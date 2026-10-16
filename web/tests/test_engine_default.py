"""S274 — THE DAEMON FINDS THE ENGINE THAT IS INSTALLED.

`python -m lcars_serve` used to take its worker engine from ONE place:
`os.environ.get("LCARS_WORKER_BIN")`. With that variable unset — which is every
ordinary start — the daemon had no engine at all, so the Align grill answered
502 "no worker engine configured ($LCARS_WORKER_BIN)" and both holodeck doors
did the same, on a laptop where `lcars init` had already found a CLI and written
`workerBin` into `.git/lcars/config.json`. The board, meanwhile, published the
installed-engine list only for a repo that had run `lcars xo`, so a repo with no
Number One block could not even say which engines were here.

What this suite pins:

  1. the daemon's default engine comes from the SAME shared bash detector every
     other surface reads (skills/lcars-init/lcars-common.sh) — repo config pin
     when that engine is installed, else the single installed engine, else
     NOTHING. `command -v` is never re-implemented in Python.
  2. `meta.enginesHere` / `meta.engineDefault` / `meta.engineSource` are on
     EVERY board, including a repo that has never heard of Number One.
  3. with NEITHER CLI the daemon STARTS and the refusals say what was looked
     for — they never tell the captain to set an environment variable, which is
     the wrong fix for a laptop that simply has no CLI.

The engines are faked through the `LCARS_CLAUDE_BIN` / `LCARS_COPILOT_BIN`
seams, never through $PATH, so every assertion measures the fixture and not the
tester's laptop. The engine stub is never RUN by the detector (`command -v` is a
filesystem question) and the Align worker is a canned-turn shell script, so this
suite spends nothing.

stdlib only.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import (  # noqa: E402
    LocalAdapter, default_worker_engine)
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402


def _exe(path, body="#!/bin/sh\nexit 0\n"):
    with open(path, "w") as fh:
        fh.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP
             | stat.S_IXOTH)
    return path


class EngineFixture(unittest.TestCase):
    """A repo plus a bin dir, with the two engine seams under our control."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.bins = os.path.join(self.tmp, "bin")
        os.makedirs(self.bins, exist_ok=True)
        self.missing = os.path.join(self.tmp, "definitely-not-installed")
        self._env_saved = {}

    def setenv(self, **kw):
        for k, v in kw.items():
            if k not in self._env_saved:
                self._env_saved[k] = os.environ.get(k)
                self.addCleanup(self._restore, k)
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _restore(self, key):
        old = self._env_saved.get(key)
        if old is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = old

    def engine(self, name):
        """An engine that is INSTALLED and never RUN."""
        return _exe(os.path.join(self.bins, name))

    def config(self, obj):
        d = os.path.join(self.tmp, ".git", "lcars")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config.json"), "w") as fh:
            json.dump(obj, fh, indent=2)

    def only_copilot(self):
        self.setenv(LCARS_WORKER_BIN=None,
                    LCARS_CLAUDE_BIN=self.missing,
                    LCARS_COPILOT_BIN=self.engine("copilot"))

    def neither(self):
        self.setenv(LCARS_WORKER_BIN=None,
                    LCARS_CLAUDE_BIN=self.missing,
                    LCARS_COPILOT_BIN=self.missing)

    def meta(self):
        return LocalAdapter(self.tmp).board()["meta"]


