// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/*
 * UniMedia.h — C ABI for UniMedia (local-first media catalogue)
 *
 * A Nim media engine exposed to C: open a library, scan it, page through its
 * items, find and review duplicates, and plan an organize run.
 *
 * Lifecycle:
 *   - Call um_init() before any other function. Repeated calls are no-ops;
 *     externally synchronize the first call.
 *   - um_library is opaque. The library owns it; release with um_library_close.
 *
 * Reports:
 *   - Every report crosses as a NUL-terminated UTF-8 JSON string that the
 *     library allocates and the caller releases with um_buffer_free. Never
 *     free() it: it does not come from malloc.
 *   - One call per report, so an operation that costs something or changes
 *     something -- a scan, a duplicate run -- happens exactly once.
 *   - Field names match what the `om` CLI prints with --json.
 *
 * Thread-safety:
 *   - The thread that opens a library owns it. A handle must not be used
 *     concurrently from several threads without external synchronisation.
 *   - um_last_error is thread-local.
 *
 * Error model:
 *   - Functions returning int return a um_status. No exception or fault from
 *     the Nim core crosses this boundary. um_last_error() describes the most
 *     recent failure on the calling thread.
 *
 * Schema:
 *   - The catalogue schema never crosses this ABI. No table, column, migration
 *     number or SQLite handle is exposed, so a migration cannot break a linked
 *     caller.
 *
 * ABI stability:
 *   - UNIMEDIA_ABI_VERSION rises when an entry point is added as well as when
 *     one changes shape, so it answers "does the call I want exist"; check it at
 *     runtime with um_abi_version().
 */
#ifndef UNIMEDIA_H
#define UNIMEDIA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UNIMEDIA_ABI_VERSION 1

typedef enum {
  UM_OK = 0,
  UM_ERR_INIT = 1,     /* um_init was not called */
  UM_ERR_HANDLE = 2,   /* unknown or already closed handle */
  UM_ERR_ARG = 3,      /* null pointer, or an out-of-range argument */
  UM_ERR_LIBRARY = 4,  /* the root is not a usable library */
  UM_ERR_RUNTIME = 5,  /* the engine refused the request */
  UM_ERR_CANCELLED = 6 /* reserved for the mutating surface */
} um_status;

/* Opaque library handle. */
typedef void *um_library;

/* Progress and cancellation. Both run on the calling thread and must not
 * re-enter the library. `user_data` is passed back untouched; either may be
 * NULL. A non-zero um_cancel_fn stops the run at its next cooperative
 * boundary, which returns UM_ERR_CANCELLED and rolls back the transaction. */
typedef void (*um_progress_fn)(const char *phase, int current, int total,
                               const char *message, void *user_data);
typedef int (*um_cancel_fn)(void *user_data);

/* Must be called once before anything else. */
int um_init(void);

/* ABI version of this build, to compare against UNIMEDIA_ABI_VERSION. */
int um_abi_version(void);

/* Engine version, e.g. "1.0.0". Owned by the library; do not free. */
const char *um_engine_version(void);

/* Most recent error on this thread, "" when there is none. Owned by the
 * library; valid until the next failing call on the same thread. */
const char *um_last_error(void);

/* Release a JSON string produced by this ABI. NULL is accepted. */
void um_buffer_free(void *buffer);

/* Open an existing library rooted at `root`. */
int um_library_open(const char *root, um_library *handle);

/* Whether `root` already holds a library. Deliberately distinct from whether
 * it opens: a folder that was never a library invites creating one, while a
 * library whose config is unreadable must show that error instead. */
int um_library_exists(const char *root, int *present);

/* Create a library at `root` and open it, in one call -- creating and opening
 * separately would leave a window where the files exist and the caller holds
 * nothing. `domain` is photo|video|music|visual; `scheme` may be NULL or "" for
 * the default layout. Only the config and the catalogue are written: no media
 * file is read, moved or modified, and a root already holding either is
 * refused rather than overwritten. */
int um_library_init(const char *root, const char *domain, const char *scheme,
                    um_library *handle);

/* Close a library and invalidate its handle. */
int um_library_close(um_library handle);

/* The library preferences, as stored in `.organizemedia.json` at the root:
 * {"schemaVersion","domain","scheme","filenameDate","birthtimeDate",
 * "noDateDir","onConflict"}. "birthtimeDate" accepts the filesystem's
 * creation time as a capture date; off, because on a copied library it is
 * the date of the copy.
 * domain is photo|video|music|visual, scheme is one of YYYY/MM-DD, YYYY/MM/DD,
 * YYYY/MM, YYYY/YYYY-MM-DD, flat, and onConflict is suffix|skip. */
int um_config_json(um_library handle, char **out_json);

