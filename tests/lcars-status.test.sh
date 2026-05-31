#!/usr/bin/env bash
#
# Tests for `lcars status` (skill source: skills/lcars-status/status.sh).
#
# `lcars status` is read-only: it scans .git/lcars/missions/, loads each
# state.json, and renders the active-mission table. All the logic lives in
# status.sh so it can be exercised directly. These tests drive that script,
# covering the six behaviours from the build order, in order:
#   1. Returns "not initialised" message when .git/lcars/ is missing
#   2. Returns "no missions" message when missions/ is empty
#   3. Reads and displays a single mission correctly
#   4. Displays paused indicator when state.json has paused: true
#   5. Displays awaiting-human indicator and prints the pending question
#   6. Sorts missions by created date, newest first
#
# Usage: bash tests/lcars-status.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_STATUS_SCRIPT:-$REPO_ROOT/skills/lcars-status/status.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- helpers --------------------------------------------------------------

# A bare git repo with NO .git/lcars/ scaffold.
new_bare_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "$repo"
}

# A git repo with an empty .git/lcars/missions/.
new_init_repo() {
  local repo; repo="$(new_bare_repo)"
  mkdir -p "$repo/.git/lcars/missions"
  echo "$repo"
}

# write_mission <repo> <id> <stage> <issue> <created> <title> [paused] [question]
write_mission() {
  local repo="$1" id="$2" stage="$3" issue="$4" created="$5" title="$6"
  local paused="${7:-}" question="${8:-}"
  local dir="$repo/.git/lcars/missions/$id"
  mkdir -p "$dir"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "%s",\n' "$title"
    printf '  "stage": "%s",\n' "$stage"
    printf '  "created": "%s",\n' "$created"
    printf '  "model": "claude-sonnet",\n'
    [ -n "$paused" ]   && printf '  "paused": %s,\n' "$paused"
    [ -n "$question" ] && printf '  "pendingQuestion": "%s",\n' "$question"
    printf '  "githubIssue": %s\n' "$issue"
    printf '}\n'
  } >"$dir/state.json"
}

# ==========================================================================
echo "lcars status"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: not initialised -----------------------------------------
repo1="$(new_bare_repo)"
( cd "$repo1" && bash "$SCRIPT" >out.txt 2>&1 )
check "1. reports not initialised when .git/lcars/ is missing" \
  "grep -qi 'not initialised' '$repo1/out.txt'"
check "1. points the captain at lcars init" \
  "grep -q 'lcars init' '$repo1/out.txt'"

# --- Behaviour 2: no missions ---------------------------------------------
repo2="$(new_init_repo)"
( cd "$repo2" && bash "$SCRIPT" >out.txt 2>&1 )
check "2. reports no missions when missions/ is empty" \
  "grep -qi 'no active missions' '$repo2/out.txt'"
check "2. points the captain at lcars file" \
  "grep -q 'lcars file' '$repo2/out.txt'"

# --- Behaviour 3: single mission ------------------------------------------
repo3="$(new_init_repo)"
write_mission "$repo3" "lcars-20260530-001" "implement" "42" \
  "2026-05-30T10:00:00Z" "Add gamification"
( cd "$repo3" && bash "$SCRIPT" >out.txt 2>&1 )
check "3. shows the mission id"     "grep -q 'lcars-20260530-001' '$repo3/out.txt'"
check "3. shows the issue number"   "grep -q '#42' '$repo3/out.txt'"
check "3. shows the stage"          "grep -q 'implement' '$repo3/out.txt'"
check "3. shows the title"          "grep -q 'Add gamification' '$repo3/out.txt'"
check "3. shows the table header"   "grep -qi 'Active Missions' '$repo3/out.txt'"

# --- Behaviour 4: paused indicator ----------------------------------------
repo4="$(new_init_repo)"
write_mission "$repo4" "lcars-20260530-001" "implement" "42" \
  "2026-05-30T10:00:00Z" "Add gamification" "true"
