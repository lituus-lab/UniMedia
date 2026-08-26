# Nothing is lost

Every claim on this page is a property of the code, not an intention. They are
listed together because they only mean something as a set: any one alone would
still let you lose photographs.

## A plan, then an apply

Every destructive command prints what it would do and stops. `--yes` is what
makes it act.

```
$ om --library ~/Pictures privacy strip
SKIP    clip.mov     gps
STRIP   photo.heic   camera,gps,software
```

`SKIP` and `STRIP` are different words because they are different outcomes. A
plan that said `STRIP` for both would promise work the apply then refuses.

## The apply rebuilds the plan

It does not take the one you read. It computes it again, so a file that changed
in between meets the same rules rather than being acted on from a stale
reading. A plan whose items moved underneath it is refused outright — the whole
request, not the part that still fits.

## The journal is written first

Before a file is touched, a row says what is about to happen and carries the
digest of what is there now. An interrupted run therefore leaves a description
of its intention, and the next run reconciles from that rather than from
whatever state the disk happens to be in.

## What is removed is kept

Removal moves files to `.om-trash/<batch>/` inside the library. `undo` restores
them **byte for byte** — verified by digest, and refused if the file changed
since.

```
$ om --library ~/Pictures undo apply --last --yes
Batch batch_1787481074_f752fd82: undone 358, skipped 0, failed 0
```

## Emptying is the exception, and says so

`trash empty` deletes for good. There is no second trash behind it. The batch is
marked `emptied`, so `undo` afterwards refuses **once, by name**, rather than
failing on each path it cannot find:

```
$ om --library ~/Pictures undo apply --last --yes
om: this batch was emptied from the trash; what it removed is gone
```

`cleanup --permanently` and `items remove --permanently` skip the trash
entirely. They exist because a network share pays for every move — trashing
44299 files and then emptying them is twice the work of deleting them once. The
plan says `DELETE` rather than `REMOVE`, the report does not mention undo, and
**no batch identifier is handed back**: returning one would read as a way back
that does not exist.

## What is refused rather than half-done

An operation that cannot finish correctly does not start.

- Linking duplicates on a filesystem without hard links is refused **before any
  file moves**, by trying a real link — not by guessing from the filesystem's
  name, because a network share and an exFAT disk both refuse them.
- Only byte-identical files may be linked, and the contents are re-verified at
  the moment of linking rather than trusted from the search.
- A privacy strip that cannot rewrite a container reports it and passes over it,
  rather than failing the batch or claiming to have cleaned it.
- A date correction that cannot reach the file says so, and counts those apart
  from the ones it wrote.
