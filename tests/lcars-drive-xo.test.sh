#!/usr/bin/env bash
#
# Tests for THE DRIVER'S HOOK — Number One at a park (Session 202, wave B).
#
# Skill source under test: skills/lcars-run/run.sh (`cmd_drive` + its S202
# helpers), driving the REAL skills/lcars-xo/xo.sh and the REAL
# skills/lcars-respond/respond.sh.
#
# THIS SUITE IS DELIBERATELY SCOPED. `tests/lcars-run.test.sh` exercises the
# whole pipeline and is far too slow (and too expensive) to re-run for a change
# this size; the hook is a handful of lines in three places and deserves a file
# of its own. Everything here is ONE mission, ONE gate, and the REAL driver loop
# — nine full drives, about a minute and a half on a laptop, and not one of them
# touches the network or a paid CLI.
#
# THE FOUR THINGS IT EXISTS TO PIN:
#
#  1. THE DRIVE CONTINUES, WITH EXACTLY ONE DRIVER. `respond.sh` re-execs the
#     driver by default — that is what a human's answer does. Number One is
#     called FROM the driver, so xo.sh pins `LCARS_RESPOND_RESUME=0`; if that
#     pin ever came off, one mission would have two drivers racing each other
#     through the same stages. The proof is counted, not asserted by eye: the
#     next Stage's `stage_start` appears EXACTLY ONCE in events.jsonl, and the
#     driver's own output carries neither "Resuming" (respond.sh's re-exec line)
#     nor the single-instance refusal a second driver would have printed.
#  2. AN ESCALATION LEAVES THE GATE EXACTLY WHERE IT WAS. The driver halts as it
#     did before this session existed.
#  3. THE SAME QUESTION IS NEVER ASKED TWICE. An escalated gate is still a gate:
#     the next `lcars run` sees the same pending.json, and without a memory it
#     would hire a worker every single pass. The memory is a recorded cksum.
#  4. ENGAGING IS THE DRIVER'S ACT, and it respects the captain: repo OFF, or
#     this mission opted out, and nothing engages however often he re-runs it.
#
# ZERO SPEND. Both CLIs are PATH shims that record their argv and the suite
# asserts the recorded count is ZERO; the one worker that does run is a shim
# handed over via $LCARS_WORKER_BIN, and its count is reported separately.
#
# Usage: bash tests/lcars-drive-xo.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
XO="${LCARS_XO_SCRIPT:-$REPO_ROOT/skills/lcars-xo/xo.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- THE ZERO-SPEND SHIMS --------------------------------------------------
SHIMDIR="$TMPROOT/shims"; mkdir -p "$SHIMDIR"
export XO_SHIM_LOG="$TMPROOT/shim-calls.txt"; : >"$XO_SHIM_LOG"
for e in claude copilot; do
  cat >"$SHIMDIR/$e" <<EOF
#!/usr/bin/env bash
printf '$e %s\n' "\$*" >>"\$XO_SHIM_LOG"
exit 0
EOF
  chmod +x "$SHIMDIR/$e"
done
PATH="$SHIMDIR:$PATH"; export PATH

# --- the Number One worker shim (the CLI xo.sh actually hires) -------------
export XO_WORKER_LOG="$TMPROOT/worker-calls.txt"; : >"$XO_WORKER_LOG"
WORKER_SHIM="$TMPROOT/copilot-worker"
cat >"$WORKER_SHIM" <<'SHIM'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
[ -n "${XO_VERDICT:-}" ] && [ -n "$out" ] && printf '%s\n' "$XO_VERDICT" >"$out/xo-answer.json"
exit 0
SHIM
chmod +x "$WORKER_SHIM"

# --- a recording `gh` ------------------------------------------------------
GH_SHIM="$TMPROOT/gh"
cat >"$GH_SHIM" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$GH_LOG"
exit 0
EOF
chmod +x "$GH_SHIM"

MID="lcars-20260912-001"

