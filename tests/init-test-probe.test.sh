#!/usr/bin/env bash
#
# Fast scoped tests for the INIT-TIME TEST PROBE
# (skills/lcars-init/init.sh + the shared run_probe in lcars-common.sh).
#
# WHY THIS EXISTS
# ---------------
# `lcars_test_readiness` is CHEAP by construction — it declares a repo "ready"
# when a testCommand is set and its first token resolves on PATH. It never runs
# anything, because status/board call it constantly.
#
# That makes "ready" a claim about the COMMAND, not about the SUITE. A repo can
# be declared mission-ready while its suite cannot execute at all. Observed in
# the field: a repo pinned vitest 4 against vite 5 (incompatible — vitest 4 needs
# vite >= 6), so every suite died at import and collected ZERO tests. `npx`
# resolved fine, so init reported TEST SYSTEMS ONLINE, and the breakage only
# surfaced days later inside a Mission, misread as a code defect.
#
# init is a ONE-TIME setup action, so it can afford what the cheap verdict can't:
# run the seeded command ONCE and report what actually happened. `lcars update`
# already owns exactly this probe (run_probe/report_probe) — init just never
# called it.
#
# Usage: bash tests/init-test-probe.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_INIT_SCRIPT:-$REPO_ROOT/skills/lcars-init/init.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A JS repo whose detected runner is vitest ⇒ seeded testCommand starts `npx`.
# $1 = probe mode the stubbed npx should act out (pass|fail|zero|hang).
new_repo() {
  local mode="$1"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    cat >package.json <<'EOF'
{
  "name": "x",
  "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^3.2.7" }
}
EOF
    printf 'lock\n' >package-lock.json
  )
  # stubs: claude (CLI present), gh (labels), npx (the suite itself)
  mkdir -p "$repo/bin"
  cat >"$repo/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  cat >"$repo/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "owner/repo"; exit 0; fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then exit 0; fi
exit 0
EOF
  cat >"$repo/bin/npx" <<EOF
#!/usr/bin/env bash
echo "npx \$*" >>"$repo/npx.calls"
case "$mode" in
  pass) echo "Test Files  3 passed (3)"; echo "     Tests  8 passed (8)"; exit 0 ;;
  fail) echo "Test Files  1 failed (3)"; echo "FAIL src/a.test.ts"; exit 1 ;;
  zero) echo "No test files found, exiting with code 1"; exit 1 ;;
  hang) sleep 30; exit 0 ;;
esac
EOF
  chmod +x "$repo/bin/claude" "$repo/bin/gh" "$repo/bin/npx"
  : >"$repo/npx.calls"
  echo "$repo"
}

run_init() { # repo [extra env assignments...]
  local repo="$1"; shift
  ( cd "$repo" && PATH="$repo/bin:$PATH" \
      LCARS_CLAUDE_BIN="$repo/bin/claude" LCARS_GH_BIN="$repo/bin/gh" \
      env "$@" bash "$SCRIPT" >"$repo/out.txt" 2>&1 )
  return $?
}

echo "lcars init — test probe"

# --- 1. a suite that genuinely passes -------------------------------------
R1="$(new_repo pass)"; run_init "$R1"; RC1=$?
check "1a. the seeded command was actually RUN (npx invoked)" \
  '[ -s "$R1/npx.calls" ]'
check "1b. init reports the SUITE verified, not merely configured" \
  'grep -qiE "test systems responding|suite ran and passed" "$R1/out.txt"'
check "1c. init exits 0" '[ "$RC1" -eq 0 ]'

# --- 2. THE REGRESSION: command resolves, suite cannot run ----------------
# `npx` exists, so the cheap verdict says "ready". The probe must contradict it.
R2="$(new_repo fail)"; run_init "$R2"; RC2=$?
check "2a. init does NOT claim test systems are online" \
  '! grep -q "TEST SYSTEMS ONLINE" "$R2/out.txt"'
check "2b. init reports the suite failed" \
  'grep -qiE "PROBE FAILED|reported failures" "$R2/out.txt"'
check "2c. a red suite still does not block setup (exit 0)" \
  '[ "$RC2" -eq 0 ]'

# --- 3. zero-collected is NOT a pass --------------------------------------
# The exact shape that bit us: the runner starts, collects nothing, and a naive
# check reads "no failures" as success.
R3="$(new_repo zero)"; run_init "$R3"
check "3a. zero-collected is called out explicitly" \
  'grep -qiE "zero|no test" "$R3/out.txt"'
check "3b. zero-collected is not reported as online" \
  '! grep -q "TEST SYSTEMS ONLINE" "$R3/out.txt"'

# --- 4. the probe is bounded ----------------------------------------------
R4="$(new_repo hang)"
SECONDS=0; run_init "$R4" LCARS_PROBE_TIMEOUT=2; EL=$SECONDS
check "4a. a hanging suite is cut off by LCARS_PROBE_TIMEOUT" \
  '[ "$EL" -lt 25 ]'
check "4b. the timeout is reported honestly" \
  'grep -qiE "timed out|timeout" "$R4/out.txt"'

# --- 5. opt-out for speed --------------------------------------------------
R5="$(new_repo pass)"; run_init "$R5" LCARS_INIT_SKIP_PROBE=1
check "5. LCARS_INIT_SKIP_PROBE=1 runs no suite" \
  '[ ! -s "$R5/npx.calls" ]'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
