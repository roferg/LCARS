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

# Build a repo with a mission already at stage "plan" — i.e. Validate has run
# (validated-plan.md exists) and the next Stage to execute is Plan.
new_repo_with_plan_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"plan"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  write_plan "$repo/.git/lcars/missions/$MID/validated-plan.md"
  echo "$repo"
}

# Write a well-formed plan.json (the Planning LLM's ticket list) to a path.
# Canonical shape: a JSON array of ticket objects, one field per line, with
# acceptanceCriteria and dependencies as inline single-line arrays. t-002
# depends on t-001 to exercise the dependency cross-check.
write_plan_json() { # file
  cat >"$1" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Add data-theme attribute and CSS variable wiring",
    "description": "Flip a data-theme attribute on <html> and define the dark token set end-to-end.",
    "acceptanceCriteria": ["Setting data-theme=dark recolours the page via existing --color-* tokens"],
    "estimatedLoc": 120,
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle and persist the choice",
    "description": "Render a toggle that writes the choice to localStorage and restores it on load.",
    "acceptanceCriteria": ["Toggling persists across reload", "Default follows prefers-color-scheme"],
    "estimatedLoc": 90,
    "dependencies": ["t-001"]
  }
]
EOF
}

# Build a repo with a mission already at stage "plan-review" — i.e. Plan has run
# (plan.json exists) and the next Stage to execute is Plan Review.
new_repo_with_plan_review_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"plan-review"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  write_plan_json "$repo/.git/lcars/missions/$MID/plan.json"
  echo "$repo"
}

# Write a passing reviewer verdict — all tickets cleared review, no issues.
write_verdict_pass() { # file
  cat >"$1" <<'EOF'
{
  "passed": true,
  "issues": []
}
EOF
}

# Write a failing reviewer verdict — one oversized ticket and one horizontal
# slice. Canonical one-issue-per-line shape so the objection text is parseable.
write_verdict_fail() { # file
  cat >"$1" <<'EOF'
{
  "passed": false,
  "issues": [
    { "ticketId": "t-001", "objection": "Oversized: estimated ~450 LoC; split into smaller slices." },
    { "ticketId": "t-002", "objection": "Horizontal slice — only touches the data layer, no UI." }
  ]
}
EOF
}

# Write a well-formed approved-plan.json (Plan Review's approved ticket list).
# Four tickets exercising the wave algorithm: t-001 and t-002 have no
# dependencies (wave 1); t-003 depends on t-001 and t-004 on both t-001 and
# t-002 (wave 2).
write_approved_plan_json() { # file
  cat >"$1" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Add the data-theme attribute and dark token set",
    "description": "Flip data-theme on <html> and wire the dark --color-* tokens end-to-end.",
    "acceptanceCriteria": ["Setting data-theme=dark recolours the page"],
    "estimatedLoc": 120,
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle control",
    "description": "Render a toggle in the nav that emits a theme-change event.",
    "acceptanceCriteria": ["Clicking the toggle flips the active theme"],
    "estimatedLoc": 70,
    "dependencies": []
  },
  {
    "id": "t-003",
    "title": "Persist the theme choice across reloads",
    "description": "Write the chosen theme to localStorage and restore it on load.",
    "acceptanceCriteria": ["Choice survives a reload", "Defaults to prefers-color-scheme"],
    "estimatedLoc": 80,
    "dependencies": ["t-001"]
  },
  {
    "id": "t-004",
    "title": "Show the active theme on the dashboard",
    "description": "Surface the active theme name on the learner dashboard.",
    "acceptanceCriteria": ["Dashboard shows the active theme"],
    "estimatedLoc": 60,
    "dependencies": ["t-001", "t-002"]
  }
]
EOF
}

# Build a repo with a mission at stage "schedule" — Plan Review passed and
# approved-plan.json exists; the next Stage to execute is Schedule.
new_repo_with_schedule_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"schedule"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  write_approved_plan_json "$repo/.git/lcars/missions/$MID/approved-plan.json"
  echo "$repo"
}

