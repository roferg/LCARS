#!/usr/bin/env bash
#
# S313 — A REGRESSION-LOCK TICKET IS LANDABLE.
#
# THE DEFECT (measured on a real mission, on a ticket titled "Lock today's
# anchor-less comment thread rendering with golden tests": NINE Copilot TDD
# sessions, three human gates). A pure regression-lock ticket — golden / characterisation tests over
# behaviour that ALREADY EXISTS — cannot satisfy the proof gates at all:
#
#   1. the FLIP-FLOP gate fails it, because its tests pass on the PARENT by
#      construction (a characterisation test asserts existing behaviour);
#   2. the RESULT-V2 gate refuses the escape — `flipFlop: "not-applicable"`
#      beside a non-empty `newTests` is rejected with "a ticket that authors
#      tests must expect them to flip. Declare flipFlop 'expected', or drop the
#      tests" — but the tests ARE the deliverable, so dropping them drops the
#      ticket.
#
# Each gate is individually CORRECT. Jointly they are impossible, and LCARS
# PLAN WROTE THAT TICKET ITSELF. Resolved by hand on the real mission by
# dropping the standalone ticket and folding its golden corpus into the ticket
# that CHANGES the behaviour, whose own new tests flip red→green legitimately:
# "guard preserved, proof honest."
#
# WHAT THIS SUITE PINS
#   A. PLAN does not emit the shape — the REAL Plan path (cold worker → real
#      plan-save → real validate_plan_json) REFUSES a plan that carries a
#      standalone regression-lock ticket beside the ticket it guards, and the
#      refusal NAMES THE FOLD. Non-deadlocking: a plan whose tickets are ALL
#      locks (no fold target exists) is NOT refused, and an ordinary plan is
#      untouched.
#   B. THE GOLDENS SURVIVE — the folded ticket (goldens green-on-parent +
#      its own new behaviour test red-on-parent, all declared) PASSES every
#      real gate, with the golden file in the committed diff.
#   C. THE REFUSALS NAME THE ESCAPE — a no-red flip-flop refusal and the
#      result-v2 refusal both say where the goldens belong, and both say that
#      `flipFlop: "not-applicable"` is NOT the way out. (The finding: that one
#      sentence is what made the timeout verdict diagnosable in a single read.)
#   D. REGRESSION LOCKS — nothing here relaxes a gate:
#      D1. genuinely new tests + `not-applicable` is STILL REFUSED;
#      D2. the INITIALIZATION scaffold exemption still waives, a later ticket
#          still cannot, and an unreadable mission ordering still fails CLOSED.
#
# Zero model spend: the Plan worker is a PATH shim (it copies a plan file this
# suite wrote); the gates run real git + real `node --test` on tiny fixtures.
#
# Usage: bash tests/regression-lock.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
PLAN_MD="$REPO_ROOT/skills/lcars-run/stages/plan.md"
# The cold-worker CLI flags live in worker-adapter.sh, keyed off the worker
# binary's basename (`claude` in production). This suite stubs the worker under a
# generic name, so point the cli id at the claude adapter for the whole suite —
# the same arrangement tests/lcars-context.test.sh uses.
export LCARS_WORKER_CLI="${LCARS_WORKER_CLI:-claude}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ==========================================================================
# Fixtures — the Plan half
# ==========================================================================
# A worker shim that writes WHATEVER plan file $PLANSRC names. It is the only
# "model" in the Plan half, and it records every invocation so an empty log is a
# MEASURED zero rather than an assumed one.
make_plan_worker() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'role=%s\n' "${LCARS_WORKER_ROLE:-?}" >>"$WORKER_LOG"
printf '%s' "$prompt" >"$WORKER_CALLS/${LCARS_WORKER_ROLE:-x}.$$.txt"
case "${LCARS_WORKER_ROLE:-}" in
  plan) [ -n "${PLANSRC:-}" ] && cp "$PLANSRC" "$LCARS_WORK_OUT/plan.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
}

plan_repo() { # → echoes repo dir, one mission parked at stage `plan`
  local repo; repo="$(mktemp -d "$TMPROOT/plan.XXXX")"
  (
    cd "$repo" && git init -q -b main \
      && git config user.email t@t && git config user.name t \
      && printf '# fixture\n' > README.md \
      && printf '# Context\n\nA fixture repo.\n' > CONTEXT.md \
      && git add -A && git commit -qm init
  ) >/dev/null 2>&1
  local m="$repo/.git/lcars/missions/test-001"; mkdir -p "$m"
  printf '{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": "CONTEXT.md" }\n' \
    > "$repo/.git/lcars/config.json"
  cat > "$m/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "Render the anchor chip",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main"
}
JSON
  cat > "$m/prd.md" <<'MD'
