# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniMedia. Built --app:staticlib/--app:lib --noMain --mm:arc
## -d:release. Keep in sync with include/UniMedia.h; tests/c links the header
## against this lib.
##
## Conventions (the header is the authoritative contract):
##   * Call `um_init()` before anything else. Repeated calls are no-ops; the
##     first call must be externally synchronized.
##   * `um_library` is opaque. The library owns it; release with
##     `um_library_close`.
##   * Reports cross as a JSON string the library allocates and the caller
##     releases with `um_buffer_free`. One call, so an operation with a cost or
##     an effect -- a scan, a dedup run -- happens exactly once. That keeps every
##     report one shape instead of a struct per query, and keeps the schema on
##     this side of the boundary, so a schema migration cannot break a caller
##     that is already linked against the library.
##   * No Nim exception or Defect crosses the ABI: every entry point traps both
##     and maps them to a `UM_*` status.
##   * The thread that opens a library owns it.
import UniMedia/[types, store, config, catalog, curation, batch_curation,
  hashing,
  date_edit, gpx, dedup, organize, removal, privacy, privacy_strip, integrity,
  thumbnails, curate, smartalbums, people, timeline, reverse_geocode,
  nominatim_client, sync, vision, external_media, external_audio, cleanup,
  trash, face_detect]
import std/[json, options, sets, locks, strutils]

when defined(danger):
  {.error: "libUniMedia must not be built with -d:danger; use -d:release".}

const UniMediaAbiVersion = 1
  ## The number a caller compares against `UNIMEDIA_ABI_VERSION` in the header
  ## it compiled against. It rises when an entry point is added as well as when
  ## one changes shape, so a caller can tell whether the call it wants exists.

type
  LibraryHandle = ref object
    store: Store

  Status = enum
    umOk = 0
    umErrInit = 1      ## um_init was not called
    umErrHandle = 2    ## unknown or already closed handle
    umErrArg = 3       ## null pointer or out-of-range argument
    umErrLibrary = 4   ## the root is not a usable library
    umErrRuntime = 5   ## the engine refused the request
    umErrCancelled = 6 ## reserved for the mutating surface

proc NimMain() {.importc.}

var
  initialized: bool
  handleLock: Lock
  libraryHandles: HashSet[pointer]

initLock(handleLock)

var lastError {.threadvar.}: string

proc setError(message: string) =
  lastError = message

proc libraryOf(p: pointer): LibraryHandle {.inline.} =
  cast[LibraryHandle](p)

proc known(p: pointer): bool =
  withLock handleLock:
    result = p in libraryHandles

template guarded(body: untyped): Status =
  ## Every entry point runs inside this: no exception, and no Defect, reaches C.
  if not initialized:
    setError("um_init was not called")
    umErrInit
  else:
    try:
      body
    except OperationCancelledError:
      setError("operation cancelled")
      umErrCancelled
    except IOError, OSError:
      setError(getCurrentExceptionMsg())
      umErrLibrary
    except CatchableError, Defect:
      setError(getCurrentExceptionMsg())
      umErrRuntime

proc emit(payload: string; output: ptr cstring): Status =
  ## Hand the caller a NUL-terminated copy it owns. Allocated with Nim's
  ## allocator, so it must come back through `um_buffer_free`, never `free`.
  if output == nil:
    setError("output must not be null")
    return umErrArg
  let buffer = cast[cstring](alloc(payload.len + 1))
  copyMem(buffer, payload.cstring, payload.len + 1)
  output[] = buffer
  umOk

type
  ProgressFn* = proc(phase: cstring; current, total: cint; message: cstring;
                     userData: pointer) {.cdecl.}
  CancelFn* = proc(userData: pointer): cint {.cdecl.}

proc progressBridge(hook: ProgressFn; userData: pointer): ProgressCallback =
  ## A plain function pointer and the caller's own context, never a Nim
  ## callback: a Nim closure carries an environment C has no way to hold.
  ## The hook runs on the thread that made the call and must not re-enter the
  ## library; Nim cannot prove an indirect call into C is GC-safe, hence the
  ## cast.
  if hook == nil: return nil
  result = proc(event: ProgressEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
      hook(event.phase.cstring, cint(event.current), cint(event.total),
        event.message.cstring, userData)

proc cancelBridge(hook: CancelFn; userData: pointer): CancelCallback =
  if hook == nil: return nil
  result = proc(): bool {.gcsafe.} =
    {.cast(gcsafe).}:
      result = hook(userData) != 0

proc applyScheme(options: var OrganizeOptions; scheme: cstring): bool =
  ## An empty or null scheme keeps the library's own preference, which is what a
  ## caller that does not want to override it passes.
  if scheme == nil or ($scheme).len == 0: return true
  try:
    options.scheme = parseScheme($scheme)
    true
  except ValueError:
    setError("scheme must be one of YYYY/MM-DD, YYYY/MM/DD, YYYY/MM, " &
      "YYYY/YYYY-MM-DD, flat")
    false

proc itemJson(item: Item): JsonNode =
  ## Field names match what `om --json` prints, so a consumer can move between
  ## the CLI and the ABI without learning a second vocabulary.
  result = %*{
    "id": item.id, "path": item.relPath, "size": item.fileSize,
    "category": item.category, "extension": item.extension,
    "creationDate": item.creationDate, "dateSource": item.dateSource,
    "width": item.width, "height": item.height,
    "hashStatus": item.hashStatus, "phashStatus": item.phashStatus,
    "location": item.locationText, "source": item.source
  }
  result["latitude"] = if item.latitude.isSome: %item.latitude.get()
                       else: newJNull()
  result["longitude"] = if item.longitude.isSome: %item.longitude.get()
                        else: newJNull()


# A shared library runs NimMain from DllMain (Windows) or an ELF constructor;
# a static one has neither, so nothing initializes the Nim runtime. The first
# entry point then enters Nim code whose globals were never set up and the
# process faults. The static-library tasks pass -d:staticNoAutoInit; shared
# builds must not, or NimMain runs twice.
when defined(staticNoAutoInit):
  # A once primitive, not a plain flag: two threads reaching an entry point
  # together would both see the flag unset, both call NimMain, and the second
  # would enter Nim code the first had not finished initializing. The platform
  # primitives block the losers until the winner returns, which a flag cannot.
  #
  # C statics, not Nim globals: module initialization would reset a Nim one and
  # NimMain would run again. NimMain is declared here too — the generated
  # prototype comes after this section.
  {.emit: """/*VARSECTION*/
void NimMain(void);
#ifdef _WIN32
#  include <windows.h>
static INIT_ONCE um_runtime_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK um_runtime_init(PINIT_ONCE o, PVOID p, PVOID *c) {
  (void)o; (void)p; (void)c; NimMain(); return TRUE;
}
static void um_runtime_ensure(void) {
  InitOnceExecuteOnce(&um_runtime_once, um_runtime_init, NULL, NULL);
}
#else
#  include <pthread.h>
static pthread_once_t um_runtime_once = PTHREAD_ONCE_INIT;
static void um_runtime_init(void) { NimMain(); }
static void um_runtime_ensure(void) {
  pthread_once(&um_runtime_once, um_runtime_init);
}
#endif
""".}
  template ensureRuntime() =
    {.emit: "  um_runtime_ensure();".}
else:
  template ensureRuntime() = discard


proc um_init(): cint {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  if not initialized:
    # NimMain only where `ensureRuntime` is a no-op. Under
    # -d:staticNoAutoInit it has already run it behind a once primitive, and
    # running it again would re-execute module initialization and reset the
    # globals the first call set up. The flag is still set either way: it is
    # what `guarded` tests to refuse a call made before um_init.
    when not defined(staticNoAutoInit):
      NimMain()
    initialized = true
  cint(umOk)

proc um_abi_version(): cint {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(UniMediaAbiVersion)

proc um_engine_version(): cstring {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  UniMediaVersion.cstring

proc um_last_error(): cstring {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  lastError.cstring

proc um_buffer_free(buffer: pointer) {.exportc, dynlib, cdecl.} =
  ## Release a JSON string the library handed out. NULL is accepted.
  ensureRuntime()
  if buffer != nil: dealloc(buffer)

proc um_library_open(root: cstring; handle: ptr pointer): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if root == nil or handle == nil:
      setError("root and handle must not be null")
      return cint(umErrArg)
    let opened = LibraryHandle(store: openLibrary($root))
    GC_ref(opened)
    let raw = cast[pointer](opened)
    withLock handleLock:
      libraryHandles.incl raw
    handle[] = raw
    umOk)

proc um_library_exists(root: cstring; present: ptr cint): cint
                      {.exportc, dynlib, cdecl.} =
  ## Whether `root` already holds a library, asked before opening one.
  ##
  ## Deliberately distinct from "can it be opened": a folder that was never a
  ## library invites creating one, while a library whose config is unreadable
  ## must show that error instead. Answering both with one status would offer
  ## to initialize over a damaged library.
  ensureRuntime()
  cint(guarded do:
    if root == nil or present == nil:
      setError("root and present must not be null")
      return cint(umErrArg)
    present[] = (if libraryExists($root): 1 else: 0)
    umOk)

proc um_library_init(root, domain, scheme: cstring; handle: ptr pointer): cint
                    {.exportc, dynlib, cdecl.} =
  ## Create a library at `root` and open it, in one call.
  ##
  ## Creating and opening separately would leave a window where the files exist
  ## and the caller holds nothing. `domain` is photo|video|music|visual and
  ## `scheme` may be NULL or "" for the default layout. Only the config and the
  ## catalogue are written: no media file is read, moved or modified. A root
  ## that already holds either is refused rather than overwritten.
  ensureRuntime()
  cint(guarded do:
    if root == nil or domain == nil or handle == nil:
      setError("root, domain and handle must not be null")
      return cint(umErrArg)
    var config: MediaDomain
    var layout = osYearMonthDayDash
    try:
      config = parseDomain($domain)
      if scheme != nil and ($scheme).len > 0:
        layout = parseScheme($scheme)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    discard initLibrary($root, config, layout)
    let opened = LibraryHandle(store: openLibrary($root))
    GC_ref(opened)
    let raw = cast[pointer](opened)
    withLock handleLock:
      libraryHandles.incl raw
    handle[] = raw
    umOk)

proc um_library_close(handle: pointer): cint {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    library.store.close()
    withLock handleLock:
      libraryHandles.excl handle
    # Not unreferenced. Freeing it lets the allocator hand the same address to
    # the next library opened, and a caller that kept the old handle then
    # reaches a library it never opened and is told nothing — the handle is
    # the identity, so the identity must not be reused. The object retained is
    # one small ref; what it held is released here.
    reset(library.store)
    umOk)

proc configJsonNode(config: LibraryConfig): JsonNode =
  ## The preferences `.organizemedia.json` holds, under the names it uses.
  ## `schemaVersion` crosses so a caller can recognize a file it was not built
  ## for; `um_config_set` refuses to change it.
  %*{
    "schemaVersion": config.schemaVersion,
    "domain": $config.domain,
    "scheme": $config.scheme,
    "filenameDate": config.filenameDate,
    "birthtimeDate": config.birthtimeDate,
    "noDateDir": config.noDateDir,
    "onConflict": $config.onConflict
  }

proc um_config_json(handle: pointer; output: ptr cstring): cint
                   {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($configJsonNode(libraryOf(handle).store.library.config), output))

proc um_config_set(handle: pointer; settings: cstring): cint
                  {.exportc, dynlib, cdecl.} =
  ## Merges `settings` into the library preferences: any key of
  ## `um_config_json` but `schemaVersion` may appear, and an absent key keeps
  ## its value. The file is rewritten through the same atomic rename the CLI
  ## uses before the handle adopts the result, so a rejected value leaves both
  ## the file and this library on the previous preferences.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if settings == nil:
      setError("settings must not be null")
      return cint(umErrArg)
    let library = libraryOf(handle)
    var updated = library.store.library.config
    try:
      let node = parseJson($settings)
      if node.kind != JObject:
        setError("settings must be a JSON object")
        return cint(umErrArg)
      for key, value in node:
        case key
        of "domain": updated.domain = parseDomain(value.getStr())
        of "scheme": updated.scheme = parseScheme(value.getStr())
        of "onConflict": updated.onConflict = parseConflict(value.getStr())
        of "noDateDir": updated.noDateDir = value.getStr()
        of "filenameDate":
          if value.kind != JBool:
            raise newException(ValueError, "filenameDate must be a boolean")
          updated.filenameDate = value.getBool()
        of "birthtimeDate":
          if value.kind != JBool:
            raise newException(ValueError, "birthtimeDate must be a boolean")
          updated.birthtimeDate = value.getBool()
        of "schemaVersion":
          raise newException(ValueError, "schemaVersion is not settable")
        else:
          raise newException(ValueError, "unknown preference: " & key)
      writeConfig(library.store.library.root, updated)
    except ValueError, JsonParsingError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    library.store.library.config = updated
    umOk)

proc um_phash_pending_count(handle: pointer; count: ptr cint): cint
                           {.exportc, dynlib, cdecl.} =
  ## How many items still owe a perceptual hash.
  ##
  ## A scan can be told to skip that work, which is most of what a scan costs
  ## and only duplicate detection needs. Whoever needs it asks this first, so
  ## it can say how much is left rather than appear to stall.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if count == nil:
      setError("count must not be null")
      return cint(umErrArg)
    count[] = cint(pendingPerceptualCount(libraryOf(handle).store))
    umOk)

proc um_scan(handle: pointer; skipPhash: cint; onProgress: ProgressFn;
             onCancel: CancelFn; userData: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let report = scanLibrary(library.store, skipPhash != 0,
      progressBridge(onProgress, userData), cancelBridge(onCancel, userData))
    emit($(%*{"indexed": report.indexed, "updated": report.updated,
      "removed": report.removed, "hashErrors": report.hashErrors}), output))

proc um_item_count(handle: pointer; kind: cstring; count: ptr cint): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if count == nil:
      setError("count must not be null")
      return cint(umErrArg)
    count[] = cint(countItems(libraryOf(handle).store,
      if kind == nil: "" else: $kind))
    umOk)

proc um_items_json(handle: pointer; kind: cstring; limit, offset: cint;
                   output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if limit <= 0 or offset < 0:
      setError("limit must be positive and offset must not be negative")
      return cint(umErrArg)
    var items = newJArray()
    for item in listItemsPage(libraryOf(handle).store,
        (if kind == nil: "" else: $kind), int(limit), int(offset)):
      items.add itemJson(item)
    emit($items, output))

proc um_dedup_find(handle: pointer; kind: cstring; threshold: cdouble;
                   onProgress: ProgressFn; onCancel: CancelFn;
                   userData: pointer; runId: ptr int64): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if runId == nil:
      setError("runId must not be null")
      return cint(umErrArg)
    let requested = if kind == nil: "all" else: ($kind).toLowerAscii()
    let selected = case requested
      of "exact": dkExact
      of "visual": dkVisual
      of "all": dkAll
      else:
        setError("kind must be exact, visual or all")
        return cint(umErrArg)
    runId[] = findDuplicates(libraryOf(handle).store, selected,
      float(threshold), progressBridge(onProgress, userData),
      cancelBridge(onCancel, userData))
    umOk)

