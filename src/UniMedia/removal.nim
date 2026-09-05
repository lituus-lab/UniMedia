# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Journaled removal: the one way a file leaves the library.
##
## Nothing is unlinked. An item and its XMP sidecars move into
## `.om-trash/<batch>/<item>/`, recorded in `batches`/`batch_ops` with the
## content hash taken before the move, so undo has something to restore and
## something to verify it against. Deduplication and an outright removal differ
## only in how the item ids are chosen; how they leave is here.

import std/[algorithm, os, sequtils, sets, strutils]
import db_connector/db_sqlite
import UniMedia/[types, store, hashing, organize]

type RemovalOp = object
  itemId: int64
  kind: OpKind
  source, destination: string

proc removalSidecars(path: string): seq[string] =
  let exact = path & ".xmp"
  let parts = splitFile(path)
  let stem = parts.dir / (parts.name & ".xmp")
  for candidate in [exact, stem]:
    if candidate in result: continue
    if symlinkExists(candidate):
      raise newException(ValueError, "XMP sidecar must not be a symbolic link")
    if fileExists(candidate): result.add candidate

proc trashItems*(store: var Store; itemIds: seq[int64];
                 permanently = false): ApplyReport =
  ## Move `itemIds` and their sidecars into the journaled internal trash.
  ##
  ## `permanently` deletes them instead, with no journal and no way back. Only
  ## a caller naming items by hand passes it; duplicate removal and privacy
  ## stripping never do, because there the file being taken is one the engine
  ## judged expendable rather than one somebody pointed at.
  ##
  ## The caller decides what leaves; this decides how. An id that is unknown or
  ## already removed raises before anything moves, so a request lands whole or
  ## not at all. Repeats are collapsed: naming an item twice would move it, then
  ## fail to find it.
  if itemIds.len == 0:
    raise newException(ValueError, "no item to remove")
  recoverInterruptedBatches(store)
  var wanted = itemIds.toHashSet().toSeq()
  wanted.sort()

  if permanently:
    # Every file checked before any is deleted, so the request lands whole or
    # not at all — the same rule the journaled path keeps, and the only one
    # left once there is no journal to reconcile against.
    var doomed: seq[tuple[itemId: int64; paths: seq[string]]]
    for itemId in wanted:
      let item = store.getItem(itemId)
      let source = store.absoluteItemPath(item.relPath)
      if not fileExists(source):
        raise newException(IOError, "file is missing: " & source)
      doomed.add (item.id, @[source] & removalSidecars(source))
    for entry in doomed:
      var lost = false
      for path in entry.paths:
        try: removeFile(path)
        except CatchableError: lost = true
      if lost: inc result.failed
      else:
        store.db.exec(sql"DELETE FROM items WHERE id=?", entry.itemId)
        inc result.applied
    return

  result.batchId = newBatchId()
  var operations: seq[RemovalOp]
  for itemId in wanted:
    let item = store.getItem(itemId)
    let source = store.absoluteItemPath(item.relPath)
    if not fileExists(source):
      raise newException(IOError, "file is missing: " & source)
    let trashRoot = store.library.root / TrashDirName / result.batchId / $item.id
    operations.add RemovalOp(itemId: item.id, kind: okDelete, source: source,
      destination: trashRoot / source.extractFilename)
    for sidecar in removalSidecars(source):
      operations.add RemovalOp(itemId: item.id, kind: okMove, source: sidecar,
        destination: trashRoot / sidecar.extractFilename)

  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"""
      INSERT INTO batches(id,created_at,source_root,mode,status)
      VALUES(?,?,?,'delete',?)""", result.batchId, isoNow(), store.library.root,
      $bsApplying)
    for index, operation in operations:
      let destinationRel = relCatalogPath(operation.destination,
          store.library.root)
      store.db.exec(sql"""
        INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,status)
        VALUES(?,?,?,?,?,?)""", result.batchId, index, $operation.kind,
        operation.source, destinationRel, $opsPending)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

  var removed = initHashSet[int64]()
  for index, operation in operations:
    if operation.kind == okMove and operation.itemId notin removed:
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $opsFailed, "media removal failed", result.batchId, index)
      inc result.failed
      continue
    var transferred = false
    try:
      if not fileExists(operation.source):
        raise newException(IOError, "removal source disappeared: " &
            operation.source)
      if fileExists(operation.destination) or symlinkExists(
          operation.destination):
        raise newException(IOError, "trash destination already exists")
      let digest = blake3File(operation.source)
      store.db.exec(sql"BEGIN IMMEDIATE")
      try:
        store.db.exec(sql"""
          UPDATE batch_ops SET content_hash=? WHERE batch_id=? AND seq=?""",
          digest, result.batchId, index)
        store.db.exec(sql"COMMIT")
      except CatchableError:
        store.db.exec(sql"ROLLBACK")
        raise
      createDir(operation.destination.parentDir)
      moveFile(operation.source, operation.destination)
      transferred = true
      store.db.exec(sql"BEGIN IMMEDIATE")
      try:
        if operation.kind == okDelete:
          store.db.exec(sql"UPDATE items SET deleted_at=? WHERE id=?", isoNow(),
            operation.itemId)
        store.db.exec(sql"""
          UPDATE batch_ops SET status=?,error=NULL WHERE batch_id=? AND seq=?""",
          $opsApplied, result.batchId, index)
        store.db.exec(sql"COMMIT")
      except CatchableError:
        store.db.exec(sql"ROLLBACK")
        raise
      if operation.kind == okDelete:
        removed.incl operation.itemId
        inc result.applied
    except CatchableError as error:
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $(if transferred: opsPending else: opsFailed), error.msg,
        result.batchId, index)
      inc result.failed
  let pending = store.db.getValue(sql"""
    SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='pending'""",
    result.batchId).parseInt()
  let status = if pending > 0: bsApplying
    elif result.failed > 0: bsPartial
    else: bsApplied
  store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $status,
    result.batchId)
  recoverInterruptedBatches(store)

