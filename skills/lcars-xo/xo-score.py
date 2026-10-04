#!/usr/bin/env python3
"""xo-score.py — validate the worker's verdict, then DERIVE the score from it.

    python3 xo-score.py <xo-verdict.json> <criteria.json> <out verdict.json>
                         [<observations.json>] [<tests.json>]

THIS IS THE HEART OF THE SESSION: the model reasons, the skill decides.

THE FOURTH ARGUMENT is optional and is S210's: `xo-observe.py`'s output, the
OBSERVATIONS pass (crowding, overlap, a misaligned row, clipped text — things
no drawing ever states, computed from the same boxes the worker looked at).
They are rendered into their own section of `report.md`, below, and NOTHING
ABOUT THEM EVER TOUCHES THE SCORE: this file's derivation reads only the
ledger and the contract, exactly as it did before observations existed, and an
`observations.json` full of findings changes not one character of `score` or
`derivation`. If it is missing, or empty, the section is simply not written —
a mission with no observations reads exactly as one with the argument omitted.

THE FIFTH ARGUMENT is S211's: `xo-tests.py`'s record of the project's OWN test
suite, run by the skill in the launched build's worktree before the worker ever
looked. It does two things here and no more:

  * It lets a `notVisual` criterion — one that makes no visual claim at all, and
    that a screenshot therefore can never settle — be answered by the project's
    own tests, cited exactly as a picture is cited.
  * It is the RECORD the over-claiming guard checks a citation against.

THE OVER-CLAIMING GUARD, WHICH IS THE POINT OF S211. **A passing suite does not
prove a criterion the suite does not speak to.** So a `met` whose evidence is
the tests must name the LINE of test output that settles it, and that line must
be findable in the output actually recorded. Lean on the green alone — no line
cited — and the honest answer stands: "I could not check this." The same holds
if the suite never ran, or hung: a suite that did not finish settles nothing,
and a hang is trouble running the tests, never a fault in the build.

THE EVIDENCE KIND IS RECORDED, NOT INFERRED (S211). Every ledger line carries
where its judgement came from — `picture`, `measurement`, `tests`, or `none` —
declared by the worker that made the judgement, or, when it declared nothing,
taken from the structural fact that it cited a shot. It is NEVER worked out
afterwards by reading the wording of a note. Four rounds of this project
(S147, S156, S188, S212) were lost to code that read back text a human also
writes.

THE NO-DRAWING GUARD (S210) is the other new thing here. `criteria.json` now
carries `hasDrawing` (xo-criteria.py) — the plain fact of whether this mission
was ever handed a holodeck drawing at all. When it was not, every criterion the
plan marked `drawnAt` is forced to `untested` with one fixed sentence, WHATEVER
THE WORKER WROTE — this is the one place in this file that overrules the
worker's own rating rather than merely checking its citation, because "I could
not check this against a drawing, because there isn't one" is not a judgement
call available to get right or wrong; it is a fact about the mission's own
attachments, and the skill knows it before the worker ever looks.

Number One writes a ledger — one line per criterion, met / gap / untested, each
citing the shot that shows it — and a score of its own. **The score it wrote is
a recommendation.** The score that gets recorded, labelled and shown to the
captain is recomputed HERE, from the ledger, by a rule anyone can check:

    (S216 — the captain's two-part score: IMPACT x OUTCOME; see "THE TWO-PART
    SCORE" below. It superseded S203's contradiction-driven table. S225 then
    split the ledger three ways and took the blind rows out of the rule.)
    nothing on this list                            → LOW
    a HIGH-impact item didn't work                  → LOW     core broken
    nothing on this list was checked at all         → LOW     nothing vouched for
    HIGH items exist and NOT ONE was checked        → LOW     core unverified
    every high worked; a MEDIUM didn't work         → MEDIUM  go with known issues
    every high and medium worked                    → HIGH    (low never moves it)

THREE QUESTIONS, NOT ONE GRADE (S225 change 01). The ledger splits on the
`source` every criterion has always carried: `prd` + `journey` are the PERSON
group ("can a person do what it promises?"), `drawing` is its own graded line,
and `plan` — the ticket acceptance criteria — is a COVERAGE COUNT and not a
grade at all. `score` is the PERSON group's grade and nothing else, by the
captain's ruling of 2026-09-22: his build scored LOW on a ledger where 57% of
the rows were ticket criteria a walk can never answer and the nine things a
person can actually do scored 8 of 9.

FOUR OUTCOMES, AND ONLY TWO OF THEM GRADE (S225 change 03). Every row carries
`outcome`: worked / didnt-work / couldnt-see / couldnt-set-up. `status` is
unchanged beneath it. A row nobody could check no longer moves the grade in
either direction; it is listed for US to fix in `myChecking`.

If the worker's score disagrees with its own ledger, the LEDGER WINS and the
disagreement is recorded (xo.sh journals it). A free-floating score is the one
thing an LLM judge is worst at and a rule is best at; a per-criterion ledger is
the opposite. So each does the half it is good at.

TWO CITATION GUARDS, both of them anti-OVER-REJECTION:

  * A `met` or `gap` with NO SHOT is not evidence of anything. It is downgraded
    to `untested` with a note. The tester brief calls a gap without a shot a
    DEFECT; this is what makes producing one impossible rather than merely
    discouraged.
  * A CONTRADICTION with no shot is demoted to an INTERPRETATION — reported to
    the captain, not filed against the build. The known failure in this seat is
    reasoning past the record into confident faults, and a picture is the cheap
    guard against it.

A criterion in the contract the worker never rated is `untested` too, with a
note saying so. It is never silently dropped: the contract was written before
the look, and a look that skipped part of it is a look with a hole in it.

THE SIXTH ARGUMENT is S216 fix round 1's: the mission's own `xo/impacts.json`,
THE RECORD OF HOW MUCH EACH REQUIREMENT MATTERS. Two Copilot looks at the same
build disagreed on 21 of 31 impacts, and the grade's HIGH-vs-MEDIUM hung on
it. So importance is RECORDED, not re-guessed: the first look that rates an id
writes its impact (with when, and which engine) and every later look — and
every recheck — reuses it; the look's new impact for that id is ignored and the
disagreement handed to the journal (IMPACT_KEPT). Only ids the record has never
seen take this look's impact. With no sixth argument nothing is read or
written, exactly as before. The engine is `$LCARS_XO_ENGINE`.

Output on stdout, one TAB-separated record per line, for the shell to read:
  MALFORMED <why>                 | SCORE <s> / WORKER_SCORE <s> / DISAGREED yes|no
  WHY <the derivation, in words>  | COUNTS <met> <gap> <untested> <contradictions>
  MEANING <what the score word means for THIS ledger — never a fixed sentence>
  GRADE_WHY <why this grade, the table walked in words> | CORE <met|broken|unverified|>
  IMPACT_KEPT <id> <recorded> <this look's>  | IMPACT_MISMATCH <id> <id> <impact> <impact>
  TEST_DEMOTED <id> <rated> <quote>  — a test citation that settled nothing (T1)
  SCORE_GROUP <group>  — which of the three the headline was read from (S225)
  GROUP <key> <kind> <grade|-> <total> <worked> <didnt> <couldntSee> <couldntSetUp>
  OPEN <n>  — rows still open ANYWHERE; the score word no longer implies zero
"""
import json
import os
import re
import sys
import time

VALID_SCORES = ("high", "medium", "low")
VALID_STATUS = ("met", "gap", "untested")
# WHERE A JUDGEMENT CAME FROM. The captain must never have to guess which of
# these decided a line (S211): a picture of the running app, the transcript of
# something the harness RAN, a box measured off that page, or his project's own
# tests. `none` is the honest last one — nothing settled it.
#
# `transcript` is S239 fix round 1 (D1). The reach steps put a command's exact
# output on disk beside the shots, and on the first real look EVERY row read
# `"evidence": "picture"` — including a gap whose only citation was
# `01-help.txt`, a terminal transcript. There was no honest word for it, so the
# look used the only one the schema offered and the table told the captain it had
# looked at a screen.
VALID_EVIDENCE = ("picture", "transcript", "measurement", "tests")


def shot_name_evidence(name):
    """The evidence word a shot's own FILENAME implies (S240 fix round 2, D-C).

    The reach steps keep a command's exact output in a `.txt` and its parsed
    readings in a `.json` beside the pictures, and a live worker cites those by
    their full name. So `02-workflow-run.txt` is a transcript and
    `round1-01.json` is a measurement, while `shot-01`, `round1-01.png` and
    anything else at all stay `picture` — the structural default is unchanged for
    every genuine screenshot."""
    low = str(name or "").strip().lower()
    if low.endswith(".txt"):
        return "transcript"
    if low.endswith(".json"):
        return "measurement"
    return "picture"
EVIDENCE_WORD = {"picture": "a picture", "transcript": "a transcript",
                 "measurement": "a measured box", "tests": "your tests",
                 "none": "—"}

# WHICH INSTRUMENT SETTLED THE ROW — recorded by the look, never worked out here
# (S239 fix round 1, D1). Produced on every step readout (`xo-run.py`), taught by
# the prompt, and now carried onto the ledger line the captain reads. An
# unrecognised word is DROPPED exactly as `kind` is: a guessed instrument is the
# very thing this cures.
VALID_CHECKED_BY = ("browser", "cli", "workflow", "test")

# THE FAILING RUN'S SENTENCE, AND THE ONE CASE THAT RESOLVES IT (fix round 2,
# R2-2). Round 1 stopped this sentence guessing which of the two things a
# non-zero exit meant — a red test of the captain's, or a runner that never
# started — because nothing this skill knows can tell them apart at the moment
# the suite exits. It then stayed agnostic FOREVER, in the most prominent
# position on the page, on a report that went on to quote a CHECKED failing
# line three inches below. That under-states a confirmed fault.
#
# By the time the report is written the ambiguity may have been settled, by the
# one thing that can settle it: a quoted line, found in the recorded output,
# through the same guard every other citation goes through. When it has, the
# clause is swapped for one that says so. When it has not — the crashed runner,
# which is round 1's whole cure — the agnostic clause stands word for word.
#
# FAILED_AMBIGUOUS is xo-tests.py's own literal, repeated here (they are two
# processes, and the file names cannot be imported) and pinned by a test that
# asserts the two are byte-identical. If they ever drift, the resolved clause
# is APPENDED instead of swapped, so the captain still gets the fact.
FAILED_AMBIGUOUS = ("A failed run can be a test of yours going red or a test runner "
                    "that never started, and the exit code does not say which, so I "
                    "have not counted it against the build on its own.")
FAILED_RESOLVED = ("A failed run can also be a test runner that never started, but this "
                   "one is not that: a test of yours went red, I found the line it "
                   "printed in the output, and I have counted it against the build.")


def tests_sentence(tests, resolved):
    """The run's own recorded verdict — with its one hedged clause swapped out
    when, and only when, a checked failing line has resolved the hedge."""
    said = str(tests.get("verdict") or "").strip()
    if not resolved or str(tests.get("outcome") or "") != "failed":
        return said
    if FAILED_AMBIGUOUS in said:
        return said.replace(FAILED_AMBIGUOUS, FAILED_RESOLVED)
    return (said + " " + FAILED_RESOLVED).strip()


# THE ONE SENTENCE (S210). Byte-identical wherever it is written, because it is
# a fact ("there is no drawing"), not prose a worker composed — and a test that
# wants to be sure the honest answer was given, not a paraphrase of it, can
# match this string.
NO_DRAWING_NOTE = "I could not check this against a drawing, because there isn't one"

# S220 PART B — THE PARTS THE BUILD HAS NOT GOT, and the differences a look
# waved away. Both come from `xo/pairs.json`, which is arithmetic: the drawing
# had this part, the build either has it or it does not, and the icon either
# fits its button or it does not.
UNREACHABLE_PART_NOTE = ("your drawing names this part and I could not find it in the "
                         "build, so there was nothing to look at — couldn't check")


def load_pairs(path):
    """`{part id: pair}` from xo/pairs.json — empty when there is no pairing.

    Best-effort exactly like the observations pass: a look with no drawing, or
    a drawing pass that could not run, must still be able to finish a verdict.
    """
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except Exception:
        return {}
    out = {}
    for p in (doc.get("pairs") if isinstance(doc, dict) else []) or []:
        if not (isinstance(p, dict) and p.get("part")):
            continue
        key = str(p["part"])
        # A FOUND PART BEATS A NOT-FOUND ONE UNDER THE SAME KEY (S224 item 1).
        # A drawing that stacks its screens on one page draws "Cancel" twice;
        # the pairer now folds those into one entry, but a pairs.json written
        # by an older drive still has both, and last-wins made the NOT-FOUND
        # one the answer — which is how `part-lock month` came back "I could
        # not find it in the build" on the S222 capstone while a crop of that
        # very button sat beside it. Nothing here can turn a part the build
        # has not got into a reachable one: the reachable entry has to exist.
        prev = out.get(key)
        if prev is not None and prev.get("reachable") and not p.get("reachable"):
            continue
        out[key] = p
    return out

# A PICTURE IS NOT A DRAWING (S217). S214/S215 measured a mission whose only
# design was a PNG: no drawing, no place names, no `drawnAt` — so the guard
# above had nothing to overrule, verify_unfenced_note never fired, and the
# comparison silently did not run. Filing cannot refuse it, because nothing
# records whether a picture was meant as THE design or as context (see
# xo-criteria.py `pictures`). So it is SAID, here, as a fact that holds either
# way, at the head of the one line the card shows. Byte-identical everywhere.
PICTURE_NOT_DRAWING = ("your attachment is a picture, so I could not check the "
                       "build against a drawing")
# The headline's short lead (S216 fix round 2, W1/W2) — the same words the
# board's picture label uses; the headline has a word budget.
PICTURE_LEAD = "Your attachment is a picture, not a drawing."
HEADLINE_WORDS = 25
LIST_NAME = 40      # a name inside a list of three, on a phone


def word_count(text):
    """Words a reader reads: a dash or a bracketed id on its own is not one."""
    return sum(1 for w in str(text or "").split() if re.search(r"[^\W_]", w, re.UNICODE)
               and not re.fullmatch(r"\([\w-]+\)[.,;]?", w))

# WHAT TO DO ABOUT IT, said once (S217 fix round 1, D1). report.md prints it and
# the verdict RECORDS it under pictureNotDrawing.fix, so the ◈ Number One tab
# reads the scorer's own words instead of carrying a second copy that could drift.
PICTURE_FIX = ("To have me check it against one, attach an `.html` mock-up "
               "whose element `id`s name the parts, plus a `concept.md` saying "
               "what it must do — the holodeck makes both for you.")


# A CELL THE CAPTAIN CAN READ (fix round 1, D7). A hard `[:160]` cut the
# evidence mid-word and landed on an open quote — `…and no '` — which reads as a
# rendering bug, not as a finding. Cut at the last word boundary inside the
# budget instead and SAY that it was cut, with one ellipsis.
def clip(text, n):
    t = " ".join((text or "").split())
    if len(t) <= n:
        return t
    head = t[:n]
    cut = head.rfind(" ")
    if cut < n // 2:          # one very long token: there is no boundary to find
        cut = n
    return t[:cut].rstrip(" ,;:-") + "…"


# ONE FULL STOP, NOT TWO (fix round 1, D7). The gap bullet appends its own `.`
# after the worker's `saw` text, and a worker that ended its sentence produced
# `…(readout)..`. Strip a trailing stop from the fragment; the template adds it.
def cite(g):
    """The brackets at the end of a finding: the shot the captain can open, and
    the criterion id, in that order. THE HUMAN SENTENCE COMES FIRST and the id
    goes in the brackets after it (captain's ruling, 2026-09-13) — an id is for
    a machine, and reading one first is reading the wrong thing first."""
    if str(g.get("evidence") or "") == "tests":
        # S211: this one was settled by the project's own suite. Saying "no
        # shot" of it would read as a missing picture rather than as a
        # different kind of evidence.
        bits = ["your tests"]
    else:
        bits = ["see " + ", ".join(g["shots"])] if g.get("shots") else ["no shot"]
    cid = str(g.get("criterion") or "").strip()
    if cid:
        bits.append(cid)
    return "; ".join(bits)


def unstop(text):
    return (text or "").rstrip().rstrip(".")


def bad(why):
    print("MALFORMED\t" + why)
    sys.exit(0)


def load(path, what):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except Exception:
        bad("no %s was written" % what)
    try:
        return json.loads(raw)
    except Exception:
        # A worker that fenced its JSON has still answered; unwrap the one
        # outermost object rather than refuse over punctuation (the S202
        # precedent). Anything else is a genuine malformation.
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            bad("the %s is not JSON" % what)
        try:
            return json.loads(m.group(0))
        except Exception:
            bad("the %s is not JSON" % what)


def load_observations(path):
    """Best-effort: no fourth argument, a missing file, or a file with nothing
    in it are all the same case — no observations section, no thresholds
    printed, exactly as if S210 had never happened for this look."""
    if not path:
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except Exception:
        return None
    if not isinstance(doc, dict):
        return None
    obs = doc.get("observations")
    if not isinstance(obs, list):
        obs = []
    # ONE FILTER WAS EATING THE FINDINGS THE BENCHMARK WAS COUNTING (fix round
    # 1, D5). The layout pass (S210) writes `message`; the part-by-part
    # measurement (S220 B) and the journey's carry/gate checks (S220 F) write
    # `says`. This line asked for `message` and nothing else, so the four
    # oversized-icon findings and the August→September carry — the very things
    # the drill scored as FOUND — were dropped on the floor before the report
    # was written, and the captain's red list came up two short of the number
    # he was being given. A finding the score counts and the report hides is
    # the false green this whole session exists to kill. So both words are
    # read, and where each came from is kept.
    kept = []
    for o in obs:
        if not isinstance(o, dict):
            continue
        said = o.get("message") or o.get("says")
        if not said:
            continue
        o = dict(o)
        o["message"] = said
        # `says` means a detector measured or walked it: it is about a part of
        # the drawing or a step of the flow, not a loose thing noticed on a
        # page, and it is printed under its own heading.
        o["reportedUnder"] = "measured" if o.get("says") else "layout"
        kept.append(o)
    return {
        "observations": kept,
        "thresholds": doc.get("thresholds") if isinstance(doc.get("thresholds"), dict) else {},
        "elementCount": doc.get("elementCount"),
        # S212: when the list was capped, the pass says so in a sentence, and
        # that sentence has to reach HIM. A short list he believes is the whole
        # list is worse than a long one.
        "notes": [n for n in (doc.get("notes") or []) if isinstance(n, str) and n.strip()],
        # S212 round 5: the ONE silence that is left. The look now only writes
        # something off as unseen when it POSITIVELY established that something
        # solid was over it, which makes this rare, legitimate — and cheap to
        # say out loud. It was in the record and never in his copy, so the one
        # thing the look admits it could not see was the one thing he could
        # not read.
        "unseenCount": doc.get("unseenCount"),
    }


def load_tests(path):
    """`xo/tests.json`, exactly as xo-tests.py wrote it, or None when this look
    never had one (the four-argument call every pre-S211 caller makes). None and
    "the file is unreadable" are the same case on purpose: a look with no record
    of a test run has no test evidence, which is the safe direction."""
    if not path:
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except Exception:
        return None
    if not isinstance(doc, dict) or not doc.get("outcome"):
        return None
    return doc


# A REAL TEST RUNNER COLOURS ITS OUTPUT. `bash tests/…` and vitest alike emit
# SGR escapes mid-line, so the recorded tail holds "\x1b[32mPASS\x1b[0m B13 …"
# while the sentence a reader would copy out of it is "PASS B13 …". Comparing
# the two verbatim would refuse a perfectly good citation. So the escapes and
# the whitespace are normalised on BOTH SIDES for the comparison only — the
# recorded output itself is never rewritten.
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def norm_for_match(text):
    return " ".join(ANSI.sub("", str(text or "")).split())


# A LINE THAT IS ONLY A TALLY (S211 fix round 1, D4). `413 passed, 0 failed`,
# `Tests: 1 failed, 41 passed`, `ℹ pass 2`, `Duration 1.23s`, a bare `PASS` —
# a whole CLASS of line that can never settle ANY criterion, because it names
# no subject at all. Hand-fed one of these as a citation, the guard used to
# find it in the output, accept it, and score HIGH.
#
# THIS IS NOT A RELEVANCE JUDGEMENT AND NOT A PROSE CLASSIFIER. The guard still
# cannot tell whether a line is ABOUT a criterion — that is declared, and rests
# on the prompt. This asks a structural question instead: drop the digits and
# the punctuation, drop a fixed list of tally words, and see whether the line
# mentions anything whatsoever. `PASS batches survive a restart` keeps three
# words and is accepted exactly as before; `413 passed, 0 failed` keeps none,
# so there is nothing for it to be about, whatever the criterion is.
# BOTH EDGES OF THIS BELT WERE WRONG (fix round 2, R2-3) and the words moved
# in both directions. OUT: `ok` and `case`/`cases`, which are not counts at all
# — they cost the belt `✔ 200 OK (1ms)` and `✔ case 3 passed (1ms)`, two
# perfectly ordinary test names, and `200 OK` is exactly the API-shaped name
# this session exists to serve. IN: `all`, which is what let jest's
# `Ran all test suites.` through. Nothing here reads a runner's PROSE: a word
# is either in this list or it is not.
TALLY_WORDS = frozenset("""
pass passed passes passing fail failed fails failing failure failures
skip skipped skipping todo pending cancelled canceled
test tests testing suite suites spec specs file files
assertion assertions checks
total totals count counts all
duration elapsed time took start started finish finished
ran run runs
of in and or
s ms us ns sec secs second seconds m min mins minute minutes h hr hrs
""".split())

# THE SUMMARY LINES THE WORD LIST CANNOT SEE. A runner's own summary can name
# its subject in ordinary words and still count nothing whatsoever. These are
# matched as the fixed strings the runners print them as — not as a guess at
# what a summary sounds like.
# EACH ONE CARRIES ITS COUNT, so a test of the captain's that happens to start
# with one of these words is not refused for its first word alone.
SUMMARY_LINES = (
    re.compile(r"^ran all test suites"),
    re.compile(r"^(test suites|test files|tests|snapshots|time|duration)\s*[:=]\s*\d"),
    re.compile(r"^passed!.*\bfailed\s*[:=]\s*\d"),
)


def is_marker(word):
    """A RUNNER'S MARKER GLYPH IS NOT A WORD. `node --test` prefixes every
    summary line with `ℹ`, which Unicode classifies as a LETTER (category Ll,
    the Letterlike Symbols block) — so `ℹ 413` came back carrying one "word"
    and sailed through a guard whose whole job was to refuse it. Everything in
    U+2100–U+214F is a symbol drawn from letters, never a name."""
    return all(0x2100 <= ord(ch) <= 0x214F for ch in word)


def tally_refusal(text):
    """WHY THIS CITATION NAMES NOTHING — or "" when it does name something.

    Three refusals, each narrow, and NOTHING ELSE IS REFUSED (fix round 2):
    a citation with no words in it at all cannot name anything; a runner's own
    summary line counts and names nothing; and a line with nothing left once
    the counting words are taken out is a count. A line that still names
    something after that is a test name and is accepted — including one whose
    name happens to be `200 OK`.

    The sentence it returns says what it COULD NOT FIND. It used to declare
    what the line WAS ("the only line you quoted is a tally of how many tests
    passed or failed"), which for the captain's own `✔ 200 OK (1ms)` was
    simply untrue — and a guard that is wrong out loud is worse than one that
    is merely cautious."""
    t = " ".join(str(text or "").split())
    if not t:
        return ""
    # ANY SCRIPT, NOT JUST LATIN. `[A-Za-z]+` found no words in
    # `✔ 批次在重启后仍然存在` and, on the old empty-list branch, ACCEPTED it by
    # accident while ALSO accepting `ℹ 413`. Word runs here are letters in any
    # script, so the Chinese name is a word and the bare count is not.
    words = [w for w in re.findall(r"[^\W\d_]+", t, re.UNICODE) if not is_marker(w)]
    if not words:
        return ("the line you quoted has no words in it at all — nothing but a count "
                "of how many — so there is nothing in it that could name what you "
                "asked for")
    low = t.lower()
    for pat in SUMMARY_LINES:
        if pat.search(low):
            return ("the line you quoted is your test runner's own summary — a count "
                    "of how many tests ran — and I could not find a test name in it, "
                    "so I cannot tell which of your tests speaks to this one")
    if all(w.lower() in TALLY_WORDS for w in words):
        return ("I could not find a test name in the line you quoted — take out the "
                "count of how many passed and failed and there is nothing left of it "
                "— so it cannot settle this one whatever it says")
    return ""


