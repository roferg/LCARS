"""S115 — collapsible per-wave / per-stage sections for the detail activity feed.

The long serial activity feed in the detail modal is grouped CLIENT-SIDE into
collapsible sections keyed by stage + wave. Completed sections collapse to one
LCARS summary band; the active (last/in-flight) section stays open; everything
is expandable, and an "expand all" affordance reveals every event.

Two layers of coverage:

  * A PURE helper `groupActivityIntoSections(acts)` (no DOM) — exercised for real
    by running the SHIPPING board.js in a node vm harness (there is no JS DOM
    harness in this repo; ADR-007 forbids a build step / npm). Grouping, counts,
    durations, flagged marker, active-section detection, small-mission passthrough
    and the nothing-lost invariant are asserted against real event streams.
  * String assertions on board.js proving the thin DOM wiring exists (collapsible
    bands, expand-all, per-event reuse) and that the CARD ticket strip is
    untouched.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "..", "static")
HARNESS = os.path.join(HERE, "board_sections_harness.js")
NODE = shutil.which("node")


def _big_gamify_events():
    """A 3-wave / 9-ticket Implement stream (wave 2 has a flagged ticket)."""
    evs = [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "implement starting"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
    ]
    ts = 1002
    plan = [
        # (wave_first?, ticket, flagged?)
        (False, "t-001", False), (False, "t-002", False), (False, "t-003", False),
        ("wave", "t-004", False), (False, "t-005", True), (False, "t-006", False),
        ("wave", "t-007", False), (False, "t-008", False), (False, "t-009", False),
    ]
    for marker, tid, flagged in plan:
        if marker == "wave":
            evs.append({"ts": ts, "stage": "implement", "type": "wave_start",
                        "detail": "wave"})
            ts += 1
        evs.append({"ts": ts, "stage": "implement", "type": "ticket_start",
                    "detail": "%s begin" % tid})
        ts += 5
        if flagged:
            evs.append({"ts": ts, "stage": "implement", "type": "ticket_flagged",
                        "detail": "%s attempt failed" % tid})
            ts += 3
        evs.append({"ts": ts, "stage": "implement", "type": "ticket_green",
                    "detail": "%s green" % tid})
        ts += 5
    evs.append({"ts": ts, "stage": "implement", "type": "stage_done",
                "detail": "implement complete"})
    return evs


def _small_events():
    """A single-wave Implement mission — nothing to collapse."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "start"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1010, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
    ]


def _multistage_events():
    """Research + Validate stage sections, then a single Implement wave."""
    return [
        {"ts": 1000, "stage": "research", "type": "stage_start", "detail": "research"},
        {"ts": 1005, "stage": "research", "type": "gate", "detail": "a question"},
        {"ts": 1010, "stage": "research", "type": "stage_done", "detail": "research done"},
        {"ts": 1020, "stage": "validate", "type": "stage_start", "detail": "validate"},
        {"ts": 1030, "stage": "validate", "type": "stage_done", "detail": "validate done"},
        {"ts": 1040, "stage": "implement", "type": "stage_start", "detail": "implement"},
        {"ts": 1041, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1042, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1050, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
    ]


def _run_harness(acts, mode=None):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(acts, f)
        path = f.name
    argv = [NODE, HARNESS, path] + ([mode] if mode else [])
    try:
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT)
    finally:
        os.unlink(path)
    return json.loads(out.decode("utf-8"))


@unittest.skipUnless(NODE, "node is required to exercise the pure JS helper")
class GroupActivityHelperTest(unittest.TestCase):
    def _group(self, acts):
        return _run_harness(acts)

    # (1) a 3-wave / 9-ticket mission → 3 sections, 2 collapsed + 1 open.
    def test_three_waves_three_sections_last_open(self):
        secs = self._group(_big_gamify_events())
        self.assertEqual(len(secs), 3, "one section per wave")
        self.assertTrue(all(s["kind"] == "wave" for s in secs))
        self.assertEqual([s["wave"] for s in secs], [1, 2, 3])
        # exactly the last section is active/open; the earlier two collapse.
        self.assertEqual([s["active"] for s in secs], [False, False, True])
        self.assertEqual(sum(1 for s in secs if not s["active"]), 2)
        # per-wave ticket counts (3 each → 9 total).
        self.assertEqual([s["ticketCount"] for s in secs], [3, 3, 3])
        self.assertEqual(sum(s["ticketCount"] for s in secs), 9)

    # (2) a flagged wave's band carries the flag marker; clean waves do not.
    def test_flagged_wave_marked(self):
        secs = self._group(_big_gamify_events())
        self.assertEqual([s["flagged"] for s in secs], [False, True, False])
        self.assertEqual(secs[1]["flaggedCount"], 1)

    # (3) NOTHING LOST — the union of every section's events equals the input,
    #     in order, with nothing dropped or duplicated. (expand-all in the DOM
    #     renders exactly these, one .evt each — see the wiring assertions.)
    def test_nothing_lost(self):
        acts = _big_gamify_events()
        secs = self._group(acts)
        regrouped = []
        for s in secs:
            regrouped.extend(s["events"])
        self.assertEqual(len(regrouped), len(acts))
        self.assertEqual([e["ts"] for e in regrouped], [e["ts"] for e in acts])
        self.assertEqual([e["type"] for e in regrouped], [e["type"] for e in acts])

    # (4) a small (1-wave) mission renders effectively as today: a single open
    #     section, so the DOM takes the flat passthrough branch.
    def test_small_mission_single_open_section(self):
        secs = self._group(_small_events())
        self.assertEqual(len(secs), 1)
        self.assertTrue(secs[0]["active"])
        # nothing lost here either.
        self.assertEqual(len(secs[0]["events"]), len(_small_events()))

    # durations derive from each section's first/last event ts.
    def test_section_durations(self):
        secs = self._group(_big_gamify_events())
        for s in secs:
            self.assertIsNotNone(s["durationSec"])
            self.assertGreater(s["durationSec"], 0)
        # wave 1 spans stage_start(1000) .. last ticket_green(1027).
        self.assertEqual(secs[0]["durationSec"], 27)

    # non-implement stages group under their STAGE; implement splits into waves.
    def test_multistage_grouping(self):
        secs = self._group(_multistage_events())
        kinds = [(s["kind"], s["stage"]) for s in secs]
        self.assertEqual(kinds, [
            ("stage", "research"),
            ("stage", "validate"),
            ("wave", "implement"),
        ])
        # the research gate event stays inside the research section (not lost).
        self.assertEqual(len(secs[0]["events"]), 3)
        self.assertTrue(secs[-1]["active"])

    def test_empty_stream(self):
        self.assertEqual(self._group([]), [])


