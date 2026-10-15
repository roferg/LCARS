"""S201 wave B — NUMBER ONE ON THE BOARD: the payload, the card, the band.

Four things are pinned here, in this order of importance:

  1. THE BOARD WITHOUT NUMBER ONE IS UNCHANGED. A repo whose config carries no
     `numberOne` block and whose missions record none must serve a card payload
     — and render a card — BYTE-IDENTICAL to the one it served before this
     wave. `numberOne` is ABSENT, never null, on both the card and meta: the
     rule every additive key in this shape has followed since S109.

  2. THE VOCABULARY IS THE CAPTAIN'S, VERBATIM. The pill says only
     "◈ NUMBER ONE · ENGAGED" while engaged and hollow FINISHED / ESCALATED /
     ANSWERED after; it never says "fixing"; and NO PRICING WORD ("free",
     "billed", "cost") appears anywhere in the product copy this wave adds.
     Both are asserted against the shipped board.js and index.html, not against
     a paraphrase.

  3. THE SWEEP MATCHES THE SERVER, EXACTLY. board.js disables precisely the
     verbs `server._XO_LOCKED_VERBS` refuses and no more — the S190 rule that a
     DOM sweep is always paired with a server refusal (board.js:1022-1032). The
     sentence in the tooltip is read out of `ownership.sh`, so the three
     surfaces cannot tell the captain three different stories.

  4. THE BAND GAINS A CONTROL AND MOVES NOTHING. The toggle is added BEFORE
     #deployMainBtn; every existing control keeps its id, its label and its
     order (test_help_console's band-parity test is the other half of this).

No gh, no network, no model, no worker: every fact here is a local file read.
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
from lcars_serve import board as board_shape  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server, _XO_LOCKED_VERBS  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

STATIC = os.path.normpath(os.path.join(HERE, "..", "static"))
OWNERSHIP = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-run", "ownership.sh"))
CARD_HARNESS = os.path.join(HERE, "board_owner_harness.js")
XO_HARNESS = os.path.join(HERE, "board_xo_harness.js")
NODE = shutil.which("node")

# The captain's ruling of 2026-09-11: the picker names engines and nothing else.
PRICING_WORDS = ("free", "billed", "cost")


def plant_number_one(root, mid, block):
    """Write `numberOne` exactly the way the shipped writers write it — one
    line, at the TOP of state.json (the S189 rule; see test_xo_lock_endpoints)."""
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    with open(path) as fh:
        json.load(fh)          # still valid JSON, which is the point
    return path


def write_config(root, obj):
    d = os.path.join(root, ".git", "lcars")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "config.json")
    with open(p, "w") as fh:
        json.dump(obj, fh, indent=2)
    return p


# ════════════════════════ 1. THE CARD PAYLOAD ════════════════════════

class CardPayloadIsAdditive(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-plain", stage="verify", issue=101)
        fx.plant_simple(self.tmp, "m-xo", stage="verify", issue=102)
        self.adapter = LocalAdapter(self.tmp)

    def card(self, mid):
        for c in self.adapter.board()["missions"]:
            if c["id"] == mid:
                return c
        self.fail("no card for %s" % mid)

    def test_a_mission_with_no_numberOne_key_carries_none(self):
        self.assertNotIn("numberOne", self.card("m-plain"))

    def test_the_key_is_absent_not_null(self):
        """The whole byte-identity guarantee in one assertion: a `None` value
        would serialise as `"numberOne": null` and change every payload."""
        blob = json.dumps(self.adapter.board(), sort_keys=True)
        self.assertNotIn('"numberOne"', blob)

    def test_an_engaged_mission_carries_the_recorded_block(self):
        plant_number_one(self.tmp, "m-xo", {
            "status": "engaged", "engine": "copilot",
            "since": "2026-09-12T01:00:00Z", "note": "waiting on the launch"})
        x = self.card("m-xo")["numberOne"]
        self.assertEqual("engaged", x["status"])
        self.assertEqual("copilot", x["engine"])
        self.assertEqual("2026-09-12T01:00:00Z", x["since"])
        self.assertEqual("waiting on the launch", x["note"])

    def test_only_recorded_fields_appear(self):
        plant_number_one(self.tmp, "m-xo", {"status": "engaged"})
        self.assertEqual({"status": "engaged"}, self.card("m-xo")["numberOne"])

    def test_the_score_rides_when_recorded(self):
        plant_number_one(self.tmp, "m-xo",
                         {"status": "finished", "score": "HIGH"})
        self.assertEqual("HIGH", self.card("m-xo")["numberOne"]["score"])

    def test_a_bare_optout_records_no_card_block(self):
        """`lcars xo off <id>` on a mission Number One never held writes only
        `optOut`. That is a fact about a future engagement, not a state the card
        has anything to draw — so the card is byte-identical to before."""
        plant_number_one(self.tmp, "m-xo", {"optOut": True})
        self.assertNotIn("numberOne", self.card("m-xo"))

    def test_a_malformed_block_never_reaches_the_card(self):
        path = os.path.join(fx.mission_dir(self.tmp, "m-xo"), "state.json")
        with open(path) as fh:
            lines = fh.read().splitlines(True)
        lines.insert(1, '  "numberOne": "engaged",\n')
        with open(path, "w") as fh:
            fh.writelines(lines)
        self.assertNotIn("numberOne", self.card("m-xo"))

    def test_the_shape_builder_answers_None_for_nothing_recorded(self):
        self.assertIsNone(board_shape.xo_block(None))
        self.assertIsNone(board_shape.xo_block({}))
        self.assertIsNone(board_shape.xo_block("engaged"))
        self.assertIsNone(board_shape.xo_block({"optOut": True}))


# ════════════════════════ 2. THE BOARD-LEVEL TOGGLE ════════════════════

class MetaCarriesTheRepoToggle(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-1", stage="align", issue=101)

    def meta(self):
        return LocalAdapter(self.tmp).board()["meta"]

    def test_no_config_no_key(self):
        self.assertNotIn("numberOne", self.meta())

    def test_a_config_without_the_block_carries_no_key(self):
        write_config(self.tmp, {"model": "claude-sonnet"})
        self.assertNotIn("numberOne", self.meta())

    def test_off_is_reported_as_off(self):
        write_config(self.tmp, {"numberOne": {"enabled": False}})
        self.assertEqual({"enabled": False}, self.meta()["numberOne"])

    def test_on_carries_the_engine(self):
        write_config(self.tmp,
                     {"numberOne": {"enabled": True, "engine": "copilot"}})
        self.assertEqual({"enabled": True, "engine": "copilot"},
                         self.meta()["numberOne"])

    def test_a_malformed_block_is_ignored(self):
        write_config(self.tmp, {"numberOne": "yes"})
        self.assertNotIn("numberOne", self.meta())


# ════════════════════════ 3. THE ENDPOINTS ════════════════════════════

def _record_stub(record_path):
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\n'
                 'printf "ARGV: %s\\n" "$*" >> "' + record_path + '"\n'
                 'exit 0\n')
    os.chmod(path, 0o755)
    return path


class XoEndpoints(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-1", stage="verify", issue=101)
        self.rec = os.path.join(self.tmp, "rec-xo.txt")
        self.actions = Actions(repo_root=self.tmp,
                               scripts={"xo": _record_stub(self.rec)},
                               worker_bin="/bin/echo")
        self.httpd = make_server(LocalAdapter(self.tmp), host="127.0.0.1",
                                 port=0, poll_interval=0.05,
                                 actions=self.actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(
            url, data=json.dumps(obj or {}).encode(), method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def argv(self):
        with open(self.rec) as fh:
            return [l.strip() for l in fh if l.strip()]

    def test_on_dispatches_the_verb_with_the_chosen_engine(self):
        status, payload = self.post("/api/xo/on", {"engine": "copilot"})
        self.assertEqual(200, status, payload)
        self.assertTrue(payload.get("ok"), payload)
        self.assertEqual(["ARGV: on --engine copilot"], self.argv())

    def test_on_refuses_an_engine_that_is_not_a_name(self):
        status, _ = self.post("/api/xo/on", {"engine": "--help"})
        self.assertEqual(400, status)
        self.assertFalse(os.path.exists(self.rec))

    def test_off_stands_the_whole_repo_down(self):
        status, payload = self.post("/api/xo/off")
        self.assertEqual(200, status, payload)
        self.assertEqual(["ARGV: off"], self.argv())

    def test_off_on_one_mission_names_it(self):
        status, payload = self.post("/api/xo/off/m-1")
        self.assertEqual(200, status, payload)
        self.assertEqual(["ARGV: off m-1"], self.argv())

    def test_a_mission_that_is_not_here_is_a_404(self):
        status, _ = self.post("/api/xo/off/m-nope")
        self.assertEqual(404, status)

    def test_an_unknown_xo_verb_is_a_404(self):
        status, _ = self.post("/api/xo/engage")
        self.assertEqual(404, status)


class XoEndpointsAreViewOnlySafe(unittest.TestCase):

    def test_a_read_only_daemon_refuses_both(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        fx.plant_simple(tmp, "m-1", stage="align", issue=101)
        httpd = make_server(LocalAdapter(tmp), host="127.0.0.1", port=0,
                            poll_interval=0.05, actions=None)
        port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        for path in ("/api/xo/on", "/api/xo/off", "/api/xo/off/m-1"):
            req = urllib.request.Request(
                path and "http://127.0.0.1:%d%s" % (port, path),
                data=b"{}", method="POST",
                headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    self.fail("%s was accepted on a view-only build (%s)"
                              % (path, r.status))
            except urllib.error.HTTPError as exc:
                self.assertEqual(403, exc.code, path)


# ════════════════════════ 4. THE SOURCE — vocabulary + band ════════════

class TheVocabularyIsTheCaptains(unittest.TestCase):

    def setUp(self):
        with open(os.path.join(STATIC, "board.js")) as fh:
            self.js = fh.read()
        with open(os.path.join(STATIC, "index.html")) as fh:
            self.html = fh.read()
        with open(os.path.join(STATIC, "board.css")) as fh:
            self.css = fh.read()

    def test_the_engaged_pill_says_exactly_that(self):
        self.assertIn('"◈ NUMBER ONE · ENGAGED"', self.js)

    def test_the_finished_states_are_the_three_the_captain_named(self):
        for label in ('"◈ NUMBER ONE · FINISHED"', '"◈ ESCALATED"',
                      '"◈ ANSWERED"'):
            self.assertIn(label, self.js, label)

    def test_it_never_says_fixing(self):
        """Fixes show through the board's own `◐ resolving N logged bugs…`
        control, which already exists. Number One's pill never claims them."""
        for m in re.finditer(r'"[^"\n]*NUMBER ONE[^"\n]*"', self.js):
            self.assertNotIn("fix", m.group(0).lower(), m.group(0))

    def test_no_pricing_word_appears_in_the_copy_this_wave_adds(self):
        """The captain's ruling: not everyone's situation is his. The picker
        names engines and says installed / not installed, and nothing else."""
        blocks = re.findall(r"/\* ═+ S201.*?(?=\n/\* ═|\Z)", self.js, re.S)
        self.assertTrue(blocks, "the S201 board.js section is not marked")
        body = "".join(blocks)
        for m in re.finditer(r'"([^"\n]*)"', body):
            text = m.group(1)
            if not re.search(r"[A-Za-z]{3}\s+[A-Za-z]{3}", text):
                continue          # class names / selectors, not prose
            for word in PRICING_WORDS:
                self.assertNotIn(word, text.lower(),
                                 "%r is product copy naming a price" % text)

    def test_the_picker_labels_are_installed_or_not_installed(self):
        self.assertIn('"installed"', self.js)
        self.assertIn('"not installed"', self.js)

    def test_the_confirm_and_the_cancel_are_the_captains_words(self):
        self.assertIn('"◈ Engage"', self.js)
        self.assertIn('"Cancel"', self.js)

    def test_the_stand_down_control_is_the_captains_words(self):
        self.assertIn('"■ Stand down"', self.js)

    def test_the_legend_entries_are_the_captains_words(self):
        self.assertIn('"Number One engaged for you"', self.js)
        self.assertIn('"Number One finished · score"', self.js)

    def test_the_band_labels_are_the_captains_words(self):
        self.assertIn('"◈ Number One · OFF"', self.js)
        self.assertIn("◈ Number One · ON · ", self.js)

    def test_the_score_pill_names_three_shared_tokens_and_no_new_colour(self):
        """S203. Teal / amber / red are the board's own three-level vocabulary
        and the tints are the SAME rgba values the difficulty pills use — this
        sheet adds no colour of its own (ADR-007). The hex guard below covers
        this block too; this one pins that it uses the TOKENS by name."""
        block = re.search(r"/\* ── S203: THE INTENT-MATCH PILL.*?(?=\n/\* )",
                          self.css, re.S)
        self.assertIsNotNone(block, "the S203 board.css section is not marked")
        body = block.group(0)
        for token in ("--lcars-teal", "--lcars-amber", "--lcars-red"):
            self.assertIn(token, body)
        self.assertEqual([], re.findall(r"#[0-9a-fA-F]{3,8}", body),
                         "the score pill declares a raw colour of its own")

    def test_the_score_pill_never_says_a_bare_level_word(self):
        """Never a bare HIGH/MEDIUM/LOW: the card already has two pills with
        that exact vocabulary and the opposite polarity. S213 changed which
        words do the naming (`◈ NUMBER ONE ·` in place of `INTENT MATCH ·`,
        the approved mock-up) — the rule is the same rule."""
        self.assertIn('"◈ NUMBER ONE · " + XO_SCORE_WORD[s]', self.js)

    def test_the_accent_is_the_shared_peach_token_and_no_new_colour(self):
        """ADR-007: this sheet adds no colour of its own. Every declaration the
        wave adds names --lcars-peach (with the sheet's own existing fallback)
        or an existing token."""
        block = re.search(r"/\* ═+ S201.*?(?=\n/\* ═|\Z)", self.css, re.S)
        self.assertIsNotNone(block, "the S201 board.css section is not marked")
        body = block.group(0)
        self.assertIn("--lcars-peach", body)
        for hexcol in re.findall(r"#[0-9a-fA-F]{3,8}", body):
            self.assertIn(hexcol.lower(), ("#ff9966", "#030608"),
                          "%s is a new colour value, not a token fallback"
                          % hexcol)


