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

# S128 — the precedence sentence a bug PRD must carry, READ OUT OF THE DAEMON
# (web/lcars_serve/actions.py `_HANDOFF_PRECEDENCE`), its authority. See the
# same note in tests/lcars-file.test.sh: byte-exact, no longer an independent
# copy that can go stale while the daemon is reworded (FL-011).
PRECEDENCE="$(cd "$REPO_ROOT/web" 2>/dev/null && python3 -c 'import sys; sys.path.insert(0, "."); from lcars_serve.actions import _HANDOFF_PRECEDENCE as p; sys.stdout.write(p)' 2>/dev/null)"

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

# S196 — `cloneId` PINS THE FINGERPRINT so this suite's expected ids stay
# literal. A bug child's id is now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the
# first 4 hex of the clone's own `cloneId` (a UUID4 minted on first use, so two
# clones of one repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning it makes <fp> the constant `c10e`.
#
# THE PARENT BELOW IS DELIBERATELY LEFT AT THE OLD, FINGERPRINT-LESS SHAPE.
# Every repo in the world holds ids like it, and `lcars log` must keep taking
# one as a parent and sequencing its children PAST it. That is the whole
# compatibility guarantee, exercised here for free on every check in this file.
# An isolated git repo with .git/lcars/ scaffolded and one parent Mission
# already filed: a *feature* sitting at "implement" (issue #42, "Add
# gamification"), i.e. an active, pre-merge Mission a bug can be logged against.
new_repo_with_parent() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "created": "2026-05-30T00:00:00Z" }
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
check "1. mints the first bug mission lcars-20260530-002-c10e" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-002-c10e' ]"
check "1. mints the second bug mission lcars-20260530-003-c10e" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-003-c10e' ]"
check "1. each bug mission has a prd.md" \
  "[ -f '$repo/.git/lcars/missions/lcars-20260530-002-c10e/prd.md' ] && [ -f '$repo/.git/lcars/missions/lcars-20260530-003-c10e/prd.md' ]"
# A logged bug now ENTERS at Research (grounding mode) and walks the full pipeline,
# so log.sh no longer hand-writes a thin validated-plan.md — Validate produces the
# real one after grounding. It must NOT exist at file time.
check "1. no validated-plan.md at file time (Validate now produces it)" \
  "[ ! -f '$repo/.git/lcars/missions/lcars-20260530-002-c10e/validated-plan.md' ] && [ ! -f '$repo/.git/lcars/missions/lcars-20260530-003-c10e/validated-plan.md' ]"
check "1. summary reports 2 bug missions filed" \
  "grep -Eq '2 bug missions filed' '$repo/out.txt'"
check "1. summary lists both bug titles" \
  "grep -q 'XP not awarded for video completions' '$repo/out.txt' && grep -q 'Leaderboard flicker on first load' '$repo/out.txt'"

B2="$repo/.git/lcars/missions/lcars-20260530-002-c10e"
B3="$repo/.git/lcars/missions/lcars-20260530-003-c10e"

# --- Behaviour 2: state.json carries parentMission ------------------------
check "2. bug 1 state.json has parentMission = parent id" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B2/state.json'"
check "2. bug 1 state.json type is bug" \
  "grep -q '\"type\": *\"bug\"' '$B2/state.json'"
check "2. bug 1 state.json id matches its dir" \
  "grep -q '\"id\": *\"lcars-20260530-002-c10e\"' '$B2/state.json'"
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
  "[ ! -d '$repo5/.git/lcars/missions/lcars-20260530-002-c10e' ]"

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
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$repo6/.git/lcars/missions/lcars-20260530-002-c10e/state.json'"

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
B8="$repo8/.git/lcars/missions/lcars-20260530-002-c10e"
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
B9="$repo9/.git/lcars/missions/lcars-20260530-002-c10e"
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
  "[ -f '$repo10/.git/lcars/missions/lcars-20260530-002-c10e/state.json' ]"

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
B12="$repo12/.git/lcars/missions/lcars-20260530-002-c10e"
check "11. exits zero logging against a pre-merge parent" "[ '$rc12' -eq 0 ]"
check "11. bug records the PARENT's branch as its working branch" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-001\"' '$B12/state.json'"
check "11. bug does NOT record its own lcars/<bug-id> branch" \
  "! grep -q '\"branch\": *\"lcars/lcars-20260530-002-c10e\"' '$B12/state.json'"
check "11. no lcars/<bug-id> branch ref is created (no stacked branch)" \
  "( cd '$repo12' && ! git show-ref --verify --quiet refs/heads/lcars/lcars-20260530-002-c10e )"

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
B13="$repo13/.git/lcars/missions/lcars-20260530-002-c10e"
check "12. exits zero logging against a merged parent" "[ '$rc13' -eq 0 ]"
check "12. bug records its OWN lcars/<bug-id> branch when parent is merged" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-002-c10e\"' '$B13/state.json'"
check "12. its own lcars/<bug-id> branch ref is created" \
  "( cd '$repo13' && git show-ref --verify --quiet refs/heads/lcars/lcars-20260530-002-c10e )"

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
B14="$repo14/.git/lcars/missions/lcars-20260530-002-c10e"
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
B15="$repo15/.git/lcars/missions/lcars-20260530-002-c10e"
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
B16="$repo16/.git/lcars/missions/lcars-20260530-002-c10e"
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
B17="$repo17/.git/lcars/missions/lcars-20260530-002-c10e"
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
B18="$repo18/.git/lcars/missions/lcars-20260530-002-c10e"
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
B19="$repo19/.git/lcars/missions/lcars-20260530-002-c10e"
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
B20A="$repo20/.git/lcars/missions/lcars-20260530-002-c10e"
B20B="$repo20/.git/lcars/missions/lcars-20260530-003-c10e"
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
  "[ ! -d '$repo21/.git/lcars/missions/lcars-20260530-002-c10e' ]"

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
B22A="$repo22/.git/lcars/missions/lcars-20260530-002-c10e"
B22B="$repo22/.git/lcars/missions/lcars-20260530-003-c10e"
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
B23="$repo23/.git/lcars/missions/lcars-20260530-002-c10e"
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
  "[ ! -d '$repo24/.git/lcars/missions/lcars-20260530-002-c10e' ]"

# 21d. FL-010 — `lcars log` is a THIRD home of the same sentence. A bug logged
# against a holodeck-born mission can carry the very mockup the parent was
# built from, and this bug's prd.md IS its GitHub issue body. The wording comes
# from the ONE shared rule (lcars_attach_prd_section in lcars-common.sh), so an
# HTML mockup is never called an image here either.
repo24b="$(new_repo_with_parent)"
make_gh_stub "$repo24b/gh"
export GH_LOG="$repo24b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug24b="$repo24b/b.md"; write_bug_prd "$bug24b" "Mockup bug" "Looks wrong."
mock24="$repo24b/mockup.html"; printf '<!doctype html>' >"$mock24"
rc24b=0
(
  cd "$repo24b"
  LCARS_GH_BIN="$repo24b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$mock24" --prd "$bug24b" >out24b.txt 2>&1
) || rc24b=$?
B24B="$repo24b/.git/lcars/missions/lcars-20260530-002-c10e"
check "21d. logging a bug with a mockup attachment succeeds" "[ '$rc24b' -eq 0 ]"
check "21d. bug prd.md does NOT call an HTML mockup an image" \
  "! grep -q '## Attached images' '$B24B/prd.md'"
