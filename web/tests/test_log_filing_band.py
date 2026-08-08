"""S162 — the ◐ FILING & COSTING band on the parent card.

S161 moved the authored bug PRDs into a daemon-side session so closing the
Mission-Log console stopped throwing them away. This session spends that seam:
"File & Cost" DISPATCHES the filing and closes the console, and the parent card
takes over the job of telling the captain what is happening — the same clothes
new missions have worn since S137's ◐ FINALIZING & COSTING band.

Drives the SHIPPING `cardNode(m)` / `renderDetail(m)` in a node vm
(board_logfiling_harness.js), and asserts:

  * the band + a DISABLED control appear from the CLIENT map, on the click, with
    no SSE tick and no server stamp of `filing` yet;
  * a page RELOAD mid-filing (no client state at all) still shows them, off the
    S161 board stamp;
  * `filed` clears them; `failed` / `partial` replace them with a legible state
    that NAMES the failure instead of clearing silently;
  * a card with no live log session renders BYTE-IDENTICALLY to its pre-S162
    self (the additive-payload invariant, proven against the real pre-S162
    board.js rather than argued);
  * a view-only board is handed no live control;
  * the filing band and the Align FINALIZING band COEXIST on one card — they are
    different work on different clocks, and neither may silence the other.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_logfiling_harness.js")
REPO = os.path.dirname(os.path.dirname(HERE))
BOARD_JS = os.path.join(REPO, "web", "static", "board.js")
# The two sheets index.html links, IN LINK ORDER — the shared token source first,
# the board geometry second (ADR-007). Order is part of the cascade, so the list
# is the contract: a resolution computed from board.css alone would miss both the
# --lcars-* values and any rule lcars.css contributes.
CSS_SHEETS = [os.path.join(REPO, "docs", "lcars.css"),
              os.path.join(REPO, "web", "static", "board.css")]
NODE = shutil.which("node")
GIT = shutil.which("git")

# The commit this session builds ON: S161, the last state of board.js before the
# filing band existed. Behaviour 5 ("a mission with no log session renders
# byte-identically to pre-162") is asserted against the REAL file at that commit,
# so the invariant is measured, not asserted by eye.
PRE_S162 = "e41cd63"

CONTROL = "◐ FILING & COSTING…"
BAND = "◐ Filing bugs & costing each fix…"

VERIFY = {"id": "m-001", "issue": 142, "stage": "verify", "type": "feature",
          "title": "Add Gamification to Course Site",
          "pills": {"cost": {"label": "$4–7", "level": "med"},
                    "reasoning": {"label": "R med", "level": "med"},
                    "implementation": {"label": "I low", "level": "low"}}}


def _stamp(status, bug_count=2, filed_count=0, error=None, sid="abc123"):
    s = {"sessionId": sid, "status": status,
         "bugCount": bug_count, "filedCount": filed_count}
    if error is not None:
        s["error"] = error
    return s


def _drive(mission, mode="card", mark_filing=False, mark_finalizing=False,
           readonly=False, board_js=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump({"mission": mission, "markFiling": mark_filing,
                   "markFinalizing": mark_finalizing}, fh)
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
    surface. Deliberately the `node` subtree ONLY: the harness's sibling fields
    report the CLIENT state it was asked to set up, which a pre-S162 board.js
    cannot answer at all (it has no isFiling), and comparing those would be
    comparing the harness with itself rather than the render."""
    return json.dumps(res["node"], sort_keys=True, ensure_ascii=False)


def _texts(res):
    return [n["text"] for n in _flatten(res["node"]) if n["text"]]


def _node_with_text(res, text):
    for n in _flatten(res["node"]):
        if n["text"] == text:
            return n
    return None


def _classes(res, cls):
    return [n for n in _flatten(res["node"])
            if cls in (n["cls"] or "").split()]


def _node_starting_with(res, prefix):
    """S169/FL-017 — the `_node_with_text` twin for a label that carries a live
    elapsed readout after its fixed opening."""
    for n in _flatten(res["node"]):
        if (n["text"] or "").startswith(prefix):
            return n
    return None


def _has_band_starting(res, prefix):
    """`_has_band`, matched on the label's OPENING (see `_node_starting_with`)."""
    for n in _flatten(res["node"]):
        cls = (n["cls"] or "").split()
        if "lcars-working" in cls and "lcars-running" in cls:
            if any((c["text"] or "").startswith(prefix) for c in _flatten(n)):
                return True
    return False


