"""S201 — THE ENGAGED LOCK, at the daemon's door.

While Number One holds a mission it acts THROUGH the verbs on the captain's
behalf. A second hand on the same mission — from the board, or from a curl at
the port — is a race, so the daemon refuses the same write verbs the CLI
refuses, with the SAME sentence, for the same reason S190 built `_owner_gate`:
a disabled button is not a lock.

WHAT IS DIFFERENT FROM THE OWNER LOCK, and why:

  * `start` is NOT in this set. The owner lock covers it because someone else's
    mission must not be started here at all; an ENGAGED mission is *already*
    being driven, and Number One's own driver goes through the same door.
  * The verdict is a LOCAL FILE READ, not a forge call: `state.numberOne.status`
    is recorded by `lcars xo` / the driver. Nothing is inferred from prose, and
    no network is touched — so this suite wires the REAL `ownership.sh` rather
    than a stub, and spends nothing.
  * It is dispatched AFTER the owner gate. "this is someone else's mission" is
    the more fundamental fact; being told Number One holds a mission that is not
    yours to act on either would be the wrong first answer.

THE SENTENCE IS READ OUT OF `skills/lcars-run/ownership.sh` — this file retypes
nothing. Anyone who edits the library and not the daemon (or the reverse) breaks
this test instead of telling the captain two different stories.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

OWNERSHIP = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-run", "ownership.sh"))
MID = "m-001"

# The verbs the owner lock covers, MINUS `start`. Everything else is the same
# set for the same reason — an allow-list, so a verb added later is unlocked
# until somebody puts it here on purpose.
LOCKED_VERBS = [
    ("pause", {}),
    ("resume", {}),
    ("respond", {"answer": "go on"}),
    ("verify", {"decision": "approve"}),
    ("reapprove", {}),
    ("log", {"text": "the button is the wrong colour"}),
    ("log/file", {"prds": []}),
    ("log/run", {"prds": []}),
    ("log/discard", {}),
]


def _sentence_from_the_library(mission_id):
    """The ONE sentence, lifted out of ownership.sh's printf format."""
    with open(OWNERSHIP) as fh:
        src = fh.read()
    m = re.search(r"printf '(Number One is engaged[^']*)'", src)
    assert m, "ownership.sh no longer carries the engaged sentence as a printf"
    return m.group(1).replace("%s", mission_id)


def _record_stub(record_path):
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\n'
                 'printf "ARGV: %s\\n" "$*" >> "' + record_path + '"\n'
                 'exit 0\n')
    os.chmod(path, 0o755)
    return path


def _plant_number_one(root, mid, block):
    """Write `numberOne` exactly the way the shipped writers write it.

    TWO PROPERTIES, and a fixture that got either wrong would be testing a file
    LCARS never produces:
      * AT THE TOP, immediately after the opening brace — the S189 rule. A
        last-key corruption bug is latent in the state writers, and keeping new
        keys off the end keeps it latent.
      * ON ONE LINE. `xo.sh` and `run.sh`'s state_set_raw both emit the object
        on a single line, and every reader of it (the lock, the status table)
        is a one-line reader by that contract.
    """
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    one_line = '  "numberOne": %s,\n' % json.dumps(block)
    lines.insert(1, one_line)
    with open(path, "w") as fh:
        fh.writelines(lines)
    # …and it is still valid JSON, which is the point of planting it this way.
    with open(path) as fh:
        json.load(fh)


class XoLockBase(unittest.TestCase):
    NUMBER_ONE = {"status": "engaged", "engine": "copilot",
                  "since": "2026-09-12T01:00:00Z"}

    def setUp(self):
        if not os.path.isfile(OWNERSHIP):
            self.skipTest("ownership.sh not present in this tree")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=142,
                        pr_url="https://github.com/acme/repo/pull/7",
                        pr_number="7", review="open")
        if self.NUMBER_ONE is not None:
            _plant_number_one(self.tmp, MID, self.NUMBER_ONE)

        self.adapter = LocalAdapter(self.tmp)
        self.records = {}
        self.scripts = {}
        for key in ("file", "run", "pause", "respond", "approve", "feedback",
                    "log", "resolve", "launch"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _record_stub(rec)
        # THE REAL LIBRARY. The engaged verdict is a local file read — no gh, no
        # network, no model — so there is nothing here a stub would protect us
        # from, and plenty a stub would hide.
        self.scripts["ownership"] = OWNERSHIP

        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin="/bin/echo")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, obj=None, timeout=15):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def verb(self, name, body=None):
        return self.post("/api/mission/%s/%s" % (MID, name), body)

    def dispatched(self, key):
        p = self.records[key]
        return os.path.exists(p) and os.path.getsize(p) > 0


