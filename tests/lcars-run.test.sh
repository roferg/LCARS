#!/usr/bin/env bash
#
# Tests for `lcars run` — the Research stage (skill source: skills/lcars-run/run.sh).
#
# `lcars run` has two halves. The conversational half (reading the PRD,
# generating 0–20 questions, spawning stateless research subagents) is driven
# by Claude per SKILL.md. The mechanical, testable half lives in run.sh and is
# split into two subcommands:
#
#   gate  — branch on the question count BEFORE any agent runs
#   save  — persist the agents' responses, then advance the mission
#
# These tests drive that script, covering the five behaviours from the build
# order, in order:
#   1. Skips research and advances to validate when 0 questions generated
#   2. Saves each research response as correctly-shaped JSON
#   3. Updates stage to "validate" after research completes
#   4. Updates the GitHub label correctly (lcars:align → lcars:research)
#   5. Triggers a human prompt when > 20 questions are needed
#
# The script takes its dependencies via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary (default: gh)
#
# Usage: bash tests/lcars-run.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- stubs ----------------------------------------------------------------
# A fake `gh` that records every invocation to $GH_LOG and otherwise succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated git repo with one mission already filed at stage "align".
# Echoes the repo path. Mission id is fixed: lcars-20260530-001, issue #42.
new_repo_with_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/lcars-20260530-001"
  mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
**Out of Scope:**
- Per-component theming
**Constraints:**
- Existing CSS variables
EOF
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "align",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42
}
EOF
  echo "$repo"
}

# Write a well-formed research response JSON to a path.
write_response() { # file question
  cat >"$1" <<EOF
{
  "question": "$2",
  "recommendation": "Do the sensible thing.",
  "supporting_points": ["because A", "because B"]
}
EOF
}

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }

# Build a repo with a mission already at stage "validate" — i.e. Research has
# run and saved findings, and the next Stage to execute is Validate.
new_repo_with_validate_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"validate"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  local rdir="$repo/.git/lcars/missions/$MID/research"
  mkdir -p "$rdir"
  write_response "$rdir/1.json" "Which colour token drives the theme?"
  write_response "$rdir/2.json" "Where is the toggle persisted?"
  echo "$repo"
}

# Write a well-formed validated plan (the Validator's synthesis) to a path.
write_plan() { # file
  cat >"$1" <<'EOF'
# Validated Plan: Add dark mode

## Synthesis
Research agrees a CSS-variable theme driven by a persisted toggle is the path.

## Decisions
- Use the existing `--color-*` tokens; flip a `data-theme` attribute on `<html>`.
- Persist the learner's choice in `localStorage`.
EOF
}

# ==========================================================================
echo "lcars run"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: 0 questions → skip research, advance to validate ---------
repo1="$(new_repo_with_mission)"; make_gh_stub "$repo1/gh"
export GH_LOG="$repo1/gh.log"; : >"$GH_LOG"
: >"$repo1/questions.txt"   # zero questions
rc1=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" bash "$SCRIPT" gate \
    --mission "$MID" --questions "$repo1/questions.txt" >out.txt 2>&1 ) || rc1=$?
check "1. gate exits 0 when there are no questions" "[ '$rc1' -eq 0 ]"
check "1. announces it is skipping research" \
  "grep -qi 'skip' '$repo1/out.txt'"
check "1. advances the stage to validate" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repo1")'"

# --- Behaviour 2: save responses as correctly-shaped JSON -----------------
repo2="$(new_repo_with_mission)"; make_gh_stub "$repo2/gh"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"
resp="$repo2/responses"; mkdir -p "$resp"
write_response "$resp/001.json" "Which colour token drives the theme?"
write_response "$resp/002.json" "Where is the toggle persisted?"
rc2=0
( cd "$repo2" && LCARS_GH_BIN="$repo2/gh" bash "$SCRIPT" save \
    --mission "$MID" --responses "$resp" >out.txt 2>&1 ) || rc2=$?
RDIR="$repo2/.git/lcars/missions/$MID/research"
check "2. save exits 0" "[ '$rc2' -eq 0 ]"
check "2. writes research/1.json"            "[ -f '$RDIR/1.json' ]"
check "2. writes research/2.json"            "[ -f '$RDIR/2.json' ]"
check "2. saved response has question"        "grep -q '\"question\"' '$RDIR/1.json'"
check "2. saved response has recommendation"  "grep -q '\"recommendation\"' '$RDIR/1.json'"
check "2. saved response has supporting_points" "grep -q '\"supporting_points\"' '$RDIR/1.json'"

# a malformed response (missing supporting_points) stops the save entirely
repo2b="$(new_repo_with_mission)"; make_gh_stub "$repo2b/gh"
export GH_LOG="$repo2b/gh.log"; : >"$GH_LOG"
respB="$repo2b/responses"; mkdir -p "$respB"
printf '{ "question": "q", "recommendation": "r" }\n' >"$respB/001.json"
rc2b=0
( cd "$repo2b" && LCARS_GH_BIN="$repo2b/gh" bash "$SCRIPT" save \
    --mission "$MID" --responses "$respB" >outB.txt 2>&1 ) || rc2b=$?
