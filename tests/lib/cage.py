"""cage.py TIMEOUT cmd...  -> own process group, SIGKILL the whole group on timeout.

The harness's only safety device: every unattended suite is run through it.
CLAUDE.md's rule for anything unattended, because there is no portable
`timeout(1)` on macOS.

Output contract, depended on by tests/harness.test.sh: the FIRST line is always
    ELAPSED <n>s EXIT <code>
or
    ELAPSED <n>s *** TIMED OUT — exceeded the <d>s deadline (group killed). ...
and the caged process's own output follows it.

EXIT-STATUS CONTRACT (S289). The cage exits WHAT THE CAGED PROCESS DID, so
`cage … && <next step>` can be trusted:
    the child exited N          -> the cage exits N          (N == 0 on a pass)
    the child was killed by sig -> the cage exits 128+sig, the shell's own
                                   convention (the line still prints EXIT -sig)
    the child outran the deadline -> the cage exits 124, timeout(1)'s
                                   convention, so "the suite FAILED" and "the
                                   suite outran its budget" are distinguishable
                                   by a caller and not only by a reader. A child
                                   that exits 124 on its own is still told apart
                                   by the first line (EXIT 124, no TIMED OUT).
    the cage itself was signalled -> 128+sig, unchanged (see _on_signal)
    a usage error               -> unchanged (python's own traceback, exit 1)
Only the PROCESS STATUS changes: the first line above remains the contract,
byte for byte, and several readers parse it with `sed -n 1p`.

IT USED TO EXIT 0 ON EVERY PATH, and said nothing about it. It printed `EXIT 7`
and then told its caller 0, so a red suite read as a pass to anything keyed on
the status. Unattended is exactly where nobody reads the printed line, so an
overnight chain structurally could not see a red suite; it nearly fooled the
2026-10-11 orchestrator, which took a background job's exit 0 for the verdict.
The silence of this docstring on the point is what made the defect invisible,
which is why the contract above is now stated and pinned (harness.test.sh 6f).

AN INSTRUMENT MUST NOT STATE A CONCLUSION IT CANNOT SUPPORT (S244). The timeout
line used to read `*** TIMED OUT -> HUNG ***`. It said HUNG; it only ever knew
TIMED OUT. From where the cage stands, "hung", "slow", "waiting on a lock" and
"legitimately long" are indistinguishable — the single fact it observed is that
the child outlived the deadline. That inference was expensive: lcars-xo-observe
(240.6s, 182 passed) and lcars-xo-render-gate (441.7s, 38 passed) were measured
under a 150s cage, the cage ASSERTED "HUNG", the orchestrator believed the
instrument, and all shipping was recorded as blocked on hangs that do not exist.
The line now reports the measurement, names the deadline it exceeded (so a bad
budget reads as a bad budget), and says plainly that the cage cannot tell slow
from stuck — the answer to that is in the child's own output, which defect 1
below now preserves.

TWO DEFECTS FIXED AT S244. Both are why "the full suite is the merge gate and
nobody has ever completed a run" stayed a mystery.

1. IT DESTROYED THE EVIDENCE. The old version buffered the child's output inside
   `communicate(timeout=...)` and printed it only on the CLEAN path. On a
   timeout, `TimeoutExpired` was raised and every buffered byte was dropped, so
   the one run that most needed a diagnosis produced none — you could not see
   WHICH assertion it stopped after, and that is the only fact separating a HANG
   from a merely SLOW suite. Three suites were filed as hung on that evidence
   and all three were simply long. The pipe is now drained by a reader thread
   into a buffer that survives the timeout, so a timed-out cage still prints
   everything the child managed to say.

2. IT ORPHANED ITS CHILD WHEN IT WAS ITSELF KILLED. `start_new_session=True` is
   deliberate — it is what lets the timeout path killpg the whole tree — but it
   also puts the child in a session NOTHING ELSE KNOWS ABOUT. With no signal
   handler, a cage killed before its own timeout died without reaping, and the
   caged suite ran on for ever: ppid 1, its own process group, invisible to any
   group kill aimed at the launcher. 26 such strays were reaped by hand, the
   oldest 28 hours old. A cage that leaks the thing it was caging is not a cage.
   SIGTERM/SIGINT/SIGHUP are now caught and reap the group first.

RESIDUAL, stated honestly: a SIGKILL of cage.py itself cannot be caught by
anything, so it still orphans. Nothing in userspace can defend against that;
send a cage SIGTERM, not SIGKILL.
"""
import os, signal, subprocess, sys, threading, time

to = float(sys.argv[1]); cmd = sys.argv[2:]
t0 = time.time()
p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, start_new_session=True,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

# THE EVIDENCE SURVIVES THE TIMEOUT (defect 1). A reader thread drains the pipe
# into `chunks`, so whatever the child said is still in hand on every exit path
# — timeout and signal included — instead of dying inside communicate().
chunks = []


def _drain():
    try:
        for block in iter(lambda: p.stdout.read(4096), b""):
            chunks.append(block)
    except Exception:
        pass


reader = threading.Thread(target=_drain, daemon=True)
reader.start()


def _reap():
    """SIGKILL the caged process's whole group. Safe to call more than once."""
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def _report(first_line):
    # The ELAPSED line stays FIRST — harness.test.sh reads it with `sed -n 1s`.
    print(first_line)
    reader.join(2.0)
    sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
    sys.stdout.flush()


def _on_signal(signum, _frame):
    """THE CAGE DOES NOT LEAK ITS CHILD (defect 2). Whatever kills the cage —
    an orchestrator, a shell, a session teardown — the caged group goes first."""
    _reap()
    try:
        p.wait(timeout=5)
    except Exception:
        pass
    _report("ELAPSED %.1fs *** CAGE SIGNALLED (%d) -> group killed ***"
            % (time.time() - t0, signum))
    # Exit the way the signal would have, so a waiting parent still sees it.
    os._exit(128 + signum)


for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    try:
        signal.signal(_sig, _on_signal)
    except (ValueError, OSError):
        pass

try:
    rc = p.wait(timeout=to)
    _report("ELAPSED %.1fs EXIT %d" % (time.time() - t0, rc))
    # THE STATUS IS THE CHILD'S (S289) — see the EXIT-STATUS CONTRACT above.
    # Popen.wait() returns -N for a child killed by signal N; raising that to
    # the shell's 128+N keeps a kill readable instead of truncating to garbage.
    sys.exit(rc if rc >= 0 else 128 - rc)
except subprocess.TimeoutExpired:
    _reap()
    p.wait()
    # Report WHAT WAS MEASURED, not what it implies. See the header.
    _report("ELAPSED %.1fs *** TIMED OUT — exceeded the %gs deadline (group "
            "killed). A timeout is not a verdict: this cage cannot tell SLOW "
            "from STUCK. If the deadline was the wrong budget, raise it; "
            "otherwise read the caged output below for where it stopped. ***"
            % (time.time() - t0, to))
    # 124 IS timeout(1)'s CONVENTION, and deliberately not the child's status:
    # a deadline is a different event from a failing suite, and a caller has to
    # be able to tell them apart. The line says which one it was.
    sys.exit(124)
