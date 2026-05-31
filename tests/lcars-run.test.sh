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

# --- Behaviour 4: GitHub label moved align → research ----------------------
# (asserted on the save path of behaviour 2)
check "4. calls gh issue edit on the mission's issue" \
  "grep -q 'issue edit 42' '$repo2/gh.log'"
check "4. adds the lcars:research label" \
  "grep -q 'add-label lcars:research' '$repo2/gh.log'"
check "4. removes the lcars:align label" \
  "grep -q 'remove-label lcars:align' '$repo2/gh.log'"
# the skip path (behaviour 1) relabels too
check "4. skip path also relabels align → research" \
  "grep -q 'add-label lcars:research' '$repo1/gh.log' && grep -q 'remove-label lcars:align' '$repo1/gh.log'"

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
printf 'lcars run: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