/* Merge `settings` -- a JSON object holding any subset of the keys above,
 * except schemaVersion -- into the preferences, and rewrite the file. An
 * absent key keeps its value; an unknown key or an invalid value returns
 * UM_ERR_ARG and changes nothing, on disk or in the handle. */
int um_config_set(um_library handle, const char *settings);

/* How many items still owe a perceptual hash. A scan told to skip that work
 * leaves them pending; duplicate detection is the only thing that needs it,
 * and asks this first so it can say how much is left. */
int um_phash_pending_count(um_library handle, int *count);

/* Reconcile the catalogue against the disk. `skip_phash` defers perceptual
 * hashing. Report: {"indexed","updated","removed","hashErrors"}. */
int um_scan(um_library handle, int skip_phash, um_progress_fn on_progress,
            um_cancel_fn on_cancel, void *user_data, char **out_json);

/* Active item count, optionally restricted to a media kind ("image", "video",
 * …). Pass NULL for every kind. */
int um_item_count(um_library handle, const char *kind, int *count);

/* One page of items as a JSON array, ordered by relative path. */
int um_items_json(um_library handle, const char *kind, int limit, int offset,
                  char **out_json);

/* Group duplicates. `kind` is "exact", "visual" or "all" (NULL means "all");
 * `threshold` is a percentage in 0..100. Writes the run id. */
int um_dedup_find(um_library handle, const char *kind, double threshold,
                  um_progress_fn on_progress, um_cancel_fn on_cancel,
                  void *user_data, int64_t *run_id);

/* A duplicate run as JSON: {"run","kind","threshold","groups":[…]}. Pass
 * run_id 0 for the most recent run. */
int um_dedup_review_json(um_library handle, int64_t run_id, char **out_json);

/* A display-oriented PNG for `item_id`, generated on a cache miss. `max_edge`
 * is bounded 16..4096. The caller renders the returned path and never decodes
 * or caches a second time. Report:
 * {"item","path","width","height","maxEdge","cacheHit"}. */
int um_thumbnail_json(um_library handle, int64_t item_id, int max_edge,
                      char **out_json);

/* Plan an organize run over `source` without changing anything. Report:
 * {"sourceRoot","operations":[…]}. */
/* `scheme` overrides the library's own preference for this call: one of
 * "YYYY/MM-DD", "YYYY/MM/DD", "YYYY/MM", "YYYY/YYYY-MM-DD", "flat". NULL or ""
 * keeps the library preference. */
int um_organize_plan_json(um_library handle, const char *source,
                          const char *scheme, int keep_duplicates,
                          char **out_json);

/* File `source` into the library. `mode` is "copy" (default when NULL), "move"
 * or "hardlink". The plan is rebuilt here, so a file that appeared since the
 * caller displayed one is caught by the same conflict rules.
 *
 * A non-zero `keep_duplicates` copies a file even where an identical one
 * already holds its place, suffixing it _1, _2 and so on; zero treats the same
 * bytes under the same name as one file, so importing a folder that holds its
 * own backup writes one copy. Journalled: an
 * interruption is reconciled by the next run, so this takes no cancel hook.
 * Report: {"batch","applied","skipped","failed"}. */
int um_organize_apply(um_library handle, const char *source, const char *mode,
                      const char *scheme, int keep_duplicates,
                      um_progress_fn on_progress, void *user_data,
                      char **out_json);

/* What undoing `batch` would do, changing nothing. NULL or "" selects the most
 * recent batch. */
int um_undo_plan_json(um_library handle, const char *batch, char **out_json);

/* Undo `batch`, verifying journalled content hashes before restoring. Report:
 * {"batch","undone","skipped","failed"}. */
int um_undo_apply(um_library handle, const char *batch,
                  um_progress_fn on_progress, void *user_data,
                  char **out_json);

/* Choose the one active member of `group_id` a removal must not touch. */
int um_dedup_keep(um_library handle, int64_t group_id, int64_t item_id);

/* Remove non-keepers of `run_id` (0 = most recent) into the hash-verified
 * trash; um_undo_apply restores them. Report:
 * {"batch","applied","skipped","failed"}. */
int um_dedup_remove(um_library handle, int64_t run_id, char **out_json);

/* What an item carries, read from its XMP sidecar:
 * {"item","title","description","rating","favorite","keywords":[...],
 *  "creator":[...],"copyright","creationDate","dateSource","latitude",
 *  "longitude","location","updatedAt"}. */
int um_curation_json(um_library handle, int64_t item_id, char **out_json);

