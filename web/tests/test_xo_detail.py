"""S205 behaviours 1, 2, 7 — the ◈ Number One surfaces on the mission DETAIL.

  1. `numberOne.report` rides the `/api/mission/<id>` payload ONLY when the
     mission actually has a `number-one.jsonl` journal — absent (never null,
     never an empty object) for every mission Number One has never looked at,
     which is every mission this product has ever served until S205.
  2. Number One's own journal entries merge into the SAME activity feed
     (`bot: "number-one"`), each carrying the STAGE IT HAPPENED IN — so the
     front end can render "◈ posted by Number One" beside the ordinary
     "⬡ posted by lcars-bot" entries, inside the right per-stage band,
     chronologically interleaved with the mission's own events.
  7. Every write verb the engaged lock covers is STILL refused when the
     request names this mission through the DETAIL route rather than the
     board's own card — the detail is "the other door onto a mission"
     (S201's own words), so `test_xo_lock_endpoints.py`'s sweep (already
     exercised through `/api/mission/<id>/<verb>`) is the same door this
     payload is served through; this file adds the ONE thing that suite does
     not: that the detail's OWN read is never blocked, and that its
     `numberOne` block carries exactly what a locked mission's card carries,
     plus `report`.

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
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

MID = "lcars-20260914-601"


def _plant_number_one_state(root, mid, block):
    """`numberOne` at the TOP of state.json, one line — the shape every
    shipped writer emits (S189's rule)."""
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    with open(path) as fh:
        json.load(fh)  # still valid JSON
    return path


def _write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh)


