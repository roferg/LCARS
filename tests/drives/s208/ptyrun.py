#!/usr/bin/env python3
"""ptyrun.py CMD [ARGS...] — run CMD with a REAL pty as its stdin/stdout/stderr.

The child's stdin is a pty slave that is OPEN and never reaches EOF: nothing is
ever written to the master and the master is never closed while the child lives.
That is the honest condition — it is how a human at a terminal runs a suite, and
it is the ONE condition under which the inherited-stdin hang class is visible.
A `</dev/null` run is the accident that hides the bug and proves nothing.

Note pty.fork() puts the child in its OWN session, so a process-group cage around
THIS process cannot reach it. When this process dies the master fd closes, the
pty hangs up, and the kernel SIGHUPs the child's foreground group — which is why
the caller should still confirm no orphan survives.

Exits with the child's exit code (128+N if signalled).
"""
import os
import pty
import sys

if len(sys.argv) < 2:
    sys.stderr.write("usage: ptyrun.py CMD [ARGS...]\n")
    sys.exit(2)

pid, master = pty.fork()
if pid == 0:
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError as exc:
        sys.stderr.write("ptyrun: exec failed: %s\n" % exc)
        os._exit(127)

sys.stderr.write("PTYRUN_CHILD_PID %d\n" % pid)
sys.stderr.flush()
out = []
while True:
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    out.append(data)
sys.stdout.write(b"".join(out).decode("utf-8", "replace"))
sys.stdout.flush()
_, status = os.waitpid(pid, 0)
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
