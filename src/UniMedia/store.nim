# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/[options, os, strutils]
import db_connector/db_sqlite
import contracts
import UniMedia/[types, config]

const DatabaseName* = ".organizeMedia.db"
  ## Hidden, like the configuration beside it. A catalogue is the library's own
  ## bookkeeping and has no business showing up among somebody's photographs
  ## when they open the folder.

const TrashDirName* = ".om-trash"
  ## Where a journaled removal keeps what it took, under the library root.
  ## Dotted, so a scan skips it: what is in the trash is not in the library.

const LegacyDatabaseName* = "organizeMedia.db"
  ## What the catalogue was called before it was hidden. A library written then
  ## is renamed on the next open rather than being reported as no library at
  ## all, and the WAL files travel with it or SQLite refuses the result.

const CurrentSchema* = 18
  ## The schema this build writes and accepts. A database past it is refused
  ## rather than migrated backwards, and the number lives here so the guard and
  ## the last forward step cannot disagree — they did, and a test that fixed
  ## the version by hand is what caught it.

type Store* = object
  library*: Library
  db*: DbConn

proc createAlbumCoverTrigger(db: DbConn) =
  db.exec(sql"""
    CREATE TRIGGER clear_album_cover_after_member_delete
    AFTER DELETE ON album_items
    WHEN OLD.item_id=(SELECT cover_item_id FROM albums WHERE id=OLD.album_id)
    BEGIN
      UPDATE albums SET cover_item_id=NULL WHERE id=OLD.album_id;
    END""")

proc createAlbumSchema(db: DbConn) =
  db.exec(sql"""
    CREATE TABLE albums (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL COLLATE NOCASE UNIQUE,
      created_at TEXT NOT NULL,
      cover_item_id INTEGER,
      -- An album inside another. Deleting a parent lifts its children to the
      -- top rather than taking them with it: an album lists items it does not
      -- own, and neither does a parent own a child.
      parent_id INTEGER REFERENCES albums(id) ON DELETE SET NULL,
      FOREIGN KEY(cover_item_id) REFERENCES items(id) ON DELETE SET NULL
    )""")
  db.exec(sql"""
    CREATE TABLE album_items (
      album_id INTEGER NOT NULL,
      item_id INTEGER NOT NULL,
      added_at TEXT NOT NULL,
      PRIMARY KEY(album_id,item_id),
      FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")
  db.exec(sql"CREATE INDEX idx_album_items_item ON album_items(item_id)")
  createAlbumCoverTrigger(db)

proc createCurationSchema(db: DbConn; journalMetadata = true) =
  db.exec(sql"""
    CREATE TABLE item_curations (
      item_id INTEGER PRIMARY KEY,
      title TEXT NOT NULL DEFAULT '',
      description TEXT NOT NULL DEFAULT '',
      rating INTEGER NOT NULL DEFAULT 0 CHECK(rating BETWEEN 0 AND 5),
      favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)),
      keywords_json TEXT NOT NULL DEFAULT '[]',
      creator_json TEXT NOT NULL DEFAULT '[]',
      copyright TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL,
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")
  let metadataColumns = if journalMetadata: """
      creation_date TEXT NOT NULL DEFAULT '',
      date_source TEXT NOT NULL DEFAULT '',
      latitude REAL,
      longitude REAL,
      location_text TEXT NOT NULL DEFAULT '',
""" else: ""
  db.exec(sql("""
    CREATE TABLE curation_ops (
      id TEXT PRIMARY KEY,
      item_id INTEGER NOT NULL,
      sidecar_rel_path TEXT NOT NULL,
      old_exists INTEGER NOT NULL CHECK(old_exists IN (0,1)),
      old_xmp TEXT NOT NULL,
      new_xmp TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      rating INTEGER NOT NULL CHECK(rating BETWEEN 0 AND 5),
      favorite INTEGER NOT NULL CHECK(favorite IN (0,1)),
      keywords_json TEXT NOT NULL,
      creator_json TEXT NOT NULL DEFAULT '[]',
      copyright TEXT NOT NULL DEFAULT '',
""" & metadataColumns &
      """
      status TEXT NOT NULL CHECK(status IN ('pending','applied','failed')),
      error TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )"""))
  db.exec(sql"""
    CREATE UNIQUE INDEX idx_curation_ops_active_item
    ON curation_ops(item_id) WHERE status='pending'""")

