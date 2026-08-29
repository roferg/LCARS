#!/usr/bin/env bash
# S175 — fast, SCOPED test for the design's DATA PRECONDITIONS (run.sh) and for
# the open questions the brief left unsettled surviving into the PRD (file.sh).
#
# THE MEASUREMENT this guards (lcars-20260814-001): the mockup drew an MBR
# builder in which 11 of 14 KPIs collect AUTOMATICALLY, and the target repo's
# data/config.json carries 19 KPIs with ZERO non-empty aiUpdateInstructions —
# every one manual, an invariant that repo's own ADR-002 enforces on purpose.
# Three tickets and most of a fourth built surfaces the repo can never display.
# Every gate green; the captain could not tell broken from unreachable.
#
# Deliberately NOT the heavy tests/lcars-run.test.sh. Everything here runs over
# run.sh's isolation hooks and file.sh's PRD gate — no worker is ever spawned,
# no token is ever spent, and the whole file finishes in about a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FILE_SH="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

has()    { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
assert_has() { if has "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_no()  { if has "$2" "$3"; then bad "$1 (present but must not be: $2)"; else ok "$1"; fi; }
assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

# --- a mission dir carrying a concept doc ----------------------------------
# The concept doc rides as a mission ATTACHMENT, exactly as the holodeck files
# it. Content is the only thing that matters here.
new_mission() { # [concept-doc-text] -> echoes mission dir
  local d; d="$(mktemp -d "$TMPROOT/m.XXXX")"
  mkdir -p "$d/attachments"
  printf '{ "id": "test-001", "stage": "validate" }\n' > "$d/state.json"
  if [ "$#" -gt 0 ]; then
    printf '%s' "$1" > "$d/attachments/attachment-02.md"
  fi
  echo "$d"
}

CONCEPT_REAL='# MBR builder

## Decisions

- The builder is one screen. (T2)

## Open questions

- What makes a KPI "carried"?
- What do Preview and View actually do?

## DATA PRECONDITIONS

- most KPIs have an automated collection instruction
- at least one prior published month exists

## DECLARED FLOW

`start` → `collect` → `builder`
'

CONCEPT_EMPTY='# Theme toggle

## Decisions

- One button, not two. (T3)

## Open questions

## DATA PRECONDITIONS

## DECLARED FLOW

`board` → `detail`
'

CONCEPT_NONE='# Theme toggle

## Decisions

- One button, not two. (T3)

## DECLARED FLOW

`board` → `detail`
'

hook() { # subcommand mission-dir [env assignments…] -> sets OUT/RC (stderr merged)
  local sub="$1" dir="$2"; shift 2
  OUT="$(LCARS_ATT_TEST_DIR="$dir" "$@" bash "$SCRIPT" "$sub" 2>&1)"; RC=$?
}

hook_out() { # same, but STDOUT ONLY — a warning on stderr is not output
  local sub="$1" dir="$2"; shift 2
  OUT="$(LCARS_ATT_TEST_DIR="$dir" "$@" bash "$SCRIPT" "$sub" 2>/dev/null)"; RC=$?
}

echo "== 1. the design DECLARES — and an empty section declares nothing =="

D="$(new_mission "$CONCEPT_REAL")"
hook preconditions-declared-test "$D"
assert_has "the two declared preconditions are read, in order" \
  "most KPIs have an automated collection instruction" "$OUT"
assert_has "…and the second one too" "at least one prior published month exists" "$OUT"
assert_eq "exactly two, nothing invented" "$(printf '%s' "$OUT" | grep -c .)" "2"

D_EMPTY="$(new_mission "$CONCEPT_EMPTY")"
hook preconditions-declared-test "$D_EMPTY"
assert_eq "an EMPTY section declares NOTHING (behaviour 1)" "$OUT" ""

D_NONE="$(new_mission "$CONCEPT_NONE")"
hook preconditions-declared-test "$D_NONE"
assert_eq "a doc with no section at all declares NOTHING" "$OUT" ""

D_BARE="$(new_mission)"
hook preconditions-declared-test "$D_BARE"
assert_eq "a mission with NO concept doc declares NOTHING (behaviour 6)" "$OUT" ""

# MEASURED against the real brief (lcars-20260814-001/attachments/attachment-02.md):
# every one of its bullets wraps across two physical lines. Counting LINES turns
# each sentence into two half-sentences, and then nothing downstream can copy one
# back verbatim — the Validator's report would never match a declaration, and the
# PRD gate would demand text that does not exist.
CONCEPT_WRAPPED='# MBR builder

## DATA PRECONDITIONS

- most KPIs have an automated collection instruction that is
  non-empty in the config
- at least one prior published month exists
'
D_WRAP="$(new_mission "$CONCEPT_WRAPPED")"
hook preconditions-declared-test "$D_WRAP"
assert_eq "a WRAPPED bullet is ONE precondition, not two" "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_has "…joined back into one sentence" \
  "most KPIs have an automated collection instruction that is non-empty in the config" "$OUT"

CONCEPT_TICKED='# MBR builder

## DATA PRECONDITIONS

  `most KPIs carry an automated collection instruction`
  `at least one prior published month exists`
'
D_TICK="$(new_mission "$CONCEPT_TICKED")"
hook preconditions-declared-test "$D_TICK"
assert_eq "the backtick shape the contract SHOWS yields two, not one" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"

echo "== 2. the Validate prompt — present only when something was declared =="

hook preconditions-block-test "$D"
assert_has "the Validator is told to go and look" "OPEN THE REPOSITORY AND LOOK" "$OUT"
assert_has "…and is given the declared list, numbered" \
  "1. most KPIs have an automated collection instruction" "$OUT"
assert_has "…and is told to name the file and the count" "NAMES THE FILE AND THE COUNT" "$OUT"
assert_has "…and that unchecked is a correct answer" "\`unchecked\` IS A CORRECT ANSWER" "$OUT"
assert_has "…and that a verdict without evidence is not a verdict" \
  "A VERDICT WITHOUT EVIDENCE IS NOT A VERDICT" "$OUT"
assert_has "…and that a fabricated pass is the worst outcome" \
  "a fabricated pass is the single" "$OUT"
assert_has "…and that the harness, not it, composes the question" \
  "the harness composes that question itself" "$OUT"

hook preconditions-block-test "$D_EMPTY"
assert_eq "an EMPTY section adds NOT ONE BYTE to the prompt (behaviour 1)" "$OUT" ""
hook preconditions-block-test "$D_BARE"
assert_eq "a mission with no concept doc adds NOT ONE BYTE (behaviour 6)" "$OUT" ""

echo "== 3. a precondition the repo SATISFIES — recorded, no escalation =="

SAT="$TMPROOT/sat.json"
cat > "$SAT" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied",
   "evidence": "data/config.json: 17 of 19 KPIs have a non-empty aiUpdateInstructions"},
  {"text": "at least one prior published month exists",
   "status": "satisfied",
   "evidence": "data/months/: 4 published month files"}
]}
JSON
D2="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D2" env LCARS_PRECOND_SRC="$SAT"
SCOPE="${OUT#*--- SCOPE ---}"
assert_has "a satisfied precondition is RECORDED with its evidence" \
  "17 of 19 KPIs" "$OUT"
