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
# real tiny node:test and Python unittest suites exercise the gates' runner legs):
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
#   11–14. Missing-result retry guidance, a clean first Python prompt, a
#      stopped Python test refused, and a Node ticket that builds a real bundle.
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
PYTHON_CMD='python3 -m unittest discover -s "$LCARS_TESTS_DIR" -p "test_*.py"'

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
write_python_mul() {
  cat > tests/test_mul.py <<'PY'
import unittest
from calc import mul
from support import operands

class MultiplyTest(unittest.TestCase):
    def test_multiply(self):
        self.assertEqual(mul(*operands()), 6)
PY
  cat > tests/test_zero.py <<'PY'
import unittest
from calc import add, mul
from support import operands

class ZeroTest(unittest.TestCase):
    def test_add_zero(self):
        self.assertEqual(add(0, 0), 0)

    def test_zero(self):
        self.assertEqual(mul(operands()[0], 0), 0)
PY
  printf 'def add(a, b):\n    return a + b\n\ndef mul(a, b):\n    return a * b\n' > calc.py
}
case "$mode" in
  python-talk)
    write_python_mul
    echo "Implemented multiplication and its tests; describing completion without filing result.json."
    exit 0 ;;
  python-good)
    write_python_mul
    result '["tests/test_mul.py"]' \
      '[{"path": "tests/test_zero.py", "reason": "extend existing zero coverage with multiplication"}]' 1 ;;
  python-drop)
    write_python_mul
    cat > tests/test_zero.py <<'PY'
import unittest
from calc import add, mul
from support import operands

@unittest.skip("simulate a test file that stopped running")
class ZeroTest(unittest.TestCase):
    def test_add_zero(self):
        self.assertEqual(add(0, 0), 0)

    def test_zero(self):
        self.assertEqual(mul(operands()[0], 0), 0)
PY
    result '["tests/test_mul.py"]' \
      '[{"path": "tests/test_zero.py", "reason": "extend existing zero coverage with multiplication"}]' 1 ;;
  build-good)
    write_mul
    cat > src/calc.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { calculate } = require('../dist/calculator.cjs');
test('built calculator multiplies', () => { assert.strictEqual(calculate(2, 3), 6); });
JS
    result '["src/calc.test.js"]' '[]' 1 ;;
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
{
  "id": "m1",
  "type": "feature",
  "title": "t",
  "stage": "implement",
  "branch": "lcars/m1",
  "base": "$base"
}
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

new_python_repo() {
  local repo; repo="$(new_repo)"
  rm -f "$repo/package.json" "$repo/src/calc.js" "$repo/src/other.test.js"
  rmdir "$repo/src"
  mkdir -p "$repo/tests"
  printf 'def add(a, b):\n    return a + b\n' > "$repo/calc.py"
  cat > "$repo/tests/support.py" <<'PY'
def operands():
    return 2, 3
PY
  cat > "$repo/tests/test_add.py" <<'PY'
import unittest
from calc import add

class AddTest(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 2), 4)
PY
  cat > "$repo/tests/test_zero.py" <<'PY'
import unittest
from calc import add

class ZeroTest(unittest.TestCase):
    def test_add_zero(self):
        self.assertEqual(add(0, 0), 0)
PY
  ( cd "$repo" && git add -A && git commit -qm "Python fixture" && git branch -f lcars/m1 )
  echo "$repo"
}

new_node_build_repo() {
  local repo; repo="$(new_repo)"
  printf 'dist/\n' > "$repo/.gitignore"
  printf 'module.exports = { calculate: (a, b) => calc.mul(a, b) };\n' > "$repo/src/main.js"
  cat > "$repo/build.js" <<'JS'
const fs = require('node:fs');
const calc = fs.readFileSync('src/calc.js', 'utf8');
const main = fs.readFileSync('src/main.js', 'utf8');
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/calculator.cjs',
  `"use strict";\nconst calc = (() => {\nconst exports = {};\n${calc}\nreturn exports;\n})();\n${main}`);
JS
  ( cd "$repo" && git add -A && git commit -qm "Node bundle fixture" && git branch -f lcars/m1 )
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

