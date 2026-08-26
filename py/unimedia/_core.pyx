# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cython: language_level=3
"""Cython binding over the UniMedia C ABI.

A thin wrapper, never a second implementation: what the ABI cannot reach, this
cannot reach either. Reports come back as parsed JSON, so the catalogue schema
stays behind the boundary exactly as it does for a C caller.
"""
from libc.stdint cimport int64_t
from libc.stddef cimport size_t
import json
import threading


cdef extern from "UniMedia.h":
    ctypedef void* um_library

    int um_init()
    int um_abi_version()
    const char *um_engine_version()
    const char *um_last_error()
    void um_buffer_free(void *buffer)
    int um_library_open(const char *root, um_library *handle)
    int um_library_exists(const char *root, int *present)
    int um_library_init(const char *root, const char *domain,
                        const char *scheme, um_library *handle)
    int um_library_close(um_library handle)
    int um_config_json(um_library handle, char **out_json)
    int um_config_set(um_library handle, const char *settings)
    ctypedef void (*um_progress_fn)(const char *phase, int current,
                                    int total, const char *message,
                                    void *user_data) noexcept
    ctypedef int (*um_cancel_fn)(void *user_data) noexcept
    int um_scan_bounded(um_library handle, int skip_phash, int jobs,
                        um_progress_fn on_progress, um_cancel_fn on_cancel,
                        void *user_data, char **out_json)
    int um_dedup_link_plan_json(um_library handle, long long run_id,
                                char **out_json)
    int um_dedup_link(um_library handle, long long run_id, char **out_json)
    int um_albums_json(um_library handle, char **out_json)
    int um_album_json(um_library handle, long long album_id, char **out_json)
    int um_album_items_json(um_library handle, long long album_id,
                            char **out_json)
    int um_album_create(um_library handle, const char *name, char **out_json)
    int um_album_rename(um_library handle, long long album_id,
                        const char *name, char **out_json)
    int um_album_delete(um_library handle, long long album_id)
    int um_album_add_item(um_library handle, long long album_id,
                          long long item_id, int *added)
    int um_album_remove_item(um_library handle, long long album_id,
                             long long item_id, int *removed)
    int um_album_set_cover(um_library handle, long long album_id,
                           long long item_id, char **out_json)
    int um_album_set_parent(um_library handle, long long album_id,
                            long long parent_id, char **out_json)
    int um_album_children_json(um_library handle, long long parent_id,
                               char **out_json)
    int um_smart_albums_json(um_library handle, char **out_json)
    int um_smart_album_json(um_library handle, long long album_id,
                            char **out_json)
    int um_smart_album_items_json(um_library handle, long long album_id,
                                  char **out_json)
    int um_smart_album_create(um_library handle, const char *name,
                              int match_all, const char *rules_json,
                              char **out_json)
    int um_smart_album_rename(um_library handle, long long album_id,
                              const char *name, char **out_json)
    int um_smart_album_delete(um_library handle, long long album_id)
    int um_people_json(um_library handle, char **out_json)
    int um_faces_json(um_library handle, long long item_id, char **out_json)
    int um_person_create(um_library handle, const char *name,
                         long long *person_id)
    int um_face_assign(um_library handle, long long face_id,
                       long long person_id)
    int um_face_assign_name(um_library handle, long long face_id,
                            const char *name, char **out_json)
    int um_faces_clear(um_library handle, long long item_id,
                       int include_assigned)
    int um_faces_cluster_json(um_library handle, int max_distance,
                              char **out_json)
    int um_timeline_json(um_library handle, const char *period,
                         char **out_json)
    int um_geocode_plan_json(um_library handle, const char *provider,
                             const char *language, const char *endpoint,
                             const char *user_agent, int overwrite,
                             int refresh_cache, char **out_json)
    int um_geocode_apply(um_library handle, const char *provider,
                         const char *language, const char *endpoint,
                         const char *user_agent, int overwrite,
                         int refresh_cache, um_progress_fn on_progress,
                         um_cancel_fn on_cancel, void *user_data,
                         char **out_json)
    int um_sync_manifest_json(um_library handle, char **out_json)
    int um_sync_available(int *available)
    int um_sync_plan_json(um_library handle, const char *remote, int push,
                          char **out_json)
    int um_sync_apply(um_library handle, const char *plan_id, char **out_json)
    int um_sync_runs_json(um_library handle, const char *plan_id, int limit,
                          char **out_json)
    int um_vision_annotations_json(um_library handle, long long item_id,
                                   char **out_json)
    int um_vision_describe(um_library handle, long long item_id,
                           const char *endpoint, const char *model,
                           char **out_json)
    int um_vision_search_json(um_library handle, const char *endpoint,
                              const char *model, const char *query, int limit,
                              char **out_json)
    int um_media_probe_json(const char *path, char **out_json)
    # --- added surface -----------------------------------------------------
    int um_category_for(int domain, const char *path, char **out_text)
    int um_filename_date(const char *path, char **out_text)
    int um_media_coordinates(const char *path, char **out_json)
    int um_media_date(const char *path, int filename_date, int birthtime_date,
                      char **out_json)
    int um_is_internal(const char *root, const char *path, int *out_answer)
    int um_apple_double_verdict(const char *path, char **out_json)
    int um_can_write_date(const char *rel_path, int *out_answer)
    int um_can_strip(const char *rel_path, int *out_answer)
    int um_checked_path_under(const char *root, const char *path,
                              char **out_text)
    int um_iso_now(char **out_text)
    int um_new_batch_id(char **out_text)
    int um_blake3_file(const char *path, int buffer_size,
                       um_cancel_fn on_cancel, void *user_data,
                       char **out_text)
    int um_video_frame_hashes(const char *path, int samples, char **out_json)
    int um_perceptual_hash_file(const char *path, char **out_json)
    int um_parse_sync_manifest(const char *data, char **out_json)
    int um_diff_sync_manifests(const char *local, const char *remote,
                               char **out_json)
    int um_reindex_paths(um_library handle, const char *paths_json,
                         int skip_phash, char **out_json)
    int um_add_virtual_item(um_library handle, const char *name,
                            const char *category, const char *meta_json,
                            long long *out_item_id)
    int um_validate_curation_patch(const char *patch_json)
    int um_recover(um_library handle)
    int um_dedup_removal_plan(um_library handle, long long run_id,
                              char **out_json)
    int um_hardlinks_supported(const char *root, int *out_answer)
    int um_link_duplicates(um_library handle, const char *pairs_json,
                           char **out_json)
    int um_trash_plan(um_library handle, const char *batches_json,
                      int older_than_days, char **out_json)
    int um_trash_holding(um_library handle, char **out_json)
    int um_audio_offset_similarity(const char *first, const char *second,
                                   int max_shift, double *out_score)
    int um_probe_sound(const char *path, char **out_json)
    int um_probe_still(const char *path, char **out_json)
    int um_parse_gpx(const char *path, char **out_json)
    int um_decode_frame(const char *path, int max_edge, double seek_seconds,
                        unsigned char **out_pixels, size_t *out_length,
                        int *out_width, int *out_height)
    int um_detect_faces(um_library handle, long long item_id,
                        const char *backend, char **out_json)
    int um_replace_faces(um_library handle, long long item_id,
                         const char *faces_json)
    int um_read_config(const char *root, char **out_json)
    int um_default_config(int domain, char **out_json)
    int um_vision_store_document(um_library handle, long long item_id,
                                 const char *model, const char *caption,
                                 const char *labels_json,
                                 const char *embedding_json)
    int um_vision_store_annotation(um_library handle, long long item_id,
                                   const char *model, const char *caption,
                                   const char *labels_json, char **out_json)
    int um_vision_semantic_search(um_library handle, const char *model,
                                  const char *query_json, int limit,
                                  char **out_json)
    int um_vision_index_text(um_library handle, long long item_id,
                             const char *endpoint, const char *model,
                             const char *text, const char *caption,
                             const char *labels_json)
    int um_vision_embedding(const char *endpoint, const char *model,
                            const char *input, int timeout_ms,
                            char **out_json)
    int um_vision_describe_file(const char *endpoint, const char *model,
                                const char *image_path, int timeout_ms,
                                char **out_json)
    int um_vision_parse_description(const char *raw, char **out_json)
    int um_media_available(int *available)
    int um_audio_available(int *available)
    int um_audio_fingerprint_json(const char *path, int max_seconds,
                                  char **out_json)
    int um_audio_similarity(const char *first_json, const char *second_json,
                            double *score)
    int um_item_json(um_library handle, long long item_id, char **out_json)
    int um_item_path(um_library handle, long long item_id, char **out_path)
    int um_search_json(um_library handle, const char *query, const char *kind,
                       int limit, int offset, char **out_json)
    int um_filter_json(um_library handle, const char *filter_json, int limit,
                       int offset, char **out_json)
    int um_place_facets_json(um_library handle, const char *prefix, int limit,
                             char **out_json)
    int um_item_meta_json(um_library handle, long long item_id,
                          char **out_json)
    int um_item_meta_set(um_library handle, long long item_id,
                         const char *meta_json)

    int um_phash_pending_count(um_library handle, int *count)
    int um_scan(um_library handle, int skip_phash, um_progress_fn on_progress,
                um_cancel_fn on_cancel, void *user_data, char **out_json)
    int um_organize_apply(um_library handle, const char *source,
                          const char *mode, const char *scheme,
                          int keep_duplicates, um_progress_fn on_progress,
                          void *user_data, char **out_json)
    int um_undo_plan_json(um_library handle, const char *batch,
                          char **out_json)
    int um_undo_apply(um_library handle, const char *batch,
                      um_progress_fn on_progress, void *user_data,
                      char **out_json)
    int um_items_remove(um_library handle, const char *item_ids,
                        char **out_json)
    int um_curation_json(um_library handle, int64_t item_id, char **out_json)
    int um_curate_item(um_library handle, int64_t item_id, const char *patch,
                       char **out_json)
    int um_curation_batch_apply(um_library handle, const char *item_ids,
                                const char *patch, um_progress_fn on_progress,
                                um_cancel_fn on_cancel, void *user_data,
                                char **out_json)
    int um_keywords_json(um_library handle, const char *prefix, int limit,
                         char **out_json)
    int um_dates_plan_json(um_library handle, const char *item_ids,
                           const char *mode, const char *value,
                           char **out_json)
    int um_dates_apply(um_library handle, const char *item_ids,
                       const char *mode, const char *value,
                       um_progress_fn on_progress, um_cancel_fn on_cancel,
                       void *user_data, char **out_json)
    int um_gpx_plan_json(um_library handle, const char *gpx_path,
                         const char *item_ids, int tolerance_seconds,
                         int camera_utc_offset_minutes, int refresh,
                         char **out_json)
    int um_gpx_apply(um_library handle, const char *gpx_path,
                     const char *item_ids, int tolerance_seconds,
                     int camera_utc_offset_minutes, int refresh,
                     um_progress_fn on_progress, um_cancel_fn on_cancel,
                     void *user_data, char **out_json)
    int um_trash_list_json(um_library handle, char **out_json)
    int um_trash_empty(um_library handle, const char *batch_ids,
                       int older_than_days, um_progress_fn on_progress,
                       void *user_data, char **out_json)
    int um_cleanup_plan_json(um_library handle, const char *kinds,
                             char **out_json)
    int um_cleanup_apply(um_library handle, const char *kinds, int permanently,
                         um_progress_fn on_progress, void *user_data,
                         char **out_json)
    int um_privacy_audit_json(um_library handle, char **out_json)
    int um_privacy_strip_plan_json(um_library handle, const char *item_ids,
                                   char **out_json)
    int um_privacy_strip_apply(um_library handle, const char *item_ids,
                               um_progress_fn on_progress, void *user_data,
                               char **out_json)
    int um_dedup_keep(um_library handle, int64_t group_id, int64_t item_id)
    int um_dedup_remove(um_library handle, int64_t run_id, char **out_json)
    int um_dedup_remove_item(um_library handle, int64_t run_id,
                             int64_t item_id, char **out_json)
    int um_thumbnail_json(um_library handle, int64_t item_id, int max_edge,
                          char **out_json)
    int um_integrity_audit_json(um_library handle, int verify_hashes,
                                um_progress_fn on_progress,
                                um_cancel_fn on_cancel, void *user_data,
                                char **out_json)
    int um_item_count(um_library handle, const char *kind, int *count)
    int um_items_json(um_library handle, const char *kind, int limit,
                      int offset, char **out_json)
    int um_dedup_find(um_library handle, const char *kind, double threshold,
                      um_progress_fn on_progress, um_cancel_fn on_cancel,
                      void *user_data, int64_t *run_id)
    int um_dedup_review_json(um_library handle, int64_t run_id, char **out_json)
    int um_organize_plan_json(um_library handle, const char *source,
                              const char *scheme, int keep_duplicates,
                              char **out_json)


