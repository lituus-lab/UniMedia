# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[os, times, tables, algorithm, sequtils, strutils, sysrand]
import db_connector/db_sqlite
import UniMedia/[types, store, catalog, hashing]

proc datedRel(dateValue, filename, noDateDir: string;
              scheme: OrganizeScheme): string =
  # `catalogPath` on the way out: `/` joins with the platform separator, so on
  # Windows a scheme whose own format already contains `/` produced a mixed
  # `2026/07-31\IMG.jpg` that no stored row could match.
  if dateValue.len < 10:
    return (noDateDir / filename).catalogPath
  let stamp = try: parse(dateValue[0..9], "yyyy-MM-dd")
              except ValueError: return (noDateDir / filename).catalogPath
  case scheme
  of osYearMonthDayDash:
    (stamp.format("yyyy/MM-dd") / filename).catalogPath
  of osYearMonthDay:
    (stamp.format("yyyy/MM/dd") / filename).catalogPath
  of osYearMonth:
    (stamp.format("yyyy/MM") / filename).catalogPath
  of osYearDate:
    (stamp.format("yyyy/yyyy-MM-dd") / filename).catalogPath
  of osFlat:
    stamp.format("yyyy-MM-dd") & "_" & filename

proc isHidden(root, path: string): bool =
  ## Whether any component of `path` below `root` begins with a dot.
  ##
  ## The same rule the scan applies, so a file the catalogue would never index
  ## is not one an import copies in.
  # The catalogue's separator, not the platform's: `rel` is already normalised,
  # so `DirSep` matched nothing on Windows and no component was ever hidden.
  let rel = relCatalogPath(path, root)
  for part in rel.split(CatalogSep):
    if part.startsWith('.'): return true
  false

proc uniqueRel(store: Store; wanted: string; policy: ConflictPolicy;
               reserved: var Table[string, bool]): tuple[path, reason: string] =
  if not reserved.hasKey(wanted) and not fileExists(store.absoluteItemPath(wanted)):
    reserved[wanted] = true
    return (wanted, "")
  if policy == cpSkip: return (wanted, "collision")
  let parts = splitFile(wanted)
  var index = 1
  while true:
    # `/` joins with the platform separator, and a candidate carrying `\` would
    # match neither a reserved name nor a stored row.
    let candidate = (parts.dir / (parts.name & "_" & $index &
        parts.ext)).catalogPath
    if not reserved.hasKey(candidate) and not fileExists(store.absoluteItemPath(candidate)):
      reserved[candidate] = true
      return (candidate, "")
    inc index

const SidecarExts* = [".xmp", ".aae", ".thm"]
  ## What travels with a media file rather than being one.
  ##
  ## `.aae` holds Apple's non-destructive edits — a crop, a filter — and the
  ## picture beside it is the unedited original, so a copy that leaves it
  ## behind quietly discards the edit. `.thm` is a camera's thumbnail for a
  ## recording. Both are written in two spellings, `IMG_1.HEIC.aae` and
  ## `IMG_1.aae`, and both are found here.

proc sidecars(path: string): seq[string] =
  ## Every sidecar sitting beside `path`.
  let parts = splitFile(path)
  for extension in SidecarExts:
    let direct = path & extension
    let sibling = parts.dir / (parts.name & extension)
    if fileExists(direct): result.add direct
    if sibling != direct and fileExists(sibling): result.add sibling

proc alreadyThere(store: Store; source, wanted: string;
                  claimedBy: Table[string, string]): bool =
  ## Whether `wanted` is already occupied by these very bytes.
  ##
  ## Two places to look, and both matter: what a previous run put on disk, and
  ## what an earlier source in this same plan claimed. Checking only the first
  ## made a file behave differently depending on whether somebody had imported
  ## its twin before.
  ##
  ## Size gates the hash, so two files of different length never cost a read.
  let destination = store.absoluteItemPath(wanted)
  if fileExists(destination) and getFileSize(destination) == getFileSize(source):
    return try: blake3File(destination) == blake3File(source)
           except CatchableError: false
  if claimedBy.hasKey(wanted):
    let earlier = claimedBy[wanted]
    if getFileSize(earlier) == getFileSize(source):
      return try: blake3File(earlier) == blake3File(source)
             except CatchableError: false
  false

