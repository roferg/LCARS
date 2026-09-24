#!/usr/bin/env python3
# scorecard.py — S225 MEASUREMENT TOOL (zero model spend, read-only)
#
#   python3 tests/drives/s225/scorecard.py <mission-xo-dir> [<mission-xo-dir> ...]
#
# WHAT IT IS. Tonight Number One (the Verify-stage grader) got seven changes.
# This tool reads a FINISHED run's artefacts off disk and reports, per run and
# across all runs, whether each of the seven changes actually fired — in plain
# English a person can read at 7am on a phone without knowing the codebase.
#
# THE ONE RULE THAT MAKES IT TRUSTWORTHY. It REPORTS what it finds. It never
# asserts a change worked. For every change it says one of three things:
#
#   FIRED         — the evidence that it fired is on disk (with a COUNT and an
#                   example).
#   DID NOT FIRE  — the artefact is here and readable, and nothing in this run
#                   exercised the change.
#   CANNOT TELL   — the file it would have to read is absent or unreadable. It
#                   NAMES the file. This is as important as the other two: a
#                   tool that cannot tell "did not fire" from "I could not look"
#                   is the exact failure this project keeps hitting.
#
# Absence of evidence is NEVER read as "it worked". A missing artefact is
# CANNOT TELL, always naming the file. Every finding prints a number.
#
# THE SHAPE IS CHANGING UNDERNEATH IT. Another implementor is editing the
# scorer right now, so this tool reads defensively: every field access is
# guarded, every file load is wrapped, and anything it cannot find degrades to
# CANNOT TELL — it must never crash and never assume one fixed shape.
#
# Python 3 standard library only. It reads JSON. It spends nothing on a model.

import json
import os
import sys


# ── the three answers ───────────────────────────────────────────────────────
FIRED = "FIRED"
DIDNT = "DID NOT FIRE"
CANT = "CANNOT TELL"


def load_json(path):
    """(data, err). err is a human sentence naming the file when it could not
    be read; data is None then. Never raises."""
    if not path or not os.path.exists(path):
        return None, "the file %s is not here" % _short(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh), None
    except Exception as e:
        return None, "the file %s is here but unreadable (%s)" % (_short(path), e)


def _short(path):
    """A path a human can place — the last two segments are enough."""
    if not path:
        return "(no path)"
    parts = os.path.normpath(path).split(os.sep)
    return os.sep.join(parts[-2:]) if len(parts) >= 2 else path


def as_list(x):
    return x if isinstance(x, list) else []


def as_dict(x):
    return x if isinstance(x, dict) else {}


def crit_of(verdict):
    """The finished ledger rows out of a verdict, or [] — the rows every
    row-level change reads. Guarded against a verdict of the wrong shape."""
    return [c for c in as_list(as_dict(verdict).get("criteria")) if isinstance(c, dict)]


def name_of(entry):
    """A short human handle for a criterion row: its text, else its id."""
    t = " ".join(str(entry.get("text") or "").split())
    if t:
        return t[:70]
    return str(entry.get("id") or "(an unnamed row)")


# ── a run's artefacts, located once ─────────────────────────────────────────
class Run:
    """Everything on disk for one run, located and loaded once. A mission xo/
    dir and a replay output dir are both accepted; whatever is missing simply
    stays None and the changes that need it report CANNOT TELL."""

    def __init__(self, xo_dir):
        self.dir = os.path.abspath(xo_dir)
        self.label = os.path.basename(self.dir.rstrip(os.sep)) or self.dir

        # First-look verdict — the primary artefact.
        self.first_path = os.path.join(self.dir, "verdict.json")
        self.first, self.first_err = load_json(self.first_path)

        # Re-check verdict — a mission dir writes verdict-2.json; a replay
        # output dir writes second/verdict.json. Try both, report which.
        cand = [os.path.join(self.dir, "verdict-2.json"),
                os.path.join(self.dir, "second", "verdict.json")]
        self.recheck_path = None
        self.recheck, self.recheck_err = None, "no re-check verdict (looked for verdict-2.json and second/verdict.json)"
        for p in cand:
            if os.path.exists(p):
                self.recheck_path = p
                self.recheck, self.recheck_err = load_json(p)
                break

        # First-look walk — the record of what was clicked and what refused.
        self.walk_path = os.path.join(self.dir, "walk.json")
        self.walk, self.walk_err = load_json(self.walk_path)

        # Paired drawing↔build parts.
        self.pairs_path = os.path.join(self.dir, "pairs.json")
        self.pairs, self.pairs_err = load_json(self.pairs_path)

    def inventory_lines(self):
        def mark(data, err, path):
            if err and data is None:
                return "missing  — %s" % _short(path)
            return "found    — %s" % _short(path)
        return [
            "first-look verdict : " + mark(self.first, self.first_err, self.first_path),
            "re-check verdict   : " + (("found    — %s" % _short(self.recheck_path))
                                       if self.recheck_path else "missing  — verdict-2.json / second/verdict.json"),
            "walk record        : " + mark(self.walk, self.walk_err, self.walk_path),
            "drawing pairs      : " + mark(self.pairs, self.pairs_err, self.pairs_path),
        ]