class TheDaemonsDefaultEngine(EngineFixture):
    """Behaviours 1 + 2 — where the engine comes from, and the provenance."""

    def test_config_pin_wins_when_that_engine_is_installed(self):
        """Behaviour 1. `lcars init` wrote `workerBin: copilot`; the daemon
        reads it rather than starting with no engine at all."""
        self.only_copilot()
        self.config({"workerBin": "copilot"})
        engine, source = default_worker_engine(self.tmp)
        self.assertEqual("copilot", engine)
        self.assertEqual("config", source)

    def test_the_single_installed_engine_when_nothing_is_pinned(self):
        """Behaviour 2. No pin anywhere — the detector's answer, recorded as
        `detected` so the board can say WHY this engine."""
        self.only_copilot()
        self.config({"model": "claude-sonnet"})
        engine, source = default_worker_engine(self.tmp)
        self.assertEqual("copilot", engine)
        self.assertEqual("detected", source)

    def test_an_explicit_variable_still_wins_and_says_so(self):
        """$LCARS_WORKER_BIN is a per-invocation operator act and still tops
        everything — recorded as `env`, never as a detection."""
        self.only_copilot()
        self.setenv(LCARS_WORKER_BIN="/opt/weird/claude")
        engine, source = default_worker_engine(self.tmp)
        self.assertEqual("/opt/weird/claude", engine)
        self.assertEqual("env", source)

    def test_a_pin_for_an_absent_engine_is_not_obeyed(self):
        """A config that names claude on a copilot-only laptop must not make
        the daemon start a CLI that is not there."""
        self.only_copilot()
        self.config({"workerBin": "claude"})
        engine, source = default_worker_engine(self.tmp)
        self.assertEqual("copilot", engine)
        self.assertEqual("detected", source)

    def test_neither_installed_answers_nothing(self):
        """Behaviour 3's half of the resolution: EMPTY, never the literal
        `claude`."""
        self.neither()
        engine, source = default_worker_engine(self.tmp)
        self.assertIsNone(engine)
        self.assertEqual("none", source)

    def test_the_detector_never_runs_an_engine(self):
        """`command -v` is a question about the filesystem. An engine that was
        EXECUTED to answer it would be spending the captain's money."""
        log = os.path.join(self.tmp, "ran.txt")
        _exe(os.path.join(self.bins, "copilot"),
             "#!/bin/sh\necho ran >> %s\nexit 0\n" % log)
        self.setenv(LCARS_WORKER_BIN=None, LCARS_CLAUDE_BIN=self.missing,
                    LCARS_COPILOT_BIN=os.path.join(self.bins, "copilot"))
        self.assertEqual("copilot", default_worker_engine(self.tmp)[0])
        self.assertFalse(os.path.exists(log),
                         "an engine CLI was executed to answer a question "
                         "about whether it is installed")


class EveryBoardSaysWhatIsHere(EngineFixture):
    """Behaviours 2 + 4 — the keys are on EVERY board, Number One or not."""

    def test_a_repo_with_no_number_one_block_still_lists_the_engines(self):
        """Behaviour 4. Before S274 these keys lived inside `if xo is not
        None`, so the ONLY repos that could say which engines were installed
        were the ones that had run `lcars xo`."""
        self.only_copilot()
        self.config({"model": "claude-sonnet"})
        meta = self.meta()
        self.assertNotIn("numberOne", meta)
        self.assertEqual(["copilot"], meta.get("enginesHere"))
        self.assertEqual("copilot", meta.get("engineDefault"))
        self.assertEqual("detected", meta.get("engineSource"))

    def test_the_config_pin_shows_as_the_source(self):
        self.only_copilot()
        self.config({"workerBin": "copilot"})
        meta = self.meta()
        self.assertEqual("copilot", meta.get("engineDefault"))
        self.assertEqual("config", meta.get("engineSource"))
        self.assertEqual("copilot", meta.get("workerEngine"))

    def test_neither_installed_is_an_empty_list_and_a_null(self):
        """Behaviour 3. [] is an ANSWER — "I asked, and there are none" — and
        it is not the same as the key being absent, which the front end reads
        as "I could not ask"."""
        self.neither()
        self.config({"model": "claude-sonnet"})
        meta = self.meta()
        self.assertEqual([], meta.get("enginesHere"))
        self.assertIsNone(meta.get("engineDefault"))
        self.assertEqual("none", meta.get("engineSource"))

    def test_both_installed_lists_both(self):
        self.setenv(LCARS_WORKER_BIN=None,
                    LCARS_CLAUDE_BIN=self.engine("claude"),
                    LCARS_COPILOT_BIN=self.engine("copilot"))
        self.config({"model": "claude-sonnet"})
        meta = self.meta()
        self.assertEqual(["claude", "copilot"], meta.get("enginesHere"))


