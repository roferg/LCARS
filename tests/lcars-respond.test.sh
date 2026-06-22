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

## Rationale
A per-course key matches the captain's scope answer and avoids a global-board
schema we would have to migrate away from later.
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

# --- Behaviour 1 (in-flight stage): list shows the TRUE stage, not the pointer
# A Mission paused at the Research >20 gate keeps state.json.stage="align" (the
# resume pointer), but pending.json records stage="research" — the Stage the
# card is actually stuck in, matching the board label. `respond list` must show
# "research" so the CLI view agrees with the Kanban column.
repo1c="$(mktemp -d "$TMPROOT/repo.XXXX")"
( cd "$repo1c" && git init -q && git config user.email t@t && git config user.name t )
mR="$repo1c/.git/lcars/missions/lcars-20260530-009"; mkdir -p "$mR"
cat >"$mR/state.json" <<'EOF'
{
  "id": "lcars-20260530-009",
  "type": "feature",
  "title": "Gamification overhaul",
  "stage": "align",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 9,
  "awaitingHuman": true,
  "pendingQuestion": "Research needs 21 questions — override or return-to-align?"
}
EOF
cat >"$mR/pending.json" <<'EOF'
{
  "stage": "research",
  "questions": [
    "Research needs 21 questions — override or return-to-align?"
  ]
}
EOF
rc1c=0
( cd "$repo1c" && bash "$SCRIPT" list >out.txt 2>&1 ) || rc1c=$?
check "1. research-gate list exits 0" "[ '$rc1c' -eq 0 ]"
check "1. list shows the in-flight stage (research) from pending.json" \
  "grep -qi 'stage: *research' '$repo1c/out.txt'"
check "1. list does not show the stale resume-pointer stage (align)" \
  "! grep -qi 'stage: *align' '$repo1c/out.txt'"

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

# --- Behaviour 8: accepting a re-verify gate folds children to Done (BUG-E) --
# Model A: when the captain accepts the consolidated re-verify gate raised by
# `lcars resolve-logs` on a PARENT, respond must fold the parent's verified child
# bug Missions to Done WITHOUT a per-bug PR — by invoking `resolve-logs complete
# --parent <id>` after clearing the gate. We point respond at the REAL
# resolve-logs script via $LCARS_RESOLVE_LOGS_SCRIPT and build a parent parked at
# the consolidated gate with two children at Verify.
RESOLVE_LOGS_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh}"

new_repo_with_reverify_gate() { # -> repo path; parent MID with 2 verified kids
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "verify",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main",
  "awaitingHuman": true,
  "pendingQuestion": "2 logged bugs resolved and waiting on their Verify gates — ready for you to re-verify."
}
EOF
  cat >"$m/pending.json" <<'EOF'
{
  "stage": "verify",
  "questions": [
    "2 logged bugs resolved and waiting on their Verify gates — ready for you to re-verify."
  ]
}
EOF
  local seq d
  for seq in 002 003; do
    d="$repo/.git/lcars/missions/lcars-20260530-$seq"; mkdir -p "$d"
    cat >"$d/state.json" <<EOF
{
  "id": "lcars-20260530-$seq",
  "type": "bug",
  "title": "Logged bug $seq",
  "stage": "verify",
  "githubIssue": $((50 + 10#$seq)),
  "parentMission": "$MID",
  "parentIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main"
}
EOF
  done
  echo "$repo"
}

repo8="$(new_repo_with_reverify_gate)"; make_gh_stub "$repo8/gh"
export GH_LOG="$repo8/gh.log"; : >"$GH_LOG"
rc8=0
(
  cd "$repo8"
  LCARS_GH_BIN="$repo8/gh" LCARS_GIT_BIN="$(command -v git)" \
  LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_LOGS_SCRIPT" \
    bash "$SCRIPT" answer --mission "$MID" --answer "Looks good, ship it." >out8.txt 2>&1
) || rc8=$?
check "8. accepting the re-verify gate exits 0" "[ '$rc8' -eq 0 ]"
check "8. the parent's gate is cleared (awaitingHuman gone)" \
  "! grep -q '\"awaitingHuman\": *true' '$repo8/.git/lcars/missions/$MID/state.json'"
check "8. child 002 is folded to Done" \
  "grep -q '\"stage\": *\"done\"' '$repo8/.git/lcars/missions/lcars-20260530-002/state.json'"
check "8. child 003 is folded to Done" \
  "grep -q '\"stage\": *\"done\"' '$repo8/.git/lcars/missions/lcars-20260530-003/state.json'"
check "8. children are relabelled lcars:done" \
  "[ \"\$(grep -c 'add-label.*lcars:done' '$repo8/gh.log')\" -ge 2 ]"
check "8. NO per-bug PR is opened for any child" \
  "! grep -q 'pr create' '$repo8/gh.log'"
check "8. children's commits target the PARENT branch (folded onto parent)" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-001\"' '$repo8/.git/lcars/missions/lcars-20260530-002/state.json'"
check "8. no child is left orphaned at Verify after acceptance" \
  "! grep -q '\"stage\": *\"verify\"' '$repo8/.git/lcars/missions/lcars-20260530-002/state.json' && ! grep -q '\"stage\": *\"verify\"' '$repo8/.git/lcars/missions/lcars-20260530-003/state.json'"

# --- Behaviour 8b: a plain escalation answer does NOT fold anything ----------
# Answering an ordinary escalation (a Mission with no verified linked children)
# must be unaffected by the completion hook — it stays a clean no-op.
repo8b="$(new_repo_with_paused_mission)"; make_gh_stub "$repo8b/gh"
export GH_LOG="$repo8b/gh.log"; : >"$GH_LOG"
rc8b=0
(
  cd "$repo8b"
  LCARS_GH_BIN="$repo8b/gh" LCARS_GIT_BIN="$(command -v git)" \
  LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_LOGS_SCRIPT" \
    bash "$SCRIPT" answer --mission "$MID" --answer "Per-course." >out8b.txt 2>&1
) || rc8b=$?
check "8b. a plain escalation answer still exits 0 with the hook present" "[ '$rc8b' -eq 0 ]"
check "8b. no PR is opened on a plain escalation answer" \
  "! grep -q 'pr create' '$repo8b/gh.log'"

# --- Behaviour 9 (BUG-043/055): answering a RECONCILE design gate is SPECIFIC --
# A reconcile design gate is marked with a dedicated marker file
# (reconcile-design-question.txt). When respond answers a mission whose pending
# gate is that reconcile design gate, in ADDITION to the generic answers.json it
# must: (a) write the captain's answer to a DEDICATED store the reconcile resume
# reads (reconcile-answer.txt), (b) RESET the reconcile round budget
# (reconcileRound deleted) and clear the escalated reconcileStatus, and
# (c) clear the marker. A NON-reconcile gate must be unchanged (no dedicated
# store, no round reset).
reconcile_marker_of() { echo "$1/.git/lcars/missions/$MID/reconcile-design-question.txt"; }
reconcile_answer_of() { echo "$1/.git/lcars/missions/$MID/reconcile-answer.txt"; }

# Build a Mission parked at the Verify reconcile design gate: the marker is set,
# state carries reconcileRound + reconcileStatus=escalated, awaitingHuman, and a
# pending design question.
new_repo_with_reconcile_design_gate() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "verify",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main",
  "reconcileRound": 2,
  "reconcileStatus": "escalated",
  "awaitingHuman": true,
  "pendingQuestion": "Two readouts overlap top-right — which should the player see?"
}
EOF
  cat >"$m/pending.json" <<'EOF'
{
  "stage": "verify",
  "questions": [
    "Two readouts overlap top-right — which should the player see?"
  ]
}
EOF
  # the marker that tells respond this is a RECONCILE design gate
  printf 'Two readouts overlap top-right — which should the player see?\n' \
    >"$m/reconcile-design-question.txt"
  echo "$repo"
}

