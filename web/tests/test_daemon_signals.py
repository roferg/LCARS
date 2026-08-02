"""The daemon must actually STOP when it is asked to stop (pre-165 Fix A).

`kill <daemon-pid>` — a bare SIGTERM, the conventional "please stop" — did NOT
stop the viewscreen daemon. Only `kill -9` did, so every session that started a
board leaked an orphaned daemon holding its port.

The cause was the SIGTERM handler `Actions.__init__` installs to reap launched
apps. It captured the PREVIOUS disposition and chained to it only when that
previous disposition was a real callable — which at daemon start it never is
(it is `SIG_DFL`). So the handler reaped the launches and then simply RETURNED,
and returning from a Python signal handler resumes the interrupted call:
`serve_forever()` carried straight on. INSTALLING the handler is what converted
SIGTERM from "terminate" into "reap the launches and keep running". The daemon
had disabled its own termination.

Why these tests spawn a REAL daemon process: the pre-existing shutdown test
(`test_daemon_shutdown_kills_a_still_running_launch`) calls
`actions.shutdown_launches()` as an in-process Python method. That proves the
reaping and is blind, by construction, to whether the PROCESS dies — which is
exactly why a daemon that could not be terminated kept a green shutdown test.
Everything here signals a real `python3 -m lcars_serve` and judges by whether
the pid is gone, the app it launched is gone, and the port can be bound again.

SIGINT (measured, not assumed — see `SigintTest`): the daemon handles SIGINT
correctly whenever its SIGINT disposition is the default. `__main__` catches
KeyboardInterrupt and runs its `finally`. The operational report that "SIGINT is
ignored too" reproduces only when the daemon is launched as a BACKGROUND job of
a non-interactive shell (or otherwise inherits `SIG_IGN` for SIGINT): the shell
sets SIGINT to SIG_IGN for async commands, and CPython deliberately does not
install its KeyboardInterrupt handler over an inherited SIG_IGN. That is the
launch context, not the daemon — and it is precisely why SIGTERM had to work:
a detached daemon has no other polite way to be stopped.

Zero spend: no worker, no model, no network. The launch script is a stub.
"""
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402

WEB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# How long a stop is allowed to take. Generous: the serve_forever poll interval
# is 1s, so a Python-level handler runs within ~1s of the signal.
STOP_TIMEOUT = 5.0


def _free_port():
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _launch_script(path):
    """A stub `lcars launch` that spawns a REAL app in its OWN process group.

    Same setsid handshake as the fixtures in test_deploy_main / test_write_
    endpoints: setsid FIRST, then touch a ready-file, and only record the pgid
    once the child is confirmed to be its own group leader. A stub that records
    an uncertified pgid makes the daemon group-kill a group the app is not in.
    """
    body = (
        '#!/usr/bin/env bash\n'
        'mid=""\n'
        'for a in "$@"; do\n'
        '  case "$a" in --*) ;; *) [ -z "$mid" ] && mid="$a" ;; esac\n'
        'done\n'
        'lj=".git/lcars/missions/$mid/launch.json"\n'
        'mkdir -p ".git/lcars/missions/$mid"\n'
        'rdy="$(mktemp)"; rm -f "$rdy"\n'
        "perl -e 'use POSIX qw(setsid); eval { setsid(); }; "
        "my $r=shift @ARGV; open(my $f,\">\",$r); close $f; exec @ARGV' "
        '-- "$rdy" sleep 300 >/dev/null 2>&1 &\n'
        'pid=$!\n'
        'led=""\n'
        'for _ in $(seq 1 200); do\n'
        '  if [ -e "$rdy" ]; then led=1; break; fi\n'
        '  sleep 0.01\n'
        'done\n'
        'rm -f "$rdy"\n'
        'if [ -z "$led" ]; then\n'
        '  kill "$pid" 2>/dev/null || true\n'
        '  echo "launch stub: child never led its own process group" >&2\n'
        '  exit 1\n'
        'fi\n'
        'printf \'{"status":"running","target":"fake app",'
        '"url":"http://localhost:9931","howToStop":"stop it from the board",'
        '"command":"sleep 300","cwd":".","pid":%s,"pgid":%s,'
        '"message":"the app is running."}\\n\' "$pid" "$pid" > "$lj"\n'
        'exit 0\n'
    )
    with open(path, "w") as fh:
        fh.write(body)
    os.chmod(path, 0o755)
    return path


