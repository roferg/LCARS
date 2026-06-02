#!/usr/bin/env bash
#
# Tests for `lcars respond` — the async human gate (skill source:
# skills/lcars-respond/respond.sh).
#
# When a stage escalates (Research >20, Validate scope change, Plan Review's
# 3-round limit, Implement's 5-attempt cap) it parks the Mission behind an
# awaiting-human gate: awaitingHuman=true in state.json, the question(s) in
# pending.json, and the lcars:awaiting-human label on the issue. `lcars respond`
# is how the captain answers that gate, walk-away style — it surfaces the
# pending question, records the answer next to it, and clears the gate so a
# plain `lcars run <id>` resumes the SAME stage and consumes the answer.
#
# The mechanical half lives in respond.sh, split into three subcommands:
#   list                       — every awaiting-human mission + its questions
#   show   --mission <id>      — that mission's pending question(s)
#   answer --mission <id> --answer "<text>"
#                              — persist the answer, clear the gate, drop label
#
# Behaviours under test (from the build order), in order:
#   1. `lcars respond` (no id) lists all awaiting-human missions + questions
#   2. `lcars respond <id>` displays that mission's pending question(s)
#   3. captures + persists the human's answer next to the question
#   4. clears awaitingHuman in state.json (stage UNCHANGED)
#   5. removes lcars:awaiting-human via gh, tolerant when it isn't applied
#   7. after respond, `lcars run <id>` consumes the answer and does not re-ask
#
# (Behaviour 6 — the in-flight stage label on escalation — is owned by run.sh
# and lives in tests/lcars-run.test.sh.)
#
# Dependencies are taken via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary (default: gh)
#   LCARS_NOW      - ISO stamp for the answer (default: now, UTC)
#
# Usage: bash tests/lcars-respond.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RESPOND_SCRIPT:-$REPO_ROOT/skills/lcars-respond/respond.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }
pending_of() { echo "$1/.git/lcars/missions/$MID/pending.json"; }
answers_of() { echo "$1/.git/lcars/missions/$MID/answers.json"; }

# A fake `gh` that records every call to $GH_LOG and otherwise succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# A fake `gh` that records calls but FAILS any issue edit — stands in for
# removing a label that isn't applied / a flaky gh. `lcars respond` must still
# succeed locally (tolerant).
make_gh_stub_failing() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$*" in
  *"issue edit"*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated git repo with a Mission paused behind the awaiting-human
# gate at the Validate stage: state.json carries awaitingHuman/pendingQuestion,
# pending.json holds two scope questions, issue #42.
new_repo_with_paused_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "validate",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
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
  echo "$repo"
}

# Add a SECOND, non-paused mission to a repo so `respond list` has to filter.
add_quiet_mission() { # repo
  local m="$1/.git/lcars/missions/lcars-20260530-002"
  mkdir -p "$m"
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-002",
  "type": "bug",
  "title": "Fix the /about route",
  "stage": "plan",
  "created": "2026-05-30T11:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 43
}
EOF
}

# The Validator's synthesis, needed to drive the resume (validate-advance).
write_plan() { # file
  cat >"$1" <<'EOF'
# Validated Plan: Add gamification

## Synthesis
Per-course leaderboards, XP that does not decay — per the captain's answer.

## Decisions
- One leaderboard table keyed by course.
EOF
}

# ==========================================================================
echo "lcars respond"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: `respond` (no id) lists awaiting-human missions + questions
repo1="$(new_repo_with_paused_mission)"; make_gh_stub "$repo1/gh"
add_quiet_mission "$repo1"
export GH_LOG="$repo1/gh.log"; : >"$GH_LOG"
rc1=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" bash "$SCRIPT" list >out.txt 2>&1 ) || rc1=$?
check "1. respond list exits 0" "[ '$rc1' -eq 0 ]"
check "1. names the awaiting-human mission" \
  "grep -q '$MID' '$repo1/out.txt'"
check "1. surfaces the mission's pending question" \
  "grep -q 'per-course leaderboard' '$repo1/out.txt'"