# S173 — the ticket-green line stops quoting the worker's homework. ONE hire, so
# the captain is told nothing about a count; the worker's own iteration count
# (result.json.attempts = 2 for the `good` stub) rides event DATA only.
gline="$(grep '"type":"ticket_green"' "$ev" | tail -1)"
printf '%s' "$gline" | grep -q '"detail":"ticket t-001 green"' \
  && ok "1k. first-hire ticket_green detail is bare 'green' (no count at all)" \
  || bad "1k. ticket_green detail carries a count: $gline"
printf '%s' "$gline" | grep -qi 'attempt' \
  && bad "1l. the retired word 'attempt' is still in the ticket_green line: $gline" \
  || ok "1l. no 'attempt' anywhere in the ticket_green event"
printf '%s' "$gline" | grep -q '"sessions":1' \
  && ok "1m. data carries sessions=1 (the HIRE count, derived from events)" \
  || bad "1m. no sessions=1 in the ticket_green data: $gline"
printf '%s' "$gline" | grep -q '"iterations":2' \
  && ok "1n. data carries iterations=2 (the worker's own count, forensic)" \
  || bad "1n. no iterations=2 in the ticket_green data: $gline"
printf '%s' "$OUT" | grep -q 't-001 passed\. Saved result.json\.' \
  && ok "1o. the terminal echo is silent about counts on a first-hire green" \
  || bad "1o. terminal echo still quotes a count: $(printf '%s' "$OUT" | grep -i 'passed' | head -2)"

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

# S173 — two hires, so the count that GOVERNS is named, in the hire vocabulary.
gline2="$(grep '"type":"ticket_green"' "$(EV "$repo")" | tail -1)"
printf '%s' "$gline2" | grep -q '"detail":"ticket t-001 green after 2 worker sessions"' \
  && ok "2g. a 2-hire green reads 'green after 2 worker sessions'" \
  || bad "2g. wrong 2-hire green detail: $gline2"
printf '%s' "$gline2" | grep -q '"sessions":2' \
  && ok "2h. data carries sessions=2" || bad "2h. no sessions=2: $gline2"
printf '%s' "$gline2" | grep -q '"iterations":1' \
  && ok "2i. the fix-good worker's OWN count (1) rides iterations, not sessions" \
  || bad "2i. no iterations=1: $gline2"
printf '%s' "$gline2" | grep -qi 'attempt' \
  && bad "2j. 'attempt' survives in the 2-hire green line: $gline2" \
  || ok "2j. no 'attempt' in the 2-hire ticket_green event"

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
printf '%s' "$OUT" | grep -q 'lcars respond\|lcars-respond/respond.sh answer' \
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
# S173 — the hire count is derived from events.jsonl, so it SURVIVES a fresh
# process re-entering a half-built ticket. Session 1 runs under a 1-session cap
# and is bounced (parks); a SECOND, independent process then re-enters and goes
# green — its green must read "after 2 worker sessions", NOT restart at 1.
echo "== 8. the hire count survives a fresh process re-entering the ticket =="
repo="$(new_repo)"; sd1="$(new_stub_dir lazy)"
run_ticket "$repo" "$sd1" LCARS_WORKER_TRIES=1
[ "$(cat "$sd1/n")" = 1 ] && ok "8a. process 1 ran exactly ONE hire (cap 1) and parked" \
                          || bad "8a. process 1 hire count $(cat "$sd1/n") (wanted 1)"
[ "$(grep -c '"type":"ticket_attempt"' "$(EV "$repo")")" = 1 ] \
  && ok "8b. exactly one ticket_attempt on disk after process 1" \
  || bad "8b. ticket_attempt count $(grep -c '"type":"ticket_attempt"' "$(EV "$repo")")"
# clear the gate exactly as `lcars respond` does, then re-enter in a NEW process.
st8="$(MD "$repo")/state.json"
python3 - "$st8" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d.pop("awaitingHuman",None); d.pop("pendingQuestion",None)
json.dump(d,open(sys.argv[1],'w'),indent=2)
PY
rm -f "$(MD "$repo")/pending.json"
sd2="$(new_stub_dir good)"
run_ticket "$repo" "$sd2"
[ "$RC" -eq 0 ] && grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "8c. the re-entering process goes green" \
  || bad "8c. re-entry failed (rc=$RC: $(printf '%s' "$OUT" | tail -8))"
