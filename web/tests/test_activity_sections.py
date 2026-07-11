"""S115 — collapsible per-wave / per-stage sections for the detail activity feed.

The long serial activity feed in the detail modal is grouped CLIENT-SIDE into
collapsible sections keyed by stage + wave. Completed sections collapse to one
LCARS summary band; the active (last/in-flight) section stays open; everything
is expandable, and an "expand all" affordance reveals every event.

Two layers of coverage:

  * A PURE helper `groupActivityIntoSections(acts)` (no DOM) — exercised for real
    by running the SHIPPING board.js in a node vm harness (there is no JS DOM
    harness in this repo; ADR-007 forbids a build step / npm). Grouping, counts,
    durations, flagged marker, active-section detection, small-mission passthrough
    and the nothing-lost invariant are asserted against real event streams.
  * String assertions on board.js proving the thin DOM wiring exists (collapsible
    bands, expand-all, per-event reuse) and that the CARD ticket strip is
    untouched.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "..", "static")
HARNESS = os.path.join(HERE, "board_sections_harness.js")
NODE = shutil.which("node")


def _big_gamify_events():
    """A 3-wave / 9-ticket Implement stream (wave 2 has a flagged ticket)."""
    evs = [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "implement starting"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
    ]
    ts = 1002
    plan = [
        # (wave_first?, ticket, flagged?)
        (False, "t-001", False), (False, "t-002", False), (False, "t-003", False),
        ("wave", "t-004", False), (False, "t-005", True), (False, "t-006", False),
        ("wave", "t-007", False), (False, "t-008", False), (False, "t-009", False),
    ]
    for marker, tid, flagged in plan:
        if marker == "wave":
            evs.append({"ts": ts, "stage": "implement", "type": "wave_start",
                        "detail": "wave"})
            ts += 1
        evs.append({"ts": ts, "stage": "implement", "type": "ticket_start",
                    "detail": "%s begin" % tid})
        ts += 5
        if flagged:
            evs.append({"ts": ts, "stage": "implement", "type": "ticket_flagged",
                        "detail": "%s attempt failed" % tid})
            ts += 3
        evs.append({"ts": ts, "stage": "implement", "type": "ticket_green",
                    "detail": "%s green" % tid})
        ts += 5
    evs.append({"ts": ts, "stage": "implement", "type": "stage_done",
                "detail": "implement complete"})
    return evs


def _small_events():
    """A single-wave Implement mission — nothing to collapse."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "start"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1010, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
    ]


