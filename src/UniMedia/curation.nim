# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Crash-recoverable item curation backed by XMP sidecars and SQLite.

import std/[json, options, os, sets, strutils, sysrand, tables, times]
import db_connector/db_sqlite
import UniImage/exif/xmp
import UniMedia/[types, store]

const OrganizeMediaXmpNs* = "https://lituus-lab.com/ns/organize-media/1.0/"

const
  XmpCreateDate = "xmp:CreateDate"
  XmpLatitude = "exif:GPSLatitude"
  XmpLongitude = "exif:GPSLongitude"
  XmpLocation = "Iptc4xmpCore:Location"

proc opId(): string =
  result = "curation_"
  for value in urandom(16):
    result.add value.toHex(2).toLowerAscii()

proc normalizedText(value, field: string; maximum: int): string =
  result = value.strip()
  if result.len > maximum:
    raise newException(ValueError, field & " must not exceed " & $maximum &
      " bytes")
  for ch in result:
    if ch < ' ' and ch notin {'\t', '\n'}:
      raise newException(ValueError, field & " must not contain control characters")

proc normalizedKeywords(values: seq[string]): seq[string] =
  var seen = initHashSet[string]()
  for value in values:
    let keyword = normalizedText(value, "keyword", 200)
    let folded = keyword.toLowerAscii()
    if keyword.len > 0 and folded notin seen:
      result.add keyword
      seen.incl folded
  if result.len > 100:
    raise newException(ValueError, "curation must not exceed 100 keywords")

proc normalizedKeywordEdit(values: seq[string]; operation: string): seq[string] =
  for value in values:
    if value.strip().len == 0:
      raise newException(ValueError,
        operation & " keyword must not be empty")
  normalizedKeywords(values)

proc sidecarPath(store: Store; item: Item): string =
  let media = store.absoluteItemPath(item.relPath)
  let exact = media & ".xmp"
  let parts = splitFile(media)
  let stem = parts.dir / (parts.name & ".xmp")
  result = if fileExists(exact) or symlinkExists(exact): exact
           elif fileExists(stem) or symlinkExists(stem): stem
           else: exact
  discard checkedPathUnder(store.library.root, result)
  if symlinkExists(result):
    raise newException(ValueError, "XMP sidecar must not be a symbolic link")

proc parseRating(value: string): int =
  try: result = value.parseInt()
  except ValueError: return 0
  if result notin 0..5: result = 0

proc normalizedCreationDate(value: string): string =
  let candidate = value.strip()
  if candidate.len == 0: return ""
  for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]:
    try:
      let parsed = parse(candidate, format)
      if parsed.format(format) == candidate:
        return parsed.format("yyyy-MM-dd HH:mm:ss")
    except TimeParseError:
      discard
  raise newException(ValueError,
    "date must be YYYY-MM-DD or YYYY-MM-DD[ T]HH:MM:SS")

proc coordinateText(value: Option[float]): string =
  if value.isSome: $value.get() else: ""

proc xmpCoordinate(value: float; latitude: bool): string =
  let absolute = abs(value)
  let degrees = int(absolute)
  var minutes = formatFloat((absolute - float(degrees)) * 60.0,
    ffDecimal, 8)
  while '.' in minutes and minutes.endsWith('0'): minutes.setLen(minutes.len - 1)
  if minutes.endsWith('.'): minutes.setLen(minutes.len - 1)
  let direction = if latitude:
      (if value < 0: "S" else: "N")
    else:
      (if value < 0: "W" else: "E")
  $degrees & "," & minutes & direction

proc catalogCoordinate(value: string): Option[float] =
  if value.len == 0: return none(float)
  try:
    result = some(value.parseFloat())
  except ValueError:
    raise newException(ValueError, "invalid coordinate in the catalogue")

proc validateCoordinates(latitude, longitude: Option[float]) =
  if latitude.isSome != longitude.isSome:
    raise newException(ValueError, "latitude and longitude must be set together")
  if latitude.isSome:
    let lat = latitude.get()
    let lon = longitude.get()
    if lat != lat or lon != lon or abs(lat) > 90.0 or abs(lon) > 180.0:
      raise newException(ValueError, "coordinates are outside valid ranges")

