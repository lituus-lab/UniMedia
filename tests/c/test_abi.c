// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Links include/UniMedia.h against the static library, so a header that drifts
 * from src/UniMedia/c_api.nim fails to compile rather than at a caller's site.
 *
 * It drives a throwaway library end to end: open, scan, count, page, dedup,
 * organize plan. Two identical images make the duplicate assertion meaningful.
 * The library root comes from UNIMEDIA_C_TEST_DIR, which the ctest task
 * prepares with `om catalog init`.
 */
#include "UniMedia.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int progress_calls;

static void count_progress(const char *phase, int current, int total,
                           const char *message, void *user_data) {
  (void)phase; (void)current; (void)total; (void)message;
  (*(int *)user_data)++;
}

static int always_cancel(void *user_data) {
  (void)user_data;
  return 1;
}

static void write_ppm(const char *path, int red) {
  FILE *f = fopen(path, "w");
  assert(f != NULL);
  fprintf(f, "P3\n2 2\n255\n");
  for (int i = 0; i < 4; i++) fprintf(f, "%d 0 0\n", red);
  fclose(f);
}

int main(void) {
  assert(um_init() == UM_OK);
  /* The library and the header the caller compiled against must agree. A
   * second assertion on a hardcoded number would only repeat the constant. */
  assert(um_abi_version() == UNIMEDIA_ABI_VERSION);
  assert(strlen(um_engine_version()) > 0);

  /* Bad arguments must be reported, not crash. */
  assert(um_library_open(NULL, NULL) == UM_ERR_ARG);
  assert(um_library_close(NULL) == UM_ERR_HANDLE);
  assert(strlen(um_last_error()) > 0);

  const char *root = getenv("UNIMEDIA_C_TEST_DIR");
  assert(root != NULL && "set UNIMEDIA_C_TEST_DIR to a prepared library root");

  char first[600], second[600], inbox[600];
  snprintf(first, sizeof first, "%s/one.ppm", root);
  snprintf(second, sizeof second, "%s/two.ppm", root);
  snprintf(inbox, sizeof inbox, "%s/inbox", root);
  write_ppm(first, 9);
  write_ppm(second, 9); /* identical bytes: an exact duplicate */

  /* A folder that is not a library yet: the caller can tell, and can make one
   * without the user writing a config by hand. */
  char fresh[600], fresh_image[600];
  /* A sibling, not a child: a folder inside the library would be scanned as
   * part of it. */
  snprintf(fresh, sizeof fresh, "%s-fresh", root);
  assert(mkdir(fresh, 0755) == 0);
  snprintf(fresh_image, sizeof fresh_image, "%s/photo.ppm", fresh);
  write_ppm(fresh_image, 5);

  int present = 1;
  assert(um_library_exists(fresh, &present) == UM_OK);
  assert(present == 0);
  assert(um_library_exists(root, &present) == UM_OK);
  assert(present == 1);
  assert(um_library_exists(NULL, &present) == UM_ERR_ARG);

  um_library created = NULL;
  assert(um_library_init(fresh, "visual", NULL, &created) == UM_OK);
  assert(created != NULL);
  assert(um_library_exists(fresh, &present) == UM_OK);
  assert(present == 1);
  /* Creating catalogues nothing by itself: the scan is a separate step, and
   * the media are untouched until then. */
  int fresh_count = -1;
  assert(um_item_count(created, NULL, &fresh_count) == UM_OK);
  assert(fresh_count == 0);
  char *fresh_scan = NULL;
  assert(um_scan(created, 1, NULL, NULL, NULL, &fresh_scan) == UM_OK);
  assert(strstr(fresh_scan, "\"indexed\":1") != NULL);
  um_buffer_free(fresh_scan);
  assert(um_library_close(created) == UM_OK);

  /* A second creation is refused rather than overwriting what is there. */
  assert(um_library_init(fresh, "visual", NULL, &created) != UM_OK);
  assert(um_library_init(fresh, "nonsense", NULL, &created) == UM_ERR_ARG);
  assert(um_library_init(fresh, "visual", "sideways", &created) == UM_ERR_ARG);
  assert(um_library_init(NULL, "visual", NULL, &created) == UM_ERR_ARG);

  um_library lib = NULL;
  assert(um_library_open(root, &lib) == UM_OK);
  assert(lib != NULL);

  /* One call performs the scan once. A sizing pass would have run it twice and
   * reported the second, empty result. */
  char *scan = NULL;
  progress_calls = 0;
  assert(um_scan(lib, 1, count_progress, NULL, &progress_calls, &scan) == UM_OK);
  assert(strstr(scan, "\"indexed\":2") != NULL);
  /* One event per indexed file. */
  assert(progress_calls == 2);
  um_buffer_free(scan);

  /* What a scan told to skip perceptual hashing leaves behind. The scan above
   * skipped it, so both PPMs still owe one. */
  int owing = -1;
  assert(um_phash_pending_count(lib, &owing) == UM_OK);
  assert(owing == 2);
  assert(um_phash_pending_count(lib, NULL) == UM_ERR_ARG);

  /* Preferences round-trip: read, change one key, read back. */
  char *prefs = NULL;
  assert(um_config_json(lib, &prefs) == UM_OK);
  assert(strstr(prefs, "\"schemaVersion\":1") != NULL);
  assert(strstr(prefs, "\"scheme\":\"YYYY/MM-DD\"") != NULL);
  um_buffer_free(prefs);

  assert(um_config_set(lib, "{\"scheme\":\"flat\",\"noDateDir\":\"undated\"}")
         == UM_OK);
  assert(um_config_json(lib, &prefs) == UM_OK);
  assert(strstr(prefs, "\"scheme\":\"flat\"") != NULL);
  assert(strstr(prefs, "\"noDateDir\":\"undated\"") != NULL);
  /* An untouched key keeps its value. */
  assert(strstr(prefs, "\"domain\":\"photo\"") != NULL);
  um_buffer_free(prefs);

  /* Rejected settings change nothing. */
  assert(um_config_set(lib, "{\"scheme\":\"nonsense\"}") == UM_ERR_ARG);
  assert(um_config_set(lib, "{\"schemaVersion\":2}") == UM_ERR_ARG);
  assert(um_config_set(lib, "{\"unknown\":1}") == UM_ERR_ARG);
  assert(um_config_set(lib, "{\"filenameDate\":\"yes\"}") == UM_ERR_ARG);
  assert(um_config_set(lib, "not json") == UM_ERR_ARG);
  assert(um_config_set(lib, NULL) == UM_ERR_ARG);
  assert(um_config_json(lib, &prefs) == UM_OK);
  assert(strstr(prefs, "\"scheme\":\"flat\"") != NULL);
  um_buffer_free(prefs);
  /* Restore, so the organize plan below runs on the documented default. */
  assert(um_config_set(lib,
      "{\"scheme\":\"YYYY/MM-DD\",\"noDateDir\":\"_no-date\"}") == UM_OK);

  int count = 0;
  assert(um_item_count(lib, NULL, &count) == UM_OK);
  assert(count == 2);
  assert(um_item_count(lib, "video", &count) == UM_OK);
  assert(count == 0);

  char *items = NULL;
  assert(um_items_json(lib, NULL, 10, 0, &items) == UM_OK);
  assert(strstr(items, "\"path\":\"one.ppm\"") != NULL);
  assert(strstr(items, "\"source\":\"file\"") != NULL);
  /* The schema must not leak through the ABI. */
  assert(strstr(items, "user_version") == NULL);
  assert(strstr(items, "item_hashes") == NULL);
  um_buffer_free(items);

  char *rejected = NULL;
  assert(um_items_json(lib, NULL, 0, 0, &rejected) == UM_ERR_ARG);
  assert(um_items_json(lib, NULL, 10, -1, &rejected) == UM_ERR_ARG);
  assert(um_items_json(lib, NULL, 10, 0, NULL) == UM_ERR_ARG);

  int64_t run = 0;
  assert(um_dedup_find(lib, "exact", 95.0, NULL, NULL, NULL, &run) == UM_OK);
  assert(run > 0);
  assert(um_dedup_find(lib, "nonsense", 95.0, NULL, NULL, NULL, &run)
         == UM_ERR_ARG);

  /* Cancelling reports UM_ERR_CANCELLED rather than a partial success. */
  int64_t cancelled_run = 0;
  assert(um_dedup_find(lib, "exact", 95.0, NULL, always_cancel, NULL,
                       &cancelled_run) == UM_ERR_CANCELLED);

  char *review = NULL;
  assert(um_dedup_review_json(lib, 0, &review) == UM_OK);
  assert(strstr(review, "\"kind\":\"exact\"") != NULL);
  assert(strstr(review, "\"keeper\":true") != NULL);
  um_buffer_free(review);

  char *plan = NULL;
  assert(um_organize_plan_json(lib, inbox, NULL, 0, &plan) == UM_OK);
  assert(strstr(plan, "\"operations\"") != NULL);
  um_buffer_free(plan);

  assert(um_organize_plan_json(lib, NULL, NULL, 0, &plan) == UM_ERR_ARG);

  /* Keeper selection, then a recoverable removal, then undo. */
  char *review2 = NULL;
  assert(um_dedup_review_json(lib, run, &review2) == UM_OK);
  um_buffer_free(review2);
  assert(um_dedup_keep(lib, 1, 2) == UM_OK);
  char *removed = NULL;
  assert(um_dedup_remove(lib, run, &removed) == UM_OK);
  assert(strstr(removed, "\"batch\"") != NULL);
  um_buffer_free(removed);
  int after = 0;
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 1); /* the keeper survives, its twin is in the trash */

  char *undo_plan = NULL;
  assert(um_undo_plan_json(lib, NULL, &undo_plan) == UM_OK);
  um_buffer_free(undo_plan);
  char *undone = NULL;
  assert(um_undo_apply(lib, NULL, NULL, NULL, &undone) == UM_OK);
  assert(strstr(undone, "\"undone\"") != NULL);
  um_buffer_free(undone);
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 2); /* restored */

  /* Dates: a plan says what would change; a bad mode is refused. */
  char *dates = NULL;
  assert(um_dates_plan_json(lib, "[1]", "set", "2026-07-14 20:30:00", &dates)
         == UM_OK);
  assert(strstr(dates, "\"newDate\":\"2026-07-14 20:30:00\"") != NULL);
  um_buffer_free(dates);
  assert(um_dates_plan_json(lib, "[1]", "sideways", "1", &dates) == UM_ERR_ARG);
  assert(um_dates_plan_json(lib, "[1]", "shift", "not a number", &dates)
         == UM_ERR_ARG);
  assert(um_dates_plan_json(lib, "[]", "set", "2026-07-14 20:30:00", &dates)
         == UM_ERR_ARG);

  char *applied_dates = NULL;
  assert(um_dates_apply(lib, "[1]", "set", "2026-07-14 20:30:00", NULL, NULL,
                        NULL, &applied_dates) == UM_OK);
  assert(strstr(applied_dates, "\"applied\":1") != NULL);
  um_buffer_free(applied_dates);
  /* A shift now has a date to work from. */
  assert(um_dates_apply(lib, "[1]", "shift", "3600", NULL, NULL, NULL,
                        &applied_dates) == UM_OK);
  um_buffer_free(applied_dates);
  assert(um_dates_apply(lib, "[1]", "shift", "0", NULL, NULL, NULL,
                        &applied_dates) == UM_ERR_ARG);

  /* GPX: a track that places nothing is a refusal, not an empty success. */
  char gpx[600];
  snprintf(gpx, sizeof gpx, "%s/track.gpx", root);
  FILE *track = fopen(gpx, "w");
  assert(track != NULL);
  fprintf(track,
    "<?xml version=\"1.0\"?><gpx><trk><trkseg>"
    "<trkpt lat=\"48.8566\" lon=\"2.3522\">"
    "<time>2026-07-14T21:30:00Z</time></trkpt>"
    "</trkseg></trk></gpx>\n");
  fclose(track);

  char *gpx_plan = NULL;
  assert(um_gpx_plan_json(lib, gpx, NULL, 300, 0, 0, &gpx_plan) == UM_OK);
  assert(strstr(gpx_plan, "\"trackPointCount\":1") != NULL);
  assert(strstr(gpx_plan, "\"matched\":true") != NULL);
  um_buffer_free(gpx_plan);
  assert(um_gpx_plan_json(lib, gpx, NULL, -1, 0, 0, &gpx_plan) == UM_ERR_ARG);
  assert(um_gpx_plan_json(lib, gpx, NULL, 300, 100000, 0, &gpx_plan) == UM_ERR_ARG);
  assert(um_gpx_plan_json(lib, NULL, NULL, 300, 0, 0, &gpx_plan) == UM_ERR_ARG);

  char *placed = NULL;
  assert(um_gpx_apply(lib, gpx, NULL, 300, 0, 0, NULL, NULL, NULL, &placed)
         == UM_OK);
  assert(strstr(placed, "\"applied\":1") != NULL);
  um_buffer_free(placed);
  /* Zero tolerance matches nothing here, which must be refused. */
  assert(um_gpx_apply(lib, gpx, NULL, 0, 720, 0, NULL, NULL, NULL, &placed)
         == UM_ERR_ARG);

  /* Curation: read what an item carries, change it, read it back. */
  char *curation = NULL;
  assert(um_curation_json(lib, 1, &curation) == UM_OK);
  assert(strstr(curation, "\"rating\":0") != NULL);
  assert(strstr(curation, "\"keywords\":[]") != NULL);
  um_buffer_free(curation);

  assert(um_curate_item(lib, 1,
      "{\"title\":\"A red square\",\"rating\":4,\"keywords\":[\"test\",\"red\"],"
      "\"creator\":[\"lituus-lab\"],\"copyright\":\"CC0\"}", &curation) == UM_OK);
  assert(strstr(curation, "\"title\":\"A red square\"") != NULL);
  assert(strstr(curation, "\"rating\":4") != NULL);
  assert(strstr(curation, "\"copyright\":\"CC0\"") != NULL);
  um_buffer_free(curation);

  /* An absent key preserves; addKeywords adds without naming the rest. */
  assert(um_curate_item(lib, 1, "{\"addKeywords\":[\"square\"]}", &curation)
         == UM_OK);
  assert(strstr(curation, "\"title\":\"A red square\"") != NULL);
  assert(strstr(curation, "square") != NULL);
  um_buffer_free(curation);

  assert(um_curate_item(lib, 1, "{\"unknown\":1}", &curation) == UM_ERR_ARG);
  assert(um_curate_item(lib, 1, "{\"rating\":9}", &curation) == UM_ERR_ARG);
  assert(um_curate_item(lib, 1, "not json", &curation) == UM_ERR_ARG);
  assert(um_curate_item(lib, 1, NULL, &curation) == UM_ERR_ARG);

  char *keywords = NULL;
  assert(um_keywords_json(lib, NULL, 10, &keywords) == UM_OK);
  assert(strstr(keywords, "\"keyword\":\"red\"") != NULL);
  um_buffer_free(keywords);
  assert(um_keywords_json(lib, "sq", 10, &keywords) == UM_OK);
  assert(strstr(keywords, "square") != NULL);
  assert(strstr(keywords, "\"red\"") == NULL);  /* the prefix is honoured */
  um_buffer_free(keywords);
  assert(um_keywords_json(lib, NULL, 0, &keywords) == UM_ERR_ARG);

  char *batch = NULL;
  assert(um_curation_batch_apply(lib, "[1,2]", "{\"rating\":3}", NULL, NULL,
                                 NULL, &batch) == UM_OK);
  assert(strstr(batch, "\"applied\":2") != NULL);
  assert(strstr(batch, "\"failed\":0") != NULL);
  um_buffer_free(batch);
  assert(um_curation_batch_apply(lib, "[]", "{\"rating\":3}", NULL, NULL,
                                 NULL, &batch) == UM_ERR_ARG);
  assert(um_curation_batch_apply(lib, "[1]", "{\"nope\":1}", NULL, NULL,
                                 NULL, &batch) == UM_ERR_ARG);

  /* The trash answers even when it is empty, and emptying nothing is refused
   * rather than reported as a success. */
  {
    char *listed = NULL;
    assert(um_trash_list_json(lib, &listed) == UM_OK);
    assert(strstr(listed, "batches") != NULL);
    um_buffer_free(listed);
    assert(um_trash_empty(lib, "not json", 0, NULL, NULL, &listed) ==
           UM_ERR_ARG);
  }

  /* Cleanup: a plan answers even when it finds nothing, and a kind that does
   * not exist is refused rather than quietly ignored. */
  {
    char *plan = NULL;
    assert(um_cleanup_plan_json(lib, NULL, &plan) == UM_OK);
    assert(strstr(plan, "entries") != NULL);
    um_buffer_free(plan);
    assert(um_cleanup_plan_json(lib, "[\"os-junk\"]", &plan) == UM_OK);
    um_buffer_free(plan);
    assert(um_cleanup_plan_json(lib, "[\"nonsense\"]", &plan) == UM_ERR_ARG);
    assert(um_cleanup_plan_json(lib, "not json", &plan) == UM_ERR_ARG);
  }

  /* Privacy: the audit reads, the plan changes nothing, and a bad selection
   * is refused. PPM carries no metadata, so what is asserted here is the shape
   * of the contract, not a stripped file. */
  char *audit_privacy = NULL;
  assert(um_privacy_audit_json(lib, &audit_privacy) == UM_OK);
  /* Only items that disclose something are reported: a PPM carries no
   * metadata, so a clean library reports an empty array. */
  assert(audit_privacy[0] == '[');
  assert(strcmp(audit_privacy, "[]") == 0);
  um_buffer_free(audit_privacy);

  char *strip_plan = NULL;
  assert(um_privacy_strip_plan_json(lib, NULL, &strip_plan) == UM_OK);
  assert(strstr(strip_plan, "\"entries\"") != NULL);
  um_buffer_free(strip_plan);
  assert(um_privacy_strip_plan_json(lib, "[1]", &strip_plan) == UM_OK);
  assert(strstr(strip_plan, "\"item\":1") != NULL);
  um_buffer_free(strip_plan);

  assert(um_privacy_strip_plan_json(lib, "[0]", &strip_plan) == UM_ERR_ARG);
  assert(um_privacy_strip_plan_json(lib, "[\"x\"]", &strip_plan) == UM_ERR_ARG);
  assert(um_privacy_strip_plan_json(lib, "not json", &strip_plan) == UM_ERR_ARG);
  char *stripped = NULL;
  assert(um_privacy_strip_apply(lib, "[9999]", NULL, NULL, &stripped)
         == UM_ERR_ARG);
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 2); /* a refused strip leaves the catalogue alone */

  /* Removing catalogued items outright, with no duplicate run involved. */
  char *dropped = NULL;
  assert(um_items_remove(lib, "[1]", &dropped) == UM_OK);
  assert(strstr(dropped, "\"applied\":1") != NULL);
  um_buffer_free(dropped);
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 1);
  /* And it is the same journalled trash, so undo brings it back. */
  char *restored = NULL;
  assert(um_undo_apply(lib, NULL, NULL, NULL, &restored) == UM_OK);
  um_buffer_free(restored);
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 2);

  assert(um_items_remove(lib, "[]", &dropped) == UM_ERR_ARG);
  assert(um_items_remove(lib, "[\"one\"]", &dropped) == UM_ERR_ARG);
  assert(um_items_remove(lib, "not json", &dropped) == UM_ERR_ARG);
  assert(um_items_remove(lib, NULL, &dropped) == UM_ERR_ARG);
  /* An unknown id fails the request rather than removing the rest of it. */
  assert(um_items_remove(lib, "[1,9999]", &dropped) != UM_OK);
  assert(um_item_count(lib, NULL, &after) == UM_OK);
  assert(after == 2);

  /* An explicit scheme overrides the library preference; a bad one is rejected
   * before anything is planned. */
  char *flat = NULL;
  assert(um_organize_plan_json(lib, inbox, "flat", 0, &flat) == UM_OK);
  um_buffer_free(flat);
  assert(um_organize_plan_json(lib, inbox, "nonsense", 0, &flat) == UM_ERR_ARG);

  /* Thumbnails: the grid's only raster source. */
  char *thumb = NULL;
  assert(um_thumbnail_json(lib, 1, 64, &thumb) == UM_OK);
  assert(strstr(thumb, "\"maxEdge\":64") != NULL);
  assert(strstr(thumb, ".om-cache") != NULL);
  um_buffer_free(thumb);
  assert(um_thumbnail_json(lib, 1, 0, &thumb) == UM_ERR_RUNTIME);

  char *audit = NULL;
  assert(um_integrity_audit_json(lib, 0, NULL, NULL, NULL, &audit) == UM_OK);
  assert(strstr(audit, "\"checked\":2") != NULL);
  um_buffer_free(audit);

  /* ---- Albums, both kinds --------------------------------------------- */
  char *out = NULL;
  assert(um_albums_json(lib, &out) == UM_OK);
  assert(strcmp(out, "[]") == 0);   /* none yet, and that is not an error */
  um_buffer_free(out);

  assert(um_album_create(lib, "Holidays", &out) == UM_OK);
  assert(strstr(out, "\"name\":\"Holidays\"") != NULL);
  long long album = 0;
  {
    const char *at = strstr(out, "\"id\":");
    assert(at != NULL);
    album = atoll(at + 5);
    assert(album > 0);
  }
  um_buffer_free(out);
  assert(um_album_create(lib, "", &out) == UM_ERR_ARG);

  int added = -1;
  assert(um_album_add_item(lib, album, 1, &added) == UM_OK);
  assert(added == 1);
  /* Adding twice is how a caller makes sure, so it is not a failure. */
  assert(um_album_add_item(lib, album, 1, &added) == UM_OK);
  assert(added == 0);

  assert(um_album_items_json(lib, album, &out) == UM_OK);
  assert(strstr(out, "\"id\":1") != NULL);
  um_buffer_free(out);

  assert(um_album_json(lib, album, &out) == UM_OK);
  assert(strstr(out, "\"itemCount\":1") != NULL);
  um_buffer_free(out);

  assert(um_album_set_cover(lib, album, 1, &out) == UM_OK);
  assert(strstr(out, "\"coverItemId\":1") != NULL);
  um_buffer_free(out);
  assert(um_album_set_cover(lib, album, 0, &out) == UM_OK);
  assert(strstr(out, "\"coverItemId\":0") != NULL);
  um_buffer_free(out);

  /* Albums nest, and a cycle is refused however long the chain. */
  {
    char *inner = NULL;
    assert(um_album_create(lib, "Inner", &inner) == UM_OK);
    long long child = atoll(strstr(inner, "\"id\":") + 5);
    um_buffer_free(inner);
    assert(um_album_set_parent(lib, child, album, &out) == UM_OK);
    assert(strstr(out, "\"parentId\":") != NULL);
    um_buffer_free(out);
    assert(um_album_children_json(lib, album, &out) == UM_OK);
    assert(strstr(out, "\"name\":\"Inner\"") != NULL);
    um_buffer_free(out);
    /* The album cannot contain the album that contains it. */
    assert(um_album_set_parent(lib, album, child, &out) == UM_ERR_RUNTIME);
    assert(um_album_set_parent(lib, album, album, &out) == UM_ERR_RUNTIME);
    /* Back to the top, then gone. */
    assert(um_album_set_parent(lib, child, 0, &out) == UM_OK);
    um_buffer_free(out);
    assert(um_album_delete(lib, child) == UM_OK);
  }

  assert(um_album_rename(lib, album, "Trips", &out) == UM_OK);
  assert(strstr(out, "\"name\":\"Trips\"") != NULL);
  um_buffer_free(out);

  int taken_out = -1;
  assert(um_album_remove_item(lib, album, 1, &taken_out) == UM_OK);
  assert(taken_out == 1);
  assert(um_album_remove_item(lib, album, 1, &taken_out) == UM_OK);
  assert(taken_out == 0);
  assert(um_album_delete(lib, album) == UM_OK);

  assert(um_smart_album_create(lib, "Photos", 1,
    "[{\"field\":\"kind\",\"operator\":\"eq\",\"value\":\"image\"}]",
    &out) == UM_OK);
  long long smart = 0;
  {
    const char *at = strstr(out, "\"id\":");
    assert(at != NULL);
    smart = atoll(at + 5);
  }
  assert(strstr(out, "\"matchAll\":true") != NULL);
  um_buffer_free(out);
  /* Rules are checked by the engine, so a nonsense field is refused. */
  assert(um_smart_album_create(lib, "Bad", 1, "[{\"field\":\"nope\"}]",
    &out) == UM_ERR_ARG);
  assert(um_smart_album_create(lib, "Bad", 1, "not json", &out) == UM_ERR_ARG);

  assert(um_smart_album_json(lib, smart, &out) == UM_OK);
  assert(strstr(out, "\"field\":\"kind\"") != NULL);
  um_buffer_free(out);
  assert(um_smart_album_items_json(lib, smart, &out) == UM_OK);
  um_buffer_free(out);
  assert(um_smart_albums_json(lib, &out) == UM_OK);
  assert(strstr(out, "\"name\":\"Photos\"") != NULL);
  um_buffer_free(out);
  assert(um_smart_album_rename(lib, smart, "Pictures", &out) == UM_OK);
  um_buffer_free(out);
  assert(um_smart_album_delete(lib, smart) == UM_OK);

  /* ---- People and faces ------------------------------------------------ */
  assert(um_people_json(lib, &out) == UM_OK);
  assert(strcmp(out, "[]") == 0);
  um_buffer_free(out);
  assert(um_faces_json(lib, 0, &out) == UM_OK);
  um_buffer_free(out);

  long long person = 0;
  assert(um_person_create(lib, "Ada", &person) == UM_OK);
  assert(person > 0);
  assert(um_person_create(lib, "", &person) == UM_ERR_ARG);
  assert(um_people_json(lib, &out) == UM_OK);
  assert(strstr(out, "\"name\":\"Ada\"") != NULL);
  um_buffer_free(out);
  assert(um_faces_clear(lib, 1, 0) == UM_OK);
  assert(um_faces_cluster_json(lib, 8, &out) == UM_OK);
  um_buffer_free(out);
  /* Out of range is refused, never clamped into range. */
  assert(um_faces_cluster_json(lib, 99, &out) == UM_ERR_ARG);

  /* ---- Time, place, sync, vision --------------------------------------- */
  assert(um_timeline_json(lib, "month", &out) == UM_OK);
  um_buffer_free(out);
  assert(um_timeline_json(lib, NULL, &out) == UM_OK);   /* NULL means month */
  um_buffer_free(out);
  assert(um_timeline_json(lib, "fortnight", &out) == UM_ERR_ARG);

  /* No endpoint means no network call, so the plan comes from the cache
   * alone. These items have never been looked up, so it fails rather than
   * inventing a place for them -- which is the answer that matters. */
  /* These items were given coordinates by the GPX step above, so a plan has
   * something to look up -- and with no endpoint there is nothing to look it
   * up with, which is an error rather than an invented place. */
  assert(um_geocode_plan_json(lib, "nominatim", "en", NULL, NULL, 0, 0,
                              &out) == UM_ERR_RUNTIME);
  assert(strstr(um_last_error(), "provider") != NULL);
  /* The two rules the command line applies, applied here too. */
  assert(um_geocode_plan_json(lib, "", "en", NULL, NULL, 0, 0,
                              &out) == UM_ERR_ARG);
  assert(um_geocode_plan_json(lib, "nominatim", "en", NULL, NULL, 0, 1,
                              &out) == UM_ERR_ARG);

  assert(um_sync_manifest_json(lib, &out) == UM_OK);
  um_buffer_free(out);
  int available = -1;
  assert(um_sync_available(&available) == UM_OK);
  assert(available == 0 || available == 1);
  assert(um_sync_runs_json(lib, NULL, 10, &out) == UM_OK);
  um_buffer_free(out);
  assert(um_sync_runs_json(lib, NULL, 0, &out) == UM_ERR_ARG);
  assert(um_sync_plan_json(lib, "", 1, &out) == UM_ERR_ARG);

  assert(um_vision_annotations_json(lib, 0, &out) == UM_OK);
  um_buffer_free(out);
  assert(um_vision_search_json(lib, NULL, "m", "q", 5, &out) == UM_ERR_ARG);
  assert(um_vision_search_json(lib, "e", "m", "q", 0, &out) == UM_ERR_ARG);

  /* ---- Media and audio -------------------------------------------------- */
  assert(um_media_available(&available) == UM_OK);
  assert(available == 0 || available == 1);
  assert(um_audio_available(&available) == UM_OK);
  assert(um_media_probe_json(NULL, &out) == UM_ERR_ARG);
  /* A picture is not a movie, so probing one says so rather than guessing. */
  assert(um_media_probe_json(first, &out) != UM_OK);
  assert(um_audio_fingerprint_json("nowhere.mp3", 0, &out) == UM_ERR_ARG);
  {
    /* Two fingerprints compare without the caller keeping engine types; a
     * file's own fingerprint matches itself exactly. */
    const char *print = "{\"durationSeconds\":1.0,\"raw\":[1,2,3]}";
    const char *other = "{\"durationSeconds\":1.0,\"raw\":[1,2,4095]}";
    double score = -1.0;
    assert(um_audio_similarity(print, print, &score) == UM_OK);
    assert(score > 0.999);
    assert(um_audio_similarity(print, other, &score) == UM_OK);
    assert(score >= 0.0 && score < 1.0);
    assert(um_audio_similarity("not json", print, &score) == UM_ERR_ARG);
    assert(um_audio_similarity(NULL, print, &score) == UM_ERR_ARG);
  }

  /* ---- One item, and the ways of finding it ----------------------------- */
  assert(um_item_json(lib, 1, &out) == UM_OK);
  assert(strstr(out, "\"id\":1") != NULL);
  um_buffer_free(out);
  assert(um_item_path(lib, 1, &out) == UM_OK);
  assert(out[0] == '/');            /* absolute, unlike the listing's path */
  um_buffer_free(out);

  assert(um_search_json(lib, "", NULL, 10, 0, &out) == UM_ERR_ARG);
  assert(um_search_json(lib, "a", NULL, 0, 0, &out) == UM_ERR_ARG);
  assert(um_search_json(lib, "a", NULL, 10, 0, &out) == UM_OK);
  um_buffer_free(out);

  /* An empty filter narrows nothing, so it answers with everything. */
  assert(um_filter_json(lib, "{}", 10, 0, &out) == UM_OK);
  assert(strstr(out, "\"id\":1") != NULL);
  um_buffer_free(out);
  assert(um_filter_json(lib, "{\"kind\":\"video\"}", 10, 0, &out) == UM_OK);
  assert(strcmp(out, "[]") == 0);   /* the fixtures are images */
  um_buffer_free(out);
  assert(um_filter_json(lib, "not json", 10, 0, &out) == UM_ERR_ARG);
  assert(um_filter_json(lib, "[]", 10, 0, &out) == UM_ERR_ARG);

  assert(um_place_facets_json(lib, NULL, 10, &out) == UM_OK);
  um_buffer_free(out);
  assert(um_place_facets_json(lib, NULL, 0, &out) == UM_ERR_ARG);

  assert(um_item_meta_json(lib, 1, &out) == UM_OK);
  um_buffer_free(out);
  assert(um_item_meta_set(lib, 1, "{\"note\":\"kept\"}") == UM_OK);
  assert(um_item_meta_json(lib, 1, &out) == UM_OK);
  assert(strstr(out, "kept") != NULL);
  um_buffer_free(out);
  assert(um_item_meta_set(lib, 1, "[]") == UM_ERR_ARG);
  assert(um_item_meta_set(lib, 1, NULL) == UM_ERR_ARG);

  /* Every one of these refuses a handle it does not know. */
  assert(um_albums_json(NULL, &out) == UM_ERR_HANDLE);
  assert(um_people_json(NULL, &out) == UM_ERR_HANDLE);
  assert(um_timeline_json(NULL, "day", &out) == UM_ERR_HANDLE);
  assert(um_item_json(NULL, 1, &out) == UM_ERR_HANDLE);

  /* Linking duplicates: the plan is read-only, and a run with nothing
   * byte-identical left to link says so rather than doing nothing quietly. */
  {
    char *plan = NULL;
    assert(um_dedup_link_plan_json(lib, 0, &plan) == UM_OK);
    um_buffer_free(plan);
    assert(um_dedup_link_plan_json(NULL, 0, &plan) == UM_ERR_HANDLE);
  }

  /* A bounded scan indexes the same files as an unbounded one; only how many
   * are hashed at once changes. */
  {
    char *bounded = NULL;
    assert(um_scan_bounded(lib, 1, 1, NULL, NULL, NULL, &bounded) == UM_OK);
    assert(strstr(bounded, "\"hashErrors\":0") != NULL);
    um_buffer_free(bounded);
    assert(um_scan_bounded(lib, 1, -1, NULL, NULL, NULL, &bounded) ==
           UM_ERR_ARG);
  }

  assert(um_library_close(lib) == UM_OK);
  /* A closed handle is no longer known. */
  assert(um_library_close(lib) == UM_ERR_HANDLE);

  /* And it must not become known again. Freeing the handle would let the
   * allocator hand the same address to the next library, and a caller holding
   * the old one would then reach a library it never opened, silently. */
  {
    um_library reopened = NULL;
    assert(um_library_open(root, &reopened) == UM_OK);
    assert(reopened != lib);
    char *leaked = NULL;
    assert(um_albums_json(lib, &leaked) == UM_ERR_HANDLE);
    assert(um_library_close(reopened) == UM_OK);
  }

  /* File inspection, no library. Each answers from a path alone, so these
   * run outside any open library and must still refuse a null argument. */
  {
    char *text = NULL;
    assert(um_category_for(UM_DOMAIN_PHOTO, "a/b/photo.jpg", &text) == UM_OK);
    assert(text != NULL && text[0] != '\0');
    um_buffer_free(text);
    assert(um_category_for(UM_DOMAIN_PHOTO, NULL, &text) == UM_ERR_ARG);
    assert(um_category_for(-1, "a.jpg", &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_filename_date("IMG_20240115_101500.jpg", &text) == UM_OK);
    assert(text != NULL);
    um_buffer_free(text);

    text = NULL;
    assert(um_media_coordinates("a/b/photo.jpg", &text) == UM_OK);
    assert(strstr(text, "\"found\"") != NULL);
    um_buffer_free(text);

    text = NULL;
    assert(um_media_date("IMG_20240115_101500.jpg", 1, 0, &text) == UM_OK);
    assert(strstr(text, "\"source\"") != NULL);
    um_buffer_free(text);

    text = NULL;
    assert(um_apple_double_verdict("._photo.jpg", &text) == UM_OK);
    assert(strstr(text, "\"removable\"") != NULL);
    um_buffer_free(text);

    int answer = -1;
    assert(um_is_internal(root, "photo.jpg", &answer) == UM_OK);
    assert(answer == 0 || answer == 1);
    assert(um_is_internal(NULL, "photo.jpg", &answer) == UM_ERR_ARG);

    answer = -1;
    assert(um_can_write_date("photo.jpg", &answer) == UM_OK);
    assert(answer == 0 || answer == 1);
    answer = -1;
    assert(um_can_strip("photo.jpg", &answer) == UM_OK);
    assert(answer == 0 || answer == 1);

    /* The path is resolved against the working directory, not against the
     * root, so a caller joins it to the root first -- which is what the
     * engine's own callers do. */
    {
      char joined[4096];
      snprintf(joined, sizeof(joined), "%s/photo.jpg", root);
      text = NULL;
      assert(um_checked_path_under(root, joined, &text) == UM_OK);
      assert(text != NULL && text[0] != '\0');
      um_buffer_free(text);
      /* One climbing back out of the root is refused, not resolved. */
      snprintf(joined, sizeof(joined), "%s/../escape.jpg", root);
      text = NULL;
      assert(um_checked_path_under(root, joined, &text) != UM_OK);
    }

    text = NULL;
    assert(um_iso_now(&text) == UM_OK);
    /* yyyy-mm-ddThh:mm:ssZ */
    assert(strlen(text) == 20 && text[19] == 'Z');
    um_buffer_free(text);

    char *first = NULL;
    char *second = NULL;
    assert(um_new_batch_id(&first) == UM_OK);
    assert(um_new_batch_id(&second) == UM_OK);
    /* Two calls must not hand back the same identifier. */
    assert(strcmp(first, second) != 0);
    um_buffer_free(first);
    um_buffer_free(second);
  }

  /* Hashing and sync, no library. */
  {
    char joined[4096];
    /* A file this test's own fixture library really holds. */
    snprintf(joined, sizeof(joined), "%s/one.ppm", root);
    char *text = NULL;
    assert(um_blake3_file(joined, 0, NULL, NULL, &text) == UM_OK);
    /* BLAKE3 is 32 bytes, so 64 hex characters. */
    assert(strlen(text) == 64);
    um_buffer_free(text);
    assert(um_blake3_file(NULL, 0, NULL, NULL, &text) == UM_ERR_ARG);
    assert(um_blake3_file(joined, -1, NULL, NULL, &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_perceptual_hash_file(joined, &text) == UM_OK);
    assert(strstr(text, "\"hash\"") != NULL);
    um_buffer_free(text);

    /* A manifest the engine really accepts: schemaVersion 1, a relative
     * path, and a digest of exactly 64 hex characters -- a shorter one is
     * refused, which is what makes this a manifest and not free-form JSON. */
    const char *manifest =
      "{\"schemaVersion\":1,\"entries\":[{\"path\":\"a.jpg\","
      "\"digest\":\"000102030405060708090a0b0c0d0e0f"
      "101112131415161718191a1b1c1d1e1f\","
      "\"size\":1,\"mtimeNs\":2}]}";
    text = NULL;
    assert(um_parse_sync_manifest(manifest, &text) == UM_OK);
    assert(strstr(text, "\"a.jpg\"") != NULL);
    um_buffer_free(text);
    assert(um_parse_sync_manifest(NULL, &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_diff_sync_manifests(manifest, manifest, &text) == UM_OK);
    assert(strstr(text, "\"onlyLocal\":[]") != NULL);
    um_buffer_free(text);

    /* One entry against an empty manifest: it can only be local-only. */
    text = NULL;
    assert(um_diff_sync_manifests(manifest,
      "{\"schemaVersion\":1,\"entries\":[]}", &text) == UM_OK);
    assert(strstr(text, "\"onlyLocal\":[\"a.jpg\"]") != NULL);
    um_buffer_free(text);
  }

  /* Library-backed methods. `lib` was closed above, so this block opens its
   * own rather than reaching for a handle the test already retired. */
  {
    um_library work = NULL;
    assert(um_library_open(root, &work) == UM_OK);
    const um_library lib = work;
    char *text = NULL;
    /* Reindexing nothing is a no-op that still reports its shape. */
    assert(um_reindex_paths(lib, "[]", 1, &text) == UM_OK);
    assert(strstr(text, "\"indexed\"") != NULL);
    um_buffer_free(text);
    assert(um_reindex_paths(lib, "not json", 1, &text) == UM_ERR_ARG);
    assert(um_reindex_paths(lib, "{}", 1, &text) == UM_ERR_ARG);
    assert(um_reindex_paths(lib, "[1]", 1, &text) == UM_ERR_ARG);

    long long virtualId = 0;
    assert(um_add_virtual_item(lib, "a record", "image", NULL,
                               &virtualId) == UM_OK);
    assert(virtualId > 0);
    assert(um_add_virtual_item(lib, "another", "image", "{\"k\":1}",
                               &virtualId) == UM_OK);
    /* A meta payload that is not an object is refused, not coerced. */
    assert(um_add_virtual_item(lib, "bad", "image", "[1]",
                               &virtualId) == UM_ERR_ARG);

    assert(um_validate_curation_patch("{\"rating\":3}") == UM_OK);
    assert(um_validate_curation_patch("{\"rating\":99}") == UM_ERR_ARG);
    assert(um_validate_curation_patch(NULL) == UM_ERR_ARG);

    /* Recovery on a library that was closed cleanly changes nothing. */
    assert(um_recover(lib) == UM_OK);

    text = NULL;
    assert(um_dedup_removal_plan(lib, 0, &text) == UM_OK);
    /* A JSON array whatever the earlier tests left behind: asserting it is
     * empty would encode an assumption about their state, not the contract. */
    assert(text[0] == '[');
    um_buffer_free(text);

    int supported = -1;
    assert(um_hardlinks_supported(root, &supported) == UM_OK);
    assert(supported == 0 || supported == 1);
    assert(um_hardlinks_supported(NULL, &supported) == UM_ERR_ARG);

    /* An empty list is refused rather than reported as nothing done: asking
     * to link no duplicate is a caller's mistake, not an empty batch. A
     * ValueError from the engine surfaces as UM_ERR_RUNTIME. */
    text = NULL;
    assert(um_link_duplicates(lib, "[]", &text) == UM_ERR_RUNTIME);
    /* A malformed pair is caught before the engine sees it. */
    assert(um_link_duplicates(lib, "[{\"itemId\":1}]", &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_trash_plan(lib, NULL, 0, &text) == UM_OK);
    um_buffer_free(text);
    assert(um_trash_plan(lib, NULL, -1, &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_trash_holding(lib, &text) == UM_OK);
    assert(strstr(text, "\"files\"") != NULL);
    um_buffer_free(text);

    /* Every one of them refuses a handle it does not know. */
    um_library bogus = (um_library)(void *)0x1;
    assert(um_reindex_paths(bogus, "[]", 1, &text) == UM_ERR_HANDLE);
    assert(um_recover(bogus) == UM_ERR_HANDLE);
    assert(um_trash_holding(bogus, &text) == UM_ERR_HANDLE);

    assert(um_library_close(work) == UM_OK);
  }

  /* Media inspection and the rest of the domain. */
  {
    um_library work = NULL;
    assert(um_library_open(root, &work) == UM_OK);
    char *text = NULL;
    char joined[4096];

    /* A still the fixture library really holds. */
    snprintf(joined, sizeof(joined), "%s/one.ppm", root);
    assert(um_probe_still(joined, &text) == UM_OK);
    assert(strstr(text, "\"width\"") != NULL);
    um_buffer_free(text);
    assert(um_probe_still(NULL, &text) == UM_ERR_ARG);
    /* A file that is not an image is refused, not guessed at. */
    snprintf(joined, sizeof(joined), "%s/track.gpx", root);
    assert(um_probe_still(joined, &text) != UM_OK);

    /* The same GPX the library ships is a real track. */
    text = NULL;
    assert(um_parse_gpx(joined, &text) == UM_OK);
    assert(text[0] == '[');
    um_buffer_free(text);
    assert(um_parse_gpx(NULL, &text) == UM_ERR_ARG);

    text = NULL;
    assert(um_read_config(root, &text) == UM_OK);
    assert(strstr(text, "\"domain\"") != NULL);
    um_buffer_free(text);

    text = NULL;
    assert(um_default_config(UM_DOMAIN_PHOTO, &text) == UM_OK);
    assert(strstr(text, "\"photo\"") != NULL);
    um_buffer_free(text);
    assert(um_default_config(-1, &text) == UM_ERR_ARG);

    /* Two identical fingerprints score 1, shifted or not. */
    const char *print =
      "{\"durationSeconds\":1.0,\"raw\":[1,2,3,4,5,6,7,8]}";
    double score = -1.0;
    assert(um_audio_offset_similarity(print, print, 0, &score) == UM_OK);
    assert(score > 0.99);
    assert(um_audio_offset_similarity(print, print, -1, &score) == UM_ERR_ARG);
    assert(um_audio_offset_similarity("not json", print, 0,
                                      &score) == UM_ERR_ARG);

    /* Decoding refuses a zero edge before it opens anything, and clears every
     * output it promised to. */
    unsigned char *pixels = (unsigned char *)0x1;
    size_t length = 99;
    int w = 9, h = 9;
    snprintf(joined, sizeof(joined), "%s/one.ppm", root);
    assert(um_decode_frame(joined, 0, 0.0, &pixels, &length, &w,
                           &h) == UM_ERR_ARG);
    assert(pixels == NULL && length == 0 && w == 0 && h == 0);

    /* Replacing faces with an empty set is a real request: it clears them. */
    assert(um_replace_faces(work, 1, "[]") == UM_OK);
    assert(um_replace_faces(work, 1, "not json") == UM_ERR_ARG);
    assert(um_replace_faces(work, 1, "{}") == UM_ERR_ARG);

    assert(um_library_close(work) == UM_OK);
  }

  /* Vision primitives. Only the ones that reach no network are exercised
   * here; the model calls need an endpoint this test has no business
   * assuming exists. */
  {
    um_library work = NULL;
    assert(um_library_open(root, &work) == UM_OK);
    char *text = NULL;

    assert(um_vision_store_document(work, 1, "test-model", "a caption",
                                    "[\"one\",\"two\"]",
                                    "[0.1,0.2,0.3]") == UM_OK);
    /* An embedding that is not numbers is refused, not coerced. */
    assert(um_vision_store_document(work, 1, "test-model", "c", NULL,
                                    "[\"x\"]") == UM_ERR_ARG);
    assert(um_vision_store_document(work, 1, "test-model", "c", NULL,
                                    NULL) == UM_ERR_ARG);
    /* Labels that are not strings are refused too. */
    assert(um_vision_store_document(work, 1, "test-model", "c", "[1]",
                                    "[0.1]") == UM_ERR_ARG);

    assert(um_vision_store_annotation(work, 1, "test-model", "a caption",
                                      "[\"one\"]", &text) == UM_OK);
    assert(strstr(text, "\"caption\"") != NULL);
    um_buffer_free(text);

    /* The document stored above is the nearest thing to its own vector. */
    text = NULL;
    assert(um_vision_semantic_search(work, "test-model", "[0.1,0.2,0.3]", 0,
                                     &text) == UM_OK);
    assert(text[0] == '[');
    um_buffer_free(text);
    assert(um_vision_semantic_search(work, "test-model", "[0.1]", -1,
                                     &text) == UM_ERR_ARG);

    /* Parsing a reply needs no endpoint. */
    text = NULL;
    assert(um_vision_parse_description(
      "{\"caption\":\"a caption\",\"labels\":[\"one\"]}", &text) == UM_OK);
    assert(strstr(text, "\"a caption\"") != NULL);
    um_buffer_free(text);
    assert(um_vision_parse_description(NULL, &text) == UM_ERR_ARG);
    /* A reply missing either half is refused rather than half-read. */
    assert(um_vision_parse_description("{\"caption\":\"x\"}",
                                       &text) != UM_OK);

    /* The two model calls validate their arguments before reaching out. */
    assert(um_vision_embedding(NULL, "m", "t", 0, &text) == UM_ERR_ARG);
    assert(um_vision_embedding("http://localhost:1", "m", "t", -1,
                               &text) == UM_ERR_ARG);
    assert(um_vision_describe_file(NULL, "m", "p", 0, &text) == UM_ERR_ARG);

    assert(um_library_close(work) == UM_OK);
  }

  um_buffer_free(NULL);
  printf("c abi: ok\n");
  return 0;
}