# ─── A TEST CITATION MUST NAME A TEST CASE (S216 fix round 2, T1) ───────────
#
# THE DEFECT. Two looks at one build were handed the same test output, which
# named only FILES and counts — `✓ src/renderer/utils.test.ts  (9 tests) 2ms`.
# One look called seven items "met by tests" on that line, the other refused
# them as unobservable, and the grade moved HIGH↔MEDIUM on nothing but a
# re-guess. There was no rule for what "met by tests" needs. This is the rule:
# a row stands as MET on test evidence ONLY if the line it cites names a test
# CASE — a file name, alone or with its count, names none — and that line is in
# the recorded output. When xo-tests.py recorded the case names (`testCases`),
# the citation must also contain one of them, whole. Everything is decided
# from the recorded output and the recorded names; nothing reads the worker's
# prose.
NOT_NAMED = "your tests ran, but none I could see is named for this"
FILE_TOKEN = re.compile(r"(?<!\S)\S*(?:/\S*|\.(?:[cm]?[jt]sx?|py|rb|go|rs|java|kt|cs|php|svelte|vue))(?!\S)")


def names_only_a_file(q):
    """True when the citation, once its file names are taken out, is nothing
    but glyphs, counts and tally words — a file-level line, not a test case."""
    rest = FILE_TOKEN.sub(" ", q)
    if rest.strip() == q.strip():
        return False                       # no file in it at all
    rest = rest.replace(">", " ")
    words = [w for w in re.findall(r"[^\W\d_]+", rest, re.UNICODE) if not is_marker(w)]
    return all(w.lower() in TALLY_WORDS for w in words)


def case_leaves(tests):
    """The recorded test-case names a citation may contain — each case's last
    ` > ` segment, normalised, keeping only ones that name something."""
    out = []
    for c in (tests or {}).get("testCases") or []:
        leaf = norm_for_match(str(c).split(" > ")[-1])
        if leaf and not tally_refusal(leaf) and leaf not in out:
            out.append(leaf)
    return out


def tests_settle(tests, quote):
    """CAN THE PROJECT'S OWN TESTS SETTLE THIS ONE? → (yes/no, why not).

    Every branch below is decided from a FACT xo-tests.py recorded at the moment
    it ran — the outcome it derived there, and the output it kept — never from
    the wording of anything a model wrote. The second half of the tuple is the
    sentence the captain reads when the answer is no."""
    if not tests or not tests.get("ran"):
        why = "this repo has no test command set, so I have nothing from your tests to go on"
        if tests and tests.get("outcome") == "no-worktree":
            why = ("I could not find the checkout the build was launched from, so your "
                   "tests never ran")
        return False, why
    outcome = str(tests.get("outcome") or "")
    if outcome == "hung":
        return False, ("your tests were still running when I stopped them, so they "
                       "settled nothing either way")
    if outcome == "could-not-run":
        return False, "I could not start your tests at all, so they settled nothing"
    q = norm_for_match(quote)
    if not q:
        # THE OVER-CLAIMING GUARD ITSELF. A green suite is not a blanket proof;
        # the line that speaks to THIS criterion is what proves it.
        return False, ("your tests pass, but nothing in your test output speaks to this "
                       "one, so a green run does not tell me it is there")
    names_nothing = tally_refusal(q)
    if names_nothing:
        return False, names_nothing
    if names_only_a_file(q):
        return False, NOT_NAMED
    cases = [norm_for_match(c) for c in (tests.get("testCases") or [])]
    hay = norm_for_match(tests.get("outputTail"))
    if q not in hay and not any(c and (q in c or c in q) for c in cases):
        cut = ("  (I only kept the last %s bytes of it)" % tests.get("tailCapBytes")
               if tests.get("truncated") else "")
        return False, ("I could not find that line in your test output, so I am not "
                       "going to say your tests proved it%s" % cut)
    leaves = case_leaves(tests)
    if leaves and not any(leaf in q for leaf in leaves):
        return False, NOT_NAMED
    return True, ""


HIDDEN_WORDS = {1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five",
                6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten",
                11: "Eleven", 12: "Twelve"}


def hidden_sentence(n):
    """What it could not look at, said the way he would say it — and nothing
    at all when there was nothing."""
    if not isinstance(n, int) or n < 1:
        return None
    if n == 1:
        return ("One thing on this page was behind something solid, so I "
                "could not look at it.")
    return ("%s things on this page were behind something solid, so I could "
            "not look at them." % HIDDEN_WORDS.get(n, str(n)))


# ─── S216: THE TWO-PART SCORE ────────────────────────────────────────────────
#
# The captain's own grading method, and it IS the score (verify-pass-dev.md,
# rulings Q1 + the last word, which outranks the research):
#
#   BEFORE LOOKING  each requirement has an IMPACT — high (the point of the
#                   mission: a reasonable person would block the merge if it
#                   did not work), medium (a stated requirement that works but
#                   not as asked, or is secondary to the point), low (polish).
#   AFTER LOOKING   each one worked (MET) / didn't (GAP) / couldn't check
#                   (UNTESTED) — the machine words stay underneath.
#
#   first match wins:
#     nothing on the list at all, or nothing on it checked      → LOW
#     any high didn't, or any high couldn't be checked          → LOW
#     every high worked; a medium didn't or couldn't be checked → MEDIUM
#     every high and medium worked                              → HIGH
#   Low-impact outcomes never move it. A row with no impact counts as HIGH
#   (the careful reading) and the reasoning says so.
#
# What the research ADDS sits BESIDE the grade and never moves it: `core`
# (met / broken / unverified — a high that failed and a high nobody could see
# are both LOW but read differently), `altReading` (only when a risk-based
# reviewer would read it differently), `polishFlag` (small things piling up).
VALID_IMPACT = ("high", "medium", "low")
COULD_NOT_CHECK = ("unreachable", "unobservable")

# ─── WHOSE FAULT A BLIND ROW IS — RECORDED, NEVER INFERRED (S240) ────────────
#
# `couldNotCheck` says WHAT stopped the check (`unreachable`, `unobservable`).
# It has never said WHOSE it is, and the two answers lead opposite ways: a high
# row nobody could reach because THE BUILD SHIPS NO WAY IN is the work not being
# done (send it back, and file it); the same row unreachable because a runner is
# not installed on this laptop is OUR problem (merge, and fix the rig). The
# weekend's own policy table split `low` on exactly this word and a human
# supplied it by hand every time.
#
# SO THE LOOK RECORDS IT, and an absent record is treated as INFRASTRUCTURE.
# That is not a shrug, it is the honesty rule this file already won: "a blind row
# is a failure of OURS reading as a doubt about HIS build" — so an unrecorded
# cause may never become a send-back or a filed bug against the captain's work on
# a guess. `causeRecorded` says out loud which of the two happened.
CAUSE_CLASS = ("product", "infrastructure")

# ─── THE HEADLINE IS AN ACTION, NOT AN ADJECTIVE (S240) ──────────────────────
#
# THE MEASURED DEFECT. `verdict.json` ended at `score: low|medium|high`, and the
# weekend playbook's § 4 ("pass + high -> merge; pass + medium -> merge with
# follow-ups; pass + low + product -> send back") was then applied BY HAND on
# every single look. The grade is not the decision and never was: the archive has
# a `high` standing on 83% coverage against a floor of 80, with the two numbers
# that decided it absent from the report the captain read.
#
# So the policy becomes the reviewer's own, derived here off the SAME ledger the
# grade came from, and sitting ABOVE it. The grade ladder (`derive_grade`) is not
# touched — `score` still means exactly what it meant.
RECOMMENDATIONS = ("merge", "merge-with-follow-ups", "send-back")
RECOMMENDATION_WORD = {"merge": "MERGE",
                       "merge-with-follow-ups": "MERGE WITH FOLLOW-UPS",
                       "send-back": "SEND-BACK"}
OUTCOME_WORD = {"met": "worked", "gap": "didn't", "untested": "couldn't check"}
POLISH_PILE = 5

# ─── THE COVERAGE FLOOR ON A GRADED RAIL (captain's ruling, 2026-09-24) ──────
#
# THE MEASURED DEFECT, on lcars-20260921-007-8cb0. `all-worked` asks only
# whether anything FAILED and is blind to how much was never checked, so the
# drawing rail read HIGH having checked 8 of 14 of its own items (57%). The
# captain's own policy — "HIGH because everything I could check worked" — is
# coherent at 95% coverage and indefensible at 57%. His ruling: unchecked must
# pull the grade down on the two GRADED rails (person, drawing), but a working,
# good-looking build must not be dragged to LOW for it.
#
# THE THRESHOLD, STATED. A graded rail must have ACTUALLY CHECKED (worked or
# didn't-work — the two "couldn't" outcomes are not checks) at least 80% of its
# own items to read HIGH. Between the half-checked floor (50%, `too-little-
# checked` → LOW) and this floor, with nothing failed, the rail is HELD BACK
# one notch to MEDIUM. Coverage only ever LOWERS a grade; a real failure
# (`high-broken`, `medium-open`) fires first and always dominates it. The
# contract rail is `kind: "coverage"` and is NEVER graded, so this never
# touches it.
HIGH_COVERAGE_PCT = 80


# ─── S225 CHANGE 01: THREE GROUPS, NOT ONE GRADE ─────────────────────────────
#
# THE MEASURED DEFECT. Number One graded the captain's build LOW; he drove it
# himself and scored it HIGH. Its own record says the whole reason:
#
#   ticket acceptance criteria  58 rows  57%   39 answered · 19 nothing covers
#   PRD statements              21 rows  21%   18 met · 2 couldn't check · 1 fault
#   parts from the drawing      14 rows  14%   5 met · 3 faults · 6 couldn't check
#   a person clicking through    9 rows   9%   8 met · 1 couldn't check
#
# The one thing a person can actually SEE was under a tenth of the grade and
# scored 8 of 9 — and was then averaged against 58 ticket criteria that a walk
# can never answer. The machine had his answer and averaged it away.
#
# Every criterion has carried a `source` since the moment it was written
# (xo-criteria.py, xo-parts.py, xo-journey.py). NOTHING DOWNSTREAM EVER READ IT
# to change how grading works. That was the bug, and this is where it is read.
#
#   1. person   journey + prd   "Can a person do what it promises?"  THE HEADLINE
#   2. drawing  drawing         "Does it look like your drawing?"    its own line
#   3. contract plan            "Is the contract covered?"           NOT A GRADE
#
# THE CAPTAIN RULED THIS EXPLICITLY, 2026-09-22, and it is not to be re-decided
# in a build: the single headline grade — the one word the report rail and the
# board card show — reads GROUP 1, the person group. NOT the worst of the three.
# On the recorded run group 1 reads 26/30, which is HIGH, which is the score he
# gave it himself. The drawing line sits beneath it and is NEVER hidden; it
# simply stops setting the headline, because a fault there is real but rarely
# stops anyone using the thing. The contract group is a COVERAGE COUNT — how
# many ticket criteria have an answer behind them and how many have nothing —
# because a row nobody could answer is a fact about OUR CHECKING and never a
# failure of his build.
#
# A SOURCE THIS FILE DOES NOT KNOW FALLS TO THE PERSON GROUP. Contracts written
# before this split carry free text ("PRD §2") or no source at all, and the
# conservative place for an unknown row is the group that sets the grade — never
# quietly out of the grade altogether.
GROUP_PERSON, GROUP_DRAWING, GROUP_CONTRACT = "person", "drawing", "contract"
GROUP_ORDER = (GROUP_PERSON, GROUP_DRAWING, GROUP_CONTRACT)
SOURCE_GROUP = {"prd": GROUP_PERSON, "journey": GROUP_PERSON,
                "drawing": GROUP_DRAWING, "plan": GROUP_CONTRACT}
GROUP_QUESTION = {
    GROUP_PERSON: "Can a person do what it promises?",
    GROUP_DRAWING: "Does it look like your drawing?",
    GROUP_CONTRACT: "Is the contract covered?",
}
GROUP_KIND = {GROUP_PERSON: "graded", GROUP_DRAWING: "graded",
              GROUP_CONTRACT: "coverage"}
HEADLINE_GROUP = GROUP_PERSON
GROUP_ASIDE = {
    GROUP_PERSON: "This is the grade at the top of this report.",
    GROUP_DRAWING: ("A fault here is real, but it rarely stops anyone using the "
                    "thing, so it does not set the grade."),
    GROUP_CONTRACT: ("This is not a grade. It is how much of the ticket contract "
                     "I could answer at all — a fact about my checking, not "
                     "about your build."),
}


def group_of(source, kind=None, drawn=False):
    """Which of the captain's three questions a criterion answers.

    APPEARANCE CLAIMS BELONG ON THE LOOK RAIL, NOT THE PERSON RAIL (the captain,
    2026-09-25). Grouping was by `source` alone, and it carried a measured
    defect: a mission whose DRAWING was restyled — card colour, button colour,
    text colour, corner radius — with the BUILD NEVER TOUCHED and every drawn
    part still pairing saw its PERSON rail ("can a person do what it promises?")
    fall 7/7 -> 4/7, while the drawing rail correctly caught the restyle. The
    build did not change, so nothing a person can DO could have got worse; the
    only cause was appearance claims being graded on the functional rail, so
    restyling the drawing made that rail start demanding the new colours.

    An APPEARANCE CLAIM is one BOTH producers declared to be settled by
    comparing the built screen to the DRAWING — and it takes both, because
    neither declaration alone means "appearance":

      * `drawn` (from the criterion's `drawnAt`, declared where the per-part
        requirement is DERIVED from the drawing — the planner on a mockup
        mission, xo-parts.part_criteria) says "this surface IS in the drawing;
        compare the app to the drawing there." But a DRAWN requirement can be
        functional — "the board shows every open task" is drawn yet is a person
        promise that must pull the headline when it breaks.
      * `kind == "looks"` (the eye's produce-time stamp as it judges) says "a
        picture settles this — presence, position, colour, wording." But a
        LOOKS-question can be a person promise with no tie to a drawing — "the
        header shows the app name" is settled by a photo yet is not an
        appearance-vs-drawing check, and is legitimately graded on the person
        rail (the coverage-floor and blind-rail rulings depend on it).

    Only a criterion carrying BOTH — declared drawn AND settled by looking — is
    "does the built appearance match the drawn appearance", and only that is
    lifted off the person rail onto the DRAWING rail. Two rails are untouched: a
    `drawing`-source row is already on the look rail, and the CONTRACT group
    (coverage, never graded) keeps its rows.

    RECORD, DO NOT INFER. Both signals are PRODUCER stamps — `drawnAt` declared
    at derivation, `kind` stamped by the eye beside its verdict
    (prompts/evaluate.md). Nothing here reads the criterion's PROSE (colour
    words, "looks like") to decide it is appearance: that is the infer-vs-record
    class this codebase has lost sessions to. The consumer reads the stamps, and
    nothing else.
    """
    base = SOURCE_GROUP.get(str(source or "").strip().lower(), GROUP_PERSON)
    if base == GROUP_PERSON and drawn \
            and str(kind or "").strip().lower() == "looks":
        return GROUP_DRAWING
    return base


# ─── S225 CHANGE 03: FOUR OUTCOMES, AND ONLY TWO OF THEM TOUCH THE GRADE ─────
#
# The distinction was already in the file and demoted to a sub-field: an
# `untested` row could carry `couldNotCheck` — `unreachable` (I couldn't set it
# up) or `unobservable` (I couldn't see it). Those are not one outcome, they are
# two, and neither of them is a statement about the build. So there are four
# first-class outcomes and the grade may read only the first two:
#
#   worked          | the build did it            GRADES
#   didnt-work      | the build did not do it     GRADES
#   couldnt-see     | I looked and nothing settled it
#   couldnt-set-up  | I could not get to the point of looking
#
# "A failure of ours should never read as a doubt about your build." Until this
# session an `untested` row dragged the grade down twice over — `high-unchecked`
# forced LOW and `medium-open` forced MEDIUM. It no longer does either. What it
# could not set up is LISTED FOR US TO FIX, naming what defeated it.
#
# `status` (met/gap/untested) is left exactly as it was on every row, so a
# reader written before this session degrades instead of crashing.
OUTCOME_WORKED = "worked"
OUTCOME_DIDNT = "didnt-work"
OUTCOME_BLIND = "couldnt-see"
OUTCOME_SETUP = "couldnt-set-up"
VALID_OUTCOME = (OUTCOME_WORKED, OUTCOME_DIDNT, OUTCOME_BLIND, OUTCOME_SETUP)
GRADING_OUTCOMES = (OUTCOME_WORKED, OUTCOME_DIDNT)
OUTCOME_SAID = {OUTCOME_WORKED: "worked", OUTCOME_DIDNT: "didn't work",
                OUTCOME_BLIND: "I couldn't see it",
                OUTCOME_SETUP: "I couldn't set it up"}
# A `couldNotCheck` word that means "I never got to the point of looking".
# `no-change` is xo-journey's: the step ran and the screen was the same, so the
# thing the step was supposed to set up never got set up. `works-needs-action`
# is the captain's 2026-09-24 ruling: a works-question that got only a picture
# was never exercised — a photo shows a Pause button is DRAWN, not that pausing
# pauses — so the check was never set up, and it says so by name.
SETUP_DEFEATED = ("unreachable", "no-change", "works-needs-action")
MY_CHECKING_NOTE = ("These are gaps in my checking, not a fault in your build. "
                    "They are mine to fix — nothing here is counted against you.")


# ═══ THE LANDING RAIL (S241) ═════════════════════════════════════════════════
#
# "A SHOT THAT LANDED ELSEWHERE IS NOT EVIDENCE."
#
# THE MEASURED DEFECT, from the archive. In the Kelmoor runs `shot-01.png`,
# `inv-full.png` and `after-battle-full.png` are THE SAME FILE, byte for byte,
# and all three are the ROSTER screen. The
# report cited two of them as the Inventory evidence and the after-battle
# evidence, each captioned "full page of http://localhost:5174/". Nine identical
# files read as a reviewed feature and every run published `high`.
#
# IDENTICAL BYTES ARE THE SYMPTOM, NOT THE TEST. Nothing here weighs one picture
# against another, and nothing here walks the browser again to go and look a
# second time — going back round until the address matches turns one bad shot
# into a hang.
# The producer's record was never missing: `xo-drive.js` writes the url, the
# title, the visible text and a box for every declared place beside each PNG.
# What was missing was WHERE THE STEP MEANT TO LAND, and a consumer to compare
# the two. S241 stamps the intent (`expectLanding`, xo-journey.py) and writes
# both halves into the readout (`intent` + `landed`, xo-drive.js); this rail is
# the consumer.
#
# RECORD, DO NOT INFER — the rule this file has lost four sessions to. Every
# field below is one producer's recorded field compared to another producer's
# recorded field. The intent is read, in order, from (1) the readout the driver
# wrote, (2) the walk/journey step whose shot this is, (3) the criterion's own
# `drawnAt`, which the planner wrote FROM THE DRAWING before any look happened.
# NOTHING reads the shot's FILENAME to decide where it should have been — that
# guess is exactly how `inv-full` came to be read as the Inventory.
LANDING_NO_RECORD = "no landing record"
SCREEN_IN_DRAWN_AT = re.compile(r"#(screen[-_][A-Za-z0-9_-]+)")


