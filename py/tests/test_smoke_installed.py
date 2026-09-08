# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Prove an installed `unimedia` wheel stands on its own.

`test_core.py` is the full suite: it resolves `bin/om` by walking up from its
own path, which only holds inside a checkout. This module is copied to a
neutral directory and run there, so it may lean on nothing but the wheel.

Importing the extension proves little by itself -- it imports fine while the
shared library it needs stays behind. Every check below crosses into that
library.
"""
import faulthandler
import sys

# Breadcrumbs on stderr, unbuffered: on Windows this module died with no output
# at all, which tells nothing beyond "before pytest printed". faulthandler
# turns a native fault into a C-level traceback instead of a silent exit.
faulthandler.enable()
print("smoke: importing unimedia", file=sys.stderr, flush=True)
import unimedia
print("smoke: imported, engine", unimedia.engine_version(),
      file=sys.stderr, flush=True)


def test_the_engine_answers_its_version():
    assert unimedia.engine_version()
    assert unimedia.__version__ == unimedia.engine_version()


def test_the_abi_version_is_a_positive_integer():
    abi = unimedia.abi_version()
    assert isinstance(abi, int) and abi > 0


def test_capability_probes_answer_without_raising():
    # Each returns a bool from the engine rather than from Python, so a wheel
    # whose library never loaded cannot reach this point.
    for probe in (unimedia.audio_available, unimedia.media_available,
                  unimedia.sync_available):
        assert isinstance(probe(), bool)


def test_hardlink_support_is_answered_for_a_real_directory(tmp_path):
    # It takes the root to test: whether hardlinks work is a property of the
    # filesystem under that path, not of the build.
    assert isinstance(unimedia.hardlinks_supported(str(tmp_path)), bool)


def test_the_default_config_comes_back_populated():
    config = unimedia.default_config()
    assert isinstance(config, dict) and config


def test_a_timestamp_is_produced_in_iso_form():
    stamp = unimedia.iso_now()
    assert stamp.count("-") >= 2 and "T" in stamp