class TheBandGainsOneControlAndMovesNothing(unittest.TestCase):

    def setUp(self):
        with open(os.path.join(STATIC, "index.html")) as fh:
            self.html = fh.read()
        i = self.html.index('<div class="frame-top topbar">')
        j = self.html.index("\n  </div>", i)
        self.band = self.html[i:j]

    def test_the_band_carries_the_toggle(self):
        self.assertIn('id="xoBtn"', self.band)

    def test_it_sits_before_the_deploy_control(self):
        self.assertLess(self.band.index('id="xoBtn"'),
                        self.band.index('id="deployMainBtn"'),
                        "the toggle is placed BEFORE ▸ Deploy Main")

    def test_every_pre_existing_control_keeps_its_place(self):
        ids = re.findall(r'id="([A-Za-z]+)"', self.band)
        ids = [i for i in ids if i != "xoBtn"]
        self.assertEqual(["repoMeta", "mainDeploy", "deployMainBtn",
                          "holodeckBtn", "fileBtn", "helpBtn", "conn"], ids)

    def test_the_toggle_is_a_btn_like_its_neighbours(self):
        m = re.search(r'<button([^>]*)id="xoBtn"([^>]*)>', self.band)
        self.assertIsNotNone(m, "the toggle must be a <button>")
        self.assertIn('class="btn', m.group(1) + m.group(2))


