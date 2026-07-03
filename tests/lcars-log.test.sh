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

# S74: log.sh now runs the dynamic estimator on each child (best-effort, via
# $LCARS_RUN_BIN). The behaviours that aren't ABOUT the estimate must NOT spend a
# real worker — default $LCARS_RUN_BIN to a path that does NOT exist so the
# estimator step is skipped (log.sh guards on [ -f "$RUN_BIN" ]). The estimator
# behaviours below set their OWN LCARS_RUN_BIN at the real run.sh with a stub.
export LCARS_RUN_BIN="$TMPROOT/no-such-run.sh"

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
# A logged bug now ENTERS at Research (grounding mode) and walks the full pipeline,
# so log.sh no longer hand-writes a thin validated-plan.md — Validate produces the
# real one after grounding. It must NOT exist at file time.
check "1. no validated-plan.md at file time (Validate now produces it)" \
  "[ ! -f '$repo/.git/lcars/missions/lcars-20260530-002/validated-plan.md' ] && [ ! -f '$repo/.git/lcars/missions/lcars-20260530-003/validated-plan.md' ]"
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

# --- Behaviour 3: enters at Research via stage "align" + origin "log" -------
# A logged bug enters the pipeline at Research (grounding mode): stage="align"
# (the drive maps align + no feedback.md → Research, NO re-grill) plus an explicit
# origin="log" flag Research keys grounding-mode on. Align itself is still skipped.
check "3. bug 1 seeds stage align (drive → Research, no re-grill)" \
  "grep -q '\"stage\": *\"align\"' '$B2/state.json'"
check "3. bug 2 seeds stage align" \
  "grep -q '\"stage\": *\"align\"' '$B3/state.json'"
check "3. bug 1 carries origin=log (grounding-mode key)" \
  "grep -q '\"origin\": *\"log\"' '$B2/state.json'"
check "3. bug 2 carries origin=log" \
  "grep -q '\"origin\": *\"log\"' '$B3/state.json'"
check "3. no research/ dir at file time (grounding runs at Research, not now)" \
  "[ ! -d '$B2/research' ] && [ ! -d '$B3/research' ]"

# --- Behaviour 4: GitHub issues with the right labels ----------------------
check "4. calls gh issue create" "grep -q 'issue create' '$repo/gh.log'"
check "4. passes lcars:align,lcars:bug,lcars:linked labels" \
  "grep -q 'lcars:align,lcars:bug,lcars:linked' '$repo/gh.log'"
check "4. tags each child bug Mission lcars:mission (role)" \
  "grep -q 'lcars:align,lcars:bug,lcars:linked,lcars:mission' '$repo/gh.log'"
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
  "grep -q 'lcars:align,lcars:bug,lcars:linked' '$repo8/gh.log'"
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

# --- Behaviour 15: each logged bug gets a dynamic ESTIMATE (S74) -------------
# A logged bug is just a Mission whose estimate is computed from its bug PRD. It
# must get the SAME dynamic estimator scoring a top-level Mission gets (cost +
# reasoning/impl criticality + per-stage model map), persisted as a canonical,
# always-valid estimate.json on the child — exactly the way file.sh runs the
# estimator at the end of Align. We REUSE the real run.sh `estimate` entry point,
# with its cold worker swapped for a canned-estimate stub (same harness as
# tests/estimate.test.sh). log.sh must locate run.sh via $LCARS_RUN_BIN and run
# it best-effort (never block the log).
RUN_BIN_REAL="$REPO_ROOT/skills/lcars-run/run.sh"

# A canned-estimate stub CLI: ignores its prompt, writes $STUB_ESTIMATE (an
# estimate.json body) into its scratch output dir (LCARS_WORK_OUT). "NONE" ⇒ no
# file (emulates a worker that produced nothing).
make_estimator_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_ESTIMATE:-}" = "NONE" ]; then exit 0; fi
printf '%s\n' "${STUB_ESTIMATE:-}" >"$LCARS_WORK_OUT/estimate.json"
exit 0
EOF
  chmod +x "$1"
}

EST_TRIVIAL='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"deviations":[],"estimatorModel":"opus"}'

