#!/usr/bin/env bash
#
# Tests for THE TICKET-CRITERION CONTRADICTION CHECK (the ruling of 2026-09-25).
#
# MEASURED 2026-09-24. A mission was written with a deliberate omission
# ("deliberately do not build the counter"). The PLANNER turned that into a
# ticket whose acceptance criterion CERTIFIED the counter's ABSENCE. The
# reviewer then checked that ticket criterion, found the counter absent, and
# marked it MET. One line called the missing feature a fault (the PRD line) and
# another certified its absence as correct (the ticket line). Nothing checked a
# ticket's acceptance criterion against the requirement it is supposed to
# deliver, so any ticket that drifts from its requirement was self-certifying.
#
# THE FIRST CURE READ ENGLISH — AND WAS BEATEN TWICE IN ONE DAY. It guessed a
# criterion's polarity from its prose (does this sentence ask FOR a thing or for
# its ABSENCE). A text-matching fallback produced 8 false positives (deleted),
# and then a REGEX polarity classifier flagged a CORRECT ticket through a
# correct link, because it read the NEGATIVE requirement "Saving is instant and
# never asks the player to name anything" as affirmative. Reading English for
# polarity is the most expensive recurring mistake in this codebase (S147, S156,
# S188) — so the consequence was withdrawn while the captain ruled on the design.
#
# THE RULING: RECORD, DO NOT INFER. The PLANNER, at the moment it writes a
# ticket, DECLARES which way round each criterion is — it `delivers` the
# requirement it names (`serves`) or it deliberately `removes` it. This check
# READS that declaration. A CONTRADICTION is a criterion the planner declared it
# `removes` against a PRIMARY PRD requirement the PRD asks FOR. Nothing reads
# prose for polarity any more, so the teeth come back: the offending ticket row
# is dropped to a gap AND the primary requirement it names is overruled to a gap,
# which moves the headline grade. A missing/unreadable declaration is REFUSED by
# name, never defaulted.
#
# Skill source under test:
#   skills/lcars-xo/xo-criteria.py — the contract + the contradiction check.
#   skills/lcars-xo/xo-score.py    — the teeth (the grade consequence).
#
# ZERO SPEND. No worker, no browser.
#
# Usage: bash tests/lcars-xo-serves.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRITERIA="${LCARS_XO_CRITERIA_PY:-$REPO_ROOT/skills/lcars-xo/xo-criteria.py}"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# j <criteria.json> <python-expr-over d> — evaluate a boolean expression with
# `d` bound to the loaded contract dict; exit 0 when true.
j() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if bool(eval(sys.argv[2])) else 1)' "$1" "$2"
}

# The PRD asks FOR a counter — the requirement the whole defect turns on.
PRD='# Mission: Board

## Acceptance criteria
- a live counter shows the number of items on the board
- the board lists every task
'

