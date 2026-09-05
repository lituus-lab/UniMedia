# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, strutils]
import nimib, nimibook
# The modules a caller actually needs, not the umbrella. Importing narrowly is
# how a consumer avoids dragging in a codec it never calls — and it is what this
# page is showing.
import UniMedia/[types, store, catalog, cleanup]

nbInit(theme = useNimibook)

nbText: """
# Building on it

Three ways in, resting on the same engine. Nim is the native one; Python and the
C ABI are bindings over the same calls, so what is true here is true there.

Two rules hold across all three.

**Nothing crosses a boundary but a handle and JSON.** The database schema is
never exposed: a caller receives what an operation reports, not a row.

**Plan and apply are separate calls**, and apply rebuilds the plan. A caller
cannot act on a stale one.

## Opening a library
"""

let sandbox = getTempDir() / "unimedia-book-api"
removeDir(sandbox)
createDir(sandbox)
writeFile(sandbox / "20240712_101500.ppm",
  "P3\n2 2\n255\n" & repeat("20 0 0\n", 4))

nbCode:
  discard initLibrary(sandbox, mdPhoto)
  var library = openLibrary(sandbox)
  echo "domain ", library.library.config.domain
  echo "scheme ", library.library.config.scheme

nbText: """
`initLibrary` refuses a directory that already holds one rather than
overwriting it. `openLibrary` raises where there is none — a missing catalogue
is not an empty one.

## Reading what is there
"""

nbCode:
  let report = scanLibrary(library, skipPhash = true)
  echo "indexed ", report.indexed, ", errors ", report.hashErrors
  for item in library.listItems():
    echo item.relPath, "  ", item.creationDate, "  from ", item.dateSource

nbText: """
`skipPhash` defers the perceptual fingerprints, which are most of a scan's cost.
The catalogue records the two hash states independently, so a later scan
computes what is owed rather than starting again.

## Plan, then apply

Every destructive operation is two calls. The plan is a value you can inspect,
count and show; the apply takes it and rebuilds it.
"""

nbCode:
  writeFile(sandbox / ".DS_Store", "x")
  let plan = planCleanup(library)
  for entry in plan.entries:
    echo entry.kind, "  ", entry.relPath, "  removable=", entry.removable
    echo "    ", entry.reason

nbText: """
`removable` and `reason` are both part of the plan, and a caller that shows only
the first is hiding the interesting half: an entry that will **not** be taken is
reported precisely so somebody knows it is there.

## Contracts

The engine uses NimContracts. A precondition states what a correct **caller**
must not do, and compiles away under `-d:release`. Anything derived from a file
— a length, a count, a timescale — is checked in the body and raises instead,
because a precondition that disappeared in release would leave a release build
writing a malformed file in silence.

The practical consequence for a caller: a `Defect` means the calling code is
wrong, an exception means the data was.
"""

library.close()
removeDir(sandbox)

nbSave
