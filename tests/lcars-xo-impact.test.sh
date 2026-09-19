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
check "B3b. the paragraph names the small thing that DIDN'T work, and that it does not count" \
  "v b3b whyThisGrade | grep -q \"1 smaller item didn't work, and it doesn't change the grade: the bar has a one pixel border\""
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

# ─── S216 fix round 1 — the tester's three REAL looks, copied in as fixtures ──
# tests/fixtures/xo-s216/: the health-bar mission's contract and the finished
# verdicts of two Copilot looks and one Claude look at the same build. Each is
# turned back into the worker verdict that produced it (same rows, same
# impacts, same quotes) and scored again, so these tests read the sentences
# the captain would read on those real looks.
FX="$REPO_ROOT/tests/fixtures/xo-s216"
# realrun <name> <fixture|file> [impacts.json] [engine] [mutate-python]
# realrun <name> <fixture> [impacts] [engine] [mutation] [named]
# With `named`, every test-cited row cites a NAMED test case instead of the
# file-level line the live look saw (S216 fix round 2, T1) — for the checks
# that are about something other than the test-citation rule.
realrun() {
  local name="$1" src="$2" imp="${3:-}" eng="${4:-}" mut="${5:-}" named="${6:-}"
  [ -f "$src" ] || src="$FX/$src-verdict.json"
  mkdir -p "$TMPROOT/$name"
  "$PY" - "$src" "$TMPROOT/$name.worker.json" "$TMPROOT/$name.tests.json" "$mut" "$named" <<'PYX'
import json, sys
src, wout, tout, mut, named = sys.argv[1:6]
d = json.load(open(src))
keep = ("id", "text", "status", "note", "evidence", "testQuote", "shot",
        "impact", "impactWhy", "reason", "couldNotCheck", "workaround", "tries")
rows = [{k: c[k] for k in keep if k in c} for c in d["criteria"]]
if named:
    for c in rows:
        if c.get("testQuote"):
            c["testQuote"] = "✓ src/game.test.ts > %s is covered" % c["id"]
w = {"score": d.get("workerScore") or d["score"], "summary": d["summary"],
     "criteria": rows, "gaps": d.get("gaps") or []}
if mut:
    exec(mut)
json.dump(w, open(wout, "w"))
quotes = sorted(set(c["testQuote"] for c in rows if c.get("testQuote")))
json.dump({"ran": True, "outcome": "passed", "exitCode": 0, "command": "npx vitest run",
           "durationSeconds": 4, "outputTail": "\n".join(quotes) + "\n"}, open(tout, "w"))
PYX
  LCARS_XO_ENGINE="$eng" "$PY" "$SCOREPY" "$TMPROOT/$name.worker.json" "$FX/criteria.json" \
    "$TMPROOT/$name/verdict.json" "" "$TMPROOT/$name.tests.json" ${imp:+"$imp"} \
    >"$TMPROOT/$name/out.txt" 2>"$TMPROOT/$name/err.txt"
}

echo "R1 (D1). HIGH with 7 items nobody could check says so — never 'everything else worked'"
realrun c2 copilot-2 "" "" "" named
check "R1. copilot-2 is still HIGH (his table: those 7 are low)" "[ \"\$(score c2)\" = high ]"
check "R1. why-this-grade no longer claims everything else worked" \
  "! v c2 whyThisGrade | grep -q 'everything else you asked for, worked'"
check "R1. …it says 7 smaller items could not be checked and do not change the grade" \
  "v c2 whyThisGrade | grep -q \"7 smaller items I could not check, and they don't change the grade\""
check "R1. …and names them in plain words (not ids only) — at most three, then how many more" \
  "v c2 whyThisGrade | grep -q 'DEV_HP_BAR_WIDTH' && v c2 whyThisGrade | grep -q 'and 4 more — see the list'"
check "R1. …and never calls an unchecked item one that did not work" \
  "! v c2 whyThisGrade | grep -qi \"didn't work\" && ! v c2 whyThisGrade | grep -q 'Polish noted'"
verdict r1b high "$(row prd-1 high met)" "$(row prd-2 medium met)" \
  "$(row t-1-ac1 low gap)" "$(row t-1-ac2 low untested)"
run r1b
check "R1. a low that didn't work and a low nobody checked are said apart" \
  "v r1b whyThisGrade | grep -q \"1 smaller item didn't work, and it doesn't change the grade: the bar sits in the top right corner\" \
   && v r1b whyThisGrade | grep -q \"1 smaller item I could not check, and it doesn't change the grade: the bar has a one pixel border\""

echo "R2 (D2). the headline says worked / didn't / couldn't check truthfully"
check "R2. copilot-2's headline no longer says 7 small things did not work" \
  "! v c2 derivation | grep -q 'did not' && ! v c2 derivation | grep -qi \"didn't\""
