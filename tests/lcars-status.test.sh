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

# --- FIX 3: the glyph legend only prints when a row actually has a glyph -----
# A freshly-filed, non-paused, non-awaiting mission has no glyph. The trailing
# "⏸ paused  ❓ awaiting your input" legend must NOT print then — otherwise it
# reads as if that single clean mission is itself paused / awaiting.
repo4c="$(new_init_repo)"
write_mission "$repo4c" "lcars-20260530-001" "align" "42" \
  "2026-05-30T10:00:00Z" "Fresh mission"
( cd "$repo4c" && bash "$SCRIPT" >out.txt 2>&1 )
check "4. no glyph legend on a clean board (no 'awaiting your input')" \
  "! grep -qi 'awaiting your input' '$repo4c/out.txt'"
check "4. no stray 'paused' legend on a clean board" \
  "! grep -qi 'paused' '$repo4c/out.txt'"

# With a glyph-bearing mission present (paused here), the legend IS shown.
repo4d="$(new_init_repo)"
write_mission "$repo4d" "lcars-20260530-001" "implement" "42" \
  "2026-05-30T10:00:00Z" "Paused mission" "true"
( cd "$repo4d" && bash "$SCRIPT" >out.txt 2>&1 )
check "4. legend IS shown once a glyph is rendered" \
  "grep -qi 'paused' '$repo4d/out.txt' && grep -qi 'awaiting your input' '$repo4d/out.txt'"

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

# --- Regression: a string value containing an escaped quote -----------------
# A pending question can contain a literal double-quote, which valid JSON
# escapes as \". The reader must decode it and print the FULL question, not
# truncate at the first inner quote.
repo8="$(new_init_repo)"
d8="$repo8/.git/lcars/missions/lcars-20260530-001"; mkdir -p "$d8"
{
  printf '{\n'
  printf '  "id": "lcars-20260530-001",\n'
  printf '  "title": "Add dark mode",\n'
  printf '  "stage": "validate",\n'
  printf '  "created": "2026-05-30T10:00:00Z",\n'
  printf '  "pendingQuestion": "Should the toggle say \\"Dark\\" or use an icon?",\n'
  printf '  "githubIssue": 42\n'
  printf '}\n'
} >"$d8/state.json"
( cd "$repo8" && bash "$SCRIPT" >out.txt 2>&1 )
check "8. prints the whole question, decoding the escaped quotes" \
  "grep -qF 'Should the toggle say \"Dark\" or use an icon?' '$repo8/out.txt'"
check "8. does not truncate the question at the first inner quote" \
  "! grep -qE 'Should the toggle say \\\\\$' '$repo8/out.txt'"
check "8. an escaped quote in the title does not corrupt the row" \
  "grep -q 'Add dark mode' '$repo8/out.txt'"

# --- Behaviour 9: awaiting-human gate shows the TRUE in-flight stage --------
# When Research escalates (>20 questions), the Mission parks behind the gate:
# state.json.stage stays "align" (the resume pointer, so `lcars run` re-enters
# Research), but pending.json records the real in-flight stage "research" — the
# same value the board label carries. `lcars status` must display "research" so
# the CLI view agrees with the Kanban column, not the stale "align".
repo9="$(new_init_repo)"
d9="$repo9/.git/lcars/missions/lcars-20260530-009"; mkdir -p "$d9"
{
  printf '{\n'
  printf '  "id": "lcars-20260530-009",\n'
  printf '  "title": "Gamification overhaul",\n'
  printf '  "stage": "align",\n'
  printf '  "created": "2026-05-30T10:00:00Z",\n'
  printf '  "awaitingHuman": true,\n'
  printf '  "pendingQuestion": "Research needs 21 questions — override or return-to-align?",\n'
  printf '  "githubIssue": 9\n'
  printf '}\n'
} >"$d9/state.json"
cat >"$d9/pending.json" <<'EOF'
{
  "stage": "research",
  "questions": [
    "Research needs 21 questions — override or return-to-align?"
  ]
}
EOF
( cd "$repo9" && bash "$SCRIPT" >out.txt 2>&1 )
check "9. displays the in-flight stage (research) from pending.json" \
  "grep -qE 'lcars-20260530-009[[:space:]]+#9[[:space:]]+research' '$repo9/out.txt'"
check "9. does not display the stale resume-pointer stage (align)" \
  "! grep -qE 'lcars-20260530-009[[:space:]]+#9[[:space:]]+align' '$repo9/out.txt'"

# Fallback: awaiting-human with NO pending.json keeps state.json.stage. A gate
# is normally backed by pending.json, but a corrupt/half-written one must still
# render — falling back to the resume pointer rather than blanking the column.
repo9b="$(new_init_repo)"
write_mission "$repo9b" "lcars-20260530-010" "validate" "10" \
  "2026-05-30T10:00:00Z" "No pending file" "" "Some pending question?"
( cd "$repo9b" && bash "$SCRIPT" >out.txt 2>&1 )
check "9. falls back to state.json.stage when there is no pending.json" \
  "grep -qE 'lcars-20260530-010[[:space:]]+#10[[:space:]]+validate' '$repo9b/out.txt'"

# ==========================================================================
echo
printf 'lcars status: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
