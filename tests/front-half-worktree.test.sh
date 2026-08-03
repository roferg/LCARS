#!/usr/bin/env bash
#
# Tests for THE FRONT HALF READING THE MISSION'S OWN CODE (S166).
#
# Skill source:
#   skills/lcars-run/run.sh   enter_mission_worktree / leave_mission_worktree —
#                             a disposable DETACHED worktree at the Mission's
#                             branch, entered before Research / Validate / Plan /
#                             Plan Review / grounding spawn anything.
#
# WHY THIS EXISTS. Until S166 those five workers were spawned with the AMBIENT
# working tree as cwd, and LCARS compensated with a sentence — `mission_branch_block`
# telling the worker "the checkout may be on an UNRELATED branch; IGNORE it".
# S159's live Copilot drive measured what a real worker does with that sentence:
# it repeated it back ("Let me check the mission branch content via git.") and
# then read the working-tree path anyway, never issuing a single git command.
# The guarantee LCARS actually shipped was "you are safe as long as the repo
# happens to be sitting on the right branch" — an unwritten rule, already broken
# twice (the DX-Scorecard staleness failure, and S93's sibling-branch leak where
# a Validator read ANOTHER Mission's code and decided the bug was already fixed).
#
# HOW THIS SUITE JUDGES. Not by asserting that a pointer says the right thing —
# that is exactly the over-certification S159's mechanical `git show lcars/<id>:…`
# check fell into, passing while the worker read a different tree entirely. Every
# assertion here is on WHAT THE WORKER COULD READ FROM ITS CWD: the recording
# stub reports its own $PWD and then looks for discriminating files that exist in
# one tree and not the other. A worker on the wrong tree cannot fake those.
#
# ZERO TOKENS. The cold worker is replaced by a fake worker-adapter, and `claude`
# and `copilot` are additionally shadowed by refusing PATH shims for the whole
# suite — so even a resolution bug cannot reach a billable CLI. Real git
# throughout (local repos, no remote is ever contacted).
#
# Usage: bash tests/front-half-worktree.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

export LCARS_VERSION_CHECK=0
# The BUG-076 hang guard polls every 15s before it notices a stub that exited in
# 30ms — 15s per spawn for nothing. The sanctioned knob, as in the other scoped
# suites; nothing here is ABOUT the hang guard.
export LCARS_WORKER_HANG_SECS=0
export LCARS_WORKER_CLI=claude

# --- THE MONEY GUARD: refusing PATH shims ---------------------------------
# S159 leaked ~$7 of real Opus because an env-var pin alone was not sufficient.
# Shadow both CLIs with executables that fail loudly and record the attempt, and
# put them FIRST on $PATH for the whole suite. Nothing in here can spend.
SHIMDIR="$TMPROOT/shims"; mkdir -p "$SHIMDIR"
SPEND_LOG="$TMPROOT/spend.log"
for cli in claude copilot; do
  cat >"$SHIMDIR/$cli" <<EOF
#!/usr/bin/env bash
echo "REAL-CLI-SPAWN-ATTEMPT $cli \$*" >>"$SPEND_LOG"
exit 97
EOF
  chmod +x "$SHIMDIR/$cli"
done
export PATH="$SHIMDIR:$PATH"

MID="lcars-20260731-001"
SIB="lcars-20260731-002"
BUG="lcars-20260731-003"
MBRANCH="lcars/$MID"
SBRANCH="lcars/$SIB"
SPIKE="captain/spike"

# --- the recording worker-adapter -----------------------------------------
# run.sh invokes it as: adapter spawn <cli> <toolset> <outdir> <prompt>, with the
# real env-role in $LCARS_WORKER_ROLE. It is a plain subprocess, so its $PWD IS
# the cwd run.sh spawned the worker with — the fact this whole session is about.
#
# The four `sees_*` lines are the honest witnesses: each names a file that exists
# in exactly ONE of the fixture's trees, so the answer flips on which tree the
# worker is standing in. `log_sibling` is the S93 shape — a worker that can read
# the sibling Mission's COMMIT is a worker that can be talked into deferring to it.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
seen() { if [ -f "$1" ]; then printf 'yes'; else printf 'no'; fi; }
{
  printf 'role=%s\n' "$role"
  printf 'cwd=%s\n' "$PWD"
  printf 'head=%s\n' "$(git rev-parse HEAD 2>/dev/null)"
  if git symbolic-ref -q HEAD >/dev/null 2>&1; then printf 'attached=yes\n'; else printf 'attached=no\n'; fi
  printf 'sees_mission_only=%s\n' "$(seen src/mission-only.txt)"
  printf 'sees_spike_only=%s\n'   "$(seen src/spike-only.txt)"
  printf 'sees_sibling_only=%s\n' "$(seen src/sibling-only.txt)"
  printf 'sees_parent_only=%s\n'  "$(seen src/parent-delivered.txt)"
  if git log --oneline -n 50 2>/dev/null | grep -q SIBLING-MARKER; then
    printf 'log_sibling=yes\n'
  else
    printf 'log_sibling=no\n'
  fi
  printf 'input_dirs=%s\n' "$(printf '%s' "${LCARS_WORKER_INPUT_DIRS:-}" | tr '\n' ' ')"
} >>"$RECORD"
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"

