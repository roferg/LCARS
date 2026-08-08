"""Park & Align (S137 · BUG-1/2/3) — the mission DETAIL modal + START-ALIGNMENT
busy-guard, plus the Verify-only Mission Log gate.

Runs the SHIPPING web/static/board.js in a node vm (ADR-007: no DOM, no build) via
board_detail_harness.js, which drives the real renderDetail / cardNode / align-console
builders and projects the produced DOM (and any /api/* POSTs) to JSON. Asserts:

  * BUG-1 — a PARKED (prdPending) mission's detail header renders "▹ START ALIGNMENT"
    and NEVER the runnable "▶ Start"; a normal aligned mission still shows "▶ Start".
  * BUG-2 — Mission Log renders ONLY at stage verify (excluding logged-bug children);
    it is absent for align/parked/research/validate/plan/implement/done.
  * BUG-3 — with isAligning(id) true the card control AND the detail header render a
    DISABLED "⊹ Scanning…" affordance, never a clickable START ALIGNMENT.
  * BUG-3 — dismissing the align CONSOLE (closeOverlay) fires POST /api/align/<sid>/
    cancel to reap the warm session.
  * BUG-3 — closing an UNRELATED overlay (e.g. the detail modal) during the in-flight
    START-ALIGNMENT POST does NOT abort the scan: isAligning stays set and the console
    still opens when the worker turn returns.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_detail_harness.js")
NODE = shutil.which("node")


def _flatten(node, acc=None):
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


def _run(mission, mode="detail", extra=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(mission, fh)
    try:
        argv = [NODE, HARNESS, path, mode]
        if extra:
            argv.append(extra)
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def _texts(mission, mode="detail", extra=None):
    res = _run(mission, mode, extra)
    return res, [n.get("text", "") for n in _flatten(res.get("overlay"))]


_BASE = {
    "issue": 9, "title": "X", "type": "feature", "engine": "claude",
    "pills": {"cost": {"label": "$1"}, "reasoning": {"level": "low", "label": "R"},
              "implementation": {"level": "low", "label": "I"}},
    "awaiting": False, "paused": False, "running": False, "queued": False,
    "dispatched": False, "tickets": [], "activity": [],
}


def _mission(**over):
    m = dict(_BASE)
    m.update(over)
    return m


PARKED = _mission(id="m-park", stage="align", prdPending=True,
                  pills={"cost": None, "reasoning": None, "implementation": None})
ALIGNED = _mission(id="m-align", stage="align")
# S128/FL-009 (the reload half): a parked card as a FRESHLY-LOADED tab receives
# it — the daemon's in-flight align fact on the payload, and nothing at all in
# the client's ALIGNING map, because this tab never saw the click.
SCANNING_ON_SERVER = _mission(
    id="m-park", stage="align", prdPending=True,
    pills={"cost": None, "reasoning": None, "implementation": None},
    alignBusy={"since": 1754500000.0, "for": 95.4})
# S169/FL-017 (the reload half of the FINALIZE): the same shape for the window
# after the grill closes, while the estimator and `file.sh --complete` run.
FINALIZING_ON_SERVER = _mission(
    id="m-park", stage="align", prdPending=True,
    pills={"cost": None, "reasoning": None, "implementation": None},
    alignFinalizing={"since": 1754500000.0, "for": 218.0})


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ParkDetailRenderTest(unittest.TestCase):
    # ── BUG-1: detail header primary action ────────────────────────────────
    def test_parked_detail_shows_start_alignment_not_start(self):
        _, texts = _texts(PARKED)
        joined = " || ".join(texts).upper()
        self.assertIn("START ALIGNMENT", joined,
                      "a parked mission's detail must offer START ALIGNMENT")
        self.assertNotIn("▶ Start", texts,
                         "a parked mission is never runnable — no ▶ Start")

    def test_normal_align_detail_shows_start(self):
        _, texts = _texts(ALIGNED)
        self.assertIn("▶ Start", texts,
                      "a non-parked align mission still Starts a run")
        self.assertNotIn("START ALIGNMENT", " || ".join(texts).upper())

    # ── BUG-2: Mission Log is Verify-only ──────────────────────────────────
    def test_mission_log_only_at_verify(self):
        for stage in ("align", "research", "validate", "plan", "implement", "done"):
            _, texts = _texts(_mission(id="m-" + stage, stage=stage))
            self.assertNotIn("Mission Log", texts,
                             "Mission Log must be hidden at stage " + stage)
        _, vtexts = _texts(_mission(id="m-verify", stage="verify"))
        self.assertIn("Mission Log", vtexts,
                      "Mission Log must show at Verify")

    def test_mission_log_hidden_for_parked(self):
        _, texts = _texts(PARKED)
        self.assertNotIn("Mission Log", texts,
                         "a parked (align) mission must not show Mission Log")

    # ── a parked mission's detail shows AWAITING ALIGNMENT, not a fake PRD ──
    def test_parked_detail_hides_prd_shows_awaiting_alignment(self):
        _, texts = _texts(PARKED)
        joined = " || ".join(texts)
        self.assertIn("AWAITING ALIGNMENT", joined.upper(),
                      "a parked mission's detail must show the awaiting-alignment panel")
        self.assertNotIn("Acceptance criteria", joined,
                         "no PRD acceptance-criteria section before the grill runs")
        self.assertNotIn("works end to end", joined,
                         "no placeholder acceptance criterion before alignment")

    def test_aligned_detail_still_shows_prd(self):
        _, texts = _texts(ALIGNED)
        self.assertIn("Acceptance criteria", " || ".join(texts),
                      "a non-parked mission still shows its PRD acceptance criteria")

    def test_mission_log_hidden_for_logged_bug_child_even_at_verify(self):
        bug = _mission(id="m-bug", stage="verify", type="bug", parentMission="m-1")
        _, texts = _texts(bug)
        self.assertNotIn("Mission Log", texts,
                         "a logged-bug child never shows Mission Log")

    # ── BUG-3: aligning busy-guard (card + detail) ─────────────────────────
    def test_detail_aligning_renders_disabled_scanning(self):
        res, texts = _texts(PARKED, mode="detail-aligning")
        joined = " || ".join(texts)
        self.assertIn("Scanning", joined, "detail must show the ⊹ Scanning… guard")
        self.assertNotIn("START ALIGNMENT", joined.upper(),
                         "while aligning, no clickable START ALIGNMENT")
        scanning = [n for n in _flatten(res.get("overlay"))
                    if "Scanning" in n.get("text", "")]
        self.assertTrue(scanning and all(n["disabled"] for n in scanning),
                        "the ⊹ Scanning… affordance must be disabled")

    def test_card_aligning_renders_disabled_scanning_button(self):
        res = _run(PARKED, mode="card-aligning")
        buttons = [n for n in _flatten(res.get("overlay")) if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertNotIn("START ALIGNMENT", btexts,
                         "while aligning, the card offers no clickable START ALIGNMENT")
        scan_btns = [n for n in buttons if "SCANNING" in n.get("text", "").upper()]
        self.assertTrue(scan_btns and all(n["disabled"] for n in scan_btns),
                        "the card's ⊹ Scanning… control button must be disabled")

    # ── FIX-A: the persistent animated scanning band on the card ───────────
    def test_card_aligning_shows_persistent_running_band(self):
        res = _run(PARKED, mode="card-aligning")
        bands = [n for n in _flatten(res.get("overlay"))
                 if "lcars-running" in n.get("cls", "")]
        self.assertTrue(bands,
                        "an aligning card must render the persistent .lcars-running "
                        "scanning band (survives repaints)")

    def test_card_not_aligning_has_no_scanning_band(self):
        res = _run(PARKED, mode="card")
        bands = [n for n in _flatten(res.get("overlay"))
                 if "lcars-running" in n.get("cls", "")]
        self.assertFalse(bands,
                         "a parked card not mid-scan shows no scanning band")

    # ── closing an UNRELATED overlay mid-scan must NOT abort the alignment ──
    def test_close_during_scan_keeps_alignment_alive(self):
        # The captain's repro: open a card, click START ALIGNMENT, close the
        # detail modal — the scan must survive (the click-guard already prevents
        # duplicate spawns, so there is nothing to supersede).
        res = _run(PARKED, mode="cancel-during-scan")
        self.assertEqual(res["aligning"], True,
                         "dismissing an unrelated overlay during the in-flight open "
                         "must NOT cancel the scan — isAligning stays set")

    def test_close_during_scan_still_opens_console(self):
        res = _run(PARKED, mode="stale-open")
        self.assertEqual(res["opened"], 1,
                         "the console must still open after an unrelated close — the "
                         "captain clicked START ALIGNMENT; honor it")
        self.assertNotIn("/api/align/sid-stale/cancel", res["fetches"],
                         "an unrelated close must NOT reap the in-flight session")

    # ── S128 / FL-009: a SLOW turn is not a FAILED turn ────────────────────
    #
    # Measured on the S127 capstone (2026-08-06): the captain's opening Align
    # turn ran 61s; board.js's 60s safety timeout fired at 60s, cleared the
    # guard and refresh()ed, so the card re-armed to START ALIGNMENT one second
    # before the turn returned. Success was presented as failure, and the
    # re-click spawned a SECOND real worker (free on copilot, billed on claude).
    #
    # The cure is not a bigger constant — a bigger constant is the same guess
    # with a longer fuse, and every holodeck hand-off (28KB mockup + concept doc
    # + ~5s of MCP spawn) sits on the threshold. The guard's lifetime is now the
    # REQUEST's lifetime: it ends when the turn settles — a fact — and no timer
    # may end it early.
    def test_slow_turn_keeps_the_scan_armed_past_the_safety_timeout(self):
        res = _run(PARKED, mode="scan-outlives-timeout")
        self.assertEqual(res["aligning"], True,
                         "FL-009: a turn still in flight must stay 'scanning' — no "
                         "wall-clock timer may re-arm START ALIGNMENT under it")

    def test_slow_turn_card_still_reads_as_scanning(self):
        res = _run(PARKED, mode="scan-outlives-timeout")
        nodes = _flatten(res.get("cardMidFlight"))
        buttons = [n for n in nodes if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertIn("SCANNING", btexts,
                      "the card must still show the disabled Scanning affordance")
        self.assertNotIn("START ALIGNMENT", btexts,
                         "FL-009: a re-armed START ALIGNMENT here is the defect — it "
                         "invites a second worker on a turn that is still running")
        scanning = [n for n in buttons if "Scanning" in n.get("text", "")]
        self.assertTrue(scanning and all(n["disabled"] for n in scanning),
                        "the Scanning affordance must stay disabled")
        bands = [n for n in nodes if "lcars-running" in n.get("cls", "")]
        self.assertTrue(bands, "the persistent scanning band must survive too")

    def test_slow_turn_discloses_how_long_it_has_been_scanning(self):
        # The harness back-dates the click by 95s. Silence is what made this
        # frightening ("something is shaky") — the card must say how long the
        # turn has been running instead of just insisting it is busy.
        res = _run(PARKED, mode="scan-outlives-timeout")
        joined = " || ".join(n.get("text", "")
                             for n in _flatten(res.get("cardMidFlight")))
        self.assertIn("1m 35s", joined,
                      "an in-flight scan must disclose its elapsed time, so a long "
                      "turn reads as SLOW rather than as broken")

    # ── S128 / FL-009, the RELOAD half: the daemon's fact, not this tab's ──
    #
    # Everything above is CLIENT MEMORY (the ALIGNING map). Reload the board
    # mid-scan and it is gone, and the card re-arms to START ALIGNMENT on a turn
    # that is still running — the same lie, through a different door, and the
    # re-click still spawns a second real worker.
    #
    # These fixtures carry `alignBusy` and NOTHING in the ALIGNING map: exactly a
    # freshly-loaded tab reading GET /api/board. The card must read the daemon.
    def test_a_reloaded_card_still_reads_as_scanning(self):
        res = _run(SCANNING_ON_SERVER, mode="card")
        buttons = [n for n in _flatten(res.get("overlay"))
                   if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertNotIn("START ALIGNMENT", btexts,
                         "FL-009 (reload): a tab that never saw the click must not "
                         "re-arm START ALIGNMENT under a running turn")
        scan = [n for n in buttons if "SCANNING" in n.get("text", "").upper()]
        self.assertTrue(scan and all(n["disabled"] for n in scan),
                        "it must show the same DISABLED ⊹ Scanning… control")

    def test_a_reloaded_card_shows_the_daemons_elapsed_time(self):
        # 95s on the wire → the same "1m 35s" the clicking tab renders from its
        # own memory. ONE wording, two sources for the same number.
        res = _run(SCANNING_ON_SERVER, mode="card")
        joined = " || ".join(n.get("text", "")
                             for n in _flatten(res.get("overlay")))
        self.assertIn("1m 35s", joined,
                      "the elapsed time comes from the daemon — the only surface "
                      "that knows when a turn a reloaded tab never saw began")

    def test_a_reloaded_card_keeps_the_scanning_band(self):
        res = _run(SCANNING_ON_SERVER, mode="card")
        bands = [n for n in _flatten(res.get("overlay"))
                 if "lcars-running" in n.get("cls", "")]
        self.assertTrue(bands, "and the persistent animated band with it")

    def test_a_reloaded_detail_mirrors_the_card(self):
        _, texts = _texts(SCANNING_ON_SERVER, mode="detail")
        joined = " || ".join(texts)
        self.assertIn("Scanning", joined)
        self.assertIn("1m 35s", joined)
        self.assertNotIn("START ALIGNMENT", joined.upper(),
                         "the detail modal must not offer what the card refuses")

    def test_the_daemons_fact_outranks_this_tabs_silence(self):
        # The disagreement case that matters: this tab's POST already came back
        # (or never happened) while the daemon says the turn is STILL RUNNING —
        # a proxy timeout, a second tab, a reload. The daemon wins; it is the
        # only one that can see the worker. (The reverse — client memory with no
        # published fact — is the plain in-flight case the tests above cover, and
        # an absent key is NOT evidence the turn died, so it never clears the
        # guard. Only the POST settling does that.)
        res = _run(SCANNING_ON_SERVER, mode="card")
        buttons = [n for n in _flatten(res.get("overlay"))
                   if n.get("tag") == "button"]
        self.assertTrue([n for n in buttons
                         if "SCANNING" in n.get("text", "").upper()])

    def test_a_finished_turn_re_arms_the_card(self):
        # THE HONESTY BOUNDARY, client-side. No `alignBusy` on the payload means
        # the daemon is not running a turn, and the card says so — a fact that
        # could never be withdrawn would be a worse lie than the one it cures.
        res = _run(PARKED, mode="card")
        buttons = [n for n in _flatten(res.get("overlay"))
                   if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertIn("START ALIGNMENT", btexts)
        self.assertNotIn("SCANNING", btexts)

    def test_slow_turn_fires_exactly_one_start_post(self):
        res = _run(PARKED, mode="scan-outlives-timeout")
        starts = [u for u in res["fetches"] if u.endswith("/api/align/start")]
        self.assertEqual(len(starts), 1,
                         "exactly one worker turn may be spawned per click")

    def test_the_turn_returning_is_what_ends_the_scan(self):
        # The other half of the same contract: the guard is not permanent. It is
        # released by the turn SETTLING (here: the held response landing), which
        # is also the path a dead daemon takes — postWrite's .catch reports a
        # network error and clears it. That event, never a clock, ends the scan.
        res = _run(PARKED, mode="scan-outlives-timeout")
        self.assertEqual(res["aligningAfterReturn"], False,
                         "when the worker turn finally returns, the scan ends")
        self.assertEqual(res["opened"], 1,
                         "…and the alignment console opens — the turn SUCCEEDED")

    # ── F2: closing the CONSOLE mid-grill KEEPS the session (resume) ────────
    def test_close_keeps_session_and_marks_resumable(self):
        res = _run(PARKED, mode="close-keeps")
        # the warm session is NOT reaped — no /cancel POST.
        self.assertFalse([u for u in res["fetches"] if u.endswith("/cancel")],
                         "closing mid-grill must NOT cancel the warm session")
        # and the parked mission is marked resumable so the card flips to RESUME.
        self.assertIn(PARKED["id"], res["resumable"],
                      "closing mid-grill must mark the mission RESUMABLE")

    # ── F1: FINALIZING band + disabled control on the card ─────────────────
    def test_card_finalizing_shows_disabled_control_and_band(self):
        res = _run(PARKED, mode="card-finalizing")
        buttons = [n for n in _flatten(res.get("overlay")) if n.get("tag") == "button"]
        fin = [n for n in buttons if "FINALIZING" in n.get("text", "").upper()]
        self.assertTrue(fin and all(n["disabled"] for n in fin),
                        "a finalizing card must render a disabled FINALIZING control")
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertNotIn("START ALIGNMENT", btexts)
        self.assertNotIn("RESUME ALIGN", btexts)
        bands = [n for n in _flatten(res.get("overlay"))
                 if "lcars-running" in n.get("cls", "")]
        self.assertTrue(bands, "a finalizing card must render the .lcars-running band")

    # ══ S169 / FL-017 — FINALIZING & COSTING, WITHOUT THE FIVE-MINUTE FUSE ══
    #
    # `board.js` covered the estimate + `file.sh --complete` window with
    # `FINALIZING_TIMEOUT_MS = 300000` — FL-009's exact shape, longer fuse. On
    # expiry it dropped the band and re-armed the card while the run was still
    # going, and the captain met it live ("OK the mission is costing after the
    # grill"). FL-009's ruling was written for this: a bigger constant is the
    # same guess with a longer fuse.
    def test_the_finalize_guard_outlives_a_fired_five_minute_timer(self):
        """THE NO-TIMER CLAIM, driven rather than asserted. The submit is made,
        the answer POST is HELD OPEN (file.sh really is still running), and
        every long timer that submit armed is then fired — a browser's wall
        clock arriving before a finalize that is merely slow."""
        res = _run(PARKED, mode="finalize-outlives-timeout")
        self.assertTrue(res["finalizingAfterTimers"],
                        "a fired safety timer must NOT clear a finalize that is "
                        "still running — that is the defect, with a longer fuse")
        buttons = [n for n in _flatten(res.get("cardMidFlight"))
                   if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertIn("FINALIZING", btexts)
        self.assertNotIn("START ALIGNMENT", btexts,
                         "re-arming START ALIGNMENT under a live file.sh is the "
                         "re-click that spawns a second real worker")
        bands = [n for n in _flatten(res.get("cardMidFlight"))
                 if "lcars-running" in n.get("cls", "")]
        self.assertTrue(bands, "and the band stays with it")

    def test_the_mid_finalize_card_says_how_long_it_has_been_going(self):
        """Silence is what made FL-009 frightening. `◐ Finalizing & costing…
        5m 10s` reads as slow where a bare spinner reads as broken."""
        res = _run(PARKED, mode="finalize-outlives-timeout")
        joined = " || ".join(n.get("text", "")
                             for n in _flatten(res.get("cardMidFlight")))
        self.assertIn("5m 10s", joined)

    def test_the_POST_settling_is_what_releases_the_finalize_guard(self):
        res = _run(PARKED, mode="finalize-outlives-timeout")
        self.assertFalse(res["finalizingAfterReturn"],
                         "the answer POST settling — an EVENT — is what ends it")

    def test_a_finalize_that_FAILS_releases_the_guard_too(self):
        """The other half of "released by an event". Before S169 only the
        SUCCESS path dropped it; with the timer gone, a 502 from the estimator
        would have left the card banded and its control disabled forever."""
        res = _run(PARKED, mode="finalize-dies")
        self.assertFalse(res["finalizingAfterReturn"],
                         "settling BADLY is still settling")

    # ── FL-017, the RELOAD half: the daemon's fact, not this tab's ─────────
    def test_a_reloaded_card_still_reads_as_finalizing(self):
        """`FINALIZING` is client memory. A tab that reloaded mid-costing had
        none, and re-armed START ALIGNMENT over a running file.sh — FL-009's
        second half, in the state FL-009's own fix left alone."""
        res = _run(FINALIZING_ON_SERVER, mode="card")
        buttons = [n for n in _flatten(res.get("overlay"))
                   if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertNotIn("START ALIGNMENT", btexts)
        fin = [n for n in buttons if "FINALIZING" in n.get("text", "").upper()]
        self.assertTrue(fin and all(n["disabled"] for n in fin))

    def test_a_reloaded_card_shows_the_daemons_elapsed_finalize(self):
        # 218s on the wire → "3m 38s", through the SAME `scanningLabel` the
        # scan band uses. One wording, two sources for the same number.
        res = _run(FINALIZING_ON_SERVER, mode="card")
        joined = " || ".join(n.get("text", "")
                             for n in _flatten(res.get("overlay")))
        self.assertIn("3m 38s", joined)

    def test_a_reloaded_detail_mirrors_the_finalizing_card(self):
        _, texts = _texts(FINALIZING_ON_SERVER, mode="detail")
        joined = " || ".join(texts)
        self.assertIn("FINALIZING", joined.upper())
        self.assertNotIn("START ALIGNMENT", joined.upper())
        self.assertNotIn("RESUME ALIGN", joined.upper())

    def test_no_stamp_and_no_client_memory_re_arms_the_card(self):
        """The honesty boundary. An absent `alignFinalizing` means the daemon is
        not finalizing anything, and the card says so."""
        res = _run(PARKED, mode="card")
        buttons = [n for n in _flatten(res.get("overlay"))
                   if n.get("tag") == "button"]
        btexts = " || ".join(n.get("text", "") for n in buttons).upper()
        self.assertIn("START ALIGNMENT", btexts)
        self.assertNotIn("FINALIZING", btexts)

    # ── F2: RESUME ALIGN control (payload flag OR client flag) ─────────────
    def test_card_resume_from_payload_flag(self):
        m = _mission(id="m-park", stage="align", prdPending=True,
                     alignResume={"sid": "sid-payload"},
                     pills={"cost": None, "reasoning": None, "implementation": None})
        res = _run(m, mode="card")
        texts = " || ".join(n.get("text", "") for n in _flatten(res.get("overlay")))
        self.assertIn("RESUME ALIGN", texts.upper(),
                      "a card carrying m.alignResume must offer RESUME ALIGN")
        self.assertNotIn("START ALIGNMENT", texts.upper())

    def test_card_resume_from_client_flag(self):
        res = _run(PARKED, mode="card-resume-client")
        texts = " || ".join(n.get("text", "") for n in _flatten(res.get("overlay")))
        self.assertIn("RESUME ALIGN", texts.upper(),
                      "a client RESUMABLE flag must offer RESUME ALIGN")
        self.assertNotIn("START ALIGNMENT", texts.upper())

    def test_card_no_resume_flag_shows_start_alignment(self):
        res = _run(PARKED, mode="card")
        texts = " || ".join(n.get("text", "") for n in _flatten(res.get("overlay")))
        self.assertIn("START ALIGNMENT", texts.upper())
        self.assertNotIn("RESUME ALIGN", texts.upper())

    def test_resume_gets_session_and_opens_console(self):
        res = _run(PARKED, mode="resume")
        self.assertIn("/api/align/sid-resume", res["fetches"],
                      "RESUME ALIGN must GET the session's open turn")
        self.assertEqual(res["opened"], 1,
                         "resume must reopen the console at the returned question")

    # ── FIX-C: Park is the DEFAULT primary in the File-New-Mission modal ────
    def test_file_modal_park_is_primary_align_is_secondary(self):
        res = _run(PARKED, mode="file")
        buttons = [n for n in _flatten(res.get("overlay")) if n.get("tag") == "button"]

        def find(needle):
            hits = [n for n in buttons if needle in n.get("text", "")]
            self.assertTrue(hits, "expected a button containing " + repr(needle))
            return hits[0]

        park = find("File to Backlog")
        align = find("File & Begin Alignment")
        # Park is the sole teal primary — carries "go" but NOT "big" (same size as
        # the other footer buttons, per the captain ruling).
        self.assertIn("go", park["cls"].split(),
                      "Park must be the teal primary (go) button")
        self.assertNotIn("big", park["cls"].split(),
                         "Park must be the SAME size as the others — not 'big'")
        # Align is secondary — plain (not teal).
        self.assertNotIn("go", align["cls"].split(),
                         "the Align button must NOT be teal-primary")
        # exactly one teal (go) button in the footer (Park), and none oversized.
        primaries = [n for n in buttons if "go" in n["cls"].split()]
        self.assertEqual(len(primaries), 1,
                         "the File modal must have exactly one teal primary (Park)")
        big = [n for n in buttons if "big" in n["cls"].split()]
        self.assertEqual(len(big), 0,
                         "no footer button should be oversized ('big')")


if __name__ == "__main__":
    unittest.main()