def landing_readout(shotsroot, name):
    """The readout `.json` beside a recorded shot, and where it was found.

    The look's shots live in one directory per look (`shots/look-3/…`), and the
    eye cites a shot by bare name. The newest look is searched first, because
    that is the look the citation came from. A path to nothing is worse than no
    path, so this returns a doc only when a file really parsed."""
    nm = str(name or "").strip()
    if not nm or not shotsroot or not os.path.isdir(shotsroot):
        return "", None
    stem = os.path.splitext(nm)[0]
    cands = [nm + ".json", stem + ".json"] if not nm.endswith(".json") else [nm]
    # NEWEST LOOK FIRST, COUNTING LIKE A HUMAN. A plain reverse sort puts
    # `look-9` ahead of `look-10`, which would hand back the older picture on
    # the tenth look of a mission. The digits are compared as numbers.
    def newest_first(d):
        return tuple(int(t) if t.isdigit() else t
                     for t in re.split(r"(\d+)", d))
    dirs = [os.path.join(shotsroot, d) for d in
            sorted((d for d in os.listdir(shotsroot)
                    if os.path.isdir(os.path.join(shotsroot, d))),
                   key=newest_first, reverse=True)]
    for d in dirs + [shotsroot]:
        for c in cands:
            pth = os.path.join(d, c)
            if not os.path.isfile(pth):
                continue
            try:
                with open(pth, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except Exception:
                continue
            if isinstance(doc, dict):
                return pth, doc
    return "", None


def landing_records_exist(shotsroot):
    """Does this look record landings AT ALL?

    MEASURED, AND THE REASON THIS FUNCTION EXISTS. "A cited shot with no readout
    is not evidence" is right for ONE shot in a look that records them — the
    picture cannot be placed and the row is a hole. Applied to a whole run that
    records NONE of them it is something else entirely: every row in the look
    goes untested at once, which is not a measurement but an outage, and it
    would silently rewrite the grade of every look taken before S241 and of
    every run driven by a stub or a replacement `$LCARS_XO_DRIVER`. Turning the
    rail on against the archive's own stub fixtures did exactly that: 13 rows
    that had been settled on real pictures read "no landing record".

    So the rail needs one readout to prove the run was recording, and says so in
    a note when there is not one. Bounded: the look's own directory and one
    level of look folders, first hit wins."""
    if not shotsroot or not os.path.isdir(shotsroot):
        return False
    dirs = [shotsroot]
    try:
        dirs += [os.path.join(shotsroot, d) for d in sorted(os.listdir(shotsroot))
                 if os.path.isdir(os.path.join(shotsroot, d))]
    except OSError:
        return False
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for nm in names:
            if not nm.endswith(".json"):
                continue
            try:
                with open(os.path.join(d, nm), encoding="utf-8") as fh:
                    doc = json.load(fh)
            except Exception:
                continue
            # BOTH HALVES, OR IT PROVES NOTHING. A PER-SHOT readout names its
            # own shot AND records the page it was taken on — that is what
            # xo-drive.js writes beside every PNG. Measured: a stub driver in
            # the suite writes `{"shot":"shot-01"}` with no page at all, plus a
            # look-level `readout.json` with a page and no shot; counting either
            # of those as proof turned the rail on over a run that records
            # nothing and rewrote a settled ledger (lcars-xo.test.sh B23b).
            if (isinstance(doc, dict) and str(doc.get("shot") or "").strip()
                    and (isinstance(doc.get("landed"), dict)
                         or isinstance(doc.get("page"), dict))):
                return True
    return False


def landed_of(doc):
    """Where a shot was taken, out of its own readout.

    `landed` when the driver wrote one (S241 on). For a run from before that,
    the SAME THREE FACTS are already in the readout's `page` block and are read
    from there — that is reading the record, not inventing one. A readout that
    carries neither is no landing record at all."""
    if not isinstance(doc, dict):
        return None
    got = doc.get("landed")
    if isinstance(got, dict) and (got.get("url") or got.get("title") or got.get("screen")):
        return got
    page = doc.get("page")
    if not isinstance(page, dict):
        return None
    out = {"url": str(page.get("url") or ""), "title": str(page.get("title") or ""),
           "textSample": " ".join(str(page.get("textExcerpt") or "").split())[:400],
           "from": "the readout's own page block"}
    places = page.get("places") if isinstance(page.get("places"), dict) else {}
    on = [k for k, v in places.items()
          if str(k).lower().startswith(("screen-", "screen_"))
          and isinstance(v, dict) and v.get("laidOut")]
    # ONE laid-out screen is the page telling us which screen it is showing.
    # None, or several, is not an answer — and a guess here would refuse good
    # evidence, which is worse than refusing none.
    if len(on) == 1:
        out["screen"] = on[0]
    if not out["url"] and not out["title"] and not out.get("screen"):
        return None
    return out


def drawn_at_landing(row):
    """The landing a CRITERION declares, out of the `drawnAt` the planner wrote
    from the drawing before the look. "…#button-open-inventory on #screen-roster
    leading to #screen-inventory" lands on the LAST screen it names — where the
    sentence ends is where the person ends up."""
    txt = str((row or {}).get("drawnAt") or "")
    ids = SCREEN_IN_DRAWN_AT.findall(txt)
    if not ids:
        return None
    return {"screen": ids[-1], "textMustInclude": [],
            "from": "the criterion's own drawnAt, written from the drawing before the "
                    "look: %s" % " ".join(txt.split())[:140]}


def landing_intent(doc, shot, by_shot, row, cid=""):
    """What THIS ROW's shot was meant to show, from the record that says.

    Three recorded sources, never a filename: the readout the driver wrote, the
    walk/journey step whose shot this is, and the criterion's own `drawnAt`.

    WHOSE INTENT GOVERNS WHOSE ROW (measured on the archive, S241). A step's
    intent is the STEP's, and it governs only the step's own row (`journey-j3`
    is step `j3`) — not every criterion that happened to cite the same picture.
    Replaying the six archived looks the other way round, a single mis-derived
    step (the drawing stacks the inventory after the battle, so the journey
    decided "Attack" leads to the inventory) refused `prd-6` and `t-004-ac3` as
    well — two rows whose own declared place, `#screen-battle`, is exactly where
    their picture was taken. Refusing good evidence because a DIFFERENT row's
    expectation was wrong is the same crime as crediting a shot that landed
    elsewhere, in the other direction. So a criterion is judged against the place
    IT declared, and nothing else."""
    if isinstance(doc, dict) and isinstance(doc.get("intent"), dict):
        it = doc["intent"]
        if not it.get("unstated"):
            return it
    st = by_shot.get(str(shot or "").strip())
    if isinstance(st, dict) and str(cid or "") == "journey-%s" % str(st.get("key") or ""):
        it = st.get("expectLanding")
        if isinstance(it, dict) and not it.get("unstated"):
            return dict(it, step=st.get("key") or "")
    return drawn_at_landing(row)


def landing_verdict(intent, landed):
    """(reached, reason). `reached` is False only when a RECORDED intent and a
    RECORDED landing actually disagree; an intent with nothing to check, or a
    landing the page never declared, settles nothing either way and the row is
    left exactly as the eye rated it."""
    if not isinstance(intent, dict) or not isinstance(landed, dict):
        return True, ""
    where = (landed.get("screen") or landed.get("title")
             or landed.get("url") or "somewhere the record does not name")
    said = str(intent.get("from") or "").strip()
    pat = str(intent.get("urlPattern") or "").strip()
    if pat:
        try:
            if not re.search(pat, str(landed.get("url") or "")):
                return False, ("landed on %s, expected a page whose address matches %s — %s"
                               % (str(landed.get("url") or where), pat, said))
        except re.error:
            pass
    want = str(intent.get("screen") or "").strip()
    got = str(landed.get("screen") or "").strip()
    if want and got and want != got:
        return False, ("landed on %s, expected %s — %s" % (got, want, said))
    # THE WORDS, when the screens did not settle it. Most products do not label
    # their screens with an id a page can expose, so `screen` is often known on
    # one side only — and skipping the text check whenever an intent NAMED a
    # screen would leave those products unchecked entirely. Any ONE of the
    # drawn headings is enough, because a heading may be restyled; all of them
    # missing from a page that showed words at all is the signal.
    musts = [str(t) for t in (intent.get("textMustInclude") or []) if str(t).strip()]
    if musts and not (want and got):
        hay = (" ".join([str(landed.get("textSample") or ""),
                         str(landed.get("title") or "")])).lower()
        if hay.strip() and not any(m.lower() in hay for m in musts):
            return False, ("landed on %s, which shows none of %s — %s"
                           % (where, ", ".join('"%s"' % m for m in musts[:3]), said))
    return True, ""


def landing_by_shot(walk, journey):
    """shot name -> the step that took it, with its recorded intent.

    The WALK says which step took which shot (`shot`, `shotBefore`); the JOURNEY
    says what that step expected. Joined on the step's own `key` — a recorded
    id, never a filename."""
    by_key = {}
    for st in ((journey or {}).get("steps") or []):
        if isinstance(st, dict) and st.get("key"):
            by_key[str(st["key"])] = st
    out = {}
    for st in ((walk or {}).get("steps") or []):
        if not isinstance(st, dict):
            continue
        key = str(st.get("key") or "")
        want = st.get("expectLanding")
        if not isinstance(want, dict):
            want = (by_key.get(key) or {}).get("expectLanding")
        if not isinstance(want, dict):
            continue
        for f in ("shot", "shotBefore"):
            nm = str(st.get(f) or "").strip()
            if nm:
                out.setdefault(nm, {"key": key, "expectLanding": want})
    return out


def outcome_of(entry):
    """The four-way outcome of a finished ledger row. Reads only `status` and
    the recorded `couldNotCheck` word — never the prose of a note."""
    st = entry.get("status")
    if st == "met":
        return OUTCOME_WORKED
    if st == "gap":
        return OUTCOME_DIDNT
    if str(entry.get("couldNotCheck") or "") in SETUP_DEFEATED:
        return OUTCOME_SETUP
    return OUTCOME_BLIND


# ─── THE KIND OF QUESTION, READ FROM THE STAMP (captain's ruling, 2026-09-24) ─
#
# A LOOKS-question asks about appearance/presence — "the title is there", "the
# badge is red". A picture genuinely SETTLES it; pressing adds nothing. A
# WORKS-question asks about behaviour — "Save saves", "pausing pauses". Only an
# ACTION settles it; a picture of a button proves the button is DRAWN, not that
# it DOES anything. The measured defect: a build got credit for "pausing works"
# from a photo showing a Pause button exists.
#
# RECORD, DO NOT INFER — and this is the whole point of the session that added
# this. The kind is a PRODUCE-TIME STAMP on the criterion, written when the
# criterion is born: the planner's `kind: "looks"|"works"`, carried through
# xo-criteria.py. A criterion the planner marked `notVisual` makes no visual
# claim at all, so it is a works-question by the planner's OWN stamp — read
# here, not guessed. NOTHING here reads the criterion's PROSE to classify it:
# LCARS has lost three sessions to text heuristics (a source parser, a regex
# classifier, a heading guard), each beaten because the captain writes specs
# ABOUT LCARS in LCARS's own vocabulary. The consumer reads a field a producer
# stamped, and nothing else.
def question_kind(row):
    """(kind, from) for a contract row — ("looks"|"works"|"", provenance).

    Reads only stamped fields: the explicit `kind`, else the planner's
    `notVisual` (no visual claim ⇒ a works-question). An unstamped criterion is
    UNKNOWN ("", "") — never guessed from its text, and never downgraded on a
    guess, so a legitimate looks-question backed by a picture is never harmed.
    """
    if not isinstance(row, dict):
        return "", ""
    k = str(row.get("kind") or "").strip().lower()
    if k in ("looks", "works"):
        return k, "stamp"
    if row.get("notVisual"):
        return "works", "notVisual"
    return "", ""


# ─── WHAT COUNTS AS HAVING BEEN EXERCISED (S240 fix round 1, D2) ─────────────
# `settled_by_picture_alone` predates S239, which made `transcript` a real
# evidence word: the reach steps run a command and keep its exact output in a
# `.txt` beside the shots. The predicate was written when a works-question could
# only be exercised by a browser ACTION or by the project's own tests, so a row
# proven by a CLI transcript — the whole point of the reach steps — fell through
# to "a picture alone" and the works-kind downgrade below rewrote it.
#
# WHAT IT PROTECTS IS A PASS, NOT A FAULT — the round-1 wording here had this
# backwards and a later reader would have been misled (corrected S240 fix round
# 2). The downgrade below is gated on `e["status"] == "met"`, so the ONLY row it
# can ever rewrite is one the look called MET. A `gap` row was never downgraded
# by it and never could be: a transcript-proven FAULT reaches the report
# untouched by this predicate.
#
# MEASURED consequence of the narrow predicate: a high-impact works-question the
# look PASSED on a `cli` run, with its transcript on disk and no `action` string,
# was rewritten to `untested` / `works-needs-action` / `evidence: none` — a
# checked criterion turned into an unchecked one, which is what then moved the
# headline off the evidence that existed. The widening restores the pass; it
# grants nothing to a gap.
#
# THESE TWO TABLES ARE THE WIDENING, AND THEY ARE WHY IT IS NOT A REMOVAL. The
# check exists to stop a row asserting a judgement with nothing behind it, so an
# evidence WORD is not enough on its own: the row must ALSO name the instrument
# it was taken with (`checkedBy`) AND where the output was left. A row that says
# `transcript` and nothing else is still demoted.
EXERCISED_EVIDENCE = ("transcript", "measurement", "tests")
EXERCISED_CHECKED_BY = ("cli", "workflow", "test")
# The fields a producer uses to say WHERE the output it took is. Any one of them
# is a location a fix worker could open; none of them is prose.
EVIDENCE_LOCATION_FIELDS = ("evidencePath", "transcriptPath", "transcript",
                            "shot", "where", "testQuote")


def recorded_location(entry):
    """True when the row names WHERE its instrument left what it saw."""
    for k in EVIDENCE_LOCATION_FIELDS:
        if str(entry.get(k) or "").strip():
            return True
    for sh in (entry.get("shots") or []):
        if str(sh or "").strip():
            return True
    return False


def settled_by_picture_alone(entry):
    """True when the ONLY thing behind a passing row is a screenshot — no test
    line quoted, no action recorded, and no other instrument that was actually
    RUN. The same predicate the settledBy record uses (a picture is the fallback
    once tests and action are ruled out), read from producer-stamped fields, so
    the two can never disagree."""
    ev = str(entry.get("evidence") or "").strip().lower()
    if ev == "tests" and str(entry.get("testQuote") or "").strip():
        return False
    if str(entry.get("action") or "").strip():
        return False
    # AN INSTRUMENT THAT WAS RUN, NAMED, AND LEFT ITS OUTPUT SOMEWHERE. All
    # three, or the row falls through to the demotion exactly as before.
    if ev in EXERCISED_EVIDENCE \
            and str(entry.get("checkedBy") or "").strip().lower() in EXERCISED_CHECKED_BY \
            and recorded_location(entry):
        return False
    return True


def take_impact(entry, row):
    """Copy the look's IMPACT onto a ledger entry — or record HIGH, and that it
    was assumed, when the look gave none it could name."""
    imp = str((row or {}).get("impact") or "").strip().lower()
    if imp in VALID_IMPACT:
        entry["impact"] = imp
        why = " ".join(str((row or {}).get("impactWhy") or "").split())
        if why:
            entry["impactWhy"] = why
    else:
        entry["impact"] = "high"
        entry["impactAssumed"] = True


def derive_grade(ledger):
    """His table, over ONE GRADED GROUP of the finished ledger. Pure: reads
    status + impact only.

    S225 CHANGE 03 — ONLY `worked` AND `didn't work` MOVE THIS. Two rules used
    to let a blind row decide the captain's grade: `high-unchecked` forced LOW
    the moment ANY high row was unchecked, and `medium-open` forced MEDIUM on a
    medium nobody could see. Both were a failure of OURS reading as a doubt
    about HIS build, and both are gone: a blind row is now recorded, listed and
    said out loud beside the grade, and counts for nothing inside it.

    WHAT SURVIVES, AND WHY IT IS NOT THE SAME RULE. `nothing-checked` (not one
    row in this group was ever settled) and `high-unchecked` (there ARE rows
    that are the point of the mission and NOT ONE of them was settled) both say
    "nothing here is vouched for" — which is the opposite of a doubt about the
    build, and the exact hole S220's benchmark fell through when a silent model
    scored 5/5. One unchecked high among checked highs no longer moves a thing;
    a group where the point of the mission was never looked at still refuses to
    certify itself.
    """
    by = {"high": [], "medium": [], "low": []}
    for e in ledger:
        by[e.get("impact") if e.get("impact") in by else "high"].append(e)

    def pick(rows, st):
        return [e for e in rows if e["status"] == st]

    g = {"high": by["high"],
         "highGap": pick(by["high"], "gap"), "highBlind": pick(by["high"], "untested"),
         "mediumGap": pick(by["medium"], "gap"),
         "mediumBlind": pick(by["medium"], "untested"),
         "lowOpen": [e for e in by["low"] if e["status"] != "met"]}
    checked = sum(1 for e in ledger if e["status"] in ("met", "gap"))
    highs_checked = sum(1 for e in by["high"] if e["status"] in ("met", "gap"))
    # The 80% coverage floor, as a row COUNT off the recorded total — a graded
    # group reads HIGH only if it checked at least this many of its own rows.
    coverage_needed = (HIGH_COVERAGE_PCT * len(ledger) + 99) // 100
    if not ledger:
        g.update(score="low", rule="nothing-listed")
    elif g["highGap"]:
        g.update(score="low", rule="high-broken")
    elif not checked:
        # Said as what it is — nothing at all — rather than as "the core".
        g.update(score="low", rule="nothing-checked")
    elif by["high"] and not highs_checked:
        g.update(score="low", rule="high-unchecked")
    elif g["mediumGap"]:
        g.update(score="medium", rule="medium-open")
    elif 2 * checked <= len(ledger):
        # THE HALF-CHECKED FLOOR (captain's ruling, 2026-09-22). Measured on a
        # live mission: a group of 7 with one row worked and six that could not
        # be SET UP read HIGH — it graded on the single row that got checked,
        # exactly the "silent model scores 5/5" hole. `high-unchecked` could not
        # catch it because ONE high row was checked. So a graded group may not
        # read HIGH unless MORE THAN HALF of its rows were actually checked
        # (worked or didn't-work; the two "couldn't" outcomes are not checks).
        # Below the floor it is UNKNOWN, said as what it is — too little checked
        # to grade — NEVER a doubt about the build: no row here didn't work, the
        # core stays `unverified` below, and the rows we could not check are
        # listed as OURS to fix, never counted against him.
        g.update(score="low", rule="too-little-checked")
    elif checked < coverage_needed:
        # THE 80% COVERAGE FLOOR (captain's ruling, 2026-09-24). Above the
        # half-checked floor but below 80% actually checked, with nothing
        # failed: the rail worked everywhere it was looked at, but too much of
        # it went unlooked-at to certify. It is HELD BACK one notch to MEDIUM —
        # not LOW: no row here didn't work, so it is not a doubt about the
        # build, it is a doubt about how much of the build we reached. The core
        # reads `unverified` below (there is an unchecked high), and the words
        # name the floor and the count. `didntWork` fired above and always wins;
        # coverage can only lower a grade, never raise one.
        g.update(score="medium", rule="held-back-coverage")
    else:
        g.update(score="high", rule="all-worked")
    # THE CORE — the point of the mission, as its own fact beside the grade.
    # No high row at all is not a core anybody met, so it is left unsaid.
    if g["highGap"]:
        g["core"] = "broken"
    elif g["highBlind"] or not ledger or not checked:
        g["core"] = "unverified"
    elif by["high"]:
        g["core"] = "met"
    else:
        g["core"] = ""
    # Counts the floor and its reasons read (additive; older readers ignore).
    g["checked"], g["total"] = checked, len(ledger)
    # THE THRESHOLD, MADE VISIBLE. The 80% floor that was applied and the
    # coverage this group actually reached, both as recorded numbers a person
    # can read, so the rule that held a grade back is on the page, not inferred.
    g["coverageFloorPct"] = HIGH_COVERAGE_PCT
    g["coveragePct"] = int(round(100 * checked / len(ledger))) if ledger else 0
    return g


def derive_recommendation(ledger, grade, finding_by_id=None, name_of=None):
    """THE ACTION, derived from the ledger + the grade + the coverage floor.

    The weekend's merge policy, made the reviewer's own and written down:

      * no gap, and the coverage floor met                     -> merge
      * gaps only at medium/low impact, or the floor missed for
        INFRASTRUCTURE reasons                                 -> merge-with-follow-ups
      * any high-impact gap, or a high-impact criterion that
        could not be reached for a PRODUCT reason              -> send-back

    Pure: reads `status`, `impact` and the recorded `cause` off the ledger, and
    `coveragePct`/`coverageFloorPct` off the grade. It NEVER reads the grade WORD
    — a `low` that is low only because a runner would not start is not a send-back,
    and that is the whole reason the two live apart.

    Returns {recommendation, because[], blockers[], followUps[]}. `blockers` are
    the rows that forced a send-back, each carrying the recorded evidence kind so
    a surface never has to read it back out of prose; `filedAs` is stamped onto
    them later, by whoever files them.
    """
    finding_by_id = finding_by_id or {}
    name_of = name_of or (lambda cid: cid)
    high_gaps, other_gaps, product_blind, infra_blind = [], [], [], []
    for e in ledger:
        st = str(e.get("status") or "")
        imp = e.get("impact") if e.get("impact") in VALID_IMPACT else "high"
        if st == "gap":
            (high_gaps if imp == "high" else other_gaps).append(e)
        elif st == "untested" and imp == "high":
            # AN UNRECORDED CAUSE IS INFRASTRUCTURE. See CAUSE_CLASS.
            if str(e.get("cause") or "") == "product":
                product_blind.append(e)
            else:
                infra_blind.append(e)

    floor = int(grade.get("coverageFloorPct") or HIGH_COVERAGE_PCT)
    pct = int(grade.get("coveragePct") or 0)
    floor_met = pct >= floor

    def ev_of(e):
        f = finding_by_id.get(e.get("id")) or {}
        return str(f.get("evidence") or e.get("evidence") or "none")

    def blocker(e, why):
        b = {"criterion": e.get("id"), "evidence": ev_of(e),
             "impact": "high", "why": why}
        if e.get("checkedBy"):
            b["checkedBy"] = e["checkedBy"]
        return b

    because, blockers, follow_ups = [], [], []
    for e in high_gaps:
        why = ("%s is the point of the mission and it did not work"
               % name_of(e.get("id")))
        because.append(why + " (%s)" % e.get("id"))
        blockers.append(blocker(e, why))
    for e in product_blind:
        why = ("%s could not be reached at all, and the reason is the build: %s"
               % (name_of(e.get("id")),
                  unstop(" ".join(str(e.get("note") or "").split()))
                  or "no way in was recorded"))
        because.append(why + " (%s)" % e.get("id"))
        blockers.append(blocker(e, why))
    for e in other_gaps:
        follow_ups.append("%s did not work, at %s impact (%s)"
                          % (name_of(e.get("id")), e.get("impact") or "medium",
                             e.get("id")))
    for e in infra_blind:
        follow_ups.append("%s could not be checked here, and the reason is our rig, "
                          "not the build: %s (%s)"
                          % (name_of(e.get("id")),
                             unstop(" ".join(str(e.get("note") or "").split()))
                             or "no cause was recorded, so it is read as ours",
                             e.get("id")))
    if not floor_met:
        follow_ups.append("only %d%% of this rail was actually checked, against a "
                          "floor of %d%% — close the gap in what we can reach"
                          % (pct, floor))

    if blockers:
        rec = "send-back"
    elif other_gaps or infra_blind or not floor_met:
        rec = "merge-with-follow-ups"
    else:
        rec = "merge"

    if rec == "merge":
        because = ["nothing on your list is short of the mark, and %d%% of this rail "
                   "was actually checked against a floor of %d%%" % (pct, floor)]
    elif rec == "merge-with-follow-ups" and not because:
        because = [follow_ups[0]] if follow_ups else [
            "nothing here blocks a merge, but something is left over"]
    return {"recommendation": rec, "because": because,
            "blockers": blockers, "followUps": follow_ups}


def _plain(text):
    return " ".join(re.sub(r"[^\w\s]", " ", str(text or "").lower()).split())


# ─── S216 fix round 1: THE WORDS THE CAPTAIN READS ABOUT EACH REQUIREMENT ────
#
# A SHORT PLAIN NAME (D4). The paragraph used to embed the contract's text as
# written — backticked signatures, file paths, and PRD bullets the parser had
# cut at a line end ("returns a Pixi colour number for the (prd-3)"). A name is
# derived here, deterministically, from the same text: a parenthetical that is
# only code goes, a code span becomes the name of the thing it names (a
# function, a file), and a long one is cut at a word — never on a word that
# leads nowhere — with one "…".
DANGLING = set("a an the of for to with and or but in on at by from as is are be "
               "no not into onto than that which who its their your this then when while "
               "if so was were has have".split())
STRIP_TAIL = " :;,.—-*=+"


# MARKDOWN IS NOT A NAME (S216 fix round 2, W1). A PRD's `**low demo value**`
# leaked into the tab as raw `**`. Emphasis marks go; an identifier's own
# underscores (DEV_HP_BAR_WIDTH) are left alone.
def strip_markdown(t):
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = re.sub(r"__(.+?)__", r"\1", t)
    t = re.sub(r"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])", r"\1", t)
    t = re.sub(r"(?<![\w_])_(?!\s)([^_]+?)(?<!\s)_(?![\w_])", r"\1", t)
    return t.replace("**", "")


# ARGUMENTS THAT ARE VALUES STAY (W1). `healthBarColor(0)` and
# `healthBarColor(0.35)` are two different checks; naming both
# "healthBarColor" made two rows read identically. Arguments with no letters
# in them are the requirement and are kept; a signature's typed parameters
# (`current: number`) are not, and go.
VALUE_ARGS = re.compile(r"^[^A-Za-z]*$")
SUBORDINATE = set("when if after before while unless once until whenever".split())


def short_name(text, limit=60):
    t = strip_markdown(re.sub(r"\s*\(\s*`[^`]*`\s*\)", "", str(text or "")))

    def code(m):
        c = m.group(1).strip()
        fn = re.match(r"([A-Za-z_$][\w$.]*)\s*\(([^()]*)\)", c)
        if fn and VALUE_ARGS.match(fn.group(2)) and len(c) <= 40:
            return c
        fn = re.match(r"([A-Za-z_$][\w$.]*)\s*\(", c)
        if fn:
            return fn.group(1)
        if "/" in c:
            return c.rstrip("/").rsplit("/", 1)[-1]
        return c
    t = re.sub(r"`([^`]*)`", code, t).replace("`", "")
    # A bare file path is named by its file.
    t = re.sub(r"(?<![\w/])[\w.-]+(?:/[\w.-]+)+\.\w+", lambda m: m.group(0).rsplit("/", 1)[-1], t)
    t = " ".join(t.split()).rstrip(STRIP_TAIL)
    if len(t) > limit:
        # Too long: first drop worded call arguments and worded asides —
        # "(current, max)", "(not app.renderer.resize directly)" — but keep a
        # bare value like "(8,8)" or "(0.35)", which is the requirement.
        t = re.sub(r"(?<=\w)\([^()]*[A-Za-z][^()]*\)", "", t)
        t = re.sub(r"\s+\([^()]*[A-Za-z][^()]*\)", "", t)
        t = " ".join(t.split()).rstrip(STRIP_TAIL)
    if len(t) > limit:
        # NEVER MID-PHRASE (W1): prefer the first whole clause — up to a colon,
        # a semicolon, a dash, then a comma, then an "and" — when that clause
        # is a name on its own. It carries one "…": there was more.
        # A clause that is only a condition ("When devMode is false") or a
        # list's first item ("DEV_HP_BAR_WIDTH") is not a name, so a clause
        # needs three words and must not open on a subordinating word. A
        # spaced hyphen is arithmetic here ("width - margin"), never a dash.
        for sep in (r":\s", r";\s", r"\s[—–]\s", r",\s", r"\sand\s"):
            head = re.split(sep, t, maxsplit=1)[0].rstrip(STRIP_TAIL)
            words = head.split(" ")
            if head != t and 15 <= len(head) <= limit + 15 and len(words) >= 3 \
                    and words[-1].lower() not in DANGLING \
                    and words[0].lower() not in SUBORDINATE:
                return head + "…"
    cut = False
    if len(t) > limit:
        head = t[:limit + 1]
        sp = head.rfind(" ")
        t = head[:sp] if sp > limit // 2 else t[:limit]
        cut = True
    words = t.split(" ")
    while len(words) > 1 and words[-1].lower().strip(STRIP_TAIL) in DANGLING:
        words.pop()
        cut = True
    t = " ".join(words).rstrip(STRIP_TAIL)
    if cut and t.count("(") > t.count(")"):
        # Never stop inside a bracket.
        t = t[:t.rfind("(")].rstrip(STRIP_TAIL)
    return t + ("…" if cut else "")


# WHAT A HIGH RESTED ON (D7). "I have a picture of each one" was said of a
# ledger two thirds of which your tests settled. The rows carry their evidence
# kind (recorded, S211), so the sentence counts it — no reading of prose.
def evidence_said(rows, has_drawing=False):
    pics = sum(1 for e in rows if e.get("evidence") in ("picture", "measurement"))
    tests = sum(1 for e in rows if e.get("evidence") == "tests")
    # S239 fix round 1 (D1): a row settled by RUNNING the thing is backed by a
    # transcript, not a photograph. Counted apart and said apart — folded in, it
    # made this sentence claim the captain's reviewer had SEEN ON SCREEN what it
    # had read in a terminal.
    runs = sum(1 for e in rows if e.get("evidence") == "transcript")
    if runs:
        bits = []
        if pics:
            bits.append(("I saw %d on screen" if has_drawing
                         else "I have a picture of %d") % pics)
        bits.append("I ran %d and read the transcript" % runs)
        if tests:
            bits.append("your own tests show %d" % tests)
        if len(bits) == 1:
            return "I ran each one and read the transcript"
        return ", ".join(bits[:-1]) + " and " + bits[-1]
    # W2: with a real drawing on the mission, "picture" reads as the drawing;
    # the screenshots are what was SEEN on screen.
    if pics and tests:
        return (("I saw %d on screen and your own tests show the other %d"
                 if has_drawing else
                 "I have a picture of %d and your own tests show the other %d")
                % (pics, tests))
    if tests:
        return "your own tests show each one"
    return "I saw each one on screen" if has_drawing else "I have a picture of each one"


# THE SMALLER ITEMS, SAID APART (D1/D2). "7 small things did not" was said of
# seven items nobody could check. Didn't-work and couldn't-check are two facts.
def smaller_items(lg, lb, names):
    bits = []
    for rows, what in ((lg, "didn't work"), (lb, "I could not check")):
        if not rows:
            continue
        n = len(rows)
        s = "%d smaller item%s %s" % (n, "" if n == 1 else "s", what)
        if names:
            s += (", and %s the grade: %s" % ("it doesn't change" if n == 1 else
                                              "they don't change", names(rows)))
        bits.append(s)
    return bits


# NEAR-DUPLICATE REQUIREMENTS, RATED APART (D5). The same thing stated in the
# PRD and again in a ticket got different impacts inside one look. The harness
# FLAGS such a pair — beside the grade, never moving it. Deliberately simple:
# the same words once punctuation and case are gone, or nearly all the same
# words (a token overlap), and nothing cleverer.
NEAR_DUP_OVERLAP = 0.8


def near_duplicates(ledger, texts):
    def toks(t):
        return _plain(str(t or "").replace("`", " ")).split()
    rows = [(e, toks(texts.get(e["id"]) or e.get("text"))) for e in ledger]
    pairs = []
    for i, (a, ta) in enumerate(rows):
        for b, tb in rows[i + 1:]:
            if a.get("impact") == b.get("impact") or not ta or not tb:
                continue
            sa, sb = set(ta), set(tb)
            same = ta == tb or (min(len(sa), len(sb)) >= 4 and
                                len(sa & sb) / float(len(sa | sb)) >= NEAR_DUP_OVERLAP)
            if same:
                pairs.append({"ids": [a["id"], b["id"]],
                              "impacts": [a["impact"], b["impact"]]})
    return pairs


ENGINE_WORD = {"copilot": "Copilot", "claude": "Claude"}


def apply_recorded_impacts(ledger, path, texts=None):
    """REUSE the importance the first look set (D5). → (note, kept, new ids).

    `kept` is every (id, recorded, this look's) where the look re-guessed an id
    already on the record; the record wins and the shell journals each one.
    The record keeps the requirement's text too: if the PRD was re-aligned and
    an id now names a DIFFERENT requirement, it is rated afresh, not reused."""
    texts = texts or {}
    if not path:
        return "", [], []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        rec = doc.get("impacts") if isinstance(doc, dict) else None
    except Exception:
        rec = None
    rec = rec if isinstance(rec, dict) else {}
    engine = os.environ.get("LCARS_XO_ENGINE", "").strip().lower()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    kept, new, used = [], [], []
    for e in ledger:
        r = rec.get(e["id"])
        now_text = texts.get(e["id"]) or e.get("text") or ""
        if isinstance(r, dict) and r.get("text") and \
                _plain(r["text"]) != _plain(now_text):
            r = None
        if isinstance(r, dict) and r.get("impact") in VALID_IMPACT:
            given = "" if e.get("impactAssumed") else e.get("impact", "")
            if given and given != r["impact"]:
                kept.append((e["id"], r["impact"], given))
            e["impact"] = r["impact"]
            e.pop("impactAssumed", None)
            if r.get("impactWhy"):
                e["impactWhy"] = r["impactWhy"]
            else:
                e.pop("impactWhy", None)
            e["_impactRecorded"] = True
            used.append(r)
        elif not e.get("impactAssumed"):
            # An impact nobody gave is not recorded: the next look may give one.
            rec[e["id"]] = {"impact": e["impact"], "impactWhy": e.get("impactWhy", ""),
                            "at": now, "engine": engine, "text": now_text}
            new.append(e["id"])
    if new:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"impacts": rec}, fh, indent=2)
                fh.write("\n")
            os.replace(tmp, path)
        except Exception:
            pass

    def when(r):
        at = str(r.get("at") or "")[:10]
        eng = ENGINE_WORD.get(str(r.get("engine") or ""), str(r.get("engine") or ""))
        return ", ".join(x for x in (at, eng) if x)
    if used:
        first = min(used, key=lambda r: str(r.get("at") or ""))
        note = ("Importance was set on the first look (%s) and kept for this one, "
                "so a new look cannot move the grade by re-guessing it." % when(first))
        if new:
            note += (" %d item%s new since then %s rated on this look."
                     % (len(new), "" if len(new) == 1 else "s",
                        "was" if len(new) == 1 else "were"))
    elif new:
        note = ("Importance was set on this look (%s); later looks keep it."
                % when(rec[new[0]]))
    else:
        note = ""
    return note, kept, new


