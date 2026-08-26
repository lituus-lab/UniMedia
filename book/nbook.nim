# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The book's table of contents.
##
## Three parts, because two audiences meet in only one place. Somebody driving
## the command line and somebody calling the C ABI need the same vocabulary and
## the same database, and nothing else in common: the first wants commands, the
## second wants types.
##
## The graphical applications are a separate product with a separate manual.
## They link this engine; they are not part of it, and documenting them here
## would tie a published Apache-2.0 book to something that is neither.
import std/os
import nimibook

createDir("__site")

var book = initBook()
book.title = "UniMedia — a local-first media library"
book.description = "Executable manual: the tool, and building on it"

book.toc = initToc:
  entry("Preface", "index.md")
  section("What a library is", "common/concepts.md"):
    entry("The database", "schema.nim")
    entry("Nothing is lost", "safety.md")
  section("Using the tool", "tool/start.nim"):
    entry("Filing by date", "filing.nim")
    entry("Finding things", "finding.nim")
    entry("Duplicates", "duplicates.nim")
    entry("Dates and places", "places.nim")
    entry("What a photograph discloses", "privacy.nim")
    entry("Housekeeping", "housekeeping.nim")
  section("Building on it", "dev/nim.nim"):
    entry("Python", "python.md")
    entry("The C ABI", "cabi.md")

nimibookCli(book)
