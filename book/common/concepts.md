# What a library is

Six words carry the whole design. They are worth ten minutes.

## A library

A directory containing your media, plus two files UniMedia writes at its root:

| File | What it is |
|---|---|
| `.organizemedia.json` | The preferences: how folders are named, which dates are trusted |
| `.organizeMedia.db` | The catalogue: one SQLite database |

Both begin with a dot, so the Finder hides them and they do not clutter a
folder of photographs. Delete them and you still have every picture; you have
lost only what UniMedia learned about them.

Nothing else is added. Your files are not moved into a package, renamed into an
opaque scheme, or copied into a second store.

## An item

One row in the catalogue, standing for one file. It holds what reading the file
told UniMedia: dimensions, capture date and where that date came from, camera,
codec, coordinates, and a BLAKE3 digest of the contents.

An item's path is stored **relative to the library root**. Move the whole
library to another disk and the catalogue still describes it.

## A batch

Every operation that changes files does so under a batch: a row saying what it
was and when, plus one row per file operation, written **before** the file is
touched. That is what makes the operation survive an interruption — the journal
says what was intended, so the next run can finish or reverse it.

## The trash

Removing something moves it to `.om-trash/<batch>/` inside the library rather
than deleting it. `undo` puts it back. The space is not returned until you empty
the trash deliberately, which is the only action here with no way back.

## A plan

What an operation would do, computed without doing it. Every destructive
command prints one and stops. The plan is not a promise the apply keeps blindly:
the apply rebuilds it, so a file that changed in between is caught by the same
rules rather than acted on from a stale reading.

## A domain

What a library takes in — `photo`, `video`, `visual` (both), or `music`. A scan
ignores anything outside it. Hidden files are never taken in, whatever their
name ends with: on a network share macOS writes `._IMG_1234.HEIC` beside every
picture, and that name ends in `.HEIC` without being a photograph.