class UniMediaError(RuntimeError):
    """A call into the engine failed. `status` carries the um_status code."""

    def __init__(self, status, message):
        super().__init__(message or f"UniMedia error {status}")
        self.status = status


_init_lock = threading.Lock()
_initialised = False


cdef _ensure_init():
    global _initialised
    if not _initialised:
        with _init_lock:
            if not _initialised:
                um_init()
                _initialised = True


cdef _check(int status):
    if status != 0:
        raise UniMediaError(status, um_last_error().decode("utf-8", "replace"))


cdef _take(char *buffer):
    """Own a string the ABI allocated, copy it out, hand it back."""
    try:
        return buffer.decode("utf-8")
    finally:
        um_buffer_free(buffer)


def is_library(root):
    """Whether `root` already holds a library.

    Distinct from whether it opens: a folder that was never a library invites
    creating one, while a library that fails to open has an error worth
    reporting.
    """
    _ensure_init()
    cdef bytes encoded = str(root).encode("utf-8")
    cdef int present = 0
    _check(um_library_exists(encoded, &present))
    return present != 0


def abi_version():
    """ABI version of the linked library."""
    _ensure_init()
    return um_abi_version()


def engine_version():
    """Engine version, e.g. "1.0.0"."""
    _ensure_init()
    return um_engine_version().decode("utf-8")