# A repo whose config carries the numberOne block given as $1 (raw, or empty).
new_repo() { # [numberOne-config-line]
  local repo extra="${1:-}"
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  {
    printf '{\n'
    printf '  "cloneId": "aaaaaaaa",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "testCommand": "true",\n'
    [ -n "$extra" ] && printf '  %s,\n' "$extra"
    printf '  "created": "2026-09-12T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$repo/.git/lcars/config.json" || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$repo"
}

# A mission parked awaiting-human at SCHEDULE. The stage is chosen on purpose:
# once the gate clears, the driver's very next act is to run the Schedule Stage,
# and Schedule refuses in one line without an approved plan — so the loop
# demonstrably CONTINUES (a stage_start is logged) without hiring a single
# worker for the stage itself. $2 is the numberOne state block, verbatim.
plant_park() { # <repo> <numberOne-state-block>
  local repo="$1" xo="$2" m
  m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m/research"
  {
    printf '{\n'
    [ -n "$xo" ] && printf '  "numberOne": %s,\n' "$xo"
    printf '  "id": "%s",\n' "$MID"
    printf '  "type": "feature",\n'
    printf '  "title": "The review queue",\n'
    printf '  "stage": "schedule",\n'
    printf '  "awaitingHuman": true,\n'
    printf '  "pendingQuestion": "Should unassigned reviewers appear in the queue?",\n'
    printf '  "created": "2026-09-12T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  {
    printf '{\n'
    printf '  "stage": "schedule",\n'
    printf '  "humanSummary": "A ticket hit its session cap.",\n'
    printf '  "escalationType": "cap",\n'
    printf '  "technicalDetail": "t-003 failed three sessions.",\n'
    printf '  "questions": ["Should unassigned reviewers appear in the queue?"]\n'
    printf '}\n'
  } >"$m/pending.json"
  cat >"$m/prd.md" <<'PRD'
# The review queue

## 2. Scope
The queue shows assigned work only. Unassigned reviewers never appear in it.
PRD
  printf '{"answers": []}\n' >"$m/answers.json"
  : >"$m/events.jsonl"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

# Drive the mission for real. EVERY external dependency is a stub, and the
# version check is pinned to /usr/bin/true so nothing in here can reach the
# network (a `git fetch` under a redirected $HOME is a known way to hang a
# suite); the askpass pins are belt and braces for the same reason.
DRIVE_FLAGS=""      # extra argv for `run.sh drive` (only ever `--step`)
DRIVE_PATH=""       # a dir prepended to PATH for one call (the Stage stub)
drive() { # <repo> <verdict-json> [extra env...]
  local repo="$1" verdict="$2"; shift 2
  ( cd "$repo" \
    && PATH="${DRIVE_PATH:+$DRIVE_PATH:}$PATH" \
       GH_LOG="$repo/gh.log" XO_VERDICT="$verdict" \
       XO_WORKER_LOG="$XO_WORKER_LOG" \
       LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
       LCARS_GH_BIN="$GH_SHIM" LCARS_NOTIFY=/usr/bin/true \
       LCARS_VERSION_CHECK_BIN=/usr/bin/true \
       LCARS_OWNER_ENFORCE=0 \
       GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
       env "$@" \
       bash "$RUN" drive --mission "$MID" $DRIVE_FLAGS 2>&1 )
}

xo_state() { # <mission-dir> <key>
  sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$1/state.json" \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

worker_calls() { grep -c '^worker ' "$XO_WORKER_LOG" 2>/dev/null || true; }

V_OK='{"decision":"answer","answer":"No — the queue shows assigned work only.","rationale":"PRD section 2 settles it.","citations":[{"file":"prd.md","quote":"The queue shows assigned work only."}],"confidence":"high"}'
V_ESC='{"decision":"escalate","answer":"","rationale":"The PRD is silent on email.","citations":[],"recommendation":"Leave email out and file it as a follow-up.","confidence":"low"}'

echo "lcars run — Number One at a gate (S202 driver hook)"
[ -f "$RUN" ] || { echo "run.sh not found at $RUN"; exit 1; }

# ==========================================================================
# D1. THE ANSWER PATH — the gate clears and the SAME driver carries on.
# ==========================================================================
echo
echo "D1. the drive continues after Number One answers"
r1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m1="$(plant_park "$r1" '')"
: >"$XO_WORKER_LOG"
out1="$(drive "$r1" "$V_OK")"; rc1=$?

check "D1. the gate was CLEARED — awaitingHuman is gone from state" \
  "! grep -q '\"awaitingHuman\"' '$m1/state.json'"
check "D1. the answer reached answers.json through respond.sh" \
  "grep -q 'assigned work only' '$m1/answers.json'"
check "D1. …attributed: answeredBy = number-one" \
  "grep -q '\"answeredBy\": \"number-one\"' '$m1/answers.json'"
check "D1. the awaiting-human LABEL was REMOVED (not merely mentioned)" \
  "grep -q -- '--remove-label lcars:awaiting-human' '$r1/gh.log'"
printf '    gh: %s\n' "$(grep -o -- '--remove-label [^ ]*' "$r1/gh.log" | head -1)"
check "D1. the driver CONTINUED — it spawned the next Stage action" \
  "grep -q '\"stage\":\"schedule\",\"type\":\"stage_start\"' '$m1/events.jsonl'"
check "D1. …EXACTLY ONE driver ran it: one stage_start, not two" \
  "[ \"\$(grep -c '\"type\":\"stage_start\"' '$m1/events.jsonl')\" = '1' ]"
check "D1. …respond.sh did NOT re-exec the driver (no 'Resuming' line)" \
  "! printf '%s' \"\$out1\" | grep -q 'Resuming'"
check "D1. …and no second driver ever hit the single-instance guard" \
  "! printf '%s' \"\$out1\" | grep -q 'already advancing this Mission'"
check "D1. no halt banner was printed — the drive did not stop at the gate" \
  "! printf '%s' \"\$out1\" | grep -q 'stopped at: schedule  (awaiting your answer)'"
check "D1. the mission is STILL engaged (Number One keeps the conn)" \
  "[ \"\$(xo_state '$m1' status)\" = 'engaged' ]"
check "D1. …the driver ENGAGED it at drive start (state had no numberOne block)" \
  "printf '%s' \"\$out1\" | grep -q 'NUMBER ONE: engaged'"
check "D1. …recording the repo's chosen engine" \
  "[ \"\$(xo_state '$m1' engine)\" = 'copilot' ]"
check "D1. the pending it acted on was RECORDED, not inferred later" \
  "[ -n \"\$(xo_state '$m1' lastPending)\" ]"
check "D1. exactly ONE Number One worker was hired" "[ \"\$(worker_calls)\" = '1' ]"
check "D1. no pricing words anywhere in the drive's output" \
  "! printf '%s' \"\$out1\" | grep -Eqi 'free|billed|billing|pricing'"

# ==========================================================================
# D2. THE ESCALATE PATH — the gate stays, the driver halts as it always did.
# ==========================================================================
echo
echo "D2. an escalation leaves the gate for the captain"
r2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m2="$(plant_park "$r2" '')"
: >"$XO_WORKER_LOG"
out2="$(drive "$r2" "$V_ESC")"; rc2=$?

check "D2. the gate is INTACT — awaitingHuman still true" \
  "grep -q '\"awaitingHuman\": true' '$m2/state.json'"
check "D2. nothing was recorded in answers.json" \
  "! grep -q '\"answeredBy\"' '$m2/answers.json'"
check "D2. the driver halted at the gate, exactly as before S202" \
  "printf '%s' \"\$out2\" | grep -q 'awaiting your answer'"
check "D2. …and never spawned the next Stage" \
  "! grep -q '\"type\":\"stage_start\"' '$m2/events.jsonl'"
check "D2. the state says escalated" "[ \"\$(xo_state '$m2' status)\" = 'escalated' ]"
check "D2. …with the note the captain reads off the card" \
  "printf '%s' \"\$(xo_state '$m2' note)\" | grep -q 'follow-up'"
check "D2. the gate event was still emitted for the board" \
  "grep -q '\"type\":\"gate\"' '$m2/events.jsonl'"
check "D2. one worker was hired for it" "[ \"\$(worker_calls)\" = '1' ]"

# ==========================================================================
# D3. THE SAME QUESTION IS NEVER ASKED TWICE.
#     The gate D2 left up is still up. Re-drive it: the driver must recognise
#     the pending.json it already acted on and hire NOBODY.
# ==========================================================================
echo
echo "D3. the same pending.json never buys a second worker"
before3="$(xo_state "$m2" lastPending)"
: >"$XO_WORKER_LOG"
out3="$(drive "$r2" "$V_OK")"; rc3=$?
check "D3. NO worker was spawned on the second pass" "[ \"\$(worker_calls)\" = '0' ]"
check "D3. the recorded cksum is unchanged" \
  "[ \"\$(xo_state '$m2' lastPending)\" = '$before3' ]"
check "D3. the gate is still the captain's" \
  "grep -q '\"awaitingHuman\": true' '$m2/state.json'"
check "D3. …and the driver halted on it again" \
  "printf '%s' \"\$out3\" | grep -q 'awaiting your answer'"
check "D3. nothing was answered behind his back" \
  "! grep -q '\"answeredBy\"' '$m2/answers.json'"

# A DIFFERENT question, though, IS Number One's to take: change pending.json and
# the cksum no longer matches, so the next pass hires a worker again.
printf '{\n  "stage": "schedule",\n  "escalationType": "cap",\n  "questions": ["Do unassigned reviewers appear?"]\n}\n' \
  >"$m2/pending.json"
: >"$XO_WORKER_LOG"
out3b="$(drive "$r2" "$V_OK")"; rc3b=$?
check "D3b. a NEW pending question DOES get a worker" "[ \"\$(worker_calls)\" = '1' ]"
check "D3b. …and it cleared the gate" \
  "! grep -q '\"awaitingHuman\"' '$m2/state.json'"

# ==========================================================================
# D4. THE CAPTAIN'S SWITCHES WIN.
# ==========================================================================
echo
echo "D4. repo OFF and per-mission opt-out are obeyed"
r4="$(new_repo '"numberOne": {"enabled": false, "engine": "copilot"}')"
m4="$(plant_park "$r4" '')"
: >"$XO_WORKER_LOG"
out4="$(drive "$r4" "$V_OK")"; rc4=$?
check "D4. repo OFF ⇒ nothing engaged" "[ -z \"\$(xo_state '$m4' status)\" ]"
check "D4. …no worker hired" "[ \"\$(worker_calls)\" = '0' ]"
check "D4. …the gate is the captain's, as it always was" \
  "grep -q '\"awaitingHuman\": true' '$m4/state.json'"

r5="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5="$(plant_park "$r5" '{"optOut": true}')"
: >"$XO_WORKER_LOG"
out5="$(drive "$r5" "$V_OK")"; rc5=$?
check "D4. an OPTED-OUT mission is not engaged even with the repo ON" \
  "[ -z \"\$(xo_state '$m5' status)\" ]"
check "D4. …and no worker was hired for it" "[ \"\$(worker_calls)\" = '0' ]"

r6="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m6="$(plant_park "$r6" '{"status": "stood-down"}')"
: >"$XO_WORKER_LOG"
out6="$(drive "$r6" "$V_OK")"; rc6=$?
check "D4. a STOOD-DOWN mission is not silently re-engaged by a re-run" \
  "[ \"\$(xo_state '$m6' status)\" = 'stood-down' ]"
check "D4. …and no worker was hired for it" "[ \"\$(worker_calls)\" = '0' ]"

# ==========================================================================
# D5. `--step` HAS ITS OWN ARM. A Stage that finishes by ASKING has finished:
#     the captain asked for one Stage and got one. So Number One answers the
#     gate that Stage raised and the step ENDS, cleared — rather than the
#     `continue` carrying it to the top of the loop, where the auto-mode hook
#     would clear it and then run a SECOND Stage nobody asked for.
#
#     The Stage itself is stubbed here, deliberately: what is under test is the
#     driver's arm, not Schedule. The stub intercepts the ONE
#     `env … bash run.sh <action>` the driver uses to spawn a Stage and parks
#     the mission exactly as `write_pending` would.
# ==========================================================================
echo
echo "D5. --step: the gate the stepped Stage raised is answered, and the step ends"
r7="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m7="$(plant_park "$r7" '')"
# No gate at ENTRY — the Stage is going to raise it.
grep -v '"awaitingHuman"\|"pendingQuestion"' "$m7/state.json" >"$m7/state.tmp" \
  && mv "$m7/state.tmp" "$m7/state.json"
rm -f "$m7/pending.json"

STAGESTUB="$TMPROOT/stagestub"; mkdir -p "$STAGESTUB"
STAGELOG="$TMPROOT/stage-stub.log"; : >"$STAGELOG"
cat >"$STAGESTUB/env" <<STUB
#!/usr/bin/env bash
# Only the driver's Stage spawn is intercepted; everything else is the real env.
case " \$* " in
  *" schedule "*)
    printf 'stage-stub %s\n' "\$*" >>"$STAGELOG"
    m="$m7"
    printf '{\n  "stage": "schedule",\n  "escalationType": "cap",\n  "questions": ["Should unassigned reviewers appear in the queue?"]\n}\n' >"\$m/pending.json"
    awk 'NR==1{print; print "  \"awaitingHuman\": true,"; next} {print}' \
      "\$m/state.json" >"\$m/state.tmp" && mv "\$m/state.tmp" "\$m/state.json"
    printf 'schedule parked awaiting your answer\n'
    exit 0 ;;
esac
exec /usr/bin/env "\$@"
STUB
chmod +x "$STAGESTUB/env"
: >"$XO_WORKER_LOG"
DRIVE_FLAGS="--step"; DRIVE_PATH="$STAGESTUB"
out7="$(drive "$r7" "$V_OK")"; rc7=$?
DRIVE_FLAGS=""; DRIVE_PATH=""

check "D5. the stubbed Stage ran and parked the mission" \
  "[ \"\$(grep -c 'stage-stub' '$STAGELOG')\" = '1' ]"
check "D5. --step routed that gate through Number One (exactly one worker)" \
  "[ \"\$(worker_calls)\" = '1' ]"
check "D5. …the gate is CLEARED" \
  "! grep -q '\"awaitingHuman\"' '$m7/state.json'"
check "D5. …the answer is recorded, attributed" \
  "grep -q '\"answeredBy\": \"number-one\"' '$m7/answers.json'"
check "D5. …and the STEP ENDED — no second Stage was run" \
  "[ \"\$(grep -c 'stage-stub' '$STAGELOG')\" = '1' ]"
check "D5. …saying so in the captain's own words" \
  "printf '%s' \"\$out7\" | grep -q 'Number One answered the gate it raised'"
check "D5. …exactly one stage_start was logged" \
  "[ \"\$(grep -c '\"type\":\"stage_start\"' '$m7/events.jsonl')\" = '1' ]"

# ==========================================================================
# D6. THE KILL SWITCH. Every S202 seam has one; this is the driver's.
# ==========================================================================
echo
echo "D6. LCARS_XO_DRIVE=0 takes the hook out of the loop"
r8="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8="$(plant_park "$r8" '')"
: >"$XO_WORKER_LOG"
out8="$(drive "$r8" "$V_OK" LCARS_XO_DRIVE=0)"; rc8=$?
check "D6. no worker was hired" "[ \"\$(worker_calls)\" = '0' ]"
check "D6. the driver halted at the gate as it did before S202" \
  "grep -q '\"awaitingHuman\": true' '$m8/state.json'"

# ==========================================================================
# D8 (fix round 1, D1). THE ENGINE PIN IS REAL CONFIG, NOT PROVENANCE.
#
# WHAT WENT WRONG LIVE. `lcars xo on --engine claude` on a repo whose mission
# carried `workerBin: <copilot>`: the banner said `engaged · claude`, state.json
# said `"engine":"claude"`, the living comment said `Engine: claude` — and the
# argv handed to the CLI was the COPILOT shape, exec'ing the copilot binary.
# `numberOne.engine` was RECORDED and DISPLAYED and never CONSULTED: engine
# selection fell straight through to resolve_worker_bin, where the MISSION's
# own `workerBin` wins. The report named an engine that did not run.
#
# WHY BOTH DIRECTIONS. A test that only pins claude-on-a-copilot-mission passes
# just as happily when the pin is ignored and the AMBIENT answer happens to be
# claude. Only the pair — claude pinned onto a copilot mission AND copilot
# pinned onto a claude mission — can tell a pin that works from a coincidence.
#
# WHY THE PROVENANCE IS ASSERTED BYTE-FOR-BYTE. Number One's engine is Number
# One's, not the mission's. The naive cure (export $LCARS_WORKER_BIN and let it
# record as `env`) would rewrite engineSource/engineResolved on the MISSION —
# the captain's "why does this mission run on this engine" answer replaced by a
# fact about his first officer. So the three keys are captured before the drive
# and compared after it.
#
# ZERO SPEND: `claude` and `copilot` here are recording shims in their own dir,
# prepended to PATH for these drives only, and their argv is what is asserted.
# ==========================================================================
echo
echo "D8. the engine Number One is pinned to is the engine that runs"

ENGDIR="$TMPROOT/engines"; mkdir -p "$ENGDIR"
export XO_ENGINE_LOG="$TMPROOT/engine-calls.txt"; : >"$XO_ENGINE_LOG"
# $XO_ENGINE_LOG is zeroed per arm (each arm asserts on its OWN argv); this one
# is never zeroed, so the zero-spend block at the end can report the total.
export XO_ENGINE_ALL="$TMPROOT/engine-calls-all.txt"; : >"$XO_ENGINE_ALL"
for e in claude copilot; do
  cat >"$ENGDIR/$e" <<EOF
#!/usr/bin/env bash
# The recorded argv, MINUS the prompt (one long positional, not a flag) so the
# line a failure prints is the argv SHAPE and not five pages of instructions.
{ printf '=== $e'
  for a in "\$@"; do
    case "\$a" in -*) printf ' %s' "\$a" ;;
      *) [ "\${#a}" -le 60 ] && printf ' %s' "\$a" || printf ' <prompt:%s bytes>' "\${#a}" ;;
    esac
  done
  printf '\n'; } | tee -a "\$XO_ENGINE_ALL" >>"\$XO_ENGINE_LOG"
