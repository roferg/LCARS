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

S213 RE-AIMED IT AT THE NEW FILTER ROW and left its point alone. The chips
are now `Needs you · N` / `Verdicts · N` / `Everything · N` (the approved
mock-up; the captain lands on Needs-you, not the firehose), and the flat
since-list moved behind the `By time` switch — so this file drives that
switch first and then clicks. What it proves is unchanged and still the thing
that actually broke once: a click MOVES `.on`, every time, exactly one chip.

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
        "counts": {"needs": 1, "verdicts": 2, "all": 3},
        "seenCount": 0,
        "missions": [],
        "since": {
            "count": 3,
            "entries": [
                {"at": "2026-09-14T10:00:00Z", "action": "scored",
                 "rank": "verdict", "mission": "m1", "new": True},
                {"at": "2026-09-14T10:05:00Z", "action": "answered",
                 "rank": "verdict", "mission": "m1", "new": True},
                {"at": "2026-09-14T10:10:00Z", "action": "escalated",
                 "rank": "needs-you", "mission": "m2", "new": True},
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
    """Every drive starts on the BY TIME switch: the flat since-list this file
    reads its counts off is that view's list, and the chip row it is really
    about is the same row in both views."""
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"reportData": _report_data(),
                       "clicks": [{"view": "time"}] + list(clicks)}, fh)
        out = subprocess.check_output([NODE, HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _on_chips(snapshot):
    return [c["text"] for c in snapshot if "on" in (c["cls"] or "").split()]


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheModalOpens(unittest.TestCase):

    def test_boots_clean(self):
        self.assertEqual([], _run(["verdicts"])["bootErrors"])

    def test_needs_you_is_the_one_and_only_chip_marked_on_at_open(self):
        """S213: he lands on Needs-you, not the firehose (C7). Before, it was
        All — and 29 flat rows was the complaint that started the session."""
        out = _run(["verdicts"])
        self.assertEqual(["Needs you · 1"], _on_chips(out["chipsAtOpen"]))

    def test_the_flat_list_carries_the_full_count_once_he_switches(self):
        out = _run(["all"])
        self.assertEqual("Since you last looked (3)",
                         out["afterClicks"][-1]["sinceHead"])


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class AChipClickMovesTheMarker(unittest.TestCase):
    """The regression itself: filtering already worked (the since-head count
    already moved before this fix), but `.on` never left "All"."""

    # S223: "Show" became FILTER chips — the captain's mock: "'Show' items are
    # filters, with a tick and a different outline when on" — so Needs you and
    # Verdicts can both be on (their union shows). The S205 regression this
    # class guards (the marker must follow EVERY click) is still what is
    # checked; "exactly one on" moved to Arrange, the single-choice switch.

    def test_clicking_verdicts_turns_it_on_beside_needs_you(self):
        out = _run(["verdicts"])
        after = out["afterClicks"][-1]
        self.assertIsNone(after["error"])
        self.assertEqual(["Needs you · 1", "Verdicts · 2"], _on_chips(after["chips"]))

    def test_the_list_filters_to_the_union_the_same_click(self):
        out = _run(["verdicts"])
        after = out["afterClicks"][-1]
        # needs-you (1) + verdicts (2) — all three, and the marker moved.
        self.assertEqual("Since you last looked (3)", after["sinceHead"])

    def test_a_second_click_turns_it_back_off(self):
        out = _run(["verdicts", "needs"])
        first, second = out["afterClicks"][-2:]
        self.assertEqual(["Needs you · 1", "Verdicts · 2"], _on_chips(first["chips"]))
        self.assertEqual(["Verdicts · 2"], _on_chips(second["chips"]),
                          "the marker must follow EVERY click, not just the "
                          "first one after paint()")
        self.assertEqual("Since you last looked (2)", second["sinceHead"])

    def test_clicking_out_to_everything_restores_it_and_only_it(self):
        out = _run(["verdicts", "needs", "all"])
        last = out["afterClicks"][-1]
        self.assertEqual(["Everything · 3"], _on_chips(last["chips"]))
        self.assertEqual("Since you last looked (3)", last["sinceHead"])

    def test_never_zero_chips_on(self):
        out = _run(["needs"])      # turning the only one off falls back
        last = out["afterClicks"][-1]
        self.assertEqual(["Everything · 3"], _on_chips(last["chips"]))

    def test_arrange_is_exactly_one_at_every_step(self):
        out = _run(["verdicts", "needs", "all"])
        for step in out["afterClicks"]:
            on = [v for v in step["views"] if " on" in (" " + v["cls"])]
            self.assertEqual(1, len(on), step["views"])

if __name__ == "__main__":
    unittest.main()
