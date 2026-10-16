"""S191 — REMOTE MISSION VISIBILITY. A clone with no `.git/lcars` still sees it.

THE PROBLEM THIS PINS. `lcars adopt` (S189) rebuilds a mission on a second
laptop, but until it is adopted that laptop's board is EMPTY for a mission that
plainly exists on GitHub. The forge already knows enough for an honest read-only
card: `run.sh` swaps the `lcars:<stage>` label at every transition,
`lcars:awaiting-human` is additive, the assignee is the owner (S189/S190), and
Schedule opens one `lcars:ticket` sub-issue per ticket, so the parent issue's own
sub-issue summary tracks Implement progress.

FIVE THINGS ARE PINNED HERE, in this order of importance:

  1. gh ABSENT ⇒ NOTHING CHANGES. No overlay, no `meta.remote` key, a board
     byte-identical to the one this daemon served before this session. That is
     every user who does not have two laptops, which is every user.

  2. THE POLL SEAM IS SLOW AND CACHED, and this is a ROADMAP-LEVEL constraint
     (S152): the board re-fetches itself every four seconds, so a listing taken
     per render is a `gh issue list` storm. ONE listing per CYCLE, reused by
     every remote card, proven with an argv-COUNTING stub and an injected clock.

  3. LOCAL MISSIONS ALWAYS WIN. A mission that has been adopted is LOCAL, and
     the same issue must never draw two cards.

  4. THE STAGE COMES FROM THE LABEL, NEVER THE ENVELOPE. The S188 envelope is
     refreshed at exactly two transfer points, so its `stage` is stale
     mid-pipeline BY CONSTRUCTION; `gh_relabel` moves the label at every single
     transition. One source per fact.

  5. THE CARD IS READ-ONLY, and ADOPT is offered at exactly the two ENDS
     (align / verify) — the v1 portability boundary S189 drew.

No gh, no network, no model: `gh` is a bash stub that records its argv and cats
a JSON payload, and the clock is injected.
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.remote import RemoteMissions  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

ME = "roferg"
OTHER = "picard"
NODE = shutil.which("node")
OWNER_HARNESS = os.path.join(HERE, "board_owner_harness.js")

# The refusal a remote card's write affordances carry. ONE sentence, shared by
# the tooltip and (for a verb that reaches it) the daemon.
REMOTE_LINE = ("driven from another machine — adopt at Align/Verify to act here")


# --------------------------------------------------------------------------
# the fake forge
# --------------------------------------------------------------------------
def issue(number, stage="implement", title=None, labels=(), assignee=None,
          body=None, sub=None, state="OPEN", closed_at=None):
    """One `gh issue list --json …` row, in the shape real gh 2.96 emits.

    `sub` is the `subIssuesSummary` block — {completed,total} — which is how the
    forge reports one mission's `lcars:ticket` sub-issues without a second call.
    """
    names = ["lcars:mission", "lcars:%s" % stage, "lcars:feature"]
    names += list(labels)
    row = {
        "number": number,
        "title": title or ("remote mission #%d" % number),
        "state": state,
        "labels": [{"name": n} for n in names],
        "body": body if body is not None else "A remote mission.",
        "updatedAt": "2026-09-08T10:00:00Z",
        "assignees": ([{"login": assignee}] if assignee else []),
        "subIssuesSummary": (sub if sub is not None
                             else {"completed": 0, "total": 0,
                                   "percentCompleted": 0}),
    }
    # S278 — the field the Done column orders by. gh emits it on every CLOSED
    # issue (verified read-only against acme/widget, 2026-10-11: present on
    # all 51 done rows) and as `null` on an open one, which is exactly how a row
    # built without it reads here.
    if closed_at is not None:
        row["closedAt"] = closed_at
    return row


def gh_stub(tmp, rows, record, fail=False, name="gh-stub.sh"):
    """A `gh` stand-in that RECORDS EVERY INVOCATION and cats a payload.

    The recording is the whole point of behaviour 5: a per-render listing and a
    per-cycle listing look identical from the board, and differ only in how many
    times this file was appended to.
    """
    payload = os.path.join(tmp, name + ".json")
    with open(payload, "w") as fh:
        json.dump(list(rows), fh)
    path = os.path.join(tmp, name)
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 'printf "%s\\n" "$*" >> "' + record + '"\n'
                 + ("exit 1\n" if fail else 'cat "' + payload + '"\n'))
    os.chmod(path, 0o755)
    return path


def calls(record):
    if not os.path.exists(record):
        return []
    with open(record) as fh:
        return [ln for ln in fh.read().splitlines() if ln.strip()]


class Clock(object):
    """An injected clock. The cache is a TIME cache, so the test owns time."""

    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


def remote(tmp, rows, record, fail=False, clock=None, ttl=30.0, gh=None):
    return RemoteMissions(
        repo_root=tmp,
        gh_bin=(gh if gh is not None else gh_stub(tmp, rows, record, fail=fail)),
        ttl=ttl, clock=(clock or Clock()))


# --------------------------------------------------------------------------
# 1. gh absent ⇒ the board is what it was
# --------------------------------------------------------------------------
def scrub(b):
    """`activeSecondsAt` is a server wall-clock stamp; it moves between two
    board() calls a millisecond apart and is not what byte-identity is about
    (S190's suite scrubs the same field for the same reason)."""
    seen = list(b.get("missions", []))
    for col in b.get("columns", {}).values():
        seen += list(col)
    for c in seen:
        if "activeSecondsAt" in c:
            c["activeSecondsAt"] = 0
    return b


class GhAbsentIsByteIdentical(unittest.TestCase):
    """THE constraint of this session. Everyone else's board is untouched."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-local", stage="plan", issue=101,
                        created="2026-06-01T10:00:00Z")
        fx.plant_paused(self.tmp, "m-paused", stage="implement", issue=103)
        self.reader = lambda r: "git@x:acme/repo.git"

    def _today(self):
        return scrub(LocalAdapter(self.tmp, git_url_reader=self.reader).board())

    def test_no_gh_binary_leaves_the_payload_byte_identical(self):
        missing = os.path.join(self.tmp, "definitely-not-gh")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=self.reader,
            remote=RemoteMissions(repo_root=self.tmp, gh_bin=missing))
        self.assertEqual(
            json.dumps(self._today(), sort_keys=True, indent=2),
            json.dumps(scrub(adapter.board()), sort_keys=True, indent=2),
            "an absent gh changed the board; the overlay must be invisible")

    def test_no_gh_binary_adds_no_meta_remote_key(self):
        missing = os.path.join(self.tmp, "definitely-not-gh")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=self.reader,
            remote=RemoteMissions(repo_root=self.tmp, gh_bin=missing))
        self.assertNotIn("remote", adapter.board()["meta"])

    def test_an_absent_gh_is_never_even_invoked(self):
        record = os.path.join(self.tmp, "rec.txt")
        missing = os.path.join(self.tmp, "definitely-not-gh")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=self.reader,
            remote=RemoteMissions(repo_root=self.tmp, gh_bin=missing))
        adapter.board()
        self.assertEqual([], calls(record))

    def test_the_overlay_is_off_by_env_switch(self):
        record = os.path.join(self.tmp, "rec.txt")
        os.environ["LCARS_REMOTE_OVERLAY"] = "0"
        self.addCleanup(os.environ.pop, "LCARS_REMOTE_OVERLAY", None)
        adapter = LocalAdapter(
            self.tmp, git_url_reader=self.reader,
            remote=remote(self.tmp, [issue(201)], record))
        self.assertEqual(
            json.dumps(self._today(), sort_keys=True, indent=2),
            json.dumps(scrub(adapter.board()), sort_keys=True, indent=2))
        self.assertEqual([], calls(record))


class AGhFailureNeverTouchesLocalCards(unittest.TestCase):
    """gh is THERE but it cannot answer — no auth, no network, wrong repo."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-local", stage="plan", issue=101,
                        created="2026-06-01T10:00:00Z")
        self.record = os.path.join(self.tmp, "rec.txt")
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [], self.record, fail=True))

    def test_the_local_cards_are_all_still_there(self):
        ids = [c["id"] for c in self.adapter.board()["missions"]]
        self.assertEqual(["m-local"], ids)

    def test_the_board_says_remote_data_is_unavailable(self):
        self.assertEqual({"status": "unavailable"},
                         self.adapter.board()["meta"]["remote"])

    def test_a_failing_gh_is_still_only_asked_once_per_cycle(self):
        # The degraded path must not become the storm the healthy one avoids.
        for _ in range(6):
            self.adapter.board()
        self.assertEqual(1, len(calls(self.record)))


# --------------------------------------------------------------------------
# 2. the remote card
# --------------------------------------------------------------------------
class RemoteOnlyMissionBecomesACard(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-local", stage="plan", issue=101,
                        created="2026-06-01T10:00:00Z")
        self.record = os.path.join(self.tmp, "rec.txt")
        self.rows = [
            issue(201, stage="implement", assignee=ME,
                  title="Add a CSV export", sub={"completed": 3, "total": 7}),
            issue(202, stage="align", assignee=OTHER, title="Dark mode"),
            issue(203, stage="verify", title="Unassigned at verify"),
            issue(204, stage="research", labels=["lcars:awaiting-human"]),
        ]
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, self.rows, self.record))

    def cards(self):
        b = self.adapter.board()
        return {c["id"]: c for c in b["missions"]}, b

    def test_a_remote_only_mission_gets_a_card(self):
        cards, _ = self.cards()
        self.assertIn("201", cards)

    def test_the_local_mission_is_untouched_and_still_local(self):
        cards, _ = self.cards()
        self.assertIn("m-local", cards)
        self.assertNotIn("remote", cards["m-local"])

    def test_the_remote_card_is_marked_remote(self):
        cards, _ = self.cards()
        self.assertIs(True, cards["201"]["remote"])

    def test_the_stage_comes_from_the_STAGE_LABEL(self):
        # Not from the S188 envelope, which is refreshed at two transfer points
        # and is therefore stale mid-pipeline BY CONSTRUCTION.
        cards, _ = self.cards()
        self.assertEqual("implement", cards["201"]["stage"])
        self.assertEqual("align", cards["202"]["stage"])
        self.assertEqual("verify", cards["203"]["stage"])

    def test_a_stale_envelope_stage_is_ignored(self):
        rows = [issue(
            301, stage="implement",
            body="Spec.\n\n<!-- lcars:handoff v1\n"
                 '{"id":"lcars-x","stage":"align","branch":"lcars/x"}\n-->')]
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, os.path.join(self.tmp, "r2.txt")))
        card = {c["id"]: c for c in adapter.board()["missions"]}["301"]
        self.assertEqual("implement", card["stage"],
                         "the envelope's stale stage outranked the label")

    def test_the_card_lands_in_its_stage_column(self):
        _, b = self.cards()
        self.assertIn("201", [c["id"] for c in b["columns"]["implement"]])
        self.assertIn("202", [c["id"] for c in b["columns"]["align"]])

    def test_awaiting_human_comes_from_its_own_label(self):
        cards, _ = self.cards()
        self.assertTrue(cards["204"]["awaiting"])
        self.assertFalse(cards["201"]["awaiting"])

    def test_the_owner_block_is_the_one_s190_builds(self):
        cards, _ = self.cards()
        self.assertEqual(
            {"login": ME, "avatarUrl": "https://github.com/%s.png?size=64" % ME},
            cards["201"]["owner"])
        self.assertEqual(OTHER, cards["202"]["owner"]["login"])

    def test_an_unassigned_remote_mission_carries_no_owner_key(self):
        cards, _ = self.cards()
        self.assertNotIn("owner", cards["203"])

    def test_meta_reports_the_remote_read_is_healthy(self):
        _, b = self.cards()
        self.assertEqual("ok", b["meta"]["remote"]["status"])
        self.assertEqual(4, b["meta"]["remote"]["count"])

    def test_the_title_is_the_issue_title(self):
        cards, _ = self.cards()
        self.assertEqual("Add a CSV export", cards["201"]["title"])

    def test_the_card_carries_its_issue_number(self):
        cards, _ = self.cards()
        self.assertEqual(201, cards["201"]["issue"])


class RemoteTicketProgress(unittest.TestCase):
    """Behaviour 2 — closed/total from the mission's `lcars:ticket` sub-issues."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _card(self, row):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [row], self.record))
        return {c["id"]: c for c in adapter.board()["missions"]}[
            str(row["number"])]

    def test_implement_shows_closed_over_total(self):
        c = self._card(issue(201, stage="implement",
                             sub={"completed": 3, "total": 7}))
        self.assertEqual(3, c["progress"]["ticketsDone"])
        self.assertEqual(7, c["progress"]["ticketsTotal"])

    def test_the_label_reads_as_tickets_not_waves(self):
        # The remote view cannot see waves.json, so it must not imply it can.
        c = self._card(issue(201, stage="implement",
                             sub={"completed": 3, "total": 7}))
        self.assertEqual("TICKET 3/7", c["progress"]["label"])
        self.assertNotIn("wave", c["progress"])
        self.assertNotIn("shape", c["progress"])

    def test_no_sub_issues_means_no_progress_block(self):
        c = self._card(issue(201, stage="implement",
                             sub={"completed": 0, "total": 0}))
        self.assertIsNone(c["progress"])

    def test_progress_is_an_implement_stage_reading(self):
        c = self._card(issue(201, stage="plan",
                             sub={"completed": 1, "total": 4}))
        self.assertIsNone(c["progress"])

    def test_a_missing_summary_never_raises(self):
        row = issue(201, stage="implement")
        row.pop("subIssuesSummary")
        self.assertIsNone(self._card(row)["progress"])


class TheScoreComesFromTheLabelAndCostsNothing(unittest.TestCase):
    """S203 — Number One's verdict on a card this laptop has never driven.

    THE WHOLE REASON THE SCORE IS A LABEL. "Stage from the label, never the
    envelope" (S191) is not a style: the envelope is written by the FILING
    laptop and never updated, while a label is a fact the forge holds and the
    one listing this poll already makes carries it. So the intent match travels
    to every other laptop for free — and "for free" is the assertion, not the
    adjective: the invocation recorder below is the same one behaviour 5 uses to
    pin one listing per cycle, and it must read exactly ONE after a board that
    shows a score pill.

    Engagement rides the same road for the same reason. `state.numberOne` is a
    LOCAL file; the badge on a remote card can only come from `lcars:xo:engaged`.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _cards(self, rows):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record))
        return {c["id"]: c for c in adapter.board()["missions"]}

    def _card(self, row):
        return self._cards([row])[str(row["number"])]

    def test_the_score_rides_the_card_read_off_the_label(self):
        for label, score in (("lcars:xo:high", "high"),
                             ("lcars:xo:medium", "medium"),
                             ("lcars:xo:low", "low")):
            c = self._card(issue(301, stage="verify", labels=[label]))
            self.assertEqual(score, c["numberOne"]["score"], label)

    def test_the_engaged_badge_is_a_label_too(self):
        c = self._card(issue(302, stage="implement",
                             labels=["lcars:xo:engaged"]))
        self.assertEqual("engaged", c["numberOne"]["status"])
        self.assertNotIn("score", c["numberOne"])

    def test_engaged_and_scored_is_one_block(self):
        c = self._card(issue(303, stage="verify",
                             labels=["lcars:xo:engaged", "lcars:xo:medium"]))
        self.assertEqual({"status": "engaged", "score": "medium"},
                         c["numberOne"])

    def test_a_mission_with_none_of_them_carries_no_key(self):
        """ABSENT, never null — the rule every additive key in this shape has
        followed since S109, and what keeps a forge with no Number One on it
        serving the payload it served yesterday."""
        c = self._card(issue(304, stage="plan"))
        self.assertNotIn("numberOne", c)

    def test_the_local_facts_are_not_invented(self):
        """`engine`, `since` and `note` live in the DRIVING laptop's state.json.
        A second laptop cannot see them and must not answer as if it could."""
        c = self._card(issue(305, stage="verify", labels=["lcars:xo:low"]))
        for key in ("engine", "since", "note"):
            self.assertNotIn(key, c["numberOne"])

    def test_the_whole_board_still_costs_exactly_one_gh_call(self):
        """THE INVARIANT. One listing per cycle (S191) — a score on a card must
        never have bought a per-mission `gh` call to read a label."""
        cards = self._cards([
            issue(401, stage="verify", labels=["lcars:xo:high"]),
            issue(402, stage="verify", labels=["lcars:xo:medium"]),
            issue(403, stage="implement", labels=["lcars:xo:engaged"]),
            issue(404, stage="plan"),
        ])
        self.assertEqual("high", cards["401"]["numberOne"]["score"])
        self.assertEqual("medium", cards["402"]["numberOne"]["score"])
        self.assertEqual("engaged", cards["403"]["numberOne"]["status"])
        self.assertNotIn("numberOne", cards["404"])
        self.assertEqual(1, len(calls(self.record)),
                         "reading the score cost a second forge call")

    def test_the_listing_asks_for_nothing_new_to_get_it(self):
        """…and it did not widen the listing either. The label names arrive in
        the `labels` field the poll has always asked for."""
        self._cards([issue(401, stage="verify", labels=["lcars:xo:high"])])
        argv = calls(self.record)[0]
        self.assertIn("labels", argv)
        self.assertNotIn("label list", argv)

    def test_the_detail_view_answers_from_the_same_row(self):
        rows = [issue(501, stage="verify", labels=["lcars:xo:medium"])]
        rm = remote(self.tmp, rows, self.record)
        self.assertEqual("medium", rm.mission("501")["numberOne"]["score"])
        self.assertEqual(1, len(calls(self.record)))


# --------------------------------------------------------------------------
# 3. local wins
# --------------------------------------------------------------------------
class LocalMissionsAlwaysWin(unittest.TestCase):
    """Behaviour 3 — an ADOPTED mission is local, and draws exactly one card."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-adopted", stage="verify", issue=201,
                        created="2026-06-01T10:00:00Z")
        self.record = os.path.join(self.tmp, "rec.txt")
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, stage="verify"),
                                     issue(202, stage="align")], self.record))

    def test_exactly_one_card_for_the_adopted_mission(self):
        cards = self.adapter.board()["missions"]
        self.assertEqual(1, len([c for c in cards if c.get("issue") == 201]))

    def test_the_surviving_card_is_the_LOCAL_one(self):
        card = [c for c in self.adapter.board()["missions"]
                if c.get("issue") == 201][0]
        self.assertEqual("m-adopted", card["id"])
        self.assertNotIn("remote", card)

    def test_the_other_remote_mission_still_shows(self):
        ids = [c["id"] for c in self.adapter.board()["missions"]]
        self.assertIn("202", ids)

    def test_a_local_mission_with_no_issue_suppresses_nothing(self):
        fx.plant_simple(self.tmp, "m-noissue", stage="plan", issue=None,
                        created="2026-06-02T10:00:00Z")
        ids = [c["id"] for c in self.adapter.board()["missions"]]
        self.assertIn("202", ids)
        self.assertIn("m-noissue", ids)


# --------------------------------------------------------------------------
# 4. the poll seam
# --------------------------------------------------------------------------
class OneListingPerCycleNotPerRender(unittest.TestCase):
    """Behaviour 5, and the roadmap-level constraint (S152).

    The front end re-fetches /api/board every four seconds. A listing taken per
    render is a `gh issue list` storm; the only thing that tells the two apart is
    HOW MANY TIMES gh was invoked."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-local", stage="plan", issue=101)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.clock = Clock()
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201)], self.record,
                          clock=self.clock, ttl=30.0))

    def test_twenty_renders_inside_one_cycle_cost_one_listing(self):
        for _ in range(20):
            self.adapter.board()
        self.assertEqual(1, len(calls(self.record)),
                         "the overlay listed the forge more than once per cycle")

    def test_the_cached_cards_are_served_on_every_one_of_them(self):
        for _ in range(20):
            ids = [c["id"] for c in self.adapter.board()["missions"]]
            self.assertIn("201", ids)

    def test_the_next_cycle_costs_exactly_one_more(self):
        self.adapter.board()
        self.clock.advance(31)
        for _ in range(5):
            self.adapter.board()
        self.assertEqual(2, len(calls(self.record)))

    def test_the_listing_is_bounded_and_scoped_to_mission_issues(self):
        self.adapter.board()
        argv = calls(self.record)[0]
        self.assertIn("issue list", argv)
        self.assertIn("--label lcars:mission", argv)
        self.assertIn("--limit", argv)
        self.assertIn("subIssuesSummary", argv)

    def test_the_default_cadence_is_slow(self):
        r = RemoteMissions(repo_root=self.tmp, gh_bin="gh")
        self.assertGreaterEqual(r.ttl, 30.0)

    def test_the_cadence_is_env_tunable_but_floored(self):
        os.environ["LCARS_REMOTE_POLL"] = "1"
        self.addCleanup(os.environ.pop, "LCARS_REMOTE_POLL", None)
        r = RemoteMissions(repo_root=self.tmp, gh_bin="gh")
        self.assertGreaterEqual(r.ttl, 10.0,
                                "a 1s cadence is the storm S152 forbade")

    def test_a_longer_cadence_is_honoured(self):
        os.environ["LCARS_REMOTE_POLL"] = "120"
        self.addCleanup(os.environ.pop, "LCARS_REMOTE_POLL", None)
        r = RemoteMissions(repo_root=self.tmp, gh_bin="gh")
        self.assertEqual(120.0, r.ttl)


class TheLiveChannelIsUntouched(unittest.TestCase):
    """No SSE for remote changes — the slow poll updates them (brief item 4)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-local", stage="plan", issue=101)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.clock = Clock()
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201)], self.record,
                          clock=self.clock))

    def test_the_fingerprint_never_asks_the_forge(self):
        for _ in range(5):
            self.adapter.fingerprint()
        self.assertEqual([], calls(self.record))

    def test_the_fingerprint_does_not_move_when_the_remote_does(self):
        before = self.adapter.fingerprint()
        self.adapter.board()
        self.assertEqual(before, self.adapter.fingerprint())


# --------------------------------------------------------------------------
# 5. adopt — offered at the ENDS, refused honestly elsewhere
# --------------------------------------------------------------------------
class AdoptIsOfferedAtTheEnds(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.rows = [issue(200 + i, stage=s) for i, s in enumerate(
            ("align", "research", "validate", "plan", "plan-review",
             "schedule", "implement", "verify"))]
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, self.rows, self.record))

    def cards(self):
        return {c["stage"]: c for c in self.adapter.board()["missions"]}

    def test_align_and_verify_are_adoptable(self):
        c = self.cards()
        self.assertTrue(c["align"]["adoptable"])
        self.assertTrue(c["verify"]["adoptable"])

    def test_every_stage_between_them_is_not(self):
        c = self.cards()
        for stage in ("research", "validate", "plan", "plan-review",
                      "schedule", "implement"):
            self.assertFalse(c[stage]["adoptable"],
                             "%s offered adopt; the v1 boundary is the ENDS"
                             % stage)

    def test_a_local_card_never_carries_the_key(self):
        fx.plant_simple(self.tmp, "m-local", stage="align", issue=101)
        for c in self.adapter.board()["missions"]:
            if c["id"] == "m-local":
                self.assertNotIn("adoptable", c)


class AdoptEndpoint(unittest.TestCase):
    """The board's ADOPT dispatches `lcars adopt` through the action layer."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.rec = os.path.join(self.tmp, "adopt-argv.txt")
        stub = os.path.join(self.tmp, "adopt-stub.sh")
        with open(stub, "w") as fh:
            fh.write('#!/usr/bin/env bash\n'
                     'printf "%s\\n" "$*" >> "' + self.rec + '"\nexit 0\n')
        os.chmod(stub, 0o755)
        self.actions = Actions(repo_root=self.tmp,
                               scripts={"adopt": stub}, worker_bin="/bin/echo")
        self.adapter = LocalAdapter(self.tmp,
                                    git_url_reader=lambda r: "git@x:acme/repo.git")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(
            url, data=json.dumps(obj or {}).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_adopt_dispatches_the_skill_with_the_issue_number(self):
        status, _ = self.post("/api/mission/201/adopt")
        self.assertEqual(200, status)
        self.assertEqual(["--issue 201"], calls(self.rec))

    def test_a_non_numeric_id_is_refused_and_dispatches_nothing(self):
        status, payload = self.post("/api/mission/..%2Fetc/adopt")
        self.assertEqual(400, status)
        self.assertFalse(payload.get("ok"))
        self.assertEqual([], calls(self.rec))


# --------------------------------------------------------------------------
# 5c. S196 A4 — THE BOARD DOES NOT SWALLOW ADOPT'S WARNINGS
#
# MEASURED: an adopted clone had no config.json — no testCommand, so the
# Implement red gate has nothing to run. adopt SAID so, on stdout, and the
# board's ADOPT dispatch threw the whole string away and showed only
# "Adopted #34 — it is a local mission now." Adopt now seeds a config, but the
# swallow is a defect in its own right: attachments that cannot follow the
# issue, no open PR at Verify, a repo config that prefers a different engine —
# all of those still arrive as warnings on a SUCCESSFUL adopt, and all of them
# were being dropped by the one surface that could have shown them.
#
# They are lifted by adopt's OWN marker (`  ⚠ <sentence>`, what note() emits),
# not by matching its prose — the same discipline as _ADOPT_REFUSAL_BANNER.
# --------------------------------------------------------------------------
class AdoptWarningsReachTheBoard(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _serve(self, body):
        stub = _adopt_stub(self.tmp, "adopt-warn.sh", body)
        actions = Actions(repo_root=self.tmp, scripts={"adopt": stub},
                          worker_bin="/bin/echo")
        adapter = LocalAdapter(self.tmp,
                               git_url_reader=lambda r: "git@x:acme/repo.git")
        self.httpd = make_server(adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(url, data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_the_warnings_ride_out_on_the_response(self):
        self._serve(
            'printf "%s\\n" "\u25c7 Adopted m1 - stage align"\n'
            'printf "%s\\n" "  \u26a0 no testCommand could be detected"\n'
            'printf "%s\\n" "  \u26a0 the original mission had 2 attachment(s)"\n'
            'exit 0\n')
        status, payload = self.post("/api/mission/201/adopt")
        self.assertEqual(200, status)
        self.assertEqual(
            ["no testCommand could be detected",
             "the original mission had 2 attachment(s)"],
            payload["state"]["warnings"])

    def test_a_clean_adopt_carries_an_empty_warning_list(self):
        self._serve('printf "%s\\n" "\u25c7 Adopted m1 - stage align"\nexit 0\n')
        status, payload = self.post("/api/mission/201/adopt")
        self.assertEqual(200, status)
        self.assertEqual([], payload["state"]["warnings"])

    def test_the_full_output_still_travels_verbatim(self):
        """The warnings are a LIFT, not a replacement: nothing is dropped."""
        self._serve(
            'printf "%s\\n" "\u25c7 Adopted m1 - stage align"\n'
            'printf "%s\\n" "  \u26a0 one warning"\nexit 0\n')
        _, payload = self.post("/api/mission/201/adopt")
        self.assertIn("Adopted m1", payload["state"]["output"])
        self.assertIn("one warning", payload["state"]["output"])


# --------------------------------------------------------------------------
# 5b. S191 fix round 1 — THE TWO REFUSALS, SAID PROPERLY
#
# D5. An honest "no" must not arrive as a server fault. `lcars adopt` refuses
#     at a non-adoptable stage with a full, actionable sentence and exits 1; the
#     daemon wrapped every non-zero skill exit in a 502. 502 says THE SERVER
#     BROKE. Nothing broke — the captain asked for something the mission's own
#     state does not allow, which is 409. A crash is still a fault.
#
# D6. A remote card's tooltip and the daemon's refusal must be ONE sentence.
#     A direct POST to start/pause/resume/verify on a remote issue number said
#     `no such mission: 34` while the card it came from said "driven from
#     another machine — adopt at Align/Verify to act here". Two stories about
#     one thing is the exact failure S190 spent a session eliminating.
# --------------------------------------------------------------------------
class _EndpointBase(unittest.TestCase):
    """A live daemon over a tmp repo. Subclasses build the adapter/actions."""

    def serve(self, adapter, actions):
        self.httpd = make_server(adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(
            url, data=json.dumps(obj or {}).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())


def _adopt_stub(tmp, name, body):
    path = os.path.join(tmp, name)
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n" + body)
    os.chmod(path, 0o755)
    return path


# The sentence adopt.sh actually prints at a mid-pipeline stage, trimmed to the
# shape `die()` gives it: the banner, then the refusal.
MID_PIPELINE = ("mission is mid-pipeline at implement; portable ends are Align "
                "and Verify. Nothing was created.")


class AdoptRefusalIsNotAServerFault(_EndpointBase):
    """D5 — a refusal the captain caused reads as a refusal, not a 502."""

    def build(self, script):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        actions = Actions(repo_root=self.tmp, scripts={"adopt": script(self.tmp)},
                          worker_bin="/bin/echo")
        adapter = LocalAdapter(self.tmp,
                               git_url_reader=lambda r: "git@x:acme/repo.git")
        self.serve(adapter, actions)

    def test_a_non_adoptable_stage_is_a_conflict_not_a_fault(self):
        self.build(lambda t: _adopt_stub(
            t, "adopt-refuse.sh",
            'printf "lcars adopt: %s\\n" "' + MID_PIPELINE + '" >&2\nexit 1\n'))
        status, payload = self.post("/api/mission/34/adopt")
        self.assertEqual(409, status,
                         "an honest refusal was reported as a server fault")
        self.assertFalse(payload.get("ok"))

    def test_the_refusal_reaches_the_captain_WORD_FOR_WORD(self):
        # The prose is the whole value of the refusal — it names the boundary and
        # what to do instead. A status-code fix that ate the sentence would be a
        # worse bug than the one it cured.
        self.build(lambda t: _adopt_stub(
            t, "adopt-refuse.sh",
            'printf "lcars adopt: %s\\n" "' + MID_PIPELINE + '" >&2\nexit 1\n'))
        _, payload = self.post("/api/mission/34/adopt")
        self.assertEqual(MID_PIPELINE, payload.get("error"))
        self.assertNotIn("exited", payload.get("error", ""),
                         "the generic skill wrapper is still showing through")

    def test_a_GENUINE_CRASH_still_reads_as_a_fault(self):
        # The point of the cure is honesty in BOTH directions. A skill that dies
        # without ever reaching its own refusal channel is a broken server, and
        # 409 would be a lie in the other direction.
        self.build(lambda t: _adopt_stub(
            t, "adopt-crash.sh",
            'echo "adopt.sh: line 12: jq: command not found" >&2\nexit 127\n'))
        status, payload = self.post("/api/mission/34/adopt")
        self.assertEqual(502, status, "a crash was dressed up as a refusal")
        self.assertIn("127", payload.get("error", ""))

    def test_an_unbannered_failure_is_still_a_fault(self):
        # exit 1 alone is not a refusal. adopt.sh's `die()` stamps every honest
        # "no" with its own banner; output without one never went through it.
        self.build(lambda t: _adopt_stub(
            t, "adopt-silent.sh", 'echo "Traceback (most recent call last)" >&2\n'
                                  'exit 1\n'))
        status, _ = self.post("/api/mission/34/adopt")
        self.assertEqual(502, status)

    def test_a_SUCCESSFUL_adopt_is_untouched(self):
        self.build(lambda t: _adopt_stub(t, "adopt-ok.sh",
                                         'echo "adopted"\nexit 0\n'))
        status, payload = self.post("/api/mission/34/adopt")
        self.assertEqual(200, status)
        self.assertEqual(34, (payload.get("state") or {}).get("adopted"))


class RemoteWriteSaysWhatTheCardSays(_EndpointBase):
    """D6 — the tooltip, the card and the daemon tell ONE story."""

    VERBS = [("start", {}), ("pause", {}), ("resume", {}),
             ("verify", {"decision": "approve"}), ("respond", {"answer": "x"}),
             ("reapprove", {}), ("log", {"text": "x"})]

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.dispatched = os.path.join(self.tmp, "dispatched.txt")
        stub = _adopt_stub(self.tmp, "any.sh",
                           'printf "%s\\n" "$*" >> "' + self.dispatched + '"\n'
                           'exit 0\n')
        scripts = dict((k, stub) for k in
                       ("run", "pause", "respond", "approve", "feedback",
                        "log", "resolve", "adopt"))
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        # ONE local mission and ONE remote one, so every assertion below has a
        # negative control sitting beside it on the same daemon.
        fx.plant_simple(self.tmp, "m-local", stage="align", issue=101)
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(34, stage="implement")], self.record))
        self.serve(adapter, actions)

    def test_a_write_on_a_remote_mission_is_REFUSED_not_MISSING(self):
        for verb, body in self.VERBS:
            status, _ = self.post("/api/mission/34/%s" % verb, body)
            self.assertEqual(409, status,
                             "%s said the mission does not exist" % verb)

    def test_the_refusal_is_the_SAME_SENTENCE_the_card_carries(self):
        for verb, body in self.VERBS:
            _, payload = self.post("/api/mission/34/%s" % verb, body)
            self.assertEqual(REMOTE_LINE, payload.get("error"), verb)

    def test_nothing_is_dispatched_behind_the_refusal(self):
        for verb, body in self.VERBS:
            self.post("/api/mission/34/%s" % verb, body)
        self.assertEqual([], calls(self.dispatched))

    def test_ADOPT_is_still_offered_on_a_remote_mission(self):
        # The one write a remote card exists to offer. A gate that also refused
        # this would lock the door from the inside.
        status, _ = self.post("/api/mission/34/adopt")
        self.assertEqual(200, status)
        self.assertEqual(["--issue 34"], calls(self.dispatched))

    def test_a_MISSING_mission_still_says_it_is_missing(self):
        # The gate must not turn every unknown id into "driven elsewhere" — an
        # issue number the forge never listed genuinely is not here.
        status, payload = self.post("/api/mission/999/start")
        self.assertEqual(404, status)
        self.assertIn("no such mission", payload.get("error", ""))

    def test_a_LOCAL_mission_is_untouched_by_the_gate(self):
        status, _ = self.post("/api/mission/m-local/start")
        self.assertEqual(200, status)

    def test_the_daemon_and_board_js_carry_ONE_sentence_not_two(self):
        # THREE SURFACES, ONE VOICE (S190's rule, applied to S191's state): the
        # tooltip on the card, the constant this suite asserts against, and the
        # daemon's refusal body are the same bytes. Read out of the shipping
        # files, so a later edit to either one breaks here instead of in front of
        # the captain.
        with open(os.path.join(HERE, "..", "static", "board.js")) as fh:
            js = fh.read()
        self.assertIn('"%s"' % REMOTE_LINE, js,
                      "board.js no longer carries the sentence verbatim")
        from lcars_serve import server as srv
        self.assertEqual(REMOTE_LINE, srv._REMOTE_LOCK_LINE)


# --------------------------------------------------------------------------
# 6. the mission DETAIL of a remote card
# --------------------------------------------------------------------------
class RemoteMissionDetail(unittest.TestCase):
    """The card is click-to-open; a remote card must not open onto a 404."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, stage="verify", assignee=ME)],
                          self.record))

    def test_the_remote_detail_resolves(self):
        d = self.adapter.mission("201")
        self.assertIsNotNone(d)
        self.assertIs(True, d["remote"])
        self.assertEqual("verify", d["stage"])

    def test_it_claims_nothing_it_cannot_see(self):
        d = self.adapter.mission("201")
        self.assertEqual([], d["activity"])
        self.assertIsNone(d["adrs"])
        self.assertIsNone(d["criteria"])

    def test_an_unknown_id_is_still_none(self):
        self.assertIsNone(self.adapter.mission("nope"))


# --------------------------------------------------------------------------
# 7. the rendered card (board.js, in a vm)
# --------------------------------------------------------------------------
@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheRenderedRemoteCard(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _cards(self, rows, whoami=ME):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record))
        return {c["id"]: c for c in adapter.board()["missions"]}

    def _render(self, card, whoami=ME):
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": whoami}, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    @staticmethod
    def _walk(node, out=None):
        out = [] if out is None else out
        out.append(node)
        for kid in node.get("children", []):
            TheRenderedRemoteCard._walk(kid, out)
        return out

    def _buttons(self, dom):
        return [n for n in self._walk(dom)
                if (n.get("tag") or "").lower() == "button"]

    def test_the_card_carries_a_remote_marker(self):
        card = self._cards([issue(201, stage="implement", assignee=ME)])["201"]
        dom = self._render(card)
        self.assertIn("remote", dom["cls"])
        pills = [n for n in self._walk(dom) if "REMOTE" in (n.get("text") or "")]
        self.assertTrue(pills, "no remote marker rendered on the card")
        self.assertIn("pill", pills[0]["cls"])

    def test_every_write_affordance_is_disabled_and_says_why(self):
        """S196 B3 INVERTED THIS, deliberately — read the reason.

        S191 shipped a remote card whose dead controls stayed on screen,
        disabled, carrying REMOTE_LINE as a tooltip. The captain's ruling (R8,
        2026-09-09, after looking at one) is that nothing on a remote card is
        actionable BY DEFINITION, so a dead `\u25b6 START` is noise that
        competes with the ONE control that works. The card now renders no dead
        control at all, and the stage label (`#201 \u00b7 lcars:implement`)
        carries the state it was standing in for.

        What the original assertion protected — "no control on a remote card is
        ever live" — is STRONGER now, not weaker, and is asserted below: there
        is nothing there to be live. The disabled-and-says-why contract itself
        did not go away; it moved to the DETAIL surface, where the controls do
        still render (a captain who opened a mission to read it is entitled to
        see what it HAS), and it is pinned in RemoteDetailControlsReadAsLocked.
        """
        card = self._cards([issue(201, stage="implement", assignee=ME)])["201"]
        dom = self._render(card)
        for b in self._buttons(dom):
            self.assertTrue(b["disabled"], "a live control on a remote card")
            self.assertEqual(REMOTE_LINE, b["title"])

    def test_a_remote_card_i_own_is_still_read_only(self):
        # S190's light lock does NOT fire here (the owner IS me) — so the remote
        # sweep is the only thing between the captain and a Start he cannot honour.
        card = self._cards([issue(201, stage="align", assignee=ME)])["201"]
        for b in self._buttons(self._render(card, whoami=ME)):
            if "ADOPT" in (b.get("text") or "").upper():
                continue
            self.assertTrue(b["disabled"])

    def test_adopt_is_offered_at_align(self):
        card = self._cards([issue(201, stage="align")])["201"]
        labels = [b.get("text") or "" for b in self._buttons(self._render(card))]
        self.assertTrue(any("ADOPT" in t.upper() for t in labels), labels)

    def test_adopt_is_offered_at_verify(self):
        card = self._cards([issue(201, stage="verify")])["201"]
        labels = [b.get("text") or "" for b in self._buttons(self._render(card))]
        self.assertTrue(any("ADOPT" in t.upper() for t in labels), labels)

    def test_adopt_is_live_not_disabled(self):
        card = self._cards([issue(201, stage="align")])["201"]
        ad = [b for b in self._buttons(self._render(card))
              if "ADOPT" in (b.get("text") or "").upper()]
        self.assertEqual(1, len(ad))
        self.assertFalse(ad[0]["disabled"])

    def test_adopt_is_absent_mid_pipeline(self):
        for stage in ("research", "plan", "schedule", "implement"):
            card = self._cards([issue(201, stage=stage)])["201"]
            labels = [b.get("text") or ""
                      for b in self._buttons(self._render(card))]
            self.assertFalse(any("ADOPT" in t.upper() for t in labels),
                             "adopt offered at %s" % stage)

    def test_the_new_glyphs_are_in_the_house_family(self):
        """S190's D3 was a glyph outside the house family; this is the guard.

        The set is `test_help_console.ConsoleTitleGlyphTest.LCARS_GLYPHS` — flat,
        geometric, single-colour, drawn in the page's own text font, never a
        system emoji. A card in a starship console gets no exceptions."""
        FAMILY = "▦▤▣▧▨▩◆◇◈●○◐▶▸▹✓⊹⌖⬢⬡⚡↩■"
        card = self._cards([issue(201, stage="align")])["201"]
        dom = self._render(card)
        for n in self._walk(dom):
            text = (n.get("text") or "").strip()
            if not text:
                continue
            if "REMOTE" in text or "Adopt" in text:
                self.assertIn(text[0], FAMILY,
                              "%r opens with an off-family glyph" % text)

    def test_a_local_card_renders_with_no_remote_marker(self):
        fx.plant_simple(self.tmp, "m-local", stage="align", issue=101)
        card = self._cards([])["m-local"]
        dom = self._render(card)
        self.assertNotIn("remote", dom["cls"])
        for n in self._walk(dom):
            self.assertNotIn("REMOTE", (n.get("text") or ""))


# --------------------------------------------------------------------------
# 8. S196 A3(g) — WHICH ENGINE, AND WHY THAT ONE, ON THE BOARD
#
# The resolver's `worker: claude (bin: config)` line printed ZERO times during a
# real 6-stage auto-advance run, was persisted nowhere, and never reached this
# board. So a mission silently re-homed onto a billed engine by a clone's
# config.json looked exactly like one that chose that engine on purpose, and the
# spend was the only symptom.
#
# The pair is RECORDED BY ITS PRODUCER — `lcars adopt` at the handoff, run.sh's
# resolver at each resolution — and read here. Nothing in the daemon or the front
# end re-derives which source would have won.
# --------------------------------------------------------------------------
@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheEngineProvenanceOnACard(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _plant(self, mid, **extra):
        fx.plant_simple(self.tmp, mid, stage="align", issue=101,
                        worker_bin="copilot")
        if extra:
            sp = os.path.join(self.tmp, ".git", "lcars", "missions", mid,
                              "state.json")
            with open(sp) as fh:
                st = json.load(fh)
            st.update(extra)
            with open(sp, "w") as fh:
                json.dump(st, fh, indent=2)
        adapter = LocalAdapter(self.tmp,
                               git_url_reader=lambda r: "git@x:acme/repo.git")
        return {c["id"]: c for c in adapter.board()["missions"]}[mid]

    def _render(self, card):
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": ME}, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    def _texts(self, dom):
        return [(n.get("text") or "").strip()
                for n in TheRenderedRemoteCard._walk(dom)]

    def test_the_pair_reaches_the_board_shape(self):
        card = self._plant("m-eng", engineSource="mission",
                           engineResolved="copilot")
        self.assertEqual("mission", card["engineSource"])
        self.assertEqual("copilot", card["engineResolved"])

    def test_the_card_SAYS_which_engine_and_where_it_came_from(self):
        card = self._plant("m-eng", engineSource="mission",
                           engineResolved="copilot")
        self.assertIn("copilot \u00b7 mission pin", self._texts(self._render(card)))

    def test_a_conversion_at_adopt_says_so_in_words(self):
        card = self._plant("m-conv", engineSource="adopt-converted",
                           engineResolved="claude")
        self.assertIn("claude \u00b7 converted at adopt",
                      self._texts(self._render(card)))

    def test_an_engine_the_repo_CONFIG_imposed_is_named_as_such(self):
        """The case that cost money: the pin says copilot, config ran claude."""
        card = self._plant("m-cfg", engineSource="config",
                           engineResolved="claude")
        texts = self._texts(self._render(card))
        self.assertIn("claude \u00b7 repo config", texts)

    def test_a_mission_with_no_recorded_provenance_renders_no_such_line(self):
        card = self._plant("m-bare")
        self.assertNotIn("engineSource", card)
        for t in self._texts(self._render(card)):
            self.assertNotIn("mission pin", t)
            self.assertNotIn("repo config", t)

    def test_the_issue_and_stage_line_is_untouched(self):
        """The provenance is a SECOND line; `#101 \u00b7 lcars:align` is unchanged."""
        card = self._plant("m-eng", engineSource="mission",
                           engineResolved="copilot")
        self.assertIn("#101 \u00b7 lcars:align", self._texts(self._render(card)))


# --------------------------------------------------------------------------
# 9. S196 HALF B — A REMOTE CARD YOU CAN READ
#
# GROUND TRUTH, measured in real Chrome by a fresh tester on 2026-09-09: on a
# remote card the dead `▶ START` painted median rgb(64,141,122) and the live
# `▹ ADOPT ▸` beside it rgb(85,193,161) — a separation of 1.79:1. They were
# the same button. The SAME board's owned-by-other lock (S190/S191) measured
# 8.39:1 against a live control, because it is HOLLOW where a live control is
# SOLID. The house already had the right language; remote cards were left out.
#
# THREE CURES, and each one is a different kind of fix:
#   B2  every control the remote sweep disables now wears `.btn.locked` and the
#       `⊘` mark — the SAME treatment, not a second one.
#   B3  the CARD stops drawing them at all (R8).
#   B4  Adopt's leading glyph stops stuttering against its own `▸` suffix.
#
# THESE ARE DOM-SHAPE TRIPWIRES, NOT THE PROOF. What a rule paints is a question
# only a browser can answer — the whole reason S190 round 1 shipped an
# `opacity:1` that computed as 1 and painted at .55. The proof is
# tests/drives/s190/owner-paint.sh, in real Chrome, off pixels, with red
# controls. These are what stops the cured shape walking back in between runs.
# --------------------------------------------------------------------------

# The house glyph family (board.js LOCK_ACTION_GLYPHS + the lock mark + the
# remote diamond). S190's D3 and S191's `⇩` near-miss were both a glyph from
# outside it; nothing here may add another.
HOUSE_GLYPHS = u"\u25b6\u25b8\u25b9\u2713\u23f8\u25d0\u25f7\u21bb\u25c6\u2739\u2298\u25c8"


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ARemoteCardOffersOnlyWhatItCanDo(unittest.TestCase):
    """B3 — R8: hide Verify, offer only Adopt."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _card(self, **kw):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, **kw)], self.record))
        return {c["id"]: c for c in adapter.board()["missions"]}["201"]

    def _dom(self, card, whoami=ME):
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": whoami}, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    @staticmethod
    def _walk(node, out=None):
        out = [] if out is None else out
        out.append(node)
        for kid in node.get("children", []):
            ARemoteCardOffersOnlyWhatItCanDo._walk(kid, out)
        return out

    def _ctrl_buttons(self, dom):
        rows = [n for n in self._walk(dom)
                if "card-ctrl" in (n.get("cls") or "").split()]
        self.assertEqual(1, len(rows), "expected exactly one control row")
        return [n for n in self._walk(rows[0])
                if (n.get("tag") or "").lower() == "button"]

    def test_a_remote_card_carries_NO_dead_control(self):
        """The headline. A dead `▶ START` measured 1.79:1 against the live
        Adopt beside it; the cure is that there is nothing there to measure."""
        for stage in ("research", "plan", "schedule", "implement", "verify",
                      "align"):
            dom = self._dom(self._card(stage=stage))
            dead = [b for b in self._ctrl_buttons(dom) if b["disabled"]]
            self.assertEqual([], [b.get("text") for b in dead],
                             "a dead control survived on a remote %s card"
                             % stage)

    def test_a_remote_card_MID_PIPELINE_offers_nothing_at_all(self):
        """The tester found exactly this card: `research`, offering ONLY a dead
        `▶ START` and no Adopt. It must now offer nothing — and lose no
        information, because `#201 · lcars:research` is still on the card."""
        dom = self._dom(self._card(stage="research"))
        self.assertEqual([], self._ctrl_buttons(dom))
        stage_lines = [n.get("text") or "" for n in self._walk(dom)
                       if (n.get("text") or "").startswith("#201")]
        self.assertIn(u"#201 \u00b7 lcars:research", stage_lines)

    def test_at_verify_the_ONLY_control_is_adopt_and_it_is_LIVE(self):
        dom = self._dom(self._card(stage="verify"))
        btns = self._ctrl_buttons(dom)
        self.assertEqual(1, len(btns),
                         [b.get("text") for b in btns])
        self.assertIn("ADOPT", (btns[0].get("text") or "").upper())
        self.assertFalse(btns[0]["disabled"])

    def test_VERIFY_itself_is_HIDDEN_not_merely_disabled(self):
        """R8, verbatim: on a remote card, hide Verify."""
        texts = [b.get("text") or ""
                 for b in self._ctrl_buttons(self._dom(self._card(stage="verify")))]
        for t in texts:
            self.assertNotIn("REVIEW PR", t.upper())
            self.assertNotIn("MERGE", t.upper())
            self.assertNotIn("VERIFY", t.upper())

    def test_at_align_the_ONLY_control_is_adopt(self):
        btns = self._ctrl_buttons(self._dom(self._card(stage="align")))
        self.assertEqual(1, len(btns), [b.get("text") for b in btns])
        self.assertIn("ADOPT", (btns[0].get("text") or "").upper())

    def test_an_AWAITING_remote_card_still_offers_no_Answer_button(self):
        """`● AWAITING YOU` on a remote card is somebody ELSE's gate."""
        dom = self._dom(self._card(stage="verify",
                                   labels=["lcars:awaiting-human"]))
        texts = [b.get("text") or "" for b in self._ctrl_buttons(dom)]
        self.assertFalse(any("ANSWER" in t.upper() for t in texts), texts)

    def test_a_LOCAL_card_keeps_every_control_it_had(self):
        """The negative control. The removal is keyed on `remote`, and a board
        with no remote cards on it must render exactly as it did."""
        fx.plant_simple(self.tmp, "m-local", stage="verify", issue=101,
                        pr_url="https://github.com/acme/repo/pull/7",
                        pr_number="7", review="open")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [], self.record))
        card = {c["id"]: c for c in adapter.board()["missions"]}["m-local"]
        self.assertTrue(self._ctrl_buttons(self._dom(card)),
                        "a LOCAL card lost its controls")


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheAdoptButtonDoesNotStutter(unittest.TestCase):
    """B4 — `▹ Adopt ▸` is a hollow triangle beside a solid one.

    `▸` is the SHARED dispatch suffix every dispatching button on this board
    carries (`Go ▸`, `✓ Review PR ▸`), so the suffix is not the thing to
    change. The leading glyph is. `◆` is in LOCK_ACTION_GLYPHS, and it differs
    from the remote pill's `◈` by FILL — which is the same sentence the rest of
    this session speaks: solid means it is yours to act on.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _label(self):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, stage="verify")], self.record))
        card = {c["id"]: c for c in adapter.board()["missions"]}["201"]
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": ME}, fh)
        dom = json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))
        out = []
        def walk(n):
            out.append(n)
            for k in n.get("children", []):
                walk(k)
        walk(dom)
        labels = [n.get("text") or "" for n in out
                  if (n.get("tag") or "").lower() == "button"
                  and "ADOPT" in (n.get("text") or "").upper()]
        self.assertEqual(1, len(labels), labels)
        return labels[0]

    def test_the_leading_glyph_is_the_solid_diamond(self):
        self.assertTrue(self._label().startswith(u"\u25c6 "), self._label())

    def test_it_no_longer_opens_with_a_HOLLOW_TRIANGLE(self):
        self.assertFalse(self._label().startswith(u"\u25b9"))

    def test_it_keeps_the_shared_dispatch_suffix(self):
        self.assertTrue(self._label().endswith(u" \u25b8"), self._label())

    def test_the_label_carries_exactly_two_glyphs_and_both_are_house(self):
        label = self._label()
        glyphs = [c for c in label if c in HOUSE_GLYPHS]
        self.assertEqual([u"\u25c6", u"\u25b8"], glyphs, label)

    def test_no_glyph_in_the_label_is_OUTSIDE_the_house_family(self):
        for ch in self._label():
            if ord(ch) > 0x2000:
                self.assertIn(ch, HOUSE_GLYPHS,
                              "%r is outside the house family" % ch)

    def test_the_RESTORED_label_after_a_failed_adopt_matches(self):
        """board.js swaps the label to `◐ Adopting…` on click and puts it BACK
        on failure. Two literals, and a session that changed one and not the
        other would resurrect the stutter on exactly the unhappy path."""
        with open(os.path.join(HERE, "..", "static", "board.js")) as fh:
            src = fh.read()
        self.assertEqual(2, src.count(u'"\u25c6 Adopt \u25b8"'),
                         "the adopt label is not identical in both places")
        self.assertEqual(0, src.count(u'"\u25b9 Adopt \u25b8"'))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class RemoteDetailControlsReadAsLocked(unittest.TestCase):
    """B2 — the remote sweep now speaks the house's lock language.

    The DETAIL is where a remote mission's controls still render: the card hides
    them (B3), but a captain who clicked in to READ the mission is entitled to
    see what it has. Those controls were painting `opacity:.4` on a saturated
    `.go` fill — the exact look S191's D4 condemned and cured on owned cards.
    They now take `.btn.locked` (hollow, dashed) and the `⊘` mark, which is the
    SAME treatment, applied by the SAME function (markLocked), not a second one.
    """

    DETAIL_HARNESS = os.path.join(HERE, "board_detail_harness.js")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _detail(self, stage="verify"):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, stage=stage)], self.record))
        mi = adapter.mission("201")
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump(mi, fh)
        out = json.loads(subprocess.check_output(
            [NODE, self.DETAIL_HARNESS, p, "detail"]))
        self.assertIsNotNone(out["overlay"], "the detail never rendered")
        return out["overlay"]

    @staticmethod
    def _walk(node, out=None):
        out = [] if out is None else out
        out.append(node)
        for kid in node.get("children", []):
            RemoteDetailControlsReadAsLocked._walk(kid, out)
        return out

    def _buttons(self, dom):
        return [n for n in self._walk(dom)
                if (n.get("tag") or "").lower() == "button"]

    def test_the_detail_STILL_renders_the_controls(self):
        """The half of S191's contract that did NOT move. If this ever empties,
        B3 has leaked onto the detail and B2 is measuring nothing."""
        dead = [b for b in self._buttons(self._detail()) if b["disabled"]]
        self.assertTrue(dead, "the remote detail rendered no disabled control")

    def test_every_disabled_control_wears_the_state_class(self):
        for b in self._buttons(self._detail()):
            if not b["disabled"]:
                continue
            self.assertIn("locked", (b.get("cls") or "").split(),
                          "%r is disabled and does not read as locked"
                          % (b.get("text") or ""))

    def test_every_disabled_control_opens_with_the_lock_mark(self):
        for b in self._buttons(self._detail()):
            if not b["disabled"]:
                continue
            text = (b.get("text") or "").strip()
            if not text:
                continue
            self.assertTrue(text.startswith(u"\u2298"),
                            "%r still claims it will go" % text)

    def test_the_action_glyph_is_REPLACED_never_merely_prefixed(self):
        """`⊘ ▶ Start` would be the lie stated twice."""
        for b in self._buttons(self._detail()):
            text = (b.get("text") or "").strip()
            if not text.startswith(u"\u2298"):
                continue
            rest = text[1:].lstrip()
            self.assertFalse(rest[:1] in HOUSE_GLYPHS and rest[:1] != u"",
                             "%r keeps its action glyph behind the lock mark"
                             % text)

    def test_ADOPT_is_the_one_control_that_stays_LIVE_and_UNMARKED(self):
        live = [b for b in self._buttons(self._detail()) if not b["disabled"]]
        labels = [b.get("text") or "" for b in live]
        self.assertTrue(any("ADOPT" in t.upper() for t in labels), labels)
        for b in live:
            self.assertNotIn("locked", (b.get("cls") or "").split())
            self.assertFalse((b.get("text") or "").startswith(u"\u2298"))

    def test_the_CLOSE_control_is_never_marked(self):
        for b in self._buttons(self._detail()):
            if "detail-close" in (b.get("cls") or "").split():
                self.assertNotIn("locked", (b.get("cls") or "").split())
                self.assertFalse(b["disabled"])


class TheOwnerPillSurvivesGREYSCALE(unittest.TestCase):
    """B1 — ownership was encoded in COLOUR ALONE.

    amber = mine, blue = someone else's. Those two tokens differ by 1.52:1 in
    luminance, which is what a greyscale screenshot and a red-green colourblind
    reader both see. S191 established the better language one row down the same
    card: `.btn.locked` is HOLLOW/dashed where a live control is SOLID, measured
    at 9.07:1. This extends the SAME sentence to the owner pill — solid means
    you can act, hollow means you cannot — rather than inventing a second one.

    NOT THE PROOF, the tripwire: what a fill paints is a browser's answer.
    tests/drives/s190/owner-paint.sh desaturates the real screenshot and measures
    it, with a red control that puts the solid fill back.
    """

    CSS = os.path.normpath(os.path.join(HERE, "..", "static", "board.css"))

    def setUp(self):
        with open(self.CSS) as fh:
            raw = fh.read()
        # Comments stripped: this sheet quotes the broken shape it replaced in
        # the paragraph above every cured rule.
        import re as _re
        self.css = _re.sub(r"/\*.*?\*/", " ", raw, flags=_re.S)
        self.rules = _re.findall(
            r"\.card\.owned-by-other\s+\.owner\s*\{([^}]*)\}", self.css)

    def test_someone_elses_pill_is_HOLLOW(self):
        self.assertTrue(self.rules, "nothing styles someone else's owner pill")
        body = " ".join(self.rules).replace(" ", "").replace("\n", "")
        self.assertIn("--owner-fill:transparent", body,
                      "the pill went back to a solid fill — amber vs blue is "
                      "1.52:1 in greyscale and reads as one pill")

    def test_it_also_changes_its_EDGE(self):
        body = " ".join(self.rules).replace(" ", "").replace("\n", "")
        self.assertIn("--owner-edge:dashed", body)

    def test_MY_pill_is_still_SOLID(self):
        import re as _re
        base = _re.findall(r"(?<![-.\w])\.owner\s*\{([^}]*)\}", self.css)
        self.assertTrue(base, "the base .owner rule vanished")
        body = " ".join(base).replace(" ", "").replace("\n", "")
        self.assertIn("--owner-fill:var(--owner-col)", body)
        self.assertIn("--owner-edge:solid", body)

    def test_the_fill_and_the_edge_are_actually_CONSUMED(self):
        """A token nothing reads is a promise nothing keeps — which is exactly
        what `.det-head .owner` was (S190 D3)."""
        for prop in ("var(--owner-fill)", "var(--owner-edge)"):
            self.assertIn(prop, self.css,
                          "%s is declared and never used" % prop)

    def test_the_palette_is_NOT_forked(self):
        """ADR-007: one shared --lcars-* token source. Every colour here is a
        var() read, never a literal."""
        import re as _re
        for body in self.rules:
            for literal in _re.findall(r"#[0-9a-fA-F]{3,8}", body):
                self.assertRegex(
                    body, r"var\(--lcars-[a-z-]+,\s*" + literal,
                    "%s is a raw colour, not a token fallback" % literal)

    def test_the_dead_pill_closes_its_own_left_edge(self):
        """A pill whose avatar died keeps the handle ALONE (S164). Hollow, that
        handle is the only thing carrying the outline, so its left border has to
        come back or the pill paints with its nose cut off."""
        import re as _re
        rules = _re.findall(r"\.owner\.dead\s+\.owner-handle\s*\{([^}]*)\}",
                            self.css)
        self.assertTrue(rules)
        body = " ".join(rules).replace(" ", "")
        self.assertIn("border-left-width:1px", body)

    def test_the_REMOTE_card_does_not_also_speak_through_the_pill(self):
        """One channel, one fact. `remote` is carried by the ◈ pill, the violet
        edge and a control row that offers only Adopt; making the owner pill
        hollow for it too would make hollow mean two different things."""
        import re as _re
        self.assertFalse(
            _re.search(r"\.card\.remote[^{,]*\.owner\s*\{", self.css),
            "the remote card started restyling the owner pill")


class TheRemoteControlRowIsNotDIMMED(unittest.TestCase):
    """B2's cheap tripwire, and the S191 trap it is about.

    `.card.remote .card-ctrl button[disabled]{opacity:.7}` OUT-SPECIFIES
    `.btn.locked{opacity:1}` (0,4,1 against 0,2,0), so leaving it in place while
    adding the lock class would have painted every locked remote control at .7
    on a hollow fill and the cure would have been invisible — the same shape as
    S190's compositing-group defect, arrived at from the other direction.

    Deleting it is safe in exactly one direction and it is checked here:
    `.btn.locked{opacity:1}` must still sit BELOW `.btn[disabled]{opacity:.4}`,
    or the controls fall to .4 instead.
    """

    CSS = os.path.normpath(os.path.join(HERE, "..", "static", "board.css"))

    def setUp(self):
        import re as _re
        with open(self.CSS) as fh:
            self.css = _re.sub(r"/\*.*?\*/", " ", fh.read(), flags=_re.S)

    def test_no_opacity_rule_out_specifies_the_lock_on_a_remote_card(self):
        import re as _re
        for sel, body in _re.findall(r"([^{}]*\.card\.remote[^{}]*)\{([^}]*)\}",
                                     self.css):
            if "opacity" in body:
                self.fail("`%s` sets opacity and out-specifies .btn.locked"
                          % sel.strip())

    def test_the_lock_still_wins_its_tie_with_disabled(self):
        self.assertLess(self.css.index(".btn[disabled]"),
                        self.css.index(".btn.locked"))


# --------------------------------------------------------------------------
# 9. THE MISSION THAT SHIPPED FROM SOMEWHERE ELSE
#
# Found TWICE in one day by two independent two-laptop runs. Laptop B adopts a
# mission, drives it and merges it; laptop A — the one that FILED it — still
# shows the card at Verify offering a live `✓ Review PR ▸` for a pull request
# that merged minutes ago. LOCAL WINS (rule 1) is right for CONTENT and was
# being applied to TRUTH: the local card never learned the one fact the forge
# is authoritative about.
#
# A live control for a merged PR is the S191 D4 defect exactly — a lie the hand
# discovers — so the headline behaviour is: WITHDRAW THE AFFORDANCE AND SAY WHY.
#
# The information is already paid for. The overlay's ONE cached listing carries
# every `lcars:mission` issue's state and labels; the reconcile reads that same
# cache and costs NOTHING (S152 is proven below, not assumed).
# --------------------------------------------------------------------------
def local_verify(tmp, mid="m-local", issue_no=101):
    """A LOCAL mission parked at Verify with an OPEN PR — the exact card the
    two live runs found lying."""
    fx.plant_simple(tmp, mid, stage="verify", issue=issue_no,
                    pr_url="https://github.com/acme/repo/pull/7",
                    pr_number="7", review="open")


class TheLocalCardLearnsThatItShipped(unittest.TestCase):
    """The DAEMON half: one fact, taken from the listing already in hand."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        local_verify(self.tmp)

    def _board(self, rows, **kw):
        return LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record, **kw)).board()

    def _card(self, rows, mid="m-local", **kw):
        by = {}
        b = self._board(rows, **kw)
        for col in b["columns"].values():
            for c in col:
                by[c["id"]] = c
        return by.get(mid)

    # -- the headline ------------------------------------------------------
    def test_a_merged_mission_is_marked_shipped(self):
        """`lcars approve` relabels the issue `lcars:done`; the PR body's
        `Closes #n` closes it. Either alone is enough."""
        c = self._card([issue(101, stage="done", state="CLOSED")])
        self.assertIsNotNone(c)
        self.assertEqual("shipped", (c.get("shippedElsewhere") or {}).get("state"))

    def test_the_done_LABEL_alone_is_enough(self):
        """Stage truth from the LABEL (S191's ruling). An issue relabelled
        `lcars:done` whose close has not landed yet still shipped."""
        c = self._card([issue(101, stage="done", state="OPEN")])
        self.assertEqual("shipped", (c.get("shippedElsewhere") or {}).get("state"))

    def test_a_closed_issue_with_no_done_label_is_CLOSED_not_shipped(self):
        """A mission abandoned on the forge (issue closed at `lcars:implement`
        — there is one in this very repo) must not be reported as merged."""
        c = self._card([issue(101, stage="implement", state="CLOSED")])
        self.assertEqual("closed", (c.get("shippedElsewhere") or {}).get("state"))

    def test_the_block_carries_the_forge_stage_from_the_label(self):
        c = self._card([issue(101, stage="done", state="CLOSED")])
        self.assertEqual("done", c["shippedElsewhere"]["stage"])
        self.assertIs(True, c["shippedElsewhere"]["closed"])

    # -- the things that must NOT change ----------------------------------
    def test_a_mission_whose_issue_is_still_open_is_untouched(self):
        c = self._card([issue(101, stage="verify", state="OPEN")])
        self.assertNotIn("shippedElsewhere", c)

    def test_an_unreachable_forge_changes_nothing(self):
        """S190 D1's shape: rc read through a pipeline ERASED a good cache. A
        forge that did not answer must never look like a forge that said
        `shipped`."""
        c = self._card([issue(101, stage="done", state="CLOSED")], fail=True)
        self.assertNotIn("shippedElsewhere", c)

    def test_an_issue_absent_from_the_listing_changes_nothing(self):
        """Absence is not evidence. The listing is capped, so a mission beyond
        the cap is UNKNOWN, never shipped."""
        c = self._card([issue(999, stage="done", state="CLOSED")])
        self.assertNotIn("shippedElsewhere", c)

    def test_gh_absent_adds_no_key_at_all(self):
        missing = os.path.join(self.tmp, "definitely-not-gh")
        b = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=RemoteMissions(repo_root=self.tmp, gh_bin=missing)).board()
        for c in b["missions"]:
            self.assertNotIn("shippedElsewhere", c)

    def test_no_remote_reader_at_all_adds_no_key(self):
        b = LocalAdapter(self.tmp,
                         git_url_reader=lambda r: "git@x:acme/repo.git").board()
        for c in b["missions"]:
            self.assertNotIn("shippedElsewhere", c)

    def test_a_mission_already_done_LOCALLY_is_not_marked(self):
        shutil.rmtree(os.path.join(self.tmp, ".git", "lcars", "missions"))
        fx.plant_simple(self.tmp, "m-done", stage="done", issue=101)
        c = self._card([issue(101, stage="done", state="CLOSED")], mid="m-done")
        self.assertNotIn("shippedElsewhere", c)

    def test_the_shipped_issue_draws_NO_second_card(self):
        """S278 REPLACES HALF OF THIS PIN, by the captain's decision of
        2026-10-11. What it pinned was "a closed issue never draws a card",
        which was two claims wearing one assertion:

          * RULE 1, which is untouched and still pinned below: issue #101 IS the
            local mission, so it draws exactly ONE card — the local one. A
            shipped issue the captain holds locally never doubles.
          * "…and no closed issue draws a card AT ALL", which is the thing that
            left a fresh clone's Done column empty for 51 shipped missions.
            Issue #202 is NOT local, is CLOSED, and carries `lcars:done`: it is
            now drawn, read-only, from the forge.

        A CLOSED issue with no `lcars:done` is still not drawn — that half of
        the old pin is kept, in its own test below."""
        b = self._board([issue(101, stage="done", state="CLOSED"),
                         issue(202, stage="done", state="CLOSED",
                               closed_at="2026-09-10T10:00:00Z")])
        ids = [c["id"] for col in b["columns"].values() for c in col]
        self.assertEqual(["m-local", "202"], ids,
                         "local must win for #101, and #202 must reach Done")
        done = b["columns"]["done"]
        self.assertEqual([202], [c["issue"] for c in done])
        self.assertIs(True, done[0]["readOnly"])

    def test_an_OPEN_remote_mission_still_draws_its_card(self):
        b = self._board([issue(202, stage="implement", state="OPEN")])
        ids = [c["id"] for col in b["columns"].values() for c in col]
        self.assertIn("202", ids)

    # -- S152: the cost does not move -------------------------------------
    def test_it_costs_no_extra_forge_round_trip(self):
        clock = Clock()
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(101, stage="done", state="CLOSED")],
                          self.record, clock=clock, ttl=30.0))
        for _ in range(25):
            b = adapter.board()
        self.assertEqual(1, len(calls(self.record)),
                         "the reconcile bought a second listing")
        marked = [c for c in b["missions"] if c.get("shippedElsewhere")]
        self.assertEqual(1, len(marked), "…and it did not even work")

    def test_the_detail_learns_it_too(self):
        """The detail header offers the same `✓ Review PR` — one fact, both
        surfaces (BUG-049's rule)."""
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(101, stage="done", state="CLOSED")],
                          self.record))
        d = adapter.mission("m-local")
        self.assertEqual("shipped", (d.get("shippedElsewhere") or {}).get("state"))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheShippedElsewhereCard(unittest.TestCase):
    """The FRONT-END half: the board stops offering what cannot succeed."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        local_verify(self.tmp)

    def _card(self, rows):
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record))
        by = {}
        for col in adapter.board()["columns"].values():
            for c in col:
                by[c["id"]] = c
        return by["m-local"]

    def _dom(self, card):
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": ME}, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    @staticmethod
    def _walk(node, out=None):
        out = [] if out is None else out
        out.append(node)
        for kid in node.get("children", []):
            TheShippedElsewhereCard._walk(kid, out)
        return out

    def _buttons(self, dom):
        return [n for n in self._walk(dom)
                if (n.get("tag") or "").lower() == "button"]

    def _texts(self, dom):
        return [(n.get("text") or "") for n in self._walk(dom)]

    def _shipped(self):
        return self._dom(self._card([issue(101, stage="done", state="CLOSED")]))

    # -- THE HEADLINE ------------------------------------------------------
    def test_the_live_REVIEW_PR_control_is_gone(self):
        for t in self._texts(self._shipped()):
            self.assertNotIn("Review PR", t,
                             "the board still offers a merged PR for review")

    def test_the_control_row_holds_nothing_live(self):
        for b in self._buttons(self._shipped()):
            self.assertTrue(b["disabled"],
                            "a live control on a mission that already shipped: "
                            + repr(b.get("text")))

    def test_the_card_says_what_actually_happened(self):
        texts = " ".join(self._texts(self._shipped())).upper()
        self.assertIn("SHIPPED", texts)

    def test_a_closed_but_unshipped_mission_does_not_claim_a_merge(self):
        dom = self._dom(self._card([issue(101, stage="implement",
                                          state="CLOSED")]))
        joined = " ".join(self._texts(dom)).upper()
        self.assertIn("CLOSED", joined)
        self.assertNotIn("SHIPPED", joined)
        for b in self._buttons(dom):
            self.assertTrue(b["disabled"])

    # -- the negative control ---------------------------------------------
    def test_a_mission_whose_issue_is_open_keeps_its_live_control(self):
        dom = self._dom(self._card([issue(101, stage="verify", state="OPEN")]))
        live = [b for b in self._buttons(dom) if not b["disabled"]]
        self.assertTrue(live, "the cure withdrew a control it had no business "
                              "withdrawing")
        self.assertTrue(any("Review PR" in (b.get("text") or "")
                            for b in self._buttons(dom)))
        self.assertNotIn("shipped-elsewhere", dom["cls"])

    # -- legibility --------------------------------------------------------
    def test_it_is_legible_without_colour(self):
        """Solid = actionable, hollow/dashed = not. The card takes the state
        class the stylesheet draws dashed, and every dead control takes
        `.btn.locked` — both are SHAPE, not hue."""
        dom = self._shipped()
        self.assertIn("shipped-elsewhere", dom["cls"])
        for b in self._buttons(dom):
            self.assertIn("locked", " " + str(b.get("cls") or "") + " ")

    def test_every_dead_control_opens_with_the_lock_mark(self):
        for b in self._buttons(self._shipped()):
            t = (b.get("text") or "").strip()
            if t:
                self.assertEqual("⊘", t[0], repr(t))

    def test_every_dead_control_says_why(self):
        for b in self._buttons(self._shipped()):
            self.assertTrue(b["title"], "a locked control with no reason")
            self.assertIn("shipped", b["title"].lower())

    def test_no_glyph_from_outside_the_house_family(self):
        FAMILY = "▦▤▣▧▨▩◆◇◈●○◐▶▸▹✓⊹⌖⬢⬡⚡↩■⊘◷↻"
        for dom in (self._shipped(),
                    self._dom(self._card([issue(101, stage="implement",
                                                state="CLOSED")]))):
            for n in self._walk(dom):
                t = (n.get("text") or "").strip()
                if not t:
                    continue
                if "SHIPPED" in t.upper() or "CLOSED" in t.upper():
                    self.assertIn(t[0], FAMILY,
                                  "%r opens with an off-family glyph" % t)

    def test_the_stylesheet_draws_the_state_without_colour(self):
        with open(os.path.join(HERE, "..", "static", "board.css")) as fh:
            css = fh.read()
        import re as _re
        bodies = [b for s, b in
                  _re.findall(r"([^{}]*\.shipped[^{}]*)\{([^}]*)\}", css)]
        self.assertTrue(bodies, "no .shipped rule in the stylesheet")
        self.assertTrue(any("dashed" in b for b in bodies),
                        "the shipped state is carried by colour alone")


if __name__ == "__main__":
    unittest.main()


# ==========================================================================
# S197 — A WITHDRAWN CONTROL IS NOT A LOCK.
#
# S196's last round taught the FILING laptop that its mission had merged on the
# other machine and WITHDREW the `✓ Review PR ▸` it had gone on offering for a
# pull request that closed minutes earlier. It left the daemon ACCEPTING a POST
# to that very verb, and said so in its own commit message:
#
#     "No daemon-side 403 yet: the write endpoints live in server.py, outside
#      this change's fence. A POST to /verify on a shipped mission is still
#      accepted. The shape to copy is `_remote_gate` at server.py:693.
#      LEDGERED — and it matters, because S190's own lesson is that a disabled
#      button is not a lock."
#
# This is that ledger item. Everything here BYPASSES THE DOM and POSTs straight
# at the daemon, exactly the way anyone with the port number can.
# ==========================================================================
SHIPPED_LINE = ("already shipped from another machine — its pull request "
                "is merged")
CLOSED_LINE = ("already closed on the forge from another machine — nothing "
               "here can act on it")


class _ShippedBase(_EndpointBase):
    """One LOCAL mission at verify whose issue the forge says is finished.

    IDENTICAL ON DISK to a mission that is still live — that is the design of
    the fixture, and the same one the pixel rig uses. The only difference is
    what the forge says about issue 106, so anything that changes IS the cure
    and nothing else can be.
    """

    VERBS = [("start", {}), ("pause", {}), ("resume", {}),
             ("verify", {"decision": "approve"}), ("respond", {"answer": "x"}),
             ("reapprove", {}), ("log", {"text": "x"})]

    def build(self, rows, fail=False):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.dispatched = os.path.join(self.tmp, "dispatched.txt")
        stub = _adopt_stub(self.tmp, "any.sh",
                           'printf "%s\\n" "$*" >> "' + self.dispatched + '"\n'
                           'exit 0\n')
        scripts = dict((k, stub) for k in
                       ("run", "pause", "respond", "approve", "feedback",
                        "log", "resolve", "adopt"))
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        # THE MISSION THAT SHIPPED ELSEWHERE, and a live one beside it as the
        # negative control — same stage, same PR, same everything on disk.
        fx.plant_simple(self.tmp, "m-shipped", stage="verify", issue=106,
                        pr_url="https://github.com/acme/repo/pull/9",
                        pr_number="9", review="open")
        fx.plant_simple(self.tmp, "m-live", stage="verify", issue=107,
                        pr_url="https://github.com/acme/repo/pull/10",
                        pr_number="10", review="open")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record, fail=fail))
        self.serve(adapter, actions)


class AShippedMissionRefusesEveryWrite(_ShippedBase):
    def setUp(self):
        self.build([issue(106, stage="done", state="CLOSED")])

    def test_every_write_verb_is_refused(self):
        for verb, body in self.VERBS:
            status, _ = self.post("/api/mission/m-shipped/%s" % verb, body)
            self.assertEqual(409, status,
                             "%s was accepted on a mission that already "
                             "shipped" % verb)

    def test_the_refusal_is_the_SAME_SENTENCE_the_card_carries(self):
        for verb, body in self.VERBS:
            _, payload = self.post("/api/mission/m-shipped/%s" % verb, body)
            self.assertEqual(SHIPPED_LINE, payload.get("error"), verb)

    def test_nothing_is_dispatched_behind_the_refusal(self):
        for verb, body in self.VERBS:
            self.post("/api/mission/m-shipped/%s" % verb, body)
        self.assertEqual([], calls(self.dispatched))

    def test_a_LIVE_mission_on_the_same_daemon_is_untouched(self):
        status, _ = self.post("/api/mission/m-live/verify",
                              {"decision": "approve"})
        self.assertEqual(200, status)

    def test_the_card_and_the_daemon_carry_ONE_sentence_not_two(self):
        """Byte-identical, read out of the SHIPPING files on both sides.

        The tooltip on the withdrawn control and the body of the refusal a
        click past it earns are the same bytes, or the captain is told two
        different things about one fact (S190's rule, S191's idiom)."""
        with open(os.path.join(HERE, "..", "static", "board.js")) as fh:
            js = fh.read()
        self.assertIn('"%s"' % SHIPPED_LINE, js,
                      "board.js no longer carries the shipped sentence")
        self.assertIn('"%s"' % CLOSED_LINE, js,
                      "board.js no longer carries the closed sentence")
        from lcars_serve import server as srv
        self.assertEqual(SHIPPED_LINE, srv._SHIPPED_LOCK_LINE)
        self.assertEqual(CLOSED_LINE, srv._CLOSED_LOCK_LINE)


class AClosedMissionSaysCLOSEDNotSHIPPED(_ShippedBase):
    """Two verdicts, because they are two facts and only one is a merge."""

    def setUp(self):
        self.build([issue(106, stage="implement", state="CLOSED")])

    def test_the_write_is_refused(self):
        status, _ = self.post("/api/mission/m-shipped/verify",
                              {"decision": "approve"})
        self.assertEqual(409, status)

    def test_with_the_sentence_that_does_not_claim_a_merge(self):
        _, payload = self.post("/api/mission/m-shipped/verify",
                               {"decision": "approve"})
        self.assertEqual(CLOSED_LINE, payload.get("error"))


class AnUnreachableForgeNEVERLocks(_ShippedBase):
    """S190's D1, preserved. A forge that did not answer must never read as a
    forge that said "over" — otherwise a flaky network becomes a frozen board.
    """

    def setUp(self):
        self.build([issue(106, stage="done", state="CLOSED")], fail=True)

    def test_the_verb_proceeds_when_the_listing_failed(self):
        for verb, body in self.VERBS:
            if verb == "log":
                continue        # a preview does real work; see the OPEN case
            status, _ = self.post("/api/mission/m-shipped/%s" % verb, body)
            self.assertNotEqual(409, status,
                                "a forge that did not answer locked %s" % verb)
            self.assertEqual(200, status, verb)


class AnOPENIssueChangesNothing(_ShippedBase):
    """The ordinary case, which is every mission: still open, still writable."""

    def setUp(self):
        self.build([issue(106, stage="verify", state="OPEN")])

    def test_a_normal_mission_is_unaffected(self):
        # `log` is left out of the positive set and only out of it: it is a
        # PREVIEW that does real work (it reads the repo and drafts PRDs), so
        # a 502 from it on a bare tmp tree says nothing about this gate. Every
        # negative assertion above still covers it — the point there is that it
        # never reaches its own machinery at all.
        for verb, body in self.VERBS:
            if verb == "log":
                continue
            status, _ = self.post("/api/mission/m-shipped/%s" % verb, body)
            self.assertEqual(200, status, verb)


class TheGateBuysNoForgeRoundTrip(_ShippedBase):
    """S152 — the verdict rides the SAME cached listing the board was built
    from. Counted off the stub's argv log, not asserted in prose."""

    def setUp(self):
        self.build([issue(106, stage="done", state="CLOSED")])

    def test_twelve_refused_posts_cost_one_gh_invocation(self):
        for _ in range(12):
            self.post("/api/mission/m-shipped/verify", {"decision": "approve"})
        self.assertEqual(1, len(calls(self.record)))


# ==========================================================================
# S278 — DONE MISSIONS REACH A NEW LAPTOP.
#
# THE GAP. The Done column is filled from LOCAL state only (board.assemble
# routes by `stage`; local_adapter._mission_dirs returns [] when
# `.git/lcars/missions` does not exist, which is EVERY fresh clone). So the
# laptop that clones a repo with 51 shipped missions sees an empty Done column
# and no evidence the factory ever shipped anything.
#
# The listing this module already takes was ALREADY asking for them —
# `--state all --label lcars:mission` — and then threw every closed row away
# one line later. This is that half of the window, spent.
#
# THE ONE DISTINCTION THAT MATTERS. `lcars:done` is applied by `lcars approve`
# at the ship and nowhere else, so a CLOSED issue carrying it SHIPPED, and a
# CLOSED issue without it was ABANDONED. Measured read-only on acme/widget
# (2026-10-11): 54 mission issues, all closed, 51 with the label and 3 without.
# Those 3 are not history to be proud of and they are not drawn.
# ==========================================================================
def fresh_clone(tmp):
    """A clone with NO `.git/lcars/missions` at all — the condition every
    single one of these tests is about, and the one the local board has no
    answer for. `.git/lcars/` carries a config and nothing else, exactly as
    `~/Projects/widget` does today (it holds only `cache/`)."""
    os.makedirs(os.path.join(tmp, ".git", "lcars"), exist_ok=True)
    with open(os.path.join(tmp, ".git", "lcars", "config.json"), "w") as fh:
        fh.write('{"projectName": "repo", "testCommand": "true"}\n')
    return tmp


def done_row(number, closed_at, title=None, labels=(), body=None):
    """One SHIPPED mission as the forge reports it: closed, `lcars:done`, and
    carrying the `closedAt` stamp gh emits for every closed issue."""
    return issue(number, stage="done", state="CLOSED", closed_at=closed_at,
                 title=title, labels=labels, body=body)


class TheDoneColumnIsFilledFromTheForge(unittest.TestCase):
    """Behaviour 1-4: the fresh clone's Done column, built from the listing
    the overlay was already paying for."""

    def setUp(self):
        self.tmp = fresh_clone(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _board(self, rows, **kw):
        return LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record, **kw)).board()

    # -- behaviour 1 -------------------------------------------------------
    def test_two_shipped_missions_draw_two_read_only_done_cards(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z", title="first"),
                         done_row(31, "2026-09-20T09:00:00Z", title="second")])
        done = b["columns"]["done"]
        self.assertEqual(2, len(done), "the fresh clone's Done column is empty")
        for c in done:
            self.assertIs(True, c["remote"])
            self.assertIs(True, c["readOnly"])
            self.assertEqual("done", c["stage"])

    def test_the_newest_ship_is_first(self):
        """Newest-first, by the date the mission actually SHIPPED — not by
        issue number, which is the order it was FILED in."""
        b = self._board([done_row(99, "2026-01-02T09:00:00Z"),
                         done_row(14, "2026-09-20T09:00:00Z"),
                         done_row(31, "2026-05-05T09:00:00Z")])
        self.assertEqual([14, 31, 99],
                         [c["issue"] for c in b["columns"]["done"]])

    def test_each_card_carries_title_type_and_closed_date(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z", title="dark mode"),
                         done_row(15, "2026-08-01T09:00:00Z", title="a crash",
                                  labels=("lcars:bug",))])
        by = {c["issue"]: c for c in b["columns"]["done"]}
        self.assertEqual("dark mode", by[14]["title"])
        self.assertEqual("feature", by[14]["type"])
        self.assertEqual("2026-09-01T09:00:00Z", by[14]["closedAt"])
        self.assertEqual("a crash", by[15]["title"])
        self.assertEqual("bug", by[15]["type"])

    def test_each_card_links_to_its_issue_on_the_configured_host(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z")])
        self.assertEqual("https://github.com/acme/repo/issues/14",
                         b["columns"]["done"][0]["url"])

    def test_the_active_mission_list_is_empty(self):
        """`board.missions` backs the footer's "N active missions". A shipped
        mission is not active and must not inflate it."""
        b = self._board([done_row(14, "2026-09-01T09:00:00Z"),
                         done_row(31, "2026-09-20T09:00:00Z")])
        self.assertEqual([], b["missions"])

    def test_the_card_carries_the_envelope_mission_id_when_there_is_one(self):
        env = ('<!-- lcars:handoff v1 {"id":"lcars-20260901-003",'
               '"branch":"lcars/x","base":"main","type":"feature",'
               '"engine":"claude","parentIssue":null,"attachments":0} -->')
        b = self._board([done_row(14, "2026-09-01T09:00:00Z",
                                  body="shipped.\n\n" + env)])
        self.assertEqual("lcars-20260901-003", b["columns"]["done"][0]["id"])

    def test_a_body_with_no_envelope_falls_back_to_the_issue_number(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z")])
        self.assertEqual("14", b["columns"]["done"][0]["id"])

    def test_the_estimate_pills_the_body_carries_still_ride(self):
        body = ("## Estimate\n\n"
                "| Cost | Reasoning | Implementation |\n"
                "|---|---|---|\n"
                "| $0.40-$0.90 | medium | high |\n")
        b = self._board([done_row(14, "2026-09-01T09:00:00Z", body=body)])
        self.assertTrue(b["columns"]["done"][0]["pills"]["cost"])

    # -- behaviour 2: the half of the old pin that is KEPT -----------------
    def test_a_closed_issue_with_no_done_label_is_NOT_drawn(self):
        """It was ABANDONED, not shipped. There are three of them in
        acme/widget and the Done column must not claim them."""
        b = self._board([issue(77, stage="implement", state="CLOSED",
                               closed_at="2026-09-01T09:00:00Z")])
        self.assertEqual([], b["columns"]["done"])
        self.assertEqual([], b["columns"]["implement"])
        self.assertEqual([], b["missions"])

    def test_an_open_mission_still_draws_its_ordinary_remote_card(self):
        b = self._board([issue(202, stage="implement", state="OPEN"),
                         done_row(14, "2026-09-01T09:00:00Z")])
        self.assertEqual([202], [c["issue"] for c in b["columns"]["implement"]])
        self.assertEqual([14], [c["issue"] for c in b["columns"]["done"]])

    def test_a_row_with_no_closedAt_still_draws_last_rather_than_vanishing(self):
        """A forge is not a promise: a gh too old to emit `closedAt`, or a row
        that lost it, must cost the card its PLACE in the order and never the
        card itself."""
        b = self._board([done_row(14, None), done_row(31, "2026-09-20T09:00:00Z")])
        self.assertEqual([31, 14], [c["issue"] for c in b["columns"]["done"]])

    # -- behaviour 5: the cap ---------------------------------------------
    def test_a_full_listing_says_the_column_is_truncated(self):
        rows = [done_row(n, "2026-09-%02dT09:00:00Z" % ((n % 28) + 1))
                for n in range(1, 201)]
        self.assertEqual(200, len(rows))
        self.assertIs(True, self._board(rows)["meta"]["doneTruncated"])

    def test_one_row_short_of_the_cap_says_nothing_at_all(self):
        rows = [done_row(n, "2026-09-%02dT09:00:00Z" % ((n % 28) + 1))
                for n in range(1, 200)]
        self.assertEqual(199, len(rows))
        self.assertNotIn("doneTruncated", self._board(rows)["meta"])

    def test_an_empty_listing_says_nothing_at_all(self):
        self.assertNotIn("doneTruncated", self._board([])["meta"])

    # -- the overlay's own guarantees, on the new path ---------------------
    def test_gh_absent_draws_no_done_cards_and_adds_no_key(self):
        missing = os.path.join(self.tmp, "definitely-not-gh")
        b = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=RemoteMissions(repo_root=self.tmp, gh_bin=missing)).board()
        self.assertEqual([], b["columns"]["done"])
        self.assertNotIn("remote", b["meta"])
        self.assertNotIn("doneTruncated", b["meta"])

    def test_an_unreachable_forge_draws_no_done_cards(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z")], fail=True)
        self.assertEqual([], b["columns"]["done"])

    def test_the_done_column_costs_no_extra_forge_round_trip(self):
        clock = Clock()
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [done_row(14, "2026-09-01T09:00:00Z")],
                          self.record, clock=clock, ttl=30.0))
        for _ in range(25):
            b = adapter.board()
        self.assertEqual(1, len(calls(self.record)),
                         "the Done column bought a second listing")
        self.assertEqual(1, len(b["columns"]["done"]))

    def test_a_done_card_opens_no_detail(self):
        """There is no `/api/mission/<id>` for it — the card opens the ISSUE.
        A detail that answered here would be a window onto artifacts this
        laptop has never had."""
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [done_row(14, "2026-09-01T09:00:00Z")],
                          self.record))
        self.assertIsNone(adapter.mission("14"))

    def test_a_done_card_is_never_adoptable(self):
        b = self._board([done_row(14, "2026-09-01T09:00:00Z")])
        c = b["columns"]["done"][0]
        self.assertFalse(c["adoptable"])
        self.assertNotIn("enginesHere", c)


class ALocalDoneMissionStillWins(unittest.TestCase):
    """Behaviour 4 + behaviour 3: the dedupe key is the ISSUE NUMBER and
    nothing else (rule 1), and it is the same key the verdict path uses."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _board(self, rows):
        return LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, rows, self.record)).board()

    def test_a_locally_done_mission_draws_exactly_one_card(self):
        fx.plant_simple(self.tmp, "m-done", stage="done", issue=101)
        b = self._board([done_row(101, "2026-09-01T09:00:00Z")])
        self.assertEqual(["m-done"], [c["id"] for c in b["columns"]["done"]])

    def test_the_local_card_is_the_one_that_survives(self):
        fx.plant_simple(self.tmp, "m-done", stage="done", issue=101,
                        title="the local title")
        b = self._board([done_row(101, "2026-09-01T09:00:00Z",
                                  title="the forge title")])
        c = b["columns"]["done"][0]
        self.assertEqual("the local title", c["title"])
        self.assertNotIn("readOnly", c)

    def test_local_done_cards_come_before_remote_ones(self):
        """They are THIS laptop's — the captain's own work reads first."""
        fx.plant_simple(self.tmp, "m-mine", stage="done", issue=101)
        b = self._board([done_row(500, "2026-09-30T09:00:00Z")])
        self.assertEqual(["m-mine", "500"],
                         [c["id"] for c in b["columns"]["done"]])

    def test_an_OPEN_done_labelled_issue_is_still_only_a_verdict(self):
        """Behaviour 3. `lcars approve` relabels before the merge closes the
        issue, so there is a window where the issue is OPEN and `lcars:done`.
        The LOCAL card learns it shipped; no second card appears."""
        local_verify(self.tmp)
        b = self._board([issue(101, stage="done", state="OPEN")])
        cards = [c for col in b["columns"].values() for c in col]
        self.assertEqual(["m-local"], [c["id"] for c in cards])
        self.assertEqual("shipped", cards[0]["shippedElsewhere"]["state"])
        self.assertEqual([], b["columns"]["done"],
                         "an open issue drew a Done card")


# --------------------------------------------------------------------------
# S278 — THE FRONT-END HALF. The Done column as render() actually builds it.
#
# These drive the SHIPPING board.js through `render(board)` — never a builder
# called by hand — because the two things being asserted only exist inside that
# loop: the card the Done column paints, and the "+ more on GitHub" row that is
# appended after the last card in it.
#
# WHAT THEY CANNOT SEE, said plainly: there is no CSS and no browser here, so
# "no live control on this card" and "the click reaches the issue" are proven,
# and "the Done column LOOKS right" is not. That is the tester's, in real
# Chrome, against the real daemon.
# --------------------------------------------------------------------------
GHLINKS_HARNESS = os.path.join(HERE, "board_ghlinks_harness.js")

DONE_REMOTE = {
    "id": "31", "issue": 31, "title": "Dark mode", "type": "feature",
    "stage": "done", "awaiting": False, "paused": False, "running": False,
    "dispatched": False, "queued": False, "linked": False, "tickets": [],
    "pills": {}, "progress": {}, "remote": True, "readOnly": True,
    "adoptable": False, "closedAt": "2026-09-20T09:00:00Z",
    "url": "https://enterprise.example.com/acme/widget/issues/31",
}
DONE_LOCAL = {
    "id": "m-mine", "issue": 12, "title": "A mission I shipped here",
    "type": "feature", "stage": "done", "awaiting": False, "paused": False,
    "running": False, "dispatched": False, "queued": False, "linked": False,
    "tickets": [], "pills": {}, "progress": {},
}


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheDoneColumnAsRenderBuildsIt(unittest.TestCase):

    def _render(self, done_cards, meta=None, click=None, open_detail=None):
        m = {"repo": "acme/widget", "adapter": "local",
             "mode": "read-write", "ghHost": "enterprise.example.com"}
        m.update(meta or {})
        spec = {
            "mission": DONE_REMOTE,
            "board": {"stages": ["done"], "columns": {"done": done_cards},
                      "missions": [], "meta": m},
        }
        if click:
            spec["clickCard"] = click
        if open_detail:
            spec["openDetail"] = open_detail
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump(spec, fh)
        out = subprocess.run([NODE, GHLINKS_HARNESS, p, "board"],
                             capture_output=True, text=True, check=True)
        data = json.loads(out.stdout)
        self.assertFalse(data["bootErrors"], data["bootErrors"])
        return data

    @staticmethod
    def _walk(node, out=None):
        out = [] if out is None else out
        if not node:
            return out
        out.append(node)
        for kid in node.get("children", []):
            TheDoneColumnAsRenderBuildsIt._walk(kid, out)
        return out

    def _nodes(self, data):
        return self._walk(data["tree"])

    def _card(self, data, mid):
        for n in self._nodes(data):
            if (n.get("attrs") or {}).get("data-mid") == mid:
                return n
        return None

    # -- behaviour 6 -------------------------------------------------------
    def test_a_remote_done_card_renders_no_controls_at_all(self):
        card = self._card(self._render([DONE_REMOTE]), "31")
        self.assertIsNotNone(card, "render() drew no card for the done mission")
        btns = [n for n in self._walk(card)
                if (n.get("tag") or "").lower() == "button"]
        self.assertEqual([], btns,
                         "a control on a mission that shipped elsewhere: "
                         + repr([b.get("text") for b in btns]))

    def test_CONTROL_this_harness_can_see_a_button_when_there_is_one(self):
        """The negative control the "no controls" test above is worthless
        without. A remote card at VERIFY offers exactly one live affordance —
        Adopt — and if the projection could not see that, "no buttons on a done
        card" would be a fact about the harness and not about the product."""
        live = dict(DONE_REMOTE, id="77", issue=77, stage="verify",
                    readOnly=False, adoptable=True, closedAt=None)
        card = self._card(self._render([live]), "77")
        btns = [n for n in self._walk(card)
                if (n.get("tag") or "").lower() == "button"]
        self.assertTrue(btns, "the harness cannot see buttons at all")
        self.assertTrue(any("Adopt" in (b.get("text") or "") for b in btns),
                        repr([b.get("text") for b in btns]))

    def test_no_RUN_approve_or_feedback_label_appears_on_it(self):
        card = self._card(self._render([DONE_REMOTE]), "31")
        joined = " ".join(n.get("text") or "" for n in self._walk(card)).upper()
        for banned in ("RUN", "APPROVE", "FEEDBACK", "START", "ADOPT",
                       "REVIEW PR"):
            self.assertNotIn(banned, joined, banned)

    # -- behaviour 4 of the brief: the shipped line ------------------------
    def test_it_says_when_it_shipped(self):
        card = self._card(self._render([DONE_REMOTE]), "31")
        line = [n.get("text") or "" for n in self._walk(card)
                if (n.get("text") or "").startswith("⧗")]
        self.assertTrue(line, "no ⧗ shipped line on the card")
        self.assertIn("2026-09-20", line[0])

    def test_the_click_opens_the_issue_in_a_new_tab(self):
        data = self._render([DONE_REMOTE], click="31")
        self.assertEqual(
            [{"url": "https://enterprise.example.com/acme/widget/issues/31",
              "target": "_blank", "features": "noopener"}],
            data["opened"])

    def test_the_KEYBOARD_opens_the_issue_too(self):
        """The command deck's Enter resolves a `data-mid` and calls openDetail
        directly — it never reaches the card's click handler. A cure that lived
        in cardNode would have left Enter opening onto "no such mission"."""
        data = self._render([DONE_REMOTE], open_detail="31")
        self.assertEqual(
            ["https://enterprise.example.com/acme/widget/issues/31"],
            [o["url"] for o in data["opened"]])

    def test_a_done_card_with_no_resolvable_link_opens_nothing(self):
        """The daemon omits `url` when the repo identity did not resolve
        (absent, never wrong). Doing nothing beats navigating to a 404."""
        card = dict(DONE_REMOTE)
        del card["url"]
        data = self._render([card], click="31", open_detail="31")
        self.assertEqual([], data["opened"])

    def test_a_LOCAL_done_card_still_opens_its_detail_and_not_a_tab(self):
        """The negative control. A local done mission HAS a detail, and the
        cure must not have taken it away."""
        data = self._render([DONE_LOCAL], click="m-mine")
        self.assertEqual([], data["opened"])

    # -- behaviour 5: the "+ more" row -------------------------------------
    def test_a_truncated_column_offers_the_rest_on_github(self):
        data = self._render([DONE_REMOTE], meta={"doneTruncated": True})
        texts = [n.get("text") or "" for n in self._nodes(data)]
        self.assertTrue(any("more on GitHub" in t for t in texts),
                        "nothing told the captain the column is capped")
        hrefs = [h["href"] for h in data["hrefs"]]
        self.assertIn(
            "https://enterprise.example.com/acme/widget/issues?q="
            "is%3Aclosed+label%3Alcars%3Adone+label%3Alcars%3Amission",
            hrefs)

    def test_an_untruncated_column_offers_nothing(self):
        data = self._render([DONE_REMOTE])
        texts = [n.get("text") or "" for n in self._nodes(data)]
        self.assertFalse([t for t in texts if "more on GitHub" in t])

    def _done_head_count(self, data):
        for n in self._nodes(data):
            if "col-head" not in (n.get("cls") or ""):
                continue
            kids = n.get("children") or []
            if not any((k.get("text") or "") == "Done" for k in kids):
                continue
            for k in kids:
                if "ct" in (k.get("cls") or "").split():
                    return k.get("text")
        return None

    def test_the_more_row_is_not_counted_as_a_card(self):
        """The column head counts CARDS. A navigation row is not one."""
        self.assertEqual("1", self._done_head_count(
            self._render([DONE_REMOTE], meta={"doneTruncated": True})))
        self.assertEqual("1", self._done_head_count(
            self._render([DONE_REMOTE])))


# --------------------------------------------------------------------------
# S278 FIX ROUND 1 — THE TWO THINGS A BOARD WITH CARDS AND NO ACTIVE WORK GOT
# WRONG.
#
# Both were S278's own, and both are the same shape: filling the Done column
# from the forge made "cards on the board" and "missions still in flight" two
# different numbers for the first time, and two surfaces were still asking the
# second question while answering the first.
#
#   D1  The first-run banner — "NO MISSIONS ON THE BOARD / File the first one"
#       — keyed off the ACTIVE list, which is legitimately 0 on a fresh clone of
#       a repo that has shipped everything it ever filed. It printed directly
#       above a Done column headed 51 and full of cards.
#
#   D2  A read-only Done card drew `⊙ READ THE FULL REPORT →` whenever the
#       mission carried a Number One verdict. There is no local detail for such
#       a card (openDetail sends it to the issue instead), so the control was a
#       prominent promise the card cannot keep — plus a Tab stop.
#
# Each has a NEGATIVE CONTROL beside it, because "the banner is hidden" and "the
# button is gone" are both satisfied by a harness that can see neither.
# --------------------------------------------------------------------------
DONE_REMOTE_SCORED = dict(
    DONE_REMOTE, id="41", issue=41, title="A mission Number One graded",
    url="https://enterprise.example.com/acme/widget/issues/41",
    numberOne={"status": "finished", "score": "low",
               "meaning": "the primary flow was never exercised"},
)



class _DoneBoardHelpers:
    """The four helpers both fix-round classes below need, BORROWED from
    `TheDoneColumnAsRenderBuildsIt` rather than inherited: subclassing a
    TestCase re-collects every one of its twelve tests under each new name, so
    the suite's own count would stop meaning anything."""
    _render = TheDoneColumnAsRenderBuildsIt._render
    _walk = staticmethod(TheDoneColumnAsRenderBuildsIt._walk)
    _nodes = TheDoneColumnAsRenderBuildsIt._nodes
    _card = TheDoneColumnAsRenderBuildsIt._card

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheFirstRunBannerAsksWhetherTheBoardIsEmpty(
        _DoneBoardHelpers, unittest.TestCase):
    """D1. The question is "does this board have any cards, in any column?" —
    NOT "is there any active work?". Those were the same question until S278
    gave a clone a Done column it had never driven."""

    def test_the_banner_is_HIDDEN_when_a_column_has_cards_and_none_are_active(
            self):
        data = self._render([DONE_REMOTE, DONE_REMOTE_SCORED])
        self.assertEqual(
            True, data["emptyState"]["hidden"],
            "the board told the captain to file his first mission directly "
            "above " + str(len(data["emptyState"]["text"])) + " chars of "
            "banner over two drawn cards: "
            + repr(data["emptyState"]["text"]))

    def test_CONTROL_a_board_with_no_cards_ANYWHERE_still_teaches_itself(self):
        """Without this, "the banner is hidden" is a fact about the harness."""
        data = self._render([])
        self.assertEqual(False, data["emptyState"]["hidden"],
                         "a genuinely cold board stopped teaching itself")
        self.assertIn("NO MISSIONS ON THE BOARD", data["emptyState"]["text"])


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ARemoteDoneCardPromisesNoReportItCannotOpen(
        _DoneBoardHelpers, unittest.TestCase):
    """D2. The VERDICT stays — it is a fact the forge's labels carry and it is
    worth a glance. The ROUTE TO A REPORT goes, because there is no report at
    the end of it: `openDetail` sends a remote done card to its GitHub issue."""

    def test_it_renders_no_read_the_full_report_button(self):
        card = self._card(self._render([DONE_REMOTE_SCORED]), "41")
        self.assertIsNotNone(card, "render() drew no card for the done mission")
        btns = [n for n in self._walk(card)
                if (n.get("tag") or "").lower() == "button"]
        self.assertEqual([], btns,
                         "a control on a read-only done card: "
                         + repr([b.get("text") for b in btns]))

    def test_it_carries_no_data_act_control_of_any_kind(self):
        """The generic form of the claim. `data-act` is the product's own
        machine-readable name for "this node is a control", so a future branch
        that adds another one to a done card fails here too."""
        card = self._card(self._render([DONE_REMOTE_SCORED]), "41")
        acts = [(n.get("attrs") or {}).get("data-act")
                for n in self._walk(card)
                if (n.get("attrs") or {}).get("data-act")]
        self.assertEqual([], acts, repr(acts))

    def test_the_VERDICT_is_still_on_the_card(self):
        """Suppressing the button must not suppress the grade. (a), not (b)."""
        card = self._card(self._render([DONE_REMOTE_SCORED]), "41")
        texts = [n.get("text") or "" for n in self._walk(card)]
        self.assertTrue(any("NUMBER ONE" in t and "LOW" in t for t in texts),
                        "the grade went with the button: " + repr(texts))

    def test_CONTROL_a_LOCAL_done_card_KEEPS_its_report_button(self):
        """The negative control, and the scope of the cure. A mission this
        laptop drove HAS a Number One report on disk, and the button opens it.
        If this went red the cure would have reached past the remote cards."""
        local = dict(DONE_LOCAL, numberOne=DONE_REMOTE_SCORED["numberOne"])
        card = self._card(self._render([local]), "m-mine")
        labels = [n.get("text") or "" for n in self._walk(card)
                  if (n.get("tag") or "").lower() == "button"]
        self.assertTrue(any("Read the full report" in t for t in labels),
                        "the harness cannot see the button at all: "
                        + repr(labels))