def _one_ticket_wave():
    """A single-ticket, single-attempt wave (for the singular chip forms)."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1008, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
    ]


def _zero_attempt_wave():
    """A wave whose ticket has no outcome/hire yet → 0 sessions (chip omitted)."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
    ]


def _zero_ticket_wave():
    """A wave header with no tickets at all → no health bar."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
    ]


def _red_health_wave():
    """A 2-ticket wave: one green, one flagged-and-unresolved → 50/50 health bar."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1005, "stage": "implement", "type": "ticket_green", "detail": "t-001 green"},
        {"ts": 1006, "stage": "implement", "type": "ticket_start", "detail": "t-002"},
        {"ts": 1009, "stage": "implement", "type": "ticket_flagged", "detail": "t-002 flag"},
    ]


def _one_hire_clean_wave():
    """S173: ONE ticket, ONE hire, ZERO bounces — the clean case. The worker's
    own iteration count (7) rides `iterations` in the green event's data and
    must never reach a captain-facing chip."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001",
         "data": {"ticket": "t-001"}},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 1 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
        {"ts": 1008, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-001 green",
         "data": {"ticket": "t-001", "sessions": 1, "iterations": 7}},
    ]


def _two_hire_one_bounce_wave():
    """S173: ONE ticket, TWO hires, ONE gate bounce, green on the second hire."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001",
         "data": {"ticket": "t-001"}},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 1 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
        {"ts": 1004, "stage": "implement", "type": "ticket_gate_bounce",
         "detail": "ticket t-001 bounced by the flip-flop gate (FAIL) — session 1",
         "data": {"ticket": "t-001", "gate": "flip-flop", "attempt": 1}},
        {"ts": 1005, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 2 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 2}},
        {"ts": 1012, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-001 green after 2 worker sessions",
         "data": {"ticket": "t-001", "sessions": 2, "iterations": 3}},
    ]


def _mixed_vocabulary_stream():
    """S173 back-compat: ONE file holding PRE-S173 detail text (`green in 4
    attempt(s)`, data key `attempts`) alongside POST-S173 events. Nothing parses
    detail text, so both must tally identically off the event TYPE."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        # --- old (pre-S173) ticket, old wording, old data key ---
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001"},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 1 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
        {"ts": 1004, "stage": "implement", "type": "ticket_gate_bounce",
         "detail": "ticket t-001 bounced by the quality-floor gate (FAIL) — session 1",
         "data": {"ticket": "t-001", "gate": "quality-floor", "attempt": 1}},
        {"ts": 1005, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 2 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 2}},
        {"ts": 1006, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-001 green in 4 attempt(s)",
         "data": {"ticket": "t-001", "attempts": 4}},
        # --- new (post-S173) ticket in the SAME file ---
        {"ts": 1007, "stage": "implement", "type": "ticket_start", "detail": "t-002"},
        {"ts": 1008, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 3 for t-002",
         "data": {"ticket": "t-002", "phase": "tdd", "attempt": 1}},
        {"ts": 1009, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-002 green",
         "data": {"ticket": "t-002", "sessions": 1, "iterations": 2}},
    ]


def _pre_s133_standoff_wave():
    """S173 FIX ROUND: the PRE-S133 adversarial-standoff shape, still on disk in
    every historical mission — ticket_attempt events carrying phase=test-writer /
    phase=implementer, each numbered PER PHASE, so the max `attempt` VALUE (1)
    under-counts the TWO real worker dispatches."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-007",
         "data": {"ticket": "t-007"}},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "test-writer try 1 for t-007",
         "data": {"ticket": "t-007", "phase": "test-writer", "attempt": 1}},
        {"ts": 1004, "stage": "implement", "type": "ticket_attempt",
         "detail": "implementer try 1 for t-007",
         "data": {"ticket": "t-007", "phase": "implementer", "attempt": 1}},
        {"ts": 1010, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-007 green in 3 attempt(s)",
         "data": {"ticket": "t-007", "attempts": 3}},
    ]


