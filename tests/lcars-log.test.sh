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

# --- Behaviour 7: native sub-issue nesting under the parent ----------------
# A logged bug Mission must be nested as a NATIVE GitHub sub-issue of its
# parent's issue (the same way Schedule nests ticket sub-issues), routed
# through the SAME host adapter Schedule uses (`link-subissue <parent> <child>`),
# in addition to the lcars:linked label. Stub the adapter to record its argv.
make_adapter_stub() { # path log [exit_code]
  local p="$1" log="$2" code="${3:-0}"
  cat >"$p" <<EOF
#!/usr/bin/env bash
echo "adapter \$*" >>"$log"
exit $code
EOF
  chmod +x "$p"
}

repo8="$(new_repo_with_parent)"
make_gh_stub "$repo8/gh"
make_adapter_stub "$repo8/adapter" "$repo8/adapter.log"
export GH_LOG="$repo8/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"; : >"$repo8/adapter.log"
bug8a="$repo8/bug1.md"; write_bug_prd "$bug8a" "Nested bug one" "First nested bug."
bug8b="$repo8/bug2.md"; write_bug_prd "$bug8b" "Nested bug two" "Second nested bug."
rc8=0
(
  cd "$repo8"
  LCARS_GH_BIN="$repo8/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_HOST_ADAPTER="$repo8/adapter" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug8a" --prd "$bug8b" >out8.txt 2>&1
) || rc8=$?
check "7. exits zero when nesting via the host adapter" "[ '$rc8' -eq 0 ]"
check "7. invokes the host adapter's link-subissue op" \
  "grep -q 'adapter link-subissue' '$repo8/adapter.log'"
check "7. nests bug 1 (#1) under the parent issue #42" \
  "grep -q 'adapter link-subissue 42 1' '$repo8/adapter.log'"
check "7. nests bug 2 (#2) under the parent issue #42" \
  "grep -q 'adapter link-subissue 42 2' '$repo8/adapter.log'"
check "7. one link-subissue call per bug issue created" \
  "[ \"\$(grep -c 'link-subissue' '$repo8/adapter.log')\" -eq 2 ]"

# --- Behaviour 8: linkage by label + state.json is NOT lost (regression) ---
# Belt and braces: even with native nesting, the lcars:linked label and the
# parentIssue/parentMission state.json records must still be written.
B8="$repo8/.git/lcars/missions/lcars-20260530-002"
check "8. still applies the lcars:linked label" \
  "grep -q 'lcars:plan,lcars:bug,lcars:linked' '$repo8/gh.log'"
check "8. still records parentMission in state.json" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B8/state.json'"
check "8. still records parentIssue (#42) in state.json" \
  "grep -q '\"parentIssue\": *42' '$B8/state.json'"

# --- Behaviour 9: nesting is best-effort — never hard-fails lcars log -------
# If the host adapter (or gh) is unavailable or the link call returns non-zero,
# the Mission is STILL filed locally (state.json + prd.md) and lcars log exits 0.
repo9="$(new_repo_with_parent)"
make_gh_stub "$repo9/gh"
make_adapter_stub "$repo9/adapter" "$repo9/adapter.log" 1   # adapter fails
export GH_LOG="$repo9/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"; : >"$repo9/adapter.log"
bug9="$repo9/bug.md"; write_bug_prd "$bug9" "Best-effort bug" "Link fails but mission files."
rc9=0
(
  cd "$repo9"
  LCARS_GH_BIN="$repo9/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_HOST_ADAPTER="$repo9/adapter" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug9" >out9.txt 2>&1
) || rc9=$?
B9="$repo9/.git/lcars/missions/lcars-20260530-002"
check "9. exits zero even when the link call fails" "[ '$rc9' -eq 0 ]"
check "9. still attempted the link-subissue call" \
  "grep -q 'adapter link-subissue 42' '$repo9/adapter.log'"
check "9. still files the Mission's state.json" "[ -f '$B9/state.json' ]"
check "9. still files the Mission's prd.md" "[ -f '$B9/prd.md' ]"

# adapter entirely absent (path does not exist) -> still files + exits 0
repo10="$(new_repo_with_parent)"
make_gh_stub "$repo10/gh"
export GH_LOG="$repo10/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug10="$repo10/bug.md"; write_bug_prd "$bug10" "No adapter bug" "Adapter missing entirely."
rc10=0
(
  cd "$repo10"
  LCARS_GH_BIN="$repo10/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_HOST_ADAPTER="$repo10/does-not-exist-adapter" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug10" >out10.txt 2>&1
) || rc10=$?
check "9. exits zero when the host adapter is missing entirely" "[ '$rc10' -eq 0 ]"
check "9. still files the Mission when the adapter is missing" \
  "[ -f '$repo10/.git/lcars/missions/lcars-20260530-002/state.json' ]"

# --- Behaviour 10: no native nesting when the parent has no issue number ----
# A parent resolvable only locally (githubIssue null) cannot be nested; the
# link call must be skipped (no self-nest / no bogus call) and lcars log still
# files the bug and exits 0.
repo11="$(new_repo_with_parent)"
make_gh_stub "$repo11/gh"
make_adapter_stub "$repo11/adapter" "$repo11/adapter.log"
export GH_LOG="$repo11/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"; : >"$repo11/adapter.log"
# strip the parent's githubIssue (make it local-only)
sed 's/"githubIssue": 42,/"githubIssue": null,/' \
  "$repo11/.git/lcars/missions/lcars-20260530-001/state.json" >"$repo11/tmp.json"
