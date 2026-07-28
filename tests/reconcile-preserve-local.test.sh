#!/usr/bin/env bash
#
# Tests that the reconcile re-entry NEVER destroys committed work
# (skill source: skills/lcars-run/run.sh — reconcile_gate / reconcile_sync_local_branch).
#
# WHY THIS EXISTS — a real data-loss incident
# ------------------------------------------
# BUG-077 made a reconcile RE-ENTRY reset the local mission branch to the remote
# PR head before re-merging, so a killed/retried reconcile could not leave the
# local tip diverged and jam the eventual push:
#
#     git branch -f "$BRANCH" "origin/$BRANCH"
#
# That is correct when the local-only commits are a dead attempt's merge commit.
# It is catastrophic when they are real work. Mission-log bug fixes are exactly
# that: a logged bug NEVER opens its own PR — its fix is cherry-picked onto the
# PARENT's branch and rides the parent's PR. Until the parent next pushes, those
# commits exist ONLY locally.
#
# Observed live (DX-Scorecard, 2026-07-28): three logged-bug fixes were built,
# gate-verified and cherry-picked onto the parent branch —
#
#     b75400b (bug 005)  ts 1785267868
#     a2509a8 (bug 006)  ts 1785268473
#     cddf9b4 (bug 007)  ts 1785269867
#     RESET -> 091fbb7   ts 1785269976     <- 109 seconds later
#
# — and the parent then re-entered reconcile (main was 8 commits ahead). The
# reset moved the branch back to the remote head, which was precisely the chain's
# base, and all three commits became unreachable in one command. The reconcile
# re-tested the PARENT's ticket, went green (the bug fixes' own tests had been
# discarded along with their code, so nothing was left to fail), and the PR
# merged carrying none of it. No error, anywhere.
#
# THE RULE THIS SUITE LOCKS: divergence is resolved by PUBLISHING local work, not
# by deleting it. If the local branch holds commits the remote has never seen,
# push them; if that push fails, leave the branch ALONE and say so loudly. Reset
# only when there is genuinely nothing to lose.
#
# PURE GIT FIXTURES: real repos, a real `origin`, no runner, no model, no network,
# ZERO tokens. Safe to run directly. Do NOT route through tests/run.sh.
#
# Usage: bash tests/reconcile-preserve-local.test.sh
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

sed -n '/^reconcile_unpushed_count() {/,/^}/p'      "$RUN_SH" >"$LIB"
sed -n '/^reconcile_unpushed_work_count() {/,/^}/p' "$RUN_SH" >>"$LIB"
sed -n '/^reconcile_sync_local_branch() {/,/^}/p'   "$RUN_SH" >>"$LIB"

# Stub the harness the extracted functions lean on.
GIT_BIN=git
EVENTS=""
emit_event() { EVENTS="$EVENTS$1 "; }   # type stage detail [data]
# shellcheck source=/dev/null
. "$LIB"

for fn in reconcile_unpushed_count reconcile_unpushed_work_count reconcile_sync_local_branch; do
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: could not extract $fn from $RUN_SH" >&2
    exit 1
  fi
done

# A repo with a real `origin` bare remote and a branch pushed to it.
# Echoes the working repo path. Leaves HEAD on the mission branch.
new_pair() { # name
  local n="$1" bare="$TMPROOT/$1.git" work="$TMPROOT/$1"
  git init -q --bare "$bare"
  git init -q "$work"
  (
    cd "$work"
    git config user.email t@t; git config user.name t
    echo base >f.txt; git add -A; git commit -qm base
    git branch -M main
    git remote add origin "$bare"
    git push -q origin main
    git checkout -qb mission
    git push -q origin mission
  ) >/dev/null 2>&1
  echo "$work"
}

echo "reconcile re-entry — never destroy committed work"

# --- 1. the counter -------------------------------------------------------
W1="$(new_pair count)"
cd "$W1"
check "1a. in sync => 0 unpushed" '[ "$(reconcile_unpushed_count mission)" = "0" ]'
echo one >>f.txt; git add -A; git commit -qm "lcars(m-1) t-001: ticket work" >/dev/null
echo two >>f.txt; git add -A; git commit -qm "a hand-made commit" >/dev/null
check "1b. two local-only commits => 2" '[ "$(reconcile_unpushed_count mission)" = "2" ]'
check "1c. an unknown branch is 0, not an error" '[ "$(reconcile_unpushed_count nope)" = "0" ]'
# The decision is driven by TICKET work, not by the raw count: a dead reconcile
# attempt leaves a merge / hand commit, which BUG-077 may still discard.
check "1d. only the LCARS ticket commit counts as work" \
  '[ "$(reconcile_unpushed_work_count mission)" = "1" ]'

# --- 2. THE INCIDENT: local-only work must SURVIVE ------------------------
W2="$(new_pair incident)"
cd "$W2"
# Three commits standing in for the three logged-bug fixes, cherry-picked onto
# the parent branch and never pushed (a logged bug opens no PR of its own).
REMOTE_HEAD="$(git rev-parse mission)"
for i in 1 2 3; do echo "bugfix $i" >>f.txt; git add -A; git commit -qm "lcars(bug-00$i) t-001: fix" >/dev/null; done
LOCAL_TIP="$(git rev-parse mission)"
EVENTS=""
reconcile_sync_local_branch mission >/dev/null 2>&1

