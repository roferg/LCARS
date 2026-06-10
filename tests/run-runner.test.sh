#!/usr/bin/env bash
#
# Tests for the LCARS test RUNNER itself (skills source: tests/run.sh).
#
# BUG-009: the Implement red gate runs the configured testCommand with
# $LCARS_TESTS_DIR pointing at the QUARANTINED tests, then probes with an EMPTY
# dir to prove the command reacted to the var. LCARS dogfoods `bash tests/run.sh`,
# so the runner MUST honour $LCARS_TESTS_DIR (and a positional dir) while still
# behaving EXACTLY as today when a human runs it with no var.
#
# Black-box: we never invoke the repo's real suites and never recurse into
# ourselves. We copy tests/run.sh into a temp "home" dir alongside throwaway
# *.test.sh fixtures and drive that copy against temp dirs.
#
# Usage: bash tests/run-runner.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${LCARS_RUN_SH:-$REPO_ROOT/tests/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# Write a throwaway suite that prints a unique marker then exits $3 (default 0).
make_fixture() { # dir name [exit]
  local dir="$1" name="$2" code="${3:-0}"
  cat >"$dir/$name.test.sh" <<EOF
#!/usr/bin/env bash
echo "MARKER:$name"
exit $code
EOF
}

echo "lcars test runner (tests/run.sh)"

[ -f "$RUNNER" ] || { echo "runner under test not found at $RUNNER"; exit 1; }

# A "home" dir = a copy of the runner with its OWN fixtures, standing in for the
# repo's real suite. We never touch the real suite.
home="$(mktemp -d "$TMPROOT/home.XXXX")"
cp "$RUNNER" "$home/run.sh"
make_fixture "$home" "home_one" 0
make_fixture "$home" "home_two" 0

# A quarantine dir with one passing + one failing fixture.
qdir="$(mktemp -d "$TMPROOT/q.XXXX")"
make_fixture "$qdir" "q_pass" 0
make_fixture "$qdir" "q_fail" 1

# An empty dir (no *.test.sh).
empty="$(mktemp -d "$TMPROOT/empty.XXXX")"

# --- 1. $LCARS_TESTS_DIR scopes the run to THAT dir, not the runner's own ----
out1="$(LCARS_TESTS_DIR="$qdir" bash "$home/run.sh" 2>&1)"; rc1=$?
check "1. LCARS_TESTS_DIR runs the quarantine fixtures" \
  "printf '%s' \"\$out1\" | grep -q 'MARKER:q_pass' && printf '%s' \"\$out1\" | grep -q 'MARKER:q_fail'"
check "1. LCARS_TESTS_DIR does NOT run the runner's own suite" \
  "! printf '%s' \"\$out1\" | grep -q 'MARKER:home_'"
check "1. exit reflects ONLY the quarantine fixtures (a failure -> rc 1)" \
  "[ '$rc1' -eq 1 ]"
check "1. final line is SOME SUITES FAILED" \
  "printf '%s' \"\$out1\" | grep -q 'SOME SUITES FAILED'"

# --- 2. No var: full default run over the runner's own dir (regression) ------
out2="$(bash "$home/run.sh" 2>&1)"; rc2=$?
check "2. no var runs the runner's own suite (default dir)" \
  "printf '%s' \"\$out2\" | grep -q 'MARKER:home_one' && printf '%s' \"\$out2\" | grep -q 'MARKER:home_two'"
check "2. no var does NOT run the quarantine dir" \
  "! printf '%s' \"\$out2\" | grep -q 'MARKER:q_'"
check "2. clean default suite exits 0 / ALL SUITES PASSED" \
  "[ '$rc2' -eq 0 ] && printf '%s' \"\$out2\" | grep -q 'ALL SUITES PASSED'"

# --- 3. Empty dir differs from the full run (the red-gate probe property) ----
out3="$(LCARS_TESTS_DIR="$empty" bash "$home/run.sh" 2>&1)"; rc3=$?
check "3. an empty quarantine dir runs NO suites (no markers)" \
  "! printf '%s' \"\$out3\" | grep -q 'MARKER:'"
check "3. empty-dir run DIFFERS from the default full run (probe can react)" \
  "[ \"\$out3\" != \"\$out2\" ]"
check "3. empty-dir run exits 0 / ALL SUITES PASSED" \
  "[ '$rc3' -eq 0 ] && printf '%s' \"\$out3\" | grep -q 'ALL SUITES PASSED'"

# --- 4. Positional arg behaves like the env-var form -------------------------
out4="$(bash "$home/run.sh" "$qdir" 2>&1)"; rc4=$?
check "4. positional dir runs the quarantine fixtures" \
  "printf '%s' \"\$out4\" | grep -q 'MARKER:q_pass' && printf '%s' \"\$out4\" | grep -q 'MARKER:q_fail'"
check "4. positional dir does NOT run the runner's own suite" \
  "! printf '%s' \"\$out4\" | grep -q 'MARKER:home_'"
check "4. positional dir exit matches the env-var form" \
  "[ '$rc4' -eq 1 ]"

# --------------------------------------------------------------------------
echo
echo "  runner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