proc createSmartAlbumSchema(db: DbConn) =
  db.exec(sql"""
    CREATE TABLE smart_albums (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL COLLATE NOCASE UNIQUE,
      match_all INTEGER NOT NULL CHECK(match_all IN (0,1)),
      created_at TEXT NOT NULL
    )""")
  db.exec(sql"""
    CREATE TABLE smart_album_rules (
      album_id INTEGER NOT NULL,
      seq INTEGER NOT NULL,
      field TEXT NOT NULL,
      operator TEXT NOT NULL,
      value TEXT NOT NULL,
      PRIMARY KEY(album_id,seq),
      FOREIGN KEY(album_id) REFERENCES smart_albums(id) ON DELETE CASCADE
    )""")

proc createAudioHashSchema(db: DbConn) =
  ## One fingerprint per audio item. Stored whole rather than one row per
  ## sub-fingerprint: matching is a pairwise bit comparison in Nim, so there is
  ## nothing for SQLite to index.
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS item_audio_hashes (
      item_id INTEGER PRIMARY KEY,
      duration REAL NOT NULL,
      raw_json TEXT NOT NULL,
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")

proc createFrameHashSchema(db: DbConn) =
  ## Per-frame perceptual hashes. An image needs only item_hashes.phash; a video
  ## keeps one row per sampled frame so a trim or re-encode still overlaps.
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS item_frame_hashes (
      item_id INTEGER NOT NULL,
      seq INTEGER NOT NULL,
      phash INTEGER NOT NULL,
      PRIMARY KEY(item_id,seq),
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")
  db.exec(sql"""CREATE INDEX IF NOT EXISTS idx_item_frame_hashes_phash
    ON item_frame_hashes(phash)""")

proc createGeocodeCacheSchema(db: DbConn) =
  db.exec(sql"""
    CREATE TABLE geocode_cache (
      provider TEXT NOT NULL,
      language TEXT NOT NULL,
      latitude_e6 INTEGER NOT NULL,
      longitude_e6 INTEGER NOT NULL,
      location_text TEXT NOT NULL,
      attribution TEXT NOT NULL,
      fetched_at TEXT NOT NULL,
      PRIMARY KEY(provider,language,latitude_e6,longitude_e6)
    )""")

proc createIntelligenceSchema(db: DbConn) =
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS people (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL COLLATE NOCASE UNIQUE,
      created_at TEXT NOT NULL
    )""")

  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS faces (
      id INTEGER PRIMARY KEY,
      item_id INTEGER NOT NULL,
      person_id INTEGER,
      x REAL NOT NULL CHECK(x BETWEEN 0 AND 1),
      y REAL NOT NULL CHECK(y BETWEEN 0 AND 1),
      width REAL NOT NULL CHECK(width > 0 AND width <= 1),
      height REAL NOT NULL CHECK(height > 0 AND height <= 1),
      confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
      signature INTEGER NOT NULL DEFAULT 0,
      signature_valid INTEGER NOT NULL DEFAULT 0 CHECK(signature_valid IN (0,1)),
      detector TEXT NOT NULL,
      detected_at TEXT NOT NULL,
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE,
      FOREIGN KEY(person_id) REFERENCES people(id) ON DELETE SET NULL
    )""")

  db.exec(sql"CREATE INDEX IF NOT EXISTS idx_faces_item ON faces(item_id)")
  db.exec(sql"CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id)")
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS vision_documents (
      item_id INTEGER NOT NULL,
      model TEXT NOT NULL,
      caption TEXT NOT NULL DEFAULT '',
      labels_json TEXT NOT NULL DEFAULT '[]',
      embedding_json TEXT NOT NULL,
      dimensions INTEGER NOT NULL CHECK(dimensions > 0),
      updated_at TEXT NOT NULL,
      PRIMARY KEY(item_id,model),
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS vision_annotations (
      item_id INTEGER NOT NULL,
      model TEXT NOT NULL,
      caption TEXT NOT NULL,
      labels_json TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(item_id,model),
      FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
    )""")
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS sync_runs (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      remote TEXT NOT NULL,
      direction TEXT NOT NULL CHECK(direction IN ('push','pull')),
      dry_run INTEGER NOT NULL CHECK(dry_run IN (0,1)),
      status TEXT NOT NULL CHECK(status IN ('planned','applied','failed')),
      started_at TEXT NOT NULL,
      finished_at TEXT,
      summary TEXT NOT NULL DEFAULT ''
    )""")

proc hasTable(db: DbConn; table: string): bool =
  ## A hand-built or partial database may lack a table a forward step wants to
  ## alter; ALTER TABLE on a missing table is an error, PRAGMA is not.
  db.getValue(sql"""SELECT count(*) FROM sqlite_master
    WHERE type='table' AND name=?""", table) != "0"

proc hasColumn(db: DbConn; table, column: string): bool =
  ## SQLite has no ADD COLUMN IF NOT EXISTS, so a forward step checks first and
  ## stays repeatable. The table name reaches PRAGMA unparameterised, hence the
  ## closed list.
  if table notin ["albums", "faces", "items", "item_curations", "curation_ops"]:
    raise newException(ValueError, "unsupported schema inspection table")
  for row in db.fastRows(SqlQuery("PRAGMA table_info(" & table & ")")):
    if row[1] == column: return true

proc migrate(db: DbConn) =
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA synchronous=NORMAL")
  db.exec(sql"PRAGMA foreign_keys=ON")
  db.exec(sql"PRAGMA busy_timeout=5000")
  let version = try: db.getValue(sql"PRAGMA user_version").parseInt()
                except ValueError: 0
  if version > CurrentSchema:
    raise newException(ValueError, "database schema is newer than this UniMedia build")
  if version == 0:
    db.exec(sql"BEGIN IMMEDIATE")
    try:
      db.exec(sql"""
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          rel_path TEXT NOT NULL UNIQUE,
          file_size INTEGER NOT NULL,
          mtime_ns INTEGER NOT NULL,
          category TEXT NOT NULL,
          extension TEXT NOT NULL,
          creation_date TEXT,
          date_source TEXT,
          width INTEGER DEFAULT 0,
          height INTEGER DEFAULT 0,
          hash_status TEXT NOT NULL DEFAULT 'pending',
          phash_status TEXT NOT NULL DEFAULT 'pending',
          latitude REAL,
          longitude REAL,
          location_text TEXT NOT NULL DEFAULT '',
          source TEXT NOT NULL DEFAULT 'file',
          meta_json TEXT NOT NULL DEFAULT '',
          deleted_at TEXT,
          indexed_at TEXT NOT NULL
        )""")
      db.exec(sql"""
        CREATE TABLE item_hashes (
          item_id INTEGER PRIMARY KEY,
          blake3 TEXT,
          phash INTEGER,
          computed_at TEXT NOT NULL,
          FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        )""")
      db.exec(sql"CREATE INDEX idx_item_hashes_blake3 ON item_hashes(blake3)")
      db.exec(sql"CREATE INDEX idx_item_hashes_phash ON item_hashes(phash)")
      createFrameHashSchema(db)
      createAudioHashSchema(db)
      db.exec(sql"""
        CREATE TABLE dedup_runs (
          id INTEGER PRIMARY KEY,
          created_at TEXT NOT NULL,
          kind TEXT NOT NULL,
          threshold REAL NOT NULL
        )""")
      db.exec(sql"""
        CREATE TABLE dedup_groups (
          id INTEGER PRIMARY KEY,
          run_id INTEGER NOT NULL,
          kind TEXT NOT NULL,
          FOREIGN KEY(run_id) REFERENCES dedup_runs(id) ON DELETE CASCADE
        )""")
      db.exec(sql"""
        CREATE TABLE dedup_members (
          group_id INTEGER NOT NULL,
          item_id INTEGER NOT NULL,
          similarity REAL NOT NULL,
          is_keeper INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(group_id, item_id),
          FOREIGN KEY(group_id) REFERENCES dedup_groups(id) ON DELETE CASCADE,
          FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        )""")
      db.exec(sql"""
        CREATE TABLE batches (
          id TEXT PRIMARY KEY,
          created_at TEXT NOT NULL,
          source_root TEXT NOT NULL,
          mode TEXT NOT NULL,
          status TEXT NOT NULL,
          error TEXT
        )""")
      db.exec(sql"""
        CREATE TABLE batch_ops (
          id INTEGER PRIMARY KEY,
          batch_id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          kind TEXT NOT NULL,
          source_path TEXT NOT NULL,
          dest_rel_path TEXT NOT NULL,
          content_hash TEXT,
          status TEXT NOT NULL,
          error TEXT,
          UNIQUE(batch_id, seq),
          FOREIGN KEY(batch_id) REFERENCES batches(id) ON DELETE CASCADE
        )""")
      createAlbumSchema(db)
      createCurationSchema(db)
      createSmartAlbumSchema(db)
      createGeocodeCacheSchema(db)
      createIntelligenceSchema(db)
      db.exec(sql"CREATE INDEX idx_items_location ON items(location_text)")
      db.exec(sql"CREATE INDEX idx_items_geo ON items(latitude,longitude)")
      db.exec(sql"CREATE INDEX idx_items_active ON items(deleted_at,rel_path)")
      db.exec(sql"PRAGMA user_version=17")
      db.exec(sql"COMMIT")
    except CatchableError:
      db.exec(sql"ROLLBACK")
      raise
  else:
    var current = version
    if current == 1:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"ALTER TABLE items ADD COLUMN phash_status TEXT NOT NULL DEFAULT 'pending'")
        db.exec(sql"""
          UPDATE items SET phash_status='hashed' WHERE id IN (
            SELECT item_id FROM item_hashes WHERE phash IS NOT NULL AND phash != 0
          )""")
        db.exec(sql"UPDATE items SET phash_status='not-applicable' WHERE category!='image'")
        db.exec(sql"PRAGMA user_version=2")
        db.exec(sql"COMMIT")
        current = 2
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 2:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createAlbumSchema(db)
        db.exec(sql"PRAGMA user_version=4")
        db.exec(sql"COMMIT")
        current = 4
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 3:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"""
          ALTER TABLE albums ADD COLUMN cover_item_id INTEGER
          REFERENCES items(id) ON DELETE SET NULL""")
        createAlbumCoverTrigger(db)
        db.exec(sql"PRAGMA user_version=4")
        db.exec(sql"COMMIT")
        current = 4
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 4:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createCurationSchema(db, journalMetadata = false)
        db.exec(sql"PRAGMA user_version=5")
        db.exec(sql"COMMIT")
        current = 5
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 5:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createSmartAlbumSchema(db)
        db.exec(sql"PRAGMA user_version=6")
        db.exec(sql"COMMIT")
        current = 6
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 6:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"ALTER TABLE items ADD COLUMN latitude REAL")
        db.exec(sql"ALTER TABLE items ADD COLUMN longitude REAL")
        db.exec(sql"ALTER TABLE items ADD COLUMN location_text TEXT NOT NULL DEFAULT ''")
        db.exec(sql"CREATE INDEX idx_items_location ON items(location_text)")
        db.exec(sql"CREATE INDEX idx_items_geo ON items(latitude,longitude)")
        db.exec(sql"PRAGMA user_version=7")
        db.exec(sql"COMMIT")
        current = 7
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 7:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"ALTER TABLE curation_ops ADD COLUMN creation_date TEXT NOT NULL DEFAULT ''")
        db.exec(sql"ALTER TABLE curation_ops ADD COLUMN date_source TEXT NOT NULL DEFAULT ''")
        db.exec(sql"ALTER TABLE curation_ops ADD COLUMN latitude REAL")
        db.exec(sql"ALTER TABLE curation_ops ADD COLUMN longitude REAL")
        db.exec(sql"ALTER TABLE curation_ops ADD COLUMN location_text TEXT NOT NULL DEFAULT ''")
        db.exec(sql"""
          UPDATE curation_ops SET
            creation_date=COALESCE((SELECT creation_date FROM items
              WHERE items.id=curation_ops.item_id),''),
            date_source=COALESCE((SELECT date_source FROM items
              WHERE items.id=curation_ops.item_id),''),
            latitude=(SELECT latitude FROM items
              WHERE items.id=curation_ops.item_id),
            longitude=(SELECT longitude FROM items
              WHERE items.id=curation_ops.item_id),
            location_text=COALESCE((SELECT location_text FROM items
              WHERE items.id=curation_ops.item_id),'')""")
        db.exec(sql"PRAGMA user_version=8")
        db.exec(sql"COMMIT")
        current = 8
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 8:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"ALTER TABLE items ADD COLUMN deleted_at TEXT")
        db.exec(sql"CREATE INDEX idx_items_active ON items(deleted_at,rel_path)")
        db.exec(sql"PRAGMA user_version=9")
        db.exec(sql"COMMIT")
        current = 9
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 9:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createGeocodeCacheSchema(db)
        db.exec(sql"PRAGMA user_version=10")
        db.exec(sql"COMMIT")
        current = 10
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 10:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createIntelligenceSchema(db)
        db.exec(sql"PRAGMA user_version=11")
        db.exec(sql"COMMIT")
        current = 11
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 11:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        if not db.hasColumn("faces", "signature"):
          db.exec(sql"ALTER TABLE faces ADD COLUMN signature INTEGER NOT NULL DEFAULT 0")
        if not db.hasColumn("faces", "signature_valid"):
          db.exec(sql"ALTER TABLE faces ADD COLUMN signature_valid INTEGER NOT NULL DEFAULT 0")
        db.exec(sql"PRAGMA user_version=12")
        db.exec(sql"COMMIT")
        current = 12
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 12:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        db.exec(sql"""CREATE TABLE IF NOT EXISTS vision_annotations (
          item_id INTEGER NOT NULL,
          model TEXT NOT NULL,
          caption TEXT NOT NULL,
          labels_json TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(item_id,model),
          FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        )""")
        db.exec(sql"PRAGMA user_version=13")
        db.exec(sql"COMMIT")
        current = 13
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 13:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createFrameHashSchema(db)
        # Video was marked not-applicable when only images could be hashed.
        # Re-queue it so the next scan samples frames.
        db.exec(sql"""UPDATE items SET phash_status='pending'
          WHERE category='video' AND phash_status='not-applicable'""")
        db.exec(sql"PRAGMA user_version=14")
        db.exec(sql"COMMIT")
        current = 14
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 14:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        if not db.hasColumn("items", "source"):
          db.exec(sql"""ALTER TABLE items
            ADD COLUMN source TEXT NOT NULL DEFAULT 'file'""")
        if not db.hasColumn("items", "meta_json"):
          db.exec(sql"""ALTER TABLE items
            ADD COLUMN meta_json TEXT NOT NULL DEFAULT ''""")
        db.exec(sql"PRAGMA user_version=15")
        db.exec(sql"COMMIT")
        current = 15
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 15:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        # Both tables: recoverCurationOps rebuilds the stored state from the
        # journal, so a column missing there would be erased by a recovery.
        for table in ["item_curations", "curation_ops"]:
          if not db.hasTable(table): continue
          if not db.hasColumn(table, "creator_json"):
            db.exec(sql("ALTER TABLE " & table &
              " ADD COLUMN creator_json TEXT NOT NULL DEFAULT '[]'"))
          if not db.hasColumn(table, "copyright"):
            db.exec(sql("ALTER TABLE " & table &
              " ADD COLUMN copyright TEXT NOT NULL DEFAULT ''"))
        db.exec(sql"PRAGMA user_version=16")
        db.exec(sql"COMMIT")
        current = 16
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 16:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        createAudioHashSchema(db)
        # Audio was parked as not-applicable when only images and video could
        # be hashed perceptually; re-queue it for the next scan.
        db.exec(sql"""UPDATE items SET phash_status='pending'
          WHERE category='audio' AND phash_status='not-applicable'""")
        db.exec(sql"PRAGMA user_version=17")
        db.exec(sql"COMMIT")
        current = 17
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
    if current == 17:
      db.exec(sql"BEGIN IMMEDIATE")
      try:
        # A database rebuilt from an old version may not carry the table at
        # all, and ALTER TABLE on a missing one is an error where PRAGMA is
        # not — which is why every forward step here asks first.
        if db.hasTable("albums") and not db.hasColumn("albums", "parent_id"):
          db.exec(sql"""ALTER TABLE albums ADD COLUMN parent_id INTEGER
            REFERENCES albums(id) ON DELETE SET NULL""")
        db.exec(sql("PRAGMA user_version=" & $CurrentSchema))
        db.exec(sql"COMMIT")
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise

proc libraryExists*(root: string): bool =
  ## Whether `root` already carries a library's own files.
  ##
  ## A caller asks this before offering to create one: a folder holding neither
  ## is a candidate for `initLibrary`, and one holding either is not, whether or
  ## not it opens. Read-only, and it never looks at the media.
  let base = normalizedPath(absolutePath(root))
  fileExists(base / ConfigName) or symlinkExists(base / ConfigName) or
    fileExists(base / DatabaseName) or symlinkExists(base / DatabaseName) or
    fileExists(base / LegacyDatabaseName) or
    symlinkExists(base / LegacyDatabaseName)

proc initLibrary*(root: string; domain: MediaDomain;
                  scheme = osYearMonthDayDash): Library =
  result.root = normalizedPath(absolutePath(root))
  let configPath = result.root / ConfigName
  let databasePath = result.root / DatabaseName
  if fileExists(configPath) or symlinkExists(configPath) or
      fileExists(databasePath) or symlinkExists(databasePath):
    raise newException(IOError, "library already initialized: " & result.root)
  result.config = defaultLibraryConfig(domain)
  result.config.scheme = scheme
  var db: DbConn
  try:
    writeConfig(result.root, result.config)
    db = open(databasePath, "", "", "")
    migrate(db)
  except CatchableError:
    if db != nil:
      db.close()
      db = nil
    for suffix in ["-shm", "-wal", ""]:
      let path = databasePath & suffix
      if fileExists(path): removeFile(path)
    if fileExists(configPath): removeFile(configPath)
    raise
  finally:
    if db != nil: db.close()

