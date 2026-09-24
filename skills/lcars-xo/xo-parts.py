#!/usr/bin/env python3
"""SIDE BY SIDE, PART BY PART — Session 220, parts B and C.

WHY THIS EXISTS. On 2026-09-19 Number One looked straight at four buttons
whose icon spilled past the control and whose label had wrapped onto three
lines, and graded every one of them "worked" — in shots it took itself, with
the oversized icons in frame. It had asked "is there a button with that
label?" and answered from the build alone. Nobody ever put the drawing's
button next to the build's button at the same scale; the orchestrator did that
by hand and saw it in a second.

So this module does two things, and neither of them is a verdict:

  `pair`      pairs every part of the DRAWING with the element that is that
              part in the BUILD — recording WHICH handle matched — and takes
              a few cheap measurements of the two boxes. The pair of pictures
              and the measurements are handed to the look as EVIDENCE. The
              outcome is still the look's, with the default-fail stance.
              (The captain's standing rule, S212: a detector that fires on
              correct UI teaches him to ignore the whole feature.)

  `criteria`  turns every drawn part into its own requirement, so "matches the
              mock-up" can never again be ONE row covering twelve parts, one
              holistic "looks right" hiding four broken buttons.

WHICH MEASUREMENTS FIRE, AND WHY ONLY THOSE. Measured on the S220 benchmark,
over the four known-broken controls and the correct ones beside them:

  icon-bigger-than-its-control   separated all four faults from the correct
                                 control with NO overlap.               FIRES
  label-wraps-more-than-drawn    likewise, and the drawing's own line count
                                 is what makes it safe: a label the drawing
                                 ALSO wraps is not a fault.             FIRES
  size-delta                     did NOT separate them. The CORRECT control
                                 had the LARGEST delta of the lot (-16.5%),
                                 so a threshold here cries wolf on the one
                                 thing that was right.     RECORDED, NEVER FIRES
  colour / position delta        recorded for the same reason and with the
                                 same standing: a drawing is a drawing, not a
                                 pixel spec, and the look can see colour and
                                 corner for itself in the pair.
                                                           RECORDED, NEVER FIRES

A measurement that never fires is still WORTH RECORDING: it is a number
beside the two pictures, and the look may cite it either way.

MATCHING IS BY HANDLE, AND THE HANDLE IS NAMED. `data-testid` is a project
convention, not a guarantee (the S220 benchmark's drawing has twelve `id=`s
and the build has NONE of them), so the handles are tried in order —
data-testid, id, accessible name, label text, a role with exactly one
candidate — and the one that matched is written down, because "matched by
role, last resort" and "matched by test id" are not the same evidence.

A part the build has not got is COULDN'T CHECK (UNREACHABLE) — never
"worked". So is a part whose box has no size: a control 0px wide is a control
nobody can look at, not a crop that went wrong.

Usage:
  xo-parts.py pair --drawing <parts.json> --build <parts.json> [--build …]
                   --out <pairs.json>
  xo-parts.py criteria [--drawing <parts.json>] --criteria <criteria.json>
                       --out <criteria.json> [--cap N]
  xo-parts.py touched --walk <walk.json> --build <build-parts.json> [--build …]
                      --criteria <criteria.json> --out <criteria.json>
  xo-parts.py scan --build <build-parts.json> [--build …] --out <fragment.json>
"""

import json
import os
import re
import sys

# The most parts one drawing may put on the contract. The real benchmark
# carries 79 criteria already; twelve more is a long list and a readable one,
# forty would be a wall. Past the cap the parts are kept in `pairs.json` (so
# the look still gets the pictures) and the contract says how many were held.
PART_CRITERIA_CAP = 14

# The catch-all this retires. Only a SHORT row that is nothing but "it matches
# the drawing" is retired outright — a long PRD paragraph that happens to
# mention the mock-up is carrying content the per-part rows do not cover, so
# it stays, with a line saying the parts below now carry its visual parity.
CATCH_ALL = re.compile(
    r"(match(es|ing)?|visual parity with|looks? like|faithful to|as (per|in))\s+"
    r"(the\s+)?(mock ?-?up|mock|drawing|design|holodeck)", re.I)
CATCH_ALL_MAX = 160