check "21d. bug prd.md heading names what actually arrived" \
  "grep -q '## Attached files' '$B24B/prd.md'"
check "21d. bug prd.md declares the mockup LOOK AND FLOW only" \
  "grep -q 'LOOK AND FLOW' '$B24B/prd.md'"
check "21d. the daemon's precedence sentence is readable" "[ -n \"\$PRECEDENCE\" ]"
check "21d. bug prd.md carries the precedence rule VERBATIM" \
  "[ -n \"\$PRECEDENCE\" ] && grep -qF \"\$PRECEDENCE\" '$B24B/prd.md'"
check "21d. bug prd.md still lists it by RELATIVE path" \
  "grep -q '^- attachments/attachment-01.html\$' '$B24B/prd.md'"

# 21e. …and the IMAGE-ONLY wording is untouched, BYTE FOR BYTE (see 21a's
# fixture). A pasted screenshot's bug PRD must not move by one character.
IMG_SECTION_LOG="$(printf '\n## Attached images\n\n- attachments/attachment-01.png\n')"
GOT_SECTION_LOG="$(python3 - "$B22A/prd.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.index('\n## Attached')
sys.stdout.write(t[i:])
PY
)"
check "21e. image-only bug prd.md section is BYTE-IDENTICAL to the pre-S128 string" \
  "[ \"\$GOT_SECTION_LOG\" = \"\$IMG_SECTION_LOG\" ]"

# --- Behaviour 22: per-bug image routing via POSITIONAL --attach -------------
# `--attach` is now positional (mirroring --model-override): a global attach
# (before any --prd) applies to EVERY bug; a per-bug attach (after a --prd) is
# paired to THAT --prd only. A bug's final set = GLOBAL ∪ its-own, deduped.

# 22a. GLOBAL-only (before any --prd) ⇒ every bug gets it (legacy, byte-identical).
repo25="$(new_repo_with_parent)"
make_gh_stub "$repo25/gh"
export GH_LOG="$repo25/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug25a="$repo25/b1.md"; write_bug_prd "$bug25a" "Global bug one" "First."
bug25b="$repo25/b2.md"; write_bug_prd "$bug25b" "Global bug two" "Second."
imgG="$repo25/global.png"; printf 'GLOBAL' >"$imgG"
rc25=0
(
  cd "$repo25"
  LCARS_GH_BIN="$repo25/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$imgG" \
      --prd "$bug25a" --prd "$bug25b" >out25.txt 2>&1
) || rc25=$?
B25A="$repo25/.git/lcars/missions/lcars-20260530-002-c10e"
B25B="$repo25/.git/lcars/missions/lcars-20260530-003-c10e"
check "22a. global --attach succeeds" "[ '$rc25' -eq 0 ]"
check "22a. global image lands in BOTH bugs" \
  "[ \"\$(cat '$B25A/attachments/attachment-01.png')\" = 'GLOBAL' ] && [ \"\$(cat '$B25B/attachments/attachment-01.png')\" = 'GLOBAL' ]"

# 22b. PER-BUG attaches (after each --prd) route to THAT bug only.
repo26="$(new_repo_with_parent)"
make_gh_stub "$repo26/gh"
export GH_LOG="$repo26/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug26a="$repo26/b1.md"; write_bug_prd "$bug26a" "Per-bug one" "First."
bug26b="$repo26/b2.md"; write_bug_prd "$bug26b" "Per-bug two" "Second."
img1="$repo26/one.png"; printf 'IMG-ONE' >"$img1"
img2="$repo26/two.png"; printf 'IMG-TWO' >"$img2"
rc26=0
(
  cd "$repo26"
  LCARS_GH_BIN="$repo26/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 \
      --prd "$bug26a" --attach "$img1" \
      --prd "$bug26b" --attach "$img2" >out26.txt 2>&1
) || rc26=$?
B26A="$repo26/.git/lcars/missions/lcars-20260530-002-c10e"
B26B="$repo26/.git/lcars/missions/lcars-20260530-003-c10e"
check "22b. per-bug --attach succeeds" "[ '$rc26' -eq 0 ]"
check "22b. bug 1 gets ONLY its own image (IMG-ONE)" \
  "[ \"\$(cat '$B26A/attachments/attachment-01.png')\" = 'IMG-ONE' ] && [ ! -f '$B26A/attachments/attachment-02.png' ]"
check "22b. bug 2 gets ONLY its own image (IMG-TWO)" \
  "[ \"\$(cat '$B26B/attachments/attachment-01.png')\" = 'IMG-TWO' ] && [ ! -f '$B26B/attachments/attachment-02.png' ]"

# 22c. GLOBAL ∪ PER-BUG: a global orphan reaches every bug, plus each bug's own.
repo27="$(new_repo_with_parent)"
make_gh_stub "$repo27/gh"
export GH_LOG="$repo27/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug27a="$repo27/b1.md"; write_bug_prd "$bug27a" "Union one" "First."
bug27b="$repo27/b2.md"; write_bug_prd "$bug27b" "Union two" "Second."
imgOrphan="$repo27/orphan.png"; printf 'ORPHAN' >"$imgOrphan"
imgOwn="$repo27/own.png"; printf 'OWN' >"$imgOwn"
rc27=0
(
  cd "$repo27"
  LCARS_GH_BIN="$repo27/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$imgOrphan" \
      --prd "$bug27a" --attach "$imgOwn" \
      --prd "$bug27b" >out27.txt 2>&1
) || rc27=$?
B27A="$repo27/.git/lcars/missions/lcars-20260530-002-c10e"
B27B="$repo27/.git/lcars/missions/lcars-20260530-003-c10e"
check "22c. union --attach succeeds" "[ '$rc27' -eq 0 ]"
check "22c. bug 1 gets global orphan (01) AND its own (02)" \
  "[ \"\$(cat '$B27A/attachments/attachment-01.png')\" = 'ORPHAN' ] && [ \"\$(cat '$B27A/attachments/attachment-02.png')\" = 'OWN' ]"
check "22c. bug 2 gets ONLY the global orphan" \
  "[ \"\$(cat '$B27B/attachments/attachment-01.png')\" = 'ORPHAN' ] && [ ! -f '$B27B/attachments/attachment-02.png' ]"