cdef class Library:
    """An open media library. Close it, or use it as a context manager.

    The thread that opens a library owns it: do not share an instance between
    threads without external synchronisation.
    """

    cdef um_library _handle
    cdef bint _open

    def __cinit__(self, root, create=None, scheme=None):
        _ensure_init()
        cdef bytes encoded = str(root).encode("utf-8")
        cdef bytes domain
        cdef bytes layout
        cdef um_library handle = NULL
        if create is None:
            _check(um_library_open(encoded, &handle))
        else:
            domain = str(create).encode("utf-8")
            layout = (scheme or "").encode("utf-8")
            _check(um_library_init(encoded, domain, layout, &handle))
        self._handle = handle
        self._open = True

    @staticmethod
    def create(root, domain="visual", scheme=None):
        """Create a library at `root` and open it.

        Only the config and the catalogue are written: no media file is read,
        moved or modified, and a root already holding either is refused.
        Cataloguing is the separate `scan` step.
        """
        return Library(root, create=domain, scheme=scheme)

    cdef _require_open(self):
        if not self._open:
            raise UniMediaError(2, "library is closed")

    def close(self):
        if self._open:
            _check(um_library_close(self._handle))
            self._open = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __dealloc__(self):
        if self._open:
            um_library_close(self._handle)

    @property
    def config(self):
        """The library preferences, as `.organizemedia.json` holds them."""
        self._require_open()
        cdef char *out = NULL
        _check(um_config_json(self._handle, &out))
        return json.loads(_take(out))

    def configure(self, **settings):
        """Change preferences, keeping the ones not named.

        Accepts domain, scheme, filenameDate, noDateDir and onConflict. An
        invalid value leaves the file and this library untouched.
        """
        self._require_open()
        cdef bytes encoded = json.dumps(settings).encode("utf-8")
        _check(um_config_set(self._handle, encoded))

    def scan(self, skip_phash=False, jobs=0):
        """Reconcile the catalogue against the disk. Returns the report.

        ``jobs`` bounds how many files are hashed at once. Zero uses every
        core, which is what a machine doing nothing else wants and what a
        machine someone is working on does not.
        """
        self._require_open()
        cdef char *out = NULL
        if jobs < 0:
            raise ValueError("jobs must not be negative")
        _check(um_scan_bounded(self._handle, 1 if skip_phash else 0, jobs,
                               NULL, NULL, NULL, &out))
        return json.loads(_take(out))

    def pending_perceptual_hashes(self):
        """How many items still owe a perceptual hash.

        A scan can skip that work, which is most of what a scan costs and only
        duplicate detection needs. This says how much is left.
        """
        self._require_open()
        cdef int owing = 0
        _check(um_phash_pending_count(self._handle, &owing))
        return owing

    def count(self, kind=None):
        """Active item count, optionally restricted to a media kind."""
        self._require_open()
        cdef int total = 0
        cdef bytes encoded
        if kind is None:
            _check(um_item_count(self._handle, NULL, &total))
        else:
            encoded = str(kind).encode("utf-8")
            _check(um_item_count(self._handle, encoded, &total))
        return total

    def items(self, kind=None, limit=100, offset=0):
        """One page of items, ordered by relative path."""
        self._require_open()
        cdef char *out = NULL
        cdef bytes encoded
        if kind is None:
            _check(um_items_json(self._handle, NULL, limit, offset, &out))
        else:
            encoded = str(kind).encode("utf-8")
            _check(um_items_json(self._handle, encoded, limit, offset, &out))
        return json.loads(_take(out))

    def find_duplicates(self, kind="all", threshold=95.0):
        """Group duplicates and return the run id."""
        self._require_open()
        cdef bytes encoded = str(kind).encode("utf-8")
        cdef int64_t run = 0
        _check(um_dedup_find(self._handle, encoded, threshold, NULL, NULL,
                             NULL, &run))
        return run

    def review(self, run_id=0):
        """A duplicate run, most recent when `run_id` is 0."""
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_review_json(self._handle, run_id, &out))
        return json.loads(_take(out))

    def plan_organize(self, source, scheme=None, keep_duplicates=False):
        """Plan an organize run over `source`. Changes nothing.

        `scheme` overrides the library preference for this run only; None
        keeps it. ``keep_duplicates`` copies a file even where an identical one
        already holds its place, suffixing it; the default treats the same
        bytes under the same name as one file.
        """
        self._require_open()
        cdef bytes encoded = str(source).encode("utf-8")
        cdef bytes layout = (scheme or "").encode("utf-8")
        cdef char *out = NULL
        _check(um_organize_plan_json(self._handle, encoded, layout,
                                     1 if keep_duplicates else 0, &out))
        return json.loads(_take(out))

    def organize(self, source, mode="copy", scheme=None,
                 keep_duplicates=False):
        """File `source` into the library. mode: copy, move or hardlink."""
        self._require_open()
        cdef bytes src = str(source).encode("utf-8")
        cdef bytes how = str(mode).encode("utf-8")
        cdef bytes layout = (scheme or "").encode("utf-8")
        cdef char *out = NULL
        _check(um_organize_apply(self._handle, src, how, layout,
                                 1 if keep_duplicates else 0, NULL, NULL,
                                 &out))
        return json.loads(_take(out))

    def undo_plan(self, batch=None):
        """What undoing `batch` would do. None selects the most recent."""
        self._require_open()
        cdef bytes encoded = (batch or "").encode("utf-8")
        cdef char *out = NULL
        _check(um_undo_plan_json(self._handle, encoded, &out))
        return json.loads(_take(out))

    def undo(self, batch=None):
        """Undo `batch`, verifying journalled hashes. None = most recent."""
        self._require_open()
        cdef bytes encoded = (batch or "").encode("utf-8")
        cdef char *out = NULL
        _check(um_undo_apply(self._handle, encoded, NULL, NULL, &out))
        return json.loads(_take(out))

    def remove_items(self, item_ids):
        """Move the given catalogue items to the trash; undo restores them.

        An id that is unknown or already removed fails the whole request.
        """
        self._require_open()
        cdef bytes encoded = json.dumps([int(i) for i in item_ids]).encode("utf-8")
        cdef char *out = NULL
        _check(um_items_remove(self._handle, encoded, &out))
        return json.loads(_take(out))

    def curation(self, item_id):
        """What an item carries: title, rating, keywords, creator, copyright."""
        self._require_open()
        cdef char *out = NULL
        _check(um_curation_json(self._handle, item_id, &out))
        return json.loads(_take(out))

    def curate(self, item_id, **patch):
        """Change one item. An omitted field is preserved; an empty string or
        list clears it."""
        self._require_open()
        cdef bytes encoded = json.dumps(patch).encode("utf-8")
        cdef char *out = NULL
        _check(um_curate_item(self._handle, item_id, encoded, &out))
        return json.loads(_take(out))

    def curate_batch(self, item_ids, **patch):
        """The same patch across a selection. Failures are per item."""
        self._require_open()
        cdef bytes ids = json.dumps([int(i) for i in item_ids]).encode("utf-8")
        cdef bytes encoded = json.dumps(patch).encode("utf-8")
        cdef char *out = NULL
        _check(um_curation_batch_apply(self._handle, ids, encoded, NULL, NULL,
                                       NULL, &out))
        return json.loads(_take(out))

    def keywords(self, prefix=None, limit=100):
        """Keywords already in use, with how many items carry each."""
        self._require_open()
        cdef bytes encoded
        cdef char *out = NULL
        if prefix is None:
            _check(um_keywords_json(self._handle, NULL, limit, &out))
        else:
            encoded = str(prefix).encode("utf-8")
            _check(um_keywords_json(self._handle, encoded, limit, &out))
        return json.loads(_take(out))

    def plan_dates(self, item_ids, mode, value):
        """What a date correction would change. mode: "set" or "shift"."""
        self._require_open()
        cdef bytes ids = json.dumps([int(i) for i in item_ids]).encode("utf-8")
        cdef bytes how = str(mode).encode("utf-8")
        cdef bytes what = str(value).encode("utf-8")
        cdef char *out = NULL
        _check(um_dates_plan_json(self._handle, ids, how, what, &out))
        return json.loads(_take(out))

    def set_dates(self, item_ids, value):
        """Give every named item the same creation date."""
        return self._apply_dates(item_ids, "set", value)

    def shift_dates(self, item_ids, seconds):
        """Move every named item's creation date by `seconds`."""
        return self._apply_dates(item_ids, "shift", int(seconds))

    def _apply_dates(self, item_ids, mode, value):
        self._require_open()
        cdef bytes ids = json.dumps([int(i) for i in item_ids]).encode("utf-8")
        cdef bytes how = str(mode).encode("utf-8")
        cdef bytes what = str(value).encode("utf-8")
        cdef char *out = NULL
        _check(um_dates_apply(self._handle, ids, how, what, NULL, NULL, NULL,
                              &out))
        return json.loads(_take(out))

    def plan_gpx(self, gpx_path, item_ids=None, tolerance_seconds=300,
                 camera_utc_offset_minutes=0, refresh=False):
        """Which items a track would place, and how far each match is.

        An item that already carries a position is reported with
        ``alreadyPlaced`` and kept; pass ``refresh=True`` to place it anyway.
        """
        self._require_open()
        cdef bytes track = str(gpx_path).encode("utf-8")
        cdef bytes ids = json.dumps(
            [int(i) for i in item_ids or []]).encode("utf-8")
        cdef char *out = NULL
        _check(um_gpx_plan_json(self._handle, track, ids, tolerance_seconds,
                                camera_utc_offset_minutes, 1 if refresh else 0,
                                &out))
        return json.loads(_take(out))

    def apply_gpx(self, gpx_path, item_ids=None, tolerance_seconds=300,
                  camera_utc_offset_minutes=0, refresh=False):
        """Write the matched coordinates. Refused when nothing matches."""
        self._require_open()
        cdef bytes track = str(gpx_path).encode("utf-8")
        cdef bytes ids = json.dumps(
            [int(i) for i in item_ids or []]).encode("utf-8")
        cdef char *out = NULL
        _check(um_gpx_apply(self._handle, track, ids, tolerance_seconds,
                            camera_utc_offset_minutes, 1 if refresh else 0,
                            NULL, NULL, NULL, &out))
        return json.loads(_take(out))

    def trash(self):
        """Every batch that put something in the trash, newest first.

        ``undoable`` needs both a batch that was applied and files still there
        to put back; either alone is not a way back.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_trash_list_json(self._handle, &out))
        return json.loads(_take(out))["batches"]

    def empty_trash(self, batches=None, older_than_days=0):
        """Delete what those batches kept. **This ends recoverability.**

        The files go for good and ``undo`` can no longer reach them. ``batches``
        names them, or None for every batch at least ``older_than_days`` old;
        zero days means all of them.
        """
        self._require_open()
        cdef bytes ids = json.dumps(list(batches or [])).encode("utf-8")
        cdef char *out = NULL
        _check(um_trash_empty(self._handle, ids, older_than_days,
                              NULL, NULL, &out))
        return json.loads(_take(out))

    def plan_cleanup(self, kinds=None):
        """What a cleanup would take away, taking nothing.

        ``kinds`` names the categories — "apple-double", "os-junk",
        "orphan-sidecar", "empty-dir", "interrupted" — or None for all of them.

        An entry whose ``removable`` is false was found and is being reported,
        not proposed: an AppleDouble carrying a Finder tag is where that tag
        lives when the filesystem cannot hold it beside the file. ``reason``
        says why either way.
        """
        self._require_open()
        cdef bytes wanted = json.dumps(list(kinds or [])).encode("utf-8")
        cdef char *out = NULL
        _check(um_cleanup_plan_json(self._handle, wanted, &out))
        return json.loads(_take(out))["entries"]

    def cleanup(self, kinds=None, permanently=False):
        """Move what the plan marked removable into the journalled trash.

        ``permanently`` deletes instead, with no trash and no undo.

        Undoable like any other batch. Refused when nothing in the plan can be
        removed, rather than reporting a run that did nothing as a success.
        """
        self._require_open()
        cdef bytes wanted = json.dumps(list(kinds or [])).encode("utf-8")
        cdef char *out = NULL
        _check(um_cleanup_apply(self._handle, wanted,
                                1 if permanently else 0, NULL, NULL, &out))
        return json.loads(_take(out))

    def privacy_audit(self):
        """What each item still discloses. Only items with something to
        report, or that could not be read, appear."""
        self._require_open()
        cdef char *out = NULL
        _check(um_privacy_audit_json(self._handle, &out))
        return json.loads(_take(out))

    def plan_privacy_strip(self, item_ids=None):
        """What a strip would touch. None means everything the audit found."""
        self._require_open()
        cdef bytes encoded = json.dumps(
            [int(i) for i in item_ids or []]).encode("utf-8")
        cdef char *out = NULL
        _check(um_privacy_strip_plan_json(self._handle, encoded, &out))
        return json.loads(_take(out))

    def strip_privacy(self, item_ids=None):
        """Strip metadata. Journalled: `undo` restores the originals."""
        self._require_open()
        cdef bytes encoded = json.dumps(
            [int(i) for i in item_ids or []]).encode("utf-8")
        cdef char *out = NULL
        _check(um_privacy_strip_apply(self._handle, encoded, NULL, NULL, &out))
        return json.loads(_take(out))

    def keep(self, group_id, item_id):
        """Choose the member of `group_id` a removal must not touch."""
        self._require_open()
        _check(um_dedup_keep(self._handle, group_id, item_id))

    def remove_duplicates(self, run_id=0):
        """Move non-keepers to the hash-verified trash; undo restores them."""
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_remove(self._handle, run_id, &out))
        return json.loads(_take(out))

    def remove_duplicate(self, long long run_id, long long item_id):
        """Send one item of a duplicate run to the journalled trash.

        The whole-run form removes everything a review marked; this removes one
        of them, for a caller working through a run item by item. Both go to
        the same trash, so undo restores either.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_remove_item(self._handle, run_id, item_id, &out))
        return json.loads(_take(out))

    def thumbnail(self, long long item_id, int max_edge=256):
        """A deterministic PNG under ``.om-cache``, keyed by content digest,
        edge and algorithm version.

        Returns where it is rather than its bytes: a caller renders the path,
        and nothing decodes or caches a second time.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_thumbnail_json(self._handle, item_id, max_edge, &out))
        return json.loads(_take(out))

    def link_duplicates_plan(self, long long run_id=0):
        """Which duplicates could become a hard link, and to which copy.

        Byte-identical groups only: files a perceptual hash called alike are
        not the same file, and linking them would throw away whichever was not
        kept.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_link_plan_json(self._handle, run_id, &out))
        return json.loads(_take(out))

    def link_duplicates(self, long long run_id=0):
        """Replace each byte-identical duplicate with a hard link to the copy
        kept: the space is freed and every path still opens.

        Journalled like a removal, and undone by :meth:`undo`.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_link(self._handle, run_id, &out))
        return json.loads(_take(out))

    def audit(self, verify_hashes=True):
        """Read-only consistency audit."""
        self._require_open()
        cdef char *out = NULL
        _check(um_integrity_audit_json(self._handle, 1 if verify_hashes else 0,
                                       NULL, NULL, NULL, &out))
        return json.loads(_take(out))

    # ---- Albums, both kinds ------------------------------------------------
    # An album is a list somebody curated; a smart album is a query that
    # produces one. They are reported the same way so a caller shows them side
    # by side, which is how a library is browsed.

    def albums(self):
        """Every album, with its item count and cover."""
        self._require_open()
        cdef char *out = NULL
        _check(um_albums_json(self._handle, &out))
        return json.loads(_take(out))

    def album(self, long long album_id):
        """One album by identifier."""
        self._require_open()
        cdef char *out = NULL
        _check(um_album_json(self._handle, album_id, &out))
        return json.loads(_take(out))

    def album_items(self, long long album_id):
        """The items an album holds, in the order it holds them."""
        self._require_open()
        cdef char *out = NULL
        _check(um_album_items_json(self._handle, album_id, &out))
        return json.loads(_take(out))

    def create_album(self, name):
        """Create an album and return it, identifier included."""
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef char *out = NULL
        _check(um_album_create(self._handle, encoded, &out))
        return json.loads(_take(out))

    def rename_album(self, long long album_id, name):
        """Rename an album and return it as it now stands."""
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef char *out = NULL
        _check(um_album_rename(self._handle, album_id, encoded, &out))
        return json.loads(_take(out))

    def delete_album(self, long long album_id):
        """Delete an album. The items it held are untouched."""
        self._require_open()
        _check(um_album_delete(self._handle, album_id))

    def add_to_album(self, long long album_id, long long item_id):
        """Put an item in an album. False when it was already there, which is
        not a failure -- adding twice is how a caller makes sure."""
        self._require_open()
        cdef int added = 0
        _check(um_album_add_item(self._handle, album_id, item_id, &added))
        return added != 0

    def remove_from_album(self, long long album_id, long long item_id):
        """Take an item out. False when it was not in the album."""
        self._require_open()
        cdef int removed = 0
        _check(um_album_remove_item(self._handle, album_id, item_id, &removed))
        return removed != 0

    def set_album_cover(self, long long album_id, long long item_id=0):
        """Set an album's cover, or clear it with an item id of 0."""
        self._require_open()
        cdef char *out = NULL
        _check(um_album_set_cover(self._handle, album_id, item_id, &out))
        return json.loads(_take(out))

    def set_album_parent(self, long long album_id, long long parent_id=0):
        """Move an album inside another, or to the top with a parent of 0.

        A cycle is refused: an album cannot be its own ancestor, and neither
        can a chain of them close on itself.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_album_set_parent(self._handle, album_id, parent_id, &out))
        return json.loads(_take(out))

    def child_albums(self, long long parent_id=0):
        """The albums directly inside ``parent_id``, or those at the top.

        One level, so a caller drawing a tree asks again for each branch it
        opens rather than being handed a whole library's worth it may never
        show.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_album_children_json(self._handle, parent_id, &out))
        return json.loads(_take(out))

    def smart_albums(self):
        """Every smart album, with the rules that define it."""
        self._require_open()
        cdef char *out = NULL
        _check(um_smart_albums_json(self._handle, &out))
        return json.loads(_take(out))

    def smart_album(self, long long album_id):
        """One smart album by identifier."""
        self._require_open()
        cdef char *out = NULL
        _check(um_smart_album_json(self._handle, album_id, &out))
        return json.loads(_take(out))

    def smart_album_items(self, long long album_id):
        """What a smart album currently matches, evaluated on the call."""
        self._require_open()
        cdef char *out = NULL
        _check(um_smart_album_items_json(self._handle, album_id, &out))
        return json.loads(_take(out))

    def create_smart_album(self, name, rules, match_all=True):
        """Create a smart album from a list of rule dicts.

        Each rule is ``{"field": ..., "operator": ..., "value": ...}``. The
        engine checks them, so it and this binding cannot disagree about what
        is valid.
        """
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef bytes payload = json.dumps(list(rules)).encode("utf-8")
        cdef char *out = NULL
        _check(um_smart_album_create(self._handle, encoded,
                                     1 if match_all else 0, payload, &out))
        return json.loads(_take(out))

    def rename_smart_album(self, long long album_id, name):
        """Rename a smart album and return it as it now stands."""
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef char *out = NULL
        _check(um_smart_album_rename(self._handle, album_id, encoded, &out))
        return json.loads(_take(out))

    def delete_smart_album(self, long long album_id):
        """Delete a smart album. It holds no items of its own."""
        self._require_open()
        _check(um_smart_album_delete(self._handle, album_id))

    # ---- People and faces --------------------------------------------------

    def people(self):
        """Every named person, with how many faces carry that name."""
        self._require_open()
        cdef char *out = NULL
        _check(um_people_json(self._handle, &out))
        return json.loads(_take(out))

    def faces(self, long long item_id=0):
        """Faces in one item, or in the whole library when ``item_id`` is 0."""
        self._require_open()
        cdef char *out = NULL
        _check(um_faces_json(self._handle, item_id, &out))
        return json.loads(_take(out))

    def create_person(self, name):
        """Create a person and return the identifier faces attach to."""
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef long long person_id = 0
        _check(um_person_create(self._handle, encoded, &person_id))
        return person_id

    def assign_face(self, long long face_id, long long person_id):
        """Attach a face to a person that already exists."""
        self._require_open()
        _check(um_face_assign(self._handle, face_id, person_id))

    def name_face(self, long long face_id, name):
        """Attach a face to a person named ``name``, creating that person if
        there is none -- which is what naming a face in an interface means."""
        self._require_open()
        cdef bytes encoded = str(name).encode("utf-8")
        cdef char *out = NULL
        _check(um_face_assign_name(self._handle, face_id, encoded, &out))
        return json.loads(_take(out))

    def clear_faces(self, long long item_id, include_assigned=False):
        """Forget the faces found in an item. Assigned ones are kept unless
        asked for, so re-detecting does not throw away names."""
        self._require_open()
        _check(um_faces_clear(self._handle, item_id,
                              1 if include_assigned else 0))

    def cluster_faces(self, int max_distance=10):
        """Group unassigned faces that look alike, so a caller can name a group
        at once. ``max_distance`` is how many bits of the signature may differ,
        0 to 32."""
        self._require_open()
        cdef char *out = NULL
        _check(um_faces_cluster_json(self._handle, max_distance, &out))
        return json.loads(_take(out))

    # ---- Time, place, sync, vision ----------------------------------------

    def timeline(self, period="month"):
        """How many items fall in each day, month or year, and their size."""
        self._require_open()
        cdef bytes encoded = str(period).encode("utf-8")
        cdef char *out = NULL
        _check(um_timeline_json(self._handle, encoded, &out))
        return json.loads(_take(out))

    def geocode_plan(self, provider, language="en", endpoint=None,
                     user_agent=None, overwrite=False, refresh_cache=False):
        """What naming the places in a library would change, without changing
        any of it.

        With no ``endpoint`` no network call is made and the plan is answered
        from the cache alone, which fails rather than guessing for an item the
        cache has never seen.
        """
        self._require_open()
        cdef bytes p = str(provider).encode("utf-8")
        cdef bytes lang = str(language).encode("utf-8")
        cdef bytes ep = b"" if endpoint is None else str(endpoint).encode("utf-8")
        cdef bytes ua = b"" if user_agent is None else str(user_agent).encode("utf-8")
        cdef char *out = NULL
        _check(um_geocode_plan_json(self._handle, p, lang,
                                    NULL if endpoint is None else <const char *>ep,
                                    NULL if user_agent is None else <const char *>ua,
                                    1 if overwrite else 0,
                                    1 if refresh_cache else 0, &out))
        return json.loads(_take(out))

    def geocode_apply(self, provider, language="en", endpoint=None,
                      user_agent=None, overwrite=False, refresh_cache=False):
        """Plan and apply in one call, as organising does."""
        self._require_open()
        cdef bytes p = str(provider).encode("utf-8")
        cdef bytes lang = str(language).encode("utf-8")
        cdef bytes ep = b"" if endpoint is None else str(endpoint).encode("utf-8")
        cdef bytes ua = b"" if user_agent is None else str(user_agent).encode("utf-8")
        cdef char *out = NULL
        _check(um_geocode_apply(self._handle, p, lang,
                                NULL if endpoint is None else <const char *>ep,
                                NULL if user_agent is None else <const char *>ua,
                                1 if overwrite else 0,
                                1 if refresh_cache else 0, NULL, NULL, NULL,
                                &out))
        return json.loads(_take(out))

    def sync_manifest(self):
        """What this library holds, as the manifest a copy is compared against."""
        self._require_open()
        cdef char *out = NULL
        _check(um_sync_manifest_json(self._handle, &out))
        return json.loads(_take(out))

    def sync_plan(self, remote, push=True):
        """What synchronising against ``remote`` would move."""
        self._require_open()
        cdef bytes encoded = str(remote).encode("utf-8")
        cdef char *out = NULL
        _check(um_sync_plan_json(self._handle, encoded, 1 if push else 0, &out))
        return json.loads(_take(out))

    def sync_apply(self, plan_id):
        """Carry out a plan made earlier, named by its identifier."""
        self._require_open()
        cdef bytes encoded = str(plan_id).encode("utf-8")
        cdef char *out = NULL
        _check(um_sync_apply(self._handle, encoded, &out))
        return json.loads(_take(out))

    def sync_runs(self, plan_id=None, limit=100):
        """What has been synchronised before, most recent first."""
        self._require_open()
        cdef bytes encoded
        cdef char *out = NULL
        if plan_id is None:
            _check(um_sync_runs_json(self._handle, NULL, limit, &out))
        else:
            encoded = str(plan_id).encode("utf-8")
            _check(um_sync_runs_json(self._handle, encoded, limit, &out))
        return json.loads(_take(out))

    def vision_annotations(self, long long item_id=0):
        """What a model has said about an item, or about every item."""
        self._require_open()
        cdef char *out = NULL
        _check(um_vision_annotations_json(self._handle, item_id, &out))
        return json.loads(_take(out))

    def vision_describe(self, long long item_id, endpoint, model):
        """Ask a model at ``endpoint`` to describe one item, and keep what it
        says. The model runs outside this process; its absence is an error."""
        self._require_open()
        cdef bytes ep = str(endpoint).encode("utf-8")
        cdef bytes md = str(model).encode("utf-8")
        cdef char *out = NULL
        _check(um_vision_describe(self._handle, item_id, ep, md, &out))
        return json.loads(_take(out))

    def vision_search(self, endpoint, model, query, limit=50):
        """Items whose description is closest in meaning to ``query``."""
        self._require_open()
        cdef bytes ep = str(endpoint).encode("utf-8")
        cdef bytes md = str(model).encode("utf-8")
        cdef bytes q = str(query).encode("utf-8")
        cdef char *out = NULL
        _check(um_vision_search_json(self._handle, ep, md, q, limit, &out))
        return json.loads(_take(out))

    # ---- One item, and the ways of finding it ------------------------------

    def item(self, long long item_id):
        """One item by identifier, in the shape the listing uses."""
        self._require_open()
        cdef char *out = NULL
        _check(um_item_json(self._handle, item_id, &out))
        return json.loads(_take(out))

    def item_path(self, long long item_id):
        """Where an item is on disk, absolute. The listing reports a path
        relative to the library root, which a caller opening the file cannot
        use directly."""
        self._require_open()
        cdef char *out = NULL
        _check(um_item_path(self._handle, item_id, &out))
        return _take(out)

    def search(self, query, kind=None, limit=100, offset=0):
        """Items whose text matches ``query``."""
        self._require_open()
        cdef bytes q = str(query).encode("utf-8")
        cdef bytes k
        cdef char *out = NULL
        if kind is None:
            _check(um_search_json(self._handle, q, NULL, limit, offset, &out))
        else:
            k = str(kind).encode("utf-8")
            _check(um_search_json(self._handle, q, k, limit, offset, &out))
        return json.loads(_take(out))

    def filter(self, criteria=None, limit=100, offset=0):
        """Items matching a filter.

        ``criteria`` is a dict of any of ``text``, ``kind``, ``dateFrom``,
        ``dateTo``, ``location``, ``keywords``, ``minRating``, ``maxRating``,
        ``favorite``, ``hasGps``. A field left out narrows nothing, which is
        what makes an empty filter mean everything.
        """
        self._require_open()
        cdef bytes payload = json.dumps(criteria or {}).encode("utf-8")
        cdef char *out = NULL
        _check(um_filter_json(self._handle, payload, limit, offset, &out))
        return json.loads(_take(out))

    def place_facets(self, prefix=None, limit=100):
        """Where the library's items are, grouped by place name."""
        self._require_open()
        cdef bytes encoded
        cdef char *out = NULL
        if prefix is None:
            _check(um_place_facets_json(self._handle, NULL, limit, &out))
        else:
            encoded = str(prefix).encode("utf-8")
            _check(um_place_facets_json(self._handle, encoded, limit, &out))
        return json.loads(_take(out))

    def item_meta(self, long long item_id):
        """The free-form metadata attached to an item."""
        self._require_open()
        cdef char *out = NULL
        _check(um_item_meta_json(self._handle, item_id, &out))
        return json.loads(_take(out))

    def set_item_meta(self, long long item_id, meta):
        """Replace it. The whole object is written, so a caller keeping a field
        must send it back."""
        self._require_open()
        cdef bytes payload = json.dumps(meta).encode("utf-8")
        _check(um_item_meta_set(self._handle, item_id, payload))


    # --- added surface ----------------------------------------------------

    def reindex_paths(self, paths, skip_phash=True):
        """Re-read a named set of paths rather than the whole library.

        For a caller that already knows what changed. Each path is relative
        to the library root.
        """
        self._require_open()
        cdef bytes encoded = json.dumps([str(p) for p in paths]).encode("utf-8")
        cdef char *out = NULL
        _check(um_reindex_paths(self._handle, encoded,
                                1 if skip_phash else 0, &out))
        return json.loads(_take(out))

    def add_virtual_item(self, name, category, meta=None):
        """Add an item with no file of its own, and return its identifier.

        A record for something the library describes but does not hold.
        """
        self._require_open()
        cdef bytes n = str(name).encode("utf-8")
        cdef bytes c = str(category).encode("utf-8")
        cdef bytes m
        cdef long long item_id = 0
        if meta is None:
            _check(um_add_virtual_item(self._handle, n, c, NULL, &item_id))
        else:
            m = json.dumps(meta).encode("utf-8")
            _check(um_add_virtual_item(self._handle, n, c, m, &item_id))
        return item_id

    def recover(self):
        """Finish or roll back what a previous run left half-done.

        Interrupted organize batches and curation writes both: a caller has
        no way to know which of the two a crash left behind. Does nothing on
        a library that was closed cleanly.
        """
        self._require_open()
        _check(um_recover(self._handle))

    def dedup_removal_plan(self, long long run_id=0):
        """What a dedup removal would take, without taking it.

        Every group member that is not the keeper. Zero means the most
        recent run.
        """
        self._require_open()
        cdef char *out = NULL
        _check(um_dedup_removal_plan(self._handle, run_id, &out))
        return json.loads(_take(out))

    def link_duplicate_pairs(self, pairs):
        """Replace named duplicates by a hard link to the copy kept.

        `pairs` is a sequence of `{"itemId": n, "keeperId": m}`. Where
        :meth:`link_duplicates` takes a whole dedup run, this takes the pairs
        a caller chose itself. Byte-identical only: every pair's hash is
        compared before anything moves.
        """
        self._require_open()
        cdef bytes encoded = json.dumps(list(pairs)).encode("utf-8")
        cdef char *out = NULL
        _check(um_link_duplicates(self._handle, encoded, &out))
        return json.loads(_take(out))

    def trash_plan(self, batches=None, older_than_days=0):
        """What emptying the trash would remove, without removing it."""
        self._require_open()
        cdef bytes encoded
        cdef char *out = NULL
        if batches is None:
            _check(um_trash_plan(self._handle, NULL, int(older_than_days),
                                 &out))
        else:
            encoded = json.dumps([str(b) for b in batches]).encode("utf-8")
            _check(um_trash_plan(self._handle, encoded, int(older_than_days),
                                 &out))
        return json.loads(_take(out))

    def trash_holding(self):
        """What the whole trash occupies: files and bytes."""
        self._require_open()
        cdef char *out = NULL
        _check(um_trash_holding(self._handle, &out))
        return json.loads(_take(out))

    def detect_faces(self, long long item_id, backend=None):
        """Run the detector over one item and report what it found.

        Nothing is stored. `backend` is the executable to run; None takes
        the default.
        """
        self._require_open()
        cdef bytes encoded
        cdef char *out = NULL
        if backend is None:
            _check(um_detect_faces(self._handle, item_id, NULL, &out))
        else:
            encoded = str(backend).encode("utf-8")
            _check(um_detect_faces(self._handle, item_id, encoded, &out))
        return json.loads(_take(out))

    def replace_faces(self, long long item_id, faces):
        """Replace every face recorded against one item.

        The whole set is written, so a caller keeping one must send it back.
        """
        self._require_open()
        cdef bytes encoded = json.dumps(list(faces)).encode("utf-8")
        _check(um_replace_faces(self._handle, item_id, encoded))

    def vision_store_document(self, long long item_id, model, caption,
                              embedding, labels=None):
        """Record one item's embedding under a model, with its caption.

        For a caller that ran its own model and holds a vector.
        """
        self._require_open()
        cdef bytes m = str(model).encode("utf-8")
        cdef bytes c = str(caption).encode("utf-8")
        cdef bytes e = json.dumps([float(v) for v in embedding]).encode("utf-8")
        cdef bytes l
        if labels is None:
            _check(um_vision_store_document(self._handle, item_id, m, c,
                                            NULL, e))
        else:
            l = json.dumps([str(x) for x in labels]).encode("utf-8")
            _check(um_vision_store_document(self._handle, item_id, m, c, l, e))

    def vision_store_annotation(self, long long item_id, model, caption,
                                labels=None):
        """Record a caption and labels without an embedding.

        A description that did not come from a model this library can search
        over.
        """
        self._require_open()
        cdef bytes m = str(model).encode("utf-8")
        cdef bytes c = str(caption).encode("utf-8")
        cdef bytes l
        cdef char *out = NULL
        if labels is None:
            _check(um_vision_store_annotation(self._handle, item_id, m, c,
                                              NULL, &out))
        else:
            l = json.dumps([str(x) for x in labels]).encode("utf-8")
            _check(um_vision_store_annotation(self._handle, item_id, m, c,
                                              l, &out))
        return json.loads(_take(out))

    def vision_semantic_search(self, model, query, limit=0):
        """Nearest items to a vector the caller already has.

        Rather than to text this library would have to embed first.
        """
        self._require_open()
        cdef bytes m = str(model).encode("utf-8")
        cdef bytes q = json.dumps([float(v) for v in query]).encode("utf-8")
        cdef char *out = NULL
        _check(um_vision_semantic_search(self._handle, m, q, int(limit), &out))
        return json.loads(_take(out))

    def vision_index_text(self, long long item_id, endpoint, model, text,
                          caption, labels=None):
        """Embed a piece of text through the endpoint and store it.

        The network reach is the caller's to allow.
        """
        self._require_open()
        cdef bytes e = str(endpoint).encode("utf-8")
        cdef bytes m = str(model).encode("utf-8")
        cdef bytes t = str(text).encode("utf-8")
        cdef bytes c = str(caption).encode("utf-8")
        cdef bytes l
        if labels is None:
            _check(um_vision_index_text(self._handle, item_id, e, m, t, c,
                                        NULL))
        else:
            l = json.dumps([str(x) for x in labels]).encode("utf-8")
            _check(um_vision_index_text(self._handle, item_id, e, m, t, c, l))