assert_eq "…and raises NO escalation (behaviour 2)" "$(printf '%s' "$SCOPE" | grep -c .)" "0"

echo "== 4. THE REAL CASE — 19 manual KPIs escalate, naming file and count =="

UNSAT="$TMPROOT/unsat.json"
cat > "$UNSAT" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "unsatisfied",
   "evidence": "data/config.json: 0 of 19 KPIs have a non-empty aiUpdateInstructions"},
  {"text": "at least one prior published month exists",
   "status": "satisfied",
   "evidence": "data/months/: 4 published month files"}
]}
JSON
D3="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D3" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "EXACTLY ONE question — the satisfied one is silent (behaviour 3)" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "1"
assert_has "the question quotes the assumption" \
  'This design assumes: "most KPIs have an automated collection instruction"' "$SCOPE"
assert_has "…and NAMES THE FILE" "data/config.json" "$SCOPE"
assert_has "…and NAMES THE COUNT" "0 of 19 KPIs" "$SCOPE"
assert_has "answer (a) build it anyway" "(a) BUILD IT ANYWAY" "$SCOPE"
assert_has "answer (b) cut the parts that depend on it" "(b) CUT the parts that depend on it" "$SCOPE"
assert_has "answer (c) change the repo's data first" "(c) CHANGE THE REPO'S DATA FIRST" "$SCOPE"
assert_has "all three answers are offered plainly, none ranked" \
  "reply (a), (b) or (c)" "$SCOPE"
assert_no "no answer is RECOMMENDED" "recommend" "$SCOPE"
assert_no "no answer is called the SAFE one" "safest" "$SCOPE"
assert_has "the SECOND-ORDER COST is named (C9)" "under-specified" "$SCOPE"
assert_has "…with the measured delta evidence" "no comparison against the previous period" "$SCOPE"
assert_has "…and the measured pull-screen evidence" "N values pulled" "$SCOPE"
assert_has "…and it says the reachable path is the one that suffers" \
  "both under-designed" "$SCOPE"
assert_eq "the question is ONE LINE (the scope.txt shape)" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "1"

echo "== 5. an unmechanisable precondition — UNCHECKED, never a fabricated pass =="

UNCH="$TMPROOT/unch.json"
cat > "$UNCH" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "unchecked",
   "evidence": "no file settles this — it depends on what the collector returns at run time"},
  {"text": "at least one prior published month exists",
   "status": "satisfied",
   "evidence": "data/months/: 4 published month files"}
]}
JSON
D4="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D4" env LCARS_PRECOND_SRC="$UNCH"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "an UNCHECKED precondition raises NO escalation (behaviour 4)" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "0"
assert_has "…but it is REPORTED, not swallowed" "could NOT be checked mechanically" "$OUT"
assert_has "…and explicitly NOT assumed true" "were NOT assumed true" "$OUT"

echo "== 6. THE FABRICATED PASS — a verdict without evidence is not a verdict =="

FAB="$TMPROOT/fab.json"
cat > "$FAB" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied"},
  {"text": "at least one prior published month exists",
   "status": "satisfied", "evidence": ""}
]}
JSON
D5="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D5" env LCARS_PRECOND_SRC="$FAB"
CANON="$(cat "$D5/preconditions.json")"
assert_no "an evidence-free \"satisfied\" does NOT stand as satisfied" '"satisfied"' "$CANON"
assert_has "…it is downgraded to unchecked" '"unchecked"' "$CANON"
assert_has "…and says why" "but no evidence was given at all" "$CANON"

DROP="$TMPROOT/drop.json"
cat > "$DROP" <<'JSON'
{"preconditions": [
  {"text": "at least one prior published month exists",
   "status": "satisfied", "evidence": "data/months/: 4 published month files"}
]}
JSON
D6="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D6" env LCARS_PRECOND_SRC="$DROP"
CANON="$(cat "$D6/preconditions.json")"
assert_has "a precondition the worker LEFT OUT is UNCHECKED, never satisfied" \
  "the Validator did not report on this one" "$CANON"
assert_eq "…and both declared preconditions are still present, in order" \
  "$(printf '%s' "$CANON" | grep -c '"text"')" "2"

D7="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D7" env LCARS_PRECOND_SRC=/nonexistent/nope.json
CANON="$(cat "$D7/preconditions.json")"
assert_eq "a worker that wrote NOTHING yields two UNCHECKED rows, zero passes" \
  "$(printf '%s' "$CANON" | grep -c '"unchecked"')" "2"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "…and no escalation is invented from silence" "$(printf '%s' "$SCOPE" | grep -c .)" "0"

INVENT="$TMPROOT/invent.json"
cat > "$INVENT" <<'JSON'
{"preconditions": [
  {"text": "the repo must be rewritten in Rust", "status": "unsatisfied",
   "evidence": "Cargo.toml: absent"}
]}
JSON
D8="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D8" env LCARS_PRECOND_SRC="$INVENT"
CANON="$(cat "$D8/preconditions.json")"
assert_no "the worker cannot ADD a precondition nobody declared" "rewritten in Rust" "$CANON"

echo "== 7. answered once — the re-run does not re-ask (behaviour 5) =="

D9="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D9" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
Q="$(printf '%s' "$SCOPE" | grep -m1 .)"
"${LCARS_PYTHON_BIN:-python3}" - "$D9/answers.json" "$Q" <<'PY'
import json, sys
json.dump({"stage": "validate", "answer": "(a) build it anyway",
           "questions": [sys.argv[2]]}, open(sys.argv[1], "w"))
PY
hook preconditions-gate-test "$D9" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "the answered precondition is NOT re-asked" "$(printf '%s' "$SCOPE" | grep -c .)" "0"
assert_has "…and the captain's answer is recorded against it" \
  "(a) build it anyway" "$(cat "$D9/preconditions.json")"

echo "== 8. the limit stays visible at Verify (Part C) =="

hook preconditions-verify-test "$D9"
assert_has "Verify names the unreachable design" "UNREACHABLE WITH THIS REPO'S CURRENT DATA" "$OUT"
assert_has "…quoting the assumption" "most KPIs have an automated collection instruction" "$OUT"
assert_has "…and the evidence" "0 of 19 KPIs" "$OUT"
assert_has "…and what he chose" "you answered: (a) build it anyway" "$OUT"
assert_has "…and it repeats the second-order cost" "drawn as the minority case" "$OUT"

hook preconditions-verify-test "$D4"
assert_has "an UNCHECKED precondition also reaches Verify" "NOT CHECKED" "$OUT"