def _has_band(res, label=BAND):
    """The persistent animated band — a .lcars-running working node whose LABEL
    says what is in flight (the same shape scanningPulse/finalizingPulse make)."""
    for n in _flatten(res["node"]):
        cls = (n["cls"] or "").split()
        if "lcars-working" in cls and "lcars-running" in cls:
            if any(c["text"] == label for c in _flatten(n)):
                return True
    return False


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingBandTest(unittest.TestCase):
    """Behaviours 2, 3, 4 — the band's whole life, on the card."""

    def test_the_click_paints_the_band_before_any_server_tick(self):
        """Behaviour 2. The captain clicks File & Cost and the console closes; the
        POST has not returned, no SSE has fired, and the cached board still
        carries the session's PRE-dispatch `previewed` stamp. The card must
        already be saying so — the whole point of the optimistic map."""
        m = dict(VERIFY, logFiling=_stamp("previewed"))
        res = _drive(m, mark_filing=True)
        self.assertTrue(res["filing"], "the client flag must survive the render")
        self.assertTrue(_has_band(res),
                        "the persistent animated band must be on the card")
        ctrl = _node_with_text(res, CONTROL)
        self.assertIsNotNone(ctrl, "and a control that names the state")
        self.assertTrue(ctrl["disabled"], "which is never clickable")
        self.assertFalse(ctrl["clickable"], "and dispatches nothing")

    def test_a_reload_mid_filing_still_shows_the_band(self):
        """Behaviour 3. A fresh tab has NO client state — only the S161 board
        stamp. That is the durable half of the alignResume split, and it is the
        difference between a card that tells the truth and one that forgets."""
        m = dict(VERIFY, logFiling=_stamp("filing"))
        res = _drive(m)                       # no markFiling: a fresh page load
        self.assertFalse(res["filing"], "no client state — this is the reload")
        self.assertTrue(_has_band(res))
        self.assertIsNotNone(_node_with_text(res, CONTROL))

    def test_a_filed_stamp_clears_the_band_and_the_optimistic_flag(self):
        """Behaviour 4a. The server settled it: every bug is on disk. The band
        goes, and so does the client flag (otherwise the next repaint would
        re-draw it from stale optimism until the timeout)."""
        m = dict(VERIFY, logFiling=_stamp("filed", filed_count=2))
        res = _drive(m, mark_filing=True)
        self.assertFalse(res["filing"], "a terminal status drops the flag")
        self.assertFalse(_has_band(res))
        self.assertIsNone(_node_with_text(res, CONTROL))

    def test_a_failed_stamp_names_the_failure_instead_of_clearing_silently(self):
        """Behaviour 4b. Silence here is the defect: the captain closed the
        console on dispatch, so if the card just stops animating they are left
        believing bugs were filed that do not exist."""
        why = "lcars log: bug PRD /tmp/p2.md is missing its '# Mission:' title line"
        m = dict(VERIFY, logFiling=_stamp("failed", error=why))
        res = _drive(m, mark_filing=True)
        self.assertFalse(res["filing"])
        self.assertFalse(_has_band(res), "nothing is in flight any more")
        note = _classes(res, "log-filing-status")
        self.assertEqual(len(note), 1, "the card must carry a failure state")
        self.assertIn("failed", note[0]["text"])
        self.assertIn("0 of 2", note[0]["text"], "and say how much landed")
        self.assertIn("failed", (note[0]["cls"] or "").split(),
                      "styled as the attention state, not a routine note")
        detail = _classes(res, "log-filing-detail")
        self.assertEqual(len(detail), 1)
        self.assertEqual(detail[0]["text"], why,
                         "the daemon's own words, verbatim — the client cannot "
                         "know the reason, so it must not paraphrase one")

    def test_a_partial_stamp_says_exactly_how_many_landed(self):
        """`partial` is S161's honest middle: some bugs are real and reviewable,
        the rest are still only text the daemon holds. The card must not round
        that to either 'done' or 'failed'."""
        why = ("only 1 of 2 authored bugs filed (m-bug1) — 1 did not reach disk; "
               "their authored text is still held")
        m = dict(VERIFY, logFiling=_stamp("partial", filed_count=1, error=why))
        res = _drive(m, mark_filing=True)
        self.assertFalse(res["filing"])
        self.assertFalse(_has_band(res))
        note = _classes(res, "log-filing-status")
        self.assertEqual(len(note), 1)
        self.assertIn("1 of 2", note[0]["text"])
        self.assertNotIn("failed", (note[0]["cls"] or "").split(),
                         "a partial is not a failure — some bugs really landed")
        self.assertEqual(_classes(res, "log-filing-detail")[0]["text"], why)

    def test_a_previewed_stamp_does_not_clear_the_optimistic_flag(self):
        """The sticky-optimism lesson (BUG-078). The board cached at the moment
        of the click still says `previewed` — the daemon has not been told yet.
        Clearing on 'anything but filing' would wipe the band one frame after
        drawing it, which is exactly the flicker this band exists to remove."""
        m = dict(VERIFY, logFiling=_stamp("previewed"))
        res = _drive(m, mark_filing=True)
        self.assertTrue(res["filing"])
        self.assertTrue(_has_band(res))

    def test_a_previewed_session_alone_paints_nothing(self):
        """A session that has only been PREVIEWED is not work in flight — the
        captain is still authoring. The band must not claim otherwise (the
        follow-through control for that state is S163's business)."""
        res = _drive(dict(VERIFY, logFiling=_stamp("previewed")))
        self.assertFalse(_has_band(res))
        self.assertIsNone(_node_with_text(res, CONTROL))
        self.assertEqual(_classes(res, "log-filing-status"), [])

    def test_a_vanished_session_clears_the_optimistic_flag(self):
        """The stamp is gone: the session was discarded, or the captain's Go
        consumed it. There is nothing left to be filing, so the card must not go
        on animating until a timeout rescues it."""
        res = _drive(VERIFY, mark_filing=True)     # no logFiling stamp at all
        self.assertFalse(res["filing"])
        self.assertFalse(_has_band(res))
        self.assertIsNone(_node_with_text(res, CONTROL))


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingBandCoexistenceTest(unittest.TestCase):
    """Behaviour 7 — FILING is its own map, not a second meaning for FINALIZING."""

    PARKED = {"id": "m-002", "issue": 7, "stage": "align", "type": "feature",
              "title": "Parked idea", "prdPending": True}

    def test_the_filing_band_and_the_align_band_coexist(self):
        m = dict(self.PARKED, logFiling=_stamp("filing"))
        res = _drive(m, mark_filing=True, mark_finalizing=True)
        self.assertTrue(res["filing"])
        self.assertTrue(res["finalizing"])
        self.assertTrue(_has_band(res), "the filing band")
        # S169/FL-017: the Align band now carries the finalize's ELAPSED time
        # (`◐ Finalizing & costing… 5m 10s`), the way the scanning band already
        # did — silence is what made FL-009 frightening. This assertion is about
        # COEXISTENCE, so it matches the label's opening rather than pinning a
        # clock into a test about two bands sharing one card.
        self.assertTrue(_has_band_starting(res, "◐ Finalizing & costing…"),
                        "and the Align finalizing band, on the same card")
        self.assertIsNotNone(_node_with_text(res, CONTROL))
        self.assertIsNotNone(
            _node_starting_with(res, "◐ FINALIZING & COSTING…"),
            "neither control may replace the other")

    def test_a_filing_card_keeps_its_own_stage_control(self):
        """The filing is news ABOUT the mission, not a new state OF it: a verify
        card must still offer its verify gate while its logged bugs file."""
        m = dict(VERIFY, logFiling=_stamp("filing"))
        res = _drive(m)
        labels = _texts(res)
        self.assertIn(CONTROL, labels)
        self.assertTrue([t for t in labels if "Verify" in t or "Review" in t],
                        "the mission's own control is untouched: %r" % (labels,))

    def test_filing_does_not_mark_the_mission_finalizing(self):
        res = _drive(dict(VERIFY, logFiling=_stamp("filing")), mark_filing=True)
        self.assertFalse(res["finalizing"],
                         "one map per meaning — a log filing is not an Align")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingBandViewOnlyTest(unittest.TestCase):
    """Behaviour 6 — a read-only build is handed no live control."""

    def test_the_control_is_inert_on_a_view_only_board(self):
        m = dict(VERIFY, logFiling=_stamp("filing"))
        res = _drive(m, readonly=True)
        ctrl = _node_with_text(res, CONTROL)
        self.assertIsNotNone(ctrl, "the state is still readable view-only")
        self.assertTrue(ctrl["disabled"])
        self.assertFalse(ctrl["clickable"], "and it dispatches nothing")

    def test_the_control_carries_the_go_chrome_markviewonly_sweeps(self):
        """`markViewOnly()` disables what is already on screen by sweeping
        `.board .btn.go/.warn/.danger`. A control outside that set would survive a
        403 as a live-looking button, so the class list is part of the contract —
        the S161-D9 lesson (a bare `disabled = false` handed a read-only board a
        live File button) applied one layer up."""
        res = _drive(dict(VERIFY, logFiling=_stamp("filing")))
        ctrl = _node_with_text(res, CONTROL)
        self.assertIn("go", (ctrl["cls"] or "").split())
        self.assertTrue(ctrl["disabled"],
                        "and it is born disabled, not disabled on demand")


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingDetailTest(unittest.TestCase):
    """The mission DETAIL mirrors the card (the align_overlay_mission lesson: the
    detail never runs through the board overlay, so a surface left out of this
    goes silent exactly when the captain clicks the card to look closer)."""

    def test_the_detail_header_shows_the_filing_too(self):
        res = _drive(dict(VERIFY, logFiling=_stamp("filing")), mode="detail")
        ctrl = _node_with_text(res, CONTROL)
        self.assertIsNotNone(ctrl)
        self.assertTrue(ctrl["disabled"])

    def test_the_detail_names_a_failure_as_the_card_does(self):
        why = "log.sh: bug PRD is missing its '# Mission:' title line"
        res = _drive(dict(VERIFY, logFiling=_stamp("failed", error=why)),
                     mode="detail")
        note = _classes(res, "log-filing-status")
        self.assertEqual(len(note), 1)
        self.assertIn("0 of 2", note[0]["text"])
        self.assertEqual(_classes(res, "log-filing-detail")[0]["text"], why)

    def test_a_detail_with_no_session_shows_none_of_it(self):
        res = _drive(VERIFY, mode="detail")
        self.assertIsNone(_node_with_text(res, CONTROL))
        self.assertEqual(_classes(res, "log-filing-status"), [])


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
@unittest.skipIf(GIT is None, "git is required to fetch the pre-S162 board.js")
class ByteIdenticalWithoutASessionTest(unittest.TestCase):
    """Behaviour 5 — a board with no in-flight log filing renders byte-identically
    to pre-S162.

    Not argued: MEASURED. Every fixture below is rendered twice — once through the
    working tree's board.js and once through the real file at %s — and the two
    projections are compared as raw JSON. There is no normaliser, so there is
    nothing for a difference to hide behind; the projection deliberately carries
    every field a card can differ by (class, text, title, hidden, disabled,
    clickable), and the card render reads no clock, which is what makes a raw
    comparison possible at all (proven by `test_the_render_is_deterministic`).
    """ % PRE_S162

    FIXTURES = {
        "verify": VERIFY,
        "verify_with_a_previewed_session": dict(VERIFY,
                                                logFiling=_stamp("previewed")),
        "parked": {"id": "m-002", "issue": 7, "stage": "align", "type": "feature",
                   "title": "Parked idea", "prdPending": True},
        "running_implement": {
            "id": "m-003", "issue": 8, "stage": "implement", "type": "feature",
            "title": "Wave 2 in flight", "running": True, "dispatched": True,
            "engine": "copilot",
            "progress": {"ticketsDone": 3, "ticketsTotal": 7, "label": "wave 2"},
            "tickets": [{"id": "T1", "title": "seed", "state": "done"},
                        {"id": "T2", "title": "band", "state": "run"},
                        {"id": "T3", "title": "gate", "state": "pending"}],
            "liveness": {"state": "producing", "quietSeconds": 3}},
        "paused": {"id": "m-004", "issue": 9, "stage": "plan", "type": "feature",
                   "title": "Held", "paused": True},
        "awaiting": {"id": "m-005", "issue": 10, "stage": "validate",
                     "type": "feature", "title": "Needs a call", "awaiting": True},
        "done": {"id": "m-006", "issue": 11, "stage": "done", "type": "feature",
                 "title": "Shipped"},
        "log_bug_child": {"id": "m-bug1", "issue": 301, "stage": "plan",
                          "type": "bug", "title": "XP not awarded",
                          "parentMission": "m-001", "linked": True},
        "reconciling_verify": dict(VERIFY, id="m-007",
                                   reconcileStatus="merge-failed",
                                   reconcileNote="push rejected — non-fast-forward"),
        "launched_verify": dict(VERIFY, id="m-008",
                                launch={"status": "running",
                                        "url": "http://127.0.0.1:5173"}),
    }

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="s162-pre-")
        cls.pristine = os.path.join(cls.tmp, "board.js")
        try:
            src = subprocess.check_output(
                [GIT, "-C", REPO, "show", "%s:web/static/board.js" % PRE_S162],
                stderr=subprocess.STDOUT)
        except (subprocess.CalledProcessError, OSError) as exc:
            shutil.rmtree(cls.tmp, ignore_errors=True)
            raise unittest.SkipTest(
                "cannot read board.js at %s (%s) — the byte-identity baseline is "
                "unavailable in this checkout" % (PRE_S162, exc))
        with open(cls.pristine, "wb") as fh:
            fh.write(src)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", None) or "", ignore_errors=True)

    def test_the_baseline_really_is_pre_s162(self):
        """A baseline that already knew about filing would make every comparison
        below pass for the wrong reason."""
        with open(self.pristine) as fh:
            pristine = fh.read()
        self.assertNotIn("markFiling", pristine)
        self.assertNotIn(CONTROL, pristine)
        with open(BOARD_JS) as fh:
            self.assertIn("markFiling", fh.read(),
                          "and the working tree really is S162")

    def test_the_render_is_deterministic(self):
        """No clock, no randomness: the same fixture renders to the same bytes
        twice. This is what licenses the raw comparison — with a wall-clock field
        in the projection the test would need a normaliser, and a normaliser is
        somewhere a real difference can hide."""
        for name, m in sorted(self.FIXTURES.items()):
            a = _drive(m, board_js=self.pristine)
            b = _drive(m, board_js=self.pristine)
            self.assertEqual(_dom(a), _dom(b), name)

    def test_every_card_without_a_live_filing_is_unchanged(self):
        for name, m in sorted(self.FIXTURES.items()):
            for readonly in (False, True):
                pre = _drive(m, readonly=readonly, board_js=self.pristine)
                now = _drive(m, readonly=readonly)
                self.assertEqual(_dom(pre), _dom(now),
                                 "%s (readonly=%s) drifted" % (name, readonly))

    def test_every_detail_without_a_live_filing_is_unchanged(self):
        for name, m in sorted(self.FIXTURES.items()):
            pre = _drive(m, mode="detail", board_js=self.pristine)
            now = _drive(m, mode="detail")
            self.assertEqual(_dom(pre), _dom(now), "%s detail drifted" % name)


