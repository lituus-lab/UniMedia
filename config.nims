# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniMedia build config.
##
## On macOS the system HEIC and AVIF decoders are on: a photograph library is
## mostly HEIC on a Mac, and a build that cannot open one would fall back to an
## external ffmpeg for every picture. `UniImage` carries the backend; this only
## asks for it, because a `config.nims` applies to its own project and a
## consumer does not inherit the dependency's.
##
## `-d:noAppleCodecs` turns it off for a build that must link no framework.
when defined(macosx) and not defined(noAppleCodecs):
  switch("define", "appleCodecs")

# The one network client this engine has — the reverse geocoder — reaches a
# service over HTTPS, and Nim's httpclient refuses to without this. Without it
# the geocoder validated the endpoint, accepted the request and then failed on
# the connection, so naming a place was unreachable however it was called.
#
# `-d:noSsl` turns it off for a build that must link no OpenSSL; the geocoder
# then refuses an HTTPS endpoint outright rather than at the connection.
when not defined(noSsl):
  switch("define", "ssl")
