#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Local mirror of the CI dco job: a commit must carry a Signed-off-by trailer.
# pre-commit passes the commit-msg file path as $1.
#
# Parse the trailer block rather than grepping the whole message, so this agrees
# with the CI job: a bare grep also accepts a Signed-off-by that sits outside
# the block -- followed by another paragraph, say -- which CI would reject.
set -eu
if [ "$#" -ne 1 ]; then
  echo "usage: $0 COMMIT_MSG_FILE" >&2
  exit 2
fi
msg_file="$1"
if ! git interpret-trailers --parse <"$msg_file" |
    grep -qE '^Signed-off-by: .+ <.+@.+>$'; then
  echo "Missing Signed-off-by trailer in the commit message." >&2
  echo "Re-run with:  git commit -s   (or  git commit -s --amend)" >&2
  exit 1
fi
