<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniMedia

## Build gates

```bash
nimble buildOm
nimble test
nimble testRelease
nimble testAll
nimble lint
nimble checkVGraph
nimble docs
nimble coverage
```

## Conventions

- English comments, terse and current.
- The engine never prints or quits; only `cli.nim` and `src/om.nim` own terminal
  I/O.
- Library paths stored in SQLite are relative to the library root.
- Filesystem mutations must be journaled in `batches`/`batch_ops` first.
- New destructive operations require a tested undo path.
- NimContracts state cheap public pre/postconditions and compile away in release.
- Covered Nim sources end with a blank line so lcov maps their final statement.

## Scope

Shared Nim engine and the `om` CLI. GTK and Studio code do not belong here.
A C ABI and a Python extension are published like everywhere else in the family
(ADR-0011); opaque handles only, and the schema never crosses them.
