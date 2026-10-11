#!/usr/bin/env bash
# D6: drive the actual orphan_probe with real detached processes, no workers.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$DIR" <<'PY'
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

tests = Path(sys.argv[1])
source = (tests / "harness.test.sh").read_text()
start = source.index("ppid1_snapshot() {")
stop = source.index("\n# CONTROL: the detector must first", start)
functions = source[start:stop]
passed = failed = 0
planted = set()


def check(label, condition):
    global passed, failed
    print(("PASS " if condition else "FAIL ") + label, flush=True)
    if condition:
        passed += 1
    else:
        failed += 1


def info(pid):
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "pid=,ppid=,args="],
        capture_output=True, text=True, check=False,
    ).stdout.strip()


def reap(pid):
    if info(pid):
        os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + 3
    while info(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    check(f"cleanup pid={pid} is gone", not info(pid))


with tempfile.TemporaryDirectory(prefix="s256-orphans-") as directory:
    root = Path(directory).resolve()
    suite = root / "suite"
    suite.mkdir()
    # A sibling with the same prefix must NOT match the suite directory.
    outside = root / "suite-unowned"
    outside.mkdir()
    sleeper = outside / "s256-sleep"
    sleeper.symlink_to("/bin/sleep")
    owned_sleeper = suite / "s256-owned-sleep"
    owned_sleeper.symlink_to("/bin/sleep")
    probe = root / "probe.sh"
    probe.write_text(
        'set -uo pipefail\nTMPROOT="$1"; CAGE="$2"; shift 2\n'
        + functions
        + '\nlabel="$1"; shift\norphan_probe "$label" 10 "$@"\n'
          'echo "ATTRIBUTED=$(wc -l <"$ORPHAN_NEW" | tr -d " ")"\n'
          'cat "$ORPHAN_REPORT"\n'
    )
    detach = root / "detach.py"
    detach.write_text('''import os, resource, sys
pidfile, sleeper, mode, cwd = sys.argv[1:]
if os.fork():
    os._exit(0)
os.setsid()
if os.fork():
    os._exit(0)
os.chdir(cwd)
with open(pidfile, "w") as stream:
    stream.write(str(os.getpid()))
null = os.open("/dev/null", os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
if mode in ("closeall", "argdir"):
    os.closerange(3, int(resource.getrlimit(resource.RLIMIT_NOFILE)[0]))
elif mode == "execdrop":
    program = ("import os,sys;os.set_inheritable(9,False);"
               "os.execv(sys.argv[1],[sys.argv[1],'300'])")
    os.execv(sys.executable, [sys.executable, "-c", program, sleeper])
if mode == "argdir":
    os.execv(sys.executable, [sys.executable, "-c",
                            "import time;time.sleep(300)", sleeper])
os.execv(sleeper, [sleeper, "300"])
''')
    clean = root / "clean.sh"
    clean.write_text(
        'sleep 300 &\nchild=$!\nkill -TERM "$child"\n'
        'wait "$child" 2>/dev/null || true\nsleep 0.6\n'
    )

    def run(label, mode=None, cwd=None, executable=None, external=False):
        pidfile = root / (label + ".pid")
        args = (["bash", str(clean)] if mode is None or external else
                [sys.executable, str(detach), str(pidfile),
                 str(executable or sleeper), mode, str(cwd)])
        command = [
            "bash", str(probe), str(suite), str(tests / "lib/cage.py"),
            label, *args,
        ]
        child = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            if external:
                deadline = time.monotonic() + 5
                while not (suite / (label + ".root")).exists():
                    if time.monotonic() > deadline:
                        raise RuntimeError("probe never announced its suite root")
                    time.sleep(0.01)
                subprocess.run(
                    [sys.executable, str(detach), str(pidfile), str(sleeper),
                     "closeall", str(outside)], check=True, timeout=5,
                )
            text, _ = child.communicate(timeout=25)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
        print(f"\nCONTROL {label}\n{text}", flush=True)
        attributed = (suite / (label + ".new")).read_text().split()
        unknown_file = suite / (label + ".unattributed")
        unknown = unknown_file.read_text() if unknown_file.exists() else ""
        check(label + ": launching suite completed (cage TEXT)",
              bool(re.search(r"^ELAPSED [0-9.]+s EXIT 0$", text, re.M)))
        if mode is None:
            check(label + ": clean suite has ZERO blamed orphans",
                  not attributed)
            return
        pid = int(pidfile.read_text())
        planted.add(pid)
        status = info(pid)
        print(f"ALIVE {status}", flush=True)
        check(label + ": planted process really is alive at ppid 1",
              bool(re.match(rf"{pid}\s+1\s", status)))
        marker = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(pid),
             str(suite / (label + ".root.marker"))],
            capture_output=True, text=True, check=False,
        )
        print(f"MARKER pid={pid} lsof_exit={marker.returncode}", flush=True)
        check(label + ": marker evidence has the intended shape",
              marker.returncode == (0 if mode == "keep" else 1))
        expected_owned = not external and label != "owned-unattributable"
        if expected_owned:
            check(label + ": exact owned PID is DETECTED",
                  str(pid) in attributed)
        else:
            check(label + ": no false blame",
                  str(pid) not in attributed and not attributed)
            check(label + ": exact PID and argv are stored as UNATTRIBUTED",
                  bool(re.search(rf"^{pid}\s+.*{re.escape(str(sleeper))}",
                                 unknown, re.M)))
            check(label + ": UNATTRIBUTED PID and argv are PRINTED",
                  bool(re.search(
                      rf"unattributed.*pid={pid}\s+argv=.*{re.escape(str(sleeper))}",
                      text)))
            summary = re.search(r"attributed=(\d+) unattributed=(\d+)", text)
            check(label + ": separate nonzero UNATTRIBUTED count is visible",
                  bool(summary and int(summary[1]) == 0 and int(summary[2]) >= 1))
        reap(pid)

    try:
        run("marker-only", "keep", outside)
        run("close-descriptors-cwd", "closeall", suite)
        run("close-on-exec-cwd", "execdrop", suite)
        run("close-descriptors-argv", "closeall", "/", owned_sleeper)
        run("close-descriptors-argv-directory", "argdir", "/", suite)
        run("owned-unattributable", "closeall", "/")
        run("clean-alone")
        run("external-double-fork", "closeall", outside, external=True)
    finally:
        # Even a failed assertion or interrupted probe must reap its planted PID.
        for pidfile in root.glob("*.pid"):
            planted.add(int(pidfile.read_text()))
        for pid in sorted(planted):
            if info(pid):
                reap(pid)
        remaining = {pid: info(pid) for pid in planted if info(pid)}
        print(f"CLEANUP planted={len(planted)} remaining={len(remaining)} "
              f"details={remaining}", flush=True)
        check("final roll call: ALL planted processes are gone", not remaining)

print(f"harness orphans: {passed} passed, {failed} failed", flush=True)
sys.exit(bool(failed))
PY
