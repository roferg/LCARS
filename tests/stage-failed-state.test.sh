#!/usr/bin/env bash
#
# tests/stage-failed-state.test.sh — "FAILED AND IDLE" IS A STATE YOU CAN SEE (S312).
#
# Skill source:
#   skills/lcars-run/run.sh   drive_mark_stage_failed / drive_clear_stage_failed
#                             — the `failed` fact written INTO mission state.json
#                             when a stage attempt fails, and cleared when the
#                             next attempt starts.
#   skills/lcars-run/run.sh   drive_early_drift_check — cmd_drive's post-lock,
#                             pre-stage-loop slot, beside drive_base_recheck.
#
# WHY THIS EXISTS — MEASURED, NOT IMAGINED. On a real mission the retry failed at
# 01:36 and the mission SAT UNTOUCHED FOR 4 HOURS 49 MINUTES. Nothing surfaced
# it, because nothing in mission state said it had failed. Driven on this
# fixture before the fix, `lcars run drive` with a worker that produces nothing
# ends like this:
#
#     ⏹ stopped: research failed
#     state.json: { … "stage": "align" … }        ← and NOTHING else
#
# `stage: "align"` is the RESUME POINTER, and it is byte-identical to a
# freshly-filed healthy mission. The failure was recorded in events.jsonl (S218)
# and rendered by the board and `lcars status` — but the ECH, the heartbeat and
# every reader that asks mission state "how is this mission?" got the same
# answer for a dead mission as for a new one.
#
# SO THE FACT GOES WHERE THE READERS LOOK: state.json, beside `awaitingHuman`
# (its precedent — a non-working state as a flat field on the mission). It is
# THREE fields, because "it failed" without "at what, when and why" is another
# thing nobody can act on:
#     failedStage   the stage whose ATTEMPT failed
#     failedAt      when
#     failedReason  the one line that says why
#
# AND IT IS A DISTINCT FACT FROM THE STAGE. A mission is "at implement,
# FAILED" — never "at failed". `stage` is not touched, so every existing reader,
# label and resume path behaves exactly as before. That is asserted here
# explicitly (check 3), because collapsing the two would silently break resume.
#
# THE SECOND HALF — DRIFT, EARLY. The undeclared-test-drift gate is correct and
# is NOT relaxed here (it is on this round's off-limits list). It was only ever
# consulted at the END of an Implement pass, so a branch that already carried
# undeclared drift burned a full pass (~20 minutes on the real mission) before
# being refused. This suite drives the SAME gate function from cmd_drive's
# post-lock, pre-stage-loop slot — the one where drive_base_recheck already
# lives — and MEASURES how long the refusal takes.
#
# EVERYTHING here is real git against LOCAL BARE remotes, the real run.sh, and a
# real stub worker on a PATH SHIM. ZERO model calls — asserted at the end.
#
# Usage: bash tests/stage-failed-state.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
STATUS_SCRIPT="${LCARS_STATUS_SCRIPT:-$REPO_ROOT/skills/lcars-status/status.sh}"
ECH_SCRIPT="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"
VERSION_STAMP="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"

export LCARS_VERSION_CHECK=0
export LCARS_WORKER_HANG_SECS=0
export LCARS_WORKER_CLI=claude

pass=0
fail=0
TMPROOT="$(mktemp -d)"
# Every process this suite starts is recorded here and killed BY PID on the way
# out (S208/S209: a leaky suite left daemons behind). No pattern matching: a
# `pkill -f` in a suite that drives real workers can reach the captain's own.
BG_PIDS=""
teardown() {
  local p
  for p in $BG_PIDS; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$TMPROOT"
}
trap teardown EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# jget <file> <python-expr-on-d> — read one field out of a state file without a
# regex. `d` is the parsed object; a missing key prints empty.
jget() { python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
try:
    v = eval(sys.argv[2], {"d": d})
except Exception:
    v = ""
print("" if v is None else v)
PY
}