out="\${LCARS_WORK_OUT:-}"
[ -n "\${XO_VERDICT:-}" ] && [ -n "\$out" ] && printf '%s\n' "\$XO_VERDICT" >"\$out/xo-answer.json"
exit 0
EOF
  chmod +x "$ENGDIR/$e"
done

# A drive with NO $LCARS_WORKER_BIN and NO $LCARS_WORKER_CLI — the resolver is
# left to answer for itself, which is the whole point of this block.
drive_unpinned() { # <repo> <verdict-json>
  local repo="$1" verdict="$2"; shift 2
  ( cd "$repo" \
    && PATH="$ENGDIR:$PATH" \
       GH_LOG="$repo/gh.log" XO_VERDICT="$verdict" \
       XO_ENGINE_LOG="$XO_ENGINE_LOG" \
       LCARS_GH_BIN="$GH_SHIM" LCARS_NOTIFY=/usr/bin/true \
       LCARS_VERSION_CHECK_BIN=/usr/bin/true \
       LCARS_OWNER_ENFORCE=0 \
       GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
       env "$@" \
       bash "$RUN" drive --mission "$MID" 2>&1 )
}

# The mission's OWN engine record, exactly as `lcars adopt` leaves it.
pin_mission_engine() { # <mission-dir> <engine>
  local m="$1" e="$2"
  awk -v e="$e" 'NR==1{
        print
        printf "  \"workerBin\": \"%s\",\n", e
        printf "  \"engineSource\": \"adopt-chosen\",\n"
        printf "  \"engineResolved\": \"%s\",\n", e
        next } {print}' "$m/state.json" >"$m/state.tmp" && mv "$m/state.tmp" "$m/state.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
}
prov() { grep -E '"(workerBin|engineSource|engineResolved)"' "$1/state.json"; }

