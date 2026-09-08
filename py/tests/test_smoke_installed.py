# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Prove an installed `unimedia` wheel stands on its own.

`test_core.py` is the full suite: it resolves `bin/om` by walking up from its
own path, which only holds inside a checkout. This module is copied to a
neutral directory and run there, so it may lean on nothing but the wheel.

The import happens in a child process on purpose. Importing at module level
put the whole session at the mercy of a native fault: on Windows the wheel job
exited 1 with no output at all, because pytest captures stdout and stderr
during collection and loses the buffer when the process dies. A child hands
back its own output and exit status, so a crash is reported instead of
swallowed.
"""
import subprocess
import sys
import textwrap


def run_in_child(body):
    """Run `body` in a fresh interpreter, returning it whole for assertions."""
    return subprocess.run(
        [sys.executable, "-c", textwrap.dedent(body)],
        capture_output=True, text=True, timeout=120)


def describe(done):
    return (f"exit {done.returncode}\n"
            f"--- stdout ---\n{done.stdout}\n"
            f"--- stderr ---\n{done.stderr}")


def test_the_package_imports_at_all():
    done = run_in_child("""
        import faulthandler
        faulthandler.enable()
        import unimedia
        print("imported")
    """)
    assert done.returncode == 0, describe(done)
    assert "imported" in done.stdout, describe(done)


def test_the_engine_answers_through_the_bundled_library():
    done = run_in_child("""
        import faulthandler
        faulthandler.enable()
        import unimedia
        print(unimedia.engine_version())
        print(unimedia.abi_version())
    """)
    assert done.returncode == 0, describe(done)
    version, abi = done.stdout.split()
    assert version
    assert int(abi) > 0


def test_capability_probes_answer_without_raising():
    # Each returns a bool from the engine rather than from Python, so a wheel
    # whose library never loaded cannot reach this point.
    done = run_in_child("""
        import faulthandler
        faulthandler.enable()
        import unimedia
        for probe in (unimedia.audio_available, unimedia.media_available,
                      unimedia.sync_available):
            print(type(probe()).__name__, probe())
    """)
    assert done.returncode == 0, describe(done)
    for line in done.stdout.split("\n"):
        if line:
            assert line.startswith("bool "), describe(done)


def test_the_default_config_comes_back_populated():
    done = run_in_child("""
        import faulthandler
        faulthandler.enable()
        import unimedia
        config = unimedia.default_config()
        assert isinstance(config, dict) and config, config
        print(len(config))
    """)
    assert done.returncode == 0, describe(done)
    assert int(done.stdout.strip()) > 0


def test_a_timestamp_is_produced_in_iso_form():
    done = run_in_child("""
        import faulthandler
        faulthandler.enable()
        import unimedia
        print(unimedia.iso_now())
    """)
    assert done.returncode == 0, describe(done)
    stamp = done.stdout.strip()
    assert stamp.count("-") >= 2 and "T" in stamp, describe(done)
