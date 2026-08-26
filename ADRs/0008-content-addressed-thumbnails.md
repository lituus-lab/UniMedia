<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0008: Content-addressed display thumbnails

## Status

Accepted.

## Context

The Studio library grid needs bounded, display-oriented rasters. Implementing
decode, EXIF orientation and cache policy in the GUI would duplicate engine
semantics and make headless testing impossible. Cache identity must survive
renames while invalidating when content or processing rules change.

## Decision

UniMedia owns thumbnail generation through `ensureThumbnail`. Only active image
items with a valid catalogue BLAKE3 hash are eligible. Source size and mtime
must still match the catalogue; otherwise the caller must rescan.

Pixels are decoded by UniImage, normalized using the complete EXIF Orientation
mapping, and reduced with the box filter while preserving aspect ratio and
never enlarging. Version 1 stores PNG so grayscale, RGB and alpha inputs share
one lossless, dependency-free output contract. WebP is not used until UniImage
has a maintained encoder; JPEG would require an arbitrary alpha-flattening
policy.

Entries live below `.om-cache/thumbnails/<digest-prefix>/` and are named from
the lowercase BLAKE3 digest, algorithm version and requested maximum edge.
Writes use a sibling temporary file followed by rename. Corrupt entries are
regenerated. Symbolic cache components and entries are rejected.

## Consequences

The CLI and Studio consume identical rasters and invalidation behavior. Renames
reuse cached content. Cache storage can grow with content and requested sizes;
bounded eviction is a later policy and does not change cache identity. Video
poster frames remain a separate feature because they require a decoder and a
timestamp policy rather than an image-thumbnail fallback.