# Mission: Render the anchor chip
**Type:** feature
**Goal:** Show which comment a thread is anchored to.
**Acceptance Criteria:**
- An anchored thread shows its chip
**Out of Scope:**
- Editing anchors
**Constraints:**
- The existing renderer
MD
  cat > "$m/validated-plan.md" <<'MD'
# Validated Plan
## Synthesis
x
## Decisions
- y
## Rationale
z
MD
  echo "$repo"
}

# Drive the REAL Plan stage: real cmd_plan → real plan-save → real
# validate_plan_json. Sets PRC + POUT. $3 is LCARS_WORKER_TRIES (default 1).
#
# READ THE TRIES COUNT BEFORE ASSERTING A REFUSAL HERE. cmd_plan passes
# `--final-attempt` to plan-save when `tries >= MAX_WORKER_TRIES`, so with
# LCARS_WORKER_TRIES=1 the FIRST attempt is also the LAST one and every
# advisory-on-final guard is already advisory. That is why the refusal cases
# below drive `plan_save` (the subcommand cmd_plan itself invokes, one attempt
# at a time) rather than this whole-stage driver: it is the only way to see a
# NON-final attempt.
run_plan() { # repo plan-file [tries]
  local repo="$1" src="$2" bin="$1.bin"
  rm -rf "$bin"; mkdir -p "$bin/calls"
  make_plan_worker "$bin/worker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/gh"; chmod +x "$bin/gh"
  : >"$bin/worker.log"
  POUT="$( cd "$repo" && env \
      WORKER_LOG="$bin/worker.log" WORKER_CALLS="$bin/calls" PLANSRC="$src" \
      LCARS_WORKER_BIN="$bin/worker" LCARS_GH_BIN="$bin/gh" \
      LCARS_GIT_BIN="$(command -v git)" LCARS_WORKER_TRIES="${3:-1}" \
      bash "$SCRIPT" plan --mission test-001 2>&1 )"
  PRC=$?
  PLAN_PROMPT="$(cat "$bin"/calls/plan.*.txt 2>/dev/null)"
  SHIM_CALLS="$(grep -c 'role=' "$bin/worker.log" 2>/dev/null || echo 0)"
}

# Drive ONE attempt of the real `plan-save` subcommand — exactly the entry
# cmd_plan uses per attempt, real validate_plan_json and all. $3 == "final"
# passes `--final-attempt`, which is what cmd_plan passes on the LAST attempt
# and nothing else. Sets PRC + POUT, and PNOTE = the reject note the next
# worker would be handed.
plan_save() { # repo plan-file [final]
  local repo="$1" src="$2" flag="" wd
  [ "${3:-}" = final ] && flag=--final-attempt
  wd="$(mktemp -d "$TMPROOT/ps.XXXX")"
  cp "$src" "$wd/plan.json"
  POUT="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      bash "$SCRIPT" plan-save --mission test-001 --plan "$wd/plan.json" $flag 2>&1 )"
  PRC=$?
  PNOTE="$(cat "$wd/.plan-reject-note" 2>/dev/null)"
}

# Does $2 appear BEFORE $3 in $1? "Leads" is a byte position, not a vibe.
leads() { # text first second
  python3 - "$1" "$2" "$3" <<'PY'
import sys
t, a, b = (x.lower() for x in sys.argv[1:4])
ia, ib = t.find(a), t.find(b)
sys.exit(0 if ia >= 0 and ib >= 0 and ia < ib else 1)
PY
}

# A ticket in the CANONICAL one-field-per-line plan.json shape.
ticket() { # id title newloc testloc criteria-json deps-json
  cat <<JSON
  {
    "id": "$1",
    "title": "$2",
    "description": "d",
    "acceptanceCriteria": $5,
    "estimatedReadLoc": 120,
    "estimatedTestLoc": $4,
    "estimatedNewLoc": $3,
    "dependencies": $6,
    "rationale": "r"
  }
JSON
}

# ==========================================================================
# A. PLAN DOES NOT EMIT THE SHAPE (cure A), through the REAL Plan path
# ==========================================================================
echo "== A. Plan refuses a standalone regression-lock ticket =="

# The measured plan, in miniature: t-002 is the lock (golden tests over today's
# rendering, no new production code), t-005 is the ticket whose behaviour it
# guards.
mixed="$TMPROOT/plan-mixed.json"
{
  echo '['
  ticket t-002 "Lock today's anchor-less comment thread rendering with golden tests" \
    0 90 '["The current anchor-less thread markup is captured as a golden file", "Any change to that markup fails the golden test"]' '[]'
  echo '  ,'
  ticket t-005 "Render the anchor chip on an anchored thread" \
    140 80 '["An anchored thread shows a chip naming its anchor"]' '["t-002"]'
  echo ']'
} > "$mixed"