# ── a finding: one change's answer for one run ──────────────────────────────
class Finding:
    def __init__(self, num, title):
        self.num = num
        self.title = title
        self.verdict = CANT
        self.lines = []
        # counts carried into the across-all aggregate; free-form per change.
        self.counts = {}

    def say(self, line):
        self.lines.append(line)
        return self

    def render(self):
        out = ["%d. %s" % (self.num, self.title), "   %s" % self.verdict]
        for ln in self.lines:
            out.append("      %s" % ln)
        return "\n".join(out)


# ── change 1 — the score is split three ways ────────────────────────────────
def change1(run):
    f = Finding(1, "The score is split three ways")
    v = run.first
    if v is None:
        f.verdict = CANT
        f.say(run.first_err)
        f.say("Without the first-look verdict there is no score to inspect.")
        return f
    groups = as_dict(v.get("groups"))
    if not groups:
        f.verdict = DIDNT
        f.say("This run's verdict carries no three-way split — the 'groups' "
              "section is not in %s." % _short(run.first_path))
        f.say("Headline grade recorded: %s." % (v.get("score") or "(none)"))
        return f

    person = as_dict(groups.get("person"))
    drawing = as_dict(groups.get("drawing"))
    contract = as_dict(groups.get("contract"))
    if not person:
        f.verdict = DIDNT
        f.say("A 'groups' section exists but has no person group, so the split "
              "is not the one this change makes.")
        return f

    f.verdict = FIRED
    p_worked = _int(person.get("worked"), person.get("met"))
    p_total = _int(person.get("total"))
    f.say("A person can do what it promises: %s of %s."
          % (_n(p_worked), _n(p_total)))
    if drawing:
        d_worked = _int(drawing.get("worked"), drawing.get("met"))
        d_total = _int(drawing.get("total"))
        d_faults = _int(drawing.get("didntWork"), drawing.get("gap"))
        f.say("Looks like the drawing: %s of %s parts right (%s fault%s) — its "
              "own line, never folded into the grade."
              % (_n(d_worked), _n(d_total), _n(d_faults), "" if d_faults == 1 else "s"))
    else:
        f.say("Looks like the drawing: no drawing group on this run (nothing "
              "drawn to check).")
    if contract:
        covered = _int(contract.get("covered"))
        c_total = _int(contract.get("total"))
        f.say("Ticket criteria answered: %s of %s have an answer behind them — "
              "a COUNT, not a grade." % (_n(covered), _n(c_total)))
    else:
        f.say("Ticket criteria: no contract group on this run.")

    headline = v.get("score")
    score_group = v.get("scoreGroup")
    p_grade = person.get("grade")
    is_head = bool(person.get("isHeadline"))
    reads_person = (str(score_group) == "person") and is_head and (headline == p_grade)
    if reads_person:
        f.say("Headline grade: %s — and it reads the PERSON group (the captain's "
              "rule)." % (headline or "(none)"))
    else:
        f.say("Headline grade: %s. NOTE: could not confirm it reads the person "
              "group (scoreGroup=%r, person grade=%r) — reporting the mismatch, "
              "not hiding it." % (headline or "(none)", score_group, p_grade))
    f.counts = {"person_worked": p_worked, "person_total": p_total,
                "headline": str(headline), "reads_person": reads_person}
    return f


