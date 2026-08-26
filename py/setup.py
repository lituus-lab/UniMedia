# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Build unimedia._core over the UniMedia C ABI.

A repository checkout links the library built by ``nimble clib``. An extracted
source distribution builds its vendored Nim project; Nim and Nimble must be
available on PATH.
"""
import os
import shutil
import subprocess
import sys

from Cython.Build import cythonize
from setuptools import Extension, setup

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PKG_DIR = os.path.join(HERE, "unimedia")
VENDOR_DIR = os.path.join(HERE, "_nimsrc")
NIMBLE_FILE = "UniMedia.nimble"
VENDOR_FILES = [NIMBLE_FILE, "nim.cfg", "vgraph.cfg"]
VENDOR_DIRS = ["src", "include"]

if sys.platform == "win32":
    LIB_NAME, BUNDLED = "UniMedia.lib", False
    LINK_ARGS = []
elif sys.platform == "darwin":
    LIB_NAME, BUNDLED = "libUniMedia.dylib", True
    LINK_ARGS = ["-Wl,-rpath,@loader_path"]
else:
    LIB_NAME, BUNDLED = "libUniMedia.so", True
    LINK_ARGS = ["-Wl,-rpath,$ORIGIN"]

# db_connector reaches SQLite, and std/sysrand reaches Security on macOS.
SYSTEM_LIBS = ["sqlite3"]
FRAMEWORKS = ["-framework", "Security"] if sys.platform == "darwin" else []


def vendor_nim_source():
    """Copy the files needed for a standalone Nim build into the sdist."""
    if os.path.exists(VENDOR_DIR):
        shutil.rmtree(VENDOR_DIR)
    os.makedirs(VENDOR_DIR)
    for filename in VENDOR_FILES:
        shutil.copy2(os.path.join(ROOT, filename), os.path.join(VENDOR_DIR, filename))
    for dirname in VENDOR_DIRS:
        shutil.copytree(os.path.join(ROOT, dirname), os.path.join(VENDOR_DIR, dirname))


def nim_project_dir():
    if os.path.exists(os.path.join(ROOT, NIMBLE_FILE)):
        return ROOT
    if os.path.exists(os.path.join(VENDOR_DIR, NIMBLE_FILE)):
        return VENDOR_DIR
    return None


def ensure_lib_built():
    project = nim_project_dir()
    if project is None:
        raise SystemExit(f"setup.py: no {NIMBLE_FILE} to build the engine from.")
    built = os.path.join(project, "build", LIB_NAME)
    if os.path.exists(built):
        return built
    try:
        subprocess.check_call(["nimble", "install", "-y", "-d"], cwd=project)
        subprocess.check_call(["nimble", "clib"], cwd=project)
    except FileNotFoundError as error:
        raise SystemExit(
            "setup.py: `nimble` not found on PATH. Building UniMedia from "
            "source needs Nim (https://nim-lang.org/install.html)."
        ) from error
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"setup.py: `nimble clib` failed: {error}") from error
    if not os.path.exists(built):
        raise SystemExit(f"setup.py: `nimble clib` did not produce {built}")
    return built


if "sdist" in sys.argv:
    vendor_nim_source()
    include_dir, library_dir = os.path.join(ROOT, "include"), ROOT
else:
    library_path = ensure_lib_built()
    library_dir = os.path.dirname(library_path)
    include_dir = os.path.join(ROOT, "include")
    if not os.path.isdir(include_dir):
        include_dir = os.path.join(VENDOR_DIR, "include")
    if BUNDLED:
        os.makedirs(PKG_DIR, exist_ok=True)
        shutil.copy2(library_path, os.path.join(PKG_DIR, LIB_NAME))

pyx = os.path.join("unimedia", "_core.pyx")
source = (
    pyx
    if os.path.exists(os.path.join(HERE, pyx))
    else os.path.join("unimedia", "_core.c")
)
extension = Extension(
    "unimedia._core",
    sources=[source],
    include_dirs=[include_dir],
    library_dirs=[library_dir],
    extra_link_args=LINK_ARGS + FRAMEWORKS,
    libraries=["UniMedia"] + SYSTEM_LIBS,
)
ext_modules = (
    cythonize([extension], language_level=3) if source.endswith(".pyx") else [extension]
)

setup(
    ext_modules=ext_modules,
    include_package_data=True,
    package_data={"unimedia": [LIB_NAME] if BUNDLED else []},
    exclude_package_data={"unimedia": ["_core.c"]},
    zip_safe=False,
)
