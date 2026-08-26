# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The Python surface over the C ABI, exercised against a real library."""
import json
import subprocess
from pathlib import Path

import pytest

from unimedia import (Library, UniMediaError, abi_version, audio_available,
                      audio_fingerprint, audio_similarity, engine_version, is_library,
                      media_available, probe_media, sync_available)

OM = Path(__file__).resolve().parents[2] / "bin" / "om"


def ppm(red: int) -> str:
    return "P3\n2 2\n255\n" + f"{red} 0 0\n" * 4


@pytest.fixture
def library(tmp_path):
    """A catalogued library with two identical images and an empty inbox."""
    if not OM.exists():
        pytest.skip(f"{OM} not built; run `nimble build` first")
    (tmp_path / "inbox").mkdir()
    (tmp_path / "one.ppm").write_text(ppm(9))
    (tmp_path / "two.ppm").write_text(ppm(9))
    subprocess.run([str(OM), "catalog", "init", str(tmp_path), "--domain", "photo"],
                   check=True, capture_output=True)
    return tmp_path


def test_versions_are_reported():
    # The number a caller compares against the header it compiled against,
    # to tell whether the call it wants exists.
    assert abi_version() >= 1
    assert engine_version().count(".") == 2


def test_scan_then_page_through_items(library):
    with Library(library) as lib:
        report = lib.scan(skip_phash=True)
        assert report["indexed"] == 2
        assert lib.count() == 2
        assert lib.count("video") == 0

        items = lib.items(limit=10)
        assert [item["path"] for item in items] == ["one.ppm", "two.ppm"]
        # The schema stays behind the boundary.
        assert "user_version" not in json.dumps(items)

        first_page = lib.items(limit=1, offset=0)
        second_page = lib.items(limit=1, offset=1)
        assert first_page[0]["path"] == "one.ppm"
        assert second_page[0]["path"] == "two.ppm"


