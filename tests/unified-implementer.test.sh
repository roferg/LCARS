#!/usr/bin/env bash
# Fast, SCOPED test for the S133 PATH FLIP — the unified TDD worker.
#
# cmd_implement_ticket now drives ONE cold worker per ticket (role implement-tdd,
# repo-write toolset) that writes tests AND code in-tree, then proves the work
# post-hoc with the S132 gates (result v2 → declared-edits → quality floor →
# flip-flop vs the parent commit) before the unchanged commit_ticket +
# post-commit + full-suite flow. A gate rejection writes tickets/<id>/
# gate-signal.txt and re-spawns a FRESH worker carrying the verdict (cap
# LCARS_WORKER_TRIES sessions); exhaustion PARKS awaiting-human — the old
# `ticket_test_writer_failed → die` class no longer exists. The Test Writer, the
# red-gate choreography, tests.sha256 and reconcile-tests are DELETED.
#
# Behaviors driven here (stubbed worker via $LCARS_WORKER_BIN — ZERO tokens; a
# real tiny node:test suite exercises the gates' runner legs):
#   1. Happy path (whole `implement` driver): ONE worker spawn (implement-tdd,
#      never implement-test-writer), gates pass, ONE commit carries test+code,
#      full-suite runs, stage → verify; events carry phase=tdd + gate events.
#   2. Cheating stub (undeclared edit of a committed test): declared-edits FAILS
#      → gate-signal.txt → SECOND spawn carries the signal → compliant stub →
#      green. Two sessions total.
#   3. Persistent-fail stub: 3 sessions then awaiting-human (pending.json, label
#      relabel, ticket_flagged) — process exits 0 (alive), NEVER dies; a
#      recorded answer + re-run resumes and consumes answers.json.
#   4. Logged-bug mission editing a contradictory parent test WITH declaration:
#      flows clean, NO reconcile_tests anywhere, edit recorded in
#      test-edits.json. `reconcile-tests` is no longer a subcommand.
#   5. Runner-dead package: the preflight parks exactly as today, spawning NO
#      worker (env truth untouched).
#   6. Serial re-run on the updated tip (the wave-conflict rebuild shape): the
#      worker RE-RUNS (no stale-contract reuse — LCARS_REUSE_TESTS is inert) and
#      the gates re-prove on the new parent.
#   7. LCARS_SELFHEAL_FEEDBACK rides the unified worker's prompt unchanged.
#
# NOT the heavy lcars-run.test.sh. Safe to run directly.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Dir-aware: a multi-file scope hands the runner the COMMON-ANCESTOR DIR, and
# node v25 treats a bare dir arg as a module entry — glob it like a real runner.
NODE_CMD='if [ -d "$LCARS_TESTS_DIR" ]; then node --test "$LCARS_TESTS_DIR"/*.test.js; else node --test "$LCARS_TESTS_DIR"; fi'

# --- the scripted stub worker ------------------------------------------------
# One behavior keyword per line in $STUB_DIR/script; call N executes line N
# (last line repeats). Records every prompt / role / argv. Writes into its CWD
# (the ticket worktree or the repo) and result.json into $LCARS_WORK_OUT.
STUB="$TMPROOT/stub-worker.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
sd="${STUB_DIR:?}"
n="$(cat "$sd/n" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$sd/n"
prompt="${2:-}"
printf '%s' "$prompt" > "$sd/prompt-$n.txt"
printf '%s\n' "${LCARS_WORKER_ROLE:-}" >> "$sd/roles"
printf '%s\n' "$*" >> "$sd/argv"
mode="$(sed -n "${n}p" "$sd/script")"
[ -n "$mode" ] || mode="$(tail -1 "$sd/script")"
out="${LCARS_WORK_OUT:?}"
result() { # newTests-json testEdits-json attempts
  cat > "$out/result.json" <<JSON
{ "ticketId": "t-001", "passed": true, "attempts": ${3:-2}, "summary": "stub $mode",
  "newTests": $1, "testEdits": $2, "flipFlop": "expected" }
JSON
}
write_mul() { # the honest work: failing-first test + the impl it needs
  cat > src/calc.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { mul } = require('./calc.js');
test('mul multiplies', () => { assert.strictEqual(mul(2, 3), 6); });
JS
  printf 'exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\n' > src/calc.js
}
case "$mode" in
  good)
    write_mul
    result '["src/calc.test.js"]' '[]' 2 ;;
  good2)
    cat > src/sq.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { sq } = require('./calc.js');
