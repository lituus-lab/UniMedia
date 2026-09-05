# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Removing what accumulates around a media library without belonging to it.
##
## Five kinds of litter, kept apart because they do not carry the same risk: the
## sidecar files macOS writes on a filesystem that cannot hold extended
## attributes, the droppings of a file browser, sidecars whose media is gone,
## directories a re-filing emptied, and the temporary files an interrupted run
## left behind.
##
## Nothing here deletes. Files move into the journaled trash exactly as a
## removal does, so `undo` brings them back — a cleanup is as reversible as
## anything else this engine does. The one exception is an empty directory,
## stated where it happens.
##
## An AppleDouble file is **read before it is proposed**. It usually holds
## nothing worth keeping, but it is also where a Finder tag, a comment and a
## resource fork live when the filesystem cannot store them beside the file, and
## deleting one of those loses what no copy would bring back. So the payload is
## parsed, and a file carrying anything but known-worthless markers is reported
## and left alone.

import std/[algorithm, os, sequtils, sets, strutils, tables]
import db_connector/db_sqlite
import UniMedia/[types, store, config, hashing]
from UniMedia/organize import newBatchId, recoverInterruptedBatches

const AppleDoubleMagic = 0x00051607'u32
  ## The first four bytes of every AppleDouble file.

const EmptyResourceFork = 286
  ## An AppleDouble carrying no resource data still writes the empty resource
  ## map, which is this long. Anything longer is real fork content.

const HarmlessAttributes = [
    "com.apple.provenance",
    "com.apple.quarantine",
    "com.apple.lastuseddate#PS",
    "com.apple.macl"]
  ## Attributes macOS sets for its own bookkeeping. Anything outside this list —
  ## a Finder tag, a comment, the address something was downloaded from — makes
  ## the file worth keeping.

const BrowserJunk = [".ds_store", "thumbs.db", "ehthumbs.db", "desktop.ini"]
  ## What a file browser leaves in a folder it displayed. Matched on the lower
  ## case name: a Windows share hands these back with any capitalisation.

const SidecarExts = ["xmp", "aae", "thm"]
  ## Files that describe a media file rather than being one.

proc beU32(data: string; offset: int): uint32 =
  ## Four big-endian bytes, or zero past the end.
  if offset + 4 > data.len: return 0
  (uint32(uint8(data[offset])) shl 24) or
    (uint32(uint8(data[offset + 1])) shl 16) or
    (uint32(uint8(data[offset + 2])) shl 8) or uint32(uint8(data[offset + 3]))

proc beU16(data: string; offset: int): int =
  ## Two big-endian bytes, or zero past the end.
  if offset + 2 > data.len: return 0
  (int(uint8(data[offset])) shl 8) or int(uint8(data[offset + 1]))

type AppleDoubleContents = object
  ## What one AppleDouble file is carrying.
  parsed: bool
    ## False where the file does not look like AppleDouble at all, which is
    ## reason enough to leave it where it is.
  attributes: seq[string]
  finderInfoSet: bool
  resourceForkLen: int

proc readAppleDouble(path: string): AppleDoubleContents =
  ## Parse enough of an AppleDouble file to say whether it holds anything.
  ##
  ## The extended attributes live inside the Finder-info entry, past the 32
  ## bytes of Finder info proper, in a block Apple marks `ATTR`. Each entry
  ## names its attribute, and those names are what the decision rests on.
  let data = try: readFile(path) except CatchableError: return
  if data.len < 26 or beU32(data, 0) != AppleDoubleMagic: return
  let entries = beU16(data, 24)
  var at = 26
  for _ in 0 ..< entries:
    if at + 12 > data.len: return
    let id = int(beU32(data, at))
    let offset = int(beU32(data, at + 4))
    let length = int(beU32(data, at + 8))
    at += 12
    if offset < 0 or length < 0 or offset + length > data.len: return
    case id
    of 2:
      result.resourceForkLen = length
    of 9:
      for index in 0 ..< min(32, length):
        if data[offset + index] != '\0':
          result.finderInfoSet = true
          break
      let region = data[offset ..< offset + length]
      let attrAt = region.find("ATTR")
      if attrAt < 0: continue
      let header = region[attrAt .. ^1]
      if header.len < 36: continue
      let count = beU16(header, 34)
      var cursor = 36
      for _ in 0 ..< count:
        if cursor + 11 > header.len: break
        let nameLen = int(uint8(header[cursor + 10]))
        if cursor + 11 + nameLen > header.len: break
        var name = header[cursor + 11 ..< cursor + 11 + nameLen]
        let terminator = name.find('\0')
        if terminator >= 0: name.setLen(terminator)
        result.attributes.add name
        cursor += 11 + nameLen
        cursor = (cursor + 3) and not 3
    else: discard
  result.parsed = true

