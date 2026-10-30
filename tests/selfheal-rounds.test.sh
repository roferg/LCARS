#!/usr/bin/env bash
# =============================================================================
# tests/selfheal-rounds.test.sh — S310: A SELF-HEAL ROUND IS SPENT ON DEFECTS,
# NOT ON INFRASTRUCTURE.
# =============================================================================
# Fast, SCOPED, zero-token: real `skills/lcars-run/run.sh`, real git repos built
# by tests/fixtures/mkflatrepo.sh (flat tests/, local BARE REMOTE so `main` can
# be advanced under a mission branch with `--advance-base`), real node runner.
# The worker is a PURE-FAKE shim scripted to SUCCEED, so the only thing that can
# fail is the harness's own accounting. No model is ever called, and this suite
# asserts that by counting the shim's own invocations.
#
#   *** FORK-BOMB HAZARD. The shims here are pure fakes: they print, write
#   their scripted artifacts and exit. They NEVER resolve, exec or delegate to
#   a real `claude` / `copilot` — on this machine `command -v copilot` is VS
#   Code's own shim, which re-invokes `copilot` BY NAME (5,538 processes, ~8
#   hours of an overnight run, 2026-09-15). See tests/lib/real-worker.sh. ***
#
# THE DEFECT THIS SUITE PINS (measured on a live repo, 2026-10-22). One ticket
# burned THREE self-heal rounds, FIVE worker sessions and ~2.5 hours on a
# regression that did not exist:
#
#   07:24  round 1/3 — "regression attributed to <ticket>"
#   08:26  round 2/3 — "authored-failing-suite"
#   08:52  "ticket green after 4 worker sessions", THEN
#          "self-heal round 2: the rebuilt commit did not land cleanly"
#   09:56  "ticket green after 5 worker sessions", THEN
#          "self-heal round 3: the rebuilt commit did not land cleanly"
#   10:14  branch rebased onto current main — 12 commits, no conflicts
#   10:20  full suite on the rebased branch: 1721 tests OK, 0 FAIL
#
# The branch was green the whole time. The base moved THREE times during the
# self-heal and the branch ended NINE commits behind, so each round rebuilt
# against a base that was already stale and the commit would not apply. Rounds
# 2 and 3 reported the ticket GREEN immediately before failing: the WORK
# succeeded, only the APPLY failed — and the round was already SPENT, because
# `round=$((round + 1))` is the second line of the loop body and the
# apply-failure emit is later in the same iteration.
#
# Behaviours, in the order the session declared them:
#   1. a round whose rebuild fails to APPLY leaves the round counter UNCHANGED
#      and is recorded as an apply failure, not a regression
#   2. that event's text attributes no defect to the ticket
#   3. a round rebuilds against the branch tip AS IT IS at the start of that
#      round — and records which tip that was
#   4. advancing the fixture's base between rounds no longer produces
#      "did not land cleanly"
#   5. an attributed failing set that is GREEN at the current tip dispatches NO
#      worker, and the stale attribution is recorded
#   6. a working branch behind its base merges automatically (S336); unsafe
#      recovery still REFUSES a round and names the blocker
#   7. two rounds with two different failure modes escalate WITH THAT FACT
#      stated
#
# Usage: bash tests/selfheal-rounds.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
MKFLAT="$REPO_ROOT/tests/fixtures/mkflatrepo.sh"
MID=m-001

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; }

# Teardown through a FILE, not a variable: mkrig is called in a command
# substitution, so anything it assigns to a shell variable dies with that
# subshell — which is exactly how a suite silently leaks throwaway git repos
# into $TMPDIR and corrupts a later measurement.
BASEFILE="$(mktemp "${TMPDIR:-/tmp}/lcars-selfheal-bases.XXXXXX")"
cleanup() {
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    # Any worktree this rig attached to a mission branch must be unregistered
    # before the tree is removed, or `git worktree prune` has nothing to find.
    [ -d "$b/repo" ] && git -C "$b/repo" worktree prune >/dev/null 2>&1
    rm -rf "$b"
  done <"$BASEFILE"
  rm -f "$BASEFILE"
}
trap cleanup EXIT

echo "S310 — a self-heal round is spent on defects, not on infrastructure"
[ -f "$RUN_SH" ] || { echo "run.sh not found at $RUN_SH"; exit 1; }
[ -f "$MKFLAT" ] || { echo "fixture builder not found at $MKFLAT"; exit 1; }
command -v node   >/dev/null 2>&1 || { echo "node is required for this suite"; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required for this suite"; exit 1; }

# ===========================================================================
# THE RIG. mkflatrepo.sh gives the repo, the local BARE REMOTE (so `main` can
# be advanced under the mission branch on demand) and the pure-fake worker
# shims; this adds the two-ticket self-heal mission on top of it.
#
# `main` holds ONLY the base. The tickets' work sits on `lcars/m-001`, so the
# mission branch always carries commits OF ITS OWN — so advancing its base
# requires a merge, never a pointer fast-forward, i.e. the live shape.
# ===========================================================================
mkrig() { # → base dir (recorded for teardown)
  local base repo m
  base="$(bash "$MKFLAT" --files 1 --sleep 0 --tip none 2>/dev/null)"
  printf '%s\n' "$base" >>"$BASEFILE"
  repo="$base/repo"
  m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m/tickets/t-001" "$m/tickets/t-002"
  printf '# ctx\n' >"$repo/CONTEXT.md"   # pre-seeded → no context-pack spawn

  # ONE FIELD PER LINE, `{` and `}` alone: that is the only shape LCARS's own
  # line-oriented state writer will touch, and a compact object makes every
  # escalation REFUSE to park the mission (it cost this suite its second run).
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "selfheal accounting",
  "stage": "implement",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "main"
}
EOF
  # The EXPANDED shape, one field per line: parse_waves_table / ticket_issue are
  # line-oriented readers, so a compact one-line object parses as the literal
  # key names (it cost this suite its first run).
  cat >"$m/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 101
      },
      {
        "id": "t-002",
        "issue": 102
      }
    ]
  }
]
JSON
  cat >"$m/approved-plan.json" <<'JSON'
{ "tickets": [
  { "id": "t-001", "title": "one", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" },
  { "id": "t-002", "title": "two", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" } ] }
JSON

  # The base commit carries only CONTEXT.md on top of mkflatrepo's parent.
  ( cd "$repo" && git add -A && git commit -qm "base: context" && git push -q origin main )
  ( cd "$repo" && git branch "lcars/$MID" && git checkout -q "lcars/$MID" )
  # NB: the checkout returns to `main` at the end of this function. The repo's
  # own checkout must NOT hold the mission branch, or the landing worktree can
  # never be attached and EVERY apply fails — which is section 1's deliberate
  # condition, not the default one.

  # EACH TICKET'S TEST HANGS OFF ITS OWN SOURCE FILE, and nothing else. A
  # ticket's redness is therefore a property of the REPO at a commit, which is
  # what the flip-flop gate measures (red on the parent, green on the tip) — an
  # out-of-repo switch would be identical on both legs and no rebuild could ever
  # pass that gate, so no commit would ever exist for an apply to fail on.
  # src/b.js starts BROKEN: t-002 is the regression the gate finds.
  printf 'exports.ok = () => true;\n'  >"$repo/src/a.js"
  printf 'exports.ok = () => false;\n' >"$repo/src/b.js"
  cat >"$repo/tests/t-001.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { ok } = require('../src/a.js');
test('t-001 contract', () => { assert.strictEqual(ok(), true); });
JS
  cat >"$repo/tests/t-002.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { ok } = require('../src/b.js');
test('t-002 contract', () => { assert.strictEqual(ok(), true); });
JS
  local i
  for i in 001 002; do
    printf '%s  tests/t-%s.test.js\n' \
      "$(shasum -a 256 "$repo/tests/t-$i.test.js" | awk '{print $1}')" "$i" \
      >"$m/tickets/t-$i/proof-tests.sha256"
    cat >"$m/tickets/t-$i/result.json" <<JSON
{ "ticketId": "t-$i", "passed": true, "attempts": 1, "summary": "s",
  "newTests": ["tests/t-$i.test.js"], "testEdits": [], "flipFlop": "expected" }
JSON
  done
  ( cd "$repo" && git add -A && git commit -qm "t-001 + t-002: the mission's work" \
      && git checkout -q main )

  printf '#!/usr/bin/env bash\nexit 0\n' >"$base/gh"; chmod +x "$base/gh"
  : >"$base/dispatch.log"
  printf '%s' "$base"
}

# The PURE-FAKE self-heal worker. One line per invocation in dispatch.log — the
# COUNT is the proof that a worker ran or did not — carrying the worktree HEAD it
# was handed and the attribution its prompt arrived with. The HEAD is how "it
# rebuilt against the tip as it is NOW" is measured from the outside, rather than
# read off a log line the harness wrote about itself.
#
# It repairs the source file the ATTRIBUTED ticket's own test hangs off, so the
# rebuild is red on the parent and green on the tip and a real commit exists for
# the apply to succeed or fail on. $RIG_TOGGLE additionally breaks the OTHER
# ticket's source file, so the full-suite gate goes red again on a DIFFERENT
# owner — an unhealable regression whose failure mode CHANGES each round, which
# is the shape behaviour 7 is about. No test file is ever touched, so the
# undeclared-drift gate has nothing to refuse.
mkworker() { # base
  local base="$1"
  cat >"$base/worker" <<'STUB'
#!/usr/bin/env bash
# PURE FAKE worker (S310 rig). Scripted output only. It NEVER resolves, execs
# or delegates to a real `claude` / `copilot` — that is a fork bomb.
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="${2:-}"; shift 2 ;; *) shift ;; esac; done
att="$(printf '%s' "$prompt" | sed -n 's/.*ATTRIBUTION: \(t-[0-9]*\).*/\1/p' | head -1)"
printf '%s\trole=%s\thead=%s\tatt=%s\n' \
  "$(date -u +%FT%TZ)" "${LCARS_WORKER_ROLE:-}" \
  "$(git rev-parse HEAD 2>/dev/null)" "$att" >>"${RIG_DISPATCH_LOG:?}"
[ "${LCARS_WORKER_ROLE:-}" = implement-tdd ] || exit 0
# $RIG_WORKER_CRASH / $RIG_WORKER_SILENT: the worker produces NO RESULT. Still
# pure fakes — they just stop. CRASH is the loud shape (exit 1, no result.json,
# no commit); SILENT is the commonest real engine failure (exit 0, prints
# nothing, writes nothing: an auth lapse, a rate limit, an empty completion).
# Neither writes a ticket_flagged and neither writes a ticket_green, which is
# the third state the parked exit could not see.
[ -n "${RIG_WORKER_CRASH:-}"  ] && exit 1
[ -n "${RIG_WORKER_SILENT:-}" ] && exit 0
case "$att" in
  t-001) mine=src/a.js; theirs=src/b.js; rel=../src/a.js ;;
  *)     mine=src/b.js; theirs=src/a.js; rel=../src/b.js; att=t-002 ;;
esac
n="$(grep -c 'role=implement-tdd' "$RIG_DISPATCH_LOG" 2>/dev/null || echo 1)"
# $RIG_WORKER_BAD: the worker reports success and repairs NOTHING, so the proof
# gates cannot believe it (its own test is red on the parent AND on the tip) and
# the ticket legitimately burns its own worker-session cap — the everyday "the
# reconcile ticket couldn't do it" outcome section 11 is about.
if [ -z "${RIG_WORKER_BAD:-}" ]; then
  printf 'exports.ok = () => true;\n' >"$mine"
  [ "${RIG_TOGGLE:-0}" = 1 ] && printf 'exports.ok = () => false;\n' >"$theirs"
fi
# S320 / D18 — $RIG_WORKER_NEWTEST: the worker writes a NEW regression test file
# OF ITS OWN instead of restating the ticket's, declares it in `newTests`, and
# never touches the ticket's existing test. Every proof gate is satisfied
# HONESTLY (red on the parent where $mine is broken, green on the tip, declared,
# a new test file in the diff) — this is not a cheat, it is what a real model
# spontaneously did on 2026-10-22. The consequence is the whole point: the
# ticket's proof-tests snapshot is REWRITTEN to name a file that exists only in
# this rebuild, so if the rebuild never lands, the full-suite gate has no file
# to re-run for that ticket and SKIPS it — going green over a branch whose own
# test still exits 1.
if [ -n "${RIG_WORKER_NEWTEST:-}" ]; then
  cat >"tests/$att-regression.test.js" <<JS
const { test } = require('node:test');
const assert = require('node:assert');
const { ok } = require('$rel');
// reconcile pass $n — a NEW regression guard, declared with its reason.
test('$att regression guard', () => { assert.strictEqual(ok(), true); });
JS
  [ -n "${RIG_AFTER_WORKER:-}" ] && bash -c "$RIG_AFTER_WORKER" >/dev/null 2>&1
  # DECLARED THE SAME WAY the restating worker above declares its file — in
  # `testEdits`, WITH A REASON. That is what the harness's own contract asks for
  # and it is the declaration channel the pre-merge drift check reads
  # (mission_declared_edit_paths globs test-edits.json; `newTests` is NOT in it).
  # It matters: with the file declared only under `newTests`, an unlanded
  # rebuild makes the full-suite gate see an UNDECLARED drift and `die` LOUDLY —
  # wrong, but honest. Declared here, the drift is forgiven, the file is simply
  # absent, the ticket is SKIPPED, and the gate goes green over a broken branch.
  cat >"${LCARS_WORK_OUT:?}/result.json" <<JSON
{ "ticketId": "$att", "passed": true, "attempts": 1,
  "summary": "reconcile: repaired $mine and added a regression guard of its own",
  "newTests": [],
  "testEdits": [ { "path": "tests/$att-regression.test.js", "reason": "new regression guard for the break in $mine" } ],
  "flipFlop": "expected" }
JSON
  exit 0
fi
# An HONEST restatement of the ticket's own test — same assertion, same test
# count, DECLARED. The quality floor requires a new or changed test file in the
# diff, and the flip-flop gate then has something to prove: red on the parent
# (where $mine is still broken), green on the tip.
cat >"tests/$att.test.js" <<JS
const { test } = require('node:test');
const assert = require('node:assert');
const { ok } = require('$rel');
// reconcile pass $n — the assertion is unchanged, restated.
test('$att contract', () => { assert.strictEqual(ok(), true); });
JS
[ -n "${RIG_AFTER_WORKER:-}" ] && bash -c "$RIG_AFTER_WORKER" >/dev/null 2>&1
cat >"${LCARS_WORK_OUT:?}/result.json" <<JSON
{ "ticketId": "$att", "passed": true, "attempts": 1,
  "summary": "reconcile: repaired $mine and restated the ticket's own test",
  "newTests": [],
  "testEdits": [ { "path": "tests/$att.test.js", "reason": "restated unchanged — the break was in $mine" } ],
  "flipFlop": "expected" }
JSON
exit 0
STUB
  chmod +x "$base/worker"
}