test('sq squares', () => { assert.strictEqual(sq(3), 9); });
JS
    printf '%s\n' 'exports.sq = (a) => a * a;' >> src/calc.js
    result '["src/sq.test.js"]' '[]' 1 ;;
  cheat)
    write_mul
    printf '// sneaky undeclared edit\n' >> src/other.test.js
    result '["src/calc.test.js"]' '[]' 3 ;;
  fix-good)
    git checkout -- src/other.test.js 2>/dev/null || true
    write_mul
    result '["src/calc.test.js"]' '[]' 1 ;;
  declare-edit)
    write_mul
    cat > src/other.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('./calc.js');
test('add adds (ticket changed the expectation)', () => { assert.strictEqual(add(2, 2), 4); });
JS
    result '["src/calc.test.js"]' '[{ "path": "src/other.test.js", "reason": "the bug contradicts the parent assertion" }]' 2 ;;
  lazy)
    printf 'exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\n' > src/calc.js
    result '[]' '[]' 7 ;;
  nothing)
    exit 0 ;;
esac
echo "stub ran: $mode"
exit 0
STUB_EOF
chmod +x "$STUB"

new_stub_dir() { # script-lines... → echoes STUB_DIR
  local sd; sd="$(mktemp -d "$TMPROOT/stub.XXXX")"
  : > "$sd/roles"; : > "$sd/argv"; printf '%s\n' "$@" > "$sd/script"
  echo "$sd"
}

# --- the fixture repo: committed src + a committed PASSING test + a branch ----
new_repo() { # → echoes repo dir; mission m1 parked at implement, branch exists
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  # CONTEXT.md pre-seeds the durable context source so NO context-pack worker
  # spawns (the stub's call numbering stays 1:1 with TDD sessions).
  printf '# ctx\n' > "$repo/CONTEXT.md"
  printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/src"
  printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
  cat > "$repo/src/other.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('./calc.js');
test('add adds', () => { assert.strictEqual(add(2, 2), 4); });
JS
  ( cd "$repo" && git add -A && git commit -qm base && git branch lcars/m1 )
  local base; base="$( cd "$repo" && git rev-parse --abbrev-ref HEAD )"
  mkdir -p "$repo/.git/lcars/missions/m1/tickets/t-001"
  cat > "$repo/.git/lcars/missions/m1/state.json" <<JSON
{ "id": "m1", "type": "feature", "title": "t", "stage": "implement",
  "branch": "lcars/m1", "base": "$base" }
JSON
  cat > "$repo/.git/lcars/missions/m1/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "add mul", "description": "add a mul export",
                 "acceptanceCriteria": ["mul(2,3) === 6"], "rationale": "r" } ] }
JSON
  cat > "$repo/.git/lcars/missions/m1/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001", "issue": null }
      ]
    }
  ]
}
JSON
  echo "$repo"
}

MD() { echo "$1/.git/lcars/missions/m1"; }
EV() { echo "$1/.git/lcars/missions/m1/events.jsonl"; }
TD() { echo "$1/.git/lcars/missions/m1/tickets/t-001"; }

run_ticket() { # repo stub-dir [extra env pairs...] → RC + OUT
  local repo="$1" sd="$2"; shift 2
  OUT="$( cd "$repo" && env STUB_DIR="$sd" LCARS_TEST_CMD="$NODE_CMD" \
          LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          LCARS_WORKER_BIN="$STUB" LCARS_WORKER_CLI=claude "$@" \
          bash "$SCRIPT" implement-ticket --mission m1 --ticket t-001 2>&1 )"
  RC=$?
}

