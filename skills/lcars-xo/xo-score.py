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
    SCORE" below. It superseded S203's contradiction-driven table.)
    nothing on the list, or nothing checked         → LOW
    a HIGH-impact item didn't work / couldn't check → LOW     core broken/unverified
    every high worked; a MEDIUM didn't / couldn't   → MEDIUM  go with known issues
    every high and medium worked                    → HIGH    (low never moves it)

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
"""
import json
import os
import re
import sys
import time

VALID_SCORES = ("high", "medium", "low")
VALID_STATUS = ("met", "gap", "untested")
# WHERE A JUDGEMENT CAME FROM. The captain must never have to guess which of
# these decided a line (S211): a picture of the running app, a box measured off
# that page, or his project's own tests. `none` is the honest fourth — nothing
# settled it.
VALID_EVIDENCE = ("picture", "measurement", "tests")
EVIDENCE_WORD = {"picture": "a picture", "measurement": "a measured box",
                 "tests": "your tests", "none": "—"}

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

# A PICTURE IS NOT A DRAWING (S217). S214/S215 measured a mission whose only
# design was a PNG: no drawing, no place names, no `drawnAt` — so the guard
# above had nothing to overrule, verify_unfenced_note never fired, and the
# comparison silently did not run. Filing cannot refuse it, because nothing
# records whether a picture was meant as THE design or as context (see
# xo-criteria.py `pictures`). So it is SAID, here, as a fact that holds either
# way, at the head of the one line the card shows. Byte-identical everywhere.
PICTURE_NOT_DRAWING = ("your attachment is a picture, so I could not check the "
                       "build against a drawing")

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
    return {
        "observations": [o for o in obs if isinstance(o, dict) and o.get("message")],
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
    hay = norm_for_match(tests.get("outputTail"))
    if q not in hay:
        cut = ("  (I only kept the last %s bytes of it)" % tests.get("tailCapBytes")
               if tests.get("truncated") else "")
        return False, ("I could not find that line in your test output, so I am not "
                       "going to say your tests proved it%s" % cut)
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
OUTCOME_WORD = {"met": "worked", "gap": "didn't", "untested": "couldn't check"}
POLISH_PILE = 5


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
    """His table, over the finished ledger. Pure: reads status + impact only."""
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
    if not ledger:
        g.update(score="low", rule="nothing-listed")
    elif g["highGap"]:
        g.update(score="low", rule="high-broken")
    elif not checked:
        # Said as what it is — nothing at all — rather than as "the core".
        g.update(score="low", rule="nothing-checked")
    elif g["highBlind"]:
        g.update(score="low", rule="high-unchecked")
    elif g["mediumGap"] or g["mediumBlind"]:
        g.update(score="medium", rule="medium-open")
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
    return g


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


def short_name(text, limit=60):
    t = re.sub(r"\s*\(\s*`[^`]*`\s*\)", "", str(text or ""))

    def code(m):
        c = m.group(1).strip()
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
        # Too long: first drop call arguments and worded asides — "(current
        # === max)", "(not app.renderer.resize directly)" — but keep a bare
        # value like "(8,8)", which is the requirement.
        t = re.sub(r"(?<=\w)\([^()]*\)", "", t)
        t = re.sub(r"\s+\([^()]*[A-Za-z][^()]*\)", "", t)
        t = " ".join(t.split()).rstrip(STRIP_TAIL)
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
def evidence_said(rows):
    pics = sum(1 for e in rows if e.get("evidence") in ("picture", "measurement"))
    tests = sum(1 for e in rows if e.get("evidence") == "tests")
    if pics and tests:
        return ("I have a picture of %d and your own tests show the other %d"
                % (pics, tests))
    if tests:
        return "your own tests show each one"
    return "I have a picture of each one"


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
        impact = "Impact %s%s because %s" % (e["impact"], tag, unstop(e["impactWhy"]))
    else:
        impact = "Impact %s%s" % (e["impact"], tag)
    if rated != e["status"]:
        told = unstop(e.get("note") or "") or "I could not check this"
        e["reason"] = "%s. %s. Outcome: %s." % (impact, told[:1].upper() + told[1:], word)
        return
    if not said or _plain(said) == _plain(e.get("text")):
        e["reason"] = ("No reason was given for this one — all I have is the outcome: "
                       "%s. %s." % (word, impact))
        return
    if recorded:
        # The look's own "Impact <x> because …" sentence gives way to the one
        # on the record; what it tried and saw is kept as written.
        said = "%s. %s" % (impact, re.sub(r"^Impact\s+\w+\b[^.]*\.\s*", "", said))
    e["reason"] = said


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: xo-score.py <verdict> <criteria> <out> [<observations>] [<tests>]\n")
        return 2
    vpath, cpath, opath = sys.argv[1], sys.argv[2], sys.argv[3]
    obs_path = sys.argv[4] if len(sys.argv) > 4 else ""
    tests_path = sys.argv[5] if len(sys.argv) > 5 else ""
    impacts_path = sys.argv[6] if len(sys.argv) > 6 else ""
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
            g_ev = "picture" if shots else ""
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
                    status = "untested"
                    note = why
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
        if quote and entry["evidence"] == "tests":
            entry["testQuote"] = quote
        take_impact(entry, c)
        entry["_ratedStatus"] = rated_status
        entry["_reason"] = str(c.get("reason") or "")
        if status == "untested" and rated_status == "untested":
            why_not = str(c.get("couldNotCheck") or "").strip().lower()
            if why_not in COULD_NOT_CHECK:
                entry["couldNotCheck"] = why_not
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
            entry.pop("shot", None)
            entry.pop("testQuote", None)

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
    def named(cid):
        for g in gaps:
            if str(g.get("criterion") or "") == cid and str(g.get("title") or "").strip():
                return short_name(g["title"], 90)
        row = contract_by_id.get(cid) or {}
        return short_name(row.get("text")) or cid

    # WHAT WENT WRONG, NOT WHAT WAS ASKED (D3). "Known issues shipping with it:
    # the bar is red" reads as if the bar is red. A known issue names its fault:
    # what was expected against what was seen, off the finding the look
    # recorded — or the row's own observation — and when there is neither, it
    # says it didn't work and where to look.
    def fault(e):
        nm = named(e["id"])
        if e["status"] == "untested":
            return "%s — I could not check it" % nm
        for g in gaps:
            if str(g.get("criterion") or "") != e["id"]:
                continue
            exp, saw = unstop(str(g.get("expected") or "")), unstop(str(g.get("saw") or ""))
            if exp.strip() and saw.strip():
                return "%s — you asked for %s; the build gives %s" % (nm, exp, saw)
        obs = unstop(" ".join(str(e.get("note") or "").split()))
        if obs and _plain(obs) != _plain(e.get("text")) \
                and _plain(obs) != _plain((contract_by_id.get(e["id"]) or {}).get("text")):
            return "%s — didn't work: %s" % (nm, clip(obs, 140))
        return "%s — didn't work (see the row)" % nm

    def faults(rows):
        return "; ".join("%s (%s)" % (fault(e), e["id"]) for e in rows)

    def names_ids(rows):
        return "; ".join("%s (%s)" % (named(e["id"]), e["id"]) for e in rows)

    def name_list(ids):
        names = [named(c) for c in ids]
        if len(names) < 2:
            return "".join(names)
        return ", ".join(names[:-1]) + " and " + names[-1]

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
    grade = derive_grade(ledger)
    score, core = grade["score"], grade["core"]

    def items(rows):
        return "; ".join(named(e["id"]) for e in rows)

    def ids(rows):
        return ", ".join(e["id"] for e in rows)

    hi_gap, hi_blind = grade["highGap"], grade["highBlind"]
    med_open = grade["mediumGap"] + grade["mediumBlind"]
    low_gap = [e for e in grade["lowOpen"] if e["status"] == "gap"]
    low_blind = [e for e in grade["lowOpen"] if e["status"] == "untested"]
    if grade["rule"] == "nothing-listed":
        why = ("there was nothing on your list to check, so nothing here is "
               "vouched for.")
        meaning = ("There was nothing on your list to check, so nothing here is "
                   "vouched for — this is not a clean bill of health")
    elif grade["rule"] == "high-broken":
        why = ("the point of the mission does not work — %s (%s). What you set "
               "out to get is not there yet."
               % (name_list([e["id"] for e in hi_gap]), ids(hi_gap)))
        meaning = ("What you set out to get is not in the build — look for "
                   "yourself before this goes anywhere")
    elif grade["rule"] == "high-unchecked":
        why = ("I could not check the point of the mission — %s (%s) — so nothing "
               "here says it works."
               % (name_list([e["id"] for e in hi_blind]), ids(hi_blind)))
        meaning = ("I could not check the point of the mission, so it is not "
                   "vouched for — look for yourself")
    elif grade["rule"] == "nothing-checked":
        why = ("I could not check anything on your list, so nothing here is "
               "vouched for.")
        meaning = ("I could not check anything on your list, so nothing here is "
                   "vouched for — this is not a clean bill of health")
    elif score == "medium":
        # What did not work and what could not be checked are said apart, so a
        # MEDIUM that rests on a blind spot never reads as a clean bill.
        mg, mb = grade["mediumGap"], grade["mediumBlind"]
        bits = []
        if mg:
            bits.append("go with %s known issue%s — %s"
                        % ("this" if len(mg) == 1 else "these",
                           "" if len(mg) == 1 else "s", faults(mg)))
        if mb:
            bits.append("I could not check %s (%s)%s"
                        % (name_list([e["id"] for e in mb]), ids(mb),
                           "" if mg else ", so %s as a known issue%s"
                           % ("it ships" if len(mb) == 1 else "they ship",
                              "" if len(mb) == 1 else "s")))
        why = "the point of the mission works; %s." % "; and ".join(bits)
        said = []
        if mg:
            said.append("%d known issue%s that didn't work as asked"
                        % (len(mg), "" if len(mg) == 1 else "s"))
        if mb:
            said.append("%d item%s I could not check" % (len(mb), "" if len(mb) == 1 else "s"))
        meaning = ("The point of the mission works; it would ship with %s"
                   % " and ".join(said))
    elif grade["lowOpen"]:
        # D1/D2: didn't-work and couldn't-check are said apart, with counts.
        small = smaller_items(low_gap, low_blind, None)
        n = len(grade["lowOpen"])
        tail = ", and %s the grade" % ("it doesn't change" if n == 1 else "they don't change")
        why = ("everything that matters on your list worked; %s%s."
               % (" and ".join(small), tail))
        meaning = ("Everything that matters worked; %s%s — ship as is"
                   % (" and ".join(small), tail))
    else:
        # D7: say what the grade actually rested on — pictures, your tests, or
        # both — counted off the rows' recorded evidence kind.
        seen = evidence_said([e for e in ledger if e["status"] == "met"])
        why = "everything you asked for is in the build, and %s." % seen
        meaning = "Everything you asked for worked — %s — ship as is" % seen

    # --- WHY THIS GRADE: the table walked in words (S216) --------------------
    rule_words = {
        "nothing-listed": "there was nothing on your list to check",
        "high-broken": "something that is the point of the mission did not work",
        "high-unchecked": ("I could not check the point of the mission, and I will "
                           "not call a build good on the strength of what I could "
                           "not see"),
        "nothing-checked": "I could not check anything on your list",
        "medium-open": ("every part that is the point of the mission worked, but "
                        "%s — go with the named known issue%s"
                        % ("something else you asked for did not work as asked"
                           if not grade["mediumBlind"] else
                           "something else you asked for could not be checked"
                           if not grade["mediumGap"] else
                           "other things you asked for did not work as asked or "
                           "could not be checked",
                           "" if len(med_open) == 1 else "s")),
        # D1: "and everything else you asked for" only when it is TRUE.
        "all-worked": ("everything that is the point of the mission, and everything "
                       "else you asked for, worked"
                       if not grade["lowOpen"] else
                       "everything that is the point of the mission worked, and so "
                       "did every other requirement that is more than polish"
                       if any(e.get("impact") == "medium" for e in ledger) else
                       "everything that is the point of the mission worked"),
    }
    para = ["%s because %s." % (score.upper(), rule_words[grade["rule"]])]
    highs = grade["high"]
    if highs:
        point = "The point of the mission: %s." % items(highs)
        if not hi_gap and not hi_blind:
            point += " All of it worked."
        else:
            bits = []
            if hi_gap:
                bits.append("%s didn't work" % ", ".join(e["id"] for e in hi_gap))
            if hi_blind:
                bits.append("%s couldn't be checked" % ", ".join(e["id"] for e in hi_blind))
            point += " " + " and ".join(bits) + "."
        para.append(point)
    elif ledger:
        para.append("Nothing on your list was marked as the point of the mission.")
    if grade["mediumGap"]:
        para.append("Known issues shipping with it: %s." % faults(grade["mediumGap"]))
    if grade["mediumBlind"]:
        para.append("Also shipping unchecked — I could not check %s."
                    % names_ids(grade["mediumBlind"]))
    for bit in smaller_items(low_gap, low_blind, names_ids):
        para.append(bit[:1].upper() + bit[1:] + ".")
    assumed = [e for e in ledger if e.get("impactAssumed")]
    if assumed:
        para.append("No impact was given for %s, so I counted %s as the point of "
                    "the mission — the careful reading."
                    % (ids(assumed), "it" if len(assumed) == 1 else "them"))
    why_grade = " ".join(para)

    # --- BESIDE HIS GRADE, NEVER INSTEAD OF IT (the research's hybrid) -------
    alt_reading = ""
    if score == "medium" and not grade["mediumGap"] and grade["mediumBlind"]:
        blind = grade["mediumBlind"]
        alt_reading = ("a risk-based reviewer might sign this off: the only open "
                       "item%s %s nobody could check (%s), not one that was seen "
                       "to fail" % ("" if len(blind) == 1 else "s",
                                    "is one" if len(blind) == 1 else "are ones",
                                    ids(blind)))
    low_gaps = sum(1 for e in grade["lowOpen"] if e["status"] == "gap")
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
    picture_names = [str(p) for p in (contract.get("pictures") or [])
                     if str(p).strip()] if isinstance(contract, dict) else []
    picture_only = bool(picture_names) and not has_drawing
    if picture_only:
        why = "%s. %s" % (PICTURE_NOT_DRAWING, why[:1].upper() + why[1:])

    out = {
        "score": score,
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
        "criteria": ledger,
        "gaps": gaps,
        "escalations": [str(e) for e in (doc.get("escalations") or []) if str(e).strip()],
        "alsoChecked": [str(e) for e in (doc.get("alsoChecked") or []) if str(e).strip()],
        "summary": summary,
    }
    if impacts_note:
        out["impactsNote"] = impacts_note
    if mismatches:
        out["impactMismatches"] = mismatches
    if alt_reading:
        out["altReading"] = alt_reading
    if polish_flag:
        out["polishFlag"] = polish_flag
    if notes:
        out["ledgerNotes"] = notes
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
        w("**How close this is to what you asked for: %s** — %s\n\n" % (score.upper(), why))
        # S216 — WHY THIS GRADE comes first after the score: the table walked
        # in words, then what the research reads beside it (never instead).
        w("**Why this grade.** %s\n\n" % why_grade)
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
        blind = [e for e in ledger if e["status"] == "untested"]
        if blind:
            w("\n### What I could not check\n\n")
            for e in blind:
                w("- %s — %s. *(%s)*\n" % (
                    clip(e["text"], 120) or "this one",
                    unstop(e["note"] or "I could not check this"), e["id"]))
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
        if observations and observations["observations"]:
            w("\n### Things I noticed that are not on your list\n\n")
            w("None of these come from your drawing or your PRD — they never "
              "change the score above. I am just telling you what I saw.\n\n")
            # If the list was capped, say so BEFORE the list — otherwise three
            # bullets read as "three things", which is the lie the cap could
            # tell if it kept quiet about itself.
            for n in observations.get("notes") or []:
                w("%s\n\n" % n)
            for o in observations["observations"]:
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
    print("WORKER_SCORE\t" + worker_score)
    print("DISAGREED\t" + ("yes" if score != worker_score else "no"))
    print("WHY\t" + why)
    print("MEANING\t" + meaning.replace("\n", " "))
    print("GRADE_WHY\t" + why_grade.replace("\n", " "))
    print("CORE\t" + core)
    for cid, was, said_now in impacts_kept:
        print("IMPACT_KEPT\t%s\t%s\t%s" % (cid, was, said_now))
    for m in mismatches:
        print("IMPACT_MISMATCH\t%s\t%s\t%s\t%s" % tuple(m["ids"] + m["impacts"]))
    print("COUNTS\t%d\t%d\t%d\t%d" % (met, gap, untested, len(contradicted)))
    print("SUMMARY\t" + summary.replace("\n", " "))
    if observations is not None:
        print("OBSERVATIONS\t%d" % len(observations["observations"]))
    for n in notes:
        print("NOTE\t" + n.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