gline8="$(grep '"type":"ticket_green"' "$(EV "$repo")" | tail -1)"
printf '%s' "$gline8" | grep -q '"detail":"ticket t-001 green after 2 worker sessions"' \
  && ok "8d. the count did NOT restart at 1 across the process boundary" \
  || bad "8d. re-entry count restarted: $gline8"
printf '%s' "$gline8" | grep -q '"sessions":2' \
  && ok "8e. data sessions=2 after re-entry" || bad "8e. wrong sessions after re-entry: $gline8"

# ==========================================================================
# S173 — ticket_flagged is emitted from TWO paths carrying TWO quantities. A
# consumer reading DATA ALONE must be able to tell them apart.
echo "== 9. ticket_flagged from both paths is distinguishable by data alone =="
# Path A: the worker itself reports not-green (impl-save-result, direct entry).
repoA="$(new_repo)"
cat > "$TMPROOT/notgreen.json" <<'JSON'
{ "ticketId": "t-001", "passed": false, "attempts": 6, "summary": "could not get it green",
  "newTests": [], "testEdits": [], "flipFlop": "not-applicable",
  "flipFlopReason": "nothing new was proven" }
JSON
OUTA="$( cd "$repoA" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
         bash "$SCRIPT" impl-save-result --mission m1 --ticket t-001 \
         --result "$TMPROOT/notgreen.json" 2>&1 )"
flagA="$(grep '"type":"ticket_flagged"' "$(EV "$repoA")" | tail -1)"
printf '%s' "$flagA" | grep -q '"iterations":6' \
  && ok "9a. worker-self-report flag carries iterations=6" \
  || bad "9a. no iterations=6 on the self-report flag: $flagA"
printf '%s' "$flagA" | grep -q '"sessions":' \
  && bad "9b. the self-report flag also claims a hire count: $flagA" \
  || ok "9b. the self-report flag carries NO sessions key (unambiguous)"
# Path B: the proof gates exhausted the hire cap.
repoB="$(new_repo)"; sdB="$(new_stub_dir lazy lazy lazy)"
run_ticket "$repoB" "$sdB"
flagB="$(grep '"type":"ticket_flagged"' "$(EV "$repoB")" | tail -1)"
printf '%s' "$flagB" | grep -q '"sessions":3' \
  && ok "9c. cap-exhaustion flag carries sessions=3 (hires)" \
  || bad "9c. no sessions=3 on the exhaustion flag: $flagB"
printf '%s' "$flagB" | grep -q '"iterations":' \
  && bad "9d. the exhaustion flag also claims an iteration count: $flagB" \
  || ok "9d. the exhaustion flag carries NO iterations key (unambiguous)"
printf '%s%s' "$flagA" "$flagB" | grep -q '"attempts":' \
  && bad "9e. the colliding 'attempts' data key survives on a ticket_flagged" \
  || ok "9e. neither flag path still emits the colliding 'attempts' key"

# ==========================================================================
# 10. S173 FIX ROUND — the retired word is gone from the CAPTAIN-FACING strings
# that name the HIRE CAP, and there is ONE derivation rule for the hire count.
# Source-level, so it is cheap and cannot be faked by a stub.
# ==========================================================================
echo "== 10. no captain-facing string names the hire cap an 'attempt' =="

grep -n 'never turned green within the attempt cap' "$SCRIPT" >/dev/null \
  && bad "10a. classify_impl_failure still calls the HIRE cap an 'attempt cap'" \
  || ok "10a. genuine-red-exhausted names the hire cap correctly"
grep -q 'never turned green within the hire cap' "$SCRIPT" \
  && ok "10a. …and says 'hire cap' explicitly" \
  || bad "10a. the genuine-red-exhausted wording is missing"

