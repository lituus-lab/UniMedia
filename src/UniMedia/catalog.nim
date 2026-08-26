# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[algorithm, json, options, os, sets, strutils, tables, times]
import db_connector/db_sqlite
import malebolgia
import UniImage
from UniMovie/isobmff import locationFile
from UniMovie/edit import movieCreationDate
import UniMedia/[types, store, config, hashing, external_media, external_audio]

const
  ImageExts = ["bmp", "gif", "jpeg", "jpg", "pcx", "png", "pnm", "ppm",
               "qoi", "tif", "tiff", "webp"]
  PhotoMetaExts = ["arw", "avif", "cr2", "cr3", "dng", "heic", "heif", "nef",
                   "orf", "raw", "rw2"]
  VideoExts = ["3gp", "avi", "m2ts", "mkv", "mov", "mp4", "mts", "ogv", "webm"]
  MusicExts = ["aac", "flac", "m4a", "mp3", "ogg", "wav", "wma"]

proc inSorted(values: openArray[string]; value: string): bool =
  binarySearch(values, value) >= 0

proc categoryFor*(domain: MediaDomain; path: string): string =
  let ext = path.splitFile.ext.strip(chars = {'.'}).toLowerAscii()
  case domain
  of mdPhoto:
    if inSorted(ImageExts, ext) or inSorted(PhotoMetaExts,
        ext): "image" else: ""
  of mdVideo:
    if inSorted(VideoExts, ext): "video" else: ""
  of mdMusic:
    if inSorted(MusicExts, ext): "audio" else: ""
  of mdVisual:
    if inSorted(ImageExts, ext) or inSorted(PhotoMetaExts, ext): "image"
    elif inSorted(VideoExts, ext): "video"
    else: ""

proc parseFilenameDate*(path: string): string =
  let name = path.splitFile.name
  proc validDate(y, m, d: int): string =
    if y notin 1900..2200 or m notin 1..12 or d notin 1..31: return ""
    try:
      discard dateTime(y, Month(m), MonthdayRange(d), 0, 0, 0)
      align($y, 4, '0') & "-" & align($m, 2, '0') & "-" &
        align($d, 2, '0') & " 00:00:00"
    except ValueError:
      ""
  if name.len >= 10:
    for index in 0..name.len - 10:
      if name[index + 4] in {'-', '_'} and name[index + 7] in {'-', '_'}:
        try:
          let value = validDate(name[index..index + 3].parseInt(),
            name[index + 5..index + 6].parseInt(),
            name[index + 8..index + 9].parseInt())
          if value.len > 0: return value
        except ValueError:
          discard
  var digits = ""
  for ch in name:
    if ch.isDigit:
      digits.add ch
      if digits.len >= 8:
        let y = try: digits[^8..^5].parseInt() except ValueError: 0
        let m = try: digits[^4..^3].parseInt() except ValueError: 0
        let d = try: digits[^2..^1].parseInt() except ValueError: 0
        let value = validDate(y, m, d)
        if value.len > 0: return value
    else:
      digits.setLen(0)

proc mediaCoordinates*(path: string):
    tuple[latitude, longitude: float; found: bool] =
  ## Where a file says it was taken, from its own metadata.
  ##
  ## A camera roll carries this in every picture, and until a scan read it the
  ## only way coordinates reached a catalogue was a GPS track matched by hand
  ## or somebody typing them -- so a library of geotagged photographs reported
  ## no places at all.
  ##
  ## EXIF stores a latitude as a positive number and a letter, but `UniImage`
  ## has already turned the two into one signed value -- so the sign is not
  ## applied again here. Doing so puts Sydney in the northern hemisphere, which
  ## is how this was noticed.
  ##
  ## A file at exactly zero is treated as carrying nothing: that point is in
  ## the Atlantic off Africa and is what a camera writes when it has no fix,
  ## far more often than it is where a photograph was taken.
  ##
  ## A video keeps it elsewhere — an ISO 6709 string in its own metadata, not
  ## an EXIF tag — so both are tried. On a camera roll of Live Photos the
  ## still and the clip carry the same position, and reading only one of them
  ## leaves half the library unplaced.
  try:
    let metadata = readMetadata(path)
    if metadata.isValid and
        (metadata.gpsLatitude != 0.0 or metadata.gpsLongitude != 0.0):
      let latitude = metadata.gpsLatitude
      let longitude = metadata.gpsLongitude
      if latitude >= -90.0 and latitude <= 90.0 and
          longitude >= -180.0 and longitude <= 180.0:
        return (latitude, longitude, true)
  except CatchableError:
    discard
  try:
    let where = locationFile(path)
    if where.found: return (where.latitude, where.longitude, true)
  except CatchableError:
    discard