D10="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$D10" env LCARS_PRECOND_SRC="$SAT"
hook preconditions-verify-test "$D10"
assert_eq "an all-satisfied mission's Verify readout is EMPTY (byte-identical)" "$OUT" ""

hook preconditions-verify-test "$D_BARE"
assert_eq "a mission with no preconditions.json prints NOTHING at Verify" "$OUT" ""

echo "== 9. Part D — the brief's open questions survive into the PRD =="

# The gate itself (`lcars_prd_questions_gate`, lcars-init/lcars-common.sh), which
# file.sh runs beside its other PRD section checks. Driven directly so this file
# stays a sub-second scoped suite.
# shellcheck source=../skills/lcars-init/lcars-common.sh
. "$REPO_ROOT/skills/lcars-init/lcars-common.sh"

prd_of() { # extra-sections -> path to a PRD file
  local p; p="$(mktemp "$TMPROOT/prd.XXXX")"
  cat > "$p" <<PRD
# Mission: Test

**Type:** feature
**Goal:** do the thing
**Acceptance Criteria:**
- it works
**Out of Scope:**
- everything else
**Constraints:**
- none
$1
PRD
  echo "$p"
}

gate() { # prd concept… -> sets OUT/RC
  OUT="$(lcars_prd_questions_gate "$@" 2>&1)"; RC=$?
}

CONCEPT_F="$TMPROOT/concept.md";     printf '%s' "$CONCEPT_REAL"  > "$CONCEPT_F"
CONCEPT_NOQ="$TMPROOT/concept-noq.md"; printf '%s' "$CONCEPT_EMPTY" > "$CONCEPT_NOQ"

gate "$(prd_of '')" "$CONCEPT_F"
if [ "$RC" -ne 0 ]; then ok "a PRD that DROPS the brief's open questions is REFUSED (behaviour 7)"
else bad "a PRD that DROPS the brief's open questions was accepted"; fi
assert_has "…and the refusal names the section it wants" \
  "Open questions from the design session" "$OUT"
assert_has "…and quotes a question that went missing" 'What makes a KPI "carried"?' "$OUT"
assert_has "…and names the measured mission it happened on" "lcars-20260814-001" "$OUT"

CARRIED='
## Open questions from the design session

These came from the design brief and are NOT settled.

- STILL OPEN: What makes a KPI "carried"?
- STILL OPEN: What do Preview and View actually do?
'
gate "$(prd_of "$CARRIED")" "$CONCEPT_F"
assert_eq "a PRD carrying both, as questions, is ACCEPTED (behaviour 7)" "$RC" "0"

RESOLVED='
## Open questions from the design session

- RESOLVED with the captain: What makes a KPI "carried"? — a KPI is carried when
  last month published a value and this month has not entered one.
- STILL OPEN: What do Preview and View actually do?
'
gate "$(prd_of "$RESOLVED")" "$CONCEPT_F"
assert_eq "a question RESOLVED during Align, recorded as resolved, is ACCEPTED (behaviour 8)" "$RC" "0"

HALF='
## Open questions from the design session

- STILL OPEN: What makes a KPI "carried"?
'
gate "$(prd_of "$HALF")" "$CONCEPT_F"
if [ "$RC" -ne 0 ]; then ok "a PRD that carries SOME and silently drops the rest is REFUSED"
else bad "a PRD that dropped one of the two open questions was accepted"; fi
assert_has "…naming the one that evaporated" "What do Preview and View actually do?" "$OUT"

# THE MEASURED DEFECT ITSELF: the real prd.md asserted the Carried-pill rule as
# settled fact while the brief still had it open, and left no trace it was ever
# a question. An assertion is not a carried question.
ASSERTED='
**Carried pill:** a KPI is carried when last month published a value and this
month has not entered one.
'
gate "$(prd_of "$ASSERTED")" "$CONCEPT_F"
if [ "$RC" -ne 0 ]; then ok "an open question quietly ASSERTED as fact is REFUSED (the measured defect)"
else bad "the PRD asserted an open question as settled fact and was accepted"; fi

gate "$(prd_of '')" "$CONCEPT_NOQ"
assert_eq "ZERO open questions ⇒ NO section required (behaviour 7, empty-bucket rule)" "$RC" "0"

gate "$(prd_of "$CARRIED")" "$CONCEPT_NOQ"
if [ "$RC" -ne 0 ]; then ok "…and a section invented out of nothing is REFUSED"
else bad "a PRD invented an open-questions section the brief never had"; fi

gate "$(prd_of '')"
assert_eq "a mission with NO concept doc is UNTOUCHED (behaviour 6)" "$RC" "0"

# BOTH homes the contract gives an unsettled thing. `_CONCEPT_CONTRACT` splits
# them ON PURPOSE (ONE HOME EACH): `## Open questions`, and bucket 2 of
# `## WHAT IT MUST DO` — "Implied by the mockup, not yet settled … Write each as
# a QUESTION". Reading only the first carries 2 of the real brief's 14.
CONCEPT_BOTH='# MBR builder

## Open questions

- Does "lock" happen per-bucket, per-month, or both? The mock shows both
  (bucket Unlock + month Lock) — is that the real model?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements

1. (T1) Generate a mock rendering of the builder.

### 2. Implied by the mockup, not yet settled

- "Preview", "View" and "Continue to builder" are drawn — what does each
  actually do?
- A "Carried" badge marks KPIs carried over. What makes a KPI carried?

### 3. Out of scope

- Nothing.
'
CONCEPT_BOTH_F="$TMPROOT/concept-both.md"; printf '%s' "$CONCEPT_BOTH" > "$CONCEPT_BOTH_F"
gate "$(prd_of '')" "$CONCEPT_BOTH_F"
if [ "$RC" -ne 0 ]; then ok "bucket 2's unsettled items are open questions too"
else bad "bucket 2's unsettled items were ignored by the gate"; fi
assert_has "…the Preview/View question is one of them (the measured hole)" \
  "what does each actually do?" "$OUT"
assert_has "…and so is the Carried-badge question" "What makes a KPI carried?" "$OUT"
assert_no "…while a stated REQUIREMENT is not dragged in as a question" \
  "Generate a mock rendering" "$OUT"

MOCKUP="$TMPROOT/attachment-01.html"; printf '<html></html>' > "$MOCKUP"
gate "$(prd_of '')" "$MOCKUP"
assert_eq "an image/mockup-only attachment set is UNTOUCHED" "$RC" "0"

echo "== 10. Part D — an open question that reaches Plan unresolved (behaviour 9) =="

# The PRD's own declaration is what makes a question open at Plan: `STILL OPEN:`
# vs `RESOLVED with the captain:`, the prefixes the Align contract prescribes.
# Nothing here reads a question and guesses whether it is settled.
prd_mission() { # prd-body -> echoes mission dir
  local d; d="$(mktemp -d "$TMPROOT/pm.XXXX")"
  printf '{ "id": "test-001", "stage": "plan" }\n' > "$d/state.json"
  printf '%s' "$1" > "$d/prd.md"
  echo "$d"
}

