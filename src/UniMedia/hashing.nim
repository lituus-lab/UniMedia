# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[os, strutils]
import UniCrypto
import UniPercept
import UniImage
import contracts
import UniMedia/[types, external_media]

const VideoFrameSamples* = 5
  ## Frames sampled per video. Enough that trimming one end still leaves
  ## overlapping frames, few enough that a scan stays bounded: each sample is
  ## one FFmpeg seek and decode.

type PerceptualHashInfo* = object
  hash*: uint64
  width*, height*: int

proc blake3File*(path: string; bufferSize = 1024 *
    1024; cancel: CancelCallback = nil): string {.contractual.} =
  require:
    path.len > 0
    bufferSize > 0
  ensure:
    result.len == 64
  body:
    var input = open(path, fmRead)
    defer: input.close()
    var hasher = newHasher()
    var buffer = newSeq[byte](bufferSize)
    while true:
      checkCancelled(cancel)
      let count = input.readBuffer(addr buffer[0], buffer.len)
      if count <= 0: break
      hasher.update(buffer.toOpenArray(0, count - 1))
    var digest: array[32, byte]
    hasher.finalize(digest)
    digest.toHex()

proc videoFrameHashes*(path: string; media: ExternalMediaInfo;
                       samples = VideoFrameSamples): seq[
                           uint64] {.contractual.} =
  ## Perceptual hashes of frames sampled across the whole video, in time order,
  ## from a container the caller has already probed.
  ##
  ## A scan needs the duration for the sampling positions and the dimensions
  ## for the catalogue, both from the same probe. Taking the probe as an
  ## argument is what stops the same file being probed twice.
  require:
    path.len > 0
    samples > 0
  ensure:
    result.len > 0
  body:
    for index in 0 ..< samples:
      # Sample the middle of each slice, not its edge: opening and closing
      # frames are often black or a title card, which would collide across
      # unrelated videos.
      let position = if media.durationSeconds > 0:
          media.durationSeconds * (float(index) + 0.5) / float(samples)
        else: 0.0
      let frame = decodeMediaFrame(path, 512, position)
      result.add uint64(pHash(toGrayscale(frame.data, frame.width, frame.height,
        4)))
      # A container without a usable duration yields one frame, not `samples`
      # copies of the same one.
      if media.durationSeconds <= 0: break

proc videoFrameHashes*(path: string;
                       samples = VideoFrameSamples): seq[uint64] =
  ## Probe the container, then hash frames across it. Needs the optional
  ## FFmpeg tools; raises when they are absent or the container cannot be
  ## probed.
  videoFrameHashes(path, probeMedia(path), samples)

proc perceptualHashInfoFile*(path: string): PerceptualHashInfo =
  try:
    let info = phashInfo(path)
    return PerceptualHashInfo(hash: uint64(info.hash), width: info.width,
      height: info.height)
  except UniImageException:
    let ext = path.splitFile.ext.toLowerAscii()
    if ext notin [".heic", ".heif", ".avif"]: raise
    # A still in an ISO base media container that this build cannot decode.
    # Its size comes from UniImage's HEIF reader, which needs no decoder, and
    # not from `probeMedia`: that one looks for a `moov`, and a still has none.
    let still = readHeifFile(path)
    let image = decodeMediaFrame(path, 512)
    let gray = toGrayscale(image.data, image.width, image.height, 4)
    return PerceptualHashInfo(hash: uint64(pHash(gray)),
      width: still.width, height: still.height)