# A canned, well-formed artifact per role — unless $STARVE is set, in which case
# the worker produces NOTHING and the Stage fails after its retries. That is the
# failure-path lifecycle test: the worktree must be gone either way.
[ -n "${STARVE:-}" ] && exit 0
case "$role" in
  # $MANYQ drives the one front-half ESCALATION: more questions than the cap, so
  # Research parks the Mission awaiting-human instead of advancing.
  research-questions)
    : >"$outdir/questions.txt"
    if [ -n "${MANYQ:-}" ]; then
      i=1; while [ "$i" -le 21 ]; do printf 'Question %s?\n' "$i" >>"$outdir/questions.txt"; i=$((i + 1)); done
    fi ;;
  research-grounding)
    cat >"$outdir/grounding.json" <<'JSON'
{ "targets": ["src/parent-delivered.txt"], "kind": "modify-existing",
  "restated": "the delivered control is wired to the wrong handler",
  "reuse_directive": "Modify the delivered code; do NOT add a parallel control." }
JSON
    ;;
  validate)
    cat >"$outdir/validated-plan.md" <<'MD'
# Validated Plan: Add an /about route

## Synthesis
Wire the route into the existing router.

## Decisions
- Reuse the existing router table.

## Rationale
The router already resolves every other page; one more entry is the whole change.
MD
    ;;
  plan)
    cat >"$outdir/plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Resolve /about through the existing router table",
    "description": "Add the /about entry to the router table so the About page renders.",
    "acceptanceCriteria": ["GET /about renders the About page instead of the 404 view"],
    "estimatedReadLoc": 120,
    "estimatedTestLoc": 40,
    "estimatedNewLoc": 30,
    "dependencies": [],
    "rationale": "One route entry is the whole user-observable behaviour."
  }
]
JSON
    ;;
  plan-review) printf '{ "passed": true, "issues": [] }\n' >"$outdir/verdict.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A worker binary that merely EXISTS so require_worker passes. The adapter above
# is what actually runs; if this is ever invoked it fails loudly and is recorded.
make_worker_bin() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "UNEXPECTED-WORKER-BIN-SPAWN \$*" >>"$SPEND_LOG"
exit 96
EOF
  chmod +x "$1"
}

make_gh() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# A git wrapper that LOGS every invocation, so "no new network calls" is an
# assertion about observed argv rather than a promise.
make_git_wrapper() { # path
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${GIT_LOG:-/dev/null}"
exec $(command -v git) "\$@"
EOF
  chmod +x "$1"
}

# --- the fixture ----------------------------------------------------------
# One repo, four trees that disagree on purpose:
#   main             src/base.txt                       (+ CONTEXT.md)
#   lcars/<MID>      … + src/mission-only.txt           THE MISSION'S CODE
#   lcars/<SIB>      … + src/sibling-only.txt           a SIBLING Mission (S93)
#   captain/spike    … + src/spike-only.txt             where the captain parks
# Nothing but the branch the Stage is pinned to contains its marker file, so the
# recording adapter's answers cannot be right by accident.
new_repo() { # → echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$repo"
    git init -q -b main
    git config user.email t@t; git config user.name t
    mkdir -p src
    printf 'base\n' >src/base.txt
    printf '# Context\n\nA fixture repo.\n' >CONTEXT.md
    git add -A && git commit -q -m "init"

    git checkout -q -b "lcars/$MID"
    printf 'only on the mission branch\n' >src/mission-only.txt
    git add -A && git commit -q -m "mission work"

    git checkout -q main
    git checkout -q -b "lcars/$SIB"
    printf 'only on the sibling branch\n' >src/sibling-only.txt
    git add -A && git commit -q -m "SIBLING-MARKER sibling mission work"

    git checkout -q main
    git checkout -q -b "$SPIKE"
    printf 'only on the spike branch\n' >src/spike-only.txt
    git add -A && git commit -q -m "captain spike"

    git checkout -q main
  ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<JSON
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  # EVERY stub and log lives OUTSIDE the clone, as a sibling. Two reasons, both
  # learned the hard way here: a stub in the repo root makes the tree dirty, which
  # scenario 7 is measuring; and a fixture that commits with `git add -A` would
  # sweep the stubs onto a branch and then DELETE them on the next checkout.
  make_adapter     "$repo.adapter"
  make_worker_bin  "$repo.worker"
  make_gh          "$repo.gh"
  make_git_wrapper "$repo.gitw"
  echo "$repo"
}

# Seed the Mission under test with every artifact the four Stages demand, so any
# one of them can be run in isolation by just setting the stage.
seed_mission() { # repo [id] [extra-state-fields]
  local repo="$1" id="${2:-$MID}" extra="${3:-}"
  local d="$repo/.git/lcars/missions/$id"
  mkdir -p "$d"
  cat >"$d/state.json" <<JSON
{
  "id": "$id",
  "type": "feature",
  "title": "Add an /about route",
  "stage": "align",
  "branch": "lcars/$id",
  "base": "main",
  "githubIssue": null$extra
}
JSON
  cat >"$d/prd.md" <<'MD'
# Mission: Add an /about route

**Type:** feature
**Goal:** The /about route should resolve to the About page instead of 404ing.
MD
  printf '# Validated Plan: Add an /about route\n\n## Synthesis\nWire the route in.\n' >"$d/validated-plan.md"
  cat >"$d/plan.json" <<'JSON'
[
  { "id": "t-001", "title": "Resolve /about through the existing router table",
    "description": "Add the /about entry to the router table.",
    "acceptanceCriteria": ["GET /about renders the About page"],
    "estimatedReadLoc": 120, "estimatedTestLoc": 40, "estimatedNewLoc": 30,
    "dependencies": [], "rationale": "One route entry is the whole behaviour." }
]
JSON
  printf '%s' "$d"
}