# ---------------------------------------------------------------------------
# ZERO SPEND, PINNED BY A PATH SHIM — never an env var. S140/S159 measured the
# daemon's align path overriding LCARS_WORKER_BIN from a request body and an env
# var losing to a persisted state.json workerBin, so the pin is a `claude` AND a
# `copilot` on PATH that log and refuse. Asserted empty at the end.
# ---------------------------------------------------------------------------
SHIMDIR="$TMPROOT/shim"; mkdir -p "$SHIMDIR"
export MODEL_SHIM_LOG="$TMPROOT/model-shim.log"; : >"$MODEL_SHIM_LOG"
for cli in claude copilot; do
  cat >"$SHIMDIR/$cli" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "$cli" "\$*" >>"\$MODEL_SHIM_LOG"
exit 1
SHIM
  chmod +x "$SHIMDIR/$cli"
done
PATH="$SHIMDIR:$PATH"; export PATH
# THE POSITIVE CONTROL. An empty shim log proves zero spend only if a model CLI
# invocation WOULD have written to it. So invoke each shim once, deliberately,
# into a control log of its own — then the real log's emptiness is a
# measurement rather than an assumption about PATH resolution.
MODEL_SHIM_CONTROL="$TMPROOT/model-shim-control.log"
MODEL_SHIM_LOG="$MODEL_SHIM_CONTROL" claude -p "control probe" >/dev/null 2>&1 || true
MODEL_SHIM_LOG="$MODEL_SHIM_CONTROL" copilot -p "control probe" >/dev/null 2>&1 || true

# --- stubs -----------------------------------------------------------------
GH_STUB="$TMPROOT/gh"
cat >"$GH_STUB" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"; exit 0
fi
exit 0
EOF
chmod +x "$GH_STUB"

NOTIFY_STUB="$TMPROOT/notify"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOTIFY_STUB"; chmod +x "$NOTIFY_STUB"

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

# THE WORKER STUB. Two modes, chosen by $WORKER_MODE at spawn time:
#   empty  — produces NOTHING. The question-generator then has no questions.txt
#            after its three attempts and the Research stage STOPS. That is a
#            genuine stage failure through the real failure path, not a string a
#            test wrote.
#   good   — produces the artifacts each role needs, so Research advances.
make_worker_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; *) shift ;; esac; done
role="${LCARS_WORKER_ROLE:-}"
out="${LCARS_WORK_OUT:-}"
[ -n "${WORKER_LOG:-}" ] && printf 'role=%s mode=%s\n' "$role" "${WORKER_MODE:-}" >>"$WORKER_LOG"
# hang — hold the stage open until something kills us. The second attempt in
# the killed-mid-stage test has to be GENUINELY mid-stage; a worker that
# returns immediately would be a test of a race, not of an interrupted drive.
if [ "${WORKER_MODE:-empty}" = "hang" ]; then while :; do sleep 1; done; fi
[ "${WORKER_MODE:-empty}" = "empty" ] && exit 0
[ -n "$out" ] || exit 0
case "$role" in
  research-questions) : >"$out/questions.txt" ;;
  context-pack)       printf '# Context pack\n\nStub.\n' >"$out/context-pack.md" ;;
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
esac
exit 0
EOF
  chmod +x "$1"
}

scaffold_lcars() {
  local repo="$1"
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<EOF
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "model": "claude-sonnet", "projectName": "fixture", "contextFile": null,
  "testCommand": "true",
  "lcarsVersion": "$VERSION_STAMP", "created": "2026-05-30T00:00:00Z" }
EOF
  printf '# Context pack\n\nA fixture repo.\n' >"$repo/.git/lcars/context-pack.md"
}

# make_fixture <name> — a local BARE origin + a seed clone + the working clone
# under test. Same shape as tests/drive-base-recheck.test.sh so both suites
# judge the same kind of repo.
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
    mkdir -p tests
    printf 'echo ok\n' >tests/thing.test.sh
    git add -A && git commit -q -m init
    git remote add origin "$bare" && git push -q -u origin main
  ) >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$repo" 2>/dev/null
  ( cd "$repo" && git config user.email t@t && git config user.name t )
  scaffold_lcars "$repo"
  make_worker_stub "$repo.worker"
  printf '%s' "$repo"
}

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

