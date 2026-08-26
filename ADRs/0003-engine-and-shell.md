<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: Engine, CLI, and foreign-language eligibility

- Status: Accepted; its foreign-language sections are superseded by
  [ADR-0011](0011-c-abi.md), which opens the C ABI and drops Python. The
  engine/shell split and the thread and cancellation contract below stand.
- Date: 2026-07-31
- Scope: UniMedia

## Decision

UniMedia is a Nim engine with a thin CLI in the same repo. The future Studio
imports the Nim engine directly. CLI parsing and terminal output never enter the
engine modules.

UniMedia publishes no C ABI and no Python wheel. The engine is technically
eligible, but its stateful surface is not stable enough to become a compatibility
contract. A useful ABI would require opaque library handles, explicit ownership,
thread-local errors, cancellation/progress callbacks, two-call UTF-8/JSON output
buffers, and versioned option structs. Exposing Nim objects, SQLite handles, or
raw callbacks directly is forbidden.

## Eligibility gate

C/Python work may start when all conditions hold:

1. SQLite schema and migration policy have survived a released version.
2. Scan, organize, undo, and dedup error categories are closed and documented.
3. Cancellation and thread ownership semantics are tested.
4. The minimal ABI can expose opaque `um_library` and immutable report handles
   without leaking paths or allocations across the boundary.
5. A C header/test and a Cython wheel can cover the same stable subset.

The first candidate subset is version, open/close, scan, item listing, duplicate
find/review, and organize planning. Mutating apply/undo enter only after crash
recovery semantics are frozen.

## Studio thread and cancellation contract

The owner of a `Store` is the thread that opened it. A Studio background job
opens and closes its own `Store`; GTK widgets never retain or share SQLite
handles across threads. Results crossing back to the GTK thread are immutable
value objects.

Read/compute operations may expose cooperative cancellation at explicit loop
boundaries. Cancellation raises `OperationCancelledError` and rolls back the
active SQLite transaction. Journaled filesystem mutations deliberately do not
offer cancellation after apply starts: interruption is handled by their tested
recovery protocol, not by an unsafe UI-level exception between filesystem and
database commits.

## Consequences

CI currently has no C ABI or Python jobs. This is an explicit product decision,
not missing scaffolding. When the gate is met, add those jobs and layouts and
record the ABI in its own ADR.