check "R2. …it says 7 smaller items could not be checked" \
  "v c2 derivation | grep -q '7 smaller items I could not check'"
check "R2. the score word's meaning does not say only polish is left" \
  "! v c2 scoreMeaning | grep -q 'only polish is left' && v c2 scoreMeaning | grep -q 'could not check'"
check "R2. a low that didn't work is said as didn't work in the headline" \
  "v r1b derivation | grep -q \"1 smaller item didn't work\" && v r1b derivation | grep -q '1 smaller item I could not check'"

echo "R3 (D3). a MEDIUM's known issue names the FAULT, not the requirement"
cat >"$TMPROOT/two-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "the health bar is on screen and drops when you are hit", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "the health bar is red", "source": "prd", "primary": true}]}
C
printf '{"score": "medium", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "evidence": "picture", "note": "the bar drops when hit", "reason": "r"},
 {"id": "prd-2", "impact": "medium", "status": "gap", "shot": "shot-02", "evidence": "picture", "note": "the bar is drawn purple", "reason": "r"}
], "gaps": [{"criterion": "prd-2", "kind": "contradiction", "title": "The bar is the wrong colour", "expected": "a red bar", "saw": "a purple bar", "shots": ["shot-02"]}]}\n' >"$TMPROOT/r3.worker.json"
run r3 "$TMPROOT/two-criteria.json"
check "R3. with a recorded finding: expected vs seen, in one sentence" \
  "v r3 whyThisGrade | grep -q 'The bar is the wrong colour — you asked for a red bar; the build gives a purple bar (prd-2)'"
printf '{"score": "medium", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "evidence": "picture", "note": "ok", "reason": "r"},
 {"id": "prd-2", "impact": "medium", "status": "gap", "shot": "shot-02", "evidence": "picture", "note": "the bar is drawn purple.", "reason": "r"}
], "gaps": []}\n' >"$TMPROOT/r3b.worker.json"
run r3b "$TMPROOT/two-criteria.json"
check "R3. with only the row's own observation: that observation" \
  "v r3b whyThisGrade | grep -q \"the health bar is red — didn't work: the bar is drawn purple (prd-2)\""
printf '{"score": "medium", "summary": "s", "criteria": [
 {"id": "prd-1", "impact": "high", "status": "met", "shot": "shot-01", "evidence": "picture", "note": "ok", "reason": "r"},
 {"id": "prd-2", "impact": "medium", "status": "gap", "shot": "shot-02", "evidence": "picture", "note": "the health bar is red", "reason": "r"}
], "gaps": []}\n' >"$TMPROOT/r3c.worker.json"
run r3c "$TMPROOT/two-criteria.json"
check "R3. with no usable observation: says it didn't work and points at the row" \
  "v r3c whyThisGrade | grep -q \"the health bar is red — didn't work (see the row) (prd-2)\""
check "R3. the headline says it didn't work too, not just the requirement" \
  "v r3b derivation | grep -q \"didn't work\""

echo "R4 (D4). plain short names — no code spans, never cut mid-phrase"
realrun c1 copilot-1
check "R4. no backtick anywhere in why-this-grade or the headline" \
  "! v c1 whyThisGrade | grep -q '\`' && ! v c1 derivation | grep -q '\`' && ! v c2 whyThisGrade | grep -q '\`'"