def _multistage_events():
    """Research + Validate stage sections, then a single Implement wave."""
    return [
        {"ts": 1000, "stage": "research", "type": "stage_start", "detail": "research"},
        {"ts": 1005, "stage": "research", "type": "gate", "detail": "a question"},
        {"ts": 1010, "stage": "research", "type": "stage_done", "detail": "research done"},
        {"ts": 1020, "stage": "validate", "type": "stage_start", "detail": "validate"},
        {"ts": 1030, "stage": "validate", "type": "stage_done", "detail": "validate done"},
        {"ts": 1040, "stage": "implement", "type": "stage_start", "detail": "implement"},
        {"ts": 1041, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1042, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1050, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
    ]


@unittest.skipUnless(NODE, "node is required to exercise the pure JS helper")
class GroupActivityHelperTest(unittest.TestCase):
    def _group(self, acts):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(acts, f)
            path = f.name
        try:
            out = subprocess.check_output([NODE, HARNESS, path], stderr=subprocess.STDOUT)
        finally:
            os.unlink(path)
        return json.loads(out.decode("utf-8"))

    # (1) a 3-wave / 9-ticket mission → 3 sections, 2 collapsed + 1 open.
    def test_three_waves_three_sections_last_open(self):
        secs = self._group(_big_gamify_events())
        self.assertEqual(len(secs), 3, "one section per wave")
        self.assertTrue(all(s["kind"] == "wave" for s in secs))
        self.assertEqual([s["wave"] for s in secs], [1, 2, 3])
        # exactly the last section is active/open; the earlier two collapse.
        self.assertEqual([s["active"] for s in secs], [False, False, True])
        self.assertEqual(sum(1 for s in secs if not s["active"]), 2)
        # per-wave ticket counts (3 each → 9 total).
        self.assertEqual([s["ticketCount"] for s in secs], [3, 3, 3])
        self.assertEqual(sum(s["ticketCount"] for s in secs), 9)

    # (2) a flagged wave's band carries the flag marker; clean waves do not.
    def test_flagged_wave_marked(self):
        secs = self._group(_big_gamify_events())
        self.assertEqual([s["flagged"] for s in secs], [False, True, False])
        self.assertEqual(secs[1]["flaggedCount"], 1)

    # (3) NOTHING LOST — the union of every section's events equals the input,
    #     in order, with nothing dropped or duplicated. (expand-all in the DOM
    #     renders exactly these, one .evt each — see the wiring assertions.)
    def test_nothing_lost(self):
        acts = _big_gamify_events()
        secs = self._group(acts)
        regrouped = []
        for s in secs:
            regrouped.extend(s["events"])
        self.assertEqual(len(regrouped), len(acts))
        self.assertEqual([e["ts"] for e in regrouped], [e["ts"] for e in acts])
        self.assertEqual([e["type"] for e in regrouped], [e["type"] for e in acts])

    # (4) a small (1-wave) mission renders effectively as today: a single open
    #     section, so the DOM takes the flat passthrough branch.
    def test_small_mission_single_open_section(self):
        secs = self._group(_small_events())
        self.assertEqual(len(secs), 1)
        self.assertTrue(secs[0]["active"])
        # nothing lost here either.
        self.assertEqual(len(secs[0]["events"]), len(_small_events()))

    # durations derive from each section's first/last event ts.
    def test_section_durations(self):
        secs = self._group(_big_gamify_events())
        for s in secs:
            self.assertIsNotNone(s["durationSec"])
            self.assertGreater(s["durationSec"], 0)
        # wave 1 spans stage_start(1000) .. last ticket_green(1027).
        self.assertEqual(secs[0]["durationSec"], 27)

    # non-implement stages group under their STAGE; implement splits into waves.
    def test_multistage_grouping(self):
        secs = self._group(_multistage_events())
        kinds = [(s["kind"], s["stage"]) for s in secs]
        self.assertEqual(kinds, [
            ("stage", "research"),
            ("stage", "validate"),
            ("wave", "implement"),
        ])
        # the research gate event stays inside the research section (not lost).
        self.assertEqual(len(secs[0]["events"]), 3)
        self.assertTrue(secs[-1]["active"])

    def test_empty_stream(self):
        self.assertEqual(self._group([]), [])


class BoardJsWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_helper_defined(self):
        self.assertIn("function groupActivityIntoSections", self.js)

    def test_feed_uses_sections(self):
        # the feed builds sections and, for >1 section, renders collapsible bands.
        self.assertIn("groupActivityIntoSections", self.js)
        self.assertIn("feed-section", self.js)
        self.assertIn("feed-band", self.js)

    def test_expand_all_affordance(self):
        self.assertIn("feed-expand", self.js)
        # a case-insensitive nod to the "expand all" label.
        self.assertIn("Expand all", self.js)

    def test_small_mission_passthrough_branch(self):
        # a single (or zero) section still renders the flat feed — no band chrome.
        self.assertIn("sections.length <= 1", self.js)

    def test_per_event_render_reused(self):
        # the per-event .evt block is factored into a helper reused inside bands
        # AND the flat passthrough, so no event is rendered by only one path.
        self.assertIn("function renderEvent", self.js)

    def test_linked_bugs_collapse(self):
        # the mission-log parent's linked-bug list gets the same band idiom.
        self.assertIn("function linkedBugsSection", self.js)
        self.assertIn("linkedBugsSection(kids)", self.js)


class CardsUntouchedTest(unittest.TestCase):
    """The card ticket strip (CARD_TICKET_CAP / cardTickets) is DETAIL-only work's
    off-limits neighbour — assert it is byte-stable at the contract points."""
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_card_ticket_cap_unchanged(self):
        self.assertIn("var CARD_TICKET_CAP = 3;", self.js)

    def test_card_tickets_present(self):
        self.assertIn("function cardTickets(tickets)", self.js)
        self.assertIn('tk.appendChild(ticketMore("and " + hiddenAfter + " more…"));', self.js)


if __name__ == "__main__":
    unittest.main()
