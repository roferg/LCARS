#!/usr/bin/env bash
#
# Tests for `lcars` — the one entry point (skill source: skills/lcars/lcars.sh)
# and the shared mission resolver (skills/lcars/resolve.sh).
#
# `lcars` adds NO stage logic. It is a dispatcher: it reads mission state,
# ANNOUNCES the action it inferred, then delegates to a script already built —
#   • no missions filed        → the `lcars file` flow (Claude runs it)
#   • a decision is pending     → the inbox (delegate to lcars-answer)
#   • work in flight, nothing
#     pending                   → drive the active mission (delegate to run.sh)
# A shared resolver picks the target mission: one candidate → no id needed;
# several → a picker; an explicit id / partial-id / title always works.
#
# Behaviours under test (from the build order):
#   1. bare `lcars` with no missions enters the file flow
#   2. bare `lcars` with one active mission, nothing pending → drives it
#      (delegates to run.sh drive)
#   3. bare `lcars` with a pending decision → opens the inbox
#   7. the resolver: one candidate → no id; several → picker; explicit id works
#   8. bare `lcars` announces the inferred action before acting
#
# Dependencies are stubbable via env, as the other skills do:
#   LCARS_RUN_SCRIPT      the run.sh delegate    (drive)
#   LCARS_ANSWER_SCRIPT   the answer.sh delegate (inbox)
#   LCARS_RESOLVE_SCRIPT  the shared resolver
#
# Usage: bash tests/lcars.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LCARS="${LCARS_SCRIPT:-$REPO_ROOT/skills/lcars/lcars.sh}"
RESOLVE="${LCARS_RESOLVE_BIN:-$REPO_ROOT/skills/lcars/resolve.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '%s' "$repo"
}

# Write a mission state.json. Args: repo id title stage [extra-json-lines]
mk_mission() {
  local repo="$1" id="$2" title="$3" stage="$4" extra="${5:-}"
  local m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m"
  {
    echo '{'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "%s",\n' "$title"
    printf '  "created": "2026-05-30T10:00:00Z",\n'
    printf '  "githubIssue": 42,\n'
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf '  "stage": "%s"\n' "$stage"
    echo '}'
  } >"$m/state.json"
}

# A stub script that records its argv to $1.log and exits 0.
mk_logging_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$0.log"
exit 0
EOF
  chmod +x "$1"
}

# ==========================================================================
echo "lcars (entry point)"

[ -f "$LCARS" ]   || { echo "script under test not found at $LCARS"; exit 1; }
[ -f "$RESOLVE" ] || { echo "resolver not found at $RESOLVE"; exit 1; }

# --- Behaviour 1 + 8: no missions → announce + enter the file flow ----------
repo1="$(new_repo)"
rc1=0
( cd "$repo1" && bash "$LCARS" >out.txt 2>&1 ) || rc1=$?
check "1. exits 0 with no missions"            "[ '$rc1' -eq 0 ]"
check "1. routes to the file flow"             "grep -qi 'ROUTE: file' '$repo1/out.txt'"
check "8. announces it is filing a new mission" \
  "grep -qi 'no missions' '$repo1/out.txt'"

# --- Behaviour 2 + 8: one active mission, nothing pending → drive it ---------
repo2="$(new_repo)"
mk_mission "$repo2" "lcars-20260530-001" "Add gamification" "research"
RUN_STUB="$repo2/run-stub.sh"; mk_logging_stub "$RUN_STUB"; : >"$RUN_STUB.log"
rc2=0
( cd "$repo2" && LCARS_RUN_SCRIPT="$RUN_STUB" bash "$LCARS" >out.txt 2>&1 ) || rc2=$?
check "2. exits 0 driving the one active mission" "[ '$rc2' -eq 0 ]"
check "2. delegates to run.sh drive for that mission" \
  "grep -q 'drive --mission lcars-20260530-001' '$RUN_STUB.log'"
check "8. announces it is driving the mission (before delegating)" \
  "grep -qi 'driv' '$repo2/out.txt'"
check "8. names the mission in the announcement" \
  "grep -q 'lcars-20260530-001' '$repo2/out.txt'"

