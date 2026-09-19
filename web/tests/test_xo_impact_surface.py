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
         "reason": "Impact high because it is the point. I tried taking a "
                   "hit; I saw the bar drop (evidence: shot-02). Outcome: "
                   "worked."},
        {"id": "prd-2", "text": "the bar is red", "status": "untested",
         "evidence": "none", "impact": "medium", "couldNotCheck": "unobservable",
         "reason": "Impact medium because colour is secondary. I tried two "
                   "shots; I saw no bar colour recorded. Outcome: couldn't "
                   "check (unobservable)."},
        {"id": "t-1-ac1", "text": "a border", "status": "gap",
         "evidence": "picture", "shot": "shot-03", "impact": "high",
         "impactAssumed": True,
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
        self.assertEqual("◈ MEDIUM  · checked 11 of 14 · core met",
                         _all_text(p).strip())
        self.assertEqual(1, len(_cls_of(p, " xo-grade ")))
        self.assertEqual("◈ MEDIUM", _cls_of(p, " xo-grade ")[0]["text"])

    def test_core_broken_and_unverified_read_as_such(self):
        self.assertIn("core broken",
                      _all_text(self.pill(score="low", checked=4, total=4,
                                          core="broken")))
        self.assertIn("core unverified",
                      _all_text(self.pill(score="low", checked=3, total=4,
                                          core="unverified")))

    def test_an_old_verdict_shows_counts_but_asserts_no_core(self):
        t = _all_text(self.pill(checked=3, total=5))
        self.assertIn("checked 3 of 5", t)
        self.assertNotIn("core", t)

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

    def test_why_this_grade_comes_right_after_the_score(self):
        out = self.tab(NEW_VERDICT)
        joined = " ⇢ ".join(out["paneText"])
        self.assertIn("Why this grade", joined)
        self.assertLess(joined.index("MEDIUM because"),
                        joined.index(NEW_VERDICT["derivation"][:30]))
        self.assertLess(joined.index("MEDIUM because"),
                        joined.index("What I found, to the captain"))

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

    def test_each_row_shows_its_impact_and_its_reason(self):
        out = self.tab(NEW_VERDICT)
        rows = _cls_of(out["pane"], " xo-crit-row ")
        self.assertEqual(3, len(rows))
        first = _all_text(rows[0])
        self.assertIn("point of the mission", first)
        self.assertIn("I tried taking a hit", first)
        self.assertIn("Worked", first)
        second = _all_text(rows[1])
        self.assertIn("Couldn't check", second)
        self.assertIn("no way to observe it", second)
        third = _all_text(rows[2])
        self.assertIn("none was given, so counted as high", third)
        self.assertIn("Didn't work", third)

    def test_a_pre_s216_verdict_asserts_no_impact_and_no_why(self):
        out = self.tab(OLD_VERDICT)
        self.assertEqual([], _cls_of(out["pane"], " xo-why "))
        self.assertEqual([], _cls_of(out["pane"], " xo-crit-impact "))
        self.assertEqual([], _cls_of(out["pane"], " xo-crit-reason "))
        # …but it still renders its rows and its own sentence.
        self.assertEqual(2, len(_cls_of(out["pane"], " xo-crit-row ")))
        self.assertIn(OLD_VERDICT["derivation"][:40],
                      " ".join(out["paneText"]))


PAGE = """<!doctype html><html><head><meta charset="utf-8">
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
              text: pill.textContent});
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
            self.assertIn("core", r["text"])


if __name__ == "__main__":
    unittest.main()