repo16="$(new_repo_with_parent)"
make_gh_stub "$repo16/gh"
make_estimator_stub "$repo16/estimator-stub"
# a repo-root CONTEXT.md so the estimator's context block never spawns a pack
printf '# Context\nTest repo.\n' >"$repo16/CONTEXT.md"
export GH_LOG="$repo16/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug16="$repo16/bug.md"; write_bug_prd "$bug16" "Estimated bug" "This bug must carry a dynamic estimate."
rc16=0
(
  cd "$repo16"
  env -u CLAUDECODE CLAUDECODE=1 \
    LCARS_GH_BIN="$repo16/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_RUN_BIN="$RUN_BIN_REAL" \
    LCARS_WORKER_BIN="$repo16/estimator-stub" LCARS_WORKER_CLI=claude \
    STUB_ESTIMATE="$EST_TRIVIAL" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug16" >out16.txt 2>&1
) || rc16=$?
B16="$repo16/.git/lcars/missions/lcars-20260530-002"
check "15. exits zero filing a bug with the estimator wired" "[ '$rc16' -eq 0 ]"
check "15. the child bug carries an estimate.json" "[ -f '$B16/estimate.json' ]"
check "15. child estimate.json is canonical (schemaVersion 3)" \
  "grep -q '\"schemaVersion\": *3' '$B16/estimate.json'"
check "15. child estimate.json is valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B16/estimate.json'"
check "15. child estimate carries reasoningCriticality (enum)" \
  "grep -Eq '\"reasoningCriticality\": *\"(low|medium|high)\"' '$B16/estimate.json'"
check "15. child estimate carries implCriticality (enum)" \
  "grep -Eq '\"implCriticality\": *\"(low|medium|high)\"' '$B16/estimate.json'"
check "15. child estimate carries a per-stage models map" \
  "grep -q '\"models\"' '$B16/estimate.json' && grep -Eq '\"implement\": *\"(sonnet|opus)\"' '$B16/estimate.json'"
check "15. child estimate carries a computed cost block" \
  "grep -q '\"cost\"' '$B16/estimate.json'"
# D-verification: a logged bug now enters at align (stage="align"), so the
# estimator's bug fast-track fork (mtype=bug && mstage=plan) does NOT fire and the
# estimate now INCLUDES research + validate — the full pipeline it actually runs.
check "15. bug estimate now INCLUDES research (enters at align, full pipeline)" \
  "grep -Eq '\"research\": *\"(sonnet|opus)\"' '$B16/estimate.json'"
check "15. bug estimate now INCLUDES validate" \
  "grep -Eq '\"validate\": *\"(sonnet|opus)\"' '$B16/estimate.json'"

# --- Behaviour 16: a quote/newline rationale round-trips to valid JSON (S69) -
# The S69 escaping fix lives inside estimate_validate_and_write; it must still
# hold through the logged-bug path. A rationale bearing quotes + escaped newlines
# must produce a still-valid estimate.json on the child.
EST_QUOTED='{"schemaVersion":1,"reasoningCriticality":"medium","implCriticality":"high","models":{"research":"opus","validate":"opus","plan":"opus","planReview":"sonnet","implement":"opus","verify":"sonnet"},"rationale":"He said \"fix it\" — line one.\n\nLine two with a tab\tand a quote: \".","deviations":[],"estimatorModel":"opus"}'
repo17="$(new_repo_with_parent)"
make_gh_stub "$repo17/gh"
make_estimator_stub "$repo17/estimator-stub"
printf '# Context\nTest repo.\n' >"$repo17/CONTEXT.md"
export GH_LOG="$repo17/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug17="$repo17/bug.md"; write_bug_prd "$bug17" "Quoted rationale bug" "Rationale has quotes and newlines."
rc17=0
(
  cd "$repo17"
  env -u CLAUDECODE CLAUDECODE=1 \
    LCARS_GH_BIN="$repo17/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_RUN_BIN="$RUN_BIN_REAL" \
    LCARS_WORKER_BIN="$repo17/estimator-stub" LCARS_WORKER_CLI=claude \
    STUB_ESTIMATE="$EST_QUOTED" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug17" >out17.txt 2>&1
) || rc17=$?
B17="$repo17/.git/lcars/missions/lcars-20260530-002"
check "16. exits zero with a quote/newline rationale" "[ '$rc17' -eq 0 ]"
check "16. child estimate.json (quoted rationale) stays valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B17/estimate.json'"

