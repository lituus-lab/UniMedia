<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0005: Journal item curation to preserving XMP sidecars

## Status

Accepted.

## Context

The catalogue and filesystem cannot participate in one atomic transaction.
Writing only SQLite would create metadata lock-in; writing only XMP would make
queries expensive. Rebuilding a known subset of XMP would also destroy
third-party metadata.

## Decision

Schema v5 stores the queryable projection in `item_curations` and records each
cross-resource mutation in `curation_ops` before touching the filesystem.
UniImage's preserving merge changes only `dc:title`, `dc:description`,
`dc:subject`, `xmp:Rating`, `om:Favorite`, `xmp:CreateDate`,
`exif:GPSLatitude`, `exif:GPSLongitude` and `Iptc4xmpCore:Location`. The `om` namespace is
`https://lituus-lab.com/ns/organize-media/1.0/`.

Existing unrelated XMP structures and namespaces are preserved. Existing
`media.ext.xmp` or `media.xmp` sidecars are reused, in that order; new sidecars
use `media.ext.xmp` to avoid collisions between equal stems with different
extensions. Sidecars and every path component must not be symbolic links.

The operation journal contains the exact old/new packets and desired catalogue
state. A temporary file and an operation-specific backup make replacement
recoverable. An immediate SQLite transaction serializes verification,
filesystem replacement, catalogue update and journal finalization. Recovery
replays only a known old state or accepts the exact desired packet. Any other
content is treated as an external edit and is not overwritten.

Schema v7 adds latitude, longitude and location to the canonical item
projection. Schema v8 adds that projection plus creation date and source to
every journal entry. Migrating a pending v7 operation snapshots its current
item values, preventing recovery from clearing pre-existing metadata. A
curated date, including an explicit empty date, keeps the `curation` source so
later scans do not replace the user's decision.

Coordinates are accepted only as a complete finite pair within latitude and
longitude ranges. XMP writes use the standard degrees/minutes plus hemisphere
form. Clearing GPS removes both properties atomically; a location label remains
independent because it can be useful without exact coordinates.

## Consequences

CLI and future GUI consumers see one SQLite projection, while portable XMP
remains the durable interchange representation. Operation history costs extra
database space and is retained for auditability. Zero lock-in applies to the
managed fields above; arbitrary application state is not claimed to be XMP.
