"""S160 — the base-freshness verdict, made visible on the viewscreen.

THE PROBLEM. S158 (file time) and S159 (drive time) print their warning to
stdout. The daemon dispatches file.sh through `_run`/`_spawn`, so a captain
filing FROM THE BOARD never sees a word of it — the guard exists and is
invisible on the surface missions are actually filed from.

Covered here:
  • the ADDITIVE card key: `card.baseFreshness` present ONLY when the record's
    carried `loud` is true, ABSENT otherwise — a board with no loud record is
    BYTE-IDENTICAL to pre-S160;
  • LOUDNESS IS CARRIED, NOT DERIVED. Two `unknown` records, one loud (origin
    unreachable) and one quiet (a local-only repo), must surface differently.
    A verdict allowlist — the shape this session was first specified with —
    provably cannot tell those apart, which is exactly why S158 made `loud` a
    field;
  • `behindBy: null` (never measured) is passed through as null, never as a
    reassuring 0;
  • `GET /api/base-freshness` — a READ. It reports the live verdict, it works on
    a read-only board (403s nothing), and running it leaves the repo untouched
    (proven against a REAL git clone with a REAL local bare origin);
  • the front-end surfaces via the node-vm harness (board_basefresh_harness.js):
    the compact card badge, the detail line, and the File-console PRE-FLIGHT
    line — which appears only on a loud verdict, carries the record's own words,
    and never blocks or walls off filing.

stdlib only; no model/gh/worker spend anywhere.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.github_adapter import GitHubAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
_HARNESS = os.path.join(_HERE, "board_basefresh_harness.js")
_REPO_ROOT = os.path.normpath(os.path.join(_HERE, "..", ".."))
_REPORTER = os.path.join(_REPO_ROOT, "skills", "lcars-init", "base-freshness.sh")


# --- canonical records, exactly as lcars_base_state_json emits them ---------
# A dirty tree that forbids the fast-forward: the base stays behind and there IS
# something for the captain to do.
STALE_DIRTY = {
    "verdict": "stale", "loud": True,
    "reason": "the working tree has 1 modified file — LCARS never writes into a "
              "dirty tree, so your own uncommitted work was not touched and "
              "'main' was left 19 commit(s) behind origin.",
    "fix": "git stash && git pull --ff-only origin main",
    "fixNote": "You can commit your work instead of stashing — either clears "
               "the block; 'git stash pop' brings a stash back afterwards.",
    "blocker": "dirty-tree",
    "behindBy": 19, "aheadBy": 0, "baseSha": "abc1234",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": False,
}
# LCARS brought it up to date. Nothing to say.
UPDATED = {
    "verdict": "updated", "loud": False,
    "reason": "fast-forwarded 'main' 19 commit(s) from origin.",
    "fix": "", "fixNote": "", "blocker": "",
    "behindBy": 19, "aheadBy": 0, "baseSha": "def5678",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}
CURRENT = {
    "verdict": "current", "loud": False,
    "reason": "local 'main' is exactly origin's 'main'.",
    "fix": "", "fixNote": "", "blocker": "",
    "behindBy": 0, "aheadBy": 0, "baseSha": "def5678",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}
# The pair that breaks a verdict allowlist: same word, opposite loudness.
UNKNOWN_QUIET = {
    "verdict": "unknown", "loud": False,
    "reason": "this repo has no 'origin' remote — there is nothing to be stale "
              "against.",
    "fix": "", "fixNote": "", "blocker": "",
    "behindBy": None, "aheadBy": None, "baseSha": "aaa1111",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}
UNKNOWN_LOUD = {
    "verdict": "unknown", "loud": True,
    "reason": "could not fetch from origin (offline, auth, or the remote is "
              "unreachable) — LCARS could not check whether 'main' is behind.",
    "fix": "",
    "fixNote": "reach origin first (VPN / network / auth); once it answers, "
               "'git fetch origin main' measures 'main' again.",
    "blocker": "unreachable",
    "behindBy": None, "aheadBy": None, "baseSha": "aaa1111",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}
# ROUND 2, D1 — git REFUSED the purely local fast-forward LCARS attempted
# (`merge.verifySignatures=true`). The record quotes the refusal and offers NO
# command: the merge LCARS just watched fail is not its own remedy.
MERGE_REFUSED = {
    "verdict": "stale", "loud": True,
    "reason": "'main' is 2 commit(s) behind origin and the LOCAL fast-forward "
              "onto the already-fetched origin/main failed (fatal: Commit "
              "79ce589 does not have a GPG signature.) — the ref was not moved "
              "and your tree was not written to.",
    "fix": "",
    "fixNote": "git refused this merge itself, so there is no command LCARS can "
               "offer: running the same merge again only repeats the refusal. "
               "Clear whatever git objected to — its own words are in the "
               "reason above — and 'main' fast-forwards on the next filing.",
    "blocker": "merge-refused",
    "behindBy": 2, "aheadBy": 0, "baseSha": "ed1a292",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": None,
}
# ROUND 3, D2 — the BOUNDED fetch ran past LCARS's own deadline while origin
# answered a ref listing instantly. A separate blocker from `unreachable`
# because the situations are separate: nothing refused this operation on its
# merits, so the captain's unbounded run of it really can succeed — which is
# why this is the one "could not measure" lane that still carries a `fix`.
FETCH_TIMEOUT = {
    "verdict": "unknown", "loud": True,
    "reason": "fetching origin/main timed out after 8s (set "
              "LCARS_BASE_FETCH_TIMEOUT_SECS to change that), but origin "
              "ANSWERED a plain ref listing straight away — it is reachable, "
              "just slower than LCARS is willing to make you wait, so 'main' "
              "was not measured.",
    "fix": "git fetch origin main",
    "fixNote": "origin is reachable, just slower than LCARS waits — raising "
               "LCARS_BASE_FETCH_TIMEOUT_SECS and re-filing works too.",
    "blocker": "fetch-timeout",
    "behindBy": None, "aheadBy": None, "baseSha": "aaa1111",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}
# ROUND 2, D2 — git is MID-REBASE. Nothing was measured, and `baseSha` is null
# because naming a commit the Mission was not cut from is a PERMANENT wrong
# provenance record — the defect this round exists to prevent.
IN_PROGRESS = {
    "verdict": "unknown", "loud": True,
    "reason": "an unfinished git rebase is in progress here, with HEAD "
              "detached at 79ce589, and 1 path(s) are still unmerged — the "
              "refs are mid-move, so LCARS measured nothing against origin and "
              "did nothing of its own. Finish or abandon the rebase and the "
              "check runs normally again.",
    "fix": "",
    "fixNote": "only you can decide how this ends: resolve the conflicted "
               "path(s), 'git add' them and 'git rebase --continue', or 'git "
               "rebase --abort' to put the branch back exactly where it "
               "started. Either one clears this.",
    "blocker": "operation-in-progress",
    "behindBy": None, "aheadBy": None, "baseSha": None,
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": None,
}
# A logged bug: its base IS its parent's branch. LCARS takes no position.
CHILD_BASE = {
    "verdict": "child-base", "loud": False,
    "reason": "'lcars/lcars-20260730-001' is an LCARS Mission branch, not a "
              "trunk — this Mission is based on another Mission's work (a logged "
              "bug's fix belongs on its parent's branch), so there is nothing to "
              "bring down from origin. Nothing was fetched and no ref was moved.",
    "fix": "", "fixNote": "", "blocker": "",
    "behindBy": None, "aheadBy": None, "baseSha": "bbb2222",
    "checkedAt": "2026-07-31T09:00:00Z", "missionBranchAtBase": True,
}


def _plant(root, mid="m-001", record=None, **kw):
    """Plant a mission and (optionally) stamp a baseFreshness record on it."""
    fx.plant_simple(root, mid, **kw)
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        state = json.load(fh)
    if record is not None:
        state["baseFreshness"] = record
    else:
        state.pop("baseFreshness", None)
    with open(path, "w") as fh:
        fh.write(json.dumps(state, indent=2) + "\n")
    return path


def _reporter_stub(tmp, payload=None, exit_code=0, stdout=None):
    """A stub base-freshness.sh printing `payload` for --json.

    It also RECORDS its argv + cwd, so a test can prove the daemon asked the
    shared reporter (never a Python reimplementation of the verdict).
    """
    rec = os.path.join(tmp, "rec-basefresh.txt")
    path = os.path.join(tmp, "basefresh-stub.sh")
    body = stdout if stdout is not None else (
        json.dumps(payload) if payload is not None else "")
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 "printf 'argv=%s cwd=%s\\n' \"$*\" \"$PWD\" >>'" + rec + "'\n"
                 "printf '%s\\n' '" + body.replace("'", "'\"'\"'") + "'\n"
                 "exit " + str(exit_code) + "\n")
    os.chmod(path, 0o755)
    return path, rec


def _run_harness(mode, payload, readonly=False):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(payload, fh)
        arg = fh.name
    try:
        cmd = ["node", _HARNESS, mode, arg]
        if readonly:
            cmd.append("readonly")
        proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
        if proc.returncode != 0:
            raise AssertionError("harness failed: %s"
                                 % proc.stderr.decode("utf-8", "replace"))
        return json.loads(proc.stdout.decode("utf-8"))
    finally:
        os.unlink(arg)


def _texts(node):
    """Every text string in the projected subtree."""
    out = []
    if not node:
        return out
    if node.get("text"):
        out.append(node["text"])
    for c in node.get("children") or []:
        out.extend(_texts(c))
    return out


def _find(node, pred):
    if not node:
        return None
    if pred(node):
        return node
    for c in node.get("children") or []:
        hit = _find(c, pred)
        if hit:
            return hit
    return None


def _find_all(node, pred):
    out = []
    if not node:
        return out
    if pred(node):
        out.append(node)
    for c in node.get("children") or []:
        out.extend(_find_all(c, pred))
    return out


def _has_class(node, cls):
    return cls in (node.get("cls") or "").split()


# ══════════════════════════════════════════════════════════════════════════
class TestCardPayload(unittest.TestCase):
    """The ADDITIVE card key. Present ONLY when the record is loud."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _card(self, record):
        _plant(self.tmp, "m-001", record=record)
        return LocalAdapter(self.tmp).board()["missions"][0]

    def test_no_record_at_all_has_no_key(self):
        self.assertNotIn("baseFreshness", self._card(None))

    def test_quiet_record_has_no_key(self):
        for rec in (CURRENT, UPDATED, UNKNOWN_QUIET, CHILD_BASE):
            with self.subTest(verdict=rec["verdict"]):
                self.assertNotIn("baseFreshness", self._card(rec))

    def test_a_quiet_record_leaves_the_card_BYTE_IDENTICAL(self):
        """The invariant: an unaffected board renders exactly as pre-S160.

        Not "has no extra key" — the whole serialized card, byte for byte,
        against the same mission with no record on disk at all. The one field
        pinned first is `activeSecondsAt`: it is deliberately the server's live
        wall-clock (BUG-047's anchor for the front-end tick), so it differs
        between any two renders and would mask the comparison rather than
        inform it.
        """
        def dump(rec):
            card = self._card(rec)
            card["activeSecondsAt"] = 0
            return json.dumps(card, sort_keys=True)

        baseline = dump(None)
        for rec in (CURRENT, UPDATED, UNKNOWN_QUIET, CHILD_BASE):
            with self.subTest(verdict=rec["verdict"]):
                shutil.rmtree(os.path.join(self.tmp, ".git"), ignore_errors=True)
                self.assertEqual(dump(rec), baseline)

    def test_loud_record_surfaces_carrying_its_own_reason(self):
        bf = self._card(STALE_DIRTY)["baseFreshness"]
        self.assertEqual(bf["verdict"], "stale")
        self.assertIs(bf["loud"], True)
        # VERBATIM — the surface displays the guard's sentence, it does not
        # compose a second one about git state.
        self.assertEqual(bf["reason"], STALE_DIRTY["reason"])
        self.assertEqual(bf["fix"], STALE_DIRTY["fix"])
        # S160 fix-loop: the two fields the guard added ride through untouched
        # too — `blocker` (what the badge headline is built from) and `fixNote`
        # (the prose that used to be smuggled into `fix`).
        self.assertEqual(bf["blocker"], "dirty-tree")
        self.assertEqual(bf["fixNote"], STALE_DIRTY["fixNote"])
        self.assertEqual(bf["behindBy"], 19)

    def test_the_case_a_verdict_allowlist_gets_WRONG(self):
        """Two `unknown` records; only the loud one may surface.

        This is the whole reason loudness is a carried field. Any gate keyed on
        the verdict NAME answers both of these the same way and is wrong about
        one of them, always.
        """
        self.assertNotIn("baseFreshness", self._card(UNKNOWN_QUIET))
        shutil.rmtree(os.path.join(self.tmp, ".git"), ignore_errors=True)
        loud = self._card(UNKNOWN_LOUD)
        self.assertIn("baseFreshness", loud)
        self.assertEqual(loud["baseFreshness"]["verdict"], "unknown")

    def test_behindBy_null_stays_null_and_never_becomes_zero(self):
        bf = self._card(UNKNOWN_LOUD)["baseFreshness"]
        self.assertIsNone(bf["behindBy"])
        self.assertIsNone(bf["aheadBy"])
        self.assertNotEqual(bf["behindBy"], 0)

    def test_a_child_base_record_takes_no_position(self):
        """A logged bug's base is its parent's branch — not a fault to report.

        It is carried QUIET by the guard, so the card says nothing at all: LCARS
        has no opinion about a parent Mission's branch, and inventing a badge
        here would be inventing one.
        """
        card = self._card(CHILD_BASE)
        self.assertNotIn("baseFreshness", card)

    def test_a_malformed_record_is_ignored_not_crashed_on(self):
        for junk in ("stale", 42, [], {"loud": True}, {"verdict": "stale"}):
            with self.subTest(junk=junk):
                shutil.rmtree(os.path.join(self.tmp, ".git"), ignore_errors=True)
                card = self._card(junk)
                self.assertIsNotNone(card)
                if isinstance(junk, dict) and junk.get("loud") is True:
                    # loud but shapeless: it surfaces, with nulls, never a crash
                    self.assertIn("baseFreshness", card)
                else:
                    self.assertNotIn("baseFreshness", card)

    def test_the_detail_payload_carries_it_too(self):
        _plant(self.tmp, "m-001", record=STALE_DIRTY)
        detail = LocalAdapter(self.tmp).mission("m-001")
        self.assertEqual(detail["baseFreshness"]["reason"], STALE_DIRTY["reason"])

    def test_the_github_adapter_shape_is_untouched(self):
        gh = GitHubAdapter(repo="o/r", gh_bin="/bin/true")
        issue = {"number": 3, "title": "t", "labels": [],
                 "createdAt": "2026-07-31T00:00:00Z"}
        card = gh._card(issue, [issue])
        self.assertNotIn("baseFreshness", card)