# ════════════════════════════════════════════════════════════════════════════
# BUG-S162-A — the status line's WINNING declaration, resolved not string-matched
#
# The defect this section exists for: `● only 1 of 2 filed` rendered in the same
# muted slate-grey as the `#142 · lcars:verify` metadata line above it. The amber
# rule was in board.css and read correctly to the eye — but the element was
# emitted as `class="no log-filing-status"`, `.card .no` ties it on specificity
# (0,2,0) and sits LATER in the sheet, so the amber never reached the screen.
# `.failed` survived only because it also set a colour at (0,3,0).
#
# A test that greps board.css for `.log-filing-status{color:var(--lcars-amber)`
# passes in exactly that broken state — it is the flattering green this round has
# been burned by repeatedly. So the pin below MEASURES, the way the tester did:
# the class list the shipping builder actually emits, resolved against the real
# stylesheets through a cascade (specificity + source order + custom properties),
# and it is asserted for EVERY terminal status the band can produce, read out of
# board.js rather than hard-coded, so a new sibling status cannot go unstyled in
# silence.
#
# Below is a deliberately small CSS cascade resolver. It handles exactly what
# these sheets use — descendant combinators over tag/class compounds — and it
# REFUSES to guess: any rule it cannot parse, and any rule that lives under a
# conditional at-rule, is surfaced to the test, which fails if such a rule could
# match the element. That is the difference between "the resolution is right" and
# "the resolver did not notice".
# ════════════════════════════════════════════════════════════════════════════