proc hideLegacyDatabase(root: string) =
  ## Move a catalogue written under the old visible name, with its WAL files.
  ##
  ## Only when there is nothing under the new name: two catalogues in one
  ## folder is somebody's mistake to look at, not one to resolve by picking.
  let legacy = root / LegacyDatabaseName
  let hidden = root / DatabaseName
  if not fileExists(legacy) or symlinkExists(legacy): return
  if fileExists(hidden) or symlinkExists(hidden): return
  for suffix in ["", "-wal", "-shm"]:
    let source = legacy & suffix
    if fileExists(source) and not symlinkExists(source):
      moveFile(source, hidden & suffix)

proc openLibrary*(root: string): Store =
  result.library.root = normalizedPath(absolutePath(root))
  if symlinkExists(result.library.root):
    raise newException(ValueError, "library root must not be a symbolic link: " & root)
  hideLegacyDatabase(result.library.root)
  result.library.config = readConfig(result.library.root)
  if not fileExists(result.library.root / DatabaseName):
    raise newException(IOError, "invalid om library (missing " & DatabaseName &
      "): " & result.library.root)
  if symlinkExists(result.library.root / DatabaseName):
    raise newException(ValueError, "library database must not be a symbolic link")
  result.db = open(result.library.root / DatabaseName, "", "", "")
  try:
    migrate(result.db)
  except CatchableError:
    result.db.close()
    result.db = nil
    raise

