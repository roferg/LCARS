#!/usr/bin/env bash
#
# Tests for `lcars answer` — the inbox (skill source: skills/lcars-answer/answer.sh).
#
# `lcars answer` is the single inbox of every pending decision across ALL
# missions. It adds NO stage logic — it lists the union and delegates each
# action to a script already built:
#   • an escalation (awaiting-human) → respond.sh   (records the answer, clears
#                                                     the gate)
#   • a Verify card "ship it"        → approve.sh    (open the PR, mark Done)
#   • a Verify card "send back"      → feedback.sh   (back to Align with a note)
#
# Behaviours under test (from the build order):
#   4. `lcars answer` lists pending decisions across ALL missions (the union)
#   5. a Verify card offers approve / send-back, delegating to approve/feedback
#   6. an escalation records the answer via respond.sh and clears the gate
#
# Dependencies are stubbable via env, as the other skills do:
#   LCARS_RESPOND_SCRIPT   the respond.sh delegate
#   LCARS_APPROVE_SCRIPT   the approve.sh delegate
#   LCARS_FEEDBACK_SCRIPT  the feedback.sh delegate
#   LCARS_GH_BIN           the gh binary (for the real respond.sh)
#
# Usage: bash tests/lcars-answer.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSWER="${LCARS_ANSWER_SCRIPT:-$REPO_ROOT/skills/lcars-answer/answer.sh}"
RESPOND_REAL="${LCARS_RESPOND_SCRIPT:-$REPO_ROOT/skills/lcars-respond/respond.sh}"

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

mk_logging_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$0.log"
exit 0
EOF
  chmod +x "$1"
}

make_gh_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

state_of()   { echo "$1/.git/lcars/missions/$2/state.json"; }
answers_of() { echo "$1/.git/lcars/missions/$2/answers.json"; }

# A Mission parked behind the awaiting-human gate (escalation) at Validate.
add_escalation() { # repo id title
  local m="$1/.git/lcars/missions/$2"; mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$2",
  "type": "feature",
  "title": "$3",
  "stage": "validate",
  "created": "2026-05-30T10:00:00Z",
  "githubIssue": 42,
  "awaitingHuman": true,
  "pendingQuestion": "Global or per-course leaderboard?"
}
EOF
  cat >"$m/pending.json" <<'EOF'
{
  "stage": "validate",
  "questions": [
    "Global or per-course leaderboard?",
    "Should XP decay when a learner is inactive?"
  ]
}
EOF
}

# A Mission parked at the Verify gate (ship or send back).
add_verify() { # repo id title
  local m="$1/.git/lcars/missions/$2"; mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$2",
  "type": "feature",
  "title": "$3",
  "stage": "verify",
  "created": "2026-05-31T10:00:00Z",
  "githubIssue": 43
}
EOF
}

# A quiet, in-flight Mission that needs nothing from the human.
add_quiet() { # repo id title stage
  local m="$1/.git/lcars/missions/$2"; mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$2",
  "type": "feature",
  "title": "$3",
  "stage": "$4",
  "created": "2026-05-29T10:00:00Z",
  "githubIssue": 44
}
EOF
}

# ==========================================================================
echo "lcars answer"

[ -f "$ANSWER" ] || { echo "script under test not found at $ANSWER"; exit 1; }

# --- Behaviour 4: list the union of pending decisions across ALL missions ----
repo4="$(new_repo)"
add_escalation "$repo4" "lcars-20260530-001" "Add gamification"
add_verify     "$repo4" "lcars-20260531-002" "Dark mode"
add_quiet      "$repo4" "lcars-20260529-003" "Refactor" "plan"
rc4=0
( cd "$repo4" && bash "$ANSWER" list >out.txt 2>&1 ) || rc4=$?
check "4. answer list exits 0"                   "[ '$rc4' -eq 0 ]"
check "4. includes the escalation mission"       "grep -q 'lcars-20260530-001' '$repo4/out.txt'"
check "4. surfaces the escalation's question"    "grep -qi 'per-course leaderboard' '$repo4/out.txt'"
check "4. surfaces every escalation question"    "grep -qi 'XP decay' '$repo4/out.txt'"
check "4. includes the Verify-gate mission"      "grep -q 'lcars-20260531-002' '$repo4/out.txt'"
check "4. omits the quiet in-flight mission"     "! grep -q 'lcars-20260529-003' '$repo4/out.txt'"

# bare `lcars answer` (no subcommand) defaults to list
rc4b=0
( cd "$repo4" && bash "$ANSWER" >outb.txt 2>&1 ) || rc4b=$?
check "4. bare 'answer' defaults to the list"    \
  "[ '$rc4b' -eq 0 ] && grep -q 'lcars-20260530-001' '$repo4/outb.txt'"

