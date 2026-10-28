#!/usr/bin/env bash
# S336: real git at the base-advance and self-heal drift-guard seams.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); printf '  ok %s\n' "$*"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; fi
}

. "$ROOT/skills/lcars-init/lcars-common.sh"
# Load the real guard and landing lock, without starting the driver.
for fn in selfheal_base_drift_blocks selfheal_merge_base merge_base_in_worktree \
          replay_lock_path acquire_replay_lock release_replay_lock; do
  sed -n "/^$fn() {/,/^}/p" "$RUN" >>"$TMP/guard.sh"
done
. "$TMP/guard.sh"
drive_load_base_lib() { :; }
pid_alive() { kill -0 "${1:-0}" 2>/dev/null; }
GIT_BIN=git
REPLAY_LOCK_DIR=""
REPLAY_LOCK_STALE_SECS=300

rig() {
  REPO_ROOT="$TMP/$1"; mkdir -p "$REPO_ROOT"
  cd "$REPO_ROOT" || exit 1
  git init -q -b main
  git config user.name test; git config user.email test@example.com
  printf 'original\n' >shared
  git add shared; git commit -qm base
  git checkout -qb lcars/test
  printf 'mission\n' >mission
  git add mission; git commit -qm mission
  OLD="$(git rev-parse HEAD)"
  git checkout -q main
  printf 'base\n' >incoming
  git add incoming; git commit -qm incoming
  MISSION_DIR="$REPO_ROOT/.git/lcars/missions/test"
  mkdir -p "$MISSION_DIR"
}
blocked() { selfheal_base_drift_blocks lcars/test main; }
proceeds() { ! blocked; }
unchanged() { [ "$(git rev-parse lcars/test)" = "$OLD" ]; }
preserved() { git merge-base --is-ancestor "$OLD" lcars/test; }
contains_base() { git merge-base --is-ancestor main lcars/test; }

rig control
lcars_base_advance_mission_branch lcars/test main
check test "$LCARS_MB_MOVE" = refused
check unchanged
check test -n "$LCARS_MB_REASON"
check proceeds
check preserved
check contains_base
check test "$(git rev-list --count --merges lcars/test)" = 1
check test "$(git symbolic-ref --short HEAD)" = main
check test -z "$(git status --porcelain)"

rig conflict
git checkout -q lcars/test
printf 'mission edit\n' >shared; git add shared; git commit -qm mission-edit
OLD="$(git rev-parse HEAD)"
git checkout -q main
printf 'base edit\n' >shared; git add shared; git commit -qm base-edit
check blocked
check unchanged
check test -n "$SELFHEAL_DRIFT_REASON"
check grep -qi conflict <<<"$SELFHEAL_DRIFT_REASON"
check test "$(git worktree list --porcelain | grep -c '^worktree ')" = 1
check test -z "$(git status --porcelain)"

rig dirty
printf 'captain\n' >>shared
check blocked
check unchanged
check grep -qi dirty <<<"$SELFHEAL_DRIFT_REASON"
check grep -q captain shared

for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  rig "op-$op"
  marker="$(git rev-parse --git-path "$op")"
  case "$op" in rebase-*) mkdir -p "$marker" ;; *) printf '%s\n' "$OLD" >"$marker" ;; esac
  check blocked
  check unchanged
  check test -e "$marker"
done

rig actual-cherry-pick
git checkout -q lcars/test
printf 'mission edit\n' >shared; git add shared; git commit -qm mission-edit
OLD="$(git rev-parse HEAD)"
git checkout -q main
printf 'base edit\n' >shared; git add shared; git commit -qm base-edit
if git cherry-pick lcars/test >"$TMP/cherry-pick.log" 2>&1; then
  FAIL=$((FAIL+1)); printf '  FAIL real cherry-pick did not conflict\n'
else
  check test -e "$(git rev-parse --git-path CHERRY_PICK_HEAD)"
fi
status_before="$(git status --porcelain)"
cp shared "$TMP/conflicted-shared"
check blocked
check unchanged
check test "$(git status --porcelain)" = "$status_before"
check cmp shared "$TMP/conflicted-shared"

rig held
git worktree add -q "$TMP/holder" lcars/test
check blocked
check unchanged
check grep -qi 'checked out' <<<"$SELFHEAL_DRIFT_REASON"
git worktree remove "$TMP/holder"

rig published
git init -q --bare "$TMP/published.git"
git remote add origin "$TMP/published.git"
git push -q origin main lcars/test
published="$(git rev-parse refs/remotes/origin/lcars/test)"
git checkout -q lcars/test
printf 'linked bug fix\n' >bug
git add bug; git commit -qm linked-bug-fix
OLD="$(git rev-parse HEAD)"
git checkout -q main
check proceeds
check preserved
check contains_base
check test "$(git rev-parse refs/remotes/origin/lcars/test)" = "$published"
check git merge-base --is-ancestor "$published" lcars/test
check test "$(git show lcars/test:bug)" = 'linked bug fix'

rig concurrent
RACE_SHA="$(printf 'concurrent linked fix\n' | git commit-tree "$(git rev-parse 'lcars/test^{tree}')" -p "$OLD")"
export RACE_SHA
cat >"$TMP/race-git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = update-ref ]; then
  git update-ref refs/heads/lcars/test "$RACE_SHA" || exit 1
fi
exec git "$@"
SH
chmod +x "$TMP/race-git"
GIT_BIN="$TMP/race-git"
check blocked
check test "$(git rev-parse lcars/test)" = "$RACE_SHA"
check preserved
check grep -qi 'tip changed' <<<"$SELFHEAL_DRIFT_REASON"
check test "$(git worktree list --porcelain | grep -c '^worktree ')" = 1
GIT_BIN=git

rig level
git branch level lcars/test
before="$(git rev-parse lcars/test)"
output="$(selfheal_base_drift_blocks lcars/test level)"; rc=$?
check test "$rc" = 1
check test -z "$output"
check test "$(git rev-parse lcars/test)" = "$before"
if [ -n "${LCARS_REANCHOR_BASELINE:-}" ]; then
  sed -n '/^selfheal_base_drift_blocks() {/,/^}/p' "$LCARS_REANCHOR_BASELINE" >"$TMP/parent-guard.sh"
  (
    . "$TMP/parent-guard.sh"
    selfheal_base_drift_blocks lcars/test level >"$TMP/parent-output" 2>&1
    printf '%s\n' "$?" >"$TMP/parent-status"
  )
  selfheal_base_drift_blocks lcars/test level >"$TMP/tip-output" 2>&1
  printf '%s\n' "$?" >"$TMP/tip-status"
  check cmp "$TMP/parent-output" "$TMP/tip-output"
  check cmp "$TMP/parent-status" "$TMP/tip-status"
fi

rig fast-forward
git branch empty "$(git rev-parse 'lcars/test^')"
output="$(selfheal_base_drift_blocks empty main)"; rc=$?
check test "$rc" = 1
check test -z "$output"
check test "$(git rev-parse empty)" = "$(git rev-parse main)"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
