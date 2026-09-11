"""S190 — THE LOCK. The daemon's write endpoints refuse someone else's mission.

A DISABLED BUTTON IS NOT A LOCK. Everything in test_owner_board.py is a courtesy
to the person looking at the board; this file is the part that actually holds.
Every test here BYPASSES THE DOM and POSTs straight at the daemon, exactly the
way anyone with the port number can.

This is defense in depth OVER S189, not instead of it: `lcars run` / `respond` /
`approve` / `feedback` / `log` already refuse at the CLI. But the daemon spawns
those skills DETACHED and fire-and-forget for the long verbs, so a refusal that
only happens inside the child arrives as a line in a spawn log nobody is reading,
after the board has already flipped the card to "starting". The daemon must
refuse at the door, with the status code that says so, and the SAME sentence.

The check is LIVE, not cached: it shells the same `ownership.sh lock-reason` the
CLI consults, so a reassignment made on GitHub takes effect on the very next
click — the board's published-owner file is a display cache and is never allowed
to decide a write.

`ownership.sh` is stubbed (a script speaking its three-op contract); no gh, no
network, no model.
"""
import json
import os
import shutil
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

ME = "roferg"
OTHER = "picard"
LINE = ("assigned to %s — reassign it to yourself on GitHub to take command"
        % OTHER)