grep -n 'The ticket FAILS this attempt' "$SCRIPT" >/dev/null \
  && bad "10b. the POST-COMMIT GATE detail still says 'FAILS this attempt'" \
  || ok "10b. the POST-COMMIT GATE detail names the worker session"
grep -q 'The ticket FAILS this worker session' "$SCRIPT" \
  && ok "10b. …in the round's vocabulary" \
  || bad "10b. the POST-COMMIT GATE replacement wording is missing"

grep -n 'no valid estimate.json after %s attempt' "$SCRIPT" >/dev/null \
  && bad "10c. the estimator still counts MAX_WORKER_TRIES in 'attempt(s)'" \
  || ok "10c. the estimator's bounded retry names worker sessions"
grep -q 'no valid estimate.json after %s worker session' "$SCRIPT" \
  && ok "10c. …and each try IS a spawn_worker dispatch, so that is the honest word" \
  || bad "10c. the estimator replacement wording is missing"

# The DERIVATION RULE itself is proven behaviourally at each of its four
# surfaces rather than by poking the function: run.sh through the Verify
# roll-up (verify-summary-contract §7/§8 — a pre-S133 two-phase ticket counts
# TWO hires, and a stream with no dispatch on file stays silent rather than
# being floored to 1) and through §8 above (a re-entered process keeps
# counting), comment-mirror through lcars-comment T15, lcars-status through
# W15, and board.js through web/tests/test_activity_sections.HireDerivationTest.

# ==========================================================================
# S327: observe the actual NEXT dispatch, not whether a lucky retry goes green.
echo "== 11. a talkative Python worker that omits result gets the file-first warning =="
repo="$(new_python_repo)"; sd="$(new_stub_dir python-talk python-good)"
run_ticket "$repo" "$sd" LCARS_TEST_CMD="$PYTHON_CMD"
if [ -f "$sd/prompt-2.txt" ] \
   && grep -q '^## YOUR PREVIOUS ATTEMPT FAILED' "$sd/prompt-2.txt" \
   && grep -q 'MUST be to call your file-creation tool' "$sd/prompt-2.txt"; then
  ok "11a. missing-result retry receives the existing file-first escalation"
else
  bad "11a. missing-result retry did NOT receive the existing file-first escalation"
fi
if [ -f "$sd/prompt-2.txt" ] \
   && grep -q '^## GATE FEEDBACK' "$sd/prompt-2.txt" \
   && grep -q 'result.*missing' "$sd/prompt-2.txt"; then
  ok "11b. retry also carries the real result-missing gate verdict"
else
  bad "11b. retry lacks the result-missing gate verdict"
fi
[ "$(cat "$sd/n")" = 2 ] \
  && ok "11c. talking without filing consumes one proof session, not an empty-worker retry" \
  || bad "11c. expected two worker sessions, got $(cat "$sd/n")"
grep -q '"type":"ticket_worker_empty_output"' "$(EV "$repo")" \
  && bad "11d. talkative worker misclassified as empty" \
  || ok "11d. talkative worker is not classified as empty"
[ "$RC" -eq 0 ] && grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "11e. Python multi-file retry passes the real proof and commit gates" \
  || bad "11e. Python retry did not pass (rc=$RC: $OUT)"

echo "== 12. first-time Python success receives a clean prompt =="
repo="$(new_python_repo)"; sd="$(new_stub_dir python-good)"
run_ticket "$repo" "$sd" LCARS_TEST_CMD="$PYTHON_CMD"
if [ -f "$sd/prompt-1.txt" ] \
   && ! grep -q '^## YOUR PREVIOUS ATTEMPT FAILED\|^## YOUR PREVIOUS ATTEMPT WAS REJECTED\|^## GATE FEEDBACK' "$sd/prompt-1.txt"; then
  ok "12a. first dispatch has no failure-only warning or gate feedback"
else
  bad "12a. first dispatch is missing or contains stale failure guidance"
fi
[ "$RC" -eq 0 ] && [ "$(cat "$sd/n")" = 1 ] \
  && grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "12b. Python flat tests plus test-free shared helper pass on the first hire" \
  || bad "12b. Python happy path failed (rc=$RC: $OUT)"
