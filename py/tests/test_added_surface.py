# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The methods the binding gained, exercised against a real library.

Every one of them is a thin wrapper over a C entry point, so what is checked
here is that the wrapper marshals its arguments and hands the answer back --
the engine's own behaviour is tested on the Nim side.
"""
import json
import subprocess
from pathlib import Path

import pytest

import unimedia
from unimedia import (Library, UniMediaError, apple_double_verdict,
                      blake3_file, can_strip, can_write_date, category_for,
                      checked_path_under, decode_frame, default_config,
                      diff_sync_manifests,
                      filename_date, hardlinks_supported, is_internal,
                      iso_now, media_coordinates, media_date, new_batch_id,
                      parse_gpx, parse_sync_manifest,
                      parse_vision_description, perceptual_hash_file,
                      probe_still, read_config, validate_curation_patch)

OM = Path(__file__).resolve().parents[2] / "bin" / "om"

DIGEST = "00" * 32
MANIFEST = json.dumps({
    "schemaVersion": 1,
    "entries": [{"path": "a.jpg", "digest": DIGEST, "size": 1, "mtimeNs": 2}],
})


def ppm(red: int) -> str:
    return "P3\n2 2\n255\n" + f"{red} 0 0\n" * 4


@pytest.fixture
def library(tmp_path):
    """A catalogued library holding one image."""
    if not OM.exists():
        pytest.skip(f"{OM} not built; run `nimble buildOm` first")
    (tmp_path / "one.ppm").write_text(ppm(9))
    subprocess.run([str(OM), "catalog", "init", str(tmp_path),
                    "--domain", "photo"], check=True, capture_output=True)
    subprocess.run([str(OM), "--library", str(tmp_path), "catalog", "scan"],
                   check=True, capture_output=True)
    return tmp_path


class TestFileInspection:
    """Answers from a path alone, before any library exists."""

    def test_category_follows_the_domain(self):
        assert category_for("photo", "a/b.jpg") == "image"
        # A photo library does not hold a video, so it has no category for it.
        assert category_for("photo", "a/b.mp4") == ""
        assert category_for("video", "a/b.mp4") == "video"

    def test_an_unknown_domain_is_refused(self):
        with pytest.raises(ValueError):
            category_for("sculpture", "a/b.jpg")

    def test_a_date_in_the_name_is_read(self):
        assert filename_date("IMG_20240115_101500.jpg").startswith("2024")
        # A name claiming nothing reads as nothing, not as an error.
        assert filename_date("holiday.jpg") == ""

    def test_coordinates_report_whether_the_file_said(self, tmp_path):
        plain = tmp_path / "one.ppm"
        plain.write_text(ppm(1))
        assert media_coordinates(str(plain))["found"] is False

    def test_a_date_carries_the_source_it_came_from(self, tmp_path):
        plain = tmp_path / "IMG_20240115_101500.ppm"
        plain.write_text(ppm(1))
        answer = media_date(str(plain), filename_date=True)
        assert answer["value"].startswith("2024")
        assert answer["source"]

    def test_the_library_own_files_are_internal(self, library):
        assert is_internal(str(library), str(library / ".organizeMedia.db"))
        assert not is_internal(str(library), str(library / "one.ppm"))

    def test_an_apple_double_is_judged_with_a_reason(self, tmp_path):
        sidecar = tmp_path / "._photo.jpg"
        sidecar.write_bytes(b"\x00\x05\x16\x07")
        verdict = apple_double_verdict(str(sidecar))
        assert "removable" in verdict and verdict["reason"]

    def test_writability_is_answered_from_the_name(self):
        assert can_write_date("a.jpg") is True
        assert can_strip("a.jpg") is True
        # A text file is neither, and saying so costs no read.
        assert can_write_date("notes.txt") is False
        assert can_strip("notes.txt") is False

    def test_a_path_escaping_its_root_is_refused(self, tmp_path):
        inside = tmp_path / "one.ppm"
        assert checked_path_under(str(tmp_path), str(inside))
        with pytest.raises(UniMediaError):
            checked_path_under(str(tmp_path), str(tmp_path / ".." / "x.jpg"))

    def test_a_timestamp_and_a_batch_id_are_produced(self):
        stamp = iso_now()
        assert len(stamp) == 20 and stamp.endswith("Z")
        # Two calls must not hand back the same identifier.
        assert new_batch_id() != new_batch_id()


class TestHashingAndSync:
    def test_a_digest_is_sixty_four_hex_characters(self, library):
        digest = blake3_file(str(library / "one.ppm"))
        assert len(digest) == 64
        assert all(c in "0123456789abcdef" for c in digest)

    def test_a_perceptual_hash_carries_the_size_it_used(self, library):
        answer = perceptual_hash_file(str(library / "one.ppm"))
        assert answer["width"] > 0 and answer["height"] > 0
        # A decimal string: a 64-bit hash does not survive a JSON double.
        assert isinstance(answer["hash"], str)

    def test_a_manifest_reads_back_what_it_holds(self):
        parsed = parse_sync_manifest(MANIFEST)
        assert parsed["entries"][0]["path"] == "a.jpg"

    def test_a_malformed_manifest_is_refused(self):
        with pytest.raises(UniMediaError):
            # A digest is 64 hex characters; a shorter one is not a digest.
            parse_sync_manifest('{"schemaVersion":1,"entries":['
                                '{"path":"a","digest":"ab","size":1,'
                                '"mtimeNs":2}]}')

    def test_a_manifest_against_itself_differs_in_nothing(self):
        diff = diff_sync_manifests(MANIFEST, MANIFEST)
        assert diff["onlyLocal"] == [] and diff["onlyRemote"] == []

    def test_an_entry_missing_from_the_other_side_is_local_only(self):
        empty = json.dumps({"schemaVersion": 1, "entries": []})
        assert diff_sync_manifests(MANIFEST, empty)["onlyLocal"] == ["a.jpg"]


class TestMediaProbes:
    def test_a_still_reports_its_size(self, library):
        answer = probe_still(str(library / "one.ppm"))
        assert answer["width"] == 2 and answer["height"] == 2

    def test_a_file_that_is_no_image_is_refused(self, library):
        with pytest.raises(UniMediaError):
            probe_still(str(library / ".organizeMedia.db"))

    def test_a_gpx_track_reads_as_a_list(self, tmp_path):
        track = tmp_path / "t.gpx"
        track.write_text(
            '<?xml version="1.0"?><gpx><trk><trkseg>'
            '<trkpt lat="45.9" lon="6.6"><time>2024-01-15T10:15:00Z</time>'
            "</trkpt></trkseg></trk></gpx>")
        points = parse_gpx(str(track))
        assert len(points) == 1
        assert abs(points[0]["latitude"] - 45.9) < 0.001


class TestFrameDecoding:
    def test_a_frame_comes_back_with_the_size_it_claims(self, library):
        pixels, width, height = decode_frame(str(library / "one.ppm"), 64)
        # The header promises width * height * 4 bytes of RGBA.
        assert len(pixels) == width * height * 4
        # A 2x2 source is already under the edge, so nothing is enlarged.
        assert width == 2 and height == 2

    def test_an_edge_of_zero_is_refused(self, library):
        with pytest.raises(UniMediaError):
            decode_frame(str(library / "one.ppm"), 0)


class TestConfiguration:
    def test_a_root_reports_the_settings_it_holds(self, library):
        assert read_config(str(library))["domain"] == "photo"

    def test_the_defaults_are_readable_without_creating_anything(self):
        assert default_config("photo")["domain"] == "photo"
        assert default_config("music")["domain"] == "music"

    def test_an_unknown_domain_is_refused(self):
        with pytest.raises(ValueError):
            default_config("sculpture")

    def test_hardlink_support_is_a_question_not_a_failure(self, library):
        assert hardlinks_supported(str(library)) in (True, False)

    def test_a_patch_out_of_range_is_refused(self):
        assert validate_curation_patch({"rating": 3}) is True
        with pytest.raises(UniMediaError):
            validate_curation_patch({"rating": 99})


class TestLibraryMethods:
    def test_reindexing_nothing_still_reports_its_shape(self, library):
        with Library(str(library)) as lib:
            report = lib.reindex_paths([])
            assert "indexed" in report

    def test_a_virtual_item_gets_an_identifier(self, library):
        with Library(str(library)) as lib:
            first = lib.add_virtual_item("a record", "image")
            second = lib.add_virtual_item("another", "image", {"k": 1})
            assert first > 0 and second > first

    def test_recovery_on_a_clean_library_changes_nothing(self, library):
        with Library(str(library)) as lib:
            lib.recover()
            assert lib.count() >= 1

    def test_the_trash_reports_what_it_holds(self, library):
        with Library(str(library)) as lib:
            holding = lib.trash_holding()
            assert holding["files"] == 0 and holding["bytes"] == 0
            assert lib.trash_plan() == []

    def test_a_removal_plan_needs_a_run_to_plan_from(self, library):
        with Library(str(library)) as lib:
            # No dedup has run, so there is nothing to plan a removal from.
            # Saying so beats handing back an empty list a caller would read
            # as "nothing to remove".
            with pytest.raises(UniMediaError):
                lib.dedup_removal_plan()

    def test_linking_no_pair_is_refused(self, library):
        with Library(str(library)) as lib:
            # Asking to link no duplicate is a caller's mistake, not an
            # empty batch.
            with pytest.raises(UniMediaError):
                lib.link_duplicate_pairs([])

    def test_faces_can_be_replaced_by_an_empty_set(self, library):
        with Library(str(library)) as lib:
            lib.replace_faces(1, [])
            assert lib.faces(item_id=1) == []


class TestVision:
    def test_a_document_is_found_by_its_own_vector(self, library):
        with Library(str(library)) as lib:
            lib.vision_store_document(1, "test-model", "a caption",
                                      [0.1, 0.2, 0.3], labels=["one"])
            hits = lib.vision_semantic_search("test-model", [0.1, 0.2, 0.3])
            assert hits and hits[0]["itemId"] == 1

    def test_an_annotation_needs_no_vector(self, library):
        with Library(str(library)) as lib:
            stored = lib.vision_store_annotation(1, "test-model", "a caption")
            assert stored["caption"] == "a caption"

    def test_a_reply_is_parsed_without_reaching_a_model(self):
        parsed = parse_vision_description(
            '{"caption":"a caption","labels":["one"]}')
        assert parsed["caption"] == "a caption"
        assert parsed["labels"] == ["one"]

    def test_a_reply_missing_a_half_is_refused(self):
        with pytest.raises(UniMediaError):
            parse_vision_description('{"caption":"x"}')


def test_every_added_name_is_exported():
    """The module exports what this file imports, so a rename breaks here."""
    for name in ["category_for", "probe_sound", "blake3_file", "parse_gpx",
                 "vision_embedding", "vision_describe_file",
                 "audio_offset_similarity"]:
        assert hasattr(unimedia, name), name
