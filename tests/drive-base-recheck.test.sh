#!/usr/bin/env bash
#
# Tests for the DRIVE-TIME base re-check (S159).
#
# Skill source:
#   skills/lcars-run/run.sh             cmd_drive — one re-check per drive, taken
#                                       AFTER the driver lock and BEFORE the
#                                       stage loop spawns anything
#   skills/lcars-init/lcars-common.sh   ensure_base_current — S158's guard, reused
#                                       verbatim, plus the `child-base` lane
#
# WHY THIS EXISTS. Filing and starting are separate moments. S158 brings the base
# up to date when the Mission is FILED; a Mission parked overnight — or filed now
# and driven tomorrow — still enters Research against whatever `main` was at
# filing time. DX-Scorecard's lcars-20260730-001 was filed at 16:00 and driven
# later, and Research truthfully reported a file "does not exist" because in that
# tree it did not.
#
# THE VOCABULARY GAINS EXACTLY ONE WORD. S158 consolidated fifteen verdict names
# back to four (`current | updated | stale | unknown`) on the captain's ruling
# that the name count IS the lying surface. S159 adds ONE: `child-base`, and it
# is not a shade of staleness — it is the guard REFUSING to have an opinion,
# because the base is another Mission's branch and "bringing it up to date from
# origin" would mean rebasing a bug fix onto code it was never written against.
#
# THIS SUITE IS SEPARATE FROM tests/base-freshness.test.sh ON PURPOSE. That one
# is 443 checks over a different script (file.sh) with no worker, no driver lock
# and no event log; this one drives run.sh end to end with a recording stub
# worker. Keeping them apart keeps each scoped and fast.
#
# EVERYTHING here is real git against LOCAL BARE remotes (`git init --bare`), so
# fetch/pull are genuine operations with no network and no forge. gh, the
# estimator, the notifier and the cold worker are all stubbed — ZERO model calls.
#
# Usage: bash tests/drive-base-recheck.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$REPO_ROOT/skills/lcars-log/log.sh}"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
VERSION_STAMP="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"

# The interactive version check is irrelevant here (and would fetch the LCARS
# repo's own origin). Kill it for the whole suite — zero output, zero git calls.
export LCARS_VERSION_CHECK=0
# The BUG-076 hang guard polls every 15s before it will even notice a worker that
# exited in 30ms, so a stub-worker drive pays 15s per spawn for nothing. Disable
# it for this suite (the sanctioned knob; tests/mission-log-grounding.test.sh does
# the same) — nothing here is ABOUT the hang guard.
export LCARS_WORKER_HANG_SECS=0
# The worker stub is a generic binary; point the adapter at the claude argv arm
# explicitly (the same seam tests/cost.test.sh uses) rather than relying on the
# stub's basename resolving to a known CLI.
export LCARS_WORKER_CLI=claude

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# qgrep: drain stdin FULLY before grepping (a piped `grep -q` short-circuits and
# SIGPIPEs the producer, which fails the pipeline under `set -o pipefail`).
#
# IT IS FOR PIPES ONLY. Its `cat` reads STDIN whatever else it is given, so
# `qgrep -q pattern file` blocks forever whenever the suite is run with an open
# stdin (a terminal, or `foo | bash tests/…`) — which is exactly how a captain
# runs it. Every file-argument grep in this suite is a plain `grep`.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

# --- stubs ----------------------------------------------------------------
GH_STUB="$TMPROOT/gh"
cat >"$GH_STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"; exit 0
fi
exit 0
EOF
chmod +x "$GH_STUB"

NOTIFY_STUB="$TMPROOT/notify"
cat >"$NOTIFY_STUB" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$NOTIFY_STUB"

ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"
cat >"$ESTIMATOR_STUB" <<'EOF'
#!/usr/bin/env bash
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="${2:-}"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
mdir="$gitdir/lcars/missions/$mid"
[ -d "$mdir" ] || exit 1
cat >"$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "low",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
chmod +x "$ESTIMATOR_STUB"
export LCARS_RUN_BIN="$ESTIMATOR_STUB"

# THE RECORDING COLD WORKER. It is the ordering witness for behaviour 6: it does
# not read the source to decide whether the re-check ran first — it records the
# OBSERVED STATE OF THE TREE at the moment it was spawned (does the file only
# origin had exist yet? where is local `main`? where is origin/main?). If the
# re-check runs before the first worker, the worker sees the pulled tree; if it
# runs after (or not at all), it sees the stale one. Nothing else can produce
# that recording.
make_worker_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
role="${LCARS_WORKER_ROLE:-}"
if [ -n "${RECORD:-}" ]; then
  {
    printf 'role=%s\n' "$role"
    printf 'cwd=%s\n' "$PWD"
    if [ -f "src/real-view.txt" ]; then
      printf 'sees_origin_file=yes\n'
    else
      printf 'sees_origin_file=no\n'
    fi
    printf 'main=%s\n' "$(git rev-parse refs/heads/main 2>/dev/null)"
    printf 'origin_main=%s\n' "$(git rev-parse refs/remotes/origin/main 2>/dev/null)"
    # THE MISSION BRANCH, AS THE WORKER COULD ACTUALLY READ IT. `mission_branch_block`
    # (run.sh:574) pins every read-only Stage to `lcars/<id>` and tells it in so many
    # words to IGNORE the ambient checkout — so what the ambient cwd contains is NOT
    # what this worker reasons about. The only honest witness is the mission branch's
    # own tree, observed here at spawn time.
    for b in $(git for-each-ref --format='%(refname:short)' 'refs/heads/lcars/*' 2>/dev/null); do
      if git cat-file -e "$b:src/real-view.txt" 2>/dev/null; then f=yes; else f=no; fi
      printf 'mbranch=%s sha=%s sees_origin_file=%s\n' "$b" "$(git rev-parse "$b" 2>/dev/null)" "$f"
    done
  } >>"$RECORD"
fi
[ -n "${WORKER_LOG:-}" ] && printf 'role=%s\n' "$role" >>"$WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || exit 0
case "$role" in
  research-questions)
    # ZERO questions → `GATE: skip` → Research advances with no fan-out.
    : >"$out/questions.txt" ;;
  research-grounding)
    cat >"$out/grounding.json" <<JSON
{ "symptom": "the reported defect", "anchoredTo": ["src/real-view.txt"],
  "decisions": ["modify the existing implementation"],
  "rationale": "the feature already ships this file" }
JSON
    ;;
  validate)
    cat >"$out/validated-plan.md" <<MD
# Validated Plan: Add an /about route

## Synthesis
Wire the route into the existing router.

## Decisions
- Reuse the existing router table.

## Rationale
The router already resolves every other page; one more entry is the whole change.
MD
    ;;
  context-pack)
    printf '# Context pack\n\nStub.\n' >"$out/context-pack.md" ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# --- fixtures -------------------------------------------------------------
# scaffold_lcars <repo> — .git/lcars with a STAMPED config (so file.sh's version
# check has nothing to prompt about) and a pre-generated context pack (so no
# Stage ever needs a context-pack worker). Both live INSIDE .git/, so neither
# dirties the working tree the guard is judging.
scaffold_lcars() {
  local repo="$1"
  mkdir -p "$repo/.git/lcars/missions"
  # S183: a CONFIGURED test command, so this fixture is a repo with a test
  # FOUNDATION. `lcars file` now refuses to open a normal mission on a repo that
  # has none (greenfield/untested) and points at Establish Vision instead — so a
  # suite that files missions has to file against a repo that can actually be
  # filed against. `true` resolves via `command -v`, which is all the readiness
  # verdict asks of a command. The gate itself is proven in
  # tests/foundation-gate.test.sh, against real repos in all four states.
  cat >"$repo/.git/lcars/config.json" <<EOF
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "model": "claude-sonnet", "projectName": "fixture", "contextFile": null,
  "testCommand": "true",
  "lcarsVersion": "$VERSION_STAMP", "created": "2026-05-30T00:00:00Z" }
EOF
  printf '# Context pack\n\nA fixture repo.\n' >"$repo/.git/lcars/context-pack.md"
}

