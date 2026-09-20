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

S212 — IT MUST NOT CRY WOLF. Driven live, the pass above fired on UI that was
perfectly correct: a chip's own embedded remove button read as "touching", a
notification badge on a button corner read as "overlap", a box that is MEANT to
scroll read as "clipped", and a tidy five-row list produced five separate notes
saying the same thing. None of that needed anyone to define anything — every
case is settled by a fact the BROWSER already knows, which `xo-drive.js` now
writes down (`path`, `overflowStyleX/Y`, `seen`). This script only READS those
facts. It never works nesting out from the boxes: a badge sits geometrically
inside its button, and so does a genuinely misplaced element that merely
overlaps one, and no amount of rectangle arithmetic can tell those apart.

Then two rules about VOLUME, because noise kills a feature just as surely as a
falsehood does: one fact reported N times is collapsed into one note that names
the count, and past a handful the list is capped at the three worst and SAYS how
many it held back. A wall of notes gets skipped, and a feature that gets skipped
is dead.

S212, FIX ROUND 1 — AND IT MUST NOT GO DEAF. Quietening the four false alarms
above bought three new faults, all of the opposite kind, and a guard quietened
into uselessness is the worse failure:

  * ANYTHING laid over the page bought total silence. The only escape hatch was
    `pointer-events:none`, so a bare `position:fixed; inset:0` click-catcher —
    which real apps put over the page constantly — read every element beneath
    it as unseen and Number One reported a clean page. A cover now has to be
    SOLID ENOUGH TO ACTUALLY HIDE to hide anything, measured in the driver
    where the browser is still open to be asked. An ancestor winning the hit
    test is still the other case entirely (a row its own scroll container has
    carried away) and is still silence; the two are recorded APART.
    THAT CURE LEAKED TWICE MORE before the rule itself was changed: round 2
    assumed any background-image solid (so any gradient silenced a page), and
    round 3 assumed any unparseable colour solid (so a 30% dim written as
    oklch() or lab() or color-mix() silenced a page while the identical dim
    written as rgba() did not). ROUND 4 INVERTED THE FALLBACK ITSELF — an
    element is recorded as not-seen ONLY where hiding was positively
    established, and anything unmeasurable means LOOK. The captain's ruling,
    and his reason: a wrong complaint is on the screen where he can see it and
    say it is wrong; going quiet means he never finds out it did not look. The
    whole argument lives in `xo-drive.js` beside the code it governs.
  * A collapsed sentence invented a place. A family was "same tag, same class"
    and never looked at the container, so a tab bar and a segmented control
    60 px below it became "five buttons in this row are touching" — and there
    was no such row on the page. A family is now things that really sit
    together, and a sentence only names a place when the group shares one.
    The first cure for that asked every pair to share a DIRECT parent, which
    is right about the tab bar and wrong about the commonest repeat in UI:
    twenty list rows each carrying its own Edit/Delete pair share no direct
    parent, so nothing folded and the captain read a cap line followed by
    three byte-identical sentences. The second cure took the LOWEST COMMON
    ANCESTOR of the whole group instead, and sprang the leak again: every
    real application has a wrapper — #app, #root, .container, <main> — so the
    LCA always finds something and a place was therefore ALWAYS asserted. A
    tab bar, a segmented control and a pager inside one #app read as "seven
    buttons in this list are touching", and there is no list of seven buttons
    on that screen. ROUND 4 MADE A PLACE SOMETHING THAT HAS TO BE EARNED, by
    one of exactly two shapes and nothing else (`shared_place`): one direct
    parent, or one genuinely repeated family. A wrapper that merely contains
    everything is not a place, and a group that has none says so. Which WORD
    to call a place it does have, a row or a list, is read off the boxes
    rather than off the crowding axis. Under all of it sits one invariant:
    two notes that would read the same word for word FOLD (`say_it_once`),
    because that is proof they were one fact all along.

    And where the group IS a repeated family whose units all carry the same
    names, the sentence describes THAT rather than counting — "every row's
    Edit and Delete buttons are touching" beats "38 buttons in this list are
    touching", which is a number with no story (`repeated_labels`). ROUND 5
    MADE THE WORD "EVERY" SOMETHING THAT HAS TO BE ESTABLISHED: the rest of
    the family is counted (`family_census`), and a page where three of eight
    rows are affected says "three rows'" instead. A story with a FALSE number
    is worse than a number with no story — it is the error he catches himself,
    standing in front of the screen.
  * "The three worst" were not the worst. They were ranked by a FIXED CATEGORY
    ORDER, so clipped text and a crooked row were last in the queue by
    construction and were exactly what the cap threw away. Worst is EARNED now
    — see `noticeability`.

And one more of the ORIGINAL kind that got through: `overflow:hidden;
text-overflow:ellipsis` always fired, and that is the universal idiom for
deliberately shortening a long name. Same cure as `overflow:auto`, one recorded
field along — but only where the ellipsis can actually RENDER. It cannot on
text that is allowed to wrap, and a base class setting `text-overflow:
ellipsis` on everything (which is how people write CSS) bought silence for a
60 px box whose one long unbreakable word was chopped with no "…" anywhere.
`white-space` is recorded too now, and it is what decides.

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
RHYTHM_TOL_PX = 1          # two neighbour gaps this close are THE SAME gap
                           # (sub-pixel layout, not a second opinion about
                           #  spacing) — a measurement tolerance, not a floor

# ── HOW MUCH IT IS ALLOWED TO SAY (S212) ───────────────────────────────────
# A wall of notes gets skipped, and a feature that gets skipped is dead. So:
# the same fact found over and over becomes ONE note that names the count, and
# past a handful of notes only the worst few are printed — out loud, with the
# number held back, so a quiet report is never mistaken for a clean page.
COLLAPSE_AT = 3             # this many of one fact in one family -> one note
OBS_HANDFUL = 5             # up to this many notes, he reads them all
OBS_CAP = 3                 # past a handful: the three worst, and say so

# A FIXED CATEGORY ORDER IS NOT "THE WORST" (S212 fix round 1). This used to
# rank the findings by their KIND — overlap, then crowding, then clipped, then
# misaligned — so clipped text and a crooked row were structurally last in the
# queue and were exactly what the cap threw away first. Driven on a real batch
# tracker it printed three trivial toolbar notes and held back six names cut
# off mid-word and a row 40 px out of true: the only two things a person
# actually notices in the screenshot. A live worker reading the same shot
# found both and led with them. The cap was outranked by the model.
#
# So "worst" is EARNED now — see `noticeability` below — and the kind order
# survives only as a tie-break, so that two findings of equal weight still
# come out in the same order every run.
KIND_RANK = {"overlap": 0, "crowding": 1, "clipped": 2, "misaligned": 3}

