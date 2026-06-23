"""GITHUB adapter — maps a stubbed `gh` issues+labels payload to the SAME board
shape the LOCAL adapter produces (ADR-003 behavior 4).

The adapter shells out to `$LCARS_GH_BIN` exactly like comment-mirror.sh does;
the test stubs that binary with a script that echoes a canned `gh issue list
--json …` payload, so NO network / real gh is touched. The assertion is shape
PARITY: same keys, same column placement, same gate rule, same pills.
"""
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve.board import STAGES  # noqa: E402
from lcars_serve.github_adapter import GitHubAdapter  # noqa: E402


# A canned `gh issue list … --json …` payload: two missions + ticket sub-issues.
#
# The "## Estimate" bodies use the EXACT format render_estimate_issue() emits in
# skills/lcars-run/run.sh (the source of truth): a single `**Criticality:**`
# line with `reasoning = LEVEL · implementation = LEVEL` (UPPERCASE level, `=`
# separator, `·` middot), then the per-stage model table, then
# `**Estimated cost:** $low–$high`. The parser MUST track that real rendering.
PAYLOAD = [
    {
        "number": 142,
        "title": "Add Gamification to Course Site",
        "state": "OPEN",
        "labels": [{"name": "lcars:mission"}, {"name": "lcars:implement"},
                   {"name": "lcars:feature"}],
        "body": ("PRD body…\n\n---\n\n## Estimate\n\n"
                 "**Criticality:** reasoning = MEDIUM · implementation = HIGH\n\n"
                 "**Per-stage model mix:**\n\n"
                 "| Stage | Model |\n| --- | --- |\n| Research | Opus |\n"
                 "| Implement | Opus |\n\n"
                 "**Estimated cost:** $4.20–$6.40\n\n"
                 "Touches a sensitive boundary.\n"),
    },
    {
        "number": 143,
        "title": "Gated mission",
        "state": "OPEN",
        "labels": [{"name": "lcars:mission"}, {"name": "lcars:research"},
                   {"name": "lcars:awaiting-human"}, {"name": "lcars:feature"}],
        "body": ("PRD…\n\n## Estimate\n\n"
                 "**Criticality:** reasoning = LOW · implementation = LOW\n\n"
                 "**Estimated cost:** $1.00–$2.00\n"),
        # the pending gate question is mirrored as a comment body (S65)
        "comments": [{"body": "AWAITING YOU — Question: Global vs per-course?"}],
    },
    {
        "number": 201,
        "title": "t-001 XP model",
        "state": "OPEN",
        "labels": [{"name": "lcars:ticket"}, {"name": "lcars:implement"}],
        "body": "Parent: #142",
    },
    {
        "number": 202,
        "title": "t-002 Badge model",
        "state": "OPEN",
        "labels": [{"name": "lcars:ticket"}, {"name": "lcars:implement"}],
        "body": "Parent: #142",
    },
]


