#!/usr/bin/env bash
#
# Tests for THE TICKET-CRITERION CONTRADICTION CHECK (Number One).
#
# MEASURED 2026-09-24. A mission was written with a deliberate omission
# ("deliberately do not build the counter"). The PLANNER turned that into a
# ticket whose acceptance criterion REQUIRED the counter's ABSENCE. The
# reviewer then checked that ticket criterion, found the counter absent, and
# marked it MET. One line called the missing feature a fault (the PRD line) and
# another certified its absence as correct (the ticket line). Nothing checked a
# ticket's acceptance criterion against the requirement it is supposed to
# deliver, so any ticket that drifts from its requirement was self-certifying.
#
# THE CURE. The contract is BUILT BEFORE LOOKING and reads both prd.md and
# plan.json, so a ticket criterion that contradicts the requirement it serves
# is decidable there, before a pixel is seen. When a plan (ticket) criterion
# asserts the ABSENCE of what the PRD requirement it serves asks FOR, that is a
# contradiction: recorded by name (which requirement, which ticket criterion,
# which direction) in the contract, and marked on the criterion so it can never
# read as a clean upward win.
#
# RECORD, DO NOT INFER. The planner records which requirement each ticket
# criterion serves (`serves`). xo-criteria.py fires the contradiction check
# ONLY on a recorded, resolved link. There is NO text fallback: an unlinked
# criterion is left unjudged (silence, not a guess), and the contract states
# plainly how many ticket criteria carried no link so an unlinked plan reads as
# "not checked", never as "clean". MEASURED 2026-09-24: on the first real
# mission the text fallback touched (106 criteria) it produced 8 false
# positives, all resolving to the longest requirement (prd-1) and all
# downgrading a correct criterion from met to gap. Deleting the fallback is
# LCARS's proven cure (S147, S156, S188): refuse to judge what you cannot name.
#
# Skill source under test:
#   skills/lcars-xo/xo-criteria.py — the contract + the contradiction check.
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

# ─── A. the linked contradiction — the measured defect ───────────────────────
mA="$TMPROOT/linked"; mkdir -p "$mA"
printf '%s' "$PRD" >"$mA/prd.md"
cat >"$mA/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Board without a counter",
    "description": "deliberately do not build the counter",
    "acceptanceCriteria": [
      {"text": "no counter is displayed on the board", "serves": "a live counter shows the number of items on the board"},
      {"text": "the board lists every task", "serves": "the board lists every task"}
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
check "A5. it states the direction (ticket requires the ABSENCE of what the requirement asks for)" \
  "j '$mA/criteria.json' '\"absence\" in d[\"contradictions\"][0][\"direction\"].lower()'"
check "A6. it used the recorded link, not a text guess" \
  "j '$mA/criteria.json' 'd[\"contradictions\"][0][\"via\"]==\"link\"'"
check "A7. the offending plan criterion is MARKED with the requirement it contradicts" \
  "j '$mA/criteria.json' 'any(c.get(\"contradictsRequirement\")==\"prd-1\" for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac1\")'"
check "A8. the AGREEING ticket criterion is NOT flagged" \
  "j '$mA/criteria.json' 'all(\"contradictsRequirement\" not in c for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac2\")'"
check "A9. a contradicting ticket criterion stays a plan-source (CONTRACT-group) row — it never sets the grade" \
  "j '$mA/criteria.json' 'all(c[\"source\"]==\"plan\" for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac1\")'"

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
      {"text": "a live counter is displayed and updates as items change", "serves": "a live counter shows the number of items on the board"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mB" "$mB/criteria.json" >/dev/null
check "B1. an agreeing ticket criterion yields NO contradiction" \
  "j '$mB/criteria.json' 'len(d.get(\"contradictions\",[]))==0'"
check "B2. and nothing is marked contradictsRequirement" \
  "j '$mB/criteria.json' 'all(\"contradictsRequirement\" not in c for c in d[\"criteria\"])'"

# ─── C. NO LINK → NO GUESS: an unlinked criterion is left unjudged ───────────
# The measured defect: a text fallback matched unlinked criteria to the longest
# requirement and downgraded correct criteria. The cure is silence — and an
# honest, visible count of how many criteria carried no link.
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
check "C3. a linked plan (case A) reports zero unlinked ticket criteria" \
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
      {"text": "the counter is not shown", "serves": "prd-1"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mD" "$mD/criteria.json" >/dev/null
check "D1. serves given as prd-1 resolves to the requirement" \
  "j '$mD/criteria.json' 'len(d.get(\"contradictions\",[]))==1 and d[\"contradictions\"][0][\"requirement\"][\"id\"]==\"prd-1\" and d[\"contradictions\"][0][\"via\"]==\"link\"'"

# ─── E. a NON-absence ticket criterion never trips the check ─────────────────
# A criterion that legitimately says something is not X (a colour, a state) but
# does NOT deny existence must not be flagged.
mE="$TMPROOT/notabsence"; mkdir -p "$mE"
printf '%s' "$PRD" >"$mE/prd.md"
cat >"$mE/plan.json" <<'P'
[
  {
    "id": "t-001",
    "title": "Counter styling",
    "description": "colour",
    "acceptanceCriteria": [
      {"text": "the counter is green, not red", "serves": "a live counter shows the number of items on the board"}
    ],
    "dependencies": []
  }
]
P
"$PY" "$CRITERIA" "$mE" "$mE/criteria.json" >/dev/null
check "E1. 'green, not red' about a delivered counter is NOT a contradiction" \
  "j '$mE/criteria.json' 'len(d.get(\"contradictions\",[]))==0'"

# ─── F. the SCORE guard — a contradiction can never read as a clean MET ──────
# The measured defect: the reviewer rated the absence-asserting ticket criterion
# MET, and the omission the PRD faults was blessed as correct. Feed xo-score.py
# the marked contract (from case A) and a worker verdict that rates the
# contradicting criterion MET; it must be overruled to a gap and NAMED.
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
check "F1. the contradicting ticket criterion, rated MET, is overruled to a gap" \
  "j '$TMPROOT/scored/verdict.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"t-001-ac1\"][0][\"status\"]==\"gap\"'"
check "F2. and the verdict names the disagreement (criterion + requirement) by name" \
  "j '$TMPROOT/scored/verdict.json' 'any(\"t-001-ac1\" in n and \"prd-1\" in n and \"omission\" in n for n in d.get(\"ledgerNotes\",[]))'"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