# ==========================================================================
echo "== 1. happy path — the whole implement driver =="
repo="$(new_repo)"; sd="$(new_stub_dir good)"
OUT="$( cd "$repo" && env STUB_DIR="$sd" LCARS_TEST_CMD="$NODE_CMD" \
        LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        LCARS_WORKER_BIN="$STUB" LCARS_WORKER_CLI=claude \
        bash "$SCRIPT" implement --mission m1 2>&1 )"
RC=$?
[ "$RC" -eq 0 ] && ok "1a. implement driver exits 0" \
                || bad "1a. implement driver failed (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
if [ "$(grep -c . "$sd/roles")" = 1 ] && grep -qx 'implement-tdd' "$sd/roles"; then
  ok "1b. exactly ONE worker spawn, role implement-tdd"
else
  bad "1b. spawn roles wrong: $(tr '\n' ' ' < "$sd/roles")"
fi
grep -q 'implement-test-writer\|implement-implementer' "$sd/argv" "$sd/roles" 2>/dev/null \
  && bad "1c. standoff role leaked into a spawn" \
  || ok "1c. no test-writer / old-implementer role anywhere in the spawns"
tip_files="$( cd "$repo" && git show --name-only --format= lcars/m1 2>/dev/null )"
if printf '%s\n' "$tip_files" | grep -q 'src/calc.test.js' \
   && printf '%s\n' "$tip_files" | grep -q 'src/calc.js'; then
  ok "1d. ONE commit on the branch carries the test AND the code"
else
  bad "1d. branch tip commit wrong ($tip_files)"
fi
grep -q '"stage": "verify"' "$(MD "$repo")/state.json" \
  && ok "1e. stage advanced to verify (full-suite gate passed)" \
  || bad "1e. stage did not reach verify ($(grep stage "$(MD "$repo")/state.json"))"
ev="$(EV "$repo")"
grep -q '"type":"ticket_attempt"' "$ev" && grep -q '"phase":"tdd"' "$ev" \
  && ok "1f. ticket_attempt event carries phase=tdd" \
  || bad "1f. ticket_attempt phase=tdd missing"
grep -q '"type":"flip_flop_pass"' "$ev" \
  && ok "1g. flip_flop_pass gate event in events.jsonl" \
  || bad "1g. flip_flop_pass event missing"
grep -q '"type":"ticket_test_edits"' "$ev" \
  && ok "1h. ticket_test_edits gate event in events.jsonl" \
  || bad "1h. ticket_test_edits event missing"
grep -q '"type":"ticket_green"' "$ev" \
  && ok "1i. ticket_green emitted" || bad "1i. ticket_green missing"
[ -f "$(TD "$repo")/proof-tests.sha256" ] \
  && ok "1j. proof-tests.sha256 recorded at gate-pass time" \
  || bad "1j. proof-tests.sha256 missing"

# ==========================================================================
echo "== 2. cheating stub bounces once, compliant retry goes green =="
repo="$(new_repo)"; sd="$(new_stub_dir cheat fix-good)"
run_ticket "$repo" "$sd"
[ "$RC" -eq 0 ] && ok "2a. second session ends green (rc 0)" \
                || bad "2a. expected green after one bounce (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
[ "$(cat "$sd/n")" = 2 ] && ok "2b. exactly TWO worker sessions ran" \
                         || bad "2b. session count $(cat "$sd/n") (wanted 2)"
if grep -q 'GATE FEEDBACK' "$sd/prompt-2.txt" \
   && grep -q 'declared-edits' "$sd/prompt-2.txt" \
   && grep -q 'src/other.test.js' "$sd/prompt-2.txt"; then
  ok "2c. the SECOND prompt carries the gate signal naming the undeclared file"
else
  bad "2c. second prompt lacks the gate-signal block"
fi
grep -q '"type":"ticket_gate_bounce"' "$(EV "$repo")" \
  && ok "2d. ticket_gate_bounce event emitted" \
  || bad "2d. ticket_gate_bounce event missing"
grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "2e. ticket green after the compliant session" \
  || bad "2e. no ticket_green after retry"
