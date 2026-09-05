# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Correcting a creation date, in the catalogue and in the file itself.
##
## A camera with a wrong clock stamps every picture it takes, so correcting only
## the catalogue leaves the mistake in place for every other program: the date
## that matters is the one in the file. The rewrite is journalled exactly as a
## removal is — the original goes to the library's trash and `undo` brings it
## back — because a metadata edit is no less irreversible for being small.
##
## Two writers, one per family: `UniImage` for the Exif carriers and `UniMovie`
## for ISO base media. A container neither of them writes is corrected in the
## catalogue and reported as not written, rather than being reported as done.

import std/[options, os, sets, strutils, times]
import db_connector/db_sqlite
import UniImage/exif/edit as imageEdit
from UniImage/exif import writeExifDateTimeOriginal
import UniMovie/edit as movieEdit
import UniMedia/[types, store, curation, hashing]
from UniMedia/organize import newBatchId
from UniMedia/catalog import scanLibrary

const CanonicalDate = "yyyy-MM-dd HH:mm:ss"

const ExifDate = "yyyy:MM:dd HH:mm:ss"
  ## Exif spells a date with colons in the date part. Writing the canonical form
  ## instead produces a field every reader rejects.

const DateWritableImages = [
  # The EXIF block can be rebuilt for these: it does not reference the pixels.
  "avif", "heic", "heif", "jpeg", "jpg", "png", "webp",
  # And these are patched where the date already sits, twenty bytes for
  # twenty. Rebuilding their block would hand back the embedded thumbnail
  # and drop the picture, which is why the editor refuses them outright.
  "arw", "cr2", "cr3", "dng", "nef", "orf", "raw", "rw2", "tif", "tiff"]
  ## The Exif carriers the image editor can rebuild. The same set the privacy
  ## strip works on, and for the same reason: it is what the editor does, not
  ## what the format could in principle hold.

const DateWritableMovies = ["m4v", "mov", "mp4", "qt"]
  ## ISO base media, where the date lives in fixed-width header fields.

proc canonical(value: string): string =
  var patch: CurationPatch
  patch.creationDate = some(value)
  validateCurationPatch(patch)
  let candidate = value.strip()
  if candidate.len == 10: candidate & " 00:00:00"
  else: candidate.replace('T', ' ')

proc selectedItems(store: Store; itemIds: seq[int64]): seq[Item] =
  if itemIds.len == 0:
    raise newException(ValueError, "date edit requires at least one item")
  var seen = initHashSet[int64]()
  for itemId in itemIds:
    if itemId <= 0:
      raise newException(ValueError, "date edit item ids must be positive")
    if itemId in seen: continue
    seen.incl itemId
    result.add store.getItem(itemId)

proc canWriteDate*(relPath: string): bool =
  ## Whether the correction can reach the file, from its name alone.
  ##
  ## By extension rather than by opening it: a plan covers a whole library and
  ## is read-only, so finding out for certain would make planning cost what
  ## applying does.
  let ext = relPath.splitFile.ext.strip(chars = {'.'}).toLowerAscii()
  ext in DateWritableImages or ext in DateWritableMovies

proc planDateSet*(store: Store; itemIds: seq[int64];
                  value: string): DateEditPlan =
  ## What setting an absolute date would change. Nothing is written.
  let target = canonical(value)
  for item in selectedItems(store, itemIds):
    result.entries.add DateEditEntry(itemId: item.id, relPath: item.relPath,
      oldDate: item.creationDate, newDate: target,
      writesFile: canWriteDate(item.relPath))

proc planDateShift*(store: Store; itemIds: seq[int64];
                    seconds: int64): DateEditPlan =
  if seconds == 0:
    raise newException(ValueError, "date shift must not be zero")
  for item in selectedItems(store, itemIds):
    if item.creationDate.len == 0:
      raise newException(ValueError,
        "cannot shift an item without a creation date: " & item.relPath)
    let current = try: parse(item.creationDate, CanonicalDate, utc())
      except TimeParseError:
        raise newException(ValueError,
          "catalogue contains an invalid creation date: " & item.relPath)
    let shifted = current + initDuration(seconds = seconds)
    result.entries.add DateEditEntry(itemId: item.id, relPath: item.relPath,
      oldDate: item.creationDate, newDate: shifted.format(CanonicalDate),
      writesFile: canWriteDate(item.relPath))

type PreparedDateWrite = object
  ## One file's corrected copy, waiting to be swapped in.
  itemId: int64
  relPath: string
  media, mediaTrash, temp: string
  mediaHash, writtenHash: string
  sidecars: seq[tuple[source, trash, digest: string]]

