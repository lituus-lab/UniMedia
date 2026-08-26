# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[base64, json, unittest, options, os, osproc, sequtils, strutils,
  tables, sets]
import db_connector/db_sqlite
import UniMedia
import UniMedia/cleanup
import UniMedia/trash
import UniImage/[core, formats]
import UniImage/exif/edit
import UniImage/exif/xmp
from UniMovie/edit import movieCreationDate
# Only `year`: importing times whole would collide with names this suite already
# uses, and the year is the whole assertion — 2036 against 2019.
from std/times import year

var observedProgress {.threadvar.}: seq[ProgressEvent]

proc recordProgress(event: ProgressEvent) {.gcsafe.} =
  observedProgress.add event

proc cancelNow(): bool {.gcsafe.} = true

var workerItemCount: int

proc countInOwnStore(root: string) {.thread.} =
  ## ADR-0003: the thread that opens a Store owns it. A background worker opens
  ## and closes its own, sharing nothing but the library path.
  var own = openLibrary(root)
  workerItemCount = own.countItems()
  own.close()

proc fresh(name: string): string =
  result = getTempDir() / name
  if dirExists(result): removeDir(result)
  createDir(result)

proc ppm(red: int): string =
  "P3\n2 2\n255\n" & repeat($red & " 0 0\n", 4)

proc ppmSize(width, height, red: int): string =
  "P3\n" & $width & " " & $height & "\n255\n" &
    repeat($red & " 0 0\n", width * height)

proc privateJpeg(path: string) =
  var image = newImage[uint8](8, 8, csGray)
  image.data = newSeq[uint8](64)
  let encoded = encodeJpeg(image)
  writeFile(path, cast[string](encoded))
  var exif = parseExif(path)
  exif.setGps(48.8566, 2.3522)
  exif.setSoftware("UniMedia test")
  doAssert writeExif(path, exif)