def load(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None


def parts_of(doc, controls_only=False):
    """Every part the reader recorded — or only the CONTROLS, when asked.

    WHY THE FILTER EXISTS, measured on the S220 fixture: the reader records a
    section with an id as a part, and a section's text is every control's
    label glued together. Pairing one produced "the entry section runs onto 11
    lines in the build where your drawing has 10" — a sentence about nothing,
    which the benchmark then scored as a FALSE ALARM against the correct tab
    bar named inside it. A part earns a requirement of its own when it is
    something a person CLICKS or READS, not when it is the box those sit in.

    A drawing's annotations ("SCREEN ONE — the entry screen") are dropped by
    the same rule: they are prose the drawing writes about itself, they carry
    no id, and nobody built them."""
    if not isinstance(doc, dict):
        return []
    p = doc.get("parts")
    out = [x for x in p if isinstance(x, dict)] if isinstance(p, list) else []
    if not controls_only:
        return out
    keep = []
    for x in out:
        if x.get("container"):
            continue
        if x.get("interactive"):
            keep.append(x)
            continue
        if x.get("id") or x.get("testid"):
            keep.append(x)
    return keep


def norm(s):
    """A name, as a person would hear it: case, punctuation and runs of space
    are not what makes two labels the same thing."""
    return re.sub(r"[^a-z0-9 ]+", " ", str(s or "").lower()).strip()


def squash(s):
    return re.sub(r"\s+", " ", norm(s))


def box_of(p):
    b = p.get("box")
    return b if isinstance(b, dict) else {}


def has_size(p):
    b = box_of(p)
    try:
        return float(b.get("w") or 0) > 0 and float(b.get("h") or 0) > 0
    except Exception:
        return False


# ── the match ──────────────────────────────────────────────────────────────

def other_names(p):
    """The names a control has BESIDE its accessible one, squashed.

    WHY (S224 item 1, measured on the S222 capstone). `nameOf` in the reader
    returns the ACCESSIBLE name and aria-label wins it outright. The build
    labels its status selects "Status for LTC P75" and its insight boxes
    "Insight for LTC P75"; the holodeck drawing is plain HTML with no aria, so
    it names the very same controls by what is PRINTED on them ("On
    trackWatchOff track") or by their placeholder ("Add an insight for this
    KPI…"). Both ends compared accessible names only, so ten controls that
    were on the screen came back "I could not find it in the build".
    """
    out = []
    for k in ("text", "placeholder", "value", "title", "alt"):
        s = squash(p.get(k))
        if s and s not in out:
            out.append(s)
    return out


def match(drawn, candidates):
    """The build element that IS this drawn part, and the handle that found
    it. Handles in order of how much they prove; None when nothing matched."""
    dname = squash(drawn.get("name"))
    dtest = str(drawn.get("testid") or "").strip()
    did = str(drawn.get("id") or "").strip()
    drole = str(drawn.get("role") or drawn.get("tag") or "").strip().lower()

    if dtest:
        for c in candidates:
            if str(c.get("testid") or "").strip() == dtest:
                return c, "data-testid"
    if did:
        for c in candidates:
            if str(c.get("id") or "").strip() == did:
                return c, "id"
            # A project that uses test ids often names them after the drawing's
            # id, hyphenated. Same handle, said differently.
            if squash(c.get("testid")).replace(" ", "") == squash(did).replace(" ", "") \
               and str(c.get("testid") or "").strip():
                return c, "data-testid"
    if dname:
        for c in candidates:
            if squash(c.get("name")) == dname:
                return c, "accessible name"
        # The build's label starting with the drawing's (an added count, a
        # trailing glyph) is still that control — but only when it is the only
        # one, or the shortest such label would be a coin toss.
        starts = [c for c in candidates
                  if squash(c.get("name")).startswith(dname) or
                  dname.startswith(squash(c.get("name")) or "\0")]
        if len(starts) == 1:
            return starts[0], "label text"
        # A WHOLE-WORD RUN of the drawn name inside a build label is that
        # control: "Unlock" is the "Unlock month" button. This generalises the
        # literal-prefix handle above to a run in the MIDDLE or at the END of
        # the label, but keeps a word BOUNDARY — "Lock" is letters inside
        # "Unlock", not a word of it, and must not pair; "Month view" shares
        # the word "month" with "Unlock month" but is not a contiguous run of
        # its words, and must not pair either. Fenced to ONE candidate for the
        # same reason the prefix is: when the run is in two labels equally,
        # pairing an arbitrary one is worse than not pairing.
        dwords = dname.split()

        def _run_in(hay):
            hw = squash(hay).split()
            n = len(dwords)
            return n > 0 and any(hw[i:i + n] == dwords
                                 for i in range(len(hw) - n + 1))
        runs = [c for c in candidates if _run_in(c.get("name"))]
        if len(runs) == 1:
            return runs[0], "the drawn name is a whole-word run of the label"
        # THE CONTROL'S OTHER NAMES (S224 item 1). EXACT equality only — a
        # whole printed label or a whole placeholder matching is not a coin
        # toss, and anything looser here is how a leftover control answers for
        # a part the build has not got. The drawn part's own other names are
        # tried too, because which end carries the aria-label is an accident
        # of which end a person hand-wrote.
        dalts = other_names(drawn)
        for c in candidates:
            calts = other_names(c)
            if dname in calts:
                return c, "the text on the control"
            if calts and squash(c.get("name")) in dalts:
                return c, "the text on the control"
            if dalts and set(dalts) & set(calts):
                return c, "the text on the control"
    # ROLE IS THE LAST HANDLE, AND IT IS FENCED. "the only button on the
    # screen" is a real match; "the only button left over" is how a drawn part
    # the build simply has not got gets paired with an unrelated control and
    # reported as present. So the role handle needs the labels to share a word
    # as well — the fence that stopped Export CSV matching Save reading.
    if drole:
        same = [c for c in candidates
                if str(c.get("role") or c.get("tag") or "").lower() == drole]
        if len(same) == 1 and dname:
            words = set(dname.split()) & set(squash(same[0].get("name")).split())
            if words:
                return same[0], "role (the only %s on the screen)" % drole
        elif len(same) == 1 and not dname:
            return same[0], "role (the only %s on the screen)" % drole
    return None, None


# ── the measurements ───────────────────────────────────────────────────────

def pct(a, b):
    try:
        return (float(a) - float(b)) / float(b) * 100.0
    except Exception:
        return 0.0


def measure(drawn, built):
    """Cheap, deterministic, and every one of them EVIDENCE, never a verdict."""
    out = []
    db, bb = box_of(drawn), box_of(built)

    ic = built.get("iconBox")
    if isinstance(ic, dict) and bb.get("h"):
        try:
            ratio = float(ic.get("h") or 0) / float(bb.get("h") or 1)
        except Exception:
            ratio = 0.0
        fires = ratio > 1.0
        out.append({
            "id": "icon-bigger-than-its-control",
            "fires": bool(fires),
            "ratio": round(ratio, 2),
            "says": ("the icon inside it is %dpx tall in a %dpx %s — %.2fx the control, "
                     "so it spills past the top and bottom edges"
                     % (ic.get("h") or 0, bb.get("h") or 0,
                        built.get("tag") or "control", ratio)) if fires else
                    ("the icon inside it is %dpx tall in a %dpx control (%.2fx) — it fits"
                     % (ic.get("h") or 0, bb.get("h") or 0, ratio)),
        })

    dl, bl = drawn.get("lines"), built.get("lines")
    if isinstance(dl, int) and isinstance(bl, int) and dl > 0 and bl > 0:
        fires = bl > dl
        out.append({
            "id": "label-wraps-more-than-drawn",
            "fires": bool(fires),
            "drawnLines": dl, "builtLines": bl,
            "says": ("the label runs onto %d lines in the build where your drawing has %d"
                     % (bl, dl)) if fires else
                    ("the label is on %d line%s in both" % (bl, "" if bl == 1 else "s")),
        })

    if db.get("w") and bb.get("w"):
        dw, dh = pct(bb.get("w"), db.get("w")), pct(bb.get("h"), db.get("h") or 1)
        out.append({
            "id": "size-delta",
            # NEVER FIRES, on purpose and on evidence — see the module note.
            "fires": False,
            "widthPct": round(dw, 1), "heightPct": round(dh, 1),
            "says": ("it is %.0f%% %s and %.0f%% %s than the drawing's box "
                     "(recorded, not a fault on its own — a drawing is not a pixel spec)"
                     % (abs(dw), "wider" if dw >= 0 else "narrower",
                        abs(dh), "taller" if dh >= 0 else "shorter")),
        })

    dc, bc = str(drawn.get("background") or ""), str(built.get("background") or "")
    if dc and bc and dc != bc:
        out.append({
            "id": "colour-delta", "fires": False,
            "drawn": dc, "built": bc,
            "says": "your drawing fills it %s; the build fills it %s (recorded — look and judge)"
                    % (dc, bc),
        })

    if db.get("x") is not None and bb.get("x") is not None:
        out.append({
            "id": "position-delta", "fires": False,
            "drawn": {"x": db.get("x"), "y": db.get("y")},
            "built": {"x": bb.get("x"), "y": bb.get("y")},
            "says": "drawn at x=%s y=%s, built at x=%s y=%s (recorded — the corner is yours to judge)"
                    % (db.get("x"), db.get("y"), bb.get("x"), bb.get("y")),
        })
    return out


UNREACHABLE = "couldn't check (unreachable)"


def pair_all(drawing, builds):
    """One entry per drawn part. Nothing is dropped and nothing is assumed."""
    drawn_parts = parts_of(drawing, controls_only=True)
    candidates = []
    screens = []
    for b in builds:
        url = str((b or {}).get("url") or "")
        # A build reading may carry MANY screens (`pages`), because the look
        # walks. Every screen it stood on is a place a drawn part may live —
        # pairing against only the screen the round ended on is how 59 of 65
        # real parts were reported "not in the build" while they were two
        # clicks back.
        pages = (b or {}).get("pages")
        pages = pages if isinstance(pages, list) and pages else [{"url": url, "parts": (b or {}).get("parts") or []}]
        for pg in pages:
            at = str((pg or {}).get("url") or url)
            if at and at not in screens:
                screens.append(at)
            for c in parts_of(pg, controls_only=True):
                c = dict(c)
                c["_screen"] = c.get("screen") or at
                candidates.append(c)

    # ONE DRAWN PART KEY IS ONE ENTRY (S224 item 1).
    #
    # MEASURED ON THE S222 CAPSTONE (mission lcars-20260920-001-8cb0). A
    # holodeck drawing is ONE long page with every screen stacked down it, so
    # "Cancel", "View", "Lock month" and "Discard draft" are each drawn twice
    # — once on the screen and once in a modal. The first instance paired; the
    # second found nothing left to claim and became "couldn't check
    # (unreachable)". Downstream, pairs are keyed by the part's name, so the
    # LAST entry won and the unreachable-part guard blanked four criteria
    # about controls that were right there on his screen: "your drawing names
    # this part and I could not find it in the build."
    #
    # A drawn part key already carries ONE requirement (see part_criteria —
    # the key is the same), so a second entry under the same key was never
    # anything but a second answer to one question. The FIRST instance is the
    # entry, and since same-key instances match identically it is the one with
    # first pick of the candidates — the one that finds the control if the
    # build has it at all. How many times the drawing drew it is kept as
    # `drawnTimes`, because that is a fact about the drawing worth reading.
    by_key = []
    seen_keys = {}
    for d in drawn_parts:
        k = str(d.get("id") or d.get("testid") or squash(d.get("name")) or "part")
        if k in seen_keys:
            by_key[seen_keys[k]][1] += 1
            continue
        seen_keys[k] = len(by_key)
        by_key.append([d, 1])

    pairs = []
    # ONE BUILD ELEMENT ANSWERS FOR ONE DRAWN PART. Without this a single
    # leftover button answers for every part the build is missing.
    claimed = set()
    for d, drawn_times in by_key:
        free = [c for c in candidates if id(c) not in claimed]
        # A CONTROL YOU CAN SEE BEATS ONE YOU CANNOT (S224 item 1).
        #
        # MEASURED IN REAL HEADLESS CHROME on a four-screen SPA that hides its
        # screens with `display:none`: 72 of the 100 parts the reader recorded
        # had a 0x0 box, because the computed display of a button INSIDE a
        # hidden section is still "inline-flex" — only the section itself
        # reads "none", so every control on every screen that is not showing
        # is recorded with no box at all. Those come first in document order,
        # so the hidden "Cancel" claimed the name and the REAL Cancel two
        # clicks into the walk was never reached: seven controls that were on
        # the captain's screen read "it is in the build but it has no
        # laid-out box".
        #
        # So the laid-out candidates are tried first, and the rest only when
        # nothing laid out answers — which keeps "it is in the build but there
        # is nothing to look at" for the case where that is the whole truth.
        sized = [c for c in free if has_size(c)]
        built, handle = match(d, sized)
        if built is None:
            built, handle = match(d, free)
        if built is not None:
            claimed.add(id(built))
        entry = {
            "part": d.get("id") or d.get("testid") or squash(d.get("name")) or "part",
            "name": d.get("name") or "",
            "drawn": {"box": box_of(d), "lines": d.get("lines"),
                      "crop": d.get("crop"), "iconBox": d.get("iconBox")},
        }
        if drawn_times > 1:
            entry["drawnTimes"] = drawn_times
        if built is None:
            entry.update({
                "reachable": False, "outcome": UNREACHABLE, "handle": None,
                "screen": None, "built": None, "measurements": [],
                "why": "your drawing names this part; I could not find it anywhere I looked, "
                       "by test id, by id, by its label or by its role",
            })
            pairs.append(entry)
            continue
        if not has_size(built):
            entry.update({
                "reachable": False, "outcome": UNREACHABLE, "handle": handle,
                "screen": built.get("_screen"), "measurements": [],
                "built": {"box": box_of(built), "lines": built.get("lines"),
                          "crop": built.get("crop"), "iconBox": built.get("iconBox")},
                "why": "it is in the build but it has no laid-out box (%sx%s), so there is "
                       "nothing to look at" % (box_of(built).get("w"), box_of(built).get("h")),
            })
            pairs.append(entry)
            continue
        ms = measure(d, built)
        entry.update({
            "reachable": True, "outcome": "", "handle": handle,
            "screen": built.get("_screen"),
            "built": {"box": box_of(built), "lines": built.get("lines"),
                      "crop": built.get("crop"), "iconBox": built.get("iconBox"),
                      "name": built.get("name")},
            "measurements": ms,
            "measuredDifference": any(m.get("fires") for m in ms),
        })
        pairs.append(entry)

    return {
        "drawing": (drawing or {}).get("url") or "",
        "screens": screens,
        "partCount": len(by_key),
        "drawnParts": len(drawn_parts),
        "matched": sum(1 for p in pairs if p.get("reachable")),
        "unreachable": sum(1 for p in pairs if not p.get("reachable")),
        "measuredDifferences": sum(1 for p in pairs if p.get("measuredDifference")),
        "stance": ("These are MEASUREMENTS, not verdicts. Look at the two pictures and "
                   "say what you see; if a measurement is wrong about this control, say "
                   "why and overrule it — that is recorded too."),
        "pairs": pairs,
    }


# ── one requirement per drawn part (part C) ────────────────────────────────

def part_criteria(drawing, cap=PART_CRITERIA_CAP):
    rows, held, keys = [], 0, set()
    for d in parts_of(drawing, controls_only=True):
        key = d.get("id") or d.get("testid") or squash(d.get("name"))
        if not key:
            continue
        # ONE KEY, ONE REQUIREMENT (S224 item 1). A drawing that stacks every
        # screen on one page draws "Cancel" twice, and two rows with the SAME
        # id are one question asked twice — on the S222 capstone one of the
        # fourteen slots under the cap was spent on a duplicate `part-view`.
        if str(key) in keys:
            continue
        keys.add(str(key))
        if len(rows) >= cap:
            held += 1
            continue
        name = str(d.get("name") or "").strip()
        kind = str(d.get("role") or d.get("tag") or "part").lower()
        if kind in ("a",):
            kind = "link"
        if kind in ("p", "div", "span"):
            kind = "part"
        what = ('the "%s" %s' % (name[:60], kind)) if name else ("the %s %s" % (key, kind))
        rows.append({
            "id": "part-%s" % key,
            "text": "%s matches the drawing — same icon size, same label on the same "
                    "number of lines, same place" % what,
            "source": "drawing",
            "primary": True,
            "drawnAt": key,
            "drawnPart": key,
        })
    return rows, held


def apply_criteria(contract, drawing, cap=PART_CRITERIA_CAP):
    rows, held = part_criteria(drawing, cap) if drawing else ([], 0)
    if not rows:
        return contract, 0, 0, held
    kept, retired = [], 0
    for c in contract.get("criteria") or []:
        text = str(c.get("text") or "")
        if CATCH_ALL.search(text) and len(text) <= CATCH_ALL_MAX:
            # THE CATCH-ALL IS RETIRED, NOT DELETED. It is kept in the record
            # with the reason, so nobody reading the contract later thinks a
            # requirement went missing.
            c = dict(c)
            c["retired"] = ("superseded by %d per-part requirements — one holistic "
                            "'looks right' is how four broken buttons passed" % len(rows))
            retired += 1
            contract.setdefault("retiredCriteria", []).append(c)
            continue
        if CATCH_ALL.search(text):
            c = dict(c)
            c["partsCover"] = ("the per-part requirements below carry this row's visual "
                               "parity; judge the rest of it on its own words")
        kept.append(c)
    contract["criteria"] = kept + rows
    contract["drawnParts"] = len(rows)
    if held:
        contract["drawnPartsHeld"] = held
    return contract, len(rows), retired, held


# ── THE CONTROL THAT DOES NOT FIT ITSELF (S220 parts D/F) ──────────────────
#
# A pairing needs a DRAWN counterpart, and the four broken buttons on the real
# benchmark included one — "Back to builder" — on a screen the drawing never
# drew. Nothing that compares two pictures can ever reach it. But an icon
# TALLER THAN THE BUTTON IT SITS IN is wrong with no drawing at all: no mockup
# is needed to say that a 41px glyph does not belong inside a 30px control.
#
# So this is the one measurement taken on the build ALONE, on every screen the
# look stands on. It is deliberately narrow — the icon's own box against its
# control's own box, both read from the browser — because the wide version of
# this idea (a label on two lines) has a legitimate reason to be true, and the
# fixture's deliberately two-line notice is there to punish anyone who forgets
# it.
ICON_MARGIN_PX = 2          # a hairline over is rounding, not a fault
ICON_OVER_RATIO = 1.05      # …and on a small control, 2px has to also be 5%
MAX_CONTROL_PX = 220        # past this it is a panel, not a control


def oversized_icons(builds):
    seen, out = set(), []
    for doc in builds:
        for p in parts_of(doc, controls_only=True):
            if not p.get("interactive"):
                continue
            b, icon = box_of(p), p.get("iconBox")
            if not isinstance(icon, dict) or not b or not b.get("h"):
                continue
            ih, iw = float(icon.get("h") or 0), float(icon.get("w") or 0)
            h, w = float(b.get("h") or 0), float(b.get("w") or 0)
            if h <= 0 or h > MAX_CONTROL_PX:
                continue
            over_h = ih - h
            over_w = iw - w
            tall = over_h >= ICON_MARGIN_PX and ih >= h * ICON_OVER_RATIO
            wide = w > 0 and over_w >= ICON_MARGIN_PX and iw >= w * ICON_OVER_RATIO
            if not tall and not wide:
                continue
            # THE LABEL AS IT IS PRINTED, not a squashed key: the captain
            # reads this sentence, and "Pull data & start" is what is on his
            # screen. squash() is for MATCHING two records to each other; it is
            # not how a control is named to a person.
            name = re.sub(r"\s+", " ", str(p.get("name") or "")).strip() \
                or str(p.get("id") or p.get("tag") or "control")
            screen = str(p.get("screen") or doc.get("url") or "")
            key = (name.lower(), screen)
            if key in seen:
                continue
            seen.add(key)
            kind = str(p.get("role") or p.get("tag") or "control").lower()
            where = (" on %s" % screen) if screen else ""
            out.append({
                "says": 'the "%s" %s%s holds an icon %dpx tall inside a control only '
                        '%dpx tall — the icon is bigger than the button it sits in%s'
                        % (name[:60], kind, where, round(ih), round(h),
                           (", and its label runs onto %d lines" % int(p.get("lines") or 0))
                           if int(p.get("lines") or 0) > 1 else ""),
                "screen": screen,
                "kind": "oversized-icon",
                "measured": {"controlHeightPx": round(h), "iconHeightPx": round(ih),
                             "controlWidthPx": round(w), "iconWidthPx": round(iw),
                             "labelLines": p.get("lines")},
                "part": p.get("id") or name,
            })
    return out


# ── THE CONTROL THE WALK CLICKED, DRAWN OR NOT (S225) ──────────────────────
#
# WHY THIS EXISTS, in the captain's words. His "Back to builder" button wraps
# onto three lines. The walk clicked it, confirmed it RETURNED, scored that row
# `met` — and had the picture on disk the whole time. It was asked whether the
# button WORKED. Nobody asked whether it LOOKED right, because his drawing does
# not name that control, so no row existed to hold it to.
#
# `pair_all`/`part_criteria` start from `parts_of(drawing, controls_only=True)`
# — every entry is keyed off the DRAWING's own `id=` vocabulary. A control the
# walk clicked that the drawing never named gets no pair, no measurement and no
# criterion, so no fault can ever be filed for it. This path is the missing
# join, PARALLEL to the pairing: it is driven by walk.json (the controls the
# walk actually clicked) against the full build inventory (`build-parts-*.json`
# — every control on every screen the walk visited, with its box, its icon box
# and its label's line count), and it files a fault against a touched control
# WHETHER OR NOT THE DRAWING NAMED IT.
#
# THE STANDARD WITHOUT A DRAWN BASELINE. The pairing's `label-wraps-more-than-
# drawn` compares the built line count against the DRAWING's — safe, because a
# label the drawing ALSO wraps is not a fault. A touched-but-undrawn control
# has no drawn baseline, so that comparison is impossible. But a person CLICKED
# this: it is a real control, not a prose paragraph (a `<p>` notice) that may
# legitimately run long — and the walk only ever clicks controls. So the
# standard here is the control's OWN label on THREE OR MORE lines, which is
# exactly the "Back to builder" fault and needs no mock-up to call wrong. TWO
# lines is deliberately allowed: a two-line button is a real design, and firing
# on one is the S212 sin (a detector that cries wolf on correct UI teaches the
# captain to ignore the whole feature). The icon check is the pairing's own
# `icon-bigger-than-its-control`, which reads the built element ALONE and so
# needs no drawing at all.
#
# LIKE `oversized_icons`, THIS ONLY FILES FAULTS. A touched control that is
# correct gets measured and produces no row — the "second question" is asked of
# every clicked control, but a contract row (a thing the captain must
# adjudicate) is filed only when a measurement finds a fault to answer for.

TOUCHED_MAX_LINES = 2       # a real control's own label past two lines is wrong


def steps_of(walk):
    if not isinstance(walk, dict):
        return []
    s = walk.get("steps")
    return [x for x in s if isinstance(x, dict)] if isinstance(s, list) else []


def touched_controls(walk):
    """The controls the walk ACTUALLY clicked — the name it matched and the
    screen it was standing on when it clicked. A step counts only when it was a
    CLICK that landed on a named control: a type, a key press or a refused
    click never touched a control to look at. De-duplicated by (name, screen),
    because clicking the same control twice is one control to measure."""
    out, seen = [], set()
    for st in steps_of(walk):
        do = str(st.get("do") or "click").lower()
        if do != "click":
            continue
        landed = bool(st.get("clicked")) or (
            st.get("status") == "done" and st.get("matched"))
        if not landed:
            continue
        raw = st.get("matched") or (st.get("match") or [None])[0]
        name = squash(raw)
        if not name:
            continue
        screen = str(st.get("urlBefore") or st.get("urlAfter") or "")
        key = (name, screen)
        if key in seen:
            continue
        seen.add(key)
        out.append({"name": name, "display": str(raw), "screen": screen})
    return out


def inventory(builds):
    """Every control on every screen the walk visited, flattened, each carrying
    the screen it is on. `build-parts-*.json` writes both `pages` and a flat
    `parts` (each with its own `screen`); either is read the same way."""
    cands = []
    for b in builds:
        url = str((b or {}).get("url") or "")
        pages = (b or {}).get("pages")
        if isinstance(pages, list) and pages:
            for pg in pages:
                at = str((pg or {}).get("url") or url)
                for c in parts_of(pg, controls_only=True):
                    c = dict(c)
                    c["_screen"] = c.get("screen") or at
                    cands.append(c)
        else:
            for c in parts_of(b, controls_only=True):
                c = dict(c)
                c["_screen"] = c.get("screen") or url
                cands.append(c)
    return cands


def find_touched(name, screen, candidates):
    """The inventory control that IS the one the walk clicked. By its name, or
    one of its other names; the copy ON THE SCREEN IT WAS CLICKED and with a
    laid-out box wins, for the same reason the pairing prefers a sized
    candidate — a 0x0 copy on a hidden screen is not the one that was seen."""
    nm = squash(name)

    def is_it(c):
        return squash(c.get("name")) == nm or nm in other_names(c)
    hits = [c for c in candidates if is_it(c)]
    if not hits:
        return None
    here = [c for c in hits if c.get("_screen") == screen and has_size(c)]
    if here:
        return here[0]
    sized = [c for c in hits if has_size(c)]
    if sized:
        return sized[0]
    return hits[0]


def measure_touched(built):
    """The second question, taken on the built control ALONE. Icon in
    proportion (the pairing's own check, which never needed a drawing); label
    inside its box, judged against the control's own standard because there is
    no drawn baseline to judge against."""
    out = []
    bb = box_of(built)

    ic = built.get("iconBox")
    if isinstance(ic, dict) and bb.get("h"):
        try:
            ratio = float(ic.get("h") or 0) / float(bb.get("h") or 1)
        except Exception:
            ratio = 0.0
        fires = ratio > 1.0
        out.append({
            "id": "icon-bigger-than-its-control",
            "fires": bool(fires),
            "ratio": round(ratio, 2),
            "says": ("the icon inside it is %dpx tall in a %dpx %s — %.2fx the control, "
                     "so it spills past the top and bottom edges"
                     % (ic.get("h") or 0, bb.get("h") or 0,
                        built.get("tag") or "control", ratio)) if fires else
                    ("the icon inside it is %dpx tall in a %dpx control (%.2fx) — it fits"
                     % (ic.get("h") or 0, bb.get("h") or 0, ratio)),
        })

    bl = built.get("lines")
    if isinstance(bl, int) and bl > 0:
        fires = bl > TOUCHED_MAX_LINES
        out.append({
            "id": "label-wraps-or-clips",
            "fires": bool(fires),
            "builtLines": bl,
            "standard": TOUCHED_MAX_LINES,
            "says": ("its label runs onto %d lines — a control's own label past %d is "
                     "wrapping or clipped, no mock-up needed to see it"
                     % (bl, TOUCHED_MAX_LINES)) if fires else
                    ("its label is on %d line%s, within a control's own budget of %d"
                     % (bl, "" if bl == 1 else "s", TOUCHED_MAX_LINES)),
        })
    return out


def touched_report(walk, builds):
    """The touched pass as a WHOLE: the rows it faults AND a tally of the effort
    it made. The captain's cure for the lazy reviewer — silence must not read
    the same as work. So alongside the fault rows we count, honestly:
      clicked         — controls the walk actually touched (distinct)
      examined        — of those, the ones we could measure (in the inventory
                        with a laid-out box)
      faulted         — of the examined, the ones a measurement faulted; equals
                        the number of rows filed
      couldNotExamine — clicked but NOT measurable (missing from the inventory,
                        or present with no box); NEVER folded into "examined"
    By construction clicked == examined + couldNotExamine. Rows are counted,
    not manufactured: a clean control adds to `examined`, never a "this was
    fine" row, so the verdict is not drowned."""
    cands = inventory(builds)
    clicked = touched_controls(walk)
    rows, keys = [], set()
    examined = 0
    for ctl in clicked:
        built = find_touched(ctl["name"], ctl["screen"], cands)
        # Not in the inventory, or in it with no laid-out box, is COULDN'T-CHECK,
        # not a fault — there is nothing to look at, so no row is filed and it is
        # recorded as couldNotExamine (clicked - examined), never as fine.
        if built is None or not has_size(built):
            continue
        examined += 1
        ms = measure_touched(built)
        if not any(m.get("fires") for m in ms):
            continue
        key = str(built.get("id") or built.get("testid")
                  or squash(built.get("name")) or ctl["name"])
        if key in keys:
            continue
        keys.add(key)
        name = re.sub(r"\s+", " ", str(built.get("name") or ctl["display"] or "")).strip()
        kind = str(built.get("role") or built.get("tag") or "control").lower()
        what = ('the "%s" %s' % (name[:60], kind)) if name else ("the %s %s" % (key, kind))
        rows.append({
            "id": "touched-%s" % key,
            "text": "%s you clicked sits right — the label inside its box, the icon in "
                    "proportion, nothing wrapping or clipped (the walk clicked it, so it "
                    "is held to the mock-up's standard even though the drawing never "
                    "named it)" % what,
            "source": "touched",
            "primary": True,
            "touchedControl": key,
            "screen": built.get("_screen"),
            "measurements": ms,
            "measuredDifference": True,
        })
    tally = {
        "clicked": len(clicked),
        "examined": examined,
        "faulted": len(rows),
        "couldNotExamine": len(clicked) - examined,
    }
    return rows, tally


def touched_criteria(walk, builds):
    """One requirement per touched control that a measurement faulted — source
    `touched`, distinct from prd/plan/drawing/journey so a downstream score can
    move these rows by changing one mapping. Thin wrapper over
    `touched_report`, which also carries the effort tally."""
    rows, _tally = touched_report(walk, builds)
    return rows


def apply_touched(contract, walk, builds):
    """Append the touched rows to the contract, skipping any id it already
    carries, and ALWAYS record the effort tally on the contract as
    `touchedCheck` — even when nothing faulted, so the verdict can tell "looked
    at N, all fine" from "never looked at a control". Returns the enriched
    contract, the number of NEW rows added, and the tally."""
    rows, tally = touched_report(walk, builds)
    contract["touchedCheck"] = tally
    have = {str(c.get("id")) for c in (contract.get("criteria") or [])}
    rows = [r for r in rows if r["id"] not in have]
    if rows:
        contract["criteria"] = (contract.get("criteria") or []) + rows
        contract["touchedParts"] = contract.get("touchedParts", 0) + len(rows)
    return contract, len(rows), tally


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__.split("Usage:")[-1])
        return 2
    cmd = argv[1]

    def opt(name, default=None):
        try:
            return argv[argv.index("--" + name) + 1]
        except (ValueError, IndexError):
            return default

    def opts(name):
        out, i = [], 0
        while i < len(argv):
            if argv[i] == "--" + name and i + 1 < len(argv):
                out.append(argv[i + 1])
                i += 1
            i += 1
        return out

    out_path = opt("out")
    if not out_path:
        sys.stderr.write("xo-parts.py: --out is required\n")
        return 2

    if cmd == "pair":
        drawing = load(opt("drawing") or "") or {}
        builds = [load(p) or {} for p in opts("build")]
        doc = pair_all(drawing, builds)
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
        print("%d drawn part(s): %d matched, %d unreachable, %d with a measured difference"
              % (doc["partCount"], doc["matched"], doc["unreachable"],
                 doc["measuredDifferences"]))
        return 0

    if cmd == "scan":
        builds = [load(p) or {} for p in opts("build")]
        obs = oversized_icons(builds)
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump({"observations": obs}, fh, indent=2)
            fh.write("\n")
        print("%d control(s) hold an icon bigger than themselves" % len(obs))
        return 0

    if cmd == "criteria":
        cpath = opt("criteria")
        contract = load(cpath or "")
        if not isinstance(contract, dict):
            sys.stderr.write("xo-parts.py: cannot read the criteria list\n")
            return 2
        drawing = load(opt("drawing") or "") if opt("drawing") else None
        try:
            cap = int(opt("cap") or PART_CRITERIA_CAP)
        except Exception:
            cap = PART_CRITERIA_CAP
        contract, added, retired, held = apply_criteria(contract, drawing, cap)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(contract, fh, indent=2)
            fh.write("\n")
        print("%d per-part requirement(s) added, %d catch-all row(s) retired%s"
              % (added, retired, (", %d part(s) held back (cap %d)" % (held, cap)) if held else ""))
        return 0

    if cmd == "touched":
        cpath = opt("criteria")
        contract = load(cpath or "")
        if not isinstance(contract, dict):
            sys.stderr.write("xo-parts.py: cannot read the criteria list\n")
            return 2
        walk = load(opt("walk") or "") or {}
        builds = [load(p) or {} for p in opts("build")]
        contract, added, tally = apply_touched(contract, walk, builds)
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(contract, fh, indent=2)
            fh.write("\n")
        print("%d control(s) clicked, %d examined, %d faulted, %d could not be examined "
              "(%d requirement(s) added)"
              % (tally["clicked"], tally["examined"], tally["faulted"],
                 tally["couldNotExamine"], added))
        return 0

    sys.stderr.write("xo-parts.py: unknown command %r\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