# The why paragraph now names at most three (fix round 2, W1), so the naming
# rules are checked on the names themselves, off the same contract.
sn() { "$PY" - "$SCOREPY" "$FX/criteria.json" "$1" <<'PYX'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("xs", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print([m.short_name(c["text"]) for c in json.load(open(sys.argv[2]))["criteria"] if c["id"] == sys.argv[3]][0])
PYX
}
check "R4. a truncated PRD bullet does not end on a dangling 'for the'" \
  "! v c1 whyThisGrade | grep -q 'for the (' && ! v c1 whyThisGrade | grep -q 'for the;' \
   && [ \"\$(sn prd-3)\" = 'healthBarColor returns a Pixi colour number…' ]"
check "R4. a signature is named by its function, not its type annotations" \
  "[ \"\$(sn prd-2)\" = 'healthFillRatio returns the fraction' ] && ! v c1 whyThisGrade | grep -q 'max: number'"
check "R4. a parenthetical file path is dropped from the name" \
  "[ \"\$(sn prd-5)\" = 'The renderer gains an always-visible' ] && ! v c1 whyThisGrade | grep -q 'renderer/index.ts'"
"$PY" - "$SCOREPY" <<'PYX' >"$TMPROOT/r4names.txt" 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("xs", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for t in ["When devMode is false, updateHealthBar is a no-op and no HP-bar object is added to the stage",
          "the health bar is red", "Two pure functions live in `packages/engine/src/renderer/utils.ts`:"]:
    print(m.short_name(t))
PYX
check "R4. a long requirement is cut at a word, never on 'and'/'no', with …" \
  "sed -n 1p '$TMPROOT/r4names.txt' | grep -qx 'When devMode is false, updateHealthBar is a no-op…'"
check "R4. a short one is left whole" "sed -n 2p '$TMPROOT/r4names.txt' | grep -qx 'the health bar is red'"
check "R4. a path in backticks becomes its file name, and a trailing colon goes" \
  "sed -n 3p '$TMPROOT/r4names.txt' | grep -qx 'Two pure functions live in utils.ts'"
m4="$TMPROOT/wrapped"; mkdir -p "$m4"
printf '# T\n\n## Acceptance criteria\n- `healthBarColor(ratio)` returns a Pixi colour number for the\n  current ratio: red when low\n- second\n' >"$m4/prd.md"
"$PY" "$CRITERIA" "$m4" "$m4/criteria.json" >/dev/null
check "R4. xo-criteria joins a PRD bullet wrapped onto the next line" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"criteria\"]; sys.exit(0 if [c[\"text\"] for c in d]==[\"\`healthBarColor(ratio)\` returns a Pixi colour number for the current ratio: red when low\",\"second\"] else 1)' '$m4/criteria.json'"

echo "R5 (D5). impacts are RECORDED on the first look and reused, never re-guessed"
IMP="$TMPROOT/mission-xo/impacts.json"; mkdir -p "$TMPROOT/mission-xo"
realrun f1 copilot-1 "$IMP" copilot
check "R5. the first look writes impacts.json, keyed by id, with when and which engine" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"impacts\"]; r=d[\"t-001-ac9\"]; sys.exit(0 if len(d)==31 and r[\"impact\"]==\"medium\" and r[\"engine\"]==\"copilot\" and r[\"at\"] and r.get(\"impactWhy\") else 1)' '$IMP'"
check "R5. the first look says the importance was set on this look" \
  "v f1 impactsNote | grep -qi 'set on this look'"
cp "$IMP" "$TMPROOT/imp-before.json"
realrun f2 copilot-2 "$IMP" copilot
check "R5. a second look REUSES every recorded impact (copilot-2's own guesses ignored)" \
  "$PY -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if all(c[\"impact\"]==a[\"criteria\"][i][\"impact\"] for i,c in enumerate(b[\"criteria\"])) else 1)' '$TMPROOT/f1/verdict.json' '$TMPROOT/f2/verdict.json'"
check "R5. …each overruled impact is handed to the journal (IMPACT_KEPT id recorded worker)" \
  "grep -q \$'^IMPACT_KEPT\\tt-001-ac9\\tmedium\\tlow' '$TMPROOT/f2/out.txt' && [ \"\$(grep -c '^IMPACT_KEPT' '$TMPROOT/f2/out.txt')\" -ge 15 ]"
check "R5. …the recorded file is not rewritten by a later look" \
  "cmp -s '$IMP' '$TMPROOT/imp-before.json'"
check "R5. …and the report and verdict say importance was set on the first look" \
  "v f2 impactsNote | grep -q 'set on the first look' && grep -q 'set on the first look' '$TMPROOT/f2/report.md'"
check "R5. …a reused row's reason states the recorded impact, not the look's" \
  "v f2 criteria.16.reason | grep -q '^Impact medium (set on the first look)'"
realrun f3 copilot-1 "$IMP" claude \
  'for c in w["criteria"]: c["impact"] = "low"'
check "R5. same outcomes + recorded impacts → same grade, whatever the look re-guessed" \
  "[ \"\$(score f3)\" = \"\$(score f1)\" ] && [ \"\$(v f3 core)\" = \"\$(v f1 core)\" ]"
IMP2="$TMPROOT/mission2-xo/impacts.json"; mkdir -p "$TMPROOT/mission2-xo"
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); d["impacts"].pop("prd-8"); json.dump(d, open(sys.argv[2],"w"))' "$IMP" "$IMP2"
realrun f4 copilot-2 "$IMP2" claude
check "R5. a NEW criterion id gets its fresh impact from this look" \
  "[ \"\$(v f4 criteria.7.impact)\" = high ] && ! grep -q \$'^IMPACT_KEPT\\tprd-8' '$TMPROOT/f4/out.txt'"
check "R5. …and is added to the record, stamped with this look's engine" \
  "$PY -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"impacts\"][\"prd-8\"]; sys.exit(0 if r[\"impact\"]==\"high\" and r[\"engine\"]==\"claude\" else 1)' '$IMP2'"
check "R5. …and the note says one item was new and rated on this look" \
  "v f4 impactsNote | grep -q '1 item new since then'"
IMP3="$TMPROOT/mission3-xo/impacts.json"; mkdir -p "$TMPROOT/mission3-xo"
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); d["impacts"]["prd-8"]["text"]="a different requirement after a re-align"; d["impacts"]["prd-8"]["impact"]="low"; json.dump(d, open(sys.argv[2],"w"))' "$IMP" "$IMP3"
realrun f6 copilot-2 "$IMP3" copilot
check "R5. an id whose requirement TEXT changed (a re-aligned PRD) is rated afresh, not reused" \
  "[ \"\$(v f6 criteria.7.impact)\" = high ] && ! grep -q \$'^IMPACT_KEPT\\tprd-8' '$TMPROOT/f6/out.txt' \
   && $PY -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"impacts\"][\"prd-8\"]; sys.exit(0 if r[\"text\"]==\"The full engine package test suite passes\" else 1)' '$IMP3'"
