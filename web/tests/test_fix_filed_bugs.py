"""S163 — the "Fix Filed Bugs" follow-through.

S161 moved the authored bug PRDs into a daemon-side session; S162 let the captain
close the console and watch the parent card file them. This session gives that
card the way FORWARD: once the batch is filed, the card offers to reopen the cost
review the captain skipped by closing the window, and the SAME `Go ▸` in that
restored panel dispatches the batch.

The window it owns is narrow and named: **filed, not yet dispatched**. Before this
session the card's only control there was S77's disabled `◐ resolving N logged
bugs…` — which is derived purely from "the parent has linked, non-done, non-verify
children" and is therefore TRUE the instant filing completes, while BUG-059's hold
means nothing is running and nothing will run without an explicit Go. A dead
button claiming work in flight, and the only control on the card.

So the assertions come in pairs, because both edges are defects:

  * in the filed-but-not-dispatched window the resolving lock is REPLACED (not
    joined) by a live "⚙ FIX N FILED BUGS";
  * the moment the Go is dispatched the control disappears and the lock RETURNS —
    the children really are being driven then, and suppressing the parent's Merge
    is exactly what that lock is for.

`isResolvingLocked` itself is deliberately UNTOUCHED (it also gates the parent's
Merge/Accept, and in this window that suppression is right anyway): what changes
is the control and its copy, never the predicate.

Three things tell "filed" from "dispatched" apart, and every one of them is a
MEASUREMENT rather than an inference — the children exist in both states, so their
mere presence proves nothing:

  1. the daemon's `logFiling` stamp at status `filed` (the Go CONSUMES the
     session, so a stamp that is still there is proof no Go has been taken);
  2. the client's optimistic `markLogRun` flag (instant, the tab that clicked);
  3. the daemon's additive `logDispatch` stamp (durable for the daemon's life,
     which is exactly long enough to cover the seconds between the Go and
     resolve-logs stamping its children `queued`).

With none of the three — the daemon restarted and its memory went with it — the
fallback reads the DISK signal the local adapter publishes per child
(`queued` / `running`): a batch no driver has ever touched.

────────────────────────────────────────────────────────────────────────────────
S163 fix round 1 (D1). The paragraph above shipped with one word wrong, and it
cost the session its whole point. The third measurement — `logDispatch` — was
IN-MEMORY, so a daemon restart dropped it; and the children fallback that was
supposed to cover exactly that case ALSO read each child's `dispatched` flag,
which `local_adapter._card` computes as `bool(events) or running`. The File &
Cost step runs `run.sh estimate` on every bug it files, and that spawns a worker
whose `usage_capture` hook appends a `worker_usage` line to the child's
events.jsonl. So EVERY freshly filed, never-driven bug child is `dispatched:
true` from birth, the fallback's premise was unreachable, and a restart put the
captain back in the pre-S163 dead end: the disabled "◐ resolving N logged bugs…"
lock, over children nothing was driving.

Two things changed, and both make the distinction a MEASUREMENT the product can
actually take:

  * the dispatch record is now DURABLE — `log_run` writes
    `<parent>/log-dispatch.json` when it spawns resolve-logs, so a RESTARTED
    daemon still knows the Go was taken (`LogDispatchDurabilityTest`);
  * the children fallback no longer reads `dispatched` at all. The signals a
    DRIVER produces are `queued` (resolve-logs stamps every scheduled bug) and
    `running` (a live driver lock); `dispatched` is produced by the ESTIMATOR
    and says nothing about whether anything is being driven.

The fixtures below were corrected with it: `_kid()` now carries `dispatched:
True`, because that is what the LocalAdapter publishes for a filed bug in
production. A test that files bugs and then pretends they carry no events is
testing a repo that cannot exist.
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The S161 daemon fixture, reused verbatim: a real daemon on an ephemeral port,
# a recording log.sh stub that plants children + estimates, and a canned-turn
# split worker. Zero tokens, and the SAME rig S161/S162 proved the seams on — a
# second copy of it is a second set of rules waiting to drift.
from tests.test_log_session import (  # noqa: E402
    BUG_A, BUG_B, LogSessionBase as _LogSessionBase)

# A third bug PRD, so a parent can carry bugs from MORE THAN ONE report — the
# repo shape S163 fix round 3 exists for. The two the base fixture exports are
# one batch; the defect only appears once a second batch lands beside it.
BUG_C = ("# Mission: Streak counter double-counts a replay\n\n"
         "**Type:** bug\n**Goal:** Count a replay once.\n"
         "**Acceptance Criteria:**\n- once\n**Out of Scope:**\n- n\n"
         "**Constraints:**\n- c\n")

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_logfiling_harness.js")
CONSOLE = os.path.join(HERE, "board_logsession_harness.js")
REPO = os.path.dirname(os.path.dirname(HERE))
NODE = shutil.which("node")
GIT = shutil.which("git")

# The commit this session builds ON: S162, the last state of board.js before the
# Fix Filed Bugs control existed. The additive-payload invariant is measured
# against the REAL file at that commit, never asserted by eye.
PRE_S163 = "0b831af"

RESOLVING_PREFIX = "◐ resolving "

VERIFY = {"id": "m-001", "issue": 142, "stage": "verify", "type": "feature",
          "title": "Add Gamification to Course Site",
          "pills": {"cost": {"label": "$4–7", "level": "med"},
                    "reasoning": {"label": "R med", "level": "med"},
                    "implementation": {"label": "I low", "level": "low"}}}


def _kid(n, **over):
    """A filed-but-never-driven logged bug child, as the LocalAdapter publishes
    it IN PRODUCTION.

    S163 fix round 1 (D1): `dispatched` is TRUE here, and that is not an edge
    case — it is the only shape this child ever has. `_card` computes
    `dispatched = bool(events) or running`, and File & Cost runs `run.sh
    estimate` on every bug it files, whose `usage_capture` hook appends a
    `worker_usage` line to that child's events.jsonl before the captain has
    even seen the review. `LogDispatchDurabilityTest` measures this against a
    real repo rather than asserting it here.

    What stays false is what a DRIVER produces: `queued` (resolve-logs stamps
    every scheduled bug) and `running` (a live driver lock). The child is parked
    at `align` by BUG-059's hold, and nothing is driving it.
    """
    c = {"id": "m-00%d" % (n + 1), "issue": 200 + n, "stage": "align",
         "type": "bug", "title": "Bug %d" % n, "parentMission": "m-001",
         "linked": True, "dispatched": True, "queued": False, "running": False}
    c.update(over)
    return c


def _stamp(status, bug_count=4, filed_count=4, error=None, sid="abc123"):
    s = {"sessionId": sid, "status": status,
         "bugCount": bug_count, "filedCount": filed_count}
    if error is not None:
        s["error"] = error
    return s


def _drive(mission, mode="card", children=None, mark_filing=False,
           mark_log_run=False, readonly=False, board_js=None, adapter=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    payload = {"mission": mission, "markFiling": mark_filing,
               "markFinalizing": False, "markLogRun": mark_log_run}
    if children is not None:
        payload["children"] = children
    if adapter:
        payload["adapter"] = adapter
    with open(path, "w") as fh:
        json.dump(payload, fh)
    env = dict(os.environ)
    if board_js:
        env["LCARS_BOARD_JS"] = board_js
    else:
        env.pop("LCARS_BOARD_JS", None)
    try:
        argv = [NODE, HARNESS, mode, path]
        if readonly:
            argv.append("readonly")
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT, env=env)
        return json.loads(out)
    finally:
        os.unlink(path)


def _console(mode, mission, session=None, preview=None, steer=None,
             readonly=False, session_error=False, children=None,
             run_error=None, run_response=None, repaint=None,
             repaint_after=False, file_error=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    body = {"mission": mission, "session": session,
            "sessionError": session_error}
    if run_error is not None:
        body["runError"] = run_error
    if file_error is not None:
        body["fileError"] = file_error
    if run_response is not None:
        body["runResponse"] = run_response
    # S163 fix round 5: with a board here the harness's `refresh` stub RENDERS it
    # through the real render(), i.e. the routine repaint that follows every
    # write actually happens — the half of the interaction a no-op stub hid.
    if repaint is not None:
        body["repaint"] = repaint
    if repaint_after:
        body["repaintAfter"] = True
    if children is not None:
        body["children"] = children
    if preview is not None:
        body["previewResponse"] = preview
    if steer is not None:
        body["steer"] = steer
    with open(path, "w") as fh:
        json.dump(body, fh)
    try:
        argv = [NODE, CONSOLE, mode, path]
        if readonly:
            argv.append("readonly")
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def _flatten(node, acc=None):
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


def _dom(res):
    """The rendered DOM as raw, sorted JSON — the byte-identity comparison
    surface. The `node` subtree ONLY: the harness's sibling fields report the
    CLIENT state it was asked to set up, which a pre-S163 board.js cannot answer
    (it has no isLogRunDispatched)."""
    return json.dumps(res["node"], sort_keys=True, ensure_ascii=False)


def _texts(res):
    return [n["text"] for n in _flatten(res["node"]) if n["text"]]


def _fix_control(res):
    """The Fix Filed Bugs control, found by its data-act-free shape: a BUTTON
    whose text starts with the label stem. Deliberately not found by the exact
    label — the count in it is part of what the tests assert."""
    for n in _flatten(res["node"]):
        if n["tag"] == "button" and n["text"].startswith("⚙ FIX "):
            return n
    return None


def _resolving_control(res):
    for n in _flatten(res["node"]):
        if n["tag"] == "button" and n["text"].startswith(RESOLVING_PREFIX):
            return n
    return None


def _filing_control(res):
    for n in _flatten(res["node"]):
        if n["tag"] == "button" and n["text"] == "◐ FILING & COSTING…":
            return n
    return None


def _prune_resolving(node):
    """The projection with every `◐ resolving N logged bug(s)…` control removed.

    Lets a byte-identity comparison say "identical EXCEPT for this one node"
    instead of being downgraded to no comparison at all — see
    `test_a_filing_in_flight_differs_by_exactly_the_duplicate_lock`.
    """
    if not node:
        return node
    kept = [c for c in node.get("children", [])
            if not (c["tag"] == "button"
                    and c["text"].startswith(RESOLVING_PREFIX))]
    out = dict(node)
    out["children"] = [_prune_resolving(c) for c in kept]
    return out


def _shortfall_note(res):
    """S162's `log-filing-status` line — the sentence that names what did NOT
    land. S163 fix round 2 must never buy its way-forward control by silencing
    this."""
    for n in _flatten(res["node"]):
        if "log-filing-status" in (n["cls"] or ""):
            return n
    return None


def _sleeping_stub(record_path, seconds):
    """A `resolve-logs` stand-in that records its ARGV and then STAYS ALIVE.

    The base fixture's resolver exits at once, which is the round-7 D3 case (a
    drive that dies before it drives anything). To prove the OTHER edge — that a
    RUNNING drive is never mistaken for a dead one, because that mistake is how
    the double dispatch returns — we need a process the OS will report as alive.
    It sleeps rather than doing work: liveness is the only thing under test.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\nprintf "ARGV: %s\\n" "$*" >> "'
                 + record_path + '"\nsleep ' + str(seconds) + '\nexit 0\n')
    os.chmod(path, 0o755)
    return path


def _pin_live_resolver(test, seconds=20):
    """Give `test` a resolve-logs stand-in that is ACTUALLY RUNNING.

    S163 fix round 7 (D3) made "a drive is live" a measurement — the daemon asks
    the OS whether the resolver it spawned is still there — and that turned an
    assumption baked into this file's fixture into a visible fiction. The base
    rig's `resolve` stub records its ARGV and exits within milliseconds, and
    round 6's tests used it to stand for "a batch is being driven". It never was:
    the process was gone before the assertion ran, and its children sat at
    `align` untouched, which is now precisely the shape the product calls a DEAD
    drive and offers to re-run.

    So the tests that mean "while a drive is live" say so with a process that
    lives. The round-6 invariants they protect are unchanged and still assert the
    same things; what changed is that the fixture no longer relies on the daemon
    being unable to tell. The tests that mean "the drive died" keep the exiting
    stub — see `DeadResolverTest`.

    Reaped on cleanup: a detached `sleep` outliving its test is how a previous
    round made an unrelated launch test flake in the full suite.
    """
    path = _sleeping_stub(test.records["resolve"], seconds)
    test.scripts["resolve"] = path
    test.actions.scripts["resolve"] = path
    test.addCleanup(_reap_stub, path)
    return path


def _reap_stub(path):
    try:
        subprocess.run(["pkill", "-9", "-f", path], capture_output=True)
    except OSError:
        pass