# The test command. One scope per invocation (S308 scopes a proof leg to the
# ticket's declared files, so $LCARS_TESTS_DIR may be a FILE). $T2_ONESHOT
# clears the red flag AFTER t-002's suite has run once, which makes the gate
# red exactly once and every later run of that same suite green.
# The test command. One scope per invocation (S308 scopes a proof leg to the
# ticket's declared files, so $LCARS_TESTS_DIR may be a FILE).
#
# $T2_ONESHOT is a path: the FIRST run of t-002's suite creates it and reports
# RED, every later run reports the truth. That is how a regression the gate
# genuinely found can already be absent by the time the self-heal looks at the
# tip — the live shape — without touching one tracked blob.
#
# $RIG_FLAP is a FLAPPING suite: it passes when it is re-run on its own (the
# narrow re-check, which runs in selfheal-recheck-wt) and fails in the
# full-suite gate at the same tip. That is the contradiction the harness refuses
# to spend a round guessing about. $RIG_FLAP_WIDEN additionally pulls t-001 into
# the gate's failing set from the second gate run on, so the failing set CHANGES
# and the loop reaches the stale-attribution cap instead of the contradiction.
RIG_CMD='scope="$LCARS_TESTS_DIR"; rc=0
if [ -d "$scope" ]; then node --test "$scope"/*.test.js || rc=$?; else node --test "$scope" || rc=$?; fi
if [ -n "${T2_ONESHOT:-}" ]; then
  case "$scope" in *t-002*) if [ ! -f "$T2_ONESHOT" ]; then : >"$T2_ONESHOT"; rc=1; fi ;; esac
fi
if [ -n "${RIG_FLAP:-}" ]; then
  case "$PWD" in
    *selfheal-recheck-wt*) rc=0 ;;
    *) case "$scope" in
         *t-002*) rc=1; [ -n "${RIG_FLAP_WIDEN:-}" ] && : >"$RIG_FLAP" ;;
         *t-001*) if [ -n "${RIG_FLAP_WIDEN:-}" ] && [ -f "$RIG_FLAP" ]; then rc=1; fi ;;
       esac ;;
  esac
fi
exit $rc'

# Drive the REAL impl-advance → full_suite_gate → self_heal_full_suite line.
drive() { # base [env-pairs…] → DRIVE_OUT / DRIVE_RC
  local base="$1"; shift
  DRIVE_RC=0
  DRIVE_OUT="$( cd "$base/repo" && env PATH="$base/shim:$PATH" \
      RIG_DISPATCH_LOG="$base/dispatch.log" \
      LCARS_WORKER_BIN="$base/worker" LCARS_WORKER_CLI=claude \
      LCARS_TEST_CMD="$RIG_CMD" LCARS_GH_BIN="$base/gh" LCARS_NOTIFY=true \
      LCARS_GATE_TIMEOUT=60 "$@" \
      bash "$RUN_SH" impl-advance --mission "$MID" 2>&1 )" || DRIVE_RC=$?
}

ev_of()     { printf '%s' "$1/repo/.git/lcars/missions/$MID/events.jsonl"; }
ledger_of() { printf '%s' "$1/repo/.git/lcars/missions/$MID/selfheal-ledger.json"; }
tdlog()     { grep -c 'role=implement-tdd' "$1/dispatch.log" 2>/dev/null | tr -d ' '; }
# One field out of the self-heal ledger — the harness's OWN record of the
# round counter, read off disk, never off a variable this suite set.
led() { # base key
  "${LCARS_PYTHON_BIN:-python3}" - "$(ledger_of "$1")" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))
PY
}

# The TWO surfaces a human actually reads. Self-heal events have never been
# rendered anywhere (not even the long-standing selfheal_exhausted), so a story
# that reaches only events.jsonl does not reach him: it is stdout, and the
# `pendingQuestion` that `lcars answer` and the board replay back later.
pq() { # base → the mission's pendingQuestion, off disk
  "${LCARS_PYTHON_BIN:-python3}" - "$1/repo/.git/lcars/missions/$MID/state.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
sys.stdout.write(str(d.get("pendingQuestion", "")))
PY
}
# The FIRST line he reads.
headline() { printf '%s\n' "$1" | grep '^IMPLEMENT:' | head -1; }

# S320: GROUND TRUTH, READ AT THE BRANCH TIP — never off a harness claim. The
# whole D18 defect is that `selfheal_ok` was not evidence of anything, so every
# assertion about whether the branch is actually repaired reads git, or runs the
# ticket's own test by hand in a throwaway DETACHED worktree at that tip (a
# detached cut works even while something else holds the branch, which is the
# condition that makes the apply fail in the first place).
sfield() { # base field → state.json field, off disk
  "${LCARS_PYTHON_BIN:-python3}" - "$1/repo/.git/lcars/missions/$MID/state.json" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))
PY
}
tip_blob() { # base relpath → the file's content AT THE BRANCH TIP (empty if absent)
  git -C "$1/repo" show "lcars/$MID:$2" 2>/dev/null
}
tip_has() { # base relpath → 0 when the path exists at the branch tip
  git -C "$1/repo" cat-file -e "lcars/$MID:$2" 2>/dev/null
}
handrun() { # base relpath → the rc of running that test BY HAND at the branch tip
  # `local` expands ALL of its arguments before it assigns any of them, so $wt
  # cannot be derived from $b on the same line (set -u kills the suite).
  local b="$1" rel="$2" rc=0 wt
  wt="$b/handcheck"
  rm -rf "$wt"
  git -C "$b/repo" worktree add -q --detach "$wt" "lcars/$MID" >/dev/null 2>&1 || return 99
  ( cd "$wt" && node --test "$rel" >/dev/null 2>&1 ) || rc=$?
  git -C "$b/repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$b/repo" worktree prune >/dev/null 2>&1 || :
  return "$rc"
}

# ===========================================================================
# 0. THE PRODUCT WORKS AT ALL: a real self-heal runs on this fixture and its
#    round counter moves. Nothing below means anything if this does not hold.
# ===========================================================================
echo "-- 0. a self-heal runs at all, and the round counter moves --"
B0="$(mkrig)"; mkworker "$B0"
drive "$B0" LCARS_SELFHEAL_CAP=2 RIG_TOGGLE=1
grep -q '"type":"selfheal"' "$(ev_of "$B0")" 2>/dev/null \
  && ok "0a. the full-suite gate went red and a self-heal started" \
  || bad "0a. no self-heal event: $(printf '%s' "$DRIVE_OUT" | tail -3)"
[ "$(grep -c 'self-heal round' "$(ev_of "$B0")" 2>/dev/null | tr -d ' ')" = 2 ] \
  && ok "0b. an unhealable regression spends exactly LCARS_SELFHEAL_CAP=2 rounds" \
  || bad "0b. expected 2 'self-heal round' events, got $(grep -c 'self-heal round' "$(ev_of "$B0")" 2>/dev/null)"
# …AND a budget genuinely spent on defects must still read as exhausted. The
# S310 fix-round headline is keyed on the stop reason, so this is the control
# that keeps the true case true (sections 8–11 are the false ones).
case "$(headline "$DRIVE_OUT")" in
  *"self-heal exhausted"*) ok "0c. a budget really spent on defects still reads as exhausted" ;;
  *) bad "0c. a genuine cap exhaustion no longer says so: $(headline "$DRIVE_OUT")" ;;
esac
[ "$(led "$B0" roundsSpent)" = 2 ] \
  && ok "0c. the harness's own ledger records roundsSpent=2" \
  || bad "0c. ledger roundsSpent='$(led "$B0" roundsSpent)' (cap='$(led "$B0" cap)')"
# Each defect round re-dispatches implement-ticket, which spends up to its OWN
# three worker sessions — so two rounds are >=2 invocations, not exactly 2.
# (That ratio is why the live run read "green after 5 worker sessions".)
[ "$(tdlog "$B0")" -ge 2 ] 2>/dev/null \
  && ok "0d. the defect rounds really dispatched workers ($(tdlog "$B0")), counted not inferred" \
  || bad "0d. expected >=2 implement-tdd dispatches, got '$(tdlog "$B0")'"
[ ! -s "$B0/worker-calls.log" ] \
  && ok "0e. ZERO model spend — mkflatrepo's claude/copilot shims were never invoked" \
  || bad "0e. a model shim was invoked: $(cat "$B0/worker-calls.log")"

# A healing worker clears the regression and the mission advances.
echo "-- 0f. a self-heal that works still heals --"
B0b="$(mkrig)"; mkworker "$B0b"
drive "$B0b" LCARS_SELFHEAL_CAP=3
grep -q '"type":"selfheal_ok"' "$(ev_of "$B0b")" 2>/dev/null \
  && ok "0f. a repaired regression emits selfheal_ok" \
  || bad "0f. no selfheal_ok: $(grep -o '"type":"selfheal[a-z_]*"' "$(ev_of "$B0b")" 2>/dev/null | tr '\n' ' ')"

# ===========================================================================
# 1 + 2. AN APPLY FAILURE IS INFRASTRUCTURE, NOT A DEFECT ROUND.
#
#    The apply is made to fail the way it really fails: something else HOLDS
#    the mission branch, so the landing worktree cannot be attached to it.
#    The worker still succeeds — it is built and green, exactly as the live
#    run reported immediately before each "did not land cleanly".
# ===========================================================================
echo "-- 1+2. an apply failure spends no round and blames no ticket --"
B1="$(mkrig)"; mkworker "$B1"
# Hold the mission branch in a second worktree: `git worktree add <path>
# <branch>` is then refused for the landing tree, which is REPLAY_FAIL_REASON's
# own documented "branch is checked out at …" case.
git -C "$B1/repo" worktree add -q "$B1/holder" "lcars/$MID" >/dev/null 2>&1
HOLD_RC=$?
if [ "$HOLD_RC" -ne 0 ] || [ ! -d "$B1/holder" ]; then
  skip "1: could not hold the mission branch in a second worktree — SKIPPING"
else
  drive "$B1" LCARS_SELFHEAL_CAP=3 RIG_TOGGLE=1
  EV1="$(ev_of "$B1")"
  # Did the scenario reproduce at all? Either the OLD signature or the new
  # event must be there; neither means the rig produced no apply failure and
  # every assertion below would be vacuous.
  grep -qE 'did not land cleanly|"type":"selfheal_apply_failed"' "$EV1" 2>/dev/null \
    && ok "1-pre. the rig really did produce an apply failure (the work is green, the apply is not)" \
    || bad "1-pre. NO apply failure occurred — the scenario did not reproduce; every check below is vacuous"
  # The worker DID run and DID produce a commit — only the apply failed.
  [ "$(tdlog "$B1")" -ge 1 ] 2>/dev/null \
    && ok "1a. the worker ran (the work succeeded; only the apply can fail here)" \
    || bad "1a. no worker was dispatched at all: $(printf '%s' "$DRIVE_OUT" | tail -3)"
  grep -q '"type":"selfheal_apply_failed"' "$EV1" 2>/dev/null \
    && ok "1b. the outcome is recorded as an APPLY FAILURE, by its own event name" \
    || bad "1b. no selfheal_apply_failed event: $(grep -o '"type":"selfheal[a-z_]*"' "$EV1" 2>/dev/null | sort -u | tr '\n' ' ')"
  # THE COUNTER ITSELF, read off the harness's own record on disk.
  [ "$(led "$B1" applyFailures)" -ge 1 ] 2>/dev/null \
    && ok "1c. the ledger counts the apply failure(s): $(led "$B1" applyFailures)" \
    || bad "1c. ledger applyFailures='$(led "$B1" applyFailures)'"
  [ "$(led "$B1" roundsSpent)" = 0 ] \
    && ok "1d. and roundsSpent is STILL 0 — the defect budget was not touched" \
    || bad "1d. an apply failure SPENT a round: roundsSpent='$(led "$B1" roundsSpent)'"
  # The STOP's own record, in its data fields — not in prose anyone can read
  # two ways. "round 3/3" over a stack of apply failures is the exact reading
  # that cost the live run two and a half hours.
  STOP1="$(grep -E '"type":"selfheal_(exhausted|blocked)"' "$EV1" 2>/dev/null | tail -1)"
  case "$STOP1" in
    *'"roundsSpent":0'*) ok "1e. the stop event records roundsSpent 0 — no defect round was spent" ;;
    *) bad "1e. the stop event does not carry roundsSpent 0: $(printf '%s' "$STOP1" | cut -c1-240)" ;;
  esac
  case "$STOP1" in
    *"WITHOUT exhausting"*|*"not on the code"*) ok "1e2. …and says the budget was not what ran out" ;;
    *) bad "1e2. the stop still reads as an exhausted defect budget: $(printf '%s' "$STOP1" | cut -c1-240)" ;;
  esac
  # BEHAVIOUR 2: the apply-failure event text blames no ticket.
  APPLY_LINE="$(grep '"type":"selfheal_apply_failed"' "$EV1" 2>/dev/null | head -1)"
  case "$APPLY_LINE" in
    *"attributed to"*) bad "2a. the apply-failure event still attributes a defect: $APPLY_LINE" ;;
    *) ok "2a. the apply-failure event does NOT say a regression was attributed to the ticket" ;;
  esac
  case "$APPLY_LINE" in
    *"not a defect"*) ok "2b. it says plainly that this is not a defect in the ticket" ;;
    *) bad "2b. the apply-failure event does not say what it is NOT: $APPLY_LINE" ;;
  esac
  case "$APPLY_LINE" in
    *"self-heal round"*) bad "2c. the apply-failure event is counted as a round in the timeline: $APPLY_LINE" ;;
    *) ok "2c. it is not phrased as a spent 'self-heal round'" ;;
  esac
  # The budget survives repetition: three apply failures, cap untouched.
  [ "$(led "$B1" applyFailures)" -ge 3 ] 2>/dev/null \
    && ok "1f. three apply failures in a row still spend ZERO of the 3-round cap" \
    || skip "1f. only $(led "$B1" applyFailures) apply failure(s) occurred (roundsSpent=$(led "$B1" roundsSpent))"
  git -C "$B1/repo" worktree remove --force "$B1/holder" >/dev/null 2>&1
fi

# ===========================================================================
# 3. EVERY ROUND RE-ANCHORS TO THE BRANCH TIP AS IT IS AT THE START OF THAT
#    ROUND — and records which tip that was, so the claim is auditable.
#    The rig moves the mission branch underneath the self-heal between rounds
#    (RIG_AFTER_WORKER), which is what the live run's base advances did.
# ===========================================================================
echo "-- 3. a round re-anchors to the tip as it is NOW --"
B3="$(mkrig)"; mkworker "$B3"
# Each round's rebuild LANDS, so the tip genuinely moves between rounds — which
# is the condition the live run's rounds were blind to.
drive "$B3" LCARS_SELFHEAL_CAP=2 RIG_TOGGLE=1
EV3="$(ev_of "$B3")"
grep -q '"type":"selfheal_reanchor"' "$EV3" 2>/dev/null \
  && ok "3a. each round records the tip it re-anchored to (selfheal_reanchor)" \
  || bad "3a. no selfheal_reanchor event: $(grep -o '"type":"selfheal[a-z_]*"' "$EV3" 2>/dev/null | sort -u | tr '\n' ' ')"
ANCHORS="$(grep '"type":"selfheal_reanchor"' "$EV3" 2>/dev/null | grep -o '"tip":"[0-9a-f]\{7,\}"' | sort -u | wc -l | tr -d ' ')"
[ "${ANCHORS:-0}" -ge 2 ] \
  && ok "3b. the two rounds anchored to two DIFFERENT tips (the branch moved under them)" \
  || bad "3b. expected >=2 distinct recorded tips, got ${ANCHORS:-0}: $(grep -o '"tip":"[0-9a-f]*"' "$EV3" 2>/dev/null | tr '\n' ' ')"
# The worker's OWN worktree HEAD, per round, against the tip recorded for it.
ANCHOR2="$(grep '"type":"selfheal_reanchor"' "$EV3" 2>/dev/null | tail -1 | sed -n 's/.*"tip":"\([0-9a-f]*\)".*/\1/p')"
HEAD2="$(grep 'role=implement-tdd' "$B3/dispatch.log" 2>/dev/null | tail -1 | sed -n 's/.*head=\([0-9a-f]*\).*/\1/p')"
if [ -n "$ANCHOR2" ] && [ -n "$HEAD2" ] && [ "$ANCHOR2" = "$HEAD2" ]; then
  ok "3c. the LAST round's worker really built on the tip that round recorded"
