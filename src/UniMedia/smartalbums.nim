# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

## Validated, dynamically evaluated smart albums.

import std/[json, sets, strutils, times]
import db_connector/db_sqlite
import UniMedia/[types, store]

proc normalizedName(name: string): string =
  result = name.strip()
  if result.len == 0:
    raise newException(ValueError, "smart album name must not be empty")
  if result.len > 200:
    raise newException(ValueError, "smart album name must not exceed 200 characters")
  for ch in result:
    if ch < ' ':
      raise newException(ValueError,
        "smart album name must not contain control characters")

proc validateRule(rule: SmartRule): SmartRule =
  result = SmartRule(field: rule.field.toLowerAscii(),
    operator: rule.operator.toLowerAscii(), value: rule.value.strip())
  case result.field
  of "path", "title", "description", "keyword", "location":
    if result.operator notin ["contains", "eq", "ne"]:
      raise newException(ValueError, "invalid text rule operator: " &
          result.operator)
    if result.value.len == 0:
      raise newException(ValueError, "text rule value must not be empty")
    let maximum = if result.field == "keyword": 200 else: 1000
    if result.value.len > maximum:
      raise newException(ValueError, "smart album rule value is too long")
  of "rating":
    if result.operator notin ["eq", "ne", "gt", "gte", "lt", "lte"]:
      raise newException(ValueError, "invalid rating rule operator: " &
          result.operator)
    let rating = try: result.value.parseInt()
                 except ValueError: -1
    if rating notin 0..5:
      raise newException(ValueError, "rating rule value must be between 0 and 5")
  of "favorite", "gps":
    if result.operator notin ["eq", "ne"]:
      raise newException(ValueError, "invalid boolean rule operator: " &
          result.operator)
    result.value = result.value.toLowerAscii()
    if result.value notin ["true", "false"]:
      raise newException(ValueError, "boolean rule value must be true or false")
  of "date":
    if result.operator notin ["eq", "ne", "gt", "gte", "lt", "lte"]:
      raise newException(ValueError, "invalid date rule operator: " &
          result.operator)
    try:
      discard parse(result.value, "yyyy-MM-dd")
    except TimeParseError:
      raise newException(ValueError, "date rule value must use YYYY-MM-DD")
  of "kind":
    if result.operator notin ["eq", "ne"]:
      raise newException(ValueError, "invalid kind rule operator: " &
          result.operator)
    result.value = result.value.toLowerAscii()
    if result.value notin ["image", "video", "audio"]:
      raise newException(ValueError, "kind rule value must be image, video, or audio")
  else:
    raise newException(ValueError, "unknown smart album field: " & result.field)

proc rulesFor(store: Store; albumId: int64): seq[SmartRule] =
  for row in store.db.getAllRows(sql"""
      SELECT field,operator,value FROM smart_album_rules
      WHERE album_id=? ORDER BY seq""", albumId):
    result.add SmartRule(field: row[0], operator: row[1], value: row[2])

proc escapedLike(value: string): string =
  value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

proc idsForRule(store: Store; rule: SmartRule): HashSet[int64] =
  let op = case rule.operator
    of "eq": "="
    of "ne": "!="
    of "gt": ">"
    of "gte": ">="
    of "lt": "<"
    of "lte": "<="
    else: ""
  var rows: seq[Row]
  case rule.field
  of "path":
    if rule.operator == "contains":
      rows = store.db.getAllRows(sql"""
        SELECT id FROM items WHERE rel_path LIKE ? ESCAPE '\' COLLATE NOCASE""",
        "%" & escapedLike(rule.value) & "%")
    else:
      rows = store.db.getAllRows(sql("SELECT id FROM items WHERE rel_path " & op &
        " ? COLLATE NOCASE"), rule.value)
  of "title", "description":
    let column = if rule.field == "title": "title" else: "description"
    if rule.operator == "contains":
      rows = store.db.getAllRows(sql("SELECT i.id FROM items i LEFT JOIN " &
        "item_curations c ON c.item_id=i.id WHERE COALESCE(c." & column &
        ",'') LIKE ? ESCAPE '\\' COLLATE NOCASE"),
        "%" & escapedLike(rule.value) & "%")
    else:
      rows = store.db.getAllRows(sql("SELECT i.id FROM items i LEFT JOIN " &
        "item_curations c ON c.item_id=i.id WHERE COALESCE(c." & column &
        ",'') " & op & " ? COLLATE NOCASE"), rule.value)
  of "location":
    if rule.operator == "contains":
      rows = store.db.getAllRows(sql"""
        SELECT id FROM items WHERE location_text LIKE ? ESCAPE '\'
        COLLATE NOCASE""", "%" & escapedLike(rule.value) & "%")
    else:
      rows = store.db.getAllRows(sql("SELECT id FROM items WHERE location_text " &
        op & " ? COLLATE NOCASE"), rule.value)
  of "keyword":
    let expected = rule.value.toLowerAscii()
    if rule.operator == "ne":
      for item in store.listItems(): result.incl item.id
    for row in store.db.getAllRows(sql"""
        SELECT item_id,keywords_json FROM item_curations"""):
      var matched = false
      try:
        for node in parseJson(row[1]):
          let keyword = node.getStr().toLowerAscii()
          let equal = keyword == expected
          let contains = expected in keyword
          if (rule.operator in ["eq", "ne"] and equal) or
              (rule.operator == "contains" and contains):
            matched = true
            break
      except CatchableError:
        discard
      let itemId = row[0].parseBiggestInt()
      if rule.operator == "ne":
        if matched: result.excl itemId
      elif matched:
        result.incl itemId
    return
  of "rating":
    rows = store.db.getAllRows(sql("SELECT i.id FROM items i LEFT JOIN " &
      "item_curations c ON c.item_id=i.id WHERE COALESCE(c.rating,0) " & op &
      " CAST(? AS INTEGER)"),
      rule.value.parseInt())
  of "favorite":
    let value = if rule.value == "true": 1 else: 0
    rows = store.db.getAllRows(sql("SELECT i.id FROM items i LEFT JOIN " &
      "item_curations c ON c.item_id=i.id WHERE COALESCE(c.favorite,0) " & op &
      " CAST(? AS INTEGER)"),
      value)
  of "gps":
    let expected = (rule.value == "true") != (rule.operator == "ne")
    let comparison = if expected: "IS NOT NULL" else: "IS NULL"
    rows = store.db.getAllRows(sql("SELECT id FROM items WHERE latitude " &
      comparison & " AND longitude " & comparison))
  of "date":
    rows = store.db.getAllRows(sql("SELECT id FROM items WHERE " &
      "date(creation_date) " & op & " date(?)"), rule.value)
  of "kind":
    rows = store.db.getAllRows(sql("SELECT id FROM items WHERE category " & op &
      " ? COLLATE NOCASE"), rule.value)
  else:
    discard
  for row in rows: result.incl row[0].parseBiggestInt()