const MovieDateExts = ["m4v", "mov", "mp4", "qt"]
  ## Containers whose creation time is read from the presentation header. Kept
  ## beside the cascade that uses it rather than shared with the writer's list:
  ## reading one and writing it are allowed to diverge.

const DateProbeCap = 262_144
  ## How much of a file to read looking for a date before reading more.
  ##
  ## Exif sits near the start, so this finds it for all but the unusual file —
  ## measured against the full 16 MiB default on 389 dated photographs spanning
  ## twenty years of cameras, with no disagreement. A scan asks this of every
  ## file it meets, and on a network share the difference is the read volume of
  ## the whole library against a fraction of it.

proc mediaDate*(path: string; filenameDate, birthtimeDate: bool): tuple[value,
    source: string] =
  ## The capture date, and where it was found.
  ##
  ## Empty when nothing trustworthy was available: the caller files it under the
  ## library's undated bucket rather than inventing a date for it.
  # Short read first, the full one only when it found nothing: no file is read
  # less thoroughly than before, and almost none is read as far.
  for cap in [DateProbeCap, 0]:
    try:
      let metadata = if cap > 0: readMetadata(path, cap) else: readMetadata(path)
      if metadata.isValid and metadata.creationDate.year >= 1900:
        return (metadata.creationDate.format("yyyy-MM-dd HH:mm:ss"), "metadata")
    except CatchableError:
      discard
  # An ISO base media file keeps its date in the `mvhd` header, which the image
  # metadata reader above does not look at — so a recording fell through to its
  # filename, or to the filesystem, while the real date sat in the container.
  if path.splitFile.ext.strip(chars = {'.'}).toLowerAscii() in MovieDateExts:
    try:
      let recorded = movieCreationDate(path)
      if recorded.found and recorded.moment.year >= 1900:
        return (recorded.moment.format("yyyy-MM-dd HH:mm:ss"), "metadata")
    except CatchableError:
      discard
  if filenameDate:
    let value = parseFilenameDate(path)
    if value.len > 0: return (value, "filename")
  if birthtimeDate:
    try:
      let created = getFileInfo(path).creationTime
      if created.toUnix() > 0:
        return (created.local.format("yyyy-MM-dd HH:mm:ss"), "birthtime")
    except CatchableError:
      discard

proc displayDimensions(path: string; width, height: int): tuple[width,
    height: int] =
  result = (width, height)
  if width <= 0 or height <= 0: return
  try:
    let orientation = readMetadata(path).orientation
    if orientation in 5 .. 8:
      result = (height, width)
  except CatchableError:
    discard

proc isInternal*(root, path: string): bool =
  ## True for the library's own bookkeeping: its database, its config, and
  ## anything under a dotted directory such as `.om-cache` or `.om-trash`.
  ## `path` must be under `root`; anything else relativizes to `..`, which
  ## every dotted-part check would answer yes to.
  let rel = relativePath(path, root)
  let first = rel.splitPath.head
  let name = path.extractFilename
  for part in rel.split(DirSep):
    if part.startsWith('.') and not part.startsWith(".om-tmp-"):
      return true
  name == ConfigName or name.startsWith(DatabaseName) or
  name.startsWith(LegacyDatabaseName) or
    name.startsWith(".om-tmp-") or first.startsWith(".om-tmp-")

type ScanWork = object
  ## One file, what the scan still owes it, and what a worker computed.
  ##
  ## Everything here is a pure function of the path, which is what lets a pool
  ## of workers do it while the catalogue stays on the one thread that owns the
  ## SQLite connection. What is needed is decided before any of it runs, from
  ## the row already on disk, so an unchanged library still hashes nothing.
  path, rel, category, ext: string
  size, mtimeNs: int64
  changed, wasNew: bool
  needsDate, needsExact, needsVisual, needsFrames, needsAudio: bool
  needsMediaInfo: bool
  date: tuple[value, source: string]
  coordinates: tuple[latitude, longitude: float; found: bool]
  exact: string
  exactFailed: bool
  visual: PerceptualHashInfo
  frames: seq[uint64]
  audio: AudioFingerprint
  media: ExternalMediaInfo
  sound: SoundInfo
  perceptualFailed, mediaFailed: bool