proc orientedJpeg(path: string; width, height, orientation: int) =
  var image = newImage[uint8](width, height, csGray)
  writeFile(path, cast[string](encodeJpeg(image)))
  var exif = parseExif(path)
  exif.ifd0[0x0112'u16] = shortVal(orientation)
  doAssert writeExif(path, exif)

proc runExternal(executable: string; arguments: openArray[string]): bool =
  var process = startProcess(executable, args = @arguments,
    options = {poParentStreams})
  try:
    result = process.waitForExit(30_000) == 0
  finally:
    process.close()

suite "catalog, organize, dedup, undo":
  test "visual domain accepts images and videos only":
    check categoryFor(mdVisual, "photo.jpg") == "image"
    check categoryFor(mdVisual, "clip.mp4") == "video"
    check categoryFor(mdVisual, "track.mp3") == ""

  test "external media validation is strict without requiring FFmpeg":
    expect ValueError:
      discard probeMedia("")
    expect IOError:
      discard probeMedia(getTempDir() / "unimedia-absent-media")
    writeFile(fresh("unimedia_external_validation") / "plain.bin", "x")
    expect ValueError:
      discard decodeMediaFrame(getTempDir() /
        "unimedia_external_validation" / "plain.bin", MinThumbnailEdge - 1)
    removeDir(getTempDir() / "unimedia_external_validation")

  test "probing needs no external process at all":
    # It used to shell out to ffprobe. A machine with neither tool must still
    # report what a video is, so this deliberately does not check for one.
    let root = fresh("unimedia_inprocess_probe")
    let video = root / "clip.mp4"
    if findExe("ffmpeg").len == 0: skip()
    else:
      check runExternal(findExe("ffmpeg"), ["-y", "-nostdin", "-hide_banner",
        "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=48x32:d=1", "-c:v", "mpeg4", video])
      let media = probeMedia(video)
      check (media.width, media.height) == (48, 32)
      check media.durationSeconds > 0
      # The container's own vocabulary, not ffprobe's: `mp4v`, not `mpeg4`.
      check media.codec.len == 4
      check media.format.len > 0
      check media.rotation in [0, 90, 180, 270]
      # Square pixels here, so the two sizes agree; they part on an anamorphic
      # source, which is why both are reported.
      check (media.displayWidth, media.displayHeight) == (48, 32)
      removeDir(root)

  test "a file that is not a container this build reads says so":
    let root = fresh("unimedia_not_a_movie")
    let bogus = root / "clip.mp4"
    writeFile(bogus, "this is not a container at all, whatever it is called")
    expect ExternalMediaError: discard probeMedia(bogus)
    removeDir(root)

  test "a still in an ISO base media container is not probed as a movie":
    # A HEIC or AVIF has no `moov`, so the movie reader cannot size it. The
    # fallback that decodes one asks UniImage's HEIF reader instead — routing
    # it through the movie probe made this fail only in a build without the
    # system decoders, where the fallback is actually reached.
    if findExe("ffmpeg").len == 0: skip()
    else:
      let root = fresh("unimedia_still_not_movie")
      let still = root / "still.avif"
      if not runExternal(findExe("ffmpeg"), ["-y", "-nostdin", "-hide_banner",
          "-loglevel", "error", "-f", "lavfi", "-i", "color=c=green:s=40x30",
          "-frames:v", "1", still]):
        skip()
      else:
        expect ExternalMediaError: discard probeMedia(still)
        let hashed = perceptualHashInfoFile(still)
        check (hashed.width, hashed.height) == (40, 30)
      removeDir(root)

  test "FFmpeg adapter probes and thumbnails video when available":
    if externalMediaAvailable():
      let root = fresh("unimedia_external_video")
      let video = root / "clip.mp4"
      check runExternal(findExe("ffmpeg"), ["-y", "-nostdin", "-hide_banner",
        "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=red:s=32x24:d=1", "-c:v", "mpeg4", video])
      let media = probeMedia(video)
      check (media.width, media.height) == (32, 24)
      check media.durationSeconds > 0
      let decoded = decodeMediaFrame(video, 16)
      check (decoded.width, decoded.height) == (16, 12)
      discard initLibrary(root, mdVideo)
      var store = openLibrary(root)
      discard scanLibrary(store)
      let item = store.listItems()[0]
      check (item.width, item.height) == (32, 24)
      let thumbnail = ensureThumbnail(store, item.id, 16)
      check (thumbnail.width, thumbnail.height) == (16, 12)
      store.close()
      removeDir(root)

  test "FFmpeg adapter hashes and thumbnails a real AVIF when supported":
    if externalMediaAvailable():
      let root = fresh("unimedia_external_avif")
      let imagePath = root / "still.avif"
      if runExternal(findExe("ffmpeg"), ["-y", "-nostdin", "-hide_banner",
          "-loglevel", "error", "-f", "lavfi", "-i",
          "color=c=green:s=32x24", "-frames:v", "1", imagePath]):
        discard initLibrary(root, mdPhoto)
        var store = openLibrary(root)
        let report = scanLibrary(store)
        check report.hashErrors == 0
        let item = store.listItems()[0]
        check item.extension == "avif"
        check item.phashStatus == "hashed"
        check (item.width, item.height) == (32, 24)
        let thumbnail = ensureThumbnail(store, item.id, 16)
        check (thumbnail.width, thumbnail.height) == (16, 12)
        store.close()
      removeDir(root)

  when defined(macosx):
    test "system HEIC output decodes through the shared FFmpeg boundary":
      if externalMediaAvailable() and findExe("sips").len > 0:
        let sandbox = fresh("unimedia_external_heic")
        let root = sandbox / "library"
        let source = sandbox / "source.jpg"
        createDir(root)
        var pixels = newImage[uint8](32, 24, csRgb)
        writeFile(source, cast[string](encodeJpeg(pixels)))
        let imagePath = root / "still.heic"
        if runExternal(findExe("sips"), ["-s", "format", "heic", source,
            "--out", imagePath]):
          discard initLibrary(root, mdPhoto)
          var store = openLibrary(root)
          let report = scanLibrary(store)
          check report.hashErrors == 0
          let item = store.listItems()[0]
          check item.extension == "heic"
          check item.phashStatus == "hashed"
          check (item.width, item.height) == (32, 24)
          check ensureThumbnail(store, item.id, 16).width == 16
          store.close()
        removeDir(sandbox)

  test "people registry validates regions and preserves explicit assignments":
    let root = fresh("unimedia_people")
    writeFile(root / "portrait.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    let item = store.listItems()[0]
    replaceFaces(store, item.id, [FaceDetection(x: 0.1, y: 0.2, width: 0.3,
      height: 0.4, confidence: 0.9, signature: 0x10'u64,
      signatureValid: true, detector: "test-v1"),
      FaceDetection(x: 0.5, y: 0.2, width: 0.3, height: 0.4,
        confidence: 0.8, signature: 0x11'u64, signatureValid: true,
        detector: "test-v1")])
    let clusters = clusterFaces(store, 1)
    check clusters.len == 1
    check clusters[0].faceIds.len == 2
    expect ValueError:
      replaceFaces(store, item.id, [FaceDetection(x: 0.9, y: 0.2,
        width: 0.3, height: 0.4, confidence: 0.9, detector: "test-v1")])
    let person = createPerson(store, "Ada")
    let face = listFaces(store, item.id)[0]
    assignFace(store, face.id, person)
    check listFaces(store, item.id)[0].personId == person
    check listPeople(store)[0].faceCount == 1
    expect ValueError:
      replaceFaces(store, item.id, [FaceDetection(x: 0.2, y: 0.2,
        width: 0.3, height: 0.4, confidence: 0.9, detector: "test-v2")])
    check listFaces(store, item.id).len == 2
    store.close()
    removeDir(root)

  when not defined(windows):
    test "external face detector protocol signs observations locally":
      let root = fresh("unimedia_face_detector")
      let backend = root / "fake-detector"
      writeFile(root / "portrait.ppm", ppmSize(32, 32, 64))
      writeFile(backend, """#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then output="$2"; shift 2; else shift; fi
done
printf '[{"x":0.1,"y":0.1,"width":0.5,"height":0.5,"confidence":0.9,"detector":"fake-v1"}]' > "$output"
""")
      setFilePermissions(backend, {fpUserRead, fpUserWrite, fpUserExec})
      discard initLibrary(root, mdPhoto)
      var store = openLibrary(root)
      discard scanLibrary(store)
      let detected = detectFaces(store, store.listItems()[0].id, backend)
      check detected.len == 1
      check detected[0].signatureValid
      check detected[0].detector == "fake-v1"
      writeFile(backend, """#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then output="$2"; shift 2; else shift; fi
done
printf '[{"x":"not-a-number"}]' > "$output"
""")
      setFilePermissions(backend, {fpUserRead, fpUserWrite, fpUserExec})
      expect IOError:
        discard detectFaces(store, store.listItems()[0].id, backend)
      check store.listFaces().len == 1
      store.close()
      removeDir(root)

    test "rclone sync plans exclude control state and stage pulls":
      let sandbox = fresh("unimedia_rclone_protocol")
      let root = sandbox / "library"
      let tool = sandbox / "rclone"
      let trace = sandbox / "trace.log"
      writeFile(tool, """#!/bin/sh
source_path="$2"
destination_path="$3"
log_path=""
changes_path=""
dry_run=0
for argument in "$@"; do
  if [ "$previous" = "--log-file" ]; then log_path="$argument"; fi
  if [ "$previous" = "--combined" ]; then changes_path="$argument"; fi
  if [ "$argument" = "--dry-run" ]; then dry_run=1; fi
  previous="$argument"
done
printf '%s\n' "$*" >> "$UNIMEDIA_RCLONE_TRACE"
printf 'fake rclone dry_run=%s' "$dry_run" > "$log_path"
printf '%s' "${UNIMEDIA_RCLONE_CHANGE:-= local.ppm}" > "$changes_path"
if [ "$dry_run" -eq 0 ] && [ "$source_path" = "remote:test" ]; then
  mkdir -p "$destination_path"
  printf 'remote media' > "$destination_path/remote.ppm"
fi
""")
      setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec})
      let oldPath = getEnv("PATH")
      putEnv("PATH", sandbox & $PathSep & oldPath)
      putEnv("UNIMEDIA_RCLONE_TRACE", trace)
      defer:
        putEnv("PATH", oldPath)
        delEnv("UNIMEDIA_RCLONE_TRACE")
        delEnv("UNIMEDIA_RCLONE_CHANGE")
      discard initLibrary(root, mdPhoto)
      writeFile(root / "local.ppm", ppm(32))
      var store = openLibrary(root)
      discard scanLibrary(store)
      check rcloneAvailable()
      let stale = planSync(store, "remote:test", sdPush)
      putEnv("UNIMEDIA_RCLONE_CHANGE", "+ remote-change.ppm")
      expect ValueError:
        discard applySync(store, stale.id)
      delEnv("UNIMEDIA_RCLONE_CHANGE")
      let push = planSync(store, "remote:test", sdPush)
      check push.summary.contains("local.ppm")
      check applySync(store, push.id).applied
      check listSyncRuns(store, push.id)[0].status == "applied"
      let pull = planSync(store, "remote:test", sdPull)
      check applySync(store, pull.id).applied
      check fileExists(root / ".om-incoming" / pull.id / "remote.ppm")
      let invocation = readFile(trace)
      check invocation.contains("--dry-run")
      check invocation.contains("--exclude /.organizemedia.json")
      check invocation.contains("--exclude /.organizemedia.toml")
      check invocation.contains("--exclude /.organizemedia-*.tmp")
      check invocation.contains("--exclude /organizeMedia.db*")
      check store.listItems().len == 1
      store.close()
      removeDir(sandbox)

  test "sync manifests are deterministic validated and comparable":
    let root = fresh("unimedia_sync_manifest")
    writeFile(root / "one.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    let local = buildSyncManifest(store)
    check local.schemaVersion == SyncManifestVersion
    check local.entries.len == 1
    check local.entries[0].path == "one.ppm"
    check parseSyncManifest($syncManifestJson(local)).entries == local.entries
    var remote = local
    remote.entries[0].digest = "different"
    remote.entries.add SyncManifestEntry(path: "two.ppm", size: 1, mtimeNs: 0,
      digest: "remote")
    let difference = diffSyncManifests(local, remote)
    check difference.changed == @["one.ppm"]
    check difference.onlyRemote == @["two.ppm"]
    expect ValueError:
      discard parseSyncManifest("""{"schemaVersion":1,"entries":[{"path":"../escape","size":1,"mtimeNs":0,"digest":"x"}]}""")
    store.db.exec(sql"UPDATE item_hashes SET blake3='' WHERE item_id=?",
      store.listItems()[0].id)
    expect ValueError:
      discard buildSyncManifest(store)
    store.close()
    removeDir(root)

  test "semantic vectors are validated ranked and model isolated":
    let root = fresh("unimedia_vision")
    writeFile(root / "one.ppm", ppm(32))
    writeFile(root / "two.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    let items = store.listItems()
    storeVisionDocument(store, items[0].id, "test", "first", ["red"],
      [1.0, 0.0])
    storeVisionDocument(store, items[1].id, "test", "second", ["blue"],
      [0.0, 1.0])
    let hits = semanticSearch(store, "test", [0.9, 0.1], 2)
    check hits.len == 2
    check hits[0].itemId == items[0].id
    check hits[0].score > hits[1].score
    let annotation = storeVisionAnnotation(store, items[0].id, "vision-test",
      "A red square", ["red", "square"])
    check annotation.labels == @["red", "square"]
    check listVisionAnnotations(store, items[0].id)[0].caption == "A red square"
    let parsed = parseOllamaDescription(
      "{\"caption\":\"A harbour\",\"labels\":[\"sea\",\"boat\"]}")
    check parsed.caption == "A harbour"
    check parsed.labels == @["sea", "boat"]
    expect IOError:
      discard parseOllamaDescription("{\"caption\":\"\",\"labels\":[]}")
    expect ValueError:
      storeVisionDocument(store, items[0].id, "test", "", [], [0.0, 0.0])
    store.close()
    removeDir(root)
  test "visual scan stores decoded display dimensions without a second decode":
    let root = fresh("unimedia_dimensions")
    writeFile(root / "wide.ppm", ppmSize(32, 8, 64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    let item = store.listItems()[0]
    check (item.width, item.height) == (32, 8)
    store.close()
    removeDir(root)

  test "visual scan stores EXIF-oriented display dimensions":
    let root = fresh("unimedia_oriented_dimensions")
    orientedJpeg(root / "portrait.jpg", 16, 8, 6)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    let item = store.listItems()[0]
    check (item.width, item.height) == (8, 16)
    store.close()
    removeDir(root)

  test "a changed image invalidates dimensions when visual hashing is deferred":
    let root = fresh("unimedia_dimensions_invalidation")
    let media = root / "photo.ppm"
    writeFile(media, ppmSize(32, 8, 64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store)
    check store.listItems()[0].width == 32
    writeFile(media, ppmSize(33, 8, 64))
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    check (item.width, item.height) == (0, 0)
    check item.phashStatus == "pending"
    store.close()
    removeDir(root)

  test "thumbnail cache is bounded, deterministic, and detects stale catalog data":
    let root = fresh("unimedia_thumbnails")
    let media = root / "wide.ppm"
    writeFile(media, ppmSize(32, 8, 64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    let generated = ensureThumbnail(store, item.id, 16)
    check not generated.cacheHit
    check (generated.width, generated.height) == (16, 4)
    check fileExists(generated.path)
    check generated.path.startsWith(root / ThumbnailCacheDir)
    let cached = ensureThumbnail(store, item.id, 16)
    check cached.cacheHit
    check cached.path == generated.path
    writeFile(cached.path, "not a png")
    let repaired = ensureThumbnail(store, item.id, 16)
    check not repaired.cacheHit
    check (repaired.width, repaired.height) == (16, 4)
    writeFile(media, ppmSize(33, 8, 64))
    expect ValueError:
      discard ensureThumbnail(store, item.id, 16)
    store.close()
    removeDir(root)

  test "a shared thumbnail cache hit backfills dimensions after deferred hashing":
    let root = fresh("unimedia_shared_thumbnail_dimensions")
    let content = ppmSize(32, 8, 64)
    writeFile(root / "a.ppm", content)
    writeFile(root / "b.ppm", content)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    let first = ensureThumbnail(store, items[0].id, 16)
    let second = ensureThumbnail(store, items[1].id, 16)
    check not first.cacheHit
    check second.cacheHit
    check second.path == first.path
    check (store.getItem(items[0].id).width,
      store.getItem(items[0].id).height) == (32, 8)
    check (store.getItem(items[1].id).width,
      store.getItem(items[1].id).height) == (32, 8)
    store.close()
    removeDir(root)

  when not defined(windows):
    test "thumbnail cache refuses symbolic entries":
      let sandbox = fresh("unimedia_thumbnail_symlink")
      let root = sandbox / "library"
      let outside = sandbox / "outside.png"
      writeFile(outside, "do not read")
      discard initLibrary(root, mdPhoto)
      writeFile(root / "photo.ppm", ppm(64))
      var store = openLibrary(root)
      discard scanLibrary(store, skipPhash = true)
      let item = store.listItems()[0]
      let generated = ensureThumbnail(store, item.id, 16)
      removeFile(generated.path)
      createSymlink(outside, generated.path)
      expect ValueError:
        discard ensureThumbnail(store, item.id, 16)
      store.close()
      removeDir(sandbox)

  test "thumbnail generation rejects non-visual items and invalid sizes":
    let root = fresh("unimedia_thumbnail_validation")
    writeFile(root / "photo.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    expect ValueError:
      discard ensureThumbnail(store, item.id, MinThumbnailEdge - 1)
    store.db.exec(sql"UPDATE items SET category='audio' WHERE id=?", item.id)
    expect ValueError:
      discard ensureThumbnail(store, item.id)
    store.close()
    removeDir(root)

  test "item curation preserves unrelated XMP and survives catalogue reopen":
    let root = fresh("unimedia_curation")
    let media = root / "photo.ppm"
    writeFile(media, ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    let sidecar = media & ".xmp"
    writeFile(sidecar, """<?xpacket begin=""?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description xmlns:vendor="https://vendor.invalid/ns/"
   vendor:Opaque="keep"><vendor:Tree><rdf:Bag><rdf:li>A</rdf:li>
   </rdf:Bag></vendor:Tree></rdf:Description>
 </rdf:RDF>
</x:xmpmeta>""")
    var patch: CurationPatch
    patch.title = some("  A title  ")
    patch.description = some("Description")
    patch.rating = some(5)
    patch.favorite = some(true)
    patch.keywords = some(@[" Travel ", "travel", "family"])
    patch.creationDate = some("2024-06-07T08:09:10")
    patch.latitude = some(48.8566)
    patch.longitude = some(2.3522)
    patch.locationText = some(" Paris, France ")
    let saved = curateItem(store, item.id, patch)
    check saved.title == "A title"
    check saved.rating == 5
    check saved.favorite
    check saved.keywords == @["Travel", "family"]
    check saved.creationDate == "2024-06-07 08:09:10"
    check saved.dateSource == "curation"
    check abs(saved.latitude.get() - 48.8566) < 0.000001
    check abs(saved.longitude.get() - 2.3522) < 0.000001
    check saved.locationText == "Paris, France"
    let xml = readFile(sidecar)
    check "vendor:Opaque=\"keep\"" in xml
    check "<vendor:Tree>" in xml
    check "<xmp:Rating>5</xmp:Rating>" in xml
    check "<om:Favorite>true</om:Favorite>" in xml
    check "<xmp:CreateDate>2024-06-07T08:09:10</xmp:CreateDate>" in xml
    check "<exif:GPSLatitude>48,51.396N</exif:GPSLatitude>" in xml
    check "<exif:GPSLongitude>2,21.132E</exif:GPSLongitude>" in xml
    check "<Iptc4xmpCore:Location>Paris, France</Iptc4xmpCore:Location>" in xml
    check store.getItemCuration(item.id).title == "A title"
    store.close()
    store = openLibrary(root)
    let reopened = store.getItemCuration(item.id)
    check reopened.keywords == @["Travel", "family"]
    check reopened.creationDate == "2024-06-07 08:09:10"
    check reopened.latitude.isSome
    check reopened.locationText == "Paris, France"
    writeFile(media, ppm(65))
    discard scanLibrary(store, skipPhash = true)
    check store.getItem(item.id).creationDate == "2024-06-07 08:09:10"
    check store.getItem(item.id).dateSource == "curation"
    var keywordEdit: CurationPatch
    keywordEdit.addKeywords = @["Sea", "FAMILY"]
    keywordEdit.removeKeywords = @["travel"]
    let edited = curateItem(store, item.id, keywordEdit)
    check edited.keywords == @["family", "Sea"]
    var contradictory: CurationPatch
    contradictory.addKeywords = @["sea"]
    contradictory.removeKeywords = @["SEA"]
    expect ValueError:
      discard curateItem(store, item.id, contradictory)
    var clearGps: CurationPatch
    clearGps.clearGps = true
    let cleared = curateItem(store, item.id, clearGps)
    check cleared.latitude.isNone
    check cleared.longitude.isNone
    check "exif:GPSLatitude" notin readFile(sidecar)
    store.close()
    removeDir(root)

  test "creator and copyright reach the sidecar and survive a recovery":
    let root = fresh("unimedia_creator_rights")
    let media = root / "photo.ppm"
    writeFile(media, ppm(72))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    var patch: CurationPatch
    # Order matters in dc:creator, and a name may contain a comma.
    patch.creator = some(@["Doe, Jane", " Ansel Adams "])
    patch.copyright = some("  (c) 2026 lituus-lab  ")
    let saved = curateItem(store, item.id, patch)
    check saved.creator == @["Doe, Jane", "Ansel Adams"]
    check saved.copyright == "(c) 2026 lituus-lab"

    let sidecar = readFile(media & ".xmp")
    check "dc:creator" in sidecar
    check "Ansel Adams" in sidecar
    check "dc:rights" in sidecar

    # Read back from SQLite, not from the object just returned.
    check getItemCuration(store, item.id).creator == @["Doe, Jane", "Ansel Adams"]
    check getItemCuration(store, item.id).copyright == "(c) 2026 lituus-lab"

    # A pending journal row is replayed by recovery; if the two columns were
    # missing there, writeState would erase them.
    store.db.exec(sql"UPDATE curation_ops SET status='pending'")
    recoverCurationOps(store)
    check getItemCuration(store, item.id).creator == @["Doe, Jane", "Ansel Adams"]
    check getItemCuration(store, item.id).copyright == "(c) 2026 lituus-lab"

    var clearing: CurationPatch
    clearing.creator = some(newSeq[string]())
    check curateItem(store, item.id, clearing).creator.len == 0
    store.close()
    removeDir(root)

  test "item curation validates values before creating a journal entry":
    let root = fresh("unimedia_curation_validation")
    writeFile(root / "photo.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    var patch: CurationPatch
    patch.rating = some(6)
    expect ValueError:
      discard curateItem(store, store.listItems()[0].id, patch)
    check store.db.getValue(sql"SELECT count(*) FROM curation_ops") == "0"
    check not fileExists(root / "photo.ppm.xmp")
    patch.rating = none(int)
    patch.creationDate = some("2026-02-30")
    expect ValueError:
      discard curateItem(store, store.listItems()[0].id, patch)
    patch.creationDate = none(string)
    patch.latitude = some(91.0)
    patch.longitude = some(0.0)
    expect ValueError:
      discard curateItem(store, store.listItems()[0].id, patch)
    patch.latitude = some(1.0)
    patch.longitude = none(float)
    expect ValueError:
      discard curateItem(store, store.listItems()[0].id, patch)
    check store.db.getValue(sql"SELECT count(*) FROM curation_ops") == "0"
    store.close()
    removeDir(root)

  test "an interrupted sidecar write is finalized from its journal":
    let root = fresh("unimedia_curation_recovery")
    let media = root / "photo.ppm"
    writeFile(media, ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    let xml = buildXmp(XmpData(title: "Recovered"))
    writeFile(media & ".xmp", xml)
    store.db.exec(sql"""
      INSERT INTO curation_ops(id,item_id,sidecar_rel_path,old_exists,old_xmp,
        new_xmp,title,description,rating,favorite,keywords_json,creation_date,
        date_source,latitude,longitude,location_text,status,created_at)
      VALUES('curation_test',?,'photo.ppm.xmp',0,'',?,'Recovered','',3,1,
        '["restored"]','2023-02-03 04:05:06','curation',51.5,-0.125,
        'London','pending','now')""", item.id, xml)
    recoverCurationOps(store)
    let recovered = getItemCuration(store, item.id)
    check recovered.title == "Recovered"
    check recovered.rating == 3
    check recovered.favorite
    check recovered.keywords == @["restored"]
    check recovered.creationDate == "2023-02-03 04:05:06"
    check recovered.latitude == some(51.5)
    check recovered.longitude == some(-0.125)
    check recovered.locationText == "London"
    check store.db.getValue(sql"""
      SELECT status FROM curation_ops WHERE id='curation_test'""") == "applied"
    store.close()
    removeDir(root)

  test "copy is journaled, scanned, deduplicated, and undone":
    let sandbox = fresh("unimedia_engine")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "IMG_20260731.ppm", ppm(255))
    writeFile(source / "copy_20260731.ppm", ppm(255))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    let plan = planOrganize(store, source, options)
    check plan.operations.len == 2
    check plan.operations[0].destRelPath.startsWith("2026/07-31/")
    let applied = applyPlan(store, plan)
    check applied.applied == 2
    check applied.failed == 0
    check store.listItems().len == 2
    let runId = findDuplicates(store, dkExact)
    let run = loadDedupRun(store, runId)
    check run.groups.len == 1
    check run.groups[0].members.len == 2
    let undoPlan = planUndo(store, applied.batchId)
    check undoPlan.len == 2
    let undone = applyUndo(store, applied.batchId)
    check undone.undone == 2
    check store.listItems().len == 0
    store.close()
    removeDir(sandbox)

  test "organize and undo progress totals include every actionable operation":
    let sandbox = fresh("unimedia_progress")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "a_20260731.ppm", ppm(16))
    writeFile(source / "b_20260731.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    createDir(root / "2026" / "07-31")
    copyFile(source / "a_20260731.ppm", root / "2026" / "07-31" /
      "a_20260731.ppm")
    var store = openLibrary(root)
    let plan = planOrganize(store, source,
      defaultOrganizeOptions(store.library.config))
    check plan.operations.countIt(it.skipReason.len == 0) == 1
    observedProgress.setLen(0)
    let report = applyPlan(store, plan, recordProgress)
    let organizeEvents = observedProgress.filterIt(it.phase == "organize")
    check organizeEvents.len == 1
    check (organizeEvents[0].current, organizeEvents[0].total) == (1, 1)
    check observedProgress.anyIt(it.phase == "scan")
    observedProgress.setLen(0)
    discard applyUndo(store, report.batchId, recordProgress)
    let undoEvents = observedProgress.filterIt(it.phase == "undo")
    check undoEvents.len == 1
    check (undoEvents[0].current, undoEvents[0].total) == (1, 1)
    store.close()
    removeDir(sandbox)

  test "undo refuses to delete a changed destination":
    let sandbox = fresh("unimedia_undo_guard")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "IMG_20260731.ppm", ppm(255))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let plan = planOrganize(store, source,
      defaultOrganizeOptions(store.library.config))
    let applied = applyPlan(store, plan)
    let destination = store.absoluteItemPath(plan.operations[0].destRelPath)
    writeFile(destination, ppm(1))
    let undone = applyUndo(store, applied.batchId)
    check undone.failed == 1
    check fileExists(destination)
    store.close()
    removeDir(sandbox)

  test "undo refuses a move whose original path is occupied":
    let sandbox = fresh("unimedia_undo_occupied_source")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    let original = source / "IMG_20260731.ppm"
    writeFile(original, ppm(255))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmMove
    let plan = planOrganize(store, source, options)
    let applied = applyPlan(store, plan)
    let destination = store.absoluteItemPath(plan.operations[0].destRelPath)
    writeFile(original, ppm(1))
    let undone = applyUndo(store, applied.batchId)
    check undone.failed == 1
    check fileExists(destination)
    check readFile(original) == ppm(1)
    store.close()
    removeDir(sandbox)

  test "scan is idempotent":
    let root = fresh("unimedia_scan")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "photo_20260731.ppm", ppm(128))
    var store = openLibrary(root)
    let first = scanLibrary(store)
    let second = scanLibrary(store)
    check first.indexed == 1
    check second.indexed == 0
    check second.updated == 0
    check store.listItems().len == 1
    store.close()
    removeDir(root)

  test "an exact hash error is retried without a metadata change":
    let root = fresh("unimedia_hash_retry")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "retry.ppm", ppm(128))
    var store = openLibrary(root)
    discard scanLibrary(store)
    store.db.exec(sql"DELETE FROM item_hashes")
    store.db.exec(sql"UPDATE items SET hash_status='error'")
    let retry = scanLibrary(store)
    check retry.hashErrors == 0
    check store.listItems()[0].hashStatus == "hashed"
    store.close()
    removeDir(root)

  test "a scan without pHash can be completed later":
    let root = fresh("unimedia_deferred_phash")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "deferred.ppm", ppm(128))
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    check store.listItems()[0].phashStatus == "pending"
    discard scanLibrary(store, skipPhash = false)
    check store.listItems()[0].phashStatus == "hashed"
    store.close()
    removeDir(root)

  test "visual groups never include a member below the threshold":
    let root = fresh("unimedia_visual_threshold")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    for index, hash in [0'i64, 1'i64, 3'i64]:
      store.db.exec(sql"""
        INSERT INTO items(rel_path,file_size,mtime_ns,category,extension,
          creation_date,date_source,hash_status,phash_status,indexed_at)
        VALUES(?,1,1,'image','ppm','','','hashed','hashed','now')""",
        "item" & $index & ".ppm")
      let itemId = store.db.getValue(sql"SELECT last_insert_rowid()")
      store.db.exec(sql"""
        INSERT INTO item_hashes(item_id,blake3,phash,computed_at)
        VALUES(?,?,?,'now')""", itemId, "hash" & $index, hash)
    store.db.exec(sql"UPDATE items SET hash_status='error' WHERE rel_path='item1.ppm'")
    let run = loadDedupRun(store, findDuplicates(store, dkVisual, 98.0))
    check run.groups.len == 1
    check run.groups[0].members.len == 2
    for member in run.groups[0].members:
      check member.similarity >= 0.98
    store.close()
    removeDir(root)

  test "a re-encoded video is a visual duplicate although its bytes differ":
    if externalMediaAvailable():
      let root = fresh("unimedia_video_dedup")
      createDir(root)
      let ffmpeg = findExe("ffmpeg")
      let original = root / "original.mp4"
      let reencoded = root / "reencoded.mp4"
      # A moving pattern, so the sampled frames differ from each other and a
      # match means shared content rather than a shared flat colour.
      check runExternal(ffmpeg, ["-y", "-nostdin", "-hide_banner", "-loglevel",
        "error", "-f", "lavfi", "-i", "testsrc=size=64x48:rate=10:duration=3",
        "-c:v", "mpeg4", original])
      check runExternal(ffmpeg, ["-y", "-nostdin", "-hide_banner", "-loglevel",
        "error", "-i", original, "-c:v", "mpeg4", "-q:v", "25", reencoded])
      check readFile(original) != readFile(reencoded)
      discard initLibrary(root, mdVideo)
      var store = openLibrary(root)
      check scanLibrary(store).hashErrors == 0
      check store.db.getValue(sql"""SELECT count(*) FROM item_frame_hashes""")
        .parseInt() == 2 * VideoFrameSamples
      # Exact hashing cannot see a re-encode; the sampled frames can.
      check loadDedupRun(store, findDuplicates(store, dkExact)).groups.len == 0
      let visual = loadDedupRun(store, findDuplicates(store, dkVisual))
      check visual.groups.len == 1
      check visual.groups[0].members.len == 2
      store.close()
      removeDir(root)

  test "a re-encoded track is an audio duplicate although its bytes differ":
    if audioFingerprintAvailable() and findExe("ffmpeg").len > 0:
      let root = fresh("unimedia_audio_dedup")
      createDir(root)
      let ffmpeg = findExe("ffmpeg")
      let original = root / "original.flac"
      let reencoded = root / "reencoded.mp3"
      # A varying tone: silence fingerprints alike whatever the source.
      check runExternal(ffmpeg, ["-y", "-nostdin", "-hide_banner", "-loglevel",
        "error", "-f", "lavfi", "-i",
        "sine=frequency=440:duration=15,aeval=val(0)*sin(2*PI*t/3)",
        "-c:a", "flac", original])
      check runExternal(ffmpeg, ["-y", "-nostdin", "-hide_banner", "-loglevel",
        "error", "-i", original, "-c:a", "libmp3lame", "-b:a", "96k",
        reencoded])
      check readFile(original) != readFile(reencoded)
      discard initLibrary(root, mdMusic)
      var store = openLibrary(root)
      check scanLibrary(store).hashErrors == 0
      check store.db.getValue(
        sql"SELECT count(*) FROM item_audio_hashes").parseInt() == 2
      # Bytes differ, so exact finds nothing and the image passes stay empty.
      check loadDedupRun(store, findDuplicates(store, dkExact)).groups.len == 0
      check loadDedupRun(store, findDuplicates(store, dkVisual)).groups.len == 0
      let audio = loadDedupRun(store, findDuplicates(store, dkAudio))
      check audio.groups.len == 1
      check audio.groups[0].members.len == 2
      store.close()
      removeDir(root)

  test "duplicate thresholds reject NaN before integer conversion":
    let root = fresh("unimedia_nan_threshold")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    expect ValueError:
      discard findDuplicates(store, dkVisual, NaN)
    store.close()
    removeDir(root)

  test "duplicate review changes the keeper atomically and protects all keepers":
    let root = fresh("unimedia_dedup_keeper")
    writeFile(root / "a.ppm", ppm(64))
    writeFile(root / "b.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    let runId = findDuplicates(store, dkExact)
    let groupId = loadDedupRun(store, runId).groups[0].id
    setDedupKeeper(store, groupId, items[1].id)
    let selected = loadDedupRun(store, runId).groups[0].members
    check selected.filterIt(it.isKeeper).len == 1
    check selected.filterIt(it.isKeeper)[0].itemId == items[1].id
    check planDedupRemoval(store, runId)[0].itemId == items[0].id
    expect ValueError:
      setDedupKeeper(store, groupId, 999)
    check loadDedupRun(store, runId).groups[0].members.filterIt(it.isKeeper)[
        0].itemId ==
      items[1].id
    store.db.exec(sql"INSERT INTO dedup_groups(run_id,kind) VALUES(?,'visual')",
      runId)
    let otherGroup = store.db.getValue(sql"SELECT last_insert_rowid()")
    store.db.exec(sql"""
      INSERT INTO dedup_members(group_id,item_id,similarity,is_keeper)
      VALUES(?,?,1.0,1),(?,?,1.0,0)""", otherGroup, items[0].id,
      otherGroup, items[1].id)
    check planDedupRemoval(store, runId).len == 0
    store.close()
    removeDir(root)

  test "dedup removal preserves identity sidecars and undo":
    let root = fresh("unimedia_dedup_remove")
    writeFile(root / "a.ppm", ppm(64))
    writeFile(root / "b.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    let candidate = items[1]
    let album = createAlbum(store, "Duplicates")
    discard addAlbumItem(store, album.id, candidate.id)
    var patch: CurationPatch
    patch.title = some("Retained metadata")
    discard curateItem(store, candidate.id, patch)
    let run = findDuplicates(store, dkExact)
    let plan = planDedupRemoval(store, run)
    check plan.len == 1
    check plan[0].itemId == candidate.id
    let report = applyDedupRemoval(store, run)
    check report.applied == 1
    check report.failed == 0
    check not fileExists(root / candidate.relPath)
    check not fileExists(root / (candidate.relPath & ".xmp"))
    check store.listItems().len == 1
    check getAlbum(store, album.id).itemCount == 0
    let undo = applyUndo(store, report.batchId)
    check undo.failed == 0
    check fileExists(root / candidate.relPath)
    check fileExists(root / (candidate.relPath & ".xmp"))
    check store.getItem(candidate.id).relPath == candidate.relPath
    check getAlbum(store, album.id).itemCount == 1
    check getItemCuration(store, candidate.id).title == "Retained metadata"
    store.close()
    removeDir(root)

  test "a plain folder of photographs can become a library":
    let root = fresh("unimedia_become_library")
    writeFile(root / "one.ppm", ppm(21))
    check not libraryExists(root)

    discard initLibrary(root, mdVisual)
    check libraryExists(root)
    # Creating catalogues nothing by itself, and touches no media.
    var store = openLibrary(root)
    check store.listItems().len == 0
    check readFile(root / "one.ppm") == ppm(21)
    check scanLibrary(store, skipPhash = true).indexed == 1
    check store.listItems().len == 1
    store.close()

    # A second creation is refused rather than overwriting what is there.
    expect IOError:
      discard initLibrary(root, mdVisual)
    removeDir(root)

  test "re-filing a library leaves its own bookkeeping alone":
    let root = fresh("unimedia_refile_internals")
    writeFile(root / "a.ppm", ppm(30))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    # A rendered thumbnail is a PNG under .om-cache. Filing the library walks
    # the library, and must not take it for one more photo.
    let rendered = ensureThumbnail(store, item.id, 64)
    check fileExists(rendered.path)
    let plan = planOrganize(store, root,
      defaultOrganizeOptions(store.library.config))
    check plan.operations.len == 1
    check plan.operations[0].sourcePath == root / "a.ppm"
    store.close()
    removeDir(root)

  test "chosen items are removed together and come back together":
    let root = fresh("unimedia_trash_items")
    for index in 0..2:
      writeFile(root / ("item" & $index & ".ppm"), ppm(index * 40))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    check items.len == 3
    # Naming one item twice must not queue it twice.
    let report = trashItems(store, @[items[0].id, items[2].id, items[0].id])
    check report.applied == 2
    check report.failed == 0
    check store.listItems().len == 1
    check not fileExists(root / items[0].relPath)
    check fileExists(root / items[1].relPath)
    let undo = applyUndo(store, report.batchId)
    check undo.failed == 0
    check store.listItems().len == 3
    check fileExists(root / items[2].relPath)
    store.close()
    removeDir(root)

  test "an unknown item fails the whole removal, moving nothing":
    let root = fresh("unimedia_trash_unknown")
    writeFile(root / "keep.ppm", ppm(12))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let kept = store.listItems()[0]
    expect ValueError:
      discard trashItems(store, @[kept.id, 9999'i64])
    check fileExists(root / kept.relPath)
    check store.listItems().len == 1
    expect ValueError:
      discard trashItems(store, @[])
    store.close()
    removeDir(root)

  test "dedup undo refuses changed trash content":
    let root = fresh("unimedia_dedup_changed_trash")
    writeFile(root / "a.ppm", ppm(64))
    writeFile(root / "b.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let run = findDuplicates(store, dkExact)
    let report = applyDedupRemoval(store, run)
    let trashRel = store.db.getValue(sql"""
      SELECT dest_rel_path FROM batch_ops
      WHERE batch_id=? AND kind='delete'""", report.batchId)
    writeFile(root / trashRel, ppm(32))
    let undo = applyUndo(store, report.batchId)
    check undo.failed == 1
    check not fileExists(root / "b.ppm")
    check store.listItems().len == 1
    store.close()
    removeDir(root)

  test "dedup undo reconciles an already restored file":
    let root = fresh("unimedia_dedup_undo_recovery")
    writeFile(root / "a.ppm", ppm(64))
    writeFile(root / "b.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let candidate = store.listItems()[1]
    let report = applyDedupRemoval(store, findDuplicates(store, dkExact))
    let trashRel = store.db.getValue(sql"""
      SELECT dest_rel_path FROM batch_ops
      WHERE batch_id=? AND kind='delete'""", report.batchId)
    moveFile(root / trashRel, root / candidate.relPath)
    let undo = applyUndo(store, report.batchId)
    check undo.failed == 0
    check store.getItem(candidate.id).relPath == candidate.relPath
    check store.db.getValue(sql"""
      SELECT status FROM batch_ops WHERE batch_id=? AND kind='delete'""",
      report.batchId) == "undone"
    store.close()
    removeDir(root)

  test "catalog lookup and literal search are deterministic":
    let root = fresh("unimedia_catalog_search")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "Summer_100%.ppm", ppm(128))
    writeFile(root / "Winter_1000.ppm", ppm(64))
    var store = openLibrary(root)
    discard scanLibrary(store)
    let summer = store.searchItems("100%")
    check summer.len == 1
    check summer[0].relPath == "Summer_100%.ppm"
    check store.searchItems("summer")[0].id == summer[0].id
    check store.getItem(summer[0].id).relPath == summer[0].relPath
    var patch: CurationPatch
    patch.title = some("Mediterranean evening")
    patch.description = some("At the old harbour")
    patch.keywords = some(@["sailing", "family"])
    discard curateItem(store, summer[0].id, patch)
    check store.searchItems("Mediterranean")[0].id == summer[0].id
    check store.searchItems("harbour")[0].id == summer[0].id
    check store.searchItems("sailing")[0].id == summer[0].id
    check store.countItems() == 2
    check store.countItems("image") == 2
    check store.listItemsPage(limit = 1, offset = 1)[0].relPath ==
      "Winter_1000.ppm"
    check store.searchItems("100", limit = 1, offset = 1)[0].relPath ==
      "Winter_1000.ppm"
    let pageFilter = CatalogFilter(kind: "image")
    check filterItems(store, pageFilter, limit = 1, offset = 1)[0].relPath ==
      "Winter_1000.ppm"
    expect ValueError:
      discard store.searchItems("", limit = 1)
    expect ValueError:
      discard store.searchItems("Summer", limit = 0)
    expect ValueError:
      discard store.listItemsPage(offset = -1)
    expect ValueError:
      discard store.searchItems("Summer", offset = -1)
    expect ValueError:
      discard filterItems(store, pageFilter, offset = -1)
    store.close()
    removeDir(root)

  test "catalog facets combine text curation rating favorite and date":
    let root = fresh("unimedia_catalog_facets")
    writeFile(root / "IMG_20260102.ppm", ppm(16))
    writeFile(root / "IMG_20260203.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    check items[0].latitude.isNone
    check items[0].longitude.isNone
    check items[0].locationText.len == 0
    var first: CurationPatch
    first.title = some("Harbour sunset")
    first.rating = some(5)
    first.favorite = some(true)
    first.keywords = some(@["family", "sea"])
    first.latitude = some(48.8566)
    first.longitude = some(2.3522)
    first.locationText = some("Paris, France")
    discard curateItem(store, items[0].id, first)
    var second: CurationPatch
    second.title = some("Mountain snow")
    second.rating = some(3)
    second.favorite = some(false)
    second.keywords = some(@["family", "snow"])
    second.locationText = some("paris, france")
    discard curateItem(store, items[1].id, second)

    let matches = filterItems(store, CatalogFilter(text: "sunset",
      keywords: @["FAMILY", "sea", "family"], minRating: some(4),
      maxRating: some(5),
      favorite: some(true), dateFrom: "2026-01-01", dateTo: "2026-01-31"))
    check matches.len == 1
    check matches[0].id == items[0].id
    check filterItems(store, CatalogFilter(favorite: some(false))).len == 1
    check filterItems(store, CatalogFilter(location: "PARIS")).len == 2
    check filterItems(store, CatalogFilter(hasGps: some(true))).len == 1
    check filterItems(store, CatalogFilter(hasGps: some(false))).len == 1
    let places = listPlaceFacets(store, "PAR")
    check places.len == 1
    check places[0].location == "Paris, France"
    check places[0].itemCount == 2
    check places[0].gpsCount == 1
    check abs(places[0].latitude.get() - 48.8566) < 0.000001
    expect ValueError:
      discard listPlaceFacets(store, " ")
    expect ValueError:
      discard listPlaceFacets(store, limit = 0)
    expect ValueError:
      discard filterItems(store, CatalogFilter(minRating: some(5),
        maxRating: some(4)))
    expect ValueError:
      discard filterItems(store, CatalogFilter(dateFrom: "2026-02-30"))
    check filterItems(store, CatalogFilter(keywords: @["family",
        "snow"])).len == 1
    expect ValueError:
      discard filterItems(store, CatalogFilter(keywords: @[""]))
    store.close()
    removeDir(root)

  test "keyword facets count items once and use deterministic ordering":
    let root = fresh("unimedia_keyword_facets")
    writeFile(root / "one.ppm", ppm(16))
    writeFile(root / "two.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    var first: CurationPatch
    first.keywords = some(@["Family", "family", "sea"])
    discard curateItem(store, items[0].id, first)
    var second: CurationPatch
    second.keywords = some(@["family", "snow"])
    discard curateItem(store, items[1].id, second)

    let facets = listKeywordFacets(store)
    check facets.len == 3
    check facets[0] == KeywordFacet(keyword: "family", itemCount: 2)
    check facets[1] == KeywordFacet(keyword: "sea", itemCount: 1)
    check facets[2] == KeywordFacet(keyword: "snow", itemCount: 1)
    check listKeywordFacets(store, prefix = "SN")[0].keyword == "snow"
    check listKeywordFacets(store, limit = 1).len == 1
    expect ValueError:
      discard listKeywordFacets(store, limit = 0)
    store.close()
    removeDir(root)

  test "timeline groups dated items without mutating the catalogue":
    let root = fresh("unimedia_timeline")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "IMG_20260102.ppm", ppm(16))
    writeFile(root / "IMG_20260103.ppm", ppm(32))
    writeFile(root / "IMG_20260201.ppm", ppm(64))
    var store = openLibrary(root)
    discard scanLibrary(store)
    let months = timelineReport(store, tpMonth)
    check months.len == 2
    check months[0].period == "2026-01"
    check months[0].itemCount == 2
    check months[1].period == "2026-02"
    check timelineReport(store, tpYear)[0].itemCount == 3
    check store.listItems().len == 3
    store.close()
    removeDir(root)

  test "privacy audit reports categories without exposing values":
    let root = fresh("unimedia_privacy")
    discard initLibrary(root, mdPhoto)
    privateJpeg(root / "private.jpg")
    var store = openLibrary(root)
    discard scanLibrary(store)
    let findings = privacyAudit(store)
    check findings.len == 1
    check findings[0].relPath == "private.jpg"
    check "gps" in findings[0].signals
    check "software" in findings[0].signals
    check "48.8566" notin $findings[0].signals
    store.close()
    removeDir(root)

  test "privacy strip is planned, journaled, and restores the exact original":
    let root = fresh("unimedia_privacy_strip")
    let media = root / "private.jpg"
    privateJpeg(media)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    var patch: CurationPatch
    patch.title = some("Private title")
    discard curateItem(store, item.id, patch)
    let originalHash = blake3File(media)
    let sidecar = media & ".xmp"
    check fileExists(sidecar)
    let plan = planPrivacyStrip(store, @[item.id])
    check plan.entries.len == 1
    let report = applyPrivacyStrip(store, plan)
    check report.applied == 1
    check blake3File(media) != originalHash
    check not fileExists(sidecar)
    check privacyAudit(store).len == 0
    let undone = applyUndo(store, report.batchId)
    check undone.failed == 0
    check blake3File(media) == originalHash
    check fileExists(sidecar)
    check "gps" in privacyAudit(store)[0].signals
    store.close()
    removeDir(root)

  test "curation batches prevalidate, deduplicate, and report item failures":
    let root = fresh("unimedia_curation_batch")
    writeFile(root / "first.ppm", ppm(10))
    writeFile(root / "second.ppm", ppm(20))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    var patch: CurationPatch
    patch.addKeywords = @["Travel", "travel"]
    patch.rating = some(4)
    let plan = planCurationBatch(store,
      @[items[0].id, items[0].id, items[1].id], patch)
    check plan.entries.len == 2
    let report = applyCurationBatch(store, plan)
    check report.applied == 2
    check report.failed == 0
    for item in items:
      let curated = store.getItemCuration(item.id)
      check curated.rating == 4
      check curated.keywords == @["Travel"]
    var invalid: CurationPatch
    invalid.rating = some(9)
    expect ValueError:
      discard planCurationBatch(store, @[items[0].id], invalid)
    expect ValueError:
      discard planCurationBatch(store, @[items[0].id], CurationPatch())
    store.close()
    removeDir(root)

  test "date set and shift plans reject stale state before writing":
    let root = fresh("unimedia_date_edit")
    writeFile(root / "first.ppm", ppm(30))
    writeFile(root / "second.ppm", ppm(40))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    let setPlan = planDateSet(store, @[items[0].id, items[1].id],
      " 2026-08-01T12:30:00 ")
    check setPlan.entries[0].newDate == "2026-08-01 12:30:00"
    check applyDateEdit(store, setPlan).applied == 2
    let shiftPlan = planDateShift(store, @[items[0].id, items[1].id], 3600)
    check shiftPlan.entries[0].newDate == "2026-08-01 13:30:00"
    var conflicting: CurationPatch
    conflicting.creationDate = some("2026-08-02")
    discard store.curateItem(items[0].id, conflicting)
    expect ValueError:
      discard applyDateEdit(store, shiftPlan)
    check store.getItem(items[1].id).creationDate == "2026-08-01 12:30:00"
    expect ValueError:
      discard planDateShift(store, @[items[0].id], 0)
    store.close()
    removeDir(root)

  test "GPX matching normalizes timezones and journals matched coordinates":
    let root = fresh("unimedia_gpx")
    writeFile(root / "first.ppm", ppm(50))
    writeFile(root / "second.ppm", ppm(60))
    let track = root / "track.gpx"
    writeFile(track, """<?xml version="1.0"?>
<gpx version="1.1"><trk><trkseg>
  <trkpt lat="48.1000" lon="2.2000"><time>2026-08-01T10:00:00.500Z</time></trkpt>
  <trkpt lat="48.2000" lon="2.3000"><time>2026-08-01T12:00:00+02:00</time></trkpt>
</trkseg></trk></gpx>""")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    for item in items:
      var patch: CurationPatch
      patch.creationDate = some("2026-08-01 12:00:00")
      discard store.curateItem(item.id, patch)
    let plan = planGpxMatch(store, track, @[items[0].id, items[1].id],
      toleranceSeconds = 1, cameraUtcOffsetMinutes = 120)
    check plan.trackPointCount == 2
    check plan.entries.len == 2
    check plan.entries[0].matched
    # Equal UTC timestamps select the earlier point deterministically.
    check plan.entries[0].latitude == 48.1
    check applyGpxMatch(store, plan).applied == 2
    check store.getItem(items[0].id).latitude.get() == 48.1
    var stalePatch: CurationPatch
    stalePatch.creationDate = some("2026-08-02")
    discard store.curateItem(items[0].id, stalePatch)
    expect ValueError:
      discard applyGpxMatch(store, plan)
    writeFile(root / "unsafe.gpx", "<!DOCTYPE gpx><gpx/>")
    expect ValueError:
      discard parseGpx(root / "unsafe.gpx")
    store.close()
    removeDir(root)

  test "reverse geocoding caches provider results and rejects stale plans":
    let root = fresh("unimedia_reverse_geocode")
    writeFile(root / "photo.ppm", ppm(70))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    var gps: CurationPatch
    gps.latitude = some(43.2965)
    gps.longitude = some(5.3698)
    discard store.curateItem(item.id, gps)
    proc provider(latitude, longitude: float;
                  language: string): ReverseGeocodeResult {.gcsafe.} =
      check latitude == 43.2965
      check longitude == 5.3698
      check language == "fr"
      ReverseGeocodeResult(locationText: "Marseille, France",
        attribution: "Test geocoder data")
    let plan = planReverseGeocode(store, "test-provider", "fr", provider,
      @[item.id])
    check plan.entries.len == 1
    check not plan.entries[0].fromCache
    check applyReverseGeocode(store, plan).applied == 1
    let cachedPlan = planReverseGeocode(store, "test-provider", "fr", nil,
      @[item.id], overwrite = true)
    check cachedPlan.entries[0].fromCache
    check cachedPlan.entries[0].attribution == "Test geocoder data"
    var changed: CurationPatch
    changed.locationText = some("User override")
    discard store.curateItem(item.id, changed)
    expect ValueError:
      discard applyReverseGeocode(store, cachedPlan)
    store.close()
    removeDir(root)

  test "manual albums are deterministic, idempotent, and follow catalog deletion":
    let root = fresh("unimedia_albums")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "first.ppm", ppm(16))
    writeFile(root / "second.ppm", ppm(32))
    var store = openLibrary(root)
    discard scanLibrary(store)
    let items = store.listItems()
    let album = createAlbum(store, "  Summer  ")
    check album.name == "Summer"
    check addAlbumItem(store, album.id, items[0].id)
    check not addAlbumItem(store, album.id, items[0].id)
    check addAlbumItem(store, album.id, items[1].id)
    check getAlbum(store, album.id).itemCount == 2
    check listAlbumItems(store, album.id)[0].relPath == "first.ppm"
    check setAlbumCover(store, album.id, items[1].id).coverItemId == items[1].id
    check clearAlbumCover(store, album.id).coverItemId == 0
    check setAlbumCover(store, album.id, items[1].id).coverItemId == items[1].id
    expect ValueError:
      discard setAlbumCover(store, album.id, 0)
    expect ValueError:
      discard setAlbumCover(store, album.id, 9999)
    expect ValueError:
      discard createAlbum(store, "summer")
    check renameAlbum(store, album.id, "Holiday").name == "Holiday"
    let other = createAlbum(store, "Summer")
    expect ValueError:
      discard renameAlbum(store, other.id, "holiday")
    check removeAlbumItem(store, album.id, items[0].id)
    check not removeAlbumItem(store, album.id, items[0].id)
    removeFile(root / "second.ppm")
    discard scanLibrary(store)
    check getAlbum(store, album.id).itemCount == 0
    check getAlbum(store, album.id).coverItemId == 0
    deleteAlbum(store, other.id)
    expect ValueError:
      discard getAlbum(store, other.id)
    store.close()
    removeDir(root)

  test "smart albums validate rules and evaluate current curation dynamically":
    let root = fresh("unimedia_smart_albums")
    writeFile(root / "summer.ppm", ppm(16))
    writeFile(root / "winter.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    var summerPatch: CurationPatch
    summerPatch.rating = some(5)
    summerPatch.favorite = some(true)
    summerPatch.keywords = some(@["family", "sea"])
    summerPatch.latitude = some(48.8566)
    summerPatch.longitude = some(2.3522)
    summerPatch.locationText = some("Paris")
    discard curateItem(store, items[0].id, summerPatch)
    var winterPatch: CurationPatch
    winterPatch.rating = some(4)
    winterPatch.favorite = some(false)
    winterPatch.keywords = some(@["family", "snow"])
    discard curateItem(store, items[1].id, winterPatch)

    let favorites = createSmartAlbum(store, "Best family", true, @[
      SmartRule(field: "rating", operator: "gte", value: "4"),
      SmartRule(field: "favorite", operator: "eq", value: "true"),
      SmartRule(field: "keyword", operator: "eq", value: "family")])
    check favorites.itemCount == 1
    check listSmartAlbumItems(store, favorites.id)[0].id == items[0].id
    let paris = createSmartAlbum(store, "Paris GPS", true, @[
      SmartRule(field: "location", operator: "contains", value: "paris"),
      SmartRule(field: "gps", operator: "eq", value: "true")])
    check paris.itemCount == 1
    winterPatch.favorite = some(true)
    discard curateItem(store, items[1].id, winterPatch)
    check getSmartAlbum(store, favorites.id).itemCount == 2

    let either = createSmartAlbum(store, "Season", false, @[
      SmartRule(field: "path", operator: "contains", value: "summer"),
      SmartRule(field: "keyword", operator: "eq", value: "snow")])
    check either.itemCount == 2
    check renameSmartAlbum(store, either.id, "Seasons").name == "Seasons"
    expect ValueError:
      discard createAlbum(store, "best family")
    discard createAlbum(store, "Manual")
    expect ValueError:
      discard renameSmartAlbum(store, either.id, "manual")
    expect ValueError:
      discard createSmartAlbum(store, "Invalid", true, @[
        SmartRule(field: "rating", operator: "gte", value: "6")])
    let hostile = createSmartAlbum(store, "Parameterized", true, @[
      SmartRule(field: "path", operator: "contains", value: "%'; DELETE")])
    check hostile.itemCount == 0
    check store.listItems().len == 2
    let withoutSea = createSmartAlbum(store, "Without sea", true, @[
      SmartRule(field: "keyword", operator: "ne", value: "sea")])
    check withoutSea.itemCount == 1
    check listSmartAlbumItems(store, withoutSea.id)[0].id == items[1].id
    deleteSmartAlbum(store, either.id)
    expect ValueError:
      discard getSmartAlbum(store, either.id)
    store.close()
    removeDir(root)

  test "album membership follows an item moved inside the library":
    let root = fresh("unimedia_album_reorg")
    let incoming = root / "incoming"
    discard initLibrary(root, mdPhoto)
    createDir(incoming)
    writeFile(incoming / "IMG_20260731.ppm", ppm(64))
    var store = openLibrary(root)
    discard scanLibrary(store)
    let item = store.listItems()[0]
    let album = createAlbum(store, "Reorganized")
    check addAlbumItem(store, album.id, item.id)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmMove
    let report = applyPlan(store, planOrganize(store, incoming, options))
    check report.failed == 0
    let members = listAlbumItems(store, album.id)
    check members.len == 1
    check members[0].id == item.id
    check members[0].relPath == "2026/07-31/IMG_20260731.ppm"
    var patch: CurationPatch
    patch.favorite = some(true)
    discard curateItem(store, item.id, patch)
    check fileExists(root / "2026/07-31/IMG_20260731.ppm.xmp")
    check applyUndo(store, report.batchId).failed == 0
    let restored = listAlbumItems(store, album.id)
    check restored.len == 1
    check restored[0].id == item.id
    check restored[0].relPath == "incoming/IMG_20260731.ppm"
    check fileExists(incoming / "IMG_20260731.ppm.xmp")
    check not fileExists(root / "2026/07-31/IMG_20260731.ppm.xmp")
    store.close()
    removeDir(root)

  test "soft-deleted items are hidden without losing relationships":
    let root = fresh("unimedia_soft_delete")
    writeFile(root / "IMG_20260731.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    let album = createAlbum(store, "Retained")
    discard addAlbumItem(store, album.id, item.id)
    discard setAlbumCover(store, album.id, item.id)
    var patch: CurationPatch
    patch.keywords = some(@["retained"])
    discard curateItem(store, item.id, patch)
    store.db.exec(sql"UPDATE items SET deleted_at='now' WHERE id=?", item.id)
    check store.listItems().len == 0
    expect ValueError:
      discard store.getItem(item.id)
    check getAlbum(store, album.id).itemCount == 0
    check getAlbum(store, album.id).coverItemId == 0
    check listAlbumItems(store, album.id).len == 0
    check listKeywordFacets(store).len == 0
    discard scanLibrary(store, skipPhash = true)
    check store.getItem(item.id).relPath == "IMG_20260731.ppm"
    check getAlbum(store, album.id).itemCount == 1
    check getAlbum(store, album.id).coverItemId == item.id
    check getItemCuration(store, item.id).keywords == @["retained"]
    store.close()
    removeDir(root)

  test "filename dates accept separated and compact forms":
    check parseFilenameDate("IMG_2026-07-31.jpg") == "2026-07-31 00:00:00"
    check parseFilenameDate("IMG_2026_07_31.jpg") == "2026-07-31 00:00:00"
    check parseFilenameDate("IMG_20260731.jpg") == "2026-07-31 00:00:00"

  test "year and ISO-date scheme plans the documented path":
    let sandbox = fresh("unimedia_year_date_scheme")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "IMG_20260731.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.scheme = osYearDate
    let plan = planOrganize(store, source, options)
    check plan.operations.len == 1
    check plan.operations[0].destRelPath ==
      "2026/2026-07-31/IMG_20260731.ppm"
    store.close()
    removeDir(sandbox)

  test "planning an already copied file is idempotent":
    let sandbox = fresh("unimedia_idempotent")
    let root = sandbox / "library"
    let source = sandbox / "source"
    createDir(source)
    writeFile(source / "IMG_20260731.ppm", ppm(255))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let options = defaultOrganizeOptions(store.library.config)
    discard applyPlan(store, planOrganize(store, source, options))
    let second = planOrganize(store, source, options)
    check second.operations.len == 1
    check second.operations[0].skipReason == "identical"
    store.close()
    removeDir(sandbox)

  test "unknown batches and absent dedup runs are rejected":
    let root = fresh("unimedia_missing_history")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    expect ValueError:
      discard planUndo(store, "does-not-exist")
    expect ValueError:
      discard applyUndo(store, "does-not-exist")
    expect ValueError:
      discard loadDedupRun(store)
    store.close()
    removeDir(root)

  test "an interrupted verified copy is recovered from its journal":
    let sandbox = fresh("unimedia_recover_copy")
    let root = sandbox / "library"
    let source = sandbox / "source.ppm"
    discard initLibrary(root, mdPhoto)
    writeFile(source, ppm(255))
    let destination = root / "2026" / "recovered.ppm"
    createDir(destination.parentDir)
    copyFile(source, destination)
    var store = openLibrary(root)
    let digest = blake3File(source)
    store.db.exec(sql"""
      INSERT INTO batches(id,created_at,source_root,mode,status)
      VALUES('recover-copy','now',?,'copy','applying')""", sandbox)
    store.db.exec(sql"""
      INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
        content_hash,status)
      VALUES('recover-copy',0,'copy',?,'2026/recovered.ppm',?,'pending')""",
      source, digest)
    recoverInterruptedBatches(store)
    check store.db.getValue(sql"SELECT status FROM batch_ops WHERE batch_id='recover-copy'") ==
      "applied"
    check store.db.getValue(sql"SELECT status FROM batches WHERE id='recover-copy'") ==
      "applied"
    store.close()
    removeDir(sandbox)

  test "an interrupted dedup removal is recovered and undoable":
    let root = fresh("unimedia_recover_delete")
    writeFile(root / "duplicate.ppm", ppm(64))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    let source = root / item.relPath
    let destinationRel = ".om-trash/recover-delete/1/duplicate.ppm"
    let destination = root / destinationRel
    createDir(destination.parentDir)
    let digest = blake3File(source)
    moveFile(source, destination)
    store.db.exec(sql"""
      INSERT INTO batches(id,created_at,source_root,mode,status)
      VALUES('recover-delete','now',?,'delete','applying')""", root)
    store.db.exec(sql"""
      INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
        content_hash,status)
      VALUES('recover-delete',0,'delete',?,?,?,'pending')""", source,
      destinationRel, digest)
    recoverInterruptedBatches(store)
    check store.listItems().len == 0
    check store.db.getValue(sql"""
      SELECT status FROM batch_ops WHERE batch_id='recover-delete'""") == "applied"
    check applyUndo(store, "recover-delete").failed == 0
    check store.getItem(item.id).relPath == item.relPath
    check fileExists(source)
    store.close()
    removeDir(root)

  test "an ambiguous interrupted move is preserved and marked partial":
    let sandbox = fresh("unimedia_recover_ambiguous")
    let root = sandbox / "library"
    let source = sandbox / "source.ppm"
    discard initLibrary(root, mdPhoto)
    writeFile(source, ppm(255))
    let destination = root / "2026" / "ambiguous.ppm"
    createDir(destination.parentDir)
    copyFile(source, destination)
    var store = openLibrary(root)
    let digest = blake3File(source)
    store.db.exec(sql"""
      INSERT INTO batches(id,created_at,source_root,mode,status)
      VALUES('recover-move','now',?,'move','applying')""", sandbox)
    store.db.exec(sql"""
      INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
        content_hash,status)
      VALUES('recover-move',0,'move',?,'2026/ambiguous.ppm',?,'pending')""",
      source, digest)
    recoverInterruptedBatches(store)
    check fileExists(source)
    check fileExists(destination)
    check store.db.getValue(sql"SELECT status FROM batch_ops WHERE batch_id='recover-move'") ==
      "failed"
    check store.db.getValue(sql"SELECT status FROM batches WHERE id='recover-move'") ==
      "partial"
    store.close()
    removeDir(sandbox)

  when not defined(windows):
    test "catalog scan ignores symbolic media files":
      let sandbox = fresh("unimedia_scan_symlink")
      let root = sandbox / "library"
      let outside = sandbox / "outside.ppm"
      writeFile(outside, ppm(255))
      discard initLibrary(root, mdPhoto)
      createSymlink(outside, root / "linked.ppm")
      var store = openLibrary(root)
      discard scanLibrary(store)
      check store.listItems().len == 0
      store.close()
      removeDir(sandbox)

    test "organization refuses symlinked destination components":
      let sandbox = fresh("unimedia_symlink_guard")
      let root = sandbox / "library"
      let source = sandbox / "source"
      let outside = sandbox / "outside"
      createDir(source)
      createDir(outside)
      writeFile(source / "IMG_20260731.ppm", ppm(255))
      discard initLibrary(root, mdPhoto)
      createSymlink(outside, root / "2026")
      var store = openLibrary(root)
      expect ValueError:
        discard planOrganize(store, source,
          defaultOrganizeOptions(store.library.config))
      check not fileExists(outside / "07-31" / "IMG_20260731.ppm")
      store.close()
      removeDir(sandbox)

  test "cancelled scan rolls back its transaction":
    let root = fresh("unimedia_cancel_scan")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "one.ppm", ppm(255))
    var store = openLibrary(root)
    expect OperationCancelledError:
      discard scanLibrary(store, cancel = cancelNow)
    check store.countItems() == 0
    store.close()
    removeDir(root)

  test "cancelled duplicate detection leaves no partial run":
    let root = fresh("unimedia_cancel_dedup")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "one.ppm", ppm(255))
    writeFile(root / "two.ppm", ppm(255))
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    expect OperationCancelledError:
      discard findDuplicates(store, dkExact, cancel = cancelNow)
    check store.db.getValue(sql"SELECT count(*) FROM dedup_runs") == "0"
    store.close()
    removeDir(root)

  test "a second thread opens its own store on the same library":
    let root = fresh("unimedia_thread_ownership")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(48))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    check scanLibrary(store, skipPhash = true).indexed == 1
    # The owner keeps its handle open while the worker uses its own.
    var worker: Thread[string]
    createThread(worker, countInOwnStore, root)
    joinThread(worker)
    check workerItemCount == 1
    # The owner's handle is still usable afterwards.
    check store.countItems() == 1
    store.close()
    removeDir(root)

  test "a file-less item survives scanning, audit and curation":
    let root = fresh("unimedia_virtual_item")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(32))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let id = addVirtualItem(store, "book/dune", "book",
      %*{"isbn": "9780441013593"})
    check parseJson(itemMeta(store, id))["isbn"].getStr() == "9780441013593"
    expect ValueError:
      discard addVirtualItem(store, "book/dune", "book")
    # A scan reconciles files against the disk; an item without one is not
    # missing media, so it must survive.
    check scanLibrary(store, skipPhash = true).removed == 0
    check store.listItems().len == 2
    # The audit has no path, size or digest to verify for it.
    let audit = auditIntegrity(store, verifyHashes = false)
    check audit.checked == 1
    check audit.missing == 0
    # Curation still applies, but there is no media to mirror a sidecar next to.
    check curateItem(store, id, CurationPatch(rating: some(5))).rating == 5
    check not fileExists(root / "book" / "dune.xmp")
    store.close()
    removeDir(root)

  test "integrity audit reports hash drift, missing files, and cancellation":
    let root = fresh("unimedia_integrity")
    discard initLibrary(root, mdPhoto)
    writeFile(root / "one.ppm", ppm(32))
    writeFile(root / "two.ppm", ppm(64))
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let clean = auditIntegrity(store)
    check clean.checked == 2
    check clean.findings.len == 0
    writeFile(root / "one.ppm", ppm(31))
    removeFile(root / "two.ppm")
    let drift = auditIntegrity(store)
    check drift.hashMismatches == 1
    check drift.missing == 1
    expect OperationCancelledError:
      discard auditIntegrity(store, cancel = cancelNow)
    store.close()
    removeDir(root)

suite "a duplicate can become a link instead of going to the trash":
  test "identical copies share one inode afterwards, and undo separates them":
    let root = fresh("unimedia_dedup_link")
    createDir(root)
    for name in ["a.ppm", "b.ppm", "c.ppm"]: writeFile(root / name, ppm(7))
    writeFile(root / "other.ppm", ppm(200))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    check scanLibrary(store, skipPhash = true).indexed == 4
    let run = findDuplicates(store, dkExact)

    let pairs = planDedupLinks(store, run)
    check pairs.len == 2
    # Every duplicate points at the one copy that was kept.
    check pairs.allIt(it.keeperId == pairs[0].keeperId)

    let report = applyDedupLinks(store, run)
    check report.linked == 2
    check report.failed == 0
    proc inodeOf(path: string): tuple[device: DeviceId; file: FileId] =
      getFileInfo(path).id
    check inodeOf(root / "b.ppm") == inodeOf(root / "a.ppm")
    check inodeOf(root / "c.ppm") == inodeOf(root / "a.ppm")
    check inodeOf(root / "other.ppm") != inodeOf(root / "a.ppm")
    # The links are not catalogue items: what is there is the kept file.
    check store.listItems().len == 2

    let undone = applyUndo(store, report.batchId)
    check undone.failed == 0
    check inodeOf(root / "b.ppm") != inodeOf(root / "a.ppm")
    check store.listItems().len == 4
    for name in ["a.ppm", "b.ppm", "c.ppm"]:
      check readFile(root / name) == ppm(7)
    store.close()
    removeDir(root)

  test "files a perceptual hash called alike are refused":
    # They are not the same file. Linking them would throw away whichever was
    # not kept, and no similarity score makes that safe.
    let root = fresh("unimedia_dedup_link_visual")
    createDir(root)
    # Same picture, different bytes: a trailing comment changes the file
    # without changing what it shows.
    writeFile(root / "one.ppm", ppm(9))
    writeFile(root / "two.ppm", ppm(9) & "# a comment\n")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = false)
    let run = findDuplicates(store, dkVisual)
    check planDedupLinks(store, run).len == 0
    expect ValueError: discard applyDedupLinks(store, run)
    store.close()
    removeDir(root)

  test "linkDuplicates refuses what it cannot link":
    let root = fresh("unimedia_link_guards")
    createDir(root)
    writeFile(root / "a.ppm", ppm(11))
    writeFile(root / "b.ppm", ppm(11))
    writeFile(root / "c.ppm", ppm(250))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    let a = items[0].id
    let b = items[1].id
    let c = items[2].id
    expect ValueError: discard linkDuplicates(store, @[])
    expect ValueError: discard linkDuplicates(store, @[(a, a)])
    expect ValueError: discard linkDuplicates(store, @[(b, a), (b, a)])
    # c differs from a, so the whole request is refused rather than half done.
    expect ValueError: discard linkDuplicates(store, @[(b, a), (c, a)])
    check store.listItems().len == 3
    store.close()
    removeDir(root)

suite "albums can sit inside one another":
  test "a child reports its parent, and a parent lists its children":
    let root = fresh("unimedia_album_tree")
    createDir(root)
    writeFile(root / "one.ppm", ppm(21))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)

    let trips = createAlbum(store, "Trips")
    let spain = createAlbum(store, "Spain")
    let madrid = createAlbum(store, "Madrid")
    check trips.parentId == 0

    check setAlbumParent(store, spain.id, trips.id).parentId == trips.id
    check setAlbumParent(store, madrid.id, spain.id).parentId == spain.id
    check listChildAlbums(store, 0).mapIt(it.name) == @["Trips"]
    check listChildAlbums(store, trips.id).mapIt(it.name) == @["Spain"]
    check listChildAlbums(store, spain.id).mapIt(it.name) == @["Madrid"]
    check listChildAlbums(store, madrid.id).len == 0

    # An item belongs to the album it was put in, never to that album's parent.
    let item = store.listItems()[0].id
    check addAlbumItem(store, madrid.id, item)
    check getAlbum(store, madrid.id).itemCount == 1
    check getAlbum(store, spain.id).itemCount == 0
    check getAlbum(store, trips.id).itemCount == 0

    # Back to the top.
    check setAlbumParent(store, spain.id, 0).parentId == 0
    check listChildAlbums(store, 0).mapIt(it.name) == @["Spain", "Trips"]
    store.close()
    removeDir(root)

  test "a cycle is refused, however long the chain":
    let root = fresh("unimedia_album_cycle")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let a = createAlbum(store, "A")
    let b = createAlbum(store, "B")
    let c = createAlbum(store, "C")
    expect ValueError: discard setAlbumParent(store, a.id, a.id)
    discard setAlbumParent(store, b.id, a.id)
    discard setAlbumParent(store, c.id, b.id)
    # A into C would close A -> B -> C -> A, which one step of checking misses.
    expect ValueError: discard setAlbumParent(store, a.id, c.id)
    expect ValueError: discard setAlbumParent(store, a.id, b.id)
    # The tree is untouched by a refusal.
    check getAlbum(store, a.id).parentId == 0
    check getAlbum(store, b.id).parentId == a.id
    check getAlbum(store, c.id).parentId == b.id
    expect ValueError: discard setAlbumParent(store, a.id, 9999)
    expect ValueError: discard setAlbumParent(store, 9999, a.id)
    store.close()
    removeDir(root)

  test "deleting a parent lifts its children rather than taking them":
    # An album lists items it does not own, and a parent does not own a child.
    let root = fresh("unimedia_album_orphan")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let parent = createAlbum(store, "Parent")
    let child = createAlbum(store, "Child")
    discard setAlbumParent(store, child.id, parent.id)
    deleteAlbum(store, parent.id)
    check getAlbum(store, child.id).parentId == 0
    check listChildAlbums(store, 0).mapIt(it.name) == @["Child"]
    store.close()
    removeDir(root)



# Three eight-pixel JPEGs, made once with exiftool and kept here rather than
# generated: a test that needs a tool installed tests less on a machine without
# it. One is placed north-east, one south-west, one carries no GPS at all.
const
  PlacedJpegBase64 =
    "/9j/4AAQSkZJRgABAgAAAQABAAD/4QDURXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAAA" &
    "SgEbAAUAAAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIglAAQAAAABAAAAWgAA" &
    "AAAAAAABAAAAAQAAAAEAAAABAAUAAAABAAAABAIDAAAAAQACAAAAAk4AAAAAAgAFAAAA" &
    "AwAAAJwAAwACAAAAAkUAAAAABAAFAAAAAwAAALQAAAAAAAAALQAAAAEAAAA4AAAAAQAB" &
    "BjEAABHTAAAABgAAAAEAAAAmAAAAAQAAB4MAAABk//4AD0xhdmM2My4xLjEwMQD/2wBD" &
    "AAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJ" &
    "CQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABwEBAQAAAAAAAAAAAAAA" &
    "AAAABQcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAIAAgD" &
    "ASIAAhEAAxEA/9oADAMBAAIRAxEAPwCOAL+Kf//Z"
  SouthWestJpegBase64 =
    "/9j/4AAQSkZJRgABAgAAAQABAAD/4QDURXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAAA" &
    "SgEbAAUAAAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIglAAQAAAABAAAAWgAA" &
    "AAAAAAABAAAAAQAAAAEAAAABAAUAAAABAAAABAIDAAAAAQACAAAAAlMAAAAAAgAFAAAA" &
    "AwAAAJwAAwACAAAAAlcAAAAABAAFAAAAAwAAALQAAAAAAAAAIQAAAAEAAAA0AAAAAQAA" &
    "AMAAAAAZAAAAlwAAAAEAAAAMAAAAAQAAA0UAAAAZ//4AD0xhdmM2My4xLjEwMQD/2wBD" &
    "AAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJ" &
    "CQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABwEBAQAAAAAAAAAAAAAA" &
    "AAAABQcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAIAAgD" &
    "ASIAAhEAAxEA/9oADAMBAAIRAxEAPwCOAL+Kf//Z"
  UnplacedJpegBase64 =
    "/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAxAP/bAEMACAQEBAQEBQUF" &
    "BQUFBgYGBgYGBgYGBgYGBgcHBwgICAcHBwYGBwcICAgICQkJCAgICAkJCgoKDAwLCw4O" &
    "DhERFP/EAEwAAQEAAAAAAAAAAAAAAAAAAAAHAQEBAAAAAAAAAAAAAAAAAAAFBxABAAAA" &
    "AAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIAAgACAMBIgACEQADEQD/" &
    "2gAMAwEAAhEDEQA/AI4Av4p//9k="

proc writeJpeg(path, encoded: string) =
  writeFile(path, decode(encoded))

suite "a scan reads where a file says it was taken":
  test "coordinates come out of the file, and curation is never overwritten":
    # Until the scan read them, the only way coordinates reached a catalogue
    # was a GPS track matched by hand or somebody typing them, so a library of
    # geotagged photographs reported no places at all.
    let root = fresh("unimedia_scan_gps")
    createDir(root)
    writeJpeg(root / "placed.jpg", PlacedJpegBase64)
    writeJpeg(root / "bare.jpg", UnplacedJpegBase64)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    check scanLibrary(store, skipPhash = true).indexed == 2

    var placed, bare: Item
    for item in store.listItems():
      if item.relPath == "placed.jpg": placed = item else: bare = item
    check placed.latitude.isSome
    check placed.longitude.isSome
    check abs(placed.latitude.get() - 45.9374194) < 1e-4
    check abs(placed.longitude.get() - 6.6386750) < 1e-4
    # A file carrying none stays without, rather than gaining a zero that
    # would place it in the Atlantic off Africa.
    check bare.latitude.isNone
    check bare.longitude.isNone

    # What somebody corrected survives the next scan.
    discard curateItem(store, placed.id, CurationPatch(
      latitude: some(48.8584), longitude: some(2.2945)))
    discard scanLibrary(store, skipPhash = true)
    for item in store.listItems():
      if item.relPath == "placed.jpg":
        check abs(item.latitude.get() - 48.8584) < 1e-4
    store.close()
    removeDir(root)

  test "the reference letters make the sign, not a negative number":
    # EXIF stores a latitude as a positive number and an S, so a file read
    # without its reference letter lands in the wrong hemisphere.
    let root = fresh("unimedia_scan_gps_sw")
    createDir(root)
    writeJpeg(root / "sydney.jpg", SouthWestJpegBase64)
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    check item.latitude.get() < 0.0
    check item.longitude.get() < 0.0
    check abs(item.latitude.get() + 33.8688) < 1e-3
    check abs(item.longitude.get() + 151.2093) < 1e-3
    store.close()
    removeDir(root)

  test "a file that is not there carries nothing, and does not raise":
    check not mediaCoordinates(getTempDir() / "unimedia-no-such-file").found


suite "a video says where it was made too":
  test "the scan reads a recording's own position, not only a photograph's":
    # A camera roll is Live Photos: a still and a clip sharing a name and a
    # place. The still keeps it in EXIF and the clip in an ISO 6709 string of
    # its own, so reading one of the two leaves half the library unplaced.
    let root = fresh("unimedia_video_gps")
    createDir(root)
    copyFile(currentSourcePath.parentDir / "fixtures" / "located.mov",
      root / "clip.mov")
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    check scanLibrary(store, skipPhash = true).indexed == 1
    let item = store.listItems()[0]
    check item.latitude.isSome
    check abs(item.latitude.get() - 45.9374) < 1e-3
    check abs(item.longitude.get() - 6.6387) < 1e-3
    store.close()
    removeDir(root)

  test "a recording with no position stays without one":
    let root = fresh("unimedia_video_nogps")
    createDir(root)
    copyFile(currentSourcePath.parentDir / "fixtures" / "unplaced.mp4",
      root / "clip.mp4")
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    check store.listItems()[0].latitude.isNone
    store.close()
    removeDir(root)

suite "the catalogue keeps out of sight":
  test "a library written under the visible name is renamed on the next open":
    # Two files used to sit among somebody's photographs. The configuration was
    # already hidden; the catalogue and its WAL files were not.
    let root = fresh("unimedia_hide_db")
    createDir(root)
    writeFile(root / "one.ppm", ppm(31))
    discard initLibrary(root, mdPhoto)
    block:
      var store = openLibrary(root)
      discard scanLibrary(store, skipPhash = true)
      store.close()
    # Put it back the way an older build left it.
    moveFile(root / DatabaseName, root / LegacyDatabaseName)
    check fileExists(root / LegacyDatabaseName)
    check not fileExists(root / DatabaseName)
    # It is still recognised as a library, rather than reported as none.
    check libraryExists(root)
    block:
      var store = openLibrary(root)
      check store.listItems().len == 1
      store.close()
    check fileExists(root / DatabaseName)
    check not fileExists(root / LegacyDatabaseName)
    removeDir(root)

  test "two catalogues in one folder are left alone":
    # Somebody's mistake to look at, not one to resolve by picking.
    let root = fresh("unimedia_two_dbs")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    block:
      var store = openLibrary(root)
      store.close()
    writeFile(root / LegacyDatabaseName, "not a database")
    block:
      var store = openLibrary(root)
      store.close()
    check fileExists(root / LegacyDatabaseName)
    check readFile(root / LegacyDatabaseName) == "not a database"
    removeDir(root)

  test "the catalogue is never catalogued":
    let root = fresh("unimedia_skip_own_files")
    createDir(root)
    writeFile(root / "one.ppm", ppm(41))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    check scanLibrary(store, skipPhash = true).indexed == 1
    # The database, its WAL files and the configuration are the library's own.
    check store.listItems().len == 1
    store.close()
    removeDir(root)

suite "a privacy audit that misses a video says nothing, which reads as safe":
  test "a recording's position is reported, and the strip passes it over":
    let root = fresh("unimedia_privacy_video")
    createDir(root)
    copyFile(currentSourcePath.parentDir / "fixtures" / "located.mov",
      root / "clip.mov")
    writeFile(root / "plain.ppm", ppm(64))
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)

    let findings = privacyAudit(store)
    let clip = findings.filterIt(it.relPath == "clip.mov")
    check clip.len == 1
    check "gps" in clip[0].signals
    # It is not unreadable — it was read, by the reader that knows the format.
    check clip[0].error.len == 0

    # The plan carries it so somebody knows, and marks that stripping cannot
    # rewrite it.
    let plan = planPrivacyStrip(store)
    let planned = plan.entries.filterIt(it.relPath == "clip.mov")
    check planned.len == 1
    check not planned[0].strippable
    store.close()
    removeDir(root)

  test "which containers can be rewritten is measured, not assumed":
    # TIFF looks like it belongs and does not; HEIC looks like it does not and
    # does. A camera roll is mostly HEIC, so this one matters.
    check canStrip("a.heic")
    check canStrip("a.HEIC")
    check canStrip("a.jpg")
    check canStrip("a.png")
    check canStrip("a.avif")
    check not canStrip("a.tif")
    check not canStrip("a.tiff")
    check not canStrip("a.mov")
    check not canStrip("a")

  test "a plan of nothing rewritable says so rather than reporting success":
    let root = fresh("unimedia_privacy_only_video")
    createDir(root)
    copyFile(currentSourcePath.parentDir / "fixtures" / "located.mov",
      root / "clip.mov")
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let plan = planPrivacyStrip(store)
    check plan.entries.len == 1
    expect ValueError: discard applyPrivacyStrip(store, plan)
    store.close()
    removeDir(root)

suite "a track must not undo a position the camera already recorded":
  test "an item that carries one is kept, and said to be kept":
    let root = fresh("unimedia_gpx_keep")
    createDir(root)
    writeFile(root / "shot.ppm", ppm(20))
    let track = root.parentDir / "keep.gpx"
    writeFile(track, """<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
<trkpt lat="48.8566" lon="2.3522"><time>2026-01-01T12:00:00Z</time></trkpt>
</trkseg></trk></gpx>""")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let id = store.listItems()[0].id
    var when1: CurationPatch
    when1.creationDate = some("2026-01-01 12:00:00")
    discard store.curateItem(id, when1)

    let first = planGpxMatch(store, track)
    check first.entries[0].matched
    check not first.entries[0].alreadyPlaced
    discard applyGpxMatch(store, first)

    # Planned again, the track is not consulted for it.
    let second = planGpxMatch(store, track)
    check second.entries.len == 1 # reported, not dropped
    check second.entries[0].alreadyPlaced
    check not second.entries[0].matched
    # And the refusal names the real reason, so nobody widens the tolerance
    # looking for a match that was never sought.
    expect ValueError: discard applyGpxMatch(store, second)

    let forced = planGpxMatch(store, track, refresh = true)
    check forced.refreshed
    check forced.entries[0].matched
    check forced.entries[0].alreadyPlaced # true, and placed anyway
    store.close()
    removeFile(track)
    removeDir(root)

  test "a refresh can name the items it applies to":
    let root = fresh("unimedia_gpx_refresh_some")
    createDir(root)
    writeFile(root / "a.ppm", ppm(30))
    writeFile(root / "b.ppm", ppm(60))
    let track = root.parentDir / "some.gpx"
    writeFile(track, """<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
<trkpt lat="45.7640" lon="4.8357"><time>2026-01-01T12:00:00Z</time></trkpt>
</trkseg></trk></gpx>""")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    for item in store.listItems():
      var stamp: CurationPatch
      stamp.creationDate = some("2026-01-01 12:00:00")
      discard store.curateItem(item.id, stamp)
    discard applyGpxMatch(store, planGpxMatch(store, track))

    let chosen = store.listItems()[0].id
    let plan = planGpxMatch(store, track, @[chosen], refresh = true)
    check plan.entries.len == 1
    check plan.entries[0].itemId == chosen
    check plan.entries[0].matched
    store.close()
    removeFile(track)
    removeDir(root)

suite "a date taken from the filesystem dates the copy, not the photograph":
  test "a file with nothing better is undated rather than dated wrongly":
    let root = fresh("unimedia_birthtime")
    createDir(root)
    # No metadata, and a name that carries no date either.
    writeFile(root / "holiday.ppm", ppm(40))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    check not store.library.config.birthtimeDate # the default
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    check item.creationDate.len == 0
    check item.dateSource.len == 0
    store.close()
    removeDir(root)

  test "accepting it is a choice the library records":
    let root = fresh("unimedia_birthtime_on")
    createDir(root)
    writeFile(root / "holiday.ppm", ppm(41))
    discard initLibrary(root, mdPhoto)
    var config = readConfig(root)
    config.birthtimeDate = true
    writeConfig(root, config)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    check item.dateSource == "birthtime"
    check item.creationDate.len > 0
    store.close()
    removeDir(root)

  test "a name that carries a date still wins over the filesystem":
    let root = fresh("unimedia_birthtime_name")
    createDir(root)
    writeFile(root / "20090329_011303.ppm", ppm(42))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]
    check item.dateSource == "filename"
    check item.creationDate.startsWith("2009-03-29")
    store.close()
    removeDir(root)

suite "correcting a date reaches the file, not only the catalogue":
  test "a recording's own header is rewritten, and undo restores it":
    let root = fresh("unimedia_date_file")
    createDir(root)
    let clip = root / "clip.mov"
    copyFile(currentSourcePath.parentDir / "fixtures" / "unplaced.mp4", clip)
    let before = readFile(clip)
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]

    let plan = planDateSet(store, @[item.id], "2019-08-14 10:30:00")
    check plan.entries[0].writesFile
    let report = applyDateEdit(store, plan)
    check report.applied == 1
    check report.written == 1
    check report.batchId.len > 0
    # The file itself changed: a catalogue-only correction leaves every other
    # program reading the date the camera got wrong.
    check readFile(clip) != before
    check movieCreationDate(clip).moment.year == 2019

    discard applyUndo(store, report.batchId)
    check readFile(clip) == before
    store.close()
    removeDir(root)

  test "a container with no writer is corrected in the catalogue and says so":
    let root = fresh("unimedia_date_nofile")
    createDir(root)
    writeFile(root / "plain.ppm", ppm(50))
    discard initLibrary(root, mdVisual)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let item = store.listItems()[0]

    let plan = planDateSet(store, @[item.id], "2019-08-14 10:30:00")
    check not plan.entries[0].writesFile
    let report = applyDateEdit(store, plan)
    check report.applied == 1
    # Counted apart: nothing was written, so no other program will see it.
    check report.written == 0
    check report.batchId.len == 0
    check store.getItem(item.id).creationDate == "2019-08-14 10:30:00"
    store.close()
    removeDir(root)

  test "which containers can be written is stated, not guessed at":
    check canWriteDate("a.jpg")
    check canWriteDate("a.HEIC")
    check canWriteDate("a.mov")
    check canWriteDate("a.mp4")
    check not canWriteDate("a.ppm")
    check not canWriteDate("a.mkv")
    check not canWriteDate("a")

suite "linking refuses a filesystem that has no hard links":
  test "the probe passes where they work, so the check costs nothing here":
    # The negative case needs a filesystem without them — a network share or
    # exFAT — which a unit test cannot conjure. What is testable is that the
    # probe accepts an ordinary directory and leaves nothing behind.
    let root = fresh("unimedia_linkprobe")
    createDir(root)
    requireHardlinkSupport(root)
    var left: seq[string]
    for kind, path in walkDir(root):
      left.add path.extractFilename
    check left.len == 0
    removeDir(root)

  test "a library on such a filesystem still removes duplicates":
    # Removal is the alternative the refusal names, and it frees the same
    # space; it must not depend on links.
    let root = fresh("unimedia_dedup_noremove")
    createDir(root)
    writeFile(root / "a.ppm", ppm(70))
    writeFile(root / "b.ppm", ppm(70))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let run = findDuplicates(store, dkExact)
    let report = applyDedupRemoval(store, run)
    check report.applied == 1
    store.close()
    removeDir(root)

suite "importing twice the same file copies it once":
  test "a duplicate earlier in the same plan is skipped, not suffixed":
    # It was skipped only against what a previous run had already imported, so
    # the same two files behaved differently depending on the order somebody
    # happened to import them in.
    let root = fresh("unimedia_import_dupe")
    let src = root & "-src"
    createDir(root)
    createDir(src / "a")
    createDir(src / "b")
    writeFile(src / "a" / "shot.ppm", ppm(80))
    writeFile(src / "b" / "shot.ppm", ppm(80)) # identical, same name
    writeFile(src / "b" / "other.ppm", ppm(80)) # identical, different name
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    let plan = planOrganize(store, src, options)

    let copies = plan.operations.filterIt(it.skipReason.len == 0)
    let skipped = plan.operations.filterIt(it.skipReason == "identical")
    check skipped.len == 1
    # Two copies, not three: the same name and the same bytes is one file. The
    # differently named twin is still copied — matching content under another
    # name is what `dedup` is for, and finding it would mean hashing every
    # source before planning.
    check copies.len == 2
    store.close()
    removeDir(root)
    removeDir(src)

  test "keepDuplicates copies every one, suffixed":
    # For somebody who wants each copy kept rather than reconciled. Off by
    # default: the same bytes under the same name are one file.
    let root = fresh("unimedia_import_keep")
    let src = root & "-src"
    createDir(root)
    createDir(src / "a")
    createDir(src / "b")
    writeFile(src / "a" / "shot.ppm", ppm(81))
    writeFile(src / "b" / "shot.ppm", ppm(81))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    check not options.keepDuplicates # the default
    options.mode = tmCopy
    options.keepDuplicates = true
    let plan = planOrganize(store, src, options)
    check plan.operations.filterIt(it.skipReason == "identical").len == 0
    check plan.operations.filterIt(it.skipReason.len == 0).len == 2
    # The second lands beside the first rather than over it.
    let dests = plan.operations.mapIt(it.destRelPath)
    check dests.anyIt(it.contains("shot_1"))
    store.close()
    removeDir(root)
    removeDir(src)

suite "an import takes in what the catalogue would index, and nothing else":
  test "a hidden file is not a photograph, whatever its name ends in":
    # macOS writes `._IMG_1234.HEIC` beside every picture on a network share to
    # hold its resource fork. That name ends in .HEIC, so an importer filtering
    # by extension alone files it as a photograph — 44299 of them on a real
    # share. The scan has always skipped hidden files; both halves of one
    # library must agree on what a file is.
    let root = fresh("unimedia_import_hidden")
    let src = root & "-src"
    createDir(root)
    createDir(src)
    createDir(src / ".hidden")
    writeFile(src / "shot.ppm", ppm(90))
    writeFile(src / "._shot.ppm", ppm(91))
    writeFile(src / ".hidden" / "other.ppm", ppm(92))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    let plan = planOrganize(store, src, options)
    check plan.operations.len == 1
    check plan.operations[0].sourcePath.endsWith("shot.ppm")
    check not plan.operations[0].sourcePath.contains("._")
    store.close()
    removeDir(root)
    removeDir(src)

suite "an undo reconciles its own batch, not the whole library":
  test "a restored file is re-read and the rest is left alone":
    let root = fresh("unimedia_undo_narrow")
    createDir(root)
    for index in 0 ..< 6:
      writeFile(root / ("keep" & $index & ".ppm"), ppm(index * 7))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let before = store.listItems().len
    check before == 6

    # Remove one, then put it back.
    let victim = store.listItems()[0]
    let batch = trashItems(store, @[victim.id])
    check store.listItems().len == before - 1
    discard applyUndo(store, batch.batchId)

    # The one that came back is listed again, and nothing else moved.
    check store.listItems().len == before
    check store.listItems().anyIt(it.relPath == victim.relPath)
    # Untouched files keep the hash the first scan gave them: a narrowed
    # reconciliation must not mark the library pending.
    check store.db.getValue(sql"""
      SELECT count(*) FROM items WHERE hash_status<>'hashed'""").parseInt() == 0
    store.close()
    removeDir(root)

  test "reindexPaths ignores a path outside the library rather than failing":
    let root = fresh("unimedia_reindex_outside")
    createDir(root)
    writeFile(root / "a.ppm", ppm(60))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    # An undo that restored some files and not others still reconciles the ones
    # it did, so a stray path is passed over rather than raising.
    let report = reindexPaths(store, @[root / "a.ppm", "/nowhere/b.ppm"])
    check report.removed == 0
    check store.listItems().len == 1
    store.close()
    removeDir(root)

suite "cleanup takes away litter, and only what it can prove is litter":
  proc appleDouble(attribute: string): string =
    ## A minimal AppleDouble carrying one named attribute and nothing else.
    ##
    ## Built rather than copied: the decision rests on the attribute's name, so
    ## a test has to choose that name. Hex escapes throughout — Nim reads `\26`
    ## as decimal, and the magic wants 0x16.
    var attrs = "ATTR" & newString(32) # header, 36 bytes
    attrs[34] = '\x00'
    attrs[35] = '\x01' # one attribute
    attrs.add "\x00\x00\x00\x00" # offset
    attrs.add "\x00\x00\x00\x00" # length
    attrs.add "\x00\x00" # flags
    attrs.add char(attribute.len)
    attrs.add attribute
    let entry9 = newString(32) & "\x00\x00" & attrs # Finder info, then ATTR
    result = "\x00\x05\x16\x07" & "\x00\x02\x00\x00" & newString(16) &
      "\x00\x01"
    let offset = result.len + 12
    result.add "\x00\x00\x00\x09" # entry id 9
    for shift in [24, 16, 8, 0]:
      result.add char((offset shr shift) and 0xFF)
    for shift in [24, 16, 8, 0]:
      result.add char((entry9.len shr shift) and 0xFF)
    result.add entry9

  test "an AppleDouble holding only a marker goes; one holding a tag stays":
    let root = fresh("unimedia_cleanup_appledouble")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(30))
    writeFile(root / "._plain.ppm", appleDouble("com.apple.provenance"))
    writeFile(root / "._tagged.ppm",
      appleDouble("com.apple.metadata:_kMDItemUserTags"))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let plan = planCleanup(store, [ckAppleDouble].toHashSet())
    check plan.entries.len == 2
    let plain = plan.entries.filterIt(it.relPath.contains("plain"))[0]
    let tagged = plan.entries.filterIt(it.relPath.contains("tagged"))[0]
    check plain.removable
    # Reported, not proposed: that file is where the tag lives when the
    # filesystem cannot hold it beside the photograph.
    check not tagged.removable
    check tagged.reason.contains("_kMDItemUserTags")
    store.close()
    removeDir(root)

  test "a sidecar beside its media is not an orphan":
    let root = fresh("unimedia_cleanup_sidecar")
    createDir(root)
    writeFile(root / "kept.ppm", ppm(31))
    writeFile(root / "kept.xmp", "<x/>")
    writeFile(root / "gone.xmp", "<x/>")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let plan = planCleanup(store, [ckOrphanSidecar].toHashSet())
    check plan.entries.len == 1
    check plan.entries[0].relPath == "gone.xmp"
    store.close()
    removeDir(root)

  test "what it takes is journalled, so undo brings it back":
    let root = fresh("unimedia_cleanup_undo")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(32))
    writeFile(root / ".DS_Store", "x")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let report = applyCleanup(store, planCleanup(store, [ckOsJunk].toHashSet()))
    check report.applied == 1
    check not fileExists(root / ".DS_Store")
    discard applyUndo(store, report.batchId)
    check fileExists(root / ".DS_Store")
    store.close()
    removeDir(root)

  test "the trash is never a candidate, whatever it holds":
    # It is what makes everything else undoable; cleaning it would take the way
    # back with it.
    let root = fresh("unimedia_cleanup_trash")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(33))
    createDir(root / TrashDirName / "batch_x")
    writeFile(root / TrashDirName / "batch_x" / ".DS_Store", "x")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let plan = planCleanup(store)
    check not plan.entries.anyIt(it.relPath.contains(TrashDirName))
    store.close()
    removeDir(root)

  test "a plan of nothing removable is refused rather than reported as done":
    let root = fresh("unimedia_cleanup_nothing")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(34))
    writeFile(root / "._tagged.ppm",
      appleDouble("com.apple.metadata:_kMDItemUserTags"))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let plan = planCleanup(store, [ckAppleDouble].toHashSet())
    check plan.entries.len == 1
    expect ValueError: discard applyCleanup(store, plan)
    check fileExists(root / "._tagged.ppm")
    store.close()
    removeDir(root)

suite "a sidecar travels with the picture it describes":
  test "an Apple edit file is carried, and keeps its own extension":
    # `.aae` holds a crop or a filter, and the picture beside it is the
    # unedited original — a copy that left it behind would quietly discard the
    # edit. Renaming it to .xmp would be as bad: nothing reads it there.
    let root = fresh("unimedia_sidecar_aae")
    let src = root & "-src"
    createDir(root)
    createDir(src)
    writeFile(src / "20260814_120000.ppm", ppm(45))
    writeFile(src / "20260814_120000.aae", "<plist/>")
    writeFile(src / "20260814_120000.ppm.xmp", "<x/>")
    writeFile(src / "20260814_120000.thm", "thumb")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    let plan = planOrganize(store, src, options)
    let destinations = plan.operations.mapIt(it.destRelPath)
    check destinations.anyIt(it.endsWith(".aae"))
    check destinations.anyIt(it.endsWith(".thm"))
    check destinations.anyIt(it.endsWith(".ppm.xmp"))
    # Four operations, not one: the picture and its three companions.
    check plan.operations.len == 4
    store.close()
    removeDir(root)
    removeDir(src)

  test "a second run carries a sidecar the first one did not have":
    # The picture is already filed; its edit file arrived later. A run that
    # only looked at sidecars of files it was copying would never take it.
    let root = fresh("unimedia_sidecar_catchup")
    let src = root & "-src"
    createDir(root)
    createDir(src)
    writeFile(src / "20260814_120000.ppm", ppm(46))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    discard applyPlan(store, planOrganize(store, src, options))

    writeFile(src / "20260814_120000.aae", "<plist/>")
    let second = planOrganize(store, src, options)
    check second.operations.filterIt(it.skipReason == "identical").len == 1
    let carried = second.operations.filterIt(it.skipReason.len == 0)
    check carried.len == 1
    check carried[0].destRelPath.endsWith(".aae")
    store.close()
    removeDir(root)
    removeDir(src)

suite "the preferences a library keeps are reachable from the command line":
  test "a value the config would reject is refused before it is written":
    let root = fresh("unimedia_cli_config")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    let before = readConfig(root)
    check before.onConflict == cpSuffix
    # The same readers the file uses, so nothing invalid reaches the disk.
    expect ValueError: discard parseConflict("nonsense")
    check readConfig(root).onConflict == cpSuffix
    removeDir(root)

  test "every settable preference survives a round trip":
    let root = fresh("unimedia_cli_config_roundtrip")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    var config = readConfig(root)
    config.birthtimeDate = true
    config.scheme = osYearMonthDay
    config.noDateDir = "_undated"
    writeConfig(root, config)
    let read = readConfig(root)
    check read.birthtimeDate
    check read.scheme == osYearMonthDay
    check read.noDateDir == "_undated"
    removeDir(root)

  test "an identical sidecar is skipped like its picture, not suffixed":
    # A folder holding its own backup filed one picture and two identical edit
    # files, the second suffixed — 704 of them on a real import. The name
    # collision was avoided; the content was never compared.
    let root = fresh("unimedia_sidecar_dupe")
    let src = root & "-src"
    createDir(root)
    createDir(src / "a")
    createDir(src / "b")
    for side in ["a", "b"]:
      writeFile(src / side / "20260814_120000.ppm", ppm(47))
      writeFile(src / side / "20260814_120000.aae", "<plist/>")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    var options = defaultOrganizeOptions(store.library.config)
    options.mode = tmCopy
    let plan = planOrganize(store, src, options)
    check plan.operations.filterIt(it.skipReason == "identical").len == 2
    check plan.operations.filterIt(it.skipReason.len == 0).len == 2
    # Ends with, not contains: the stem itself holds "_120000".
    check not plan.operations.anyIt(it.destRelPath.endsWith("_1.ppm") or
      it.destRelPath.endsWith("_1.aae"))

    # Asked to keep every copy, both arrive and the second is suffixed.
    options.keepDuplicates = true
    let kept = planOrganize(store, src, options)
    check kept.operations.filterIt(it.skipReason == "identical").len == 0
    check kept.operations.anyIt(it.destRelPath.endsWith("_1.aae"))
    store.close()
    removeDir(root)
    removeDir(src)

  test "every file in a crowded directory is examined, not half of them":
    # The orphan test used to walk the directory it was called from inside the
    # plan's own walk of that directory. The outer walk lost its place: a
    # folder of 382 files was seen as 197, and most of its orphans were never
    # found. One walk, then classification, is what fixes it.
    let root = fresh("unimedia_cleanup_crowded")
    createDir(root)
    discard initLibrary(root, mdPhoto)
    const Pairs = 120
    for index in 0 ..< Pairs:
      writeFile(root / ("kept" & $index & ".ppm"), ppm(index mod 200))
      writeFile(root / ("kept" & $index & ".xmp"), "<x/>")
      writeFile(root / ("gone" & $index & ".xmp"), "<x/>")
    var store = openLibrary(root)
    let plan = planCleanup(store, [ckOrphanSidecar].toHashSet())
    # Every orphan, and not one sidecar whose picture is beside it.
    check plan.entries.len == Pairs
    check plan.entries.allIt(it.relPath.startsWith("gone"))
    store.close()
    removeDir(root)

suite "the trash can be read, and emptying it ends the way back":
  test "a batch is listed with what it holds, then stops being undoable":
    let root = fresh("unimedia_trash_list")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(55))
    writeFile(root / ".DS_Store", "x")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let report = applyCleanup(store, planCleanup(store, [ckOsJunk].toHashSet()))

    let listed = listTrash(store)
    check listed.len == 1
    check listed[0].batchId == report.batchId
    check listed[0].fileCount == 1
    check listed[0].undoable

    let emptied = emptyTrash(store)
    check emptied.batches == 1
    check emptied.files == 1
    # Named, not discovered: undo must refuse once rather than fail per file.
    expect ValueError: discard applyUndo(store, report.batchId)
    check not listTrash(store)[0].undoable
    check listTrash(store)[0].status == $bsEmptied
    store.close()
    removeDir(root)

  test "emptying nothing is refused rather than reported as done":
    let root = fresh("unimedia_trash_none")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(56))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    expect ValueError: discard emptyTrash(store)
    store.close()
    removeDir(root)

  test "a batch younger than the cut-off is left alone":
    let root = fresh("unimedia_trash_age")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(57))
    writeFile(root / ".DS_Store", "x")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard applyCleanup(store, planCleanup(store, [ckOsJunk].toHashSet()))
    check planEmptyTrash(store, @[], 30).len == 0 # made moments ago
    check planEmptyTrash(store, @[], 0).len == 1
    store.close()
    removeDir(root)