proc appleDoubleVerdict*(path: string): tuple[removable: bool; reason: string] =
  ## Whether this AppleDouble may go, and why either way.
  let contents = readAppleDouble(path)
  if not contents.parsed:
    return (false, "not readable as AppleDouble, so what it holds is unknown")
  if contents.finderInfoSet:
    return (false, "carries Finder information — a label, flags or a type")
  if contents.resourceForkLen > EmptyResourceFork:
    return (false, "carries a resource fork of " & $contents.resourceForkLen &
      " bytes")
  var kept: seq[string]
  for name in contents.attributes:
    if name notin HarmlessAttributes: kept.add name
  if kept.len > 0: return (false, "carries " & kept.join(", "))
  if contents.attributes.len == 0: return (true, "holds nothing")
  (true, "holds only " & contents.attributes.join(", "))

proc isOrphanSidecar(path: string; neighbours: HashSet[string]): bool =
  ## Whether a sidecar has no media beside it.
  ##
  ## Both spellings are looked for — `IMG_1.HEIC.xmp` beside `IMG_1.HEIC`, and
  ## `IMG_1.xmp` beside it — because both are written in practice, and finding
  ## either means the sidecar still describes something.
  ##
  ## `neighbours` is the directory's own listing, gathered once by the caller.
  ## It used to walk the directory itself, which meant opening the very
  ## directory the plan's own walk was reading: the outer walk lost its place
  ## and skipped entries, so a folder of 382 files was seen as 197 and most of
  ## its orphans were never found.
  let parts = splitFile(path)
  if parts.name in neighbours: return false # IMG_1.HEIC.xmp
  for other in neighbours:
    let split = splitFile(other)
    if split.name == parts.name and split.ext != parts.ext: return false
  true

proc classify(path, rel: string; kinds: HashSet[CleanupKind];
              neighbours: HashSet[string]): seq[CleanupEntry] =
  ## What this one file is, if it is litter at all.
  let name = path.extractFilename
  let lower = name.toLowerAscii()
  let ext = splitFile(name).ext.strip(chars = {'.'}).toLowerAscii()
  let size = try: getFileSize(path) except CatchableError: 0'i64

  # What a file is does not depend on what was asked for. A `._IMG_1.aae` is an
  # AppleDouble whose name happens to end in a sidecar extension; letting it
  # fall through to the sidecar rule when that category was not requested would
  # take it away without the reading its own category guarantees — which is the
  # one protection worth having here.
  if name.startsWith("._"):
    if ckAppleDouble notin kinds: return @[]
    let verdict = appleDoubleVerdict(path)
    return @[CleanupEntry(relPath: rel, kind: ckAppleDouble, size: size,
      removable: verdict.removable, reason: verdict.reason)]
  if lower in BrowserJunk and ckOsJunk in kinds:
    return @[CleanupEntry(relPath: rel, kind: ckOsJunk, size: size,
      removable: true, reason: "written by a file browser, not by a camera")]
  if name.startsWith(".om-tmp-") and ckInterrupted in kinds:
    return @[CleanupEntry(relPath: rel, kind: ckInterrupted, size: size,
      removable: true, reason: "left by a run that did not finish")]
  if ext in SidecarExts and ckOrphanSidecar in kinds and
      isOrphanSidecar(path, neighbours):
    return @[CleanupEntry(relPath: rel, kind: ckOrphanSidecar, size: size,
      removable: true, reason: "describes a file that is no longer here")]
  @[]

proc planCleanup*(store: Store;
                  kinds: HashSet[CleanupKind] = initHashSet[CleanupKind]()):
                 CleanupPlan =
  ## What a cleanup would take away, taking nothing.
  ##
  ## An empty `kinds` means every kind. The library's database, its
  ## configuration and its trash are never candidates: the first two are what
  ## make it a library, and the third is what makes everything undoable.
  var wanted = kinds
  if wanted.len == 0:
    for kind in CleanupKind: wanted.incl kind
  let root = store.library.root
  var directories: seq[string]
  var files: seq[string]
  # Collected before anything is classified. Deciding as it walks would mean
  # reading a directory from inside the walk of that same directory, which
  # loses the outer walk's place.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir}):
    let rel = relCatalogPath(path, root)
    if rel.startsWith(TrashDirName): continue
    let name = path.extractFilename
    if name == ConfigName or name.startsWith(DatabaseName) or
       name.startsWith(LegacyDatabaseName): continue
    if dirExists(path):
      directories.add path
      continue
    if symlinkExists(path): continue
    files.add path

  var neighbours = initTable[string, HashSet[string]]()
  for path in files:
    let parent = path.parentDir
    if parent notin neighbours: neighbours[parent] = initHashSet[string]()
    neighbours[parent].incl path.extractFilename
  for path in files:
    result.entries.add classify(path, relCatalogPath(path, root), wanted,
      neighbours.getOrDefault(path.parentDir))

  if ckEmptyDir in wanted:
    # Deepest first, so a directory holding only empty directories is itself
    # seen to be empty once those have been accounted for.
    directories.sort(proc (a, b: string): int = cmp(b.len, a.len))
    var going = initHashSet[string]()
    for directory in directories:
      var empty = true
      for _, child in walkDir(directory):
        if child in going: continue
        empty = false
        break
      if not empty: continue
      going.incl directory
      result.entries.add CleanupEntry(relPath: relCatalogPath(directory, root),
        kind: ckEmptyDir, size: 0, removable: true, reason: "holds nothing")