const GpsUpdate = "UPDATE items SET latitude=?,longitude=? " &
  "WHERE id=? AND latitude IS NULL AND longitude IS NULL"

const ScanChunk = 64
  ## Files computed per round. Large enough that the pool stays fed, small
  ## enough that progress moves and a cancellation is noticed while a big
  ## library is still being read.

proc compute(work: ptr UncheckedArray[ScanWork]; index: int;
             filenameDate, birthtimeDate: bool) {.gcsafe.} =
  ## The expensive half, off the catalogue's thread. Each failure is recorded
  ## against its own part: a file whose perceptual hash fails is still exactly
  ## hashed, exactly as when this ran serially.
  template item: untyped = work[index]
  let path = item.path
  if item.needsDate:
    item.date = mediaDate(path, filenameDate, birthtimeDate)
    item.coordinates = mediaCoordinates(path)
  if item.needsExact:
    try:
      item.exact = blake3File(path)
    except CatchableError:
      item.exactFailed = true
  if item.needsMediaInfo and item.category == "audio":
    # In process and from the header: `probeMedia` reads a container through
    # UniMovie and an audio file has no video track for it to find.
    try:
      item.sound = probeSound(path)
    except CatchableError:
      item.mediaFailed = true
  elif item.needsMediaInfo or item.needsFrames:
    try:
      item.media = probeMedia(path)
    except CatchableError:
      item.mediaFailed = true
  if item.needsVisual:
    try:
      item.visual = perceptualHashInfoFile(path)
    except CatchableError:
      item.perceptualFailed = true
  elif item.needsFrames:
    if item.mediaFailed:
      item.perceptualFailed = true
    else:
      try:
        # The probe above is the one this would otherwise make for itself.
        item.frames = videoFrameHashes(path, item.media)
      except CatchableError:
        item.perceptualFailed = true
  elif item.needsAudio:
    try:
      item.audio = audioFingerprint(path)
    except CatchableError:
      item.perceptualFailed = true