set_stage() { # repo id stage
  local s="$1/.git/lcars/missions/$2/state.json"
  sed "s/\"stage\": \"[a-z-]*\"/\"stage\": \"$3\"/" "$s" >"$s.tmp" && mv "$s.tmp" "$s"
}

park_checkout() { # repo branch  — where the CAPTAIN's tree is sitting
  ( cd "$1" && git checkout -q "$2" ) >/dev/null 2>&1
}

# Run one Stage. RECORD/PROMPTS are truncated first so each call is judged alone.
stage() { # repo id action [extra-env…]
  local repo="$1" id="$2" action="$3"; shift 3
  : >"$repo.record"; : >"$repo.prompts"
  OUT="$( cd "$repo" && env \
      LCARS_GH_BIN="$repo.gh" LCARS_GIT_BIN="$repo.gitw" \
      LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" \
      RECORD="$repo.record" PROMPTS="$repo.prompts" \
      GIT_LOG="$repo.gitlog" \
      "$@" bash "$SCRIPT" "$action" --mission "$id" 2>&1 )"
  RC=$?
}

# The captain's OWN path. `lcars run` never invokes a Stage the way `stage()`
# above does — it spawns each one as a subprocess and re-emits a synthesized
# summary, which is exactly how the ⌂ readout went missing in the live drive.
# Same stubs, same recording adapter; only the entry point differs.
NOTIFY_STUB="$TMPROOT/notify"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOTIFY_STUB"; chmod +x "$NOTIFY_STUB"

drive() { # repo id [run-args…]
  local repo="$1" id="$2"; shift 2
  : >"$repo.record"; : >"$repo.prompts"
  OUT="$( cd "$repo" && env \
      LCARS_GH_BIN="$repo.gh" LCARS_GIT_BIN="$repo.gitw" \
      LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" \
      LCARS_NOTIFY="$NOTIFY_STUB" \
      RECORD="$repo.record" PROMPTS="$repo.prompts" \
      GIT_LOG="$repo.gitlog" \
      bash "$SCRIPT" drive --mission "$id" "$@" 2>&1 )"
  RC=$?
}

# The tree marker as the DRIVER prints it, for one stage's summary line. Empty
# when that line carries none — which is the whole assertion in the honest case.
drive_tree() { # stage-label  ← reads $OUT
  printf '%s' "$OUT" | sed -n "s/^$1  *[✓⏸].*⌂ //p" | head -1
}

# rec <repo> <key> — the FIRST value the recording adapter wrote for that key.
rec() { sed -n "s/^$2=//p" "$1.record" 2>/dev/null | head -1; }
# recall <repo> <key> — every value, newline-separated (multi-spawn stages).
recall() { sed -n "s/^$2=//p" "$1.record" 2>/dev/null; }
# `grep -c` exits 1 on a zero count, so `|| echo 0` would print TWO lines. Count
# with awk, which always exits 0 and always prints exactly one number.
spawns() { awk '/^role=/{n++} END{print n+0}' "$1.record" 2>/dev/null; }

wt_count() { ( cd "$1" && git worktree list 2>/dev/null | grep -c . ); }
no_spend() { [ ! -s "$SPEND_LOG" ]; }

printf '\n\033[1mfront-half worktree (S166)\033[0m\n'

# ============================================================================
# 1. THE WORKER'S CWD IS A WORKTREE WHOSE HEAD IS THE MISSION'S CODE
# ============================================================================
printf '\n  -- 1. worker cwd is the Mission'"'"'s own tree --\n'
r1="$(new_repo)"; seed_mission "$r1" >/dev/null
MSHA="$( cd "$r1" && git rev-parse "$MBRANCH" )"
stage "$r1" "$MID" research
check "research: the worker's cwd is NOT the ambient repo root" \
  '[ "$(rec "$r1" cwd)" != "$r1" ]'
check "research: the worker's cwd is the Mission's stage-tree" \
  '[ "$(rec "$r1" cwd)" = "$r1/.git/lcars/stage-tree/$MID" ]'
check "research: the worker's HEAD is the mission branch's sha" \
  '[ "$(rec "$r1" head)" = "$MSHA" ]'
check "research: that checkout is DETACHED (holds no branch ref)" \
  '[ "$(rec "$r1" attached)" = "no" ]'
check "research: the worker can read the mission-only file" \
  '[ "$(rec "$r1" sees_mission_only)" = "yes" ]'
check "research: the Stage says which tree it read, out loud" \
  'printf "%s" "$OUT" | grep -q "mission tree"'
check "research: the printed line names the mission branch" \
  'printf "%s" "$OUT" | grep -q "$MBRANCH"'
check "research: out-of-worktree inputs are granted (.git/lcars)" \
  '[ "$(rec "$r1" input_dirs)" = "$r1/.git/lcars" ]'
