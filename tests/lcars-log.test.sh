#!/usr/bin/env bash
#
# Tests for `lcars log` (skill source: skills/lcars-log/log.sh).
#
# `lcars log` has two halves. The conversational half (parse free-form input
# into N distinct bugs, resolve which active Mission they belong to) is driven
# by Claude per SKILL.md and produces one well-formed bug PRD per bug on disk,
# plus the resolved parent selector. The mechanical half — fast-tracking a
# Mission per bug at the Plan stage and linking each to the parent — lives in
# log.sh so it can be exercised directly. These tests drive that script,
# covering the six behaviours from the build order:
#   1. Two bug PRDs in one invocation -> two separate linked Missions
#   2. state.json carries parentMission (the resolved parent's id)
#   3. Initial stage is "plan" (Align/Research/Validate are skipped)
#   4. GitHub issues get lcars:plan,lcars:bug,lcars:linked
#   5. No parent selector -> refuses and lists the active Missions to pick from
#   6. Multiple bugs link to the SAME parent Mission
#
# The script takes its dependencies via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary    (default: gh)
#   LCARS_GIT_BIN  - the `git` binary   (default: git)
#   LCARS_DATE     - the YYYYMMDD used in the mission ID (default: today, UTC)
#
# Usage: bash tests/lcars-log.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_LOG_SCRIPT:-$REPO_ROOT/skills/lcars-log/log.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- stubs ----------------------------------------------------------------
# A fake `gh` that records every invocation and, on `issue create`, prints the
# URL of a new issue. The number climbs per call (45, 46, 47, …) so multiple
# bugs in one run get distinct issue numbers, the way real gh does.
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  n_file="${GH_LOG}.n"
  n="$(cat "$n_file" 2>/dev/null || echo 44)"
  n=$((n + 1))
  echo "$n" >"$n_file"
  echo "https://github.com/owner/repo/issues/$n"
  exit 0
fi
exit 0
EOF
  chmod +x "$p"
}

# An isolated git repo with .git/lcars/ scaffolded and one parent Mission
# already filed: a *feature* sitting at "implement" (issue #42, "Add
# gamification"), i.e. an active, pre-merge Mission a bug can be logged against.
new_repo_with_parent() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "created": "2026-05-30T00:00:00Z" }
EOF
  local p="$repo/.git/lcars/missions/lcars-20260530-001"
  mkdir -p "$p"
  cat >"$p/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "implement",
  "created": "2026-05-30T00:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main"
}
EOF
  echo "$repo"
}

# Write a well-formed bug PRD (same required sections as `lcars file` expects,
# Type: bug) to $1, titled by $2 and described by $3.
write_bug_prd() {
  cat >"$1" <<EOF
# Mission: $2

**Type:** bug
**Goal:** $3
**Acceptance Criteria:**
- The described defect no longer reproduces
**Out of Scope:**
- Unrelated refactors
**Constraints:**
- Minimal change; no new dependencies
EOF
}

# ==========================================================================
echo "lcars log"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: two bug PRDs in one invocation -> two linked Missions -----
repo="$(new_repo_with_parent)"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug1="$repo/bug1.md"; write_bug_prd "$bug1" "XP not awarded for video completions" "XP should be awarded when a video is marked complete, not only on quizzes."
bug2="$repo/bug2.md"; write_bug_prd "$bug2" "Leaderboard flicker on first load" "The leaderboard should not visibly flicker before its data arrives."
rc1=0
(
  cd "$repo"
  LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug1" --prd "$bug2" >out.txt 2>&1
) || rc1=$?
check "1. exits zero on a clean two-bug log" "[ '$rc1' -eq 0 ]"
check "1. mints the first bug mission lcars-20260530-002" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-002' ]"
check "1. mints the second bug mission lcars-20260530-003" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-003' ]"
check "1. each bug mission has a prd.md" \
  "[ -f '$repo/.git/lcars/missions/lcars-20260530-002/prd.md' ] && [ -f '$repo/.git/lcars/missions/lcars-20260530-003/prd.md' ]"
# Bugs skip Validate, but Plan still needs validated-plan.md — log.sh writes it
# so `lcars run <id>` is immediately runnable from Plan.
check "1. each bug mission has a validated-plan.md (runnable from Plan)" \
  "[ -f '$repo/.git/lcars/missions/lcars-20260530-002/validated-plan.md' ] && [ -f '$repo/.git/lcars/missions/lcars-20260530-003/validated-plan.md' ]"
check "1. summary reports 2 bug missions filed" \
  "grep -Eq '2 bug missions filed' '$repo/out.txt'"
check "1. summary lists both bug titles" \
  "grep -q 'XP not awarded for video completions' '$repo/out.txt' && grep -q 'Leaderboard flicker on first load' '$repo/out.txt'"

B2="$repo/.git/lcars/missions/lcars-20260530-002"
B3="$repo/.git/lcars/missions/lcars-20260530-003"

