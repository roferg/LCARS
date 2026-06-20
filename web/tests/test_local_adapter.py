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
from lcars_serve.board import STAGES, active_seconds  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402


def _dead_pid():
    """A pid that is not alive: fork+reap a child, reuse its (now-freed) pid.

    Race-tiny (the kernel may recycle it) but adequate for a unit test; the
    adapter treats ESRCH as not-running, which is what we assert.
    """
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    return pid


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

    # ── S73: the `queued` flag (resolve-logs scheduled-but-not-started) ──
    def test_queued_true_when_scheduled_not_started(self):
        """A logged-bug child scheduled in a resolve-logs batch but not yet
        driving carries state.json.queued:true; the board card surfaces it as the
        boolean `queued`."""
        fx.plant_simple(self.tmp, "m-q", stage="plan", queued=True)
        m = self._by_id(self._board(), "m-q")
        self.assertIn("queued", m)
        self.assertTrue(m["queued"])

    def test_queued_false_by_default(self):
        """No queued field on disk ⇒ the card exposes queued:false (never None /
        absent), so the front end can rely on the boolean."""
        fx.plant_simple(self.tmp, "m-nq", stage="plan")
        m = self._by_id(self._board(), "m-nq")
        self.assertIn("queued", m)
        self.assertFalse(m["queued"])

    # ── UX-28: parentMission (logged-bug child's parent id) ──
    def test_parent_mission_surfaced_for_logged_bug_child(self):
        """A logged-bug child records state.json.parentMission; the board card
        (and the detail) must surface it as `parentMission` == that id so the
        front end can render "log bug · child of #<parent>"."""
        fx.plant_simple(self.tmp, "m-bug", stage="plan", parent_mission="m-001")
        m = self._by_id(self._board(), "m-bug")
        self.assertEqual(m["parentMission"], "m-001")
        # surfaced on the mission detail shape too
        detail = LocalAdapter(self.tmp).mission("m-bug")
        self.assertEqual(detail["parentMission"], "m-001")

    def test_parent_mission_none_for_normal_mission(self):
        """A normal mission has no parentMission on disk ⇒ the card exposes
        parentMission None, no crash."""
        fx.plant_simple(self.tmp, "m-norm", stage="plan")
        m = self._by_id(self._board(), "m-norm")
        self.assertIn("parentMission", m)
        self.assertIsNone(m["parentMission"])

    # ── S75: the Verify PR lifecycle on the card shape ──────────────────────
    def test_in_review_mission_surfaces_pr_and_review_state(self):
        """A Mission Verify auto-opened a PR for records prUrl/prNumber + a
        review="open" sub-state; the card must surface all three so the Verify
        modal can show the PR link + the in-review state and offer Merge PR."""
        fx.plant_simple(self.tmp, "m-rev", stage="verify",
                        pr_url="https://github.com/acme/repo/pull/77",
                        pr_number=77, review="open")
        m = self._by_id(self._board(), "m-rev")
        self.assertEqual(m["prUrl"], "https://github.com/acme/repo/pull/77")
        self.assertEqual(m["prNumber"], 77)
        self.assertEqual(m["review"], "open")
        # the card stays in the verify column (NOT done) while in review.
        self.assertEqual(m["stage"], "verify")

    def test_mission_without_pr_has_null_pr_fields(self):
        """A mission not yet in review exposes prUrl/prNumber/review None — the
        fields are present (non-crashing) but empty."""
        fx.plant_simple(self.tmp, "m-nopr", stage="implement")
        m = self._by_id(self._board(), "m-nopr")
        self.assertIn("prUrl", m)
        self.assertIsNone(m["prUrl"])
        self.assertIsNone(m["prNumber"])
        self.assertIsNone(m["review"])

    def test_reconcile_status_surfaced_on_verify_card(self):
        """S76: a verify-stage mission with no PR yet that is reconciling with the
        updated base surfaces its reconcileStatus so the board can show the
        'reconciling with main / re-verifying' note."""
        for st in ("merging", "retesting", "healing", "escalated"):
            fx.plant_simple(self.tmp, "m-rec-%s" % st, stage="verify",
                            reconcile_status=st)
            m = self._by_id(self._board(), "m-rec-%s" % st)
            self.assertEqual(m["reconcileStatus"], st)
            # still at verify with no PR open while reconciling.
            self.assertEqual(m["stage"], "verify")
            self.assertIsNone(m["prUrl"])

    def test_reconcile_status_none_when_not_reconciling(self):
        """The field is always present (non-crashing) and None for a normal
        mission that is not reconciling."""
        fx.plant_simple(self.tmp, "m-norec", stage="implement")
        m = self._by_id(self._board(), "m-norec")
        self.assertIn("reconcileStatus", m)
        self.assertIsNone(m["reconcileStatus"])

    def test_reconciling_mission_with_multiline_diagnosis_not_dropped(self):
        """S76 DEFECT regression: reconcile_gate writes a MULTI-LINE failure
        summary into reconcileDiagnosis. With the FIXED json_escape this stays
        VALID JSON, so the reconciling/escalated parent MUST still appear on the
        board (carrying its reconcile state) and be readable via the detail
        endpoint — instead of silently vanishing (the old behaviour: invalid JSON
        ⇒ _load_json None ⇒ card dropped ⇒ 404) at the worst moment (escalated +
        awaiting the captain)."""
        diagnosis = (
            "MERGING main into the mission branch produced a TEXTUAL conflict.\n"
            "Conflicted/affected: shared.txt\n"
            "\tsuite t-001 went red\tafter merging \"main\".\n"
            "Root cause: main renamed fooBar to foo_bar."
        )
        # healing state (mid-self-heal)
        fx.plant_simple(self.tmp, "m-heal", stage="verify",
                        reconcile_status="healing", reconcile_diagnosis=diagnosis)
        # escalated + awaiting-human (the worst-case the defect hit)
        fx.plant_simple(self.tmp, "m-esc", stage="verify",
                        reconcile_status="escalated", reconcile_diagnosis=diagnosis,
                        awaiting_human=True,
                        pending_question="Reconcile still red after K rounds.")

        board = self._board()
        # BOTH cards must be present (not dropped by a JSON parse error).
        heal = self._by_id(board, "m-heal")
        esc = self._by_id(board, "m-esc")
        self.assertEqual(heal["reconcileStatus"], "healing")
        self.assertEqual(esc["reconcileStatus"], "escalated")
        self.assertTrue(esc["awaiting"])

        # the detail endpoint must serve them (previously 404 "no such mission").
        adapter = LocalAdapter(self.tmp)
        self.assertIsNotNone(adapter.mission("m-heal"))
        esc_detail = adapter.mission("m-esc")
        self.assertIsNotNone(esc_detail)
        self.assertEqual(esc_detail["reconcileStatus"], "escalated")

    def test_malformed_state_json_is_dropped_documenting_the_defect(self):
        """The root cause: an INVALID state.json (a raw newline inside a JSON
        string, exactly what the OLD json_escape emitted for a multi-line
        reconcileDiagnosis) is unparseable, so the adapter drops the mission and
        the detail endpoint 404s. This is why the escaper fix is load-bearing."""
        d = fx.mission_dir(self.tmp, "m-bad")
        os.makedirs(d, exist_ok=True)
        # a literal newline inside the "reconcileDiagnosis" string value → the
        # json.JSONDecodeError "Invalid control character" the defect produced.
        bad = (
            '{\n'
            '  "id": "m-bad",\n'
            '  "stage": "verify",\n'
            '  "reconcileStatus": "escalated",\n'
            '  "reconcileDiagnosis": "line1\nline2",\n'
            '  "awaitingHuman": true\n'
            '}\n'
        )
        with open(os.path.join(d, "state.json"), "w") as fh:
            fh.write(bad)
        # dropped from the board, and 404 on detail — the exact symptom reported.
        board = self._board()
        self.assertNotIn("m-bad", [m["id"] for m in board["missions"]])
        self.assertIsNone(LocalAdapter(self.tmp).mission("m-bad"))

    def test_detail_serves_child_bug_prd_body(self):
        """S76 behaviour 6: a self-authored reconcile bug child's DETAILED PRD
        (Conflict/failure summary, Root cause, Intended fix) must be readable in
        the detail modal — so the detail endpoint serves the verbatim prd body."""
        d = fx.plant_simple(self.tmp, "m-recbug", stage="plan",
                            parent_mission="m-001", mtype="bug")
        prd = (
            "# Mission: reconcile break when main merged in\n"
            "**Type:** bug\n"
            "**Conflict/failure summary:** suite t-001 went red after merging main.\n"
            "**Affected files / tests:** src/foo.js\n"
            "**Root cause:** main renamed fooBar to foo_bar.\n"
            "**Intended fix:** rename the call site, keeping the toggle behaviour.\n"
        )
        with open(os.path.join(d, "prd.md"), "w") as fh:
            fh.write(prd)
        detail = LocalAdapter(self.tmp).mission("m-recbug")
        self.assertIn("prd", detail)
        self.assertIn("Conflict/failure summary", detail["prd"])
        self.assertIn("Root cause", detail["prd"])
        self.assertIn("Intended fix", detail["prd"])

    def test_detail_prd_empty_when_absent(self):
        """No prd.md ⇒ the detail's prd is "" (present, non-crashing)."""
        fx.plant_simple(self.tmp, "m-noprd", stage="implement")
        detail = LocalAdapter(self.tmp).mission("m-noprd")
        self.assertEqual(detail.get("prd"), "")

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

    # ── UX-15: Copilot usage cost pill shows GROSS, not net-$0 ──
    def test_copilot_usage_cost_pill_shows_gross_not_net_zero(self):
        fx.plant_simple(self.tmp, "m-usage", stage="plan",
                        estimate=fx.ESTIMATE_COPILOT_USAGE)
        m = self._by_id(self._board(), "m-usage")
        cost = m["pills"]["cost"]
        # the pill must carry the GROSS band (3.5–7.0), not the net (0.0) band.
        self.assertEqual(cost["low"], 3.5)
        self.assertEqual(cost["high"], 7.0)
        # and its label must not read as a bare $0 when gross is non-zero.
        self.assertNotIn("$0.00", cost["label"])
        self.assertIn("3.50", cost["label"])

    # ── S67 BUG-A: the `running` flag (live driver lock) ──
    def _lock(self, mid, pid):
        """Plant a driver.lock/pid for mission `mid` holding `pid`."""
        d = fx.mission_dir(self.tmp, mid)
        ld = os.path.join(d, "driver.lock")
        os.makedirs(ld, exist_ok=True)
        with open(os.path.join(ld, "pid"), "w") as fh:
            fh.write(str(pid))

    def test_running_false_for_idle_mission_with_no_lock(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        m = self._by_id(self._board(), "m-001")
        self.assertIn("running", m)
        self.assertFalse(m["running"])

    def test_running_true_when_a_live_driver_holds_the_lock(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        # our own pid is, by definition, alive.
        self._lock("m-001", os.getpid())
        m = self._by_id(self._board(), "m-001")
        self.assertTrue(m["running"])

    def test_running_false_for_a_stale_lock_dead_pid(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        # a pid that is (almost certainly) not alive.
        self._lock("m-001", _dead_pid())
        m = self._by_id(self._board(), "m-001")
        self.assertFalse(m["running"])

    def test_running_false_for_garbled_lock_pid(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        self._lock("m-001", "not-a-pid")
        m = self._by_id(self._board(), "m-001")
        self.assertFalse(m["running"])

    def test_running_surfaced_on_mission_detail_too(self):
        fx.plant_simple(self.tmp, "m-001", stage="plan")
        self._lock("m-001", os.getpid())
        detail = LocalAdapter(self.tmp).mission("m-001")
        self.assertTrue(detail["running"])

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

    # ── S74 follow-up CHANGE 3: a logged BUG fast-tracks past Research+Validate,
    # so its model-mix table must omit those rows even though estimate.json still
    # carries all six stages. Adapter-neutral: the filter lives in the shared
    # shape layer (board.model_mix_from_estimate), keyed off mission type. ──
    def test_bug_mission_mix_omits_research_and_validate(self):
        fx.plant_simple(self.tmp, "m-bugmix", stage="plan", mtype="bug",
                        parent_mission="m-001")
        m = self._by_id(self._board(), "m-bugmix")
        self.assertIsNotNone(m["modelMix"])
        stages = [r["stage"] for r in m["modelMix"]]
        self.assertEqual(stages, ["Plan", "Plan Review", "Implement", "Verify"])
        self.assertNotIn("Research", stages)
        self.assertNotIn("Validate", stages)

    def test_feature_mission_mix_keeps_all_six_stages(self):
        fx.plant_simple(self.tmp, "m-featmix", stage="plan")
        m = self._by_id(self._board(), "m-featmix")
        stages = [r["stage"] for r in m["modelMix"]]
        self.assertEqual(stages, ["Research", "Validate", "Plan",
                                  "Plan Review", "Implement", "Verify"])

    # ── S78 CHANGE 4: per-engine model mix. A COPILOT mission is opus-safe, so
    # the DISPLAYED mix must reflect that resolution — every row shows `opus`
    # (mirroring alias_for_tier's copilot default). A CLAUDE mission keeps the
    # estimate's per-stage tiers. ONE estimate, two engines, shape layer. ──
    def test_copilot_mission_mix_is_opus_safe_every_row(self):
        # ESTIMATE_COPILOT_USAGE has sonnet-tier stages; a copilot mission must
        # display opus on EVERY row (opus-safe), and engine == "copilot".
        fx.plant_simple(self.tmp, "m-cop", stage="plan",
                        worker_bin="copilot",
                        estimate=fx.ESTIMATE_COPILOT_USAGE)
        m = self._by_id(self._board(), "m-cop")
        self.assertEqual(m["engine"], "copilot")
        self.assertIsNotNone(m["modelMix"])
        tiers = {r["tier"] for r in m["modelMix"]}
        self.assertEqual(tiers, {"opus"},
                         "a copilot mission's displayed mix must be opus-safe "
                         "on EVERY row, got %r" % tiers)

    def test_claude_mission_mix_keeps_estimate_tiers(self):
        # the SAME sonnet-heavy estimate on a claude engine keeps its tiers.
        fx.plant_simple(self.tmp, "m-cla", stage="plan",
                        worker_bin="claude",
                        estimate=fx.ESTIMATE_COPILOT_USAGE)
        m = self._by_id(self._board(), "m-cla")
        self.assertEqual(m["engine"], "claude")
        rows = {r["stage"]: r["tier"] for r in m["modelMix"]}
        # ESTIMATE_COPILOT_USAGE is all-sonnet → claude keeps sonnet everywhere.
        self.assertEqual(set(rows.values()), {"sonnet"},
                         "claude must keep the estimate's tiers, got %r" % rows)

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


class ActiveSecondsTest(unittest.TestCase):
    """UX-24: active run time = wall-clock from first stage_start to the last
    event (or `now` if an interval is still open) MINUS every human-wait and
    paused interval. `now` is injected so the assertion path never touches the
    real clock."""

    def _ev(self, ts, type_, stage="research"):
        return {"ts": ts, "mission": "m", "stage": stage, "type": type_,
                "detail": ""}

    def test_no_stage_start_is_zero(self):
        evs = [self._ev(50, "gate"), self._ev(60, "error")]
        self.assertEqual(active_seconds(evs, now=100), 0)

    def test_empty_is_zero(self):
        self.assertEqual(active_seconds([], now=100), 0)

    def test_gate_interval_excluded(self):
        # stage_start@100 … gate@130 (awaiting) … stage_start@200 (resumed) …
        # stage_done@260. span = 260-100 = 160; gate interval 130→200 = 70 wait.
        evs = [
            self._ev(100, "stage_start"),
            self._ev(130, "gate"),
            self._ev(200, "stage_start", stage="validate"),
            self._ev(260, "stage_done", stage="validate"),
        ]
        self.assertEqual(active_seconds(evs, now=300), 160 - 70)

    def test_paused_resumed_interval_excluded(self):
        # stage_start@0 … paused@40 … resumed@100 … stage_done@140.
        # span=140; paused interval 40→100 = 60 excluded.
        evs = [
            self._ev(0, "stage_start"),
            self._ev(40, "paused"),
            self._ev(100, "resumed"),
            self._ev(140, "stage_done"),
        ]
        self.assertEqual(active_seconds(evs, now=200), 140 - 60)

    def test_both_gate_and_paused_excluded(self):
        evs = [
            self._ev(0, "stage_start"),
            self._ev(30, "gate"),
            self._ev(50, "stage_start", stage="validate"),  # gate answered (20)
            self._ev(80, "paused"),
            self._ev(120, "resumed"),                        # paused (40)
            self._ev(150, "stage_done"),
        ]
        # span 0→150 = 150; excluded 20+40 = 60.
        self.assertEqual(active_seconds(evs, now=200), 150 - 60)

    def test_open_gate_at_now_is_excluded(self):
        # currently parked at a gate: gate@120 with no resume; now=300.
        # span runs to now (300); active = 120 (start→gate); 120→300 excluded.
        evs = [
            self._ev(100, "stage_start"),
            self._ev(110, "stage_done"),
            self._ev(120, "gate", stage="validate"),
        ]
        self.assertEqual(active_seconds(evs, now=300), 20)

    def test_open_paused_at_now_is_excluded(self):
        evs = [
            self._ev(100, "stage_start"),
            self._ev(160, "paused"),
        ]
        self.assertEqual(active_seconds(evs, now=500), 60)

    def test_closed_run_ends_at_last_event_not_now(self):
        # no open gate/paused: a run whose last event is before `now` is treated
        # as closed — the span ends at the last event, NOT at now (we don't infer
        # "still running" without an open interval).
        evs = [
            self._ev(100, "stage_start"),
            self._ev(140, "stage_done"),
            self._ev(141, "stage_start", stage="validate"),
        ]
        self.assertEqual(active_seconds(evs, now=200), 41)

    def test_verify_gate_is_a_human_wait(self):
        # the verify review gate (emit_event gate verify …) is awaiting-human too.
        evs = [
            self._ev(0, "stage_start"),
            self._ev(50, "gate", stage="verify"),
            self._ev(120, "stage_start", stage="verify"),  # captain answered
            self._ev(140, "stage_done", stage="verify"),
        ]
        # span 140; gate 50→120 = 70 excluded.
        self.assertEqual(active_seconds(evs, now=200), 140 - 70)


class ActiveSecondsOnMissionTest(unittest.TestCase):
    """The CONTRACT: an integer `activeSeconds` on the mission detail shape."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_active_seconds_on_detail(self):
        d = fx.plant_simple(self.tmp, "m-act", stage="validate")
        fx.write_jsonl(os.path.join(d, "events.jsonl"), [
            {"ts": 100, "mission": "m-act", "stage": "research",
             "type": "stage_start", "detail": "starting"},
            {"ts": 130, "mission": "m-act", "stage": "research",
             "type": "gate", "detail": "awaiting"},
            {"ts": 200, "mission": "m-act", "stage": "validate",
             "type": "stage_start", "detail": "starting"},
            {"ts": 260, "mission": "m-act", "stage": "validate",
             "type": "stage_done", "detail": "done"},
        ])
        detail = LocalAdapter(self.tmp).mission("m-act")
        self.assertIn("activeSeconds", detail)
        self.assertIsInstance(detail["activeSeconds"], int)
        # 260-100=160 minus the 130→200 gate (70) = 90 (now after last event).
        self.assertEqual(detail["activeSeconds"], 90)

    def test_active_seconds_absent_events_is_zero(self):
        fx.plant_simple(self.tmp, "m-none", stage="align")
        detail = LocalAdapter(self.tmp).mission("m-none")
        self.assertEqual(detail.get("activeSeconds", 0), 0)


if __name__ == "__main__":
    unittest.main()
