# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Bounded GPX parsing and deterministic nearest-time geotagging plans.

import std/[algorithm, options, os, sequtils, sets, strutils, times, xmlparser, xmltree]
import UniMedia/[types, store, curation]

const
  MaxGpxBytes* = 64'i64 * 1024 * 1024
  MaxGpxPoints* = 1_000_000
  MaxGpxXmlDepth* = 128
  CanonicalDate = "yyyy-MM-dd HH:mm:ss"

proc localName(tag: string): string =
  let separator = tag.rfind(':')
  if separator >= 0: tag[separator + 1..^1] else: tag

proc rfc3339Time(value: string): Time =
  var candidate = value.strip()
  if candidate.endsWith('Z'):
    candidate = candidate[0..^2] & "+00:00"
  let timeSeparator = candidate.find('T')
  if timeSeparator < 0:
    raise newException(ValueError, "GPX time is not RFC 3339: " & value)
  var zoneAt = -1
  for index in countdown(candidate.high, timeSeparator + 1):
    if candidate[index] in {'+', '-'}:
      zoneAt = index
      break
  if zoneAt < 0:
    raise newException(ValueError, "GPX time requires a UTC offset: " & value)
  let fractionAt = candidate.find('.', timeSeparator)
  if fractionAt >= 0 and fractionAt < zoneAt:
    candidate = candidate[0..<fractionAt] & candidate[zoneAt..^1]
  try:
    result = parseTime(candidate, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
  except TimeParseError:
    raise newException(ValueError, "GPX time is not RFC 3339: " & value)

proc finiteCoordinate(value, field: string; limit: float): float =
  try: result = value.parseFloat()
  except ValueError:
    raise newException(ValueError, "invalid GPX " & field & ": " & value)
  if result != result or abs(result) > limit:
    raise newException(ValueError, "GPX " & field & " is outside valid ranges")

proc childText(node: XmlNode; wanted: string): string =
  for child in node:
    if child.kind == xnElement and localName(child.tag) == wanted:
      return child.innerText.strip()

proc collectPoints(node: XmlNode; points: var seq[GpxPoint]; depth = 0) =
  if node.kind != xnElement: return
  if depth > MaxGpxXmlDepth:
    raise newException(ValueError, "GPX XML nesting exceeds the safety limit")
  if localName(node.tag) == "trkpt":
    let lat = finiteCoordinate(node.attr("lat"), "latitude", 90.0)
    let lon = finiteCoordinate(node.attr("lon"), "longitude", 180.0)
    let timestamp = childText(node, "time")
    if timestamp.len == 0:
      raise newException(ValueError, "GPX track point has no time")
    var point = GpxPoint(timestamp: rfc3339Time(timestamp).toUnix(),
      latitude: lat, longitude: lon)
    let elevation = childText(node, "ele")
    if elevation.len > 0:
      var value: float
      try: value = elevation.parseFloat()
      except ValueError:
        raise newException(ValueError, "invalid GPX elevation: " & elevation)
      if value != value or abs(value) > 100_000.0:
        raise newException(ValueError, "GPX elevation is outside valid ranges")
      point.elevation = some(value)
    if points.len >= MaxGpxPoints:
      raise newException(ValueError, "GPX track exceeds the point safety limit")
    points.add point
  for child in node:
    collectPoints(child, points, depth + 1)

proc parseGpx*(path: string): seq[GpxPoint] =
  if symlinkExists(path):
    raise newException(ValueError, "GPX source must not be a symbolic link")
  if not fileExists(path):
    raise newException(IOError, "GPX source is missing: " & path)
  if getFileSize(path) > MaxGpxBytes:
    raise newException(ValueError, "GPX source exceeds the 64 MiB limit")
  let content = readFile(path)
  if "<!doctype" in content.toLowerAscii():
    raise newException(ValueError, "GPX DTD declarations are not supported")
  let document = try: parseXml(content)
    except CatchableError as error:
      raise newException(ValueError, "invalid GPX XML: " & error.msg)
  if document.kind != xnElement or localName(document.tag) != "gpx":
    raise newException(ValueError, "GPX document requires a gpx root element")
  collectPoints(document, result)
  if result.len == 0:
    raise newException(ValueError, "GPX track contains no timed points")
  result.sort(proc(a, b: GpxPoint): int =
    result = cmp(a.timestamp, b.timestamp)
    if result == 0: result = cmp(a.latitude, b.latitude)
    if result == 0: result = cmp(a.longitude, b.longitude))

proc nearest(points: seq[GpxPoint]; timestamp: int64): tuple[index: int;
    distance: int64] =
  var low = 0
  var high = points.len
  while low < high:
    let middle = (low + high) div 2
    if points[middle].timestamp < timestamp: low = middle + 1
    else: high = middle
  result.index = min(low, points.high)
  result.distance = abs(points[result.index].timestamp - timestamp)
  if result.index > 0:
    let previous = abs(points[result.index - 1].timestamp - timestamp)
    if previous <= result.distance:
      result = (result.index - 1, previous)

proc planGpxMatch*(store: Store; gpxPath: string; itemIds: seq[int64] = @[];
                   toleranceSeconds = 300;
                   cameraUtcOffsetMinutes = 0;
                   refresh = false): GpxMatchPlan =
  ## Match photographs to a track by time.
  ##
  ## An item that already carries a position is left alone: a camera's own fix
  ## is usually better than one interpolated from a logger, and redoing it
  ## costs time to produce a worse answer. `refresh` overrides that, for the
  ## items named in `itemIds` or for the whole library when none are.
  if toleranceSeconds < 0 or toleranceSeconds > 86_400:
    raise newException(ValueError, "GPX tolerance must be between 0 and 86400 seconds")
  if cameraUtcOffsetMinutes notin -14 * 60..14 * 60:
    raise newException(ValueError, "camera UTC offset is outside valid ranges")
  let points = parseGpx(gpxPath)
  result = GpxMatchPlan(sourcePath: absolutePath(gpxPath),
    toleranceSeconds: toleranceSeconds,
    cameraUtcOffsetMinutes: cameraUtcOffsetMinutes,
    trackPointCount: points.len, refreshed: refresh)
  var selected = itemIds
  if selected.len == 0:
    for item in store.listItems(): selected.add item.id
  var seen = initHashSet[int64]()
  for itemId in selected:
    if itemId <= 0:
      raise newException(ValueError, "GPX item ids must be positive")
    if itemId in seen: continue
    seen.incl itemId
    let item = store.getItem(itemId)
    var entry = GpxMatchEntry(itemId: item.id, relPath: item.relPath,
      creationDate: item.creationDate, distanceSeconds: -1,
      alreadyPlaced: item.latitude.isSome and item.longitude.isSome)
    if entry.alreadyPlaced and not refresh:
      # Carried in the plan rather than dropped from it, so the screen can say
      # how many were left alone instead of showing a smaller total with no
      # explanation.
      result.entries.add entry
      continue
    if item.creationDate.len > 0:
      let cameraTime = try: parse(item.creationDate, CanonicalDate, utc()).toTime()
        except TimeParseError:
          raise newException(ValueError,
            "catalogue contains an invalid creation date: " & item.relPath)
      let utcTimestamp = cameraTime.toUnix() -
        int64(cameraUtcOffsetMinutes) * 60
      let match = nearest(points, utcTimestamp)
      entry.distanceSeconds = match.distance
      if match.distance <= int64(toleranceSeconds):
        entry.matched = true
        entry.latitude = points[match.index].latitude
        entry.longitude = points[match.index].longitude
    result.entries.add entry

proc applyGpxMatch*(store: var Store; plan: GpxMatchPlan;
                    progress: ProgressCallback = nil;
                    cancel: CancelCallback = nil): CurationBatchReport =
  var matches = 0
  for entry in plan.entries:
    let item = store.getItem(entry.itemId)
    if item.relPath != entry.relPath or item.creationDate != entry.creationDate:
      raise newException(ValueError, "GPX plan is stale: " & entry.relPath)
    if entry.matched: inc matches
  if matches == 0:
    # Saying "no matches" when every item was skipped sends somebody to widen
    # the tolerance, which cannot help.
    if plan.entries.len > 0 and plan.entries.allIt(it.alreadyPlaced):
      raise newException(ValueError,
        "every item in this plan already carries a position; " &
        "plan again with refresh to replace them")
    raise newException(ValueError, "GPX plan contains no matches")
  var current = 0
  for entry in plan.entries:
    if not entry.matched: continue
    if cancel != nil and cancel():
      raise newException(OperationCancelledError,
        "GPX apply cancelled after " & $result.applied & " item(s)")
    inc current
    try:
      var patch: CurationPatch
      patch.latitude = some(entry.latitude)
      patch.longitude = some(entry.longitude)
      discard store.curateItem(entry.itemId, patch)
      inc result.applied
    except CatchableError as error:
      inc result.failed
      result.failures.add CurationBatchFailure(itemId: entry.itemId,
        relPath: entry.relPath, error: error.msg)
    if progress != nil:
      progress(ProgressEvent(phase: "gpx", current: current, total: matches,
        message: entry.relPath))