# --- Behaviour 3 + 8: a pending decision → open the inbox -------------------
# A Mission parked at Verify is a pending decision (ship or send back).
repo3="$(new_repo)"
mk_mission "$repo3" "lcars-20260530-001" "Add gamification" "verify"
ANS_STUB="$repo3/answer-stub.sh"; mk_logging_stub "$ANS_STUB"; : >"$ANS_STUB.log"
rc3=0
( cd "$repo3" && LCARS_ANSWER_SCRIPT="$ANS_STUB" bash "$LCARS" >out.txt 2>&1 ) || rc3=$?
check "3. exits 0 when a decision is pending"  "[ '$rc3' -eq 0 ]"
check "3. delegates to the inbox (answer list)" \
  "grep -q 'list' '$ANS_STUB.log'"
check "8. announces it is opening the inbox"   \
  "grep -qi 'inbox\\|waiting\\|decision' '$repo3/out.txt'"

# An awaiting-human escalation is also a pending decision → inbox.
repo3b="$(new_repo)"
mk_mission "$repo3b" "lcars-20260530-002" "Fix route" "validate" \
'  "awaitingHuman": true,
  "pendingQuestion": "Global or per-course leaderboard?",'
ANS_STUB2="$repo3b/answer-stub.sh"; mk_logging_stub "$ANS_STUB2"; : >"$ANS_STUB2.log"
rc3b=0
( cd "$repo3b" && LCARS_ANSWER_SCRIPT="$ANS_STUB2" bash "$LCARS" >out.txt 2>&1 ) || rc3b=$?
check "3. an awaiting-human escalation also opens the inbox" \
  "[ '$rc3b' -eq 0 ] && grep -q 'list' '$ANS_STUB2.log'"

# Pending takes precedence over a drivable mission: even with another mission in
# flight, a pending decision sends you to the inbox first.
repo3c="$(new_repo)"
mk_mission "$repo3c" "lcars-20260530-010" "Drivable" "plan"
mk_mission "$repo3c" "lcars-20260530-011" "Needs me" "verify"
ANS_STUB3="$repo3c/answer-stub.sh"; mk_logging_stub "$ANS_STUB3"; : >"$ANS_STUB3.log"
RUN_STUB3="$repo3c/run-stub.sh"; mk_logging_stub "$RUN_STUB3"; : >"$RUN_STUB3.log"
( cd "$repo3c" && LCARS_ANSWER_SCRIPT="$ANS_STUB3" LCARS_RUN_SCRIPT="$RUN_STUB3" \
    bash "$LCARS" >out.txt 2>&1 )
check "3. pending decision wins over a drivable mission (inbox, not drive)" \
  "grep -q 'list' '$ANS_STUB3.log' && [ ! -s '$RUN_STUB3.log' ]"

# --- Behaviour 2 (ambiguous drive): several active, none pending → picker ----
repo2b="$(new_repo)"
mk_mission "$repo2b" "lcars-20260530-001" "Add gamification" "research"
mk_mission "$repo2b" "lcars-20260530-002" "Dark mode" "plan"
RUN_STUB2="$repo2b/run-stub.sh"; mk_logging_stub "$RUN_STUB2"; : >"$RUN_STUB2.log"
rc2b=0
( cd "$repo2b" && LCARS_RUN_SCRIPT="$RUN_STUB2" bash "$LCARS" >out.txt 2>&1 ) || rc2b=$?
check "2. several drivable missions → drops into the picker (does not auto-drive)" \
  "[ ! -s '$RUN_STUB2.log' ]"
check "2. picker lists every candidate mission" \
  "grep -q 'lcars-20260530-001' '$repo2b/out.txt' && grep -q 'lcars-20260530-002' '$repo2b/out.txt'"

# An explicit id with several missions resolves straight to it and drives.
RUN_STUB2c="$repo2b/run-stub-c.sh"; mk_logging_stub "$RUN_STUB2c"; : >"$RUN_STUB2c.log"
( cd "$repo2b" && LCARS_RUN_SCRIPT="$RUN_STUB2c" bash "$LCARS" "20260530-002" >outc.txt 2>&1 )
check "2. an explicit id still drives that mission with no picker" \
  "grep -q 'drive --mission lcars-20260530-002' '$RUN_STUB2c.log'"

# ==========================================================================
echo
echo "lcars resolver"

# --- Behaviour 7: the shared mission resolver -------------------------------
# one candidate → resolves with no id, exit 0, prints the id
repo7a="$(new_repo)"
mk_mission "$repo7a" "lcars-20260530-001" "Add gamification" "plan"
rc7a=0
( cd "$repo7a" && bash "$RESOLVE" --scope active >out.txt 2>&1 ) || rc7a=$?
check "7. one candidate resolves with no id (exit 0)" "[ '$rc7a' -eq 0 ]"
check "7. prints the resolved mission id" \
  "grep -q '^lcars-20260530-001$' '$repo7a/out.txt'"