proc scanLibraryImpl(store: var Store; skipPhash: bool;
                     progress: ProgressCallback;
                     cancel: CancelCallback; jobs: int;
                     only: seq[string] = @[]): ScanReport =
  ## `only` names the files to re-read instead of walking the library. It also
  ## turns off the reconciliation below: a run that never looked at the rest of
  ## the library cannot conclude the rest of the library is gone.
  let narrowed = only.len > 0
  var paths: seq[string]
  if narrowed:
    for path in only:
      if symlinkExists(path) or not fileExists(path): continue
      if isInternal(store.library.root, path): continue
      if categoryFor(store.library.config.domain, path).len > 0: paths.add path
  else:
    for path in walkDirRec(store.library.root):
      checkCancelled(cancel)
      if symlinkExists(path): continue
      if isInternal(store.library.root, path): continue
      let category = categoryFor(store.library.config.domain, path)
      if category.len > 0: paths.add path
  paths.sort()

  # Asked once: both are a PATH lookup, and neither changes under a scan.
  let hasFfmpeg = externalMediaAvailable()
  let hasFingerprinter = audioFingerprintAvailable()
  let filenameDate = store.library.config.filenameDate
  let birthtimeDate = store.library.config.birthtimeDate

  var seen = initTable[string, bool]()
  var pending: seq[ScanWork]
  for path in paths:
    checkCancelled(cancel)
    let rel = relativePath(path, store.library.root)
    seen[rel] = true
    let info = getFileInfo(path)
    var work = ScanWork(path: path, rel: rel,
      category: categoryFor(store.library.config.domain, path),
      ext: path.splitFile.ext.strip(chars = {'.'}).toLowerAscii(),
      size: info.size,
      mtimeNs: int64(info.lastWriteTime.toUnixFloat() * 1_000_000_000.0))
    let old = store.db.getRow(sql"""
      SELECT id,file_size,mtime_ns,deleted_at,hash_status,phash_status
      FROM items WHERE rel_path=?""", rel)
    work.wasNew = old[0].len == 0
    work.changed = work.wasNew or old[1] != $work.size or
      old[2] != $work.mtimeNs or old[3].len > 0
    # A changed row is reset to pending by the upsert below, so it owes
    # everything; an unchanged one owes whatever its statuses still say.
    let exactStatus = if work.changed: "pending" else: old[4]
    let phashStatus = if work.changed: "pending" else: old[5]
    work.needsDate = work.changed
    work.needsExact = exactStatus in ["pending", "error"]
    let owesPerceptual = not skipPhash and phashStatus in ["pending", "error"]
    case work.category
    of "video":
      work.needsMediaInfo = work.changed and hasFfmpeg
      work.needsFrames = owesPerceptual and hasFfmpeg
    of "audio":
      work.needsAudio = owesPerceptual and hasFingerprinter
      # Read in process, so unlike a video's it does not wait on ffmpeg.
      work.needsMediaInfo = work.changed
    of "image":
      work.needsVisual = owesPerceptual
    else: discard
    pending.add work

  var done = 0
  var chunkStart = 0
  while chunkStart < pending.len:
    checkCancelled(cancel)
    let chunkEnd = min(chunkStart + ScanChunk, pending.len)
    # `jobs` bounds how many files are hashed at once. Awaiting a batch of that
    # size is what enforces it: the pool is sized by the machine and cannot be
    # resized, so the limit has to come from how much work is in flight. Zero
    # means the whole chunk, which is every core.
    let batch = if jobs > 0: min(jobs, ScanChunk) else: ScanChunk
    var batchStart = chunkStart
    while batchStart < chunkEnd:
      let batchEnd = min(batchStart + batch, chunkEnd)
      block:
        var m = createMaster()
        m.awaitAll:
          for index in batchStart ..< batchEnd:
            m.spawn compute(cast[ptr UncheckedArray[ScanWork]](addr pending[0]),
                            index, filenameDate, birthtimeDate)
      batchStart = batchEnd

    for index in chunkStart ..< chunkEnd:
      let work = addr pending[index]
      if work.changed:
        store.db.exec(sql"""
          INSERT INTO items(rel_path,file_size,mtime_ns,category,extension,
            creation_date,date_source,hash_status,indexed_at)
          VALUES(?,?,?,?,?,?,?,'pending',?)
          ON CONFLICT(rel_path) DO UPDATE SET
            file_size=excluded.file_size,mtime_ns=excluded.mtime_ns,
            category=excluded.category,extension=excluded.extension,
            creation_date=CASE WHEN items.date_source='curation'
              THEN items.creation_date ELSE excluded.creation_date END,
            date_source=CASE WHEN items.date_source='curation'
              THEN items.date_source ELSE excluded.date_source END,
            width=0,height=0,hash_status='pending',phash_status='pending',
            deleted_at=NULL,
            indexed_at=excluded.indexed_at
        """, work.rel, work.size, work.mtimeNs, work.category, work.ext,
          work.date.value, work.date.source, isoNow())
        if work.wasNew: inc result.indexed else: inc result.updated
      let itemId = store.db.getValue(sql"SELECT id FROM items WHERE rel_path=?",
        work.rel)
      if work.changed and work.coordinates.found:
        # Only where the catalogue has none. Coordinates that arrived from a
        # GPS track or from somebody correcting them are not overwritten by
        # what the file happens to say, which is the rule the creation date
        # follows too.
        store.db.exec(sql(GpsUpdate), work.coordinates.latitude,
          work.coordinates.longitude, itemId)
      let statuses = store.db.getRow(
        sql"SELECT hash_status,phash_status FROM items WHERE id=?", itemId)

      if work.needsExact:
        if work.exactFailed:
          store.db.exec(sql"UPDATE items SET hash_status='error' WHERE id=?",
            itemId)
          inc result.hashErrors
        else:
          store.db.exec(sql"""
            INSERT INTO item_hashes(item_id,blake3,computed_at) VALUES(?,?,?)
            ON CONFLICT(item_id) DO UPDATE SET blake3=excluded.blake3,
              computed_at=excluded.computed_at
          """, itemId, work.exact, isoNow())
          store.db.exec(sql"UPDATE items SET hash_status='hashed' WHERE id=?",
            itemId)

      case work.category
      of "video":
        if work.needsMediaInfo and not work.mediaFailed:
          store.db.exec(sql"UPDATE items SET width=?,height=? WHERE id=?",
            work.media.width, work.media.height, itemId)
        if not hasFfmpeg:
          # FFmpeg is optional, so its absence is a capability gap rather than
          # a hashing error: the item stays exactly indexed and visually
          # unhashed.
          if statuses[1] != "not-applicable":
            store.db.exec(
              sql"UPDATE items SET phash_status='not-applicable' WHERE id=?",
              itemId)
        elif work.needsFrames:
          if work.perceptualFailed or work.frames.len == 0:
            store.db.exec(sql"UPDATE items SET phash_status='error' WHERE id=?",
              itemId)
            inc result.hashErrors
          else:
            store.db.exec(sql"DELETE FROM item_frame_hashes WHERE item_id=?",
              itemId)
            for sequence, frame in work.frames:
              store.db.exec(sql"""INSERT INTO
                item_frame_hashes(item_id,seq,phash) VALUES(?,?,?)""",
                itemId, sequence, cast[int64](frame))
            # The first sampled frame also lands in item_hashes so single-hash
            # readers and the phash index keep working for video.
            store.db.exec(sql"""
              INSERT INTO item_hashes(item_id,phash,computed_at) VALUES(?,?,?)
              ON CONFLICT(item_id) DO UPDATE SET phash=excluded.phash,
                computed_at=excluded.computed_at
            """, itemId, cast[int64](work.frames[0]), isoNow())
            store.db.exec(sql"UPDATE items SET phash_status='hashed' WHERE id=?",
              itemId)
      of "audio":
        if work.needsMediaInfo and not work.mediaFailed:
          var meta = %*{"container": work.sound.container,
            "codec": work.sound.codec,
            "sampleRate": work.sound.sampleRate,
            "channels": work.sound.channels}
          # Only where the header states it: Ogg keeps the length in its last
          # page and MPEG audio in an optional one, and a guess recorded as a
          # duration is worse than none.
          if work.sound.durationKnown:
            meta["durationSeconds"] = %work.sound.durationSeconds
          let tags = work.sound.tags
          for pair in [("title", tags.title), ("artist", tags.artist),
              ("album", tags.album), ("albumArtist", tags.albumArtist),
              ("composer", tags.composer), ("genre", tags.genre),
              ("date", tags.date)]:
            if pair[1].len > 0: meta[pair[0]] = %pair[1]
          if tags.trackNumber > 0: meta["trackNumber"] = %tags.trackNumber
          if tags.discNumber > 0: meta["discNumber"] = %tags.discNumber
          store.db.exec(sql"UPDATE items SET meta_json=? WHERE id=?",
            $meta, itemId)
        if not hasFingerprinter:
          # Kept as a branch although fingerprinting is now linked in: a
          # build that cannot reach it leaves the item exactly indexed rather
          # than failing the scan.
          if statuses[1] != "not-applicable":
            store.db.exec(
              sql"UPDATE items SET phash_status='not-applicable' WHERE id=?",
              itemId)
        elif work.needsAudio:
          if work.perceptualFailed:
            store.db.exec(sql"UPDATE items SET phash_status='error' WHERE id=?",
              itemId)
            inc result.hashErrors
          else:
            var raw = newJArray()
            for value in work.audio.raw: raw.add %int64(value)
            store.db.exec(sql"""
              INSERT INTO item_audio_hashes(item_id,duration,raw_json)
              VALUES(?,?,?)
              ON CONFLICT(item_id) DO UPDATE SET duration=excluded.duration,
                raw_json=excluded.raw_json
            """, itemId, work.audio.durationSeconds, $raw)
            store.db.exec(sql"UPDATE items SET phash_status='hashed' WHERE id=?",
              itemId)
      of "image":
        if work.needsVisual:
          if work.perceptualFailed:
            store.db.exec(sql"UPDATE items SET phash_status='error' WHERE id=?",
              itemId)
            inc result.hashErrors
          else:
            store.db.exec(sql"""
              INSERT INTO item_hashes(item_id,phash,computed_at) VALUES(?,?,?)
              ON CONFLICT(item_id) DO UPDATE SET phash=excluded.phash,
                computed_at=excluded.computed_at
            """, itemId, cast[int64](work.visual.hash), isoNow())
            let display = displayDimensions(work.path, work.visual.width,
              work.visual.height)
            store.db.exec(sql"""
              UPDATE items SET phash_status='hashed',width=?,height=?
              WHERE id=?""", display.width, display.height, itemId)
      else:
        if statuses[1] != "not-applicable":
          store.db.exec(
            sql"UPDATE items SET phash_status='not-applicable' WHERE id=?",
            itemId)

      inc done
      if progress != nil:
        progress(ProgressEvent(phase: "scan", current: done,
          total: pending.len, message: work.rel))
    chunkStart = chunkEnd

  if not narrowed:
    for row in store.db.getAllRows(
        sql"""SELECT id,rel_path FROM items
          WHERE deleted_at IS NULL AND source='file'"""):
      # Only file-backed items are reconciled against the disk: an item with no
      # file of its own was never going to be walked, and must survive the scan.
      if not seen.hasKey(row[1]):
        store.db.exec(sql"DELETE FROM items WHERE id=?", row[0])
        inc result.removed