def because_tail(why):
    """ONE "because" (S216 fix round 2, W3). A recorded reason is usually
    "The tuning constants are medium because they are …"; set after "Impact
    medium because" that read "because The tuning constants are medium
    because …". Keep what follows its own "because", and continue in lower
    case unless the first word is a name (DEV_HP_BAR_WIDTH, API, F3)."""
    t = unstop(why)
    m = re.search(r"\bbecause\s+", t, re.IGNORECASE)
    if m and t[m.end():].strip():
        t = t[m.end():]
    w = t.split(" ", 1)[0]
    if w[:1].isupper() and w[1:].islower() and w.isalpha():
        t = t[:1].lower() + t[1:]
    return t


def finish_reason(e):
    """Every row carries ONE reason sentence (S216).

    The look writes it: "Impact <h/m/l> because <why>. I tried <action>; I saw
    <observation> (evidence: <shot/step>). Outcome: <…>." The harness checks it
    is THERE and is not the requirement read back — it does not grade the prose.
    When the look gave none, the fallback says so rather than invent one. When
    the harness overruled the look's outcome (no picture, no drawing, never
    rated), the look's sentence would now claim an outcome the row does not
    have, so the harness writes the row's reason itself, from its own note."""
    said = " ".join(str(e.pop("_reason", "") or "").split())
    rated = e.pop("_ratedStatus", "")
    recorded = e.pop("_impactRecorded", False)
    tag = " (set on the first look)" if recorded else ""
    word = OUTCOME_WORD[e["status"]]
    if e.get("impactAssumed"):
        impact = "Impact high — none was given, so I counted it as the point of the mission"
    elif e.get("impactWhy"):
        impact = "Impact %s%s because %s" % (e["impact"], tag, because_tail(e["impactWhy"]))
    else:
        impact = "Impact %s%s" % (e["impact"], tag)
    # S223 fix round 1 (D2): when the HARNESS writes the reason, the reason is
    # not the look's own words and must never be shown as "what I did". The
    # row says so on the record rather than leaving a reader to guess.
    if rated != e["status"]:
        told = unstop(e.get("note") or "") or "I could not check this"
        e["reason"] = "%s. %s. Outcome: %s." % (impact, told[:1].upper() + told[1:], word)
        e["reasonByHarness"] = True
        return
    if not said or _plain(said) == _plain(e.get("text")):
        e["reason"] = ("No reason was given for this one — all I have is the outcome: "
                       "%s. %s." % (word, impact))
        e["reasonByHarness"] = True
        return
    if recorded:
        # The look's own "Impact <x> because …" sentence gives way to the one
        # on the record; what it tried and saw is kept as written.
        # The look's sentence ends at a full stop that ends a SENTENCE — not
        # the dot inside `renderer.resize` (W3: that left "resize is medium
        # because …" behind, a second "because").
        said = "%s. %s" % (impact, re.sub(r"^Impact\s+\w+\b.*?\.(?:\s+(?=[A-Z])|\s*$)", "", said, count=1))
    e["reason"] = said


def load_json_or_none(path):
    if not path:
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None


# --- WHAT NOBODY ASKED ABOUT (S224 item 2) ---------------------------------
# Number One reviews what the captain wrote down. Measured on the S222
# capstone: it filed every fault an acceptance criterion named, and missed or
# demoted every fault none did — it quoted the draft banner reading "Last
# edited —" verbatim and PASSED that row, and it passed a Preview button with
# no icon at all, because the comparator asks whether an icon OVERFLOWS its
# control and has no way to ask whether one is simply ABSENT.
#
# The cure is a second pass whose context has the criteria REMOVED, asked only
# "what is wrong here that nobody asked about", over the pictures the walk
# already took. `xo.sh` runs it and writes its record; this file does ONE thing
# with that record: it routes it to the captain.
#
# IT IS EVIDENCE FOR HIM, NEVER A CRITERION HE WROTE. So it lands in
# `escalations` — the channel S222 built, already on the wire, already in the
# console and already in `lcars xo report` — and it touches nothing else. No
# outcome, no count, no gap, no score, no sentence of the derivation. The
# invariant is pinned by tests/lcars-xo-evidence.test.sh § U2, which scores the
# SAME ledger twice and demands the two verdicts agree everywhere but here.
#
# THE CITATION GUARD, same as everything else in this file. A finding must name
# a picture that was actually taken, and the list of those pictures is the
# PRODUCER'S: `xo.sh` stamps the inventory it granted into the record, so the
# model cannot declare its own corpus. One that names a picture nobody took is
# an invention stated confidently, and it is dropped — loudly, in the notes,
# never in silence.
UNLISTED_LEAD = "nobody asked about this"


def merge_unlisted(path, notes):
    """(rows, escalation lines) from the unlisted pass's record.

    `notes` is appended to in place when anything is dropped."""
    doc = load_json_or_none(path)
    if not isinstance(doc, dict):
        return [], []
    findings = doc.get("findings")
    if not isinstance(findings, list):
        return [], []
    # An inventory of "" is not an inventory. When the producer recorded one,
    # every citation is checked against it; when it recorded none there is
    # nothing to check against and the guard stands down rather than inventing
    # a verdict of its own.
    inventory = set(str(s).strip() for s in (doc.get("shots") or [])
                    if str(s).strip())
    rows, lines, dropped = [], [], 0
    for f in findings:
        if not isinstance(f, dict):
            continue
        what = " ".join(str(f.get("what") or "").split())
        if not what:
            continue
        shot = str(f.get("shot") or "").strip()
        why = " ".join(str(f.get("why") or "").split())
        if inventory and shot not in inventory:
            dropped += 1
            continue
        # THE FINDING FIRST, THE ATTRIBUTION AFTER IT. The console prints these
        # behind "this one is yours to decide — ", so a line that also OPENS on
        # its provenance buries the thing he has to read behind two clauses of
        # machinery before it ever says what is wrong.
        line = what
        if why:
            line += " · %s" % why
        line += " — %s" % UNLISTED_LEAD
        if shot:
            line += "; I saw it in %s" % shot
        rows.append({"shot": shot, "what": what, "why": why,
                     "source": "unlisted"})
        lines.append(line)
    if dropped:
        notes.append(
            "%d thing%s the unlisted pass raised could not name a picture the "
            "walk took, so I left %s out rather than pass on something I cannot "
            "show you" % (dropped, "" if dropped == 1 else "s",
                          "it" if dropped == 1 else "them"))
    return rows, lines


# --- A FAULT NO LIST COULD HAVE NAMED REACHES HIM BY CONSTRUCTION ------------
#
# S224 fix round 3. The walk's own checks (xo-journey.py's carry and gate
# passes) find the things a person notices ONLY because they walked: a value
# that was on the screen they came from and is different on the screen they
# arrived at, a gate that opened on a blank form. Nothing on the captain's list
# can ever name one of those, because his list is written from the PRD, the plan
# and the drawing's parts — all of which describe screens, not the seams between
# them.
#
# S222 put one of these in front of him. S224 measured the SAME fault in the
# same words and it never left the file, because whether it reached him was left
# to the model's choice of what to write in `escalations` — and a model's choice
# is a lottery this project has lost before (S175). So it is not a choice any
# more. The producer already recorded which measurements are anchored to a part
# of the drawing (they carry `part`, and a `part-…` row on his list answers for
# them) and which are not; the unanchored ones are routed here, the same way the
# unlisted pass's findings are, and by the same rule: INFER NOTHING, ROUTE WHAT
# WAS RECORDED.
#
# IT IS EVIDENCE, NEVER A CRITERION. Same channel S222 built, no score, no
# count, no gap, no outcome — the fence xo-observe's measurements have always
# had. And the same silence discipline: on a build where the walk found nothing,
# this adds nothing at all.
WALKED_LEAD = "I only saw this because I walked it, and nothing on your list asks about it"


def _significant(text):
    return set(w for w in re.findall(r"[0-9a-z]+", str(text or "").lower())
               if len(w) > 3 or w.isdigit())


def already_said(line, existing):
    """True when one of the look's own escalation lines is already about this.

    Not a substring test: the look writes the same fact in its own words ("the
    next-up month jumped from X to Y on the start card"), and a second copy of a
    thing he has already read is noise, which is the one thing this channel
    cannot afford."""
    mine = _significant(line)
    if not mine:
        return False
    for e in existing:
        theirs = _significant(e)
        if theirs and len(mine & theirs) * 10 >= len(mine) * 6:
            return True
    return False


def walked_escalations(observations, existing):
    """Escalation lines for the measurements no criterion could have named."""
    lines = []
    for o in (observations or {}).get("observations") or []:
        # STAMPED BY THE WALK, NOT GUESSED HERE. The first cut asked instead
        # whether the measurement named a drawn part, and a part-measurement
        # with that field simply missing was routed as if no criterion could
        # name it — a rule that reads meaning out of an ABSENT field will
        # eventually be wrong about a present one. The producer says so itself.
        if not o.get("fromWalk"):
            continue
        said = " ".join(str(o.get("message") or o.get("says") or "").split())
        if not said:
            continue
        line = "%s — %s" % (said, WALKED_LEAD)
        if str(o.get("shot") or "").strip():
            line += "; I saw it in %s" % str(o["shot"]).strip()
        if already_said(said, list(existing) + lines):
            continue
        lines.append(line)
    return lines


# --- A ROW SETTLED ON ONE MOMENT OF SEVERAL ---------------------------------
#
# S224 fix round 3, the other half. `readings.json` (xo-readings.py) lists every
# place on a screen whose words read differently from one moment of the walk to
# the next. A row that quotes one of the LATER readings and never the first was
# graded on one moment of a walk that had several — measured on the captain's
# own build, where a row passed on a late picture while the walk's own record
# showed that strip reading differently at its first three moments.
#
# THIS DOES NOT DECIDE ANYTHING, AND MUST NOT. On the same corpus the rule fires
# on three rows and only one of them is a fault: the other two are counters
# doing exactly their job, and a detector that called those faults would be
# crying wolf over correct behaviour — the failure that teaches him to ignore a
# channel (S212). A value that changes is not a fault; whether it is one is the
# eye's to say, which is why the same record goes to the eye through its own
# read-only door. All this does is refuse to let the ledger read as if the
# question never came up: the row keeps its outcome and the note says, in his
# words, which moment it rests on and what the same place read first.
def moment_notes(ledger, readings):
    """Ledger notes for rows that quote a later reading and never the first."""
    out = []
    reads = [r for r in (readings or {}).get("readings") or [] if isinstance(r, dict)]
    if not reads:
        return out
    for e in ledger:
        if e.get("status") != "met":
            continue
        said = " ".join(("%s %s" % (e.get("note") or "", e.get("reason") or "")).split()).lower()
        if not said:
            continue
        for r in reads:
            first = " ".join(str((r.get("first") or {}).get("reads") or "").split())
            if not first or first.lower() in said:
                continue
            for later in (r.get("later") or []):
                quoted = " ".join(str(later.get("reads") or "").split())
                if not quoted or quoted.lower() not in said:
                    continue
                out.append(
                    u"%s was read at one moment of the walk (%s, where that place "
                    u"said “%s”). At the first moment I was on that screen (%s) the "
                    u"same place said “%s”. I have left the outcome as it was — a "
                    u"value that changes is usually a value doing its job — but this "
                    u"row speaks for one moment, not for the walk."
                    % (str(e.get("id")), str(later.get("moment") or "a later moment"),
                       quoted, str((r.get("first") or {}).get("moment") or "the first moment"),
                       first))
                break
            else:
                continue
            break
    return out


def load_walk(path):
    """THE RECORD OF HOW IT MOVED (S220 part F).

    Never a judgement, and never re-derived from how the report reads: the
    driver wrote down every click, typing, keypress and address jump as it
    made them, plus each declared step and whether it happened."""
    doc = load_json_or_none(path)
    if not isinstance(doc, dict):
        return None
    steps = [st for st in (doc.get("steps") or []) if isinstance(st, dict)]
    moves = doc.get("moves") if isinstance(doc.get("moves"), dict) else {}
    return {"steps": steps, "moves": moves, "jumps": doc.get("jumps") or [],
            "screens": doc.get("screens") or []}


# S239 FIX ROUND 3 — THE REFUSAL WAS RECORDED AND NEVER DELIVERED.
# `journey.reachUninstantiated` holds every live-check item the record could not
# INSTANTIATE, each with a reason xo-journey.py already worded for the captain.
# On a live look at ec9e4c6 ten of them sat on disk and nothing printed one.
# They belong in the section he already reads for exactly this question —
# "What I could not check" — not in a new one.
#
# TWO CLASSES, AND ONLY ONE IS HIS. `cli#4-8` and `web#4-6` want a second actor,
# an owner-not-login pair, a non-default host, an artifact nobody named: facts a
# record genuinely cannot supply, so they go unbuilt on EVERY healthy mission.
# Raising those would cry wolf on every look, which is how S212's guard got
# ignored. The split is READ OFF THE RECORD (`oneLineFix`, written by
# xo-journey.py) and never re-derived from the prose here.
def load_unbuilt(path):
    """(items a one-line record edit recovers, items the record cannot supply)."""
    doc = load_json_or_none(path)
    if not isinstance(doc, dict):
        return [], []
    un = [u for u in (doc.get("reachUninstantiated") or []) if isinstance(u, dict)]
    return ([u for u in un if u.get("oneLineFix")],
            [u for u in un if not u.get("oneLineFix")])


def unbuilt_lines(items):
    """One bullet per REASON, with the items it covers named beside it, so a
    sentence shared by two items is said once instead of twice."""
    order, by = [], {}
    for u in items:
        why = " ".join(str(u.get("why") or "").split())
        if why not in by:
            by[why] = []
            order.append(why)
        by[why].append(str(u.get("item") or "?"))
    return [(", ".join(by[why]), why) for why in order]


def walk_sentence(walk):
    m = (walk or {}).get("moves") or {}
    return ("I moved through it with %d click(s), %d typing(s) and %d keypress(es)"
            "%s." % (int(m.get("clicks") or 0), int(m.get("typings") or 0),
                     int(m.get("keypresses") or 0),
                     (", and %d address jump(s) past the front door — those screens "
                      "I reached by address, not by the flow"
                      % int(m.get("addressJumps") or 0))
                     if int(m.get("addressJumps") or 0) else
                     ", and never by typing an address"))


# --- THE SUMMING-UP CANNOT CLAIM A COMPLETENESS THE RECORD CONTRADICTS ------
# S220 fix round 3, F1. `summary` is the look's own paragraph, in its own
# voice, and it is the first prose the captain reads. On his own report it
# said "the one real parity problem is cosmetic but visible" and named three
# buttons — while five measured faults sat on disk, including a button it
# never mentions and a month that does not carry between screens, which is
# not cosmetic. A reader who stopped at the top came away believing the look
# had seen everything.
#
# So the paragraph carries its own caveat, in the same place, in his words.
# NOTHING NEW IS SCORED: this counts only what the run had already counted,
# and the S210 contract stands — measurements never move the grade.
# "Names it" means exactly that: the paragraph contains the finding's own
# part label. A finding with no part to name can never be named, so it is
# only ever covered by the first half of the sentence and never accused by
# the list. Kept word-for-word in step with board.js (`xoSummaryCaveat`).
PART_LABEL_RE = re.compile(
    u"[“\"]([^”\"]{2,60})[”\"]\\s*"
    "(?:button|control|link|chip|field|tab|icon)\\b", re.I)


def obs_part_label(o):
    m = PART_LABEL_RE.search(str((o or {}).get("message")
                                 or (o or {}).get("says") or ""))
    return (m.group(1).strip() if m else str((o or {}).get("part") or "").strip())


