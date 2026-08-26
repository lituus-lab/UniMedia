<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0007: Make duplicate removal recoverable

## Status

Accepted.

## Context

Deleting a duplicate immediately would make `undo` dishonest and would cascade
through album membership, curation and hash history. Keeping a missing item in
normal catalogue reads would make every consumer handle inconsistent paths.

## Decision

Schema v9 adds nullable `items.deleted_at`. Public catalogue projections include
only active items, while soft-deleted rows and their foreign-key relationships
remain stored. A scan resurrects an item if the file reappears at its canonical
path, even when size and mtime are unchanged.

`planDedupRemoval` selects each non-keeper at most once. `applyDedupRemoval`
journals a `delete` batch, persists each content hash before touching the
filesystem, then atomically moves media and existing XMP sidecars below
`.om-trash/<batch>/<item>/`. The internal directory is excluded from scans.

Recovery accepts a trash file only when its source is absent and its hash equals
the durable journal value. Undo processes operations in reverse, verifies the
same hash, restores sidecars and media, then clears `deleted_at`. Changed trash
content, occupied originals, symbolic links and path escapes fail closed.

## Consequences

The default `om dedup remove` is a read-only plan; `--yes` applies it. Restored
items retain IDs, albums, covers, curation and smart-album behavior. Trash is
retained until undo or a future explicit purge policy; no automatic purge is
part of this decision.