# ── change 2 — a refusal was read and answered ──────────────────────────────
def change2(run):
    f = Finding(2, "A refusal was read and answered")
    w = run.walk
    if w is None:
        f.verdict = CANT
        f.say(run.walk_err)
        f.say("The walk record is where a refusal-and-retry would be written, "
              "so without it this cannot be told.")
        return f
    steps = [s for s in as_list(as_dict(w).get("steps")) if isinstance(s, dict)]
    met = [s for s in steps if isinstance(s.get("refusal"), dict)]
    repaired = [s for s in steps if s.get("repaired") is True]
    twice = [s for s in steps if s.get("refusedTwice") is True]
    f.counts = {"met": len(met), "repaired": len(repaired), "twice": len(twice),
                "steps": len(steps)}
    if not met:
        f.verdict = DIDNT
        f.say("Walked %d step%s; none of them recorded a refusal to read and "
              "answer." % (len(steps), "" if len(steps) == 1 else "s"))
        return f
    f.verdict = FIRED
    f.say("Refusals met and read: %d." % len(met))
    f.say("Repaired then went through on the retry: %d." % len(repaired))
    f.say("Refused a second time (a real fault, two attempts behind it): %d."
          % len(twice))
    ex = (repaired or met)[0]
    ex_name = " ".join(str(ex.get("name") or ex.get("key") or "a step").split())
    said = ""
    rep = as_dict(ex.get("repair"))
    if rep.get("becauseItSaid"):
        said = ' — it said: "%s"' % (" ".join(str(rep["becauseItSaid"]).split())[:120])
    elif as_dict(ex.get("refusal")).get("text"):
        said = ' — it said: "%s"' % (" ".join(str(ex["refusal"]["text"]).split())[:120])
    f.say('For example, the step "%s"%s.' % (ex_name[:70], said))
    return f


# ── change 3 — "couldn't set up" is distinct from "couldn't see" ────────────
_OUTCOMES = ("worked", "didnt-work", "couldnt-see", "couldnt-set-up")
_OUTCOME_SAID = {"worked": "worked", "didnt-work": "didn't work",
                 "couldnt-see": "I couldn't see it",
                 "couldnt-set-up": "I couldn't set it up"}


def change3(run):
    f = Finding(3, "\"I couldn't set it up\" is distinct from \"I couldn't see it\"")
    v = run.first
    if v is None:
        f.verdict = CANT
        f.say(run.first_err)
        return f
    rows = crit_of(v)
    if not rows:
        f.verdict = CANT
        f.say("The first-look verdict %s carries no criteria rows, so there are "
              "no outcomes to count." % _short(run.first_path))
        return f
    have_outcome = [r for r in rows if r.get("outcome") in _OUTCOMES]
    tally = {o: sum(1 for r in rows if r.get("outcome") == o) for o in _OUTCOMES}
    f.counts = dict(tally)
    if not have_outcome:
        # No row carries the four-way outcome word: the distinction is not in
        # this run's data. Report the coarse status buckets so the number is
        # never empty, and say plainly that the two "couldn't" kinds are
        # collapsed here.
        f.verdict = DIDNT
        met = sum(1 for r in rows if r.get("status") == "met")
        gap = sum(1 for r in rows if r.get("status") == "gap")
        unt = sum(1 for r in rows if r.get("status") == "untested")
        # The older field the four-way outcome is derived from, if present.
        cnc = {}
        for r in rows:
            k = str(r.get("couldNotCheck") or "").strip()
            if k:
                cnc[k] = cnc.get(k, 0) + 1
        f.say("No row carries the four-way outcome, so this run does NOT split "
              "the two 'couldn't' kinds: worked %d, didn't work %d, and %d "
              "untested collapsed into ONE bucket." % (met, gap, unt))
        if cnc:
            f.say("(The older reason-word is on some rows: %s — but nothing "
                  "downstream separated them into two outcomes here.)"
                  % ", ".join("%s %d" % (k, n) for k, n in sorted(cnc.items())))
        f.counts["distinguishable"] = False
        return f
    f.verdict = FIRED
    for o in _OUTCOMES:
        f.say("%s: %d." % (_OUTCOME_SAID[o], tally[o]))
    distinguishable = True  # the two couldn't kinds are separate outcome words
    f.say("The two 'couldn't' kinds ARE kept apart in the data: 'couldn't set "
          "it up' (%d) and 'couldn't see it' (%d) are separate outcomes, not "
          "one bucket." % (tally["couldnt-set-up"], tally["couldnt-see"]))
    mc = as_dict(v.get("myChecking"))
    if mc:
        f.say("They are also listed separately for us to fix: %d I couldn't set "
              "up, %d I couldn't see." % (len(as_list(mc.get("couldntSetUp"))),
                                          len(as_list(mc.get("couldntSee")))))
    f.counts["distinguishable"] = distinguishable
    return f