def sync_available():
    """Whether the external transfer tool is installed."""
    _ensure_init()
    cdef int available = 0
    _check(um_sync_available(&available))
    return available != 0


def media_available():
    """Whether a frame can be decoded out of a video, which needs an external
    ffmpeg. Probing does not, so a machine without it still catalogues videos
    and only goes without their thumbnails."""
    _ensure_init()
    cdef int available = 0
    _check(um_media_available(&available))
    return available != 0


def audio_available():
    """Whether the external acoustic fingerprinter is installed."""
    _ensure_init()
    cdef int available = 0
    _check(um_audio_available(&available))
    return available != 0


def probe_media(path):
    """What a video file is: the size its decoder produces, the size it is
    shown at, its rotation in clockwise degrees, duration, codec and
    container. Read in process; no external program runs."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_media_probe_json(encoded, &out))
    return json.loads(_take(out))


def audio_fingerprint(path, max_seconds=120):
    """The acoustic fingerprint of an audio file, computed in process."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_audio_fingerprint_json(encoded, max_seconds, &out))
    return json.loads(_take(out))


def audio_similarity(first, second):
    """How alike two fingerprints are, from 0 to 1.

    Each is what :func:`audio_fingerprint` returned, so two files fingerprinted
    at different times are compared without keeping the engine's types.
    """
    _ensure_init()
    cdef bytes a = json.dumps(first).encode("utf-8")
    cdef bytes b = json.dumps(second).encode("utf-8")
    cdef double score = 0.0
    _check(um_audio_similarity(a, b, &score))
    return score


