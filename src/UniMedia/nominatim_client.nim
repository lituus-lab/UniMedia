# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Explicit client for a user-selected Nominatim-compatible endpoint.

import std/[httpclient, json, monotimes, os, strutils, times, uri]
import UniMedia/types

const MinimumRequestIntervalMs* = 1000'i64

proc newNominatimProvider*(endpoint, userAgent: string): ReverseGeocodeProvider =
  let base = endpoint.strip().strip(chars = {'/'})
  if not (base.startsWith("https://") or base.startsWith("http://")):
    raise newException(ValueError, "geocoder endpoint must use HTTP or HTTPS")
  when not defined(ssl):
    # Said here rather than at the socket. A build without SSL accepts the
    # endpoint, accepts the request, and only then cannot connect — and the
    # message it gives names the compiler flag, not the thing the caller did.
    if base.startsWith("https://"):
      raise newException(ValueError,
        "this build has no SSL, so it cannot reach an https endpoint; " &
        "build without -d:noSsl, or name an http one")
  if '?' in base or '#' in base:
    raise newException(ValueError, "geocoder endpoint must not contain query or fragment")
  let identity = userAgent.strip()
  if identity.len < 6 or identity.len > 500 or '\n' in identity or '\r' in identity:
    raise newException(ValueError,
      "geocoder User-Agent must identify the application")
  let client = newHttpClient(timeout = 30_000, maxRedirects = 3)
  var hasRequested = false
  var previousRequest: MonoTime
  result = proc(latitude, longitude: float;
                language: string): ReverseGeocodeResult {.gcsafe.} =
    if hasRequested:
      let elapsed = (getMonoTime() - previousRequest).inMilliseconds
      if elapsed < MinimumRequestIntervalMs:
        sleep(int(MinimumRequestIntervalMs - elapsed))
    client.headers = newHttpHeaders({"User-Agent": identity,
      "Accept": "application/json", "Accept-Language": language})
    let url = base & "/reverse?format=jsonv2&addressdetails=0&layer=address" &
      "&lat=" & encodeUrl($latitude) & "&lon=" & encodeUrl($longitude)
    previousRequest = getMonoTime()
    hasRequested = true
    let body = client.getContent(url)
    if body.len > 1_000_000:
      raise newException(ValueError, "geocoder response exceeds 1 MiB")
    let node = try: parseJson(body)
      except JsonParsingError as error:
        raise newException(ValueError, "invalid geocoder JSON: " & error.msg)
    if node.kind != JObject or not node.hasKey("display_name") or
        not node.hasKey("licence"):
      raise newException(ValueError,
        "geocoder response lacks display_name or licence")
    ReverseGeocodeResult(locationText: node["display_name"].getStr(),
      attribution: node["licence"].getStr())