suite "deleting outright keeps nothing, and says so":
  test "cleanup --permanently leaves no batch to undo":
    let root = fresh("unimedia_perm_cleanup")
    createDir(root)
    writeFile(root / "photo.ppm", ppm(58))
    writeFile(root / ".DS_Store", "x")
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    let report = applyCleanup(store, planCleanup(store, [ckOsJunk].toHashSet()),
      permanently = true)
    check report.applied == 1
    check not fileExists(root / ".DS_Store")
    # No identifier: handing one back would read as a way that does not exist.
    check report.batchId.len == 0
    check listTrash(store).len == 0
    store.close()
    removeDir(root)

  test "removing an item outright checks every file before deleting any":
    let root = fresh("unimedia_perm_items")
    createDir(root)
    writeFile(root / "a.ppm", ppm(59))
    writeFile(root / "b.ppm", ppm(60))
    discard initLibrary(root, mdPhoto)
    var store = openLibrary(root)
    discard scanLibrary(store, skipPhash = true)
    let items = store.listItems()
    # A missing file refuses the whole request, as the journalled path does.
    removeFile(root / items[0].relPath)
    expect IOError:
      discard trashItems(store, @[items[0].id, items[1].id], permanently = true)
    check fileExists(root / items[1].relPath)
    store.close()
    removeDir(root)
