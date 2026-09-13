"""S201 — ONE MORE FACT on S190's fixture: Number One has the conn.

Handed (repo, fixture-root) by `owner-paint.sh`'s LCARS_PAINT_PLANT seam, AFTER
its own planter has run. It adds nothing to the board's population — it engages
Number One on a mission that is already there — because the pixel question is
"can you tell the peach pill from the amber owner pill with the colour removed",
and that question needs the two pills on ONE screen, not two boards.

  m-mine      → ENGAGED. Mine, at verify, with a live control row: the card the
                peach edge, the solid pill, the line and the locked controls are
                all read off.
  m-align-mine→ FINISHED, with a score. The hollow half of the same sentence,
                so "solid vs hollow" can be measured between two REAL cards
                rather than asserted about one.

…and the repo's own toggle ON, which is what puts the band control and the two
legend entries on screen at all.
"""
import json
import os
import sys

repo, root = sys.argv[1], sys.argv[2]


def engage(mid, block):
    """Write `numberOne` the way the shipped writers write it: ONE LINE, at the
    TOP of the object (the S189 rule — new keys stay off the end, where the
    latent last-key corruption lives)."""
    path = os.path.join(root, ".git", "lcars", "missions", mid, "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    with open(path) as fh:
        json.load(fh)               # still valid JSON, which is the point


engage("m-mine", {"status": "engaged", "engine": "copilot",
                  "since": "2026-09-12T01:00:00Z"})
engage("m-align-mine", {"status": "finished", "engine": "copilot",
                        "score": "HIGH",
                        "note": "Number One stood down 01:14 · you have the conn"})

cfg_dir = os.path.join(root, ".git", "lcars")
os.makedirs(cfg_dir, exist_ok=True)
cfg_path = os.path.join(cfg_dir, "config.json")
cfg = {}
if os.path.isfile(cfg_path):
    try:
        with open(cfg_path) as fh:
            cfg = json.load(fh)
    except ValueError:
        cfg = {}
cfg["numberOne"] = {"enabled": True, "engine": "copilot"}
with open(cfg_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