check "research: no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 2. THE HEADLINE — the captain's checkout is on an UNRELATED branch
# ============================================================================
printf '\n  -- 2. THE HEADLINE: ambient checkout on an unrelated branch --\n'
r2="$(new_repo)"; seed_mission "$r2" >/dev/null
park_checkout "$r2" "$SPIKE"
for act in research validate plan plan-review; do
  case "$act" in
    research)    set_stage "$r2" "$MID" align ;;
    validate)    set_stage "$r2" "$MID" validate ;;
    plan)        set_stage "$r2" "$MID" plan ;;
    plan-review) set_stage "$r2" "$MID" plan-review ;;
  esac
  stage "$r2" "$MID" "$act"
  check "$act: reads the MISSION's code (mission-only file present)" \
    '[ "$(rec "$r2" sees_mission_only)" = "yes" ]'
  check "$act: cannot see the captain's spike branch content" \
    '[ "$(rec "$r2" sees_spike_only)" = "no" ]'
  check "$act: exited 0 with the checkout parked elsewhere" '[ "$RC" -eq 0 ]'
done
check "the captain's checkout is STILL on the spike branch" \
  '[ "$( cd "$r2" && git rev-parse --abbrev-ref HEAD )" = "$SPIKE" ]'
check "no worktree leaked across the whole front half" '[ "$(wt_count "$r2")" -eq 1 ]'
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 3. THE S93 REGRESSION — the checkout is on a SIBLING Mission's branch
# ============================================================================
printf '\n  -- 3. THE S93 REGRESSION: ambient checkout on a sibling Mission --\n'
r3="$(new_repo)"; seed_mission "$r3" >/dev/null; seed_mission "$r3" "$SIB" >/dev/null
park_checkout "$r3" "$SBRANCH"
set_stage "$r3" "$MID" validate
stage "$r3" "$MID" validate
check "validate: the sibling Mission's code is NOT readable" \
  '[ "$(rec "$r3" sees_sibling_only)" = "no" ]'
check "validate: the sibling Mission's COMMIT is not in reachable history" \
  '[ "$(rec "$r3" log_sibling)" = "no" ]'
check "validate: this Mission's own code IS readable" \
  '[ "$(rec "$r3" sees_mission_only)" = "yes" ]'
check "validate: the sibling's checkout is untouched" \
  '[ "$( cd "$r3" && git rev-parse --abbrev-ref HEAD )" = "$SBRANCH" ]'
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 4. GROUNDING — a logged bug sees the PARENT's delivered code
# ============================================================================
printf '\n  -- 4. grounding: the bug child reads the PARENT'"'"'s delivered code --\n'
r4="$(new_repo)"
# The parent DELIVERED something on its branch that exists nowhere else.
( cd "$r4" && git checkout -q "$MBRANCH" \
    && printf 'the delivered control\n' >src/parent-delivered.txt \
    && git add -A && git commit -q -m "parent delivers the control" \
    && git checkout -q main ) >/dev/null 2>&1
seed_mission "$r4" >/dev/null
PDIR="$r4/.git/lcars/missions/$MID"
# The bug child exactly as log.sh writes it while the parent is still pre-merge:
# origin="log", stage="align", branch == the PARENT's branch.
bdir="$r4/.git/lcars/missions/$BUG"; mkdir -p "$bdir"
cat >"$bdir/state.json" <<JSON
{ "id": "$BUG", "type": "bug", "origin": "log", "title": "the control does nothing",
  "stage": "align", "branch": "$MBRANCH", "base": "$MBRANCH", "githubIssue": null,
  "parentMission": "$MID", "parentIssue": 42 }
JSON
printf '# Mission: the control does nothing\n\n**Type:** bug\nClicking it does nothing.\n' >"$bdir/prd.md"
# Park the captain somewhere else entirely.
park_checkout "$r4" "$SPIKE"
stage "$r4" "$BUG" research
check "grounding: exactly ONE bounded worker ran" '[ "$(spawns "$r4")" -eq 1 ]'
check "grounding: it ran in grounding mode" '[ "$(rec "$r4" role)" = "research-grounding" ]'
check "grounding: the PARENT's delivered file is readable" \
  '[ "$(rec "$r4" sees_parent_only)" = "yes" ]'
check "grounding: the captain's spike branch is NOT readable" \
  '[ "$(rec "$r4" sees_spike_only)" = "no" ]'
check "grounding: it advanced to validate" \
  'grep -q "\"stage\": \"validate\"" "$bdir/state.json"'
check "grounding: no worktree leaked" '[ "$(wt_count "$r4")" -eq 1 ]'
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 5. LIFECYCLE — removed on success AND on failure
# ============================================================================
printf '\n  -- 5. lifecycle: the worktree is gone on every exit path --\n'
r5="$(new_repo)"; seed_mission "$r5" >/dev/null
park_checkout "$r5" "$SPIKE"
stage "$r5" "$MID" research
check "success: git worktree list is clean" '[ "$(wt_count "$r5")" -eq 1 ]'
check "success: the stage-tree dir is gone" '[ ! -d "$r5/.git/lcars/stage-tree/$MID" ]'
check "success: no stale worktree registration" \
  '[ -z "$( cd "$r5" && git worktree list --porcelain | grep "stage-tree" )" ]'

# The starved worker never writes an artifact → the Stage dies after its retries.
set_stage "$r5" "$MID" validate
stage "$r5" "$MID" validate STARVE=1
check "failure: the Stage really did fail" '[ "$RC" -ne 0 ]'
check "failure: it retried in a worktree each time" '[ "$(spawns "$r5")" -ge 2 ]'
check "failure: every retry stood in the Mission's tree" \
  '[ "$(recall "$r5" sees_mission_only | sort -u)" = "yes" ]'