/* Apply `patch` -- a JSON object -- to one item, and return what it holds
 * afterwards in the shape above. An absent key preserves the field; an empty
 * string or array clears the property. Accepted keys: title, description,
 * rating, favorite, keywords, creator, copyright, addKeywords,
 * removeKeywords, creationDate, latitude, longitude, clearGps, location.
 * An unknown key or an invalid value returns UM_ERR_ARG and changes nothing. */
int um_curate_item(um_library handle, int64_t item_id, const char *patch,
                   char **out_json);

/* The same patch across a selection. `item_ids` is a non-empty JSON array.
 * Report: {"applied","failed","failures":[{"item","path","error"}]}. Failures
 * are per item: one unwritable sidecar does not abandon the rest. Cancellation
 * is observed between items, never during a sidecar replacement. */
int um_curation_batch_apply(um_library handle, const char *item_ids,
                            const char *patch, um_progress_fn on_progress,
                            um_cancel_fn on_cancel, void *user_data,
                            char **out_json);

/* Keywords already in use and how many items carry each, most used first:
 * [{"keyword","count"}]. `prefix` may be NULL. */
int um_keywords_json(um_library handle, const char *prefix, int limit,
                     char **out_json);

/* What a date correction would change, changing nothing. `mode` is "set" --
 * `value` is an absolute date, "YYYY-MM-DD HH:MM:SS" -- or "shift", where
 * `value` is a signed whole number of seconds. `item_ids` is a non-empty JSON
 * array. Report: {"entries":[{"item","path","oldDate","newDate","writesFile"}]}.
 * "writesFile" is false for a container with no writer here: that item's
 * catalogue entry is corrected and its file keeps the date its camera wrote,
 * which every other program will go on reading. */
int um_dates_plan_json(um_library handle, const char *item_ids,
                       const char *mode, const char *value, char **out_json);

/* Apply that correction, in the catalogue and in each file that has a writer
 * here. The plan is rebuilt, and the engine refuses one whose items changed
 * underneath it.
 *
 * The file rewrites go into one journalled batch: the original moves to the
 * library's trash and the corrected copy takes its place, so um_undo_apply
 * restores it byte for byte. "written" counts the files actually rewritten,
 * which is not "applied" — a container with no writer still has its catalogue
 * entry corrected. "batch" is empty when nothing was written.
 * Report: {"applied","written","batch","failed",
 *          "failures":[{"item","path","error"}]}. */
int um_dates_apply(um_library handle, const char *item_ids, const char *mode,
                   const char *value, um_progress_fn on_progress,
                   um_cancel_fn on_cancel, void *user_data, char **out_json);

/* Which items a GPX track would place, and how far each match is in time.
 * `item_ids` may be NULL or "[]" for the whole catalogue. `tolerance_seconds`
 * is 0..86400; `camera_utc_offset_minutes` is -840..840, for a camera clock
 * set to local time.
 *
 * An item that already carries a position is reported with "alreadyPlaced"
 * true and "matched" false: a camera's own fix is usually better than one
 * interpolated from a track, so it is kept. A non-zero `refresh` places those
 * items too, over the ids given or the whole catalogue when none are.
 * Report: {"source","toleranceSeconds","cameraUtcOffsetMinutes",
 * "trackPointCount","refreshed","entries":[{"item","path","creationDate",
 * "matched","alreadyPlaced","distanceSeconds","latitude","longitude"}]}. */
int um_gpx_plan_json(um_library handle, const char *gpx_path,
                     const char *item_ids, int tolerance_seconds,
                     int camera_utc_offset_minutes, int refresh,
                     char **out_json);

/* Write the matched coordinates. Refused outright when nothing matches, so an
 * empty run cannot read as a successful one; when every item was kept because
 * it already carries a position, the refusal says that rather than reporting
 * no matches. `refresh` is read as in um_gpx_plan_json.
 * Report: {"applied","failed","failures":[{"item","path","error"}]}. */
int um_gpx_apply(um_library handle, const char *gpx_path, const char *item_ids,
                 int tolerance_seconds, int camera_utc_offset_minutes,
                 int refresh, um_progress_fn on_progress,
                 um_cancel_fn on_cancel, void *user_data, char **out_json);

/* Every batch that put something in the trash, newest first.
 * Report: {"batches":[{"batch","when","mode","status","files","bytes",
 *          "undoable"}]}. "undoable" needs both a batch that was applied and
 * files still there to put back; either alone is not a way back. A batch whose
 * directory is gone still appears with a count of zero, because the row is what
 * explains its status. */
int um_trash_list_json(um_library handle, char **out_json);