proc reindexPaths*(store: var Store; paths: seq[string];
                   skipPhash = true): ScanReport =
  ## Re-read the named files and nothing else.
  ##
  ## For an operation that touched a known set of files and needs the catalogue
  ## to match them again — an undo restoring originals whose size and hash
  ## differ from what was indexed. Walking the whole library to learn that would
  ## cost the library rather than the batch.
  ##
  ## A path that is absent or outside the library is passed over: an undo that
  ## restored some files and not others still reconciles the ones it did.
  if paths.len == 0: return
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    result = scanLibraryImpl(store, skipPhash, nil, nil, 0, paths)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc pendingPerceptualCount*(store: Store): int =
  ## How many active items still owe a perceptual hash.
  ##
  ## A scan may be told to skip that work, which is most of its cost and only
  ## duplicate detection needs it. Whoever does need it asks this first, so it
  ## can say how much is left instead of appearing to stall.
  store.db.getValue(sql"""
    SELECT count(*) FROM items
    WHERE deleted_at IS NULL AND phash_status IN ('pending', 'error')
  """).parseInt()

proc scanLibrary*(store: var Store; skipPhash = false;
                  progress: ProgressCallback = nil;
                  cancel: CancelCallback = nil; jobs = 0): ScanReport =
  ## `jobs` bounds how many files are hashed at once; 0 uses every core, which
  ## is what a machine doing nothing else wants and what a machine someone is
  ## working on does not.
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    result = scanLibraryImpl(store, skipPhash, progress, cancel, jobs)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