# several candidates, no id → ambiguous (exit 2), lists candidates for the picker
repo7b="$(new_repo)"
mk_mission "$repo7b" "lcars-20260530-001" "Add gamification" "plan"
mk_mission "$repo7b" "lcars-20260530-002" "Dark mode" "research"
rc7b=0
( cd "$repo7b" && bash "$RESOLVE" --scope active >out.txt 2>&1 ) || rc7b=$?
check "7. several candidates → ambiguous picker (exit 2)" "[ '$rc7b' -eq 2 ]"
check "7. picker output names both candidates" \
  "grep -q 'lcars-20260530-001' '$repo7b/out.txt' && grep -q 'lcars-20260530-002' '$repo7b/out.txt'"
check "7. picker carries the title for the fuzzy choice" \
  "grep -qi 'dark mode' '$repo7b/out.txt'"

# explicit partial id disambiguates → exit 0, that id
rc7c=0
( cd "$repo7b" && bash "$RESOLVE" --scope active --id "002" >outc.txt 2>&1 ) || rc7c=$?
check "7. an explicit partial id resolves to exactly one (exit 0)" "[ '$rc7c' -eq 0 ]"
check "7. partial id resolves to the right mission" \
  "grep -q '^lcars-20260530-002$' '$repo7b/outc.txt'"

# a title substring resolves too
rc7d=0
( cd "$repo7b" && bash "$RESOLVE" --scope active --id "dark" >outd.txt 2>&1 ) || rc7d=$?
check "7. a title substring resolves to the right mission" \
  "[ '$rc7d' -eq 0 ] && grep -q '^lcars-20260530-002$' '$repo7b/outd.txt'"

# no match → exit 3
rc7e=0
( cd "$repo7b" && bash "$RESOLVE" --scope active --id "nope" >oute.txt 2>&1 ) || rc7e=$?
check "7. an unmatched selector is rejected (exit 3)" "[ '$rc7e' -eq 3 ]"

# scope pending only surfaces missions that need a human
repo7f="$(new_repo)"
mk_mission "$repo7f" "lcars-20260530-001" "Quiet plan" "plan"
mk_mission "$repo7f" "lcars-20260530-002" "Ready to ship" "verify"
rc7f=0
( cd "$repo7f" && bash "$RESOLVE" --scope pending >out.txt 2>&1 ) || rc7f=$?
check "7. scope pending resolves the single decision-needing mission" \
  "[ '$rc7f' -eq 0 ] && grep -q '^lcars-20260530-002$' '$repo7f/out.txt'"

# done missions are not candidates for active
repo7g="$(new_repo)"
mk_mission "$repo7g" "lcars-20260530-001" "Shipped" "done"
rc7g=0
( cd "$repo7g" && bash "$RESOLVE" --scope active >out.txt 2>&1 ) || rc7g=$?
check "7. a done mission is not an active candidate (exit 3)" "[ '$rc7g' -eq 3 ]"

# ==========================================================================
echo
echo "lcars — SKILL.md drive route relays progress in-session (session 42)"
#
# When the route is `drive`, the dispatcher's SKILL.md must instruct the same
# background-run + periodic `status.sh --once` relay as lcars-run, so the captain
# sees the Mission move without a second window. Doc-level guard only.
LCARS_SKILL="$REPO_ROOT/skills/lcars/SKILL.md"
check "8. drive route SKILL.md says to background-run the driver" \
  "grep -qiE 'background|detached' '$LCARS_SKILL' && grep -qE 'drive --mission <id>.*&|2>&1 &' '$LCARS_SKILL'"
check "8. drive route SKILL.md relays via status.sh --once" \
  "grep -qE 'status.sh --once' '$LCARS_SKILL'"
check "8. drive route SKILL.md honours the watch interval" \
  "grep -q 'LCARS_WATCH_INTERVAL' '$LCARS_SKILL'"
check "8. drive route SKILL.md keeps the isolation markers byte-for-byte" \
  "grep -qF '⊘ isolated' '$LCARS_SKILL' && grep -qiE 'byte-for-byte|byte-compatible' '$LCARS_SKILL'"

# ==========================================================================
echo
printf 'lcars: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
