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

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves nothing on its
# own -- `build/unigate canary` is the call that does, and if it ever passes,
# every other green result is worthless.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool only when it is missing, and that is
  ## deliberate. Every call here happens inside a task the gate binary is
  ## already running, and Windows locks a running executable against being
  ## overwritten. Freshness is enforced where the gate is invoked instead: CI
  ## compiles it at the start of every job, and tools/hooks/gated.sh rebuilds
  ## it when the source is newer.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"


task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

task buildOm, "Build the om binary":
  # `nim c`, not `nimble build`: nimble appends each dependency's declared
  # srcDir to its install path, while the installer flattened that srcDir into
  # the package root, so every engine path it passes points at a directory
  # that is not there. A task's own compile resolves them through nimblePath
  # instead, which is what every other task here relies on.
  exec "nim c -d:release --hints:off --path:src -o:bin/om src/om.nim"
  done "buildOm"

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
  # `nimble install` exits 0 even when it installed nothing, so this task's own
  # success marker would otherwise promise a toolchain that is not there and
  # the book would fail later with something unrelated. The compiler answers
  # truthfully: it either resolves both modules or it does not.
  writeFile("build/docsdeps_probe.nim", "import nimib, nimibook\n")
  exec "nim c --hints:off --verbosity:0 -o:build/docsdeps_probe" &
       " build/docsdeps_probe.nim"
  rmFile "build/docsdeps_probe.nim"
  done "docsDeps"

task book, "Build the multipage nimib book (needs nimib + nimibook)":
  # The tool chapters drive the real binary, so it has to exist: without it
  # they used to record `command not found` as the command's own output.
  exec gate("buildOm")
  # Every Nim chapter is compiled and run, so prose that outlives its API fails
  # the build rather than misleading a reader.
  withDir "book":
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim init"
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim clean"
    exec "nim c -r --path:../src --hints:off -o:../build/nbook nbook.nim build"
  done "book"

task docs, "Build API reference and book into pages/":
  rmDir "pages"
  exec "nim doc --path:src --index:on --outdir:pages/api --project --hints:off src/UniMedia.nim"
  exec gate("book")
  cpDir "book/__site", "pages/book"
  cpFile "book/__site/index.html", "pages/index.html"
  done "docs"

task test, "Run the debug test suite":
  exec "nim c -r --path:src -o:build/test_all tests/test_all.nim"
  done "test"

task testRelease, "Run the release test suite":
  exec "nim c -r -d:release --path:src -o:build/test_all_rel tests/test_all.nim"
  done "testRelease"

task testCi, "Run the CI debug suite":
  exec gate("test")
  done "testCi"

task testCiRelease, "Run the CI release suite":
  exec gate("testRelease")
  done "testCiRelease"

task testAll, "Build and run debug + release tests, the CLI and the C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("buildOm")
  exec gate("ctest")
  done "testAll"

task example, "Run the Nim engine example":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

task appleVision, "Build the optional macOS Apple Vision face detector":
  when defined(macosx):
    mkDir "build"
    exec "swiftc -O -o build/unimedia-apple-vision tools/unimedia_apple_vision.swift"
  else:
    echo "Apple Vision is available only on macOS"
  done "appleVision"

task clibStatic, "C static library":
  mkDir "build"
  exec "nim c --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release --path:src " &
    "-o:build/libUniMedia.a src/UniMedia/c_api.nim"
  done "clibStatic"

task clib, "C shared library":
  mkDir "build"
  exec "nim c --app:lib --noMain --mm:arc -d:release --path:src " &
    "-o:build/libUniMedia" & (when defined(windows): ".dll"
                              elif defined(macosx): ".dylib" else: ".so") &
    " src/UniMedia/c_api.nim"
  done "clib"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output. MSVC's
  # linker takes the lib name verbatim, no `lib` prefix, so the output is
  # UniMedia.lib -- which is the name py/setup.py already looks for under
  # build/, and which nothing here produced until now.
  mkDir "build"
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release" &
    " -d:staticNoAutoInit --path:src -o:build/UniMedia.lib" &
    " src/UniMedia/c_api.nim"
  done "clibMsvc"

