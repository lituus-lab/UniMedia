# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Recoverable embedded-metadata and XMP-sidecar removal.

import std/[os, sequtils, sets, strutils]
import db_connector/db_sqlite
import UniImage/exif/edit
import UniMedia/[types, store, hashing, catalog, organize, privacy]

type PreparedStrip = object
  item: Item
  temp, media, mediaTrash: string
  mediaHash, strippedHash: string
  sidecars: seq[tuple[source, trash, digest: string]]

proc xmpSidecars(path: string): seq[string] =
  let exact = path & ".xmp"
  let parts = splitFile(path)
  let stem = parts.dir / (parts.name & ".xmp")
  for candidate in [exact, stem]:
    if candidate in result: continue
    if symlinkExists(candidate):
      raise newException(ValueError,
        "privacy strip refuses symbolic XMP sidecars")
    if fileExists(candidate): result.add candidate

const StrippableExts = ["avif", "heic", "heif", "jpeg", "jpg", "png", "webp"]
  ## The containers the metadata editor can rebuild — JPEG by rewriting its
  ## segments, the rest by replacing the Exif payload in place.
  ##
  ## Measured against the editor rather than assumed: TIFF looks like it
  ## belongs here and does not, and HEIC looks like it does not and does. A
  ## camera roll is mostly HEIC, so getting that one wrong would have meant a
  ## privacy tool that could clean almost nothing in it.
  ##
  ## A video is reported by the audit and left alone here: its position is real
  ## and worth knowing about, and rewriting a video is not this tool's job.

proc canStrip*(relPath: string): bool =
  ## Whether stripping can rewrite this file, from its name alone.
  ##
  ## By extension rather than by reading it: a plan is read-only and covers a
  ## whole library, and opening every file to find out would make planning cost
  ## what applying does.
  relPath.splitFile.ext.strip(chars = {'.'}).toLowerAscii() in StrippableExts

proc planPrivacyStrip*(store: Store;
                       requested: seq[int64] = @[]): PrivacyStripPlan =
  ## Plan only. An empty selection targets items reported by privacyAudit.
  ##
  ## Every flagged item appears, including the ones stripping cannot rewrite:
  ## leaving those out would hide a file that gives something away. They are
  ## marked instead, and `applyPrivacyStrip` passes over them.
  var selected = initHashSet[int64]()
  for itemId in requested:
    if itemId <= 0:
      raise newException(ValueError, "privacy strip item ids must be positive")
    discard store.getItem(itemId)
    selected.incl itemId
  var signalsById: seq[PrivacyFinding]
  for finding in store.privacyAudit():
    if finding.error.len == 0: signalsById.add finding
  if selected.len == 0:
    for finding in signalsById: selected.incl finding.itemId
  for item in store.listItems():
    if item.id notin selected: continue
    var signals: seq[string]
    for finding in signalsById:
      if finding.itemId == item.id:
        signals = finding.signals
        break
    if signals.len == 0: signals = @["explicit-selection"]
    result.entries.add PrivacyStripEntry(itemId: item.id,
      relPath: item.relPath, signals: signals,
      strippable: canStrip(item.relPath))

proc prepare(store: Store; entry: PrivacyStripEntry; batchId: string;
             index: int): PreparedStrip =
  result.item = store.getItem(entry.itemId)
  if result.item.relPath != entry.relPath:
    raise newException(ValueError, "privacy strip plan is stale: " & entry.relPath)
  result.media = store.absoluteItemPath(entry.relPath)
  if symlinkExists(result.media):
    raise newException(ValueError, "privacy strip refuses symbolic media")
  if not fileExists(result.media):
    raise newException(IOError, "privacy strip source is missing: " & result.media)
  let trashRoot = store.library.root / TrashDirName / batchId / "strip" /
    $entry.itemId
  result.mediaTrash = store.absoluteItemPath(relativePath(
    trashRoot / result.media.extractFilename, store.library.root))
  result.temp = result.media.parentDir / (".om-tmp-" & batchId & "-" & $index)
  if fileExists(result.temp) or symlinkExists(result.temp):
    raise newException(IOError, "privacy strip temporary path is occupied")
  try:
    if not stripMetadata(result.media, result.temp):
      raise newException(ValueError,
        "privacy strip does not support this container: " & entry.relPath)
    result.mediaHash = blake3File(result.media)
    result.strippedHash = blake3File(result.temp)
    for sidecar in xmpSidecars(result.media):
      let trash = store.absoluteItemPath(relativePath(
        trashRoot / sidecar.extractFilename, store.library.root))
      result.sidecars.add (source: sidecar, trash: trash,
        digest: blake3File(sidecar))
  except CatchableError:
    if fileExists(result.temp): removeFile(result.temp)
    raise