def summary_caveat(summary, measured):
    """The one sentence that sits under the look's own paragraph, or ''."""
    if not measured:
        return ""
    low = str(summary or "").lower()
    named, unnamed = 0, []
    for o in measured:
        lab = obs_part_label(o)
        if lab and lab.lower() in low:
            named += 1
        elif lab:
            unnamed.append(u"“%s”" % lab)
    s = ("That summing-up is my own words, from what I noticed by eye — it is "
         "not the whole count. Measurements caught %d fault%s on this build "
         "and this paragraph names %d of them"
         % (len(measured), "" if len(measured) == 1 else "s", named))
    if unnamed:
        s += "; %s %s not in it" % (" and ".join(unnamed),
                                    "is" if len(unnamed) == 1 else "are")
    return s + (u". Read the list below, under “What I measured on your "
                u"drawing”, before you take this paragraph for the whole "
                u"picture.")


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: xo-score.py <verdict> <criteria> <out> [<observations>] [<tests>]\n")
        return 2
    vpath, cpath, opath = sys.argv[1], sys.argv[2], sys.argv[3]
    obs_path = sys.argv[4] if len(sys.argv) > 4 else ""
    tests_path = sys.argv[5] if len(sys.argv) > 5 else ""
    impacts_path = sys.argv[6] if len(sys.argv) > 6 else ""
    # S220 part B: the drawing/build PAIRS, and what was measured on each.
    pairs_path = sys.argv[7] if len(sys.argv) > 7 else ""
    # S220 part F: the WALK — what the look actually did, step by step.
    # S220 part E: the SEED — whether this repo declared sample data at all.
    walk_path = sys.argv[8] if len(sys.argv) > 8 else ""
    seed_path = sys.argv[9] if len(sys.argv) > 9 else ""
    # S224 item 2: what the criteria-free pass found over the same pictures.
    # Routed to his escalations and NOWHERE else — see merge_unlisted.
    unlisted_path = sys.argv[10] if len(sys.argv) > 10 else ""
    # S224 fix round 3: the walk's own moments — see moment_notes.
    readings_path = sys.argv[11] if len(sys.argv) > 11 else ""
    readings = load_json_or_none(readings_path)
    # THE CHOICES LCARS MADE FOR HIM (2026-09-25, "decide, but tell me it
    # decided"). Research RECORDS, at the moment it decides, every open point
    # that was the captain's to settle and that it settled anyway to keep the
    # build moving — question, options considered, the one chosen, why, where.
    # It is read HERE as structured fields and rendered in report.md; nothing
    # downstream scans prose to work out that a decision was taken (RECORD, DO
    # NOT INFER — the most expensive recurring mistake in this codebase). One
    # of two producers of the report's "Choices I made for you" section; the
    # other is the scoring system's OWN assumed-impact call (impactAssumed).
    decisions_path = sys.argv[12] if len(sys.argv) > 12 else ""
    made_decisions = load_json_or_none(decisions_path)
    # S239 fix round 3: the live-check items the record could not instantiate.
    journey_path = sys.argv[13] if len(sys.argv) > 13 else ""
    unbuilt_fix, unbuilt_design = load_unbuilt(journey_path)
    # S241: the look's SHOTS directory, so a cited shot's readout — the record
    # of where that picture was actually taken — can be read back. Absent, the
    # landing rail is OFF and every row stands exactly as the eye rated it: a
    # missing directory is not evidence that a shot landed wrong.
    shots_root = sys.argv[14] if len(sys.argv) > 14 else ""
    journey_doc = load_json_or_none(journey_path)
    landing_steps = landing_by_shot(load_json_or_none(walk_path), journey_doc)
    landing_records = landing_records_exist(shots_root)
    landing_on = bool(shots_root and os.path.isdir(shots_root) and landing_records)
    landing_refusals, landing_not_reached = [], []
    landing_note = ""
    if shots_root and os.path.isdir(shots_root) and not landing_records:
        # SAY IT ONCE, DO NOT SPEND IT THIRTY TIMES. See landing_records_exist.
        landing_note = ("not one picture in this look carries a record of where it was "
                        "taken, so I could not check that any of them is of the screen "
                        "it was cited for")
    walk = load_walk(walk_path)
    seed = load_json_or_none(seed_path)
    pairs_by_part = load_pairs(pairs_path)
    observations = load_observations(obs_path)
    tests = load_tests(tests_path)

    doc = load(vpath, "verdict")
    if not isinstance(doc, dict):
        bad("the verdict is not a JSON object")

    contract = load(cpath, "criteria list")
    contract_list = contract.get("criteria") if isinstance(contract, dict) else []
    if not isinstance(contract_list, list):
        contract_list = []
    has_drawing = bool(isinstance(contract, dict) and contract.get("hasDrawing"))
    primary = set(str(c.get("id")) for c in contract_list
                  if isinstance(c, dict) and c.get("primary"))
    contract_by_id = {str(c.get("id")): c for c in contract_list if isinstance(c, dict)}

    worker_score = str(doc.get("score") or "").strip().lower()
    if worker_score not in VALID_SCORES:
        bad("the verdict names no score (want high|medium|low)")
    summary = str(doc.get("summary") or "").strip()
    if not summary:
        bad("the verdict has no summary")
    rated = doc.get("criteria")
    if not isinstance(rated, list):
        rated = []
    # AN EMPTY CONTRACT IS NOT A MALFORMED VERDICT (S216). With nothing on the
    # list there is nothing to rate, and the honest answer is LOW with that
    # sentence — not "I could not read back my own verdict".
    if not rated and contract_by_id:
        bad("the verdict rates no criteria")

    gaps_in = doc.get("gaps") if isinstance(doc.get("gaps"), list) else []
    notes = []
    # RECONCILING THE RECORDS OF ONE LOOK (S226, Number One). The reviewer keeps
    # several records of the same look — the walk, the probe/action pass, the
    # verdict. Where two of them disagree the difference is written down HERE,
    # by name, and surfaced in the verdict, rather than resolved silently in the
    # build's favour by whichever record was most generous. RECORD, DO NOT
    # INFER: every entry below is one producer's recorded field compared to
    # another producer's recorded field — never a re-reading of finished prose.
    reconciled = []

    # THE SAME FACT, DECLARED ONCE, IS ENOUGH (fix round 2, R2-1). The worker
    # declares a finding in TWO places — a ledger row and a gap entry — and on
    # 1 live spin in 4, on identical input, it put `evidence:"tests"` and the
    # failing line on the ROW and left the GAP bare. The gap loop below read
    # the gap entry only, found no shot and no declared test backing, and
    # demoted a test-proven product fault to "a call the build made": the
    # headline count fell 2 → 1 and no bug was ever filed for it. That is the
    # output lottery, not a regression — but it is a hole THIS session opened,
    # because before it every contradiction carried a shot and a second
    # declaration site with no fallback did not exist.
    #
    # So the gap loop gets the rows to fall back on. Nothing is inferred and
    # nothing new is trusted: the row's quote goes through the SAME guard,
    # against the SAME recorded output. NEVER MAKE THE MODEL DECLARE THE SAME
    # FACT TWICE — that is the whole lesson of this round.
    declared_rows = {}
    for c in rated:
        if not isinstance(c, dict):
            continue
        cid = str(c.get("id") or "").strip()
        if cid and cid not in declared_rows:
            declared_rows[cid] = c

    # --- the gaps, checked for their pictures --------------------------------
    gaps = []
    for g in gaps_in:
        if not isinstance(g, dict):
            continue
        kind = str(g.get("kind") or "").strip().lower()
        if kind not in ("contradiction", "interpretation"):
            bad("a gap names no kind (want contradiction|interpretation)")
        shots = [str(s) for s in g.get("shots") or [] if str(s).strip()]
        # WHERE THIS FINDING CAME FROM, RECORDED ON THE FINDING (S211). Declared
        # by the look that made it; when it declared nothing, taken from the
        # structural fact that it cited a shot — never from the wording.
        g_ev = str(g.get("evidence") or "").strip().lower()
        if g_ev not in VALID_EVIDENCE:
            # THE SAME FACT, DECLARED ONCE, IS ENOUGH — the evidence WORD too
            # (S240 fix round 2, D-C). The worker declares a finding in two
            # places; on the first live look it put `evidence: "transcript"` and
            # `checkedBy: "cli"`/`"workflow"` on the LEDGER ROW and left the GAP
            # record's word off, and this line then stamped the gap — and the
            # blocker built from it — `picture`. MEASURED: three gaps whose only
            # evidence was `01-help.txt` / `02-workflow-run.txt` /
            # `08-publish.txt` read "a picture" to the captain while the ledger
            # row for the very same criterion correctly read "a transcript".
            # So the row's own word is taken first, exactly as the test-citation
            # fallback below takes the row's quote. Nothing is inferred from
            # prose and no new claim is trusted: it is the producer's word about
            # its own finding, read off its other declaration site.
            row_ev = str((declared_rows.get(str(g.get("criterion") or "").strip())
                          or {}).get("evidence") or "").strip().lower()
            if row_ev in VALID_EVIDENCE:
                g_ev = row_ev
            elif shots:
                # AND THE STRUCTURAL FALLBACK IS STILL STRUCTURAL — it just
                # reads the whole name. A shot called `02-workflow-run.txt` is
                # not a picture of anything; a shot called `shot-01` or
                # `round1-01.png` is. Anything that is not a named text/data
                # file stays `picture`, so a genuine screenshot gap is unchanged.
                g_ev = shot_name_evidence(shots[0])
            else:
                # UNDECLARED AND UNCITED IS STILL NOTHING. An unrecognised word
                # must not survive this branch (it would reach the report as
                # itself), so it is cleared exactly as before.
                g_ev = ""
        g_quote = str(g.get("testQuote") or "").strip()
        # A FAILING TEST IS A PICTURE (S211). The citation guard below exists so
        # a confident-sounding fault always has something behind it; for a
        # criterion with no visual surface at all, the thing behind it is the
        # line the suite printed. That line is checked against the recorded
        # output exactly as a `met` is, so this is not a hole in the guard —
        # it is the same guard, over the other kind of evidence.
        tests_back_it = g_ev == "tests" and tests_settle(tests, g_quote)[0]
        # THE FALLBACK, AND ONLY WHERE THE HOLE IS. It applies to a
        # contradiction that is about to be demoted for want of anything behind
        # it, and that cited no line of its own — a gap that DID cite one and
        # failed the guard has already been answered, and rescuing that from a
        # second place would be exactly the promotion this guard exists to
        # refuse.
        if kind == "contradiction" and not shots and not tests_back_it and not g_quote:
            row = declared_rows.get(str(g.get("criterion") or "").strip()) or {}
            r_quote = str(row.get("testQuote") or "").strip()
            if str(row.get("evidence") or "").strip().lower() == "tests" and r_quote \
                    and tests_settle(tests, r_quote)[0]:
                tests_back_it = True
                g_ev, g_quote = "tests", r_quote
                notes.append("%r cited no line of its own, so I took the one your tests "
                             "printed from my note on the same criterion (%s) and checked "
                             "it against your test output the same way"
                             % (str(g.get("title") or g.get("criterion") or "?"),
                                str(g.get("criterion") or "?")))
        if kind == "contradiction" and not shots and not tests_back_it:
            notes.append("I called %r a mismatch but had no picture of it, so I have moved it "
                         "to the calls-the-build-made list instead — a finding with no picture "
                         "is not evidence" % (str(g.get("title") or g.get("criterion") or "?")))
            kind = "interpretation"
        gg = dict(g)
        gg["kind"] = kind
        # THE GUARD'S OWN ANSWER, carried out of the loop that made it and
        # dropped again below — never re-derived from the finished entry (a
        # contradiction that has a picture can carry an unchecked quote too).
        gg["_testsBacked"] = bool(tests_back_it)
        gg["shots"] = shots
        gg["evidence"] = g_ev or "none"
        if g_quote:
            gg["testQuote"] = g_quote
        gaps.append(gg)

    contradicted = set(str(g.get("criterion") or "") for g in gaps
                       if g["kind"] == "contradiction" and g.get("criterion"))
    # ONE FACT, RECORDED WHERE IT WAS DECIDED (fix round 2, R2-2): a
    # contradiction that the tests guard PASSED. It is what tells the failing
    # run's sentence, far below, that the ambiguity it is hedging about has
    # actually been settled — and it is set here, in the loop that settled it,
    # never worked out later by reading the report back.
    tests_proved_a_red = any(g.get("_testsBacked") for g in gaps
                             if g["kind"] == "contradiction")
    for g in gaps:
        g.pop("_testsBacked", None)

    # --- the ledger, checked for its pictures --------------------------------
    ledger = []
    demoted = []          # (id, rated, quote) — a test citation that named no case
    seen = set()
    for c in rated:
        if not isinstance(c, dict):
            continue
        cid = str(c.get("id") or "").strip()
        if not cid:
            continue
        # ONLY THE CONTRACT COUNTS (S216, inherited D3). A tester watched a
        # look rate `prd-1`/`prd-2` — ids the contract never carried, with
        # blank text — and the scorer took them as MET evidence: "ship as is"
        # on a build checked against nothing. An id that is not on the list
        # written before the look is not evidence of anything on that list.
        if cid not in contract_by_id:
            notes.append("%s is not on the list you gave me, so I have not counted "
                         "what I said about it" % cid)
            continue
        status = str(c.get("status") or "").strip().lower()
        if status not in VALID_STATUS:
            bad("criterion %r has no valid status (want met|gap|untested)" % cid)
        rated_status = status
        harness_blind = ""
        shot = str(c.get("shot") or "").strip()
        note = str(c.get("note") or "")
        # THE EVIDENCE KIND, RECORDED BY WHATEVER MADE THE JUDGEMENT (S211).
        # The look declares it; an undeclared one falls back to `picture` when
        # a shot is cited, which is a structural fact about the entry and not a
        # reading of its prose. An unrecognised word is treated as undeclared.
        evidence = str(c.get("evidence") or "").strip().lower()
        if evidence not in VALID_EVIDENCE:
            evidence = "picture" if shot else ""
        quote = str(c.get("testQuote") or "").strip()
        if status in ("met", "gap"):
            if evidence == "tests":
                # THE OVER-CLAIMING GUARD. The project's own tests may settle a
                # criterion a screenshot never could — but only the line that
                # actually speaks to it, and only if that line is in the output
                # the skill recorded. A green suite on its own proves nothing
                # about a criterion the suite is silent on.
                settled, why = tests_settle(tests, quote)
                if not settled:
                    notes.append("%s was rated %s on your tests, but %s; recorded as "
                                 "not-checked" % (cid, status, why))
                    # T1: a citation that names no test case is "couldn't
                    # check — nothing to see", decided here and journaled.
                    if why == NOT_NAMED or tally_refusal(norm_for_match(quote)):
                        harness_blind = "unobservable"
                    demoted.append((cid, status, quote))
                    status = "untested"
                    note = why
                    evidence = ""
                    quote = ""
            elif evidence == "measurement" and status == "met":
                # A MEASUREMENT MAY LOWER AN OUTCOME OR RAISE A FAULT, NEVER
                # SETTLE A CRITERION. A measured box is a number read out of
                # pairs.json — e.g. icon-bigger-than-its-control, which only
                # sees an icon OVERFLOW its button and cannot notice one that is
                # ABSENT. On a real run four rows — View, Cancel, Discard draft
                # and Preview — closed `met` on a measurement alone, and Preview
                # was a planted fault (a button with no icon at all) the ruler
                # was blind to. So a `met` on a measurement does not stand; the
                # row stays open and says why. A `gap` from a measurement is a
                # legitimate fault and is left to stand (handled by falling
                # through this chain).
                #
                # FALL BACK TO THE PICTURE IT ALREADY HAS (the captain,
                # 2026-09-25). The rule above discards a whole rail's worth of
                # rows on a coin-flip about which evidence word the eye named —
                # on a real run 8 of 14 drawing checks were cited as
                # measurements and ALL EIGHT vanished, so the look rail read
                # `nothing-checked` (half the review gone). But the eye took a
                # screenshot of that part anyway, and it is retained. So when
                # the measurement is thrown out, settle the row FROM THE EYE'S
                # OWN READING OF THAT PICTURE instead of discarding it.
                #
                # RECORD, DO NOT INFER — this is the seam this codebase has lost
                # four sessions to. The rail is deterministic Python and CANNOT
                # look at a photograph, so it does not judge the image, and it
                # does NOT read the shot's mere presence or the note's prose to
                # credit a row: that would manufacture the exact blind
                # confidence this rule exists to prevent. The PRODUCER records
                # the judgement — the eye stamps `pictureStatus` (`met`/`gap`),
                # its own verdict from looking at that shot (prompts/evaluate.md)
                # — and the rail reads only that explicit field, and only when a
                # shot backs it. The measurement STILL settles nothing; the
                # PICTURE does. A row the eye left no picture verdict on is
                # discarded exactly as before and reads unchecked — a genuinely
                # unsettled row still vanishes, which is the honest outcome; the
                # only thing cured is the row the eye DID look at with a camera.
                pic_status = str(c.get("pictureStatus") or "").strip().lower()
                if pic_status in ("met", "gap") and shot:
                    notes.append("%s was rated met on a measured box, which "
                                 "cannot settle a criterion — settled instead "
                                 "from the eye's own reading of its picture %s"
                                 % (cid, shot))
                    status = pic_status
                    evidence = "picture"
                    quote = ""
                else:
                    notes.append("%s was rated met on a measured box, but a "
                                 "measurement cannot settle a criterion; recorded "
                                 "as not-checked" % cid)
                    # S216: the row's reason is rebuilt from its note when the
                    # outcome is overruled, so the note must say why.
                    note = ("the look called this met on a measured box, but a "
                            "measurement can lower an outcome or raise a fault, "
                            "never settle a criterion — a measurement cannot settle "
                            "a criterion")
                    demoted.append((cid, status, quote))
                    status = "untested"
                    evidence = ""
                    quote = ""
            elif not shot:
                notes.append("criterion %s was rated %s with no shot cited; recorded as "
                             "untested — a judgement with no picture behind it is not a "
                             "judgement" % (cid, status))
                # S216: the row's reason is rebuilt from its note when the
                # outcome is overruled, so the note must say why.
                note = ("the look called this %s but cited no picture, and a "
                        "judgement with no picture behind it is not a judgement"
                        % OUTCOME_WORD[status])
                status = "untested"
                evidence = ""
        # ── A SHOT THAT LANDED ELSEWHERE IS NOT EVIDENCE (S241) ───────────
        # The pair the archive never had: what this shot was MEANT to show
        # against where the page actually was. Both halves are read off records
        # (see the landing rail above) — no image is compared, no filename is
        # read, and nothing is retried. A row refused here is NOT a fault in the
        # build: it is a hole in MY checking, so it goes to `untested` with the
        # recorded reason and is listed under "what defeated my checks".
        landing = None
        if landing_on and shot and status in ("met", "gap"):
            _rpath, _rdoc = landing_readout(shots_root, shot)
            _landed = landed_of(_rdoc)
            _intent = landing_intent(_rdoc, shot, landing_steps,
                                     contract_by_id.get(cid) or {}, cid)
            _step = str((landing_steps.get(shot) or {}).get("key") or "")
            if _landed is None:
                # NEVER INVENT A LANDING RECORD. An older look, or a swept
                # directory, leaves nothing to compare — and the honest answer
                # is that this picture cannot be placed, not that it is fine.
                why = ("%s — the picture is cited but nothing beside it records "
                       "where it was taken, so it cannot be shown to be of the "
                       "right screen" % LANDING_NO_RECORD)
                notes.append("criterion %s cites %s, and there is %s beside it; "
                             "recorded as untested" % (cid, shot, LANDING_NO_RECORD))
                note = why
                landing = {"mismatch": True, "reason": why, "shot": shot,
                           "expected": _intent or None, "landed": None}
                status = "untested"
                evidence = ""
                landing_refusals.append(cid)
                landing_not_reached.append({"criterion": cid, "shot": shot,
                                            "step": _step, "reason": why})
            else:
                _ok, _why = landing_verdict(_intent, _landed)
                if not _ok:
                    notes.append("criterion %s was rated %s on %s, which %s; recorded as "
                                 "untested — a shot that landed elsewhere is not evidence"
                                 % (cid, status, shot, _why))
                    note = _why
                    landing = {"mismatch": True, "reason": _why, "shot": shot,
                               "expected": _intent, "landed": _landed}
                    status = "untested"
                    evidence = ""
                    landing_refusals.append(cid)
                    landing_not_reached.append({"criterion": cid, "shot": shot,
                                                "step": _step, "reason": _why})
                # A SHOT THAT LANDED WHERE IT WAS MEANT TO IS JUST EVIDENCE, and
                # it says so by carrying nothing extra. Stamping `mismatch:
                # false` on every settled row looked tidier and broke the
                # invariant the suite guards at B23b — that the SAME worker
                # verdict through the SAME path yields a byte-identical ledger
                # whether or not the driver happened to record anything. A key
                # that appears only when the driver wrote readouts is not a
                # judgement, it is a draught.
        # AN UNTESTED ROW SETTLED NOTHING, SO IT NAMES NO SOURCE (fix round 1,
        # D3). `evidence` was stamped from the structural fact that a shot was
        # cited, and only the met/gap downgrades above ever cleared it — so a
        # row the look itself rated `untested` kept whatever it was stamped
        # with, and the table read `| UNTESTED | a picture | shot-01 — Nothing
        # on screen can settle whether batches survive a restart … |`. The
        # column named a source; the note in the same cell said that source
        # decided nothing. On a hung or crashed run the same rows said "your
        # tests". This is the session's own contract sentence — the captain
        # must never have to guess whether a judgement came from a picture, a
        # measured box, or his tests — and naming the wrong one is worse than
        # making him guess. `none` is the honest fourth word and it is already
        # in EVIDENCE_WORD. The SHOT stays on the row: a picture was taken, it
        # is still worth naming under *What I saw*; it simply did not decide
        # anything.
        if status == "untested":
            evidence = ""
            quote = ""
        entry = {
            "id": cid,
            "text": str(c.get("text") or (contract_by_id.get(cid, {}) or {}).get("text") or ""),
            "status": status,
            "note": note,
            "primary": cid in primary,
            "evidence": evidence or "none",
        }
        if shot:
            entry["shot"] = shot
        # THE SHOT STAYS IN THE RECORD. A picture that landed elsewhere is still
        # worth naming under *What I saw* — marked for what it is, so nobody
        # reads it as the screen it was cited for.
        if landing is not None:
            entry["landing"] = landing
        if quote and entry["evidence"] == "tests":
            entry["testQuote"] = quote
        take_impact(entry, c)
        entry["_ratedStatus"] = rated_status
        entry["_reason"] = str(c.get("reason") or "")
        # S223 fix round 1 (D2) — WHAT IT DID IS A RECORD, NOT A PARSE.
        # The report used to CHOP the `I tried …; I saw …` clause out of the
        # reason prose to fill its "What I did" line, and the chop lost the
        # verb ("The test tail."), missed every reason written without the
        # `; I saw` joint (39 rows fell back to a canned sentence, 1 to "Not
        # recorded" though its reason said what it tried), and printed
        # harness boilerplate over the look's own words. This is the field
        # instead: the look writes `action` beside `note` and `reason`
        # (prompts/evaluate.md, prompts/recheck.md), and it is carried here
        # verbatim. Absent → absent; the reader says so honestly.
        act = " ".join(str(c.get("action") or "").split())
        if act:
            entry["action"] = act
        # THE KIND OF QUESTION, RECORDED AS THE PASS JUDGED IT (S… , Captain
        # 2026-09-24). Beside its verdict the evaluating pass states which kind
        # of question this criterion is — `looks` (a picture can settle it) or
        # `works` (only an action can). It is RECORDED here beside the evidence
        # kind, exactly like `evidence` and `action`, and NEVER worked out later
        # from the criterion's prose (LCARS has lost three sessions to prose
        # heuristics). The captain's ruling: the reviewer states the kind AS IT
        # JUDGES, because it is already reading the requirement to judge it — so
        # this reaches the PRD/journey/drawing criteria a planner stamp never
        # touched. Unrecognised or absent is DROPPED, not defaulted: a guessed
        # `works` would be a false downgrade, a guessed `looks` a false excuse.
        # The consumer reads it through the SAME question_kind() path below.
        judged_kind = str(c.get("kind") or "").strip().lower()
        if judged_kind in ("looks", "works"):
            entry["kind"] = judged_kind
        # THE INSTRUMENT, CARRIED (S239 fix round 1, D1). `checkedBy` was
        # produced on every step readout and taught by the prompt, and then LOST
        # here: the row was rebuilt field by field and this one was never copied,
        # so it stood on 0 of 15 lines of the file the captain actually reads
        # while `evidence` said `picture` on 15 of 15. Read, never inferred —
        # nothing in this rail may work out from a row's prose how it was
        # checked. Kept on an `untested` row too: "I ran the CLI and it settled
        # nothing" is a fact about the instrument, and `evidence: none` beside it
        # already says the row proved nothing.
        checked_by = str(c.get("checkedBy") or "").strip().lower()
        if checked_by in VALID_CHECKED_BY:
            entry["checkedBy"] = checked_by
        # WHAT WAS SEEN INSTEAD, CARRIED (S240 fix round 1, D3). `sawInstead` is
        # the look's NOUN PHRASE for the thing it actually got ("it printed
        # github.com, the hardcoded one"), and it was dropped by this rebuild —
        # so `xo-logs.py` fell back to the row's `note`, a SENTENCE, and spliced
        # it into "the build gave …". One line, read never inferred, and the
        # `note` is still carried beside it.
        saw_instead = " ".join(str(c.get("sawInstead") or "").split())
        if saw_instead:
            entry["sawInstead"] = saw_instead
        if status == "untested" and rated_status == "untested":
            why_not = str(c.get("couldNotCheck") or "").strip().lower()
            if why_not in COULD_NOT_CHECK:
                entry["couldNotCheck"] = why_not
        # WHOSE FAULT IT IS, RECORDED (S240). See CAUSE_CLASS: the look declares
        # `product` or `infrastructure` beside `couldNotCheck`, and an absent or
        # unrecognised word is left ABSENT rather than defaulted — the consumer
        # then reads it as ours, says `causeRecorded: false`, and never files a
        # bug against the build on a word nobody wrote.
        if status == "untested":
            cause = str(c.get("cause") or "").strip().lower()
            if cause in CAUSE_CLASS:
                entry["cause"] = cause
                entry["causeRecorded"] = True
            else:
                entry["causeRecorded"] = False
        if harness_blind:
            entry["couldNotCheck"] = harness_blind
        if status == "gap":
            # Notes for the fix loop, never the grade (ISTQB's triage inputs):
            # is there a way round it, and how often did it happen.
            wa = c.get("workaround")
            if isinstance(wa, bool):
                entry["workaround"] = wa
            tries = str(c.get("tries") or "").strip()
            if tries:
                entry["tries"] = clip(tries, 40)
        ledger.append(entry)
        seen.add(cid)

    # A criterion the contract carried and the look never rated. Never dropped.
    for cid, c in contract_by_id.items():
        if cid in seen:
            continue
        entry = {
            "id": cid, "text": str(c.get("text") or ""), "status": "untested",
            "note": "I never got to this one, so it is unchecked", "primary": cid in primary,
            "evidence": "none",
        }
        take_impact(entry, {})
        entry["_ratedStatus"] = ""
        entry["_reason"] = ""
        ledger.append(entry)
        notes.append("%s was on the list you gave me and I never rated it" % cid)

    # THE NO-DRAWING GUARD (S210). NEVER SILENTLY MET. A criterion the plan
    # marked `drawnAt` names a place IN A DRAWING to compare the app against —
    # and if this mission has no drawing at all, no amount of worker confidence
    # makes that comparison possible. This overrules whatever status the worker
    # gave, on purpose: the honest answer here is a fact about the mission's own
    # attachments, not something a look could ever get right by trying harder.
    if not has_drawing:
        for entry in ledger:
            row = contract_by_id.get(entry["id"]) or {}
            if not row.get("drawnAt"):
                continue
            if entry["status"] == "untested" and entry["note"] == NO_DRAWING_NOTE:
                continue
            notes.append("%s asks to be checked against the drawing, but this "
                         "mission has none, so I am marking it not-checkable "
                         "rather than trusting what the look called it"
                         % entry["id"])
            entry["status"] = "untested"
            entry["note"] = NO_DRAWING_NOTE
            entry["evidence"] = "none"
            # S225 — WHICH OF THE TWO BLIND OUTCOMES THIS IS, RECORDED WHERE IT
            # IS KNOWN. Nobody failed to SEE this: there was no drawing to hold
            # the build against, so the check was never set up. That makes it
            # ours to fix (attach the drawing) and it says so by name.
            entry["couldNotCheck"] = "unreachable"
            entry.pop("shot", None)
            entry.pop("testQuote", None)

    # THE TICKET-CONTRADICTION GUARD (the ruling of 2026-09-25 — TEETH RESTORED).
    # NEVER LET A DELIBERATE OMISSION CERTIFY ITSELF. xo-criteria.py marks a
    # ticket (plan) criterion `contradictsRequirement` when the PLANNER DECLARED
    # — with `direction: "removes"` — that the criterion deliberately removes a
    # requirement the PRD asks FOR. That is now a RECORD, not a prose guess: the
    # earlier detector read the criterion's English to decide polarity and was
    # beaten twice in one day (once through a CORRECT link, misreading the
    # negative "never asks the player to name anything" as affirmative), so the
    # consequence was withdrawn while the design was ruled on. The ruling: the
    # planner STATES which way round each criterion is, and this check READS that
    # statement — nothing reads prose for polarity any more. So the teeth come
    # back, and they are now sound.
    #
    # THE CONSEQUENCE, and why it moves the grade. A ticket the planner declared
    # `removes` is certifying that a stated goal is gone — so the requirement it
    # names is NOT delivered, whatever a look thought it saw. Two things happen:
    # the offending ticket criterion is dropped from met to a gap so it can never
    # read as a clean win, AND the PRIMARY requirement it names is overruled to a
    # gap. The primary sits in the graded person group, so this is what stops a
    # build that deliberately removes a requirement from reading HIGH on the
    # strength of a look that was fooled. The pair is named — which ticket
    # criterion, which requirement — so the captain sees the disagreement.
    ledger_by_id = {e["id"]: e for e in ledger}
    for entry in ledger:
        row = contract_by_id.get(entry["id"]) or {}
        req = row.get("contradictsRequirement")
        if not req:
            continue
        req_text = str((contract_by_id.get(req) or {}).get("text") or req)
        notes.append(
            "%s declares it deliberately REMOVES requirement %s (%s), which the "
            "PRD asks for — so the build does not deliver that requirement" % (
                entry["id"], req, clip(req_text, 60)))
        if entry["status"] == "met":
            entry["status"] = "gap"
            entry["note"] = ("this ticket criterion declares it deliberately "
                             "removes requirement %s, which the PRD asks for" % req)
            entry["evidence"] = "none"
            entry.pop("shot", None)
            entry.pop("testQuote", None)
        preq = ledger_by_id.get(req)
        if preq is not None and preq.get("status") == "met":
            preq["status"] = "gap"
            preq["note"] = ("a ticket in this plan (%s) declares it deliberately "
                            "removes this requirement, so the build does not "
                            "deliver it" % entry["id"])
            preq["evidence"] = "none"
            preq.pop("shot", None)
            preq.pop("testQuote", None)


    # not on the screen was NOT TAKEN, and a step nobody took cannot have
    # worked. It is named — "couldn't check (unreachable)" about THIS step —
    # rather than skipped silently, which is what a walk that quietly stopped
    # halfway used to look like in a report.
    if walk:
        by_step = {str(st.get("key")): st for st in walk["steps"]}
        # WHAT THE PROBE ALREADY REACHED, IN THIS SAME LOOK (S226 R4). Mission
        # "Name your hero": the probe pressed `n`, opened the hero panel and
        # photographed its validation bubble, while the walk — hunting for a
        # button that was not there — called the SAME screen unreachable, and
        # the grade came from the walk. A screen the probe stood on is not
        # unreachable. The set is the URLs the observation pass RECORDED
        # standing on (`screen`); the walk step RECORDS the URL it stood on
        # (`urlBefore`/`urlAfter`). Two recorded URLs, compared — no prose read.
        reached_screens = set()
        for o in (observations or {}).get("observations") or []:
            scr = str(o.get("screen") or "").strip()
            if scr:
                reached_screens.add(scr)
        for entry in ledger:
            row = contract_by_id.get(entry["id"]) or {}
            st = by_step.get(str(row.get("journeyStep") or ""))
            # A STEP THAT CHANGED NOTHING IS THE SAME KIND OF SILENCE as a step
            # whose control was not there (fix round 1, D6). The driver now
            # says so in the record; here it becomes a named couldn't-check on
            # the criterion, instead of a "worked" nobody earned.
            if not st or st.get("status") not in ("unreachable", "no-change"):
                continue
            how = st.get("status")
            # THE WALK MAY NOT CALL A SCREEN UNREACHABLE THAT THE PROBE REACHED
            # (S226 R4). Only "unreachable" is a claim about arriving at all —
            # "no-change" is a claim the action did nothing, which a probe
            # standing on the screen does NOT contradict, so it is left alone.
            if how == "unreachable" and entry["status"] == "met":
                here = {str(st.get("urlBefore") or "").strip(),
                        str(st.get("urlAfter") or "").strip()} - {""}
                if here & reached_screens:
                    hit = sorted(here & reached_screens)[0]
                    notes.append(
                        "%s: the walk called the journey step \"%s\" unreachable, "
                        "but the probe reached that same screen (%s) in this look, "
                        "so I am NOT downgrading it — the two records disagreed and "
                        "the walk did not win by being the more generous"
                        % (entry["id"], st.get("name") or st.get("key"), hit))
                    reconciled.append({
                        "id": entry["id"],
                        "kind": "walk-overruled-by-probe",
                        "step": st.get("name") or st.get("key"),
                        "screen": hit,
                        "walkSaid": "unreachable",
                        "probeReached": True,
                    })
                    entry.setdefault("ledgerNote", "")
                    continue
            if entry["status"] == "untested":
                entry.setdefault("couldNotCheck", how)
                continue
            notes.append("%s is the journey step \"%s\", and I could not take it "
                         "(%s) — so it is not-checkable, whatever the look called it"
                         % (entry["id"], st.get("name") or st.get("key"),
                            st.get("why") or "the control was not on the screen"))
            entry["status"] = "untested"
            entry["couldNotCheck"] = how
            entry["note"] = ("I could not take this step: %s"
                             % (st.get("why") or "the control it names was not on the screen"))
            entry["evidence"] = "none"
            entry.pop("shot", None)
            entry.pop("testQuote", None)

    # THE UNREACHABLE-PART GUARD (S220 part B). A requirement about a part of
    # the DRAWING that the build has not got can never be "worked": there was
    # nothing on the screen to work. The look has said it was met before — on
    # 2026-09-19 it called four buttons correct with the faults in its own
    # frame — and this is a fact about two boxes, not a call a look could get
    # right by trying harder, so it overrules whatever was said.
    #
    # AND THE OVERRULES ARE JOURNALED (the captain's standing rule: a measured
    # difference is EVIDENCE, never a verdict — the look may overrule it, and
    # when it does, the reason it gave is written down beside the measurement
    # so he can see who decided what).
    for entry in ledger:
        row = contract_by_id.get(entry["id"]) or {}
        part = row.get("drawnPart")
        pair = pairs_by_part.get(str(part)) if part else None
        if not pair:
            continue
        if not pair.get("reachable"):
            if entry["status"] != "untested":
                notes.append("%s is about a part of your drawing the build has not got "
                             "(%s), so I am marking it couldn't-check rather than "
                             "trusting what the look called it"
                             % (entry["id"], pair.get("why") or "not found"))
            entry["status"] = "untested"
            entry["note"] = UNREACHABLE_PART_NOTE
            entry["evidence"] = "none"
            # S225 — the build has not got this part of the drawing, so there
            # was nothing on the screen to look at: I could not set it up.
            entry["couldNotCheck"] = "unreachable"
            entry.pop("shot", None)
            entry.pop("testQuote", None)
            continue
        fired = [m for m in (pair.get("measurements") or []) if m.get("fires")]
        if fired and entry["status"] == "met":
            notes.append("%s: I measured %s and the look overruled it — its reason: %s"
                         % (entry["id"],
                            "; ".join(str(m.get("says") or m.get("id")) for m in fired),
                            (entry.get("note") or "").strip() or "none given"))

    # IMPORTANCE, RECORDED ONCE AND REUSED (S216 fix round 1, D5). Before the
    # grade is derived, so the grade reads the record, not this look's guess.
    impacts_note, impacts_kept, _ = apply_recorded_impacts(
        ledger, impacts_path, {cid: str(c.get("text") or "") for cid, c in contract_by_id.items()})
    if impacts_kept:
        notes.append("this look rated how much %d item%s matter%s differently from the "
                     "first look; I kept the first look's rating%s (%s)"
                     % (len(impacts_kept), "" if len(impacts_kept) == 1 else "s",
                        "s" if len(impacts_kept) == 1 else "",
                        "" if len(impacts_kept) == 1 else "s",
                        ", ".join(k[0] for k in impacts_kept)))
    mismatches = near_duplicates(
        ledger, {cid: c.get("text") for cid, c in contract_by_id.items()})

    # A contradiction naming a criterion that is no longer contradicted in the
    # ledger (downgraded above for want of a shot) must not still count.
    contradicted = set(cid for cid in contradicted
                       if any(e["id"] == cid and e["status"] == "gap" for e in ledger)
                       or cid not in seen)

    # ─── THE KIND OF QUESTION DECIDES THE KIND OF PROOF (Captain, 2026-09-24) ─
    # Number One PRESSES things and it PHOTOGRAPHS things, and both used to
    # count equally as proof that something WORKS. They are not equal. A picture
    # of a Pause button proves it is DRAWN, not that pausing pauses. So each
    # criterion is judged by the RIGHT KIND of proof, read from its produce-time
    # STAMP (see question_kind — the planner's `kind`/`notVisual`, never the
    # criterion's prose):
    #
    #   * a LOOKS-question backed by a picture is a FULL PASS — a picture
    #     genuinely settles "the title is there". Pictures are NOT devalued
    #     where they belong; that is half the ruling.
    #   * a WORKS-question backed by NOTHING BUT A PICTURE is NOT a pass — it was
    #     never exercised, so it reads "I could not check this" in the words a
    #     person reads, and it is surfaced BY NAME. A works-question that got a
    #     real action (or its own test) is untouched and passes on its merits.
    #
    # This runs BEFORE the outcome is stamped below, so a downgraded row is
    # already `untested` when outcome_of reads it, and the grade (which reads
    # only worked/didn't-work) can never bank a works-question nobody exercised.
    works_on_look_alone = []
    split = {"looks": 0, "works": 0, "worksExercised": 0, "worksPictureOnly": 0,
             "unstamped": 0}
    for e in ledger:
        # RECORDED KIND WINS, THEN THE PRODUCE-TIME STAMP (Captain 2026-09-24).
        # question_kind reads a row's explicit `kind`, then `notVisual`. Called
        # on the LEDGER ROW it reads the kind the pass RECORDED as it judged;
        # only when the pass stated none does it fall back to the CONTRACT row,
        # where the planner's `kind`/`notVisual` stamp still stands. Same path,
        # two sources — never a second classifier. An unstamped criterion is
        # UNKNOWN from both and is never downgraded (the guard is preserved).
        kind, kfrom = question_kind(e)
        if kind:
            kfrom = "recorded"
        else:
            kind, kfrom = question_kind(contract_by_id.get(e["id"]) or {})
        if kind:
            e["questionKind"] = kind
            if kfrom == "notVisual":
                e["questionKindFrom"] = "notVisual"
            elif kfrom == "recorded":
                e["questionKindFrom"] = "recorded"
        # THE SPLIT, COUNTED OFF THE STAMPS — said out loud below (ruling #5).
        if kind == "looks":
            split["looks"] += 1
        elif kind == "works":
            split["works"] += 1
            if not settled_by_picture_alone(e):
                split["worksExercised"] += 1
            else:
                split["worksPictureOnly"] += 1
        else:
            split["unstamped"] += 1
        # THE DOWNGRADE: a works-question that PASSED on a picture alone did not
        # actually get checked. Never `met`, never counted as worked.
        if kind == "works" and e["status"] == "met" \
                and settled_by_picture_alone(e):
            e["status"] = "untested"
            e["couldNotCheck"] = "works-needs-action"
            e["evidence"] = "none"
            e["note"] = ("This asks whether it WORKS, and I only have a picture "
                         "of it. A picture shows the thing is on screen, not "
                         "that it does anything, so I could not check it — it "
                         "needs a press, not a photo.")
            e.pop("testQuote", None)
            works_on_look_alone.append({"id": e["id"], "text": e.get("text") or ""})

    # ─── S225: THE SOURCE IS READ AT LAST ────────────────────────────────────
    # Every guard above has finished; a row's status and its `couldNotCheck`
    # word are final, so this is the first line at which the four-way outcome
    # is knowable. Both facts are stamped on the row itself — `source` copied
    # from the contract that was written before the look, `group` derived from
    # it — so nothing downstream ever has to re-derive either, and no surface
    # has to read provenance back out of prose.
    for e in ledger:
        row = contract_by_id.get(e["id"]) or {}
        src = str(row.get("source") or "").strip()
        if src:
            e["source"] = src
        # THE KIND AND THE DRAWING TIE ARE READ HERE TOO — an appearance claim
        # (declared drawn at derivation AND judged a `looks`-question by the eye)
        # is graded on the drawing rail, never the person rail (captain,
        # 2026-09-25). `questionKind` was resolved above (the eye's recorded
        # kind, else the planner's produce-time stamp); `drawnAt` is the
        # producer's derivation-time declaration that this surface is IN the
        # drawing. Both are PRODUCER fields — nothing here reads the prose.
        e["group"] = group_of(src, e.get("questionKind"), bool(row.get("drawnAt")))
        e["outcome"] = outcome_of(e)

    # ─── S226 R2/R3: A PASS SAYS WHAT ESTABLISHED IT ─────────────────────────
    # A criterion settled "worked" (status met) records WHICH record settled it
    # and what that record actually did. RECORD, DO NOT INFER: each answer is
    # read from a field a producer already stamped on the row — the tests'
    # quoted line, the probe's `action`, or the bare fact that only a picture
    # was cited — never from re-reading the note's prose. A pass that did no
    # more than look at a screenshot is marked look-only; and because a passing
    # row backed by nothing but a look is never legitimate on its own, every
    # such row is also surfaced BY NAME so it is visible in the output.
    passing_on_look_alone = []
    for e in ledger:
        if e["status"] != "met":
            continue
        ev = str(e.get("evidence") or "").strip().lower()
        if ev == "tests" and str(e.get("testQuote") or "").strip():
            e["settledBy"] = {"record": "tests",
                              "did": str(e["testQuote"]).strip()}
        elif str(e.get("action") or "").strip():
            e["settledBy"] = {"record": "action", "lookedOnly": False,
                              "did": str(e["action"]).strip()}
        else:
            did = "looked at a screenshot"
            if e.get("shot"):
                did += " (%s)" % str(e["shot"]).strip()
            e["settledBy"] = {"record": "picture", "lookedOnly": True, "did": did}
            passing_on_look_alone.append({"id": e["id"],
                                          "text": e.get("text") or ""})

    by_group = {k: [e for e in ledger if e["group"] == k] for k in GROUP_ORDER}

    met = sum(1 for e in ledger if e["status"] == "met")
    gap = sum(1 for e in ledger if e["status"] == "gap")
    untested = sum(1 for e in ledger if e["status"] == "untested")

    # --- THE DERIVATION ------------------------------------------------------
    # THE DERIVATION IS THE FIRST LINE THE CAPTAIN READS, on a phone, so it is
    # written to him: what the build does to HIM, then the machine ids in
    # brackets (captain's ruling, 2026-09-13 — "I need more plain English in my
    # report"). Plain is not vague: every id and every count stays in the line.
    #
    # AND THE THINGS HAVE NAMES (fix round 2, D2). "2 things in the build do not
    # match what you asked for (t-3-ac1, t-5-ac1)" made the captain read two
    # machine handles to learn nothing — while the gap behind each one carried a
    # title in his own words, sitting right here in this function. The names go
    # in the sentence; the ids stay, in the brackets after it.
    def named(cid, limit=60):
        for g in gaps:
            if str(g.get("criterion") or "") == cid and str(g.get("title") or "").strip():
                return short_name(g["title"], max(limit, 60) + 30)
        row = contract_by_id.get(cid) or {}
        return short_name(row.get("text"), limit) or cid

    # WHAT WENT WRONG, NOT WHAT WAS ASKED (D3). "Known issues shipping with it:
    # the bar is red" reads as if the bar is red. A known issue names its fault:
    # what was expected against what was seen, off the finding the look
    # recorded — or the row's own observation — and when there is neither, it
    # says it didn't work and where to look.
    def fault(e, room=140):
        # A smaller room (the why paragraph) shortens what was asked and seen.
        nm = named(e["id"])
        if e["status"] == "untested":
            return "%s — I could not check it" % nm
        for g in gaps:
            if str(g.get("criterion") or "") != e["id"]:
                continue
            exp, saw = unstop(str(g.get("expected") or "")), unstop(str(g.get("saw") or ""))
            if exp.strip() and saw.strip():
                return "%s — you asked for %s; the build gives %s" % (
                    nm, clip(exp, room), clip(saw, room))
        obs = unstop(" ".join(str(e.get("note") or "").split()))
        if obs and _plain(obs) != _plain(e.get("text")) \
                and _plain(obs) != _plain((contract_by_id.get(e["id"]) or {}).get("text")):
            return "%s — didn't work: %s" % (nm, clip(obs, room))
        return "%s — didn't work (see the row)" % nm

    # --- WHAT THE SCORE WORD MEANS, off the SAME LEDGER ----------------------
    # THE BUG THIS CLOSES (S213 fix round 1, D4). The three score words carried
    # a fixed sentence apiece, written into the board's stylesheet-side code:
    # MEDIUM always read "the primary flow works end to end; some criteria gap
    # or could not be tested". On a mission whose verdict was "nothing could be
    # tested — the calculator never rendered", with every criterion untested,
    # the captain hovered MEDIUM and was told the primary flow worked. Nobody
    # ever saw that flow. It is the exact fault this session exists to kill,
    # relocated from a line of copy into a tooltip.
    #
    # So the sentence is DECIDED HERE, in the same breath as the score, off the
    # same ledger, by the same rule — not inferred at the surface from the
    # verdict's prose. A meaning derived from the counts cannot claim something
    # the counts do not support.
    # S225 — THE HEADLINE READS THE PERSON GROUP, BY THE CAPTAIN'S RULING. The
    # prose below (the derivation, the meaning, the why-this-grade paragraph)
    # is the headline's own explanation, so it is built off the same rows the
    # headline was decided from. The other two groups get their own lines,
    # below the grade, where they can never be averaged into it and can never
    # be hidden either.
    grade = derive_grade(by_group[GROUP_PERSON])
    score, core = grade["score"], grade["core"]

    def group_block(key):
        rows = by_group[key]
        b = {"question": GROUP_QUESTION[key], "kind": GROUP_KIND[key],
             "aside": GROUP_ASIDE[key], "total": len(rows)}
        for name, o in (("worked", OUTCOME_WORKED), ("didntWork", OUTCOME_DIDNT),
                        ("couldntSee", OUTCOME_BLIND), ("couldntSetUp", OUTCOME_SETUP)):
            b[name] = sum(1 for e in rows if e["outcome"] == o)
        b["met"] = b["worked"]
        b["gap"] = b["didntWork"]
        b["untested"] = b["couldntSee"] + b["couldntSetUp"]
        b["ids"] = [e["id"] for e in rows]
        if GROUP_KIND[key] == "graded":
            if key == HEADLINE_GROUP:
                # The headline group always carries a grade: it IS the grade,
                # and an empty list is still an answer ("nothing here is
                # vouched for"), which is the rule that fires.
                b["grade"], b["rule"] = grade["score"], grade["rule"]
                b["coverageFloorPct"] = grade["coverageFloorPct"]
                b["coveragePct"] = grade["coveragePct"]
                b["isHeadline"] = True
            elif rows:
                g = derive_grade(rows)
                b["grade"], b["rule"] = g["score"], g["rule"]
                b["coverageFloorPct"] = g["coverageFloorPct"]
                b["coveragePct"] = g["coveragePct"]
            # A GROUP WITH NOTHING ON IT IS NOT A LOW ONE. A mission with no
            # drawing has no drawing line; grading its empty list would print
            # "Does it look like your drawing? — LOW" at a captain who never
            # gave us one. The key is simply absent, and the report skips it.
        else:
            # COVERAGE, NEVER A GRADE. "Covered" is: something actually settled
            # this row, either way. "Uncovered" is: nothing did — which is a
            # hole in the checking, not a fault in the build. `backedByTests`
            # is the narrower fact for anyone who wants it: a row that closed
            # `met` on a named line of the project's own suite.
            b["covered"] = b["met"] + b["gap"]
            b["uncovered"] = b["untested"]
            b["backedByTests"] = sum(1 for e in rows if e["status"] == "met"
                                     and e.get("evidence") == "tests")
        return b

    groups = {k: group_block(k) for k in GROUP_ORDER}

    # S225 — WHAT DEFEATED MY CHECKS, LISTED FOR US TO FIX, NEVER COUNTED
    # AGAINST HIM. These are exactly the two outcomes that no longer touch the
    # grade, and the price of that is that each one has to say what stopped it:
    # a list of blind spots with no reasons on it is a list nobody can act on.
    def _check_row(e):
        r = {"id": e["id"], "group": e["group"], "name": named(e["id"]),
             "why": (" ".join(str(e.get("note") or "").split())
                     or "nothing on the record says what stopped me")}
        if e.get("couldNotCheck"):
            r["defeatedBy"] = e["couldNotCheck"]
        return r

    my_checking = {
        "note": MY_CHECKING_NOTE,
        "couldntSee": [_check_row(e) for e in ledger if e["outcome"] == OUTCOME_BLIND],
        "couldntSetUp": [_check_row(e) for e in ledger if e["outcome"] == OUTCOME_SETUP],
    }
    my_checking["total"] = (len(my_checking["couldntSee"])
                            + len(my_checking["couldntSetUp"]))

    # IS ANYTHING OPEN ON THE OTHER TWO LISTS? The headline may only claim
    # "everything you asked for is in the build" when that is true of ALL THREE
    # of his lists. The person group setting the grade is the captain's ruling;
    # it is not a licence for the grade's sentence to speak for lists it no
    # longer reads. When the drawing or the ticket contract has anything open,
    # the sentence says what it actually covers and the three-question block
    # under it carries the rest.
    others_open = sum(groups[k][n] for k in (GROUP_DRAWING, GROUP_CONTRACT)
                      for n in ("didntWork", "couldntSee", "couldntSetUp"))

    def ids(rows):
        return ", ".join(e["id"] for e in rows)

    hi_gap, hi_blind = grade["highGap"], grade["highBlind"]
    low_gap = [e for e in grade["lowOpen"] if e["status"] == "gap"]
    low_blind = [e for e in grade["lowOpen"] if e["status"] == "untested"]

    # S217's picture fact, known before the words are chosen: the headline's
    # word budget has to leave room for its short lead.
    picture_names = [str(p) for p in (contract.get("pictures") or [])
                     if str(p).strip()] if isinstance(contract, dict) else []
    picture_only = bool(picture_names) and not has_drawing

    # ─── S216 fix round 2 (W1): SHORT, ON A PHONE ───────────────────────────
    # The headline listed seven cut-off names with their ids and the "why"
    # listed all nineteen of the mission's core items — forty lines at 390px.
    # Now every list is AT MOST THREE names and "and N more — see the list";
    # the headline has a word budget and falls back from names to counts; the
    # full per-item detail stays in the table, where it always was.
    CAP = 3
    budget = HEADLINE_WORDS - (word_count(PICTURE_LEAD) if picture_only else 0)

    def some(rows, fmt, n=CAP, sep=", "):
        """At most n of them, and how many more — never the whole list."""
        got = [fmt(e) for e in rows[:n]]
        more = len(rows) - len(got)
        if not got:
            return ""
        if more > 0:
            return "%s and %d more" % (sep.join(got), more)
        if len(got) == 1:
            return got[0]
        return "%s and %s" % (sep.join(got[:-1]), got[-1])

    def short(e):
        return named(e["id"], LIST_NAME)

    def named_id(e):
        return "%s (%s)" % (short(e), e["id"])

    def fault_id(e):
        return "%s (%s)" % (fault(e, 70), e["id"])

    def fit(*cands):
        """The first candidate inside the headline's word budget, else the
        last (the counts-only one, which always is)."""
        for c in cands:
            if c and word_count(c) <= budget:
                return c
        return cands[-1]

    def n_things(n, what="thing"):
        return "%d %s%s" % (n, what, "" if n == 1 else "s")

    if grade["rule"] == "nothing-listed":
        why = ("there was nothing on your list to check, so nothing here is "
               "vouched for.")
        meaning = ("There was nothing on your list to check, so nothing here is "
                   "vouched for — this is not a clean bill of health")
    elif grade["rule"] == "high-broken":
        why = fit(*["the point of the mission does not work — %s. What you set out "
                    "to get is not there yet." % some(hi_gap, named_id, n, "; ")
                    for n in (2, 1)] +
                  ["%s of the point of the mission didn't work; what you wanted is "
                   "not there yet." % n_things(len(hi_gap), "part")])
        meaning = ("What you set out to get is not in the build — look for "
                   "yourself before this goes anywhere")
    elif grade["rule"] == "high-unchecked":
        why = fit(*["I could not check the point of the mission — %s — so nothing "
                    "here says it works." % some(hi_blind, named_id, n)
                    for n in (2, 1)] +
                  ["I could not check %s of the mission's point, so it is not "
                   "vouched for." % n_things(len(hi_blind), "part")])
        meaning = ("I could not check the point of the mission, so it is not "
                   "vouched for — look for yourself")
    elif grade["rule"] == "nothing-checked":
        why = ("I could not check anything on your list, so nothing here is "
               "vouched for.")
        meaning = ("I could not check anything on your list, so nothing here is "
                   "vouched for — this is not a clean bill of health")
    elif grade["rule"] == "too-little-checked":
        # UNKNOWN, NOT GOOD AND NOT A FAULT. More than half of this group could
        # not be checked, so it is too thin to certify — but nothing here didn't
        # work, so it is not held against the build either.
        why = ("too little was checked to grade — I could not check %d of %d."
               % (grade["total"] - grade["checked"], grade["total"]))
        meaning = ("Too little was checked to grade — only %d of %d rows got a "
                   "real outcome — so this is not a grade, it is a gap in my "
                   "checking; nothing here is a fault in your build"
                   % (grade["checked"], grade["total"]))
    elif grade["rule"] == "held-back-coverage":
        # HELD BACK, NOT MARKED DOWN. Everything checked worked; the grade is
        # one notch below HIGH only because too much went unchecked to certify.
        # The words name the floor and the count so the rule is on the page.
        _un = grade["total"] - grade["checked"]
        why = ("held back to MEDIUM: everything I could check worked, but I only "
               "checked %d of %d — below the %d%% a HIGH needs — so %d of %d went "
               "unchecked." % (grade["checked"], grade["total"],
                               grade["coverageFloorPct"], _un, grade["total"]))
        meaning = ("Everything I could check worked, but the grade is held back "
                   "to MEDIUM: only %d of %d were checked, below the %d%% a HIGH "
                   "needs, so %d of %d went unchecked — that is a gap in my "
                   "checking, not a fault in your build"
                   % (grade["checked"], grade["total"], grade["coverageFloorPct"],
                      _un, grade["total"]))
    elif score == "medium":
        # What did not work and what could not be checked are said apart, so a
        # MEDIUM that rests on a blind spot never reads as a clean bill.
        mg, mb = grade["mediumGap"], grade["mediumBlind"]

        def medium_line(n, fmt_gap):
            bits = []
            if mg:
                bits.append("go with %s known issue%s — %s"
                            % ("this" if len(mg) == 1 else "these",
                               "" if len(mg) == 1 else "s", some(mg, fmt_gap, n, "; ")))
            if mb:
                bits.append("I could not check %s%s"
                            % (some(mb, named_id, n),
                               "" if mg else ", so %s"
                               % ("it ships as a known issue" if len(mb) == 1
                                  else "they ship as known issues")))
            return "the point of the mission works; %s." % "; and ".join(bits)
        counted = []
        if mg:
            counted.append("%s didn't work" % n_things(len(mg)))
        if mb:
            counted.append(("%d couldn't be checked" if mg else "%s couldn't be checked")
                           % (len(mb) if mg else n_things(len(mb))))
        why = fit(medium_line(2, fault_id), medium_line(1, fault_id),
                  medium_line(1, named_id),
                  "the point of the mission works; %s." % " and ".join(counted))
        said = []
        if mg:
            said.append("%d known issue%s that didn't work as asked"
                        % (len(mg), "" if len(mg) == 1 else "s"))
        if mb:
            said.append("%d item%s I could not check" % (len(mb), "" if len(mb) == 1 else "s"))
        meaning = ("The point of the mission works; it would ship with %s"
                   % " and ".join(said))
    elif grade["lowOpen"] or hi_blind or grade["mediumBlind"]:
        # D1/D2: didn't-work and couldn't-check are said apart, with counts.
        #
        # S225 — AND A BLIND SPOT THAT NO LONGER MOVES THE GRADE IS SAID LOUDER,
        # NOT QUIETER. Under change 03 a high or medium nobody could check stops
        # dragging the score down; the one thing that must not follow is a
        # headline reading "everything you asked for is in the build" over a row
        # nobody ever saw. So the moment this group holds ANY unchecked row, the
        # headline opens on what it could check and names the gap in the same
        # breath. With nothing unchecked above polish, every word below is the
        # sentence S216 fix round 2 already wrote, unchanged.
        big_blind = hi_blind + grade["mediumBlind"]
        bits = []
        if big_blind:
            bits.append("I could not check %s" % n_things(len(big_blind)))
        bits += smaller_items(low_gap, low_blind, None)
        n = len(big_blind) + len(grade["lowOpen"])
        tail = ", and %s the grade" % ("it doesn't change" if n == 1 else "they don't change")
        if big_blind:
            why = ("everything I could check worked; %s%s."
                   % (" and ".join(bits), tail))
            meaning = ("Everything I could check worked; %s%s — that is a gap in "
                       "my checking, not a fault in the build"
                       % (" and ".join(bits), tail))
        else:
            why = ("everything that matters on your list worked; %s%s."
                   % (" and ".join(bits), tail))
            meaning = ("Everything that matters worked; %s%s — ship as is"
                       % (" and ".join(bits), tail))
    else:
        # D7: say what the grade actually rested on — pictures, your tests, or
        # both — counted off the rows' recorded evidence kind.
        seen = evidence_said([e for e in ledger if e["status"] == "met"], has_drawing)
        if others_open:
            # S225 — SCOPED TO WHAT THIS GRADE READ. The person group is clean,
            # so the grade is HIGH and stays HIGH; but something on the drawing
            # or the ticket contract is open, and "everything you asked for" is
            # a claim about all three of his lists. It is not made here.
            why = "everything a person can do worked, and %s." % seen
            meaning = ("Everything a person can do worked — %s — the drawing and "
                       "the ticket contract are on their own lines" % seen)
        else:
            why = "everything you asked for is in the build, and %s." % seen
            meaning = "Everything you asked for worked — %s — ship as is" % seen

    # --- WHY THIS GRADE: at most four short sentences (S216 fix round 2) -----
    #   1. the rule that fired, in words;
    #   2. the point of the mission, in ONE sentence: how many, three names;
    #   3. what didn't work, by name with its fault;
    #   4. what couldn't be checked, how many and three names.
    # Nothing else — the rows carry the rest.
    rule_words = {
        "nothing-listed": "there was nothing on your list to check",
        "high-broken": "something that is the point of the mission did not work",
        "high-unchecked": ("I could not check the point of the mission, and I will "
                           "not call a build good on what I could not see"),
        "nothing-checked": "I could not check anything on your list",
        # S225+ — THE HALF-CHECKED FLOOR. More than half of this group could not
        # be checked, so it is too thin to read HIGH; it is not held against the
        # build (nothing here didn't work), it simply is not vouched for.
        "too-little-checked": ("too little was checked to grade — only %d of %d "
                               "rows got a real outcome, and a grade needs more "
                               "than half; nothing here is a fault in your build"
                               % (grade["checked"], grade["total"])),
        # THE 80% COVERAGE FLOOR (captain's ruling, 2026-09-24). Everything
        # checked worked; the grade is held back one notch only because too
        # much went unchecked to certify — the floor and the count are named.
        "held-back-coverage": ("everything I could check worked, but I checked "
                               "only %d of %d — below the %d%% a HIGH needs — so "
                               "the grade is held back to MEDIUM; %d of %d went "
                               "unchecked, and that is a gap in my checking, not "
                               "a fault in your build"
                               % (grade["checked"], grade["total"],
                                  grade["coverageFloorPct"],
                                  grade["total"] - grade["checked"], grade["total"])),
        # S225 — MEDIUM now fires on a medium that DIDN'T WORK and nothing
        # else. A medium nobody could check no longer moves the grade, so this
        # sentence no longer offers it as a reason (it is still said, in the
        # couldn't-check sentence below, where it belongs).
        "medium-open": ("the point of the mission worked, but %s"
                        % ("something else you asked for did not work as asked"
                           if len(grade["mediumGap"]) == 1 else
                           "other things you asked for did not work as asked")),
        # D1: "and everything else you asked for" only when it is TRUE.
        #
        # S225 — AND NOW "WORKED" MEANS "WORKED WHERE I COULD LOOK". Until this
        # session an all-worked grade could not carry an unchecked row: a blind
        # high forced LOW and a blind medium forced MEDIUM, so these sentences
        # were safe. Change 03 removed both, and the FIRST thing that has to
        # follow is that this sentence stops claiming a build nobody finished
        # checking. The grade does not move for the blind spot; the words do.
        "all-worked": ("everything I could check worked, and I will not turn what "
                       "I could not check into a doubt about your build"
                       if (hi_blind or grade["mediumBlind"] or low_blind) else
                       # …and never "everything ELSE you asked for" while
                       # something on the drawing or the ticket contract is
                       # open: those are two of his three lists and this
                       # sentence does not read them (S225).
                       "everything a person can do with the build worked — the "
                       "drawing and your ticket contract are on their own lines "
                       "below"
                       if others_open else
                       "everything that is the point of the mission, and everything "
                       "else you asked for, worked"
                       if not grade["lowOpen"] else
                       "everything that is the point of the mission worked, and so "
                       "did every other requirement that is more than polish"
                       if any(e.get("impact") == "medium" for e in ledger) else
                       "everything that is the point of the mission worked"),
    }
    first = "%s because %s" % (score.upper(), rule_words[grade["rule"]])
    assumed = [e for e in ledger if e.get("impactAssumed")]
    if assumed:
        first += ("; no impact was given for %s, so I counted %s as the point of "
                  "the mission, the careful reading"
                  % (some(assumed, lambda e: e["id"]), "it" if len(assumed) == 1 else "them"))
    para = [first + "."]
    highs = grade["high"]
    if highs:
        point = ("The point of the mission is %s — %s — and %s."
                 % (n_things(len(highs)), some(highs, short),
                    ("it worked" if len(highs) == 1 else "all of them worked")
                    if not hi_gap and not hi_blind else
                    " and ".join(x for x in (
                        ("%d didn't work" % len(hi_gap)) if hi_gap else "",
                        ("%d couldn't be checked" % len(hi_blind)) if hi_blind else "")
                        if x)))
        para.append(point)
    elif ledger:
        para.append("Nothing on your list was marked as the point of the mission.")
    more_note = " — see the list"
    broke = []
    if hi_gap:
        broke.append("didn't work: %s" % some(hi_gap, fault_id, sep="; "))
    if grade["mediumGap"]:
        broke.append("Known issues shipping with it: %s" % some(grade["mediumGap"], fault_id, sep="; "))
    broke += smaller_items(low_gap, [], lambda rows: some(rows, short))
    if broke:
        s3 = "; ".join(broke)
        if any(len(r) > CAP for r in (hi_gap, grade["mediumGap"], low_gap)):
            s3 += more_note
        para.append(s3[:1].upper() + s3[1:] + ".")
    blind = hi_blind + grade["mediumBlind"]
    unseen = []
    if blind:
        unseen.append("I could not check %s — %s"
                      % (n_things(len(blind)), some(blind, short)))
    unseen += smaller_items([], low_blind, lambda rows: some(rows, short))
    if unseen:
        s4 = "; ".join(unseen)
        if len(blind) > CAP or len(low_blind) > CAP:
            s4 += more_note
        para.append(s4[:1].upper() + s4[1:] + ".")
    why_grade = " ".join(para)

    # --- BESIDE HIS GRADE, NEVER INSTEAD OF IT (the research's hybrid) -------
    #
    # S225 TURNED THIS ROUND. It used to say a risk-based reviewer might sign a
    # MEDIUM off because its only open items were ones nobody could check —
    # which was the reading the grade itself now takes, so the note had nothing
    # left to add. The reading that is NOT in the grade any more is the cautious
    # one: this grade was earned by what was checked, and here is what wasn't.
    # It sits beside the grade and moves nothing, exactly as before.
    alt_reading = ""
    blind_beside = hi_blind + grade["mediumBlind"] + low_blind
    if score != "low" and blind_beside:
        alt_reading = ("a cautious reviewer would want %s checked before this "
                       "ships: nobody could see %s (%s). That is a gap in my "
                       "checking, not a fault in the build"
                       % (n_things(len(blind_beside)),
                          "it" if len(blind_beside) == 1 else "them",
                          ids(blind_beside)))
    # POLISH PILES UP WHEREVER IT COMES FROM (S225). This never touched the
    # grade and still doesn't, so it is counted over the WHOLE ledger — a
    # ticket criterion that broke is a small thing that broke, and five of them
    # make a build feel unfinished whichever of his three lists named them.
    low_gaps = sum(1 for e in ledger
                   if e.get("impact") == "low" and e["status"] == "gap")
    polish_flag = ""
    if low_gaps >= POLISH_PILE:
        polish_flag = ("lots of small things — %d small things did not work, so it "
                       "may feel unfinished even though none of them moves the grade"
                       % low_gaps)

    # --- EVERY ROW CARRIES ITS REASON ----------------------------------------
    for e in ledger:
        finish_reason(e)

    # S217 — the picture sentence LEADS the derivation, so the card's one line
    # and the report's first line both open with it. The score is untouched:
    # a missing drawing is not a fault in the build.
    # W2: every sentence opens on a capital. The headline's lead is the SHORT
    # form (the board's own label); the full sentence is in the report.
    why = why[:1].upper() + why[1:]
    if picture_only:
        why = "%s %s" % (PICTURE_LEAD, why)

    # S224 item 2 — READ AFTER EVERY NUMBER IS ALREADY DECIDED, on purpose.
    # `score`, `met`, `gap`, `untested`, `why`, `why_grade` and the whole ledger
    # are final by this line. Nothing below can move them, and that is the whole
    # design: an unlisted finding is the captain's to weigh, not a criterion he
    # wrote. The only thing it may append to is `notes` (when a citation fails)
    # and the escalation list built just below.
    unlisted_rows, unlisted_lines = merge_unlisted(unlisted_path, notes)

    # …and, on the same terms, the faults the walk found that no row on his list
    # could have named. The look's own lines are read FIRST so a fact it already
    # put in front of him is never handed to him twice.
    _own = [str(e) for e in (doc.get("escalations") or []) if str(e).strip()]
    walked_lines = walked_escalations(observations, _own)

    # A row that rests on one moment of a walk that had several — the note only,
    # never the outcome. Read after every number is final, like everything else
    # below this line.
    notes.extend(moment_notes(ledger, readings))

    # ─── THE HEADLINE MAY NOT READ HIGH OVER A GRADED RAIL THAT SAW NOTHING ──
    # (captain's ruling, 2026-09-24, measured on lcars-20260924-009-72bf)
    #
    # THE MEASURED DEFECT. The person rail read HIGH (all-worked, 6/6) while the
    # drawing rail read `nothing-checked` — it had four items and checked NONE
    # of them (0 of 4) — and the headline STILL read HIGH. A confident grade
    # sitting on top of a graded sub-rail that admits it saw nothing is the
    # exact failure this round exists to close: "unchecked must pull the grade
    # down, but care more about … does it look correct". He named BOTH graded
    # rails as the things he cares about, so a graded rail that saw nothing may
    # not sit silently beneath a HIGH.
    #
    # THE NARROW RULE, AND ONLY IT. When the headline reads HIGH and ANOTHER
    # GRADED rail (today only the drawing) HAD items and checked none of them,
    # the headline is HELD BACK one notch to MEDIUM and names which rail could
    # not be checked. The rails are NOT averaged, the drawing does NOT become
    # the headline, and the coverage contract rail — `kind: "coverage"`, never
    # graded, so never carrying a `nothing-checked` rule — can NEVER fire this:
    # the captain does not want a thin contract dragging a good, good-looking
    # build down. A rail with NOTHING to check at all (`total == 0`, e.g. a
    # mission with no drawing) is "nothing to look at", not "looked at nothing",
    # and holds nothing back — the whole difference between the two.
    blind_rails = [
        k for k in GROUP_ORDER
        if k != HEADLINE_GROUP and groups[k].get("kind") == "graded"
        and groups[k].get("total", 0) > 0
        and groups[k].get("rule") == "nothing-checked"
    ]
    headline_held_by_blind_rail = False
    if score == "high" and blind_rails:
        score = "medium"
        headline_held_by_blind_rail = True
        which = "; ".join(
            'the "%s" rail checked none of its %d item%s'
            % (GROUP_QUESTION[k], groups[k]["total"],
               "" if groups[k]["total"] == 1 else "s")
            for k in blind_rails)
        hold = ("Held back to MEDIUM: %s, so this cannot read HIGH over a graded "
                "rail that saw nothing." % which)
        why = "%s %s" % (hold, why)
        meaning = ("%s Everything a person can do worked, but a graded rail was "
                   "never looked at, and a grade cannot sit on a rail that saw "
                   "nothing" % hold)
        why_grade = "%s %s" % (hold, why_grade)

    # ─── S240: THE ACTION, ABOVE THE GRADE ───────────────────────────────────
    # Derived off the SAME ledger and the SAME coverage numbers the grade came
    # from, by `derive_recommendation` — the weekend's § 4 policy, written down
    # once instead of applied by hand on every look. The grade is unchanged and
    # stays as `score`; this sits above it and is what a surface acts on.
    finding_by_id = {str(g.get("criterion") or ""): g for g in gaps
                     if str(g.get("criterion") or "")}
    advice = derive_recommendation(ledger, grade, finding_by_id, named)
    recommendation = advice["recommendation"]
    rec_why = advice["because"][0] if advice["because"] else ""

    # THE COVERAGE SENTENCE THE CAPTAIN NEVER GOT. `checked`, `total`,
    # `coveragePct` and `coverageFloorPct` have been computed since S226 and
    # written into `groups.person` — and never once rendered. The archive case is
    # 83% against a floor of 80 deciding HIGH while the report said "2 I couldn't
    # set up". Both numbers now go on line 2, with the RECORDED reason for every
    # row that was not reached (never the canned one).
    blind_rows = [e for e in by_group[GROUP_PERSON] if e["status"] == "untested"]
    def blind_reason(e):
        rec = unstop(" ".join(str(e.get("note") or "").split()))
        if not rec:
            rec = ("no cause was recorded, so it is read as ours"
                   if not e.get("causeRecorded") else
                   str(e.get("couldNotCheck") or "no reason recorded"))
        return "%s (%s)" % (named(e["id"]), clip(rec, 110))
    cover_bits = ["checked %d of %d (%d%%, floor %d%%)"
                  % (grade.get("checked", 0), grade.get("total", 0),
                     grade.get("coveragePct", 0), grade.get("coverageFloorPct", 0))]
    if blind_rows:
        cover_bits.append("%d unreachable — %s"
                          % (len(blind_rows),
                             "; ".join(blind_reason(e) for e in blind_rows[:4])))
    cover_line = "; ".join(cover_bits)

    out = {
        "score": score,
        # S240 — THE RECOMMENDATION, and the reasons behind it, as data. `score`
        # above is still the grade and still means what it meant; this is the
        # action. `blockers[].filedAs` is stamped on by whoever files the bug.
        "recommendation": recommendation,
        "because": advice["because"],
        # The one sentence a surface shows beside the action — the SAME first
        # line of `because`, frozen here so nobody has to index into an array
        # (and so a shell can read it with one key).
        "recommendationWhy": rec_why,
        "blockers": advice["blockers"],
        "followUps": advice["followUps"],
        "coverageLine": cover_line,
        "workerScore": worker_score,
        "scoreDisagreed": score != worker_score,
        "derivation": why,
        # The score word's own meaning, decided beside the score off the same
        # ledger, so a surface can never explain MEDIUM with something the
        # ledger does not support (S213 fix round 1, D4).
        "scoreMeaning": meaning,
        "counts": {"met": met, "gap": gap, "untested": untested,
                   "contradictions": len(contradicted)},
        # S216 — the table walked in words, and the point of the mission as
        # its own fact. `core` is "" only when no row was marked high at all.
        "whyThisGrade": why_grade,
        "core": core,
        # S225 — THE THREE QUESTIONS, KEPT APART. `score` above is the PERSON
        # group's grade and nothing else (the captain's ruling, 2026-09-22);
        # `scoreGroup` says so out loud so no reader has to assume. The drawing
        # carries its own grade here, and the ticket contract carries a coverage
        # count and NO grade at all — the absence of the key is the contract.
        "scoreGroup": HEADLINE_GROUP,
        "groups": groups,
        "criteria": ledger,
        "gaps": gaps,
        # The look's own list FIRST, then what the criteria-free pass found —
        # one channel, in the order they were produced. An unlisted finding
        # joins what the look put aside for him; it never displaces it.
        "escalations": _own + walked_lines + unlisted_lines,
        "alsoChecked": [str(e) for e in (doc.get("alsoChecked") or []) if str(e).strip()],
        "summary": summary,
    }
    if my_checking["total"]:
        out["myChecking"] = my_checking
    # S241 — THE LANDING LEDGER, an ADDITIVE key. Which cited pictures were not
    # of the screen they were cited for, and for each the step that took it and
    # the RECORDED reason it did not get there. A step named here was attempted
    # and did not reach: `reason` is the comparison that was actually made,
    # never a canned sentence.
    if landing_note:
        out["landing"] = {"note": landing_note, "railOn": False,
                          "refused": [], "notReached": []}
        notes.append(landing_note)
    if landing_refusals or landing_not_reached:
        out["landing"] = {
            "note": ("A picture that was taken somewhere else is not evidence of the "
                     "screen it was cited for. These are gaps in my checking, not "
                     "faults in your build."),
            "railOn": landing_on,
            "refused": landing_refusals,
            "notReached": landing_not_reached,
        }
    if impacts_note:
        out["impactsNote"] = impacts_note
    if mismatches:
        out["impactMismatches"] = mismatches
    if alt_reading:
        out["altReading"] = alt_reading
    if polish_flag:
        out["polishFlag"] = polish_flag
    # THE HELD-BACK HEADLINE, AS DATA (captain's ruling, 2026-09-24). When a
    # graded rail that saw nothing pulled the headline off HIGH, a surface reads
    # WHICH rail and how many items it never looked at from here — never back
    # out of the prose above. Emitted only when it fired.
    if score == "medium" and headline_held_by_blind_rail:
        out["heldBackByBlindRail"] = {
            "rails": [{"group": k, "question": GROUP_QUESTION[k],
                       "total": groups[k]["total"]} for k in blind_rails],
            "note": ("The headline is held back to MEDIUM because a graded rail "
                     "had items and checked none of them — a grade cannot sit on "
                     "a rail that saw nothing."),
        }
    if notes:
        out["ledgerNotes"] = notes
    # ─── S226: THE RECORDS THAT DISAGREED, AS DATA ───────────────────────────
    # Where two records of one look disagreed, the difference is surfaced here
    # by name — never resolved silently in the build's favour. `reconciled`
    # lists the walk-said-unreachable rows the probe overruled by reaching the
    # same screen; `passingOnLookAlone` names every worked row backed by
    # nothing but a screenshot. Both are the same facts a surface would
    # otherwise have to read back out of prose (S147/S156/S188/S212).
    if reconciled:
        out["reconciled"] = reconciled
    if passing_on_look_alone:
        out["passingOnLookAlone"] = passing_on_look_alone
    # ─── THE KIND-OF-QUESTION SPLIT, AS DATA (Captain, 2026-09-24) ────────────
    # How many of the checks were looks-questions and how many were works-
    # questions, and — the number the whole ruling turns on — how many of the
    # works-questions actually got an action rather than just a photo.
    # `worksOnLookAlone` names every works-question that passed on nothing but a
    # picture and was therefore NOT counted as worked. Always emitted so a
    # surface never has to recompute it or read it back out of prose.
    out["questionSplit"] = split
    if works_on_look_alone:
        out["worksOnLookAlone"] = works_on_look_alone
    # STRUCTURED AS WELL AS SAID (S224 item 2). The escalation line is the
    # captain's sentence; this is the same facts as data, so a surface never
    # has to read meaning back out of that prose — the mistake S147, S156, S188
    # and S212 each cost this project a round.
    if unlisted_rows:
        out["unlisted"] = unlisted_rows
    if picture_only:
        out["pictureNotDrawing"] = {"pictures": picture_names,
                                    "note": PICTURE_NOT_DRAWING,
                                    "fix": PICTURE_FIX}
    if observations and observations["observations"]:
        # CARRIED THROUGH, NOT RECOMPUTED. The observations were already final
        # when xo-observe.py wrote them; this file is the one place they get
        # rendered to the captain, never a second place they get decided.
        out["observations"] = observations["observations"]
        out["observationThresholds"] = observations["thresholds"]

    os.makedirs(os.path.dirname(os.path.abspath(opath)), exist_ok=True)
    with open(opath, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")

    # THE REPORT, RENDERED HERE AND NOWHERE ELSE. The living comment (S65, one
    # comment per key, edited in place) includes this fragment verbatim, so the
    # ledger the captain reads on the issue and the ledger on disk cannot drift
    # apart into two renderings of one fact. Shot NAMES, never images: GitHub has
    # no comment-image upload API and the PNGs stay on the laptop that took them
    # (ruling, ledgered), so the report names each shot and says what it showed.
    with open(os.path.join(os.path.dirname(os.path.abspath(opath)), "report.md"),
              "w", encoding="utf-8") as fh:
        w = fh.write
        # ─── LINE 1 IS THE ACTION; LINE 2 IS THE GRADE (S240) ────────────
        # The captain read a bare adjective and mapped it to an action himself,
        # every time. Line 1 is now the recommendation and the one sentence
        # behind it; line 2 is the grade it sits on, WITH the coverage numbers
        # that decided it. The two trailing spaces are a markdown hard break, so
        # the two facts stay two lines in the living comment as well as on disk.
        w("**Recommendation: %s** — %s  \n"
          % (RECOMMENDATION_WORD.get(recommendation, recommendation.upper()),
             rec_why or why))
        w("**How close this is to what you asked for: %s** — %s. %s\n\n"
          % (score.upper(), cover_line, why))
        # S216 — WHY THIS GRADE comes first after the score: the table walked
        # in words, then what the research reads beside it (never instead).
        w("**Why this grade.** %s\n\n" % why_grade)
        # ─── S225: THE THREE QUESTIONS, NEVER AVERAGED INTO ONE ──────────────
        # Directly under the grade, because the whole defect was one number
        # standing in for three different questions with three different
        # answers. The person line IS the grade above and says so; the drawing
        # line is never hidden, it simply does not set the headline; the
        # contract line is a coverage count and is not graded at all.
        def _tally(b):
            bits = []
            for key, said in (("worked", "worked"), ("didntWork", "didn't work"),
                              ("couldntSee", "I couldn't see"),
                              ("couldntSetUp", "I couldn't set up")):
                if b[key]:
                    bits.append("%d %s" % (b[key], said))
            return ", ".join(bits)
        shown = [k for k in GROUP_ORDER if groups[k]["total"]]
        if shown:
            w("**The three questions, kept apart.**\n\n")
            for k in shown:
                b = groups[k]
                if b["kind"] == "graded":
                    # HELD BACK FOR COVERAGE, SAID ON THE RAIL'S OWN LINE. So a
                    # graded rail below the headline (the drawing) carries the
                    # rule that held it back, the floor, and the count — never
                    # only in the headline, which reads a different rail.
                    held = ""
                    if b.get("rule") == "held-back-coverage":
                        held = (" Held back for coverage: only %d of %d checked, "
                                "below the %d%% a HIGH needs, so %d of %d went "
                                "unchecked."
                                % (b["worked"] + b["didntWork"], b["total"],
                                   b["coverageFloorPct"], b["untested"], b["total"]))
                    w("- **%s** — **%s**. %d on this list: %s.%s *%s*\n"
                      % (b["question"], b["grade"].upper(), b["total"],
                         _tally(b) or "nothing was settled either way",
                         held, b["aside"]))
                else:
                    # A ticket criterion SEEN TO FAIL is still a fault, and it
                    # is said here — it is simply not graded here (S225).
                    broke_n = ("" if not b["didntWork"] else
                               " %d of those answers was that it didn't work."
                               % b["didntWork"] if b["didntWork"] == 1 else
                               " %d of those answers were that it didn't work."
                               % b["didntWork"])
                    w("- **%s** — %d of %d %s an answer behind %s; %d %s "
                      "nothing.%s *%s*\n"
                      % (b["question"], b["covered"], b["total"],
                         "has" if b["covered"] == 1 else "have",
                         "it" if b["covered"] == 1 else "them",
                         b["uncovered"], "has" if b["uncovered"] == 1 else "have",
                         broke_n, b["aside"]))
            w("\n")
        # ─── SAY THE SPLIT OUT LOUD (Captain's ruling, 2026-09-24, #5) ────────
        # How many checks were looks-questions a picture can settle, how many
        # were works-questions only an action can, and — the number the ruling
        # turns on — how many works-questions actually got a press. A photo of a
        # button is not a check that the button does anything.
        if split["looks"] or split["works"]:
            _wq = split["works"]
            bit = ("**%d were works-questions** (only a press settles those); of "
                   "those, %d actually got an action, and %d had nothing but a "
                   "photo — those are marked *couldn't check*, not *worked*."
                   % (_wq, split["worksExercised"], split["worksPictureOnly"])) \
                if _wq else "none were works-questions"
            w("**How I checked, by the kind of question.** %d %s a looks-question "
              "(a picture settles those); %s\n\n"
              % (split["looks"], "was" if split["looks"] == 1 else "were", bit))
        if impacts_note:
            w("*%s*\n\n" % impacts_note)
        for m in mismatches:
            a, b = m["ids"]
            w("*%s (%s) and %s (%s) say the same thing but were given different "
              "importance (%s and %s). This does not change the grade — tell me "
              "which is right.*\n\n" % (named(a), a, named(b), b,
                                          m["impacts"][0], m["impacts"][1]))
        beside = [s for s in (alt_reading, polish_flag) if s]
        if beside:
            w("*Read another way (this does not change the grade):* %s.\n\n"
              % "; ".join(beside))
        w(summary + "\n\n")
        # POINT AT THE MEASURED FINDINGS FROM THE TOP (fix round 1, D5). The
        # score is the criteria's; these are measurements and they never move
        # it. That is the S210 contract and it stands — but a finding the
        # captain has to scroll past four sections to meet is a finding he
        # does not act on, so the count is said here, once, with its heading.
        _measured = [o for o in ((observations or {}).get("observations") or [])
                     if o.get("reportedUnder") == "measured"]
        _measured_n = len(_measured)
        # …and the paragraph above never stands alone claiming to be the whole
        # picture (fix round 3, F1). Same sentence the board renders.
        _caveat = summary_caveat(summary, _measured)
        if _caveat:
            w("*%s*\n\n" % _caveat)
        if _measured_n:
            w("**I also measured %d thing%s against your drawing and while walking "
              "the flow myself. They are not in the count above — measurements never "
              "move your score — but they are faults and they are listed below, under "
              "*What I measured on your drawing*.**\n\n"
              % (_measured_n, "" if _measured_n == 1 else "s"))
        if picture_only:
            w("**%s.** %s %s a picture, not a drawing, so nothing in this build "
              "was compared against a design. %s\n\n"
              % (PICTURE_NOT_DRAWING[:1].upper() + PICTURE_NOT_DRAWING[1:],
                 ", ".join("`%s`" % p for p in picture_names),
                 "is" if len(picture_names) == 1 else "are each",
                 PICTURE_FIX))
        if out["scoreDisagreed"]:
            w("> I first called this %s. The line above is worked out again from my own\n"
              "> notes below, and those notes win.\n\n" % worker_score.upper())
        # YOUR OWN TESTS, AND WHAT THEY DO NOT COVER (S211). The sentence comes
        # from the record xo-tests.py wrote at the moment it ran — the command,
        # the outcome and the duration are its facts, not this file's reading of
        # its output. The second sentence is the LIMIT the captain asked for in
        # his own words: "I ran your tests and they pass, but they don't cover
        # X, so I can't tell you about that."
        if tests:
            w(tests_sentence(tests, tests_proved_a_red) + "\n\n")
            if tests.get("outcome") == "passed" and untested:
                w("They pass, but they don't cover everything on your list — there %s "
                  "still %d thing%s below, under *What I could not check*, that I can't "
                  "tell you about from them.\n\n"
                  % ("is" if untested == 1 else "are", untested,
                     "" if untested == 1 else "s"))
        # THE TABLE STAYS MACHINE-READABLE: one row per criterion, the ids and
        # the MET/GAP/UNTESTED marks exactly as they were. Only the header words
        # the captain reads are written to him. (Five columns since S211 — the
        # fifth says where each judgement came from.)
        # HOW I KNOW is S211's column: a picture, a measured box, or your own
        # tests. The captain must never have to guess which decided a line.
        w("| What you asked for | | Verdict | How I know | What I saw |\n"
          "|---|---|---|---|---|\n")
        mark = {"met": "MET", "gap": "GAP", "untested": "UNTESTED"}
        for e in ledger:
            # WHICH TEST SETTLED IT (fix round 1, D5). A met on the project's
            # own suite said "Your own tests cover this and they pass" and
            # never which line — while a GAP quoted its line and the guard had
            # already checked that same quote against the recorded output. The
            # quote was on the record and only the failures got to show it.
            # Same contract sentence as D3: he should not have to take "your
            # tests" on trust when the line is right there.
            what_i_saw = ((e.get("shot", "") + " — ") if e.get("shot") else "") \
                + clip(e["note"], 160)
            if e.get("evidence") == "tests" and e.get("testQuote"):
                what_i_saw = what_i_saw.rstrip() + (" " if what_i_saw.strip() else "") + \
                    'Your tests said: "%s"' % clip(e["testQuote"], 120)
            w("| %s | %s | %s | %s | %s |\n" % (
                e["id"] + (" (PRD)" if e["primary"] else ""),
                clip(e["text"], 120).replace("|", "\\|"),
                mark[e["status"]],
                EVIDENCE_WORD.get(e.get("evidence") or "none", "—"),
                what_i_saw.replace("|", "\\|")))
        # ONE SENTENCE, BOTH HALVES OF THE MISMATCH. The captain asked to see
        # what his first officer sees, from where he stands: *"phrases like
        # 'wrong color or this doesn't match the mock where it was in the lower
        # right, but it's lower left here'"*. So the drawing's expectation and
        # the build's reality sit in the SAME sentence, in that order, and the
        # machine id goes in the brackets at the end with the shot.
        real = [g for g in gaps if g["kind"] == "contradiction"]
        if real:
            w("\n### Where the build does not match what you asked for\n\n")
            for g in real:
                if g.get("evidence") == "tests":
                    # NOT "your drawing has…": there was nothing to draw. This
                    # one came out of the suite, so it is said that way, and the
                    # line the suite printed is quoted for the captain to read.
                    w("- **%s** — you asked for %s; the build gives %s. Your tests say "
                      "so: \"%s\" *(%s)*\n" % (
                          g.get("title", "?"), unstop(g.get("expected", "?")),
                          unstop(g.get("saw", "?")),
                          clip(str(g.get("testQuote") or ""), 200), cite(g)))
                else:
                    w("- **%s** — your drawing has %s; the build has %s. *(%s)*\n" % (
                        g.get("title", "?"), unstop(g.get("expected", "?")),
                        unstop(g.get("saw", "?")), cite(g)))
        interp = [g for g in gaps if g["kind"] == "interpretation"]
        if interp:
            w("\n### Calls the build made that your drawing does not cover\n\n")
            w("I am reading these as yours, not as faults.\n\n")
            for g in interp:
                w("- **%s** — the build has %s; your drawing does not say, so I am "
                  "treating it as your call. *(%s)*\n" % (
                      g.get("title", "?"), unstop(g.get("saw", "?")), cite(g)))
        # ─── CHOICES I MADE FOR YOU — two producers, one section (2026-09-25) ─
        # The defect this closes: LCARS noticed a choice was the captain's to
        # make, made it anyway, and said nothing. The ruling is "decide, but
        # tell me it decided" — so it keeps deciding and the report NAMES every
        # call made on his behalf and the alternatives it passed over.
        #   Producer 1 — Research's recorded PRODUCT decisions (decisions.json),
        #     read as structured fields (question / options / chose / why /
        #     where), never inferred from prose.
        #   Producer 2 — the scoring system's OWN call: a criterion that arrived
        #     with no importance, which take_impact() stamped high + assumed
        #     (impactAssumed). That is the machine deciding for him too, and it
        #     had no home of its own — it lived only inside grade prose above.
        # ABSENT, not present-and-empty, when there were none: an empty list
        # reads as "nothing was decided", a different fact from "these were".
        chosen = []
        if isinstance(made_decisions, dict):
            for d in made_decisions.get("decisions") or []:
                if isinstance(d, dict) and \
                   " ".join(str(d.get("question") or "").split()) and \
                   " ".join(str(d.get("chose") or "").split()):
                    chosen.append(d)
        assumed_calls = [e for e in ledger if e.get("impactAssumed")]
        if chosen or assumed_calls:
            w("\n### Choices I made for you\n\n")
            w("You did not settle these, so I did — to keep the build moving. "
              "Here is each call, and what I passed over.\n\n")
            for d in chosen:
                q = clip(str(d.get("question") or ""), 200)
                pick = unstop(" ".join(str(d.get("chose") or "").split()))
                picknorm = " ".join(str(d.get("chose") or "").split())
                alts = []
                for o in (d.get("options") or []):
                    on = " ".join(str(o).split())
                    if on and on != picknorm and on not in alts:
                        alts.append(on)
                # `dwhy`, NEVER `why`. That name holds the GRADE DERIVATION,
                # frozen above into out["derivation"] and printed on the WHY
                # wire line far below — which xo.sh reads into the board card's
                # one line. A loop here that re-bound `why` put this decision's
                # own reason on the card in place of the grade.
                dwhy = unstop(" ".join(str(d.get("why") or "").split()))
                where = " ".join(str(d.get("where") or "").split())
                line = "- **%s** — I went with %s" % (q, pick)
                if alts:
                    line += ", over " + ", ".join(alts)
                line += "."
                if dwhy:
                    line += " %s." % dwhy
                if where:
                    line += " You will see it in %s." % where
                w(line + "\n")
            for e in assumed_calls:
                what = clip(e.get("text") or "", 120) or e["id"]
                w("- **how much %s counts** — you gave it no importance, so I "
                  "counted it as the point of the mission, the careful reading. "
                  "*(%s)*\n" % (what, e["id"]))
        blind = [e for e in ledger if e["status"] == "untested"]
        if blind or unbuilt_fix:
            w("\n### What I could not check\n\n")
            for e in blind:
                w("- %s — %s. *(%s)*\n" % (
                    clip(e["text"], 120) or "this one",
                    unstop(e["note"] or "I could not check this"), e["id"]))
            # THE STEPS THAT WERE NEVER BUILT (S239 fix round 3). Not a failure
            # and never reported as one: the record did not say the one thing
            # the step needed, so nothing was guessed and nothing was run. The
            # reason names the edit that recovers it.
            if unbuilt_fix:
                w("\n**%d of my live-check items I could not BUILD from your "
                  "record at all — one line in your record recovers each of "
                  "them:**\n\n" % len(unbuilt_fix))
                # `wline`, NEVER `why` — same reason as the decisions loop above.
                for items, wline in unbuilt_lines(unbuilt_fix):
                    w("- **%s** — %s\n" % (items, wline))
            if unbuilt_design:
                w("\n*%d further live-check item(s) want a fact your record "
                  "cannot supply — a second actor, an owner-not-login pair, a "
                  "non-default host, an artifact nobody named. Those go unbuilt "
                  "on every healthy mission; there is nothing for you to fix "
                  "there.*\n" % len(unbuilt_design))
        # S216 — THE REASONING, ITEM BY ITEM. Its own section, not a table
        # column: the table above stays exactly as machine-readable as it was.
        if ledger:
            w("\n### My reasoning, item by item\n\n")
            for e in ledger:
                w("- %s *(%s)* — %s\n" % (clip(e["text"], 120) or e["id"], e["id"],
                                          e["reason"]))
        # OBSERVATIONS — THEIR OWN SECTION, NEVER THE SCORE (S210). These do not
        # come from the drawing or the PRD; they are things a person would just
        # SEE — two controls touching, a row out of line, text spilling past its
        # own box — measured from the same boxes the ledger above was judged
        # from. They never moved the score you read at the top of this report.
        # WHAT I MEASURED, AND WHAT I SAW WALKING IT (fix round 1, D5). These
        # are the part-by-part measurements (S220 B) and the journey's own
        # carry and gate checks (S220 F). They ARE about your drawing and your
        # flow, so they do not belong under "not on your list" — and until
        # this section existed they reached the captain nowhere at all while
        # the benchmark was scoring them as found. Every one of them is a
        # finding he can act on, in its own right, in plain words.
        measured = [o for o in ((observations or {}).get("observations") or [])
                    if o.get("reportedUnder") == "measured"]
        loose = [o for o in ((observations or {}).get("observations") or [])
                 if o.get("reportedUnder") != "measured"]
        if measured:
            w("\n### What I measured on your drawing, and what I saw walking it\n\n")
            # WHICH EYE SAW THEM (fix round 3, F1). This read as Number One's
            # own eye, which is the one thing the record does not say: every
            # line here came off a measurement.
            w("These came from measurements, not from my own eye. Every part "
              "of your drawing was held against the part the build renders, "
              "and the flow was walked a step at a time. Anything here that I "
              "do not also write up in your list above is something I did not "
              "notice while looking. They are findings either way — act on "
              "them.\n\n")
            for o in measured:
                where = str(o.get("screen") or "")
                w("- %s%s\n" % (o.get("message", ""),
                                ("  *(on %s)*" % where) if where and where not in str(o.get("message") or "") else ""))
        if loose:
            w("\n### Things I noticed that are not on your list\n\n")
            w("None of these come from your drawing or your PRD — they never "
              "change the score above. I am just telling you what I saw.\n\n")
            # If the list was capped, say so BEFORE the list — otherwise three
            # bullets read as "three things", which is the lie the cap could
            # tell if it kept quiet about itself.
            for n in observations.get("notes") or []:
                w("%s\n\n" % n)
            for o in loose:
                w("- %s\n" % o.get("message", ""))
            hidden = hidden_sentence(observations.get("unseenCount"))
            if hidden:
                w("\n%s\n" % hidden)
            th = observations["thresholds"] or {}
            w("\n*The numbers I used: I flag two controls less than %s px "
              "apart, a row whose left edge is more than %s px off from the "
              "others, and text that needs more than %s px of room it does "
              "not have. Tell me if these are wrong for your eye — that "
              "calibration is yours to make.*\n" % (
                  th.get("gapPx", "?"), th.get("misalignPx", "?"),
                  th.get("overflowPx", "?")))
        # HOW I MOVED (S220 part F) — read off the record of what was
        # executed, so a report can never claim a walk that did not happen.
        if walk and walk["steps"]:
            w("\n### How I walked it\n\n")
            w("%s\n\n" % walk_sentence(walk))
            for st in walk["steps"]:
                if st.get("status") == "unreachable":
                    w("- **couldn't check (unreachable)** — %s: %s\n"
                      % (st.get("name") or st.get("key"),
                         st.get("why") or "the control it names was not on the screen"))
                elif st.get("status") == "no-change":
                    w("- **couldn't check (nothing changed)** — %s: %s\n"
                      % (st.get("name") or st.get("key"),
                         st.get("why") or "the screen was the same before and after"))
                elif st.get("status") == "refused":
                    w("- **it refused** — %s\n" % (st.get("name") or st.get("key")))
                elif st.get("do") == "type-all":
                    # D6: say how much of the form was actually filled. "I
                    # filled the form" over 2 of 19 boxes is the claim that
                    # made the gate's filled phase meaningless.
                    w("- %s — I filled %s of %s field(s)%s\n"
                      % (st.get("name") or st.get("key"), st.get("filled"),
                         st.get("fieldsOnScreen"),
                         ("; I could not fill %s" % ", ".join(st.get("couldNotFill") or [])[:160])
                         if st.get("couldNotFill") else ""))
                else:
                    w("- %s%s\n" % (st.get("name") or st.get("key"),
                                     "" if st.get("changed") else " — and nothing on the screen changed"))
        # WHAT I COULD NOT SEE FOR WANT OF DATA (S220 part E). One plain
        # sentence, and only when nothing was declared — a seed that ran is
        # not worth a paragraph, and a missing one is never the build's fault.
        if isinstance(seed, dict) and not seed.get("declared"):
            blind_screens = []
            for e in ledger:
                if e["status"] != "untested":
                    continue
                row = contract_by_id.get(e["id"]) or {}
                where = str(row.get("drawnAt") or row.get("drawnPart") or "")
                where = where.split(",")[0].strip()
                if where and where not in blind_screens:
                    blind_screens.append(where)
            if blind_screens:
                w("\n**Nothing in this repo declares sample data for a look, so the "
                  "screens that only appear once there is data in them I could not "
                  "see: %s.** That is not a fault in your build — it is a gap in "
                  "what I was given.\n" % ", ".join(blind_screens[:5]))
        if out["alsoChecked"]:
            w("\n**I also looked at:** " + "; ".join(out["alsoChecked"]) + "\n")
        if out["escalations"]:
            w("\n**These are yours to decide:** " + "; ".join(out["escalations"]) + "\n")
        if notes:
            w("\n<details><summary>How I put this together</summary>\n\n")
            for n in notes:
                w("- %s\n" % n)
            w("\n</details>\n")

    print("SCORE\t" + score)
    # S240 — the action on the wire, so `xo.sh` mirrors what was DECIDED and
    # never reads it back out of the report's prose.
    print("RECOMMENDATION\t" + recommendation)
    print("RECOMMENDATION_WHY\t" + (rec_why or why).replace("\n", " "))
    print("WORKER_SCORE\t" + worker_score)
    print("DISAGREED\t" + ("yes" if score != worker_score else "no"))
    print("WHY\t" + why)
    print("MEANING\t" + meaning.replace("\n", " "))
    print("GRADE_WHY\t" + why_grade.replace("\n", " "))
    print("CORE\t" + core)
    # S225 — THE THREE GROUPS ON THE WIRE, AS DATA. Same discipline as every
    # other record here: the shell journals what was decided, and never reads a
    # meaning back out of the prose above it.
    print("SCORE_GROUP\t" + HEADLINE_GROUP)
    for _k in GROUP_ORDER:
        _b = groups[_k]
        print("GROUP\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d"
              % (_k, _b["kind"], _b.get("grade") or "-", _b["total"], _b["worked"],
                 _b["didntWork"], _b["couldntSee"], _b["couldntSetUp"]))
    for cid, was, said_now in impacts_kept:
        print("IMPACT_KEPT\t%s\t%s\t%s" % (cid, was, said_now))
    for cid, was, q in demoted:
        print("TEST_DEMOTED\t%s\t%s\t%s" % (cid, was, " ".join(q.split())))
    for m in mismatches:
        print("IMPACT_MISMATCH\t%s\t%s\t%s\t%s" % tuple(m["ids"] + m["impacts"]))
    print("COUNTS\t%d\t%d\t%d\t%d" % (met, gap, untested, len(contradicted)))
    # S225 — HOW MUCH IS STILL OPEN ANYWHERE, as one number. The headline reads
    # ONE of the captain's three lists now, so "the grade is HIGH" no longer
    # implies "there is nothing left on any list". Anything downstream that used
    # to infer that from the score word has to read this instead of guessing.
    print("OPEN\t%d" % (gap + untested))
    print("SUMMARY\t" + summary.replace("\n", " "))
    if observations is not None:
        print("OBSERVATIONS\t%d" % len(observations["observations"]))
    if walk:
        m = walk["moves"]
        print("WALK\t%d\t%d\t%d\t%d" % (int(m.get("clicks") or 0),
                                          int(m.get("typings") or 0),
                                          int(m.get("keypresses") or 0),
                                          int(m.get("addressJumps") or 0)))
    # WHAT IS HIS TO DECIDE, ON THE WIRE (S222 fix round 1). `escalations` is
    # what the look flagged for the captain himself — something it saw, and
    # believes matters, that no acceptance criterion names. It reached
    # `report.md` and stopped there: on 2026-09-20 Number One described the
    # August→September month jump exactly, called it "worth the captain's eye",
    # and it appeared in neither the console nor `lcars xo report`. So the one
    # thing it flagged for him was the one thing he would never see.
    #
    # READ AS DATA, NEVER PARSED OUT OF PROSE. This is the list the look wrote
    # into its verdict, carried word for word onto the same tab-separated wire
    # NOTE already travels on, so xo.sh can journal it the way it journals
    # every other finding. No line at all when there is nothing to escalate.
    for e in out["escalations"]:
        print("ESCALATION\t" + e.replace("\n", " "))
    for n in notes:
        print("NOTE\t" + n.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