PRD_OPEN='# Mission: Test

## Open questions from the design session

- STILL OPEN: What do Preview and View actually do?
- RESOLVED with the captain: What makes a KPI "carried"? — last month published, this month has not.
- STILL OPEN: Does the sweep run on open?
'
PD="$(prd_mission "$PRD_OPEN")"
hook open-questions-test "$PD"
assert_eq "only the STILL OPEN ones reach Plan — the resolved one does not" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_has "…the first still-open question" "What do Preview and View actually do?" "$OUT"
assert_no "…and NOT the one Align resolved (behaviour 8)" 'What makes a KPI' "$OUT"

hook plan-open-questions-block-test "$PD"
assert_has "the Planner is shown them, numbered" "1. What do Preview and View actually do?" "$OUT"
assert_has "…and told it MAY decide one" "You MAY decide one" "$OUT"
assert_has "…but never silently" "What you may
NOT do is decide one SILENTLY" "$OUT"
assert_has "…via the S174-shaped declaration on the criterion" '"decides"' "$OUT"
assert_has "…which sits BESIDE the drawnAt declaration, not instead of it" \
  "it does not
replace it" "$OUT"
assert_has "…and it names the measured case" "came out scrambled" "$OUT"

PD_NONE="$(prd_mission '# Mission: Test

**Goal:** x
')"
hook open-questions-test "$PD_NONE"
assert_eq "a PRD with no such section leaves NOTHING open" "$OUT" ""
hook plan-open-questions-block-test "$PD_NONE"
assert_eq "…and adds NOT ONE BYTE to the Plan prompt (behaviour 6)" "$OUT" ""

PLAN_DECIDES="$TMPROOT/plan-decides"
mkdir -p "$PLAN_DECIDES"
printf '{ "id": "test-001", "stage": "verify" }\n' > "$PLAN_DECIDES/state.json"
cat > "$PLAN_DECIDES/plan.json" <<'JSON'
[
  {"id": "t-007", "title": "Preview screen",
   "acceptanceCriteria": [
     {"text": "Preview opens read-only", "drawnAt": "#screen-builder",
      "decides": "What do Preview and View actually do? → Preview opens a read-only render of the month; View navigates to the published page."},
     {"text": "unit tests pass", "notVisual": true}
   ]},
  {"id": "t-008", "title": "Sweep",
   "acceptanceCriteria": ["plain string criterion"]}
]
JSON
hook verify-decided-test "$PLAN_DECIDES"
assert_has "Verify lists what a ticket decided for him (behaviour 9)" "DECIDED FOR YOU" "$OUT"
assert_has "…naming the ticket" "t-007" "$OUT"
assert_has "…and the question with the answer it took" \
  "What do Preview and View actually do? → Preview opens a read-only render" "$OUT"
assert_has "…and saying he was never asked" "YOU WERE NEVER ASKED THESE" "$OUT"
assert_no "…and a notVisual criterion is not dragged in" "unit tests pass" "$OUT"

PLAN_PLAIN="$TMPROOT/plan-plain"
mkdir -p "$PLAN_PLAIN"
printf '[{"id":"t-001","acceptanceCriteria":["a","b"]}]\n' > "$PLAN_PLAIN/plan.json"
hook verify-decided-test "$PLAN_PLAIN"
assert_eq "a plan with no \"decides\" prints NOTHING at Verify (byte-identical)" "$OUT" ""

echo "== 11. FIX ROUND 1 — a fresh tester's inputs, verbatim =="

# THE GOVERNING PRINCIPLE OF THIS ROUND IS **FAIL CLOSED**. `unchecked` is a SAFE
# state: it is reported to the captain and never claimed as a pass. Every
# ambiguity below resolves to `unchecked`/refuse, never to the favourable verdict.

# --- D1: a worker fabricates a pass in one line ---------------------------
# The old rule tested Python truthiness after a whitespace collapse, so ANY
# non-empty scrap of prose supported a verdict.
d1_case() { # evidence-json-fragment
  local f; f="$(mktemp "$TMPROOT/d1.XXXX")"
  cat > "$f" <<JSON
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied", $1},
  {"text": "at least one prior published month exists",
   "status": "satisfied",
   "evidence": "data/months/: 4 published month files"}
]}
JSON
  local d; d="$(new_mission "$CONCEPT_REAL")"
  hook preconditions-gate-test "$d" env LCARS_PRECOND_SRC="$f"
  D1_CANON="$(cat "$d/preconditions.json")"
}

d1_case '"evidence": "ok"'
assert_has "D1 \"ok\" is downgraded to unchecked" "names no file and no count" "$D1_CANON"
assert_no "D1 …and never stands as a pass" '"status": "satisfied",
      "evidence": "ok"' "$D1_CANON"

d1_case '"evidence": "."'
assert_has "D1 \".\" is downgraded" "names no file and no count" "$D1_CANON"

d1_case '"evidence": 19'
assert_has "D1 a bare NUMBER 19 is downgraded" "not a string" "$D1_CANON"

d1_case '"evidence": {"checked": true}'
assert_has "D1 a dict evidence is downgraded" "not a string" "$D1_CANON"
assert_no "D1 …and its Python repr never leaks into the file (D12)" "'checked'" "$D1_CANON"

d1_case '"evidence": ["a", "b"]'
assert_has "D1 a list evidence is downgraded" "not a string" "$D1_CANON"
assert_no "D1 …and its repr never leaks (D12)" "['a'" "$D1_CANON"

d1_case '"evidence": "reviewed the KPI configuration; automation is in place"'
assert_has "D1 fluent prose with no file and no count is downgraded" \
  "names no file and no count" "$D1_CANON"

d1_case '"evidence": "data/config.json: 17 of 19 KPIs carry aiUpdateInstructions"'
assert_has "D1 …but REAL evidence (a path and a count) still supports the pass" \
  '"status": "satisfied"' "$D1_CANON"

d1_case '"evidence": "17 of 19 KPIs carry a non-empty aiUpdateInstructions"'
assert_has "D1 …and a count with no path is enough" '"status": "satisfied"' "$D1_CANON"

# --- D2: duplicate rows, last wins, favourable overwrites honest -----------
DUP="$TMPROOT/dup.json"
cat > "$DUP" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "unsatisfied",
   "evidence": "data/config.json: 0 of 19 KPIs have a non-empty aiUpdateInstructions"},
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied",
   "evidence": "data/config.json: looked again, 19 of 19 fine"}
]}
JSON
DD="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DD" env LCARS_PRECOND_SRC="$DUP"
CANON="$(cat "$DD/preconditions.json")"
SCOPE="${OUT#*--- SCOPE ---}"
assert_has "D2 an honest UNSATISFIED is not overwritten by a later satisfied" \
  '"status": "unsatisfied"' "$CANON"
