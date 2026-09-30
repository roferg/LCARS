"""S217 fix round 1, D1 — the ◈ Number One tab says WHICH file was a picture
and WHAT TO DO about it.

The tester clicked "⊙ READ THE FULL REPORT" on a picture-only card: the card's
line truncates to "your attachment is a picture, …", and the tab it opens showed
the headline, the summary, the criteria and also-checked — never the file, never
the fix. That text lived only in `xo/report.md` on disk.

The verdict here is written by the REAL `xo-score.py` off a real criteria.json
(the same path `lcars xo` takes), so the tab is proved against the words the
producer actually records — not against a shape a test author imagined.

Original filenames are NOT recorded anywhere a mission keeps (file.sh stages
every attachment as attachments/attachment-NN.<ext> and state.json lists only
those), so the tab names the staged name — it does not guess.

A NODE DOM IS A STUB OF A BROWSER. This proves wiring and order; the picture
is the tester's job.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import test_xo_surfaces as surf  # noqa: E402

XO_SCORE = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo-score.py"))


def _score_mod():
    spec = importlib.util.spec_from_file_location("xo_score_pic", XO_SCORE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _real_verdict(pictures, has_drawing=False):
    """Run the REAL xo-score.py over a minimal look; return its verdict.json."""
    d = tempfile.mkdtemp()
    try:
        crit = {"builtBeforeLaunch": True, "hasDrawing": has_drawing,
                "placeNames": [], "pictures": pictures,
                "criteria": [{"id": "prd-1", "text": "The page loads",
                              "primary": True}]}
        judged = {"summary": "It loads.", "score": "high",
                  "criteria": [{"id": "prd-1", "status": "met",
                                "evidence": "picture", "shot": "shot-01",
                                "note": "the page rendered"}],
                  "gaps": [], "alsoChecked": []}
        cp, jp = os.path.join(d, "criteria.json"), os.path.join(d, "judged.json")
        with open(cp, "w") as fh:
            json.dump(crit, fh)
        with open(jp, "w") as fh:
            json.dump(judged, fh)
        # usage: xo-score.py <verdict> <criteria> <out>; report.md lands
        # beside <out>.
        vp, rp = os.path.join(d, "verdict.json"), os.path.join(d, "report.md")
        proc = subprocess.run(
            [sys.executable, XO_SCORE, jp, cp, vp],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            raise AssertionError("xo-score failed: %s"
                                 % proc.stderr.decode("utf-8", "replace"))
        with open(vp) as fh:
            verdict = json.load(fh)
        with open(rp) as fh:
            report = fh.read()
        return verdict, report
    finally:
        shutil.rmtree(d, ignore_errors=True)


class PictureTab(surf.TabBase):

    def tab_for(self, verdict):
        # Only the scorer's picture fact is carried onto the TabBase fixture,
        # so the order checks can anchor on its known headline / full text /
        # criteria / also-checked.
        over = {k: verdict[k] for k in ("pictureNotDrawing",) if k in verdict}
        return self.mi(verdict=over)

    def picture_blocks(self, out):
        return surf._cls_of(out["pane"], " xo-picture ")


class D1_TheTabNamesThePictureAndTheFix(PictureTab):

    def setUp(self):
        super().setUp()
        self.verdict, self.report = _real_verdict(["attachment-01.png"])
        self.assertIn("pictureNotDrawing", self.verdict,
                      "precondition: the real scorer recorded the fact")

    def test_the_tab_shows_a_picture_block(self):
        out = self.tab_for(self.verdict)
        self.assertEqual(1, len(self.picture_blocks(out)),
                         "no picture note on the tab at all")

    def test_it_names_the_file(self):
        out = self.tab_for(self.verdict)
        self.assertIn("attachment-01.png",
                      surf._all_text(self.picture_blocks(out)[0]))

    def test_it_says_what_to_do(self):
        text = surf._all_text(self.picture_blocks(self.tab_for(self.verdict))[0])
        for needle in (".html", "id", "concept.md", "holodeck"):
            self.assertIn(needle, text, "the fix is missing %r" % needle)

    def test_the_fix_is_the_same_words_the_report_on_disk_says(self):
        fix = self.verdict["pictureNotDrawing"].get("fix")
        self.assertTrue(fix, "the verdict does not record the fix it tells him")
        self.assertIn(fix, self.report)

    def test_several_pictures_are_all_named(self):
        v, _ = _real_verdict(["attachment-01.png", "attachment-02.jpg"])
        text = surf._all_text(self.picture_blocks(self.tab_for(v))[0])
        self.assertIn("attachment-01.png", text)
        self.assertIn("attachment-02.jpg", text)

    def test_it_sits_near_the_top_after_the_verdict_and_before_the_detail(self):
        out = self.tab_for(self.verdict)
        texts = out["paneText"]
        joined = " ⇢ ".join(texts)
        self.assertIn("MEDIUM", texts[0].upper(), "the score must still lead")
        pic_at = joined.index("attachment-01.png")
        self.assertLess(joined.index(surf.HEADLINE), pic_at,
                        "the one honest sentence must come before the note")
        self.assertLess(pic_at, joined.index(surf.LONG[:40]),
                        "the note must come before the full text")
        self.assertLess(pic_at, joined.index("worldToScreen converts correctly"),
                        "the note must come before the criteria table")

    def test_also_checked_is_still_the_last_block(self):
        out = self.tab_for(self.verdict)
        idx = [i for i, t in enumerate(out["paneText"])
               if surf.REASSURANCE[:40] in t]
        self.assertTrue(idx)
        after = " ".join(out["paneText"][idx[0] + 1:])
        self.assertNotIn("attachment-01.png", after)


class D1_NothingWhenThereIsNoPictureNote(PictureTab):

    def test_a_verdict_without_the_field_shows_no_block(self):
        self.assertEqual([], self.picture_blocks(self.mi()))

    def test_a_real_verdict_with_a_drawing_shows_no_block(self):
        v, _ = _real_verdict(["attachment-01.png"], has_drawing=True)
        self.assertNotIn("pictureNotDrawing", v)
        self.assertEqual([], self.picture_blocks(self.tab_for(v)))

    def test_a_malformed_field_renders_nothing_and_does_not_crash(self):
        for bad in ({"pictures": []}, {"pictures": "x.png"}, "yes", None):
            out = self.tab_for({"pictureNotDrawing": bad})
            self.assertEqual([], self.picture_blocks(out), repr(bad))


class D1_TheWordsAreTheScorersOwn(unittest.TestCase):

    def test_the_fix_sentence_is_one_constant_in_the_scorer(self):
        m = _score_mod()
        self.assertTrue(getattr(m, "PICTURE_FIX", ""),
                        "xo-score.py should own the fix sentence")
        for needle in (".html", "concept.md", "holodeck"):
            self.assertIn(needle, m.PICTURE_FIX)

    def test_the_boards_fallback_is_that_constant_verbatim(self):
        import re
        board = open(os.path.join(HERE, "..", "static", "board.js"),
                     encoding="utf-8").read()
        mt = re.search(r'var XO_PICTURE_FIX_FALLBACK = ((?:"[^"]*"\s*\+?\s*)+);',
                       board)
        self.assertTrue(mt, "XO_PICTURE_FIX_FALLBACK not found")
        joined = "".join(re.findall(r'"([^"]*)"', mt.group(1)))
        self.assertEqual(_score_mod().PICTURE_FIX, joined)


class D1_AVerdictWithoutTheRecordedFixStillSaysWhatToDo(PictureTab):

    def test_names_and_fix_from_the_fallback(self):
        out = self.tab_for({"pictureNotDrawing": {
            "pictures": ["attachment-03.jpg"],
            "note": "your attachment is a picture, so I could not check the "
                    "build against a drawing"}})
        text = surf._all_text(self.picture_blocks(out)[0])
        self.assertIn("attachment-03.jpg", text)
        self.assertIn("concept.md", text)
        self.assertIn("holodeck", text)


if __name__ == "__main__":
    unittest.main()