proc applyCleanup*(store: var Store; plan: CleanupPlan;
                   progress: ProgressCallback = nil;
                   permanently = false): ApplyReport =
  ## Move what the plan marked removable into the journaled trash.
  ##
  ## `permanently` deletes instead. **There is no way back from that**: no
  ## trash, no journal, no undo. It exists because a network share pays for
  ## every move — trashing 44299 files and then emptying them is twice the work
  ## of deleting them once — and because what this command takes is litter it
  ## has read and proved worthless. Nothing else here offers it.
  ##
  ## An entry the plan reported but did not mark is counted as skipped: it was
  ## shown so somebody knows it is there, not so it would be taken away.
  ##
  ## An empty directory is removed rather than trashed. It held nothing, so
  ## there is nothing for the trash to keep and nothing an undo could lose.
  if plan.entries.len == 0:
    raise newException(ValueError, "cleanup plan is empty")
  let files = plan.entries.filterIt(it.removable and it.kind != ckEmptyDir)
  let directories = plan.entries.filterIt(it.removable and it.kind == ckEmptyDir)
  if files.len == 0 and directories.len == 0:
    raise newException(ValueError,
      "nothing in this plan can be removed; every entry was reported only")
  recoverInterruptedBatches(store)
  let root = store.library.root

  if permanently:
    # No batch id: there is nothing to undo, and handing back an identifier
    # that undo would reject reads as a way back that does not exist.
    for index, entry in files:
      try:
        removeFile(store.absoluteItemPath(entry.relPath))
        inc result.applied
      except CatchableError:
        inc result.failed
      if progress != nil:
        progress(ProgressEvent(phase: "cleanup", current: index + 1,
          total: files.len, message: entry.relPath))
    for entry in directories:
      try:
        removeDir(store.absoluteItemPath(entry.relPath), checkDir = true)
        inc result.applied
      except CatchableError:
        inc result.failed
    result.skipped = plan.entries.countIt(not it.removable)
    return

  result.batchId = newBatchId()
  if files.len > 0:
    store.db.exec(sql"BEGIN IMMEDIATE")
    try:
      store.db.exec(sql"""
        INSERT INTO batches(id,created_at,source_root,mode,status)
        VALUES(?,?,?,'cleanup',?)""", result.batchId, isoNow(), root,
        $bsApplying)
      for index, entry in files:
        let source = store.absoluteItemPath(entry.relPath)
        store.db.exec(sql"""
          INSERT INTO batch_ops(batch_id,seq,kind,source_path,dest_rel_path,
            content_hash,status) VALUES(?,?,?,?,?,?,?)""", result.batchId,
          index, $okMove, source,
          TrashDirName / result.batchId / "cleanup" / entry.relPath,
          (try: blake3File(source) except CatchableError: ""), $opsPending)
      store.db.exec(sql"COMMIT")
    except CatchableError:
      store.db.exec(sql"ROLLBACK")
      raise

  for index, entry in files:
    let source = store.absoluteItemPath(entry.relPath)
    let destination = root / TrashDirName / result.batchId / "cleanup" /
      entry.relPath
    try:
      createDir(destination.parentDir)
      moveFile(source, destination)
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=NULL WHERE batch_id=? AND seq=?""",
        $opsApplied, result.batchId, index)
      inc result.applied
    except CatchableError as error:
      store.db.exec(sql"""
        UPDATE batch_ops SET status=?,error=? WHERE batch_id=? AND seq=?""",
        $opsFailed, error.msg, result.batchId, index)
      inc result.failed
    if progress != nil:
      progress(ProgressEvent(phase: "cleanup", current: index + 1,
        total: files.len, message: entry.relPath))

  for entry in directories:
    try:
      removeDir(store.absoluteItemPath(entry.relPath), checkDir = true)
      inc result.applied
    except CatchableError:
      inc result.failed

  result.skipped = plan.entries.countIt(not it.removable)
  if files.len > 0:
    let status = if result.failed > 0: bsPartial else: bsApplied
    store.db.exec(sql"UPDATE batches SET status=? WHERE id=?", $status,
      result.batchId)