proc xmpSidecars(path: string): seq[string] =
  ## The XMP files that travel with this one.
  ##
  ## They go into the batch rather than being left behind: undo removes the
  ## corrected file and restores the original, and it refuses to do that with a
  ## sidecar sitting beside it — a sidecar it did not put there could hold
  ## edits made since, and dropping the file would take them with it.
  let exact = path & ".xmp"
  let parts = splitFile(path)
  let stem = parts.dir / (parts.name & ".xmp")
  for candidate in [exact, stem]:
    if candidate in result: continue
    if symlinkExists(candidate):
      raise newException(ValueError, "date edit refuses symbolic XMP sidecars")
    if fileExists(candidate): result.add candidate

proc writeCorrected(source, dest, newDate: string) =
  ## Write `source` to `dest` with its embedded date replaced.
  ##
  ## Raises rather than returning false: the caller is inside a journalled batch
  ## and needs the reason, not a flag.
  let moment = try: parse(newDate, CanonicalDate, utc())
    except TimeParseError:
      raise newException(ValueError, "invalid corrected date: " & newDate)
  let ext = source.splitFile.ext.strip(chars = {'.'}).toLowerAscii()
  if ext in DateWritableMovies:
    discard movieEdit.setMovieCreationDate(source, dest, moment)
  else:
    var exif = imageEdit.parseExif(source)
    # Sets DateTimeOriginal, DateTimeDigitized and DateTime together: a file
    # where those disagree shows whichever one the reader happens to prefer.
    exif.setDateTimeOriginal(moment.format(ExifDate))
    if not imageEdit.writeExif(source, exif, dest):
      # A file whose bulk is image data cannot have its block rebuilt -- a RAW
      # would come back as its embedded thumbnail -- so the editor refuses it.
      # The date is patched where it already sits instead: the same twenty
      # ASCII bytes, so no offset moves and the pixels are never read.
      copyFile(source, dest)
      if not writeExifDateTimeOriginal(dest, moment.format(ExifDate)):
        removeFile(dest)
        raise newException(ValueError,
          "the metadata editor could not rewrite " & source.extractFilename)

proc prepareDateWrite(store: Store; entry: DateEditEntry; batchId: string;
                      index: int): PreparedDateWrite =
  ## Build the corrected copy and work out where the original will be kept.
  result.itemId = entry.itemId
  result.relPath = entry.relPath
  result.media = store.absoluteItemPath(entry.relPath)
  if symlinkExists(result.media):
    raise newException(ValueError, "date edit refuses symbolic media")
  if not fileExists(result.media):
    raise newException(IOError, "date edit source is missing: " & result.media)
  let trashRoot = store.library.root / TrashDirName / batchId / "date" /
    $entry.itemId
  result.mediaTrash = store.absoluteItemPath(relCatalogPath(
    trashRoot / result.media.extractFilename, store.library.root))
  result.temp = result.media.parentDir / (".om-tmp-date-" & batchId & "-" & $index)
  if fileExists(result.temp) or symlinkExists(result.temp):
    raise newException(IOError, "date edit temporary path is occupied")
  try:
    writeCorrected(result.media, result.temp, entry.newDate)
    result.mediaHash = blake3File(result.media)
    result.writtenHash = blake3File(result.temp)
    let trashDir = result.mediaTrash.parentDir
    for sidecar in xmpSidecars(result.media):
      result.sidecars.add (source: sidecar,
        trash: trashDir / sidecar.extractFilename,
        digest: blake3File(sidecar))
  except CatchableError:
    if fileExists(result.temp): removeFile(result.temp)
    raise

