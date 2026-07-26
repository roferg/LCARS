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
