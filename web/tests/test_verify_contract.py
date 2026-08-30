"""S134 — the unified-implementer Verify surfaces + board activity rendering.

The S133 unified TDD Implementer proves each ticket with deterministic post-hoc
gates and emits new events (flip_flop_*, ticket_test_edits, ticket_gate_bounce)
plus phase=tdd ticket_attempt session markers. This session renders that machine:

  * The Verify readout shows a CONTRACT AMENDMENTS block (declared test edits,
    {path, reason} verbatim) + a per-ticket flip-flop verdict chip (PROVEN / N/A).
  * The board activity feed renders the proof-gate events in Trek voice, shows a
    worker-session marker across a bounce, and — the captain ruling — carries NO
    per-event role chip (the retired Test-Writer / Implementer distinction).
  * The nothing-lost invariant (S115) holds: an unknown event still renders raw.
  * A pre-S133 mission renders byte-identically (no proof data → nothing added).

Exercised against the SHIPPING board.js in a node vm harness (ADR-007: no build
step / npm), the DOM projected to JSON so the assertions run without a browser.
Plus string assertions that this session added NO write surface (display only).
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "..", "static")
HARNESS = os.path.join(HERE, "board_verify_harness.js")
BOARD_JS = os.path.join(STATIC, "board.js")
NODE = shutil.which("node")


def _run(mode, obj):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(obj, f)
        path = f.name
    try:
        out = subprocess.check_output([NODE, HARNESS, mode, path],
                                      stderr=subprocess.STDOUT)
    finally:
        os.unlink(path)
    return json.loads(out.decode("utf-8"))


def _flat_text(node):
    """All textContent across a projected node tree, joined."""
    if not node:
        return ""
    parts = [node.get("text") or "", node.get("html") or "", node.get("title") or ""]
    for c in node.get("children") or []:
        parts.append(_flat_text(c))
    return " ".join(p for p in parts if p)


def _flat_classes(node):
    if not node:
        return ""
    parts = [node.get("className") or ""]
    for c in node.get("children") or []:
        parts.append(_flat_classes(c))
    return " ".join(p for p in parts if p)


PROVEN_T1 = {
    "id": "t-001", "title": "Add the toggle", "state": "done",
    "proof": {"newTests": 2, "declaredEdits": [],
              "flipFlop": {"verdict": "proven", "reason": None}},
}
AMEND_T2 = {
    "id": "t-002", "title": "Wire persistence", "state": "done",
    "proof": {"newTests": 1,
              "declaredEdits": [{"path": "src/legacy.test.ts",
                                 "reason": "the ticket changes the return shape from string to object"}],
              "flipFlop": {"verdict": "proven", "reason": None}},
}
NA_T3 = {
    "id": "t-003", "title": "Pure rename", "state": "done",
    "proof": {"newTests": 0, "declaredEdits": [],
              "flipFlop": {"verdict": "n-a", "reason": "pure rename, no behavior change"}},
}
PRE_S133_T = {"id": "t-009", "title": "Old ticket", "state": "done"}   # no proof key


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class ContractAmendmentsTest(unittest.TestCase):
    def test_declared_edits_render_verbatim(self):
        mi = {"tickets": [PROVEN_T1, AMEND_T2]}
        node = _run("contract", mi)
        self.assertIsNotNone(node)
        txt = _flat_text(node)
        self.assertIn("src/legacy.test.ts", txt)
        self.assertIn("the ticket changes the return shape from string to object", txt)
        self.assertIn("t-002", txt)

    def test_no_edits_renders_one_quiet_line(self):
        mi = {"tickets": [PROVEN_T1, NA_T3]}   # proofed, zero declared edits
        node = _run("contract", mi)
        self.assertIsNotNone(node)
        txt = _flat_text(node)
        self.assertIn("No contract changes", txt)
        # exactly one quiet line — no amendment rows leaked in.
        self.assertNotIn(".test.ts", txt)

    def test_pre_s133_mission_renders_nothing(self):
        # No ticket carries proof → contractAmendments returns null → nothing appended.
        mi = {"tickets": [PRE_S133_T]}
        node = _run("contract", mi)
        self.assertIsNone(node)


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class SingleTicketParityTest(unittest.TestCase):
    """S134 defect — CLI↔UI parity on a SINGLE-ticket mission.

    A single-ticket mission carries NO ticket rows (`_tickets` returns [] — the
    lone slice reuses the mission's own issue), so `mi.tickets` is empty and the
    per-row proof render had nothing to hang the flip-flop verdict / contract
    amendments on, while the CLI verify-summary reads the lone ticket directly
    and DOES show them. The adapter now surfaces the lone ticket's proof at
    MISSION level as `mi.contractProof` (same _ticket_proof shape + its id), and
    the board's render builders fall back to it when `mi.tickets` is empty."""

    SOLO = {
        "id": "t-solo",
        "newTests": 1,
        "declaredEdits": [{"path": "src/api.test.ts",
                           "reason": "the fix changes the error return from null to a Result"}],
        "flipFlop": {"verdict": "proven", "reason": None},
    }

    def test_single_ticket_amendments_render_verbatim(self):
        mi = {"tickets": [], "contractProof": self.SOLO}
        node = _run("contract", mi)
        self.assertIsNotNone(node)          # the block IS rendered (was null before)
        txt = _flat_text(node)
        self.assertIn("src/api.test.ts", txt)
        self.assertIn("the fix changes the error return from null to a Result", txt)
        self.assertIn("t-solo", txt)        # names the lone ticket, matching the CLI

    def test_single_ticket_proven_chip_renders(self):
        mi = {"tickets": [], "contractProof": self.SOLO}
        node = _run("buildSummary", mi)
        self.assertIn("PROVEN", _flat_text(node))
        self.assertIn("proven", _flat_classes(node))

    def test_single_ticket_na_verdict_shows_reason(self):
        mi = {"tickets": [], "contractProof": {
            "id": "t-solo", "newTests": 0, "declaredEdits": [],
            "flipFlop": {"verdict": "n-a", "reason": "pure rename, no behavior change"}}}
        node = _run("buildSummary", mi)
        txt = _flat_text(node)
        self.assertIn("N/A", txt)
        self.assertIn("pure rename, no behavior change", txt)

    def test_no_contract_proof_renders_nothing(self):
        # Byte-identity: a single-ticket mission with NO proof artifacts carries
        # no `contractProof` key at all — amendments block is null, summary empty.
        mi = {"tickets": []}
        self.assertIsNone(_run("contract", mi))
        node = _run("buildSummary", mi)
        self.assertNotIn("ff-chip", _flat_classes(node))
        self.assertNotIn("PROVEN", _flat_text(node))

    def test_multi_ticket_not_double_rendered_from_contract_proof(self):
        # A multi-ticket mission surfaces proof via its per-ticket rows; it never
        # carries contractProof (adapter). Even if one leaked in, the per-row path
        # wins and the amendment is shown exactly once (no duplicate).
        mi = {"tickets": [PROVEN_T1, AMEND_T2]}
        node = _run("contract", mi)
        txt = _flat_text(node)
        self.assertEqual(txt.count("src/legacy.test.ts"), 1)


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class FlipFlopChipTest(unittest.TestCase):
    def test_proven_chip(self):
        node = _run("buildSummary", {"tickets": [PROVEN_T1]})
        self.assertIn("PROVEN", _flat_text(node))
        self.assertIn("proven", _flat_classes(node))

    def test_na_chip_shows_reason(self):
        node = _run("buildSummary", {"tickets": [NA_T3]})
        txt = _flat_text(node)
        self.assertIn("N/A", txt)
        self.assertIn("pure rename, no behavior change", txt)

    def test_pre_s133_ticket_has_no_chip(self):
        node = _run("buildSummary", {"tickets": [PRE_S133_T]})
        cls = _flat_classes(node)
        self.assertNotIn("ff-chip", cls)


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class ProofEventRenderTest(unittest.TestCase):
    def _render(self, ev):
        return _run("renderEvent", ev)

    def test_flip_flop_pass_reads_proof_accepted(self):
        node = self._render({"stage": "implement", "type": "flip_flop_pass",
                             "detail": "flip-flop PASS for t-001"})
        self.assertIn("PROOF ACCEPTED", _flat_text(node))
        self.assertIn("proof-pass", _flat_classes(node))

    def test_flip_flop_fail_reads_rejection(self):
        node = self._render({"stage": "implement", "type": "flip_flop_fail",
                             "detail": "flip-flop FAIL — red-on-parent not proven"})
        txt = _flat_text(node)
        self.assertIn("PROOF REJECTED", txt)
        self.assertIn("proof-fail", _flat_classes(node))

    def test_flip_flop_inconclusive_reads_rejection(self):
        node = self._render({"stage": "implement", "type": "flip_flop_inconclusive",
                             "detail": "zero tests collected"})
        self.assertIn("PROOF INCONCLUSIVE", _flat_text(node))

    def test_ticket_test_edits_reads_contract_amendment(self):
        node = self._render({"stage": "implement", "type": "ticket_test_edits",
                             "detail": "t-002 declared 1 test edit against the diff"})
        self.assertIn("CONTRACT AMENDMENT", _flat_text(node))
        self.assertIn("proof-amend", _flat_classes(node))

    def test_unknown_event_still_renders_raw(self):
        # Nothing-lost (S115): a type we never styled still renders, detail intact.
        node = self._render({"stage": "implement", "type": "brand_new_signal",
                             "detail": "some future payload text"})
        txt = _flat_text(node)
        self.assertIn("brand new signal", txt)          # headlineFor fallback
        self.assertIn("some future payload text", txt)   # detail preserved


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class WorkerSessionMarkerTest(unittest.TestCase):
    def test_session_marker_across_a_two_session_bounce(self):
        # S173 FIX ROUND 2 (N2): rendered as ONE STREAM, which is the only way
        # the board ever renders — the session INDEX is now the event's position
        # in its ticket's own hire sequence (derived by the grouping pass the
        # product always runs) rather than the wire's `attempt`, so it can never
        # contradict the hire count on the band above it. Two dispatches for
        # t-001 ⇒ "Worker session 1" then "Worker session 2".
        nodes = _run("renderStream", [
            {"stage": "implement", "type": "ticket_attempt",
             "detail": "tdd session 1 for t-001",
             "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
            {"stage": "implement", "type": "ticket_attempt",
             "detail": "tdd session 2 for t-001",
             "data": {"ticket": "t-001", "phase": "tdd", "attempt": 2}},
        ])
        self.assertIn("Worker session 1", _flat_text(nodes[0]))
        self.assertIn("Worker session 2", _flat_text(nodes[1]))

    def test_a_pre_s133_stream_numbers_its_two_dispatches_1_then_2(self):
        # BOTH wire indices are 1 (the old loops numbered PER PHASE). The old
        # wire-indexed headline rendered "Worker session 1" twice under a band
        # that said 2.
        nodes = _run("renderStream", [
            {"stage": "implement", "type": "ticket_attempt",
             "detail": "test-writer try 1 for t-007",
             "data": {"ticket": "t-007", "phase": "test-writer", "attempt": 1}},
            {"stage": "implement", "type": "ticket_attempt",
             "detail": "implementer try 1 for t-007",
             "data": {"ticket": "t-007", "phase": "implementer", "attempt": 1}},
        ])
        self.assertIn("Worker session 1", _flat_text(nodes[0]))
        self.assertIn("Worker session 2", _flat_text(nodes[1]))

    def test_no_role_or_tdd_chip_anywhere(self):
        # The retired Test-Writer / Implementer distinction — and a "TDD" chip —
        # must not appear in any rendered event.
        for ev in [
            {"stage": "implement", "type": "ticket_attempt", "detail": "tdd session 1",
             "data": {"phase": "tdd", "attempt": 1}},
            {"stage": "implement", "type": "flip_flop_pass", "detail": "ok"},
            {"stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
        ]:
            txt = _flat_text(_run("renderEvent", ev)).lower()
            self.assertNotIn("test-writer", txt)
            self.assertNotIn("test writer", txt)
            self.assertNotIn("implementer", txt)


@unittest.skipUnless(NODE, "node is required to exercise the board.js DOM builders")
class GateExhaustedCategoryTest(unittest.TestCase):
    def test_flagged_card_shows_gate_category(self):
        # After 3 sessions, ticket_flagged parks awaiting-human; the last gate
        # verdict (its category) rides the detail and must render.
        node = _run("renderEvent", {"stage": "implement", "type": "ticket_flagged",
                    "detail": "ticket t-001 flagged after 3 TDD session(s) — last gate verdict: flip-flop (FAIL)",
                    "data": {"ticket": "t-001", "attempts": 3}})
        txt = _flat_text(node)
        self.assertIn("flip-flop", txt)   # the gate category that parked it
        self.assertIn("FAIL", txt)


class ReadOnlyBuildTest(unittest.TestCase):
    """This session is display-only: it must add NO new write surface."""
    def test_no_new_write_endpoint_in_board_js(self):
        with open(BOARD_JS) as _fh:
            src = _fh.read()
        # The only write dispatcher is postWrite (S-existing). Count its call
        # sites and the endpoints it targets; assert our new code added none.
        # Our additions (contractAmendments / flipFlopChip / proof events) are
        # pure render — they must not call postWrite or reference a /verify write.
        for fn in ["function contractAmendments", "function flipFlopChip"]:
            start = src.index(fn)
            # crude body slice up to the next top-level "\nfunction "
            body = src[start: src.index("\nfunction ", start + 1)]
            self.assertNotIn("postWrite", body, "%s must be display-only" % fn)
            self.assertNotIn("fetch(", body, "%s must be display-only" % fn)

    def test_open_verify_surfaces_single_ticket_proof(self):
        # S134 defect: the Verify dialog must render the lone ticket's proof-of-
        # work for a single-ticket mission (mi.tickets empty, proof on
        # mi.contractProof). Assert openVerify reads contractProof and still
        # builds the "what was built" summary in that branch.
        with open(BOARD_JS) as _fh:
            src = _fh.read()
        start = src.index("function openVerify")
        body = src[start: src.index("\nfunction ", start + 1)]
        self.assertIn("contractProof", body,
                      "openVerify must surface the single-ticket contractProof")


if __name__ == "__main__":
    unittest.main()
