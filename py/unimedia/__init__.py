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
# Before the extension: the engine loads SQLite and OpenSSL by bare name during
# its own initialization, and Windows carries neither under the names asked for.
# setup.py puts copies beside this file; loading them here by full path is what
# makes those names resolve. add_dll_directory would not -- it only affects
# loads passing LOAD_LIBRARY_SEARCH_USER_DIRS, and Nim's `dynlib` calls plain
# LoadLibrary. Once a module is in the process, a load by base name returns the
# handle already open.
import ctypes as _ctypes
import glob as _glob
import os as _os
import sys as _sys

if _sys.platform == "win32":
    _here = _os.path.dirname(_os.path.abspath(__file__))
    # libcrypto before libssl: the second links the first, and loading a
    # dependency by path first is what keeps the loader from looking for it
    # anywhere else.
    for _name in ("libcrypto-", "libssl-", "sqlite3_64.dll"):
        for _dll in sorted(_glob.glob(_os.path.join(_here, _name + "*.dll"))
                           if _name.endswith("-")
                           else [_os.path.join(_here, _name)]):
            if _os.path.exists(_dll):
                _ctypes.WinDLL(_dll)

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
