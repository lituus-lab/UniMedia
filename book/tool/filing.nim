import std/[os, osproc, strutils]
import nimib, nimibook

nbInit(theme = useNimibook)

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir
let om = RepoRoot / "bin" / "om"
let sandbox = getTempDir() / "unimedia-book-filing"
removeDir(sandbox)
createDir(sandbox / "library")
createDir(sandbox / "inbox" / "camera")
createDir(sandbox / "inbox" / "backup")

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

# A folder holding its own backup: the same pictures twice, plus one that is
# only in the copy.
for name in ["20240712_101500.ppm", "20240712_154500.ppm"]:
  writeFile(sandbox / "inbox" / "camera" / name, ppm(20))
  writeFile(sandbox / "inbox" / "backup" / name, ppm(20))
writeFile(sandbox / "inbox" / "backup" / "20250301_090000.ppm", ppm(50))

proc run(args: varargs[string]): string =
  let (output, _) = execCmdEx(om.quoteShell & " " & args.join(" "))
  output.strip().replace(sandbox, "…")

discard run("catalog init", (sandbox / "library").quoteShell,
  "--domain photo --scheme YYYY/MM/DD")

nbText: """
# Filing by date

`organize` puts files into dated folders. It plans first, always.

The inbox below is a common shape: a camera folder and a backup of it, holding
the same two pictures, plus one the backup has and the camera does not.

## The plan

Nothing is written by this.
"""

nbCode:
  echo run("--library", (sandbox / "library").quoteShell,
    "organize plan", (sandbox / "inbox").quoteShell, "--copy")

nbText: """
Two things to read there.

**`SKIP identical`.** The same bytes under the same name are one file, whether
the twin is already filed or merely earlier in this same plan. A folder holding
its own backup is filed once, not twice. Without this the second copy would take
a `_1` suffix and the library would carry both.

**The layout.** `--scheme` chose `YYYY/MM/DD` for this library; the closed set
is `YYYY/MM-DD`, `YYYY/MM/DD`, `YYYY/MM`, `YYYY/YYYY-MM-DD` and `flat`.

## Copy, move or link

| Mode | What happens to the source |
|---|---|
| `--copy` | Kept. Available when importing from outside the library. |
| `--move` | Given up. |
| `--hardlink` | One copy of the bytes, reachable from both places. One filesystem only. |

Re-filing a library in place offers move and hard link; copy would duplicate the
library into itself.

## Applying it
"""

nbCode:
  echo run("--library", (sandbox / "library").quoteShell,
    "organize apply", (sandbox / "inbox").quoteShell, "--copy")

nbText: "What landed:"

nbCode:
  echo run("--library", (sandbox / "library").quoteShell, "catalog list")

nbText: """
Three files for five in the inbox, and the source is untouched.

## Keeping every copy

Sometimes you want them all — scattered folders where a duplicate is evidence
rather than waste. `--keep-duplicate` turns off both identity tests, and each
copy takes the next free suffix.
"""

nbCode:
  echo run("--library", (sandbox / "library").quoteShell,
    "organize plan", (sandbox / "inbox").quoteShell, "--copy --keep-duplicate")

nbText: """
## What travels with a picture

A sidecar beside a file is carried with it: `.xmp`, and `.aae` and `.thm`. The
`.aae` matters more than it looks — it holds Apple's non-destructive edits, and
the picture beside it is the **unedited original**. Leaving it behind discards
the crop and the filter without saying so.

Each keeps its own extension and its own spelling. A `.aae` renamed `.xmp`
describes nothing any reader knows how to apply.

Sidecars are considered even where the media itself is skipped, which is what
lets a second run finish what a first one left.
"""

nbSave
