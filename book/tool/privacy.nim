# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"

nbText: """
# What a photograph discloses

`privacy audit` opens every catalogued file and reports what it still carries.

| Signal | What it is |
|---|---|
| `gps` | Where the file was made |
| `camera` | The make, model and serial of the device |
| `software` | What edited it, and when |
| `identity` | Names, owners, copyright holders, contact details |

On a real library of 176579 files, 164559 disclosed something: 160074 named the
camera, 141364 named the software, 42078 carried an identity, 19853 a position.

A file the audit cannot read is counted separately. **It is not clean, it is
unknown**, and the difference matters more than the count.

## Video was invisible

The audit read Exif only, so a recording produced no signals *and* no error. Its
position went unreported, and silence in an audit reads as nothing to worry
about — which is the one thing it must never mean. It now consults the container
as well.

## Stripping

The plan says what will happen to each file, in two words that are not
interchangeable:

```
SKIP    clip.mov     gps
STRIP   photo.heic   camera,gps,software
```

`STRIP` rewrites the file. `SKIP` means it carries the metadata and this tool
cannot rewrite that format — the disclosure is real, and saying nothing about it
would read as clean.

Which formats can be rewritten was **measured against the editor**, not assumed:

| JPEG | PNG | HEIC | AVIF | WebP | TIFF | video |
|---|---|---|---|---|---|---|
| yes | yes | yes | yes | yes | no | no |

HEIC looks like it would not and does; TIFF looks like it would and does not. A
camera roll is mostly HEIC, so guessing that one wrong would have meant a
privacy tool that could clean almost nothing in it.

One unsupported file does not stop the batch: a roll of photographs is cleaned
even with a recording in the middle of it. The report counts three outcomes —
stripped, passed over, failed — because a file that was passed over is neither
cleaned nor a failure, and counting it as either misstates what happened.

The originals are kept. `undo last` restores them.
"""

nbSave
