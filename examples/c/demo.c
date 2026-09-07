// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* A print-only consumer of the um_* ABI, built against the shipped header.
 *
 * It touches no library on disk: the point is that a C caller can link
 * include/UniMedia.h against the archive and reach the engine. Anything that
 * opens a catalogue belongs in tests/c/test_abi.c, which prepares one.
 */
#include "UniMedia.h"

#include <stdio.h>

int main(void) {
  if (um_init() != 0) {
    fprintf(stderr, "um_init failed: %s\n", um_last_error());
    return 1;
  }
  printf("UniMedia %s (ABI v%d)\n", um_engine_version(), um_abi_version());

  int present = -1;
  /* A path that is not a catalogue answers plainly rather than failing: the
   * distinction between "no library here" and "could not look" is the ABI's,
   * not the caller's to guess. */
  if (um_library_exists("/nonexistent-by-design", &present) != 0) {
    fprintf(stderr, "um_library_exists failed: %s\n", um_last_error());
    return 1;
  }
  printf("library at /nonexistent-by-design: %s\n", present ? "yes" : "no");
  return 0;
}