# --- Behaviour 17: estimator best-effort — a missing/empty estimate never blocks
# When the worker produces NOTHING, the bug must STILL file (state.json + prd.md)
# and lcars log must exit 0 — mirroring file.sh's never-block degradation.
repo18="$(new_repo_with_parent)"
make_gh_stub "$repo18/gh"
make_estimator_stub "$repo18/estimator-stub"
printf '# Context\nTest repo.\n' >"$repo18/CONTEXT.md"
export GH_LOG="$repo18/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug18="$repo18/bug.md"; write_bug_prd "$bug18" "No-estimate bug" "Estimator produces nothing."
rc18=0
(
  cd "$repo18"
  env -u CLAUDECODE CLAUDECODE=1 \
    LCARS_GH_BIN="$repo18/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_RUN_BIN="$RUN_BIN_REAL" \
    LCARS_WORKER_BIN="$repo18/estimator-stub" LCARS_WORKER_CLI=claude \
    STUB_ESTIMATE="NONE" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug18" >out18.txt 2>&1
) || rc18=$?
B18="$repo18/.git/lcars/missions/lcars-20260530-002"
check "17. exits zero when the estimator produces nothing" "[ '$rc18' -eq 0 ]"
check "17. bug still filed (state.json) without an estimate" "[ -f '$B18/state.json' ]"
check "17. bug still filed (prd.md) without an estimate" "[ -f '$B18/prd.md' ]"
check "17. no estimate.json when the worker produced nothing" "[ ! -f '$B18/estimate.json' ]"

# --- Behaviour 18: a captain per-bug override persists into state.json (S74) --
# The captain steers the model in the Mission-Log review panel. We reuse the
# EXACT lever file.sh uses: --model-override "<scope>:<tier>" persisted into the
# child's state.json.modelOverride = { "scope": "...", "tier": "..." }, which
# run.sh's active_model_override picks up natively (no resolve-logs change).
repo19="$(new_repo_with_parent)"
make_gh_stub "$repo19/gh"
export GH_LOG="$repo19/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug19="$repo19/bug.md"; write_bug_prd "$bug19" "Overridden bug" "Captain steers the model to opus."
rc19=0
(
  cd "$repo19"
  LCARS_GH_BIN="$repo19/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_RUN_BIN="$repo19/no-run.sh" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug19" --model-override "all:opus" >out19.txt 2>&1
) || rc19=$?
B19="$repo19/.git/lcars/missions/lcars-20260530-002"
check "18. exits zero with a per-bug model override" "[ '$rc19' -eq 0 ]"
check "18. child state.json persists modelOverride.scope" \
  "grep -q '\"modelOverride\".*\"scope\": *\"all\"' '$B19/state.json'"
check "18. child state.json persists modelOverride.tier" \
  "grep -q '\"tier\": *\"opus\"' '$B19/state.json'"
check "18. child state.json (with override) stays valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B19/state.json'"

# --- Behaviour 19: per-PRD override pairing (S74) ---------------------------
# When multiple bugs are filed in one invocation, --model-override values pair
# positionally with --prd values, so each bug carries its OWN override (the
# Launch panel's per-card override). A bug with no paired override gets none.
repo20="$(new_repo_with_parent)"
make_gh_stub "$repo20/gh"
export GH_LOG="$repo20/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug20a="$repo20/b1.md"; write_bug_prd "$bug20a" "First override bug" "Opus me."
bug20b="$repo20/b2.md"; write_bug_prd "$bug20b" "Second default bug" "Leave me default."
rc20=0
(
  cd "$repo20"
  LCARS_GH_BIN="$repo20/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_RUN_BIN="$repo20/no-run.sh" \
    bash "$SCRIPT" --parent lcars-20260530-001 \
      --prd "$bug20a" --model-override "all:opus" \
      --prd "$bug20b" --model-override "" >out20.txt 2>&1
) || rc20=$?
B20A="$repo20/.git/lcars/missions/lcars-20260530-002"
B20B="$repo20/.git/lcars/missions/lcars-20260530-003"
check "19. exits zero with per-PRD overrides" "[ '$rc20' -eq 0 ]"
check "19. first bug carries its own override (all:opus)" \
  "grep -q '\"modelOverride\"' '$B20A/state.json' && grep -q '\"scope\": *\"all\"' '$B20A/state.json'"
check "19. second bug carries NO override" \
  "! grep -q 'modelOverride' '$B20B/state.json'"
check "19. both children stay valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B20A/state.json' && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B20B/state.json'"