proc applyDateEdit*(store: var Store; plan: DateEditPlan;
                    progress: ProgressCallback = nil;
                    cancel: CancelCallback = nil;
                    writeFiles = true): CurationBatchReport =
  ## Correct the date, in the catalogue and — unless `writeFiles` is false — in
  ## each file that has a writer here.
  ##
  ## The file rewrite is journalled under one batch: the original moves to the
  ## library's trash and the corrected copy takes its place, so `undo` restores
  ## it exactly as it does after a removal. `written` counts the files that were
  ## actually rewritten, which is not the same as `applied`: a container with no
  ## writer here still has its catalogue entry corrected.
  if plan.entries.len == 0:
    raise newException(ValueError, "date edit plan is empty")
  for entry in plan.entries:
    let item = store.getItem(entry.itemId)
    if item.relPath != entry.relPath or item.creationDate != entry.oldDate:
      raise newException(ValueError, "date edit plan is stale: " & entry.relPath)
    discard canonical(entry.newDate)

  # Every corrected copy is built before anything is swapped, so a container the
  # editor turns out to refuse stops the batch while the library is untouched.
  var prepared: seq[PreparedDateWrite]
  if writeFiles:
    result.batchId = newBatchId()
    try:
      for index, entry in plan.entries:
        if not entry.writesFile: continue
        prepared.add prepareDateWrite(store, entry, result.batchId, index)
    except CatchableError:
      for operation in prepared:
        if fileExists(operation.temp): removeFile(operation.temp)
      raise
  if prepared.len == 0: result.batchId = ""

  if prepared.len > 0:
    store.db.exec(sql"BEGIN IMMEDIATE")
    try:
      store.db.exec(sql"""
        INSERT INTO batches(id,created_at,source_root,mode,status)
        VALUES(?,?,?,'date',?)""", result.batchId, isoNow(),
        store.library.root, $bsApplying)
      var sequence = 0
      for operation in prepared:
        for sidecar in operation.sidecars:
          store.db.exec(sql"""
            INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
              content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
            sequence, $okMove, sidecar.source,
            relCatalogPath(sidecar.trash, store.library.root), sidecar.digest,
            $opsPending)
          inc sequence
        store.db.exec(sql"""
          INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
            content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
          sequence, $okMove, operation.media,
          relCatalogPath(operation.mediaTrash, store.library.root),
          operation.mediaHash, $opsPending)
        inc sequence
        store.db.exec(sql"""
          INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
            content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
          sequence, $okCopy, operation.temp, operation.relPath,
          operation.writtenHash, $opsPending)
        inc sequence
      store.db.exec(sql"COMMIT")
    except CatchableError:
      store.db.exec(sql"ROLLBACK")
      for operation in prepared:
        if fileExists(operation.temp): removeFile(operation.temp)
      raise

  var writtenFor = initHashSet[int64]()
  var sequence = 0
  for operation in prepared:
    # Each operation owns a fixed block of rows -- one per sidecar, one for the
    # media move, one for the corrected copy -- written in that order above.
    # `transfer` only advances the counter after a successful UPDATE, so a
    # failure part-way through left the remaining rows of this operation
    # unvisited and the next operation writing its statuses over them.
    let base = sequence
    let rows = operation.sidecars.len + 2
    template transfer(source, destination: string) =
      discard store.absoluteItemPath(relCatalogPath(destination,
        store.library.root))
      if fileExists(destination) or symlinkExists(destination):
        raise newException(IOError, "date edit destination is occupied")
      createDir(destination.parentDir)
      moveFile(source, destination)
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=NULL WHERE batch_id=? AND seq=?""",
        $opsApplied, result.batchId, sequence)
      inc sequence
    try:
      for sidecar in operation.sidecars:
        transfer(sidecar.source, sidecar.trash)
      transfer(operation.media, operation.mediaTrash)
      transfer(operation.temp, operation.media)
      writtenFor.incl operation.itemId
      inc result.written
    except CatchableError as error:
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $opsFailed, error.msg, result.batchId, sequence)
      result.failures.add CurationBatchFailure(itemId: operation.itemId,
        relPath: operation.relPath, error: error.msg)
      if fileExists(operation.temp): removeFile(operation.temp)
    sequence = base + rows

  if prepared.len > 0:
    let pending = store.db.getValue(sql"""
      SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='pending'""",
      result.batchId).parseInt()
    let status = if result.failures.len > 0 or pending > 0: bsPartial
                 else: bsApplied
    store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $status,
      result.batchId)

  for index, entry in plan.entries:
    if cancel != nil and cancel():
      raise newException(OperationCancelledError,
        "date edit cancelled after " & $result.applied & " item(s)")
    # An item whose file rewrite failed keeps its old date in the catalogue too:
    # a catalogue that disagreed with the file it just failed to write would be
    # the worst of both.
    if writeFiles and entry.writesFile and entry.itemId notin writtenFor:
      inc result.failed
      continue
    if entry.itemId in writtenFor:
      # The date now lives in the file, and the rescan below reads it back. A
      # curation here would write an XMP sidecar beside the corrected file, and
      # undo will not remove a file that has one.
      inc result.applied
      if progress != nil:
        progress(ProgressEvent(phase: "date-edit", current: index + 1,
          total: plan.entries.len, message: entry.relPath))
      continue
    try:
      var patch: CurationPatch
      patch.creationDate = some(entry.newDate)
      discard store.curateItem(entry.itemId, patch)
      inc result.applied
    except CatchableError as error:
      inc result.failed
      result.failures.add CurationBatchFailure(itemId: entry.itemId,
        relPath: entry.relPath, error: error.msg)
    if progress != nil:
      progress(ProgressEvent(phase: "date-edit", current: index + 1,
        total: plan.entries.len, message: entry.relPath))

  if writtenFor.len > 0 and result.failures.len == 0:
    # Incremental: only the files just rewritten differ in size or timestamp, so
    # this re-reads those and stats the rest. Perceptual hashes are left for a
    # later scan — a metadata edit does not change what a picture looks like.
    discard scanLibrary(store, skipPhash = true)