proc requireHardlinkSupport*(root: string) =
  ## Refuse before anything moves if this filesystem has no hard links.
  ##
  ## Asked of the filesystem rather than assumed from its name: a network share
  ## and an exFAT disk both refuse them, and there is no list of which mounts do.
  ## The check matters because linking is built on the trash — every duplicate
  ## is moved there first — so discovering it on the first link would leave a
  ## whole library in the trash awaiting an undo.
  let probe = root / (".om-linkprobe-" & $getCurrentProcessId())
  let target = probe & "-link"
  try:
    writeFile(probe, "")
    try:
      createHardlink(probe, target)
    except CatchableError, Defect:
      raise newException(IOError,
        "this filesystem does not support hard links, so duplicates cannot be " &
        "linked here; removing them puts the space back the same way")
    removeFile(target)
  finally:
    if fileExists(target): removeFile(target)
    if fileExists(probe): removeFile(probe)

proc linkDuplicates*(store: var Store;
                     pairs: seq[tuple[itemId, keeperId: int64]]): ApplyReport =
  ## Replace each duplicate with a hard link to the copy that was kept, so the
  ## space is freed and every path that pointed at it still opens.
  ##
  ## **Only for byte-identical duplicates.** Every pair's content hash is
  ## compared before anything moves, and a mismatch refuses the whole request:
  ## two files a perceptual hash called alike are not the same file, and
  ## linking them would destroy whichever was not kept.
  ##
  ## Built on the trash rather than beside it. The duplicate goes there first
  ## and the link is journalled after it, so undo — which walks a batch
  ## backwards — removes the link and then restores the file, with no new case
  ## to handle.
  if pairs.len == 0:
    raise newException(ValueError, "no duplicate to link")
  requireHardlinkSupport(store.library.root)
  # Every item this call replaces, known before any pair is judged: a keeper
  # that is itself being replaced would leave a link pointing at a link, and
  # the incremental set could not see a chain `A -> B, B -> C` coming, nor a
  # cycle `A -> B, B -> A`.
  var replaced = initHashSet[int64]()
  for pair in pairs:
    if pair.itemId in replaced:
      raise newException(ValueError, "an item is named twice")
    replaced.incl pair.itemId
  var keeperPath: seq[string]
  for pair in pairs:
    if pair.itemId == pair.keeperId:
      raise newException(ValueError, "an item cannot be linked to itself")
    if pair.keeperId in replaced:
      raise newException(ValueError,
        "a keeper is itself being replaced: " & $pair.keeperId)
    let duplicate = store.absoluteItemPath(store.getItem(pair.itemId).relPath)
    let keeper = store.absoluteItemPath(store.getItem(pair.keeperId).relPath)
    if not fileExists(duplicate):
      raise newException(IOError, "file is missing: " & duplicate)
    if not fileExists(keeper):
      raise newException(IOError, "the copy to keep is missing: " & keeper)
    if blake3File(duplicate) != blake3File(keeper):
      raise newException(ValueError,
        "only identical files may be linked; these differ: " & duplicate)
    keeperPath.add keeper

  # The originals go to the trash, journalled and undoable, exactly as an
  # ordinary removal does.
  var originals: seq[string]
  for pair in pairs:
    originals.add store.absoluteItemPath(store.getItem(pair.itemId).relPath)
  result = trashItems(store, pairs.mapIt(it.itemId))
  if result.failed > 0: return

  var nextSeq = store.db.getValue(sql"""
    SELECT coalesce(max(seq), -1) FROM batch_ops WHERE batch_id=?""",
    result.batchId).parseInt() + 1
  for index, pair in pairs:
    let original = originals[index]
    let keeper = keeperPath[index]
    try:
      if fileExists(original) or symlinkExists(original):
        raise newException(IOError, "the duplicate's path is occupied again")
      createHardlink(keeper, original)
      let digest = blake3File(original)
      store.db.exec(sql"""
        INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
          content_hash,status)
        VALUES(?,?,?,?,?,?,?)""", result.batchId, nextSeq, $okHardlink,
        keeper, relCatalogPath(original, store.library.root), digest, $opsApplied)
      inc nextSeq
      inc result.linked
    except CatchableError as error:
      # The file is in the trash and the link did not happen: undo still puts
      # it back, so the batch is short of a link rather than short of a file.
      inc result.failed
      store.db.exec(sql"""
        INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
          status,error)
        VALUES(?,?,?,?,?,?,?)""", result.batchId, nextSeq, $okHardlink,
        keeper, relCatalogPath(original, store.library.root), $opsFailed,
        error.msg)
      inc nextSeq
