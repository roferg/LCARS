#!/usr/bin/env bash
#
# Tests that a logged bug is never marked Done unless its fix is ACTUALLY on the
# parent branch (skill source: skills/lcars-resolve-logs/resolve-logs.sh).
#
# WHY THIS EXISTS
# ---------------
# fold_one_child flips a logged bug to Done on the stated premise that:
#
#   "its fix already lives on the parent branch … we only flip the stage +
#    board label here"
#
# It never checked. When the premise was false the bug was marked Done, its
# board column moved to lcars:done, and the fix simply did not exist — silently.
# That is exactly how three DX-Scorecard fixes were lost on 2026-07-28: a
# reconcile re-entry reset the parent branch and deleted them, and the fold
# cheerfully marked all three Done afterwards.
#
# The reconcile fix removes that particular cause. This closes the CLASS: any
# future cause (a force-push, a botched cherry-pick, a stray reset) now produces
# a loud refusal at the moment of the decision instead of a green board and a
# discovery days later.
#
# HOW PRESENCE IS DETECTED: a cherry-pick PRESERVES the commit subject, so a fix
# folded onto the parent branch appears in its log as "lcars(<bug-id>) …".
# Matching the recorded worktree sha would be WRONG — cmd_implement cherry-picks
# that commit onto the branch, so the branch carries a DIFFERENT sha with the
# same message (in the real incident the worktree sha was ec85424 while the
# branch carried b75400b).
#
# NO FALSE REFUSALS: a bug whose ticket recorded no commit at all (a green
# no-op ticket) has nothing to verify and folds exactly as before.
#
# Usage: bash tests/resolve-logs-fold-verify.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

TMPROOT="$(mktemp -d)"
LIB="$(mktemp)"
trap 'rm -rf "$TMPROOT" "$LIB"' EXIT

sed -n '/^child_recorded_a_commit() {/,/^}/p' "$SRC" >"$LIB"
sed -n '/^child_fix_on_branch() {/,/^}/p'     "$SRC" >>"$LIB"
sed -n '/^fold_one_child() {/,/^}/p'          "$SRC" >>"$LIB"