# THE CONTROL FOR THE WHOLE ADVISORY RULING (section E): on a NON-FINAL
# attempt — every attempt but the planner's last — this rule still REFUSES.
r1="$(plan_repo)"; plan_save "$r1" "$mixed"
if [ "$PRC" != 0 ]; then
  ok "A1. a NON-FINAL attempt REFUSES a plan carrying a standalone regression-lock ticket"
else
  bad "A1. the plan was ACCEPTED (rc 0) — the shape still ships: $POUT"
fi
if [ -n "$PNOTE" ] && printf '%s' "$PNOTE" | grep -qi 'regression-lock'; then
  ok "A1b. and the reason is left in the reject note the NEXT attempt is handed"
else
  bad "A1b. the refusal never reaches the retrying worker: note=[$PNOTE]"
fi
[ ! -f "$r1/.git/lcars/missions/test-001/plan.json" ] \
  && ok "A2. no plan.json was installed, so the Mission did not advance on it" \
  || bad "A2. plan.json was installed despite the refusal"
if printf '%s' "$POUT" | grep -qi 'fold'; then
  ok "A3. the refusal NAMES THE FOLD (the cure, not just the complaint)"
else
  bad "A3. the refusal does not name the fold: $POUT"
fi
if printf '%s' "$POUT" | grep -q 't-002' && printf '%s' "$POUT" | grep -q 't-005'; then
  ok "A4. it names the offending ticket AND a ticket to fold it into"
else
  bad "A4. the refusal names neither the lock ticket nor a fold target: $POUT"
fi
# The whole point of the refusal is that the GUARD IS KEPT. A refusal that
# reads as "delete the golden tests" would trade the defect for a worse one.
if printf '%s' "$POUT" | grep -qiE 'golden|characteri[sz]ation' \
   && ! printf '%s' "$POUT" | grep -qiE 'delete (the )?(golden|test)|drop the golden'; then
  ok "A5. the refusal keeps the goldens — it relocates them, it does not delete them"
else
  bad "A5. the refusal reads as dropping the guard: $POUT"
fi

# --- NON-DEADLOCK (the S175 lesson: a rule with no honest answer is a trap) --
echo "== A'. the rule cannot deadlock a plan that has no fold target =="
alllock="$TMPROOT/plan-alllock.json"
{
  echo '['
  ticket t-001 "Lock today's thread rendering with golden tests" \
    0 90 '["Todays markup is captured as a golden file"]' '[]'
  echo '  ,'
  ticket t-002 "Lock the existing comment list rendering with golden tests" \
    0 70 '["The current list markup is captured as a golden file"]' '[]'
  echo ']'
} > "$alllock"
r2="$(plan_repo)"; plan_save "$r2" "$alllock"
if [ "$PRC" = 0 ]; then
  ok "A7. a plan whose tickets are ALL locks is NOT refused (nothing to fold into)"
else
  bad "A7. an all-lock plan was refused — that is a deadlock, not a cure: $POUT"
fi

# --- the ordinary plan is untouched (positive control) ----------------------
plain="$TMPROOT/plan-plain.json"
{
  echo '['
  ticket t-001 "Render the anchor chip on an anchored thread" \
    140 80 '["An anchored thread shows a chip naming its anchor"]' '[]'
  echo ']'
} > "$plain"
r3="$(plan_repo)"; run_plan "$r3" "$plain"
if [ "$PRC" = 0 ] && [ -f "$r3/.git/lcars/missions/test-001/plan.json" ]; then
  ok "A8. control: an ordinary plan still validates and installs"
else
  bad "A8. an ordinary plan broke (rc=$PRC): $POUT"
fi
# N1 REGRESSION: an HONEST plan installs on EVERY attempt, final or not. The
# advisory ruling must not be readable from an honest plan at all.
r3b="$(plan_repo)"; plan_save "$r3b" "$plain"
if [ "$PRC" = 0 ] && [ -f "$r3b/.git/lcars/missions/test-001/plan.json" ]; then
  ok "A8b. an ordinary plan installs on a NON-FINAL attempt too"
else
  bad "A8b. an ordinary plan was refused on a non-final attempt (rc=$PRC): $POUT"
fi
r3c="$(plan_repo)"; plan_save "$r3c" "$plain" final
if [ "$PRC" = 0 ] && [ -f "$r3c/.git/lcars/missions/test-001/plan.json" ] \
   && ! printf '%s' "$POUT" | grep -qi 'regression-lock'; then
  ok "A8c. and on the FINAL attempt, with no lock-shape warning attached"