def _gapped_index_wave():
    """S173 FIX ROUND: a stream with a GAP in the attempt indices (1, then 3).
    The event COUNT is 2; the max `attempt` VALUE is 3. Proves the two
    derivations are NOT equivalent, and that the board counts events."""
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "s"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001",
         "data": {"ticket": "t-001"}},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 1 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
        {"ts": 1005, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 3 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 3}},
        {"ts": 1010, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-001 green after 2 worker sessions",
         "data": {"ticket": "t-001", "sessions": 2, "iterations": 4}},
    ]


def _resumed_wave_three_hires_two_bounces():
    """S173 FIX ROUND 2 (N1) — the EXACT measured shape: one ticket taking THREE
    hires and TWO bounces, with a real re-entry (`stage_start`) after hire 2.

    `wave_start` is durably deduped against events.jsonl, but `stage_start` is
    NOT, so every respond→run resume / manual retry / auto-advance re-run of
    Implement appends a second `stage_start` — and the board opens a NEW section
    on one. The wave's hires therefore SPLIT across two sections, and the wave
    band used to count only the two that happened to sit above the split while
    run.sh's ticket_hire_count(), comment-mirror's cm_ticket_sessions() and the
    Verify roll-up all said 3.

    The sectioning itself is NOT changed (the captain's ruling): the timeline
    still visibly splits here. Only the NUMBER on the band changes.
    """
    return [
        {"ts": 1000, "stage": "implement", "type": "stage_start", "detail": "implement starting"},
        {"ts": 1001, "stage": "implement", "type": "wave_start", "detail": "wave 1"},
        {"ts": 1002, "stage": "implement", "type": "ticket_start", "detail": "t-001",
         "data": {"ticket": "t-001", "wave": 1}},
        {"ts": 1003, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 1 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 1}},
        {"ts": 1004, "stage": "implement", "type": "ticket_gate_bounce",
         "detail": "ticket t-001 bounced by the flip-flop gate (FAIL) \u2014 session 1",
         "data": {"ticket": "t-001", "gate": "flip-flop", "attempt": 1}},
        {"ts": 1005, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 2 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 2}},
        {"ts": 1006, "stage": "implement", "type": "ticket_gate_bounce",
         "detail": "ticket t-001 bounced by the declared-edits gate (FAIL) \u2014 session 2",
         "data": {"ticket": "t-001", "gate": "declared-edits", "attempt": 2}},
        # ── THE RE-ENTRY. A fresh `lcars run` after a respond; no wave_start
        #    (that one IS deduped), so the board opens a new STAGE section here.
        {"ts": 1007, "stage": "implement", "type": "stage_start", "detail": "implement resuming"},
        {"ts": 1008, "stage": "implement", "type": "ticket_attempt",
         "detail": "tdd session 3 for t-001",
         "data": {"ticket": "t-001", "phase": "tdd", "attempt": 3}},
        {"ts": 1012, "stage": "implement", "type": "ticket_green",
         "detail": "ticket t-001 green after 3 worker sessions",
         "data": {"ticket": "t-001", "sessions": 3, "iterations": 5}},
    ]


def _hired_gamify_events():
    """_big_gamify_events, but with a real HIRE RECORD: one ticket_attempt per
    ticket, plus a SECOND for wave 1's t-002 and wave 2's flagged t-005 — so
    waves 1 and 2 carry a hire count > 1 and therefore wear the session chip."""
    out = []
    for ev in _big_gamify_events():
        out.append(ev)
        if ev["type"] == "ticket_start":
            tid = ev["detail"].split()[0]
            n = 2 if tid in ("t-002", "t-005") else 1
            for i in range(1, n + 1):
                out.append({"ts": ev["ts"], "stage": "implement",
                            "type": "ticket_attempt",
                            "detail": "tdd session %d for %s" % (i, tid),
                            "data": {"ticket": tid, "phase": "tdd", "attempt": i}})
    return out


@unittest.skipUnless(NODE, "node is required to exercise the pure JS helper")
class HireDerivationTest(unittest.TestCase):
    """S173 FIX ROUND (D2 + D5) — ONE derivation rule for the hire count:
    the NUMBER of ticket_attempt events for the section, ANY phase. Zero
    ticket_attempt events means the hire count is UNKNOWN — the chip is omitted
    and outcomes are NEVER substituted for hires."""

    def _chips(self, acts):
        return _run_harness(acts, mode="chips")

    def test_any_phase_ticket_attempt_counts_as_a_hire(self):
        # pre-S133 standoff: two dispatches, each numbered `attempt: 1`.
        sec = self._chips(_pre_s133_standoff_wave())[0]
        self.assertEqual(sec["sessionCount"], 2)
        self.assertIn("↻ 2 worker sessions", sec["chipTexts"])

    def test_gapped_indices_count_events_not_the_max_value(self):
        # indices 1 and 3 → TWO events. The max VALUE (3) must not be shown.
        sec = self._chips(_gapped_index_wave())[0]
        self.assertEqual(sec["sessionCount"], 2)
        self.assertIn("↻ 2 worker sessions", sec["chipTexts"])
        self.assertNotIn("↻ 3 worker sessions", sec["chipTexts"])

    def test_zero_ticket_attempt_stream_reports_an_UNKNOWN_hire_count(self):
        # THE FABRICATION: (greens + flaggeds) used to be rendered under the
        # word "sessions". A count nobody counted is not a hire count.
        secs = self._chips(_big_gamify_events())
        for sec in secs:
            self.assertIsNone(sec["sessionCount"],
                              "no ticket_attempt ⇒ hires are UNKNOWN, not derived")
            self.assertNotIn("chip-sessions", " ".join(sec["chipClasses"]))
            blob = " ".join(sec["chipTexts"])
            self.assertNotIn("↻", blob)
            self.assertNotIn("NaN", blob)
            self.assertNotIn("undefined", blob)
            self.assertNotIn("null", blob)

    def test_a_clean_wave_never_wears_a_fabricated_counter(self):
        # 3 tickets, all green first try, NO ticket_attempt events → the round's
        # own contradiction: "↻ 3 sessions" on a wave where nothing was re-hired.
        secs = self._chips(_big_gamify_events())
        self.assertEqual(secs[0]["greenCount"], 3)
        self.assertNotIn("3 session", " ".join(secs[0]["chipTexts"]))
        self.assertNotIn("3 worker session", " ".join(secs[0]["chipTexts"]))


