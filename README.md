<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniMedia

Local-first media engine and the `om` CLI. A library is one media directory
containing `.organizemedia.json` and `.organizeMedia.db`; all stored media
paths are relative to that root.

## Layout

```text
UniMedia.nimble          package and tasks
src/UniMedia.nim         umbrella module
src/UniMedia/            the engine, one module per subject
src/om.nim               the CLI binary
include/UniMedia.h       the C ABI, hand-written and kept in sync
py/                      the Cython binding and its tests
tests/                   Nim suites; tests/c links the header against the lib
book/                    the nimib book, compiled and run at docs build
ADRs/                    the decisions, and what they rejected
```

## Build

```bash
nimble install -y        # dependencies
nimble buildOm           # the om binary, into bin/
nimble test              # the Nim suite
nimble clib              # libUniMedia, shared
nimble buildCython       # the Python extension, in place
```

`nimble buildOm` rather than `nimble build`: nimble appends each dependency's
declared `srcDir` to its install path while the installer flattened that
directory into the package root, so the engine paths it passes point at
directories that are not there. A task's own compile resolves them through
`nimblePath` instead.

## What's inside

- **Catalogue and storage** — portable JSON configuration, a SQLite catalogue
  with WAL and forward migrations, incremental scan, bounded pagination, literal
  search, composable filters and facets: `src/UniMedia/{config,store,catalog,timeline}.nim`.
- **Content identity** — BLAKE3 digests for exact identity, perceptual hashes
  and BK-tree neighbour search for visual duplicates including sampled video
  frames, transactional keeper selection and recoverable removal:
  `src/UniMedia/{hashing,dedup}.nim`.
- **Files and organisation** — journaled plan/apply moves and copies with
  conflict handling, crash recovery and undo; content-addressed thumbnails; a
  read-only integrity audit: `src/UniMedia/{organize,thumbnails,integrity}.nim`.
- **Curation and metadata** — ratings, keywords, creator, copyright, favourites
  and covers over XMP sidecars, manual albums and validated dynamic smart albums:
  `src/UniMedia/{curate,curation,batch_curation,smartalbums}.nim`.
- **Privacy** — reporting and recoverable removal of GPS and software signals:
  `src/UniMedia/{privacy,privacy_strip}.nim`.
- **Time and place** — creation-date set and shift, GPX track matching, cached
  reverse geocoding: `src/UniMedia/{date_edit,gpx,reverse_geocode,nominatim_client}.nim`.
- **Optional local intelligence** — an external face-detector protocol, face
  clustering with protected assignments, model-isolated embeddings and captions:
  `src/UniMedia/{face_detect,people,vision}.nim`.
- **Transfer** — deterministic manifests, staged non-destructive remote pulls,
  and a bounded FFmpeg adapter for formats no codec here decodes:
  `src/UniMedia/{sync,external_media}.nim`.
- **Shell** — a terminal-neutral command dispatcher and the `om` process
  boundary: `src/UniMedia/cli.nim`, `src/om.nim`.

## The Uni* family