else
  bad "3c. round-2 anchor '$ANCHOR2' != the worker's worktree HEAD '$HEAD2'"
fi
HEAD1="$(grep 'role=implement-tdd' "$B3/dispatch.log" 2>/dev/null | head -1 | sed -n 's/.*head=\([0-9a-f]*\).*/\1/p')"
[ -n "$HEAD1" ] && [ -n "$HEAD2" ] && [ "$HEAD1" != "$HEAD2" ] \
  && ok "3d. …and NOT on the base the earlier round captured" \
  || bad "3d. both rounds built on the same tip ('$HEAD1' vs '$HEAD2')"

# ===========================================================================
# 4 + 6. BASE DRIFT MERGES SAFELY OR BLOCKS WITH A RECOVERY DIAGNOSIS.
#    6: the base is advanced BEFORE the drive; dirty trees still block.
#    4: the base is advanced BETWEEN rounds, by the worker itself — the live
#       shape — and "did not land cleanly" must not appear anywhere.
# ===========================================================================
echo "-- S336. a working mission re-anchors by merge and heals --"
BM="$(mkrig)"; mkworker "$BM"
MISSION_TIP="$(git -C "$BM/repo" rev-parse "lcars/$MID")"
bash "$MKFLAT" --advance-base "$BM" >/dev/null 2>&1
drive "$BM" LCARS_SELFHEAL_CAP=3
grep -q '"type":"selfheal_ok"' "$(ev_of "$BM")" \
  && ok "S336a. behind + own commits automatically re-anchors and heals" \
  || bad "S336a. behind + own commits still parks: $(headline "$DRIVE_OUT")"
git -C "$BM/repo" merge-base --is-ancestor "$MISSION_TIP" "lcars/$MID" \
  && ok "S336b. the original mission commit remains an ancestor" \
  || bad "S336b. mission work was lost"
git -C "$BM/repo" merge-base --is-ancestor main "lcars/$MID" \
  && ok "S336c. the healed mission contains the current base" \
  || bad "S336c. mission still lacks the base"
[ "$(sfield "$BM" stage)" = verify ] \
  && ok "S336d. the real Implement gate advances to Verify" \
  || bad "S336d. mission is still parked"
handrun "$BM" tests/t-002.test.js \
  && ok "S336e. the repaired ticket actually passes at the branch tip" \
  || bad "S336e. repair is not effective at the tip"

echo "-- S336. a conflicting base merge parks without spending a worker --"
BC="$(mkrig)"; mkworker "$BC"
CONFLICT_TIP="$(git -C "$BC/repo" rev-parse "lcars/$MID")"
printf 'base changed this file differently\n' >"$BC/repo/src/a.js"
( cd "$BC/repo" && git add src/a.js && git commit -qm base-conflict )
drive "$BC" LCARS_SELFHEAL_CAP=3
[ "$(sfield "$BC" awaitingHuman)" = True ] \
  && ok "S336f. a content conflict raises the human gate" \
  || bad "S336f. conflict did not raise the human gate"
[ "$(git -C "$BC/repo" rev-parse "lcars/$MID")" = "$CONFLICT_TIP" ] \
  && ok "S336g. the conflicting merge leaves the exact original mission tip" \
  || bad "S336g. conflict changed the mission ref"
[ "$(led "$BC" roundsSpent)" = 0 ] && [ ! -s "$BC/dispatch.log" ] \
  && ok "S336h. conflict spends zero rounds and zero workers" \
  || bad "S336h. conflict spent a round or dispatched a worker"
case "$(pq "$BC")" in
  *CONFLICT*src/a.js*) ok "S336i. the durable human gate names the conflict and path" ;;
  *) bad "S336i. the durable gate lost the merge conflict diagnosis" ;;
esac
[ "$(git -C "$BC/repo" worktree list --porcelain | grep -c '^worktree ')" = 1 ] \
  && ok "S336j. the failed recovery leaves no worktree behind" \
  || bad "S336j. the failed recovery leaked its worktree"

echo "-- 6. a dirty tree still REFUSES recovery and names the fix --"
B6="$(mkrig)"; mkworker "$B6"
bash "$MKFLAT" --advance-base "$B6" >/dev/null 2>&1
( cd "$B6/repo" && git fetch -q origin main && git merge -q --ff-only origin/main )
printf 'captain work\n' >"$B6/repo/captain-untracked"
drive "$B6" LCARS_SELFHEAL_CAP=3 RIG_TOGGLE=1
EV6="$(ev_of "$B6")"
grep -q '"type":"selfheal_refused"' "$EV6" 2>/dev/null \
  && ok "6a. the self-heal REFUSES the round instead of proceeding" \
  || bad "6a. no selfheal_refused event: $(grep -o '"type":"selfheal[a-z_]*"' "$EV6" 2>/dev/null | sort -u | tr '\n' ' ')"
[ "$(tdlog "$B6")" = 0 ] || [ -z "$(tdlog "$B6")" ] \
  && ok "6b. and spends NO worker on a stale base ($(tdlog "$B6") dispatches)" \
  || bad "6b. a worker was dispatched against a stale base: $(tdlog "$B6")"
[ "$(led "$B6" roundsSpent)" = 0 ] \
  && ok "6c. roundsSpent stays 0 — base drift is not a defect round" \
  || bad "6c. ledger roundsSpent='$(led "$B6" roundsSpent)'"