file_mission() {
  local repo="$1"; shift
  (
    cd "$repo"
    LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
      bash "$FILE_SCRIPT" "$@" >"$repo.file.out" 2>&1
  ) || true
}

# drive <repo> <mission> [mode] [args…] — the real driver. stdout in <repo>.drive.out
drive() {
  local repo="$1" mid="$2" mode="${3:-empty}"; shift 3
  local rc=0
  (
    cd "$repo"
    LCARS_GH_BIN="$GH_STUB" LCARS_WORKER_BIN="$repo.worker" LCARS_NOTIFY="$NOTIFY_STUB" \
      WORKER_MODE="$mode" WORKER_LOG="$repo.workerlog" \
      bash "$RUN_SCRIPT" drive --mission "$mid" "$@" >"$repo.drive.out" 2>&1
  ) || rc=$?
  printf '%s' "$rc" >"$repo.drive.rc"
}

MID="lcars-20260530-001-c10e"

# ===========================================================================
echo "-- 1. a stage attempt that fails RECORDS a failed state --"
# ===========================================================================
r1="$(make_fixture f1)"; prd1="$TMPROOT/prd1.md"; write_prd "$prd1"
file_mission "$r1" --prd "$prd1"
S1="$r1/.git/lcars/missions/$MID/state.json"
check "the fixture filed a mission" "[ -f '$S1' ]"
check "a FRESHLY FILED mission carries NO failed fact" \
  "[ -z \"\$(jget '$S1' 'd.get(\"failedStage\")')\" ]"

drive "$r1" "$MID" empty
check "the drive stopped on a stage failure (the real failure path ran)" \
  "grep -q 'stopped: research failed' '$r1.drive.out'"

# B1 — the three fields, each a distinct fact.
check "1a. state.json records failedStage = the stage whose attempt failed" \
  "[ \"\$(jget '$S1' 'd.get(\"failedStage\")')\" = research ]"
check "1b. state.json records failedAt (WHEN it failed), non-empty" \
  "[ -n \"\$(jget '$S1' 'd.get(\"failedAt\")')\" ]"
check "1c. state.json records failedReason — ONE line that says why" \
  "[ -n \"\$(jget '$S1' 'd.get(\"failedReason\")')\" ]"
check "1d. the reason is the stage's own stated reason, not a generic word" \
  "printf '%s' \"\$(jget '$S1' 'd.get(\"failedReason\")')\" | grep -q 'questions.txt'"
check "1d2. the failure LOG this run wrote is part of the record too — a record\n        that becomes the preferred source must not LOSE what the event carried" \
  "printf '%s' \"\$(jget '$S1' 'd.get(\"failedLog\")')\" | grep -q 'research/worker-failure.log'"
check "1e. the reason is ONE line (a reader prints it whole)" \
  "[ \"\$(jget '$S1' 'd.get(\"failedReason\")' | wc -l | tr -d ' ')\" = 1 ]"

# B1 — AND IT IS A DISTINCT FACT FROM THE STAGE. This is the check that stops a
# future session collapsing the two: `stage` is the RESUME POINTER and must be
# untouched, so the mission reads "at align, failed at research".
check "1f. the mission is 'at <stage>, FAILED' — stage is NOT set to 'failed'" \
  "[ \"\$(jget '$S1' 'd[\"stage\"]')\" != failed ]"
check "1g. …and stage is still the resume pointer the filing left (align)" \
  "[ \"\$(jget '$S1' 'd[\"stage\"]')\" = align ]"

# The record must not outlive the attempt it describes — the same supersede rule
# events.jsonl already uses (a later stage_start clears the failure).
# `--step` so exactly ONE stage runs: Research, which now succeeds. Without it
# the drive runs on to Plan, which this stub worker cannot serve, and the record
# would be cleared and then honestly re-written by that LATER failure — which
# would make this check pass or fail for the wrong reason.
drive "$r1" "$MID" good --step
check "1h. a NEW attempt CLEARS the failed record (it describes the LAST attempt)" \
  "[ -z \"\$(jget '$S1' 'd.get(\"failedStage\")')\" ]"