def _write_stub(path, payload):
    script = (
        "#!/usr/bin/env bash\n"
        "# fake gh: echo the canned issue-list payload for the --json read.\n"
        "cat <<'JSON'\n"
        + json.dumps(payload)
        + "\nJSON\n"
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class GitHubAdapterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.stub = os.path.join(self.tmp, "gh")
        _write_stub(self.stub, PAYLOAD)

    def _board(self):
        return GitHubAdapter(gh_bin=self.stub).board()

    def _by_id(self, board, key):
        for m in board["missions"]:
            if m["id"] == key:
                return m
        raise AssertionError("mission %s not in board" % key)

    def test_shape_matches_board_contract(self):
        board = self._board()
        self.assertEqual(board["stages"], list(STAGES))
        self.assertEqual(set(board["columns"].keys()), set(STAGES))
        # a mission card carries the same keys the local adapter emits.
        m = self._by_id(board, "142")
        for k in ("id", "issue", "title", "stage", "awaiting", "paused",
                  "question", "pills", "progress", "tickets"):
            self.assertIn(k, m)
        # S73: queued is adapter-neutral — present and False on github (ADR-006).
        self.assertIn("queued", m)
        self.assertFalse(m["queued"])
        # UX-28: parentMission is adapter-neutral — present and None on github
        # (read from the child's local state.json the github adapter can't see).
        self.assertIn("parentMission", m)
        self.assertIsNone(m["parentMission"])
        # S76: reconcileStatus is adapter-neutral — present and None on github
        # (the main-ahead reconcile sub-state lives in the child's local
        # state.json the github read-path can't see; ADR-006).
        self.assertIn("reconcileStatus", m)
        self.assertIsNone(m["reconcileStatus"])
        # BUG-067: reconcileNote / reconcileMergeSha are adapter-neutral too —
        # present and None on the github read-path (live in the local state.json).
        self.assertIn("reconcileNote", m)
        self.assertIsNone(m["reconcileNote"])
        self.assertIn("reconcileMergeSha", m)
        self.assertIsNone(m["reconcileMergeSha"])

    def test_mission_placed_by_stage_label(self):
        board = self._board()
        self.assertEqual([m["issue"] for m in board["columns"]["implement"]], [142])

    def test_gated_mission_in_inflight_column_not_align(self):
        board = self._board()
        self.assertEqual(board["columns"]["align"], [])
        col = board["columns"]["research"]
        self.assertEqual([m["issue"] for m in col], [143])
        self.assertTrue(col[0]["awaiting"])

    def test_pills_parsed_from_estimate_section(self):
        m = self._by_id(self._board(), "142")
        self.assertEqual(m["pills"]["reasoning"]["level"], "medium")
        self.assertEqual(m["pills"]["implementation"]["level"], "high")
        self.assertIsNotNone(m["pills"]["cost"])

    def test_both_difficulty_pills_from_real_rendered_body(self):
        """Regression (S67 fix-loop r1, DEFECT 1): the github adapter MUST parse
        the EXACT `**Criticality:** reasoning = X · implementation = Y` line that
        render_estimate_issue() emits — not a fabricated bullet form. Before the
        fix both pills came back None on every card."""
        board = self._board()
        m142 = self._by_id(board, "142")
        self.assertIsNotNone(m142["pills"]["reasoning"],
                             "reasoning pill must not be None on real body")
        self.assertIsNotNone(m142["pills"]["implementation"],
                             "implementation pill must not be None on real body")
        self.assertEqual(m142["pills"]["reasoning"]["level"], "medium")
        self.assertEqual(m142["pills"]["implementation"]["level"], "high")
        # case-robust: 143 uses UPPERCASE LOW in the rendered body.
        m143 = self._by_id(board, "143")
        self.assertEqual(m143["pills"]["reasoning"]["level"], "low")
        self.assertEqual(m143["pills"]["implementation"]["level"], "low")

    def test_adapter_parity_pills_match_local(self):
        """ADR-003 / S67 acceptance #4: the github adapter and the local adapter
        MUST produce the SAME pill set for the SAME mission. We render mission
        142's estimate two ways — through the github body parser and through the
        local adapter's pills_from_estimate — and assert they agree."""
        from lcars_serve.board import pills_from_estimate
        m = self._by_id(self._board(), "142")
        # The same estimator output that produced 142's rendered issue body.
        local = pills_from_estimate({
            "reasoningCriticality": "medium",
            "implCriticality": "high",
            "cost": {"cli": "claude", "unit": "usd", "currency": "USD",
                     "usd": {"low": 4.2, "high": 6.4}},
        })
        self.assertEqual(m["pills"]["reasoning"]["level"],
                         local["reasoning"]["level"])
        self.assertEqual(m["pills"]["implementation"]["level"],
                         local["implementation"]["level"])
        self.assertEqual(m["pills"]["cost"]["unit"], local["cost"]["unit"])

    def test_tickets_nested_under_parent(self):
        m = self._by_id(self._board(), "142")
        self.assertIn(201, [t["issue"] for t in m["tickets"]])

    # ── S70-A: board-level meta on the github adapter ──
    def test_board_meta_repo_and_adapter(self):
        board = GitHubAdapter(gh_bin=self.stub, repo="roferg/lcars-sandbox").board()
        self.assertIn("meta", board)
        self.assertEqual(board["meta"]["repo"], "roferg/lcars-sandbox")
        self.assertEqual(board["meta"]["adapter"], "github")
        # the github adapter is always view-only (no write layer)
        self.assertEqual(board["meta"]["mode"], "read-only")

    # ── S70-B1: model mix parsed from the issue body's table (else None) ──
    def test_model_mix_from_estimate_section_table(self):
        m = self._by_id(self._board(), "142")
        self.assertIsNotNone(m["modelMix"])
        rows = {r["stage"]: r for r in m["modelMix"]}
        self.assertEqual(rows["Research"]["tier"], "opus")
        self.assertEqual(rows["Implement"]["tier"], "opus")

    def test_model_mix_none_when_no_table(self):
        # mission 143's body has an Estimate section but NO model-mix table.
        m = self._by_id(self._board(), "143")
        self.assertIsNone(m["modelMix"])

    # ── S74 follow-up CHANGE 3 (adapter parity): a logged BUG (lcars:bug /
    # lcars:linked) skips Research+Validate, so those rows are dropped from its
    # model-mix table even when the issue body's table still lists all six. ──
    def test_bug_mission_mix_omits_research_and_validate(self):
        payload = [{
            "number": 150, "title": "Bug: leaderboard off-by-one", "state": "OPEN",
            "labels": [{"name": "lcars:mission"}, {"name": "lcars:plan"},
                       {"name": "lcars:bug"}, {"name": "lcars:linked"}],
            "body": ("Bug PRD…\n\n## Estimate\n\n"
                     "**Per-stage model mix:**\n\n"
                     "| Stage | Model |\n| --- | --- |\n"
                     "| Research | Opus |\n| Validate | Opus |\n| Plan | Opus |\n"
                     "| Plan Review | Sonnet |\n| Implement | Opus |\n"
                     "| Verify | Sonnet |\n\n"
                     "**Estimated cost:** $1.00–$2.00\n"),
        }]
        _write_stub(self.stub, payload)
        m = self._by_id(self._board(), "150")
        stages = [r["stage"] for r in m["modelMix"]]
        self.assertEqual(stages, ["Plan", "Plan Review", "Implement", "Verify"])
        self.assertNotIn("Research", stages)
        self.assertNotIn("Validate", stages)

    # ── S70-B2/B3: ADRs + criteria are null on the github adapter (not in body) ──
    def test_detail_adrs_and_criteria_null_safe(self):
        detail = GitHubAdapter(gh_bin=self.stub).mission("142")
        self.assertIn("adrs", detail)
        self.assertIn("criteria", detail)
        self.assertIsNone(detail["adrs"])
        self.assertIsNone(detail["criteria"])

    def test_card_carries_modelmix_key(self):
        # parity: every card must carry the modelMix key (value may be None).
        m = self._by_id(self._board(), "143")
        self.assertIn("modelMix", m)

    def test_done_in_done_column_but_not_active(self):
        """S67 fix-loop r2, DEFECT 2: a `lcars:done` mission belongs in the Done
        COLUMN with its normal card fields, but stays OUT of the active
        `missions` list so the active count is unaffected. Mirrors the local
        adapter's behaviour for adapter parity."""
        payload = [{"number": 9, "title": "Shipped", "state": "OPEN",
                    "labels": [{"name": "lcars:mission"}, {"name": "lcars:done"}],
                    "body": ""}]
        _write_stub(self.stub, payload)
        board = self._board()
        # done mission renders as a card in the Done column…
        done_col = board["columns"]["done"]
        self.assertEqual([m["issue"] for m in done_col], [9])
        self.assertEqual(done_col[0]["stage"], "done")
        self.assertEqual(done_col[0]["title"], "Shipped")
        self.assertIn("pills", done_col[0])
        # …but is not part of the active mission count.
        self.assertEqual(board["missions"], [])

    def test_done_card_parity_with_local(self):
        """ADR-003: the github and local adapters must produce the SAME done
        card shape for the SAME done mission (issue, title, stage, card keys)."""
        import tempfile
        from lcars_serve.local_adapter import LocalAdapter
        # github side
        payload = [{"number": 9, "title": "Shipped", "state": "OPEN",
                    "labels": [{"name": "lcars:mission"}, {"name": "lcars:done"}],
                    "body": ""}]
        _write_stub(self.stub, payload)
        gh_done = self._board()["columns"]["done"][0]
        # local side: an equivalent done mission on disk
        from tests import _fixtures as fx
        tmp = tempfile.mkdtemp()
        fx.plant_simple(tmp, "m-done", stage="done", issue=9, title="Shipped",
                        estimate=None)
        local_done = LocalAdapter(tmp).board()["columns"]["done"][0]
        for k in ("issue", "title", "stage"):
            self.assertEqual(gh_done[k], local_done[k],
                             "done card field %r differs across adapters" % k)
        self.assertEqual(set(gh_done) & {"id", "issue", "title", "stage",
                                         "awaiting", "paused", "pills", "tickets"},
                         set(local_done) & {"id", "issue", "title", "stage",
                                            "awaiting", "paused", "pills", "tickets"})


if __name__ == "__main__":
    unittest.main()
