"""S213 GROUP C, the data half — the First Officer's report GROUPED BY MISSION.

The captain's complaint, in his own words: *"I'm so lost what issues its talking
about and what I should focus my attention on."* 29 flat rows where an
observation and a personal escalation carried identical weight, the machine's
own lifecycle steps outnumbering the news.

The cure is a grouping, and the grouping is RECORDED HERE, in the one builder
both the CLI and the board read (`xo-report.py`), never worked out twice in two
front ends that would eventually disagree:

  * **C4** — `missions` carries one row per mission that has news, its entries
    inside it, newest mission first.
  * **C11** (the captain's ruling, 2026-09-17) — a mission that NEEDS HIM sorts
    FIRST, block intact. A needs-you entry never floats out of its mission.
  * **C5** — ✓ Seen marks ONE entry. Its mission's count drops by one, its
    siblings are untouched, and NOTHING is deleted: `history` still carries
    every entry the journal ever held, seen or not.
  * **C6** — clearing the LAST entry leaves the mission with `newCount == 0`,
    which is what dims it and re-tags it on screen. It does NOT remove it: a
    mission that vanishes the moment you deal with it takes its context away
    with it, and the quiet ones are supposed to stay out of the way WITHOUT
    vanishing.

The RANK of an entry is a lookup on its recorded `action`, never a reading of
its prose (INFER-VS-RECORD — the defect class that has cost this project four
rounds). Three ranks: `needs-you`, `verdict`, `step`. Steps fold under the
verdict they led to.

No gh, no network, no model, no worker — every fact here is a local file read.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402

import importlib.util  # noqa: E402

XO_REPORT = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo-report.py"))


def _load_module():
    spec = importlib.util.spec_from_file_location("xo_report_s213", XO_REPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


QUIET = "lcars-20260917-201"      # a verdict, nothing needing him
LOUD = "lcars-20260917-202"       # an escalation — this one needs him
OLDEST = "lcars-20260917-203"     # older news than either


class GroupedReportBase(unittest.TestCase):

    def setUp(self):
        if not os.path.isfile(XO_REPORT):
            self.skipTest("xo-report.py not present in this tree")
        self.mod = _load_module()
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.seen = os.path.join(self.tmp, ".git", "lcars", "xo-seen.json")

        fx.plant_simple(self.tmp, QUIET, stage="verify", issue=8,
                        title="worldToScreen / screenToWorld")
        fx.plant_simple(self.tmp, LOUD, stage="verify", issue=3,
                        title="Editor shell UI audit")
        fx.plant_simple(self.tmp, OLDEST, stage="verify", issue=2,
                        title="Player sprite on a rendered tilemap")

        # QUIET: a look — five lifecycle steps and one verdict, newest of all.
        _write_jsonl(fx.mission_dir(self.tmp, QUIET) + "/number-one.jsonl", [
            {"at": "2026-09-17T05:56:37Z", "action": "launched",
             "detail": "Launched the build"},
            {"at": "2026-09-17T05:57:13Z", "action": "looked"},
            {"at": "2026-09-17T05:57:16Z", "action": "actions"},
            {"at": "2026-09-17T05:58:59Z", "action": "scored",
             "score": "medium",
             "why": "I could not check the main thing you asked for"},
        ])
        # LOUD: an older verdict, then an escalation. It needs him.
        _write_jsonl(fx.mission_dir(self.tmp, LOUD) + "/number-one.jsonl", [
            {"at": "2026-09-17T04:30:00Z", "action": "looked"},
            {"at": "2026-09-17T04:35:00Z", "action": "scored",
             "score": "low", "why": "a black box hides the import button"},
            {"at": "2026-09-17T04:41:00Z", "action": "escalated",
             "detail": "a bug it filed stopped before it could be fixed"},
        ])
        # OLDEST: one verdict, days ago.
        _write_jsonl(fx.mission_dir(self.tmp, OLDEST) + "/number-one.jsonl", [
            {"at": "2026-09-15T10:00:00Z", "action": "scored",
             "score": "high", "why": "everything you asked for is there"},
        ])

    def build(self):
        return self.mod.build_report(
            os.path.join(self.tmp, ".git", "lcars", "missions"), self.seen)

    def rows(self, report):
        return {m["id"]: m for m in report["missions"]}


class C4_EntriesGroupUnderTheirMission(GroupedReportBase):
    """C4 — one row per mission, its own entries inside it."""

    def test_there_is_a_grouped_view_at_all(self):
        r = self.build()
        self.assertIn("missions", r)
        self.assertEqual(3, len(r["missions"]))

    def test_each_entry_sits_under_its_own_mission(self):
        rows = self.rows(self.build())
        for mid, row in rows.items():
            for e in row["entries"]:
                self.assertEqual(mid, e["mission"])

    def test_a_mission_row_names_the_mission_the_way_the_captain_reads_it(self):
        rows = self.rows(self.build())
        self.assertEqual("Editor shell UI audit", rows[LOUD]["title"])
        self.assertEqual(3, rows[LOUD]["issue"])

    def test_lifecycle_steps_fold_under_the_verdict_they_led_to(self):
        rows = self.rows(self.build())
        top = rows[QUIET]["entries"]
        # Three steps and one verdict went in; ONE row comes out, carrying
        # the three steps folded underneath it.
        self.assertEqual(1, len(top))
        self.assertEqual("scored", top[0]["action"])
        self.assertEqual("verdict", top[0]["rank"])
        self.assertEqual(3, len(top[0]["steps"]))
        self.assertEqual(["launched", "looked", "actions"],
                         [s["action"] for s in top[0]["steps"]])

    def test_the_rank_is_a_lookup_on_the_recorded_action(self):
        rows = self.rows(self.build())
        by_action = {e["action"]: e["rank"] for e in rows[LOUD]["entries"]}
        self.assertEqual("needs-you", by_action["escalated"])
        self.assertEqual("verdict", by_action["scored"])

    def test_newest_mission_first_among_the_ones_that_do_not_need_him(self):
        r = self.build()
        ids = [m["id"] for m in r["missions"]]
        self.assertLess(ids.index(QUIET), ids.index(OLDEST))


class C11_ANeedsYouMissionSortsFirst(GroupedReportBase):
    """C11 — the captain's ruling. The ITEM does not float; its MISSION does,
    block intact, so he sees the item AND its context."""

    def test_the_mission_that_needs_him_is_the_first_block(self):
        r = self.build()
        self.assertEqual(LOUD, r["missions"][0]["id"])

    def test_it_sorts_first_even_though_its_news_is_older(self):
        rows = self.rows(self.build())
        newest_loud = max(e["at"] for e in rows[LOUD]["entries"])
        newest_quiet = max(e["at"] for e in rows[QUIET]["entries"])
        self.assertLess(newest_loud, newest_quiet)  # genuinely older news
        self.assertEqual(LOUD, self.build()["missions"][0]["id"])

    def test_the_needs_you_entry_stays_inside_its_own_block(self):
        rows = self.rows(self.build())
        actions = [e["action"] for e in rows[LOUD]["entries"]]
        self.assertIn("escalated", actions)
        for other in (QUIET, OLDEST):
            self.assertNotIn("escalated",
                             [e["action"] for e in rows[other]["entries"]])

    def test_the_block_says_it_needs_him(self):
        rows = self.rows(self.build())
        self.assertTrue(rows[LOUD]["needsYou"])
        self.assertFalse(rows[QUIET]["needsYou"])


class C5_SeenMovesOneEntryAndNeverDeletes(GroupedReportBase):
    """C5 — ✓ Seen is "I have dealt with this", never "this is gone"."""

    def a_key(self, mid, action):
        rows = self.rows(self.build())
        for e in rows[mid]["entries"]:
            if e["action"] == action:
                return e["key"]
        self.fail("no %s entry on %s" % (action, mid))

    def test_every_entry_carries_a_stable_key_to_mark(self):
        rows = self.rows(self.build())
        keys = [e["key"] for row in rows.values() for e in row["entries"]]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(keys, [e["key"] for row in self.rows(self.build()).values()
                                for e in row["entries"]])

    def test_marking_one_clears_exactly_that_one(self):
        key = self.a_key(LOUD, "escalated")
        self.mod.mark_entry_seen(self.seen, key)
        rows = self.rows(self.build())
        self.assertNotIn("escalated",
                         [e["action"] for e in rows[LOUD]["entries"]])
        self.assertIn("scored", [e["action"] for e in rows[LOUD]["entries"]])

    def test_the_count_drops_by_exactly_one(self):
        before = self.rows(self.build())[LOUD]["newCount"]
        self.mod.mark_entry_seen(self.seen, self.a_key(LOUD, "escalated"))
        after = self.rows(self.build())[LOUD]["newCount"]
        self.assertEqual(before - 1, after)

    def test_a_sibling_mission_is_untouched(self):
        before = self.rows(self.build())[QUIET]["newCount"]
        self.mod.mark_entry_seen(self.seen, self.a_key(LOUD, "escalated"))
        self.assertEqual(before, self.rows(self.build())[QUIET]["newCount"])

    def test_history_still_carries_it_afterwards(self):
        self.mod.mark_entry_seen(self.seen, self.a_key(LOUD, "escalated"))
        hist = {h["id"]: h for h in self.build()["history"]}
        actions = [e["action"] for e in hist[LOUD]["entries"]]
        self.assertIn("escalated", actions)
        self.assertEqual(3, len(actions))

    def test_the_journal_file_itself_is_never_touched(self):
        path = fx.mission_dir(self.tmp, LOUD) + "/number-one.jsonl"
        with open(path) as fh:
            before = fh.read()
        self.mod.mark_entry_seen(self.seen, self.a_key(LOUD, "escalated"))
        with open(path) as fh:
            self.assertEqual(before, fh.read())

    def test_marking_a_verdict_takes_its_folded_steps_with_it(self):
        self.mod.mark_entry_seen(self.seen, self.a_key(QUIET, "scored"))
        rows = self.rows(self.build())
        self.assertEqual(0, rows[QUIET]["newCount"])  # nothing new left
        self.assertEqual([], rows[QUIET]["entries"])
        hist = {h["id"]: h for h in self.build()["history"]}
        self.assertEqual(4, len(hist[QUIET]["entries"]))  # all four kept

    def test_the_seen_count_the_history_line_shows_goes_up(self):
        before = self.build()["seenCount"]
        self.mod.mark_entry_seen(self.seen, self.a_key(LOUD, "escalated"))
        self.assertEqual(before + 1, self.build()["seenCount"])


class C6_ClearingTheLastEntryQuietsTheMission(GroupedReportBase):

    def test_a_mission_with_nothing_new_left_reports_a_zero_count(self):
        rows = self.rows(self.build())
        for e in list(rows[LOUD]["entries"]):
            self.mod.mark_entry_seen(self.seen, e["key"])
        r = self.build()
        # STILL THERE, and quiet. `newCount: 0` is what dims it and re-tags it;
        # its whole journal is still in history, as it always will be.
        self.assertEqual(0, self.rows(r)[LOUD]["newCount"])
        self.assertFalse(self.rows(r)[LOUD]["needsYou"])
        hist = {h["id"]: h for h in r["history"]}
        self.assertEqual(3, len(hist[LOUD]["entries"]))

    def test_a_quiet_mission_sorts_below_the_ones_with_news(self):
        rows = self.rows(self.build())
        for e in list(rows[LOUD]["entries"]):
            self.mod.mark_entry_seen(self.seen, e["key"])
        ids = [m["id"] for m in self.build()["missions"]]
        self.assertEqual(ids[-1], LOUD)

    def test_clearing_all_but_one_leaves_the_mission_with_one(self):
        rows = self.rows(self.build())
        first = rows[LOUD]["entries"][0]
        self.mod.mark_entry_seen(self.seen, first["key"])
        self.assertEqual(1, self.rows(self.build())[LOUD]["newCount"])


class C7_TheFiltersCarryTheirOwnCounts(GroupedReportBase):
    """C7's data half — the three filter counts come off the record, so the
    board never counts them a second way."""

    def test_the_three_counts_are_recorded(self):
        counts = self.build()["counts"]
        self.assertEqual(1, counts["needs"])     # one escalation
        self.assertEqual(3, counts["verdicts"])  # three scored looks
        self.assertEqual(8, counts["all"])       # every new entry, steps too

    def test_clearing_the_escalation_empties_the_needs_you_filter(self):
        rows = self.rows(self.build())
        key = [e for e in rows[LOUD]["entries"]
               if e["action"] == "escalated"][0]["key"]
        self.mod.mark_entry_seen(self.seen, key)
        self.assertEqual(0, self.build()["counts"]["needs"])


class TheOldSurfacesStillWork(GroupedReportBase):
    """The grouped view is ADDITIVE. `since` and `history` — which the CLI's
    text renderer and every older test read — keep their shape exactly."""

    def test_since_is_still_a_flat_newest_first_list(self):
        since = self.build()["since"]
        self.assertEqual(8, since["count"])
        ats = [e["at"] for e in since["entries"]]
        self.assertEqual(sorted(ats, reverse=True), ats)

    def test_history_still_holds_every_entry_of_every_mission(self):
        hist = {h["id"]: h for h in self.build()["history"]}
        self.assertEqual(4, len(hist[QUIET]["entries"]))
        self.assertEqual(3, len(hist[LOUD]["entries"]))
        self.assertEqual(1, len(hist[OLDEST]["entries"]))

    def test_the_wholesale_mark_still_clears_everything(self):
        self.mod.write_seen(self.seen, "2026-09-18T00:00:00Z")
        r = self.build()
        self.assertEqual(0, r["since"]["count"])
        self.assertEqual([0, 0, 0], [m["newCount"] for m in r["missions"]])
        self.assertEqual(8, len(
            [e for h in r["history"] for e in h["entries"]]))


if __name__ == "__main__":
    unittest.main()
