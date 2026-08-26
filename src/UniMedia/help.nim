# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What the CLI can be asked, as data rather than as one long string.
##
## The overview and the per-group help are rendered from this one table, so
## the two cannot come to describe different command sets. A few words per
## action -- what it does, and what it costs where that is the surprise --
## with the reasoning left to the book.
import std/strutils

type
  HelpAction* = object
    ## One thing a group can be asked to do.
    synopsis*: string ## the line as typed, without the leading `om`
    summary*: string  ## a sentence or two on what it does

  HelpFlag* = object
    name*, meaning*: string

  HelpGroup* = object
    name*, summary*: string
    actions*: seq[HelpAction]
    flags*: seq[HelpFlag]
    note*: string ## what a reader needs before running the group, or ""

func act(synopsis, summary: string): HelpAction =
  HelpAction(synopsis: synopsis, summary: summary)

func flag(name, meaning: string): HelpFlag =
  HelpFlag(name: name, meaning: meaning)

const Groups*: seq[HelpGroup] = @[
  HelpGroup(name: "catalog",
    summary: "Index a directory and ask what is in it.",
    actions: @[
      act("catalog init DIR --domain photo|video|music|visual [--scheme S]",
        "Make DIR a library. Writes the configuration and the database into " &
        "it and touches nothing else."),
      act("catalog scan [--no-phash] [--progress]",
        "Read the library and record what changed. Hashes only files whose " &
        "size or modification time moved, so scanning an unchanged library " &
        "again is cheap."),
      act("catalog list [--kind KIND] [--limit N] [--offset N] [--json]",
        "Every item, newest first."),
      act("catalog show ID [--json]",
        "One item and everything recorded about it."),
      act("catalog search QUERY [--kind KIND] [--limit N] [--json]",
        "Items whose path contains QUERY, matched literally."),
      act("catalog filter [QUERY] [--kind K] [--keyword W ...] [--json]",
        "Items matching several conditions at once: kind, keywords, rating, " &
        "favourite, location, coordinates, a date range. A field left out " &
        "narrows nothing, which is what makes an empty filter mean everything."),
      act("catalog keywords [--prefix TEXT] [--limit N] [--json]",
        "Every keyword in use, and how many items carry it."),
      act("catalog thumbnail ID [--size 16..4096] [--json]",
        "Render a thumbnail and report where it was cached. Keyed by content, " &
        "so a file that moves keeps its thumbnail and one that changes cannot " &
        "serve a stale one."),
      act("catalog add-virtual NAME [--kind KIND] [--meta K=V ...] [--json]",
        "Record something the library describes but does not hold. A scan " &
        "leaves it alone rather than reporting it missing."),
      act("catalog meta ID [--meta KEY=VALUE ...]",
        "Show or replace an item's free-form properties. The whole object is " &
        "written, so a caller keeping a field must send it back.")],
    flags: @[
      flag("--domain", "photo, video, music or visual: what the library holds"),
      flag("--scheme", "the dated layout files are filed under: YYYY/MM-DD " &
        "(month/date), YYYY/MM/DD (month/day), YYYY/MM, YYYY/YYYY-MM-DD, or " &
        "flat")],
    note: ""),

  HelpGroup(name: "probe",
    summary: "Say what one file is, without a library.",
    actions: @[
      act("probe FILE [--json]",
        "Read the header and report the container, the codec, the size and " &
        "the duration. Video, still image and audio all answer; nothing is " &
        "decoded beyond what the header needs.")],
    flags: @[],
    note: "Takes no --library: a probe consults no catalogue."),

  HelpGroup(name: "organize",
    summary: "Import files into the library under a dated layout.",
    actions: @[
      act("organize plan SRC [--copy|--move|--hardlink] [--progress]",
        "Work out where each file under SRC would land, and write nothing. " &
        "One line per operation, including what it would skip and why."),
      act("organize apply SRC [--copy|--move|--hardlink] [--progress]",
        "Do it, as one journalled batch that `undo apply` walks backwards.")],
    flags: @[
      flag("--copy", "leave the source where it is (the default)"),
      flag("--move", "remove the source once the copy is in place"),
      flag("--hardlink", "link rather than copy; refused where the filesystem has none"),
      flag("--keep-duplicate", "import even when the library already holds " &
        "that content, suffixed _1, _2; off, the same bytes under the same " &
        "name are one file"),
      flag("--filename-date", "let a date in the file name stand in when the " &
        "file carries none"),
      flag("--birthtime-date", "accept the filesystem's creation time as a " &
        "capture date; off, because on a copied library it is the date of " &
        "the copy"),
      flag("--scheme", "the dated layout, as for `catalog init`")],
    note: "Planning reads every candidate's date, which is most of the wait " &
      "on a slow source. --progress reports it as it goes."),

  HelpGroup(name: "dedup",
    summary: "Find files that are the same picture, and resolve them.",
    actions: @[
      act("dedup find [--kind exact|visual|audio|all] [--threshold N]",
        "Group the library's duplicates and record the run. Exact groups come " &
        "from the content digest, visual ones from the perceptual hash, audio " &
        "ones from the acoustic fingerprint."),
      act("dedup review [--run ID] [--json]",
        "What a run found: each group, its members, how alike each is to the " &
        "copy the run kept, and which one that is. Decides nothing."),
      act("dedup keep GROUP ITEM [--json]",
        "Choose which copy a group keeps, in place of the one the run picked."),
      act("dedup remove [--run ID] [--yes] [--json]",
        "Send every non-keeper to the trash, as one journalled batch. Without " &
        "--yes the plan is printed and nothing moves.")],
    flags: @[
      flag("--kind", "which comparison to run; `all` runs each that applies"),
      flag("--threshold", "how alike two files must be before they are grouped"),
      flag("--yes", "required before anything is removed")],
    note: "A visual group is not proof two files are the same. Only an exact " &
      "group may become a hard link, because only there are the bytes equal."),

  HelpGroup(name: "trash",
    summary: "See and empty what removals set aside.",
    actions: @[
      act("trash list [--json]",
        "Every batch that put something in the trash, newest first, with what " &
        "it still holds. A batch appears even when its files are gone."),
      act("trash empty [BATCH ...] [--older-than DAYS] [--yes] [--json]",
        "Delete what those batches kept. Naming none takes every batch.")],
    flags: @[flag("--yes", "required: this is where recoverability ends")],
    note: "Until a batch is emptied, `undo apply` can still put its files back."),

  HelpGroup(name: "undo",
    summary: "Walk a journalled batch backwards.",
    actions: @[
      act("undo plan <BATCH|--last> [--yes] [--progress]",
        "What undoing would restore, without restoring it."),
      act("undo apply <BATCH|--last> [--yes] [--progress]",
        "Put the batch's files back. Every mutating command here writes a " &
        "batch, so each of them can be undone.")],
    flags: @[], note: ""),

  HelpGroup(name: "items",
    summary: "Remove items from the library.",
    actions: @[
      act("items remove ITEM... [--permanently] [--yes] [--json]",
        "Send the named items to the trash. --permanently deletes instead, " &
        "which no undo reaches.")],
    flags: @[], note: ""),

  HelpGroup(name: "cleanup",
    summary: "Remove what is not media.",
    actions: @[
      act("cleanup [--kind KIND ...] [--permanently] [--yes] [--progress]",
        "AppleDouble sidecars, operating-system junk, orphaned sidecars, " &
        "empty directories and interrupted batches. Each is reported with " &
        "the reason it is safe to take.")],
    flags: @[
      flag("--kind", "apple-double, os-junk, orphan-sidecar, empty-dir, interrupted")],
    note: ""),

  HelpGroup(name: "integrity",
    summary: "Check the catalogue against the disk.",
    actions: @[
      act("integrity audit [--no-hash] [--progress] [--json]",
        "Report files the catalogue names but cannot find, files whose " &
        "content no longer matches what was recorded, and rows the database " &
        "cannot resolve. --no-hash checks existence only, and is far quicker.")],
    flags: @[], note: ""),

  HelpGroup(name: "dates",
    summary: "Correct a capture date.",
    actions: @[
      act("dates set DATE ITEM... [--yes] [--progress] [--json]",
        "Write an absolute date into the files and the catalogue."),
      act("dates shift SECONDS ITEM... [--yes] [--progress] [--json]",
        "Move each item's date by the same amount, which is what a camera " &
        "set to the wrong hour needs.")],
    flags: @[],
    note: "A RAW is patched where its date already sits rather than rewritten, " &
      "so the sensor data and the maker note are never touched."),

  HelpGroup(name: "gpx",
    summary: "Put coordinates on items from a recorded track.",
    actions: @[
      act("gpx match FILE [ITEM ...] [--tolerance SECONDS] [--yes]",
        "Match each item's time against the track and write the position it " &
        "was at. --camera-offset compensates a camera clock that was wrong.")],
    flags: @[], note: ""),

  HelpGroup(name: "geo",
    summary: "Places, and the names for them.",
    actions: @[
      act("geo places [--prefix TEXT] [--limit N] [--json]",
        "Where the library's items are, grouped by place name, with how many " &
        "carry coordinates."),
      act("geo reverse [ITEM ...] --provider NAME [--network] [--yes]",
        "Turn coordinates into a place name. Results are cached, so the same " &
        "place is asked for once.")],
    flags: @[],
    note: "The geocoder reaches a third party. Nothing leaves the machine " &
      "until --network is given."),

  HelpGroup(name: "timeline",
    summary: "How the library spreads over time.",
    actions: @[
      act("timeline report [--by day|month|year] [--json]",
        "How many items fall in each period.")],
    flags: @[], note: ""),

  HelpGroup(name: "privacy",
    summary: "See and remove what files disclose.",
    actions: @[
      act("privacy audit [--json]",
        "Which items carry coordinates, a camera serial, a name, or traces of " &
        "the software that wrote them. Reads only."),
      act("privacy strip [ITEM ...] [--yes] [--progress] [--json]",
        "Rewrite the files without that metadata. A video is reported by the " &
        "audit and left alone: rewriting one is not this tool's job.")],
    flags: @[], note: ""),

  HelpGroup(name: "curate",
    summary: "Titles, ratings, keywords and albums.",
    actions: @[
      act("curate album create|list|show|add|remove|rename|cover|delete ...",
        "Albums, and which items belong to them."),
      act("curate item show ID [--json]",
        "What has been curated on one item."),
      act("curate item set ID [--title TEXT] [--rating 0..5] ... [--json]",
        "Set one item's curated fields."),
      act("curate batch set ITEM... [metadata options] [--yes] [--progress]",
        "The same edit across a selection, as one journalled batch."),
      act("curate smart create NAME [--all|--any] --rule FIELD:OP:VALUE ...",
        "An album defined by a rule rather than a list, re-evaluated when " &
        "it is asked for."),
      act("curate smart list|show|rename|delete ... [--json]",
        "The smart albums that exist.")],
    flags: @[],
    note: "Curation is written to an XMP sidecar as well as the catalogue, so " &
      "what was typed outlives this database."),

  HelpGroup(name: "faces",
    summary: "Detect and name the people in a library.",
    actions: @[
      act("faces detect ITEM [--backend EXECUTABLE] [--json]",
        "Run a detector over one item and record what it found."),
      act("faces list [--item ID] [--json]",
        "The faces recorded, and who they belong to."),
      act("faces clusters [--distance 0..32] [--json]",
        "Group unnamed faces that look like the same person."),
      act("faces name FACE NAME [--json]",
        "Give a face a name, creating the person if there is none."),
      act("faces person-create NAME [--json]",
        "Create a person with no face attached yet."),
      act("faces assign FACE PERSON [--json]",
        "Attach a face to a person that already exists."),
      act("faces clear ITEM [--yes] [--json]",
        "Forget every face recorded on one item."),
      act("faces import ITEM FILE [--json]",
        "Record faces a detector wrote elsewhere.")],
    flags: @[],
    note: "Detection needs an external backend. Without one, the rest still " &
      "works on faces already recorded."),

  HelpGroup(name: "vision",
    summary: "Captions, labels, and search by meaning.",
    actions: @[
      act("vision add ITEM MODEL VECTOR.json [--caption TEXT]",
        "Record an embedding a model produced elsewhere."),
      act("vision search MODEL VECTOR.json [--limit N] [--json]",
        "Items nearest a vector you already hold."),
      act("vision index ITEM TEXT --endpoint URL --model MODEL",
        "Embed a piece of text through a model and store it against an item."),
      act("vision semantic QUERY --endpoint URL --model MODEL [--limit N]",
        "Embed a phrase and search with it, in one call."),
      act("vision label ITEM --endpoint URL --model VISION_MODEL",
        "Ask a vision model what an item shows, and record the answer."),
      act("vision annotations [ITEM] [--json]",
        "The captions and labels recorded.")],
    flags: @[],
    note: "Everything with --endpoint reaches a model you host. Nothing is " &
      "sent anywhere without one."),

  HelpGroup(name: "sync",
    summary: "Compare a library against a remote copy.",
    actions: @[
      act("sync manifest [--json]", "What this library holds, as a manifest."),
      act("sync diff REMOTE [--json]",
        "What separates this library from a manifest."),
      act("sync plan push|pull REMOTE [--json]",
        "What a transfer would move, moving nothing."),
      act("sync apply push|pull REMOTE [--yes] [--progress] [--json]",
        "Run the transfer."),
      act("sync status [--json]",
        "Whether the tooling a transfer needs is present.")],
    flags: @[],
    note: "Transfers go through rclone, which must be installed and " &
      "configured for the remote."),

  HelpGroup(name: "config",
    summary: "The library's own settings.",
    actions: @[
      act("config show [--json]", "What the configuration file holds."),
      act("config set KEY=VALUE ... [--json]",
        "Change a setting. Keys: scheme, filenameDate, birthtimeDate, " &
        "noDateDir, onConflict, domain.")],
    flags: @[], note: "")]

