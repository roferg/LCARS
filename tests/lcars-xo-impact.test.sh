#!/usr/bin/env bash
#
# Tests for THE TWO-PART SCORE (Session 216): impact x outcome, graded the way
# the captain grades a verify pass himself, with the reasoning written down.
#
# His framework IS the score (verify-pass-dev.md, rulings Q1 and the last word):
#
#   BEFORE LOOKING  each requirement gets an IMPACT  high | medium | low
#   AFTER LOOKING   each one is  worked | didn't | couldn't check
#   LOW     a high one didn't work  OR  a high one couldn't be checked
#   MEDIUM  every high one worked; a medium one didn't or couldn't be checked
#   HIGH    every high + medium one worked (low ones never move it)
#
# Research only ADDS, beside his grade: a core state (met / broken /
# unverified), an alternative reading when a risk-based reviewer would read it
# differently, and a flag when small things pile up. None of it moves the score.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py     — the derivation, reasons, why-this-grade
#   skills/lcars-xo/xo-criteria.py  — the contract (bold-label PRD criteria)
#
# ZERO SPEND. No worker, no browser.
#
# Usage: bash tests/lcars-xo-impact.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
CRITERIA="${LCARS_XO_CRITERIA_PY:-$REPO_ROOT/skills/lcars-xo/xo-criteria.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A four-item contract: two PRD items and two plan items.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "the health bar is on screen and drops when you are hit", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "the health bar is red", "source": "prd", "primary": true},
  {"id": "t-1-ac1", "text": "the bar sits in the top right corner", "source": "plan", "primary": false},
  {"id": "t-1-ac2", "text": "the bar has a one pixel border", "source": "plan", "primary": false}
 ]}
C

# row <id> <impact|-> <status> [extra json] — one ledger row, with a shot for
# met/gap so the citation guards leave the status alone.
row() {
  local id="$1" imp="$2" st="$3" extra="${4:-}"
  local s=""
  [ "$st" != "untested" ] && s='"shot": "shot-01", "evidence": "picture",'
  local i=""
  [ "$imp" != "-" ] && i="\"impact\": \"$imp\", \"impactWhy\": \"it is why $id exists\","
  printf '{"id": "%s", %s "status": "%s", %s "note": "saw it", "reason": "Impact %s because it matters. I tried looking at shot-01; I saw the thing (evidence: shot-01). Outcome: %s."%s}' \
    "$id" "$i" "$st" "$s" "$imp" "$st" "${extra:+, $extra}"
}

# verdict <name> <worker-score> <row>... — write a worker verdict file.
verdict() {
  local name="$1" ws="$2"; shift 2
  local rows="" r
  for r in "$@"; do rows="${rows:+$rows, }$r"; done
  printf '{"score": "%s", "summary": "What I found.", "criteria": [%s], "gaps": []}\n' \
    "$ws" "$rows" >"$TMPROOT/$name.worker.json"
}

# run <name> [criteria] — score it; leaves <name>/verdict.json, report.md, out.txt
run() {
  local name="$1" crit="${2:-$TMPROOT/criteria.json}"
  mkdir -p "$TMPROOT/$name"
  "$PY" "$SCOREPY" "$TMPROOT/$name.worker.json" "$crit" "$TMPROOT/$name/verdict.json" \
    >"$TMPROOT/$name/out.txt" 2>"$TMPROOT/$name/err.txt"
}
v() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print("" if d is None else d)' "$TMPROOT/$1/verdict.json" "$2" 2>/dev/null; }
score() { v "$1" score; }

echo "B1. a high-impact criterion that DIDN'T work → LOW, whatever else passed"
verdict b1 high "$(row prd-1 high gap)" "$(row prd-2 medium met)" \
  "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low met)"
run b1
check "B1. score is LOW" "[ \"\$(score b1)\" = low ]"
check "B1. core is broken" "[ \"\$(v b1 core)\" = broken ]"
check "B1. the why-this-grade paragraph opens with the grade and the rule" \
  "v b1 whyThisGrade | grep -q '^LOW because'"
check "B1. …and names the point of the mission that did not work" \
  "v b1 whyThisGrade | grep -q 'health bar is on screen and drops'"
check "B1. the report carries the why-this-grade paragraph" \
  "grep -q 'Why this grade' '$TMPROOT/b1/report.md' && grep -q 'LOW because' '$TMPROOT/b1/report.md'"