# --- D8a. claude PINNED onto a COPILOT mission ------------------------------
r9="$(new_repo '"numberOne": {"enabled": true, "engine": "claude"}')"
m9="$(plant_park "$r9" '')"
pin_mission_engine "$m9" copilot
PROV9_BEFORE="$(prov "$m9")"
: >"$XO_ENGINE_LOG"
out9="$(drive_unpinned "$r9" "$V_ESC")"
ARGV9="$(cat "$XO_ENGINE_LOG")"
printf '    argv (numberOne.engine=claude on a copilot mission):\n'
printf '%s\n' "$ARGV9" | sed 's/^/      /'
check "D8a. the CLAUDE binary was the one that ran" \
  "printf '%s' \"\$ARGV9\" | grep -q '^=== claude '"
check "D8a. …and the COPILOT binary was never invoked" \
  "! printf '%s' \"\$ARGV9\" | grep -q '^=== copilot '"
check "D8a. the argv is the CLAUDE shape (--allowedTools / --disallowedTools)" \
  "printf '%s' \"\$ARGV9\" | grep -q -- '--allowedTools Read,Grep,Glob,Write' && printf '%s' \"\$ARGV9\" | grep -q -- '--disallowedTools'"
check "D8a. …and carries NONE of the copilot shape (--available-tools/--add-dir)" \
  "! printf '%s' \"\$ARGV9\" | grep -q -- '--available-tools'"