proc planOrganize*(store: Store; sourceRoot: string;
                   options: OrganizeOptions;
                   progress: ProgressCallback = nil): OrganizePlan =
  ## Plans without touching a file. `progress` is reported over both halves:
  ## the walk, whose total is not known while it runs, and the pass that reads
  ## each candidate's date, which is the long one -- on a network share it is
  ## most of the wait, and without a report the command looks stalled.
  result.sourceRoot = normalizedPath(absolutePath(sourceRoot))
  if not dirExists(result.sourceRoot):
    raise newException(IOError, "source directory not found: " &
        result.sourceRoot)
  discard checkedPathUnder(result.sourceRoot, result.sourceRoot)
  # Re-filing a library walks the library, and its own bookkeeping lives
  # there: filing `.om-cache` would catalogue every thumbnail as a photo, and
  # then find them all as duplicates of what they were rendered from.
  let root = store.library.root
  let sourceInsideLibrary = result.sourceRoot.isRelativeTo(root)
  var sources: seq[string]
  for path in walkDirRec(result.sourceRoot):
    if sourceInsideLibrary and isInternal(root, path): continue
    # A hidden file is not an import candidate, whatever its name ends in. On a
    # network share macOS writes `._IMG_1234.HEIC` beside every picture to hold
    # its resource fork; that name ends in .HEIC, so filtering by extension
    # alone files 44299 of them as photographs. The scan has always skipped
    # them — the two halves of one library must agree on what a file is.
    if isHidden(result.sourceRoot, path): continue
    if categoryFor(store.library.config.domain, path).len > 0:
      sources.add path
      if progress != nil and sources.len mod 64 == 0:
        progress(ProgressEvent(phase: "walk", current: sources.len, total: 0,
          message: "looking for candidates"))
  sources.sort()
  if progress != nil:
    progress(ProgressEvent(phase: "walk", current: sources.len,
      total: sources.len, message: "candidates found"))
  var reserved = initTable[string, bool]()
  # What each destination was claimed by, so a later source that is byte for
  # byte the same file is recognised. Without it a plan skips a duplicate of
  # something already on disk but copies a duplicate of something earlier in
  # its own list — the same two files behaving differently depending on whether
  # a previous run had already imported one of them.
  var claimedBy = initTable[string, string]()
  for sourceIndex, source in sources:
    if progress != nil:
      progress(ProgressEvent(phase: "plan", current: sourceIndex + 1,
        total: sources.len, message: source.extractFilename))
    discard checkedPathUnder(result.sourceRoot, source)
    let date = mediaDate(source, options.filenameDate, options.birthtimeDate)
    let wanted = datedRel(date.value, source.extractFilename,
                          options.noDateDir, options.scheme)
    # Asked for every copy: neither what is already on disk nor what an earlier
    # source in this plan claimed makes this one redundant.
    let identical = not options.keepDuplicates and
      alreadyThere(store, source, wanted, claimedBy)
    let choice = if identical: (path: wanted, reason: "identical")
                 else: uniqueRel(store, wanted, options.onConflict, reserved)
    if choice.reason.len == 0 and not claimedBy.hasKey(choice.path):
      claimedBy[choice.path] = source
    let kind = case options.mode
      of tmCopy: okCopy
      of tmMove: okMove
      of tmHardlink: okHardlink
    var skip = choice.reason
    let dest = store.absoluteItemPath(choice.path)
    if normalizedPath(absolutePath(source)) == dest: skip = "already-organized"
    result.operations.add PlannedOp(kind: kind, sourcePath: source,
      destRelPath: choice.path, size: getFileSize(source),
      creationDate: date.value, dateSource: date.source, skipReason: skip)
    # Sidecars are considered even where the media is skipped. A picture
    # already filed whose edit file is not says nothing about the edit file:
    # `uniqueRel` below skips a sidecar that is genuinely already there, and
    # carries one that never arrived — which is what makes a second run able to
    # finish what a first one left.
    if true:
      for sidecar in sidecars(source):
        let mediaParts = splitFile(choice.path)
        # The sidecar keeps its own extension and its own spelling: a `.aae`
        # renamed `.xmp` describes nothing any reader knows how to apply.
        let sideExt = splitFile(sidecar).ext
        let sideRel = if sidecar == source & sideExt: choice.path & sideExt
                      else: mediaParts.dir / (mediaParts.name & sideExt)
        # The same test the media gets. Without it a folder holding its own
        # backup filed one picture and two identical edit files, the second
        # suffixed — 704 of them on a real import.
        let sideIdentical = not options.keepDuplicates and
          alreadyThere(store, sidecar, sideRel, claimedBy)
        let sideChoice = if sideIdentical: (path: sideRel, reason: "identical")
                         else: uniqueRel(store, sideRel, options.onConflict,
                           reserved)
        if sideChoice.reason.len == 0 and not claimedBy.hasKey(sideChoice.path):
          claimedBy[sideChoice.path] = sidecar
        result.operations.add PlannedOp(kind: kind, sourcePath: sidecar,
          destRelPath: sideChoice.path, size: getFileSize(sidecar),
          creationDate: date.value, dateSource: "sidecar",
          skipReason: sideChoice.reason)

