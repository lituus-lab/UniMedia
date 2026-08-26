# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Reading what a video is, and getting one frame out of it.
##
## The shape of a file — its tracks, dimensions, rotation and duration — comes
## from `UniMovie`, in process. Only a decoded frame still needs an external
## `ffmpeg`, because decoding is where the patents are and no `Uni*` carries a
## decoder.
##
## UniMedia never bundles FFmpeg and never invokes a shell.

import std/[os, osproc, strutils, tables, tempfiles]
import UniImage
import UniMovie

const
  ExternalMediaTimeoutMs* = 30_000
  MaxDecodedBytes* = 128 * 1024 * 1024

type
  ExternalMediaError* = object of CatchableError

  ExternalMediaInfo* = object
    ## What a video file turns out to be.
    width*, height*: int
      ## The size the decoder produces, which is what a frame out of
      ## `decodeMediaFrame` measures. A track whose pixels are not square is
      ## shown wider or taller than this; `displayWidth`/`displayHeight` carry
      ## that, and mixing the two stretches a thumbnail.
    displayWidth*, displayHeight*: int
      ## The size the file asks to be shown at, before rotation.
    rotation*: int
      ## Clockwise degrees the picture should be turned by — 0, 90, 180 or 270.
      ## Phones record sideways and correct it here rather than in the pixels.
    durationSeconds*: float
    codec*, format*: string
      ## The container's own names, e.g. `avc1` and `mp4`. These were `h264`
      ## and `mov,mp4,m4a,3gp,3g2,mj2` while ffprobe reported them.

proc requireRegularSource(path: string) =
  if path.len == 0:
    raise newException(ValueError, "media path must not be empty")
  if symlinkExists(path):
    raise newException(ValueError, "external media source must not be a symbolic link")
  if not fileExists(path):
    raise newException(IOError, "external media source is missing: " & path)

proc toolPath(name: string): string =
  result = findExe(name)
  if result.len == 0:
    raise newException(ExternalMediaError,
      name & " is not installed; configure a system FFmpeg package")

proc externalMediaAvailable*(): bool =
  ## Whether a frame can be decoded. Only `ffmpeg` is asked for: probing is
  ## done in process now, so a machine without it still catalogues videos and
  ## only goes without their thumbnails.
  findExe("ffmpeg").len > 0

proc runBounded(executable: string; arguments: openArray[string];
                timeoutMs = ExternalMediaTimeoutMs) =
  var process = startProcess(executable, args = @arguments,
    options = {poParentStreams})
  try:
    let code = process.waitForExit(timeoutMs)
    if code == -1:
      process.kill()
      discard process.waitForExit(2_000)
      raise newException(ExternalMediaError,
        executable.extractFilename & " exceeded the timeout")
    if code != 0:
      raise newException(ExternalMediaError,
        executable.extractFilename & " failed with exit code " & $code)
  finally:
    process.close()

proc tempPath(suffix: string): string =
  let temporary = createTempFile("unimedia-", suffix)
  temporary.cfile.close()
  temporary.path

proc probeMedia*(path: string): ExternalMediaInfo =
  ## What a video file is, read in process.
  ##
  ## `UniMovie` reads the container; nothing here decodes, and no external
  ## process runs. A file in a container it does not read raises
  ## `ExternalMediaError` naming that, rather than being reported as a generic
  ## failure or guessed at from its extension.
  requireRegularSource(path)
  let movie =
    try: readMovieFile(path)
    except MovieError as error:
      raise newException(ExternalMediaError,
        "cannot read " & path.extractFilename & ": " & error.msg)
    except IOError as error:
      raise newException(ExternalMediaError, error.msg)
  let index = movie.videoTrack
  if index < 0:
    raise newException(ExternalMediaError, "the file has no visual stream")
  let track = movie.tracks[index]

  # The coded size is the one a decoded frame has, so it is the one reported as
  # `width`; the display size is carried beside it rather than instead of it.
  result.width = if track.codedWidth > 0: track.codedWidth else: track.width
  result.height = if track.codedHeight > 0: track.codedHeight else: track.height
  result.displayWidth = track.width
  result.displayHeight = track.height
  result.rotation = ord(track.rotation)
  if result.width <= 0 or result.height <= 0 or result.width > 1_000_000 or
      result.height > 1_000_000:
    raise newException(ExternalMediaError,
      "video dimensions are outside safety limits")
  result.codec = track.codec
  result.format = movie.format
  # The movie header's duration, falling back to the track's where a file
  # declares none — a transport stream has no header to declare one in.
  result.durationSeconds = movie.durationSeconds
  if result.durationSeconds <= 0:
    result.durationSeconds = track.durationSeconds
  if result.durationSeconds < 0:
    raise newException(ExternalMediaError, "the file declares a negative duration")

