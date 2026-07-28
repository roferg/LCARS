"""LOCAL adapter — maps a `.git/lcars/missions/*` tree to the board shape.

Behaviors covered:
  1. columns, pills, paused/gate state, nested tickets from a fixture tree.
  2. a gated mission lands in its in-flight (pending.json.stage) column, NOT
     align — mirroring status.sh's gate rule exactly.
"""
import json
import os
import sys
import tempfile
import time
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

    def test_gate_envelope_fields_passed_through(self):
        # BUG-027: the harness writes a legible, type-aware gate envelope into
        # pending.json; the adapter must surface it verbatim as card["gate"] so the
        # front end can render type-appropriate copy + a technical-detail
        # disclosure.
        d = fx.plant_gated(self.tmp, "m-gate", resume_stage="align",
                           inflight_stage="implement")
        pending = json.load(open(os.path.join(d, "pending.json")))
        pending.update({
            "humanSummary": "Two of your changes conflict — #47 re-broke a test "
                            "#43 locked in.",
            "escalationType": "regression",
            "technicalDetail": "FULL-SUITE GATE: t-001 REGRESSED\n"
                               "node --test tests/**/*.test.js",
        })
        fx.write_json(os.path.join(d, "pending.json"), pending)
        m = self._by_id(self._board(), "m-gate")
        self.assertIsNotNone(m["gate"])
        self.assertEqual(m["gate"]["escalationType"], "regression")
        self.assertIn("#47", m["gate"]["humanSummary"])
        self.assertIn("FULL-SUITE GATE", m["gate"]["technicalDetail"])

    def test_gate_none_when_no_envelope_fields(self):
        # a plain pre-harness pending.json (no new fields) → gate is None so the
        # renderer degrades to the bare question text.
        fx.plant_gated(self.tmp, "m-gate", resume_stage="align",
                       inflight_stage="research")
        m = self._by_id(self._board(), "m-gate")
        self.assertIsNone(m["gate"])
        self.assertTrue(m["awaiting"])

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

    def test_progress_counts_distinct_green_tickets_not_every_event(self):
        """BUG-050: a single ticket can emit MULTIPLE ticket_green events (goes
        green → ticket_replay_conflict → serial rebuild → goes green AGAIN), so a
        naive per-event increment over-counts ("TICKET 2/1", a >100% bar).
        _progress must count DISTINCT tickets that reached green, clamped to the
        total."""
        from lcars_serve.local_adapter import _progress
        waves = [{"wave": 1, "tickets": [{"id": "t-001", "issue": 201}]}]
        events = [
            {"type": "wave_start", "data": {"wave": 1}},
            {"type": "ticket_start", "data": {"ticket": "t-001"}},
            {"type": "ticket_green", "data": {"ticket": "t-001"}},
            {"type": "ticket_replay_conflict", "data": {"ticket": "t-001"}},
            # the SAME ticket goes green again after the serial rebuild
            {"type": "ticket_green", "data": {"ticket": "t-001"}},
        ]
        prog = _progress(waves, events)
        # one distinct ticket reached green, not two
        self.assertEqual(prog["ticketsDone"], 1)
        self.assertEqual(prog["ticketsTotal"], 1)
        # the label reads 1/1 (never "TICKET 2/1")
        self.assertIn("TICKET 1/1", prog["label"])
        self.assertNotIn("2/1", prog["label"])
        # defensive clamp: ticketsDone can never exceed the total
        self.assertLessEqual(prog["ticketsDone"], prog["ticketsTotal"])

    def test_single_ticket_mission_shows_no_tickets(self):
        fx.plant_simple(self.tmp, "m-solo", stage="plan")
        m = self._by_id(self._board(), "m-solo")
        self.assertEqual(m["tickets"], [])

    def test_single_ticket_proof_surfaced_at_mission_level(self):
        """S134 defect: a single-ticket mission carries NO ticket rows, so its
        lone ticket's proof-of-work must ride the mission as `contractProof`
        (same _ticket_proof shape + its id) — the CLI↔UI parity field the board
        renders the PROVEN chip + CONTRACT AMENDMENTS from."""
        fx.plant_single_ticket_proof(
            self.tmp, "m-lone", ticket_id="t-solo", flip_flop="pass",
            edits=[{"path": "src/api.test.ts",
                    "reason": "the fix changes the error return from null to a Result"}])
        m = self._by_id(self._board(), "m-lone")
        # the "no nested rows" convention is preserved
        self.assertEqual(m["tickets"], [])
        cp = m["contractProof"]
        self.assertEqual(cp["id"], "t-solo")
        self.assertEqual(cp["flipFlop"]["verdict"], "proven")
        self.assertEqual(cp["declaredEdits"],
                         [{"path": "src/api.test.ts",
                           "reason": "the fix changes the error return from null to a Result"}])

    def test_single_ticket_no_proof_omits_contract_proof(self):
        """Byte-identity: a single-ticket mission with NO proof artifacts must NOT
        carry a `contractProof` key at all (ABSENT, not empty)."""
        fx.plant_single_ticket_proof(self.tmp, "m-bare", flip_flop=None)
        m = self._by_id(self._board(), "m-bare")
        self.assertEqual(m["tickets"], [])
        self.assertNotIn("contractProof", m)

    def test_multi_ticket_mission_has_no_contract_proof(self):
        """No double-render: a multi-ticket mission surfaces proof via its
        per-ticket rows, so the mission-level `contractProof` must be ABSENT."""
        fx.plant_implementing(self.tmp, "m-multi")
        m = self._by_id(self._board(), "m-multi")
        self.assertTrue(len(m["tickets"]) > 1)
        self.assertNotIn("contractProof", m)

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

    # ── Park & Align (S137): the additive `prdPending` standby field ──
    def test_parked_mission_card_carries_prd_pending(self):
        """A PARKED mission (state.json.prdPending:true, no estimate.json) yields
        a card with prdPending:true, sitting in the align column, with NO estimate
        cost pill (it has no estimate yet)."""
        fx.plant_parked(self.tmp, "m-park", issue=200)
        board = self._board()
        self.assertEqual([m["id"] for m in board["columns"]["align"]], ["m-park"])
        m = self._by_id(board, "m-park")
        self.assertTrue(m.get("prdPending"))
        self.assertEqual(m["stage"], "align")
        # a parked mission has no estimate → no cost pill (no estimate pills).
        self.assertIsNone(m["pills"].get("cost"))
        self.assertIsNone(m["pills"].get("reasoning"))
        self.assertIsNone(m["pills"].get("implementation"))

    def test_parked_mission_surfaces_engine_chip(self):
        fx.plant_parked(self.tmp, "m-park", issue=200, worker_bin="copilot")
        m = self._by_id(self._board(), "m-park")
        self.assertEqual(m["engine"], "copilot")
        self.assertTrue(m.get("prdPending"))

    def test_non_parked_card_omits_prd_pending_byte_identical(self):
        """The additive field is ABSENT (not false) on every non-parked card, so
        the existing card payload is byte-identical."""
        fx.plant_simple(self.tmp, "m-001", stage="align", issue=142)
        m = self._by_id(self._board(), "m-001")
        self.assertNotIn("prdPending", m)

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

    # ── BUG-033: the child carries its parent's ISSUE number on the shape ──
    def test_parent_issue_surfaced_from_child_state(self):
        """BUG-033: a logged-bug child records state.json.parentIssue (its
        parent's GitHub issue #). The board must surface it as `parentIssue` so
        the "child of #<n>" badge survives the parent merging off the board (the
        front-end ISSUE_BY_ID index only covers ACTIVE cards)."""
        fx.plant_simple(self.tmp, "m-bug", stage="plan", parent_mission="m-001",
                        parent_issue=142)
        m = self._by_id(self._board(), "m-bug")
        self.assertEqual(m["parentIssue"], 142)
        detail = LocalAdapter(self.tmp).mission("m-bug")
        self.assertEqual(detail["parentIssue"], 142)

    def test_parent_issue_none_when_absent(self):
        """No parentIssue on disk ⇒ the field is present and None (non-crashing)."""
        fx.plant_simple(self.tmp, "m-norm", stage="plan")
        m = self._by_id(self._board(), "m-norm")
        self.assertIn("parentIssue", m)
        self.assertIsNone(m["parentIssue"])

    # ── BUG-036: prNumber is populated, deriving from prUrl when absent ──
    def test_pr_number_derived_from_pr_url_when_absent(self):
        """BUG-036: a verify mission with a prUrl but NO prNumber on disk must
        still expose prNumber, derived from the prUrl trailing /pull/<n>, so the
        Verify dialog never renders a blank 'PR #'."""
        fx.plant_simple(self.tmp, "m-derive", stage="verify",
                        pr_url="https://github.com/acme/repo/pull/93",
                        review="open")  # NOTE: no pr_number planted
        m = self._by_id(self._board(), "m-derive")
        self.assertEqual(m["prUrl"], "https://github.com/acme/repo/pull/93")
        self.assertEqual(m["prNumber"], 93)

    def test_pr_number_explicit_wins_over_url(self):
        """An explicit state.json.prNumber is used verbatim (not re-derived)."""
        fx.plant_simple(self.tmp, "m-pr", stage="verify",
                        pr_url="https://github.com/acme/repo/pull/77",
                        pr_number=77, review="open")
        m = self._by_id(self._board(), "m-pr")
        self.assertEqual(m["prNumber"], 77)

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

    def test_reconcile_status_surfaced_even_when_pr_open(self):
        """BUG-039: a verify mission may carry a live reconcileStatus WHILE its PR
        is open (prUrl set) — the now-normal self-heal case. The adapter must
        surface reconcileStatus regardless of prUrl so the board can suppress
        Merge and show the heal note even with a PR recorded."""
        for st in ("merging", "retesting", "healing", "escalated"):
            fx.plant_simple(self.tmp, "m-prrec-%s" % st, stage="verify",
                            reconcile_status=st,
                            pr_url="https://github.com/acme/repo/pull/88",
                            pr_number=88, review="open")
            m = self._by_id(self._board(), "m-prrec-%s" % st)
            self.assertEqual(m["reconcileStatus"], st)
            # the PR is still surfaced (the board uses it to suppress Merge).
            self.assertEqual(m["prUrl"], "https://github.com/acme/repo/pull/88")

    def test_reconcile_status_none_when_not_reconciling(self):
        """The field is always present (non-crashing) and None for a normal
        mission that is not reconciling."""
        fx.plant_simple(self.tmp, "m-norec", stage="implement")
        m = self._by_id(self._board(), "m-norec")
        self.assertIn("reconcileStatus", m)
        self.assertIsNone(m["reconcileStatus"])

    def test_reconcile_new_statuses_surfaced(self):
        """BUG-067 SHARED CONTRACT: the two NEW reconcileStatus values —
        awaiting-reapprove (heal converged, awaiting the human's reapprove) and
        merge-failed (push/merge failed, surfaced not silent) — pass through
        verbatim so the board can render the gate + the merge-failed outcome."""
        for st in ("awaiting-reapprove", "merge-failed"):
            fx.plant_simple(self.tmp, "m-new-%s" % st, stage="verify",
                            reconcile_status=st, awaiting_human=True,
                            reconcile_note="some human-readable summary")
            m = self._by_id(self._board(), "m-new-%s" % st)
            self.assertEqual(m["reconcileStatus"], st)
            self.assertTrue(m["awaiting"])

    def test_reconcile_note_and_merge_sha_surfaced(self):
        """BUG-067: reconcileNote (the card summary) and reconcileMergeSha (the
        reconciled tip) are exposed on the card shape so the gate/merge-failed
        renderer can show the summary + sha verbatim."""
        note = ("Reconciled main into the branch (abc1234) and re-tested green "
                "(8/8). Reapprove to merge.")
        fx.plant_simple(self.tmp, "m-rn", stage="verify",
                        reconcile_status="awaiting-reapprove",
                        awaiting_human=True, reconcile_note=note,
                        reconcile_merge_sha="abc1234")
        m = self._by_id(self._board(), "m-rn")
        self.assertEqual(m["reconcileNote"], note)
        self.assertEqual(m["reconcileMergeSha"], "abc1234")

    def test_reconcile_note_and_merge_sha_none_when_absent(self):
        """Both fields are always present (non-crashing) and None when not set."""
        fx.plant_simple(self.tmp, "m-nonote", stage="implement")
        m = self._by_id(self._board(), "m-nonote")
        self.assertIn("reconcileNote", m)
        self.assertIsNone(m["reconcileNote"])
        self.assertIn("reconcileMergeSha", m)
        self.assertIsNone(m["reconcileMergeSha"])

    def test_merge_failed_surfaced_on_detail_too(self):
        """BUG-067: the merge-failed outcome + its note ride the detail endpoint
        (not just the board) so the modal can render the error state."""
        fx.plant_simple(self.tmp, "m-mf", stage="verify",
                        reconcile_status="merge-failed", awaiting_human=True,
                        reconcile_note="push rejected: non-fast-forward")
        detail = LocalAdapter(self.tmp).mission("m-mf")
        self.assertIsNotNone(detail)
        self.assertEqual(detail["reconcileStatus"], "merge-failed")
        self.assertEqual(detail["reconcileNote"],
                         "push rejected: non-fast-forward")

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

    # ── S114: the REAL liveness signal (worker-liveness.json → card.liveness) ──
    def _make_running(self, mid, stage="implement"):
        """Plant a running mission: a live driver.lock (this test's own pid) makes
        _driver_running() True, the gate liveness surfaces behind."""
        d = fx.plant_simple(self.tmp, mid, stage=stage)
        lock = os.path.join(d, "driver.lock")
        os.makedirs(lock, exist_ok=True)
        with open(os.path.join(lock, "pid"), "w") as fh:
            fh.write(str(os.getpid()))   # alive → running True
        return d

    def _write_liveness(self, d, **kv):
        with open(os.path.join(d, "worker-liveness.json"), "w") as fh:
            fh.write(json.dumps(kv))

    def test_liveness_surfaced_for_running_worker(self):
        """A live worker's sidecar file surfaces as an additive `liveness` card
        field, echoing state/stage/outputBytes."""
        d = self._make_running("m-live")
        now = time.time()
        self._write_liveness(d, stage="implement", startedAt=now - 20,
                             lastOutputTs=now - 1, outputBytes=4096,
                             state="producing")
        m = self._by_id(self._board(), "m-live")
        self.assertIn("liveness", m)
        self.assertEqual(m["liveness"]["state"], "producing")
        self.assertEqual(m["liveness"]["stage"], "implement")
        self.assertEqual(m["liveness"]["outputBytes"], 4096)

    def test_liveness_quiet_seconds_computed_server_side(self):
        """Staleness (quietSeconds = now - lastOutputTs) is computed SERVER-SIDE so
        the client needn't carry its own clock."""
        d = self._make_running("m-quiet")
        now = time.time()
        self._write_liveness(d, stage="implement", startedAt=now - 300,
                             lastOutputTs=now - 40, outputBytes=10,
                             state="quiet")
        m = self._by_id(self._board(), "m-quiet")
        self.assertEqual(m["liveness"]["state"], "quiet")
        # server-computed, ~40s (allow a hair of test-runtime drift)
        self.assertGreaterEqual(m["liveness"]["quietSeconds"], 39)
        self.assertLessEqual(m["liveness"]["quietSeconds"], 43)

    def test_liveness_absent_when_no_file_is_byte_identical(self):
        """A RUNNING mission with NO sidecar file adds NO `liveness` key at all —
        the card payload is byte-identical to before S114."""
        self._make_running("m-nofile")
        m = self._by_id(self._board(), "m-nofile")
        self.assertNotIn("liveness", m)

    def test_liveness_never_shown_when_not_running(self):
        """A STALE sidecar left by a hard-crashed process (no live driver lock)
        must NEVER show a pulse — a dead worker shows nothing (the tester's #1
        hunt). No driver.lock ⇒ running False ⇒ no `liveness` key even though the
        file is present on disk."""
        d = fx.plant_simple(self.tmp, "m-stale", stage="implement")  # no lock
        now = time.time()
        self._write_liveness(d, stage="implement", startedAt=now - 99,
                             lastOutputTs=now - 99, outputBytes=1,
                             state="producing")
        m = self._by_id(self._board(), "m-stale")
        self.assertNotIn("liveness", m)

    def test_liveness_malformed_state_ignored(self):
        """A sidecar with an unknown/garbled state is ignored (no crash, no key)."""
        d = self._make_running("m-bad-live")
        self._write_liveness(d, stage="implement", lastOutputTs=1,
                             state="haywire")
        m = self._by_id(self._board(), "m-bad-live")
        self.assertNotIn("liveness", m)

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

    # ── S113: the ACTUAL usage pill (display-only, beside the estimate) ──
    def test_actual_pill_present_at_verify_with_full_usage(self):
        # a verify-stage mission WITH usage.json → pills.actual in usd, exact total.
        fx.plant_simple(self.tmp, "m-ver", stage="verify",
                        estimate=fx.ESTIMATE_CLAUDE)
        fx.plant_usage(self.tmp, "m-ver", fx.USAGE_CLAUDE)
        m = self._by_id(self._board(), "m-ver")
        actual = m["pills"]["actual"]
        self.assertEqual(actual["unit"], "usd")
        self.assertAlmostEqual(actual["value"], 0.15, places=6)
        self.assertFalse(actual["partial"])
        self.assertEqual(actual["label"], "~$0.15")
        # the estimate pill is UNCHANGED beside it (both same unit).
        self.assertEqual(m["pills"]["cost"]["unit"], "usd")

    def test_actual_pill_present_at_done(self):
        fx.plant_simple(self.tmp, "m-done", stage="done",
                        estimate=fx.ESTIMATE_CLAUDE)
        fx.plant_usage(self.tmp, "m-done", fx.USAGE_CLAUDE)
        # done missions live in the done column (out of the flat missions list).
        m = None
        for c in self._board()["columns"]["done"]:
            if c["id"] == "m-done":
                m = c
        self.assertIsNotNone(m)
        self.assertEqual(m["pills"]["actual"]["label"], "~$0.15")

    def test_actual_pill_copilot_legacy_is_premium_requests(self):
        fx.plant_simple(self.tmp, "m-cop", stage="verify",
                        estimate=fx.ESTIMATE_COPILOT_LEGACY)
        fx.plant_usage(self.tmp, "m-cop", fx.USAGE_COPILOT_LEGACY)
        m = self._by_id(self._board(), "m-cop")
        actual = m["pills"]["actual"]
        self.assertEqual(actual["unit"], "premiumRequests")
        self.assertEqual(actual["value"], 15)
        self.assertEqual(actual["label"], "~15 reqs")
        # same unit as its estimate pill (both premiumRequests).
        self.assertEqual(m["pills"]["cost"]["unit"], "premiumRequests")

    def test_actual_pill_partial_when_a_stage_unavailable(self):
        fx.plant_simple(self.tmp, "m-part", stage="verify",
                        estimate=fx.ESTIMATE_CLAUDE)
        fx.plant_usage(self.tmp, "m-part", fx.USAGE_PARTIAL)
        m = self._by_id(self._board(), "m-part")
        actual = m["pills"]["actual"]
        self.assertTrue(actual["partial"])
        self.assertAlmostEqual(actual["value"], 0.05, places=6)
        self.assertIn("partial", actual["label"])
        self.assertEqual(actual["label"], "~$0.05 · partial")

    def test_no_usage_json_no_actual_key_byte_identical(self):
        # THE key regression: a verify mission WITHOUT usage.json produces the
        # EXACT same card payload as before this round — no pills.actual key.
        fx.plant_simple(self.tmp, "m-nou", stage="verify",
                        estimate=fx.ESTIMATE_CLAUDE)
        # baseline: capture the card, then confirm adding NOTHING keeps it equal.
        m = self._by_id(self._board(), "m-nou")
        self.assertNotIn("actual", m["pills"])
        self.assertEqual(set(m["pills"].keys()),
                         {"cost", "reasoning", "implementation"})

    def test_no_actual_pill_before_verify_even_with_usage(self):
        # usage present but the mission is still at plan → NO actual pill yet
        # (only verify/done surface actuals).
        fx.plant_simple(self.tmp, "m-early", stage="plan",
                        estimate=fx.ESTIMATE_CLAUDE)
        fx.plant_usage(self.tmp, "m-early", fx.USAGE_CLAUDE)
        m = self._by_id(self._board(), "m-early")
        self.assertNotIn("actual", m["pills"])

    def test_actual_pill_on_mission_log_child_card(self):
        # a logged-bug CHILD is a mission — it flows through the same _card path,
        # so at verify with usage it gets the actual pill for free.
        fx.plant_simple(self.tmp, "m-child", stage="verify",
                        estimate=fx.ESTIMATE_CLAUDE, mtype="bug",
                        parent_mission="m-parent", parent_issue=99)
        fx.plant_usage(self.tmp, "m-child", fx.USAGE_CLAUDE)
        m = self._by_id(self._board(), "m-child")
        self.assertEqual(m["parentMission"], "m-parent")
        self.assertEqual(m["pills"]["actual"]["label"], "~$0.15")

    def test_actual_pill_in_mission_detail(self):
        # the detail shape (mission(mid)) carries the same actual pill.
        fx.plant_simple(self.tmp, "m-ver", stage="verify",
                        estimate=fx.ESTIMATE_CLAUDE)
        fx.plant_usage(self.tmp, "m-ver", fx.USAGE_CLAUDE)
        detail = LocalAdapter(self.tmp).mission("m-ver")
        self.assertEqual(detail["pills"]["actual"]["label"], "~$0.15")

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

    # ── BUG-062: the `dispatched` flag (was the run actually launched?) ──
    # A logged bug fast-tracks to stage="plan" but, with the estimate gate, is
    # FILED but HELD at estimate-review — only estimate.json exists, NO
    # events.jsonl, no driver lock. It is NOT dispatched, so its card must show
    # "Start", not "Pause". `dispatched` is the durable signal the front end
    # gates the Start/Pause button on: true iff a run has actually run (events
    # on disk) OR a live driver currently holds the lock.
    def test_dispatched_false_for_filed_but_held_bug_estimate_only(self):
        """The crux of BUG-062: a bug parked at plan with ONLY estimate.json (no
        events.jsonl, no lock) is filed-but-held — not dispatched."""
        fx.plant_simple(self.tmp, "m-bug", stage="plan", mtype="bug")
        m = self._by_id(self._board(), "m-bug")
        self.assertIn("dispatched", m)
        self.assertFalse(m["dispatched"],
                         "an estimate-only, no-events bug must not read dispatched")
        self.assertFalse(m["running"])

    def test_dispatched_true_when_events_jsonl_present(self):
        """Once a run is actually dispatched it emits events.jsonl ⇒ dispatched."""
        fx.plant_simple(self.tmp, "m-run", stage="plan")
        self._events("m-run", [
            {"ts": 1, "stage": "plan", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-run")
        self.assertTrue(m["dispatched"])

    def test_dispatched_true_when_a_live_driver_holds_the_lock(self):
        """A live driver lock (run just started, events not yet flushed) ⇒
        dispatched, so the card never flashes a clickable Start mid-launch."""
        fx.plant_simple(self.tmp, "m-run", stage="plan")
        self._lock("m-run", os.getpid())
        m = self._by_id(self._board(), "m-run")
        self.assertTrue(m["dispatched"])

    def test_dispatched_false_for_align_mission_no_events(self):
        """A fresh align mission (no events, no lock) is not dispatched."""
        fx.plant_simple(self.tmp, "m-align", stage="align")
        m = self._by_id(self._board(), "m-align")
        self.assertFalse(m["dispatched"])

    def test_dispatched_surfaced_on_mission_detail_too(self):
        fx.plant_simple(self.tmp, "m-run", stage="plan")
        self._events("m-run", [
            {"ts": 1, "stage": "plan", "type": "stage_start", "detail": ""},
        ])
        detail = LocalAdapter(self.tmp).mission("m-run")
        self.assertTrue(detail["dispatched"])

    # ── BUG-017: a running, non-gated card shows its in-flight events stage ──
    def _events(self, mid, rows):
        d = fx.mission_dir(self.tmp, mid)
        fx.write_jsonl(os.path.join(d, "events.jsonl"), rows)

    def test_running_mission_uses_inflight_events_stage_not_state_stage(self):
        """The crux of BUG-017: state.json.stage is the RESUME pointer (lags). A
        running mission's column must come from events.jsonl's latest open
        stage_start (the stage actually executing), not the stale state.stage."""
        # state.json says align (resume pointer), but the latest open stage_start
        # is research — the running card belongs in the Research column.
        fx.plant_simple(self.tmp, "m-run", stage="align")
        self._lock("m-run", os.getpid())
        self._events("m-run", [
            {"ts": 1, "stage": "research", "type": "stage_start",
             "detail": "starting"},
        ])
        board = self._board()
        self.assertEqual([m["id"] for m in board["columns"]["align"]], [])
        col = board["columns"]["research"]
        self.assertEqual([m["id"] for m in col], ["m-run"])
        self.assertEqual(col[0]["stage"], "research")

    def test_running_inflight_is_latest_open_stage_after_a_stage_done(self):
        """A completed stage_done closes its stage; the following open stage_start
        is the in-flight one. research done → validate started ⇒ Validate column."""
        fx.plant_simple(self.tmp, "m-run", stage="align")
        self._lock("m-run", os.getpid())
        self._events("m-run", [
            {"ts": 1, "stage": "research", "type": "stage_start", "detail": ""},
            {"ts": 2, "stage": "research", "type": "stage_done", "detail": ""},
            {"ts": 3, "stage": "validate", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-run")
        self.assertEqual(m["stage"], "validate")

    def test_running_falls_back_to_state_stage_with_no_stage_events(self):
        """No stage_start events yet ⇒ keep state.json.stage (the resume pointer)."""
        fx.plant_simple(self.tmp, "m-run", stage="plan")
        self._lock("m-run", os.getpid())
        self._events("m-run", [
            {"ts": 1, "stage": "plan", "type": "ticket_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-run")
        self.assertEqual(m["stage"], "plan")

    def test_idle_mission_keeps_state_stage_even_with_open_stage_event(self):
        """The in-flight override is RUNNING-only. An idle mission (no live driver
        lock) keeps state.json.stage even if a stale stage_start is on disk —
        avoids a crashed run leaving a card stuck in a column it isn't running."""
        fx.plant_simple(self.tmp, "m-idle", stage="align")
        # no driver lock ⇒ not running.
        self._events("m-idle", [
            {"ts": 1, "stage": "research", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-idle")
        self.assertFalse(m["running"])
        self.assertEqual(m["stage"], "align")

    def test_awaiting_human_still_uses_pending_stage_not_events(self):
        """The awaiting-human → pending.json.stage rule is UNCHANGED by BUG-017."""
        fx.plant_gated(self.tmp, "m-gate", resume_stage="align",
                       inflight_stage="research")
        # even if events disagree, a gated mission follows pending.json.stage.
        self._events("m-gate", [
            {"ts": 1, "stage": "validate", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-gate")
        self.assertTrue(m["awaiting"])
        self.assertEqual(m["stage"], "research")

    # ── Mission-log-grounding round: a logged bug (state.json.stage="align" as
    # the resume pointer, origin="log") FLOWS through the columns exactly like a
    # normal running mission — the in-flight column comes from events.jsonl's
    # latest open stage_start (BUG-017 path), which for a logged bug is Research
    # (grounding) → Validate → Plan → …. No columning special-case is needed; it
    # inherits the normal-mission behaviour. These prove it. ──
    def test_logged_bug_columns_into_research_while_grounding(self):
        # state.json.stage is align (resume pointer); the driver emits a research
        # stage_start → the card belongs in the Research column, NOT Align.
        fx.plant_simple(self.tmp, "m-lb", stage="align", mtype="bug",
                        origin="log", parent_mission="m-001")
        self._lock("m-lb", os.getpid())
        self._events("m-lb", [
            {"ts": 1, "stage": "research", "type": "stage_start", "detail": ""},
        ])
        board = self._board()
        self.assertEqual([m["id"] for m in board["columns"]["align"]], [])
        col = board["columns"]["research"]
        self.assertEqual([m["id"] for m in col], ["m-lb"])
        self.assertEqual(col[0]["stage"], "research")
        # and it carries the grounding descriptor while in Research.
        self.assertTrue(col[0]["groundingResearch"])

    def test_logged_bug_flows_research_to_validate(self):
        # research done → validate started ⇒ the logged bug lands in Validate.
        fx.plant_simple(self.tmp, "m-lb", stage="align", mtype="bug",
                        origin="log", parent_mission="m-001")
        self._lock("m-lb", os.getpid())
        self._events("m-lb", [
            {"ts": 1, "stage": "research", "type": "stage_start", "detail": ""},
            {"ts": 2, "stage": "research", "type": "stage_done", "detail": ""},
            {"ts": 3, "stage": "validate", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-lb")
        self.assertEqual(m["stage"], "validate")

    def test_paused_running_mission_keeps_state_stage(self):
        """A paused mission (even if its lock is still live) is not 'actively
        executing' a stage — keep the resume pointer, don't chase events."""
        fx.plant_paused(self.tmp, "m-pause", stage="plan")
        self._lock("m-pause", os.getpid())
        self._events("m-pause", [
            {"ts": 1, "stage": "implement", "type": "stage_start", "detail": ""},
        ])
        m = self._by_id(self._board(), "m-pause")
        self.assertTrue(m["paused"])
        self.assertEqual(m["stage"], "plan")

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

    # ── Mission-log-grounding round: a LOGGED bug now walks the FULL pipeline
    # (Research grounding → Validate → …), so its model-mix table KEEPS the
    # Research + Validate rows. The mix is driven purely by what estimate.json
    # carries; a logged bug's estimate scores all six stages. ──
    def test_logged_bug_mix_keeps_research_and_validate(self):
        fx.plant_simple(self.tmp, "m-logbug", stage="align", mtype="bug",
                        origin="log", parent_mission="m-001",
                        estimate=fx.ESTIMATE_CLAUDE)
        m = self._by_id(self._board(), "m-logbug")
        self.assertIsNotNone(m["modelMix"])
        stages = [r["stage"] for r in m["modelMix"]]
        self.assertEqual(stages, ["Research", "Validate", "Plan",
                                  "Plan Review", "Implement", "Verify"])
        self.assertIn("Research", stages)
        self.assertIn("Validate", stages)
        # cost + both difficulty pills populate from the 6-stage filing estimate.
        self.assertIsNotNone(m["pills"]["cost"])
        self.assertEqual(m["pills"]["cost"]["unit"], "usd")
        self.assertEqual(m["pills"]["reasoning"]["level"], "medium")
        self.assertEqual(m["pills"]["implementation"]["level"], "high")
        # the grounding descriptor rides the card (scoped Research pass).
        self.assertTrue(m["groundingResearch"])
        self.assertEqual(m["origin"], "log")

    # Regression: a genuinely FAST-TRACKED bug (legacy/none) whose estimate.json
    # omits research/validate from `models` still HIDES those rows — no empty
    # Research/Validate rows now that the is_bug filter is gone.
    def test_real_fast_track_bug_mix_omits_research_and_validate(self):
        fx.plant_simple(self.tmp, "m-bugmix", stage="plan", mtype="bug",
                        parent_mission="m-001",
                        estimate=fx.ESTIMATE_FASTTRACK_BUG)
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

    # ── S147 round-2 SMELL 8: the board must DERIVE the per-engine tier from the
    # same policy the harness uses (alias_for_tier + config.json modelAliases),
    # not hard-code "copilot ⇒ opus". Once run.sh's readout learned to honour
    # `modelAliases.copilot.sonnet`, a board that still forced opus disagreed
    # with the CLI about the very same mission — and the UI is a viewport, never
    # a reimplementation. ──
    def test_copilot_mix_honours_model_aliases_override(self):
        os.makedirs(os.path.join(self.tmp, ".git", "lcars"), exist_ok=True)
        fx.write_json(os.path.join(self.tmp, ".git", "lcars", "config.json"),
                      {"model": "claude-sonnet", "projectName": "r",
                       "contextFile": None,
                       "modelAliases": {"copilot": {"sonnet": "claude-sonnet-4.6"}}})
        fx.plant_simple(self.tmp, "m-copov", stage="plan",
                        worker_bin="copilot",
                        estimate=fx.ESTIMATE_COPILOT_USAGE)
        m = self._by_id(self._board(), "m-copov")
        tiers = {r["tier"] for r in m["modelMix"]}
        self.assertEqual(tiers, {"sonnet"},
                         "with modelAliases.copilot.sonnet mapped back to a real "
                         "Sonnet model the board must say sonnet (the CLI does), "
                         "got %r" % tiers)

    def test_copilot_mix_still_opus_by_default(self):
        # …and with NO override the opus-safe default is unchanged.
        os.makedirs(os.path.join(self.tmp, ".git", "lcars"), exist_ok=True)
        fx.write_json(os.path.join(self.tmp, ".git", "lcars", "config.json"),
                      {"model": "claude-sonnet", "projectName": "r",
                       "contextFile": None})
        fx.plant_simple(self.tmp, "m-copdef", stage="plan",
                        worker_bin="copilot",
                        estimate=fx.ESTIMATE_COPILOT_USAGE)
        m = self._by_id(self._board(), "m-copdef")
        self.assertEqual({r["tier"] for r in m["modelMix"]}, {"opus"})

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

    def test_launch_launching_status_surfaces_on_card(self):
        # S110: launch.sh persists an intermediate `status:"launching"` record for
        # the whole 15–60s discovery+spawn window so a card reopened mid-launch
        # shows "launching", not the RUN prompt. The launch shape flows generically
        # through the adapter; this pins the new status is carried through verbatim.
        d = fx.plant_simple(self.tmp, "m-launching", stage="verify")
        fx.write_json(os.path.join(d, "launch.json"), {
            "status": "launching",
            "target": "the m9 app",
            "message": "the app is starting…",
        })
        m = self._by_id(self._board(), "m-launching")
        self.assertIn("launch", m)
        self.assertEqual(m["launch"]["status"], "launching")
        self.assertEqual(m["launch"]["target"], "the m9 app")
        # the detail view carries the same launch shape
        detail = LocalAdapter(self.tmp).mission("m-launching")
        self.assertEqual(detail["launch"]["status"], "launching")

    def test_launch_running_status_surfaces_on_card_for_badge(self):
        # S110 (card badge): a running launch.json yields launch.status=="running"
        # on the card so the board can render the ● APP LIVE badge. Guard for the
        # data the front-end badge depends on.
        d = fx.plant_simple(self.tmp, "m-live", stage="verify")
        fx.write_json(os.path.join(d, "launch.json"), {
            "status": "running", "target": "the game",
            "url": "http://localhost:5173", "message": "the app is running.",
        })
        m = self._by_id(self._board(), "m-live")
        self.assertEqual(m["launch"]["status"], "running")

    def test_never_launched_mission_has_no_launch_key(self):
        # Board-shape-additive invariant: a mission that was never launched (no
        # launch.json) carries NO `launch` key at all — renders exactly as before.
        fx.plant_simple(self.tmp, "m-nolaunch", stage="verify")
        m = self._by_id(self._board(), "m-nolaunch")
        self.assertNotIn("launch", m)


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

    def test_active_seconds_at_anchor_present(self):
        """BUG-047: the shape carries activeSecondsAt (the server `now` used to
        compute activeSeconds) so the front-end live clock re-bases from a server
        anchor instead of a snapshot frozen at the last stage boundary."""
        d = fx.plant_simple(self.tmp, "m-anchor", stage="research")
        fx.write_jsonl(os.path.join(d, "events.jsonl"), [
            {"ts": 100, "mission": "m-anchor", "stage": "research",
             "type": "stage_start", "detail": "starting"},
        ])
        before = time.time()
        detail = LocalAdapter(self.tmp).mission("m-anchor")
        after = time.time()
        self.assertIn("activeSecondsAt", detail)
        self.assertIsInstance(detail["activeSecondsAt"], (int, float))
        # the anchor is the wall-clock `now` at shape-build time.
        self.assertGreaterEqual(detail["activeSecondsAt"], before)
        self.assertLessEqual(detail["activeSecondsAt"], after)


class WaveIsolationReasonTest(unittest.TestCase):
    """S156: a wave the Schedule stage ISOLATED (a lone infrastructure-
    establishing ticket) carries an ADDITIVE `reason` in waves.json. The adapter
    must read that file exactly as before — the extra key changes no ticket row,
    no progress count, and never leaks into a ticket id."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    ISOLATED = [
        {"wave": 1,
         "reason": ("t-001 establishes shared build/test infrastructure "
                    "(vite.config) — isolated so later tickets build against it"),
         "tickets": [{"id": "t-001", "issue": 101}]},
        {"wave": 2, "tickets": [{"id": "t-012", "issue": 102}]},
    ]
    PLAN = [
        {"id": "t-001", "title": "Scaffold the app",
         "acceptanceCriteria": ["builds"], "dependencies": []},
        {"id": "t-012", "title": "Author the docs",
         "acceptanceCriteria": ["docs exist"], "dependencies": []},
    ]

    def _card(self, mid):
        for m in LocalAdapter(self.tmp).board()["missions"]:
            if m["id"] == mid:
                return m
        raise AssertionError("mission %s not in board" % mid)

    def _plant(self, mid="m-iso"):
        fx.plant_simple(self.tmp, mid, stage="implement", issue=42)
        d = fx.mission_dir(self.tmp, mid)
        fx.write_json(os.path.join(d, "plan.json"), self.PLAN)
        fx.write_json(os.path.join(d, "approved-plan.json"), self.PLAN)
        fx.write_json(os.path.join(d, "waves.json"), self.ISOLATED)
        fx.write_jsonl(os.path.join(d, "events.jsonl"), [
            {"ts": 100, "mission": mid, "stage": "implement",
             "type": "wave_start", "detail": "wave 1", "data": {"wave": 1}},
        ])
        return mid

    def test_ticket_rows_ignore_the_reason(self):
        mid = self._plant()
        card = self._card(mid)
        self.assertEqual([t["id"] for t in card["tickets"]], ["t-001", "t-012"])
        self.assertEqual([t["issue"] for t in card["tickets"]], [101, 102])

    def test_progress_counts_are_unchanged(self):
        mid = self._plant()
        card = self._card(mid)
        prog = card["progress"]
        self.assertEqual(prog["wavesTotal"], 2)
        self.assertEqual(prog["ticketsTotal"], 2)
        self.assertEqual(prog["wave"], 1)

    def test_reason_never_becomes_a_ticket(self):
        mid = self._plant()
        detail = LocalAdapter(self.tmp).mission(mid)
        blob = json.dumps(detail)
        self.assertNotIn("establishes shared", blob)


if __name__ == "__main__":
    unittest.main()