assert_has "D2 …and the real evidence survives" "0 of 19 KPIs" "$CANON"
assert_eq "D2 …and the escalation still fires" "$(printf '%s' "$SCOPE" | grep -c .)" "1"

DUP2="$TMPROOT/dup2.json"
cat > "$DUP2" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied", "evidence": "data/config.json: 19 of 19 fine"},
  {"text": "most KPIs have an automated collection instruction",
   "status": "unchecked", "evidence": "actually I could not tell"}
]}
JSON
DD2="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DD2" env LCARS_PRECOND_SRC="$DUP2"
CANON="$(cat "$DD2/preconditions.json")"
assert_has "D2 conflicting satisfied/unchecked resolves to UNCHECKED, not the pass" \
  "conflicting verdicts" "$CANON"

DUP3="$TMPROOT/dup3.json"
cat > "$DUP3" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied", "evidence": "data/config.json: 19 of 19 fine"},
  {"text": "most KPIs have an automated collection instruction",
   "status": "satisfied", "evidence": "data/config.json: 19 of 19 fine"}
]}
JSON
DD3="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DD3" env LCARS_PRECOND_SRC="$DUP3"
CANON="$(cat "$DD3/preconditions.json")"
assert_has "D2 IDENTICAL duplicates are fine and still pass" '"status": "satisfied"' "$CANON"

# --- D9: substring collision when absorbing an answer ---------------------
CONCEPT_SUB='# P

## DATA PRECONDITIONS

- KPIs have targets
- KPIs have targets and owners
'
SUBJ="$TMPROOT/sub.json"
cat > "$SUBJ" <<'JSON'
{"preconditions": [
  {"text": "KPIs have targets", "status": "unsatisfied",
   "evidence": "data/config.json: 0 of 19 have a target"},
  {"text": "KPIs have targets and owners", "status": "unsatisfied",
   "evidence": "data/config.json: 0 of 19 have an owner"}
]}
JSON
DS="$(new_mission "$CONCEPT_SUB")"
hook preconditions-gate-test "$DS" env LCARS_PRECOND_SRC="$SUBJ"
SCOPE="${OUT#*--- SCOPE ---}"
LONGQ="$(printf '%s' "$SCOPE" | grep -m1 'targets and owners')"
"${LCARS_PYTHON_BIN:-python3}" - "$DS/answers.json" "$LONGQ" <<'PY'
import json, sys
json.dump({"stage": "validate", "answer": "(b) cut it",
           "questions": [sys.argv[2]]}, open(sys.argv[1], "w"))
PY
hook preconditions-gate-test "$DS" env LCARS_PRECOND_SRC="$SUBJ"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "D9 answering the LONGER question leaves the SHORTER one still asked" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "1"
assert_has "D9 …and it is the shorter one" 'assumes: "KPIs have targets".' "$SCOPE"

# --- D6: the answer is durable across a send-back -------------------------
DR="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DR" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
Q1="$(printf '%s' "$SCOPE" | grep -m1 .)"
"${LCARS_PYTHON_BIN:-python3}" - "$DR/answers.json" "$Q1" <<'PY'
import json, sys
json.dump({"stage": "validate", "answer": "(a) build it anyway",
           "questions": [sys.argv[2]]}, open(sys.argv[1], "w"))
PY
hook preconditions-gate-test "$DR" env LCARS_PRECOND_SRC="$UNSAT"
# validate-advance deletes answers.json; a `lcars feedback` send-back then
# re-enters Validate with NO answers.json at all.
rm -f "$DR/answers.json"
hook preconditions-gate-test "$DR" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "D6 after a send-back the answered precondition is NOT re-asked" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "0"
assert_has "D6 …and the answer is still on file" "(a) build it anyway" \
  "$(cat "$DR/preconditions.json")"
hook preconditions-verify-test "$DR"
assert_has "D6 …and Verify still prints what he chose" \
  "you answered: (a) build it anyway" "$OUT"

# --- D10: the empty-bucket rule on DATA PRECONDITIONS ---------------------
CONCEPT_NONE_BULLET='# P

## DATA PRECONDITIONS

- None — this design assumes nothing of the repo.
'
DN="$(new_mission "$CONCEPT_NONE_BULLET")"
hook_out preconditions-declared-test "$DN"
assert_eq "D10 a forbidden none-bullet is NOT a precondition" "$OUT" ""
hook_out preconditions-block-test "$DN"
assert_eq "D10 …so the Validator is asked to check NOTHING" "$OUT" ""
hook preconditions-declared-test "$DN"
assert_has "D10 …but it does not disengage SILENTLY — it says so on stderr" \
  "an empty section is the heading and nothing under it" "$OUT"

# …while a real precondition that merely STARTS with "none" is untouched.
CONCEPT_NONE_REAL='# P

## DATA PRECONDITIONS

- none of the KPIs are archived
'
DNR="$(new_mission "$CONCEPT_NONE_REAL")"
hook_out preconditions-declared-test "$DNR"
assert_eq "D10 \"none of the KPIs are archived\" IS a real precondition" \
  "$OUT" "none of the KPIs are archived"

# --- D4: the wrap bug in the parser that feeds the PLANNER ----------------
PRD_WRAP='# Mission: Test

## Open questions from the design session

- STILL OPEN: What do Preview, View and Continue to builder actually do — does
  Preview open a read-only render, or the published page?
'
PW="$(prd_mission "$PRD_WRAP")"
hook open-questions-test "$PW"
assert_eq "D4 a WRAPPED still-open bullet is ONE question, not a truncated one" \
  "$(printf '%s' "$OUT" | grep -c .)" "1"
assert_has "D4 …joined across the line break" \
  "does Preview open a read-only render, or the published page?" "$OUT"

# --- D5: the prefix contract in its most natural markdown form ------------
PRD_BOLD='# Mission: Test

## Open questions from the design session

- **STILL OPEN:** What do Preview and View actually do?
'
PB="$(prd_mission "$PRD_BOLD")"
hook open-questions-test "$PB"
assert_eq "D5 a BOLDED lead-in still yields the question" \
  "$(printf '%s' "$OUT" | grep -c .)" "1"
assert_has "D5 …with the markers stripped" "What do Preview and View actually do?" "$OUT"

PRD_NOCOLON='# Mission: Test

## Open questions from the design session

- STILL OPEN What do Preview and View actually do?
'
PNC="$(prd_mission "$PRD_NOCOLON")"
hook open-questions-test "$PNC"
assert_eq "D5 a MISSING COLON still yields the question" \
  "$(printf '%s' "$OUT" | grep -c .)" "1"

PRD_SILENT='# Mission: Test

## Open questions from the design session

- Preview and View: nobody has decided what these do.
- The Carried pill rule is not settled.
'
PSI="$(prd_mission "$PRD_SILENT")"
hook open-questions-test "$PSI"
if [ "$RC" -ne 0 ]; then ok "D5 a non-empty section yielding ZERO questions REFUSES, loudly"
else bad "D5 a non-empty section yielded a silent zero"; fi
assert_has "D5 …and says what it could not parse" "STILL OPEN" "$OUT"