func wrap(text: string; indent: string; width = 78): string =
  ## Fold `text` to `width`, every line after the first carrying `indent`.
  var column = indent.len
  var first = true
  for word in text.split(' '):
    if word.len == 0: continue
    if not first and column + 1 + word.len > width:
      result.add "\n" & indent
      column = indent.len
    elif not first:
      result.add " "
      column += 1
    result.add word
    column += word.len
    first = false

func findGroup*(name: string): int =
  ## Index of the group by that name, or -1. Callers use this to tell a help
  ## topic from a mistyped command.
  result = -1
  for index, group in Groups:
    if group.name == name: return index

func spellings*(word: string): seq[string] =
  ## Every `group action` pair whose action is spelled `word`. A word that is
  ## no command is often an action typed without its group -- `om find` for
  ## `om dedup find` -- and naming the groups that have one beats a bare
  ## refusal.
  for group in Groups:
    for action in group.actions:
      let parts = action.synopsis.split(' ')
      if parts.len >= 2 and parts[0] == group.name and parts[1] == word:
        result.add group.name & " " & word

proc groupHelp*(name: string): string =
  ## Everything one group can be asked, with a few words on each.
  let index = findGroup(name)
  if index < 0: return ""
  let group = Groups[index]
  result = "om " & group.name & " — " & group.summary & "\n\n"
  for action in group.actions:
    result.add "  om " & action.synopsis & "\n"
    result.add "      " & wrap(action.summary, "      ") & "\n\n"
  if group.flags.len > 0:
    result.add "Options:\n"
    var widest = 0
    for one in group.flags: widest = max(widest, one.name.len)
    for one in group.flags:
      let pad = " ".repeat(widest - one.name.len)
      result.add "  " & one.name & pad & "  " &
        wrap(one.meaning, " ".repeat(widest + 4)) & "\n"
    result.add "\n"
  if group.note.len > 0:
    result.add wrap(group.note, "") & "\n"

proc overview*(version: string): string =
  ## Every group in one line, and where to ask for more.
  result = "om " & version & " — local-first media library\n\n"
  result.add "Usage: om [--library DIR] COMMAND [ACTION] [options]\n\n"
  var widest = 0
  for group in Groups: widest = max(widest, group.name.len)
  for group in Groups:
    let pad = " ".repeat(widest - group.name.len)
    result.add "  " & group.name & pad & "  " &
      wrap(group.summary, " ".repeat(widest + 4)) & "\n"
  result.add "\n`om COMMAND --help` describes one of them in full.\n"