proc newBatchId*(): string =
  var token = ""
  for value in urandom(12):
    token.add value.toHex(2).toLowerAscii()
  "batch_" & $getTime().toUnix() & "_" & token

func leavesSourceInPlace(kind: string): bool =
  ## Copy and hardlink keep the source where it was, so recovery and undo may
  ## drop the destination. Move and delete must restore it instead.
  kind == $okCopy or kind == $okHardlink

proc materialize(source, destination, expectedHash, token: string;
                 kind: OpKind) =
  createDir(destination.parentDir)
  let temp = destination.parentDir / (".om-tmp-" & token)
  try:
    if kind == okHardlink:
      # Same inode, so there are no second bytes to verify; the read below still
      # confirms the source is intact and reachable through the new name.
      createHardlink(source, temp)
    else:
      copyFile(source, temp)
    if blake3File(temp) != expectedHash:
      raise newException(IOError, "copy verification failed: " & source)
    moveFile(temp, destination)
  finally:
    if fileExists(temp): removeFile(temp)

proc recoverInterruptedBatches*(store: var Store) =
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    for batch in store.db.getAllRows(sql"""
        SELECT id FROM batches WHERE status IN ('pending','applying')
        ORDER BY rowid"""):
      for row in store.db.getAllRows(sql"""
          SELECT id,kind,source_path,dest_rel_path,content_hash,status
          FROM batch_ops WHERE batch_id=? ORDER BY seq""", batch[0]):
        if row[5] != $opsPending: continue
        var status = opsFailed
        var message = "interrupted before the filesystem mutation completed"
        try:
          let destination = store.absoluteItemPath(row[3])
          if row[4].len > 0 and fileExists(destination) and
              blake3File(destination) == row[4]:
            if leavesSourceInPlace(row[1]) or not fileExists(row[2]):
              status = opsApplied
              message = ""
              if row[1] == $okDelete:
                let original = checkedPathUnder(store.library.root, row[2])
                let originalRel = relCatalogPath(original, store.library.root)
                store.db.exec(sql"UPDATE items SET deleted_at=? WHERE rel_path=?",
                  isoNow(), originalRel)
            else:
              message = "interrupted move is ambiguous: source and destination exist"
        except CatchableError as error:
          message = error.msg
        store.db.exec(sql"UPDATE batch_ops SET status=?,error=? WHERE id=?",
          $status, message, row[0])
      let remaining = store.db.getValue(
        sql"""
        SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='pending'""",
        batch[0]).parseInt()
      let broken = store.db.getValue(sql"""
        SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='failed'""",
        batch[0]).parseInt()
      let finalStatus = if remaining > 0 or broken > 0: bsPartial
                        else: bsApplied
      store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $finalStatus,
        batch[0])
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc applyPlan*(store: var Store; plan: OrganizePlan;
                progress: ProgressCallback = nil): ApplyReport =
  recoverInterruptedBatches(store)
  for operation in plan.operations:
    if operation.skipReason.len == 0:
      discard checkedPathUnder(plan.sourceRoot, operation.sourcePath)
      discard store.absoluteItemPath(operation.destRelPath)
  result.batchId = newBatchId()
  let mode = if plan.operations.anyIt(it.kind == okMove): "move"
             elif plan.operations.anyIt(it.kind == okHardlink): "hardlink"
             else: "copy"
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"INSERT INTO batches(id,created_at,source_root,mode,status) VALUES(?,?,?,?,?)",
      result.batchId, isoNow(), plan.sourceRoot, mode, $bsPending)
    for index, operation in plan.operations:
      if operation.skipReason.len == 0:
        store.db.exec(sql"""
          INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,status)
          VALUES(?,?,?,?,?,?)""", result.batchId, index, $operation.kind,
          operation.sourcePath, operation.destRelPath, $opsPending)
    store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $bsApplying,
        result.batchId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise
  var pending = 0
  let operationTotal = plan.operations.countIt(it.skipReason.len == 0)
  var opIndex = 0
  for index, operation in plan.operations:
    if operation.skipReason.len > 0:
      inc result.skipped
      continue
    var destination, source: string
    var transferred = false
    var compensationFailed = false
    try:
      destination = store.absoluteItemPath(operation.destRelPath)
      source = checkedPathUnder(plan.sourceRoot, operation.sourcePath)
      if not fileExists(source):
        raise newException(IOError, "source disappeared: " & source)
      let digest = blake3File(source)
      store.db.exec(sql"BEGIN IMMEDIATE")
      try:
        store.db.exec(sql"""
          UPDATE batch_ops SET content_hash=? WHERE batch_id=? AND seq=?""",
          digest, result.batchId, index)
        store.db.exec(sql"COMMIT")
      except CatchableError:
        store.db.exec(sql"ROLLBACK")
        raise
      if fileExists(destination):
        raise newException(IOError, "destination appeared after planning: " &
            destination)
      materialize(source, destination, digest, result.batchId & "-" & $index,
        operation.kind)
      transferred = true
      if operation.kind == okMove: removeFile(source)
      store.db.exec(sql"BEGIN IMMEDIATE")
      try:
        if operation.kind == okMove and source.startsWith(
            store.library.root & DirSep):
          let oldRel = relCatalogPath(source, store.library.root)
          store.db.exec(sql"""
            UPDATE items SET rel_path=?,indexed_at=? WHERE rel_path=?""",
            operation.destRelPath, isoNow(), oldRel)
        store.db.exec(sql"""
          UPDATE batch_ops SET status=?,error=NULL WHERE batch_id=? AND seq=?""",
          $opsApplied, result.batchId, index)
        store.db.exec(sql"COMMIT")
      except CatchableError:
        store.db.exec(sql"ROLLBACK")
        raise
      inc result.applied
    except CatchableError as error:
      if transferred and destination.len > 0 and fileExists(destination):
        try:
          if operation.kind in {okCopy, okHardlink} or fileExists(source):
            removeFile(destination)
          else:
            let original = checkedPathUnder(plan.sourceRoot, source)
            createDir(original.parentDir)
            moveFile(destination, original)
        except CatchableError:
          compensationFailed = true
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $(if compensationFailed: opsPending else: opsFailed), error.msg,
        result.batchId, index)
      inc result.failed
    inc opIndex
    if progress != nil:
      progress(ProgressEvent(phase: "organize", current: opIndex,
        total: operationTotal, message: operation.destRelPath))
  pending = store.db.getValue(sql"""
    SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='pending'""",
    result.batchId).parseInt()
  let status = if pending > 0: bsApplying
               elif result.failed == 0: bsApplied
               else: bsPartial
  store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $status,
      result.batchId)
  if pending > 0:
    recoverInterruptedBatches(store)
  discard scanLibrary(store, skipPhash = false, progress = progress)