def _pre_s163_board_js(tmpdir):
    """The REAL web/static/board.js as of the pre-S163 commit."""
    out = subprocess.check_output(
        [GIT, "-C", REPO, "show", "%s:web/static/board.js" % PRE_S163])
    path = os.path.join(tmpdir, "board_pre_s163.js")
    with open(path, "wb") as fh:
        fh.write(out)
    return path


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FixFiledControlTest(unittest.TestCase):
    """Behaviours 1, 4, 6, 9 — the control's window, on the card."""

    def test_a_filed_session_offers_fix_filed_bugs_with_the_count(self):
        """Behaviour 1. The filing finished; four bugs are on disk and NOTHING is
        running. The card must offer the way forward, named and counted."""
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        res = _drive(m, children=[_kid(i) for i in range(4)])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no Fix Filed Bugs control: %s" % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 4 FILED BUGS")
        self.assertFalse(ctl["disabled"], "the control must be LIVE, not a badge")
        self.assertTrue(ctl["clickable"], "it must open the cost review")

    def test_one_bug_reads_singular(self):
        m = dict(VERIFY, logFiling=_stamp("filed", 1, 1))
        res = _drive(m, children=[_kid(0)])
        self.assertEqual(_fix_control(res)["text"], "⚙ FIX 1 FILED BUG")

    def test_it_replaces_the_resolving_lock_rather_than_joining_it(self):
        """Behaviour 9, edge one. S77's `◐ resolving N logged bugs…` is TRUE-by-
        derivation the instant filing completes and FALSE in substance: BUG-059
        parks the children at `align` and nothing runs without a Go. The card
        must not carry both — the disabled lie must be GONE."""
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        res = _drive(m, children=[_kid(i) for i in range(4)])
        self.assertIsNone(
            _resolving_control(res),
            "the stale disabled resolving lock is still on the card: %s"
            % _texts(res))

    def test_after_the_go_the_lock_returns_and_the_control_is_gone(self):
        """Behaviour 9, edge two — and behaviour 4's other half. Once resolve-logs
        is driving the batch the children really are in flight, the lock is
        telling the truth, and suppressing the parent's Merge is its job."""
        kids = [_kid(i, queued=True) for i in range(4)]
        kids[0] = _kid(0, running=True, dispatched=True, stage="research")
        res = _drive(dict(VERIFY), children=kids)
        self.assertIsNone(_fix_control(res),
                          "the control must vanish once the batch is dispatched")
        lock = _resolving_control(res)
        self.assertIsNotNone(lock, "the S77 lock must return: %s" % _texts(res))
        self.assertTrue(lock["disabled"])
        self.assertEqual(lock["text"], "◐ resolving 4 logged bugs…")

    def test_the_click_hides_the_control_before_any_server_tick(self):
        """Behaviour 4. The captain clicks Go; the console closes and the board
        still carries the PRE-dispatch picture (session stamp intact, children
        still un-driven). Nothing may re-offer the dispatch in that gap."""
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        res = _drive(m, children=[_kid(i) for i in range(4)], mark_log_run=True)
        self.assertTrue(res["logRun"], "the client flag must survive the render")
        self.assertIsNone(_fix_control(res))
        self.assertIsNotNone(_resolving_control(res))

    def test_the_daemons_dispatch_stamp_hides_it_after_a_reload(self):
        """Behaviour 4, in a tab that never clicked. A hard reload drops the
        client flag; the seconds before resolve-logs stamps its children `queued`
        would otherwise re-offer a Go that is already running."""
        m = dict(VERIFY, logDispatch={"sessionId": "abc123",
                                      "status": "dispatched"})
        res = _drive(m, children=[_kid(i) for i in range(4)])
        self.assertIsNone(_fix_control(res))
        self.assertIsNotNone(_resolving_control(res))

    def test_the_daemon_restart_fallback_offers_it_from_the_children_alone(self):
        """Behaviour 5, card half. The daemon restarted: the in-memory session is
        gone, but the bugs are real linked children on disk that no driver has
        ever touched. The card must still offer the way forward — the alternative
        is a dead disabled lock and no path back to the cost review at all."""
        res = _drive(dict(VERIFY), children=[_kid(i) for i in range(3)])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no fallback control: %s" % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 3 FILED BUGS")
        self.assertFalse(ctl["disabled"])
        self.assertTrue(ctl["clickable"])
        self.assertIsNone(_resolving_control(res))

    def test_the_estimators_own_events_never_read_as_a_dispatch(self):
        """S163 fix round 1, D1 — the regression test for the defect that made
        this whole fallback dead code in production.

        A restarted daemon holds no session and no mark, so this branch is the
        captain's ONLY route back to the cost review (since S162, File & Cost
        always closes the console). It shipped gated on
        `kids.every(c => !c.dispatched && ...)` — and `dispatched` is
        `bool(events) or running`, which the FILING step makes true on every
        child by running the estimator through a worker that logs
        `worker_usage`. So the gate could never open, the card fell back to the
        disabled "◐ resolving N logged bugs…" lock, and nothing was resolving.

        These children are exactly what disk holds after a File & Cost: events
        from the estimator, no queue stamp, no driver lock.
        """
        res = _drive(dict(VERIFY), children=[_kid(i) for i in range(3)])
        ctl = _fix_control(res)
        self.assertIsNotNone(
            ctl,
            "the estimator's own events read as 'a driver has touched this "
            "batch' — the restart fallback is dead code: %s" % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 3 FILED BUGS")
        self.assertIsNone(_resolving_control(res))

    def test_one_child_already_driving_withdraws_the_fallback(self):
        """The fallback is "no DRIVER has ever touched this batch" — one child in
        flight means the batch is running, whatever the others read.

        Both driver-produced signals are checked, because each arrives on its own
        schedule: resolve-logs stamps `queued` on every scheduled bug up front
        and CLEARS it as that bug starts, at which point `running` is what says
        so. (`dispatched` is deliberately absent from this list — see
        test_the_estimators_own_events_never_read_as_a_dispatch.)
        """
        for signal in ("queued", "running"):
            kids = [_kid(i) for i in range(3)]
            kids[2] = _kid(2, stage="plan", **{signal: True})
            res = _drive(dict(VERIFY), children=kids)
            self.assertIsNone(_fix_control(res),
                              "a child marked %s must withdraw it" % signal)
            self.assertIsNotNone(_resolving_control(res))

    def test_a_filing_in_flight_keeps_the_s162_band_and_offers_no_fix(self):
        """The two surfaces are sequential, never simultaneous: while the
        estimator is still running there is nothing to review yet."""
        m = dict(VERIFY, logFiling=_stamp("filing", 4, 1))
        res = _drive(m, children=[_kid(i) for i in range(4)], mark_filing=True)
        self.assertIsNone(_fix_control(res))
        self.assertIn("◐ FILING & COSTING…", _texts(res))

    def test_a_batch_that_filed_nothing_offers_no_fix_control(self):
        """`failed` is the daemon's word for "none of them landed"
        (`_settle_log_session`: `partial if filed else failed`), so there is no
        filed batch to fix and the control would be counting to zero.

        S163 fix round 2 states the rule as a MEASUREMENT rather than a status
        name — the gate is `filedCount >= 1` — so a future daemon that ever
        produced a `failed` batch with children really on disk would get the way
        forward instead of a lie. Today that shape does not exist, and this is
        what the shape that DOES exist must do.
        """
        m = dict(VERIFY, logFiling=_stamp("failed", 4, 0,
                                          error="log.sh refused every bug"))
        res = _drive(m, children=[])
        self.assertIsNone(_fix_control(res),
                          "a batch that filed nothing offered a fix control")
        self.assertIsNone(_resolving_control(res),
                          "...and nothing is resolving either: %s" % _texts(res))
        self.assertIn("✖ logging the bugs failed — 0 of 4 filed", _texts(res),
                      "S162's failure note is what owns this card: %s"
                      % _texts(res))

    def test_a_batch_that_filed_nothing_says_nothing_about_an_EARLIER_one(self):
        """S163 fix round 2, the third face of D1 — MEASURED live, on the real
        daemon, after the first two were cured.

        A parent can carry a filed-but-never-dispatched batch AND then have a
        second report fail outright. Same repo, one minute apart:

            no session, 4 untouched children   →  ⚙ FIX 4 FILED BUGS   (live)
            log 2 bugs, both refused (`failed`)→  ◐ resolving 4 …      (DISABLED)

        Nothing about those four children changed. A stamp is authoritative
        about the batch IT describes, and a `filedCount: 0` batch describes
        nothing that reached disk — so it must not be allowed to speak for what
        was already there. It falls through to the children measurement, and the
        card keeps saying what it said before the failure.
        """
        kids = [_kid(i) for i in range(4)]
        m = dict(VERIFY, logFiling=_stamp("failed", 2, 0, error="both refused"))
        with_stamp = _drive(m, children=kids)
        without = _drive(dict(VERIFY), children=kids)
        self.assertIsNotNone(
            _fix_control(with_stamp),
            "a failed batch buried the way forward for an EARLIER filed batch "
            "that is still sitting on disk: %s" % _texts(with_stamp))
        self.assertEqual(_fix_control(with_stamp)["text"],
                         _fix_control(without)["text"],
                         "the failed batch changed how the earlier one is "
                         "counted")
        self.assertIsNone(_resolving_control(with_stamp))
        self.assertIn("✖ logging the bugs failed — 0 of 2 filed",
                      _texts(with_stamp),
                      "...and the failure is still reported: %s"
                      % _texts(with_stamp))

    def test_a_partial_that_filed_nothing_offers_no_fix_control(self):
        """Belt and braces on the same measurement: `partial` is defined as
        "some landed", so `filedCount: 0` is a contradiction the daemon cannot
        produce — but the card decides on the COUNT, not on the word, so it
        refuses this shape too rather than printing "FIX 0 FILED BUGS"."""
        m = dict(VERIFY, logFiling=_stamp("partial", 3, 0, error="none filed"))
        res = _drive(m, children=[])
        self.assertIsNone(_fix_control(res))

    def test_a_github_board_never_claims_the_batch_is_undriven(self):
        """The fallback reads three per-child fields the GITHUB adapter cannot
        see and publishes as hardcoded `false` placeholders (its own comments say
        so). Reading a placeholder as a measurement would let a forge card state
        "these bugs have never been driven" on a view that cannot know it — so
        there the S77 lock, which needs only the children's stages, keeps the
        card. The LOCAL adapter measures all three, so it still offers it."""
        kids = [_kid(i) for i in range(3)]
        gh = _drive(dict(VERIFY), children=kids, adapter="github")
        self.assertIsNone(_fix_control(gh))
        self.assertIsNotNone(_resolving_control(gh))
        local = _drive(dict(VERIFY), children=kids, adapter="local")
        self.assertIsNotNone(_fix_control(local))

    def test_a_github_board_still_honours_the_session_stamp(self):
        """The session stamp is adapter-independent — it comes from the daemon's
        own memory, not from a card field — so it is not withdrawn here. (A
        github build holds no sessions in practice; this pins that the refusal
        above is scoped to the fields it is about, not a blanket one.)"""
        m = dict(VERIFY, logFiling=_stamp("filed", 2, 2))
        res = _drive(m, children=[_kid(i) for i in range(2)], adapter="github")
        self.assertIsNotNone(_fix_control(res))

    def test_a_bug_child_never_offers_it(self):
        """You cannot log bugs against a logged bug (BUG-046), so a bug child can
        never be the parent of a filed batch."""
        child = dict(_kid(0), stage="verify", logFiling=_stamp("filed", 1, 1))
        res = _drive(child, children=[])
        self.assertIsNone(_fix_control(res))

    def test_view_only_board_disables_it(self):
        """Behaviour 8. The control opens a console whose Go is a write."""
        m = dict(VERIFY, logFiling=_stamp("filed", 2, 2))
        res = _drive(m, children=[_kid(i) for i in range(2)], readonly=True)
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl)
        self.assertTrue(ctl["disabled"], "a view-only board must not offer a Go")
        self.assertEqual(ctl["title"], "view-only board — writes are disabled")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FixFiledDetailTest(unittest.TestCase):
    """Behaviour 1, detail half. The detail NEVER runs through the board's card
    builder, so a surface left out of it goes silent at exactly the moment the
    captain clicks the card to look closer (the align_overlay_mission lesson)."""

    def test_the_detail_actions_carry_the_same_control(self):
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        res = _drive(m, mode="detail", children=[_kid(i) for i in range(4)])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no Fix Filed Bugs in the detail actions: %s"
                             % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 4 FILED BUGS")
        self.assertFalse(ctl["disabled"])
        self.assertIn("Mission Log", _texts(res),
                      "it belongs BESIDE the console it points at")

    def test_the_detail_drops_the_resolving_lock_in_the_same_window(self):
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        res = _drive(m, mode="detail", children=[_kid(i) for i in range(4)])
        self.assertIsNone(_resolving_control(res))

    def test_the_detail_restores_the_lock_after_the_go(self):
        kids = [_kid(i, queued=True) for i in range(2)]
        res = _drive(dict(VERIFY), mode="detail", children=kids)
        self.assertIsNone(_fix_control(res))
        self.assertIsNotNone(_resolving_control(res))


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class PartialBatchTest(unittest.TestCase):
    """S163 fix round 2, D1 — a `partial` filing must not be a dead end.

    THE TESTER'S MEASUREMENT (2026-08-01, parent lcars-20260802-026, reproduced
    twice). Three bugs logged against a Verify-stage mission, one of them
    malformed so `log.sh` refuses it. Costing finishes:

        /log/session      {"status":"partial","bugCount":3,"filedCount":2,…}
        disk              two real linked children, both at align, both costed
        log-dispatch.json NONE — no Go has been taken, nothing is running
        card + detail     "◐ resolving 2 logged bugs…"  DISABLED

    That is the exact pre-S163 dead end this session existed to remove, and two
    of the three bugs really are filed and reviewable. The first shipping cut
    scoped the control to a clean `filed` on the reasoning that a `partial` Go
    keeps its session (N1) and two stamps on one card is confusing. The captain
    overruled it on measurement: a presentation problem is not a reason to ship a
    control that says work is in flight when nothing is.

    THE CLINCHER, and why the agreement test below is the sharpest of these.
    `kill -9` the daemon and restart — nothing on disk changes, only the
    in-memory `partial` session is dropped — and the same repo renders
    "⚙ FIX 2 FILED BUGS", live and clickable. The DISK fallback got it right and
    the LIVE session path did not, so the product contradicted itself about one
    repo state depending only on how long the daemon had been up.

    What the cure may NOT do: bury the shortfall. S161 made "the unfiled text is
    preserved verbatim and can be retried" a ship-blocker-grade promise, so the
    control names the shortfall in its own label AND leaves S162's note in place
    to say what did not land and why.
    """

    #: the tester's exact repro: 3 authored, 2 on disk, 1 refused by log.sh.
    ERROR = ("only 2 of 3 authored bugs filed — the missing one is still held "
             "here")

    def _partial(self, bug_count=3, filed_count=2):
        return dict(VERIFY, logFiling=_stamp("partial", bug_count, filed_count,
                                             error=self.ERROR))

    def test_a_partial_offers_a_live_way_forward_on_the_card(self):
        """The blocking defect itself. Two bugs are on disk, no Go has been
        taken, nothing is running — the card must offer a route, not a lock."""
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)])
        self.assertIsNone(
            _resolving_control(res),
            "the disabled 'resolving' lie is still the card's only control on a "
            "partial batch: %s" % _texts(res))
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no way forward from a partial batch: %s"
                             % _texts(res))
        self.assertFalse(ctl["disabled"], "the control must be LIVE")
        self.assertTrue(ctl["clickable"], "it must open the cost review")

    def test_the_label_counts_only_what_landed_and_names_the_shortfall(self):
        """"FIX 2 FILED BUGS" on a 3-bug batch would be true and misleading in
        the same breath. The label carries both numbers, so the count the captain
        is about to approve can never read as the batch they asked for."""
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)])
        self.assertEqual(_fix_control(res)["text"], "⚙ FIX 2 OF 3 FILED BUGS")

    def test_it_keeps_the_s162_shortfall_note_and_the_daemons_reason(self):
        """The way forward must not be bought by silencing the bad news. Both
        stay on the card: the note says what did not land and why (the daemon's
        own words), the control says what can be done about what did."""
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)])
        note = _shortfall_note(res)
        self.assertIsNotNone(note, "S162's shortfall note vanished: %s"
                             % _texts(res))
        self.assertEqual(note["text"], "● only 2 of 3 filed")
        self.assertIn(self.ERROR, _texts(res),
                      "the daemon's own reason is no longer on the card")

    def test_the_control_says_the_unfiled_text_is_still_retryable(self):
        """S161's promise, carried by the copy of the control that replaced the
        lock — the captain must not learn "1 bug never filed" only by counting
        cards."""
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)])
        title = _fix_control(res)["title"]
        self.assertIn("1 bug", title,
                      "the tooltip does not name the shortfall: %r" % title)
        self.assertIn("retr", title.lower(),
                      "it must say the missing bug can be retried: %r" % title)

    def test_the_detail_carries_the_same_control(self):
        """The detail is built by a different function (the
        `align_overlay_mission` lesson) and the tester measured the lie on BOTH
        surfaces, so both are pinned."""
        res = _drive(self._partial(), mode="detail",
                     children=[_kid(i) for i in range(2)])
        self.assertIsNone(_resolving_control(res),
                          "the detail still shows the lock: %s" % _texts(res))
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no control in the detail actions: %s"
                             % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 2 OF 3 FILED BUGS")
        self.assertFalse(ctl["disabled"])

    def test_the_live_session_and_the_restarted_daemon_agree(self):
        """THE AGREEMENT TEST — the self-contradiction the tester measured, and
        the sharpest evidence there was a bug at all.

        ONE on-disk state (two filed, never-driven bug children), rendered twice:
        once with the daemon's live `partial` session, once with that session
        gone (a `kill -9` and a relaunch changes nothing else). The two must
        agree about whether there is a way forward. They disagreed — the disk
        fallback offered the control, the live path offered the lock — so a
        captain's answer to "can I get back to my cost review?" depended on how
        long the daemon had been up.

        They are NOT required to word it identically: the restarted daemon has no
        session and therefore cannot know a third bug was ever authored, so it
        counts only what it can see. Claiming otherwise would be the invention
        S160/S161 spent two rounds removing.
        """
        kids = [_kid(i) for i in range(2)]
        for mode in ("card", "detail"):
            live = _drive(self._partial(), mode=mode, children=kids)
            restarted = _drive(dict(VERIFY), mode=mode, children=kids)
            self.assertEqual(
                _fix_control(live) is not None,
                _fix_control(restarted) is not None,
                "the live-session and post-restart renders of the SAME disk "
                "state disagree about whether a way forward exists (%s): "
                "live=%s restarted=%s"
                % (mode, _texts(live), _texts(restarted)))
            self.assertEqual(
                _resolving_control(live) is not None,
                _resolving_control(restarted) is not None,
                "one of them shows the disabled resolving lock and the other "
                "does not (%s)" % mode)
            self.assertIsNotNone(_fix_control(live))
            self.assertIsNone(_resolving_control(live))

    def test_a_partial_go_still_hides_the_control(self):
        """BUG-059's hold survives the widening in both directions: once the Go
        IS taken the control goes and the lock returns, because now the lock is
        telling the truth. (A `partial` Go deliberately KEEPS its session — N1,
        so the unfiled text survives — which is exactly why the dispatch marks
        have to outrank the stamp rather than the other way round.)"""
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)],
                     mark_log_run=True)
        self.assertIsNone(_fix_control(res))
        self.assertIsNotNone(_resolving_control(res))

    def test_a_view_only_board_disables_it(self):
        res = _drive(self._partial(), children=[_kid(i) for i in range(2)],
                     readonly=True)
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl)
        self.assertTrue(ctl["disabled"])

    def test_a_partial_console_opens_the_review_the_shortfall_and_a_go(self):
        """Where the control SENDS them. The tester found an honest recovery
        console already sitting behind the detail's Mission Log button — the
        filed bug's review, the shortfall warning, and a footer offering both
        "File N Remaining" and "Go ▸". The card's control must route to that same
        truth rather than open a parallel one."""
        session = {
            "sessionId": "abc123", "parent": "m-001", "status": "partial",
            "authored": False, "filed": True, "bugCount": 3, "filedCount": 2,
            "error": self.ERROR, "overrides": [],
            "unfiledCount": 1,
            "unfiled": [{"index": 2, "title": "Leaderboard drops ties",
                         "prd": "this is not a PRD at all"}],
            "children": FixFiledConsoleTest.FILED_SESSION["children"],
        }
        res = _console("openFix", VERIFY, session=session)
        texts = _texts(res)
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"],
                         [], "reopening a partial batch dispatched a write")
        self.assertTrue(any(t.startswith("Review — ") for t in texts),
                        "not the post-File review: %s" % texts)
        self.assertIn(self.ERROR, texts,
                      "the shortfall is not stated in the console: %s" % texts)
        self.assertIn("Leaderboard drops ties", " ".join(texts),
                      "the unfiled bug's held text is not offered back")
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"],
                        "the partial review has no armed Go")
        retry = [n for n in _flatten(res["node"])
                 if n["tag"] == "button" and n["text"].startswith("File ")]
        self.assertTrue(retry, "the retry control is gone: %s" % texts)
        self.assertEqual(retry[0]["text"], "File 1 Remaining")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingWindowTest(unittest.TestCase):
    """S163 fix round 2, D2 — ONE statement while a filing is in flight.

    THE TESTER'S MEASUREMENT (pre-existing; A/B'd against board.js at %s, which
    rendered the same two controls byte-for-byte, so S163 did not introduce it):

        t=1   ◐ FILING & COSTING…[DIS]   ◐ resolving 1 logged bug…[DIS]
        t=5   ◐ FILING & COSTING…[DIS]   ◐ resolving 2 logged bugs…[DIS]
        t=11  ◐ FILING & COSTING…[DIS]   ◐ resolving 3 logged bugs…[DIS]

    …with the daemon's own stamp reading `filedCount: 0` and no Go taken. The
    second control is the same lie as D1's, produced by the same cause: S77's
    lock is derived from the children EXISTING, and filing is precisely the
    window in which they appear one by one while nothing drives any of them.

    It is folded into this fix because it needs neither a change to the
    `isResolvingLocked` predicate (the Merge/Accept suppression it also performs
    is right in this window and stays) nor any movement of a byte-identity
    baseline (a card mid-filing is log activity, so it was never in one).
    """ % PRE_S163

    def _filing(self, seen):
        """Mid-filing: the daemon's stamp says `filing` and `seen` children have
        appeared on disk so far."""
        m = dict(VERIFY, logFiling=_stamp("filing", 3, 0))
        return _drive(m, children=[_kid(i) for i in range(seen)],
                      mark_filing=True)

    def test_the_card_makes_one_in_flight_statement_not_two(self):
        for seen in (1, 2, 3):
            res = self._filing(seen)
            self.assertIsNotNone(_filing_control(res),
                                 "the honest statement is missing: %s"
                                 % _texts(res))
            self.assertIsNone(
                _resolving_control(res),
                "a second, contradictory control claims %d logged bug(s) are "
                "resolving while the batch is still FILING: %s"
                % (seen, _texts(res)))

    def test_the_detail_makes_one_in_flight_statement_not_two(self):
        m = dict(VERIFY, logFiling=_stamp("filing", 3, 0))
        res = _drive(m, mode="detail", children=[_kid(i) for i in range(3)],
                     mark_filing=True)
        self.assertIsNotNone(_filing_control(res))
        self.assertIsNone(_resolving_control(res),
                          "the detail carries both statements: %s" % _texts(res))

    def test_the_optimistic_flag_alone_is_enough(self):
        """The click's own instant flag, before any server tick — the board is
        still carrying the PRE-dispatch `previewed` stamp then, and the children
        of a PREVIOUS batch may already be indexed."""
        m = dict(VERIFY, logFiling=_stamp("previewed", 3, 0))
        res = _drive(m, children=[_kid(i) for i in range(2)], mark_filing=True)
        self.assertIsNone(_resolving_control(res), _texts(res))
        self.assertIsNotNone(_filing_control(res))

    def test_the_lock_returns_the_moment_the_filing_ends(self):
        """Suppression is scoped to the window, never a habit: with the filing
        over and the Go taken, the children really are being driven and the lock
        is the right thing to say."""
        kids = [_kid(i, queued=True) for i in range(3)]
        res = _drive(dict(VERIFY), children=kids)
        self.assertIsNone(_filing_control(res))
        lock = _resolving_control(res)
        self.assertIsNotNone(lock, _texts(res))
        self.assertTrue(lock["disabled"])


