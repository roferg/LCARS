#!/usr/bin/env bash
#
# Tests the LOCKFILE GUARD on the seeded worktreeSetupCommand
# (skills/lcars-init/lcars-common.sh → detect_worktree_setup_cmd).
#
# WHY THIS EXISTS
# ---------------
# The JS default provisions a Stage worktree by SYMLINKING the main checkout's
# node_modules — fast, offline, and correct right up until a ticket CHANGES the
# dependencies. Then the symlink serves the main checkout's OLD packages while
# the worktree's committed lockfile asks for new ones, so the ticket's own
# dependency fix can never take effect. Observed in the field: a ticket pinned
# vitest ^3.2.7 to repair an unrunnable suite, the post-commit gate symlinked a
# node_modules still holding vitest 4, the suite died on import, and the gate
# reported "the implementation is NOT present on the committed branch". No
# committed lockfile change could ever have fixed it.
#
# The guard: symlink ONLY while the worktree's lockfile matches the main
# checkout's. When they diverge, the shared node_modules is by definition the
# WRONG dependency set, so do a real install instead.
#
# These are BEHAVIOURAL tests — they run the emitted command inside a real git
# worktree with a stubbed `npm`, and assert which path it took. Asserting on the
# emitted string alone would pass for a command that never actually branches.
#
# Usage: bash tests/worktree-provision-lockfile.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${LCARS_COMMON_SH:-$REPO_ROOT/skills/lcars-init/lcars-common.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# shellcheck source=/dev/null
. "$COMMON"

# --- fixture ---------------------------------------------------------------
# A real repo with a real worktree: the emitted command resolves the main
# checkout via `git rev-parse --git-common-dir`, so a fake dir will not do.
#
# $1 = case name; $2 = the lockfile contents to commit on the worktree's branch.
# Echoes the worktree path. A stub `npm` on PATH records its args instead of
# installing, so the test is hermetic and fast.
make_case() {
  local name="$1" wt_lock="$2"
  local main="$TMPROOT/$name/main"
  mkdir -p "$main"
  (
    cd "$main"
    git init -q .
    git config user.email t@t.t; git config user.name t
    printf '{"name":"x","version":"1.0.0"}\n' >package.json
    printf 'MAIN-LOCK\n' >package-lock.json
    git add -A; git commit -qm init
    git checkout -qb feature
    printf '%s\n' "$wt_lock" >package-lock.json
    git add -A; git commit -qm feature
    git checkout -qm main >/dev/null 2>&1 || git checkout -q master
    # The main checkout's INSTALLED deps — what the symlink path would serve.
    mkdir -p node_modules
    printf 'stale\n' >node_modules/.marker
    git worktree add -q --detach "$TMPROOT/$name/wt" feature
  ) >/dev/null 2>&1
  echo "$TMPROOT/$name/wt"
}

# A stub npm that records invocation instead of installing.
STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_CALLS"
mkdir -p node_modules
echo fresh >node_modules/.marker
EOF
chmod +x "$STUBBIN/npm"

# Run the seeded command inside $1, with the npm stub on PATH.
run_setup() {
  local wt="$1" cmd="$2"
  export NPM_CALLS="$wt/.npm-calls"
  : >"$NPM_CALLS"
  ( cd "$wt" && PATH="$STUBBIN:$PATH" bash -c "$cmd" ) >/dev/null 2>&1
}

echo "worktree provisioning — lockfile guard"

# The seed is emitted for the repo at $TOPLEVEL.
SEED_REPO="$TMPROOT/seed"
mkdir -p "$SEED_REPO"
printf '{"name":"x"}\n' >"$SEED_REPO/package.json"
printf 'lock\n' >"$SEED_REPO/package-lock.json"
TOPLEVEL="$SEED_REPO"
CMD="$(detect_worktree_setup_cmd)"

check "a JS repo still gets a non-empty seeded command" \
  '[ -n "$CMD" ]'

# --- 1. DIVERGENT lockfile => real install, never the stale symlink ---------
WT_DIFF="$(make_case diverge 'FEATURE-LOCK-DIFFERENT')"
run_setup "$WT_DIFF" "$CMD"

check "divergent lockfile: node_modules is NOT a symlink to the main checkout" \
  '[ ! -L "$WT_DIFF/node_modules" ]'
check "divergent lockfile: a real install ran (npm ci)" \
  'grep -q "npm ci" "$WT_DIFF/.npm-calls"'
check "divergent lockfile: the stale marker was NOT served" \
  '[ "$(cat "$WT_DIFF/node_modules/.marker" 2>/dev/null)" != "stale" ]'

# --- 2. MATCHING lockfile => keep the fast symlink path --------------------
# Same bytes as the main checkout's lockfile, so the shared install is correct
# and reusing it is exactly right. The guard must not cost us this.
WT_SAME="$(make_case match 'MAIN-LOCK')"
run_setup "$WT_SAME" "$CMD"

check "matching lockfile: node_modules IS symlinked (fast path preserved)" \
  '[ -L "$WT_SAME/node_modules" ]'
check "matching lockfile: no install was run" \
  '[ ! -s "$WT_SAME/.npm-calls" ]'

# --- 3. no main node_modules => still installs (unchanged legacy behaviour) --
WT_NONE="$(make_case nonm 'MAIN-LOCK')"
rm -rf "$TMPROOT/nonm/main/node_modules"
run_setup "$WT_NONE" "$CMD"

check "no main node_modules: falls back to a real install as before" \
  'grep -q "npm ci" "$WT_NONE/.npm-calls"'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
