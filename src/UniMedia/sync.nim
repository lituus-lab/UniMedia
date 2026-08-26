# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Non-destructive external rclone transport. Credentials stay in rclone config.

import std/[algorithm, json, os, osproc, strutils, sysrand, tables, tempfiles,
  times]
import db_connector/db_sqlite
import UniMedia/[store, types]

const SyncTimeoutMs* = 24 * 60 * 60 * 1000
const MaxSyncLogBytes* = 16 * 1024 * 1024
const SyncManifestVersion* = 1
const MaxSyncManifestBytes* = 64 * 1024 * 1024

proc buildSyncManifest*(store: Store): SyncManifest =
  ## Builds a deterministic, root-independent snapshot of catalogued content.
  result.schemaVersion = SyncManifestVersion
  for row in store.db.fastRows(sql"""SELECT i.rel_path,i.file_size,i.mtime_ns,
      COALESCE(h.blake3,'') FROM items i LEFT JOIN item_hashes h ON h.item_id=i.id
      WHERE i.deleted_at IS NULL ORDER BY i.rel_path"""):
    if row[3].len != 64 or not row[3].allCharsInSet(HexDigits):
      raise newException(ValueError,
        "catalog item lacks an exact BLAKE3 digest; rescan before manifest export")
    result.entries.add SyncManifestEntry(path: row[0], size: row[
        1].parseBiggestInt,
      mtimeNs: row[2].parseBiggestInt, digest: row[3].toLowerAscii)

proc syncManifestJson*(manifest: SyncManifest): JsonNode =
  result = %*{"schemaVersion": manifest.schemaVersion, "entries": newJArray()}
  for entry in manifest.entries:
    result["entries"].add %*{"path": entry.path, "size": entry.size,
      "mtimeNs": entry.mtimeNs, "digest": entry.digest}

proc parseSyncManifest*(data: string): SyncManifest =
  if data.len > MaxSyncManifestBytes:
    raise newException(ValueError, "sync manifest exceeds 64 MiB")
  let node = try: parseJson(data)
    except JsonParsingError as error:
      raise newException(ValueError, "invalid sync manifest JSON: " & error.msg)
  if node.kind != JObject or not node.hasKey("schemaVersion") or
      node["schemaVersion"].kind != JInt or
      node["schemaVersion"].getInt != SyncManifestVersion or
      not node.hasKey("entries") or node["entries"].kind != JArray:
    raise newException(ValueError, "unsupported sync manifest")
  result.schemaVersion = SyncManifestVersion
  var previous = ""
  for item in node["entries"]:
    if item.kind != JObject or not item.hasKey("path") or
        item["path"].kind != JString or not item.hasKey("size") or
        item["size"].kind != JInt or not item.hasKey("mtimeNs") or
        item["mtimeNs"].kind != JInt or not item.hasKey("digest") or
        item["digest"].kind != JString:
      raise newException(ValueError, "invalid sync manifest entry")
    let entry = SyncManifestEntry(path: item["path"].getStr,
      size: item["size"].getBiggestInt, mtimeNs: item["mtimeNs"].getBiggestInt,
      digest: item["digest"].getStr)
    if entry.path.len == 0 or entry.path.isAbsolute or '\0' in entry.path or
        entry.path == ".." or entry.path.startsWith("../") or
        entry.path.contains("/../") or entry.path.startsWith("..\\") or
        entry.path.contains("\\..\\") or entry.path.len > 4096 or
        entry.digest.len != 64 or not entry.digest.allCharsInSet(HexDigits) or
        entry.size < 0 or
        (previous.len > 0 and entry.path <= previous):
      raise newException(ValueError, "unsafe or unsorted sync manifest entry")
    previous = entry.path
    result.entries.add entry

proc diffSyncManifests*(local, remote: SyncManifest): SyncDiff =
  var localEntries, remoteEntries: Table[string, SyncManifestEntry]
  for entry in local.entries: localEntries[entry.path] = entry
  for entry in remote.entries: remoteEntries[entry.path] = entry
  for path, entry in localEntries:
    if path notin remoteEntries: result.onlyLocal.add path
    elif entry.digest != remoteEntries[path].digest or
        entry.size != remoteEntries[path].size:
      result.changed.add path
  for path in remoteEntries.keys:
    if path notin localEntries: result.onlyRemote.add path
  result.onlyLocal.sort()
  result.onlyRemote.sort()
  result.changed.sort()

proc validateRemote(remote: string) =
  if remote.strip.len == 0 or remote.len > 4096 or '\0' in remote or
      '\n' in remote or '\r' in remote:
    raise newException(ValueError, "invalid rclone remote")

proc rcloneAvailable*(): bool = findExe("rclone").len > 0

