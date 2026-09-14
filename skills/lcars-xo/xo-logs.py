#!/usr/bin/env python3
"""xo-logs.py — turn the Verify look's CONTRADICTIONS into bug PRDs.

    python3 xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir> [cap]

S203's verdict carries two kinds of gap. A **contradiction** is the build
disagreeing with something the captain wrote down, and it has a picture (the
score step demotes a contradiction with no shot to an interpretation, so one
cannot reach here). An **interpretation** is a call the build made where the
record is silent — reported to the captain, never filed against the build.

ONLY CONTRADICTIONS ARE FILED. That is the whole selection rule, and it is read
off the recorded `kind` field rather than guessed from the prose, for the same
reason the gate's `kind` is recorded rather than matched.

THE CAP IS TEN (captain's ruling). Eleven gaps file ten and say so; the
overflow is never silently dropped.

Each bug PRD is written in the house shape `log.sh` requires — a
`# Mission:` title line and a `**Type:** bug` line — and says three things a
fix worker needs: what was expected and where that expectation is written, what
was actually seen and in which shot, and an acceptance criterion that is the
original criterion restated. Nothing is invented here: every sentence is
assembled from fields the verdict already carries.

Output on stdout, one TAB-separated record per line, for the shell:

    GAP <n> <prd-path> <shot-path,shot-path> <criterion> <title>
    OVERFLOW <how-many-were-not-filed>

The shell consumes GAP lines in order to build ONE `log.sh` invocation whose
`--attach` arguments sit AFTER the `--prd` they belong to, which is what binds
a shot to its own bug rather than to every bug.
"""
import json
import os
import re
import sys

CAP = 10


def clean(s):
    return " ".join(str(s or "").split())


def unstop(s):
    """A fragment that the template will punctuate. One full stop, not two."""
    return re.sub(r"[.\s]+$", "", clean(s))


