"""S205 fix round 2, D2 — THE FIRST OFFICER'S REPORT's chip row highlights
the chip the captain actually clicked.

The captain's own ruling stands behind this file (recorded in memory as
"the engaged pill is hollow"): a state he has to read must not be carried by
HUE ALONE. `.xo-chip.on` in board.css already differs from a plain chip by
fill (solid vs. transparent), border colour AND font-weight (700 vs. normal)
— three greyscale-readable signals, not one colour swap — so this file does
not touch the CSS. What it proves is that a click actually MOVES that class:
before this fix round, `paint()` set `.on` once at build time and the click
handler called only `render()` (which rebuilds the FILTERED LIST, never
`chipsRow` itself), so `.on` stayed on "All" no matter which chip was
pressed, even though the list it filtered was correct.

Driven through board_xo_report_harness.js — a sandboxed vm running the REAL,
SHIPPING board.js against a small synthetic DOM (board_help_harness.js's own
proven Element engine), opening the report modal for real
(`openXoReport()`), letting its `fetch("/api/xo/report")` resolve
SYNCHRONOUSLY off a canned payload, and CLICKING the chip nodes exactly as a
captain would. No gh, no network, no model, no worker.
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

HARNESS = os.path.join(HERE, "board_xo_report_harness.js")
NODE = shutil.which("node")


def _report_data():
    return {
        "lastSeenAt": None,
        "since": {
            "count": 3,
            "entries": [
                {"at": "2026-09-14T10:00:00Z", "action": "scored",
                 "mission": "m1", "new": True},
                {"at": "2026-09-14T10:05:00Z", "action": "answered",
                 "mission": "m1", "new": True},
                {"at": "2026-09-14T10:10:00Z", "action": "escalated",
                 "mission": "m2", "new": True},
            ],
        },
        "history": [
            {"id": "m1", "title": "Mission One", "issue": 101, "entries": [
                {"at": "2026-09-14T10:00:00Z", "action": "scored", "mission": "m1"},
                {"at": "2026-09-14T10:05:00Z", "action": "answered", "mission": "m1"},
            ]},
            {"id": "m2", "title": "Mission Two", "issue": 102, "entries": [
                {"at": "2026-09-14T10:10:00Z", "action": "escalated", "mission": "m2"},
            ]},
        ],
    }


def _run(clicks):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"reportData": _report_data(), "clicks": clicks}, fh)
        out = subprocess.check_output([NODE, HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _on_chips(snapshot):
    return [c["text"] for c in snapshot if "on" in (c["cls"] or "").split()]


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheModalOpens(unittest.TestCase):

    def test_boots_clean(self):
        self.assertEqual([], _run(["gate"])["bootErrors"])

    def test_all_is_the_one_and_only_chip_marked_on_at_open(self):
        out = _run(["gate"])
        self.assertEqual(["All"], _on_chips(out["chipsAtOpen"]))

    def test_since_head_carries_the_full_count_at_open(self):
        out = _run(["gate"])
        self.assertEqual("Since you last looked (3)", out["sinceHeadAtOpen"])


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class AChipClickMovesTheMarker(unittest.TestCase):
    """The regression itself: filtering already worked (the since-head count
    already moved before this fix), but `.on` never left "All"."""

    def test_clicking_gate_answers_moves_on_onto_it_and_off_all(self):
        out = _run(["gate"])
        after = out["afterClicks"][0]
        self.assertIsNone(after["error"])
        self.assertEqual(["Gate answers"], _on_chips(after["chips"]),
                          "exactly one chip — the one clicked — must carry "
                          "`.on` after the click")

    def test_the_list_still_filters_the_same_click(self):
        out = _run(["gate"])
        after = out["afterClicks"][0]
        # Only the ONE "answered" entry matches the "gate" chip.
        self.assertEqual("Since you last looked (1)", after["sinceHead"])

    def test_a_second_click_moves_it_again_not_just_the_first(self):
        out = _run(["gate", "escalated"])
        first, second = out["afterClicks"]
        self.assertEqual(["Gate answers"], _on_chips(first["chips"]))
        self.assertEqual(["Escalated to you"], _on_chips(second["chips"]),
                          "the marker must follow EVERY click, not just the "
                          "first one after paint()")

    def test_clicking_back_to_all_restores_it_and_only_it(self):
        out = _run(["gate", "escalated", "all"])
        last = out["afterClicks"][-1]
        self.assertEqual(["All"], _on_chips(last["chips"]))
        self.assertEqual("Since you last looked (3)", last["sinceHead"])

    def test_never_more_than_one_chip_marked_on_at_once(self):
        out = _run(["gate", "escalated", "all"])
        for step in out["afterClicks"]:
            self.assertEqual(1, len(_on_chips(step["chips"])),
                              "exactly one chip must read as active at a time: %s"
                              % step)


if __name__ == "__main__":
    unittest.main()