proc validateCurationPatch*(patch: CurationPatch) =
  ## Validate state-independent constraints without writing a sidecar or SQLite.
  if patch.title.isNone and patch.description.isNone and patch.rating.isNone and
      patch.favorite.isNone and patch.keywords.isNone and
      patch.addKeywords.len == 0 and patch.removeKeywords.len == 0 and
      patch.creationDate.isNone and patch.latitude.isNone and
      patch.longitude.isNone and not patch.clearGps and
      patch.locationText.isNone and patch.creator.isNone and
      patch.copyright.isNone:
    raise newException(ValueError, "curation patch requires at least one edit")
  if patch.keywords.isSome and
      (patch.addKeywords.len > 0 or patch.removeKeywords.len > 0):
    raise newException(ValueError,
      "keyword replacement cannot be combined with add/remove")
  if patch.clearGps and (patch.latitude.isSome or patch.longitude.isSome):
    raise newException(ValueError,
      "GPS clearing cannot be combined with coordinates")
  validateCoordinates(patch.latitude, patch.longitude)
  discard normalizedText(if patch.title.isSome: patch.title.get() else: "",
    "title", 1000)
  discard normalizedText(if patch.description.isSome:
    patch.description.get() else: "", "description", 10_000)
  discard normalizedText(if patch.copyright.isSome:
    patch.copyright.get() else: "", "copyright", 1000)
  if patch.creator.isSome:
    for name in patch.creator.get():
      discard normalizedText(name, "creator", 1000)
  if patch.rating.isSome and patch.rating.get() notin 0..5:
    raise newException(ValueError, "rating must be between 0 and 5")
  if patch.keywords.isSome:
    discard normalizedKeywords(patch.keywords.get())
  let additions = normalizedKeywordEdit(patch.addKeywords, "added")
  let removals = normalizedKeywordEdit(patch.removeKeywords, "removed")
  var removalSet = initHashSet[string]()
  for keyword in removals: removalSet.incl keyword.toLowerAscii()
  for keyword in additions:
    if keyword.toLowerAscii() in removalSet:
      raise newException(ValueError, "the same keyword cannot be added and removed")
  if patch.creationDate.isSome:
    discard normalizedCreationDate(patch.creationDate.get())
  if patch.locationText.isSome:
    discard normalizedText(patch.locationText.get(), "location", 1000)

proc stateFromXmp(item: Item; xml: string): ItemCuration =
  let metadata = parseXmp(xml)
  result = ItemCuration(itemId: item.id, title: metadata.title,
    description: metadata.description,
    keywords: normalizedKeywords(metadata.keywords),
    creator: metadata.creator, copyright: metadata.rights,
    creationDate: item.creationDate, dateSource: item.dateSource,
    latitude: item.latitude, longitude: item.longitude,
    locationText: item.locationText)
  if metadata.all.hasKey("xmp:Rating"):
    result.rating = parseRating(metadata.all["xmp:Rating"])
  if metadata.all.hasKey("om:Favorite"):
    result.favorite = metadata.all["om:Favorite"].toLowerAscii() in ["1", "true"]

proc keywordsJson(values: seq[string]): string = $(%values)

proc decodeKeywords(value: string): seq[string] =
  try:
    for node in parseJson(value): result.add node.getStr()
  except CatchableError:
    raise newException(ValueError, "invalid keyword data in the catalogue")

proc curationFromRow(row: Row): ItemCuration =
  ItemCuration(itemId: row[0].parseBiggestInt(), title: row[1],
    description: row[2], rating: row[3].parseInt(), favorite: row[4] == "1",
    keywords: decodeKeywords(row[5]), updatedAt: row[6], creationDate: row[7],
    dateSource: row[8], latitude: catalogCoordinate(row[9]),
    longitude: catalogCoordinate(row[10]), locationText: row[11],
    creator: decodeKeywords(row[12]), copyright: row[13])

proc getItemCuration*(store: Store; itemId: int64): ItemCuration =
  discard store.getItem(itemId)
  let row = store.db.getRow(sql"""
    SELECT c.item_id,c.title,c.description,c.rating,c.favorite,c.keywords_json,
      c.updated_at,i.creation_date,i.date_source,i.latitude,i.longitude,
      i.location_text,c.creator_json,c.copyright
    FROM item_curations c JOIN items i ON i.id=c.item_id
    WHERE c.item_id=?""", itemId)
  if row[0].len > 0: return curationFromRow(row)
  let item = store.getItem(itemId)
  ItemCuration(itemId: itemId, creationDate: item.creationDate,
    dateSource: item.dateSource, latitude: item.latitude,
    longitude: item.longitude, locationText: item.locationText)

