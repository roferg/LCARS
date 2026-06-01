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
echo "lcars run — Implement stage"

# The Implement stage processes waves sequentially; tickets within a wave run in
# parallel. Each ticket is built by two adversarially-separated LLM sessions
# (Claude, per SKILL.md): a Test Writer (Phase 1) that writes failing tests, then
# a fresh Implementer (Phase 2) that makes them pass. run.sh owns the mechanical,
# testable parts via four subcommands:
#
#   impl-save-tests   — quarantine the Test Writer's files to tickets/<id>/tests/
#   impl-save-result  — validate + save the Implementer's result.json, capping
#                       attempts at 5 and flagging the human on a failure
#   impl-status       — report the current wave and its still-pending tickets
#   impl-advance      — when every ticket is green, advance to verify
#
# The seven behaviours from the build order, in order:
#   1. Test Writer produces (syntactically valid) test files — saved to tests/
#   2. Test Writer does not produce implementation code — output is quarantined
#   3. Implementer does not receive Test Writer session context — handoff is the
#      on-disk tests alone
#   4. Implementer iterates until tests pass (up to 5 attempts) — recorded
#   5. Flags the ticket for human if tests still fail after 5 attempts
#   6. Processes the next wave only after the current wave is fully complete
#   7. Updates the stage to verify when all waves are done

# Write the canonical waves.json (the shape Schedule's emit_waves_json produces):
# wave 1 holds t-001/t-002 (no deps), wave 2 holds t-003/t-004.
write_waves_json() { # file
  cat >"$1" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 101
      },
      {
        "id": "t-002",
        "issue": 102
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-003",
        "issue": 103
      },
      {
        "id": "t-004",
        "issue": 104
      }
    ]
  }
]
EOF
}

# Write a result.json for a ticket: id, passed, attempts, summary.
write_result() { # file ticketId passed attempts
  cat >"$1" <<EOF
{
  "ticketId": "$2",
  "passed": $3,
  "attempts": $4,
  "summary": "Implemented the slice; suite is $([ "$3" = true ] && echo green || echo red)."
}
EOF
}

# Build a repo with a mission at stage "implement" — Schedule has run, so
# waves.json and approved-plan.json exist; the next Stage to execute is Implement.
new_repo_with_implement_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"implement"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  local m="$repo/.git/lcars/missions/$MID"
  write_approved_plan_json "$m/approved-plan.json"
  write_waves_json "$m/waves.json"
  echo "$repo"
}

# Drive every ticket in a wave to a green result (tests saved + passing result),
# the way the Test Writer / Implementer pair would. Used to set up later waves.
finish_ticket_green() { # repo ticketId script gh
  local repo="$1" tid="$2" script="$3" gh="$4"
  local td; td="$(mktemp -d)"; printf 'test stub\n' >"$td/${tid}.test"
  ( cd "$repo" && LCARS_GH_BIN="$gh" bash "$script" impl-save-tests \
      --mission "$MID" --ticket "$tid" --tests "$td" >/dev/null 2>&1 )
  local rf; rf="$(mktemp)"; write_result "$rf" "$tid" true 2
  ( cd "$repo" && LCARS_GH_BIN="$gh" bash "$script" impl-save-result \
      --mission "$MID" --ticket "$tid" --result "$rf" >/dev/null 2>&1 )
}

# --- I1/I2: Test Writer's files are saved, quarantined to tests/ -----------
#   1. Test Writer produces test files — saved to tickets/<id>/tests/
#   2. Test Writer does not produce implementation code — output is quarantined
repoI="$(new_repo_with_implement_mission)"; make_gh_stub "$repoI/gh"
export GH_LOG="$repoI/gh.log"; : >"$GH_LOG"
testsI="$repoI/tw-out"; mkdir -p "$testsI"
printf 'describe("t-001", () => { it("recolours", () => expect(false).toBe(true)) })\n' \
  >"$testsI/theme.test.js"
rcI=0
( cd "$repoI" && LCARS_GH_BIN="$repoI/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$testsI" >out.txt 2>&1 ) || rcI=$?
TDIR="$repoI/.git/lcars/missions/$MID/tickets/t-001/tests"
check "I. impl-save-tests exits 0" "[ '$rcI' -eq 0 ]"
check "I1. saves the Test Writer's file under tickets/t-001/tests/" \
  "[ -f '$TDIR/theme.test.js' ]"
