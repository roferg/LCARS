#!/usr/bin/env python3
"""xo-observe.py — the OBSERVATIONS pass: crowding, overlap, misalignment and
clipped text, computed from the boxes the driver already recorded.

    python3 xo-observe.py <readout.json> <out observations.json>
                           [--gap-px N] [--misalign-px N] [--overflow-px N]

THIS IS ARITHMETIC, NOT A JUDGEMENT (captain's ruling 2026-09-11, "the worker
reasons, the skill executes" — S210's application of it). Every instruction the
worker has ever been given frames a finding as "versus the drawing", and a
drawing never says "there is a gap here" — so nothing asked the model to notice
two smooshed buttons, because nothing recorded the geometry to notice it FROM.
S210 fixed the recording (`xo-drive.js` now walks the whole DOM); this script
is the second half — it reads the boxes back and does the measuring a human
would do with a ruler, so the worker is handed the finding already made rather
than being asked to eyeball spacing from a screenshot.

WHAT THIS IS NOT. Observations are not gaps and are never a criterion. They
never move a score — nothing here even sees `criteria.json`. They are reported
in their OWN section, so the worker (and the captain, reading the same words in
the living comment) can use one as evidence for a real criterion without ever
being able to invent a new criterion out of one.

THE THRESHOLDS ARE A GUESS, AND SAID TO BE ONE. The captain is the only one who
can calibrate "how close is too close" against his own eye on his own apps
(S210 brief) — so every number here is a named constant, carried into
`observations.json` as `thresholds`, and xo-score.py prints them into the
report so he can tell us they are wrong.

Input: `readout.json`, exactly as `xo-drive.js` writes it — this script reads
`page.elements`, the list EVERY visible element on the page, one box + computed
colour + a couple of DOM facts each (S210). A page with no elements (or none
that trip any detector) yields an EMPTY observations list — a clean page must
produce NOTHING, not a false alarm (the captain's own words: "a crowding check
that fires on a well-spaced page would train the captain to ignore the whole
feature").
"""
import json
import os
import sys
from collections import Counter

# ── THE THRESHOLDS (a first guess, printed for the captain to correct) ──────
GAP_PX_DEFAULT = 8         # two INTERACTIVE elements closer than this: crowded
MISALIGN_PX_DEFAULT = 6    # a sibling's left edge missing the others' by this
OVERFLOW_PX_DEFAULT = 2    # content spilling past its own box by more than this

OBS_CAP = 20                # bounded output: a dense page cannot blow up the
                             # readout here either (S210's own rule, applied to
                             # its own output).