[ ! -f "$(TD "$repo")/gate-signal.txt" ] \
  && ok "2f. gate-signal.txt cleared on the green path" \
  || bad "2f. stale gate-signal.txt left after green"

# ==========================================================================
echo "== 3. persistent-fail stub → 3 sessions → PARK (never die) → resume =="
repo="$(new_repo)"; sd="$(new_stub_dir lazy lazy lazy good)"
run_ticket "$repo" "$sd"
[ "$RC" -eq 0 ] && ok "3a. exhaustion exits 0 (parked, process alive — no die)" \
                || bad "3a. exhaustion should exit 0 (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
[ "$(cat "$sd/n")" = 3 ] && ok "3b. exactly THREE sessions before the park" \
                         || bad "3b. session count $(cat "$sd/n") (wanted 3)"
st="$(MD "$repo")/state.json"
grep -q '"awaitingHuman": *true' "$st" \
  && ok "3c. awaitingHuman set" || bad "3c. awaitingHuman not set"
[ -f "$(MD "$repo")/pending.json" ] && grep -q 'quality-floor\|GATE' "$(MD "$repo")/pending.json" \
  && ok "3d. pending.json quotes the last gate verdict" \
  || bad "3d. pending.json missing or lacks the verdict"
grep -q '"type":"ticket_flagged"' "$(EV "$repo")" \
  && ok "3e. ticket_flagged event emitted" || bad "3e. ticket_flagged missing"
printf '%s' "$OUT" | grep -q 'lcars respond' \
  && ok "3f. park copy points at lcars respond" || bad "3f. no respond pointer"
# --- resume: record the captain's answer, clear the gate, re-run ------------
cat > "$(MD "$repo")/answers.json" <<'JSON'
{ "answers": [ { "question": "t-001 blocked", "answer": "write the mul test, then implement it" } ] }
JSON
python3 - "$st" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d.pop("awaitingHuman",None); d.pop("pendingQuestion",None)
json.dump(d,open(sys.argv[1],'w'),indent=2)
PY
rm -f "$(MD "$repo")/pending.json"
run_ticket "$repo" "$sd"
[ "$RC" -eq 0 ] && grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "3g. respond → re-run resumes and goes green" \
  || bad "3g. resume failed (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
grep -q 'answers.json' "$sd/prompt-4.txt" \
  && ok "3h. the resumed session's prompt carries answers.json" \
  || bad "3h. answers.json not fed to the resumed worker"
grep -q 'GATE FEEDBACK' "$sd/prompt-4.txt" \
  && ok "3i. the resumed session still sees the last gate verdict" \
  || bad "3i. last gate verdict missing from the resumed prompt"

# ==========================================================================
echo "== 4. logged bug edits a contradictory parent test WITH declaration =="
repo="$(new_repo)"; sd="$(new_stub_dir declare-edit)"
# make m1 a logged bug with a parent mission on file
python3 - "$(MD "$repo")/state.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d["type"]="bug"; d["parentMission"]="p1"; d["origin"]="log"
json.dump(d,open(sys.argv[1],'w'),indent=2)
PY
mkdir -p "$repo/.git/lcars/missions/p1/tickets/t-900/tests"
OUT="$( cd "$repo" && env STUB_DIR="$sd" LCARS_TEST_CMD="$NODE_CMD" \
        LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        LCARS_WORKER_BIN="$STUB" LCARS_WORKER_CLI=claude \
        bash "$SCRIPT" implement --mission m1 2>&1 )"
RC=$?
[ "$RC" -eq 0 ] && grep -q '"stage": "verify"' "$(MD "$repo")/state.json" \
  && ok "4a. logged bug flows clean to verify" \
  || bad "4a. logged bug failed (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
grep -q 'tests_reconcile\|reconcile-tests' "$(EV "$repo")" \
  && bad "4b. reconcile_tests machinery ran (should not exist)" \
  || ok "4b. NO reconcile_tests events anywhere"
grep -q 'reconcile-tests' "$sd/roles" "$sd/argv" 2>/dev/null \
  && bad "4c. a reconcile-tests worker was spawned" \
  || ok "4c. no reconcile-tests worker spawn"
