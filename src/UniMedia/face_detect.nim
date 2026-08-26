# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Structured external face-detector protocol and local visual signatures.

import std/[json, math, os, osproc, tempfiles]
import UniImage
import UniPercept
import UniMedia/[store, types, people, thumbnails]

const
  FaceDetectorTimeoutMs* = 60_000
  MaxFaceDetectorBytes* = 4 * 1024 * 1024
  MaxFacesPerItem* = 10_000

proc runDetector(backend, input, output: string) =
  let executable = if backend.contains(DirSep) or backend.contains(
      AltSep): backend
    else: findExe(backend)
  if executable.len == 0 or not fileExists(executable):
    raise newException(IOError, "face detector executable is missing: " & backend)
  var process = startProcess(executable,
    args = @["--input", input, "--output", output],
    options = {poParentStreams})
  try:
    let code = process.waitForExit(FaceDetectorTimeoutMs)
    if code == -1:
      process.kill()
      discard process.waitForExit(2_000)
      raise newException(IOError, "face detector exceeded the timeout")
    if code != 0:
      raise newException(IOError,
        "face detector failed with exit code " & $code)
  finally:
    process.close()

proc detectorObservations(backend, input: string): seq[FaceDetection] =
  let temporary = createTempFile("unimedia-faces-", ".json")
  temporary.cfile.close()
  try:
    runDetector(backend, input, temporary.path)
    let size = getFileSize(temporary.path)
    if size <= 0 or size > MaxFaceDetectorBytes:
      raise newException(IOError, "face detector output is empty or too large")
    let root = parseFile(temporary.path)
    if root.kind != JArray or root.len > MaxFacesPerItem:
      raise newException(IOError, "face detector output must be a bounded array")
    for node in root:
      if node.kind != JObject or not node.hasKey("x") or
          node["x"].kind notin {JInt, JFloat} or not node.hasKey("y") or
          node["y"].kind notin {JInt, JFloat} or not node.hasKey("width") or
          node["width"].kind notin {JInt, JFloat} or
          not node.hasKey("height") or node["height"].kind notin {JInt,
              JFloat} or
          not node.hasKey("confidence") or
          node["confidence"].kind notin {JInt, JFloat} or
          not node.hasKey("detector") or node["detector"].kind != JString:
        raise newException(IOError,
          "face detector observation has an invalid shape")
      result.add FaceDetection(x: node["x"].getFloat(),
        y: node["y"].getFloat(), width: node["width"].getFloat(),
        height: node["height"].getFloat(),
        confidence: node["confidence"].getFloat(),
        detector: node["detector"].getStr())
  except JsonParsingError as error:
    raise newException(IOError, "invalid face detector JSON: " & error.msg)
  finally:
    if fileExists(temporary.path): removeFile(temporary.path)

proc readImage(path: string): Image[uint8] =
  let raw = readFile(path)
  if raw.len == 0: raise newException(IOError, "empty thumbnail")
  decodeImage(raw.toOpenArrayByte(0, raw.high))

proc signedObservation(image: Image[uint8];
    observation: FaceDetection): FaceDetection =
  result = observation
  let x = clamp(int(floor(observation.x * float(image.width))), 0,
    image.width - 1)
  let y = clamp(int(floor(observation.y * float(image.height))), 0,
    image.height - 1)
  let right = clamp(int(ceil((observation.x + observation.width) *
    float(image.width))), x + 1, image.width)
  let bottom = clamp(int(ceil((observation.y + observation.height) *
    float(image.height))), y + 1, image.height)
  let face = image.crop(x, y, right - x, bottom - y)
  let gray = toGrayscale(face.data, face.width, face.height, face.channels)
  result.signature = uint64(pHash(gray))
  result.signatureValid = true

proc detectFaces*(store: Store; itemId: int64; backend: string): seq[Face] =
  let item = store.getItem(itemId)
  if item.category notin ["image", "video"]:
    raise newException(ValueError, "face detection requires visual media")
  let source = store.absoluteItemPath(item.relPath)
  let observations = detectorObservations(backend, source)
  let thumbnail = store.ensureThumbnail(itemId, 1024)
  let image = readImage(thumbnail.path)
  var signed: seq[FaceDetection]
  for observation in observations:
    signed.add signedObservation(image, observation)
  store.replaceFaces(itemId, signed)
  store.listFaces(itemId)
