# Python

A Cython extension over the same C ABI, published as a wheel. The engine is
statically linked, so the module has no runtime dependency beyond CPython.

```bash
pip install unimedia
```

## A library is a context manager

```python
from unimedia import Library

with Library("/Users/me/Pictures/Library") as lib:
    lib.scan(skip_phash=True)
    for item in lib.items(limit=10):
        print(item["path"], item["creationDate"], item["dateSource"])
```

Leaving the block closes the handle. A call on a closed library raises rather
than reaching a freed pointer.

## Everything returns plain data

Reports come back as dictionaries and lists, decoded from the JSON the engine
emits. There is no object model to learn and nothing to keep in sync with the
schema.

```python
plan = lib.plan_cleanup()
for entry in plan:
    print(entry["kind"], entry["path"], entry["removable"], entry["reason"])

done = lib.cleanup(["os-junk"])
print(done["removed"], done["kept"], done["failed"])
```

## Plan and apply are separate

```python
groups = lib.find_duplicates(kind="exact")
review = lib.review_duplicates(groups)
# look at review before this line
lib.remove_duplicates(groups)
```

The apply rebuilds the plan from the same inputs, so a file that changed in
between meets the same rules rather than being acted on from a stale reading.

## Progress and cancellation

Long operations take a callback. Returning `True` from a cancel callback stops
the run at the next safe point; what was already journalled is reconciled by the
next call rather than left half-done.

```python
lib.scan(progress=lambda event: print(event["current"], "/", event["total"]))
```

## Errors

Every failure is a `UniMediaError` carrying the engine's message. Out-of-range
input is refused rather than clamped, so a wrong argument is an exception and
never a quiet substitution.

```python
try:
    lib.cleanup(["nonsense"])
except UniMediaError as error:
    print(error)          # unknown cleanup kind: nonsense
```