realrun f5 copilot-2 "" ""
check "R5. with no record path the scorer behaves as before (no note, no file)" \
  "[ -z \"\$(v f5 impactsNote)\" ] && ! grep -q '^IMPACT_KEPT' '$TMPROOT/f5/out.txt'"
check "R5. xo.sh passes the mission's own xo/impacts.json to both scorer calls" \
  "[ \"\$(grep -c 'xo-score.py.*\\\\\$' '$REPO_ROOT/skills/lcars-xo/xo.sh')\" -ge 2 ] \
   && [ \"\$(grep -c '\"\$xodir/impacts.json\"' '$REPO_ROOT/skills/lcars-xo/xo.sh')\" -ge 2 ]"
check "R5. xo.sh journals a kept impact" \
  "grep -q 'IMPACT_KEPT|IMPACT_MISMATCH' '$REPO_ROOT/skills/lcars-xo/xo.sh' && grep -q 'impact-kept' '$REPO_ROOT/skills/lcars-xo/xo.sh'"

echo "R6 (D5). near-identical requirements rated differently are FLAGGED, never re-graded"
cat >"$TMPROOT/dup-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "The example game calls `setPlayerHealth(3, 10)` once", "source": "prd", "primary": true},
  {"id": "t-1-ac1", "text": "the example game calls setPlayerHealth(3, 10) once.", "source": "plan"},
  {"id": "t-1-ac2", "text": "the bar has a one pixel border", "source": "plan"}
 ]}
C
verdict r6 high "$(row prd-1 high met)" "$(row t-1-ac1 low met)" "$(row t-1-ac2 low met)"
run r6 "$TMPROOT/dup-criteria.json"
check "R6. the pair is recorded beside the grade" \
  "v r6 impactMismatches | grep -q 'prd-1' && v r6 impactMismatches | grep -q 't-1-ac1'"
check "R6. …handed to the journal" "grep -q \$'^IMPACT_MISMATCH\\tprd-1\\tt-1-ac1' '$TMPROOT/r6/out.txt'"
check "R6. …and said in the report in plain words" \
  "grep -q 'say the same thing but were given different importance' '$TMPROOT/r6/report.md'"
check "R6. the grade is untouched (HIGH)" "[ \"\$(score r6)\" = high ]"
verdict r6b high "$(row prd-1 high met)" "$(row t-1-ac1 high met)" "$(row t-1-ac2 low met)"
run r6b "$TMPROOT/dup-criteria.json"
check "R6. the same pair with the same impact is not flagged; unlike texts never are" \
  "[ -z \"\$(v r6b impactMismatches)\" ] && ! grep -q '^IMPACT_MISMATCH' '$TMPROOT/r6b/out.txt'"
check "R6. the prompt tells the worker to rate a restated requirement the same" \
  "grep -qi 'same impact' '$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md' && grep -qi 'what the requirement does' '$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md'"

echo "R7 (D7). a HIGH says what evidence it actually used"
realrun cl1 claude-1 "" "" "" named
check "R7. claude-1 (pictures AND tests) no longer claims a picture of each one" \
  "! v cl1 derivation | grep -q 'picture of each one' && ! v cl1 scoreMeaning | grep -q 'picture of each one'"
check "R7. …it names both, with the counts off the rows" \
  "v cl1 derivation | grep -q 'I have a picture of 9 and your own tests show the other 22'"
check "R7. …and so does the score word's meaning" \
  "v cl1 scoreMeaning | grep -q 'your own tests'"
verdict r7p high "$(row prd-1 high met)" "$(row prd-2 medium met)" "$(row t-1-ac1 low met)" "$(row t-1-ac2 low met)"
run r7p
check "R7. all pictures, with a real drawing → 'I saw each one on screen' (never 'picture', W2)" \
  "v r7p derivation | grep -q 'I saw each one on screen' && ! v r7p derivation | grep -q picture"