@unittest.skipUnless(NODE, "node is required to exercise headlineFor")
class EventHeadlineVocabularyTest(unittest.TestCase):
    """S173 FIX ROUND (D1) — no captain-facing event HEADLINE says "attempt", on
    ANY stream. `Worker session N` whenever the wire carries an index, whatever
    the phase; a phase-neutral label otherwise."""

    def _heads(self, acts):
        return _run_harness(acts, mode="headlines")

    def test_pre_s133_phase_events_read_as_worker_sessions(self):
        heads = self._heads(_pre_s133_standoff_wave())["headlines"]
        self.assertIn("Worker session 1", heads)
        for h in heads:
            self.assertNotIn("attempt", h.lower(), h)

    def test_indexless_ticket_attempt_gets_a_phase_neutral_label(self):
        out = self._heads([{"ts": 1, "stage": "implement", "type": "ticket_attempt",
                            "detail": "d", "data": {}}])
        self.assertEqual(out["headlines"], ["Worker session"])

    def test_no_event_head_in_the_whole_map_says_attempt(self):
        out = self._heads([])
        for k, v in out["heads"].items():
            self.assertNotIn("attempt", str(v).lower(), "%s → %s" % (k, v))

    def test_every_headline_of_every_fixture_stream_is_attempt_free(self):
        for acts in (_pre_s133_standoff_wave(), _mixed_vocabulary_stream(),
                     _two_hire_one_bounce_wave(), _big_gamify_events()):
            for h in self._heads(acts)["headlines"]:
                self.assertNotIn("attempt", h.lower(), h)


@unittest.skipUnless(NODE, "node is required to exercise the chip DOM builders")
class HireAndBounceChipsTest(unittest.TestCase):
    """S173 — the board shows the number that GOVERNS (hires) and the signal that
    something went wrong (gate bounces), and never the worker's own iteration
    count. `attempt` is retired from every captain-facing chip."""

    def _chips(self, acts):
        return _run_harness(acts, mode="chips")

    def _classes(self, sec):
        return " ".join(sec["chipClasses"])

    def test_clean_wave_wears_no_session_and_no_bounce_chip(self):
        sec = self._chips(_one_hire_clean_wave())[0]
        # PRESENCE first — the chip cluster was really built for this wave.
        self.assertIn("chip-tickets", self._classes(sec))
        self.assertIn("⬢ 1 ticket", sec["chipTexts"])
        # …and then the two counters are absent, because nothing went wrong.
        self.assertNotIn("chip-sessions", self._classes(sec))
        self.assertNotIn("chip-bounces", self._classes(sec))
        self.assertEqual(sec["sessionCount"], 1)
        self.assertEqual(sec["bounceCount"], 0)

    def test_bounced_wave_wears_both_chips_with_their_text(self):
        sec = self._chips(_two_hire_one_bounce_wave())[0]
        cls = self._classes(sec)
        self.assertIn("chip-sessions", cls)
        self.assertIn("chip-bounces", cls)
        self.assertIn("↻ 2 worker sessions", sec["chipTexts"])
        self.assertIn("⤫ 1 bounce", sec["chipTexts"])
        self.assertEqual(sec["sessionCount"], 2)
        self.assertEqual(sec["bounceCount"], 1)

    def test_clean_and_bounced_waves_are_distinguishable_at_a_glance(self):
        clean = self._chips(_one_hire_clean_wave())[0]
        bounced = self._chips(_two_hire_one_bounce_wave())[0]
        self.assertNotEqual(clean["chipClasses"], bounced["chipClasses"])
        self.assertNotEqual(clean["chipTexts"], bounced["chipTexts"])

    def test_no_chip_ever_says_attempt(self):
        for acts in (_one_hire_clean_wave(), _two_hire_one_bounce_wave(),
                     _big_gamify_events(), _mixed_vocabulary_stream()):
            for sec in self._chips(acts):
                blob = " ".join(sec["chipTexts"] + sec["chipClasses"]).lower()
                self.assertNotIn("attempt", blob, blob)

    def test_worker_iteration_count_never_reaches_a_chip(self):
        # the green event carries iterations=7; no chip may quote it.
        sec = self._chips(_one_hire_clean_wave())[0]
        self.assertNotIn("7", " ".join(sec["chipTexts"]))

    def test_pre_s134_stream_still_renders_a_sane_band(self):
        # S173 FIX ROUND retarget (was: `sessionCount == 3` / "↻ 3 sessions",
        # the greens+flaggeds fallback rendered under the word "sessions"). No
        # ticket_attempt events means the hire count is UNKNOWN: the band still
        # renders every OTHER chip, and simply stays silent about hires.
        secs = self._chips(_big_gamify_events())
        for sec in secs:
            self.assertIsNone(sec["sessionCount"])
            self.assertIsInstance(sec["bounceCount"], int)
            self.assertNotIn("NaN", " ".join(sec["chipTexts"]))
            self.assertNotIn("undefined", " ".join(sec["chipTexts"]))
        # the band is still a band — tickets and duration read normally.
        self.assertIn("⬢ 3 tickets", secs[0]["chipTexts"])
        self.assertIn("chip-duration", " ".join(secs[0]["chipClasses"]))
        self.assertNotIn("chip-sessions", " ".join(secs[0]["chipClasses"]))

    def test_mixed_old_and_new_stream_counts_off_event_type_only(self):
        secs = self._chips(_mixed_vocabulary_stream())
        sec = secs[0]
        # 3 ticket_attempt events (2 old-ticket + 1 new-ticket) and 1 bounce —
        # counted off TYPE, not off the detail text, which disagrees on purpose.
        self.assertEqual(sec["sessionCount"], 3)
        self.assertEqual(sec["bounceCount"], 1)
        self.assertIn("↻ 3 worker sessions", sec["chipTexts"])
        self.assertIn("⤫ 1 bounce", sec["chipTexts"])
        self.assertEqual(sec["ticketCount"], 2)
        self.assertEqual(sec["greenCount"], 2)

    def test_bounce_chip_plural(self):
        acts = _two_hire_one_bounce_wave()
        acts.insert(-1, {"ts": 1010, "stage": "implement", "type": "ticket_gate_bounce",
                         "detail": "ticket t-001 bounced by the declared-edits gate (FAIL) — session 2",
                         "data": {"ticket": "t-001", "gate": "declared-edits", "attempt": 2}})
        sec = self._chips(acts)[0]
        self.assertIn("⤫ 2 bounces", sec["chipTexts"])