proc writeState(db: DbConn; state: ItemCuration) =
  db.exec(sql"""
    INSERT INTO item_curations(item_id,title,description,rating,favorite,
      keywords_json,creator_json,copyright,updated_at)
    VALUES(?,?,?,?,?,?,?,?,?)
    ON CONFLICT(item_id) DO UPDATE SET title=excluded.title,
      description=excluded.description,rating=excluded.rating,
      favorite=excluded.favorite,keywords_json=excluded.keywords_json,
      creator_json=excluded.creator_json,copyright=excluded.copyright,
      updated_at=excluded.updated_at""", state.itemId, state.title,
    state.description, state.rating, ord(state.favorite),
    keywordsJson(state.keywords), keywordsJson(state.creator),
    state.copyright, state.updatedAt)
  let latitude = coordinateText(state.latitude)
  let longitude = coordinateText(state.longitude)
  db.exec(sql"""
    UPDATE items SET creation_date=?,date_source=?,
      latitude=CASE WHEN ?='' THEN NULL ELSE CAST(? AS REAL) END,
      longitude=CASE WHEN ?='' THEN NULL ELSE CAST(? AS REAL) END,
      location_text=? WHERE id=?""", state.creationDate, state.dateSource,
    latitude, latitude, longitude, longitude, state.locationText, state.itemId)

proc replaceSidecar(path, oldXml, newXml, id: string; oldExists: bool) =
  let temporary = path & ".om-tmp-" & id
  let backup = path & ".om-backup-" & id
  if fileExists(temporary) or symlinkExists(temporary) or fileExists(backup) or
      symlinkExists(backup):
    raise newException(IOError, "curation recovery file already exists")
  if fileExists(path) != oldExists or
      (oldExists and readFile(path) != oldXml):
    raise newException(IOError, "XMP sidecar changed during the curation operation")
  writeFile(temporary, newXml)
  try:
    if oldExists: moveFile(path, backup)
    try:
      moveFile(temporary, path)
    except CatchableError:
      if oldExists and fileExists(backup) and not fileExists(path):
        moveFile(backup, path)
      raise
    if fileExists(backup): removeFile(backup)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc recoverCurationOps*(store: var Store) =
  for row in store.db.getAllRows(sql"""
      SELECT id,item_id,sidecar_rel_path,old_exists,old_xmp,new_xmp,title,
        description,rating,favorite,keywords_json,creation_date,date_source,
        latitude,longitude,location_text,creator_json,copyright
      FROM curation_ops WHERE status='pending' ORDER BY created_at,id"""):
    let path = checkedPathUnder(store.library.root,
      store.library.root / row[2])
    let backup = path & ".om-backup-" & row[0]
    let oldExists = row[3] == "1"
    let state = ItemCuration(itemId: row[1].parseBiggestInt(), title: row[6],
      description: row[7], rating: row[8].parseInt(), favorite: row[9] == "1",
      keywords: decodeKeywords(row[10]), creationDate: row[11],
      dateSource: row[12], latitude: catalogCoordinate(row[13]),
      longitude: catalogCoordinate(row[14]), locationText: row[15],
      creator: decodeKeywords(row[16]), copyright: row[17],
      updatedAt: isoNow())
    store.db.exec(sql"BEGIN IMMEDIATE")
    try:
      if store.db.getValue(sql"SELECT status FROM curation_ops WHERE id=?",
          row[0]) != "pending":
        store.db.exec(sql"COMMIT")
        continue
      if symlinkExists(path) or symlinkExists(backup):
        raise newException(ValueError, "curation recovery path is a symbolic link")
      if fileExists(path) and readFile(path) == row[5]:
        if fileExists(backup): removeFile(backup)
      else:
        if not fileExists(path) and oldExists and fileExists(backup) and
            readFile(backup) == row[4]:
          moveFile(backup, path)
        replaceSidecar(path, row[4], row[5], row[0], oldExists)
      writeState(store.db, state)
      store.db.exec(sql"UPDATE curation_ops SET status='applied',error=NULL WHERE id=?",
        row[0])
      store.db.exec(sql"COMMIT")
    except CatchableError as error:
      store.db.exec(sql"ROLLBACK")
      store.db.exec(sql"UPDATE curation_ops SET status='failed',error=? WHERE id=?",
        error.msg, row[0])