# ════════════════════════ 5. THE RENDER ════════════════════════════════

def _render_card(mission, self_login=None, readonly=False, click=None):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"mission": mission, "self": self_login,
                       "readonly": readonly, "click": click}, fh)
        out = subprocess.check_output([NODE, CARD_HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _render_band(meta, readonly=False, click=None):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"meta": meta, "readonly": readonly, "click": click}, fh)
        out = subprocess.check_output([NODE, XO_HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _nodes(tree):
    yield tree
    for c in tree.get("children", []):
        for n in _nodes(c):
            yield n


def _find(tree, pred):
    return [n for n in _nodes(tree) if pred(n)]


def _cls(n, name):
    return name in (n.get("cls") or "").split()


def _texts(tree):
    return [n.get("text") or "" for n in _nodes(tree)]


def card(**over):
    m = {"id": "m-1", "issue": 142, "title": "Add gamification",
         "stage": "verify", "prUrl": "https://github.com/acme/repo/pull/7",
         "review": "open"}
    m.update(over)
    return m


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheEngagedCard(unittest.TestCase):

    def test_a_card_with_no_block_gains_nothing(self):
        tree = _render_card(card())
        self.assertFalse(_find(tree, lambda n: _cls(n, "xo-engaged")))
        self.assertFalse(_find(tree, lambda n: _cls(n, "pill") and
                               "NUMBER ONE" in (n.get("text") or "")))

    def test_the_engaged_card_wears_the_marker_class(self):
        tree = _render_card(card(numberOne={"status": "engaged",
                                            "engine": "copilot"}))
        self.assertTrue(_cls(tree, "xo-engaged"))

    def test_the_engaged_pill_is_solid_and_says_engaged(self):
        tree = _render_card(card(numberOne={"status": "engaged"}))
        pills = _find(tree, lambda n: _cls(n, "xo"))
        self.assertTrue(pills)
        self.assertEqual("◈ NUMBER ONE · ENGAGED", pills[0]["text"])
        self.assertFalse(_cls(pills[0], "done"),
                         "an ENGAGED pill is solid, never hollow")

    def test_the_finished_states_are_hollow(self):
        for status, label in (("finished", "◈ NUMBER ONE · FINISHED"),
                              ("escalated", "◈ ESCALATED"),
                              ("answered", "◈ ANSWERED")):
            tree = _render_card(card(numberOne={"status": status}))
            pill = _find(tree, lambda n: _cls(n, "xo"))[0]
            self.assertEqual(label, pill["text"], status)
            self.assertTrue(_cls(pill, "done"),
                            "a finished pill is hollow (%s)" % status)
            self.assertFalse(_cls(tree, "xo-engaged"),
                             "only ENGAGED gives the card the peach edge")

    def test_a_stood_down_mission_shows_the_note_and_no_pill(self):
        tree = _render_card(card(numberOne={
            "status": "stood-down",
            "note": "Number One stood down 01:14 · you have the conn"}))
        self.assertFalse(_find(tree, lambda n: _cls(n, "xo")))
        notes = _find(tree, lambda n: _cls(n, "xo-note"))
        self.assertEqual(1, len(notes))
        self.assertIn("you have the conn", notes[0]["text"])

    def test_the_line_says_what_it_is_doing_now(self):
        tree = _render_card(card(numberOne={"status": "engaged",
                                            "engine": "copilot"}))
        lines = _find(tree, lambda n: _cls(n, "xo-line"))
        self.assertEqual(1, len(lines))
        self.assertIn("has the conn", lines[0]["text"])

    def test_the_line_never_claims_a_fix(self):
        for status in ("engaged", "finished", "escalated", "answered"):
            tree = _render_card(card(numberOne={"status": status}))
            for n in _find(tree, lambda n: _cls(n, "xo-line")):
                self.assertNotIn("fix", (n.get("text") or "").lower())

    def test_the_score_rides_the_card_wherever_it_is_shown(self):
        """S213 MOVED IT, and did not lose it. A card that HAS a verdict is now
        a signal: one pill carrying the score, one line of verdict, one way in.
        The `xo-line` ("Number One handed the conn back · scored HIGH") said
        the score a second time in a second place, so it is no longer drawn
        beside the pill that already says it — but the score itself is still on
        the card, which is what this test has always been about."""
        tree = _render_card(card(numberOne={"status": "finished",
                                            "score": "HIGH"}))
        pill = _find(tree, lambda n: _cls(n, "xo-score"))[0]
        self.assertIn("HIGH", pill["text"])
        self.assertFalse(_find(tree, lambda n: _cls(n, "xo-line")),
                         "the score is said twice on one card")


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class DoneMissionsDoNotHaveTheConn(unittest.TestCase):

    def test_pause_posture_is_only_live_before_done(self):
        note = "Number One stood down 01:14 · you have the conn"
        for stage in ("done", "implement", "verify"):
            for running in (False, True):
                with self.subTest(stage=stage, running=running):
                    tree = _render_card(card(
                        stage=stage, paused=True, running=running,
                        numberOne={"status": "stood-down", "note": note}))
                    self.assertIn(note, _texts(tree))
                    self.assertFalse(_cls(tree, "running"),
                                     "a retained pause must not become running")
                    self.assertEqual(stage != "done", _cls(tree, "paused"),
                                     "only nonterminal cards are dimmed")
                    labels = [n["text"] for n in _find(
                        tree, lambda n: _cls(n, "pause-status"))]
                    expected = [] if stage == "done" else [
                        "◐ PAUSING — stopping at next safe boundary"
                        if running else "⏸ paused"]
                    self.assertEqual(expected, labels)

    def test_done_cards_offer_no_first_officer_write_controls(self):
        for score in (None, "high"):
            with self.subTest(score=score):
                xo = {"status": "engaged", "engine": "copilot"}
                if score:
                    xo["score"] = score
                tree = _render_card(card(stage="done", numberOne=xo))
                buttons = _find(tree, lambda n: n.get("tag") == "button")
                self.assertTrue(all(n.get("attrs", {}).get("data-act")
                                    == "xo-report" for n in buttons),
                                "a done card offers a write control: %r" %
                                [n["text"] for n in buttons])

    def test_done_unscored_cards_make_no_live_engagement_claim(self):
        tree = _render_card(card(stage="done", numberOne={
            "status": "engaged", "engine": "copilot"}))
        self.assertNotIn("◈ NUMBER ONE · ENGAGED", _texts(tree))
        self.assertFalse(any("has the conn" in t for t in _texts(tree)))
        self.assertFalse(_cls(tree, "xo-engaged"))

    def test_done_scored_cards_keep_the_grade_and_report_not_a_live_lock(self):
        tree = _render_card(card(stage="done", numberOne={
            "status": "engaged", "score": "high",
            "meaning": "Every stated criterion is met."}))
        self.assertEqual(["◈ NUMBER ONE · HIGH"], [
            n["text"] for n in _find(tree, lambda n: _cls(n, "xo-score"))])
        self.assertTrue(_find(tree, lambda n:
                             n.get("attrs", {}).get("data-act") == "xo-report"
                             and not n.get("disabled")))
        self.assertFalse(any("stand it down" in (n.get("title") or "")
                             for n in _nodes(tree)))
        self.assertFalse(_cls(tree, "xo-engaged"))

    def test_done_scored_cards_do_not_resurface_the_engaged_transcript(self):
        tree = _render_card(card(stage="done", numberOne={
            "status": "engaged", "score": "high",
            "note": "Historical worker transcript, not a current activity."}))
        self.assertFalse(_find(tree, lambda n: _cls(n, "xo-note")))

    def test_nonterminal_stages_keep_engaged_controls_even_when_paused(self):
        for stage in ("research", "implement", "verify"):
            with self.subTest(stage=stage):
                tree = _render_card(card(stage=stage, paused=True,
                                         numberOne={"status": "engaged"}))
                self.assertTrue(_cls(tree, "xo-engaged"))
                self.assertTrue(any("has the conn" in t for t in _texts(tree)))
                self.assertTrue(_find(tree, lambda n:
                                     _cls(n, "xo-stand-down")
                                     and not n.get("disabled")))

    def test_done_cards_keep_recorded_finished_history(self):
        tree = _render_card(card(stage="done", numberOne={
            "status": "finished", "note": "Number One completed the review."}))
        self.assertIn("◈ NUMBER ONE · FINISHED", _texts(tree))
        self.assertIn("Number One completed the review.", _texts(tree))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheIntentMatchPill(unittest.TestCase):
    """S203 — the SCORE on the card, and the one thing that makes it readable.

    The card already wears two pills whose whole vocabulary is LOW / MED / HIGH
    — the reasoning and implementation DIFFICULTY of the work. A bare HIGH
    beside them is not merely vague, it is vague in the direction that inverts
    the meaning: a high difficulty is bad news and a high intent match is the
    best news on the card. So the words INTENT MATCH are part of the pill, and
    that is what this class pins."""

    def test_the_pill_names_what_it_is_measuring(self):
        """S213 changed the WORDS and kept the RULE. The pill used to read
        `INTENT MATCH · MEDIUM` beside a second pill reading `◈ NUMBER ONE ·
        ENGAGED` — two pills spent saying one thing, with the half that matters
        underneath. Now one pill says both. What has NOT changed, and is what
        this test is for, is that the level word never appears bare: the two
        DIFFICULTY pills beside it read LOW/MED/HIGH with the opposite
        polarity, so the pill must always name whose level it is."""
        for score, word in (("high", "HIGH"), ("medium", "MEDIUM"),
                            ("low", "LOW")):
            tree = _render_card(card(numberOne={"status": "finished",
                                                "score": score}))
            pills = _find(tree, lambda n: _cls(n, "xo-score"))
            self.assertEqual(1, len(pills), score)
            self.assertEqual("◈ NUMBER ONE · " + word, pills[0]["text"])

    def test_it_never_reads_as_a_difficulty_pill(self):
        """The two vocabularies never share a class, in either direction: a
        difficulty pill is `.pill.high`, the intent match is `.pill.xo-score
        .s-high`, and the sheet colours them oppositely on purpose."""
        tree = _render_card(card(numberOne={"score": "high"}))
        pill = _find(tree, lambda n: _cls(n, "xo-score"))[0]
        self.assertTrue(_cls(pill, "s-high"))
        for difficulty in ("low", "med", "high"):
            self.assertFalse(_cls(pill, difficulty),
                             "the score pill wears the DIFFICULTY class %r"
                             % difficulty)

    def test_a_card_with_no_score_gains_no_pill(self):
        for block in ({"status": "engaged"}, {"status": "finished"}):
            tree = _render_card(card(numberOne=block))
            self.assertFalse(_find(tree, lambda n: _cls(n, "xo-score")),
                             str(block))

    def test_a_score_this_board_cannot_name_is_not_painted(self):
        """The posture `xoBlock` already takes on a malformed block: an
        unreadable record is nothing recorded, never a guess."""
        for bad in ("HIGHEST", "", "3", "ok"):
            tree = _render_card(card(numberOne={"score": bad}))
            self.assertFalse(_find(tree, lambda n: _cls(n, "xo-score")),
                             repr(bad))

    def test_the_score_alone_is_enough_to_draw_the_block(self):
        """THE REMOTE CASE. A forge-read card carries `{score}` and nothing
        else — no engine, no since, no note, because those are local facts —
        and it must still show the verdict."""
        tree = _render_card(card(numberOne={"score": "medium"}))
        self.assertTrue(_find(tree, lambda n: _cls(n, "xo-block")))
        pills = _find(tree, lambda n: _cls(n, "xo-score"))
        self.assertEqual("◈ NUMBER ONE · MEDIUM", pills[0]["text"])

    def test_a_scored_card_wears_exactly_one_number_one_pill(self):
        """S213 RETIRED the two-pill row, on the captain's approved mock-up.
        `◈ NUMBER ONE · FINISHED` + `INTENT MATCH · LOW` was the status said
        twice and the verdict said once; one pill now carries both, and the
        status the old pill named is implied by there being a verdict at all.
        The two-pill row still exists for a mission with no verdict YET — that
        is `test_a_card_with_no_score_gains_no_pill`'s side of the fork."""
        tree = _render_card(card(numberOne={"status": "finished",
                                            "score": "low"}))
        row = _find(tree, lambda n: _cls(n, "xo-pills"))[0]
        texts = [c.get("text") or "" for c in row["children"]]
        self.assertEqual(["◈ NUMBER ONE · LOW"], texts)

    def test_the_meaning_rides_the_tooltip_when_a_ledger_recorded_one(self):
        """S203 put three fixed sentences here, one per score word, and pinned
        LOW's. S213 fix round 3 took them out: a sentence kept per WORD is a
        claim about EVERY build that wears it, and MEDIUM's was telling the
        captain his primary flow worked on builds nothing could be checked on.
        What the word means HERE comes off this mission's own ledger — recorded
        beside the score, or derived from the verdict's counts by the adapter —
        and rides the block as `meaning`."""
        said = "I could not check any of the 11 things on your list"
        tree = _render_card(card(numberOne={"score": "low", "meaning": said}))
        pill = _find(tree, lambda n: _cls(n, "xo-score"))[0]
        self.assertEqual(said, pill.get("title") or "")

    def test_and_a_card_with_no_ledger_behind_it_asserts_nothing(self):
        """THE REMOTE CASE, and every mission scored before fix round 1. The
        pill is still painted — the verdict is real — but nothing explains it,
        because nothing on this board knows what it meant."""
        tree = _render_card(card(numberOne={"score": "low"}))
        pill = _find(tree, lambda n: _cls(n, "xo-score"))[0]
        self.assertEqual("", pill.get("title") or "")


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheEngagedSweep(unittest.TestCase):
    """A DOM sweep is ALWAYS paired with a server refusal (board.js:1022-1032).
    These two tests are that pairing, read off both files."""

    ENGAGED = {"status": "engaged", "engine": "copilot"}

    def ctrl(self, m):
        tree = _render_card(m)
        hosts = _find(tree, lambda n: _cls(n, "card-ctrl"))
        out = []
        for h in hosts:
            out += _find(h, lambda n: n["tag"] == "button")
        return out

    def test_every_control_the_server_403s_is_disabled(self):
        buttons = self.ctrl(card(numberOne=self.ENGAGED))
        live = [b for b in buttons
                if not b["disabled"] and not _cls(b, "xo-stand-down")]
        self.assertEqual([], [b["text"] for b in live],
                         "a live write control on an engaged mission")

    def test_the_tooltip_is_the_sentence_the_daemon_refuses_with(self):
        with open(OWNERSHIP) as fh:
            src = fh.read()
        m = re.search(r"printf '(Number One is engaged[^']*)'", src)
        self.assertIsNotNone(m, "ownership.sh no longer carries the sentence")
        expected = m.group(1).replace("%s", "m-1")
        buttons = [b for b in self.ctrl(card(numberOne=self.ENGAGED))
                   if b["disabled"] and not _cls(b, "xo-stand-down")]
        self.assertTrue(buttons)
        for b in buttons:
            self.assertEqual(expected, b["title"], b["text"])

    def test_start_is_not_swept_the_server_does_not_refuse_it(self):
        """`start` is the ONE verb in the owner set the engaged set drops — an
        engaged mission is already being driven, through this very door."""
        self.assertNotIn("start", _XO_LOCKED_VERBS)
        buttons = self.ctrl(card(stage="align", prUrl=None, review=None,
                                 numberOne=self.ENGAGED))
        starts = [b for b in buttons if "Start" in (b["text"] or "")]
        for b in starts:
            self.assertFalse(b["disabled"],
                             "Start was swept, but the daemon allows it")

    def test_the_stand_down_control_is_offered_and_live(self):
        buttons = self.ctrl(card(numberOne=self.ENGAGED))
        sd = [b for b in buttons if _cls(b, "xo-stand-down")]
        self.assertEqual(1, len(sd))
        self.assertEqual("■ Stand down", sd[0]["text"])
        self.assertFalse(sd[0]["disabled"],
                         "standing Number One down must always be possible")

    def test_nothing_is_swept_on_a_mission_it_does_not_hold(self):
        for block in (None, {"status": "finished"}, {"status": "stood-down"}):
            m = card(stage="align", prUrl=None, review=None)
            if block:
                m["numberOne"] = block
            for b in self.ctrl(m):
                self.assertFalse(b["disabled"], "%s / %s" % (block, b["text"]))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheBandToggle(unittest.TestCase):

    def test_no_block_leaves_the_toggle_hidden(self):
        out = _render_band({"repo": "acme/repo", "adapter": "local"})
        self.assertTrue(out["toggle"]["hidden"],
                        "a repo that has never heard of Number One shows "
                        "nothing new in the band")

    def test_off_reads_off(self):
        out = _render_band({"numberOne": {"enabled": False}})
        self.assertFalse(out["toggle"]["hidden"])
        self.assertEqual("◈ Number One · OFF", out["toggle"]["text"])
        self.assertNotIn("on", out["toggle"]["cls"].split())

    def test_on_names_the_engine_in_upper_case(self):
        out = _render_band({"numberOne": {"enabled": True,
                                          "engine": "copilot"}})
        self.assertEqual("◈ Number One · ON · COPILOT", out["toggle"]["text"])
        self.assertIn("on", out["toggle"]["cls"].split())

    def test_a_view_only_board_disables_it_with_the_view_only_reason(self):
        out = _render_band({"numberOne": {"enabled": False}}, readonly=True)
        self.assertTrue(out["toggle"]["disabled"])
        self.assertEqual("view-only board — writes are disabled",
                         out["toggle"]["title"])

    def test_the_legend_gains_two_entries_only_when_on(self):
        off = _render_band({"numberOne": {"enabled": False}})
        self.assertEqual([], off["legend"])
        on = _render_band({"numberOne": {"enabled": True,
                                         "engine": "copilot"}})
        self.assertEqual(["Number One engaged for you",
                          "Number One finished · score"],
                         [e["text"] for e in on["legend"]])

    def test_the_legend_entries_are_removed_again_when_it_goes_off(self):
        out = _render_band({"numberOne": {"enabled": True, "engine": "copilot"}},
                           click="off")
        self.assertEqual([], out["legend"],
                         "the legend must not accumulate on repaint")

    def test_pressing_it_while_off_opens_the_picker(self):
        out = _render_band({"numberOne": {"enabled": False}}, click="toggle")
        self.assertTrue(out["picker"]["open"])
        self.assertEqual(["copilot", "claude"], out["picker"]["engines"])

    def test_the_picker_says_installed_or_not_installed_and_nothing_about_money(self):
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["copilot"]}, click="toggle")
        rows = out["picker"]["rows"]
        self.assertEqual(2, len(rows))
        self.assertIn("installed", rows[0]["text"])
        self.assertIn("not installed", rows[1]["text"])
        for r in rows:
            for w in PRICING_WORDS:
                self.assertNotIn(w, r["text"].lower())

    def test_the_picker_defaults_to_the_one_that_is_installed(self):
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["claude"]}, click="toggle")
        self.assertEqual("claude", out["picker"]["chosen"])

    def test_the_picker_opens_on_the_DAEMONS_answer(self):
        """FIX ROUND 1, D2 — the board picker and the CLI picker preselected
        DIFFERENT engines (copilot here, claude at a terminal), so a bare Enter
        got you a different first officer depending on which door you came
        through. The default now has ONE source — `lcars_xo_default_engine` in
        lcars-common.sh — and reaches the board as `meta.engineDefault`. This
        board does not recompute it; it renders it."""
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["copilot", "claude"],
                            "engineDefault": "copilot"}, click="toggle")
        self.assertEqual("copilot", out["picker"]["chosen"])

    def test_and_it_is_the_daemons_answer_even_when_it_is_the_other_one(self):
        """The half that proves it is READ, not re-derived: the same board,
        the same installed pair, the other answer."""
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["copilot", "claude"],
                            "engineDefault": "claude"}, click="toggle")
        self.assertEqual("claude", out["picker"]["chosen"])

    def test_an_answer_that_names_no_engine_we_offer_is_ignored(self):
        """A daemon that answers something this board cannot draw falls back to
        what it can see, rather than opening a picker with no row selected."""
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["claude"],
                            "engineDefault": "sarek"}, click="toggle")
        self.assertEqual("claude", out["picker"]["chosen"])

    def test_engaging_posts_the_daemons_default_on_a_bare_press(self):
        """The whole point, end to end: open the picker and press Engage
        without touching a row, and what is POSTED is the one default."""
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["copilot", "claude"],
                            "engineDefault": "copilot"}, click="engage")
        self.assertEqual([["/api/xo/on", {"engine": "copilot"}]], out["posts"])

    def test_the_picker_foot_is_cancel_and_engage(self):
        out = _render_band({"numberOne": {"enabled": False}}, click="toggle")
        self.assertEqual(["Cancel", "◈ Engage"], out["picker"]["foot"])

    def test_pressing_it_while_on_stands_the_repo_down(self):
        # S205: this now goes THROUGH the small ON-state menu (report / change
        # engine / turn off) rather than dispatching straight off the one
        # click — the harness follows through to the menu's own "■ Turn off"
        # item, so the eventual POST is unchanged; see test_pressing_it_while
        # _on_opens_a_menu below for the menu itself.
        out = _render_band({"numberOne": {"enabled": True, "engine": "copilot"}},
                           click="toggle")
        self.assertFalse(out["picker"]["open"], "ON → OFF never asks the "
                                                "ENGINE picker — that only ever opens OFF")
        self.assertEqual([["/api/xo/off", {}]], out["posts"])

    def test_pressing_it_while_on_opens_a_menu(self):
        """S205: the band's ON control gains a menu (report / change engine /
        turn off) instead of dispatching a stand-down off the one click."""
        out = _render_band({"numberOne": {"enabled": True, "engine": "copilot"}},
                           click="menu")
        self.assertTrue(out["menu"]["open"])
        self.assertEqual(["◈ First Officer's report", "Change engine",
                          "■ Turn off"], out["menu"]["items"])
        self.assertEqual([], out["posts"], "opening the menu posts nothing yet")

    def test_pressing_it_while_off_never_opens_the_menu(self):
        """The menu is the ON-state's own affordance — OFF still goes straight
        to the engine picker, exactly as before this round."""
        out = _render_band({"numberOne": {"enabled": False}}, click="menu")
        self.assertFalse(out["menu"]["open"])
        self.assertTrue(out["picker"]["open"])

    def test_engaging_posts_the_chosen_engine(self):
        out = _render_band({"numberOne": {"enabled": False},
                            "enginesHere": ["copilot"]}, click="engage")
        self.assertEqual([["/api/xo/on", {"engine": "copilot"}]], out["posts"])


