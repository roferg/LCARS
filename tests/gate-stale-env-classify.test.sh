#!/usr/bin/env bash
#
# Fast, STANDALONE test for the STALE-DEPENDENCY-ENVIRONMENT classifier
# `stale_dep_env_reason` (skill source: skills/lcars-run/run.sh).
#
# WHY THIS EXISTS
# ---------------
# When a gate's suite goes RED, the post-commit gate says:
#
#   "The implementation is NOT present on the committed branch"
#
# That is an accusation about the ticket's CODE, and it is sometimes simply
# false. The gate provisions its worktree by SYMLINKING the main checkout's
# node_modules. If the ticket CHANGED dependencies, the shared install is the
# wrong dependency set — the committed code is right there, but it is being
# tested against packages its own commit replaced.
#
# Observed in the field: a ticket pinned vitest ^3.2.7 to repair a suite that
# could never run (vitest 4 against vite 5). The gate symlinked a node_modules
# still holding vitest 4, every suite died at import, and the gate reported a
# missing implementation. Three sessions were spent re-solving a solved problem.
#
# The existing classifier `red_gate_env_failure` does not catch this: it keys on
# the runner failing to START (command-not-found class). Here the runner starts
# perfectly — it just has the wrong packages. This is the STATE-based companion:
# it inspects the worktree's dependency environment against its own committed
# lockfile and reports evidence of staleness.
#
# CONSERVATIVE BY DESIGN: it reports staleness only on POSITIVE evidence (deps
# shared by symlink from another checkout AND a lockfile that differs). With no
# evidence it stays silent, so a genuinely missing implementation keeps its
# existing, correct wording.
#
# PURE FILESYSTEM INSPECTION: no runner, no model, no network, ZERO tokens.
# Safe to run directly. Do NOT route through tests/run.sh.
#
# Usage: bash tests/gate-stale-env-classify.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

TMPROOT="$(mktemp -d)"
LIB="$(mktemp)"
trap 'rm -rf "$TMPROOT" "$LIB"' EXIT

sed -n '/^stale_dep_env_reason() {/,/^}/p' "$RUN_SH" >"$LIB"
# shellcheck source=/dev/null
. "$LIB"

if ! type stale_dep_env_reason >/dev/null 2>&1; then
  echo "FATAL: could not extract stale_dep_env_reason from $RUN_SH" >&2
  exit 1
fi

echo "post-commit gate — stale dependency environment classifier"

# Build a MAIN checkout and a gate worktree that shares its node_modules by
# symlink, exactly as worktreeSetupCommand provisions one.
# $1 case name, $2 main's lockfile bytes, $3 worktree's lockfile bytes,
# $4 lockfile name, $5 "symlink"|"real"|"none"
make_case() {
  local name="$1" mainlock="$2" wtlock="$3" lockname="$4" kind="$5"
  local main="$TMPROOT/$name/main" wt="$TMPROOT/$name/wt"
  mkdir -p "$main/node_modules" "$wt"
  printf '%s\n' "$mainlock" >"$main/$lockname"
  printf '%s\n' "$wtlock"   >"$wt/$lockname"
  case "$kind" in
    symlink) ln -s "$main/node_modules" "$wt/node_modules" ;;
    real)    mkdir -p "$wt/node_modules" ;;
    none)    : ;;
  esac
  echo "$wt"
}

# --- 1. THE BUG: shared deps + a lockfile the ticket changed ---------------
WT1="$(make_case diverge MAIN FEATURE package-lock.json symlink)"
R1="$(stale_dep_env_reason "$WT1")"
check "1a. divergent lockfile behind a shared install is reported" \
  '[ -n "$R1" ]'
check "1b. the reason names the lockfile that diverged" \
  'printf %s "$R1" | grep -q "package-lock.json"'

# --- 2. shared deps, SAME lockfile => not stale ----------------------------
WT2="$(make_case same MAIN MAIN package-lock.json symlink)"
check "2. matching lockfile behind a shared install is silent" \
  '[ -z "$(stale_dep_env_reason "$WT2")" ]'

# --- 3. the worktree OWNS its node_modules => not decidable, stay silent ----
# A real install in the worktree is by definition the worktree's own deps, so a
# lockfile difference against some other checkout proves nothing.
WT3="$(make_case owned MAIN FEATURE package-lock.json real)"
check "3. a real (non-shared) node_modules is never called stale" \
  '[ -z "$(stale_dep_env_reason "$WT3")" ]'

# --- 4. no node_modules at all => the START-failure classifier's job --------
WT4="$(make_case nodeps MAIN FEATURE package-lock.json none)"
check "4. an absent node_modules is left to red_gate_env_failure" \
  '[ -z "$(stale_dep_env_reason "$WT4")" ]'

# --- 5. the other lockfile flavours are covered too ------------------------
WT5="$(make_case pnpm MAIN FEATURE pnpm-lock.yaml symlink)"
check "5a. pnpm-lock.yaml divergence is detected" \
  '[ -n "$(stale_dep_env_reason "$WT5")" ]'
WT6="$(make_case yarn MAIN FEATURE yarn.lock symlink)"
check "5b. yarn.lock divergence is detected" \
  '[ -n "$(stale_dep_env_reason "$WT6")" ]'

# --- 6. defensive: a missing/nonsense path must not explode -----------------
check "6a. a nonexistent worktree path is silent, not an error" \
  '[ -z "$(stale_dep_env_reason "$TMPROOT/does-not-exist")" ]'
check "6b. an empty argument is silent, not an error" \
  '[ -z "$(stale_dep_env_reason "")" ]'