echo "B2. a high-impact criterion nobody could CHECK → LOW, and it says so"
verdict b2 medium "$(row prd-1 high untested '"couldNotCheck": "unreachable"')" \
  "$(row prd-2 medium met)" "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low met)"
run b2
check "B2. score is LOW" "[ \"\$(score b2)\" = low ]"
check "B2. core is unverified (not broken — nobody saw it fail)" "[ \"\$(v b2 core)\" = unverified ]"
check "B2. the reasoning says it could not check the point of the mission" \
  "v b2 whyThisGrade | grep -qi 'could not check the point of the mission'"
check "B2. the couldn't-check sub-reason rides the ledger row" \
  "[ \"\$(v b2 criteria.0.couldNotCheck)\" = unreachable ]"
check "B2. the derivation (the card's one line) says so too" \
  "v b2 derivation | grep -qi 'could not check the point of the mission'"

echo "B3. all high worked + one medium didn't → MEDIUM, naming the known issue"
verdict b3 medium "$(row prd-1 high met)" "$(row prd-2 medium gap)" \
  "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low met)"
run b3
check "B3. score is MEDIUM" "[ \"\$(score b3)\" = medium ]"
check "B3. core is met" "[ \"\$(v b3 core)\" = met ]"
check "B3. the paragraph reads as go-with-known-issues and names the issue" \
  "v b3 whyThisGrade | grep -q 'Known issues shipping with it' && v b3 whyThisGrade | grep -q 'health bar is red'"
check "B3. no alternative reading — a medium that DIDN'T work is a real known issue" \
  "[ -z \"\$(v b3 altReading)\" ]"

echo "B3b. all high + medium worked, a low one didn't → HIGH"
verdict b3b high "$(row prd-1 high met)" "$(row prd-2 medium met)" \
  "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low gap)"
run b3b
check "B3b. score is HIGH — polish never moves the grade" "[ \"\$(score b3b)\" = high ]"
check "B3b. the paragraph counts the polish it did not count" \
  "v b3b whyThisGrade | grep -q 'Polish noted, not counted: 1'"
check "B3b. no pile-up flag for one small thing" "[ -z \"\$(v b3b polishFlag)\" ]"

echo "B4. nothing checkable / zero criteria → LOW (never ship as is)"
verdict b4 high "$(row prd-1 medium untested)" "$(row prd-2 medium untested)" \
  "$(row t-1-ac1 low untested)" "$(row t-1-ac2 low untested)"
run b4
check "B4. every item couldn't-check, even with no high one → LOW" "[ \"\$(score b4)\" = low ]"
cat >"$TMPROOT/empty-criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [], "criteria": []}
C
printf '{"score": "high", "summary": "Looks fine.", "criteria": [], "gaps": []}\n' >"$TMPROOT/b4z.worker.json"
run b4z "$TMPROOT/empty-criteria.json"
check "B4. zero criteria in the contract and none rated → LOW, not malformed" \
  "[ \"\$(score b4z)\" = low ] && ! grep -q MALFORMED '$TMPROOT/b4z/out.txt'"
check "B4. …and it says there was nothing on the list to check" \
  "v b4z whyThisGrade | grep -qi 'nothing on your list'"

echo "B5. a criterion with no impact → treated as HIGH, and the reasoning says so"
verdict b5 high "$(row prd-1 - gap)" "$(row prd-2 medium met)" \
  "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low met)"
run b5
check "B5. the missing impact counts as high → a gap makes it LOW" "[ \"\$(score b5)\" = low ]"
check "B5. the row records impact high and that it was assumed" \
  "[ \"\$(v b5 criteria.0.impact)\" = high ] && [ \"\$(v b5 criteria.0.impactAssumed)\" = True ]"
check "B5. the paragraph says an impact was not given and counted as high" \
  "v b5 whyThisGrade | grep -qi 'no impact was given' "

echo "B6. every criterion carries a non-empty reason"
printf '{"score": "high", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "note": "saw it"},
 {"id": "prd-2", "impact": "medium", "status": "met", "shot": "shot-01", "note": "ok", "reason": "the health bar is red"},
 {"id": "t-1-ac1", "impact": "medium", "status": "met", "shot": "shot-01", "note": "ok", "reason": "   "}
], "gaps": []}\n' >"$TMPROOT/b6.worker.json"
run b6
check "B6. every ledger row (including the never-rated one) has a non-empty reason" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"criteria\"] and all(str(c.get(\"reason\") or \"\").strip() for c in d[\"criteria\"]) else 1)' '$TMPROOT/b6/verdict.json'"
check "B6. a missing reason gets the honest fallback saying none was given" \
  "v b6 criteria.0.reason | grep -qi 'no reason was given'"