check "failure: git worktree list is STILL clean" '[ "$(wt_count "$r5")" -eq 1 ]'
check "failure: the stage-tree dir is gone" '[ ! -d "$r5/.git/lcars/stage-tree/$MID" ]'
check "failure: the Mission did not advance" \
  'grep -q "\"stage\": \"validate\"" "$r5/.git/lcars/missions/$MID/state.json"'

# A hard-killed Stage leaves a tree behind; the next Stage must not be blocked
# by it. This is the self-heal path, driven by staging the wreckage by hand.
( cd "$r5" && mkdir -p .git/lcars/stage-tree \
    && git worktree add -q --detach ".git/lcars/stage-tree/$MID" "$MBRANCH" ) >/dev/null 2>&1
check "a leftover worktree from a killed Stage is present (fixture)" \
  '[ "$(wt_count "$r5")" -eq 2 ]'
set_stage "$r5" "$MID" validate
stage "$r5" "$MID" validate
check "recovery: the next Stage runs anyway" '[ "$RC" -eq 0 ]'
check "recovery: it still read the Mission's code" \
  '[ "$(rec "$r5" sees_mission_only)" = "yes" ]'
check "recovery: and cleaned up after itself" '[ "$(wt_count "$r5")" -eq 1 ]'
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 6. IMPLEMENT IS NOT BLOCKED — the branch ref is never held
# ============================================================================
printf '\n  -- 6. the branch ref stays free for Implement and the gates --\n'
r6="$(new_repo)"; seed_mission "$r6" >/dev/null
park_checkout "$r6" "$SPIKE"
for act in research validate plan plan-review; do
  case "$act" in
    research)    set_stage "$r6" "$MID" align ;;
    validate)    set_stage "$r6" "$MID" validate ;;
    plan)        set_stage "$r6" "$MID" plan ;;
    plan-review) set_stage "$r6" "$MID" plan-review ;;
  esac
  stage "$r6" "$MID" "$act"
done
# The reconcile gate cuts an ATTACHED worktree on the mission branch. That is the
# operation a front-half worktree holding the ref would make impossible — which is
# the whole reason the front half is DETACHED.
attach_rc=0
( cd "$r6" && git worktree add -q "$TMPROOT/attach6" "$MBRANCH" ) >/dev/null 2>&1 || attach_rc=$?
check "reconcile-shaped ATTACHED worktree on the mission branch succeeds" '[ "$attach_rc" -eq 0 ]'
( cd "$r6" && git worktree remove --force "$TMPROOT/attach6" ) >/dev/null 2>&1
# The per-ticket worktree is detached at the branch tip.
tick_rc=0
( cd "$r6" && git worktree add -q --detach "$TMPROOT/tick6" "$MBRANCH" ) >/dev/null 2>&1 || tick_rc=$?
check "Implement-shaped DETACHED ticket worktree succeeds" '[ "$tick_rc" -eq 0 ]'
( cd "$r6" && git worktree remove --force "$TMPROOT/tick6" ) >/dev/null 2>&1
# replay_ticket_commit checks the branch out in the shared tree.
co_rc=0
( cd "$r6" && git checkout -q "$MBRANCH" ) >/dev/null 2>&1 || co_rc=$?
check "replay-shaped checkout of the mission branch succeeds" '[ "$co_rc" -eq 0 ]'
check "no worktree leaked" '[ "$(wt_count "$r6")" -eq 1 ]'

# ============================================================================
# 7. THE CAPTAIN'S DIRTY TREE SURVIVES BYTE-IDENTICAL
# ============================================================================
printf '\n  -- 7. a dirty ambient checkout is never touched --\n'
r7="$(new_repo)"; seed_mission "$r7" >/dev/null
park_checkout "$r7" "$SPIKE"
printf 'the captain was halfway through this\n' >>"$r7/src/base.txt"
printf 'scratch notes\n' >"$r7/NOTES.txt"
before_status="$( cd "$r7" && git status --porcelain )"
before_sum="$( cd "$r7" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum )"
before_head="$( cd "$r7" && git rev-parse HEAD )"
for act in research validate plan plan-review; do
  case "$act" in
    research)    set_stage "$r7" "$MID" align ;;
    validate)    set_stage "$r7" "$MID" validate ;;
    plan)        set_stage "$r7" "$MID" plan ;;
    plan-review) set_stage "$r7" "$MID" plan-review ;;
  esac
  stage "$r7" "$MID" "$act"
done
after_status="$( cd "$r7" && git status --porcelain )"
after_sum="$( cd "$r7" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum )"
after_head="$( cd "$r7" && git rev-parse HEAD )"
check "the working tree is byte-identical after the whole front half" \
  '[ "$before_sum" = "$after_sum" ]'
check "git status is unchanged (nothing stashed, staged or reverted)" \
  '[ "$before_status" = "$after_status" ]'
check "HEAD never moved" '[ "$before_head" = "$after_head" ]'
check "the untracked scratch file still exists" '[ -f "$r7/NOTES.txt" ]'
check "the front half still ran in the Mission's tree" \
  '[ "$(rec "$r7" sees_mission_only)" = "yes" ]'