def _strip_css_comments(css):
    out, i = [], 0
    while i < len(css):
        if css.startswith("/*", i):
            j = css.find("*/", i + 2)
            i = len(css) if j < 0 else j + 2
        else:
            out.append(css[i])
            i += 1
    return "".join(out)


class CssRule(object):
    __slots__ = ("order", "selector", "decls", "conditional", "sheet")

    def __init__(self, order, selector, decls, conditional, sheet):
        self.order = order
        self.selector = selector
        self.decls = decls
        self.conditional = conditional
        self.sheet = sheet

    def __repr__(self):
        return "<%s %r%s>" % (os.path.basename(self.sheet), self.selector,
                             " @conditional" if self.conditional else "")


def _split_decls(body):
    """`prop: value` pairs, last-wins within the block, `!important` flagged."""
    out = []
    for chunk in body.split(";"):
        if ":" not in chunk:
            continue
        prop, _, value = chunk.partition(":")
        prop, value = prop.strip().lower(), value.strip()
        important = False
        if value.lower().endswith("!important"):
            value = value[: -len("!important")].strip()
            important = True
        if prop and value:
            out.append((prop, value, important))
    return out


def _walk_css(css, sheet, rules, conditional=False):
    i, n = 0, len(css)
    while i < n:
        b = css.find("{", i)
        if b < 0:
            break
        prelude = css[i:b].strip()
        depth, j = 1, b + 1
        while j < n and depth:
            if css[j] == "{":
                depth += 1
            elif css[j] == "}":
                depth -= 1
            j += 1
        body = css[b + 1:j - 1]
        if prelude.startswith("@"):
            at = prelude.split()[0].lower()
            if at in ("@media", "@supports", "@layer", "@container"):
                # Its rules DO apply, but only under a condition this resolver
                # cannot evaluate — carried through flagged so the test can
                # refuse to resolve anything one of them could reach.
                _walk_css(body, sheet, rules, conditional=True)
            # @keyframes / @font-face carry no matchable style rules.
        else:
            for sel in prelude.split(","):
                sel = " ".join(sel.split())
                if sel:
                    rules.append(CssRule(len(rules), sel, _split_decls(body),
                                         conditional, sheet))
        i = j
    return rules