def test_identical_files_group_as_exact_duplicates(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        run = lib.find_duplicates("exact")
        assert run > 0
        review = lib.review()
        assert review["kind"] == "exact"
        assert sum(len(group["members"]) for group in review["groups"]) == 2


def test_organize_plan_changes_nothing(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        plan = lib.plan_organize(library / "inbox")
        assert plan["operations"] == []
        assert (library / "one.ppm").exists()


def test_organize_then_undo_round_trips(tmp_path, library):
    inbox = tmp_path / "inbox"
    (inbox / "sub").mkdir(parents=True, exist_ok=True)
    (inbox / "sub" / "new.ppm").write_text(ppm(21))
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        before = lib.count()
        report = lib.organize(inbox, "copy")
        assert report["applied"] == 1
        assert lib.count() == before + 1
        # Undo verifies journalled hashes before restoring.
        assert lib.undo()["undone"] >= 1
        assert lib.count() == before


def test_duplicate_removal_is_recoverable(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        run = lib.find_duplicates("exact")
        group = lib.review(run)["groups"][0]
        keeper = next(m for m in group["members"] if m["keeper"])
        lib.keep(group["group"], keeper["item"])
        lib.remove_duplicates(run)
        assert lib.count() == 1
        lib.undo()
        assert lib.count() == 2


def test_audit_reports_a_clean_library(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        report = lib.audit(verify_hashes=True)
        assert report["checked"] == 2
        assert report["missing"] == 0
        assert report["findings"] == []


def test_a_skipped_perceptual_hash_is_reported_as_still_owed(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        # Skipping leaves the work outstanding rather than pretending it is
        # done, so whoever needs it can say how much is left.
        assert lib.pending_perceptual_hashes() == 2
        lib.scan()
        assert lib.pending_perceptual_hashes() == 0


def test_dates_can_be_set_then_shifted(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        item = lib.items()[0]["id"]

        plan = lib.plan_dates([item], "set", "2026-07-14 20:30:00")
        assert plan["entries"][0]["newDate"] == "2026-07-14 20:30:00"
        # A plan changes nothing until it is applied.
        assert lib.curation(item)["creationDate"] != "2026-07-14 20:30:00"

        assert lib.set_dates([item], "2026-07-14 20:30:00")["applied"] == 1
        assert lib.curation(item)["creationDate"] == "2026-07-14 20:30:00"

        assert lib.shift_dates([item], 3600)["applied"] == 1
        assert lib.curation(item)["creationDate"] == "2026-07-14 21:30:00"


def test_a_zero_shift_is_refused(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        item = lib.items()[0]["id"]
        lib.set_dates([item], "2026-07-14 20:30:00")
        with pytest.raises(UniMediaError):
            lib.shift_dates([item], 0)
        assert lib.curation(item)["creationDate"] == "2026-07-14 20:30:00"


def test_curation_round_trips_and_preserves_what_it_is_not_told(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        item = lib.items()[0]["id"]
        assert lib.curation(item)["rating"] == 0

        lib.curate(item, title="A red square", rating=4,
                   keywords=["test", "red"], creator=["lituus-lab"],
                   copyright="CC0")
        stored = lib.curation(item)
        assert stored["title"] == "A red square"
        assert stored["creator"] == ["lituus-lab"]
        assert sorted(stored["keywords"]) == ["red", "test"]

        # An omitted field survives; addKeywords does not restate the rest.
        lib.curate(item, addKeywords=["square"])
        stored = lib.curation(item)
        assert stored["title"] == "A red square"
        assert "square" in stored["keywords"]

        assert {facet["keyword"] for facet in lib.keywords()} >= {"red", "square"}
        assert [f["keyword"] for f in lib.keywords(prefix="sq")] == ["square"]


def test_a_rejected_curation_changes_nothing(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        item = lib.items()[0]["id"]
        lib.curate(item, rating=3)
        with pytest.raises(UniMediaError):
            lib.curate(item, rating=9)
        assert lib.curation(item)["rating"] == 3


def test_privacy_reports_only_what_discloses_something(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        # PPM carries no metadata, so a clean library has nothing to report.
        assert lib.privacy_audit() == []
        # An explicit selection is still plannable: the caller decides.
        plan = lib.plan_privacy_strip([lib.items()[0]["id"]])
        assert len(plan["entries"]) == 1
        assert plan["entries"][0]["signals"] == ["explicit-selection"]


def test_stripping_an_unknown_item_is_refused(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        with pytest.raises(UniMediaError):
            lib.strip_privacy([9999])


def test_chosen_items_are_removed_and_restored(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        chosen = lib.items()[0]["id"]
        report = lib.remove_items([chosen])
        assert report["applied"] == 1
        assert lib.count() == 1
        lib.undo()
        assert lib.count() == 2


def test_removing_an_unknown_item_removes_nothing(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        with pytest.raises(UniMediaError):
            lib.remove_items([lib.items()[0]["id"], 9999])
        assert lib.count() == 2


def test_preferences_round_trip_through_the_config_file(library):
    with Library(library) as lib:
        assert lib.config["scheme"] == "YYYY/MM-DD"
        lib.configure(scheme="flat")
        assert lib.config["scheme"] == "flat"
        # An untouched key keeps its value.
        assert lib.config["domain"] == "photo"
    # What was read back is what landed in the file.
    written = json.loads((library / ".organizemedia.json").read_text())
    assert written["scheme"] == "flat"


def test_an_invalid_preference_changes_nothing(library):
    with Library(library) as lib:
        with pytest.raises(UniMediaError):
            lib.configure(scheme="nonsense")
        with pytest.raises(UniMediaError):
            lib.configure(unknown=1)
        assert lib.config["scheme"] == "YYYY/MM-DD"


def test_a_bad_argument_raises_rather_than_crashing(library):
    with Library(library) as lib:
        with pytest.raises(UniMediaError) as failure:
            lib.items(limit=0)
        assert failure.value.status != 0


def test_a_closed_library_refuses_further_calls(library):
    lib = Library(library)
    lib.close()
    with pytest.raises(UniMediaError):
        lib.count()


def test_a_plain_folder_can_become_a_library(tmp_path):
    folder = tmp_path / "photos"
    folder.mkdir()
    (folder / "one.ppm").write_text(ppm(7))

    assert not is_library(folder)
    with Library.create(folder, domain="visual") as lib:
        assert is_library(folder)
        assert (folder / ".organizemedia.json").exists()
        assert lib.config["domain"] == "visual"
        # Creating catalogues nothing: the scan is the separate step.
        assert lib.count() == 0
        assert lib.scan(skip_phash=True)["indexed"] == 1
        assert lib.count() == 1

    # The photograph itself was neither moved nor rewritten.
    assert (folder / "one.ppm").read_text() == ppm(7)


def test_creating_over_an_existing_library_is_refused(library):
    assert is_library(library)
    with pytest.raises(UniMediaError):
        Library.create(library, domain="visual")


def test_opening_a_missing_library_raises():
    with pytest.raises(UniMediaError):
        Library("/nonexistent/library/root")


# ---- Albums, both kinds ----------------------------------------------------


def test_an_album_holds_items_and_reports_a_count(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        assert lib.albums() == []          # none yet, and that is not an error
        album = lib.create_album("Holidays")
        assert album["name"] == "Holidays"
        assert album["itemCount"] == 0

        item = lib.items(limit=1)[0]["id"]
        assert lib.add_to_album(album["id"], item) is True
        # Adding twice is how a caller makes sure, so it is not a failure.
        assert lib.add_to_album(album["id"], item) is False
        assert lib.album(album["id"])["itemCount"] == 1
        assert [entry["id"] for entry in lib.album_items(album["id"])] == [item]

        covered = lib.set_album_cover(album["id"], item)
        assert covered["coverItemId"] == item
        assert lib.set_album_cover(album["id"])["coverItemId"] == 0

        assert lib.rename_album(album["id"], "Trips")["name"] == "Trips"
        assert lib.remove_from_album(album["id"], item) is True
        assert lib.remove_from_album(album["id"], item) is False
        lib.delete_album(album["id"])
        assert lib.albums() == []


def test_an_album_that_does_not_exist_is_an_error(library):
    with Library(library) as lib:
        with pytest.raises(UniMediaError):
            lib.album(9999)
        with pytest.raises(UniMediaError):
            lib.create_album("")


def test_a_smart_album_is_a_query_evaluated_on_the_call(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        album = lib.create_smart_album(
            "Photos", [{"field": "kind", "operator": "eq", "value": "image"}])
        assert album["matchAll"] is True
        assert album["rules"][0]["field"] == "kind"
        # Evaluated now, so it reports what the library holds rather than what
        # it held when the album was made.
        assert len(lib.smart_album_items(album["id"])) == 2
        assert lib.smart_album(album["id"])["name"] == "Photos"
        assert lib.rename_smart_album(album["id"], "Pictures")["name"] == "Pictures"
        lib.delete_smart_album(album["id"])
        assert lib.smart_albums() == []


def test_the_engine_checks_smart_rules_not_the_binding(library):
    with Library(library) as lib:
        with pytest.raises(UniMediaError):
            lib.create_smart_album("Bad", [{"field": "nonsense",
                                            "operator": "eq", "value": "x"}])
        with pytest.raises(UniMediaError):
            # A valid field with an operator it does not take.
            lib.create_smart_album("Bad", [{"field": "kind",
                                            "operator": "gt", "value": "x"}])


# ---- People and faces ------------------------------------------------------


def test_people_start_empty_and_a_person_can_be_named(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        assert lib.people() == []
        assert lib.faces() == []
        person = lib.create_person("Ada")
        assert person > 0
        named = lib.people()
        assert [entry["name"] for entry in named] == ["Ada"]
        assert named[0]["faceCount"] == 0
        with pytest.raises(UniMediaError):
            lib.create_person("")


def test_clustering_refuses_a_distance_it_cannot_use(library):
    with Library(library) as lib:
        assert lib.cluster_faces(8) == []
        with pytest.raises(UniMediaError):
            lib.cluster_faces(99)


# ---- Time, place, sync, vision ---------------------------------------------


def test_the_timeline_buckets_what_was_scanned(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        # A PPM carries no metadata and these names carry no date, so the scan
        # leaves them undated on purpose. A timeline is built from dates: give
        # them one rather than asking the scan to invent it.
        lib.set_dates([item["id"] for item in lib.items(limit=10)],
                      "2026-07-14 20:30:00")
        buckets = lib.timeline("month")
        assert sum(bucket["itemCount"] for bucket in buckets) == 2
        assert all(bucket["totalBytes"] > 0 for bucket in buckets)
        with pytest.raises(UniMediaError):
            lib.timeline("fortnight")


def test_geocoding_without_an_endpoint_makes_no_network_call(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        # These fixtures carry no coordinates, so there is nothing to name and
        # the plan is empty rather than an error. The C suite reaches the other
        # case: its items are given coordinates first, and a plan that has
        # something to look up with nothing to look it up with fails.
        plan = lib.geocode_plan("nominatim")
        assert plan["provider"] == "nominatim"
        assert plan["entries"] == []
        with pytest.raises(UniMediaError):
            lib.geocode_plan("")              # a provider must be named
        with pytest.raises(UniMediaError):
            lib.geocode_plan("nominatim", refresh_cache=True)


def test_the_sync_manifest_describes_the_library(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        manifest = lib.sync_manifest()
        assert isinstance(manifest, dict)
        assert lib.sync_runs() == []
        assert isinstance(sync_available(), bool)
        with pytest.raises(UniMediaError):
            lib.sync_plan("")


def test_vision_reports_nothing_before_a_model_has_run(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        assert lib.vision_annotations() == []
        with pytest.raises(UniMediaError):
            lib.vision_search("http://localhost:1", "m", "q", limit=0)


# ---- Media and audio -------------------------------------------------------


def test_the_optional_tools_report_their_own_absence():
    assert isinstance(media_available(), bool)
    assert isinstance(audio_available(), bool)


def test_probing_a_picture_says_it_is_not_a_movie(library):
    with pytest.raises(UniMediaError):
        probe_media(str(library / "one.ppm"))
    with pytest.raises(UniMediaError):
        audio_fingerprint(str(library / "one.ppm"), max_seconds=0)


# ---- One item, and the ways of finding it ----------------------------------


def test_one_item_by_id_and_where_it_is_on_disk(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        first = lib.items(limit=1)[0]
        assert lib.item(first["id"])["id"] == first["id"]
        path = lib.item_path(first["id"])
        assert Path(path).is_absolute()
        assert Path(path).exists()
        with pytest.raises(UniMediaError):
            lib.item(9999)


def test_an_empty_filter_narrows_nothing(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        assert len(lib.filter()) == 2
        assert len(lib.filter({"kind": "image"})) == 2
        assert lib.filter({"kind": "video"}) == []
        assert lib.place_facets() == []
        with pytest.raises(UniMediaError):
            lib.filter({}, limit=0)


def test_searching_needs_something_to_search_for(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        assert isinstance(lib.search("ppm"), list)
        with pytest.raises(UniMediaError):
            lib.search("")


def test_item_metadata_is_replaced_whole(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        first = lib.items(limit=1)[0]["id"]
        assert lib.item_meta(first) == {}
        lib.set_item_meta(first, {"note": "kept", "other": 1})
        assert lib.item_meta(first) == {"note": "kept", "other": 1}
        # The whole object is written, so a field left out is gone.
        lib.set_item_meta(first, {"note": "only"})
        assert lib.item_meta(first) == {"note": "only"}


def test_two_fingerprints_compare_without_engine_types():
    same = {"durationSeconds": 1.0, "raw": [1, 2, 3]}
    other = {"durationSeconds": 1.0, "raw": [1, 2, 4095]}
    assert audio_similarity(same, same) > 0.999
    assert 0.0 <= audio_similarity(same, other) < 1.0
    with pytest.raises(UniMediaError):
        audio_similarity({"raw": "not a list"}, same)


def test_a_thumbnail_is_a_path_under_the_cache(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        first = lib.items(limit=1)[0]["id"]
        thumb = lib.thumbnail(first, 64)
        assert thumb["maxEdge"] == 64
        assert ".om-cache" in thumb["path"]
        assert Path(thumb["path"]).exists()
        with pytest.raises(UniMediaError):
            lib.thumbnail(first, 0)


def test_a_run_can_be_worked_through_one_item_at_a_time(library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        run = lib.find_duplicates(kind="exact")
        review = lib.review(run)
        # The fixtures are two identical files, so the run has something in it.
        assert review
        second = lib.items(limit=2)[1]["id"]
        report = lib.remove_duplicate(run, second)
        assert isinstance(report, dict)
        assert len(lib.items(limit=10)) == 1


def test_a_closed_handle_never_becomes_valid_again(library):
    """Closing frees nothing the allocator can hand out again.

    Otherwise the next library opened lands at the same address and a caller
    that kept the old handle reaches a library it never opened, silently.
    """
    first = Library(library)
    first.close()
    second = Library(library)
    try:
        with pytest.raises(UniMediaError):
            first.albums()
    finally:
        second.close()


def test_a_scan_can_be_told_how_many_files_to_hash_at_once(library):
    with Library(library) as lib:
        # The bound changes how the work is spread, never what comes out.
        report = lib.scan(skip_phash=True, jobs=1)
        assert report["indexed"] == 2
        with pytest.raises(ValueError):
            lib.scan(jobs=-1)


def test_identical_duplicates_can_become_a_link(tmp_path, library):
    with Library(library) as lib:
        lib.scan(skip_phash=True)
        run = lib.find_duplicates(kind="exact")
        plan = lib.link_duplicates_plan(run)
        # The fixtures are two identical files, so one becomes a link to the
        # other and the pair names which is which.
        assert len(plan) == 1
        assert plan[0]["item"] != plan[0]["keeper"]

        one = Path(lib.item_path(plan[0]["item"]))
        keeper = Path(lib.item_path(plan[0]["keeper"]))
        assert one.stat().st_ino != keeper.stat().st_ino

        report = lib.link_duplicates(run)
        assert report["linked"] == 1
        assert report["failed"] == 0
        # One copy on disk, both paths still opening.
        assert one.stat().st_ino == keeper.stat().st_ino
        assert one.read_bytes() == keeper.read_bytes()

        lib.undo(report["batch"])
        assert one.stat().st_ino != keeper.stat().st_ino
        assert len(lib.items(limit=10)) == 2


def test_albums_nest_and_a_cycle_is_refused(library):
    with Library(library) as lib:
        trips = lib.create_album("Trips")["id"]
        spain = lib.create_album("Spain")["id"]
        madrid = lib.create_album("Madrid")["id"]

        assert lib.set_album_parent(spain, trips)["parentId"] == trips
        assert lib.set_album_parent(madrid, spain)["parentId"] == spain
        assert [a["name"] for a in lib.child_albums()] == ["Trips"]
        assert [a["name"] for a in lib.child_albums(trips)] == ["Spain"]
        assert [a["name"] for a in lib.child_albums(spain)] == ["Madrid"]
        assert lib.child_albums(madrid) == []

        # Trips into Madrid would close Trips -> Spain -> Madrid -> Trips,
        # which one step of checking misses.
        with pytest.raises(UniMediaError):
            lib.set_album_parent(trips, madrid)
        with pytest.raises(UniMediaError):
            lib.set_album_parent(trips, trips)
        # A refusal leaves the tree as it was.
        assert lib.album(spain)["parentId"] == trips

        # Deleting a parent lifts its children rather than taking them.
        lib.delete_album(trips)
        assert lib.album(spain)["parentId"] == 0
