#!/usr/bin/env python3
"""Start a command in a session of its OWN, then become it.

macOS ships NO `setsid(1)`. MEASURED consequence (S240 fix round 4, D3): the
`nohup` fallback in `file_logs_for` left the detached resolve chain in the
LOOK's process group, so `xo-resolve.pid` recorded the look's group — killing
that group would have killed the look, and the one kill the product was
willing to make reached the driver but not its worker, which stayed alive with
nothing watching it.

`os.setsid()` is the same syscall `setsid(1)` makes, and python3 is on every
machine this runs on. `execvp` keeps the pid, so the pid the parent captured
with `$!` is still the command's pid AFTER the new session exists — which is
what makes the recorded pgid a group the chain genuinely leads.

A failing setsid() is NOT a reason not to run: the command still starts, in
the group it inherited, and `xo_write_pidfile` then records NO pgid rather
than a borrowed one.
"""
import os
import sys

if len(sys.argv) < 2:
    sys.stderr.write("usage: setsid.py <command> [args...]\n")
    raise SystemExit(2)

try:
    os.setsid()
except OSError:
    # Already a session/group leader, or the kernel refused. Carry on.
    pass

os.execvp(sys.argv[1], sys.argv[1:])
