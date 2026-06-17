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

    def test_done_missions_in_done_column_but_not_active(self):
        """S67 fix-loop r2, DEFECT 2: a done mission (state.stage == "done")
        belongs in the Done COLUMN (PRD §5.1 — done is a Stage label), with its
        normal card fields, but must stay OUT of the active `missions` list so
        the "N active missions" count doesn't inflate."""
        fx.plant_simple(self.tmp, "m-done", stage="done", issue=9)
        fx.plant_simple(self.tmp, "m-live", stage="plan", issue=10)
        board = self._board()
        # done mission lands in the Done column with its normal card fields
        done_col = board["columns"]["done"]
        self.assertEqual([m["id"] for m in done_col], ["m-done"])
        self.assertEqual(done_col[0]["issue"], 9)
        self.assertEqual(done_col[0]["stage"], "done")
        self.assertIn("pills", done_col[0])
        # but it is NOT counted as active
        ids = [m["id"] for m in board["missions"]]
        self.assertIn("m-live", ids)
        self.assertNotIn("m-done", ids)

    # ── S67: chosen engine survives onto the card (state.json.workerBin) ──
    def test_engine_populated_from_worker_bin(self):
        """A mission filed with a chosen engine persists it as state.json's
        `workerBin`; the board card must surface it as `engine` so the card/detail
        shows "copilot"/"claude" instead of None."""
        fx.plant_simple(self.tmp, "m-eng", stage="plan", worker_bin="copilot")
        m = self._by_id(self._board(), "m-eng")
        self.assertEqual(m["engine"], "copilot")

    def test_engine_absent_is_none_no_crash(self):
        """No persisted workerBin ⇒ engine is None (absent), and the board still
        assembles cleanly (no regression / crash)."""
        fx.plant_simple(self.tmp, "m-noeng", stage="plan")
        m = self._by_id(self._board(), "m-noeng")
        self.assertIsNone(m["engine"])

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

    # ── S70-A: board-level meta (which repo am I attached to) ──
    def test_board_meta_present_with_repo_and_mode(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        board = self._board()
        self.assertIn("meta", board)
        meta = board["meta"]
        self.assertEqual(meta["adapter"], "local")
        # mode defaults to read-write for the local adapter (write layer seam)
        self.assertEqual(meta["mode"], "read-write")
        # repo is always a non-empty string — basename fallback when no remote
        self.assertTrue(meta["repo"])
        self.assertIsInstance(meta["repo"], str)

    def test_board_meta_repo_falls_back_to_basename(self):
        # a temp dir with no git remote → meta.repo is the directory basename
        board = self._board()
        self.assertEqual(board["meta"]["repo"], os.path.basename(self.tmp))

    def test_board_meta_repo_from_git_remote(self):
        # plant a .git/config carrying an origin remote → owner/name is derived
        gitdir = os.path.join(self.tmp, ".git")
        os.makedirs(gitdir, exist_ok=True)
        with open(os.path.join(gitdir, "config"), "w") as fh:
            fh.write('[remote "origin"]\n'
                     '\turl = git@github.com:roferg/lcars-sandbox.git\n')
        self.assertEqual(self._board()["meta"]["repo"], "roferg/lcars-sandbox")

    def test_board_meta_repo_worktree_safe_when_git_is_a_file(self):
        # Simulate a git WORKTREE: <root>/.git is a FILE (a gitdir: pointer),
        # so the direct .git/config read CANNOT find a remote. The worktree-safe
        # path shells `git` (stubbed here) and resolves the origin url → it must
        # NOT fall back to the dir basename when a remote is resolvable.
        with open(os.path.join(self.tmp, ".git"), "w") as fh:
            fh.write("gitdir: /elsewhere/.git/worktrees/wt\n")
        reader = lambda root: "https://github.com/roferg/LCARS.git"
        board = LocalAdapter(self.tmp, git_url_reader=reader).board()
        self.assertEqual(board["meta"]["repo"], "roferg/LCARS")
        self.assertNotEqual(board["meta"]["repo"], os.path.basename(self.tmp))

    def test_board_meta_repo_git_reader_takes_precedence_over_config(self):
        # When git resolves a remote it wins over a (stale) .git/config parse.
        gitdir = os.path.join(self.tmp, ".git")
        os.makedirs(gitdir, exist_ok=True)
        with open(os.path.join(gitdir, "config"), "w") as fh:
            fh.write('[remote "origin"]\n\turl = git@github.com:old/stale.git\n')
        reader = lambda root: "git@github.com:roferg/LCARS.git"
        board = LocalAdapter(self.tmp, git_url_reader=reader).board()
        self.assertEqual(board["meta"]["repo"], "roferg/LCARS")

    def test_board_meta_repo_degrades_when_reader_returns_none(self):
        # A missing/unauthed git (reader → None) must never crash; with no
        # .git/config either, it degrades to the basename.
        reader = lambda root: None
        board = LocalAdapter(self.tmp, git_url_reader=reader).board()
        self.assertEqual(board["meta"]["repo"], os.path.basename(self.tmp))

    def test_board_meta_mode_read_only_when_flagged(self):
        board = LocalAdapter(self.tmp, read_only=True).board()
        self.assertEqual(board["meta"]["mode"], "read-only")

    # ── S70-B1: per-stage model mix (from estimate.json.models) ──
    def test_model_mix_on_card_from_estimate(self):
        fx.plant_simple(self.tmp, "m-mix", stage="plan")
        m = self._by_id(self._board(), "m-mix")
        self.assertIsNotNone(m["modelMix"])
        rows = {r["stage"]: r for r in m["modelMix"]}
        self.assertEqual(rows["Research"]["tier"], "opus")
        self.assertEqual(rows["Plan Review"]["tier"], "sonnet")
        # the single top-level rationale rides every row's `why`
        self.assertEqual(rows["Research"]["why"], "Touches a sensitive boundary.")

    def test_model_mix_none_when_no_estimate(self):
        fx.plant_simple(self.tmp, "m-noest", stage="plan", estimate=None)
        m = self._by_id(self._board(), "m-noest")
        self.assertIsNone(m["modelMix"])

    # ── S70-B2: ADRs (from adr.md) ──
    def test_adrs_parsed_from_adr_md(self):
        d = fx.plant_simple(self.tmp, "m-adr", stage="plan")
        fx.write(os.path.join(d, "adr.md"),
                 "# Architecture Decision Records: Gamification\n\n"
                 "## ADR-001: Use a per-course leaderboard\n\n"
                 "**Context:** Courses are isolated.\n"
                 "**Decision:** Scope leaderboards per course.\n\n"
                 "## ADR-002: Store XP in the user model\n\n"
                 "**Decision:** Add an xp column.\n")
        detail = LocalAdapter(self.tmp).mission("m-adr")
        self.assertIsNotNone(detail["adrs"])
        self.assertEqual(len(detail["adrs"]), 2)
        self.assertEqual(detail["adrs"][0]["title"],
                         "ADR-001: Use a per-course leaderboard")
        self.assertIn("per course", detail["adrs"][0]["body"])

    def test_adrs_none_when_no_adr_md(self):
        fx.plant_simple(self.tmp, "m-noadr", stage="plan")
        detail = LocalAdapter(self.tmp).mission("m-noadr")
        self.assertIsNone(detail["adrs"])

    # ── S70-B3: verbatim acceptance criteria (from prd.md) ──
    def test_criteria_parsed_from_prd(self):
        d = fx.plant_simple(self.tmp, "m-prd", stage="plan")
        fx.write(os.path.join(d, "prd.md"),
                 "# Mission: Gamification\n\n"
                 "**Type:** feature\n"
                 "**Goal:** Add XP and badges.\n"
                 "**Acceptance Criteria:**\n"
                 "- Users earn XP for completing lessons\n"
                 "- A leaderboard shows the top 10 learners\n"
                 "**Out of Scope:**\n"
                 "- Real-money rewards\n"
                 "**Constraints:**\n"
                 "- Django + Postgres\n")
        detail = LocalAdapter(self.tmp).mission("m-prd")
        self.assertIsNotNone(detail["criteria"])
        texts = [c["text"] for c in detail["criteria"]]
        self.assertEqual(texts, [
            "Users earn XP for completing lessons",
            "A leaderboard shows the top 10 learners",
        ])
        # the Out of Scope / Constraints bullets must NOT bleed in
        self.assertNotIn("Real-money rewards", texts)
        self.assertNotIn("Django + Postgres", texts)
        # each criterion carries a `done` flag (default False — plain bullets)
        self.assertFalse(detail["criteria"][0]["done"])

    def test_criteria_none_when_no_prd(self):
        fx.plant_simple(self.tmp, "m-noprd", stage="plan")
        detail = LocalAdapter(self.tmp).mission("m-noprd")
        self.assertIsNone(detail["criteria"])


if __name__ == "__main__":
    unittest.main()