# ============================================================================
# 8. NO NEW NETWORK CALLS
# ============================================================================
printf '\n  -- 8. no network: local git operations only --\n'
r8="$(new_repo)"; seed_mission "$r8" >/dev/null
park_checkout "$r8" "$SPIKE"
: >"$r8.gitlog"
set_stage "$r8" "$MID" validate
stage "$r8" "$MID" validate
check "no fetch / pull / push / clone / ls-remote in the whole Stage" \
  '! grep -Eq "(^| )(fetch|pull|push|clone|ls-remote|remote)( |$)" "$r8.gitlog"'
check "the Stage did cut a worktree (the log is not empty by accident)" \
  'grep -q "worktree add" "$r8.gitlog"'
check "and pruned it" 'grep -q "worktree prune\|worktree remove" "$r8.gitlog"'

# ============================================================================
# 9. THE PROSE PIN IS STILL THERE (belt-and-braces; its removal is a later step)
# ============================================================================
printf '\n  -- 9. mission_branch_block survives as belt-and-braces --\n'
r9="$(new_repo)"; seed_mission "$r9" >/dev/null
set_stage "$r9" "$MID" validate
stage "$r9" "$MID" validate
check "the prompt still names the Mission's branch in prose" \
  'grep -q "The code for this Mission lives on branch" "$r9.prompts"'
check "the prompt still points at this Mission's branch specifically" \
  'grep -q "$MBRANCH" "$r9.prompts"'
check "the context source resolves inside the Mission's own tree" \
  'grep -q "stage-tree/$MID/CONTEXT.md" "$r9.prompts"'

# ============================================================================
# 10. NO BRANCH OF ITS OWN ⇒ NO WORKTREE, SAID OUT LOUD
# ============================================================================
printf '\n  -- 10. a branch-less Mission degrades honestly --\n'
r10="$(new_repo)"; seed_mission "$r10" >/dev/null
# A Mission whose recorded branch was never created (or has been merged away).
s10="$r10/.git/lcars/missions/$MID/state.json"
sed "s|\"branch\": \"$MBRANCH\"|\"branch\": \"lcars/never-created\"|" "$s10" >"$s10.tmp" && mv "$s10.tmp" "$s10"
park_checkout "$r10" "$SPIKE"
set_stage "$r10" "$MID" validate
stage "$r10" "$MID" validate
check "it says so rather than pretending" \
  'printf "%s" "$OUT" | grep -q "no branch of its own"'
check "it falls back to the ambient checkout" '[ "$(rec "$r10" cwd)" = "$r10" ]'
check "it does not claim a mission tree it never cut" \
  '! printf "%s" "$OUT" | grep -q "mission tree"'
check "nothing leaked" '[ "$(wt_count "$r10")" -eq 1 ]'

# ============================================================================
# 11. THE CAPTAIN IS SITTING ON THE MISSION'S OWN BRANCH
# ============================================================================
# The one case an ATTACHED worktree would have broken outright: git refuses to
# check out a branch that is already checked out elsewhere. Detached does not
# care, and the Stage must behave identically to every other scenario.
printf '\n  -- 11. the captain is parked ON the mission branch, with dirty work --\n'
r11="$(new_repo)"; seed_mission "$r11" >/dev/null
park_checkout "$r11" "$MBRANCH"
printf 'half-finished\n' >>"$r11/src/mission-only.txt"
b11="$( cd "$r11" && git status --porcelain )"
set_stage "$r11" "$MID" validate
stage "$r11" "$MID" validate
check "the Stage runs (a detached cut never contends with the checkout)" '[ "$RC" -eq 0 ]'
check "it still ran in its own tree, not the captain's" \
  '[ "$(rec "$r11" cwd)" = "$r11/.git/lcars/stage-tree/$MID" ]'
check "the captain's uncommitted edit did NOT reach the worker" \
  '! grep -q "half-finished" "$r11/.git/lcars/missions/$MID/validated-plan.md" 2>/dev/null; [ "$(rec "$r11" sees_mission_only)" = "yes" ]'
check "the captain is still on the mission branch" \
  '[ "$( cd "$r11" && git rev-parse --abbrev-ref HEAD )" = "$MBRANCH" ]'
check "the captain's dirty work is untouched" \
  '[ "$b11" = "$( cd "$r11" && git status --porcelain )" ]'
check "nothing leaked" '[ "$(wt_count "$r11")" -eq 1 ]'

# ============================================================================
# 12. THE CAPTAIN'S OWN PATH SHOWS IT (S166 D2)
# ============================================================================
# Every check above ran a Stage DIRECTLY. Nobody drives LCARS that way: the
# documented path is `lcars run`, which spawns each Stage as a subprocess,
# captures its stdout, and re-emits one synthesized line per Stage. So the ⌂
# readout — the only place the captain is told WHICH tree their Stage reasoned
# about — was printed into a buffer and thrown away. The behaviour was right and
# the copy was accurate, and neither reached the person they were for.
#
# The cure keeps the driver's design: it does not firehose the Stage's stdout,
# it lifts the branch@sha out and hangs it on the summary line as a MARKER,
# exactly as `⊘ isolated` is already lifted out of `isolated_line`'s sentence.
printf '\n  -- 12. the `lcars run` driver surfaces the tree it read --\n'
r12="$(new_repo)"; seed_mission "$r12" >/dev/null
park_checkout "$r12" "$SPIKE"
SHORT12="$( cd "$r12" && git rev-parse --short "$MBRANCH" )"

