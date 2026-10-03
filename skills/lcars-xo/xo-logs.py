#!/usr/bin/env python3
"""xo-logs.py — turn what the Verify look MEASURED into evidence-first bug PRDs.

    python3 xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir>
                        [cap] [logs.json]

S203's verdict carries two kinds of gap. A **contradiction** is the build
disagreeing with something the captain wrote down, and it always has evidence:
either a picture (the score step demotes a contradiction with no shot to an
interpretation, so a bare one cannot reach here) or — since S211 — a quoted
line from the project's own failing test suite, which is what proves a
criterion that had no visual surface to photograph. An **interpretation** is a
call the build made where the record is silent — reported to the captain,
never filed against the build.

WHAT IS FILED (S240 WIDENED THIS; it did not replace it). Until S240 the rule
was "contradictions only", and a contradiction needed a picture or a quoted
failing-test line to exist at all — so a gap whose proof was a CLI TRANSCRIPT,
which is the entire point of S239's reach steps, was reported to the captain and
filed against nothing. The rule now reads:

  * every `gap` whose judgement came from ANY RECORDED INSTRUMENT — a picture, a
    CLI/workflow transcript, a measured box, or a line of the project's own test
    output. The instrument is read off the recorded `evidence` field (and the
    structural fact of a cited shot or quote), NEVER guessed from the prose.
  * every high-impact `untested` whose recorded `cause` is `product` — the build
    ships no way to do the thing, which is the work not being done and is a bug.
    An `infrastructure` cause, or NO recorded cause at all, is never filed: a
    blind row is a failure of ours and may not become a bug against his build on
    a word nobody wrote (xo-score.py -> CAUSE_CLASS).
  * an `interpretation`, and a gap nothing instrumented, are still NOT filed —
    they go on the report, exactly as before.

NEVER TWICE FOR ONE CRITERION. The sixth argument is the look's own
`xo/logs.json`; a criterion already in its `filed` list is skipped and said out
loud as an `ALREADY` record, so a second look cannot file the same bug again.

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
    ALREADY <criterion> <the bug mission it was filed as>
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


def upfirst(s):
    """A sentence starts with a capital. The contract's own words are kept
    otherwise — this is the Goal line, and it has to read like one."""
    s = str(s or "")
    return s[:1].upper() + s[1:] if s else s


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


# ─── WHAT COUNTS AS AN INSTRUMENT (S240) ────────────────────────────────────
# The same four words xo-score.py records on every row (VALID_EVIDENCE). A gap
# backed by one of them is a gap something MEASURED; `none` is a judgement call
# and goes on the report, never on a bug.
INSTRUMENTS = ("picture", "transcript", "measurement", "tests")

# The same plain words xo-score.py prints for each one — said when the
# instrument's output was NOT retained, so the sentence names what took the
# reading instead of citing a file that is not there (S240 fix round 1, D3).
EVIDENCE_WORD = {"picture": "a picture", "transcript": "a transcript",
                 "measurement": "a measured box", "tests": "the project's own tests"}

# The file a recorded instrument put on disk, by kind. A transcript is a `.txt`
# beside the shots (xo-run.py writes it); a picture is the `.png`; a measurement
# is the `.json` readout. Read in this order, and the first that EXISTS wins —
# the path on a bug has to be a path a fix worker can open.
EVIDENCE_EXT = {"transcript": (".txt", ".json", ".png"),
                "picture": (".png", ".txt"),
                "measurement": (".json", ".png"),
                "tests": (".txt",)}

# THE PLAN RULE, ONE SENTENCE, ON EVERY BUG THIS FILES. The grounding rule
# CONTEXT.md exists for: a fix belongs in the code that is already there, and a
# parallel control built beside the real one is the "green but wrong" decoy this
# whole arc is about.
PLAN_RULE = ("PLAN RULE: fix the code that is already there. Do NOT add a second "
             "path, flag, field or control beside the real one — a green test over "
             "a parallel dead control is the exact failure this bug exists to stop.")


def instrument_of(row, finding):
    """WHICH instrument settled this row — recorded, never inferred.

    The declared `evidence` word first; failing that, the STRUCTURAL facts a
    producer stamped (a cited shot, a quoted test line), which is the same
    fallback xo-score.py uses and for the same reason. "" means nothing
    measured it."""
    row, finding = row or {}, finding or {}
    ev = str(finding.get("evidence") or row.get("evidence") or "").strip().lower()
    if ev in INSTRUMENTS:
        return ev
    if finding.get("shots") or finding.get("shot") or row.get("shot"):
        return "picture"
    if clean(finding.get("testQuote")) or clean(row.get("testQuote")):
        return "tests"
    return ""


def evidence_ref(shotsdir, row, finding, instrument):
    """The PATH of the thing that was observed, as a fix worker would open it.

    An explicitly recorded path wins. Otherwise the recorded shot/transcript NAME
    is resolved against the look's own directory by the instrument's extension,
    and the first file that actually exists is the one quoted — a path to nothing
    is worse than no path."""
    row, finding = row or {}, finding or {}
    for k in ("evidencePath", "transcriptPath", "transcript"):
        v = clean(finding.get(k)) or clean(row.get(k))
        if not v:
            continue
        # A RECORDED PATH IS STILL CHECKED (S240 fix round 1, D3). It is quoted
        # only if it is there, as given or resolved against the look's own
        # directory — a bug that sends a fix worker to a file that is not on the
        # disk costs more than one that admits the evidence was not kept.
        if os.path.exists(v):
            return v
        pth = os.path.join(shotsdir, os.path.basename(v))
        if os.path.exists(pth):
            return pth
        continue
    name = clean(finding.get("shot")) or clean(row.get("shot"))
    if not name:
        for sh in (finding.get("shots") or []):
            if clean(sh):
                name = clean(sh)
                break
    if not name:
        return ""
    # THE NAME EXACTLY AS IT WAS GIVEN, FIRST (S240 fix round 2, D-B). A live
    # worker records its shot WITH the extension already on it — `01-help.txt`,
    # `02-workflow-run.txt` — so probing only `<name> + <ext>` looked for
    # `01-help.txt.png` / `01-help.txt.json`, found neither, and returned "".
    # MEASURED on the first live look: 6 of the 7 filed PRDs said "the evidence
    # was not retained" while `01-help.txt`, `02-workflow-run.txt` and
    # `08-publish.txt` were sitting in `shots/look-1/`. Round 1 stopped this
    # citing a path that is not there; without this line it started claiming
    # nothing had been kept.
    pth = os.path.join(shotsdir, name)
    if os.path.isfile(pth):
        return pth
    # AND THE EXTENSION PROBE STAYS, for a bare name (`shot-01`, `round1-01`) —
    # which is what every drawing/part shot is called. Both halves; neither one
    # traded for the other.
    exts = EVIDENCE_EXT.get(instrument) or (".png", ".txt")
    for ext in exts:
        pth = os.path.join(shotsdir, name + ext)
        if os.path.exists(pth):
            return pth
    # NOTHING OF THAT NAME IS ON THE DISK, so nothing is cited. This line used to
    # synthesise `<shotsdir>/<name><first-ext>` from the extension table and hand
    # it back unchecked, and `xo.sh` guards only the ATTACHMENT
    # (`[ -f "$s" ] && args+=(--attach "$s")`) — so AC #1 and AC #4 quoted an
    # absolute path to nothing, inside the PARENT mission's `.git/lcars/`, which
    # is untracked and sweepable and not the bug mission's own directory.
    return ""


def seam_of(row, finding, criteria, cid):
    """The producer -> consumer pair this bug sits at, or `none`.

    RECORDED FIRST: the look's own `seam` on the finding, then the contract's on
    the criterion. Failing both, a row the harness settled by RUNNING something
    (`checkedBy` cli or workflow) crossed a seam by construction — it ran one half
    and read what another half produced — so the pair is declared as what the
    record does say, and the round-trip criterion is required. A row a browser
    settled declares `none`, because one screen is not two halves."""
    row, finding = row or {}, finding or {}
    for src in (finding, row):
        v = clean(src.get("seam"))
        if v:
            return v
    try:
        with open(criteria, encoding="utf-8") as fh:
            doc = json.load(fh)
        rows = doc.get("criteria") if isinstance(doc, dict) else doc
        for c in rows or []:
            if isinstance(c, dict) and str(c.get("id") or "") == cid:
                v = clean(c.get("seam"))
                if v:
                    return v
    except Exception:
        pass
    by = str(row.get("checkedBy") or "").strip().lower()
    if by in ("cli", "workflow"):
        return ("the %s run that produced it -> whatever reads what it wrote "
                "(the record names no producer/consumer pair, so name it in the fix)"
                % by)
    return "none"


def already_filed(path):
    """{criterion: the bug mission it was filed as} off the look's own logs.json.
    The RECORD is the only thing consulted — never the presence of children, a
    label, or an issue's text."""
    out = {}
    if not path:
        return out
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return out
    for f in (doc.get("filed") or []) if isinstance(doc, dict) else []:
        if isinstance(f, dict) and clean(f.get("criterion")):
            out[clean(f["criterion"])] = clean(f.get("mission")) or "(unrecorded)"
    return out


