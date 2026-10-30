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
COMMON="${LCARS_COMMON_SH:-$REPO_ROOT/skills/lcars-init/lcars-common.sh}"

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
  slow) sleep \${LCARS_FAKE_SUITE_SECS:-4}
        echo "Test Files  3 passed (3)"; echo "     Tests  8 passed (8)"; exit 0 ;;
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

# --- 6. node --test's OWN zero-collect shape ------------------------------
# S168, measured live: a JS repo whose package.json is
#   {"scripts": {"test": "node --test"}}
# and which has NO test files at all. Node's built-in runner does not print any
# of the phrasings the `zero` signature knew ("No test files found", "collected
# 0 items", …). It prints its own counter block and EXITS 0:
#
#   ℹ tests 0
#   ℹ suites 0
#   ℹ pass 0
#   ℹ fail 0
#
# so init certified "TEST SYSTEMS ONLINE" on a repo with zero tests — a silent
# green on exactly the greenfield case.
#
# These drive the REAL detector (the shared run_probe in lcars-common.sh), not
# a copy of its regex: run_probe is handed a command that replays the runner's
# byte-for-byte output and exit code.
probe_outcome() { # <output> <exit-code> → the resulting PROBE_OUTCOME
  local out="$1" rc="$2" d
  d="$(mktemp -d "$TMPROOT/probe.XXXX")"
  printf '%s' "$out" >"$d/out.txt"
  ( . "$COMMON"
    TOPLEVEL="$d"
    run_probe "cat '$d/out.txt'; exit $rc" >/dev/null 2>&1
    printf '%s' "$PROBE_OUTCOME" )
}

# The three real `node --test` summaries, captured from node v25 (non-TTY).
NODE_ZERO='ℹ tests 0
ℹ suites 0
ℹ pass 0
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 8.519167
'
NODE_PASS='✔ a (0.873958ms)
✔ b (0.083958ms)
✔ c (0.102417ms)
✔ d (0.071250ms)
ℹ tests 4
ℹ suites 0
ℹ pass 4
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 115.587958
'
NODE_FAIL='ℹ tests 6
ℹ suites 0
ℹ pass 4
ℹ fail 2
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 93.409125
'

check "6a. node --test collecting NOTHING (exit 0) is zero-collected, not a pass" \
  '[ "$(probe_outcome "$NODE_ZERO" 0)" = zero-collected ]'
# THE regression that matters most: a healthy Node repo must stay initialisable.
# Its summary is full of standalone zeros (fail 0, cancelled 0, skipped 0,
# todo 0, suites 0) — only the `tests` counter distinguishes the two.
check "6b. node --test with 4 PASSING tests is still a pass" \
  '[ "$(probe_outcome "$NODE_PASS" 0)" = pass ]'
check "6c. node --test with 2 FAILING tests is still a fail" \
  '[ "$(probe_outcome "$NODE_FAIL" 1)" = fail ]'
# The substring hazard, stated explicitly: `tests 10` / `tests 01` contain
# `tests 0` and must never be read as zero-collected.
check "6d. a 10-test node run is not mistaken for zero-collected" \
  '[ "$(probe_outcome "ℹ tests 10
ℹ pass 10
ℹ fail 0
" 0)" = pass ]'

# --- 7. the pre-existing runners classify EXACTLY as before ----------------
check "7a. vitest zero-collect still zero-collected" \
  '[ "$(probe_outcome "No test files found, exiting with code 1
" 1)" = zero-collected ]'
check "7b. vitest green still a pass" \
  '[ "$(probe_outcome "Test Files  3 passed (3)
     Tests  8 passed (8)
" 0)" = pass ]'
check "7c. pytest zero-collect still zero-collected" \
  '[ "$(probe_outcome "collected 0 items

no tests ran in 0.01s
" 5)" = zero-collected ]'
check "7d. pytest green still a pass" \
  '[ "$(probe_outcome "collected 12 items

tests/test_a.py ............                                     [100%]

12 passed in 0.05s
" 0)" = pass ]'

# --- 8. end-to-end: `lcars init` on the real greenfield node repo ----------
# The live repro, driven through init itself rather than the probe alone.
new_node_repo() { # $1 = pass|zero
  local mode="$1" repo
  repo="$(mktemp -d "$TMPROOT/noderepo.XXXX")"
  (
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    printf '{\n  "name": "x",\n  "scripts": { "test": "node --test" }\n}\n' >package.json
    printf 'lock\n' >package-lock.json
  )
  mkdir -p "$repo/bin"
  cat >"$repo/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  cat >"$repo/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "owner/repo"; exit 0; fi
exit 0
EOF
  # `npm test` on this repo shells out to node --test; replay its real output.
  cat >"$repo/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >>"$repo/npm.calls"
case "$mode" in
  zero) printf '%s' '$NODE_ZERO'; exit 0 ;;
  pass) printf '%s' '$NODE_PASS'; exit 0 ;;
