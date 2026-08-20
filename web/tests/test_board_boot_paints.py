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


def _boot(board, mode="boot", board2=None, board3=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump({"board": board, "board2": board2, "board3": board3}, fh)
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


@unittest.skipIf(NODE is None, "node not available")
class UnchangedBoardIsNotRepaintedTest(unittest.TestCase):
    """S176 part B — the board stops rebuilding itself over nothing.

    `connect()` installs setInterval(refresh, 4000) and `render()` opens with
    `root.innerHTML = ""` and rebuilds EVERY card in EVERY column. There was no
    diff and no change check, so a 56-card board tore itself down and rebuilt on
    the main thread four times a minute for ever, whether or not a single byte
    had moved. That is what the captain felt as "laggy when I click on a card".

    THE CHECK IS ON THE PAYLOAD, NOT ON `fingerprint()` — and that is the whole
    design. `fingerprint()` is a DISK signature, but `meta.holodeck` is built
    from in-memory daemon session state (actions.py `_holodeck`), so a holodeck
    program starting or stopping changes the board with the fingerprint sitting
    perfectly still. Gate the fetch on the fingerprint and the ⬡ HOLODECK band
    silently stops lighting up. Comparing what actually came back cannot miss
    it, because the thing compared IS the thing drawn.
    """

    def _b(self, missions, meta=None):
        b = _board(missions)
        if meta:
            b["meta"].update(meta)
        return b

    def test_an_identical_payload_does_not_repaint(self):
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        out = _boot(one, mode="pollsame")
        self.assertEqual("", out["bootError"])
        # Two board fetches (boot + poll), ONE paint.
        self.assertEqual(2, out["boardFetches"])
        self.assertEqual(1, out["boardPaints"])
        # ...and the board is still on screen, not blanked by the skip.
        self.assertEqual(1, len(_cards(out)))

    def test_a_changed_payload_still_repaints(self):
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        two = self._b([_mission("m-1", 41, "Ship the thing"),
                       _mission("m-2", 42, "And the other thing")])
        out = _boot(one, mode="poll", board2=two)
        self.assertEqual("", out["bootError"])
        self.assertEqual(2, out["boardPaints"])
        self.assertEqual(2, len(_cards(out)))

    def test_the_poll_repaints_through_a_write_burst(self):
        # The reconcile case the safety poll EXISTS for: SSE is debounced and
        # only emits once writes stop, so the poll must carry each intermediate
        # state. A change check that only proves "identical skips" has proved
        # half of it — this is the other half.
        one = self._b([_mission("m-1", 41, "merging")])
        two = self._b([_mission("m-1", 41, "retesting")])
        three = self._b([_mission("m-1", 41, "awaiting reapprove")])
        out = _boot(one, mode="burst", board2=two, board3=three)
        self.assertEqual("", out["bootError"])
        self.assertEqual(3, out["boardPaints"])
        self.assertIn("awaiting reapprove", _all_text(out))

    def test_an_in_memory_only_meta_change_still_repaints(self):
        # THE TRAP, as an executable assertion. `meta.holodeck` never touches
        # disk, so fingerprint() cannot see this change. Payload comparison can.
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        two = self._b([_mission("m-1", 41, "Ship the thing")],
                      meta={"holodeck": {"count": 1, "working": [
                          {"sessionId": "h1", "program": "p", "room": "r"}],
                          "message": "drawing"}})
        out = _boot(one, mode="poll", board2=two)
        self.assertEqual("", out["bootError"])
        self.assertEqual(2, out["boardPaints"],
                         "a holodeck change is invisible to fingerprint() — the "
                         "payload check must still catch it")

    def test_the_sse_push_is_unaffected(self):
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        two = self._b([_mission("m-1", 41, "Ship the thing"),
                       _mission("m-2", 42, "New arrival")])
        out = _boot(one, mode="sse", board2=two)
        self.assertEqual("", out["bootError"])
        self.assertEqual(2, out["boardPaints"])
        self.assertEqual(2, len(_cards(out)))

    def test_a_recovered_fetch_repaints_even_when_nothing_changed(self):
        # The edge the change check CREATES. A failed fetch leaves the board
        # unpainted and #status on "board unavailable". If the next successful
        # fetch is compared against the payload we never drew, "unchanged" would
        # skip the paint and strand the captain on an error that has passed. The
        # failure path must therefore invalidate the comparison, not just report.
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        out = _boot(one, mode="failthenpoll")
        self.assertEqual("", out["bootError"])
        self.assertEqual(1, out["boardPaints"])
        self.assertEqual(1, len(_cards(out)))
        self.assertNotIn("unavailable", out["status"])

    def test_the_skip_leaves_the_status_line_alone(self):
        # Skipping a render is only safe if nothing that matters was riding on
        # the render happening. The status line is the visible one.
        one = self._b([_mission("m-1", 41, "Ship the thing")])
        painted = _boot(one, mode="boot")
        skipped = _boot(one, mode="pollsame")
        self.assertEqual(painted["status"], skipped["status"])
        self.assertTrue(skipped["status"])


@unittest.skipIf(NODE is None, "node not available")
class PaintCounterIsHonestTest(unittest.TestCase):
    """Positive control for the S176 counter, in the spirit of the one above.

    A paint counter stuck at 1 would make the skip test pass no matter what the
    product did. Prove it can count to two."""

    def test_the_counter_can_reach_two(self):
        one = _board([_mission("m-1", 41, "Ship the thing")])
        two = _board([_mission("m-2", 42, "Different mission")])
        self.assertEqual(1, _boot(one, mode="boot")["boardPaints"])
        self.assertEqual(2, _boot(one, mode="poll", board2=two)["boardPaints"])


if __name__ == "__main__":
    unittest.main()