COUNT_WORDS = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six",
               7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven",
               12: "twelve"}


def count_word(n):
    """Spelled out while a person would spell it out, digits after that."""
    return COUNT_WORDS.get(n, str(n))


def plural(word):
    return word + "es" if word.endswith(("s", "x", "ch", "sh")) else word + "s"


def flag_str(argv, name, default=""):
    try:
        return argv[argv.index("--" + name) + 1]
    except (ValueError, IndexError):
        return default


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


# ── the three facts the BROWSER wrote down, read back (S212) ──────────────
# Every one of these is a lookup. None of them is a derivation from the boxes.
# That distinction is the whole session: inferring nesting from geometry would
# be beaten the first time a genuinely misplaced element landed inside another
# one's rectangle, which is exactly what a badge looks like from the outside.
def nested(a, b):
    """True when one of these two elements is INSIDE the other. A parent and
    its own child touching at 0 px is structurally inevitable — a chip and its
    remove button, a button and its unread badge — not a fault anyone can fix.

    The DOM position comes from the driver as a chain of child indices, so one
    being inside the other is a prefix test. When either path is missing (an
    older readout, a crafted fixture) we say nothing and let the pair be
    measured: staying quiet is the failure mode worth avoiding."""
    pa, pb = a.get("path"), b.get("path")
    if not isinstance(pa, str) or not isinstance(pb, str) or not pa or not pb:
        return False
    return pa == pb or pa.startswith(pb + ".") or pb.startswith(pa + ".")


def can_be_seen(el):
    """Whether this element is really what is painted at its own position —
    recorded by the driver with one hit test. A row its container has scrolled
    away and a button behind an opaque modal backdrop are the same case, and
    measuring either of them is measuring something nobody can look at."""
    return el.get("seen") is not False


SCROLLING = ("auto", "scroll", "overlay")

# The white-space values that keep text on ONE line. An ellipsis can only be
# drawn where the line does not wrap, so these are the only values under which
# `text-overflow: ellipsis` means anything at all.
NO_WRAP = ("nowrap", "pre")


def scrolls(el, axis):
    """Whether the element is MEANT to hold more than it shows on this axis.
    Reads the computed overflow PROPERTY — a different fact from the pixel
    spill in `overflowX`/`overflowY`, which says how much, never whether it
    matters."""
    v = el.get("overflowStyleX" if axis == "x" else "overflowStyleY")
    return isinstance(v, str) and v.strip().lower() in SCROLLING


def ellipsized(el):
    """Whether the author asked for the text to be SHORTENED rather than to
    fit. `overflow:hidden; text-overflow:ellipsis` is the universal idiom for
    a long name in a narrow column, and the ellipsis is the author saying out
    loud that cutting it off was the point — a person reading the screen sees
    the "…" and knows there is more. `overflow:hidden` with no ellipsis says
    nothing of the kind and still reports: that is the control.

    BUT ONLY WHERE THE ELLIPSIS CAN ACTUALLY RENDER. `text-overflow` does
    nothing whatsoever to text that is allowed to wrap — the browser wraps
    first, there is no single overflowing line to put a "…" on, and a 60 px
    box holding one long unbreakable word is chopped mid-word with no "…"
    anywhere on the screen. Reading the property alone made a base class that
    sets `text-overflow: ellipsis` on everything — which is how people write
    CSS — buy silence for every wrapping box in the application. A readout
    too old to carry `white-space` therefore reports rather than stays quiet:
    the failure mode worth avoiding is silence.

    Another lookup of a fact the browser wrote down, exactly like `scrolls`
    one field along. It applies only across the inline axis, which is the only
    axis text-overflow has ever governed."""
    v = el.get("textOverflow")
    if not (isinstance(v, str) and v.strip().lower() not in ("", "clip", "none")):
        return False
    ws = el.get("whiteSpace")
    return isinstance(ws, str) and ws.strip().lower() in NO_WRAP


def family(el):
    """What KIND of thing this is, for the purpose of noticing that the same
    fault has just been reported about five of them."""
    return "%s|%s" % ((el.get("tag") or "").lower(),
                      (el.get("className") or "").strip())


def parent_path(el):
    """WHERE this element lives — its parent's position in the DOM, read off
    the path the driver recorded. Never inferred from the boxes."""
    path = el.get("path")
    if not isinstance(path, str) or "." not in path:
        return None
    return path.rsplit(".", 1)[0]


def container_of(a, b):
    """The nearest place that holds BOTH of these — the longest prefix their
    two recorded DOM paths share. Two things in one toolbar share the toolbar;
    a tab bar and a segmented control 60 px below it share only the page.

    This is what makes a family a real GROUP rather than a coincidence of tag
    and class. Without it, three tabs and two segmented buttons — five
    unrelated `button`s with nothing in common but their tag — collapse into
    one sentence about "this row", and there is no such row on the screen."""
    pa, pb = a.get("path"), b.get("path")
    if not isinstance(pa, str) or not isinstance(pb, str) or not pa or not pb:
        return None
    sa, sb = pa.split("."), pb.split(".")
    shared = []
    for x, y in zip(sa, sb):
        if x != y:
            break
        shared.append(x)
    return ".".join(shared) if shared else None


def lowest_common_ancestor(members):
    """The deepest DOM path that holds every one of these, or None."""
    paths = []
    for m in members:
        p = m.get("path")
        if not isinstance(p, str) or not p:
            return None
        paths.append(p.split("."))
    shared = []
    for parts in zip(*paths):
        if len(set(parts)) != 1:
            break
        shared.append(parts[0])
    return ".".join(shared) if shared else None


def unit_shape(members):
    """THE SHAPE OF ONE UNIT of a repeated family: how many of the group sit
    in it, how big each of them is, and where each sits relative to the
    unit's own top-left corner. Two units are the same thing repeated when
    these match exactly — twenty rows each carrying an Edit and a Delete, cut
    to the same size in the same two places.

    A tab bar holding three tabs and a segmented control holding two are not
    the same thing repeated, and this is what says so."""
    boxes = [m.get("box") for m in members]
    if any(not isinstance(b, dict) for b in boxes):
        return None
    ox = min(b["x"] for b in boxes)
    oy = min(b["y"] for b in boxes)
    return tuple(sorted((b["x"] - ox, b["y"] - oy, b["w"], b["h"]) for b in boxes))


def unit_corner(members):
    boxes = [m["box"] for m in members]
    return (min(b["x"] for b in boxes), min(b["y"] for b in boxes))