# --- Behaviour 20: a malformed override is rejected BEFORE filing (S74) ------
# Mirrors file.sh: a bad --model-override stops the log with a non-zero exit and
# files nothing partial.
repo21="$(new_repo_with_parent)"
make_gh_stub "$repo21/gh"
export GH_LOG="$repo21/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug21="$repo21/bug.md"; write_bug_prd "$bug21" "Bad override bug" "Override is malformed."
rc21=0
(
  cd "$repo21"
  LCARS_GH_BIN="$repo21/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug21" --model-override "banana:opus" >out21.txt 2>&1
) || rc21=$?
check "20. refuses (non-zero) on a malformed override scope" "[ '$rc21' -ne 0 ]"
check "20. files no bug mission on a malformed override" \
  "[ ! -d '$repo21/.git/lcars/missions/lcars-20260530-002' ]"

# --- Behaviour 21: durable image attachments (--attach) (S92) ---------------
# `lcars log --attach <img>` (repeatable) copies each image into EVERY child
# bug's attachments/ dir under a stable name, references it by RELATIVE path in
# that bug's prd.md, and records it in state.json. With NO --attach nothing
# changes (no attachments/ dir, no prd.md section, no state.json key).

# 21a. two bugs + one --attach ⇒ EACH bug gets the staged image + refs.
repo22="$(new_repo_with_parent)"
make_gh_stub "$repo22/gh"
export GH_LOG="$repo22/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug22a="$repo22/b1.md"; write_bug_prd "$bug22a" "First bug" "First defect."
bug22b="$repo22/b2.md"; write_bug_prd "$bug22b" "Second bug" "Second defect."
img22="$repo22/shot.png"; printf 'LOGIMG-22' >"$img22"
rc22=0
(
  cd "$repo22"
  LCARS_GH_BIN="$repo22/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$img22" \
      --prd "$bug22a" --prd "$bug22b" >out22.txt 2>&1
) || rc22=$?
B22A="$repo22/.git/lcars/missions/lcars-20260530-002"
B22B="$repo22/.git/lcars/missions/lcars-20260530-003"
check "21a. log with --attach succeeds" "[ '$rc22' -eq 0 ]"
check "21a. first bug has attachments/attachment-01.png" \
  "[ -f '$B22A/attachments/attachment-01.png' ]"
check "21a. second bug has attachments/attachment-01.png" \
  "[ -f '$B22B/attachments/attachment-01.png' ]"
check "21a. first bug staged bytes match the source" \
  "[ \"\$(cat '$B22A/attachments/attachment-01.png')\" = 'LOGIMG-22' ]"
check "21a. first bug prd.md references the attachment (relative)" \
  "grep -q 'attachments/attachment-01.png' '$B22A/prd.md'"
check "21a. first bug prd.md has the Attached images section" \
  "grep -q '## Attached images' '$B22A/prd.md'"
check "21a. first bug state.json lists the attachment" \
  "grep -q '\"attachments\": *\\[ *\"attachments/attachment-01.png\"' '$B22A/state.json'"
check "21a. second bug state.json lists the attachment" \
  "grep -q 'attachment-01.png' '$B22B/state.json'"
check "21a. both children stay valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B22A/state.json' && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$B22B/state.json'"

# 21b. NO --attach ⇒ no attachments anywhere (regression).
repo23="$(new_repo_with_parent)"
make_gh_stub "$repo23/gh"
export GH_LOG="$repo23/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug23="$repo23/b.md"; write_bug_prd "$bug23" "No-attach bug" "No images."
(
  cd "$repo23"
  LCARS_GH_BIN="$repo23/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug23" >out23.txt 2>&1
)
B23="$repo23/.git/lcars/missions/lcars-20260530-002"
check "21b. no --attach ⇒ no attachments/ dir" "[ ! -d '$B23/attachments' ]"
check "21b. no --attach ⇒ no prd.md section" \
  "! grep -q '## Attached images' '$B23/prd.md'"
check "21b. no --attach ⇒ no state.json attachments key" \
  "! grep -q 'attachments' '$B23/state.json'"

# 21c. a missing --attach file is rejected before anything is filed.
repo24="$(new_repo_with_parent)"
make_gh_stub "$repo24/gh"
export GH_LOG="$repo24/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug24="$repo24/b.md"; write_bug_prd "$bug24" "Bad attach bug" "Missing image."
rc24=0
(
  cd "$repo24"
  LCARS_GH_BIN="$repo24/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$repo24/nope.png" --prd "$bug24" >out24.txt 2>&1
) || rc24=$?
check "21c. missing attachment ⇒ non-zero exit" "[ '$rc24' -ne 0 ]"
check "21c. missing attachment ⇒ no bug filed" \
  "[ ! -d '$repo24/.git/lcars/missions/lcars-20260530-002' ]"

# ==========================================================================
echo
printf 'lcars log: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