# One `--step` per Stage, chained down the real front half exactly as a captain
# debugging a Mission would: align → validate → plan → plan-review → schedule.
drive "$r12" "$MID" --step
check "--step research: the summary line carries the tree marker" \
  '[ -n "$(drive_tree research)" ]'
check "--step research: it names the Mission's branch and sha" \
  '[ "$(drive_tree research)" = "$MBRANCH @ $SHORT12" ]'
check "--step research: the Stage really did advance" \
  'grep -q "\"stage\": \"validate\"" "$r12/.git/lcars/missions/$MID/state.json"'
check "--step research: the marker is not a claim — the worker stood there" \
  '[ "$(rec "$r12" head)" = "$( cd "$r12" && git rev-parse "$MBRANCH" )" ]'

drive "$r12" "$MID" --step
check "--step validate: the summary line carries the tree marker" \
  '[ "$(drive_tree validate)" = "$MBRANCH @ $SHORT12" ]'
drive "$r12" "$MID" --step
check "--step plan: the summary line carries the tree marker" \
  '[ "$(drive_tree plan)" = "$MBRANCH @ $SHORT12" ]'
drive "$r12" "$MID" --step
check "--step plan-review: the summary line carries the tree marker" \
  '[ "$(drive_tree plan-review)" = "$MBRANCH @ $SHORT12" ]'
check "the captain's checkout is still on the spike branch throughout" \
  '[ "$( cd "$r12" && git rev-parse --abbrev-ref HEAD )" = "$SPIKE" ]'
check "no worktree leaked across four driven Stages" '[ "$(wt_count "$r12")" -eq 1 ]'
check "no real CLI was ever spawned" 'no_spend'

# A logged bug's grounding Research is driven the same way, and the tree it names
# is the PARENT's — the branch whose delivered code the symptom was reported
# against. Reuses r4's fixture shape.
printf '\n  -- 12b. a driven grounding Research names the PARENT'"'"'s tree --\n'
r12b="$(new_repo)"
( cd "$r12b" && git checkout -q "$MBRANCH" \
    && printf 'the delivered control\n' >src/parent-delivered.txt \
    && git add -A && git commit -q -m "parent delivers the control" \
    && git checkout -q main ) >/dev/null 2>&1
seed_mission "$r12b" >/dev/null
b12="$r12b/.git/lcars/missions/$BUG"; mkdir -p "$b12"
cat >"$b12/state.json" <<JSON
{ "id": "$BUG", "type": "bug", "origin": "log", "title": "the control does nothing",
  "stage": "align", "branch": "$MBRANCH", "base": "$MBRANCH", "githubIssue": null,
  "parentMission": "$MID", "parentIssue": 42 }
JSON
printf '# Mission: the control does nothing\n\n**Type:** bug\nClicking it does nothing.\n' >"$b12/prd.md"
park_checkout "$r12b" "$SPIKE"
SHORT12B="$( cd "$r12b" && git rev-parse --short "$MBRANCH" )"
drive "$r12b" "$BUG" --step
check "--step grounding: the summary line names the parent's branch and sha" \
  '[ "$(drive_tree research)" = "$MBRANCH @ $SHORT12B" ]'
check "--step grounding: the worker really stood in the parent's tree" \
  '[ "$(rec "$r12b" sees_parent_only)" = "yes" ]'
check "no real CLI was ever spawned" 'no_spend'

# The auto-advance drive — the walk-away path — must say it for EVERY Stage it
# runs, not once at the top. Four Stages, four markers, each on its own line.
printf '\n  -- 12c. a full auto drive says it per Stage --\n'
r12c="$(new_repo)"; seed_mission "$r12c" >/dev/null
park_checkout "$r12c" "$SPIKE"
SHORT12C="$( cd "$r12c" && git rev-parse --short "$MBRANCH" )"
drive "$r12c" "$MID"
for act in research validate plan plan-review; do
  check "auto: the $act line carries the tree marker" \
    '[ "$(drive_tree "$act")" = "$MBRANCH @ $SHORT12C" ]'
done
check "auto: it ran the whole front half in one drive" \
  '[ "$(printf "%s" "$OUT" | grep -c "⌂ $MBRANCH @ $SHORT12C")" -ge 4 ]'
check "auto: the captain's checkout is untouched" \
  '[ "$( cd "$r12c" && git rev-parse --abbrev-ref HEAD )" = "$SPIKE" ]'
check "no real CLI was ever spawned" 'no_spend'

# THE HONESTY CASE, on the driven path. A Mission with no branch of its own cut
# no worktree, so the driver has nothing true to report — and must report nothing
# rather than a plausible-looking branch@sha. This is the S159 lesson inverted:
# there, a marker asserted something it had not measured.
printf '\n  -- 12d. a branch-less Mission gets no marker, not a false one --\n'
r12d="$(new_repo)"; seed_mission "$r12d" >/dev/null
s12d="$r12d/.git/lcars/missions/$MID/state.json"
sed "s|\"branch\": \"$MBRANCH\"|\"branch\": \"lcars/never-created\"|" "$s12d" >"$s12d.tmp" \
  && mv "$s12d.tmp" "$s12d"
park_checkout "$r12d" "$SPIKE"
set_stage "$r12d" "$MID" validate
drive "$r12d" "$MID" --step
check "branch-less: the drive still advanced the Stage" '[ "$RC" -eq 0 ]'
check "branch-less: the summary line carries NO tree marker" \
  '[ -z "$(drive_tree validate)" ]'