# ── change 4 — a clicked control was also asked whether it LOOKS right ───────
def change4(run):
    f = Finding(4, "A control the walk clicked was also asked whether it LOOKS right")
    v = run.first
    if v is None:
        f.verdict = CANT
        f.say(run.first_err)
        return f
    rows = crit_of(v)
    if not rows:
        f.verdict = CANT
        f.say("The first-look verdict %s carries no criteria rows, so a "
              "'touched' row cannot be looked for." % _short(run.first_path))
        return f
    touched = [r for r in rows if str(r.get("source") or "").strip().lower() == "touched"]
    faults = [r for r in touched if r.get("status") == "gap"
              or r.get("outcome") == "didnt-work"]
    f.counts = {"touched": len(touched), "faults": len(faults)}
    if not touched:
        f.verdict = DIDNT
        f.say("No criterion in this run carries the 'touched' mark — nothing the "
              "walk clicked was additionally checked for how it looks. (Rows "
              "scanned: %d.)" % len(rows))
        return f
    f.verdict = FIRED
    f.say("Controls clicked and then also checked for how they look: %d."
          % len(touched))
    f.say("Of those, a fault was raised on: %d." % len(faults))
    ex = (faults or touched)[0]
    f.say('For example: "%s".' % name_of(ex))
    return f


# ── change 5 — near-matching names paired (the whole-word-run rule) ─────────
_WWR = "the drawn name is a whole-word run of the label"


def change5(run):
    f = Finding(5, "Near-matching names paired")
    p = run.pairs
    if p is None:
        f.verdict = CANT
        f.say(run.pairs_err)
        f.say("The pairings are in pairs.json; without it this cannot be told.")
        return f
    pairs = [x for x in as_list(as_dict(p).get("pairs")) if isinstance(x, dict)]
    wwr = [x for x in pairs if str(x.get("handle") or "").strip() == _WWR]
    f.counts = {"wwr": len(wwr), "pairs": len(pairs)}
    if not wwr:
        f.verdict = DIDNT
        f.say("Of %d pairing%s, none were made by the whole-word-run rule "
              "(near-matching names)." % (len(pairs), "" if len(pairs) == 1 else "s"))
        return f
    f.verdict = FIRED
    f.say("Pairings made because the drawn name is a whole word-run of the "
          "built label: %d." % len(wwr))
    ex = wwr[0]
    drawn = " ".join(str(ex.get("name") or "").split()) or "(unnamed)"
    built = as_dict(ex.get("built"))
    built_label = " ".join(str(built.get("name") or "").split()) or "(unnamed)"
    f.say('For example: drawn "%s"  ↔  built "%s".' % (drawn[:50], built_label[:50]))
    return f


# ── change 6 — a measurement never settled a row ────────────────────────────
_MEASURE_MARK = "measurement cannot settle a criterion"
_MEASURE_NOTE = "measured box"


def change6(run):
    f = Finding(6, "A measurement never settled a row")
    v = run.first
    if v is None:
        f.verdict = CANT
        f.say(run.first_err)
        return f
    rows = crit_of(v)
    if not rows:
        f.verdict = CANT
        f.say("The first-look verdict %s carries no criteria rows, so a "
              "measurement demotion cannot be looked for." % _short(run.first_path))
        return f
    # Rows demoted because only a measurement spoke: a row now untested whose
    # note says a measurement cannot settle it.
    demoted = [r for r in rows if r.get("status") == "untested"
               and _MEASURE_MARK in str(r.get("note") or "").lower()]
    # Corroborated by the verdict's own ledger notes, if present.
    notes = as_list(v.get("ledgerNotes"))
    note_hits = sum(1 for n in notes
                    if _MEASURE_NOTE in str(n).lower()
                    or _MEASURE_MARK in str(n).lower())
    demoted_n = max(len(demoted), note_hits)
    # THE REAL CHECK: any row still standing 'met' on a measurement. Must be 0.
    still_met = [r for r in rows if r.get("status") == "met"
                 and str(r.get("evidence") or "").strip().lower() == "measurement"]
    f.counts = {"demoted": demoted_n, "still_met_on_measurement": len(still_met)}
    # The change FIRED only if a row was actually blocked from settling on a
    # measurement. The "still met on a measurement" number is the real check
    # and is reported EITHER WAY — a nonzero there is the very bug this change
    # exists to kill, and it is flagged whether or not the change fired.
    if demoted_n > 0:
        f.verdict = FIRED
        f.say("Rows a measurement tried to settle, and that were pushed back to "
              "'couldn't check' instead: %d." % demoted_n)
        if demoted:
            f.say('For example: "%s".' % name_of(demoted[0]))
    else:
        f.verdict = DIDNT
        f.say("No row in this run was closed on a measurement, so none needed "
              "demoting. (Rows scanned: %d.)" % len(rows))
    if len(still_met) == 0:
        f.say("The real check — rows still marked 'worked' on a measurement "
              "alone: 0. That is the number that matters, and it is zero.")
    else:
        f.say("PROBLEM: %d row%s still read 'worked' on a measurement alone — "
              "this number must be ZERO. Naming %s: %s."
              % (len(still_met), "" if len(still_met) == 1 else "s",
                 "it" if len(still_met) == 1 else "them",
                 ", ".join(str(r.get("id")) for r in still_met[:5])))
    return f


