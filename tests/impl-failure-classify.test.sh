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
have() { command -v "$1" >/dev/null 2>&1; }

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

# 7. (S131) HONEST TERMINAL CATEGORY for the declared-setup include/placement trap.
#    (Live 2026-07-09: a declared vitest config with include: tests/** vs a test
#    relocated co-located → zero collected on every attempt → exhaustion was
#    misclassified as over-broad-slice, pointing the captain at a scoping problem
#    that doesn't exist.) Trigger: a declared setup was APPLIED this mission
#    (marker threaded by the caller as the 4th input / $LCARS_CLASSIFY_SETUP_APPLIED)
#    AND the runner output carries the zero-collect signature.
classify_setup() { # runner_out [files_written] -> echoes the category (setup applied)
  local runner="$1" files="${2:-tests/x.test.js}"
  printf '%s' "$runner" | ( cd "$REPO_ROOT" \
    && LCARS_CLASSIFY_FILES="$files" LCARS_CLASSIFY_SETUP_APPLIED=1 \
       bash "$SCRIPT" classify-impl-failure-test )
}
RUNNER_ZERO='SELF-SMOKE — your suite collected ZERO tests
 RUN  v1.6.1 /w/t-001/example-game
filter:  src/controls-hint.test.js
include: tests/**/*.test.{js,mjs,ts}
No test files found, exiting with code 1'
expect_cat "7a. zero-collect + setup applied → test-infra-mismatch" \
  "test-infra-mismatch" \
  "$(classify_setup "$RUNNER_ZERO")"
expect_cat "7b. zero-collect WITHOUT setup → over-broad-slice (genuine no-coherent-red keeps its name)" \
  "over-broad-slice" \
  "$(classify "$RUNNER_ZERO" "tests/x.test.js")"
expect_cat "7c. genuine assertion red + setup applied → genuine-red-exhausted (the flag alone never hijacks)" \
  "genuine-red-exhausted" \
  "$(classify_setup "$RUNNER_ASSERT")"
expect_cat "7d. hang marker + setup applied → suite-hang (hang precedence holds)" \
  "suite-hang" \
  "$(classify_setup 'SELF-SMOKE — your suite HUNG: the suite never settled within the hard timeout')"

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

# ==========================================================================
# S192 — `make:` DIAGNOSTICS THAT MEAN THE RUNNER NEVER RAN
#
# THE DEFECT (ledgered by S193 as L2, INHERITED — byte-identical at HEAD —
# and adopted into S192 because it sits on the arm the capstone drives live).
# The greenfield python foundation seeds `make test` as the mission's
# testCommand. On ticket 2's PARENT commit the Makefile (or its target, or the
# venv the recipe execs) does not exist yet, so make prints its OWN diagnostic
# and exits non-zero. NOT ONE arm of the env pattern matched those, so
# proof_parent_red_kind fell through to `runner-red` — which the flip-flop gate
# reads as PROOF that a genuine test ran and failed. A parent commit with no
# runner manufactured a flip-flop that never happened.
#
# THE CRUX, and the reason every buffer below is CAPTURED from a real `make`
# run at test time rather than typed from memory: make prints the SAME
# recipe-failed line (`make: *** [test] Error 1`) whether its recipe could not
# be EXECUTED at all or whether it ran a real test runner that failed an
# assertion. Only make's own *runner-absent* lines discriminate, so those are
# what the env arm matches — never the exit-status line, never `Error 1`.
# MEASURED HERE: GNU Make 3.81 (macOS /usr/bin/make) reports a failed exec as
# `Error 1`; GNU Make 4.4.1 reports the same failure as `Error 127`. An
# exit-code rule would therefore be wrong on 3.81 in one direction and is
# unnecessary on 4.4.1 in the other.
#
# Offline and free: `make` is a local binary, each capture is a few
# milliseconds, and nothing here spawns a worker or touches the network.
# ==========================================================================
echo
echo "S192 — make's own runner-absent diagnostics are ENV failures (REAL make, captured here)"

MKROOT="$(mktemp -d)"
trap 'rm -rf "$MKROOT"' EXIT

mk_run() { # make-bin  case-name  makefile-content ('' = no Makefile) → REAL bytes
  local mkbin="$1" name="$2" content="$3" d="$MKROOT/$2"
  mkdir -p "$d"
  [ -n "$content" ] && printf '%s' "$content" > "$d/Makefile"
  ( cd "$d" && "$mkbin" test 2>&1 )
}