check "1i. …and clears failedAt and failedReason with it (no half-record)" \
  "[ -z \"\$(jget '$S1' 'd.get(\"failedAt\")')\$(jget '$S1' 'd.get(\"failedReason\")')\" ]"
check "1j. …and the successful attempt really did advance the mission" \
  "[ \"\$(jget '$S1' 'd[\"stage\"]')\" != align ]"

# ===========================================================================
# 2 + 3. S312 FIX ROUND 1 — A DRIVE KILLED MID-STAGE, AND THE LIVE CONTROL
# ===========================================================================
# MEASURED BY A FRESH TESTER. S312 cleared the recorded failure when the next
# attempt STARTED. So:
#
#   DID      failed Research (correctly reported) -> started a second real drive
#            -> hard-killed the driver and its children mid-stage, by pid, twice
#   EXPECTED a mission with a stale driver.lock and a dead last attempt reported
#            by SOMETHING
#   SAW      all four surfaces blind. state.json failed* NONE (cleared when the
#            attempt started, never re-written because the driver died first);
#            `stalled` zero bytes; `lcars status` a plain row; the ECH's own
#            status gate=- driver=-; /api/board failure: null.
#
# WORSE: before the second drive the mission WAS visible. STARTING A DOOMED DRIVE
# MADE IT INVISIBLE. And this is the ordinary case, not an exotic one — the
# captain's laptop sleeps after one minute, on mains, so a drive interrupted by
# sleep is what normally happens to an unattended retry.
#
# SO THE RECORD IS CLEARED BY A STAGE THAT SUCCEEDS, NOT BY ONE THAT STARTS.
# Which buys this round a NEW RISK, and section 3 is that risk's control: while a
# retry is genuinely in flight the stale record is STILL ON DISK, and a running
# mission must not read as failed on ANY surface. A board that cries wolf is the
# defect that teaches the captain to ignore it, so the control is written first
# and every surface is checked, not only the one that was changed.
#
# EVERY liveness fact here is a REAL PROCESS: the drives are real `run.sh drive`
# runs against the real fixture, and the kills are by pid.
#
# NOTHING IS GREPPED THROUGH A PIPE. This suite runs under `set -o pipefail`, and
# `<producer> | grep -q PATTERN` returns 141 when grep matches EARLY and the
# producer dies of SIGPIPE — a check that fails precisely when it should pass.
# (It cost two runs of this suite to find.) So every surface is captured to a
# file and the file is the grep operand.

# kill_tree <pid> — the descendants are collected BEFORE the parent dies (once it
# is gone they are reparented and `pgrep -P` can no longer find them), then
# everything is killed BY PID. No pattern matching, so nothing outside this
# suite's own process tree can ever be a target.
kill_tree() {
  local root="$1" all="" frontier="$1" next p
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      all="$all $p"
      next="$next $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"
    done
    frontier="$next"
  done
  for p in $all; do kill -9 "$p" 2>/dev/null || true; done
  printf '%s' "$all"
}

# drive_bg <repo> <mission> <mode> — the real driver, backgrounded. `exec` so the
# pid this returns IS run.sh's own pid, which is the pid it writes into
# driver.lock; a wrapper subshell would hand back a pid no surface knows about.
drive_bg() {
  local repo="$1" mid="$2" mode="$3"
  (
    cd "$repo" || exit 1
    exec env LCARS_GH_BIN="$GH_STUB" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_NOTIFY="$NOTIFY_STUB" WORKER_MODE="$mode" WORKER_LOG="$repo.workerlog" \
      bash "$RUN_SCRIPT" drive --mission "$mid" >"$repo.drive.out" 2>&1
  ) </dev/null &
  printf '%s' "$!"
}

# await_mid_stage <repo> <mission> <driver-pid> — block until the drive is
# genuinely INSIDE a stage: its lock is held by that pid and a worker has run.
await_mid_stage() {
  local repo="$1" mid="$2" dpid="$3" i=0
  # NOT in the `local` above: a builtin expands every one of its words BEFORE
  # assigning any of them, so "$repo" there is unbound (set -u), not "$1".
  local lock="$repo/.git/lcars/missions/$mid/driver.lock/pid"
  while [ "$i" -lt 240 ]; do
    if [ "$(cat "$lock" 2>/dev/null)" = "$dpid" ] && [ -s "$repo.workerlog" ]; then
      return 0
    fi
    kill -0 "$dpid" 2>/dev/null || return 1
    sleep 0.25; i=$((i + 1))
  done
  return 1
}