/* Delete what those batches kept. THIS IS WHERE RECOVERABILITY ENDS: the files
 * go for good and um_undo_apply can no longer reach them.
 *
 * `batch_ids` is a JSON array; NULL or "[]" means every batch at least
 * `older_than_days` old, and zero days means all of them. Each batch is marked
 * before its files go, so an interruption leaves one undo refuses by name
 * rather than one that fails on every path it cannot find. Refused with
 * UM_ERR_ARG when nothing matches, rather than reporting a run that freed
 * nothing as a success.
 * Report: {"batches","files","freedBytes","failed"}. */
int um_trash_empty(um_library handle, const char *batch_ids,
                   int older_than_days, um_progress_fn on_progress,
                   void *user_data, char **out_json);

/* What a cleanup would take away, taking nothing. `kinds` is a JSON array of
 * "apple-double", "os-junk", "orphan-sidecar", "empty-dir", "interrupted";
 * NULL or "[]" means every kind.
 *
 * Report: {"entries":[{"kind","path","size","removable","reason"}]}. An entry
 * with "removable" false was found and is being reported, not proposed: an
 * AppleDouble carrying a Finder tag is where that tag lives when the filesystem
 * cannot hold it beside the file. "reason" says why, either way. */
int um_cleanup_plan_json(um_library handle, const char *kinds, char **out_json);

/* Move what the plan marked removable into the journaled trash, so
 * um_undo_apply brings it back. The plan is rebuilt here from the same kinds.
 * An empty directory is removed rather than trashed: it held nothing for the
 * trash to keep. Refused with UM_ERR_ARG when nothing in the plan can be
 * removed, rather than reporting a run that did nothing as a success.
 *
 * A non-zero `permanently` deletes instead of trashing. NOTHING COMES BACK
 * FROM THAT, and "batch" is empty in the report because there is no batch.
 * Report: {"batch","removed","kept","failed"}. */
int um_cleanup_apply(um_library handle, const char *kinds, int permanently,
                     um_progress_fn on_progress, void *user_data,
                     char **out_json);

/* What each item still discloses, as a JSON array of
 * {"item","path","signals":[...],"error"}. A signal is "gps", "camera",
 * "software" or "identity"; "error" says why an item could not be read. */
int um_privacy_audit_json(um_library handle, char **out_json);

/* What a strip would touch, changing nothing. `item_ids` is a JSON array;
 * NULL or "[]" means every item the audit reported.
 * Report: {"entries":[{"item","path","signals":[...],"strippable"}]}.
 * "strippable" is false where the format carries the metadata but the editor
 * cannot rewrite it — a video, a TIFF. Apply passes those over rather than
 * failing the batch, so a caller that ignores the flag reports work that did
 * not happen. */
int um_privacy_strip_plan_json(um_library handle, const char *item_ids,
                               char **out_json);

/* Strip the metadata from that selection. The plan is rebuilt here, so a
 * caller cannot apply one it displayed before the library moved on.
 * Journalled: the original is kept and um_undo_apply restores it. Not
 * cancellable once the journal is committed.
 * Report: {"batch","applied","skipped","failed"}. */
int um_privacy_strip_apply(um_library handle, const char *item_ids,
                           um_progress_fn on_progress, void *user_data,
                           char **out_json);

/* Remove catalogued items outright: `item_ids` is a JSON array of ids, e.g.
 * "[3,7,12]". They move to the journaled trash like any other removal, so
 * um_undo_apply brings them back. An id that is unknown or already removed
 * fails the whole request before anything moves.
 * Report: {"batch","applied","skipped","failed"}. */
int um_items_remove(um_library handle, const char *item_ids, char **out_json);

/* Remove one reviewed duplicate of `run_id`. Removes strictly fewer files than
 * um_dedup_remove: the plan still excludes keepers, so asking for a protected
 * item removes nothing. Report: {"batch","applied","skipped","failed"}. */
int um_dedup_remove_item(um_library handle, int64_t run_id, int64_t item_id,
                         char **out_json);

/* Read-only consistency audit over catalogued paths, sizes and — unless
 * `verify_hashes` is 0 — streaming BLAKE3. Report:
 * {"checked","missing","changed","hashMismatches","databaseErrors",
 *  "findings":[…]}. */
int um_integrity_audit_json(um_library handle, int verify_hashes,
                            um_progress_fn on_progress, um_cancel_fn on_cancel,
                            void *user_data, char **out_json);

/* ---- Albums --------------------------------------------------------------
 * An album is a list somebody curated; a smart album is a query that produces
 * one. Both are reported the same way, so a caller shows them side by side. */

/* Every album, with its item count and cover. */
/* um_scan with a bound on how many files are hashed at once. Zero uses every
 * core, which is what um_scan does; a number leaves the rest of the machine
 * usable while a large import runs. */
int um_scan_bounded(um_library handle, int skip_phash, int jobs,
                    um_progress_fn on_progress, um_cancel_fn on_cancel,
                    void *user_data, char **out_json);