( cd "$repo4" && bash "$SCRIPT" >out.txt 2>&1 )
# the paused mission's row carries the ⏸ glyph
check "4. marks the paused mission with the pause glyph" \
  "grep -q '⏸' '$repo4/out.txt'"
check "4. paused glyph sits on the mission row" \
  "grep -E 'lcars-20260530-001.*⏸|⏸.*lcars-20260530-001' '$repo4/out.txt' >/dev/null"
# a NON-paused mission must not be marked
repo4b="$(new_init_repo)"
write_mission "$repo4b" "lcars-20260530-001" "implement" "42" \
  "2026-05-30T10:00:00Z" "Add gamification"
( cd "$repo4b" && bash "$SCRIPT" >out.txt 2>&1 )
check "4. unpaused mission row carries no pause glyph" \
  "! grep -q '⏸.*lcars\\|lcars-20260530-001.*⏸' '$repo4b/out.txt'"

# --- Behaviour 5: awaiting-human indicator + question ---------------------
repo5="$(new_init_repo)"
write_mission "$repo5" "lcars-20260530-002" "research" "43" \
  "2026-05-30T11:00:00Z" "Add dark mode" "" "Global or per-course leaderboard?"
( cd "$repo5" && bash "$SCRIPT" >out.txt 2>&1 )
check "5. marks the awaiting mission with the question glyph" \
  "grep -q '❓' '$repo5/out.txt'"
check "5. prints the pending question text" \
  "grep -q 'Global or per-course leaderboard?' '$repo5/out.txt'"
check "5. ties the question to its mission id" \
  "grep -q 'lcars-20260530-002' '$repo5/out.txt'"

# --- Behaviour 6: sort by created, newest first ---------------------------
repo6="$(new_init_repo)"
write_mission "$repo6" "lcars-20260530-001" "implement" "42" \
  "2026-05-30T09:00:00Z" "Oldest mission"
write_mission "$repo6" "lcars-20260530-002" "research" "43" \
  "2026-05-30T12:00:00Z" "Newest mission"
write_mission "$repo6" "lcars-20260530-003" "align" "44" \
  "2026-05-30T10:30:00Z" "Middle mission"
( cd "$repo6" && bash "$SCRIPT" >out.txt 2>&1 )
# the newest-created mission must appear above the middle, which is above the oldest
newest_line="$(grep -n 'Newest mission' "$repo6/out.txt" | head -1 | cut -d: -f1)"
middle_line="$(grep -n 'Middle mission' "$repo6/out.txt" | head -1 | cut -d: -f1)"
oldest_line="$(grep -n 'Oldest mission' "$repo6/out.txt" | head -1 | cut -d: -f1)"
check "6. newest mission is listed before the middle one" \
  "[ '$newest_line' -lt '$middle_line' ]"
check "6. middle mission is listed before the oldest one" \
  "[ '$middle_line' -lt '$oldest_line' ]"

# --- Regression: single-line state.json must parse cleanly ----------------
# file.sh writes multi-line JSON, but a compact one-line state.json (hand-
# written, or from a future writer) must not have its whole tail swallowed
# by a greedy field match.
repo7="$(new_init_repo)"
d7="$repo7/.git/lcars/missions/lcars-20260530-001"; mkdir -p "$d7"
printf '{ "id": "lcars-20260530-001", "title": "Compact mission", "stage": "plan", "created": "2026-05-30T10:00:00Z", "githubIssue": 7 }\n' >"$d7/state.json"
( cd "$repo7" && bash "$SCRIPT" >out.txt 2>&1 )
check "7. parses a single-line state.json title cleanly" \
  "grep -q 'Compact mission' '$repo7/out.txt'"
check "7. single-line title is not polluted by later json fields" \
  "! grep -q 'Compact mission.*githubIssue' '$repo7/out.txt'"
check "7. single-line stage parses to just the stage value" \
  "grep -qE 'lcars-20260530-001[^\\n]*[[:space:]]plan([[:space:]]|\$)' '$repo7/out.txt'"

# ==========================================================================
echo
printf 'lcars status: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