# make_fixture <name> — a local BARE origin + a seed clone that pushed the first
# commit + the working clone under test. Echoes the working clone's path.
# (The shape is lifted from tests/base-freshness.test.sh so both suites judge the
# same kind of repo.)
make_fixture() {
  local name="$1"
  local bare="$TMPROOT/$name.git" seed="$TMPROOT/$name.seed" repo="$TMPROOT/$name"
  git init -q --bare "$bare" 2>/dev/null
  git init -q "$seed" 2>/dev/null
  (
    cd "$seed"
    git config user.email t@t; git config user.name t
    git checkout -q -b main 2>/dev/null
    echo "base" >README.md
    git add -A && git commit -q -m init
    git remote add origin "$bare" && git push -q -u origin main
  ) >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$repo" 2>/dev/null
  ( cd "$repo" && git config user.email t@t && git config user.name t )
  scaffold_lcars "$repo"
  # The stub worker lives OUTSIDE the clone. Dropping it in the repo root makes
  # the tree dirty, and a dirty tree is precisely what the guard refuses to write
  # into — the fixture would silently test the wrong lane.
  make_worker_stub "$repo.worker"
  printf '%s' "$repo"
}

# advance_origin <name> <n> — push n new commits to the bare origin from the seed
# clone, so the working clone is genuinely n commits behind. The FIRST of those
# commits adds src/real-view.txt — the "file only origin has" a stale worker
# would swear does not exist.
advance_origin() {
  local name="$1" n="$2" i
  (
    cd "$TMPROOT/$name.seed"
    git pull -q --ff-only origin main
    for i in $(seq 1 "$n"); do
      mkdir -p src
      printf 'origin line %s\n' "$i" >>src/real-view.txt
      git add -A && git commit -q -m "origin commit $i"
    done
    git push -q origin main
  ) >/dev/null 2>&1
}

# A FEATURE PRD on purpose: a `bug` mission routes Research into GROUNDING mode,
# which is a different stage driver. The top-level fixtures here must take the
# ordinary Research path; behaviour 4 files its bug child through the real
# `lcars log`, which is where a genuine grounding mission comes from.
write_prd() {
  cat >"$1" <<'EOF'
# Mission: Add an /about route

**Type:** feature
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
}

# file_mission <repo> [args…] — grill-first filing with pinned date/now, exactly
# as tests/base-freshness.test.sh does it. stdout+stderr land in <repo>.out.
file_mission() {
  local repo="$1"; shift
  local rc=0
  (
    cd "$repo"
    LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
      GH_LOG="$repo.ghlog" bash "$FILE_SCRIPT" "$@" >"$repo.out" 2>&1
  ) || rc=$?
  printf '%s' "$rc" >"$repo.rc"
}

# drive <repo> <mission-id> [args…] — the real driver, with every external
# dependency stubbed. LCARS_NOW is deliberately NOT pinned here: events.jsonl
# stamps `ts` with it, and an ISO string there would be invalid JSON.
# Output accumulates in <repo>.drive.out (each call also gets its own
# <repo>.drive.<n>.out so a re-drive can be judged on its own).
drive() {
  local repo="$1" mid="$2"; shift 2
  local rc=0 n
  n="$(cat "$repo.drives" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" >"$repo.drives"
  (
    cd "$repo"
    LCARS_GH_BIN="$GH_STUB" LCARS_WORKER_BIN="$repo.worker" LCARS_NOTIFY="$NOTIFY_STUB" \
      GH_LOG="$repo.ghlog" WORKER_LOG="$repo.workerlog" RECORD="$repo.record" \
      bash "$RUN_SCRIPT" drive --mission "$mid" "$@" >"$repo.drive.$n.out" 2>&1
  ) || rc=$?
  cat "$repo.drive.$n.out" >>"$repo.drive.out"
  printf '%s' "$rc" >"$repo.drive.rc"
}

# S196 — `cloneId` PINS THE FINGERPRINT so $MID below stays a literal. A minted
# mission id is now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the first 4 hex of
# the clone's own `cloneId` (a UUID4 minted on first use, so two clones of one
# repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning it makes <fp> the constant `c10e`;
# the widening itself is proven in tests/mission-id.test.sh.
MID="lcars-20260530-001-c10e"
mdir() { printf '%s/.git/lcars/missions/%s' "$1" "${2:-$MID}"; }

# sf <state.json> <dotted.key> — read a (possibly nested) field. Empty on miss.
sf() {
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'): d=d[k]
    print(d)
except Exception:
    pass
" "$1" "$2" 2>/dev/null
}

# ev_count <events.jsonl> <type> — how many events of that type were logged.
ev_count() { grep -c "\"type\":\"$2\"" "$1" 2>/dev/null || true; }
# ev_line <events.jsonl> <type> — the first event of that type, whole line.
ev_line()  { grep "\"type\":\"$2\"" "$1" 2>/dev/null | head -1; }

# sha <repo> <ref> — a ref's sha, or nothing.
sha() { git -C "$1" rev-parse "$2" 2>/dev/null; }

# ==========================================================================
echo "drive-time base re-check (S159)"
[ -f "$RUN_SCRIPT" ]  || { echo "script under test not found at $RUN_SCRIPT"; exit 1; }
[ -f "$FILE_SCRIPT" ] || { echo "file.sh not found at $FILE_SCRIPT"; exit 1; }
[ -f "$COMMON" ]      || { echo "shared lib not found at $COMMON"; exit 1; }

# --- Behaviour 0: the vocabulary gained exactly ONE word -------------------
# S158's ruling stands: four verdicts plus a reason sentence. S159 is allowed
# `child-base` and nothing else, so the guard is held to that declaration here —
# the same way S158's behaviour 32 holds its own source to its own.
# BOTH recorders are scanned. S160 round 2 added `_lcars_base_set_after_attempt`
# (the setter with no `fix` slot, for an outcome LCARS reached by trying and
# failing), and a declaration check that inspects only one of the two would go on
# passing while a sixth verdict walked in through the other — the "flattering
# number" this round exists to distrust.
VERDICTS_IN_SOURCE="$(grep -oE '_lcars_base_set(_after_attempt)? [a-z-]+' "$COMMON" \
  | awk '{print $2}' | sort -u | tr '\n' ' ')"
check "0. the guard sets ONLY the five sanctioned verdicts" \
  "[ \"\$VERDICTS_IN_SOURCE\" = 'child-base current stale unknown updated ' ]"
check "0. lcars-common.sh defines the mission-branch test" \
  "bash -c '. \"$COMMON\"; type lcars_base_is_mission_branch' >/dev/null 2>&1"

# --- Behaviour 1: filed current, origin moves ahead, THEN driven -----------
# The headline case, and the exact shape of DX-Scorecard 53: nothing was wrong at
# filing time, so S158 had nothing to fix. The staleness arrives in the gap.
r1="$(make_fixture d1)"
prd1="$TMPROOT/prd1.md"; write_prd "$prd1"
file_mission "$r1" --prd "$prd1"
M1="$(mdir "$r1")"
check "1. the mission filed against a CURRENT base" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.verdict)\" = 'current' ]"
FILED_CHECKED_AT="$(sf "$M1/state.json" baseFreshness.checkedAt)"
# …and NOW the world moves on.
advance_origin d1 3
ORIGIN_TIP1="$(sha "$TMPROOT/d1.git" refs/heads/main)"
check "1. the origin-only file is genuinely absent before the drive" \
  "[ ! -f '$r1/src/real-view.txt' ]"
drive "$r1" "$MID" --step
check "1. the drive exits 0 (never blocked by the check)" "[ \"\$(cat '$r1.drive.rc')\" = '0' ]"
check "1. the base was PULLED before the stage loop" \
  "[ \"\$(sha '$r1' refs/heads/main)\" = '$ORIGIN_TIP1' ]"
check "1. the origin-only file is now in the tree a worker reads" \
  "[ -f '$r1/src/real-view.txt' ]"
check "1. the refreshed verdict is 'updated'" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "1. behindBy records the PRE-pull distance (3)" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.behindBy)\" = '3' ]"
check "1. baseSha is the post-pull sha" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.baseSha)\" = '$ORIGIN_TIP1' ]"
check "1. checkedAt was REFRESHED (not the filing-time stamp)" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.checkedAt)\" != '$FILED_CHECKED_AT' ]"
check "1. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M1/state.json'"
check "1. state.json still carries the rest of the record (base)" \
  "[ \"\$(sf '$M1/state.json' base)\" = 'main' ]"