/* Which duplicates could be replaced by a hard link to the copy kept, and
 * which copy that is. Read-only. Byte-identical groups only: files a
 * perceptual hash called alike are not the same file, and linking them would
 * throw away whichever was not kept. */
int um_dedup_link_plan_json(um_library handle, long long run_id,
                            char **out_json);
/* Do it. Journalled like a removal and undone by um_undo_apply: the file goes
 * to the trash first and the link is recorded after it, so undo takes the link
 * away and puts the file back. */
int um_dedup_link(um_library handle, long long run_id, char **out_json);

int um_albums_json(um_library handle, char **out_json);
/* One album by identifier. */
int um_album_json(um_library handle, long long album_id, char **out_json);
/* The items an album holds, in the order it holds them. */
int um_album_items_json(um_library handle, long long album_id, char **out_json);
/* Create an album and return it, so the caller learns its identifier without a
 * second call. */
int um_album_create(um_library handle, const char *name, char **out_json);
/* Rename an album and return it as it now stands. */
int um_album_rename(um_library handle, long long album_id, const char *name,
                    char **out_json);
/* Delete an album. The items it held are untouched: an album lists them, it
 * never owns them. */
int um_album_delete(um_library handle, long long album_id);
/* Put an item in an album. added is 0 when it was already there, which is not
 * a failure -- adding twice is how a caller makes sure. */
int um_album_add_item(um_library handle, long long album_id, long long item_id,
                      int *added);
/* Take an item out. removed is 0 when it was not in the album. */
int um_album_remove_item(um_library handle, long long album_id,
                         long long item_id, int *removed);
/* Move an album inside another, or to the top with a parent_id of 0. A cycle
 * is refused: an album cannot be its own ancestor, and neither can a chain of
 * them close on itself. */
int um_album_set_parent(um_library handle, long long album_id,
                        long long parent_id, char **out_json);
/* The albums directly inside parent_id, or those at the top when it is 0. One
 * level, so a caller drawing a tree asks again for each branch it opens. */
int um_album_children_json(um_library handle, long long parent_id,
                           char **out_json);

/* Set an album's cover, or clear it by passing an item id of 0. */
int um_album_set_cover(um_library handle, long long album_id,
                       long long item_id, char **out_json);

/* Every smart album, with the rules that define it. */
int um_smart_albums_json(um_library handle, char **out_json);
/* One smart album by identifier. */
int um_smart_album_json(um_library handle, long long album_id, char **out_json);
/* What a smart album currently matches. Evaluated on the call, so it answers
 * for the library as it stands, not as it stood when the album was made. */
int um_smart_album_items_json(um_library handle, long long album_id,
                              char **out_json);
/* Create a smart album from rules given as JSON: an array of
 * {"field":...,"operator":...,"value":...}. match_all non-zero requires every
 * rule. The rules are checked by the engine, so it and the caller cannot
 * disagree about what is valid. */
int um_smart_album_create(um_library handle, const char *name, int match_all,
                          const char *rules_json, char **out_json);
int um_smart_album_rename(um_library handle, long long album_id,
                          const char *name, char **out_json);
int um_smart_album_delete(um_library handle, long long album_id);

/* ---- People and faces ----------------------------------------------------
 * A face is a rectangle the detector found; a person is a name several faces
 * were attached to. Detection is optional, so a library with none reports an
 * empty list rather than failing. */

int um_people_json(um_library handle, char **out_json);
/* Faces in one item, or in the whole library when item_id is 0. */
int um_faces_json(um_library handle, long long item_id, char **out_json);
int um_person_create(um_library handle, const char *name, long long *person_id);
int um_face_assign(um_library handle, long long face_id, long long person_id);
/* Attach a face to a person named name, creating that person if there is none
 * -- which is what naming a face in an interface means. */
int um_face_assign_name(um_library handle, long long face_id, const char *name,
                        char **out_json);
/* Forget the faces found in an item. Assigned ones are kept unless
 * include_assigned is non-zero, so re-detecting does not throw away names. */
int um_faces_clear(um_library handle, long long item_id, int include_assigned);
/* Group unassigned faces that look alike, so a caller can name a group at
 * once. max_distance is how many bits of the signature may differ, 0 to 32. */
int um_faces_cluster_json(um_library handle, int max_distance, char **out_json);

/* ---- Time, place, and keeping two copies in step ------------------------- */

/* How many items fall in each day, month or year, with their total size.
 * period is "day", "month" or "year"; NULL means month. */
int um_timeline_json(um_library handle, const char *period, char **out_json);