# A fake `gh` for the Schedule stage. Like make_gh_stub, but `gh issue create`
# echoes a freshly-numbered issue URL (101, 102, …) to stdout so the script can
# read the new issue number back, the way real gh prints the created issue URL.
# Each invocation is logged to $GH_LOG as a single line (newlines in the issue
# body are folded out so the log stays one-line-per-call).
make_gh_stub_schedule() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  n=101
  [ -f "$GH_SEQ" ] && n=$(( $(cat "$GH_SEQ") + 1 ))
  echo "$n" >"$GH_SEQ"
  echo "https://github.com/acme/repo/issues/$n"
fi
exit 0
EOF
  chmod +x "$1"
}

# Extract the wave number a ticket id was placed into, by scanning waves.json.
wave_of() { # waves.json  ticket-id
  awk -v want="$2" '
    /"wave":/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    $0 ~ ("\"id\": \"" want "\"") { print cur; exit }
  ' "$1"
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
echo "lcars run — Plan stage"

# --- P1/P4: well-formed plan.json → install it, advance to plan-review ------
# plan-save takes the Planning LLM's ticket list, validates it, writes it to
# plan.json, and advances the Mission. The four Plan behaviours, in order:
#   1. Produces plan.json with the correct shape for each ticket
#   2. Each ticket has at least one acceptance criterion
#   3. All dependency references point to valid ticket ids in the same plan
#   4. Advances to the plan-review stage
repoPL="$(new_repo_with_plan_mission)"; make_gh_stub "$repoPL/gh"
export GH_LOG="$repoPL/gh.log"; : >"$GH_LOG"
planJSON="$repoPL/plan.json"; write_plan_json "$planJSON"
rcPL=0
( cd "$repoPL" && LCARS_GH_BIN="$repoPL/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$planJSON" >out.txt 2>&1 ) || rcPL=$?
PLANJSON_OUT="$repoPL/.git/lcars/missions/$MID/plan.json"
check "P. plan-save exits 0 on a well-formed plan" "[ '$rcPL' -eq 0 ]"
check "P1. writes plan.json"                 "[ -f '$PLANJSON_OUT' ]"
check "P1. plan.json carries both tickets"   "grep -q 't-001' '$PLANJSON_OUT' && grep -q 't-002' '$PLANJSON_OUT'"
check "P4. advances the stage to plan-review" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repoPL")'"
check "P4. relabels plan → plan-review (adds lcars:plan-review)" \
  "grep -q 'add-label lcars:plan-review' '$repoPL/gh.log'"
check "P4. relabels plan → plan-review (removes lcars:plan)" \
  "grep -q 'remove-label lcars:plan' '$repoPL/gh.log'"

# --- P1: a ticket missing a required field is rejected; nothing moves -------
# Shape contract: every ticket needs id, title, description, acceptanceCriteria,
# estimatedLoc, dependencies. Here t-002 is missing its title.
repoPLb="$(new_repo_with_plan_mission)"; make_gh_stub "$repoPLb/gh"
export GH_LOG="$repoPLb/gh.log"; : >"$GH_LOG"
cat >"$repoPLb/bad.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedLoc": 120,
    "dependencies": []
  },
  {
    "id": "t-002",
    "description": "A ticket with no title field.",
    "acceptanceCriteria": ["something observable"],
    "estimatedLoc": 90,
    "dependencies": []
  }
]
EOF
rcPLb=0
( cd "$repoPLb" && LCARS_GH_BIN="$repoPLb/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoPLb/bad.json" >outB.txt 2>&1 ) || rcPLb=$?
check "P1. rejects a ticket missing a required field" "[ '$rcPLb' -ne 0 ]"
check "P1. does not advance on a malformed ticket" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoPLb")'"
check "P1. writes no plan.json on rejection" \
  "[ ! -f '$repoPLb/.git/lcars/missions/$MID/plan.json' ]"