def _align_worker_stub(path, reply):
    """A canned-turn Align worker: prints ONE question blob, spends nothing."""
    return _exe(path, "#!/bin/sh\ncat <<'JSON'\n%s\nJSON\nexit 0\n"
                % json.dumps(reply))


def _noop_script(path):
    return _exe(path, "#!/usr/bin/env bash\nexit 0\n")


class TheGrillStartsOnTheInstalledEngine(EngineFixture):
    """Behaviour 1's other half, and behaviour 3's refusal."""

    def _serve(self, worker_bin):
        scripts = {k: _noop_script(os.path.join(self.tmp, "sk-%s.sh" % k))
                   for k in ("file", "log", "resolve")}
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin=worker_bin)
        httpd = make_server(LocalAdapter(self.tmp), host="127.0.0.1", port=0,
                            poll_interval=0.05, actions=actions)
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return httpd.server_address[1]

    def _post(self, port, path, obj):
        req = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (port, path),
            data=json.dumps(obj).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read())

    def test_align_start_succeeds_on_the_detected_engine(self):
        """Behaviour 1. The grill used to 502 here with $LCARS_WORKER_BIN
        unset. The engine NAME is what the daemon carries; `_engine_file`
        turns `copilot` into $LCARS_COPILOT_BIN, which is how a laptop whose
        CLI is not on PATH is served — and how this test stays free."""
        self.setenv(LCARS_WORKER_BIN=None, LCARS_CLAUDE_BIN=self.missing,
                    LCARS_COPILOT_BIN=_align_worker_stub(
                        os.path.join(self.bins, "copilot"),
                        {"status": "question",
                         "question": {"text": "One course or many?",
                                      "recommended": "One"},
                         "prd": "# Mission: X\n\n**Type:** feature\n"}))
        self.config({"workerBin": "copilot"})
        engine, source = default_worker_engine(self.tmp)
        self.assertEqual(("copilot", "config"), (engine, source))
        port = self._serve(engine)
        status, body = self._post(port, "/api/align/start",
                                  {"idea": "Add a leaderboard"})
        self.assertEqual(200, status)
        self.assertEqual("question", body["state"]["status"])
        self.assertEqual("One course or many?",
                         body["state"]["question"]["text"])

    def test_align_refuses_a_picked_engine_that_is_not_installed(self):
        """Behaviour 3 ON THE BRANCH THE UI ACTUALLY TAKES (fix round 1).

        MEASURED by a fresh tester: on a laptop with only Copilot (and again
        with neither CLI) he pressed FILE MISSION and FILE & BEGIN ALIGNMENT
        with the engine control at its default, and the console's error line
        read

            worker engine failed to start: [Errno 2] No such file or
            directory: 'claude'

        — a raw Python OSError, on the first screen a stranger touches. Round 0
        made the NO-engine branch honest, but board.js always posts an explicit
        `engine`, so the UI never reaches it: the named-but-absent engine went
        straight to the spawn. The grill must refuse pre-spawn, the way the
        holodeck already does, naming the engine asked for and BOTH binaries
        LCARS looks for.

        $PATH is scrubbed as well as the two seams, so "claude is not here" is
        TRUE in this process and the refusal cannot be answered by the tester's
        own install (and no real engine can be spawned to spend anything)."""
        self.neither()
        self.setenv(PATH="/usr/bin:/bin")
        self.config({"model": "claude-sonnet"})
        port = self._serve(None)
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post(port, "/api/align/start",
                       {"idea": "Add a leaderboard", "engine": "claude"})
        self.assertEqual(502, cm.exception.code)
        msg = cm.exception.read().decode("utf-8", "replace")
        self.assertIn("claude", msg)
        self.assertIn("copilot", msg)
        self.assertIn("not an executable on this machine", msg)
        # NEVER AGAIN: the raw exception, or a variable that cannot cure a
        # laptop which simply has not got the CLI.
        self.assertNotIn("Errno", msg)
        self.assertNotIn("LCARS_WORKER_BIN", msg)

    def test_align_refusal_names_both_engines_for_an_absent_path(self):
        """The same door, an engine named BY PATH — the sentence still says
        what LCARS looks for, so the refusal is readable when the engine asked
        for is neither of the two names."""
        self.only_copilot()
        port = self._serve("copilot")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post(port, "/api/align/start",
                       {"idea": "Add a leaderboard", "engine": self.missing})
        self.assertEqual(502, cm.exception.code)
        msg = cm.exception.read().decode("utf-8", "replace")
        self.assertIn(os.path.basename(self.missing), msg)
        self.assertIn("claude", msg)
        self.assertIn("copilot", msg)
        self.assertNotIn("Errno", msg)

    def test_with_no_engine_the_daemon_serves_and_the_refusal_is_honest(self):
        """Behaviour 3. The board still comes up; the grill explains itself."""
        self.neither()
        self.config({"model": "claude-sonnet"})
        engine, _src = default_worker_engine(self.tmp)
        port = self._serve(engine)
        # the READ path is untouched — a laptop with no CLI still gets a board.
        with urllib.request.urlopen(
                "http://127.0.0.1:%d/api/board" % port, timeout=15) as r:
            meta = json.loads(r.read())["meta"]
        self.assertEqual([], meta.get("enginesHere"))
        self.assertIsNone(meta.get("engineDefault"))
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post(port, "/api/align/start", {"idea": "Add a leaderboard"})
        self.assertEqual(502, cm.exception.code)
        msg = cm.exception.read().decode("utf-8", "replace")
        # It says WHAT WAS LOOKED FOR, by binary name, and how to get either —
        # never "set $LCARS_WORKER_BIN", which cannot cure an empty laptop.
        self.assertIn("claude", msg)
        self.assertIn("copilot", msg)
        self.assertIn("claude.com/claude-code", msg)
        self.assertIn("github.com/features/copilot/cli", msg)
        self.assertNotIn("LCARS_WORKER_BIN", msg)