/* What naming the places in a library would change, without changing any of
 * it. With no endpoint no network call is made and the plan is answered from
 * the cache alone, which fails rather than guessing for an item the cache has
 * never seen. overwrite replaces a location an item already has; refresh_cache
 * asks the provider again rather than trusting what was stored. */
int um_geocode_plan_json(um_library handle, const char *provider,
                         const char *language, const char *endpoint,
                         const char *user_agent, int overwrite,
                         int refresh_cache, char **out_json);
/* Plan and apply in one call, as organising does: the plan is rebuilt here, so
 * an item whose coordinates changed in between is named from what it holds now
 * rather than from a stale plan. */
int um_geocode_apply(um_library handle, const char *provider,
                     const char *language, const char *endpoint,
                     const char *user_agent, int overwrite, int refresh_cache,
                     um_progress_fn on_progress, um_cancel_fn on_cancel,
                     void *user_data, char **out_json);

/* What this library holds, as the manifest another copy is compared against. */
int um_sync_manifest_json(um_library handle, char **out_json);
/* Whether the external transfer tool is installed. Its absence is reported
 * rather than discovered halfway through a transfer. */
int um_sync_available(int *available);
/* What synchronising against remote would move. push non-zero sends this
 * library outwards; zero brings the remote in. */
int um_sync_plan_json(um_library handle, const char *remote, int push,
                      char **out_json);
int um_sync_apply(um_library handle, const char *plan_id, char **out_json);
/* What has been synchronised before, most recent first. */
int um_sync_runs_json(um_library handle, const char *plan_id, int limit,
                      char **out_json);

/* What a model has said about an item, or about every item when item_id is 0. */
int um_vision_annotations_json(um_library handle, long long item_id,
                               char **out_json);
/* Ask a model at endpoint to describe one item, and keep what it says. The
 * model runs outside this process; its absence is an error rather than a
 * silent empty description. */
int um_vision_describe(um_library handle, long long item_id,
                       const char *endpoint, const char *model,
                       char **out_json);
/* Items whose description is closest in meaning to query, rather than items
 * whose text contains it. */
int um_vision_search_json(um_library handle, const char *endpoint,
                          const char *model, const char *query, int limit,
                          char **out_json);

/* ---- Media and audio ----------------------------------------------------- */

/* What a video file is: the size its decoder produces, the size it is shown
 * at, its rotation in clockwise degrees, duration, codec and container. Read
 * in process; no external program runs. */
int um_media_probe_json(const char *path, char **out_json);
/* Whether a frame can be decoded out of a video, which needs an external
 * ffmpeg. Probing does not, so a machine without it still catalogues videos
 * and only goes without their thumbnails. */
int um_media_available(int *available);
/* Whether the external acoustic fingerprinter is installed. */
int um_audio_available(int *available);
/* The acoustic fingerprint of an audio file: its duration and the
 * sub-fingerprints. Needs the external fpcalc. */
int um_audio_fingerprint_json(const char *path, int max_seconds,
                              char **out_json);
/* How alike two fingerprints are, from 0 to 1. Each is the JSON
 * um_audio_fingerprint_json returned, so two files fingerprinted at different
 * times are compared without the caller keeping the engine's types. */
int um_audio_similarity(const char *first_json, const char *second_json,
                        double *score);

/* ---- One item, and the ways of finding it -------------------------------- */

int um_item_json(um_library handle, long long item_id, char **out_json);
/* Where an item is on disk, absolute. The listing reports a path relative to
 * the library root, which a caller opening the file cannot use directly. */
int um_item_path(um_library handle, long long item_id, char **out_path);
/* Items whose text matches query. kind narrows to a category, or is NULL. */
int um_search_json(um_library handle, const char *query, const char *kind,
                   int limit, int offset, char **out_json);
/* Items matching a filter given as JSON: any of text, kind, dateFrom, dateTo,
 * location, keywords, minRating, maxRating, favorite, hasGps. A field left out
 * narrows nothing, which is what makes an empty object mean everything. */
int um_filter_json(um_library handle, const char *filter_json, int limit,
                   int offset, char **out_json);
/* Where the library's items are, grouped by place name, with how many carry
 * coordinates. prefix narrows to names beginning with it. */
int um_place_facets_json(um_library handle, const char *prefix, int limit,
                         char **out_json);
/* The free-form metadata attached to an item, as the JSON it is stored as. */
int um_item_meta_json(um_library handle, long long item_id, char **out_json);
/* Replace it. The whole object is written, so a caller keeping a field must
 * send it back. */
int um_item_meta_set(um_library handle, long long item_id,
                     const char *meta_json);

/* --- file inspection, no library ---------------------------------------
 *
 * These answer from a path alone, so they take no handle: a caller deciding
 * what to do with a file it has not imported yet needs them before any
 * library exists. Every out_json buffer is released with um_buffer_free. */