esac
EOF
  chmod +x "$repo/bin/claude" "$repo/bin/gh" "$repo/bin/npm"
  : >"$repo/npm.calls"
  echo "$repo"
}

R6="$(new_node_repo zero)"; run_init "$R6"
check "8a. the node suite was actually RUN" '[ -s "$R6/npm.calls" ]'
check "8b. a zero-test node repo is NOT certified online" \
  '! grep -q "TEST SYSTEMS ONLINE" "$R6/out.txt"'
check "8c. init says the runner collected ZERO tests" \
  'grep -qiE "PROBE INCONCLUSIVE|collected ZERO" "$R6/out.txt"'

R7="$(new_node_repo pass)"; run_init "$R7"
check "8d. a HEALTHY node repo is still certified online" \
  'grep -q "TEST SYSTEMS ONLINE" "$R7/out.txt"'

# --- 9. S308: THE PROBE SEEDS THE GATE TIMEOUT IT JUST MEASURED -----------
# The probe is the only place LCARS ever times this repo's whole suite, and it
# threw that number away. On the repo this was measured against it timed out
# and said only "fix it before
# relying on the Implement gates" — while the Implement gates went on to kill
# every proof leg at 120s, five times, with no way for the repo to record that
# its suite needs longer. A measured suite SLOWER than the default gate is a
# fact about the repo; it belongs in .git/lcars/config.json, said out loud.
#
# $LCARS_GATE_TIMEOUT_DEFAULT moves the LAST-RESORT default only, so this proves
# the seeding with a 4-second fake suite instead of a 120-second one. THE
# SHIPPED DEFAULT IS 500s; settings-findings.test.sh locks the timeout path.
cfg_gate() { "${LCARS_PYTHON_BIN:-python3}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("gateTimeout"))' "$1/.git/lcars/config.json" 2>/dev/null; }

R9="$(new_repo slow)"
run_init "$R9" LCARS_GATE_TIMEOUT_DEFAULT=2 LCARS_FAKE_SUITE_SECS=4
check "9a. the measured wall-clock is reported at setup, in seconds" \
  'grep -qE "in [0-9]+s" "$R9/out.txt"'
check "9b. init SEEDS a gateTimeout for a suite slower than the gate" \
  '[ -n "$(cfg_gate "$R9")" ] && [ "$(cfg_gate "$R9")" != None ] && [ "$(cfg_gate "$R9")" -gt 2 ]'
check "9c. and SAYS so, naming the key the captain can change" \
  'grep -q "gateTimeout" "$R9/out.txt"'
check "9d. the recommendation names the key AND the file it is recorded in" \
  'grep "gateTimeout" "$R9/out.txt" | grep -q "config.json"'

# A FAST suite must not seed anything — the key stays null and nothing is said.
R9b="$(new_repo pass)"
run_init "$R9b"
check "9e. a suite inside the 500s default seeds NOTHING" \
  '[ "$(cfg_gate "$R9b")" = None ]'
# (The key is named in the "keys seeded" line, which is correct and expected —
# what must NOT appear is a recommendation about a suite that is not slow.)
check "9f. ...and makes no gate-timeout recommendation" \
  '! grep -qE "recorded gateTimeout=|proof-gate timeout" "$R9b/out.txt"'

# A value the captain already recorded is never overwritten by a later measure.
R9c="$(new_repo slow)"
run_init "$R9c" LCARS_INIT_SKIP_PROBE=1
# In place, ONE line — never a json round trip (see lcars_config_merge: a raw
# value is preserved by capturing its line's tail, so a pretty-printer would
# split `numberOne` across lines and corrupt the config).
sed -i.bak 's/"gateTimeout": [^,]*,/"gateTimeout": 999,/' "$R9c/.git/lcars/config.json"
rm -f "$R9c/.git/lcars/config.json.bak"
run_init "$R9c" LCARS_GATE_TIMEOUT_DEFAULT=2 LCARS_FAKE_SUITE_SECS=4
check "9g. an existing gateTimeout is PRESERVED, never re-measured over" \
  '[ "$(cfg_gate "$R9c")" = 999 ]'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