if tr '\n' ' ' < "$sd/prompt-1.txt" \
   | grep -q 'NEVER revert, stash, check out or back up files to test the parent yourself'; then
  ok "12c. worker prompt forbids destructive parent testing"
else
  bad "12c. worker prompt does not forbid destructive parent testing"
fi
if tr '\n' ' ' < "$sd/prompt-1.txt" \
   | grep -q 'Run only the tests you declared, NEVER the whole suite'; then
  ok "12d. worker prompt limits test runs to declared tests"
else
  bad "12d. worker prompt does not limit test runs to declared tests"
fi
if python3 - "$(TD "$repo")/flip-flop.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["verdict"] == "pass" and d["gate"]["scopeKind"] == "files", d
assert d["tip"]["rc"] == 0 and d["parent"]["rc"] != 0, d
assert d["executed"]["runner"] == "unittest" and d["executed"]["tip"] == "3", d
assert d["declaredRan"]["unaccounted"] == [], d
PY
then
  ok "12e. real Python proof ran all three declared tests with per-file scope"
else
  bad "12e. Python proof did not establish the expected scoped red/green"
fi
if [ -f "$sd/prompt-1.txt" ] \
   && ! grep -qi 'Run the suite freely' "$sd/prompt-1.txt"; then
  ok "12f. worker prompt does not contradict declared-test scope with free suite runs"
else
  bad "12f. worker prompt is missing or invites running the suite freely"
fi

echo "== 13. a stopped Python test file is still refused =="
repo="$(new_python_repo)"; sd="$(new_stub_dir python-drop)"
before="$( cd "$repo" && python3 -m unittest discover -s tests -p test_zero.py 2>&1 )"
if [ "$?" -eq 0 ] && printf '%s' "$before" | grep -q '^Ran 1 test in ' \
   && ! printf '%s' "$before" | grep -q 'skipped'; then
  ok "13a. existing zero test really executes and passes before the worker changes it"
else
  bad "13a. stopped-file control did not run green before the change: $before"
fi
run_ticket "$repo" "$sd" LCARS_TEST_CMD="$PYTHON_CMD" LCARS_WORKER_TRIES=1
if python3 - "$(TD "$repo")/flip-flop.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["verdict"] == "inconclusive", d
assert "tests/test_zero.py" in d["declaredRan"]["unaccounted"], d
assert d["executed"]["tip"] == "1", d
PY
then
  ok "13b. real unittest count catches the declared file whose tests stopped executing"
else
  bad "13b. stopped Python file was not identified by the real proof gate"
fi
[ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$(MD "$repo")/state.json" \
  && ! grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "13c. stopped-test ticket parks instead of recording green" \
  || bad "13c. stopped-test ticket did not park honestly (rc=$RC: $OUT)"

echo "== 14. Node builds and exercises a real calculator bundle =="
repo="$(new_node_build_repo)"; sd="$(new_stub_dir build-good)"
run_ticket "$repo" "$sd" LCARS_TEST_CMD="node build.js && $NODE_CMD"
[ "$RC" -eq 0 ] && [ "$(cat "$sd/n")" = 1 ] \
  && grep -q '"type":"ticket_green"' "$(EV "$repo")" \
  && ok "14a. building Node ticket passes proof and commit gates" \
  || bad "14a. Node build path failed (rc=$RC: $OUT)"
if ( cd "$repo" && node -e \
  'require("node:assert/strict").equal(require("./dist/calculator.cjs").calculate(2, 3), 6)' ); then
  ok "14b. generated bundle exists and computes the ticket's multiplication"
else
  bad "14b. generated Node bundle is missing or incorrect"
fi
if python3 - "$(TD "$repo")/flip-flop.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["verdict"] == "pass", d
assert d["tip"]["rc"] == 0 and d["parent"]["rc"] != 0, d
assert "node build.js" in d["tip"]["cmd"] and "node build.js" in d["parent"]["cmd"], d
PY
then
  ok "14c. real build command ran on both tip and scratch parent"
else
  bad "14c. Node flip-flop did not rebuild both sides"
fi

echo
printf 'unified-implementer: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