@unittest.skipIf(NODE is None or GIT is None, "node + git are required")
class AdditivePayloadTest(unittest.TestCase):
    """Behaviour 7 — a card with no filed-bug batch renders BYTE-IDENTICALLY to
    its pre-S163 self, proven against the real board.js at %s rather than argued.

    Every comparison is paired with a POSITIVE control on the same surface: a
    fixture that MUST differ. A normaliser that hid a change would pass the
    identity half and fail the control, which is the point — five rounds of this
    project have been burned by a check that could only ever say yes.
    """ % PRE_S163

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="lcars-s163-")
        self.pre = _pre_s163_board_js(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _both(self, mission, mode="card", children=None):
        now = _drive(mission, mode=mode, children=children)
        was = _drive(mission, mode=mode, children=children, board_js=self.pre)
        return _dom(now), _dom(was)

    def test_a_mission_with_no_logged_bugs_is_unchanged(self):
        for mode in ("card", "detail"):
            now, was = self._both(dict(VERIFY), mode=mode)
            self.assertEqual(now, was, "%s drifted with no log activity" % mode)

    def test_a_dispatched_batch_is_unchanged(self):
        """The post-Go window is S77's, untouched: same lock, same copy, same
        DOM. If this drifts, the fix control leaked out of its window."""
        kids = [_kid(i, queued=True) for i in range(4)]
        for mode in ("card", "detail"):
            now, was = self._both(dict(VERIFY), mode=mode, children=kids)
            self.assertEqual(now, was, "%s drifted after dispatch" % mode)

    def test_a_filing_in_flight_differs_by_exactly_the_duplicate_lock(self):
        """S162's band is not this session's to move — and it has not moved.

        THE ONE BASELINE S163 fix round 2 CHANGES, named rather than relaxed.
        This shipped as a flat "identical" assertion, and that assertion WAS the
        D2 defect written down: the tester measured the filing window carrying
        two disabled controls at once —

            ◐ FILING & COSTING…[DIS]   ◐ resolving 3 logged bugs…[DIS]

        — with the daemon's stamp reading `filedCount: 0` and no Go taken. So
        "byte-identical to S162 here" meant "still carrying S162's second,
        contradictory statement".

        It is replaced by a STRICTER check, not a weaker one: prune the duplicate
        lock out of the pre-S163 projection and the two must be equal ANYWHERE
        ELSE. Nothing about the band, the pulse, the pills or the layout may
        drift under cover of this fix — the delta is exactly one removed node,
        and the assertions below prove that node was there before and is gone
        now. The round's stated invariant ("a board with no in-flight log filing
        renders byte-identically to pre-158") is untouched, and the other three
        comparisons in this class — including the positive control — still run
        as flat equalities.
        """
        m = dict(VERIFY, logFiling=_stamp("filing", 4, 1))
        for mode in ("card", "detail"):
            now = _drive(m, mode=mode, children=[_kid(i) for i in range(4)],
                         mark_filing=True)
            was = _drive(m, mode=mode, children=[_kid(i) for i in range(4)],
                         mark_filing=True, board_js=self.pre)
            self.assertIsNotNone(
                _resolving_control(was),
                "the pre-S163 %s did NOT carry the duplicate lock — D2's premise "
                "needs re-measuring" % mode)
            self.assertIsNone(_resolving_control(now),
                              "the duplicate lock is still there (%s)" % mode)
            self.assertIsNotNone(_filing_control(now),
                                 "the honest statement went with it (%s)" % mode)
            self.assertEqual(
                json.dumps(_prune_resolving(now["node"]), sort_keys=True,
                           ensure_ascii=False),
                json.dumps(_prune_resolving(was["node"]), sort_keys=True,
                           ensure_ascii=False),
                "%s drifted somewhere OTHER than the duplicate lock" % mode)

    def test_the_comparison_can_go_red(self):
        """The positive control. The very fixture this session changes MUST
        differ across the two board.js files — otherwise the three assertions
        above prove only that the normaliser is blind."""
        m = dict(VERIFY, logFiling=_stamp("filed", 4, 4))
        now, was = self._both(m, children=[_kid(i) for i in range(4)])
        self.assertNotEqual(now, was,
                            "the byte-identity surface cannot see this session's "
                            "own change — it proves nothing")
        self.assertIn("⚙ FIX 4 FILED BUGS", now)
        self.assertNotIn("⚙ FIX 4 FILED BUGS", was)


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FixFiledConsoleTest(unittest.TestCase):
    """Behaviours 2, 3, 5 and 6 — what the click actually opens, and what Go
    sends. Drives the SHIPPING `openLog(id, {fix:true})`."""

    FILED_SESSION = {
        "sessionId": "abc123", "parent": "m-001", "status": "filed",
        "authored": False, "filed": True, "bugCount": 2, "filedCount": 2,
        "unfiled": [], "unfiledCount": 0, "overrides": [],
        "children": [
            {"id": "m-002", "issue": 200, "title": "Score resets on reload",
             "stage": "align", "type": "bug",
             "pills": {"cost": {"label": "$1–2", "level": "low"},
                       "reasoning": {"label": "R low", "level": "low"},
                       "implementation": {"label": "I low", "level": "low"}},
             "modelMix": [{"stage": "plan", "model": "Sonnet"}]},
            {"id": "m-003", "issue": 201, "title": "Badge art misaligned",
             "stage": "align", "type": "bug",
             "pills": {"cost": {"label": "$1–2", "level": "low"},
                       "reasoning": {"label": "R low", "level": "low"},
                       "implementation": {"label": "I low", "level": "low"}},
             "modelMix": [{"stage": "plan", "model": "Sonnet"}]},
        ],
    }

    # what the daemon answers an EMPTY-text preview with: the read-only view of
    # the bug missions already linked to this parent. Authors nothing, files
    # nothing, mints no session.
    LINKED_ONLY = {"parent": "m-001", "authored": False, "count": 2,
                   "children": FILED_SESSION["children"]}

    def _urls(self, res, method=None):
        return [f["url"] for f in res["fetches"]
                if method is None or f["method"] == method]

    def test_it_restores_the_breakdown_with_estimates_and_override_boxes(self):
        """Behaviour 2. Exactly the panel the captain would have seen had they
        stayed: the post-File review, each bug's estimate pills, and the S74
        per-bug steer box."""
        res = _console("openFix", VERIFY, session=self.FILED_SESSION)
        texts = _texts(res)
        self.assertTrue(any(t.startswith("Review — ") for t in texts),
                        "not the post-File review panel: %s" % texts)
        self.assertIn("Bug · Score resets on reload", texts)
        self.assertTrue(any("$1–2" in t for t in texts),
                        "the estimate pills must be there: %s" % texts)
        inputs = [n for n in _flatten(res["node"]) if n["tag"] == "input"]
        self.assertGreaterEqual(len(inputs), 2,
                                "one model-override box per filed bug")
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"], "Go must be armed")

    def test_reopening_never_re_files_and_never_re_splits(self):
        """Behaviour 5's other half, and the money question: reopening a filed
        batch must cost nothing. With a session in hand the console asks the
        daemon what it holds and stops — no /log (the ~25s split worker), no
        /log/file (the estimator), no /log/run."""
        res = _console("openFix", VERIFY, session=self.FILED_SESSION)
        self.assertEqual(self._urls(res, "POST"), [],
                         "reopening the review dispatched a write")

    def test_nothing_auto_runs(self):
        """Behaviour 6 — BUG-059's hold, relocated but not removed. Opening the
        review is not consent; the dispatch waits for the click."""
        res = _console("openFix", VERIFY, session=self.FILED_SESSION)
        self.assertNotIn("/api/mission/m-001/log/run", self._urls(res))

    def test_go_dispatches_once_through_the_existing_path(self):
        """Behaviour 4. One POST, to the endpoint the in-dialog Go has always
        used — this session adds no second dispatch path."""
        res = _console("fixThenGo", VERIFY, session=self.FILED_SESSION)
        runs = [u for u in self._urls(res, "POST")
                if u.endswith("/log/run")]
        self.assertEqual(len(runs), 1, "expected exactly one dispatch: %s"
                         % self._urls(res, "POST"))
        self.assertTrue(res["closed"], "the console closes on dispatch")
        self.assertTrue(res["logRun"],
                        "the parent must be marked dispatched on the click, so "
                        "the card's control goes with the console")

    def test_an_edited_override_rides_the_dispatch(self):
        """Behaviour 3 — the whole reason the review exists. The captain steers
        one bug's model and that steer must reach /log/run, not evaporate.

        S163 fix round 3 (D2) changed the wire shape from a positional LIST to a
        map keyed by the bug's mission id, and this assertion changed with it —
        deliberately, because the list is what let a steer land on a bug that was
        never on screen. The steer typed into the FIRST box must arrive named for
        m-002 and for nothing else.

        S163 fix round 6 (D1) changed what the map CONTAINS: every box the panel
        renders now rides the dispatch, empty ones included, because a deleted
        steer had no way to reach the daemon otherwise (`setSteer` dropped it,
        so an emptied box was indistinguishable from an untouched one). The
        payload is now the panel — so the assertion is the panel: m-002 carries
        the typed words and m-003 carries the emptiness the captain left it in.
        """
        res = _console("fixSteerGo", VERIFY, session=self.FILED_SESSION,
                       steer="use Opus")
        body = None
        for f in res["fetches"]:
            if f["url"].endswith("/log/run"):
                body = f["body"]
        self.assertIsNotNone(body, "no /log/run dispatch")
        self.assertEqual(body.get("overrides"),
                         {"m-002": "use Opus", "m-003": ""},
                         "the edited steer did not ride the dispatch: %r" % body)

    def test_the_daemon_restart_fallback_opens_the_linked_children_and_a_go(self):
        """Behaviour 5. No session (the daemon restarted) but the bugs are on
        disk. The console must fall back to the READ-ONLY linked-children view
        with a working Go — never a dead panel, and never a re-file: the only
        POST is the empty-text preview, which authors nothing."""
        res = _console("openFix", VERIFY, session=None, preview=self.LINKED_ONLY)
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(len(posts), 1, "expected one read-only preview: %s"
                         % [p["url"] for p in posts])
        self.assertTrue(posts[0]["url"].endswith("/log"))
        self.assertEqual((posts[0]["body"] or {}).get("text"), "",
                         "an empty report is what makes it read-only — anything "
                         "else re-splits and re-charges the captain")
        texts = _texts(res)
        self.assertIn("Bug · Score resets on reload", texts)
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"],
                        "the fallback must arm Go, never a dead button")

    def test_a_failed_session_get_falls_back_the_same_way(self):
        """"Never a dead button" must hold for every way the session can be
        unreachable, not just the tidy 404. A wedged daemon answering 500 leaves
        the bugs exactly as filed on disk, so the fallback is the same one."""
        res = _console("openFix", VERIFY, session=None, session_error=True,
                       preview=self.LINKED_ONLY)
        self.assertIn("Bug · Score resets on reload", _texts(res))
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"])

    def test_the_fallback_go_dispatches_the_same_endpoint(self):
        res = _console("fixThenGo", VERIFY, session=None,
                       preview=self.LINKED_ONLY)
        runs = [u for u in self._urls(res, "POST") if u.endswith("/log/run")]
        self.assertEqual(len(runs), 1)

    def test_the_plain_mission_log_button_opens_blank_with_no_filed_batch(self):
        """The old entry point stays a blank console when there is nothing to
        come back to: `openLog(id)` against a parent with no logged bugs must
        not start fetching linked children on its own."""
        res = _console("open", VERIFY, session=None, preview=self.LINKED_ONLY)
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [],
                         "the plain Mission Log console dispatched something")

    def test_the_plain_mission_log_button_lands_in_the_review_after_a_restart(self):
        """S163 fix round 1 (D2). Same restart, the OTHER door.

        With the card's control restored, "Mission Log" in the detail is still
        the button a captain reaches for by habit — and it opened a console that
        said nothing about the bug already filed, showed no cost, and carried a
        `Go ▸` that could only refuse. The last route back was a silent no-op.

        It now lands in the SAME restored review, keyed on the same reading the
        card's control uses (a filed batch, no Go taken) rather than on which
        button was pressed. Still read-only: one empty-text preview, which
        authors nothing and mints no session.
        """
        kids = [_kid(i) for i in range(2)]
        res = _console("open", VERIFY, session=None, preview=self.LINKED_ONLY,
                       children=kids)
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(len(posts), 1,
                         "expected one read-only preview: %s"
                         % [p["url"] for p in posts])
        self.assertTrue(posts[0]["url"].endswith("/log"))
        self.assertEqual((posts[0]["body"] or {}).get("text"), "")
        self.assertIn("Bug · Score resets on reload", _texts(res))
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"],
                        "the plain console's Go is still a dead button")

    def test_the_plain_console_stays_blank_once_the_batch_is_dispatched(self):
        """...and only in that window. Once the Go is taken there is no review
        to come back to, so the habitual button must not start re-rendering one
        over children that are being driven."""
        m = dict(VERIFY, logDispatch={"sessionId": "abc123",
                                      "status": "dispatched"})
        res = _console("open", m, session=None, preview=self.LINKED_ONLY,
                       children=[_kid(i) for i in range(2)])
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [],
                         "the plain console re-opened a spent review")


