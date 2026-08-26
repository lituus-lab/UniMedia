# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/strutils
import db_connector/db_sqlite
import UniMedia/[types, store]

proc normalizedAlbumName(name: string): string =
  result = name.strip()
  if result.len == 0:
    raise newException(ValueError, "album name must not be empty")
  if result.len > 200:
    raise newException(ValueError, "album name must not exceed 200 characters")
  for ch in result:
    if ch < ' ':
      raise newException(ValueError, "album name must not contain control characters")

proc albumFromRow(row: Row): Album =
  Album(id: row[0].parseBiggestInt(), name: row[1], createdAt: row[2],
    coverItemId: (if row[3].len > 0: row[3].parseBiggestInt() else: 0),
    itemCount: row[4].parseInt(),
    parentId: (if row.len > 5 and row[5].len > 0: row[5].parseBiggestInt()
    else: 0))

proc createAlbum*(store: var Store; name: string): Album =
  let normalized = normalizedAlbumName(name)
  let createdAt = isoNow()
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    if store.db.getValue(sql"SELECT id FROM albums WHERE name=? COLLATE NOCASE",
        normalized).len > 0 or store.db.getValue(
        sql"""
        SELECT id FROM smart_albums WHERE name=? COLLATE NOCASE""",
        normalized).len > 0:
      raise newException(ValueError, "album already exists: " & normalized)
    store.db.exec(sql"INSERT INTO albums(name,created_at) VALUES(?,?)",
      normalized,
      createdAt)
    let id = store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()
    result = Album(id: id, name: normalized, createdAt: createdAt)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc listAlbums*(store: Store): seq[Album] =
  for row in store.db.getAllRows(sql"""
      SELECT a.id,a.name,a.created_at,
        CASE WHEN cover.deleted_at IS NULL THEN a.cover_item_id ELSE NULL END,
        count(i.id), a.parent_id
      FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
      LEFT JOIN items i ON i.id=ai.item_id AND i.deleted_at IS NULL
      LEFT JOIN items cover ON cover.id=a.cover_item_id
      GROUP BY a.id,a.name,a.created_at,a.cover_item_id,cover.deleted_at,
        a.parent_id
      ORDER BY a.name COLLATE NOCASE,a.id"""):
    result.add albumFromRow(row)

proc getAlbum*(store: Store; id: int64): Album =
  let row = store.db.getRow(sql"""
    SELECT a.id,a.name,a.created_at,
      CASE WHEN cover.deleted_at IS NULL THEN a.cover_item_id ELSE NULL END,
      count(i.id), a.parent_id
    FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
    LEFT JOIN items i ON i.id=ai.item_id AND i.deleted_at IS NULL
    LEFT JOIN items cover ON cover.id=a.cover_item_id
    WHERE a.id=? GROUP BY a.id,a.name,a.created_at,a.cover_item_id,
      cover.deleted_at,a.parent_id""", id)
  if row[0].len == 0:
    raise newException(ValueError, "album not found: " & $id)
  albumFromRow(row)

proc listAlbumItems*(store: Store; albumId: int64): seq[Item] =
  discard store.getAlbum(albumId)
  for row in store.db.getAllRows(sql"""
      SELECT ai.item_id FROM album_items ai JOIN items i ON i.id=ai.item_id
      WHERE ai.album_id=? AND i.deleted_at IS NULL
      ORDER BY ai.added_at,ai.item_id""", albumId):
    result.add store.getItem(row[0].parseBiggestInt())

proc addAlbumItem*(store: var Store; albumId, itemId: int64): bool =
  discard store.getAlbum(albumId)
  discard store.getItem(itemId)
  store.db.exec(sql"INSERT OR IGNORE INTO album_items(album_id,item_id,added_at) VALUES(?,?,?)",
    albumId, itemId, isoNow())
  store.db.getValue(sql"SELECT changes()") == "1"

proc removeAlbumItem*(store: var Store; albumId, itemId: int64): bool =
  discard store.getAlbum(albumId)
  store.db.exec(sql"DELETE FROM album_items WHERE album_id=? AND item_id=?", albumId,
    itemId)
  store.db.getValue(sql"SELECT changes()") == "1"

