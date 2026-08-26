# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[algorithm, json, math, sequtils, sets, strutils, tables]
import db_connector/db_sqlite
import UniPercept
import contracts
import UniMedia/[types, store, organize, removal, external_audio]

func atMostOneKeeperPerGroup(run: DedupRun): bool =
  ## A group records one keeper at most; a soft-deleted keeper leaves none.
  for group in run.groups:
    var keepers = 0
    for member in group.members:
      if member.isKeeper: inc keepers
    if keepers > 1: return false
  true

func keepsNoPlannedMember(plan: seq[DedupMember]): bool =
  for member in plan:
    if member.isKeeper: return false
  true

func plansEachItemOnce(plan: seq[DedupMember]): bool =
  var seen = initHashSet[int64]()
  for member in plan:
    if member.itemId in seen: return false
    seen.incl member.itemId
  true

type HashRow = object
  id: int64
  path, exact: string
  phash: uint64
  hasPhash: bool

proc loadHashes(store: Store): seq[HashRow] =
  for row in store.db.getAllRows(sql"""
      SELECT i.id,i.rel_path,
        CASE WHEN i.hash_status='hashed' THEN h.blake3 ELSE '' END,
        h.phash,i.phash_status
      FROM items i
      JOIN item_hashes h ON h.item_id=i.id
      WHERE i.deleted_at IS NULL AND
        (i.hash_status='hashed' OR i.phash_status='hashed')
      ORDER BY i.rel_path"""):
    # `hashed` alone is not enough: an audio item is perceptually hashed too,
    # but into item_audio_hashes, leaving this column NULL.
    let hasPhash = row[4] == "hashed" and row[3].len > 0
    result.add HashRow(id: row[0].parseBiggestInt(), path: row[1], exact: row[2],
      phash: (if hasPhash: cast[uint64](row[3].parseBiggestInt()) else: 0'u64),
      hasPhash: hasPhash)

proc loadAudioFingerprint(store: Store; itemId: int64): AudioFingerprint =
  let row = store.db.getRow(sql"""
    SELECT duration,raw_json FROM item_audio_hashes WHERE item_id=?""", itemId)
  if row[0].len == 0: return
  result.durationSeconds =
    try: row[0].parseFloat()
    except ValueError: 0.0
  for node in parseJson(row[1]): result.raw.add uint32(node.getBiggestInt())

proc loadFrameHashes(store: Store; itemId: int64): seq[uint64] =
  ## Sampled frame hashes in time order. Empty for a still image, which carries
  ## its single hash in item_hashes instead.
  for row in store.db.getAllRows(sql"""
      SELECT phash FROM item_frame_hashes WHERE item_id=? ORDER BY seq""",
      itemId):
    result.add cast[uint64](row[0].parseBiggestInt())

proc persistGroup(store: Store; runId: int64; kind: string;
                  members: seq[tuple[row: HashRow; similarity: float]]) =
  store.db.exec(sql"INSERT INTO dedup_groups(run_id,kind) VALUES(?,?)", runId, kind)
  let groupId = store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()
  for index, member in members:
    store.db.exec(sql"INSERT INTO dedup_members(group_id,item_id,similarity,is_keeper) VALUES(?,?,?,?)",
      groupId, member.row.id, member.similarity, if index == 0: 1 else: 0)

proc findDuplicates*(store: var Store; kind = dkAll;
                     threshold = 95.0;
                     progress: ProgressCallback = nil;
                     cancel: CancelCallback = nil): int64 =
  if threshold != threshold or threshold < 0.0 or threshold > 100.0:
    raise newException(ValueError, "threshold must be between 0 and 100")
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"INSERT INTO dedup_runs(created_at,kind,threshold) VALUES(?,?,?)",
      isoNow(), $kind, threshold)
    result = store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()
    let rows = loadHashes(store)
    if kind in {dkExact, dkAll}:
      var byHash = initOrderedTable[string, seq[HashRow]]()
      for index, row in rows:
        checkCancelled(cancel)
        if row.exact.len > 0: byHash.mgetOrPut(row.exact, @[]).add row
        if progress != nil:
          progress(ProgressEvent(phase: "dedup-exact", current: index + 1,
            total: rows.len, message: row.path))
      for _, members in byHash:
        if members.len > 1:
          var group: seq[tuple[row: HashRow; similarity: float]]
          for member in members: group.add (member, 1.0)
          persistGroup(store, result, "exact", group)
    if kind in {dkVisual, dkAll}:
      var visual: seq[HashRow]
      # One tree entry per hash: an image contributes its own, a video one per
      # sampled frame. Two videos therefore meet on any frame they share, which
      # survives re-encoding and trimming, while groups stay per item.
      var entries: seq[tuple[item: int; value: uint64]]
      var hashesOf: seq[seq[uint64]]
      for row in rows:
        if not row.hasPhash: continue
        let item = visual.len
        visual.add row
        var values = loadFrameHashes(store, row.id)
        if values.len == 0: values = @[row.phash]
        hashesOf.add values
        for value in values: entries.add (item, value)
      var tree = initBkTree()
      for index, entry in entries:
        checkCancelled(cancel)
        tree.insert(Hash(entry.value), int32(index))
      let radius = int(floor((100.0 - threshold) * 64.0 / 100.0))
      var assigned = newSeq[bool](visual.len)
      for index, row in visual:
        checkCancelled(cancel)
        if assigned[index]: continue
        # Keep the best similarity per candidate item across every frame pair,
        # so the recorded score is the closest match rather than an arbitrary one.
        var best = initOrderedTable[int, float]()
        for value in hashesOf[index]:
          for match in tree.query(Hash(value), radius):
            let entry = entries[int(match[0])]
            if assigned[entry.item]: continue
            let score = similarity(Hash(value), Hash(entry.value))
            if entry.item notin best or score > best[entry.item]:
              best[entry.item] = score
        if best.len > 1:
          var members: seq[int]
          for candidate in best.keys: members.add candidate
          members.sort()
          var group: seq[tuple[row: HashRow; similarity: float]]
          for candidate in members:
            assigned[candidate] = true
            group.add (visual[candidate], best[candidate])
          persistGroup(store, result, "visual", group)
        if progress != nil:
          progress(ProgressEvent(phase: "dedup-visual", current: index + 1,
            total: visual.len, message: row.path))
    if kind in {dkAudio, dkAll}:
      # No tree here: fingerprints vary in length with the recording, so
      # grouping is a direct pairwise comparison over the loaded set.
      var audio: seq[HashRow]
      var prints: seq[AudioFingerprint]
      for row in rows:
        let print = loadAudioFingerprint(store, row.id)
        if print.raw.len == 0: continue
        audio.add row
        prints.add print
      var assigned = newSeq[bool](audio.len)
      for index, row in audio:
        checkCancelled(cancel)
        if assigned[index]: continue
        var group: seq[tuple[row: HashRow; similarity: float]]
        group.add (row, 1.0)
        for other in index + 1 ..< audio.len:
          if assigned[other]: continue
          let score = audioSimilarity(prints[index], prints[other])
          if score * 100.0 >= threshold:
            assigned[other] = true
            group.add (audio[other], score)
        if group.len > 1:
          assigned[index] = true
          persistGroup(store, result, "audio", group)
        if progress != nil:
          progress(ProgressEvent(phase: "dedup-audio", current: index + 1,
            total: audio.len, message: row.path))
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc loadDedupRun*(store: Store; requested = 0'i64): DedupRun {.contractual.} =
  ensure:
    result.id > 0
    atMostOneKeeperPerGroup(result)
  body:
    let idText = if requested > 0: $requested
                 else: store.db.getValue(sql"SELECT id FROM dedup_runs ORDER BY id DESC LIMIT 1")
    if idText.len == 0:
      raise newException(ValueError, "no dedup run available")
    let id = idText.parseBiggestInt()
    let run = store.db.getRow(sql"SELECT id,created_at,kind,threshold FROM dedup_runs WHERE id=?", id)
    if run[0].len == 0: raise newException(ValueError, "dedup run not found: " & $id)
    result = DedupRun(id: id, createdAt: run[1], kind: run[2], threshold: run[
        3].parseFloat())
    for groupRow in store.db.getAllRows(
        sql"SELECT id,kind FROM dedup_groups WHERE run_id=? ORDER BY id", id):
      var group = DedupGroup(id: groupRow[0].parseBiggestInt(), kind: groupRow[1])
      for member in store.db.getAllRows(
          sql"""
          SELECT m.item_id,i.rel_path,m.similarity,m.is_keeper FROM dedup_members m
          JOIN items i ON i.id=m.item_id WHERE m.group_id=? AND i.deleted_at IS NULL
          ORDER BY m.is_keeper DESC,i.rel_path""", group.id):
        group.members.add DedupMember(itemId: member[0].parseBiggestInt(),
          relPath: member[1], similarity: member[2].parseFloat(),
          isKeeper: member[3] == "1")
      result.groups.add group

proc setDedupKeeper*(store: var Store; groupId, itemId: int64) =
  ## Select exactly one active keeper in an existing duplicate group.
  if groupId <= 0 or itemId <= 0:
    raise newException(ValueError, "dedup group and item ids must be positive")
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    if store.db.getValue(sql"SELECT id FROM dedup_groups WHERE id=?",
        groupId).len == 0:
      raise newException(ValueError, "dedup group not found: " & $groupId)
    if store.db.getValue(sql"""
        SELECT 1 FROM dedup_members m JOIN items i ON i.id=m.item_id
        WHERE m.group_id=? AND m.item_id=? AND i.deleted_at IS NULL""",
        groupId, itemId).len == 0:
      raise newException(ValueError,
        "active item is not a member of duplicate group: " & $itemId)
    store.db.exec(sql"""
      UPDATE dedup_members SET is_keeper=CASE WHEN item_id=? THEN 1 ELSE 0 END
      WHERE group_id=?""", itemId, groupId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc planDedupRemoval*(store: Store;
                       requested = 0'i64): seq[DedupMember] {.contractual.} =
  ## Select every non-keeper once. The plan is read-only and deterministic.
  ensure:
    # Overlapping exact/visual groups must never cost a selected keeper, and an
    # item must not be scheduled for removal twice.
    keepsNoPlannedMember(result)
    plansEachItemOnce(result)
  body:
    let run = loadDedupRun(store, requested)
    var seen = initHashSet[int64]()
    var keepers = initHashSet[int64]()
    for group in run.groups:
      for member in group.members:
        if member.isKeeper: keepers.incl member.itemId
    for group in run.groups:
      for member in group.members:
        if not member.isKeeper and member.itemId notin keepers and
            member.itemId notin seen:
          result.add member
          seen.incl member.itemId
    result.sort(proc(a, b: DedupMember): int = cmp(a.relPath, b.relPath))

proc planDedupLinks*(store: Store; requested = 0'i64):
    seq[tuple[itemId, keeperId: int64]] {.contractual.} =
  ## Each non-keeper paired with the copy its group kept, for the runs where
  ## that pairing means something.
  ##
  ## **Exact groups only.** A visual or audio group holds files a perceptual
  ## hash called alike, which is not the same as identical — replacing one with
  ## a link to the other would throw away whichever was not kept. An item that
  ## appears in both an exact and a perceptual group is paired from the exact
  ## one and only once.
  ensure:
    # No keeper is ever the thing being replaced.
    result.allIt(it.itemId != it.keeperId)
  body:
    let run = loadDedupRun(store, requested)
    var keepers = initHashSet[int64]()
    for group in run.groups:
      for member in group.members:
        if member.isKeeper: keepers.incl member.itemId
    var seen = initHashSet[int64]()
    for group in run.groups:
      if group.kind != $dkExact: continue
      var keeper = 0'i64
      for member in group.members:
        if member.isKeeper: keeper = member.itemId
      if keeper == 0: continue
      for member in group.members:
        if member.isKeeper or member.itemId in keepers or
            member.itemId in seen: continue
        result.add (member.itemId, keeper)
        seen.incl member.itemId

proc applyDedupLinks*(store: var Store; requested = 0'i64;
                      only: seq[int64] = @[]): ApplyReport =
  ## Replace each byte-identical duplicate with a hard link to the copy that
  ## was kept: the space is freed and every path still opens.
  ##
  ## `only` narrows to those item ids, as it does for removal, and can only
  ## ever act on fewer.
  # Asked before the plan, not only inside linkDuplicates: building it means a
  # database lookup per pair, and on a network share that is minutes spent to
  # reach a refusal that was knowable at once.
  requireHardlinkSupport(store.library.root)
  recoverInterruptedBatches(store)
  var pairs = planDedupLinks(store, requested)
  if only.len > 0:
    let wanted = only.toHashSet()
    pairs = pairs.filterIt(it.itemId in wanted)
    if pairs.len == 0:
      raise newException(ValueError,
        "none of the requested items is a linkable member of this run")
  if pairs.len == 0:
    raise newException(ValueError,
      "this run has no byte-identical duplicate to link")
  linkDuplicates(store, pairs)

proc applyDedupRemoval*(store: var Store; requested = 0'i64;
                        only: seq[int64] = @[]): ApplyReport =
  ## Move non-keepers and their XMP sidecars into the journaled internal trash.
  ##
  ## `only` narrows the plan to those item ids, for a reviewer acting on one
  ## duplicate at a time. It can only ever remove *fewer* items: the plan still
  ## comes from planDedupRemoval, so a keeper stays protected whatever is asked.
  recoverInterruptedBatches(store)
  var candidates = planDedupRemoval(store, requested)
  if only.len > 0:
    let wanted = only.toHashSet()
    candidates = candidates.filterIt(it.itemId in wanted)
    if candidates.len == 0:
      raise newException(ValueError,
        "none of the requested items is a removable member of this run")
  if candidates.len == 0:
    raise newException(ValueError, "dedup run has no removable members")
  result = trashItems(store, candidates.mapIt(it.itemId))