class BoardJsVocabularyTest(unittest.TestCase):
    """S173 — `attempt` is retired from board.js's captain-facing strings and from
    the derived-count field names, while the event TYPE keeps its name."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_derived_fields_renamed(self):
        self.assertIn("sessionCount", self.js)
        self.assertIn("bounceCount", self.js)
        self.assertNotIn("attemptCount", self.js)

    def test_no_outcome_fallback_survives(self):
        # S173 FIX ROUND (D5): (greens + flaggeds) may never stand in for hires.
        self.assertNotIn("_outcomes", self.js)

    def test_the_counter_noun_is_worker_session_not_a_bare_session(self):
        # SOURCE-STRING REGRESSION GUARD (not a cure proof — it holds on both
        # sides of the fix). It pins the NOUN only: the pre-S173 chip said
        # "sessions" with no qualifier. What the chip actually RENDERS is proved
        # behaviourally by HireAndBounceChipsTest / SessionChipSilenceTest.
        self.assertNotIn('" sessions"', self.js)
        self.assertIn('" worker session"', self.js)

    def test_event_type_name_is_unchanged(self):
        # the WIRE does not change — only the display.
        self.assertIn('case "ticket_attempt":', self.js)
        self.assertIn('"ticket_gate_bounce"', self.js)


@unittest.skipUnless(NODE, "node is required to exercise the chip DOM builders")
class SectionChipsTest(unittest.TestCase):
    """VISUAL POLISH: the graphic stat chips + wave-health micro-bar produced by
    the SHIPPING board.js (sectionSummaryChips / sectionHealthBar)."""

    def _chips(self, acts):
        return _run_harness(acts, mode="chips")

    def _classes(self, sec):
        return " ".join(sec["chipClasses"])

    def test_wave_chip_classes_present(self):
        # S173 FIX ROUND retarget: the session chip exists only where hires were
        # RECORDED, so this uses the hire-bearing variant of the same stream.
        secs = self._chips(_hired_gamify_events())
        cls0 = self._classes(secs[0])
        # a wave band gets ticket + worker-session + duration chips.
        self.assertIn("chip-tickets", cls0)
        self.assertIn("chip-sessions", cls0)
        self.assertIn("chip-duration", cls0)
        # clean wave 1 → sessions NOT flagged-tinted; flagged wave 2 → flagged.
        self.assertNotIn("flagged", self._classes(secs[0]))
        self.assertIn("chip-sessions flagged", self._classes(secs[1]))

    def test_plural_and_singular(self):
        secs = self._chips(_big_gamify_events())
        self.assertEqual(secs[0]["chipTexts"][0], "⬢ 3 tickets")  # plural
        one = self._chips(_one_ticket_wave())
        self.assertEqual(one[0]["chipTexts"][0], "⬢ 1 ticket")     # singular
        # S173 retarget (was: `assertIn("↻ 1 attempt", ...)`). The counter that
        # governs is the HIRE count, and a wave where nothing had to be re-hired
        # wears no counter at all — so 1 is SILENT and >1 is spelled out.
        self.assertNotIn("chip-sessions", self._classes(one[0]))
        # …and >1 is spelled out, on a stream that actually recorded its hires.
        hired = self._chips(_hired_gamify_events())
        self.assertIn("↻ 4 worker sessions", hired[0]["chipTexts"])

    def test_zero_attempts_chip_omitted(self):
        secs = self._chips(_zero_attempt_wave())
        self.assertIn("chip-tickets", self._classes(secs[0]))
        self.assertNotIn("chip-sessions", self._classes(secs[0]))

    def test_stage_chip_status(self):
        secs = self._chips(_multistage_events())
        # research + validate are STAGE sections → a status chip (not tickets).
        self.assertIn("chip-status", self._classes(secs[0]))
        self.assertNotIn("chip-tickets", self._classes(secs[0]))
        # a completed (non-active) stage reads "✓ complete".
        self.assertIn("✓ complete", secs[0]["chipTexts"])
        # a stream ending on an OPEN stage → its last chip reads "in progress".
        active_stage = self._chips([
            {"ts": 1000, "stage": "research", "type": "stage_start", "detail": "r"},
            {"ts": 1010, "stage": "research", "type": "stage_done", "detail": "r done"},
            {"ts": 1020, "stage": "validate", "type": "stage_start", "detail": "v"},
        ])
        self.assertIn("chip-status active", self._classes(active_stage[-1]))
        self.assertIn("in progress", active_stage[-1]["chipTexts"])

    def test_health_bar_wave_only(self):
        # a wave with tickets → a health bar; a stage / zero-ticket wave → none.
        wave = self._chips(_big_gamify_events())
        self.assertIsNotNone(wave[0]["healthBar"])
        self.assertIn("band-health", wave[0]["healthBar"])
        multi = self._chips(_multistage_events())
        self.assertIsNone(multi[0]["healthBar"])  # research STAGE section
        self.assertIsNone(self._chips(_zero_ticket_wave())[0]["healthBar"])

    def test_health_bar_proportions(self):
        secs = self._chips(_red_health_wave())
        self.assertEqual(secs[0]["healthGreen"], "50%")
        self.assertEqual(secs[0]["healthRed"], "50%")

    def test_flagged_badge_class(self):
        # a flagged wave still emits the band-flag badge (built in sectionNode);
        # the chip cluster carries the flagged-tinted worker-sessions chip.
        # S173 FIX ROUND retarget: the session chip exists only where hires were
        # RECORDED, so the flagged-tint assertion moves to the hire-bearing
        # variant of the same stream. The flagged MARKER itself is unchanged and
        # is still asserted on the original (hire-free) stream.
        self.assertTrue(self._chips(_big_gamify_events())[1]["flagged"])
        secs = self._chips(_hired_gamify_events())
        self.assertTrue(secs[1]["flagged"])
        self.assertIn("chip-sessions flagged", self._classes(secs[1]))


class BoardJsWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_helper_defined(self):
        self.assertIn("function groupActivityIntoSections", self.js)

    def test_feed_uses_sections(self):
        # the feed builds sections and, for >1 section, renders collapsible bands.
        self.assertIn("groupActivityIntoSections", self.js)
        self.assertIn("feed-section", self.js)
        self.assertIn("feed-band", self.js)

    def test_expand_all_affordance(self):
        self.assertIn("feed-expand", self.js)
        # a case-insensitive nod to the "expand all" label.
        self.assertIn("Expand all", self.js)

    def test_small_mission_passthrough_branch(self):
        # a single (or zero) section still renders the flat feed — no band chrome.
        self.assertIn("sections.length <= 1", self.js)

    def test_per_event_render_reused(self):
        # the per-event .evt block is factored into a helper reused inside bands
        # AND the flat passthrough, so no event is rendered by only one path.
        self.assertIn("function renderEvent", self.js)

    def test_linked_bugs_collapse(self):
        # the mission-log parent's linked-bug list gets the same band idiom.
        self.assertIn("function linkedBugsSection", self.js)
        self.assertIn("linkedBugsSection(kids)", self.js)

    def test_chip_and_health_builders_defined(self):
        # VISUAL POLISH: the graphic stat-chip + health-bar builders exist and the
        # band renders them (the run-together band-summary text is superseded).
        self.assertIn("function sectionSummaryChips", self.js)
        self.assertIn("function sectionHealthBar", self.js)
        self.assertIn("band-chips", self.js)
        self.assertIn("band-health", self.js)
        self.assertIn("sectionSummaryChips(sec)", self.js)
        self.assertIn("sectionHealthBar(sec)", self.js)


class BoardCssMotionTest(unittest.TestCase):
    """VISUAL POLISH: every new animation MUST sit inside a
    prefers-reduced-motion:no-preference block (reduced-motion → static)."""
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.css"), encoding="utf-8") as f:
            cls.css = f.read()

    def test_chip_and_health_styles_present(self):
        for sel in (".band-chip", ".band-chip.chip-tickets", ".band-chip.chip-sessions",
                    ".band-chip.chip-sessions.flagged", ".band-chip.chip-bounces",
                    ".band-chip.chip-duration",
                    ".band-chip.chip-status", ".band-health"):
            self.assertIn(sel, self.css, sel)

    def test_animations_gated_on_no_preference(self):
        marker = "@media (prefers-reduced-motion:no-preference){"
        self.assertIn(marker, self.css)
        block = self.css.split(marker, 1)[1]
        # close the block at the matching brace depth so we test only its contents.
        depth, end = 1, 0
        for i, ch in enumerate(block):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        inner = block[:end]
        # each new keyframe animation must live INSIDE the no-preference block.
        for kf in ("band-flag-pulse", "band-dot-pulse", "band-active-glow",
                   "band-events-in"):
            self.assertIn(kf, inner, kf + " must be gated on no-preference")
        # and NOT leak outside it (no bare animation on these selectors elsewhere).
        outside = self.css.replace(inner, "")
        self.assertNotIn("band-flag-pulse", outside)


class CardsUntouchedTest(unittest.TestCase):
    """The card ticket strip (CARD_TICKET_CAP / cardTickets) is DETAIL-only work's
    off-limits neighbour — assert it is byte-stable at the contract points."""
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(STATIC, "board.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_card_ticket_cap_unchanged(self):
        self.assertIn("var CARD_TICKET_CAP = 3;", self.js)

    def test_card_tickets_present(self):
        self.assertIn("function cardTickets(tickets)", self.js)
        self.assertIn('tk.appendChild(ticketMore("and " + hiddenAfter + " more…"));', self.js)


@unittest.skipUnless(NODE, "node is required to exercise the pure JS helper")
class ResumeSplitHireCountTest(unittest.TestCase):
    """S173 FIX ROUND 2 (N1) — a wave band's hire/bounce counters are PER TICKET
    OVER THE WHOLE STREAM, matching run.sh's ticket_hire_count(), the comment
    mirror and the Verify roll-up. A `stage_start` re-entry still SPLITS the
    timeline (the sectioning is deliberately untouched) — it no longer splits
    the NUMBER."""

    def _chips(self, acts):
        return _run_harness(acts, mode="chips")

    def _wave(self, secs):
        waves = [s for s in secs if s["kind"] == "wave"]
        self.assertTrue(waves, "the fixture must produce a wave band")
        return waves[0]

    def test_the_resume_still_splits_the_timeline(self):
        # The captain's ruling: do NOT restructure the grouping. Two sections is
        # the ACCEPTED shape here, and this test pins it so a later round cannot
        # quietly "fix" it by merging sections instead.
        secs = self._chips(_resumed_wave_three_hires_two_bounces())
        self.assertEqual(len(secs), 2, "stage_start still opens a second section")
        self.assertEqual([s["kind"] for s in secs], ["wave", "stage"])

    def test_wave_band_counts_all_three_hires_across_the_split(self):
        wave = self._wave(self._chips(_resumed_wave_three_hires_two_bounces()))
        self.assertEqual(wave["sessionCount"], 3)
        self.assertIn("\u21bb 3 worker sessions", wave["chipTexts"])
        self.assertNotIn("\u21bb 2 worker sessions", wave["chipTexts"])

    def test_wave_band_counts_all_bounces_across_the_split(self):
        # The bounce counter had the SAME per-section scope bug; it is cured on
        # the same rule. (Both bounces happen to sit above the split in this
        # fixture, so the next test moves one below it.)
        wave = self._wave(self._chips(_resumed_wave_three_hires_two_bounces()))
        self.assertEqual(wave["bounceCount"], 2)
        self.assertIn("\u292b 2 bounces", wave["chipTexts"])

    def test_a_bounce_below_the_split_still_reaches_the_wave_band(self):
        acts = _resumed_wave_three_hires_two_bounces()
        # move the SECOND bounce below the re-entry: the wave band must still
        # report 2, because it counts its tickets' bounces wherever they sit.
        second = [e for e in acts if e["type"] == "ticket_gate_bounce"][1]
        acts.remove(second)
        acts.insert(acts.index([e for e in acts if e["type"] == "ticket_green"][0]), second)
        wave = self._wave(self._chips(acts))
        self.assertEqual(wave["bounceCount"], 2)
        self.assertEqual(wave["sessionCount"], 3)

    def test_a_ticket_with_no_hire_events_anywhere_stays_silent(self):
        # the zero-events rule survives the whole-stream widening: no
        # ticket_attempt anywhere ⇒ UNKNOWN ⇒ null ⇒ no chip, nothing invented.
        acts = [e for e in _resumed_wave_three_hires_two_bounces()
                if e["type"] != "ticket_attempt"]
        wave = self._wave(self._chips(acts))
        self.assertIsNone(wave["sessionCount"])
        self.assertNotIn("chip-sessions", " ".join(wave["chipClasses"]))

    def test_an_unsplit_wave_is_unchanged(self):
        # the widening must not double-count the ordinary (single-section) case.
        sec = self._chips(_two_hire_one_bounce_wave())[0]
        self.assertEqual(sec["sessionCount"], 2)
        self.assertEqual(sec["bounceCount"], 1)


@unittest.skipUnless(NODE, "node is required to exercise headlineFor")
class HeadlineIndexAgreesWithTheBandTest(unittest.TestCase):
    """S173 FIX ROUND 2 (N2) — a `Worker session N` headline can never contradict
    the hire chip above it. The COUNT comes from the ticket's ticket_attempt
    events; the INDEX now comes from the SAME sequence (1st, 2nd, 3rd for that
    ticket) instead of off the wire, where on historical streams the two series
    are unrelated."""

    def _heads(self, acts):
        return _run_harness(acts, mode="headlines")["headlines"]

    def _session_heads(self, acts):
        return [h for h in self._heads(acts) if h.startswith("Worker session")]

    def test_pre_s133_two_phase_dispatches_are_numbered_1_then_2(self):
        # BOTH events carry attempt=1 on the wire; the band says 2 hires, so the
        # headlines must read 1 and 2 — never "Worker session 1" twice.
        heads = self._session_heads(_pre_s133_standoff_wave())
        self.assertEqual(heads, ["Worker session 1", "Worker session 2"])

    def test_gapped_wire_indices_are_renumbered_to_the_hire_sequence(self):
        # wire indices 1 and 3, chip says 2 hires → headlines 1 and 2.
        heads = self._session_heads(_gapped_index_wave())
        self.assertEqual(heads, ["Worker session 1", "Worker session 2"])

    def test_no_headline_index_exceeds_the_bands_hire_count(self):
        for acts in (_pre_s133_standoff_wave(), _gapped_index_wave(),
                     _mixed_vocabulary_stream(), _two_hire_one_bounce_wave(),
                     _resumed_wave_three_hires_two_bounces(),
                     _hired_gamify_events()):
            secs = _run_harness(acts, mode="chips")
            cap = max([s["sessionCount"] or 0 for s in secs] + [0])
            for h in self._session_heads(acts):
                bits = h.split()
                if len(bits) == 3:
                    self.assertLessEqual(int(bits[2]), cap, "%s > %d" % (h, cap))

    def test_headline_indexes_are_per_ticket_not_per_stream(self):
        # two tickets in one wave: each restarts at 1 (the count is per ticket).
        heads = self._session_heads(_mixed_vocabulary_stream())
        self.assertEqual(heads, ["Worker session 1", "Worker session 2",
                                 "Worker session 1"])

    def test_the_index_survives_a_stage_start_re_entry(self):
        heads = self._session_heads(_resumed_wave_three_hires_two_bounces())
        self.assertEqual(heads, ["Worker session 1", "Worker session 2",
                                 "Worker session 3"])

    def test_still_no_headline_says_attempt(self):
        for acts in (_pre_s133_standoff_wave(), _gapped_index_wave(),
                     _resumed_wave_three_hires_two_bounces()):
            for h in self._heads(acts):
                self.assertNotIn("attempt", h.lower(), h)


@unittest.skipUnless(NODE, "node is required to exercise the chip DOM builders")
class SessionChipSilenceTest(unittest.TestCase):
    """S173 FIX ROUND 2 (N4) — what the hire chip ACTUALLY does, rendered, not
    grepped out of the source.

    The old `test_session_chip_pluralises_off_the_count` claimed the chip
    "pluralises off the count" while only grepping board.js for a string, and
    the claim was false either way: the chip is gated `sessionCount > 1`, so the
    singular "1 worker session" is UNREACHABLE BY DESIGN — that is the round's
    silence-at-one rule (a wave where nothing had to be re-hired wears no
    counter at all), not an accident to be fixed by adding a rendering path.

    So this proves the true invariant instead: SILENT at 0 and 1, PLURAL at 2+,
    and the singular form never renders on any stream.

    This is a BEHAVIOURAL CHARACTERISATION, not a cure proof — the behaviour is
    the same before and after fix round 2. It replaces a test that proved
    nothing with one that proves what is true."""

    def _chips(self, acts):
        return _run_harness(acts, mode="chips")

    def _texts(self, sec):
        return " ".join(sec["chipTexts"])

    def test_unknown_hire_count_renders_no_counter(self):
        for sec in self._chips(_big_gamify_events()):     # no ticket_attempt at all
            self.assertIsNone(sec["sessionCount"])
            self.assertNotIn("worker session", self._texts(sec))

    def test_exactly_one_hire_renders_no_counter(self):
        sec = self._chips(_one_hire_clean_wave())[0]
        self.assertEqual(sec["sessionCount"], 1)
        self.assertNotIn("worker session", self._texts(sec))

    def test_two_hires_render_the_plural_counter(self):
        sec = self._chips(_two_hire_one_bounce_wave())[0]
        self.assertEqual(sec["sessionCount"], 2)
        self.assertIn("\u21bb 2 worker sessions", sec["chipTexts"])

    def test_the_singular_form_never_renders_on_any_stream(self):
        for acts in (_one_hire_clean_wave(), _two_hire_one_bounce_wave(),
                     _zero_attempt_wave(), _big_gamify_events(),
                     _hired_gamify_events(), _mixed_vocabulary_stream(),
                     _pre_s133_standoff_wave(), _gapped_index_wave(),
                     _resumed_wave_three_hires_two_bounces()):
            for sec in self._chips(acts):
                self.assertNotIn("1 worker session", self._texts(sec))

    def test_the_bounce_chip_by_contrast_does_pluralise_off_its_count(self):
        # the bounce chip is gated at > 0, so BOTH of its forms are reachable —
        # which is why the pluralisation claim belongs here and not on hires.
        one = self._chips(_two_hire_one_bounce_wave())[0]
        self.assertIn("\u292b 1 bounce", one["chipTexts"])
        two = self._chips(_resumed_wave_three_hires_two_bounces())
        wave = [s for s in two if s["kind"] == "wave"][0]
        self.assertIn("\u292b 2 bounces", wave["chipTexts"])


if __name__ == "__main__":
    unittest.main()