type CurationFacet = object
  title, description: string
  rating: int
  favorite: bool
  keywords: seq[string]

proc validFilterDate(value, field: string) =
  if value.len == 0: return
  try:
    discard parse(value, "yyyy-MM-dd")
  except TimeParseError:
    raise newException(ValueError, field & " must use YYYY-MM-DD")

proc normalizedFilterKeywords(values: seq[string]): seq[string] =
  var seen = initHashSet[string]()
  for value in values:
    let keyword = value.strip().toLowerAscii()
    if keyword.len == 0:
      raise newException(ValueError, "catalog keyword must not be empty")
    if keyword.len > 200:
      raise newException(ValueError, "catalog keyword must not exceed 200 bytes")
    if keyword notin seen:
      result.add keyword
      seen.incl keyword
  if result.len > 100:
    raise newException(ValueError,
      "catalog filter must not exceed 100 keywords")

proc addVirtualItem*(store: var Store; name, category: string;
                     meta: JsonNode = nil): int64 =
  ## Catalogue an item that has no file of its own -- a book or a bottle read
  ## from a barcode, say. It carries per-domain properties in `meta_json` and is
  ## exempt from scanning, hashing and the integrity audit, while albums,
  ## curation and smart albums treat it like any other item.
  let clean = name.strip
  if clean.len == 0:
    raise newException(ValueError, "virtual item name must not be empty")
  if category.strip.len == 0:
    raise newException(ValueError, "virtual item category must not be empty")
  if meta != nil and meta.kind != JObject:
    raise newException(ValueError, "virtual item metadata must be a JSON object")
  if store.db.getValue(sql"SELECT 1 FROM items WHERE rel_path=?", clean).len > 0:
    raise newException(ValueError, "item already exists: " & clean)
  store.db.exec(sql"""
    INSERT INTO items(rel_path,file_size,mtime_ns,category,extension,
      creation_date,date_source,hash_status,phash_status,source,meta_json,
      indexed_at)
    VALUES(?,0,0,?,'','','','not-applicable','not-applicable','virtual',?,?)
  """, clean, category.strip, (if meta == nil: "" else: $meta), isoNow())
  store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()

