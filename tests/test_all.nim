# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Importing each module executes its suites. One binary gives debug, release,
# and coverage runs the exact same test surface.
{.push warning[UnusedImport]: off.}
import test_config
import test_engine
import test_cli
{.pop.}
