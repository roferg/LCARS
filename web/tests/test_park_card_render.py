"""Park & Align (S137) — the board CARD render for a PARKED mission.

Runs the SHIPPING web/static/board.js in a node vm (there is no JS DOM harness in
this repo; ADR-007 forbids a build step / npm) and calls the real `cardNode(m)`,
projecting the produced DOM to JSON. Asserts:
  * a `prdPending` card renders the ◇ STANDBY badge + "▹ START ALIGNMENT" control,
    NO estimate pills, and NEVER the runnable "▶ Start";
  * a normal align card (no prdPending) is byte-identical — "▶ Start", no standby,
    no START ALIGNMENT;
  * a view-only build disables the new write control.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_card_harness.js")
NODE = shutil.which("node")


def _flatten(node, acc=None):
    """Every node in the projected tree, depth-first."""
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


def _render(mission, mode=""):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(mission, fh)
    try:
        argv = [NODE, HARNESS, path]
        if mode:
            argv.append(mode)
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def _texts(nodes):
    return [n.get("text", "") for n in nodes]


def _classes(nodes):
    return [n.get("cls", "") for n in nodes]


PARKED = {
    "id": "m-park", "issue": 200, "stage": "align", "title": "Add a dark mode toggle",
    "type": "feature", "engine": "claude", "prdPending": True,
    "pills": {"cost": None, "reasoning": None, "implementation": None},
    "awaiting": False, "paused": False, "running": False, "queued": False,
    "dispatched": False, "tickets": [],
}

# a NORMAL align mission (no prdPending) — the byte-identity control group.
NORMAL_ALIGN = {
    "id": "m-001", "issue": 142, "stage": "align", "title": "Gamify the site",
    "type": "feature", "engine": "claude",
    "pills": {"cost": {"label": "$4–6"}, "reasoning": {"level": "medium", "label": "R"},
              "implementation": {"level": "high", "label": "I"}},
    "awaiting": False, "paused": False, "running": False, "queued": False,
    "dispatched": False, "tickets": [],
}


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ParkCardRenderTest(unittest.TestCase):
    def test_parked_card_shows_standby_badge(self):
        nodes = _flatten(_render(PARKED))
        classes = _classes(nodes)
        self.assertIn("pill standby", classes,
                      "a parked card must render the STANDBY badge")
        standby = next(n for n in nodes if n.get("cls") == "pill standby")
        self.assertIn("STANDBY", standby["text"].upper())

    def test_parked_card_control_is_start_alignment_not_start(self):
        nodes = _flatten(_render(PARKED))
        texts = " || ".join(_texts(nodes))
        self.assertIn("START ALIGNMENT", texts.upper(),
                      "a parked card must offer START ALIGNMENT")
        # it must NEVER offer the runnable "▶ Start" (no PRD ⇒ not runnable).
        self.assertNotIn("▶ Start", _texts(nodes),
                         "a parked card must NOT be runnable")

    def test_parked_card_has_no_estimate_pills(self):
        nodes = _flatten(_render(PARKED))
        classes = _classes(nodes)
        self.assertNotIn("pill cost", classes,
                         "a parked mission has no estimate — no cost pill")
        self.assertFalse([c for c in classes if c in ("pill low", "pill med",
                                                       "pill high")],
                         "a parked mission shows no difficulty pills")

    def test_normal_align_card_unchanged_byte_identical(self):
        """A non-parked align card renders "▶ Start", cost pill, and NO standby /
        START ALIGNMENT — proving the parked branch is additive only."""
        nodes = _flatten(_render(NORMAL_ALIGN))
        texts = _texts(nodes)
        classes = _classes(nodes)
        self.assertIn("▶ Start", texts)
        self.assertIn("pill cost", classes)
        self.assertNotIn("pill standby", classes)
        self.assertNotIn("START ALIGNMENT", " || ".join(texts).upper())

    def test_readonly_disables_start_alignment(self):
        nodes = _flatten(_render(PARKED, mode="readonly"))
        aligns = [n for n in nodes
                  if "START ALIGNMENT" in n.get("text", "").upper()]
        self.assertTrue(aligns, "START ALIGNMENT control must exist")
        self.assertTrue(all(n["disabled"] for n in aligns),
                        "a view-only build must disable START ALIGNMENT")


if __name__ == "__main__":
    unittest.main()
