#!/usr/bin/env python3
"""Plant the S225 rail fixture: four missions, one per state the rail must
survive, built from the captain's REAL replayed verdicts.

    python3 plant.py <missions-dir> <verdicts-dir>

  twice     both looks recorded — three groups, two bars each. The main case.
  once      the first look only — three groups, one bar, no deltas claimed.
  nodrawing the drawing group emptied to total 0. It must NOT be drawn, and
            certainly not as "Does it look like your drawing? — LOW".
  legacy    a verdict with no `groups` at all, exactly as every mission scored
            before today has on disk. It must keep the old single bar.

Nothing here rewrites a number: the group tallies, questions, asides and
myChecking entries are the scorer's own, copied off the replay.
"""
import json
import os
import shutil
import sys

missions, verdicts = sys.argv[1], sys.argv[2]
V1 = json.load(open(os.path.join(verdicts, "verdict.json")))
V2 = json.load(open(os.path.join(verdicts, "second", "verdict.json")))

JOURNAL = [{"action": "scored", "at": "2026-09-21T05:15:38Z"},
           {"action": "rescored", "at": "2026-09-21T07:37:34Z"}]


def plant(mid, title, v1, v2, score, score2=None, issue=9001):
    d = os.path.join(missions, mid)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "xo", "second"))
    xo = {"status": "finished" if (score2 or score) == "high" else "engaged",
          "engine": "copilot", "score": score,
          "headline": v1.get("derivation", "")}
    if score2:
        xo["score2"] = score2
    json.dump({"id": mid, "type": "feature", "title": title, "stage": "verify",
               "created": "2026-09-11T10:00:00Z", "model": "copilot",
               "githubIssue": issue, "branch": "lcars/" + mid, "base": "main",
               "numberOne": xo},
              open(os.path.join(d, "state.json"), "w"))
    json.dump(v1, open(os.path.join(d, "xo", "verdict.json"), "w"))
    if v2 is not None:
        json.dump(v2, open(os.path.join(d, "xo", "second", "verdict.json"), "w"))
    else:
        os.rmdir(os.path.join(d, "xo", "second"))
    with open(os.path.join(d, "number-one.jsonl"), "w") as fh:
        for e in JOURNAL:
            if e["action"] == "rescored" and v2 is None:
                continue
            fh.write(json.dumps(e) + "\n")


def strip_drawing(v):
    out = json.loads(json.dumps(v))
    g = out["groups"]["drawing"]
    for k in ("total", "worked", "didntWork", "couldntSee", "couldntSetUp",
              "met", "gap", "untested"):
        g[k] = 0
    g["ids"] = []
    g.pop("grade", None)
    g.pop("rule", None)
    return out


def legacy(v):
    """What a verdict written before today looks like: no groups, no
    scoreGroup, no myChecking — just the whole-ledger counts."""
    out = json.loads(json.dumps(v))
    for k in ("groups", "scoreGroup", "myChecking"):
        out.pop(k, None)
    return out


plant("lcars-20260921-twice", "The MBR builder — looked at twice",
      V1, V2, V1.get("score"), V2.get("score"), 9001)
plant("lcars-20260921-once", "The MBR builder — one look",
      V1, None, V1.get("score"), None, 9002)
plant("lcars-20260921-nodrawing", "A mission with no drawing at all",
      strip_drawing(V1), None, V1.get("score"), None, 9003)
plant("lcars-20260921-legacy", "Scored before the split (no groups on disk)",
      legacy(V1), None, V1.get("score"), None, 9004)
print("planted 4 missions in", missions)