def write_prd(path, **k):
    """THE EVIDENCE-FIRST BUG PRD (skills/lcars-buddy/bug-prd.md).

    Not prose. On the modelled weekend the bugs that were fixed FIRST TIME all
    had the same three things, and `autopilot.sh file-bug` refuses a PRD without
    them: a title that states the broken behaviour as a SENTENCE, an AC #1 that
    is literally `Observed live:` with the exact output and the real identifiers,
    and a ROUND-TRIP criterion wherever a seam is declared. The six sections
    `lcars file` requires are all here, in the order the template gives them, and
    everything after `Constraints` is reference material a reader can ignore —
    nothing is interleaved into the criteria list, because the validator reads
    AC #1 as the first bullet under the heading."""
    with open(path, "w", encoding="utf-8") as fh:
        w = fh.write
        w("# Mission: %s\n\n" % k["title"])
        w("**Type:** bug\n")
        w("**Seam:** %s\n" % k["seam"])
        w("**Goal:** %s\n" % k["goal"])
        w("**Acceptance Criteria:**\n")
        for ac in k["acs"]:
            w("- %s\n" % ac)
        w("**Out of Scope:**\n")
        for o in k["out_of_scope"]:
            w("- %s\n" % o)
        w("**Constraints:**\n")
        for c in k["constraints"]:
            w("- %s\n" % c)
        if k.get("tail"):
            w("\n## What the look recorded\n\n")
            for t in k["tail"]:
                w("%s\n\n" % t)


