# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Local-first media catalogue, organizer and duplicate finder.

Thin Python surface over the native UniMedia engine::

    from unimedia import Library

    with Library("~/Pictures/Library") as library:
        library.scan()
        for item in library.items(limit=20):
            print(item["path"])

Albums, people, places and searches hang off the same handle::

        album = library.create_album("Holidays")
        library.add_to_album(album["id"], item_id=1)
        library.filter({"kind": "image", "minRating": 4})

A few things do not need a library open: whether an optional external tool is
installed, and what a media file is.
"""
# Before the extension: the engine asks the loader for sqlite3_64.dll by bare
# name, and on Windows setup.py puts a copy beside this file. Loading it here
# by full path is what makes that name resolve -- add_dll_directory would not,
# because it only affects loads that pass LOAD_LIBRARY_SEARCH_USER_DIRS and
# Nim's `dynlib` calls plain LoadLibrary. Once the module is in the process,
# a load by base name returns the handle already open.
import ctypes as _ctypes
import os as _os
import sys as _sys

if _sys.platform == "win32":
    _sqlite = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                            "sqlite3_64.dll")
    if _os.path.exists(_sqlite):
        _ctypes.WinDLL(_sqlite)

from ._core import (
    Library, UniMediaError, abi_version, apple_double_verdict,
    audio_available, audio_fingerprint, audio_offset_similarity,
    audio_similarity, blake3_file, can_strip, can_write_date,
    category_for, checked_path_under, decode_frame, default_config, diff_sync_manifests,
    engine_version, filename_date, hardlinks_supported, is_internal,
    is_library, iso_now, media_available, media_coordinates, media_date,
    new_batch_id, parse_gpx, parse_sync_manifest,
    parse_vision_description, perceptual_hash_file, probe_media,
    probe_sound, probe_still, read_config, sync_available,
    validate_curation_patch, video_frame_hashes, vision_describe_file,
    vision_embedding)

__all__ = [
    "Library", "UniMediaError", "abi_version", "apple_double_verdict",
    "audio_available", "audio_fingerprint", "audio_offset_similarity",
    "audio_similarity", "blake3_file", "can_strip", "can_write_date",
    "category_for", "checked_path_under", "decode_frame", "default_config",
    "diff_sync_manifests", "engine_version", "filename_date",
    "hardlinks_supported", "is_internal", "is_library", "iso_now",
    "media_available", "media_coordinates", "media_date", "new_batch_id",
    "parse_gpx", "parse_sync_manifest", "parse_vision_description",
    "perceptual_hash_file", "probe_media", "probe_sound", "probe_still",
    "read_config", "sync_available", "validate_curation_patch",
    "video_frame_hashes", "vision_describe_file", "vision_embedding"]
__version__ = engine_version()