# --- the four surfaces, each captured to a file ----------------------------
# lstatus_to <repo> <outfile> — the real `lcars status` CLI, as the captain runs it.
lstatus_to() {
  ( cd "$1" && LCARS_GH_BIN="$GH_STUB" bash "$STATUS_SCRIPT" ) >"$2" 2>&1 || true
}
# ech_to <repo> <outfile> <args…> — the real ECH verb. Only `stalled` and
# `status` are used here and neither spawns anything.
ech_to() {
  local repo="$1" out="$2"; shift 2
  LCARS_ECH_CWD="$repo" LCARS_GH_BIN="$GH_STUB" LCARS_NOTIFY="$NOTIFY_STUB" \
    bash "$ECH_SCRIPT" "$@" </dev/null >"$out" 2>&1 || true
}
# board_to <repo> <mission> <outfile> — the REAL board adapter's card for this
# mission: the `failure` object `/api/board` serialises, or `null`, or MISSING.
# The adapter is called in-process rather than over HTTP so this suite starts no
# daemon it would then have to hunt down; the HTTP layer only serialises what
# this returns, and web/tests/test_stage_failure_surface.py covers the shape.
board_to() {
  python3 - "$REPO_ROOT/web" "$1" "$2" >"$3" 2>&1 <<'PY' || true
import json, sys
sys.path.insert(0, sys.argv[1])
from lcars_serve.local_adapter import LocalAdapter
board = LocalAdapter(sys.argv[2]).board()
for col in (board.get("columns") or {}).values():
    for m in col:
        if m.get("id") == sys.argv[3]:
            print(json.dumps(m.get("failure")))
            raise SystemExit(0)
print("MISSING")
PY
}

OUT="$TMPROOT/surface"; mkdir -p "$OUT"

# --- the fixture: a mission whose Research really failed, then a second real
#     drive killed mid-stage.
r4="$(make_fixture f4)"; prd4="$TMPROOT/prd4.md"; write_prd "$prd4"
file_mission "$r4" --prd "$prd4"
S4="$r4/.git/lcars/missions/$MID/state.json"
printf 'M0 the thing\n' >"$TMPROOT/ech-spec.md"
ech_to "$r4" "$OUT/init" init --spec "$TMPROOT/ech-spec.md" --scope M0
ech_to "$r4" "$OUT/rec" record "missions.M0.id" "$MID"
ech_to "$r4" "$OUT/echstat0" status
check "2-setup. the ECH knows about this mission, so its status screen has a row" \
  "grep -q '$MID' '$OUT/echstat0'"

drive "$r4" "$MID" empty
check "2-setup. attempt 1's Research really failed (the real failure path ran)" \
  "grep -q 'stopped: research failed' '$r4.drive.out'"
lstatus_to "$r4" "$OUT/st0"
check "2-setup. …and it IS visible before the second attempt: lcars status wears the glyph" \
  "grep -q '✖' '$OUT/st0'"
FAT1="$(jget "$S4" 'd.get("failedAt")')"
check "2-setup. …with a recorded failedAt" "[ -n '$FAT1' ]"

# === 3. THE CONTROL, FIRST: a drive genuinely IN FLIGHT reads as RUNNING ====
: >"$r4.workerlog"
d4pid="$(drive_bg "$r4" "$MID" hang)"
BG_PIDS="$BG_PIDS $d4pid"
if await_mid_stage "$r4" "$MID" "$d4pid"; then
  ok "3-setup. a second real drive is mid-stage: it holds the lock and a worker ran"
else
  bad "3-setup. the second drive never reached a stage (pid $d4pid)"
fi
check "3-setup. the stale failed record IS still on disk while it runs (that is the risk)" \
  "[ -n \"\$(jget '$S4' 'd.get(\"failedStage\")')\" ]"