proc resolveBatch(store: Store; requested: string): string =
  ## An empty `requested` selects the most recent batch. The shell owns the
  ## spelling of that choice, so no command-line token reaches the engine.
  result = if requested.len == 0:
    store.db.getValue(sql"SELECT id FROM batches ORDER BY rowid DESC LIMIT 1")
  else:
    store.db.getValue(sql"SELECT id FROM batches WHERE id=?", requested)
  if result.len == 0:
    let message = if requested.len == 0: "no batch to undo"
                  else: "batch not found: " & requested
    raise newException(ValueError, message)

proc planUndo*(store: var Store; requested: string): seq[PlannedOp] =
  ## Read-only reversal plan for `requested`, or the most recent batch when it
  ## is empty.
  recoverInterruptedBatches(store)
  let batch = resolveBatch(store, requested)
  for row in store.db.getAllRows(sql"""
      SELECT kind,source_path,dest_rel_path,status FROM batch_ops
      WHERE batch_id=? ORDER BY seq DESC""", batch):
    if row[3] == $opsApplied or row[3] == $opsPending:
      let kind = if row[0] == $okMove: okMove
                 elif row[0] == $okHardlink: okHardlink
                 elif row[0] == $okDelete: okDelete
                 else: okCopy
      result.add PlannedOp(kind: kind,
        sourcePath: row[1], destRelPath: row[2])

