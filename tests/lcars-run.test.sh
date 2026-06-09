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
#   4. Updates the GitHub label correctly (lcars:align → lcars:validate)
#   5. Triggers a human prompt when > 20 questions are needed
#   6. A paused/escalated card shows its TRUE in-flight stage (lcars:research)
#
# The script takes its dependencies via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary (default: gh)
#
# Usage: bash tests/lcars-run.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

# These suites stub the cold-worker binary under the generic name `worker`. The
# CLI-spawn flags/tool names now live in worker-adapter.sh, keyed by a cli id
# that run.sh derives from the worker binary's basename (`claude` in production).
# Point that cli id at the claude adapter for the whole suite (like LCARS_GH_BIN
# selects a stubbed gh) so the generic `worker` stub drives the real claude flags.
export LCARS_WORKER_CLI="${LCARS_WORKER_CLI:-claude}"

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

# Mirror run.sh's json_escape (writer) so fixtures exercise true on-disk shape.
json_escape_like_run() { # raw-string -> JSON-escaped string body
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

set_state_title_json_escaped() { # repo raw-title
  local s esc tmp
  s="$(state_of "$1")"
  esc="$(json_escape_like_run "$2")"
  tmp="$1/s.tmp"
  TITLE_ESC="$esc" awk '
    /"title"[[:space:]]*:/ { print "  \"title\": \"" ENVIRON["TITLE_ESC"] "\","; next }
    { print }
  ' "$s" >"$tmp" && mv "$tmp" "$s"
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

## Rationale
Reusing the token layer avoids a parallel colour system, and localStorage keeps
the choice client-side without a schema change — the cheapest path to the PRD.
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
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "The token plumbing is the foundation every later slice paints on."
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle and persist the choice",
    "description": "Render a toggle that writes the choice to localStorage and restores it on load.",
    "acceptanceCriteria": ["Toggling persists across reload", "Default follows prefers-color-scheme"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 90,
    "dependencies": ["t-001"],
    "rationale": "Persistence is meaningless without the tokens, so it builds on t-001."
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
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Foundational token layer every later slice depends on."
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle control",
    "description": "Render a toggle in the nav that emits a theme-change event.",
    "acceptanceCriteria": ["Clicking the toggle flips the active theme"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 70,
    "dependencies": [],
    "rationale": "The control is independent of persistence, so it can build in parallel."
  },
  {
    "id": "t-003",
    "title": "Persist the theme choice across reloads",
    "description": "Write the chosen theme to localStorage and restore it on load.",
    "acceptanceCriteria": ["Choice survives a reload", "Defaults to prefers-color-scheme"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 80,
    "dependencies": ["t-001"],
    "rationale": "Persistence only matters once the tokens it restores exist."
  },
  {
    "id": "t-004",
    "title": "Show the active theme on the dashboard",
    "description": "Surface the active theme name on the learner dashboard.",
    "acceptanceCriteria": ["Dashboard shows the active theme"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 60,
    "dependencies": ["t-001", "t-002"],
    "rationale": "The dashboard readout needs both the tokens and the toggle wired."
  }
]
EOF
}

# A SINGLE-ticket approved plan — the Schedule fast-path case (BUG-005). One
# vertical slice, no dependencies. Schedule must NOT open a redundant sub-issue
# for this; it reuses the Mission's own issue instead.
write_single_ticket_plan_json() { # file
  cat >"$1" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Add the data-theme attribute and dark token set",
    "description": "Flip data-theme on <html> and wire the dark --color-* tokens end-to-end.",
    "acceptanceCriteria": ["Setting data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "The whole change is one cohesive slice — no decomposition needed."
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
# Native sub-issue nesting (Session 35): `gh api .../issues/<n> --jq .id`
# resolves a child's db id; the POST to .../sub_issues links it. Echo a db id
# distinct from the issue number so a test could tell them apart.
if [ "${1:-}" = "api" ] && printf '%s' "${2:-}" | grep -q '/sub_issues$' ; then
  echo '{"sub_issues_summary":{"total":1}}'
elif [ "${1:-}" = "api" ]; then
  child="$(printf '%s' "${2:-}" | sed 's#.*/issues/##')"
  echo $((9000 + child))
fi
exit 0
EOF
  chmod +x "$1"
}

# A schedule gh stub whose sub-issue calls (gh api) FAIL — id resolution and the
# POST both exit non-zero — so cmd_schedule's "could not nest" note must fire
# while waves.json is still written and the stage still advances. issue create
# still succeeds (only the linking is broken).
make_gh_stub_schedule_linkfail() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  n=101
  [ -f "$GH_SEQ" ] && n=$(( $(cat "$GH_SEQ") + 1 ))
  echo "$n" >"$GH_SEQ"
  echo "https://github.com/acme/repo/issues/$n"
  exit 0
fi
if [ "${1:-}" = "api" ]; then exit 1; fi
exit 0
EOF
  chmod +x "$1"
}

# A stub for the WHOLE host-adapter (LCARS_HOST_ADAPTER). It records each op to
# $ADAPTER_LOG and mimics the real adapter's stdout contract: issue-create echoes
# a fresh number; link-subissue echoes nothing. Proves the link goes THROUGH the
# host seam (op recorded), not via a direct gh/REST call in cmd_schedule.
make_adapter_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$ADAPTER_LOG"
case "${1:-}" in
  issue-create)
    n=101; [ -f "$ADAPTER_SEQ" ] && n=$(( $(cat "$ADAPTER_SEQ") + 1 ))
    echo "$n" >"$ADAPTER_SEQ"; echo "$n" ;;
  link-subissue) : ;;
  *) : ;;
esac
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
# The escalation is a walk-away awaiting-human gate, NOT a synchronous prompt:
# the stage POINTER stays at align (Research re-runs on align), but the gate is
# persisted so `lcars respond` can answer it later.
check "5. leaves the stage pointer at align (Research re-runs on align)" \
  "grep -q '\"stage\": *\"align\"' '$(state_of "$repo5")'"
check "5. sets awaitingHuman so the gate is walk-away" \
  "grep -q '\"awaitingHuman\": *true' '$(state_of "$repo5")'"
check "5. persists the escalation to pending.json" \
  "[ -f '$repo5/.git/lcars/missions/$MID/pending.json' ]"
check "5. prompts the captain to answer with lcars respond" \
  "grep -qi 'lcars respond' '$repo5/out.txt'"

# --- Behaviour 6: the paused card shows its TRUE in-flight stage ------------
# The bug this fixes: a Mission paused mid-Research used to keep the lcars:align
# label, so the Research column read empty while the card actually sat there.
# The escalation must flip the board label align → research and overlay
# awaiting-human, so the paused card sits in the Research column it is stuck in.
check "6. flips the board label to lcars:research (in-flight stage)" \
  "grep -q 'add-label lcars:research' '$repo5/gh.log'"
check "6. drops the stale lcars:align label" \
  "grep -q 'remove-label lcars:align' '$repo5/gh.log'"
check "6. overlays lcars:awaiting-human" \
  "grep -q 'add-label lcars:awaiting-human' '$repo5/gh.log'"
check "6. records the in-flight stage (research) in pending.json" \
  "grep -q '\"stage\": *\"research\"' '$repo5/.git/lcars/missions/$MID/pending.json'"

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
# estimatedReadLoc, estimatedTestLoc, estimatedNewLoc, dependencies, rationale.
# Here t-002 is missing its title.
repoPLb="$(new_repo_with_plan_mission)"; make_gh_stub "$repoPLb/gh"
export GH_LOG="$repoPLb/gh.log"; : >"$GH_LOG"
cat >"$repoPLb/bad.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Foundational token layer."
  },
  {
    "id": "t-002",
    "description": "A ticket with no title field.",
    "acceptanceCriteria": ["something observable"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 90,
    "dependencies": [],
    "rationale": "Has every field but the title, to isolate the missing-title check."
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
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Has every field but an acceptance criterion, to isolate that check."
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
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": ["t-099"],
    "rationale": "Well-formed except for the dangling dependency under test."
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
check "S4. tags each sub-issue lcars:ticket (role)" \
  "grep -q 'label lcars:implement,lcars:feature,lcars:ticket' '$GH_LOG'"
check "S4. never tags a sub-issue lcars:mission" \
  "! grep -q 'lcars:mission' '$GH_LOG'"

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

# --- Behaviour 6 (Session 35): each ticket sub-issue is NESTED under the Mission
# as a native GitHub sub-issue. With 4 tickets (issues 101-104) and Mission #42,
# Schedule must link all four under #42 via the host adapter — the POST to
# .../issues/42/sub_issues with a TYPED integer sub_issue_id (gh api -F).
check "S6. nests each ticket under the Mission (POST to issues/42/sub_issues)" \
  "[ \"\$(grep -c 'api --method POST repos/{owner}/{repo}/issues/42/sub_issues' '$repoS/gh.log')\" = '4' ]"
check "S6. resolves each child's db id before linking (gh api issues/101 --jq .id)" \
  "grep -q 'api repos/{owner}/{repo}/issues/101 --jq .id' '$repoS/gh.log'"
check "S6. sends sub_issue_id as a TYPED integer (-F, the resolved db id 9101)" \
  "grep -q 'sub_issues -F sub_issue_id=9101' '$repoS/gh.log'"
check "S6. never self-nests the Mission under itself (no POST issues/42/.../42)" \
  "! grep -q 'sub_issues -F sub_issue_id=9042' '$repoS/gh.log'"

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
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 50,
    "dependencies": ["t-002"],
    "rationale": "Well-formed tickets; the cycle is the defect under test."
  },
  {
    "id": "t-002",
    "title": "Ticket two",
    "description": "Depends on t-001.",
    "acceptanceCriteria": ["does another thing"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 50,
    "dependencies": ["t-001"],
    "rationale": "Well-formed tickets; the cycle is the defect under test."
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
echo "lcars run — Schedule single-ticket fast-path (BUG-005, Session 33)"

# When Plan emits exactly ONE ticket, Schedule must STOP opening a redundant
# sub-issue that merely duplicates the Mission's own issue. It still emits a
# one-wave waves.json — the lone ticket pointed at the Mission's OWN issue —
# and advances to Implement. Pipeline + Implement's input contract unchanged.

# --- SF: a 1-ticket plan opens NO sub-issue; reuses the Mission issue --------
repoSF="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoSF/gh"
write_single_ticket_plan_json "$repoSF/.git/lcars/missions/$MID/approved-plan.json"
export GH_LOG="$repoSF/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSF/gh.seq"; rm -f "$GH_SEQ"
rcSF=0
( cd "$repoSF" && LCARS_GH_BIN="$repoSF/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >outSF.txt 2>&1 ) || rcSF=$?
WAVESSF="$repoSF/.git/lcars/missions/$MID/waves.json"
check "SF. schedule exits 0 on a single-ticket plan" "[ '$rcSF' -eq 0 ]"
check "SF. writes waves.json" "[ -f '$WAVESSF' ]"
check "SF. opens NO GitHub sub-issue (fast-path)" \
  "! grep -q 'issue create' '$repoSF/gh.log'"
check "SF. the lone ticket is in wave 1" "[ \"\$(wave_of '$WAVESSF' t-001)\" = '1' ]"
check "SF. the lone ticket's issue == the Mission's own issue (#42)" \
  "grep -q '\"issue\": *42' '$WAVESSF'"
check "SF. waves.json has exactly one ticket (no second ticket)" \
  "[ \"\$(grep -c '\"id\":' '$WAVESSF')\" = '1' ]"
check "SF. advances the stage to implement" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoSF")'"
check "SF. relabels schedule → implement (adds lcars:implement)" \
  "grep -q 'add-label lcars:implement' '$repoSF/gh.log'"
check "SF. relabels schedule → implement (removes lcars:schedule)" \
  "grep -q 'remove-label lcars:schedule' '$repoSF/gh.log'"
check "SF. reports it opened 0 sub-issue(s)" \
  "grep -q 'opened 0 sub-issue' '$repoSF/outSF.txt'"
# Session 35: the fast-path creates no sub-issue, so there is nothing to nest —
# and the lone ticket reuses the Mission's OWN issue (#42), so a link would
# self-nest #42 under #42. NO link-subissue POST may fire on the fast path.
check "SF. makes NO sub-issue link on the fast path (no self-nest of #42)" \
  "! grep -q 'sub_issues' '$repoSF/gh.log'"

# --- SF-multi: a 2+-ticket plan is UNCHANGED (regression lock) --------------
# The existing graph → one-sub-issue-per-ticket → waves loop must still fire.
repoSFm="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoSFm/gh"
export GH_LOG="$repoSFm/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSFm/gh.seq"; rm -f "$GH_SEQ"
rcSFm=0
( cd "$repoSFm" && LCARS_GH_BIN="$repoSFm/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >outSFm.txt 2>&1 ) || rcSFm=$?
WAVESSFm="$repoSFm/.git/lcars/missions/$MID/waves.json"
check "SF-multi. 2+-ticket plan exits 0" "[ '$rcSFm' -eq 0 ]"
check "SF-multi. still opens one sub-issue per ticket (4)" \
  "[ \"\$(grep -c 'issue create' '$repoSFm/gh.log')\" = '4' ]"
check "SF-multi. saves the created issue numbers into waves.json (101)" \
  "grep -q '\"issue\": *101' '$WAVESSFm'"
check "SF-multi. does NOT reuse the Mission issue #42 for any ticket" \
  "! grep -q '\"issue\": *42' '$WAVESSFm'"

# --- SF-null: a 1-ticket plan with githubIssue=null → null issue, still moves -
# Degraded path: no issue on file. Keep TODAY's behaviour — issue: null + the
# existing warning. Never fabricate an issue.
repoSFn="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoSFn/gh"
write_single_ticket_plan_json "$repoSFn/.git/lcars/missions/$MID/approved-plan.json"
sSFn="$(state_of "$repoSFn")"
sed 's/"githubIssue": 42/"githubIssue": null/' "$sSFn" >"$repoSFn/s.tmp" && mv "$repoSFn/s.tmp" "$sSFn"
export GH_LOG="$repoSFn/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSFn/gh.seq"; rm -f "$GH_SEQ"
rcSFn=0
( cd "$repoSFn" && LCARS_GH_BIN="$repoSFn/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >outSFn.txt 2>&1 ) || rcSFn=$?
WAVESSFn="$repoSFn/.git/lcars/missions/$MID/waves.json"
check "SF-null. exits 0 with a null Mission issue" "[ '$rcSFn' -eq 0 ]"
check "SF-null. opens NO sub-issue (does not fabricate one)" \
  "! grep -q 'issue create' '$repoSFn/gh.log'"
check "SF-null. records issue: null for the lone ticket" \
  "grep -q '\"issue\": *null' '$WAVESSFn'"
check "SF-null. still advances to implement" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoSFn")'"
check "SF-null. warns about the missing issue" \
  "grep -qi 'warn\\|⚠\\|no.*issue\\|by hand' '$repoSFn/outSFn.txt'"

# --- SF-impl: Implement consumes the fast-path waves.json with NO special-case
# impl-status reads the reused-issue waves.json exactly the same way.
repoSFi="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule "$repoSFi/gh"
write_single_ticket_plan_json "$repoSFi/.git/lcars/missions/$MID/approved-plan.json"
export GH_LOG="$repoSFi/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSFi/gh.seq"; rm -f "$GH_SEQ"
( cd "$repoSFi" && LCARS_GH_BIN="$repoSFi/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >/dev/null 2>&1 )
rcSFi=0
( cd "$repoSFi" && LCARS_GH_BIN="$repoSFi/gh" bash "$SCRIPT" impl-status \
    --mission "$MID" >outSFi.txt 2>&1 ) || rcSFi=$?
check "SF-impl. impl-status reads the fast-path waves.json (exits 0)" "[ '$rcSFi' -eq 0 ]"
check "SF-impl. impl-status names the lone ticket t-001 as pending" \
  "grep -q 't-001' '$repoSFi/outSFi.txt'"

# ==========================================================================
echo
echo "lcars run — Schedule sub-issue nesting (Session 35)"

# --- SN-fail: a FAILING link degrades gracefully ----------------------------
# When sub-issue linking fails (gh api non-zero), Schedule must: surface a
# warning, STILL write waves.json, and STILL advance to implement (exit 0). A
# link failure must NEVER abort the Schedule stage.
repoSN="$(new_repo_with_schedule_mission)"; make_gh_stub_schedule_linkfail "$repoSN/gh"
export GH_LOG="$repoSN/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoSN/gh.seq"; rm -f "$GH_SEQ"
rcSN=0
( cd "$repoSN" && LCARS_GH_BIN="$repoSN/gh" bash "$SCRIPT" schedule \
    --mission "$MID" >outSN.txt 2>&1 ) || rcSN=$?
WAVESSN="$repoSN/.git/lcars/missions/$MID/waves.json"
check "SN-fail. schedule still exits 0 when sub-issue linking fails" "[ '$rcSN' -eq 0 ]"
check "SN-fail. still writes waves.json despite the link failure" "[ -f '$WAVESSN' ]"
check "SN-fail. still advances to implement despite the link failure" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoSN")'"
check "SN-fail. surfaces a 'could not nest / by hand' warning" \
  "grep -qi 'nest\\|by hand\\|⚠' '$repoSN/outSN.txt'"

# --- SN-route: nesting goes THROUGH the host adapter, not direct gh/REST -----
# Stub the WHOLE adapter and assert it received the link-subissue op with the
# Mission as parent for each ticket — proving cmd_schedule routes nesting via
# `host link-subissue`, keeping the path host/CLI-agnostic.
repoSR="$(new_repo_with_schedule_mission)"
ADAPTER="$repoSR/adapter.sh"; make_adapter_stub "$ADAPTER"
export ADAPTER_LOG="$repoSR/adapter.log"; : >"$ADAPTER_LOG"
export ADAPTER_SEQ="$repoSR/adapter.seq"; rm -f "$ADAPTER_SEQ"
rcSR=0
( cd "$repoSR" && LCARS_HOST_ADAPTER="$ADAPTER" bash "$SCRIPT" schedule \
    --mission "$MID" >outSR.txt 2>&1 ) || rcSR=$?
check "SN-route. schedule exits 0 with a stubbed host adapter" "[ '$rcSR' -eq 0 ]"
check "SN-route. routes nesting through the adapter's link-subissue op" \
  "grep -q '^link-subissue ' '$ADAPTER_LOG'"
check "SN-route. links each of the 4 tickets under the Mission issue 42" \
  "[ \"\$(grep -c '^link-subissue 42 ' '$ADAPTER_LOG')\" = '4' ]"
check "SN-route. never self-nests the Mission under itself (no link-subissue 42 42)" \
  "! grep -q '^link-subissue 42 42' '$ADAPTER_LOG'"

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
  local td; td="$(mktemp -d)"; printf 'assert: %s does the thing\n' "$tid" >"$td/${tid}.test"
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
twIr="$repoIr/tw"; mkdir -p "$twIr"; printf 'assert: a failing test\n' >"$twIr/t.test.js"
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
twIc="$repoIc/tw"; mkdir -p "$twIc"; printf 'assert: a failing test\n' >"$twIc/t.test.js"
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
twIm="$repoIm/tw"; mkdir -p "$twIm"; printf 'assert: a failing test\n' >"$twIm/t.test.js"
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
twIf="$repoIf/tw"; mkdir -p "$twIf"; printf 'assert: a failing test\n' >"$twIf/t.test.js"
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
twIC="$repoIC/tw"; mkdir -p "$twIC"; printf 'assert: a failing test\n' >"$twIC/t.test.js"
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
echo "lcars run — Implement issue-close lifecycle (Session 29, Rule A)"

# RULE A: when a ticket goes GREEN, impl-save-result closes that ticket's
# per-ticket sub-issue — relabel lcars:implement → lcars:done, then close it.
# This runs ONLY in the GREEN path, AFTER the guardrails and the commit, so an
# issue-close can never imply a pass a guardrail rejected. It is best-effort:
# a forge failure leaves a note but never fails the saved result. A ticket whose
# waves.json issue is null is a local-only mission — no forge call at all.
#
# The fake `gh` already logs `issue edit … --add-label …` and `issue close …`
# to GH_LOG, so the adapter's relabel/close calls land there per sub-issue.

# A1: a green ticket closes ITS sub-issue (t-001 → #101) with the done relabel.
repoL1="$(new_repo_with_implement_mission)"; make_gh_stub "$repoL1/gh"
export GH_LOG="$repoL1/gh.log"; : >"$GH_LOG"
twL1="$repoL1/tw"; mkdir -p "$twL1"; printf 'assert: a failing test\n' >"$twL1/t.test.js"
( cd "$repoL1" && LCARS_GH_BIN="$repoL1/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twL1" >/dev/null 2>&1 )
resL1="$repoL1/result.json"; write_result "$resL1" t-001 true 2
rcL1=0
( cd "$repoL1" && LCARS_GH_BIN="$repoL1/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resL1" >outL1.txt 2>&1 ) || rcL1=$?
check "A1. impl-save-result exits 0 on the green ticket" "[ '$rcL1' -eq 0 ]"
check "A1. relabels the sub-issue #101 to add lcars:done" \
  "grep -q 'issue edit 101 .*add-label lcars:done' '$GH_LOG'"
check "A1. relabels the sub-issue #101 to remove lcars:implement" \
  "grep -q 'issue edit 101 .*remove-label lcars:implement' '$GH_LOG'"
check "A1. closes the sub-issue #101" \
  "grep -q 'issue close 101' '$GH_LOG'"
check "A1. closes ONLY this ticket's sub-issue (not another ticket's #102)" \
  "! grep -q 'issue close 102' '$GH_LOG'"

# A2: a FLAGGED (failed) ticket closes NOTHING — its sub-issue stays open and
# keeps lcars:implement. (The flagged path relabels the PARENT #42 to
# awaiting-human, but never touches the ticket's own sub-issue.)
repoL2="$(new_repo_with_implement_mission)"; make_gh_stub "$repoL2/gh"
export GH_LOG="$repoL2/gh.log"; : >"$GH_LOG"
twL2="$repoL2/tw"; mkdir -p "$twL2"; printf 'assert: a failing test\n' >"$twL2/t.test.js"
( cd "$repoL2" && LCARS_GH_BIN="$repoL2/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twL2" >/dev/null 2>&1 )
resL2="$repoL2/result.json"; write_result "$resL2" t-001 false 5
( cd "$repoL2" && LCARS_GH_BIN="$repoL2/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resL2" >outL2.txt 2>&1 ) || true
check "A2. a flagged ticket issues NO close against its sub-issue #101" \
  "! grep -q 'issue close 101' '$GH_LOG'"
check "A2. a flagged ticket does NOT relabel its sub-issue #101 to done" \
  "! grep -q 'issue edit 101 .*add-label lcars:done' '$GH_LOG'"

# A3: a ticket whose waves.json issue is null → NO forge call for it, just a
# note. (Local-only mission path stays clean.) We rewrite waves.json so t-001's
# issue is null, then drive it green and assert no close fires for it.
repoL3="$(new_repo_with_implement_mission)"; make_gh_stub "$repoL3/gh"
export GH_LOG="$repoL3/gh.log"; : >"$GH_LOG"
wL3="$repoL3/.git/lcars/missions/$MID/waves.json"
cat >"$wL3" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  }
]
EOF
twL3="$repoL3/tw"; mkdir -p "$twL3"; printf 'assert: a failing test\n' >"$twL3/t.test.js"
( cd "$repoL3" && LCARS_GH_BIN="$repoL3/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twL3" >/dev/null 2>&1 )
resL3="$repoL3/result.json"; write_result "$resL3" t-001 true 2
rcL3=0
( cd "$repoL3" && LCARS_GH_BIN="$repoL3/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resL3" >outL3.txt 2>&1 ) || rcL3=$?
check "A3. impl-save-result still exits 0 with a null sub-issue" "[ '$rcL3' -eq 0 ]"
check "A3. a null-issue ticket makes NO issue close call" \
  "! grep -q 'issue close' '$GH_LOG'"
check "A3. a null-issue ticket makes NO done-relabel call" \
  "! grep -q 'add-label lcars:done' '$GH_LOG'"

# A4 (Session 33 interplay guard): when the ticket's issue IS the Mission's OWN
# parent issue (#42 — the single-ticket fast-path reuse), the on-green close
# must SKIP entirely. Closing it on green would close the parent BEFORE the PR
# merges; the parent closes on MERGE (lcars-approve), not here.
repoL4="$(new_repo_with_implement_mission)"; make_gh_stub "$repoL4/gh"
export GH_LOG="$repoL4/gh.log"; : >"$GH_LOG"
wL4="$repoL4/.git/lcars/missions/$MID/waves.json"
cat >"$wL4" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 42
      }
    ]
  }
]
EOF
twL4="$repoL4/tw"; mkdir -p "$twL4"; printf 'assert: a failing test\n' >"$twL4/t.test.js"
( cd "$repoL4" && LCARS_GH_BIN="$repoL4/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twL4" >/dev/null 2>&1 )
resL4="$repoL4/result.json"; write_result "$resL4" t-001 true 2
rcL4=0
( cd "$repoL4" && LCARS_GH_BIN="$repoL4/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resL4" >outL4.txt 2>&1 ) || rcL4=$?
check "A4. impl-save-result exits 0 when the ticket reuses the Mission issue" "[ '$rcL4' -eq 0 ]"
check "A4. does NOT close the reused parent issue #42 on green" \
  "! grep -q 'issue close 42' '$GH_LOG'"
check "A4. does NOT relabel the reused parent issue #42 to done on green" \
  "! grep -q 'issue edit 42 .*add-label lcars:done' '$GH_LOG'"
check "A4. notes the parent issue is left open (closes on PR merge)" \
  "grep -qi 'mission issue\\|left open\\|on.*merge' '$repoL4/outL4.txt'"

# A4b: a NORMAL sub-issue (issue != parent #42) STILL closes on green
# (regression on Session 29 — the guard must not over-fire).
repoL4b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoL4b/gh"
export GH_LOG="$repoL4b/gh.log"; : >"$GH_LOG"
twL4b="$repoL4b/tw"; mkdir -p "$twL4b"; printf 'assert: a failing test\n' >"$twL4b/t.test.js"
( cd "$repoL4b" && LCARS_GH_BIN="$repoL4b/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twL4b" >/dev/null 2>&1 )
resL4b="$repoL4b/result.json"; write_result "$resL4b" t-001 true 2
( cd "$repoL4b" && LCARS_GH_BIN="$repoL4b/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resL4b" >outL4b.txt 2>&1 ) || true
check "A4b. a normal sub-issue #101 (!= parent #42) STILL closes on green" \
  "grep -q 'issue close 101' '$GH_LOG'"
check "A4b. a normal sub-issue #101 STILL gets the done relabel" \
  "grep -q 'issue edit 101 .*add-label lcars:done' '$GH_LOG'"

# ==========================================================================
echo
echo "lcars run — Implement guardrails (red gate, immutable tests, test quality)"

# The adversarial Test Writer → Implementer split relies on prompt instructions
# alone unless the HARNESS enforces it. An LLM rewarded for a green suite will
# game the contract (trivially-passing tests, editing the tests to pass). These
# three guardrails live in run.sh — the deterministic driver — so the workers
# can't talk their way around them:
#   G1 RED GATE      — the saved tests must FAIL (against no implementation)
#                      before the Implementer is allowed to run
#   G2 IMMUTABLE     — the Implementer must not modify the locked test files
#   G3 TEST QUALITY  — a zero-assertion suite is rejected at impl-save-tests
# The red gate's test runner is env-injectable (LCARS_TEST_CMD, like LCARS_GH_BIN)
# so these unit tests drive a fake red→green transition with no real suite.

# A tests dir holding one file that actually asserts something.
make_tests_dir() { # dir
  mkdir -p "$1"; printf 'it("works", () => expect(value).toBe(42))\n' >"$1/spec.test.js"
}

# A runner that HONORS $LCARS_TESTS_DIR: red (exit 1) when the quarantine dir has
# tests, vacuously green (exit 0) when it is empty/missing. Different rc for the
# two cases, so the red gate's empty-dir probe proves the command reacted to the
# var → a non-zero quarantine exit is a GENUINE red of the new tests, accepted.
# (A bare `exit 1` ignores the var and is now BLOCKED — see TRIPWIRE 9 — so the
# guardrail regression tests that need an ACCEPTED red use this honoring shape.)
EARLY_HONOR_RED="$TMPROOT/early-honor-red.sh"
cat >"$EARLY_HONOR_RED" <<'EOF'
#!/usr/bin/env bash
d="${LCARS_TESTS_DIR:-}"
n=0; [ -n "$d" ] && [ -d "$d" ] && n="$(find "$d" -type f | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && { echo "0 tests collected (vacuous green)" >&2; exit 0; }
echo "quarantined tests are RED (no implementation)" >&2
exit 1
EOF
chmod +x "$EARLY_HONOR_RED"

# --- G1 RED GATE: a suite that PASSES with no implementation is rejected -----
repoG1="$(new_repo_with_implement_mission)"; make_gh_stub "$repoG1/gh"
export GH_LOG="$repoG1/gh.log"; : >"$GH_LOG"
tG1="$repoG1/tw"; make_tests_dir "$tG1"
rcG1=0
( cd "$repoG1" && LCARS_TEST_CMD='exit 0' LCARS_GH_BIN="$repoG1/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG1" >outG1.txt 2>&1 ) || rcG1=$?
check "G1. red gate rejects a suite that passes with no implementation" "[ '$rcG1' -ne 0 ]"
check "G1. names the red gate in the rejection" "grep -qi 'red gate' '$repoG1/outG1.txt'"
check "G1. does not quarantine tests when the red gate fails" \
  "[ ! -d '$repoG1/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# a suite that FAILS (red) is accepted — the Implementer may now run
repoG1b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoG1b/gh"
export GH_LOG="$repoG1b/gh.log"; : >"$GH_LOG"
tG1b="$repoG1b/tw"; make_tests_dir "$tG1b"
rcG1b=0
( cd "$repoG1b" && LCARS_TEST_CMD="bash $EARLY_HONOR_RED" LCARS_GH_BIN="$repoG1b/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG1b" >outG1b.txt 2>&1 ) || rcG1b=$?
check "G1. red gate accepts a failing (red) suite" "[ '$rcG1b' -eq 0 ]"
check "G1. quarantines the tests once the red gate passes" \
  "[ -f '$repoG1b/.git/lcars/missions/$MID/tickets/t-001/tests/spec.test.js' ]"

# --- G3 TEST QUALITY: a zero-assertion suite is rejected at impl-save-tests ---
repoG3="$(new_repo_with_implement_mission)"; make_gh_stub "$repoG3/gh"
export GH_LOG="$repoG3/gh.log"; : >"$GH_LOG"
tG3="$repoG3/tw"; mkdir -p "$tG3"
printf '// nothing of substance here\nconst x = 1;\n' >"$tG3/empty.test.js"
rcG3=0
( cd "$repoG3" && LCARS_TEST_CMD='exit 1' LCARS_GH_BIN="$repoG3/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG3" >outG3.txt 2>&1 ) || rcG3=$?
check "G3. rejects a zero-assertion suite" "[ '$rcG3' -ne 0 ]"
check "G3. names test quality / assertion in the rejection" \
  "grep -qiE 'assert|quality' '$repoG3/outG3.txt'"
check "G3. does not quarantine a zero-assertion suite" \
  "[ ! -d '$repoG3/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# --- G2 IMMUTABLE TESTS: a result whose locked tests changed is rejected ------
repoG2="$(new_repo_with_implement_mission)"; make_gh_stub "$repoG2/gh"
export GH_LOG="$repoG2/gh.log"; : >"$GH_LOG"
tG2="$repoG2/tw"; make_tests_dir "$tG2"
( cd "$repoG2" && LCARS_TEST_CMD="bash $EARLY_HONOR_RED" LCARS_GH_BIN="$repoG2/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG2" >/dev/null 2>&1 )
# the Implementer tampers with the locked contract to force a pass
QTDIR="$repoG2/.git/lcars/missions/$MID/tickets/t-001/tests"
printf 'it("works", () => expect(true).toBe(true))  // weakened\n' >"$QTDIR/spec.test.js"
resG2="$repoG2/result.json"; write_result "$resG2" t-001 true 2
rcG2=0
( cd "$repoG2" && LCARS_GH_BIN="$repoG2/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resG2" >outG2.txt 2>&1 ) || rcG2=$?
check "G2. rejects a result whose locked test files were modified" "[ '$rcG2' -ne 0 ]"
check "G2. names the immutable-tests violation" \
  "grep -qiE 'modif|immutable|locked|tamper' '$repoG2/outG2.txt'"
check "G2. does not save result.json when the tests were tampered with" \
  "[ ! -f '$repoG2/.git/lcars/missions/$MID/tickets/t-001/result.json' ]"

# an untouched contract still advances normally
repoG2b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoG2b/gh"
export GH_LOG="$repoG2b/gh.log"; : >"$GH_LOG"
tG2b="$repoG2b/tw"; make_tests_dir "$tG2b"
( cd "$repoG2b" && LCARS_TEST_CMD="bash $EARLY_HONOR_RED" LCARS_GH_BIN="$repoG2b/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG2b" >/dev/null 2>&1 )
resG2b="$repoG2b/result.json"; write_result "$resG2b" t-001 true 2
rcG2b=0
( cd "$repoG2b" && LCARS_GH_BIN="$repoG2b/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resG2b" >outG2b.txt 2>&1 ) || rcG2b=$?
check "G2. accepts a result when the locked tests are untouched" "[ '$rcG2b' -eq 0 ]"
check "G2. saves result.json for an untouched contract" \
  "[ -f '$repoG2b/.git/lcars/missions/$MID/tickets/t-001/result.json' ]"

# --- G4 REGRESSION: a normal red→green ticket advances and commits ------------
# Session 9 behaviour preserved with all three guardrails active: the red gate
# stub is red (exit 1) until the Implementer leaves a marker, then green.
repoG4="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$repoG4" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init && git branch "lcars/$MID" )
BASEG4="$(cd "$repoG4" && git rev-parse --abbrev-ref HEAD)"
mG4="$repoG4/.git/lcars/missions/$MID"; mkdir -p "$mG4"
cat >"$mG4/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$BASEG4"
}
EOF
write_approved_plan_json "$mG4/approved-plan.json"
write_waves_json "$mG4/waves.json"
make_gh_stub "$repoG4/gh"; export GH_LOG="$repoG4/gh.log"; : >"$GH_LOG"
tG4="$repoG4/tw"; make_tests_dir "$tG4"
GATE4="$repoG4/gate.sh"
cat >"$GATE4" <<'EOF'
#!/usr/bin/env bash
# HONORS $LCARS_TESTS_DIR: vacuously green on an empty/missing dir (so the red
# gate's probe proves it reacted to the var), otherwise red (1) until the
# implementation marker exists, then green (0).
d="${LCARS_TESTS_DIR:-}"
n=0; [ -n "$d" ] && [ -d "$d" ] && n="$(find "$d" -type f | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && { echo "0 tests, vacuous green" >&2; exit 0; }
[ -f impl-done ] && exit 0 || exit 1
EOF
chmod +x "$GATE4"
rcG4ts=0
( cd "$repoG4" && LCARS_TEST_CMD="bash $GATE4" LCARS_GH_BIN="$repoG4/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$tG4" >outG4a.txt 2>&1 ) || rcG4ts=$?
check "G4. red gate passes while the suite is still red (no impl)" "[ '$rcG4ts' -eq 0 ]"
# the Implementer implements: flip the suite green and leave a real file
printf 'export const theme = "dark";\n' >"$repoG4/theme.js"
: >"$repoG4/impl-done"
resG4="$repoG4/result.json"; write_result "$resG4" t-001 true 3
rcG4=0
( cd "$repoG4" && LCARS_GH_BIN="$repoG4/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resG4" >outG4b.txt 2>&1 ) || rcG4=$?
check "G4. a normal red→green ticket saves its result" "[ '$rcG4' -eq 0 ]"
check "G4. commits the green ticket onto the mission branch" \
  "( cd '$repoG4' && git ls-tree -r --name-only HEAD | grep -q '^theme.js$' )"