def units_line_up(units):
    """Whether the units are laid out the way a family is laid out — one
    column, one row, or a filled grid. Read off the corners, with no
    threshold in it: the units' top-left corners must be exactly every
    combination of the distinct lefts and the distinct tops.

    Twenty list rows are a column; six buttons in two columns of three are a
    grid; three identical widgets at (40,100), (600,300) and (1000,600) are
    three points on a diagonal — one of nine combinations filled — and a
    sentence calling those "this list" sends the captain looking for a list
    that is not on the screen."""
    corners = [unit_corner(u) for u in units]
    if len(set(corners)) != len(corners):
        return False
    xs = set(c[0] for c in corners)
    ys = set(c[1] for c in corners)
    return len(xs) * len(ys) == len(corners)


def repeated_family(members):
    """THE GROUP AS ONE THING REPEATED — the units, in order — or None when
    it is not that shape.

    This is the second of the only two ways a group earns a place, and every
    condition in it has to be POSITIVELY true:

      * every member's parent is a SIBLING directly under the one ancestor
        that holds them all (so a wrapper two levels up buys nothing),
      * there are at least two such units,
      * every unit is the same shape (see `unit_shape`), and
      * the units line up (see `units_line_up`).

    Twenty list rows each carrying its own Edit/Delete pair pass all four,
    and they genuinely ARE one list. A tab bar, a segmented control and a
    pager inside one #app pass the first two and fail the third."""
    parents = [parent_path(m) for m in members]
    if not parents or any(p is None for p in parents):
        return None
    lca = lowest_common_ancestor(members)
    if not lca:
        return None
    for p in parents:
        if "." not in p or p.rsplit(".", 1)[0] != lca:
            return None
    order, by_parent = [], {}
    for p, m in zip(parents, members):
        if p not in by_parent:
            order.append(p)
            by_parent[p] = []
        by_parent[p].append(m)
    units = [by_parent[p] for p in order]
    if len(units) < 2:
        return None
    shapes = [unit_shape(u) for u in units]
    if any(sh is None for sh in shapes) or len(set(shapes)) != 1:
        return None
    if not units_line_up(units):
        return None
    return units


def shared_place(members):
    """THE ONE PLACE THAT HOLDS EVERY ONE OF THESE, or None when there is no
    such place.

    A PLACE HAS TO BE EARNED (captain's ruling, S212 round 4), and there are
    exactly two ways to earn one:

      1. every member shares the SAME DIRECT PARENT — one toolbar, one list,
         one form row. There is no arguing about where that is.
      2. the group is ONE REPEATED FAMILY (see `repeated_family`) — twenty
         rows each carrying its own Edit and Delete. That genuinely is one
         list, and asking for a direct parent cannot see it.

    ANYTHING ELSE HAS NO PLACE, and says so ("in different parts of the
    page") rather than inventing one. That is the change round 4 made, and
    the reason is the same one that runs through the driver: what this used
    to do was take the LOWEST COMMON ANCESTOR of the whole group, and every
    real application has a wrapper — #app, #root, .container, <main> — so the
    LCA always found something and a place was therefore always asserted. A
    tab bar, a segmented control and a pager, three plainly separate things
    60 px apart, all inside one #app, read as "seven buttons in this list are
    touching". There is no list of seven buttons on that screen. A WRAPPER
    THAT MERELY CONTAINS EVERYTHING IS NOT A PLACE.

    Erring toward naming a place was the old comment's stated intention, and
    it was wrong: a false place is not noise the captain can shrug off, it is
    a sentence sending him to look for something that is not there. Erring
    toward "I cannot tell you where" costs him a vaguer sentence and nothing
    else."""
    parents = [parent_path(m) for m in members]
    if not parents or any(p is None for p in parents):
        return None
    if len(set(parents)) == 1:
        return parents[0]
    return lowest_common_ancestor(members) if repeated_family(members) else None


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


# ── what a page DECLARES about its own controls (S213 fix round 1) ───────
def pair_axis(a, b):
    """'row' when these two sit beside each other, 'column' when one is under
    the other — the same test adjacency_gap already makes to decide which gap it
    is measuring, named once so the two cannot drift apart."""
    _, ay1, _, ay2 = edges(a["box"])
    _, by1, _, by2 = edges(b["box"])
    return "row" if min(ay2, by2) - max(ay1, by1) > 0 else "column"


def same_segment(a, b):
    """True when the page DECLARES these two controls to be parts of one
    segmented control — a `role="tablist"` tab bar, a `role="toolbar"`, a
    radiogroup or `<fieldset>` of radios, a menubar, an explicit `role="group"`,
    or a set of controls each carrying `role="tab"` / `aria-selected`.

    THE CAPTAIN'S RULING, 2026-09-17: sibling controls touching inside one of
    those are DELIBERATE — a flush tab bar is a tab bar, not a fault — so they
    are silent whether they touch or sit 4 px apart.

    IT IS A DECLARATION THE BROWSER CAN READ, NEVER A GEOMETRY GUESS. That
    distinction is the whole fix. The round before this one tried to tell
    deliberate spacing from a mistake by comparing a gap with its neighbours'
    rhythm, and INVERTED the detector: on a uniformly tight page 1, 3 and 6 px
    IS the rhythm, so every genuinely cramped pair was forgiven, while the one
    case the captain had exempted — a flush tab bar at 0 px — was the one thing
    that could still fire. A fact the page states about itself cannot invert
    like that: a bar either says it is a tab bar or it does not.

    `segment` is recorded per element by xo-drive.js: the declaring ancestor's
    own DOM path plus what it declared. Two controls are in one segmented
    control when, and only when, those two strings are equal — so a tab bar and
    a separate segmented control 60 px below it never forgive each other."""
    sa, sb = a.get("segment"), b.get("segment")
    return bool(sa) and isinstance(sa, str) and sa == sb


# ── what a layout SPACES on purpose, when nothing was declared (S213 r2) ──
def neighbour_gaps(elements):
    """Every NEIGHBOUR gap on the page, grouped by the layout run it belongs to.

    A RUN is the set of interactive elements that share one container — read off
    the DOM path the driver recorded, a LOOKUP, never inferred from the boxes.
    Its neighbours are the consecutive members along the axis they are laid out
    on, and the gaps between those are the rhythm that container was written to.

    Deliberately NOT keyed on family: a tab bar's selected tab carries a
    different class from its unselected ones, and keying on class would have let
    exactly the tab bar this exists to forgive escape through the gap.

    Returns {(parent, axis): [(id(a), id(b), gap), …]}.
    """
    runs = {}
    inter = [e for e in elements if e.get("interactive") and e.get("box")]
    for e in inter:
        p = parent_path(e)
        if p is None:
            continue
        runs.setdefault(p, []).append(e)
    out = {}
    for parent, members in runs.items():
        if len(members) < 2:
            continue
        for axis, sort_key in (("row", lambda e: e["box"]["x"]),
                               ("column", lambda e: e["box"]["y"])):
            ordered = sorted(members, key=sort_key)
            gaps = []
            for a, b in zip(ordered, ordered[1:]):
                if nested(a, b) or intersects(a["box"], b["box"]):
                    continue
                g = adjacency_gap(a["box"], b["box"])
                if g is None:
                    continue
                if pair_axis(a, b) != axis:
                    continue
                gaps.append((id(a), id(b), g))
            if gaps:
                out[(parent, axis)] = gaps
    return out