proc runRclone(localRoot, remote, incoming: string; direction: SyncDirection;
               dryRun: bool): string =
  validateRemote(remote)
  let tool = findExe("rclone")
  if tool.len == 0:
    raise newException(IOError, "rclone is not installed")
  let temporary = createTempFile("unimedia-rclone-", ".log")
  temporary.cfile.close()
  let logPath = temporary.path
  let changes = createTempFile("unimedia-rclone-", ".changes")
  changes.cfile.close()
  let changesPath = changes.path
  try:
    let source = if direction == sdPush: localRoot else: remote
    let destination = if direction == sdPush: remote else: incoming
    var arguments = @["copy", source, destination, "--log-file", logPath,
      "--log-level", "INFO", "--metadata", "--combined", changesPath]
    if direction == sdPush:
      # Library-local control state, never pushed. The .toml is not written
      # here: a library migrated from organizeMedia carries its folder
      # preferences in one, and those stay local too.
      for pattern in ["/.organizemedia.json", "/.organizemedia.toml",
          "/.organizemedia-*.tmp", "/organizeMedia.db*",
          "/.om-cache/**", "/.om-trash/**", "/.om-incoming/**",
          "/.om-tmp-*/**"]:
        arguments.add ["--exclude", pattern]
    if dryRun: arguments.add "--dry-run"
    var process = startProcess(tool, args = arguments, options = {poParentStreams})
    try:
      let code = process.waitForExit(SyncTimeoutMs)
      if code == -1:
        process.kill()
        discard process.waitForExit(2_000)
        raise newException(IOError, "rclone exceeded the timeout")
      if code != 0:
        raise newException(IOError, "rclone failed with exit code " & $code)
    finally:
      process.close()
    if getFileSize(logPath) > MaxSyncLogBytes or
        getFileSize(changesPath) > MaxSyncLogBytes:
      raise newException(IOError, "rclone output exceeds 16 MiB")
    result = readFile(if dryRun: changesPath else: logPath).strip
  finally:
    if fileExists(logPath): removeFile(logPath)
    if fileExists(changesPath): removeFile(changesPath)

proc newRunId(): string =
  var suffix = ""
  for value in urandom(8): suffix.add value.toHex(2).toLowerAscii()
  "sync_" & $int64(epochTime() * 1_000_000.0) & "_" & suffix

proc planSync*(store: Store; remote: string;
               direction: SyncDirection): SyncPlan =
  result = SyncPlan(id: newRunId(), provider: "rclone", remote: remote.strip,
    direction: direction)
  let incoming = checkedPathUnder(store.library.root,
    store.library.root / ".om-incoming" / result.id)
  result.summary = runRclone(store.library.root, result.remote, incoming,
    direction, true)
  store.db.exec(sql"""
    INSERT INTO sync_runs(id,provider,remote,direction,dry_run,status,started_at,
      finished_at,summary) VALUES(?,?,?,?,1,'planned',?,?,?)""", result.id,
      result.provider, result.remote, $direction, isoNow(), isoNow(),
          result.summary)

proc applySync*(store: Store; planId: string): SyncReport =
  let row = store.db.getRow(sql"""SELECT remote,direction,status FROM sync_runs
    WHERE id=?""", planId)
  if row[0].len == 0: raise newException(KeyError, "unknown sync plan: " & planId)
  if row[2] != "planned":
    raise newException(ValueError, "sync plan is no longer applicable: " & planId)
  let direction = if row[1] == "push": sdPush elif row[1] == "pull": sdPull
    else: raise newException(ValueError, "stored sync direction is invalid")
  try:
    let incoming = checkedPathUnder(store.library.root,
      store.library.root / ".om-incoming" / planId)
    if direction == sdPull and not dirExists(incoming): createDir(incoming)
    let currentPlan = runRclone(store.library.root, row[0], incoming,
      direction, true)
    let plannedSummary = store.db.getValue(
      sql"SELECT summary FROM sync_runs WHERE id=?", planId)
    if currentPlan != plannedSummary:
      raise newException(ValueError,
        "sync endpoints changed after review; build and review a new plan")
    result.summary = runRclone(store.library.root, row[0], incoming, direction,
      false)
    result.id = planId
    result.applied = true
    store.db.exec(sql"UPDATE sync_runs SET status='applied',dry_run=0,finished_at=?,summary=? WHERE id=?",
      isoNow(), result.summary, planId)
  except CatchableError as error:
    store.db.exec(sql"UPDATE sync_runs SET status='failed',finished_at=?,summary=? WHERE id=?",
      isoNow(), error.msg, planId)
    raise

proc listSyncRuns*(store: Store; planId = ""; limit = 100): seq[SyncRun] =
  if limit notin 1..1000:
    raise newException(ValueError, "sync status limit must be between 1 and 1000")
  let query = if planId.len > 0: sql"""SELECT id,provider,remote,direction,
    dry_run,status,started_at,COALESCE(finished_at,''),summary FROM sync_runs
    WHERE id=? ORDER BY started_at DESC,id DESC LIMIT ?"""
    else: sql"""SELECT id,provider,remote,direction,dry_run,status,started_at,
      COALESCE(finished_at,''),summary FROM sync_runs
      ORDER BY started_at DESC,id DESC LIMIT ?"""
  let params = if planId.len > 0: @[$planId, $limit] else: @[$limit]
  for row in store.db.fastRows(query, params):
    let direction = if row[3] == "push": sdPush elif row[3] == "pull": sdPull
      else: raise newException(ValueError, "stored sync direction is invalid")
    result.add SyncRun(id: row[0], provider: row[1], remote: row[2],
      direction: direction, dryRun: row[4] == "1", status: row[5],
      startedAt: row[6], finishedAt: row[7], summary: row[8])
