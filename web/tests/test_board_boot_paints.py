"""S163 fix round 7 (D1) — the board's OWN paint path must actually paint.

THE HOLE THIS CLOSES. Round 5 deleted `.then(render)` from `refresh()` while
inserting a comment about the `.catch` beneath it. The shipping board went
permanently blank — `#status` stuck on "loading…", zero `.card` nodes, on a
healthy daemon answering `GET /api/board` 200 every four seconds. And 1137
tests stayed green, because every single one of them calls `render(board)` (or
`cardNode(m)`) BY HAND. The suite could not distinguish a working board from a
blank one. Six tester rounds missed it too; real Chrome found it in five
seconds.

So these tests never call render(). They run the shipping board.js the way the
browser runs it — its own boot statements — against a fetch that answers with a
real payload, and then ask whether anything appeared. Cut ANY link in

    boot refresh() → fetch("/api/board") → .json() → render() → #board

and one of these goes red.

Coverage boundary, stated plainly (see board_boot_harness.js): this is a node
`vm` with DOM stubs. It proves the WIRING carries payload data into real DOM
nodes. It knows nothing of CSS, layout, paint order or browser-specific
parsing, so it cannot prove the result is LEGIBLE — a card hidden by a
stylesheet still counts here. The round's real-Chrome eyeball remains the check
for that.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_boot_harness.js")
NODE = shutil.which("node")


def _mission(mid, issue, title, stage="verify"):
    return {
        "id": mid, "issue": issue, "title": title, "stage": stage,
        "type": "feature", "engine": "claude",
    }


def _board(missions, stage="verify"):
    return {
        "missions": missions,
        "columns": {stage: list(missions)},
        "meta": {"adapter": "local", "repo": "fixture", "version": {}},
    }


def _boot(board, mode="boot", board2=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump({"board": board, "board2": board2}, fh)
    try:
        out = subprocess.check_output([NODE, HARNESS, path, mode],
                                      stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def _flatten(node, acc=None):
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


def _cards(res):
    """Every node the render produced that IS a card."""
    return [n for n in _flatten(res.get("board"))
            if "card" in (n.get("cls") or "").split()]


def _all_text(res):
    return " ".join(n.get("text", "") for n in _flatten(res.get("board")))


@unittest.skipIf(NODE is None, "node not available")
class BoardBootPaintsTest(unittest.TestCase):
    """The blocker itself: does the product paint when the product boots?"""

    def test_booting_board_js_paints_cards_without_anyone_calling_render(self):
        # Two missions on a healthy board — exactly what the daemon serves.
        board = _board([_mission("m-1", 41, "Ship the thing"),
                        _mission("m-2", 42, "Fix the other thing")])
        res = _boot(board)
        self.assertEqual("", res["bootError"], "board.js threw during boot")
        # It asked the daemon...
        self.assertGreaterEqual(
            res["boardFetches"], 1,
            "boot never fetched /api/board — the read path is not wired")
        # ...and it PAINTED what came back. This is the assertion round 5 broke.
        cards = _cards(res)
        self.assertEqual(
            2, len(cards),
            "the board fetched a 2-mission payload and rendered %d cards — the "
            "fetch→render wiring is cut (this is the round-7 blocker)"
            % len(cards))
        # and the payload's own words reached the DOM, not just a card shell.
        self.assertIn("Ship the thing", _all_text(res))

    def test_the_status_line_stops_saying_loading_once_the_board_paints(self):
        """`loading…` forever was the blank board's only visible symptom."""
        res = _boot(_board([_mission("m-1", 41, "Ship the thing")]))
        self.assertNotIn("loading", res["status"].lower())
        self.assertIn("1 active mission", res["status"])

    def test_an_empty_board_still_completes_its_paint(self):
        """No missions is not the same as no render — the columns still draw."""
        res = _boot(_board([]))
        self.assertEqual("", res["bootError"])
        cols = [n for n in _flatten(res.get("board"))
                if "col" in (n.get("cls") or "").split()]
        self.assertTrue(cols, "an empty board rendered no columns at all")
        self.assertIn("0 active missions", res["status"])

    def test_a_failing_fetch_still_reports_the_ambient_failure(self):
        """The .catch round 5's comment was about — it must survive the fix."""
        res = _boot(_board([_mission("m-1", 41, "Ship the thing")]), mode="fail")
        self.assertEqual("board unavailable", res["status"])


@unittest.skipIf(NODE is None, "node not available")
class BoardStaysLiveTest(unittest.TestCase):
    """The two live paths BUG-065 installed. A board that paints once and then
    never again is the same blank-page class of defect, delayed."""

    def test_the_safety_poll_repaints_the_board(self):
        first = _board([_mission("m-1", 41, "Ship the thing")])
        second = _board([_mission("m-1", 41, "Ship the thing"),
                         _mission("m-2", 42, "A newly filed mission")])
        res = _boot(first, mode="poll", board2=second)
        self.assertIn(4000, res["intervals"],
                      "connect() no longer installs the LIVE_POLL_MS safety poll")
        self.assertEqual(
            2, len(_cards(res)),
            "the safety poll fired and the board did not repaint")
        self.assertIn("A newly filed mission", _all_text(res))

    def test_an_sse_update_repaints_the_board(self):
        first = _board([_mission("m-1", 41, "Ship the thing")])
        second = _board([_mission("m-1", 41, "Ship the thing"),
                         _mission("m-2", 42, "A newly filed mission")])
        res = _boot(first, mode="sse", board2=second)
        self.assertEqual("/api/events", res["sseUrl"],
                         "the board no longer subscribes to the SSE channel")
        self.assertIn("update", res["sseEvents"])
        self.assertEqual(
            2, len(_cards(res)),
            "an SSE `update` arrived and the board did not repaint")
        self.assertIn("A newly filed mission", _all_text(res))


@unittest.skipIf(NODE is None, "node not available")
class BootHarnessIsHonestTest(unittest.TestCase):
    """Positive control, in the spirit of `test_the_comparison_can_go_red`.

    A harness that reports cards no matter what would be worse than no harness
    — it would license the next round-5. So prove it can see the difference:
    serve a payload with a mission and a payload without, and require the count
    to actually differ."""

    def test_the_harness_can_tell_a_painted_board_from_an_empty_one(self):
        with_one = _cards(_boot(_board([_mission("m-1", 41, "Ship the thing")])))
        with_none = _cards(_boot(_board([])))
        self.assertEqual(1, len(with_one))
        self.assertEqual(0, len(with_none))


if __name__ == "__main__":
    unittest.main()