proc close*(store: var Store) = store.db.close()

proc checkedPathUnder*(root, path: string): string =
  let safeRoot = normalizedPath(absolutePath(root))
  if symlinkExists(safeRoot):
    raise newException(ValueError, "allowed root must not be a symbolic link: " & root)
  result = normalizedPath(absolutePath(path))
  if result != safeRoot and not result.startsWith(safeRoot & DirSep):
    raise newException(ValueError, "path escapes its allowed root: " & path)
  let relPath = relCatalogPath(result, safeRoot)
  var cursor = safeRoot
  for part in relPath.split({DirSep, AltSep}):
    if part.len == 0 or part == ".": continue
    if part == "..":
      raise newException(ValueError, "path escapes its allowed root: " & path)
    cursor = cursor / part
    if symlinkExists(cursor):
      raise newException(ValueError, "path contains a symbolic link: " & path)

proc absoluteItemPath*(store: Store; relPath: string): string =
  if relPath.len == 0 or relPath.isAbsolute:
    raise newException(ValueError, "item path must be relative: " & relPath)
  checkedPathUnder(store.library.root, store.library.root / relPath)

proc itemFromRow(row: Row): Item =
  proc optionalFloat(value: string): Option[float] =
    if value.len == 0: return none(float)
    try: some(value.parseFloat())
    except ValueError:
      raise newException(ValueError, "invalid coordinate in catalogue")
  Item(id: row[0].parseBiggestInt(), relPath: row[1],
    fileSize: row[2].parseBiggestInt(), mtimeNs: row[3].parseBiggestInt(),
    category: row[4], extension: row[5], creationDate: row[6],
    dateSource: row[7], width: row[8].parseInt(), height: row[9].parseInt(),
    hashStatus: row[10], phashStatus: row[11],
    latitude: optionalFloat(row[12]), longitude: optionalFloat(row[13]),
    locationText: row[14], source: row[15], metaJson: row[16])