# empty inbox says so
repo4c="$(new_repo)"
add_quiet "$repo4c" "lcars-20260529-009" "Quiet" "implement"
rc4c=0
( cd "$repo4c" && bash "$ANSWER" list >out.txt 2>&1 ) || rc4c=$?
check "4. empty inbox exits 0 and says nothing is pending" \
  "[ '$rc4c' -eq 0 ] && grep -qi 'no.*pending\\|nothing.*pending\\|nothing.*waiting\\|all clear\\|inbox.*empty' '$repo4c/out.txt'"

# --- Behaviour 5: a Verify card offers approve / send-back -------------------
repo5="$(new_repo)"
add_verify "$repo5" "lcars-20260531-002" "Dark mode"
# the list spells out both actions on the verify card
( cd "$repo5" && bash "$ANSWER" list >out.txt 2>&1 )
check "5. the Verify card offers 'approve'"      "grep -qi 'approve' '$repo5/out.txt'"
check "5. the Verify card offers 'send back'"    "grep -qi 'send.back\\|feedback' '$repo5/out.txt'"

# approve delegates to approve.sh
APP_STUB="$repo5/approve-stub.sh"; mk_logging_stub "$APP_STUB"; : >"$APP_STUB.log"
rc5a=0
( cd "$repo5" && LCARS_APPROVE_SCRIPT="$APP_STUB" \
    bash "$ANSWER" approve --mission "lcars-20260531-002" >outa.txt 2>&1 ) || rc5a=$?
check "5. approve exits 0"                        "[ '$rc5a' -eq 0 ]"
check "5. approve delegates to approve.sh for that mission" \
  "grep -q 'mission lcars-20260531-002' '$APP_STUB.log'"

# send-back delegates to feedback.sh, carrying the note
FB_STUB="$repo5/feedback-stub.sh"; mk_logging_stub "$FB_STUB"; : >"$FB_STUB.log"
rc5b=0
( cd "$repo5" && LCARS_FEEDBACK_SCRIPT="$FB_STUB" \
    bash "$ANSWER" send-back --mission "lcars-20260531-002" --feedback "Spacing is off" \
    >outb.txt 2>&1 ) || rc5b=$?
check "5. send-back exits 0"                      "[ '$rc5b' -eq 0 ]"
check "5. send-back delegates to feedback.sh for that mission" \
  "grep -q 'mission lcars-20260531-002' '$FB_STUB.log'"
check "5. send-back forwards the captain's note"  \
  "grep -q 'Spacing is off' '$FB_STUB.log'"

# --- Behaviour 6: an escalation records the answer via respond.sh ------------
# Use the REAL respond.sh so we can assert the gate actually clears.
repo6="$(new_repo)"
add_escalation "$repo6" "lcars-20260530-001" "Add gamification"
make_gh_stub "$repo6/gh"; export GH_LOG="$repo6/gh.log"; : >"$GH_LOG"
rc6=0
( cd "$repo6" && LCARS_RESPOND_SCRIPT="$RESPOND_REAL" LCARS_GH_BIN="$repo6/gh" \
    bash "$ANSWER" respond --mission "lcars-20260530-001" \
      --answer "Per-course for now; XP does not decay." >out.txt 2>&1 ) || rc6=$?
s6="$(state_of "$repo6" "lcars-20260530-001")"
a6="$(answers_of "$repo6" "lcars-20260530-001")"
check "6. respond exits 0"                        "[ '$rc6' -eq 0 ]"
check "6. records the answer (answers.json written)" "[ -f '$a6' ]"
check "6. answers.json carries the captain's answer" \
  "grep -q 'Per-course for now' '$a6'"
check "6. clears the awaiting-human gate in state.json" \
  "! grep -q '\"awaitingHuman\": *true' '$s6'"
check "6. removes the lcars:awaiting-human label via gh" \
  "grep -q 'remove-label lcars:awaiting-human' '$repo6/gh.log'"

# resolver convenience: with exactly one escalation, no --mission is needed
repo6b="$(new_repo)"
add_escalation "$repo6b" "lcars-20260530-007" "Solo escalation"
make_gh_stub "$repo6b/gh"; export GH_LOG="$repo6b/gh.log"; : >"$GH_LOG"
rc6b=0
( cd "$repo6b" && LCARS_RESPOND_SCRIPT="$RESPOND_REAL" LCARS_GH_BIN="$repo6b/gh" \
    bash "$ANSWER" respond --answer "Go with option A." >out.txt 2>&1 ) || rc6b=$?
a6b="$(answers_of "$repo6b" "lcars-20260530-007")"
check "6. with one escalation, respond needs no mission id" \
  "[ '$rc6b' -eq 0 ] && [ -f '$a6b' ]"

# ==========================================================================
echo
printf 'lcars answer: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