check "branch-less: nothing in the drive claims a mission tree" \
  '! printf "%s" "$OUT" | grep -q "⌂"'
check "branch-less: and it does not name a branch it never cut" \
  '! printf "%s" "$OUT" | grep -q "never-created @"'
check "no real CLI was ever spawned" 'no_spend'

# The Stage that ESCALATES is the one where the tree matters most: the captain is
# about to answer a question, and "which code was it looking at when it asked?" is
# what the answer turns on. An escalated line carries the marker too.
printf '\n  -- 12e. an escalated Stage still names the tree it read --\n'
r12e="$(new_repo)"; seed_mission "$r12e" >/dev/null
park_checkout "$r12e" "$SPIKE"
SHORT12E="$( cd "$r12e" && git rev-parse --short "$MBRANCH" )"
MANYQ=1 drive "$r12e" "$MID" --step
check "escalated: the Mission really did park awaiting-human" \
  'grep -q "\"awaitingHuman\": true" "$r12e/.git/lcars/missions/$MID/state.json"'
check "escalated: the ⏸ line still names the tree the Stage read" \
  '[ "$(drive_tree research)" = "$MBRANCH @ $SHORT12E" ]'
check "escalated: nothing leaked" '[ "$(wt_count "$r12e")" -eq 1 ]'
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 13. THE `⊘ isolated` MARKER IS EVIDENCE, NOT A WORD (S166 D2 follow-on)
# ============================================================================
# `drive_line` decides the isolation marker by scanning the Stage's stdout. It
# used to scan for the BARE WORD "isolated" — safe only for as long as no Stage
# ever said the word in prose. Section 12's own fix broke that: the ⌂ sentence
# this suite exists to prove reads "…in an isolated worktree", so from S166 the
# tree sentence satisfies the isolation check ALL BY ITSELF. Every Stage that
# prints ⌂ also emits a real `isolated_line` today, so nothing on the board is
# lying — but the guard had stopped being a guard, one inline fallback away from
# certifying a Stage that never spawned a worker.
#
# The evidence is the MARKER `isolated_line` prints, and nothing else. These two
# checks are a matched pair: prose alone must NOT mark, the marker alone MUST.
printf '\n  -- 13. the isolation marker is lifted from evidence, not prose --\n'

# The pure hook: Stage output on stdin, the Stage name as the positional. No
# mission, no worker, no git — this is string work, and judging it as string work
# lets us hand `drive_line` the shape the real Stages do not produce yet.
dline() { # stage  <<< stage-output
  ( cd "$TMPROOT" && bash "$SCRIPT" drive-line-test "$1" 2>&1 )
}
TREE_SENTENCE="  ⌂ mission tree — validate reads 'lcars/x' @ abc1234 in an isolated worktree (your checkout is untouched)"
ISO_SENTENCE="  ⊘ isolated — validate ran in 1 cold worker(s) via claude"

d13a="$(printf '%s\n' "$TREE_SENTENCE" | dline validate)"
check "prose alone: the tree sentence does NOT earn a ⊘ isolated marker" \
  '! printf "%s" "$d13a" | grep -q "⊘ isolated"'
check "prose alone: the line is still printed, and still carries its tree marker" \
  '[ "$(printf "%s" "$d13a" | sed -n "s/^validate  *✓.*⌂ //p")" = "lcars/x @ abc1234" ]'

d13b="$(printf '%s\n%s\n' "$ISO_SENTENCE" "$TREE_SENTENCE" | dline validate)"
check "evidence: a real isolated_line DOES earn the ⊘ isolated marker" \
  'printf "%s" "$d13b" | grep -q "⊘ isolated"'
check "evidence: and the tree marker still rides alongside it" \
  '[ "$(printf "%s" "$d13b" | sed -n "s/^validate  *✓.*⌂ //p")" = "lcars/x @ abc1234" ]'

# The OTHER prose source, already in the tree: Schedule explains a lone wave with
# "isolated into a wave of its own". A Stage output carrying that and no marker
# must read as uncovered too.
d13c="$(printf '%s\n' "  T-002 declares establishesSharedInfrastructure — isolated into a wave of its own so later tickets build against it" | dline schedule)"
check "prose alone: Schedule's wave-isolation reason earns no marker either" \
  '! printf "%s" "$d13c" | grep -q "⊘ isolated"'

# And the real driven path is unchanged: a genuinely isolated Stage still shows
# the marker where the captain reads it.
r13="$(new_repo)"; seed_mission "$r13" >/dev/null
park_checkout "$r13" "$SPIKE"
drive "$r13" "$MID"
for act in research validate plan plan-review; do
  check "driven: the $act line still carries its ⊘ isolated marker" \
    'printf "%s" "$OUT" | grep -q "^'"$act"'  *✓.*⊘ isolated"'
done
check "no real CLI was ever spawned" 'no_spend'

# ============================================================================
printf '\n\033[1mfront-half worktree:\033[0m \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$pass" "$fail"
if [ -s "$SPEND_LOG" ]; then
  printf '\033[31mMONEY GUARD TRIPPED — a real CLI was invoked:\033[0m\n'
  cat "$SPEND_LOG"
  exit 1
fi
[ "$fail" -eq 0 ]