lstatus_to "$r4" "$OUT/live-st"
ech_to "$r4" "$OUT/live-stalled" stalled
ech_to "$r4" "$OUT/live-echstat" status
board_to "$r4" "$MID" "$OUT/live-board"
check "3a. lcars status shows NO failed glyph for a mission that is RUNNING" \
  "! grep -q '✖' '$OUT/live-st'"
check "3b. the stalled report is SILENT about a mission that is RUNNING" \
  "! grep -q '$MID' '$OUT/live-stalled'"
check "3c. the ECH status screen does NOT read FAILED for a mission that is RUNNING" \
  "! grep -q 'FAILED' '$OUT/live-echstat'"
check "3d. the board card carries NO failure for a mission that is RUNNING" \
  "[ \"\$(cat '$OUT/live-board')\" = null ]"

# === 2. NOW KILL IT, THE WAY A CLOSING LID DOES =============================
victims="$(kill_tree "$d4pid")"
BG_PIDS="$BG_PIDS $victims"
wait "$d4pid" 2>/dev/null || true
gone=1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$d4pid" 2>/dev/null || { gone=0; break; }
  sleep 0.25
done
check "2-setup. the driver is genuinely dead (killed by pid, with its children)" \
  "[ $gone -eq 0 ]"
check "2-setup. …and its driver.lock is still there, owned by a dead pid" \
  "[ -d '$r4/.git/lcars/missions/$MID/driver.lock' ] && ! kill -0 $d4pid 2>/dev/null"

lstatus_to "$r4" "$OUT/dead-st"
ech_to "$r4" "$OUT/dead-stalled" stalled
ech_to "$r4" "$OUT/dead-echstat" status
board_to "$r4" "$MID" "$OUT/dead-board"
check "2a. THE RECORD SURVIVED the killed attempt (it is not cleared at START)" \
  "[ -n \"\$(jget '$S4' 'd.get(\"failedStage\")')\" ]"
check "2b. lcars status shows the failed glyph again now the drive is dead" \
  "grep -q '✖' '$OUT/dead-st'"
check "2c. the stalled report names the mission" \
  "grep -q '$MID' '$OUT/dead-stalled'"
check "2d. the ECH status screen no longer reads like a mission between stages" \
  "grep -q 'FAILED' '$OUT/dead-echstat'"
check "2e. the board card carries a failure object again" \
  "[ \"\$(cat '$OUT/dead-board')\" != null ]"
check "2f. …and the board's failure names the stage that failed" \
  "grep -q research '$OUT/dead-board'"
check "2g. STARTING A DOOMED DRIVE NO LONGER MAKES THE MISSION INVISIBLE" \
  "grep -qi 'failed' '$OUT/dead-stalled'"

# --- fail -> retry -> fail: the record moves with the attempt it describes.
drive "$r4" "$MID" empty
FAT2="$(jget "$S4" 'd.get("failedAt")')"
ech_to "$r4" "$OUT/refail-stalled" stalled
check "2h. a second genuine failure RE-WRITES the record (it describes the LAST attempt)" \
  "[ -n '$FAT2' ] && [ '$FAT2' != '$FAT1' ]"
check "2i. …and it still reads as failed-and-idle afterwards" \
  "grep -q '$MID' '$OUT/refail-stalled'"

# --- and the cure the line NAMES actually works: a stage that SUCCEEDS clears it.
check "2j-setup. the stalled line names a re-drive as the cure" \
  "grep -q 'drive $MID' '$OUT/refail-stalled'"
drive "$r4" "$MID" good --step
lstatus_to "$r4" "$OUT/cured-st"
ech_to "$r4" "$OUT/cured-stalled" stalled
check "2j. doing it clears the record (the advice is PROVEN, not asserted)" \
  "[ -z \"\$(jget '$S4' 'd.get(\"failedStage\")')\" ]"
check "2k. …and the mission drops off the stalled report entirely" \
  "! grep -q '$MID' '$OUT/cured-stalled'"
check "2l. …and lcars status drops the failed glyph" \
  "! grep -q '✖' '$OUT/cured-st'"