# --- D3: Part D's gate bypassed by the exact failure it exists to stop ----
PRD_QUOTED='# Mission: Test

**Type:** feature
**Goal:** do the thing
**Acceptance Criteria:**
- it works
**Out of Scope:**
- everything else
**Constraints:**
- none

## Background from the design session

> - Does "lock" happen per-bucket, per-month, or both? The mock shows both
>   (bucket Unlock + month Lock) — is that the real model?

**Decision:** month-only.

## Open questions from the design session

None outstanding — all settled during the grill.
'
PQ="$(mktemp "$TMPROOT/prdq.XXXX")"; printf '%s' "$PRD_QUOTED" > "$PQ"
gate "$PQ" "$CONCEPT_BOTH_F"
if [ "$RC" -ne 0 ]; then ok "D3 a question QUOTED elsewhere does not satisfy the section"
else bad "D3 the gate passed on a question quoted outside the section"; fi
assert_has "D3 …and it names what is missing from the section" \
  'Does "lock" happen per-bucket' "$OUT"

# --- D7: a RESOLVED question may be rephrased -----------------------------
CONCEPT_ONE='# P

## Open questions

- What makes a KPI "carried"?
'
CONE="$TMPROOT/concept-one.md"; printf '%s' "$CONCEPT_ONE" > "$CONE"
REPHRASED='
## Open questions from the design session

- RESOLVED with the captain: the carried rule — a KPI counts as carried when the
  previous month published a value and this month has not entered one.
'
gate "$(prd_of "$REPHRASED")" "$CONE"
assert_eq "D7 a RESOLVED question, rephrased, does not kill the filing" "$RC" "0"

NOTHING_TO_REPORT='
## Open questions from the design session

- Nothing to report.
'
gate "$(prd_of "$NOTHING_TO_REPORT")" "$CONE"
if [ "$RC" -ne 0 ]; then ok "D7 …but a section that accounts for NOTHING is still refused"
else bad "D7 a section accounting for nothing was accepted"; fi

# --- the escalation stops overpromising -----------------------------------
DW="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DW" env LCARS_PRECOND_SRC="$UNSAT"
SCOPE="${OUT#*--- SCOPE ---}"
assert_has "W the ASK is at the top, not buried" "DECISION NEEDED" "$SCOPE"
assert_has "W it says the answer is recorded and carried as guidance" \
  "recorded and carried to the later stages as guidance" "$SCOPE"
assert_has "W …and that the harness itself cuts and changes NOTHING" \
  "does not itself cut anything" "$SCOPE"
assert_no "W it no longer claims the harness acts on the letter" "all legitimate;" "$SCOPE"

MULTI="$TMPROOT/multi.json"
cat > "$MULTI" <<'JSON'
{"preconditions": [
  {"text": "most KPIs have an automated collection instruction", "status": "unsatisfied",
   "evidence": "data/config.json: 0 of 19 KPIs have a non-empty aiUpdateInstructions"},
  {"text": "at least one prior published month exists", "status": "unsatisfied",
   "evidence": "data/months/: 0 published month files"}
]}
JSON
DM="$(new_mission "$CONCEPT_REAL")"
hook preconditions-gate-test "$DM" env LCARS_PRECOND_SRC="$MULTI"
SCOPE="${OUT#*--- SCOPE ---}"
assert_eq "W two unsatisfied preconditions ⇒ two questions" \
  "$(printf '%s' "$SCOPE" | grep -c .)" "2"
assert_eq "W …and the shared consequence is stated ONCE, not twice" \
  "$(printf '%s' "$SCOPE" | grep -c 'N values pulled')" "1"
LONGEST="$(printf '%s' "$SCOPE" | awk '{print length}' | sort -rn | head -1)"
if [ "$LONGEST" -lt 1000 ]; then ok "W no single question is a 1,274-character wall ($LONGEST)"
else bad "W a question is still $LONGEST characters"; fi

echo "== 12. FIX ROUND 2 — the LIVE COPILOT DRIVE (four real turns) =="

# PROVENANCE. `tests/fixtures/s175-live/turn-{a,b,c,d}-concept.md` are the
# VERBATIM concept.md files a live `claude-opus-4.8` holodeck wrote through a
# real daemon, grounded on the real DX-Scorecard, on 2026-08-26. Nothing in them
# is authored by this test.
#
# THE MEASUREMENT THAT FORCED THIS ROUND. Run through the extractor as it stood
# after fix round 1: A:0  B:0  C:0  D:3. The feature reached Validate on ONE TURN
# IN THREE of the turns that needed it.
#
#   A — assumes repo data, wrote heading + EOF          -> 0 (legitimately empty)
#   B — assumes nothing, wrote heading + EOF (CORRECT)  -> 0
#   C — assumes repo data, wrote 3 GOOD PLAIN SENTENCES -> 0  ← THE BUG
#   D — assumes repo data, wrote 3 GOOD BACKTICKED LINES-> 3
#
# C is the defect: `items()` opened an item only on a bullet marker or a
# backtick, so three perfectly good sentences were dropped SILENTLY. A human
# reading C's concept.md sees a full section; Validate saw an empty one and the
# whole gate stayed inert.
LIVE="$REPO_ROOT/tests/fixtures/s175-live"

live_mission() { # turn-letter -> echoes mission dir
  local d; d="$(mktemp -d "$TMPROOT/live.XXXX")"
  mkdir -p "$d/attachments"
  printf '{ "id": "test-001", "stage": "validate" }\n' > "$d/state.json"
  cp "$LIVE/turn-$1-concept.md" "$d/attachments/attachment-02.md"
  echo "$d"
}

# --- CURE 1: the extractor accepts PROSE ----------------------------------
LA="$(live_mission a)"; LB="$(live_mission b)"
LC="$(live_mission c)"; LD="$(live_mission d)"

hook_out preconditions-declared-test "$LA"
assert_eq "LIVE A — an empty section yields NOTHING" "$OUT" ""
assert_eq "LIVE A — …and exits clean" "$RC" "0"
hook preconditions-declared-test "$LA"
assert_eq "LIVE A — …and does NOT warn (empty is legitimately empty)" "$OUT" ""

hook_out preconditions-declared-test "$LB"
assert_eq "LIVE B — assumes-nothing yields NOTHING" "$OUT" ""
hook preconditions-declared-test "$LB"
assert_eq "LIVE B — …silently, because there is nothing to say" "$OUT" ""
hook_out preconditions-block-test "$LB"
assert_eq "LIVE B — …and the Validator is asked to check NOTHING" "$OUT" ""

hook_out preconditions-declared-test "$LC"
assert_eq "LIVE C — three PLAIN SENTENCES are three preconditions" \
  "$(printf '%s' "$OUT" | grep -c .)" "3"