class LogDispatchStampTest(_LogSessionBase):
    """The DAEMON half of "the control disappears once the batch is dispatched".

    The client's optimistic `markLogRun` covers the tab that clicked Go. It does
    NOT cover a tab that reloads, and that gap is real rather than theoretical:
    `log_run` spawns resolve-logs fire-and-forget and returns, and it is
    resolve-logs — seconds later — that stamps each child `queued`. In between,
    the board looks exactly like the pre-Go board, which is the one picture that
    must not re-offer the dispatch (a second Go is a second resolve-logs driver
    over the same children).

    So the daemon publishes what only it knows: it dispatched this parent's Go.
    In-memory and additive, like every other stamp in this family — and bounded
    the same way, because after those few seconds the DISK signal the fallback
    reads (`queued`/`dispatched`/`running` on the children) is real and takes
    over.
    """

    def _dispatch_stamp(self, mid="m-001"):
        _s, board = self._get("/api/board")
        for c in self._cards(board):
            if c["id"] == mid:
                return c.get("logDispatch")
        self.fail("no card for %s on the board" % mid)

    def test_no_go_no_stamp_and_the_board_is_byte_identical(self):
        """The additive invariant at the source. A daemon that has dispatched
        nothing must return the adapter's board untouched."""
        board = self.adapter.board()
        snapshot = copy.deepcopy(board)
        self.assertEqual(self.actions.log_overlay(board), snapshot)
        _s, live = self._get("/api/board")
        self.assertTrue(all("logDispatch" not in c for c in self._cards(live)))
        _s, detail = self._get("/api/mission/m-001")
        self.assertNotIn("logDispatch", detail)

    def test_the_go_stamps_the_parent_and_clears_the_filing_stamp(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(self._stamp()["status"], "filed")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertIsNone(self._stamp(),
                          "the Go consumes the session (S161) — unchanged")
        mark = self._dispatch_stamp()
        self.assertIsNotNone(mark, "the Go left no trace for a reloaded tab")
        self.assertEqual(mark["status"], "dispatched")
        self.assertEqual(mark["sessionId"], sid)

    def test_the_detail_mirrors_it(self):
        """The detail never runs through the board overlay — the same lesson
        `logFiling` learned in S161."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        _s, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["logDispatch"]["status"], "dispatched")

    def test_only_the_parent_is_stamped(self):
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        _s, board = self._get("/api/board")
        others = [c for c in self._cards(board) if c["id"] != "m-001"]
        self.assertTrue(all("logDispatch" not in c for c in others))

    def test_a_fresh_preview_supersedes_a_SETTLED_mark(self):
        """A new report against the same parent is a NEW batch. Once the old
        batch has reached its gate, the old dispatch mark must not suppress the
        new one's review — the live session is then the stronger, more recent
        fact and wins outright.

        S163 fix round 6 (D3): "once the old batch has reached its gate" is the
        whole of the correction. This test used to prove the rule with the batch
        still mid-drive, which is exactly the state where it is false —
        `DoubleDispatchTest.test_the_card_says_the_parent_is_being_driven_not_
        fixable` now pins the other side of the same boundary.
        """
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertIsNotNone(self._dispatch_stamp())
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", "m-bug1",
                          "state.json")
        with open(sp) as fh:
            st = json.load(fh)
        st["stage"] = "verify"
        with open(sp, "w") as fh:
            json.dump(st, fh, indent=2)
        self._preview(BUG_B)
        self.assertIsNone(self._dispatch_stamp(),
                          "a fresh preview must clear a SETTLED dispatch mark")
        self.assertEqual(self._stamp()["status"], "previewed")


class LogDispatchDurabilityTest(_LogSessionBase):
    """S163 fix round 1 (D1) — the dispatch record must OUTLIVE the daemon.

    The tester's ledger: log a bug, File & Cost, close the window, wait for
    `filed`, confirm the card offers "⚙ FIX 1 FILED BUG", `kill -9` the daemon,
    relaunch — and the card reverted to the pre-S163 dead end. No Go had been
    taken and no driver had ever run.

    The mark that suppresses the control was in-memory, which is fine (a Go this
    daemon took is a fact this daemon can hold); the FALLBACK that was supposed
    to cover a restart was not, because it read a per-child flag the ESTIMATOR
    sets. So the cure is on both sides, and this class owns the daemon half:
    "this parent's Go was dispatched" is written to disk, next to the mission it
    is about, and a brand-new `Actions` over the same repo reads it back.

    Restart is simulated the honest way — a SECOND `Actions` over the same
    repo_root, with none of the first one's memory. Nothing else could tell an
    in-memory fact from a durable one.
    """

    def _restarted(self):
        """A daemon that has just booted over this repo: same scripts, same
        worker, ZERO carried-over memory."""
        from lcars_serve.actions import Actions
        return Actions(repo_root=self.tmp, scripts=self.scripts,
                       worker_bin=self.worker_bin)

    def _card_of(self, board, mid="m-001"):
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s on the board" % mid)

    def _plant_estimator_events(self):
        """What File & Cost really leaves on each filed child.

        `log.sh` runs `run.sh estimate` per bug; `estimate` spawns a cold worker
        and `usage_capture` appends a `worker_usage` event to that child's
        events.jsonl — before the captain has seen a single pill. The suite's
        log.sh stub plants the child + its estimate.json but not this, so plant
        it here: without it these tests would measure a repo that cannot exist,
        which is precisely the fiction D1 was hiding in.
        """
        planted = []
        for name in self._on_disk():
            d = os.path.join(self.tmp, ".git", "lcars", "missions", name)
            with open(os.path.join(d, "events.jsonl"), "a") as fh:
                fh.write(json.dumps({
                    "ts": "2026-08-01T10:00:01Z", "type": "worker_usage",
                    "stage": "estimate", "message": "usage captured",
                    "engine": "claude", "cost": "0.01"}) + "\n")
            planted.append(name)
        self.assertTrue(planted, "no bug children were filed")
        return planted

    def _file_a_batch(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._plant_estimator_events()
        return sid

    # -- the premise, measured --------------------------------------------
    def test_a_filed_child_is_dispatched_true_before_anything_drives_it(self):
        """The root cause, pinned against the REAL LocalAdapter so no future
        session can put `dispatched` back into the "has a driver touched this?"
        question. It is the ESTIMATOR's footprint, not a driver's."""
        self._file_a_batch(BUG_A, BUG_B)
        board = self.adapter.board()
        kids = [c for c in self._cards(board)
                if c.get("id", "").startswith("m-bug")]
        self.assertEqual(len(kids), 2)
        for c in kids:
            self.assertTrue(c["dispatched"],
                            "a filed bug child reads dispatched=False — the "
                            "estimator no longer writes events, so this test's "
                            "premise (and D1's) needs re-measuring")
            self.assertFalse(c["queued"], "nothing has scheduled it")
            self.assertFalse(c["running"], "nothing is driving it")

    # -- the durable record -------------------------------------------------
    def test_the_dispatch_record_survives_a_restart(self):
        """The blocking defect. Go, then throw the daemon away."""
        self._file_a_batch(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        fresh = self._restarted()
        card = self._card_of(fresh.log_overlay(self.adapter.board()))
        self.assertIsNotNone(
            card.get("logDispatch"),
            "a restarted daemon forgot the captain's Go — the card will "
            "re-offer a review of a batch that is already being driven")
        self.assertEqual(card["logDispatch"]["status"], "dispatched")

    def test_the_restarted_detail_mirrors_it(self):
        """The detail never runs through the board overlay (the
        `align_overlay_mission` lesson), so it needs its own read."""
        self._file_a_batch(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        fresh = self._restarted()
        detail = fresh.log_overlay_mission(self.adapter.mission("m-001"))
        self.assertEqual(detail["logDispatch"]["status"], "dispatched")

    def test_a_filed_but_undispatched_batch_leaves_no_record(self):
        """The other edge, and the one the whole session is FOR: filing alone
        must never look like a dispatch. This is the tester's exact journey up
        to the restart — File & Cost, close, restart, no Go ever taken."""
        self._file_a_batch(BUG_A)
        fresh = self._restarted()
        board = fresh.log_overlay(self.adapter.board())
        self.assertNotIn("logDispatch", self._card_of(board))
        detail = fresh.log_overlay_mission(self.adapter.mission("m-001"))
        self.assertNotIn("logDispatch", detail)

    def test_a_repo_that_never_logged_a_bug_is_byte_identical(self):
        """The additive-payload invariant, at the durable half's source: a
        restarted daemon that reads no record returns the adapter's board
        untouched."""
        fresh = self._restarted()
        board = self.adapter.board()
        snapshot = copy.deepcopy(board)
        self.assertEqual(fresh.log_overlay(board), snapshot)

    def test_the_record_names_the_batch_it_is_about(self):
        """It is written next to the mission it describes, and it says which
        children the Go covered — the next session reading this file should not
        have to guess what it was a record OF."""
        sid = self._file_a_batch(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        path = os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                            "log-dispatch.json")
        self.assertTrue(os.path.isfile(path), "no durable record on disk")
        with open(path) as fh:
            rec = json.load(fh)
        self.assertEqual(rec["status"], "dispatched")
        self.assertEqual(sorted(rec["children"]), self._on_disk())
        self.assertTrue(rec.get("at"), "the record must say WHEN")
        # S163 fix round 2: and WHERE the Go came from. A dispatch taken through
        # the disk fallback has no session to name, so `sessionId` is honestly
        # null there; without this field that null read as a dropped join key.
        self.assertEqual(rec["source"], "session")
        self.assertEqual(rec["sessionId"], sid)

    def test_a_disk_fallback_go_records_where_it_came_from(self):
        """The tester's cheap-honesty item. After a restart the review is rebuilt
        from the linked children and there is no session — `sessionId: null` is
        the truthful answer, and `source` is what makes it legible as an answer
        rather than a lost field."""
        self._file_a_batch(BUG_A)
        fresh = self._restarted()          # the session is gone with the daemon
        fresh.log_run("m-001", overrides=[])
        path = os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                            "log-dispatch.json")
        with open(path) as fh:
            rec = json.load(fh)
        self.assertEqual(rec["status"], "dispatched")
        self.assertIsNone(rec["sessionId"],
                          "a restarted daemon invented a session id")
        self.assertEqual(rec["source"], "children")

    def test_the_record_is_not_written_before_the_go(self):
        self._file_a_batch(BUG_A)
        self.assertFalse(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-dispatch.json")), "filing alone wrote a dispatch record")

    def test_a_live_session_outranks_a_SETTLED_record(self):
        """A NEW report against the same parent is a new batch, and the live
        session is the more recent, more detailed fact — ONCE THE OLD BATCH IS
        DONE. That rule already governed the in-memory mark
        (`_log_dispatch_stamps` drops any parent holding a session); it governs
        the DURABLE one too, or the review of a fresh batch would be suppressed
        by the last batch's Go.

        S163 fix round 6 (D3) narrowed it by one word, and the word is load
        bearing: SETTLED. Applied to a batch still being driven, this rule hid a
        live drive behind a fresh preview and let the Go spawn a second
        resolve-logs over the same children — see `DoubleDispatchTest`. So the
        batch is walked to its consolidated gate here before the new report is
        logged, which is the state this rule was always describing.

        The record itself is deliberately LEFT on disk — it is still true about
        the batch it names, and a preview the captain abandons must not be able
        to un-say a dispatch that really happened.
        """
        self._file_a_batch(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self._settle("m-bug1")        # the batch reaches its re-verify gate
        self._preview(BUG_B)          # the captain logs another bug
        _s, board = self._get("/api/board")
        card = self._card_of(board)
        self.assertNotIn("logDispatch", card,
                         "the dispatch record suppressed a fresh preview")
        self.assertEqual(card["logFiling"]["status"], "previewed")
        self.assertTrue(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-dispatch.json")), "the record of a real dispatch was erased")

    def _settle(self, *mids):
        """Walk dispatched bug children to their `verify` gate — what
        resolve-logs does, and the ONLY thing that ends a drive as far as the
        daemon is concerned (S163 fix round 6, D3)."""
        for mid in mids:
            sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                              "state.json")
            with open(sp) as fh:
                state = json.load(fh)
            state["stage"] = "verify"
            with open(sp, "w") as fh:
                json.dump(state, fh, indent=2)

    def test_only_the_parent_carries_it(self):
        self._file_a_batch(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        fresh = self._restarted()
        board = fresh.log_overlay(self.adapter.board())
        others = [c for c in self._cards(board) if c["id"] != "m-001"]
        self.assertTrue(all("logDispatch" not in c for c in others))


# ════════════════════════════════════════════════════════════════════════════
# S163 fix round 3 — "show me everything that will run" (the captain's ruling,
# 2026-08-01).
#
# The round-3 tester found the review panel and the dispatch answering two
# different questions. `log_session_state` filtered its children to `filed_ids`
# — S161's deliberate defence against a parent that already carried bug children
# from an earlier report INFLATING the batch count — while `Go ▸` has always
# spawned `resolve-logs --parent <mid>`, which drives the whole parent to ONE
# consolidated gate. And `_apply_child_overrides` paired the captain's steers
# POSITIONALLY against every linked child, sorted by mission dir name, not
# against the rows the panel actually rendered.
#
# Measured on a clean parent, two reports, no Go in between: the card counted 1
# while 3 bugs waited, the panel listed only the newest, `all:opus` typed against
# "second report bug three" was written onto "first report bug one" — a bug that
# was never on screen — and the Go dispatched all three.
#
# The captain's ruling reverses S161's filter for the REVIEW path: show every
# bug on the mission still waiting to be fixed, whatever report it came from,
# each with its pills and its own steer, and tie each steer to the bug's MISSION
# ID rather than to its position. The inflated-count risk S161 was defending
# against is answered by making the count honest for the new meaning ("N bugs
# waiting to be fixed on this mission"), not by hiding bugs the Go will run.
# ════════════════════════════════════════════════════════════════════════════
class WaitingReviewTest(_LogSessionBase):
    """D2 — the panel, the count and the dispatch are one list, keyed by id."""

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _session(self):
        _s, sess = self._get("/api/mission/m-001/log/session")
        return sess

    def _override(self, mid):
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                          "state.json")
        with open(sp) as fh:
            return json.load(fh).get("modelOverride")

    def _dispatch_record(self):
        with open(os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                               "log-dispatch.json")) as fh:
            return json.load(fh)

    # -- 1. two reports, no Go ------------------------------------------------
    def test_a_second_report_never_shrinks_the_review(self):
        """The tester's D2, at its source. Report 1 files two bugs and is left
        undispatched; report 2 files a third. The review must be all three."""
        self._file(BUG_A, BUG_B)
        self._file(BUG_C)
        sess = self._session()
        self.assertEqual(sorted(c["id"] for c in sess["children"]),
                         ["m-bug1", "m-bug2", "m-bug3"],
                         "the review still shows one batch, not the mission")
        self.assertEqual(sess["waitingCount"], 3)
        self.assertEqual(self._stamp()["waitingCount"], 3,
                         "the CARD's count dropped while three bugs waited")

    def test_the_batch_measurements_still_mean_what_they_meant(self):
        """Widening the review must not blur the two counts a shortfall is told
        from. `bugCount`/`filedCount` stay THIS batch's measurements (S161's D2
        rule); `waitingCount` is the new, differently-named fact."""
        self._file(BUG_A, BUG_B)
        self._file(BUG_C)
        sess = self._session()
        self.assertEqual(sess["bugCount"], 1)
        self.assertEqual(sess["filedCount"], 1)
        self.assertEqual(sess["waitingCount"], 3)

    # -- 2. the steer lands on the bug it was typed against -------------------
    def test_the_steer_lands_on_the_bug_it_was_typed_against(self):
        """The most severe half of D2: `{"m-bug3": "all:opus"}` must reach
        m-bug3 and nothing else. Asserted from the CHILD's persisted state.json
        — the lever resolve-logs/run.sh actually reads."""
        self._file(BUG_A, BUG_B)
        self._file(BUG_C)
        self._post("/api/mission/m-001/log/run",
                   {"overrides": {"m-bug3": "all:opus"}})
        self.assertEqual(self._override("m-bug3"),
                         {"scope": "all", "tier": "opus"})
        self.assertIsNone(self._override("m-bug1"),
                          "the steer landed on a bug that was never on screen")
        self.assertIsNone(self._override("m-bug2"))

    def test_the_report_names_the_bug_each_steer_reached(self):
        self._file(BUG_A, BUG_B)
        _s, resp = self._post("/api/mission/m-001/log/run",
                              {"overrides": {"m-bug2": "all:opus"}})
        rep = (resp.get("state") or resp).get("overrides") or []
        hit = [r for r in rep if r.get("resolved")]
        self.assertEqual([r["id"] for r in hit], ["m-bug2"])

    # -- 7. an unknown id is REPORTED, never silently dropped -----------------
    def test_a_steer_for_a_bug_that_is_not_here_is_reported(self):
        """S161 already fixed the positional version of this once (a
        mis-length override list used to be dropped outright). A keyed scheme
        must make the silent drop impossible, not merely unlikely."""
        self._file(BUG_A)
        _s, resp = self._post("/api/mission/m-001/log/run",
                              {"overrides": {"m-bug404": "all:opus"}})
        rep = (resp.get("state") or resp).get("overrides") or []
        self.assertEqual([r["id"] for r in rep], ["m-bug404"])
        self.assertTrue(rep[0].get("error"),
                        "a steer for an unknown bug was swallowed: %r" % rep)
        self.assertIsNone(rep[0].get("resolved"))

    # -- 3. everything Go runs was in the panel -------------------------------
    def test_everything_the_go_runs_was_in_the_panel(self):
        """`resolve-logs --parent` drives the whole parent. The panel is the
        promise about that, so the two lists must be the same list."""
        self._file(BUG_A, BUG_B)
        self._file(BUG_C)
        shown = sorted(c["id"] for c in self._session()["children"])
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(sorted(self._dispatch_record()["children"]), shown,
                         "the Go covered bugs the review never showed")

    def test_the_go_still_spawns_exactly_one_resolve_logs_for_the_parent(self):
        """No second dispatch path (the round's invariant)."""
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        # `_spawn` is fire-and-forget (BUG-G), so the stub's record lands a beat
        # after the POST returns — wait for it rather than racing it.
        deadline = time.time() + 10
        argvs = []
        while time.time() < deadline:
            argvs = [ln for ln in self._record("resolve").splitlines()
                     if ln.startswith("ARGV: ")]
            if argvs:
                break
            time.sleep(0.05)
        self.assertEqual(argvs, ["ARGV: --parent m-001"])

    # -- 5. a second Go is refused, not rubber-stamped ------------------------
    def test_a_second_go_on_a_dispatched_parent_is_refused(self):
        """D3's tail. The tester pressed Go twice and got `ok:true` both times,
        with the dispatch record's timestamp quietly rewritten.

        Round 7: pinned to a LIVE resolver, because this asserts the refusal for
        a drive that is genuinely in flight. The refusal for a drive that has
        DIED is a different sentence and is owned by
        `DeadResolverTest.test_the_plain_go_still_refuses_and_now_says_what_to_do`
        — both are 409s, and neither may be the other's words."""
        _pin_live_resolver(self)
        self._file(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        at = self._dispatch_record()["at"]
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {}})
        self.assertEqual(code, 409)
        self.assertIn("already", msg.lower())
        self.assertEqual(self._dispatch_record()["at"], at,
                         "a refused Go still rewrote the record")

    def test_a_settled_batch_re_arms_the_go(self):
        """...and the refusal must not become a one-way door.

        S163 fix round 6 (D3) changed WHAT re-arms it. This used to assert that
        a fresh REPORT did — `_new_log_session` spent the mark — and that is the
        defect the round-6 tester measured: logging one more bug against a
        parent mid-drive re-armed a Go that then spawned a second resolve-logs
        over the first drive's children. What re-arms it now is the earlier
        batch reaching its consolidated gate, which is the moment it is actually
        safe. `DoubleDispatchTest` owns both halves in detail; this keeps the
        door itself pinned open right beside the 409 that closes it.
        """
        self._file(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._file(BUG_C)
        code, _msg = self._post_err("/api/mission/m-001/log/run",
                                    {"overrides": {}})
        self.assertEqual(code, 409, "a new report re-armed a live drive")
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", "m-bug1",
                          "state.json")
        with open(sp) as fh:
            st = json.load(fh)
        st["stage"] = "verify"
        with open(sp, "w") as fh:
            json.dump(st, fh, indent=2)
        _s, resp = self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertTrue((resp.get("ok") is not False))


class PartialDispatchStateTest(_LogSessionBase):
    """D3 — after a Go on a PARTIAL batch the card must say the work is running,
    live and after a restart, and it must say the SAME thing in both.

    The Go on a partial deliberately KEEPS its session (N1: it is the only copy
    of the unfiled bug's authored text). `_log_dispatch_stamps` dropped any
    parent holding a live session, so the retained session hid the dispatch mark
    and the card went on offering "⚙ FIX 1 OF 2 FILED BUGS" over a batch
    resolve-logs was already driving — while a restarted daemon, reading the same
    disk, said "◐ resolving 1 logged bug…". One repo state, two answers.
    """

    def _partial(self):
        """A 2-bug batch where the second is refused: `partial`, 1 of 2."""
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        return sid

    def _card(self, mid="m-001", board=None):
        if board is None:
            _s, board = self._get("/api/board")
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    def _restarted(self):
        from lcars_serve.actions import Actions
        return Actions(repo_root=self.tmp, scripts=self.scripts,
                       worker_bin=self.worker_bin)

    def test_a_partial_go_is_stated_as_in_flight(self):
        sid = self._partial()
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        card = self._card()
        self.assertIsNotNone(card.get("logDispatch"),
                             "the card never said the work was running")
        self.assertEqual(card["logDispatch"]["sessionId"], sid)

    def test_the_shortfall_note_survives_the_dispatch(self):
        """...and saying it must not cost the shortfall. Both stamps ride the
        same card: `logDispatch` withdraws the Fix control, `logFiling` keeps
        S162's "only 1 of 2 filed" note underneath it."""
        self._partial()
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        card = self._card()
        self.assertEqual(card["logFiling"]["status"], "partial")
        self.assertEqual(card["logFiling"]["filedCount"], 1)
        self.assertEqual(card["logFiling"]["bugCount"], 2)

    def test_the_detail_says_the_same(self):
        self._partial()
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        _s, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["logDispatch"]["status"], "dispatched")

    def test_a_restart_agrees_with_the_live_daemon(self):
        """The contradiction, pinned: same disk, two daemons, one answer."""
        self._partial()
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        live = self._card()
        fresh = self._restarted()
        after = self._card(board=fresh.log_overlay(self.adapter.board()))
        self.assertEqual("logDispatch" in live, "logDispatch" in after,
                         "the live daemon and a restarted one disagree about "
                         "whether the Go was taken")
        self.assertEqual(live["logFiling"]["filedCount"],
                         after["logFiling"]["filedCount"])


class DurableShortfallTest(_LogSessionBase):
    """D4 — CAPTAIN'S RULING: "save it to disk".

    A partial's counts and, above all, the AUTHORED TEXT of the bugs that never
    filed lived only in daemon memory. `kill -9` and the shortfall was gone: the
    card read a plain "⚙ FIX 1 FILED BUG", `/log/session` 404'd, and a batch
    where 1 of 2 was dropped became indistinguishable from a clean 1-bug batch.
    S161 made "the unfiled text is preserved verbatim and retryable" a
    ship-blocker-grade promise; this makes the promise survive a restart.

    DELIBERATELY NARROW: what is persisted is the SHORTFALL — the two counts, the
    child ids that landed, and the unfiled rows' text — not the session. Durable
    sessions (v2) remain out of scope for both consoles.
    """

    def _partial(self):
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        return sid

    def _simulate_restart(self):
        """Throw away everything the daemon held in memory, in place.

        The sibling suites simulate a restart with a SECOND `Actions` over the
        same repo, which is the honest shape for a read. This test also has to
        drive a RETRY over HTTP, and the server is bound to `self.actions` — so
        the restart is done by emptying that instance instead. It drops exactly
        what a process death drops: the sessions, the retirement ledger and the
        in-memory dispatch marks.
        """
        with self.actions._log_lock:
            self.actions._log_sessions.clear()
            self.actions._log_retired.clear()
            self.actions._log_dispatched.clear()
        self.actions._log_rehydrated = False

    def _card(self, mid="m-001", board=None):
        if board is None:
            _s, board = self._get("/api/board")
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    def test_the_record_lands_beside_the_dispatch_record(self):
        self._partial()
        path = os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                            "log-shortfall.json")
        self.assertTrue(os.path.isfile(path), "the shortfall was not persisted")
        with open(path) as fh:
            rec = json.load(fh)
        self.assertEqual(rec["bugCount"], 2)
        self.assertEqual(rec["filedCount"], 1)
        self.assertIn("Leaderboard", rec["unfiled"][0]["prd"],
                      "the unfiled bug's authored text is not in the record")

    def test_a_clean_batch_leaves_no_shortfall_record(self):
        """The additive rule: a repo whose batches all landed must carry
        nothing extra."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertFalse(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-shortfall.json")))

    def test_the_card_still_says_one_of_two_after_a_restart(self):
        self._partial()
        before = self._card()["logFiling"]
        self._simulate_restart()
        after = self._card()["logFiling"]
        self.assertEqual(after["status"], "partial",
                         "the restart erased the shortfall")
        self.assertEqual((after["bugCount"], after["filedCount"]),
                         (before["bugCount"], before["filedCount"]))

    def test_the_unfiled_text_is_readable_after_a_restart(self):
        self._partial()
        self._simulate_restart()
        _s, sess = self._get("/api/mission/m-001/log/session")
        self.assertEqual(sess["status"], "partial")
        self.assertEqual(sess["unfiledCount"], 1)
        self.assertIn("Leaderboard", sess["unfiled"][0]["prd"])

    def test_a_retry_after_a_restart_files_only_the_missing_bug(self):
        """The promise in full: not just readable, RETRYABLE — and it must not
        duplicate the bug that already landed or spend a second split turn."""
        self._partial()
        splits = self._splits()
        self._simulate_restart()
        _s, sess = self._get("/api/mission/m-001/log/session")
        self._allow_all()
        self._post("/api/mission/m-001/log/file",
                   {"sessionId": sess["sessionId"]})
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(len(self._on_disk()), 2,
                         "the retry duplicated a bug or filed nothing")
        self.assertEqual(done["filedCount"], 2)
        self.assertEqual(self._splits(), splits,
                         "the retry paid for a second split worker turn")
        self.assertFalse(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-shortfall.json")),
            "a completed batch left a stale shortfall record behind")

    def test_a_discard_clears_it(self):
        """The captain's deliberate "I am done with the leftover" must reach
        disk too, or the card would resurrect the shortfall on the next restart."""
        self._partial()
        self._post("/api/mission/m-001/log/discard", {})
        self.assertFalse(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-shortfall.json")))
        self._simulate_restart()
        self.assertIsNone(self._card().get("logFiling"))

    def test_a_repo_with_no_shortfall_is_byte_identical(self):
        """The additive-payload invariant at this half's source."""
        self._simulate_restart()
        board = self.adapter.board()
        snapshot = copy.deepcopy(board)
        self.assertEqual(self.actions.log_overlay(board), snapshot)


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class UnfiledPreviewCoexistenceTest(unittest.TestCase):
    """D1 — an unfiled preview must not hide the bugs waiting to be fixed.

    The tester's journey: file a good 2-bug batch, leave it undispatched, log a
    second report that files nothing, then click "⚙ FIX 2 FILED BUGS". They
    landed in the FAILED session's console — two `Untitled bug`s, no estimate
    pills, no override boxes — and a `Go ▸` whose only reply was "Click File
    first". The only escape was `Discard Preview`, which destroys the unfiled
    bugs' authored text. The control's own tooltip promised the cost review.

    Both facts are real and neither may erase the other, so both are on screen:
    the review of the bugs waiting to be fixed AND the recovery panel holding the
    text that never filed.
    """

    WAITING = [
        {"id": "m-002", "issue": 200, "title": "Score resets on reload",
         "stage": "plan", "type": "bug",
         "pills": {"cost": {"label": "$1–2", "level": "low"},
                   "reasoning": {"label": "R low", "level": "low"},
                   "implementation": {"label": "I low", "level": "low"}},
         "modelMix": [{"stage": "plan", "model": "Sonnet"}]},
        {"id": "m-003", "issue": 201, "title": "Badge art misaligned",
         "stage": "plan", "type": "bug",
         "pills": {"cost": {"label": "$1–2", "level": "low"},
                   "reasoning": {"label": "R low", "level": "low"},
                   "implementation": {"label": "I low", "level": "low"}},
         "modelMix": [{"stage": "plan", "model": "Sonnet"}]},
    ]

    def _session(self, status):
        """A live session for a SECOND report that put nothing on disk, on a
        parent that is already holding two filed-but-undispatched bugs."""
        return {
            "sessionId": "def456", "parent": "m-001", "status": status,
            "authored": True, "filed": False,
            "bugCount": 2, "filedCount": 0,
            "children": [{"title": "Untitled bug", "prd": "no title line\n"},
                         {"title": "Untitled bug", "prd": "also no title\n"}],
            "unfiled": [{"index": 0, "title": "Untitled bug",
                         "prd": "no title line\n"},
                        {"index": 1, "title": "Untitled bug",
                         "prd": "also no title\n"}],
            "unfiledCount": 2,
            "waiting": self.WAITING, "waitingCount": 2,
            "error": "nothing was filed — none of the 2 authored bugs "
                     "reached disk",
        }

    def test_the_fix_control_lands_on_the_cost_review(self):
        res = _console("openFix", VERIFY, session=self._session("failed"))
        texts = _texts(res)
        self.assertIn("Bug · Score resets on reload", texts,
                      "the waiting bugs are not on screen: %s" % texts)
        self.assertTrue(any("$1–2" in t for t in texts),
                        "no estimate pills — this is not a cost review: %s"
                        % texts)
        inputs = [n for n in _flatten(res["node"]) if n["tag"] == "input"]
        self.assertGreaterEqual(len(inputs), 2,
                                "no per-bug model-override boxes")
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"],
                        "Go must be armed — the waiting bugs are what it runs")

    def test_the_unfiled_text_is_still_there_afterwards(self):
        """...and reaching the review must not have cost the other fact."""
        res = _console("openFix", VERIFY, session=self._session("failed"))
        texts = _texts(res)
        self.assertTrue(
            any("did NOT file" in t for t in texts),
            "the unfiled bugs' recovery panel is gone: %s" % texts)
        bodies = [n for n in _flatten(res["node"])
                  if n["tag"] == "textarea" and "no title line" in n["value"]]
        self.assertTrue(bodies, "the authored text itself is not recoverable")

    def test_a_live_previewed_report_does_the_same(self):
        """The same shape one status earlier: a report split but not yet filed.
        Nothing about the two bugs waiting on disk has changed."""
        res = _console("openFix", VERIFY, session=self._session("previewed"))
        self.assertIn("Bug · Score resets on reload", _texts(res))
        go = [n for n in _flatten(res["node"])
              if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(go and not go[0]["hidden"])

    def test_it_still_dispatches_nothing_on_its_own(self):
        """BUG-059's hold, in the state that made it tempting to bend."""
        res = _console("openFix", VERIFY, session=self._session("failed"))
        self.assertEqual([f["url"] for f in res["fetches"]
                          if f["method"] == "POST"], [])

    def test_the_go_runs_the_waiting_bugs(self):
        res = _console("fixThenGo", VERIFY, session=self._session("failed"))
        runs = [f for f in res["fetches"] if f["url"].endswith("/log/run")]
        self.assertEqual(len(runs), 1,
                         "Go refused the waiting bugs: %s" % res.get("status"))

    def test_a_steer_in_that_panel_is_keyed_to_its_bug(self):
        res = _console("fixSteerGo", VERIFY, session=self._session("failed"),
                       steer="use Opus")
        body = None
        for f in res["fetches"]:
            if f["url"].endswith("/log/run"):
                body = f["body"]
        # S163 fix round 6 (D1): the payload is the PANEL — every rendered box,
        # empty ones included, so a cleared steer can be said.
        self.assertEqual((body or {}).get("overrides"),
                         {"m-002": "use Opus", "m-003": ""})


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class WaitingCountCardTest(unittest.TestCase):
    """The card half of the ruling: the count is "bugs waiting to be fixed on
    this mission", published by the daemon as `waitingCount` on the stamp."""

    def test_the_count_is_every_waiting_bug_not_the_last_batch(self):
        """D2's shrinking count. A 1-bug second report on a parent already
        holding two undispatched bugs must read 3, never 1."""
        st = _stamp("filed", 1, 1)
        st["waitingCount"] = 3
        res = _drive(dict(VERIFY, logFiling=st),
                     children=[_kid(i) for i in range(3)])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl)
        self.assertEqual(ctl["text"], "⚙ FIX 3 FILED BUGS")

    def test_a_live_preview_no_longer_hides_the_waiting_bugs(self):
        """D1 on the card: a second report still being authored (`previewed`)
        used to withdraw the control entirely."""
        st = _stamp("previewed", 2, 0)
        st["waitingCount"] = 2
        res = _drive(dict(VERIFY, logFiling=st),
                     children=[_kid(i) for i in range(2)])
        self.assertIsNotNone(_fix_control(res),
                             "an unfiled preview hid two waiting bugs: %s"
                             % _texts(res))

    def test_a_dispatched_partial_says_the_work_is_running(self):
        """D3 on the card: both stamps ride together after a Go on a partial —
        the dispatch withdraws the control, the filing stamp keeps the note."""
        st = _stamp("partial", 2, 1, error="only 1 of 2 authored bugs filed")
        st["waitingCount"] = 1
        m = dict(VERIFY, logFiling=st,
                 logDispatch={"sessionId": "abc123", "status": "dispatched"})
        res = _drive(m, children=[_kid(0)])
        self.assertIsNone(_fix_control(res),
                          "the Fix control outlived the Go: %s" % _texts(res))
        self.assertIsNotNone(_resolving_control(res),
                             "the card never says the work is running: %s"
                             % _texts(res))
        self.assertIsNotNone(_shortfall_note(res),
                             "...and the shortfall note was lost with it")



