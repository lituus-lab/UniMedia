# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
  # Its own directory per process: the book is built alongside the rest of
  # the suite, and a shared path means one run wiping another's fixtures.
let sandbox = getTempDir() / ("unimedia-book-places-" & $getCurrentProcessId())
removeDir(sandbox)
createDir(sandbox)
writeFile(sandbox / "20360401_170332.ppm",
  "P3\n2 2\n255\n" & repeat("30 0 0\n", 4))

proc run(args: varargs[string]): string =
  ## A non-zero exit stops the book. Rendering the failure as output would
  ## publish a page whose "result" is an error message.
  let (output, code) = execCmdEx(om.quoteShell & " " & args.join(" "))
  if code != 0:
    raise newException(OSError,
      "book: `om " & args.join(" ") & "` exited " & $code & "\n" & output)
  output.strip().replace(sandbox, "…")

discard run("catalog init", sandbox.quoteShell, "--domain visual")
discard run("--library", sandbox.quoteShell, "catalog scan --no-phash")

nbText: """
# Dates and places

A camera with a wrong clock stamps every recording it makes. The picture below
says 2036 — a real case, from a real library, where a battery change reset the
clock.

## Correcting a date
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "catalog list")
  # `quoteShell` rather than apostrophes: it quotes for the platform, and
  # cmd.exe does not treat an apostrophe as one -- the timestamp would arrive
  # as two arguments there.
  echo run("--library", sandbox.quoteShell, "dates set",
    "2019-08-14 10:30:00".quoteShell, "1")

nbText: """
`DATE` means the correction reaches the file. `CATALOG` would mean it does not,
and that distinction is the point of the two words: a date fixed only in the
catalogue leaves every other program reading the wrong one.

UniImage rewrites the Exif carriers — JPEG, PNG, HEIC, AVIF, WebP. UniMovie
rewrites ISO base media headers — MOV, MP4, M4V — by replacing fixed-width
fields, so no byte moves and the sample tables stay valid. Anything else is
corrected in the catalogue alone and counted apart.

The whole rewrite is one journalled batch. `undo` restores the originals byte
for byte.

`dates shift SECONDS` moves a whole batch by an offset, for a clock that was
consistently wrong. A camera an hour behind is `3600`.

## Positions from a track

`gpx match FILE` places photographs by time against a `.gpx` recording.

A photograph that **already carries a position is left alone** — a camera's own
fix beats one interpolated from a logger — and it is reported as kept rather
than as unmatched. Only the second is fixed by widening `--tolerance`, so
folding them together would send you to change a setting that cannot help.

`--refresh` places them anyway.

## Names for coordinates

Coordinates say where; they do not say *Sydney*. `geo reverse` asks a geocoder,
and nothing is implicit about which one: it names no default endpoint and makes
no request unless you ask for one. Without `--network` it answers from the
cache alone, and `--network` is refused unless `--endpoint` and `--user-agent`
come with it.

Coordinates are among the most revealing things a photograph carries, so the
endpoint is worth choosing rather than accepting: one you run yourself, or one
you trust with the positions of your own pictures.

[Nominatim](https://nominatim.openstreetmap.org) is OpenStreetMap's own and the
obvious public choice. It is free and needs no account, and asks two things in
return:

- **A user agent naming you.** The command refuses without one. That is
  Nominatim's usage policy, not a formality — anonymous bulk traffic is blocked.
- **At most one request per second.** A thousand distinct places takes about
  twenty minutes. Answers are cached, so a second run over the same library
  costs nothing, and an afternoon in one town is a handful of lookups.

Results carry OpenStreetMap's attribution, which the ODbL licence requires when
the data is passed on.
"""

nbSave