REF6="$(grep '"type":"selfheal_refused"' "$EV6" 2>/dev/null | head -1)"
case "$REF6$DRIVE_OUT" in
  *"dirty working tree"*) ok "6d. the refusal NAMES the recovery blocker" ;;
  *) bad "6d. no re-anchor command named: $(printf '%s' "$REF6" | cut -c1-240)" ;;
esac
case "$DRIVE_OUT" in
  *"commit(s) behind"*) ok "6e. …and says how far behind the branch is" ;;
  *) bad "6e. the human never learns the branch is behind: $(printf '%s' "$DRIVE_OUT" | grep -i 'IMPLEMENT:' | head -1)" ;;
esac
case "$(headline "$DRIVE_OUT")" in
  *"self-heal exhausted"*) bad "6f. the headline claims an exhausted budget on a refusal: $(headline "$DRIVE_OUT")" ;;
  *) ok "6f. and the FIRST line he reads names the refusal, not an exhausted budget" ;;
esac
case "$(pq "$B6")" in
  *"behind its base"*|*"commit(s) behind"*) ok "6g. …as does the pendingQuestion \`lcars answer\` replays" ;;
  *) bad "6g. pendingQuestion does not mention the drift: $(pq "$B6" | tr '\n' ' ' | cut -c1-200)" ;;
esac
# S310 FIX 2 D3: THE RECOVERY ORDER IS EXECUTABLE, AND IT IS ON THIS STOP TOO.
# Base drift parks the mission and tells him to re-anchor; answering the gate
# RESUMES the drive, so "answer first, then re-anchor" cannot be performed —
# a tester followed it literally and got a billed round and a false headline.
PQ6="$(pq "$B6")"
case "$PQ6" in
  *"THE ORDER MATTERS"*) ok "6h. the base-drift stop carries a recovery ORDER at all" ;;
  *) bad "6h. base-drift gives no ordering, though it parks the mission and asks him to act: $(printf '%s' "$PQ6" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ6" in
  *"ANSWER THIS GATE FIRST"*) bad "6i. the order is still answer-first, which auto-resumes the drive before the branch is re-anchored" ;;
  *"only THEN answer this gate"*|*"then answer this gate"*) ok "6j. …and it is re-anchor FIRST, answer second" ;;
  *) bad "6j. the ordering never says to answer the gate second: $(printf '%s' "$PQ6" | tr '\n' ' ' | cut -c1-240)" ;;
esac
# S310 FIX 2 D4: ¶1 MUST NOT CLAIM A RECONCILE THAT NEVER RAN. Base drift
# dispatches NOTHING (6b asserts dispatch.log is empty), yet the field opened
# with "the harness's last reconcile attempt went to issue #102 … and did not
# clear it" — and two paragraphs later said no worker was dispatched.
case "$PQ6" in
  *"last reconcile attempt went to"*|*"reconcile attempts did not clear it"*)
    bad "6k. pendingQuestion opens by claiming a reconcile that never happened (0 dispatches)" ;;
  *) ok "6k. pendingQuestion does not claim a reconcile attempt that never ran" ;;
esac
case "$PQ6" in
  "full-suite regression —"*) ok "6l. …and the KEYED headline leads the field he actually reads" ;;
  *) bad "6l. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ6" | head -1 | cut -c1-160)" ;;
esac

echo "-- 4. a base advanced BETWEEN rounds no longer 'does not land cleanly' --"
B4="$(mkrig)"; mkworker "$B4"
drive "$B4" LCARS_SELFHEAL_CAP=3 RIG_TOGGLE=1 \
  RIG_AFTER_WORKER="bash '$MKFLAT' --advance-base '$B4'"
EV4="$(ev_of "$B4")"
if grep -q 'did not land cleanly' "$EV4" 2>/dev/null; then
  bad "4a. the old signature survives: $(grep -o 'did not land cleanly.\{0,120\}' "$EV4" | head -1)"
else
  ok "4a. 'did not land cleanly' appears nowhere in the timeline"
fi
if grep -q '"type":"selfheal_refused"' "$EV4" 2>/dev/null; then
  bad "4b. base drift still refuses instead of merging"
else
  ok "4b. base movement between rounds no longer parks the mission"
fi
[ "$(led "$B4" roundsSpent)" = 3 ] \
  && ok "4c. three genuine alternating regressions spend three defect rounds" \
  || bad "4c. roundsSpent='$(led "$B4" roundsSpent)' — expected three genuine defects"

# ===========================================================================
# 5. A STALE ATTRIBUTION DISPATCHES NO WORKER.
#    t-002's suite is red for the gate's run and green for every run after it
#    ($T2_ONESHOT) — so by the time the self-heal looks, the regression it was
#    handed does not exist. On the live repo that single check would have saved
#    all three rounds and five worker sessions.
# ===========================================================================
echo "-- 5. a regression that is green at the tip spends no worker --"
B5="$(mkrig)"; mkworker "$B5"
# The repo at the tip is GREEN — src/b.js works. The gate still goes red,
# because $T2_ONESHOT makes t-002's suite report RED exactly once, which is the
# live shape: the gate's evidence was real when it was taken and is already out
# of date by the time anyone acts on it.
git -C "$B5/repo" checkout -q "lcars/$MID"
printf 'exports.ok = () => true;\n' >"$B5/repo/src/b.js"
( cd "$B5/repo" && git add -A && git commit -qm "t-002: src/b.js already repaired" \
    && git checkout -q main )
drive "$B5" LCARS_SELFHEAL_CAP=3 T2_ONESHOT="$B5/t2-oneshot"
EV5="$(ev_of "$B5")"
grep -q '"type":"selfheal_stale_attribution"' "$EV5" 2>/dev/null \
  && ok "5a. the stale attribution is RECORDED, by its own event name" \
  || bad "5a. no selfheal_stale_attribution event: $(grep -o '"type":"selfheal[a-z_]*"' "$EV5" 2>/dev/null | sort -u | tr '\n' ' ')"
N5="$(tdlog "$B5")"; [ -n "$N5" ] || N5=0
[ "$N5" = 0 ] \
  && ok "5b. NO worker was dispatched (the shim's own invocation count is 0)" \
  || bad "5b. $N5 worker(s) were dispatched on a regression that no longer exists"
[ "$(led "$B5" roundsSpent)" = 0 ] \
  && ok "5c. and no round was spent" \
  || bad "5c. ledger roundsSpent='$(led "$B5" roundsSpent)'"
[ "$(led "$B5" workersAvoided)" -ge 1 ] 2>/dev/null \
  && ok "5d. the ledger records how many worker dispatches the check avoided: $(led "$B5" workersAvoided)" \
  || bad "5d. ledger workersAvoided='$(led "$B5" workersAvoided)'"
grep -q '"type":"selfheal_attribution"' "$EV5" 2>/dev/null \
  && bad "5e. a ticket was attributed a regression that was already gone" \
  || ok "5e. no ticket is attributed a regression that is green at the tip"
grep -q '"type":"selfheal_ok"' "$EV5" 2>/dev/null \
  && ok "5f. the mission healed without a single worker session" \
  || bad "5f. no selfheal_ok after the stale attribution: $(printf '%s' "$DRIVE_OUT" | tail -2)"
# S320 BEHAVIOUR 4. This IS the case the apply-failure comment was written to
# protect — a regression that cleared for an unrelated reason, with NOTHING to
# land — and it must still resolve honestly after D18's fix. It must also say
# WHICH of the two it was, because "self-heal succeeded" over a repair that was
# never applied is exactly the sentence D18 turned into a live break.
[ "$(led "$B5" stopReason)" = healed-stale ] \
  && ok "5g. a regression that cleared ON ITS OWN resolves under its own stop reason: healed-stale" \
  || bad "5g. ledger stopReason='$(led "$B5" stopReason)' — expected healed-stale"
[ "$(led "$B5" applyFailures)" = 0 ] \
  && ok "5h. …with ZERO apply failures, because nothing ever needed to land" \
  || bad "5h. ledger applyFailures='$(led "$B5" applyFailures)' on a path where nothing was built"
OK5="$(grep '"type":"selfheal_ok"' "$EV5" 2>/dev/null | head -1)"
case "$OK5" in
  *"NO worker session"*)
    ok "5i. …and the message names WHICH of the two it was: no worker ran, nothing was landed" ;;
  *) bad "5i. the heal message does not distinguish 'nothing to land' from a landed repair: $(printf '%s' "$OK5" | cut -c1-240)" ;;
esac
case "$OK5" in
  *LANDED*) bad "5j. it claims a rebuild LANDED on a path where nothing was ever built" ;;
  *) ok "5j. …and it claims no rebuild landed" ;;
esac
[ "$(sfield "$B5" stage)" = verify ] \
  && ok "5k. …and an honest resolution still ADVANCES the mission to Verify" \
  || bad "5k. a regression that cleared on its own no longer advances: stage='$(sfield "$B5" stage)'"

# ===========================================================================
# 7. TWO ROUNDS, TWO DIFFERENT FAILURE MODES → the escalation SAYS SO.
#    Round 1 fails on t-002's suite; the worker's repair of t-002 exposes
#    t-001 instead, so round 2 fails on a different owner. Two rounds failing
#    for two DIFFERENT reasons is stronger evidence of a structural problem
#    than two identical ones, and the human must be told that.
# ===========================================================================
echo "-- 7. a CHANGING failure mode is named in the escalation --"
B7="$(mkrig)"; mkworker "$B7"
# RIG_TOGGLE repairs the attributed ticket and breaks the OTHER one, so round 1
# ends with t-001 failing and round 2 with t-002 failing: two rounds, two
# different failing owners, nothing weakened and no test file touched.
drive "$B7" LCARS_SELFHEAL_CAP=2 RIG_TOGGLE=1
MODES7="$(led "$B7" modes)"
case "$DRIVE_OUT" in
  *"different reason"*|*"DIFFERENT reason"*|*"changed between rounds"*)
    ok "7a. the escalation states that the rounds failed for DIFFERENT reasons" ;;
  *) bad "7a. the escalation does not name the mode shift: $(printf '%s' "$DRIVE_OUT" | grep -i 'IMPLEMENT:' | head -1)" ;;
esac
[ -n "$(led "$B7" modeShift)" ] \
  && ok "7b. and the shift is recorded in the ledger, not just said once" \
  || bad "7b. ledger modeShift is empty: $(cat "$(ledger_of "$B7")" 2>/dev/null | tr -d '\n' | cut -c1-240)"
case "$MODES7" in
  *t-002*t-001*|*t-001*t-002*) ok "7c. the ledger names BOTH rounds' modes: $MODES7" ;;
  *) bad "7c. the recorded modes do not show two different failing owners: '$MODES7'" ;;
esac


# ===========================================================================
# 8. THE STOP'S REAL STORY REACHES THE HUMAN (S310 fix round 1).
#
# The mechanics of section 1–7 were driven on 25 fixtures and held. What an
# operator was TOLD did not: every stop still opened with "self-heal
# exhausted — the regression is irreducible", which is the pre-S310 sentence
# that cost the measured live run 2.5 hours, and the honest story lived only
# in events.jsonl. Self-heal events have never been rendered anywhere, so the
# only two surfaces that reach a human are asserted here: run STDOUT, and
# `state.json.pendingQuestion` — the field `lcars answer` and the board
# replay to him later.
# ===========================================================================
echo "-- 8. an apply-failure stop says so, on both human surfaces --"
B8="$(mkrig)"; mkworker "$B8"
git -C "$B8/repo" worktree add -q "$B8/holder" "lcars/$MID" >/dev/null 2>&1
# D5 rides on this same rig: the re-check worktree's base dir is left
# non-writable, so the budget-saving stale-attribution check CANNOT be cut.
# The direction is safe (it spends a worker rather than false-healing), but a
# whole feature switching itself off on a real repo must not be silent.
R8="$B8/repo/.git/lcars/missions/$MID/selfheal-recheck-wt"
mkdir -p "$R8"; : >"$R8/occupied"; chmod 500 "$R8"
drive "$B8" LCARS_SELFHEAL_CAP=3 RIG_TOGGLE=1
chmod 700 "$R8" 2>/dev/null
EV8="$(ev_of "$B8")"; PQ8="$(pq "$B8")"; H8="$(headline "$DRIVE_OUT")"
[ "$(led "$B8" stopReason)" = apply-failed ] \
  && ok "8-pre. the rig stopped on an apply failure (ledger stopReason)" \
  || bad "8-pre. stopReason='$(led "$B8" stopReason)' — not the apply-failure stop; every check below is vacuous"
