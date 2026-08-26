# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[json, options, os, strutils, sets]
import UniMedia/[types, config, store, catalog, timeline, privacy, curate, organize,
  curation, smartalbums, dedup, thumbnails, external_media, external_audio,
  trash, removal]
import UniMedia/help
import UniMedia/integrity
import UniMedia/privacy_strip
import UniMedia/cleanup
import UniMedia/batch_curation
import UniMedia/date_edit
import UniMedia/gpx
import UniMedia/[reverse_geocode, nominatim_client]
import UniMedia/[people, vision, sync]
import UniMedia/face_detect

proc takeFlag(args: var seq[string]; name: string): bool =
  let index = args.find(name)
  if index >= 0:
    args.delete(index)
    return true

proc takeValue(args: var seq[string]; name: string; fallback = ""): string =
  for index, value in args:
    if value.startsWith(name & "="):
      result = value[name.len + 1..^1]
      args.delete(index)
      return
    if value == name:
      if index + 1 >= args.len:
        raise newException(ValueError, name & " requires a value")
      result = args[index + 1]
      args.delete(index + 1)
      args.delete(index)
      return
  fallback

proc hasOption(args: seq[string]; name: string): bool =
  for value in args:
    if value == name or value.startsWith(name & "="): return true

proc takeValues(args: var seq[string]; name: string): seq[string] =
  var index = 0
  while index < args.len:
    if args[index].startsWith(name & "="):
      result.add args[index][name.len + 1..^1]
      args.delete(index)
    elif args[index] == name:
      if index + 1 >= args.len:
        raise newException(ValueError, name & " requires a value")
      result.add args[index + 1]
      args.delete(index + 1)
      args.delete(index)
    else:
      inc index

proc metaFromPairs(pairs: seq[string]): JsonNode =
  ## Repeated --meta KEY=VALUE. Values stay strings: the shell does not guess
  ## types for a domain the engine does not model.
  if pairs.len == 0: return nil
  result = newJObject()
  for pair in pairs:
    let separator = pair.find('=')
    if separator <= 0:
      raise newException(ValueError, "--meta expects KEY=VALUE, got: " & pair)
    result[pair[0 ..< separator]] = %pair[separator + 1 .. ^1]

proc takeCurationPatch(args: var seq[string]): CurationPatch =
  let hasTitle = hasOption(args, "--title")
  let hasDescription = hasOption(args, "--description")
  let hasRating = hasOption(args, "--rating")
  let hasKeywords = hasOption(args, "--keywords")
  let hasDate = hasOption(args, "--date")
  let hasLatitude = hasOption(args, "--latitude")
  let hasLongitude = hasOption(args, "--longitude")
  let hasLocation = hasOption(args, "--location")
  let hasCopyright = hasOption(args, "--copyright")
  let title = takeValue(args, "--title")
  let description = takeValue(args, "--description")
  let ratingText = takeValue(args, "--rating")
  let keywordsText = takeValue(args, "--keywords")
  let date = takeValue(args, "--date")
  let latitudeText = takeValue(args, "--latitude")
  let longitudeText = takeValue(args, "--longitude")
  let location = takeValue(args, "--location")
  let copyright = takeValue(args, "--copyright")
  # Repeatable rather than comma-separated: "Doe, John" is a plausible name,
  # and dc:creator is an ordered list.
  let creators = takeValues(args, "--creator")
  result.addKeywords = takeValues(args, "--add-keyword")
  result.removeKeywords = takeValues(args, "--remove-keyword")
  let favorite = takeFlag(args, "--favorite")
  let notFavorite = takeFlag(args, "--no-favorite")
  result.clearGps = takeFlag(args, "--clear-gps")
  let clearCreator = takeFlag(args, "--clear-creator")
  if clearCreator and creators.len > 0:
    raise newException(ValueError,
      "--creator and --clear-creator are mutually exclusive")
  if favorite and notFavorite:
    raise newException(ValueError,
      "--favorite and --no-favorite are mutually exclusive")
  if hasTitle: result.title = some(title)
  if hasDescription: result.description = some(description)
  if hasRating:
    try: result.rating = some(ratingText.parseInt())
    except ValueError:
      raise newException(ValueError, "invalid rating: " & ratingText)
  if hasKeywords:
    result.keywords = some(if keywordsText.len == 0: @[]
      else: keywordsText.split(','))
  if hasDate: result.creationDate = some(date)
  if hasLatitude:
    try: result.latitude = some(latitudeText.parseFloat())
    except ValueError:
      raise newException(ValueError, "invalid latitude: " & latitudeText)
  if hasLongitude:
    try: result.longitude = some(longitudeText.parseFloat())
    except ValueError:
      raise newException(ValueError, "invalid longitude: " & longitudeText)
  if hasLocation: result.locationText = some(location)
  if hasCopyright: result.copyright = some(copyright)
  if clearCreator: result.creator = some(newSeq[string]())
  elif creators.len > 0: result.creator = some(creators)
  if favorite: result.favorite = some(true)
  if notFavorite: result.favorite = some(false)
  validateCurationPatch(result)

proc requireNoOptions(args: seq[string]) =
  for value in args:
    if value.startsWith('-'):
      raise newException(ValueError, "unknown option: " & value)

proc itemJson(item: Item): JsonNode =
  result = %*{
    "id": item.id, "path": item.relPath, "size": item.fileSize,
    "category": item.category, "extension": item.extension,
    "creationDate": item.creationDate, "dateSource": item.dateSource,
    "width": item.width, "height": item.height, "hashStatus": item.hashStatus,
    "phashStatus": item.phashStatus, "location": item.locationText
  }
  result["latitude"] = if item.latitude.isSome: %item.latitude.get()
                       else: newJNull()
  result["longitude"] = if item.longitude.isSome: %item.longitude.get()
                        else: newJNull()

proc writeItem(item: Item; jsonOutput: bool) =
  if jsonOutput:
    echo $itemJson(item)
  else:
    echo item.id, "\t", item.category, "\t", item.relPath

proc writeKeywordFacet(facet: KeywordFacet; jsonOutput: bool) =
  if jsonOutput:
    echo $(%*{"keyword": facet.keyword, "itemCount": facet.itemCount})
  else:
    echo facet.itemCount, "\t", facet.keyword

proc writePlaceFacet(facet: PlaceFacet; jsonOutput: bool) =
  if jsonOutput:
    var node = %*{"location": facet.location, "itemCount": facet.itemCount,
      "gpsCount": facet.gpsCount}
    node["latitude"] = if facet.latitude.isSome: %facet.latitude.get()
                       else: newJNull()
    node["longitude"] = if facet.longitude.isSome: %facet.longitude.get()
                        else: newJNull()
    echo $node
  else:
    echo facet.itemCount, "\t", facet.gpsCount, "\t", facet.location, "\t",
      (if facet.latitude.isSome: $facet.latitude.get() else: ""), "\t",
      (if facet.longitude.isSome: $facet.longitude.get() else: "")

proc writeProgress(event: ProgressEvent) {.gcsafe.} =
  stderr.writeLine(event.phase, "\t", event.current, "/", event.total, "\t",
    event.message)

proc writeProgressJson(event: ProgressEvent) {.gcsafe.} =
  stderr.writeLine($(%*{"phase": event.phase, "current": event.current,
    "total": event.total, "message": event.message}))

proc progressWriter(enabled, asJson: bool): ProgressCallback =
  ## One progress sink for every long operation: absent, human TSV, or one JSON
  ## object per line. Both formats go to stderr so stdout stays parsable.
  if not enabled: nil
  elif asJson: writeProgressJson
  else: writeProgress

var cancelFlag = false

proc requestCancel*() =
  ## Ask the running operation to stop at its next cooperative boundary. The
  ## process boundary calls this from its interrupt hook; tests call it directly.
  cancelFlag = true

proc cancelRequested(): bool {.gcsafe.} = cancelFlag

proc planJson(operation: PlannedOp): JsonNode = %*{
  "operation": $operation.kind, "source": operation.sourcePath,
  "destination": operation.destRelPath, "size": operation.size,
  "date": operation.creationDate, "dateSource": operation.dateSource,
  "skipReason": operation.skipReason
}

proc albumJson(album: Album): JsonNode =
  result = %*{"id": album.id, "name": album.name,
    "createdAt": album.createdAt, "itemCount": album.itemCount}
  result["coverItem"] = if album.coverItemId > 0: %album.coverItemId
                        else: newJNull()
  result["parent"] = if album.parentId > 0: %album.parentId else: newJNull()