# ══════════════════════════════════════════════════════════════════════════
class TestAdapterReader(unittest.TestCase):
    """LocalAdapter.base_freshness() — the daemon SHELLS the shared reporter."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        _plant(self.tmp, "m-001")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_it_returns_the_record_the_reporter_printed(self):
        stub, _ = _reporter_stub(self.tmp, STALE_DIRTY)
        rec = LocalAdapter(self.tmp, base_freshness_script=stub).base_freshness()
        self.assertEqual(rec["reason"], STALE_DIRTY["reason"])
        self.assertIs(rec["loud"], True)

    def test_it_asks_the_shared_reporter_with_json_in_the_repo(self):
        stub, recfile = _reporter_stub(self.tmp, CURRENT)
        LocalAdapter(self.tmp, base_freshness_script=stub).base_freshness()
        with open(recfile) as fh:
            line = fh.read()
        self.assertIn("argv=--json", line)
        cwd = line.split("cwd=", 1)[1].strip()
        self.assertEqual(os.path.realpath(cwd), os.path.realpath(self.tmp))

    def test_any_failure_degrades_to_None_never_into_the_response(self):
        for kw in ({"exit_code": 1}, {"stdout": "not json"}, {"stdout": ""},
                   {"stdout": "[1,2,3]"}, {"stdout": '{"loud": true}'}):
            with self.subTest(**kw):
                stub, _ = _reporter_stub(self.tmp, **kw)
                self.assertIsNone(
                    LocalAdapter(self.tmp, base_freshness_script=stub)
                    .base_freshness())

    def test_a_missing_reporter_degrades_to_None(self):
        adapter = LocalAdapter(self.tmp,
                               base_freshness_script="/no/such/reporter.sh")
        self.assertIsNone(adapter.base_freshness())

    def test_it_is_NOT_folded_into_the_board_meta(self):
        """A board render must not pay for a network fetch.

        The pre-flight is its own endpoint precisely so the Kanban board — which
        re-renders on every SSE push — never triggers a `git fetch`.
        """
        stub, recfile = _reporter_stub(self.tmp, STALE_DIRTY)
        meta = LocalAdapter(self.tmp, base_freshness_script=stub).board()["meta"]
        self.assertNotIn("baseFreshness", meta)
        self.assertFalse(os.path.exists(recfile))


# ══════════════════════════════════════════════════════════════════════════
class TestEndpoint(unittest.TestCase):
    """GET /api/base-freshness — a read, on every build that can answer it."""

    read_only = False

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        _plant(self.tmp, "m-001")
        self.stub, self.recfile = _reporter_stub(self.tmp, STALE_DIRTY)
        self.adapter = LocalAdapter(self.tmp, read_only=self.read_only,
                                    base_freshness_script=self.stub)
        # actions=None → the READ-ONLY / view-only daemon shape (every POST 403s).
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _get(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_it_reports_the_live_verdict(self):
        status, body = self._get("/api/base-freshness")
        self.assertEqual(status, 200)
        self.assertEqual(body["baseFreshness"]["reason"], STALE_DIRTY["reason"])

    def test_it_is_a_READ_and_403s_nothing_on_a_view_only_daemon(self):
        """actions=None is the shape where every WRITE is 403'd. This is not a
        write: a captain looking at a view-only board still gets the truth."""
        status, _ = self._get("/api/base-freshness")
        self.assertEqual(status, 200)

    def test_a_reporter_failure_answers_null_not_a_500(self):
        stub, _ = _reporter_stub(self.tmp, exit_code=3, stdout="kaboom")
        self.adapter._base_freshness_script = stub
        status, body = self._get("/api/base-freshness")
        self.assertEqual(status, 200)
        self.assertIsNone(body["baseFreshness"])


class TestEndpointOnReadOnlyBoard(TestEndpoint):
    """The `--read-only` LOCAL build: same answer, still 200."""
    read_only = True


class TestEndpointOnGitHubBoard(unittest.TestCase):
    """A forge-backed board cannot see a local checkout — so it 404s, cleanly."""

    def setUp(self):
        self.adapter = GitHubAdapter(repo="o/r", gh_bin="/bin/true")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def test_404_not_a_stack_trace(self):
        url = "http://127.0.0.1:%d/api/base-freshness" % self.port
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                self.fail("expected 404, got %s" % r.status)
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)
            self.assertIn("error", json.loads(e.read()))


# ══════════════════════════════════════════════════════════════════════════
def _git(cwd, *args):
    return subprocess.run(("git",) + args, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=60)


def _git_out(cwd, *args):
    return _git(cwd, *args).stdout.decode("utf-8", "replace").strip()


@unittest.skipUnless(shutil.which("git"), "git not available")
class TestEndpointDoesNotMutate(unittest.TestCase):
    """The whole point of the pre-flight, end to end, against REAL git.

    The console fires this before the captain has typed a word. A question whose
    asking fast-forwards the captain's checkout is not a question — so the base
    ref, HEAD, and the working tree must be bit-for-bit identical afterwards,
    even though the repo really IS behind a real (local, bare) origin.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        bare = os.path.join(self.tmp, "origin.git")
        seed = os.path.join(self.tmp, "seed")
        self.repo = os.path.join(self.tmp, "clone")
        _git(self.tmp, "init", "-q", "--bare", bare)
        _git(self.tmp, "init", "-q", seed)
        _git(seed, "config", "user.email", "t@t")
        _git(seed, "config", "user.name", "t")
        _git(seed, "checkout", "-q", "-b", "main")
        with open(os.path.join(seed, "README.md"), "w") as fh:
            fh.write("base\n")
        _git(seed, "add", "-A")
        _git(seed, "commit", "-q", "-m", "init")
        _git(seed, "remote", "add", "origin", bare)
        _git(seed, "push", "-q", "-u", "origin", "main")
        _git(bare, "symbolic-ref", "HEAD", "refs/heads/main")
        _git(self.tmp, "clone", "-q", bare, self.repo)
        _git(self.repo, "config", "user.email", "t@t")
        _git(self.repo, "config", "user.name", "t")
        # …now push 5 commits the clone has never seen.
        for i in range(5):
            with open(os.path.join(seed, "only-on-origin.txt"), "a") as fh:
                fh.write("line %d\n" % i)
            _git(seed, "add", "-A")
            _git(seed, "commit", "-q", "-m", "origin %d" % i)
        _git(seed, "push", "-q", "origin", "main")

        _plant(self.repo, "m-001")
        self.adapter = LocalAdapter(self.repo, base_freshness_script=_REPORTER)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _snapshot(self):
        return (
            _git_out(self.repo, "rev-parse", "HEAD"),
            _git_out(self.repo, "rev-parse", "refs/heads/main"),
            _git_out(self.repo, "symbolic-ref", "-q", "HEAD"),
            _git_out(self.repo, "status", "--porcelain"),
            sorted(os.listdir(self.repo)),
        )

    def test_the_endpoint_measures_without_moving_anything(self):
        before = self._snapshot()
        url = "http://127.0.0.1:%d/api/base-freshness" % self.port
        with urllib.request.urlopen(url, timeout=60) as r:
            body = json.loads(r.read())
        bf = body["baseFreshness"]
        self.assertIsNotNone(bf, "the reporter must answer against a real repo")
        # it really did measure…
        self.assertEqual(bf["behindBy"], 5)
        self.assertEqual(bf["verdict"], "stale")
        # …and it CANNOT report `updated`: that word means a ref moved.
        self.assertNotEqual(bf["verdict"], "updated")
        # …and nothing moved.
        self.assertEqual(self._snapshot(), before)
        self.assertFalse(
            os.path.exists(os.path.join(self.repo, "only-on-origin.txt")),
            "origin's file must NOT have been written into the captain's tree")

    def test_a_clean_ff_able_base_is_carried_QUIET(self):
        """Behind, clean, fast-forwardable — and there is nothing to tell the
        captain: FILING is what fixes this one. A warning whose only remedy is
        the action you were already taking is noise."""
        url = "http://127.0.0.1:%d/api/base-freshness" % self.port
        with urllib.request.urlopen(url, timeout=60) as r:
            bf = json.loads(r.read())["baseFreshness"]
        self.assertIs(bf["loud"], False)