# 22d. a bug with an empty per-bug set and NO globals gets NO attachments dir.
repo28="$(new_repo_with_parent)"
make_gh_stub "$repo28/gh"
export GH_LOG="$repo28/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug28a="$repo28/b1.md"; write_bug_prd "$bug28a" "Has image" "First."
bug28b="$repo28/b2.md"; write_bug_prd "$bug28b" "No image" "Second."
img28="$repo28/only.png"; printf 'ONLY-ONE' >"$img28"
rc28=0
(
  cd "$repo28"
  LCARS_GH_BIN="$repo28/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 \
      --prd "$bug28a" --attach "$img28" \
      --prd "$bug28b" >out28.txt 2>&1
) || rc28=$?
B28A="$repo28/.git/lcars/missions/lcars-20260530-002-c10e"
B28B="$repo28/.git/lcars/missions/lcars-20260530-003-c10e"
check "22d. bug with an assigned image has it" \
  "[ -f '$B28A/attachments/attachment-01.png' ]"
check "22d. bug with no image + no globals has NO attachments dir" \
  "[ ! -d '$B28B/attachments' ]"
check "22d. bug with no image has no state.json attachments key" \
  "! grep -q 'attachments' '$B28B/state.json'"

# --- Behaviour 23: base tracks the PARENT's branch, NOT the checkout ---------
# `lcars log` is ALWAYS the Mission-Log path: a logged bug fixes the delivered
# code of its PARENT Mission, so its `base` must be the PARENT's branch — not the
# incidental working-tree checkout. Filing bugs against a Claude parent (branch
# lcars/…-002) while the tree sits on the Copilot branch (lcars/…-001) must still
# base on the Claude branch. Here the parent's branch is a DISTINCT custom name
# (not lcars/<parent-id>) so we prove log.sh reads state.json.branch, and the tree
# is checked out on a different branch entirely.
repo29="$(new_repo_with_parent)"
make_gh_stub "$repo29/gh"
export GH_LOG="$repo29/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# give the parent a custom branch (distinct from lcars/<parent-id>), and DON'T
# create that ref, so the child mints its own branch while base still tracks it.
sed 's#"branch": "lcars/lcars-20260530-001"#"branch": "lcars/parent-custom"#' \
  "$repo29/.git/lcars/missions/lcars-20260530-001/state.json" >"$repo29/tmp.json"
mv "$repo29/tmp.json" "$repo29/.git/lcars/missions/lcars-20260530-001/state.json"
# check the tree out on a DIFFERENT branch than the parent's.
( cd "$repo29" && git checkout -q -b some-other-branch )
bug29="$repo29/bug.md"; write_bug_prd "$bug29" "Base-tracks-parent bug" "Base must be the parent's branch."
rc29=0
(
  cd "$repo29"
  LCARS_GH_BIN="$repo29/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug29" >out29.txt 2>&1
) || rc29=$?
B29="$repo29/.git/lcars/missions/lcars-20260530-002-c10e"
check "23. exits zero filing against a parent on a different branch" "[ '$rc29' -eq 0 ]"
check "23. child base = the PARENT's branch (lcars/parent-custom)" \
  "grep -q '\"base\": *\"lcars/parent-custom\"' '$B29/state.json'"
check "23. child base is NOT the checked-out branch (some-other-branch)" \
  "! grep -q '\"base\": *\"some-other-branch\"' '$B29/state.json'"

# --- Behaviour 24: base falls back to lcars/<parent-id> with no branch field --
# When the parent's state.json has NO `branch` field, base falls back to
# lcars/<parent-id> — the SAME fallback the fix-branch logic uses — still NOT the
# checked-out branch.
repo30="$(new_repo_with_parent)"
make_gh_stub "$repo30/gh"
export GH_LOG="$repo30/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# strip the parent's branch field entirely.
grep -v '"branch":' "$repo30/.git/lcars/missions/lcars-20260530-001/state.json" \
  >"$repo30/tmp.json"
mv "$repo30/tmp.json" "$repo30/.git/lcars/missions/lcars-20260530-001/state.json"
( cd "$repo30" && git checkout -q -b some-other-branch )
bug30="$repo30/bug.md"; write_bug_prd "$bug30" "Base-fallback bug" "Base falls back to lcars/<parent-id>."
rc30=0
(
  cd "$repo30"
  LCARS_GH_BIN="$repo30/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug30" >out30.txt 2>&1
) || rc30=$?
B30="$repo30/.git/lcars/missions/lcars-20260530-002-c10e"
check "24. exits zero when the parent has no branch field" "[ '$rc30' -eq 0 ]"
check "24. child base falls back to lcars/<parent-id>" \
  "grep -q '\"base\": *\"lcars/lcars-20260530-001\"' '$B30/state.json'"
check "24. child base is NOT the checked-out branch (fallback case)" \
  "! grep -q '\"base\": *\"some-other-branch\"' '$B30/state.json'"

# --- Behaviour 25 (S174): a bug logged against a DRAWING inherits the drawing --
#
# MEASURED 2026-08-17: all NINE bugs logged against the holodeck-born mission
# lcars-20260814-001 carry `attachments: None`. Not one could open the drawing it
# was being told to reproduce, and the first fix round restored #screen-start's
# structure while losing its specifics — because the only description of the
# drawing that worker ever saw was the captain's prose.
#
# Inheritance is a UNION with whatever the captain passed, never a replacement,
# and ONLY a mockup is inherited: a screenshot of the parent's own bug is not
# context for a different bug.

# A parent Mission carrying attachments of the given basenames.
parent_with_attachments() { # repo  basename…
  local pdir="$1/.git/lcars/missions/lcars-20260530-001/attachments"
  mkdir -p "$pdir"
  shift
  local a
  for a in "$@"; do
    case "$a" in
      *.html) printf '<!doctype html><div id="screen-start">PARENT DRAWING</div>' >"$pdir/$a" ;;
      *)      printf 'PARENT-PNG' >"$pdir/$a" ;;
    esac
  done
}

# 25a. parent carries a mockup, captain passes NOTHING ⇒ the child inherits it.
repo31="$(new_repo_with_parent)"
make_gh_stub "$repo31/gh"
export GH_LOG="$repo31/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo31" attachment-01.html
bug31="$repo31/b.md"; write_bug_prd "$bug31" "Next-up card lost its accent border" "The blue accent border is gone."
rc31=0
(
  cd "$repo31"
  LCARS_GH_BIN="$repo31/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug31" >out31.txt 2>&1
) || rc31=$?
B31="$repo31/.git/lcars/missions/lcars-20260530-002-c10e"
check "25a. logging against a mockup-born parent succeeds" "[ '$rc31' -eq 0 ]"
check "25a. the child carries the parent's MOCKUP on disk" \
  "[ -f '$B31/attachments/attachment-01.html' ]"
check "25a. the inherited mockup is the parent's actual file, byte for byte" \
  "grep -q 'PARENT DRAWING' '$B31/attachments/attachment-01.html'"
check "25a. the child's prd.md references it (relative, like the parent's)" \
  "grep -q '^- attachments/attachment-01.html\$' '$B31/prd.md'"
check "25a. the child's prd.md heads it as a FILE, never an image" \
  "grep -q '## Attached files' '$B31/prd.md'"
