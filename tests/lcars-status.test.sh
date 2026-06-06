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
# --watch / --once : the live Mission event view (Session 27)
#
# `--once` is the deterministic, non-follow sibling of `--watch`: it reads a
# FIXED events.jsonl + waves.json, renders every human line, computes the final
# progress line, and exits — so the math is assertable without a live tail.
# `$LCARS_NOW` pins "now" for elapsed; the shared resolver picks the mission.
# ==========================================================================
echo
echo "lcars status --watch / --once"

# The real shared resolver lives one dir up from status.sh.
RESOLVE="${LCARS_RESOLVE_SCRIPT:-$REPO_ROOT/skills/lcars/resolve.sh}"

# write_events <repo> <id> <events.jsonl-body>  — drop a literal event stream.
write_events() {
  local repo="$1" id="$2" body="$3"
  local dir="$repo/.git/lcars/missions/$id"
  mkdir -p "$dir"
  printf '%s\n' "$body" >"$dir/events.jsonl"
}

# write_waves <repo> <id> <waves.json-body> — drop a canonical waves.json.
write_waves() {
  local repo="$1" id="$2" body="$3"
  local dir="$repo/.git/lcars/missions/$id"
  mkdir -p "$dir"
  printf '%s\n' "$body" >"$dir/waves.json"
}

WAVES_3='[
  { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 }, { "id": "t-002", "issue": 12 } ] },
  { "wave": 2, "tickets": [ { "id": "t-003", "issue": 13 }, { "id": "t-004", "issue": 14 } ] },
  { "wave": 3, "tickets": [ { "id": "t-005", "issue": 15 }, { "id": "t-006", "issue": 16 } ] }
]'

# --- Behaviour W1: every event type renders to its expected human line --------
repoW1="$(new_init_repo)"
write_mission "$repoW1" "lcars-20260601-001" "implement" "21" \
  "2026-06-01T10:00:00Z" "Watch me"
write_events "$repoW1" "lcars-20260601-001" \
'{"ts":1000,"mission":"lcars-20260601-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260601-001","stage":"research","type":"stage_done","detail":"asked 3 questions, all answered"}
{"ts":1002,"mission":"lcars-20260601-001","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":3}}
{"ts":1003,"mission":"lcars-20260601-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1004,"mission":"lcars-20260601-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 2 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":2}}
{"ts":1010,"mission":"lcars-20260601-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","attempts":2}}
{"ts":1011,"mission":"lcars-20260601-001","stage":"implement","type":"ticket_flagged","detail":"ticket t-002 flagged after 5 attempt(s)","data":{"ticket":"t-002","attempts":5}}
{"ts":1012,"mission":"lcars-20260601-001","stage":"verify","type":"gate","detail":"human review required"}
{"ts":1013,"mission":"lcars-20260601-001","stage":"error","type":"error","detail":"implement failed"}'
write_waves "$repoW1" "lcars-20260601-001" "$WAVES_3"
( cd "$repoW1" && LCARS_NOW=2000 bash "$SCRIPT" --once lcars-20260601-001 >out.txt 2>&1 )
check "W1. renders stage_start line"    "grep -qi 'research' '$repoW1/out.txt' && grep -qi 'start' '$repoW1/out.txt'"
check "W1. renders stage_done summary"  "grep -qF 'asked 3 questions, all answered' '$repoW1/out.txt'"
check "W1. renders wave_start line"     "grep -qiE 'wave 1' '$repoW1/out.txt'"
check "W1. renders ticket_start line"   "grep -qi 'ticket t-001' '$repoW1/out.txt'"
check "W1. renders ticket_attempt line" "grep -qiE 'attempt|try' '$repoW1/out.txt' && grep -q 't-001' '$repoW1/out.txt'"
check "W1. renders ticket_green line"   "grep -qi 'green' '$repoW1/out.txt' && grep -q 't-001' '$repoW1/out.txt'"
check "W1. renders ticket_flagged line" "grep -qi 'flag' '$repoW1/out.txt' && grep -q 't-002' '$repoW1/out.txt'"
check "W1. renders gate line"           "grep -qF 'human review required' '$repoW1/out.txt'"
check "W1. renders error line"          "grep -qi 'implement failed' '$repoW1/out.txt'"

