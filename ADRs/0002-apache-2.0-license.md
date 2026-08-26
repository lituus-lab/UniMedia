<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0002: Apache License 2.0 for UniMedia

- Status: Accepted
- Date: 2026-07-15
- Scope: UniMedia

## Decision

UniMedia is distributed under Apache-2.0, as are the UniImage, UniPercept and
UniCrypto engines it consumes. `db_connector`, `malebolgia`, `nimib`,
NimContracts and nimsimd remain external MIT-licensed dependencies; the
repository vendors none of them.

The repository ships `LICENSE`, `NOTICE`, and `CONTRIBUTING.md` with DCO
requirements. Apache-2.0 grants an explicit patent licence; `NOTICE` records the
provenance and the external dependencies.
