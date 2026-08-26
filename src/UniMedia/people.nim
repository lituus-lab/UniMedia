# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Face-region registry. Detection backends submit normalized observations here.

import std/[algorithm, math, sequtils, sets, strutils]
import contracts
import db_connector/db_sqlite
import UniPercept
import UniMedia/[store, types]

proc listPeople*(store: Store): seq[Person]

proc validRegion(face: FaceDetection): bool =
  face.x >= 0 and face.y >= 0 and face.width > 0 and face.height > 0 and
    face.x + face.width <= 1 and face.y + face.height <= 1 and
    face.confidence >= 0 and face.confidence <= 1 and
    face.detector.strip.len > 0 and face.x.classify != fcNan and
    face.y.classify != fcNan and face.width.classify != fcNan and
    face.height.classify != fcNan and face.confidence.classify != fcNan

proc replaceFaces*(store: Store; itemId: int64;
                   detections: openArray[FaceDetection]) =
  discard store.getItem(itemId)
  if store.db.getValue(sql"SELECT 1 FROM faces WHERE item_id=? AND person_id IS NOT NULL LIMIT 1",
      itemId).len > 0:
    raise newException(ValueError,
      "cannot replace face observations with explicit person assignments")
  for face in detections:
    if not validRegion(face):
      raise newException(ValueError, "invalid normalized face region")
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    store.db.exec(sql"DELETE FROM faces WHERE item_id=?", itemId)
    for face in detections:
      store.db.exec(sql"""
        INSERT INTO faces(item_id,x,y,width,height,confidence,signature,
          signature_valid,detector,detected_at) VALUES(?,?,?,?,?,?,?,?,?,?)""",
        itemId, face.x, face.y,
        face.width, face.height, face.confidence, cast[int64](face.signature),
        ord(face.signatureValid), face.detector.strip, isoNow())
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc createPerson*(store: Store; name: string): int64 =
  let clean = name.strip
  if clean.len == 0 or clean.len > 200:
    raise newException(ValueError, "person name must contain 1 to 200 characters")
  store.db.exec(sql"INSERT INTO people(name,created_at) VALUES(?,?)", clean,
    isoNow())
  result = store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()

proc assignFace*(store: Store; faceId, personId: int64) =
  if store.db.getValue(sql"SELECT 1 FROM people WHERE id=?", personId).len == 0:
    raise newException(KeyError, "unknown person: " & $personId)
  if store.db.getValue(sql"SELECT 1 FROM faces WHERE id=?", faceId).len == 0:
    raise newException(KeyError, "unknown face: " & $faceId)
  store.db.exec(sql"UPDATE faces SET person_id=? WHERE id=?", personId, faceId)

proc assignFaceName*(store: Store; faceId: int64; name: string): Person =
  let clean = name.strip
  if clean.len == 0 or clean.len > 200:
    raise newException(ValueError, "person name must contain 1 to 200 characters")
  let existing = store.db.getRow(sql"SELECT id,name,created_at FROM people WHERE name=?",
    clean)
  let personId = if existing[0].len > 0: existing[0].parseBiggestInt()
    else: store.createPerson(clean)
  store.assignFace(faceId, personId)
  for person in store.listPeople():
    if person.id == personId: return person
  raise newException(IOError, "assigned person could not be reloaded")

proc clearFaces*(store: Store; itemId: int64; includeAssigned = false) =
  discard store.getItem(itemId)
  if not includeAssigned and store.db.getValue(
      sql"""SELECT 1 FROM faces
      WHERE item_id=? AND person_id IS NOT NULL LIMIT 1""", itemId).len > 0:
    raise newException(ValueError,
      "face observations have explicit assignments; confirm their removal")
  store.db.exec(sql"DELETE FROM faces WHERE item_id=?", itemId)

proc listPeople*(store: Store): seq[Person] =
  for row in store.db.fastRows(sql"""
      SELECT p.id,p.name,p.created_at,COUNT(f.id)
      FROM people p LEFT JOIN faces f ON f.person_id=p.id
      GROUP BY p.id ORDER BY p.name COLLATE NOCASE,p.id"""):
    result.add Person(id: row[0].parseBiggestInt(), name: row[1],
      createdAt: row[2], faceCount: row[3].parseInt())

proc listFaces*(store: Store; itemId = 0'i64): seq[Face] =
  let query = if itemId > 0: sql"""SELECT id,item_id,COALESCE(person_id,0),x,y,
    width,height,confidence,signature,signature_valid,detector,detected_at
    FROM faces WHERE item_id=? ORDER BY id"""
    else: sql"""SELECT id,item_id,COALESCE(person_id,0),x,y,width,height,
      confidence,signature,signature_valid,detector,detected_at
      FROM faces ORDER BY item_id,id"""
  let params = if itemId > 0: @[$itemId] else: @[]
  for row in store.db.fastRows(query, params):
    result.add Face(id: row[0].parseBiggestInt(), itemId: row[
        1].parseBiggestInt(),
      personId: row[2].parseBiggestInt(), x: row[3].parseFloat(),
      y: row[4].parseFloat(), width: row[5].parseFloat(),
      height: row[6].parseFloat(), confidence: row[7].parseFloat(),
      signature: cast[uint64](row[8].parseBiggestInt()),
      signatureValid: row[9] == "1", detector: row[10], detectedAt: row[11])

func partitionsFaces(clusters: seq[FaceCluster]): bool =
  ## Connected components are disjoint and non-empty: every face lands once.
  var seen = initHashSet[int64]()
  for cluster in clusters:
    if cluster.faceIds.len == 0: return false
    for faceId in cluster.faceIds:
      if faceId in seen: return false
      seen.incl faceId
  true

proc clusterFaces*(store: Store;
                   maxDistance = 10): seq[FaceCluster] {.contractual.} =
  ## Connected components of unassigned face signatures under Hamming distance.
  ensure:
    partitionsFaces(result)
  body:
    if maxDistance notin 0..32:
      raise newException(ValueError, "face cluster distance must be between 0 and 32")
    let faces = store.listFaces().filterIt(it.personId == 0 and
        it.signatureValid)
    var assigned = newSeq[bool](faces.len)
    for start in 0..<faces.len:
      if assigned[start]: continue
      assigned[start] = true
      var pending = @[start]
      var cluster = FaceCluster(representativeSignature: faces[start].signature)
      while pending.len > 0:
        let current = pending.pop()
        cluster.faceIds.add faces[current].id
        for candidate in 0..<faces.len:
          if not assigned[candidate] and hammingDistance(
              Hash(faces[current].signature), Hash(faces[
                  candidate].signature)) <=
              maxDistance:
            assigned[candidate] = true
            pending.add candidate
      cluster.faceIds.sort()
      result.add cluster
    result.sort(proc(a, b: FaceCluster): int = cmp(a.faceIds[0], b.faceIds[0]))
