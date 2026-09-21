"""S216 — THE TWO-PART SCORE on the board: the pill, the tab, the adapter.

The captain approved the card as drawn: `◈ MEDIUM · checked 11 of 14 · core
met`. The grade is still the ONE label (`lcars:xo:<score>`); the two axes ride
beside it on the card and live in the verdict file, the tab and the report —
never an envelope field, never a second label.

  * THE ADAPTER reads `checked` / `total` / `core` off the mission's own
    `xo/verdict.json`. A verdict written before S216 has counts but no impact,
    so it gets the counts and NO core — nothing it never assessed is asserted.
  * THE PILL carries grade + checked N of M + core, and at the real column
    width (220px `.col`, inside the 224px the captain measured) the grade never
    breaks and nothing clips — proven in REAL headless Chrome, not the vm.
  * THE TAB leads with WHY THIS GRADE after the score; the alternative reading
    sits beside it as an aside; each row shows its impact and its reason.

No gh, no network, no model, no worker.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

CARD_HARNESS = os.path.join(HERE, "board_card_harness.js")
TAB_HARNESS = os.path.join(HERE, "board_xo_tab_harness.js")
STATIC = os.path.join(os.path.dirname(HERE), "static")
DRIVER = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo-drive.js"))
CHROME = os.environ.get(
    "LCARS_BROWSER_CHROME",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
MID = "lcars-20260919-216"


def _run(harness, payload):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(payload, fh)
        spec = fh.name
    try:
        proc = subprocess.run(["node", harness, spec],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            raise AssertionError("harness failed: %s"
                                 % proc.stderr.decode("utf-8", "replace"))
        return json.loads(proc.stdout.decode("utf-8"))
    finally:
        os.unlink(spec)


def _flatten(node, out=None):
    out = [] if out is None else out
    if not node:
        return out
    out.append(node)
    for kid in node.get("children") or []:
        _flatten(kid, out)
    return out


def _all_text(node):
    return " ".join(n.get("text") or "" for n in _flatten(node))


def _cls_of(node, needle):
    return [n for n in _flatten(node)
            if needle in (" " + (n.get("cls") or "") + " ")]


def _plant(root, block, verdict):
    fx.plant_simple(root, MID, stage="verify", issue=16, title="health bar")
    path = os.path.join(fx.mission_dir(root, MID), "state.json")
    with open(path) as fh:
        doc = json.load(fh)
    doc["numberOne"] = block
    with open(path, "w") as fh:
        json.dump(doc, fh)
    if verdict is not None:
        xodir = os.path.join(fx.mission_dir(root, MID), "xo")
        os.makedirs(xodir, exist_ok=True)
        with open(os.path.join(xodir, "verdict.json"), "w") as fh:
            json.dump(verdict, fh)


NEW_VERDICT = {
    "score": "medium", "derivation": "the point of the mission works; go with "
    "this known issue — the bar is red (prd-2).",
    "whyThisGrade": "MEDIUM because every part that is the point of the "
    "mission worked, but something else you asked for did not work as asked "
    "— go with the named known issue. Known issues shipping with it: the bar "
    "is red (prd-2).",
    "core": "met",
    "counts": {"met": 10, "gap": 1, "untested": 3, "contradictions": 1},
    "criteria": [
        {"id": "prd-1", "text": "the health bar drops when you are hit",
         "status": "met", "evidence": "picture", "shot": "shot-02",
         "impact": "high", "impactWhy": "it is the point of the mission",
         # S223 fix round 1 (D2): the look RECORDS what it did.
         "action": "Took a hit and watched the bar",
         "reason": "Impact high because it is the point. I tried taking a "
                   "hit; I saw the bar drop (evidence: shot-02). Outcome: "
                   "worked."},
        # NO `action` — an older verdict. The reader shows the recorded reason
        # as written; it must never print the canned "no way to observe it".
        {"id": "prd-2", "text": "the bar is red", "status": "untested",
         "evidence": "none", "impact": "medium", "couldNotCheck": "unobservable",
         "reason": "Impact medium because colour is secondary. I tried two "
                   "shots; I saw no bar colour recorded. Outcome: couldn't "
                   "check (unobservable)."},
        {"id": "t-1-ac1", "text": "a border", "status": "gap",
         "evidence": "picture", "shot": "shot-03", "impact": "high",
         "impactAssumed": True, "reasonByHarness": True,
         "reason": "No reason was given for this one — all I have is the "
                   "outcome: didn't."},
    ],
    "gaps": [], "summary": "What I found, to the captain.",
    "altReading": "a risk-based reviewer might sign this off: the only open "
                  "item is one nobody could check (prd-2), not one that was "
                  "seen to fail",
}

OLD_VERDICT = {
    "score": "medium", "derivation": "nothing in the build contradicts what "
    "you asked for, but there are 2 things on your list I could not check.",
    "counts": {"met": 3, "gap": 0, "untested": 2, "contradictions": 0},
    "criteria": [
        {"id": "prd-1", "text": "the list shows", "status": "met",
         "evidence": "picture", "shot": "shot-01", "note": "saw it"},
        {"id": "prd-2", "text": "it saves", "status": "untested",
         "evidence": "none", "note": "could not see a save"},
    ],
    "gaps": [], "summary": "Older look.",
}


class TheAdapterCarriesTheAxes(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _xo(self):
        cards = [c for c in LocalAdapter(self.tmp).board()["missions"]
                 if c["id"] == MID]
        self.assertTrue(cards)
        return cards[0]["numberOne"]

    def test_a_new_verdict_gives_checked_total_and_core(self):
        _plant(self.tmp, {"status": "engaged", "score": "medium"}, NEW_VERDICT)
        xo = self._xo()
        self.assertEqual(11, xo["checked"])
        self.assertEqual(14, xo["total"])
        self.assertEqual("met", xo["core"])

    def test_a_pre_s216_verdict_gets_counts_and_no_core(self):
        _plant(self.tmp, {"status": "engaged", "score": "medium"}, OLD_VERDICT)
        xo = self._xo()
        self.assertEqual(3, xo["checked"])
        self.assertEqual(5, xo["total"])
        self.assertNotIn("core", xo)

    def test_no_verdict_on_disk_gives_no_axes(self):
        _plant(self.tmp, {"status": "engaged", "score": "medium"}, None)
        xo = self._xo()
        for k in ("checked", "total", "core"):
            self.assertNotIn(k, xo)

    def test_an_unknown_core_word_is_not_carried(self):
        v = dict(NEW_VERDICT, core="fine")
        _plant(self.tmp, {"status": "engaged", "score": "medium"}, v)
        self.assertNotIn("core", self._xo())


@unittest.skipIf(shutil.which("node") is None, "node not available")
class ThePillCarriesBothAxes(unittest.TestCase):

    def pill(self, **block):
        m = {"id": MID, "issue": 16, "stage": "verify", "title": "t",
             "numberOne": dict({"status": "engaged", "score": "medium"}, **block)}
        card = _run(CARD_HARNESS, m)
        pills = _cls_of(card, " xo-score ")
        self.assertEqual(1, len(pills))
        return pills[0]

    def test_grade_checked_and_core_in_one_pill(self):
        p = self.pill(checked=11, total=14, core="met")
        # S223: plain words, grade word alone in colour, sentence below it.
        self.assertEqual("◈ MEDIUM The point of the mission worked · 11 of 14 checked",
                         _all_text(p).strip())
        self.assertEqual(1, len(_cls_of(p, " xo-axes ")))
        self.assertNotIn("core", _all_text(p))
        self.assertEqual(1, len(_cls_of(p, " xo-grade ")))
        self.assertEqual("◈ MEDIUM", _cls_of(p, " xo-grade ")[0]["text"])

    def test_core_broken_and_unverified_read_as_such(self):
        self.assertIn("The point of the mission didn't work",
                      _all_text(self.pill(score="low", checked=4, total=4,
                                          core="broken")))
        self.assertIn("Couldn't check the point of the mission",
                      _all_text(self.pill(score="low", checked=3, total=4,
                                          core="unverified")))

    def test_an_old_verdict_shows_counts_but_asserts_no_core(self):
        t = _all_text(self.pill(checked=3, total=5))
        self.assertIn("3 of 5 checked", t)
        self.assertNotIn("point of the mission", t)

    def test_no_axes_keeps_the_old_pill_word_for_word(self):
        self.assertEqual("◈ NUMBER ONE · MEDIUM", self.pill()["text"])


@unittest.skipIf(shutil.which("node") is None, "node not available")
class TheTabSaysWhy(unittest.TestCase):

    def tab(self, verdict):
        mi = {"id": MID, "issue": 16, "stage": "verify", "title": "t",
              "numberOne": {"status": "engaged", "engine": "copilot",
                            "score": verdict["score"],
                            "report": {"score": verdict["score"],
                                       "status": "engaged", "engine": "copilot",
                                       "verdict": verdict, "logs": [],
                                       "shotsDir": "shots", "journal": []}}}
        return _run(TAB_HARNESS, mi)

    def test_why_this_grade_comes_right_after_the_verdict(self):
        # S223 (the approved mock): the grade box with the one honest sentence
        # beside it, THEN "Why this grade", then the full text.
        out = self.tab(NEW_VERDICT)
        joined = " ⇢ ".join(out["paneText"])
        self.assertIn("Why this grade", joined)
        self.assertLess(joined.index(NEW_VERDICT["derivation"][:30]),
                        joined.index("MEDIUM because"))
        self.assertLess(joined.index("MEDIUM because"),
                        joined.index("What I found, to the captain"))
        head = _cls_of(out["pane"], " xo-verdict ")[0]
        self.assertIn(NEW_VERDICT["derivation"][:30], _all_text(head))

    def test_why_this_grade_is_read_as_prose_not_a_wall(self):
        """S223 fix round 1 (D3) — DISPLAY ONLY, S216 still writes the words.

        On the captain's real report this was ONE ~2,300-word paragraph with
        raw `**` asterisks in it, and it is the first thing he reads. The
        markdown is rendered, the run of sentences is broken into paragraphs,
        and every word is still there.

        S224 MOVED THE DOOR OUT ONE LEVEL. The whole block now sits behind
        the pane's single fold, so a disclosure of its own would be two taps
        to reach one sentence — the reader that is already open shows every
        paragraph. What this test has always been about is unchanged: no raw
        markdown on screen, the wall broken into paragraphs, and every word
        still present."""
        long_why = ("**MEDIUM** because every part that is the point of the "
                    "mission worked. " + " ".join(
                        "Sentence number %d says something about ticket "
                        "t-00%d-ac1 that the captain has to read." % (i, i)
                        for i in range(1, 30)))
        out = self.tab(dict(NEW_VERDICT, whyThisGrade=long_why))
        box = _cls_of(out["pane"], " xo-why ")[0]
        shown = _all_text(box)
        # 1 · no raw markdown reaches the screen
        self.assertNotIn("**", shown)
        self.assertIn("MEDIUM", shown)
        # 2 · it is broken up, and the lead is short
        bodies = _cls_of(box, " xo-why-body ")
        self.assertGreaterEqual(len(bodies), 2)
        self.assertLess(len(_all_text(bodies[0])), 600)
        # 3 · no fold INSIDE the block — the pane's own one already holds it
        self.assertEqual([], [n for n in _flatten(box) if n["tag"] == "details"])
        self.assertNotIn("Show the full reasoning", shown)
        # 4 · and not one word is lost to the flattening
        self.assertIn("Sentence number 29", shown)

    def test_why_this_grade_is_behind_the_panes_one_fold(self):
        """S224 — the grade's account of itself folds with the rest of the
        prose. It is still first inside that fold, and the door names it."""
        out = self.tab(NEW_VERDICT)
        folds = [n for n in _flatten(out["pane"]) if n["tag"] == "details"]
        self.assertEqual(1, len(folds), "expected exactly one fold on the pane")
        self.assertIn("why this grade", _all_text(folds[0]).lower())
        self.assertIn("MEDIUM because", _all_text(folds[0]))
        # …and it is no longer a direct child of the pane, above the evidence
        top = [(n.get("cls") or "") for n in out["pane"]["children"]]
        self.assertNotIn("xo-why", top)

    def test_a_short_why_this_grade_needs_no_disclosure(self):
        out = self.tab(NEW_VERDICT)
        box = _cls_of(out["pane"], " xo-why ")[0]
        self.assertEqual([], [n for n in _flatten(box) if n["tag"] == "details"])
        self.assertIn("MEDIUM because", _all_text(box))

    def test_the_alt_reading_is_beside_it_and_labelled_as_not_the_grade(self):
        out = self.tab(NEW_VERDICT)
        alts = _cls_of(out["pane"], " xo-alt ")
        self.assertEqual(1, len(alts))
        text = _all_text(alts[0])
        self.assertIn("does not change the grade", text)
        self.assertIn("risk-based reviewer", text)

    def test_no_alt_reading_no_aside(self):
        v = dict(NEW_VERDICT)
        v.pop("altReading")
        self.assertEqual([], _cls_of(self.tab(v)["pane"], " xo-alt "))

    def test_each_row_shows_its_impact_once_and_what_it_did(self):
        # S223: one boxed block per requirement, problems first; the
        # importance reasoning is said ONCE (the "Why it matters" line), and
        # the reason's "Impact … because" half is never repeated.
        out = self.tab(NEW_VERDICT)
        rows = _cls_of(out["pane"], " xo-item ")
        self.assertEqual(3, len(rows))
        texts = [_all_text(r) for r in rows]
        self.assertIn("DIDN'T WORK", texts[0])
        self.assertIn("COULDN'T CHECK", texts[1])
        self.assertIn("WORKED", texts[2])
        met = texts[2]
        self.assertIn("HIGH · the point", met)
        # S223 fix round 1 (D2): the RECORDED action, word for word.
        self.assertIn("Took a hit and watched the bar", met)   # What I did
        self.assertIn("Why it matters: It is the point of the mission.", met)
        self.assertEqual(1, met.count("point of the mission"))
        # a row WITH an action still keeps the reason's "Impact …" half off
        # the screen entirely — nothing is said twice.
        self.assertNotIn("Impact high", met)
        unt = texts[1]
        self.assertIn("MEDIUM · a known issue", unt)
        self.assertIn("the bar colour recorded"[4:], unt)
        gap = texts[0]
        self.assertIn("None was given, so I counted it as the point of the mission.", gap)

    def test_what_i_did_is_the_recorded_action_never_a_rewrite(self):
        """S223 fix round 1 (D2) — the infer-vs-record check.

        The reader used to CHOP `I tried …; I saw …` out of the reason prose.
        On the captain's own report that printed a canned sentence over 39
        rows that each had a recorded action, dropped the verb on 13 more
        ("The test tail.", "Preview."), and said "Not recorded for this one."
        on a row whose reason says what it tried. Three rules, one test:
        the recorded field wins; no `action` shows the REASON as written; and
        a canned sentence is never printed over either."""
        v = dict(NEW_VERDICT, criteria=[
            # (a) a recorded action is shown word for word
            {"id": "a-1", "text": "the tail", "status": "met", "impact": "low",
             "evidence": "tests", "action": "Ran the test tail",
             "reason": "Impact low because polish. I tried the test tail; I "
                       "saw 42 passing. Outcome: worked."},
            # (b) no action, an untested row WITH a couldNotCheck: the old code
            #     printed "Tried to check it — no way to observe it."
            {"id": "a-2", "text": "the warn line", "status": "untested",
             "impact": "high", "evidence": "none", "couldNotCheck": "unobservable",
             "reason": "I tried finding the amber warn-line in the full "
                       "builder and could not."},
            # (c) no action, no `; I saw` joint: the old code said "Not
            #     recorded for this one." over a real recorded action.
            {"id": "a-3", "text": "the lock dialog", "status": "gap",
             "impact": "medium", "evidence": "none",
             "reason": "I tried reading the bar and cross-checking the lock "
                       "dialog."},
        ])
        rows = {r["attrs"].get("data-id"): _all_text(r)
                for r in _cls_of(self.tab(v)["pane"], " xo-item ")}
        self.assertIn("Ran the test tail", rows["a-1"])
        self.assertNotIn("The test tail.", rows["a-1"])
        self.assertIn("finding the amber warn-line in the full builder and "
                      "could not", rows["a-2"])
        self.assertNotIn("no way to observe it", rows["a-2"])
        self.assertNotIn("Tried to check it", rows["a-2"])
        self.assertIn("reading the bar and cross-checking the lock dialog",
                      rows["a-3"])
        for text in rows.values():
            self.assertNotIn("Not recorded for this one.", text)

    def test_a_harness_written_reason_is_not_passed_off_as_what_it_did(self):
        """The harness writes the reason when the look gave none, and says so
        on the record (`reasonByHarness`). That sentence is not the look's
        account of what it did, so "What I did" says nothing was recorded —
        and that is true."""
        rows = {r["attrs"].get("data-id"): _all_text(r) for r in
                _cls_of(self.tab(NEW_VERDICT)["pane"], " xo-item ")}
        self.assertIn("Not recorded for this one.", rows["t-1-ac1"])

    def test_the_tab_says_when_importance_was_set(self):
        # S216 fix round 1 (D5): importance is recorded on the first look and
        # kept; the tab says so, right under why-this-grade.
        v = dict(NEW_VERDICT, impactsNote="Importance was set on the first "
                 "look (2026-09-19, Copilot) and kept for this one, so a new "
                 "look cannot move the grade by re-guessing it.")
        out = self.tab(v)
        notes = _cls_of(out["pane"], " xo-impacts-note ")
        self.assertEqual(1, len(notes))
        self.assertIn("set on the first look (2026-09-19, Copilot)",
                      _all_text(notes[0]))
        joined = " ⇢ ".join(out["paneText"])
        self.assertLess(joined.index("MEDIUM because"),
                        joined.index("set on the first look"))

    def test_near_duplicates_rated_apart_are_flagged_not_graded(self):
        v = dict(NEW_VERDICT, impactMismatches=[
            {"ids": ["prd-1", "t-1-ac1"], "impacts": ["high", "low"]}])
        out = self.tab(v)
        flags = _cls_of(out["pane"], " xo-impact-mismatch ")
        self.assertEqual(1, len(flags))
        text = _all_text(flags[0])
        self.assertIn("say the same thing but were given different importance",
                      text)
        self.assertIn("prd-1", text)
        self.assertIn("does not change the grade", text)

    def test_no_record_no_note(self):
        out = self.tab(NEW_VERDICT)
        self.assertEqual([], _cls_of(out["pane"], " xo-impacts-note "))
        self.assertEqual([], _cls_of(out["pane"], " xo-impact-mismatch "))

    def test_a_pre_s216_verdict_asserts_no_impact_and_no_why(self):
        out = self.tab(OLD_VERDICT)
        self.assertEqual([], _cls_of(out["pane"], " xo-why "))
        self.assertEqual([], _cls_of(out["pane"], " xo-ichip "))
        self.assertEqual([], _cls_of(out["pane"], " xo-matters "))
        # …but it still renders its rows and its own sentence.
        self.assertEqual(2, len(_cls_of(out["pane"], " xo-item ")))
        self.assertIn(OLD_VERDICT["derivation"][:40],
                      " ".join(out["paneText"]))


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="%(tokens)s">
<link rel="stylesheet" href="%(css)s"></head>
<body><div id="host"></div>
<script src="%(js)s"></script>
<script>
(function () {
  var out = [];
  var cases = %(cases)s;
  var host = document.getElementById("host");
  cases.forEach(function (c) {
    var col = document.createElement("div");
    col.className = "col";
    var card = document.createElement("div");
    card.className = "card";
    var block = document.createElement("div");
    block.className = "xo-block xo-signal";
    var row = document.createElement("div");
    row.className = "pills xo-pills";
    var pill = xoScorePill({numberOne: c});
    row.appendChild(pill);
    block.appendChild(row);
    card.appendChild(block);
    col.appendChild(card);
    host.appendChild(col);
    var g = pill.querySelector(".xo-grade");
    var gr = g.getBoundingClientRect(), pr = pill.getBoundingClientRect(),
        cr = card.getBoundingClientRect(), lr = col.getBoundingClientRect();
    var lh = parseFloat(getComputedStyle(g).lineHeight) || 16;
    out.push({colW: lr.width, pillRight: pr.right, cardRight: cr.right,
              cardInner: cr.right - parseFloat(getComputedStyle(card).paddingRight)
                         - parseFloat(getComputedStyle(card).borderRightWidth),
              pillScroll: pill.scrollWidth, pillClient: pill.clientWidth,
              cardScroll: card.scrollWidth, cardClient: card.clientWidth,
              gradeH: gr.height, gradeLine: lh, gradeText: g.textContent,
              text: pill.textContent,
              // S223: COMPUTED styles — only the grade word is coloured; the
              // sentence is body ink at body size, in sentence case.
              gradeColor: getComputedStyle(g).color,
              axesColor: getComputedStyle(pill.querySelector(".xo-axes")).color,
              axesSize: parseFloat(getComputedStyle(pill.querySelector(".xo-axes")).fontSize),
              axesCase: getComputedStyle(pill.querySelector(".xo-axes")).textTransform,
              axesWeight: getComputedStyle(pill.querySelector(".xo-axes")).fontWeight,
              ink: getComputedStyle(document.body).getPropertyValue("--lcars-text-bright").trim()});
  });
  document.title = "";
  var pre = document.createElement("pre");
  pre.id = "result";
  pre.textContent = "RESULT" + JSON.stringify(out) + "ENDRESULT";
  document.body.appendChild(pre);
})();
</script></body></html>"""