check "1. surfaces every pending question, not just the first" \
  "grep -q 'XP decay' '$repo1/out.txt'"
check "1. omits the mission that is not awaiting a human" \
  "! grep -q 'lcars-20260530-002' '$repo1/out.txt'"

# empty state: no mission is awaiting a human → say so, exit 0
repo1b="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$repo1b" && git init -q && git config user.email t@t && git config user.name t )
add_quiet_mission "$repo1b"
rc1b=0
( cd "$repo1b" && bash "$SCRIPT" list >out.txt 2>&1 ) || rc1b=$?
check "1. empty state exits 0" "[ '$rc1b' -eq 0 ]"
check "1. empty state says nothing is awaiting" \
  "grep -qi 'no.*awaiting\\|nothing.*awaiting\\|no missions' '$repo1b/out.txt'"

# --- Behaviour 2: `respond <id>` displays the pending question(s) -----------
repo2="$(new_repo_with_paused_mission)"; make_gh_stub "$repo2/gh"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"
rc2=0
( cd "$repo2" && LCARS_GH_BIN="$repo2/gh" bash "$SCRIPT" show --mission "$MID" >out.txt 2>&1 ) || rc2=$?
check "2. respond show exits 0" "[ '$rc2' -eq 0 ]"
check "2. shows the first pending question" \
  "grep -q 'per-course leaderboard' '$repo2/out.txt'"
check "2. shows the second pending question" \
  "grep -q 'XP decay' '$repo2/out.txt'"

# --- Behaviours 3/4/5: answer persists, clears the gate, drops the label ----
repo3="$(new_repo_with_paused_mission)"; make_gh_stub "$repo3/gh"
export GH_LOG="$repo3/gh.log"; : >"$GH_LOG"
ANS="Per-course for now; XP does not decay."
rc3=0
( cd "$repo3" && LCARS_GH_BIN="$repo3/gh" LCARS_NOW="2026-06-02T12:00:00Z" \
    bash "$SCRIPT" answer --mission "$MID" --answer "$ANS" >out.txt 2>&1 ) || rc3=$?
s3="$(state_of "$repo3")"; a3="$(answers_of "$repo3")"
check "3. answer exits 0" "[ '$rc3' -eq 0 ]"
# 3. captures + persists the answer next to the question
check "3. writes answers.json"                 "[ -f '$a3' ]"
check "3. answers.json carries the captain's answer" \
  "grep -q 'Per-course for now' '$a3'"
check "3. answers.json keeps the question next to the answer" \
  "grep -q 'per-course leaderboard' '$a3'"
# 4. clears awaitingHuman, stage UNCHANGED
check "4. clears awaitingHuman in state.json" \
  "! grep -q '\"awaitingHuman\": *true' '$s3'"
check "4. clears pendingQuestion so the board stops flagging it" \
  "! grep -q '\"pendingQuestion\"' '$s3'"
check "4. leaves the stage UNCHANGED (still validate)" \
  "grep -q '\"stage\": *\"validate\"' '$s3'"
# 5. removes lcars:awaiting-human via gh
check "5. removes the lcars:awaiting-human label via gh" \
  "grep -q 'remove-label lcars:awaiting-human' '$repo3/gh.log'"
check "5. tells the captain lcars run resumes the stage" \
  "grep -qi 'lcars run' '$repo3/out.txt' && grep -qi 'validate' '$repo3/out.txt'"

# 5 (tolerant): a gh that fails the edit must NOT fail respond or leave the gate
repo5="$(new_repo_with_paused_mission)"; make_gh_stub_failing "$repo5/gh"
export GH_LOG="$repo5/gh.log"; : >"$GH_LOG"
rc5=0
( cd "$repo5" && LCARS_GH_BIN="$repo5/gh" bash "$SCRIPT" answer \
    --mission "$MID" --answer "Per-course." >out.txt 2>&1 ) || rc5=$?