def main():
    if len(sys.argv) < 5:
        print("usage: xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir> "
              "[cap] [logs.json]", file=sys.stderr)
        return 2
    vpath, cpath, outdir, shotsdir = sys.argv[1:5]
    cap = int(sys.argv[5]) if len(sys.argv) > 5 and str(sys.argv[5]).strip() else CAP
    already = already_filed(sys.argv[6] if len(sys.argv) > 6 else "")

    try:
        with open(vpath, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print("MALFORMED" + RS + "the verdict could not be read (%s)" % exc)
        return 0

    gaps = doc.get("gaps") if isinstance(doc, dict) else None
    gaps = [g for g in gaps if isinstance(g, dict)] if isinstance(gaps, list) else []
    ledger = doc.get("criteria") if isinstance(doc, dict) else None
    ledger = [e for e in ledger if isinstance(e, dict)] if isinstance(ledger, list) else []
    row_by_id = {clean(e.get("id")): e for e in ledger if clean(e.get("id"))}
    find_by_id = {}
    for g in gaps:
        cid = clean(g.get("criterion"))
        if cid and cid not in find_by_id:
            find_by_id[cid] = g

    # ── THE SELECTION, WIDENED (S240) ────────────────────────────────────────
    # Contradictions first and in the order the look listed them, exactly as
    # before — then every other instrumented gap, then the high-impact rows the
    # build left unreachable. `picked` is positional, so the order a captain
    # reads them in is the order the look produced them in.
    picked, seen = [], set()

    def take(cid, kind):
        if not cid or cid in seen:
            return
        seen.add(cid)
        picked.append((cid, kind))

    # PASS 1 — THE OLD RULE, UNCHANGED. Every recorded `contradiction`, in the
    # order the look listed them. No extra test is applied here on purpose: the
    # score step already demoted any contradiction it could not back to an
    # interpretation, so an instrument check here would REMOVE a rule rather than
    # widen one — and widening is the whole brief. `kind` is read, never guessed
    # from the prose, exactly as before.
    for g in gaps:
        if str(g.get("kind") or "").strip().lower() != "contradiction":
            continue
        take(clean(g.get("criterion")), "gap")
    # PASS 2 — THE WIDENING. Every OTHER ledger row that says `gap` and names a
    # recorded instrument: the CLI transcript, the workflow step, the measured
    # box, the test line. This is the class that was reported and never filed.
    for e in ledger:
        if str(e.get("status") or "").strip().lower() != "gap":
            continue
        cid = clean(e.get("id"))
        if instrument_of(e, find_by_id.get(cid)):
            take(cid, "gap")
    for e in ledger:
        if str(e.get("status") or "").strip().lower() != "untested":
            continue
        imp = str(e.get("impact") or "high").strip().lower()
        if imp != "high":
            continue
        if str(e.get("cause") or "").strip().lower() != "product":
            continue
        take(clean(e.get("id")), "untested")

    # NEVER TWICE. Said out loud, with the mission it was filed as, before the
    # cap is applied — an already-filed bug must not consume one of the ten.
    fresh = []
    for cid, kind in picked:
        if cid in already:
            print(RS.join(["ALREADY", cid, already[cid]]))
        else:
            fresh.append((cid, kind))

    overflow = max(0, len(fresh) - cap)
    fresh = fresh[:cap]

    os.makedirs(outdir, exist_ok=True)
    for n, (cid, kind) in enumerate(fresh, 1):
        row = row_by_id.get(cid) or {}
        g = find_by_id.get(cid) or {}
        ctext, csource = criterion_text(cpath, cid)
        where = csource or (cid or "the record")
        if where.strip().lower() in ("prd", "plan", "journey", "drawing"):
            where = {"prd": "your PRD", "plan": "the plan",
                     "journey": "the journey through the build",
                     "drawing": "your drawing"}[where.strip().lower()]
        shots = [clean(sh) for sh in (g.get("shots") or []) if clean(sh)]
        place = criterion_place(cpath, cid) or hash_id(
            " ".join([str(g.get("title") or ""), str(g.get("expected") or ""),
                      str(g.get("saw") or "")]))
        shots = bind_shots(shotsdir, shots, place)
        instrument = instrument_of(row, g) or "none"
        ref = evidence_ref(shotsdir, row, g, instrument)
        seam = seam_of(row, g, cpath, cid)
        action = unstop(row.get("action")) or unstop(g.get("action"))
        # ── WHAT WAS SEEN, AND WHICH CLAUSE IT BELONGS IN (S240 fix round 1, D3)
        # `saw_phrase` is a NOUN PHRASE and is the only thing spliced into "the
        # build gave …". `gaps[].saw` is written that way ("a hardcoded
        # github.com") and so is a row's `sawInstead` ("it printed github.com,
        # the hardcoded one"). The ledger row's `note` is a SENTENCE ("ran it and
        # it did not do that") and used to be spliced in anyway, producing "the
        # build gave ran it and it did not do that" — ungrammatical, and it threw
        # away the one field that said what actually went wrong. The note is
        # still said, as its own sentence, below.
        saw_phrase = (unstop(row.get("sawInstead")) or unstop(g.get("sawInstead"))
                      or unstop(g.get("saw")))
        observed = (unstop(row.get("sawInstead")) or unstop(g.get("sawInstead"))
                    or unstop(row.get("note")) or unstop(g.get("saw")))
        expected = unstop(g.get("expected")) or unstop(ctext) or "what the record says"
        quote = clean(g.get("testQuote")) or clean(row.get("testQuote"))

        # ── THE TITLE IS A SENTENCE ──────────────────────────────────────────
        if kind == "untested":
            title = (clean(g.get("title"))
                     or "%s — the build offers no way to do it at all" % (ctext or cid))
        else:
            title = clean(g.get("title")) or (
                "%s — the build does not do it" % (ctext or cid))

        # ── AC #1, THE ONE PART THAT CANNOT BE WRONG ─────────────────────────
        ac1 = ["Observed live:"]
        if action:
            ac1.append("%s." % action)
        if kind == "untested":
            ac1.append("Nothing could be run for this: %s."
                       % (observed or "the record names no way in"))
        elif saw_phrase:
            ac1.append("Expected %s; the build gave %s." % (expected, saw_phrase))
        else:
            ac1.append("Expected %s; it did not." % expected)
        if quote:
            ac1.append('The project\'s own tests said: "%s".' % quote)
        if ref:
            ac1.append("Recorded in `%s` (%s)." % (ref, instrument))
            # AND THE ROW'S OWN SENTENCE, WHEN IT IS NOT ALREADY THE OBSERVATION
            # (S240 fix round 1, D3). The `note` is the one line that says what
            # went wrong in the look's own words; citing the file instead of it
            # threw it away.
            if observed and observed != saw_phrase:
                ac1.append("The row's own words: %s." % observed)
        elif kind != "untested":
            # NO PATH IS CITED, AND THAT IS SAID PLAINLY (S240 fix round 1, D3).
            # `evidence_ref` returns a path only when the file is on the disk, so
            # an empty `ref` with a named instrument means the output was taken
            # and not retained. A fix worker is told that, and told what was
            # observed, instead of being sent to a file that is not there.
            if instrument != "none":
                ac1.append("%s settled this and was not retained, so the "
                           "record's own words are all there is%s"
                           % (upfirst(EVIDENCE_WORD.get(instrument, "an instrument")),
                              (": %s." % observed) if observed else "."))
            elif observed:
                ac1.append("Recorded on the row as: %s." % observed)
        ac1.append("The criterion is `%s`, written at %s." % (cid, where))
        acs = [" ".join(ac1)]

        # ── THE CORRECTED BEHAVIOUR, AS ONE SHARED RULE ──────────────────────
        acs.append("%s — as ONE shared rule, declared in one place and read by "
                   "every half that needs it, not restated on each side."
                   % (ctext or expected))
        if seam.strip().strip("`.").lower() not in ("none", "n/a", "na", "-"):
            acs.append("Round-trip test with NO hand-written fixture: the test drives "
                       "the real producer (%s), feeds what it actually wrote to the "
                       "real consumer, and asserts the consumer reports the value the "
                       "producer was given." % seam)
        if instrument == "transcript" and ref:
            acs.append("The same check re-run the way the look ran it — the command "
                       "above, its output compared against `%s` — now agrees with "
                       "the criterion." % ref)
        elif shots:
            acs.append("The fix is visible on the same screen the shot above was "
                       "taken of (`%s`)." % shots[0])
        elif quote:
            acs.append("The test that reported this now passes, and the fix is in the "
                       "code that test already exercises — not in a new path built "
                       "beside it.")

        goal = ("%s. That is true after the fix for EVERY record, not only the one "
                "above, and it is checkable by running the thing rather than by "
                "reading the code." % upfirst(unstop(ctext) or unstop(expected)))

        out_of_scope = []
        for other, _k in picked:
            if other != cid and other in row_by_id:
                out_of_scope.append("`%s` — %s. Filed as its own bug, or on the "
                                    "report; not this one."
                                    % (other, criterion_text(cpath, other)[0] or other))
        out_of_scope = out_of_scope[:3]
        out_of_scope.append("Anything the look put aside as an interpretation — those "
                            "are calls the build made where the record is silent, and "
                            "they are the captain's to settle, not a fix worker's.")
        if not shots:
            out_of_scope.append("Building a screen for this. There is no picture here "
                                "because there is no screen; do not make one.")

        constraints = [PLAN_RULE,
                       "Keep the project's existing stack, permission model and test "
                       "conventions. No new dependency to fix one field.",
                       "A test may stub the clock, the network and the forge. It may "
                       "NOT stub either half of the seam named above — that is the "
                       "thing under test."]

        tail = []
        # ONLY THE SHOTS THAT ARE ON THE DISK ARE DESCRIBED (S240 fix round 1,
        # D3, the cheap half). `xo.sh` attaches a PNG only when the file exists
        # (`[ -f "$s" ] && args+=(--attach "$s")`), so a swept shot left this
        # block promising "each PNG has a `.json` readout beside it" about
        # attachments the issue does not carry. The Out-of-Scope line still reads
        # off `shots`, not this list: a shot NAME means there WAS a screen, so
        # "do not make one" would be wrong just because the file was swept.
        present = [sh for sh in shots
                   if os.path.exists(os.path.join(shotsdir, sh + ".png"))]
        if present:
            tail.append("Number One's shots of the running build: %s. Each PNG has a "
                        "`.json` readout beside it (url, visible text, the box and "
                        "computed colour of every element the drawing names) and a "
                        "`.txt` caption." % ", ".join(present))
            lead = shot_selector(shotsdir, present[0])
            if lead:
                tail.append("`%s` is the close-up of `%s` — that is the one that "
                            "shows this." % (present[0], lead))
        if ctext:
            tail.append("The criterion this is judged against, in full:\n\n> %s" % ctext)

        path = os.path.join(outdir, "%d.md" % n)
        write_prd(path, title=title, seam=seam, goal=goal, acs=acs,
                  out_of_scope=out_of_scope, constraints=constraints, tail=tail)

        print(RS.join(["GAP", str(n), path,
                       ",".join(os.path.join(shotsdir, sh + ".png") for sh in shots),
                       cid, title]))

    if overflow:
        print("OVERFLOW" + RS + str(overflow))
    return 0


if __name__ == "__main__":
    sys.exit(main())