const StillExts* = ["avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg",
                    "png", "ppm", "tga", "tiff", "webp"]
  ## What is decoded in process rather than through ffmpeg. Shared by the
  ## probe and the frame decoder so the two cannot disagree about what a
  ## still is.

proc isStill(path: string): bool =
  path.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in StillExts

proc toRgba(image: Image[uint8]): Image[uint8] =
  ## Four channels whatever the source had.
  ##
  ## A PPM decodes to three and a grayscale PNG to one, while the ffmpeg path
  ## forces RGBA. The ABI promises one layout -- `width * height * 4` -- so a
  ## caller does not have to ask which decoder produced its pixels.
  if image.channels == 4: return image
  result = Image[uint8](width: image.width, height: image.height, channels: 4,
    data: newSeq[uint8](image.width * image.height * 4))
  let pixels = image.width * image.height
  for index in 0 ..< pixels:
    let source = index * image.channels
    let target = index * 4
    case image.channels
    of 1:
      for channel in 0 .. 2: result.data[target + channel] = image.data[source]
      result.data[target + 3] = 255
    of 2: # grey plus alpha
      for channel in 0 .. 2: result.data[target + channel] = image.data[source]
      result.data[target + 3] = image.data[source + 1]
    of 3:
      for channel in 0 .. 2:
        result.data[target + channel] = image.data[source + channel]
      result.data[target + 3] = 255
    else:
      # Not a layout any reader here produces; copied as far as it goes rather
      # than guessed at.
      for channel in 0 ..< min(4, image.channels):
        result.data[target + channel] = image.data[source + channel]

proc decodeStill(path: string; maxEdge: int): Image[uint8] =
  ## One still, decoded and reduced in process.
  ##
  ## Not through ffmpeg: a HEIF holding a large photograph stores it as a grid
  ## of tiles, which ffmpeg presents as one video stream per tile. `-map
  ## 0:v:0` then takes the first of them, so a phone photograph came back as
  ## its top-left corner -- at the right reported size, which is what made it
  ## hard to see. UniImage assembles the picture instead.
  let text = readFile(path)
  var bytes = newSeq[byte](text.len)
  for index, character in text: bytes[index] = byte(character)
  let decoded = decodeImageScaled(bytes, maxEdge)
  # Turned to the way it is meant to be shown. ImageIO and this library's own
  # readers hand back the stored pixels and leave the orientation in the
  # metadata, which is the usual shape for a decoder; ffmpeg bakes it in. This
  # entry point promises one thing whichever produced the pixels, so a caller
  # does not have to know which platform it is on.
  let metadata = readMetadataFromBytes(bytes)
  let orientation = if metadata.orientation in 1 .. 8: metadata.orientation
                    else: 1
  let image = decoded.image.applyExifOrientation(orientation)
  let longest = max(image.width, image.height)
  if longest <= maxEdge or longest == 0: return toRgba(image)
  # Both edges shrink by the same factor, so the picture is not squashed.
  let width = max(1, image.width * maxEdge div longest)
  let height = max(1, image.height * maxEdge div longest)
  toRgba(resize(image, width, height))