check "D8a. the MISSION's provenance is byte-identical after the spin" \
  "[ \"\$(prov '$m9')\" = \"\$PROV9_BEFORE\" ]"
check "D8a. …its workerBin still says copilot (Number One's engine is not the mission's)" \
  "grep -q '\"workerBin\": \"copilot\"' '$m9/state.json'"
check "D8a. …and engineSource is still the captain's adopt answer" \
  "grep -q '\"engineSource\": \"adopt-chosen\"' '$m9/state.json'"

# --- D8b. copilot PINNED onto a CLAUDE mission (the other direction) --------
r10="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m10="$(plant_park "$r10" '')"
pin_mission_engine "$m10" claude
PROV10_BEFORE="$(prov "$m10")"
: >"$XO_ENGINE_LOG"
out10="$(drive_unpinned "$r10" "$V_ESC")"
ARGV10="$(cat "$XO_ENGINE_LOG")"
printf '    argv (numberOne.engine=copilot on a claude mission):\n'
printf '%s\n' "$ARGV10" | sed 's/^/      /'
check "D8b. the COPILOT binary was the one that ran" \
  "printf '%s' \"\$ARGV10\" | grep -q '^=== copilot '"
check "D8b. …and the CLAUDE binary was never invoked" \
  "! printf '%s' \"\$ARGV10\" | grep -q '^=== claude '"
