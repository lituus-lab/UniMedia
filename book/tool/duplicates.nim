# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
let sandbox = getTempDir() / "unimedia-book-dupes"
removeDir(sandbox)
createDir(sandbox)

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

writeFile(sandbox / "20240712_101500.ppm", ppm(20))
writeFile(sandbox / "copy_of_the_same.ppm", ppm(20)) # identical, other name
writeFile(sandbox / "20250301_090000.ppm", ppm(70)) # its own picture

proc run(args: varargs[string]): string =
  let (output, _) = execCmdEx(om.quoteShell & " " & args.join(" "))
  output.strip().replace(sandbox, "…")

discard run("catalog init", sandbox.quoteShell, "--domain photo")
discard run("--library", sandbox.quoteShell, "catalog scan --no-phash")

nbText: """
# Duplicates

Two questions that look alike and are not: *are these the same bytes*, and *do
these look alike*. The first has an answer; the second has a threshold.

| Search | Basis |
|---|---|
| `exact` | The bytes. A match or not. |
| `visual` | A perceptual fingerprint of the picture. |
| `audio` | An acoustic fingerprint of the sound. |
| `all` | The three at once. |

Only `exact` is a fact. The others are judgements, and `--threshold` says how
close counts.

## Finding them

The library below holds a picture, a copy of it under another name, and a
different picture.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "dedup find --kind exact")
  echo run("--library", sandbox.quoteShell, "dedup review")

nbText: """
One group, two members, one of them marked `KEEP`. The keeper is not a
judgement about quality — look before removing.

`dedup keep GROUP ITEM` moves the mark. The engine protects a keeper across
every overlapping group, so a contradictory choice removes fewer files rather
than deleting one you marked.

## Removing them
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "dedup remove")

nbText: """
A plan, as everywhere. `--yes` applies it, the non-keepers move to the trash,
and `undo` brings them back.

## Linking instead

For byte-identical files only, the duplicate can become a hard link to the
keeper: the bytes exist once, and every path that existed still opens. Nothing
that reads those paths can tell.

This is offered for exact matches and no others, for a reason worth stating.
Two files that merely look alike are not interchangeable, and replacing one with
a link to the other silently discards a picture.

The contents are re-verified by digest at the moment of linking rather than
trusted from the search, and the operation goes through the trash first — so the
same `undo` restores separate copies.

Hard links need a filesystem that has them. A network share and an exFAT disk
both refuse, and there is no list of which mounts do, so UniMedia **makes a real
link at the library root before anything moves** and refuses the whole operation
if it cannot. Without that check, linking would move a whole library to the
trash and then fail on every link.
"""

nbSave