# --- file inspection, no library -------------------------------------------
#
# These answer from a path alone, so they take no Library: a caller deciding
# what to do with a file it has not imported yet needs them before one exists.

_DOMAINS = {"photo": 0, "video": 1, "music": 2, "visual": 3}


cdef _domain_code(domain):
    """The engine's number for a domain name, refusing anything else."""
    try:
        return _DOMAINS[str(domain)]
    except KeyError:
        raise ValueError(
            "domain is one of %s" % ", ".join(sorted(_DOMAINS))) from None


def category_for(domain, path):
    """The category a file falls in for that domain, from its extension.

    An empty string means the domain does not hold that kind of file.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_category_for(_domain_code(domain), encoded, &out))
    return _take(out)


def filename_date(path):
    """The date the file name itself claims, or "" when it claims none."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_filename_date(encoded, &out))
    return _take(out)


def media_coordinates(path):
    """Where the file says it was taken.

    `found` is false when it does not say, which is an ordinary state and not
    a failure.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_media_coordinates(encoded, &out))
    return json.loads(_take(out))


def media_date(path, filename_date=True, birthtime_date=False):
    """The date to file this media under, and which source it came from.

    The two flags say whether the file name and the birth time may be fallen
    back on when the file carries no date of its own.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_media_date(encoded, 1 if filename_date else 0,
                         1 if birthtime_date else 0, &out))
    return json.loads(_take(out))