else
  bad "A8c. an ordinary final attempt broke or grew a warning (rc=$PRC): $POUT"
fi

# A lock-SOUNDING ticket that declares real production code is NOT the shape —
# narrowness, so the rule cannot start eating honest tickets.
narrow="$TMPROOT/plan-narrow.json"
{
  echo '['
  ticket t-001 "Lock the existing rendering behind a golden test AND add the chip" \
    140 80 '["An anchored thread shows a chip naming its anchor"]' '[]'
  echo '  ,'
  ticket t-002 "Persist the anchor choice" \
    90 40 '["The choice survives a reload"]' '[]'
  echo ']'
} > "$narrow"
r4="$(plan_repo)"; plan_save "$r4" "$narrow"
if [ "$PRC" = 0 ]; then
  ok "A9. a lock-WORDED ticket that declares net-new production code is NOT refused"
else
  bad "A9. the rule is too wide — it refused a ticket that changes behaviour: $POUT"
fi

# --- THE LIVE PLANNER ARTIFACTS (not a hand-written miniature) ---------------
# tests/fixtures/s313-live-plan/ holds two REAL Copilot Plan outputs for the
# same PRD, one line of prompt apart (see its README). The first was emitted at
# pristine HEAD and carries the unlandable shape the planner chose BY ITSELF —
# which is the whole finding: Plan creates this ticket. Feed it to the REAL
# validator; the second is the folded shape that must stay accepted.
LIVE_FIX="$REPO_ROOT/tests/fixtures/s313-live-plan"
r5="$(plan_repo)"; plan_save "$r5" "$LIVE_FIX/standalone-lock-plan.json"
if [ "$PRC" != 0 ] && printf '%s' "$POUT" | grep -qi 'fold'; then
  ok "A11. a LIVE planner's own standalone-lock plan is refused, with the fold named"
else
  bad "A11. the live planner's bad plan was accepted (rc=$PRC): $POUT"
fi
r6="$(plan_repo)"; run_plan "$r6" "$LIVE_FIX/folded-plan.json"
if [ "$PRC" = 0 ] && [ -f "$r6/.git/lcars/missions/test-001/plan.json" ]; then
  ok "A12. and the LIVE planner's FOLDED plan (goldens ride along) still installs"
else
  bad "A12. the folded live plan was refused (rc=$PRC): $POUT"
fi

# The planner must be TOLD the rule, not merely punished by it.
if grep -qiE 'regression[ -]lock|characteri[sz]ation' "$PLAN_MD" \
   && grep -qi 'fold' "$PLAN_MD"; then
  ok "A10. the Plan stage prompt teaches the fold before the validator enforces it"
else
  bad "A10. stages/plan.md never mentions the regression-lock rule"
fi

# ==========================================================================
# E. THE RULE CANNOT DEADLOCK THE STAGE — advisory on the LAST attempt
# ==========================================================================
# MEASURED (fix round 1): with a worker that keeps emitting the standalone-lock
# plan and LCARS_WORKER_TRIES=3, the refusal correctly reached attempts 2 and 3
# and the Stage then DIED — "failed validation after 3 attempt(s) — Stage
# stopped, no advance", stage still `plan`, NO awaitingHuman, NO pendingQuestion.
# The card read "in Plan" while the Mission was dead: exactly the invisibility
# S312 had just cured.
#
# THE RULING: gate the rule on FINAL_ATTEMPT, matching its neighbour. run.sh
# says why in its own words at the over-correction guard — "a valid plan must
# never deadlock the Stage on this guard". Safe because this rule is PREVENTIVE,
# not the enforcement: if a lock plan does install on the last attempt, the
# ticket still meets the flip-flop refusal, which since S313 names the fold and
# forecloses `not-applicable` by name. Caught one step later, by the gate that
# was always going to catch it.
echo "== E. the lock-shape rule goes ADVISORY on the final attempt =="
r7="$(plan_repo)"; plan_save "$r7" "$mixed" final
if [ "$PRC" = 0 ] && [ -f "$r7/.git/lcars/missions/test-001/plan.json" ]; then
  ok "E1. on the FINAL attempt the plan INSTALLS — the Stage is not deadlocked"
else
  bad "E1. the final attempt still refused (rc=$PRC) — this is the deadlock: $POUT"
fi
if printf '%s' "$POUT" | grep -qi 'regression-lock' \
   && printf '%s' "$POUT" | grep -qiE 'unresolved|saved|warning'; then
  ok "E2. and it SAYS SO — installed with the lock-shape warning, not silently"
else
  bad "E2. the advisory pass is silent — the plan slipped through unrecorded: $POUT"