# --- 7. WIRING: the post-commit gate must consult it BEFORE accusing --------
# The whole point is the ordering: if the accusation is emitted first, the
# classifier is decorative.
GATE_START="$(grep -n '^post_commit_gate() {' "$RUN_SH" | cut -d: -f1)"
CALL_LINE="$(awk -v s="$GATE_START" 'NR>s && /stale_dep_env_reason/ {print NR; exit}' "$RUN_SH")"
ACCUSE_LINE="$(awk -v s="$GATE_START" 'NR>s && /implementation is NOT present/ {print NR; exit}' "$RUN_SH")"

check "7a. post_commit_gate consults the classifier" \
  '[ -n "$CALL_LINE" ]'
check "7b. it consults it BEFORE the missing-implementation accusation" \
  '[ -n "$CALL_LINE" ] && [ -n "$ACCUSE_LINE" ] && [ "$CALL_LINE" -lt "$ACCUSE_LINE" ]'

# --- 8. WIRING: the full-suite gate has the SAME fault and the same fix -----
# It re-runs earlier tickets' suites in a provisioned worktree too, so a stale
# shared install makes healthy suites read as regressions.
FS_START="$(grep -n '^full_suite_gate() {' "$RUN_SH" | cut -d: -f1)"
FS_CALL="$(awk -v s="$FS_START" 'NR>s && /stale_dep_env_reason/ {print NR; exit}' "$RUN_SH")"
FS_ACCUSE="$(awk -v s="$FS_START" 'NR>s && /no longer pass against the fully-built repo/ {print NR; exit}' "$RUN_SH")"

check "8a. full_suite_gate consults the classifier" \
  '[ -n "$FS_CALL" ]'
check "8b. it reads the evidence BEFORE the regression accusation" \
  '[ -n "$FS_CALL" ] && [ -n "$FS_ACCUSE" ] && [ "$FS_CALL" -lt "$FS_ACCUSE" ]'
# The worktree is torn down mid-function; reading it after would always be empty.
FS_REMOVE="$(awk -v s="$FS_START" 'NR>s && /worktree remove --force "\$wt"/ {print NR; exit}' "$RUN_SH")"
check "8c. the evidence is read BEFORE the worktree is removed" \
  '[ -n "$FS_CALL" ] && [ -n "$FS_REMOVE" ] && [ "$FS_CALL" -lt "$FS_REMOVE" ]'

# --- 9. WIRING: the S157 x #93 MERGE SEAM — ordering is the whole invariant ---
# #93 says a stale dependency environment is a TOOLCHAIN fault, so no ticket may
# be accused. S157 says a real regression must be attributed to the ticket that
# AUTHORED the failing suite, via $FULL_SUITE_REGRESSED, which self-heal reads to
# pick who gets the reconcile. Neither change knew about the other, and the two
# only agree because of ORDER: the stale-env block returns BEFORE
# FULL_SUITE_REGRESSED is assigned, so a toolchain fault attributes to nobody.
#
# Hoisting that assignment above the early return would compile, pass every other
# test in this file and in proof-gates, and silently hand a worker a ticket to
# "fix" for a broken toolchain — the false-premise reconcile BOTH changes exist
# to end. So it is pinned as ordering, exactly like 7b/8b/8c above.
# (The behavioural half of this seam — that the signal names no ticket, and that
# a genuine regression is unaffected — lives in tests/proof-gates.test.sh
# section V, which owns the mission fixtures and the full_suite_gate hook.)
FS_END="$(awk -v s="$FS_START" 'NR>s && /^\}/ {print NR; exit}' "$RUN_SH")"
FS_RESET="$(awk -v s="$FS_START" -v e="$FS_END" 'NR>s && NR<e && /^  FULL_SUITE_REGRESSED=""/ {print NR; exit}' "$RUN_SH")"
FS_STALE_IF="$(awk -v s="$FS_START" -v e="$FS_END" 'NR>s && NR<e && /if \[ -n "\$\{FULL_SUITE_STALE_ENV/ {print NR; exit}' "$RUN_SH")"
FS_STALE_RET="$(awk -v s="${FS_STALE_IF:-0}" -v e="$FS_END" 'NR>s && NR<e && /^    return 1$/ {print NR; exit}' "$RUN_SH")"
FS_ASSIGN="$(awk -v s="$FS_START" -v e="$FS_END" 'NR>s && NR<e && /^  FULL_SUITE_REGRESSED="\$regressed"/ {print NR; exit}' "$RUN_SH")"

check "9a. full_suite_gate resets FULL_SUITE_REGRESSED at entry (no inherited verdict)" \
  '[ -n "$FS_RESET" ] && [ -n "$FS_STALE_IF" ] && [ "$FS_RESET" -lt "$FS_STALE_IF" ]'
check "9b. the stale-env block exists and RETURNS rather than falling through" \
  '[ -n "$FS_STALE_IF" ] && [ -n "$FS_STALE_RET" ] && [ "$FS_STALE_RET" -gt "$FS_STALE_IF" ]'
check "9c. it returns BEFORE FULL_SUITE_REGRESSED is assigned (a stale env accuses no ticket)" \
  '[ -n "$FS_STALE_RET" ] && [ -n "$FS_ASSIGN" ] && [ "$FS_STALE_RET" -lt "$FS_ASSIGN" ]'
check "9d. and the classifier is READ before the block that consumes it" \
  '[ -n "$FS_CALL" ] && [ -n "$FS_STALE_IF" ] && [ "$FS_CALL" -lt "$FS_STALE_IF" ]'
# The attribution the assignment feeds must still be downstream of the accusation
# wording, i.e. the ids are recorded for a consumer, not parsed back out of prose.
check "9e. the assignment precedes the regression detail it attributes" \
  '[ -n "$FS_ASSIGN" ] && [ -n "$FS_ACCUSE" ] && [ "$FS_ASSIGN" -lt "$FS_ACCUSE" ]'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