check "25a. the child's prd.md carries the LOOK AND FLOW declaration" \
  "grep -q 'LOOK AND FLOW' '$B31/prd.md'"
check "25a. the child's state.json records it (NOT attachments: None)" \
  "grep -q '\"attachments\": *\\[ *\"attachments/attachment-01.html\"' '$B31/state.json'"

# 25b. THE UNION. The captain's own --attach screenshot rides ALONGSIDE the
# inherited drawing — inheritance never replaces what he passed.
repo32="$(new_repo_with_parent)"
make_gh_stub "$repo32/gh"
export GH_LOG="$repo32/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo32" attachment-01.html
shot32="$repo32/shot.png"; printf 'CAPTAIN-SHOT' >"$shot32"
bug32="$repo32/b.md"; write_bug_prd "$bug32" "Scrambled value cell" "Here is what I see."
rc32=0
(
  cd "$repo32"
  LCARS_GH_BIN="$repo32/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$shot32" --prd "$bug32" >out32.txt 2>&1
) || rc32=$?
B32="$repo32/.git/lcars/missions/lcars-20260530-002-c10e"
check "25b. logging with BOTH succeeds" "[ '$rc32' -eq 0 ]"
check "25b. the inherited drawing is there" \
  "[ -f '$B32/attachments/attachment-01.html' ]"
check "25b. the captain's screenshot is STILL there beside it" \
  "grep -rq 'CAPTAIN-SHOT' '$B32/attachments/'"
check "25b. both are listed in the child's prd.md" \
  "grep -q 'attachment-01.html' '$B32/prd.md' && grep -q '.png' '$B32/prd.md'"
check "25b. both are recorded in state.json" \
  "grep -q 'attachment-01.html' '$B32/state.json' && grep -q '.png' '$B32/state.json'"

# 25c. ONLY a mockup is inherited. A screenshot on the parent is a picture of the
# parent's own bug; it is not context for a different one.
repo33="$(new_repo_with_parent)"
make_gh_stub "$repo33/gh"
export GH_LOG="$repo33/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo33" attachment-01.png attachment-02.md
bug33="$repo33/b.md"; write_bug_prd "$bug33" "Unrelated bug" "Nothing to do with that screenshot."
rc33=0
(
  cd "$repo33"
  LCARS_GH_BIN="$repo33/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug33" >out33.txt 2>&1
) || rc33=$?
B33="$repo33/.git/lcars/missions/lcars-20260530-002-c10e"
check "25c. logging against a screenshots-only parent succeeds" "[ '$rc33' -eq 0 ]"
check "25c. a parent SCREENSHOT is NOT inherited" "[ ! -d '$B33/attachments' ]"
check "25c. a parent DOC is NOT inherited either" \
  "! grep -q 'attachments' '$B33/state.json'"

# 25d. a parent with NO attachments at all ⇒ byte-identical to today.
repo34="$(new_repo_with_parent)"
make_gh_stub "$repo34/gh"
export GH_LOG="$repo34/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug34="$repo34/b.md"; write_bug_prd "$bug34" "Plain bug" "No drawing anywhere."
rc34=0
(
  cd "$repo34"
  LCARS_GH_BIN="$repo34/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug34" >out34.txt 2>&1
) || rc34=$?
B34="$repo34/.git/lcars/missions/lcars-20260530-002-c10e"
check "25d. a no-mockup parent still files a bug" "[ '$rc34' -eq 0 ]"
check "25d. no attachments/ dir (unchanged)" "[ ! -d '$B34/attachments' ]"
check "25d. no prd.md attachments section (unchanged)" \
  "! grep -q '## Attached' '$B34/prd.md'"
check "25d. no state.json attachments key (unchanged)" \
  "! grep -q 'attachments' '$B34/state.json'"

# 25e. THE MEASURED CASE. Several bugs filed in ONE invocation against the
# mockup-born parent: EVERY child carries the drawing. Nine of nine read
# `attachments: None` before this round.
repo35="$(new_repo_with_parent)"
make_gh_stub "$repo35/gh"
export GH_LOG="$repo35/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo35" attachment-01.html
b35a="$repo35/a.md"; write_bug_prd "$b35a" "Bug one" "One."
b35b="$repo35/b.md"; write_bug_prd "$b35b" "Bug two" "Two."
b35c="$repo35/c.md"; write_bug_prd "$b35c" "Bug three" "Three."
rc35=0
(
  cd "$repo35"
  LCARS_GH_BIN="$repo35/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 \
      --prd "$b35a" --prd "$b35b" --prd "$b35c" >out35.txt 2>&1
) || rc35=$?
check "25e. a multi-bug filing succeeds" "[ '$rc35' -eq 0 ]"
M35="$repo35/.git/lcars/missions"
for n in 002 003 004; do
  # S196 — the fingerprint the pinned cloneId produces (see new_repo_with_parent).
  check "25e. bug lcars-20260530-$n-c10e can OPEN the drawing" \
    "[ -f '$M35/lcars-20260530-$n-c10e/attachments/attachment-01.html' ]"
  check "25e. bug lcars-20260530-$n-c10e does NOT read attachments: None" \
    "grep -q 'attachment-01.html' '$M35/lcars-20260530-$n-c10e/state.json'"
done

# 25f. …and because the child now CARRIES a mockup, the bug's own tickets are
# held to the same anchored-criterion contract as a feature's. A bug Mission goes
# through Plan like any other, and Plan keys the contract off the Mission's own
# attachments — so this is the inheritance paying for itself, not a second rule.
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
BLOCK35="$(LCARS_ATT_TEST_DIR="$M35/lcars-20260530-002-c10e" bash "$RUN_SH" plan-mockup-block-test 2>/dev/null)"
check "25f. the bug's Plan prompt carries the mockup contract" \
  "printf '%s' \"\$BLOCK35\" | grep -q 'changesScreenAppearance'"
check "25f. …naming the INHERITED drawing" \
  "printf '%s' \"\$BLOCK35\" | grep -q 'attachment-01.html'"
check "25f. …and the per-criterion declaration contract" \
  "printf '%s' \"\$BLOCK35\" | grep -q 'notDrawn'"

# The deterministic gate itself: a bug ticket that changes a screen's appearance
# and carries a criterion tracing to nothing is REJECTED, exactly like a feature's.
BUGPLAN="$repo35/bugplan.json"
cat >"$BUGPLAN" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Restore the next-up card accent border",
    "description": "Put the accent border back.",
    "acceptanceCriteria": [{"text": "The next-up card carries its accent border again", "drawnAt": "#screen-start, the next-up start-card"}, {"text": "A manual override toggle is added beside it"}],
    "estimatedReadLoc": 40,
    "estimatedTestLoc": 20,
    "estimatedNewLoc": 20,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "It is the reported defect."
  }
]
JSON
python3 - "$M35/lcars-20260530-002-c10e/state.json" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
open(p, 'w').write(re.sub(r'"stage":\s*"[^"]*"', '"stage": "plan"', t, count=1))
PY
OUT35="$( cd "$repo35" && LCARS_GH_BIN="$repo35/gh" LCARS_GIT_BIN="$(command -v git)" \
  bash "$RUN_SH" plan-save --mission lcars-20260530-002-c10e --plan "$BUGPLAN" 2>&1 )"