proc curationJson(curation: ItemCuration): JsonNode =
  result = %*{
    "item": curation.itemId, "title": curation.title,
    "description": curation.description, "rating": curation.rating,
    "favorite": curation.favorite, "keywords": curation.keywords,
    "creator": curation.creator, "copyright": curation.copyright,
    "creationDate": curation.creationDate, "dateSource": curation.dateSource,
    "location": curation.locationText, "updatedAt": curation.updatedAt
  }
  result["latitude"] = if curation.latitude.isSome: %curation.latitude.get()
                       else: newJNull()
  result["longitude"] = if curation.longitude.isSome: %curation.longitude.get()
                        else: newJNull()

proc writeCuration(curation: ItemCuration; jsonOutput: bool) =
  if jsonOutput:
    echo $curationJson(curation)
  else:
    echo "Item ", curation.itemId
    echo "Title: ", curation.title
    echo "Description: ", curation.description
    echo "Rating: ", curation.rating
    echo "Favorite: ", curation.favorite
    echo "Keywords: ", curation.keywords.join(", ")
    echo "Creator: ", curation.creator.join(", ")
    echo "Copyright: ", curation.copyright
    echo "Creation date: ", curation.creationDate
    echo "Date source: ", curation.dateSource
    echo "Location: ", curation.locationText
    echo "Latitude: ", if curation.latitude.isSome: $curation.latitude.get()
                       else: ""
    echo "Longitude: ", if curation.longitude.isSome: $curation.longitude.get()
                        else: ""

proc smartAlbumJson(album: SmartAlbum): JsonNode =
  result = %*{"id": album.id, "name": album.name, "matchAll": album.matchAll,
    "createdAt": album.createdAt, "itemCount": album.itemCount}
  var rules = newJArray()
  for rule in album.rules:
    rules.add %*{"field": rule.field, "operator": rule.operator,
      "value": rule.value}
  result["rules"] = rules

proc writeSmartAlbum(album: SmartAlbum; jsonOutput: bool) =
  if jsonOutput: echo $smartAlbumJson(album)
  else: echo album.id, "\t", album.itemCount, "\t", album.name

proc parseId(value, kind: string): int64 =
  try:
    result = value.parseBiggestInt()
  except ValueError:
    raise newException(ValueError, "invalid " & kind & " id: " & value)
  if result <= 0:
    raise newException(ValueError, "invalid " & kind & " id: " & value)

const ActionGroups = ["catalog", "geo", "faces", "vision", "sync", "dedup"]
  ## Groups that do nothing without an action word, so a bare one is a
  ## question. The rest either take a positional argument or act as named.

