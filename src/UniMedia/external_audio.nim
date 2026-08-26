# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Acoustic fingerprints, in process, through `UniAudio`.
##
## Nothing is spawned: `UniAudio` decodes the patent-free containers this
## library catalogues and takes the fingerprint from the decoded samples. A
## file it cannot decode raises rather than falling back to a tool.
##
## The chroma fingerprint, not the band-energy one beside it: a copy of a track
## re-encoded to MP3 or Vorbis has to stay recognisable at the same threshold
## an exact duplicate meets, and only this one does that. The words are the
## ones AcoustID indexes.

import std/[os, bitops]
import UniAudio

const
  MaxAudioSeconds* = 120
    ## Analysed prefix. Two recordings of the same track agree long before this,
    ## and a cap keeps a scan bounded on long files.

type
  AudioFingerprintError* = object of CatchableError

  AudioFingerprint* = object
    durationSeconds*: float
    raw*: seq[uint32] ## one 32-bit word per analysed frame, in time order

proc audioFingerprintAvailable*(): bool =
  ## Always true: fingerprinting is linked in, not looked up on PATH.
  true

proc audioFingerprint*(path: string; maxSeconds = MaxAudioSeconds):
    AudioFingerprint =
  ## Fingerprint `path`. Raises when the file is missing or symbolic, when the
  ## container is not one this build decodes, or when the recording is too short
  ## to yield a single word.
  if path.len == 0:
    raise newException(ValueError, "audio path must not be empty")
  if symlinkExists(path):
    raise newException(ValueError, "audio source must not be a symbolic link")
  if not fileExists(path):
    raise newException(IOError, "audio source is missing: " & path)
  if maxSeconds <= 0 or maxSeconds > 3600:
    raise newException(ValueError, "audio length must be between 1 and 3600 s")

  var buffer: AudioBuffer
  try:
    buffer = decodeFile(path)
  except CatchableError as error:
    raise newException(AudioFingerprintError,
      "cannot decode " & path & ": " & error.msg)

  # The prefix, not the whole recording: a scan over long files would otherwise
  # spend its time on samples that change no answer.
  let keep = min(buffer.format.frames, maxSeconds * buffer.format.sampleRate)
  if keep < buffer.format.frames:
    var head = initAudioBuffer(buffer.format.sampleRate,
                               buffer.format.channels, keep)
    for index in 0 ..< head.samples.len:
      head.samples[index] = buffer.samples[index]
    buffer = head

  let print = chromaFingerprint(buffer)
  if print.words.len == 0:
    raise newException(AudioFingerprintError,
      "recording is under three seconds, too short to fingerprint: " & path)
  AudioFingerprint(durationSeconds: print.durationSeconds, raw: print.words)

func audioSimilarity*(a, b: AudioFingerprint): float =
  ## 1.0 identical, 0.0 maximally different: the share of agreeing bits over the
  ## common prefix.
  ##
  ## The comparison starts at the first word of each side, so it recognises the
  ## same recording re-encoded. `audioOffsetSimilarity` is the one to reach for
  ## when a copy may start at a different point.
  let common = min(a.raw.len, b.raw.len)
  if common == 0: return 0.0
  var differing = 0
  for index in 0 ..< common:
    differing += countSetBits(a.raw[index] xor b.raw[index])
  1.0 - differing.float / float(common * 32)

func audioOffsetSimilarity*(a, b: AudioFingerprint; maxShift = 64): float =
  ## The best similarity over a bounded time shift, for two copies that start at
  ## different points — a track with a few seconds trimmed off the front is
  ## still the same recording, which `audioSimilarity` alone cannot see.
  if a.raw.len == 0 or b.raw.len == 0 or maxShift < 0: return 0.0
  for shift in 0 .. maxShift:
    for pair in [(a, b), (b, a)]:
      let (left, right) = pair
      if shift >= left.raw.len: continue
      let common = min(left.raw.len - shift, right.raw.len)
      if common == 0: continue
      var differing = 0
      for index in 0 ..< common:
        differing += countSetBits(left.raw[index + shift] xor right.raw[index])
      let score = 1.0 - differing.float / float(common * 32)
      if score > result: result = score

type SoundInfo* = object
  ## What an audio file's header says, and whatever tags it carries.
  ##
  ## Read in process through UniAudio, so unlike a video's this costs no
  ## external tool and no decode -- which is what lets a scan ask it of every
  ## track in a library.
  container*, codec*: string
  sampleRate*, channels*: int
  durationSeconds*: float
  durationKnown*: bool
    ## False where the container does not state a length: Ogg keeps it in the
    ## last page and MPEG audio in an optional header, and a guess recorded as
    ## a duration is worse than none.
  tags*: Tags

proc probeSound*(path: string): SoundInfo =
  ## The header and the tags of one audio file.
  let probed = probeAudioFile(path)
  result.container = $probed.container
  result.codec = probed.codec
  result.sampleRate = probed.format.sampleRate
  result.channels = probed.format.channels
  result.durationKnown = probed.framesKnown
  if probed.framesKnown and probed.format.sampleRate > 0:
    result.durationSeconds = durationSeconds(probed.format)
  result.tags = readTags(readFile(path))