proc renameAlbum*(store: var Store; albumId: int64; name: string): Album =
  let normalized = normalizedAlbumName(name)
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    discard store.getAlbum(albumId)
    if store.db.getValue(sql"""
        SELECT id FROM albums WHERE name=? COLLATE NOCASE AND id!=?""",
        normalized, albumId).len > 0:
      raise newException(ValueError, "album already exists: " & normalized)
    if store.db.getValue(sql"""
        SELECT id FROM smart_albums WHERE name=? COLLATE NOCASE""",
        normalized).len > 0:
      raise newException(ValueError, "album already exists: " & normalized)
    store.db.exec(sql"UPDATE albums SET name=? WHERE id=?", normalized, albumId)
    result = store.getAlbum(albumId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc setAlbumCover*(store: var Store; albumId, itemId: int64): Album =
  if itemId <= 0:
    raise newException(ValueError, "album cover item id must be positive")
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    discard store.getAlbum(albumId)
    discard store.getItem(itemId)
    if store.db.getValue(sql"""
        SELECT 1 FROM album_items WHERE album_id=? AND item_id=?""", albumId,
        itemId).len == 0:
      raise newException(ValueError, "album cover must be one of its items")
    store.db.exec(sql"UPDATE albums SET cover_item_id=? WHERE id=?", itemId,
      albumId)
    result = store.getAlbum(albumId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc clearAlbumCover*(store: var Store; albumId: int64): Album =
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    discard store.getAlbum(albumId)
    store.db.exec(sql"UPDATE albums SET cover_item_id=NULL WHERE id=?", albumId)
    result = store.getAlbum(albumId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc deleteAlbum*(store: var Store; albumId: int64) =
  discard store.getAlbum(albumId)
  store.db.exec(sql"DELETE FROM albums WHERE id=?", albumId)


proc setAlbumParent*(store: var Store; albumId, parentId: int64): Album =
  ## Move an album inside another, or to the top with a `parentId` of 0.
  ##
  ## A cycle is refused: an album cannot be its own ancestor, and neither can a
  ## chain of them close on itself. The check walks upwards from the proposed
  ## parent, so it costs the depth of the tree and catches a loop of any
  ## length rather than only the obvious one-step case.
  if albumId == parentId:
    raise newException(ValueError, "an album cannot contain itself")
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    if store.db.getValue(sql"SELECT id FROM albums WHERE id=?", albumId).len == 0:
      raise newException(ValueError, "album not found: " & $albumId)
    if parentId != 0:
      if store.db.getValue(sql"SELECT id FROM albums WHERE id=?",
          parentId).len == 0:
        raise newException(ValueError, "album not found: " & $parentId)
      var ancestor = parentId
      var steps = 0
      while ancestor != 0:
        if ancestor == albumId:
          raise newException(ValueError,
            "that would put the album inside itself")
        inc steps
        if steps > MaxAlbumDepth:
          raise newException(ValueError, "album nesting is too deep")
        let next = store.db.getValue(sql"SELECT parent_id FROM albums WHERE id=?",
          ancestor)
        ancestor = if next.len > 0: next.parseBiggestInt() else: 0
    if parentId == 0:
      store.db.exec(sql"UPDATE albums SET parent_id=NULL WHERE id=?", albumId)
    else:
      store.db.exec(sql"UPDATE albums SET parent_id=? WHERE id=?", parentId,
        albumId)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise
  getAlbum(store, albumId)

proc listChildAlbums*(store: Store; parentId: int64): seq[Album] =
  ## The albums directly inside `parentId`, or those at the top when it is 0.
  ## One level, not the whole subtree: a caller drawing a tree asks again.
  let rows = if parentId == 0:
      store.db.getAllRows(sql"""
        SELECT a.id,a.name,a.created_at,
          CASE WHEN cover.deleted_at IS NULL THEN a.cover_item_id ELSE NULL END,
          count(i.id), a.parent_id
        FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
        LEFT JOIN items i ON i.id=ai.item_id AND i.deleted_at IS NULL
        LEFT JOIN items cover ON cover.id=a.cover_item_id
        WHERE a.parent_id IS NULL
        GROUP BY a.id,a.name,a.created_at,a.cover_item_id,cover.deleted_at,
          a.parent_id
        ORDER BY a.name COLLATE NOCASE,a.id""")
    else:
      store.db.getAllRows(sql"""
        SELECT a.id,a.name,a.created_at,
          CASE WHEN cover.deleted_at IS NULL THEN a.cover_item_id ELSE NULL END,
          count(i.id), a.parent_id
        FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
        LEFT JOIN items i ON i.id=ai.item_id AND i.deleted_at IS NULL
        LEFT JOIN items cover ON cover.id=a.cover_item_id
        WHERE a.parent_id=?
        GROUP BY a.id,a.name,a.created_at,a.cover_item_id,cover.deleted_at,
          a.parent_id
        ORDER BY a.name COLLATE NOCASE,a.id""", parentId)
  for row in rows: result.add albumFromRow(row)
