<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0009: Optional external media process boundary

Status: accepted — 2026-08-01, amended 2026-08-18 (probing moved in process)

## Context

UniImage intentionally does not ship HEVC or AV1 decoders. Video containers and
HEIC/AVIF therefore need an optional decoder, but UniMedia must remain Apache-2.0,
easy to distribute, and independent from codec patent or copyleft choices.

## Decision

UniMedia may discover the system `ffmpeg` executable at runtime. It neither
links nor bundles FFmpeg. Calls use argument vectors without a shell, reject
symbolic inputs, have a 30-second timeout, bounded output, randomly named
temporary files, and deterministic cleanup.

The adapter decodes one bounded RGBA frame, and that is all it does. What a
file *is* — tracks, dimensions, rotation, duration — is read in process by
`UniMovie`, and the size of a HEIC or AVIF still by `UniImage`'s HEIF reader;
neither decodes anything, so neither carries a patent question. `ffprobe` was
what answered those before and is no longer used.

The adapter powers video thumbnails and the HEIC/HEIF/AVIF fallback. Normal
UniImage formats continue to use the in-process decoder. A missing adapter never
prevents exact catalogue indexing, and now never prevents a video being
catalogued either — only its preview fails, with an actionable error.

Distributors must select and document their FFmpeg build. FFmpeg is LGPL-2.1-or-
later in its base configuration, while optional components can make a build GPL
or add codec patent considerations. UniMedia makes no codec available itself.

## Consequences

There is one audited external-process boundary instead of format-specific shell
commands. Feature availability depends on the installed FFmpeg build, and tests
exercise the integration conditionally when both executables are present.