proc applyUndo*(store: var Store; requested: string;
                progress: ProgressCallback = nil): UndoReport =
  ## Reverse `requested`, or the most recent batch when it is empty.
  recoverInterruptedBatches(store)
  result.batchId = resolveBatch(store, requested)
  # Named rather than discovered file by file: emptying the trash ends
  # recoverability, and saying so once is clearer than a hundred failures on
  # paths that are no longer there.
  if store.db.getValue(sql"SELECT status FROM batches WHERE id=?",
      result.batchId) == $bsEmptied:
    raise newException(ValueError,
      "this batch was emptied from the trash; what it removed is gone")
  # Gathered as the files come back, so the reconciliation afterwards reads
  # those and no more.
  var restored: seq[string]
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    let rows = store.db.getAllRows(sql"""
      SELECT id,kind,source_path,dest_rel_path,content_hash,status FROM batch_ops
      WHERE batch_id=? AND status IN ('applied','pending') ORDER BY seq DESC""",
      result.batchId)
    let sourceRoot = store.db.getValue(sql"SELECT source_root FROM batches WHERE id=?",
      result.batchId)
    result.failed = store.db.getValue(sql"""
      SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='failed'""",
      result.batchId).parseInt()
    for index, row in rows:
      template notifyUndo() =
        if progress != nil:
          progress(ProgressEvent(phase: "undo", current: index + 1,
            total: rows.len, message: row[3]))
      var destination = ""
      try:
        destination = store.absoluteItemPath(row[3])
        if not fileExists(destination):
          if leavesSourceInPlace(row[1]):
            store.db.exec(sql"UPDATE batch_ops SET status=?,error=NULL WHERE id=?",
              $opsUndone, row[0])
            inc result.skipped
            notifyUndo()
            continue
          let original = checkedPathUnder(sourceRoot, row[2])
          if not fileExists(original):
            raise newException(IOError,
              "moved file is missing from source and destination")
          if blake3File(original) != row[4]:
            raise newException(IOError,
              "restored original changed before undo recovery: " & original)
          if row[1] == $okDelete:
            let originalRel = relCatalogPath(original, store.library.root)
            store.db.exec(sql"""
              UPDATE items SET deleted_at=NULL,indexed_at=? WHERE rel_path=?""",
              isoNow(), originalRel)
          elif original.startsWith(store.library.root & DirSep):
            let originalRel = relCatalogPath(original, store.library.root)
            store.db.exec(sql"""
              UPDATE items SET rel_path=?,indexed_at=? WHERE rel_path=?""",
              originalRel, isoNow(), row[3])
          store.db.exec(sql"UPDATE batch_ops SET status=?,error=NULL WHERE id=?",
            $opsUndone, row[0])
          inc result.skipped
          notifyUndo()
          continue
        if blake3File(destination) != row[4]:
          raise newException(IOError, "destination changed since apply: " & destination)
        if leavesSourceInPlace(row[1]):
          let exactSidecar = destination & ".xmp"
          let parts = splitFile(destination)
          let stemSidecar = parts.dir / (parts.name & ".xmp")
          if fileExists(exactSidecar) or symlinkExists(exactSidecar) or
              fileExists(stemSidecar) or symlinkExists(stemSidecar):
            raise newException(IOError,
              "destination gained an XMP sidecar since apply: " & destination)
          removeFile(destination)
          # The row goes with the file -- unless this same batch is about to
          # put a file back at that very path. A privacy strip journals the
          # cleaned file as a copy over the item's own path and moves the
          # original to the trash; undoing the move restores it there, so
          # deleting the row here dropped the item's curation, album, face and
          # vision data with it and the rescan created a new item with a new
          # id. Otherwise the entry would list a photograph that is no longer
          # there, which the full rescan used to clean up on the library's
          # time rather than the batch's.
          let restoredHere = store.db.getValue(
            sql"""
            SELECT count(*) FROM batch_ops
            WHERE batch_id=? AND kind=? AND source_path=?""",
            result.batchId, $okMove,
            store.library.root / row[3]).parseInt() > 0
          if not restoredHere:
            store.db.exec(sql"DELETE FROM items WHERE rel_path=?", row[3])
        else:
          let original = checkedPathUnder(sourceRoot, row[2])
          if fileExists(original):
            raise newException(IOError, "original path is occupied: " & original)
          let destinationParts = splitFile(destination)
          let exactSidecar = destination & ".xmp"
          let stemSidecar = destinationParts.dir / (destinationParts.name & ".xmp")
          if (exactSidecar != destination and symlinkExists(exactSidecar)) or
              (stemSidecar != destination and symlinkExists(stemSidecar)):
            raise newException(IOError,
              "destination XMP sidecar must not be a symbolic link")
          if exactSidecar != destination and stemSidecar != destination and
              fileExists(exactSidecar) and fileExists(stemSidecar) and
              exactSidecar != stemSidecar:
            raise newException(IOError,
              "destination has ambiguous XMP sidecars: " & destination)
          let sidecar = if exactSidecar != destination and fileExists(exactSidecar):
                          exactSidecar
                        elif stemSidecar != destination and fileExists(stemSidecar):
                          stemSidecar
                        else: ""
          var originalSidecar = ""
          if sidecar.len > 0:
            let originalParts = splitFile(original)
            originalSidecar = if sidecar == exactSidecar: original & ".xmp"
              else: originalParts.dir / (originalParts.name & ".xmp")
            originalSidecar = checkedPathUnder(sourceRoot, originalSidecar)
            if fileExists(originalSidecar) or symlinkExists(originalSidecar):
              raise newException(IOError,
                "original XMP sidecar path is occupied: " & originalSidecar)
          createDir(original.parentDir)
          if sidecar.len > 0:
            moveFile(sidecar, originalSidecar)
          try:
            moveFile(destination, original)
          except CatchableError:
            if sidecar.len > 0 and fileExists(originalSidecar) and
                not fileExists(sidecar):
              moveFile(originalSidecar, sidecar)
            raise
          if original.startsWith(store.library.root & DirSep):
            restored.add original
          if row[1] == $okDelete:
            let originalRel = relCatalogPath(original, store.library.root)
            store.db.exec(sql"""
              UPDATE items SET deleted_at=NULL,indexed_at=? WHERE rel_path=?""",
              isoNow(), originalRel)
          elif original.startsWith(store.library.root & DirSep):
            let originalRel = relCatalogPath(original, store.library.root)
            store.db.exec(sql"UPDATE items SET rel_path=?,indexed_at=? WHERE rel_path=?",
              originalRel, isoNow(), row[3])
        store.db.exec(sql"UPDATE batch_ops SET status=?,error=NULL WHERE id=?",
          $opsUndone, row[0])
        inc result.undone
      except CatchableError as error:
        store.db.exec(sql"UPDATE batch_ops SET error=? WHERE id=?", error.msg,
            row[0])
        inc result.failed
      notifyUndo()
    let unresolved = store.db.getValue(sql"""
      SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='failed'""",
      result.batchId).parseInt()
    if result.failed == 0 and unresolved == 0:
      store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $bsUndone,
          result.batchId)
    else:
      store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $bsPartial,
          result.batchId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise
  # Only what came back is re-read. The rows above already carry the right path
  # and deleted_at; what a move cannot know is that a restored file's size and
  # hash differ from the one it replaced — a stripped photograph and its
  # original are not the same bytes. Rescanning the library to learn that cost
  # the library instead of the batch, and on a network share that was half an
  # hour of work after the files were already back.
  #
  # Perceptual hashes are left pending: only similarity search reads them, and
  # whoever runs one computes what it is owed.
  if restored.len > 0:
    discard reindexPaths(store, restored)