proc itemMeta*(store: Store; itemId: int64): string =
  ## Per-domain properties as stored, or an empty object when the item carries
  ## none. Raises for an unknown item, which an empty string cannot express.
  if store.db.getValue(sql"SELECT 1 FROM items WHERE id=?", itemId).len == 0:
    raise newException(KeyError, "unknown item: " & $itemId)
  let stored = store.db.getValue(sql"SELECT meta_json FROM items WHERE id=?",
    itemId)
  if stored.len == 0: "{}" else: stored

proc setItemMeta*(store: var Store; itemId: int64; meta: JsonNode) =
  ## Replace an item's per-domain properties. A JSON object keeps the carrier
  ## self-describing without a column per domain.
  if meta == nil or meta.kind != JObject:
    raise newException(ValueError, "item metadata must be a JSON object")
  if store.db.getValue(sql"SELECT 1 FROM items WHERE id=?", itemId).len == 0:
    raise newException(KeyError, "unknown item: " & $itemId)
  store.db.exec(sql"UPDATE items SET meta_json=? WHERE id=?", $meta, itemId)

proc filterItems*(store: Store; filter: CatalogFilter;
                  limit = 100; offset = 0): seq[Item] =
  ## Apply deterministic, combinable facets without requiring SQLite FTS/JSON1.
  if limit notin 1..10_000:
    raise newException(ValueError, "catalog filter limit must be between 1 and 10000")
  if offset < 0:
    raise newException(ValueError, "catalog filter offset must not be negative")
  if (filter.minRating.isSome and filter.minRating.get() notin 0..5) or
      (filter.maxRating.isSome and filter.maxRating.get() notin 0..5):
    raise newException(ValueError, "rating filters must be between 0 and 5")
  if filter.minRating.isSome and filter.maxRating.isSome and
      filter.minRating.get() > filter.maxRating.get():
    raise newException(ValueError, "minimum rating must not exceed maximum rating")
  if filter.kind.len > 0 and filter.kind notin ["image", "video", "audio"]:
    raise newException(ValueError, "catalog kind must be image, video, or audio")
  validFilterDate(filter.dateFrom, "date-from")
  validFilterDate(filter.dateTo, "date-to")
  if filter.dateFrom.len > 0 and filter.dateTo.len > 0 and
      filter.dateFrom > filter.dateTo:
    raise newException(ValueError, "date-from must not exceed date-to")

  var facets = initTable[int64, CurationFacet]()
  for row in store.db.getAllRows(sql"""
      SELECT item_id,title,description,rating,favorite,keywords_json
      FROM item_curations"""):
    var facet = CurationFacet(title: row[1], description: row[2],
      rating: row[3].parseInt(), favorite: row[4] == "1")
    try:
      for node in parseJson(row[5]): facet.keywords.add node.getStr()
    except CatchableError:
      raise newException(ValueError, "invalid keyword data in the catalogue")
    facets[row[0].parseBiggestInt()] = facet

  let text = filter.text.toLowerAscii()
  let location = filter.location.strip().toLowerAscii()
  if filter.location.len > 0 and location.len == 0:
    raise newException(ValueError, "catalog location must not be empty")
  if location.len > 1000:
    raise newException(ValueError, "catalog location must not exceed 1000 bytes")
  let keywords = normalizedFilterKeywords(filter.keywords)
  var matched = 0
  for item in store.listItems(filter.kind):
    let facet = facets.getOrDefault(item.id)
    if filter.minRating.isSome and facet.rating < filter.minRating.get(): continue
    if filter.maxRating.isSome and facet.rating > filter.maxRating.get(): continue
    if filter.favorite.isSome and facet.favorite != filter.favorite.get(): continue
    if filter.hasGps.isSome and
        (item.latitude.isSome and item.longitude.isSome) != filter.hasGps.get():
      continue
    if location.len > 0 and location notin item.locationText.toLowerAscii(): continue
    let date = if item.creationDate.len >= 10: item.creationDate[0..9] else: ""
    if filter.dateFrom.len > 0 and date < filter.dateFrom: continue
    if filter.dateTo.len > 0 and (date.len == 0 or date >
        filter.dateTo): continue
    var hasAllKeywords = true
    for keyword in keywords:
      var found = false
      for value in facet.keywords:
        if value.toLowerAscii() == keyword:
          found = true
          break
      if not found:
        hasAllKeywords = false
        break
    if not hasAllKeywords: continue
    if text.len > 0:
      var found = text in item.relPath.toLowerAscii() or
        text in facet.title.toLowerAscii() or
        text in facet.description.toLowerAscii() or
        text in item.locationText.toLowerAscii()
      if not found:
        for value in facet.keywords:
          if text in value.toLowerAscii():
            found = true
            break
      if not found: continue
    if matched < offset:
      inc matched
      continue
    result.add item
    if result.len == limit: break