repo9="$(new_repo_with_reconcile_design_gate)"; make_gh_stub "$repo9/gh"
export GH_LOG="$repo9/gh.log"; : >"$GH_LOG"
RANS="Move the best-score readout to the top-left and keep the badge top-right."
rc9=0
( cd "$repo9" && LCARS_GH_BIN="$repo9/gh" bash "$SCRIPT" answer \
    --mission "$MID" --answer "$RANS" >out9.txt 2>&1 ) || rc9=$?
s9="$(state_of "$repo9")"
check "9. answering a reconcile design gate exits 0" "[ '$rc9' -eq 0 ]"
check "9. writes the DEDICATED reconcile answer store" \
  "[ -f '$(reconcile_answer_of "$repo9")' ]"
check "9. the dedicated reconcile answer carries the captain's answer verbatim" \
  "grep -q 'top-left' '$(reconcile_answer_of "$repo9")'"
check "9. RESETS the reconcile round budget (reconcileRound deleted)" \
  "! grep -q '\"reconcileRound\"' '$s9'"
check "9. clears the escalated reconcileStatus" \
  "! grep -q '\"reconcileStatus\": *\"escalated\"' '$s9'"
check "9. clears the reconcile-design marker file" \
  "[ ! -f '$(reconcile_marker_of "$repo9")' ]"
check "9. still clears the generic awaiting-human gate" \
  "! grep -q '\"awaitingHuman\": *true' '$s9'"
check "9. still writes the generic answers.json (unchanged behaviour)" \
  "[ -f '$(answers_of "$repo9")' ]"

# --- Behaviour 9b: a NON-reconcile gate answer is UNCHANGED -----------------
# Answering an ordinary escalation (no reconcile-design marker) must NOT create a
# dedicated reconcile answer store and must NOT touch a reconcile round budget.
repo9b="$(new_repo_with_paused_mission)"; make_gh_stub "$repo9b/gh"
export GH_LOG="$repo9b/gh.log"; : >"$GH_LOG"
rc9b=0
( cd "$repo9b" && LCARS_GH_BIN="$repo9b/gh" bash "$SCRIPT" answer \
    --mission "$MID" --answer "Per-course." >out9b.txt 2>&1 ) || rc9b=$?
check "9b. a non-reconcile gate answer exits 0" "[ '$rc9b' -eq 0 ]"
check "9b. a non-reconcile gate writes NO dedicated reconcile answer store" \
  "[ ! -f '$(reconcile_answer_of "$repo9b")' ]"
check "9b. a non-reconcile gate still writes the generic answers.json" \
  "[ -f '$(answers_of "$repo9b")' ]"

# ==========================================================================
echo
printf 'lcars respond: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
