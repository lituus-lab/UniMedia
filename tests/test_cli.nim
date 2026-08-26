# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[json, options, unittest, os, strutils]
import UniMedia/cli
import UniMedia/help
import UniMedia/[types, store, curation]
import UniMedia/[reverse_geocode, nominatim_client]
import UniMedia/sync
import UniImage/[core, formats]
import UniImage/exif/edit

test "the help distinguishes the two similar date layouts":
  # One files a month's pictures in a folder per day, the other in a folder
  # per month with the day in the name. A reader choosing between them has to
  # be able to tell which is which.
  let text = groupHelp("catalog")
  check "YYYY/MM-DD (month/date)" in text
  check "YYYY/MM/DD (month/day)" in text

test "every group answers for itself":
  # A group in the table with no help would be a command a reader cannot ask
  # about, which is the gap this table exists to close.
  for group in Groups:
    let text = groupHelp(group.name)
    check text.len > 0
    check group.summary in text
    for action in group.actions:
      check action.synopsis in text
      check action.summary.split(" ")[0] in text

test "the overview names every group exactly once":
  let text = overview("1.0.0")
  for group in Groups:
    check ("\n  " & group.name) in text

test "a bare group answers before it demands a library":
  # A reader typing `om dedup` is asking what dedup is. Refusing for a
  # missing --library answers a question they did not ask.
  # It answers -- exit 2, no raise -- where a missing --library would have
  # refused. What it prints is the group help the tests above already cover.
  check runCli(@["dedup"]) == 2
  check runCli(@["catalog"]) == 2

test "a mistyped command is named as the mistake, not the library":
  # `om find` refused for a missing --library, which sends the reader looking
  # for the wrong mistake: the word is wrong whatever library it names.
  check runCli(@["nawak"]) == 2
  check runCli(@["find"]) == 2

test "an action typed without its group is recognised as one":
  # The commonest way to get the word wrong is to drop the group, so the
  # groups that have that action are worth naming back.
  check spellings("find") == @["dedup find"]
  check spellings("show") == @["catalog show", "config show"]
  check spellings("nawak").len == 0

test "a group that acts as named still refuses without a library":
  # `om cleanup` is an operation with everything it needs but the library,
  # so it is the one case the rule above must not swallow.
  expect ValueError:
    discard runCli(@["cleanup"])

test "an unknown topic has no help rather than an empty one":
  check findGroup("no-such-command") < 0
  check groupHelp("no-such-command") == ""

proc fresh(name: string): string =
  result = getTempDir() / name
  if dirExists(result): removeDir(result)

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

proc privateJpeg(path: string) =
  var image = newImage[uint8](8, 8, csGray)
  image.data = newSeq[uint8](64)
  writeFile(path, cast[string](encodeJpeg(image)))
  var exif = parseExif(path)
  exif.setGps(48.8566, 2.3522)
  exif.setSoftware("UniMedia CLI test")
  doAssert writeExif(path, exif)

