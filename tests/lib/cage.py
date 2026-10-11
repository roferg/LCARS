"""cage.py TIMEOUT cmd...  -> own process group, SIGKILL the whole group on timeout.

The harness's only safety device: every unattended suite is run through it.
CLAUDE.md's rule for anything unattended, because there is no portable
`timeout(1)` on macOS.

Output contract, depended on by tests/harness.test.sh: the FIRST line is always
    ELAPSED <n>s EXIT <code>
or
    ELAPSED <n>s *** TIMED OUT — exceeded the <d>s deadline (group killed). ...
and the caged process's own output follows it.

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
except subprocess.TimeoutExpired:
    _reap()
    p.wait()
    # Report WHAT WAS MEASURED, not what it implies. See the header.
    _report("ELAPSED %.1fs *** TIMED OUT — exceeded the %gs deadline (group "
            "killed). A timeout is not a verdict: this cage cannot tell SLOW "
            "from STUCK. If the deadline was the wrong budget, raise it; "
            "otherwise read the caged output below for where it stopped. ***"
            % (time.time() - t0, to))