fi
if printf '%s' "$POUT" | grep -qi 'fold' && printf '%s' "$POUT" | grep -q 't-002'; then
  ok "E3. the warning still names the shape, the ticket and the cure"
else
  bad "E3. the warning drops the diagnosis: $POUT"
fi
if printf '%s' "$POUT" | grep -qi 'plan-review' \
   || [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stage"])' \
          "$r7/.git/lcars/missions/test-001/state.json" 2>/dev/null)" = plan-review ]; then
  ok "E4. the Mission advanced to Plan Review, which gets the plan AND the warning"
else
  bad "E4. the Mission did not advance on the advisory pass: $POUT"
fi
# AND THE WHOLE STAGE, END TO END, with a worker that never folds: three
# attempts, the refusal carried into 2 and 3, then an advisory save. No
# "Stage stopped, no advance".
r8="$(plan_repo)"; run_plan "$r8" "$mixed" 3
if [ "$PRC" = 0 ] && [ -f "$r8/.git/lcars/missions/test-001/plan.json" ]; then
  ok "E5. the real Plan STAGE now completes against an unfolding planner"
else
  bad "E5. the Plan stage still dies on a stubborn planner (rc=$PRC): $POUT"
fi
if ! printf '%s' "$POUT" | grep -qi 'Stage stopped, no advance'; then
  ok "E6. and never prints \"Stage stopped, no advance\" over a live Mission"
else
  bad "E6. the silent hard stop survives: $POUT"
fi
[ "${SHIM_CALLS:-0}" -ge 1 ] \
  && ok "E7. positive control: the PATH-shimmed planner was really invoked ($SHIM_CALLS call(s))" \
  || bad "E7. the worker shim was never called — the Plan path did not run"
if printf '%s' "$PLAN_PROMPT" | grep -qi 'regression-lock'; then
  ok "E8. and the refusal still reached the retrying worker's prompt"
else
  bad "E8. the non-final refusal never reached a retry prompt"
fi

# ==========================================================================
# G. A LOCK NO TICKET GUARDS IS NOT TOLD TO FOLD INTO AN UNRELATED TICKET
# ==========================================================================
# MEASURED (fix round 1): a plan of t-001 "Add a dark-mode toggle" + t-002
# "Lock today's CSV export column order with golden tests" was told, as its
# PRIMARY instruction, to fold the CSV lock into the dark-mode toggle. The
# honest out — it is not this Mission scope — existed but came last.
#
# The cure computes NO semantic relatedness (that is an inference trap). It
# reads the only honest, cheap signal there is: a DEPENDENCY EDGE the planner
# ITSELF declared between a lock ticket and a non-lock ticket. That is the
# planner's own written claim that the two are about the same thing, and it is
# the link the measured mission had (t-005 depended on t-002).
echo "== G. the honest option leads when no ticket plausibly guards the behaviour =="
unrelated="$TMPROOT/plan-unrelated.json"
{
  echo '['
  ticket t-001 "Add a dark-mode toggle" \
    90 60 '["The toggle flips the theme and the choice survives a reload"]' '[]'
  echo '  ,'
  ticket t-002 "Lock today's CSV export column order with golden tests" \
    0 50 '["The current CSV column order is captured as a golden file"]' '[]'
  echo ']'
} > "$unrelated"
r9="$(plan_repo)"; plan_save "$r9" "$unrelated"
[ "$PRC" != 0 ] \
  && ok "G1. the unrelated-lock plan is still REFUSED (nothing was relaxed)" \
  || bad "G1. the lock shape was accepted (rc 0): $POUT"
if leads "$POUT" "NOT THIS MISSION" "FOLD IT"; then
  ok "G2. with NO plausible fold target, the OUT-OF-SCOPE option LEADS"
else
  bad "G2. the fold into an unrelated ticket still leads: $POUT"
fi
if printf '%s' "$POUT" | grep -qi 'fold'; then
  ok "G3. and the fold is still offered, second and CONDITIONALLY"
else
  bad "G3. the fold option vanished entirely: $POUT"
fi
# WITH a declared edge — the measured shape — the fold LEADS, as it should.
r10="$(plan_repo)"; plan_save "$r10" "$mixed"
if leads "$POUT" "FOLD IT" "NOT THIS MISSION"; then
  ok "G4. with a DECLARED dependency edge to the lock, the FOLD still leads"
else
  bad "G4. the fold no longer leads on the measured shape: $POUT"
fi
if printf '%s' "$POUT" | grep -q 't-005'; then
  ok "G5. and it names the linked ticket as the target, not every ticket at once"
else
  bad "G5. the refusal does not name the linked fold target: $POUT"