class AnEngagedMissionIs403(XoLockBase):

    def test_every_locked_write_verb_returns_403(self):
        for verb, body in LOCKED_VERBS:
            status, payload = self.verb(verb, body)
            self.assertEqual(403, status, "%s was not refused" % verb)
            self.assertFalse(payload.get("ok"), verb)

    def test_the_refusal_is_the_SAME_BYTES_as_the_shell_library_prints(self):
        # Read BOTH files: the sentence comes out of ownership.sh's source, and
        # the 403 body comes off the wire. Two wordings for one rule is how a
        # captain ends up unsure which of them is telling the truth.
        expected = _sentence_from_the_library(MID)
        for verb, body in LOCKED_VERBS:
            _, payload = self.verb(verb, body)
            self.assertEqual(expected, payload.get("error"), verb)

    def test_the_shell_face_and_the_403_agree_byte_for_byte(self):
        # …and the third reading: actually RUN the executable face the daemon
        # shells, and compare its stdout with the wire.
        proc = subprocess.run(
            ["bash", OWNERSHIP, "xo-lock-reason",
             fx.mission_dir(self.tmp, MID)],
            cwd=self.tmp, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.assertEqual(0, proc.returncode)
        line = proc.stdout.decode("utf-8").strip()
        _, payload = self.verb("pause")
        self.assertEqual(line, payload.get("error"))
        self.assertEqual(_sentence_from_the_library(MID), line)

    def test_nothing_is_dispatched_behind_the_refusal(self):
        for verb, body in LOCKED_VERBS:
            self.verb(verb, body)
        for key in ("run", "pause", "respond", "approve", "feedback", "log",
                    "resolve"):
            self.assertFalse(self.dispatched(key),
                             "the %s skill ran on an engaged mission" % key)

    def test_start_is_NOT_locked_the_mission_is_already_being_driven(self):
        status, _ = self.verb("start")
        self.assertNotEqual(403, status)

    def test_the_launch_affordance_is_untouched(self):
        status, _ = self.verb("launch/stop")
        self.assertNotEqual(403, status)

    def test_reads_are_never_blocked(self):
        for path in ("/api/board", "/api/mission/%s" % MID):
            url = "http://127.0.0.1:%d%s" % (self.port, path)
            with urllib.request.urlopen(url, timeout=10) as r:
                self.assertEqual(200, r.status, path)


class AMissionWithNoNumberOneKeyIsUntouched(XoLockBase):
    NUMBER_ONE = None

    def test_every_write_verb_still_gets_through(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, "%s was wrongly refused" % verb)


class AStoodDownMissionIsNotLocked(XoLockBase):
    NUMBER_ONE = {"status": "stood-down", "engine": "copilot",
                  "note": "Number One stood down 01:02 · you have the conn"}

    def test_standing_down_lifts_the_lock(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, verb)


class AFinishedMissionIsNotLocked(XoLockBase):
    NUMBER_ONE = {"status": "finished", "engine": "copilot", "score": 91}

    def test_a_finished_number_one_hands_the_conn_back(self):
        # The whole point of the gate is the captain acting on what Number One
        # finished: a finished mission that stayed locked would be a dead end.
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, verb)


class NoOwnershipScriptWiredChangesNothing(XoLockBase):
    """Every pre-S201 caller builds Actions with no `ownership` script."""

    def setUp(self):
        super().setUp()
        self.actions.scripts.pop("ownership", None)

    def test_writes_are_not_refused_when_the_daemon_has_no_seam(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, verb)


if __name__ == "__main__":
    unittest.main()
