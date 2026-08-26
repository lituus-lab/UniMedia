# The C ABI

Ninety-two entry points in `include/UniMedia.h`, linked as
`libUniMedia.a` or `libUniMedia.dylib`. The Python module and the Swift package
both rest on this; nothing reaches the engine another way.

## The shape every call takes

```c
um_library lib = NULL;
if (um_library_open("/Users/me/Pictures/Library", &lib) != UM_OK) {
    fprintf(stderr, "%s\n", um_last_error());
    return 1;
}

char *json = NULL;
if (um_cleanup_plan_json(lib, NULL, &json) == UM_OK) {
    puts(json);
    um_buffer_free(json);
}
um_library_close(lib);
```

Four rules hold throughout.

**An opaque handle.** `um_library` is a pointer you never dereference. The
schema does not cross the boundary, so a caller cannot come to depend on a
column that later moves.

**No exception ever crosses.** Every entry point returns a status; the reason
sits in `um_last_error()` until the next call on that thread.

**Reports are JSON, and the caller frees them.** Every `char **out_json` is
yours to `um_buffer_free`. The buffer is valid until you free it, not until the
next call.

**Out-of-range input is refused, never clamped.** A tolerance of −1 is
`UM_ERR_ARG`, not a silently corrected 0. A caller that passes nonsense learns
so rather than getting a plausible answer to a different question.

## Status codes

| Code | Meaning |
|---|---|
| `UM_OK` | Done |
| `UM_ERR_ARG` | An argument was refused |
| `UM_ERR_HANDLE` | The handle is not one this library issued |
| `UM_ERR_IO` | The filesystem said no |
| `UM_ERR_RUNTIME` | Anything else, with the reason in `um_last_error()` |

## Versioning

`um_abi_version()` returns an integer that rises whenever an entry point is
added **or its signature changes**. `UNIMEDIA_ABI_VERSION` in the header is the
value that header describes. Comparing them is how a consumer detects a library
that has moved:

```c
assert(um_abi_version() == UNIMEDIA_ABI_VERSION);
```

`tests/c/test_abi.c` makes exactly that assertion, which is what catches a stale
static library before anything subtler does.

## Progress and cancellation

Long operations take a `um_progress_fn` and, where cancelling is safe, a
`um_cancel_fn`, plus a `void *user_data` handed back to both.

```c
static void on_progress(const char *phase, int current, int total,
                        const char *message, void *user_data) {
    fprintf(stderr, "%s %d/%d %s\n", phase, current, total, message);
}
```

A cancel returning non-zero stops the run at the next safe point. Journalled
operations do not take one at all: an interrupted batch is reconciled by the
next call, and cancelling one halfway would be a state to reconcile rather than
a stop.

## Threads

One handle, one thread. The engine is not internally synchronised, and the last
error is per-thread. Open a handle per thread, or serialise the calls.

## Building against it

```bash
cd UniMedia && nimble clibStatic
cc -std=c11 -Iinclude yours.c build/libUniMedia.a -lsqlite3 \
   -framework Security -framework ImageIO -framework CoreFoundation \
   -framework CoreGraphics -o yours
```

The frameworks are named at the link site deliberately. A `passL` inside a Nim
dependency does not travel into a static archive, so a consumer that omits them
gets undefined symbols from the HEIC backend rather than a clear failure.