# --- Behaviour W2: progress line Wave x/y and ticket k-of-n -------------------
# Stream is partway through wave 2, on t-004; two tickets (t-001,t-002) green.
repoW2="$(new_init_repo)"
write_mission "$repoW2" "lcars-20260601-002" "implement" "22" \
  "2026-06-01T10:00:00Z" "Progress math"
write_events "$repoW2" "lcars-20260601-002" \
'{"ts":1000,"mission":"lcars-20260601-002","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260601-002","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":3}}
{"ts":1002,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}
{"ts":1010,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","attempts":1}}
{"ts":1011,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_start","detail":"ticket t-002","data":{"ticket":"t-002","wave":1}}
{"ts":1025,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_green","detail":"ticket t-002 green","data":{"ticket":"t-002","attempts":1}}
{"ts":1026,"mission":"lcars-20260601-002","stage":"implement","type":"wave_start","detail":"wave 2 starting","data":{"wave":2,"ticketCount":2,"totalWaves":3}}
{"ts":1027,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_start","detail":"ticket t-003","data":{"ticket":"t-003","wave":2}}
{"ts":1030,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_start","detail":"ticket t-004","data":{"ticket":"t-004","wave":2}}
{"ts":1031,"mission":"lcars-20260601-002","stage":"implement","type":"ticket_attempt","detail":"implementer try 1 for t-004","data":{"ticket":"t-004","phase":"implementer","attempt":1}}'
write_waves "$repoW2" "lcars-20260601-002" "$WAVES_3"
( cd "$repoW2" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-002 >out.txt 2>&1 )
PROG2="$(grep -i 'avg/ticket' "$repoW2/out.txt" | tail -1)"
check "W2. progress line shows Wave 2/3"          "printf '%s' '$PROG2' | grep -qF 'Wave 2/3'"
check "W2. progress line names current ticket t-004" "printf '%s' '$PROG2' | grep -q 't-004'"
check "W2. progress line shows 2 of 6 green"        "printf '%s' '$PROG2' | grep -qF '2/6'"

# --- Behaviour W3: avg/ticket math + em dash before any green ----------------
# In W2's stream: t-001 took 1010-1002=8s, t-002 took 1025-1011=14s → avg 11s.
check "W3. avg/ticket is the mean of completed durations (~11s)" \
  "printf '%s' '$PROG2' | grep -qE '~11s avg/ticket'"
# A stream with NO ticket_green yet must show the em dash, not a number.
repoW3="$(new_init_repo)"
write_mission "$repoW3" "lcars-20260601-003" "implement" "23" \
  "2026-06-01T10:00:00Z" "No green yet"
write_events "$repoW3" "lcars-20260601-003" \
'{"ts":1000,"mission":"lcars-20260601-003","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":3}}
{"ts":1001,"mission":"lcars-20260601-003","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}'
write_waves "$repoW3" "lcars-20260601-003" "$WAVES_3"
( cd "$repoW3" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-003 >out.txt 2>&1 )
PROG3="$(grep -i 'avg/ticket' "$repoW3/out.txt" | tail -1)"
check "W3. shows the em dash for avg before any ticket is green" \
  "printf '%s' '$PROG3' | grep -qF '—s avg/ticket' || printf '%s' '$PROG3' | grep -qF '— avg/ticket'"
check "W3. no spurious avg number before any green" \
  "! printf '%s' '$PROG3' | grep -qE '~[0-9]+s avg/ticket'"

# --- Behaviour W4: elapsed from first-event ts, $LCARS_NOW pinned ------------
# first event ts=1000; LCARS_NOW=1100 → 100s elapsed → 1m40s.
check "W4. elapsed computed from first-event ts with LCARS_NOW pinned" \
  "printf '%s' '$PROG2' | grep -qE 'elapsed .*1m40s'"

# --- Behaviour W5: a terminal gate ends the watch with a final snapshot ------
# Last line is a verify gate; --once renders it AND prints a final progress line.
repoW5="$(new_init_repo)"
write_mission "$repoW5" "lcars-20260601-005" "verify" "25" \
  "2026-06-01T10:00:00Z" "Terminal gate"
write_events "$repoW5" "lcars-20260601-005" \
'{"ts":1000,"mission":"lcars-20260601-005","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":1,"totalWaves":1}}
{"ts":1001,"mission":"lcars-20260601-005","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}
{"ts":1009,"mission":"lcars-20260601-005","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","attempts":1}}
{"ts":1010,"mission":"lcars-20260601-005","stage":"verify","type":"gate","detail":"human review required"}'
write_waves "$repoW5" "lcars-20260601-005" \
'[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 } ] } ]'
( cd "$repoW5" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-005 >out.txt 2>&1 )
check "W5. renders the terminal gate line" \
  "grep -qF 'human review required' '$repoW5/out.txt'"
check "W5. prints a final progress snapshot after the gate" \
  "grep -qi 'avg/ticket' '$repoW5/out.txt'"
check "W5. final snapshot reflects the single completed wave (1/1, 1/1)" \
  "grep -i 'avg/ticket' '$repoW5/out.txt' | grep -qF 'Wave 1/1' && grep -i 'avg/ticket' '$repoW5/out.txt' | grep -qF '1/1'"
# --once must exit 0 cleanly on a terminal stream.
( cd "$repoW5" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-005 >/dev/null 2>&1 )
check "W5. --once exits 0 on a terminal stream" "[ $? -eq 0 ]"

# --- Behaviour W6: --watch resolves the active mission via the shared resolver -
# Exactly one active mission → no prompt, the resolver returns it. We exercise
# the REAL resolve.sh against a temp repo (true integration). Use --once so the
# test is deterministic, but force resolution by passing NO id.
repoW6="$(new_init_repo)"
write_mission "$repoW6" "lcars-20260601-006" "implement" "26" \
  "2026-06-01T10:00:00Z" "Sole active mission"
write_events "$repoW6" "lcars-20260601-006" \
'{"ts":1000,"mission":"lcars-20260601-006","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":1,"totalWaves":1}}
{"ts":1001,"mission":"lcars-20260601-006","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}
{"ts":1009,"mission":"lcars-20260601-006","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","attempts":1}}'
write_waves "$repoW6" "lcars-20260601-006" \
'[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 } ] } ]'
( cd "$repoW6" && LCARS_NOW=1100 LCARS_RESOLVE_SCRIPT="$RESOLVE" bash "$SCRIPT" --once >out.txt 2>&1 )
check "W6. --once with no id resolves the sole active mission" \
  "grep -q 'ticket t-001' '$repoW6/out.txt' && grep -qi 'avg/ticket' '$repoW6/out.txt'"
# An explicit partial id is honoured by the resolver.
( cd "$repoW6" && LCARS_NOW=1100 LCARS_RESOLVE_SCRIPT="$RESOLVE" bash "$SCRIPT" --once 006 >out2.txt 2>&1 )
check "W6. an explicit partial id is honoured" \
  "grep -qi 'avg/ticket' '$repoW6/out2.txt'"

# ==========================================================================
# DEFECT #2 (Session 27): the live watch's waves.json totals must be re-read
# every frame, not captured once before the follow loop. Before the fix the
# denominator (ticket total N / wave total) froze at startup, so a watch begun
# BEFORE Schedule wrote waves.json stayed stuck at `(0/?)` forever even after
# waves.json appeared. The deterministic guard is at the compute level:
#   (a) with NO waves.json, the denominator falls back to the events-derived
#       ticketCount sum (best-effort), NOT a bare `?`.
#   (b) once waves.json IS present it wins (its counts override the events).
# Both run through --once, which shares compute_progress with --watch.
echo
echo "lcars status --watch totals freshness (DEFECT #2)"

# (a) No waves.json yet — wave_start events carry totalWaves + ticketCount.
# Two distinct waves with ticketCount 2 + 1 → events-derived total tickets = 3,
# total waves = 2. The denominator must be 3 (not `?`), and the wave total 2.
repoW7="$(new_init_repo)"
write_mission "$repoW7" "lcars-20260601-007" "implement" "27" \
  "2026-06-01T10:00:00Z" "No waves.json yet"
write_events "$repoW7" "lcars-20260601-007" \
'{"ts":1000,"mission":"lcars-20260601-007","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":2}}
{"ts":1001,"mission":"lcars-20260601-007","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}
{"ts":1009,"mission":"lcars-20260601-007","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","attempts":1}}
{"ts":1010,"mission":"lcars-20260601-007","stage":"implement","type":"ticket_start","detail":"ticket t-002","data":{"ticket":"t-002","wave":1}}
{"ts":1018,"mission":"lcars-20260601-007","stage":"implement","type":"ticket_green","detail":"ticket t-002 green","data":{"ticket":"t-002","attempts":1}}
{"ts":1019,"mission":"lcars-20260601-007","stage":"implement","type":"wave_start","detail":"wave 2 starting","data":{"wave":2,"ticketCount":1,"totalWaves":2}}
{"ts":1020,"mission":"lcars-20260601-007","stage":"implement","type":"ticket_start","detail":"ticket t-003","data":{"ticket":"t-003","wave":2}}'
# NB: deliberately NO write_waves — waves.json is absent.
( cd "$repoW7" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-007 >out.txt 2>&1 )
PROG7="$(grep -i 'avg/ticket' "$repoW7/out.txt" | tail -1)"
check "D2(a). ticket total falls back to events ticketCount sum (2/3), not ?" \
  "printf '%s' '$PROG7' | grep -qF '2/3'"
check "D2(a). wave total falls back to events totalWaves (Wave 2/2), not ?" \
  "printf '%s' '$PROG7' | grep -qF 'Wave 2/2'"
check "D2(a). denominator is never a bare ? once events carry totals" \
  "! printf '%s' '$PROG7' | grep -qE '/\\?'"

# (b) Same stream, but now waves.json IS present and disagrees with the events
# (it lists 5 tickets across 2 waves). waves.json must win: the denominator is
# its count (5), not the events-derived 3 — proving compute reads it FRESH.
repoW8="$(new_init_repo)"
write_mission "$repoW8" "lcars-20260601-008" "implement" "28" \
  "2026-06-01T10:00:00Z" "waves.json wins"
write_events "$repoW8" "lcars-20260601-008" \
'{"ts":1000,"mission":"lcars-20260601-008","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":2}}
{"ts":1001,"mission":"lcars-20260601-008","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}'
write_waves "$repoW8" "lcars-20260601-008" \
'[
  { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 }, { "id": "t-002", "issue": 12 }, { "id": "t-003", "issue": 13 } ] },
  { "wave": 2, "tickets": [ { "id": "t-004", "issue": 14 }, { "id": "t-005", "issue": 15 } ] }
]'
( cd "$repoW8" && LCARS_NOW=1100 bash "$SCRIPT" --once lcars-20260601-008 >out.txt 2>&1 )
PROG8="$(grep -i 'avg/ticket' "$repoW8/out.txt" | tail -1)"
check "D2(b). waves.json ticket total wins over events (0/5)" \
  "printf '%s' '$PROG8' | grep -qF '0/5'"
check "D2(b). waves.json wave total wins (Wave 1/2)" \
  "printf '%s' '$PROG8' | grep -qF 'Wave 1/2'"
check "D2(b). events-derived count (3) does NOT leak through when waves.json present" \
  "! printf '%s' '$PROG8' | grep -qF '/3'"

# (c) Live-watch freshness: start --watch with NO waves.json, write it after a
# beat, assert a later frame shows the real totals (not the stale `?`/events
# count). Bounded + always-cleaned-up so it stays non-flaky; LCARS_NOW pins time.
repoW9="$(new_init_repo)"
write_mission "$repoW9" "lcars-20260601-009" "implement" "29" \
  "2026-06-01T10:00:00Z" "Live waves.json appears"
write_events "$repoW9" "lcars-20260601-009" \
'{"ts":1000,"mission":"lcars-20260601-009","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":1,"totalWaves":1}}
{"ts":1001,"mission":"lcars-20260601-009","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}'
WATCHLOG9="$repoW9/watch.log"
(
  cd "$repoW9" && LCARS_NOW=1100 LCARS_RESOLVE_SCRIPT="$RESOLVE" \
    bash "$SCRIPT" --watch lcars-20260601-009 </dev/null >"$WATCHLOG9" 2>&1 &
  echo $! >"$repoW9/watch.pid"
)
wpid9="$(cat "$repoW9/watch.pid")"
sleep 2
# waves.json appears mid-watch, listing 4 tickets across 1 wave.
write_waves "$repoW9" "lcars-20260601-009" \
'[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 }, { "id": "t-002", "issue": 12 }, { "id": "t-003", "issue": 13 }, { "id": "t-004", "issue": 14 } ] } ]'
sleep 2
# Tear down with SIGTERM (the reliable signal for an `&`-backgrounded process;
# SIGINT is inherited-ignored — see DEFECT #1 note below) so no orphan leaks.
kill -TERM "$wpid9" 2>/dev/null
wait "$wpid9" 2>/dev/null
kill -KILL "$wpid9" 2>/dev/null || true
check "D2(c). a waves.json that appears mid-watch is picked up (0/4)" \
  "grep -qF '0/4' '$WATCHLOG9'"

# ==========================================================================
# DEFECT #1 (Session 27): a no-TTY / backgrounded --watch must NOT busy-spin and
# must honour SIGINT. With stdin redirected from /dev/null, `read -t 1` used to
# return immediately at EOF → thousands of frames in seconds. The fix sleeps 1s
# per tick when stdin isn't a terminal, and the trap sets a stop flag the loop
# checks so SIGINT terminates a backgrounded watch. We drive a NON-terminal
# stream (no gate → it would loop forever) with stdin </dev/null, let it run
# ~2s, then SIGINT it. Assert: (a) the output is small (single-digit frames),
# proving the ~1s throttle; (b) the process is gone (SIGINT honoured).
echo
echo "lcars status --watch no-TTY throttle + signal teardown (DEFECT #1)"

repoW10="$(new_init_repo)"
write_mission "$repoW10" "lcars-20260601-010" "implement" "30" \
  "2026-06-01T10:00:00Z" "No-TTY throttle"
# Non-terminal stream: a wave + ticket_start, NO gate/error → watch keeps looping.
write_events "$repoW10" "lcars-20260601-010" \
'{"ts":1000,"mission":"lcars-20260601-010","stage":"implement","type":"wave_start","detail":"wave 1 starting","data":{"wave":1,"ticketCount":2,"totalWaves":1}}
{"ts":1001,"mission":"lcars-20260601-010","stage":"implement","type":"ticket_start","detail":"ticket t-001","data":{"ticket":"t-001","wave":1}}'
write_waves "$repoW10" "lcars-20260601-010" \
'[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 11 }, { "id": "t-002", "issue": 12 } ] } ]'
WATCHLOG="$repoW10/watch.log"
(
  cd "$repoW10" && LCARS_NOW=1100 LCARS_RESOLVE_SCRIPT="$RESOLVE" \
    bash "$SCRIPT" --watch lcars-20260601-010 </dev/null >"$WATCHLOG" 2>&1 &
  echo $! >"$repoW10/watch.pid"
)
wpid="$(cat "$repoW10/watch.pid")"
sleep 2
# Count the per-frame header lines: one per render. A 1s throttle over ~2s gives
# a handful (≤6, generous for scheduling jitter); a busy-spin gives thousands.
# This is the CORE regression for DEFECT #1 (no-busy-spin).
frames="$(grep -c 'watching lcars-20260601-010' "$WATCHLOG" 2>/dev/null || echo 0)"
check "D1. no-TTY watch throttles to ~1 frame/sec (not a busy-spin)" \
  "[ '$frames' -ge 1 ] && [ '$frames' -le 6 ]"
# Termination: assert with SIGTERM, the reliable signal for a backgrounded
# process. NOTE: a script started with `&` inherits SIGINT as IGNORED (standard
# shell job-control — so Ctrl-C in the launching terminal doesn't kill bg jobs),
# and bash can't re-trap an inherited-ignored SIGINT. So SIGINT can't be asserted
# against an `&`-backgrounded watch here; in a REAL foreground terminal SIGINT is
# NOT ignored and the trap fires (Ctrl-C works — confirmed manually). The trap
# also handles TERM, which we CAN assert: a hung/busy-spinning watch wouldn't
# honour it promptly.
kill -TERM "$wpid" 2>/dev/null
sleep 1
check "D1. SIGTERM terminates the backgrounded no-TTY watch (no orphan)" \
  "! kill -0 '$wpid' 2>/dev/null"
kill -KILL "$wpid" 2>/dev/null || true   # belt-and-braces cleanup

# ==========================================================================
echo
printf 'lcars status: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