check "B6. a reason that only restates the criterion is not a reason" \
  "v b6 criteria.1.reason | grep -qi 'no reason was given'"
check "B6. a worker reason is kept as written" \
  "v b1 criteria.0.reason | grep -q 'I tried looking at shot-01'"
check "B6. the report lists the reasoning item by item" \
  "grep -q 'I tried looking at shot-01' '$TMPROOT/b1/report.md'"

echo "B9. the worker's proposed score disagreeing with the table → table wins"
check "B9. B1: worker said HIGH, table says LOW, disagreement recorded" \
  "[ \"\$(v b1 workerScore)\" = high ] && [ \"\$(v b1 scoreDisagreed)\" = True ] \
   && grep -q '^DISAGREED.yes' '$TMPROOT/b1/out.txt' && grep -q '^SCORE.low' '$TMPROOT/b1/out.txt'"

echo "B11. worker ids that are not in the contract are not evidence"
printf '{"score": "high", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "note": "ok"},
 {"id": "prd-2", "impact": "high", "status": "met", "shot": "shot-01", "note": "ok"}
], "gaps": []}\n' >"$TMPROOT/b11.worker.json"
run b11 "$TMPROOT/empty-criteria.json"
check "B11. invented prd-1/prd-2 against an empty contract → LOW, not HIGH" \
  "[ \"\$(score b11)\" = low ]"
check "B11. …and they are not in the ledger" \
  "[ \"\$(v b11 counts.met)\" = 0 ]"
check "B11. …and a note says they were not on the list" \
  "v b11 ledgerNotes | grep -q 'not on the list'"
printf '{"score": "high", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "note": "ok"},
 {"id": "prd-2", "impact": "medium", "status": "met", "shot": "shot-01", "note": "ok"},
 {"id": "t-1-ac1", "impact": "medium", "status": "met", "shot": "shot-01", "note": "ok"},
 {"id": "t-1-ac2", "impact": "low", "status": "met", "shot": "shot-01", "note": "ok"},
 {"id": "made-up-9", "impact": "high", "status": "met", "shot": "shot-01", "note": "ok"}
], "gaps": []}\n' >"$TMPROOT/b11b.worker.json"
run b11b
check "B11. an extra invented id beside a full contract is dropped from the counts" \
  "[ \"\$(v b11b counts.met)\" = 4 ] && [ \"\$(score b11b)\" = high ]"

echo "B12. MEDIUM caused ONLY by a medium couldn't-check → an alternative reading"
verdict b12 medium "$(row prd-1 high met)" "$(row prd-2 medium untested '"couldNotCheck": "unobservable"')" \
  "$(row t-1-ac1 medium met)" "$(row t-1-ac2 low met)"
run b12
check "B12. the grade stays MEDIUM (his table)" "[ \"\$(score b12)\" = medium ]"
check "B12. an altReading is recorded beside it" \
  "v b12 altReading | grep -qi 'risk-based reviewer might sign this off'"
check "B12. no altReading on a HIGH" "[ -z \"\$(v b3b altReading)\" ]"
check "B12. no altReading on a LOW" "[ -z \"\$(v b1 altReading)\" ]"

echo "B13. lots of small things → a flag, never a grade change"
cat >"$TMPROOT/many-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "the point", "source": "prd", "primary": true},
  {"id": "l1", "text": "polish one", "source": "plan"}, {"id": "l2", "text": "polish two", "source": "plan"},
  {"id": "l3", "text": "polish three", "source": "plan"}, {"id": "l4", "text": "polish four", "source": "plan"},
  {"id": "l5", "text": "polish five", "source": "plan"}
 ]}
C
verdict b13 high "$(row prd-1 high met)" "$(row l1 low gap)" "$(row l2 low gap)" \
  "$(row l3 low gap)" "$(row l4 low gap)" "$(row l5 low gap)"
run b13 "$TMPROOT/many-criteria.json"
check "B13. five low gaps → still HIGH" "[ \"\$(score b13)\" = high ]"
check "B13. …with the pile-up flag" "v b13 polishFlag | grep -qi 'lots of small things'"
check "B13. the pill numbers are recorded: checked 6 of 6" \
  "[ \"\$(v b13 counts.met)\" = 1 ] && [ \"\$(v b13 counts.gap)\" = 5 ]"