case "$H8" in
  *"self-heal exhausted"*) bad "8a. the FIRST line he reads still claims an exhausted budget: $H8" ;;
  *) ok "8a. the headline does not claim self-heal was exhausted" ;;
esac
case "$H8" in
  *"would not LAND"*|*"not LAND"*) ok "8b. …it says the rebuild would not LAND: $H8" ;;
  *) bad "8b. the headline never names the apply failure: $H8" ;;
esac
case "$DRIVE_OUT" in
  *"WHAT ACTUALLY STOPPED THE SELF-HEAL"*"would not LAND"*)
    ok "8c. stdout carries the apply-failure clarifier" ;;
  *) bad "8c. no apply clarifier on stdout: $(printf '%s' "$DRIVE_OUT" | grep -c 'WHAT ACTUALLY') WHAT-ACTUALLY line(s)" ;;
esac
case "$PQ8" in
  *"WHAT ACTUALLY STOPPED THE SELF-HEAL"*"would not LAND"*)
    ok "8d. and so does pendingQuestion — what \`lcars answer\` shows him later" ;;
  *) bad "8d. pendingQuestion still tells the pre-S310 story: $(printf '%s' "$PQ8" | tr '\n' ' ' | cut -c1-200)" ;;
esac
case "$PQ8" in
  *"UNTOUCHED"*|*"0 of 3 self-heal round(s) were spent"*)
    ok "8e. …and says plainly that the repair budget was not spent" ;;
  *) bad "8e. he is never told the budget is intact: $(printf '%s' "$PQ8" | tr '\n' ' ' | cut -c1-200)" ;;
esac
# THE RECOVERY ORDER. The discard of a green round while the mission is parked
# is INHERITED and is not cured here — but S310's own advice walked him
# straight into it ("switch that checkout … and re-run implement"), losing a
# green rebuild and reporting "exhausted". Any recovery advice must put
# answering the gate FIRST.
case "$PQ8" in
  *"answer this gate"*|*"ANSWER THIS GATE"*) ok "8f. the recovery advice mentions the gate at all" ;;
  *) bad "8f. the advice still sends him to re-run implement while parked: $(printf '%s' "$PQ8" | tr '\n' ' ' | cut -c1-240)" ;;
esac
# S310 FIX 2 D3: AND THE ORDER IS THE OTHER WAY ROUND. Fix round 1 wrote
# "ANSWER THIS GATE FIRST, then free whatever holds the branch" — but answering
# a gate AUTO-RESUMES the drive, so there is no gap between step 1 and step 2:
# followed literally it re-ran implement with the holder still attached, burned
# three more worker sessions and re-parked with the same story.
case "$PQ8" in
  *"ANSWER THIS GATE FIRST"*) bad "8f2. the stated order is still answer-first, which cannot be performed — answering resumes the drive" ;;
  *) ok "8f2. the un-performable answer-first order is gone" ;;
esac
case "$PQ8" in
  *"only THEN answer this gate"*|*"then answer this gate"*) ok "8f3. …and it is free-the-branch FIRST, answer second" ;;
  *) bad "8f3. no free-then-answer ordering on the apply-failure stop: $(printf '%s' "$PQ8" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ8" in
  "full-suite regression —"*) ok "8f4. the keyed headline leads pendingQuestion" ;;
  *) bad "8f4. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ8" | head -1 | cut -c1-160)" ;;
esac
AF8="$(grep '"type":"selfheal_apply_failed"' "$EV8" 2>/dev/null | head -1)"
case "$AF8" in
  *"re-run implement"*)
    case "$AF8" in
      *"answer"*|*"gate"*) ok "8g. the apply-failure event's own instruction clears the gate before re-running" ;;
      *) bad "8g. the event still says re-run implement with no word about the gate: $(printf '%s' "$AF8" | cut -c1-240)" ;;
    esac ;;
  *) ok "8g. the apply-failure event gives no bare re-run instruction" ;;
esac
grep -q '"type":"selfheal_recheck_unmeasured"' "$EV8" 2>/dev/null \
  && ok "8h. a stale-check that could NOT run says so, by its own event name" \
  || bad "8h. the budget-saving check switched itself off silently: $(grep -o '"type":"selfheal[a-z_]*"' "$EV8" 2>/dev/null | sort -u | tr '\n' ' ')"
case "$DRIVE_OUT" in
  *"could not re-check"*|*"STALE-ATTRIBUTION CHECK"*)
    ok "8i. …and the run says it out loud too" ;;
  *) bad "8i. nothing on stdout says the check did not run" ;;
esac

echo "-- 9. a contradiction stop does NOT print 'nothing for a worker to fix' --"
B9="$(mkrig)"; mkworker "$B9"
drive "$B9" LCARS_SELFHEAL_CAP=3 RIG_FLAP="$B9/flap"
PQ9="$(pq "$B9")"; H9="$(headline "$DRIVE_OUT")"
[ "$(led "$B9" stopReason)" = contradiction ] \
  && ok "9-pre. the rig reproduced the contradiction stop (ledger stopReason)" \
  || bad "9-pre. stopReason='$(led "$B9" stopReason)' — not the contradiction stop; every check below is vacuous"
case "$DRIVE_OUT$PQ9" in
  *"nothing for a worker to fix"*)
    bad "9a. he reads 'nothing to fix' about a branch the harness just said it cannot vouch for" ;;
  *) ok "9a. the stale-skip clarifier is NOT printed for a contradiction" ;;
esac
case "$DRIVE_OUT" in
  *"cannot tell which run is true"*) ok "9b. stdout says the two runs disagree at the same tip" ;;
  *) bad "9b. stdout never says what the contradiction is: $(printf '%s' "$DRIVE_OUT" | grep -A2 'WHAT ACTUALLY' | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ9" in
  *"cannot tell which run is true"*) ok "9c. and pendingQuestion carries the same sentence" ;;
  *) bad "9c. pendingQuestion does not state the contradiction: $(printf '%s' "$PQ9" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$H9" in
  *"self-heal exhausted"*) bad "9d. the headline claims an exhausted budget on a 0-round stop: $H9" ;;
  *) ok "9d. the headline does not claim self-heal was exhausted: $H9" ;;
esac
# A contradiction parks the mission and tells him to re-run the suite himself:
# the same discard hazard, so the same ordering (S310 FIX 2 D3).
[ "$(tdlog "$B9")" = 0 ] || [ -z "$(tdlog "$B9")" ] \
  && ok "9e-pre. the contradiction stop dispatched NO worker ($(tdlog "$B9"))" \
  || bad "9e-pre. $(tdlog "$B9") dispatch(es) — this is not a 0-dispatch stop; 9f/9g are vacuous"
case "$PQ9" in
  *"THE ORDER MATTERS"*"THEN answer this gate"*) ok "9e. the contradiction stop carries the free-then-answer ordering" ;;
  *) bad "9e. no recovery ordering on the contradiction stop: $(printf '%s' "$PQ9" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ9" in
  *"last reconcile attempt went to"*|*"reconcile attempts did not clear it"*)
    bad "9f. pendingQuestion opens by claiming a reconcile that never happened (0 dispatches)" ;;
  *) ok "9f. pendingQuestion does not claim a reconcile attempt that never ran" ;;
esac
case "$PQ9" in
  "full-suite regression —"*) ok "9g. …and the keyed headline leads it" ;;
  *) bad "9g. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ9" | head -1 | cut -c1-160)" ;;
esac

echo "-- 10. a stale-skip stop still gets its own (correct) sentence --"
B10="$(mkrig)"; mkworker "$B10"
drive "$B10" LCARS_SELFHEAL_CAP=3 LCARS_SELFHEAL_STALE_CAP=1 \
  RIG_FLAP="$B10/flap" RIG_FLAP_WIDEN=1
PQ10="$(pq "$B10")"; H10="$(headline "$DRIVE_OUT")"
[ "$(led "$B10" stopReason)" = stale-attribution ] \
  && ok "10-pre. the rig reproduced the stale-skip stop (ledger stopReason)" \
  || bad "10-pre. stopReason='$(led "$B10" stopReason)' — not the stale-skip stop; every check below is vacuous"
case "$PQ10" in
  *"already cleared at the current tip"*)
    ok "10a. pendingQuestion says every regression had already cleared at the tip" ;;
  *) bad "10a. the stale sentence is missing: $(printf '%s' "$PQ10" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$H10" in
  *"self-heal exhausted"*) bad "10b. the headline claims an exhausted budget on a 0-round stop: $H10" ;;
  *) ok "10b. the headline does not claim self-heal was exhausted: $H10" ;;
esac
case "$PQ10" in
  *"THE ORDER MATTERS"*"THEN answer this gate"*) ok "10c. the stale-skip stop carries the free-then-answer ordering too" ;;
  *) bad "10c. no recovery ordering on the stale-skip stop: $(printf '%s' "$PQ10" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ10" in
  *"last reconcile attempt went to"*|*"reconcile attempts did not clear it"*)
    bad "10d. pendingQuestion opens by claiming a reconcile that never happened" ;;
  *) ok "10d. pendingQuestion does not claim a reconcile attempt that never ran" ;;
esac
case "$PQ10" in
  "full-suite regression —"*) ok "10e. …and the keyed headline leads it" ;;
  *) bad "10e. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ10" | head -1 | cut -c1-160)" ;;
esac

echo "-- 11. the everyday worker-session-cap exit CLOSES the ledger --"
B11="$(mkrig)"; mkworker "$B11"
# The reconcile worker reports success but lands nothing the proof gates can
# believe, so the ticket legitimately burns its own worker-session cap. This is
# not an exotic path — it is "the reconcile ticket couldn't do it" — and the new
# accounting reported it as roundsSpent 0 / lastOutcome "start" / tip "".
drive "$B11" LCARS_SELFHEAL_CAP=3 LCARS_WORKER_TRIES=1 RIG_WORKER_BAD=1
EV11="$(ev_of "$B11")"; PQ11="$(pq "$B11")"; H11="$(headline "$DRIVE_OUT")"
grep -q '"type":"ticket_flagged"' "$EV11" 2>/dev/null \
  && ok "11-pre. the reconcile ticket really did burn its own session cap" \
  || bad "11-pre. no ticket_flagged — the scenario did not reproduce; every check below is vacuous"
[ "$(led "$B11" roundsSpent)" = 1 ] \
  && ok "11a. the ledger records the ONE round that was really spent" \
  || bad "11a. ledger roundsSpent='$(led "$B11" roundsSpent)' — real spend is under-reported"
[ -n "$(led "$B11" stopReason)" ] \
  && ok "11b. …and why the loop stopped: $(led "$B11" stopReason)" \
  || bad "11b. ledger stopReason is empty on the everyday failure path"
case "$(led "$B11" lastOutcome)" in
  ''|start) bad "11c. ledger lastOutcome='$(led "$B11" lastOutcome)' — never closed out" ;;
  *) ok "11c. …and the ledger is closed out, not left at 'start' ($(led "$B11" lastOutcome))" ;;
esac
[ -n "$(led "$B11" tip)" ] \
  && ok "11d. …with the tip the round was anchored to" \
  || bad "11d. ledger tip is empty"
case "$PQ11" in
  *"worker-session cap"*) ok "11e. and the human is told it was the ticket's OWN session cap" ;;
  *) bad "11e. pendingQuestion does not name the session cap: $(printf '%s' "$PQ11" | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$H11" in
  *"self-heal exhausted"*) bad "11f. the headline claims the self-heal budget ran out when the ticket's did: $H11" ;;
  *) ok "11f. the headline names the real stop: $H11" ;;
esac

