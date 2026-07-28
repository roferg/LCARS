#!/usr/bin/env bash
#
# Fast scoped tests for the worktreeSetupCommand LOCKFILE-GUARD migration in
# `lcars update` (skills/lcars-update/update.sh + skills/lcars-init/lcars-common.sh).
#
# Repos initialized by an OLDER `lcars init` carry the un-guarded JS default:
# symlink the main checkout's node_modules whenever it exists, full stop. That
# is wrong for any ticket that CHANGES dependencies — the shared install is then
# the wrong dependency set, the ticket's own lockfile fix can never take effect,
# and the gate blames the implementation for a stale environment.
#
# Fixing the seed only helps repos initialized from now on. `lcars update` must
# recognize LCARS's own un-guarded symlink command and rewrite it in place —
# and touch a captain's custom command never.
#
# Mirrors tests/lcars-update-testcommand-migration.test.sh: a temp git repo, a
# stubbed gh, the REAL update.sh, asserting config.json.
#
# Usage: bash tests/lcars-update-worktree-guard.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_UPDATE_SCRIPT:-$REPO_ROOT/skills/lcars-update/update.sh}"
INIT="$REPO_ROOT/skills/lcars-init/init.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

make_claude_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  chmod +x "$1"
}

make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "owner/repo"; exit 0; fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  [ -f "$GH_EXISTING" ] && cat "$GH_EXISTING"; exit 0; fi
exit 0
EOF
  chmod +x "$1"
}

all_labels() {
  cat >"$1" <<'EOF'
lcars:align
lcars:research
lcars:validate
lcars:plan
lcars:plan-review
lcars:schedule
lcars:implement
lcars:verify
lcars:done
lcars:feature
lcars:bug
lcars:paused
lcars:awaiting-human
lcars:linked
lcars:mission
lcars:ticket
EOF
}

# A JS repo (package.json + package-lock.json ⇒ the npm seed shape).
new_js_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    printf '{"name":"x"}\n' >package.json
    printf 'lock\n' >package-lock.json
  )
  make_claude_stub "$repo/claude"; make_gh_stub "$repo/gh"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
  ( cd "$repo" && LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" \
      bash "$INIT" >/dev/null 2>&1 )
  echo "$repo"
}

run_update() {
  local repo="$1"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$repo/existing"; all_labels "$GH_EXISTING"
  ( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >"$repo/out.txt" 2>&1 )
}

cfg_get() {
  sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" \
    | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}

set_cfg() { # config key value  — via the shipped writer, so escaping matches
  ( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"
    lcars_config_set_string "$1" "$2" "$3" )
}

# The EXACT un-guarded shape an older `lcars init` seeded for an npm repo.
LEGACY='MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ]; then find "$MAIN" -path "$MAIN/.git" -prune -o -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else npm ci; fi'

echo "lcars update — worktreeSetupCommand lockfile guard migration"

# --- 1. the legacy un-guarded command is migrated --------------------------
R1="$(new_js_repo)"
set_cfg "$R1/.git/lcars/config.json" worktreeSetupCommand "$LEGACY"
run_update "$R1"
GOT1="$(cfg_get "$R1/.git/lcars/config.json" worktreeSetupCommand)"

check "1a. legacy command is rewritten (no longer the un-guarded form)" \
  '[ "$GOT1" != "$LEGACY" ]'
check "1b. the migrated command compares lockfiles" \
  'printf %s "$GOT1" | grep -q "cmp -s package-lock.json"'
check "1c. it still symlinks when they match (fast path kept)" \
  'printf %s "$GOT1" | grep -q "ln -snf"'
check "1d. it still falls back to a real install" \
  'printf %s "$GOT1" | grep -q "npm ci"'
check "1e. the migration is reported to the captain" \
  'grep -qi "worktree" "$R1/out.txt"'

# --- 2. idempotent: a guarded command is left alone ------------------------
R2="$(new_js_repo)"
BEFORE2="$(cfg_get "$R2/.git/lcars/config.json" worktreeSetupCommand)"
run_update "$R2"
AFTER2="$(cfg_get "$R2/.git/lcars/config.json" worktreeSetupCommand)"

check "2a. a freshly-seeded (already guarded) command is unchanged" \
  '[ "$BEFORE2" = "$AFTER2" ]'
check "2b. no migration is reported when nothing needed repair" \
  '! grep -qi "worktree setup.*migrat\|migrat.*worktree setup" "$R2/out.txt"'

# --- 3. a captain's custom command is NEVER touched ------------------------
CUSTOM='make bootstrap && ./scripts/link-deps.sh'
R3="$(new_js_repo)"
set_cfg "$R3/.git/lcars/config.json" worktreeSetupCommand "$CUSTOM"
run_update "$R3"

check "3. a hand-written command survives byte-for-byte" \
  '[ "$(cfg_get "$R3/.git/lcars/config.json" worktreeSetupCommand)" = "$CUSTOM" ]'

# --- 4. a non-JS repo with no setup command does not crash -----------------
R4="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$R4" && git init -q && git config user.email t@t && git config user.name t )
make_claude_stub "$R4/claude"; make_gh_stub "$R4/gh"
export GH_LOG="$R4/gh.log"; : >"$GH_LOG"; export GH_EXISTING="$R4/existing"; : >"$GH_EXISTING"
( cd "$R4" && LCARS_CLAUDE_BIN="$R4/claude" LCARS_GH_BIN="$R4/gh" bash "$INIT" >/dev/null 2>&1 )
run_update "$R4"; RC4=$?

check "4. a repo with no worktreeSetupCommand updates cleanly (exit 0)" \
  '[ "$RC4" -eq 0 ]'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
