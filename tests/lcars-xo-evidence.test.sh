#!/usr/bin/env bash
#
# Tests for THE PROJECT'S OWN TESTS AS EVIDENCE (Session 211) — the captain,
# 2026-09-13: "some things might just be API changes that don't affect the UI
# that need to be tested … a functionality bug is like a button being pushed
# was supposed to do something and it doesn't."
#
# Number One acts only through a browser, so a change with no UI surface is
# invisible to it. `config.json` already carries `testCommand` — the project's
# own suite. THE SKILL RUNS IT and hands the worker the result as evidence.
# The worker still reasons and still gets no shell.
#
# Skill source under test:
#   skills/lcars-xo/xo-tests.py   — the BOUNDED runner. It runs the repo's own
#                                    test command in the launched build's
#                                    worktree, in its own process group, with a
#                                    hard timeout, and RECORDS FACTS: the
#                                    command as run, the exit code, the
#                                    duration, the tail of the output, whether
#                                    that tail was truncated and at what cap.
#   skills/lcars-xo/xo-score.py   — the evidence KIND on every ledger line, and
#                                    the over-claiming guard: a passing suite
#                                    does not prove a criterion the suite does
#                                    not speak to.
#
# THE TRAP THIS SUITE EXISTS TO STOP. `tests/drives/s197/cage.py` reports a
# hang and a failure on STDOUT while its own process exit status stays 0 in all
# three cases. Anything wired to a cage's exit status reads every test run as a
# pass — a green that means nothing, on a feature whose entire purpose is to
# answer what a screenshot cannot. So the runner here propagates the child's
# status ITSELF, and pass / fail / hang are asserted to be three DISTINGUISHABLE
# outcomes, one assertion each.
#
# INFER VS RECORD. Everything derived — the `outcome`, the plain verdict, the
# evidence kind on a ledger line — is derived from facts the producer knew at
# the moment it produced them, never re-parsed later out of prose. S147, S156,
# S188 and S212 were each lost to code that read back text a human also writes.
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-evidence.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${LCARS_XO_TESTS_PY:-$REPO_ROOT/skills/lcars-xo/xo-tests.py}"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
LOGSPY="${LCARS_XO_LOGS_PY:-$REPO_ROOT/skills/lcars-xo/xo-logs.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

jget() { # <file> <python expression over `d`>
  "$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))' "$1" "$2" 2>/dev/null
}

echo
echo "=== lcars xo: the project's own tests as evidence (S211) ==="
echo

# ==========================================================================
echo "A. the bounded runner — pass, fail and hang are three different things"
# ==========================================================================

RDIR="$TMPROOT/runner"; mkdir -p "$RDIR/work"
run_tests() { # <out.json> <cwd> <timeout> <command> [cap]  -> echoes the exit code
  local out="$1" cwd="$2" to="$3" cmd="$4" cap="${5:-8000}" rc=0
  "$PY" "$RUNNER" --out "$out" --cwd "$cwd" --timeout "$to" \
        --cap "$cap" --command "$cmd" >"$out.stdout" 2>"$out.stderr" || rc=$?
  printf '%s' "$rc"
}

# --- A1. a suite that passes ------------------------------------------------
rcA1="$(run_tests "$RDIR/a1.json" "$RDIR/work" 30 'echo "42 passed"; exit 0')"
check "A1. a passing suite records outcome=passed" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"outcome\"]')\" = passed ]"
check "A1. …with the real exit code, 0" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"exitCode\"]')\" = 0 ]"
check "A1. …and ran=true" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"ran\"]')\" = true ]"
check "A1. …and the runner's OWN exit status is 0" "[ '$rcA1' -eq 0 ]"
check "A1. …and the command it ran is recorded verbatim" \
  "grep -q '42 passed' '$RDIR/a1.json'"
check "A1. …and the output tail carries what the suite printed" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"outputTail\"]')\" != '' ]"

# --- A2. a suite that FAILS (a product failure) -----------------------------
rcA2="$(run_tests "$RDIR/a2.json" "$RDIR/work" 30 'echo "FAIL batches survive a restart"; exit 7')"
check "A2. a failing suite records outcome=failed" \
  "[ \"\$(jget '$RDIR/a2.json' 'd[\"outcome\"]')\" = failed ]"
check "A2. …with the child's real exit code, 7 — not the runner's own" \
  "[ \"\$(jget '$RDIR/a2.json' 'd[\"exitCode\"]')\" = 7 ]"
check "A2. …and it did NOT time out" \
  "[ \"\$(jget '$RDIR/a2.json' 'd[\"timedOut\"]')\" = false ]"
check "A2. …and the runner's own exit status says failed, not 0" "[ '$rcA2' -eq 1 ]"
check "A2. …and the failure text is in the recorded tail" \
  "grep -q 'FAIL batches survive a restart' '$RDIR/a2.json'"

# --- A3. a suite that HANGS (an infrastructure failure) ---------------------
# The whole process group must die, grandchildren included: a hung `pnpm test`
# that leaves a detached vitest behind on the captain's machine is how this
# project has lost whole sessions.
#
# WHAT IS ASSERTED AND WHY IT IS SHAPED THIS WAY. A killpg on macOS does not
# stop every member in the same instant — a background subshell blocked in
# wait() can get ONE syscall in between its child dying and its own SIGKILL
# landing, which was measured here. That is a race, not a leak: the subshell is
# gone microseconds later. So the assertion is the thing that actually matters
# and is actually decidable — the background process IS DEAD when the runner
# returns, and nothing it would have done seconds later ever happens.
marker="$RDIR/grandchild-survived"
subpid="$RDIR/subshell.pid"
t0="$(date +%s)"
rcA3="$(run_tests "$RDIR/a3.json" "$RDIR/work" 2 \
  "( echo \$BASHPID > '$subpid'; sleep 20; sleep 3; touch '$marker' ) & sleep 20")"
t1="$(date +%s)"
check "A3. a hanging suite records outcome=hung" \
  "[ \"\$(jget '$RDIR/a3.json' 'd[\"outcome\"]')\" = hung ]"
check "A3. …timedOut is the recorded fact, not a guess" \
  "[ \"\$(jget '$RDIR/a3.json' 'd[\"timedOut\"]')\" = true ]"
check "A3. …the timeout it was held to is recorded" \
  "[ \"\$(jget '$RDIR/a3.json' 'd[\"timeoutSeconds\"]')\" = 2 ]"
check "A3. …and it was killed at the timeout, not left to run" "[ \$(( t1 - t0 )) -lt 12 ]"
check "A3. …and the runner's own exit status says hung, not 0" "[ '$rcA3' -eq 2 ]"
check "A3. …the backgrounded process is DEAD the moment the runner returns" \
  "[ -s '$subpid' ] && ! kill -0 \"\$(cat '$subpid')\" 2>/dev/null"
sleep 5
check "A3. …and nothing it had queued up ever ran" "[ ! -e '$marker' ]"

# --- A4. the three outcomes are genuinely distinguishable -------------------
# This is the assertion the cage would fail. Named on its own so a regression
# here cannot hide inside a group.
check "A4. pass / fail / hang are three DIFFERENT exit statuses" \
  "[ '$rcA1' -ne '$rcA2' ] && [ '$rcA2' -ne '$rcA3' ] && [ '$rcA1' -ne '$rcA3' ]"
check "A4. …and three DIFFERENT recorded outcomes" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"outcome\"]')\" != \"\$(jget '$RDIR/a2.json' 'd[\"outcome\"]')\" ] &&
   [ \"\$(jget '$RDIR/a2.json' 'd[\"outcome\"]')\" != \"\$(jget '$RDIR/a3.json' 'd[\"outcome\"]')\" ]"
check "A4. …a hang is NEVER recorded as a product failure" \
  "[ \"\$(jget '$RDIR/a3.json' 'd[\"outcome\"]')\" != failed ]"
check "A4. …and a hang's plain verdict says it is about running the tests" \
  "jget '$RDIR/a3.json' 'd[\"verdict\"]' | grep -qi 'stopped it'"

# --- A5. no test command at all — the common case ---------------------------
rcA5=0
"$PY" "$RUNNER" --out "$RDIR/a5.json" --cwd "$RDIR/work" --timeout 30 \
      --cap 8000 --command "" >/dev/null 2>&1 || rcA5=$?
check "A5. no testCommand records ran=false" \
  "[ \"\$(jget '$RDIR/a5.json' 'd[\"ran\"]')\" = false ]"
check "A5. …and names the case plainly" \
  "[ \"\$(jget '$RDIR/a5.json' 'd[\"outcome\"]')\" = no-test-command ]"
check "A5. …and that is not a pass, a fail or a hang" "[ '$rcA5' -eq 3 ]"
check "A5. …and the file still exists to be read" "[ -s '$RDIR/a5.json' ]"

# --- A6. no worktree to run in ----------------------------------------------
rcA6=0
"$PY" "$RUNNER" --out "$RDIR/a6.json" --cwd "$RDIR/nowhere" --timeout 30 \
      --cap 8000 --command 'exit 0' >/dev/null 2>&1 || rcA6=$?
check "A6. a missing worktree is recorded, never guessed at" \
  "[ \"\$(jget '$RDIR/a6.json' 'd[\"outcome\"]')\" = no-worktree ]"
check "A6. …and nothing was run" "[ \"\$(jget '$RDIR/a6.json' 'd[\"ran\"]')\" = false ]"

# --- A7. the cap is STATED, and the tail is the TAIL ------------------------
rcA7="$(run_tests "$RDIR/a7.json" "$RDIR/work" 30 \
  'i=0; while [ $i -lt 400 ]; do echo "line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done; echo LASTLINE' 500)"
check "A7. a long run says it was truncated" \
  "[ \"\$(jget '$RDIR/a7.json' 'd[\"truncated\"]')\" = true ]"
check "A7. …states the cap it used" \
  "[ \"\$(jget '$RDIR/a7.json' 'd[\"tailCapBytes\"]')\" = 500 ]"
check "A7. …records how much there really was" \
  "[ \"\$(jget '$RDIR/a7.json' 'd[\"outputBytes\"]')\" -gt 500 ]"
check "A7. …and keeps the END of the output, where a failure lands" \
  "grep -q 'LASTLINE' '$RDIR/a7.json'"
check "A7. …and drops the start" "! grep -q 'line-0-' '$RDIR/a7.json'"
check "A7. a short run is NOT marked truncated" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"truncated\"]')\" = false ]"

# --- A8. it runs in the worktree it was given -------------------------------
mkdir -p "$RDIR/elsewhere"
run_tests "$RDIR/a8.json" "$RDIR/elsewhere" 30 'pwd' >/dev/null
check "A8. the command runs in the worktree, and the cwd is recorded" \
  "grep -q 'elsewhere' '$RDIR/a8.json' &&
   [ \"\$(jget '$RDIR/a8.json' 'd[\"cwd\"]')\" = \"\$(cd '$RDIR/elsewhere' && pwd -P)\" ]"

# --- A9. the WHOLE suite, not the red gate's quarantine ---------------------
# A seeded testCommand interpolates ${LCARS_TESTS_DIR} to scope itself to the
# Implement gate's staged copy. Number One wants the project's own whole suite,
# so that variable must not be set for it.
LCARS_TESTS_DIR="/should/not/be/used" \
  run_tests "$RDIR/a9.json" "$RDIR/work" 30 'echo "scope=[${LCARS_TESTS_DIR:-unset}]"' >/dev/null
check "A9. LCARS_TESTS_DIR is not leaked into the project's own suite" \
  "grep -q 'scope=\[unset\]' '$RDIR/a9.json'"

# --- A10. the duration is a recorded fact -----------------------------------
check "A10. the duration is recorded as a number" \
  "[ \"\$(jget '$RDIR/a1.json' 'd[\"durationSeconds\"]')\" != '' ] &&
   \"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d[\"durationSeconds\"],(int,float)) else 1)' '$RDIR/a1.json'"

# ==========================================================================
echo
echo "B. the evidence kind, and the over-claiming guard"
# ==========================================================================

BDIR="$TMPROOT/score"; mkdir -p "$BDIR"

cat >"$BDIR/criteria.json" <<'CJ'
{"hasDrawing": true, "placeNames": ["#task-list"], "criteria": [
  {"id": "prd-1", "text": "the board shows every open task in one list",
   "primary": true, "drawnAt": "#task-list"},
  {"id": "t-4-ac1", "text": "batches survive a restart", "notVisual": true}
]}
CJ

# THE FOUR RECORDS, WRITTEN BY THE REAL RUNNER — never hand-typed.
# A captured fixture goes stale the moment the producer's wording moves, and
# this project has already paid for that once (S126: a captured CLI fixture
# that silently stopped matching). So each of these is xo-tests.py's own
# output over a fake `npm` on PATH, which is what makes the recorded command
# read `npm test` and the recorded verdict the exact sentence the captain
# would see.
FAKEBIN="$BDIR/bin"; mkdir -p "$FAKEBIN" "$BDIR/wt"
cat >"$FAKEBIN/npm" <<'NPM'
#!/usr/bin/env bash
case "${FAKE_SUITE:-pass}" in
  pass) printf 'PASS batches survive a restart\nTests: 42 passed\n'; exit 0 ;;
  fail) printf 'FAIL batches survive a restart\n  expected 3 batches, got 0\nTests: 1 failed, 41 passed\n'; exit 1 ;;
  hang) printf 'batches survive a restart\n'; sleep 20 ;;
esac
NPM
chmod +x "$FAKEBIN/npm"

