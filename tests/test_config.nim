# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[unittest, os, json, strutils]
import db_connector/db_sqlite
import UniMedia

proc fresh(name: string): string =
  result = getTempDir() / name
  if dirExists(result): removeDir(result)

# Read at compile time from the checkout the tests are compiled in, so the
# constant and the package manifest cannot drift apart unnoticed.
const manifest = staticRead(currentSourcePath.parentDir.parentDir /
  "UniMedia.nimble")

suite "package metadata":
  test "the version constant matches the package manifest":
    var declared = ""
    for line in manifest.splitLines:
      if line.startsWith("version"):
        declared = line.split('"')[1]
        break
    check declared == UniMediaVersion

suite "library configuration":
  test "init writes a strict portable configuration":
    let root = fresh("unimedia_config")
    let library = initLibrary(root, mdPhoto, osYearMonth)
    check library.root == absolutePath(root)
    check fileExists(root / ConfigName)
    check fileExists(root / DatabaseName)
    let config = readConfig(root)
    check config.domain == mdPhoto
    check config.scheme == osYearMonth
    removeDir(root)

  test "every closed organize scheme round-trips":
    for scheme in [osYearMonthDayDash, osYearMonthDay, osYearMonth,
                   osYearDate, osFlat]:
      check parseScheme($scheme) == scheme

  test "unknown keys are rejected":
    let root = fresh("unimedia_config_unknown")
    discard initLibrary(root, mdPhoto)
    var node = parseFile(root / ConfigName)
    node["surprise"] = %true
    writeFile(root / ConfigName, $node)
    expect ValueError:
      discard readConfig(root)
    removeDir(root)

  test "path traversal bucket is rejected":
    let root = fresh("unimedia_config_escape")
    createDir(root)
    var config = defaultLibraryConfig()
    config.noDateDir = "../outside"
    expect ValueError:
      writeConfig(root, config)
    removeDir(root)

  test "opening a library never recreates a missing database":
    let root = fresh("unimedia_missing_database")
    discard initLibrary(root, mdPhoto)
    moveFile(root / DatabaseName, root / "saved.db")
    expect IOError:
      discard openLibrary(root)
    check not fileExists(root / DatabaseName)
    moveFile(root / "saved.db", root / DatabaseName)
    removeDir(root)

  test "schema version one migrates pHash state without losing data":
    let root = fresh("unimedia_schema_v1")
    createDir(root)
    writeConfig(root, defaultLibraryConfig())
    var db = open(root / DatabaseName, "", "", "")
    db.exec(sql"""
      CREATE TABLE items (
        id INTEGER PRIMARY KEY, rel_path TEXT NOT NULL UNIQUE,
        file_size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
        category TEXT NOT NULL, extension TEXT NOT NULL,
        creation_date TEXT, date_source TEXT, width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0, hash_status TEXT NOT NULL DEFAULT 'pending',
        indexed_at TEXT NOT NULL)""")
    db.exec(sql"""
      CREATE TABLE item_hashes (
        item_id INTEGER PRIMARY KEY, blake3 TEXT, phash INTEGER,
        computed_at TEXT NOT NULL)""")
    db.exec(sql"""
      INSERT INTO items(id,rel_path,file_size,mtime_ns,category,extension,
        hash_status,indexed_at) VALUES(1,'old.ppm',1,1,'image','ppm','hashed','now')""")
    db.exec(sql"INSERT INTO item_hashes VALUES(1,'digest',123,'now')")
    db.exec(sql"PRAGMA user_version=1")
    db.close()
    var store = openLibrary(root)
    check store.db.getValue(sql"PRAGMA user_version") == "18"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name='geocode_cache'""") == "1"
    check store.getItem(1).phashStatus == "hashed"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name IN ('albums','album_items')""") == "2"
    check store.db.getValue(sql"""
      SELECT count(*) FROM pragma_table_info('albums') WHERE name='cover_item_id'""") == "1"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name IN ('item_curations','curation_ops')""") == "2"
    check store.db.getValue(sql"""
      SELECT count(*) FROM pragma_table_info('curation_ops')
      WHERE name IN ('creation_date','date_source','latitude','longitude',
        'location_text')""") == "5"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name IN ('smart_albums','smart_album_rules')""") == "2"
    check store.db.getValue(sql"""
      SELECT count(*) FROM pragma_table_info('items')
      WHERE name IN ('latitude','longitude','location_text','deleted_at')""") == "4"
    store.close()
    removeDir(root)

  test "schema version three gains album covers without losing albums":
    let root = fresh("unimedia_schema_v3")
    createDir(root)
    writeConfig(root, defaultLibraryConfig())
    var db = open(root / DatabaseName, "", "", "")
    db.exec(sql"""
      CREATE TABLE items (
        id INTEGER PRIMARY KEY, rel_path TEXT NOT NULL UNIQUE,
        file_size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
        category TEXT NOT NULL, extension TEXT NOT NULL,
        creation_date TEXT, date_source TEXT, width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0, hash_status TEXT NOT NULL DEFAULT 'pending',
        phash_status TEXT NOT NULL DEFAULT 'pending', indexed_at TEXT NOT NULL)""")
    db.exec(sql"""
      CREATE TABLE albums (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        created_at TEXT NOT NULL)""")
    db.exec(sql"""
      CREATE TABLE album_items (
        album_id INTEGER NOT NULL, item_id INTEGER NOT NULL,
        added_at TEXT NOT NULL, PRIMARY KEY(album_id,item_id))""")
    db.exec(sql"INSERT INTO albums VALUES(1,'Existing','now')")
    db.exec(sql"PRAGMA user_version=3")
    db.close()
    var store = openLibrary(root)
    check store.db.getValue(sql"PRAGMA user_version") == "18"
    check store.db.getValue(sql"SELECT name FROM albums WHERE id=1") == "Existing"
    check store.db.getValue(sql"""
      SELECT count(*) FROM pragma_table_info('albums') WHERE name='cover_item_id'""") == "1"
    store.close()
    removeDir(root)

  test "schema version seven preserves pending journal metadata":
    let root = fresh("unimedia_schema_v7")
    createDir(root)
    writeConfig(root, defaultLibraryConfig())
    var db = open(root / DatabaseName, "", "", "")
    db.exec(sql"""
      CREATE TABLE items (
        id INTEGER PRIMARY KEY, rel_path TEXT NOT NULL UNIQUE,
        file_size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
        category TEXT NOT NULL, extension TEXT NOT NULL,
        creation_date TEXT, date_source TEXT, width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0, hash_status TEXT NOT NULL DEFAULT 'pending',
        phash_status TEXT NOT NULL DEFAULT 'pending', latitude REAL,
        longitude REAL, location_text TEXT NOT NULL DEFAULT '',
        indexed_at TEXT NOT NULL)""")
    db.exec(sql"""
      CREATE TABLE curation_ops (
        id TEXT PRIMARY KEY, item_id INTEGER NOT NULL,
        sidecar_rel_path TEXT NOT NULL, old_exists INTEGER NOT NULL,
        old_xmp TEXT NOT NULL, new_xmp TEXT NOT NULL, title TEXT NOT NULL,
        description TEXT NOT NULL, rating INTEGER NOT NULL,
        favorite INTEGER NOT NULL, keywords_json TEXT NOT NULL,
        status TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL)""")
    db.exec(sql"""
      INSERT INTO items VALUES(1,'old.ppm',1,1,'image','ppm',
        '2024-01-02 03:04:05','curation',0,0,'hashed','pending',48.5,2.25,
        'Paris','now')""")
    db.exec(sql"""
      INSERT INTO curation_ops VALUES('pending',1,'old.ppm.xmp',0,'','xmp',
        'title','',0,0,'[]','pending',NULL,'now')""")
    db.exec(sql"PRAGMA user_version=7")
    db.close()
    var store = openLibrary(root)
    let row = store.db.getRow(sql"""
      SELECT creation_date,date_source,latitude,longitude,location_text
      FROM curation_ops WHERE id='pending'""")
    check row == @["2024-01-02 03:04:05", "curation", "48.5", "2.25", "Paris"]
    store.close()
    removeDir(root)

  test "schema version nine adds only the geocode cache":
    let root = fresh("unimedia_schema_v9")
    discard initLibrary(root, mdPhoto)
    var db = open(root / DatabaseName, "", "", "")
    db.exec(sql"DROP TABLE geocode_cache")
    db.exec(sql"PRAGMA user_version=9")
    db.close()
    var store = openLibrary(root)
    check store.db.getValue(sql"PRAGMA user_version") == "18"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name='geocode_cache'""") == "1"
    check store.db.getValue(sql"""
      SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name IN ('smart_albums','smart_album_rules')""") == "2"
    store.close()
    removeDir(root)

  when not defined(windows):
    test "symbolic library control files are rejected":
      let sandbox = fresh("unimedia_control_symlinks")
      createDir(sandbox)
      let root = sandbox / "library"
      discard initLibrary(root, mdPhoto)
      moveFile(root / ConfigName, sandbox / "config.json")
      createSymlink(sandbox / "config.json", root / ConfigName)
      expect ValueError:
        discard openLibrary(root)
      removeFile(root / ConfigName)
      moveFile(sandbox / "config.json", root / ConfigName)
      moveFile(root / DatabaseName, sandbox / "database.db")
      createSymlink(sandbox / "database.db", root / DatabaseName)
      expect ValueError:
        discard openLibrary(root)
      removeDir(sandbox)