mv "$repo11/tmp.json" "$repo11/.git/lcars/missions/lcars-20260530-001/state.json"
bug11="$repo11/bug.md"; write_bug_prd "$bug11" "Local parent bug" "Parent has no issue."
rc11=0
(
  cd "$repo11"
  LCARS_GH_BIN="$repo11/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_HOST_ADAPTER="$repo11/adapter" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug11" >out11.txt 2>&1
) || rc11=$?
check "10. exits zero when the parent has no issue number" "[ '$rc11' -eq 0 ]"
check "10. skips link-subissue when the parent issue is unknown" \
  "[ ! -s '$repo11/adapter.log' ]"

# --- Behaviour 11: pre-merge parent -> commit onto the parent's branch ------
# BUG-011: when the parent Mission is still pre-merge (its lcars/<parent> branch
# ref still exists locally), a logged bug must NOT mint its own lcars/<bug>
# branch. It records the PARENT's branch as its working branch so Implement
# accumulates the fix as commits on that one branch (no stacked bug->parent PRs).
repo12="$(new_repo_with_parent)"
make_gh_stub "$repo12/gh"
export GH_LOG="$repo12/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# the parent is pre-merge: its branch ref exists locally.
( cd "$repo12" && git branch "lcars/lcars-20260530-001" >/dev/null 2>&1 )
bug12="$repo12/bug.md"; write_bug_prd "$bug12" "Pre-merge bug" "Fix accumulates on the parent branch."
rc12=0
(
  cd "$repo12"
  LCARS_GH_BIN="$repo12/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug12" >out12.txt 2>&1
) || rc12=$?
B12="$repo12/.git/lcars/missions/lcars-20260530-002"
check "11. exits zero logging against a pre-merge parent" "[ '$rc12' -eq 0 ]"
check "11. bug records the PARENT's branch as its working branch" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-001\"' '$B12/state.json'"
check "11. bug does NOT record its own lcars/<bug-id> branch" \
  "! grep -q '\"branch\": *\"lcars/lcars-20260530-002\"' '$B12/state.json'"
check "11. no lcars/<bug-id> branch ref is created (no stacked branch)" \
  "( cd '$repo12' && ! git show-ref --verify --quiet refs/heads/lcars/lcars-20260530-002 )"

# --- Behaviour 12: merged parent -> bug keeps its own branch (regression) ---
# When the parent has NO live branch (already merged/squashed away), the bug
# still gets and records its own lcars/<bug-id> branch, exactly as before.
repo13="$(new_repo_with_parent)"
make_gh_stub "$repo13/gh"
export GH_LOG="$repo13/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# NB: new_repo_with_parent does NOT create the parent branch ref -> "merged".
bug13="$repo13/bug.md"; write_bug_prd "$bug13" "Post-merge bug" "Parent already merged away."
rc13=0
(
  cd "$repo13"
  LCARS_GH_BIN="$repo13/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug13" >out13.txt 2>&1
) || rc13=$?
B13="$repo13/.git/lcars/missions/lcars-20260530-002"
check "12. exits zero logging against a merged parent" "[ '$rc13' -eq 0 ]"
check "12. bug records its OWN lcars/<bug-id> branch when parent is merged" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-002\"' '$B13/state.json'"
check "12. its own lcars/<bug-id> branch ref is created" \
  "( cd '$repo13' && git show-ref --verify --quiet refs/heads/lcars/lcars-20260530-002 )"

# --- Behaviour 13: child bug inherits the PARENT's engine (BUG-D) -----------
# When the parent ran on a chosen engine, the daemon threads it to `lcars log`
# as $LCARS_WORKER_BIN. Each child bug Mission must PERSIST that engine into its
# own state.json `workerBin` (mirroring file.sh), so the board shows it and the
# child `lcars run` runs on the parent engine instead of host-detecting claude.
repo14="$(new_repo_with_parent)"
make_gh_stub "$repo14/gh"
export GH_LOG="$repo14/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug14="$repo14/bug.md"; write_bug_prd "$bug14" "Engine-inheriting bug" "Child must run on the parent engine."
rc14=0
(
  cd "$repo14"
  LCARS_GH_BIN="$repo14/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_WORKER_BIN="copilot" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug14" >out14.txt 2>&1
) || rc14=$?
B14="$repo14/.git/lcars/missions/lcars-20260530-002"
check "13. exits zero logging with a parent engine set" "[ '$rc14' -eq 0 ]"
check "13. child state.json persists workerBin = the parent engine" \
  "grep -q '\"workerBin\": *\"copilot\"' '$B14/state.json'"
# state.json must remain valid JSON with the new field — python parses it.
check "13. child state.json stays valid JSON with workerBin" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B14/state.json'"

# --- Behaviour 14: no engine set -> NO workerBin field (no regression) ------
# Absent $LCARS_WORKER_BIN, the child omits the field entirely so host-detect
# stays in charge — exactly as before this change.
repo15="$(new_repo_with_parent)"
make_gh_stub "$repo15/gh"
export GH_LOG="$repo15/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug15="$repo15/bug.md"; write_bug_prd "$bug15" "No-engine bug" "No engine set; field omitted."
rc15=0
(
  cd "$repo15"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repo15/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug15" >out15.txt 2>&1
) || rc15=$?
B15="$repo15/.git/lcars/missions/lcars-20260530-002"
check "14. exits zero logging with no engine set" "[ '$rc15' -eq 0 ]"
check "14. child state.json OMITS workerBin when no engine is set" \
  "! grep -q 'workerBin' '$B15/state.json'"
check "14. child state.json (no workerBin) stays valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B15/state.json'"

# ==========================================================================
echo
printf 'lcars log: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