cat >"$TMPROOT/tests-only-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [{"id": "prd-1", "text": "the suite passes", "source": "prd", "primary": true}]}
C
printf '{"score":"high","summary":"s","criteria":[{"id":"prd-1","impact":"high","status":"met","evidence":"tests","testQuote":"ok 1 the suite","note":"passes","reason":"r"}],"gaps":[]}\n' >"$TMPROOT/r7u.worker.json"
printf '{"ran":true,"outcome":"passed","exitCode":0,"command":"t","outputTail":"ok 1 the suite\\n"}\n' >"$TMPROOT/r7u.tests.json"
mkdir -p "$TMPROOT/r7u"
"$PY" "$SCOREPY" "$TMPROOT/r7u.worker.json" "$TMPROOT/tests-only-criteria.json" "$TMPROOT/r7u/verdict.json" "" "$TMPROOT/r7u.tests.json" >"$TMPROOT/r7u/out.txt" 2>&1
check "R7. all tests → 'your own tests show each one'" \
  "[ \"\$(score r7u)\" = high ] && v r7u derivation | grep -q 'your own tests show each one' && ! v r7u derivation | grep -q picture"

echo "R8 (D9). the score labels describe the new meanings"
desc() { bash -c '. "$1"; lcars_label_desc "$2"' _ "$REPO_ROOT/skills/lcars-init/lcars-common.sh" "$1"; }
check "R8. HIGH: the point works and every stated requirement worked" \
  "desc lcars:xo:high | grep -q 'point of the mission' && ! desc lcars:xo:high | grep -q 'every criterion met'"
check "R8. MEDIUM: the point works, named known issues" \
  "desc lcars:xo:medium | grep -q 'known issues' && ! desc lcars:xo:medium | grep -q 'primary flow'"
check "R8. LOW: the point didn't work or couldn't be checked" \
  "desc lcars:xo:low | grep -q \"point of the mission didn't work or couldn't be checked\""
check "R8. every description fits GitHub's 100-character limit and keeps 'intent match'" \
  "for l in high medium low; do d=\"\$(desc lcars:xo:\$l)\"; [ \${#d} -le 100 ] && printf '%s' \"\$d\" | grep -q 'intent match' || exit 1; done"

echo "T1 (fix round 2). a test citation must NAME a test case — the looks agree"
# The tester's two live Copilot looks at ONE build, handed the SAME test output
# (file names and counts only). Look A called 25 rows "met by tests", look B 13,
# on lines like "✓ src/renderer/utils.test.ts  (9 tests) 2ms" — HIGH vs MEDIUM.
TRUN="$REPO_ROOT/skills/lcars-xo/xo-tests.py"
t1look() { # <name> <look A|B> [tests.json]
  local d="$TMPROOT/$1"; mkdir -p "$d"; cp "$FX/impacts-look-A.json" "$d/impacts.json"
  "$PY" "$SCOREPY" "$FX/look-$2-verdict.json" "$FX/criteria-joined.json" "$d/verdict.json" "" \
    "${3:-$FX/tests-file-only.json}" "$d/impacts.json" >"$d/out.txt" 2>"$d/err.txt"
}
t1look ta A; t1look tb B
check "T1. same build, same file-only test output → the two looks land the SAME grade and core" \
  "[ \"\$(score ta)\" = \"\$(score tb)\" ] && [ \"\$(v ta core)\" = \"\$(v tb core)\" ]"
check "T1. …no row in either stands MET on a file-level test line" \
  "$PY -c 'import json,sys
