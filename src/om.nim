# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

import std/os
import UniMedia/types
import UniMedia/cli

when isMainModule:
  # Ctrl-C asks the running operation to stop at its next cooperative boundary
  # instead of killing the process mid-mutation. A wrapping GUI sends SIGINT to
  # get the same behaviour.
  setControlCHook(proc () {.noconv.} = requestCancel())
  try:
    var args: seq[string]
    for index in 1..paramCount(): args.add paramStr(index)
    quit(runCli(args))
  except OperationCancelledError:
    # 4, not the shell's 130: on POSIX Nim types the exit code as int8, so quit
    # clamps anything above 127 down to 127 -- which reads as "command not
    # found". Codes 0-3 are already taken by success, error, usage and partial
    # failure.
    stderr.writeLine("om: cancelled")
    quit(4)
  except ValueError as error:
    stderr.writeLine("om: " & error.msg)
    quit(2)
  except CatchableError as error:
    stderr.writeLine("om: " & error.msg)
    quit(1)