task ctest, "Compile and run the C ABI test against the header":
  exec gate("clibStatic")
  # The static library carries no transitive link information: SQLite comes from
  # db_connector, std/sysrand reaches Security.framework on macOS, and the
  # system HEIC decoder UniImage uses there reaches ImageIO. A `passL` inside a
  # dependency does not travel into an archive, so every framework the archive
  # needs is named here or the link fails at the caller.
  let systemLibs = when defined(macosx):
                     " -lsqlite3 -framework Security -framework ImageIO" &
                     " -framework CoreFoundation -framework CoreGraphics"
                   # -lm because glibc keeps the maths functions out of libc
                   # and UniAudio's chroma and AIFF code calls them; macOS has
                   # them in libSystem, which is why only Linux failed to link.
                   else: " -lsqlite3 -lm"
  exec "cc -std=c11 -Wall -Wextra -Werror -Iinclude -o build/test_abi " &
    "tests/c/test_abi.c build/libUniMedia.a" & systemLibs
  # A fresh library each run: the test asserts exact item counts.
  rmDir "build/ctest-lib"
  # A sibling the test initializes itself: inside the root it would be scanned
  # as part of the library it is meant to be separate from.
  rmDir "build/ctest-lib-fresh"
  mkDir "build/ctest-lib/inbox"
  exec gate("buildOm")
  exec "bin/om catalog init build/ctest-lib --domain photo"
  putEnv "UNIMEDIA_C_TEST_DIR", getCurrentDir() & "/build/ctest-lib"
  exec "./build/test_abi"
  done "ctest"

task cexample, "C demo (print-only consumer of the um_* ABI)":
  # The C demo is part of the documented surface; nothing else builds it, so
  # a header change that breaks a caller shows up here rather than downstream.
  exec gate("clibStatic")
  let systemLibs = when defined(macosx):
                     " -lsqlite3 -framework Security -framework ImageIO" &
                     " -framework CoreFoundation -framework CoreGraphics"
                   else: " -lsqlite3 -lm"
  exec "cc -std=c11 -Wall -Wextra -Werror -Iinclude -o build/c_demo " &
    "examples/c/demo.c build/libUniMedia.a" & systemLibs
  exec "./build/c_demo"
  done "cexample"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task pyDeps, "Install the Python build dependencies":
  # The family's line, verbatim: a Homebrew or distribution Python refuses to
  # install into itself without the flag, and Cython 3 is what the generated
  # sources assume.
  exec "python3 -m pip install --break-system-packages --quiet setuptools " &
       "wheel \"Cython>=3.0.0\" pytest"
  done "pyDeps"

task buildCython, "Build the Cython extension in place":
  exec gate("pyLib")
  # nimscript `cd` changes the VM cwd for the next exec without a shell, so
  # the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildOm")
  exec gate("buildCython")
  cd "py"
  exec "python3 -m pytest tests -q"
  cd ".."
  done "pyTest"

task pyWheel, "Build the Python wheel":
  exec gate("clib")
  exec gate("pyDeps")
  # setup.py rather than `pip wheel .`, as the rest of the family does: pip
  # builds in an isolated subprocess whose path a broken editable install
  # elsewhere on the machine can corrupt, and the failure then names neither.
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."
  done "pyWheel"

task testNoSsl, "Build without SSL and check the geocoder says so":
  # The refusal lives behind `when not defined(ssl)`, so no test compiled with
  # SSL can reach it. This builds the other half and runs the one command that
  # must fail, which is the only way that branch is exercised at all.
  exec "nim c --hints:off -d:noSsl --path:src -o:build/om_nossl src/om.nim"
  exec "nim c -r --hints:off --path:src -o:build/test_nossl tests/test_nossl.nim"
  done "testNoSsl"

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
       # `mismatch` too: lcov 2.x and gcov disagree on the end line of the
       # destructors Nim generates, a compiler artefact with no source-level
       # fix. Every other lcov error still fails the task.
       " --ignore-errors gcov,gcov,mismatch"
  # Nim can map generated end-of-procedure code one line past the source EOF,
  # and that one artefact answers to two names: lcov 2.0, the version
  # ubuntu-latest installs, calls it `unmapped` and rejects `range` as a
  # category outright, while 2.5 calls it `range` and can filter those lines
  # away. Ask which one is there rather than assume.
  let genhtmlRange =
    if gorgeEx("genhtml --version").output.contains("LCOV version 2.0"):
      " --ignore-errors unmapped"
    else: " --filter range --ignore-errors range"
  exec "genhtml lcov.info" & genhtmlRange &
       " --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"
