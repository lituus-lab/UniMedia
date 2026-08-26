# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[options, times]
import contracts

# Single source of truth for the version: the facade re-exports it and the CLI
# prints it, so a bump touches one line. tests/test_config.nim checks it against
# the package manifest.
const UniMediaVersion* = "1.0.0"

const MaxAlbumDepth* = 64
  ## How deep albums may nest. Past any tree somebody arranges by hand, and a
  ## bound on how far a cycle check walks before it decides the data is wrong
  ## rather than merely deep.

type
  MediaDomain* = enum
    mdPhoto = "photo"
    mdVideo = "video"
    mdMusic = "music"
    mdVisual = "visual"

  OrganizeScheme* = enum
    osYearMonthDayDash = "YYYY/MM-DD"
    osYearMonthDay = "YYYY/MM/DD"
    osYearMonth = "YYYY/MM"
    osYearDate = "YYYY/YYYY-MM-DD"
    osFlat = "flat"

  ConflictPolicy* = enum
    cpSuffix = "suffix"
    cpSkip = "skip"

  TransferMode* = enum
    tmCopy = "copy"
    tmMove = "move"
    tmHardlink = "hardlink"

  OpKind* = enum
    okCopy = "copy"
    okMove = "move"
    okDelete = "delete"
    okHardlink = "hardlink"

  OpStatus* = enum
    opsPending = "pending"
    opsApplied = "applied"
    opsFailed = "failed"
    opsUndone = "undone"

  BatchStatus* = enum
    bsPending = "pending"
    bsApplying = "applying"
    bsApplied = "applied"
    bsPartial = "partial"
    bsUndone = "undone"
    bsEmptied = "emptied"
      ## The trash this batch kept was deleted. Recorded rather than inferred
      ## from missing files, so undo refuses by name instead of failing on each
      ## path it cannot find.

  LibraryConfig* = object
    schemaVersion*: int
    domain*: MediaDomain
    scheme*: OrganizeScheme
    filenameDate*: bool
    birthtimeDate*: bool
      ## Accept the filesystem's creation time as a capture date. Off: on a
      ## copied library it is the date of the copy, so it dates a photograph to
      ## whenever the backup ran. A file with nothing better is better reported
      ## as undated than dated wrongly.
    noDateDir*: string
    onConflict*: ConflictPolicy

  Library* = object
    root*: string
    config*: LibraryConfig

  Item* = object
    id*: int64
    relPath*: string
    fileSize*: int64
    mtimeNs*: int64
    category*: string
    extension*: string
    creationDate*: string
    dateSource*: string
    width*, height*: int
    hashStatus*: string
    phashStatus*: string
    latitude*, longitude*: Option[float]
    locationText*: string
    source*: string
      ## `file` for media found by a scan. Anything else marks an item with no
      ## file of its own, which a scan must not reconcile against the disk.
    metaJson*: string
      ## Per-domain properties as a JSON object. Empty for plain media; the
      ## carrier a non-photo domain fills instead of growing the items table.

  Person* = object
    id*: int64
    name*, createdAt*: string
    faceCount*: int

  Face* = object
    id*, itemId*, personId*: int64
    x*, y*, width*, height*, confidence*: float
    signature*: uint64
    signatureValid*: bool
    detector*, detectedAt*: string

  FaceDetection* = object
    x*, y*, width*, height*, confidence*: float
    signature*: uint64
    signatureValid*: bool
    detector*: string

  FaceCluster* = object
    faceIds*: seq[int64]
    representativeSignature*: uint64

  VisionHit* = object
    itemId*: int64
    relPath*, caption*: string
    labels*: seq[string]
    score*: float

  VisionAnnotation* = object
    itemId*: int64
    model*, caption*, updatedAt*: string
    labels*: seq[string]

  SyncDirection* = enum
    sdPush = "push"
    sdPull = "pull"

  SyncPlan* = object
    id*, provider*, remote*, summary*: string
    direction*: SyncDirection

  SyncReport* = object
    id*, summary*: string
    applied*: bool

  SyncRun* = object
    id*, provider*, remote*, status*, startedAt*, finishedAt*, summary*: string
    direction*: SyncDirection
    dryRun*: bool

  SyncManifestEntry* = object
    path*, digest*: string
    size*, mtimeNs*: int64

  SyncManifest* = object
    schemaVersion*: int
    entries*: seq[SyncManifestEntry]

  SyncDiff* = object
    onlyLocal*, onlyRemote*, changed*: seq[string]

  OrganizeOptions* = object
    mode*: TransferMode
    scheme*: OrganizeScheme
    filenameDate*: bool
    birthtimeDate*: bool
    keepDuplicates*: bool
      ## Copy a file even where an identical one already occupies its place,
      ## giving it the next free `_1`, `_2` suffix. Off: the same bytes under the
      ## same name are one file, and importing a folder that holds its own
      ## backup would otherwise write both halves.
    noDateDir*: string
    onConflict*: ConflictPolicy

  PlannedOp* = object
    kind*: OpKind
    sourcePath*: string
    destRelPath*: string
    size*: int64
    creationDate*: string
    dateSource*: string
    skipReason*: string

  OrganizePlan* = object
    sourceRoot*: string
    operations*: seq[PlannedOp]

  ApplyReport* = object
    batchId*: string
    applied*, skipped*, failed*: int
    linked*: int
      ## Duplicates replaced by a hard link to the copy that was kept. Zero for
      ## every operation but that one.

  UndoReport* = object
    batchId*: string
    undone*, skipped*, failed*: int

  ScanReport* = object
    indexed*, updated*, removed*, hashErrors*: int

  TimelinePeriod* = enum
    tpDay = "day"
    tpMonth = "month"
    tpYear = "year"

  TimelineBucket* = object
    period*: string
    itemCount*: int
    totalBytes*: int64

  PrivacyFinding* = object
    itemId*: int64
    relPath*: string
    signals*: seq[string]
    error*: string

  PrivacyStripEntry* = object
    itemId*: int64
    relPath*: string
    signals*: seq[string]
    strippable*: bool
      ## Whether this file's container can be rewritten without its metadata.
      ##
      ## An audit reports what a file gives away whatever it is; stripping only
      ## works on the containers the editor can rebuild. A plan that promised
      ## the rest would fail on them one at a time, which is worse than saying
      ## so first.

  PrivacyStripPlan* = object
    entries*: seq[PrivacyStripEntry]

  IntegrityFinding* = object
    itemId*: int64
    relPath*, kind*, detail*: string

  IntegrityReport* = object
    checked*, missing*, changed*, hashMismatches*, databaseErrors*: int
    findings*: seq[IntegrityFinding]

  Album* = object
    id*: int64
    name*: string
    createdAt*: string
    itemCount*: int
    coverItemId*: int64
    parentId*: int64
      ## The album this one sits inside, or 0 for one at the top.
      ##
      ## `itemCount` counts what this album holds, never what its children do:
      ## an album lists items, and a parent does not inherit its children's
      ## lists any more than it owns them.

  ItemCuration* = object
    itemId*: int64
    title*, description*: string
    rating*: int
    favorite*: bool
    keywords*: seq[string]
    creator*: seq[string]
      ## `dc:creator`, an ordered list: a photograph can have several authors.
    copyright*: string
      ## `dc:rights`.
    creationDate*, dateSource*: string
    latitude*, longitude*: Option[float]
    locationText*: string
    updatedAt*: string

  CurationPatch* = object
    ## `none` preserves a field. Empty strings/lists clear their XMP property.
    title*, description*: Option[string]
    rating*: Option[int]
    favorite*: Option[bool]
    keywords*: Option[seq[string]]
    creator*: Option[seq[string]]
    copyright*: Option[string]
    addKeywords*, removeKeywords*: seq[string]
    creationDate*: Option[string]
    latitude*, longitude*: Option[float]
    clearGps*: bool
    locationText*: Option[string]

  CurationBatchEntry* = object
    itemId*: int64
    relPath*: string

  CurationBatchPlan* = object
    entries*: seq[CurationBatchEntry]
    patch*: CurationPatch

  CurationBatchFailure* = object
    itemId*: int64
    relPath*, error*: string

  CurationBatchReport* = object
    applied*, failed*: int
    written*: int
      ## Items whose file itself was rewritten, as opposed to only the
      ## catalogue. Counted apart because the difference is what decides
      ## whether any other program will see the correction.
    batchId*: string
      ## The journal a file rewrite was recorded under, so it can be undone.
      ## Empty where nothing was written.
    failures*: seq[CurationBatchFailure]

  TrashBatch* = object
    ## One batch, and what it is still holding.
    batchId*, createdAt*, mode*, status*: string
    fileCount*: int
    totalBytes*: int64
    undoable*: bool
      ## Both conditions at once: a batch that was applied, and files still
      ## there to put back. Either alone is not a way back.

  TrashReport* = object
    batches*, files*, failed*: int
    freedBytes*: int64

  CleanupKind* = enum
    ckAppleDouble = "apple-double"
    ckOsJunk = "os-junk"
    ckOrphanSidecar = "orphan-sidecar"
    ckEmptyDir = "empty-dir"
    ckInterrupted = "interrupted"

  CleanupEntry* = object
    relPath*: string
    kind*: CleanupKind
    size*: int64
    removable*: bool
      ## False where the file was found but must not go — an AppleDouble
      ## carrying a Finder tag, say. Reported so somebody knows it is there,
      ## which is not the same as proposing it.
    reason*: string
      ## Why it is proposed, or why it is kept. Both are worth saying.

  CleanupPlan* = object
    entries*: seq[CleanupEntry]

  DateEditEntry* = object
    itemId*: int64
    relPath*, oldDate*, newDate*: string
    writesFile*: bool
      ## Whether correcting this one reaches the file. False for a container
      ## with no writer here: the catalogue is corrected and the file keeps the
      ## date its camera wrote, which every other program will go on reading.

  DateEditPlan* = object
    entries*: seq[DateEditEntry]

  GpxPoint* = object
    timestamp*: int64
    latitude*, longitude*: float
    elevation*: Option[float]

  GpxMatchEntry* = object
    itemId*: int64
    relPath*, creationDate*: string
    matched*: bool
    alreadyPlaced*: bool
      ## The item carries a position already. Left alone unless the plan was
      ## asked to refresh, and reported either way: a count that quietly
      ## excluded these would read as a track that matched nothing.
    distanceSeconds*: int64
    latitude*, longitude*: float

  GpxMatchPlan* = object
    sourcePath*: string
    toleranceSeconds*, cameraUtcOffsetMinutes*: int
    trackPointCount*: int
    refreshed*: bool
      ## Whether this plan was asked to replace positions that already exist.
    entries*: seq[GpxMatchEntry]

  ReverseGeocodeResult* = object
    locationText*, attribution*: string

  ReverseGeocodeProvider* = proc(latitude, longitude: float;
    language: string): ReverseGeocodeResult {.gcsafe.}

  ReverseGeocodeEntry* = object
    itemId*: int64
    relPath*, oldLocation*, newLocation*, attribution*: string
    latitude*, longitude*: float
    fromCache*: bool

  ReverseGeocodePlan* = object
    provider*, language*: string
    entries*: seq[ReverseGeocodeEntry]

  SmartRule* = object
    field*, operator*, value*: string

  SmartAlbum* = object
    id*: int64
    name*: string
    matchAll*: bool
    createdAt*: string
    rules*: seq[SmartRule]
    itemCount*: int

  CatalogFilter* = object
    text*, kind*, dateFrom*, dateTo*, location*: string
    keywords*: seq[string]
    minRating*, maxRating*: Option[int]
    favorite*, hasGps*: Option[bool]

  KeywordFacet* = object
    keyword*: string
    itemCount*: int

  PlaceFacet* = object
    location*: string
    itemCount*, gpsCount*: int
    latitude*, longitude*: Option[float]

  Thumbnail* = object
    itemId*: int64
    path*: string
    width*, height*: int
    maxEdge*: int
    cacheHit*: bool

  DedupKind* = enum
    dkExact = "exact"
    dkVisual = "visual"
    dkAudio = "audio"
    dkAll = "all"

  DedupMember* = object
    itemId*: int64
    relPath*: string
    similarity*: float
    isKeeper*: bool

  DedupGroup* = object
    id*: int64
    kind*: string
    members*: seq[DedupMember]

  DedupRun* = object
    id*: int64
    createdAt*: string
    kind*: string
    threshold*: float
    groups*: seq[DedupGroup]

  ProgressEvent* = object
    phase*: string
    current*, total*: int
    message*: string

  ProgressCallback* = proc(event: ProgressEvent) {.gcsafe.}
  CancelCallback* = proc(): bool {.gcsafe.}
  OperationCancelledError* = object of CatchableError

proc checkCancelled*(cancel: CancelCallback) =
  ## Raises at an explicit cooperative cancellation boundary.
  if cancel != nil and cancel():
    raise newException(OperationCancelledError, "operation cancelled")

proc defaultLibraryConfig*(domain = mdPhoto): LibraryConfig {.contractual.} =
  ensure:
    result.schemaVersion == 1
    result.noDateDir.len > 0
  body:
    LibraryConfig(schemaVersion: 1, domain: domain,
      scheme: osYearMonthDayDash, filenameDate: true,
      birthtimeDate: false, noDateDir: "_no-date", onConflict: cpSuffix)

proc defaultOrganizeOptions*(config: LibraryConfig): OrganizeOptions {.contractual.} =
  require:
    config.schemaVersion == 1
    config.noDateDir.len > 0
  ensure:
    result.mode == tmCopy
    result.noDateDir.len > 0
  body:
    OrganizeOptions(mode: tmCopy, scheme: config.scheme,
      filenameDate: config.filenameDate,
      birthtimeDate: config.birthtimeDate, keepDuplicates: false,
      noDateDir: config.noDateDir, onConflict: config.onConflict)

proc isoNow*(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