check "D8b. the argv is the COPILOT shape (--available-tools view,rg,glob)" \
  "printf '%s' \"\$ARGV10\" | grep -q -- '--available-tools view,rg,glob'"
check "D8b. …and carries NONE of the claude shape (--disallowedTools)" \
  "! printf '%s' \"\$ARGV10\" | grep -q -- '--disallowedTools'"
check "D8b. the MISSION's provenance is byte-identical after the spin" \
  "[ \"\$(prov '$m10')\" = \"\$PROV10_BEFORE\" ]"
check "D8b. …its workerBin still says claude" \
  "grep -q '\"workerBin\": \"claude\"' '$m10/state.json'"

# --- D8c. THE CAPTAIN'S OWN $LCARS_WORKER_BIN STILL OUTRANKS EVERYTHING -----
# Per-invocation and unmistakably deliberate; that is how he moves a spin by
# hand. Number One's engine is repo config and must not overrule it.
r11="$(new_repo '"numberOne": {"enabled": true, "engine": "claude"}')"
m11="$(plant_park "$r11" '')"
pin_mission_engine "$m11" copilot
: >"$XO_ENGINE_LOG"; : >"$XO_WORKER_LOG"
out11="$(drive_unpinned "$r11" "$V_ESC" LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot)"
check "D8c. an explicit \$LCARS_WORKER_BIN wins — that shim ran" \
  "[ \"\$(worker_calls)\" = '1' ]"
check "D8c. …and neither engine shim was touched" \
  "[ ! -s \"\$XO_ENGINE_LOG\" ]"

# ==========================================================================
# D9 (fix round 1, D3). A RE-DRIVE MUST NOT DOWNGRADE `escalated` TO `engaged`.
#
# WHAT WENT WRONG LIVE. After a scope escalation, a second `lcars run drive`
# (an auto-advance, or the daemon, or the captain re-running it) came back with
# `"status": "engaged"` — the escalation note and `lastAction: "escalated …"`
# still attached to it. Nothing was lost mechanically, the gate survived; what
# disappeared was the ONE signal that says THIS ONE IS YOURS. The red card stops
# being red and `lcars xo` lists it as engaged-with-an-escalation-note.
#
# THE CAUSE: engage-at-drive-start already skipped `engaged` and `stood-down`
# and simply did not know about `escalated`.
#
# THE OTHER HALF OF THE CURE, and why it is in the same block. "Stays escalated"
# on its own would be a WORSE defect than the one it cures: the conn would never
# come back and the first officer would sit out every remaining gate on the
# mission. It stays escalated WHILE THE GATE IT HANDED BACK IS STILL UP. The
# moment the captain answers it, the drive that follows re-engages — which is
# exactly what "until the captain acts on it" means.
# ==========================================================================
echo
echo "D9. an escalated mission stays escalated until the captain acts"