# ─── A. the linked contradiction — the measured defect, DECLARED ─────────────
# t-001-ac1 declares it deliberately REMOVES the counter requirement (prd-1);
# t-001-ac2 declares it DELIVERS "lists every task" (prd-2).
mA="$TMPROOT/linked"; mkdir -p "$mA"
printf '%s' "$PRD" >"$mA/prd.md"
cat >"$mA/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Board without a counter",
    "description": "deliberately do not build the counter",
    "acceptanceCriteria": [
      {"text": "no counter is displayed on the board", "serves": "a live counter shows the number of items on the board", "direction": "removes"},
      {"text": "the board lists every task", "serves": "the board lists every task", "direction": "delivers"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mA" "$mA/criteria.json" >/dev/null

check "A1. a contradiction is recorded (not silently absent)" \
  "j '$mA/criteria.json' 'len(d.get(\"contradictions\",[]))==1'"
check "A2. it names the PRD requirement by id" \
  "j '$mA/criteria.json' 'd[\"contradictions\"][0][\"requirement\"][\"id\"]==\"prd-1\"'"
check "A3. it names the offending ticket criterion by id" \
  "j '$mA/criteria.json' 'd[\"contradictions\"][0][\"ticketCriterion\"][\"id\"]==\"t-001-ac1\"'"
check "A4. it carries the requirement text and the ticket criterion text" \
  "j '$mA/criteria.json' '\"counter\" in d[\"contradictions\"][0][\"requirement\"][\"text\"] and \"no counter\" in d[\"contradictions\"][0][\"ticketCriterion\"][\"text\"]'"
check "A5. it states the direction (ticket declares it REMOVES what the requirement asks for)" \
  "j '$mA/criteria.json' '\"removes\" in d[\"contradictions\"][0][\"direction\"].lower()'"
check "A6. it used the DECLARED direction, not a text guess" \
  "j '$mA/criteria.json' 'd[\"contradictions\"][0][\"via\"]==\"declaration\"'"
check "A7. the offending plan criterion is MARKED with the requirement it contradicts" \
  "j '$mA/criteria.json' 'any(c.get(\"contradictsRequirement\")==\"prd-1\" for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac1\")'"
check "A8. the DELIVERING ticket criterion is NOT flagged" \
  "j '$mA/criteria.json' 'all(\"contradictsRequirement\" not in c for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac2\")'"
check "A9. no criterion carried a malformed declaration in the well-formed plan" \
  "j '$mA/criteria.json' 'len(d.get(\"malformedDeclarations\",[]))==0'"

# ─── B. the control — a ticket criterion that DELIVERS the requirement ───────
mB="$TMPROOT/agree"; mkdir -p "$mB"
printf '%s' "$PRD" >"$mB/prd.md"
cat >"$mB/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Add the counter",
    "description": "build it",
    "acceptanceCriteria": [
      {"text": "a live counter is displayed and updates as items change", "serves": "a live counter shows the number of items on the board", "direction": "delivers"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mB" "$mB/criteria.json" >/dev/null
check "B1. an agreeing (delivers) ticket criterion yields NO contradiction" \
  "j '$mB/criteria.json' 'len(d.get(\"contradictions\",[]))==0'"
check "B2. and nothing is marked contradictsRequirement" \
  "j '$mB/criteria.json' 'all(\"contradictsRequirement\" not in c for c in d[\"criteria\"])'"

# ─── C. NO LINK → NO GUESS: an unlinked criterion is left unjudged ───────────
# A plain-string criterion names no requirement and declares nothing. It is left
# unjudged (silence, not a guess) and COUNTED, so an unlinked plan reads as "not
# checked", never "clean".
mC="$TMPROOT/nolink"; mkdir -p "$mC"
printf '%s' "$PRD" >"$mC/prd.md"
cat >"$mC/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Board without a counter",
    "description": "deliberately do not build the counter",
    "acceptanceCriteria": [
      "no counter appears anywhere on the board"
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mC" "$mC/criteria.json" >/dev/null
check "C1. an unlinked absence-asserting criterion is NOT guessed into a contradiction" \
  "j '$mC/criteria.json' 'len(d.get(\"contradictions\",[]))==0'"
check "C2. the contract states plainly how many ticket criteria carried no link" \
  "j '$mC/criteria.json' 'd.get(\"unlinkedTicketCriteria\")==1'"
check "C3. an unlinked plain string is NOT a malformed declaration (it declared nothing)" \
  "j '$mC/criteria.json' 'len(d.get(\"malformedDeclarations\",[]))==0'"
check "C4. a linked plan (case A) reports zero unlinked ticket criteria" \
  "j '$mA/criteria.json' 'd.get(\"unlinkedTicketCriteria\")==0'"

# ─── D. serves by SYNTHETIC ID resolves the same as by text ──────────────────
mD="$TMPROOT/byid"; mkdir -p "$mD"
printf '%s' "$PRD" >"$mD/prd.md"
cat >"$mD/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Board without a counter",
    "description": "deliberately do not build the counter",
    "acceptanceCriteria": [
      {"text": "the counter is not shown", "serves": "prd-1", "direction": "removes"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mD" "$mD/criteria.json" >/dev/null
check "D1. serves given as prd-1 resolves to the requirement" \
  "j '$mD/criteria.json' 'len(d.get(\"contradictions\",[]))==1 and d[\"contradictions\"][0][\"requirement\"][\"id\"]==\"prd-1\" and d[\"contradictions\"][0][\"via\"]==\"declaration\"'"

# ─── E. a DELIVERS criterion never trips the check, whatever its wording ─────
# "green, not red" reads like an absence to a prose parser, but the planner
# DECLARED it delivers the counter — so it is never a contradiction. This is the
# false-alarm class the declaration kills.
mE="$TMPROOT/notabsence"; mkdir -p "$mE"
printf '%s' "$PRD" >"$mE/prd.md"
cat >"$mE/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Counter styling",
    "description": "colour",
    "acceptanceCriteria": [
      {"text": "the counter is green, not red", "serves": "a live counter shows the number of items on the board", "direction": "delivers"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mE" "$mE/criteria.json" >/dev/null
check "E1. 'green, not red' DECLARED delivers is NOT a contradiction" \
  "j '$mE/criteria.json' 'len(d.get(\"contradictions\",[]))==0'"

# ─── F. the SCORE guard — TEETH RESTORED (the ruling of 2026-09-25) ──────────
# Now the direction is DECLARED, the consequence comes back. Feed xo-score.py the
# marked contract (case A) and a verdict that rates everything MET. The teeth
# must: overrule the PRIMARY requirement prd-1 (met->gap), flip the offending
# plan row t-001-ac1 (met->gap), name both ids in a ledger note, and MOVE THE
# GRADE.
mkdir -p "$TMPROOT/scored"
cat >"$TMPROOT/scored/worker.json" <<'W'
{"score":"high","summary":"all good","criteria":[
 {"id":"prd-1","impact":"high","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact high. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"prd-2","impact":"high","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact high. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"t-001-ac1","impact":"low","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact low. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"t-001-ac2","impact":"low","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact low. I tried; I saw (evidence: s1). Outcome: met."}
],"gaps":[]}
W
"$PY" "$SCOREPY" "$TMPROOT/scored/worker.json" "$mA/criteria.json" "$TMPROOT/scored/verdict.json" >/dev/null 2>&1
check "F1. the served PRIMARY requirement prd-1 is OVERRULED met->gap" \
  "j '$TMPROOT/scored/verdict.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"prd-1\"][0][\"status\"]==\"gap\"'"
check "F2. the offending plan row t-001-ac1 is flipped met->gap" \
  "j '$TMPROOT/scored/verdict.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac1\"][0][\"status\"]==\"gap\"'"
check "F3. a ledger note names BOTH ids and the declared removal" \
  "j '$TMPROOT/scored/verdict.json' 'any(\"t-001-ac1\" in n and \"prd-1\" in n and \"remove\" in n.lower() for n in d.get(\"ledgerNotes\",[]))'"

# ─── FLIP-CONTROL — with NO contradiction mark the grade STANDS ──────────────
# The teeth must move the grade ONLY when a contradiction is declared. Score the
# same worker verdict against an UNMARKED copy of case A: prd-1 must stay met.
# This is the known-good control that proves F is not simply always-failing.
"$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for c in d.get("criteria",[]):
    c.pop("contradictsRequirement",None)
d["contradictions"]=[]
json.dump(d,open(sys.argv[2],"w"))' "$mA/criteria.json" "$TMPROOT/unmarked.json"
"$PY" "$SCOREPY" "$TMPROOT/scored/worker.json" "$TMPROOT/unmarked.json" "$TMPROOT/scored/verdict_unmarked.json" >/dev/null 2>&1
check "F4. without the mark, prd-1 KEEPS its met status (the mark is what moves it)" \
  "j '$TMPROOT/scored/verdict_unmarked.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"prd-1\"][0][\"status\"]==\"met\"'"
check "F5. the grade MOVED: marked score differs from the unmarked score" \
  "$PY -c 'import json;a=json.load(open(\"$TMPROOT/scored/verdict.json\"));b=json.load(open(\"$TMPROOT/scored/verdict_unmarked.json\"));exit(0 if a[\"score\"]!=b[\"score\"] else 1)'"

# ─── PASS-MARK (a) — the REAL false positive must STOP firing ────────────────
# REQUIREMENT prd-3: "Saving is instant and never asks the player to name
# anything." (a NEGATIVE requirement the old parser misread as affirmative).
# TICKET t-004-ac2: "Activating Save completes without presenting any
# text-entry/name prompt" — which DELIVERS it, and the planner DECLARES delivers.
# It must no longer flag, and must not be downgraded.
mG="$TMPROOT/realfp"; mkdir -p "$mG"
cat >"$mG/prd.md" <<'PP'
# Mission: Save

## Acceptance criteria
- the game autosaves on every room change
- a save indicator flashes briefly after each save
- Saving is instant and never asks the player to name anything.
PP
cat >"$mG/plan.json" <<'P'
[
  {
    "id": "t-004",
    "title": "Instant save",
    "description": "save without prompting",
    "acceptanceCriteria": [
      {"text": "Save writes the current state to disk", "serves": "prd-1", "direction": "delivers"},
      {"text": "Activating Save completes without presenting any text-entry/name prompt", "serves": "Saving is instant and never asks the player to name anything.", "direction": "delivers"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mG" "$mG/criteria.json" >/dev/null
check "(a) the real pair is NOT flagged (the planner declared it delivers)" \
  "j '$mG/criteria.json' 'all(\"contradictsRequirement\" not in c for c in d[\"criteria\"] if c[\"id\"]==\"t-004-ac2\") and len(d.get(\"contradictions\",[]))==0'"
cat >"$TMPROOT/scored/workerG.json" <<'W'
{"score":"high","summary":"all good","criteria":[
 {"id":"prd-1","impact":"high","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact high. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"prd-2","impact":"high","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact high. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"prd-3","impact":"high","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact high. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"t-004-ac1","impact":"low","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact low. I tried; I saw (evidence: s1). Outcome: met."},
 {"id":"t-004-ac2","impact":"low","impactWhy":"pt","status":"met","shot":"s1","evidence":"picture","note":"saw","reason":"Impact low. I tried; I saw (evidence: s1). Outcome: met."}
],"gaps":[]}
W
"$PY" "$SCOREPY" "$TMPROOT/scored/workerG.json" "$mG/criteria.json" "$TMPROOT/scored/verdictG.json" >/dev/null 2>&1
check "(a) the correctly-implementing ticket criterion is NOT downgraded" \
  "j '$TMPROOT/scored/verdictG.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"t-004-ac2\"][0][\"status\"]==\"met\"'"
check "(a) and the served requirement prd-3 is NOT overruled" \
  "j '$TMPROOT/scored/verdictG.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"prd-3\"][0][\"status\"]==\"met\"'"

# ─── PASS-MARK (b) — a genuine contradiction still fires AND moves the grade ──
# Case A is a genuine, DECLARED contradiction. It must move the grade at score
# time (proved by F5 above: marked score != unmarked score).
check "(b) a genuine declared contradiction moves the grade" \
  "$PY -c 'import json;a=json.load(open(\"$TMPROOT/scored/verdict.json\"));b=json.load(open(\"$TMPROOT/scored/verdict_unmarked.json\"));exit(0 if a[\"score\"]!=b[\"score\"] else 1)'"
check "(b) and the pair is reported to a person (both ids surfaced)" \
  "j '$TMPROOT/scored/verdict.json' 'any(\"t-001-ac1\" in n and \"prd-1\" in n for n in d.get(\"ledgerNotes\",[]))'"

# ─── PASS-MARK (c) — a malformed/missing declaration is REFUSED by name ──────
# A `serves` with no readable `direction` is not defaulted — it is recorded by
# name, with the field to add, so a planner who linked a requirement but did not
# state which way round it is gets a refusal, not a silent guess. A well-formed
# sibling in the SAME plan is the known-good control: it must NOT be listed.
mM="$TMPROOT/malformed"; mkdir -p "$mM"
printf '%s' "$PRD" >"$mM/prd.md"
cat >"$mM/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Board",
    "description": "half-declared",
    "acceptanceCriteria": [
      {"text": "the counter is not shown", "serves": "prd-1"},
      {"text": "the board lists every task", "serves": "prd-2", "direction": "delivers"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mM" "$mM/criteria.json" >/dev/null
check "(c) the half-declared criterion is recorded as malformed, by id" \
  "j '$mM/criteria.json' 'any(m[\"id\"]==\"t-001-ac1\" for m in d.get(\"malformedDeclarations\",[]))'"
check "(c) the refusal names the field to add (direction)" \
  "j '$mM/criteria.json' 'any(\"direction\" in m[\"problem\"] for m in d.get(\"malformedDeclarations\",[]) if m[\"id\"]==\"t-001-ac1\")'"
check "(c) a missing declaration is NOT defaulted into a contradiction" \
  "j '$mM/criteria.json' 'all(c.get(\"ticketCriterion\",{}).get(\"id\")!=\"t-001-ac1\" for c in d.get(\"contradictions\",[]))'"
check "(c-control) the well-formed sibling is NOT listed as malformed" \
  "j '$mM/criteria.json' 'all(m[\"id\"]!=\"t-001-ac2\" for m in d.get(\"malformedDeclarations\",[]))'"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