proc applyPrivacyStrip*(store: var Store; plan: PrivacyStripPlan;
                        progress: ProgressCallback = nil): ApplyReport =
  ## Apply is intentionally non-cancellable after the journal is committed.
  if plan.entries.len == 0:
    raise newException(ValueError, "privacy strip plan is empty")
  if not plan.entries.anyIt(it.strippable):
    raise newException(ValueError,
      "nothing in this plan is a container privacy strip can rewrite")
  recoverInterruptedBatches(store)
  result.batchId = newBatchId()
  var prepared: seq[PreparedStrip]
  try:
    for index, entry in plan.entries:
      # A container the editor cannot rebuild is passed over, not failed: the
      # audit reported it so somebody knows, and one video must not stop a
      # thousand photographs from being cleaned.
      if not entry.strippable:
        inc result.skipped
        continue
      prepared.add prepare(store, entry, result.batchId, index)
  except CatchableError:
    for operation in prepared:
      if fileExists(operation.temp): removeFile(operation.temp)
    raise

  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"""
      INSERT INTO batches(id,created_at,source_root,mode,status)
      VALUES(?,?,?,'strip',?)""", result.batchId, isoNow(), store.library.root,
      $bsApplying)
    var sequence = 0
    for operation in prepared:
      for sidecar in operation.sidecars:
        store.db.exec(sql"""
          INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
            content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
          sequence, $okMove, sidecar.source,
          relativePath(sidecar.trash, store.library.root), sidecar.digest,
          $opsPending)
        inc sequence
      store.db.exec(sql"""
        INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
          content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
        sequence, $okMove, operation.media,
        relativePath(operation.mediaTrash, store.library.root),
        operation.mediaHash, $opsPending)
      inc sequence
      store.db.exec(sql"""
        INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
          content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
        sequence, $okCopy, operation.temp, operation.item.relPath,
        operation.strippedHash, $opsPending)
      inc sequence
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    for operation in prepared:
      if fileExists(operation.temp): removeFile(operation.temp)
    raise

  var sequence = 0
  for index, operation in prepared:
    var failed = false
    template transfer(source, destination: string) =
      discard store.absoluteItemPath(relativePath(destination,
        store.library.root))
      if fileExists(destination) or symlinkExists(destination):
        raise newException(IOError, "privacy strip destination is occupied")
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
      inc result.applied
    except CatchableError as error:
      failed = true
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $opsFailed, error.msg, result.batchId, sequence)
      inc result.failed
      if fileExists(operation.temp): removeFile(operation.temp)
    if failed:
      for remaining in index + 1..<prepared.len:
        if fileExists(prepared[remaining].temp): removeFile(prepared[
            remaining].temp)
      break
    if progress != nil:
      progress(ProgressEvent(phase: "privacy-strip", current: index + 1,
        total: prepared.len, message: operation.item.relPath))

  let pending = store.db.getValue(sql"""
    SELECT count(*) FROM batch_ops WHERE batch_id=? AND status='pending'""",
    result.batchId).parseInt()
  let status = if result.failed > 0 or pending > 0: bsPartial else: bsApplied
  store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $status,
    result.batchId)
  if result.failed == 0:
    discard scanLibrary(store, skipPhash = false, progress = progress)