# ===========================================================================
# 12. A GREEN RECONCILE WHILE THE MISSION IS PARKED IS NOT A BURNED SESSION CAP
#     (S310 fix round 2, D1).
#
# ONE variable against section 0: whether the mission was ALREADY parked at a
# human gate (`awaitingHuman: true`) when the self-heal ran. That is the state
# EVERY ONE of the six S310 stops leaves behind, so this is reached by the
# everyday route — follow the printed advice on any of them, re-run implement,
# and land here.
#
# Parked, the self-heal's post-dispatch `awaitingHuman == true` check fires on a
# flag the dispatch did NOT set, so a reconcile that passed every proof gate was
# reported as "the reconcile ticket burned its OWN worker-session cap" and a
# repair round was billed for a round that SUCCEEDED. The harness's own timeline
# proves it: flip_flop_pass → ticket_postcommit_ok → ticket_green, and NO
# ticket_flagged event anywhere. Section 11 covers only the shape where the
# ticket really IS flagged ($RIG_WORKER_BAD), which is how this got through.
#
# The DISCARD itself is inherited (D17) and is NOT cured here — what is cured is
# the false diagnosis and the billed round.
# ===========================================================================
echo "-- 12. a GREEN reconcile while the mission is parked is not a session cap --"
B12="$(mkrig)"; mkworker "$B12"
S12="$B12/repo/.git/lcars/missions/$MID/state.json"
"${LCARS_PYTHON_BIN:-python3}" - "$S12" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["awaitingHuman"] = True
d["pendingQuestion"] = "an earlier gate nobody has answered yet"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
drive "$B12" LCARS_SELFHEAL_CAP=3
EV12="$(ev_of "$B12")"; PQ12="$(pq "$B12")"; H12="$(headline "$DRIVE_OUT")"
grep -q '"type":"ticket_green"' "$EV12" 2>/dev/null \
  && ok "12-pre. the reconcile ticket really did go GREEN (ticket_green in the timeline)" \
  || bad "12-pre. no ticket_green — the scenario did not reproduce; every check below is vacuous"
grep -q '"type":"ticket_flagged"' "$EV12" 2>/dev/null \
  && bad "12a. a ticket_flagged event exists — this is section 11's shape, not the parked one" \
  || ok "12a. and NO ticket_flagged event exists — nothing was ever flagged"
[ "$(led "$B12" roundsSpent)" = 0 ] \
  && ok "12b. NO repair round is billed for a round that succeeded" \
  || bad "12b. ledger roundsSpent='$(led "$B12" roundsSpent)' — a round was billed for a GREEN reconcile"
[ "$(led "$B12" stopReason)" = ticket-session-cap ] \
  && bad "12c. the ledger still records the ticket's own session cap: $(led "$B12" stopReason)" \
  || ok "12c. the ledger names a different stop: $(led "$B12" stopReason)"
case "$H12" in
  *"burned its OWN worker-session cap"*)
    bad "12d. the headline still says the ticket burned its own session cap: $H12" ;;
  *) ok "12d. the headline does not claim a burned session cap: $H12" ;;
esac
case "$H12$PQ12" in
  *"self-heal exhausted"*) bad "12e. a GREEN reconcile is reported as an exhausted self-heal" ;;
  *) ok "12e. …nor an exhausted self-heal" ;;
esac
case "$PQ12" in
  *"last reconcile attempt went to"*)
    bad "12i. ¶1 says the reconcile 'did not clear it' about one that PASSED every gate and was discarded" ;;
  *) ok "12i. ¶1 does not read the discarded-but-green reconcile as a failed repair" ;;
esac
case "$PQ12" in
  *"PASSED its proof gates"*|*"PASSED every proof gate"*)
    ok "12j. …it says the reconcile ran and passed" ;;
  *) bad "12j. ¶1 never says the reconcile passed: $(printf '%s' "$PQ12" | sed -n 2,3p | tr '\n' ' ' | cut -c1-240)" ;;
esac
case "$PQ12" in
  *"parked"*) ok "12f. pendingQuestion says the mission was already parked at a gate" ;;
  *) bad "12f. he is never told the park is what stopped it: $(printf '%s' "$PQ12" | tr '\n' ' ' | cut -c1-280)" ;;
esac
case "$PQ12" in
  *"worker-session cap"*) bad "12g. pendingQuestion still names a session cap that was never reached" ;;
  *) ok "12g. …and pendingQuestion names no session cap" ;;
esac
case "$PQ12" in
  "full-suite regression —"*) ok "12h. the keyed headline leads pendingQuestion here too" ;;
  *) bad "12h. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ12" | head -1 | cut -c1-160)" ;;
esac

# ===========================================================================
# 14/15. A RECONCILE WORKER THAT PRODUCED NOTHING IS NOT A GREEN RECONCILE
#        (S310 fix round 3).
#
# Section 12's exit discriminates on the ABSENCE of a ticket_flagged event — and
# absence is not evidence of green. A reconcile worker that simply FAILS writes
# no ticket_flagged either, so it was reported with section 12's story: "the
# reconcile went GREEN and could not land", "it PASSED every proof gate",
# "nothing is lost but that worker session". Three sentences, all false: nothing
# was rebuilt, nothing passed a gate, the worker died.
#
# ONE variable against section 12: the worker. Same pre-parked fixture, same
# drive. The on-disk timeline of both variants below is identical and carries
# ticket_worker_empty_output / ticket_implementer_failed with NO ticket_green,
# NO ticket_postcommit_ok and NO ticket_flagged anywhere — the product already
# had names for this third state and the exit simply never consulted them.
#
# Two variants, because the quiet one is what a real engine produces:
#   14. the worker exits 1, writes no result.json, no commit
#   15. the worker exits 0 and prints nothing — an auth lapse, a rate limit, an
#       empty completion
# ===========================================================================
park() { # base — park the mission at a human gate, exactly as section 12 does
  "${LCARS_PYTHON_BIN:-python3}" - "$1/repo/.git/lcars/missions/$MID/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["awaitingHuman"] = True
d["pendingQuestion"] = "an earlier gate nobody has answered yet"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
}

for VAR in crash silent; do
  case "$VAR" in
    crash)  N=14; KNOB=RIG_WORKER_CRASH=1
            echo "-- 14. a reconcile worker that CRASHES while parked is not a green reconcile --" ;;
    silent) N=15; KNOB=RIG_WORKER_SILENT=1
            echo "-- 15. …nor is one that exits 0 and produces nothing (the real engine shape) --" ;;
  esac
  BX="$(mkrig)"; mkworker "$BX"; park "$BX"
  drive "$BX" LCARS_SELFHEAL_CAP=3 "$KNOB"
  EVX="$(ev_of "$BX")"; PQX="$(pq "$BX")"; HX="$(headline "$DRIVE_OUT")"

  # --- the scenario really did reproduce -----------------------------------
  grep -q '"type":"ticket_worker_empty_output"' "$EVX" 2>/dev/null \
    && ok "${N}-pre. the reconcile worker really did produce nothing (ticket_worker_empty_output on record)" \
    || bad "${N}-pre. no ticket_worker_empty_output — the scenario did not reproduce; every check below is vacuous"
  if grep -q '"type":"ticket_green"' "$EVX" 2>/dev/null \
     || grep -q '"type":"ticket_postcommit_ok"' "$EVX" 2>/dev/null; then
    bad "${N}a. a green marker exists — this is section 12's shape, not the no-result one"
  else
    ok "${N}a. and NO ticket_green / ticket_postcommit_ok anywhere — nothing passed a gate"
  fi
  grep -q '"type":"ticket_flagged"' "$EVX" 2>/dev/null \
    && bad "${N}b. a ticket_flagged exists — this is section 11's shape, not the no-result one" \
    || ok "${N}b. …and NO ticket_flagged either — which is why absence could not be trusted"

  # --- the headline ---------------------------------------------------------
  case "$HX" in
    *"went GREEN"*|*PASSED*)
      bad "${N}c. the headline claims a green reconcile that never ran: $HX" ;;
    *) ok "${N}c. the headline claims no green reconcile: $HX" ;;
  esac
  case "$HX" in
    *"self-heal exhausted"*) bad "${N}d. the headline claims an exhausted self-heal: $HX" ;;
    *) ok "${N}d. …nor an exhausted self-heal" ;;
  esac
  [ "$(printf '%s\n' "$DRIVE_OUT" | grep -c '^IMPLEMENT:')" = 1 ] \
    && ok "${N}e. exactly one IMPLEMENT: line on stdout" \
    || bad "${N}e. $(printf '%s\n' "$DRIVE_OUT" | grep -c '^IMPLEMENT:') IMPLEMENT: lines on stdout"

  # --- pendingQuestion: the surface `lcars answer` and the board replay -----
  case "$PQX" in
    *"PASSED its proof gates"*|*"PASSED every proof gate"*)
      bad "${N}f. pendingQuestion asserts a gate pass that never happened" ;;
    *) ok "${N}f. pendingQuestion asserts no gate pass" ;;
  esac
  case "$PQX" in
    *"reconcile was rebuilt"*|*"rebuilt from scratch"*)
      bad "${N}g. pendingQuestion claims a rebuild that never happened" ;;
    *) ok "${N}g. …and claims no rebuild" ;;
  esac
  case "$PQX" in
    *"nothing is lost"*) bad "${N}h. pendingQuestion reassures him nothing was lost" ;;
    *) ok "${N}h. …and does not reassure him nothing was lost" ;;
  esac
  case "$PQX" in
    *"YOUR REPAIR BUDGET IS UNTOUCHED"*)
      bad "${N}i. pendingQuestion says the budget is UNTOUCHED while the engine is broken" ;;
    *) ok "${N}i. …and does not call the budget untouched — the engine is what is broken" ;;
  esac
  case "$PQX" in
    *"worker-session cap"*) bad "${N}j. pendingQuestion names a session cap that was never reached" ;;
    *) ok "${N}j. …and names no session cap" ;;
  esac
  case "$PQX" in
    *"NO RESULT"*) ok "${N}k. he is told the reconcile worker produced NO RESULT" ;;
    *) bad "${N}k. he is never told the worker produced nothing: $(printf '%s' "$PQX" | tr '\n' ' ' | cut -c1-280)" ;;
  esac
  case "$PQX" in
    *"worker CLI"*|*"LCARS_WORKER_BIN"*)
      ok "${N}l. …and the recovery points at the worker/engine, not at the gate" ;;
    *) bad "${N}l. the recovery advice never names the worker/engine: $(printf '%s' "$PQX" | tr '\n' ' ' | cut -c1-320)" ;;
  esac
  case "$PQX" in
    "full-suite regression —"*) ok "${N}m. the keyed headline leads pendingQuestion here too" ;;
    *) bad "${N}m. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQX" | head -1 | cut -c1-160)" ;;
  esac

  # --- the ledger ----------------------------------------------------------
  [ "$(led "$BX" roundsSpent)" = 0 ] \
    && ok "${N}n. no repair round is charged — no worker ran to a verdict" \
    || bad "${N}n. ledger roundsSpent='$(led "$BX" roundsSpent)' — a round was billed for a worker that produced nothing"
  case "$(led "$BX" stopReason)" in
    mission-parked) bad "${N}o. the ledger still records section 12's green-but-discarded stop" ;;
    worker-no-result) ok "${N}o. the ledger names the worker/engine stop: worker-no-result" ;;
    *) bad "${N}o. ledger stopReason='$(led "$BX" stopReason)' — expected worker-no-result" ;;
  esac
done

# ===========================================================================
# 16. S320 — THE CONTROL, AND IT IS WRITTEN FIRST ON PURPOSE.
#
#     A GENUINE heal must still heal and must still advance. Breaking this is
#     the real risk of the D18 fix, so the control is the SAME worker shape as
#     section 17 — it writes a new declared regression test file of its own —
#     with exactly ONE variable changed: nothing holds the mission branch, so
#     the rebuild LANDS. Everything is read at the branch tip.
# ===========================================================================
echo "-- 16. S320 CONTROL: a rebuild that LANDS is still a heal, and still advances --"
B16="$(mkrig)"; mkworker "$B16"
drive "$B16" LCARS_SELFHEAL_CAP=3 RIG_WORKER_NEWTEST=1
EV16="$(ev_of "$B16")"
[ "$(tdlog "$B16")" -ge 1 ] 2>/dev/null \
  && ok "16-pre. the control really dispatched a reconcile worker" \
  || bad "16-pre. no worker ran — the control is vacuous: $(printf '%s' "$DRIVE_OUT" | tail -3)"
grep -q '"type":"selfheal_apply_failed"' "$EV16" 2>/dev/null \
  && bad "16-pre2. the control's apply FAILED — it is no longer a control" \
  || ok "16-pre2. and its apply succeeded — nothing held the branch"
