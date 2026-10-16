#!/usr/bin/env python3
"""xo-logs.py — turn what the Verify look MEASURED into evidence-first bug PRDs.

    python3 xo-logs.py <verdict.json> <criteria.json> <out-dir> <shots-dir>
                        [cap] [logs.json]
    python3 xo-logs.py --merge-follow-ups <verdict.json>

The merge mode retains findings as operator followUps and never emits filing records.

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
  * and, since S251, every entry of `volunteered[]` — a real fault the look saw
    that NO criterion covers. Filed LAST, only into what the cap has left, with
    `volunteered-<k>` for a criterion id because there is no criterion, and with
    every sentence of its PRD saying so. Since S263 it must CITE a RECORD — a
    regular, non-empty file inside the look's own shots directory, and nothing
    else — or it is REFUSED out loud with what is missing (see `vol_record`):
    the one class nobody wrote a criterion for is the one class where the record
    is all there is.
    It is fenced out of the grade by not being READ anywhere a grade is decided.
    `xo-criteria.py` never sees the key at all — it is not a criterion — and
    `xo-score.py` only COPIES it through to here (its one pass-through line,
    S263), because this file is handed the SCORED verdict and the raw one is
    deleted by `xo_rm_work`. `derive_grade`, `derive_recommendation`, the
    coverage floor and `blockers[]` have never read it and still do not. So the
    contract-first rule stands and a volunteered find is information, never a
    send-back.

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
    REFUSED <what-it-said> <what-is-missing>

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
import tempfile

CAP = 10

# THE ID AN UNCONTRACTED FINDING IS FILED UNDER (S251). There is no criterion, so
# there is no criterion id — this prefix IS the record that says so, and it is the
# one thing `xo-filed.py` reads to keep a volunteered bug out of the send-back
# sentence. Minted here, honoured there; the two are one contract and the comment
# in each names the other.
# It is NOT an extra field on the GAP record: `xo.sh` splits that record with
# seven `read` names, and bash gives the LAST name everything that is left — so an
# eighth field lands inside the attachment list and every attachment is lost. The
# id IS the record. (Measured: adding the field cost B12a and three B18 checks.)
VOL_ID_PREFIX = "volunteered-"

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


# ─── ONE LADDER FROM A SHOT NAME TO A FILE ON DISK (S240 fix round 3) ───────
# Round 2 cured `evidence_ref`, which probed `<shotsdir>/<name> + ".png"` against
# a live shot name that ALREADY CARRIES ITS EXTENSION (`01-help.txt`) — looking
# for `01-help.txt.png`, finding nothing, and reporting the evidence lost. The
# SAME `+ ".png"` survived on the ATTACHMENTS path and the same `+ ".json"` in
# `shot_selector`, so `xo.sh`'s `[ -f "$s" ] && args+=(--attach "$s")` attached
# NOTHING: 5 shot paths across the live look's 7 filed tickets, 4 of them
# `….txt.png` phantoms. It is ONE ladder now, read by all three call sites, so
# the halves cannot drift apart again:
#
#   1. the name EXACTLY AS IT WAS GIVEN          `01-help.txt`
#   2. then `<name><ext>`, the bare-name probe   `shot-01` -> `shot-01.png`
#   3. then `<stem><ext>`, the SIDECAR           `01-help.txt` -> `01-help.json`
#
# Step 3 is the new rung and is purely additive: it can only fire where 1 and 2
# already found nothing. It is what `shot_selector` needs, because that reader
# does not want "any file of this name" — it wants the `.json` readout beside the
# shot, which for `01-help.txt` is `01-help.json`.
SHOT_EXT = (".png", ".txt", ".json")


def shot_candidates(name, exts=SHOT_EXT):
    """Every filename a recorded shot NAME could be on disk under, in order."""
    name = clean(name)
    if not name:
        return []
    stem, ext = os.path.splitext(name)
    cands = [name] + [name + e for e in exts]
    if ext:
        cands += [stem + e for e in exts]
    out = []
    for c in cands:
        if c not in out:
            out.append(c)
    return out


def shot_file(shotsdir, name, exts=SHOT_EXT):
    """The FILE a recorded shot name is actually on disk as, or "". A path to
    nothing is worse than no path: every caller here quotes or attaches what this
    returns, so it is checked with `isfile` and never synthesised."""
    for cand in shot_candidates(name, exts):
        pth = os.path.join(shotsdir, cand)
        if os.path.isfile(pth):
            return pth
    return ""


def attach_path(shotsdir, name):
    """The path `xo.sh` is handed for a recorded shot, for its `[ -f "$s" ]`
    guard to accept or drop. The real file when there is one; otherwise the NAME
    is still carried — a gap is worth filing with a name for its shot even when
    the file has been swept, and `logs.json` recovers that name from this field
    (basename, less `.png`) for `xo recheck` — but never with an extension glued
    onto a name that already has one."""
    real = shot_file(shotsdir, name)
    if real:
        return real
    if os.path.splitext(clean(name))[1]:
        return os.path.join(shotsdir, clean(name))
    return os.path.join(shotsdir, clean(name) + ".png")


def shot_selector(shotsdir, name):
    """The element this shot was CLIPPED to, or "" for a picture of the whole
    page. The driver writes it into the `.json` readout beside every PNG
    (`selector`, with `clip` set to the box it used), so this is read off the
    record of the shot and never guessed from its name."""
    # THE READOUT, NOT MERELY A FILE OF THAT NAME. `01-help.txt` exists and is a
    # transcript; the record of that shot is `01-help.json`, so the ladder is
    # walked for `.json` only and a non-readout rung is stepped over.
    doc = None
    for cand in shot_candidates(name, (".json",)):
        if not cand.endswith(".json"):
            continue
        try:
            with open(os.path.join(shotsdir, cand), encoding="utf-8") as fh:
                doc = json.load(fh)
            break
        except Exception:
            continue
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


def widen_shots(shotsdir, shots, row, finding, instrument):
    """EVERY PLACE A SHOT WAS RECORDED, not just one (S240 fix round 4, D5).

    MEASURED on a seven-gap case before anything was changed, counting only
    attachments whose file is actually on disk (which is `xo.sh`'s own
    `[ -f "$s" ]` rule):

        gap 1  gaps[].shots (plural)            attach=shot-01.png
        gap 2  gaps[].shots, two                attach=shot-02.png,shot-03.png
        gap 3  gaps[].shot (SINGULAR)           attach=(NONE)
        gap 4  only criteria[].shot on the ROW  attach=(NONE)
        gap 5  evidencePath                     attach=(NONE)
        gap 6  a transcript name                attach=(NONE)
        gap 7  nothing recorded at all          attach=(NONE)
        -> 2 of 7 arrived with an attachment.

    So the attach list read ONE recorded field — `gaps[].shots` — while the
    PROSE path (`instrument_of`, `evidence_ref`) already read four others. The
    captain was told plainly that the cure WIDENS what attaches rather than
    correcting a wrong path, and approved it on 2026-10-03: a bug he cannot see
    is not actionable, and a less-relevant screenshot beats none.

    So every recorded place is read, most specific first:
      1. the element's own shot              (bind_shots, unchanged)
      2. `gaps[].shots`                      (what already worked)
      3. `gaps[].shot` / `criteria[].shot`   singular, on the gap or the row
      4. whatever `evidence_ref` resolved    (evidencePath / transcript / …)
      5. LAST RESORT: the look's lead picture, so no bug ships blind.

    Nothing is reordered within what already worked, and nothing synthesised:
    every name still goes through `shot_file`, so a path to nothing is never
    carried as if it were evidence.
    """
    row, finding = row or {}, finding or {}
    out = list(shots)

    def add(name):
        name = clean(name)
        if name and name not in out:
            out.append(name)

    # 3 — the singular field, on the gap and on the ledger row.
    add(finding.get("shot"))
    add(row.get("shot"))
    for sh in (row.get("shots") or []):
        add(sh)

    # 4 — whatever the prose already cites. It is a PATH, so it is carried as
    # the basename the attach ladder can resolve back to that same file.
    ref = evidence_ref(shotsdir, row, finding, instrument)
    if ref:
        add(os.path.basename(ref))

    # Keep only names that are really on the disk; a name with no file behind
    # it is still returned by `bind_shots` for the prose, but it must not be
    # counted here as the thing that made this gap visible.
    #
    # DEDUPED BY FILE, NOT BY NAME. `shot-01` and `shot-01.png` are two names
    # for one file, and `evidence_ref` hands back the second while the look
    # cites the first — which attached the same picture to the same ticket
    # twice on the first run of this cure.
    real, seen_files = [], set()
    for n in out:
        f = shot_file(shotsdir, n)
        if not f or f in seen_files:
            continue
        seen_files.add(f)
        real.append(n)
    if real:
        return real

    # 5 — LAST RESORT. Nothing recorded for this gap resolves to a file, so the
    # bug would arrive with no picture at all. The look's lead picture is less
    # relevant than a close-up and far better than nothing: it at least shows
    # the captain the build the gap is about. It is marked as the fallback by
    # being the ONLY thing here, and the PRD prose still says exactly what was
    # and was not retained — this widens what ATTACHES, never what is claimed.
    lead = lead_shot(shotsdir)
    return [lead] if lead else out


def lead_shot(shotsdir):
    """The look's own first picture — the full page, by convention `shot-01`.

    Read off the disk, never assumed: the first `.png` in name order whose
    readout is not a close-up, falling back to the first `.png` at all."""
    try:
        pngs = sorted(fn for fn in os.listdir(shotsdir) if fn.endswith(".png"))
    except Exception:
        return ""
    if not pngs:
        return ""
    for fn in pngs:
        if not shot_selector(shotsdir, fn[:-4]):
            return fn[:-4]
    return pngs[0][:-4]


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


# ─── WHAT A VOLUNTEERED FIND MUST CITE (S263), AND WHY IT IS ONE QUESTION ────
#
# THIS GUARD HAS BEEN WRITTEN THREE TIMES AND THE FIRST TWO WERE BOTH BEATEN
# THE SAME WAY: they asked a question NEAR the real one.
#
#   ROUND 0 asked "is the citation field non-empty?" — and `{"transcript": "it
#   felt sluggish when I used it"}`, `{"evidencePath": "n/a"}` and
#   `{"testQuote": "nothing, I did not run a test"}` each filed a complete bug
#   against the captain's build. The price of an evidence-free opinion moved
#   from zero words to ONE word.
#
#   ROUND 1 asked "does the value LOOK like a path, or LOOK like a machine
#   line?" — two ladders, one of them a shape test over English. Measured:
#   `/etc/passwd`, `/tmp`, `.`, `/`, a directory inside the shots dir and a
#   ZERO-BYTE file all cited and filed, with `--attach /etc/passwd` in the real
#   `file-logs` argv; while `error: unknown command "publish"`, `Segmentation
#   fault` and `Traceback (most recent call last)` — honest machine output, which
#   the ask explicitly invites — were all REFUSED, and `"I looked at config.yaml
#   and it was wrong"` was accepted for its dot. It was BACKWARDS.
#
# `ORCHESTRATION.md` records that every session which went past three rounds was
# cured by DELETING or RESTRUCTURING something, never by the next patch (S147,
# four generations of a parser; S156, a regex classifier; S157, five versions of
# a guard). So there is no generation three of the heuristic. The heuristic is
# GONE — `vol_quote` and its four constants are deleted — and what is left is
# ONE rung asking ONE question, about a RECORD and not about words:
#
#     is this a REGULAR, NON-EMPTY file INSIDE the look's own shots directory?
#
# Four properties, every one of them a row that filed a bug in round 1, and
# every one checkable with `os.stat`. Nothing here reads prose, nothing here
# judges shape, and there is nothing left for a sentence with a slash in it to
# satisfy — which is the point: a reviewer satisfies this by SAVING THE FILE.
#
# WHY NOT `testQuote` ANY MORE (fix round 2, D3). A quoted line is not a file,
# so it cannot be asked this question — and the CORRECT mechanism for a quoted
# test line already exists somewhere else: `xo-score.py`'s `tests_settle` /
# `tally_refusal` / `case_leaves` judge a quote against `tests.json`'s RECORDED
# `outputTail` and `testCases`, which is a FACT and not a shape. That ladder
# lives in the scorer, reads a file this program is never handed, and
# reimplementing it here is the cloning the three dead rounds above were made of.
# So the route is closed rather than faked: this lane's whole point is a RECORD,
# and a file record is the thing the look already produces. The ask no longer
# offers `testQuote` as a way in, and this sentence no longer promises one.
VOL_CITATION_ASK = ("it cites no record of this look — a find outside the "
                    "contract needs the same citation a gap needs, and the only "
                    "thing that counts is a FILE YOU SAVED in this look's own "
                    "shots directory, named in `shot`/`shots`/`transcript`/"
                    "`transcriptPath`/`evidencePath`. It has to be really there, "
                    "it has to be a file and not a directory, it must not be "
                    "empty, and it must be inside the shots directory — a path "
                    "to somewhere else on the machine is not a record of this "
                    "look even when it exists. An `evidence` word on its own, a "
                    "field filled with prose, and a name you never saved are all "
                    "not citations.")

# ─── AND THE TWO REASONS AN ENTRY IS DROPPED BEFORE ITS CITATION IS EVEN READ
# (fix round 3, FIX 3). Both of these used to be silent list comprehensions
# above the loop. They are refusals now, on the same `REFUSED` record, through
# the same surfaces (`xo.sh` prints them, journals them and keeps them in
# `xo/logs.json`) — a dropped find the captain never hears about is the exact
# failure this whole session is about.
VOL_WORDLESS = "(a find with no words on it)"
VOL_WORDLESS_ASK = ("it says nothing a bug could be filed from — a find needs a "
                    "`title` or a `saw` IN WORDS, and this one has neither. A "
                    "number, a `true` and an empty field are not a sentence, so "
                    "there was nothing to write down. Nothing was filed from it "
                    "and nothing about it is proven clean: say it again in a "
                    "sentence, with the file you saved beside it.")
VOL_SHAPE_ASK = ("it is not a find at all — `volunteered` takes objects shaped "
                 "like a gap (`title`, `expected`, `saw`, `shots`, …) and this "
                 "entry is not an object, so nothing could be read off it. "
                 "Nothing was filed from it and nothing about it is proven "
                 "clean.")

# The recorded fields that may NAME the file, most specific first. Exactly the
# fields `evidence_ref` and `instrument_of` already read, so a reviewer who
# cited a gap the usual way has cited this the usual way too.
VOL_CITE_FIELDS = ("evidencePath", "transcriptPath", "transcript", "shot", "shots")
# PLURAL FIRST, as the lane has always read them — `bind_shots` and the PRD's
# tail both lead on `shots[0]`, so the order the look's own list gives is kept.
VOL_SHOT_FIELDS = ("shots", "shot")


def cite_names(v, fields=VOL_CITE_FIELDS):
    """Every NAME a find offers, in field order, whatever shape it offered it in.

    SHAPE IS NOT A JUDGEMENT (S263 fix round 2, D6). `clean()` stringifies a
    container, so `{"transcript": ["01-help.txt"]}` became the string
    `"['01-help.txt']"` and `{"shots": {"a": "01-help.txt"}}` became a dict's
    repr — the path inside was never tried and an honest citation was lost to the
    shape of its field. A number, a bool and a None yield NOTHING, which is also
    what stops `{"shots": 5}` from reaching an iteration that raises."""
    out = []

    def add(x):
        if isinstance(x, str):
            n = clean(x)
            if n and n not in out:
                out.append(n)
        elif isinstance(x, (list, tuple)):
            for y in x:
                add(y)
        elif isinstance(x, dict):
            for y in x.values():
                add(y)

    for k in fields:
        add((v or {}).get(k))
    return out


def vol_record(shotsdir, v):
    """THE RECORD that cites this volunteered find, as a path — or "".

    ONE RUNG, four properties, all of them `os.stat`:

      * INSIDE. The name is taken down to its basename and resolved against the
        look's own directory, and the file it lands on is checked to be really
        under that directory with `os.path.realpath` and a containment test —
        not a string prefix, which a symlink or a `..` walks straight through.
        `evidence_ref` rung 1 resolved the RAW value against the PROCESS CWD, so
        `/etc/passwd` was a citation; rung 2 joined the directory without
        normalising, so `..` escaped.
      * A FILE. `shot_file` is the shared resolver and it already asks
        `os.path.isfile`, so `/tmp`, `.`, `/` and a directory inside the shots
        dir are all answered here rather than by a second ladder.
      * NOT EMPTY. A zero-byte file is a record of nothing; it cited and filed.
      * NAMED AS SAVED. `shot_file` walks the one extension ladder every other
        caller in this file walks, so `01-help.txt` and a bare `shot-01` both
        resolve exactly as they do for a contracted gap.

    SCOPE, DELIBERATELY (fix round 2, D2). This confines the VOLUNTEERED lane
    only. `evidence_ref` has five call sites and the other four are pre-existing
    behaviour on the CONTRACTED lanes, where a criterion and the score step's own
    instrument check already stand behind every row — changing those is a wider
    blast radius than this cure, and the general weakness is ledgered for the
    captain instead. This is not a clone of that ladder either: it CALLS
    `shot_file`, the one resolver, and adds the three `stat` questions
    `evidence_ref` never asked."""
    if not shotsdir or not os.path.isdir(shotsdir):
        return ""
    root = os.path.realpath(shotsdir)
    for name in cite_names(v):
        for cand in vol_candidates(name):
            pth = shot_file(shotsdir, cand)
            if not pth:
                continue
            real = os.path.realpath(pth)
            try:
                if os.path.commonpath([root, real]) != root:
                    continue
                if os.path.getsize(real) <= 0:
                    continue
            except (OSError, ValueError):
                continue
            return pth
    return ""


def vol_candidates(name):
    """THE NAMES TO TRY for one recorded citation, and why there are two.

    "INSIDE YOUR SHOTS DIRECTORY" MEANS **UNDER** IT (fix round 3, FIX 2). Round
    2 took every name down to its basename before resolving, so a record the
    reviewer genuinely saved at `deep/a/b/x.txt` under its own shots directory
    was looked for at `shots/x.txt`, found nothing, and the honest find was
    REFUSED. A reviewer told to save a file in a directory will make
    subdirectories in it; a guard that only reads the top of that directory
    throws away exactly the finds it asked for.

      1. THE PATH AS WRITTEN, so a record is found where it was actually put.
      2. ITS BASENAME, which is how a reviewer that wrote the absolute path of
         its own copy still lands on the record it saved here. This is round 2's
         behaviour, kept.

    TRYING BOTH IS SAFE BECAUSE CONTAINMENT, NOT THIS LIST, IS THE GUARANTEE.
    Whatever either candidate lands on is still resolved with `os.path.realpath`
    and checked `commonpath`-against the shots directory by the one caller — so
    an absolute path (`os.path.join` lets it win), a `..` walk, a symlink
    pointing out, and a sibling directory whose name merely starts the same way
    (`shots-evil` beside `shots`) are all still refused, and are refused by the
    SAME line that refused them before. Nothing here is a string prefix test."""
    n = clean(name).rstrip("/\\")
    out = []
    for cand in (n, os.path.basename(n)):
        if cand and cand not in (".", "..") and cand not in out:
            out.append(cand)
    return out


def vol_shot_name(shotsdir, name):
    """The name THIS LANE EMITS for a cited record — relative to the shots
    directory when the record lives in a subdirectory of it, so `attach_path`
    and `shot_file` land on the same file the guard accepted (fix round 3, FIX
    2). A flat name is returned exactly as round 2 returned it, a basename, so
    `bind_shots`, `shot_selector` and `logs.json`'s own name recovery all read
    precisely what they read before; and a name that resolves to nothing is
    still CARRIED as a basename, which is the pre-existing behaviour a
    `recheck` depends on."""
    base = os.path.basename(clean(name).rstrip("/\\"))
    if not shotsdir or not os.path.isdir(shotsdir):
        return base
    root = os.path.realpath(shotsdir)
    for cand in vol_candidates(name):
        pth = shot_file(shotsdir, cand)
        if not pth:
            continue
        real = os.path.realpath(pth)
        try:
            if os.path.commonpath([root, real]) != root:
                continue
            rel = os.path.relpath(real, root)
        except (OSError, ValueError):
            continue
        if os.sep in rel:
            return rel
        return base
    return base


def where_observed(shotsdir, row, finding):
    """WHERE the thing in AC #1 was actually seen — off the step's own readout.

    THE MEASURED DEFECT (S250 fix round 1, D3). Every bug PRD opens its first
    acceptance criterion with `Observed live:` — mandatory, and rightly so: the
    exact output is the one part of a bug report that cannot be wrong, and
    `ech.sh file-bug` refuses a PRD without it. But on the S250 drive all
    three filed PRDs said `Observed live:` when `xo/live.json` did not exist and
    not one step had reached a real host. The evidence was the reviewer's own
    local transcript, and a fix worker reading that line would believe the
    deployed artifact had been read back.

    So the opener keeps its word and the sentence SAYS WHERE. The answer comes
    from a RECORD: `xo-run.py` stamps `live: {host, owner, repo, consentedBy}` on
    the readout of a step that actually reached a consented host, and stamps
    nothing there on a step that ran in the look's own detached worktree. The
    readout beside the cited evidence is read, and nothing is inferred from the
    criterion's or the note's prose.

    Returns the clause to follow the opener, or "" when there is no readout to
    answer from — in which case the PRD says nothing it cannot support."""
    name = clean(finding.get("shot")) or clean(row.get("shot"))
    if not name:
        for sh in (finding.get("shots") or []):
            if clean(sh):
                name = clean(sh)
                break
    if not name or not shotsdir or not os.path.isdir(shotsdir):
        return ""
    stem = name[:-4] if name.lower().endswith((".txt", ".png", ".jpg")) else name
    doc = None
    for cand in (name if name.lower().endswith(".json") else "", stem + ".json"):
        if not cand:
            continue
        try:
            with open(os.path.join(shotsdir, cand), encoding="utf-8") as fh:
                doc = json.load(fh)
        except Exception:
            doc = None
        if isinstance(doc, dict):
            break
    if not isinstance(doc, dict):
        return ""
    live = doc.get("live") if isinstance(doc.get("live"), dict) else None
    if live and clean(live.get("host")):
        where = "/".join(x for x in (clean(live.get("host")), clean(live.get("owner")),
                                     clean(live.get("repo"))) if x)
        return ("on the real host %s%s," % (where,
                (" (consented in %s)" % clean(live["consentedBy"]))
                if clean(live.get("consentedBy")) else ""))
    return ("in the reviewer's own detached worktree on one machine, NOT on a "
            "live host —")


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
    # THE NAME EXACTLY AS IT WAS GIVEN, FIRST (S240 fix round 2, D-B) — and then
    # the extension probe, for a bare name (`shot-01`, `round1-01`), which is what
    # every drawing/part shot is called. Both halves; neither one traded for the
    # other. A live worker records its shot WITH the extension already on it
    # (`01-help.txt`, `02-workflow-run.txt`), so probing only `<name> + <ext>`
    # looked for `01-help.txt.png`, found nothing, and returned "" — MEASURED on
    # the first live look as 6 of 7 filed PRDs saying "the evidence was not
    # retained" while those files sat in `shots/look-1/`.
    #
    # The ladder now lives in `shot_file` (S240 fix round 3) because the SAME
    # mistake was still live on the attachments path and in `shot_selector`; one
    # resolver means a cure here cannot stop short there. Nothing of that name on
    # the disk still cites NOTHING: `xo.sh` guards only the ATTACHMENT, so a
    # synthesised path put a dead absolute path, inside the PARENT mission's
    # untracked and sweepable `.git/lcars/`, into AC #1 and AC #4.
    return shot_file(shotsdir, name,
                     EVIDENCE_EXT.get(instrument) or (".png", ".txt"))


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
    """THE EVIDENCE-FIRST BUG PRD (skills/lcars-eeh/bug-prd.md).

    Not prose. On the modelled weekend the bugs that were fixed FIRST TIME all
    had the same three things, and `ech.sh file-bug` refuses a PRD without
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