echo "B14. the S210/S211 guards still decide the OUTCOME the table reads"
printf '{"score": "high", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "note": "looked fine", "reason": "Impact high because it is the point. I tried looking; I saw it. Outcome: worked."}
], "gaps": []}\n' >"$TMPROOT/b14.worker.json"
cat >"$TMPROOT/one-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [{"id": "prd-1", "text": "the point", "source": "prd", "primary": true}]}
C
run b14 "$TMPROOT/one-criteria.json"
check "B14. a high MET with no shot is downgraded to couldn't-check → LOW" \
  "[ \"\$(score b14)\" = low ] && [ \"\$(v b14 criteria.0.status)\" = untested ]"
check "B14. …and its reason no longer claims it worked" \
  "! v b14 criteria.0.reason | grep -q 'Outcome: worked'"

echo "B10. xo-criteria.py reads a bold-label PRD section"
m10="$TMPROOT/bold"; mkdir -p "$m10"
cat >"$m10/prd.md" <<'P'
# Mission: Thing

**Type:** feature
**Goal:** do the thing
**Acceptance Criteria:**
- the first screen shows a card
- the second screen has a progress bar
**Out of Scope:**
- anything in production
**Constraints:**
- stay local
P
"$PY" "$CRITERIA" "$m10" "$m10/criteria.json" >/dev/null
check "B10. two criteria read from under **Acceptance Criteria:**" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"criteria\"]; sys.exit(0 if [c[\"text\"] for c in d]==[\"the first screen shows a card\",\"the second screen has a progress bar\"] else 1)' '$m10/criteria.json'"
m10b="$TMPROOT/heading"; mkdir -p "$m10b"
printf '# T\n\n## Acceptance criteria\n- one\n- two\n\n## Out of scope\n- three\n' >"$m10b/prd.md"
"$PY" "$CRITERIA" "$m10b" "$m10b/criteria.json" >/dev/null
check "B10. a heading PRD reads exactly as before" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"criteria\"]; sys.exit(0 if [c[\"text\"] for c in d]==[\"one\",\"two\"] else 1)' '$m10b/criteria.json'"
m10c="$TMPROOT/boldsuccess"; mkdir -p "$m10c"
printf '# T\n\n**Success criteria**\n1. alpha\n2. beta\n\n**Notes:**\n- not me\n' >"$m10c/prd.md"
"$PY" "$CRITERIA" "$m10c" "$m10c/criteria.json" >/dev/null
check "B10. a bold label with no colon, numbered list, stops at the next label" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"criteria\"]; sys.exit(0 if [c[\"text\"] for c in d]==[\"alpha\",\"beta\"] else 1)' '$m10c/criteria.json'"

echo "B15. the First Officer's report leads with WHY THIS GRADE when it was recorded"
REPORTPY="$REPO_ROOT/skills/lcars-xo/xo-report.py"
md="$TMPROOT/missions"; mkdir -p "$md/m-new" "$md/m-old"
for m in m-new m-old; do
  printf '{"id":"%s","title":"health bar","issue":16,"stage":"verify","numberOne":{"status":"engaged","score":"low"}}\n' "$m" >"$md/$m/state.json"
done
printf '{"at":"2026-09-19T01:00:00Z","action":"scored","score":"low","why":"the worker summary","status":"engaged","whyThisGrade":"LOW because something that is the point of the mission did not work."}\n' >"$md/m-new/number-one.jsonl"
printf '{"at":"2026-09-19T01:00:00Z","action":"scored","score":"low","why":"an older summary","status":"engaged"}\n' >"$md/m-old/number-one.jsonl"
"$PY" "$REPORTPY" "$md" "$TMPROOT/seen.json" --all --format text >"$TMPROOT/fo.txt" 2>&1
check "B15. a new scored entry says why this grade" \
  "grep -q 'LOW because something that is the point' '$TMPROOT/fo.txt'"
check "B15. an old scored entry reads exactly as before" \
  "grep -q 'an older summary' '$TMPROOT/fo.txt'"
check "B15. the scorer hands the paragraph to the shell (GRADE_WHY) for the journal" \
  "grep -q '^GRADE_WHY.LOW because' '$TMPROOT/b1/out.txt' && grep -q '^CORE.broken' '$TMPROOT/b1/out.txt'"

echo
printf 'lcars xo-impact: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