assert_has "LIVE C — the collection-mode sentence survives whole" \
  "Each KPI carries a collection mode (automatic vs manual) so the two cohorts can be counted and the list filtered to the automatic set." "$OUT"
assert_has "LIVE C — the timestamp sentence survives whole" \
  "Auto-collected KPIs record a last-refresh timestamp and a last-run outcome (success/failure) per item." "$OUT"
assert_has "LIVE C — the cadence sentence survives whole" \
  'Each auto-collected KPI has a known collection cadence, so "overdue / stale" can be computed against it.' "$OUT"

hook_out preconditions-declared-test "$LD"
assert_eq "LIVE D — three BACKTICKED lines still yield three" \
  "$(printf '%s' "$OUT" | grep -c .)" "3"
assert_has "LIVE D — …and it named a real file, the best line of the drive" \
  "accents.ts" "$OUT"

hook_out preconditions-block-test "$LC"
assert_has "LIVE C — and the Validator is finally asked to check them" \
  "1. Each KPI carries a collection mode" "$OUT"

# --- CURE 1b: FAIL LOUD, never a silent zero (the D5 rule, applied here) ---
CONCEPT_RUBBLE='# P

## DATA PRECONDITIONS

``
---
'
DRB="$(new_mission "$CONCEPT_RUBBLE")"
hook preconditions-declared-test "$DRB"
if [ "$RC" -ne 0 ]; then ok "a NON-EMPTY section that parses to nothing REFUSES"
else bad "a non-empty unparseable section yielded a silent zero"; fi
assert_has "…and says which file it could not read" "attachment-02.md" "$OUT"

# --- REGRESSIONS CURE 1 COULD PLAUSIBLY BREAK -----------------------------
# D4: a wrapped item is ONE item. Cure 1 makes bare lines open items, so the
# continuation rule is exactly what is at risk here.
hook_out preconditions-declared-test "$D_WRAP"
assert_eq "D4 STILL CURED — a wrapped bullet is ONE precondition" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_has "D4 STILL CURED — …joined, not split" \
  "most KPIs have an automated collection instruction that is non-empty in the config" "$OUT"

CONCEPT_WRAP_PROSE='# P

## DATA PRECONDITIONS

- Each KPI carries a collection mode (automatic vs manual) so the two cohorts
  can be counted and the list filtered to the automatic set.
- Auto-collected KPIs record a last-refresh timestamp.
'
DWP="$(new_mission "$CONCEPT_WRAP_PROSE")"
hook_out preconditions-declared-test "$DWP"
assert_eq "an INDENTED continuation still joins, prose or not" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"

# D10: the forbidden none-bullet must not be swallowed as a real precondition
# now that the parser is more permissive.
hook_out preconditions-declared-test "$DN"
assert_eq "D10 STILL CURED — the none-bullet is NOT a precondition" "$OUT" ""
hook preconditions-declared-test "$DN"
assert_has "D10 STILL CURED — …and it still warns" \
  "an empty section is the heading and nothing under it" "$OUT"
assert_eq "D10 STILL CURED — …and an all-none section does NOT refuse" "$RC" "0"

CONCEPT_NONE_BARE='# P

## DATA PRECONDITIONS

None — this design assumes nothing of the repo.
'
DNB="$(new_mission "$CONCEPT_NONE_BARE")"
hook_out preconditions-declared-test "$DNB"
assert_eq "…and the none-line is caught WITHOUT a bullet marker too" "$OUT" ""

hook_out preconditions-declared-test "$DNR"
assert_eq "…while \"none of the KPIs are archived\" is STILL a real precondition" \
  "$OUT" "none of the KPIs are archived"

echo "== 13. FIX ROUND 3 — a third tester attacks the LOOSENED parser =="

# Fix round 2 made the extractor accept prose so a live turn's three good
# sentences stopped vanishing. Loosening it opened four holes, all measured with
# tests/drives/s175-precondition-parser-rig.sh.

# --- D-B: `•` bullets glue into ONE item ----------------------------------
# `_CONCEPT_CONTRACT` uses `•` as its OWN bullet character 52 times, so it is
# heavily modelled in the very prompt the model reads — but the marker-anywhere
# rule covered only ASCII markers, so three indented `•` lines came out as one
# run-on item, and at column 0 they separated but kept a literal "• " prefix in
# the text shipped to the Validator.
CONCEPT_UNICODE_BULLETS='# P

## DATA PRECONDITIONS

  • most KPIs carry an automated collection instruction
  • at least one prior month has been published
  • every KPI belongs to a known bucket
'
DUB="$(new_mission "$CONCEPT_UNICODE_BULLETS")"
hook_out preconditions-declared-test "$DUB"
assert_eq "D-B indented • bullets are THREE items, not one run-on" \
  "$(printf '%s' "$OUT" | grep -c .)" "3"
assert_no "D-B …and the marker is stripped from the text" "•" "$OUT"
assert_has "D-B …the first one, clean" \
  "most KPIs carry an automated collection instruction" "$OUT"

CONCEPT_DASH_BULLETS='# P

## DATA PRECONDITIONS

– each KPI carries an is-automatic flag
— every KPI belongs to a known bucket
'
DDB="$(new_mission "$CONCEPT_DASH_BULLETS")"
hook_out preconditions-declared-test "$DDB"
assert_eq "D-B en/em-dash bullets separate too" "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_has "D-B …with the dash stripped" "each KPI carries an is-automatic flag" "$OUT"

# --- D-C: sub-headings become preconditions -------------------------------
# The SIBLING parser (`_md_items`) already closes items on a heading — its S128
# D5 fix. This regressed that lesson next door. The irony the tester flagged:
# the rewritten contract introduces a SHAPE/VALUES split, so a model expressing
# that split as sub-headings poisons its own section.
CONCEPT_SUBHEADS='# P

## DATA PRECONDITIONS

### Shape

- each KPI carries an is-automatic flag

### Values

- most KPIs are currently on automatic
'
DSH="$(new_mission "$CONCEPT_SUBHEADS")"
hook_out preconditions-declared-test "$DSH"
assert_eq "D-C sub-headings are NOT preconditions" "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_no "D-C …\"### Shape\" is not sent to the Validator" "Shape" "$OUT"
assert_no "D-C …nor \"### Values\"" "Values" "$OUT"
assert_has "D-C …and the real bullets survive" \
  "each KPI carries an is-automatic flag" "$OUT"

# --- D-D: the furniture rule had an indentation hole ----------------------
# Furniture was tested at FLUSH time on the whole item, so an INDENTED furniture
# line was absorbed as a continuation before the test could see it.
CONCEPT_INDENTED_RULE='# P

## DATA PRECONDITIONS

- most KPIs carry an automated instruction
  ---