# ══════════════════════════════════════════════════════════════════════════
class TestCardBadgeRender(unittest.TestCase):
    """The SHIPPING board.js card badge."""

    def _card(self, mission):
        return _run_harness("card", {"mission": mission})["node"]

    def _badge(self, node):
        return _find(node, lambda n: _has_class(n, "basefresh"))

    def test_no_key_no_badge(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align"})
        self.assertIsNone(self._badge(node))

    def test_a_loud_record_renders_an_amber_badge(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": STALE_DIRTY})
        badge = self._badge(node)
        self.assertIsNotNone(badge)
        self.assertIn("BASE", badge["text"])
        self.assertIn("19", badge["text"])

    def test_the_badge_carries_the_records_OWN_reason_as_its_tooltip(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": STALE_DIRTY})
        self.assertIn(STALE_DIRTY["reason"], self._badge(node)["title"])

    def test_behindBy_null_never_renders_as_zero(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": UNKNOWN_LOUD})
        badge = self._badge(node)
        self.assertIsNotNone(badge)
        self.assertNotIn("0", badge["text"])
        self.assertIn(UNKNOWN_LOUD["reason"], badge["title"])

    def test_a_forced_child_base_badge_blames_nobody(self):
        """child-base is carried quiet, so this cannot happen through the
        adapter — but if a record ever arrives loud, the copy must still say
        'this Mission is based on another Mission' and NOT 'stale'."""
        forced = dict(CHILD_BASE, loud=True)
        node = self._card({"id": "m-001", "title": "T", "stage": "plan",
                           "baseFreshness": forced})
        badge = self._badge(node)
        self.assertIsNotNone(badge)
        self.assertNotIn("STALE", badge["text"].upper())
        self.assertIn("PARENT", badge["text"].upper())

    # ── S160 fix-loop, P2: the headline names what is BLOCKING ────────────
    # `⚠ BASE · 1 BEHIND` on a dirty-and-behind base names the half the captain
    # was ruled safe to ignore — and has trained themselves to ignore — while
    # the dirty tree that actually stopped the fast-forward lived only in the
    # body text. The badge must lead with the blocker.

    def test_the_headline_names_the_dirty_tree_not_just_the_distance(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": STALE_DIRTY})
        text = self._badge(node)["text"].upper()
        self.assertIn("DIRTY TREE", text)
        # the distance is still there — nothing was lost, it just stopped
        # being the headline.
        self.assertIn("19", text)
        self.assertLess(text.index("DIRTY"), text.index("19"),
                        "the blocker must come BEFORE the commit count")

    def test_the_headline_does_not_lead_with_the_count_when_blocked(self):
        """The exact tester scenario: dirty AND only 1 behind. `1 BEHIND` alone
        reads as the harmless state; it must not be the whole headline."""
        rec = dict(STALE_DIRTY, behindBy=1)
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": rec})
        text = self._badge(node)["text"].upper()
        self.assertIn("DIRTY TREE", text)
        self.assertNotEqual(text.strip(), "⚠ BASE · 1 BEHIND")

    def test_an_unreachable_origin_headline_says_so(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": UNKNOWN_LOUD})
        self.assertIn("UNREACHABLE", self._badge(node)["text"].upper())

    # ── S160 round 3, D2: a timeout is not unreachability ─────────────────
    # The timeout lane recorded `blocker: ""`, so the badge fell back to the
    # generic `⚠ BASE UNVERIFIED` — honest, but it names nothing, while its
    # `unreachable` sibling names itself. They are genuinely different: there
    # the remote failed on its merits; here LCARS gave up waiting on its own
    # bounded fetch, which is exactly why this lane still offers a command.

    def test_a_fetch_timeout_names_itself_not_the_generic_headline(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": FETCH_TIMEOUT})
        text = self._badge(node)["text"].upper()
        self.assertIn("TIMED OUT", text)
        self.assertNotIn("UNVERIFIED", text)
        # Nothing was measured, so no distance may be shown.
        self.assertNotIn("BEHIND", text)

    def test_a_fetch_timeout_is_not_called_unreachable(self):
        """Origin ANSWERED — telling the captain it is unreachable is the
        copy-that-lies class, and it would contradict the offered command."""
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": FETCH_TIMEOUT})
        self.assertNotIn("UNREACHABLE", self._badge(node)["text"].upper())

    def test_the_timeout_lane_keeps_its_runnable_fix(self):
        """The asymmetry with `unreachable` IS the reason for two tokens: this
        lane offers a command the captain can run, and that one cannot."""
        timed = self._card({"id": "m-001", "title": "T", "stage": "align",
                            "baseFreshness": FETCH_TIMEOUT})
        self.assertIn("Fix: git fetch origin main",
                      self._badge(timed)["title"])
        dead = self._card({"id": "m-002", "title": "T", "stage": "align",
                           "baseFreshness": UNKNOWN_LOUD})
        self.assertNotIn("Fix:", self._badge(dead)["title"])

    def test_an_unknown_blocker_token_falls_back_never_invents(self):
        """A token this front end has never heard of (an older or newer LCARS)
        must degrade to the distance, not render a raw token at the captain."""
        rec = dict(STALE_DIRTY, blocker="some-future-lane")
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": rec})
        text = self._badge(node)["text"]
        self.assertNotIn("some-future-lane", text)
        self.assertIn("19", text)

    def test_no_blocker_still_renders_the_old_distance_headline(self):
        rec = dict(STALE_DIRTY, blocker="")
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": rec})
        self.assertIn("19 BEHIND", self._badge(node)["text"].upper())

    # ── S160 round 2, D2: an UNFINISHED git operation gets its own headline ─
    # A rebase stopped on a conflict is the single most important fact about a
    # repo, and it is not a shade of "behind" — nothing was measured at all.

    def test_an_unfinished_operation_gets_its_own_headline(self):
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": IN_PROGRESS})
        text = self._badge(node)["text"].upper()
        self.assertIn("UNFINISHED", text)
        # Never a distance: nothing was measured, so nothing may be shown.
        self.assertNotIn("BEHIND", text)
        self.assertNotIn("0", text)

    def test_the_unfinished_headline_leaves_WHICH_operation_to_the_record(self):
        """One generic token covers rebase / merge / cherry-pick / revert /
        bisect; which one it is belongs to the guard's own sentence, not to a
        badge that would have to keep a second vocabulary in sync."""
        node = self._card({"id": "m-001", "title": "T", "stage": "align",
                           "baseFreshness": IN_PROGRESS})
        badge = self._badge(node)
        self.assertNotIn("REBASE", badge["text"].upper())
        self.assertIn("unfinished git rebase", badge["title"])

    def test_the_badge_survives_a_read_only_board(self):
        node = _run_harness("card",
                            {"mission": {"id": "m-001", "title": "T",
                                         "stage": "align",
                                         "baseFreshness": STALE_DIRTY}},
                            readonly=True)["node"]
        self.assertIsNotNone(self._badge(node))


class TestDetailRender(unittest.TestCase):
    """The detail line — the badge's long form, with the fix."""

    def _detail(self, mission):
        return _run_harness("detail", {"mission": mission})["node"]

    def test_absent_when_the_card_has_no_record(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": []})
        self.assertIsNone(_find(node, lambda n: _has_class(n, "det-basefresh")))

    def test_it_carries_the_reason_AND_the_fix_verbatim(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": STALE_DIRTY})
        line = _find(node, lambda n: _has_class(n, "det-basefresh"))
        self.assertIsNotNone(line)
        blob = " ".join(_texts(line))
        self.assertIn(STALE_DIRTY["reason"], blob)
        self.assertIn(STALE_DIRTY["fix"], blob)

    def test_a_record_with_no_fix_shows_no_empty_fix_row(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [],
                             "baseFreshness": dict(UNKNOWN_LOUD, fix="")})
        line = _find(node, lambda n: _has_class(n, "det-basefresh"))
        self.assertIsNotNone(line)
        self.assertIsNone(_find(line, lambda n: _has_class(n, "bf-fix")))

    # ── S160 fix-loop, P3: `Fix:` labels a COMMAND, and only a command ────
    # A tester pasted the old strings into a shell:
    #   `git stash -u   (or commit your work)   then   git pull --ff-only …`
    #     → bash: syntax error near unexpected token `(`, exit 2
    #   `reach origin first (VPN / network / auth) — then   git fetch origin main`
    #     → not a command at all.
    # The guard now keeps `fix` to one runnable line; the prose is `fixNote`,
    # rendered UNLABELLED so nothing dresses it as something to run.

    def test_the_fix_row_holds_only_the_command(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": STALE_DIRTY})
        fix = _find(node, lambda n: _has_class(n, "bf-fix"))
        self.assertIsNotNone(fix)
        text = " ".join(_texts(fix))
        self.assertIn(STALE_DIRTY["fix"], text)
        # nothing but the label and the command — no parenthetical, no prose.
        self.assertEqual(text.replace("Fix: ", "").strip(),
                         STALE_DIRTY["fix"])
        self.assertNotIn("(", text)

    def test_the_note_is_rendered_but_never_labelled_as_a_fix(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": STALE_DIRTY})
        note = _find(node, lambda n: _has_class(n, "bf-note"))
        self.assertIsNotNone(note, "the guidance must still reach the captain")
        text = " ".join(_texts(note))
        self.assertIn("commit your work", text)
        self.assertNotIn("Fix:", text)

    def test_a_note_with_no_command_shows_no_fix_row_at_all(self):
        """The unreachable lane: guidance, and NOTHING labelled `Fix:` — because
        no command run from this repo can bring origin back."""
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": UNKNOWN_LOUD})
        self.assertIsNone(_find(node, lambda n: _has_class(n, "bf-fix")))
        note = _find(node, lambda n: _has_class(n, "bf-note"))
        self.assertIsNotNone(note)
        self.assertIn("reach origin first", " ".join(_texts(note)))

    # ── S160 round 2, D1: the operation LCARS already ran is never the Fix ──
    # A tester set `merge.verifySignatures=true`, filed, and pasted the offered
    # fix. It answered `fatal: Commit 79ce589 does not have a GPG signature.` —
    # byte-identical to the failure LCARS had captured into its own `reason` one
    # second earlier. The board must have nothing to label `Fix:` here.

    def test_a_refused_merge_offers_NO_command_to_re_run_it(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": MERGE_REFUSED})
        line = _find(node, lambda n: _has_class(n, "det-basefresh"))
        self.assertIsNotNone(line)
        self.assertIsNone(_find(line, lambda n: _has_class(n, "bf-fix")),
                          "the merge git just refused is not its own remedy")
        blob = " ".join(_texts(line))
        self.assertNotIn("Fix:", blob)
        self.assertNotIn("git merge", blob)

    def test_a_refused_merge_still_tells_the_captain_what_to_do(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": MERGE_REFUSED})
        note = _find(node, lambda n: _has_class(n, "bf-note"))
        self.assertIsNotNone(note)
        text = " ".join(_texts(note))
        self.assertIn("git refused this merge itself", text)
        self.assertNotIn("Fix:", text)
        # git's own words are still on the surface — in the reason, where the
        # guard put them.
        why = _find(node, lambda n: _has_class(n, "bf-why"))
        self.assertIn("GPG signature", " ".join(_texts(why)))

    def test_an_unfinished_operation_offers_no_command_either(self):
        """`git pull --rebase origin main` was re-offered mid-rebase and now
        hard-`fatal`s. A fix that cannot succeed is not a fix."""
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [], "baseFreshness": IN_PROGRESS})
        self.assertIsNone(_find(node, lambda n: _has_class(n, "bf-fix")))
        note = _find(node, lambda n: _has_class(n, "bf-note"))
        self.assertIsNotNone(note)
        text = " ".join(_texts(note))
        self.assertIn("rebase --continue", text)
        self.assertIn("rebase --abort", text)

    def test_no_note_no_note_row(self):
        node = self._detail({"id": "m-001", "title": "T", "stage": "align",
                             "activity": [],
                             "baseFreshness": dict(STALE_DIRTY, fixNote="")})
        self.assertIsNone(_find(node, lambda n: _has_class(n, "bf-note")))


class TestFileConsolePreflight(unittest.TestCase):
    """The pre-flight line: named BEFORE the idea is typed, never a wall."""

    def _console(self, preflight, fails=False, readonly=False):
        return _run_harness("file", {"mission": {}, "preflight": preflight,
                                     "preflightFails": fails}, readonly=readonly)

    def _line(self, out):
        return _find(out["node"], lambda n: _has_class(n, "file-basefresh"))

    def test_it_asks_the_endpoint_when_the_console_opens(self):
        out = self._console(STALE_DIRTY)
        self.assertIn("/api/base-freshness", [f["url"] for f in out["fetches"]])
        self.assertTrue(all(f["method"] == "GET" for f in out["fetches"]
                            if f["url"] == "/api/base-freshness"))

    def test_a_loud_verdict_shows_the_line_with_the_records_words(self):
        line = self._line(self._console(STALE_DIRTY))
        self.assertIsNotNone(line)
        self.assertFalse(line["hidden"])
        blob = " ".join(_texts(line))
        self.assertIn(STALE_DIRTY["reason"], blob)
        self.assertIn(STALE_DIRTY["fix"], blob)

    def test_a_quiet_verdict_shows_NOTHING(self):
        for rec in (CURRENT, UPDATED, UNKNOWN_QUIET, CHILD_BASE):
            with self.subTest(verdict=rec["verdict"]):
                line = self._line(self._console(rec))
                self.assertTrue(line is None or line["hidden"],
                                "a quiet verdict must not decorate the console")

    def test_the_LOUD_unknown_still_shows_although_it_shares_a_verdict(self):
        """The allowlist trap again, on the console this time."""
        self.assertTrue(self._line(self._console(UNKNOWN_QUIET)) is None
                        or self._line(self._console(UNKNOWN_QUIET))["hidden"])
        loud = self._line(self._console(UNKNOWN_LOUD))
        self.assertIsNotNone(loud)
        self.assertFalse(loud["hidden"])

    def test_a_failed_or_absent_preflight_is_silent_never_an_error(self):
        for payload, fails in ((None, False), (None, True)):
            with self.subTest(fails=fails):
                line = self._line(self._console(payload, fails=fails))
                self.assertTrue(line is None or line["hidden"])

    def test_filing_is_NEVER_blocked_by_the_line(self):
        """Warn loudly, file anyway — the standing captain ruling. The idea box
        and BOTH filing controls are present and enabled on the loudest verdict
        there is, and nothing modal sits between them and the captain."""
        out = self._console(STALE_DIRTY)
        node = out["node"]
        idea = _find(node, lambda n: n["tag"] == "textarea")
        self.assertIsNotNone(idea)
        self.assertFalse(idea["disabled"])
        labels = [b["text"] for b in _find_all(node, lambda n: n["tag"] == "button")]
        park = [t for t in labels if "Backlog" in t]
        align = [t for t in labels if "Begin Alignment" in t]
        self.assertTrue(park, "the park control must still be there: %s" % labels)
        self.assertTrue(align, "the align control must still be there: %s" % labels)
        for b in _find_all(node, lambda n: n["tag"] == "button"):
            self.assertFalse(b["disabled"],
                             "%r was disabled by the warning" % b["text"])

    def _flat(self, out):
        flat = []

        def walk(n):
            flat.append(n)
            for c in n.get("children") or []:
                walk(c)
        walk(out["node"])
        return flat

    # ── S160 round 2, D4: the block MOUNTS BELOW THE IDEA FIELD ────────────
    # Measured in a real Chrome against a real GitHub remote: the console was
    # interactive at 37ms and the amber block landed at 1.3–1.8s, moving the
    # textarea's top from 131px to 300px IN ONE FRAME — a 169px jump under a
    # captain already typing (16.3s against a blackholed origin). Focus and the
    # 52 typed characters survived, so it is cosmetic — but the field must not
    # move out from under a sentence in progress.
    #
    # Reserving the height was the alternative and it is worse: the block is
    # ABSENT on the common quiet path, so a reservation is a permanent empty gap
    # on every healthy repo. Below the field, the only things it can push are
    # the engine picker and the footer.

    def test_the_line_sits_BELOW_the_idea_box(self):
        out = self._console(STALE_DIRTY)
        flat = self._flat(out)
        idx_line = next(i for i, n in enumerate(flat)
                        if _has_class(n, "file-basefresh"))
        idx_idea = next(i for i, n in enumerate(flat) if n["tag"] == "textarea")
        self.assertGreater(idx_line, idx_idea,
                           "an async block above the field reflows it mid-type")

    def test_it_is_still_ON_the_console_before_the_filing_controls(self):
        """Below the field is not below the fold: it must still be read before
        the captain commits to filing."""
        out = self._console(STALE_DIRTY)
        flat = self._flat(out)
        idx_line = next(i for i, n in enumerate(flat)
                        if _has_class(n, "file-basefresh"))
        buttons = [i for i, n in enumerate(flat) if n["tag"] == "button"]
        self.assertTrue(buttons)
        self.assertLess(idx_line, max(buttons))

    def test_the_console_reserves_NO_space_on_the_quiet_path(self):
        """A placeholder holding the block's height would be a permanent empty
        gap on every healthy repo — the block is absent entirely there."""
        line = self._line(self._console(CURRENT))
        self.assertTrue(line is None or line["hidden"])
        if line is not None:
            self.assertEqual(line.get("children") or [], [])


if __name__ == "__main__":
    unittest.main()