RC35=$?
check "25f. a bug ticket inventing an undrawn control is REJECTED" "[ '$RC35' -ne 0 ]"
check "25f. …naming the offending criterion" \
  "printf '%s' \"\$OUT35\" | grep -q 'criterion 2'"

# ==========================================================================
# 26. THE FIFTH FILING LANE — `lcars log` composes through the ONE composer
# ==========================================================================
# S188 factored one `lcars_issue_body_compose` out of file.sh's four filing
# lanes, but `lcars log` is the FIFTH: it filed a Mission (lcars:mission) whose
# body was still composed inline, so it carried NO `lcars:handoff` envelope and
# a second laptop adopting a logged bug from GitHub found nothing machine-
# readable. The irony worth keeping: `parentIssue` is the one envelope field
# that is ever non-null, and this is the ONLY lane that sets it.
#
# The visible body must stay BYTE-IDENTICAL modulo the appended envelope —
# the same parity contract the other four lanes hold — and the
# `> 🐞 Logged via …` provenance line is part of that visible body.
echo "  -- 26. the log lane composes through lcars_issue_body_compose"

IB_LIB26="$REPO_ROOT/skills/lcars-run/issue-body.sh"

# A gh stub that records the BODY it was handed, byte for byte.
repo26="$(new_repo_with_parent)"
cat >"$repo26/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
prev=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && cp "$a" "$GH_BODY"
  prev="$a"
done
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/45"
fi
exit 0
EOF
chmod +x "$repo26/gh"
export GH_LOG="$repo26/gh.log"; : >"$GH_LOG"
export GH_BODY="$repo26/body.out"; : >"$GH_BODY"
bug26="$repo26/bug.md"
write_bug_prd "$bug26" "CSV export double-fires" "Two clicks must produce one download."
( cd "$repo26"
  LCARS_GH_BIN="$repo26/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug26" >"$repo26/out.txt" 2>&1 )
B26="$repo26/.git/lcars/missions/lcars-20260530-002-c10e"

check "26. the logged-bug body carries exactly one lcars:handoff envelope" \
  "[ \"\$(grep -c 'lcars:handoff' '$GH_BODY')\" = 1 ]"
check "26. the envelope is the LAST line of the body" \
  "tail -1 '$GH_BODY' | grep -q '^<!-- lcars:handoff v1 .* -->\$'"

# BYTE PARITY. The pre-S188 inline body was, exactly:
#   "> 🐞 Logged via `lcars log` against <parent>[ (#n)].\n\n" + prd.md verbatim
# Rebuild those bytes here and require the recorded body to START with them.
EXPECT26="$TMPROOT/expect26.body"
{ printf '> 🐞 Logged via `lcars log` against lcars-20260530-001 (#42).\n\n'
  cat "$B26/prd.md"; } >"$EXPECT26"
N26="$(wc -c <"$EXPECT26" | tr -d ' ')"
check "26. the VISIBLE body is byte-identical to the pre-S188 inline body" \
  "cmp -s <(head -c '$N26' '$GH_BODY') '$EXPECT26'"
check "26. …and everything after it is nothing but the appended envelope" \
  "[ \"\$(tail -c +\$(( $N26 + 1 )) '$GH_BODY' | grep -vc '^\$')\" = 1 ]"

# The lane's own envelope values — this is the ONE lane with a real parentIssue.
lf() { bash -c '. "$1"; lcars_handoff_field "$2" "$3"' _ "$IB_LIB26" "$GH_BODY" "$1"; }
check "26. envelope id is the BUG mission's id, not the parent's" \
  "[ \"\$(lf id)\" = 'lcars-20260530-002-c10e' ]"
check "26. envelope type is bug" "[ \"\$(lf type)\" = 'bug' ]"
check "26. envelope parentIssue carries the PARENT's issue number" \
  "[ \"\$(lf parentIssue)\" = '42' ]"
check "26. envelope branch matches the branch state.json recorded" \
  "[ \"\$(lf branch)\" = \"\$(sed -n 's/.*\"branch\": *\"\\([^\"]*\\)\".*/\\1/p' '$B26/state.json' | head -1)\" ]"
check "26. envelope base matches the base state.json recorded" \
  "[ \"\$(lf base)\" = \"\$(sed -n 's/.*\"base\": *\"\\([^\"]*\\)\".*/\\1/p' '$B26/state.json' | head -1)\" ]"
check "26. a logged bug is never marked parked" "[ -z \"\$(lf parked)\" ]"
check "26. filing seeds the regression baseline for later refreshes" \
  "[ -f '$B26/.issue-body.last' ]"
check "26. that baseline is the body that was actually pushed" \
  "cmp -s '$B26/.issue-body.last' '$GH_BODY'"

# A parent with NO issue number: the "(#n)" half is omitted, exactly as before.
repo26b="$(new_repo_with_parent)"
python3 - "$repo26b/.git/lcars/missions/lcars-20260530-001/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('"githubIssue": 42', '"githubIssue": null'))
PY
cp "$repo26/gh" "$repo26b/gh"
export GH_LOG="$repo26b/gh.log"; : >"$GH_LOG"
export GH_BODY="$repo26b/body.out"; : >"$GH_BODY"
bug26b="$repo26b/bug.md"
write_bug_prd "$bug26b" "Another defect" "It should not happen."
( cd "$repo26b"
  LCARS_GH_BIN="$repo26b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug26b" >"$repo26b/out.txt" 2>&1 )
check "26. a parent with no issue number drops the '(#n)' half, as before" \
  "head -1 '$GH_BODY' | grep -q 'against lcars-20260530-001\.\$'"
check "26. …and that body still carries an envelope" \
  "grep -q 'lcars:handoff' '$GH_BODY'"
check "26. …whose parentIssue is null" \
  "[ -z \"\$(bash -c '. \"\$1\"; lcars_handoff_field \"\$2\" parentIssue' _ '$IB_LIB26' '$GH_BODY')\" ]"

