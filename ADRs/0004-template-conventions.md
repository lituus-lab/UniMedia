<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: UniMedia conventions

- Status: Accepted
- Date: 2026-07-31
- Scope: UniMedia and the conventions inherited from UniTemplate

## Layout

```text
UniMedia.nimble               package + tasks
nim.cfg                       engine paths + --threads:on
vgraph.cfg                    layer order, engines=[UniImage UniPercept UniCrypto]
src/UniMedia.nim              umbrella facade (re-exports every engine module)
src/UniMedia/types.nim        value types + the version constant — imports nothing local
src/UniMedia/config.nim       portable on-disk library configuration
src/UniMedia/store.nim        SQLite schema, batches and batch_ops journal
src/UniMedia/hashing.nim      BLAKE3 content digests (UniCrypto)
src/UniMedia/catalog.nim      scan, index, query, pagination
src/UniMedia/dedup.nim        exact and perceptual duplicates (UniPercept)
src/UniMedia/organize.nim     journaled, recoverable file moves
src/UniMedia/{curate,curation,batch_curation}.nim   ratings, keywords, XMP sidecars
src/UniMedia/{privacy,privacy_strip}.nim            GPS/software signal reporting and removal
src/UniMedia/{gpx,date_edit,reverse_geocode,nominatim_client}.nim  time and place correction
src/UniMedia/{people,vision,face_detect}.nim        optional local intelligence
src/UniMedia/sync.nim         deterministic manifests and staged remote pulls
src/UniMedia/cli.nim          terminal-neutral command dispatcher
src/om.nim                    process boundary — argv, exit codes, stderr
tests/                        engine, CLI and configuration suites
examples/demo.nim             engine demo
book/                         nimib book
tools/                        lint, vgraph, the nimble exit-code guard, Apple Vision helper
ADRs/                         0001-0010
.github/workflows/ci.yml      3-OS Nim, lint, docs, pages, coverage
LICENSE NOTICE CONTRIBUTING.md SECURITY.md .gitignore README.md AGENTS.md CLAUDE.md
```

## Naming

- Nim package/module: `UniMedia` (PascalCase).
- Binary: `om`, built into `bin/`.
- No C library and no Python wheel — see ADR-0003 for the eligibility gate.

## Conventions

- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. A postcondition states a cheap invariant; it never
  re-derives the result, and never repeats I/O, hashing or a query.
- English comments, terse, describing what the code does now.
- The engine never prints and never quits; only `cli.nim` and `om.nim` own
  terminal I/O.
- Library paths stored in SQLite are relative to the library root, so a
  library stays valid when its parent directory moves.
- Filesystem mutations are journaled in `batches`/`batch_ops` before they touch
  the disk, and every destructive operation has a tested undo path.
- Covered Nim sources end with a blank line, so lcov maps their final statement.
- The version lives once, in `types.nim`; a test compares it to the manifest.

## CI gates

- `nimble testCi` + `testCiRelease` + `nimble build` + `nimble example` on
  ubuntu/macOS/Windows, plus `nimble appleVision` on macOS.
- `nimble lint` and `nimble checkVGraph`.
- `nimble docs` builds the API reference and the book; `pages` publishes them.
- `nimble coverage` produces lcov + HTML on Linux.
- Every nimble step runs through `tools/nimble_task.sh`: nimble 0.22.2 exits 0
  even when a task aborts, so calling it directly would keep CI green over a
  failing build.