proc listKeywordFacets*(store: Store; prefix = "";
                        limit = 100): seq[KeywordFacet] =
  ## Count distinct item membership per normalized keyword without SQLite JSON1.
  if limit notin 1..10_000:
    raise newException(ValueError,
      "keyword facet limit must be between 1 and 10000")
  let normalizedPrefix = prefix.strip().toLowerAscii()
  var counts = initCountTable[string]()
  for row in store.db.getAllRows(sql"""
      SELECT c.keywords_json FROM item_curations c
      JOIN items i ON i.id=c.item_id WHERE i.deleted_at IS NULL"""):
    var seen = initHashSet[string]()
    try:
      for node in parseJson(row[0]):
        let keyword = node.getStr().strip().toLowerAscii()
        if keyword.len > 0 and keyword.startsWith(normalizedPrefix):
          seen.incl keyword
    except CatchableError:
      raise newException(ValueError, "invalid keyword data in the catalogue")
    for keyword in seen: counts.inc keyword
  for keyword, count in counts:
    result.add KeywordFacet(keyword: keyword, itemCount: count)
  result.sort(proc(a, b: KeywordFacet): int =
    result = cmp(b.itemCount, a.itemCount)
    if result == 0: result = cmp(a.keyword, b.keyword))
  if result.len > limit: result.setLen(limit)

proc listPlaceFacets*(store: Store; prefix = "";
                      limit = 100): seq[PlaceFacet] =
  ## Group active items by case-insensitive location and average known GPS pairs.
  if limit notin 1..10_000:
    raise newException(ValueError,
      "place facet limit must be between 1 and 10000")
  let normalizedPrefix = prefix.strip().toLowerAscii()
  if prefix.len > 0 and normalizedPrefix.len == 0:
    raise newException(ValueError, "place prefix must not be empty")
  if normalizedPrefix.len > 1000:
    raise newException(ValueError, "place prefix must not exceed 1000 bytes")
  type PlaceAggregate = object
    spelling: string
    itemCount, gpsCount: int
    latitudeSum, longitudeSum: float
  var aggregates = initTable[string, PlaceAggregate]()
  for item in store.listItems():
    let spelling = item.locationText.strip()
    let normalized = spelling.toLowerAscii()
    if normalized.len == 0 or not normalized.startsWith(normalizedPrefix):
      continue
    var aggregate = aggregates.getOrDefault(normalized)
    if aggregate.spelling.len == 0 or spelling < aggregate.spelling:
      aggregate.spelling = spelling
    inc aggregate.itemCount
    if item.latitude.isSome and item.longitude.isSome:
      inc aggregate.gpsCount
      aggregate.latitudeSum += item.latitude.get()
      aggregate.longitudeSum += item.longitude.get()
    aggregates[normalized] = aggregate
  for _, aggregate in aggregates:
    var facet = PlaceFacet(location: aggregate.spelling,
      itemCount: aggregate.itemCount, gpsCount: aggregate.gpsCount)
    if aggregate.gpsCount > 0:
      facet.latitude = some(aggregate.latitudeSum / float(aggregate.gpsCount))
      facet.longitude = some(aggregate.longitudeSum / float(aggregate.gpsCount))
    result.add facet
  result.sort(proc(a, b: PlaceFacet): int =
    result = cmp(b.itemCount, a.itemCount)
    if result == 0:
      result = cmp(a.location.toLowerAscii(), b.location.toLowerAscii()))
  if result.len > limit: result.setLen(limit)