# ── change 7 — both looks judged by the same standard ───────────────────────
def _test_settled(verdict):
    """Rows a NAMED test settled: status met AND evidence tests."""
    return [r for r in crit_of(verdict)
            if r.get("status") == "met"
            and str(r.get("evidence") or "").strip().lower() == "tests"]


def change7(run):
    f = Finding(7, "Both looks judged by the same standard")
    if run.first is None:
        f.verdict = CANT
        f.say(run.first_err)
        return f
    if run.recheck is None:
        f.verdict = CANT
        f.say(run.recheck_err)
        f.say("There is a first look but no re-check to compare it against, so "
              "the two-standards question cannot be told.")
        # Still report the first look's number, so there IS a number.
        first = _test_settled(run.first)
        f.say("(First look: %d row%s settled by a named test.)"
              % (len(first), "" if len(first) == 1 else "s"))
        f.counts = {"first": len(first), "recheck": None, "diff": None}
        return f
    first = _test_settled(run.first)
    rechk = _test_settled(run.recheck)
    diff = len(first) - len(rechk)
    f.counts = {"first": len(first), "recheck": len(rechk), "diff": diff}
    if not first and not rechk:
        f.verdict = DIDNT
        f.say("Neither the first look nor the re-check settled any row with a "
              "named test, so there was nothing to hold to the same standard.")
        return f
    f.verdict = FIRED
    f.say("Rows a named test settled — first look: %d, re-check: %d."
          % (len(first), len(rechk)))
    if diff <= 0:
        f.say("The re-check kept every test-backed row (difference %d) — none "
              "collapsed to 'couldn't check' the second time." % diff)
    else:
        f.say("The re-check settled %d FEWER test-backed row%s than the first "
              "look — that is exactly the collapse this change exists to stop, "
              "so it is flagged, not hidden." % (diff, "" if diff == 1 else "s"))
    return f


CHANGES = [change1, change2, change3, change4, change5, change6, change7]
TITLES = [
    "The score is split three ways",
    "A refusal was read and answered",
    "\"I couldn't set it up\" is distinct from \"I couldn't see it\"",
    "A control the walk clicked was also asked whether it LOOKS right",
    "Near-matching names paired",
    "A measurement never settled a row",
    "Both looks judged by the same standard",
]


# ── small helpers ───────────────────────────────────────────────────────────
def _int(*vals):
    """The first value that is a real int, else 0."""
    for v in vals:
        if isinstance(v, bool):
            continue
        if isinstance(v, int):
            return v
    return 0


def _n(x):
    return str(x) if isinstance(x, int) else "?"


def hr(ch="="):
    return ch * 72


# ── per-run and aggregate reporting ─────────────────────────────────────────
def report_run(run):
    lines = [hr(), " RUN: %s" % run.label, "      %s" % run.dir, hr()]
    lines.append("Artefacts on disk:")
    for il in run.inventory_lines():
        lines.append("  " + il)
    lines.append("")
    findings = [fn(run) for fn in CHANGES]
    for fi in findings:
        lines.append(fi.render())
        lines.append("")
    tally = {FIRED: 0, DIDNT: 0, CANT: 0}
    for fi in findings:
        tally[fi.verdict] += 1
    lines.append("  This run: FIRED %d · DID NOT FIRE %d · CANNOT TELL %d"
                 % (tally[FIRED], tally[DIDNT], tally[CANT]))
    lines.append("")
    return "\n".join(lines), findings


