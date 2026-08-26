# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[json, os, strutils, sysrand]
import UniMedia/types

const ConfigName* = ".organizemedia.json"

proc parseDomain*(value: string): MediaDomain =
  case value.toLowerAscii()
  of "photo": mdPhoto
  of "video": mdVideo
  of "music": mdMusic
  of "visual": mdVisual
  else: raise newException(ValueError, "invalid media domain: " & value)

proc parseScheme*(value: string): OrganizeScheme =
  case value
  of "YYYY/MM-DD": osYearMonthDayDash
  of "YYYY/MM/DD": osYearMonthDay
  of "YYYY/MM": osYearMonth
  of "YYYY/YYYY-MM-DD": osYearDate
  of "flat": osFlat
  else: raise newException(ValueError, "invalid organize scheme: " & value)

proc parseConflict*(value: string): ConflictPolicy =
  case value.toLowerAscii()
  of "suffix": cpSuffix
  of "skip": cpSkip
  else: raise newException(ValueError, "invalid conflict policy: " & value)

proc validateBucket(value: string) =
  if value.len == 0 or value in [".", ".."] or value.contains('/') or
      value.contains('\\'):
    raise newException(ValueError, "invalid noDateDir: " & value)

proc configJson(config: LibraryConfig): JsonNode = %*{
  "schemaVersion": config.schemaVersion,
  "domain": $config.domain,
  "scheme": $config.scheme,
  "filenameDate": config.filenameDate,
  "birthtimeDate": config.birthtimeDate,
  "noDateDir": config.noDateDir,
  "onConflict": $config.onConflict
}

proc writeConfig*(root: string; config: LibraryConfig) =
  if symlinkExists(root):
    raise newException(ValueError, "library root must not be a symbolic link: " & root)
  createDir(root)
  validateBucket(config.noDateDir)
  let dest = root / ConfigName
  if symlinkExists(dest):
    raise newException(ValueError, "library config must not be a symbolic link: " & dest)
  var suffix = ""
  for value in urandom(8): suffix.add value.toHex(2).toLowerAscii()
  let tmp = root / (".organizemedia-" & suffix & ".tmp")
  try:
    writeFile(tmp, pretty(configJson(config)) & "\n")
    moveFile(tmp, dest)
  finally:
    if fileExists(tmp): removeFile(tmp)

proc readConfig*(root: string): LibraryConfig =
  let path = root / ConfigName
  if not fileExists(path):
    raise newException(IOError, "not an om library (missing " & ConfigName &
        "): " & root)
  if symlinkExists(path):
    raise newException(ValueError, "library config must not be a symbolic link: " & path)
  let node = parseFile(path)
  if node.kind != JObject:
    raise newException(ValueError, "library config must be a JSON object")
  const allowed = ["schemaVersion", "domain", "scheme", "filenameDate",
                   "birthtimeDate", "noDateDir", "onConflict"]
  for key, _ in node:
    if key notin allowed:
      raise newException(ValueError, "unknown library config key: " & key)
  for key in allowed:
    if not node.hasKey(key):
      raise newException(ValueError, "missing library config key: " & key)
  result.schemaVersion = node["schemaVersion"].getInt()
  if result.schemaVersion != 1:
    raise newException(ValueError, "unsupported library config version: " &
        $result.schemaVersion)
  result.domain = parseDomain(node["domain"].getStr())
  result.scheme = parseScheme(node["scheme"].getStr())
  result.filenameDate = node["filenameDate"].getBool()
  result.birthtimeDate = node["birthtimeDate"].getBool()
  result.noDateDir = node["noDateDir"].getStr()
  validateBucket(result.noDateDir)
  result.onConflict = parseConflict(node["onConflict"].getStr())