def load_stylesheets(paths):
    rules = []
    for p in paths:
        with open(p) as fh:
            _walk_css(_strip_css_comments(fh.read()), p, rules)
    variables = {}
    for r in rules:
        if r.selector in (":root", "html", ":root,html"):
            for prop, value, _imp in r.decls:
                if prop.startswith("--"):
                    variables[prop] = value
    return rules, variables


_COMPOUND = re.compile(r"^([a-zA-Z][\w-]*)?((?:\.[\w-]+)+)?$")


def parse_selector(sel):
    """-> [(tag, frozenset(classes)), …] root-first, or None if unsupported."""
    if any(ch in sel for ch in "#[]:*>+~"):
        return None
    compounds = []
    for part in sel.split():
        m = _COMPOUND.match(part)
        if not m:
            return None
        tag = (m.group(1) or "").lower()
        classes = frozenset((m.group(2) or "").split(".")[1:])
        if not tag and not classes:
            return None
        compounds.append((tag, classes))
    return compounds or None


def _compound_matches(compound, node):
    tag, classes = compound
    ntag, nclasses = node
    if tag and tag != ntag:
        return False
    return classes <= nclasses


def selector_matches(compounds, chain):
    """Descendant combinators only, so right-to-left greedy is exact."""
    if not _compound_matches(compounds[-1], chain[-1]):
        return False
    ci, si = len(chain) - 2, len(compounds) - 2
    while si >= 0:
        while ci >= 0 and not _compound_matches(compounds[si], chain[ci]):
            ci -= 1
        if ci < 0:
            return False
        ci -= 1
        si -= 1
    return True