# --- 3e: THE OTHER LIVENESS SHAPE. A bare stage run takes no driver.lock at all
#     (`acquire_driver_lock` is called from cmd_drive alone); the only witness is
#     its worker-adapter process. Before this round the stage_start clear hid the
#     stale record on that path too, so widening the record's life has to widen
#     the guard to match — on EVERY surface, not just the one `stalled` reads.
#     A REAL process with a real argv, as the ECH's own check requires.
r5="$(make_fixture f5)"; prd5="$TMPROOT/prd5.md"; write_prd "$prd5"
file_mission "$r5" --prd "$prd5"
S5="$r5/.git/lcars/missions/$MID/state.json"
drive "$r5" "$MID" empty
lstatus_to "$r5" "$OUT/r5-st0"
check "3e-setup. r5's Research failed and it reads as failed" \
  "grep -q '✖' '$OUT/r5-st0'"
WA5="$TMPROOT/wa5"; mkdir -p "$WA5"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' >"$WA5/worker-adapter.sh"
chmod +x "$WA5/worker-adapter.sh"
mkdir -p "$r5/.git/lcars/missions/$MID/research"
bash "$WA5/worker-adapter.sh" spawn claude read-only \
  "$r5/.git/lcars/missions/$MID/research" '<prompt>' </dev/null >/dev/null 2>&1 &
wa5=$!; BG_PIDS="$BG_PIDS $wa5"
ps -p "$wa5" -o command= >"$OUT/wa5.argv" 2>/dev/null || true
check "3e-setup. a REAL worker-adapter is running for this mission, with no lock" \
  "kill -0 $wa5 2>/dev/null && grep -q worker-adapter '$OUT/wa5.argv' \
   && [ ! -d '$r5/.git/lcars/missions/$MID/driver.lock' ]"
lstatus_to "$r5" "$OUT/r5-live-st"
board_to "$r5" "$MID" "$OUT/r5-live-board"
check "3e. lcars status shows NO failed glyph while that worker is live" \
  "! grep -q '✖' '$OUT/r5-live-st'"
check "3f. the board card carries NO failure while that worker is live" \
  "[ \"\$(cat '$OUT/r5-live-board')\" = null ]"
kill -9 "$wa5" 2>/dev/null; wait "$wa5" 2>/dev/null || true
lstatus_to "$r5" "$OUT/r5-dead-st"
board_to "$r5" "$MID" "$OUT/r5-dead-board"
check "3g. …and once that REAL worker exits, both surfaces report it again" \
  "grep -q '✖' '$OUT/r5-dead-st' && [ \"\$(cat '$OUT/r5-dead-board')\" != null ]"

# ===========================================================================
echo "-- 7. undeclared drift is refused at drive START, in seconds --"
# ===========================================================================
# The gate itself is NOT relaxed and NOT re-implemented: this drives the SAME
# proof_drift_declared_ok the pre-merge gate calls, from cmd_drive's post-lock,
# pre-stage-loop slot. The RECORD it reads (tickets/<id>/proof-tests.sha256) is
# planted — that is what a real Implement pass leaves behind — and the DRIFT is
# real: a committed test file on the mission branch whose content no longer
# matches its proof-time hash, with no ticket declaring the edit.
r2="$(make_fixture f2)"; prd2="$TMPROOT/prd2.md"; write_prd "$prd2"
file_mission "$r2" --prd "$prd2"
M2="$r2/.git/lcars/missions/$MID"
S2="$M2/state.json"
BR="lcars/$MID"

# A proven ticket, with its proof-time snapshot of a test it owns.
mkdir -p "$M2/tickets/t-001"
(
  cd "$r2"
  git checkout -q "$BR" 2>/dev/null
  printf 'echo original\n' >tests/owned.test.sh
  git add -A && git commit -q -m "t-001 test"
) >/dev/null 2>&1
SNAPHASH="$(cd "$r2" && git show "$BR:tests/owned.test.sh" | shasum -a 256 | awk '{print $1}')"
printf '%s  tests/owned.test.sh\n' "$SNAPHASH" >"$M2/tickets/t-001/proof-tests.sha256"

