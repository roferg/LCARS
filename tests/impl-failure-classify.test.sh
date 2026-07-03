#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S96 actionable failure classification.
#
# S96 turns the generic "the Test Writer produced no usable tests" into ONE named
# root-cause category, and refactors the three red-gate detectors into a shared
# DATA TABLE (rg_signature) WITHOUT changing their JS/Python verdicts.
#
# This drives the REAL functions through inert `run.sh` test-hook subcommands:
#   • classify-impl-failure-test   → classify_impl_failure (runner on stdin;
#                                     worker/files via env)
#   • red-gate-env-detect-test     → red_gate_env_failure        (regression)
#   • red-gate-compile-detect-test → red_gate_compile_failure    (regression)
#   • red-gate-resolution-detect-test → red_gate_resolution_failure (regression)
#
# OFFLINE + FREE: no workers, no network, no runner — pure string classification.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# classify runner_out [files_written] [worker_out] -> echoes the category
classify() {
  local runner="$1" files="${2:-}" worker="${3:-}"
  printf '%s' "$runner" | ( cd "$REPO_ROOT" \
    && LCARS_CLASSIFY_FILES="$files" LCARS_CLASSIFY_WORKER_OUT="$worker" \
       bash "$SCRIPT" classify-impl-failure-test )
}
expect_cat() { # label  expected  actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# detector hooks return rc 0 = matched, 1 = not
env_detect()     { printf '%s' "$1" | ( cd "$REPO_ROOT" && bash "$SCRIPT" red-gate-env-detect-test ); }
compile_detect() { printf '%s' "$1" | ( cd "$REPO_ROOT" && bash "$SCRIPT" red-gate-compile-detect-test ); }
reso_detect()    { printf '%s' "$1" | ( cd "$REPO_ROOT" && bash "$SCRIPT" red-gate-resolution-detect-test ); }

echo "S96 classify_impl_failure — categories + precedence"

# 1. resolution failure for a ticket-CREATED path (a stub was written) → missing-new-module
RUNNER_MISSING='Error: Failed to resolve import "../src/state/themeStore" from "themeStore.test.ts". Does the file exist?'
expect_cat "1. resolution failure for a ticket-created path → missing-new-module" \
  "missing-new-module" \
  "$(classify "$RUNNER_MISSING" "$(printf 'tests/themeStore.test.ts\nstubs/src/state/themeStore.ts\n')")"

# 2. resolution failure for a NON-created / typo'd path (no matching stub) → bad-import-path
RUNNER_TYPO='Error: Failed to resolve import "../src/uitls" from "utils.test.ts". Does the file exist?'
expect_cat "2. resolution failure for a typo/non-created path → bad-import-path" \
  "bad-import-path" \
  "$(classify "$RUNNER_TYPO" "$(printf 'tests/utils.test.ts\n')")"

# 3. a test file WAS written but no coherent red across attempts (green-on-nothing) → over-broad-slice
RUNNER_GREEN='rc=0 (the quarantined-tests run exited 0 = GREEN, which the red gate rejects)
RED GATE — the quarantined suite PASSED with no implementation (exit 0). A contract that is green before anything is built proves nothing; the tests must FAIL first.'
expect_cat "3. test written but no coherent red → over-broad-slice" \
  "over-broad-slice" \
  "$(classify "$RUNNER_GREEN" "$(printf 'tests/theme.test.ts\n')")"

# 4. empty stdout/err + NO files written → empty-worker-output
expect_cat "4. empty output + no files → empty-worker-output" \
  "empty-worker-output" \
  "$(classify "" "" "")"

# 4a. NOISY-FILELESS: worker PRINTED output but wrote NO test file and the runner
#     produced nothing → over-broad-slice, NOT empty-worker-output (S98: empty ≠ bad).
#     The worker produced output, so calling it "no file AND no output" is factually
#     wrong; some signal is present (worker noise) so it is a bad/over-broad attempt.
expect_cat "4a. worker printed output but wrote no file → over-broad-slice (not empty)" \
  "over-broad-slice" \
  "$(classify "" "" "I read the ticket and thought about a suite but wrote nothing")"

# 4b. runner emitted some unmatched non-assertion output + no files + no worker → over-broad-slice
#     (signal present, so NOT the truly-empty #1 case).
expect_cat "4b. runner noise, no files, no worker → over-broad-slice (not empty)" \
  "over-broad-slice" \
  "$(classify "$(printf 'some runner chatter that matches no red-gate signature\n')" "" "")"

# 5a. env / runner-startup signatures → env-failure
expect_cat "5a. 'vitest: not found' → env-failure" \
  "env-failure" \
  "$(classify "$(printf 'sh: vitest: command not found\n')" "$(printf 'tests/x.test.ts\n')")"
expect_cat "5b. 'cd: <dir>: No such file or directory' (node_modules) → env-failure" \
  "env-failure" \
  "$(classify "$(printf 'node_modules missing — run install first\n')" "$(printf 'tests/x.test.ts\n')")"

# 5c. a normal assertion exhaustion (genuine red) → genuine-red-exhausted
RUNNER_ASSERT='FAIL  src/theme.test.ts > applies dark by default
AssertionError: expected 3 to be 4
Tests: 1 failed, 2 passed'
expect_cat "5c. normal assertion exhaustion → genuine-red-exhausted" \
  "genuine-red-exhausted" \
  "$(classify "$RUNNER_ASSERT" "$(printf 'tests/theme.test.ts\n')")"

# Precedence: env beats resolution (an unprovisioned runner is NOT a code fault)
RUNNER_ENV_AND_RESO='sh: vitest: command not found
Cannot find module ../src/foo'
expect_cat "precedence: env before resolution" \
  "env-failure" \
  "$(classify "$RUNNER_ENV_AND_RESO" "$(printf 'tests/x.test.ts\nstubs/src/foo.ts\n')")"

echo
echo "S96 regression — the three detectors classify IDENTICALLY to today (byte-equivalent)"

# 6. env detector — real signatures still match; assertion diffs still DON'T (S83 fixtures)
env_detect 'sh: vitest: command not found' && ok "6. env: 'command not found' matches" \
  || bad "6. env: 'command not found' matches"
env_detect 'env: node: No such file or directory' && ok "6. env: missing interpreter matches" \
  || bad "6. env: missing interpreter matches"
env_detect 'node_modules missing — run install first' && ok "6. env: missing node_modules matches" \
  || bad "6. env: missing node_modules matches"
env_detect 'AssertionError: expected 3 to be 4' && bad "6. env: assertion diff must NOT match" \
  || ok "6. env: assertion diff must NOT match"
env_detect "AssertionError: expected 'ok' to equal 'command not found'" \
  && bad "6. env: quoted 'command not found' assertion must NOT match" \
  || ok "6. env: quoted 'command not found' assertion must NOT match"

# 6. compile/resolution detector — real vite/vitest resolution + syntax still match; assertions don't
compile_detect 'Error: Failed to load url ./utils.js (resolved id: ./utils.js). Does the file exist?' \
  && ok "6. compile: 'Failed to load url' matches" || bad "6. compile: 'Failed to load url' matches"
compile_detect 'SyntaxError: Unexpected token' && ok "6. compile: SyntaxError matches" \
  || bad "6. compile: SyntaxError matches"
compile_detect 'AssertionError: expected 5 to be 999' && bad "6. compile: assertion must NOT match" \
  || ok "6. compile: assertion must NOT match"
compile_detect 'TypeError: rectCenter is not a function' \
  && bad "6. compile: undefined-symbol fail-first must NOT match" \
  || ok "6. compile: undefined-symbol fail-first must NOT match"

# 6. resolution detector (newly exposed) — matches the module-resolution subset only
reso_detect 'Error: Failed to load url ./utils.js. Does the file exist?' \
  && ok "6. resolution: 'Failed to load url' matches" || bad "6. resolution: 'Failed to load url' matches"
reso_detect 'Rollup failed to resolve import "./x"' && ok "6. resolution: Rollup matches" \
  || bad "6. resolution: Rollup matches"
reso_detect 'SyntaxError: Unexpected token' && bad "6. resolution: pure SyntaxError must NOT match" \
  || ok "6. resolution: pure SyntaxError must NOT match"
reso_detect 'AssertionError: expected 5 to be 999' && bad "6. resolution: assertion must NOT match" \
  || ok "6. resolution: assertion must NOT match"

# 6. Python arm regression (ModuleNotFoundError = env; IndentationError = compile)
env_detect 'ModuleNotFoundError: No module named pytest' && ok "6. env: Python ModuleNotFoundError matches" \
  || bad "6. env: Python ModuleNotFoundError matches"
compile_detect 'IndentationError: unexpected indent' && ok "6. compile: Python IndentationError matches" \
  || bad "6. compile: Python IndentationError matches"

echo
printf 'impl-failure-classify: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