def merge_follow_ups(vpath):
    with open(vpath, encoding="utf-8") as fh:
        doc = json.load(fh)
    if doc.get("recommendation") not in ("merge", "merge-with-follow-ups"):
        return 0

    follow_ups = list(doc.get("followUps") or [])
    findings = list(doc.get("gaps") or []) + list(doc.get("volunteered") or [])
    findings += [row for row in doc.get("criteria") or []
                 if row.get("status") == "gap" or
                 (row.get("status") == "untested" and row.get("cause") == "product")]
    for finding in findings:
        note = "%s: %s" % (clean(finding.get("title") or finding.get("text") or
                                  finding.get("id") or "Reviewer finding"),
                           json.dumps(finding, ensure_ascii=True, sort_keys=True))
        if note not in follow_ups:
            follow_ups.append(note)
    if follow_ups != (doc.get("followUps") or []):
        doc["followUps"] = follow_ups
        tmp = ""
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False,
                                             dir=os.path.dirname(vpath), prefix=".follow-ups-") as fh:
                tmp = fh.name
                json.dump(doc, fh, ensure_ascii=True, indent=2)
                fh.write("\n")
            os.replace(tmp, vpath)
        finally:
            if tmp and os.path.exists(tmp):
                os.unlink(tmp)
    print("MERGE verdict: %d follow-up(s) kept in %s (followUps). "
          "The operator decides what to file; no logs filed and no resolver started." %
          (len(follow_ups), vpath))
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--merge-follow-ups":
        return merge_follow_ups(sys.argv[2])
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

    # ── ONE BUG PER FAULT, NOT ONE PER ROW (S257 fault 1d) ──────────────────
    #
    # THE DEFECT THIS CLOSES, measured on the 2026-10-06 looks: runelock filed
    # FOUR bugs for TWO faults, shiftboard six for three, pantry six for three
    # — and the duplicates arrived with `shots: []`, so the fix worker got a
    # second ticket for the same fault with no evidence on it. The de-dup here
    # keyed on the CRITERION ID alone, and the PRD row and the plan row that
    # restates it are two ids for one requirement.
    #
    # `xo-score.py` now stamps the pairing on the ledger (`faultOf` on the
    # absorbed row, `faultWith` on the one that represents it), joined on the
    # plan's own `serves`/`direction: delivers` declaration. This READS that
    # stamp: a row that is part of a fault is filed under the requirement the
    # fault belongs to, and the id it absorbed is NAMED in the bug so nothing
    # is lost. An unstamped row behaves exactly as it did before.
    fault_root = {}
    fault_members = {}
    for e in ledger:
        cid = clean(e.get("id"))
        if not cid:
            continue
        root = clean(e.get("faultOf")) or cid
        fault_root[cid] = root
        fault_members.setdefault(root, [])
        if cid != root:
            fault_members[root].append(cid)

    def take(cid, kind):
        if not cid:
            return
        root = fault_root.get(cid, cid)
        if cid in seen or root in seen:
            return
        seen.add(cid)
        seen.add(root)
        picked.append((root, kind))

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

    # ── THE LANE FOR A FAULT NOBODY WROTE A REQUIREMENT FOR (S251) ───────────
    #
    # WHAT WAS MEASURED. Six faults were planted, one per class, with the
    # mission's requirements deliberately naming none of them. The look FOUND
    # five and FILED three; it withheld two on purpose and said why in its own
    # words — "No criterion covers the footer link, so I am not filing it."
    # It was right about the product: an uncontracted fault had two possible
    # homes and NEITHER could produce a bug. `alsoChecked` is documented as
    # "things you looked at that were fine", rendered as one semicolon-joined
    # prose line, and never read here at all; the `unlisted` lane routes to
    # `escalations` and is handed only pictures, so it is structurally blind to
    # every command-line fault.
    #
    # `volunteered[]` is the one honest way through. It is FILED, beside
    # `gaps[]`, with its evidence — and it is fenced on all three sides:
    #
    #   * it is READ only here. `xo-criteria.py` never sees the key, and
    #     `xo-score.py` only COPIES it through (S263 — this file is handed the
    #     SCORED verdict and the raw one is deleted, so the lane was severed
    #     until it did). So a volunteered find still cannot touch the grade, the
    #     ledger, the `blockers[]` the send-back is decided from, or the
    #     recommendation. The CONTRACT-FIRST RULE stands: criteria come from the
    #     record, and a fault outside the contract is information, not a verdict.
    #   * it files AFTER every contracted gap and only into what the cap has
    #     left, so it can never push a contract breach off the list or renumber
    #     one. A contracted bug's PRD is byte-identical either way.
    #   * every sentence of its PRD says what it is — nobody's ask, a lower
    #     severity than a contract breach, and explicitly NOT the reason for any
    #     grade. The captain must be able to tell the two apart at a glance.
    vol = doc.get("volunteered") if isinstance(doc, dict) else None
    vol = vol if isinstance(vol, list) else []
    # ── AND IT MUST CITE SOMETHING, OR IT IS REFUSED BY NAME (S263) ──────────
    # The gate above asks only "does it say anything at all", which let an
    # unevidenced find through (see `vol_record` for the one rung that answers
    # it, and for the two generations of heuristic that were deleted to get
    # there). A refused find is SAID, with what is missing, and `xo.sh` keeps it
    # in the mission journal and in `xo/logs.json`: a refusal nobody receives
    # measures as nothing, and this is the lane where the captain is least able
    # to tell an observation from an opinion. The contracted lane is untouched —
    # it has a criterion and the score step's own instrument check behind it.
    #
    # AND THE RECORD IT CITED IS CARRIED WITH IT (fix round 2, D4). The first cut
    # threw the answer away and let the PRD re-resolve the citation through a
    # DIFFERENT ladder, and the two disagreed: a `testQuote`-cited find filed a
    # bug with no `Recorded in` clause at all — six sections of boilerplate a fix
    # worker could not open or grep. One question, one answer, and the answer IS
    # what the bug cites.
    #
    # AND AN ENTRY THAT IS DROPPED SAYS SO — THERE IS NO SILENT ARM LEFT (fix
    # round 3, FIX 3). Two filters used to stand above this loop: one dropped a
    # non-dict entry, the other dropped a dict with no `title` and no `saw`. Both
    # dropped it in SILENCE. MEASURED: `{"saw": 3, "shots": ["01-help.txt"]}` —
    # a find whose only words are a non-string scalar — came out of the scorer's
    # `carried_finds` with the number gone, hit the `title or saw` filter, and
    # vanished with FILED=0 and REFUSED=0: nothing printed, nothing journaled,
    # nothing in `logs.json`. Silence is this lane's documented failure mode and
    # the whole reason the session exists, so the two filters are now ARMS of
    # this loop and every one of them prints. (A `title`/`saw` that is a dict or
    # a list is recovered by the scorer's `_carried_strings` and is not this
    # case; this is the degenerate scalar, and the empty object.)
    kept = []
    for v in vol:
        if not isinstance(v, dict):
            print(RS.join(["REFUSED", VOL_WORDLESS, VOL_SHAPE_ASK]))
            continue
        said = clean(v.get("title")) or clean(v.get("saw"))
        if not said:
            print(RS.join(["REFUSED", VOL_WORDLESS, VOL_WORDLESS_ASK]))
            continue
        cite = vol_record(shotsdir, v)
        if cite:
            kept.append((v, cite))
        else:
            print(RS.join(["REFUSED", said or "(untitled)", VOL_CITATION_ASK]))
    vol = kept
    room = max(0, cap - len(fresh))
    overflow += max(0, len(vol) - room)
    vol = vol[:room]

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
        # WHAT GETS ATTACHED IS WIDER THAN WHAT GETS DESCRIBED (fix round 4,
        # D5). `shots` above is the look's own citation and keeps driving the
        # prose — including the "there is no screen here" line, which must not
        # change just because a fallback picture was attached. `attach` is the
        # wider list, and is the ONLY thing handed to xo.sh's --attach.
        attach = widen_shots(shotsdir, shots, row, g, instrument)
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
        # AND WHERE IT WAS OBSERVED, OFF THE STEP'S OWN READOUT (S250 D3). The
        # opener is the template's and stays; the clause after it is the fact.
        _where = where_observed(shotsdir, row, g)
        if _where:
            ac1.append(_where)
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
        also = fault_members.get(cid) or []
        if also:
            # NOTHING VANISHES. The pair is one fault and one bug — and the
            # restatement is named, so a fix worker can see both rows this
            # ticket settles rather than wondering where the second one went.
            ac1.append("The criterion is `%s`, written at %s, and your plan "
                       "restates the same requirement as %s — one fault, one "
                       "bug, both settled by this fix."
                       % (cid, where, ", ".join("`%s`" % m for m in also)))
        else:
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
        # Resolved through the SHARED ladder (S240 fix round 3): `sh + ".png"`
        # here was the same glue round 2 cured in `evidence_ref`, so a live
        # `01-help.txt` read as swept and went undescribed.
        present = [sh for sh in shots if shot_file(shotsdir, sh)]
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

        # SEVEN FIELDS, AND FIELD 4 IS STILL THE RECORD (fix round 4, D5).
        # Field 4 feeds `xo/logs.json` as this gap's `shots` — which is what
        # `xo recheck` reads to know which picture to re-take, and what
        # `tests/lcars-xo.test.sh` B12a2 asserts is EMPTY for a gap that stands
        # on a quoted test line. The first cut of this widening wrote the wider
        # list there and turned that `[]` into `["shot-01"]`: a FALLBACK
        # PICTURE had rewritten the gap's recorded evidence. A record and an
        # attachment are not the same fact, so they are not the same field.
        # Field 7 is the ATTACH list, read only by `--attach`.
        print(RS.join(["GAP", str(n), path,
                       ",".join(attach_path(shotsdir, sh) for sh in shots),
                       cid, title,
                       ",".join(attach_path(shotsdir, sh) for sh in attach)]))

    # ── AND THE VOLUNTEERED ONES, LAST AND PLAINLY LABELLED (S251) ───────────
    # Same writer, same evidence ladder, same `GAP` record the shell already
    # reads — a different lane is not a reason for a second output format. What
    # differs is every sentence of the prose, and the criterion id, which is
    # `volunteered-<k>` precisely BECAUSE there is no criterion.
    for k_i, (v, cite) in enumerate(vol, 1):
        n = len(fresh) + k_i
        cid = "%s%d" % (VOL_ID_PREFIX, k_i)
        # ── NOTHING OUTSIDE THE LOOK'S OWN DIRECTORY GETS PAST HERE ──────────
        # (fix round 2, D2). The guard above confines what COUNTS as a citation;
        # this confines what the bug SAYS and what is hung on the issue. Measured
        # before the cure: `{"evidencePath": "/etc/passwd"}` filed a PRD reading
        # ``Recorded in `/etc/passwd` (none).`` and a real `file-logs` argv
        # carrying `--attach /etc/passwd`, which `log.sh` stages into the mission
        # and onto the GitHub issue. So the name list is basenamed, and the three
        # path fields — the ones `evidence_ref` resolves against the process CWD
        # — are REPLACED on the copy this loop reads by the ONE record that
        # passed the guard. `evidence_ref` is then asked nothing it can get
        # wrong, and its four contracted call sites are untouched.
        # …and a record saved UNDER the shots directory is cited where it was
        # put (fix round 3, FIX 2). `vol_shot_name` returns a basename for a
        # flat name, exactly as this line's `os.path.basename` did, and the
        # containment-checked relative path for one in a subdirectory — so the
        # attach list and the PRD's own "what was recorded" tail land on the
        # SAME file the guard accepted instead of on a name that is not there.
        shots = [vol_shot_name(shotsdir, x) for x in cite_names(v, VOL_SHOT_FIELDS)]
        shots = bind_shots(shotsdir, shots, hash_id(
            " ".join([str(v.get("title") or ""), str(v.get("saw") or "")])))
        v = dict(v, shots=shots, shot=(shots[0] if shots else ""),
                 evidencePath=cite, transcriptPath="", transcript="")
        # AND `testQuote` IS NO LONGER AN INSTRUMENT HERE (fix round 2, D3). It
        # is not a citation route on this lane, so it must not name the
        # instrument the PRD then says the record was taken with.
        v.pop("testQuote", None)
        instrument = instrument_of(v, v) or "none"
        # THE RECORD THE GUARD ACCEPTED, VERBATIM — never re-resolved.
        ref = cite
        attach = widen_shots(shotsdir, shots, v, v, instrument)
        what = unstop(v.get("title")) or unstop(v.get("saw")) or "something the record does not cover"
        saw = unstop(v.get("saw"))
        expected = unstop(v.get("expected"))
        note = unstop(v.get("note"))
        title = "Not asked for — %s" % what

        ac1 = ["Observed live:"]
        _where = where_observed(shotsdir, v, v)
        if _where:
            ac1.append(_where)
        if unstop(v.get("action")):
            ac1.append("%s." % unstop(v.get("action")))
        if expected and saw:
            ac1.append("A person would expect %s; the build gave %s." % (expected, saw))
        elif saw:
            ac1.append("What the build gave: %s." % saw)
        if note:
            ac1.append("The look's own words: %s." % note)
        if ref:
            ac1.append("Recorded in `%s` (%s)." % (ref, instrument))
        ac1.append("NOBODY ASKED FOR THIS. No criterion in the record covers it, so "
                   "it is a lower severity than a contract breach, and it did not "
                   "change the grade or the recommendation on the look it came from.")
        acs = [" ".join(ac1)]
        acs.append("%s — fixed in the code that is already there, with a test that "
                   "fails before the fix and passes after it." % upfirst(what))

        goal = ("%s. The look volunteered this: it is information for you, not a "
                "judgement against the milestone, and it was filed at a lower "
                "severity than a contract breach for that reason. Nothing about it "
                "moved the grade. Close it unfixed if you do not want it."
                % upfirst(what))

        out_of_scope = [
            "Re-grading the milestone. No criterion covers this, so it changed "
            "nothing about the verdict and fixing it changes nothing either.",
            "Writing a criterion for it after the fact. If you want it in the "
            "contract, that is yours to put in the record, not a fix worker's.",
        ]
        for other, _k in picked:
            out_of_scope.append("`%s` — a criterion the record DOES name. Filed as "
                                "its own bug; not this one." % other)
        out_of_scope = out_of_scope[:4]

        constraints = [PLAN_RULE,
                       "Keep the project's existing stack, permission model and test "
                       "conventions. No new dependency to fix one field.",
                       "This one is OPTIONAL. Nobody wrote it down, so a decision not "
                       "to do it is a legitimate answer and needs no justification."]

        tail = []
        present = [sh for sh in shots if shot_file(shotsdir, sh)]
        if present:
            tail.append("What Number One recorded while it was looking at something "
                        "else: %s." % ", ".join(present))
        tail.append("This came from the look's `volunteered` list — the lane for a "
                    "fault it saw that no acceptance criterion asks about. It is "
                    "filed so you can see it, at a lower severity, and it is "
                    "deliberately fenced out of the score.")

        path = os.path.join(outdir, "%d.md" % n)
        write_prd(path, title=title, seam="none", goal=goal, acs=acs,
                  out_of_scope=out_of_scope, constraints=constraints, tail=tail)
        print(RS.join(["GAP", str(n), path,
                       ",".join(attach_path(shotsdir, sh) for sh in shots),
                       cid, title,
                       ",".join(attach_path(shotsdir, sh) for sh in attach)]))

    if overflow:
        print("OVERFLOW" + RS + str(overflow))
    return 0


if __name__ == "__main__":
    sys.exit(main())
