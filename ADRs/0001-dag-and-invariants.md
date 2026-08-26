<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: UniMedia dependency direction

- Status: Accepted
- Date: 2026-07-15
- Scope: UniMedia

## Decision

UniMedia is an application layer over three engines and imports only downwards.
No engine imports UniMedia.

```text
UniImage   -> decode, EXIF/XMP read and rewrite
UniPercept -> perceptual hashes, BK-tree neighbour search
UniCrypto  -> BLAKE3 content digests
                    \
                     -> UniMedia engine modules -> cli -> om
```

The engine modules themselves form a chain that never climbs, checked by
`nimble checkVGraph` against `vgraph.cfg`:

```text
types < config < store < external_media < hashing < catalog < timeline
      < privacy < curate < curation < smartalbums < organize < dedup
      < thumbnails < integrity < privacy_strip < batch_curation < date_edit
      < gpx < reverse_geocode < nominatim_client < people < vision < sync
      < face_detect < cli
```

## Invariants

1. `types.nim` imports no other engine module; it holds value types only.
2. Only `cli.nim` and `om.nim` own terminal I/O. The engine never prints or
   quits, so the same modules serve the CLI and a future Studio unchanged.
3. Each engine is used for what it owns: UniMedia re-implements no decoder, no
   perceptual hash and no digest of its own.
4. UniMedia never imports an application, and nothing in the family imports
   UniMedia.
5. The engines and NimContracts track their maintained default branches, not a
   pinned revision — a pin dies the moment a branch's history is rewritten.

## Consequences

The engines are consumed as sibling checkouts rather than installed packages,
because a `nimble` path dependency carries none of its own transitive
requirements: `nim.cfg` therefore also supplies UniColor, which UniImage's
quantizer needs, and nimsimd, which UniCrypto's BLAKE3 kernels need. CI
reproduces that directory layout. This is a packaging constraint, not an
exception to the direction above.