check "I2. quarantines test output — nothing written outside tests/" \
  "[ ! -e '$repoI/.git/lcars/missions/$MID/tickets/t-001/result.json' ]"

# an empty Test Writer output is refused — Phase 1 must produce failing tests
repoIe="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIe/gh"
export GH_LOG="$repoIe/gh.log"; : >"$GH_LOG"
emptyI="$repoIe/empty"; mkdir -p "$emptyI"
rcIe=0
( cd "$repoIe" && LCARS_GH_BIN="$repoIe/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$emptyI" >out.txt 2>&1 ) || rcIe=$?
check "I1. refuses an empty Test Writer output" "[ '$rcIe' -ne 0 ]"
check "I1. writes no tests dir when the Test Writer produced nothing" \
  "[ ! -d '$repoIe/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# --- I3/I4: Implementer's result is saved, recording the attempt count -----
#   3. Implementer's only Phase-1 handoff is the on-disk tests (tests-first)
#   4. Implementer iterates until tests pass — attempts (up to 5) is recorded
repoIr="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIr/gh"
export GH_LOG="$repoIr/gh.log"; : >"$GH_LOG"
twIr="$repoIr/tw"; mkdir -p "$twIr"; printf 'failing test\n' >"$twIr/t.test.js"
( cd "$repoIr" && LCARS_GH_BIN="$repoIr/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIr" >/dev/null 2>&1 )
resIr="$repoIr/result.json"; write_result "$resIr" t-001 true 3
rcIr=0
( cd "$repoIr" && LCARS_GH_BIN="$repoIr/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resIr" >out.txt 2>&1 ) || rcIr=$?
RESOUT="$repoIr/.git/lcars/missions/$MID/tickets/t-001/result.json"
check "I. impl-save-result exits 0 on a passing ticket" "[ '$rcIr' -eq 0 ]"
check "I4. saves result.json under tickets/t-001/"  "[ -f '$RESOUT' ]"
check "I4. records the passed flag"     "grep -q '\"passed\": *true' '$RESOUT'"
check "I4. records the attempt count"   "grep -q '\"attempts\": *3' '$RESOUT'"

# the result must arrive AFTER the tests — the Implementer's sole handoff from
# the Test Writer is the on-disk tests, so a result with no saved tests is refused
repoIo="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIo/gh"
export GH_LOG="$repoIo/gh.log"; : >"$GH_LOG"
resIo="$repoIo/result.json"; write_result "$resIo" t-001 true 2
rcIo=0
( cd "$repoIo" && LCARS_GH_BIN="$repoIo/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resIo" >out.txt 2>&1 ) || rcIo=$?
check "I3. refuses a result before the Test Writer's tests exist" "[ '$rcIo' -ne 0 ]"

# attempts over the 5-cap is impossible — the Implementer flags the human at 5,
# so a result claiming 6 attempts is refused and nothing is saved
repoIc="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIc/gh"
export GH_LOG="$repoIc/gh.log"; : >"$GH_LOG"
twIc="$repoIc/tw"; mkdir -p "$twIc"; printf 'failing test\n' >"$twIc/t.test.js"
( cd "$repoIc" && LCARS_GH_BIN="$repoIc/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIc" >/dev/null 2>&1 )
resIc="$repoIc/result.json"; write_result "$resIc" t-001 true 6
rcIc=0
( cd "$repoIc" && LCARS_GH_BIN="$repoIc/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resIc" >out.txt 2>&1 ) || rcIc=$?
check "I4. refuses an attempt count over the cap of 5" "[ '$rcIc' -ne 0 ]"
check "I4. writes no result.json when over the cap" \
  "[ ! -f '$repoIc/.git/lcars/missions/$MID/tickets/t-001/result.json' ]"

# a malformed result (missing summary) is refused; nothing saved
repoIm="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIm/gh"
export GH_LOG="$repoIm/gh.log"; : >"$GH_LOG"
twIm="$repoIm/tw"; mkdir -p "$twIm"; printf 'failing test\n' >"$twIm/t.test.js"
( cd "$repoIm" && LCARS_GH_BIN="$repoIm/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIm" >/dev/null 2>&1 )
printf '{ "ticketId": "t-001", "passed": true, "attempts": 2 }\n' >"$repoIm/bad.json"
rcIm=0
( cd "$repoIm" && LCARS_GH_BIN="$repoIm/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$repoIm/bad.json" >out.txt 2>&1 ) || rcIm=$?
check "I4. refuses a malformed result (missing a field)" "[ '$rcIm' -ne 0 ]"