# --- Behaviour 27 (S204): NUMBER ONE FILES THROUGH THIS VERB, THE HOUSE WAY ---
# Number One's fix round adds no filing path of its own: it writes a bug PRD per
# contradiction and makes ONE `lcars log` call in exactly the shape `run.sh`
# already makes it — `--parent <id> --prd 1.md --attach shot.png --prd 2.md
# --attach shot.png` — with the per-bug binding carried by argument ORDER. This
# row is the seam between the two halves: the PRD `xo-logs.py` writes must be
# one this verb accepts unchanged, and the binding must survive.
#
# THE CONTROL IS IN THE ROW. The second bug's shot must land on the second bug
# AND NOT on the first — a check that only asserted "bug 2 has its shot" would
# still pass if every shot went to every bug, which is the bug this pins.
XOLOGS="$REPO_ROOT/skills/lcars-xo/xo-logs.py"
repo34="$(new_repo_with_parent)"
make_gh_stub "$repo34/gh"
export GH_LOG="$repo34/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo34" attachment-01.html
mkdir -p "$repo34/xo/shots" "$repo34/xo/logs"
printf 'PNG-ONE' >"$repo34/xo/shots/shot-01.png"
printf 'PNG-TWO' >"$repo34/xo/shots/shot-02.png"
cat >"$repo34/verdict.json" <<'VJ'
{
  "score": "medium",
  "summary": "Two mismatches.",
  "criteria": [],
  "gaps": [
    {"title": "ADD is above the list", "expected": "the ADD button sits under the task list",
     "saw": "it is above it", "shots": ["shot-01"], "kind": "contradiction", "criterion": "prd-1"},
    {"title": "the count is missing", "expected": "the open-task count sits in the header",
     "saw": "no count anywhere", "shots": ["shot-02"], "kind": "contradiction", "criterion": "prd-2"},
    {"title": "the header is teal", "expected": "the drawing is silent",
     "saw": "teal", "shots": ["shot-01"], "kind": "interpretation", "criterion": "prd-3"}
  ]
}
VJ
cat >"$repo34/criteria.json" <<'CJ'
{"criteria": [
  {"id": "prd-1", "text": "The ADD button sits under the task list.", "primary": true, "source": "PRD \u00a72"},
  {"id": "prd-2", "text": "The header shows the open-task count.", "primary": true, "source": "PRD \u00a72"}
]}
CJ
plan34="$(python3 "$XOLOGS" "$repo34/verdict.json" "$repo34/criteria.json" \
            "$repo34/xo/logs" "$repo34/xo/shots" 10)"
ngap34="$(printf '%s\n' "$plan34" | grep -c '^GAP')"
check "27. only the CONTRADICTIONS became bug PRDs (the interpretation did not)" \
  "[ '$ngap34' -eq 2 ] && [ ! -f '$repo34/xo/logs/3.md' ]"
check "27. each PRD carries the house title line lcars log demands" \
  "grep -q '^# Mission: ' '$repo34/xo/logs/1.md' && grep -q '^\*\*Type:\*\* bug' '$repo34/xo/logs/1.md'"
check "27. …the expected/saw sentence, citing where the expectation is written" \
  "grep -q 'Expected the ADD button sits under the task list, per PRD' '$repo34/xo/logs/1.md'"
check "27. …and an acceptance criterion that RESTATES the contract's own words" \
  "grep -q 'The ADD button sits under the task list.' '$repo34/xo/logs/1.md'"
rc34=0
(
  cd "$repo34"
  LCARS_GH_BIN="$repo34/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 \
      --prd "$repo34/xo/logs/1.md" --attach "$repo34/xo/shots/shot-01.png" \
      --prd "$repo34/xo/logs/2.md" --attach "$repo34/xo/shots/shot-02.png" >out34.txt 2>&1
) || rc34=$?
B34a="$repo34/.git/lcars/missions/lcars-20260530-002-c10e"
B34b="$repo34/.git/lcars/missions/lcars-20260530-003-c10e"
check "27. the house-way invocation files both bugs" "[ '$rc34' -eq 0 ]"
check "27. bug 1 carries ITS shot" "grep -rq 'PNG-ONE' '$B34a/attachments/'"
check "27. …and NOT the other bug's shot (per-bug binding held)" \
  "! grep -rq 'PNG-TWO' '$B34a/attachments/'"
check "27. bug 2 carries ITS shot" "grep -rq 'PNG-TWO' '$B34b/attachments/'"
check "27. …and NOT the first bug's" "! grep -rq 'PNG-ONE' '$B34b/attachments/'"
check "27. both bugs INHERIT the parent's drawing (never passed by hand)" \
  "[ -f '$B34a/attachments/attachment-01.html' ] && [ -f '$B34b/attachments/attachment-01.html' ]"
check "27. both are linked to the parent" \
  "grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B34a/state.json' && grep -q '\"parentMission\": *\"lcars-20260530-001\"' '$B34b/state.json'"
nrow34="$(grep -c '^  lcars-20260530-00' "$repo34/out34.txt")"
check "27. the summary prints one row per child, in filed order — the id map" \
  "[ '$nrow34' -eq 2 ]"

# --- Behaviour 27b (S204): the CAP. Eleven contradictions file ten, and the -----
# eleventh is REPORTED, never silently dropped.
cat >"$repo34/verdict11.json" <<'VJ'
{"score": "low", "summary": "many", "criteria": [], "gaps": [
 {"title":"g1","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c1"},
 {"title":"g2","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c2"},
 {"title":"g3","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c3"},
 {"title":"g4","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c4"},
 {"title":"g5","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c5"},
 {"title":"g6","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c6"},
 {"title":"g7","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c7"},
 {"title":"g8","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c8"},
 {"title":"g9","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c9"},
 {"title":"g10","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c10"},
 {"title":"g11","expected":"a","saw":"b","shots":["shot-01"],"kind":"contradiction","criterion":"c11"}
]}
VJ
rm -rf "$repo34/xo/logs11"; mkdir -p "$repo34/xo/logs11"
plan34b="$(python3 "$XOLOGS" "$repo34/verdict11.json" "$repo34/criteria.json" \
             "$repo34/xo/logs11" "$repo34/xo/shots" 10)"
ngap34b="$(printf '%s\n' "$plan34b" | grep -c '^GAP')"
# US (0x1f), not a tab: xo-logs.py's records must carry an EMPTY shots field
# for a gap the project's own tests found, and a tab is IFS whitespace — the
# shell's `read` eats it and shifts every later field left (S211 fix round 1).
nover34b="$(printf '%s\n' "$plan34b" | grep -c "^OVERFLOW$(printf '\037')1$")"
check "27b. exactly TEN bug PRDs are written" \
  "[ '$ngap34b' -eq 10 ] && [ ! -f '$repo34/xo/logs11/11.md' ]"
check "27b. the overflow is REPORTED, with its count" "[ '$nover34b' -eq 1 ]"

# --- Behaviour 27c (S211 fix round 1, D2). THE LOCAL-ONLY SUMMARY ROW ---------
#
# `file_one_bug` emits `<id>\t<issue>\t<title>` and the summary reads it back
# with `IFS=$'\t' read -r rid rissue rtitle`. TAB IS IFS WHITESPACE, so when a
# bug is filed with NO issue — a repo with no forge, or a `gh issue create` that
# did not come back with a number — bash COLLAPSES the empty middle field and
# every field after it shifts left. The `case "$rissue" in ''` arm that exists
# for exactly this case can then NEVER fire, and the captain was shown
#
#     lcars-…-001-c10e  #the mix-ratio status line
#
# — the first word of his own title rendered as an issue NUMBER. Number One's
# filing readout then recorded `"issue": "the"` in `xo/logs.json` off the same
# row. Same class and same cure as the gap plan: a separator that is not IFS
# whitespace. THE CONTROL is in the row: a bug filed WITH an issue must still
# read `#45`.
repo27c="$(new_repo_with_parent)"
cat >"$repo27c/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 0
EOF
chmod +x "$repo27c/gh"
export GH_LOG="$repo27c/gh.log"; : >"$GH_LOG"
bug27c="$repo27c/bug.md"
write_bug_prd "$bug27c" "the mix-ratio status line" "The status line is missing."
( cd "$repo27c"
  LCARS_GH_BIN="$repo27c/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug27c" >"$repo27c/out.txt" 2>&1 )