# The write verbs S189 locks at the CLI, expressed as the endpoints that dispatch
# them. `launch` / `launch/stop` are deliberately NOT here: the launch affordance
# is S187's territory and this session changes nothing about it.
LOCKED_VERBS = [
    ("start", {}),
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


def _record_stub(record_path):
    """A skill stub that records its argv and exits 0 — so a dispatch that got
    THROUGH the lock is visible, and one that was refused leaves no trace."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\n'
                 'printf "ARGV: %s\\n" "$*" >> "' + record_path + '"\n'
                 'exit 0\n')
    os.chmod(path, 0o755)
    return path


def _ownership_stub(tmp, whoami, owner_map, calls=None):
    """A stand-in for skills/lcars-run/ownership.sh's executable face.

    Speaks the three ops with S189's posture: unassigned never locks,
    unresolvable identity never locks. Optionally logs each call so a test can
    prove the check ran LIVE rather than off a cached file.
    """
    lines = ["#!/usr/bin/env bash", 'op="${1:-}"', 'n="${2:-}"',
             'me="%s"' % whoami, 'own=""']
    if calls:
        lines.append('printf "%s %s\\n" "$op" "$n" >> "' + calls + '"')
    for issue, login in owner_map.items():
        lines.append('[ "$n" = "%s" ] && own="%s"' % (issue, login))
    lines += [
        'case "$op" in',
        '  whoami) [ -n "$me" ] || exit 1; printf "%s" "$me" ;;',
        '  owner)  printf "%s" "$own" ;;',
        '  lock-reason)',
        '    [ -n "$own" ] || exit 1',
        '    [ -n "$me" ]  || exit 1',
        '    [ "$own" = "$me" ] && exit 1',
        '    printf "assigned to %s — reassign it to yourself on GitHub to take command" "$own"',
        '    ;;',
        '  *) exit 2 ;;',
        'esac',
    ]
    path = os.path.join(tmp, "ownership-%s.sh" % (whoami or "nobody"))
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


class LockBase(unittest.TestCase):
    WHOAMI = ME
    OWNERS = {}

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # ONE mission, at verify (so approve/verify make sense) with an issue.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        pr_url="https://github.com/acme/repo/pull/7",
                        pr_number="7", review="open")
        self.calls = os.path.join(self.tmp, "ownership-calls.txt")
        self.ownership = _ownership_stub(self.tmp, self.WHOAMI, self.OWNERS,
                                         calls=self.calls)
        self.adapter = LocalAdapter(self.tmp, ownership_script=self.ownership)

        self.records = {}
        self.scripts = {}
        for key in ("file", "run", "pause", "respond", "approve", "feedback",
                    "log", "resolve", "launch"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _record_stub(rec)
        self.scripts["ownership"] = self.ownership

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
        """POST and return (status, body) — including for an error status."""
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
        return self.post("/api/mission/m-001/%s" % name, body)

    def dispatched(self, key):
        p = self.records[key]
        return os.path.exists(p) and os.path.getsize(p) > 0


class SomeoneElsesMissionIs403(LockBase):
    WHOAMI = ME
    OWNERS = {"142": OTHER}

    def test_every_locked_write_verb_returns_403(self):
        for verb, body in LOCKED_VERBS:
            status, payload = self.verb(verb, body)
            self.assertEqual(403, status, "%s was not refused" % verb)
            self.assertFalse(payload.get("ok"), verb)

    def test_the_refusal_carries_the_SAME_plain_line_the_cli_prints(self):
        # The tooltip on the board, the CLI's die message and this refusal are
        # one sentence. Two wordings for one rule is how a captain ends up
        # unsure which of them is telling the truth.
        for verb, body in LOCKED_VERBS:
            _, payload = self.verb(verb, body)
            self.assertEqual(LINE, payload.get("error"), verb)

    def test_nothing_is_dispatched_behind_the_refusal(self):
        for verb, body in LOCKED_VERBS:
            self.verb(verb, body)
        for key in ("run", "pause", "respond", "approve", "feedback", "log",
                    "resolve"):
            self.assertFalse(self.dispatched(key),
                             "the %s skill ran on someone else's mission" % key)

    def test_the_check_is_LIVE_on_every_request_not_read_off_a_cache(self):
        # A reassignment made on GitHub has to take effect on the NEXT click; a
        # daemon answering from its display cache would keep refusing (or keep
        # allowing) until something else happened to refresh it.
        self.verb("start")
        self.verb("respond", {"answer": "x"})
        with open(self.calls) as fh:
            asked = [ln for ln in fh.read().splitlines()
                     if ln.startswith("lock-reason")]
        self.assertGreaterEqual(len(asked), 2)
        self.assertTrue(all(ln.strip() == "lock-reason 142" for ln in asked),
                        asked)

    def test_reads_are_never_blocked(self):
        # The light lock is a WRITE lock. Looking at someone else's mission —
        # the board, the detail, the activity feed — is never refused.
        for path in ("/api/board", "/api/mission/m-001"):
            url = "http://127.0.0.1:%d%s" % (self.port, path)
            with urllib.request.urlopen(url, timeout=10) as r:
                self.assertEqual(200, r.status, path)

    def test_the_launch_affordance_is_untouched(self):
        # S187's territory. It is not in the locked set, and this session must
        # not quietly annex it.
        status, _ = self.verb("launch/stop")
        self.assertNotEqual(403, status)


class MyOwnMissionIsUntouched(LockBase):
    WHOAMI = ME
    OWNERS = {"142": ME}

    def test_every_write_verb_still_gets_through(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, "%s was wrongly refused" % verb)


class UnassignedIsNeverLocked(LockBase):
    WHOAMI = ME
    OWNERS = {}

    def test_nobody_owns_it_so_nothing_is_refused(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, "%s was refused on an unassigned "
                                             "mission" % verb)


class UnresolvableIdentityIsNeverLocked(LockBase):
    WHOAMI = ""            # gh cannot say who we are
    OWNERS = {"142": OTHER}

    def test_we_do_not_lock_a_captain_out_on_an_identity_we_cannot_read(self):
        # A false lock is strictly worse than the thing the lock prevents: it
        # shuts the captain out of his own work because a network hiccuped.
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, verb)


class NoOwnershipScriptWiredChangesNothing(LockBase):
    """Every pre-S190 caller builds Actions with no `ownership` script — the
    write layer must behave exactly as it did for them."""

    WHOAMI = ME
    OWNERS = {"142": OTHER}

    def setUp(self):
        super().setUp()
        self.actions.scripts.pop("ownership", None)

    def test_writes_are_not_refused_when_the_daemon_has_no_ownership_seam(self):
        for verb, body in LOCKED_VERBS:
            status, _ = self.verb(verb, body)
            self.assertNotEqual(403, status, verb)


class AMissionWithNoIssueIsNeverLocked(LockBase):
    WHOAMI = ME
    OWNERS = {"142": OTHER}

    def setUp(self):
        super().setUp()
        # An unfiled mission has no forge issue, so there is nobody to be its
        # owner and nothing to ask about.
        fx.plant_simple(self.tmp, "m-unfiled", stage="align", issue=None)

    def test_an_unfiled_mission_is_not_refused(self):
        status, _ = self.post("/api/mission/m-unfiled/start")
        self.assertNotEqual(403, status)

    def test_and_no_forge_question_is_asked_about_it(self):
        self.post("/api/mission/m-unfiled/start")
        asked = ""
        if os.path.exists(self.calls):
            with open(self.calls) as fh:
                asked = fh.read()
        self.assertNotIn("lock-reason", asked)


class TheEnforceKillSwitchStillWorks(LockBase):
    WHOAMI = ME
    OWNERS = {"142": OTHER}

    def test_LCARS_OWNER_ENFORCE_0_is_honoured_through_the_daemon(self):
        # The stub cannot see the env var (it hard-codes the verdict), so drive
        # the REAL library here: this is the one case that must be proven
        # against the shipped ownership.sh, because a kill switch that only the
        # stub honours is not a kill switch.
        real = os.path.normpath(os.path.join(
            HERE, "..", "..", "skills", "lcars-run", "ownership.sh"))
        if not os.path.isfile(real):
            self.skipTest("the shipped ownership.sh is not in this checkout")
        self.actions.scripts["ownership"] = real
        prev = os.environ.get("LCARS_OWNER_ENFORCE")
        os.environ["LCARS_OWNER_ENFORCE"] = "0"
        try:
            status, _ = self.verb("start")
            self.assertNotEqual(403, status)
        finally:
            if prev is None:
                os.environ.pop("LCARS_OWNER_ENFORCE", None)
            else:
                os.environ["LCARS_OWNER_ENFORCE"] = prev


if __name__ == "__main__":
    unittest.main()