# --- I5: a failing result after the cap flags the human --------------------
#   5. Flags the ticket for human if tests still fail after 5 attempts
repoIf="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIf/gh"
export GH_LOG="$repoIf/gh.log"; : >"$GH_LOG"
twIf="$repoIf/tw"; mkdir -p "$twIf"; printf 'failing test\n' >"$twIf/t.test.js"
( cd "$repoIf" && LCARS_GH_BIN="$repoIf/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIf" >/dev/null 2>&1 )
resIf="$repoIf/result.json"; write_result "$resIf" t-001 false 5
rcIf=0
( cd "$repoIf" && LCARS_GH_BIN="$repoIf/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resIf" >out.txt 2>&1 ) || rcIf=$?
sIf="$(state_of "$repoIf")"
PENDIf="$repoIf/.git/lcars/missions/$MID/pending.json"
check "I5. impl-save-result exits 0 on a flagged failure" "[ '$rcIf' -eq 0 ]"
check "I5. still records the failing result.json" \
  "[ -f '$repoIf/.git/lcars/missions/$MID/tickets/t-001/result.json' ]"
check "I5. sets awaitingHuman true" "grep -q '\"awaitingHuman\": *true' '$sIf'"
check "I5. sets pendingQuestion naming the ticket" \
  "grep -q '\"pendingQuestion\".*t-001' '$sIf'"
check "I5. stays at the implement stage (does not advance)" \
  "grep -q '\"stage\": *\"implement\"' '$sIf'"
check "I5. writes the blocker to pending.json" \
  "[ -f '$PENDIf' ] && grep -q 't-001' '$PENDIf'"
check "I5. adds the lcars:awaiting-human label" \
  "grep -q 'add-label lcars:awaiting-human' '$repoIf/gh.log'"
check "I5. prompts the captain to resolve via lcars respond" \
  "grep -qi 'lcars respond' '$repoIf/out.txt'"

# --- I6: impl-status reports the current wave; later waves stay hidden ------
#   6. Processes the next wave only after the current wave is fully complete
repoIs="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIs/gh"
export GH_LOG="$repoIs/gh.log"; : >"$GH_LOG"

# fresh mission: nothing built yet → the current wave is wave 1, and wave 2's
# tickets must NOT be surfaced (the sequential-wave gate).
( cd "$repoIs" && LCARS_GH_BIN="$repoIs/gh" bash "$SCRIPT" impl-status \
    --mission "$MID" >st1.txt 2>&1 )
check "I6. current wave is wave 1 before anything is built" \
  "grep -qi 'wave 1' '$repoIs/st1.txt'"
check "I6. lists wave 1's pending tickets" \
  "grep -q 't-001' '$repoIs/st1.txt' && grep -q 't-002' '$repoIs/st1.txt'"
check "I6. does NOT reveal a later wave's tickets while wave 1 is open" \
  "! grep -q 't-003' '$repoIs/st1.txt' && ! grep -q 't-004' '$repoIs/st1.txt'"

# finish wave 1 (both tickets green) → the current wave advances to wave 2
finish_ticket_green "$repoIs" t-001 "$SCRIPT" "$repoIs/gh"
finish_ticket_green "$repoIs" t-002 "$SCRIPT" "$repoIs/gh"
( cd "$repoIs" && LCARS_GH_BIN="$repoIs/gh" bash "$SCRIPT" impl-status \
    --mission "$MID" >st2.txt 2>&1 )
check "I6. current wave advances to wave 2 once wave 1 is all green" \
  "grep -qi 'wave 2' '$repoIs/st2.txt'"
check "I6. now lists wave 2's pending tickets" \
  "grep -q 't-003' '$repoIs/st2.txt' && grep -q 't-004' '$repoIs/st2.txt'"

# finish wave 2 too → status reports the Mission is complete (ready to advance)
finish_ticket_green "$repoIs" t-003 "$SCRIPT" "$repoIs/gh"
finish_ticket_green "$repoIs" t-004 "$SCRIPT" "$repoIs/gh"
( cd "$repoIs" && LCARS_GH_BIN="$repoIs/gh" bash "$SCRIPT" impl-status \
    --mission "$MID" >st3.txt 2>&1 )