# ════════════════════════════════════════════════════════════════════════════
# S163 fix round 4 — "the harness misdescribing what it did"
#
# Four defects, one class. Round 4's tester confirmed the session's central
# ruling holds (the panel is every waiting bug, keyed by id) and then found four
# places where the product SAYS one thing and DOES another:
#
#   D1  a steer the parser cannot resolve is accepted, echoed as if it were
#       pending, sent over the wire and dropped with no trace.
#   D2  five simultaneous Gos produced five resolve-logs drivers, because the
#       round-3 refusal is a check-then-act against a file.
#   D3  the read-only board tells a different story about the same mission at
#       the same instant, because it is built with `actions=None`.
#   D4  a filing interrupted by a daemon death re-reads as a SETTLED batch.
# ════════════════════════════════════════════════════════════════════════════


class SteerRefusalTest(_LogSessionBase):
    """D1 — a steer is applied, or the captain is TOLD it was not.

    The tester typed four different overrides into a 4-bug review and pressed
    Go. Two resolved; two ("use haiku", "be really thorough on this one") were
    accepted, echoed as `pending` with the sentence "model intent resolved when
    filed", posted, and then discarded — `modelOverride` null on disk, the raw
    words nowhere under `.git/lcars/`, and the batch dispatched anyway. The copy
    was false twice over: the bugs were ALREADY filed (this IS the post-filing
    review) and nothing was ever going to resolve them.

    The cure is the one the unknown-bug-id case already models — report, never
    drop — carried one step further, because at Go there is no console left to
    report INTO: an unresolvable steer for a bug the Go would drive REFUSES the
    dispatch. Nothing spawns, no dispatch record is written, and the message
    names the bug and the reason.
    """

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _override(self, mid):
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                          "state.json")
        with open(sp) as fh:
            return json.load(fh).get("modelOverride")

    def _dispatch_record_exists(self):
        return os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-dispatch.json"))

    def _resolve_argvs(self):
        """resolve-logs invocations. `_spawn` is fire-and-forget, so give the
        stub a beat to record one before concluding nothing ran."""
        deadline = time.time() + 1.5
        while time.time() < deadline:
            argvs = [ln for ln in self._record("resolve").splitlines()
                     if ln.startswith("ARGV: ")]
            if argvs:
                return argvs
            time.sleep(0.05)
        return []

    def test_an_unresolvable_steer_refuses_the_go_and_dispatches_nothing(self):
        """The tester's "be really thorough on this one": no model intent the
        deterministic parse or the bounded worker can turn into a tier."""
        self._file(BUG_A)
        self._set_turns({"junk": "the worker had no idea either"})
        code, msg = self._post_err(
            "/api/mission/m-001/log/run",
            {"overrides": {"m-bug1": "be really thorough on this one"}})
        self.assertEqual(code, 400)
        self.assertIn("m-bug1", msg)
        self.assertIn("be really thorough on this one", msg)
        self.assertEqual(self._resolve_argvs(), [],
                         "the batch was dispatched with a dropped steer")
        self.assertFalse(self._dispatch_record_exists(),
                         "a refused Go still recorded a dispatch")
        self.assertIsNone(self._override("m-bug1"))

    def test_an_unsupported_model_is_named_not_swallowed(self):
        """"use haiku" — `haiku` is not a tier LCARS can choose. Say so, and
        say it WITHOUT spending a worker turn discovering the obvious."""
        self._file(BUG_A)
        splits = self._splits()
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {"m-bug1": "use haiku"}})
        self.assertEqual(code, 400)
        self.assertIn("haiku", msg.lower())
        self.assertIn("opus", msg.lower())
        self.assertIn("sonnet", msg.lower())
        self.assertEqual(self._splits(), splits,
                         "a steer that can never resolve still paid for a "
                         "worker turn")

    def test_the_refused_steer_is_still_there_when_the_console_reopens(self):
        """A refusal that eats the captain's words is the same loss as a drop,
        one click later. The daemon keeps the verdict on the session, so the
        reopened console echoes the error against the right bug — the same
        `overrides` channel the File step already uses."""
        self._file(BUG_A, BUG_B)
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "use haiku"}})
        _s, sess = self._get("/api/mission/m-001/log/session")
        rep = [r for r in (sess.get("overrides") or [])
               if r.get("id") == "m-bug1"]
        self.assertTrue(rep, "the refused steer left no verdict to echo: %r"
                             % sess.get("overrides"))
        self.assertEqual(rep[0]["raw"], "use haiku")
        self.assertTrue(rep[0].get("error"))
        self.assertIsNone(rep[0].get("resolved"))

    def test_the_verdict_rides_a_failed_session_too(self):
        """The live-daemon gap the unit tests missed.

        A Go is legitimate from a `failed` session — round 3's ruling is that the
        panel lists every bug WAITING on the mission, whatever report it came
        from, so a second report that filed nothing still shows (and can run) the
        first report's bugs. `/log/session` carried its `overrides` verdicts only
        on the two statuses that describe a filed batch, so on exactly that
        console a refused Go's reason evaporated. Measured against the round-4
        fixture's `-002` before it shipped."""
        self._file(BUG_A)
        self._refuse("")                       # a second report that files nothing
        sid = self._preview(BUG_B, discard_unfiled=True)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "use haiku"}})
        _s, sess = self._get("/api/mission/m-001/log/session")
        self.assertEqual(sess["status"], "failed")
        rep = [r for r in (sess.get("overrides") or [])
               if r.get("id") == "m-bug1"]
        self.assertTrue(rep, "the refused steer's reason vanished on a failed "
                             "session: %r" % sess.get("overrides"))
        self.assertEqual(rep[0]["raw"], "use haiku")
        self.assertTrue(rep[0].get("error"))

    def test_the_verdict_survives_the_first_go_after_a_restart(self):
        """The other live gap: the durable-record scan is LAZY, so on a freshly
        booted daemon the first Go merged its verdicts into a session that had
        not been read back yet, and the reason vanished. The restarted console
        is precisely the one the captain reopens."""
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        with self.actions._log_lock:                 # a kill -9, in place
            self.actions._log_sessions.clear()
            self.actions._log_dispatched.clear()
        self.actions._log_rehydrated = False
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "use haiku"}})
        _s, sess = self._get("/api/mission/m-001/log/session")
        rep = [r for r in (sess.get("overrides") or [])
               if r.get("id") == "m-bug1"]
        self.assertTrue(rep, "the first Go after a restart lost its verdict: %r"
                             % sess.get("overrides"))
        self.assertTrue(rep[0].get("error"))

    def test_a_good_steer_beside_a_bad_one_is_not_half_applied(self):
        """All-or-nothing, and MEASURED on both bugs.

        The first cut of this cure resolved-and-wrote in one pass, so the good
        steer was already persisted when the bad one was reached — and the
        refusal still said "nothing has been changed". Caught on the live daemon
        against the round-4 fixture: `use Opus` had landed on the first bug while
        the message promised it had not."""
        self._file(BUG_A, BUG_B)
        code, msg = self._post_err(
            "/api/mission/m-001/log/run",
            {"overrides": {"m-bug1": "use Opus", "m-bug2": "use haiku"}})
        self.assertEqual(code, 400)
        self.assertEqual(self._resolve_argvs(), [])
        self.assertIsNone(self._override("m-bug2"))
        self.assertIsNone(self._override("m-bug1"),
                          "the refusal said nothing had changed, and the good "
                          "steer beside the bad one had already been written: "
                          "%s" % msg)

    def test_clearing_the_bad_steer_lets_the_go_through(self):
        """...and the refusal is not a one-way door."""
        self._file(BUG_A)
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "use haiku"}})
        _s, resp = self._post("/api/mission/m-001/log/run",
                              {"overrides": {"m-bug1": "use Opus"}})
        self.assertIsNot(resp.get("ok"), False)
        self.assertEqual(self._override("m-bug1"),
                         {"scope": "all", "tier": "opus"})
        self.assertTrue(self._dispatch_record_exists())

    def test_a_steer_for_a_bug_that_is_not_here_still_only_reports(self):
        """UNCHANGED, deliberately. A steer naming a bug the Go is not running
        cannot send anything to the wrong model, so it is reported (the model
        the tester called already-correct) rather than blocking the batch."""
        self._file(BUG_A)
        _s, resp = self._post("/api/mission/m-001/log/run",
                              {"overrides": {"m-bug404": "all:opus"}})
        rep = (resp.get("state") or resp).get("overrides") or []
        self.assertEqual([r["id"] for r in rep], ["m-bug404"])
        self.assertTrue(rep[0].get("error"))
        self.assertTrue(self._dispatch_record_exists(),
                        "an unknown id must not block the bugs that ARE here")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class SteerEchoHonestyTest(unittest.TestCase):
    """D1's client half — the sentence that lied.

    `.steer-echo.pending` reached the screen amber and said "model intent
    resolved when filed." The bug was already filed, and nothing resolved it.
    """

    WAITING = [
        {"id": "m-002", "issue": 200, "title": "Score resets on reload",
         "stage": "plan", "type": "bug",
         "pills": {"cost": {"label": "$1–2", "level": "low"},
                   "reasoning": {"label": "R low", "level": "low"},
                   "implementation": {"label": "I low", "level": "low"}}},
    ]

    def _session(self):
        return {"sessionId": "abc123", "parent": "m-001", "status": "filed",
                "authored": False, "filed": True, "bugCount": 1,
                "filedCount": 1, "unfiled": [], "unfiledCount": 0,
                "children": self.WAITING, "overrides": [],
                "waiting": self.WAITING, "waitingCount": 1}

    def _echo(self, res):
        for n in _flatten(res["node"]):
            if n["cls"].startswith("steer-echo") and not n["hidden"]:
                return n
        return None

    def test_no_echo_promises_a_resolution_that_never_comes(self):
        res = _console("fixSteer", VERIFY, session=self._session(),
                       steer="be really thorough on this one")
        echo = self._echo(res)
        self.assertIsNotNone(echo, "the steer produced no echo at all")
        self.assertNotIn("resolved when filed", echo["text"],
                         "the console still promises a resolution at a moment "
                         "that has already passed: %r" % echo["text"])

    def test_an_unsupported_model_reads_as_an_error_immediately(self):
        """"use haiku" is knowable BEFORE Go — the tier does not exist — so the
        console must say so rather than accept it as pending."""
        res = _console("fixSteer", VERIFY, session=self._session(),
                       steer="use haiku")
        echo = self._echo(res)
        self.assertIsNotNone(echo)
        self.assertIn("err", echo["cls"],
                      "an impossible steer echoed as if it might resolve: %r"
                      % echo)
        self.assertIn("haiku", echo["text"].lower())

    def test_a_resolvable_steer_still_echoes_green(self):
        res = _console("fixSteer", VERIFY, session=self._session(),
                       steer="use Opus")
        echo = self._echo(res)
        self.assertIsNotNone(echo)
        self.assertIn("ok", echo["cls"])
        self.assertIn("Opus · all stages", echo["text"])

    def test_a_refused_go_puts_the_control_back_and_says_why(self):
        res = _console("fixSteerGo", VERIFY, session=self._session(),
                       steer="use haiku",
                       run_error="couldn't understand the model steer")
        self.assertFalse(res["logRun"],
                         "a refused Go left the card claiming a dispatch")
        self.assertIn("steer", res["status"].lower())

    def test_a_refused_go_keeps_the_captains_typed_words(self):
        """Reopen the console the way the captain would — the box still holds
        what they typed, so the instruction can be edited rather than retyped
        from memory."""
        res = _console("fixSteerGoReopen", VERIFY, session=self._session(),
                       steer="use haiku",
                       run_error="couldn't understand the model steer")
        vals = [n["value"] for n in _flatten(res["node"])
                if n["tag"] == "input" and n["value"]]
        self.assertIn("use haiku", vals,
                      "the refusal ate the captain's instruction: %r" % vals)


# ── S163 fix round 5 (D1): a verdict the captain never got to read ────────────
#
# Round 4 made a bad steer REFUSE the Go, and the server half was right: every
# bad steer aggregated with its own reason, refused atomically, nothing spawned,
# nothing written, the reason persisted. What the tester then measured on the
# SCREEN was the opposite of all of it:
#
#     +  16ms  Fixes dispatched — child bug missions are being driven…
#     +  66ms  the logged bugs were NOT dispatched — …: couldn't understand …
#     +  99ms  16 active missions
#
# Three defects in three frames. The first line was OPTIMISTIC — set before the
# POST resolved, asserting a dispatch that never happened. The second was the
# truth, on screen for 33 ms (~2 frames). The third was the ROUTINE REPAINT:
# `postWrite` refreshes, `refresh` renders, and `render` writes the idle "N
# active missions" line over whatever the action just said. The same erasure hit
# the SUCCESS-with-a-non-blocking-verdict branch ("…but 1 model steer was not
# applied: …"), which the daemon really does produce.
#
# This is a walk-away feature: the captain presses Go, reads "child bug missions
# are being driven", and leaves. Nothing is running.
#
# The drives below assert on the WHOLE interaction (every frame of the status
# line, via the harness's status trace) rather than on the final frame, because
# the final frame is exactly what the bug leaves looking innocent.
BAD_STEER = "be really thorough on this one"
REFUSAL = ("the logged bugs were NOT dispatched — m-002: couldn't understand "
           "the model steer %r — try e.g. \"use Opus\". Fix or clear that steer "
           "in the review and press Go again; nothing has been run and nothing "
           "has been changed." % BAD_STEER)
# What a repaint IS: the board the daemon returns a beat after any write. Two
# missions ⇒ the idle line the render writes is "2 active missions" — the exact
# sentence that erased the verdict.
REPAINT_BOARD = {"stages": [], "columns": {}, "meta": {},
                 "missions": [{"id": "m-001"}, {"id": "m-002"}]}