def specificity(compounds):
    return (0,
            sum(len(c[1]) for c in compounds),
            sum(1 for c in compounds if c[0]))


def resolve_value(value, variables, depth=0):
    """One-level-at-a-time var() expansion, fallbacks honoured."""
    if depth > 8:
        return value
    m = re.search(r"var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*))?\)", value)
    if not m:
        return value.strip()
    name, fallback = m.group(1), (m.group(2) or "").strip()
    sub = variables.get(name, fallback)
    return resolve_value(value[:m.start()] + sub + value[m.end():],
                         variables, depth + 1)


INHERITED = ("color", "font-weight", "font-family", "letter-spacing")


def winning_rule(prop, chain, rules):
    """The rule whose declaration of `prop` wins on the LAST node of `chain`."""
    best = None
    for r in rules:
        compounds = parse_selector(r.selector)
        if compounds is None:
            continue
        decl = None
        for p, v, imp in r.decls:          # last declaration in a block wins
            if p == prop:
                decl = (v, imp)
        if decl is None or not selector_matches(compounds, chain):
            continue
        key = (1 if decl[1] else 0, specificity(compounds), r.order)
        if best is None or key > best[0]:
            best = (key, r, decl[0])
    return best


def computed(prop, chain, rules, variables, initial=""):
    """The value that reaches the screen — this element's winning declaration,
    else (for an inherited property) the nearest ancestor's, else the initial."""
    depth = len(chain)
    while depth > 0:
        best = winning_rule(prop, chain[:depth], rules)
        if best is not None:
            return resolve_value(best[2], variables)
        if prop not in INHERITED:
            break
        depth -= 1
    return initial


def rgb(value):
    v = value.strip().lower()
    m = re.match(r"^#([0-9a-f]{3})$", v)
    if m:
        return tuple(int(c * 2, 16) for c in m.group(1))
    m = re.match(r"^#([0-9a-f]{6})$", v)
    if m:
        return tuple(int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4))
    m = re.match(r"^rgba?\(([^)]*)\)$", v)
    if m:
        parts = [p.strip() for p in re.split(r"[,\s/]+", m.group(1)) if p.strip()]
        return tuple(int(round(float(p))) for p in parts[:3])
    return v


def weight(value):
    v = (value or "").strip().lower()
    named = {"normal": 400, "bold": 700, "": 400}
    if v in named:
        return named[v]
    return int(v) if v.isdigit() else v


AMBER = (255, 170, 0)          # --lcars-amber  — "you have lost work, act"
ATTENTION_RED = (255, 138, 150)  # the board's outright-failure red
TEXT = (196, 212, 238)         # --lcars-text     (body copy)
TEXT_DIM = (80, 104, 138)      # --lcars-text-dim (`.no` metadata numbers)