def is_internal(root, path):
    """Whether the path is the library's own bookkeeping rather than media."""
    _ensure_init()
    cdef bytes r = str(root).encode("utf-8")
    cdef bytes p = str(path).encode("utf-8")
    cdef int answer = 0
    _check(um_is_internal(r, p, &answer))
    return answer != 0


def apple_double_verdict(path):
    """Whether an AppleDouble sidecar may be removed, and why either way."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_apple_double_verdict(encoded, &out))
    return json.loads(_take(out))


def can_write_date(rel_path):
    """Whether a date correction can reach this file, from its name alone."""
    _ensure_init()
    cdef bytes encoded = str(rel_path).encode("utf-8")
    cdef int answer = 0
    _check(um_can_write_date(encoded, &answer))
    return answer != 0


def can_strip(rel_path):
    """Whether stripping can rewrite this file, from its name alone."""
    _ensure_init()
    cdef bytes encoded = str(rel_path).encode("utf-8")
    cdef int answer = 0
    _check(um_can_strip(encoded, &answer))
    return answer != 0


def checked_path_under(root, path):
    """The path resolved under the root, refused if it escapes it.

    Resolved against the working directory, not against the root, so a caller
    joins the two itself first -- which is what the engine's own callers do.
    """
    _ensure_init()
    cdef bytes r = str(root).encode("utf-8")
    cdef bytes p = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_checked_path_under(r, p, &out))
    return _take(out)


def iso_now():
    """The current UTC instant, in the format every timestamp here uses."""
    _ensure_init()
    cdef char *out = NULL
    _check(um_iso_now(&out))
    return _take(out)


def new_batch_id():
    """A fresh batch identifier, the kind the engine stamps its own with."""
    _ensure_init()
    cdef char *out = NULL
    _check(um_new_batch_id(&out))
    return _take(out)


# --- hashing and sync, no library ------------------------------------------


def blake3_file(path, buffer_size=0):
    """The content digest of one file, as lowercase hex.

    A `buffer_size` of zero takes the engine's own.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_blake3_file(encoded, int(buffer_size), NULL, NULL, &out))
    return _take(out)