for f in sys.argv[1:]:
    for c in json.load(open(f))[\"criteria\"]:
        if c[\"status\"]==\"met\" and c[\"evidence\"]==\"tests\": sys.exit(1)' '$TMPROOT/ta/verdict.json' '$TMPROOT/tb/verdict.json'"
check "T1. …every demotion is handed to the journal (TEST_DEMOTED: 25 on look A, 13 on look B)" \
  "[ \"\$(grep -c '^TEST_DEMOTED' '$TMPROOT/ta/out.txt')\" = 25 ] && [ \"\$(grep -c '^TEST_DEMOTED' '$TMPROOT/tb/out.txt')\" = 13 ] \
   && grep -q \$'^TEST_DEMOTED\\tprd-1\\tmet\\tsrc/renderer/utils.test.ts (9 tests) 2ms' '$TMPROOT/ta/out.txt'"
check "T1. …a demoted row is couldn't-check (unobservable) with the harness's own note" \
  "$PY -c 'import json,sys
c=[c for c in json.load(open(sys.argv[1]))[\"criteria\"] if c[\"id\"]==\"prd-1\"][0]
sys.exit(0 if c[\"status\"]==\"untested\" and c.get(\"couldNotCheck\")==\"unobservable\" and c[\"note\"]==\"your tests ran, but none I could see is named for this\" and \"none I could see is named\" in c[\"reason\"] else 1)' '$TMPROOT/ta/verdict.json'"
check "T1. xo.sh journals the demotion on the first look AND on a recheck" \
  "[ \"\$(grep -c 'IMPACT_KEPT|IMPACT_MISMATCH|TEST_DEMOTED) xo_journal_impact' '$REPO_ROOT/skills/lcars-xo/xo.sh')\" = 2 ] \
   && grep -q 'test-citation-demoted' '$REPO_ROOT/skills/lcars-xo/xo.sh'"
# A NAMED case present in the output stands.
cat >"$TMPROOT/named-tests.json" <<'J'
{"ran": true, "outcome": "passed", "exitCode": 0, "command": "npx vitest run",
 "outputTail": " ✓ src/renderer/utils.test.ts > healthFillRatio > returns 0.3 for 3 of 10 2ms\n ✓ src/renderer/utils.test.ts  (9 tests) 2ms\n RUN  v1.6.1 packages/engine\n",
 "testCases": ["src/renderer/utils.test.ts > healthFillRatio > returns 0.3 for 3 of 10"]}
J
cat >"$TMPROOT/one-crit.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [{"id": "t-1", "text": "healthFillRatio(3,10) === 0.3", "source": "plan", "primary": true}]}
C
t1q() { # <name> <quote> → status of t-1
  local d="$TMPROOT/$1"; mkdir -p "$d"
  "$PY" -c 'import json,sys; print(json.dumps({"score":"high","summary":"s","criteria":[{"id":"t-1","impact":"high","status":"met","evidence":"tests","testQuote":sys.argv[1],"note":"n","reason":"r"}],"gaps":[]}))' "$2" >"$d/w.json"
  "$PY" "$SCOREPY" "$d/w.json" "$TMPROOT/one-crit.json" "$d/verdict.json" "" "$TMPROOT/named-tests.json" >"$d/out.txt" 2>&1
  v "$1" criteria.0.status
}
check "T1. a cited test case NAME present in the output → MET stands (whole line)" \
  "[ \"\$(t1q q1 '✓ src/renderer/utils.test.ts > healthFillRatio > returns 0.3 for 3 of 10 2ms')\" = met ]"
check "T1. …(the name alone, whitespace normalised)" \
  "[ \"\$(t1q q2 'healthFillRatio >   returns 0.3 for 3 of 10')\" = met ]"
check "T1. the file-level tally line → couldn't check, even beside a named case" \
  "[ \"\$(t1q q3 '✓ src/renderer/utils.test.ts  (9 tests) 2ms')\" = untested ]"
check "T1. a file name alone → couldn't check" \
  "[ \"\$(t1q q4 'src/renderer/utils.test.ts')\" = untested ]"
check "T1. a line in the output that is not one of the recorded cases → couldn't check" \
  "[ \"\$(t1q q5 'RUN v1.6.1 packages/engine')\" = untested ] && v q5 criteria.0.note | grep -q 'none I could see is named'"
check "T1. a case name that is NOT in the output → couldn't check" \
  "[ \"\$(t1q q6 'healthFillRatio > returns 1 at full health')\" = untested ]"

echo "T1b. the test step records per-case names (vitest verbose, jest --verbose)"
TB="$TMPROOT/t1b"; mkdir -p "$TB/bin" "$TB/wt"
cat >"$TB/bin/vitest" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --reporter=verbose "*)
  printf ' ✓ src/renderer/utils.test.ts > healthFillRatio > returns 0.3 for 3 of 10 2ms\n'
  printf ' × src/renderer/utils.test.ts > healthBarColor > is red at 0.35 1ms\n' ;;
esac
printf ' ✓ src/renderer/utils.test.ts  (2 tests) 2ms\n\n Test Files  1 passed (1)\n'
[ -n "${VITEST_FAIL_WITH_FLAG:-}" ] && case " $* " in *" --reporter=verbose "*) exit 1 ;; esac
exit 0
SH
cat >"$TB/bin/jest" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --verbose "*) printf '  batches\n    ✓ survive a restart (3 ms)\n' >&2 ;; esac
printf 'PASS src/batch.test.js\n' >&2
SH
chmod +x "$TB/bin/vitest" "$TB/bin/jest"
tb() { # <name> <command> [env...]
  local n="$1" c="$2"; shift 2
  ( export PATH="$TB/bin:$PATH"; env "$@" "$PY" "$TRUN" --out "$TB/$n.json" --cwd "$TB/wt" --timeout 30 --command "$c" ) >/dev/null 2>&1
}
jf() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2])))' "$TB/$1.json" "$2"; }
tb v1 'cd . && vitest run ${LCARS_TESTS_DIR:+"$LCARS_TESTS_DIR"}' X=1
check "T1b. a direct vitest run gets --reporter=verbose, and the case names are recorded" \
  "[ \"\$(jf v1 'd[\"reporterFlag\"]')\" = '\"--reporter=verbose\"' ] \
   && jf v1 'd[\"testCases\"]' | grep -q 'healthFillRatio > returns 0.3 for 3 of 10' \
   && jf v1 'd[\"testCases\"]' | grep -q 'is red at 0.35' && ! jf v1 'd[\"testCases\"]' | grep -q '2 tests'"
check "T1b. …the recorded command is the captain's own, unchanged" \
  "[ \"\$(jf v1 'd[\"command\"]')\" = '\"cd . && vitest run \${LCARS_TESTS_DIR:+\\\"\$LCARS_TESTS_DIR\\\"}\"' ] && [ \"\$(jf v1 'd[\"outcome\"]')\" = '\"passed\"' ]"
tb v2 'vitest run' VITEST_FAIL_WITH_FLAG=1
check "T1b. the flag never decides the outcome: flagged run fails, plain run passes → passed, no flag" \
  "[ \"\$(jf v2 'd[\"outcome\"]')\" = '\"passed\"' ] && [ \"\$(jf v2 'd[\"reporterFlag\"]')\" = '\"\"' ] && [ \"\$(jf v2 'd[\"exitCode\"]')\" = 0 ]"
tb v3 'vitest run | cat'
check "T1b. a command with a pipe is run exactly as written (no flag)" \
  "[ \"\$(jf v3 'd[\"reporterFlag\"]')\" = '\"\"' ] && [ \"\$(jf v3 'd[\"testCases\"]')\" = '[]' ]"
tb j1 'npx --no-install jest' X=1
tb j2 'jest'
check "T1b. jest gets --verbose and its case names are recorded (from stderr too)" \
  "[ \"\$(jf j2 'd[\"reporterFlag\"]')\" = '\"--verbose\"' ] && jf j2 'd[\"testCases\"]' | grep -q 'survive a restart'"
check "T1b. a runner we do not wrap (pnpm test) gets no flag" \
  "\"$PY\" -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"t\",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.reporter_flag(\"pnpm test\")==\"\" and m.reporter_flag(\"npm test && npx vitest run\")==\"--reporter=verbose\" and m.reporter_flag(\"npx vitest run --reporter=dot\")==\"\" else 1)' '$TRUN'"
rf_case() { # <expected flag> <command> — reporter_flag(command) == expected
  "$PY" -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("t",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); got=m.reporter_flag(sys.argv[3]); sys.exit(0 if got==sys.argv[2] else (print("got %r" % got) or 1))' "$TRUN" "$1" "$2"
}
check "T1b (fix round 3). a \${VAR#pattern} expansion is not a comment — the DX-Scorecard command gets the flag" \
  "rf_case --reporter=verbose 'npx vitest run \${LCARS_TESTS_DIR:+\"\${LCARS_TESTS_DIR#\"\$PWD/\"}\"}'"
check "T1b (fix round 3). the groutwork command (cd \"\$(…)\" && npx vitest run …) still gets the flag" \
  "rf_case --reporter=verbose 'cd \"\$(git rev-parse --show-toplevel)/packages/engine\" && npx vitest run \${LCARS_TESTS_DIR:+\"\$LCARS_TESTS_DIR\"}'"
check "T1b (fix round 3). a real trailing comment still gets no flag" \
  "rf_case '' 'npx vitest run # comment' && rf_case '' 'npx vitest run;# c' && rf_case '' '#npx vitest run'"
check "T1b (fix round 3). a real pipe / redirect / backtick still gets no flag" \
  "rf_case '' 'npx vitest run | tee x' && rf_case '' 'npx vitest run > out.txt' && rf_case '' 'npx vitest run \`echo x\`' && rf_case '' 'npx vitest run \${X:+\"a\"} | tee x'"
check "T1b (fix round 3). a # or | inside quotes is not a comment or a pipe" \
  "rf_case --reporter=verbose 'npx vitest run -t \"a # b | c\"' && rf_case --reporter=verbose \"npx vitest run -t 'x#y'\""
check "T1b. the prompts tell the worker to cite the exact test name" \
  "grep -q 'testCases' '$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md' && grep -q 'testCases' '$REPO_ROOT/skills/lcars-xo/prompts/recheck.md'"

echo "W1-W3 (fix round 2). why-this-grade is short, plain, and names stay distinct"
"$PY" - "$TMPROOT" "$SCOREPY" "$FX" >"$TMPROOT/w1.txt" 2>&1 <<'PYX'
import json, re, sys, importlib.util, subprocess
tmp, scorepy, fx = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("xs", scorepy); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def sentences(t):
    return len(re.findall(r"[.](?:\s+(?=[A-Z])|$)", t.strip()))
bad = []
# the real ledgers: both looks as scored, plus a MEDIUM and a MEDIUM-with-faults
# shape of look B (its test rows read as pictures).
d = json.load(open(fx + "/look-B-verdict.json"))
for c in d["criteria"]:
    if c.get("evidence") == "tests":
        c.update(evidence="picture", shot="shot-01"); c.pop("testQuote", None)
json.dump(d, open(tmp + "/w1-med.json", "w"))
for c in d["criteria"]:
    if c["id"] in ("t-002-ac6", "t-001-ac9"):
        c.update(status="gap", note="the bar stays at the old x after a resize",
                 evidence="picture", shot="shot-01")
d["gaps"] = [{"title": "the bar does not move on resize", "expected": "the bar pinned top-right after a resize",
              "saw": "it stays at the old x", "kind": "contradiction", "criterion": "t-002-ac6", "shots": ["shot-01"]}]
json.dump(d, open(tmp + "/w1-gap.json", "w"))
for name, src in (("A", fx + "/look-A-verdict.json"), ("B", fx + "/look-B-verdict.json"),
                  ("med", tmp + "/w1-med.json"), ("gap", tmp + "/w1-gap.json")):
    out = tmp + "/w1-%s.out.json" % name
    imp = tmp + "/w1-%s.impacts.json" % name
    open(imp, "w").write(open(fx + "/impacts-look-A.json").read())
    subprocess.run([sys.executable, scorepy, src, fx + "/criteria-joined.json", out, "",
                    fx + "/tests-file-only.json", imp], capture_output=True)
    v = json.load(open(out))
    why, head = v["whyThisGrade"], v["derivation"]
    print("%s %s | %s | %s" % (name, v["score"], head, why))
    if sentences(why) > 4: bad.append("%s: %d sentences" % (name, sentences(why)))
    if len(why) > 800: bad.append("%s: why is %d chars" % (name, len(why)))
    if m.word_count(head) > 25: bad.append("%s: headline is %d words" % (name, m.word_count(head)))
    for t in (why, head):
        if "**" in t or "`" in t: bad.append("%s: markdown leaked" % name)
        if re.search(r"\b(?:%s)…" % "|".join(m.DANGLING), t): bad.append("%s: ends mid-phrase: %s" % (name, t))
    if not head[:1].isupper(): bad.append("%s: headline starts lowercase" % name)
    if "a known issues" in head + why: bad.append("%s: 'a known issues'" % name)
    for c in v["criteria"]:
        first_sentence = re.split(r"\.\s+(?=[A-Z])", c.get("reason", ""), maxsplit=1)[0]
        if "(set on the first look) because" in first_sentence and first_sentence.count("because") > 1:
            bad.append("%s: two becauses in %s" % (name, c["id"]))
# distinct items stay distinct
texts = [c["text"] for c in json.load(open(fx + "/criteria-joined.json"))["criteria"]]
for lim in (60, 48):
    names = [m.short_name(t, lim) for t in texts]
    for i, a in enumerate(names):
        for j in range(i + 1, len(names)):
            if a == names[j] and texts[i] != texts[j]:
                bad.append("same name for two items at %d: %s" % (lim, a))
n6 = m.short_name("healthBarColor(0) === 0xff3b30 and healthBarColor(0.35) === 0xff3b30")
if "(0)" not in n6 or "healthBarColor === " in n6: bad.append("arguments stripped: " + n6)
n7 = m.short_name("The example game calls `setPlayerHealth` once with a **low demo value** (e.g. `3` of `10`)")
if "**" in n7 or "low demo" not in n7: bad.append("markdown: " + n7)
if "DEV_HP_BAR_WIDTH" not in m.short_name("DEV_HP_BAR_WIDTH is exported"): bad.append("identifier underscores eaten")
print("BAD" if bad else "OK")
for b in bad: print("  " + b)
PYX
check "W1. why-this-grade ≤ 4 sentences and ≤ 800 chars; headline ≤ 25 words; no markdown; never mid-phrase (real ledgers)" \
  "grep -qx OK '$TMPROOT/w1.txt' || { cat '$TMPROOT/w1.txt'; false; }"
check "W1. at most three names, then how many more" \
  "grep '^A ' '$TMPROOT/w1.txt' | grep -q 'and 16 more' && ! grep '^A ' '$TMPROOT/w1.txt' | grep -q 'healthFillRatio(20,10)'"
check "W1. distinct checks keep their distinguishing arguments (healthBarColor(0) vs (1))" \
  "grep -qx OK '$TMPROOT/w1.txt'"
check "W2. a picture-only mission's headline opens on a capital, with the short lead" \
  "grep '^A ' '$TMPROOT/w1.txt' | grep -q '| Your attachment is a picture, not a drawing\\. '"
check "W2. 'so it ships as a known issue' / 'they ship as known issues' — grammar" \
  "! grep -q 'a known issues' '$REPO_ROOT/skills/lcars-xo/xo-score.py'"
check "W3. a recorded impact's reason has ONE 'because' and continues in lower case" \
  "$PY -c 'import json,sys
c=[c for c in json.load(open(sys.argv[1]))[\"criteria\"] if c[\"id\"]==\"t-001-ac9\"][0]
sys.exit(0 if c[\"reason\"].startswith(\"Impact medium (set on the first look) because they are required config\") else 1)' '$TMPROOT/tb/verdict.json'"

echo
printf 'lcars xo-impact: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
