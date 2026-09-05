# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
# Its own directory per process: the book is built alongside the rest of
# the suite, and a shared path means one run wiping another's fixtures.
let sandbox = getTempDir() / ("unimedia-book-find-" & $getCurrentProcessId())
removeDir(sandbox)
createDir(sandbox)

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

for (name, red) in [("20240712_101500.ppm", 10), ("20240712_154500.ppm", 40),
                    ("20250301_090000.ppm", 90)]:
  writeFile(sandbox / name, ppm(red))

proc run(args: varargs[string]): string =
  ## A non-zero exit stops the book. Rendering the failure as output would
  ## publish a page whose "result" is an error message.
  let (output, code) = execCmdEx(om.quoteShell & " " & args.join(" "))
  if code != 0:
    raise newException(OSError,
      "book: `om " & args.join(" ") & "` exited " & $code & "\n" & output)
  output.strip().replace(sandbox, "…")

discard run("catalog init", sandbox.quoteShell, "--domain photo")
discard run("--library", sandbox.quoteShell, "catalog scan --no-phash")

nbText: """
# Finding things

Four ways in, from the cheapest to the most deliberate.

## By name

`catalog search` matches paths and filenames.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "catalog search 2024")

nbText: """
## By what a file is

`catalog filter` asks the catalogue rather than the names: a date range, a
camera, an extension, whether the file carries a position, a rating, a keyword.
"""

nbCode:
  echo run("--library", sandbox.quoteShell,
    "catalog filter --from 2025-01-01 --to 2025-12-31")

nbText: """
## By what you called it

Keywords, titles, ratings and credit are written by `curate`, into the
catalogue **and** into an XMP sidecar beside the picture — so they travel to any
other program that reads standard metadata.
"""

nbCode:
  let first = run("--library", sandbox.quoteShell,
    "catalog list --limit 1 --json")
  echo first
  echo run("--library", sandbox.quoteShell,
    "curate item set 1 --title 'Beach' --add-keyword summer --rating 4")
  echo run("--library", sandbox.quoteShell, "catalog filter --keyword summer")

nbText: """
## By a saved question

An album holds pictures you chose. A **smart album** holds a question that is
asked again every time you open it, so a picture that starts matching later
appears without you doing anything.
"""

nbCode:
  echo run("--library", sandbox.quoteShell,
    "curate smart create Kept --all --rule rating:gte:4")
  echo run("--library", sandbox.quoteShell, "curate smart list")

nbText: """
Use a plain album for a selection you made by judgement, a smart album for one
the metadata can decide. *Everything rated four or more from 2026* is a smart
album; *the ones I liked from the trip* is not.
"""

nbSave