# The ancestor chains the two surfaces really hang off, read from the shipping
# code: render() builds  #board.board > .col > .col-body > <card subtree>  and
# showOverlay() puts a detail in  #overlay.overlay > #overlayBody.overlay-stage.
# index.html carries them on `body.lcars-serve`. Named here because ancestry is
# half of a descendant-selector resolution — leaving it implicit is how a `.card`
# rule silently stops or starts applying.
CARD_ANCESTORS = [("html", frozenset()), ("body", frozenset(["lcars-serve"])),
                  ("div", frozenset(["board"])), ("div", frozenset(["col"])),
                  ("div", frozenset(["col-body"]))]
DETAIL_ANCESTORS = [("html", frozenset()), ("body", frozenset(["lcars-serve"])),
                    ("div", frozenset(["overlay"])),
                    ("div", frozenset(["overlay-stage"]))]


def _chain_to(root, cls, prefix):
    """The (tag, classes) chain from the document root down to the projected
    node carrying `cls` — i.e. exactly what a descendant selector sees."""
    def walk(node, acc):
        step = acc + [(node["tag"].lower(), frozenset((node["cls"] or "").split()))]
        if cls in (node["cls"] or "").split():
            return step
        for child in node.get("children", []):
            hit = walk(child, step)
            if hit:
                return hit
        return None
    return walk(root, list(prefix))