# ==========================================================================
echo
echo "lcars run — BUG-007: red gate evaluates the QUARANTINED tests, not the repo suite"

# Ground truth of BUG-007: red_gate_ok ran the repo's CONFIGURED testCommand and,
# when that command ignores $LCARS_TESTS_DIR (e.g. `bash tests/run.sh`), it ran
# the repo's EXISTING (passing) suite — returned 0 — and REJECTED every
# quarantined suite, silently. The fix must make the verdict a pure function of
# "did the QUARANTINED tests fail" and must FAIL LOUD (never green-light) when it
# cannot tell which suite ran. It must NOT weaken G1/G2/G3 or the adversarial
# split.

# A realistic per-repo runner that HONORS $LCARS_TESTS_DIR: it runs only the
# quarantined tests. A quarantined file tagged EXPECT_GREEN "passes"; anything
# else (or an empty dir / missing dir) "fails". This is the runner-appropriate
# shape `lcars init` documents — the gate's verdict must depend on it.
HONOR_RUNNER="$TMPROOT/honor-runner.sh"
cat >"$HONOR_RUNNER" <<'EOF'
#!/usr/bin/env bash
# Honors $LCARS_TESTS_DIR: green iff at least one quarantined file says EXPECT_GREEN.
d="${LCARS_TESTS_DIR:-}"
[ -n "$d" ] && [ -d "$d" ] || { echo "no quarantined tests dir" >&2; exit 1; }
n="$(find "$d" -type f | wc -l | tr -d ' ')"
[ "$n" -gt 0 ] || { echo "quarantined tests dir empty" >&2; exit 1; }
if grep -rq EXPECT_GREEN "$d"; then exit 0; fi
echo "quarantined tests are RED (behaviour not built)" >&2
exit 1
EOF
chmod +x "$HONOR_RUNNER"

# Helper: write a repo that ALSO has an existing, ALWAYS-GREEN repo suite at a
# fixed path (tests/run.sh), exactly the green suite the buggy gate used to run.
# The configured testCommand is the HONORing runner, so the gate must judge the
# QUARANTINED tests — the existing green suite must not change the verdict.
add_green_repo_suite() { # repo
  mkdir -p "$1/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/tests/run.sh"
  chmod +x "$1/tests/run.sh"
}