check "2a. the branch was NOT reset to the remote head" \
  '[ "$(git rev-parse mission)" != "$REMOTE_HEAD" ]'
check "2b. all three commits are still reachable" \
  '[ "$(git rev-parse mission)" = "$LOCAL_TIP" ]'
check "2c. the work was PUBLISHED instead of discarded" \
  '[ "$(git rev-parse origin/mission)" = "$LOCAL_TIP" ]'
check "2d. divergence is genuinely resolved (local == remote)" \
  '[ "$(git rev-parse mission)" = "$(git rev-parse origin/mission)" ]'
check "2e. it reports what it did" \
  'printf %s "$EVENTS" | grep -q "reconcile_local_commits_pushed"'

# --- 3. nothing to lose => reset exactly as before (BUG-077 preserved) -----
# The dead-attempt case: the remote is AHEAD, local has nothing of its own.
W3="$(new_pair behind)"
cd "$W3"
# NOTE: leave `mission` NOT checked out. `git branch -f` cannot move a branch that
# a worktree holds, and LCARS deliberately parks no tree on the mission branch
# (S111 root-tree sovereignty) — so a held branch is a different case, covered by
# the reconcile_reset_skipped path rather than this one.
( git checkout -q main; echo upstream >>f.txt; git add -A; git commit -qm upstream
  git push -q origin main:mission; git fetch -q origin ) >/dev/null 2>&1
REMOTE3="$(git rev-parse origin/mission)"
check "3a. precondition: local has no unpushed commits" \
  '[ "$(reconcile_unpushed_count mission)" = "0" ]'
EVENTS=""
reconcile_sync_local_branch mission >/dev/null 2>&1
check "3b. with nothing to lose it still resets to the remote head" \
  '[ "$(git rev-parse mission)" = "$REMOTE3" ]'
# Trailing space: the stub records "<type> ", so this matches reconcile_reset
# EXACTLY and not the reconcile_reset_skipped of the refuse path.
check "3c. and reports the reset (BUG-077 behaviour intact)" \
  'printf %s "$EVENTS" | grep -q "reconcile_reset "'

# --- 4. a failing push must NOT fall back to discarding -------------------
# The whole point: when we cannot publish, the work still must not be destroyed.
W4="$(new_pair pushfail)"
cd "$W4"
REMOTE4="$(git rev-parse mission)"
echo precious >>f.txt; git add -A; git commit -qm "lcars(bug-009) t-001: precious verified work" >/dev/null
TIP4="$(git rev-parse mission)"
git remote set-url origin "$TMPROOT/definitely-not-a-repo"   # make the push fail
EVENTS=""
reconcile_sync_local_branch mission >/dev/null 2>&1
check "4a. a failed push leaves the commits intact" \
  '[ "$(git rev-parse mission)" = "$TIP4" ]'
check "4b. it did NOT silently reset to the old remote head" \
  '[ "$(git rev-parse mission)" != "$REMOTE4" ]'
check "4c. it says so loudly rather than failing silently" \
  'printf %s "$EVENTS" | grep -q "reconcile_reset_skipped"'

# --- 4b. BUG-077 IS PRESERVED: a dead attempt is still discarded -----------
# The case BUG-077 was written for. Reconcile builds its attempt with
# `git merge --no-edit`, so a killed retry leaves a merge / hand commit with no
# ticket signature. That is genuinely disposable and must still be reset away,
# or this fix would trade one defect for another (a jammed, un-mergeable PR).
W5="$(new_pair deadattempt)"
cd "$W5"
REMOTE5="$(git rev-parse mission)"
git checkout -q main; echo up >>f.txt; git add -A; git commit -qm upstream >/dev/null
git checkout -q mission
git merge -q --no-edit main >/dev/null 2>&1     # the real artifact: a merge commit
git checkout -q main                            # don't hold the branch
check "4b-i. precondition: a local-only commit exists but is not ticket work" \
  '[ "$(reconcile_unpushed_count mission)" != "0" ] && [ "$(reconcile_unpushed_work_count mission)" = "0" ]'
EVENTS=""
reconcile_sync_local_branch mission >/dev/null 2>&1
check "4b-ii. the dead attempt IS discarded (BUG-077 intact)" \
  '[ "$(git rev-parse mission)" = "$REMOTE5" ]'
check "4b-iii. and it reports a reset, not a push" \
  'printf %s "$EVENTS" | grep -q "reconcile_reset "'

# --- 5. WIRING: reconcile_gate must consult this before any branch -f ------
cd "$REPO_ROOT"
G="$(grep -n '^reconcile_gate() {' "$RUN_SH" | cut -d: -f1)"
SYNC="$(awk -v s="$G" 'NR>s && /reconcile_sync_local_branch/ {print NR; exit}' "$RUN_SH")"
RESET="$(awk -v s="$G" 'NR>s && /branch -f "\$BRANCH" "origin\/\$BRANCH"/ {print NR; exit}' "$RUN_SH")"
check "5a. reconcile_gate delegates to reconcile_sync_local_branch" \
  '[ -n "$SYNC" ]'
check "5b. no raw unguarded branch -f survives in reconcile_gate" \
  '[ -z "$RESET" ] || { [ -n "$SYNC" ] && [ "$SYNC" -lt "$RESET" ]; }'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
