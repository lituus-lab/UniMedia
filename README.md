<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniMedia

Local-first media engine and the `om` CLI: one media directory is one
library, catalogued in place, with every stored path relative to its root.

## The Uni* family

UniMedia is the consumer at the top of the family DAG. It reads containers
through [UniMovie](https://github.com/lituus-lab/UniMovie), images through
[UniImage](https://github.com/lituus-lab/UniImage), sound through
[UniAudio](https://github.com/lituus-lab/UniAudio), perceptual hashes through
[UniPercept](https://github.com/lituus-lab/UniPercept) and content digests
through [UniCrypto](https://github.com/lituus-lab/UniCrypto). Nothing depends
on it. See [lituus-lab/.github](https://github.com/lituus-lab/.github) for the
family's purpose and philosophy.

## Licence

Apache-2.0, with DCO sign-off on every commit. See `LICENSE`, `NOTICE` and
`CONTRIBUTING.md`.