fi
# N2, the PLAN half: the refusal must never read as an offer to bin the goldens.
if ! printf '%s' "$POUT" | grep -qiE 'drop the tests|delete the tests|remove the tests|drop the golden|delete the golden|drop the goldens'; then
  ok "G6. no part of the plan refusal OFFERS to drop the goldens"
else
  bad "G6. the plan refusal offers to drop the guard: $POUT"
fi

# ==========================================================================
# B/C. The gate half — real git, real runner
# ==========================================================================
if ! have node; then
  skip "B/C. node absent — the gate half needs a real runner"
  printf '\nregression-lock: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

scaffold_mission() { # repo [type]
  mkdir -p "$1/.git/lcars/missions/m-001/tickets/t-001"
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement"%s }\n' \
    "${2:+, \"missionType\": \"$2\"}" \
    > "$1/.git/lcars/missions/m-001/state.json"
}

new_js_repo() { # → repo whose parent commit has src/calc.js (add only)
  local repo; repo="$(mktemp -d "$TMPROOT/js.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/src"
  printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo" "${1:-}"
  echo "$repo"
}

head_sha()  { ( cd "$1" && git rev-parse HEAD ); }
commit_all() { ( cd "$1" && git add -A && git commit -qm tip ); }
TD() { echo "$1/.git/lcars/missions/m-001/tickets/t-001"; }

write_result() { # dir newTests-json testEdits-json flipFlop [reason]
  local extra=""
  [ -n "${5:-}" ] && extra=", \"flipFlopReason\": \"$5\""
  cat > "$1/result.json" <<JSON
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": $2, "testEdits": $3, "flipFlop": "$4"$extra }
JSON
}

NODE_CMD='node --test $LCARS_TESTS_DIR'

ff_gate() { # repo parent-sha → FFRC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git LCARS_TEST_CMD="$NODE_CMD" \
          bash "$SCRIPT" flip-flop-gate-test --mission m-001 --ticket t-001 --sha "$2" 2>&1 )"
  FFRC="$(printf '%s\n' "$OUT" | sed -n 's/^FFRC=//p' | tail -1)"
}
de_guard() { # repo parent-sha → DERC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git LCARS_TEST_CMD="$NODE_CMD" \
          bash "$SCRIPT" declared-edits-guard-test --mission m-001 --ticket t-001 --sha "$2" 2>&1 )"
  DERC="$(printf '%s\n' "$OUT" | sed -n 's/^DERC=//p' | tail -1)"
}
q_floor() { # repo parent-sha → QFRC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git LCARS_TEST_CMD="$NODE_CMD" \
          bash "$SCRIPT" proof-quality-floor-test --mission m-001 --ticket t-001 --sha "$2" 2>&1 )"
  QFRC="$(printf '%s\n' "$OUT" | sed -n 's/^QFRC=//p' | tail -1)"
}
pv_result() { # repo mission ticket result-file → PVRC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" proof-validate-result-test --mission "$2" --ticket "$3" --result "$4" 2>&1 )"
  PVRC="$(printf '%s\n' "$OUT" | sed -n 's/^PVRC=//p' | tail -1)"
}
ff_reason() { # flip-flop.json
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"])' "$1" 2>/dev/null
}

# The pre-S313 green-parent rejection sentence, verbatim. The ESCAPE is added
# AROUND the recorded reason, never inside it: tests/proof-gates.test.sh pins
# this string byte for byte (C5b) and that pin must keep holding.
LEGACY_GREEN_PARENT_REASON="the ticket's tests PASS on the PARENT commit — red-on-parent is not proven (a test that asserts pre-existing behavior is not proof of work)"

# --- the GOLDEN corpus + the behaviour test it rides along with -------------
write_golden() { # repo — a CHARACTERISATION test: true on the parent already
  cat > "$1/src/calc.golden.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('./calc.js');
test('GOLDEN: add keeps todays behaviour', () => {
  assert.strictEqual(add(2, 2), 4);
  assert.strictEqual(add(0, 0), 0);
});
JS
}
write_new_behaviour() { # repo — a NEW test + the code that makes it pass
  cat > "$1/src/calc.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { mul } = require('./calc.js');
test('mul multiplies', () => { assert.strictEqual(mul(2, 3), 6); });
JS
  printf 'exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\n' > "$1/src/calc.js"
}

echo "== B. THE GOLDENS SURVIVE — the folded ticket lands =="
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_golden "$repo"           # the corpus the dropped lock ticket was going to own
write_new_behaviour "$repo"    # the ticket whose behaviour they guard
commit_all "$repo"
write_result "$(TD "$repo")" \
  '["src/calc.test.js", "src/calc.golden.test.js"]' '[]' expected