@unittest.skipUnless(os.path.exists(CHROME) and shutil.which("node"),
                     "Chrome and node are needed for the real-browser check")
class ThePillFitsTheColumnInARealBrowser(unittest.TestCase):
    """REAL CHROME, REAL STYLESHEET. The vm harness knows nothing of layout
    (see test_board_boot_paints), and S214's D6 was a clip only a browser
    could see."""

    def test_the_widest_pill_fits_224px_and_the_grade_never_breaks(self):
        cases = [
            {"status": "engaged", "score": "medium", "checked": 11,
             "total": 14, "core": "unverified"},
            {"status": "engaged", "score": "low", "checked": 108,
             "total": 120, "core": "broken"},
            {"status": "engaged", "score": "high", "checked": 4, "total": 4,
             "core": "met"},
        ]
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        page = os.path.join(tmp, "pill.html")
        with open(page, "w") as fh:
            fh.write(PAGE % {
                "tokens": "file://" + os.path.join(STATIC, "..", "..", "docs", "lcars.css"),
                "css": "file://" + os.path.join(STATIC, "board.css"),
                "js": "file://" + os.path.join(STATIC, "board.js"),
                "cases": json.dumps(cases)})
        # THE PRODUCT'S OWN HEADLESS DRIVER (xo-drive.js): raw CDP, a
        # throwaway profile, headless with no switch to turn it off, its own
        # Chrome reaped by pid. `--dump-dom` hangs on this machine; the driver
        # does not, and it is the browser path Number One itself uses.
        shots = os.path.join(tmp, "shots")
        proc = subprocess.run(
            ["node", DRIVER, "--url", "file://" + page, "--out", shots,
             "--scale", "1", "--timeout", "30000"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        if proc.returncode == 77:
            self.skipTest("the browser could not be started here (exit 77)")
        with open(os.path.join(shots, "shot-01.json")) as fh:
            dom = fh.read()
        dom = json.loads(dom).get("page", {}).get("textExcerpt", "")
        self.assertIn("RESULT", dom, "the page rendered nothing: %s"
                      % proc.stderr.decode("utf-8", "replace")[-500:])
        got = json.loads(dom.split("RESULT", 1)[1].split("ENDRESULT", 1)[0])
        self.assertEqual(3, len(got))
        for r in got:
            self.assertLessEqual(r["colW"], 224, r)
            # Nothing past the card's content box, nothing clipped inside it.
            self.assertLessEqual(r["pillRight"], r["cardInner"] + 0.5, r)
            self.assertLessEqual(r["pillScroll"], r["pillClient"] + 1, r)
            self.assertLessEqual(r["cardScroll"], r["cardClient"] + 1, r)
            # The grade is one unbroken line.
            self.assertLess(r["gradeH"], r["gradeLine"] * 1.6, r)
            self.assertTrue(r["gradeText"].startswith("◈ "), r)
            self.assertIn("checked", r["text"])
            # S223 — plain words, never harness talk.
            self.assertNotIn("core", r["text"])
            self.assertIn("point of the mission", r["text"])
            # S223 — ONLY the grade word is coloured: the sentence is the
            # board's body ink (#e4eeff), at body size, not upper-cased.
            self.assertEqual("rgb(228, 238, 255)", r["axesColor"], r)
            self.assertNotEqual(r["gradeColor"], r["axesColor"], r)
            self.assertGreaterEqual(r["axesSize"], 12, r)
            self.assertEqual("none", r["axesCase"], r)


if __name__ == "__main__":
    unittest.main()