tej="$(TD "$repo")/test-edits.json"
[ -f "$tej" ] && grep -q 'src/other.test.js' "$tej" \
  && ok "4d. the declared parent-test edit is recorded in test-edits.json" \
  || bad "4d. test-edits.json missing the declared edit"
OUT2="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
         bash "$SCRIPT" reconcile-tests --mission m1 2>&1 )"; RC2=$?
[ "$RC2" -ne 0 ] && printf '%s' "$OUT2" | grep -q 'unknown subcommand' \
  && ok "4e. reconcile-tests is no longer a subcommand" \
  || bad "4e. reconcile-tests still dispatches (rc=$RC2)"

# ==========================================================================
echo "== 5. runner-dead package parks at preflight, spawning NOTHING =="
repo="$(new_repo)"; sd="$(new_stub_dir good)"
cat > "$repo/dead.sh" <<'SH'
#!/usr/bin/env bash
echo "sh: vitest: command not found"
exit 127
SH
run_ticket "$repo" "$sd" LCARS_TEST_CMD="bash $repo/dead.sh"
grep -q '"awaitingHuman": *true' "$(MD "$repo")/state.json" \
  && ok "5a. dead runner parks awaiting-human (env truth untouched)" \
  || bad "5a. dead-runner park broken (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
[ "$(cat "$sd/n" 2>/dev/null || echo 0)" = 0 ] \
  && ok "5b. NO worker spawned before the park" \
  || bad "5b. a worker spawned despite the dead runner"

# ==========================================================================
echo "== 6. serial re-run on the updated tip — no stale-contract reuse =="
repo="$(new_repo)"; sd="$(new_stub_dir good good2)"
run_ticket "$repo" "$sd"
[ "$RC" -eq 0 ] || bad "6-pre. first build failed (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
first_tip="$( cd "$repo" && git rev-parse lcars/m1 )"
# the wave-conflict rebuild re-invokes implement-ticket on the SAME ticket with
# the (now inert) LCARS_REUSE_TESTS=1 the old path used to short-circuit on.
rm -f "$(TD "$repo")/.build-rc" "$(TD "$repo")/.commit-sha"
run_ticket "$repo" "$sd" LCARS_REUSE_TESTS=1
[ "$RC" -eq 0 ] && ok "6a. re-run on the updated tip goes green" \
                || bad "6a. re-run failed (rc=$RC: $(printf '%s' "$OUT" | tail -5))"
[ "$(cat "$sd/n")" = 2 ] \
  && ok "6b. the worker RE-RAN (LCARS_REUSE_TESTS no longer skips the spawn)" \
  || bad "6b. spawn count $(cat "$sd/n") (wanted 2 — stale-contract reuse?)"
[ "$(grep -c '"type":"flip_flop_pass"' "$(EV "$repo")")" -ge 2 ] \
  && ok "6c. the gates RE-PROVED on the new tip (second flip_flop_pass)" \
  || bad "6c. no second flip_flop_pass"
second_tip="$( cd "$repo" && git rev-parse lcars/m1 )"
[ "$second_tip" != "$first_tip" ] \
  && ok "6d. one NEW commit landed from the re-run" \
  || bad "6d. branch tip unchanged after the re-run"

# ==========================================================================
echo "== 7. LCARS_SELFHEAL_FEEDBACK rides the unified worker's prompt =="
repo="$(new_repo)"; sd="$(new_stub_dir good)"
run_ticket "$repo" "$sd" LCARS_SELFHEAL_FEEDBACK="suite t-000 regressed: expected 4 got 5. Command run: node --test"
[ "$RC" -eq 0 ] || bad "7-pre. selfheal-feedback run failed (rc=$RC)"
if grep -q 'FULL-SUITE RECONCILE FEEDBACK' "$sd/prompt-1.txt" \
   && grep -q 'suite t-000 regressed' "$sd/prompt-1.txt"; then
  ok "7a. the reconcile feedback block + verdict ride the prompt"
else
  bad "7a. selfheal feedback missing from the prompt"
fi

# ==========================================================================
echo
printf 'unified-implementer: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