proc um_dedup_review_json(handle: pointer; runId: int64;
                          output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let run = loadDedupRun(libraryOf(handle).store, runId)
    var groups = newJArray()
    for group in run.groups:
      var members = newJArray()
      for member in group.members:
        members.add %*{"item": member.itemId, "path": member.relPath,
          "similarity": member.similarity, "keeper": member.isKeeper}
      groups.add %*{"group": group.id, "kind": group.kind, "members": members}
    emit($(%*{"run": run.id, "kind": run.kind, "threshold": run.threshold,
      "groups": groups}), output))

proc um_organize_plan_json(handle: pointer; source, scheme: cstring;
                           keepDuplicates: cint;
                           output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What importing `source` would do, changing nothing.
  ##
  ## A non-zero `keepDuplicates` copies a file even where an identical one
  ## already holds its place, suffixing it; zero treats the same bytes under the
  ## same name as one file.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if source == nil:
      setError("source must not be null")
      return cint(umErrArg)
    let library = libraryOf(handle)
    var options = defaultOrganizeOptions(library.store.library.config)
    options.keepDuplicates = keepDuplicates != 0
    if not applyScheme(options, scheme): return cint(umErrArg)
    let plan = planOrganize(library.store, $source, options)
    var operations = newJArray()
    for operation in plan.operations:
      operations.add %*{"operation": $operation.kind,
        "source": operation.sourcePath, "destination": operation.destRelPath,
        "size": operation.size, "date": operation.creationDate,
        "dateSource": operation.dateSource, "skipReason": operation.skipReason}
    emit($(%*{"sourceRoot": plan.sourceRoot, "operations": operations}),
      output))

proc um_organize_apply(handle: pointer; source, mode, scheme: cstring;
                       keepDuplicates: cint; onProgress: ProgressFn;
                       userData: pointer;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Plan and apply in one call: the plan a caller confirmed is rebuilt here, so
  ## a file that appeared in between is caught by the same conflict rules rather
  ## than acted on from a stale plan. Journalled, so an interruption is
  ## reconciled by the next run instead of cancelled mid-way.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if source == nil:
      setError("source must not be null")
      return cint(umErrArg)
    let library = libraryOf(handle)
    var options = defaultOrganizeOptions(library.store.library.config)
    options.keepDuplicates = keepDuplicates != 0
    let requested = if mode == nil: "copy" else: $mode
    options.mode = case requested
      of "copy": tmCopy
      of "move": tmMove
      of "hardlink": tmHardlink
      else:
        setError("mode must be copy, move or hardlink")
        return cint(umErrArg)
    if not applyScheme(options, scheme): return cint(umErrArg)
    let plan = planOrganize(library.store, $source, options)
    let report = applyPlan(library.store, plan,
      progressBridge(onProgress, userData))
    emit($(%*{"batch": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed}), output))

proc um_undo_plan_json(handle: pointer; batch: cstring;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## An empty or null `batch` selects the most recent one.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var operations = newJArray()
    for operation in planUndo(libraryOf(handle).store,
        (if batch == nil: "" else: $batch)):
      operations.add %*{"operation": $operation.kind,
        "source": operation.sourcePath, "destination": operation.destRelPath}
    emit($operations, output))

proc um_undo_apply(handle: pointer; batch: cstring; onProgress: ProgressFn;
                   userData: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let report = applyUndo(libraryOf(handle).store,
      (if batch == nil: "" else: $batch), progressBridge(onProgress, userData))
    emit($(%*{"batch": report.batchId, "undone": report.undone,
      "skipped": report.skipped, "failed": report.failed}), output))

proc um_dedup_keep(handle: pointer; groupId, itemId: int64): cint
    {.exportc, dynlib, cdecl.} =
  ## Select the one active member a removal must not touch.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    setDedupKeeper(libraryOf(handle).store, groupId, itemId)
    umOk)

proc um_dedup_remove(handle: pointer; runId: int64; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Recoverable: non-keepers move to the hash-verified trash and undo restores
  ## them. Pass 0 for the most recent run.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let report = applyDedupRemoval(libraryOf(handle).store, runId)
    emit($(%*{"batch": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed}), output))

proc um_integrity_audit_json(handle: pointer; verifyHashes: cint;
                             onProgress: ProgressFn; onCancel: CancelFn;
                             userData: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let report = auditIntegrity(libraryOf(handle).store, verifyHashes != 0,
      progressBridge(onProgress, userData), cancelBridge(onCancel, userData))
    var findings = newJArray()
    for finding in report.findings:
      findings.add %*{"item": finding.itemId, "path": finding.relPath,
        "kind": finding.kind, "detail": finding.detail}
    emit($(%*{"checked": report.checked, "missing": report.missing,
      "changed": report.changed, "hashMismatches": report.hashMismatches,
      "databaseErrors": report.databaseErrors, "findings": findings}), output))

proc um_thumbnail_json(handle: pointer; itemId: int64; maxEdge: cint;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The one raster contract: a deterministic PNG under `.om-cache/thumbnails`,
  ## keyed by content digest, edge and algorithm version. A caller renders the
  ## returned path; it never decodes or caches a second time.
  ## Report: {"item","path","width","height","maxEdge","cacheHit"}.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let thumbnail = ensureThumbnail(libraryOf(handle).store, itemId,
      int(maxEdge))
    emit($(%*{"item": thumbnail.itemId, "path": thumbnail.path,
      "width": thumbnail.width, "height": thumbnail.height,
      "maxEdge": thumbnail.maxEdge, "cacheHit": thumbnail.cacheHit}), output))

proc parseIdArray(raw: cstring; allowEmpty: bool; wanted: var seq[int64]): bool =
  ## Shared by every entry point taking a JSON array of item ids. Returns false
  ## with the error already set, so the caller answers UM_ERR_ARG.
  try:
    let node = parseJson($raw)
    if node.kind != JArray:
      raise newException(ValueError, "expected a JSON array of item ids")
    if node.len == 0 and not allowEmpty:
      raise newException(ValueError, "expected a non-empty JSON array")
    for entry in node:
      if entry.kind != JInt:
        raise newException(ValueError, "item ids must be integers")
      wanted.add entry.getBiggestInt()
    true
  except ValueError, JsonParsingError:
    setError(getCurrentExceptionMsg())
    false

proc batchReportJson(report: CurationBatchReport): JsonNode =
  var failures = newJArray()
  for failure in report.failures:
    failures.add %*{"item": failure.itemId, "path": failure.relPath,
      "error": failure.error}
  %*{"applied": report.applied, "written": report.written,
    "batch": report.batchId, "failed": report.failed, "failures": failures}

proc curationJson(curation: ItemCuration): JsonNode =
  result = %*{
    "item": curation.itemId, "title": curation.title,
    "description": curation.description, "rating": curation.rating,
    "favorite": curation.favorite, "keywords": curation.keywords,
    "creator": curation.creator, "copyright": curation.copyright,
    "creationDate": curation.creationDate, "dateSource": curation.dateSource,
    "location": curation.locationText, "updatedAt": curation.updatedAt
  }
  result["latitude"] = if curation.latitude.isSome: %curation.latitude.get()
                       else: newJNull()
  result["longitude"] = if curation.longitude.isSome: %curation.longitude.get()
                        else: newJNull()

proc patchFromJson(raw: cstring; patch: var CurationPatch): bool =
  ## An absent key preserves what the item holds; an empty string or list
  ## clears the property. `clearGps` drops the coordinates outright, which no
  ## coordinate value could express.
  try:
    let node = parseJson($raw)
    if node.kind != JObject:
      raise newException(ValueError, "patch must be a JSON object")
    for key, value in node:
      case key
      of "title": patch.title = some(value.getStr())
      of "description": patch.description = some(value.getStr())
      of "rating": patch.rating = some(value.getInt())
      of "favorite": patch.favorite = some(value.getBool())
      of "copyright": patch.copyright = some(value.getStr())
      of "location": patch.locationText = some(value.getStr())
      of "creationDate": patch.creationDate = some(value.getStr())
      of "latitude": patch.latitude = some(value.getFloat())
      of "longitude": patch.longitude = some(value.getFloat())
      of "clearGps": patch.clearGps = value.getBool()
      of "keywords", "creator", "addKeywords", "removeKeywords":
        if value.kind != JArray:
          raise newException(ValueError, key & " must be an array of strings")
        var texts: seq[string]
        for entry in value:
          if entry.kind != JString:
            raise newException(ValueError, key & " must hold strings")
          texts.add entry.getStr()
        case key
        of "keywords": patch.keywords = some(texts)
        of "creator": patch.creator = some(texts)
        of "addKeywords": patch.addKeywords = texts
        else: patch.removeKeywords = texts
      else:
        raise newException(ValueError, "unknown curation field: " & key)
    true
  except ValueError, JsonParsingError, KeyError:
    setError(getCurrentExceptionMsg())
    false