def report_across(all_findings, nruns):
    # all_findings: list (per run) of list (7 findings)
    lines = [hr(), " ACROSS ALL %d RUN%s" % (nruns, "" if nruns == 1 else "S"), hr()]
    for i in range(len(CHANGES)):
        col = [run_f[i] for run_f in all_findings]
        tally = {FIRED: 0, DIDNT: 0, CANT: 0}
        for fi in col:
            tally[fi.verdict] += 1
        lines.append("%d. %s" % (i + 1, TITLES[i]))
        lines.append("   FIRED %d · DID NOT FIRE %d · CANNOT TELL %d"
                     % (tally[FIRED], tally[DIDNT], tally[CANT]))
        agg = _aggregate(i, col)
        if agg:
            lines.append("   " + agg)
        lines.append("")
    return "\n".join(lines)


def _aggregate(idx, col):
    """One plain-English roll-up line per change across the runs, or ''."""
    fired = [c for c in col if c.verdict == FIRED]
    if idx == 0:  # three-way split
        if not fired:
            return ""
        return "Where it fired, the headline read the person group on %d of %d." % (
            sum(1 for c in fired if c.counts.get("reads_person")), len(fired))
    if idx == 1:  # refusals
        met = sum(c.counts.get("met", 0) for c in col)
        rep = sum(c.counts.get("repaired", 0) for c in col)
        tw = sum(c.counts.get("twice", 0) for c in col)
        return "Total across runs: %d refusal(s) met, %d repaired, %d refused twice." % (met, rep, tw)
    if idx == 2:  # outcomes distinct
        n = sum(1 for c in col if c.counts.get("distinguishable"))
        return "Runs where the two 'couldn't' kinds were kept apart: %d of %d." % (n, len(col))
    if idx == 3:  # touched
        t = sum(c.counts.get("touched", 0) for c in col)
        fl = sum(c.counts.get("faults", 0) for c in col)
        return "Total across runs: %d clicked control(s) also checked for looks, %d faulted." % (t, fl)
    if idx == 4:  # whole-word-run pairs
        w = sum(c.counts.get("wwr", 0) for c in col)
        return "Total across runs: %d pairing(s) made by the whole-word-run rule." % w
    if idx == 5:  # measurement
        dem = sum(c.counts.get("demoted", 0) for c in col)
        bad = sum(c.counts.get("still_met_on_measurement", 0) for c in col)
        tail = "the real check (rows still 'worked' on a measurement) is %d — %s." % (
            bad, "clean" if bad == 0 else "NOT ZERO, a problem")
        return "Total across runs: %d row(s) a measurement was blocked from settling; %s" % (dem, tail)
    if idx == 6:  # same standard
        haveboth = [c for c in col if c.counts.get("recheck") is not None]
        if not haveboth:
            return "No run had both a first look and a re-check to compare."
        worst = max((c.counts.get("diff", 0) for c in haveboth), default=0)
        return "Runs with both looks: %d; worst drop in test-backed rows on the re-check: %d." % (
            len(haveboth), worst)
    return ""


def main(argv):
    dirs = argv[1:]
    if not dirs:
        sys.stderr.write(
            "usage: python3 scorecard.py <mission-xo-dir> [<mission-xo-dir> ...]\n"
            "  Each arg is a mission's xo/ dir (or a replay output dir of the\n"
            "  same shape). Reports, per run and across all runs, whether each\n"
            "  of the seven S225 changes fired. Reads JSON on disk; spends\n"
            "  nothing on a model.\n")
        return 2

    print("S225 SCORECARD — did each of the seven changes do its job?")
    print("(FIRED = evidence on disk, with a count.  DID NOT FIRE = artefact")
    print(" here, nothing exercised it.  CANNOT TELL = the file it needs is")
    print(" absent — named.  Absence is never read as 'it worked'.)")
    print("")

    all_findings = []
    for d in dirs:
        if not os.path.isdir(d):
            # Not a directory at all: say so, and still emit a full CANNOT-TELL
            # card so the run is never silently skipped.
            print(hr())
            print(" RUN: %s" % d)
            print(hr())
            print("  This path is not a directory, so none of its artefacts "
                  "could be read.")
            run = Run(d) if False else None
            # Build a synthetic all-CANNOT-TELL column.
            fake = []
            for i, title in enumerate(TITLES):
                fi = Finding(i + 1, title)
                fi.verdict = CANT
                fi.say("The run directory %s does not exist." % d)
                fake.append(fi)
                print(fi.render())
                print("")
            all_findings.append(fake)
            continue
        run = Run(d)
        text, findings = report_run(run)
        print(text)
        all_findings.append(findings)

    if len(all_findings) >= 1:
        print(report_across(all_findings, len(all_findings)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
