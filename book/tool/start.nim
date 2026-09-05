# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

# Every command on these pages is run against a library built here, and its
# real output is printed beneath it. Prose that outlived the tool fails the
# build instead of misleading somebody.
# From this file, not from the working directory: nimibook compiles a chapter
# with its own folder as the current one, so a relative path lands elsewhere.
const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
  # Its own directory per process: the book is built alongside the rest of
  # the suite, and a shared path means one run wiping another's fixtures.
let sandbox = getTempDir() / ("unimedia-book-tour-" & $getCurrentProcessId())
removeDir(sandbox)
createDir(sandbox / "inbox")

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

# Names carrying their own date, as a camera writes them.
for (name, red) in [("20240712_101500.ppm", 10), ("20240712_154500.ppm", 40),
                    ("20250301_090000.ppm", 90), ("holiday.ppm", 60)]:
  writeFile(sandbox / "inbox" / name, ppm(red))

proc run(args: varargs[string]): string =
  ## A non-zero exit stops the book. Rendering the failure as output would
  ## publish a page whose "result" is an error message.
  let (output, code) = execCmdEx(om.quoteShell & " " & args.join(" "))
  if code != 0:
    raise newException(OSError,
      "book: `om " & args.join(" ") & "` exited " & $code & "\n" & output)
  output.strip()

nbText: """
# Using the tool

A folder of photographs becomes a library in one command, and everything else
follows from that. This page builds a small one and files it; the pages after it
search, de-duplicate and correct the same library.

The commands below were run to produce the output shown. If the tool changes
and the prose does not, this page stops building.

## A folder becomes a library

`catalog init` writes the two dotfiles and nothing else. `--domain` says what
the library takes in — `photo`, `video`, `visual` for both, or `music`.
"""

nbCode:
  echo run("catalog init", sandbox.quoteShell, "--domain photo")

nbText: """
## Reading what is there

`catalog scan` opens every file and records what it finds: dimensions, capture
date, camera, position, and a digest of the contents. It reads the files rather
than trusting their names — a HEIC saved as `.jpg` is measured correctly instead
of failing as a malformed JPEG.

Nothing is moved. A scan only learns.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "catalog scan --no-phash")

nbText: """
`--no-phash` skips the perceptual fingerprints. They are most of a scan's cost
and only duplicate detection reads them, so they are worth deferring until you
want that.

## What it learned

The dates below did not come from the filesystem. Three files carry their date
in their name; the fourth carries none, and is reported as undated rather than
given the date it happened to be written.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "catalog list")

nbText: """
## Preferences

The two lines that decide how dates are found, and one that decides where
undated files go.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "config show")

nbText: """
`birthtimeDate` is off, and that is a deliberate refusal. The filesystem's
creation time is always available, which makes it tempting — but on a copied or
restored library it is the date of the copy. Accepting it would date every
photograph in a backup to the day the backup ran. A file with nothing better is
reported as undated instead, and filed under `noDateDir`.

Turn it on if you want it:

```
om --library DIR config set birthtimeDate=true
```
"""

nbSave
