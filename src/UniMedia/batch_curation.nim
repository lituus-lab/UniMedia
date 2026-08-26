# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Planned multi-item curation over the existing per-item recovery journal.

import std/sets
import UniMedia/[types, store, curation]

proc planCurationBatch*(store: Store; itemIds: seq[int64];
                        patch: CurationPatch): CurationBatchPlan =
  ## Validate the complete selection and patch without mutation.
  if itemIds.len == 0:
    raise newException(ValueError, "curation batch requires at least one item")
  validateCurationPatch(patch)
  var seen = initHashSet[int64]()
  for itemId in itemIds:
    if itemId <= 0:
      raise newException(ValueError, "curation batch item ids must be positive")
    if itemId in seen: continue
    seen.incl itemId
    let item = store.getItem(itemId)
    result.entries.add CurationBatchEntry(itemId: item.id,
      relPath: item.relPath)
  result.patch = patch

proc applyCurationBatch*(store: var Store; plan: CurationBatchPlan;
                         progress: ProgressCallback = nil;
                         cancel: CancelCallback = nil): CurationBatchReport =
  ## Each item uses curation's crash-recovery journal. Cancellation is observed
  ## only between items, never during a sidecar replacement.
  if plan.entries.len == 0:
    raise newException(ValueError, "curation batch plan is empty")
  validateCurationPatch(plan.patch)
  for entry in plan.entries:
    let item = store.getItem(entry.itemId)
    if item.relPath != entry.relPath:
      raise newException(ValueError,
        "curation batch plan is stale: " & entry.relPath)
  for index, entry in plan.entries:
    if cancel != nil and cancel():
      raise newException(OperationCancelledError,
        "curation batch cancelled after " & $result.applied & " item(s)")
    try:
      discard store.curateItem(entry.itemId, plan.patch)
      inc result.applied
    except CatchableError as error:
      inc result.failed
      result.failures.add CurationBatchFailure(itemId: entry.itemId,
        relPath: entry.relPath, error: error.msg)
    if progress != nil:
      progress(ProgressEvent(phase: "curation-batch", current: index + 1,
        total: plan.entries.len, message: entry.relPath))