const ItemColumns =
  "id,rel_path,file_size,mtime_ns,category,extension,creation_date," &
  "date_source,width,height,hash_status,phash_status,latitude,longitude," &
  "location_text,source,meta_json"

proc listItems*(store: Store; kind = ""): seq[Item] =
  let query = if kind.len == 0:
    sql("SELECT " & ItemColumns &
      " FROM items WHERE deleted_at IS NULL ORDER BY rel_path")
  else:
    sql("SELECT " & ItemColumns &
      " FROM items WHERE deleted_at IS NULL AND category=? ORDER BY rel_path")
  let rows = if kind.len == 0: store.db.getAllRows(query)
             else: store.db.getAllRows(query, kind)
  for row in rows:
    result.add itemFromRow(row)

proc listItemsPage*(store: Store; kind = ""; limit = 100;
                    offset = 0): seq[Item] {.contractual.} =
  ## Return a stable bounded page ordered by relative path.
  ensure:
    # The page bound is the contract a virtualized grid relies on; the limit
    # itself stays a runtime check, since callers supply it.
    result.len <= limit
  body:
    if limit notin 1 .. 10_000:
      raise newException(ValueError,
        "catalog page limit must be between 1 and 10000")
    if offset < 0:
      raise newException(ValueError, "catalog page offset must not be negative")
    let query = if kind.len == 0:
      sql("SELECT " & ItemColumns &
        " FROM items WHERE deleted_at IS NULL ORDER BY rel_path LIMIT ? OFFSET ?")
    else:
      sql("SELECT " & ItemColumns &
        " FROM items WHERE deleted_at IS NULL AND category=? " &
        "ORDER BY rel_path LIMIT ? OFFSET ?")
    let rows = if kind.len == 0: store.db.getAllRows(query, limit, offset)
               else: store.db.getAllRows(query, kind, limit, offset)
    for row in rows:
      result.add itemFromRow(row)

