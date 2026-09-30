"""S213 C4, C5, C6, C7 and the rulings C10/C11 — the report ON SCREEN.

The board half of `test_xo_report_grouped.py`. Every payload here is built by
the REAL `xo-report.py` off a REAL journal on disk, and every ✓ Seen answer is
what the daemon would really return (a real `mark_entry_seen`, then a real
rebuild) — so this proves the front end against the server's actual words, not
against a shape a test author imagined.

  C4  entries group under their mission, newest mission first
  C5  ✓ Seen moves ONE entry to history, decrements the count, never deletes
  C6  clearing the last entry dims the mission and re-tags it
  C7  the default filter is Needs-you, and by-time is one tap away
  C10 (his ruling) mission blocks are NOT collapsible — lifecycle steps already
      fold, and a collapsed block can hide a needs-you item
  C11 (his ruling) a needs-you item does not float out of its block; its
      MISSION sorts first, block intact

A NODE DOM IS A STUB OF A BROWSER. This proves the wiring; the picture is the
tester's job.
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

from tests import _fixtures as fx  # noqa: E402

HARNESS = os.path.join(HERE, "board_xo_report_harness.js")
XO_REPORT = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo-report.py"))
NODE = shutil.which("node")

QUIET = "lcars-20260917-201"
LOUD = "lcars-20260917-202"
OLDEST = "lcars-20260917-203"


def _mod():
    spec = importlib.util.spec_from_file_location("xo_report_render", XO_REPORT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


def _flatten(node, out=None):
    out = [] if out is None else out
    if not node:
        return out
    out.append(node)
    for kid in node.get("children") or []:
        _flatten(kid, out)
    return out


def _cls_of(node, needle):
    return [n for n in _flatten(node)
            if needle in (" " + (n.get("cls") or "") + " ")]


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ReportRenderBase(unittest.TestCase):

    def setUp(self):
        if not os.path.isfile(XO_REPORT):
            self.skipTest("xo-report.py not present in this tree")
        self.mod = _mod()
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.seen = os.path.join(self.tmp, ".git", "lcars", "xo-seen.json")

        fx.plant_simple(self.tmp, QUIET, stage="verify", issue=8,
                        title="worldToScreen / screenToWorld")
        fx.plant_simple(self.tmp, LOUD, stage="verify", issue=3,
                        title="Editor shell UI audit")
        fx.plant_simple(self.tmp, OLDEST, stage="verify", issue=2,
                        title="Player sprite on a rendered tilemap")
        # …each with the Number One block its own `xo evaluate` records, since
        # the mission header's chip wears that recorded score.
        for mid, score in ((QUIET, "medium"), (LOUD, "low"), (OLDEST, "high")):
            path = os.path.join(fx.mission_dir(self.tmp, mid), "state.json")
            with open(path) as fh:
                doc = json.load(fh)
            doc["numberOne"] = {"status": "engaged", "engine": "copilot",
                                "score": score}
            with open(path, "w") as fh:
                json.dump(doc, fh)
        _write_jsonl(fx.mission_dir(self.tmp, QUIET) + "/number-one.jsonl", [
            {"at": "2026-09-17T05:56:37Z", "action": "launched",
             "detail": "Launched the build — http://localhost:5174"},
            {"at": "2026-09-17T05:57:13Z", "action": "looked"},
            {"at": "2026-09-17T05:57:16Z", "action": "actions"},
            {"at": "2026-09-17T05:58:59Z", "action": "scored", "score": "medium",
             "why": "I could not check the main thing you asked for — your "
                    "test suite never ran."},
        ])
        _write_jsonl(fx.mission_dir(self.tmp, LOUD) + "/number-one.jsonl", [
            {"at": "2026-09-17T04:30:00Z", "action": "looked"},
            {"at": "2026-09-17T04:35:00Z", "action": "scored", "score": "low",
             "why": "a near-black box hides the + Import Tileset button"},
            {"at": "2026-09-17T04:41:00Z", "action": "escalated",
             "detail": "a bug it filed stopped before it could be fixed"},
        ])
        _write_jsonl(fx.mission_dir(self.tmp, OLDEST) + "/number-one.jsonl", [
            {"at": "2026-09-15T10:00:00Z", "action": "scored", "score": "high",
             "why": "everything you asked for is in the build"},
        ])

    def build(self):
        return self.mod.build_report(
            os.path.join(self.tmp, ".git", "lcars", "missions"), self.seen)

    def key(self, mid, action):
        for row in self.build()["missions"]:
            if row["id"] != mid:
                continue
            for e in row["entries"]:
                if e["action"] == action:
                    return e["key"]
        self.fail("no %s entry on %s" % (action, mid))

    def drive(self, clicks=None, seen_responses=None, data=None):
        spec = {"reportData": data if data is not None else self.build(),
                "clicks": clicks or [],
                "seenResponses": seen_responses or []}
        with tempfile.NamedTemporaryFile("w", suffix=".json",
                                         delete=False) as fh:
            json.dump(spec, fh)
            path = fh.name
        try:
            proc = subprocess.run([NODE, HARNESS, path],
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
            if proc.returncode != 0:
                raise AssertionError(
                    proc.stderr.decode("utf-8", "replace"))
            out = json.loads(proc.stdout.decode("utf-8"))
        finally:
            os.unlink(path)
        self.assertEqual([], out["bootErrors"], "board.js threw on boot")
        return out


class C7_HeLandsOnNeedsYou(ReportRenderBase):

    def test_the_default_filter_is_needs_you(self):
        out = self.drive()
        on = [c for c in out["atOpen"]["chips"] if " on" in (" " + c["cls"])]
        self.assertEqual(1, len(on))
        self.assertTrue(on[0]["text"].startswith("Needs you"))

    def test_every_chip_carries_its_own_count(self):
        texts = [c["text"] for c in self.drive()["atOpen"]["chips"]]
        self.assertEqual(["Needs you · 1", "Verdicts · 3", "Everything · 8"],
                         texts)

    def test_the_firehose_is_still_one_tap_away(self):
        out = self.drive(clicks=["all"])
        after = out["afterClicks"][0]
        self.assertIsNone(after["error"])
        on = [c for c in after["chips"] if " on" in (" " + c["cls"])]
        self.assertEqual("Everything · 8", on[0]["text"])

    def test_by_time_is_one_tap_away_and_by_mission_is_where_he_lands(self):
        out = self.drive()
        views = out["atOpen"]["views"]
        self.assertEqual(["By mission", "By time"], [v["text"] for v in views])
        on = [v for v in views if " on" in (" " + v["cls"])]
        self.assertEqual(["mission"], [v["view"] for v in on])

    def test_the_by_time_view_is_the_old_flat_list_unharmed(self):
        out = self.drive(clicks=[{"view": "time"}, "all"])
        after = out["afterClicks"][-1]
        self.assertIsNone(after["error"])
        self.assertEqual(8, len(after["flat"]))
        self.assertEqual([], after["groups"])

    def test_needs_you_shows_only_the_mission_that_needs_him(self):
        out = self.drive()
        groups = out["atOpen"]["groups"]
        self.assertEqual([LOUD], [g["mission"] for g in groups])


class C4_GroupedByMission(ReportRenderBase):

    def groups(self):
        return self.drive(clicks=["all"])["afterClicks"][0]["groups"]

    def test_one_block_per_mission(self):
        self.assertEqual(3, len(self.groups()))

    def test_the_block_names_the_mission_the_way_he_reads_it(self):
        g = [x for x in self.groups() if x["mission"] == LOUD][0]
        self.assertEqual("#3", _cls_of(g, " xo-mid ")[0]["text"])
        self.assertEqual("Editor shell UI audit",
                         _cls_of(g, " xo-mname ")[0]["text"])

    def test_a_filtered_block_says_how_many_it_is_hiding(self):
        """A header reading "2 new" above ONE visible row is a small lie of
        exactly the kind this session exists to stop."""
        out = self.drive()  # the Needs-you view: one of LOUD's two is hidden
        loud = [g for g in out["atOpen"]["groups"] if g["mission"] == LOUD][0]
        self.assertEqual("2 new · 1 here",
                         _cls_of(loud, " xo-mcount ")[0]["text"])

    def test_and_says_nothing_extra_when_it_is_hiding_nothing(self):
        out = self.drive(clicks=["all"])
        loud = [g for g in out["afterClicks"][0]["groups"]
                if g["mission"] == LOUD][0]
        self.assertEqual("2 new", _cls_of(loud, " xo-mcount ")[0]["text"])

    def test_the_block_carries_a_status_chip_and_a_new_count(self):
        g = [x for x in self.groups() if x["mission"] == QUIET][0]
        self.assertEqual("◈ medium", _cls_of(g, " xo-mtag ")[0]["text"])
        self.assertEqual("1 new", _cls_of(g, " xo-mcount ")[0]["text"])

    def test_the_full_title_is_not_repeated_on_every_row(self):
        g = [x for x in self.groups() if x["mission"] == LOUD][0]
        rows = _cls_of(g, " xo-entry ")
        self.assertEqual(2, len(rows))
        for r in rows:
            self.assertNotIn("Editor shell UI audit", r["text"])

    def test_the_timestamps_are_not_utc_to_the_second(self):
        g = [x for x in self.groups() if x["mission"] == LOUD][0]
        for w in _cls_of(g, " xo-entry-when "):
            self.assertNotIn("Z", w["text"])
            self.assertNotIn("T04:", w["text"])

    def test_lifecycle_steps_are_folded_not_shouting(self):
        g = [x for x in self.groups() if x["mission"] == QUIET][0]
        folds = _cls_of(g, " xo-fold ")
        self.assertEqual(1, len(folds))
        self.assertIn("3 steps it took to get there", folds[0]["text"])
        # and the steps are NOT entries of their own competing for his eye
        self.assertEqual(1, len(_cls_of(g, " xo-entry ")))

    def test_every_mission_header_is_a_way_into_the_mission(self):
        for g in self.groups():
            ways = _cls_of(g, " xo-mopen ")
            self.assertEqual(1, len(ways))
            self.assertEqual(g["mission"], ways[0]["mission"])

    def test_the_way_in_opens_that_mission(self):
        out = self.drive(clicks=["all", {"open": QUIET}])
        gets = [f for f in out["fetches"]
                if f["method"] == "GET" and QUIET in f["url"]
                and "/api/mission/" in f["url"]]
        self.assertTrue(gets, "clicking the header opened nothing")


class C11_TheNeedsYouMissionSortsFirst(ReportRenderBase):

    def test_its_block_is_the_first_one_on_the_page(self):
        groups = self.drive(clicks=["all"])["afterClicks"][0]["groups"]
        self.assertEqual(LOUD, groups[0]["mission"])

    def test_the_item_itself_stays_inside_that_block(self):
        groups = self.drive(clicks=["all"])["afterClicks"][0]["groups"]
        loud = [g for g in groups if g["mission"] == LOUD][0]
        needs = _cls_of(loud, " r-needs-you ")
        self.assertEqual(1, len(needs))
        # and nowhere else on the page
        for g in groups:
            if g["mission"] == LOUD:
                continue
            self.assertEqual([], _cls_of(g, " r-needs-you "))

    def test_the_three_ranks_are_visibly_different(self):
        groups = self.drive(clicks=["all"])["afterClicks"][0]["groups"]
        loud = [g for g in groups if g["mission"] == LOUD][0]
        ranks = [e["cls"] for e in _cls_of(loud, " xo-entry ")]
        self.assertTrue(any("r-needs-you" in c for c in ranks))
        self.assertTrue(any("r-verdict" in c for c in ranks))


class C10_MissionBlocksDoNotCollapse(ReportRenderBase):
    """His ruling, 2026-09-17, and his reason: the lifecycle steps already
    fold, and a collapsed block can hide a needs-you item — the one thing this
    report exists to surface."""

    def test_no_mission_block_is_a_details_element(self):
        groups = self.drive(clicks=["all"])["afterClicks"][0]["groups"]
        for g in groups:
            self.assertNotEqual("details", g["tag"])
            for n in _flatten(g):
                if n["tag"] == "details":
                    self.assertIn("xo-fold", n["cls"],
                                  "something other than the step fold "
                                  "collapses inside a mission block")

    def test_the_needs_you_item_is_visible_without_opening_anything(self):
        groups = self.drive()["atOpen"]["groups"]
        loud = [g for g in groups if g["mission"] == LOUD][0]
        needs = _cls_of(loud, " r-needs-you ")[0]
        self.assertIn("a bug it filed stopped", needs["text"])


class S223D5_SeenAllClearsExactlyWhatItNames(ReportRenderBase):
    """S223 fix round 1 (D5) — ✓ SEEN ALL N CLEARS N, NOT THE BACKLOG.

    The fresh tester pressed a header button labelled "SEEN ALL 7" under the
    Verdicts filter. Seven rows were on screen; forty-eight entries left the
    news and history jumped 7 → 48. The button named one number and did
    another thing. It now sends the KEYS of the rows it counted, so the label
    and the act are the same list by construction."""

    def loud_keys(self, action=None):
        rows = {r["id"]: r for r in self.build()["missions"]}
        return [e["key"] for e in rows[LOUD]["entries"]
                if action is None or e["action"] == action]

    def posted(self, out):
        return [f["body"] for f in out["fetches"]
                if f["method"] == "POST" and f["url"] == "/api/xo/seen"]

    def test_under_a_filter_the_label_counts_only_the_rows_on_screen(self):
        # The board opens on "Needs you", which hides LOUD's verdict row.
        loud = [g for g in self.drive()["atOpen"]["groups"]
                if g["mission"] == LOUD][0]
        shown = len(_cls_of(loud, " xo-entry "))
        btns = _cls_of(loud, " xo-seen-all ")
        self.assertEqual(1, len(btns))
        self.assertLess(shown, len(self.loud_keys()))   # the filter IS hiding some
        self.assertEqual("✓ Seen all %d" % shown, btns[0]["text"])

    def test_it_posts_exactly_the_keys_that_were_on_screen(self):
        out = self.drive(clicks=[{"seenAll": LOUD}])
        loud = [g for g in out["atOpen"]["groups"]
                if g["mission"] == LOUD][0]
        on_screen = [e["key"] for e in _cls_of(loud, " xo-entry ")]
        bodies = self.posted(out)
        self.assertEqual(1, len(bodies))
        self.assertEqual(on_screen, bodies[0]["entries"])
        self.assertLess(len(on_screen), len(self.loud_keys()))
        self.assertNotIn("mission", bodies[0])

    def test_everything_shown_clears_everything_shown(self):
        out = self.drive(clicks=["all", {"seenAll": LOUD}])
        bodies = self.posted(out)
        self.assertEqual(1, len(bodies))
        self.assertEqual(sorted(self.loud_keys()), sorted(bodies[0]["entries"]))

    def test_a_sibling_missions_entries_are_never_in_the_body(self):
        out = self.drive(clicks=["all", {"seenAll": LOUD}])
        body = self.posted(out)[0]
        for k in body["entries"]:
            self.assertTrue(k.startswith(LOUD), k)

    def test_the_button_still_says_nothing_is_deleted(self):
        out = self.drive(clicks=["all"])
        loud = [g for g in out["afterClicks"][0]["groups"]
                if g["mission"] == LOUD][0]
        self.assertEqual(1, len(_cls_of(loud, " xo-seen-all ")))


class C5_SeenClearsOneAndDeletesNothing(ReportRenderBase):

    def test_every_entry_has_its_own_seen_button(self):
        groups = self.drive(clicks=["all"])["afterClicks"][0]["groups"]
        for g in groups:
            for ent in _cls_of(g, " xo-entry "):
                buttons = _cls_of(ent, " xo-seen ")
                self.assertEqual(1, len(buttons))
                self.assertEqual(ent["key"], buttons[0]["key"])

    def test_clicking_it_names_that_one_entry_to_the_daemon(self):
        key = self.key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        after = self.build()
        # put the journal back the way the board first saw it
        os.remove(self.seen)
        out = self.drive(clicks=["all", {"seen": key}],
                         seen_responses=[after])
        posts = [f for f in out["fetches"]
                 if f["method"] == "POST" and f["url"] == "/api/xo/seen"]
        self.assertEqual(1, len(posts))
        self.assertEqual({"entry": key}, posts[0]["body"])

    def test_the_entry_leaves_the_block_and_its_sibling_stays(self):
        key = self.key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        after = self.build()
        os.remove(self.seen)
        out = self.drive(clicks=["all", {"seen": key}], seen_responses=[after])
        groups = out["afterClicks"][-1]["groups"]
        loud = [g for g in groups if g["mission"] == LOUD][0]
        keys = [e["key"] for e in _cls_of(loud, " xo-entry ")]
        self.assertNotIn(key, keys)
        self.assertEqual(1, len(keys))

    def test_the_count_on_the_block_drops_by_one(self):
        key = self.key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        after = self.build()
        os.remove(self.seen)
        out = self.drive(clicks=["all", {"seen": key}], seen_responses=[after])
        before = [g for g in out["afterClicks"][0]["groups"]
                  if g["mission"] == LOUD][0]
        now = [g for g in out["afterClicks"][-1]["groups"]
               if g["mission"] == LOUD][0]
        self.assertEqual("2 new", _cls_of(before, " xo-mcount ")[0]["text"])
        self.assertEqual("1 new", _cls_of(now, " xo-mcount ")[0]["text"])

    def test_the_screen_says_in_as_many_words_that_nothing_is_deleted(self):
        line = self.drive()["atOpen"]["histLine"]
        self.assertIn("kept for good", line)
        self.assertIn("Nothing is ever deleted", line)

    def test_the_cleared_entry_is_still_in_history_on_screen(self):
        key = self.key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        after = self.build()
        os.remove(self.seen)
        out = self.drive(clicks=["all", {"seen": key}], seen_responses=[after])
        tree = out["afterClicks"][-1]["tree"]
        hist = _cls_of(tree, " xo-report-history ")[0]
        self.assertIn("a bug it filed stopped", hist["text"])

    def test_the_already_seen_count_goes_up(self):
        key = self.key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        after = self.build()
        os.remove(self.seen)
        out = self.drive(clicks=["all", {"seen": key}], seen_responses=[after])
        self.assertIn("0 already seen", out["afterClicks"][0]["histLine"])
        self.assertIn("1 already seen", out["afterClicks"][-1]["histLine"])


class C6_ClearingTheLastEntryDimsTheMission(ReportRenderBase):

    def _clear_all_of(self, mid):
        keys = [e["key"] for row in self.build()["missions"]
                if row["id"] == mid for e in row["entries"]]
        responses = []
        for k in keys:
            self.mod.mark_entry_seen(self.seen, k)
            responses.append(self.build())
        self.cleared = responses[-1]
        os.remove(self.seen)   # the board opens on the state BEFORE the clicks
        clicks = ["all"] + [{"seen": k} for k in keys]
        return self.drive(clicks=clicks, seen_responses=responses)

    def test_the_block_dims_rather_than_vanishing(self):
        out = self._clear_all_of(LOUD)
        groups = out["afterClicks"][-1]["groups"]
        loud = [g for g in groups if g["mission"] == LOUD]
        self.assertEqual(1, len(loud), "the mission vanished when he cleared it")
        self.assertIn("quiet", loud[0]["cls"])

    def test_it_is_re_tagged_as_dealt_with(self):
        out = self._clear_all_of(LOUD)
        loud = [g for g in out["afterClicks"][-1]["groups"]
                if g["mission"] == LOUD][0]
        self.assertEqual("◈ seen", _cls_of(loud, " xo-mtag ")[0]["text"])
        self.assertEqual("nothing new", _cls_of(loud, " xo-mcount ")[0]["text"])

    def test_it_no_longer_claims_to_need_him(self):
        out = self._clear_all_of(LOUD)
        loud = [g for g in out["afterClicks"][-1]["groups"]
                if g["mission"] == LOUD][0]
        self.assertNotIn("needs", (" " + loud["cls"]).replace(" xo-mgrp", ""))

    def test_a_quiet_mission_stays_out_of_the_needs_you_view(self):
        self._clear_all_of(LOUD)
        # Re-opening the report later, with the clears already on disk: the
        # mission he dealt with is not what "Needs you" is for.
        back = self.drive(data=self.cleared)
        self.assertEqual([], back["atOpen"]["groups"])

    def test_but_it_is_still_there_under_everything(self):
        self._clear_all_of(LOUD)
        back = self.drive(data=self.cleared, clicks=["all"])
        groups = back["afterClicks"][0]["groups"]
        self.assertIn(LOUD, [g["mission"] for g in groups])


WHY_FIXTURE = os.path.normpath(os.path.join(
    HERE, "..", "..", "tests", "drives", "s223", "why-this-grade.txt"))


class D1_TheNewsRendersTheReasoningTheSameWayTheReportDoes(ReportRenderBase):
    """S223 fix round 2, D1 + D2.

    The tester opened Number One → First Officer's report → Everything and
    counted 46 literal `**` on screen: the verdict entry printed the whole
    unclipped `whyThisGrade` as PLAIN TEXT, while the mission report rendered
    the identical string as markdown. One string, two treatments, and the
    loud one was the wrong one.

    D2 is the same string's other half. It carries an ODD number of `**` (23
    on the captain's own report — a `**lead…` whose closer went with the
    truncation), and round 1's "drop the last marker" balancing dropped the
    WRONG one: the emphasis inverted, seven lines came out bold and the two
    words the record really marked came out plain.
    """

    def _say(self, why):
        data = self.build()
        for row in data["missions"]:
            for e in row["entries"]:
                if e["action"] == "scored":
                    e["whyThisGrade"] = why
        out = self.drive(clicks=["all"], data=data)
        says = _cls_of({"children": out["afterClicks"][0]["groups"]},
                       " xo-entry-say ")
        # Only the VERDICT entries — the other ranks say their own one-liner,
        # and this is about the string the look recorded.
        needle = why.replace("**", "").split(".")[0].split(";")[0][:24].strip()
        mine = [s for s in says if needle and needle in (
            self._visible(self._html(s)).replace("&quot;", '"')
            .replace("&amp;", "&") + " " + (s.get("text") or ""))]
        self.assertTrue(mine, "the recorded reasoning reached no entry")
        return mine

    @staticmethod
    def _html(node):
        return "".join(n.get("html") or "" for n in _flatten(node))

    @staticmethod
    def _bold(html):
        import re
        return re.findall(r"<strong>(.*?)</strong>", html)

    @staticmethod
    def _visible(html):
        import re
        return re.sub(r"<[^>]*>", "", html)

    def test_the_real_report_puts_no_raw_asterisks_on_screen(self):
        why = open(WHY_FIXTURE).read()
        self.assertEqual(23, why.count("**"), "fixture drifted")
        for say in self._say(why):
            self.assertNotIn("**", self._visible(self._html(say)))
            self.assertNotIn("**", say["text"])

    def test_the_entry_is_clipped_to_a_lead_not_the_whole_essay(self):
        why = open(WHY_FIXTURE).read()
        for say in self._say(why):
            lead = [n for n in _flatten(say)
                    if " xo-why-body " in " " + (n.get("cls") or "") + " "][0]
            self.assertLess(len(self._visible(lead["html"])), 600,
                            "the lead is still the whole essay")

    def test_and_the_rest_is_reachable_the_way_the_mission_report_offers_it(self):
        why = open(WHY_FIXTURE).read()
        for say in self._say(why):
            more = [n for n in _flatten(say) if n.get("tag") == "details"]
            self.assertEqual(1, len(more))
            self.assertIn("Show the full reasoning", more[0]["text"])
            # …and every word the record wrote is still in there.
            self.assertIn("Re-pull", self._visible(self._html(more[0])))

    def test_the_words_the_record_marked_are_the_bold_ones(self):
        why = open(WHY_FIXTURE).read()
        for say in self._say(why):
            bold = self._bold(self._html(say))
            self.assertIn("Refresh-all", bold)
            self.assertIn("Nav actions:", bold)
            self.assertIn("Reviews entry screen", bold)
            # …and nothing enormous: an inverted run swallowed whole lines.
            self.assertTrue(all(len(b) < 120 for b in bold), bold)

    def test_odd_markers_anywhere_never_invert_and_never_lose_a_word(self):
        cases = [
            # (string, the words the record marked)
            ("**Alpha beta. Then gamma and **delta** and more text here.",
             ["Alpha beta", "delta"]),
            ("**One** here; **Two truncated\u2026; **Three** ends it.",
             ["One", "Two truncated\u2026", "Three"]),
            ("Some text with **Marked** words and a trailing **",
             ["Marked"]),
            ("Lead in: **Reviews entry screen\u2026; **Builder** matches it.",
             ["Reviews entry screen\u2026", "Builder"]),
        ]
        for src, want in cases:
            for say in self._say(src):
                html = self._html(say)
                self.assertEqual(want, self._bold(html), src)
                self.assertNotIn("**", self._visible(html), src)
                # NO WORD IS LOST: strip the markers from the source and the
                # text on screen is the same run of words.
                self.assertEqual(
                    " ".join(src.replace("**", "").split()),
                    " ".join(self._visible(html).replace("&quot;", '"')
                             .replace("&amp;", "&").split()),
                    src)


if __name__ == "__main__":
    unittest.main()
