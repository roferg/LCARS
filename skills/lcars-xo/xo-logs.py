#!/usr/bin/env python3
"""xo-logs.py — turn the Verify look's CONTRADICTIONS into bug PRDs.

    python3 xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir> [cap]

S203's verdict carries two kinds of gap. A **contradiction** is the build
disagreeing with something the captain wrote down, and it always has evidence:
either a picture (the score step demotes a contradiction with no shot to an
interpretation, so a bare one cannot reach here) or — since S211 — a quoted
line from the project's own failing test suite, which is what proves a
criterion that had no visual surface to photograph. An **interpretation** is a
call the build made where the record is silent — reported to the captain,
never filed against the build.

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

Output on stdout, one record per line, for the shell. The fields are separated
by ASCII US (0x1f), NOT by a tab:

    GAP <n> <prd-path> <shot-path,shot-path> <criterion> <title>
    OVERFLOW <how-many-were-not-filed>

WHY NOT A TAB (S211 fix round 1, D2). TAB IS IFS WHITESPACE, so `IFS=$'\t'
read -r …` COLLAPSES a run of tabs: a record whose shots field is empty loses
that field entirely and every field after it shifts left by one. Before S211 a
contradiction with no shot could not exist — the score step demoted it to an
interpretation — so the empty field was unreachable; `tests_back_it` opened the
door and `xo/logs.json` immediately recorded criterion="batches do not survive a
restart", title="", and the captain's filing readout printed `log #2` with no
title at all. US has no such rule: empty fields survive and the split is
positional. This is the same cure `lcars status` took for the same class in
S207 R4, and it is the reason this constant exists in both this file and
`xo-held.py` rather than a tab being typed twice.

The shell consumes GAP lines in order to build ONE `log.sh` invocation whose
`--attach` arguments sit AFTER the `--prd` they belong to, which is what binds
a shot to its own bug rather than to every bug.
"""
import json
import os
import re
import sys

CAP = 10

# THE RECORD SEPARATOR. ASCII US (0x1f) — not a tab. See the module docstring:
# a tab is IFS whitespace and silently eats an empty field.
RS = "\x1f"


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
        print("MALFORMED" + RS + "the verdict could not be read (%s)" % exc)
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
            # THE FAILING TEST LINE, WHEN THAT IS WHAT FOUND IT (S211). A gap a
            # screenshot could never have shown is proven by the project's own
            # suite instead, and the line it printed is the single most useful
            # thing a fix worker can be handed. Read off the recorded `evidence`
            # field, never guessed from the prose — the same rule as `kind`.
            quote = ""
            if str(g.get("evidence") or "") == "tests":
                quote = clean(g.get("testQuote"))
                if quote:
                    w("This one did not come from a picture — it came from the project's\n"
                      "own test suite, which said:\n\n> %s\n\n" % quote)
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
            # THIS LINE USED TO BE UNCONDITIONAL (S211 fix round 1, D6), and it
            # sat directly under "There is no shot for this one." A gap the
            # project's own tests found has no visual surface by definition —
            # that is WHY the suite had to answer it — so telling a fix worker
            # the fix is "visible on the same screen the shot above was taken
            # of" points it at a screen that does not exist and invites it to
            # build one: a parallel dead control beside the real thing. That is
            # the exact class CONTEXT.md → *Grounding* exists to kill. So the
            # sentence is now conditional on there BEING a shot, and a
            # test-sourced bug is anchored the only way it honestly can be — to
            # the code the failing test already exercises.
            if shots:
                w("- The fix is visible on the same screen the shot above was taken of.\n")
            elif quote:
                w("- The test that reported this now passes, and the fix is in the code\n"
                  "  that test already exercises — not in a new path built beside it.\n")

        print(RS.join(["GAP", str(n), path,
                       ",".join(os.path.join(shotsdir, s + ".png") for s in shots),
                       cid, title]))

    if overflow:
        print("OVERFLOW" + RS + str(overflow))
    return 0


if __name__ == "__main__":
    sys.exit(main())