check "2. rejects a malformed response" "[ '$rc2b' -ne 0 ]"
check "2. does not advance on a malformed response" \
  "grep -q '\"stage\": *\"align\"' '$(state_of "$repo2b")'"

# --- Behaviour 3: stage becomes validate after research completes ---------
check "3. save advanced the stage to validate" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repo2")'"

# --- Behaviour 4: GitHub label moved align → validate ----------------------
# The on-disk stage and the GitHub label stay in agreement: both land on
# "validate" (the Stage `lcars run` will execute next). Asserted on the save
# path of behaviour 2.
check "4. calls gh issue edit on the mission's issue" \
  "grep -q 'issue edit 42' '$repo2/gh.log'"
check "4. adds the lcars:validate label" \
  "grep -q 'add-label lcars:validate' '$repo2/gh.log'"
check "4. removes the lcars:align label" \
  "grep -q 'remove-label lcars:align' '$repo2/gh.log'"
check "4. label agrees with the on-disk stage (validate)" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repo2")'"
# the skip path (behaviour 1) relabels the same way
check "4. skip path also relabels align → validate" \
  "grep -q 'add-label lcars:validate' '$repo1/gh.log' && grep -q 'remove-label lcars:align' '$repo1/gh.log'"

# --- Behaviour 5: > 20 questions triggers a human prompt ------------------
repo5="$(new_repo_with_mission)"; make_gh_stub "$repo5/gh"
export GH_LOG="$repo5/gh.log"; : >"$GH_LOG"
q5="$repo5/questions.txt"; : >"$q5"
for i in $(seq 1 21); do echo "Question number $i?" >>"$q5"; done
rc5=0
( cd "$repo5" && LCARS_GH_BIN="$repo5/gh" bash "$SCRIPT" gate \
    --mission "$MID" --questions "$q5" >out.txt 2>&1 ) || rc5=$?
check "5. gate exits non-zero when over the cap" "[ '$rc5' -ne 0 ]"
check "5. reports the question count (21)" \
  "grep -q '21' '$repo5/out.txt'"
check "5. offers the override option" \
  "grep -qi 'override' '$repo5/out.txt'"
check "5. offers the return-to-align option" \
  "grep -qi 'return-to-align\\|align' '$repo5/out.txt'"
check "5. changes nothing — stage is still align" \
  "grep -q '\"stage\": *\"align\"' '$(state_of "$repo5")'"
check "5. does not touch the GitHub label" \
  "! grep -q 'issue edit' '$repo5/gh.log'"

# --- Guard: Research refuses to run on a non-align mission ------------------
repo6="$(new_repo_with_mission)"; make_gh_stub "$repo6/gh"
export GH_LOG="$repo6/gh.log"; : >"$GH_LOG"
# bump it past align
sed 's/"align"/"plan"/' "$(state_of "$repo6")" >"$repo6/s.tmp" && mv "$repo6/s.tmp" "$(state_of "$repo6")"
rc6=0
( cd "$repo6" && LCARS_GH_BIN="$repo6/gh" bash "$SCRIPT" gate \
    --mission "$MID" --questions /dev/null >out.txt 2>&1 ) || rc6=$?
check "guard. refuses to run Research on a non-align mission" "[ '$rc6' -ne 0 ]"

# ==========================================================================
echo
echo "lcars run — Validate stage"

# --- V1/V2: no scope questions → write the plan, advance to plan -----------
# validate-advance synthesises the research into validated-plan.md and moves
# the Mission on. The four Validate behaviours, in order:
#   1. Produces validated-plan.md with the right structure
#   2. Advances to the plan stage when there are no scope questions
repoV="$(new_repo_with_validate_mission)"; make_gh_stub "$repoV/gh"
export GH_LOG="$repoV/gh.log"; : >"$GH_LOG"
planV="$repoV/plan.md"; write_plan "$planV"
rcV=0
( cd "$repoV" && LCARS_GH_BIN="$repoV/gh" bash "$SCRIPT" validate-advance \
    --mission "$MID" --plan "$planV" >out.txt 2>&1 ) || rcV=$?
PLAN_OUT="$repoV/.git/lcars/missions/$MID/validated-plan.md"
check "V. validate-advance exits 0" "[ '$rcV' -eq 0 ]"
check "V1. writes validated-plan.md"            "[ -f '$PLAN_OUT' ]"
check "V1. plan keeps its Synthesis section"    "grep -q '## Synthesis' '$PLAN_OUT'"
check "V1. plan keeps its Decisions section"    "grep -q '## Decisions' '$PLAN_OUT'"
check "V2. advances the stage to plan" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoV")'"
check "V2. relabels validate → plan (adds lcars:plan)" \
  "grep -q 'add-label lcars:plan' '$repoV/gh.log'"
check "V2. relabels validate → plan (removes lcars:validate)" \
  "grep -q 'remove-label lcars:validate' '$repoV/gh.log'"