proc um_curation_json(handle: pointer; itemId: int64;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What an item carries: title, description, rating, favourite, keywords,
  ## creator, copyright, date and place. Read from the XMP sidecar, so it is
  ## what a another application reading the folder would see.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($curationJson(getItemCuration(libraryOf(handle).store, itemId)),
      output))

proc um_curate_item(handle: pointer; itemId: int64; patch: cstring;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Apply `patch` to one item and return what it holds afterwards. Written
  ## through curation's crash-recovery journal, so an interrupted write is
  ## finished or rolled back by the next call rather than left half-applied.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if patch == nil:
      setError("patch must not be null")
      return cint(umErrArg)
    var edit: CurationPatch
    if not patchFromJson(patch, edit):
      return cint(umErrArg)
    let library = libraryOf(handle)
    var updated: ItemCuration
    try:
      updated = curateItem(library.store, itemId, edit)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($curationJson(updated), output))

proc um_curation_batch_apply(handle: pointer; itemIds, patch: cstring;
                             onProgress: ProgressFn; onCancel: CancelFn;
                             userData: pointer; output: ptr cstring): cint
                            {.exportc, dynlib, cdecl.} =
  ## The same patch across a selection. Report:
  ## {"applied","failed","failures":[{"item","path","error"}]}. Failures are
  ## per item: one unwritable sidecar does not abandon the rest.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if itemIds == nil or patch == nil:
      setError("itemIds and patch must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if not parseIdArray(itemIds, false, wanted):
      return cint(umErrArg)
    var edit: CurationPatch
    if not patchFromJson(patch, edit):
      return cint(umErrArg)
    let library = libraryOf(handle)
    var plan: CurationBatchPlan
    try:
      plan = planCurationBatch(library.store, wanted, edit)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    let report = applyCurationBatch(library.store, plan,
      progressBridge(onProgress, userData), cancelBridge(onCancel, userData))
    emit($batchReportJson(report), output))

proc um_keywords_json(handle: pointer; prefix: cstring; limit: cint;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Keywords already in use, with how many items carry each. An editor offers
  ## these instead of inviting a second spelling of the same word.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if limit <= 0:
      setError("limit must be positive")
      return cint(umErrArg)
    var facets = newJArray()
    for facet in listKeywordFacets(libraryOf(handle).store,
        (if prefix == nil: "" else: $prefix), int(limit)):
      facets.add %*{"keyword": facet.keyword, "count": facet.itemCount}
    emit($facets, output))

proc datePlan(store: Store; mode, value: cstring;
              wanted: seq[int64]): DateEditPlan =
  ## "set" takes an absolute date, "shift" a signed number of seconds. Both
  ## refuse a selection they cannot express rather than skipping part of it.
  case $mode
  of "set": planDateSet(store, wanted, $value)
  of "shift":
    var seconds: int64
    try: seconds = parseBiggestInt($value)
    except ValueError:
      raise newException(ValueError, "shift value must be a whole number of seconds")
    planDateShift(store, wanted, seconds)
  else:
    raise newException(ValueError, "date mode must be \"set\" or \"shift\"")

proc um_dates_plan_json(handle: pointer; itemIds, mode, value: cstring;
                        output: ptr cstring): cint
                       {.exportc, dynlib, cdecl.} =
  ## What a date correction would change, item by item, changing nothing.
  ## Report: {"entries":[{"item","path","oldDate","newDate","writesFile"}]}.
  ## `writesFile` is false where no writer here reaches that container: the
  ## catalogue is corrected and the file keeps the date its camera wrote.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if itemIds == nil or mode == nil or value == nil:
      setError("itemIds, mode and value must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if not parseIdArray(itemIds, false, wanted):
      return cint(umErrArg)
    var entries = newJArray()
    try:
      for entry in datePlan(libraryOf(handle).store, mode, value,
          wanted).entries:
        entries.add %*{"item": entry.itemId, "path": entry.relPath,
          "oldDate": entry.oldDate, "newDate": entry.newDate,
          "writesFile": entry.writesFile}
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($(%*{"entries": entries}), output))

proc um_dates_apply(handle: pointer; itemIds, mode, value: cstring;
                    onProgress: ProgressFn; onCancel: CancelFn;
                    userData: pointer; output: ptr cstring): cint
                   {.exportc, dynlib, cdecl.} =
  ## Apply the same correction. The plan is rebuilt here, so a caller cannot
  ## apply one it displayed before the dates moved; the engine also refuses a
  ## plan whose items have changed underneath it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if itemIds == nil or mode == nil or value == nil:
      setError("itemIds, mode and value must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if not parseIdArray(itemIds, false, wanted):
      return cint(umErrArg)
    let library = libraryOf(handle)
    var plan: DateEditPlan
    try:
      plan = datePlan(library.store, mode, value, wanted)
      if plan.entries.len == 0:
        raise newException(ValueError, "no item to correct")
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($batchReportJson(applyDateEdit(library.store, plan,
      progressBridge(onProgress, userData),
      cancelBridge(onCancel, userData))), output))

proc um_gpx_plan_json(handle: pointer; gpxPath, itemIds: cstring;
                      toleranceSeconds, cameraUtcOffsetMinutes, refresh: cint;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Which items a GPX track would place, and how far each match is in time.
  ## `itemIds` may be NULL or [] for the whole catalogue.
  ##
  ## An item that already carries a position is reported with
  ## `alreadyPlaced` and not matched; a non-zero `refresh` places it anyway.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if gpxPath == nil:
      setError("gpxPath must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if itemIds != nil and not parseIdArray(itemIds, true, wanted):
      return cint(umErrArg)
    var plan: GpxMatchPlan
    try:
      plan = planGpxMatch(libraryOf(handle).store, $gpxPath, wanted,
        int(toleranceSeconds), int(cameraUtcOffsetMinutes), refresh != 0)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    var entries = newJArray()
    for entry in plan.entries:
      entries.add %*{"item": entry.itemId, "path": entry.relPath,
        "creationDate": entry.creationDate, "matched": entry.matched,
        "alreadyPlaced": entry.alreadyPlaced,
        "distanceSeconds": entry.distanceSeconds,
        "latitude": entry.latitude, "longitude": entry.longitude}
    emit($(%*{"source": plan.sourcePath,
      "toleranceSeconds": plan.toleranceSeconds,
      "cameraUtcOffsetMinutes": plan.cameraUtcOffsetMinutes,
      "trackPointCount": plan.trackPointCount, "refreshed": plan.refreshed,
      "entries": entries}), output))

proc um_gpx_apply(handle: pointer; gpxPath, itemIds: cstring;
                  toleranceSeconds, cameraUtcOffsetMinutes, refresh: cint;
                  onProgress: ProgressFn; onCancel: CancelFn;
                  userData: pointer; output: ptr cstring): cint
                 {.exportc, dynlib, cdecl.} =
  ## Write the matched coordinates. Rebuilt from the same track and settings,
  ## and refused outright when nothing matches, so an empty run cannot read as
  ## a successful one.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if gpxPath == nil:
      setError("gpxPath must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if itemIds != nil and not parseIdArray(itemIds, true, wanted):
      return cint(umErrArg)
    let library = libraryOf(handle)
    var plan: GpxMatchPlan
    try:
      plan = planGpxMatch(library.store, $gpxPath, wanted,
        int(toleranceSeconds), int(cameraUtcOffsetMinutes), refresh != 0)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    var report: CurationBatchReport
    try:
      report = applyGpxMatch(library.store, plan,
        progressBridge(onProgress, userData), cancelBridge(onCancel, userData))
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($batchReportJson(report), output))

proc um_privacy_audit_json(handle: pointer; output: ptr cstring): cint
                          {.exportc, dynlib, cdecl.} =
  ## What each item still discloses: an array of
  ## {"item","path","signals":[…],"error"}. A signal is "gps", "camera",
  ## "software" or "identity"; `error` is why an item could not be read.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var findings = newJArray()
    for finding in privacyAudit(libraryOf(handle).store):
      findings.add %*{"item": finding.itemId, "path": finding.relPath,
        "signals": finding.signals, "error": finding.error}
    emit($findings, output))

proc um_privacy_strip_plan_json(handle: pointer; itemIds: cstring;
                                output: ptr cstring): cint
                               {.exportc, dynlib, cdecl.} =
  ## What a strip would touch, changing nothing. `itemIds` is a JSON array;
  ## NULL or [] means every item the audit reported.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var wanted: seq[int64]
    if itemIds != nil and not parseIdArray(itemIds, true, wanted):
      return cint(umErrArg)
    var entries = newJArray()
    try:
      for entry in planPrivacyStrip(libraryOf(handle).store, wanted).entries:
        entries.add %*{"item": entry.itemId, "path": entry.relPath,
          "signals": entry.signals, "strippable": entry.strippable}
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($(%*{"entries": entries}), output))

proc um_privacy_strip_apply(handle: pointer; itemIds: cstring;
                            onProgress: ProgressFn; userData: pointer;
                            output: ptr cstring): cint
                           {.exportc, dynlib, cdecl.} =
  ## Strip the metadata. The plan is rebuilt here from the same selection, so
  ## a caller cannot apply one it displayed before the library moved on.
  ## Journalled: the original is kept, and um_undo_apply restores it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var wanted: seq[int64]
    if itemIds != nil and not parseIdArray(itemIds, true, wanted):
      return cint(umErrArg)
    let library = libraryOf(handle)
    var plan: PrivacyStripPlan
    try:
      plan = planPrivacyStrip(library.store, wanted)
      if plan.entries.len == 0:
        raise newException(ValueError, "nothing to strip")
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    let report = applyPrivacyStrip(library.store, plan,
      progressBridge(onProgress, userData))
    emit($(%*{"batch": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed}), output))

proc um_items_remove(handle: pointer; itemIds: cstring;
                     output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Remove the catalogued items named by `itemIds`, a JSON array of ids, with
  ## no duplicate run involved. They move to the journaled trash like any other
  ## removal, so `um_undo_apply` brings them back.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if itemIds == nil:
      setError("itemIds must not be null")
      return cint(umErrArg)
    var wanted: seq[int64]
    if not parseIdArray(itemIds, false, wanted):
      return cint(umErrArg)
    let report = trashItems(libraryOf(handle).store, wanted)
    emit($(%*{"batch": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed}), output))

proc um_dedup_remove_item(handle: pointer; runId, itemId: int64;
                          output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Remove one reviewed duplicate, for a caller working through a run item by
  ## item. It can only remove fewer files than um_dedup_remove: the plan still
  ## excludes keepers, so asking for one cannot cost a protected file.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let report = applyDedupRemoval(libraryOf(handle).store, runId, @[itemId])
    emit($(%*{"batch": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed}), output))

# Albums, both kinds. An album is a list somebody curated; a smart album is a
# query that produces one. They are reported the same way so a caller shows
# them side by side, which is how a library is browsed.

proc albumJson(album: Album): JsonNode =
  %*{"id": album.id, "name": album.name, "createdAt": album.createdAt,
     "itemCount": album.itemCount, "coverItemId": album.coverItemId,
     "parentId": album.parentId}

proc smartAlbumJson(album: SmartAlbum): JsonNode =
  var rules = newJArray()
  for rule in album.rules:
    rules.add %*{"field": rule.field, "operator": rule.operator,
                 "value": rule.value}
  %*{"id": album.id, "name": album.name, "matchAll": album.matchAll,
     "createdAt": album.createdAt, "itemCount": album.itemCount,
     "rules": rules}