check "I6. reports complete when every wave is green" \
  "grep -qi 'complete' '$repoIs/st3.txt'"

# --- I7: impl-advance moves to verify only when every wave is green ---------
#   7. Updates the stage to verify when all waves are done
# refuses while work remains — a half-built mission must not advance
repoIa="$(new_repo_with_implement_mission)"; make_gh_stub "$repoIa/gh"
export GH_LOG="$repoIa/gh.log"; : >"$GH_LOG"
finish_ticket_green "$repoIa" t-001 "$SCRIPT" "$repoIa/gh"   # only 1 of 4 green
rcIaEarly=0
( cd "$repoIa" && LCARS_GH_BIN="$repoIa/gh" bash "$SCRIPT" impl-advance \
    --mission "$MID" >early.txt 2>&1 ) || rcIaEarly=$?
check "I7. refuses to advance while tickets are unfinished" "[ '$rcIaEarly' -ne 0 ]"
check "I7. stays at implement when work remains" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoIa")'"

# finish every ticket → advance to verify, relabel implement → verify
finish_ticket_green "$repoIa" t-002 "$SCRIPT" "$repoIa/gh"
finish_ticket_green "$repoIa" t-003 "$SCRIPT" "$repoIa/gh"
finish_ticket_green "$repoIa" t-004 "$SCRIPT" "$repoIa/gh"
: >"$repoIa/gh.log"
rcIa=0
( cd "$repoIa" && LCARS_GH_BIN="$repoIa/gh" bash "$SCRIPT" impl-advance \
    --mission "$MID" >out.txt 2>&1 ) || rcIa=$?
check "I7. impl-advance exits 0 when every wave is green" "[ '$rcIa' -eq 0 ]"
check "I7. advances the stage to verify" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoIa")'"
check "I7. relabels implement → verify (adds lcars:verify)" \
  "grep -q 'add-label lcars:verify' '$repoIa/gh.log'"
check "I7. relabels implement → verify (removes lcars:implement)" \
  "grep -q 'remove-label lcars:implement' '$repoIa/gh.log'"

# --- Guard: Implement subcommands refuse a non-implement mission -----------
repoIg="$(new_repo_with_mission)"; make_gh_stub "$repoIg/gh"   # still at align
export GH_LOG="$repoIg/gh.log"; : >"$GH_LOG"
twIg="$repoIg/tw"; mkdir -p "$twIg"; printf 'x\n' >"$twIg/t.test.js"
rcIg=0
( cd "$repoIg" && LCARS_GH_BIN="$repoIg/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIg" >out.txt 2>&1 ) || rcIg=$?
check "guard. impl-save-tests refuses a non-implement mission" "[ '$rcIg' -ne 0 ]"
rcIag=0
( cd "$repoIg" && LCARS_GH_BIN="$repoIg/gh" bash "$SCRIPT" impl-advance \
    --mission "$MID" >out2.txt 2>&1 ) || rcIag=$?
check "guard. impl-advance refuses a non-implement mission" "[ '$rcIag' -ne 0 ]"

# --- IC: a green ticket's produced files are committed to the mission branch -
# The Implementer writes real files into the working tree; impl-save-result must
# commit them to the Mission's branch (recorded in state.json) so the eventual
# PR has content. This needs a repo with a real commit + the recorded branch, so
# it's built from scratch rather than via new_repo_with_mission.
repoIC="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$repoIC" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init && git branch "lcars/$MID" )
BASEIC="$(cd "$repoIC" && git rev-parse --abbrev-ref HEAD)"
mIC="$repoIC/.git/lcars/missions/$MID"; mkdir -p "$mIC"
cat >"$mIC/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$BASEIC"
}
EOF
write_approved_plan_json "$mIC/approved-plan.json"
write_waves_json "$mIC/waves.json"
make_gh_stub "$repoIC/gh"; export GH_LOG="$repoIC/gh.log"; : >"$GH_LOG"
# Phase 1 — Test Writer's tests saved (the Implementer's only handoff).
twIC="$repoIC/tw"; mkdir -p "$twIC"; printf 'failing test\n' >"$twIC/t.test.js"
( cd "$repoIC" && LCARS_GH_BIN="$repoIC/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twIC" >/dev/null 2>&1 )
# Phase 2 — the Implementer leaves a real file in the working tree, then we save
# a passing result, which must commit that file to lcars/<id>.
printf 'export const theme = "dark";\n' >"$repoIC/theme.js"
resIC="$repoIC/result.json"; write_result "$resIC" t-001 true 2
rcIC=0
( cd "$repoIC" && LCARS_GH_BIN="$repoIC/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resIC" >"$repoIC/outIC.txt" 2>&1 ) || rcIC=$?
check "IC. impl-save-result exits 0 and commits the green ticket" "[ '$rcIC' -eq 0 ]"
check "IC. checks out the mission branch" \
  "[ \"\$(cd '$repoIC' && git rev-parse --abbrev-ref HEAD)\" = 'lcars/$MID' ]"