# a malformed plan (missing the Decisions section) is rejected; nothing moves
repoVb="$(new_repo_with_validate_mission)"; make_gh_stub "$repoVb/gh"
export GH_LOG="$repoVb/gh.log"; : >"$GH_LOG"
printf '# Validated Plan: x\n\n## Synthesis\nonly this\n' >"$repoVb/bad.md"
rcVb=0
( cd "$repoVb" && LCARS_GH_BIN="$repoVb/gh" bash "$SCRIPT" validate-advance \
    --mission "$MID" --plan "$repoVb/bad.md" >outB.txt 2>&1 ) || rcVb=$?
check "V1. rejects a plan missing a required section" "[ '$rcVb' -ne 0 ]"
check "V1. does not advance on a malformed plan" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repoVb")'"
check "V1. writes no validated-plan.md on rejection" \
  "[ ! -f '$repoVb/.git/lcars/missions/$MID/validated-plan.md' ]"

# --- V3: scope questions → pause with awaiting-human state -----------------
#   3. Pauses with awaiting-human state when scope questions exist
repoP="$(new_repo_with_validate_mission)"; make_gh_stub "$repoP/gh"
export GH_LOG="$repoP/gh.log"; : >"$GH_LOG"
qP="$repoP/scope.txt"
cat >"$qP" <<'EOF'
Global or per-course leaderboard?
Should XP decay when a learner is inactive?
EOF
rcP=0
( cd "$repoP" && LCARS_GH_BIN="$repoP/gh" bash "$SCRIPT" validate-pause \
    --mission "$MID" --questions "$qP" >out.txt 2>&1 ) || rcP=$?
PEND="$repoP/.git/lcars/missions/$MID/pending.json"
sP="$(state_of "$repoP")"
check "V3. validate-pause exits 0" "[ '$rcP' -eq 0 ]"
check "V3. writes pending.json"                    "[ -f '$PEND' ]"
check "V3. pending.json carries the first question" \
  "grep -q 'per-course leaderboard' '$PEND'"
check "V3. pending.json carries the second question" \
  "grep -q 'XP decay' '$PEND'"
check "V3. sets awaitingHuman true in state.json" \
  "grep -q '\"awaitingHuman\": *true' '$sP'"
check "V3. sets pendingQuestion so the board shows it" \
  "grep -q '\"pendingQuestion\"' '$sP'"
check "V3. stays at the validate stage" \
  "grep -q '\"stage\": *\"validate\"' '$sP'"
check "V3. adds the lcars:awaiting-human label" \
  "grep -q 'add-label lcars:awaiting-human' '$repoP/gh.log'"
check "V3. leaves the lcars:validate label in place" \
  "! grep -q 'remove-label lcars:validate' '$repoP/gh.log'"
check "V3. prompts the captain to answer with lcars respond" \
  "grep -qi 'lcars respond' '$repoP/out.txt'"

# --- V4: resume after answers → advance, clearing the awaiting state -------
#   4. Resumes correctly after `lcars respond` provides answers.
# `lcars respond` (a later build) records answers and clears the gate; here we
# stand in for it by re-running validate-advance on the still-paused mission.
# It must resume cleanly: write the plan, drop the awaiting-human gate, advance.
planP="$repoP/plan.md"; write_plan "$planP"
: >"$repoP/gh.log"
rcR=0
( cd "$repoP" && LCARS_GH_BIN="$repoP/gh" bash "$SCRIPT" validate-advance \
    --mission "$MID" --plan "$planP" >outR.txt 2>&1 ) || rcR=$?
check "V4. resume exits 0" "[ '$rcR' -eq 0 ]"
check "V4. writes validated-plan.md on resume" \
  "[ -f '$repoP/.git/lcars/missions/$MID/validated-plan.md' ]"
check "V4. advances to the plan stage"        "grep -q '\"stage\": *\"plan\"' '$sP'"
check "V4. clears awaitingHuman"   "! grep -q '\"awaitingHuman\": *true' '$sP'"
check "V4. clears pendingQuestion" "! grep -q '\"pendingQuestion\"' '$sP'"
check "V4. removes pending.json"   "[ ! -f '$PEND' ]"
check "V4. removes the lcars:awaiting-human label" \
  "grep -q 'remove-label lcars:awaiting-human' '$repoP/gh.log'"

# --- Guard: Validate refuses to run on a non-validate mission --------------
repoVg="$(new_repo_with_mission)"; make_gh_stub "$repoVg/gh"   # still at align
export GH_LOG="$repoVg/gh.log"; : >"$GH_LOG"
write_plan "$repoVg/plan.md"
rcVg=0
( cd "$repoVg" && LCARS_GH_BIN="$repoVg/gh" bash "$SCRIPT" validate-advance \
    --mission "$MID" --plan "$repoVg/plan.md" >out.txt 2>&1 ) || rcVg=$?
check "guard. validate-advance refuses a non-validate mission" "[ '$rcVg' -ne 0 ]"
rcVp=0
( cd "$repoVg" && LCARS_GH_BIN="$repoVg/gh" bash "$SCRIPT" validate-pause \
    --mission "$MID" --questions /dev/null >out2.txt 2>&1 ) || rcVp=$?
check "guard. validate-pause refuses a non-validate mission" "[ '$rcVp' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars run: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