check "5. tolerant: respond still exits 0 when gh edit fails" "[ '$rc5' -eq 0 ]"
check "5. tolerant: the gate is still cleared locally" \
  "! grep -q '\"awaitingHuman\": *true' '$(state_of "$repo5")'"
check "5. tolerant: still wrote answers.json" "[ -f '$(answers_of "$repo5")' ]"
check "5. tolerant: did attempt the remove-label" \
  "grep -q 'remove-label lcars:awaiting-human' '$repo5/gh.log'"

# --- Behaviour 7: after respond, `lcars run` consumes the answer (no re-ask) -
# The resume is validate-advance (run.sh): it writes the plan and advances. It
# must consume the gate artifacts — pending.json AND the answer — so the stage
# does not re-ask, and clear awaitingHuman as it advances to Plan.
repo7="$(new_repo_with_paused_mission)"; make_gh_stub "$repo7/gh"
export GH_LOG="$repo7/gh.log"; : >"$GH_LOG"
( cd "$repo7" && LCARS_GH_BIN="$repo7/gh" bash "$SCRIPT" answer \
    --mission "$MID" --answer "Per-course." >outA.txt 2>&1 )
check "7. answer left answers.json for the resuming stage" \
  "[ -f '$(answers_of "$repo7")' ]"
write_plan "$repo7/plan.md"
: >"$repo7/gh.log"
rc7=0
( cd "$repo7" && LCARS_GH_BIN="$repo7/gh" bash "$RUN_SCRIPT" validate-advance \
    --mission "$MID" --plan "$repo7/plan.md" >out7.txt 2>&1 ) || rc7=$?
check "7. lcars run resumes (validate-advance exits 0)" "[ '$rc7' -eq 0 ]"
check "7. resume advanced to plan"  "grep -q '\"stage\": *\"plan\"' '$(state_of "$repo7")'"
check "7. resume consumed pending.json" "[ ! -f '$(pending_of "$repo7")' ]"
check "7. resume consumed answers.json (no re-ask)" "[ ! -f '$(answers_of "$repo7")' ]"

# --- Guards -----------------------------------------------------------------
# answering an unknown mission is rejected
repoG="$(new_repo_with_paused_mission)"; make_gh_stub "$repoG/gh"
export GH_LOG="$repoG/gh.log"; : >"$GH_LOG"
rcG=0
( cd "$repoG" && LCARS_GH_BIN="$repoG/gh" bash "$SCRIPT" answer \
    --mission "no-such" --answer "x" >out.txt 2>&1 ) || rcG=$?
check "guard. rejects an unknown mission id" "[ '$rcG' -ne 0 ]"

# answering a mission that is NOT awaiting a human is rejected (nothing to answer)
repoGq="$(new_repo_with_paused_mission)"; make_gh_stub "$repoGq/gh"
add_quiet_mission "$repoGq"
export GH_LOG="$repoGq/gh.log"; : >"$GH_LOG"
rcGq=0
( cd "$repoGq" && LCARS_GH_BIN="$repoGq/gh" bash "$SCRIPT" answer \
    --mission "lcars-20260530-002" --answer "x" >out.txt 2>&1 ) || rcGq=$?
check "guard. refuses a mission that is not awaiting a human" "[ '$rcGq' -ne 0 ]"

# an empty answer is rejected — an answer must say something
repoGe="$(new_repo_with_paused_mission)"; make_gh_stub "$repoGe/gh"
export GH_LOG="$repoGe/gh.log"; : >"$GH_LOG"
rcGe=0
( cd "$repoGe" && LCARS_GH_BIN="$repoGe/gh" bash "$SCRIPT" answer \
    --mission "$MID" --answer "" >out.txt 2>&1 ) || rcGe=$?
check "guard. rejects an empty answer" "[ '$rcGe' -ne 0 ]"
check "guard. leaves the gate intact on an empty answer" \
  "grep -q '\"awaitingHuman\": *true' '$(state_of "$repoGe")'"

# ==========================================================================
echo
printf 'lcars respond: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
