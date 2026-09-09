"""Capture the S190 byte-identity BASELINE.

    python3 tests/drives/s190/capture-baseline.py

THE POINT. S190 is additive: a board with no owner published and no gh must
serve a payload — and render a card — byte-for-byte identical to the one it
served before the session. The only honest way to check that is against an
artifact captured from the PRE-CHANGE tree, so this script was run at c5f3723
and its two outputs committed under web/tests/fixtures/s190/. An expectation
written AFTER the change can only ever agree with the code it was written from.

`plant()` below must stay EXACTLY in step with test_owner_board.BaselineFixture
— the whole guarantee is that the same tree is built the same way on both sides.

RE-RUN THIS ONLY to re-baseline against a NEW pre-change tree (a later session
starting its own additive round). Re-running it against a tree that already
carries S190 would simply record whatever S190 does and the guard would go
silent — which is the one thing it exists to prevent.
"""
import json, os, subprocess, sys, tempfile

import pathlib
HERE = str(pathlib.Path(__file__).resolve().parents[3] / "web")
sys.path.insert(0, HERE)
from tests import _fixtures as fx
from lcars_serve.local_adapter import LocalAdapter

OUT = os.path.join(HERE, "tests", "fixtures", "s190")


def plant(root):
    """The identity-free fixture. Deterministic: fixed ids, fixed created
    stamps, no clock, no git, no gh."""
    fx.plant_simple(root, "m-align", stage="align", issue=101,
                    created="2026-06-01T10:00:00Z")
    fx.plant_simple(root, "m-verify", stage="verify", issue=102,
                    created="2026-06-02T10:00:00Z",
                    pr_url="https://github.com/acme/repo/pull/7", pr_number="7",
                    review="open")
    fx.plant_paused(root, "m-paused", stage="implement", issue=103)
    fx.plant_gated(root, "m-gated", issue=104)
    fx.plant_parked(root, "m-parked", issue=105)
    fx.plant_simple(root, "m-noissue", stage="plan", issue=None,
                    created="2026-06-05T10:00:00Z")


def board_payload():
    root = tempfile.mkdtemp()
    plant(root)
    ad = LocalAdapter(root, git_url_reader=lambda r: "git@x:acme/repo.git")
    b = ad.board()
    # activeSecondsAt is a server wall-clock; scrub it (it is not what this
    # baseline is about, and it moves every run).
    for c in b["missions"] + [c for col in b["columns"].values() for c in col]:
        if "activeSecondsAt" in c:
            c["activeSecondsAt"] = 0
    return b


def card_dom(card):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(p, "w") as fh:
        json.dump(card, fh)
    out = subprocess.check_output(
        ["node", os.path.join(HERE, "tests", "board_card_harness.js"), p])
    return json.loads(out.decode())


b = board_payload()
with open(os.path.join(OUT, "board-baseline.json"), "w") as fh:
    fh.write(json.dumps(b, sort_keys=True, indent=2) + "\n")

doms = {}
for c in b["missions"]:
    doms[c["id"]] = card_dom(c)
with open(os.path.join(OUT, "card-dom-baseline.json"), "w") as fh:
    fh.write(json.dumps(doms, sort_keys=True, indent=2) + "\n")
print("missions:", [c["id"] for c in b["missions"]])
print("wrote", OUT)