UniMedia is the application layer of `lituus-lab`'s `Uni*` family: a set of Nim
libraries unified by a shared dependency DAG and documentation/testing
conventions. See
[lituus-lab/.github](https://github.com/lituus-lab/.github) for the family's
purpose and philosophy. UniMedia consumes UniImage (decoding, EXIF/XMP),
UniPercept (perceptual hashes, BK-tree) and UniCrypto (BLAKE3), and nothing in
the family depends on UniMedia.

## Provenance & development

The algorithms here are standard practice rather than original research:
content-addressed caching, BK-tree nearest-neighbour search over Hamming
distance, write-ahead journaling for recoverable filesystem mutations, and the
portable XMP/EXIF/IPTC property set for date and place. The media-library design
— one movable root, relative paths, plan-then-apply with undo — comes from an
earlier hand-written organizer that this repository replaces.

Development used LLM/agent assistance extensively, on the terms described below.
One visible consequence: this repo's git history is short and linear, with
commits landing close together in time — that reflects an LLM/agent rewrite pass
over a design that already existed, not a catalogue engine being designed at
that speed from a blank page.

## CLI

```bash
nimble install --depsOnly -y
nimble buildOm
bin/om catalog init ~/Pictures/Library --domain photo
bin/om --library ~/Pictures/Library catalog scan --progress
bin/om --library ~/Pictures/Library catalog search IMG_2026 --limit 20
bin/om --library ~/Pictures/Library catalog list --limit 100 --offset 200
bin/om --library ~/Pictures/Library catalog filter summer --kind image \
  --keyword family --keyword sea --min-rating 4 --favorite --from 2026-06-01 \
  --to 2026-08-31
bin/om --library ~/Pictures/Library catalog filter --location paris --has-gps
bin/om --library ~/Pictures/Library catalog keywords --prefix fam --limit 20
bin/om --library ~/Pictures/Library geo places --prefix par --json
bin/om --library ~/Pictures/Library catalog show 42 --json
bin/om --library ~/Pictures/Library config show
bin/om --library ~/Pictures/Library config set birthtimeDate=true scheme=YYYY/MM/DD
bin/om --library ~/Pictures/Library cleanup --kind os-junk
bin/om --library ~/Pictures/Library cleanup --yes --progress
bin/om probe ~/Videos/clip.mov
bin/om --library ~/Pictures/Library catalog thumbnail 42 --size 256 --json
bin/om --library ~/Pictures/Library timeline report --by month
bin/om --library ~/Pictures/Library privacy audit --json
bin/om --library ~/Pictures/Library privacy strip 42       # plan only
bin/om --library ~/Pictures/Library privacy strip 42 --yes # recoverable apply
bin/om --library ~/Pictures/Library integrity audit --progress
bin/om --library ~/Pictures/Library dates shift 3600 42 43 # plan only
bin/om --library ~/Pictures/Library gpx match track.gpx \
  --camera-offset 120 --tolerance 60 # plan only
bin/om --library ~/Pictures/Library curate album create "Summer 2026"
bin/om --library ~/Pictures/Library curate batch set 42 43 \
  --add-keyword summer --rating 4 --yes
bin/om --library ~/Pictures/Library curate album add 1 42 43
bin/om --library ~/Pictures/Library curate album cover 1 42
bin/om --library ~/Pictures/Library curate album rename 1 "Summer archive"
bin/om --library ~/Pictures/Library curate album show 1 --json
bin/om --library ~/Pictures/Library curate item set 42 --rating 5 --favorite \
  --title "A summer evening" --keywords "summer,family"
bin/om --library ~/Pictures/Library curate item set 42 \
  --add-keyword sea --remove-keyword family
bin/om --library ~/Pictures/Library curate item set 42 \
  --date 2026-07-14T20:30:00 --latitude 48.8566 --longitude 2.3522 \
  --location "Paris, France"
bin/om --library ~/Pictures/Library curate item show 42 --json
bin/om --library ~/Pictures/Library curate smart create "Best family" --all \
  --rule rating:gte:4 --rule favorite:eq:true --rule keyword:eq:family
bin/om --library ~/Pictures/Library curate smart show 1 --json
bin/om --library ~/Pictures/Library organize plan ~/Pictures/Inbox
bin/om --library ~/Pictures/Library organize apply ~/Pictures/Inbox --progress
bin/om --library ~/Pictures/Library dedup find
bin/om --library ~/Pictures/Library dedup review
bin/om --library ~/Pictures/Library dedup keep 3 42
bin/om --library ~/Pictures/Library dedup remove        # plan only
bin/om --library ~/Pictures/Library dedup remove --yes  # recoverable apply
bin/om --library ~/Pictures/Library undo apply --last --yes --progress
```

Use `--domain visual` for a library containing both images and videos. The
existing `photo`, `video`, and `music` domains remain intentionally selective.

Copy is the default. Moving requires `--move --yes`. `--hardlink` files the media
under its catalogue name without a second copy of the bytes and needs no `--yes`,
because the source keeps its own name; it requires one filesystem and reports a
per-operation failure across devices. Duplicate removal also requires `--yes`;
without it, `dedup remove` only prints the deterministic plan.
The closed organize schemes are `YYYY/MM-DD` (month/date), `YYYY/MM/DD`
(month/day), `YYYY/MM`, `YYYY/YYYY-MM-DD` and `flat`. An explicit `--scheme`
overrides the strict `.organizemedia.json` library preference; otherwise that
preference is used.
UniMedia deliberately keeps one configuration format instead of adding a second
TOML source of truth.

Duplicate review is actionable: `setDedupKeeper` and `dedup keep GROUP ITEM`
atomically select exactly one active member as keeper before removal. When an
item appears in overlapping exact and visual groups, any keeper selection
protects it globally; contradictory group choices therefore fail safe by
removing fewer items, never by deleting a selected keeper.

## Output contract

A GUI or script drives `om` rather than reimplementing it, so the output shape is
part of the interface.

- **`--json` writes JSON Lines to stdout**: one self-contained JSON object per
  line, not a wrapping array. A result set of one item is one line; an empty
  result set is zero bytes. Parse line by line and a partial read stays valid.
- **`--progress` and `--progress-json` write to stderr**, never stdout, so a
  consumer can read records and progress on separate streams. `--progress` emits
  `phase<TAB>current/total<TAB>message`; `--progress-json` emits
  `{"phase":…,"current":…,"total":…,"message":…}` one per line and implies
  `--progress`.
- **Exit codes**: `0` success, `1` error, `2` usage error, `3` partial failure
  (some items failed; the rest committed), `4` cancelled.
- **Cancellation**: SIGINT — Ctrl-C, or a parent process signalling the child —
  stops the run at its next cooperative boundary, rolls back the open
  transaction and exits `4`. Organize and undo take the journaled route instead:
  an interrupted batch is reconciled by the next run rather than abandoned.
- **Plan then apply**: mutating commands print a plan and change nothing until
  `--yes`. A consumer can therefore show the plan for confirmation and pass the
  same arguments back with `--yes`.

```console
$ om --library LIB catalog scan --json --progress-json 2>progress.jsonl
{"indexed":2,"updated":0,"removed":0,"hashErrors":0}
$ cat progress.jsonl
{"phase":"scan","current":1,"total":2,"message":"a.ppm"}
{"phase":"scan","current":2,"total":2,"message":"b.ppm"}
```

## Engine

The `UniMedia` facade exposes configuration, portable SQLite storage, streaming
BLAKE3, catalogue scanning/search/lookup, read-only timeline and privacy
reports, organization planning/apply/undo, and exact/visual duplicate reports.

### Storage, search and facets

Catalogue search includes the textual curation fields. `CatalogFilter` and
`catalog filter` combine optional text, media kind, exact keyword, rating,
favorite, inclusive date, literal location and GPS-presence facets. Filtering
remains portable across the supported SQLite builds: it does not require FTS or
JSON1. Repeated `--keyword` options are intersected; an item must contain every
exact case-insensitive keyword.

`catalog keywords` exposes normalized keyword counts for facet pickers. Counts
represent distinct items, and results use frequency then keyword ordering so CLI
and Studio consumers receive a stable projection. Curation treats keyword case
variants as one value while preserving the spelling of the first occurrence.

`listItemsPage`, `searchItems` and `filterItems` provide bounded, zero-based
offset pagination with stable relative-path ordering; `countItems` supplies the
active total for a virtualized grid. The matching CLI commands accept `--limit`
and `--offset`, while an unpaged `catalog list` retains its complete listing
behavior for scripts.

`listPlaceFacets` and `om geo places` expose the local place projection needed
by list and map consumers: case-insensitive location groups, stable counts,
GPS coverage and a nullable mean coordinate. They never contact a geocoding
service. Reverse geocoding requires a separately configured provider and cache
and is not implied by reading the catalogue.

### Items without a file

`addVirtualItem` and `om catalog add-virtual` catalogue something that has no
file of its own — a book or a bottle read from a barcode. It carries its
domain-specific properties as a JSON object in `meta_json`, reachable through
`itemMeta`/`setItemMeta` and `om catalog meta`, so a new domain adds no column
and no second store.

Such an item is marked `source` other than `file`, which is what keeps the rest
of the engine honest: a scan reconciles only file-backed rows and never sweeps
it away, the integrity audit has no path to verify and skips it, and curation
writes the catalogue row without inventing an XMP sidecar next to media that
does not exist. Albums, smart albums, keywords and ratings treat it like any
other item.

### Organize, undo and integrity

`auditIntegrity` is a read-only consistency gate over SQLite constraints,
catalogued paths, file sizes and optional exact hashes. It reports drift but
never silently rescans, repairs or deletes anything; `catalog scan` remains the
explicit reconciliation command.

A file identical to one already filed is not filed twice: the same bytes under
the same name are one file, whether the twin is already on disk or earlier in
the same plan, so importing a folder that holds its own backup writes one copy.
`--keep-duplicate` files every copy instead, each taking the next free suffix.
Two files identical but named differently are filed twice either way — matching
content under another name is what `dedup` finds.

Sidecars travel with their media: `.xmp`, `.aae` and `.thm`, each keeping its
own extension and spelling. `.aae` holds Apple's non-destructive edits and the
picture beside it is the unedited original, so leaving it behind discards the
crop. They are considered even where the media itself is skipped, which is what
lets a second run finish what a first one left.

Transfer hashes commit before filesystem changes; final state commits
afterward. Mutations serialize through SQLite, interrupted batches and XMP edits
are reconciled against their journals, and control files plus all mutation paths
reject symbolic-link traversal.

### Duplicates

Exact groups come from streaming BLAKE3. Visual groups come from pHash and a
BK-tree, over one hash per still image and one per sampled frame for a video, so
a re-encoded or trimmed video still groups with its original where byte equality
cannot see it. Frame sampling needs the optional FFmpeg tools; without them a
video remains exactly indexed and visually unhashed rather than reported as an
error.

Audio groups come from chromaprint fingerprints through the optional `fpcalc`
executable, compared pairwise over their common prefix — there is no tree,
because the fingerprints vary in length. `dedup find --kind audio` therefore
finds a re-encoded track, but not one trimmed at the head, which would need an
alignment search the engine does not perform. Without chromaprint an audio item
stays exactly indexed, as video does without FFmpeg.

Duplicate removal is recoverable through soft deletion. Non-keepers and
their XMP sidecars move into `.om-trash/<batch>/`; normal catalogue, album,
timeline, facet and smart-album reads hide them without deleting their item IDs
or relationships. `undo` verifies the journaled content hashes before restoring
the original paths and visibility. Modified trash content is never restored.

### Albums, curation and XMP

Manual albums are durable catalogue projections: membership references item IDs,
does not move media, is idempotent, and is removed automatically when an item
leaves the catalogue. An album also carries an optional member-backed cover, and
supports safe rename and confirmed deletion. Item curation stores titles,
descriptions, ratings, favorites, keywords, creator and copyright while
mirroring every edit to a preserving XMP sidecar. `--creator` repeats rather
than splitting on commas, because a name may contain one and `dc:creator` is an
ordered list; `--clear-creator` empties it.

Multi-item curation is planned and fully prevalidated before the first edit.
`applyCurationBatch` reuses the per-item XMP recovery journal, observes
cooperative cancellation only between items, and reports runtime conflicts per
item without hiding successfully committed edits.

Incremental keyword additions and removals are evaluated inside the same
journaled XMP mutation as full replacement; contradictory edits are rejected.

Smart albums are evaluated dynamically. Their normalized rules use whitelisted
fields/operators and parameterized queries rather than stored SQL.

Existing sidecars keep unrelated namespaces and structured properties. A new
sidecar uses `<media filename>.xmp`; an existing same-stem sidecar is reused
instead, so a library written by another tool keeps one sidecar per item. Date
and place use portable `xmp:CreateDate`, `exif:GPSLatitude`, `exif:GPSLongitude`
and `Iptc4xmpCore:Location` properties.

### Dates, GPX and reverse geocoding

Date correction exposes separate set and second-resolution shift plans. Every
entry records its old and new canonical timestamp; apply rejects the whole plan
if any path or source date became stale.

**The correction is written into the file, not only into the catalogue.** A
camera with a wrong clock stamped the picture, so a date fixed only here would
leave every other program reading the wrong one: UniImage rewrites the Exif
carriers, UniMovie the ISO base media headers, under one journaled batch that
`undo` reverses byte for byte. A container with no writer here is corrected in
the catalogue alone and counted apart as `written`, because nothing else will
see that one.

A GPX match leaves a photograph that already carries a position alone — a
camera's own fix beats one interpolated from a logger — and reports it as kept
rather than as unmatched, since only the second is fixed by widening the
tolerance. `--refresh` places those too. Shift arithmetic uses UTC to avoid host timezone and
daylight-saving drift; catalogue timestamps remain deliberately timezone-neutral.

Latitude, longitude and location text form a canonical projection, and the
curation journal carries canonical date and place state, so recovery finalizes
SQLite and XMP together. Dates accept `YYYY-MM-DD` and second-resolution local
timestamps. GPS coordinates must be supplied as a complete latitude/longitude
pair; `--clear-gps`, `--date=` and `--location=` perform explicit clears. Curated
dates survive later catalogue rescans.

GPX import accepts bounded, DTD-free GPX 1.x XML and requires timed track
points with RFC 3339 offsets. Plans expose matched and unmatched catalogue
items, apply a user-supplied camera UTC offset and tolerance, and write only
matched GPS pairs through the same recovery journal.

Reverse geocoding is provider-neutral. Cache keys include provider, language and
coordinates rounded to six decimals in the canonical SQLite store. Planning may
fill this derived cache, preserves existing place text unless overwrite is
explicit, retains provider attribution, and applies locations through curation.
No public geocoding endpoint is built into the engine.

A Nominatim-compatible adapter exists only for explicitly configured endpoints.
It requires an identifying User-Agent, serializes misses at no more than one
request per second, limits redirects/timeouts, and retains the returned licence
attribution. The CLI additionally requires `--network`; cached plans need no
network opt-in.

### Privacy

Privacy stripping delegates container rewriting to UniImage. The default CLI
prints a plan; `--yes` journals XMP sidecars, the original media and the
stripped replacement before mutation. Generic hash-verified `undo` removes the
replacement and restores the exact original plus sidecars.

### Cleanup

`cleanup` takes away what accumulates around a library without belonging to it:
AppleDouble sidecars, browser droppings, sidecars whose media is gone,
directories a re-filing emptied, and the temporary files an interrupted run
left. `--kind` narrows it; the default plan covers every kind.

An AppleDouble is read before it is proposed. On a filesystem that cannot hold
extended attributes beside a file, `._name` is where a Finder tag, a comment
and a resource fork live, so one carrying anything but a known-worthless marker
is reported with `KEEP` and the reason rather than taken. Everything else moves
to the journaled trash, so `undo` brings it back; an empty directory is removed
instead, having held nothing for the trash to keep.

### Preferences

`config show` prints what `.organizemedia.json` holds; `config set KEY=VALUE`
changes it. Each value is parsed through the reader the file itself uses, so a
value the library would reject is refused before anything is written.

`birthtimeDate` is off: on a copied or restored library the filesystem's
creation time is the date of the copy, so accepting it dates every photograph
to the day the backup ran. A file with no date in its metadata or its name is
filed as undated instead.

### Probing one file

`probe FILE` reports what a media file is — coded size, display size, rotation,
duration, codec, container — without a library and without running an external
program. It is the same reader the scan uses.

### Thumbnails and external media

`ensureThumbnail` provides the raster boundary shared by the CLI and future
Studio grid. It normalizes all EXIF orientations, preserves aspect ratio,
never enlarges the source and writes a deterministic PNG beneath
`.om-cache/thumbnails/`. Cache keys include the catalogue BLAKE3 digest, edge
size and algorithm version. A changed source requires a catalogue rescan;
corrupt cache entries are rebuilt and symbolic cache paths are rejected.

What a video *is* — its tracks, dimensions, rotation and duration — comes from
`UniMovie`, in process. Getting a *frame* out of one still needs an optional
system `ffmpeg`, because decoding is where the patents are. A machine without it
catalogues videos and goes without their thumbnails, rather than skipping them.
UniMedia neither links nor bundles FFmpeg; the bounded process boundary and
distribution consequences are recorded in
[ADR-0009](ADRs/0009-optional-external-media.md).

### People, vision and sync

People runs an explicit structured detector executable, computes visual face-crop
signatures locally, clusters unassigned observations and protects explicit user
assignments. `nimble appleVision` builds the supplied macOS system-framework
helper; other platforms can implement the documented JSON protocol. No model is
downloaded.

Vision stores model-isolated embeddings and structured annotations, ranks them
locally by cosine similarity, and exposes textual index/search plus factual
captions/labels. Its Ollama adapters require an explicit endpoint, model and
call; redirects and response sizes are bounded.

Sync delegates non-destructive `copy` transports to the optional system `rclone`
executable: credentials remain in rclone configuration, every application
follows a recorded dry-run plan, and UniMedia never constructs a shell command.
Push excludes database, configuration, cache, trash and staging paths. Pull
writes only to `.om-incoming/<plan>` for a later journaled Organize import; it
never overwrites the active library. `om sync status` exposes persisted plans,
completion state and bounded summaries. `om sync manifest` emits a deterministic,
root-independent JSON snapshot; `om sync diff MANIFEST.json` compares it locally
without contacting a remote.

### Engines, contracts and progress

UniImage, UniPercept and UniCrypto provide metadata, raster decoding,
perceptual hashes/BK-tree and BLAKE3.

The three engines are resolved as sibling checkouts under `lituus-lab/` rather
than installed packages, because a `nimble` path dependency carries none of its
own transitive requirements: `nim.cfg` therefore also supplies UniColor, needed
by UniImage's quantizer, and nimsimd, needed by UniCrypto's BLAKE3 kernels. Each
tracks its maintained default branch, and CI reproduces the same layout.
[ADR-0001](ADRs/0001-dag-and-invariants.md) records the constraint.

NimContracts state cheap public invariants in debug builds and compile away in
release builds. The filesystem journal is the recovery boundary; WAL alone is
not treated as filesystem atomicity.

The catalogue tracks exact-hash and pHash state independently (`hash_status` and
`phash_status`), so `catalog scan --no-phash` defers visual hashing instead of
disabling it permanently. A normal visual scan reuses its UniImage decode to
store EXIF-oriented display dimensions. Changed content invalidates dimensions;
with `--no-phash`, they remain `0×0` until visual hashing or thumbnail generation
decodes that content.

Scan, organize apply and undo apply share a phase-tagged `ProgressCallback`.
Organize totals count actionable operations only and then emit the rescan as a
separate `scan` phase; undo emits every actionable journal row, including
already reconciled skips. CLI `--progress` writes these events to stderr so JSON
and other stdout output remain machine-readable.

## Gates

```bash
nimble testAll        # debug + release + CLI build
nimble lint           # nimpretty check, no rewrite
nimble checkVGraph    # internal layers + Uni* DAG
nimble example
nimble docs           # executable nimib book + API reference
nimble coverage       # lcov, Linux/macOS
```

CI runs the Nim gates on Linux, macOS and Windows, plus SPDX, DCO, Conventional
Commits, docs and coverage.

## C ABI and Python

UniMedia publishes a C ABI and a Python extension, in the same layout as the rest
of the family — `src/UniMedia/c_api.nim`, `include/UniMedia.h`, `py/` — so a
native application can link the engine and a script can import it, instead of
driving the CLI.

Handles are opaque: no Nim object, `Store` or SQLite handle crosses the boundary,
and the schema is never exposed, so a migration cannot break a linked caller.
Python is a thin Cython wrapper over that same ABI, never a second
implementation. [ADR-0011](ADRs/0011-c-abi.md) records the decision, including
which of the earlier eligibility conditions are met and which are deliberately
waived.

The ABI reaches the whole library, not the parts a first consumer asked for:
ask whether a folder is a library and create one where it is not, open and
close, read and write the preferences, scan, page through items, fetch one by
identifier with its absolute path, search, filter and place facets, free-form
metadata, thumbnails, duplicate find/review/keep/remove — whole run or one
reviewed item — removal of chosen items with no duplicate run involved,
organize plan and apply with an explicit scheme, item curation and its batch
form with the keyword facets an editor offers, date correction and GPX matching
as plan and apply, place naming as plan and apply, the privacy audit with its
strip plan and apply, undo plan and apply, the integrity audit, albums and
smart albums, people and faces with clustering, the timeline, sync manifest and
history, vision annotations and semantic search, and what a video file is
alongside the availability of each optional external tool.
Every removal goes to the same journalled trash, and a strip keeps the original
the same way, so undo restores either whichever asked. Every plan is rebuilt
inside its apply, so a caller cannot act on one the library has moved past.
Creating a library writes its config and catalogue and nothing else: no media
file is read, moved or modified until a scan is asked for, and every long
operation reports progress per file so a large folder shows movement rather
than a stalled window.

A scan decides what each file still owes from the row already on disk, computes
that over a thread pool, and writes the results on the one thread that owns the
SQLite connection; an unchanged library therefore still hashes nothing. Measured
over 1733 photographs and videos, 811 s became 263 s. Perceptual hashing is
almost all of what remains -- the same scan skipping it takes 6 s -- and only
duplicate detection needs it, so `--no-phash` leaves it owed and
`um_phash_pending_count` says how much.
Preferences cross as the JSON `.organizemedia.json` already holds, so an
application edits the file the CLI reads instead of keeping a second copy of the
settings. Long operations take a
progress function pointer and a cancel function pointer with the caller's own
context; cancelling returns `UM_ERR_CANCELLED` and rolls back. Organize and undo
take no cancel hook on purpose: they are journalled, so an interruption is
reconciled by the next run rather than abandoned half-done. Curation, privacy,
dates, GPX and sync stay out until an application needs them.

## AI-assisted contributions

Assistance from AI/LLM tools is welcome on the same terms as any other
contribution.

- **Accountability.** The human contributor is the author and remains fully
  responsible for the change. The DCO sign-off (`Signed-off-by`) is the mechanism:
  by signing you certify the content is yours or properly licensed — this covers
  AI-assisted work, provided you can stand behind it.
- **No third-party contamination.** Ensure AI output introduces no code from a
  third party without a compatible license and attribution. If an LLM reproduced
  protected material, do not submit it.
- **Correctness is yours.** The gates (tests, `nimble lint`, conventional commits,
  pre-commit) catch a lot, but you own the result — review and verify what you
  commit.
- **Atomic commits.** Each commit is one logical change. A PR may stack
  several atomic commits (one per element, say) — one monolithic big-bang
  commit is not.
- **Disclosure.** State in the PR whether AI assistance was used (see the PR
  template). It is not a hard requirement — the DCO remains the gate.

## License

Apache-2.0. Contributions require DCO sign-off; see `CONTRIBUTING.md`.