proc um_albums_json(handle: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Every album, with its item count and cover.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var albums = newJArray()
    for album in listAlbums(libraryOf(handle).store): albums.add albumJson(album)
    emit($albums, output))

proc um_album_items_json(handle: pointer; albumId: int64;
                         output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The items an album holds, in the order it holds them.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var items = newJArray()
    for item in listAlbumItems(libraryOf(handle).store, albumId):
      items.add itemJson(item)
    emit($items, output))

proc um_album_create(handle: pointer; name: cstring; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Create an album and return it, so the caller learns the identifier it was
  ## given without a second call.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0:
      setError("an album needs a name")
      return cint(umErrArg)
    let library = libraryOf(handle)
    emit($albumJson(createAlbum(library.store, $name)), output))

proc um_album_rename(handle: pointer; albumId: int64; name: cstring;
                     output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Rename an album and return it as it now stands.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0:
      setError("an album needs a name")
      return cint(umErrArg)
    let library = libraryOf(handle)
    emit($albumJson(renameAlbum(library.store, albumId, $name)), output))

proc um_album_delete(handle: pointer; albumId: int64): cint
    {.exportc, dynlib, cdecl.} =
  ## Delete an album. The items it held are untouched: an album is a list of
  ## them, never their owner.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    deleteAlbum(library.store, albumId)
    umOk)

proc um_album_add_item(handle: pointer; albumId, itemId: int64;
                       added: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Put an item in an album. `added` is 0 when it was already there, which is
  ## not a failure — adding twice is how a caller makes sure.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if added == nil:
      setError("added must not be null")
      return cint(umErrArg)
    let library = libraryOf(handle)
    added[] = cint(if addAlbumItem(library.store, albumId, itemId): 1 else: 0)
    umOk)

proc um_album_remove_item(handle: pointer; albumId, itemId: int64;
                          removed: ptr cint): cint
    {.exportc, dynlib, cdecl.} =
  ## Take an item out of an album. `removed` is 0 when it was not in it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if removed == nil:
      setError("removed must not be null")
      return cint(umErrArg)
    let library = libraryOf(handle)
    removed[] = cint(
      if removeAlbumItem(library.store, albumId, itemId): 1 else: 0)
    umOk)

proc um_album_set_cover(handle: pointer; albumId, itemId: int64;
                        output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Set an album's cover, or clear it by passing an item id of 0.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let album = if itemId == 0: clearAlbumCover(library.store, albumId)
                else: setAlbumCover(library.store, albumId, itemId)
    emit($albumJson(album), output))

proc um_smart_albums_json(handle: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Every smart album, with the rules that define it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var albums = newJArray()
    for album in listSmartAlbums(libraryOf(handle).store):
      albums.add smartAlbumJson(album)
    emit($albums, output))

proc um_smart_album_items_json(handle: pointer; albumId: int64;
                               output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What a smart album currently matches. Evaluated on the call, so it answers
  ## for the library as it stands rather than as it stood when the album was
  ## made.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var items = newJArray()
    for item in listSmartAlbumItems(libraryOf(handle).store, albumId):
      items.add itemJson(item)
    emit($items, output))

proc um_smart_album_create(handle: pointer; name: cstring; matchAll: cint;
                           rules: cstring; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Create a smart album from rules given as JSON — an array of
  ## `{"field": ..., "operator": ..., "value": ...}`. `matchAll` non-zero
  ## requires every rule; zero matches an item that satisfies any of them.
  ##
  ## The rules are checked by the engine, not here: a field or an operator it
  ## does not know is refused with the reason, so the two cannot disagree about
  ## what is valid.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0:
      setError("a smart album needs a name")
      return cint(umErrArg)
    if rules == nil:
      setError("rules must not be null")
      return cint(umErrArg)
    var parsed: seq[SmartRule]
    let document = try: parseJson($rules)
      except CatchableError:
        setError("rules must be JSON")
        return cint(umErrArg)
    if document.kind != JArray:
      setError("rules must be a JSON array")
      return cint(umErrArg)
    for entry in document:
      if entry.kind != JObject or not entry.hasKey("field") or
          not entry.hasKey("operator") or not entry.hasKey("value"):
        setError("every rule needs field, operator and value")
        return cint(umErrArg)
      parsed.add SmartRule(field: entry["field"].getStr(),
        operator: entry["operator"].getStr(),
        value: entry["value"].getStr())
    let library = libraryOf(handle)
    emit($smartAlbumJson(createSmartAlbum(library.store, $name,
      matchAll != 0, parsed)), output))

proc um_smart_album_rename(handle: pointer; albumId: int64; name: cstring;
                           output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Rename a smart album and return it as it now stands.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0:
      setError("a smart album needs a name")
      return cint(umErrArg)
    let library = libraryOf(handle)
    emit($smartAlbumJson(renameSmartAlbum(library.store, albumId, $name)),
      output))

proc um_smart_album_delete(handle: pointer; albumId: int64): cint
    {.exportc, dynlib, cdecl.} =
  ## Delete a smart album. It holds no items of its own, so nothing else goes.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    deleteSmartAlbum(library.store, albumId)
    umOk)

# People and faces. A face is a rectangle the detector found; a person is a
# name several faces were attached to. Detection itself is optional and lives
# behind a build flag, so a library with none reports an empty list rather than
# failing.

proc personJson(person: Person): JsonNode =
  %*{"id": person.id, "name": person.name, "createdAt": person.createdAt,
     "faceCount": person.faceCount}

proc faceJson(face: Face): JsonNode =
  %*{"id": face.id, "itemId": face.itemId, "personId": face.personId,
     "x": face.x, "y": face.y, "width": face.width, "height": face.height,
     "confidence": face.confidence, "signatureValid": face.signatureValid,
     "detector": face.detector, "detectedAt": face.detectedAt}

proc um_people_json(handle: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Every named person, with how many faces carry that name.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var people = newJArray()
    for person in listPeople(libraryOf(handle).store):
      people.add personJson(person)
    emit($people, output))

proc um_faces_json(handle: pointer; itemId: int64; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The faces found in one item, or in the whole library when `itemId` is 0.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var faces = newJArray()
    for face in listFaces(libraryOf(handle).store, itemId):
      faces.add faceJson(face)
    emit($faces, output))

proc um_person_create(handle: pointer; name: cstring; personId: ptr int64): cint
    {.exportc, dynlib, cdecl.} =
  ## Create a person and hand back the identifier faces are attached to.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0 or personId == nil:
      setError("a person needs a name, and personId must not be null")
      return cint(umErrArg)
    personId[] = createPerson(libraryOf(handle).store, $name)
    umOk)

proc um_face_assign(handle: pointer; faceId, personId: int64): cint
    {.exportc, dynlib, cdecl.} =
  ## Attach a face to a person that already exists.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    assignFace(libraryOf(handle).store, faceId, personId)
    umOk)

proc um_face_assign_name(handle: pointer; faceId: int64; name: cstring;
                         output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Attach a face to a person named `name`, creating that person if there is
  ## none — which is what naming a face in an interface means.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or ($name).len == 0:
      setError("a person needs a name")
      return cint(umErrArg)
    emit($personJson(assignFaceName(libraryOf(handle).store, faceId, $name)),
      output))

proc um_faces_clear(handle: pointer; itemId: int64;
                    includeAssigned: cint): cint {.exportc, dynlib, cdecl.} =
  ## Forget the faces found in an item. Assigned ones are kept unless
  ## `includeAssigned` is non-zero, so re-detecting does not throw away the
  ## names somebody typed.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    clearFaces(libraryOf(handle).store, itemId, includeAssigned != 0)
    umOk)

proc um_faces_cluster_json(handle: pointer; maxDistance: cint;
                           output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Group the unassigned faces that look alike, so a caller can offer to name
  ## a group at once. `maxDistance` is how many bits of the signature may
  ## differ, 0 to 32; it groups nothing at 0 and everything at 32.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if maxDistance notin 0 .. 32:
      setError("maxDistance must be between 0 and 32")
      return cint(umErrArg)
    var clusters = newJArray()
    for cluster in clusterFaces(libraryOf(handle).store, int(maxDistance)):
      var ids = newJArray()
      for id in cluster.faceIds: ids.add %id
      clusters.add %*{"faceIds": ids,
        "representativeSignature": $cluster.representativeSignature}
    emit($clusters, output))

# The rest of the subject: when things were taken, where, keeping two copies of
# a library in step, and what a model says is in a picture.

proc um_timeline_json(handle: pointer; period: cstring;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## How many items fall in each day, month or year, with their total size.
  ## `period` is "day", "month" or "year"; null means month.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var by = tpMonth
    if period != nil and ($period).len > 0:
      try: by = parseTimelinePeriod($period)
      except ValueError:
        setError("period must be day, month or year")
        return cint(umErrArg)
    var buckets = newJArray()
    for bucket in timelineReport(libraryOf(handle).store, by):
      buckets.add %*{"period": bucket.period, "itemCount": bucket.itemCount,
                     "totalBytes": bucket.totalBytes}
    emit($buckets, output))

proc geocodePlanJson(plan: ReverseGeocodePlan): JsonNode =
  var entries = newJArray()
  for entry in plan.entries:
    entries.add %*{"itemId": entry.itemId, "path": entry.relPath,
      "oldLocation": entry.oldLocation, "newLocation": entry.newLocation,
      "attribution": entry.attribution, "latitude": entry.latitude,
      "longitude": entry.longitude, "fromCache": entry.fromCache}
  %*{"provider": plan.provider, "language": plan.language, "entries": entries}

proc geocodeArgumentsOk(provider, endpoint: cstring;
                        refreshCache: cint): bool =
  ## The same two rules the command line applies, so the two front ends cannot
  ## disagree about what a valid request is.
  if provider == nil or ($provider).strip().len == 0:
    setError("a provider must be named")
    return false
  if refreshCache != 0 and (endpoint == nil or ($endpoint).len == 0):
    setError("refreshing the cache needs an endpoint to ask")
    return false
  true

proc geocodeProvider(endpoint, userAgent: cstring): ReverseGeocodeProvider =
  ## A network provider when an endpoint is given, and none otherwise — which
  ## makes the plan answer from the cache alone. A caller that has not decided
  ## to make network calls must not make them by omission.
  if endpoint == nil or ($endpoint).len == 0: nil
  else: newNominatimProvider($endpoint,
    if userAgent == nil: "" else: $userAgent)

proc um_geocode_plan_json(handle: pointer; provider, language, endpoint,
                          userAgent: cstring; overwrite, refreshCache: cint;
                          output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What naming the places in a library would change, without changing any of
  ## it. Planning and applying are separate calls, as they are for organising,
  ## so a caller can show the change before it happens.
  ##
  ## With no `endpoint` no network call is made and the plan is answered from
  ## the cache alone — which fails, rather than guessing, for an item the cache
  ## has never seen. `overwrite` non-zero replaces a location an item already
  ## has; `refreshCache` non-zero asks the provider again rather than trusting
  ## what was stored.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if not geocodeArgumentsOk(provider, endpoint, refreshCache):
      return cint(umErrArg)
    let library = libraryOf(handle)
    let plan = planReverseGeocode(library.store, $provider,
      (if language == nil: "" else: $language),
      geocodeProvider(endpoint, userAgent), @[], overwrite != 0,
      refreshCache != 0)
    emit($geocodePlanJson(plan), output))