# …then the UNDECLARED drift: the committed test changes on the branch and NO
# test-edits.json declares it.
(
  cd "$r2"
  printf 'echo TAMPERED\n' >tests/owned.test.sh
  git add -A && git commit -q -m "drifted, undeclared"
  git checkout -q main 2>/dev/null
) >/dev/null 2>&1
check "7-setup. the branch really does carry undeclared drift" \
  "[ \"\$(cd '$r2' && git show '$BR:tests/owned.test.sh')\" = 'echo TAMPERED' ]"
check "7-setup. …and NO ticket declared it" \
  "! ls '$M2'/tickets/*/test-edits.json >/dev/null 2>&1"

# Put the mission at implement, which is where a drifted branch is driven from.
python3 - "$S2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["stage"] = "implement"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

T0="$(date +%s)"
drive "$r2" "$MID" empty
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
printf '  ⏱ drift refusal arrived in %ss (the finding: ~20 minutes at the end of an Implement pass)\n' "$ELAPSED"

check "7a. the drive REFUSED (non-zero), it did not carry on" \
  "[ \"\$(cat '$r2.drive.rc')\" != 0 ]"
check "7b. the refusal names UNDECLARED TEST DRIFT (the same gate, same words)" \
  "grep -qi 'undeclared test drift' '$r2.drive.out'"
check "7c. the refusal names the drifted file" \
  "grep -q 'tests/owned.test.sh' '$r2.drive.out'"
# THE WHOLE POINT: before any stage work. The witness is the worker log — a
# stage that ran would have spawned one — and events.jsonl's stage_start.
check "7d. NO stage worker was ever spawned (the refusal beat the stage loop)" \
  "[ ! -s '$r2.workerlog' ]"
check "7e. no stage_start was emitted for this drive" \
  "! grep -q '\"type\":\"stage_start\"' '$M2/events.jsonl' 2>/dev/null"
check "7f. the refusal took SECONDS, not an Implement pass (< 120s)" \
  "[ $ELAPSED -lt 120 ]"
check "7g. the early refusal is itself recorded as a failed state" \
  "[ \"\$(jget '$S2' 'd.get(\"failedStage\")')\" = implement ]"

# AND IT DOES NOT FIRE WHEN THERE IS NO DRIFT — a gate that refuses everything
# is not a gate. Same fixture shape, snapshot matching the committed content.
r3="$(make_fixture f3)"; prd3="$TMPROOT/prd3.md"; write_prd "$prd3"
file_mission "$r3" --prd "$prd3"
M3="$r3/.git/lcars/missions/$MID"
mkdir -p "$M3/tickets/t-001"
(
  cd "$r3"
  git checkout -q "lcars/$MID" 2>/dev/null
  printf 'echo original\n' >tests/owned.test.sh
  git add -A && git commit -q -m "t-001 test"
  git checkout -q main 2>/dev/null
) >/dev/null 2>&1
H3="$(cd "$r3" && git show "lcars/$MID:tests/owned.test.sh" | shasum -a 256 | awk '{print $1}')"
printf '%s  tests/owned.test.sh\n' "$H3" >"$M3/tickets/t-001/proof-tests.sha256"
drive "$r3" "$MID" empty
check "7h. a branch with NO drift is NOT refused early (it reaches its stage)" \
  "! grep -qi 'undeclared test drift' '$r3.drive.out'"
check "7i. …and that drive really did run its stage (the early check is not a stop-all)" \
  "[ -s '$r3.workerlog' ]"

# ===========================================================================
echo "-- ZERO SPEND --"
# ===========================================================================
check "POSITIVE CONTROL: the shim DOES log when a model CLI is invoked" \
  "[ -s '$MODEL_SHIM_CONTROL' ] && grep -q claude '$MODEL_SHIM_CONTROL' && grep -q copilot '$MODEL_SHIM_CONTROL'"
check "no model CLI was invoked (the claude/copilot PATH shim log is empty)" \
  "[ ! -s '$MODEL_SHIM_LOG' ]"
if [ -s "$MODEL_SHIM_LOG" ]; then
  printf '  shim log:\n'; sed 's/^/    /' "$MODEL_SHIM_LOG"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
