# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel and compares the fresh
outputs with the committed ones, so a stale value fails the build. Re-run this
after any API change.

Nothing here prints a capability probe (audio_available and friends) or a
timestamp: both answer differently on another machine, and the comparison
would be impossible to satisfy across the runners."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniMedia — Python quickstart

`unimedia` is a Cython extension over the UniMedia C ABI, shipped as a
self-contained wheel: the native library travels inside the package, so
installing it needs neither Nim nor a compiler.

```
pip install lituus-unimedia
```"""),
    ("md", "## The API"),
    ("code", """import unimedia

unimedia.engine_version(), unimedia.__version__, unimedia.abi_version()"""),
    ("md", """## Answers a path alone can give

Most of the library reads files, but a useful part of it answers from the name
before anything is opened. A domain holds some kinds of file and not others: a
photo library has no category for a video, and says so with an empty string
rather than an error."""),
    ("code", """print("photo / b.jpg =", repr(unimedia.category_for("photo", "a/b.jpg")))
print("photo / b.mp4 =", repr(unimedia.category_for("photo", "a/b.mp4")))
print("video / b.mp4 =", repr(unimedia.category_for("video", "a/b.mp4")))

try:
    unimedia.category_for("sculpture", "a/b.jpg")
except ValueError as exc:
    print("unknown domain ->", exc)"""),
    ("md", """## What a name claims about its date

`filename_date` reads the **date** a name claims, not the time: a name carrying
`101500` still answers at midnight. A name claiming nothing answers nothing,
which is not an error."""),
    ("code", """print("IMG_20240115_101500.jpg ->", repr(unimedia.filename_date("IMG_20240115_101500.jpg")))
print("holiday.jpg             ->", repr(unimedia.filename_date("holiday.jpg")))"""),
    ("md", """## What can be written, without reading anything

Whether a date correction can reach a file, or metadata be stripped from it,
follows from the format. Answering from the name costs no read."""),
    ("code", """for name in ("a.jpg", "notes.txt"):
    print(f"{name:10} date-writable={unimedia.can_write_date(name)}"
          f" strippable={unimedia.can_strip(name)}")"""),
    ("md", """## A path that escapes its root is refused

`checked_path_under` resolves a path and refuses it when it leaves the root —
the guard between a library and the rest of the disk. `is_internal` separates
the library's own bookkeeping from the media it holds."""),
    ("code", """import os
import tempfile

root = tempfile.mkdtemp()
inside = os.path.join(root, "one.ppm")

print("inside  ->", os.path.basename(unimedia.checked_path_under(root, inside)))
try:
    unimedia.checked_path_under(root, os.path.join(root, "..", "elsewhere.jpg"))
except unimedia.UniMediaError as exc:
    print("outside ->", type(exc).__name__)

print("the database is internal   =",
      unimedia.is_internal(root, os.path.join(root, ".organizeMedia.db")))
print("the photo next to it is not =",
      unimedia.is_internal(root, inside))"""),
    ("md", """## Reading a file

A PPM is a plain-text image, which makes it a fair subject without shipping a
binary: two pixels by two, solid red. `probe_still` reports what the bytes say,
`blake3_file` digests them, and `perceptual_hash_file` reduces the picture to a
hash that survives re-encoding."""),
    ("code", """with open(inside, "w") as handle:
    handle.write("P3\\n2 2\\n255\\n" + "255 0 0\\n" * 4)

print("probe_still =", unimedia.probe_still(inside))
print("blake3      =", unimedia.blake3_file(inside)[:16], "...",
      len(unimedia.blake3_file(inside)), "hex characters")
print("perceptual  =", unimedia.perceptual_hash_file(inside))"""),
    ("md", """## Coordinates the file did not carry

A file with no location does not fail and does not guess: the answer says it
was not found, and the numbers alongside are not an estimate."""),
    ("code", """print(unimedia.media_coordinates(inside))"""),
    ("md", """## An AppleDouble sidecar

macOS leaves `._name` files behind. Whether one can be deleted depends on what
it holds, and the verdict carries the reason — here the bytes do not parse as
AppleDouble at all, so the honest answer is that its contents are unknown."""),
    ("code", """sidecar = os.path.join(root, "._photo.jpg")
with open(sidecar, "wb") as handle:
    handle.write(b"\\x00\\x05\\x16\\x07")

verdict = unimedia.apple_double_verdict(sidecar)
print("removable =", verdict["removable"])
print("reason    =", verdict["reason"])"""),
    ("md", """## A GPX track

`parse_gpx` returns the track points as timestamps and coordinates, which is
what dating a photo from a track needs."""),
    ("code", """track = os.path.join(root, "walk.gpx")
with open(track, "w") as handle:
    handle.write(
        '<?xml version="1.0"?><gpx><trk><trkseg>'
        '<trkpt lat="43.6" lon="1.44"><time>2024-01-15T10:15:00Z</time></trkpt>'
        '<trkpt lat="43.7" lon="1.45"><time>2024-01-15T10:20:00Z</time></trkpt>'
        '</trkseg></trk></gpx>')

points = unimedia.parse_gpx(track)
print("points =", len(points))
for point in points:
    print("  ", point)"""),
    ("md", """## Sync manifests

A manifest lists what a side holds. `diff_sync_manifests` compares two of them
without touching either side's files; a manifest against itself differs in
nothing."""),
    ("code", """import json

manifest = json.dumps({"schemaVersion": 1, "entries": [
    {"path": "a.jpg", "digest": "ab" * 32, "size": 1, "mtimeNs": 2}]})
empty = json.dumps({"schemaVersion": 1, "entries": []})

print("entry        =", unimedia.parse_sync_manifest(manifest)["entries"][0]["path"])
print("against self =", unimedia.diff_sync_manifests(manifest, manifest))
print("against none =", unimedia.diff_sync_manifests(manifest, empty))"""),
    ("md", """## A digest that is not a digest

The manifest is validated, not trusted: an entry whose digest is not 64 hex
characters is refused rather than carried forward."""),
    ("code", """try:
    unimedia.parse_sync_manifest(
        '{"schemaVersion":1,"entries":[{"path":"a","digest":"ab","size":1,"mtimeNs":2}]}')
except unimedia.UniMediaError as exc:
    print("refused ->", type(exc).__name__)"""),
    ("md", """## Identifiers and timestamps

`iso_now` stamps an instant and `new_batch_id` names a run. Neither value can be
printed here — they differ every time, which is the point of them — so what is
shown is their shape."""),
    ("code", """stamp = unimedia.iso_now()

print("iso_now length   =", len(stamp), "| ends with Z =", stamp.endswith("Z"))
print("two batch ids differ =", unimedia.new_batch_id() != unimedia.new_batch_id())"""),
    ("md", """## Configuration

`default_config` is the starting point a caller edits, and reading it back
tells you the keys that exist rather than guessing at them."""),
    ("code", """print(sorted(unimedia.default_config()))"""),
]


def main():
    nb = nbf.v4.new_notebook()
    nb.cells = [
        nbf.v4.new_markdown_cell(src) if kind == "md" else nbf.v4.new_code_cell(src)
        for kind, src in CELLS
    ]
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    # Execute from the repo root, never from py/: there, `import unimedia`
    # would resolve to the py/unimedia source tree instead of the installed
    # package, and the notebook would stop testing what it claims to test.
    NotebookClient(nb, timeout=120, kernel_name="python3",
                   resources={"metadata": {"path": ROOT}}).execute()
    with open(OUT, "w") as f:
        nbf.write(nb, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
