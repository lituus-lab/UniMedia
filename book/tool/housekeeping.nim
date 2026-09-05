# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
let sandbox = getTempDir() / "unimedia-book-house"
removeDir(sandbox)
createDir(sandbox / "2024" / "07" / "12")
createDir(sandbox / "emptied")

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

writeFile(sandbox / "2024" / "07" / "12" / "20240712_101500.ppm", ppm(30))
writeFile(sandbox / "2024" / "07" / "12" / "20240712_101500.xmp", "<x/>")
writeFile(sandbox / "2024" / "07" / "12" / "gone.xmp", "<x/>")
writeFile(sandbox / ".DS_Store", "x")
writeFile(sandbox / ".om-tmp-abandoned", "x")

proc run(args: varargs[string]): string =
  let (output, _) = execCmdEx(om.quoteShell & " " & args.join(" "))
  output.strip().replace(sandbox, "…")

discard run("catalog init", sandbox.quoteShell, "--domain photo")
discard run("--library", sandbox.quoteShell, "catalog scan --no-phash")

nbText: """
# Housekeeping

Two commands: one takes away what accumulates around a library without
belonging to it, the other decides when that becomes permanent.

## Cleaning up

Five kinds of litter, kept apart because they do not carry the same risk.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "cleanup")

nbText: """
`.DS_Store` was written by a file browser. `.om-tmp-abandoned` is what a run
that did not finish left. `gone.xmp` describes a picture that is not there, while
`20240712_101500.xmp` is left alone because its picture is beside it. And
`emptied/` held nothing.

`--kind` narrows it: `apple-double`, `os-junk`, `orphan-sidecar`, `empty-dir`,
`interrupted`.

### The one that is read before it is proposed

On a filesystem that cannot hold extended attributes beside a file — a network
share, an exFAT disk — macOS writes them into a companion named `._something`.
Most hold nothing worth keeping. Some hold a Finder tag, a comment, or a real
resource fork.

So each one is **parsed**, and one carrying anything but a housekeeping marker
is reported with what it holds rather than taken:

```
REMOVE  apple-double  ._IMG_7265.HEIC  holds only com.apple.provenance
KEEP    apple-double  ._IMG_9901.HEIC  carries com.apple.metadata:_kMDItemUserTags
```

A tool that deleted these by name would be quick, and would erase tags nobody
could restore.

## The trash

Everything removed is kept until you say otherwise.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "cleanup --yes")
  echo run("--library", sandbox.quoteShell, "trash list")

nbText: """
`undoable` needs two things at once: a batch that was applied, and files still
there to put back. Either alone is not a way back.

## Emptying it

This is the only action here with no way back.
"""

nbCode:
  echo run("--library", sandbox.quoteShell, "trash empty --yes")
  echo run("--library", sandbox.quoteShell, "undo apply --last --yes")

nbText: """
The refusal is named rather than discovered. Emptying marks the batch, so undo
answers once instead of failing on every path it cannot find.

`trash empty --older-than 30` takes only what has been there a month; naming
batches takes only those.

## Deleting outright

`cleanup --permanently` and `items remove --permanently` skip the trash
altogether. They exist for one measured reason: on a network share, trashing
44299 files and then emptying them is twice the work of deleting them once.

Three things change, and they are meant to be hard to miss — the plan says
`DELETE` rather than `REMOVE`, the report does not mention undo, and **no batch
identifier is returned**, because handing one back would read as a way that does
not exist.

Neither `privacy strip` nor `dedup remove` offers it. There the original is the
only unmodified copy of a photograph, or a file the engine judged expendable
rather than one you pointed at.
"""

nbSave