/* Media domain, matching the engine's own order. */
typedef enum {
  UM_DOMAIN_PHOTO = 0,
  UM_DOMAIN_VIDEO = 1,
  UM_DOMAIN_MUSIC = 2,
  UM_DOMAIN_VISUAL = 3
} um_domain;

/* The category a file falls in for that domain, from its extension. Plain
 * string, not JSON. */
int um_category_for(int domain, const char *path, char **out_text);
/* The date the file name itself claims, or "" when it claims none. Plain
 * string, not JSON. */
int um_filename_date(const char *path, char **out_text);
/* Where the file says it was taken: {latitude, longitude, found}. found is
 * false when it does not say, which is an ordinary state, not a failure. */
int um_media_coordinates(const char *path, char **out_json);
/* The date to file this media under, and its source: {value, source}. The
 * two flags say whether the file name and the birth time may be fallen back
 * on when the file carries no date of its own. */
int um_media_date(const char *path, int filename_date, int birthtime_date,
                  char **out_json);
/* Whether the path is the library's own bookkeeping rather than media. */
int um_is_internal(const char *root, const char *path, int *out_answer);
/* Whether an AppleDouble sidecar may be removed, and why either way:
 * {removable, reason}. */
int um_apple_double_verdict(const char *path, char **out_json);
/* Whether a date correction can reach this file, from its name alone. */
int um_can_write_date(const char *rel_path, int *out_answer);
/* Whether stripping can rewrite this file, from its name alone. */
int um_can_strip(const char *rel_path, int *out_answer);
/* The path resolved under the root, refused if it escapes it. This is the
 * check every mutating call makes before touching a file, exposed so a
 * caller can make it before asking. Plain string, not JSON. */
int um_checked_path_under(const char *root, const char *path, char **out_text);
/* The current UTC instant in the format every timestamp here is written in.
 * Plain string, not JSON. */
int um_iso_now(char **out_text);
/* A fresh batch identifier, the same kind the engine stamps its own
 * mutations with. Plain string, not JSON. */
int um_new_batch_id(char **out_text);

/* --- hashing and sync, no library --------------------------------------- */

/* The content digest of one file, as lowercase hex. buffer_size of 0 takes
 * the engine's own; on_cancel may stop a long read. Plain string, not JSON. */
int um_blake3_file(const char *path, int buffer_size, um_cancel_fn on_cancel,
                   void *user_data, char **out_text);
/* Perceptual hashes of frames sampled across a video, as a JSON array of
 * decimal strings -- not numbers, because a 64-bit hash does not survive a
 * JSON parser that reads every number as a double. 0 takes the engine's own
 * sample count. */
int um_video_frame_hashes(const char *path, int samples, char **out_json);
/* The perceptual hash of an image and the dimensions it was computed over:
 * {hash, width, height}. hash is a decimal string, for the same reason. */
int um_perceptual_hash_file(const char *path, char **out_json);
/* Read a sync manifest and hand back what it holds, so a caller can check one
 * before acting on it: {schemaVersion, entries:[{path, digest, size,
 * mtimeNs}]}. */
int um_parse_sync_manifest(const char *data, char **out_json);
/* What separates two manifests: {onlyLocal, onlyRemote, changed}, each a list
 * of paths. Both arguments are manifests as text. */
int um_diff_sync_manifests(const char *local, const char *remote,
                           char **out_json);

/* --- library-backed methods -------------------------------------------- */

/* Re-read a named set of paths rather than the whole library, for a caller
 * that already knows what changed. paths_json is a JSON array of paths
 * relative to the library root. Reports {indexed, updated, removed,
 * hashErrors}. */
int um_reindex_paths(um_library handle, const char *paths_json, int skip_phash,
                     char **out_json);
/* Add an item with no file of its own -- a record for something the library
 * describes but does not hold. meta_json may be NULL. */
int um_add_virtual_item(um_library handle, const char *name,
                        const char *category, const char *meta_json,
                        long long *out_item_id);
/* Whether a curation patch is self-consistent, without opening a library or
 * writing anything: the check to make before offering to apply it. */
int um_validate_curation_patch(const char *patch_json);
/* Finish or roll back whatever a previous run left half-done: interrupted
 * organize batches and curation writes both. Does nothing on a library that
 * was closed cleanly. */
int um_recover(um_library handle);
/* What a dedup removal would take, without taking it: every group member that
 * is not the keeper. run_id 0 means the most recent run. */
int um_dedup_removal_plan(um_library handle, long long run_id,
                          char **out_json);
/* Whether this filesystem has hard links, asked before anything moves. A
 * network share often does not. 0 is an answer, not a failure; the reason is
 * in um_last_error. */