r12="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m12="$(plant_park "$r12" '{"status": "escalated", "engine": "copilot", "note": "this gate is a scope decision, and scope is yours — leave email out", "lastAction": "escalated implement 00:54", "lastPending": "PENDSUM"}')"
# lastPending is the cksum of the pending.json it acted on — the record of WHICH
# gate it handed back. The fixture carries the REAL one, computed exactly as the
# driver computes it, so "the same gate" means the same gate.
PENDSUM12="$(cksum <"$m12/pending.json" | tr -s ' ' ' ' | cut -d' ' -f1,2 | tr ' ' '-')"
sed "s/PENDSUM/$PENDSUM12/" "$m12/state.json" >"$m12/state.tmp" && mv "$m12/state.tmp" "$m12/state.json"
: >"$XO_WORKER_LOG"
out12="$(drive "$r12" "$V_OK")"
check "D9. the re-drive left the status ESCALATED" \
  "[ \"\$(xo_state '$m12' status)\" = 'escalated' ]"
check "D9. …the note the captain reads off the red card survived" \
  "printf '%s' \"\$(xo_state '$m12' note)\" | grep -q 'scope is yours'"
check "D9. …and lastAction still says what it did" \
  "printf '%s' \"\$(xo_state '$m12' lastAction)\" | grep -q 'escalated implement'"
check "D9. …no banner claimed to engage anything" \
  "! printf '%s' \"\$out12\" | grep -q 'NUMBER ONE: engaged'"
check "D9. …the gate is still the captain's" \
  "grep -q '\"awaitingHuman\": true' '$m12/state.json'"
check "D9. …and no worker was hired to re-answer it" "[ \"\$(worker_calls)\" = '0' ]"
check "D9. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m12/state.json'"

# THE CAPTAIN ACTS. He answers the gate (awaitingHuman gone, pending.json gone)
# — and the next drive hands the conn back to his first officer.
grep -v '"awaitingHuman"\|"pendingQuestion"' "$m12/state.json" >"$m12/state.tmp" \
  && mv "$m12/state.tmp" "$m12/state.json"
rm -f "$m12/pending.json"
: >"$XO_WORKER_LOG"
out12b="$(drive "$r12" "$V_OK")"
check "D9b. once he has answered, the next drive RE-ENGAGES Number One" \
  "[ \"\$(xo_state '$m12' status)\" = 'engaged' ]"
check "D9b. …and the stale 'this one is yours' note is gone with it" \
  "[ -z \"\$(xo_state '$m12' note)\" ]"
check "D9b. …the record of what it did is NOT erased" \
  "printf '%s' \"\$(xo_state '$m12' lastAction)\" | grep -q 'escalated implement'"
check "D9b. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m12/state.json'"

# D9c. AN ESCALATION WITH NO RECORDED CKSUM. `lcars xo answer --mission <id>`
# run by hand never goes through the driver, so nothing stamped `lastPending`.
# "No memory" must not read as "a different gate" — that would put the downgrade
# straight back for every escalation the captain raised outside a drive.
r13="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m13="$(plant_park "$r13" '{"status": "escalated", "engine": "copilot", "note": "the PRD is silent on email"}')"
: >"$XO_WORKER_LOG"
out13="$(drive "$r13" "$V_OK")"
check "D9c. escalated with NO lastPending still stays escalated" \
  "[ \"\$(xo_state '$m13' status)\" = 'escalated' ]"
check "D9c. …and no worker was hired" "[ \"\$(worker_calls)\" = '0' ]"
check "D9c. …the gate is still the captain's" \
  "grep -q '\"awaitingHuman\": true' '$m13/state.json'"

# ==========================================================================
# D10 (fix round 2). `lcars xo on <mission>` PUTS THE MISSION BACK IN SCOPE.
#
# WHAT WENT WRONG LIVE. `lcars xo off m-scope` mid-spin, then `lcars xo on
# m-scope` — which printed "back in scope — the opt-out is cleared" and DID
# clear `optOut` — and then a re-drive. No banner, no spin, no journal line:
# the gate parked as though Number One were switched off entirely. Fix round 1
# cured a lock-out by clearing `lastPending` on stand-down; the lock-out had not
# gone, it had MOVED to `status`, which `xo on <mission>` never touched and
# which engage-at-drive-start returns on. The verb reported success while
# leaving the thing it names undone — the same class as the adopt defect.
#
# WHY THE PROOF IS A RE-DRIVE AND NOT A FIELD. Asserting the state field would
# pass on any cure that merely writes a different string; only driving the
# tester's exact sequence proves the first officer actually takes the gate
# again. So: engaged mid-spin → `xo off <id>` → `xo on <id>` → `lcars run
# drive`, and Number One must engage, hire exactly one worker, and clear it.
# ==========================================================================
echo
echo "D10. \`lcars xo on <mission>\` really does put the mission back in scope"