# --- the harness fold_one_child leans on -----------------------------------
GIT_BIN=git
GH_BIN=/nonexistent-gh          # label move is best-effort; skip it
json_str() { sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*([^,}\"[:space:]]*).*/\1/p" "$1" | head -1; }
# THE STATE WRITER IS THE REAL ONE (S207). This harness used to define its own
# `state_set_str` — a NINTH copy of the house field writer, living under tests/
# where item 5's acceptance grep could not see it. It builds the FIXTURE state
# files these assertions read, so a writer that can corrupt JSON here plants
# corrupt JSON into the test's own setup and the suite grades the wrong file.
# It now sources the ONE writer family, which is also what `fold_one_child`
# (extracted from resolve-logs.sh above) calls.
# shellcheck source=../skills/lcars-init/lcars-state.sh
. "$REPO_ROOT/skills/lcars-init/lcars-state.sh"
# shellcheck source=/dev/null
. "$LIB"

for fn in child_recorded_a_commit child_fix_on_branch fold_one_child; do
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: could not extract $fn from $SRC" >&2; exit 1
  fi
done

# Build a repo whose branch `parent` may or may not carry the bug's fix, plus a
# mission dir for the child. $1 = case name, $2 = "landed"|"lost"|"nocommit"
setup() {
  local name="$1" mode="$2"
  local root="$TMPROOT/$name"
  MISSIONS_DIR="$root/missions"
  mkdir -p "$MISSIONS_DIR/bug-001/tickets/t-001"
  ( cd "$root" && git init -q . && git config user.email t@t && git config user.name t
    echo base >f.txt && git add -A && git commit -qm base
    git checkout -qb parent
    if [ "$mode" = "landed" ]; then
      echo fix >>f.txt; git add -A
      git commit -qm "lcars(bug-001) t-001: the fix, cherry-picked onto the parent"
    fi ) >/dev/null 2>&1
  # ONE FIELD PER LINE — the shape every LCARS writer emits and the ONE state
  # writer (skills/lcars-init/lcars-state.sh) requires. The old fixture was a
  # single-line object no LCARS code path produces, which the writer correctly
  # refuses to edit: a fixture that is not the real file's shape grades the real
  # writer on a file it will never meet.
  cat >"$MISSIONS_DIR/bug-001/state.json" <<EOF
{
  "id": "bug-001",
  "type": "bug",
  "stage": "verify",
  "branch": "parent",
  "githubIssue": null
}
EOF
  # The recorded WORKTREE sha — deliberately never equal to what is on the branch.
  [ "$mode" = "nocommit" ] || echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    >"$MISSIONS_DIR/bug-001/tickets/t-001/.commit-sha"
  cd "$root"
}

stage_of() { json_str "$MISSIONS_DIR/bug-001/state.json" stage; }

echo "resolve-logs — never fold a bug to Done without its fix"

# --- 1. the presence predicate --------------------------------------------
setup pred landed
check "1a. a fix on the branch is detected by its preserved subject" \
  'child_fix_on_branch bug-001 parent'
setup pred2 lost
check "1b. a missing fix is reported absent" \
  '! child_fix_on_branch bug-001 parent'
check "1c. a recorded commit is noticed" 'child_recorded_a_commit bug-001'

# --- 2. THE INCIDENT: refuse to fold when the fix is gone ------------------
setup incident lost
fold_one_child bug-001 >/dev/null 2>&1; RC=$?
check "2a. fold REFUSES with a distinct code (2)" '[ "$RC" -eq 2 ]'
check "2b. the bug is NOT marked done" '[ "$(stage_of)" = "verify" ]'

# --- 3. the happy path still folds ----------------------------------------
setup happy landed
fold_one_child bug-001 >/dev/null 2>&1; RC=$?
check "3a. a landed fix folds normally (0)" '[ "$RC" -eq 0 ]'
check "3b. and the bug moves to done" '[ "$(stage_of)" = "done" ]'

# --- 4. no false refusal for a bug that produced no commit ----------------
setup noop nocommit
check "4a. precondition: nothing was committed" '! child_recorded_a_commit bug-001'
fold_one_child bug-001 >/dev/null 2>&1; RC=$?
check "4b. a no-op fix folds (nothing to verify)" '[ "$RC" -eq 0 ]'
check "4c. and reaches done" '[ "$(stage_of)" = "done" ]'

# --- 5. a child not at Verify is still just skipped (rc 1, unchanged) -----
setup skip landed
lcars_state_set_string "$MISSIONS_DIR/bug-001/state.json" stage plan
fold_one_child bug-001 >/dev/null 2>&1; RC=$?
check "5. a child mid-flight is skipped with rc 1, not refused" '[ "$RC" -eq 1 ]'

# --- 6. WIRING: both callers must handle the refusal ----------------------
cd "$REPO_ROOT"
# Assert the BEHAVIOUR (it inspects the refusal code and refuses), not the shape
# of the branch statement used to do it.
check "6a. the single-bug complete path inspects the refusal code" \
  'awk "/^cmd_complete_single/,/^}/" "$SRC" | grep -q "fold_rc\" -eq 2"'
check "6a2. and refuses rather than folding" \
  'awk "/^cmd_complete_single/,/^}/" "$SRC" | grep -q "REFUSING"'
check "6b. the bulk complete path handles it too" \
  'grep -q "fold_refused\|FOLD_REFUSED" "$SRC"'

# --- 7. END-TO-END through the REAL command -------------------------------
# Sections 1-6 drive the extracted function with a stubbed harness, and the
# wiring checks are source assertions. That is not the same as the command
# actually refusing, so this runs `resolve-logs complete` for real.
#
# NOTE the existing tests/lcars-resolve-logs.test.sh cannot cover this: its
# fixture's children record no .commit-sha, so the guard never fires there —
# which is exactly why the happy-path suite stayed green and proves nothing
# about the refusal.
e2e_repo() { # → repo path; child at verify WITH a commit, fix NOT on the branch
  local repo; repo="$(mktemp -d "$TMPROOT/e2e.XXXX")"
  (
    cd "$repo" && git init -q . && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
    git branch -M main
    # The parent's branch exists but carries NO lcars(child) commit — the exact
    # post-incident state: the fix was built, then wiped off the branch.
    git branch "lcars/lcars-20260601-001" main
  ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  printf '{ "model": "claude-sonnet", "projectName": "repo" }\n' >"$repo/.git/lcars/config.json"
  mkdir -p "$repo/.git/lcars/missions/lcars-20260601-001"
  cat >"$repo/.git/lcars/missions/lcars-20260601-001/state.json" <<'EOF'
{ "id": "lcars-20260601-001", "type": "feature", "title": "Parent", "stage": "verify",
  "githubIssue": 42, "branch": "lcars/lcars-20260601-001", "base": "main" }
EOF
  mkdir -p "$repo/.git/lcars/missions/lcars-20260601-002/tickets/t-001"
  # A logged bug rides the PARENT's branch (log.sh records it for a pre-merge child).
  cat >"$repo/.git/lcars/missions/lcars-20260601-002/state.json" <<'EOF'
{ "id": "lcars-20260601-002", "type": "bug", "title": "Logged bug", "stage": "verify",
  "githubIssue": 51, "parentMission": "lcars-20260601-001", "parentIssue": 42,
  "branch": "lcars/lcars-20260601-001", "base": "lcars/lcars-20260601-001" }
EOF
  echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    >"$repo/.git/lcars/missions/lcars-20260601-002/tickets/t-001/.commit-sha"
  for s in gh notify run worker; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/$s"; chmod +x "$repo/$s"
  done
  echo "$repo"
}

E2E="$(e2e_repo)"
e2e_rc=0
(
  cd "$E2E"
  LCARS_GH_BIN="$E2E/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$E2E/notify" \
  LCARS_RUN_SCRIPT="$E2E/run" LCARS_WORKER_BIN="$E2E/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SRC" complete --parent lcars-20260601-001 >out.txt 2>&1
) || e2e_rc=$?

check "7a. the real command exits NON-ZERO when a fix is missing" \
  '[ "$e2e_rc" -ne 0 ]'
check "7b. the bug is NOT marked done on disk" \
  '! grep -q "\"stage\": *\"done\"" "$E2E/.git/lcars/missions/lcars-20260601-002/state.json"'
check "7c. it stays at verify, recoverable" \
  'grep -q "\"stage\": *\"verify\"" "$E2E/.git/lcars/missions/lcars-20260601-002/state.json"'
check "7d. it says REFUSED and names the bug" \
  'grep -qi "refus" "$E2E/out.txt" && grep -q "lcars-20260601-002" "$E2E/out.txt"'
check "7e. it never labelled the issue done" \
  '! grep -q "lcars:done" "$E2E/out.txt"'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