proc runCli*(rawArgs: seq[string]): int =
  var args = rawArgs
  # Asked for by position, not by presence anywhere in the line: `--title
  # --help` sets a title to "--help", and printing the usage there would throw
  # away the edit the caller was making. It is a help request only where it
  # opens the line, or where it follows a command name.
  if args.len == 0 or args[0] in ["--help", "-h"]:
    stdout.write overview(UniMediaVersion)
    return 0
  for index in 1 ..< args.len:
    if args[index] notin ["--help", "-h"]: continue
    if findGroup(args[index - 1]) >= 0:
      stdout.write groupHelp(args[index - 1])
      return 0
    break
  if takeFlag(args, "--version"):
    echo "om ", UniMediaVersion
    return 0
  let jsonOutput = takeFlag(args, "--json")
  # --progress-json implies --progress: a caller asking for machine-readable
  # progress always wants the events.
  let progressJson = takeFlag(args, "--progress-json")
  # One invocation, one cancellation state: an interrupted run must not poison
  # the next call inside an embedding process.
  defer: cancelFlag = false
  let libraryRoot = takeValue(args, "--library")
  if args.len == 0: raise newException(ValueError, "missing command")
  let command = args[0]
  args.delete(0)

  if command == "catalog" and args.len > 0 and args[0] == "init":
    args.delete(0)
    let domain = takeValue(args, "--domain")
    let schemeText = takeValue(args, "--scheme", "YYYY/MM-DD")
    if domain.len == 0: raise newException(ValueError, "--domain is required")
    if args.len != 1: raise newException(ValueError, "catalog init requires one directory")
    let library = initLibrary(args[0], parseDomain(domain), parseScheme(schemeText))
    if jsonOutput: echo $(%*{"library": library.root,
        "domain": $library.config.domain})
    else: echo "Initialized ", library.root
    return 0

  # Before the library is opened: a probe asks about one file and has no
  # catalogue to consult, so requiring a library would be asking for something
  # it does not use.
  if command == "probe":
    if args.len != 1:
      raise newException(ValueError, "probe requires one file")
    # A still is asked about the same way a video is, so the command answers
    # for both: `probeMedia` looks for a `moov` box, which a photograph has
    # none of. The video error is the one reported when neither reads it,
    # since a file that is neither is far more often a broken video.
    # Video, then still, then sound. `probeMedia` looks for a `moov` box, which
    # neither a photograph nor a track has; the video error is the one kept
    # when none of the three reads the file, since a file that is none of them
    # is far more often a broken video.
    var sound: SoundInfo
    var isSound = false
    let info = try: probeMedia(args[0])
      except ExternalMediaError as videoError:
        try: probeStill(args[0])
        except ExternalMediaError:
          try:
            sound = probeSound(args[0])
            isSound = true
            ExternalMediaInfo(format: sound.container, codec: sound.codec,
              durationSeconds: sound.durationSeconds)
          except CatchableError: raise videoError
    if jsonOutput:
      echo pretty(%*{"path": absolutePath(args[0]), "width": info.width,
        "height": info.height, "displayWidth": info.displayWidth,
        "displayHeight": info.displayHeight, "rotation": info.rotation,
        "durationSeconds": info.durationSeconds, "codec": info.codec,
        "format": info.format})
    elif isSound:
      echo "format\t", info.format
      echo "codec\t", info.codec
      echo "rate\t", sound.sampleRate, " Hz"
      echo "channels\t", sound.channels
      # Absent rather than zero where the container does not state it.
      if sound.durationKnown:
        echo "duration\t", sound.durationSeconds, "s"
      if sound.tags.title.len > 0: echo "title\t", sound.tags.title
      if sound.tags.artist.len > 0: echo "artist\t", sound.tags.artist
      if sound.tags.album.len > 0: echo "album\t", sound.tags.album
    else:
      echo "format\t", info.format
      echo "codec\t", info.codec
      echo "coded\t", info.width, "x", info.height
      echo "display\t", info.displayWidth, "x", info.displayHeight
      echo "rotation\t", info.rotation
      echo "duration\t", info.durationSeconds, "s"
    return 0

  # A group named with nothing after it is a question, not an operation, and a
  # reader asking what `dedup` is has not chosen a library yet. Answer it
  # before demanding one, then still say what running it would need. Exit 2
  # either way: a script that reached here did not run what it meant to.
  if args.len == 0 and command in ActionGroups:
    stdout.write groupHelp(command)
    if libraryRoot.len == 0:
      # stderr is unbuffered and stdout is not, so without this the one
      # actionable line lands above the help it belongs under.
      stdout.flushFile()
      stderr.writeLine "om: --library is required"
    return 2

  if libraryRoot.len == 0: raise newException(ValueError, "--library is required")
  var store = openLibrary(libraryRoot)
  defer: store.close()

  case command
  of "catalog":
    let action = args[0]
    args.delete(0)
    case action
    of "scan":
      let noPhash = takeFlag(args, "--no-phash")
      let showProgress = takeFlag(args, "--progress")
      let jobsText = takeValue(args, "--jobs")
      requireNoOptions(args)
      if args.len != 0: raise newException(ValueError, "catalog scan takes no path")
      let jobs = if jobsText.len == 0: 0
        else:
          let parsed = try: jobsText.parseInt()
            except ValueError:
              raise newException(ValueError, "--jobs must be a number")
          if parsed < 1:
            raise newException(ValueError, "--jobs must be at least 1")
          parsed
      let report = scanLibrary(store, noPhash,
        progressWriter(showProgress or progressJson, progressJson),
        cancelRequested, jobs)
      if jsonOutput: echo $(%*{"indexed": report.indexed,
        "updated": report.updated,
        "removed": report.removed, "hashErrors": report.hashErrors})
      else: echo "Indexed ", report.indexed, ", updated ", report.updated,
        ", removed ", report.removed, ", hash errors ", report.hashErrors
    of "list":
      let kind = takeValue(args, "--kind")
      let paged = hasOption(args, "--limit") or hasOption(args, "--offset")
      let limitText = takeValue(args, "--limit", "100")
      let offsetText = takeValue(args, "--offset", "0")
      let limit = try: limitText.parseInt()
                  except ValueError: raise newException(ValueError,
                    "invalid list limit: " & limitText)
      let offset = try: offsetText.parseInt()
                   except ValueError: raise newException(ValueError,
                     "invalid list offset: " & offsetText)
      requireNoOptions(args)
      if args.len != 0: raise newException(ValueError, "catalog list takes no positional arguments")
      let items = if paged: store.listItemsPage(kind, limit, offset)
                  else: store.listItems(kind)
      for item in items:
        writeItem(item, jsonOutput)
    of "show":
      requireNoOptions(args)
      if args.len != 1: raise newException(ValueError, "catalog show requires one item id")
      let id = try: args[0].parseBiggestInt()
               except ValueError: raise newException(ValueError,
                   "invalid item id: " & args[0])
      writeItem(store.getItem(id), jsonOutput)
    of "search":
      let kind = takeValue(args, "--kind")
      let limitText = takeValue(args, "--limit", "100")
      let offsetText = takeValue(args, "--offset", "0")
      let limit = try: limitText.parseInt()
                  except ValueError: raise newException(ValueError,
                      "invalid search limit: " & limitText)
      let offset = try: offsetText.parseInt()
                   except ValueError: raise newException(ValueError,
                     "invalid search offset: " & offsetText)
      requireNoOptions(args)
      if args.len != 1: raise newException(ValueError,
          "catalog search requires one query")
      for item in store.searchItems(args[0], kind, limit, offset):
        writeItem(item, jsonOutput)
    of "thumbnail":
      let sizeText = takeValue(args, "--size", "256")
      let size = try: sizeText.parseInt()
                 except ValueError: raise newException(ValueError,
                   "invalid thumbnail size: " & sizeText)
      requireNoOptions(args)
      if args.len != 1:
        raise newException(ValueError, "catalog thumbnail requires one item id")
      let thumbnail = ensureThumbnail(store, parseId(args[0], "item"), size)
      if jsonOutput:
        echo $(%*{"item": thumbnail.itemId, "path": thumbnail.path,
          "width": thumbnail.width, "height": thumbnail.height,
          "maxEdge": thumbnail.maxEdge, "cacheHit": thumbnail.cacheHit})
      else:
        echo thumbnail.path
    of "filter":
      var filter: CatalogFilter
      filter.kind = takeValue(args, "--kind")
      filter.keywords = takeValues(args, "--keyword")
      filter.dateFrom = takeValue(args, "--from")
      filter.dateTo = takeValue(args, "--to")
      let hasLocation = hasOption(args, "--location")
      filter.location = takeValue(args, "--location")
      if hasLocation and filter.location.strip().len == 0:
        raise newException(ValueError, "catalog location must not be empty")
      let minRating = takeValue(args, "--min-rating")
      let maxRating = takeValue(args, "--max-rating")
      if minRating.len > 0:
        try: filter.minRating = some(minRating.parseInt())
        except ValueError:
          raise newException(ValueError, "invalid minimum rating: " & minRating)
      if maxRating.len > 0:
        try: filter.maxRating = some(maxRating.parseInt())
        except ValueError:
          raise newException(ValueError, "invalid maximum rating: " & maxRating)
      let favorite = takeFlag(args, "--favorite")
      let notFavorite = takeFlag(args, "--no-favorite")
      if favorite and notFavorite:
        raise newException(ValueError,
          "--favorite and --no-favorite are mutually exclusive")
      if favorite: filter.favorite = some(true)
      if notFavorite: filter.favorite = some(false)
      let hasGps = takeFlag(args, "--has-gps")
      let noGps = takeFlag(args, "--no-gps")
      if hasGps and noGps:
        raise newException(ValueError,
          "--has-gps and --no-gps are mutually exclusive")
      if hasGps: filter.hasGps = some(true)
      if noGps: filter.hasGps = some(false)
      let limitText = takeValue(args, "--limit", "100")
      let offsetText = takeValue(args, "--offset", "0")
      let limit = try: limitText.parseInt()
                  except ValueError: raise newException(ValueError,
                    "invalid filter limit: " & limitText)
      let offset = try: offsetText.parseInt()
                   except ValueError: raise newException(ValueError,
                     "invalid filter offset: " & offsetText)
      requireNoOptions(args)
      if args.len > 1:
        raise newException(ValueError,
          "catalog filter accepts at most one text query")
      if args.len == 1: filter.text = args[0]
      if filter.text.len == 0 and filter.kind.len == 0 and
          filter.keywords.len == 0 and filter.dateFrom.len == 0 and
          filter.dateTo.len == 0 and filter.minRating.isNone and
          filter.maxRating.isNone and filter.favorite.isNone:
        if filter.location.len == 0 and filter.hasGps.isNone:
          raise newException(ValueError, "catalog filter requires at least one facet")
      for item in filterItems(store, filter, limit, offset):
        writeItem(item, jsonOutput)
    of "keywords":
      let prefix = takeValue(args, "--prefix")
      let limitText = takeValue(args, "--limit", "100")
      let limit = try: limitText.parseInt()
                  except ValueError: raise newException(ValueError,
                    "invalid keyword limit: " & limitText)
      requireNoOptions(args)
      if args.len != 0:
        raise newException(ValueError, "catalog keywords accepts no arguments")
      for facet in listKeywordFacets(store, prefix, limit):
        writeKeywordFacet(facet, jsonOutput)
    of "add-virtual":
      let category = takeValue(args, "--kind", "other")
      let pairs = takeValues(args, "--meta")
      requireNoOptions(args)
      if args.len != 1:
        raise newException(ValueError, "catalog add-virtual requires one name")
      let id = addVirtualItem(store, args[0], category, metaFromPairs(pairs))
      if jsonOutput: echo $(%*{"item": id, "name": args[0].strip,
        "kind": category})
      else: echo "Added virtual item ", id
    of "meta":
      let pairs = takeValues(args, "--meta")
      requireNoOptions(args)
      if args.len != 1:
        raise newException(ValueError, "catalog meta requires one item id")
      let itemId = parseId(args[0], "item")
      if pairs.len > 0: setItemMeta(store, itemId, metaFromPairs(pairs))
      echo itemMeta(store, itemId)
    else: raise newException(ValueError, "unknown catalog action: " & action)
  of "geo":
    let action = args[0]
    args.delete(0)
    case action
    of "places":
      let prefix = takeValue(args, "--prefix")
      let limitText = takeValue(args, "--limit", "100")
      let limit = try: limitText.parseInt()
                  except ValueError: raise newException(ValueError,
                    "invalid place limit: " & limitText)
      requireNoOptions(args)
      if args.len != 0:
        raise newException(ValueError, "geo places accepts no arguments")
      for facet in listPlaceFacets(store, prefix, limit):
        writePlaceFacet(facet, jsonOutput)
    of "reverse":
      let providerName = takeValue(args, "--provider")
      let language = takeValue(args, "--language", "en")
      let endpoint = takeValue(args, "--endpoint")
      let userAgent = takeValue(args, "--user-agent")
      let network = takeFlag(args, "--network")
      let overwrite = takeFlag(args, "--overwrite")
      let refresh = takeFlag(args, "--refresh-cache")
      let confirmed = takeFlag(args, "--yes")
      let showProgress = takeFlag(args, "--progress")
      if providerName.len == 0:
        raise newException(ValueError, "geo reverse requires --provider")
      if refresh and not network:
        raise newException(ValueError, "--refresh-cache requires --network")
      if network and (endpoint.len == 0 or userAgent.len == 0):
        raise newException(ValueError,
          "--network requires --endpoint and --user-agent")
      if not network and (endpoint.len > 0 or userAgent.len > 0):
        raise newException(ValueError,
          "--endpoint and --user-agent require explicit --network")
      requireNoOptions(args)
      var itemIds: seq[int64]
      for item in args: itemIds.add parseId(item, "item")
      let provider = if network: newNominatimProvider(endpoint, userAgent)
        else: nil
      let plan = planReverseGeocode(store, providerName, language, provider,
        itemIds, overwrite, refresh)
      if not confirmed:
        for entry in plan.entries:
          if jsonOutput:
            echo $(%*{"operation": "reverse-geocode", "item": entry.itemId,
              "path": entry.relPath, "oldLocation": entry.oldLocation,
              "newLocation": entry.newLocation,
              "attribution": entry.attribution, "fromCache": entry.fromCache})
          else:
            echo "PLACE\t", entry.itemId, "\t", entry.oldLocation, " -> ",
              entry.newLocation, "\t", entry.attribution
      else:
        let report = applyReverseGeocode(store, plan,
          progressWriter(showProgress or progressJson, progressJson),
          cancelRequested)
        if jsonOutput:
          echo $(%*{"applied": report.applied, "failed": report.failed})
        else:
          echo "Located ", report.applied, ", failed ", report.failed
        if report.failed > 0: return 3
    else:
      raise newException(ValueError, "unknown geo action: " & action)
  of "organize":
    if args.len < 2: raise newException(ValueError, "organize requires plan|apply and a source")
    let action = args[0]
    args.delete(0)
    var options = defaultOrganizeOptions(store.library.config)
    let wantsMove = takeFlag(args, "--move")
    let wantsCopy = takeFlag(args, "--copy")
    let wantsHardlink = takeFlag(args, "--hardlink")
    if wantsMove.int + wantsCopy.int + wantsHardlink.int > 1:
      raise newException(ValueError,
        "--copy, --move and --hardlink are mutually exclusive")
    if wantsMove: options.mode = tmMove
    if wantsCopy: options.mode = tmCopy
    if wantsHardlink: options.mode = tmHardlink
    let confirmed = takeFlag(args, "--yes")
    let showProgress = takeFlag(args, "--progress")
    let wantsFilenameDate = takeFlag(args, "--filename-date")
    let rejectsFilenameDate = takeFlag(args, "--no-filename-date")
    if wantsFilenameDate and rejectsFilenameDate:
      raise newException(ValueError,
        "--filename-date and --no-filename-date are mutually exclusive")
    if wantsFilenameDate: options.filenameDate = true
    if rejectsFilenameDate: options.filenameDate = false
    let wantsBirthtime = takeFlag(args, "--birthtime-date")
    let rejectsBirthtime = takeFlag(args, "--no-birthtime-date")
    if wantsBirthtime and rejectsBirthtime:
      raise newException(ValueError,
        "--birthtime-date and --no-birthtime-date are mutually exclusive")
    if wantsBirthtime: options.birthtimeDate = true
    if rejectsBirthtime: options.birthtimeDate = false
    options.keepDuplicates = takeFlag(args, "--keep-duplicate")
    let schemeText = takeValue(args, "--scheme")
    if schemeText.len > 0: options.scheme = parseScheme(schemeText)
    options.noDateDir = takeValue(args, "--no-date-dir", options.noDateDir)
    let conflict = takeValue(args, "--on-conflict")
    if conflict.len > 0: options.onConflict = parseConflict(conflict)
    requireNoOptions(args)
    if args.len != 1: raise newException(ValueError, "organize requires exactly one source")
    # Reported for both actions: planning is the long half on a slow source,
    # and it used to run to completion before the flag was even looked at --
    # so an invalid combination cost the whole walk before saying so.
    let plan = planOrganize(store, args[0], options,
      progressWriter(showProgress or progressJson, progressJson))
    case action
    of "plan":
      for operation in plan.operations:
        if jsonOutput: echo $planJson(operation)
        else:
          let verb = if operation.skipReason.len > 0: "SKIP " &
              operation.skipReason
                     else: ($operation.kind).toUpperAscii()
          echo verb, "\t", operation.sourcePath, " -> ", operation.destRelPath
    of "apply":
      if options.mode == tmMove and not confirmed:
        raise newException(ValueError, "moving files requires --yes")
      let report = applyPlan(store, plan,
        progressWriter(showProgress or progressJson, progressJson))
      if jsonOutput: echo $(%*{"batch": report.batchId,
        "applied": report.applied,
        "skipped": report.skipped, "failed": report.failed})
      else: echo "Batch ", report.batchId, ": applied ", report.applied,
        ", skipped ", report.skipped, ", failed ", report.failed
      if report.failed > 0: return 3
    else: raise newException(ValueError, "unknown organize action: " & action)
  of "timeline":
    if args.len == 0 or args[0] != "report":
      raise newException(ValueError, "timeline requires the report action")
    args.delete(0)
    let period = parseTimelinePeriod(takeValue(args, "--by", "month"))
    requireNoOptions(args)
    if args.len != 0:
      raise newException(ValueError, "timeline report takes no positional arguments")
    for bucket in timelineReport(store, period):
      if jsonOutput:
        echo $(%*{"period": bucket.period, "items": bucket.itemCount,
          "bytes": bucket.totalBytes})
      else:
        echo bucket.period, "\t", bucket.itemCount, "\t", bucket.totalBytes
  of "privacy":
    if args.len == 0:
      raise newException(ValueError, "privacy requires audit or strip")
    let action = args[0]
    args.delete(0)
    case action
    of "audit":
      requireNoOptions(args)
      if args.len != 0:
        raise newException(ValueError, "privacy audit takes no arguments")
      for finding in privacyAudit(store):
        if jsonOutput:
          echo $(%*{"item": finding.itemId, "path": finding.relPath,
            "signals": finding.signals, "error": finding.error})
        else:
          let details = if finding.error.len > 0: "error:" & finding.error
                        else: finding.signals.join(",")
          echo finding.itemId, "\t", details, "\t", finding.relPath
    of "strip":
      let confirmed = takeFlag(args, "--yes")
      let showProgress = takeFlag(args, "--progress")
      requireNoOptions(args)
      var itemIds: seq[int64]
      for value in args: itemIds.add parseId(value, "item")
      let plan = planPrivacyStrip(store, itemIds)
      if not confirmed:
        for entry in plan.entries:
          if jsonOutput:
            echo $(%*{"operation": "strip", "item": entry.itemId,
              "path": entry.relPath, "signals": entry.signals,
              "strippable": entry.strippable})
          else:
            # SKIP, not STRIP: the format carries the metadata but this tool
            # cannot rewrite it, and a dry run that says otherwise is a lie.
            echo (if entry.strippable: "STRIP\t" else: "SKIP\t"),
              entry.relPath, "\t", entry.signals.join(",")
      else:
        let report = applyPrivacyStrip(store, plan,
          progressWriter(showProgress or progressJson, progressJson))
        if jsonOutput:
          echo $(%*{"batch": report.batchId, "stripped": report.applied,
            "skipped": report.skipped, "failed": report.failed})
        else:
          echo "Batch ", report.batchId, ": stripped ", report.applied,
            ", skipped ", report.skipped, ", failed ", report.failed
        if report.failed > 0: return 3
    else:
      raise newException(ValueError, "unknown privacy action: " & action)
  of "config":
    if args.len == 0 or args[0] notin ["show", "set"]:
      raise newException(ValueError, "config requires show or set")
    let action = args[0]
    args.delete(0)
    if action == "show":
      requireNoOptions(args)
      let config = store.library.config
      if jsonOutput:
        echo pretty(%*{"schemaVersion": config.schemaVersion,
          "domain": $config.domain, "scheme": $config.scheme,
          "filenameDate": config.filenameDate,
          "birthtimeDate": config.birthtimeDate,
          "noDateDir": config.noDateDir, "onConflict": $config.onConflict})
      else:
        echo "domain\t", config.domain
        echo "scheme\t", config.scheme
        echo "filenameDate\t", config.filenameDate
        echo "birthtimeDate\t", config.birthtimeDate
        echo "noDateDir\t", config.noDateDir
        echo "onConflict\t", config.onConflict
    else:
      if args.len == 0:
        raise newException(ValueError, "config set requires at least one KEY=VALUE")
      var updated = store.library.config
      for assignment in args:
        let split = assignment.find('=')
        if split <= 0:
          raise newException(ValueError, "expected KEY=VALUE, got: " & assignment)
        let key = assignment[0 ..< split]
        let value = assignment[split + 1 .. ^1]
        # Parsed through the same readers the file uses, so a value the config
        # would reject is refused here rather than written and found later.
        case key
        of "scheme": updated.scheme = parseScheme(value)
        of "onConflict": updated.onConflict = parseConflict(value)
        of "domain": updated.domain = parseDomain(value)
        of "noDateDir": updated.noDateDir = value
        of "filenameDate", "birthtimeDate":
          let flag = case value
            of "true", "yes", "on", "1": true
            of "false", "no", "off", "0": false
            else: raise newException(ValueError,
              key & " must be true or false, got: " & value)
          if key == "filenameDate": updated.filenameDate = flag
          else: updated.birthtimeDate = flag
        of "schemaVersion":
          raise newException(ValueError, "schemaVersion is not settable")
        else: raise newException(ValueError, "unknown preference: " & key)
      writeConfig(store.library.root, updated)
      if jsonOutput: echo $(%*{"updated": args.len})
      else: echo "Updated ", args.len, " preference(s)"
  of "trash":
    if args.len == 0 or args[0] notin ["list", "empty"]:
      raise newException(ValueError, "trash requires list or empty")
    let action = args[0]
    args.delete(0)
    if action == "list":
      requireNoOptions(args)
      for batch in listTrash(store):
        if jsonOutput:
          echo $(%*{"batch": batch.batchId, "when": batch.createdAt,
            "mode": batch.mode, "status": batch.status,
            "files": batch.fileCount, "bytes": batch.totalBytes,
            "undoable": batch.undoable})
        else:
          echo batch.batchId, "\t", batch.createdAt, "\t", batch.mode, "\t",
            batch.fileCount, " file(s)\t", batch.totalBytes, " bytes\t",
            (if batch.undoable: "undoable" else: batch.status)
    else:
      let confirmed = takeFlag(args, "--yes")
      let showProgress = takeFlag(args, "--progress")
      let ageText = takeValue(args, "--older-than", "0")
      let age = try: ageText.parseInt()
        except ValueError:
          raise newException(ValueError, "invalid --older-than: " & ageText)
      requireNoOptions(args)
      if not confirmed:
        for batch in planEmptyTrash(store, args, age):
          if jsonOutput:
            echo $(%*{"operation": "empty", "batch": batch.batchId,
              "when": batch.createdAt, "files": batch.fileCount,
              "bytes": batch.totalBytes})
          else:
            # EMPTY, not REMOVE: what these hold does not move anywhere.
            echo "EMPTY\t", batch.batchId, "\t", batch.fileCount,
              " file(s)\t", batch.totalBytes, " bytes"
      else:
        let report = emptyTrash(store, args, age,
          progressWriter(showProgress or progressJson, progressJson))
        if jsonOutput:
          echo $(%*{"batches": report.batches, "files": report.files,
            "freedBytes": report.freedBytes, "failed": report.failed})
        else:
          echo "Emptied ", report.batches, " batch(es), ", report.files,
            " file(s), ", report.freedBytes, " bytes freed, failed ",
            report.failed
          echo "these are gone; undo can no longer reach them"
        if report.failed > 0: return 3
  of "items":
    if args.len < 2 or args[0] != "remove":
      raise newException(ValueError, "items requires remove ITEM...")
    args.delete(0)
    let confirmed = takeFlag(args, "--yes")
    let permanently = takeFlag(args, "--permanently")
    requireNoOptions(args)
    var itemIds: seq[int64]
    for value in args: itemIds.add parseId(value, "item")
    if not confirmed:
      for itemId in itemIds:
        let item = store.getItem(itemId)
        if jsonOutput:
          echo $(%*{"operation": if permanently: "delete" else: "remove",
            "item": item.id, "path": item.relPath})
        else:
          # DELETE where nothing is kept, so the word matches the act.
          echo (if permanently: "DELETE\t" else: "REMOVE\t"), item.id, "\t",
            item.relPath
      if permanently:
        echo "these would be deleted outright — no trash, no undo"
    else:
      let report = trashItems(store, itemIds, permanently)
      if jsonOutput:
        echo $(%*{"batch": report.batchId, "removed": report.applied,
          "failed": report.failed})
      else:
        echo "Removed ", report.applied, ", failed ", report.failed
        if report.batchId.len > 0: echo "undo restores them"
        else: echo "deleted outright; there is no way back"
      if report.failed > 0: return 3
  of "cleanup":
    let confirmed = takeFlag(args, "--yes")
    let permanently = takeFlag(args, "--permanently")
    let showProgress = takeFlag(args, "--progress")
    var kinds = initHashSet[CleanupKind]()
    while true:
      let value = takeValue(args, "--kind")
      if value.len == 0: break
      var known = false
      for kind in CleanupKind:
        if $kind == value:
          kinds.incl kind
          known = true
      if not known:
        raise newException(ValueError, "unknown cleanup kind: " & value)
    requireNoOptions(args)
    let plan = planCleanup(store, kinds)
    if not confirmed:
      for entry in plan.entries:
        if jsonOutput:
          echo $(%*{"operation": "cleanup", "kind": $entry.kind,
            "path": entry.relPath, "size": entry.size,
            "removable": entry.removable, "reason": entry.reason})
        else:
          # KEEP, not REMOVE: the file was found and is being reported, which
          # is not the same as being proposed.
          echo (if not entry.removable: "KEEP\t"
            elif permanently: "DELETE\t" else: "REMOVE\t"),
            entry.kind, "\t", entry.relPath, "\t", entry.reason
    else:
      let report = applyCleanup(store, plan,
        progressWriter(showProgress or progressJson, progressJson),
        permanently)
      if jsonOutput:
        echo $(%*{"batch": report.batchId, "removed": report.applied,
          "kept": report.skipped, "failed": report.failed})
      else:
        if report.batchId.len > 0:
          echo "Batch ", report.batchId, ": removed ", report.applied,
            ", kept ", report.skipped, ", failed ", report.failed
          echo "undo restores them"
        else:
          echo "Deleted ", report.applied, ", kept ", report.skipped,
            ", failed ", report.failed
          echo "deleted outright; there is no way back"
      if report.failed > 0: return 3
  of "integrity":
    if args.len == 0 or args[0] != "audit":
      raise newException(ValueError, "integrity requires the audit action")
    args.delete(0)
    let noHash = takeFlag(args, "--no-hash")
    let showProgress = takeFlag(args, "--progress")
    requireNoOptions(args)
    if args.len != 0:
      raise newException(ValueError, "integrity audit takes no arguments")
    let report = auditIntegrity(store, not noHash,
      progressWriter(showProgress or progressJson, progressJson),
      cancelRequested)
    if jsonOutput:
      var findings = newJArray()
      for finding in report.findings:
        findings.add %*{"item": finding.itemId, "path": finding.relPath,
          "kind": finding.kind, "detail": finding.detail}
      echo $(%*{"checked": report.checked, "missing": report.missing,
        "changed": report.changed, "hashMismatches": report.hashMismatches,
        "databaseErrors": report.databaseErrors, "findings": findings})
    else:
      echo "Checked ", report.checked, ", missing ", report.missing,
        ", changed ", report.changed, ", hash mismatches ",
        report.hashMismatches, ", database errors ", report.databaseErrors
      for finding in report.findings:
        echo finding.kind, "\t", finding.relPath, "\t", finding.detail
    if report.missing + report.changed + report.hashMismatches +
        report.databaseErrors > 0: return 3
  of "dates":
    if args.len < 3 or args[0] notin ["set", "shift"]:
      raise newException(ValueError,
        "dates requires set DATE ITEM... or shift SECONDS ITEM...")
    let action = args[0]
    args.delete(0)
    let value = args[0]
    args.delete(0)
    let confirmed = takeFlag(args, "--yes")
    let showProgress = takeFlag(args, "--progress")
    requireNoOptions(args)
    var itemIds: seq[int64]
    for item in args: itemIds.add parseId(item, "item")
    let plan = if action == "set": planDateSet(store, itemIds, value)
      else:
        let seconds = try: value.parseBiggestInt()
          except ValueError:
            raise newException(ValueError, "invalid shift seconds: " & value)
        planDateShift(store, itemIds, seconds)
    if not confirmed:
      for entry in plan.entries:
        if jsonOutput:
          echo $(%*{"operation": "date", "item": entry.itemId,
            "path": entry.relPath, "oldDate": entry.oldDate,
            "newDate": entry.newDate, "writesFile": entry.writesFile})
        else:
          # CATALOG, not DATE, where the file itself keeps the old date: every
          # other program will go on reading it.
          echo (if entry.writesFile: "DATE\t" else: "CATALOG\t"),
            entry.itemId, "\t", entry.oldDate, " -> ",
            entry.newDate, "\t", entry.relPath
    else:
      let report = applyDateEdit(store, plan,
        progressWriter(showProgress or progressJson, progressJson),
        cancelRequested)
      if jsonOutput:
        echo $(%*{"applied": report.applied, "written": report.written,
          "batch": report.batchId, "failed": report.failed})
      else:
        echo "Updated ", report.applied, ", files rewritten ", report.written,
          ", failed ", report.failed
        if report.batchId.len > 0:
          echo "Batch ", report.batchId, " — undo restores the originals"
      if report.failed > 0: return 3
  of "gpx":
    if args.len < 2 or args[0] != "match":
      raise newException(ValueError, "gpx requires match FILE [ITEM ...]")
    args.delete(0)
    let source = args[0]
    args.delete(0)
    let confirmed = takeFlag(args, "--yes")
    let showProgress = takeFlag(args, "--progress")
    # Items that already carry a position are kept unless this is given.
    let refresh = takeFlag(args, "--refresh")
    let toleranceText = takeValue(args, "--tolerance", "300")
    let offsetText = takeValue(args, "--camera-offset", "0")
    let tolerance = try: toleranceText.parseInt()
      except ValueError:
        raise newException(ValueError, "invalid GPX tolerance: " & toleranceText)
    let cameraOffset = try: offsetText.parseInt()
      except ValueError:
        raise newException(ValueError,
          "invalid camera UTC offset: " & offsetText)
    requireNoOptions(args)
    var itemIds: seq[int64]
    for item in args: itemIds.add parseId(item, "item")
    let plan = planGpxMatch(store, source, itemIds, tolerance, cameraOffset,
      refresh)
    if not confirmed:
      for entry in plan.entries:
        if jsonOutput:
          var node = %*{"operation": "gpx", "item": entry.itemId,
            "path": entry.relPath, "date": entry.creationDate,
            "matched": entry.matched, "alreadyPlaced": entry.alreadyPlaced,
            "distanceSeconds": entry.distanceSeconds}
          node["latitude"] = if entry.matched: %entry.latitude else: newJNull()
          node["longitude"] = if entry.matched: %entry.longitude else: newJNull()
          echo $node
        else:
          # KEPT, not NO_MATCH: the track was never consulted for this one.
          let verdict =
            if entry.matched: "MATCH"
            elif entry.alreadyPlaced: "KEPT"
            else: "NO_MATCH"
          # No distance for a kept item: the track was never consulted, and
          # printing the sentinel would read as a match an hour away.
          let distance = if entry.matched or not entry.alreadyPlaced:
              $entry.distanceSeconds & "s" else: "-"
          echo verdict, "\t", entry.itemId, "\t", distance, "\t", entry.relPath
    else:
      let report = applyGpxMatch(store, plan,
        progressWriter(showProgress or progressJson, progressJson),
        cancelRequested)
      if jsonOutput:
        echo $(%*{"applied": report.applied, "failed": report.failed})
      else:
        echo "Geotagged ", report.applied, ", failed ", report.failed
      if report.failed > 0: return 3
  of "curate":
    if args.len < 2 or args[0] notin ["album", "item", "smart", "batch"]:
      raise newException(ValueError,
        "curate requires an album, item, smart, or batch action")
    let target = args[0]
    args.delete(0)
    let action = args[0]
    args.delete(0)
    if target == "smart":
      case action
      of "create":
        let all = takeFlag(args, "--all")
        let any = takeFlag(args, "--any")
        if all and any:
          raise newException(ValueError, "--all and --any are mutually exclusive")
        let ruleTexts = takeValues(args, "--rule")
        requireNoOptions(args)
        if args.len != 1:
          raise newException(ValueError, "curate smart create requires one name")
        var rules: seq[SmartRule]
        for value in ruleTexts:
          let parts = value.split(':', maxsplit = 2)
          if parts.len != 3:
            raise newException(ValueError,
              "smart rule must use FIELD:OPERATOR:VALUE")
          rules.add SmartRule(field: parts[0], operator: parts[1], value: parts[2])
        writeSmartAlbum(createSmartAlbum(store, args[0], not any, rules),
          jsonOutput)
      of "list":
        requireNoOptions(args)
        if args.len != 0:
          raise newException(ValueError, "curate smart list takes no arguments")
        for album in listSmartAlbums(store): writeSmartAlbum(album, jsonOutput)
      of "show":
        requireNoOptions(args)
        if args.len != 1:
          raise newException(ValueError, "curate smart show requires one album id")
        let album = getSmartAlbum(store, parseId(args[0], "smart album"))
        if jsonOutput:
          var node = smartAlbumJson(album)
          var items = newJArray()
          for item in listSmartAlbumItems(store, album.id): items.add itemJson(item)
          node["items"] = items
          echo $node
        else:
          writeSmartAlbum(album, false)
          for item in listSmartAlbumItems(store, album.id): writeItem(item, false)
      of "rename":
        requireNoOptions(args)
        if args.len != 2:
          raise newException(ValueError,
            "curate smart rename requires an album id and one name")
        writeSmartAlbum(renameSmartAlbum(store,
          parseId(args[0], "smart album"), args[1]), jsonOutput)
      of "delete":
        let confirmed = takeFlag(args, "--yes")
        requireNoOptions(args)
        if args.len != 1:
          raise newException(ValueError, "curate smart delete requires one album id")
        if not confirmed:
          raise newException(ValueError, "curate smart delete requires --yes")
        let id = parseId(args[0], "smart album")
        deleteSmartAlbum(store, id)
        if jsonOutput: echo $(%*{"deleted": id})
        else: echo "Deleted smart album ", id
      else:
        raise newException(ValueError, "unknown curate smart action: " & action)
      return 0
    if target == "item":
      case action
      of "show":
        requireNoOptions(args)
        if args.len != 1:
          raise newException(ValueError, "curate item show requires one item id")
        writeCuration(getItemCuration(store, parseId(args[0], "item")), jsonOutput)
      of "set":
        let patch = takeCurationPatch(args)
        requireNoOptions(args)
        if args.len != 1:
          raise newException(ValueError, "curate item set requires one item id")
        writeCuration(curateItem(store, parseId(args[0], "item"), patch),
          jsonOutput)
      else:
        raise newException(ValueError, "unknown curate item action: " & action)
      return 0
    if target == "batch":
      if action != "set":
        raise newException(ValueError, "curate batch requires the set action")
      let confirmed = takeFlag(args, "--yes")
      let showProgress = takeFlag(args, "--progress")
      let patch = takeCurationPatch(args)
      requireNoOptions(args)
      var itemIds: seq[int64]
      for value in args: itemIds.add parseId(value, "item")
      let plan = planCurationBatch(store, itemIds, patch)
      if not confirmed:
        for entry in plan.entries:
          if jsonOutput:
            echo $(%*{"operation": "curate", "item": entry.itemId,
              "path": entry.relPath})
          else:
            echo "CURATE\t", entry.itemId, "\t", entry.relPath
      else:
        let report = applyCurationBatch(store, plan,
          progressWriter(showProgress or progressJson, progressJson),
          cancelRequested)
        if jsonOutput:
          var failures = newJArray()
          for failure in report.failures:
            failures.add %*{"item": failure.itemId, "path": failure.relPath,
              "error": failure.error}
          echo $(%*{"applied": report.applied, "failed": report.failed,
            "failures": failures})
        else:
          echo "Curated ", report.applied, ", failed ", report.failed
        if report.failed > 0: return 3
      return 0
    let confirmed = takeFlag(args, "--yes")
    if confirmed and action != "delete":
      raise newException(ValueError, "--yes is only valid for album delete")
    requireNoOptions(args)
    case action
    of "create":
      if args.len != 1:
        raise newException(ValueError, "curate album create requires one name")
      let album = createAlbum(store, args[0])
      if jsonOutput: echo $albumJson(album)
      else: echo album.id, "\t", album.name
    of "list":
      if args.len != 0:
        raise newException(ValueError, "curate album list takes no arguments")
      for album in listAlbums(store):
        if jsonOutput: echo $albumJson(album)
        else: echo album.id, "\t", album.itemCount, "\t", album.name
    of "show":
      if args.len != 1:
        raise newException(ValueError, "curate album show requires one album id")
      let albumId = parseId(args[0], "album")
      let album = getAlbum(store, albumId)
      let items = listAlbumItems(store, albumId)
      if jsonOutput:
        var itemNodes = newJArray()
        for item in items: itemNodes.add itemJson(item)
        var node = albumJson(album)
        node["items"] = itemNodes
        echo $node
      else:
        echo "Album ", album.id, " — ", album.name, " (", album.itemCount, ")"
        for item in items: writeItem(item, false)
    of "add", "remove":
      if args.len < 2:
        raise newException(ValueError, "curate album " & action &
          " requires an album id and at least one item id")
      let albumId = parseId(args[0], "album")
      discard getAlbum(store, albumId)
      var itemIds: seq[int64]
      for value in args[1..^1]:
        let itemId = parseId(value, "item")
        discard getItem(store, itemId)
        itemIds.add itemId
      var changed = 0
      for itemId in itemIds:
        let didChange = if action == "add": addAlbumItem(store, albumId, itemId)
                        else: removeAlbumItem(store, albumId, itemId)
        if didChange: inc changed
      if jsonOutput:
        echo $(%*{"album": albumId, "action": action, "changed": changed,
          "unchanged": itemIds.len - changed})
      else:
        let past = if action == "add": "added" else: "removed"
        echo "Album ", albumId, ": ", changed, " item(s) ", past, ", ",
          itemIds.len - changed, " unchanged"
    of "rename":
      if args.len != 2:
        raise newException(ValueError,
          "curate album rename requires an album id and one name")
      let album = renameAlbum(store, parseId(args[0], "album"), args[1])
      if jsonOutput: echo $albumJson(album)
      else: echo album.id, "\t", album.name
    of "cover":
      if args.len != 2:
        raise newException(ValueError,
          "curate album cover requires an album id and an item id or none")
      let albumId = parseId(args[0], "album")
      let album = if args[1] == "none": clearAlbumCover(store, albumId)
                  else: setAlbumCover(store, albumId,
                      parseId(args[1], "item"))
      if jsonOutput: echo $albumJson(album)
      else: echo "Album ", album.id, ": cover ",
          (if album.coverItemId > 0: $album.coverItemId else: "none")
    of "parent":
      if args.len != 2:
        raise newException(ValueError,
          "curate album parent requires an album id and a parent id or none")
      let albumId = parseId(args[0], "album")
      let parentId = if args[1] == "none": 0'i64
                     else: parseId(args[1], "parent")
      let album = setAlbumParent(store, albumId, parentId)
      if jsonOutput: echo $albumJson(album)
      else: echo "Album ", album.id, ": inside ",
          (if album.parentId > 0: $album.parentId else: "nothing")
    of "children":
      if args.len != 1:
        raise newException(ValueError,
          "curate album children requires a parent album id or none")
      let parentId = if args[0] == "none": 0'i64
                     else: parseId(args[0], "album")
      for album in listChildAlbums(store, parentId):
        if jsonOutput: echo $albumJson(album)
        else: echo album.id, "\t", album.name
    of "delete":
      if args.len != 1:
        raise newException(ValueError, "curate album delete requires one album id")
      if not confirmed:
        raise newException(ValueError, "curate album delete requires --yes")
      let albumId = parseId(args[0], "album")
      deleteAlbum(store, albumId)
      if jsonOutput: echo $(%*{"deleted": albumId})
      else: echo "Deleted album ", albumId
    else:
      raise newException(ValueError, "unknown curate album action: " & action)
  of "faces":
    let action = args[0]
    args.delete(0)
    case action
    of "detect":
      let backend = takeValue(args, "--backend", findExe("unimedia-apple-vision"))
      requireNoOptions(args)
      if args.len != 1:
        raise newException(ValueError, "faces detect requires one item id")
      for face in detectFaces(store, parseId(args[0], "item"), backend):
        echo $(%*{"id": face.id, "item": face.itemId, "x": face.x,
          "y": face.y, "width": face.width, "height": face.height,
          "confidence": face.confidence, "detector": face.detector})
    of "list":
      let itemText = takeValue(args, "--item", "0")
      requireNoOptions(args)
      if args.len != 0: raise newException(ValueError, "faces list takes no arguments")
      let itemId = try: itemText.parseBiggestInt()
        except ValueError: raise newException(ValueError, "invalid item id")
      for face in listFaces(store, itemId):
        echo $(%*{"id": face.id, "item": face.itemId, "person": face.personId,
          "x": face.x, "y": face.y, "width": face.width,
          "height": face.height, "confidence": face.confidence,
          "detector": face.detector})
    of "import":
      requireNoOptions(args)
      if args.len != 2: raise newException(ValueError, "faces import requires item and JSON file")
      let root = parseFile(args[1])
      if root.kind != JArray: raise newException(ValueError, "face JSON must be an array")
      var detections: seq[FaceDetection]
      for node in root:
        detections.add FaceDetection(x: node["x"].getFloat(), y: node[
            "y"].getFloat(),
          width: node["width"].getFloat(), height: node["height"].getFloat(),
          confidence: node["confidence"].getFloat(), detector: node[
              "detector"].getStr())
      let itemId = parseId(args[0], "item")
      replaceFaces(store, itemId, detections)
      echo $(%*{"item": itemId, "faces": detections.len})
    of "person-create":
      requireNoOptions(args)
      if args.len != 1: raise newException(ValueError, "person-create requires a name")
      let id = createPerson(store, args[0])
      echo $(%*{"id": id, "name": args[0].strip})
    of "name":
      requireNoOptions(args)
      if args.len != 2:
        raise newException(ValueError, "faces name requires a face id and name")
      let person = assignFaceName(store, parseId(args[0], "face"), args[1])
      echo $(%*{"face": args[0], "person": person.id, "name": person.name})
    of "clusters":
      let distanceText = takeValue(args, "--distance", "10")
      let distance = try: distanceText.parseInt()
        except ValueError: raise newException(ValueError, "invalid face distance")
      requireNoOptions(args)
      if args.len != 0:
        raise newException(ValueError, "faces clusters takes no arguments")
      for cluster in clusterFaces(store, distance):
        echo $(%*{"faces": cluster.faceIds,
          "representativeSignature": $cluster.representativeSignature})
    of "clear":
      let confirmed = takeFlag(args, "--yes")
      requireNoOptions(args)
      if args.len != 1:
        raise newException(ValueError, "faces clear requires one item id")
      let itemId = parseId(args[0], "item")
      clearFaces(store, itemId, includeAssigned = confirmed)
      echo $(%*{"item": itemId, "cleared": true})
    of "assign":
      requireNoOptions(args)
      if args.len != 2: raise newException(ValueError, "faces assign requires face and person ids")
      assignFace(store, parseId(args[0], "face"), parseId(args[1], "person"))
      echo $(%*{"face": args[0], "person": args[1]})
    else: raise newException(ValueError, "unknown faces action: " & action)
  of "vision":
    let action = args[0]
    args.delete(0)
    let caption = takeValue(args, "--caption")
    let labels = takeValues(args, "--label")
    let limitText = takeValue(args, "--limit", "50")
    let endpoint = takeValue(args, "--endpoint")
    let optionModel = takeValue(args, "--model")
    requireNoOptions(args)
    case action
    of "add":
      if args.len != 3:
        raise newException(ValueError, "vision add requires item/model/vector")
      let vectorNode = parseFile(args[2])
      if vectorNode.kind != JArray:
        raise newException(ValueError, "embedding JSON must be an array")
      var vector: seq[float]
      for node in vectorNode: vector.add node.getFloat()
      storeVisionDocument(store, parseId(args[0], "item"), args[1], caption,
        labels, vector)
      echo $(%*{"item": args[0], "model": args[1], "dimensions": vector.len})
    of "search":
      if args.len != 2:
        raise newException(ValueError, "vision search requires model/vector")
      let vectorNode = parseFile(args[1])
      if vectorNode.kind != JArray:
        raise newException(ValueError, "embedding JSON must be an array")
      var vector: seq[float]
      for node in vectorNode: vector.add node.getFloat()
      let limit = try: limitText.parseInt()
        except ValueError: raise newException(ValueError, "invalid vision limit")
      for hit in semanticSearch(store, args[0], vector, limit):
        echo $(%*{"item": hit.itemId, "path": hit.relPath,
          "caption": hit.caption, "labels": hit.labels, "score": hit.score})
    of "index":
      if args.len != 2 or endpoint.len == 0 or optionModel.len == 0:
        raise newException(ValueError,
          "vision index requires item/text/--endpoint/--model")
      let itemId = parseId(args[0], "item")
      indexVisionText(store, itemId, endpoint, optionModel, args[1],
        if caption.len > 0: caption else: args[1], labels)
      echo $(%*{"item": itemId, "model": optionModel, "indexed": true})
    of "semantic":
      if args.len != 1 or endpoint.len == 0 or optionModel.len == 0:
        raise newException(ValueError,
          "vision semantic requires query/--endpoint/--model")
      let limit = try: limitText.parseInt()
        except ValueError: raise newException(ValueError, "invalid vision limit")
      for hit in semanticTextSearch(store, endpoint, optionModel, args[0], limit):
        echo $(%*{"item": hit.itemId, "path": hit.relPath,
          "caption": hit.caption, "labels": hit.labels, "score": hit.score})
    of "label":
      if args.len != 1 or endpoint.len == 0 or optionModel.len == 0:
        raise newException(ValueError,
          "vision label requires item/--endpoint/--model")
      let annotation = describeVisionItem(store, parseId(args[0], "item"),
        endpoint, optionModel)
      echo $(%*{"item": annotation.itemId, "model": annotation.model,
        "caption": annotation.caption, "labels": annotation.labels})
    of "annotations":
      if args.len > 1:
        raise newException(ValueError, "vision annotations accepts at most one item")
      let itemId = if args.len == 1: parseId(args[0], "item") else: 0'i64
      for annotation in listVisionAnnotations(store, itemId):
        echo $(%*{"item": annotation.itemId, "model": annotation.model,
          "caption": annotation.caption, "labels": annotation.labels,
          "updatedAt": annotation.updatedAt})
    else: raise newException(ValueError, "unknown vision action: " & action)
  of "sync":
    let action = args[0]
    args.delete(0)
    let confirmed = takeFlag(args, "--yes")
    let limitText = takeValue(args, "--limit", "100")
    requireNoOptions(args)
    case action
    of "manifest":
      if args.len != 0: raise newException(ValueError, "sync manifest accepts no argument")
      echo $syncManifestJson(buildSyncManifest(store))
    of "diff":
      if args.len != 1: raise newException(ValueError, "sync diff requires one manifest file")
      let info = getFileInfo(args[0], followSymlink = false)
      if info.kind == pcLinkToFile or info.kind == pcLinkToDir:
        raise newException(ValueError, "sync manifest must not be a symbolic link")
      if info.kind != pcFile or info.size > MaxSyncManifestBytes:
        raise newException(ValueError, "invalid sync manifest file")
      let difference = diffSyncManifests(buildSyncManifest(store),
        parseSyncManifest(readFile(args[0])))
      echo $(%*{"onlyLocal": difference.onlyLocal,
        "onlyRemote": difference.onlyRemote, "changed": difference.changed})
    of "plan":
      if args.len != 2: raise newException(ValueError, "sync plan requires push|pull and remote")
      let direction = if args[0] == "push": sdPush elif args[0] == "pull": sdPull
        else: raise newException(ValueError, "sync direction must be push or pull")
      let plan = planSync(store, args[1], direction)
      echo $(%*{"plan": plan.id, "provider": plan.provider,
        "remote": plan.remote,
        "direction": $plan.direction, "summary": plan.summary})
    of "apply":
      if args.len != 1: raise newException(ValueError, "sync apply requires one plan id")
      if not confirmed: raise newException(ValueError, "sync apply requires --yes")
      let report = applySync(store, args[0])
      echo $(%*{"plan": report.id, "applied": report.applied,
        "summary": report.summary})
    of "status":
      if args.len > 1:
        raise newException(ValueError, "sync status accepts at most one plan id")
      let limit = try: limitText.parseInt()
        except ValueError: raise newException(ValueError, "invalid sync status limit")
      for run in listSyncRuns(store, if args.len == 1: args[0] else: "", limit):
        echo $(%*{"plan": run.id, "provider": run.provider,
          "remote": run.remote, "direction": $run.direction,
          "dryRun": run.dryRun, "status": run.status,
          "startedAt": run.startedAt, "finishedAt": run.finishedAt,
          "summary": run.summary})
    else: raise newException(ValueError, "unknown sync action: " & action)
  of "undo":
    if args.len < 2: raise newException(ValueError, "undo requires plan|apply and a batch")
    let action = args[0]
    # The engine takes an empty id for "the most recent batch"; --last is this
    # shell's spelling of it.
    let batch = if args[1] == "--last": "" else: args[1]
    args.delete(0)
    args.delete(0)
    let confirmed = takeFlag(args, "--yes")
    let showProgress = takeFlag(args, "--progress")
    requireNoOptions(args)
    if args.len != 0: raise newException(ValueError, "unexpected undo arguments")
    case action
    of "plan":
      if showProgress:
        raise newException(ValueError, "--progress is only valid for undo apply")
      for operation in planUndo(store, batch):
        if jsonOutput: echo $planJson(operation)
        else: echo "UNDO ", operation.kind, "\t", operation.destRelPath, " -> ",
            operation.sourcePath
    of "apply":
      if not confirmed: raise newException(ValueError, "undo apply requires --yes")
      let report = applyUndo(store, batch,
        progressWriter(showProgress or progressJson, progressJson))
      if jsonOutput: echo $(%*{"batch": report.batchId, "undone": report.undone,
        "skipped": report.skipped, "failed": report.failed})
      else: echo "Batch ", report.batchId, ": undone ", report.undone,
        ", skipped ", report.skipped, ", failed ", report.failed
      if report.failed > 0: return 3
    else: raise newException(ValueError, "unknown undo action: " & action)
  of "dedup":
    let action = args[0]
    args.delete(0)
    case action
    of "find":
      let kindText = takeValue(args, "--kind", "all")
      let kind = case kindText
        of "exact": dkExact
        of "visual": dkVisual
        of "audio": dkAudio
        of "all": dkAll
        else: raise newException(ValueError, "invalid dedup kind: " & kindText)
      let thresholdText = takeValue(args, "--threshold", "95")
      let threshold = try: thresholdText.parseFloat()
                      except ValueError: raise newException(ValueError,
                          "invalid threshold: " & thresholdText)
      let showProgress = takeFlag(args, "--progress")
      requireNoOptions(args)
      if args.len != 0: raise newException(ValueError, "dedup find takes no positional arguments")
      let runId = findDuplicates(store, kind, threshold,
        progressWriter(showProgress or progressJson, progressJson),
        cancelRequested)
      if jsonOutput: echo $(%*{"run": runId}) else: echo "Dedup run ", runId
    of "review":
      let runText = takeValue(args, "--run", "0")
      let runId = try: runText.parseBiggestInt()
                  except ValueError: raise newException(ValueError,
                      "invalid run id: " & runText)
      requireNoOptions(args)
      if args.len != 0: raise newException(ValueError, "dedup review takes no positional arguments")
      let run = loadDedupRun(store, runId)
      for group in run.groups:
        if not jsonOutput: echo "Group ", group.id, " (", group.kind, ")"
        for member in group.members:
          if jsonOutput: echo $(%*{"run": run.id, "group": group.id,
            "kind": group.kind, "item": member.itemId, "path": member.relPath,
            "similarity": member.similarity, "keeper": member.isKeeper})
          else: echo "  ", (if member.isKeeper: "KEEP " else: "     "),
            formatFloat(member.similarity * 100.0, ffDecimal, 1), "%\t", member.relPath
    of "keep":
      requireNoOptions(args)
      if args.len != 2:
        raise newException(ValueError, "dedup keep requires group and item ids")
      let groupId = parseId(args[0], "group")
      let itemId = parseId(args[1], "item")
      setDedupKeeper(store, groupId, itemId)
      if jsonOutput:
        echo $(%*{"group": groupId, "keeper": itemId})
      else:
        echo "Group ", groupId, ": keeper ", itemId
    of "remove":
      let runText = takeValue(args, "--run", "0")
      let runId = try: runText.parseBiggestInt()
                  except ValueError: raise newException(ValueError,
                      "invalid run id: " & runText)
      let confirmed = takeFlag(args, "--yes")
      # Replace each duplicate with a hard link to the copy kept, instead of
      # sending it to the trash: the space is freed and every path still opens.
      let link = takeFlag(args, "--link")
      requireNoOptions(args)
      if args.len != 0:
        raise newException(ValueError, "dedup remove takes no positional arguments")
      if link:
        let pairs = planDedupLinks(store, runId)
        if not confirmed:
          for pair in pairs:
            let item = store.getItem(pair.itemId)
            let keeper = store.getItem(pair.keeperId)
            if jsonOutput:
              echo $(%*{"operation": "hardlink", "item": pair.itemId,
                "path": item.relPath, "keeper": keeper.relPath})
            else:
              echo "LINK\t", item.relPath, "\t-> ", keeper.relPath
        else:
          let report = applyDedupLinks(store, runId)
          if jsonOutput:
            echo $(%*{"batch": report.batchId, "linked": report.linked,
              "failed": report.failed})
          else:
            echo "Batch ", report.batchId, ": linked ", report.linked,
              ", failed ", report.failed
          if report.failed > 0: return 3
      else:
        let plan = planDedupRemoval(store, runId)
        if not confirmed:
          for member in plan:
            if jsonOutput:
              echo $(%*{"operation": "delete", "item": member.itemId,
                "path": member.relPath})
            else:
              echo "DELETE\t", member.relPath
        else:
          let report = applyDedupRemoval(store, runId)
          if jsonOutput:
            echo $(%*{"batch": report.batchId, "removed": report.applied,
              "failed": report.failed})
          else:
            echo "Batch ", report.batchId, ": removed ", report.applied,
              ", failed ", report.failed
          if report.failed > 0: return 3
    else: raise newException(ValueError, "unknown dedup action: " & action)
  else:
    raise newException(ValueError, "unknown command: " & command)
  0