ff_gate "$repo" "$P"
[ "$FFRC" = 0 ] \
  && ok "B1. the FOLDED ticket PASSES the flip-flop gate (its own new test supplies the red)" \
  || bad "B1. the folded ticket failed the flip-flop gate (FFRC=$FFRC): $OUT"
de_guard "$repo" "$P"
[ "$DERC" = 0 ] \
  && ok "B2. the golden file rides along as a DECLARED test (declared-edits guard passes)" \
  || bad "B2. declared-edits refused the golden corpus (DERC=$DERC): $OUT"
q_floor "$repo" "$P"
[ "$QFRC" = 0 ] && ok "B3. quality floor passes" || bad "B3. quality floor failed: $OUT"
mkdir -p "$TMPROOT/res-fold.d"
write_result "$TMPROOT/res-fold.d" \
  '["src/calc.test.js", "src/calc.golden.test.js"]' '[]' expected
pv_result "$repo" m-001 t-001 "$TMPROOT/res-fold.d/result.json"
[ "$PVRC" = 0 ] \
  && ok "B4. result-v2 accepts the folded ticket (flipFlop expected, goldens declared)" \
  || bad "B4. result-v2 refused the folded ticket (PVRC=$PVRC): $OUT"
# THE GUARD IS REALLY THERE: committed, and asserting the old behaviour.
if ( cd "$repo" && git ls-tree -r --name-only HEAD | grep -q '^src/calc.golden.test.js$' ) \
   && grep -q 'GOLDEN' "$repo/src/calc.golden.test.js"; then
  ok "B5. the golden corpus is COMMITTED on the tip — the guard is preserved"
else
  bad "B5. the golden corpus is not in the commit — the cure dropped the guard"
fi

echo "== C. the refusals NAME THE ESCAPE =="
# The standalone lock ticket, exactly as the measured one: goldens only, no
# behaviour change, so both legs are green and there is no red to be had.
lockrepo="$(new_js_repo)"; LP="$(head_sha "$lockrepo")"
write_golden "$lockrepo"
commit_all "$lockrepo"
write_result "$(TD "$lockrepo")" '["src/calc.golden.test.js"]' '[]' expected
ff_gate "$lockrepo" "$LP"
[ "$FFRC" = 1 ] \
  && ok "C1. a pure regression-lock ticket still FAILS the flip-flop gate (judgement unchanged)" \
  || bad "C1. expected the green-parent FAIL (FFRC=$FFRC): $OUT"
if printf '%s' "$OUT" | grep -qiE 'characteri[sz]ation|regression[ -]lock' \
   && printf '%s' "$OUT" | grep -qi 'fold'; then
  ok "C2. the refusal NAMES THE ESCAPE: fold the goldens into the ticket they guard"
else
  bad "C2. the no-red refusal still does not name the escape: $OUT"
fi
if printf '%s' "$OUT" | grep -q 'not-applicable'; then
  ok "C3. and it forecloses the FALSE escape by name (not-applicable will be refused)"
else
  bad "C3. the refusal does not mention not-applicable, so the ping-pong survives: $OUT"
fi
ffj="$(TD "$lockrepo")/flip-flop.json"
[ "$(ff_reason "$ffj")" = "$LEGACY_GREEN_PARENT_REASON" ] \
  && ok "C4. the RECORDED reason is still byte-identical to pre-S313" \
  || bad "C4. the recorded reason drifted: $(ff_reason "$ffj")"

# The other half of the vice: the result-v2 refusal.
norepo="$(new_js_repo)"
mkdir -p "$TMPROOT/res-na.d"
write_result "$TMPROOT/res-na.d" '["src/calc.golden.test.js"]' '[]' \
  not-applicable "they assert pre-existing behaviour"
pv_result "$norepo" m-001 t-001 "$TMPROOT/res-na.d/result.json"
if [ "$PVRC" != 0 ] && printf '%s' "$OUT" | grep -qi 'fold'; then
  ok "C5. the result-v2 refusal names the fold too (one read, not nine sessions)"
else
  bad "C5. result-v2 refuses without naming the cure (PVRC=$PVRC): $OUT"
fi

echo "== D. REGRESSION LOCKS — no gate was relaxed =="
# D1 — the rule that stops a worker declaring its way out of proving anything.
if [ "$PVRC" != 0 ] && printf '%s' "$OUT" | grep -q 'must expect them to flip'; then
  ok "D1. new tests + flipFlop not-applicable is STILL REFUSED, in the old words"
else
  bad "D1. the waiver-plus-newTests rule changed (PVRC=$PVRC): $OUT"
fi