check "27c. a bug filed with NO issue reads as (local), not as a fake issue number" \
  "grep -q '(local)' '$repo27c/out.txt'"
check "27c. …and the captain's own title is NOT rendered as an issue number" \
  "! grep -q '#the' '$repo27c/out.txt'"
check "27c. …with the whole title intact on the row" \
  "grep -q 'the mix-ratio status line' '$repo27c/out.txt'"
repo27d="$(new_repo_with_parent)"
make_gh_stub "$repo27d/gh"
export GH_LOG="$repo27d/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug27d="$repo27d/bug.md"
write_bug_prd "$bug27d" "the mix-ratio status line" "The status line is missing."
( cd "$repo27d"
  LCARS_GH_BIN="$repo27d/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug27d" >"$repo27d/out.txt" 2>&1 )
check "27c. CONTROL: a bug filed WITH an issue still shows its number" \
  "grep -qE '  #[0-9]+  the mix-ratio status line\$' '$repo27d/out.txt'"

# ==========================================================================
# 28 (S204 fix round 1, D1). THE ENGAGED LOCK EXEMPTS NUMBER ONE'S OWN FILING.
#
# `lcars xo evaluate` files what it found THROUGH this verb, and it is `engaged`
# on the parent for the whole of the look. The lock refuses exactly that state,
# so before this fix Number One found two contradictions and filed NONE:
#   "lcars log: Number One is engaged on this mission on your behalf — …"
# The exemption is a marker that NAMES the mission it is allowed to write.
# ==========================================================================
echo
echo "28. the engaged lock vs Number One's own filing"

engage_parent() { # <repo>
  local st="$1/.git/lcars/missions/lcars-20260530-001/state.json"
  python3 - "$st" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
out = {}
for k, v in d.items():
    out[k] = v
    if k == "stage":
        out["numberOne"] = {"status": "engaged", "engine": "copilot"}
keys = list(out)
lines = ["{"]
for i, k in enumerate(keys):
    lines.append('  %s: %s%s' % (json.dumps(k), json.dumps(out[k]),
                                 "," if i < len(keys) - 1 else ""))
lines.append("}")
open(p, "w").write("\n".join(lines) + "\n")
EOF
}
LOG_REFUSAL="Number One is engaged on this mission on your behalf — stand it down (lcars xo off lcars-20260530-001) to act yourself"

# 28a. CONTROL — a parent Number One is NOT on files normally. Without a row
# that must PASS, the refusals below cannot detect their own breakage.
repo40="$(new_repo_with_parent)"; make_gh_stub "$repo40/gh"
export GH_LOG="$repo40/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug40="$repo40/b.md"; write_bug_prd "$bug40" "Accent border gone" "It is gone."
rc40=0
( cd "$repo40" && LCARS_GH_BIN="$repo40/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug40" >out40.txt 2>&1 ) || rc40=$?
check "28a. CONTROL: not engaged ⇒ the filing lands" \
  "[ '$rc40' -eq 0 ] && [ -d '$repo40/.git/lcars/missions/lcars-20260530-002-c10e' ]"

# 28b. THE CAPTAIN'S OWN `lcars log` IS STILL REFUSED. The lock is not weakened
# by the exemption — this row is the whole point of it.
repo41="$(new_repo_with_parent)"; make_gh_stub "$repo41/gh"; engage_parent "$repo41"
export GH_LOG="$repo41/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug41="$repo41/b.md"; write_bug_prd "$bug41" "Accent border gone" "It is gone."
rc41=0
( cd "$repo41" && LCARS_GH_BIN="$repo41/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug41" >out41.txt 2>&1 ) || rc41=$?
check "28b. engaged ⇒ the CAPTAIN's own \`lcars log\` is refused" "[ '$rc41' -ne 0 ]"
check "28b. …with the same sentence, byte for byte" \
  "grep -Fqx \"lcars log: \$LOG_REFUSAL\" '$repo41/out41.txt'"
check "28b. …and NOTHING was filed" \
  "[ ! -d '$repo41/.git/lcars/missions/lcars-20260530-002-c10e' ]"

# 28c. NUMBER ONE'S OWN CALL, marker naming THIS parent ⇒ it files.
repo42="$(new_repo_with_parent)"; make_gh_stub "$repo42/gh"; engage_parent "$repo42"
export GH_LOG="$repo42/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug42="$repo42/b.md"; write_bug_prd "$bug42" "Accent border gone" "It is gone."
rc42=0
( cd "$repo42" && LCARS_GH_BIN="$repo42/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_XO_INTERNAL=lcars-20260530-001 \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug42" >out42.txt 2>&1 ) || rc42=$?
check "28c. engaged + the marker naming THIS parent ⇒ Number One's filing lands" \
  "[ '$rc42' -eq 0 ] && ! grep -q 'Number One is engaged' '$repo42/out42.txt'"
check "28c. …and the bug mission really exists on disk" \
  "[ -f '$repo42/.git/lcars/missions/lcars-20260530-002-c10e/prd.md' ]"

# 28d. A MARKER NAMING A DIFFERENT MISSION EXEMPTS NOTHING.
repo43="$(new_repo_with_parent)"; make_gh_stub "$repo43/gh"; engage_parent "$repo43"
export GH_LOG="$repo43/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug43="$repo43/b.md"; write_bug_prd "$bug43" "Accent border gone" "It is gone."
rc43=0
( cd "$repo43" && LCARS_GH_BIN="$repo43/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_XO_INTERNAL=lcars-20260530-777 \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug43" >out43.txt 2>&1 ) || rc43=$?
check "28d. a marker naming ANOTHER mission does NOT exempt this parent" \
  "[ '$rc43' -ne 0 ] && grep -q 'Number One is engaged' '$repo43/out43.txt'"

# ==========================================================================
# 29 (S204 fix round 1, D4). A FILED LOG NAMES THE FILE THE CAPTAIN WILL SEE.
#
# Staging renames every attachment to `attachment-NN.<ext>`. Number One's bug
# PRD still talks about `shot-01`, so a filed log said "(shot-01)" while the
# only picture attached was `attachments/attachment-02.png` and nothing joined
# the two names. The renamer — the only thing that knows both — now says which
# is which.
# ==========================================================================
echo
echo "29. which file is which"