grep -q '"type":"selfheal_ok"' "$EV16" 2>/dev/null \
  && ok "16a. a landed rebuild still emits selfheal_ok" \
  || bad "16a. the fix broke a genuine heal — no selfheal_ok: $(grep -o '"type":"selfheal[a-z_]*"' "$EV16" 2>/dev/null | sort -u | tr '\n' ' ')"
[ "$(led "$B16" stopReason)" = healed ] \
  && ok "16b. …and the ledger still records stopReason healed" \
  || bad "16b. ledger stopReason='$(led "$B16" stopReason)' — expected healed"
[ "$(sfield "$B16" stage)" = verify ] \
  && ok "16c. …and the mission still ADVANCES to Verify" \
  || bad "16c. a genuine heal no longer advances: stage='$(sfield "$B16" stage)'"
[ -z "$(sfield "$B16" awaitingHuman)" ] && [ -z "$(pq "$B16")" ] \
  && ok "16d. …and no human gate is raised on a heal that really healed" \
  || bad "16d. a genuine heal parked the mission: awaitingHuman='$(sfield "$B16" awaitingHuman)'"
# GROUND TRUTH at the tip — the branch really is repaired.
case "$(tip_blob "$B16" src/b.js)" in
  *"=> true"*) ok "16e. GROUND TRUTH: src/b.js at the branch tip is repaired" ;;
  *) bad "16e. the branch tip is NOT repaired: $(tip_blob "$B16" src/b.js | tr '\n' ' ')" ;;
esac
tip_has "$B16" tests/t-002-regression.test.js \
  && ok "16f. GROUND TRUTH: the rebuild's own regression test IS on the branch" \
  || bad "16f. the rebuild's test is absent from the branch — the apply did not land"
handrun "$B16" tests/t-002.test.js \
  && ok "16g. GROUND TRUTH: the ticket's OWN test passes when run by hand at the tip" \
  || bad "16g. the ticket's own test fails at the tip of a mission reported HEALED (rc=$?)"
case "$(grep '"type":"selfheal_ok"' "$EV16" 2>/dev/null | head -1)" in
  *LANDED*) ok "16h. the heal message says WHICH heal it was — the rebuild LANDED" ;;
  *) bad "16h. the heal message does not say the rebuild landed: $(grep '"type":"selfheal_ok"' "$EV16" 2>/dev/null | head -1 | cut -c1-240)" ;;
esac

# ===========================================================================
# 17. S320 / D18 — A REPAIR THAT DID NOT LAND IS NEVER REPORTED AS A HEAL.
#
#     Measured on a live repo 2026-10-22/23 and the most serious finding of
#     that night. The reconcile worker writes a NEW declared regression test
#     file of its own, repairs the source and goes green — all honestly. Its
#     commit will not LAND (something else holds the mission branch). The
#     ticket's proof-tests snapshot has by then been rewritten to name that new
#     file, which exists ONLY in the unlanded commit, so the full-suite gate
#     finds nothing to re-run for that ticket, SKIPS it, and goes GREEN. The
#     harness then reported:
#
#       selfheal_ok | "self-heal succeeded in round 0 — every suite passes again"
#       ledger stopReason "healed" · state.json stage VERIFY
#       NO awaitingHuman · NO pendingQuestion — the inbox was EMPTY
#
#     while at the branch tip the source was still broken, the reconcile commit
#     was ABSENT, and the ticket's own test exited 1. A green gate that never
#     ran the repair is not evidence the repair worked.
# ===========================================================================
echo "-- 17. S320/D18: the gate goes green WITHOUT the repair → no heal is claimed --"
B17="$(mkrig)"; mkworker "$B17"
# Hold the mission branch, exactly as section 1 does: the landing worktree then
# cannot be attached and the commit CANNOT land, which is the real shape
# (usually the captain's own checkout sitting on the mission branch).
git -C "$B17/repo" worktree add -q "$B17/holder" "lcars/$MID" >/dev/null 2>&1
HOLD17=$?
if [ "$HOLD17" -ne 0 ] || [ ! -d "$B17/holder" ]; then
  skip "17: could not hold the mission branch in a second worktree — SKIPPING"
else
  drive "$B17" LCARS_SELFHEAL_CAP=3 RIG_WORKER_NEWTEST=1
  EV17="$(ev_of "$B17")"; PQ17="$(pq "$B17")"; H17="$(headline "$DRIVE_OUT")"

  # --- did the scenario reproduce at all? Every check below is vacuous if not.
  grep -q '"type":"selfheal_apply_failed"' "$EV17" 2>/dev/null \
    && ok "17-pre1. the rebuild was built and green and its commit would NOT land" \
    || bad "17-pre1. no apply failure — D18's precondition did not reproduce"
  case "$(led "$B17" stopReason)" in
    healed|heal-unverified)
      ok "17-pre2. …and the full-suite gate then came back GREEN anyway (stopReason='$(led "$B17" stopReason)')" ;;
    *) bad "17-pre2. the gate did not go green after the apply failure (stopReason='$(led "$B17" stopReason)') — D18 did not reproduce; every check below is vacuous" ;;
  esac

  # --- GROUND TRUTH AT THE BRANCH TIP. The gate said green; the branch is broken.
  case "$(tip_blob "$B17" src/b.js)" in
    *"=> false"*) ok "17-gt1. GROUND TRUTH: src/b.js at the branch tip is STILL BROKEN" ;;
    *) bad "17-gt1. the branch tip is not broken, so there is no false heal to detect: $(tip_blob "$B17" src/b.js | tr '\n' ' ')" ;;
  esac
  tip_has "$B17" tests/t-002-regression.test.js \
    && bad "17-gt2. the rebuild's test IS on the branch — the commit landed after all" \
    || ok "17-gt2. GROUND TRUTH: the reconcile commit is ABSENT from the branch"
  handrun "$B17" tests/t-002.test.js \
    && bad "17-gt3. the ticket's own test passes at the tip — the branch is fine, so this is not D18" \
    || ok "17-gt3. GROUND TRUTH: the ticket's OWN test EXITS NON-ZERO when run by hand at the tip"

  # --- BEHAVIOUR 1: the outcome. No heal, no advance, and the inbox is not empty.
  grep -q '"type":"selfheal_ok"' "$EV17" 2>/dev/null \
    && bad "17a. the harness still claims selfheal_ok over a branch it never repaired" \
    || ok "17a. NO selfheal_ok is emitted — no heal is claimed"
  [ "$(led "$B17" stopReason)" = healed ] \
    && bad "17b. the ledger still records stopReason 'healed'" \
    || ok "17b. …and the ledger does not record a heal: stopReason='$(led "$B17" stopReason)'"
  [ "$(sfield "$B17" stage)" = verify ] \
    && bad "17c. the mission ADVANCED TO VERIFY with the regression live on the branch" \
    || ok "17c. the mission does NOT advance to Verify: stage='$(sfield "$B17" stage)'"
  [ -n "$PQ17" ] \
    && ok "17d. a pendingQuestion EXISTS — the inbox is not empty" \
    || bad "17d. pendingQuestion is EMPTY: nothing reaches \`lcars answer\` or the board"
  [ "$(sfield "$B17" awaitingHuman)" = True ] || [ "$(sfield "$B17" awaitingHuman)" = true ] \
    && ok "17e. …and the mission is parked awaiting the captain" \
    || bad "17e. awaitingHuman='$(sfield "$B17" awaitingHuman)' — the card will not show as waiting on him"

  # --- the two surfaces he reads, with the TRUE story.
  case "$PQ17" in
    "full-suite regression —"*) ok "17f. the keyed headline leads pendingQuestion on this stop too" ;;
    *) bad "17f. pendingQuestion does not open with the keyed headline: $(printf '%s' "$PQ17" | head -1 | cut -c1-160)" ;;
  esac
  case "$PQ17" in
    *"NOT on the mission branch"*|*"ABSENT from the branch"*|*"not on the branch"*)
      ok "17g. …and it says plainly the repair is NOT on the branch" ;;
    *) bad "17g. he is never told the repair is absent from the branch: $(printf '%s' "$PQ17" | tr '\n' ' ' | cut -c1-320)" ;;
  esac
  case "$PQ17" in
    *"WHAT ACTUALLY STOPPED THE SELF-HEAL"*) ok "17h. the stop has its own clarifier, like every other S310 stop" ;;
    *) bad "17h. no WHAT-ACTUALLY clarifier on this stop" ;;
  esac
  case "$H17" in
    *"self-heal exhausted"*) bad "17i. the headline claims an exhausted defect budget: $H17" ;;
    *) ok "17i. the headline does not claim an exhausted budget: $H17" ;;
  esac
  [ "$(printf '%s\n' "$DRIVE_OUT" | grep -c '^IMPLEMENT:')" = 1 ] \
    && ok "17j. exactly one IMPLEMENT: line on stdout — one stop, one story" \
    || bad "17j. $(printf '%s\n' "$DRIVE_OUT" | grep -c '^IMPLEMENT:') IMPLEMENT: lines on stdout"

  # --- BEHAVIOUR 5: the ledger records the truth on the new path.
  [ "$(led "$B17" applyFailures)" -ge 1 ] 2>/dev/null \
    && ok "17k. the ledger records the apply failure(s): $(led "$B17" applyFailures)" \
    || bad "17k. ledger applyFailures='$(led "$B17" applyFailures)'"
  [ "$(led "$B17" stopReason)" = heal-unverified ] \
    && ok "17l. …and names the stop for what it is: heal-unverified" \
    || bad "17l. ledger stopReason='$(led "$B17" stopReason)' — expected heal-unverified"
  [ "$(led "$B17" roundsSpent)" = 0 ] \
    && ok "17m. …and charges NO defect round — nothing here was about code" \
    || bad "17m. ledger roundsSpent='$(led "$B17" roundsSpent)'"
  git -C "$B17/repo" worktree remove --force "$B17/holder" >/dev/null 2>&1
fi

# ===========================================================================
# 18. S320 BEHAVIOUR 6 — TERMINATION STAYS BOUNDED, AND THE APPLY COUNTER IS
#     CUMULATIVE: A SUCCESS MUST NEVER RESET IT.
#
#     The branch is held for the FIRST reconcile only — the worker frees it on
#     its second dispatch — so this run contains an apply FAILURE and then an
#     apply SUCCESS. The defect rounds must still be bounded by the cap, and
#     the apply-failure count must still be on the ledger at the end.
# ===========================================================================
echo "-- 18. a successful apply does not reset the cumulative apply-failure count --"
B18="$(mkrig)"; mkworker "$B18"
git -C "$B18/repo" worktree add -q "$B18/holder" "lcars/$MID" >/dev/null 2>&1
HOLD18=$?
if [ "$HOLD18" -ne 0 ] || [ ! -d "$B18/holder" ]; then
  skip "18: could not hold the mission branch in a second worktree — SKIPPING"
else
  drive "$B18" LCARS_SELFHEAL_CAP=2 RIG_TOGGLE=1 \
    RIG_AFTER_WORKER="n=\$(grep -c 'role=implement-tdd' '$B18/dispatch.log' 2>/dev/null || echo 0); [ \"\$n\" -ge 2 ] && git -C '$B18/repo' worktree remove --force '$B18/holder' >/dev/null 2>&1; true"
  AF18="$(led "$B18" applyFailures)"; RS18="$(led "$B18" roundsSpent)"
  [ "${AF18:-0}" -ge 1 ] 2>/dev/null \
    && ok "18-pre. an apply really did fail in this run ($AF18)" \
    || bad "18-pre. no apply failure occurred — the mixed shape did not reproduce"
  [ "${RS18:-0}" -ge 1 ] 2>/dev/null \
    && ok "18-pre2. …and a later apply really did SUCCEED (a defect round was charged: $RS18)" \
    || bad "18-pre2. no defect round was ever charged, so no apply succeeded; 18a is vacuous"
  [ "${AF18:-0}" -ge 1 ] 2>/dev/null \
    && ok "18a. the apply-failure count SURVIVES the later success — it is cumulative" \
    || bad "18a. applyFailures='$AF18' — a successful apply reset the counter"
  [ "${RS18:-0}" -le 2 ] 2>/dev/null \
    && ok "18b. and the defect rounds stay bounded by the cap (spent $RS18 of 2)" \
    || bad "18b. roundsSpent='$RS18' exceeded the 2-round cap"
  A18="$(grep -c 'self-heal round' "$(ev_of "$B18")" 2>/dev/null | tr -d ' ')"
  [ "${A18:-0}" -le 6 ] 2>/dev/null \
    && ok "18c. the loop terminated inside its attempt backstop ($A18 round event(s))" \
    || bad "18c. $A18 round events — the loop ran past cap+applyCap"
  git -C "$B18/repo" worktree remove --force "$B18/holder" >/dev/null 2>&1