'
DIR2="$(new_mission "$CONCEPT_INDENTED_RULE")"
hook_out preconditions-declared-test "$DIR2"
assert_eq "D-D an indented --- is not absorbed into the sentence" \
  "$OUT" "most KPIs carry an automated instruction"

CONCEPT_FENCE='# P

## DATA PRECONDITIONS

- each KPI has aiUpdateInstructions
  ```json
  {"id": "x", "aiUpdateInstructions": ""}
  ```
'
DFC="$(new_mission "$CONCEPT_FENCE")"
hook_out preconditions-declared-test "$DFC"
assert_eq "D-D a fenced block yields NO precondition of its own" \
  "$(printf '%s' "$OUT" | grep -c .)" "1"
assert_no "D-D …the JSON never becomes a thing to check against the repo" \
  "aiUpdateInstructions\": \"\"" "$OUT"

# --- D-E: the small ones --------------------------------------------------
CONCEPT_BOM="$(printf '\xef\xbb\xbf## DATA PRECONDITIONS\n\n- most KPIs carry an automated instruction\n')"
DBOM="$(new_mission "$CONCEPT_BOM")"
hook_out preconditions-declared-test "$DBOM"
assert_eq "D-E a BOM on the heading line no longer silences the section" \
  "$OUT" "most KPIs carry an automated instruction"

CONCEPT_ORDINAL='# P

## DATA PRECONDITIONS

1990. the year field exists on every record
'
DORD="$(new_mission "$CONCEPT_ORDINAL")"
hook_out preconditions-declared-test "$DORD"
assert_has "D-E \"1990.\" is content, not a list marker" "1990." "$OUT"

CONCEPT_ORDERED='# P

## DATA PRECONDITIONS

1. each KPI carries an is-automatic flag
2. most KPIs are currently on automatic
'
DORL="$(new_mission "$CONCEPT_ORDERED")"
hook_out preconditions-declared-test "$DORL"
assert_eq "D-E …while a real 1./2. ordered list still separates" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"
assert_no "D-E …with its marker stripped" "1." "$OUT"

CONCEPT_CODESPAN='# P

## DATA PRECONDITIONS

`aiUpdateInstructions` is non-empty on most KPIs
'
DCS="$(new_mission "$CONCEPT_CODESPAN")"
hook_out preconditions-declared-test "$DCS"
assert_eq "D-E an inline code span leaves no stray backtick" \
  "$OUT" "\`aiUpdateInstructions\` is non-empty on most KPIs"

CONCEPT_BLANKGAP='# P

## DATA PRECONDITIONS

- most KPIs carry an automated collection instruction

  at least one prior month has been published
'
DBG="$(new_mission "$CONCEPT_BLANKGAP")"
hook_out preconditions-declared-test "$DBG"
assert_eq "D-E a BLANK LINE closes an item — two preconditions, not one" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"

# --- turn D must still round-trip, backticks and all ----------------------
hook_out preconditions-declared-test "$LD"
assert_eq "LIVE D still yields three after all of the above" \
  "$(printf '%s' "$OUT" | grep -c .)" "3"
assert_has "LIVE D …and its whole-line backticks are still unwrapped" \
  "each KPI record carries an is-automatic (vs manual) collection flag" "$OUT"

# --- ACCEPTED, DOCUMENTED LIMIT ------------------------------------------
# Column-0 wrapped PROSE splits into fragments. Deliberate: the alternative is
# dropping the section, which is what fix round 2 existed to stop. Turn C's real
# prose was unwrapped single long lines, so live evidence neither supports nor
# refutes it. Pinned so a future round changes it ON PURPOSE, not by accident.
CONCEPT_COL0_WRAP='# P

## DATA PRECONDITIONS

Each KPI carries a collection mode so the two cohorts can be counted
and the list filtered to the automatic set.
'
DCW="$(new_mission "$CONCEPT_COL0_WRAP")"
hook_out preconditions-declared-test "$DCW"
assert_eq "KNOWN LIMIT: column-0 wrapped prose splits (indent it, or one line)" \
  "$(printf '%s' "$OUT" | grep -c .)" "2"

echo "== 10. Part E — the PROMPT and the GATE read the SAME brief sections =="

# ANTI-DRIFT (S176). MEASURED: skills/lcars-file/SKILL.md told the Align agent
# the brief has "a `## Open questions` section" — SINGULAR — while
# `lcars_concept_open_questions` reads TWO homes: `## Open questions` AND bucket
# 2 of `## WHAT IT MUST DO` ("Implied by the mockup, not yet settled"). So an
# agent OBEYING our own prompt carried 2 questions and the gate demanded 14.
# The agent could not pass by following our instructions.
#
# This already happened once: an earlier round taught the PARSER to read both
# and never updated the PROMPT. So the section names below are not typed here —
# they are EXTRACTED FROM THE GATE'S OWN SOURCE. Teach the gate a third home and
# this test fails until SKILL.md names it too; rename one and it fails the same
# way. A "keep these in sync" comment is what we had, and it did not hold.
QGATE_SRC="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
SKILL_MD="$REPO_ROOT/skills/lcars-file/SKILL.md"

QSECTIONS="$(python3 - "$QGATE_SRC" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# the body of lcars_concept_open_questions, and only that
body = src.split("lcars_concept_open_questions() {", 1)[1].split("\nS175_PY\n", 1)[0]
names = []
m = re.search(r'^HEAD\s*=\s*"([^"]+)"', body, re.M)
if m:
    names.append(m.group(1))
names += re.findall(r'section\(\s*\w+\s*,\s*"([^"]+)"\s*\)', body)
out, seen = [], set()
for n in names:
    n = re.sub(r"^\d+[.)]\s*", "", n).strip()   # "2. Implied by…" -> "Implied by…"
    if n.lower() in seen:
        continue
    seen.add(n.lower())
    out.append(n)
sys.stdout.write("\n".join(out))
PY
)"

QCOUNT="$(printf '%s\n' "$QSECTIONS" | grep -c .)"
# A parse that found nothing would pass every assertion below vacuously.
if [ "$QCOUNT" -ge 2 ]; then
  ok "the gate's own source names $QCOUNT brief section(s) it reads"
else
  bad "could not extract the gate's section names from lcars-common.sh (got $QCOUNT)"
fi

while IFS= read -r QS; do
  [ -n "$QS" ] || continue
  if grep -qF "$QS" "$SKILL_MD"; then
    ok "SKILL.md names '$QS' — the prompt and the gate agree"
  else
    bad "DRIFT: the gate reads '$QS' but skills/lcars-file/SKILL.md never names it — an agent obeying the prompt cannot pass the gate"
  fi
done <<EOF
$QSECTIONS
EOF

# …and the prompt must not still describe the brief as having ONE such section.
if grep -q 'it has a `## Open questions` section with anything under it' "$SKILL_MD"; then
  bad "SKILL.md still describes a SINGLE open-questions section (the measured drift)"
else
  ok "SKILL.md no longer describes a single open-questions section"
fi

echo
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