r14="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m14="$(plant_park "$r14" '{"status": "engaged", "engine": "copilot", "since": "2026-09-12T10:05:00Z", "lastPending": "PENDSUM"}')"
# The mission is MID-SPIN: it holds the conn on the very gate that is up, and
# the recorded cksum is the real one, so the stand-down is the live case.
PENDSUM14="$(cksum <"$m14/pending.json" | tr -s ' ' ' ' | cut -d' ' -f1,2 | tr ' ' '-')"
sed "s/PENDSUM/$PENDSUM14/" "$m14/state.json" >"$m14/state.tmp" && mv "$m14/state.tmp" "$m14/state.json"

xo14() { ( cd "$r14" && bash "$XO" "$@" 2>&1 ); }

off14="$(xo14 off "$MID")"
check "D10. \`lcars xo off <mission>\` stood it down" \
  "[ \"\$(xo_state '$m14' status)\" = 'stood-down' ]"
check "D10. …recorded the opt-out" "grep -q '\"optOut\": true' '$m14/state.json'"
check "D10. …cleared the gate stamp (fix round 1's cure, still in place)" \
  "[ -z \"\$(xo_state '$m14' lastPending)\" ]"
check "D10. …and journalled the stand-down" \
  "grep -q '\"action\": \"stood-down\"' '$m14/number-one.jsonl'"

on14="$(xo14 on "$MID")"
check "D10. \`lcars xo on <mission>\` says it is back in scope" \
  "printf '%s' \"\$on14\" | grep -q 'back in scope'"
check "D10. …the opt-out is gone" "! grep -q '\"optOut\"' '$m14/state.json'"
check "D10. …and so is the stand-down — the mission LOOKS never-stood-down" \
  "[ -z \"\$(xo_state '$m14' status)\" ]"
check "D10. …with no stale 'you have the conn' note left on the card" \
  "[ -z \"\$(xo_state '$m14' note)\" ]"
check "D10. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m14/state.json'"

# THE PROOF: the very next drive engages and takes that same gate up again.
: >"$XO_WORKER_LOG"
out14="$(drive "$r14" "$V_OK")"
check "D10. the re-drive ENGAGED Number One — the banner says so" \
  "printf '%s' \"\$out14\" | grep -q 'NUMBER ONE: engaged'"
check "D10. …the state says engaged" "[ \"\$(xo_state '$m14' status)\" = 'engaged' ]"
check "D10. …EXACTLY ONE worker was hired for the gate" \
  "[ \"\$(worker_calls)\" = '1' ]"
check "D10. …the gate was CLEARED" \
  "! grep -q '\"awaitingHuman\"' '$m14/state.json'"
check "D10. …the answer is recorded, attributed" \
  "grep -q '\"answeredBy\": \"number-one\"' '$m14/answers.json'"
check "D10. …and the journal carries the spin" \
  "grep -q '\"action\": \"answered\"' '$m14/number-one.jsonl'"
check "D10. state.json is still valid JSON after the re-drive" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m14/state.json'"

# D10b. `xo on <mission>` IS NOT A BACK DOOR ROUND THE OTHER TWO RULES. An
# ESCALATED mission is not a stood-down one: the captain still has that gate,
# and this verb must leave it exactly where D9 pins it.
r15="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m15="$(plant_park "$r15" '{"status": "escalated", "engine": "copilot", "note": "scope is yours", "optOut": true}')"
( cd "$r15" && bash "$XO" on "$MID" >/dev/null 2>&1 )
check "D10b. the opt-out is cleared on an escalated mission too" \
  "! grep -q '\"optOut\"' '$m15/state.json'"
check "D10b. …but ESCALATED is untouched — that gate is still the captain's" \
  "[ \"\$(xo_state '$m15' status)\" = 'escalated' ]"
check "D10b. …and its note survives" \
  "printf '%s' \"\$(xo_state '$m15' note)\" | grep -q 'scope is yours'"

# ==========================================================================
echo
echo "D7. zero spend"
shim_calls="$(grep -c . "$XO_SHIM_LOG" 2>/dev/null)" || true
shim_models="$(grep -c -- '--model' "$XO_SHIM_LOG" 2>/dev/null)" || true
printf '  real-CLI shim invocations: %s (with --model: %s)\n' \
  "${shim_calls:-0}" "${shim_models:-0}"
check "D7. no real CLI was invoked at all" "[ '${shim_calls:-0}' -eq 0 ]"
# D8 hires workers ON PURPOSE, through recording shims of its own named `claude`
# and `copilot` in a dir it prepends to PATH for those drives only. Reported
# separately so the two are never confused: the line above is "no real CLI ran",
# the line below is "the fake engines ran N times, which is the measurement".
eng_calls="$(grep -c '^=== ' "$XO_ENGINE_ALL" 2>/dev/null)" || true
eng_claude="$(grep -c '^=== claude ' "$XO_ENGINE_ALL" 2>/dev/null)" || true
eng_cop="$(grep -c '^=== copilot ' "$XO_ENGINE_ALL" 2>/dev/null)" || true
printf '  engine-shim invocations (D8, deliberate): %s  [claude %s / copilot %s]\n' \
  "${eng_calls:-0}" "${eng_claude:-0}" "${eng_cop:-0}"

echo
printf 'lcars run xo-hook: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