# --- BUG-007 #1: a quarantined FAILING test is RED even with a passing repo suite
repoB1="$(new_repo_with_implement_mission)"; make_gh_stub "$repoB1/gh"
export GH_LOG="$repoB1/gh.log"; : >"$GH_LOG"
add_green_repo_suite "$repoB1"
tB1="$repoB1/tw"; mkdir -p "$tB1"
# A genuinely red quarantined test (no EXPECT_GREEN tag) that asserts something.
printf 'assert: dark mode recolours the header (NOT YET BUILT)\n' >"$tB1/spec.test"
rcB1=0
( cd "$repoB1" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoB1/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tB1" \
    >outB1.txt 2>&1 ) || rcB1=$?
check "B1. quarantined FAILING test is judged RED even when the repo suite passes" \
  "[ '$rcB1' -eq 0 ]"
check "B1. quarantines the tests once the red gate passes" \
  "[ -f '$repoB1/.git/lcars/missions/$MID/tickets/t-001/tests/spec.test' ]"

# --- BUG-007 #5/#6 GATE PURITY: the SAME quarantined PASSING test is REJECTED
# whether or not the repo has a passing suite — green-on-nothing always loses, and
# the rejection now REPORTS WHY (rc + which suite ran), not a silent stall.
# (5a) asserts an already-true fact / (passes trivially): tagged EXPECT_GREEN.
mk_green_quarantine() { # dir
  mkdir -p "$1"
  printf 'assert: 1 == 1 // EXPECT_GREEN — already true, proves nothing\n' >"$1/trivial.test"
}
# TRIPWIRE 5a — DO NOT DELETE: a suite that asserts an already-true fact is rejected.
repoT5a="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT5a/gh"
export GH_LOG="$repoT5a/gh.log"; : >"$GH_LOG"
add_green_repo_suite "$repoT5a"
tT5a="$repoT5a/tw"; mk_green_quarantine "$tT5a"
rcT5a=0
( cd "$repoT5a" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoT5a/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT5a" \
    >outT5a.txt 2>&1 ) || rcT5a=$?
check "TRIPWIRE 5a. green-on-nothing (already-true assertion) is rejected" \
  "[ '$rcT5a' -ne 0 ]"
check "TRIPWIRE 5a. the red-gate rejection REPORTS WHY (rc / suite / passed visible)" \
  "grep -qiE 'red gate|passed|rc=|exit' '$repoT5a/outT5a.txt'"
check "TRIPWIRE 5a. does NOT quarantine the green-on-nothing suite" \
  "[ ! -d '$repoT5a/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# TRIPWIRE 5b — DO NOT DELETE: a suite testing pre-existing repo behaviour
# (the runner passes it on nothing) is rejected just the same.
repoT5b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT5b/gh"
export GH_LOG="$repoT5b/gh.log"; : >"$GH_LOG"
tT5b="$repoT5b/tw"; mkdir -p "$tT5b"
printf 'assert: git is installed // EXPECT_GREEN — pre-existing, no new behaviour\n' >"$tT5b/preexisting.test"
rcT5b=0
( cd "$repoT5b" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoT5b/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT5b" \
    >outT5b.txt 2>&1 ) || rcT5b=$?
check "TRIPWIRE 5b. a suite for pre-existing (already-green) behaviour is rejected" \
  "[ '$rcT5b' -ne 0 ]"

# TRIPWIRE 5c — DO NOT DELETE: a suite that passes trivially (with a real repo
# suite ALSO green) is still rejected — the repo suite cannot rescue it.
repoT5c="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT5c/gh"
export GH_LOG="$repoT5c/gh.log"; : >"$GH_LOG"
add_green_repo_suite "$repoT5c"
tT5c="$repoT5c/tw"; mkdir -p "$tT5c"
printf 'assert: noop // EXPECT_GREEN — trivially passes\n' >"$tT5c/trivial.test"
rcT5c=0
( cd "$repoT5c" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoT5c/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT5c" \
    >outT5c.txt 2>&1 ) || rcT5c=$?
check "TRIPWIRE 5c. a trivially-passing suite is rejected (repo suite cannot rescue)" \
  "[ '$rcT5c' -ne 0 ]"

# TRIPWIRE 6 — DO NOT DELETE: GATE PURITY. The verdict is a pure function of the
# QUARANTINED tests. SAME quarantined FAILING test → RED with OR without a passing
# repo suite; SAME quarantined PASSING test → REJECTED with OR without one. Four
# combinations, the repo suite never flips the verdict.
mk_red_quarantine() { # dir
  mkdir -p "$1"; printf 'assert: behaviour X exists (NOT BUILT)\n' >"$1/x.test"
}
purity_verdict() { # tag(with|without)-repo-suite  quarantine-builder → echoes rc
  local tag="$1" builder="$2"
  local r; r="$(new_repo_with_implement_mission)"; make_gh_stub "$r/gh"
  export GH_LOG="$r/gh.log"; : >"$GH_LOG"
  [ "$tag" = with ] && add_green_repo_suite "$r"
  local t="$r/tw"; "$builder" "$t"
  local rc=0
  ( cd "$r" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$r/gh" \
      bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$t" \
      >/dev/null 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
p6_red_with="$(purity_verdict with mk_red_quarantine)"
p6_red_without="$(purity_verdict without mk_red_quarantine)"
p6_grn_with="$(purity_verdict with mk_green_quarantine)"
p6_grn_without="$(purity_verdict without mk_green_quarantine)"
check "TRIPWIRE 6. RED quarantine → accepted regardless of the repo suite" \
  "[ '$p6_red_with' -eq 0 ] && [ '$p6_red_without' -eq 0 ]"
check "TRIPWIRE 6. PASSING quarantine → rejected regardless of the repo suite" \
  "[ '$p6_grn_with' -ne 0 ] && [ '$p6_grn_without' -ne 0 ]"

# TRIPWIRE 7 — DO NOT DELETE: the "can't tell which suite ran" path NEVER
# green-lights an unproven suite. A configured command that IGNORES
# $LCARS_TESTS_DIR (so the gate cannot prove the QUARANTINED tests were what ran)
# and is GREEN must be BLOCKED loudly, not passed through. `exit 0` is exactly
# such a command (constant green, ignores the dir): it must REJECT, naming why.
repoT7="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT7/gh"
export GH_LOG="$repoT7/gh.log"; : >"$GH_LOG"
tT7="$repoT7/tw"; make_tests_dir "$tT7"
rcT7=0
( cd "$repoT7" && LCARS_TEST_CMD='exit 0' LCARS_GH_BIN="$repoT7/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT7" \
    >outT7.txt 2>&1 ) || rcT7=$?
check "TRIPWIRE 7. green command that ignores \$LCARS_TESTS_DIR is BLOCKED, not green-lit" \
  "[ '$rcT7' -ne 0 ]"
check "TRIPWIRE 7. the block is LOUD (red gate / passed / ignored surfaced)" \
  "grep -qiE 'red gate|passed|ignore|prove' '$repoT7/outT7.txt'"
check "TRIPWIRE 7. nothing quarantined on the can't-tell-which-suite path" \
  "[ ! -d '$repoT7/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# BUG-008 pair-fix: when red-gate rejects, include the ACTUAL command string run.
CMD_VIS_RUNNER="$TMPROOT/cmd-visible-runner.sh"
cat >"$CMD_VIS_RUNNER" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CMD_VIS_RUNNER"
repoB8cmd="$(new_repo_with_implement_mission)"; make_gh_stub "$repoB8cmd/gh"
export GH_LOG="$repoB8cmd/gh.log"; : >"$GH_LOG"
tB8cmd="$repoB8cmd/tw"; make_tests_dir "$tB8cmd"
mkdir -p "$repoB8cmd/.git/lcars"
printf '{ "testCommand": "bash %s \\"$LCARS_TESTS_DIR\\"" }\n' "$CMD_VIS_RUNNER" >"$repoB8cmd/.git/lcars/config.json"
expectedB8cmd="bash $CMD_VIS_RUNNER \"\$LCARS_TESTS_DIR\""
rcB8cmd=0
( cd "$repoB8cmd" && LCARS_GH_BIN="$repoB8cmd/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tB8cmd" \
    >outB8cmd.txt 2>&1 ) || rcB8cmd=$?
check "B8.4 escaped-quote testCommand is read fully (exact command text survives json_str)" \
  "grep -qF '$expectedB8cmd' '$repoB8cmd/outB8cmd.txt'"
check "B8.5 red-gate rejection includes the actual command string it ran" \
  "grep -qF '$expectedB8cmd' '$repoB8cmd/outB8cmd.txt'"

# TRIPWIRE 8 — DO NOT DELETE: G2 (immutable hash), G3 (assertions), and the
# adversarial split are UNCHANGED. (G1/G2/G3 regression blocks above already
# assert these; this restates the invariant against the HONORing runner so a
# future gate edit can't quietly drop them.)
# G3 against the honoring runner: a zero-assertion suite is still rejected
# BEFORE the runner is even consulted.
repoT8="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT8/gh"
export GH_LOG="$repoT8/gh.log"; : >"$GH_LOG"
tT8="$repoT8/tw"; mkdir -p "$tT8"
# No assertion construct at all (and nothing the assertion detector matches).
printf '// nothing of substance here\nconst x = 1;\n' >"$tT8/noassert.test"
rcT8=0
( cd "$repoT8" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoT8/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT8" \
    >outT8.txt 2>&1 ) || rcT8=$?
check "TRIPWIRE 8. G3 still rejects a zero-assertion suite under the honoring runner" \
  "[ '$rcT8' -ne 0 ]"
check "TRIPWIRE 8. G3 rejection names assertion / quality" \
  "grep -qiE 'assert|quality' '$repoT8/outT8.txt'"
# G2 against the honoring runner: the Implementer still cannot edit the locked
# tests. Save a RED quarantine (accepted), then tamper + try to save a result.
repoT8b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT8b/gh"
export GH_LOG="$repoT8b/gh.log"; : >"$GH_LOG"
tT8b="$repoT8b/tw"; mk_red_quarantine "$tT8b"
( cd "$repoT8b" && LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_GH_BIN="$repoT8b/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT8b" >/dev/null 2>&1 )
QT8="$repoT8b/.git/lcars/missions/$MID/tickets/t-001/tests"
printf 'assert: noop // EXPECT_GREEN — weakened by the Implementer\n' >"$QT8/x.test"
resT8="$repoT8b/result.json"; write_result "$resT8" t-001 true 2
rcT8b=0
( cd "$repoT8b" && LCARS_GH_BIN="$repoT8b/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resT8" >outT8b.txt 2>&1 ) || rcT8b=$?
check "TRIPWIRE 8. G2 still rejects a result whose locked tests were edited" \
  "[ '$rcT8b' -ne 0 ]"

# TRIPWIRE 9 — DO NOT DELETE: the RED-branch dir-ignoring hole.
# A non-zero exit is only "red = safe" when it proves the QUARANTINED tests
# failed. A command that IGNORES $LCARS_TESTS_DIR and is itself red on the
# repo's own suite exits non-zero IDENTICALLY whether the quarantine dir holds
# the new tests or nothing — its non-zero exit proves NOTHING about the
# quarantined suite. That UNPROVEN suite must now be BLOCKED loud, never
# accepted. (Closes the symmetric counterpart of TRIPWIRE 7 on the RED branch.)
# Model: a runner that prints byte-identical output and exits 1 regardless of
# the dir (the repo's own failing suite).
IGNORE_RED_RUNNER="$TMPROOT/ignore-red-runner.sh"
cat >"$IGNORE_RED_RUNNER" <<'EOF'
#!/usr/bin/env bash
# Ignores $LCARS_TESTS_DIR entirely: always the same red repo suite.
echo "repo suite: 3 of 7 tests FAILED" >&2
exit 1
EOF
chmod +x "$IGNORE_RED_RUNNER"
repoT9="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT9/gh"
export GH_LOG="$repoT9/gh.log"; : >"$GH_LOG"
tT9="$repoT9/tw"; mk_red_quarantine "$tT9"
rcT9=0
( cd "$repoT9" && LCARS_TEST_CMD="bash $IGNORE_RED_RUNNER" LCARS_GH_BIN="$repoT9/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT9" \
    >outT9.txt 2>&1 ) || rcT9=$?
check "TRIPWIRE 9. a non-zero runner that IGNORES \$LCARS_TESTS_DIR is BLOCKED, not accepted as red" \
  "[ '$rcT9' -ne 0 ]"
check "TRIPWIRE 9. the block is LOUD and names the ignored-var cause" \
  "grep -qiE 'red gate|ignore|prove|\\\$LCARS_TESTS_DIR' '$repoT9/outT9.txt'"
check "TRIPWIRE 9. nothing quarantined on the dir-ignoring red path" \
  "[ ! -d '$repoT9/.git/lcars/missions/$MID/tickets/t-001/tests' ]"
check "TRIPWIRE 9. the captured signal carries the new block reason for the grounded retry" \
  "grep -qiE 'red gate|ignore|prove' '$repoT9/outT9.txt'"

# TRIPWIRE 9b — DO NOT DELETE: THE CRITICAL REGRESSION GUARD (no false-block).
# A HONORing runner can legitimately exit with the SAME non-zero rc on an empty
# quarantine dir as on a real failing quarantined test — but with DIFFERENT
# output. rc-equality alone would FALSE-BLOCK it and re-break Implement (the
# BUG-007 stall). The discriminator must compare OUTPUT too: any difference
# ⟹ the command reacted ⟹ ACCEPT the red verdict. This MUST stay green.
# Model: empty dir → exit 1 + "no tests collected"; a real red test → exit 1 +
# "FAIL: <assertion>". Same rc (1), different output.
HONOR_SAME_RC_RUNNER="$TMPROOT/honor-same-rc-runner.sh"
cat >"$HONOR_SAME_RC_RUNNER" <<'EOF'
#!/usr/bin/env bash
d="${LCARS_TESTS_DIR:-}"
n=0; [ -n "$d" ] && [ -d "$d" ] && n="$(find "$d" -type f | wc -l | tr -d ' ')"
if [ "$n" -eq 0 ]; then echo "no tests collected" >&2; exit 1; fi
echo "FAIL: behaviour X exists (assertion failed)" >&2
exit 1
EOF
chmod +x "$HONOR_SAME_RC_RUNNER"
repoT9b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT9b/gh"
export GH_LOG="$repoT9b/gh.log"; : >"$GH_LOG"
tT9b="$repoT9b/tw"; mk_red_quarantine "$tT9b"
rcT9b=0
( cd "$repoT9b" && LCARS_TEST_CMD="bash $HONOR_SAME_RC_RUNNER" LCARS_GH_BIN="$repoT9b/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT9b" \
    >outT9b.txt 2>&1 ) || rcT9b=$?
check "TRIPWIRE 9b. a HONORing runner with same-rc-but-different-output is ACCEPTED (no false-block)" \
  "[ '$rcT9b' -eq 0 ]"
check "TRIPWIRE 9b. the honoring red suite IS quarantined (Implementer proceeds)" \
  "[ -d '$repoT9b/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# TRIPWIRE 9c — DO NOT DELETE: the COMMON honoring case still works. A honoring
# runner whose empty-dir run is a VACUOUS PASS (exit 0 — no tests) vs a real
# failing quarantine test (exit 1) → different rc → ACCEPT. This is the normal
# red→green mission path; it must be unaffected. (HONOR_RUNNER is exactly this:
# empty/missing dir → exit 1 actually — so model the exit-0-on-empty variant.)
HONOR_VACUOUS_RUNNER="$TMPROOT/honor-vacuous-runner.sh"
cat >"$HONOR_VACUOUS_RUNNER" <<'EOF'
#!/usr/bin/env bash
d="${LCARS_TESTS_DIR:-}"
n=0; [ -n "$d" ] && [ -d "$d" ] && n="$(find "$d" -type f | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && { echo "0 tests, vacuously green" >&2; exit 0; }
if grep -rq EXPECT_GREEN "$d"; then exit 0; fi
echo "quarantined tests RED" >&2; exit 1
EOF
chmod +x "$HONOR_VACUOUS_RUNNER"
repoT9c="$(new_repo_with_implement_mission)"; make_gh_stub "$repoT9c/gh"
export GH_LOG="$repoT9c/gh.log"; : >"$GH_LOG"
tT9c="$repoT9c/tw"; mk_red_quarantine "$tT9c"
rcT9c=0
( cd "$repoT9c" && LCARS_TEST_CMD="bash $HONOR_VACUOUS_RUNNER" LCARS_GH_BIN="$repoT9c/gh" \
    bash "$SCRIPT" impl-save-tests --mission "$MID" --ticket t-001 --tests "$tT9c" \
    >outT9c.txt 2>&1 ) || rcT9c=$?
check "TRIPWIRE 9c. a honoring runner (real fail vs vacuous-pass-on-empty) is ACCEPTED (red = safe)" \
  "[ '$rcT9c' -eq 0 ]"
check "TRIPWIRE 9c. the normal red→green path quarantines the suite" \
  "[ -d '$repoT9c/.git/lcars/missions/$MID/tickets/t-001/tests' ]"

# --- BUG-007 #2: GROUNDED RETRY — on rejection, the NEXT Test-Writer prompt
# carries the captured red-gate SIGNAL (rc + bounded runner output), and NEVER
# the implementation / prior reasoning. Driven through cmd_implement with a worker
# stub that, on its FIRST dispatch, writes a green-on-nothing suite (rejected),
# and on its SECOND dispatch writes a genuinely-red suite. The 2nd prompt must
# show the captured signal.
binGR="$TMPROOT/grbin"; rm -rf "$binGR"; mkdir -p "$binGR"
cat >"$binGR/worker" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
# Record every test-writer prompt so the test can inspect what attempt 2 saw.
if [ "$LCARS_WORKER_ROLE" = implement-test-writer ]; then
  pf="$GR_PROMPTS_DIR/tw.$(ls "$GR_PROMPTS_DIR" | grep -c '^tw\.').prompt"
  printf '%s' "$prompt" >"$pf"
  mkdir -p "$out/tests"
  if [ ! -f "$GR_STATE/first-done" ]; then
    : >"$GR_STATE/first-done"
    # green-on-nothing: tagged EXPECT_GREEN so the honoring runner passes it → rejected.
    printf 'assert: noop // EXPECT_GREEN — green on nothing\n' >"$out/tests/spec.test"
  else
    # genuinely red now: no EXPECT_GREEN → honoring runner fails → red gate accepts.
    printf 'assert: behaviour Y exists (NOT BUILT)\n' >"$out/tests/spec.test"
  fi
elif [ "$LCARS_WORKER_ROLE" = implement-implementer ]; then
  printf '{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "done" }\n' >"$out/result.json"
fi
exit 0
EOF
chmod +x "$binGR/worker"; make_gh_stub "$binGR/gh"
# Single-ticket repo at implement, with the HONORing runner configured.
repoGR="$(new_repo_with_implement_mission)"; add_green_repo_suite "$repoGR"
mkdir -p "$repoGR/.git/lcars"; printf '{ "testCommand": "bash %s" }\n' "$HONOR_RUNNER" >"$repoGR/.git/lcars/config.json"
GR_PROMPTS_DIR="$TMPROOT/gr-prompts"; rm -rf "$GR_PROMPTS_DIR"; mkdir -p "$GR_PROMPTS_DIR"
GR_STATE="$TMPROOT/gr-state"; rm -rf "$GR_STATE"; mkdir -p "$GR_STATE"
rcGR=0
( cd "$repoGR" && GR_PROMPTS_DIR="$GR_PROMPTS_DIR" GR_STATE="$GR_STATE" \
    LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_WORKER_BIN="$binGR/worker" \
    LCARS_GH_BIN="$binGR/gh" bash "$SCRIPT" implement-ticket \
    --mission "$MID" --ticket t-001 >outGR.txt 2>&1 ) || rcGR=$?
# The second test-writer prompt (tw.1.prompt) must carry the captured red-gate signal.
TW2="$GR_PROMPTS_DIR/tw.1.prompt"
check "GR. a second Test-Writer attempt occurred after the rejection" "[ -f '$TW2' ]"
check "GR. the retry prompt carries the captured red-gate SIGNAL (passed-on-nothing / runner output)" \
  "grep -qiE 'passed with no implementation|red gate|runner output|green on nothing|rc=' '$TW2'"
check "GR. the retry prompt does NOT leak the implementation / result" \
  "[ -f '$TW2' ] && ! grep -qiE 'result.json|theme.js|\"passed\": true|prior reasoning' '$TW2'"

# --- TW-GROUND: the Test Writer prompt INLINES the ticket spec (Session 22) ---
# Defect: a Copilot/opus Test Writer handed only a PATH to approved-plan.json +
# the ticket id grounded on CONTEXT.md and wrote tests for the wrong feature.
# Fix (CLI-AGNOSTIC, in the shared stage-prompt assembly): the worker must SEE
# the specific ticket's title + acceptanceCriteria TEXT in its prompt — not just
# an id and a file to go find. Capture the FIRST test-writer prompt and assert it
# carries the title and at least one acceptance-criterion string inline. This is a
# regression lock against the path-only handoff.
binTWG="$TMPROOT/twgbin"; rm -rf "$binTWG"; mkdir -p "$binTWG"
cat >"$binTWG/worker" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
if [ "$LCARS_WORKER_ROLE" = implement-test-writer ]; then
  printf '%s' "$prompt" >"$TWG_PROMPT"
  mkdir -p "$out/tests"
  printf 'assert: behaviour Y exists (NOT BUILT)\n' >"$out/tests/spec.test"
elif [ "$LCARS_WORKER_ROLE" = implement-implementer ]; then
  printf '{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "done" }\n' >"$out/result.json"
fi
exit 0
EOF
chmod +x "$binTWG/worker"; make_gh_stub "$binTWG/gh"
repoTWG="$(new_repo_with_implement_mission)"; add_green_repo_suite "$repoTWG"
mkdir -p "$repoTWG/.git/lcars"; printf '{ "testCommand": "bash %s" }\n' "$HONOR_RUNNER" >"$repoTWG/.git/lcars/config.json"
TWG_PROMPT="$TMPROOT/twg.prompt"; rm -f "$TWG_PROMPT"
rcTWG=0
( cd "$repoTWG" && TWG_PROMPT="$TWG_PROMPT" \
    LCARS_TEST_CMD="bash $HONOR_RUNNER" LCARS_WORKER_BIN="$binTWG/worker" \
    LCARS_GH_BIN="$binTWG/gh" bash "$SCRIPT" implement-ticket \
    --mission "$MID" --ticket t-001 >outTWG.txt 2>&1 ) || rcTWG=$?
check "TWG. the Test Writer was dispatched (prompt captured)" "[ -f '$TWG_PROMPT' ]"
check "TWG. the Test Writer prompt INLINES the ticket title (not just the id)" \
  "grep -qF 'Add the data-theme attribute and dark token set' '$TWG_PROMPT'"
check "TWG. the Test Writer prompt INLINES an acceptance-criterion string" \
  "grep -qF 'Setting data-theme=dark recolours the page' '$TWG_PROMPT'"
check "TWG. the Test Writer prompt still references approved-plan.json (path preserved)" \
  "grep -qF 'approved-plan.json' '$TWG_PROMPT'"

# --- BUG-007 #3: the stage prompt carries a RED-FIRST recipe; a stubbed worker
# following it (a dedicated failing test file) clears the gate.
check "P3. implement-test-writer.md carries a RED-FIRST recipe" \
  "grep -qiE 'red.first|RED FIRST' '$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md'"
check "P3. the recipe tells the writer to invoke the not-yet-built entrypoint / assert observable output" \
  "grep -qiE 'public entrypoint|not[- ]yet|does not exist|ERROR|FAIL' '$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md'"
check "P3. the recipe forbids appending to an existing passing suite (dedicated file)" \
  "grep -qiE 'dedicated|do not append|never append|existing passing suite' '$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md'"

# --- Copilot enablement: the output-file instruction is CLI-NEUTRAL and
# directive (nudges Claude's Write AND Copilot's create), and never names a CLI.
# The shared epilogue in spawn_worker is the primary lever; it must tell the
# worker to USE its file-creation tool and that a reply-only answer fails.
check "CN. the shared worker epilogue says to USE a file-creation/write tool" \
  "grep -qiE 'file-creation|file-writing|creation / file' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. the epilogue forbids a reply-only answer (harness reads files only)" \
  "grep -qiE 'not put your answer in your reply|reply.only answer|reads ONLY the files' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. no stage prompt names a CLI (the prompts stay CLI-NEUTRAL)" \
  "! grep -riqE 'copilot|claude|anthropic|opus|sonnet|haiku' '$REPO_ROOT/skills/lcars-run/stages/'"
check "CN. a single-worker stage (research-questions) tells it to CREATE the file" \
  "grep -qiE 'file-creation|file-writing|Create the file' '$REPO_ROOT/skills/lcars-run/stages/research-questions.md'"

# --- Anti-procrastination (Lever 1, Copilot-safe reframing): the prompts must
# require the file to be created BEFORE the turn ends and say that describing the
# task is not doing it — the CLI-neutral defeat for a model that announces-and-
# yields. It MUST NOT tell the worker to create an empty/placeholder file first
# and fill it in later: Copilot's `create` tool cannot overwrite an existing
# file, so an empty-first instruction bricks the worker. One create, complete.
check "CN. the shared epilogue requires the file BEFORE the turn ends" \
  "grep -qiE 'BEFORE you end your turn|before your? turn' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. the shared epilogue says describing the task is NOT doing it" \
  "grep -qiE 'describing the task is NOT doing it|announcing or describing' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. the shared epilogue says create the file ONCE with COMPLETE content" \
  "grep -qiE 'COMPLETE final content|single write' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. the question-generator requires creating the file before the turn ends" \
  "grep -qiE 'BEFORE you end your turn|create the file .*ONCE|single write' '$REPO_ROOT/skills/lcars-run/stages/research-questions.md'"

# --- Copilot file-tool hard limit: NO prompt may instruct creating an empty /
# placeholder file THEN filling/editing it later (Copilot `create` cannot
# overwrite). Assert the bricking phrasing is gone from run.sh AND every stage.
check "CN. run.sh never instructs create-empty-then-fill" \
  "! grep -qiE 'create (it|the file) empty (first)?.*then fill|empty first if you must|create a placeholder' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN. no stage prompt instructs create-empty-then-fill" \
  "! grep -riqE 'create (it|the file) empty (first)?.*then fill|empty first if you must|create a placeholder' '$REPO_ROOT/skills/lcars-run/stages/'"
check "CN. the prompts warn the file tool may not overwrite an existing file" \
  "grep -qiE 'may not support overwriting' '$REPO_ROOT/skills/lcars-run/run.sh'"

# --- Anti-procrastination (Lever 2): a behaviour-keyed retry escalation. On a
# retry AFTER a prior attempt produced NO file, spawn_worker appends an
# escalation block; the FIRST attempt's prompt is unchanged. Keyed on observed
# behaviour only — never a CLI name.
# Stub spawn_worker's collaborators and drive it directly, capturing the prompt.
cn_l2_dir="$(mktemp -d "$TMPROOT/cnl2.XXXX")"
cat >"$cn_l2_dir/tmpl.md" <<'EOF'
# Template body (substantive content)
EOF
# A tiny worker that records the prompt it was handed and writes nothing.
cn_l2_capture="$cn_l2_dir/prompt.txt"
(
  set -uo pipefail
  STAGES_DIR="$cn_l2_dir"
  worker_spawn() { printf '%s' "$3" >"$cn_l2_capture"; }   # role-toolset outdir prompt
  # Pull the real spawn_worker definition out of run.sh and eval it.
  eval "$(sed -n '/^spawn_worker() {/,/^}/p' "$REPO_ROOT/skills/lcars-run/run.sh")"
  # Same outdir both times so the ONLY difference is the appended escalation (the
  # real loop uses a fresh mktemp each retry, but we hold it constant to assert
  # the byte-for-byte prefix invariant cleanly).
  # Attempt 1 — no prior failure: prompt must NOT carry the escalation.
  spawn_worker some-role "$cn_l2_dir/tmpl.md" repo-read "$cn_l2_dir/o" "extra" ""
  cp "$cn_l2_capture" "$cn_l2_dir/a1.txt"
  # Attempt 2 — prior attempt produced no file: escalation MUST be appended.
  spawn_worker some-role "$cn_l2_dir/tmpl.md" repo-read "$cn_l2_dir/o" "extra" "no-file"
  cp "$cn_l2_capture" "$cn_l2_dir/a2.txt"
)
check "CN-L2. attempt 1 (no prior failure) carries NO escalation block" \
  "! grep -qiE 'PREVIOUS ATTEMPT FAILED' '$cn_l2_dir/a1.txt'"
check "CN-L2. attempt 2 (prior no-file) carries the escalation block" \
  "grep -qiE 'PREVIOUS ATTEMPT FAILED' '$cn_l2_dir/a2.txt'"
check "CN-L2. the escalation is behaviour-keyed, naming NO CLI" \
  "! grep -riqE 'copilot|claude|anthropic|opus|sonnet|haiku|gpt-' '$cn_l2_dir/a2.txt'"
# Slice the first N bytes of a2 (N = len(a1)) and assert it equals a1 verbatim —
# proving the escalation is strictly APPENDED, leaving attempt 1's text untouched.
head -c "$(wc -c <"$cn_l2_dir/a1.txt")" "$cn_l2_dir/a2.txt" >"$cn_l2_dir/a2-prefix.txt"
check "CN-L2. attempt 1's prompt is a byte-for-byte PREFIX of attempt 2 (escalation only appended)" \
  "cmp -s '$cn_l2_dir/a1.txt' '$cn_l2_dir/a2-prefix.txt'"

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

# --- BUG-008: json_str reads escaped string content fully (no truncation) ----
repoB8q="$(new_repo_with_verify_mission)"; make_gh_stub "$repoB8q/gh"
export GH_LOG="$repoB8q/gh.log"; : >"$GH_LOG"
set_state_title_json_escaped "$repoB8q" 'Add a "version" flag'
rcB8q=0
( cd "$repoB8q" && LCARS_GH_BIN="$repoB8q/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >outB8q.txt 2>&1 ) || rcB8q=$?
check "B8.1 json_str round-trips a json_escape-written quote in title" "[ '$rcB8q' -eq 0 ]"
check "B8.1 verify-summary prints the full quoted title (no truncation at \\\" )" \
  "grep -qF 'VERIFY: Add a \"version\" flag' '$repoB8q/outB8q.txt'"

repoB8bs="$(new_repo_with_verify_mission)"; make_gh_stub "$repoB8bs/gh"
export GH_LOG="$repoB8bs/gh.log"; : >"$GH_LOG"
set_state_title_json_escaped "$repoB8bs" 'Use C:\LCARS\tests'
rcB8bs=0
( cd "$repoB8bs" && LCARS_GH_BIN="$repoB8bs/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >outB8bs.txt 2>&1 ) || rcB8bs=$?
check "B8.2 json_str decodes \\\\ to a single backslash" \
  "grep -qF 'VERIFY: Use C:\\LCARS\\tests' '$repoB8bs/outB8bs.txt'"

repoB8plain="$(new_repo_with_verify_mission)"; make_gh_stub "$repoB8plain/gh"
export GH_LOG="$repoB8plain/gh.log"; : >"$GH_LOG"
set_state_title_json_escaped "$repoB8plain" 'Plain title'
rcB8plain=0
( cd "$repoB8plain" && LCARS_GH_BIN="$repoB8plain/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >outB8plain.txt 2>&1 ) || rcB8plain=$?
check "B8.3 json_str leaves quote-free strings unchanged" \
  "grep -qF 'VERIFY: Plain title' '$repoB8plain/outB8plain.txt'"

# --- Guard: verify-summary refuses a non-verify mission --------------------
repoVRg="$(new_repo_with_mission)"; make_gh_stub "$repoVRg/gh"   # still at align
export GH_LOG="$repoVRg/gh.log"; : >"$GH_LOG"
rcVRg=0
( cd "$repoVRg" && LCARS_GH_BIN="$repoVRg/gh" bash "$SCRIPT" verify-summary \
    --mission "$MID" >out.txt 2>&1 ) || rcVRg=$?
check "guard. verify-summary refuses a non-verify mission" "[ '$rcVRg' -ne 0 ]"

# ==========================================================================
echo
echo "lcars run — Stage isolation (cold subprocess workers)"

# This build moves every headless Stage's LLM work out of the orchestrator's own
# session and into a COLD SUBPROCESS WORKER spawned via $LCARS_WORKER_BIN, whose
# prompt run.sh assembles from a per-Stage template + the artifact PATHS alone.
# These tests point $LCARS_WORKER_BIN at a stub that records each call and echoes
# canned artifacts, so the spawn / assemble / validate / persist plumbing runs
# with no real tokens. The eight behaviours from the build order, in order:
#   1. The worker-spawn helper builds the prompt from template + artifact PATHS
#      only (no inlined context) and restricts the tool set per Stage
#   2. Research dispatches N stateless workers in parallel, each given the
#      question text only — no PRD, no siblings
#   3. Validate runs as one cold worker fed only prd.md + research/*.json
#   4. Plan, Plan Review, Test Writer, Implementer each run as cold workers fed
#      only their own artifacts
#   5. A Stage artifact missing its decisions/rationale is REFUSED by run.sh
#   6. The summary marks each Stage `⊘ isolated`; an inline fallback is flagged
#   7. A malformed worker output stops the Stage (no advance) and retries first
#   8. The whole flow runs against a stubbed worker with no real tokens

# A canned LCARS worker. Records every call (role + tools to $WORKER_LOG, the
# full prompt to $WORKER_CALLS/<role>.<pid>.txt) and writes role-appropriate
# output into $LCARS_WORK_OUT — the exact channel a real worker would use. Knobs:
#   STUB_NQUESTIONS  how many questions the question-gen worker emits (default 2)
#   STUB_SCOPE=1     the Validator raises a scope question (→ pause)
#   STUB_MALFORMED=1 the named role emits an artifact that fails validation
make_worker_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""; tools=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --allowedTools) tools="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'role=%s tools=%s\n' "$LCARS_WORKER_ROLE" "$tools" >>"$WORKER_LOG"
printf '%s' "$prompt" >"$WORKER_CALLS/$LCARS_WORKER_ROLE.$$.txt"
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  research-questions)
    : >"$out/questions.txt"
    k="${STUB_NQUESTIONS:-2}"; i=0
    while [ "$i" -lt "$k" ]; do i=$((i+1)); echo "Stub question $i about the design?" >>"$out/questions.txt"; done
    ;;
  research-agent)
    cat >"$out/response.json" <<JSON
{
  "question": "stub question",
  "recommendation": "Do the sensible thing.",
  "supporting_points": ["because A", "because B"]
}
JSON
    ;;
  validate)
    [ "${STUB_SCOPE:-0}" = "1" ] && printf 'Global or per-course leaderboard?\n' >"$out/scope.txt"
    # Option B: a refined ADR when research changed a decision (STUB_ADR=1).
    if [ "${STUB_ADR:-0}" = "1" ]; then
      cat >"$out/adr.md" <<ADR
# Architecture Decision Records: Add dark mode (REFINED BY VALIDATE)

## ADR-001: Theme delivery via data-theme

**Context:** Research confirmed the token layer.
**Decision:** Flip a data-theme attribute on <html>.
**Alternatives considered:** A parallel dark stylesheet.
**Consequences:** Reuses the token layer.
ADR
    fi
    cat >"$out/validated-plan.md" <<MD
# Validated Plan: Add dark mode

## Synthesis
A CSS-variable theme driven by a persisted toggle.

## Decisions
- Flip data-theme on <html>.

## Rationale
Reusing the existing tokens is the cheapest path to the PRD.
MD
    ;;
  plan)
    if [ "${STUB_MALFORMED:-0}" = "1" ]; then
      # A ticket missing its rationale — plan-save must refuse it.
      cat >"$out/plan.json" <<JSON
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": []
  }
]
JSON
    else
      cat >"$out/plan.json" <<JSON
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Foundational token layer every later slice paints on."
  }
]
JSON
    fi
    # Session 41: the Planner ALSO emits one manifest per ticket (separate files,
    # never embedded in plan.json). Signatures + paths + touched ADR ids ONLY —
    # the fixture is deliberately bodies-free so persistence can assert no leak.
    # STUB_NO_MANIFEST=1 simulates a worker that skipped a manifest (best-effort
    # persistence must not hard-fail the plan).
    if [ "${STUB_NO_MANIFEST:-0}" != "1" ]; then
      mkdir -p "$out/manifests"
      cat >"$out/manifests/t-001.md" <<MAN
# Context manifest: t-001 — Wire the data-theme attribute

## Relevant files
- src/theme.js
- src/index.html

## Interface signatures (locations only — NOT the implementation)
- src/theme.js: \`export function setTheme(name)\`
- src/theme.js: \`export function currentTheme()\`

## ADRs this ticket touches
- ADR-001
MAN
    fi
    ;;
  plan-review)
    cat >"$out/verdict.json" <<JSON
{
  "passed": true,
  "issues": []
}
JSON
    ;;
  implement-test-writer)
    mkdir -p "$out/tests"
    printf 'describe("t", () => it("works", () => expect(false).toBe(true)))\n' >"$out/tests/stub.test.js"
    ;;
  implement-implementer)
    printf 'export const ok = true;\n' > impl-output.js
    tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
    cat >"$out/result.json" <<JSON
{
  "ticketId": "${tid:-t-001}",
  "passed": true,
  "attempts": 2,
  "summary": "Implemented the slice; suite green."
}
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# Fetch the recorded tool set / prompt for a role (trailing space disambiguates
# role=plan from role=plan-review).
tools_for_role()  { grep "role=$2 " "$1" 2>/dev/null | head -1 | sed 's/.*tools=//'; }
prompt_for_role() { cat "$1/$2".*.txt 2>/dev/null; }
calls_of_role()   { grep -c "role=$2 " "$1" 2>/dev/null; }

# Wire a repo for a worker-driven Stage: a worker stub + a gh stub + the call log.
# Echoes nothing; exports WORKER_LOG / WORKER_CALLS for the caller's assertions.
arm_worker() { # repo
  make_worker_stub "$1/worker"; make_gh_stub "$1/gh"
  export GH_LOG="$1/gh.log"; : >"$GH_LOG"
  export WORKER_LOG="$1/worker.log"; : >"$WORKER_LOG"
  export WORKER_CALLS="$1/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
}

# --- Behaviour 1: the spawn helper passes template + PATHS only, restricted ---
# Driven through Validate: the worker's prompt must name the artifact PATHS (so
# it Reads them itself) and must NOT contain the inlined PRD body — that is what
# makes the cold hand-off airtight (no orchestrator context can leak in). And the
# tool set is restricted to the Stage's needs (read-only on the repo: Read yes,
# Bash/WebSearch no).
repoW1="$(new_repo_with_validate_mission)"; arm_worker "$repoW1"
( cd "$repoW1" && LCARS_WORKER_BIN="$repoW1/worker" LCARS_GH_BIN="$repoW1/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 )
VP1="$(prompt_for_role "$WORKER_CALLS" validate)"
VT1="$(tools_for_role "$WORKER_LOG" validate)"
MDIR1="$repoW1/.git/lcars/missions/$MID"
check "1. worker prompt carries the template (the Validator brief)" \
  "printf '%s' \"\$VP1\" | grep -q 'LCARS Validator'"
check "1. worker prompt names the prd.md PATH it may read" \
  "printf '%s' \"\$VP1\" | grep -qF '$MDIR1/prd.md'"
check "1. worker prompt names the research finding PATHS" \
  "printf '%s' \"\$VP1\" | grep -qF '$MDIR1/research/1.json'"
check "1. worker prompt does NOT inline the PRD body (paths only, no leaked context)" \
  "! printf '%s' \"\$VP1\" | grep -q 'Let users switch to a dark'"
check "1. validate worker gets read access (Read)" \
  "printf '%s' \"\$VT1\" | grep -q 'Read'"
check "1. validate worker is denied shell (no Bash)" \
  "! printf '%s' \"\$VT1\" | grep -q 'Bash'"
check "1. validate worker is denied web (no WebSearch)" \
  "! printf '%s' \"\$VT1\" | grep -q 'WebSearch'"

# --- Behaviour 2: Research fans out N stateless workers, question text only ----
repoW2="$(new_repo_with_mission)"; arm_worker "$repoW2"
rcW2=0
( cd "$repoW2" && STUB_NQUESTIONS=2 LCARS_WORKER_BIN="$repoW2/worker" LCARS_GH_BIN="$repoW2/gh" \
    bash "$SCRIPT" research --mission "$MID" >out.txt 2>&1 ) || rcW2=$?
check "2. research driver exits 0" "[ '$rcW2' -eq 0 ]"
check "2. runs exactly one question-generator worker" \
  "[ \"\$(calls_of_role "$WORKER_LOG" research-questions)\" = '1' ]"
check "2. fans out one research worker per question (2)" \
  "[ \"\$(calls_of_role "$WORKER_LOG" research-agent)\" = '2' ]"
RAP2="$(prompt_for_role "$WORKER_CALLS" research-agent)"
check "2. a research worker is given a question" \
  "printf '%s' \"\$RAP2\" | grep -qi 'question'"
check "2. a research worker is NOT given the PRD path (stateless)" \
  "! printf '%s' \"\$RAP2\" | grep -q 'prd.md'"
check "2. research worker gets web access (WebSearch)" \
  "printf '%s' \"\$(tools_for_role "$WORKER_LOG" research-agent)\" | grep -q 'WebSearch'"
check "2. research advanced the mission to validate via the stub" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repoW2")'"

# 0 questions → the question-gen worker yields an empty set and Research skips.
repoW2b="$(new_repo_with_mission)"; arm_worker "$repoW2b"
( cd "$repoW2b" && STUB_NQUESTIONS=0 LCARS_WORKER_BIN="$repoW2b/worker" LCARS_GH_BIN="$repoW2b/gh" \
    bash "$SCRIPT" research --mission "$MID" >out.txt 2>&1 )
check "2. zero questions → no research workers fan out" \
  "[ \"\$(calls_of_role "$WORKER_LOG" research-agent)\" = '0' ]"
check "2. zero questions still advances to validate (skip)" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repoW2b")'"

# --- Behaviour 3: Validate is one cold worker, fed only prd + research ---------
repoW3="$(new_repo_with_validate_mission)"; arm_worker "$repoW3"
rcW3=0
( cd "$repoW3" && LCARS_WORKER_BIN="$repoW3/worker" LCARS_GH_BIN="$repoW3/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 ) || rcW3=$?
check "3. validate driver exits 0" "[ '$rcW3' -eq 0 ]"
check "3. runs exactly one Validator worker" \
  "[ \"\$(calls_of_role "$WORKER_LOG" validate)\" = '1' ]"
check "3. persists the worker's plan and advances to plan" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW3")' && [ -f '$repoW3/.git/lcars/missions/$MID/validated-plan.md' ]"

# a scope question from the worker → pause at the human gate (validate-pause)
repoW3b="$(new_repo_with_validate_mission)"; arm_worker "$repoW3b"
( cd "$repoW3b" && STUB_SCOPE=1 LCARS_WORKER_BIN="$repoW3b/worker" LCARS_GH_BIN="$repoW3b/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 )
sW3b="$(state_of "$repoW3b")"
check "3. a worker scope question pauses at the human gate" \
  "grep -q '\"awaitingHuman\": *true' '$sW3b'"
check "3. the paused mission stays at validate" \
  "grep -q '\"stage\": *\"validate\"' '$sW3b'"

# --- Behaviour 3 (0-question fast path): Validate synthesises from the PRD alone
# A 0-question Research (unambiguous PRD) leaves NO research/ dir. Validate must
# treat zero findings as a valid input — synthesise from prd.md alone and advance
# — not hard-die "no research/ findings". Reproduces the live wedge where a
# 0-question Mission stuck at validate and every subsequent run re-failed.
repoW3c="$(new_repo_with_validate_mission)"; arm_worker "$repoW3c"
rm -rf "$repoW3c/.git/lcars/missions/$MID/research"   # 0-question Research → no findings dir
rcW3c=0
( cd "$repoW3c" && LCARS_WORKER_BIN="$repoW3c/worker" LCARS_GH_BIN="$repoW3c/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out3c.txt 2>&1 ) || rcW3c=$?
check "3. validate with no research/ does NOT die (exit 0)" "[ '$rcW3c' -eq 0 ]"
check "3. validate still runs exactly one Validator worker on the PRD alone" \
  "[ \"\$(calls_of_role "$WORKER_LOG" validate)\" = '1' ]"
check "3. validate (PRD-only) advances to plan" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW3c")'"
VP3c="$(prompt_for_role "$WORKER_CALLS" validate)"
MDIR3c="$repoW3c/.git/lcars/missions/$MID"
check "3. PRD-only validate still feeds the worker prd.md" \
  "printf '%s' \"\$VP3c\" | grep -qF '$MDIR3c/prd.md'"
check "3. PRD-only validate lists no research/*.json path" \
  "! printf '%s' \"\$VP3c\" | grep -qF '$MDIR3c/research/'"

# End-to-end: a 0-question Research then Validate must NOT wedge. Drive from align
# with STUB_NQUESTIONS=0: Research skips → Validate runs PRD-only → reaches plan.
repoW3d="$(new_repo_with_mission)"; arm_worker "$repoW3d"
( cd "$repoW3d" && STUB_NQUESTIONS=0 LCARS_WORKER_BIN="$repoW3d/worker" LCARS_GH_BIN="$repoW3d/gh" \
    bash "$SCRIPT" research --mission "$MID" >outr.txt 2>&1 )
check "3. 0-question research left no research/ dir" \
  "[ ! -d '$repoW3d/.git/lcars/missions/$MID/research' ]"
rcW3d=0
( cd "$repoW3d" && LCARS_WORKER_BIN="$repoW3d/worker" LCARS_GH_BIN="$repoW3d/gh" \
    bash "$SCRIPT" validate --mission "$MID" >outv.txt 2>&1 ) || rcW3d=$?
check "3. the 0-question Mission does NOT wedge at validate (advances)" \
  "[ '$rcW3d' -eq 0 ] && grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW3d")'"

# --- Behaviour 4: Plan / Plan Review / Test Writer / Implementer are cold ------
# Plan: fed only prd.md + validated-plan.md
repoW4p="$(new_repo_with_plan_mission)"; arm_worker "$repoW4p"
( cd "$repoW4p" && LCARS_WORKER_BIN="$repoW4p/worker" LCARS_GH_BIN="$repoW4p/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out.txt 2>&1 )
PP4="$(prompt_for_role "$WORKER_CALLS" plan)"
MDIR4="$repoW4p/.git/lcars/missions/$MID"
check "4. plan worker is fed the validated-plan path" \
  "printf '%s' \"\$PP4\" | grep -qF '$MDIR4/validated-plan.md'"
check "4. plan worker persists plan.json and advances to plan-review" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repoW4p")'"

# Plan Review: fed ONLY plan.json — never prd.md / validated-plan.md
repoW4r="$(new_repo_with_plan_review_mission)"; arm_worker "$repoW4r"
( cd "$repoW4r" && LCARS_WORKER_BIN="$repoW4r/worker" LCARS_GH_BIN="$repoW4r/gh" \
    bash "$SCRIPT" plan-review --mission "$MID" >out.txt 2>&1 )
PR4="$(prompt_for_role "$WORKER_CALLS" plan-review)"
MDIR4r="$repoW4r/.git/lcars/missions/$MID"
check "4. reviewer worker is fed the plan.json path" \
  "printf '%s' \"\$PR4\" | grep -qF '$MDIR4r/plan.json'"
# Independence: the reviewer is never handed the spec PATHS (the template names
# those filenames only to forbid them — the artifact-paths block lists plan.json
# alone), so assert the mission-dir paths to the spec are absent.
check "4. reviewer worker is NOT fed the prd.md path (independence)" \
  "! printf '%s' \"\$PR4\" | grep -qF '$MDIR4r/prd.md'"
check "4. reviewer worker is NOT fed the validated-plan.md path (independence)" \
  "! printf '%s' \"\$PR4\" | grep -qF '$MDIR4r/validated-plan.md'"
check "4. reviewer verdict advances to schedule" \
  "grep -q '\"stage\": *\"schedule\"' '$(state_of "$repoW4r")'"

# Test Writer + Implementer: a cold pair, fed only their artifacts
repoW4i="$(new_repo_with_implement_mission)"; arm_worker "$repoW4i"
rcW4i=0
( cd "$repoW4i" && LCARS_WORKER_BIN="$repoW4i/worker" LCARS_GH_BIN="$repoW4i/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >out.txt 2>&1 ) || rcW4i=$?
MDIR4i="$repoW4i/.git/lcars/missions/$MID"
check "4. implement-ticket exits 0" "[ '$rcW4i' -eq 0 ]"
check "4. runs a Test Writer worker then an Implementer worker" \
  "[ \"\$(calls_of_role "$WORKER_LOG" implement-test-writer)\" = '1' ] && [ \"\$(calls_of_role "$WORKER_LOG" implement-implementer)\" = '1' ]"
check "4. Test Writer's tests are quarantined under tickets/t-001/tests/" \
  "[ -f '$MDIR4i/tickets/t-001/tests/stub.test.js' ]"
check "4. Implementer's result.json is saved green" \
  "[ -f '$MDIR4i/tickets/t-001/result.json' ] && grep -q '\"passed\": *true' '$MDIR4i/tickets/t-001/result.json'"
check "4. Implementer is fed the on-disk tests path (its only handoff)" \
  "printf '%s' \"\$(prompt_for_role "$WORKER_CALLS" implement-implementer)\" | grep -qF '$MDIR4i/tickets/t-001/tests'"
check "4. Test Writer is denied shell (no Bash)" \
  "! printf '%s' \"\$(tools_for_role "$WORKER_LOG" implement-test-writer)\" | grep -q 'Bash'"
check "4. Implementer gets shell (Bash) to run the tests" \
  "printf '%s' \"\$(tools_for_role "$WORKER_LOG" implement-implementer)\" | grep -q 'Bash'"

# --- Behaviour 9: the engineering ADR is a downstream-readable artifact --------
# Session 36: Align seeds adr.md for complex Missions; Validate may refine it.
# Every downstream worker EXCEPT the research agents may read it. These tests
# assert the assembled worker prompt LISTS the adr.md PATH when the file exists,
# for Validate / Plan / Test Writer / Implementer — and that the RESEARCH workers
# and Plan Review NEVER see it (purity + independence invariants).

# Drop a well-formed adr.md into a mission dir.
seed_adr() { # mission-dir
  cat >"$1/adr.md" <<'EOF'
# Architecture Decision Records: Add dark mode

## ADR-001: Theme delivery via data-theme

**Context:** The app ships a --color-* token layer.
**Decision:** Flip a data-theme attribute on <html>.
**Alternatives considered:** A parallel dark stylesheet.
**Consequences:** Reuses the token layer; no parallel colour system.
EOF
}

# 9a. Validate lists adr.md when it exists (Align-seeds / Validate-refines).
repoW9v="$(new_repo_with_validate_mission)"; arm_worker "$repoW9v"
MDIR9v="$repoW9v/.git/lcars/missions/$MID"
seed_adr "$MDIR9v"
( cd "$repoW9v" && LCARS_WORKER_BIN="$repoW9v/worker" LCARS_GH_BIN="$repoW9v/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 )
VP9v="$(prompt_for_role "$WORKER_CALLS" validate)"
check "9a. validate worker is fed the adr.md path when it exists" \
  "printf '%s' \"\$VP9v\" | grep -qF '$MDIR9v/adr.md'"

# Option B persistence: cmd_validate must copy a worker-refined adr.md back into
# the mission dir. The worker stub (STUB_ADR=1) emits a refined adr.md; assert it
# overwrites the seeded one in the mission dir.
repoW9vr="$(new_repo_with_validate_mission)"; arm_worker "$repoW9vr"
MDIR9vr="$repoW9vr/.git/lcars/missions/$MID"
seed_adr "$MDIR9vr"
( cd "$repoW9vr" && STUB_ADR=1 LCARS_WORKER_BIN="$repoW9vr/worker" LCARS_GH_BIN="$repoW9vr/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 )
check "9a. a worker-refined adr.md persists into the mission dir (option B)" \
  "[ -f '$MDIR9vr/adr.md' ] && grep -q 'REFINED BY VALIDATE' '$MDIR9vr/adr.md'"

# 9b. Validate does NOT list adr.md when the Mission has none (trivial Mission).
repoW9vn="$(new_repo_with_validate_mission)"; arm_worker "$repoW9vn"
MDIR9vn="$repoW9vn/.git/lcars/missions/$MID"
( cd "$repoW9vn" && LCARS_WORKER_BIN="$repoW9vn/worker" LCARS_GH_BIN="$repoW9vn/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 )
VP9vn="$(prompt_for_role "$WORKER_CALLS" validate)"
check "9b. validate worker is NOT fed an adr.md path when none exists" \
  "! printf '%s' \"\$VP9vn\" | grep -qF '$MDIR9vn/adr.md'"

# 9c. Plan lists adr.md when it exists.
repoW9p="$(new_repo_with_plan_mission)"; arm_worker "$repoW9p"
MDIR9p="$repoW9p/.git/lcars/missions/$MID"
seed_adr "$MDIR9p"
( cd "$repoW9p" && LCARS_WORKER_BIN="$repoW9p/worker" LCARS_GH_BIN="$repoW9p/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out.txt 2>&1 )
PP9p="$(prompt_for_role "$WORKER_CALLS" plan)"
check "9c. plan worker is fed the adr.md path when it exists" \
  "printf '%s' \"\$PP9p\" | grep -qF '$MDIR9p/adr.md'"

# 9d. Test Writer AND Implementer list adr.md when it exists.
repoW9i="$(new_repo_with_implement_mission)"; arm_worker "$repoW9i"
MDIR9i="$repoW9i/.git/lcars/missions/$MID"
seed_adr "$MDIR9i"
( cd "$repoW9i" && LCARS_WORKER_BIN="$repoW9i/worker" LCARS_GH_BIN="$repoW9i/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >out.txt 2>&1 )
TWP9i="$(prompt_for_role "$WORKER_CALLS" implement-test-writer)"
IMP9i="$(prompt_for_role "$WORKER_CALLS" implement-implementer)"
check "9d. Test Writer worker is fed the adr.md path when it exists" \
  "printf '%s' \"\$TWP9i\" | grep -qF '$MDIR9i/adr.md'"
check "9d. Implementer worker is fed the adr.md path when it exists" \
  "printf '%s' \"\$IMP9i\" | grep -qF '$MDIR9i/adr.md'"

# 9e. PURITY: the RESEARCH workers NEVER see adr.md, even when it exists. Drive
# Research from align with an adr.md already on disk; assert neither the
# question-generator nor any research agent prompt names the adr path.
repoW9r="$(new_repo_with_mission)"; arm_worker "$repoW9r"
MDIR9r="$repoW9r/.git/lcars/missions/$MID"
seed_adr "$MDIR9r"
( cd "$repoW9r" && STUB_NQUESTIONS=2 LCARS_WORKER_BIN="$repoW9r/worker" LCARS_GH_BIN="$repoW9r/gh" \
    bash "$SCRIPT" research --mission "$MID" >out.txt 2>&1 )
RQP9r="$(prompt_for_role "$WORKER_CALLS" research-questions)"
RAP9r="$(prompt_for_role "$WORKER_CALLS" research-agent)"
check "9e. PURITY: research-questions worker is NEVER fed adr.md" \
  "! printf '%s' \"\$RQP9r\" | grep -qF '$MDIR9r/adr.md'"
check "9e. PURITY: research-questions worker mentions no adr at all" \
  "! printf '%s' \"\$RQP9r\" | grep -qi 'adr'"
check "9e. PURITY: a research agent worker is NEVER fed adr.md" \
  "! printf '%s' \"\$RAP9r\" | grep -qF '$MDIR9r/adr.md'"
check "9e. PURITY: a research agent worker mentions no adr at all" \
  "! printf '%s' \"\$RAP9r\" | grep -qi 'adr'"

# 9f. INDEPENDENCE: Plan Review NEVER sees adr.md (it judges tickets alone; the
# ADR is seeded planning context that would leak the spec in).
repoW9pr="$(new_repo_with_plan_review_mission)"; arm_worker "$repoW9pr"
MDIR9pr="$repoW9pr/.git/lcars/missions/$MID"
seed_adr "$MDIR9pr"
( cd "$repoW9pr" && LCARS_WORKER_BIN="$repoW9pr/worker" LCARS_GH_BIN="$repoW9pr/gh" \
    bash "$SCRIPT" plan-review --mission "$MID" >out.txt 2>&1 )
PRP9pr="$(prompt_for_role "$WORKER_CALLS" plan-review)"
check "9f. INDEPENDENCE: Plan Review worker is NOT fed the adr.md path" \
  "! printf '%s' \"\$PRP9pr\" | grep -qF '$MDIR9pr/adr.md'"

# --- Behaviour 5: an artifact missing its decisions/rationale is REFUSED -------
# validated-plan.md without a ## Rationale section
repoW5a="$(new_repo_with_validate_mission)"; make_gh_stub "$repoW5a/gh"
export GH_LOG="$repoW5a/gh.log"; : >"$GH_LOG"
printf '# Validated Plan: x\n\n## Synthesis\ns\n\n## Decisions\n- d\n' >"$repoW5a/norat.md"
rcW5a=0
( cd "$repoW5a" && LCARS_GH_BIN="$repoW5a/gh" bash "$SCRIPT" validate-advance \
    --mission "$MID" --plan "$repoW5a/norat.md" >out.txt 2>&1 ) || rcW5a=$?
check "5. validate-advance refuses a plan with no ## Rationale" "[ '$rcW5a' -ne 0 ]"
check "5. names the missing rationale in the error" \
  "grep -qi 'rationale' '$repoW5a/out.txt'"
check "5. does not advance a plan missing its rationale" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repoW5a")'"

# plan.json with a ticket missing its rationale
repoW5b="$(new_repo_with_plan_mission)"; make_gh_stub "$repoW5b/gh"
export GH_LOG="$repoW5b/gh.log"; : >"$GH_LOG"
cat >"$repoW5b/norat.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": []
  }
]
EOF
rcW5b=0
( cd "$repoW5b" && LCARS_GH_BIN="$repoW5b/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoW5b/norat.json" >out.txt 2>&1 ) || rcW5b=$?
check "5. plan-save refuses a ticket with no rationale" "[ '$rcW5b' -ne 0 ]"
check "5. names the missing rationale field in the error" \
  "grep -q 'rationale' '$repoW5b/out.txt'"
check "5. does not advance a plan whose ticket drops its rationale" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW5b")'"

# --- Behaviour 6: the `⊘ isolated` marker; an inline fallback is flagged -------
repoW6="$(new_repo_with_plan_mission)"; arm_worker "$repoW6"
( cd "$repoW6" && LCARS_WORKER_BIN="$repoW6/worker" LCARS_GH_BIN="$repoW6/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out.txt 2>&1 )
check "6. the Stage summary is marked '⊘ isolated'" \
  "grep -q 'isolated' '$repoW6/out.txt'"
check "6. the isolated marker names the worker it ran in" \
  "grep -q 'worker' '$repoW6/out.txt'"

# No worker binary available → the Stage must refuse LOUDLY, never fake isolation
repoW6b="$(new_repo_with_plan_mission)"; make_gh_stub "$repoW6b/gh"
export GH_LOG="$repoW6b/gh.log"; : >"$GH_LOG"
rcW6b=0
( cd "$repoW6b" && LCARS_WORKER_BIN="/nonexistent/lcars-worker" LCARS_GH_BIN="$repoW6b/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out.txt 2>&1 ) || rcW6b=$?
check "6. refuses to run a Stage with no cold worker available" "[ '$rcW6b' -ne 0 ]"
check "6. flags the non-isolated condition LOUDLY (NOT ISOLATED)" \
  "grep -q 'NOT ISOLATED' '$repoW6b/out.txt'"
check "6. an un-isolatable Stage never advances" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW6b")'"
check "6. an un-isolatable Stage is never marked isolated" \
  "! grep -q '⊘ isolated' '$repoW6b/out.txt'"

# --- Behaviour 7: a malformed worker output stops the Stage, after retries -----
repoW7="$(new_repo_with_plan_mission)"; arm_worker "$repoW7"
rcW7=0
( cd "$repoW7" && STUB_MALFORMED=1 LCARS_WORKER_TRIES=2 \
    LCARS_WORKER_BIN="$repoW7/worker" LCARS_GH_BIN="$repoW7/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out.txt 2>&1 ) || rcW7=$?
check "7. a malformed worker output stops the Stage (non-zero)" "[ '$rcW7' -ne 0 ]"
check "7. the Stage does not advance on malformed output" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoW7")'"
check "7. writes no plan.json on malformed output" \
  "[ ! -f '$repoW7/.git/lcars/missions/$MID/plan.json' ]"
check "7. re-dispatches the worker before surfacing failure (2 tries)" \
  "[ \"\$(calls_of_role "$WORKER_LOG" plan)\" = '2' ]"

# --- Behaviour 8: the whole flow runs against the stub, no real tokens ---------
# align → research → validate → plan → plan-review → schedule → implement → verify
repoW8="$(new_repo_with_mission)"
make_worker_stub "$repoW8/worker"; make_gh_stub_schedule "$repoW8/gh"
export GH_LOG="$repoW8/gh.log"; : >"$GH_LOG"
export GH_SEQ="$repoW8/gh.seq"; rm -f "$GH_SEQ"
export WORKER_LOG="$repoW8/worker.log"; : >"$WORKER_LOG"
export WORKER_CALLS="$repoW8/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
sW8="$(state_of "$repoW8")"
run8() { ( cd "$repoW8" && STUB_NQUESTIONS=1 LCARS_WORKER_BIN="$repoW8/worker" \
    LCARS_GH_BIN="$repoW8/gh" bash "$SCRIPT" "$@" >>"$repoW8/flow.txt" 2>&1 ); }
flow_rc=0
run8 research --mission "$MID"              || flow_rc=$?
run8 validate --mission "$MID"              || flow_rc=$?
run8 plan --mission "$MID"                  || flow_rc=$?
run8 plan-review --mission "$MID"           || flow_rc=$?
run8 schedule --mission "$MID"              || flow_rc=$?
run8 implement-ticket --mission "$MID" --ticket t-001 || flow_rc=$?
run8 impl-advance --mission "$MID"          || flow_rc=$?
check "8. the full stubbed flow runs clean end-to-end" "[ '$flow_rc' -eq 0 ]"
check "8. the mission reaches the verify gate" \
  "grep -q '\"stage\": *\"verify\"' '$sW8'"
check "8. every headless Stage ran in a cold worker (no inline reasoning)" \
  "grep -q 'role=research-questions' '$WORKER_LOG' && grep -q 'role=validate' '$WORKER_LOG' && grep -q 'role=plan ' '$WORKER_LOG' && grep -q 'role=plan-review' '$WORKER_LOG' && grep -q 'role=implement-implementer' '$WORKER_LOG'"

# ==========================================================================
echo
echo "lcars run — auto-advance driver + walk-away notifications"
#
# `lcars run <id>` now auto-advances: a thin, token-free bash loop (the `drive`
# subcommand) sequences the per-stage advances built in sessions 4–12, each a
# cold isolated worker, until a halt condition. `--step` does exactly ONE stage
# (the old behaviour). At a human gate the loop fires the notify hook once. These
# tests stub the worker ($LCARS_WORKER_BIN), gh, and the notify hook
# ($LCARS_NOTIFY) so the whole loop runs with no real tokens and no real pings.
#   1.  --step advances exactly one stage and stops
#   2.  auto mode advances through multiple stages in one invocation
#   3.  auto mode halts at "verify" without running it
#   4.  auto mode halts at an awaiting-human gate, printing the pending question
#   5.  auto mode halts at "align" (a feedback re-entry needs a human)
#   6.  auto mode stops and surfaces the error when a stage fails
#   7.  the stage-by-stage summary is printed on halt
#   8.  the summary still marks each headless stage `⊘ isolated`
#   9.  the notify hook fires exactly once at an awaiting-human / verify halt
#   10. no notification fires on a clean stage-to-stage transition
#   11. notify delivery is configurable (banner default, ntfy on a topic) + stubbable

# A notify recorder: one "<id>|<gate>|<summary>" line per call to $NOTIFY_LOG.
make_notify_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$1"
}

# Wire a repo for the driver: worker stub + schedule-capable gh + notify recorder.
arm_drive() { # repo
  make_worker_stub "$1/worker"; make_gh_stub_schedule "$1/gh"; make_notify_stub "$1/notify"
  export GH_LOG="$1/gh.log"; : >"$GH_LOG"
  export GH_SEQ="$1/gh.seq"; rm -f "$GH_SEQ"
  export WORKER_LOG="$1/worker.log"; : >"$WORKER_LOG"
  export WORKER_CALLS="$1/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
  export NOTIFY_LOG="$1/notify.log"; : >"$NOTIFY_LOG"
}
# Run the driver in a repo; stdout+stderr land in <repo>/drive.out; returns rc.
drive() { # repo args...
  local repo="$1"; shift
  ( cd "$repo" && STUB_NQUESTIONS=1 \
      LCARS_WORKER_BIN="$repo/worker" LCARS_GH_BIN="$repo/gh" LCARS_NOTIFY="$repo/notify" \
      bash "$SCRIPT" "$@" >"$repo/drive.out" 2>&1 )
}

# --- Behaviour 1: --step advances exactly one stage and stops --------------
repoA1="$(new_repo_with_validate_mission)"; arm_drive "$repoA1"
rcA1=0; drive "$repoA1" drive --mission "$MID" --step || rcA1=$?
check "1. --step exits 0" "[ '$rcA1' -eq 0 ]"
check "1. --step advances exactly one stage (validate → plan)" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoA1")'"
check "1. --step ran the validate worker once" \
  "[ \"\$(calls_of_role "$repoA1/worker.log" validate)\" = '1' ]"
check "1. --step did NOT continue into Plan / Plan Review" \
  "[ \"\$(calls_of_role "$repoA1/worker.log" plan)\" = '0' ] && [ \"\$(calls_of_role "$repoA1/worker.log" plan-review)\" = '0' ]"

# --- Behaviours 2/7/8/9: auto mode runs many stages → halts at verify -------
# A fresh align mission (no feedback.md) auto-advances research → validate →
# plan → plan-review → schedule → implement, then stops at the verify gate.
repoA2="$(new_repo_with_mission)"; arm_drive "$repoA2"
rcA2=0; drive "$repoA2" drive --mission "$MID" || rcA2=$?
sA2="$(state_of "$repoA2")"
check "2. auto mode exits 0 at the verify gate" "[ '$rcA2' -eq 0 ]"
check "2. auto mode advanced all the way to verify in one invocation" \
  "grep -q '\"stage\": *\"verify\"' '$sA2'"
check "2. auto mode ran every headless stage's worker" \
  "grep -q 'role=research-questions' '$repoA2/worker.log' && grep -q 'role=validate' '$repoA2/worker.log' && grep -q 'role=plan ' '$repoA2/worker.log' && grep -q 'role=plan-review' '$repoA2/worker.log' && grep -q 'role=implement-implementer' '$repoA2/worker.log'"
check "7. the summary lists each stage that ran" \
  "grep -q 'research' '$repoA2/drive.out' && grep -q 'validate' '$repoA2/drive.out' && grep -q 'plan-review' '$repoA2/drive.out' && grep -q 'schedule' '$repoA2/drive.out' && grep -q 'implement' '$repoA2/drive.out'"
check "7. the summary names where it stopped (verify)" \
  "grep -qi 'stopped' '$repoA2/drive.out' && grep -q 'verify' '$repoA2/drive.out'"
check "8. the summary still marks the stages '⊘ isolated' (cold-worker regression)" \
  "grep -q 'isolated' '$repoA2/drive.out'"
check "9. the notify hook fires exactly once at the verify gate" \
  "[ \"\$(grep -c . "$repoA2/notify.log")\" = '1' ]"
check "9. the notification names the verify gate" \
  "grep -q '|verify|' '$repoA2/notify.log'"
check "9. the notification carries a non-empty decision-ready summary" \
  "[ -n \"\$(awk -F'|' 'NR==1{print \$3}' "$repoA2/notify.log")\" ]"

# --- Behaviour 3: auto mode halts AT verify without running it --------------
# Seed a mission already parked at verify (Implement done): the driver must stop
# without spawning any worker and without changing the stage.
repoA3="$(new_repo_with_implement_mission)"; arm_drive "$repoA3"
# advance it cleanly to verify first (its own implement run), then re-drive.
drive "$repoA3" drive --mission "$MID" >/dev/null 2>&1 || true
: >"$repoA3/worker.log"; : >"$repoA3/notify.log"   # reset the logs for the re-drive
rcA3=0; drive "$repoA3" drive --mission "$MID" || rcA3=$?
check "3. re-driving a verify mission exits 0" "[ '$rcA3' -eq 0 ]"
check "3. it stays parked at verify (never auto-passed)" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoA3")'"
check "3. it spawns NO worker at the verify gate" "[ ! -s '$repoA3/worker.log' ]"
check "3. it reports the verify halt" \
  "grep -qi 'stopped' '$repoA3/drive.out' && grep -q 'verify' '$repoA3/drive.out'"

# --- Behaviours 4/9: auto mode halts at an awaiting-human gate --------------
# A scope-change question (STUB_SCOPE=1) pauses Validate → awaiting-human.
repoA4="$(new_repo_with_validate_mission)"; arm_drive "$repoA4"
rcA4=0
( cd "$repoA4" && STUB_SCOPE=1 STUB_NQUESTIONS=1 \
    LCARS_WORKER_BIN="$repoA4/worker" LCARS_GH_BIN="$repoA4/gh" LCARS_NOTIFY="$repoA4/notify" \
    bash "$SCRIPT" drive --mission "$MID" >"$repoA4/drive.out" 2>&1 ) || rcA4=$?
sA4="$(state_of "$repoA4")"
check "4. auto mode exits 0 at the awaiting-human gate" "[ '$rcA4' -eq 0 ]"
check "4. the mission is parked awaiting-human" "grep -q '\"awaitingHuman\": *true' '$sA4'"
check "4. the stage stays at validate (the escalating stage)" \
  "grep -q '\"stage\": *\"validate\"' '$sA4'"
check "4. the halt prints the pending question" \
  "grep -qi 'leaderboard' '$repoA4/drive.out'"
check "4. the halt hints at lcars respond" \
  "grep -q 'lcars respond' '$repoA4/drive.out'"
check "9. the notify hook fires exactly once at the awaiting-human gate" \
  "[ \"\$(grep -c . "$repoA4/notify.log")\" = '1' ]"
check "9. the notification names the awaiting-human gate" \
  "grep -q '|awaiting-human|' '$repoA4/notify.log'"
check "9. the notification summary carries the question (decision-ready)" \
  "awk -F'|' 'NR==1{print \$3}' '$repoA4/notify.log' | grep -qi 'leaderboard'"

# --- Behaviour 5: auto mode halts at align (feedback re-entry) --------------
repoA5="$(new_repo_with_mission)"; arm_drive "$repoA5"
printf '## Feedback 2026-06-04\nThe toggle should default to the OS theme.\n' \
  >"$repoA5/.git/lcars/missions/$MID/feedback.md"
rcA5=0; drive "$repoA5" drive --mission "$MID" || rcA5=$?
check "5. a feedback re-entry halts cleanly (exit 0)" "[ '$rcA5' -eq 0 ]"
check "5. it stays at align (an interactive re-grill is required)" \
  "grep -q '\"stage\": *\"align\"' '$(state_of "$repoA5")'"
check "5. it spawns NO worker (Align is not automatable)" "[ ! -s '$repoA5/worker.log' ]"
check "5. it explains the interactive Align re-entry" \
  "grep -qi 'align' '$repoA5/drive.out' && grep -qi 'feedback\|re-grill\|interactive' '$repoA5/drive.out'"
check "5. no notification fires for an align halt" "[ ! -s '$repoA5/notify.log' ]"

# --- Behaviour 6: a stage error stops auto mode and is surfaced -------------
# A malformed Plan worker output (after retries) fails the plan stage.
repoA6="$(new_repo_with_plan_mission)"; arm_drive "$repoA6"
rcA6=0
( cd "$repoA6" && STUB_MALFORMED=1 LCARS_WORKER_TRIES=2 \
    LCARS_WORKER_BIN="$repoA6/worker" LCARS_GH_BIN="$repoA6/gh" LCARS_NOTIFY="$repoA6/notify" \
    bash "$SCRIPT" drive --mission "$MID" >"$repoA6/drive.out" 2>&1 ) || rcA6=$?
check "6. a failing stage stops auto mode with a non-zero exit" "[ '$rcA6' -ne 0 ]"
check "6. the failing stage does not advance the mission" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoA6")'"
check "6. the error is surfaced to the human" \
  "grep -qi 'plan' '$repoA6/drive.out' && grep -qi 'stopped\|fail' '$repoA6/drive.out'"
check "6. no notification fires on an error (only at a human gate)" \
  "[ ! -s '$repoA6/notify.log' ]"

# --- Behaviour 10: no notification on a clean stage-to-stage transition -----
# A single --step over a non-gate transition (validate → plan) must NOT ping.
repoA10="$(new_repo_with_validate_mission)"; arm_drive "$repoA10"
drive "$repoA10" drive --mission "$MID" --step || true
check "10. a clean stage-to-stage --step advances the stage" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoA10")'"
check "10. a clean stage-to-stage transition fires NO notification" \
  "[ ! -s '$repoA10/notify.log' ]"

# --- Behaviour 11: notify delivery is configurable + stubbable --------------
# Drive the bundled notify hook directly with a stubbed curl: banner always,
# ntfy push only when a topic is configured.
NOTIFY_SH="$REPO_ROOT/skills/lcars-run/notify.sh"
check "11. the notify hook ships next to run.sh" "[ -f '$NOTIFY_SH' ]"
curlstub="$TMPROOT/curl"
cat >"$curlstub" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$CURL_LOG"
exit 0
EOF
chmod +x "$curlstub"

# (a) no topic → local banner only, no push
export CURL_LOG="$TMPROOT/curl.a.log"; : >"$CURL_LOG"
outNa="$( LCARS_CURL_BIN="$curlstub" LCARS_NTFY_TOPIC="" LCARS_NOTIFY_NO_DESKTOP=1 \
  bash "$NOTIFY_SH" "$MID" verify "Mission ready for review" 2>&1 )"
check "11. the default delivery prints a local banner" \
  "printf '%s' \"$outNa\" | grep -q '$MID'"
check "11. the banner carries the decision-ready summary" \
  "printf '%s' \"$outNa\" | grep -qi 'ready for review'"
check "11. no phone push fires without a configured topic" "[ ! -s '$CURL_LOG' ]"

# (b) ntfy topic set → push to ntfy on that topic
export CURL_LOG="$TMPROOT/curl.b.log"; : >"$CURL_LOG"
( LCARS_CURL_BIN="$curlstub" LCARS_NTFY_TOPIC="lcars-alerts" LCARS_NOTIFY_NO_DESKTOP=1 \
  bash "$NOTIFY_SH" "$MID" awaiting-human "Scope question: per-course or global?" >/dev/null 2>&1 )
check "11. an ntfy topic opts the mission into a phone push" "grep -q 'ntfy' '$CURL_LOG'"
check "11. the push targets the configured topic" "grep -q 'lcars-alerts' '$CURL_LOG'"

# ==========================================================================
echo
echo "lcars run — resume defects (the captain's answer + a clean commit)"

# --- FIX 1: the captain's answer reaches the cold worker on resume ----------
# `lcars respond` writes answers.json and clears awaitingHuman. The re-run
# Validator MUST be fed answers.json — otherwise it re-asks the same scope
# question and the awaiting-human gate loops forever.
repoF1="$(new_repo_with_validate_mission)"; arm_worker "$repoF1"
mF1="$repoF1/.git/lcars/missions/$MID"
cat >"$mF1/answers.json" <<'EOF'
{
  "answers": [
    { "question": "Global or per-course leaderboard?", "answer": "Per-course for now." }
  ]
}
EOF
rcF1=0
( cd "$repoF1" && LCARS_WORKER_BIN="$repoF1/worker" LCARS_GH_BIN="$repoF1/gh" \
    bash "$SCRIPT" validate --mission "$MID" >out.txt 2>&1 ) || rcF1=$?
check "F1. validate exits 0 after consuming the answer" "[ '$rcF1' -eq 0 ]"
check "F1. the Validator worker prompt was fed answers.json (the resolution)" \
  "printf '%s' \"\$(prompt_for_role "$WORKER_CALLS" validate)\" | grep -qF '$mF1/answers.json'"
check "F1. the resolved mission advances to plan (no re-escalation)" \
  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoF1")'"
check "F1. validate-advance cleared the consumed answers.json" \
  "[ ! -f '$mF1/answers.json' ]"

# Plan Review is fed answers.json too on a round-3 resume.
repoF1b="$(new_repo_with_plan_review_mission)"; arm_worker "$repoF1b"
mF1b="$repoF1b/.git/lcars/missions/$MID"
printf '{ "answers": [ { "question": "split t-001?", "answer": "Override — proceed." } ] }\n' >"$mF1b/answers.json"
( cd "$repoF1b" && LCARS_WORKER_BIN="$repoF1b/worker" LCARS_GH_BIN="$repoF1b/gh" \
    bash "$SCRIPT" plan-review --mission "$MID" >out.txt 2>&1 ) || true
check "F1. the Plan Review worker prompt was fed answers.json" \
  "printf '%s' \"\$(prompt_for_role "$WORKER_CALLS" plan-review)\" | grep -qF '$mF1b/answers.json'"

# --- FIX 2: commit_ticket stages ONLY the Implementer's source --------------
# An unrelated untracked file (the captain's) and the worker's `.lcars-*` scratch
# must NOT land on the mission branch — only the produced source.
make_worker_stub_commit() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/t.test.js" ;;
  implement-implementer)
    mkdir -p src; printf 'export const feature = 1;\n' > src/feature.js   # produced source → commit
    printf '#!/bin/sh\necho scratch\n' > .lcars-runner.sh                 # worker scratch → never commit
    cat >"$out/result.json" <<JSON
{
  "ticketId": "t-001",
  "passed": true,
  "attempts": 1,
  "summary": "built the feature; suite green."
}
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

repoF2="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$repoF2" && git init -q && git config user.email t@t && git config user.name t \
    && printf '# seed\n' > seed.md && git add seed.md && git commit -qm seed )
mF2="$repoF2/.git/lcars/missions/$MID"; mkdir -p "$mF2"
write_approved_plan_json "$mF2/approved-plan.json"
write_waves_json "$mF2/waves.json"
cat >"$mF2/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "branch": "lcars/$MID",
  "githubIssue": 42
}
EOF
# All test infra lives OUTSIDE the repo tree so it never shows up as untracked.
binF2="$TMPROOT/f2bin"; rm -rf "$binF2"; mkdir -p "$binF2"
make_worker_stub_commit "$binF2/worker"; make_gh_stub "$binF2/gh"
export GH_LOG="$binF2/gh.log"; : >"$GH_LOG"
export WORKER_LOG="$binF2/worker.log"; : >"$WORKER_LOG"
export WORKER_CALLS="$binF2/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
# the captain's unrelated untracked file, present BEFORE the ticket builds
printf 'a bug note\n' > "$repoF2/bugs.md"
rcF2=0
( cd "$repoF2" && LCARS_WORKER_BIN="$binF2/worker" LCARS_GH_BIN="$binF2/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >"$binF2/out.txt" 2>&1 ) || rcF2=$?
statF2="$( cd "$repoF2" && git show --stat --oneline HEAD 2>/dev/null )"
check "F2. implement-ticket exits 0 (green ticket committed)" "[ '$rcF2' -eq 0 ]"
check "F2. a commit landed on the mission branch" \
  "[ \"\$( cd "$repoF2" && git rev-parse --abbrev-ref HEAD )\" = 'lcars/$MID' ]"
check "F2. the commit includes the Implementer's produced source" \
  "printf '%s' \"$statF2\" | grep -q 'src/feature.js'"
check "F2. the commit EXCLUDES the captain's unrelated untracked file" \
  "! printf '%s' \"$statF2\" | grep -q 'bugs.md'"
check "F2. the commit EXCLUDES the worker's .lcars-* scratch" \
  "! printf '%s' \"$statF2\" | grep -q 'lcars-runner.sh'"
check "F2. the unrelated file is left untracked in the working tree" \
  "[ -f '$repoF2/bugs.md' ] && [ -z \"\$( cd "$repoF2" && git ls-files bugs.md )\" ]"

# ==========================================================================
echo
echo "lcars run — scoped commits + scratch hygiene (Session 30)"

# Session 30 HARDENS commit_ticket's existing scoped-commit filter. The scratch
# set was too narrow (only `.lcars-*`), so a non-LCARS worker runner
# (`.t003-run.cjs`) and a CLI lock that appeared MID-run (`.claude/x.lock`, not in
# the pre-run snapshot) both slipped into a ticket commit. The fix is a single
# CLI/host-agnostic scratch glob set (extensible from config.json `scratchGlobs`),
# a widened filter, a `.git/info/exclude` append (NEVER the tracked .gitignore),
# and post-commit cleanup of the harness-owned runner scratch (`.lcars-run-*`).
#
#   S30.1  a ticket producing real source + a worker runner + a CLI lock commits
#          ONLY the source; both scratch files are excluded
#   S30.2  a pre-existing untracked file (in the snapshot) is still never committed
#   S30.3  .git/info/exclude gains the scratch globs idempotently; .gitignore is
#          UNTOUCHED
#   S30.4  config.json `scratchGlobs` extend the excluded set
#   S30.5  harness runner scratch (.lcars-run-*) is gone from the tree after the
#          ticket; the per-ticket commit summary is unchanged

# A worker stub that drops the FULL spread of scratch a real run leaves behind:
# real source (commit), a non-LCARS worker runner, a mid-run CLI lock under
# .claude/, a CLI scratch dir under .copilot/, and a harness-owned runner the
# driver must clean up afterwards.
make_worker_stub_s30() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/t.test.js" ;;
  implement-implementer)
    mkdir -p src; printf 'export const feature = 1;\n' > src/feature.js     # produced source → commit
    printf '#!/usr/bin/env node\n' > .t003-run.cjs                          # non-LCARS worker runner → scratch
    mkdir -p .claude; printf 'lock\n' > .claude/scheduled_tasks.lock        # CLI lock, appears mid-run → scratch
    mkdir -p .copilot; printf 'x\n' > .copilot/session.json                 # other-CLI scratch dir → scratch
    printf 'runner\n' > .lcars-run-abc.cjs                                  # harness-owned runner → scratch + cleanup
    cat >"$out/result.json" <<JSON
{
  "ticketId": "t-001",
  "passed": true,
  "attempts": 1,
  "summary": "built the feature; suite green."
}
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# Drive one green ticket through implement-ticket in an isolated repo. Echoes the
# repo path; the worker stub is $extra-armed by make_worker_stub_s30.
new_repo_s30() { # [config-scratchGlobs-json-fragment]
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf '# seed\n' > seed.md && git add seed.md && git commit -qm seed )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  write_approved_plan_json "$m/approved-plan.json"
  write_waves_json "$m/waves.json"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "branch": "lcars/$MID",
  "githubIssue": 42
}
EOF
  # config.json with optional extra scratchGlobs (Session 30 extensibility).
  cat >"$repo/.git/lcars/config.json" <<EOF
{
  "model": "claude-sonnet",
  "testCommand": null,
  "comprehensionBudget": 1200${1:+,
  "scratchGlobs": $1}
}
EOF
  echo "$repo"
}

run_ticket_s30() { # repo
  local repo="$1"
  local bin="$repo/.bin"; mkdir -p "$bin"
  make_worker_stub_s30 "$bin/worker"; make_gh_stub "$bin/gh"
  ( cd "$repo" && GH_LOG="$bin/gh.log" LCARS_WORKER_BIN="$bin/worker" LCARS_GH_BIN="$bin/gh" \
      bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >"$bin/out.txt" 2>&1 )
}

# --- S30.1: only the produced source is committed ---------------------------
repoS30="$(new_repo_s30)"
run_ticket_s30 "$repoS30"; rcS30=$?
statS30="$( cd "$repoS30" && git show --stat --oneline HEAD 2>/dev/null )"
check "S30.1 implement-ticket exits 0 (green ticket committed)" "[ '$rcS30' -eq 0 ]"
check "S30.1 the commit INCLUDES the produced source" \
  "printf '%s' \"$statS30\" | grep -q 'src/feature.js'"
check "S30.1 the commit EXCLUDES the non-LCARS worker runner (.t003-run.cjs)" \
  "! printf '%s' \"$statS30\" | grep -q 't003-run.cjs'"
check "S30.1 the commit EXCLUDES the mid-run CLI lock (.claude/...)" \
  "! printf '%s' \"$statS30\" | grep -q 'scheduled_tasks.lock'"
check "S30.1 the commit EXCLUDES the other-CLI scratch dir (.copilot/...)" \
  "! printf '%s' \"$statS30\" | grep -q 'copilot'"

# --- S30.2: a pre-existing untracked file is still never committed -----------
repoS30b="$(new_repo_s30)"
printf 'a bug note\n' > "$repoS30b/bugs.md"   # captain's file, present BEFORE the ticket builds
run_ticket_s30 "$repoS30b" || true
statS30b="$( cd "$repoS30b" && git show --stat --oneline HEAD 2>/dev/null )"
check "S30.2 the commit EXCLUDES the captain's pre-existing untracked file" \
  "! printf '%s' \"$statS30b\" | grep -q 'bugs.md'"
check "S30.2 the captain's file is left untracked in the working tree" \
  "[ -f '$repoS30b/bugs.md' ] && [ -z \"\$( cd "$repoS30b" && git ls-files bugs.md )\" ]"

# --- S30.3: .git/info/exclude gains the globs idempotently; .gitignore intact -
repoS30c="$(new_repo_s30)"
printf '*.log\n' > "$repoS30c/.gitignore"   # captain's tracked .gitignore — MUST NOT be touched
gi_before="$( cat "$repoS30c/.gitignore" )"
run_ticket_s30 "$repoS30c" || true
excl="$repoS30c/.git/info/exclude"
check "S30.3 .git/info/exclude lists the .lcars-* scratch glob" \
  "[ -f '$excl' ] && grep -qxF '.lcars-*' '$excl'"
check "S30.3 .git/info/exclude lists the .claude/ scratch glob" \
  "grep -qxF '.claude/' '$excl'"
check "S30.3 .git/info/exclude lists the harness runner glob (.lcars-run-*)" \
  "grep -qxF '.lcars-run-*' '$excl'"
# re-run the ticket: the exclude file must not grow duplicate lines.
n1="$( grep -c '^\.lcars-\*$' "$excl" )"
( cd "$repoS30c" && git checkout -q lcars/$MID 2>/dev/null; rm -f src/feature.js )
run_ticket_s30 "$repoS30c" || true
n2="$( grep -c '^\.lcars-\*$' "$excl" )"
check "S30.3 the exclude append is idempotent (no duplicate lines on re-run)" \
  "[ \"$n1\" = '1' ] && [ \"$n2\" = '1' ]"
check "S30.3 the tracked .gitignore is UNTOUCHED" \
  "[ \"\$( cat '$repoS30c/.gitignore' )\" = '$gi_before' ]"

# --- S30.4: config.json scratchGlobs extend the excluded set ----------------
# A worker drops a `.myscratch/` file that is NOT in the base set; config opts it
# into the scratch set, so it must be excluded from the commit.
make_worker_stub_s30_extra() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/t.test.js" ;;
  implement-implementer)
    mkdir -p src; printf 'export const feature = 1;\n' > src/feature.js
    printf 'junk\n' > .myscratch-file.tmp
    cat >"$out/result.json" <<JSON
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "built it." }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}
repoS30d="$(new_repo_s30)"
cat >"$repoS30d/.git/lcars/config.json" <<'EOF'
{
  "model": "claude-sonnet",
  "testCommand": null,
  "comprehensionBudget": 1200,
  "scratchGlobs": [".myscratch-*"]
}
EOF
binS30d="$repoS30d/.bin"; mkdir -p "$binS30d"
make_worker_stub_s30_extra "$binS30d/worker"; make_gh_stub "$binS30d/gh"
( cd "$repoS30d" && GH_LOG="$binS30d/gh.log" LCARS_WORKER_BIN="$binS30d/worker" LCARS_GH_BIN="$binS30d/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >"$binS30d/out.txt" 2>&1 ) || true
statS30d="$( cd "$repoS30d" && git show --stat --oneline HEAD 2>/dev/null )"
check "S30.4 config scratchGlobs: produced source still committed" \
  "printf '%s' \"$statS30d\" | grep -q 'src/feature.js'"
check "S30.4 config scratchGlobs: the config-declared scratch is EXCLUDED" \
  "! printf '%s' \"$statS30d\" | grep -q 'myscratch'"
check "S30.4 config scratchGlobs: the glob is appended to .git/info/exclude" \
  "grep -qxF '.myscratch-*' '$repoS30d/.git/info/exclude'"

# --- S30.5: harness runner scratch is cleaned up; commit summary unchanged ---
repoS30e="$(new_repo_s30)"
run_ticket_s30 "$repoS30e" || true
check "S30.5 the harness-owned runner (.lcars-run-*) is gone from the tree" \
  "[ ! -e '$repoS30e/.lcars-run-abc.cjs' ]"
msgS30e="$( cd "$repoS30e" && git log -1 --pretty=%s 2>/dev/null )"
check "S30.5 the per-ticket commit summary is unchanged" \
  "[ \"$msgS30e\" = 'lcars($MID) t-001: built the feature; suite green.' ]"

# ==========================================================================
echo
echo "lcars run — comprehension-load sizing (Session 31)"

# Session 31 replaces the flat net-new-LOC cap with a total comprehension-load
# model. The plan.json schema carries THREE explicit estimates — existing code to
# READ, the TEST suite, and net-NEW production code — and the validator's job
# stays SHAPE (all three present), never SIZE policy. The size judgement lives in
# the prompt + Plan Review, where "over budget because it BUNDLES behaviors"
# (splittable) is told apart from "over budget because the file is just big"
# (unavoidable — must not deadlock planning). The slicing target is a config knob
# `comprehensionBudget` (default 1200), a PLANNING TARGET, not a reject threshold.
#
#   S31.1  validate_plan_json requires all three estimate fields
#   S31.2  the canonical fixtures (all three fields) still validate
#   S31.3  comprehensionBudget is read from config (default 1200 when absent)
#   S31.4  the validator does NOT reject when read+test+new exceeds the budget
#   S31.5  Schedule (parse_plan_table → waves) is unaffected by the rename

# --- S31.1: each of the three estimate fields is required -------------------
# A ticket missing ANY ONE of estimatedReadLoc / estimatedTestLoc /
# estimatedNewLoc is rejected by plan-save; nothing advances.
for field in estimatedReadLoc estimatedTestLoc estimatedNewLoc; do
  repoS1="$(new_repo_with_plan_mission)"; make_gh_stub "$repoS1/gh"
  export GH_LOG="$repoS1/gh.log"; : >"$GH_LOG"
  # Emit a single well-formed ticket, then drop the field under test.
  {
    echo '['
    echo '  {'
    echo '    "id": "t-001",'
    echo '    "title": "Wire the data-theme attribute",'
    echo '    "description": "End-to-end token wiring.",'
    echo '    "acceptanceCriteria": ["data-theme=dark recolours the page"],'
    [ "$field" = estimatedReadLoc ] || echo '    "estimatedReadLoc": 200,'
    [ "$field" = estimatedTestLoc ] || echo '    "estimatedTestLoc": 80,'
    [ "$field" = estimatedNewLoc ] || echo '    "estimatedNewLoc": 120,'
    echo '    "dependencies": [],'
    echo '    "rationale": "Has every field but the one under test."'
    echo '  }'
    echo ']'
  } >"$repoS1/missing.json"
  rcS1=0
  ( cd "$repoS1" && LCARS_GH_BIN="$repoS1/gh" bash "$SCRIPT" plan-save \
      --mission "$MID" --plan "$repoS1/missing.json" >outS1.txt 2>&1 ) || rcS1=$?
  check "S31.1 rejects a ticket missing $field" "[ '$rcS1' -ne 0 ]"
  check "S31.1 does not advance when $field is missing" \
    "grep -q '\"stage\": *\"plan\"' '$(state_of "$repoS1")'"
  check "S31.1 writes no plan.json when $field is missing" \
    "[ ! -f '$repoS1/.git/lcars/missions/$MID/plan.json' ]"
done

# --- S31.2: a ticket carrying all three estimates validates and advances ----
repoS2="$(new_repo_with_plan_mission)"; make_gh_stub "$repoS2/gh"
export GH_LOG="$repoS2/gh.log"; : >"$GH_LOG"
cat >"$repoS2/good.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Foundational token layer."
  }
]
EOF
rcS2=0
( cd "$repoS2" && LCARS_GH_BIN="$repoS2/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoS2/good.json" >outS2.txt 2>&1 ) || rcS2=$?
check "S31.2 a ticket with all three estimates passes (exit 0)" "[ '$rcS2' -eq 0 ]"
check "S31.2 advances to plan-review on a well-shaped plan" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repoS2")'"

# --- S31.3: comprehensionBudget is read from config; default 1200 when absent
# The budget is a PLANNING TARGET injected into the Plan worker's prompt. When
# config.json carries no comprehensionBudget, the driver applies 1200; when it
# carries one, that value is used. Asserted at the prompt surface (the stub
# records the assembled prompt).
repoS3="$(new_repo_with_plan_mission)"; arm_worker "$repoS3"
# Bare config (no comprehensionBudget) — default must apply.
( cd "$repoS3" && LCARS_WORKER_BIN="$repoS3/worker" LCARS_GH_BIN="$repoS3/gh" \
    bash "$SCRIPT" plan --mission "$MID" >outS3.txt 2>&1 )
PS3="$(prompt_for_role "$WORKER_CALLS" plan)"
check "S31.3 default comprehensionBudget (1200) reaches the plan prompt" \
  "printf '%s' \"\$PS3\" | grep -q '1200'"

repoS3b="$(new_repo_with_plan_mission)"; arm_worker "$repoS3b"
cat >"$repoS3b/.git/lcars/config.json" <<'EOF'
{
  "model": "claude-sonnet",
  "projectName": "demo",
  "contextFile": null,
  "testCommand": null,
  "comprehensionBudget": 800,
  "created": "2026-05-30T10:00:00Z"
}
EOF
( cd "$repoS3b" && LCARS_WORKER_BIN="$repoS3b/worker" LCARS_GH_BIN="$repoS3b/gh" \
    bash "$SCRIPT" plan --mission "$MID" >outS3b.txt 2>&1 )
PS3b="$(prompt_for_role "$WORKER_CALLS" plan)"
check "S31.3 a configured comprehensionBudget overrides the default" \
  "printf '%s' \"\$PS3b\" | grep -q '800'"
# The injected budget line carries the configured value, not the default.
check "S31.3 the configured budget is the injected target (not 1200)" \
  "printf '%s' \"\$PS3b\" | grep -q 'comprehensionBudget = 800'"

# --- S31.4: the validator does NOT hard-reject an over-budget ticket --------
# DESIGN NOTE / no-deadlock guard: a ticket whose read+test+new vastly exceeds
# the budget (a large existing file forces estimatedReadLoc alone over budget)
# must still PASS shape validation. The validator's job is SHAPE, not SIZE — the
# size judgement is the prompt's + Plan Review's, never a deterministic reject.
repoS4="$(new_repo_with_plan_mission)"; make_gh_stub "$repoS4/gh"
export GH_LOG="$repoS4/gh.log"; : >"$GH_LOG"
cat >"$repoS4/heavy.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Refactor the giant legacy controller",
    "description": "A cohesive change inside one very large existing file.",
    "acceptanceCriteria": ["The legacy route still responds, now themed"],
    "estimatedReadLoc": 5000,
    "estimatedTestLoc": 200,
    "estimatedNewLoc": 60,
    "dependencies": [],
    "rationale": "The read load is unavoidable: the file is just big. One behavior, not a bundle."
  }
]
EOF
rcS4=0
( cd "$repoS4" && LCARS_GH_BIN="$repoS4/gh" bash "$SCRIPT" plan-save \
    --mission "$MID" --plan "$repoS4/heavy.json" >outS4.txt 2>&1 ) || rcS4=$?
check "S31.4 an over-budget (read-heavy) ticket is NOT hard-rejected (exit 0)" \
  "[ '$rcS4' -eq 0 ]"
check "S31.4 the over-budget ticket advances (no deterministic size deadlock)" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repoS4")'"

# --- S31.5: Schedule (parse_plan_table → waves) is unaffected by the rename --
# The renamed estimate fields are never read by the scheduler; a plan carrying
# them still groups into the same waves.
repoS5="$(new_repo_with_schedule_mission)"; make_gh_stub "$repoS5/gh"
export GH_LOG="$repoS5/gh.log"; : >"$GH_LOG"
rcS5=0
( cd "$repoS5" && LCARS_GH_BIN="$repoS5/gh" bash "$SCRIPT" schedule --mission "$MID" \
    >outS5.txt 2>&1 ) || rcS5=$?
check "S31.5 schedule exits 0 with the new-field plan" "[ '$rcS5' -eq 0 ]"
check "S31.5 schedule wrote waves.json (rename did not break the parser)" \
  "[ -f '$repoS5/.git/lcars/missions/$MID/waves.json' ]"
check "S31.5 schedule advanced to implement" \
  "grep -q '\"stage\": *\"implement\"' '$(state_of "$repoS5")'"

# ==========================================================================
echo
echo "lcars run — behavioral-coupling Plan Review criterion (Session 32)"

# Session 32 adds COUPLING as a first-class Plan Review reject reason. The
# reviewer already sees the WHOLE plan.json (tickets + acceptanceCriteria +
# dependencies) and is independent of the spec — the right place to catch two
# tickets that touch the SAME behavior from both sides before Schedule/Implement.
# Coupling is the REAL meaning of "too big": a tiny, under-budget ticket can
# still be dangerously coupled, so size alone never catches it. Nothing about the
# verdict shape, parsing, loop-back, or 3-round escalation changes — coupling is
# an ADDED criterion that flows through the SAME failing-verdict path.
#
#   S32.1  the prompt now lists a coupling criterion + frames it as real "too big"
#   S32.2  the original four criteria are RETAINED (coupling is additive)
#   S32.3  a coupling objection flows review-save → loops back to plan
#   S32.4  the specific coupling objection text reaches the planner (not flattened)

PRTPL="$REPO_ROOT/skills/lcars-run/stages/plan-review.md"

# --- S32.1: coupling is a criterion, framed as the real meaning of "too big" -
check "S32.1 plan-review prompt mentions coupling (case-insensitive)" \
  "grep -qi 'coupl' '$PRTPL'"
check "S32.1 frames coupling as the real 'too big' (size alone misses it)" \
  "grep -qi 'too big' '$PRTPL'"
check "S32.1 notes a small / under-budget ticket can still be coupled" \
  "grep -Eqi 'under.?budget|small|<.?100|under the budget' '$PRTPL'"
check "S32.1 gives a concrete two-ticket coupling example (same behavior)" \
  "grep -qi 'behavior' '$PRTPL' && grep -Eqi 'same|both sides|seam' '$PRTPL'"
check "S32.1 the verdict example demonstrates a coupling objection" \
  "grep -i 'objection' '$PRTPL' | grep -qi 'coupl'"

# --- S32.2: the existing four criteria are retained (regression guard) -------
check "S32.2 retains the Vertical slice criterion" \
  "grep -qi 'Vertical slice' '$PRTPL'"
check "S32.2 retains the Size / comprehension-load criterion" \
  "grep -qi 'comprehension' '$PRTPL'"
check "S32.2 retains the Testability criterion" \
  "grep -qi 'Testability' '$PRTPL'"
check "S32.2 retains the Dependencies criterion" \
  "grep -qi 'Dependencies' '$PRTPL'"
check "S32.2 no longer hard-codes a stale 'four criteria' count" \
  "! grep -qi 'four criteria' '$PRTPL'"

# A coupling verdict: one failing issue naming the offending ticket AND the
# behavioral seam to split on. Canonical one-issue-per-line {ticketId,objection}
# shape — proves coupling is a valid first-class failing verdict.
write_verdict_coupling() { # file
  cat >"$1" <<'EOF'
{
  "passed": false,
  "issues": [
    { "ticketId": "t-002", "objection": "Coupled to t-001: satisfying t-002 requires changing the data-theme write path that t-001's tests already pin. Re-slice along the persistence seam so t-002 owns only the storage contract." }
  ]
}
EOF
}

# --- S32.3: a coupling objection loops back to plan via review-save ----------
repoC="$(new_repo_with_plan_review_mission)"; make_gh_stub "$repoC/gh"
export GH_LOG="$repoC/gh.log"; : >"$GH_LOG"
vC="$repoC/verdict.json"; write_verdict_coupling "$vC"
rcC=0
( cd "$repoC" && LCARS_GH_BIN="$repoC/gh" bash "$SCRIPT" review-save \
    --mission "$MID" --verdict "$vC" >outC.txt 2>&1 ) || rcC=$?
sC="$(state_of "$repoC")"
LOGC="$repoC/.git/lcars/missions/$MID/plan-review-1.json"
check "S32.3 review-save exits 0 on a coupling-objection verdict" "[ '$rcC' -eq 0 ]"
check "S32.3 logs the round to plan-review-1.json" "[ -f '$LOGC' ]"
check "S32.3 increments planReviewRound to 1" \
  "grep -q '\"planReviewRound\": *1' '$sC'"
check "S32.3 loops the stage back to plan" \
  "grep -q '\"stage\": *\"plan\"' '$sC'"
check "S32.3 adds lcars:plan" \
  "grep -q 'add-label lcars:plan ' '$repoC/gh.log' || grep -q 'add-label lcars:plan$' '$repoC/gh.log'"
check "S32.3 removes lcars:plan-review" \
  "grep -q 'remove-label lcars:plan-review' '$repoC/gh.log'"
check "S32.3 does not escalate on the first coupling failure" \
  "! grep -q '\"awaitingHuman\": *true' '$sC'"

# --- S32.4: the specific coupling objection (the seam) reaches the planner ---
check "S32.4 carries the coupling objection text through to the log" \
  "grep -qi 'Coupled to t-001' '$LOGC'"
check "S32.4 preserves the re-slice seam detail (not flattened)" \
  "grep -qi 'persistence seam' '$LOGC'"

# ==========================================================================
echo
echo "lcars run — Mission event log + live driver transitions (session 25)"
#
# `lcars run` no longer runs silent: a per-Mission append-only EVENT LOG
# (events.jsonl) records each stage transition + gate, and the auto-advance
# driver PRINTS each transition AS IT HAPPENS (not only an accumulated summary
# at halt). Events are emitted by the HARNESS (bash in run.sh), never by the
# worker. These tests cover:
#   EV1. emit_event appends a well-formed single JSON line; N calls → N lines;
#        a pinned $LCARS_NOW shows up as ts; all required keys present.
#   EV2. concurrent appends from two subshells produce no corrupted/interleaved
#        lines (every line is well-formed; total count == calls).
#   EV3. a multi-stage drive run writes stage_start + stage_done per stage IN ORDER.
#   EV4. the driver prints each stage line LIVE (before the halt) + the final
#        summary block is still printed (regression).
#   EV5. the `⊘ isolated` marker still appears on each stage line.
#   EV6. a gate halt (awaiting-human) emits a `gate` event AND fires notify once.

# Helper: a tiny grep that every events.jsonl line is individually well-formed.
all_lines_wellformed() { # file
  local f="$1" bad=0 ln
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    case "$ln" in
      '{'*'}') : ;;
      *) bad=1 ;;
    esac
    printf '%s' "$ln" | grep -q '"ts":' || bad=1
    printf '%s' "$ln" | grep -q '"mission":' || bad=1
    printf '%s' "$ln" | grep -q '"stage":' || bad=1
    printf '%s' "$ln" | grep -q '"type":' || bad=1
    printf '%s' "$ln" | grep -q '"detail":' || bad=1
  done <"$f"
  [ "$bad" -eq 0 ]
}

# --- EV1: emit_event appends a well-formed single JSON line ------------------
repoEV1="$(new_repo_with_mission)"; make_gh_stub "$repoEV1/gh"
evlog1="$repoEV1/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoEV1" && LCARS_NOW=1700000001 LCARS_GH_BIN="$repoEV1/gh" \
    bash "$SCRIPT" emit-event --mission "$MID" --type stage_start --stage research --detail "starting" >/dev/null 2>&1 )
( cd "$repoEV1" && LCARS_NOW=1700000002 LCARS_GH_BIN="$repoEV1/gh" \
    bash "$SCRIPT" emit-event --mission "$MID" --type stage_done --stage research --detail "3 agents" >/dev/null 2>&1 )
( cd "$repoEV1" && LCARS_NOW=1700000003 LCARS_GH_BIN="$repoEV1/gh" \
    bash "$SCRIPT" emit-event --mission "$MID" --type gate --stage verify --detail "human review" >/dev/null 2>&1 )
check "EV1. emit_event creates events.jsonl" "[ -f '$evlog1' ]"
check "EV1. N calls produce N lines" "[ \"\$(grep -c . '$evlog1')\" = '3' ]"
check "EV1. every line is a well-formed event with all required keys" \
  "all_lines_wellformed '$evlog1'"
check "EV1. the pinned LCARS_NOW shows up as ts" \
  "grep -q '\"ts\":1700000001' '$evlog1'"
check "EV1. the line carries the mission id" \
  "grep -q '\"mission\":\"$MID\"' '$evlog1'"
check "EV1. the type/stage/detail round-trip" \
  "grep -q '\"type\":\"stage_done\"' '$evlog1' && grep -q '\"stage\":\"research\"' '$evlog1' && grep -q '\"detail\":\"3 agents\"' '$evlog1'"
# JSON-escaping: a detail with a quote must not corrupt the line.
( cd "$repoEV1" && LCARS_NOW=1700000004 LCARS_GH_BIN="$repoEV1/gh" \
    bash "$SCRIPT" emit-event --mission "$MID" --type note --stage plan --detail 'has a "quote" inside' >/dev/null 2>&1 )
check "EV1. an embedded quote is JSON-escaped (line stays well-formed)" \
  "all_lines_wellformed '$evlog1' && grep -q 'has a \\\\\"quote\\\\\" inside' '$evlog1'"

# --- EV2: concurrent appends stay atomic (no interleaving) -------------------
repoEV2="$(new_repo_with_mission)"; make_gh_stub "$repoEV2/gh"
evlog2="$repoEV2/.git/lcars/missions/$MID/events.jsonl"
burst() { # tag count
  local i=0
  while [ "$i" -lt "$2" ]; do i=$((i+1))
    ( cd "$repoEV2" && LCARS_NOW="170000$2$i" LCARS_GH_BIN="$repoEV2/gh" \
        bash "$SCRIPT" emit-event --mission "$MID" --type "burst-$1" --stage plan --detail "n$i" >/dev/null 2>&1 )
  done
}
burst A 20 & burst B 20 & wait
check "EV2. concurrent bursts produced 40 lines, none lost" \
  "[ \"\$(grep -c . '$evlog2')\" = '40' ]"
check "EV2. every concurrently-appended line is individually well-formed" \
  "all_lines_wellformed '$evlog2'"

# --- EV3: a multi-stage drive run logs stage_start+stage_done IN ORDER -------
repoEV3="$(new_repo_with_validate_mission)"; arm_drive "$repoEV3"
evlog3="$repoEV3/.git/lcars/missions/$MID/events.jsonl"
drive "$repoEV3" drive --mission "$MID" --step || true   # one clean transition: validate → plan
check "EV3. a stepped drive writes a stage_start for the stage it ran" \
  "grep -q '\"type\":\"stage_start\".*\"stage\":\"validate\"\\|\"stage\":\"validate\".*\"type\":\"stage_start\"' '$evlog3' || grep -q '\"type\":\"stage_start\"' '$evlog3'"
check "EV3. a stepped drive writes a stage_done for the stage it ran" \
  "grep -q '\"type\":\"stage_done\"' '$evlog3'"
# A full drive: assert order — stage_start precedes its stage_done across stages.
repoEV3b="$(new_repo_with_mission)"; arm_drive "$repoEV3b"
evlog3b="$repoEV3b/.git/lcars/missions/$MID/events.jsonl"
drive "$repoEV3b" drive --mission "$MID" || true
starts3b="$(grep -c '"type":"stage_start"' "$evlog3b" 2>/dev/null)"
dones3b="$(grep -c '"type":"stage_done"' "$evlog3b" 2>/dev/null)"
check "EV3. a full drive logs a stage_start per advanced stage (>=5)" \
  "[ \"\${starts3b:-0}\" -ge 5 ]"
check "EV3. a full drive logs a stage_done per advanced stage (>=5)" \
  "[ \"\${dones3b:-0}\" -ge 5 ]"
check "EV3. the FIRST event is a stage_start (a BEGIN logs before any DONE)" \
  "[ \"\$(grep -m1 -o '\"type\":\"[a-z_]*\"' '$evlog3b' | head -1)\" = '\"type\":\"stage_start\"' ]"
check "EV3. a gate event closes the run at the verify halt" \
  "grep -q '\"type\":\"gate\".*verify\\|\"stage\":\"verify\".*\"type\":\"gate\"' '$evlog3b'"

# --- EV4: the driver prints each stage line LIVE (before halt) ---------------
# The live per-stage lines appear in stdout BEFORE the final summary separator;
# the final summary block is still printed (regression).
repoEV4="$(new_repo_with_mission)"; arm_drive "$repoEV4"
drive "$repoEV4" drive --mission "$MID" || true
out4="$repoEV4/drive.out"
# The first separator is the header rule; the final summary block prints another.
# A live stage line must appear before the LAST separator line. (run.sh's $SEP.)
SEP="─────────────────────────────────────────────"
last_sep_line="$(grep -n "$SEP" "$out4" | tail -1 | cut -d: -f1)"
first_stage_line="$(grep -n 'running…\|✓' "$out4" | head -1 | cut -d: -f1)"
check "EV4. a live stage line is printed before the final summary separator" \
  "[ -n \"\$first_stage_line\" ] && [ -n \"\$last_sep_line\" ] && [ \"\$first_stage_line\" -lt \"\$last_sep_line\" ]"
check "EV4. a live BEGIN line is printed (▶ running…) before a stage finishes" \
  "grep -q 'running…' '$out4'"
check "EV4. the final summary block is STILL printed (regression)" \
  "grep -qi 'stopped' '$out4' && grep -q 'verify' '$out4'"
check "EV4. the final summary still lists each stage that ran (regression)" \
  "grep -q 'research' '$out4' && grep -q 'validate' '$out4' && grep -q 'plan-review' '$out4' && grep -q 'implement' '$out4'"

# --- EV5: the `⊘ isolated` marker is unchanged on each stage line ------------
check "EV5. the live/summary stage lines still carry the '⊘ isolated' marker" \
  "grep -q '⊘ isolated' '$out4'"

# --- EV6: a gate halt (awaiting-human) emits a gate event + notifies once ----
repoEV6="$(new_repo_with_validate_mission)"; arm_drive "$repoEV6"
evlog6="$repoEV6/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoEV6" && STUB_SCOPE=1 STUB_NQUESTIONS=1 \
    LCARS_WORKER_BIN="$repoEV6/worker" LCARS_GH_BIN="$repoEV6/gh" LCARS_NOTIFY="$repoEV6/notify" \
    bash "$SCRIPT" drive --mission "$MID" >"$repoEV6/drive.out" 2>&1 ) || true
check "EV6. an awaiting-human halt emits a gate event to the log" \
  "grep -q '\"type\":\"gate\"' '$evlog6'"
check "EV6. the gate event records the validate stage that escalated" \
  "grep -q '\"type\":\"gate\".*\"stage\":\"validate\"\\|\"stage\":\"validate\".*\"type\":\"gate\"' '$evlog6'"
check "EV6. the notify hook STILL fires exactly once at the gate (regression)" \
  "[ \"\$(grep -c . '$repoEV6/notify.log')\" = '1' ]"

# ==========================================================================
echo "lcars run — Session 26: fine-grained Implement + wave events"
# Session 26 instruments the Implement stage with MACHINE-READABLE events:
#   wave_start    {wave,ticketCount,totalWaves}   — once per wave, ascending
#   ticket_start  {ticket,wave}                   — at implement-ticket entry
#   ticket_attempt{ticket,phase,attempt}          — per worker re-dispatch
#   ticket_flagged{ticket,attempts}               — a ticket that exhausts attempts
#   ticket_green  {ticket,attempts}               — AFTER the guardrails + commit
# The sink (emit_event) is extended with a structured "data":{...} payload, but
# stays byte-identical to Session 25 when no data pairs are passed.

# A helper like all_lines_wellformed but tolerant of an optional "data" object.
all_lines_wellformed_data() { # file
  local f="$1" bad=0 ln
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    case "$ln" in
      '{'*'}') : ;;
      *) bad=1 ;;
    esac
    printf '%s' "$ln" | grep -q '"ts":' || bad=1
    printf '%s' "$ln" | grep -q '"mission":' || bad=1
    printf '%s' "$ln" | grep -q '"stage":' || bad=1
    printf '%s' "$ln" | grep -q '"type":' || bad=1
    printf '%s' "$ln" | grep -q '"detail":' || bad=1
  done <"$f"
  [ "$bad" -eq 0 ]
}

# --- S26-1: a two-wave plan emits wave_start per wave, ascending, once each ---
# Drive the whole Implement stage with the worker stub; the green-on-everything
# stub finishes every ticket, so cmd_implement walks wave 1 then wave 2.
repoS1="$(new_repo_with_implement_mission)"; arm_worker "$repoS1"
evS1="$repoS1/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS1" && LCARS_NOW=1700001000 LCARS_WORKER_BIN="$repoS1/worker" LCARS_GH_BIN="$repoS1/gh" \
    bash "$SCRIPT" implement --mission "$MID" >outS1.txt 2>&1 ) || true
check "S26-1. a wave_start event is emitted" \
  "grep -q '\"type\":\"wave_start\"' '$evS1'"
check "S26-1. wave_start fires for wave 1 AND wave 2" \
  "grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"wave\":1' && grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"wave\":2'"
check "S26-1. exactly ONE wave_start per wave (no dup from the re-running loop)" \
  "[ \"\$(grep -c '\"type\":\"wave_start\"' '$evS1')\" = '2' ]"
check "S26-1. wave_start carries ticketCount=2 (each wave has two tickets)" \
  "grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"ticketCount\":2'"
check "S26-1. wave_start carries totalWaves=2" \
  "grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"totalWaves\":2'"
check "S26-1. wave 1's wave_start precedes wave 2's (ascending order)" \
  "[ \"\$(grep -n '\"type\":\"wave_start\".*\"wave\":1' '$evS1' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '\"type\":\"wave_start\".*\"wave\":2' '$evS1' | head -1 | cut -d: -f1)\" ]"
check "S26-1. the numeric data fields are UNQUOTED (machine-readable)" \
  "grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"wave\":[0-9]' && ! grep '\"type\":\"wave_start\"' '$evS1' | grep -q '\"wave\":\"'"
check "S26-1. every emitted Implement line is well-formed (with the data object)" \
  "all_lines_wellformed_data '$evS1'"

# --- S26-2: a ticket emits ticket_start → ticket_attempt(s) → ticket_green ----
repoS2="$(new_repo_with_implement_mission)"; arm_worker "$repoS2"
evS2="$repoS2/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS2" && LCARS_NOW=1700002000 LCARS_WORKER_BIN="$repoS2/worker" LCARS_GH_BIN="$repoS2/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >outS2.txt 2>&1 ) || true
check "S26-2. ticket_start is emitted with the ticket id" \
  "grep '\"type\":\"ticket_start\"' '$evS2' | grep -q '\"ticket\":\"t-001\"'"
check "S26-2. ticket_start carries the ticket's wave (t-001 is wave 1)" \
  "grep '\"type\":\"ticket_start\"' '$evS2' | grep -q '\"wave\":1'"
check "S26-2. a test-writer ticket_attempt is emitted" \
  "grep '\"type\":\"ticket_attempt\"' '$evS2' | grep -q '\"phase\":\"test-writer\"'"
check "S26-2. an implementer ticket_attempt is emitted" \
  "grep '\"type\":\"ticket_attempt\"' '$evS2' | grep -q '\"phase\":\"implementer\"'"
check "S26-2. ticket_attempt carries a numeric attempt index" \
  "grep '\"type\":\"ticket_attempt\"' '$evS2' | grep -q '\"attempt\":1'"
check "S26-2. ticket_green is emitted" \
  "grep '\"type\":\"ticket_green\"' '$evS2' | grep -q '\"ticket\":\"t-001\"'"
# Relative ORDER: start < first attempt < green.
posS2_start="$(grep -n '"type":"ticket_start"' "$evS2" | head -1 | cut -d: -f1)"
posS2_att="$(grep -n '"type":"ticket_attempt"' "$evS2" | head -1 | cut -d: -f1)"
posS2_green="$(grep -n '"type":"ticket_green"' "$evS2" | head -1 | cut -d: -f1)"
check "S26-2. order: ticket_start precedes ticket_attempt precedes ticket_green" \
  "[ -n \"$posS2_start\" ] && [ \"$posS2_start\" -lt \"$posS2_att\" ] && [ \"$posS2_att\" -lt \"$posS2_green\" ]"

# --- S26-3: an exhausted ticket emits ticket_flagged, NOT ticket_green --------
# Drive impl-save-result directly with a failing result (the flag branch).
repoS3="$(new_repo_with_implement_mission)"; make_gh_stub "$repoS3/gh"
export GH_LOG="$repoS3/gh.log"; : >"$GH_LOG"
twS3="$repoS3/tw"; mkdir -p "$twS3"; printf 'assert: a failing test\n' >"$twS3/t.test.js"
( cd "$repoS3" && LCARS_GH_BIN="$repoS3/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twS3" >/dev/null 2>&1 )
resS3="$repoS3/result.json"; write_result "$resS3" t-001 false 5
evS3="$repoS3/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS3" && LCARS_NOW=1700003000 LCARS_GH_BIN="$repoS3/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resS3" >outS3.txt 2>&1 ) || true
check "S26-3. a flagged ticket emits ticket_flagged with its attempts" \
  "grep '\"type\":\"ticket_flagged\"' '$evS3' | grep -q '\"ticket\":\"t-001\"' && grep '\"type\":\"ticket_flagged\"' '$evS3' | grep -q '\"attempts\":5'"
check "S26-3. a flagged ticket emits NO ticket_green" \
  "! grep -q '\"type\":\"ticket_green\"' '$evS3'"

# --- S26-4: ticket_green is emitted ONLY after the guardrails pass -------------
# Drive a guardrail rejection: a result that claims 6 attempts (over the cap) is
# die'd by impl-save-result BEFORE reaching the green emit. No ticket_green.
repoS4="$(new_repo_with_implement_mission)"; make_gh_stub "$repoS4/gh"
export GH_LOG="$repoS4/gh.log"; : >"$GH_LOG"
twS4="$repoS4/tw"; mkdir -p "$twS4"; printf 'assert: a failing test\n' >"$twS4/t.test.js"
( cd "$repoS4" && LCARS_GH_BIN="$repoS4/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twS4" >/dev/null 2>&1 )
resS4="$repoS4/result.json"; write_result "$resS4" t-001 true 6   # over the 5-cap → rejected
evS4="$repoS4/.git/lcars/missions/$MID/events.jsonl"
rcS4=0
( cd "$repoS4" && LCARS_NOW=1700004000 LCARS_GH_BIN="$repoS4/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resS4" >outS4.txt 2>&1 ) || rcS4=$?
check "S26-4. a guardrail-rejected save exits non-zero" "[ '$rcS4' -ne 0 ]"
check "S26-4. a guardrail-rejected save emits NO ticket_green" \
  "[ ! -f '$evS4' ] || ! grep -q '\"type\":\"ticket_green\"' '$evS4'"

# Second guardrail: an immutable-tests violation (the locked tests were edited).
repoS4b="$(new_repo_with_implement_mission)"; make_gh_stub "$repoS4b/gh"
export GH_LOG="$repoS4b/gh.log"; : >"$GH_LOG"
twS4b="$repoS4b/tw"; mkdir -p "$twS4b"; printf 'assert: a failing test\n' >"$twS4b/t.test.js"
( cd "$repoS4b" && LCARS_GH_BIN="$repoS4b/gh" bash "$SCRIPT" impl-save-tests \
    --mission "$MID" --ticket t-001 --tests "$twS4b" >/dev/null 2>&1 )
# Tamper with the quarantined test AFTER the snapshot → tests_unchanged fails.
printf 'assert: TAMPERED\n' >"$repoS4b/.git/lcars/missions/$MID/tickets/t-001/tests/t.test.js"
resS4b="$repoS4b/result.json"; write_result "$resS4b" t-001 true 2
evS4b="$repoS4b/.git/lcars/missions/$MID/events.jsonl"
rcS4b=0
( cd "$repoS4b" && LCARS_NOW=1700004500 LCARS_GH_BIN="$repoS4b/gh" bash "$SCRIPT" impl-save-result \
    --mission "$MID" --ticket t-001 --result "$resS4b" >outS4b.txt 2>&1 ) || rcS4b=$?
check "S26-4. an immutable-tests violation is rejected (non-zero)" "[ '$rcS4b' -ne 0 ]"
check "S26-4. an immutable-tests violation emits NO ticket_green" \
  "[ ! -f '$evS4b' ] || ! grep -q '\"type\":\"ticket_green\"' '$evS4b'"

# --- S26-5: events carry the wave/ticket ids to reconstruct "k of n" ----------
# Reuse S26-1's two-wave drive: assert the fields a downstream renderer parses.
check "S26-5. wave_start data carries wave + ticketCount + totalWaves" \
  "grep '\"type\":\"wave_start\"' '$evS1' | head -1 | grep -q '\"data\":{' && grep '\"type\":\"wave_start\"' '$evS1' | head -1 | grep -q '\"wave\":' && grep '\"type\":\"wave_start\"' '$evS1' | head -1 | grep -q '\"ticketCount\":' && grep '\"type\":\"wave_start\"' '$evS1' | head -1 | grep -q '\"totalWaves\":'"
check "S26-5. ticket_green data carries the ticket id (string) and attempts (number)" \
  "grep '\"type\":\"ticket_green\"' '$evS2' | grep -q '\"ticket\":\"t-001\"' && grep '\"type\":\"ticket_green\"' '$evS2' | grep -q '\"attempts\":[0-9]'"

# --- S26-6 (regression): the no-data line is byte-identical to Session 25 ------
# emit-event with NO data pairs must produce a line with no "data" key at all.
repoS6="$(new_repo_with_mission)"; make_gh_stub "$repoS6/gh"
evS6="$repoS6/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS6" && LCARS_NOW=1700006000 LCARS_GH_BIN="$repoS6/gh" \
    bash "$SCRIPT" emit-event --mission "$MID" --type stage_start --stage research --detail "starting" >/dev/null 2>&1 )
expectedS6='{"ts":1700006000,"mission":"'"$MID"'","stage":"research","type":"stage_start","detail":"starting"}'
check "S26-6. a no-data event line has NO data key (byte-identical to Session 25)" \
  "[ \"\$(cat '$evS6')\" = '$expectedS6' ]"
check "S26-6. a no-data line carries no data object at all" \
  "! grep -q '\"data\"' '$evS6'"
# And a data-bearing line is a single well-formed JSON line.
check "S26-6. a data-bearing event line is single + well-formed" \
  "all_lines_wellformed_data '$evS1' && [ \"\$(grep -c . '$evS1')\" -ge 2 ]"

# --- S26-7 (regression): the Implement stage is RE-INVOKED on real runs --------
# A real Mission re-enters cmd_implement / implement-ticket (manual `lcars run`
# retries; the `lcars respond` → `lcars run` resume after a flagged ticket). The
# Session-26 dedup/indexing must come from the durable events.jsonl, NOT a
# process-local — else wave_start / ticket_start re-emit and ticket_attempt
# restarts at 1 on every fresh process. These tests drive the SAME not-yet-green
# state twice and assert against events.jsonl.

# A worker stub whose implement-test-writer produces NO usable tests, so
# implement-ticket dies inside Phase 1 after MAX_WORKER_TRIES — emitting
# ticket_start + ticket_attempt(test-writer) 1..3 but never reaching green. The
# Defect-3 die path (Test-Writer exhaustion) is PRE-EXISTING and untouched; we
# only ride it to force a re-invocation cheaply.
make_worker_stub_no_tests() { # path
  make_worker_stub "$1"
  # Neuter the implement-test-writer branch in place: it currently writes a stub
  # test file; make it produce NOTHING usable so Phase 1 exhausts MAX_WORKER_TRIES.
  # (Appending after the stub's trailing `exit 0` would be dead code, so edit the
  # branch body directly.)
  sed -i.bak '/tests\/stub.test.js/d' "$1"   # drop the only test file it wrote
  rm -f "$1.bak"
}

# S26-7: re-invoke implement-ticket on the same still-red state. Across two
# dying invocations there must be EXACTLY ONE ticket_start, and the
# ticket_attempt indices for (t-001, test-writer) must continue 1,2,3 then
# 4,5,6 — strictly monotonic and unique, never a repeated index.
repoS7="$(new_repo_with_implement_mission)"
make_worker_stub_no_tests "$repoS7/worker"; make_gh_stub "$repoS7/gh"
export GH_LOG="$repoS7/gh.log"; : >"$GH_LOG"
export WORKER_LOG="$repoS7/worker.log"; : >"$WORKER_LOG"
export WORKER_CALLS="$repoS7/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
evS7="$repoS7/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS7" && LCARS_NOW=1700007000 LCARS_WORKER_BIN="$repoS7/worker" LCARS_GH_BIN="$repoS7/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >outS7a.txt 2>&1 ) || true
export WORKER_LOG="$repoS7/worker.log"
export WORKER_CALLS="$repoS7/calls"
( cd "$repoS7" && LCARS_NOW=1700007100 LCARS_WORKER_BIN="$repoS7/worker" LCARS_GH_BIN="$repoS7/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >outS7b.txt 2>&1 ) || true
check "S26-7. re-invoked implement-ticket emits EXACTLY ONE ticket_start for t-001" \
  "[ \"\$(grep '\"type\":\"ticket_start\"' '$evS7' | grep -c '\"ticket\":\"t-001\"')\" = '1' ]"
check "S26-7. test-writer ticket_attempt indices continue 1..6 across invocations (6 lines)" \
  "[ \"\$(grep '\"type\":\"ticket_attempt\"' '$evS7' | grep '\"phase\":\"test-writer\"' | grep -c '\"ticket\":\"t-001\"')\" = '6' ]"
check "S26-7. those attempt indices are unique (1,2,3,4,5,6 — no repeat)" \
  "[ \"\$(grep '\"type\":\"ticket_attempt\"' '$evS7' | grep '\"phase\":\"test-writer\"' | sed -n 's/.*\"attempt\":\\([0-9]*\\).*/\\1/p' | sort -n | uniq | tr '\\n' ' ')\" = '1 2 3 4 5 6 ' ]"
check "S26-7. attempt indices are strictly monotonic (sorted == as-emitted)" \
  "[ \"\$(grep '\"type\":\"ticket_attempt\"' '$evS7' | grep '\"phase\":\"test-writer\"' | sed -n 's/.*\"attempt\":\\([0-9]*\\).*/\\1/p' | tr '\\n' ' ')\" = '1 2 3 4 5 6 ' ]"

# S26-8: re-invoke cmd_implement (the whole stage) on a STILL-ACTIVE wave. The
# green-on-everything stub finishes nothing if we make wave 1's first ticket
# die, but to assert wave_start dedup we let the stage make progress then re-run.
# Simplest faithful drive: a green stub, run the stage to completion (one
# wave_start per wave), then re-invoke — the still-finished waves must NOT
# re-emit wave_start, and re-running while wave 1 is active must not double it.
repoS8="$(new_repo_with_implement_mission)"; arm_worker "$repoS8"
evS8="$repoS8/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS8" && LCARS_NOW=1700008000 LCARS_WORKER_BIN="$repoS8/worker" LCARS_GH_BIN="$repoS8/gh" \
    bash "$SCRIPT" implement --mission "$MID" >outS8a.txt 2>&1 ) || true
# Re-invoke the whole stage on the now-complete mission (idempotent advance path).
( cd "$repoS8" && LCARS_NOW=1700008100 LCARS_WORKER_BIN="$repoS8/worker" LCARS_GH_BIN="$repoS8/gh" \
    bash "$SCRIPT" implement --mission "$MID" >outS8b.txt 2>&1 ) || true
check "S26-8. across two cmd_implement invocations, exactly ONE wave_start per wave (2 total)" \
  "[ \"\$(grep -c '\"type\":\"wave_start\"' '$evS8')\" = '2' ]"
check "S26-8. exactly ONE ticket_start per ticket across re-invocations (4 total)" \
  "[ \"\$(grep -c '\"type\":\"ticket_start\"' '$evS8')\" = '4' ]"
check "S26-8. wave:1 dedup respects integer boundaries (one wave_start each for 1 and 2)" \
  "[ \"\$(grep '\"type\":\"wave_start\"' '$evS8' | grep -c '\"wave\":1[,}]')\" = '1' ] && [ \"\$(grep '\"type\":\"wave_start\"' '$evS8' | grep -c '\"wave\":2[,}]')\" = '1' ]"

# S26-9: the happy single-invocation green path still emits, in order, one
# wave_start, one ticket_start, the attempt line(s), then ticket_green — the
# exactly-once-within-one-call invariant the originals pinned still holds.
repoS9="$(new_repo_with_implement_mission)"; arm_worker "$repoS9"
evS9="$repoS9/.git/lcars/missions/$MID/events.jsonl"
( cd "$repoS9" && LCARS_NOW=1700009000 LCARS_WORKER_BIN="$repoS9/worker" LCARS_GH_BIN="$repoS9/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >outS9.txt 2>&1 ) || true
check "S26-9. single invocation emits exactly one ticket_start for t-001" \
  "[ \"\$(grep '\"type\":\"ticket_start\"' '$evS9' | grep -c '\"ticket\":\"t-001\"')\" = '1' ]"
posS9_start="$(grep -n '"type":"ticket_start"' "$evS9" | head -1 | cut -d: -f1)"
posS9_att="$(grep -n '"type":"ticket_attempt"' "$evS9" | head -1 | cut -d: -f1)"
posS9_green="$(grep -n '"type":"ticket_green"' "$evS9" | head -1 | cut -d: -f1)"
check "S26-9. order still holds: ticket_start < ticket_attempt < ticket_green" \
  "[ -n \"$posS9_start\" ] && [ \"$posS9_start\" -lt \"$posS9_att\" ] && [ \"$posS9_att\" -lt \"$posS9_green\" ]"
check "S26-9. first attempt index within a fresh ticket is 1" \
  "grep '\"type\":\"ticket_attempt\"' '$evS9' | grep '\"phase\":\"test-writer\"' | grep -q '\"attempt\":1'"

# ==========================================================================
echo
echo "lcars run — role labels (lcars:mission/lcars:ticket) ride through stage walks (session 34)"
#
# BUG-005: a Mission and its tickets were indistinguishable on the board. The
# fix adds disjoint ROLE labels: lcars:mission on a Mission, lcars:ticket on a
# Schedule sub-issue. Role labels are ADDITIVE + PERMANENT — no stage transition
# (gh_relabel) ever strips one. Across the full pipeline walk exercised above
# (align→validate, validate→plan, plan→plan-review, plan-review→schedule,
# schedule→implement, implement→verify) no relabel may name a role label in its
# remove-list.
S34_LOGS="$repo2/gh.log $repoV/gh.log $repoPL/gh.log $repoPR/gh.log $repoS/gh.log $repoIa/gh.log"
check "S34. no stage transition ever removes lcars:mission" \
  "! grep -hq 'remove-label lcars:mission' $S34_LOGS"
check "S34. no stage transition ever removes lcars:ticket" \
  "! grep -hq 'remove-label lcars:ticket' $S34_LOGS"

# ==========================================================================
echo
echo "lcars run — SKILL.md mandates the portable foreground per-Stage loop (session 42 / Copilot)"
#
# Doc-level guard for the in-session progress relay (Session 42, revised for
# CLI-agnostic dispatch under headless Copilot): the REQUIRED, default way to
# auto-advance must be the foreground per-Stage loop — repeatedly drive ONE Stage
# at a time in the FOREGROUND with `--step`, relay each Stage's output, and loop
# until the driver reports a halt. NO backgrounding (`&`) and NO piping (`| tee`)
# as the default, because headless GitHub Copilot CLI DENIES both even with
# --allow-all-tools. Any detached/background pattern that remains must be marked
# OPTIONAL and job-control-only. The live behaviour is proven by the functional
# tester; here we pin the instruction text.
RUN_SKILL="$REPO_ROOT/skills/lcars-run/SKILL.md"
check "S42. SKILL.md mandates a foreground per-Stage loop as the portable default" \
  "grep -qiE 'foreground per-stage loop' '$RUN_SKILL'"
check "S42. SKILL.md drives one Stage at a time in the foreground with --step" \
  "grep -qE 'drive --mission <id> --step' '$RUN_SKILL'"
check "S42. SKILL.md says headless Copilot denies backgrounding / pipes" \
  "grep -qi 'copilot' '$RUN_SKILL' && grep -qiE 'den(y|ies|ied)' '$RUN_SKILL'"
check "S42. SKILL.md names the denied shapes (& and | tee/pipe)" \
  "grep -qE 'tee|pipe' '$RUN_SKILL'"
check "S42. SKILL.md loops the per-Stage advance until the driver halts" \
  "grep -qiE 'loop until.*halt|until the driver reports a halt|until it.*halt' '$RUN_SKILL'"
check "S42. SKILL.md keeps the final summary + isolation markers byte-for-byte" \
  "grep -qF '⊘ isolated' '$RUN_SKILL' && grep -qiE 'byte-for-byte|byte-compatible' '$RUN_SKILL'"
# Any background/detached mention that survives MUST be flagged OPTIONAL, never
# the required/default path.
check "S42. any detached/background mention is marked optional, not the default" \
  "! grep -qiE 'background|detached' '$RUN_SKILL' || grep -qiE 'optional' '$RUN_SKILL'"

# ==========================================================================
echo
echo "lcars run — Session 41: per-ticket context manifest + per-wave repo map"
# Session 41 stops every Implement worker from re-walking the repo cold. Two
# DECLARATIVE, token-cheap artifacts are produced and read by PATH:
#   (a) per-ticket manifests/<id>.md — authored by the Plan worker (signatures +
#       file paths + touched ADR ids ONLY), persisted by plan-save into the
#       mission dir as SEPARATE files (never embedded in plan.json).
#   (b) a per-wave repo-map.md — a pure-bash symbol skeleton regenerated at the
#       start of each Implement wave (signature lines + paths, NEVER bodies).
# Both ride the Test Writer + Implementer extra blocks by PATH. Research workers
# get NEITHER (purity). The repo-map is bash-extracted, so it is clean by
# construction. None of this touches plan.json's schema or Plan Review.

# --- S41-1: plan-save persists per-ticket manifests from the worker scratch ----
# Drive Plan with the worker stub (it emits plan.json + manifests/t-001.md). After
# the stage, the manifest must live at $MISSION_DIR/manifests/t-001.md and carry
# signatures + paths + ADR ids — and NO implementation body (the fixture is clean).
repo41p="$(new_repo_with_plan_mission)"; arm_worker "$repo41p"
( cd "$repo41p" && LCARS_WORKER_BIN="$repo41p/worker" LCARS_GH_BIN="$repo41p/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out41p.txt 2>&1 )
MAN41="$repo41p/.git/lcars/missions/$MID/manifests/t-001.md"
check "S41-1. plan-save persists manifests/t-001.md into the mission dir" \
  "[ -f '$MAN41' ]"
check "S41-1. the manifest lists the relevant file paths" \
  "grep -q 'src/theme.js' '$MAN41'"
check "S41-1. the manifest carries interface signatures (skeletons)" \
  "grep -q 'export function setTheme' '$MAN41'"
check "S41-1. the manifest names the touched ADR ids" \
  "grep -q 'ADR-001' '$MAN41'"
check "S41-1. the persisted manifest equals what the worker wrote (no rewrite/leak)" \
  "! grep -qiE 'return |const |if \\(|=>|\\{\\{' '$MAN41'"
check "S41-1. plan.json is UNCHANGED in shape (manifest is a SEPARATE file, not embedded)" \
  "! grep -qi 'manifest' '$repo41p/.git/lcars/missions/$MID/plan.json'"
check "S41-1. Plan still advanced to plan-review (manifest persistence is additive)" \
  "grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repo41p")'"

# --- S41-1b: a missing manifest is best-effort — the plan still advances --------
# STUB_NO_MANIFEST=1: the worker emits NO manifests/ dir. plan-save must NOT
# hard-fail (single-ticket fast-path / thin greenfield) — it advances anyway.
repo41pm="$(new_repo_with_plan_mission)"; arm_worker "$repo41pm"
rc41pm=0
( cd "$repo41pm" && STUB_NO_MANIFEST=1 LCARS_WORKER_BIN="$repo41pm/worker" LCARS_GH_BIN="$repo41pm/gh" \
    bash "$SCRIPT" plan --mission "$MID" >out41pm.txt 2>&1 ) || rc41pm=$?
check "S41-1b. a plan with no manifests still advances (best-effort, no hard-fail)" \
  "[ '$rc41pm' -eq 0 ] && grep -q '\"stage\": *\"plan-review\"' '$(state_of "$repo41pm")'"

# --- S41-2: the repo-map generator (pure bash, token-free) ----------------------
# Build a fixture repo with one source file per supported language, run the
# `repo-map` subcommand (the thin driver over generate_repo_map), and assert the
# map captures top-level SIGNATURES across languages while excluding file BODIES.
repo41map="$(new_repo_with_implement_mission)"
SRC41="$repo41map/src"; mkdir -p "$SRC41"
cat >"$SRC41/util.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
  local secret_body_marker=1
  echo "$secret_body_marker"
}
EOF
cat >"$SRC41/widget.js" <<'EOF'
export function bar(a, b) {
  const inside_js_body = a + b;
  return inside_js_body;
}
class Baz {
  hidden_method_body() { return 42; }
}
EOF
cat >"$SRC41/calc.py" <<'EOF'
class Calc:
    def qux(self, n):
        inside_py_body = n * 2
        return inside_py_body
EOF
cat >"$SRC41/types.ts" <<'EOF'
export type ThemeName = "light" | "dark";
export interface Toggle {
  flip(): void;
}
EOF
# An unknown extension: degrade gracefully — list the path alone, no signatures.
printf 'binary-ish content with { braces } that must not leak as a body\n' >"$SRC41/data.xyz"
rc41map=0
( cd "$repo41map" && LCARS_WORKER_BIN="$repo41map/worker" \
    bash "$SCRIPT" repo-map --mission "$MID" >out41map.txt 2>&1 ) || rc41map=$?
MAP41="$repo41map/.git/lcars/missions/$MID/repo-map.md"
check "S41-2. repo-map subcommand exits 0 (pure bash, no worker needed)" "[ '$rc41map' -eq 0 ]"
check "S41-2. repo-map.md is written under .git/ (never the working tree)" \
  "[ -f '$MAP41' ] && [ ! -e '$repo41map/repo-map.md' ]"
check "S41-2. captures the shell function signature foo()" \
  "grep -q 'foo()' '$MAP41'"
check "S41-2. captures the JS function signature bar(" \
  "grep -q 'function bar(' '$MAP41'"
check "S41-2. captures the JS class signature Baz" \
  "grep -q 'class Baz' '$MAP41'"
check "S41-2. captures the Python def signature qux(" \
  "grep -q 'def qux(' '$MAP41'"
check "S41-2. captures the Python class signature Calc" \
  "grep -q 'class Calc' '$MAP41'"
check "S41-2. captures the TS interface/type signatures" \
  "grep -q 'interface Toggle' '$MAP41' && grep -q 'type ThemeName' '$MAP41'"
check "S41-2. degrades gracefully — an unknown file is listed by PATH alone" \
  "grep -q 'data.xyz' '$MAP41'"
# DECLARATIVE GUARD — no FUNCTION BODIES leak. The body markers planted inside
# each function must NOT appear in the skeleton map.
check "S41-2. NO shell body leaks (secret_body_marker absent)" \
  "! grep -q 'secret_body_marker' '$MAP41'"
check "S41-2. NO JS body leaks (inside_js_body absent)" \
  "! grep -q 'inside_js_body' '$MAP41'"
check "S41-2. NO JS method body leaks (hidden_method_body line is not a statement dump)" \
  "! grep -q 'return 42' '$MAP41'"
check "S41-2. NO Python body leaks (inside_py_body absent)" \
  "! grep -q 'inside_py_body' '$MAP41'"
check "S41-2. NO unknown-file body leaks (the { braces } content is not dumped)" \
  "! grep -q 'must not leak as a body' '$MAP41'"

# --- S41-3: the repo-map REGENERATES at each Implement wave_start ----------------
# Drive the whole Implement stage with the green-on-everything stub. The map must
# exist after the run (regenerated at the first wave_start) and carry a wave
# marker for each wave it regenerated at, proving the per-wave hook fired.
repo41w="$(new_repo_with_implement_mission)"; arm_worker "$repo41w"
SRC41w="$repo41w/src"; mkdir -p "$SRC41w"
printf 'export function alpha() { return 1; }\n' >"$SRC41w/alpha.js"
( cd "$repo41w" && LCARS_NOW=1700041000 LCARS_WORKER_BIN="$repo41w/worker" LCARS_GH_BIN="$repo41w/gh" \
    bash "$SCRIPT" implement --mission "$MID" >out41w.txt 2>&1 ) || true
MAP41w="$repo41w/.git/lcars/missions/$MID/repo-map.md"
check "S41-3. repo-map.md exists after the Implement stage (regenerated at a wave)" \
  "[ -f '$MAP41w' ]"
check "S41-3. the regenerated map carries a wave marker in its header (per-wave regeneration)" \
  "grep -qE 'wave [0-9]' '$MAP41w'"
check "S41-3. the wave-regenerated map carries the freshly committed symbols (alpha)" \
  "grep -q 'function alpha(' '$MAP41w'"

# --- S41-4: the Implementer AND Test Writer extra-blocks LIST both artifacts -----
# Seed the manifest + repo-map on disk, then run implement-ticket. Both halves'
# prompts must name the ticket manifest path and the repo-map path (by PATH only).
repo41r="$(new_repo_with_implement_mission)"; arm_worker "$repo41r"
MDIR41r="$repo41r/.git/lcars/missions/$MID"
mkdir -p "$MDIR41r/manifests"
cat >"$MDIR41r/manifests/t-001.md" <<'EOF'
# Context manifest: t-001
## Relevant files
- src/theme.js
## Interface signatures
- src/theme.js: `export function setTheme(name)`
EOF
printf '# Repo map (wave 1)\n- src/theme.js: `export function setTheme(name)`\n' >"$MDIR41r/repo-map.md"
( cd "$repo41r" && LCARS_WORKER_BIN="$repo41r/worker" LCARS_GH_BIN="$repo41r/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >out41r.txt 2>&1 )
TWP41="$(prompt_for_role "$WORKER_CALLS" implement-test-writer)"
IMP41="$(prompt_for_role "$WORKER_CALLS" implement-implementer)"
check "S41-4. Test Writer prompt lists the ticket manifest path" \
  "printf '%s' \"\$TWP41\" | grep -qF '$MDIR41r/manifests/t-001.md'"
check "S41-4. Test Writer prompt lists the repo-map path" \
  "printf '%s' \"\$TWP41\" | grep -qF '$MDIR41r/repo-map.md'"
check "S41-4. Implementer prompt lists the ticket manifest path" \
  "printf '%s' \"\$IMP41\" | grep -qF '$MDIR41r/manifests/t-001.md'"
check "S41-4. Implementer prompt lists the repo-map path" \
  "printf '%s' \"\$IMP41\" | grep -qF '$MDIR41r/repo-map.md'"

# --- S41-4b: the manifest/repo-map are guarded on existence (absent → not listed)
repo41rn="$(new_repo_with_implement_mission)"; arm_worker "$repo41rn"
MDIR41rn="$repo41rn/.git/lcars/missions/$MID"
( cd "$repo41rn" && LCARS_WORKER_BIN="$repo41rn/worker" LCARS_GH_BIN="$repo41rn/gh" \
    bash "$SCRIPT" implement-ticket --mission "$MID" --ticket t-001 >out41rn.txt 2>&1 )
IMP41n="$(prompt_for_role "$WORKER_CALLS" implement-implementer)"
check "S41-4b. with no manifest on disk the Implementer prompt names no manifests/ path" \
  "! printf '%s' \"\$IMP41n\" | grep -qF '$MDIR41rn/manifests/'"

# --- S41-5: PURITY — research workers see NEITHER manifest NOR repo-map ----------
# Seed both artifacts on disk, drive Research from align, and assert that neither
# the question-generator nor any research agent prompt names — or even mentions —
# the manifest or the repo-map. This is the absolute invariant of the perf round.
repo41pur="$(new_repo_with_mission)"; arm_worker "$repo41pur"
MDIR41pur="$repo41pur/.git/lcars/missions/$MID"
mkdir -p "$MDIR41pur/manifests"
printf '# manifest t-001\n- src/x.js: `export function y()`\n' >"$MDIR41pur/manifests/t-001.md"
printf '# Repo map (wave 1)\n- src/x.js: `export function y()`\n' >"$MDIR41pur/repo-map.md"
( cd "$repo41pur" && STUB_NQUESTIONS=2 LCARS_WORKER_BIN="$repo41pur/worker" LCARS_GH_BIN="$repo41pur/gh" \
    bash "$SCRIPT" research --mission "$MID" >out41pur.txt 2>&1 )
RQP41="$(prompt_for_role "$WORKER_CALLS" research-questions)"
RAP41="$(prompt_for_role "$WORKER_CALLS" research-agent)"
check "S41-5. PURITY: research-questions worker is NEVER fed the manifest path" \
  "! printf '%s' \"\$RQP41\" | grep -qF '$MDIR41pur/manifests/'"
check "S41-5. PURITY: research-questions worker is NEVER fed the repo-map path" \
  "! printf '%s' \"\$RQP41\" | grep -qF '$MDIR41pur/repo-map.md'"
check "S41-5. PURITY: research-questions worker mentions no repo-map/manifest at all" \
  "! printf '%s' \"\$RQP41\" | grep -qiE 'repo-map|manifest'"
check "S41-5. PURITY: a research agent worker is NEVER fed the manifest path" \
  "! printf '%s' \"\$RAP41\" | grep -qF '$MDIR41pur/manifests/'"
check "S41-5. PURITY: a research agent worker is NEVER fed the repo-map path" \
  "! printf '%s' \"\$RAP41\" | grep -qF '$MDIR41pur/repo-map.md'"
check "S41-5. PURITY: a research agent worker mentions no repo-map/manifest at all" \
  "! printf '%s' \"\$RAP41\" | grep -qiE 'repo-map|manifest'"

# --- S41-6: DECLARATIVE — the plan.md template forbids bodies/solutions ----------
# The template MUST instruct the Planner to author manifests with signatures /
# paths / ADR ids ONLY — never the implementation, test internals, or reasoning.
PLAN_TMPL="$REPO_ROOT/skills/lcars-run/stages/plan.md"
check "S41-6. plan.md instructs the Planner to emit per-ticket manifests" \
  "grep -qiE 'manifest' '$PLAN_TMPL'"
check "S41-6. plan.md forbids implementation bodies / the edits to make in a manifest" \
  "grep -qiE 'NEVER the (implementation|edits|solution)|signatures?[^.]*only|locations?[^.]*only' '$PLAN_TMPL'"
check "S41-6. plan.md routes manifests to a SEPARATE manifests/ dir (not plan.json)" \
  "grep -qiE 'manifests/' '$PLAN_TMPL'"

# --- Copilot-safe directory scaffolding: cold workers only CREATE FILES; the
# harness owns the manifests/ directory. cmd_plan MUST pre-create the worker's
# scratch manifests/ subdir before spawning (Copilot `create` cannot mkdir a
# missing parent). The plan.md template tells the worker the dir already exists.
check "CN-DIR. cmd_plan pre-creates the worker scratch manifests/ subdir" \
  "grep -qE 'mkdir -p \"\\\$odir/manifests\"' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN-DIR. plan.md tells the worker the manifests/ dir ALREADY EXISTS" \
  "grep -qiE 'manifests/ (directory )?ALREADY EXISTS|ALREADY EXISTS' '$PLAN_TMPL'"
check "CN-DIR. the test-writer scratch tests/ subdir is pre-created by the harness" \
  "grep -qE 'mkdir -p \"\\\$odir/tests\"' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "CN-DIR. implement-test-writer.md tells the worker tests/ ALREADY EXISTS" \
  "grep -qiE 'ALREADY EXISTS' '$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md'"

# ==========================================================================
echo
echo "lcars run — intra-wave parallelism via per-ticket worktrees (Session 37)"

# Session 37 builds a wave's INDEPENDENT tickets CONCURRENTLY, each in its OWN
# `git worktree` checked out (detached) from the mission branch, with a bounded
# concurrency cap from $LCARS_MAX_PARALLEL. The observable end state is UNCHANGED:
# exactly one commit per ticket, with its summary, on the mission branch, in
# wave/plan order (NOT finish order). The adversarial Test-Writer→Implementer
# split, the red gate, and the immutable-test hash run per ticket inside its
# worktree, untouched.
#
#   P37-1  a 2-ticket wave spawns workers CONCURRENTLY (overlap observed),
#          and the cap (LCARS_MAX_PARALLEL) bounds the overlap
#   P37-2  commits land serially on the mission branch in PLAN order — one commit
#          per ticket with its summary — even when finish order ≠ plan order
#   P37-3  a flagged ticket among green siblings still parks the Mission
#          (no green sibling masks the flag)
#   P37-4  the research fan-out now honours LCARS_MAX_PARALLEL (purity intact)
#   P37-5  the red gate + immutable-test hash are still enforced per ticket

# A two-wave plan whose WAVE 1 holds two INDEPENDENT tickets (t-001, t-002) so
# they can build concurrently. (write_waves_json already does this.) We drive the
# whole `implement` stage with a worker stub that records concurrency.

# A worker stub that: (a) on the implementer phase records a live concurrency
# counter (peak) by bumping a counter file, sleeping, then decrementing; and
# (b) writes per-ticket source named after the ticket id parsed from its prompt,
# so each ticket's commit is distinguishable. STUB_FINISH_DELAY lets a chosen
# ticket finish LAST regardless of spawn order (to prove plan-order commits).
make_worker_stub_par() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
tid="${tid:-t-001}"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"
    printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/${tid}.test.js" ;;
  implement-implementer)
    # --- live-concurrency probe (flock-free; macOS has no flock). Each live
    # implementer drops a unique marker; the peak is the max marker count, updated
    # under a portable mkdir-based lock (atomic everywhere).
    if [ -n "${CONC_DIR:-}" ]; then
      mkdir -p "$CONC_DIR/active"; : >"$CONC_DIR/active/$$"
      while ! mkdir "$CONC_DIR/L" 2>/dev/null; do :; done
      n=$(ls "$CONC_DIR/active" | wc -l | tr -d ' ')
      peak=$(cat "$CONC_DIR/peak" 2>/dev/null || echo 0); [ "$n" -gt "$peak" ] && echo "$n" >"$CONC_DIR/peak"
      rmdir "$CONC_DIR/L"
    fi
    # Make t-001 sleep LONGER so t-002 (plan-later) finishes FIRST — proves the
    # commit order follows PLAN order, not finish order. Also gives the two
    # implementers a window to overlap for the concurrency probe.
    case "$tid" in
      t-001) sleep "${STUB_SLOW_DELAY:-0.4}" ;;
      *)     sleep "${STUB_FAST_DELAY:-0.05}" ;;
    esac
    [ -n "${CONC_DIR:-}" ] && rm -f "$CONC_DIR/active/$$"
    mkdir -p src
    printf 'export const %s = 1;\n' "$(printf '%s' "$tid" | tr -dc 'a-zA-Z0-9')" > "src/${tid}.js"
    cat >"$out/result.json" <<JSON
{
  "ticketId": "${tid}",
  "passed": true,
  "attempts": 1,
  "summary": "built ${tid}; suite green."
}
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated repo at stage implement with a committed seed + mission branch.
new_repo_par() { # echoes repo path
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf '# seed\n' > seed.md && git add seed.md && git commit -qm seed \
      && git checkout -q -b "lcars/$MID" )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  write_approved_plan_json "$m/approved-plan.json"
  write_waves_json "$m/waves.json"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "branch": "lcars/$MID",
  "githubIssue": 42
}
EOF
  echo "$repo"
}

# --- P37-1: concurrent spawn, bounded by LCARS_MAX_PARALLEL -------------------
# Wave 1 has two independent tickets. With the cap >= 2 their implementers must
# OVERLAP (peak concurrency > 1); with the cap = 1 they must NOT (peak == 1).
binP1="$TMPROOT/p37-1bin"; rm -rf "$binP1"; mkdir -p "$binP1"
make_worker_stub_par "$binP1/worker"; make_gh_stub "$binP1/gh"

repoP1="$(new_repo_par)"
concP1="$binP1/conc"; rm -rf "$concP1"; mkdir -p "$concP1"; echo 0 >"$concP1/cur"; echo 0 >"$concP1/peak"
( cd "$repoP1" && CONC_DIR="$concP1" LCARS_MAX_PARALLEL=4 \
    LCARS_WORKER_BIN="$binP1/worker" LCARS_GH_BIN="$binP1/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP1/out.txt" 2>&1 ) || true
peakP1="$(cat "$concP1/peak" 2>/dev/null || echo 0)"
check "P37-1. with cap=4, the two wave-1 implementers OVERLAP (peak>1)" \
  "[ \"${peakP1:-0}\" -gt 1 ]"

repoP1s="$(new_repo_par)"
concP1s="$binP1/conc1"; rm -rf "$concP1s"; mkdir -p "$concP1s"; echo 0 >"$concP1s/cur"; echo 0 >"$concP1s/peak"
( cd "$repoP1s" && CONC_DIR="$concP1s" LCARS_MAX_PARALLEL=1 \
    LCARS_WORKER_BIN="$binP1/worker" LCARS_GH_BIN="$binP1/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP1/out1.txt" 2>&1 ) || true
peakP1s="$(cat "$concP1s/peak" 2>/dev/null || echo 0)"
check "P37-1. with cap=1, the implementers do NOT overlap (peak==1)" \
  "[ \"${peakP1s:-0}\" = '1' ]"

# --- P37-2: serial commits in PLAN order, one per ticket, summary preserved ---
# t-001 sleeps longer than t-002, so t-002 FINISHES first; the commit for t-001
# must STILL land before t-002 (plan order). Each commit carries its own summary.
binP2="$TMPROOT/p37-2bin"; rm -rf "$binP2"; mkdir -p "$binP2"
make_worker_stub_par "$binP2/worker"; make_gh_stub "$binP2/gh"
repoP2="$(new_repo_par)"
( cd "$repoP2" && LCARS_MAX_PARALLEL=4 STUB_SLOW_DELAY=0.4 STUB_FAST_DELAY=0.02 \
    LCARS_WORKER_BIN="$binP2/worker" LCARS_GH_BIN="$binP2/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP2/out.txt" 2>&1 ) || true
# The mission branch log (newest first). Filter to ticket commits.
logP2="$( cd "$repoP2" && git log --format='%s' "lcars/$MID" )"
# Wave 1 commits t-001 then t-002; in `git log` newest-first that is t-002 above t-001.
pos1="$(printf '%s\n' "$logP2" | grep -n 'lcars(.*) t-001:' | head -1 | cut -d: -f1)"
pos2="$(printf '%s\n' "$logP2" | grep -n 'lcars(.*) t-002:' | head -1 | cut -d: -f1)"
check "P37-2. exactly one commit for t-001 on the mission branch" \
  "[ \"\$(printf '%s\n' \"$logP2\" | grep -c 'lcars(.*) t-001:')\" = '1' ]"
check "P37-2. exactly one commit for t-002 on the mission branch" \
  "[ \"\$(printf '%s\n' \"$logP2\" | grep -c 'lcars(.*) t-002:')\" = '1' ]"
check "P37-2. t-001 commits BEFORE t-002 (plan order, despite t-002 finishing first)" \
  "[ -n \"$pos1\" ] && [ -n \"$pos2\" ] && [ \"$pos1\" -gt \"$pos2\" ]"
check "P37-2. each commit carries the ticket's OWN summary" \
  "printf '%s\n' \"$logP2\" | grep -q 't-001: built t-001' && printf '%s\n' \"$logP2\" | grep -q 't-002: built t-002'"
check "P37-2. the commit message format is lcars(<mission>) <ticket>: <summary>" \
  "printf '%s\n' \"$logP2\" | grep -qE 'lcars\\($MID\\) t-001: '"
check "P37-2. each ticket's produced source is in the tree" \
  "[ -f '$repoP2/src/t-001.js' ] && [ -f '$repoP2/src/t-002.js' ]"
check "P37-2. wave 2 also completes and the stage advanced to verify" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoP2")'"
# No leftover worktrees in the working tree / git metadata after the stage.
check "P37-2. no stray git worktrees remain after the stage" \
  "[ -z \"\$( cd '$repoP2' && git worktree list --porcelain | grep -i 't-001' )\" ]"

# --- P37-3: a flagged ticket among green siblings still parks the Mission ------
# A stub where t-002 FAILS (passed:false, attempts:5 → the human gate) while
# t-001 goes green. A fast green sibling must NOT mask t-002's flag.
make_worker_stub_par_flag() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
tid="${tid:-t-001}"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/${tid}.test.js" ;;
  implement-implementer)
    mkdir -p src; printf 'export const x = 1;\n' > "src/${tid}.js"
    if [ "$tid" = "t-002" ]; then
      cat >"$out/result.json" <<JSON
{ "ticketId": "t-002", "passed": false, "attempts": 5, "summary": "could not get t-002 green." }
JSON
    else
      cat >"$out/result.json" <<JSON
{ "ticketId": "${tid}", "passed": true, "attempts": 1, "summary": "built ${tid}; suite green." }
JSON
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}
binP3="$TMPROOT/p37-3bin"; rm -rf "$binP3"; mkdir -p "$binP3"
make_worker_stub_par_flag "$binP3/worker"; make_gh_stub "$binP3/gh"
repoP3="$(new_repo_par)"
rcP3=0
( cd "$repoP3" && LCARS_MAX_PARALLEL=4 \
    LCARS_WORKER_BIN="$binP3/worker" LCARS_GH_BIN="$binP3/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP3/out.txt" 2>&1 ) || rcP3=$?
sP3="$(state_of "$repoP3")"
check "P37-3. a flagged sibling parks the Mission at awaiting-human" \
  "grep -q '\"awaitingHuman\": *true' '$sP3'"
check "P37-3. the Mission stays at the implement stage (not advanced to verify)" \
  "grep -q '\"stage\": *\"implement\"' '$sP3'"
check "P37-3. the pending question names the flagged ticket t-002" \
  "grep -q 't-002' '$repoP3/.git/lcars/missions/$MID/pending.json'"
check "P37-3. the green sibling t-001 still committed (no rollback of good work)" \
  "[ \"\$( cd '$repoP3' && git log --format='%s' 'lcars/$MID' | grep -c 't-001:' )\" = '1' ]"

# --- P37-4: a hard worker failure (no result) stops the Stage non-zero --------
# A stub that produces NO result.json for t-002 → implement-ticket dies; the
# concurrent sibling must not mask it: the whole stage exits non-zero.
make_worker_stub_par_hardfail() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
tid="${tid:-t-001}"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/${tid}.test.js" ;;
  implement-implementer)
    if [ "$tid" = "t-002" ]; then exit 0; fi   # NO result.json → hard failure
    mkdir -p src; printf 'export const x = 1;\n' > "src/${tid}.js"
    cat >"$out/result.json" <<JSON
{ "ticketId": "${tid}", "passed": true, "attempts": 1, "summary": "built ${tid}." }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}
binP4="$TMPROOT/p37-4bin"; rm -rf "$binP4"; mkdir -p "$binP4"
make_worker_stub_par_hardfail "$binP4/worker"; make_gh_stub "$binP4/gh"
repoP4="$(new_repo_par)"
rcP4=0
( cd "$repoP4" && LCARS_MAX_PARALLEL=4 \
    LCARS_WORKER_BIN="$binP4/worker" LCARS_GH_BIN="$binP4/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP4/out.txt" 2>&1 ) || rcP4=$?
check "P37-4. a hard worker failure stops the Stage non-zero" "[ '$rcP4' -ne 0 ]"
check "P37-4. the Stage did NOT advance to verify on a hard failure" \
  "! grep -q '\"stage\": *\"verify\"' '$(state_of "$repoP4")'"

# --- P37-5: the research fan-out now honours LCARS_MAX_PARALLEL (purity intact) -
# Research dispatches one worker per question. With many questions and cap=2 the
# research agents must NOT exceed the cap; and EACH still gets ONLY its question.
make_worker_stub_research_conc() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  research-questions)
    : >"$out/questions.txt"
    k="${STUB_NQUESTIONS:-6}"; i=0
    while [ "$i" -lt "$k" ]; do i=$((i+1)); echo "Stub question $i?" >>"$out/questions.txt"; done ;;
  research-agent)
    if [ -n "${CONC_DIR:-}" ]; then
      mkdir -p "$CONC_DIR/active"; : >"$CONC_DIR/active/$$"
      while ! mkdir "$CONC_DIR/L" 2>/dev/null; do :; done
      n=$(ls "$CONC_DIR/active" | wc -l | tr -d ' ')
      peak=$(cat "$CONC_DIR/peak" 2>/dev/null || echo 0); [ "$n" -gt "$peak" ] && echo "$n" >"$CONC_DIR/peak"
      rmdir "$CONC_DIR/L"
    fi
    sleep 0.15
    [ -n "${CONC_DIR:-}" ] && rm -f "$CONC_DIR/active/$$"
    # Record the prompt so purity can be asserted.
    printf '%s' "$prompt" > "$CONC_DIR/agentprompt.$$.txt"
    cat >"$out/response.json" <<JSON
{ "question": "stub", "recommendation": "Do the sensible thing.", "supporting_points": ["a", "b"] }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}
binP5="$TMPROOT/p37-5bin"; rm -rf "$binP5"; mkdir -p "$binP5"
make_worker_stub_research_conc "$binP5/worker"; make_gh_stub "$binP5/gh"
repoP5="$(new_repo_with_mission)"
concP5="$binP5/conc"; rm -rf "$concP5"; mkdir -p "$concP5"; echo 0 >"$concP5/cur"; echo 0 >"$concP5/peak"
export GH_LOG="$binP5/gh.log"; : >"$GH_LOG"
( cd "$repoP5" && CONC_DIR="$concP5" STUB_NQUESTIONS=6 LCARS_MAX_PARALLEL=2 \
    LCARS_WORKER_BIN="$binP5/worker" LCARS_GH_BIN="$binP5/gh" \
    bash "$SCRIPT" research --mission "$MID" >"$binP5/out.txt" 2>&1 ) || true
peakP5="$(cat "$concP5/peak" 2>/dev/null || echo 0)"
check "P37-4/research. research fan-out never exceeds LCARS_MAX_PARALLEL=2" \
  "[ \"${peakP5:-0}\" -le 2 ] && [ \"${peakP5:-0}\" -ge 1 ]"
check "P37-4/research. with 6 questions and cap 2, more than one agent ran at once" \
  "[ \"${peakP5:-0}\" -gt 1 ]"
check "P37-4/research. PURITY: a research agent prompt carries ONLY its question (no PRD body)" \
  "! grep -rqi 'Let users switch to a dark' $concP5/agentprompt.*.txt"
check "P37-4/research. PURITY: a research agent prompt names no artifact paths" \
  "! grep -rq '/prd.md\\|/state.json\\|approved-plan' $concP5/agentprompt.*.txt"
check "P37-4/research. research still advanced the stage to validate" \
  "grep -q '\"stage\": *\"validate\"' '$(state_of "$repoP5")'"

# --- P37-5b: the red gate + immutable-test hash are enforced per ticket --------
# Per-ticket-in-worktree, the red gate must still reject a suite that passes with
# no implementation, and the immutable hash must still reject edited tests. Both
# already run inside implement-ticket; re-assert through the parallel path with a
# test command set. A stub whose tests PASS on nothing (no red) must be rejected.
binP5b="$TMPROOT/p37-5bbin"; rm -rf "$binP5b"; mkdir -p "$binP5b"
cat >"$binP5b/worker" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer) mkdir -p "$out/tests"; printf 'assert true\n' >"$out/tests/${tid:-t}.test" ;;
esac
exit 0
EOF
chmod +x "$binP5b/worker"; make_gh_stub "$binP5b/gh"
repoP5b="$(new_repo_par)"
rcP5b=0
# A test command that ALWAYS succeeds → the red gate sees green-on-nothing → reject.
( cd "$repoP5b" && LCARS_TEST_CMD='true' LCARS_MAX_PARALLEL=4 \
    LCARS_WORKER_BIN="$binP5b/worker" LCARS_GH_BIN="$binP5b/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP5b/out.txt" 2>&1 ) || rcP5b=$?
check "P37-5. the red gate still fires per ticket inside the worktree (stage stops)" \
  "[ '$rcP5b' -ne 0 ]"
check "P37-5. the red-gate rejection is surfaced (mentions red gate / failed)" \
  "grep -qi 'red gate\\|failed\\|stopped' '$binP5b/out.txt'"

# --- P37-6: SAME-FILE wave composes (Session 37 defect fix) --------------------
# The reported regression: a single wave of independent tickets that each ADD a
# case branch + handler to the SAME dispatcher file at the SAME anchor. Built
# blind off the frozen wave base, the serial cherry-pick of the 2nd/3rd ticket
# CONFLICTS textually (two independent insertions at the same line). The fix must
# still finish: exactly one commit per ticket on the mission branch in PLAN order,
# ALL tickets' additions present (none lost), and NO stray worktrees.
#
# A worker stub that appends each ticket's case branch right before the SAME
# `DISPATCH-ANCHOR` line in the shared dispatcher file. Each build runs off the
# frozen base, so all three insert at the same spot → cherry-pick conflict.
make_worker_stub_samefile() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
tid="${tid:-t-001}"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/${tid}.test.js" ;;
  implement-implementer)
    # Insert this ticket's case branch right before the shared dispatch anchor in
    # the SAME file. additively. Reads the CURRENT dispatcher (in this worktree),
    # so a serial rebuild off the updated tip composes on top of prior tickets.
    f="src/dispatch.js"
    line="  case '${tid}': return handle_${tid}();  // ADDED-${tid}"
    awk -v ins="$line" '/DISPATCH-ANCHOR/{print ins} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    cat >"$out/result.json" <<JSON
{
  "ticketId": "${tid}",
  "passed": true,
  "attempts": 1,
  "summary": "added ${tid} case to dispatcher."
}
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A 3-ticket single-wave plan + waves, all independent, sharing only the file.
write_samefile_plan_json() { # file
  cat >"$1" <<'EOF'
[
  { "id": "t-001", "title": "case a", "description": "d", "acceptanceCriteria": ["a"],
    "estimatedReadLoc": 10, "estimatedTestLoc": 5, "estimatedNewLoc": 5,
    "dependencies": [], "rationale": "shares only the dispatch file — no logic in common" },
  { "id": "t-002", "title": "case b", "description": "d", "acceptanceCriteria": ["a"],
    "estimatedReadLoc": 10, "estimatedTestLoc": 5, "estimatedNewLoc": 5,
    "dependencies": [], "rationale": "shares only the dispatch file — no logic in common" },
  { "id": "t-003", "title": "case c", "description": "d", "acceptanceCriteria": ["a"],
    "estimatedReadLoc": 10, "estimatedTestLoc": 5, "estimatedNewLoc": 5,
    "dependencies": [], "rationale": "shares only the dispatch file — no logic in common" }
]
EOF
}
write_samefile_waves_json() { # file
  cat >"$1" <<'EOF'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": 101 },
      { "id": "t-002", "issue": 102 },
      { "id": "t-003", "issue": 103 }
  ] }
]
EOF
}
# A repo at stage implement, mission branch, with the shared dispatcher committed.
new_repo_samefile() { # echoes repo path
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir -p src \
      && printf 'function dispatch(x){\n  switch(x){\n  // DISPATCH-ANCHOR\n  default: return null;\n  }\n}\n' > src/dispatch.js \
      && git add src/dispatch.js && git commit -qm seed \
      && git checkout -q -b "lcars/$MID" )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  write_samefile_plan_json "$m/approved-plan.json"
  write_samefile_waves_json "$m/waves.json"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dispatch cases",
  "stage": "implement",
  "branch": "lcars/$MID",
  "githubIssue": 42
}
EOF
  echo "$repo"
}

binP6="$TMPROOT/p37-6bin"; rm -rf "$binP6"; mkdir -p "$binP6"
make_worker_stub_samefile "$binP6/worker"; make_gh_stub "$binP6/gh"
repoP6="$(new_repo_samefile)"
rcP6=0
( cd "$repoP6" && LCARS_MAX_PARALLEL=3 \
    LCARS_WORKER_BIN="$binP6/worker" LCARS_GH_BIN="$binP6/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP6/out.txt" 2>&1 ) || rcP6=$?
sP6="$(state_of "$repoP6")"
check "P37-6. the same-file wave Stage completes (no hard stop)" \
  "[ '$rcP6' -eq 0 ]"
check "P37-6. the Stage advanced to verify" \
  "grep -q '\"stage\": *\"verify\"' '$sP6'"
logP6="$( cd "$repoP6" && git log --format='%s' "lcars/$MID" )"
check "P37-6. exactly one commit per ticket on the mission branch" \
  "[ \"\$(printf '%s\n' \"$logP6\" | grep -c 'lcars(.*) t-001:')\" = '1' ] \
   && [ \"\$(printf '%s\n' \"$logP6\" | grep -c 'lcars(.*) t-002:')\" = '1' ] \
   && [ \"\$(printf '%s\n' \"$logP6\" | grep -c 'lcars(.*) t-003:')\" = '1' ]"
# Plan order: newest-first in git log → t-003 above t-002 above t-001.
p6a="$(printf '%s\n' "$logP6" | grep -n 't-001:' | head -1 | cut -d: -f1)"
p6b="$(printf '%s\n' "$logP6" | grep -n 't-002:' | head -1 | cut -d: -f1)"
p6c="$(printf '%s\n' "$logP6" | grep -n 't-003:' | head -1 | cut -d: -f1)"
check "P37-6. commits land in PLAN order (t-001, then t-002, then t-003)" \
  "[ -n \"$p6a\" ] && [ -n \"$p6b\" ] && [ -n \"$p6c\" ] && [ \"$p6a\" -gt \"$p6b\" ] && [ \"$p6b\" -gt \"$p6c\" ]"
check "P37-6. each commit carries the ticket's OWN summary" \
  "printf '%s\n' \"$logP6\" | grep -q 't-001: added t-001' \
   && printf '%s\n' \"$logP6\" | grep -q 't-002: added t-002' \
   && printf '%s\n' \"$logP6\" | grep -q 't-003: added t-003'"
# ALL three additions are present in the final dispatcher — none lost / overwritten.
check "P37-6. the shared file contains ALL THREE tickets' additions (none lost)" \
  "grep -q 'ADDED-t-001' '$repoP6/src/dispatch.js' \
   && grep -q 'ADDED-t-002' '$repoP6/src/dispatch.js' \
   && grep -q 'ADDED-t-003' '$repoP6/src/dispatch.js'"
check "P37-6. no stray git worktrees remain after the same-file wave" \
  "[ -z \"\$( cd '$repoP6' && git worktree list --porcelain | grep -iE 't-00[123]' )\" ] \
   && [ ! -d '$repoP6/.git/lcars/missions/$MID/worktrees' ]"
check "P37-6. the working tree is clean afterwards" \
  "[ -z \"\$( cd '$repoP6' && git status --porcelain )\" ]"

# --- P37-7: an UNRECOVERABLE same-file failure parks at awaiting-human ----------
# When a conflicting ticket cannot be made green even on the serial rebuild (its
# Implementer flags the human), the Stage must NOT bare-die: it must clean up ALL
# worktrees AND route through the awaiting-human gate (label + pending question),
# the same recourse a normal exhausted ticket gets — and leave no partial,
# recourse-less commit set stranded.
make_worker_stub_samefile_flag() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --allowedTools) shift 2;; *) shift;; esac; done
out="$LCARS_WORK_OUT"
tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
tid="${tid:-t-001}"
case "$LCARS_WORKER_ROLE" in
  implement-test-writer)
    mkdir -p "$out/tests"; printf 'it("works", () => expect(true).toBe(true))\n' >"$out/tests/${tid}.test.js" ;;
  implement-implementer)
    f="src/dispatch.js"
    line="  case '${tid}': return handle_${tid}();  // ADDED-${tid}"
    awk -v ins="$line" '/DISPATCH-ANCHOR/{print ins} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    if [ "$tid" = "t-002" ]; then
      # t-002 conflicts on replay AND cannot be made green on rebuild → unrecoverable.
      cat >"$out/result.json" <<JSON
{ "ticketId": "t-002", "passed": false, "attempts": 5, "summary": "could not get t-002 green." }
JSON
    else
      cat >"$out/result.json" <<JSON
{ "ticketId": "${tid}", "passed": true, "attempts": 1, "summary": "added ${tid} case to dispatcher." }
JSON
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}
binP7="$TMPROOT/p37-7bin"; rm -rf "$binP7"; mkdir -p "$binP7"
make_worker_stub_samefile_flag "$binP7/worker"; make_gh_stub "$binP7/gh"
export GH_LOG="$binP7/gh.log"; : >"$GH_LOG"
repoP7="$(new_repo_samefile)"
rcP7=0
( cd "$repoP7" && LCARS_MAX_PARALLEL=3 \
    LCARS_WORKER_BIN="$binP7/worker" LCARS_GH_BIN="$binP7/gh" \
    bash "$SCRIPT" implement --mission "$MID" >"$binP7/out.txt" 2>&1 ) || rcP7=$?
sP7="$(state_of "$repoP7")"
check "P37-7. an unrecoverable conflicting ticket parks at awaiting-human (state)" \
  "grep -q '\"awaitingHuman\": *true' '$sP7'"
check "P37-7. it stays at the implement stage (not advanced to verify)" \
  "grep -q '\"stage\": *\"implement\"' '$sP7'"
check "P37-7. the awaiting-human label is applied (the human gate, not a bare die)" \
  "grep -q 'add-label lcars:awaiting-human' '$binP7/gh.log'"
check "P37-7. a pending question naming t-002 is recorded" \
  "[ -f '$repoP7/.git/lcars/missions/$MID/pending.json' ] && grep -q 't-002' '$repoP7/.git/lcars/missions/$MID/pending.json'"
check "P37-7. NO stray git worktrees remain after the escalation" \
  "[ -z \"\$( cd '$repoP7' && git worktree list --porcelain | grep -iE 't-00[123]' )\" ] \
   && [ ! -d '$repoP7/.git/lcars/missions/$MID/worktrees' ]"
check "P37-7. the working tree is clean after the escalation (no stranded conflict)" \
  "[ -z \"\$( cd '$repoP7' && git status --porcelain )\" ]"

# ==========================================================================
echo
printf 'lcars run: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