def load(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None


# ── naming things the way a person would (house style, no harness words) ───
KIND_WORDS = {"button": "button", "a": "link", "select": "dropdown",
              "textarea": "field", "summary": "control"}


def kind_word(el):
    tag = (el.get("tag") or "").lower()
    if tag == "input":
        t = (el.get("inputType") or "text").lower()
        if t in ("checkbox",):
            return "checkbox"
        if t in ("radio",):
            return "radio button"
        if t in ("submit", "button"):
            return "button"
        return "field"
    return KIND_WORDS.get(tag, "control")


def label(el):
    """A name a person would use, or None if this element has nothing to be
    called — never an element id, never a CSS selector."""
    text = (el.get("text") or "").strip()
    if text:
        return text if len(text) <= 30 else text[:29].rstrip() + "…"
    aria = (el.get("ariaLabel") or "").strip()
    if aria:
        return aria
    eid = (el.get("id") or "").strip()
    if eid:
        return eid.replace("-", " ").replace("_", " ").strip()
    return None


def solo(el):
    """'the ADD button' / 'the unlabeled field' — one element, named."""
    l, k = label(el), kind_word(el)
    return ("the " + l + " " + k) if l else ("the unlabeled " + k)


def pair(a, b):
    """'the ADD and CANCEL buttons' when they are the same kind of thing,
    'the ADD button and the search field' when they are not."""
    la, ka = label(a), kind_word(a)
    lb, kb = label(b), kind_word(b)
    if la and lb and ka == kb:
        return "the %s and %s %ss" % (la, lb, ka)
    return "%s and %s" % (solo(a), solo(b))


# ── box geometry ─────────────────────────────────────────────────────────
def edges(box):
    return box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"]


def intersects(a, b):
    ax1, ay1, ax2, ay2 = edges(a)
    bx1, by1, bx2, by2 = edges(b)
    return not (ax2 <= bx1 or bx2 <= ax1 or ay2 <= by1 or by2 <= ay1)


def overlap_extent(a, b):
    ax1, ay1, ax2, ay2 = edges(a)
    bx1, by1, bx2, by2 = edges(b)
    ow = min(ax2, bx2) - max(ax1, bx1)
    oh = min(ay2, by2) - max(ay1, by1)
    return max(0, min(ow, oh))


def adjacency_gap(a, b):
    """The gap between two NON-overlapping boxes, only when they plausibly sit
    in the same row (their y-ranges overlap) or the same column (their
    x-ranges overlap) — two elements on opposite corners of the page are not
    "close together" just because the number between them is small on one
    axis. Returns None if neither relation holds."""
    ax1, ay1, ax2, ay2 = edges(a)
    bx1, by1, bx2, by2 = edges(b)
    vy = min(ay2, by2) - max(ay1, by1)
    if vy > 0:
        return max(bx1 - ax2, ax1 - bx2)
    vx = min(ax2, bx2) - max(ax1, bx1)
    if vx > 0:
        return max(by1 - ay2, ay1 - by2)
    return None


# ── the four detectors ──────────────────────────────────────────────────
def detect_crowding(elements, gap_px):
    out = []
    inter = [e for e in elements if e.get("interactive") and e.get("box")]
    for i in range(len(inter)):
        for j in range(i + 1, len(inter)):
            a, b = inter[i], inter[j]
            if intersects(a["box"], b["box"]):
                continue  # that is an OVERLAP, a different finding
            gap = adjacency_gap(a["box"], b["box"])
            if gap is None or gap >= gap_px:
                continue
            px = max(gap, 0)
            verb = "touching" if px == 0 else "crowded together"
            out.append({
                "kind": "crowding", "px": px,
                "elements": [label(a) or solo(a), label(b) or solo(b)],
                "message": "%s are %s — %d px between them" % (pair(a, b), verb, px),
            })
    return out


def detect_overlap(elements):
    out = []
    inter = [e for e in elements if e.get("interactive") and e.get("box")]
    for i in range(len(inter)):
        for j in range(i + 1, len(inter)):
            a, b = inter[i], inter[j]
            if not intersects(a["box"], b["box"]):
                continue
            px = overlap_extent(a["box"], b["box"])
            out.append({
                "kind": "overlap", "px": px,
                "elements": [label(a) or solo(a), label(b) or solo(b)],
                "message": "%s overlap — they share %d px of the same space" % (pair(a, b), px),
            })
    return out


def detect_misaligned(elements, threshold):
    """A control whose left edge misses its siblings' by more than N px — a
    'sibling' is anything sharing this element's tag AND class, which is what
    a repeated row (a list of tasks, a row of buttons) looks like from the
    boxes alone."""
    out = []
    groups = {}
    for e in elements:
        cls = (e.get("className") or "").strip()
        if not cls or not e.get("box"):
            continue
        groups.setdefault((e.get("tag"), cls), []).append(e)
    for (_, _), group in groups.items():
        if len(group) < 2:
            continue
        xs = [e["box"]["x"] for e in group]
        baseline, _n = Counter(xs).most_common(1)[0]
        group_sorted = sorted(group, key=lambda e: e["box"]["y"])
        for e in group_sorted:
            x = e["box"]["x"]
            off = x - baseline
            if abs(off) <= threshold:
                continue
            out.append({
                "kind": "misaligned", "px": abs(off),
                "elements": [label(e) or solo(e)],
                "message": "%s does not line up with the rows above it — its "
                           "left edge is %d px %s (%d px vs %d px for the "
                           "others)" % (solo(e), abs(off),
                                        "further right" if off > 0 else "further left",
                                        x, baseline),
            })
    return out


def detect_clipped(elements, threshold):
    out = []
    for e in elements:
        if not (e.get("text") or "").strip():
            continue
        ox, oy = e.get("overflowX") or 0, e.get("overflowY") or 0
        worst = max(ox, oy)
        if worst <= threshold:
            continue
        out.append({
            "kind": "clipped", "px": worst,
            "elements": [label(e) or solo(e)],
            "message": "%s text is clipped by its own box — it needs %d px "
                       "more room than the box gives it" % (solo(e), worst),
        })
    return out


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: xo-observe.py <readout.json> <out.json> "
                          "[--gap-px N] [--misalign-px N] [--overflow-px N]\n")
        return 2
    inpath, outpath = argv[1], argv[2]

    def flag(name, default):
        try:
            i = argv.index("--" + name)
            return int(argv[i + 1])
        except (ValueError, IndexError):
            return default

    gap_px = flag("gap-px", GAP_PX_DEFAULT)
    misalign_px = flag("misalign-px", MISALIGN_PX_DEFAULT)
    overflow_px = flag("overflow-px", OVERFLOW_PX_DEFAULT)

    doc = load(inpath) or {}
    page = doc.get("page") if isinstance(doc, dict) else None
    elements = (page or {}).get("elements") if isinstance(page, dict) else None
    elements = elements if isinstance(elements, list) else []
    elements = [e for e in elements if isinstance(e, dict) and isinstance(e.get("box"), dict)]

    obs = (detect_crowding(elements, gap_px) + detect_overlap(elements) +
           detect_misaligned(elements, misalign_px) + detect_clipped(elements, overflow_px))

    notes = []
    if len(obs) > OBS_CAP:
        notes.append("found %d observations; only the first %d are kept (cap %d)"
                     % (len(obs), OBS_CAP, OBS_CAP))
        obs = obs[:OBS_CAP]

    out = {
        "thresholds": {"gapPx": gap_px, "misalignPx": misalign_px, "overflowPx": overflow_px},
        "elementCount": len(elements),
        "observations": obs,
        "notes": notes,
    }
    os.makedirs(os.path.dirname(os.path.abspath(outpath)) or ".", exist_ok=True)
    with open(outpath, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")
    print("%d observation(s) from %d element(s)" % (len(obs), len(elements)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
