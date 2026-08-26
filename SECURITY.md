<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Security Policy

Report vulnerabilities via GitHub private vulnerability reporting (Security
tab → "Report a vulnerability"), not via a public issue. Include: description
+ impact, minimal reproducer, affected `om --version` output.

Only the latest released line is supported. UniMedia exposes no foreign ABI.

## Surface

- Media paths, metadata and SQLite contents are untrusted inputs.
- Filesystem mutations are journaled and verified by BLAKE3 before undo.
- The engine is stateful and not reentrant through a shared `Store`; callers own
  a store on one thread and open separate connections for concurrent readers.
- Reports must not include credentials or private metadata fixtures.
