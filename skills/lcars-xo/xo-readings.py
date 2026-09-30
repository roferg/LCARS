#!/usr/bin/env python3
"""xo-readings.py — THE SAME PLACE, READ AT EVERY MOMENT OF THE WALK.

    python3 xo-readings.py <walk.json> <out readings.json>

WHY THIS EXISTS (S224 fix round 3).

A walk is not one picture, it is a sequence of them. A criterion about
something that is on the screen the whole way through therefore has several
moments it could be judged at — and the look judges it at ONE, whichever
picture it reached for. Measured on the captain's own build: a row was graded
"worked" against a late picture, while the walk's own record shows the very
same strip of the page reading differently at the first three moments. The
fault was never invisible. It was photographed, walked past, and then graded
from a later moment in which it had already gone away.

That is not "a model cannot see". It is a criterion settled on one moment of
several, and the moments are all sitting in the record already: the driver
writes the whole page's text before and after every step it takes.

So this pass does one thing and no more: for each screen the walk was on more
than once, it lines the captures up in order and writes down every PLACE whose
words read differently from one moment to the next — the first reading, every
later one, and which moment each came from.

IT JUDGES NOTHING. There is no fault in a value that changes: a counter that
counts is doing its job, and a detector that called that a fault would be
crying wolf over correct behaviour — the failure mode that teaches him to
ignore the channel. What a changed reading means is the eye's to say. This
file's whole contribution is to make sure the eye is looking at all of them
instead of one.

NOTHING HERE NAMES ANYTHING. No element, no wording, no shape of value, no app.
A reading is "the words at this position differed between two captures of the
same address", and that sentence is true of a screen nobody has ever seen.
"""

import difflib
import json
import os
import sys

# How many words of the unchanged text after a differing run are kept, so a
# reading is quotable rather than a bare token. Three is enough to make "4" into
# "4 of 5 buckets" and not so many that a quote has to be word-perfect to match.
CONTEXT = 3
# Two differing runs this close together are one place on the screen, not two.
MERGE = 4
# A run longer than this is a whole region redrawn, not a value that changed;
# quoting it would be quoting the page.
MAX_RUN = 12


def norm(s):
    return " ".join(str(s or "").split())


def captures(walk):
    """(address, [(moment, text), …]) for every address the walk was on, in the
    order it saw them. The driver's own record, read and not re-derived: each
    step carries the whole page's text before it acted and after it acted."""
    order, by = [], {}
    steps = [s for s in (walk or {}).get("steps") or [] if isinstance(s, dict)]
    for s in steps:
        key = str(s.get("key") or "")
        for url, text, moment in (
                (s.get("urlBefore"), s.get("textBefore"), "%s/before" % key),
                (s.get("urlAfter"), s.get("textAfter"), "%s/after" % key)):
            url, text = str(url or ""), norm(text)
            if not url or not text:
                continue
            if url not in by:
                by[url] = []
                order.append(url)
            row = (moment, text)
            # The same text twice running is the same moment said twice; it is
            # the CHANGES that are the point.
            if by[url] and by[url][-1][1] == text:
                continue
            by[url].append(row)
    return [(u, by[u]) for u in order]


def regions(first_moment, first_text, later):
    """Places in `first_text` that read differently in one of `later`.

    Every comparison is against the FIRST capture, so a place keeps one identity
    however many times it changes and the earliest reading is always the anchor.
    """
    a = first_text.split()
    found = {}
    order = []
    for moment, text in later:
        b = text.split()
        ops = [o for o in difflib.SequenceMatcher(None, a, b, autojunk=False)
               .get_opcodes() if o[0] == "replace"]
        merged = []
        for op in ops:
            if merged and op[1] - merged[-1][2] <= MERGE:
                m = merged[-1]
                merged[-1] = ("replace", m[1], op[2], m[3], op[4])
            else:
                merged.append(tuple(op))
        for _, i1, i2, j1, j2 in merged:
            if i1 == i2 or j1 == j2:
                continue
            if i2 - i1 > MAX_RUN or j2 - j1 > MAX_RUN:
                continue
            was = " ".join(a[i1:i2 + CONTEXT])
            now = " ".join(b[j1:j2 + CONTEXT])
            if not was or not now or was == now:
                continue
            key = (i1, i2)
            if key not in found:
                found[key] = {"first": {"moment": first_moment, "reads": was},
                              "later": []}
                order.append(key)
            seen = set(r["reads"] for r in found[key]["later"])
            if now not in seen:
                found[key]["later"].append({"moment": moment, "reads": now})
    return [found[k] for k in order]


def readings_from_walk(walk):
    """The whole record: one entry per place that read differently, with the
    address it was on. Empty when nothing on any screen ever changed — which is
    the ordinary case and must read as "nothing to say", never as a finding."""
    out = []
    for url, caps in captures(walk):
        if len(caps) < 2:
            continue
        first_moment, first_text = caps[0]
        for r in regions(first_moment, first_text, caps[1:]):
            r = dict(r)
            r["screen"] = url
            out.append(r)
    return out


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: xo-readings.py <walk.json> <out readings.json>\n")
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    try:
        with open(src, encoding="utf-8", errors="replace") as fh:
            walk = json.load(fh)
    except Exception:
        # BEST-EFFORT, like every other pass here. No walk, an unreadable walk,
        # a walk from a driver that wrote nothing — each leaves no file and the
        # look finishes exactly as it would have.
        return 0
    if not isinstance(walk, dict):
        return 0
    found = readings_from_walk(walk)
    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump({"readings": found}, fh, indent=2)
        fh.write("\n")
    sys.stdout.write("%d\n" % len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