def _claims_dispatch(text):
    """Does this frame tell the captain the fixes ARE dispatched / running?

    The daemon's own refusal contains the word "dispatched" (as "were NOT
    dispatched"), so the word alone cannot be the test — the CLAIM is what
    matters. An in-flight line that says a request is on its way claims
    nothing: it is the assertion of a completed dispatch that must never appear
    unless one happened."""
    t = (text or "").lower()
    if "not dispatched" in t:
        return False
    return ("fixes dispatched" in t or "being driven" in t
            or "are being driven" in t)


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class RefusalLegibilityTest(unittest.TestCase):
    """The refusal must reach the captain's EYES, not just the wire."""

    WAITING = [
        {"id": "m-002", "issue": 200, "title": "Score resets on reload",
         "stage": "plan", "type": "bug",
         "pills": {"cost": {"label": "$1–2", "level": "low"},
                   "reasoning": {"label": "R low", "level": "low"},
                   "implementation": {"label": "I low", "level": "low"}}},
    ]

    def _session(self):
        return {"sessionId": "abc123", "parent": "m-001", "status": "filed",
                "authored": False, "filed": True, "bugCount": 1,
                "filedCount": 1, "unfiled": [], "unfiledCount": 0,
                "children": self.WAITING, "overrides": [],
                "waiting": self.WAITING, "waitingCount": 1}

    def _refused(self, **kw):
        return _console("fixSteerGo", VERIFY, session=self._session(),
                        steer=BAD_STEER, run_error=REFUSAL,
                        repaint=REPAINT_BOARD, **kw)

    def test_a_refused_go_never_claims_the_fixes_were_dispatched(self):
        """Frame by frame across the whole interaction — not the last one."""
        res = self._refused()
        self.assertEqual(res["repaintErrors"], [],
                         "the routine repaint never ran, so this drive proves "
                         "nothing: %r" % res["repaintErrors"])
        liars = [f for f in res["statusTrace"] if _claims_dispatch(f)]
        self.assertEqual(liars, [],
                         "a refused Go told the captain fixes were running: %r"
                         % (res["statusTrace"],))

    def test_a_refused_go_leaves_its_reason_on_screen(self):
        """After everything settles, the reason is STILL readable — naming the
        bug and the words that could not be used."""
        res = self._refused()
        final = res["status"]
        self.assertIn("m-002", final,
                      "the settled screen no longer names the bug: %r" % final)
        self.assertIn(BAD_STEER, final,
                      "the settled screen no longer quotes the steer: %r"
                      % final)
        self.assertNotIn("active mission", final,
                         "the routine repaint erased the verdict: %r"
                         % (res["statusTrace"],))

    def test_a_later_routine_repaint_does_not_erase_the_verdict(self):
        """The SSE tick a second later has no action behind it and must not
        overwrite the last action's verdict either."""
        res = self._refused(repaint_after=True)
        self.assertIn("m-002", res["status"],
                      "a routine repaint erased the verdict: %r"
                      % (res["statusTrace"],))

    def test_a_refused_go_puts_the_review_back_in_front_of_the_captain(self):
        """The captain must not have to KNOW to reopen the console: the review
        comes back, with their own words in the box, beside the reason."""
        res = self._refused()
        self.assertGreaterEqual(
            res["opened"], 2,
            "the refusal left an empty stage — the captain has to know to "
            "reopen the review to learn anything")
        vals = [n["value"] for n in _flatten(res["node"])
                if n["tag"] == "input" and n["value"]]
        self.assertIn(BAD_STEER, vals,
                      "the restored review lost the captain's words: %r" % vals)

    def test_a_non_blocking_verdict_survives_the_repaint_too(self):
        """The OTHER erasure: the Go succeeded, the daemon reported a steer it
        could not apply, and the routine repaint wiped that report too."""
        res = _console("fixSteerGo", VERIFY, session=self._session(),
                       steer="use Opus", repaint=REPAINT_BOARD,
                       run_response={"overrides": [
                           {"id": "m-009", "raw": "use Opus", "error":
                            "no logged bug m-009 is waiting to be fixed on "
                            "this mission — the steer was not applied"}]})
        self.assertIn("not applied", res["status"],
                      "the repaint erased the daemon's own verdict: %r"
                      % (res["statusTrace"],))

    def test_a_clean_dispatch_still_says_so_when_it_is_true(self):
        """And the claim is still made — AFTER the POST resolves."""
        res = _console("fixSteerGo", VERIFY, session=self._session(),
                       steer="use Opus", repaint=REPAINT_BOARD,
                       run_response={"overrides": []})
        self.assertTrue(_claims_dispatch(res["status"]),
                        "a dispatch that really happened went unreported: %r"
                        % (res["statusTrace"],))

    # ── the SAME defect, one control over ────────────────────────────────────
    #
    # `File & Cost` closes the console optimistically too (S162), so a refusal
    # from THAT dispatch also has nowhere to land but the status line — and it
    # was written with the same `setStatus(msg); refresh()` pair. The tester
    # never drove it, which is not a reason to ship a known instance of the bug
    # this session exists to cure.
    FILE_REFUSAL = ("that session was replaced by a newer preview — nothing "
                    "was filed")

    def _previewed(self):
        """A split the daemon is holding, not yet filed: what `File & Cost`
        dispatches from."""
        s = self._session()
        # `waiting` stays: the S163-round-3 shape is a console holding an
        # un-filed report ON a mission that already has bugs waiting, which is
        # the one state where BOTH `File & Cost` and `Go ▸` are live at once —
        # so one fixture can drive either dispatch.
        s.update({"status": "previewed", "authored": True, "filed": False,
                  "bugCount": 1, "filedCount": 0, "steers": [""]})
        return s

    def test_a_refused_filing_leaves_its_reason_on_screen(self):
        res = _console("clickFile", VERIFY, session=self._previewed(),
                       file_error=self.FILE_REFUSAL, repaint=REPAINT_BOARD,
                       repaint_after=True)
        self.assertTrue(res["closed"], "the console closed on dispatch, so the "
                                       "status line is the only surface left")
        self.assertFalse(res["filing"], "the flag must not outlive the refusal")
        self.assertIn("replaced", res["status"],
                      "the routine repaint erased the daemon's reason: %r"
                      % (res["statusTrace"],))

    def test_a_new_action_supersedes_the_last_verdict(self):
        """A verdict is sticky against the REPAINT, never against the captain.

        The moment they dispatch something else the old outcome stops being the
        news — otherwise a refusal from five minutes ago sits over an unrelated
        action, which is the same class of lie in the other direction. Here the
        Go is refused (verdict), then the captain discards the session — a write
        that reports no copy of its own, so nothing but the dispatch itself can
        clear the stale verdict."""
        res = _console("fixSteerGoThenDismiss", VERIFY,
                       session=self._previewed(), steer=BAD_STEER,
                       run_error=REFUSAL, repaint=REPAINT_BOARD,
                       repaint_after=True)
        posts = [f for f in res["fetches"]
                 if f["method"] == "POST" and f["url"].endswith("/log/discard")]
        self.assertTrue(posts, "the drive never dispatched the second action: %r"
                               % [f["url"] for f in res["fetches"]])
        self.assertNotIn("m-002", res["status"],
                         "a stale verdict outlived the action it belonged to: "
                         "%r" % (res["statusTrace"],))
        self.assertIn("active mission", res["status"],
                      "and the board's own line never came back: %r"
                      % (res["statusTrace"],))

    def test_the_routine_repaint_still_reports_the_board_normally(self):
        """The cure must not silence the idle line — with no verdict live, a
        repaint still says what the board holds."""
        res = _console("openFix", VERIFY, session=self._session(),
                       repaint=REPAINT_BOARD, repaint_after=True)
        self.assertIn("2 active missions", res["statusTrace"],
                      "the routine repaint stopped reporting the board: %r"
                      % (res["statusTrace"],))


class ConcurrentGoTest(_LogSessionBase):
    """D2 — the dispatch guard must be ATOMIC, not check-then-act.

    The tester fired five simultaneous POSTs at an undispatched parent with an
    8-second resolve stub and got `200 200 200 200 200` and FIVE resolve-logs
    invocations. Round 3's refusal reads the persisted `log-dispatch.json`,
    which is only written after the spawn, so at true simultaneity every request
    passes the check. At 100 ms stagger it is correct — which is exactly why the
    defect survived a round.
    """

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _go_together(self, n=5):
        """`n` Gos released at the same instant by a barrier. Returns the list
        of (status | error code) in completion order."""
        results = []
        lock = threading.Lock()
        start = threading.Barrier(n)

        def one():
            start.wait()
            try:
                code, _resp = self._post("/api/mission/m-001/log/run",
                                         {"overrides": {}})
            except urllib.error.HTTPError as exc:
                code = exc.code
                exc.read()
            with lock:
                results.append(code)

        threads = [threading.Thread(target=one) for _ in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        return results

    def test_simultaneous_gos_spawn_exactly_one_resolve_logs(self):
        self._file(BUG_A, BUG_B)
        codes = self._go_together(5)
        deadline = time.time() + 5
        argvs = []
        while time.time() < deadline:
            argvs = [ln for ln in self._record("resolve").splitlines()
                     if ln.startswith("ARGV: ")]
            if argvs:
                time.sleep(0.5)      # let any racing sibling record too
                argvs = [ln for ln in self._record("resolve").splitlines()
                         if ln.startswith("ARGV: ")]
                break
            time.sleep(0.05)
        self.assertEqual(argvs, ["ARGV: --parent m-001"],
                         "the race spawned %d resolve-logs drivers over one "
                         "parent" % len(argvs))
        self.assertEqual(sorted(codes), [200, 409, 409, 409, 409],
                         "the losers were not refused honestly: %r" % codes)

    def test_the_refusal_still_says_what_happened(self):
        self._file(BUG_A)
        self._go_together(3)
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {}})
        self.assertEqual(code, 409)
        self.assertIn("already", msg.lower())

    def test_a_lone_go_is_untouched(self):
        """The guard must not cost the ordinary path anything."""
        self._file(BUG_A)
        _s, resp = self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertIsNot(resp.get("ok"), False)
        self.assertTrue(os.path.isfile(os.path.join(
            self.tmp, ".git", "lcars", "missions", "m-001",
            "log-dispatch.json")))


class ReadOnlyDurableFactsTest(_LogSessionBase):
    """D3 — one repo state, one story, whatever board is looking at it.

    The tester ran a `--read-only` daemon beside the read-write one on the SAME
    repo and compared at the same instant: the read-only build emitted no
    `logFiling`/`logDispatch` keys at all, so a dispatched batch read "⚙ FIX 4
    FILED BUGS" (work waiting) while it was already running, and two shortfalls
    vanished entirely.

    S161/S162 built those stamps out of IN-MEMORY sessions, and `actions=None`
    on a view-only build was the right call for in-memory state. Round 3 changed
    the premise: the dispatch and the shortfall are now durable files under
    `.git/lcars/missions/<id>/`, and reading a file needs no write layer. So the
    read-only local board reads them directly (`LogFacts`) — same disk, same
    story, still not a single write.

    The GITHUB adapter is deliberately excluded: it cannot see a local
    `.git/lcars/` at all, and a board that started claiming durable facts it
    has no access to would be round 1's refused-children-reading all over again.
    """

    def setUp(self):
        _LogSessionBase.setUp(self)
        from lcars_serve.local_adapter import LocalAdapter
        from lcars_serve.server import make_server
        from lcars_serve.actions import LogFacts
        # the SECOND daemon: same repo, no write layer — exactly `--read-only`.
        self.ro_adapter = LocalAdapter(self.tmp, read_only=True)
        self.ro = make_server(self.ro_adapter, host="127.0.0.1", port=0,
                              poll_interval=0.05, actions=None,
                              log_facts=LogFacts(self.tmp))
        self.ro_port = self.ro.server_address[1]
        self.ro_thread = threading.Thread(target=self.ro.serve_forever,
                                          daemon=True)
        self.ro_thread.start()

    def tearDown(self):
        self.ro.shutdown()
        self.ro.server_close()
        _LogSessionBase.tearDown(self)

    def _ro_get(self, path, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.ro_port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _card(self, board, mid="m-001"):
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    def _both(self, mid="m-001"):
        _s, rw = self._get("/api/board")
        _s, ro = self._ro_get("/api/board")
        return self._card(rw, mid), self._card(ro, mid)

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def test_a_dispatched_batch_reads_as_dispatched_on_both_boards(self):
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        rw, ro = self._both()
        self.assertEqual(rw["logDispatch"]["status"], "dispatched")
        self.assertEqual(ro.get("logDispatch", {}).get("status"), "dispatched",
                         "the view-only board still offers a review of work "
                         "that is already running")

    def test_a_shortfall_reads_as_a_shortfall_on_both_boards(self):
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        rw, ro = self._both()
        self.assertEqual(rw["logFiling"]["status"], "partial")
        self.assertEqual(ro.get("logFiling", {}).get("status"), "partial",
                         "the view-only board hid a bug that never filed")
        self.assertEqual(ro["logFiling"]["bugCount"], 2)
        self.assertEqual(ro["logFiling"]["filedCount"], 1)
        self.assertEqual(ro["logFiling"]["waitingCount"],
                         rw["logFiling"]["waitingCount"])
        self.assertTrue(ro["logFiling"].get("error"),
                        "the shortfall arrived without its reason")

    def test_a_failed_batch_reads_as_failed_on_both_boards(self):
        self._refuse("")          # refuse every bug
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        rw, ro = self._both()
        self.assertEqual(rw["logFiling"]["status"], "failed")
        self.assertEqual(ro.get("logFiling", {}).get("status"), "failed")
        self.assertEqual(ro["logFiling"]["filedCount"], 0)

    def test_the_detail_mirrors_the_card_on_the_read_only_board(self):
        self._file(BUG_A)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        _s, detail = self._ro_get("/api/mission/m-001")
        self.assertEqual(detail["logDispatch"]["status"], "dispatched")

    def test_the_read_only_session_route_reports_the_durable_shortfall(self):
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        _s, sess = self._ro_get("/api/mission/m-001/log/session")
        self.assertEqual(sess["status"], "partial")
        self.assertEqual(sess["bugCount"], 2)
        self.assertIn("Leaderboard", sess["unfiled"][0]["prd"])

    def test_a_repo_with_no_log_activity_is_byte_identical_on_both(self):
        """The additive invariant, on the board that just grew the keys.

        Compared card-shape to card-shape rather than blob to blob: the adapter
        stamps a live `ageSeconds` on every card, so two boards built a
        millisecond apart differ for a reason that has nothing to do with this
        round. What must be identical is the SET OF KEYS."""
        _s, ro = self._ro_get("/api/board")
        plain = self.ro_adapter.board()
        for c in self._cards(ro):
            self.assertNotIn("logDispatch", c)
            self.assertNotIn("logFiling", c)
        self.assertEqual(
            sorted(sorted(c.keys()) for c in self._cards(ro)),
            sorted(sorted(c.keys()) for c in self._cards(plain)),
            "the view-only board grew a key on a repo with no log activity")

    def test_every_write_is_still_refused(self):
        self._file(BUG_A)
        for path, body in (("/api/mission/m-001/log", {"text": "x"}),
                           ("/api/mission/m-001/log/file", {"sessionId": "x"}),
                           ("/api/mission/m-001/log/run", {"overrides": {}})):
            url = "http://127.0.0.1:%d%s" % (self.ro_port, path)
            req = urllib.request.Request(
                url, data=json.dumps(body).encode("utf-8"), method="POST",
                headers={"Content-Type": "application/json"})
            try:
                urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as exc:
                self.assertEqual(exc.code, 403, path)
                exc.read()
            else:
                self.fail("%s was not refused on a read-only board" % path)

    def test_the_github_adapter_claims_nothing(self):
        """A board that cannot see `.git/lcars/` must not start speaking for
        it. `LogFacts` is wired only for the LOCAL adapter."""
        from lcars_serve.__main__ import build_log_facts
        self.assertIsNone(build_log_facts("github", self.tmp))
        self.assertIsNotNone(build_log_facts("local", self.tmp))


class InterruptedFilingTest(_LogSessionBase):
    """D4 — a filing that died mid-flight must not re-read as a settled batch.

    The tester filed a 2-bug report, `kill -9`'d the daemon 8 s in (status
    `filing`, 0 filed) and restarted. `/log/session` 404'd and the card rendered
    a settled `⚙ FIX 1 FILED BUG` over a 2-bug report — no band, no note — for
    the ~35 s it took the ORPHANED `log.sh` to land the second bug. Pressing Go
    in that window would have dispatched the batch with the second bug's cost
    review never shown, which is the one thing this session exists to prevent.

    The cure is round 3's own lever, one step earlier: the durable record is
    written when the filing STARTS, not only when it settles, and it carries the
    ids that already existed so a restarted daemon can measure what landed
    afterwards instead of inferring completeness from whatever is on disk.
    """

    def tearDown(self):
        """Leave no sleeping stub behind.

        These drives deliberately run `log.sh` SLOWLY (the per-bug stagger that
        makes a half-filed batch observable), and a `kill -9`'d daemon by
        definition does not reap the filing it started — that is the situation
        under test. The stubs are detached bash, so without this they go on
        sleeping into whatever runs next. Measured: the extra process churn made
        an unrelated launch-lifecycle test start failing in the FULL suite while
        passing on its own. Clear the flag, then reap.
        """
        self._unpause()
        try:
            subprocess.run(["pkill", "-9", "-f", self.scripts["log"]],
                           capture_output=True)
        except OSError:
            pass
        _LogSessionBase.tearDown(self)

    def _restarted(self):
        from lcars_serve.actions import Actions
        return Actions(repo_root=self.tmp, scripts=self.scripts,
                       worker_bin=self.worker_bin)

    def _record_path(self):
        return os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                            "log-shortfall.json")

    def _record(self):
        with open(self._record_path()) as fh:
            return json.load(fh)

    def _card(self, actions, mid="m-001"):
        board = actions.log_overlay(self.adapter.board())
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    def test_a_filing_records_that_it_started_before_it_starts(self):
        self._pause(2)
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        rec = self._record()
        self.assertEqual(rec["status"], "filing")
        self.assertEqual(rec["bugCount"], 2)
        self.assertEqual(len(rec["unfiled"]), 2,
                         "the in-flight record does not hold the batch")
        self.assertIn("before", rec,
                      "the record cannot tell later what it started from")
        self._unpause()
        self._await_status("/api/mission/m-001/log/session", "filed", 30)

    def test_a_restart_mid_filing_does_not_read_as_a_settled_batch(self):
        """The defect, end to end. One bug has landed, one has not, and the
        daemon that was filing them is gone."""
        self._pause(3)
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        deadline = time.time() + 10
        while time.time() < deadline and len(self._on_disk()) < 1:
            time.sleep(0.05)
        self.assertEqual(len(self._on_disk()), 1,
                         "the fixture never reached the half-filed state")
        stamp = self._card(self._restarted()).get("logFiling")
        self.assertIsNotNone(
            stamp, "a restarted daemon reports a clean 1-bug batch over a "
                   "2-bug report — the second bug's review is skippable")
        self.assertEqual(stamp["bugCount"], 2)
        self.assertEqual(stamp["filedCount"], 1)
        self.assertNotEqual(stamp["status"], "filed")
        self.assertTrue(stamp.get("error"))
        self._unpause()

    def test_the_restarted_daemon_reconciles_when_the_orphan_lands(self):
        """...and it does not get STUCK saying so. The orphaned log.sh really
        does land the second bug seconds later; the next board build measures
        that (the same before/after delta the filing itself uses) and the
        shortfall clears, so a retry can never duplicate a bug that arrived."""
        self._pause(2)
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        deadline = time.time() + 10
        while time.time() < deadline and len(self._on_disk()) < 1:
            time.sleep(0.05)
        restarted = self._restarted()
        self.assertEqual(self._card(restarted)["logFiling"]["filedCount"], 1)
        deadline = time.time() + 20
        while time.time() < deadline and len(self._on_disk()) < 2:
            time.sleep(0.1)
        self.assertEqual(len(self._on_disk()), 2)
        self.assertIsNone(self._card(restarted).get("logFiling"),
                          "the batch completed but the card still claims a "
                          "shortfall — a retry here would duplicate a bug")
        self.assertFalse(os.path.isfile(self._record_path()))
        self._unpause()

    def test_a_settled_filing_leaves_no_in_flight_claim(self):
        """The ordinary path is unchanged: a clean batch clears the record it
        wrote on the way in."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertFalse(os.path.isfile(self._record_path()))

    def test_a_repo_that_never_filed_is_byte_identical(self):
        board = self.adapter.board()
        snapshot = copy.deepcopy(board)
        self.assertEqual(self._restarted().log_overlay(board), snapshot)


# ════════════════════════════════════════════════════════════════════════════
# S163 fix round 6 — the four the sixth captain-stand-in tester returned.
#
# D1  a CLEARED steer was silently restored by the refusal repaint, and the next
#     Go re-sent it. Two consequences, and the second is the worse one: between
#     the two Gos the panel showed a steer the last Go had not sent, and a
#     captain could not return a bug to "no steer" at all while any other bug
#     was refused.
# D2  a refusal verdict never expired. Sticky against the routine repaint is
#     right (round 5); sticky over the captain's NEXT ACTION — including an
#     action on a different mission — is the same lie inverted.
# D3  logging a new bug on an already-dispatched parent disarmed the
#     double-dispatch guard: the panel re-listed the two bugs already being
#     driven, the Go returned 200, and a SECOND `resolve-logs --parent` was
#     spawned over the same children and the same parent branch.
# D4  for the two modal-CLOSING verdict paths the message landed in `.dim`
#     (#50688a on #030608 — 3.6:1, below AA at 12px), with no state class at
#     all. The round claimed "prominent copy measurably reaches the screen".
# ════════════════════════════════════════════════════════════════════════════
class ClearedSteerTest(_LogSessionBase):
    """D1, the daemon half — clearing a steer must mean clearing it.

    The tester's sequence, exactly: two waiting bugs, an unusable steer typed
    into each, a Go that is refused naming both, then 013's box EMPTIED and Go
    pressed again. The second Go's refusal correctly named only 014 — the clear
    reached the daemon — and then the panel put 013's deleted words straight
    back, because `/log/session` still carried the round-1 verdict for that bug
    and the box is re-seeded from it. The third Go re-sent a steer the captain
    had deleted two clicks earlier.

    So an empty steer is an INSTRUCTION here, not an absence: for a bug the
    panel is showing, it retracts whatever was recorded about that bug — the
    verdict the console echoes AND the `modelOverride` on disk. Only for the
    KEYED shapes, which is what a panel can send; a blank in the LEGACY
    positional list still means "untouched" (that list is what `log.sh` is
    handed at file time, where a blank has never meant anything else).
    """

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _session(self):
        _s, sess = self._get("/api/mission/m-001/log/session")
        return sess

    def _state_path(self, mid):
        return os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                            "state.json")

    def _override(self, mid):
        with open(self._state_path(mid)) as fh:
            return json.load(fh).get("modelOverride")

    def _plant_override(self, mid, scope="all", tier="opus"):
        """A steer already persisted on a child — what a FILE-time steer leaves
        behind, and what pre-fills the box the captain then clears."""
        with open(self._state_path(mid)) as fh:
            state = json.load(fh)
        state["modelOverride"] = {"scope": scope, "tier": tier}
        with open(self._state_path(mid), "w") as fh:
            json.dump(state, fh, indent=2)

    def test_an_emptied_box_stops_being_sent_back_by_the_panel(self):
        """The measured defect. Refuse a Go naming both bugs, clear one, refuse
        again — and the panel must not hand the cleared words back."""
        self._file(BUG_A, BUG_B)
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "badsteer1",
                                      "m-bug2": "alsobad2"}})
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "", "m-bug2": "alsobad2"}})
        rows = self._session().get("overrides") or []
        raws = [r.get("raw") for r in rows if r.get("id") == "m-bug1"]
        self.assertEqual(raws, [],
                         "the panel still carries the cleared steer: %r" % rows)
        self.assertTrue([r for r in rows if r.get("id") == "m-bug2"],
                        "clearing one bug erased the verdict for the other")

    def test_the_refusal_stops_naming_the_bug_that_was_cleared(self):
        """...and the refusal must stop accusing it, or the captain is told to
        fix a steer that no longer exists."""
        self._file(BUG_A, BUG_B)
        self._post_err("/api/mission/m-001/log/run",
                       {"overrides": {"m-bug1": "badsteer1",
                                      "m-bug2": "alsobad2"}})
        _code, msg = self._post_err(
            "/api/mission/m-001/log/run",
            {"overrides": {"m-bug1": "", "m-bug2": "alsobad2"}})
        self.assertIn("m-bug2", msg)
        self.assertNotIn("m-bug1", msg)

    def test_a_cleared_steer_is_removed_from_disk_too(self):
        """"Clearing a steer must mean clearing it" reaches the lever that
        actually decides the model — `state.json.modelOverride`, which run.sh's
        `active_model_override` reads. A verdict dropped from the console while
        the override stayed on disk would put the box back on the next repaint
        from `c.override` and run the bug on a model the captain retracted."""
        self._file(BUG_A, BUG_B)
        self._plant_override("m-bug1")
        self.assertIsNotNone(self._override("m-bug1"))
        self._post("/api/mission/m-001/log/run",
                   {"overrides": {"m-bug1": "", "m-bug2": "all:opus"}})
        self.assertIsNone(self._override("m-bug1"),
                          "the cleared steer is still steering the bug")
        self.assertEqual(self._override("m-bug2"),
                         {"scope": "all", "tier": "opus"})

    def test_a_bug_the_payload_never_mentions_is_left_alone(self):
        """The clear is an EMPTY VALUE, never an absence. A keyed payload that
        simply does not mention a bug says nothing about it — otherwise every
        `{"overrides": {}}` Go would silently strip every file-time steer on the
        mission."""
        self._file(BUG_A, BUG_B)
        self._plant_override("m-bug1")
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(self._override("m-bug1"),
                         {"scope": "all", "tier": "opus"})

    def test_a_blank_in_the_legacy_positional_list_still_means_untouched(self):
        """The list shape is what `log.sh` is handed at FILE time, where the
        bugs have no ids and a blank has only ever meant "no steer for this
        slot". Redefining it here would reach back into a path this fix is not
        about."""
        self._file(BUG_A, BUG_B)
        self._plant_override("m-bug1")
        self._post("/api/mission/m-001/log/run", {"overrides": ["", ""]})
        self.assertEqual(self._override("m-bug1"),
                         {"scope": "all", "tier": "opus"})

    def test_a_clear_alone_never_blocks_the_go(self):
        """An empty box is not an unresolvable steer. The round-4 refusal must
        not fire on the very edit that clears the thing it refused."""
        self._file(BUG_A, BUG_B)
        status, _resp = self._post("/api/mission/m-001/log/run",
                                   {"overrides": {"m-bug1": "", "m-bug2": ""}})
        self.assertEqual(status, 200)


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class ClearedSteerConsoleTest(unittest.TestCase):
    """D1, the client half — an emptied box must REACH the daemon as a clear.

    `setSteer` deleted a blank from the keyed map, so an emptied box was
    indistinguishable on the wire from a bug the captain never touched. The
    panel is the promise that what you see is what Go runs, so every box it
    renders now rides the dispatch — including the empty ones.
    """

    SESSION = dict(FixFiledConsoleTest.FILED_SESSION)

    def _run_bodies(self, res):
        return [f["body"] for f in res["fetches"]
                if f["url"].endswith("/log/run")]

    def _steer_values(self, res):
        """EVERY per-bug steer box's value, empties included. Filtering the
        blanks out would pass on a console that rendered no boxes at all, which
        is the one way this assertion could flatter itself."""
        return [n["value"] for n in _flatten(res["node"])
                if n["tag"] == "input"]

    def test_an_emptied_box_rides_the_dispatch_as_a_clear(self):
        res = _console("fixSteerGoClearGo", VERIFY, session=self.SESSION,
                       steer="badsteer1", run_error="no model tier in that")
        bodies = self._run_bodies(res)
        self.assertEqual(len(bodies), 2, "expected two Gos: %r" % bodies)
        self.assertEqual(bodies[0].get("overrides", {}).get("m-002"),
                         "badsteer1")
        self.assertEqual(bodies[1].get("overrides", {}).get("m-002"), "",
                         "the cleared box was not sent as a clear: %r"
                         % bodies[1])

    def test_the_second_go_never_re_sends_the_deleted_steer(self):
        """The tester's Go#3, one step earlier: the deleted words must not come
        back on the wire at all."""
        res = _console("fixSteerGoClearGo", VERIFY, session=self.SESSION,
                       steer="badsteer1", run_error="no model tier in that")
        second = self._run_bodies(res)[1]
        self.assertNotIn("badsteer1", json.dumps(second),
                         "the deleted steer was re-sent: %r" % second)

    def test_the_panel_shows_no_steer_the_last_go_did_not_send(self):
        """...and the box the captain emptied stays empty through the repaint
        the refusal fires."""
        res = _console("fixSteerGoClearGo", VERIFY, session=self.SESSION,
                       steer="badsteer1", run_error="no model tier in that")
        self.assertEqual(self._steer_values(res), ["", ""],
                         "a cleared box was re-seeded: %r"
                         % self._steer_values(res))

    def test_a_daemon_verdict_cannot_out_rank_an_explicit_clear(self):
        """Belt and braces for the same rule, from the other side: a session
        that still carries an error verdict for a bug the client has explicitly
        cleared must not re-seed the box from it."""
        sess = dict(self.SESSION,
                    overrides=[{"id": "m-002", "raw": "badsteer1",
                                "resolved": None, "label": None,
                                "error": "no model tier in that"}])
        res = _console("fixSteerGoClearGo", VERIFY, session=sess,
                       steer="badsteer1", run_error="no model tier in that")
        self.assertEqual(self._steer_values(res), ["", ""])


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class VerdictRetirementTest(unittest.TestCase):
    """D2 — a verdict is sticky against the REPAINT, never against the captain.

    Round 5 made an action's outcome survive `postWrite → refresh → render`, and
    the tester could not break that: 100 s, 29 of the product's own repaints, no
    erasure. The cost was the other direction. `clearVerdict()` lives in
    `postWrite`, so only a WRITE could retire a verdict — and the captain's next
    move is very often not a write. Opening another mission's Mission Log,
    reading a different card, walking into any console at all left a refusal
    about a mission they had moved on from sitting over the top.

    The rule this pins: **starting something else retires the last outcome.**
    Two doors count as starting something — a write (`postWrite`, unchanged) and
    OPENING A CONSOLE, which is how a captain begins nearly everything that is
    not a write.

    What is deliberately NOT here is an age-out. A timer would decide that a
    verdict has been read because seconds passed, and this is a walk-away
    feature: the captain who most needs the line is the one who was not at the
    desk. Presence is not evidence, and an action is.
    """

    SESSION = dict(FixFiledConsoleTest.FILED_SESSION)
    BOARD = {"columns": {"verify": [dict(VERIFY)]},
             "missions": [dict(VERIFY)], "meta": {}}

    def test_opening_a_console_retires_the_last_verdict(self):
        res = _console("fixSteerGoThenOpenPlain", VERIFY, session=self.SESSION,
                       steer="use haiku", run_error="haiku is not a model tier",
                       repaint=self.BOARD)
        self.assertNotIn("haiku is not a model tier", res["status"],
                         "a refusal outlived the captain's next action: %r"
                         % res["status"])
        self.assertIn("active mission", res["status"],
                      "the routine line never came back: %r" % res["status"])

    def test_the_refusals_own_reopen_still_carries_it(self):
        """The console a REFUSAL opens is that action's own continuation, not
        the captain starting something else — the verdict must survive it, or
        the cure for D2 deletes the cure for round 5's D1."""
        res = _console("fixSteerGo", VERIFY, session=self.SESSION,
                       steer="use haiku", run_error="haiku is not a model tier",
                       repaint=self.BOARD, repaint_after=True)
        self.assertIn("haiku is not a model tier", res["status"],
                      "the reopened review erased its own reason: %r"
                      % res["status"])

    def test_the_routine_repaint_still_does_not_erase_it(self):
        """Round 5's guarantee, re-measured against the same drive."""
        res = _console("fixSteerGo", VERIFY, session=self.SESSION,
                       steer="use haiku", run_error="haiku is not a model tier",
                       repaint=self.BOARD, repaint_after=True)
        self.assertEqual(res["repaintErrors"], [])
        self.assertIn("NOT", res["status"].upper())


class DoubleDispatchTest(_LogSessionBase):
    """D3 — a bug already being driven is never dispatched a second time.

    The tester's measurement, and it is the severest thing in this round: a
    parent with two dispatched bugs got ONE more bug logged against it, and the
    fresh preview spent the dispatch mark. The panel then re-listed all three,
    `/log/run` answered 200 — "Fixes dispatched" — and a second
    `resolve-logs --parent` was spawned over the same children and the same
    parent branch, minutes after the first.

    Round 3 ledgered this as a bound ("a fresh preview still spends the dispatch
    mark"); the consequence turned out to be worse than the bound implied,
    because `resolve-logs --parent` drives every non-done, non-verify child of
    the parent it is handed — so the second driver re-drives the first driver's
    bugs by construction.

    Two facts replace the spendable mark:

      * the dispatch record now names the CHILDREN its Go covered, cumulatively,
        and `_waiting_children` excludes them. A bug a Go has taken is not
        waiting for another one.
      * "is a drive live?" is a MEASUREMENT — any dispatched child not yet at
        its `verify`/`done` gate — not a mark a later preview can clear. So the
        Go re-arms when the batch reaches the consolidated gate, which is the
        moment it is genuinely safe, rather than when a new report happens to
        arrive.

    A legitimately new bug is still reachable: it is filed exactly as before (no
    refusal there), it appears as its own card, and the Go covers it as soon as
    the live drive settles.
    """

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _session(self):
        _s, sess = self._get("/api/mission/m-001/log/session")
        return sess

    def _dispatch_record(self):
        with open(os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                               "log-dispatch.json")) as fh:
            return json.load(fh)

    def _resolve_argvs(self, want=1, timeout=10):
        deadline = time.time() + timeout
        argvs = []
        while time.time() < deadline:
            argvs = [ln for ln in self._record("resolve").splitlines()
                     if ln.startswith("ARGV: ")]
            if len(argvs) >= want:
                break
            time.sleep(0.05)
        return argvs

    def _set_stage(self, mid, stage):
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                          "state.json")
        with open(sp) as fh:
            state = json.load(fh)
        state["stage"] = stage
        with open(sp, "w") as fh:
            json.dump(state, fh, indent=2)

    def _card(self, mid="m-001"):
        _s, board = self._get("/api/board")
        for c in self._cards(board):
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    # -- the defect ----------------------------------------------------------
    def test_a_new_report_does_not_re_arm_the_go_over_a_live_drive(self):
        self._file(BUG_A, BUG_B)
        status, _r = self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(status, 200)
        self._file(BUG_C)                     # the new bug, mid-drive
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {}})
        self.assertEqual(code, 409)
        self.assertIn("driv", msg.lower(),
                      "the refusal never says a drive is in flight: %r" % msg)

    def test_only_one_resolve_logs_driver_over_the_parent(self):
        """The measurement that matters — two drivers over one parent branch is
        what the 409 exists to prevent."""
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(self._resolve_argvs(), ["ARGV: --parent m-001"])
        self._file(BUG_C)
        self._post_err("/api/mission/m-001/log/run", {"overrides": {}})
        time.sleep(0.4)
        self.assertEqual(self._resolve_argvs(),
                         ["ARGV: --parent m-001"],
                         "a second resolve-logs was spawned over the parent")

    def test_the_panel_never_re_offers_a_bug_already_being_driven(self):
        """The tester saw all three bugs listed, including the two already
        being driven — "what you see is exactly what Go runs" pointing at a
        double dispatch."""
        _pin_live_resolver(self)          # round 7: a drive that really is on
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._file(BUG_C)
        sess = self._session()
        self.assertEqual(sorted(c["id"] for c in sess["waiting"]), ["m-bug3"])
        self.assertEqual(sess["waitingCount"], 1)

    def test_the_record_names_the_children_its_go_covered(self):
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(sorted(self._dispatch_record()["dispatched"]),
                         ["m-bug1", "m-bug2"])

    def test_the_card_says_the_parent_is_being_driven_not_fixable(self):
        """A live session used to out-rank the dispatch record outright, which
        is how the card re-offered the review. It may only out-rank a SETTLED
        one."""
        _pin_live_resolver(self)          # round 7: a drive that really is on
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._preview(BUG_C)
        self.assertIsNotNone(self._card().get("logDispatch"),
                             "a fresh preview hid a live drive from the card")

    # -- ...and the road is not closed ---------------------------------------
    def test_a_new_bug_is_reachable_once_the_drive_settles(self):
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._file(BUG_C)
        self._post_err("/api/mission/m-001/log/run", {"overrides": {}})
        # the batch reaches its consolidated re-verify gate.
        self._set_stage("m-bug1", "verify")
        self._set_stage("m-bug2", "verify")
        status, _r = self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self.assertEqual(status, 200, "the new bug was never reachable")
        self.assertEqual(sorted(self._dispatch_record()["dispatched"]),
                         ["m-bug1", "m-bug2", "m-bug3"],
                         "the second Go forgot what the first one took")

    def test_the_settled_drive_lets_the_panel_offer_the_new_bug(self):
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._set_stage("m-bug1", "verify")
        self._set_stage("m-bug2", "verify")
        self._file(BUG_C)
        sess = self._session()
        self.assertEqual(sorted(c["id"] for c in sess["waiting"]), ["m-bug3"])
        self.assertIsNone(self._card().get("logDispatch"),
                          "a settled drive still hides the new bug's review")

    def test_filing_a_new_bug_mid_drive_is_never_refused(self):
        """The cure must not be "refuse to log bugs against a busy parent"."""
        self._file(BUG_A, BUG_B)
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        self._file(BUG_C)
        self.assertIn("m-bug3", self._on_disk())


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class StatusLegibilityTest(unittest.TestCase):
    """D4 — a verdict must be LEGIBLE where it lands.

    On the two modal-closing paths (the File & Cost refusal, and the Go's
    non-blocking "…but N steers were not applied") the console is gone by the
    time the daemon answers, so `#status` is the only carrier. The tester
    measured what reached the screen there: `<span class="dim" id="status">`
    inside `.legend` — `#50688a` on `#030608`, 3.6:1 at 12px, no error colour,
    and `board.js` setting no class at all.

    Every assertion below is a MEASUREMENT of the shipping pair — the class list
    the real `setVerdict` writes, cascaded against the real `docs/lcars.css` +
    `web/static/board.css`. This round has already shipped one amber rule that
    tested green while rendering in muted grey (`.card .no` beat it on source
    order), so a rule EXISTING in a stylesheet is not evidence.

    The resolver is the one `test_log_filing_band` built for exactly that
    lesson, reused rather than re-written — and `test_the_resolver_can_return_a
    _loss` is its calibration: the SAME code, over the class list this line used
    to carry, must come back with the muted grey. A resolver that returned the
    hoped-for colour would fail that half.
    """

    SESSION = dict(FixFiledConsoleTest.FILED_SESSION)
    BOARD = {"columns": {"verify": [dict(VERIFY)]},
             "missions": [dict(VERIFY)], "meta": {}}
    LEGEND = [("html", frozenset()), ("body", frozenset(["lcars-serve"])),
              ("div", frozenset(["legend"]))]

    @classmethod
    def setUpClass(cls):
        from tests.test_log_filing_band import load_stylesheets, CSS_SHEETS
        cls.rules, cls.vars = load_stylesheets(CSS_SHEETS)

    def _colour(self, cls):
        from tests.test_log_filing_band import computed, rgb
        chain = self.LEGEND + [("span", frozenset((cls or "").split()))]
        return rgb(computed("color", chain, self.rules, self.vars))

    @staticmethod
    def _contrast(fg, bg):
        def lum(c):
            out = []
            for v in c:
                s = v / 255.0
                out.append(s / 12.92 if s <= 0.04045
                           else ((s + 0.055) / 1.055) ** 2.4)
            return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
        a, b = lum(fg), lum(bg)
        hi, lo = max(a, b), min(a, b)
        return (hi + 0.05) / (lo + 0.05)

    BG = (3, 6, 8)              # --lcars-black, body.lcars-serve's background
    DIM = (80, 104, 138)        # --lcars-text-dim — where the verdict landed

    # -- calibration: the resolver can say NO ---------------------------------
    def test_the_resolver_can_return_a_loss(self):
        """The KNOWN LOSS. `class="dim"` is what this line carried when the
        tester measured 3.6:1, and the resolver must reproduce exactly that —
        otherwise the win below proves nothing about the cascade."""
        self.assertEqual(self._colour("dim"), self.DIM)
        self.assertLess(self._contrast(self.DIM, self.BG), 4.5)

    def test_the_resolver_can_return_a_win(self):
        """The KNOWN WIN, on the same chain and the same sheets."""
        colour = self._colour("status-verdict")
        self.assertNotEqual(colour, self.DIM,
                            "the verdict class resolves to the dim grey")
        self.assertGreaterEqual(self._contrast(colour, self.BG), 4.5)

    def test_a_losing_rule_is_detected_as_losing(self):
        """...and the resolver is not simply answering "whatever was asked
        for": a rule that ties on specificity and sits EARLIER in the sheet must
        come back beaten by `.dim`, which is precisely the shape of the bug this
        round already shipped once."""
        from tests.test_log_filing_band import (_walk_css, computed, rgb)
        rules = []
        _walk_css(".hopeful{color:#ffaa00}.dim{color:#50688a}", "synthetic",
                  rules)
        chain = [("span", frozenset(["hopeful", "dim"]))]
        self.assertEqual(rgb(computed("color", chain, rules, {})), self.DIM)

    # -- the shipping pair ----------------------------------------------------
    def test_a_refused_filing_reaches_the_screen_legibly(self):
        """The File & Cost refusal — the console has already closed."""
        res = _console("clickFile", VERIFY, session=self.SESSION,
                       file_error="that session was superseded",
                       repaint=self.BOARD, repaint_after=True)
        self.assertIn("superseded", res["status"])
        colour = self._colour(res["statusCls"])
        self.assertNotEqual(colour, self.DIM,
                            "the refusal landed in the dim grey (cls=%r)"
                            % res["statusCls"])
        self.assertGreaterEqual(self._contrast(colour, self.BG), 4.5)

    def test_a_non_blocking_complaint_reaches_the_screen_legibly(self):
        """The Go's "…but N model steers were not applied" — the dispatch
        really happened, so nothing else on the board will ever mention it."""
        res = _console(
            "fixSteerGo", VERIFY, session=self.SESSION, steer="use Opus",
            run_response={"overrides": [{"id": "m-404", "raw": "use Opus",
                                         "error": "no logged bug m-404 is "
                                                  "waiting to be fixed"}]},
            repaint=self.BOARD, repaint_after=True)
        self.assertIn("not applied", res["status"])
        colour = self._colour(res["statusCls"])
        self.assertNotEqual(colour, self.DIM,
                            "a dropped steer was reported in the dim grey "
                            "(cls=%r)" % res["statusCls"])
        self.assertGreaterEqual(self._contrast(colour, self.BG), 4.5)

    def test_an_empty_review_offers_no_go(self):
        """A ledger item from the same round, cured here because it is one line
        and the same promise: the panel IS what Go runs, so a panel with nothing
        in it must not carry a Go. The tester reached "Review — 0 bug missions
        waiting to be fixed" with `Go ▸` live above it, whose only possible
        outcome was a refusal."""
        empty = {"parent": "m-001", "authored": False, "count": 0,
                 "children": [], "waiting": [], "waitingCount": 0}
        res = _console("clickPreview", VERIFY, session=None, preview=empty,
                       children=[])
        gos = [n for n in _flatten(res["node"])
               if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(gos, "the Go control vanished entirely")
        self.assertTrue(gos[0]["hidden"],
                        "an empty review still offers a Go that can only refuse")

    def test_a_review_with_bugs_still_offers_it(self):
        """...and the control is not simply gone. The same drive with one
        waiting bug must still arm it, or the ledger fix has eaten S163's whole
        way forward."""
        one = {"parent": "m-001", "authored": False, "count": 1,
               "children": [dict(FixFiledConsoleTest.FILED_SESSION["children"][0])],
               "waitingCount": 1}
        res = _console("clickPreview", VERIFY, session=None, preview=one,
                       children=[])
        gos = [n for n in _flatten(res["node"])
               if n["tag"] == "button" and n["text"] == "Go ▸"]
        self.assertTrue(gos and not gos[0]["hidden"],
                        "the review of a real waiting bug lost its Go")

    def test_the_routine_line_is_still_the_quiet_one(self):
        """The prominence must be the VERDICT's, not the status line's. A board
        that describes itself in the same colour as a refusal has only moved the
        problem."""
        res = _console("open", VERIFY, session=self.SESSION,
                       repaint=self.BOARD, repaint_after=True)
        self.assertIn("active mission", res["status"])
        self.assertEqual(self._colour(res["statusCls"]), self.DIM)


# ══════════════════════════════════════════════════════════════════════════════
# S163 fix round 7 (D2) — ONE READING behind the card, the panel and the Go
# ══════════════════════════════════════════════════════════════════════════════
"""The round-7 tester read three different numbers off one repo, at one instant:

    card button          : ⚙ FIX 2 FILED BUGS
    panel it opens       : REVIEW — 1 BUG MISSION WAITING TO BE FIXED
    Go → log-dispatch.json: dispatched ['…-107']              (one spawn)

The setup was the recovery round 6's own bound TELLS a captain to perform: two
filed, never-dispatched bug children, one of them driven to `verify` by hand.
`_waiting_children` excludes `verify` (the consolidated re-verify gate — work
already done), so the daemon's `waitingCount` was 1 and the Go ran 1. The CARD
was counting for itself, with a different rule.

Two client-side counters were doing it, and both are the S161-D2 mistake again —
a number that means one thing on the server and another on the client:

  * `resolvingChildren()` excludes only `done`, so a child at `verify` is in it;
  * `filedCount` is THIS BATCH's landing count, which does not shrink when a
    child later reaches its gate.

The cure is to stop counting on the client at all. `waitingCount` is now
published on every parent card that has waiting bugs — not only when a live
session stamp happens to exist — and `logFixState` reads it and nothing else.
"""


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class OneReadingCardTest(unittest.TestCase):
    """The CLIENT half: the card must never count for itself."""

    def test_the_card_does_not_count_a_child_that_reached_its_gate(self):
        """D2, exactly as measured. Two filed bugs, one driven to `verify` by
        hand; the daemon says 1 is waiting and the Go will run 1."""
        m = dict(VERIFY, logFiling=dict(_stamp("filed", 2, 2), waitingCount=1))
        res = _drive(m, children=[_kid(0), _kid(1, stage="verify")])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no Fix Filed Bugs control: %s" % _texts(res))
        self.assertEqual(
            ctl["text"], "⚙ FIX 1 FILED BUG",
            "the card promises more bugs than the panel shows or the Go runs")

    def test_the_daemons_waiting_count_outranks_the_batch_count(self):
        """Even with no child at a gate: whatever the batch numbers say, the
        daemon's waiting measurement is the one the panel and the Go use."""
        m = dict(VERIFY, logFiling=dict(_stamp("filed", 4, 4), waitingCount=2))
        res = _drive(m, children=[_kid(i) for i in range(4)])
        self.assertEqual(_fix_control(res)["text"], "⚙ FIX 2 FILED BUGS")

    def test_the_restart_fallback_counts_the_same_bugs_the_daemon_would(self):
        """No stamp at all — the daemon restarted. The client's own fallback
        must apply the SAME exclusions `_waiting_children` does, or the two
        boards disagree about one repo again (the round-2 lesson)."""
        res = _drive(dict(VERIFY),
                     children=[_kid(0), _kid(1, stage="verify")])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no Fix Filed Bugs control: %s" % _texts(res))
        self.assertEqual(ctl["text"], "⚙ FIX 1 FILED BUG")

    def test_a_card_whose_only_bug_reached_its_gate_offers_no_fix(self):
        """...and the exclusion is not cosmetic. With nothing waiting there is
        nothing to fix, and a control that can only refuse must not appear."""
        res = _drive(dict(VERIFY), children=[_kid(0, stage="verify")])
        self.assertIsNone(_fix_control(res),
                          "the card offers to fix a bug already at its gate")


class OneReadingDaemonTest(_LogSessionBase):
    """The DAEMON half, end to end on a real repo: card stamp, review panel and
    dispatch record must be one list at one instant."""

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _drive_to_verify(self, mid):
        """What round 6's bound tells the captain to do by hand."""
        sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                          "state.json")
        with open(sp) as fh:
            st = json.load(fh)
        st["stage"] = "verify"
        with open(sp, "w") as fh:
            json.dump(st, fh, indent=2)

    def _card(self, mid="m-001"):
        board = self.actions.log_overlay(self.adapter.board())
        for col in (board.get("columns") or {}).values():
            for c in col:
                if c.get("id") == mid:
                    return c
        self.fail("no card for %s" % mid)

    def _dispatch_record(self):
        with open(os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                               "log-dispatch.json")) as fh:
            return json.load(fh)

    def test_card_panel_and_go_are_one_reading_after_a_hand_driven_child(self):
        self._file(BUG_A, BUG_B)
        self._drive_to_verify("m-bug2")
        card = self._card()
        _s, sess = self._get("/api/mission/m-001/log/session")
        self.assertEqual(sess["waitingCount"], 1)
        self.assertEqual([c["id"] for c in sess["waiting"]], ["m-bug1"])
        self.assertEqual(
            card["logWaitingCount"], 1,
            "the card's count and the panel's list disagree")
        self.assertEqual(card["logFiling"]["waitingCount"], 1,
                         "the stamp's copy of the same measurement drifted")
        self._post("/api/mission/m-001/log/run", {"overrides": {}})
        # `dispatched` is the load-bearing key (`children` is diagnostic — every
        # linked bug, gate-parked ones included; see `_mark_log_dispatched`).
        self.assertEqual(self._dispatch_record()["dispatched"], ["m-bug1"],
                         "the Go covered a bug the review never showed")

    def test_the_card_carries_the_waiting_count_with_no_live_session(self):
        """The restart case. A parent with waiting bugs and no session must
        still publish the daemon's own count, so the client never has to
        reconstruct it from the children."""
        self._file(BUG_A, BUG_B)
        self._drive_to_verify("m-bug2")
        from lcars_serve.actions import Actions
        restarted = Actions(repo_root=self.tmp, scripts=self.scripts,
                            worker_bin=self.worker_bin)
        board = restarted.log_overlay(self.adapter.board())
        card = None
        for col in (board.get("columns") or {}).values():
            for c in col:
                if c.get("id") == "m-001":
                    card = c
        self.assertIsNotNone(card)
        self.assertEqual(
            card.get("logWaitingCount"), 1,
            "a restarted daemon publishes no waiting count, so the card is "
            "left to count children with a different rule")


# ══════════════════════════════════════════════════════════════════════════════
# S163 fix round 7 (D3) — a card must not assert a drive it cannot evidence
# ══════════════════════════════════════════════════════════════════════════════
"""Round 6 cured the double dispatch by making the dispatch RECORD suppress the
Go until the batch reached its consolidated gate, and it wrote down the price:

    "a resolve-logs that dies mid-batch leaves its children short of verify and
     the Go stays refused until they are driven by hand"

The round-7 tester paid it. With a resolver that exits immediately, the card and
the detail both showed a permanently DISABLED `◐ RESOLVING 3 LOGGED BUGS…`, the
detail offered only MISSION LOG and ✕, and `/log/run` answered 409 with

    "…it becomes runnable as soon as this batch reaches its gate."

naming an event that could not occur. Their verdict on the round's standing
question — "is there a moment where I cannot tell the truth from this card?" —
was yes, this one: a card asserting a drive is in flight when there is no drive,
whose only stated route forward is impossible.

The cure is BOTH halves of the brief, because either alone is still a lie:

  * the drive's liveness becomes a MEASUREMENT. `log-dispatch.json` records the
    resolver's `pid`, and the daemon asks the operating system whether that
    process is alive (a live daemon polls the Popen handle it still holds, so an
    exited-but-unreaped child cannot read as running). Alive ⇒ everything round 6
    built stands, untouched. Provably gone with the batch short of its gate ⇒ the
    record is STALE and says so.
  * a stale record gives the captain an EXPLICIT way out — the same `/log/run`,
    with `resume: true`, from the same control. Never a second dispatch path, and
    the daemon re-checks liveness before it acts, so a resume can never land on
    top of a live drive.

The plain, un-flagged Go still 409s while a record stands, so round 6's
`second Go → 409`, the six-simultaneous race and the 5-Gos-5-spawns count are all
unchanged. What changes is that the refusal now names something the captain can
actually do.
"""


class DeadResolverTest(_LogSessionBase):
    """The daemon half. The `resolve` stub records its ARGV and EXITS — which is
    precisely the "dies mid-batch" case, since it never drives a child."""

    def _file(self, *bugs):
        sid = self._preview(*bugs)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        return sid

    def _dispatch(self):
        with open(os.path.join(self.tmp, ".git", "lcars", "missions", "m-001",
                               "log-dispatch.json")) as fh:
            return json.load(fh)

    def _go(self, **body):
        return self._post("/api/mission/m-001/log/run",
                          dict({"overrides": {}}, **body))

    def _await_dead(self, timeout=10):
        """Wait until the daemon can SEE the resolver is gone."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.actions._live_log_dispatch("m-001") is None:
                return True
            time.sleep(0.05)
        return False

    def _card(self, mid="m-001"):
        board = self.actions.log_overlay(self.adapter.board())
        for col in (board.get("columns") or {}).values():
            for c in col:
                if c.get("id") == mid:
                    return c
        self.fail("no card for %s" % mid)

    # -- the measurement ------------------------------------------------------
    def test_the_dispatch_record_names_the_process_it_spawned(self):
        """Without this there is nothing to ask the OS about."""
        self._file(BUG_A, BUG_B)
        self._go()
        deadline = time.time() + 10
        while time.time() < deadline and "pid" not in self._dispatch():
            time.sleep(0.05)
        rec = self._dispatch()
        self.assertIsInstance(rec.get("pid"), int,
                              "the record cannot be checked against reality")
        self.assertGreater(rec["pid"], 0)

    def test_a_card_stops_claiming_a_drive_once_the_resolver_is_gone(self):
        """The defect itself. `◐ RESOLVING N…` is an assertion about right now;
        with the resolver dead and the bugs untouched it is simply false."""
        self._file(BUG_A, BUG_B)
        self._go()
        self.assertTrue(self._await_dead(),
                        "the daemon still reads a dead resolver as a live drive")
        card = self._card()
        self.assertTrue(
            (card.get("logDispatch") or {}).get("stale"),
            "the card carries a dispatch it cannot evidence, unmarked")

    def test_a_live_resolver_is_never_called_stale(self):
        """The other edge, and the expensive one: calling a RUNNING drive dead
        is how the double dispatch comes back."""
        self._file(BUG_A, BUG_B)
        _pin_live_resolver(self)   # alive, and visibly so
        self._go()
        deadline = time.time() + 10
        while time.time() < deadline and "pid" not in self._dispatch():
            time.sleep(0.05)
        self.assertIsNotNone(self.actions._live_log_dispatch("m-001"),
                             "a sleeping resolver read as a dead drive")
        self.assertFalse((self._card().get("logDispatch") or {}).get("stale"))

    # -- the way out ----------------------------------------------------------
    def test_a_resume_re_runs_the_bugs_a_dead_drive_left(self):
        self._file(BUG_A, BUG_B)
        self._go()
        self.assertTrue(self._await_dead())
        status, _resp = self._go(resume=True)
        self.assertEqual(status, 200)
        deadline = time.time() + 10
        argvs = []
        while time.time() < deadline:
            argvs = [ln for ln in self._record("resolve").splitlines()
                     if ln.startswith("ARGV: ")]
            if len(argvs) >= 2:
                break
            time.sleep(0.05)
        self.assertEqual(argvs, ["ARGV: --parent m-001", "ARGV: --parent m-001"],
                         "the resume did not re-run the batch")

    def test_a_resume_is_refused_while_the_resolver_is_alive(self):
        """The resume must never become the second dispatch path in disguise."""
        self._file(BUG_A, BUG_B)
        _pin_live_resolver(self)
        self._go()
        deadline = time.time() + 10
        while time.time() < deadline and "pid" not in self._dispatch():
            time.sleep(0.05)
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {}, "resume": True})
        self.assertEqual(code, 409)
        self.assertIn("running", msg.lower())

    def test_the_plain_go_still_refuses_and_now_says_what_to_do(self):
        """Round 6's `second Go → 409` is untouched — but the advice must name
        something that can happen. It used to name only the batch reaching a
        gate, which for a dead drive never comes."""
        self._file(BUG_A, BUG_B)
        self._go()
        self.assertTrue(self._await_dead())
        code, msg = self._post_err("/api/mission/m-001/log/run",
                                   {"overrides": {}})
        self.assertEqual(code, 409, "a plain Go stopped being refused")
        self.assertIn("resume", msg.lower(),
                      "the refusal still names no action: %r" % msg)

    def test_the_bugs_a_dead_drive_left_are_waiting_again(self):
        """The panel's promise. A resume runs them, so the review must show
        them — `_waiting_children` subtracts a dispatch only while it is live."""
        self._file(BUG_A, BUG_B)
        self._go()
        self.assertTrue(self._await_dead())
        # The Go CONSUMED the session (S161), so the panel is rebuilt the way the
        # card's control rebuilds it: the read-only preview over the parent.
        _s, resp = self._post("/api/mission/m-001/log", {"text": ""})
        sess = resp.get("state") or resp
        self.assertEqual(sorted(c["id"] for c in sess["waiting"]),
                         ["m-bug1", "m-bug2"],
                         "the review is empty over bugs a resume will run")
        self.assertEqual(self._card().get("logWaitingCount"), 2)


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class DeadResolverCardTest(unittest.TestCase):
    """The client half: what the captain sees, and what the Go then posts."""

    STALE = {"sessionId": "abc123", "status": "dispatched", "stale": True,
             "children": ["m-002", "m-003"], "dispatched": ["m-002", "m-003"]}
    LIVE = {"sessionId": "abc123", "status": "dispatched",
            "children": ["m-002", "m-003"], "dispatched": ["m-002", "m-003"]}

    def test_a_stale_dispatch_offers_the_way_forward(self):
        m = dict(VERIFY, logDispatch=self.STALE, logWaitingCount=2)
        res = _drive(m, children=[_kid(0), _kid(1)])
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl, "no way forward at all: %s" % _texts(res))
        self.assertFalse(ctl["disabled"], "the way forward is a dead badge")
        self.assertTrue(ctl["clickable"])

    def test_a_stale_dispatch_no_longer_claims_a_drive(self):
        m = dict(VERIFY, logDispatch=self.STALE, logWaitingCount=2)
        res = _drive(m, children=[_kid(0), _kid(1)])
        self.assertIsNone(
            _resolving_control(res),
            "the card still asserts a drive that is not running")

    def test_a_live_dispatch_is_untouched(self):
        """Round 6's behaviour, byte for byte, whenever the drive IS live."""
        m = dict(VERIFY, logDispatch=self.LIVE)
        res = _drive(m, children=[_kid(0), _kid(1)])
        self.assertIsNone(_fix_control(res),
                          "a live drive re-offered its own dispatch")
        self.assertIsNotNone(_resolving_control(res))

    def test_the_detail_says_the_same_thing_as_the_card(self):
        m = dict(VERIFY, logDispatch=self.STALE, logWaitingCount=2)
        res = _drive(m, mode="detail", children=[_kid(0), _kid(1)])
        self.assertIsNotNone(_fix_control(res),
                             "the detail is still a dead end: %s" % _texts(res))

    def test_a_stale_dispatch_control_is_disabled_on_a_view_only_board(self):
        m = dict(VERIFY, logDispatch=self.STALE, logWaitingCount=2)
        res = _drive(m, children=[_kid(0), _kid(1)], readonly=True)
        ctl = _fix_control(res)
        self.assertIsNotNone(ctl)
        self.assertTrue(ctl["disabled"], "a view-only board offered a write")


if __name__ == "__main__":
    unittest.main()