# D2 — the INITIALIZATION scaffold exemption, unchanged and still fail-closed.
init_repo() { # → repo with an initialization mission + waves.json ordering
  local repo; repo="$(new_js_repo initialization)"
  local m="$repo/.git/lcars/missions/m-001"
  cat > "$m/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": null
      }
    ]
  }
]
JSON
  echo "$repo"
}
mkdir -p "$TMPROOT/res-sc.d"
write_result "$TMPROOT/res-sc.d" '["tests/first.test.js"]' '[]' \
  not-applicable "this ticket creates the test system; its parent has no runner"
ir="$(init_repo)"
pv_result "$ir" m-001 t-001 "$TMPROOT/res-sc.d/result.json"
[ "$PVRC" = 0 ] \
  && ok "D2a. the SCAFFOLD ticket may still declare its tests AND waive" \
  || bad "D2a. the scaffold exemption broke (PVRC=$PVRC): $OUT"
pv_result "$ir" m-001 t-002 "$TMPROOT/res-sc.d/result.json"
[ "$PVRC" != 0 ] \
  && ok "D2b. a LATER ticket of the same mission still cannot claim it" \
  || bad "D2b. a later ticket got the scaffold exemption"
ir2="$(init_repo)"; rm -f "$ir2/.git/lcars/missions/m-001/waves.json"
pv_result "$ir2" m-001 t-001 "$TMPROOT/res-sc.d/result.json"
[ "$PVRC" != 0 ] \
  && ok "D2c. an unreadable mission ordering still REFUSES the waiver (fail-closed)" \
  || bad "D2c. the exemption was granted on a guess"


# ==========================================================================
# F. NO REFUSAL BOTH OFFERS AND FORBIDS DROPPING THE GOLDENS
# ==========================================================================
# MEASURED (fix round 1): the result-v2 refusal opened with "… Declare flipFlop
# 'expected', or drop the tests." and then said, one paragraph later, "Do not
# drop the guard". A worker acting on the FIRST sentence deletes the guard —
# the exact outcome this session exists to prevent. The escape in that first
# sentence now POINTS AT the paragraph instead of contradicting it.
#
# BOTH HALVES ARE ASSERTED. A refusal that stopped offering the drop by
# stopping refusing would be a far worse defect than the wording.
echo "== F. the refusals no longer OFFER to drop the goldens =="
NO_DROP='drop the tests|delete the tests|remove the tests|drop the golden|delete the golden|drop the goldens|remove the golden'

mkdir -p "$TMPROOT/res-n2.d"
write_result "$TMPROOT/res-n2.d" '["src/calc.golden.test.js"]' '[]' \
  not-applicable "they assert pre-existing behaviour"
pv_result "$norepo" m-001 t-001 "$TMPROOT/res-n2.d/result.json"
F_RESULT_OUT="$OUT"
[ "$PVRC" != 0 ] \
  && ok "F1. the result-v2 refusal STILL REFUSES (the judgement is untouched)" \
  || bad "F1. the waiver-plus-newTests rule stopped refusing (PVRC=$PVRC): $OUT"
if printf '%s' "$F_RESULT_OUT" | grep -q 'declares new tests yet claims flip-flop' \
   && printf '%s' "$F_RESULT_OUT" | grep -q 'must expect them to flip'; then
  ok "F2. and both PINNED phrases survive (init-mission B8, proof-gates I3, D1)"
else
  bad "F2. a pinned phrase of the refusal was lost: $F_RESULT_OUT"
fi
if ! printf '%s' "$F_RESULT_OUT" | grep -qiE "$NO_DROP"; then
  ok "F3. the result-v2 refusal no longer OFFERS to drop the tests"
else
  bad "F3. the refusal still offers the drop it then forbids: $F_RESULT_OUT"
fi
if printf '%s' "$F_RESULT_OUT" | grep -qi 'fold'; then
  ok "F4. and it still points at where the goldens belong instead"
else
  bad "F4. the refusal removed the offer without naming the cure: $F_RESULT_OUT"
fi

# The OTHER half of the vice — the flip-flop no-red refusal.
ff_gate "$lockrepo" "$LP"
F_FF_OUT="$OUT"
[ "$FFRC" = 1 ] \
  && ok "F5. the flip-flop no-red refusal STILL REFUSES" \
  || bad "F5. the flip-flop gate stopped refusing a green parent (FFRC=$FFRC): $OUT"
if ! printf '%s' "$F_FF_OUT" | grep -qiE "$NO_DROP"; then
  ok "F6. and it offers no drop either — the two refusals now agree"
else
  bad "F6. the flip-flop refusal offers to drop the tests: $F_FF_OUT"
fi
if printf '%s' "$F_FF_OUT" | grep -qi 'never weaken a test'; then
  ok "F7. both still forbid manufacturing a red by weakening a test"
else
  bad "F7. the prohibition went missing with the offer: $F_FF_OUT"
fi

printf '\nregression-lock: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