def criterion_text(criteria, cid):
    """The criterion as the CONTRACT states it — not as the worker paraphrased
    it. The acceptance line on the bug is the captain's own sentence, so a fix
    worker is judged against the record and not against a judge's summary."""
    try:
        with open(criteria, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return "", ""
    rows = doc.get("criteria") if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        return "", ""
    for c in rows:
        if isinstance(c, dict) and str(c.get("id") or "") == cid:
            return clean(c.get("text")), clean(c.get("source") or c.get("where"))
    return "", ""


def criterion_place(criteria, cid):
    """The element the criterion was DRAWN at, as a bare `#id`.

    `criteria.json` carries `drawnAt` verbatim off the plan ("#add-button,
    beneath the task list"), so the id is pulled out of it rather than assumed
    to be the whole field."""
    try:
        with open(criteria, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return ""
    rows = doc.get("criteria") if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        return ""
    for c in rows:
        if isinstance(c, dict) and str(c.get("id") or "") == cid:
            return hash_id(c.get("drawnAt"))
    return ""


def hash_id(text):
    m = re.search(r"#([A-Za-z][\w:.-]*)", str(text or ""))
    return "#" + m.group(1) if m else ""


def shot_selector(shotsdir, name):
    """The element this shot was CLIPPED to, or "" for a picture of the whole
    page. The driver writes it into the `.json` readout beside every PNG
    (`selector`, with `clip` set to the box it used), so this is read off the
    record of the shot and never guessed from its name."""
    try:
        with open(os.path.join(shotsdir, name + ".json"), encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return ""
    if not isinstance(doc, dict):
        return ""
    sel = clean(doc.get("selector"))
    clip = doc.get("clip")
    if sel and clip and clip != "full-page":
        return sel
    return ""


def shot_of_place(shotsdir, place, prefer_prefix=""):
    """The shot taken OF this element, out of the look's own directory."""
    if not place:
        return ""
    try:
        names = sorted(fn[:-5] for fn in os.listdir(shotsdir)
                       if fn.endswith(".json") and fn != "readout.json")
    except Exception:
        return ""
    found = [n for n in names if shot_selector(shotsdir, n) == place]
    if not found:
        return ""
    if prefer_prefix:
        for n in found:
            if n.startswith(prefer_prefix):
                return n
    return found[0]


def bind_shots(shotsdir, shots, place):
    """THE PICTURE THAT ACTUALLY SHOWS THE GAP GOES FIRST (fix round 2, D3).

    Number One took `shot-03` of the header alone and `shot-06` of the add row
    alone — exactly the per-gap evidence — and then put `shot-01`, the 2880px
    full page, on BOTH bug issues, byte-for-byte identical. A fix worker sent to
    mend the header count arrived holding a picture of the whole screen.

    So: the element's own shot leads, whether the look cited it or not; any
    other clipped shot follows; the full page comes last. It ACCOMPANIES the
    close-up — never replaces it — because the full page is what shows where on
    the screen the close-up came from.
    """
    prefix = shots[0].rsplit("-", 1)[0] if shots else ""
    ordered = []
    own = shot_of_place(shotsdir, place, prefix)
    if own:
        ordered.append(own)
    for s in shots:
        if s not in ordered and shot_selector(shotsdir, s):
            ordered.append(s)
    for s in shots:
        if s not in ordered:
            ordered.append(s)
    return ordered


def main():
    if len(sys.argv) < 5:
        print("usage: xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir> [cap]",
              file=sys.stderr)
        return 2
    vpath, cpath, outdir, shotsdir = sys.argv[1:5]
    cap = int(sys.argv[5]) if len(sys.argv) > 5 else CAP

    try:
        with open(vpath, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print("MALFORMED\tthe verdict could not be read (%s)" % exc)
        return 0

    gaps = doc.get("gaps") if isinstance(doc, dict) else None
    gaps = [g for g in gaps if isinstance(g, dict)] if isinstance(gaps, list) else []
    real = [g for g in gaps if str(g.get("kind") or "").strip().lower() == "contradiction"]

    overflow = max(0, len(real) - cap)
    real = real[:cap]

    os.makedirs(outdir, exist_ok=True)
    for n, g in enumerate(real, 1):
        cid = clean(g.get("criterion"))
        ctext, csource = criterion_text(cpath, cid)
        shots = [clean(s) for s in (g.get("shots") or []) if clean(s)]
        # WHICH PICTURE GOES ON THIS BUG (fix round 2, D3). The place the
        # criterion was drawn at, else the first `#id` the finding itself names.
        place = criterion_place(cpath, cid) or hash_id(
            " ".join([str(g.get("title") or ""), str(g.get("expected") or ""),
                      str(g.get("saw") or "")]))
        shots = bind_shots(shotsdir, shots, place)
        title = clean(g.get("title")) or (ctext or cid or "a mismatch against the record")
        expected = unstop(g.get("expected")) or unstop(ctext) or "what the record says"
        saw = unstop(g.get("saw")) or "something else"
        # WHERE the expectation is written. `criteria.json` records it; when it
        # does not, the criterion id is named rather than a source invented.
        where = csource or (cid or "the record")
        shot_phrase = ", ".join(shots) if shots else "no shot"

        path = os.path.join(outdir, "%d.md" % n)
        with open(path, "w", encoding="utf-8") as fh:
            w = fh.write
            w("# Mission: %s\n\n" % title)
            w("**Type:** bug\n\n")
            w("## What is wrong\n\n")
            w("Expected %s, per %s; saw %s (%s).\n\n" % (expected, where, saw, shot_phrase))
            if ctext:
                w("The criterion this is judged against, in full:\n\n> %s\n\n" % ctext)
            w("## Where to look\n\n")
            if shots:
                w("Number One's shots of the running build: %s. Each PNG has a `.json`\n"
                  "readout beside it (url, visible text, the box and computed colour of\n"
                  "every element the drawing names) and a `.txt` caption.\n\n"
                  % ", ".join(shots))
                # WHICH ONE IS THE CLOSE-UP. Named, so the fix worker opens the
                # picture of the thing rather than the picture of the screen.
                lead = shot_selector(shotsdir, shots[0])
                if lead:
                    w("`%s` is the close-up of `%s` — that is the one that shows this.\n\n"
                      % (shots[0], lead))
            else:
                w("There is no shot for this one.\n\n")
            w("## Acceptance criteria\n\n")
            w("- %s\n" % (ctext or expected))
            w("- The fix is visible on the same screen the shot above was taken of.\n")

        print("GAP\t%d\t%s\t%s\t%s\t%s" % (
            n, path,
            ",".join(os.path.join(shotsdir, s + ".png") for s in shots),
            cid, title))

    if overflow:
        print("OVERFLOW\t%d" % overflow)
    return 0


if __name__ == "__main__":
    sys.exit(main())