suite "om command dispatcher":
  test "catalog init and scan":
    let root = fresh("unimedia_cli")
    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    check runCli(@["--library", root, "catalog", "scan", "--no-phash",
      "--progress"]) == 0
    removeDir(root)

  test "an interrupt stops the scan and does not leak into the next run":
    let root = fresh("unimedia_cli_cancel")
    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    writeFile(root / "photo.ppm", ppm(80))
    requestCancel()
    expect OperationCancelledError:
      discard runCli(@["--library", root, "catalog", "scan"])
    check runCli(@["--library", root, "catalog", "scan",
      "--progress-json"]) == 0
    removeDir(root)

  test "catalog thumbnail exposes the shared cache":
    let root = fresh("unimedia_cli_thumbnail")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "photo.ppm", ppm(64))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    check runCli(@["--library", root, "catalog", "thumbnail", "1",
      "--size", "16", "--json"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "catalog", "thumbnail", "1",
        "--size", "0"])
    removeDir(root)

  test "missing library is a usage error at the binary boundary":
    expect ValueError:
      discard runCli(@["catalog", "scan"])

  test "move needs confirmation":
    let root = fresh("unimedia_cli_move")
    let source = fresh("unimedia_cli_move_source")
    createDir(source)
    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "organize", "apply", source, "--move"])
    removeDir(root)
    removeDir(source)

  test "contradictory organize flags are rejected":
    let root = fresh("unimedia_cli_conflicts")
    let source = fresh("unimedia_cli_conflicts_source")
    createDir(source)
    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "organize", "plan", source,
        "--copy", "--move"])
    expect ValueError:
      discard runCli(@["--library", root, "organize", "plan", source,
        "--hardlink", "--move"])
    expect ValueError:
      discard runCli(@["--library", root, "organize", "plan", source,
        "--filename-date", "--no-filename-date"])
    expect ValueError:
      discard runCli(@["--library", root, "dedup", "find", "--threshold",
        "nan"])
    removeDir(root)
    removeDir(source)

  test "hardlink organize shares the inode and undoes without touching the source":
    let root = fresh("unimedia_cli_hardlink")
    let source = fresh("unimedia_cli_hardlink_source")
    createDir(source)
    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    writeFile(source / "x.ppm", ppm(48))
    # No --yes: a hardlink leaves the source in place, so it is not destructive.
    check runCli(@["--library", root, "organize", "apply", source,
      "--hardlink"]) == 0
    var linked = ""
    for path in walkDirRec(root):
      if path.endsWith("x.ppm"): linked = path
    check linked.len > 0
    check getFileInfo(linked).id == getFileInfo(source / "x.ppm").id
    check getFileInfo(linked).linkCount >= 2
    check runCli(@["--library", root, "undo", "apply", "--last", "--yes"]) == 0
    check not fileExists(linked)
    check fileExists(source / "x.ppm")
    removeDir(root)
    removeDir(source)

  test "dedup removal requires confirmation and is undoable":
    let root = fresh("unimedia_cli_dedup_remove")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "a.ppm", ppm(64))
    writeFile(root / "b.ppm", ppm(64))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    discard runCli(@["--library", root, "dedup", "find", "--kind", "exact"])
    check runCli(@["--library", root, "dedup", "keep", "1", "2", "--json"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "dedup", "keep", "1", "999"])
    check runCli(@["--library", root, "dedup", "remove"]) == 0
    check fileExists(root / "b.ppm")
    check runCli(@["--library", root, "dedup", "remove", "--yes"]) == 0
    check not fileExists(root / "a.ppm")
    check fileExists(root / "b.ppm")
    check runCli(@["--library", root, "undo", "apply", "--last", "--yes"]) == 0
    check fileExists(root / "a.ppm")
    removeDir(root)

  test "organize, dedup review, and last-batch undo are exposed":
    let sandbox = fresh("unimedia_cli_workflow")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "IMG_20260731.ppm", ppm(255))
    writeFile(source / "COPY_20260731.ppm", ppm(255))

    check runCli(@["catalog", "init", root, "--domain", "photo"]) == 0
    check runCli(@["--library", root, "organize", "plan", source]) == 0
    check runCli(@["--library", root, "organize", "apply", source,
      "--move", "--yes", "--progress"]) == 0
    check not fileExists(source / "IMG_20260731.ppm")
    check not fileExists(source / "COPY_20260731.ppm")
    check runCli(@["--library", root, "dedup", "find", "--kind", "exact"]) == 0
    check runCli(@["--library", root, "catalog", "search", "COPY",
      "--limit", "1", "--offset", "1"]) == 0
    check runCli(@["--library", root, "catalog", "list", "--limit", "1",
      "--offset", "1"]) == 0
    check runCli(@["--library", root, "catalog", "show", "1"]) == 0
    check runCli(@["--library", root, "timeline", "report", "--by",
      "day"]) == 0
    check runCli(@["--library", root, "privacy", "audit"]) == 0
    check runCli(@["--library", root, "curate", "item", "set", "1",
      "--title", "First", "--description", "CLI curation", "--rating", "4",
      "--favorite", "--keywords", "summer,family",
      "--date", "2025-06-07T08:09:10", "--latitude", "48.8566",
      "--longitude", "2.3522", "--location", "Paris", "--json"]) == 0
    check runCli(@["--library", root, "curate", "item", "show", "1",
      "--json"]) == 0
    check runCli(@["--library", root, "curate", "item", "set", "1",
      "--add-keyword", "sea", "--remove-keyword", "summer", "--json"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "curate", "item", "set", "1",
        "--latitude", "1"])
    expect ValueError:
      discard runCli(@["--library", root, "curate", "item", "set", "1",
        "--latitude", "1", "--longitude", "2", "--clear-gps"])
    check runCli(@["--library", root, "catalog", "filter", "First",
      "--min-rating", "4", "--favorite", "--keyword", "sea",
      "--keyword", "family",
      "--from", "2026-07-01", "--to", "2026-07-31", "--json"]) == 0
    check runCli(@["--library", root, "catalog", "filter",
      "--location", "paris", "--has-gps", "--offset", "0", "--json"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "catalog", "list", "--offset", "-1"])
    expect ValueError:
      discard runCli(@["--library", root, "catalog", "filter",
        "--has-gps", "--no-gps"])
    check runCli(@["--library", root, "catalog", "keywords", "--prefix",
      "sum", "--limit", "10", "--json"]) == 0
    check runCli(@["--library", root, "geo", "places", "--prefix", "par",
      "--limit", "10", "--json"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "geo", "places", "--limit", "0"])
    expect ValueError:
      discard runCli(@["--library", root, "catalog", "filter"])
    check runCli(@["--library", root, "curate", "smart", "create", "Rated",
      "--all", "--rule", "rating:gte:4", "--rule", "favorite:eq:true",
      "--rule", "location:contains:paris", "--rule", "gps:eq:true",
      "--json"]) == 0
    check runCli(@["--library", root, "curate", "smart", "list"]) == 0
    check runCli(@["--library", root, "curate", "smart", "show", "1",
      "--json"]) == 0
    check runCli(@["--library", root, "curate", "smart", "rename", "1",
      "Favorites"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "curate", "smart", "delete", "1"])
    check runCli(@["--library", root, "curate", "smart", "delete", "1",
      "--yes"]) == 0
    check runCli(@["--library", root, "curate", "item", "set", "1",
      "--title=", "--keywords=", "--no-favorite"]) == 0
    check fileExists(root / "2026" / "07-31" / "COPY_20260731.ppm.xmp")
    expect ValueError:
      discard runCli(@["--library", root, "curate", "item", "set", "1"])
    check runCli(@["--library", root, "curate", "album", "create",
      "Summer"]) == 0
    check runCli(@["--library", root, "curate", "album", "add", "1", "1",
      "2"]) == 0
    check runCli(@["--library", root, "curate", "album", "list"]) == 0
    check runCli(@["--library", root, "curate", "album", "show", "1",
      "--json"]) == 0
    check runCli(@["--library", root, "curate", "album", "cover", "1",
      "2"]) == 0
    check runCli(@["--library", root, "curate", "album", "rename", "1",
      "Holiday"]) == 0
    check runCli(@["--library", root, "curate", "album", "remove", "1",
      "2"]) == 0
    check runCli(@["--library", root, "curate", "album", "cover", "1",
      "none"]) == 0
    expect ValueError:
      discard runCli(@["--library", root, "curate", "album", "delete", "1"])
    check runCli(@["--library", root, "curate", "album", "delete", "1",
      "--yes"]) == 0
    check runCli(@["--library", root, "dedup", "review"]) == 0
    check runCli(@["--library", root, "undo", "plan", "--last"]) == 0
    check runCli(@["--library", root, "undo", "apply", "--last", "--yes",
      "--progress"]) == 0
    check fileExists(source / "IMG_20260731.ppm")
    check fileExists(source / "COPY_20260731.ppm")

    removeDir(sandbox)

  test "integrity audit reports drift with a non-success result":
    let root = fresh("unimedia_cli_integrity")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "photo.ppm", ppm(80))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    check runCli(@["--library", root, "integrity", "audit", "--no-hash",
      "--progress", "--json"]) == 0
    removeFile(root / "photo.ppm")
    check runCli(@["--library", root, "integrity", "audit", "--json"]) == 3
    removeDir(root)

  test "privacy strip requires confirmation and is undoable":
    let root = fresh("unimedia_cli_privacy_strip")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    privateJpeg(root / "private.jpg")
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    check runCli(@["--library", root, "privacy", "strip", "1", "--json"]) == 0
    check runCli(@["--library", root, "privacy", "strip", "1", "--yes",
      "--progress", "--json"]) == 0
    check runCli(@["--library", root, "undo", "apply", "--last", "--yes"]) == 0
    check runCli(@["--library", root, "privacy", "audit", "--json"]) == 0
    removeDir(root)

  test "curation batch plans by default and applies after confirmation":
    let root = fresh("unimedia_cli_curation_batch")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "one.ppm", ppm(12))
    writeFile(root / "two.ppm", ppm(24))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    check runCli(@["--library", root, "curate", "batch", "set", "1", "2",
      "--rating", "5", "--add-keyword", "Batch", "--json"]) == 0
    check runCli(@["--library", root, "curate", "batch", "set", "1", "2",
      "--rating", "5", "--add-keyword", "Batch", "--yes", "--progress",
      "--json"]) == 0
    var store = openLibrary(root)
    for item in store.listItems():
      let curated = store.getItemCuration(item.id)
      check curated.rating == 5
      check curated.keywords == @["Batch"]
    store.close()
    removeDir(root)

  test "date correction is planned before set and shift application":
    let root = fresh("unimedia_cli_dates")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "one.ppm", ppm(64))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    check runCli(@["--library", root, "dates", "set", "2026-08-01T10:00:00",
      "1", "--json"]) == 0
    check runCli(@["--library", root, "dates", "set", "2026-08-01T10:00:00",
      "1", "--yes"]) == 0
    check runCli(@["--library", root, "dates", "shift", "-3600", "1",
      "--yes", "--progress", "--json"]) == 0
    var store = openLibrary(root)
    check store.getItem(1).creationDate == "2026-08-01 09:00:00"
    store.close()
    removeDir(root)

  test "GPX matching plans all candidates before journaled application":
    let root = fresh("unimedia_cli_gpx")
    let track = getTempDir() / "unimedia_cli_track.gpx"
    if fileExists(track): removeFile(track)
    writeFile(track, """<gpx version="1.1"><trk><trkseg>
<trkpt lat="43.2965" lon="5.3698"><time>2026-08-01T08:00:00Z</time></trkpt>
</trkseg></trk></gpx>""")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "one.ppm", ppm(80))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    discard runCli(@["--library", root, "dates", "set",
      "2026-08-01T10:00:00", "1", "--yes"])
    check runCli(@["--library", root, "gpx", "match", track, "1",
      "--camera-offset", "120", "--tolerance", "1", "--json"]) == 0
    check runCli(@["--library", root, "gpx", "match", track, "1",
      "--camera-offset", "120", "--tolerance", "1", "--yes",
      "--progress", "--json"]) == 0
    var store = openLibrary(root)
    check store.getItem(1).latitude.get() == 43.2965
    check store.getItem(1).longitude.get() == 5.3698
    store.close()
    removeFile(track)
    removeDir(root)

  test "reverse geocoding can plan and apply from cache without network":
    let root = fresh("unimedia_cli_reverse_geocode")
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "one.ppm", ppm(90))
    discard runCli(@["--library", root, "catalog", "scan", "--no-phash"])
    var store = openLibrary(root)
    var gps: CurationPatch
    gps.latitude = some(48.8566)
    gps.longitude = some(2.3522)
    discard store.curateItem(1, gps)
    proc provider(latitude, longitude: float;
                  language: string): ReverseGeocodeResult =
      ReverseGeocodeResult(locationText: "Paris, France",
        attribution: "Test provider licence")
    discard planReverseGeocode(store, "test-cache", "fr", provider, @[1'i64])
    store.close()
    check runCli(@["--library", root, "geo", "reverse", "1", "--provider",
      "test-cache", "--language", "fr", "--json"]) == 0
    check runCli(@["--library", root, "geo", "reverse", "1", "--provider",
      "test-cache", "--language", "fr", "--yes", "--progress",
      "--json"]) == 0
    store = openLibrary(root)
    check store.getItem(1).locationText == "Paris, France"
    store.close()
    expect ValueError:
      discard newNominatimProvider("ftp://example.test", "Studio/1.0")
    expect ValueError:
      discard newNominatimProvider("https://example.test", "short")
    removeDir(root)

  test "sync manifest and diff dispatch through the sync command":
    let root = fresh("unimedia_cli_sync_manifest")
    let snapshot = getTempDir() / "unimedia_cli_sync_manifest.json"
    if fileExists(snapshot): removeFile(snapshot)
    discard runCli(@["catalog", "init", root, "--domain", "photo"])
    writeFile(root / "one.ppm", ppm(12))
    discard runCli(@["--library", root, "catalog", "scan"])
    var store = openLibrary(root)
    writeFile(snapshot, $syncManifestJson(buildSyncManifest(store)))
    store.close()
    check runCli(@["--library", root, "sync", "manifest", "--json"]) == 0
    check runCli(@["--library", root, "sync", "diff", snapshot,
      "--json"]) == 0
    removeFile(snapshot)
    removeDir(root)