check "1. the drive still advanced the Stage (align → validate)" \
  "[ \"\$(sf '$M1/state.json' stage)\" = 'validate' ]"
check "1. a base_stale event was emitted" \
  "[ \"\$(ev_count '$M1/events.jsonl' base_stale)\" = '1' ]"
check "1. the event carries behindBy in its data" \
  "ev_line '$M1/events.jsonl' base_stale | qgrep -q '\"behindBy\":3'"
check "1. the event names the stage the drive began at" \
  "ev_line '$M1/events.jsonl' base_stale | qgrep -q '\"stage\":\"align\"'"
check "1. the drive readout names the fast-forward" \
  "grep -qi 'fast-forward' '$r1.drive.out'"
# THE MISSION BRANCH MOVES TOO (S159, captain ruling 2026-07-31). Fast-forwarding
# only the BASE does not deliver the session's stated goal: `mission_branch_block`
# (run.sh:574) pins every Research/Validate/Plan worker to `lcars/<id>` and tells
# it to IGNORE the ambient checkout, so a base at the fresh tip with the mission
# branch left on the old one still hands every Stage the stale tree. The move is
# taken ONLY when it is LOSSLESS — the branch carries no commits of its own.
MB1="lcars/$MID"
check "1. the mission branch was fast-forwarded onto the refreshed base" \
  "[ \"\$(sha '$r1' 'refs/heads/$MB1')\" = '$ORIGIN_TIP1' ]"
check "1. the origin-only file is really on the mission branch now" \
  "git -C '$r1' cat-file -e '$MB1:src/real-view.txt'"
check "1. missionBranchAtBase is TRUE, and it is true" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.missionBranchAtBase)\" = 'True' ]"
check "1. the drive says the branch MOVED, not that it was left alone" \
  "grep -q '✓ MISSION BRANCH' '$r1.drive.out'"
check "1. …and it does NOT print the ⚠ refusal it no longer earns" \
  "! grep -q '⚠ MISSION BRANCH' '$r1.drive.out'"
check "1. …nor the now-false 'never moves a branch' claim" \
  "! grep -q 'never moves a branch' '$r1.drive.out'"
check "1. …nor a 'git branch -f' Fix line for something already done" \
  "! grep -q 'Fix:.*git branch -f' '$r1.drive.out'"
check "1. the captain's HEAD was NOT moved to the mission branch" \
  "[ \"\$(git -C '$r1' symbolic-ref --short HEAD)\" = 'main' ]"
check "1. …and HEAD is not detached anywhere" \
  "git -C '$r1' symbolic-ref -q HEAD >/dev/null"

# --- Behaviour 6: the check runs BEFORE the first stage worker is spawned ---
# Proven from OBSERVED STATE, not from reading the source: the recording worker
# wrote down what the tree looked like at the instant it was spawned.
check "6. the stage worker really was spawned" "[ -s '$r1.record' ]"
check "6. …and it SAW the origin-only file (so the pull came first)" \
  "grep -q 'sees_origin_file=yes' '$r1.record'"
check "6. …and local main was already at the origin tip when it started" \
  "grep -q '^main=$ORIGIN_TIP1' '$r1.record'"
check "6. the FIRST worker spawned was a Stage worker, not something earlier" \
  "[ \"\$(head -1 '$r1.workerlog')\" = 'role=research-questions' ]"
# THE HEADLINE, from observed state. The worker is pinned to the mission branch,
# so the question that matters is what THAT branch held at spawn time.
check "6. the worker recorded the mission branch it is pinned to" \
  "grep -q '^mbranch=$MB1 ' '$r1.record'"
check "6. …and at SPAWN TIME that branch already carried the new origin commits" \
  "grep -q '^mbranch=$MB1 sha=$ORIGIN_TIP1 sees_origin_file=yes' '$r1.record'"

# --- Behaviour 5 (part 1): --step takes the check EXACTLY once --------------
check "5. --step fetched the base exactly once" \
  "[ \"\$(grep -c 'base freshness — fetching origin' '$r1.drive.1.out')\" = '1' ]"
check "5. --step really did step exactly one Stage" \
  "grep -q 'stepped one Stage' '$r1.drive.1.out'"

# --- Behaviour 5 (part 2) + idempotence: a re-drive re-checks, silently -----
# The base is current now. Re-driving must not re-emit the same event, and must
# not shout a second time.
drive "$r1" "$MID" --step
check "5. the re-drive still exits 0" "[ \"\$(cat '$r1.drive.rc')\" = '0' ]"
check "5. the re-check ran again (one fetch on the second drive too)" \
  "[ \"\$(grep -c 'base freshness — fetching origin' '$r1.drive.2.out')\" = '1' ]"
check "5. …and found it current, so NO second base_stale event" \
  "[ \"\$(ev_count '$M1/events.jsonl' base_stale)\" = '1' ]"
check "5. the refreshed verdict is now 'current'" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.verdict)\" = 'current' ]"

# --- Behaviour 2: already current at drive time → no event, no pull ---------
# Two identical fixtures, driven identically: one with the guard ON (and nothing
# to do), one with it switched OFF. Apart from the one line that announces the
# network call, the drive must be BYTE-IDENTICAL — an unaffected mission may not
# drift.
r2="$(make_fixture d2)";  prd2="$TMPROOT/prd2.md"; write_prd "$prd2"; file_mission "$r2" --prd "$prd2"
r2b="$(make_fixture d2b)"; file_mission "$r2b" --prd "$prd2"
M2="$(mdir "$r2")"; M2B="$(mdir "$r2b")"
BEFORE_MAIN2="$(sha "$r2" refs/heads/main)"
BEFORE_ORIGIN2="$(sha "$r2" refs/remotes/origin/main)"
drive "$r2" "$MID" --step
( cd "$r2b" && LCARS_BASE_FRESHNESS=0 LCARS_GH_BIN="$GH_STUB" LCARS_WORKER_BIN="$r2b.worker" \
    LCARS_NOTIFY="$NOTIFY_STUB" GH_LOG="$r2b.ghlog" WORKER_LOG="$r2b.workerlog" \
    bash "$RUN_SCRIPT" drive --mission "$MID" --step >"$r2b.drive.out" 2>&1 )
check "2. no base_stale event on an already-current mission" \
  "[ \"\$(ev_count '$M2/events.jsonl' base_stale)\" = '0' ]"
check "2. local main was not moved" "[ \"\$(sha '$r2' refs/heads/main)\" = '$BEFORE_MAIN2' ]"
check "2. verdict is 'current'" \
  "[ \"\$(sf '$M2/state.json' baseFreshness.verdict)\" = 'current' ]"
check "2. nothing loud was printed" "! grep -q 'BASE FRESHNESS' '$r2.drive.out'"
# The two drives run in two SEPARATE fixture repos, so their commit ids differ by
# construction — and since S166 each stage line ends with the tree the Stage read
# (`⌂ <branch> @ <sha>`). That field is repo truth, not guard behaviour, so it is
# normalised on BOTH sides exactly as the guard's own ⟳ line is dropped. Every
# other byte must still match, which is what this check has always been about.
# Only the ⌂ marker's sha is normalised — a sha anywhere else must still match.
norm_drive() { grep -v 'base freshness' "$1" | sed '/⌂/s/@ [0-9a-f][0-9a-f]*$/@ <sha>/'; }
check "2. the drive is byte-identical to a guard-off drive (bar the ⟳ line)" \
  "diff <(norm_drive '$r2.drive.out') <(norm_drive '$r2b.drive.out') >/dev/null"
check "2. both drives reached the same stage" \
  "[ \"\$(sf '$M2/state.json' stage)\" = \"\$(sf '$M2B/state.json' stage)\" ]"

# --- Behaviour 3: a DIRTY tree at drive time → no pull, drive proceeds ------
r3="$(make_fixture d3)"; prd3="$TMPROOT/prd3.md"; write_prd "$prd3"; file_mission "$r3" --prd "$prd3"
M3="$(mdir "$r3")"
advance_origin d3 2
printf 'captain work in progress\n' >>"$r3/README.md"
printf 'untracked scratch\n' >"$r3/scratch.txt"
BEFORE_STATUS3="$(git -C "$r3" status --porcelain)"
BEFORE_README3="$(cksum <"$r3/README.md")"
BEFORE_MAIN3="$(sha "$r3" refs/heads/main)"
drive "$r3" "$MID" --step
check "3. the drive STILL exits 0 on a dirty tree" "[ \"\$(cat '$r3.drive.rc')\" = '0' ]"
check "3. the drive still advanced the Stage" \
  "[ \"\$(sf '$M3/state.json' stage)\" = 'validate' ]"