# --- Behaviour 2: state.json carries parentMission ------------------------
check "2. bug 1 state.json has parentMission = parent id" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B2/state.json'"
check "2. bug 1 state.json type is bug" \
  "grep -q '\"type\": *\"bug\"' '$B2/state.json'"
check "2. bug 1 state.json id matches its dir" \
  "grep -q '\"id\": *\"lcars-20260530-002\"' '$B2/state.json'"
check "2. bug 1 state.json records the bug title" \
  "grep -q 'XP not awarded for video completions' '$B2/state.json'"

# --- Behaviour 3: initial stage is plan (skips align/research/validate) ----
check "3. bug 1 starts at stage plan" \
  "grep -q '\"stage\": *\"plan\"' '$B2/state.json'"
check "3. bug 2 starts at stage plan" \
  "grep -q '\"stage\": *\"plan\"' '$B3/state.json'"
check "3. no research/ dir is created (Research is skipped)" \
  "[ ! -d '$B2/research' ] && [ ! -d '$B3/research' ]"

# --- Behaviour 4: GitHub issues with the right labels ----------------------
check "4. calls gh issue create" "grep -q 'issue create' '$repo/gh.log'"
check "4. passes lcars:plan,lcars:bug,lcars:linked labels" \
  "grep -q 'lcars:plan,lcars:bug,lcars:linked' '$repo/gh.log'"
check "4. tags each child bug Mission lcars:mission (role)" \
  "grep -q 'lcars:plan,lcars:bug,lcars:linked,lcars:mission' '$repo/gh.log'"
check "4. never tags a child bug Mission lcars:ticket" \
  "! grep -q 'lcars:ticket' '$repo/gh.log'"
check "4. creates two issues (one per bug)" \
  "[ \"\$(grep -c 'issue create' '$repo/gh.log')\" -eq 2 ]"
check "4. saves an issue number into bug 1 state.json" \
  "grep -Eq '\"githubIssue\": *[0-9]+' '$B2/state.json'"
check "4. summary references the parent issue #42" \
  "grep -q '#42' '$repo/out.txt'"
check "4. summary names the parent mission title" \
  "grep -q 'Add gamification' '$repo/out.txt'"

# --- Behaviour 5: no parent -> refuse and list active missions -------------
repo5="$(new_repo_with_parent)"
make_gh_stub "$repo5/gh"
export GH_LOG="$repo5/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug5="$repo5/bug.md"; write_bug_prd "$bug5" "Some bug" "Something is broken."
rc5=0
(
  cd "$repo5"
  LCARS_GH_BIN="$repo5/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$bug5" >out5.txt 2>&1
) || rc5=$?
check "5. refuses (non-zero) when no parent is given" "[ '$rc5' -ne 0 ]"
check "5. lists the active mission to pick from" \
  "grep -q 'lcars-20260530-001' '$repo5/out5.txt'"
check "5. mentions the active mission's title" \
  "grep -q 'Add gamification' '$repo5/out5.txt'"
check "5. files no bug mission without a parent" \
  "[ ! -d '$repo5/.git/lcars/missions/lcars-20260530-002' ]"

# --- Behaviour 6: multiple bugs link to the SAME parent --------------------
check "6. both bugs share the same parentMission" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B2/state.json' && grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B3/state.json'"

# parent resolvable by GitHub issue number too (not just mission id)
repo6="$(new_repo_with_parent)"
make_gh_stub "$repo6/gh"
export GH_LOG="$repo6/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug6="$repo6/bug.md"; write_bug_prd "$bug6" "Bug by issue number" "Linked via the parent's GitHub issue number."
rc6=0
(
  cd "$repo6"
  LCARS_GH_BIN="$repo6/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent 42 --prd "$bug6" >out6.txt 2>&1
) || rc6=$?
check "6. resolves the parent by GitHub issue number" "[ '$rc6' -eq 0 ]"
check "6. links the issue-number bug to the parent mission id" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$repo6/.git/lcars/missions/lcars-20260530-002/state.json'"

# refuses to link against a done (merged) mission
repo7="$(new_repo_with_parent)"
make_gh_stub "$repo7/gh"
export GH_LOG="$repo7/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# flip the parent to done
sed 's/"stage": "implement"/"stage": "done"/' \
  "$repo7/.git/lcars/missions/lcars-20260530-001/state.json" >"$repo7/tmp.json"
mv "$repo7/tmp.json" "$repo7/.git/lcars/missions/lcars-20260530-001/state.json"
bug7="$repo7/bug.md"; write_bug_prd "$bug7" "Late bug" "Filed against a merged mission."
rc7=0
(
  cd "$repo7"
  LCARS_GH_BIN="$repo7/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug7" >out7.txt 2>&1
) || rc7=$?
check "6. refuses to link to a done (merged) mission" "[ '$rc7' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars log: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