# --- P2: a ticket with no acceptance criterion is rejected -----------------
# Testability contract: every ticket needs at least one observable acceptance
# criterion. Here t-001's acceptanceCriteria array is empty.
repoPLc="$(new_repo_with_plan_mission)"; make_gh_stub "$repoPLc/gh"
export GH_LOG="$repoPLc/gh.log"; : >"$GH_LOG"
cat >"$repoPLc/noac.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": [],
    "estimatedLoc": 120,
    "dependencies": []
  }
]
EOF
rcPLc=0
( cd "$repoPLc" && LCARS_GH_BIN="$repoPLc/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoPLc/noac.json" >outC.txt 2>&1 ) || rcPLc=$?
check "P2. rejects a ticket with no acceptance criterion" "[ '$rcPLc' -ne 0 ]"
check "P2. does not advance when a ticket has no criterion" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoPLc")'"

# --- P3: a dependency on an unknown ticket id is rejected ------------------
# Dependency-graph contract: every dependency must reference a ticket id that
# exists in this same plan. Here t-001 depends on t-099, which is not present.
repoPLd="$(new_repo_with_plan_mission)"; make_gh_stub "$repoPLd/gh"
export GH_LOG="$repoPLd/gh.log"; : >"$GH_LOG"
cat >"$repoPLd/dangling.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedLoc": 120,
    "dependencies": ["t-099"]
  }
]
EOF
rcPLd=0
( cd "$repoPLd" && LCARS_GH_BIN="$repoPLd/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoPLd/dangling.json" >outD.txt 2>&1 ) || rcPLd=$?
check "P3. rejects a dependency on an unknown ticket id" "[ '$rcPLd' -ne 0 ]"
check "P3. names the offending dependency in the error" \
  "grep -q 't-099' '$repoPLd/outD.txt'"
check "P3. does not advance on a dangling dependency" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoPLd")'"
# but a dependency that DOES resolve (t-002 → t-001) is accepted — proven by
# the happy-path tracer (repoPL) above, whose t-002 depends on t-001.

# --- Guard: Plan refuses to run on a non-plan mission ----------------------
repoPLg="$(new_repo_with_mission)"; make_gh_stub "$repoPLg/gh"   # still at align
export GH_LOG="$repoPLg/gh.log"; : >"$GH_LOG"
write_plan_json "$repoPLg/plan.json"
rcPLg=0
( cd "$repoPLg" && LCARS_GH_BIN="$repoPLg/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoPLg/plan.json" >out.txt 2>&1 ) || rcPLg=$?
check "guard. plan-save refuses a non-plan mission" "[ '$rcPLg' -ne 0 ]"

# ==========================================================================
echo
echo "lcars run — Plan Review stage"

# A fresh reviewer (Claude, per SKILL.md) audits plan.json — and ONLY plan.json,
# no prd.md or validated-plan.md — and emits a verdict { passed, issues }.
# review-save takes that verdict and does the mechanical branching. The six
# behaviours from the build order, in order:
#   1. Passes a plan where all tickets are valid vertical slices
#   2. Returns objections for oversized tickets
#   3. Returns objections for horizontal slice tickets
#   4. Increments the round counter and loops back to plan on failure
#   5. Escalates to the human after 3 failed rounds
#   6. Reviewer session does not receive prd.md or validated-plan.md

# --- PR1: a passing verdict → approve, advance to schedule -----------------
repoPR="$(new_repo_with_plan_review_mission)"; make_gh_stub "$repoPR/gh"
export GH_LOG="$repoPR/gh.log"; : >"$GH_LOG"
vpass="$repoPR/verdict.json"; write_verdict_pass "$vpass"
rcPR=0
( cd "$repoPR" && LCARS_GH_BIN="$repoPR/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$vpass" >out.txt 2>&1 ) || rcPR=$?
APPROVED="$repoPR/.git/lcars/missions/$MID/approved-plan.json"
check "PR1. review-save exits 0 on a passing plan" "[ '$rcPR' -eq 0 ]"
check "PR1. writes approved-plan.json"             "[ -f '$APPROVED' ]"
check "PR1. approved-plan.json copies the tickets"  "grep -q 't-001' '$APPROVED' && grep -q 't-002' '$APPROVED'"
check "PR1. advances the stage to schedule" \
  "grep -q '\"stage\": *\"schedule\"' '$(state_of "$repoPR")'"
check "PR1. relabels plan-review → schedule (adds lcars:schedule)" \
  "grep -q 'add-label lcars:schedule' '$repoPR/gh.log'"
