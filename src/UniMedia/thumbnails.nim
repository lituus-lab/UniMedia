# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Deterministic, local thumbnail cache for catalogue and Studio consumers.

import std/[math, os, strutils, times]
import db_connector/db_sqlite
import UniImage
import UniMedia/[store, types, external_media]

const
  ThumbnailCacheDir* = ".om-cache" / "thumbnails"
  ThumbnailAlgorithmVersion = "v2"
  MinThumbnailEdge* = 16
  MaxThumbnailEdge* = 4096

proc checkedCacheDir(store: Store; digest: string): string =
  let base = store.library.root / ".om-cache"
  let thumbnails = store.library.root / ThumbnailCacheDir
  result = thumbnails / digest[0 .. 1]
  for directory in [base, thumbnails, result]:
    if symlinkExists(directory):
      raise newException(ValueError,
        "thumbnail cache directory must not be a symbolic link: " & directory)
    if not dirExists(directory): createDir(directory)
  discard checkedPathUnder(store.library.root, result)

proc dimensions(width, height, maxEdge: int): tuple[width, height: int] =
  if width <= maxEdge and height <= maxEdge: return (width, height)
  let scale = float(maxEdge) / float(max(width, height))
  result.width = max(1, int(round(float(width) * scale)))
  result.height = max(1, int(round(float(height) * scale)))

proc readBytes(path: string): seq[byte] =
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc writeAtomically(path: string; data: openArray[byte]) =
  let temporary = path & ".tmp-" & $getCurrentProcessId() & "-" &
    $int64(epochTime() * 1_000_000_000.0)
  try:
    var output = open(temporary, fmWrite)
    try:
      if data.len > 0:
        let written = output.writeBuffer(unsafeAddr data[0], data.len)
        if written != data.len:
          raise newException(IOError, "short thumbnail cache write")
      output.flushFile()
    finally:
      output.close()
    try:
      moveFile(temporary, path)
    except OSError:
      if not fileExists(path): raise
  finally:
    if fileExists(temporary): removeFile(temporary)

proc decodedSource(path, category, extension: string;
                   maxEdge: int): tuple[image: Image[uint8]; width, height: int] =
  if category == "video":
    let info = probeMedia(path)
    let seek = if info.durationSeconds > 0:
      min(30.0, info.durationSeconds * 0.1) else: 0.0
    result.image = decodeMediaFrame(path, maxEdge, seek)
    result.width = info.width
    result.height = info.height
    return
  let raw = readBytes(path)
  try:
    result.image = decodeImage(raw)
    let metadata = readMetadataFromBytes(raw)
    let orientation = if metadata.orientation in 1..8:
      metadata.orientation else: 1
    result.image = result.image.applyExifOrientation(orientation)
    result.width = result.image.width
    result.height = result.image.height
  except UniImageException:
    if extension notin ["avif", "heic", "heif"]: raise
    # A still in an ISO base media container, which this build cannot decode —
    # so ffmpeg produces the pixels and UniImage's HEIF reader gives the source
    # size. Not `probeMedia`: that reads a *movie*, and one of these has no
    # `moov` for it to find.
    let still = readHeifFile(path)
    result.image = decodeMediaFrame(path, maxEdge)
    result.width = still.width
    result.height = still.height

proc ensureThumbnail*(store: Store; itemId: int64;
                      maxEdge = 256): Thumbnail =
  ## Return a display-oriented PNG thumbnail, generating it on cache miss.
  ## The catalogue must be rescanned if the source size or mtime changed.
  if maxEdge notin MinThumbnailEdge .. MaxThumbnailEdge:
    raise newException(ValueError, "thumbnail edge must be between " &
      $MinThumbnailEdge & " and " & $MaxThumbnailEdge)
  let item = store.getItem(itemId)
  if item.category notin ["image", "video"]:
    raise newException(ValueError,
      "catalog item cannot produce a visual thumbnail: " & $itemId)
  let source = store.absoluteItemPath(item.relPath)
  if not fileExists(source):
    raise newException(IOError, "catalog item is missing: " & item.relPath)
  let info = getFileInfo(source)
  let mtimeNs = int64(info.lastWriteTime.toUnixFloat() * 1_000_000_000.0)
  if info.size != item.fileSize or mtimeNs != item.mtimeNs:
    raise newException(ValueError, "catalog item changed; rescan before thumbnailing: " &
      item.relPath)
  let digest = store.db.getValue(sql"""
    SELECT h.blake3 FROM item_hashes h JOIN items i ON i.id=h.item_id
    WHERE i.id=? AND i.deleted_at IS NULL AND i.hash_status='hashed'""", itemId)
  if digest.len != 64 or not digest.allCharsInSet(HexDigits):
    raise newException(ValueError, "catalog item has no valid content hash: " & $itemId)
  let directory = checkedCacheDir(store, digest)
  let path = directory / (digest.toLowerAscii() & "-" &
    ThumbnailAlgorithmVersion & "-" & $maxEdge & ".png")
  result = Thumbnail(itemId: itemId, path: path, maxEdge: maxEdge)
  if symlinkExists(path):
    raise newException(ValueError,
      "thumbnail cache entry must not be a symbolic link: " & path)
  if fileExists(path):
    try:
      let cached = decodeImage(readBytes(path))
      if max(cached.width, cached.height) <= maxEdge:
        if item.width <= 0 or item.height <= 0:
          let original = decodedSource(source, item.category, item.extension,
            maxEdge)
          store.db.exec(sql"UPDATE items SET width=?,height=? WHERE id=?",
            original.width, original.height, itemId)
        result.width = cached.width
        result.height = cached.height
        result.cacheHit = true
        return
    except UniImageException:
      discard
  let decoded = decodedSource(source, item.category, item.extension, maxEdge)
  var image = decoded.image
  if item.width != decoded.width or item.height != decoded.height:
    store.db.exec(sql"UPDATE items SET width=?,height=? WHERE id=?",
      decoded.width, decoded.height, itemId)
  let target = dimensions(image.width, image.height, maxEdge)
  if target != (image.width, image.height):
    image = image.resize(target.width, target.height, rfBox)
  writeAtomically(path, encodePng(image))
  result.width = image.width
  result.height = image.height
