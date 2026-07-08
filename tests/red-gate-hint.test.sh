#!/usr/bin/env bash
#
# Fast, STANDALONE test for the red-gate resolution-failure HINT helper
# `unresolved_imports_in_output` (skill source: skills/lcars-run/run.sh).
#
# WHY: the Implement red gate rejects a Test-Writer suite that fails to LOAD on
# an unresolved import (a brand-new module the ticket must create) and feeds the
# rejection back as "RED-GATE FEEDBACK". Historically that feedback buried the
# exact unresolved specifier inside vite's verbose stack trace, so a weaker model
# (copilot) did not reliably self-correct within the 3-attempt cap. This helper
# extracts the DISTINCT unresolved import specifier(s) from common bundler/runtime
# phrasings so the feedback can NAME them up front — turning a fuzzy retry into a
# precise, actionable one for both engines.
#
# PURE STRING PARSING: no side effects, no runner, no model, no network, ZERO
# tokens. Extracts the function body with `sed` and drives it with fixed strings.
# Safe to run directly. Do NOT route through tests/run.sh.
#
# Usage: bash tests/red-gate-hint.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# --- extract the pure helper(s) under test (mirror lcars-worker-hang.test.sh) --
LIB="$(mktemp)"; trap 'rm -f "$LIB"' EXIT
sed -n '/^unresolved_imports_in_output() {/,/^}/p' "$RUN_SH" >"$LIB"
sed -n '/^red_gate_resolution_failure() {/,/^}/p'  "$RUN_SH" >>"$LIB"
sed -n '/^unresolved_specifier_triage() {/,/^}/p'  "$RUN_SH" >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"

for fn in unresolved_imports_in_output red_gate_resolution_failure; do
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: could not extract $fn from $RUN_SH" >&2
    exit 1
  fi
done

# === A. a real vite "Failed to resolve import" line → the exact specifier =====
out_vite='Failed to resolve import "../src/state/themeStore" from ".lcars-tests/theme-toggle.test.tsx". Does the file exist?'
got="$(unresolved_imports_in_output "$out_vite")"
if [ "$got" = "../src/state/themeStore" ]; then
  ok "A. vite Failed-to-resolve-import → ../src/state/themeStore"
else
  bad "A. vite specifier (expected ../src/state/themeStore, got '$got')"
fi

# === B. node "Cannot find module 'X'" → X ===================================
got="$(unresolved_imports_in_output "Error: Cannot find module 'foo/bar' imported from x.js")"
if [ "$got" = "foo/bar" ]; then
  ok "B. Cannot find module 'foo/bar' → foo/bar"
else
  bad "B. Cannot-find-module specifier (expected foo/bar, got '$got')"
fi

# === C. multiple DISTINCT specifiers, deduped, one per line =================
multi='Failed to resolve import "../src/a" from ".lcars-tests/x.test.tsx". Does the file exist?
Failed to resolve import "../src/b" from ".lcars-tests/y.test.tsx". Does the file exist?
Failed to resolve import "../src/a" from ".lcars-tests/z.test.tsx". Does the file exist?'
got="$(unresolved_imports_in_output "$multi")"
exp="$(printf '../src/a\n../src/b')"
if [ "$got" = "$exp" ]; then
  ok "C. multiple specifiers deduped (../src/a, ../src/b)"
else
  bad "C. deduped multi (expected '$exp', got '$got')"
fi

# === D. an assertion-only failure yields NOTHING (defensive) ================
got="$(unresolved_imports_in_output "AssertionError: expected 5 to be undefined")"
if [ -z "$got" ]; then
  ok "D. assertion-only output → no specifier extracted (empty)"
else
  bad "D. assertion-only should be empty, got '$got'"
fi

# === E. stdin input path also works =========================================
got="$(printf '%s\n' "$out_vite" | unresolved_imports_in_output)"
if [ "$got" = "../src/state/themeStore" ]; then
  ok "E. reads runner output from stdin too"
else
  bad "E. stdin path (expected ../src/state/themeStore, got '$got')"
fi

# === F. S111 specifier triage: exists→path verdict, absent→stub verdict ======
# (five identical live bounces: the worker kept choosing stub-vs-path wrong;
# the harness now states the verdict per specifier.)
TRROOT="$(mktemp -d)"; trap 'rm -f "$LIB"; rm -rf "$TRROOT"' EXIT
mkdir -p "$TRROOT/src/components/Toolbar" "$TRROOT/src/state" "$TRROOT/node_modules/junk"
printf 'x\n' > "$TRROOT/src/components/Toolbar/Toolbar.tsx"
printf 'x\n' > "$TRROOT/node_modules/junk/useTheme.ts"   # must be ignored
got="$(printf './Toolbar\n./useTheme\n' | unresolved_specifier_triage "$TRROOT")"
if printf '%s' "$got" | grep -q "\./Toolbar → the module EXISTS in the repo at: src/components/Toolbar/Toolbar.tsx"; then
  ok "F1. existing module → names its real repo location (path verdict)"
else
  bad "F1. exists-verdict wrong (got: $(printf '%s' "$got" | head -1))"
fi
if printf '%s' "$got" | grep -q "\./useTheme → NO file matching 'useTheme' exists"; then
  ok "F2. absent module → MUST-stub verdict (node_modules match ignored)"
else
  bad "F2. absent-verdict wrong (got: $(printf '%s' "$got" | tail -1))"
fi

# --- summary ----------------------------------------------------------------
echo
printf 'red-gate-hint: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