def uniform_run(a, b, gap, runs):
    """True when this gap is THE GAP ITS OWN CONTAINER REPEATS — three or more
    neighbours laid out one after another at the same spacing, within a
    measurement tolerance. That is a rhythm somebody wrote, and it is silent
    whatever the number is.

    THE FALSE ALARM THIS CLOSES (measured on a real tile-map editor, S213). A
    seven-row layer rail draws its rows 2 px apart. Under an absolute 8 px floor
    that is six complaints, and not one of them is true: six identical gaps are
    not six mistakes. A list is not a segmented control and never declares
    itself one, so the declaration check above cannot reach it — its own
    repetition is the only evidence there is, and it is enough.

    FIX ROUND 1 DELETED THIS RULE and the rail's false alarm came straight back.
    It is restored BENEATH same_segment, not instead of it, because round 1 was
    right about the other half: the original rule was the ONLY thing between a
    cramped UI and silence, and on its own it inverted the detector. Now it
    forgives one narrow, evidenced thing — repetition — and everything else
    still meets the floor.

    TWO THINGS IT WILL NOT FORGIVE, on purpose:

      · TOUCHING. Zero is not a spacing anybody chooses; it is the absence of
        one, so no amount of evenness earns it. Only a declaration does, which
        is what same_segment is for, and it is the captain's own complaint
        ("buttons that have no spacing between them are smooshed together").
      · A run that DISAGREES WITH ITSELF. One pair at 2 px in a list whose other
        rows sit 12 px apart is not that list's rhythm — it is the one place the
        rhythm breaks — so it fires, and the number it fires with is the 2.

    THE LIMIT, STATED RATHER THAN PAPERED OVER (orchestrator's ruling, S213 fix
    round 2): a run EVERY neighbour of which sits at 1 px reads as rhythm here
    and goes silent. Uniformity cannot tell "tight by design" from "wrong
    everywhere" without a declaration to read, and no number invented here would
    tell them apart either — it would only move which real layouts get shouted
    at. The trade is taken deliberately and pinned by a KNOWN LIMIT test.
    """
    if gap <= 0:
        return False                     # touching is never a rhythm
    run = runs.get((parent_path(a), pair_axis(a, b)))
    if not run or len(run) < 2:
        return False                     # a lone pair has no rhythm to appeal to
    mine = (id(a), id(b))
    others = [g for (ia, ib, g) in run if (ia, ib) != mine and (ib, ia) != mine]
    if not others:
        return False
    if gap < min(others) - RHYTHM_TOL_PX:
        return False                     # tighter than its own neighbours: the break
    every = [g for (_, _, g) in run]
    return max(every) - min(every) <= RHYTHM_TOL_PX