proc um_geocode_apply(handle: pointer; provider, language, endpoint,
                      userAgent: cstring; overwrite, refreshCache: cint;
                      onProgress: ProgressFn; onCancel: CancelFn;
                      userData: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Plan and apply in one call, as organising does: the plan a caller
  ## confirmed is rebuilt here, so an item whose coordinates changed in between
  ## is named from what it holds now rather than from a stale plan.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if not geocodeArgumentsOk(provider, endpoint, refreshCache):
      return cint(umErrArg)
    let library = libraryOf(handle)
    let plan = planReverseGeocode(library.store, $provider,
      (if language == nil: "" else: $language),
      geocodeProvider(endpoint, userAgent), @[], overwrite != 0,
      refreshCache != 0)
    let report = applyReverseGeocode(library.store, plan,
      progressBridge(onProgress, userData), cancelBridge(onCancel, userData))
    emit($(%*{"applied": report.applied, "failed": report.failed}), output))

proc um_sync_manifest_json(handle: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What this library holds, as the manifest another copy is compared against.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($syncManifestJson(buildSyncManifest(libraryOf(handle).store)), output))

proc um_sync_available(available: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether the external transfer tool is installed. Its absence is reported
  ## rather than discovered halfway through a transfer.
  ensureRuntime()
  cint(guarded do:
    if available == nil:
      setError("available must not be null")
      return cint(umErrArg)
    available[] = cint(if rcloneAvailable(): 1 else: 0)
    umOk)

proc um_sync_plan_json(handle: pointer; remote: cstring; push: cint;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What synchronising against `remote` would move. `push` non-zero sends this
  ## library outwards; zero brings the remote in.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if remote == nil or ($remote).len == 0:
      setError("a remote must be named")
      return cint(umErrArg)
    let plan = planSync(libraryOf(handle).store, $remote,
      if push != 0: sdPush else: sdPull)
    emit($(%*{"id": plan.id, "provider": plan.provider, "remote": plan.remote,
      "direction": $plan.direction, "summary": plan.summary}), output))

proc um_sync_apply(handle: pointer; planId: cstring;
                   output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Carry out a plan made earlier, named by its identifier.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if planId == nil or ($planId).len == 0:
      setError("a plan id must be given")
      return cint(umErrArg)
    let report = applySync(libraryOf(handle).store, $planId)
    emit($(%*{"id": report.id, "summary": report.summary,
      "applied": report.applied}), output))

proc um_sync_runs_json(handle: pointer; planId: cstring; limit: cint;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What has been synchronised before, most recent first.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if limit <= 0:
      setError("limit must be positive")
      return cint(umErrArg)
    var runs = newJArray()
    for run in listSyncRuns(libraryOf(handle).store,
        (if planId == nil: "" else: $planId), int(limit)):
      runs.add %*{"id": run.id, "provider": run.provider, "remote": run.remote,
        "status": run.status, "direction": $run.direction,
        "dryRun": run.dryRun, "startedAt": run.startedAt,
        "finishedAt": run.finishedAt, "summary": run.summary}
    emit($runs, output))

proc um_vision_annotations_json(handle: pointer; itemId: int64;
                                output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What a model has said about an item, or about every item when `itemId`
  ## is 0.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var annotations = newJArray()
    for note in listVisionAnnotations(libraryOf(handle).store, itemId):
      var labels = newJArray()
      for label in note.labels: labels.add %label
      annotations.add %*{"itemId": note.itemId, "model": note.model,
        "caption": note.caption, "updatedAt": note.updatedAt, "labels": labels}
    emit($annotations, output))

proc um_vision_describe(handle: pointer; itemId: int64;
                        endpoint, model: cstring; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Ask a model at `endpoint` to describe one item, and keep what it says.
  ## The model runs outside this process; its absence is an error rather than
  ## a silent empty description.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if endpoint == nil or model == nil:
      setError("endpoint and model must not be null")
      return cint(umErrArg)
    let note = describeVisionItem(libraryOf(handle).store, itemId, $endpoint,
      $model)
    var labels = newJArray()
    for label in note.labels: labels.add %label
    emit($(%*{"itemId": note.itemId, "model": note.model,
      "caption": note.caption, "updatedAt": note.updatedAt,
      "labels": labels}), output))

proc um_vision_search_json(handle: pointer; endpoint, model, query: cstring;
                           limit: cint; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Find items whose description is closest in meaning to `query`, rather than
  ## items whose text contains it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if endpoint == nil or model == nil or query == nil:
      setError("endpoint, model and query must not be null")
      return cint(umErrArg)
    if limit <= 0:
      setError("limit must be positive")
      return cint(umErrArg)
    var hits = newJArray()
    for hit in semanticTextSearch(libraryOf(handle).store, $endpoint, $model,
        $query, int(limit)):
      var labels = newJArray()
      for label in hit.labels: labels.add %label
      hits.add %*{"itemId": hit.itemId, "path": hit.relPath,
        "caption": hit.caption, "score": hit.score, "labels": labels}
    emit($hits, output))

proc um_media_probe_json(path: cstring; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What a video file is: its size, the size it is shown at, its rotation,
  ## duration, codec and container. Read in process; no external program runs.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let info = probeMedia($path)
    emit($(%*{"width": info.width, "height": info.height,
      "displayWidth": info.displayWidth, "displayHeight": info.displayHeight,
      "rotation": info.rotation, "durationSeconds": info.durationSeconds,
      "codec": info.codec, "format": info.format}), output))

proc um_media_available(available: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether a frame can be decoded out of a video, which needs an external
  ## `ffmpeg`. Probing does not, so a machine without it still catalogues
  ## videos and only goes without their thumbnails.
  ensureRuntime()
  cint(guarded do:
    if available == nil:
      setError("available must not be null")
      return cint(umErrArg)
    available[] = cint(if externalMediaAvailable(): 1 else: 0)
    umOk)

proc um_audio_available(available: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether acoustic fingerprinting is available. Always true since it is
  ## linked in; kept so a caller written against the external tool still
  ## compiles and still gets a truthful answer.
  ensureRuntime()
  cint(guarded do:
    if available == nil:
      setError("available must not be null")
      return cint(umErrArg)
    available[] = cint(if audioFingerprintAvailable(): 1 else: 0)
    umOk)

# One item, one album, and the ways of finding them. The paged listing above
# answers "what is in this library"; these answer "this one", "the ones that
# match", and "where do the pictures cluster".

proc um_item_json(handle: pointer; itemId: int64; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## One item by identifier, in the same shape the listing uses.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($itemJson(getItem(libraryOf(handle).store, itemId)), output))

proc um_item_path(handle: pointer; itemId: int64; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Where an item is on disk, absolute. The listing reports a path relative to
  ## the library root, which a caller opening the file cannot use directly.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let item = getItem(library.store, itemId)
    emit(absoluteItemPath(library.store, item.relPath), output))

proc um_search_json(handle: pointer; query, kind: cstring;
                    limit, offset: cint; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Items whose text matches `query`. `kind` narrows to a category, or is null
  ## for all of them.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if query == nil or ($query).len == 0:
      setError("a query must not be empty")
      return cint(umErrArg)
    if limit <= 0 or offset < 0:
      setError("limit must be positive and offset must not be negative")
      return cint(umErrArg)
    var items = newJArray()
    for item in searchItems(libraryOf(handle).store, $query,
        (if kind == nil: "" else: $kind), int(limit), int(offset)):
      items.add itemJson(item)
    emit($items, output))

proc um_filter_json(handle: pointer; filter: cstring; limit, offset: cint;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Items matching a filter given as JSON: any of `text`, `kind`, `dateFrom`,
  ## `dateTo`, `location`, `keywords`, `minRating`, `maxRating`, `favorite`,
  ## `hasGps`. A field left out does not narrow anything, which is what makes
  ## an empty object mean "everything".
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if filter == nil:
      setError("filter must not be null")
      return cint(umErrArg)
    if limit <= 0 or offset < 0:
      setError("limit must be positive and offset must not be negative")
      return cint(umErrArg)
    let document = try: parseJson($filter)
      except CatchableError:
        setError("filter must be JSON")
        return cint(umErrArg)
    if document.kind != JObject:
      setError("filter must be a JSON object")
      return cint(umErrArg)
    var wanted: CatalogFilter
    proc textField(document: JsonNode; name: string): string =
      if document.hasKey(name): document[name].getStr() else: ""
    wanted.text = document.textField("text")
    wanted.kind = document.textField("kind")
    wanted.dateFrom = document.textField("dateFrom")
    wanted.dateTo = document.textField("dateTo")
    wanted.location = document.textField("location")
    if document.hasKey("keywords") and document["keywords"].kind == JArray:
      for keyword in document["keywords"]: wanted.keywords.add keyword.getStr()
    if document.hasKey("minRating"):
      wanted.minRating = some(document["minRating"].getInt())
    if document.hasKey("maxRating"):
      wanted.maxRating = some(document["maxRating"].getInt())
    if document.hasKey("favorite"):
      wanted.favorite = some(document["favorite"].getBool())
    if document.hasKey("hasGps"):
      wanted.hasGps = some(document["hasGps"].getBool())
    var items = newJArray()
    for item in filterItems(libraryOf(handle).store, wanted, int(limit),
        int(offset)):
      items.add itemJson(item)
    emit($items, output))

proc um_place_facets_json(handle: pointer; prefix: cstring; limit: cint;
                          output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Where the library's items are, grouped by place name, with how many carry
  ## coordinates. `prefix` narrows to names beginning with it.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if limit <= 0:
      setError("limit must be positive")
      return cint(umErrArg)
    var facets = newJArray()
    for facet in listPlaceFacets(libraryOf(handle).store,
        (if prefix == nil: "" else: $prefix), int(limit)):
      var entry = %*{"location": facet.location, "itemCount": facet.itemCount,
                     "gpsCount": facet.gpsCount}
      if facet.latitude.isSome: entry["latitude"] = %facet.latitude.get
      if facet.longitude.isSome: entry["longitude"] = %facet.longitude.get
      facets.add entry
    emit($facets, output))

proc um_item_meta_json(handle: pointer; itemId: int64;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The free-form metadata attached to an item, as the JSON it is stored as.
  ## Empty when nothing was attached.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let meta = itemMeta(libraryOf(handle).store, itemId)
    emit(if meta.len == 0: "{}" else: meta, output))

proc um_item_meta_set(handle: pointer; itemId: int64; meta: cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Replace an item's free-form metadata. The whole object is written, so a
  ## caller keeping a field must send it back.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if meta == nil:
      setError("meta must not be null")
      return cint(umErrArg)
    let document = try: parseJson($meta)
      except CatchableError:
        setError("meta must be JSON")
        return cint(umErrArg)
    if document.kind != JObject:
      setError("meta must be a JSON object")
      return cint(umErrArg)
    let library = libraryOf(handle)
    setItemMeta(library.store, itemId, document)
    umOk)

proc um_album_json(handle: pointer; albumId: int64;
                   output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## One album by identifier.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($albumJson(getAlbum(libraryOf(handle).store, albumId)), output))

proc um_smart_album_json(handle: pointer; albumId: int64;
                         output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## One smart album by identifier, with its rules.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    emit($smartAlbumJson(getSmartAlbum(libraryOf(handle).store, albumId)),
      output))

proc um_audio_fingerprint_json(path: cstring; maxSeconds: cint;
                               output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The acoustic fingerprint of an audio file, as its duration and the words
  ## taken from its samples. A container this build cannot decode is an error
  ## rather than an empty fingerprint.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    if maxSeconds <= 0:
      setError("maxSeconds must be positive")
      return cint(umErrArg)
    let print = audioFingerprint($path, int(maxSeconds))
    var raw = newJArray()
    for value in print.raw: raw.add %int64(value)
    emit($(%*{"durationSeconds": print.durationSeconds, "raw": raw}), output))

proc um_audio_similarity(first, second: cstring; score: ptr cdouble): cint
    {.exportc, dynlib, cdecl.} =
  ## How alike two fingerprints are, from 0 to 1. Each is the JSON
  ## `um_audio_fingerprint_json` returned, so a caller compares two files it
  ## fingerprinted at different times without keeping the engine's types.
  ensureRuntime()
  cint(guarded do:
    if first == nil or second == nil or score == nil:
      setError("both fingerprints and score must be non-null")
      return cint(umErrArg)
    proc fingerprintOf(text: cstring; into: var AudioFingerprint): bool =
      let document = try: parseJson($text)
        except CatchableError: return false
      if document.kind != JObject or not document.hasKey("raw") or
          document["raw"].kind != JArray: return false
      into.durationSeconds =
        if document.hasKey("durationSeconds"):
          document["durationSeconds"].getFloat()
        else: 0.0
      for value in document["raw"]: into.raw.add uint32(value.getBiggestInt())
      true
    var a, b: AudioFingerprint
    if not fingerprintOf(first, a) or not fingerprintOf(second, b):
      setError("a fingerprint is the JSON um_audio_fingerprint_json returns")
      return cint(umErrArg)
    score[] = cdouble(audioSimilarity(a, b))
    umOk)

proc um_scan_bounded(handle: pointer; skipPhash, jobs: cint;
                     onProgress: ProgressFn; onCancel: CancelFn;
                     userData: pointer; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## `um_scan` with a bound on how many files are hashed at once.
  ##
  ## Zero uses every core, which is what `um_scan` does and what a machine
  ## doing nothing else wants. A number leaves the rest of the machine usable
  ## while a large import runs, which matters because hashing a library is the
  ## longest thing this engine does.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if jobs < 0:
      setError("jobs must not be negative")
      return cint(umErrArg)
    let library = libraryOf(handle)
    let report = scanLibrary(library.store, skipPhash != 0,
      progressBridge(onProgress, userData), cancelBridge(onCancel, userData),
      int(jobs))
    emit($(%*{"indexed": report.indexed, "updated": report.updated,
      "removed": report.removed, "hashErrors": report.hashErrors}), output))

proc um_dedup_link_plan_json(handle: pointer; runId: int64;
                             output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Which duplicates could be replaced by a hard link to the copy kept, and
  ## which copy that is. Read-only.
  ##
  ## Byte-identical groups only: files a perceptual hash called alike are not
  ## the same file, and linking them would throw away whichever was not kept.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var pairs = newJArray()
    let library = libraryOf(handle)
    for pair in planDedupLinks(library.store, runId):
      pairs.add %*{"item": pair.itemId, "keeper": pair.keeperId}
    emit($pairs, output))

proc um_dedup_link(handle: pointer; runId: int64; output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Replace each byte-identical duplicate with a hard link to the copy kept:
  ## the space is freed and every path that pointed at it still opens.
  ##
  ## Journalled like a removal, and undone by the same `um_undo_apply`: the
  ## file goes to the trash first and the link is recorded after it, so undo
  ## takes the link away and puts the file back.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let report = applyDedupLinks(library.store, runId)
    emit($(%*{"batch": report.batchId, "linked": report.linked,
      "failed": report.failed}), output))

proc um_album_set_parent(handle: pointer; albumId, parentId: int64;
                         output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Move an album inside another, or to the top with a `parentId` of 0.
  ##
  ## A cycle is refused: an album cannot be its own ancestor, and neither can a
  ## chain of them close on itself.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    emit($albumJson(setAlbumParent(library.store, albumId, parentId)), output))

proc um_album_children_json(handle: pointer; parentId: int64;
                            output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The albums directly inside `parentId`, or those at the top when it is 0.
  ## One level, so a caller drawing a tree asks again for each branch it opens
  ## rather than being handed a whole library's worth it may never show.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var albums = newJArray()
    for album in listChildAlbums(libraryOf(handle).store, parentId):
      albums.add albumJson(album)
    emit($albums, output))


proc parseCleanupKinds(raw: cstring; kinds: var HashSet[CleanupKind]): bool =
  ## A JSON array of kind names, or NULL/[] for every kind.
  if raw == nil: return true
  let text = $raw
  if text.len == 0: return true
  let node = try: parseJson(text)
    except CatchableError:
      setError("cleanup kinds must be a JSON array")
      return false
  if node.kind != JArray:
    setError("cleanup kinds must be a JSON array")
    return false
  for element in node:
    if element.kind != JString:
      setError("each cleanup kind must be a string")
      return false
    var known = false
    for kind in CleanupKind:
      if $kind == element.getStr():
        kinds.incl kind
        known = true
    if not known:
      setError("unknown cleanup kind: " & element.getStr())
      return false
  true

proc um_cleanup_plan_json(handle: pointer; kinds: cstring;
                          output: ptr cstring): cint
                         {.exportc, dynlib, cdecl.} =
  ## What a cleanup would take away, taking nothing.
  ##
  ## An entry with "removable" false was found and is being reported, not
  ## proposed: an AppleDouble carrying a Finder tag is where that tag lives when
  ## the filesystem cannot hold it beside the file. "reason" says why, for both
  ## answers.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var wanted = initHashSet[CleanupKind]()
    if not parseCleanupKinds(kinds, wanted): return cint(umErrArg)
    var entries = newJArray()
    for entry in planCleanup(libraryOf(handle).store, wanted).entries:
      entries.add %*{"kind": $entry.kind, "path": entry.relPath,
        "size": entry.size, "removable": entry.removable,
        "reason": entry.reason}
    emit($(%*{"entries": entries}), output))

proc um_cleanup_apply(handle: pointer; kinds: cstring; permanently: cint;
                      onProgress: ProgressFn; userData: pointer;
                      output: ptr cstring): cint
                     {.exportc, dynlib, cdecl.} =
  ## Move what the plan marked removable into the journaled trash, so
  ## um_undo_apply brings it back. The plan is rebuilt here from the same kinds.
  ##
  ## An empty directory is removed rather than trashed: it held nothing for the
  ## trash to keep, and nothing an undo could lose.
  ##
  ## A non-zero `permanently` deletes instead of trashing. **Nothing comes back
  ## from that**, and "batch" is empty in the report because there is no batch:
  ## handing one back would read as a way that does not exist.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var wanted = initHashSet[CleanupKind]()
    if not parseCleanupKinds(kinds, wanted): return cint(umErrArg)
    let library = libraryOf(handle)
    var report: ApplyReport
    try:
      report = applyCleanup(library.store, planCleanup(library.store, wanted),
        progressBridge(onProgress, userData), permanently != 0)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($(%*{"batch": report.batchId, "removed": report.applied,
      "kept": report.skipped, "failed": report.failed}), output))


proc um_trash_list_json(handle: pointer; output: ptr cstring): cint
                       {.exportc, dynlib, cdecl.} =
  ## Every batch that put something in the trash, newest first.
  ##
  ## `undoable` needs both a batch that was applied and files still there to put
  ## back; either alone is not a way back. A batch whose directory is gone still
  ## appears with a count of zero, because the row is what explains its status.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var batches = newJArray()
    for batch in listTrash(libraryOf(handle).store):
      batches.add %*{"batch": batch.batchId, "when": batch.createdAt,
        "mode": batch.mode, "status": batch.status, "files": batch.fileCount,
        "bytes": batch.totalBytes, "undoable": batch.undoable}
    emit($(%*{"batches": batches}), output))

proc um_trash_empty(handle: pointer; batchIds: cstring; olderThanDays: cint;
                    onProgress: ProgressFn; userData: pointer;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Delete what those batches kept. **This is where recoverability ends.**
  ##
  ## `batchIds` is a JSON array; NULL or [] means every batch at least
  ## `olderThanDays` old, and zero days means all of them. Each batch is marked
  ## before its files go, so an interruption leaves one `um_undo_apply` refuses
  ## by name rather than one that fails on every path it cannot find.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    var names: seq[string]
    if batchIds != nil and ($batchIds).len > 0:
      let node = try: parseJson($batchIds)
        except CatchableError:
          setError("batchIds must be a JSON array")
          return cint(umErrArg)
      if node.kind != JArray:
        setError("batchIds must be a JSON array")
        return cint(umErrArg)
      for element in node:
        if element.kind != JString:
          setError("each batch id must be a string")
          return cint(umErrArg)
        names.add element.getStr()
    let library = libraryOf(handle)
    var report: TrashReport
    try:
      report = emptyTrash(library.store, names, int(olderThanDays),
        progressBridge(onProgress, userData))
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    emit($(%*{"batches": report.batches, "files": report.files,
      "freedBytes": report.freedBytes, "failed": report.failed}), output))

# --- file inspection, no library ------------------------------------------
#
# These answer from a path alone, so they take no handle: a caller deciding
# what to do with a file it has not imported yet needs them before any
# library exists.

proc domainOf(value: cint; into: var MediaDomain): bool =
  ## Map the C enum to a MediaDomain, refusing anything out of range rather
  ## than clamping it into a domain the caller did not ask for.
  if value < cint(low(MediaDomain).ord) or value > cint(high(MediaDomain).ord):
    setError("domain out of range")
    return false
  into = MediaDomain(value)
  true

proc um_category_for(domain: cint; path: cstring;
                     output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The category a file falls in for that domain, from its extension.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    var media: MediaDomain
    if not domainOf(domain, media): return cint(umErrArg)
    emit(categoryFor(media, $path), output))

proc um_filename_date(path: cstring;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The date the file name itself claims, or "" when it claims none.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    emit(parseFilenameDate($path), output))

proc um_media_coordinates(path: cstring;
                          output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Where the file says it was taken. `found` is false when it does not say,
  ## which is an ordinary state and not a failure.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let c = mediaCoordinates($path)
    emit($(%*{"latitude": c.latitude, "longitude": c.longitude,
      "found": c.found}), output))

proc um_media_date(path: cstring; filenameDate, birthtimeDate: cint;
                   output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The date to file this media under, and which source it came from. The
  ## two flags say whether the file name and the birth time may be fallen
  ## back on when the file carries no date of its own.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let d = mediaDate($path, filenameDate != 0, birthtimeDate != 0)
    emit($(%*{"value": d.value, "source": d.source}), output))

proc um_is_internal(root, path: cstring;
                    answer: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether the path is the library's own bookkeeping rather than media.
  ensureRuntime()
  cint(guarded do:
    if root == nil or path == nil or answer == nil:
      setError("root, path and answer must not be null")
      return cint(umErrArg)
    answer[] = cint(ord(isInternal($root, $path)))
    umOk)

proc um_apple_double_verdict(path: cstring;
                             output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Whether an AppleDouble sidecar may be removed, and the reason either way.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let v = appleDoubleVerdict($path)
    emit($(%*{"removable": v.removable, "reason": v.reason}), output))

proc um_can_write_date(rel_path: cstring;
                       answer: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether a date correction can reach this file, from its name alone.
  ensureRuntime()
  cint(guarded do:
    if rel_path == nil or answer == nil:
      setError("rel_path and answer must not be null")
      return cint(umErrArg)
    answer[] = cint(ord(canWriteDate($rel_path)))
    umOk)

proc um_can_strip(rel_path: cstring;
                  answer: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether stripping can rewrite this file, from its name alone.
  ensureRuntime()
  cint(guarded do:
    if rel_path == nil or answer == nil:
      setError("rel_path and answer must not be null")
      return cint(umErrArg)
    answer[] = cint(ord(canStrip($rel_path)))
    umOk)

proc um_checked_path_under(root, path: cstring;
                           output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The path resolved under the root, refused if it escapes it. This is the
  ## check every mutating call makes before touching a file, exposed so a
  ## caller can make it before asking.
  ensureRuntime()
  cint(guarded do:
    if root == nil or path == nil:
      setError("root and path must not be null")
      return cint(umErrArg)
    emit(checkedPathUnder($root, $path), output))

proc um_iso_now(output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The current UTC instant in the format every timestamp here is written in.
  ensureRuntime()
  cint(guarded do:
    emit(isoNow(), output))

proc um_new_batch_id(output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## A fresh batch identifier, the same kind the engine stamps its own
  ## mutations with.
  ensureRuntime()
  cint(guarded do:
    emit(newBatchId(), output))

# --- hashing and sync, no library -----------------------------------------

proc um_blake3_file(path: cstring; buffer_size: cint; onCancel: CancelFn;
                    userData: pointer;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The content digest of one file, as lowercase hex. A `buffer_size` of zero
  ## takes the engine's own; the cancel hook can stop a long read.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    if buffer_size < 0:
      setError("buffer_size must not be negative")
      return cint(umErrArg)
    let size = if buffer_size == 0: 1024 * 1024 else: int(buffer_size)
    emit(blake3File($path, size, cancelBridge(onCancel, userData)), output))

proc um_video_frame_hashes(path: cstring; samples: cint;
                           output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Perceptual hashes of frames sampled across a video, as a JSON array of
  ## decimal strings -- not numbers, because a 64-bit hash does not survive a
  ## JSON parser that reads every number as a double. Zero takes the engine's
  ## own sample count.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    if samples < 0:
      setError("samples must not be negative")
      return cint(umErrArg)
    let count = if samples == 0: VideoFrameSamples else: int(samples)
    var arr = newJArray()
    for h in videoFrameHashes($path, count): arr.add newJString($h)
    emit($arr, output))

proc um_perceptual_hash_file(path: cstring;
                             output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The perceptual hash of an image and the dimensions it was computed over:
  ## {hash, width, height}. The hash is a decimal string, for the same reason.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let info = perceptualHashInfoFile($path)
    emit($(%*{"hash": $info.hash, "width": info.width,
      "height": info.height}), output))

proc um_parse_sync_manifest(data: cstring;
                            output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Read a sync manifest and hand back what it holds, so a caller can check a
  ## manifest before acting on it: {schemaVersion, entries:[{path, digest,
  ## size, mtimeNs}]}.
  ensureRuntime()
  cint(guarded do:
    if data == nil:
      setError("data must not be null")
      return cint(umErrArg)
    var manifest: SyncManifest
    try:
      manifest = parseSyncManifest($data)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    var entries = newJArray()
    for e in manifest.entries:
      entries.add %*{"path": e.path, "digest": e.digest, "size": e.size,
        "mtimeNs": e.mtimeNs}
    emit($(%*{"schemaVersion": manifest.schemaVersion,
      "entries": entries}), output))

proc um_diff_sync_manifests(local, remote: cstring;
                            output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What separates two manifests: {onlyLocal, onlyRemote, changed}, each a
  ## list of paths. Both arguments are manifests as text, the same shape
  ## `um_parse_sync_manifest` reads.
  ensureRuntime()
  cint(guarded do:
    if local == nil or remote == nil:
      setError("local and remote must not be null")
      return cint(umErrArg)
    var a, b: SyncManifest
    try:
      a = parseSyncManifest($local)
      b = parseSyncManifest($remote)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    let diff = diffSyncManifests(a, b)
    emit($(%*{"onlyLocal": diff.onlyLocal, "onlyRemote": diff.onlyRemote,
      "changed": diff.changed}), output))

# --- library-backed methods ------------------------------------------------

proc um_reindex_paths(handle: pointer; paths_json: cstring; skip_phash: cint;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Re-read a named set of paths rather than the whole library, for a caller
  ## that already knows what changed. `paths_json` is a JSON array of paths
  ## relative to the library root.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if paths_json == nil:
      setError("paths_json must not be null")
      return cint(umErrArg)
    var wanted: seq[string]
    let parsed = try: parseJson($paths_json)
      except CatchableError:
        setError("paths_json is not valid JSON")
        return cint(umErrArg)
    if parsed.kind != JArray:
      setError("paths_json must be an array")
      return cint(umErrArg)
    for element in parsed:
      if element.kind != JString:
        setError("every path must be a string")
        return cint(umErrArg)
      wanted.add element.getStr()
    let library = libraryOf(handle)
    let report = reindexPaths(library.store, wanted, skip_phash != 0)
    emit($(%*{"indexed": report.indexed, "updated": report.updated,
      "removed": report.removed, "hashErrors": report.hashErrors}), output))

proc um_add_virtual_item(handle: pointer; name, category, meta_json: cstring;
                         item_id: ptr int64): cint {.exportc, dynlib, cdecl.} =
  ## Add an item with no file of its own -- a record for something the library
  ## describes but does not hold. `meta_json` may be null.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if name == nil or category == nil or item_id == nil:
      setError("name, category and item_id must not be null")
      return cint(umErrArg)
    var meta: JsonNode = nil
    if meta_json != nil:
      meta = try: parseJson($meta_json)
        except CatchableError:
          setError("meta_json is not valid JSON")
          return cint(umErrArg)
      if meta.kind != JObject:
        setError("meta_json must be an object")
        return cint(umErrArg)
    let library = libraryOf(handle)
    item_id[] = addVirtualItem(library.store, $name, $category, meta)
    umOk)

proc um_validate_curation_patch(patch: cstring): cint {.exportc, dynlib, cdecl.} =
  ## Whether a patch is self-consistent, without opening a library or writing
  ## anything -- the check a caller makes before offering to apply it.
  ensureRuntime()
  cint(guarded do:
    if patch == nil:
      setError("patch must not be null")
      return cint(umErrArg)
    var edit: CurationPatch
    if not patchFromJson(patch, edit):
      return cint(umErrArg)
    try:
      validateCurationPatch(edit)
    except ValueError:
      setError(getCurrentExceptionMsg())
      return cint(umErrArg)
    umOk)

proc um_recover(handle: pointer): cint {.exportc, dynlib, cdecl.} =
  ## Finish or roll back whatever a previous run left half-done: interrupted
  ## organize batches and curation writes both. Safe to call on a library that
  ## was closed cleanly, where it does nothing.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    recoverInterruptedBatches(library.store)
    recoverCurationOps(library.store)
    umOk)

proc um_dedup_removal_plan(handle: pointer; run_id: int64;
                           output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What a dedup removal would take, without taking it: the members of every
  ## group that are not the keeper. Zero means the most recent run.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    var members = newJArray()
    for member in planDedupRemoval(library.store, run_id):
      members.add %*{"itemId": member.itemId, "relPath": member.relPath,
        "similarity": member.similarity, "isKeeper": member.isKeeper}
    emit($members, output))

proc um_hardlinks_supported(root: cstring;
                            answer: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## Whether this filesystem has hard links, asked before anything moves. A
  ## network share often does not, and finding out afterwards is worse.
  ensureRuntime()
  cint(guarded do:
    if root == nil or answer == nil:
      setError("root and answer must not be null")
      return cint(umErrArg)
    try:
      requireHardlinkSupport($root)
      answer[] = 1
    except CatchableError:
      # The refusal is the answer here, not a failure: a caller asked whether
      # it could, and the reason stays in um_last_error for one that wants it.
      setError(getCurrentExceptionMsg())
      answer[] = 0
    umOk)

proc um_link_duplicates(handle: pointer; pairs_json: cstring;
                        output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Replace named duplicates by a hard link to the copy kept. `pairs_json` is
  ## a JSON array of `{"itemId":N,"keeperId":M}`. Where `um_dedup_link` takes a
  ## whole dedup run, this takes the pairs a caller chose itself.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if pairs_json == nil:
      setError("pairs_json must not be null")
      return cint(umErrArg)
    let parsed = try: parseJson($pairs_json)
      except CatchableError:
        setError("pairs_json is not valid JSON")
        return cint(umErrArg)
    if parsed.kind != JArray:
      setError("pairs_json must be an array")
      return cint(umErrArg)
    var pairs: seq[tuple[itemId, keeperId: int64]]
    for element in parsed:
      if element.kind != JObject or not element.hasKey("itemId") or
          not element.hasKey("keeperId"):
        setError("every pair needs itemId and keeperId")
        return cint(umErrArg)
      pairs.add (element["itemId"].getBiggestInt,
                 element["keeperId"].getBiggestInt)
    let library = libraryOf(handle)
    let report = linkDuplicates(library.store, pairs)
    emit($(%*{"batchId": report.batchId, "applied": report.applied,
      "skipped": report.skipped, "failed": report.failed,
      "linked": report.linked}), output))

proc um_trash_plan(handle: pointer; batches_json: cstring;
                   older_than_days: cint;
                   output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What emptying the trash would remove, without removing it. A null or
  ## empty `batches_json` means every batch.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if older_than_days < 0:
      setError("older_than_days must not be negative")
      return cint(umErrArg)
    var names: seq[string]
    if batches_json != nil and ($batches_json).len > 0:
      let parsed = try: parseJson($batches_json)
        except CatchableError:
          setError("batches_json is not valid JSON")
          return cint(umErrArg)
      if parsed.kind != JArray:
        setError("batches_json must be an array")
        return cint(umErrArg)
      for element in parsed:
        if element.kind != JString:
          setError("every batch id must be a string")
          return cint(umErrArg)
        names.add element.getStr()
    let library = libraryOf(handle)
    var batches = newJArray()
    for batch in planEmptyTrash(library.store, names, int(older_than_days)):
      batches.add %*{"batchId": batch.batchId, "createdAt": batch.createdAt,
        "mode": batch.mode, "status": batch.status,
        "fileCount": batch.fileCount, "totalBytes": batch.totalBytes,
        "undoable": batch.undoable}
    emit($batches, output))

proc um_trash_holding(handle: pointer;
                      output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What the whole trash occupies: {files, bytes}. One number for a screen
  ## that wants one number.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let holding = trashHolding(libraryOf(handle).store)
    emit($(%*{"files": holding.files, "bytes": holding.bytes}), output))

# --- media inspection and the rest of the domain ---------------------------

proc fingerprintOfJson(text: cstring; into: var AudioFingerprint): bool =
  ## One fingerprint out of the JSON `um_audio_fingerprint_json` hands back.
  let document = try: parseJson($text)
    except CatchableError: return false
  if document.kind != JObject or not document.hasKey("raw") or
      document["raw"].kind != JArray: return false
  into.durationSeconds =
    if document.hasKey("durationSeconds"): document["durationSeconds"].getFloat()
    else: 0.0
  for value in document["raw"]: into.raw.add uint32(value.getBiggestInt())
  true

proc um_audio_offset_similarity(first, second: cstring; max_shift: cint;
                                score: ptr cdouble): cint
    {.exportc, dynlib, cdecl.} =
  ## `um_audio_similarity` allowing one recording to start later than the
  ## other, which is what two rips of the same track usually differ by. The
  ## shift is bounded so the comparison stays a fixed cost.
  ensureRuntime()
  cint(guarded do:
    if first == nil or second == nil or score == nil:
      setError("both fingerprints and score must be non-null")
      return cint(umErrArg)
    if max_shift < 0:
      setError("max_shift must not be negative")
      return cint(umErrArg)
    var a, b: AudioFingerprint
    if not fingerprintOfJson(first, a) or not fingerprintOfJson(second, b):
      setError("a fingerprint is the JSON um_audio_fingerprint_json returns")
      return cint(umErrArg)
    let shift = if max_shift == 0: 64 else: int(max_shift)
    score[] = cdouble(audioOffsetSimilarity(a, b, shift))
    umOk)

proc um_probe_sound(path: cstring;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What an audio file is, from its header, with whatever tags it carries.
  ## `durationSeconds` is absent where the container does not state it.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let sound = probeSound($path)
    var payload = %*{"container": sound.container, "codec": sound.codec,
      "sampleRate": sound.sampleRate, "channels": sound.channels}
    if sound.durationKnown:
      payload["durationSeconds"] = %sound.durationSeconds
    for pair in [("title", sound.tags.title), ("artist", sound.tags.artist),
        ("album", sound.tags.album), ("albumArtist", sound.tags.albumArtist),
        ("composer", sound.tags.composer), ("genre", sound.tags.genre),
        ("date", sound.tags.date)]:
      if pair[1].len > 0: payload[pair[0]] = %pair[1]
    if sound.tags.trackNumber > 0:
      payload["trackNumber"] = %sound.tags.trackNumber
    if sound.tags.discNumber > 0:
      payload["discNumber"] = %sound.tags.discNumber
    emit($payload, output))

proc um_probe_still(path: cstring;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What a still image is: its size and the container it sits in. A
  ## photograph has no `moov` box, so `um_probe` cannot answer for one.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    let still = probeStill($path)
    emit($(%*{"width": still.width, "height": still.height,
      "format": still.format, "codec": still.codec}), output))

proc um_decode_frame(path: cstring; max_edge: cint; seek_seconds: cdouble;
                     pixels: ptr ptr uint8; length: ptr csize_t;
                     width, height: ptr cint): cint {.exportc, dynlib, cdecl.} =
  ## One frame as RGBA bytes, scaled so neither edge passes `max_edge`. The
  ## buffer is the library's to allocate and the caller's to release with
  ## `um_buffer_free`; `length` is `width * height * 4`.
  ensureRuntime()
  cint(guarded do:
    if path == nil or pixels == nil or length == nil or width == nil or
        height == nil:
      setError("path and every output must be non-null")
      return cint(umErrArg)
    # Cleared before anything can fail, so a caller that trusted the header's
    # promise does not read whatever it left in them.
    pixels[] = nil
    length[] = 0
    width[] = 0
    height[] = 0
    if max_edge <= 0:
      setError("max_edge must be positive")
      return cint(umErrArg)
    let frame = decodeMediaFrame($path, int(max_edge), float(seek_seconds))
    let bytes = frame.data.len
    if bytes <= 0:
      setError("the decoder produced no pixels")
      return cint(umErrRuntime)
    let buffer = cast[ptr UncheckedArray[uint8]](alloc(bytes))
    for index in 0 ..< bytes: buffer[index] = frame.data[index]
    pixels[] = cast[ptr uint8](buffer)
    length[] = csize_t(bytes)
    width[] = cint(frame.width)
    height[] = cint(frame.height)
    umOk)

proc um_parse_gpx(path: cstring;
                  output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The track points a GPX file holds, so a caller can check a track before
  ## matching a library against it.
  ensureRuntime()
  cint(guarded do:
    if path == nil:
      setError("path must not be null")
      return cint(umErrArg)
    var points = newJArray()
    for point in parseGpx($path):
      var entry = %*{"timestamp": point.timestamp,
        "latitude": point.latitude, "longitude": point.longitude}
      if point.elevation.isSome: entry["elevation"] = %point.elevation.get
      points.add entry
    emit($points, output))

proc um_detect_faces(handle: pointer; item_id: int64; backend: cstring;
                     output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## Run the detector over one item and report what it found, without storing
  ## it. `backend` is the executable to run; null takes the default.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    let library = libraryOf(handle)
    let tool = if backend == nil: "" else: $backend
    var faces = newJArray()
    for face in detectFaces(library.store, item_id, tool):
      faces.add %*{"id": face.id, "itemId": face.itemId,
        "personId": face.personId, "x": face.x, "y": face.y,
        "width": face.width, "height": face.height,
        "confidence": face.confidence, "detector": face.detector,
        "detectedAt": face.detectedAt, "signatureValid": face.signatureValid}
    emit($faces, output))

proc um_replace_faces(handle: pointer; item_id: int64;
                      faces_json: cstring): cint {.exportc, dynlib, cdecl.} =
  ## Replace every face recorded against one item. The whole set is written,
  ## so a caller keeping one must send it back.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if faces_json == nil:
      setError("faces_json must not be null")
      return cint(umErrArg)
    let parsed = try: parseJson($faces_json)
      except CatchableError:
        setError("faces_json is not valid JSON")
        return cint(umErrArg)
    if parsed.kind != JArray:
      setError("faces_json must be an array")
      return cint(umErrArg)
    var detections: seq[FaceDetection]
    for element in parsed:
      if element.kind != JObject:
        setError("every face must be an object")
        return cint(umErrArg)
      var one = FaceDetection(x: element{"x"}.getFloat(),
        y: element{"y"}.getFloat(), width: element{"width"}.getFloat(),
        height: element{"height"}.getFloat(),
        confidence: element{"confidence"}.getFloat(),
        detector: element{"detector"}.getStr())
      if element.hasKey("signature"):
        one.signature = uint64(element["signature"].getBiggestInt())
        one.signatureValid = true
      detections.add one
    let library = libraryOf(handle)
    replaceFaces(library.store, item_id, detections)
    umOk)

proc configJson(config: LibraryConfig): JsonNode =
  ## One shape for a library's settings, whether read from a root or asked of
  ## the defaults.
  %*{"schemaVersion": config.schemaVersion, "domain": $config.domain,
    "scheme": $config.scheme, "filenameDate": config.filenameDate,
    "birthtimeDate": config.birthtimeDate, "noDateDir": config.noDateDir,
    "onConflict": $config.onConflict}

proc um_read_config(root: cstring;
                    output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## The settings a library root holds, read without opening it.
  ensureRuntime()
  cint(guarded do:
    if root == nil:
      setError("root must not be null")
      return cint(umErrArg)
    emit($configJson(readConfig($root)), output))

proc um_default_config(domain: cint;
                       output: ptr cstring): cint {.exportc, dynlib, cdecl.} =
  ## What `um_library_init` would write for that domain, so a caller can show
  ## the defaults before creating anything.
  ensureRuntime()
  cint(guarded do:
    var media: MediaDomain
    if not domainOf(domain, media): return cint(umErrArg)
    emit($configJson(defaultLibraryConfig(media)), output))

# --- vision primitives -----------------------------------------------------
#
# The higher-level calls above drive a whole flow: describe an item, index it,
# search. These are the pieces they are built from, for a caller running its
# own model rather than the one this library knows how to talk to.

proc vectorOfJson(text: cstring; into: var seq[float]): bool =
  ## A JSON array of numbers into an embedding.
  let document = try: parseJson($text)
    except CatchableError: return false
  if document.kind != JArray: return false
  for value in document:
    if value.kind notin {JInt, JFloat}: return false
    into.add value.getFloat()
  true

proc stringsOfJson(text: cstring; into: var seq[string]): bool =
  ## A JSON array of strings, or nothing at all when the pointer is null.
  if text == nil: return true
  let document = try: parseJson($text)
    except CatchableError: return false
  if document.kind != JArray: return false
  for value in document:
    if value.kind != JString: return false
    into.add value.getStr()
  true

proc um_vision_store_document(handle: pointer; item_id: int64;
                              model, caption, labels_json,
                              embedding_json: cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Record one item's embedding under a model, with the caption and labels
  ## that go with it. For a caller that ran its own model and has a vector.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if model == nil or caption == nil or embedding_json == nil:
      setError("model, caption and embedding_json must not be null")
      return cint(umErrArg)
    var vector: seq[float]
    if not vectorOfJson(embedding_json, vector):
      setError("embedding_json must be an array of numbers")
      return cint(umErrArg)
    var labels: seq[string]
    if not stringsOfJson(labels_json, labels):
      setError("labels_json must be an array of strings")
      return cint(umErrArg)
    let library = libraryOf(handle)
    storeVisionDocument(library.store, item_id, $model, $caption, labels,
      vector)
    umOk)

proc um_vision_store_annotation(handle: pointer; item_id: int64;
                                model, caption, labels_json: cstring;
                                output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Record a caption and labels without an embedding -- a description that
  ## did not come from a model this library can search over.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if model == nil or caption == nil:
      setError("model and caption must not be null")
      return cint(umErrArg)
    var labels: seq[string]
    if not stringsOfJson(labels_json, labels):
      setError("labels_json must be an array of strings")
      return cint(umErrArg)
    let library = libraryOf(handle)
    let stored = storeVisionAnnotation(library.store, item_id, $model,
      $caption, labels)
    emit($(%*{"itemId": stored.itemId, "model": stored.model,
      "caption": stored.caption, "labels": stored.labels,
      "updatedAt": stored.updatedAt}), output))

proc um_vision_semantic_search(handle: pointer; model, query_json: cstring;
                               limit: cint;
                               output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Nearest items to a vector the caller already has, rather than to text
  ## this library would have to embed first.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if model == nil or query_json == nil:
      setError("model and query_json must not be null")
      return cint(umErrArg)
    if limit < 0:
      setError("limit must not be negative")
      return cint(umErrArg)
    var vector: seq[float]
    if not vectorOfJson(query_json, vector):
      setError("query_json must be an array of numbers")
      return cint(umErrArg)
    let library = libraryOf(handle)
    let count = if limit == 0: 50 else: int(limit)
    var hits = newJArray()
    for hit in semanticSearch(library.store, $model, vector, count):
      hits.add %*{"itemId": hit.itemId, "relPath": hit.relPath,
        "caption": hit.caption, "labels": hit.labels, "score": hit.score}
    emit($hits, output))

proc um_vision_index_text(handle: pointer; item_id: int64;
                          endpoint, model, text, caption,
                          labels_json: cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Embed a piece of text through the endpoint and store it against an item,
  ## in one call. The network reach is the caller's to allow.
  ensureRuntime()
  cint(guarded do:
    if not known(handle):
      setError("unknown library handle")
      return cint(umErrHandle)
    if endpoint == nil or model == nil or text == nil or caption == nil:
      setError("endpoint, model, text and caption must not be null")
      return cint(umErrArg)
    var labels: seq[string]
    if not stringsOfJson(labels_json, labels):
      setError("labels_json must be an array of strings")
      return cint(umErrArg)
    let library = libraryOf(handle)
    indexVisionText(library.store, item_id, $endpoint, $model, $text,
      $caption, labels)
    umOk)

proc um_vision_embedding(endpoint, model, input: cstring; timeout_ms: cint;
                         output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The embedding an endpoint returns for a string, as a JSON array. No
  ## library is involved: this is the model call on its own.
  ensureRuntime()
  cint(guarded do:
    if endpoint == nil or model == nil or input == nil:
      setError("endpoint, model and input must not be null")
      return cint(umErrArg)
    if timeout_ms < 0:
      setError("timeout_ms must not be negative")
      return cint(umErrArg)
    let wait = if timeout_ms == 0: 30_000 else: int(timeout_ms)
    var vector = newJArray()
    for value in ollamaEmbedding($endpoint, $model, $input, wait):
      vector.add %value
    emit($vector, output))

proc um_vision_describe_file(endpoint, model, image_path: cstring;
                             timeout_ms: cint;
                             output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## What a vision model says about one image file: {caption, labels}. Takes a
  ## path rather than an item, so it answers for a file not in any library.
  ensureRuntime()
  cint(guarded do:
    if endpoint == nil or model == nil or image_path == nil:
      setError("endpoint, model and image_path must not be null")
      return cint(umErrArg)
    if timeout_ms < 0:
      setError("timeout_ms must not be negative")
      return cint(umErrArg)
    let wait = if timeout_ms == 0: 60_000 else: int(timeout_ms)
    let described = ollamaDescribe($endpoint, $model, $image_path, wait)
    emit($(%*{"caption": described.caption, "labels": described.labels}),
      output))

proc um_vision_parse_description(raw: cstring;
                                 output: ptr cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## The caption and labels out of a model's raw reply, for a caller that
  ## called the model itself and holds the response.
  ensureRuntime()
  cint(guarded do:
    if raw == nil:
      setError("raw must not be null")
      return cint(umErrArg)
    let parsed = parseOllamaDescription($raw)
    emit($(%*{"caption": parsed.caption, "labels": parsed.labels}), output))