check "PR1. relabels plan-review → schedule (removes lcars:plan-review)" \
  "grep -q 'remove-label lcars:plan-review' '$repoPR/gh.log'"

# --- PR2/PR3/PR4: a failing verdict → log objections, loop back to plan -----
repoPRf="$(new_repo_with_plan_review_mission)"; make_gh_stub "$repoPRf/gh"
export GH_LOG="$repoPRf/gh.log"; : >"$GH_LOG"
vfail="$repoPRf/verdict.json"; write_verdict_fail "$vfail"
rcPRf=0
( cd "$repoPRf" && LCARS_GH_BIN="$repoPRf/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$vfail" >out.txt 2>&1 ) || rcPRf=$?
sPRf="$(state_of "$repoPRf")"
LOG1="$repoPRf/.git/lcars/missions/$MID/plan-review-1.json"
check "PR. review-save exits 0 on a failing plan" "[ '$rcPRf' -eq 0 ]"
check "PR. logs the round's objections to plan-review-1.json" "[ -f '$LOG1' ]"
check "PR2. logs the oversized-ticket objection"      "grep -q 'Oversized' '$LOG1'"
check "PR3. logs the horizontal-slice objection"      "grep -q 'Horizontal slice' '$LOG1'"
check "PR4. increments planReviewRound to 1" \
  "grep -q '\"planReviewRound\": *1' '$sPRf'"
check "PR4. loops the stage back to plan" \
  "grep -q '\"stage\": *\"plan\"' '$sPRf'"
check "PR4. relabels plan-review → plan (adds lcars:plan)" \
  "grep -q 'add-label lcars:plan ' '$repoPRf/gh.log' || grep -q 'add-label lcars:plan$' '$repoPRf/gh.log'"
check "PR4. relabels plan-review → plan (removes lcars:plan-review)" \
  "grep -q 'remove-label lcars:plan-review' '$repoPRf/gh.log'"
check "PR4. does not escalate on the first failure" \
  "! grep -q '\"awaitingHuman\": *true' '$sPRf'"

# second failure: Plan re-ran and re-advanced to plan-review — simulate that by
# resetting the stage — then fail again. The round counter must reach 2.
sed 's/"plan"/"plan-review"/' "$sPRf" >"$repoPRf/s.tmp" && mv "$repoPRf/s.tmp" "$sPRf"
: >"$repoPRf/gh.log"
rcPRf2=0
( cd "$repoPRf" && LCARS_GH_BIN="$repoPRf/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$vfail" >out2.txt 2>&1 ) || rcPRf2=$?
LOG2="$repoPRf/.git/lcars/missions/$MID/plan-review-2.json"
check "PR4. a second failure increments planReviewRound to 2" \
  "grep -q '\"planReviewRound\": *2' '$sPRf'"
check "PR4. logs the second round to plan-review-2.json" "[ -f '$LOG2' ]"
check "PR4. still loops back to plan on round 2" \
  "grep -q '\"stage\": *\"plan\"' '$sPRf'"
check "PR4. still does not escalate on round 2" \
  "! grep -q '\"awaitingHuman\": *true' '$sPRf'"

# --- PR5: the third failure escalates to the human -------------------------
sed 's/"plan"/"plan-review"/' "$sPRf" >"$repoPRf/s.tmp" && mv "$repoPRf/s.tmp" "$sPRf"
: >"$repoPRf/gh.log"
rcPRf3=0
( cd "$repoPRf" && LCARS_GH_BIN="$repoPRf/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$vfail" >out3.txt 2>&1 ) || rcPRf3=$?
PENDPR="$repoPRf/.git/lcars/missions/$MID/pending.json"
check "PR5. review-save exits 0 on the escalating round" "[ '$rcPRf3' -eq 0 ]"
check "PR5. increments planReviewRound to 3" \
  "grep -q '\"planReviewRound\": *3' '$sPRf'"
check "PR5. sets awaitingHuman true" \
  "grep -q '\"awaitingHuman\": *true' '$sPRf'"
check "PR5. sets pendingQuestion so the board shows it" \
  "grep -q '\"pendingQuestion\"' '$sPRf'"