proc listSmartAlbumItems*(store: Store; albumId: int64): seq[Item] =
  let matchAll = store.db.getValue(sql"""
    SELECT match_all FROM smart_albums WHERE id=?""", albumId)
  if matchAll.len == 0:
    raise newException(ValueError, "smart album not found: " & $albumId)
  let rules = rulesFor(store, albumId)
  if rules.len == 0:
    raise newException(ValueError, "smart album has no rules: " & $albumId)
  var matches = idsForRule(store, rules[0])
  if rules.len > 1:
    for rule in rules[1..^1]:
      let ids = idsForRule(store, rule)
      if matchAll == "1": matches = matches * ids
      else: matches = matches + ids
  for item in store.listItems():
    if item.id in matches: result.add item

proc smartAlbumFromRow(store: Store; row: Row): SmartAlbum =
  result = SmartAlbum(id: row[0].parseBiggestInt(), name: row[1],
    matchAll: row[2] == "1", createdAt: row[3])
  result.rules = rulesFor(store, result.id)
  result.itemCount = listSmartAlbumItems(store, result.id).len

proc createSmartAlbum*(store: var Store; name: string; matchAll: bool;
                       rules: seq[SmartRule]): SmartAlbum =
  let normalized = normalizedName(name)
  if rules.len == 0:
    raise newException(ValueError, "smart album requires at least one rule")
  if rules.len > 20:
    raise newException(ValueError, "smart album must not exceed 20 rules")
  var validated: seq[SmartRule]
  for rule in rules: validated.add validateRule(rule)
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    if store.db.getValue(sql"SELECT id FROM albums WHERE name=? COLLATE NOCASE",
        normalized).len > 0 or store.db.getValue(
        sql"""
        SELECT id FROM smart_albums WHERE name=? COLLATE NOCASE""",
        normalized).len > 0:
      raise newException(ValueError, "album already exists: " & normalized)
    store.db.exec(sql"""
      INSERT INTO smart_albums(name,match_all,created_at) VALUES(?,?,?)""",
      normalized, ord(matchAll), isoNow())
    let id = store.db.getValue(sql"SELECT last_insert_rowid()").parseBiggestInt()
    for index, rule in validated:
      store.db.exec(sql"""
        INSERT INTO smart_album_rules(album_id,seq,field,operator,value)
        VALUES(?,?,?,?,?)""", id, index, rule.field, rule.operator, rule.value)
    result = smartAlbumFromRow(store, store.db.getRow(
        sql"""
      SELECT id,name,match_all,created_at FROM smart_albums WHERE id=?""", id))
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise

proc listSmartAlbums*(store: Store): seq[SmartAlbum] =
  for row in store.db.getAllRows(sql"""
      SELECT id,name,match_all,created_at FROM smart_albums
      ORDER BY name COLLATE NOCASE,id"""):
    result.add smartAlbumFromRow(store, row)

proc getSmartAlbum*(store: Store; id: int64): SmartAlbum =
  let row = store.db.getRow(sql"""
    SELECT id,name,match_all,created_at FROM smart_albums WHERE id=?""", id)
  if row[0].len == 0:
    raise newException(ValueError, "smart album not found: " & $id)
  smartAlbumFromRow(store, row)

proc deleteSmartAlbum*(store: var Store; id: int64) =
  discard getSmartAlbum(store, id)
  store.db.exec(sql"DELETE FROM smart_albums WHERE id=?", id)

proc renameSmartAlbum*(store: var Store; id: int64; name: string): SmartAlbum =
  let normalized = normalizedName(name)
  store.db.exec(sql"BEGIN IMMEDIATE")
  try:
    discard getSmartAlbum(store, id)
    if store.db.getValue(sql"SELECT id FROM albums WHERE name=? COLLATE NOCASE",
        normalized).len > 0 or store.db.getValue(
        sql"""
        SELECT id FROM smart_albums WHERE name=? COLLATE NOCASE AND id!=?""",
        normalized, id).len > 0:
      raise newException(ValueError, "album already exists: " & normalized)
    store.db.exec(sql"UPDATE smart_albums SET name=? WHERE id=?", normalized, id)
    result = getSmartAlbum(store, id)
    store.db.exec(sql"COMMIT")
  except CatchableError:
    store.db.exec(sql"ROLLBACK")
    raise