proc curateItem*(store: var Store; itemId: int64;
                 patch: CurationPatch): ItemCuration =
  validateCurationPatch(patch)
  let additions = normalizedKeywordEdit(patch.addKeywords, "added")
  let removals = normalizedKeywordEdit(patch.removeKeywords, "removed")
  var removalSet = initHashSet[string]()
  for keyword in removals: removalSet.incl keyword.toLowerAscii()
  recoverCurationOps(store)
  let item = store.getItem(itemId)
  let path = sidecarPath(store, item)
  let oldExists = fileExists(path)
  let oldXml = if oldExists: readFile(path) else: buildXmp(XmpData())
  result = stateFromXmp(item, oldXml)
  if patch.title.isSome:
    result.title = normalizedText(patch.title.get(), "title", 1000)
  if patch.description.isSome:
    result.description = normalizedText(patch.description.get(), "description", 10_000)
  if patch.rating.isSome:
    if patch.rating.get() notin 0..5:
      raise newException(ValueError, "rating must be between 0 and 5")
    result.rating = patch.rating.get()
  if patch.favorite.isSome: result.favorite = patch.favorite.get()
  if patch.keywords.isSome: result.keywords = normalizedKeywords(
      patch.keywords.get())
  if patch.creator.isSome:
    # Order is meaningful in dc:creator, so this list is not normalised the way
    # keywords are; only blank entries go.
    result.creator = @[]
    for name in patch.creator.get():
      let clean = name.strip
      if clean.len > 0: result.creator.add normalizedText(clean, "creator", 1000)
  if patch.copyright.isSome:
    result.copyright = normalizedText(patch.copyright.get(), "copyright", 1000)
  if removals.len > 0:
    var retained: seq[string]
    for keyword in result.keywords:
      if keyword.toLowerAscii() notin removalSet: retained.add keyword
    result.keywords = retained
  if additions.len > 0:
    result.keywords = normalizedKeywords(result.keywords & additions)
  if patch.creationDate.isSome:
    result.creationDate = normalizedCreationDate(patch.creationDate.get())
    result.dateSource = "curation"
  if patch.clearGps:
    result.latitude = none(float)
    result.longitude = none(float)
  elif patch.latitude.isSome:
    result.latitude = patch.latitude
    result.longitude = patch.longitude
  if patch.locationText.isSome:
    result.locationText = normalizedText(patch.locationText.get(), "location", 1000)
  result.updatedAt = isoNow()

  if item.source != "file":
    # No media on disk means no sidecar to mirror and nothing to recover: the
    # catalogue row is the only state, so it commits on its own.
    store.db.exec(sql"BEGIN IMMEDIATE")
    try:
      writeState(store.db, result)
      store.db.exec(sql"COMMIT")
    except CatchableError:
      store.db.exec(sql"ROLLBACK")
      raise
    return

  var xmpPatch: XmpPatch
  xmpPatch.title = some(result.title)
  xmpPatch.description = some(result.description)
  xmpPatch.keywords = some(result.keywords)
  if patch.creator.isSome: xmpPatch.creator = some(result.creator)
  if patch.copyright.isSome: xmpPatch.rights = some(result.copyright)
  xmpPatch.properties["xmp:Rating"] = some($result.rating)
  xmpPatch.namespaces["om"] = OrganizeMediaXmpNs
  xmpPatch.properties["om:Favorite"] = some($result.favorite)
  if patch.creationDate.isSome:
    xmpPatch.properties[XmpCreateDate] = some(result.creationDate.replace(' ', 'T'))
  if patch.clearGps:
    xmpPatch.properties[XmpLatitude] = none(string)
    xmpPatch.properties[XmpLongitude] = none(string)
  elif patch.latitude.isSome:
    xmpPatch.properties[XmpLatitude] = some(xmpCoordinate(result.latitude.get(), true))
    xmpPatch.properties[XmpLongitude] = some(xmpCoordinate(result.longitude.get(), false))
  if patch.locationText.isSome:
    xmpPatch.properties[XmpLocation] = some(result.locationText)
  let newXml = mergeXmp(oldXml, xmpPatch)
  let id = opId()
  let sidecarRel = relativePath(path, store.library.root)
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"""
      INSERT INTO curation_ops(id,item_id,sidecar_rel_path,old_exists,old_xmp,
        new_xmp,title,description,rating,favorite,keywords_json,creator_json,
        copyright,creation_date,
        date_source,latitude,longitude,location_text,status,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,
        CASE WHEN ?='' THEN NULL ELSE CAST(? AS REAL) END,
        CASE WHEN ?='' THEN NULL ELSE CAST(? AS REAL) END,?,'pending',?)""",
      id, itemId, sidecarRel,
      ord(oldExists), oldXml, newXml, result.title, result.description,
      result.rating, ord(result.favorite), keywordsJson(result.keywords),
      keywordsJson(result.creator), result.copyright,
      result.creationDate, result.dateSource, coordinateText(result.latitude),
      coordinateText(result.latitude), coordinateText(result.longitude),
      coordinateText(result.longitude), result.locationText, isoNow())
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    if store.db.getValue(sql"SELECT status FROM curation_ops WHERE id=?", id) !=
        "pending":
      raise newException(IOError, "curation operation is no longer pending")
    replaceSidecar(path, oldXml, newXml, id, oldExists)
    writeState(store.db, result)
    store.db.exec(sql"UPDATE curation_ops SET status='applied',error=NULL WHERE id=?",
      id)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise
