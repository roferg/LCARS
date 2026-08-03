"""S161 — the Mission-Log console reads the DAEMON's session (client half).

Drives the SHIPPING `openLog(id)` in a node vm (board_logsession_harness.js) with
a scripted daemon, and asserts the console:
  * asks for the session on open, and RESTORES the authored bugs the daemon holds
    (a reopened console never re-runs the split worker);
  * files by `sessionId` — not by shipping the PRDs back up;
  * shows an in-flight filing as in-flight, and a failed one with its reason;
  * on a SHORTFALL shows the authored text of the bugs that did not reach disk and
    offers File as a retry of exactly those (S161 fix round 2, N1);
  * reveals "Go ▸" only once the bugs are filed, and NEVER auto-dispatches it
    (BUG-059's hold, client side);
  * disables its write controls on a view-only build.

S162 changed one thing here and left the rest: the File control is now
"File & Cost" and CLOSES the console on dispatch, handing the captain the parent
card's ◐ FILING & COSTING band (LogConsoleFileAndCostTest). Everything above still
holds — reopening restores the very session it left, in flight or finished, so
closing became the default rather than a risk.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_logsession_harness.js")
NODE = shutil.which("node")

# S162 — the File control's name. It DISPATCHES the filing (the estimator runs
# once per bug, server-side) and hands the captain the parent card, so the label
# says what the click costs them. Named once here, because these tests both find
# the control by it and assert it.
FILE_LABEL = "File & Cost"

MISSION = {"id": "m-001", "issue": 142, "stage": "verify", "type": "feature",
           "title": "Add Gamification to Course Site"}

PREVIEW_CHILD_A = {"title": "XP not awarded on video completion", "type": "bug",
                   "prd": "# Mission: XP not awarded\n\nbody a\n",
                   "images": [], "imageRefs": []}
PREVIEW_CHILD_B = {"title": "Leaderboard flicker", "type": "bug",
                   "prd": "# Mission: Leaderboard flicker\n\nbody b\n",
                   "images": [], "imageRefs": []}

FILED_CHILD_A = {"id": "m-bug1", "issue": 301, "title": "XP not awarded",
                 "stage": "plan", "type": "bug",
                 "pills": {"cost": {"text": "$1–2", "level": "low"},
                           "reasoning": {"text": "R low", "level": "low"},
                           "implementation": {"text": "I med", "level": "med"}},
                 "modelMix": [{"stage": "plan", "model": "sonnet"}]}


def _drive(mode, payload, readonly=False):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(payload, fh)
    try:
        argv = [NODE, HARNESS, mode, path]
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


def _buttons(res):
    return [n for n in _flatten(res["node"]) if n["tag"] == "button"]


def _button(res, label):
    for b in _buttons(res):
        if b["text"] == label:
            return b
    return None


def _texts(res):
    return [n["text"] for n in _flatten(res["node"]) if n["text"]]


def _values(res):
    """Every field VALUE in the console — where a textarea's body lives."""
    return [n["value"] for n in _flatten(res["node"]) if n["value"]]


def _by_cls(res, cls):
    for n in _flatten(res["node"]):
        if cls in (n["cls"] or "").split():
            return n
    return None


def _foot_file(res):
    """The footer's File control BY POSITION — at `partial` its label is part of
    what we assert, so it must not be found by text. Footer: [dismiss, Preview,
    File, Go ▸]."""
    return res["node"]["children"][2]["children"][2]


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleRestoreTest(unittest.TestCase):
    def test_console_asks_the_daemon_for_a_session_on_open(self):
        res = _drive("open", {"mission": MISSION, "session": None})
        urls = [f["url"] for f in res["fetches"]]
        self.assertIn("/api/mission/m-001/log/session", urls)
        # and it is a READ — nothing is posted just by opening the console.
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [])

    def test_no_session_opens_a_fresh_console(self):
        res = _drive("open", {"mission": MISSION, "session": None})
        self.assertIsNotNone(_button(res, "Preview"))
        self.assertTrue(_button(res, FILE_LABEL)["hidden"],
                        "with nothing authored, File stays hidden")
        self.assertTrue(_button(res, "Go ▸")["hidden"])

    def test_previewed_session_restores_the_authored_bugs_without_resplitting(self):
        """THE bug S161 exists to kill: the captain previewed, closed the console,
        and reopened it. The authored bugs must be on screen and File armed —
        with NO second POST to /log (no second split worker turn, no second bill)."""
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "previewed",
            "authored": True, "filed": False,
            "children": [PREVIEW_CHILD_A, PREVIEW_CHILD_B], "steers": ["", ""]}})
        texts = " | ".join(_texts(res))
        self.assertIn("XP not awarded on video completion", texts)
        self.assertIn("Leaderboard flicker", texts)
        self.assertIn("Preview — 2 bug missions detected", texts)
        self.assertFalse(_button(res, FILE_LABEL)["hidden"],
                         "the restored console must offer File")
        self.assertFalse(_button(res, FILE_LABEL)["disabled"])
        self.assertTrue(_button(res, "Go ▸")["hidden"],
                        "nothing is filed yet — no Go")
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(posts, [], "restoring must never re-run the split worker")

    def test_filing_session_restores_as_in_flight(self):
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "filing",
            "authored": True, "filed": False,
            "children": [PREVIEW_CHILD_A], "steers": [""]}})
        f = _button(res, "Filing…")
        self.assertIsNotNone(f, "an in-flight filing shows its own label")
        self.assertTrue(f["disabled"])
        self.assertTrue(_button(res, "Go ▸")["hidden"])
        working = [n for n in _flatten(res["node"])
                   if "Filing bugs and estimating" in n["text"]]
        self.assertTrue(working, "the working animation names what is happening")

    def test_filed_session_restores_the_review_and_reveals_go(self):
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "filed",
            "authored": False, "filed": True,
            "children": [FILED_CHILD_A], "overrides": []}})
        texts = " | ".join(_texts(res))
        # S163 fix round 3 rewords the review's tail: the panel is now scoped to
        # the MISSION (every bug still waiting to be fixed, whatever report it
        # came from) rather than to the batch, and its whole promise is that this
        # list is what `Go ▸` will run. Every row in it is still filed — the old
        # word was not false — but "waiting to be fixed" is the fact the captain
        # is being asked to act on.
        self.assertIn("Review — 1 bug mission waiting to be fixed", texts)
        self.assertFalse(_button(res, "Go ▸")["hidden"],
                         "filed bugs are reviewable — Go is offered")
        self.assertTrue(_button(res, FILE_LABEL)["hidden"])
        # BUG-059, client side: reopening a FILED console must not run anything.
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(posts, [])

    def test_failed_session_restores_with_its_reason_and_rearms_file(self):
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "failed",
            "authored": True, "filed": False,
            "error": "log.sh: the bug PRD is missing its Goal section",
            "children": [PREVIEW_CHILD_A], "steers": [""]}})
        texts = " | ".join(_texts(res))
        self.assertIn("missing its Goal section", texts)
        self.assertFalse(_button(res, FILE_LABEL)["hidden"],
                         "a failed file must be retryable for free")
        self.assertFalse(_button(res, FILE_LABEL)["disabled"])
        self.assertTrue(_button(res, "Go ▸")["hidden"])


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleFileTest(unittest.TestCase):
    SESSION = {"sessionId": "abc123", "parent": "m-001", "status": "previewed",
               "authored": True, "filed": False,
               "children": [PREVIEW_CHILD_A, PREVIEW_CHILD_B],
               "steers": ["", ""]}

    def test_file_posts_the_session_id_not_the_prds(self):
        res = _drive("clickFile", {"mission": MISSION, "session": self.SESSION})
        posts = [f for f in res["fetches"]
                 if f["url"].endswith("/log/file") and f["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        body = posts[0]["body"] or {}
        self.assertEqual(body.get("sessionId"), "abc123")
        self.assertNotIn("prds", body,
                         "the PRDs live on the daemon now — don't ship them back")
        self.assertIn("overrides", body)

    def test_file_and_cost_dispatches_marks_filing_and_closes(self):
        """S162 — the close-on-dispatch pattern `Go ▸` already used. S161 made the
        POST return in ~2ms instead of holding for the estimator; this is what
        that seam was for. The console goes, the parent card takes over."""
        res = _drive("clickFile", {"mission": MISSION, "session": self.SESSION})
        self.assertTrue(res["closed"], "the captain is handed the card, not a wait")
        self.assertTrue(res["filing"],
                        "and the parent mission is marked filing, so the band is "
                        "already on the card when the overlay disappears")
        self.assertTrue(res["status"],
                        "with a word on the status line — the console it "
                        "replaced is gone, so silence would be the whole defect")
        runs = [f for f in res["fetches"] if f["url"].endswith("/log/run")]
        self.assertEqual(runs, [], "BUG-059: filing never auto-runs the fixes")

    def test_file_falls_back_to_the_legacy_prds_body_without_a_session(self):
        """A daemon restart drops the session; the console still has the PRDs it
        rendered, so File degrades to the pre-S161 prds-in-body form."""
        res = _drive("clickFile", {
            "mission": MISSION, "session": None,
            # no session ⇒ the harness's File button is hidden; drive it anyway to
            # prove the payload SHAPE of the fallback branch.
            "fileResponse": {"children": [FILED_CHILD_A], "count": 1,
                             "parent": "m-001", "filed": True, "overrides": []}})
        posts = [f for f in res["fetches"] if f["url"].endswith("/log/file")]
        self.assertEqual(len(posts), 1)
        body = posts[0]["body"] or {}
        self.assertNotIn("sessionId", body)
        self.assertIn("prds", body)
        self.assertIn("imageRefs", body)   # per-bug routing rides the body too


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleFileAndCostTest(unittest.TestCase):
    """S162 — "File & Cost" is a DISPATCH the captain can walk away from.

    S161 put the authored PRDs on the daemon and made `/log/file` return in ~2ms
    instead of holding ~7s for the estimator. This is what that bought: the click
    marks the parent mission filing, closes the console, and lets the card's
    ◐ FILING & COSTING… band carry the rest. Closing is now the DEFAULT, not a
    risk — but the console is still whole for a captain who reopens it.
    """

    SESSION = {"sessionId": "abc123", "parent": "m-001", "status": "previewed",
               "authored": True, "filed": False, "bugCount": 2, "filedCount": 0,
               "children": [PREVIEW_CHILD_A, PREVIEW_CHILD_B],
               "steers": ["", ""]}

    def test_the_control_says_what_the_click_costs(self):
        res = _drive("open", {"mission": MISSION, "session": self.SESSION})
        f = _foot_file(res)
        self.assertEqual(f["text"], FILE_LABEL)
        self.assertFalse(f["hidden"])
        self.assertTrue(f["title"], "and says what it will do")

    def test_the_partial_retry_also_hands_over_the_card(self):
        """The retry is the same control under another name — it must background
        identically, or the one path a captain reaches while something has already
        gone wrong is the one that chains them to the desk."""
        res = _drive("clickFilePos",
                     {"mission": MISSION,
                      "session": LogConsolePartialTest.PARTIAL})
        self.assertTrue(res["closed"])
        self.assertTrue(res["filing"])
        posts = [f for f in res["fetches"] if f["url"].endswith("/log/file")]
        self.assertEqual(posts[0]["body"], {"sessionId": "abc123"},
                         "and still retries ONLY the bugs that are missing")

    def test_a_refused_dispatch_drops_the_band_and_says_so(self):
        """Nothing is filing, because the daemon never accepted it. Leaving the
        optimistic band up would have the card claim work that does not exist —
        the same lie class as a `filed` with nothing on disk, only client-side."""
        res = _drive("clickFile", {"mission": MISSION, "session": self.SESSION,
                                   "fileError": "that session was replaced"})
        self.assertTrue(res["closed"])
        self.assertFalse(res["filing"], "the flag must not outlive the refusal")
        self.assertIn("replaced", res["status"],
                      "and the daemon's reason must reach the captain on the "
                      "only surface still open")

    def test_the_legacy_no_session_path_is_untouched(self):
        """With no daemon session there is nothing durable to watch: the legacy
        prds-in-body POST HOLDS for the estimator, so closing the console would
        strand the captain with no band and no console. That path keeps its
        pre-S162 behaviour exactly — inline spinner, console open."""
        res = _drive("clickFile", {
            "mission": MISSION, "session": None,
            "fileResponse": {"children": [FILED_CHILD_A], "count": 1,
                             "parent": "m-001", "filed": True, "overrides": []}})
        self.assertFalse(res["closed"], "no session ⇒ no close-on-dispatch")
        self.assertFalse(res["filing"], "and nothing to put a band on")
        self.assertFalse(_button(res, "Go ▸")["hidden"],
                         "it still lands on the filed review, as it always did")

    def test_a_view_only_console_never_dispatches(self):
        res = _drive("clickFile", {"mission": MISSION, "session": self.SESSION},
                     readonly=True)
        self.assertFalse(res["filing"])
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [],
                         "a disabled control must post nothing")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsolePartialTest(unittest.TestCase):
    """S161 fix round 1, D1 (client half) — a batch where only SOME bugs landed.

    The daemon now reports that as `partial` (never `filed`). The console must show
    what IS on disk, say what is not, and NOT offer File again — re-filing would
    duplicate exactly the children that landed.
    """

    UNFILED_B = {"index": 1, "title": "Leaderboard flicker",
                 "type": "bug", "prd": PREVIEW_CHILD_B["prd"],
                 "images": [], "imageRefs": []}

    PARTIAL = {"sessionId": "abc123", "parent": "m-001", "status": "partial",
               "authored": False, "filed": False, "bugCount": 2, "filedCount": 1,
               "unfiledCount": 1, "unfiled": [UNFILED_B],
               "children": [FILED_CHILD_A], "overrides": [],
               "error": ("only 1 of 2 authored bugs filed (m-bug1) — 1 did not "
                         "reach disk; their authored text is still held, so File "
                         "again retries just those (no second split). lcars log: "
                         "bug PRD /tmp/p2.md is missing its '# Mission:' title "
                         "line.")}

    def test_partial_shows_the_shortfall_and_what_landed(self):
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL})
        texts = " | ".join(_texts(res))
        self.assertIn("1 of 2", texts, "the console must name the shortfall")
        self.assertIn("title line", texts, "and log.sh's own reason")
        self.assertIn("XP not awarded", texts, "and the bug that DID land")

    def test_the_shortfall_line_is_actually_VISIBLE_to_the_captain(self):
        """A shortfall the captain cannot see is the same lie class as a count that
        contradicts the disk: it must be in an UNHIDDEN error line, not merely
        present in the DOM. (This is a RESTORED console — the reopen path.)"""
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL})
        line = _by_cls(res, "errline")
        self.assertIsNotNone(line)
        self.assertFalse(line["hidden"],
                         "the shortfall must be shown, not just rendered")
        self.assertIn("1 of 2", line["text"])
        self.assertIn("still held", line["text"],
                      "and it must say the missing bug's text is recoverable")

    def test_partial_shows_the_unfiled_bugs_authored_text(self):
        """S161 fix round 2, N1 (client half) — the reason the session exists. The
        bug that did NOT file must be readable here, in full, so the captain can
        recover it without a second ~25s split worker turn."""
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL})
        self.assertIn(PREVIEW_CHILD_B["prd"], _values(res),
                      "the unfiled bug's authored PRD must be on screen verbatim")
        texts = " | ".join(_texts(res))
        self.assertIn("did NOT file", texts)
        self.assertIn("the text is still here", texts)
        self.assertIn("Leaderboard flicker", texts, "and which bug it is")
        # the copy must offer the route this panel CAN do (there is no edit-in-place
        # here), not just the retry — a PRD log.sh itself refused needs re-authoring.
        self.assertIn("copy the text below", texts.lower())

    def test_partial_offers_file_as_a_retry_of_what_is_missing(self):
        """Round 1 left File hidden-but-ENABLED at `partial`: an action whose only
        possible outcome was a 409. It is now the retry, and it says how many."""
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL})
        f = _foot_file(res)
        self.assertFalse(f["hidden"], "the retry must be reachable")
        self.assertFalse(f["disabled"])
        self.assertEqual(f["text"], "File 1 Remaining",
                         "the control must say what it will file")

    def test_the_retry_posts_the_session_id_alone(self):
        """The daemon re-files only the missing bugs. The console must NOT send its
        override inputs — at `partial` those are indexed by the children that
        LANDED, so they would re-index the captain's steers onto other bugs."""
        res = _drive("clickFilePos", {"mission": MISSION,
                                      "session": self.PARTIAL})
        posts = [f for f in res["fetches"]
                 if f["url"].endswith("/log/file") and f["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["body"], {"sessionId": "abc123"})
        runs = [f for f in res["fetches"] if f["url"].endswith("/log/run")]
        self.assertEqual(runs, [], "BUG-059: a retry never auto-runs the fixes")

    def test_partial_still_offers_go_for_the_bugs_that_landed(self):
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL})
        self.assertFalse(_button(res, "Go ▸")["hidden"])
        # BUG-059's hold: offering Go is not taking it.
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(posts, [])

    def test_a_failed_console_also_shows_the_authored_text(self):
        """Nothing landed, so every authored bug is recoverable text — and the
        captain has to SEE what log.sh refused in order to fix it."""
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "failed",
            "authored": True, "filed": False, "bugCount": 1, "filedCount": 0,
            "unfiledCount": 1, "unfiled": [dict(self.UNFILED_B, index=0)],
            "error": "log.sh: missing its '# Mission:' title line",
            "children": [PREVIEW_CHILD_B], "steers": [""]}})
        self.assertIn(PREVIEW_CHILD_B["prd"], _values(res))

    def test_a_filed_console_shows_no_recovery_panel(self):
        res = _drive("open", {"mission": MISSION, "session": {
            "sessionId": "abc123", "parent": "m-001", "status": "filed",
            "authored": False, "filed": True, "bugCount": 1, "filedCount": 1,
            "unfiledCount": 0, "unfiled": [],
            "children": [FILED_CHILD_A], "overrides": []}})
        texts = " | ".join(_texts(res))
        self.assertNotIn("did NOT file", texts)
        self.assertTrue(_foot_file(res)["hidden"],
                        "everything landed — there is nothing left to file")

    def test_view_only_cannot_fire_the_partial_retry(self):
        """The re-arm must route through applyWriteState — an earlier round shipped
        a bug here by clearing `disabled` outright."""
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL},
                     readonly=True)
        self.assertTrue(_foot_file(res)["disabled"],
                        "a view-only board must not offer a live retry")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleDismissTest(unittest.TestCase):
    """S161 fix round 1, D3 (client half) — the abandoned-preview escape hatch.

    A live session stamps the parent card, and there was no way to clear it. The
    footer's dismissal control now DISCARDS the session when nothing has landed on
    disk, and only closes when something has — and it says which it is doing.
    """

    PREVIEWED = {"sessionId": "abc123", "parent": "m-001", "status": "previewed",
                 "authored": True, "filed": False, "bugCount": 1, "filedCount": 0,
 "children": [PREVIEW_CHILD_A], "steers": [""]}

    def _discards(self, res):
        return [f for f in res["fetches"]
                if f["url"].endswith("/log/discard") and f["method"] == "POST"]

    def test_a_previewed_console_offers_a_discard_and_says_so(self):
        res = _drive("open", {"mission": MISSION, "session": self.PREVIEWED})
        self.assertEqual(res["dismiss"]["text"], "Discard Preview")
        self.assertIn("clear", res["dismiss"]["title"].lower())

    def test_discarding_a_previewed_console_posts_the_discard_and_closes(self):
        res = _drive("dismiss", {"mission": MISSION, "session": self.PREVIEWED})
        self.assertEqual(len(self._discards(res)), 1)
        self.assertTrue(res["closed"])

    def test_a_console_with_no_session_discards_nothing(self):
        res = _drive("dismiss", {"mission": MISSION, "session": None})
        self.assertEqual(res["dismiss"]["text"], "Close")
        self.assertEqual(self._discards(res), [])
        self.assertTrue(res["closed"])

    def test_a_failed_console_is_discardable(self):
        """Nothing landed, so the session is the captain's to throw away."""
        sess = dict(self.PREVIEWED, status="failed", error="log.sh refused it")
        res = _drive("dismiss", {"mission": MISSION, "session": sess})
        self.assertEqual(len(self._discards(res)), 1)

    def test_a_filing_console_closes_without_discarding(self):
        """The filing is really in flight — the card must keep saying so."""
        sess = dict(self.PREVIEWED, status="filing")
        res = _drive("dismiss", {"mission": MISSION, "session": sess})
        self.assertEqual(res["dismiss"]["text"], "Close")
        self.assertEqual(self._discards(res), [])
        self.assertTrue(res["closed"])

    def test_a_filed_console_closes_without_discarding(self):
        """The bugs exist and are awaiting the captain's Go — that is news the
        parent card must keep, so dismissal must not silently drop it."""
        sess = {"sessionId": "abc123", "parent": "m-001", "status": "filed",
                "authored": False, "filed": True, "bugCount": 1, "filedCount": 1,
 "children": [FILED_CHILD_A], "overrides": []}
        res = _drive("dismiss", {"mission": MISSION, "session": sess})
        self.assertEqual(res["dismiss"]["text"], "Close")
        self.assertEqual(self._discards(res), [])

    def test_a_partial_console_offers_to_discard_the_unfiled_leftover(self):
        """N1: the Go deliberately KEEPS a partial session (its unfiled bugs exist
        only as text it holds), so this is the only way to clear the card — and the
        label has to say what it destroys rather than pose as a plain Close."""
        sess = dict(LogConsolePartialTest.PARTIAL)
        res = _drive("open", {"mission": MISSION, "session": sess})
        self.assertEqual(res["dismiss"]["text"], "Discard Unfiled")
        self.assertIn("did not file", res["dismiss"]["title"].lower())
        self.assertIn("did file", res["dismiss"]["title"].lower(),
                      "and that the bugs that landed are untouched")
        res = _drive("dismiss", {"mission": MISSION, "session": sess})
        self.assertEqual(len(self._discards(res)), 1)
        self.assertTrue(res["closed"])

    def test_dismissal_never_re_splits_or_files(self):
        res = _drive("dismiss", {"mission": MISSION, "session": self.PREVIEWED})
        bad = [f for f in res["fetches"]
               if f["url"].endswith("/log") or f["url"].endswith("/log/file")
               or f["url"].endswith("/log/run")]
        self.assertEqual(bad, [])


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleRePreviewGuardTest(unittest.TestCase):
    """S161 fix round 3, R1 (client half) — Preview beside "File 1 Remaining" used
    to destroy the unfiled bug's authored text on one unremarkable click, with no
    tooltip, while the explicitly-destructive "Discard Unfiled" next to it warned.

    The daemon is the guard (it 409s a preview that would lose held text — a client
    can always be bypassed). The console's job is to make the choice legible: the
    first click ARMS the destruction and says what it costs, and only the second
    one sends `discardUnfiled`. With nothing stranded, Preview is untouched.
    """

    PARTIAL = LogConsolePartialTest.PARTIAL
    REPORT = "Sierra is stranded on the pad."

    def _previews(self, res):
        return [f for f in res["fetches"]
                if f["url"].endswith("/log") and f["method"] == "POST"]

    def _foot_preview(self, res):
        """The footer's Preview control BY POSITION — its label is asserted."""
        return res["node"]["children"][2]["children"][1]

    def test_preview_at_partial_warns_instead_of_destroying(self):
        res = _drive("clickPreview", {"mission": MISSION,
                                      "session": self.PARTIAL,
                                      "report": self.REPORT})
        self.assertEqual(self._previews(res), [],
                         "the first click must not send the preview that would "
                         "throw the unfiled bug's authored text away")
        p = self._foot_preview(res)
        self.assertIn("Discard", p["text"],
                      "the control must relabel itself to name the loss")
        self.assertIn("1", p["text"], "and how many bugs it would lose")
        self.assertFalse(p["disabled"], "the captain can still choose it")
        line = _by_cls(res, "errline")
        self.assertFalse(line["hidden"], "and the warning must be VISIBLE")
        self.assertIn("Leaderboard flicker", line["text"],
                      "naming the bug whose text is at stake")

    def test_the_second_click_sends_the_explicit_discard(self):
        res = _drive("clickPreviewTwice", {"mission": MISSION,
                                           "session": self.PARTIAL,
                                           "report": self.REPORT})
        posts = self._previews(res)
        self.assertEqual(len(posts), 1, "exactly one preview, on the 2nd click")
        self.assertTrue((posts[0]["body"] or {}).get("discardUnfiled"),
                        "the captain's confirmation must ride the POST")
        self.assertEqual((posts[0]["body"] or {}).get("text"), self.REPORT)

    def test_preview_carries_a_tooltip_of_what_it_will_do(self):
        """The residual's other half: Preview sat there with no title at all while
        its neighbour warned. A tooltip is not the guard, but its silence was part
        of why the click read as harmless."""
        res = _drive("open", {"mission": MISSION, "session": self.PARTIAL,
                              "report": self.REPORT})
        self.assertTrue(self._foot_preview(res)["title"],
                        "Preview must say what it does")

    def test_an_ordinary_preview_is_not_gated(self):
        """`previewed` strands nothing — the ordinary re-split must still be ONE
        click, and must not claim to discard anything."""
        sess = {"sessionId": "abc123", "parent": "m-001", "status": "previewed",
                "authored": True, "filed": False, "bugCount": 1, "filedCount": 0,
                "unfiledCount": 1, "unfiled": [], "children": [PREVIEW_CHILD_A],
                "steers": [""]}
        res = _drive("clickPreview", {"mission": MISSION, "session": sess,
                                      "report": self.REPORT})
        posts = self._previews(res)
        self.assertEqual(len(posts), 1, "one click, one preview")
        self.assertFalse((posts[0]["body"] or {}).get("discardUnfiled"))

    def test_a_console_with_no_session_previews_straight_away(self):
        res = _drive("clickPreview", {"mission": MISSION, "session": None,
                                      "report": self.REPORT})
        self.assertEqual(len(self._previews(res)), 1)

    def test_a_refused_preview_re_syncs_from_the_daemon(self):
        """The daemon is the guard, so a console whose picture is stale (it thinks
        nothing is stranded; the daemon knows better) must not be able to loop on
        the same refusal. No split happened, so it goes and re-reads the session —
        which re-arms the confirmation from fact, not by parsing the message."""
        stale = {"sessionId": "abc123", "parent": "m-001", "status": "previewed",
                 "authored": True, "filed": False, "bugCount": 1, "filedCount": 0,
                 "unfiledCount": 0, "unfiled": [], "children": [PREVIEW_CHILD_A],
                 "steers": [""]}
        res = _drive("clickPreview", {
            "mission": MISSION, "session": stale, "report": self.REPORT,
            "previewError": "this mission-log session still holds 1 authored bug"})
        self.assertEqual(len(self._previews(res)), 1, "it did try once")
        gets = [f for f in res["fetches"]
                if f["url"].endswith("/log/session") and f["method"] == "GET"]
        self.assertGreaterEqual(len(gets), 2,
                                "the refusal must send it back to the daemon for "
                                "the real state (open + re-sync)")
        self.assertEqual(self._foot_preview(res)["text"], "Preview",
                         "and it must not sit there armed on a refusal")

    def test_view_only_still_cannot_preview_at_all(self):
        """The re-arm must route through applyWriteState (a prior round shipped a
        bare `disabled = false` bug), so the armed state must stay disabled."""
        res = _drive("clickPreview", {"mission": MISSION,
                                      "session": self.PARTIAL,
                                      "report": self.REPORT}, readonly=True)
        self.assertTrue(self._foot_preview(res)["disabled"])
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [])


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleRePreviewRelabelTest(unittest.TestCase):
    """S161 fix round 4 — a confirmed re-preview must leave the File control
    describing the session that now EXISTS.

    From `partial` the retry control correctly reads "File 1 Remaining". Confirm a
    re-preview and the daemon mints a brand-new session with (here) three authored
    bugs — but the preview-success handler updated `authored.*`, the dismissal
    label and the armed discard, and never the File label. The button went on
    saying "File 1 Remaining" and then filed 3 of 3: a control whose name was a
    leftover from a session that no longer exists.
    """

    PARTIAL = LogConsolePartialTest.PARTIAL
    REPORT = "Three new problems, all at once."

    FRESH_THREE = {
        "sessionId": "def456", "parent": "m-001", "authored": True,
        "filed": False, "count": 3,
        "children": [
            {"title": "XP not awarded on video completion", "type": "bug",
             "prd": "# Mission: XP\n\na\n", "images": [], "imageRefs": []},
            {"title": "Leaderboard flicker", "type": "bug",
             "prd": "# Mission: Flicker\n\nb\n", "images": [], "imageRefs": []},
            {"title": "Badge count off by one", "type": "bug",
             "prd": "# Mission: Badges\n\nc\n", "images": [], "imageRefs": []},
        ],
    }

    def _drive_confirmed(self, readonly=False):
        return _drive("clickPreviewTwice",
                      {"mission": MISSION, "session": self.PARTIAL,
                       "report": self.REPORT,
                       "previewResponse": self.FRESH_THREE}, readonly=readonly)

    def test_a_confirmed_re_preview_relabels_file_for_the_new_session(self):
        res = self._drive_confirmed()
        f = _foot_file(res)
        self.assertFalse(f["hidden"], "the fresh split authored 3 bugs to file")
        self.assertFalse(f["disabled"], "and File must be armed for them")
        self.assertNotIn("Remaining", f["text"],
                         "the retry label belonged to the session the captain "
                         "just discarded — it must not name this one")
        self.assertEqual(f["text"], FILE_LABEL,
                         "a fresh preview's File is the plain File control")

    def test_the_relabel_routes_through_the_write_gate(self):
        """Never a bare `textContent =` / `disabled = false`: an earlier round in
        this session shipped exactly that and handed a read-only board a live File
        button. A view-only console must stay inert through the whole flow."""
        res = self._drive_confirmed(readonly=True)
        f = _foot_file(res)
        self.assertTrue(f["disabled"],
                        "a view-only board must not come out of a re-preview "
                        "with a live File control")
        self.assertEqual([f_ for f_ in res["fetches"] if f_["method"] == "POST"],
                         [], "and it must never have posted anything")

    def test_the_arming_warning_cannot_name_a_control_by_a_stale_label(self):
        """The warning quotes the retry control's name so it points at the real UI.
        Reading `file.textContent` to get it makes the copy inherit whatever
        transient text the button happens to be wearing: click File at `partial`
        and, while that POST is still in flight, click Preview — the warning came
        out telling the captain that "Filing…" is what keeps their bugs."""
        res = _drive("clickFileThenPreview", {"mission": MISSION,
                                              "session": self.PARTIAL,
                                              "report": self.REPORT})
        line = _by_cls(res, "errline")
        self.assertIsNotNone(line)
        self.assertFalse(line["hidden"], "the warning must be visible")
        self.assertNotIn("Filing…", line["text"],
                         "the warning must not name the retry control by a "
                         "transient in-flight label")
        self.assertIn("File 1 Remaining", line["text"],
                      "it must name the control by what File MEANS for this "
                      "session")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class LogConsoleViewOnlyTest(unittest.TestCase):
    VIEW_ONLY_SESSION = {"sessionId": "abc123", "parent": "m-001",
                         "status": "previewed", "authored": True, "filed": False,
 "bugCount": 1, "filedCount": 0,
                         "children": [PREVIEW_CHILD_A], "steers": [""]}

    def test_view_only_disables_every_write_control(self):
        res = _drive("open", {"mission": MISSION,
                              "session": self.VIEW_ONLY_SESSION}, readonly=True)
        for label in ("Preview", FILE_LABEL, "Go ▸"):
            b = _button(res, label)
            self.assertIsNotNone(b, "%s must still exist" % label)
            self.assertTrue(b["disabled"],
                            "%s must be disabled on a view-only board" % label)

    def test_view_only_can_still_close_its_own_console(self):
        """The dismissal control is NOT a write — a view-only board (which can hold
        no session, so never takes the discard branch) must be able to close what
        it opened. Disabling it would trap the viewer in the console."""
        res = _drive("open", {"mission": MISSION,
                              "session": self.VIEW_ONLY_SESSION}, readonly=True)
        foot = res["node"]["children"][2]
        self.assertFalse(foot["children"][0]["disabled"])

    def test_view_only_never_offers_or_dispatches_the_discard(self):
        """The discard IS a write. A view-only board must neither advertise it nor
        fire it, even if it is somehow handed a session payload."""
        res = _drive("dismiss", {"mission": MISSION,
                                 "session": self.VIEW_ONLY_SESSION}, readonly=True)
        self.assertEqual(res["dismiss"]["text"], "Close")
        self.assertEqual([f for f in res["fetches"] if f["method"] == "POST"], [])
        self.assertTrue(res["closed"])


if __name__ == "__main__":
    unittest.main()