repo44="$(new_repo_with_parent)"; make_gh_stub "$repo44/gh"
export GH_LOG="$repo44/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
parent_with_attachments "$repo44" attachment-01.html
shot44="$repo44/shot-01.png"; printf 'NUMBER-ONE-SHOT' >"$shot44"
bug44="$repo44/b.md"; write_bug_prd "$bug44" "Accent border gone" "Expected a border, saw none (shot-01)."
rc44=0
( cd "$repo44" && LCARS_GH_BIN="$repo44/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    LCARS_XO_INTERNAL=lcars-20260530-001 \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$shot44" --prd "$bug44" >out44.txt 2>&1 ) || rc44=$?
B44="$repo44/.git/lcars/missions/lcars-20260530-002-c10e"
check "29. the filing succeeds" "[ '$rc44' -eq 0 ]"
check "29. the shot really landed as attachment-02.png (the renamed name)" \
  "[ -f '$B44/attachments/attachment-02.png' ]"
check "29. the body still talks about shot-01 (the substance is untouched)" \
  "grep -q 'shot-01' '$B44/prd.md'"
check "29. the body now JOINS the two names — shot-01 ⇒ attachment-02.png" \
  "grep -q 'Which file is which' '$B44/prd.md' && grep -q 'attachments/attachment-02.png.*shot-01' '$B44/prd.md'"
check "29. the ISSUE BODY carries it too (it is prd.md that is posted)" \
  "grep -q 'Which file is which' '$GH_LOG.body' 2>/dev/null || grep -q 'Which file is which' '$B44/prd.md'"
check "29. the inherited drawing is named by both its names as well" \
  "grep -q 'attachments/attachment-01.html.*attachment-01' '$B44/prd.md'"

# 29b. NOTHING IS ADDED WHEN NOTHING WAS RENAMED. A bug whose attachments
# already carry their staged names gets no section and no noise.
repo45="$(new_repo_with_parent)"; make_gh_stub "$repo45/gh"
export GH_LOG="$repo45/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
mkdir -p "$repo45/src"; printf 'X' >"$repo45/src/attachment-01.png"
bug45="$repo45/b.md"; write_bug_prd "$bug45" "Another one" "Here."
rc45=0
( cd "$repo45" && LCARS_GH_BIN="$repo45/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$repo45/src/attachment-01.png" --prd "$bug45" >out45.txt 2>&1 ) || rc45=$?
B45="$repo45/.git/lcars/missions/lcars-20260530-002-c10e"
check "29b. a filing whose names did not change gets NO extra section" \
  "[ '$rc45' -eq 0 ] && ! grep -q 'Which file is which' '$B45/prd.md'"

# 29c. THE CAPTAIN'S OWN pasted screenshot is untouched — his bug PRD's
# attachment section must not move by one character (asserted byte-for-byte at
# 21e). Only Number One's own filings, which name their evidence by name, get
# the map.
repo46="$(new_repo_with_parent)"; make_gh_stub "$repo46/gh"
export GH_LOG="$repo46/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
shot46="$repo46/my-screenshot.png"; printf 'CAPTAIN' >"$shot46"
bug46="$repo46/b.md"; write_bug_prd "$bug46" "Captains own" "Here."
rc46=0
( cd "$repo46" && LCARS_GH_BIN="$repo46/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --attach "$shot46" --prd "$bug46" >out46.txt 2>&1 ) || rc46=$?
B46="$repo46/.git/lcars/missions/lcars-20260530-002-c10e"
check "29c. the captain's own filing is renamed too (a control)" \
  "[ '$rc46' -eq 0 ] && [ -f '$B46/attachments/attachment-01.png' ]"
check "29c. …and gets NO extra section — his wording does not move" \
  "! grep -q 'Which file is which' '$B46/prd.md'"

# --- Behaviour 30 (S205 ruling 3): NO FALSE SUCCESS ------------------------
# `file_one_bug` runs inside `ROWS+=("$(file_one_bug ...)")` — a command
# substitution, hence a SUBSHELL. Its own `die` prints to stderr (which escapes
# the substitution, so the captain still sees the validation error) and exits
# the SUBSHELL, but that exit code was silently discarded and `ROWS+=` still
# appended one (empty) row — so the loop always believed every PRD it was
# handed had been filed, and the summary printed
# "1 bug mission filed and linked to #42" with an empty id and a bare
# "Run `lcars run ` to begin." even though `mkdir "$mdir"` never ran for that
# bug (validation is checked BEFORE the mkdir). Cure: the parent must notice
# the subshell's exit status and refuse to print a success summary it did not
# earn.
repo47="$(new_repo_with_parent)"; make_gh_stub "$repo47/gh"
export GH_LOG="$repo47/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
bug47="$repo47/bad.md"
cat >"$bug47" <<'EOF'
**Type:** bug
**Goal:** This PRD is missing its title line on purpose.
**Acceptance Criteria:**
- n/a
EOF
rc47=0
( cd "$repo47" && LCARS_GH_BIN="$repo47/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$bug47" >out47.txt 2>out47.err ) || rc47=$?
check "30. refuses (non-zero) on a PRD missing '# Mission:'" "[ '$rc47' -ne 0 ]"
check "30. prints the validation error" \
  "grep -q \"missing its '# Mission:' title line\" '$repo47/out47.err'"
check "30. NEVER prints a false 'filed and linked' success line" \
  "! grep -q 'filed and linked' '$repo47/out47.txt' '$repo47/out47.err'"
check "30. NEVER prints the empty-id 'Run \`lcars run \`' line" \
  "! grep -Eq 'Run .lcars run . to begin' '$repo47/out47.txt' '$repo47/out47.err'"
check "30. files NOTHING — no bug mission dir was created" \
  "! ls -d '$repo47/.git/lcars/missions/lcars-20260530-'*-c10e >/dev/null 2>&1"

# 30b. A GOOD bug ahead of a bad one in the SAME invocation: the good one's
# summary must still be honest about the one that failed — never silently
# dropped into a report that claims full success.
repo48="$(new_repo_with_parent)"; make_gh_stub "$repo48/gh"
export GH_LOG="$repo48/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
good48="$repo48/good.md"; write_bug_prd "$good48" "A real bug" "Reproduces every time."
bad48="$repo48/bad.md"
cat >"$bad48" <<'EOF'
**Type:** bug
**Goal:** Missing title again.
EOF
rc48=0
( cd "$repo48" && LCARS_GH_BIN="$repo48/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_DATE="20260530" \
    bash "$SCRIPT" --parent lcars-20260530-001 --prd "$good48" --prd "$bad48" >out48.txt 2>out48.err ) || rc48=$?
check "30b. refuses (non-zero) when any bug in the batch is malformed" \
  "[ '$rc48' -ne 0 ]"
check "30b. never prints a false 'filed and linked' summary for the batch" \
  "! grep -q 'filed and linked' '$repo48/out48.txt' '$repo48/out48.err'"

# ==========================================================================
echo
printf 'lcars log: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
