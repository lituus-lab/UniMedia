# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

version       = "1.0.0"
author        = "lituus-lab"
description   = "Local-first media catalogue, organizer, and duplicate finder (Nim + CLI)"
license       = "Apache-2.0"
srcDir        = "src"
binDir        = "bin"
bin           = @["om"]

requires "nim >= 2.0.0"
requires "db_connector"
# The engines, by URL rather than by sibling path: a declared dependency brings
# its own with it, which is what lets this repo name UniImage without also
# naming the UniColor, UniCompress and UniChecksum underneath it.
requires "https://github.com/lituus-lab/UniAudio#main"
requires "https://github.com/lituus-lab/UniImage#main"
requires "https://github.com/lituus-lab/UniMovie#main"
requires "https://github.com/lituus-lab/UniPercept#main"
requires "https://github.com/lituus-lab/UniCrypto#main"
# UniCrypto's BLAKE3 hasher imports malebolgia under --threads:on to spawn large
# leaves; nim.cfg compiles those sources, so this repo supplies the dependency.
requires "malebolgia >= 1.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
# UniCrypto's BLAKE3 kernels import nimsimd; its sources are compiled through
# nim.cfg's path, so this repo supplies the dependency itself.
requires "https://github.com/lbartoletti/nimsimd#master"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task buildOm, "Build the om binary":
  # `nim c`, not `nimble build`: nimble appends each dependency's declared
  # srcDir to its install path, while the installer flattened that srcDir into
  # the package root, so every engine path it passes points at a directory
  # that is not there. A task's own compile resolves them through nimblePath
  # instead, which is what every other task here relies on.
  exec "nim c -d:release --hints:off --path:src -o:bin/om src/om.nim"

task docsDeps, "Install the docs toolchain (nimib + nimibook)":
  # Not in `requires`: nimibook pulls a whole graphical stack -- pixie, x11,
  # ttf -- that building this library or its binary has no use for, and whose
  # graph nimble cannot always solve. The docs tasks install it on demand, as
  # every other repo in the family does.
  #
  # Run from a directory holding no .nimble of its own: invoked here, nimble
  # would treat this package as the target too and try to build `om` along the
  # way, which is not what installing a docs tool should do.
  mkDir "build"
  withDir "build":
    exec "nimble install -y nimib"
    exec "nimble install -y https://github.com/pietroppeter/nimibook@#v0.4.0"

task book, "Build the multipage nimib book (needs nimib + nimibook)":
  # Every Nim chapter is compiled and run, so prose that outlives its API fails
  # the build rather than misleading a reader.
  withDir "book":
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim init"
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim clean"
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim build"

task docs, "Build API reference and book into pages/":
  rmDir "pages"
  exec "nim doc --path:src --index:on --outdir:pages/api --project --hints:off src/UniMedia.nim"
  exec "nimble book"
  cpDir "book/__site", "pages/book"
  cpFile "book/__site/index.html", "pages/index.html"

task test, "Run the debug test suite":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"

task testRelease, "Run the release test suite":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"

task testCi, "Run the CI debug suite":
  exec "nimble test"

task testCiRelease, "Run the CI release suite":
  exec "nimble testRelease"

task testAll, "Build and run debug + release tests, the CLI and the C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble buildOm"
  exec "nimble ctest"

task example, "Run the Nim engine example":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

task appleVision, "Build the optional macOS Apple Vision face detector":
  when defined(macosx):
    mkDir "build"
    exec "swiftc -O -o build/unimedia-apple-vision tools/unimedia_apple_vision.swift"
  else:
    echo "Apple Vision is available only on macOS"

task clibStatic, "C static library":
  mkDir "build"
  exec "nim c --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src " &
    "-o:build/libUniMedia.a src/UniMedia/c_api.nim"

task clib, "C shared library":
  mkDir "build"
  exec "nim c --app:lib --noMain --mm:arc -d:release --path:src " &
    "-o:build/libUniMedia" & (when defined(macosx): ".dylib" else: ".so") &
    " src/UniMedia/c_api.nim"

task ctest, "Compile and run the C ABI test against the header":
  exec "nimble clibStatic"
  # The static library carries no transitive link information: SQLite comes from
  # db_connector, std/sysrand reaches Security.framework on macOS, and the
  # system HEIC decoder UniImage uses there reaches ImageIO. A `passL` inside a
  # dependency does not travel into an archive, so every framework the archive
  # needs is named here or the link fails at the caller.
  let systemLibs = when defined(macosx):
                     " -lsqlite3 -framework Security -framework ImageIO" &
                     " -framework CoreFoundation -framework CoreGraphics"
                   else: " -lsqlite3"
  exec "cc -std=c11 -Wall -Wextra -Werror -Iinclude -o build/test_abi " &
    "tests/c/test_abi.c build/libUniMedia.a" & systemLibs
  # A fresh library each run: the test asserts exact item counts.
  rmDir "build/ctest-lib"
  # A sibling the test initializes itself: inside the root it would be scanned
  # as part of the library it is meant to be separate from.
  rmDir "build/ctest-lib-fresh"
  mkDir "build/ctest-lib/inbox"
  exec "nimble buildOm"
  exec "bin/om catalog init build/ctest-lib --domain photo"
  putEnv "UNIMEDIA_C_TEST_DIR", getCurrentDir() & "/build/ctest-lib"
  exec "./build/test_abi"

task pyDeps, "Install the Python build dependencies":
  # The family's line, verbatim: a Homebrew or distribution Python refuses to
  # install into itself without the flag, and Cython 3 is what the generated
  # sources assume.
  exec "python3 -m pip install --break-system-packages --quiet setuptools " &
       "wheel \"Cython>=3.0.0\" pytest"

task buildCython, "Build the Cython extension in place":
  exec "nimble clib"
  exec "cd py && python3 setup.py build_ext --inplace"

task pyTest, "Cython extension + pytest":
  exec "nimble buildOm"
  exec "nimble buildCython"
  exec "cd py && python3 -m pytest tests -q"

task pyWheel, "Build the Python wheel":
  exec "nimble clib"
  exec "nimble pyDeps"
  # setup.py rather than `pip wheel .`, as the rest of the family does: pip
  # builds in an isolated subprocess whose path a broken editable install
  # elsewhere on the machine can corrupt, and the failure then names neither.
  exec "cd py && python3 setup.py bdist_wheel"

task testNoSsl, "Build without SSL and check the geocoder says so":
  # The refusal lives behind `when not defined(ssl)`, so no test compiled with
  # SSL can reach it. This builds the other half and runs the one command that
  # must fail, which is the only way that branch is exercised at all.
  exec "nim c --hints:off -d:noSsl --path:src -o:build/om_nossl src/om.nim"
  exec "nim c -r --hints:off --path:src -o:build/test_nossl tests/test_nossl.nim"

task coverage, "LCOV + HTML coverage for the engine sources":
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_all.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniMedia/*\" --output-file lcov.info --quiet" &
       " --ignore-errors gcov,gcov"
  # Nim can map generated end-of-procedure code one line past the source EOF.
  exec "genhtml lcov.info --output-directory coverage --legend --quiet" &
       " --ignore-errors range,range"
  exec "lcov --summary lcov.info"