proc probeStill*(path: string): ExternalMediaInfo =
  ## What a still image is: its size and the container it is in.
  ##
  ## A still has no duration and no track, so `probeMedia` cannot answer for
  ## one -- it looks for a `moov`, and a photograph has none. HEIF-family
  ## files are read through their own header, which costs a parse rather than
  ## a decode; anything else is decoded, because that is the only way its
  ## size is known.
  requireRegularSource(path)
  let ext = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})
  if ext in ["heic", "heif", "avif"]:
    let still = try: readHeifFile(path)
      except CatchableError as error:
        raise newException(ExternalMediaError,
          "cannot read " & path.extractFilename & ": " & error.msg)
    result.width = still.width
    result.height = still.height
  else:
    var bytes: seq[byte]
    let image = try:
        let text = readFile(path)
        bytes = newSeq[byte](text.len)
        for index, character in text: bytes[index] = byte(character)
        decodeImage(bytes)
      except CatchableError as error:
        raise newException(ExternalMediaError,
          "cannot read " & path.extractFilename & ": " & error.msg)
    result.width = image.width
    result.height = image.height
    # A vendor RAW is a TIFF whose first directory holds a preview: decoding
    # it answers 160x120 for a photograph of 4992x3280. The picture's own size
    # is stated in the metadata, which is what a caller asking how big this is
    # wants told.
    if bytes.len >= 2 and ((bytes[0] == 0x49'u8 and bytes[1] == 0x49'u8) or
        (bytes[0] == 0x4D'u8 and bytes[1] == 0x4D'u8)):
      let meta = readMetadataFromBytes(bytes)
      try:
        let stated = (parseInt(meta.allTags.getOrDefault("ImageWidth", "")),
                      parseInt(meta.allTags.getOrDefault("ImageHeight", "")))
        if stated[0] >= result.width and stated[1] >= result.height:
          result.width = stated[0]
          result.height = stated[1]
      except ValueError:
        discard
  if result.width <= 0 or result.height <= 0 or result.width > 1_000_000 or
      result.height > 1_000_000:
    raise newException(ExternalMediaError,
      "image dimensions are outside safety limits")
  result.displayWidth = result.width
  result.displayHeight = result.height
  result.rotation = 0
  result.durationSeconds = 0.0
  result.codec = ext
  result.format = ext

proc decodeMediaFrame*(path: string; maxEdge = 512;
                       seekSeconds = 0.0): Image[uint8] =
  requireRegularSource(path)
  if maxEdge notin 16..4096:
    raise newException(ValueError,
      "external media edge must be between 16 and 4096")
  if seekSeconds != seekSeconds or seekSeconds < 0 or seekSeconds > 1.0e9:
    raise newException(ValueError, "media seek time is outside valid ranges")
  if isStill(path):
    # A still has one frame, so a seek into it means nothing; the argument is
    # accepted and ignored rather than refused, since a caller walking a mixed
    # library passes the same one for every file.
    #
    # In process where that works, ffmpeg where it does not. Not the other way
    # round: a HEIF holding a large photograph stores it as a grid of tiles,
    # which ffmpeg presents as one video stream per tile, and `-map 0:v:0`
    # then takes the first of them -- a phone photograph coming back as its
    # top-left corner, at the right reported size, which is what makes it hard
    # to see. A tile is still better than nothing for a file UniImage cannot
    # read at all, so that path stays.
    try:
      return decodeStill(path, maxEdge)
    except CatchableError:
      discard
  let output = tempPath(".png")
  try:
    var arguments = @["-y", "-nostdin", "-hide_banner", "-nostats",
      "-loglevel", "error"]
    if seekSeconds > 0:
      arguments.add ["-ss", $seekSeconds]
    arguments.add ["-i", path]
    let still = isStill(path)
    # `-map 0:v:0` picks one stream, which is what a video needs and what a
    # tiled HEIF must not have: that container is presented as one stream per
    # tile, so selecting the first returns the top-left corner instead of the
    # picture. Left to itself ffmpeg assembles it -- through a filtergraph of
    # its own, which is why the scale filter goes too: the two cannot both
    # drive one output. The reduction happens below instead.
    if not still:
      arguments.add ["-map", "0:v:0"]
    arguments.add ["-frames:v", "1"]
    if not still:
      arguments.add ["-vf", "scale=" & $maxEdge & ":" & $maxEdge &
        ":force_original_aspect_ratio=decrease"]
    arguments.add ["-pix_fmt", "rgba", output]
    runBounded(toolPath("ffmpeg"), arguments)
    let size = getFileSize(output)
    if size <= 0 or size > MaxDecodedBytes:
      raise newException(ExternalMediaError,
        "decoded frame is empty or exceeds 128 MiB")
    result = decodeImage(readFile(output).toOpenArrayByte(0,
      int(size) - 1))
    if still:
      # ffmpeg decoded at full size, so the reduction is this side's to make.
      let longest = max(result.width, result.height)
      if longest > maxEdge and longest > 0:
        result = resize(result, max(1, result.width * maxEdge div longest),
          max(1, result.height * maxEdge div longest))
  finally:
    if fileExists(output): removeFile(output)