# One body of proofs, run against EVERY make on this box (`make` and, when
# installed, `gmake` — GNU 3.81 and 4.x phrase and quote these differently:
# 3.81 writes `No rule to make target \`test'` with a backtick, 4.x writes
# `'test'`, and 4.x adds `[Makefile:2: test]` where 3.81 writes `[test]`).
make_arm_proofs() { # make-bin  label
  local mkbin="$1" L="$2" cap

  cap="$(mk_run "$mkbin" "$L-norule" '')"
  env_detect "$cap" \
    && ok "M1 ($L). no Makefile at all → 'No rule to make target' is an env failure" \
    || bad "M1 ($L). runner-absent 'No rule to make target' NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  cap="$(mk_run "$mkbin" "$L-notarget" "$(printf 'all:\n\t@echo hi\n')")"
  env_detect "$cap" \
    && ok "M2 ($L). Makefile present but NO test target → env failure" \
    || bad "M2 ($L). missing test target NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  cap="$(mk_run "$mkbin" "$L-nointerp" "$(printf 'test:\n\t.venv/bin/python -m unittest discover\n')")"
  env_detect "$cap" \
    && ok "M3 ($L). recipe's interpreter is absent → env failure" \
    || bad "M3 ($L). absent interpreter NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  cap="$(mk_run "$mkbin" "$L-nobin" "$(printf 'test:\n\tlcars-s192-no-such-runner\n')")"
  env_detect "$cap" \
    && ok "M4 ($L). recipe's binary is absent (make execs it directly) → env failure" \
    || bad "M4 ($L). absent binary NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  cap="$(mk_run "$mkbin" "$L-shellcnf" "$(printf 'test:\n\tlcars-s192-no-such-runner && echo done\n')")"
  env_detect "$cap" \
    && ok "M5 ($L). recipe's binary absent via the SHELL (command not found) → env failure" \
    || bad "M5 ($L). shell command-not-found NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  mkdir -p "$MKROOT/$L-submake/sub"
  printf 'all:\n\t@echo hi\n' > "$MKROOT/$L-submake/sub/Makefile"
  cap="$(mk_run "$mkbin" "$L-submake" "$(printf 'test:\n\t$(MAKE) -C sub test\n')")"
  env_detect "$cap" \
    && ok "M6 ($L). SUB-make prefix (make[1]:/gmake[1]:) → env failure" \
    || bad "M6 ($L). sub-make prefix NOT kinded env: $(printf '%s' "$cap" | tr '\n' '|')"

  # THE LOAD-BEARING NEGATIVE: make's recipe RAN a real test runner and that
  # runner failed an assertion. make still prints `*** [test] Error 1`. This is
  # a GENUINE red and the gate must keep reading it as proof.
  if have python3; then
    local d="$MKROOT/$L-genuine"
    mkdir -p "$d/tests"
    printf 'import unittest\nclass T(unittest.TestCase):\n    def test_x(self):\n        self.assertEqual(1 + 1, 3)\n' > "$d/tests/test_x.py"
    cap="$(mk_run "$mkbin" "$L-genuine" "$(printf 'test:\n\tpython3 -m unittest discover -s tests\n')")"
    if printf '%s' "$cap" | grep -q 'FAILED (failures=1)'; then
      if env_detect "$cap"; then
        bad "M7 ($L). A GENUINE RED WAS SWALLOWED AS AN ENV FAILURE: $(printf '%s' "$cap" | tr '\n' '|')"
      else ok "M7 ($L). recipe RAN a real runner that failed an assertion → NOT env (still a genuine red)"; fi
      expect_cat "M7b ($L). …and it classifies as a genuine assertion red" \
        "genuine-red-exhausted" "$(classify "$cap" "$(printf 'tests/test_x.py\n')")"
    else
      bad "M7 ($L). the captured buffer is not a real unittest failure — M7 proves nothing"
    fi
  else
    printf '  SKIP M7 (%s). python3 absent — the genuine-red-under-make negative did NOT run\n' "$L"
  fi
}

MK_BIN="$(command -v make 2>/dev/null || true)"
GMK_BIN="$(command -v gmake 2>/dev/null || true)"
if [ -n "$MK_BIN" ]; then make_arm_proofs "$MK_BIN" "make"
else printf '  SKIP make not installed — the S192 make-arm proofs did NOT run\n'; fi
if [ -n "$GMK_BIN" ]; then make_arm_proofs "$GMK_BIN" "gmake"
else printf '  SKIP gmake not installed — the gmake-prefix proofs did NOT run\n'; fi

# --- the anchor is load-bearing: a QUOTED phrase mid-line must never fire ----
# S185 and S193 both shipped defects that came from unanchored matching, so the
# new forms are anchored on make's OWN line-start prefix exactly like the npm
# and shell forms. These attack strings are deliberately HAND-WRITTEN: they are
# not tool transcripts, they are what a test asserting ON make's error text
# looks like when it fails, and the gate must still call that a genuine red.
ATT1="AssertionError: expected 'ok' to equal \"make: *** No rule to make target 'test'.  Stop.\""
env_detect "$ATT1" \
  && bad "M8. an assertion QUOTING make's no-rule text mid-line matched the env arm" \
  || ok "M8. an assertion QUOTING make's no-rule text mid-line does NOT match"
ATT2="$(printf -- '-      expect(err).toBe("make: .venv/bin/python: No such file or directory")\n+      expect(err).toBe("ok")\n')"
env_detect "$ATT2" \
  && bad "M9. a DIFF quoting make's missing-interpreter line matched the env arm" \
  || ok "M9. a DIFF quoting make's missing-interpreter line does NOT match"
ATT3="$(printf 'No rule to make target %stest%s.  Stop.\n' "'" "'")"
env_detect "$ATT3" \
  && bad "M10. the bare phrase with NO make: prefix matched the env arm" \
  || ok "M10. the bare phrase with no make: prefix does NOT match (the prefix is the anchor)"
ATT4="$(printf 'FAIL: test_make_error (tests.test_msg.T)\nAssertionError: %smake: *** [test] Error 1%s != %sok%s\n' "'" "'" "'" "'")"
env_detect "$ATT4" \
  && bad "M11. an assertion quoting make's recipe-failed line matched the env arm" \
  || ok "M11. an assertion quoting make's recipe-failed line does NOT match"

# --- the exit-status line NEVER decides -------------------------------------
# `Error 1` is what BOTH a dead exec (3.81) and a genuine assertion red (every
# make) print, so it must not be matched on its own in either direction.
env_detect "$(printf 'make: *** [Makefile:2: test] Error 1\n')" \
  && bad "M12. make's bare 'Error 1' line was treated as an env failure" \
  || ok "M12. make's bare 'Error 1' line alone is NOT an env failure"
env_detect "$(printf 'make: *** [test] Error 2\n')" \
  && bad "M13. make's bare 'Error 2' line was treated as an env failure" \
  || ok "M13. make's bare 'Error 2' line alone is NOT an env failure"

echo
printf 'impl-failure-classify: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
