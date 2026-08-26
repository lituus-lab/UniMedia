# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Reading and emptying what a recoverable removal kept.
##
## Every destructive operation here moves files into `.om-trash` under the
## library root and journals what it moved, which is what makes `undo` possible.
## Nothing read that back and nothing ever emptied it: the space stayed occupied
## until somebody deleted the directory by hand, and the promise that a removal
## is recoverable was invisible to whoever wanted to check it.
##
## Emptying is where recoverability ends, so it is deliberate. A batch that has
## been emptied is marked, and `undo` refuses it by name rather than failing
## file by file on paths that are no longer there.

import std/[os, times]
import db_connector/db_sqlite
import UniMedia/[types, store]

proc trashRoot(store: Store): string =
  ## Where the trash lives for this library.
  store.library.root / TrashDirName

proc batchDir(store: Store; batchId: string): string =
  ## Where one batch kept what it took.
  trashRoot(store) / batchId

proc measure(directory: string): tuple[files: int; bytes: int64] =
  ## How much a directory is holding, files and bytes.
  if not dirExists(directory): return
  for path in walkDirRec(directory):
    if symlinkExists(path) or not fileExists(path): continue
    inc result.files
    result.bytes += (try: getFileSize(path) except CatchableError: 0'i64)

proc listTrash*(store: Store): seq[TrashBatch] =
  ## Every batch that put something in the trash, newest first.
  ##
  ## A batch appears even when its directory is gone — emptied earlier, or never
  ## written because every operation failed. A count of zero says so, which is
  ## better than hiding the row that explains a status.
  for row in store.db.getAllRows(sql"""
      SELECT id, created_at, mode, status FROM batches
      ORDER BY created_at DESC"""):
    let held = measure(batchDir(store, row[0]))
    result.add TrashBatch(batchId: row[0], createdAt: row[1], mode: row[2],
      status: row[3], fileCount: held.files, totalBytes: held.bytes,
      # Undoing needs both a batch that was applied and the files it kept.
      undoable: row[3] in [$bsApplied, $bsPartial] and held.files > 0)

proc olderThan(createdAt: string; days: int): bool =
  ## Whether a batch predates the cut-off.
  ##
  ## A date that will not parse counts as recent: refusing to empty something is
  ## the safe direction for a question whose wrong answer deletes files.
  if days <= 0: return true
  let stamp = try: parse(createdAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    except TimeParseError: return false
  (now().utc - stamp).inDays >= days

proc planEmptyTrash*(store: Store; batches: seq[string] = @[];
                     olderThanDays = 0): seq[TrashBatch] =
  ## Which batches an empty would take, taking none.
  ##
  ## The batches named, or every one old enough when none are. A batch holding
  ## nothing is left out: there is no space to reclaim and no recoverability
  ## left to end.
  for batch in listTrash(store):
    if batch.fileCount == 0: continue
    if batches.len > 0:
      if batch.batchId notin batches: continue
    elif not olderThan(batch.createdAt, olderThanDays): continue
    result.add batch

proc emptyTrash*(store: var Store; batches: seq[string] = @[];
                 olderThanDays = 0;
                 progress: ProgressCallback = nil): TrashReport =
  ## Delete what those batches kept. **This is where recoverability ends.**
  ##
  ## The files go for good; there is no second trash behind this one. The batch
  ## is marked first, so an interruption leaves one that `undo` refuses by name
  ## rather than one that fails halfway through restoring files already gone.
  let chosen = planEmptyTrash(store, batches, olderThanDays)
  if chosen.len == 0:
    raise newException(ValueError,
      "nothing in the trash matches; `trash list` shows what is there")
  for index, batch in chosen:
    store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $bsEmptied,
      batch.batchId)
    try:
      removeDir(batchDir(store, batch.batchId), checkDir = false)
      inc result.batches
      result.files += batch.fileCount
      result.freedBytes += batch.totalBytes
    except CatchableError:
      inc result.failed
    if progress != nil:
      progress(ProgressEvent(phase: "trash-empty", current: index + 1,
        total: chosen.len, message: batch.batchId))

proc trashHolding*(store: Store): tuple[files: int; bytes: int64] =
  ## What the whole trash occupies, for a screen that wants one number.
  measure(trashRoot(store))