proc countItems*(store: Store; kind = ""): int =
  ## Count active catalogue items, optionally restricted by category.
  let value = if kind.len == 0:
    store.db.getValue(sql"SELECT count(*) FROM items WHERE deleted_at IS NULL")
  else:
    store.db.getValue(sql"""
      SELECT count(*) FROM items WHERE deleted_at IS NULL AND category=?""", kind)
  value.parseInt()

proc getItem*(store: Store; id: int64): Item =
  let row = store.db.getRow(sql("SELECT " & ItemColumns &
    " FROM items WHERE id=? AND deleted_at IS NULL"), id)
  if row[0].len == 0:
    raise newException(ValueError, "catalog item not found: " & $id)
  itemFromRow(row)

proc escapedLike(value: string): string =
  value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

proc searchItems*(store: Store; query: string; kind = "";
                  limit = 100; offset = 0): seq[Item] =
  if query.len == 0:
    raise newException(ValueError, "catalog search query must not be empty")
  if limit notin 1..10_000:
    raise newException(ValueError, "catalog search limit must be between 1 and 10000")
  if offset < 0:
    raise newException(ValueError, "catalog search offset must not be negative")
  let pattern = "%" & escapedLike(query) & "%"
  let matches = "(i.rel_path LIKE ? ESCAPE '\\' COLLATE NOCASE OR " &
    "c.title LIKE ? ESCAPE '\\' COLLATE NOCASE OR " &
    "c.description LIKE ? ESCAPE '\\' COLLATE NOCASE OR " &
    "c.keywords_json LIKE ? ESCAPE '\\' COLLATE NOCASE)"
  let statement = if kind.len == 0:
    sql("SELECT " & ItemColumns & " FROM items WHERE deleted_at IS NULL " &
      "AND id IN (SELECT i.id " &
      "FROM items i LEFT JOIN item_curations c ON c.item_id=i.id WHERE " &
      matches & ") ORDER BY rel_path LIMIT ? OFFSET ?")
  else:
    sql("SELECT " & ItemColumns & " FROM items WHERE deleted_at IS NULL " &
      "AND category=? AND id IN " &
      "(SELECT i.id FROM items i LEFT JOIN item_curations c ON c.item_id=i.id " &
      "WHERE " & matches & ") ORDER BY rel_path LIMIT ? OFFSET ?")
  let rows = if kind.len == 0:
    store.db.getAllRows(statement, pattern, pattern, pattern, pattern, limit,
      offset)
  else:
    store.db.getAllRows(statement, kind, pattern, pattern, pattern, pattern,
      limit, offset)
  for row in rows:
    result.add itemFromRow(row)
