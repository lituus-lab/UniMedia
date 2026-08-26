# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The build that carries no SSL, checked from the outside.
##
## `nimble testNoSsl` builds `build/om_nossl` first. The refusal it checks sits
## behind `when not defined(ssl)`, so a suite compiled with SSL cannot reach
## it — running the other binary is the only way that branch is exercised.
import std/[os, osproc, strutils, unittest]

const Binary = "build" / "om_nossl"

suite "a build without SSL says so, rather than failing at the socket":
  test "an https endpoint is refused, and the message names the cause":
    if not fileExists(Binary): skip()
    else:
      let root = getTempDir() / ("unimedia-nossl-" & $getCurrentProcessId())
      createDir(root)
      defer: removeDir(root)
      # A library with nothing in it is enough: the endpoint is checked before
      # anything is looked up.
      discard execCmdEx(Binary & " catalog init " & root.quoteShell &
        " --domain photo")
      let (output, code) = execCmdEx(Binary & " geo reverse --library " &
        root.quoteShell & " --provider nominatim --network" &
        " --endpoint https://nominatim.openstreetmap.org" &
        " --user-agent \"UniMedia/1.0.0 (test)\"")
      check code != 0
      check "no SSL" in output
      # It names what to do, not the compiler flag alone.
      check "http" in output

  test "an http endpoint is accepted by the same build":
    # The refusal is about what this build can reach, not about geocoding.
    if not fileExists(Binary): skip()
    else:
      let root = getTempDir() / ("unimedia-nossl-http-" & $getCurrentProcessId())
      createDir(root)
      defer: removeDir(root)
      discard execCmdEx(Binary & " catalog init " & root.quoteShell &
        " --domain photo")
      let (output, _) = execCmdEx(Binary & " geo reverse --library " &
        root.quoteShell & " --provider nominatim --network" &
        " --endpoint http://localhost:9/nowhere" &
        " --user-agent \"UniMedia/1.0.0 (test)\"")
      check "no SSL" notin output