@unittest.skipIf(NODE is None, "node is required to run the board.js harness")
class FilingStatusStyleTest(unittest.TestCase):
    """The status line reaches the screen at the urgency its words carry.

    Every assertion here is a MEASUREMENT of the shipping pair — the class list
    `logFilingNote` emits, cascaded against the real `lcars.css` + `board.css` —
    never a search for a rule in a stylesheet. The rule was always there; it was
    losing.
    """

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = load_stylesheets(CSS_SHEETS)

    # The states this line can END on, and what each must look like once the
    # cascade has run. Read the statuses out of the SHIPPING source so a new
    # terminal sibling fails this test closed instead of shipping unstyled.
    #   filed   → renders nothing at all (the bugs are simply there)
    #   partial → the captain LOST work: amber, and as heavy as the failure line
    #   failed  → nothing landed: the board's attention red, heavy
    EXPECTED = {
        "filed": None,
        "partial": {"classes": {"log-filing-status"},
                    "color": AMBER, "font-weight": 700},
        "failed": {"classes": {"log-filing-status", "failed"},
                   "color": ATTENTION_RED, "font-weight": 700},
    }

    def _terminal_statuses(self):
        with open(BOARD_JS) as fh:
            m = re.search(r"var LOG_FILING_TERMINAL\s*=\s*\[([^\]]*)\]", fh.read())
        self.assertIsNotNone(m, "LOG_FILING_TERMINAL must stay readable here — "
                                "this table is what keeps a new status honest")
        return [s.strip().strip('"\'') for s in m.group(1).split(",") if s.strip()]

    def test_the_expectation_table_covers_every_terminal_status(self):
        """The guard that stops this suite flattering itself. If a fourth
        terminal status appears and nobody says what it should look like, this
        fails — rather than the new status quietly rendering as a grey number."""
        self.assertEqual(sorted(self._terminal_statuses()),
                         sorted(self.EXPECTED.keys()))

    def test_the_resolver_sees_every_rule_that_could_reach_the_line(self):
        """Honesty check on the measurement itself. A rule the resolver cannot
        parse, or one gated behind an @media it cannot evaluate, would make every
        assertion below a statement about a stylesheet that is not the one the
        browser reads. There must be none that could touch this element."""
        touchable = {"log-filing-status", "failed", "no", "log-filing-note",
                     "card", "det-head"}
        for r in self.rules:
            mentions = set(re.findall(r"\.([\w-]+)", r.selector)) & touchable
            # Only the properties this test resolves matter. `.card:hover`'s
            # box-shadow is genuinely beyond the resolver and genuinely
            # irrelevant; a `.card:hover{color:…}` would not be, and would fail
            # here rather than quietly invalidating every colour below.
            if not mentions or not {p for p, _v, _i in r.decls} & set(INHERITED):
                continue
            self.assertIsNotNone(
                parse_selector(r.selector),
                "unparseable rule that could reach the status line: %r" % (r,))
            self.assertFalse(
                r.conditional,
                "conditional rule could reach the status line: %r" % (r,))

    def _line(self, status, mode):
        stamp = _stamp(status, filed_count=(1 if status == "partial" else 0),
                       error="the daemon's own words")
        res = _drive(dict(VERIFY, logFiling=stamp), mode=mode)
        found = _classes(res, "log-filing-status")
        prefix = CARD_ANCESTORS if mode == "card" else DETAIL_ANCESTORS
        chain = _chain_to(res["node"], "log-filing-status", prefix)
        return found, chain

    def _assert_status_reads(self, status, mode):
        want = self.EXPECTED[status]
        found, chain = self._line(status, mode)
        if want is None:
            self.assertEqual(found, [],
                             "%s must render no status line (%s)" % (status, mode))
            return
        self.assertEqual(len(found), 1, "%s/%s" % (status, mode))
        got_classes = set((found[0]["cls"] or "").split())
        self.assertEqual(
            got_classes, want["classes"],
            "%s/%s emits %r — the class list is half of the cascade, so it is "
            "pinned: `no` in particular hands this line `.card .no`'s dim grey "
            "at a specificity it cannot beat" % (status, mode, sorted(got_classes)))
        colour = rgb(computed("color", chain, self.rules, self.vars))
        self.assertEqual(
            colour, want["color"],
            "%s/%s resolves to %r, not %r — the amber rule exists in board.css "
            "and still never reaches the screen" % (status, mode, colour,
                                                    want["color"]))
        self.assertNotEqual(colour, TEXT_DIM,
                            "%s/%s reads as an ordinary metadata number" %
                            (status, mode))
        self.assertEqual(
            weight(computed("font-weight", chain, self.rules, self.vars,
                            initial="400")), want["font-weight"],
            "%s/%s must carry the same weight as the failure line — losing half "
            "the captain's bugs is not a lighter event than losing all of them"
            % (status, mode))

    def test_every_terminal_status_reads_correctly_on_the_card(self):
        for status in self._terminal_statuses():
            with self.subTest(status=status):
                self._assert_status_reads(status, "card")

    def test_every_terminal_status_reads_correctly_in_the_detail(self):
        """The detail hangs off `.det-head`, not `.card`, so it resolves through
        a different ancestor chain — measured separately rather than assumed to
        match (the align_overlay_mission lesson, applied to the cascade)."""
        for status in self._terminal_statuses():
            with self.subTest(status=status):
                self._assert_status_reads(status, "detail")

    def test_the_headline_is_louder_than_the_reason_underneath_it(self):
        """The tester's actual complaint, stated as a relation rather than a
        colour: the headline was DIMMER than its own explanatory text. Pinned as
        a distinct attention hue plus a heavier weight — deliberately not as a
        luminance comparison, because `--lcars-amber` is louder than body copy by
        saturation, not brightness, and a luminance assertion would be false."""
        for mode in ("card", "detail"):
            for status in ("partial", "failed"):
                _found, head_chain = self._line(status, mode)
                res = _drive(dict(VERIFY, logFiling=_stamp(
                    status, filed_count=1, error="why")), mode=mode)
                prefix = CARD_ANCESTORS if mode == "card" else DETAIL_ANCESTORS
                body_chain = _chain_to(res["node"], "log-filing-detail", prefix)
                self.assertIsNotNone(body_chain)
                head_c = rgb(computed("color", head_chain, self.rules, self.vars))
                body_c = rgb(computed("color", body_chain, self.rules, self.vars))
                self.assertEqual(body_c, TEXT, "%s/%s reason line" % (status, mode))
                self.assertNotEqual(head_c, body_c,
                                    "%s/%s headline is indistinguishable from "
                                    "its own reason text" % (status, mode))
                head_w = weight(computed("font-weight", head_chain, self.rules,
                                         self.vars, initial="400"))
                body_w = weight(computed("font-weight", body_chain, self.rules,
                                         self.vars, initial="400"))
                self.assertGreater(head_w, body_w,
                                   "%s/%s headline is no heavier than the small "
                                   "print under it" % (status, mode))

    def test_the_resolver_reproduces_a_known_win_and_a_known_loss(self):
        """A resolver that returned the LAST rule mentioning a class, or simply
        the amber it was hoping for, would pass everything above. So calibrate it
        on two facts measured in a live page: an ordinary `.no` metadata line
        resolves to the dim slate, and `.card .no` beats `.card .reconcile-status`
        on source order even though the sheet plainly sets that one amber."""
        no_chain = CARD_ANCESTORS + [("div", frozenset(["card"])),
                                     ("div", frozenset(["no"]))]
        self.assertEqual(
            rgb(computed("color", no_chain, self.rules, self.vars)), TEXT_DIM)
        rec_chain = CARD_ANCESTORS + [
            ("div", frozenset(["card"])),
            ("div", frozenset(["no", "reconcile-status", "healing"]))]
        self.assertEqual(
            rgb(computed("color", rec_chain, self.rules, self.vars)), TEXT_DIM,
            "the resolver must reproduce the LOSS as well as the win — if this "
            "ever comes back amber, `.card .reconcile-status` was fixed and this "
            "calibration should follow it, not be deleted")


if __name__ == "__main__":
    unittest.main()