fi

# ===========================================================================
# 19. S320 FIX ROUND 1 — A BRANCH THAT IS PROVABLY REPAIRED IS NOT PARKED.
#
#     The other direction of D18, and the cost of its cure. 3/3 reproducible
#     on a fresh tester's rig 2026-10-23. THIS IS THE CASE THE ORIGINAL
#     APPLY-FAILURE COMMENT WAS WRITTEN TO PROTECT — "the work may have landed
#     by another route" — and the first cut of the cure broke it:
#
#       the mission branch is HELD, so the rebuild cannot land; while the
#       worker runs, an UNRELATED commit repairs src/b.js ON the branch. The
#       worker RESTATES the ticket's own declared test, so the full-suite gate
#       re-runs the ticket's REAL test at the tip — a genuine, non-vacuous
#       green. The branch is provably fine: src/b.js at the tip reads
#       `=> true` and `tests/t-002.test.js` run BY HAND at the tip exits 0.
#
#     The harness nonetheless parked it (awaitingHuman, stage implement,
#     stopReason heal-unverified) and its headline asserted as FACT something
#     the tip contradicted: "the repair is NOT on the branch".
#
#     COMMIT-SHA IDENTITY IS A CORRELATE of "is the branch actually fixed".
#     The thing itself is the ticket's declared proof test, PRESENT at the tip
#     and PASSING there — which is precisely the check the escalation text was
#     already telling the captain to perform by hand. The harness does it
#     instead of asking, and resolves under its OWN reason (healed-elsewhere),
#     never borrowing `healed`'s "the rebuild landed" story.
#
#     The control that separates this from section 17 is ONE variable: there
#     the declared proof test is ABSENT at the tip (the worker wrote a NEW file
#     that only exists in the unlanded commit), so the green is VACUOUS and the
#     park is right. Here it is PRESENT and PASSES.
# ===========================================================================
echo "-- 19. S320: a provably-repaired branch resolves instead of parking --"
B19="$(mkrig)"; mkworker "$B19"
git -C "$B19/repo" worktree add -q "$B19/holder" "lcars/$MID" >/dev/null 2>&1
HOLD19=$?
if [ "$HOLD19" -ne 0 ] || [ ! -d "$B19/holder" ]; then
  skip "19: could not hold the mission branch in a second worktree — SKIPPING"
else
  # The DEFAULT worker (it RESTATES the ticket's own test, so the gate's green
  # is non-vacuous), plus an unrelated commit that repairs the break ON the
  # branch while the worker is out — committed from the HOLDER worktree, which
  # is the thing holding the branch, i.e. exactly the live shape.
  drive "$B19" LCARS_SELFHEAL_CAP=3 \
    RIG_AFTER_WORKER="printf 'exports.ok = () => true;\n' > '$B19/holder/src/b.js'; git -C '$B19/holder' add -A; git -C '$B19/holder' commit -qm 'unrelated fix: landed by another route'"
  EV19="$(ev_of "$B19")"; PQ19="$(pq "$B19")"; H19="$(headline "$DRIVE_OUT")"

  # --- did the scenario reproduce? Everything below is vacuous if not.
  [ "$(tdlog "$B19")" -ge 1 ] 2>/dev/null \
    && ok "19-pre1. a reconcile worker really was dispatched" \
    || bad "19-pre1. no worker ran — the case is vacuous: $(printf '%s' "$DRIVE_OUT" | tail -3)"
  grep -q '"type":"selfheal_apply_failed"' "$EV19" 2>/dev/null \
    && ok "19-pre2. …and its rebuild was green and would NOT land (the branch is held)" \
    || bad "19-pre2. no apply failure — the false-stop precondition did not reproduce"

  # --- GROUND TRUTH AT THE TIP: the branch really is repaired. Read from git
  #     and from running the ticket's own test by hand, never off a claim.
  case "$(tip_blob "$B19" src/b.js)" in
    *"=> true"*) ok "19-gt1. GROUND TRUTH: src/b.js at the branch tip is REPAIRED" ;;
    *) bad "19-gt1. the branch tip is not repaired, so this is not the false-stop case: $(tip_blob "$B19" src/b.js | tr '\n' ' ')" ;;
  esac
  tip_has "$B19" tests/t-002.test.js \
    && ok "19-gt2. GROUND TRUTH: the ticket's DECLARED proof test IS on the branch" \
    || bad "19-gt2. the ticket's declared test is absent from the tip — that is section 17, not this"
  handrun "$B19" tests/t-002.test.js \
    && ok "19-gt3. GROUND TRUTH: the ticket's OWN test EXITS 0 when run by hand at the tip" \
    || bad "19-gt3. the ticket's own test fails at the tip — the branch is not provably fine"

  # --- THE DEFECT: it must not park, and it must not assert an absence.
  [ "$(led "$B19" stopReason)" = heal-unverified ] \
    && bad "19a. FALSE STOP: a provably-repaired branch is parked as heal-unverified" \
    || ok "19a. the provably-repaired branch is NOT parked as heal-unverified"
  [ -z "$(sfield "$B19" awaitingHuman)" ] && [ -z "$PQ19" ] \
    && ok "19b. …no human gate is raised over a branch the harness can verify itself" \
    || bad "19b. parked: awaitingHuman='$(sfield "$B19" awaitingHuman)' pendingQuestion='$(printf '%s' "$PQ19" | head -1 | cut -c1-120)'"
  [ "$(sfield "$B19" stage)" = verify ] \
    && ok "19c. …and the mission ADVANCES to Verify" \
    || bad "19c. the mission did not advance: stage='$(sfield "$B19" stage)'"
  case "$H19$PQ19" in
    *"NOT on the branch"*|*"NOT on the mission branch"*|*"ABSENT from the branch"*)
      bad "19d. it asserts the repair is absent while the tip contradicts it: $H19" ;;
    *) ok "19d. nothing asserts the repair is absent from a branch that carries it" ;;
  esac

  # --- AND IT RESOLVES UNDER ITS OWN REASON, not by borrowing `healed`'s story.
  [ "$(led "$B19" stopReason)" = healed-elsewhere ] \
    && ok "19e. it resolves under its OWN stop reason: healed-elsewhere" \
    || bad "19e. ledger stopReason='$(led "$B19" stopReason)' — expected healed-elsewhere"
  grep -q '"type":"selfheal_ok"' "$EV19" 2>/dev/null \
    && ok "19f. a selfheal_ok is emitted — the heal is real and it is claimed" \
    || bad "19f. no selfheal_ok: $(grep -o '"type":"selfheal[a-z_]*"' "$EV19" 2>/dev/null | sort -u | tr '\n' ' ')"
  OK19="$(grep '"type":"selfheal_ok"' "$EV19" 2>/dev/null | head -1)"
  case "$OK19" in
    *"rebuild LANDED"*) bad "19g. it claims the rebuild LANDED when the apply failed: $(printf '%s' "$OK19" | cut -c1-240)" ;;
    *) ok "19g. …and it does NOT claim the rebuild landed" ;;
  esac
  case "$OK19" in
    *"declared"*|*"another route"*|*"at the tip"*)
      ok "19h. …it says HOW it knows: the ticket's declared test was run at the tip" ;;
    *) bad "19h. the message does not say what was verified: $(printf '%s' "$OK19" | cut -c1-240)" ;;
  esac
  # --- the honest accounting survives: the apply failure is still recorded and
  #     no defect round is charged for an infrastructure fault.
  [ "$(led "$B19" applyFailures)" -ge 1 ] 2>/dev/null \
    && ok "19i. the apply failure is STILL recorded on the ledger: $(led "$B19" applyFailures)" \
    || bad "19i. ledger applyFailures='$(led "$B19" applyFailures)' — the failure was swallowed"
  [ "$(led "$B19" roundsSpent)" = 0 ] \
    && ok "19j. …and NO defect round is charged — nothing here was about code" \
    || bad "19j. ledger roundsSpent='$(led "$B19" roundsSpent)'"
  git -C "$B19/repo" worktree remove --force "$B19/holder" >/dev/null 2>&1
fi

# ===========================================================================
# 13. ZERO MODEL SPEND, AUDITED FROM THE HARNESS'S OWN LEDGER. The worker is a
#     PURE FAKE ($base/worker) and every dispatch above was handed to it via
#     $LCARS_WORKER_BIN, so each mission's usage.json must total ZERO cost. A
#     tester once invoked a script WITHOUT the shim and a real session ran
#     ($1.16 of the captain's money, 2026-10-22); this check is why that cannot
#     pass silently in this suite.
# ===========================================================================
echo "-- 13. zero model spend, audited from the harness's own usage ledger --"
cost_of() { # usage.json → total cost, or "" when there is nothing to read
  "${LCARS_PYTHON_BIN:-python3}" -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(0); raise SystemExit
r=d.get("records",d) if isinstance(d,dict) else d
t=0.0
for x in (r if isinstance(r,list) else []):
    if isinstance(x,dict):
        try: t+=float(x.get("costUsd",x.get("cost",0)) or 0)
        except Exception: pass
print(t)' "$1" 2>/dev/null
}
C13=0; U13=0
while IFS= read -r b; do
  [ -n "$b" ] || continue
  U13f="$b/repo/.git/lcars/missions/$MID/usage.json"
  [ -f "$U13f" ] || continue
  U13=$((U13+1))
  case "$(cost_of "$U13f")" in
    ''|0|0.0|0.00) : ;;
    *) C13=$((C13+1)); printf '    non-zero cost in %s: %s\n' "$U13f" "$(cost_of "$U13f")" ;;
  esac
done <"$BASEFILE"
[ "$C13" = 0 ] \
  && ok "13a. all $U13 usage ledger(s) total \$0 — every dispatch went to the pure-fake shim" \
  || bad "13a. $C13 fixture(s) recorded a non-zero model cost — a real session ran"
# The shim's own invocation count, summed over every fixture. This is the
# number to quote when someone asks "how many model sessions did that suite
# cost?" — the answer is 0, and this is how many went to the fake instead.
N13=0
while IFS= read -r b; do
  [ -n "$b" ] || continue
  n="$(grep -c 'role=implement-tdd' "$b/dispatch.log" 2>/dev/null | tr -d ' ')"
  N13=$((N13 + ${n:-0}))
done <"$BASEFILE"
printf '  note SHIM INVOCATIONS: %s implement-tdd dispatch(es), all to the pure-fake worker, $0 billed\n' "$N13"
# S320: AND THE OTHER SHIM — mkflatrepo's PATH-shimmed `claude` AND `copilot`.
# $LCARS_WORKER_BIN is only one of the three ways an engine arrives, so the
# zero-spend claim is not "the env var was set", it is "both binary names were
# shadowed by a pure fake and here is how many times either was reached". The
# shims record `model=yes` when the invocation carried a `--model` flag, i.e.
# when it would have selected and billed a model.
P13=0; M13=0
while IFS= read -r b; do
  [ -n "$b" ] || continue
  [ -f "$b/worker-calls.log" ] || continue
  n="$(grep -c . "$b/worker-calls.log" 2>/dev/null | tr -d ' ')"; P13=$((P13 + ${n:-0}))
  n="$(grep -c 'model=yes' "$b/worker-calls.log" 2>/dev/null | tr -d ' ')"; M13=$((M13 + ${n:-0}))
done <"$BASEFILE"
printf '  note MODEL-CLI SHIM: %s invocation(s) of the faked `claude`/`copilot` across every fixture, %s of them carrying --model\n' "$P13" "$M13"
[ "$P13" = 0 ] \
  && ok "13b. the faked claude/copilot binaries were NEVER reached in ANY fixture" \
  || bad "13b. $P13 invocation(s) of a model CLI ($M13 with --model) — only the shim stood between that and real spend"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
