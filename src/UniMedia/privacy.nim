# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[algorithm, strutils, tables]
import UniImage
from UniMovie/isobmff import locationFile
import UniMedia/[types, store]

const IdentityTerms = ["artist", "author", "by-line", "creator", "copyright",
  "location", "owner", "serial"]

proc privacyAudit*(store: Store): seq[PrivacyFinding] =
  ## What each file gives away about where and by whom it was made.
  ##
  ## A video keeps its position somewhere an image reader does not look, so it
  ## is asked separately. Without that a camera roll's clips reported nothing
  ## at all — not even as unreadable — and silence in an audit reads as
  ## nothing to worry about, which is the one thing it must never mean.
  for item in store.listItems():
    var finding = PrivacyFinding(itemId: item.id, relPath: item.relPath)
    let path = store.absoluteItemPath(item.relPath)
    var imageReadFailed = false
    try:
      let metadata = readMetadata(path)
      if metadata.gpsLatitudeRef in {'N', 'S'} and
          metadata.gpsLongitudeRef in {'E', 'W'}:
        finding.signals.add "gps"
      if metadata.cameraModel.len > 0:
        finding.signals.add "camera"
      if metadata.software.len > 0:
        finding.signals.add "software"
      for key in metadata.allTags.keys:
        let normalized = key.toLowerAscii()
        for term in IdentityTerms:
          if term in normalized:
            finding.signals.add "identity"
            break
        if "identity" in finding.signals:
          break
    except CatchableError as error:
      imageReadFailed = true
      finding.error = error.msg

    # The other place a position hides. Tried whichever way the image read
    # went: a file can be readable as a picture and still carry this.
    if "gps" notin finding.signals:
      try:
        if locationFile(path).found:
          finding.signals.add "gps"
          # A video that carries a position is not unreadable, whatever the
          # image reader made of it.
          if imageReadFailed: finding.error = ""
      except CatchableError:
        discard

    finding.signals.sort()
    if finding.signals.len > 0 or finding.error.len > 0:
      result.add finding

