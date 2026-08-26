# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Provider-neutral reverse-geocoding cache and journaled location plans.

import std/[math, options, sets, strutils]
import db_connector/db_sqlite
import UniMedia/[types, store, curation]

proc normalizedIdentifier(value, field: string; maximum: int): string =
  result = value.strip()
  if result.len == 0 or result.len > maximum:
    raise newException(ValueError,
      field & " must contain between 1 and " & $maximum & " bytes")
  for character in result:
    if character < ' ' or character == '\x7f':
      raise newException(ValueError, field & " contains control characters")

proc coordinateKey(value: float): int64 =
  int64(round(value * 1_000_000.0))

proc cached(store: Store; provider, language: string; latitude,
            longitude: float): tuple[found: bool; value: ReverseGeocodeResult] =
  let row = store.db.getRow(sql"""
    SELECT location_text,attribution FROM geocode_cache
    WHERE provider=? AND language=? AND latitude_e6=? AND longitude_e6=?""",
    provider, language, coordinateKey(latitude), coordinateKey(longitude))
  if row[0].len > 0:
    result.found = true
    result.value = ReverseGeocodeResult(locationText: row[0],
      attribution: row[1])

proc cache(store: var Store; provider, language: string; latitude,
           longitude: float; value: ReverseGeocodeResult) =
  store.db.exec(sql"""
    INSERT INTO geocode_cache(provider,language,latitude_e6,longitude_e6,
      location_text,attribution,fetched_at) VALUES(?,?,?,?,?,?,?)
    ON CONFLICT(provider,language,latitude_e6,longitude_e6) DO UPDATE SET
      location_text=excluded.location_text,
      attribution=excluded.attribution,fetched_at=excluded.fetched_at""",
    provider, language, coordinateKey(latitude), coordinateKey(longitude),
    value.locationText, value.attribution, isoNow())

proc validateResult(value: ReverseGeocodeResult): ReverseGeocodeResult =
  result.locationText = normalizedIdentifier(value.locationText,
    "geocoded location", 2000)
  result.attribution = normalizedIdentifier(value.attribution,
    "geocoder attribution", 2000)

proc planReverseGeocode*(store: var Store; providerName, language: string;
                         provider: ReverseGeocodeProvider;
                         itemIds: seq[int64] = @[];
                         overwrite = false;
                         refreshCache = false): ReverseGeocodePlan =
  ## Cache fills are the only mutation performed while planning.
  let name = normalizedIdentifier(providerName, "provider", 200)
  let locale = normalizedIdentifier(language, "language", 64)
  result = ReverseGeocodePlan(provider: name, language: locale)
  var selected = itemIds
  if selected.len == 0:
    for item in store.listItems(): selected.add item.id
  var seen = initHashSet[int64]()
  for itemId in selected:
    if itemId <= 0:
      raise newException(ValueError, "reverse geocode item ids must be positive")
    if itemId in seen: continue
    seen.incl itemId
    let item = store.getItem(itemId)
    if item.latitude.isNone: continue
    if item.longitude.isNone:
      raise newException(ValueError,
        "catalogue contains incomplete coordinates: " & item.relPath)
    if item.locationText.len > 0 and not overwrite: continue
    let latitude = item.latitude.get()
    let longitude = item.longitude.get()
    var lookup = store.cached(name, locale, latitude, longitude)
    var fromCache = lookup.found and not refreshCache
    if not fromCache:
      if provider == nil:
        raise newException(ValueError,
          "reverse geocode cache miss requires a provider")
      lookup.value = validateResult(provider(latitude, longitude, locale))
      store.cache(name, locale, latitude, longitude, lookup.value)
    result.entries.add ReverseGeocodeEntry(itemId: item.id,
      relPath: item.relPath, oldLocation: item.locationText,
      newLocation: lookup.value.locationText,
      attribution: lookup.value.attribution, latitude: latitude,
      longitude: longitude, fromCache: fromCache)

proc applyReverseGeocode*(store: var Store; plan: ReverseGeocodePlan;
                          progress: ProgressCallback = nil;
                          cancel: CancelCallback = nil): CurationBatchReport =
  if plan.entries.len == 0:
    raise newException(ValueError, "reverse geocode plan is empty")
  for entry in plan.entries:
    let item = store.getItem(entry.itemId)
    let identityChanged = item.relPath != entry.relPath or
      item.locationText != entry.oldLocation
    let coordinatesMissing = item.latitude.isNone or item.longitude.isNone
    let coordinatesChanged = not coordinatesMissing and
      (item.latitude.get() != entry.latitude or
       item.longitude.get() != entry.longitude)
    if identityChanged or coordinatesMissing or coordinatesChanged:
      raise newException(ValueError,
        "reverse geocode plan is stale: " & entry.relPath)
  for index, entry in plan.entries:
    if cancel != nil and cancel():
      raise newException(OperationCancelledError,
        "reverse geocode cancelled after " & $result.applied & " item(s)")
    try:
      var patch: CurationPatch
      patch.locationText = some(entry.newLocation)
      discard store.curateItem(entry.itemId, patch)
      inc result.applied
    except CatchableError as error:
      inc result.failed
      result.failures.add CurationBatchFailure(itemId: entry.itemId,
        relPath: entry.relPath, error: error.msg)
    if progress != nil:
      progress(ProgressEvent(phase: "reverse-geocode", current: index + 1,
        total: plan.entries.len, message: entry.relPath))