class NoJournalAtAll(unittest.TestCase):
    """Behaviour 1's other half — control. A mission Number One has never
    looked at (no `number-one.jsonl` on disk at all) gets no `report` key,
    even when it carries an ordinary `numberOne` status block."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")
        _plant_number_one_state(self.tmp, MID, {
            "status": "engaged", "engine": "copilot",
            "since": "2026-09-14T09:00:00Z"})
        self.adapter = LocalAdapter(self.tmp)

    def test_no_report_key_at_all(self):
        card = self.adapter.mission(MID)
        self.assertIn("numberOne", card)
        self.assertNotIn("report", card["numberOne"])

    def test_the_ordinary_numberOne_fields_are_unaffected(self):
        card = self.adapter.mission(MID)
        self.assertEqual("engaged", card["numberOne"]["status"])
        self.assertEqual("copilot", card["numberOne"]["engine"])

    def test_the_activity_feed_has_no_number_one_entries(self):
        card = self.adapter.mission(MID)
        self.assertFalse([e for e in card["activity"] if e.get("bot") == "number-one"])


class AJournalExists(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")
        _plant_number_one_state(self.tmp, MID, {
            "status": "finished", "engine": "copilot", "score": "high",
            "since": "2026-09-14T09:00:00Z"})
        d = fx.mission_dir(self.tmp, MID)
        # An ordinary harness event, so the merge has something to interleave
        # WITH — proving Number One's lines land beside, not instead of, the
        # lcars-bot ones.
        _write_jsonl(os.path.join(d, "events.jsonl"), [
            {"ts": 1000, "stage": "verify", "type": "stage_start",
             "detail": "Verify"},
        ])
        _write_jsonl(os.path.join(d, "number-one.jsonl"), [
            {"at": "2026-09-14T09:00:05Z", "action": "criteria",
             "detail": "criteria written"},
            {"at": "2026-09-14T09:05:00Z", "action": "scored",
             "score": "high", "why": "every criterion is on the screen"},
        ])
        _write_json(os.path.join(d, "xo", "verdict.json"), {
            "criteria": [{"id": "prd-1", "text": "one list",
                          "status": "met", "shot": "shot-01",
                          "note": "it is there"}]})
        self.adapter = LocalAdapter(self.tmp)
        self.card = self.adapter.mission(MID)

    def test_report_key_is_present(self):
        self.assertIn("report", self.card["numberOne"])

    def test_report_carries_the_score(self):
        self.assertEqual("high", self.card["numberOne"]["report"]["score"])

    def test_report_carries_the_verdict_criteria(self):
        crit = self.card["numberOne"]["report"]["verdict"]["criteria"]
        self.assertEqual("prd-1", crit[0]["id"])

    def test_report_carries_a_journal_tail_newest_first(self):
        j = self.card["numberOne"]["report"]["journal"]
        self.assertEqual(2, len(j))
        self.assertEqual("scored", j[0]["action"])  # newest first
        self.assertEqual("criteria", j[1]["action"])

    # --- behaviour 2: the merged activity feed --------------------------
    def test_number_one_entries_are_bot_marked(self):
        no_entries = [e for e in self.card["activity"] if e.get("bot") == "number-one"]
        self.assertEqual(2, len(no_entries))

    def test_number_one_entries_carry_the_VERIFY_stage(self):
        no_entries = [e for e in self.card["activity"] if e.get("bot") == "number-one"]
        self.assertTrue(all(e["stage"] == "verify" for e in no_entries))

    def test_the_feed_interleaves_chronologically_with_the_lcars_bot_event(self):
        acts = self.card["activity"]
        # events.jsonl's ts=1000 (1970-01-01T00:16:40Z) is BEFORE both
        # number-one entries (2026), so it must come first.
        self.assertEqual("stage_start", acts[0]["type"])
        self.assertEqual("number-one", acts[1].get("bot"))
        self.assertEqual("number-one", acts[2].get("bot"))

    def test_the_headline_names_the_action_in_plain_words(self):
        no_entries = [e for e in self.card["activity"] if e.get("bot") == "number-one"]
        self.assertEqual("Scored the build", no_entries[1]["head"])

    def test_the_detail_carries_the_why_without_repeating_the_headline(self):
        no_entries = [e for e in self.card["activity"] if e.get("bot") == "number-one"]
        self.assertEqual("every criterion is on the screen", no_entries[1]["text"])
        self.assertNotIn("Scored", no_entries[1]["text"])

    def test_the_lcars_bot_entry_is_unaffected_by_the_merge(self):
        acts = self.card["activity"]
        plain = [e for e in acts if "bot" not in e]
        self.assertEqual(1, len(plain))
        self.assertEqual("stage_start", plain[0]["type"])

    # --- the S176 nested-mutation trap -----------------------------------
    def test_a_second_render_does_not_leak_report_onto_a_fresh_read(self):
        # Guards the exact bug class this session's brief warned about: if
        # mission() ever mutated the CACHED numberOne dict in place, a done
        # mission's memoized card would carry `report` even on a build where
        # _number_one_report() is later made to return None (or vice versa,
        # a stale leaked report). Two independent reads must agree.
        card2 = self.adapter.mission(MID)
        self.assertEqual(self.card["numberOne"]["report"],
                         card2["numberOne"]["report"])
        self.assertIsNot(self.card["numberOne"], card2["numberOne"],
                         "numberOne must be a fresh dict per render, not a "
                         "shared mutable reference")


class AnEscalatedAnswerCarriesItsOwnStage(unittest.TestCase):
    """A journal entry recorded with its OWN `stage` field (cmd_answer can
    escalate at ANY gate, not only Verify) rides in THAT stage's band, never
    forced to "verify"."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="research")
        _plant_number_one_state(self.tmp, MID, {"status": "escalated",
                                                 "engine": "copilot"})
        d = fx.mission_dir(self.tmp, MID)
        _write_jsonl(os.path.join(d, "number-one.jsonl"), [
            {"at": "2026-09-14T09:00:00Z", "action": "escalated",
             "stage": "research", "detail": "this widens scope"},
        ])
        self.adapter = LocalAdapter(self.tmp)
        self.card = self.adapter.mission(MID)

    def test_the_recorded_stage_wins_not_a_verify_default(self):
        no_entries = [e for e in self.card["activity"] if e.get("bot") == "number-one"]
        self.assertEqual("research", no_entries[0]["stage"])


if __name__ == "__main__":
    unittest.main()
