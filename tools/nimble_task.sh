#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Run a nimble task and fail when it aborts.
#
# nimble 0.22.2 exits 0 whatever happens -- a failing `exec`, a compile error, a
# `quit(1)`, even an unknown task name -- so a CI step invoking nimble directly
# can never turn red. Nimble does report the failure on its output, indented as
# `    Error:  ...`, which is what this checks. A program's own stdout starts at
# column 0, so the leading-space anchor keeps test output from tripping it.
set -euo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

nimble "$@" 2>&1 | tee "$log"

if grep -qE '^ +Error: ' "$log"; then
  echo "nimble $*: aborted (see output above)" >&2
  exit 1
fi