# ── the four detectors ──────────────────────────────────────────────────
def detect_crowding(elements, gap_px):
    """Two controls closer than the floor are crowded — unless one of exactly
    two things says otherwise. THE ORDER OF DECISION, and it is an order:

      1. the page DECLARED them one segmented control (same_segment) — a tab
         bar, a toolbar, a radiogroup. Silent at ANY gap, TOUCHING INCLUDED.
      2. the gap is the one THEIR OWN CONTAINER REPEATS (uniform_run) — three
         or more neighbours at the same spacing. Silent, whatever the number:
         that is the real editor's 2 px layer rail, and a list can never
         declare itself a segmented control, so nothing else would reach it.
      3. otherwise it FIRES, and that covers both the pair measurably tighter
         than its own container's other gaps — the one place a rhythm breaks —
         and the pair with no rhythm to appeal to at all, which is the
         captain's original complaint: two undeclared buttons touching.

    THE FLOOR IS STILL THE FLOOR. Nothing above it is ever looked at. What has
    changed is only which of the pairs BELOW it earn silence, and each of the
    two ways costs evidence — a declaration the browser read, or a repetition
    the container actually shows. Fix round 1 kept only the first and the layer
    rail started shouting again; the round before it kept only the second and a
    cramped page's tightness became its own excuse."""
    out = []
    inter = [e for e in elements if e.get("interactive") and e.get("box")]
    runs = neighbour_gaps(inter)
    for i in range(len(inter)):
        for j in range(i + 1, len(inter)):
            a, b = inter[i], inter[j]
            if nested(a, b):
                continue  # one is INSIDE the other — never a crowding fault
            if intersects(a["box"], b["box"]):
                continue  # that is an OVERLAP, a different finding
            gap = adjacency_gap(a["box"], b["box"])
            if gap is None or gap >= gap_px:
                continue
            # 1. the page's own declaration: parts of one segmented control are
            # MEANT to sit flush. Touching or 4 px apart, a tab bar is a tab bar.
            if same_segment(a, b):
                continue
            # 2. beneath it, and only beneath it: the spacing this container
            # repeats. A seven-row rail at 2 px is that rail's rhythm.
            if uniform_run(a, b, gap, runs):
                continue
            px = max(gap, 0)
            verb = "touching" if px == 0 else "crowded together"
            axis = pair_axis(a, b)
            out.append({
                "kind": "crowding", "px": px, "axis": axis,
                "group": ("crowding", axis)
                         + tuple(sorted((family(a), family(b)))),
                "place": container_of(a, b),
                "members": [a, b],
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
            if nested(a, b):
                continue  # a badge sits inside its button; that is the design
            if not intersects(a["box"], b["box"]):
                continue
            px = overlap_extent(a["box"], b["box"])
            out.append({
                "kind": "overlap", "px": px, "axis": "row",
                "group": ("overlap",)
                         + tuple(sorted((family(a), family(b)))),
                "place": container_of(a, b),
                "members": [a, b],
                "elements": [label(a) or solo(a), label(b) or solo(b)],
                "message": "%s overlap — they share %d px of the same space" % (pair(a, b), px),
            })
    return out


def is_a_column(group):
    """True when this same-tag-same-class group really is a COLUMN — one thing
    under another, every member in its own horizontal band.

    THE BUG THIS CLOSES (S213). "A column" was the detector's whole unstated
    assumption and it was never once checked. On a real tile-map editor, New
    Project and Open Project — two identical buttons SIDE BY SIDE in a header —
    were a same-class group of two, so their left edges were compared as though
    one sat under the other, and the 90 px between them along the row was
    reported as one of them being 90 px out of line. There is no column on that
    screen. It was the most confidently worded sentence in the whole report and
    there was nothing behind it at all.

    Left edges only mean something when there is a stack to line them up
    against. This is the FALLBACK, for a container that declares nothing about
    how it lays its children out; when it does declare (declared_axis), the
    declaration is read instead of this."""
    for i in range(len(group)):
        for j in range(i + 1, len(group)):
            a, b = group[i]["box"], group[j]["box"]
            _, ay1, _, ay2 = edges(a)
            _, by1, _, by2 = edges(b)
            if min(ay2, by2) - max(ay1, by1) > 0:
                return False   # these two sit beside each other, not above
    return True


FLEX_DISPLAY = ("flex", "inline-flex")


def declared_axis(container):
    """'row' or 'column' when the container SAYS how it lays its children out —
    `display:flex` plus its `flex-direction` — and None when it says nothing.

    THE BUG THIS CLOSES (S213 fix round 1). is_a_column correctly killed the
    false positive above, and over-narrowed doing it: a group was only ever
    looked at as a column, so a genuinely misaligned item in a HORIZONTAL row
    drew nothing at all. One button pushed 90 px down its own flex row produced
    zero findings — the detector had gone blind in the shape it was fixed for.
    A cure that trades a false positive for a false negative of the same shape
    is not a cure.

    A row IS checkable; it just is not checkable on left edges. What the row
    declares is which edge it lines its children up on (declared_edge), and
    that is a fact read off the container, not a guess made from the boxes."""
    if not isinstance(container, dict):
        return None
    display = str(container.get("display") or "").strip().lower()
    if display not in FLEX_DISPLAY:
        return None
    direction = str(container.get("flexDirection") or "row").strip().lower()
    return "column" if direction.startswith("column") else "row"


# How a flex container says it lines its children up across the row, mapped to
# the edge that must therefore match. `baseline` is deliberately absent: the
# text baseline is not in the boxes, so a baseline row is one this pass has NO
# OPINION about rather than one it guesses at.
ALIGN_EDGE = {
    "normal": "top", "stretch": "top", "start": "top", "flex-start": "top",
    "self-start": "top", "center": "centre", "safe center": "centre",
    "end": "bottom", "flex-end": "bottom", "self-end": "bottom",
}


def declared_edge(container):
    """The edge a declared ROW lines its children up on, or None for a row that
    says something this pass cannot check (baseline, and anything unknown)."""
    if not isinstance(container, dict):
        return None
    return ALIGN_EDGE.get(str(container.get("alignItems") or "").strip().lower())


def edge_value(box, edge):
    """Where this box sits on the edge the row is aligned on."""
    _, y1, _, y2 = edges(box)
    if edge == "top":
        return y1
    if edge == "bottom":
        return y2
    return (y1 + y2) / 2.0


def opts_out(member, container):
    """True when the member itself declares it is NOT aligned like its
    siblings — `align-self` naming a different edge from the container's
    `align-items` is the author saying so out loud, and an exception somebody
    wrote down is never a fault."""
    own = str(member.get("alignSelf") or "").strip().lower()
    if not own or own == "auto":
        return False
    mine = ALIGN_EDGE.get(own)
    return mine is not None and mine != declared_edge(container)


EDGE_WORD = {"top": "top edge", "centre": "centre", "bottom": "bottom edge"}


def detect_misaligned(elements, threshold):
    """A control that does not line up with its siblings.

    A 'sibling' is anything sharing this element's PARENT, tag and class — a
    repeated row (a list of tasks, a row of buttons) as the DOM itself lays it
    out. Which alignment it is judged on comes from what the container DECLARES
    (declared_axis), and only falls back to the boxes when it declares nothing:

      · a COLUMN lines up on LEFT edges — one row out of true is the fault;
      · a ROW lines up on the edge its `align-items` names — top, centre or
        bottom — and the member that misses that edge is the fault;
      · a row aligned on the text BASELINE, or a container that says nothing
        and whose members sit in no clear stack, gets no opinion at all.
    """
    out = []
    by_path = {}
    for e in elements:
        if isinstance(e.get("path"), str) and e["path"]:
            by_path[e["path"]] = e
    groups = {}
    for e in elements:
        if not e.get("box"):
            continue
        parent = parent_path(e)
        cls = (e.get("className") or "").strip()
        # NO RECORDED PATH — nothing says who these elements' parents are, so
        # the set they belong to is the one it always was before the DOM could
        # be consulted: same tag, same class, anywhere on the page. A class is
        # required there, because without a parent AND without a class there is
        # nothing at all making these a group.
        if parent is None and not cls:
            continue
        groups.setdefault((parent or "", e.get("tag"), cls), []).append(e)
    for (parent, _tag, _cls), group in sorted(groups.items(), key=lambda kv: str(kv[0])):
        if len(group) < 2:
            continue
        container = by_path.get(parent)
        axis = declared_axis(container)
        if axis is None:
            axis = "column" if is_a_column(group) else None
        if axis == "column":
            out.extend(_column_faults(group, threshold))
        elif axis == "row":
            out.extend(_row_faults(group, container, threshold))
    return out


def _column_faults(group, threshold):
    """A stack lines up on its LEFT edges. The baseline is the one most of them
    share; anything that misses it by more than the threshold is the fault."""
    out = []
    xs = [e["box"]["x"] for e in group]
    baseline, _n = Counter(xs).most_common(1)[0]
    for e in sorted(group, key=lambda e: e["box"]["y"]):
        x = e["box"]["x"]
        off = x - baseline
        if abs(off) <= threshold:
            continue
        out.append({
            "kind": "misaligned", "px": abs(off), "axis": "column",
            "group": ("misaligned", family(e)),
            "place": parent_path(e),
            "members": [e],
            "elements": [label(e) or solo(e)],
            "message": "%s does not line up with the rows above it — its "
                       "left edge is %d px %s (%d px vs %d px for the "
                       "others)" % (solo(e), abs(off),
                                    "further right" if off > 0 else "further left",
                                    x, baseline),
        })
    return out


def _row_faults(group, container, threshold):
    """A row lines up on ONE edge, and the row says which: `align-items` top,
    centre or bottom. Members that opt out with their own `align-self` are not
    judged against it, and a row aligned on the text baseline is not judged at
    all — the baseline is not in the boxes."""
    edge = declared_edge(container)
    if edge is None:
        return []
    judged = [e for e in group if not opts_out(e, container)]
    if len(judged) < 2:
        return []
    values = [edge_value(e["box"], edge) for e in judged]
    baseline, _n = Counter(values).most_common(1)[0]
    out = []
    for e in sorted(judged, key=lambda e: e["box"]["x"]):
        off = edge_value(e["box"], edge) - baseline
        if abs(off) <= threshold:
            continue
        out.append({
            "kind": "misaligned", "px": int(round(abs(off))), "axis": "row",
            "group": ("misaligned", family(e)),
            "place": parent_path(e),
            "members": [e],
            "elements": [label(e) or solo(e)],
            "message": "%s does not line up with the rest of its row — its %s "
                       "is %d px %s than the others (%d px vs %d px)"
                       % (solo(e), EDGE_WORD[edge], int(round(abs(off))),
                          "lower" if off > 0 else "higher",
                          int(round(edge_value(e["box"], edge))),
                          int(round(baseline))),
        })
    return out


def detect_clipped(elements, threshold):
    """Text that does not fit the box it is in — UNLESS the box is meant to
    scroll. A box with `overflow: auto` holding more than it shows is not a
    fault, it is the whole point of the box, and the two are indistinguishable
    from the pixel spill alone: both spill the same amount. The computed
    overflow property is what separates them, and `overflow: hidden` with the
    same spill still reports, which is the control.

    The same is true one field along for `text-overflow: ellipsis`, the
    universal idiom for deliberately shortening a long name: the spill is
    identical to a truncation nobody meant, and the computed property is
    again the only thing that tells them apart."""
    out = []
    for e in elements:
        if not (e.get("text") or "").strip():
            continue
        ox = 0 if (scrolls(e, "x") or ellipsized(e)) else (e.get("overflowX") or 0)
        oy = 0 if scrolls(e, "y") else (e.get("overflowY") or 0)
        worst = max(ox, oy)
        if worst <= threshold:
            continue
        out.append({
            "kind": "clipped", "px": worst, "axis": "column",
            "group": ("clipped", family(e)),
            "place": parent_path(e),
            "members": [e],
            "elements": [label(e) or solo(e)],
            "message": "%s text is clipped by its own box — it needs %d px "
                       "more room than the box gives it" % (solo(e), worst),
        })
    return out


# ── saying it once (S212) ────────────────────────────────────────────────
def place_phrase(members):
    """Where these things are — but only when there IS a single where. A group
    that does not all sit in one container has no "this row" to point at, and
    sending the captain to look for a row of eight touching buttons that was
    never on the screen is worse than not naming a place at all.

    AND WHICH WORD, read off the boxes rather than off the crowding axis. The
    axis says which way two controls are crowding each other, which is a
    different question from what the captain is looking at: twenty table rows
    of side-by-side buttons crowd along a row and are plainly a LIST, and
    calling them "this row" invents a place just as surely as naming one that
    is not there. They are a row when every one of them sits in the same
    horizontal band, and a list when they walk down the page."""
    if shared_place(members) is None:
        return "in different parts of the page"
    boxes = [m["box"] for m in members if isinstance(m.get("box"), dict)]
    if len(boxes) > 1:
        band_top = max(b["y"] for b in boxes)
        band_bottom = min(b["y"] + b["h"] for b in boxes)
        if band_bottom <= band_top:
            return "in this list"
    return "in this row"


def group_noun(members, axis):
    """What to call a handful of the same thing. Their own kind when they all
    share one and it is a real word — buttons, links, fields — and otherwise
    the layout word a person would reach for."""
    kinds = set(kind_word(e) for e in members)
    if len(kinds) == 1:
        k = kinds.pop()
        if k != "control":
            return plural(k)
    return "rows" if axis == "column" else "items"


def and_list(names):
    """'Edit and Delete', 'Edit, Copy and Delete' — the way a person says it."""
    if len(names) == 2:
        return "%s and %s" % (names[0], names[1])
    return "%s and %s" % (", ".join(names[:-1]), names[-1])


def repeated_labels(members):
    """THE SHAPE THE CAPTAIN WOULD RECOGNISE, when the group has one: the
    names that repeat, identically, in every single unit of a repeated
    family.

    "38 buttons in this list are touching — 0 px between them" is a number
    with no story. It was TWENTY ROWS, each with its own Edit and Delete, and
    what a person would say is that every row's Edit and Delete buttons are
    touching. The count stays in the record for the ranking to read; the
    SENTENCE describes the shape.

    THE NAMES ONLY. Whether "every" can be said about them is a separate
    question, asked of the whole family in `family_census` — this says what
    the affected units are called, not how many of its kind there are.

    Claimed only where the shape is not in doubt: the units must stand in one
    column, and every one of them must carry the same names in the same
    reading order. Anything less and the counted sentence is the honest one —
    three bars holding A0/B0, A1/B1 and A2/B2 have no name in common to put
    in a sentence, so they keep their count."""
    units = repeated_family(members)
    if not units:
        return None
    corners = [unit_corner(u) for u in units]
    if len(set(c[0] for c in corners)) != 1 or len(set(c[1] for c in corners)) < 2:
        return None                    # not a column of units: no "every row"
    names = None
    for unit in units:
        ordered = sorted(unit, key=lambda m: (m["box"]["y"], m["box"]["x"]))
        these = [label(m) for m in ordered]
        if len(these) < 2 or any(not n for n in these):
            return None
        if len(set(these)) != len(these):
            return None                # "Edit and Edit" names nothing
        if names is None:
            names = these
        elif these != names:
            return None
    return names


def family_census(members, elements, names):
    """HOW MANY UNITS OF THIS FAMILY ARE ON THE PAGE, beside how many of them
    this note is about — the two numbers the word "every" has to be measured
    against.

    THIS IS ROUND 5'S CURE, and the defect it exists for was the tester's:
    eight list rows, the first three with their Edit and Delete touching and
    the last five comfortably spaced, read as "every row's Edit and Delete
    buttons are touching" with five well-spaced rows on the screen in the same
    glance. Every check in front of that word looked at the AFFECTED units —
    same column, same names, same reading order — and not one of them asked
    whether the rest of the list was affected at all.

    "Every" is a claim about the WHOLE family, so the whole family has to be
    counted: the units are the siblings under the one container that holds
    them, and a sibling is a unit of this family when it carries these same
    names in this same order. Where the census cannot account for the page —
    no container to count under, or fewer units found than the note is about —
    the total comes back unknown and the sentence COUNTS rather than claims.
    Only a census that adds up can license the word.

    A story with a false number is worse than a number with no story. The
    round-4 sentence was the second; this is what keeps it from becoming the
    first."""
    units = repeated_family(members)
    if not units:
        return None
    lca = lowest_common_ancestor([m for unit in units for m in unit])
    if not lca:
        return (len(units), None)
    siblings = {}
    for e in elements:
        if not isinstance(e.get("box"), dict):
            continue
        p = parent_path(e)
        if p and "." in p and p.rsplit(".", 1)[0] == lca:
            siblings.setdefault(p, []).append(e)
    total = 0
    for kids in siblings.values():
        ordered = sorted(kids, key=lambda m: (m["box"]["y"], m["box"]["x"]))
        if [label(m) for m in ordered if label(m) in names] == names:
            total += 1
    # A census that cannot account for the units it was handed has not
    # counted the family, and says so rather than guessing low.
    return (len(units), total if total >= len(units) else None)


def fold(bucket, elements=()):
    """Turn N notes saying one thing into ONE note that names the count.

    Five rows in a list, each 6 px from the next, is five notes today and one
    fact — and five identical sentences is how a reader learns to skip the
    section. The count is the information; the repetition is not."""
    first = bucket[0]
    kind = first["kind"]
    axis = first.get("axis") or "column"
    members, seen_already = [], set()
    for o in bucket:
        for m in o.get("members") or []:
            if id(m) not in seen_already:
                seen_already.add(id(m))
                members.append(m)
    n = len(members) or len(bucket)
    noun = group_noun(members, axis)
    where = place_phrase(members)
    pxs = [o.get("px") or 0 for o in bucket]
    lo, hi = min(pxs), max(pxs)
    span = lo == hi
    # THE SHAPE FIRST, WHERE THERE IS ONE (S212 round 4). A repeated family
    # whose units all carry the same names is described, not counted.
    names = repeated_labels(members) if kind in ("crowding", "overlap") else None
    # AND ONLY THEN THE WORD "EVERY" — once the rest of the family has been
    # counted and every one of them really is affected. Three rows out of
    # eight are three rows, and say so; the counted sentence is the same
    # shape, so he reads the same story either way, with the true number in
    # it (S212 round 5).
    census = family_census(members, elements, names) if names else None
    if census and census[1] == census[0]:
        who = "every row's %s %s" % (and_list(names), noun)
    elif census:
        who = "%s rows' %s %s" % (count_word(census[0]), and_list(names), noun)
    else:
        who = None
    if who and kind == "crowding":
        if span and lo == 0:
            msg = "%s are touching — 0 px between them" % who
        elif span:
            msg = "%s sit %d px apart" % (who, lo)
        else:
            msg = "%s sit between %d and %d px apart" % (who, lo, hi)
    elif who:
        msg = ("%s overlap each other — they share %s of the same space"
               % (who, ("%d px" % hi) if span else ("between %d and %d px" % (lo, hi))))
    elif kind == "crowding":
        if span and lo == 0:
            msg = "%s %s %s are touching — 0 px between them" % (count_word(n), noun, where)
        elif span:
            msg = "%s %s %s sit %d px apart" % (count_word(n), noun, where, lo)
        else:
            msg = "%s %s %s sit between %d and %d px apart" % (count_word(n), noun, where, lo, hi)
    elif kind == "overlap":
        msg = ("%s %s %s overlap each other — they share %s of the same space"
               % (count_word(n), noun, where,
                  ("%d px" % hi) if span else ("between %d and %d px" % (lo, hi))))
    elif kind == "misaligned":
        msg = ("%s %s %s do not line up with the others — their left edges are %s off"
               % (count_word(n), noun, where,
                  ("%d px" % hi) if span else ("between %d and %d px" % (lo, hi))))
    else:  # clipped
        msg = ("%s %s %s have text clipped by their own boxes — each needs %s "
               "more room than its box gives it"
               % (count_word(n), noun, where,
                  ("%d px" % hi) if span else ("between %d and %d px" % (lo, hi))))
    return {
        "kind": kind,
        # KEPT, not dropped: `publish` strips these before the captain ever
        # sees them, and keeping them is what lets a folded note be folded
        # again — the last resort below, where two notes would otherwise read
        # the same word for word.
        "members": members,
        "axis": axis,
        "place": first.get("place"),
        "px": lo if kind == "crowding" else hi,
        # THE SAME NUMBER THE SENTENCE SAYS. It used to be len(bucket) — the
        # number of PAIRS — while the sentence counted the elements, so a note
        # reading "five rows" carried `count: 4` and contradicted itself in
        # the captain's own record.
        "count": n,
        "elements": [label(m) or solo(m) for m in members][:8],
        "message": msg,
    }


def members_of(bucket):
    """Every element the notes in this bucket are about, once each."""
    members, seen = [], set()
    for o in bucket:
        for m in o.get("members") or []:
            if id(m) not in seen:
                seen.add(id(m))
                members.append(m)
    return members


def by_place(bucket):
    """The bucket split into the places its notes DO share, in order. The
    fallback when no one place holds the whole group: a tab bar and a
    segmented control stay two facts rather than becoming one row that is not
    on the screen."""
    order, subs = [], {}
    for o in bucket:
        k = o.get("place")
        if k not in subs:
            order.append(k)
            subs[k] = []
        subs[k].append(o)
    return [subs[k] for k in order]


def say_it_once(obs, elements=()):
    """THE LAST RESORT, and an invariant rather than a special case: two notes
    that read the same word for word are one fact printed twice. The captain
    reading the same sentence three times under a cap line is the exact noise
    the collapse exists to prevent, so if two notes would render identically,
    that is proof they should have folded — whatever the grouping thought."""
    order, same = [], {}
    for o in obs:
        msg = o.get("message")
        if msg not in same:
            order.append(msg)
            same[msg] = []
        same[msg].append(o)
    return [same[m][0] if len(same[m]) == 1 else fold(same[m], elements)
            for m in order]


def collapse(obs, elements=()):
    """Group the findings that are the same fault about the same family of
    thing, and fold any group of COLLAPSE_AT or more into one note. Two of a
    kind stay two notes — a collapse that swallows a genuine second fault is
    the quietening this session is trying not to cause.

    A group folds when there is ONE PLACE that holds all of it (see
    `shared_place`). When there is not, it is split into the places it does
    share and each of those is considered on its own."""
    order, buckets = [], {}
    for o in obs:
        key = o.get("group")
        if key is None:
            order.append(None)
            buckets.setdefault(None, []).append(o)
            continue
        if key not in buckets:
            order.append(key)
            buckets[key] = []
        buckets[key].append(o)
    out = []
    for key in order:
        if key is None:
            continue
        bucket = buckets[key]
        if len(bucket) < COLLAPSE_AT:
            out.extend(bucket)
        elif shared_place(members_of(bucket)) is not None:
            out.append(fold(bucket, elements))
        else:
            for sub_bucket in by_place(bucket):
                out.extend(sub_bucket if len(sub_bucket) < COLLAPSE_AT
                           else [fold(sub_bucket, elements)])
    out.extend(buckets.get(None, []))
    return say_it_once(out, elements)


def noticeability(o, gap_px):
    """HOW MUCH OF THE PAGE THIS FAULT ACTUALLY SPOILS, in pixels a person
    would notice — the thing "the three worst" has to be measured against.

    One currency, because these have to be compared with each other:
      clipped     the px of text that are not on the screen at all
      misaligned  the px the row is out of true
      overlap     the px two controls are sitting in each other's space
      crowding    the px of space that are MISSING — a 0 px gap is the whole
                  threshold missing, a 7 px gap is 1 px missing. Crowding is
                  inherently a small-magnitude fault and now reads as one.
    Then multiplied by how many things it is about: six names cut off mid-word
    is six times the fault one is.

    A name cut off mid-word (120 px x 6) outranks two buttons 1 px apart
    (1 px missing x 1), which is the whole point — and among crowded pairs the
    tightest is still the worst, which is how it always behaved."""
    kind = o.get("kind")
    px = o.get("px") or 0
    n = o.get("count") or 1
    span = max(1, gap_px - px) if kind == "crowding" else max(1, px)
    return span * n


def severity(o, gap_px):
    """Worst first, for when only a few can be printed: most noticeable first,
    then the old kind order and the count purely so that two findings of equal
    weight never swap places between runs."""
    return (-noticeability(o, gap_px), KIND_RANK.get(o.get("kind"), 9),
            -(o.get("count") or 1))


INTERNAL = ("group", "members", "axis", "place")


def publish(o):
    return {k: v for k, v in o.items() if k not in INTERNAL}


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

    # WHICH SCREEN THIS IS (S220 part D). The observations pass used to run
    # ONCE, on the landing page, and the record said nothing about where it
    # had looked — so on 2026-09-19 it reported "112 elements, 0 findings" from
    # the Default view and never ran again on the six MBR screens the look
    # walked to. Now it runs after every round, each finding carries the screen
    # it was seen on, and the record lists every screen it has run on.
    merge = "--merge" in argv
    screen = flag_str(argv, "screen", "")

    doc = load(inpath) or {}
    # ONE READING PER SCREEN, WHEN THE DRIVER TOOK ONE (S220 part D carry-over).
    # `readouts.json` carries every screen the look stood on; `readout.json`
    # carries only the last. Either is accepted, and a file with several
    # screens in it is measured screen by screen, each finding naming its own.
    pages = doc.get("pages") if isinstance(doc, dict) else None
    if isinstance(pages, list) and pages:
        readings = []
        for pg in pages:
            if not isinstance(pg, dict):
                continue
            readings.append((str(pg.get("url") or ""), pg.get("page") if isinstance(pg.get("page"), dict) else pg))
    else:
        readings = [(screen or str((doc or {}).get("url") or
                     ((doc or {}).get("page") or {}).get("url") or ""),
                     doc.get("page") if isinstance(doc, dict) else None)]

    all_obs, all_notes, all_screens = [], [], []
    total_found = total_elements = total_unseen = 0
    for screen_at, page in readings:
      if True:
        elements = (page or {}).get("elements") if isinstance(page, dict) else None
        elements = elements if isinstance(elements, list) else []
        elements = [e for e in elements if isinstance(e, dict) and isinstance(e.get("box"), dict)]

        # NEVER MEASURE WHAT CANNOT BE SEEN (S212). A row its container has
        # scrolled away and a button behind an opaque modal backdrop both still
        # have a box, and reporting either is reporting something nobody can look
        # at. The driver recorded the answer; this is the one place it is applied,
        # so every detector below inherits it.
        unseen = len(elements)
        elements = [e for e in elements if can_be_seen(e)]
        unseen -= len(elements)

        obs = (detect_crowding(elements, gap_px) + detect_overlap(elements) +
               detect_misaligned(elements, misalign_px) + detect_clipped(elements, overflow_px))

        obs = collapse(obs, elements)
        found = len(obs)

        notes = []
        if len(obs) > OBS_HANDFUL:
            ranked = sorted(obs, key=lambda o: severity(o, gap_px))
            held = len(obs) - OBS_CAP
            obs = ranked[:OBS_CAP]
            notes.append("This page has a lot going on — here are the %s worst. "
                         "I held back %d more." % (count_word(OBS_CAP), held))
        obs = [publish(o) for o in obs]
        # EVERY FINDING NAMES ITS SCREEN. A list of layout faults across six
        # screens with no screen on them is a list nobody can act on.
        if screen_at:
            for o in obs:
                o["screen"] = screen_at

        all_obs.extend(obs)
        all_notes.extend(notes)
        total_found += found
        total_elements += len(elements)
        total_unseen += unseen
        if screen_at and screen_at not in all_screens:
            all_screens.append(screen_at)

    obs, notes, found = all_obs, all_notes, total_found
    elements = [None] * total_elements
    unseen = total_unseen
    screen = all_screens[0] if all_screens else screen
    out = {
        "thresholds": {"gapPx": gap_px, "misalignPx": misalign_px, "overflowPx": overflow_px},
        "elementCount": len(elements),
        "unseenCount": unseen,
        # What it FOUND, beside what it chose to print. The cap must never be
        # able to make a busy page look like a quiet one in the record.
        "foundCount": found,
        "observations": obs,
        "notes": notes,
        "screens": all_screens or ([screen] if screen else []),
    }

    # ADDED TO WHAT IS ALREADY THERE, when the caller is walking (--merge).
    # The same fault on the same screen is not two faults, so a finding
    # already recorded for this screen is not added twice.
    if merge:
        prev = load(outpath)
        if isinstance(prev, dict):
            old = [o for o in (prev.get("observations") or []) if isinstance(o, dict)]
            keys = set((str(o.get("screen") or ""), str(o.get("says") or o.get("text") or
                        json.dumps(o, sort_keys=True))) for o in old)
            fresh = [o for o in out["observations"]
                     if (str(o.get("screen") or ""),
                         str(o.get("says") or o.get("text") or
                             json.dumps(o, sort_keys=True))) not in keys]
            out["observations"] = old + fresh
            out["foundCount"] = int(prev.get("foundCount") or len(old)) + found
            out["elementCount"] = int(prev.get("elementCount") or 0) + len(elements)
            out["unseenCount"] = int(prev.get("unseenCount") or 0) + unseen
            out["notes"] = (prev.get("notes") or []) + out["notes"]
            seen_screens = [s for s in (prev.get("screens") or []) if s]
            for sc in out["screens"]:
                if sc and sc not in seen_screens:
                    seen_screens = seen_screens + [sc]
            out["screens"] = seen_screens
    os.makedirs(os.path.dirname(os.path.abspath(outpath)) or ".", exist_ok=True)
    with open(outpath, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")
    print("%d observation(s) from %d element(s)%s"
          % (len(obs), len(elements),
             ("" if found == len(obs) else " (%d found, %d held back)"
              % (found, found - len(obs)))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