class TheOtherTwoDoorsSayTheSameThing(EngineFixture):
    """Behaviour 3 for the holodeck's two 502s (actions.py:9656, :10491)."""

    def _actions(self):
        scripts = {k: _noop_script(os.path.join(self.tmp, "sk-%s.sh" % k))
                   for k in ("file", "log", "resolve")}
        return Actions(repo_root=self.tmp, scripts=scripts, worker_bin=None)

    def _refusal(self, fn, *a, **kw):
        from lcars_serve.actions import ActionError
        with self.assertRaises(ActionError) as cm:
            fn(*a, **kw)
        self.assertEqual(502, cm.exception.status)
        return str(cm.exception)

    def test_opening_a_program_with_no_engine_anywhere(self):
        self.neither()
        msg = self._refusal(self._actions()._resolve_holodeck_engine, "")
        self.assertIn("claude", msg)
        self.assertIn("copilot", msg)
        self.assertNotIn("LCARS_WORKER_BIN", msg)

    def test_every_no_engine_refusal_is_the_same_sentence(self):
        """ONE sentence, one place. Three doors said three different things,
        two of which named a variable."""
        from lcars_serve.actions import no_engine_refusal
        line = no_engine_refusal()
        self.assertIn("claude", line)
        self.assertIn("copilot", line)
        self.assertIn("claude.com/claude-code", line)
        self.assertIn("github.com/features/copilot/cli", line)
        self.assertNotIn("$LCARS_WORKER_BIN", line)


if __name__ == "__main__":
    unittest.main()