class _Daemon(object):
    """A real `python3 -m lcars_serve` child, started and stopped by signal."""

    def __init__(self, repo_root, port=0, launch_script=None,
                 sigint_ignored=False):
        env = dict(os.environ)
        env["LCARS_VERSION_CHECK"] = "0"
        env["LCARS_SERVE_NO_OPEN"] = "1"
        # nothing in these tests may reach a model or a forge.
        env["LCARS_WORKER_BIN"] = "/bin/echo"
        env["LCARS_GH_BIN"] = "/bin/echo"
        if launch_script:
            env["LCARS_LAUNCH_SCRIPT"] = launch_script
        pre = None
        if sigint_ignored:
            # reproduce a detached / background-job launch: SIGINT inherited as
            # SIG_IGN, which CPython will NOT override with its own handler.
            def pre():  # noqa: E306
                signal.signal(signal.SIGINT, signal.SIG_IGN)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "lcars_serve",
             "--repo-root", repo_root, "--port", str(port)],
            cwd=WEB_DIR, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, preexec_fn=pre)
        self.url = self._await_url()

    def _await_url(self):
        # the banner line carries the bound URL; it is written before serving.
        deadline = time.time() + 20
        while time.time() < deadline:
            line = self.proc.stderr.readline()
            if not line:
                if self.proc.poll() is not None:
                    raise AssertionError("daemon exited before it served")
                continue
            if "http://" in line:
                return "http://" + line.split("http://", 1)[1].split()[0]
        raise AssertionError("daemon never printed its URL")

    @property
    def pid(self):
        return self.proc.pid

    def get(self, path, timeout=3):
        with urllib.request.urlopen(self.url + path, timeout=timeout) as r:
            return r.status

    def signal(self, sig):
        os.kill(self.proc.pid, sig)

    def wait_gone(self, timeout=STOP_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return True
            time.sleep(0.05)
        return False

    def kill9(self):
        try:
            self.proc.kill()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            pass
        for stream in (self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except Exception:
                pass


class DaemonBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.daemons = []
        self.stray_pids = []

    def tearDown(self):
        for d in self.daemons:
            d.kill9()
        for pid in self.stray_pids:
            for killer in (os.killpg, os.kill):
                try:
                    killer(pid, signal.SIGKILL)
                except OSError:
                    pass

    def start(self, **kw):
        d = _Daemon(self.tmp, **kw)
        self.daemons.append(d)
        return d


class SigtermTest(DaemonBase):
    def test_a_real_daemon_exits_on_a_bare_sigterm(self):
        """`kill <pid>` stops the daemon. The whole point.

        Judged on the PROCESS, not on a Python method call: the pid must be gone
        and the exit status must be the conventional signal status.
        """
        d = self.start()
        self.assertEqual(d.get("api/board"), 200, "the daemon never served")
        d.signal(signal.SIGTERM)
        self.assertTrue(d.wait_gone(),
                        "the daemon SURVIVED SIGTERM — it has disabled its own "
                        "termination and can only be stopped with kill -9")
        # died BY the signal (or exited cleanly on its own account) — never a
        # crash/traceback status.
        self.assertIn(d.proc.returncode, (-signal.SIGTERM, 0, 143),
                      "unexpected exit status %r" % (d.proc.returncode,))

    def test_sigterm_still_reaps_the_launched_app(self):
        """The guarantee the handler was installed for, kept: an app the daemon
        launched into its own process group is dead after the daemon is TERMed."""
        script = _launch_script(os.path.join(self.tmp, "launch-stub.sh"))
        d = self.start(launch_script=script)
        req = urllib.request.Request(
            d.url + "api/mission/m-001/launch", data=b"{}",
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as r:
            self.assertEqual(r.status, 200)
        import json
        rec_path = os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                                "launch.json")
        with open(rec_path) as fh:
            rec = json.load(fh)
        app_pid = rec["pid"]
        self.stray_pids.append(app_pid)
        self.assertTrue(_pid_alive(app_pid), "the fake app never started")
        # the stub certified the pgid before recording it — so a killpg of the
        # recorded pgid really targets the app's group.
        self.assertEqual(os.getpgid(app_pid), rec["pgid"])

        d.signal(signal.SIGTERM)
        self.assertTrue(d.wait_gone(), "the daemon SURVIVED SIGTERM")
        deadline = time.time() + 3
        while time.time() < deadline and _pid_alive(app_pid):
            time.sleep(0.05)
        self.assertFalse(_pid_alive(app_pid),
                         "the launched app was ORPHANED by the daemon's stop")

    def test_the_port_is_released_so_a_second_daemon_can_bind_it(self):
        """A stop that leaks the bound port is not a stop: the captain restarts
        the board and gets 'address already in use'."""
        port = _free_port()
        first = self.start(port=port)
        self.assertEqual(first.get("api/board"), 200)
        first.signal(signal.SIGTERM)
        self.assertTrue(first.wait_gone(), "the daemon SURVIVED SIGTERM")
        second = self.start(port=port)
        self.assertEqual(second.get("api/board"), 200,
                         "the second daemon could not bind the released port")
        self.assertEqual(second.url, first.url)


class SigintTest(DaemonBase):
    """SIGINT, pinned to what was MEASURED — not to what was assumed."""

    def test_sigint_exits_cleanly_when_its_disposition_is_the_default(self):
        """Ctrl-C in the terminal `lcars viewscreen` runs in. `__main__` catches
        KeyboardInterrupt, prints its goodbye and runs its finally."""
        d = self.start()
        self.assertEqual(d.get("api/board"), 200)
        d.signal(signal.SIGINT)
        self.assertTrue(d.wait_gone(),
                        "the daemon ignored SIGINT with a default disposition")
        self.assertEqual(d.proc.returncode, 0)

    def test_a_daemon_that_inherited_sigint_ignored_still_stops_on_sigterm(self):
        """The measured shape of 'SIGINT is ignored too': a daemon launched as a
        background job / detached inherits SIG_IGN for SIGINT and CPython leaves
        it ignored. That is the LAUNCH CONTEXT, not a daemon defect — and it is
        why SIGTERM must work, since it is the only polite stop such a daemon
        has. Both halves are asserted here so neither can drift."""
        d = self.start(sigint_ignored=True)
        self.assertEqual(d.get("api/board"), 200)
        d.signal(signal.SIGINT)
        time.sleep(1.0)
        self.assertIsNone(d.proc.poll(),
                          "expected an inherited SIG_IGN to survive SIGINT")
        self.assertEqual(d.get("api/board"), 200)
        # ... and SIGTERM still stops it.
        d.signal(signal.SIGTERM)
        self.assertTrue(d.wait_gone(),
                        "a detached daemon has NO way to be stopped politely")


# ── the handler's chaining contract, driven in throwaway subprocesses ─────────
# These install real SIGTERM handlers and let the process die by signal, so they
# cannot run inside the test runner's own process.

_CHAIN_SCRIPT = r"""
import os, signal, sys
sys.path.insert(0, %(web)r)
from lcars_serve.actions import Actions

EV = %(ev)r

def note(tag):
    with open(EV, "a") as fh:
        fh.write(tag + "\n")

class Rec(Actions):
    def __init__(self, tag, **kw):
        self._tag = tag
        Actions.__init__(self, **kw)

    def shutdown_launches(self):
        note("shutdown:" + self._tag)
        return Actions.shutdown_launches(self)

%(body)s
"""

_PRIOR_BODY = """
def prior(signum, frame):
    note("prior")
    os._exit(7)

signal.signal(signal.SIGTERM, prior)
Rec("a", repo_root=%(root)r, scripts={}, worker_bin="/bin/echo")
os.kill(os.getpid(), signal.SIGTERM)
import time
time.sleep(5)
note("STILL-RUNNING")
"""

_TWO_BODY = """
Rec("a", repo_root=%(root)r, scripts={}, worker_bin="/bin/echo")
Rec("b", repo_root=%(root)r, scripts={}, worker_bin="/bin/echo")
os.kill(os.getpid(), signal.SIGTERM)
import time
time.sleep(5)
note("STILL-RUNNING")
"""


class HandlerChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.ev = os.path.join(self.tmp, "events.txt")

    def _run(self, body):
        src = _CHAIN_SCRIPT % {
            "web": WEB_DIR, "ev": self.ev, "body": body % {"root": self.tmp}}
        path = os.path.join(self.tmp, "prog.py")
        with open(path, "w") as fh:
            fh.write(src)
        proc = subprocess.run([sys.executable, path], cwd=self.tmp,
                              capture_output=True, text=True, timeout=30)
        events = []
        if os.path.exists(self.ev):
            with open(self.ev) as fh:
                events = [ln.strip() for ln in fh if ln.strip()]
        return proc, events

    def test_a_real_prior_handler_is_chained_and_owns_the_exit(self):
        """A SIGTERM handler installed BEFORE Actions() still runs, still after
        the launches are reaped, and still decides how the process ends."""
        proc, events = self._run(_PRIOR_BODY)
        self.assertNotIn("STILL-RUNNING", events, proc.stderr)
        self.assertEqual(events, ["shutdown:a", "prior"],
                         "reap-then-chain order broken: %r" % (events,))
        self.assertEqual(proc.returncode, 7,
                         "the prior handler did not own the exit")

    def test_two_actions_in_one_process_do_not_recurse(self):
        """Each Actions chains to the handler it found, so two of them nest
        exactly twice and then terminate — no recursion, no survivor."""
        proc, events = self._run(_TWO_BODY)
        self.assertNotIn("STILL-RUNNING", events, proc.stderr)
        # the second-installed handler runs first and chains to the first.
        self.assertEqual(events, ["shutdown:b", "shutdown:a"],
                         "handler chain broken: %r" % (events,))
        self.assertEqual(proc.returncode, -signal.SIGTERM,
                         "the process did not die by SIGTERM")
        self.assertNotIn("RecursionError", proc.stderr)


if __name__ == "__main__":
    unittest.main()