make_tests_record() { # <out> <FAKE_SUITE> <timeout>
  ( export PATH="$FAKEBIN:$PATH" FAKE_SUITE="$2"
    "$PY" "$RUNNER" --out "$1" --cwd "$BDIR/wt" --timeout "$3" \
          --cap 8000 --command 'npm test' ) >/dev/null 2>&1 || true
}
make_tests_record "$BDIR/tests-pass.json" pass 60
make_tests_record "$BDIR/tests-fail.json" fail 60
make_tests_record "$BDIR/tests-hung.json" hang 2
"$PY" "$RUNNER" --out "$BDIR/tests-none.json" --cwd "$BDIR/wt" --timeout 60 \
      --cap 8000 --command "" >/dev/null 2>&1 || true

check "B0. the fixtures are the real runner's own records" \
  "[ \"\$(jget '$BDIR/tests-pass.json' 'd[\"outcome\"]')\" = passed ] &&
   [ \"\$(jget '$BDIR/tests-fail.json' 'd[\"outcome\"]')\" = failed ] &&
   [ \"\$(jget '$BDIR/tests-hung.json' 'd[\"outcome\"]')\" = hung ] &&
   [ \"\$(jget '$BDIR/tests-none.json' 'd[\"outcome\"]')\" = no-test-command ]"

# $1 = t-4-ac1 status, $2 = its evidence block (raw JSON fields), $3 = gaps body
ev() {
  printf '{"score":"medium","summary":"Looked at the board.","criteria":['
  printf '{"id":"prd-1","text":"one list","status":"met","shot":"shot-01","note":"saw the list"},'
  printf '{"id":"t-4-ac1","text":"batches survive a restart","status":"%s"%s,"note":"the suite covers it"}' "$1" "$2"
  printf '],"gaps":[%s],"alsoChecked":[],"escalations":[]}' "${3:-}"
}

score() { # <verdict-json-body> <tests.json> <outdir>
  mkdir -p "$3"
  printf '%s\n' "$1" >"$3/in.json"
  "$PY" "$SCOREPY" "$3/in.json" "$BDIR/criteria.json" "$3/verdict.json" \
        "" "$2" >"$3/out.tsv" 2>"$3/err.txt"
}

lstatus() { # <verdict.json> <criterion id>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == sys.argv[2]: print(e.get("status","")); break' "$1" "$2" 2>/dev/null
}
levidence() { # <verdict.json> <criterion id>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == sys.argv[2]: print(e.get("evidence","<none-recorded>")); break' "$1" "$2" 2>/dev/null
}

# --- B1. a passing suite SETTLES a notVisual criterion ----------------------
score "$(ev met ',"evidence":"tests","testQuote":"PASS batches survive a restart"')" \
      "$BDIR/tests-pass.json" "$BDIR/b1"
check "B1. a notVisual criterion can be MET on the project's own tests" \
  "[ \"\$(lstatus '$BDIR/b1/verdict.json' t-4-ac1)\" = met ]"
check "B1. …and the ledger line RECORDS that the tests are where it came from" \
  "[ \"\$(levidence '$BDIR/b1/verdict.json' t-4-ac1)\" = tests ]"
check "B1. …and it needed no screenshot to do it" \
  "! grep -q 'rated met with no shot' '$BDIR/b1/verdict.json'"
check "B1. …the report names the tests as the source" \
  "grep -qi 'your tests' '$BDIR/b1/report.md'"
check "B1. …and everything met on a picture still says picture" \
  "[ \"\$(levidence '$BDIR/b1/verdict.json' prd-1)\" = picture ]"

# --- B2. THE OVER-CLAIMING GUARD -------------------------------------------
# A passing suite that says nothing about this criterion. The worker leans on
# the green and cites no line of it. That must NOT become MET.
score "$(ev met ',"evidence":"tests"')" "$BDIR/tests-pass.json" "$BDIR/b2"
check "B2. a green suite with nothing cited does NOT settle a criterion" \
  "[ \"\$(lstatus '$BDIR/b2/verdict.json' t-4-ac1)\" = untested ]"
check "B2. …and the report puts it under what could not be checked" \
  "grep -q 'What I could not check' '$BDIR/b2/report.md'"
check "B2. …and says WHY: the output said nothing about it" \
  "grep -qi 'test output' '$BDIR/b2/report.md'"

# --- B3. a citation that is not in the recorded output ----------------------
score "$(ev met ',"evidence":"tests","testQuote":"PASS the mix ratio is remembered"')" \
      "$BDIR/tests-pass.json" "$BDIR/b3"
check "B3. a quote that is not in the output does not settle anything" \
  "[ \"\$(lstatus '$BDIR/b3/verdict.json' t-4-ac1)\" = untested ]"
check "B3. …and the ledger note says the line was not in the output" \
  "grep -qi 'could not find that line' '$BDIR/b3/verdict.json'"

# --- B3b. a REAL runner colours its output; a citation must survive that ----
# Measured on a real run: `bash tests/…` records "\x1b[32mPASS\x1b[0m B13 …",
# and a reader copying that line out writes "PASS B13 …". Refusing it would be
# the guard eating a perfectly honest citation.
mkdir -p "$BDIR/b3b"
"$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
d["outputTail"] = "\u001b[32mPASS\u001b[0m batches survive a restart\n"
json.dump(d, open(sys.argv[2], "w"))' "$BDIR/tests-pass.json" "$BDIR/tests-coloured.json"
score "$(ev met ',"evidence":"tests","testQuote":"PASS batches survive a restart"')"       "$BDIR/tests-coloured.json" "$BDIR/b3b"
check "B3b. a citation still matches through the runner's colour codes"   "[ \"\$(lstatus '$BDIR/b3b/verdict.json' t-4-ac1)\" = met ]"

# --- B4. no testCommand at all ---------------------------------------------
score "$(ev met ',"evidence":"tests","testQuote":"PASS batches survive a restart"')" \
      "$BDIR/tests-none.json" "$BDIR/b4"
check "B4. a repo with no test command cannot settle anything by tests" \
  "[ \"\$(lstatus '$BDIR/b4/verdict.json' t-4-ac1)\" = untested ]"

# --- B5. a HUNG suite is infrastructure, never a product judgement ----------
score "$(ev met ',"evidence":"tests","testQuote":"batches survive a restart"')" \
      "$BDIR/tests-hung.json" "$BDIR/b5"
check "B5. a suite that hung settles nothing" \
  "[ \"\$(lstatus '$BDIR/b5/verdict.json' t-4-ac1)\" = untested ]"
check "B5. …and the hang is reported as trouble running the tests, not a build fault" \
  "grep -qi 'stopped it\|not a problem with the build\|not the build' '$BDIR/b5/report.md'"
check "B5. …and it does NOT become a gap" \
  "[ \"\$(lstatus '$BDIR/b5/verdict.json' t-4-ac1)\" != gap ]"

# --- B6. a FAILING suite is a GAP, with the failure quoted ------------------
GAP_TESTS='{"title":"batches do not survive a restart","expected":"the batches you added to be there after a restart","saw":"an empty list","evidence":"tests","testQuote":"FAIL batches survive a restart","shots":[],"kind":"contradiction","criterion":"t-4-ac1"}'
score "$(ev gap ',"evidence":"tests","testQuote":"FAIL batches survive a restart","impact":"medium"' "$GAP_TESTS")" \
      "$BDIR/tests-fail.json" "$BDIR/b6"
check "B6. a failing test lands a GAP" \
  "[ \"\$(lstatus '$BDIR/b6/verdict.json' t-4-ac1)\" = gap ]"
check "B6. …it stays a CONTRADICTION even with no screenshot behind it" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if any(g[\"kind\"]==\"contradiction\" for g in d[\"gaps\"]) else 1)' '$BDIR/b6/verdict.json'"
check "B6. …and the real failure text is QUOTED in the report" \
  "grep -q 'FAIL batches survive a restart' '$BDIR/b6/report.md'"
check "B6. …the evidence kind is recorded on the ledger line too" \
  "[ \"\$(levidence '$BDIR/b6/verdict.json' t-4-ac1)\" = tests ]"

# --- B7. the EXISTING matrix does the scoring — no new rule -----------------
# (S216: the matrix is now impact x outcome, so the row says it is MEDIUM
# impact; a test-proven gap is scored exactly like a pictured one.)
check "B7. a medium-impact contradiction is MEDIUM, exactly as a pictured one" \
  "[ \"\$(jget '$BDIR/b6/verdict.json' 'd[\"score\"]')\" = medium ]"
GAP_PRIMARY_TESTS='{"title":"the list is empty","expected":"every open task in one list","saw":"nothing","evidence":"tests","testQuote":"FAIL batches survive a restart","shots":[],"kind":"contradiction","criterion":"prd-1"}'
printf '{"score":"medium","summary":"s","criteria":[{"id":"prd-1","text":"one list","status":"gap","evidence":"tests","testQuote":"FAIL batches survive a restart","note":"the suite fails on it"},{"id":"t-4-ac1","text":"restart","status":"met","evidence":"tests","testQuote":"Tests: 1 failed, 41 passed","note":"green"}],"gaps":[%s],"alsoChecked":[],"escalations":[]}\n' \
  "$GAP_PRIMARY_TESTS" >"$BDIR/b7-in.json"
mkdir -p "$BDIR/b7"
"$PY" "$SCOREPY" "$BDIR/b7-in.json" "$BDIR/criteria.json" "$BDIR/b7/verdict.json" \
      "" "$BDIR/tests-fail.json" >/dev/null 2>&1
check "B7. …and a contradicted PRD criterion is still LOW" \
  "[ \"\$(jget '$BDIR/b7/verdict.json' 'd[\"score\"]')\" = low ]"

# --- B8. every ledger line names its evidence kind --------------------------
check "B8. EVERY ledger line carries an evidence kind" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
bad=[e[\"id\"] for e in d[\"criteria\"] if not e.get(\"evidence\")]
sys.exit(1 if bad else 0)' '$BDIR/b1/verdict.json'"
check "B8. …including the ones it could not check" \
  "[ \"\$(levidence '$BDIR/b2/verdict.json' t-4-ac1)\" = none ]"
check "B8. …and the report's table has a column saying where each came from" \
  "grep -q 'How I know' '$BDIR/b1/report.md'"
check "B8. …a picture reads as a picture in that column" \
  "grep -q 'a picture' '$BDIR/b1/report.md'"

# --- B9. a MEASURED box is its own kind — and CANNOT settle a criterion -----
# A measurement is a number read out of pairs.json (e.g. icon-bigger-than-its-
# control, which only sees an icon OVERFLOW its button — never an icon that is
# ABSENT). So a measurement may LOWER an outcome or RAISE a fault, but must
# NEVER satisfy one. Measured on a real run: four rows — View, Cancel, Discard
# draft and Preview — closed `met` on a measurement alone, and Preview was a
# planted fault (a button with NO icon at all) the ruler was blind to.

# B9a. a MET on a measurement alone does NOT stand — it stays open and says so.
score "$(ev met ',"evidence":"measurement","shot":"shot-02"')" \
      "$BDIR/tests-pass.json" "$BDIR/b9"
check "B9. a criterion MET on a measurement alone does NOT stand" \
  "[ \"\$(lstatus '$BDIR/b9/verdict.json' t-4-ac1)\" = untested ]"
check "B9. …and its ledger line no longer claims a measurement settled it" \
  "[ \"\$(levidence '$BDIR/b9/verdict.json' t-4-ac1)\" = none ]"
check "B9. …and it records that a measurement cannot settle a criterion" \
  "grep -qi 'measurement cannot settle a criterion' '$BDIR/b9/verdict.json'"

# B9b. a FAULT raised from a measurement is legitimate and MUST still stand.
GAP_MEAS='{"title":"the Preview button has no icon","expected":"an icon on the Preview button","saw":"a bare button","evidence":"measurement","shots":["shot-02"],"kind":"contradiction","criterion":"t-4-ac1"}'
score "$(ev gap ',"evidence":"measurement","shot":"shot-02","impact":"medium"' "$GAP_MEAS")" \
      "$BDIR/tests-pass.json" "$BDIR/b9g"
check "B9. …but a FAULT raised from a measurement still stands" \
  "[ \"\$(lstatus '$BDIR/b9g/verdict.json' t-4-ac1)\" = gap ]"
check "B9. …and that standing fault still names the measurement as its kind" \
  "[ \"\$(levidence '$BDIR/b9g/verdict.json' t-4-ac1)\" = measurement ]"

# B9c. a measurement with no shot behind it is not a judgement (unchanged).
score "$(ev met ',"evidence":"measurement"')" "$BDIR/tests-pass.json" "$BDIR/b9b"
check "B9. …a measurement with no shot behind it is not a judgement" \
  "[ \"\$(lstatus '$BDIR/b9b/verdict.json' t-4-ac1)\" = untested ]"

# --- B10. THE LIMIT, IN THE HOUSE STYLE ------------------------------------
score "$(ev untested ',"evidence":"tests"')" "$BDIR/tests-pass.json" "$BDIR/b10"
check "B10. the report says it ran the tests and what they do not cover" \
  "grep -qi 'I ran your tests' '$BDIR/b10/report.md'"
check "B10. …and says the passing suite does not settle everything" \
  "grep -qi \"don't cover\\|do not cover\\|cannot tell you\\|can't tell you\" '$BDIR/b10/report.md'"
check "B10. …and names the command it actually ran" \
  "grep -q 'npm test' '$BDIR/b10/report.md'"
# CHANGED, S225 CHANGE 03 — THE OLD ASSERTION IS THE RULE THE CAPTAIN STRUCK
# OUT. `t-4-ac1` here is `untested`: the green suite did not settle it, which is
# a hole in OUR CHECKING and says nothing at all about his build. Forcing the
# grade off HIGH for it (`derive_grade`'s `high-unchecked`) made our failure read
# as a doubt about his work — the exact thing that graded his build LOW while he
# scored it HIGH himself. The grade no longer moves for it.
#
# THE S211 GUARD THIS WAS STANDING IN FOR IS UNTOUCHED, and is what is asserted
# now: the green suite still does not turn the row `met`, the row still names no
# evidence, the report still says what the suite does not cover — and the
# unchecked row is now named on OUR list, with the note that it is not his fault.
check "B10. …a green suite still does not settle an unchecked criterion (S211)" \
  "[ \"\$(lstatus '$BDIR/b10/verdict.json' t-4-ac1)\" = untested ] \
   && [ \"\$(levidence '$BDIR/b10/verdict.json' t-4-ac1)\" = none ]"
check "B10. …and the unchecked row is listed as OURS to fix, never against the build" \
  "[ \"\$(jget '$BDIR/b10/verdict.json' 'd[\"myChecking\"][\"total\"]')\" = 1 ] \
   && grep -q 'not a fault in your build' '$BDIR/b10/verdict.json' \
   && grep -q 't-4-ac1' '$BDIR/b10/verdict.json'"
check "B10. …and the grade never pretends it was checked: core is unverified and it says so" \
  "[ \"\$(jget '$BDIR/b10/verdict.json' 'd[\"core\"]')\" = unverified ] \
   && jget '$BDIR/b10/verdict.json' 'd[\"derivation\"]' | grep -qi 'could not check'"
# CONTROL — the two outcomes that DO grade still do. The same criterion, seen
# to fail with a picture behind it, still drives the grade to LOW.
score "$(ev gap ',"shot":"shot-02"')" "$BDIR/tests-pass.json" "$BDIR/b10c"
check "B10. CONTROL — the same criterion SEEN TO FAIL is still LOW" \
  "[ \"\$(jget '$BDIR/b10c/verdict.json' 'd[\"score\"]')\" = low ]"

# --- B11. no test command: a WORKS-question still needs more than a photo ----
# UPDATED for the captain's ruling, 2026-09-24. `t-4-ac1` ("batches survive a
# restart") is `notVisual` — a pure works-question. This fixture used to assert
# that a picture-backed met on it was "untouched" when no suite ran; that WAS
# the defect. A works-question the reviewer only photographed was never
# exercised (a picture shows a list is on screen, not that it survives a
# restart), so it now reads "couldn't check", not "worked" — the absence of a
# test command does not turn a photo into a check.
score "$(ev met ',"shot":"shot-03"')" "$BDIR/tests-none.json" "$BDIR/b11"
check "B11. with no test command, a picture-only WORKS-question is NOT met" \
  "[ \"\$(lstatus '$BDIR/b11/verdict.json' t-4-ac1)\" != met ]"
check "B11. …and it is surfaced by name as passing on a look alone" \
  "grep -q 'worksOnLookAlone' '$BDIR/b11/verdict.json' && grep -q 't-4-ac1' '$BDIR/b11/verdict.json'"
check "B11. …and the report says plainly that there is no suite to run" \
  "grep -qi 'no test command' '$BDIR/b11/report.md'"

# --- B12. THE REGRESSION CONTROL -------------------------------------------
# Called with no tests.json at all — the S210 argv — the machinery still runs
# and nothing crashes. UPDATED for the 2026-09-24 ruling: the base case USED to
# grade this HIGH on a photo of a works-question, which is exactly the score the
# ruling forbids. The old call still produces a verdict (no crash, no invented
# tests section); it simply no longer banks a works-question nobody exercised,
# so the picture-only `t-4-ac1` is not met and the build is not HIGH.
mkdir -p "$BDIR/b12"
printf '%s\n' "$(ev met ',"shot":"shot-03"')" >"$BDIR/b12/in.json"
"$PY" "$SCOREPY" "$BDIR/b12/in.json" "$BDIR/criteria.json" "$BDIR/b12/verdict.json" \
      >/dev/null 2>&1
check "B12. the old four-argument call still works" "[ -s '$BDIR/b12/verdict.json' ]"
check "B12. …and a works-question backed only by a photo is not banked as HIGH" \
  "[ \"\$(lstatus '$BDIR/b12/verdict.json' t-4-ac1)\" != met ] &&
   [ \"\$(jget '$BDIR/b12/verdict.json' 'd[\"score\"]')\" != high ]"
check "B12. …and no tests section is invented out of nothing" \
  "! grep -qi 'I ran your tests' '$BDIR/b12/report.md'"

# --- B13. the bug PRD a failing test files carries the failure -------------
mkdir -p "$BDIR/b13" "$BDIR/b13-shots"
"$PY" "$LOGSPY" "$BDIR/b6/verdict.json" "$BDIR/criteria.json" \
      "$BDIR/b13" "$BDIR/b13-shots" >"$BDIR/b13/out.tsv" 2>&1
check "B13. a test-sourced gap still files a bug" "[ -s '$BDIR/b13/1.md' ]"
check "B13. …and the bug carries the failing test line a fix worker needs" \
  "grep -q 'FAIL batches survive a restart' '$BDIR/b13/1.md'"

# ==========================================================================
echo
echo "C. fix round 1 — the captain must not be told something untrue"
# ==========================================================================
#
# Three defects, one shape: the skill's OWN deterministic sentence said
# something that was not so. Everything here is keyed off facts the record
# already holds — never off the wording of a runner's output (the S147/S156/
# S188/S212 family, which is forbidden in this file).

CDIR="$TMPROOT/cure"; mkdir -p "$CDIR/wt"

# --- C1 (D1). A RUNNER THAT CRASHED BEFORE RUNNING ANYTHING -----------------
# The groutwork shape: a dangling symlink where the test runner should be, so
# `require()` throws and the command exits 1 in a tenth of a second having run
# no test at all. The worker read it right ("your suite crashed at startup …
# so those two stay unchecked") and the SKILL's own next sentence said "I ran
# your tests and they FAILED".
#
# MEASURED, AND IT IS WHY THIS IS A WORDING CURE AND NOT A CLASSIFIER: on the
# tester's own fixtures the genuine failing suite ran 0.26s and printed 877
# bytes; the crashed runner ran 0.12s and printed 1030. Neither the duration
# nor the volume separates them, and the only thing that would (stdout empty,
# stderr full) is wrong for jest, which prints its whole report to stderr. So
# the sentence stops claiming the tests RAN — a sentence that cannot be right
# must not sound certain.
CBIN="$CDIR/bin"; mkdir -p "$CBIN"
cat >"$CBIN/crashrunner" <<'CR'
#!/usr/bin/env bash
echo "node:internal/modules/cjs/loader:1458" >&2
echo "Error: Cannot find module '/gone/node_modules/vitest'" >&2
exit 1
CR
chmod +x "$CBIN/crashrunner"
( export PATH="$CBIN:$PATH"
  "$PY" "$RUNNER" --out "$CDIR/tests-crash.json" --cwd "$CDIR/wt" --timeout 60 \
        --cap 8000 --command 'crashrunner' ) >/dev/null 2>&1 || true

check "C1. a crashed runner is still recorded with the facts it had" \
  "[ \"\$(jget '$CDIR/tests-crash.json' 'd[\"exitCode\"]')\" = 1 ] &&
   [ \"\$(jget '$CDIR/tests-crash.json' 'd[\"ran\"]')\" = true ]"
check "C1. the skill's own sentence NO LONGER claims the tests ran" \
  "! grep -qi 'and they failed' '$CDIR/tests-crash.json'"
check "C1. …it names the other thing a non-zero exit can mean" \
  "grep -qi 'never started\|could not start\|did not start' '$CDIR/tests-crash.json'"
check "C1. …and it does not count the exit code against the build on its own" \
  "grep -qi 'on its own' '$CDIR/tests-crash.json'"
# THE CONTROL. A suite that genuinely RUNS and FAILS must still say plainly
# that the run failed, and must still land its GAP with the failure quoted.
check "C1. CONTROL: a real failing run still says plainly that it FAILED" \
  "grep -qi 'the run failed' '$BDIR/tests-fail.json'"
check "C1. CONTROL: …and the same one sentence covers both, so neither is guessed at" \
  "[ \"\$(jget '$CDIR/tests-crash.json' 'd[\"outcome\"]')\" = failed ] &&
   [ \"\$(jget '$BDIR/tests-fail.json' 'd[\"outcome\"]')\" = failed ]"
mkdir -p "$CDIR/c1gap"
score "$(ev gap ',"evidence":"tests","testQuote":"FAIL batches survive a restart"' "$GAP_TESTS")" \
      "$BDIR/tests-fail.json" "$CDIR/c1gap"
check "C1. CONTROL: a real failing suite still lands its GAP" \
  "[ \"\$(lstatus '$CDIR/c1gap/verdict.json' t-4-ac1)\" = gap ]"
check "C1. CONTROL: …with the failure still quoted to him" \
  "grep -q 'FAIL batches survive a restart' '$CDIR/c1gap/report.md'"

# --- C2 (D2). AN EMPTY FIELD MUST SURVIVE THE SHELL -------------------------
# `xo.sh` reads xo-logs.py's plan with `read`. TAB is IFS WHITESPACE, so bash
# collapses a run of them: a gap with NO SHOT (which only became reachable when
# a test-sourced gap stopped needing a picture) lost its shots field and every
# field after it shifted left — logs.json recorded criterion="batches do not
# survive a restart", title="", and the captain's filing readout printed
# `log #2` with no title at all. S207 R4 cured the same class in `lcars status`
# with the same fix: a separator that is NOT IFS whitespace.
mkdir -p "$CDIR/c2" "$CDIR/c2-shots"
"$PY" "$LOGSPY" "$BDIR/b6/verdict.json" "$BDIR/criteria.json" \
      "$CDIR/c2" "$CDIR/c2-shots" >"$CDIR/c2/plan.txt" 2>&1
check "C2. the shotless test-sourced gap is emitted at all" \
  "grep -q '^GAP' '$CDIR/c2/plan.txt'"
check "C2. the plan's separator is NOT a tab (tab cannot carry an empty field)" \
  "! grep -q \"\$(printf '\\t')\" '$CDIR/c2/plan.txt'"
# THE PROOF: the record is read back with a REAL `read`, exactly as the shell
# does it, and the title — the last field, the one that vanished — survives.
# (`$'\037'` is bound to a variable first: bash 3.2 mis-parses a $'…' literal
# inside a command substitution inside double quotes, which is its own trap.)
XO_RS=$'\037'
gap_field() { # <plan file> <1-based field index>
  local l
  while IFS= read -r l; do
    case "$l" in
      GAP*) printf '%s' "$(printf '%s' "$l" | cut -d"$XO_RS" -f"$2")"; return 0 ;;
    esac
  done <"$1"
}
c2title="$(gap_field "$CDIR/c2/plan.txt" 6)"
check "C2. a gap with NO shot keeps its TITLE through the shell's read" \
  "[ -n '$c2title' ] && [ '$c2title' = 'batches do not survive a restart' ]"
c2crit="$(gap_field "$CDIR/c2/plan.txt" 5)"
check "C2. …and its criterion is a criterion id, not the next field over" \
  "[ '$c2crit' = 't-4-ac1' ]"
gap_title_by_read() { # <plan file> — xo.sh's OWN idiom, verbatim
  local l _k _n _p _s _c t
  while IFS= read -r l; do
    case "$l" in
      GAP*) IFS="$XO_RS" read -r _k _n _p _s _c t <<<"$l"; printf '%s' "$t"; return 0 ;;
    esac
  done <"$1"
}
c2read="$(gap_title_by_read "$CDIR/c2/plan.txt")"
check "C2. …read back by the shell's OWN idiom, not just by cut" \
  "[ '$c2read' = 'batches do not survive a restart' ]"
# THE CONTROL that proves this is about the EMPTY field and not the delimiter:
# the same reader on a gap that HAS a shot still parses.
mkdir -p "$CDIR/c2b" "$CDIR/c2b-shots"
"$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for g in d["gaps"]: g["shots"]=["shot-09"]
json.dump(d, open(sys.argv[2],"w"))' "$BDIR/b6/verdict.json" "$CDIR/c2b-in.json"
"$PY" "$LOGSPY" "$CDIR/c2b-in.json" "$BDIR/criteria.json" \
      "$CDIR/c2b" "$CDIR/c2b-shots" >"$CDIR/c2b/plan.txt" 2>&1
c2bshot="$(gap_field "$CDIR/c2b/plan.txt" 4)"
c2btitle="$(gap_field "$CDIR/c2b/plan.txt" 6)"
check "C2. CONTROL: a gap WITH a shot still parses, shot and title both" \
  "[ '$c2btitle' = 'batches do not survive a restart' ] &&
   case '$c2bshot' in *shot-09.png) true ;; *) false ;; esac"
# AND THE CLASS, NOT THE CALL SITE: xo-held.py feeds the same kind of reader in
# xo.sh and can emit an empty `mission`/`criterion` too.
check "C2. the held-fix plan uses the same non-whitespace separator" \
  "\"$PY\" -c 'import sys; sys.path.insert(0, sys.argv[1]); import importlib.util
spec = importlib.util.spec_from_file_location(\"h\", sys.argv[2])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if getattr(m, \"RS\", \"\\t\") == \"\\x1f\" else 1)' \
     '$REPO_ROOT/skills/lcars-xo' '$REPO_ROOT/skills/lcars-xo/xo-held.py'"

# --- C3 (D3). AN UNTESTED ROW SETTLED NOTHING, SO IT NAMES NO SOURCE --------
# `| t-4-ac1 | Batches survive a restart. | UNTESTED | a picture | shot-01 —
# Nothing on screen can settle whether batches survive a restart … |`. The
# column said "a picture"; the note in the same cell said nothing could be
# seen. On a hung or crashed run the same rows said "your tests". This is the
# session's own contract sentence, and naming the wrong source is worse than
# making him guess.
score "$(ev untested ',"shot":"shot-01"')" "$BDIR/tests-none.json" "$CDIR/c3"
check "C3. an UNTESTED row names no source of judgement" \
  "[ \"\$(levidence '$CDIR/c3/verdict.json' t-4-ac1)\" = none ]"
check "C3. …so the How I know column reads as the honest dash" \
  "! grep -q '| UNTESTED | a picture |' '$CDIR/c3/report.md'"
check "C3. …and the shot it did take is still named in What I saw" \
  "grep -q 'shot-01' '$CDIR/c3/report.md'"
score "$(ev untested ',"evidence":"tests","testQuote":"FAIL batches survive a restart"')" \
      "$BDIR/tests-fail.json" "$CDIR/c3b"
check "C3. an UNTESTED row does not claim the tests settled it either" \
  "[ \"\$(levidence '$CDIR/c3b/verdict.json' t-4-ac1)\" = none ] &&
   ! grep -q '| UNTESTED | your tests |' '$CDIR/c3b/report.md'"
check "C3. CONTROL: a MET row still names the source that decided it" \
  "[ \"\$(levidence '$BDIR/b1/verdict.json' t-4-ac1)\" = tests ] &&
   [ \"\$(levidence '$BDIR/b1/verdict.json' prd-1)\" = picture ]"

# --- C4 (D4). A TALLY LINE CANNOT SETTLE ANYTHING ---------------------------
# The guard cannot judge RELEVANCE — that is declared, and rests on the prompt,
# which held 12 of 12 live attacks. But a count line is a CLASS that can never
# settle ANY criterion, and refusing it needs no relevance judgement at all:
# strip the digits, the punctuation and the tally words, and nothing is left —
# the line names no subject. Braces for the belt; not a prose classifier.
cat >"$CDIR/bin/tally" <<'TL'
#!/usr/bin/env bash
printf 'PASS batches survive a restart\n'
printf 'Tests: 413 passed, 0 failed\n'
printf '\u2139 pass 2\n'
printf 'Duration  1.23s\n'
exit 0
TL
chmod +x "$CDIR/bin/tally"
( export PATH="$CBIN:$PATH"
  "$PY" "$RUNNER" --out "$CDIR/tests-tally.json" --cwd "$CDIR/wt" --timeout 60 \
        --cap 8000 --command 'tally' ) >/dev/null 2>&1 || true
for q in 'Tests: 413 passed, 0 failed' 'pass 2' 'Duration 1.23s'; do
  d="$CDIR/c4-$(printf '%s' "$q" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
  score "$(ev met ",\"evidence\":\"tests\",\"testQuote\":\"$q\"")" \
        "$CDIR/tests-tally.json" "$d"
  check "C4. a citation that is only a tally ($q) does not settle a criterion" \
    "[ \"\$(lstatus '$d/verdict.json' t-4-ac1)\" = untested ]"
done
check "C4. …and the report says WHY, in his words" \
  "grep -qi 'tally\|count of how many' '$CDIR/c4-tests413passed0failed/report.md'"
score "$(ev met ',"evidence":"tests","testQuote":"PASS batches survive a restart"')" \
      "$CDIR/tests-tally.json" "$CDIR/c4ok"
check "C4. CONTROL: a line that NAMES the thing still settles it" \
  "[ \"\$(lstatus '$CDIR/c4ok/verdict.json' t-4-ac1)\" = met ]"

# --- C5 (D5). A MET ON TESTS SAYS WHICH TEST ------------------------------
# It said "Your own tests cover this and they pass" and never which line. The
# quote is recorded and the guard already checks it against the output; a gap
# prints it. A met must too — same contract sentence as C3.
check "C5. a met on the tests quotes the line that settled it" \
  "grep -q 'PASS batches survive a restart' '$BDIR/b1/report.md'"
check "C5. …attributed to his tests, in the row itself" \
  "grep -q 'Your tests said' '$BDIR/b1/report.md'"
check "C5. CONTROL: a met on a PICTURE invents no test quote" \
  "! grep -q 'Your tests said' '$BDIR/b11/report.md'"

# --- C6 (D6). THE FILED BUG PRD MUST NOT INVITE A DECOY --------------------
# A test-sourced gap's PRD said "There is no shot for this one" and then, with
# no condition on it at all, "The fix is visible on the same screen the shot
# above was taken of." For a criterion with no visual surface that is an
# invitation to build a parallel dead control beside the real one — the exact
# class CONTEXT.md → Grounding exists to kill.
check "C6. a shotless bug PRD does not send a fix worker to a screen" \
  "! grep -q 'the shot above was taken of' '$CDIR/c2/1.md'"
check "C6. …it anchors the fix to the code the failing test already exercises" \
  "grep -qi 'test that reported this' '$CDIR/c2/1.md'"
check "C6. CONTROL: a bug WITH a shot still says where to look" \
  "grep -q 'the shot above was taken of' '$CDIR/c2b/1.md'"


# ==========================================================================
echo
echo "D. fix round 2 — a proven fault must be FILED, and the belt must not lie"
# ==========================================================================
#
# All three are one shape again: the record already held the fact, and the
# skill did not use it.

DDIR="$TMPROOT/round2"; mkdir -p "$DDIR"

# $1 = the t-4-ac1 ledger row's extra fields, $2 = the gaps body
ev2() {
  printf '{"score":"medium","summary":"Looked at the board.","criteria":['
  printf '{"id":"prd-1","text":"one list","status":"met","shot":"shot-01","note":"saw the list"},'
  printf '{"id":"t-4-ac1","text":"batches survive a restart","status":"gap"%s,"note":"the suite goes red on it"}' "$1"
  printf '],"gaps":[%s],"alsoChecked":[],"escalations":[]}' "$2"
}
gapkind() { # <verdict.json> <criterion id>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for g in d["gaps"]:
    if str(g.get("criterion")) == sys.argv[2]: print(g.get("kind","")); break' "$1" "$2" 2>/dev/null
}

# --- D1 (R2-1). THE SAME FACT, DECLARED ONCE, IS ENOUGH ---------------------
# MEASURED, 1 live spin in 4 on identical input: the worker declared
# `evidence:"tests"` + the failing line on the LEDGER ROW and left the matching
# GAP entry bare. The scorer read the gap entry only, found no shot and no
# declared test backing, and demoted a test-proven product fault to "a call the
# build made that your drawing does not cover" — the headline count fell 2 → 1
# and NO bug was ever filed for it. This is the output lottery, not a
# regression; the cure is to stop asking for the same fact twice. The ledger
# row for the SAME criterion id already carries a quote the guard has already
# checked against the recorded output, so that is what is used, through the
# SAME guard — never a new kind of trust.
GAP_BARE='{"title":"batches do not survive a restart","expected":"the batches you added to still be there","saw":"an empty list","shots":[],"kind":"contradiction","criterion":"t-4-ac1"}'
GAP_SHOT='{"title":"batches do not survive a restart","expected":"the batches you added to still be there","saw":"an empty list","shots":["shot-02"],"kind":"contradiction","criterion":"t-4-ac1"}'
LEDGER_TESTS=',"evidence":"tests","testQuote":"FAIL batches survive a restart"'

score "$(ev2 "$LEDGER_TESTS" "$GAP_BARE")" "$BDIR/tests-fail.json" "$DDIR/d1"
check "D1. a gap that declared nothing is backed by its OWN ledger row's quote" \
  "[ \"\$(gapkind '$DDIR/d1/verdict.json' t-4-ac1)\" = contradiction ]"
check "D1. …so the headline count agrees with the table: one contradiction" \
  "[ \"\$(jget '$DDIR/d1/verdict.json' 'd[\"counts\"][\"contradictions\"]')\" = 1 ]"
check "D1. …it is reported as a mismatch, not as a call the captain made" \
  "grep -q 'Where the build does not match' '$DDIR/d1/report.md' &&
   ! grep -q 'I am reading these as yours' '$DDIR/d1/report.md'"
check "D1. …the line his tests printed is quoted against it" \
  "grep -q 'FAIL batches survive a restart' '$DDIR/d1/report.md'"
check "D1. …and the derivation names it to him" \
  "grep -q 'batches do not survive a restart' '$DDIR/d1/verdict.json'"
mkdir -p "$DDIR/d1-logs" "$DDIR/d1-shots"
"$PY" "$LOGSPY" "$DDIR/d1/verdict.json" "$BDIR/criteria.json" \
      "$DDIR/d1-logs" "$DDIR/d1-shots" >"$DDIR/d1-logs/plan.txt" 2>&1
check "D1. …AND A BUG IS ACTUALLY FILED, so a fix round runs for it" \
  "[ -s '$DDIR/d1-logs/1.md' ] && grep -q '^GAP' '$DDIR/d1-logs/plan.txt'"
check "D1. …carrying the failing line the fix worker needs" \
  "grep -q 'FAIL batches survive a restart' '$DDIR/d1-logs/1.md'"

# CONTROL 1: nothing backs it ANYWHERE — no shot, no test line on either the
# gap or the ledger row. The demotion is the whole point of the guard and it
# must still happen. The fallback is a second place to LOOK, never a blanket
# promotion.
score "$(ev2 ',"evidence":"picture","shot":"shot-02"' "$GAP_BARE")" \
      "$BDIR/tests-fail.json" "$DDIR/d1b"
check "D1. CONTROL: a contradiction with no picture and no test line is STILL demoted" \
  "[ \"\$(gapkind '$DDIR/d1b/verdict.json' t-4-ac1)\" = interpretation ]"
check "D1. CONTROL: …and the headline count says so" \
  "[ \"\$(jget '$DDIR/d1b/verdict.json' 'd[\"counts\"][\"contradictions\"]')\" = 0 ]"

# CONTROL 2: the ledger row DOES cite the tests, and the line it cites is not
# in the recorded output. The same guard that refuses it on the ledger row must
# refuse it here — a fabricated quote must not be promoted by being in a second
# place.
score "$(ev2 ',"evidence":"tests","testQuote":"FAIL the mix ratio is remembered"' "$GAP_BARE")" \
      "$BDIR/tests-fail.json" "$DDIR/d1c"
check "D1. CONTROL: a ledger quote that FAILS the guard promotes nothing" \
  "[ \"\$(gapkind '$DDIR/d1c/verdict.json' t-4-ac1)\" = interpretation ]"
check "D1. CONTROL: …and that row is still recorded as not-checked" \
  "[ \"\$(lstatus '$DDIR/d1c/verdict.json' t-4-ac1)\" = untested ]"

# CONTROL 3: a contradiction WITH a shot is untouched by any of this.
score "$(ev2 ',"evidence":"picture","shot":"shot-02"' "$GAP_SHOT")" \
      "$BDIR/tests-fail.json" "$DDIR/d1d"
check "D1. CONTROL: a contradiction with a picture behind it is unchanged" \
  "[ \"\$(gapkind '$DDIR/d1d/verdict.json' t-4-ac1)\" = contradiction ]"

# CONTROL 4: no suite ran at all, so there is no second place to look.
score "$(ev2 "$LEDGER_TESTS" "$GAP_BARE")" "$BDIR/tests-none.json" "$DDIR/d1e"
check "D1. CONTROL: with no suite run, a bare contradiction is still demoted" \
  "[ \"\$(gapkind '$DDIR/d1e/verdict.json' t-4-ac1)\" = interpretation ]"

# --- D2 (R2-2). THE SENTENCE RESOLVES WHEN THE RECORD RESOLVES IT -----------
# D1's cure (round 1) made the failed-run sentence stop guessing which of the
# two things a non-zero exit meant. It then stayed agnostic FOREVER — in the
# most prominent position on the page — even on a report that goes on to quote
# a checked failing line. Both facts are at hand where the report is written:
# `outcome == "failed"` and a contradiction the tests guard passed.
check "D2. with a checked failing line, the sentence stops sitting on the fence" \
  "! grep -q 'the exit code does not say which' '$DDIR/d1/report.md' &&
   ! grep -q 'not counted it against the build on its own' '$DDIR/d1/report.md'"
check "D2. …and says plainly that a test of his went red" \
  "grep -qi 'went red' '$DDIR/d1/report.md'"
check "D2. …while the facts of the run are still all there" \
  "grep -q 'I ran your tests' '$DDIR/d1/report.md' && grep -q 'exit 1' '$DDIR/d1/report.md'"
# THE CONTROL, WHICH IS ROUND 1's CURE: a runner that crashed before running
# anything resolves NOTHING, so the agnostic sentence must survive here word
# for word.
score "$(ev2 ',"evidence":"picture","shot":"shot-02"' "$GAP_BARE")" \
      "$CDIR/tests-crash.json" "$DDIR/d2b"
check "D2. CONTROL: a crashed runner keeps the agnostic sentence exactly" \
  "grep -q 'the exit code does not say which' '$DDIR/d2b/report.md' &&
   grep -q 'not counted it against the build on its own' '$DDIR/d2b/report.md'"
check "D2. CONTROL: …and never claims a test of his went red" \
  "! grep -qi 'went red' '$DDIR/d2b/report.md'"

# THE PIN. The clause lives in two files that cannot import each other, and
# the swap above matches it byte for byte. If the wording ever moves in one of
# them, this says so here rather than the captain silently getting the hedged
# sentence on a report that has already resolved it.
check "D2. the hedged clause is the same string in both files that hold it" \
  "\"$PY\" -c 'import importlib.util, sys
def load(n, p):
    spec = importlib.util.spec_from_file_location(n, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
a = load(\"t\", sys.argv[1]).FAILED_AMBIGUOUS
b = load(\"s\", sys.argv[2]).FAILED_AMBIGUOUS
sys.exit(0 if a == b else 1)' '$RUNNER' '$SCOREPY'"

# --- D3 (R2-3). BOTH EDGES OF THE TALLY BELT --------------------------------
# It LEAKED at one edge (jest's `Ran all test suites.` got through because
# "all" was not a tally word; and a citation with NO WORDS AT ALL — `✔ 2`,
# `ℹ 413` — was ACCEPTED, because an empty word list made `all()` true and the
# function returned False) and it OVER-REFUSED at the other (`✔ 200 OK (1ms)`
# and `✔ case 3 passed (1ms)` are perfectly ordinary test names, and `200 OK`
# is exactly the API-shaped name this session exists to serve). And what the
# captain was told about his own test name — "the only line you quoted is a
# tally of how many tests passed or failed" — was simply untrue.
BELTDIR="$DDIR/belt"; mkdir -p "$BELTDIR/bin" "$BELTDIR/wt"
"$PY" - "$BELTDIR/bin/belt" <<'BELTPY'
import io, os, sys
lines = [
    # --- the tally lines. None of these can settle anything, ever. ---
    "Tests: 413 passed, 0 failed",
    "413 passed, 0 failed",
    "ℹ pass 2",
    "Duration  1.23s",
    "Ran all test suites.",
    "✔ 2",
    "ℹ 413",
    "ℹ tests 413",
    "Test Suites: 1 passed, 1 total",
    "Test Files  3 passed (3)",
    "3 passing (12ms)",
    "ℹ duration_ms 2419.5",
    # --- real test names, every one of which must survive the belt ---
    "PASS batches survive a restart",
    "FAIL batches survive a restart",
    "✔ batches survive a restart (2.83025ms)",
    "✖ batches survive a restart (2.83025ms)",
    "--- PASS: TestBatchesSurviveRestart (0.00s)",
    "--- FAIL: TestBatchesSurviveRestart (0.00s)",
    "ok 1 - batches survive a restart",
    "not ok 2 - batches survive a restart",
    "✓ src/batch.test.ts > batches survive a restart 3ms",
    "× src/batch.test.ts > batches survive a restart 3ms",
    "✔ les lots survivent à un redémarrage (1ms)",
    "✔ 批次在重启后仍然存在 (1ms)",
    "✔ 200 OK (1ms)",
    "✔ case 3 passed (1ms)",
    "✔ renders the empty state (1ms)",
    "✗ the mix ratio is remembered",
]
# printf '%s\n' "<line>", never printf '<line>' — a line beginning with a
# dash is read as an OPTION by printf, and two of the Go lines below start
# with three of them.
body = "".join("printf '%%s\\n' '%s'\n" % l.replace("'", "'\\''") for l in lines)
with io.open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\n" + body + "exit 0\n")
os.chmod(sys.argv[1], 0o755)
BELTPY
( export PATH="$BELTDIR/bin:$PATH"
  "$PY" "$RUNNER" --out "$BELTDIR/tests.json" --cwd "$BELTDIR/wt" --timeout 60 \
        --cap 20000 --command 'belt' ) >/dev/null 2>&1 || true
check "D3. the belt fixture is the real runner's own record of a green suite" \
  "[ \"\$(jget '$BELTDIR/tests.json' 'd[\"outcome\"]')\" = passed ]"

belt_case() { # <expect: refused|accepted> <n> <quote>
  local want="$1" n="$2" q="$3" d="$BELTDIR/$1-$2" got
  score "$(ev met ",\"evidence\":\"tests\",\"testQuote\":$("$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$q")")" \
        "$BELTDIR/tests.json" "$d"
  got="$(lstatus "$d/verdict.json" t-4-ac1)"
  if [ "$want" = refused ]; then
    check "D3. REFUSED: $q" "[ '$got' = untested ]"
  else
    check "D3. ACCEPTED: $q" "[ '$got' = met ]"
  fi
}
i=0
while IFS= read -r q; do
  [ -n "$q" ] || continue
  i=$((i + 1)); belt_case refused "$i" "$q"
done <<'REFUSE'
Tests: 413 passed, 0 failed
413 passed, 0 failed
pass 2
Duration  1.23s
Ran all test suites.
✔ 2
ℹ 413
ℹ tests 413
Test Suites: 1 passed, 1 total
Test Files  3 passed (3)
3 passing (12ms)
duration_ms 2419.5
REFUSE
i=0
while IFS= read -r q; do
  [ -n "$q" ] || continue
  i=$((i + 1)); belt_case accepted "$i" "$q"
done <<'ACCEPT'
PASS batches survive a restart
FAIL batches survive a restart
✔ batches survive a restart (2.83025ms)
✖ batches survive a restart (2.83025ms)
--- PASS: TestBatchesSurviveRestart (0.00s)
--- FAIL: TestBatchesSurviveRestart (0.00s)
ok 1 - batches survive a restart
not ok 2 - batches survive a restart
✓ src/batch.test.ts > batches survive a restart 3ms
× src/batch.test.ts > batches survive a restart 3ms
✔ les lots survivent à un redémarrage (1ms)
✔ 批次在重启后仍然存在 (1ms)
✔ 200 OK (1ms)
✔ case 3 passed (1ms)
✔ renders the empty state (1ms)
✗ the mix ratio is remembered
ACCEPT
# AND THE SENTENCE MUST NOT ASSERT SOMETHING UNTRUE ABOUT HIS OWN TEST NAME.
check "D3. the refusal says what it could not FIND, not what the line IS" \
  "grep -qi 'could not find' '$BELTDIR/refused-1/report.md' &&
   ! grep -q 'the only line you quoted is a tally' '$BELTDIR/refused-1/report.md'"
check "D3. …and still tells him, in his words, why a count settles nothing" \
  "grep -qi 'count of how many' '$BELTDIR/refused-1/report.md'"

# ==========================================================================
echo
echo "W. THE WORKSPACE BLIND SPOT (S213) — exit 127 on a pnpm monorepo"
#
# MEASURED ON THE CAPTAIN'S OWN REPO. `testCommand` is `npx vitest run …` and
# vitest is installed in a PACKAGE, not at the root. Run from the checkout root
# it is `sh: vitest: command not found`, exit 127 — so the most decisive
# evidence Number One has was blind on every workspace repo, and said so in a
# sentence about the build rather than about itself.
#
# EVERY BEHAVIOUR HERE SHIPS AS A PAIR. The rescue is narrow on purpose, and
# each control below is the same shape with ONE thing changed: a repo that is
# not a workspace, a package whose tests really are red, and a command that
# already aims itself. If any of those starts coming back green, the rescue has
# become a way of not noticing.
# ==========================================================================

WS="$TMPROOT/ws"; mkdir -p "$WS/bin"
# A stand-in `npx` that resolves out of ./node_modules/.bin exactly as the real
# one does, so "not found at the root, found in the package" is real behaviour
# and not something this test asserts into being.
cat >"$WS/bin/npx" <<'NPX'
#!/usr/bin/env bash
if [ -x "./node_modules/.bin/$1" ]; then b="$1"; shift; exec "./node_modules/.bin/$b" "$@"; fi
echo "sh: $1: command not found" >&2; exit 127
NPX
chmod +x "$WS/bin/npx"

mk_ws() { # <dir> <exit-code-for-ui>  → a pnpm workspace with two packages
  local root="$1" uirc="${2:-0}" p
  mkdir -p "$root"
  printf 'packages:\n  - "packages/*"\n' >"$root/pnpm-workspace.yaml"
  printf '{"name":"root","private":true}\n' >"$root/package.json"
  for p in engine ui; do
    mkdir -p "$root/packages/$p/node_modules/.bin"
    printf '{"name":"%s"}\n' "$p" >"$root/packages/$p/package.json"
    local rc=0; [ "$p" = "ui" ] && rc="$uirc"
    cat >"$root/packages/$p/node_modules/.bin/vitest" <<VT
#!/usr/bin/env bash
echo "$p: ran its own suite"
exit $rc
VT
    chmod +x "$root/packages/$p/node_modules/.bin/vitest"
  done
}

ws_run() { # <out.json> <cwd> <command>  → echoes the runner's exit code
  local out="$1" cwd="$2" cmd="$3" rc=0
  PATH="$WS/bin:$PATH" "$PY" "$RUNNER" --out "$out" --cwd "$cwd" --timeout 30 \
       --cap 8000 --command "$cmd" >"$out.stdout" 2>"$out.stderr" || rc=$?
  printf '%s' "$rc"
}

mk_ws "$WS/green" 0
rcW1="$(ws_run "$WS/w1.json" "$WS/green" 'npx vitest run')"
check "W1. a pnpm workspace no longer comes back 127 — the suite actually runs" \
  "[ \"\$(jget '$WS/w1.json' 'd[\"outcome\"]')\" = passed ] && [ '$rcW1' -eq 0 ]"
check "W1. …and WHERE it ran is recorded, not left to be worked out from the output" \
  "[ \"\$(jget '$WS/w1.json' 'd[\"ranIn\"]')\" = '[\"packages/engine\", \"packages/ui\"]' ]"
check "W1. …and what the ROOT said is kept, so nothing pretends the 127 never happened" \
  "[ \"\$(jget '$WS/w1.json' 'd[\"rootExitCode\"]')\" = 127 ]"
check "W1. …and the evidence carries both packages' output, each labelled" \
  "grep -q 'packages/engine' '$WS/w1.json' && grep -q 'packages/ui' '$WS/w1.json'"
check "W1. …and the sentence he reads says which packages answered" \
  "jget '$WS/w1.json' 'd[\"verdict\"]' | grep -q 'across 2 of your packages'"

# --- CONTROL 1: a genuinely red package is STILL red -----------------------
# The rescue must move the command somewhere it can run. It must never turn a
# failing suite green, which is the failure mode this project has paid for.
mk_ws "$WS/red" 3
rcW2="$(ws_run "$WS/w2.json" "$WS/red" 'npx vitest run')"
check "W2. CONTROL — a package whose tests really fail is STILL a failed run" \
  "[ \"\$(jget '$WS/w2.json' 'd[\"outcome\"]')\" = failed ] && [ '$rcW2' -eq 1 ]"
check "W2. CONTROL — …carrying the package's own exit code, not a rescued zero" \
  "[ \"\$(jget '$WS/w2.json' 'd[\"exitCode\"]')\" = 3 ]"

# --- CONTROL 2: a repo that is NOT a workspace is untouched ----------------
NOWS="$TMPROOT/nows"; mkdir -p "$NOWS"
printf '{"name":"plain"}\n' >"$NOWS/package.json"
rcW3="$(ws_run "$WS/w3.json" "$NOWS" 'npx vitest run')"
check "W3. CONTROL — a plain repo that cannot find its runner still says so, 127 and all" \
  "[ \"\$(jget '$WS/w3.json' 'd[\"outcome\"]')\" = failed ] && [ \"\$(jget '$WS/w3.json' 'd[\"exitCode\"]')\" = 127 ]"
check "W3. CONTROL — …and nothing claims it ran anywhere else" \
  "[ \"\$(jget '$WS/w3.json' 'd[\"ranIn\"]')\" = '' ]"

# --- CONTROL 3: THE DOUBLE-`cd` FOOTGUN ------------------------------------
# A testCommand that aims itself — `cd packages/engine && …` — is already where
# it means to be. Re-running it from INSIDE packages/engine makes its own `cd`
# land nowhere, and whether that ends the run or carries on in the wrong place
# comes down to `&&` versus `;`. So a command that aims itself is never re-aimed.
mk_ws "$WS/aimed" 0
rcW4="$(ws_run "$WS/w4.json" "$WS/aimed" 'cd packages/engine && npx vitest run')"
check "W4. a command that aims itself is left alone — it is never re-aimed" \
  "[ \"\$(jget '$WS/w4.json' 'd[\"ranIn\"]')\" = '' ]"
check "W4. …and it still works, because it was already pointing at the right place" \
  "[ \"\$(jget '$WS/w4.json' 'd[\"outcome\"]')\" = passed ] && [ '$rcW4' -eq 0 ]"

# --- CONTROL 3b: the bound is on the RUN, not on each package --------------
# Handing every package the full timeout turns a 300s cap into 300s x however
# many packages the repo has, which is not a bound at all. Two packages that
# each hang must still be stopped inside ONE budget.
mk_ws "$WS/slow" 0
for pkg in engine ui; do
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$WS/slow/packages/$pkg/node_modules/.bin/vitest"
  chmod +x "$WS/slow/packages/$pkg/node_modules/.bin/vitest"
done
t0W="$(date +%s)"
rcW6="$(PATH="$WS/bin:$PATH" "$PY" "$RUNNER" --out "$WS/w6.json" --cwd "$WS/slow" \
        --timeout 3 --cap 8000 --command 'npx vitest run' >/dev/null 2>&1; printf '%s' "$?")"
t1W="$(date +%s)"
check "W6. two hanging packages are stopped inside ONE budget, not one each" \
  "[ \$((t1W - t0W)) -lt 12 ]"
check "W6. …and the run is reported as a hang, never counted against the build" \
  "[ \"\$(jget '$WS/w6.json' 'd[\"outcome\"]')\" = hung ] && [ '$rcW6' -eq 2 ]"

# --- CONTROL 4: a root that works is never second-guessed ------------------
WORKS="$TMPROOT/worksatroot"; mkdir -p "$WORKS/node_modules/.bin"
printf 'packages:\n  - "packages/*"\n' >"$WORKS/pnpm-workspace.yaml"
printf '{"name":"root"}\n' >"$WORKS/package.json"
mkdir -p "$WORKS/packages/a"; printf '{"name":"a"}\n' >"$WORKS/packages/a/package.json"
printf '#!/usr/bin/env bash\necho "root suite ran"\nexit 0\n' >"$WORKS/node_modules/.bin/vitest"
chmod +x "$WORKS/node_modules/.bin/vitest"
rcW5="$(ws_run "$WS/w5.json" "$WORKS" 'npx vitest run')"
check "W5. CONTROL — a workspace whose runner IS at the root runs exactly once, at the root" \
  "[ \"\$(jget '$WS/w5.json' 'd[\"ranIn\"]')\" = '' ] && [ \"\$(jget '$WS/w5.json' 'd[\"outcome\"]')\" = passed ]"
check "W5. CONTROL — …and its sentence names no packages, because none were needed" \
  "! jget '$WS/w5.json' 'd[\"verdict\"]' | grep -q 'packages'"

# ==========================================================================
# S213 FIX ROUND 1, D4 — THE SCORE WORD MAY NOT ASSERT A FLOW NOBODY SAW.
#
# Measured on the captain's real board: a mission whose verdict was "nothing
# could be tested — the calculator never rendered", every criterion untested,
# wore MEDIUM, and MEDIUM's own hover text read "The primary flow works end to
# end; some criteria gap or could not be tested, none blocking the stated
# goal". Nobody ever saw that flow. It is the fault this whole session exists
# to kill, relocated from a line of copy into a tooltip — and it is the NORMAL
# path, because xo-score.py scores an all-untested ledger MEDIUM by design.
#
# So the sentence is decided HERE, beside the score, off the same ledger. These
# are the producer's half; the surfaces' half is web/tests/test_xo_surfaces.py.
# ==========================================================================
echo
echo "S213 D4 — what the score word MEANS is recorded, not assumed"

MDIR="$TMPROOT/meaning"; mkdir -p "$MDIR"
printf '{"criteria":[{"id":"prd-1","text":"the calculator adds","primary":true},{"id":"prd-2","text":"it subtracts","primary":true}],"hasDrawing":true}\n' >"$MDIR/criteria.json"

meaning_of() { # <ledger-json> <outdir>
  mkdir -p "$2"
  printf '%s\n' "$1" >"$2/in.json"
  "$PY" "$SCOREPY" "$2/in.json" "$MDIR/criteria.json" "$2/verdict.json" \
        "" "" >"$2/out.tsv" 2>"$2/err.txt"
  "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("scoreMeaning",""))' \
        "$2/verdict.json"
}

CRIT() { # <id> <status> — a MET line carries the PICTURE that settled it, or
         # the no-drawing guard rightly demotes it and every ledger here would
         # be all-untested, controls included.
  if [ "$2" = "met" ]; then
    printf '{"id":"%s","text":"a thing you asked for","status":"met","evidence":"picture","shot":"shot-01","note":"I saw it"}' "$1"
  else
    printf '{"id":"%s","text":"a thing you asked for","status":"%s","note":"n"}' "$1" "$2"
  fi
}

# THE MISSION FROM THE BOARD: nothing could be tested at all.
none_said="$(meaning_of "{\"score\":\"medium\",\"summary\":\"The calculator never rendered.\",\"criteria\":[$(CRIT prd-1 untested),$(CRIT prd-2 untested)],\"gaps\":[],\"alsoChecked\":[],\"escalations\":[]}" "$MDIR/none")"
check "D4 an all-untested ledger NEVER claims the primary flow works" \
  "! printf '%s' \"$none_said\" | grep -qi 'flow work'"
check "D4 …it says what actually happened to him: nothing was checked" \
  "printf '%s' \"$none_said\" | grep -qi 'could not check anything'"
check "D4 …and the tab reads the same recorded sentence, not one it derived" \
  "[ \"\$(\"$PY\" -c 'import json,sys;print(json.load(open(sys.argv[1]))[\"scoreMeaning\"])' '$MDIR/none/verdict.json')\" = \"$none_said\" ]"
# S216: nothing checked at all is LOW (the captain's ruling settled the old
# "MEDIUM when nothing could be checked" question).
check "D4 …the score is LOW — nothing checked is never a pass" \
  "grep -q '^SCORE'\$'\\t''low' '$MDIR/none/out.tsv'"
check "D4 …and the sentence rides the shell contract too, for state.json" \
  "grep -q '^MEANING'\$'\\t' '$MDIR/none/out.tsv'"

# CONTROL — a ledger where things WERE checked says so, and differently.
some_said="$(meaning_of "{\"score\":\"medium\",\"summary\":\"Most of it works.\",\"criteria\":[$(CRIT prd-1 met),$(CRIT prd-2 untested)],\"gaps\":[],\"alsoChecked\":[],\"escalations\":[]}" "$MDIR/some")"
check "D4 CONTROL — a ledger with something checked gets a DIFFERENT sentence" \
  "[ -n \"$some_said\" ] && [ \"$some_said\" != \"$none_said\" ]"
check "D4 CONTROL — …and it still never over-claims a flow" \
  "! printf '%s' \"$some_said\" | grep -qi 'flow work'"

# CONTROL — a clean sweep is allowed to say so.
all_said="$(meaning_of "{\"score\":\"high\",\"summary\":\"All good.\",\"criteria\":[$(CRIT prd-1 met),$(CRIT prd-2 met)],\"gaps\":[],\"alsoChecked\":[],\"escalations\":[]}" "$MDIR/all")"
check "D4 CONTROL — everything met still reads as ship-as-is" \
  "printf '%s' \"$all_said\" | grep -qi 'ship as is'"

# ==========================================================================
# S224 ITEM 2 — THE UNLISTED PASS ROUTES TO HIS CHANNEL, NEVER TO THE SCORE
#
# Measured on the S222 capstone: Number One filed every fault an acceptance
# criterion named and MISSED or DEMOTED every fault none did. The draft banner
# reading "Last edited —" was quoted verbatim and the row PASSED; the Preview
# button with no icon was a false pass, because the comparator asks whether an
# icon OVERFLOWS and has no way to ask whether one is ABSENT.
#
# The cure is one pass whose context has the criteria REMOVED, over the
# pictures the walk already took. What it finds is EVIDENCE FOR THE CAPTAIN,
# not a criterion he wrote — so it lands in `escalations`, the channel S222
# built, and it must be incapable of moving a single outcome or number.
#
# THIS BLOCK IS THE FENCE. It pins BOTH halves:
#   - the finding really reaches him (routing + attribution + the wire)
#   - the ledger it rode in beside is BYTE-IDENTICAL to the one scored
#     without it (no outcome, no count, no score, no gap)
# A finding that cannot name a shot the walk took is DROPPED, not escalated —
# the same citation discipline every other claim in this file is held to.
# ==========================================================================
echo
echo "U. the unlisted pass — his channel, never the score"

UDIR="$TMPROOT/unlisted"; mkdir -p "$UDIR"
printf '{"hasDrawing": true, "criteria": [
  {"id": "prd-1", "text": "the board shows every open task in one list", "primary": true},
  {"id": "prd-2", "text": "a task can be added from the board", "primary": true}
]}\n' >"$UDIR/criteria.json"

# ONE ledger, scored twice: once alone, once beside unlisted findings. Nothing
# about the ledger changes between the two runs, so any difference in the
# verdict is the unlisted pass reaching somewhere it must not.
U_LEDGER='{"score":"medium","summary":"Looked at the board.","criteria":[{"id":"prd-1","text":"one list","status":"met","shot":"shot-walk-02-j2","note":"saw the list"},{"id":"prd-2","text":"add a task","status":"met","shot":"shot-walk-03-j3","note":"the add button works"}],"gaps":[],"alsoChecked":[],"escalations":[]}'

uscore() { # <outdir> <unlisted.json or "">
  mkdir -p "$1"
  printf '%s\n' "$U_LEDGER" >"$1/in.json"
  "$PY" "$SCOREPY" "$1/in.json" "$UDIR/criteria.json" "$1/verdict.json" \
        "" "" "" "" "" "" "${2:-}" >"$1/out.tsv" 2>"$1/err.txt"
}

# THE INVENTORY IS THE PRODUCER'S, NOT THE MODEL'S. `xo.sh` knows exactly which
# pictures it put on the worker's side of the door, so it stamps that list into
# the record it writes. The worker cannot declare its own corpus, which is what
# makes the citation below checkable at all.
cat >"$UDIR/found.json" <<'UJ'
{"shots": ["shot-walk-02-j2", "shot-walk-03-j3"], "findings": [
  {"shot": "shot-walk-02-j2",
   "what": "the draft banner reads \"Last edited —\" with no date after it",
   "why": "a placeholder is showing where a timestamp belongs"},
  {"shot": "shot-walk-03-j3",
   "what": "the Preview button has no icon while every other button in that row has one",
   "why": "it reads as a different kind of control from its neighbours"}
]}
UJ

uscore "$UDIR/with" "$UDIR/found.json"
uscore "$UDIR/without" ""

check "U1. an unlisted finding reaches the captain's escalations" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(\"Last edited\" in e for e in d[\"escalations\"]) else 1)' '$UDIR/with/verdict.json'"
check "U1. …both of them, not just the first" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(\"Preview button has no icon\" in e for e in d[\"escalations\"]) else 1)' '$UDIR/with/verdict.json'"
check "U1. …ATTRIBUTED as something nobody asked about" \
  "grep -qi 'nobody asked' '$UDIR/with/verdict.json'"
check "U1. …and it rides the SAME wire the escalation channel already has" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$UDIR/with/out.tsv')\" -eq 2 ]"
check "U1. …and reaches report.md under what is his to decide" \
  "grep -q 'These are yours to decide' '$UDIR/with/report.md' &&
   grep -q 'Last edited' '$UDIR/with/report.md'"
check "U1. …kept structured too, so a surface never re-parses the prose" \
  "[ \"\$(\"$PY\" -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get(\"unlisted\") or []))' '$UDIR/with/verdict.json')\" -eq 2 ]"

# --- U2. THE INVARIANT ------------------------------------------------------
check "U2. the SCORE is the same with the findings as without" \
  "[ \"\$(grep '^SCORE'\$'\\t' '$UDIR/with/out.tsv')\" = \"\$(grep '^SCORE'\$'\\t' '$UDIR/without/out.tsv')\" ]"
check "U2. …the COUNTS are the same" \
  "[ \"\$(grep '^COUNTS'\$'\\t' '$UDIR/with/out.tsv')\" = \"\$(grep '^COUNTS'\$'\\t' '$UDIR/without/out.tsv')\" ]"
check "U2. …every criterion's outcome is BYTE-IDENTICAL" \
  "[ \"\$(\"$PY\" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps([(e[\"id\"],e[\"status\"]) for e in d[\"criteria\"]]))' '$UDIR/with/verdict.json')\" = \"\$(\"$PY\" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps([(e[\"id\"],e[\"status\"]) for e in d[\"criteria\"]]))' '$UDIR/without/verdict.json')\" ]"
check "U2. …no unlisted finding became a criterion" \
  "[ \"\$(\"$PY\" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))[\"criteria\"]))' '$UDIR/with/verdict.json')\" -eq 2 ]"
check "U2. …and none of them became a GAP the build is graded on" \
  "[ \"\$(\"$PY\" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))[\"gaps\"]))' '$UDIR/with/verdict.json')\" -eq 0 ]"
check "U2. …the grade's own reasoning never mentions them" \
  "! \"$PY\" -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if \"Last edited\" in (d[\"whyThisGrade\"]+d[\"derivation\"]+d[\"scoreMeaning\"]) else 1)' '$UDIR/with/verdict.json'"

# --- U3. THE CITATION GUARD -------------------------------------------------
# A finding that names a picture nobody took is an invention, and this project
# has lost rounds to inventions stated confidently. It is dropped.
cat >"$UDIR/invented.json" <<'UJ'
{"shots": ["shot-walk-02-j2", "shot-walk-03-j3"], "findings": [
  {"shot": "shot-walk-99-nobody-took-this",
   "what": "the settings drawer overlaps the footer", "why": "it looks wrong"},
  {"shot": "shot-walk-02-j2",
   "what": "the draft banner reads \"Last edited —\" with no date after it",
   "why": "a placeholder is showing where a timestamp belongs"}
]}
UJ
uscore "$UDIR/invented" "$UDIR/invented.json"
check "U3. a finding citing a shot nobody took is DROPPED" \
  "! grep -q 'settings drawer' '$UDIR/invented/verdict.json'"
check "U3. …and the one that cites a real shot still gets through" \
  "grep -q 'Last edited' '$UDIR/invented/verdict.json'"
check "U3. …and the drop is DISCLOSED, never silent" \
  "grep -qi 'could not name a picture' '$UDIR/invented/verdict.json'"

# --- U4. CONTROL — silence stays silent -------------------------------------
# A pass that reports something every time is worthless: it buries him and
# teaches him to ignore the channel (S212). Nothing found must add NOTHING.
printf '{"shots": ["shot-walk-02-j2"], "findings": []}\n' >"$UDIR/none.json"
uscore "$UDIR/quiet" "$UDIR/none.json"
check "U4. CONTROL — no findings adds no escalation" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$UDIR/quiet/out.tsv')\" -eq 0 ]"
check "U4. CONTROL — …and no section in the report at all" \
  "! grep -q 'These are yours to decide' '$UDIR/quiet/report.md'"
check "U4. CONTROL — …and the verdict is byte-identical to one scored without the pass" \
  "diff -q '$UDIR/quiet/verdict.json' '$UDIR/without/verdict.json' >/dev/null"

# --- U5. THE LOOK'S OWN ESCALATIONS ARE NOT DISPLACED -----------------------
# The channel was built for what the LOOK put aside for him. An unlisted
# finding joins that list; it never replaces it.
printf '%s\n' "${U_LEDGER%\"escalations\":[]\}}\"escalations\":[\"the August card opened a September review\"]}" >"$UDIR/both-in.json"
mkdir -p "$UDIR/both"
cp "$UDIR/both-in.json" "$UDIR/both/in.json"
"$PY" "$SCOREPY" "$UDIR/both/in.json" "$UDIR/criteria.json" "$UDIR/both/verdict.json" \
      "" "" "" "" "" "" "$UDIR/found.json" >"$UDIR/both/out.tsv" 2>"$UDIR/both/err.txt"
check "U5. the look's own escalation survives beside the unlisted ones" \
  "grep -q 'August card opened a September review' '$UDIR/both/verdict.json'"
check "U5. …and all three reach the wire" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$UDIR/both/out.tsv')\" -eq 3 ]"

# ==========================================================================
# W. THE WALK'S OWN FAULTS, AND THE MOMENTS A ROW RESTS ON (S224 fix round 3)
# ==========================================================================
#
# TWO THINGS THE MODEL WAS BEING TRUSTED TO DO BY ITSELF, AND DID ONCE EACH.
#
# W1–W3: a fault only a walk can find — a value that was on the screen you came
# from and is different on the screen you arrive at — was put in front of the
# captain on one run and, measured again in the SAME WORDS on the next, never
# left the file. Nothing on his list can name one of those, because his list
# describes screens and this is a seam between them. So it is routed, not hoped
# for. The control is a measurement that IS anchored to a part of the drawing:
# a `part-…` row answers for that one, and it must not be handed to him twice.
#
# W4–W6: a row about something that stays on screen has several moments it could
# be judged at, and the look was settling those on whichever picture it reached
# for. The walk's own record says which places read differently and when; the
# note says which moment a row rests on. It does NOT move the outcome — on the
# captain's own build the same rule fires on three rows and only one is a fault,
# the other two being counters counting, and calling those faults is exactly how
# a channel earns being ignored (S212).

WDIR="$TMPROOT/walked"; mkdir -p "$WDIR"
cat >"$WDIR/criteria.json" <<'WC'
{"hasDrawing": true, "criteria": [
  {"id": "prd-1", "text": "one list", "primary": true},
  {"id": "part-preview", "text": "the Preview button", "primary": false}
]}
WC

# The look's ledger. `prd-1` is graded on a LATE moment of the walk.
W_LEDGER='{"score":"medium","summary":"Looked at the board.","criteria":[{"id":"prd-1","text":"one list","status":"met","shot":"shot-walk-07-j7","note":"the meta line reads Last edited Sep 22, 2026 and 4 of 5 buckets complete"},{"id":"part-preview","text":"the Preview button","status":"met","shot":"shot-walk-02-j2","note":"the Preview button renders with its label"}],"gaps":[],"alsoChecked":[],"escalations":[]}'

# What the walk measured. ONE is a seam between screens (no `part` — nothing on
# his list can name it); ONE is anchored to a drawn part (`part` present — the
# `part-preview` row answers for it).
cat >"$WDIR/observations.json" <<'WO'
{"thresholds": {}, "observations": [
  {"says": "August 2026 became September 2026 after I clicked pull data and start - the month did not carry from one screen to the next",
   "kind": "carried-value", "fromWalk": true, "screen": "http://localhost:1/x#b", "shot": "shot-walk-01-j1"},
  {"says": "the Preview button holds an icon 41px tall inside a control only 30px tall",
   "kind": "oversized-icon", "part": "Preview", "screen": "http://localhost:1/x#b"}
]}
WO

# The walk itself: the same screen at two moments, one place reading differently
# at each, beside a second place that is a counter counting.
cat >"$WDIR/walk.json" <<'WW'
{"steps": [
  {"key": "j2", "do": "click", "status": "done",
   "urlBefore": "http://localhost:1/x#a", "textBefore": "a start card",
   "urlAfter": "http://localhost:1/x#b",
   "textAfter": "Draft saved as you go. Last edited - and 3 of 5 buckets complete. Insights added 16 of 19 KPIs."},
  {"key": "j5", "do": "type", "status": "done",
   "urlBefore": "http://localhost:1/x#b",
   "textBefore": "Draft saved as you go. Last edited - and 3 of 5 buckets complete. Insights added 16 of 19 KPIs.",
   "urlAfter": "http://localhost:1/x#b",
   "textAfter": "Draft saved as you go. Last edited Sep 22, 2026 and 4 of 5 buckets complete. Insights added 18 of 19 KPIs."}
]}
WW

"$PY" "$REPO_ROOT/skills/lcars-xo/xo-readings.py" "$WDIR/walk.json" "$WDIR/readings.json" >/dev/null 2>&1

wscore() { # <outdir> <ledger json> [<readings.json>]
  mkdir -p "$1"
  printf '%s\n' "$2" >"$1/in.json"
  "$PY" "$SCOREPY" "$1/in.json" "$WDIR/criteria.json" "$1/verdict.json" \
        "$WDIR/observations.json" "" "" "" "$WDIR/walk.json" "" "" "${3:-}" \
        >"$1/out.tsv" 2>"$1/err.txt"
}
wscore "$WDIR/on" "$W_LEDGER" "$WDIR/readings.json"

check "W1. a fault only the walk could find reaches his escalations" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(\"did not carry\" in e for e in d[\"escalations\"]) else 1)' '$WDIR/on/verdict.json'"
check "W1. …said as something no list asks about, with the picture named" \
  "grep -q 'nothing on your list asks about it' '$WDIR/on/verdict.json' &&
   grep -q 'shot-walk-01-j1' '$WDIR/on/verdict.json'"
check "W1. …on the SAME wire, not a second channel" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$WDIR/on/out.tsv')\" -eq 1 ]"

check "W2. CONTROL — a measurement a drawn part answers for is NOT escalated" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not any(\"41px\" in e for e in d[\"escalations\"]) else 1)' '$WDIR/on/verdict.json'"

# W2b. THE CONTROL THE D5 REGRESSION EARNED. The first cut of this rule asked
# whether a measurement named a drawn part, and routed one that did not. A
# part-measurement whose `part` field is simply missing then read as "nothing on
# his list can name this" — and `lcars-xo-observe` §D5 caught it, because a rule
# that reads meaning out of an ABSENT field will eventually be wrong about a
# present one. Only what the walk STAMPED is routed.
cat >"$WDIR/obs-nopart.json" <<'WN'
{"thresholds": {}, "observations": [
  {"says": "the Back to builder button holds an icon 41px tall inside a control only 30px tall",
   "kind": "oversized-icon", "screen": "http://localhost:1/x#b"}
]}
WN
mkdir -p "$WDIR/nopart"
printf '%s\n' "$W_LEDGER" >"$WDIR/nopart/in.json"
"$PY" "$SCOREPY" "$WDIR/nopart/in.json" "$WDIR/criteria.json" "$WDIR/nopart/verdict.json" \
      "$WDIR/obs-nopart.json" "" "" "" "$WDIR/walk.json" "" "" "$WDIR/readings.json" \
      >"$WDIR/nopart/out.tsv" 2>"$WDIR/nopart/err.txt"
check "W2b. CONTROL — a measurement with NO part field is still not escalated" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$WDIR/nopart/out.tsv')\" -eq 0 ]"

# W3. …and a fact the LOOK already put in front of him is not handed over twice.
W_SAID='{"score":"medium","summary":"Looked.","criteria":[{"id":"prd-1","text":"one list","status":"met","shot":"shot-walk-07-j7","note":"saw it"}],"gaps":[],"alsoChecked":[],"escalations":["The next-up month jumped from August 2026 on the start card to September 2026 after I clicked pull data and start, so the month did not carry from one screen to the next"]}'
wscore "$WDIR/dup" "$W_SAID" "$WDIR/readings.json"
check "W3. CONTROL — a fault the look already escalated is not repeated" \
  "[ \"\$(grep -c '^ESCALATION'\$'\\t' '$WDIR/dup/out.tsv')\" -eq 1 ]"

check "W4. a row graded on a later moment says which moment it rests on" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(n.startswith(\"prd-1 was read at one moment\") for n in (d.get(\"ledgerNotes\") or [])) else 1)' '$WDIR/on/verdict.json'"
check "W4. …and quotes what the same place said at the FIRST moment" \
  "grep -q '3 of 5 buckets' '$WDIR/on/verdict.json'"

check "W5. CONTROL — the outcome is NOT moved by it" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if [c[\"status\"] for c in d[\"criteria\"]] == [\"met\",\"met\"] and d[\"counts\"][\"gap\"] == 0 else 1)' '$WDIR/on/verdict.json'"
check "W5. CONTROL — …and a row that names NO changed reading gets no note" \
  "! grep -q 'part-preview was read at one moment' '$WDIR/on/verdict.json'"

# W6. CONTROL — a screen whose words never change produces nothing at all.
cat >"$WDIR/still.json" <<'WS'
{"steps": [
  {"key": "j1", "do": "click", "status": "done",
   "urlBefore": "http://localhost:1/x#b", "textBefore": "Last edited - and 3 of 5 buckets complete.",
   "urlAfter": "http://localhost:1/x#b", "textAfter": "Last edited - and 3 of 5 buckets complete."}
]}
WS
"$PY" "$REPO_ROOT/skills/lcars-xo/xo-readings.py" "$WDIR/still.json" "$WDIR/still-readings.json" >/dev/null 2>&1
check "W6. CONTROL — a screen that never changed records no readings" \
  "[ \"\$(\"$PY\" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))[\"readings\"]))' '$WDIR/still-readings.json')\" -eq 0 ]"
wscore "$WDIR/off" "$W_LEDGER" "$WDIR/still-readings.json"
check "W6. CONTROL — …and then no row is accused of resting on one moment" \
  "! grep -q 'was read at one moment' '$WDIR/off/verdict.json'"


# ==========================================================================
echo
echo "R. RECONCILE THE RECORDS BEFORE THE GRADE (Number One)"
# The reviewer keeps several records of ONE look — the walk, the probe/action
# pass, the verdict. Nothing reconciled them, and where they disagreed the most
# generous set the grade. These reconcile them: a disagreement is written down
# and surfaced, never resolved silently in the build's favour. RECORD, DO NOT
# INFER — each assertion reads a field a producer wrote, compared to another
# field a producer wrote.
# ==========================================================================
NDIR="$TMPROOT/reconcile"; mkdir -p "$NDIR"

# --- R4: the walk must use what the probe/action pass already found --------
# Mission "Name your hero", measured 2026-09-23. In ONE look the probe pressed
# `n`, opened the hero panel and photographed its validation bubble; the WALK,
# separately, hunted for a button, failed, and called the screen unreachable.
# The grade came from the walk — a working screen graded as if it did not exist.
cat >"$NDIR/criteria.json" <<'NC'
{"criteria": [
  {"id": "hero", "text": "the hero naming screen", "primary": true,
   "source": "prd", "journeyStep": "j-hero"}
], "hasDrawing": false}
NC
cat >"$NDIR/walk.json" <<'NW'
{"steps": [
  {"key": "j-hero", "do": "click", "status": "unreachable",
   "couldNotCheck": "unreachable", "name": "click \"Save hero\"",
   "onScreen": "a name field and an n hint",
   "urlBefore": "http://localhost:1/x#hero"}
]}
NW
cat >"$NDIR/observations.json" <<'NO'
{"thresholds": {}, "observations": [
  {"says": "the hero name field shows a validation bubble reading give your hero a name",
   "kind": "reached", "screen": "http://localhost:1/x#hero", "shot": "shot-hero"}
]}
NO
N_LEDGER='{"score":"high","summary":"The hero screen names a hero.","criteria":[{"id":"hero","text":"the hero naming screen","status":"met","shot":"shot-hero","evidence":"picture","action":"pressed n, opened the hero panel, read the validation bubble","note":"the panel opened and validated"}],"gaps":[],"alsoChecked":[],"escalations":[]}'

nscore() { # <outdir> <ledger> <observations>
  mkdir -p "$1"; printf '%s\n' "$2" >"$1/in.json"
  "$PY" "$SCOREPY" "$1/in.json" "$NDIR/criteria.json" "$1/verdict.json" \
        "$3" "" "" "" "$NDIR/walk.json" "" "" "" >"$1/out.tsv" 2>"$1/err.txt"
}
nscore "$NDIR/reached" "$N_LEDGER" "$NDIR/observations.json"

check "R4. the walk said unreachable but the probe reached that screen — NOT downgraded" \
  "[ \"\$(jget '$NDIR/reached/verdict.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"hero\"][0][\"status\"]')\" = met ]"
check "R4. …and the two records disagreeing is written down, by name" \
  "\"$PY\" -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get(\"reconciled\") or []; sys.exit(0 if any(x[\"id\"]==\"hero\" and x.get(\"kind\")==\"walk-overruled-by-probe\" for x in r) else 1)' '$NDIR/reached/verdict.json'"

# CONTROL: with the probe standing on a DIFFERENT screen, nothing contradicts
# the walk, so its unreachable still stands — the existing guard is untouched.
cat >"$NDIR/obs-elsewhere.json" <<'NE'
{"thresholds": {}, "observations": [
  {"says": "the landing page shows a start button", "kind": "layout",
   "screen": "http://localhost:1/x#landing"}
]}
NE
nscore "$NDIR/elsewhere" "$N_LEDGER" "$NDIR/obs-elsewhere.json"
check "R4. CONTROL — no probe on that screen, so the walk's unreachable still downgrades it" \
  "[ \"\$(jget '$NDIR/elsewhere/verdict.json' '[c for c in d[\"criteria\"] if c[\"id\"]==\"hero\"][0][\"status\"]')\" = untested ]"

# --- R3: a pass records WHICH record settled it, and what that record did ---
cat >"$NDIR/crit2.json" <<'NC2'
{"criteria": [
  {"id": "bytest", "text": "batches survive a restart", "primary": true, "source": "prd"},
  {"id": "bylook", "text": "the list renders", "primary": true, "source": "prd"}
], "hasDrawing": false}
NC2
cat >"$NDIR/tests.json" <<'NT'
{"ran": true, "outcome": "passed", "command": "npm test", "exitCode": 0,
 "durationMs": 10, "outputTail": "PASS batches survive a restart\nTests: 42 passed",
 "tailCapBytes": 8000, "truncated": false}
NT
# bytest is settled by a named test line; bylook by a bare screenshot, no action.
L2='{"score":"high","summary":"looked and tested.","criteria":[{"id":"bytest","text":"restart","status":"met","evidence":"tests","testQuote":"PASS batches survive a restart","note":"green"},{"id":"bylook","text":"the list renders","status":"met","shot":"shot-01","evidence":"picture","note":"saw the list"}],"gaps":[],"alsoChecked":[],"escalations":[]}'
mkdir -p "$NDIR/s3"; printf '%s\n' "$L2" >"$NDIR/s3/in.json"
"$PY" "$SCOREPY" "$NDIR/s3/in.json" "$NDIR/crit2.json" "$NDIR/s3/verdict.json" \
      "" "$NDIR/tests.json" >"$NDIR/s3/out.tsv" 2>"$NDIR/s3/err.txt"

check "R3. a pass settled by the tests records that, and the line that did it" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"bytest\"][0]
sb=e.get(\"settledBy\") or {}
sys.exit(0 if sb.get(\"record\")==\"tests\" and \"batches survive a restart\" in (sb.get(\"did\") or \"\") else 1)' '$NDIR/s3/verdict.json'"
check "R3. a pass that did no more than look at a screenshot is marked look-only" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"bylook\"][0]
sb=e.get(\"settledBy\") or {}
sys.exit(0 if sb.get(\"record\")==\"picture\" and sb.get(\"lookedOnly\") is True else 1)' '$NDIR/s3/verdict.json'"

# --- R2: the illegitimate combination is visible in the output, by name ----
check "R2. a passing row backed by nothing but a screenshot is listed, by name" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
p=d.get(\"passingOnLookAlone\") or []
sys.exit(0 if any(x[\"id\"]==\"bylook\" for x in p) and all(x[\"id\"]!=\"bytest\" for x in p) else 1)' '$NDIR/s3/verdict.json'"


# ==========================================================================
echo
echo "K. THE KIND OF QUESTION DECIDES THE KIND OF PROOF (Captain, 2026-09-24)"
# Number One establishes things two ways — it PRESSES and it PHOTOGRAPHS — and
# today both count equally as proof. They are not equal. A LOOKS-question ("the
# title is there") a picture genuinely settles. A WORKS-question ("Save saves")
# only an ACTION settles; a picture of a button proves it is DRAWN, not that it
# DOES anything. Measured damage: builds got credit for "pausing works" from a
# photo showing a Pause button exists.
#
# RECORD, DO NOT INFER (this session's whole point, and LCARS has lost three
# sessions to prose heuristics): the KIND is a produce-time STAMP the criterion
# carries — `kind: "looks"|"works"`, or the planner's own `notVisual: true`
# stamp (a criterion that makes no visual claim IS a works-question). The
# consumer READS the stamp; it never reads the criterion's prose to guess.
# ==========================================================================
KDIR="$TMPROOT/kind"; mkdir -p "$KDIR"

kscore() { # <outdir> <criteria.json> <ledger>
  mkdir -p "$1"; printf '%s\n' "$3" >"$1/in.json"
  "$PY" "$SCOREPY" "$1/in.json" "$2" "$1/verdict.json" >"$1/out.tsv" 2>"$1/err.txt"
}

# One contract, two stamped questions: a looks-question and a works-question,
# both PRD (person group, so both are graded).
cat >"$KDIR/criteria.json" <<'KC'
{"criteria": [
  {"id": "look1", "text": "the title bar shows the app name", "primary": true,
   "source": "prd", "kind": "looks"},
  {"id": "work1", "text": "the Save button saves the document", "primary": true,
   "source": "prd", "kind": "works"}
], "hasDrawing": false}
KC

# THE DEFECT, REPRODUCED: BOTH settled by a picture alone — a shot, no action,
# no test. Today both read "worked".
KL_PIC='{"score":"high","summary":"Looks right.","criteria":[{"id":"look1","text":"the title bar shows the app name","status":"met","shot":"shot-01","evidence":"picture","note":"the title bar reads the app name"},{"id":"work1","text":"the Save button saves the document","status":"met","shot":"shot-02","evidence":"picture","note":"a Save button is visible in the toolbar"}],"gaps":[],"alsoChecked":[],"escalations":[]}'
kscore "$KDIR/pic" "$KDIR/criteria.json" "$KL_PIC"

krow() { # <verdict> <id> <field-expr over row `r`>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
r=[c for c in d["criteria"] if c["id"]==sys.argv[2]][0]
v=eval(sys.argv[3])
print("" if v is None else (v if isinstance(v,str) else json.dumps(v)))' "$1" "$2" "$3" 2>/dev/null
}

# --- K1. CONTROL — a looks-question settled by a picture is a FULL PASS ------
# This control is non-negotiable: without it the cure could silently turn every
# picture into a failure, the exact over-correction the captain warned against.
check "K1. CONTROL a looks-question backed by a picture still passes cleanly" \
  "[ \"\$(krow '$KDIR/pic/verdict.json' look1 'r[\"status\"]')\" = met ]"
check "K1. CONTROL …and it carries its produce-time kind, read from the stamp" \
  "[ \"\$(krow '$KDIR/pic/verdict.json' look1 'r.get(\"questionKind\")')\" = looks ]"
check "K1. CONTROL …and it is NOT flagged as passing on a look it shouldn't" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
w=d.get(\"worksOnLookAlone\") or []
sys.exit(0 if all(x[\"id\"]!=\"look1\" for x in w) else 1)' '$KDIR/pic/verdict.json'"

# --- K2. a works-question backed ONLY by a picture is NOT a pass ------------
check "K2. a works-question backed only by a picture does NOT read 'worked'" \
  "[ \"\$(krow '$KDIR/pic/verdict.json' work1 'r[\"status\"]')\" != met ]"
check "K2. …its outcome is 'couldn't set up' (it was never exercised)" \
  "[ \"\$(krow '$KDIR/pic/verdict.json' work1 'r.get(\"outcome\")')\" = couldnt-set-up ]"
check "K2. …the words a person reads say I could not check it, never worked" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
r=[c for c in d[\"criteria\"] if c[\"id\"]==\"work1\"][0]
n=(r.get(\"note\") or \"\").lower()
sys.exit(0 if (\"could not check\" in n or \"couldn'\''t check\" in n) and \"worked\" not in n else 1)' '$KDIR/pic/verdict.json'"
check "K2. …and it is surfaced BY NAME on the works-on-look-alone list" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
w=d.get(\"worksOnLookAlone\") or []
sys.exit(0 if any(x[\"id\"]==\"work1\" for x in w) else 1)' '$KDIR/pic/verdict.json'"

# --- K3. a works-question settled by an ACTION IS a full pass ---------------
# Pressing is what a works-question needs; when it happens, full marks.
KL_ACT='{"score":"high","summary":"Save works.","criteria":[{"id":"look1","text":"the title bar shows the app name","status":"met","shot":"shot-01","evidence":"picture","note":"the title bar reads the app name"},{"id":"work1","text":"the Save button saves the document","status":"met","shot":"shot-02","evidence":"picture","action":"clicked Save, reloaded the page, the document was still there","note":"the edit persisted across a reload"}],"gaps":[],"alsoChecked":[],"escalations":[]}'
kscore "$KDIR/act" "$KDIR/criteria.json" "$KL_ACT"
check "K3. a works-question actually exercised stays MET" \
  "[ \"\$(krow '$KDIR/act/verdict.json' work1 'r[\"status\"]')\" = met ]"
check "K3. …and it records that an action settled it, not a picture" \
  "[ \"\$(krow '$KDIR/act/verdict.json' work1 'r.get(\"settledBy\",{}).get(\"record\")')\" = action ]"
check "K3. …so it is NOT on the works-on-look-alone list" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
w=d.get(\"worksOnLookAlone\") or []
sys.exit(0 if all(x[\"id\"]!=\"work1\" for x in w) else 1)' '$KDIR/act/verdict.json'"

# --- K4. the planner's own `notVisual` stamp IS a works-question ------------
# A criterion that makes no visual claim cannot be settled by a picture of the
# screen; the produce-time stamp already says so, and the consumer reads it.
cat >"$KDIR/nv.json" <<'NVC'
{"criteria": [
  {"id": "nv1", "text": "batches persist across a restart", "primary": true,
   "source": "plan", "notVisual": true}
], "hasDrawing": false}
NVC
KL_NV='{"score":"high","summary":"Persists.","criteria":[{"id":"nv1","text":"batches persist across a restart","status":"met","shot":"shot-03","evidence":"picture","note":"I saw the batch list on screen"}],"gaps":[],"alsoChecked":[],"escalations":[]}'
kscore "$KDIR/nv" "$KDIR/nv.json" "$KL_NV"
check "K4. a notVisual criterion is a works-question, read from its stamp" \
  "[ \"\$(krow '$KDIR/nv/verdict.json' nv1 'r.get(\"questionKind\")')\" = works ]"
check "K4. …and picture-only, it does not read 'worked'" \
  "[ \"\$(krow '$KDIR/nv/verdict.json' nv1 'r[\"status\"]')\" != met ]"
check "K4. …and its kind was read from the notVisual stamp, recorded plainly" \
  "[ \"\$(krow '$KDIR/nv/verdict.json' nv1 'r.get(\"questionKindFrom\")')\" = notVisual ]"

# --- K5. the split is said out loud, as data and as words -------------------
check "K5. the verdict carries the split of looks vs works questions" \
  "\"$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
s=d.get(\"questionSplit\") or {}
sys.exit(0 if s.get(\"looks\")==1 and s.get(\"works\")==1 and s.get(\"worksExercised\")==0 and s.get(\"worksPictureOnly\")==1 else 1)' '$KDIR/pic/verdict.json'"
check "K5. …and the report says the split in words a person reads" \
  "grep -qi 'works-question' '$KDIR/pic/report.md'"

# --- K6. it may not grade HIGH on works-questions it never exercised --------
# A whole mission of works-questions, every one backed by nothing but a photo,
# must NOT come out high — it collapsed into looks-questions before this cure.
cat >"$KDIR/allwork.json" <<'AWC'
{"criteria": [
  {"id": "w1", "text": "pressing space pauses the game", "primary": true, "source": "prd", "kind": "works"},
  {"id": "w2", "text": "the Reset button clears the board", "primary": true, "source": "prd", "kind": "works"},
  {"id": "w3", "text": "a bad name shows an error", "primary": true, "source": "prd", "kind": "works"},
  {"id": "w4", "text": "the score goes up when you score", "primary": true, "source": "prd", "kind": "works"}
], "hasDrawing": false}
AWC
KL_ALLWORK='{"score":"high","summary":"All present.","criteria":[{"id":"w1","text":"pressing space pauses the game","status":"met","shot":"s1","evidence":"picture","note":"a Pause button is visible"},{"id":"w2","text":"the Reset button clears the board","status":"met","shot":"s2","evidence":"picture","note":"a Reset button is visible"},{"id":"w3","text":"a bad name shows an error","status":"met","shot":"s3","evidence":"picture","note":"a name field is visible"},{"id":"w4","text":"the score goes up when you score","status":"met","shot":"s4","evidence":"picture","note":"a score readout is visible"}],"gaps":[],"alsoChecked":[],"escalations":[]}'
kscore "$KDIR/allwork" "$KDIR/allwork.json" "$KL_ALLWORK"
check "K6. four works-questions, all photos and no presses, is NOT high" \
  "[ \"\$(jget '$KDIR/allwork/verdict.json' 'd[\"score\"]')\" != high ]"

# ==========================================================================
echo "K'. THE PRODUCE-TIME STAMP IS CARRIED THROUGH AT BIRTH (xo-criteria.py)"
# The stamp is recorded WHEN THE CRITERION IS PRODUCED, not guessed later. The
# planner stamps `kind` on each acceptance criterion; xo-criteria.py carries it
# through verbatim, additive-key style — absent when unstamped, dropped when
# bogus — exactly as it carries `serves`/`drawnAt`.
# ==========================================================================
CRITPY="${LCARS_XO_CRITERIA_PY:-$REPO_ROOT/skills/lcars-xo/xo-criteria.py}"
CDIR="$TMPROOT/critkind"; mkdir -p "$CDIR"
cat >"$CDIR/plan.json" <<'PJ'
{"tickets": [
  {"id": "t-1", "acceptanceCriteria": [
    {"text": "the Save button saves the document", "kind": "works"},
    {"text": "the header shows the title", "kind": "looks"},
    {"text": "a criterion with a bogus kind", "kind": "sideways"},
    {"text": "a criterion with no kind at all"}
  ]}
]}
PJ
"$PY" "$CRITPY" "$CDIR" "$CDIR/criteria.json" >"$CDIR/out.txt" 2>&1
ckind() { # <criteria.json> <criterion id>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d["criteria"] if x["id"]==sys.argv[2]][0]
print(c.get("kind",""))' "$1" "$2" 2>/dev/null
}
check "K'.1 a works stamp is carried onto the criterion at birth" \
  "[ \"\$(ckind '$CDIR/criteria.json' t-1-ac1)\" = works ]"
check "K'.2 a looks stamp is carried onto the criterion at birth" \
  "[ \"\$(ckind '$CDIR/criteria.json' t-1-ac2)\" = looks ]"
check "K'.3 a bogus kind is dropped, not laundered through" \
  "[ -z \"\$(ckind '$CDIR/criteria.json' t-1-ac3)\" ]"
check "K'.4 an unstamped criterion carries no kind key (additive invariant)" \
  "[ -z \"\$(ckind '$CDIR/criteria.json' t-1-ac4)\" ]"


# ==========================================================================
echo
printf 'lcars xo-evidence: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