check "IC. commits the Implementer's file onto the branch" \
  "( cd '$repoIC' && git ls-tree -r --name-only HEAD | grep -q '^theme.js$' )"
check "IC. the commit is ahead of the base branch" \
  "[ \"\$(cd '$repoIC' && git rev-list --count $BASEIC..lcars/$MID)\" -ge 1 ]"

# ==========================================================================
echo
echo "lcars run — Verify stage"

# When every wave is green, Implement parks the Mission at "verify". `lcars run`
# then prints a summary the captain reads before deciding to ship or send back:
# the mission title, every completed ticket, and the test results — plus the two
# next moves (lcars approve / lcars feedback). verify-summary is read-only; the
# decision is the captain's. The one behaviour from the build order:
#   1. Prints the verify summary with all ticket results

# Seed every ticket green (tests + passing result), the shape Implement leaves
# behind, then park the mission at verify.
seed_verify_results() { # repo
  local repo="$1" m="$repo/.git/lcars/missions/$MID" tid
  for tid in t-001 t-002 t-003 t-004; do
    mkdir -p "$m/tickets/$tid/tests"; printf 'stub\n' >"$m/tickets/$tid/tests/$tid.test"
    write_result "$m/tickets/$tid/result.json" "$tid" true 2
  done
}
new_repo_with_verify_mission() {
  local repo; repo="$(new_repo_with_mission)"
  local s; s="$(state_of "$repo")"
  sed 's/"align"/"verify"/' "$s" >"$repo/s.tmp" && mv "$repo/s.tmp" "$s"
  local m="$repo/.git/lcars/missions/$MID"
  write_approved_plan_json "$m/approved-plan.json"
  write_waves_json "$m/waves.json"
  seed_verify_results "$repo"
  echo "$repo"
}

repoVR="$(new_repo_with_verify_mission)"; make_gh_stub "$repoVR/gh"
export GH_LOG="$repoVR/gh.log"; : >"$GH_LOG"
rcVR=0
( cd "$repoVR" && LCARS_GH_BIN="$repoVR/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >out.txt 2>&1 ) || rcVR=$?
check "VR1. verify-summary exits 0" "[ '$rcVR' -eq 0 ]"
check "VR1. prints the mission title" "grep -q 'Add dark mode' '$repoVR/out.txt'"
check "VR1. lists every completed ticket" \
  "grep -q 't-001' '$repoVR/out.txt' && grep -q 't-002' '$repoVR/out.txt' && grep -q 't-003' '$repoVR/out.txt' && grep -q 't-004' '$repoVR/out.txt'"
check "VR1. reports the test results (4/4 green)" "grep -q '4/4' '$repoVR/out.txt'"
check "VR1. prompts the captain to approve" "grep -q 'lcars approve' '$repoVR/out.txt'"
check "VR1. prompts the captain to send feedback" "grep -q 'lcars feedback' '$repoVR/out.txt'"
check "VR1. is read-only — stays at the verify stage" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoVR")'"

# --- Guard: verify-summary refuses a non-verify mission --------------------
repoVRg="$(new_repo_with_mission)"; make_gh_stub "$repoVRg/gh"   # still at align
export GH_LOG="$repoVRg/gh.log"; : >"$GH_LOG"
rcVRg=0
( cd "$repoVRg" && LCARS_GH_BIN="$repoVRg/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >out.txt 2>&1 ) || rcVRg=$?
check "guard. verify-summary refuses a non-verify mission" "[ '$rcVRg' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars run: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