class TheDefaultEngineHasOneSource(unittest.TestCase):
    """FIX ROUND 1, D2 — the daemon publishes the SHELL's preselection.

    `meta.engineDefault` is `lcars_xo_default_engine`'s answer, spawned the
    same way `enginesHere` already is (ONE detector, two front doors — S195's
    rule, applied to the default as well as to the list). The engines are
    faked through the `LCARS_*_BIN` seams, never through $PATH, so this test
    measures the fixture and not the tester's laptop.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-xo", stage="verify", issue=101)
        self.bins = os.path.join(self.tmp, "bin")
        os.makedirs(self.bins, exist_ok=True)
        self.log = os.path.join(self.tmp, "engine-calls.txt")

    def _fake(self, name):
        """An engine that is INSTALLED and never RUN. It records every
        invocation, and `test_nothing_was_ever_spawned` asserts the record is
        empty: the detector asks `command -v`, and a detector that ever
        executed an engine would be spending the captain's money to answer a
        question about the filesystem."""
        p = os.path.join(self.bins, name)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\necho \"$0 $*\" >> " + self.log + "\nexit 0\n")
        os.chmod(p, 0o755)
        return p

    def _write_raw_config(self, block):
        """The config EXACTLY as `lcars xo` writes it — the `numberOne` object
        on ONE LINE. That is not decoration: `lcars_config_merge` preserves a
        raw value only when it sits on a single line, which is why the writer
        emits it that way and why a fixture that pretty-printed it would be
        testing a file no shipped writer produces."""
        d = os.path.join(self.tmp, ".git", "lcars")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config.json"), "w") as fh:
            fh.write('{\n  "model": "claude-sonnet",\n  "numberOne": %s\n}\n'
                     % block)

    def _meta(self, claude, copilot, block=None):
        self._write_raw_config(block or '{"enabled": true}')
        old = {k: os.environ.get(k)
               for k in ("LCARS_CLAUDE_BIN", "LCARS_COPILOT_BIN")}

        def restore():
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ["LCARS_CLAUDE_BIN"] = claude
        os.environ["LCARS_COPILOT_BIN"] = copilot
        return LocalAdapter(self.tmp).board()["meta"]

    def test_both_installed_opens_on_copilot(self):
        meta = self._meta(self._fake("claude"), self._fake("copilot"))
        self.assertEqual("copilot", meta.get("engineDefault"))

    def test_one_installed_opens_on_that_one(self):
        meta = self._meta(os.path.join(self.tmp, "nope"), self._fake("copilot"))
        self.assertEqual("copilot", meta.get("engineDefault"))
        meta = self._meta(self._fake("claude"), os.path.join(self.tmp, "nope"))
        self.assertEqual("claude", meta.get("engineDefault"))

    def test_the_repos_own_pin_wins(self):
        meta = self._meta(self._fake("claude"), self._fake("copilot"),
                          block='{"enabled": false, "engine": "claude"}')
        self.assertEqual("claude", meta.get("engineDefault"))

    def test_nothing_installed_names_no_default(self):
        """ABSENT, never null, never a guess — the rule every additive key on
        this shape follows, and the reason a board with no Number One block is
        byte-identical to the one served before this round."""
        meta = self._meta(os.path.join(self.tmp, "nope-c"),
                          os.path.join(self.tmp, "nope-p"))
        self.assertNotIn("engineDefault", meta)

    def test_nothing_was_ever_spawned(self):
        meta = self._meta(self._fake("claude"), self._fake("copilot"))
        self.assertEqual("copilot", meta.get("engineDefault"))
        self.assertFalse(os.path.exists(self.log),
                         "an engine CLI was executed to answer a question "
                         "about whether it is installed")

    def test_a_repo_with_no_numberOne_block_gains_no_numberOne_key(self):
        """S274 CHANGED THIS ONE ASSERTION, deliberately.

        Until S274 `engineDefault` and `enginesHere` lived inside
        `if xo is not None`, so the ONLY repos that could say which engines
        this laptop has were the ones that had already run `lcars xo`. But
        "which CLIs are installed here" is a fact about the LAPTOP, not about a
        repo's first officer, and every surface that needs an engine needs it —
        the Align grill, the holodeck's New Program dialog, Adopt, and the
        banner a laptop with no CLI at all shows. They are published on EVERY
        board now.

        What this test still guards is the thing it was written for: a repo
        that has never run `lcars xo` gains NO `numberOne` key, so the board
        shows no toggle rather than a toggle that says the wrong thing."""
        write_config(self.tmp, {"model": "claude-sonnet"})
        meta = LocalAdapter(self.tmp).board()["meta"]
        self.assertNotIn("numberOne", meta)
        # …and the laptop's engines ARE there, numberOne block or not (S274).
        self.assertIn("enginesHere", meta)


if __name__ == "__main__":
    unittest.main()
