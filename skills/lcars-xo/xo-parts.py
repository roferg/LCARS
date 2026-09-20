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

    pairs = []
    # ONE BUILD ELEMENT ANSWERS FOR ONE DRAWN PART. Without this a single
    # leftover button answers for every part the build is missing.
    claimed = set()
    for d in drawn_parts:
        built, handle = match(d, [c for c in candidates if id(c) not in claimed])
        if built is not None:
            claimed.add(id(built))
        entry = {
            "part": d.get("id") or d.get("testid") or squash(d.get("name")) or "part",
            "name": d.get("name") or "",
            "drawn": {"box": box_of(d), "lines": d.get("lines"),
                      "crop": d.get("crop"), "iconBox": d.get("iconBox")},
        }
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
        "partCount": len(drawn_parts),
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
    rows, held = [], 0
    for d in parts_of(drawing, controls_only=True):
        key = d.get("id") or d.get("testid") or squash(d.get("name"))
        if not key:
            continue
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

    sys.stderr.write("xo-parts.py: unknown command %r\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