def video_frame_hashes(path, samples=0):
    """Perceptual hashes of frames sampled across a video.

    Decimal strings, not numbers: a 64-bit hash does not survive a JSON
    parser that reads every number as a double. Zero takes the engine's own
    sample count.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_video_frame_hashes(encoded, int(samples), &out))
    return json.loads(_take(out))


def perceptual_hash_file(path):
    """The perceptual hash of an image, and the size it was computed over."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_perceptual_hash_file(encoded, &out))
    return json.loads(_take(out))


def parse_sync_manifest(data):
    """Read a sync manifest, so a caller can check one before acting on it."""
    _ensure_init()
    cdef bytes encoded = str(data).encode("utf-8")
    cdef char *out = NULL
    _check(um_parse_sync_manifest(encoded, &out))
    return json.loads(_take(out))


def diff_sync_manifests(local, remote):
    """What separates two manifests, each given as text."""
    _ensure_init()
    cdef bytes a = str(local).encode("utf-8")
    cdef bytes b = str(remote).encode("utf-8")
    cdef char *out = NULL
    _check(um_diff_sync_manifests(a, b, &out))
    return json.loads(_take(out))


# --- media inspection, no library ------------------------------------------


def probe_sound(path):
    """What an audio file is, from its header, with whatever tags it carries.

    `durationSeconds` is absent where the container does not state it: Ogg
    keeps it in the last page and MPEG audio in an optional header, and a
    guess reported as a duration is worse than none.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_probe_sound(encoded, &out))
    return json.loads(_take(out))


def probe_still(path):
    """What a still image is: its size and the container it sits in.

    A photograph has no `moov` box, so `probe_media` cannot answer for one.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_probe_still(encoded, &out))
    return json.loads(_take(out))