check "3. NO pull happened (local main untouched)" \
  "[ \"\$(sha '$r3' refs/heads/main)\" = '$BEFORE_MAIN3' ]"
check "3. the dirty file is byte-identical afterwards" \
  "[ \"\$(cksum <'$r3/README.md')\" = '$BEFORE_README3' ]"
check "3. the working-tree status is byte-identical afterwards" \
  "[ \"\$(git -C '$r3' status --porcelain)\" = \"\$BEFORE_STATUS3\" ]"
check "3. the untracked scratch file survives" "[ -f '$r3/scratch.txt' ]"
check "3. verdict is 'stale'" \
  "[ \"\$(sf '$M3/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "3. …and it is flagged loud" \
  "[ \"\$(sf '$M3/state.json' baseFreshness.loud)\" = 'True' ]"
check "3. a warning was emitted, naming the dirt" \
  "grep -q 'BASE FRESHNESS' '$r3.drive.out' && grep -qi 'uncommitted\|untracked' '$r3.drive.out'"
check "3. the staleness was still MEASURED (behindBy 2)" \
  "[ \"\$(sf '$M3/state.json' baseFreshness.behindBy)\" = '2' ]"
check "3. a base_stale event was emitted for the unfixed staleness" \
  "[ \"\$(ev_count '$M3/events.jsonl' base_stale)\" = '1' ]"
# Idempotence on the STALE path too: re-driving an identically-stale mission must
# not log the same fact twice.
sed -i.bak 's/"stage": "validate"/"stage": "align"/' "$M3/state.json" && rm -f "$M3/state.json.bak"
drive "$r3" "$MID" --step
check "3. a re-drive with IDENTICAL staleness does not re-emit the event" \
  "[ \"\$(ev_count '$M3/events.jsonl' base_stale)\" = '1' ]"

# --- Behaviour 4: a logged-bug child is NEVER pulled onto main --------------
# The child's base is its PARENT's Mission branch. "Bring the base up to date
# from origin" is meaningless there and actively dangerous: it would rebase the
# fix onto code it was never written against.
r4="$(make_fixture d4)"; prd4="$TMPROOT/prd4.md"; write_prd "$prd4"; file_mission "$r4" --prd "$prd4"
PARENT="$MID"
bug4="$TMPROOT/bug4.md"
cat >"$bug4" <<'EOF'
# Mission: The About link still 404s from the footer

**Type:** bug
**Goal:** The footer's About link should resolve like the header's does.
**Acceptance Criteria:**
- The footer link returns HTTP 200
**Out of Scope:**
- Restyling the footer
**Constraints:**
- Minimal change
EOF
( cd "$r4" && LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" GH_LOG="$r4.ghlog" \
    LCARS_RUN_BIN="$TMPROOT/no-such-run.sh" \
    bash "$LOG_SCRIPT" --parent "$PARENT" --prd "$bug4" >"$r4.log.out" 2>&1 )
CHILD="lcars-20260530-002-c10e"
M4="$(mdir "$r4" "$CHILD")"
check "4. the bug child was filed" "[ -d '$M4' ]"
check "4. its base really is the parent's Mission branch" \
  "[ \"\$(sf '$M4/state.json' base)\" = 'lcars/$PARENT' ]"
advance_origin d4 2
BEFORE_PARENT4="$(sha "$r4" "refs/heads/lcars/$PARENT")"
BEFORE_MAIN4="$(sha "$r4" refs/heads/main)"
BEFORE_ORIGIN4="$(sha "$r4" refs/remotes/origin/main)"
drive "$r4" "$CHILD" --step
check "4. the child drive exits 0" "[ \"\$(cat '$r4.drive.rc')\" = '0' ]"
check "4. verdict is 'child-base'" \
  "[ \"\$(sf '$M4/state.json' baseFreshness.verdict)\" = 'child-base' ]"
check "4. NOTHING was fetched from origin (no announce line at all)" \
  "! grep -q 'base freshness — fetching' '$r4.drive.out'"
check "4. origin/main was not even updated" \
  "[ \"\$(sha '$r4' refs/remotes/origin/main)\" = '$BEFORE_ORIGIN4' ]"
check "4. local main was not moved" "[ \"\$(sha '$r4' refs/heads/main)\" = '$BEFORE_MAIN4' ]"
check "4. the PARENT's branch was not moved" \
  "[ \"\$(sha '$r4' 'refs/heads/lcars/$PARENT')\" = '$BEFORE_PARENT4' ]"
check "4. no base_stale event on a child base" \
  "[ \"\$(ev_count '$M4/events.jsonl' base_stale)\" = '0' ]"
check "4. behindBy is null — nothing was measured, and it does not pretend 0" \
  "[ \"\$(sf '$M4/state.json' baseFreshness.behindBy)\" = 'None' ]"
check "4. the drive still advanced the child's Stage" \
  "[ \"\$(sf '$M4/state.json' stage)\" = 'validate' ]"
check "4. the reason names the Mission branch, legibly" \
  "case \"\$(sf '$M4/state.json' baseFreshness.reason)\" in *'Mission branch'*) true ;; *) false ;; esac"
check "4. the record is not loud (this is the CORRECT state for a bug child)" \
  "[ \"\$(sf '$M4/state.json' baseFreshness.loud)\" = 'False' ]"
check "4. state.json is valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M4/state.json'"

# --- Behaviour 8: the event is legible on the human surfaces ---------------
# ADR-004's ONE rendering: `lcars status`, the kanban card and the issue-comment
# mirror all render through render_human, so the new event kind is given a line
# there rather than falling through to an unglyphed bare sentence.
RENDER_LIB="$REPO_ROOT/skills/lcars-status/render.sh"
BS_LINE="$(ev_line "$M1/events.jsonl" base_stale)"
BS_HUMAN="$(EVENTS=/dev/null WAVES=/dev/null bash -c '. "$1"; render_human "$2"' _ "$RENDER_LIB" "$BS_LINE")"
check "8. the base_stale event renders through the ONE renderer" "[ -n \"\$BS_HUMAN\" ]"
check "8. …with the ⟳ the guard itself uses on the CLI" \
  "case \"\$BS_HUMAN\" in '⟳ '*) true ;; *) false ;; esac"
check "8. …and it says how far behind the base was" \
  "case \"\$BS_HUMAN\" in *'3 commit(s) behind origin'*) true ;; *) false ;; esac"

# --- Behaviour 7: an unreachable origin never blocks the drive -------------
r5="$(make_fixture d5)"; prd5="$TMPROOT/prd5.md"; write_prd "$prd5"; file_mission "$r5" --prd "$prd5"
M5="$(mdir "$r5")"
( cd "$r5" && git remote set-url origin "$TMPROOT/nowhere-at-all.git" )
drive "$r5" "$MID" --step
check "7. the drive exits 0 with an unreachable origin" "[ \"\$(cat '$r5.drive.rc')\" = '0' ]"
check "7. the drive still advanced the Stage" \
  "[ \"\$(sf '$M5/state.json' stage)\" = 'validate' ]"
check "7. verdict is 'unknown' (never a staleness it did not establish)" \
  "[ \"\$(sf '$M5/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "7. no base_stale event on an unmeasured base" \
  "[ \"\$(ev_count '$M5/events.jsonl' base_stale)\" = '0' ]"

# --- Behaviour 9: a Mission with NO recorded base is left alone -------------
# Missions predate this field. The re-check must not invent a base ("probably
# main") to have something to check — that is the same substitution the record
# refuses when it writes `null` rather than a reassuring 0.
r6="$(make_fixture d6)"; prd6="$TMPROOT/prd6.md"; write_prd "$prd6"; file_mission "$r6" --prd "$prd6"
M6="$(mdir "$r6")"
python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d.pop("base",None); d.pop("baseFreshness",None); open(f,"w").write(json.dumps(d,indent=2)+"\n")' "$M6/state.json"
advance_origin d6 2
BEFORE_MAIN6="$(sha "$r6" refs/heads/main)"
drive "$r6" "$MID" --step
check "9. the drive exits 0 with no recorded base" "[ \"\$(cat '$r6.drive.rc')\" = '0' ]"
check "9. NOTHING was fetched (there is no base to check)" \
  "! grep -q 'base freshness' '$r6.drive.out'"
check "9. no ref was moved" "[ \"\$(sha '$r6' refs/heads/main)\" = '$BEFORE_MAIN6' ]"
check "9. no baseFreshness was invented" \
  "[ -z \"\$(sf '$M6/state.json' baseFreshness.verdict)\" ]"
check "9. the Stage still advanced" "[ \"\$(sf '$M6/state.json' stage)\" = 'validate' ]"

# ==========================================================================
# S159 — THE MISSION-BRANCH ADVANCE (captain ruling 2026-07-31)
#
# The base moving is not the goal; the MISSION BRANCH moving is. Three lanes, and
# each is proven by what git actually shows afterwards, never by reading source:
#
#   10  not checked out anywhere  → a pure pointer fast-forward (`git branch -f`)
#   11  checked out, tree CLEAN   → advanced in place (`git merge --ff-only`), and
#                                   the checkout stays on the same branch
#   12  checked out, tree DIRTY   → REFUSED; the dirty file is byte-identical
#   13  the branch carries work   → REFUSED; the commit survives; rebase Fix
#
# and 14 holds every printed `Fix:` to being a command that RUNS and CLEARS the
# condition — S158's suite caught seven that did not.
# ==========================================================================

# fixline <file> — the Fix: command from the LAST ⚠ MISSION BRANCH block, with the
# parenthetical gloss stripped. It is the exact string the captain would copy.
fixline() {
  grep -A4 '⚠ MISSION BRANCH' "$1" 2>/dev/null | grep 'Fix:' | tail -1 \
    | sed -e 's/^ *Fix: *//' -e 's/   (.*//'
}

# --- Behaviour 10: not checked out → pointer fast-forward -------------------
# Already proven in behaviour 1 (the ordinary case: `lcars file` cuts the branch
# with `git branch` and never checks it out). What 10 adds is the NEGATIVE: the
# pointer move must not have created a worktree, moved HEAD, or written a file
# into the captain's tree beyond the base's own fast-forward.
check "10. no worktree was created for the mission branch" \
  "[ \"\$(git -C '$r1' worktree list --porcelain | grep -c '^worktree ')\" = '1' ]"
check "10. the ambient tree is clean afterwards" \
  "[ -z \"\$(git -C '$r1' status --porcelain)\" ]"
check "10. the ✓ line names the branch and the distance" \
  "grep -q \"✓ MISSION BRANCH — $MB1 fast-forwarded 3 commit(s)\" '$r1.drive.out'"
check "10. …and says WHY it was safe (no commits of its own)" \
  "grep -qi 'no commits of its own' '$r1.drive.out'"

# --- Behaviour 11: checked out in a CLEAN worktree → advanced in place ------
r7="$(make_fixture d7)"; prd7="$TMPROOT/prd7.md"; write_prd "$prd7"; file_mission "$r7" --prd "$prd7"
M7="$(mdir "$r7")"; MB7="lcars/$MID"
WT7="$TMPROOT/d7.wt"
git -C "$r7" worktree add -q "$WT7" "$MB7" 2>/dev/null
advance_origin d7 2
ORIGIN_TIP7="$(sha "$TMPROOT/d7.git" refs/heads/main)"
check "11. the mission branch really is checked out in a worktree" \
  "[ \"\$(git -C '$WT7' symbolic-ref --short HEAD)\" = '$MB7' ]"
check "11. the worktree tree is clean before the drive" \
  "[ -z \"\$(git -C '$WT7' status --porcelain)\" ]"
drive "$r7" "$MID" --step
check "11. the drive exits 0" "[ \"\$(cat '$r7.drive.rc')\" = '0' ]"
check "11. the mission branch WAS advanced, in place" \
  "[ \"\$(sha '$r7' 'refs/heads/$MB7')\" = '$ORIGIN_TIP7' ]"
check "11. the worktree's own HEAD followed it" \
  "[ \"\$(git -C '$WT7' rev-parse HEAD)\" = '$ORIGIN_TIP7' ]"
check "11. the worktree is STILL on the same branch (no detach, no switch)" \
  "[ \"\$(git -C '$WT7' symbolic-ref --short HEAD)\" = '$MB7' ]"
check "11. the ambient checkout is still on main" \
  "[ \"\$(git -C '$r7' symbolic-ref --short HEAD)\" = 'main' ]"
check "11. the origin-only file is really in the WORKTREE a worker would read" \
  "[ -f '$WT7/src/real-view.txt' ]"
check "11. missionBranchAtBase is TRUE" \
  "[ \"\$(sf '$M7/state.json' baseFreshness.missionBranchAtBase)\" = 'True' ]"
check "11. it reported a move, not a refusal" \
  "grep -q '✓ MISSION BRANCH' '$r7.drive.out' && ! grep -q '⚠ MISSION BRANCH' '$r7.drive.out'"
check "11. …and the copy names the checkout it advanced" \
  "grep -q 'checked out' '$r7.drive.out'"
check "11. state.json is valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M7/state.json'"

# --- Behaviour 12: checked out with a DIRTY tree → refused ------------------
r8="$(make_fixture d8)"; prd8="$TMPROOT/prd8.md"; write_prd "$prd8"; file_mission "$r8" --prd "$prd8"
M8="$(mdir "$r8")"; MB8="lcars/$MID"
WT8="$TMPROOT/d8.wt"
git -C "$r8" worktree add -q "$WT8" "$MB8" 2>/dev/null
printf 'captain half-finished work\n' >>"$WT8/README.md"
printf 'scratch\n' >"$WT8/notes.txt"
BEFORE_WT8_README="$(cksum <"$WT8/README.md")"
BEFORE_WT8_STATUS="$(git -C "$WT8" status --porcelain)"
BEFORE_MB8="$(sha "$r8" "refs/heads/$MB8")"
advance_origin d8 2
ORIGIN_TIP8="$(sha "$TMPROOT/d8.git" refs/heads/main)"
drive "$r8" "$MID" --step
check "12. the drive exits 0 (a refusal never blocks)" "[ \"\$(cat '$r8.drive.rc')\" = '0' ]"
check "12. the drive still advanced the Stage" \
  "[ \"\$(sf '$M8/state.json' stage)\" = 'validate' ]"
check "12. the base itself WAS fast-forwarded (the ambient tree is clean)" \
  "[ \"\$(sha '$r8' refs/heads/main)\" = '$ORIGIN_TIP8' ]"
check "12. the mission branch was NOT moved" \
  "[ \"\$(sha '$r8' 'refs/heads/$MB8')\" = '$BEFORE_MB8' ]"
check "12. the dirty file is byte-identical afterwards" \
  "[ \"\$(cksum <'$WT8/README.md')\" = '$BEFORE_WT8_README' ]"
check "12. …and it still holds the captain's words" \
  "grep -q 'captain half-finished work' '$WT8/README.md'"
check "12. the worktree status is byte-identical afterwards" \
  "[ \"\$(git -C '$WT8' status --porcelain)\" = \"\$BEFORE_WT8_STATUS\" ]"
check "12. the untracked scratch file survives" "[ -f '$WT8/notes.txt' ]"
check "12. the refusal is LOUD and legible" \
  "grep -q '⚠ MISSION BRANCH' '$r8.drive.out'"
check "12. …and says WHY: a dirty tree it will not write into" \
  "grep -qi 'never writes into a dirty tree' '$r8.drive.out'"
check "12. …and names the checkout that is dirty" \
  "grep -qF '$WT8' '$r8.drive.out'"
check "12. …and names the KIND of dirt (unstaged + untracked)" \
  "grep -qi 'unstaged change(s)' '$r8.drive.out' && grep -qi 'untracked file(s)' '$r8.drive.out'"
check "12. missionBranchAtBase is FALSE — it does not report a move it did not make" \
  "[ \"\$(sf '$M8/state.json' baseFreshness.missionBranchAtBase)\" = 'False' ]"
check "12. it does NOT print the ✓ move line" \
  "! grep -q '✓ MISSION BRANCH' '$r8.drive.out'"

# --- Behaviour 14a: the DIRTY lane's Fix: really clears the condition -------
FIX8="$(fixline "$r8.drive.out")"
check "14. the dirty lane printed a Fix: command" "[ -n \"\$FIX8\" ]"
check "14. …it is not the no-op 'git branch -f' on a checked-out branch" \
  "case \"\$FIX8\" in *'branch -f'*) false ;; *) true ;; esac"
FIX8_RC=0; ( eval "$FIX8" ) >"$TMPROOT/fix8.out" 2>&1 || FIX8_RC=$?
check "14. …running it verbatim SUCCEEDS" "[ '$FIX8_RC' = '0' ] || { cat '$TMPROOT/fix8.out'; false; }"
check "14. …and it really cleared the condition (branch now at the base)" \
  "[ \"\$(sha '$r8' 'refs/heads/$MB8')\" = '$ORIGIN_TIP8' ]"
check "14. …without detaching the worktree" \
  "[ \"\$(git -C '$WT8' symbolic-ref --short HEAD)\" = '$MB8' ]"

# --- Behaviour 13: the branch carries its OWN commit → never moved ----------
r9="$(make_fixture d9)"; prd9="$TMPROOT/prd9.md"; write_prd "$prd9"; file_mission "$r9" --prd "$prd9"
M9="$(mdir "$r9")"; MB9="lcars/$MID"
# One real commit ON the mission branch, made without checking it out — exactly
# what an Implement wave leaves behind.
WT9="$TMPROOT/d9.wt"
git -C "$r9" worktree add -q "$WT9" "$MB9" 2>/dev/null
( cd "$WT9" && printf 'the mission own work\n' >mission-work.txt && git add -A \
    && git commit -q -m "mission commit" ) >/dev/null 2>&1
git -C "$r9" worktree remove --force "$WT9" 2>/dev/null
OWN9="$(sha "$r9" "refs/heads/$MB9")"
advance_origin d9 3
ORIGIN_TIP9="$(sha "$TMPROOT/d9.git" refs/heads/main)"
drive "$r9" "$MID" --step
check "13. the drive exits 0" "[ \"\$(cat '$r9.drive.rc')\" = '0' ]"
check "13. the mission branch was NOT moved" \
  "[ \"\$(sha '$r9' 'refs/heads/$MB9')\" = '$OWN9' ]"
check "13. its own commit still exists on it" \
  "git -C '$r9' cat-file -e '$MB9:mission-work.txt'"
check "13. no commit was lost anywhere in the repo" \
  "git -C '$r9' cat-file -e '$OWN9^{commit}'"
check "13. the base itself was still fast-forwarded" \
  "[ \"\$(sha '$r9' refs/heads/main)\" = '$ORIGIN_TIP9' ]"
check "13. the loud ⚠ MISSION BRANCH warning is retained" \
  "grep -q '⚠ MISSION BRANCH' '$r9.drive.out'"
check "13. …and the rebase Fix line is printed" \
  "grep -q 'Fix:.*git rebase' '$r9.drive.out'"
check "13. …and NOT a 'git branch -f' that would destroy that commit" \
  "! grep -q 'git branch -f' '$r9.drive.out'"
check "13. …and it names how many commits of its own it carries" \
  "grep -qi 'commit(s) of its own' '$r9.drive.out'"
check "13. missionBranchAtBase is FALSE" \
  "[ \"\$(sf '$M9/state.json' baseFreshness.missionBranchAtBase)\" = 'False' ]"
check "13. it does NOT claim a move" "! grep -q '✓ MISSION BRANCH' '$r9.drive.out'"

# --- Behaviour 14b: the rebase Fix: really clears the condition -------------
FIX9="$(fixline "$r9.drive.out")"
check "14. the carries-work lane printed a Fix: command" "[ -n \"\$FIX9\" ]"
FIX9_RC=0; ( cd "$r9" && eval "$FIX9" ) >"$TMPROOT/fix9.out" 2>&1 || FIX9_RC=$?
check "14. …running it verbatim SUCCEEDS" "[ '$FIX9_RC' = '0' ] || { cat '$TMPROOT/fix9.out'; false; }"
check "14. …the branch now contains the base" \
  "git -C '$r9' merge-base --is-ancestor refs/heads/main 'refs/heads/$MB9'"
check "14. …and the mission's own work survived the rebase" \
  "git -C '$r9' cat-file -e '$MB9:mission-work.txt'"
# The rebase leaves the captain on the mission branch, which today's copy says
# out loud; the "brings you back" command must work too.
BACK9="$(grep -o 'git checkout [^ ]*' "$r9.drive.out" | tail -1)"
check "14. …the 'brings you back' command was printed" "[ -n \"\$BACK9\" ]"
BACK9_RC=0; ( cd "$r9" && eval "$BACK9" ) >/dev/null 2>&1 || BACK9_RC=$?
check "14. …and running it returns HEAD to where the captain was" \
  "[ '$BACK9_RC' = '0' ] && [ \"\$(git -C '$r9' symbolic-ref --short HEAD)\" = 'main' ]"

# --- Behaviour 15: a logged-bug child moves NOTHING ------------------------
# Re-asserted against the branch as well as the parent: the child's base IS the
# parent's Mission branch, and the advance must decline to have an opinion there
# for the same reason `ensure_base_current` does — no fetch, no ref moved.
r10="$(make_fixture d10)"; prd10="$TMPROOT/prd10.md"; write_prd "$prd10"; file_mission "$r10" --prd "$prd10"
bug10="$TMPROOT/bug10.md"; cp "$bug4" "$bug10"
( cd "$r10" && LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" GH_LOG="$r10.ghlog" \
    LCARS_RUN_BIN="$TMPROOT/no-such-run.sh" \
    bash "$LOG_SCRIPT" --parent "$MID" --prd "$bug10" >"$r10.log.out" 2>&1 )
CHILD10="lcars-20260530-002-c10e"
M10="$(mdir "$r10" "$CHILD10")"
# Move the PARENT branch on, so the child is genuinely behind its base.
PWT10="$TMPROOT/d10.pwt"
git -C "$r10" worktree add -q "$PWT10" "lcars/$MID" 2>/dev/null
( cd "$PWT10" && printf 'parent work\n' >parent.txt && git add -A && git commit -q -m "parent work" ) >/dev/null 2>&1
git -C "$r10" worktree remove --force "$PWT10" 2>/dev/null
BEFORE_P10="$(sha "$r10" "refs/heads/lcars/$MID")"
BEFORE_C10="$(sha "$r10" "refs/heads/lcars/$CHILD10")"
advance_origin d10 2
BEFORE_MAIN10="$(sha "$r10" refs/heads/main)"
drive "$r10" "$CHILD10" --step
check "15. the child drive exits 0" "[ \"\$(cat '$r10.drive.rc')\" = '0' ]"
check "15. verdict is still 'child-base'" \
  "[ \"\$(sf '$M10/state.json' baseFreshness.verdict)\" = 'child-base' ]"
check "15. the PARENT's branch sha is identical before and after" \
  "[ \"\$(sha '$r10' 'refs/heads/lcars/$MID')\" = '$BEFORE_P10' ]"
check "15. the CHILD's own branch was not moved either" \
  "[ \"\$(sha '$r10' 'refs/heads/lcars/$CHILD10')\" = '$BEFORE_C10' ]"
check "15. local main was not moved (no fetch was taken at all)" \
  "[ \"\$(sha '$r10' refs/heads/main)\" = '$BEFORE_MAIN10' ]"
check "15. nothing was fetched" "! grep -q 'base freshness — fetching' '$r10.drive.out'"
check "15. no MISSION BRANCH block of either voice" \
  "! grep -q 'MISSION BRANCH' '$r10.drive.out'"

# --- Behaviour 16: idempotent — a re-drive of a current mission moves nothing
# Rewind the STAGE only (as behaviour 3 does) so the re-drive re-enters the same
# Stage; the git state is left exactly as the first drive left it.
python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["stage"]="align"; open(f,"w").write(json.dumps(d,indent=2)+"\n")' "$M1/state.json"
AFTER_MB1="$(sha "$r1" "refs/heads/$MB1")"
AFTER_MAIN1="$(sha "$r1" refs/heads/main)"
AFTER_EV1="$(ev_count "$M1/events.jsonl" base_stale)"
drive "$r1" "$MID" --step
N1="$(cat "$r1.drives")"
check "16. the re-drive exits 0" "[ \"\$(cat '$r1.drive.rc')\" = '0' ]"
check "16. the mission branch did not move again" \
  "[ \"\$(sha '$r1' 'refs/heads/$MB1')\" = '$AFTER_MB1' ]"
check "16. the base did not move again either" \
  "[ \"\$(sha '$r1' refs/heads/main)\" = '$AFTER_MAIN1' ]"
check "16. no new base_stale event" \
  "[ \"\$(ev_count '$M1/events.jsonl' base_stale)\" = '$AFTER_EV1' ]"
check "16. …and nothing about the mission branch is printed at all" \
  "! grep -q 'MISSION BRANCH' '$r1.drive.$N1.out'"

# --- Behaviour 17: FILE TIME IS UNCHANGED ----------------------------------
# S158's doctrine — "a branch cut at an older commit was cut there on purpose" —
# stands, and the two voices must not blur. The file-time reporter keeps its own
# text and its own `git branch -f` Fix; the drive-time one is a separate function.
check "17. the file-time reporter still exists, untouched in name" \
  "bash -c '. \"$COMMON\"; type lcars_base_branch_note' >/dev/null 2>&1"
check "17. …and still carries its own file-time sentence" \
  "grep -q 'never moves a branch that' '$COMMON'"
check "17. …and still offers 'git branch -f' as the file-time Fix" \
  "grep -q 'Fix:    git branch -f' '$COMMON'"
check "17. the DRIVE-time reporter is a SEPARATE function (the voices cannot blur)" \
  "bash -c '. \"$COMMON\"; type lcars_base_branch_note_drive' >/dev/null 2>&1"
check "17. …and cmd_drive calls the DRIVE reporter" \
  "grep -q 'lcars_base_branch_note_drive' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "17. …and never the FILE-time one" \
  "! grep -qF 'lcars_base_branch_note \"' '$REPO_ROOT/skills/lcars-run/run.sh'"
# The verdict vocabulary is still FIVE names. The advance is a separate fact with
# its own field; it must not have smuggled in a sixth.
VERDICTS_AFTER="$(grep -oE '_lcars_base_set [a-z-]+' "$COMMON" | awk '{print $2}' | sort -u | tr '\n' ' ')"
check "17. the verdict vocabulary is still exactly five names" \
  "[ \"\$VERDICTS_AFTER\" = 'child-base current stale unknown updated ' ]"
# The file-time path really is byte-identical in behaviour: file two identical
# fixtures whose base moved after the clone, one before and one after the S159
# code path is reachable, and compare the whole readout.
r11="$(make_fixture d11)"; advance_origin d11 2
file_mission "$r11" --prd "$prd1"
M11="$(mdir "$r11")"
check "17. filing still fast-forwards the base itself" \
  "[ \"\$(sf '$M11/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "17. filing does NOT print the drive-time ✓ MISSION BRANCH line" \
  "! grep -q '✓ MISSION BRANCH' '$r11.out'"
check "17. …and the mission branch is cut from the fresh tip anyway (S158)" \
  "[ \"\$(sha '$r11' 'refs/heads/$MB1')\" = \"\$(sha '$r11' refs/heads/main)\" ]"

# ==========================================================================
# Behaviours 18–19 — the two REFUSALS git will not make for us.
#
# These drive `lcars_base_advance_mission_branch` directly against real git rather
# than through the whole driver: that the driver calls it at all is already proven
# by 1/11/12/13, and what is left to prove is the git decision itself. Both are
# conditions `git merge --ff-only` and `git branch -f` do NOT protect against on
# their own — verified by hand before these were written.
# ==========================================================================

# adv <repo> <mb> <base> — the advance + its report, in the repo, as the driver
# runs it. Output to <repo>.adv.out.
adv() {
  ( cd "$1" && bash -c '. "$1"; lcars_base_advance_mission_branch "$2" "$3"; lcars_base_branch_note_drive "$2" "$3"' \
      _ "$COMMON" "$2" "$3" ) >"$1.adv.out" 2>&1
}

# --- Behaviour 18: a GITIGNORED collider is protected ----------------------
# `git status` reads CLEAN with a gitignored build artifact sitting in the tree,
# and `git merge --ff-only` will overwrite it without a word. Same bar the base's
# own fast-forward is held to (S158 step 8): refuse, name the file, leave it.
r12="$TMPROOT/d12"
git init -q "$r12"
( cd "$r12" && git config user.email t@t && git config user.name t && git checkout -q -b main \
    && printf 'build/\n' >.gitignore && echo a >a.txt && git add -A && git commit -q -m1 \
    && git branch "lcars/$MID" \
    && mkdir -p build && echo INCOMING >build/out.js && git add -f build/out.js \
    && git commit -q -m addbuild ) >/dev/null 2>&1
WT12="$TMPROOT/d12.wt"
git -C "$r12" worktree add -q "$WT12" "lcars/$MID" 2>/dev/null
mkdir -p "$WT12/build"; printf 'CAPTAINS OWN ARTIFACT\n' >"$WT12/build/out.js"
BEFORE_MB12="$(sha "$r12" "refs/heads/lcars/$MID")"
check "18. the collider leaves git status CLEAN (which is the whole hazard)" \
  "[ -z \"\$(git -C '$WT12' status --porcelain)\" ]"
adv "$r12" "lcars/$MID" main
check "18. the branch was NOT moved" \
  "[ \"\$(sha '$r12' 'refs/heads/lcars/$MID')\" = '$BEFORE_MB12' ]"
check "18. the captain's untracked artifact is byte-for-byte intact" \
  "grep -q 'CAPTAINS OWN ARTIFACT' '$WT12/build/out.js'"
check "18. the refusal names the colliding file" \
  "grep -q \"'build/out.js'\" '$r12.adv.out'"
check "18. …and says it would have OVERWRITTEN it" \
  "grep -qi 'would OVERWRITE' '$r12.adv.out'"
FIX12="$(fixline "$r12.adv.out")"
check "18. a Fix: was printed" "[ -n \"\$FIX12\" ]"
# The Fix is prose-then-command ("move or delete those file(s), then <cmd>"): run
# the human half, then the command half, and prove the pair really clears it.
CMD12="$(printf '%s' "$FIX12" | sed 's/.*then *//')"
rm -f "$WT12/build/out.js"
FIX12_RC=0; ( eval "$CMD12" ) >"$TMPROOT/fix12.out" 2>&1 || FIX12_RC=$?
check "18. …and following it verbatim clears the condition" \
  "[ '$FIX12_RC' = '0' ] && [ \"\$(sha '$r12' 'refs/heads/lcars/$MID')\" = \"\$(sha '$r12' refs/heads/main)\" ]"

# --- Behaviour 19: a DEAD worktree registration is named, not thrashed ------
# `git branch -f` refuses a branch registered as checked out even when that
# worktree's directory is gone — verified — so this needs its own sentence and its
# own fix rather than git's bare "cannot force update the branch".
r13="$TMPROOT/d13"
git init -q "$r13"
( cd "$r13" && git config user.email t@t && git config user.name t && git checkout -q -b main \
    && echo a >a.txt && git add -A && git commit -q -m1 && git branch "lcars/$MID" \
    && echo b >b.txt && git add -A && git commit -q -m2 ) >/dev/null 2>&1
git -C "$r13" worktree add -q "$TMPROOT/d13.wt" "lcars/$MID" 2>/dev/null
rm -rf "$TMPROOT/d13.wt"
BEFORE_MB13="$(sha "$r13" "refs/heads/lcars/$MID")"
adv "$r13" "lcars/$MID" main
check "19. the branch was NOT moved" \
  "[ \"\$(sha '$r13' 'refs/heads/lcars/$MID')\" = '$BEFORE_MB13' ]"
check "19. the refusal names the dead registration in plain words" \
  "grep -qi 'no longer there' '$r13.adv.out'"
check "19. it does NOT claim a move" "! grep -q '✓ MISSION BRANCH' '$r13.adv.out'"
FIX13="$(fixline "$r13.adv.out")"
check "19. the Fix: is 'git worktree prune'" "[ \"\$FIX13\" = 'git worktree prune' ]"
FIX13_RC=0; ( cd "$r13" && eval "$FIX13" ) >/dev/null 2>&1 || FIX13_RC=$?
check "19. …running it succeeds" "[ '$FIX13_RC' = '0' ]"
adv "$r13" "lcars/$MID" main
check "19. …and the very next drive then fast-forwards it, exactly as promised" \
  "[ \"\$(sha '$r13' 'refs/heads/lcars/$MID')\" = \"\$(sha '$r13' refs/heads/main)\" ] && grep -q '✓ MISSION BRANCH' '$r13.adv.out'"

# --- Behaviour 20: a drive taken MID-OPERATION moves nothing ---------------
# S160 round 2, D2. A tester pasted the `diverged` fix (`git pull --rebase origin
# main`), hit a conflict — the COMMON outcome for a diverged branch — and worked
# on from there. Mid-rebase, `refs/heads/main` is where the operation will move
# it FROM: fast-forwarding the mission branch onto it would aim at a commit that
# is about to stop existing, and the base's own verdict already says nothing was
# measured. So the drive reads that blocker and declines to move any ref.
r14="$(make_fixture d14)"
prd14="$TMPROOT/prd14.md"; write_prd "$prd14"
file_mission "$r14" --prd "$prd14"
advance_origin d14 1
( cd "$r14" && mkdir -p src && printf 'captain line\n' >>src/real-view.txt \
    && git add -A && git commit -q -m "the captain's own commit" ) >/dev/null 2>&1
( cd "$r14" && git pull --rebase origin main ) >"$r14.rebase.out" 2>&1
BEFORE_MB14="$(sha "$r14" "refs/heads/lcars/$MID")"
BEFORE_MAIN14="$(sha "$r14" refs/heads/main)"
check "20. the fixture really is mid-rebase" \
  "( cd '$r14' && [ -e \"\$(git rev-parse --git-path rebase-merge)\" ] )"
drive "$r14" "$MID" --step
M14="$(mdir "$r14")"
check "20. the drive records the unfinished operation, not a staleness verdict" \
  "[ \"\$(sf '$M14/state.json' baseFreshness.blocker)\" = 'operation-in-progress' ]"
check "20. …as 'unknown' — nothing could honestly be measured" \
  "[ \"\$(sf '$M14/state.json' baseFreshness.verdict)\" = 'unknown' ]"
# JSON null — `sf` renders it "None". NOT a sha: naming a commit the Mission was
# not cut from is the permanent wrong provenance record D2 is about.
check "20. …with a NULL baseSha, never a commit the Mission was not cut from" \
  "[ \"\$(sf '$M14/state.json' baseFreshness.baseSha)\" = 'None' ]"
check "20. the MISSION BRANCH was not moved" \
  "[ \"\$(sha '$r14' 'refs/heads/lcars/$MID')\" = '$BEFORE_MB14' ]"
check "20. the base was not moved either" \
  "[ \"\$(sha '$r14' refs/heads/main)\" = '$BEFORE_MAIN14' ]"
check "20. and no MISSION BRANCH claim of either voice is printed" \
  "! grep -q 'MISSION BRANCH' '$r14.drive.out'"
check "20. the unfinished rebase is exactly where the captain left it" \
  "( cd '$r14' && [ -e \"\$(git rev-parse --git-path rebase-merge)\" ] )"
check "20. no base_stale event claims a staleness that was never measured" \
  "[ \"\$(ev_count '$M14/events.jsonl' base_stale)\" = '0' ]"

# --- Behaviour 21: a refused MISSION BRANCH still leaves a way forward -----
# S160 round 3, D1. A tester's mission branch was checked out CLEAN and 2 behind
# — the lane that normally advances in place (behaviour 11) — but the repo had
# `merge.verifySignatures=true`, so git refused the local fast-forward. LCARS
# recorded that honestly through the recorder with no `fix` slot (round 2's cure
# for offering back an operation it had already watched fail) and the captain
# read `Why:` / `Means:` / `Impact:` and NOTHING ELSE: a correct diagnosis with
# no hint that clearing git's objection was theirs to do.
#
# The base's own step-9 sibling has carried exactly those words as a `fixNote`
# since round 2. This lane just never got them. The cure is structural — the
# recorder writes the note — so no future refusal lane can ship the dead end by
# forgetting.
r15="$(make_fixture d15)"; prd15="$TMPROOT/prd15.md"; write_prd "$prd15"
file_mission "$r15" --prd "$prd15"
M15="$(mdir "$r15")"; MB15="lcars/$MID"
WT15="$TMPROOT/d15.wt"
git -C "$r15" worktree add -q "$WT15" "$MB15" 2>/dev/null
advance_origin d15 2
# THE BASE IS BROUGHT UP FIRST, BEFORE the config lands. `merge.verifySignatures`
# refuses EVERY unsigned fast-forward in this clone, the base's own included —
# and a base that never moves leaves the mission branch level with it, so the
# mission-branch lane would not run at all and the fixture would prove nothing.
# The situation being reproduced is a CURRENT base with a mission branch behind
# it, which is behaviour 11's lane exactly.
( cd "$r15" && git fetch -q origin main && git merge -q --ff-only origin/main ) >/dev/null 2>&1
BEFORE_MB15="$(sha "$r15" "refs/heads/$MB15")"
ORIGIN_TIP15="$(sha "$TMPROOT/d15.git" refs/heads/main)"
# The tester's own configuration. It lives in the clone's config file, which a
# linked worktree shares — so the merge attempted INSIDE the worktree is the one
# it refuses.
( cd "$r15" && git config merge.verifySignatures true ) >/dev/null 2>&1
check "21. the base is already CURRENT — only the mission branch is behind" \
  "[ \"\$(sha '$r15' refs/heads/main)\" = '$ORIGIN_TIP15' ] \
   && [ \"\$(git -C '$r15' rev-list --count '$MB15..main')\" = '2' ]"
check "21. the mission branch is checked out CLEAN — behaviour 11's lane" \
  "[ \"\$(git -C '$WT15' symbolic-ref --short HEAD)\" = '$MB15' ] \
   && [ -z \"\$(git -C '$WT15' status --porcelain)\" ]"
drive "$r15" "$MID" --step
check "21. the drive exits 0 (a refusal never blocks)" "[ \"\$(cat '$r15.drive.rc')\" = '0' ]"
check "21. the mission branch was NOT moved" \
  "[ \"\$(sha '$r15' 'refs/heads/$MB15')\" = '$BEFORE_MB15' ]"
check "21. the refusal is LOUD" "grep -q '⚠ MISSION BRANCH' '$r15.drive.out'"
check "21. git really did refuse the fast-forward (the lane is the one we mean)" \
  "grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -qi 'signature'"
# THE DEFECT, stated as the assertion. No `Fix:` — the merge LCARS just ran is
# not its own remedy — but a `Note:` the captain can act on. Every assertion is
# scoped to the MISSION BRANCH block: the BASE's own step-9 lane says nearly the
# same words, and an unscoped grep would pass on the sibling that was never
# broken.
check "21. NO Fix: is offered — the refused merge is not its own remedy" \
  "! grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -q 'Fix:'"
check "21. …but the way forward SURVIVES, as an unlabelled Note" \
  "grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -q 'Note:'"
check "21. …in the base lane's own voice: clear what git objected to" \
  "grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -q 'Clear whatever git objected to'"
check "21. …and it says plainly that no command exists here" \
  "grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -q 'there is no command LCARS can offer'"
check "21. …naming the branch that will then fast-forward" \
  "grep -A6 '⚠ MISSION BRANCH' '$r15.drive.out' | grep -q '$MB15 fast-forwards on the next drive'"
check "21. it does NOT claim a move" "! grep -q '✓ MISSION BRANCH' '$r15.drive.out'"
check "21. missionBranchAtBase is FALSE — no move is reported that did not happen" \
  "[ \"\$(sf '$M15/state.json' baseFreshness.missionBranchAtBase)\" = 'False' ]"
# And the note is TRUE, not just present: clear git's objection and the very
# next drive really does fast-forward it — the promise the words make, measured.
( cd "$r15" && git config --unset merge.verifySignatures ) >/dev/null 2>&1
adv "$r15" "$MB15" main
check "21. …and clearing the objection makes the promise come true" \
  "[ \"\$(sha '$r15' 'refs/heads/$MB15')\" = \"\$(sha '$r15' refs/heads/main)\" ] \
   && grep -q '✓ MISSION BRANCH' '$r15.adv.out'"

# ==========================================================================
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