check "PR5. stays in the plan-review stage (does not loop to plan)" \
  "grep -q '\"stage\": *\"plan-review\"' '$sPRf'"
check "PR5. writes the unresolved issues to pending.json" \
  "[ -f '$PENDPR' ] && grep -q 'Oversized' '$PENDPR'"
check "PR5. adds the lcars:awaiting-human label" \
  "grep -q 'add-label lcars:awaiting-human' '$repoPRf/gh.log'"
check "PR5. prompts the captain to override or redirect via lcars respond" \
  "grep -qi 'lcars respond' '$repoPRf/out3.txt'"

# --- PR6: the reviewer stage is independent of prd.md / validated-plan.md ---
# Mechanically prove the contract: with both the PRD and the validated plan
# removed, review-save still works — Plan Review never reads the spec, mirroring
# the SKILL.md guarantee that the fresh reviewer session receives ONLY plan.json.
repoPRi="$(new_repo_with_plan_review_mission)"; make_gh_stub "$repoPRi/gh"
export GH_LOG="$repoPRi/gh.log"; : >"$GH_LOG"
rm -f "$repoPRi/.git/lcars/missions/$MID/prd.md" \
      "$repoPRi/.git/lcars/missions/$MID/validated-plan.md"
write_verdict_pass "$repoPRi/verdict.json"
rcPRi=0
( cd "$repoPRi" && LCARS_GH_BIN="$repoPRi/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$repoPRi/verdict.json" >out.txt 2>&1 ) || rcPRi=$?
check "PR6. Plan Review never reads prd.md/validated-plan.md (works without them)" \
  "[ '$rcPRi' -eq 0 ]"

# a failed verdict that lists no issues is malformed — rejected, nothing moves
repoPRm="$(new_repo_with_plan_review_mission)"; make_gh_stub "$repoPRm/gh"
export GH_LOG="$repoPRm/gh.log"; : >"$GH_LOG"
printf '{\n  "passed": false,\n  "issues": []\n}\n' >"$repoPRm/bad.json"
rcPRm=0
( cd "$repoPRm" && LCARS_GH_BIN="$repoPRm/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$repoPRm/bad.json" >out.txt 2>&1 ) || rcPRm=$?
check "PR. rejects a failed verdict that lists no issues" "[ '$rcPRm' -ne 0 ]"
check "PR. does not advance on a malformed verdict" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repoPRm")'"

# --- Guard: Plan Review refuses to run on a non-plan-review mission ---------
repoPRg="$(new_repo_with_mission)"; make_gh_stub "$repoPRg/gh"   # still at align
export GH_LOG="$repoPRg/gh.log"; : >"$GH_LOG"
write_verdict_pass "$repoPRg/verdict.json"
rcPRg=0
( cd "$repoPRg" && LCARS_GH_BIN="$repoPRg/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$repoPRg/verdict.json" >out.txt 2>&1 ) || rcPRg=$?
check "guard. review-save refuses a non-plan-review mission" "[ '$rcPRg' -ne 0 ]"

# ==========================================================================
echo
echo "lcars run — Schedule stage"

# The Schedule stage is purely mechanical (no LLM): build the dependency graph
# from approved-plan.json, group tickets into sequential waves by topological
# order, open one GitHub sub-issue per ticket, and advance to Implement. The
# five behaviours from the build order, in order:
#   1. Places tickets with no dependencies in wave 1
#   2. Places tickets whose deps are all in wave N into wave N+1
#   3. Detects circular dependencies and errors clearly
#   4. Creates one GitHub issue per ticket with correct labels
#   5. Saves GitHub issue numbers into waves.json