int um_hardlinks_supported(const char *root, int *out_answer);
/* Replace named duplicates by a hard link to the copy kept. pairs_json is a
 * JSON array of {"itemId":N,"keeperId":M}. Where um_dedup_link takes a whole
 * dedup run, this takes the pairs a caller chose itself. */
int um_link_duplicates(um_library handle, const char *pairs_json,
                       char **out_json);
/* What emptying the trash would remove, without removing it. A NULL or empty
 * batches_json means every batch. */
int um_trash_plan(um_library handle, const char *batches_json,
                  int older_than_days, char **out_json);
/* What the whole trash occupies: {files, bytes}. */
int um_trash_holding(um_library handle, char **out_json);

/* --- media inspection and the rest of the domain ------------------------ */

/* um_audio_similarity allowing one recording to start later than the other,
 * which is what two rips of the same track usually differ by. max_shift of 0
 * takes the engine's own bound. */
int um_audio_offset_similarity(const char *first, const char *second,
                               int max_shift, double *out_score);
/* What an audio file is, from its header, with whatever tags it carries:
 * {container, codec, sampleRate, channels, ...}. durationSeconds is absent
 * where the container does not state it -- Ogg keeps it in the last page and
 * MPEG audio in an optional header. */
int um_probe_sound(const char *path, char **out_json);
/* What a still image is: {width, height, format, codec}. A photograph has no
 * moov box, so um_probe cannot answer for one. */
int um_probe_still(const char *path, char **out_json);
/* One frame as RGBA bytes, scaled so neither edge passes max_edge. The buffer
 * is released with um_buffer_free; out_length is width * height * 4. Every
 * output reads zero or NULL on any status but UM_OK. */
int um_decode_frame(const char *path, int max_edge, double seek_seconds,
                    unsigned char **out_pixels, size_t *out_length,
                    int *out_width, int *out_height);
/* The track points a GPX file holds, so a caller can check a track before
 * matching a library against it. */
int um_parse_gpx(const char *path, char **out_json);
/* Run the detector over one item and report what it found, without storing
 * it. backend is the executable to run; NULL takes the default. */
int um_detect_faces(um_library handle, long long item_id, const char *backend,
                    char **out_json);
/* Replace every face recorded against one item. The whole set is written, so
 * a caller keeping one must send it back. */
int um_replace_faces(um_library handle, long long item_id,
                     const char *faces_json);
/* The settings a library root holds, read without opening it. */
int um_read_config(const char *root, char **out_json);
/* What um_library_init would write for that domain, so a caller can show the
 * defaults before creating anything. */
int um_default_config(int domain, char **out_json);

/* --- vision primitives -------------------------------------------------
 *
 * The vision calls above drive a whole flow: describe an item, index it,
 * search. These are the pieces they are built from, for a caller running its
 * own model rather than the one this library knows how to talk to. */

/* Record one item's embedding under a model, with the caption and labels that
 * go with it. embedding_json is an array of numbers, labels_json an array of
 * strings or NULL. */
int um_vision_store_document(um_library handle, long long item_id,
                             const char *model, const char *caption,
                             const char *labels_json,
                             const char *embedding_json);
/* Record a caption and labels without an embedding -- a description that did
 * not come from a model this library can search over. */
int um_vision_store_annotation(um_library handle, long long item_id,
                               const char *model, const char *caption,
                               const char *labels_json, char **out_json);
/* Nearest items to a vector the caller already has, rather than to text this
 * library would have to embed first. limit 0 takes the engine's default. */
int um_vision_semantic_search(um_library handle, const char *model,
                              const char *query_json, int limit,
                              char **out_json);
/* Embed a piece of text through the endpoint and store it against an item, in
 * one call. The network reach is the caller's to allow. */
int um_vision_index_text(um_library handle, long long item_id,
                         const char *endpoint, const char *model,
                         const char *text, const char *caption,
                         const char *labels_json);
/* The embedding an endpoint returns for a string, as a JSON array. No library
 * is involved: this is the model call on its own. timeout_ms 0 takes the
 * engine's default. */
int um_vision_embedding(const char *endpoint, const char *model,
                        const char *input, int timeout_ms, char **out_json);
/* What a vision model says about one image file: {caption, labels}. Takes a
 * path rather than an item, so it answers for a file not in any library. */
int um_vision_describe_file(const char *endpoint, const char *model,
                            const char *image_path, int timeout_ms,
                            char **out_json);
/* The caption and labels out of a model's raw reply, for a caller that called
 * the model itself and holds the response. */
int um_vision_parse_description(const char *raw, char **out_json);

#ifdef __cplusplus
}
#endif

#endif /* UNIMEDIA_H */