def parse_gpx(path):
    """The track points a GPX file holds."""
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    _check(um_parse_gpx(encoded, &out))
    return json.loads(_take(out))


def audio_offset_similarity(first, second, max_shift=0):
    """`audio_similarity` allowing one recording to start later than the other.

    Which is what two rips of the same track usually differ by. Zero takes
    the engine's own bound.
    """
    _ensure_init()
    cdef bytes a = json.dumps(first).encode("utf-8")
    cdef bytes b = json.dumps(second).encode("utf-8")
    cdef double score = 0.0
    _check(um_audio_offset_similarity(a, b, int(max_shift), &score))
    return score


def read_config(root):
    """The settings a library root holds, read without opening it."""
    _ensure_init()
    cdef bytes encoded = str(root).encode("utf-8")
    cdef char *out = NULL
    _check(um_read_config(encoded, &out))
    return json.loads(_take(out))


def default_config(domain="photo"):
    """What creating a library would write for that domain."""
    _ensure_init()
    cdef char *out = NULL
    _check(um_default_config(_domain_code(domain), &out))
    return json.loads(_take(out))


def hardlinks_supported(root):
    """Whether this filesystem has hard links, asked before anything moves.

    A network share often does not, and finding out afterwards is worse.
    """
    _ensure_init()
    cdef bytes encoded = str(root).encode("utf-8")
    cdef int answer = 0
    _check(um_hardlinks_supported(encoded, &answer))
    return answer != 0


def validate_curation_patch(patch):
    """Whether a curation patch is self-consistent.

    Raises `UniMediaError` when it is not, so the caller learns which field.
    """
    _ensure_init()
    cdef bytes encoded = json.dumps(patch).encode("utf-8")
    _check(um_validate_curation_patch(encoded))
    return True


def parse_vision_description(raw):
    """The caption and labels out of a model's raw reply."""
    _ensure_init()
    cdef bytes encoded = str(raw).encode("utf-8")
    cdef char *out = NULL
    _check(um_vision_parse_description(encoded, &out))
    return json.loads(_take(out))


def vision_embedding(endpoint, model, text, timeout_ms=0):
    """The embedding an endpoint returns for a string.

    No library is involved: this is the model call on its own. Zero takes the
    engine's own timeout.
    """
    _ensure_init()
    cdef bytes e = str(endpoint).encode("utf-8")
    cdef bytes m = str(model).encode("utf-8")
    cdef bytes t = str(text).encode("utf-8")
    cdef char *out = NULL
    _check(um_vision_embedding(e, m, t, int(timeout_ms), &out))
    return json.loads(_take(out))


def vision_describe_file(endpoint, model, image_path, timeout_ms=0):
    """What a vision model says about one image file.

    Takes a path rather than an item, so it answers for a file that is in no
    library.
    """
    _ensure_init()
    cdef bytes e = str(endpoint).encode("utf-8")
    cdef bytes m = str(model).encode("utf-8")
    cdef bytes p = str(image_path).encode("utf-8")
    cdef char *out = NULL
    _check(um_vision_describe_file(e, m, p, int(timeout_ms), &out))
    return json.loads(_take(out))


def decode_frame(path, max_edge=512, seek_seconds=0.0):
    """One frame as RGBA bytes, with the size it came back at.

    Returns `(pixels, width, height)`, where `pixels` is `width * height * 4`
    bytes. A still is decoded in process; a video frame goes through the
    backend the platform provides.
    """
    _ensure_init()
    cdef bytes encoded = str(path).encode("utf-8")
    cdef unsigned char *pixels = NULL
    cdef size_t length = 0
    cdef int width = 0
    cdef int height = 0
    _check(um_decode_frame(encoded, int(max_edge), float(seek_seconds),
                           &pixels, &length, &width, &height))
    try:
        # Copied out before the buffer goes back: what is returned outlives it.
        return pixels[:length], width, height
    finally:
        um_buffer_free(pixels)

