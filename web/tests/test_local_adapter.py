"""LOCAL adapter — maps a `.git/lcars/missions/*` tree to the board shape.

Behaviors covered:
  1. columns, pills, paused/gate state, nested tickets from a fixture tree.
  2. a gated mission lands in its in-flight (pending.json.stage) column, NOT
     align — mirroring status.sh's gate rule exactly.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.board import STAGES  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402


class LocalAdapterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _board(self):
        return LocalAdapter(self.tmp).board()

    def _by_id(self, board, mid):
        for m in board["missions"]:
            if m["id"] == mid:
                return m
        raise AssertionError("mission %s not in board" % mid)

    def test_shape_has_all_nine_stage_columns(self):
        board = self._board()
        self.assertEqual(board["stages"], list(STAGES))
        self.assertEqual(set(board["columns"].keys()), set(STAGES))

    def test_simple_mission_lands_in_its_stage_column_with_pills(self):
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        board = self._board()
        col = board["columns"]["implement"]
        self.assertEqual([m["id"] for m in col], ["m-001"])
        m = col[0]
        self.assertEqual(m["issue"], 142)
        self.assertEqual(m["title"], "Add Gamification to Course Site")
        # one cost pill + two difficulty pills
        self.assertIn("cost", m["pills"])
        self.assertEqual(m["pills"]["reasoning"]["level"], "medium")
        self.assertEqual(m["pills"]["implementation"]["level"], "high")
        # cost pill is in the active engine's unit (claude → usd)
        self.assertEqual(m["pills"]["cost"]["unit"], "usd")
        self.assertFalse(m["awaiting"])
        self.assertFalse(m["paused"])

    def test_gated_mission_lands_in_inflight_column_not_align(self):
        # state.json.stage = align (resume pointer); pending.json.stage = research.
        fx.plant_gated(self.tmp, "m-gate", resume_stage="align",
                       inflight_stage="research")
        board = self._board()
        self.assertEqual([m["id"] for m in board["columns"]["align"]], [])
        col = board["columns"]["research"]
        self.assertEqual([m["id"] for m in col], ["m-gate"])
        m = col[0]
        self.assertTrue(m["awaiting"])
        self.assertEqual(m["stage"], "research")
        self.assertEqual(m["question"], "Global vs per-course leaderboard?")

    def test_paused_mission_flagged(self):
        fx.plant_paused(self.tmp, "m-pause", stage="implement")
        m = self._by_id(self._board(), "m-pause")
        self.assertTrue(m["paused"])
        self.assertEqual(m["stage"], "implement")

    def test_nested_tickets_and_implement_progress(self):
        fx.plant_implementing(self.tmp, "m-impl")
        m = self._by_id(self._board(), "m-impl")
        # nested tickets carry id, sub-issue and a state derived from events
        self.assertEqual([t["id"] for t in m["tickets"]],
                         ["t-001", "t-002", "t-003"])
        states = {t["id"]: t["state"] for t in m["tickets"]}
        self.assertEqual(states["t-001"], "done")
        self.assertEqual(states["t-002"], "in-progress")
        self.assertEqual(states["t-003"], "pending")
        self.assertEqual(m["tickets"][0]["issue"], 201)
        # progress strip
        self.assertIsNotNone(m["progress"])
        self.assertEqual(m["progress"]["wave"], 1)
        self.assertEqual(m["progress"]["wavesTotal"], 2)
        self.assertEqual(m["progress"]["ticketsDone"], 1)
        self.assertEqual(m["progress"]["ticketsTotal"], 3)

    def test_single_ticket_mission_shows_no_tickets(self):
        fx.plant_simple(self.tmp, "m-solo", stage="plan")
        m = self._by_id(self._board(), "m-solo")
        self.assertEqual(m["tickets"], [])

    def test_done_missions_excluded_from_active_board(self):
        fx.plant_simple(self.tmp, "m-done", stage="done", issue=9)
        fx.plant_simple(self.tmp, "m-live", stage="plan", issue=10)
        board = self._board()
        ids = [m["id"] for m in board["missions"]]
        self.assertIn("m-live", ids)
        self.assertNotIn("m-done", ids)

    def test_empty_tree_is_empty_board(self):
        board = self._board()
        self.assertEqual(board["missions"], [])
        for st in STAGES:
            self.assertEqual(board["columns"][st], [])

    def test_copilot_cost_pill_unit(self):
        fx.plant_simple(self.tmp, "m-cop", stage="plan",
                        estimate=fx.ESTIMATE_COPILOT_LEGACY)
        m = self._by_id(self._board(), "m-cop")
        self.assertEqual(m["pills"]["cost"]["unit"], "premiumRequests")


if __name__ == "__main__":
    unittest.main()
