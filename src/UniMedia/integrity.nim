# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Read-only consistency checks for a UniMedia library.

import std/[os, strutils]
import db_connector/db_sqlite
import UniMedia/[types, store, hashing]

proc addFinding(report: var IntegrityReport; item: Item; kind, detail: string) =
  report.findings.add IntegrityFinding(itemId: item.id, relPath: item.relPath,
    kind: kind, detail: detail)

proc auditIntegrity*(store: Store; verifyHashes = true;
                     progress: ProgressCallback = nil;
                     cancel: CancelCallback = nil): IntegrityReport =
  ## Verify database constraints and active catalogue files without mutation.
  let quickCheck = store.db.getValue(sql"PRAGMA quick_check")
  if quickCheck != "ok":
    inc result.databaseErrors
    result.findings.add IntegrityFinding(kind: "database", detail: quickCheck)
  for row in store.db.getAllRows(sql"PRAGMA foreign_key_check"):
    inc result.databaseErrors
    result.findings.add IntegrityFinding(kind: "foreign-key",
      detail: row.join(":"))

  let items = store.listItems()
  for index, item in items:
    checkCancelled(cancel)
    # An item with no file of its own has no path, size or digest to verify.
    if item.source != "file": continue
    inc result.checked
    let path = store.absoluteItemPath(item.relPath)
    if symlinkExists(path):
      inc result.changed
      result.addFinding(item, "symbolic-link",
        "catalogue media must not be a symbolic link")
    elif not fileExists(path):
      inc result.missing
      result.addFinding(item, "missing", "catalogued file is absent")
    else:
      try:
        let size = getFileSize(path)
        if size != item.fileSize:
          inc result.changed
          result.addFinding(item, "size", "expected " & $item.fileSize &
            " bytes, found " & $size)
        elif verifyHashes:
          let expected = store.db.getValue(
              sql"""
            SELECT h.blake3 FROM item_hashes h JOIN items i ON i.id=h.item_id
            WHERE i.id=? AND i.hash_status='hashed'""", item.id)
          if expected.len == 0:
            inc result.changed
            result.addFinding(item, "hash-state", "exact hash is unavailable")
          elif blake3File(path, cancel = cancel) != expected:
            inc result.hashMismatches
            result.addFinding(item, "hash", "content hash does not match")
      except OperationCancelledError:
        raise
      except CatchableError as error:
        inc result.changed
        result.addFinding(item, "read", error.msg)
    if progress != nil:
      progress(ProgressEvent(phase: "integrity", current: index + 1,
        total: items.len, message: item.relPath))