repoS="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoS/gh"
export GH_LOG="$repoS/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoS/gh.seq"; rm -f "$GH_SEQ"
rcS=0
( cd "$repoS" && LCARS_GH_BIN="$repoS/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >out.txt 2>&1 ) || rcS=$?
WAVES="$repoS/.git/lcars/missions/$MID/waves.json"
check "S. schedule exits 0 on a well-formed approved plan" "[ '$rcS' -eq 0 ]"
check "S. writes waves.json" "[ -f '$WAVES' ]"

# --- Behaviour 1: no-dependency tickets land in wave 1 ---------------------
wS1a="$(wave_of "$WAVES" t-001)"
wS1b="$(wave_of "$WAVES" t-002)"
check "S1. t-001 (no deps) is in wave 1" "[ '$wS1a' = '1' ]"
check "S1. t-002 (no deps) is in wave 1" "[ '$wS1b' = '1' ]"

# --- Behaviour 2: a ticket whose deps are all in wave 1 lands in wave 2 -----
wS2a="$(wave_of "$WAVES" t-003)"
wS2b="$(wave_of "$WAVES" t-004)"
check "S2. t-003 (dep t-001 in wave 1) is in wave 2" "[ '$wS2a' = '2' ]"
check "S2. t-004 (deps t-001,t-002 in wave 1) is in wave 2" "[ '$wS2b' = '2' ]"

# --- Behaviour 4: one GitHub issue per ticket, each labelled correctly ------
ncreate="$(grep -c 'issue create' "$GH_LOG")"
check "S4. creates one GitHub issue per ticket (4)" "[ '$ncreate' = '4' ]"
check "S4. labels each sub-issue lcars:implement and the mission type" \
  "grep -q 'label lcars:implement,lcars:feature' '$GH_LOG'"

# --- Behaviour 5: the created issue numbers are saved into waves.json -------
check "S5. saves issue number 101 into waves.json" "grep -q '\"issue\": *101' '$WAVES'"
check "S5. saves issue number 104 into waves.json" "grep -q '\"issue\": *104' '$WAVES'"

# advances to Implement; the parent issue is relabelled schedule → implement
check "S. advances the stage to implement" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoS")'"
check "S. relabels schedule → implement (adds lcars:implement)" \
  "grep -q 'add-label lcars:implement' '$repoS/gh.log'"
check "S. relabels schedule → implement (removes lcars:schedule)" \
  "grep -q 'remove-label lcars:schedule' '$repoS/gh.log'"

# --- Behaviour 3: a circular dependency is detected; nothing moves ----------
repoSc="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoSc/gh"
export GH_LOG="$repoSc/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSc/gh.seq"; rm -f "$GH_SEQ"
cat >"$repoSc/.git/lcars/missions/$MID/approved-plan.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Ticket one",
    "description": "Depends on t-002.",
    "acceptanceCriteria": ["does a thing"],
    "estimatedLoc": 50,
    "dependencies": ["t-002"]
  },
  {
    "id": "t-002",
    "title": "Ticket two",
    "description": "Depends on t-001.",
    "acceptanceCriteria": ["does another thing"],
    "estimatedLoc": 50,
    "dependencies": ["t-001"]
  }
]
EOF
rcSc=0
( cd "$repoSc" && LCARS_GH_BIN="$repoSc/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >outC.txt 2>&1 ) || rcSc=$?
check "S3. schedule exits non-zero on a circular dependency" "[ '$rcSc' -ne 0 ]"
check "S3. reports the cycle clearly" \
  "grep -qi 'circular\\|cycle' '$repoSc/outC.txt'"
check "S3. names the tickets caught in the cycle" \
  "grep -q 't-001' '$repoSc/outC.txt' && grep -q 't-002' '$repoSc/outC.txt'"
check "S3. does not advance on a cycle (stays at schedule)" \
  "grep -q '\"stage\": *\"schedule\"' '$(state_of "$repoSc")'"
check "S3. writes no waves.json on a cycle" \
  "[ ! -f '$repoSc/.git/lcars/missions/$MID/waves.json' ]"
check "S3. creates no GitHub issues on a cycle" \
  "! grep -q 'issue create' '$repoSc/gh.log'"

# --- Guard: Schedule refuses to run on a non-schedule mission --------------
repoSg="$(new_repo_with_mission)"; make_gh_stub_schedule "$repoSg/gh"   # at align
export GH_LOG="$repoSg/gh.log"; : >"$GH_LOG"
rcSg=0
( cd "$repoSg" && LCARS_GH_BIN="$repoSg/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >out.txt 2>&1 ) || rcSg=$?
check "guard. schedule refuses a non-schedule mission" "[ '$rcSg' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars run: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
