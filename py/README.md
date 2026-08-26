<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unimedia

Python surface over the native UniMedia engine: a local-first media catalogue,
organizer and duplicate finder.

```python
from unimedia import Library

with Library("~/Pictures/Library") as library:
    print(library.scan())
    for item in library.items(limit=20):
        print(item["id"], item["path"])

    run = library.find_duplicates("exact")
    for group in library.review(run)["groups"]:
        print(group["kind"], [member["path"] for member in group["members"]])
```

The binding wraps the C ABI and adds nothing of its own: no SQL, no decoding,
no filesystem mutation. Reports arrive as plain dictionaries, and the catalogue
schema never crosses the boundary, so an engine migration cannot break a caller.

A library is one directory holding `.organizemedia.json` and `organizeMedia.db`;
create it with `om catalog init DIR --domain photo`.

Apache-2.0.
