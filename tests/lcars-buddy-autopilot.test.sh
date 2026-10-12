#!/usr/bin/env bash
#
# tests/lcars-buddy-autopilot.test.sh — the AUTOPILOT half of `lcars buddy`
# (skill source: skills/lcars-buddy/autopilot.sh + AUTOPILOT.md + SKILL.md § 3).
#
# WHAT IS UNDER TEST. `lcars buddy` gained a second half: a mode the captain
# starts with "run it for me <spec>" and walks away from. The JUDGEMENT in that
# mode is prose the MODEL follows (AUTOPILOT.md); everything SEQUENCEABLE is
# `autopilot.sh`, a token-free bash driver OVER the existing LCARS verbs. This
# suite exercises the driver directly, with every verb and every AI CLI stubbed,
# plus a CONTRACT test that the INSTALLED prose carries the headings the
# driver's own `next` output names — so the script and the playbook cannot
# drift apart.
#
# WHY THE DRIVER IS A SCRIPT AND NOT PROSE. The weekend this mode is modelled on
# (26–29 Sep 2026) lost real time to an orchestrator hand-rolling the same shell
# twice: a "suite then push" gate that matched `FAILED` as success and pushed a
# red `main`, and an `alarm` wrapper that killed `approve` mid-retest. Both are
# now subcommands with tests (`push-gated`, `drive`'s waiter), because a guard
# that lives in prose is re-invented, badly, by the next session.
#
# DEPENDENCIES ARE ENV-INJECTED (the lcars-init pattern) so nothing real is
# touched and nothing is spent:
#   LCARS_AUTOPILOT_CWD        the repo to operate on        (default $PWD)
#   LCARS_GIT_BIN              git                            (real git here)
#   LCARS_PYTHON_BIN           python3                        (real python3 here)
#   LCARS_RUN_SCRIPT           lcars-run/run.sh               (stubbed)
#   LCARS_APPROVE_SCRIPT       lcars-approve/approve.sh       (stubbed)
#   LCARS_XO_SCRIPT            lcars-xo/xo.sh                 (stubbed)
#   LCARS_RESPOND_SCRIPT       lcars-respond/respond.sh       (stubbed)
#   LCARS_LOG_SCRIPT           lcars-log/log.sh               (stubbed)
#   LCARS_FILE_SCRIPT          lcars-file/file.sh             (stubbed)
#   LCARS_RESOLVE_LOGS_SCRIPT  lcars-resolve-logs/…           (stubbed)
#   LCARS_NOTIFY               the walk-away ping             (stubbed to a file)
#   LCARS_CRONTAB_BIN          crontab                        (stubbed to a file)
#
# ZERO WORKER SPEND IS PINNED BY A **PATH SHIM**, NOT AN ENV VAR. S140/S159
# measured the daemon's align path overriding `LCARS_WORKER_BIN` from the
# request body, and an env var losing to a persisted `state.json workerBin`. So
# this suite PREPENDS tests/lib/shims/deploy-watcher (which shims BOTH `claude`
# and `copilot`) to PATH and asserts at the end that the shim log is empty.
#
# Usage: bash tests/lcars-buddy-autopilot.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LCARS_AUTOPILOT_SCRIPT:-$REPO_ROOT/skills/lcars-buddy/autopilot.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"

# Every background process this suite (or the driver) starts is recorded so
# teardown can find it — S208/S209: a leaky suite left four daemons per run.
BG_PIDS=""
teardown() {
  local p
  for p in $BG_PIDS; do kill -9 "$p" 2>/dev/null || true; done
  # Anything the driver backgrounded is recorded in its own state files.
  local f
  for f in "$TMPROOT"/*/.git/lcars/autopilot.json; do
    [ -f "$f" ] || continue
    for p in $(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f"); do
      kill -9 "$p" 2>/dev/null || true
    done
    for p in $(sed -n 's/.*"driverPid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f"); do
      kill -9 "$p" 2>/dev/null || true
    done
  done
  rm -rf "$TMPROOT"
}
trap teardown EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# qgrep: see tests/lcars-buddy.test.sh for the full reasoning. Draining stdin
# only when NO file operand was passed is what keeps `grep -q` from either
# SIGPIPE-ing a live producer or reading INHERITED stdin (which blocks forever
# from a terminal, and passes by accident when stdin is closed).
qgrep() {
  local _a _in _n=0 _opt=1
  for _a in "$@"; do
    if [ "$_opt" = 1 ] && [ "$_a" = "--" ]; then _opt=0; continue; fi
    if [ "$_opt" = 1 ] && [ "$_a" != "${_a#-}" ] && [ "$_a" != "-" ]; then continue; fi
    _n=$((_n + 1))
  done
  if [ "$_n" -ge 2 ]; then grep "$@"; return; fi
  _in="$(cat)"; grep "$@" <<<"$_in"
}

# ==========================================================================
# THE PATH SHIM — zero worker spend, pinned on PATH for BOTH CLIs
# ==========================================================================
# `command -v copilot` on a dev box resolves to VS Code's shim, at a path WITH
# SPACES. Prepending (not appending) is the whole point: the shim must win over
# every resolution path, including one that re-derives the binary from a
# persisted state.json.
SHIM_DIR="$DIR/lib/shims/deploy-watcher"
export LCARS_DRIVE_SHIM_LOG="$TMPROOT/worker-shim.log"
: >"$LCARS_DRIVE_SHIM_LOG"
PATH="$SHIM_DIR:$PATH"; export PATH

# THE SPEND FUSE — the same one tests/lib/drive-rig.sh uses. Without it the
# zero-spend tally below is decoration: an empty shim dir puts the REAL `claude`
# back on PATH, a real `claude` never writes to $LCARS_DRIVE_SHIM_LOG, and the
# assertion still reads 0 — it cannot tell "nothing ran" from "the real thing
# ran and billed". A tripped fuse REFUSES to run the suite at all.
if [ ! -x "$SHIM_DIR/claude" ] || [ ! -x "$SHIM_DIR/copilot" ]; then
  printf 'SPEND FUSE TRIPPED: no counting claude/copilot at %s — REFUSING (would bill)\n' \
    "$SHIM_DIR" >&2
  exit 1
fi

# --- fixtures -------------------------------------------------------------

# new_repo — a real git repo, LCARS-shaped (.git/lcars/config.json), on main
# with one commit, plus a local bare "origin" so `push-gated` has something to
# push to for real.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  local bare="$repo.git"
  git init -q --bare "$bare"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  Tester
  echo seed >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm seed
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'JSON'
{
  "testCommand": "bash tests/run.sh",
  "engine": "copilot"
}
JSON
  echo "$repo"
}

# new_mission <repo> <id> <stage> [type] [parentMission]
new_mission() {
  local repo="$1" id="$2" stage="$3" type="${4:-feature}" parent="${5:-}"
  local d="$repo/.git/lcars/missions/$id"
  mkdir -p "$d"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "stage": "%s",\n' "$stage"
    printf '  "type": "%s",\n' "$type"
    printf '  "title": "mission %s",\n' "$id"
    printf '  "branch": "lcars/%s",\n' "$id"
    [ -n "$parent" ] && printf '  "parentMission": "%s",\n' "$parent"
    printf '  "issue": "1"\n'
    printf '}\n'
  } >"$d/state.json"
  # A real branch for `worktree` to detach from.
  git -C "$repo" branch -q "lcars/$id" main 2>/dev/null || true
}

# A stub verb recorder. stub <path> <exit-code> [body]
stub() {
  local path="$1" rc="$2" body="${3:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> "$STUB_LOG"\n'
    [ -n "$body" ] && printf '%s\n' "$body"
    printf 'exit %s\n' "$rc"
  } >"$path"
  chmod +x "$path"
}

# ap — run the driver against a repo with all deps stubbed.
#
# TMPDIR IS PINNED INSIDE $TMPROOT. `worktree` (and `live-check`, which reuses
# it) makes its detached worktree and throwaway HOME under ${TMPDIR:-/tmp}, so
# with the real TMPDIR every run of this suite left a pair of directories
# behind for ever — 151 of them on this box before the pin. Inside $TMPROOT
# they are removed by `teardown` along with the repos that registered them,
# which is the S208/S209 rule (a suite cleans up everything it starts) applied
# to directories instead of processes. No `rm -rf` with a pattern is involved.
ap() {
  local repo="$1"; shift
  mkdir -p "$TMPROOT/tmp"
  TMPDIR="$TMPROOT/tmp" \
  LCARS_AUTOPILOT_CWD="$repo" \
  STUB_LOG="$STUB_LOG" \
  LCARS_RUN_SCRIPT="$STUBS/run.sh" \
  LCARS_APPROVE_SCRIPT="$STUBS/approve.sh" \
  LCARS_XO_SCRIPT="$STUBS/xo.sh" \
  LCARS_RESPOND_SCRIPT="$STUBS/respond.sh" \
  LCARS_LOG_SCRIPT="${LOG_STUB:-$STUBS/log.sh}" \
  LCARS_FILE_SCRIPT="$STUBS/file.sh" \
  LCARS_RESOLVE_LOGS_SCRIPT="$STUBS/resolve-logs.sh" \
  LCARS_NOTIFY="$STUBS/notify.sh" \
  LCARS_CRONTAB_BIN="$STUBS/crontab" \
  bash "$SCRIPT" "$@" </dev/null
}

STUBS="$TMPROOT/stubs"
STUB_LOG="$TMPROOT/stub.log"
: >"$STUB_LOG"
mkdir -p "$STUBS"
stub "$STUBS/run.sh"          0
stub "$STUBS/approve.sh"      0
stub "$STUBS/xo.sh"           0
stub "$STUBS/respond.sh"      0
stub "$STUBS/log.sh"          0
stub "$STUBS/file.sh"         0
stub "$STUBS/resolve-logs.sh" 0
# APPROVE_MERGES — the stub body of an approve that GENUINELY merges. A real
# merge is observable in the mission's OWN state.json (stage -> done), which is
# what `land` must check: approve ALSO has an exit-0-did-NOT-merge outcome, and
# gating on its exit code alone reported that one as a landing.
APPROVE_MERGES='m=""
while [ $# -gt 0 ]; do case "$1" in --mission) m="$2"; shift ;; esac; shift; done
s="$LCARS_AUTOPILOT_CWD/.git/lcars/missions/$m/state.json"
[ -f "$s" ] && python3 - "$s" <<PY
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["stage"]="done"; json.dump(d,open(p,"w"))
PY'
stub "$STUBS/notify.sh"       0
# A crontab stub backed by one file, so `install` / `remove` are observable.
CRONFILE="$TMPROOT/crontab.txt"
: >"$CRONFILE"
cat >"$STUBS/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$CRONFILE"; exit 0; fi
if [ "${1:-}" = "-" ]; then cat >"$CRONFILE"; exit 0; fi
if [ "${1:-}" = "-r" ]; then : >"$CRONFILE"; exit 0; fi
cat >"$CRONFILE"
SH
chmod +x "$STUBS/crontab"
export CRONFILE

# jget <file> <python-expression-over-d>  — read a value out of the JSON record
jget() { python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
try:
    v=eval(sys.argv[2],{"d":d})
except Exception:
    v=None
print("" if v is None else (v if isinstance(v,str) else json.dumps(v)))
PY
}

echo
echo "=== lcars buddy autopilot: the driver ==================================="
echo

# ==========================================================================
# 1. init writes a complete autopilot.json; a second init refuses
# ==========================================================================
echo "-- 1. init --"
R1="$(new_repo)"
printf 'M0 the CLI\nM1 the page\n' >"$TMPROOT/spec.md"
out1="$(ap "$R1" init --spec "$TMPROOT/spec.md" --scope M0,M1 --engine copilot \
          --deadline 2026-10-01T07:00:00-07:00 2>&1)"; rc1=$?
AP1="$R1/.git/lcars/autopilot.json"

check "init exits 0"                       "[ $rc1 -eq 0 ]"
check "init writes .git/lcars/autopilot.json" "[ -f '$AP1' ]"
check "init prints the file it wrote"      "printf '%s' \"\$out1\" | qgrep -q 'autopilot.json'"
check "autopilot.json is valid JSON"       "python3 -c 'import json,sys;json.load(open(sys.argv[1]))' '$AP1'"

# Every key the schema promises. A missing key is state the mode would later
# have to INFER from chat — the failure mode that cost S147/S156/S188.
# `deploy` is the key alignment question 3 ("where it deploys, and what *live*
# means") had nowhere to land in — the tester had to drop the question for want
# of it. `questions` is the durable question ledger that `pending` only mirrors.
for k in spec scope engine latitude liveTargets stopRules report deadline \
         captainOnlySteps preauthorised testCommand missions pending \
         questions deploy startedAt lastForecast; do
  check "schema key: $k" "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if sys.argv[2] in d else 1)' '$AP1' '$k'"
done
check "latitude has allowed/never/stopAndAsk" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))[\"latitude\"];sys.exit(0 if all(x in d for x in (\"allowed\",\"never\",\"stopAndAsk\")) else 1)' '$AP1'"
check "preauthorised defaults are BOTH false" \
  "[ \"\$(jget '$AP1' 'd[\"preauthorised\"][\"manualMergeWhenApproveHitsKnownBug\"]')\" = false ] && [ \"\$(jget '$AP1' 'd[\"preauthorised\"][\"liveTestWrites\"]')\" = false ]"
check "scope parsed from --scope"          "[ \"\$(jget '$AP1' 'd[\"scope\"]')\" = '[\"M0\", \"M1\"]' ]"
check "engine recorded"                    "[ \"\$(jget '$AP1' 'd[\"engine\"]')\" = copilot ]"
check "deadline recorded"                  "printf '%s' \"\$(jget '$AP1' 'd[\"deadline\"]')\" | qgrep -q '2026-10-01'"
check "testCommand snapshotted from config.json" \
  "[ \"\$(jget '$AP1' 'd[\"testCommand\"]')\" = 'bash tests/run.sh' ]"
check "stopRules.lcarsBug recorded"        "[ -n \"\$(jget '$AP1' 'd[\"stopRules\"][\"lcarsBug\"]')\" ]"
check "deploy has somewhere to record WHERE it deploys and what live means" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))[\"deploy\"];sys.exit(0 if all(x in d for x in (\"where\",\"liveMeans\")) else 1)' '$AP1'"
check "questions starts as an empty LEDGER (an object, not one slot)" \
  "[ \"\$(jget '$AP1' 'd[\"questions\"]')\" = '{}' ]"

out1b="$(ap "$R1" init --spec "$TMPROOT/spec.md" --scope M9 2>&1)"; rc1b=$?
check "a second init REFUSES without --force" "[ $rc1b -ne 0 ]"
check "the refusal names --force"          "printf '%s' \"\$out1b\" | qgrep -q -- '--force'"
check "the refused init did NOT clobber scope" "[ \"\$(jget '$AP1' 'd[\"scope\"]')\" = '[\"M0\", \"M1\"]' ]"
out1c="$(ap "$R1" init --spec "$TMPROOT/spec.md" --scope M0,M1,M2 --force 2>&1)"; rc1c=$?
check "--force overwrites"                 "[ $rc1c -eq 0 ] && [ \"\$(jget '$AP1' 'd[\"scope\"]')\" = '[\"M0\", \"M1\", \"M2\"]' ]"

# ==========================================================================
# 2. status / next name the right next step, in order, and cap at two slots
# ==========================================================================
echo "-- 2. status / next --"
# S260: foundation readiness comes from the repo on EVERY next, not a flag.
RF="$(new_repo)"
printf '{}\n' >"$RF/.git/lcars/config.json"
nxfinit="$(ap "$RF" init --spec "$TMPROOT/spec.md" --scope M1 2>&1)"
check "S260 foundation: init immediately names the world's foundation step" \
  "printf '%s' \"\$nxfinit\" | qgrep -q '^NEXT: foundation$'"
nxf="$(ap "$RF" next --all 2>&1)"
check "S260 foundation: greenfield needs no manually recorded flag" \
  "printf '%s' \"\$nxf\" | qgrep -q '^NEXT: foundation$' && ! printf '%s' \"\$nxf\" | qgrep -q 'file M1'"
ap "$RF" record foundation.required true >/dev/null 2>&1
printf '{"testCommand":"bash tests/run.sh"}\n' >"$RF/.git/lcars/config.json"
nxfcommand="$(ap "$RF" next 2>&1)"
check "S260 foundation: a newly configured command overrides the stale required flag" \
  "printf '%s' \"\$nxfcommand\" | qgrep -q '^NEXT: file M1$'"
printf '{}\n' >"$RF/.git/lcars/config.json"
printf 'test:\n\tpython3 -m unittest discover\n' >"$RF/Makefile"
nxfdetected="$(ap "$RF" next 2>&1)"
check "S260 foundation: detected test infrastructure needs no recorded command" \
  "printf '%s' \"\$nxfdetected\" | qgrep -q '^NEXT: file M1$'"
rm "$RF/Makefile"
printf 'print("product")\n' >"$RF/product.py"
ap "$RF" record foundation.done true >/dev/null 2>&1
nxfuntested="$(ap "$RF" next 2>&1)"
check "S260 foundation: removing the test system is noticed despite a stale done flag" \
  "printf '%s' \"\$nxfuntested\" | qgrep -q '^NEXT: foundation$'"

# S260: a scope of nothing is setup to finish, not a completed product.
RE="$(new_repo)"
ap "$RE" init --spec "$TMPROOT/spec.md" >/dev/null 2>&1
nxempty="$(ap "$RE" next --all 2>&1)"
check "S260 scope: empty next names alignment and how to set scope, never done" \
  "printf '%s' \"\$nxempty\" | qgrep -q '^NEXT: align$' && printf '%s' \"\$nxempty\" | qgrep -q 'no scope is set.*--scope.*init.*record' && ! printf '%s' \"\$nxempty\" | qgrep -q 'done'"
stempty="$(ap "$RE" status 2>&1)"
check "S260 scope: status gives the same empty-scope instruction, never done" \
  "printf '%s' \"\$stempty\" | qgrep -q 'no scope is set.*--scope' && ! printf '%s' \"\$stempty\" | qgrep -q 'NEXT: done'"

# S260: the existing initialization Mission owns the slot until it lands.
RI="$(new_repo)"
printf '{}\n' >"$RI/.git/lcars/config.json"
ap "$RI" init --spec "$TMPROOT/spec.md" --scope M1 >/dev/null 2>&1
new_mission "$RI" lcars-foundation align
python3 - "$RI/.git/lcars/missions/lcars-foundation/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["missionType"] = "initialization"
json.dump(d, open(p, "w"))
PY
nxinit="$(ap "$RI" next --all 2>&1)"
check "S260 initialization: a filed foundation is driven before any product filing" \
  "printf '%s' \"\$nxinit\" | qgrep -q '^NEXT: drive lcars-foundation$' && ! printf '%s' \"\$nxinit\" | qgrep -q 'file M1'"
ap "$RI" record drivers.lcars-foundation.pid "$$" >/dev/null 2>&1
nxinitlive="$(ap "$RI" next --all 2>&1)"
check "S260 initialization: wait for its live driver instead of offering a product" \
  "printf '%s' \"\$nxinitlive\" | qgrep -q '^NEXT: wait$' && ! printf '%s' \"\$nxinitlive\" | qgrep -q 'file M1'"
ap "$RI" record drivers.lcars-foundation.pid '' >/dev/null 2>&1
python3 - "$RI/.git/lcars/missions/lcars-foundation/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["stage"] = "verify"
json.dump(d, open(p, "w"))
PY
printf '{"testCommand":"bash tests/run.sh"}\n' >"$RI/.git/lcars/config.json"
nxinitverify="$(ap "$RI" next --all 2>&1)"
check "S260 initialization: Verify precedes the product even when its runner now exists" \
  "printf '%s' \"\$nxinitverify\" | qgrep -q '^NEXT: verify-gate lcars-foundation$' && printf '%s' \"\$nxinitverify\" | qgrep -q '^PLAYBOOK: ## 6\.' && ! printf '%s' \"\$nxinitverify\" | qgrep -q 'file M1'"
python3 - "$RI/.git/lcars/missions/lcars-foundation/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["stage"] = "done"
json.dump(d, open(p, "w"))
PY
nxinitdone="$(ap "$RI" next 2>&1)"
check "S260 initialization: only after it lands is the product offered" \
  "printf '%s' \"\$nxinitdone\" | qgrep -q '^NEXT: file M1$'"

# S260: neither a stale verified flag nor Number One can skip our own check.
RV="$(new_repo)"
ap "$RV" init --spec "$TMPROOT/spec.md" --scope M1 >/dev/null 2>&1
new_mission "$RV" lcars-own-check verify
ap "$RV" record missions.M1.id lcars-own-check >/dev/null 2>&1
ap "$RV" record missions.M1.verified true >/dev/null 2>&1
mkdir -p "$RV/.git/lcars/missions/lcars-own-check/xo"
for verdict in high medium low absent; do
  if [ "$verdict" = absent ]; then
    rm "$RV/.git/lcars/missions/lcars-own-check/xo/verdict.json"
  else
    printf '{"score":"%s","recommendation":"merge","reason":"infrastructure"}\n' "$verdict" \
      >"$RV/.git/lcars/missions/lcars-own-check/xo/verdict.json"
  fi
  nxown="$(ap "$RV" next 2>&1)"
  nxownagain="$(ap "$RV" next 2>&1)"
  check "S260 Verify: $verdict review still routes to our live check on every next" \
    "printf '%s' \"\$nxown\" | qgrep -q '^NEXT: verify-gate lcars-own-check$' && printf '%s' \"\$nxown\" | qgrep -q '^PLAYBOOK: ## 6\.' && [ \"\$nxown\" = \"\$nxownagain\" ]"
done
check "S260 Verify: repo playbook makes the buddy's check a standing job, never a fallback" \
  "qgrep -qF 'This is your standing job, never a fallback.' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md'"

usage260="$(ap "$RE" 2>&1)"; usagerc260=$?
# S277: command-name literal ONLY. AUTOPILOT.md now names the on-PATH `lcars-autopilot <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `autopilot.sh`.
check "S260 usage: no arguments print help with exit 1 and no shell errors" \
  "[ $usagerc260 -eq 1 ] && printf '%s' \"\$usage260\" | qgrep -q '^Usage: lcars-autopilot' && ! printf '%s' \"\$usage260\" | qgrep -q 'command not found'"
check "S260 usage: backticked examples are printed literally, not executed" \
  "printf '%s' \"\$usage260\" | qgrep -qF 'AC #1 = \`Observed live:\`' && printf '%s' \"\$usage260\" | qgrep -qF 'through \`lcars log\`' && printf '%s' \"\$usage260\" | qgrep -qF '\`--table\` prints'"

# S260: screen intent is judged from the milestone's brief, not another flag.
RH="$(new_repo)"
printf 'M0: CLI export, no screens.\nM1: Dashboard with screens.\n' >"$TMPROOT/screens-spec.md"
ap "$RH" init --spec "$TMPROOT/screens-spec.md" --scope M1 >/dev/null 2>&1
nxscreen="$(ap "$RH" next --all 2>&1)"
check "S260 holodeck: the screens branch reaches the surface before filing" \
  "printf '%s' \"\$nxscreen\" | qgrep -qF 'IF M1 has screens (judge its own spec/brief):' && printf '%s' \"\$nxscreen\" | qgrep -q '^NEXT: holodeck M1$' && [ \"\$(printf '%s\n' \"\$nxscreen\" | grep -n '^NEXT: holodeck' | cut -d: -f1)\" -lt \"\$(printf '%s\n' \"\$nxscreen\" | grep -n '^NEXT: file' | cut -d: -f1)\" ]"
check "S260 holodeck: its next step cites the existing front-door heading" \
  "printf '%s' \"\$nxscreen\" | qgrep -A1 '^NEXT: holodeck M1$' | qgrep -qF 'PLAYBOOK: ## 4. File a milestone through the front door'"
ap "$RH" record scope '["M0"]' >/dev/null 2>&1
nxnoscreen="$(ap "$RH" next 2>&1)"
check "S260 holodeck: the no-screens branch goes directly to file" \
  "printf '%s' \"\$nxnoscreen\" | sed -n '/^OTHERWISE:/,\$p' | qgrep -q '^NEXT: file M0$' && ! printf '%s' \"\$nxnoscreen\" | sed -n '/^OTHERWISE:/,\$p' | qgrep -q '^NEXT: holodeck'"
check "S260 holodeck: repo prose distinguishes the real surface from an attachment" \
  "qgrep -qF 'holodeck_start' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md' && qgrep -qF 'holodeck_say' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md' && qgrep -qF 'holodeck_end' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md' && qgrep -qF 'mockup.html' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md' && qgrep -qF 'State which path you took.' '$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md'"

R2="$(new_repo)"
ap "$R2" init --spec "$TMPROOT/spec.md" --scope M0,M1 >/dev/null 2>&1
AP2="$R2/.git/lcars/autopilot.json"
new_mission "$R2" lcars-20260930-001 verify
ap "$R2" record 'missions.M0.id' lcars-20260930-001 >/dev/null 2>&1

st2="$(ap "$R2" status 2>&1)"
check "status names the M0 mission id"     "printf '%s' \"\$st2\" | qgrep -q 'lcars-20260930-001'"
check "status shows M0's stage"            "printf '%s' \"\$st2\" | qgrep -q 'verify'"
check "status shows the unfiled M1"        "printf '%s' \"\$st2\" | qgrep -q 'M1'"
check "status reports the parallel slots"  "printf '%s' \"\$st2\" | qgrep -qi 'slots'"
check "status names the next action"       "printf '%s' \"\$st2\" | qgrep -qi 'next'"

nx2="$(ap "$R2" next 2>&1)"
check "next picks verify-gate for the in-flight M0, not filing M1" \
  "printf '%s' \"\$nx2\" | qgrep -q 'verify-gate lcars-20260930-001'"
check "next prints ONE action line"        "[ \"\$(printf '%s\n' \"\$nx2\" | grep -c '^NEXT: ')\" = 1 ]"
check "next cites the playbook heading"    "printf '%s' \"\$nx2\" | qgrep -q '^PLAYBOOK: '"

nx2all="$(ap "$R2" next --all 2>&1)"
check "next --all orders verify-gate BEFORE file M1" \
  "[ \"\$(printf '%s\n' \"\$nx2all\" | grep -n 'verify-gate' | head -1 | cut -d: -f1)\" -lt \"\$(printf '%s\n' \"\$nx2all\" | grep -n 'file M1' | head -1 | cut -d: -f1)\" ]"

# Even a previously verified M0 still goes through the standing Verify gate.
ap "$R2" record 'missions.M0.verified' true >/dev/null 2>&1
nx2b="$(ap "$R2" next 2>&1)"
check "a previously verified mission's next step remains verify-gate" \
  "printf '%s' \"\$nx2b\" | qgrep -q 'NEXT: verify-gate lcars-20260930-001'"

# Two live drivers → the two-slot cap means WAIT, never a third file/drive.
sleep_pid_a=""; sleep_pid_b=""
( exec -a lcars-fake-driver sh -c 'while :; do :; done' ) </dev/null >/dev/null 2>&1 &
sleep_pid_a=$!; BG_PIDS="$BG_PIDS $sleep_pid_a"
( exec -a lcars-fake-driver sh -c 'while :; do :; done' ) </dev/null >/dev/null 2>&1 &
sleep_pid_b=$!; BG_PIDS="$BG_PIDS $sleep_pid_b"
R2b="$(new_repo)"
ap "$R2b" init --spec "$TMPROOT/spec.md" --scope M0,M1,M2 >/dev/null 2>&1
new_mission "$R2b" lcars-a plan
new_mission "$R2b" lcars-b plan
ap "$R2b" record 'missions.M0.id' lcars-a >/dev/null 2>&1
ap "$R2b" record 'missions.M1.id' lcars-b >/dev/null 2>&1
ap "$R2b" record "drivers.lcars-a.pid" "$sleep_pid_a" >/dev/null 2>&1
ap "$R2b" record "drivers.lcars-b.pid" "$sleep_pid_b" >/dev/null 2>&1
nx2c="$(ap "$R2b" next 2>&1)"
check "two live drivers → next is wait (two-slot cap)" \
  "printf '%s' \"\$nx2c\" | qgrep -q '^NEXT: wait'"
check "the cap message says two"           "printf '%s' \"\$nx2c\" | qgrep -q '2'"
st2c="$(ap "$R2b" status 2>&1)"
check "status reports 2/2 slots in use"    "printf '%s' \"\$st2c\" | qgrep -q '2/2'"
kill -9 "$sleep_pid_a" "$sleep_pid_b" 2>/dev/null || true

# --- D4: a DECLINED captain-only step is a recorded outcome, not an absence --
# The tester declined BOTH captain-only steps ("no deploy token, no Pages
# tonight") and `next` immediately wanted to go back to him about a step he had
# just declined. The only escapes were `done: true` (a lie in the ledger) or
# deleting the steps (losing that they were ever asked). He deleted them.
R2d="$(new_repo)"
ap "$R2d" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP2d="$R2d/.git/lcars/autopilot.json"
new_mission "$R2d" lcars-decl-1 plan
ap "$R2d" record 'missions.M0.id' lcars-decl-1 >/dev/null 2>&1
ap "$R2d" record 'captainOnlySteps' \
  '[{"what":"a Pages deploy token","instructions":"! pbpaste | gh secret set TOK -R h/o/r","neededBy":"before M0 drives","done":false}]' >/dev/null 2>&1
nx2d="$(ap "$R2d" next --all 2>&1)"
check "an OUTSTANDING captain-only step is still surfaced" \
  "printf '%s' \"\$nx2d\" | qgrep -q 'captain-step'"
ap "$R2d" record 'captainOnlySteps' \
  '[{"what":"a Pages deploy token","instructions":"! pbpaste | gh secret set TOK -R h/o/r","neededBy":"before M0 drives","done":false,"declined":true,"declinedReason":"no deploy token, no Pages tonight"}]' >/dev/null 2>&1
nx2e="$(ap "$R2d" next --all 2>&1)"
check "a DECLINED captain-only step is never asked for again" \
  "! printf '%s' \"\$nx2e\" | qgrep -q 'captain-step'"
check "declining does NOT require writing done:true (no lie in the ledger)" \
  "[ \"\$(jget '$AP2d' 'd[\"captainOnlySteps\"][0][\"done\"]')\" = false ]"
check "the fact that the step WAS asked survives the decline" \
  "printf '%s' \"\$(jget '$AP2d' 'd[\"captainOnlySteps\"][0][\"what\"]')\" | qgrep -q 'Pages deploy token'"
check "with the step declined, next moves on to the real work" \
  "printf '%s' \"\$nx2e\" | qgrep -q 'drive lcars-decl-1'"
st2d="$(ap "$R2d" status 2>&1)"
check "status counts 0 outstanding once the only step is declined" \
  "printf '%s' \"\$st2d\" | qgrep -q 'captain-only steps outstanding: 0'"
check "status still SHOWS the declined step (it is not lost)" \
  "printf '%s' \"\$st2d\" | qgrep -qi 'declined'"

# ==========================================================================
# 3. drive backgrounds the driver; the waiter watches the PROCESS
# ==========================================================================
echo "-- 3. drive + the waiter --"
R3="$(new_repo)"
ap "$R3" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP3="$R3/.git/lcars/autopilot.json"
new_mission "$R3" lcars-drive-1 implement
# A long-running run.sh stand-in: it writes its log, then blocks until killed.
cat >"$STUBS/run-long.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$STUB_LOG"
printf 'gate timeout is %s\n' "${LCARS_GATE_TIMEOUT:-unset}"
while :; do sleep 1; done
SH
chmod +x "$STUBS/run-long.sh"

t0=$(date +%s)
drv="$(LCARS_AUTOPILOT_CWD="$R3" STUB_LOG="$STUB_LOG" \
       LCARS_RUN_SCRIPT="$STUBS/run-long.sh" \
       LCARS_APPROVE_SCRIPT="$STUBS/approve.sh" LCARS_XO_SCRIPT="$STUBS/xo.sh" \
       LCARS_NOTIFY="$STUBS/notify.sh" LCARS_CRONTAB_BIN="$STUBS/crontab" \
       bash "$SCRIPT" drive lcars-drive-1 2>&1 </dev/null)"; rc3=$?
t1=$(date +%s)
check "drive returns immediately (backgrounded)" "[ $((t1 - t0)) -lt 10 ]"
check "drive exits 0"                      "[ $rc3 -eq 0 ]"
check "drive prints the log path"           "printf '%s' \"\$drv\" | qgrep -q 'drive-lcars-drive-1.log'"

# The owner pid is recorded SYNCHRONOUSLY; the inner driver pid lands a beat later.
ownpid="$(jget "$AP3" 'd["drivers"]["lcars-drive-1"]["pid"]')"
check "the owning pid is recorded in autopilot.json" "[ -n '$ownpid' ] && kill -0 '$ownpid' 2>/dev/null"
BG_PIDS="$BG_PIDS $ownpid"
dpid=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  dpid="$(jget "$AP3" 'd["drivers"]["lcars-drive-1"]["driverPid"]')"
  [ -n "$dpid" ] && break
  sleep 0.25
done
check "the inner driver pid is recorded too" "[ -n '$dpid' ]"
[ -n "$dpid" ] && BG_PIDS="$BG_PIDS $dpid"
check "LCARS_GATE_TIMEOUT came from the config" \
  "qgrep -q 'gate timeout is 600' '$R3/.git/lcars/autopilot/drive-lcars-drive-1.log'"
check "the drive called run.sh drive --mission (it did not re-sequence stages)" \
  "qgrep -q 'run-long.sh drive --mission lcars-drive-1' '$STUB_LOG'"
check "no sleep-polling in the waiter: it blocks on the process" \
  "! qgrep -qE '^[^#]*(sleep [0-9]+ *; *(kill|done)|while .*kill -0)' '$SCRIPT'"

# Kill the DRIVER; the waiter must notice through the process, within 5 s.
kill -9 "$dpid" 2>/dev/null
waiter_gone=1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ! kill -0 "$ownpid" 2>/dev/null; then waiter_gone=0; break; fi
  sleep 0.25
done
check "the waiter exits within 5 s of the driver dying" "[ $waiter_gone -eq 0 ]"
cleared=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -z "$(jget "$AP3" 'd["drivers"]["lcars-drive-1"]["pid"]')" ] && { cleared=0; break; }
  sleep 0.25
done
check "the pid is CLEARED from autopilot.json when the drive ends" "[ $cleared -eq 0 ]"
check "the exit is RECORDED (exitedAt), not inferred from the log" \
  "[ -n \"\$(jget '$AP3' 'd[\"drivers\"][\"lcars-drive-1\"][\"exitedAt\"]')\" ]"

# ==========================================================================
# 4. stalled — silent while live, reports once the driver exited at a gate
# ==========================================================================
echo "-- 4. stalled (what the heartbeat calls) --"
R4="$(new_repo)"
ap "$R4" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP4="$R4/.git/lcars/autopilot.json"
new_mission "$R4" lcars-stall-1 implement
ap "$R4" record 'missions.M0.id' lcars-stall-1 >/dev/null 2>&1
( exec -a lcars-fake-driver sh -c 'while :; do :; done' ) </dev/null >/dev/null 2>&1 &
live_pid=$!; BG_PIDS="$BG_PIDS $live_pid"
ap "$R4" record "drivers.lcars-stall-1.pid" "$live_pid" >/dev/null 2>&1
s4a="$(ap "$R4" stalled 2>&1)"; rc4a=$?
check "stalled exits 0 while a driver is live" "[ $rc4a -eq 0 ]"
check "stalled is SILENT about a live mission"  "! printf '%s' \"\$s4a\" | qgrep -q 'lcars-stall-1'"

kill -9 "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
ap "$R4" record "drivers.lcars-stall-1.exitedAt" 1 >/dev/null 2>&1
ap "$R4" record "drivers.lcars-stall-1.pid" '' >/dev/null 2>&1
s4b="$(ap "$R4" stalled 2>&1)"; rc4b=$?
check "stalled exits 0 when it reports (the heartbeat must not fail)" "[ $rc4b -eq 0 ]"
check "stalled reports the mission nobody picked up" \
  "printf '%s' \"\$s4b\" | qgrep -q 'lcars-stall-1'"
check "stalled decides from the RECORDED pid, not by parsing driver logs" \
  "! qgrep -qE 'stopped at|grep .*drive-.*\\.log' '$SCRIPT' || ! grep -n 'cmd_stalled' -A40 '$SCRIPT' | qgrep -q 'stopped at'"
# Once a human/model picks it up, it is no longer stalled.
ap "$R4" record "drivers.lcars-stall-1.pickedUpAt" 2 >/dev/null 2>&1
s4c="$(ap "$R4" stalled 2>&1)"
check "a picked-up mission stops being reported" \
  "! printf '%s' \"\$s4c\" | qgrep -q 'lcars-stall-1'"
# A done mission is never stalled.
R4b="$(new_repo)"
ap "$R4b" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$R4b" lcars-done-1 done
ap "$R4b" record 'missions.M0.id' lcars-done-1 >/dev/null 2>&1
ap "$R4b" record "drivers.lcars-done-1.exitedAt" 1 >/dev/null 2>&1
check "a done mission is never reported stalled" \
  "! ap '$R4b' stalled 2>&1 | qgrep -q 'lcars-done-1'"

# ==========================================================================
# 5. land — the approve path, its refusals, and the hygiene
# ==========================================================================
echo "-- 5. land --"
# 5a. An OPEN CHILD: exit 10, a pending question written, approve NEVER called.
R5="$(new_repo)"
ap "$R5" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP5="$R5/.git/lcars/autopilot.json"
new_mission "$R5" lcars-parent-1 verify
new_mission "$R5" lcars-bug-1 implement bug lcars-parent-1
: >"$STUB_LOG"
l5="$(ap "$R5" land lcars-parent-1 2>&1)"; rc5=$?
check "land with an open child exits 10"   "[ $rc5 -eq 10 ]"
check "land with an open child did NOT call approve" \
  "! qgrep -q 'approve.sh' '$STUB_LOG'"
check "land NEVER hand-merges (no git merge anywhere in the script)" \
  "! qgrep -qE '(git|GIT_BIN)\"? +(-C [^ ]+ )?merge' '$SCRIPT'"
check "a pending question is WRITTEN to autopilot.json" \
  "[ -n \"\$(jget '$AP5' 'd[\"pending\"][\"what\"]')\" ]"
check "the pending question names the blocking child" \
  "printf '%s' \"\$(jget '$AP5' 'd[\"pending\"]')\" | qgrep -q 'lcars-bug-1'"
for f in what why command rollback; do
  check "pending carries '$f'" "[ -n \"\$(jget '$AP5' 'd[\"pending\"][\"$f\"]')\" ]"
done
check "land fired the walk-away notification" "qgrep -q 'notify.sh lcars-parent-1' '$STUB_LOG'"

# 5b. CLEAN: approve called, testCommand re-asserted, children released,
#     the stale reconcile worktree removed.
R6="$(new_repo)"
ap "$R6" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP6="$R6/.git/lcars/autopilot.json"
new_mission "$R6" lcars-parent-2 verify
new_mission "$R6" lcars-bug-2 done bug lcars-parent-2
# An approve stub that CLOBBERS the captain's testCommand, exactly as the
# weekend's approve did (it promoted an uninstalled pytest over the recorded
# stdlib command).
stub "$STUBS/approve.sh" 0 'python3 - "$LCARS_AP_CFG" <<PY
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["testCommand"]="pytest -q"
json.dump(d,open(p,"w"))
PY
'"$APPROVE_MERGES"
# A stale reconcile worktree holding the mission branch, left by a blocked merge.
RECON="$R6/../reconcile.ABC123"
git -C "$R6" worktree add -q --detach "$RECON" main 2>/dev/null
: >"$STUB_LOG"
l6="$(LCARS_AP_CFG="$R6/.git/lcars/config.json" ap "$R6" land lcars-parent-2 2>&1)"; rc6=$?
check "a clean land exits 0"                "[ $rc6 -eq 0 ]"
check "land called approve.sh --mission"    "qgrep -q 'approve.sh --mission lcars-parent-2' '$STUB_LOG'"
check "approve is called ONCE (no retry loop)" \
  "[ \"\$(grep -c 'approve.sh --mission' '$STUB_LOG')\" = 1 ]"
check "the captain's testCommand is RE-ASSERTED after approve clobbered it" \
  "[ \"\$(jget '$R6/.git/lcars/config.json' 'd[\"testCommand\"]')\" = 'bash tests/run.sh' ]"
check "land reports the re-assert rather than doing it silently" \
  "printf '%s' \"\$l6\" | qgrep -qi 'testCommand'"
check "every folded child got xo off (LCARS does not release them)" \
  "qgrep -q 'xo.sh off lcars-bug-2' '$STUB_LOG'"
check "the stale reconcile worktree was removed" "[ ! -d '$RECON' ]"
check "land pulled main"                     "printf '%s' \"\$l6\" | qgrep -qi 'pull'"
check "the merge is recorded in the decisions ledger" \
  "qgrep -q 'lcars-parent-2' '$R6/.git/lcars/decisions.jsonl'"
stub "$STUBS/approve.sh" 0

# 5c. A REFUSED merge: exit 10, one pre-staged question, no hand-merge.
R7="$(new_repo)"
ap "$R7" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP7="$R7/.git/lcars/autopilot.json"
new_mission "$R7" lcars-parent-3 verify
stub "$STUBS/approve.sh" 1 'echo "lcars approve: test-drift gate REFUSED the merge" >&2'
: >"$STUB_LOG"
l7="$(ap "$R7" land lcars-parent-3 2>&1)"; rc7=$?
check "a refused merge exits 10"            "[ $rc7 -eq 10 ]"
check "a refused merge writes ONE pending question" \
  "[ \"\$(jget '$AP7' 'd[\"pending\"][\"what\"]')\" != '' ]"
check "the pending question quotes LCARS's own refusal" \
  "printf '%s' \"\$(jget '$AP7' 'd[\"pending\"]')\" | qgrep -q 'test-drift'"
check "a refused merge does NOT re-run approve" \
  "[ \"\$(grep -c 'approve.sh --mission' '$STUB_LOG')\" = 1 ]"
stub "$STUBS/approve.sh" 0

# 5d. A LIVE driver on the same mission: land refuses before touching approve.
R8="$(new_repo)"
ap "$R8" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$R8" lcars-parent-4 verify
( exec -a lcars-fake-driver sh -c 'while :; do :; done' ) </dev/null >/dev/null 2>&1 &
lp=$!; BG_PIDS="$BG_PIDS $lp"
ap "$R8" record "drivers.lcars-parent-4.pid" "$lp" >/dev/null 2>&1
: >"$STUB_LOG"
l8="$(ap "$R8" land lcars-parent-4 2>&1)"; rc8=$?
check "land refuses while a driver is live" "[ $rc8 -ne 0 ]"
check "that refusal never reached approve"  "! qgrep -q 'approve.sh' '$STUB_LOG'"
kill -9 "$lp" 2>/dev/null || true

# --- 5e: approve exit 0 that did NOT merge (the reconcile / awaiting-reapprove
#         outcome) must NOT be reported as a landing --------------------------
# `cmd_land`'s whole success test was approve's EXIT CODE. But approve has an
# exit-0-did-not-merge path: its self-heal reconcile (approve.sh
# reconcileStatus=awaiting-reapprove) reconciles main into the branch, re-tests
# green, prints "Reapprove to merge. Mission stays at verify awaiting your
# reapprove" and EXITS 0. The mode then printed `landed <mission>`, ran the full
# post-merge hygiene, and wrote {"what":"merged"} to the decisions ledger —
# while the stage stayed `verify` and main never moved. Silent, UNBOUNDED (land
# reporting success means the drive-failure cap cannot see it), and it
# FALSIFIES the captain's record of what shipped: four laps produced six false
# "merged" entries and nothing merged.
# The cure is to re-read the mission's OWN state.json: landed only when the
# stage is actually `done`. The mode must NEVER pass --reapprove itself —
# that sign-off is the captain's by design.
R5E="$(new_repo)"
ap "$R5E" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP5E="$R5E/.git/lcars/autopilot.json"
new_mission "$R5E" lcars-reapp-1 verify
new_mission "$R5E" lcars-reappbug-1 done bug lcars-reapp-1
# approve's reconcile path, to the letter: exit 0, nothing merged, the stage
# left at verify waiting for the captain's --reapprove.
stub "$STUBS/approve.sh" 0 'echo "Reconciled main into the branch and re-tested green (1/1). Reapprove to merge. Mission stays at verify awaiting your reapprove"'
: >"$STUB_LOG"
DEC5E="$R5E/.git/lcars/decisions.jsonl"
l5e="$(ap "$R5E" land lcars-reapp-1 2>&1)"; rc5e=$?
check "approve exit 0 with the stage still at verify is NOT a landing" \
  "[ $rc5e -ne 0 ]"
check "it does not claim the mission landed" \
  "! printf '%s' \"\$l5e\" | qgrep -q 'landed lcars-reapp-1'"
check "NO 'merged' entry reaches the decisions ledger (the record stays true)" \
  "[ ! -s '$DEC5E' ] || ! grep -q merged '$DEC5E'"
check "the post-merge hygiene did NOT run (no folded child released)" \
  "! qgrep -q 'xo.sh off' '$STUB_LOG'"
check "it raises exactly ONE question for the captain" \
  "[ \"\$(jget '$AP5E' 'len(d[\"questions\"])')\" = 1 ]"
check "that question names the reapprove command he must run" \
  "printf '%s' \"\$(jget '$AP5E' 'd[\"pending\"][\"command\"]')\" | qgrep -q -- '--reapprove'"
check "the question says the merge did NOT happen" \
  "printf '%s' \"\$(jget '$AP5E' 'd[\"pending\"][\"what\"]')\" | qgrep -qiE 'did not merge|not merged|no merge'"
check "the question reports the stage the mission is actually at" \
  "printf '%s' \"\$(jget '$AP5E' 'd[\"pending\"]')\" | qgrep -q 'verify'"
check "it pings the captain (this is a real stop-and-ask)" \
  "qgrep -q 'notify.sh lcars-reapp-1' '$STUB_LOG'"
check "the mode NEVER passes --reapprove to approve itself" \
  "! qgrep -q -- '--reapprove' '$STUB_LOG'"
check "approve was still called exactly once (no retry loop)" \
  "[ \"\$(grep -c 'approve.sh --mission lcars-reapp-1' '$STUB_LOG')\" = 1 ]"
ap "$R5E" land lcars-reapp-1 >/dev/null 2>&1
check "a repeat land re-raises nothing (the question stays one)" \
  "[ \"\$(jget '$AP5E' 'len(d[\"questions\"])')\" = 1 ]"
check "a repeat land does not re-ping (interrupt budget)" \
  "[ \"\$(grep -c 'notify.sh lcars-reapp-1 ' '$STUB_LOG')\" = 1 ]"

# --- 5f: a GENUINE merge still lands, with the FULL hygiene -----------------
# The regression most at risk from 5e. approve exits 0 AND moves the mission to
# `done`, exactly as a real merge does: everything 5b asserts must still happen.
R5F="$(new_repo)"
ap "$R5F" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP5F="$R5F/.git/lcars/autopilot.json"
new_mission "$R5F" lcars-realmerge-1 verify
new_mission "$R5F" lcars-realbug-1 done bug lcars-realmerge-1
stub "$STUBS/approve.sh" 0 "$APPROVE_MERGES"
: >"$STUB_LOG"
l5f="$(ap "$R5F" land lcars-realmerge-1 2>&1)"; rc5f=$?
check "a genuine merge (stage → done) still exits 0" "[ $rc5f -eq 0 ]"
check "a genuine merge still reports it landed" \
  "printf '%s' \"\$l5f\" | qgrep -q 'landed lcars-realmerge-1'"
check "a genuine merge still releases every folded child" \
  "qgrep -q 'xo.sh off lcars-realbug-1' '$STUB_LOG'"
check "a genuine merge still pulls main" \
  "printf '%s' \"\$l5f\" | qgrep -qi 'pull'"
check "a genuine merge still records itself in the decisions ledger" \
  "qgrep -q 'lcars-realmerge-1' '$R5F/.git/lcars/decisions.jsonl'"
check "a genuine merge raises NO question" \
  "[ \"\$(jget '$AP5F' 'len(d[\"questions\"])')\" = 0 ]"
check "a genuine merge pings nobody (it is not a gate)" \
  "! qgrep -q 'notify.sh lcars-realmerge-1' '$STUB_LOG'"
stub "$STUBS/approve.sh" 0

# ==========================================================================
# 6. push-gated — the gate the orchestrator must never hand-roll
# ==========================================================================
echo "-- 6. push-gated --"
R9="$(new_repo)"
ap "$R9" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
# The exact weekend bug: a suite that PRINTS "FAILED" and exits 1. A gate that
# grepped for a success word matched it and pushed a red main.
cat >"$R9/failing-suite.sh" <<'SH'
#!/usr/bin/env bash
echo "ran 12 tests"
echo "FAILED (failures=1)"
exit 1
SH
chmod +x "$R9/failing-suite.sh"
ap "$R9" record 'testCommand' 'bash failing-suite.sh' >/dev/null 2>&1
echo change >>"$R9/README.md"
git -C "$R9" add -A; git -C "$R9" commit -qm "a change to push"
before="$(git -C "$R9" rev-parse origin/main)"
p9="$(ap "$R9" push-gated 2>&1)"; rc9=$?
after="$(git -C "$R9" rev-parse origin/main)"
check "push-gated REFUSES on a failing suite"      "[ $rc9 -ne 0 ]"
check "nothing was pushed on a failing suite"      "[ '$before' = '$after' ]"
check "the refusal says the suite failed"          "printf '%s' \"\$p9\" | qgrep -qi 'fail'"

cat >"$R9/green-suite.sh" <<'SH'
#!/usr/bin/env bash
echo "ran 12 tests"
echo "OK"
SH
chmod +x "$R9/green-suite.sh"
git -C "$R9" add -A; git -C "$R9" commit -qm "add the green suite"
ap "$R9" record 'testCommand' 'bash green-suite.sh' >/dev/null 2>&1
p9b="$(ap "$R9" push-gated 2>&1)"; rc9b=$?
after2="$(git -C "$R9" rev-parse origin/main)"
check "push-gated pushes on exit 0"                "[ $rc9b -eq 0 ]"
check "origin/main moved"                          "[ '$before' != '$after2' ]"
check "push-gated gates on the EXIT CODE, not a grep for a word" \
  "grep -n 'cmd_push_gated' -A40 '$SCRIPT' | qgrep -q 'rc'"

# ==========================================================================
# 7. worktree — detached, with a throwaway HOME
# ==========================================================================
echo "-- 7. worktree --"
R10="$(new_repo)"
ap "$R10" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$R10" lcars-wt-1 verify
w10="$(ap "$R10" worktree lcars-wt-1 2>&1)"; rc10=$?
WT="$(printf '%s\n' "$w10" | sed -n 's/^WORKTREE: //p' | head -1)"
WH="$(printf '%s\n' "$w10" | sed -n 's/^HOME: //p' | head -1)"
check "worktree exits 0"                     "[ $rc10 -eq 0 ]"
check "worktree prints WORKTREE: <path>"     "[ -n '$WT' ] && [ -d '$WT' ]"
check "worktree prints HOME: <path>"         "[ -n '$WH' ] && [ -d '$WH' ]"
check "the worktree HEAD is DETACHED (never holds the mission branch)" \
  "! git -C '$WT' symbolic-ref -q HEAD >/dev/null 2>&1"
check "it is the mission's branch commit"    "[ \"\$(git -C '$WT' rev-parse HEAD)\" = \"\$(git -C '$R10' rev-parse lcars/lcars-wt-1)\" ]"
check "no glob deletes anywhere in the driver" \
  "! qgrep -qE 'rm +-[rf]+ +[^ ]*\\*' '$SCRIPT'"
check "no cd-then-delete anywhere in the driver" \
  "! qgrep -qE 'cd .*(&&|;) *rm ' '$SCRIPT'"

# ==========================================================================
# 8. ledger + heartbeat (crontab, NOT a harness tool)
# ==========================================================================
echo "-- 8. ledger + heartbeat --"
R11="$(new_repo)"
ap "$R11" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
ap "$R11" ledger feedback '{"kind":"lcars-bug","detail":"fold drift blocked a merge"}' >/dev/null 2>&1
ap "$R11" ledger overrides '{"mission":"lcars-x","verdict":"low","reason":"infra only"}' >/dev/null 2>&1
ap "$R11" ledger decisions '{"what":"added M6","who":"captain"}' >/dev/null 2>&1
check "ledger feedback → .git/lcars/lcars-feedback.jsonl" \
  "qgrep -q 'fold drift' '$R11/.git/lcars/lcars-feedback.jsonl'"
check "ledger overrides → .git/lcars/autopilot-overrides.jsonl" \
  "qgrep -q 'infra only' '$R11/.git/lcars/autopilot-overrides.jsonl'"
check "ledger decisions → .git/lcars/decisions.jsonl" \
  "qgrep -q 'added M6' '$R11/.git/lcars/decisions.jsonl'"
check "every ledger line is valid JSON with a ts" \
  "python3 -c 'import json,sys;[json.loads(l) and None for l in open(sys.argv[1])]' '$R11/.git/lcars/decisions.jsonl' && qgrep -q '\"ts\"' '$R11/.git/lcars/decisions.jsonl'"
check "ledger refuses an unknown kind"       "! ap '$R11' ledger nope '{}' >/dev/null 2>&1"
check "ledger refuses malformed JSON"        "! ap '$R11' ledger decisions 'not json' >/dev/null 2>&1"
check "ledgers live in .git/lcars, never in the working tree" \
  "[ -z \"\$(git -C '$R11' status --porcelain)\" ]"

: >"$CRONFILE"
echo '0 9 * * * echo someone-elses-job' >"$CRONFILE"
h11="$(ap "$R11" heartbeat install 2>&1)"; rch=$?
check "heartbeat install exits 0"            "[ $rch -eq 0 ]"
check "heartbeat uses crontab (not a harness tool)" "qgrep -q 'autopilot.sh' '$CRONFILE' || qgrep -q 'autopilot' '$CRONFILE'"
check "the cron line calls 'stalled'"        "qgrep -q 'stalled' '$CRONFILE'"
check "heartbeat kept the captain's other cron entries" \
  "qgrep -q 'someone-elses-job' '$CRONFILE'"
check "heartbeat owns exactly ONE line"      "[ \"\$(grep -c 'LCARS-AUTOPILOT' '$CRONFILE')\" = 1 ]"
ap "$R11" heartbeat install >/dev/null 2>&1
check "a second install is idempotent (still ONE line)" \
  "[ \"\$(grep -c 'LCARS-AUTOPILOT' '$CRONFILE')\" = 1 ]"
ap "$R11" heartbeat remove >/dev/null 2>&1
check "heartbeat remove GENUINELY removes the line" \
  "! qgrep -q 'LCARS-AUTOPILOT' '$CRONFILE'"
check "remove left the captain's other entries alone" \
  "qgrep -q 'someone-elses-job' '$CRONFILE'"
hs="$(ap "$R11" heartbeat status 2>&1)"
check "heartbeat status reports it is not installed" "printf '%s' \"\$hs\" | qgrep -qi 'not installed'"

# --- D5: removing our line when it is the ONLY line writes an EMPTY table ----
# `{ [ -n "$rest" ] && printf …; } | crontab -` made the empty case exit 1 under
# `set -o pipefail`, so `remove` DIED claiming "crontab refused the new table"
# on a removal that had in fact worked — while `status` then correctly reported
# not installed. The captain's own crontab is empty, so this fired every time.
: >"$CRONFILE"
ap "$R11" heartbeat install >/dev/null 2>&1
check "install works against an EMPTY crontab" "qgrep -q 'LCARS-AUTOPILOT' '$CRONFILE'"
rmo="$(ap "$R11" heartbeat remove 2>&1)"; rcrm=$?
check "remove exits 0 when ours is the ONLY line (empty table is a success)" \
  "[ $rcrm -eq 0 ]"
check "that removal does NOT claim crontab refused the table" \
  "! printf '%s' \"\$rmo\" | qgrep -qi 'refused'"
check "the line really is gone (the empty table was written)" \
  "! qgrep -q 'LCARS-AUTOPILOT' '$CRONFILE'"
check "remove reports the removal plainly" "printf '%s' \"\$rmo\" | qgrep -qi 'removed'"
hs1b="$(ap "$R11" heartbeat status 2>&1)"
check "status agrees with remove (not installed), so the two cannot disagree" \
  "printf '%s' \"\$hs1b\" | qgrep -qi 'not installed'"
# And the post-check still refuses to CLAIM a removal that did not happen: a
# crontab that keeps our line must make remove die, not print success.
cat >"$STUBS/crontab-sticky" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$CRONFILE"; exit 0; fi
cat >/dev/null
exit 0
SH
chmod +x "$STUBS/crontab-sticky"
printf '17 * * * * cd /x && bash /x/autopilot.sh stalled # LCARS-AUTOPILOT %s\n' "$R11" >"$CRONFILE"
rmo2="$(LCARS_AUTOPILOT_CWD="$R11" STUB_LOG="$STUB_LOG" \
        LCARS_CRONTAB_BIN="$STUBS/crontab-sticky" bash "$SCRIPT" heartbeat remove 2>&1 </dev/null)"; rcrm2=$?
check "remove still REFUSES to claim success while the line is present" \
  "[ $rcrm2 -ne 0 ] && printf '%s' \"\$rmo2\" | qgrep -qi 'still present'"
: >"$CRONFILE"

# ==========================================================================
# 9. Hygiene of the script itself (the §9 mistakes, as assertions)
# ==========================================================================
echo "-- 9. script hygiene --"
check "autopilot.sh exists and is executable" "[ -x '$SCRIPT' ]"
check "autopilot.sh parses under bash"        "bash -n '$SCRIPT'"
check "bash-3.2 clean: no associative arrays" "! qgrep -q 'declare -A' '$SCRIPT'"
check "bash-3.2 clean: no mapfile/readarray"  "! qgrep -qE 'mapfile|readarray' '$SCRIPT'"
check "bash-3.2 clean: no \${x^^}"            "! qgrep -qE '\\\$\\{[A-Za-z_]+\\^\\^?\\}' '$SCRIPT'"
check "no bare 'timeout' (absent on macOS; it silently no-ops)" \
  "! qgrep -qE '^[^#]*\\btimeout +[0-9]' '$SCRIPT'"
check "every background spawn closes stdin (S208)" \
  "[ \"\$(grep -cE '&\$' '$SCRIPT')\" -le \"\$(grep -c '</dev/null' '$SCRIPT')\" ]"
check "it does NOT re-implement stage order (no stage list in the driver)" \
  "! qgrep -qE 'research.*validate.*plan.*implement' '$SCRIPT'"
check "no 'gh ' calls — the forge is LCARS's business, not the driver's" \
  "! qgrep -qE '^[^#]*\\bgh +(pr|issue|api) ' '$SCRIPT'"
check "an unknown subcommand is refused with a usage line" \
  "out=\$(ap '$R11' no-such-verb 2>&1); [ \$? -ne 0 ] && printf '%s' \"\$out\" | qgrep -qi 'usage'"
check "no subcommand runs the FULL suite (tests/run.sh) itself" \
  "! qgrep -qE 'tests/run\\.sh' '$SCRIPT'"

# ==========================================================================
# 11. FIX ROUND 1 — the failure cap, the question ledger, no false parking,
#     and a waiter that respects the interrupt budget.
# ==========================================================================
echo "-- 11. failure cap / question ledger / no false parking / quiet waiter --"

# ap_drive_sync <repo> <run-script> <mission> — drive, then block until the
# waiter has recorded the exit. No clock: it watches the RECORDED pid clear,
# which is exactly what `stalled` watches.
ap_drive_sync() {
  local repo="$1" runs="$2" m="$3" rc i=0
  LCARS_AUTOPILOT_CWD="$repo" STUB_LOG="$STUB_LOG" \
  LCARS_RUN_SCRIPT="$runs" \
  LCARS_APPROVE_SCRIPT="$STUBS/approve.sh" LCARS_XO_SCRIPT="$STUBS/xo.sh" \
  LCARS_NOTIFY="$STUBS/notify.sh" LCARS_CRONTAB_BIN="$STUBS/crontab" \
  bash "$SCRIPT" drive "$m" >/dev/null 2>&1 </dev/null
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  while [ "$i" -lt 60 ]; do
    [ -n "$(jget "$repo/.git/lcars/autopilot.json" "d[\"drivers\"][\"$m\"][\"exitedAt\"]")" ] && break
    sleep 0.25; i=$((i + 1))
  done
  return 0
}

# --- D1: three failing drives must NOT produce a fourth `drive` -------------
# OBSERVED: a shimmed research stage exiting 1, three times, each time produced
# `NEXT: drive lcars-…`. `drivers.<m>.exitCode` was written and then only
# PRINTED — `next` never branched on it, and it was overwritten on each attempt
# so even the failure count was lost. Unattended, that spins until morning.
R12="$(new_repo)"
ap "$R12" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP12="$R12/.git/lcars/autopilot.json"
new_mission "$R12" lcars-fail-1 research
ap "$R12" record 'missions.M0.id' lcars-fail-1 >/dev/null 2>&1
stub "$STUBS/run-fail.sh" 1 'printf "the research stage blew up\n"'
: >"$STUB_LOG"

ap_drive_sync "$R12" "$STUBS/run-fail.sh" lcars-fail-1
check "a failing drive RECORDS a durable attempt counter" \
  "[ \"\$(jget '$AP12' 'd[\"drivers\"][\"lcars-fail-1\"][\"failures\"]')\" = 1 ]"
nx12a="$(ap "$R12" next 2>&1)"
check "after ONE failure a retry is still offered" \
  "printf '%s' \"\$nx12a\" | qgrep -q 'drive lcars-fail-1'"

ap_drive_sync "$R12" "$STUBS/run-fail.sh" lcars-fail-1
check "the counter ACCUMULATES across attempts (it is not re-derived)" \
  "[ \"\$(jget '$AP12' 'd[\"drivers\"][\"lcars-fail-1\"][\"failures\"]')\" = 2 ]"

ap_drive_sync "$R12" "$STUBS/run-fail.sh" lcars-fail-1
check "the third failure reaches the cap" \
  "[ \"\$(jget '$AP12' 'd[\"drivers\"][\"lcars-fail-1\"][\"failures\"]')\" = 3 ]"
nx12b="$(ap "$R12" next 2>&1)"
check "at the cap, next NO LONGER says drive (no infinite retry)" \
  "! printf '%s' \"\$nx12b\" | qgrep -q 'NEXT: drive lcars-fail-1'"
check "at the cap, next escalates to the captain instead" \
  "printf '%s' \"\$nx12b\" | qgrep -q 'NEXT: answer-pending'"
check "a question was WRITTEN for the capped mission" \
  "printf '%s' \"\$(jget '$AP12' 'd[\"pending\"]')\" | qgrep -q 'lcars-fail-1'"
check "the question is filed under the mode's own stop-and-ask category" \
  "printf '%s' \"\$(jget '$AP12' 'd[\"pending\"][\"why\"]')\" | qgrep -qi 'LCARS bug'"
check "the question carries the exit code it kept failing with" \
  "printf '%s' \"\$(jget '$AP12' 'd[\"pending\"]')\" | qgrep -q 'exit 1'"
# And the mechanical refusal: asking for a fourth drive is refused, not run.
: >"$STUB_LOG"
d12="$(ap_drive_sync "$R12" "$STUBS/run-fail.sh" lcars-fail-1 2>&1)"; rcd12=$?
check "drive REFUSES a fourth attempt past the cap" "[ $rcd12 -ne 0 ]"
check "that refusal never spawned run.sh again" \
  "! qgrep -q 'run-fail.sh drive --mission lcars-fail-1' '$STUB_LOG'"
# A drive that succeeds clears the count, so a flake does not poison a mission.
R12b="$(new_repo)"
ap "$R12b" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$R12b" lcars-flake-1 research
ap "$R12b" record 'missions.M0.id' lcars-flake-1 >/dev/null 2>&1
ap_drive_sync "$R12b" "$STUBS/run-fail.sh" lcars-flake-1
ap_drive_sync "$R12b" "$STUBS/run.sh" lcars-flake-1
check "a SUCCESSFUL drive clears the failure count (a flake is not fatal)" \
  "[ -z \"\$(jget '$R12b/.git/lcars/autopilot.json' 'd[\"drivers\"][\"lcars-flake-1\"][\"failures\"]')\" ]"

# --- D6: the waiter must not ping the captain on a ROUTINE stage stop -------
# `notify … drive-stopped` fired unconditionally on EVERY drive exit, exit 0
# included. AUTOPILOT.md § 9 promises exactly four things reach him.
check "a clean drive exit fires NO notification (interrupt budget)" \
  "! qgrep -q 'notify.sh lcars-flake-1' '$STUB_LOG'"
check "no 'drive-stopped' ping exists at all for a routine stop" \
  "! qgrep -q 'drive-stopped' '$STUB_LOG'"
check "the ONLY notify the driver can fire is the one that writes a question" \
  "[ \"\$(grep -c 'notify \"' '$SCRIPT')\" = 1 ]"

# --- D2: a second question must not silently delete the first ---------------
# `.pending` was a single object and write_pending did `ap_set pending {}`
# first, so M0's question was GONE from the durable record: the captain answers
# the one he can see and never learns the other existed. This is exactly the
# "record, don't infer" failure the round was built to prevent.
R13="$(new_repo)"
ap "$R13" init --spec "$TMPROOT/spec.md" --scope M0,M1 >/dev/null 2>&1
AP13="$R13/.git/lcars/autopilot.json"
new_mission "$R13" lcars-q-a verify
new_mission "$R13" lcars-bug-a implement bug lcars-q-a
new_mission "$R13" lcars-q-b verify
new_mission "$R13" lcars-bug-b implement bug lcars-q-b
ap "$R13" record 'missions.M0.id' lcars-q-a >/dev/null 2>&1
ap "$R13" record 'missions.M1.id' lcars-q-b >/dev/null 2>&1
ap "$R13" land lcars-q-a >/dev/null 2>&1
ap "$R13" land lcars-q-b >/dev/null 2>&1
check "the durable record holds BOTH open questions" \
  "[ \"\$(jget '$AP13' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 2 ]"
check "the FIRST question's text was not destroyed by the second write" \
  "printf '%s' \"\$(jget '$AP13' 'd[\"questions\"]')\" | qgrep -q 'lcars-bug-a'"
check "the second question is there too" \
  "printf '%s' \"\$(jget '$AP13' 'd[\"questions\"]')\" | qgrep -q 'lcars-bug-b'"
check "each question records which mission raised it" \
  "[ \"\$(jget '$AP13' 'sorted(q[\"mission\"] for q in d[\"questions\"].values())')\" = '[\"lcars-q-a\", \"lcars-q-b\"]' ]"
check "the single-question convenience surface still mirrors ONE question" \
  "[ -n \"\$(jget '$AP13' 'd[\"pending\"][\"what\"]')\" ]"
check "the mirror is the OLDEST open question (first asked, first answered)" \
  "printf '%s' \"\$(jget '$AP13' 'd[\"pending\"][\"mission\"]')\" | qgrep -q 'lcars-q-a'"
st13="$(ap "$R13" status 2>&1)"
check "status reports BOTH open questions, not one" \
  "printf '%s' \"\$st13\" | qgrep -q 'open questions for the captain: 2'"
check "status prints the text of both"  \
  "printf '%s' \"\$st13\" | qgrep -q 'lcars-bug-a' && printf '%s' \"\$st13\" | qgrep -q 'lcars-bug-b'"
check "status names each question's id so the captain's answer can be recorded" \
  "printf '%s' \"\$st13\" | qgrep -qE '\[q[0-9]+\]'"
# Answering one leaves the other open AND keeps the answered one on the record.
qid="$(jget "$AP13" 'sorted(d["questions"])[0]')"
ao="$(ap "$R13" answered "$qid" "go ahead" 2>&1)"; rcao=$?
check "answered <id> exits 0"                "[ $rcao -eq 0 ]"
check "answering one question leaves the other OPEN" \
  "[ \"\$(jget '$AP13' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 1 ]"
check "the answered question is still on the record (nothing destroyed)" \
  "[ -n \"\$(jget '$AP13' \"d['questions']['\$qid']['what']\")\" ]"
check "the captain's answer is recorded next to the question" \
  "printf '%s' \"\$(jget '$AP13' \"d['questions']['\$qid']['answer']\")\" | qgrep -q 'go ahead'"
check "the mirror moved on to the remaining open question" \
  "printf '%s' \"\$(jget '$AP13' 'd[\"pending\"][\"mission\"]')\" | qgrep -q 'lcars-q-b'"
ap "$R13" answered "$(jget "$AP13" 'sorted(d["questions"])[1]')" ok >/dev/null 2>&1
check "with every question answered the mirror is empty again" \
  "[ -z \"\$(jget '$AP13' 'd[\"pending\"][\"what\"]')\" ]"
check "answered refuses an id it does not know (it never invents one)" \
  "! ap '$R13' answered q999 >/dev/null 2>&1"

# --- N1: re-raising the SAME question must be a NO-OP (idempotency) ---------
# The D2 cure above made `questions` append-only. Appending with no dedupe then
# cost IDEMPOTENCY: running `land` three times on a mission still blocked by
# the same bug child appended q3, q4 and q5 BYTE-IDENTICAL, and because
# write_pending holds the script's ONE `notify` call site, each duplicate fired
# its own push. Three pings at the captain's phone for one problem is the
# interrupt-budget violation D6 exists to prevent (AUTOPILOT.md § 9: "exactly
# four things reach him"), and downstream `answered <mission>` closes only the
# oldest, so he answers the identical sentence over and over.
# The key is the PAIR (mission, what), never the mission alone.
R15="$(new_repo)"
ap "$R15" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP15="$R15/.git/lcars/autopilot.json"
new_mission "$R15" lcars-dupe-1 verify
new_mission "$R15" lcars-dupebug-1 implement bug lcars-dupe-1
ap "$R15" record 'missions.M0.id' lcars-dupe-1 >/dev/null 2>&1

ap "$R15" land lcars-dupe-1 >/dev/null 2>&1
raised1="$(jget "$AP15" 'd["questions"]["q1"]["raisedAt"]')"
check "the first raise records one question" \
  "[ \"\$(jget '$AP15' 'len(d[\"questions\"])')\" = 1 ]"
check "the first raise pings the captain exactly once" \
  "[ \"\$(grep -c 'notify.sh lcars-dupe-1 ' '$STUB_LOG')\" = 1 ]"

l15b="$(ap "$R15" land lcars-dupe-1 2>&1)"; rc15b=$?
l15c="$(ap "$R15" land lcars-dupe-1 2>&1)"; rc15c=$?
check "re-raising the SAME (mission, what) adds NO new question" \
  "[ \"\$(jget '$AP15' 'len(d[\"questions\"])')\" = 1 ]"
check "exactly ONE question is open after three identical raises" \
  "[ \"\$(jget '$AP15' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 1 ]"
check "a duplicate raise sends NO second notification (interrupt budget)" \
  "[ \"\$(grep -c 'notify.sh lcars-dupe-1 ' '$STUB_LOG')\" = 1 ]"
check "the open question keeps its ORIGINAL raisedAt (it is not refreshed)" \
  "[ \"\$(jget '$AP15' 'd[\"questions\"][\"q1\"][\"raisedAt\"]')\" = '$raised1' ]"
check "the duplicate raise says the question is already open" \
  "printf '%s' \"\$l15c\" | qgrep -q 'ALREADY OPEN'"
check "a duplicate raise still names the id the captain answers" \
  "printf '%s' \"\$l15c\" | qgrep -q 'answered q1'"
check "the de-duplicated land STILL refuses to land (exit 10, no hand-merge)" \
  "[ $rc15b -eq 10 ] && [ $rc15c -eq 10 ]"
check "the mirror still points at that one open question" \
  "printf '%s' \"\$(jget '$AP15' 'd[\"pending\"][\"id\"]')\" | qgrep -q 'q1'"

# An ANSWERED question must NOT suppress a new one: a problem that recurs after
# the captain cleared it is a real new event and earns its own ping.
ap "$R15" answered q1 "cleared it" >/dev/null 2>&1
check "answered closed the only open question" \
  "[ -z \"\$(jget '$AP15' 'd[\"pending\"].get(\"what\")')\" ]"
ap "$R15" land lcars-dupe-1 >/dev/null 2>&1
check "the same problem RECURRING after an answer raises a NEW question" \
  "[ \"\$(jget '$AP15' 'len(d[\"questions\"])')\" = 2 ]"
check "the recurrence is open (the answered one stays closed)" \
  "[ \"\$(jget '$AP15' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 1 ]"
check "the recurrence pings the captain again (a real new event)" \
  "[ \"\$(grep -c 'notify.sh lcars-dupe-1 ' '$STUB_LOG')\" = 2 ]"
check "the answered question still carries its answer (nothing destroyed)" \
  "printf '%s' \"\$(jget '$AP15' 'd[\"questions\"][\"q1\"][\"answer\"]')\" | qgrep -q 'cleared it'"
check "answered still refuses an id it does not know, dedupe or not" \
  "! ap '$R15' answered q999 >/dev/null 2>&1"
check "answered still refuses to answer the SAME question twice" \
  "! ap '$R15' answered q1 'again' >/dev/null 2>&1"

# --- N1b: a cap question and a land question on ONE mission are TWO problems -
# The dedupe keys on the PAIR. Keying on the mission alone would collapse the
# drive-failure cap (D1) and the land refusal into one, which is a worse bug
# than the duplicates: the captain would never learn one of them exists.
R16="$(new_repo)"
ap "$R16" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP16="$R16/.git/lcars/autopilot.json"
new_mission "$R16" lcars-both-1 verify
new_mission "$R16" lcars-bothbug-1 implement bug lcars-both-1
ap "$R16" record 'missions.M0.id' lcars-both-1 >/dev/null 2>&1
ap_drive_sync "$R16" "$STUBS/run-fail.sh" lcars-both-1
ap_drive_sync "$R16" "$STUBS/run-fail.sh" lcars-both-1
ap_drive_sync "$R16" "$STUBS/run-fail.sh" lcars-both-1
check "the drive-failure cap still escalates to a question" \
  "[ \"\$(jget '$AP16' 'len(d[\"questions\"])')\" = 1 ]"
ap "$R16" land lcars-both-1 >/dev/null 2>&1
check "a DIFFERENT question on the SAME mission is a SECOND question" \
  "[ \"\$(jget '$AP16' 'len(d[\"questions\"])')\" = 2 ]"
check "both of that one mission's questions are OPEN" \
  "[ \"\$(jget '$AP16' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 2 ]"
check "both are filed against the same mission" \
  "[ \"\$(jget '$AP16' 'sorted(set(q[\"mission\"] for q in d[\"questions\"].values()))')\" = '[\"lcars-both-1\"]' ]"
check "the cap question survived the land question" \
  "printf '%s' \"\$(jget '$AP16' 'd[\"questions\"]')\" | qgrep -q 'failed 3 drives'"
check "the land question is there too" \
  "printf '%s' \"\$(jget '$AP16' 'd[\"questions\"]')\" | qgrep -q 'cannot be landed'"
check "two genuinely different problems ping twice, not once" \
  "[ \"\$(grep -c 'notify.sh lcars-both-1 ' '$STUB_LOG')\" = 2 ]"
check "the mirror is still the OLDEST open question (the cap one)" \
  "printf '%s' \"\$(jget '$AP16' 'd[\"pending\"][\"what\"]')\" | qgrep -q 'failed 3 drives'"
st16="$(ap "$R16" status 2>&1)"
check "status reports BOTH of that mission's open questions" \
  "printf '%s' \"\$st16\" | qgrep -q 'open questions for the captain: 2'"

# --- N1c: the same `what` on a DIFFERENT mission is its own question --------
# Seeded directly, because the land text embeds the mission id: this is the
# only way to put a BYTE-IDENTICAL `what` on another mission.
R17="$(new_repo)"
ap "$R17" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP17="$R17/.git/lcars/autopilot.json"
new_mission "$R17" lcars-same-1 verify
new_mission "$R17" lcars-samebug-1 implement bug lcars-same-1
ap "$R17" record 'missions.M0.id' lcars-same-1 >/dev/null 2>&1
SAME_WHAT='lcars-same-1 cannot be landed: its logged bug Mission(s) lcars-samebug-1 are still open.'
ap "$R17" record 'questions.q1' \
  "{\"id\":\"q1\",\"mission\":\"lcars-other-9\",\"what\":\"$SAME_WHAT\",\"why\":\"seeded\",\"command\":\"-\",\"rollback\":\"-\",\"raisedAt\":1}" \
  >/dev/null 2>&1
check "the seeded question is the exact text land will raise" \
  "[ \"\$(jget '$AP17' 'd[\"questions\"][\"q1\"][\"what\"]')\" = \"\$SAME_WHAT\" ]"
ap "$R17" land lcars-same-1 >/dev/null 2>&1
check "the SAME what on a DIFFERENT mission raises its own question" \
  "[ \"\$(jget '$AP17' 'len(d[\"questions\"])')\" = 2 ]"
check "the new question is filed against the mission that raised it" \
  "[ \"\$(jget '$AP17' 'sorted(set(q[\"mission\"] for q in d[\"questions\"].values()))')\" = '[\"lcars-other-9\", \"lcars-same-1\"]' ]"
check "a different mission's identical question still pings" \
  "[ \"\$(grep -c 'notify.sh lcars-same-1 ' '$STUB_LOG')\" = 1 ]"

# A HAND-WRITTEN `.pending` is still adopted as a real question (D2), and the
# dedupe must not swallow it.
R18="$(new_repo)"
ap "$R18" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP18="$R18/.git/lcars/autopilot.json"
new_mission "$R18" lcars-hand-1 verify
new_mission "$R18" lcars-handbug-1 implement bug lcars-hand-1
ap "$R18" record 'missions.M0.id' lcars-hand-1 >/dev/null 2>&1
ap "$R18" record 'pending' \
  '{"mission":"lcars-hand-1","what":"the model wrote this one by hand","why":"h","command":"-","rollback":"-","raisedAt":1}' \
  >/dev/null 2>&1
ap "$R18" land lcars-hand-1 >/dev/null 2>&1
check "a hand-written .pending is still carried into the ledger" \
  "printf '%s' \"\$(jget '$AP18' 'd[\"questions\"]')\" | qgrep -q 'by hand'"
check "and the land question is recorded beside it" \
  "[ \"\$(jget '$AP18' 'len(d[\"questions\"])')\" = 2 ]"

# --- N1d: the ADOPTION path must use the SAME dedupe key as the RAISE path ---
# `write_pending` had TWO keys. The raise path dedupes on (mission, what) gated
# on `not answeredAt` — correct. The ADOPTION path (carrying a hand-written
# `.pending`, which AUTOPILOT.md § 9 still tells the model to write, into the
# ledger) matched on `what` ALONE, across ANSWERED questions too. So: answer a
# hand-written question, have the same problem recur, hand-write it again — and
# it is silently dropped. Not in `status`, no notification, no `questions`
# entry, while `.pending` still literally holds the sentence until the mirror
# overwrites it. A question nobody will ever see.
R19="$(new_repo)"
ap "$R19" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP19="$R19/.git/lcars/autopilot.json"
new_mission "$R19" lcars-adopt-1 verify
new_mission "$R19" lcars-adoptbug-1 implement bug lcars-adopt-1
ap "$R19" record 'missions.M0.id' lcars-adopt-1 >/dev/null 2>&1
HANDQ='{"mission":"lcars-adopt-1","what":"the deploy host refused the key again","why":"h","command":"-","rollback":"-","raisedAt":1}'
: >"$STUB_LOG"
ap "$R19" record pending "$HANDQ" >/dev/null 2>&1
ap "$R19" land lcars-adopt-1 >/dev/null 2>&1
check "a hand-written question is adopted alongside the raised one" \
  "[ \"\$(jget '$AP19' 'len(d[\"questions\"])')\" = 2 ]"
check "the adopted question kept its text" \
  "printf '%s' \"\$(jget '$AP19' 'd[\"questions\"]')\" | qgrep -q 'refused the key'"
# A STILL-OPEN duplicate through the adoption path is still deduped.
ap "$R19" record pending "$HANDQ" >/dev/null 2>&1
ap "$R19" land lcars-adopt-1 >/dev/null 2>&1
check "re-adopting a STILL-OPEN hand-written question adds nothing" \
  "[ \"\$(jget '$AP19' 'len(d[\"questions\"])')\" = 2 ]"
check "the still-open duplicate sends no second ping" \
  "[ \"\$(grep -c 'notify.sh lcars-adopt-1 ' '$STUB_LOG')\" = 1 ]"
# Now answer everything, and have the SAME problem recur.
for q19 in $(jget "$AP19" '" ".join(sorted(d["questions"]))'); do
  ap "$R19" answered "$q19" "cleared" >/dev/null 2>&1
done
check "every question is answered before the recurrence" \
  "[ \"\$(jget '$AP19' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 0 ]"
ap "$R19" record pending "$HANDQ" >/dev/null 2>&1
ap "$R19" land lcars-adopt-1 >/dev/null 2>&1
check "a RECURRENCE through the adoption path raises a NEW question" \
  "[ \"\$(jget '$AP19' 'len(d[\"questions\"])')\" = 4 ]"
check "the recurrence is OPEN (it is not swallowed by the answered one)" \
  "[ \"\$(jget '$AP19' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\") and \"refused the key\" in q[\"what\"]])')\" = 1 ]"
check "the recurrence pings the captain (a real new event)" \
  "[ \"\$(grep -c 'notify.sh lcars-adopt-1 ' '$STUB_LOG')\" = 2 ]"
st19="$(ap "$R19" status 2>&1)"
check "status SHOWS the recurrence (the bug made it invisible)" \
  "printf '%s' \"\$st19\" | qgrep -q 'refused the key'"
check "the answered original is still on the record with its answer" \
  "[ \"\$(jget '$AP19' 'len([q for q in d[\"questions\"].values() if q.get(\"answeredAt\")])')\" = 2 ]"
# The SAME text raised against a DIFFERENT mission must also survive adoption.
ap "$R19" record pending \
  '{"mission":"lcars-elsewhere-9","what":"the deploy host refused the key again","why":"h","command":"-","rollback":"-","raisedAt":2}' \
  >/dev/null 2>&1
ap "$R19" land lcars-adopt-1 >/dev/null 2>&1
check "the same text on a DIFFERENT mission is adopted as its own question" \
  "[ \"\$(jget '$AP19' 'len(d[\"questions\"])')\" = 5 ]"

# A hand-written `.pending` with NO mission field must still behave sensibly:
# adopted once, and not duplicated on the next raise.
R19B="$(new_repo)"
ap "$R19B" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP19B="$R19B/.git/lcars/autopilot.json"
new_mission "$R19B" lcars-nomiss-1 verify
new_mission "$R19B" lcars-nomissbug-1 implement bug lcars-nomiss-1
ap "$R19B" record pending \
  '{"what":"a hand-written question with no mission on it","why":"h","command":"-","rollback":"-"}' \
  >/dev/null 2>&1
ap "$R19B" land lcars-nomiss-1 >/dev/null 2>&1
check "a mission-less hand-written question is adopted" \
  "[ \"\$(jget '$AP19B' 'len(d[\"questions\"])')\" = 2 ]"
ap "$R19B" land lcars-nomiss-1 >/dev/null 2>&1
check "and it is NOT adopted twice" \
  "[ \"\$(jget '$AP19B' 'len(d[\"questions\"])')\" = 2 ]"

# --- N1f: a hand-written `.pending` must be shown ALONGSIDE the ledger's -----
# `open_questions` fell back to `.pending` only `if not qs` — i.e. ONLY when the
# ledger had nothing open. So the moment ONE ordinary question was open, a
# hand-written one (AUTOPILOT.md § 9 tells the model to write exactly that shape
# for a product call, a scope change or a standing-rule conflict — the questions
# that MOST need the captain) was MASKED: zero rows in `status`, zero rows in
# `next`, and the header said "open questions for the captain: 1" while two were
# open. It masked precisely when the autopilot was busiest. This display
# behaviour was on the tester's list of things not covered by either suite, and
# it then regressed silently under 311 green checks. These are the checks that
# would have caught it.
R19C="$(new_repo)"
ap "$R19C" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP19C="$R19C/.git/lcars/autopilot.json"
new_mission "$R19C" lcars-mask-1 verify
new_mission "$R19C" lcars-maskbug-1 implement bug lcars-mask-1
ap "$R19C" record 'missions.M0.id' lcars-mask-1 >/dev/null 2>&1
# One ORDINARY question first: `land` refuses on the open bug child and raises
# q1, which also makes `.pending` a mirror of it.
ap "$R19C" land lcars-mask-1 >/dev/null 2>&1
check "the ledger holds the one raised question" \
  "[ \"\$(jget '$AP19C' 'len(d[\"questions\"])')\" = 1 ]"
# Now the model hand-writes a SECOND question over the mirror.
HANDM='{"mission":"lcars-mask-1","what":"HAND: ship the CLI without the page, or hold both?","why":"a product call","command":"-","rollback":"-","raisedAt":9}'
ap "$R19C" record pending "$HANDM" >/dev/null 2>&1
st19c="$(ap "$R19C" status 2>&1)"
check "status LISTS the hand-written question even though another is open" \
  "printf '%s' \"\$st19c\" | qgrep -q 'HAND: ship the CLI'"
check "status still lists the LEDGER question beside it" \
  "printf '%s' \"\$st19c\" | qgrep -q 'lcars-maskbug-1'"
check "the count is the TRUE total (2 open), not 1" \
  "printf '%s' \"\$st19c\" | qgrep -q 'open questions for the captain: 2'"
# S233 CHANGED THIS ONE ON PURPOSE. It used to assert the row carried the
# literal `[pending]` label — the visible SYMPTOM of `.pending` doubling as
# STORAGE for a hand-written question. That is the ambiguity the design change
# ends: the orphan is ADOPTED on first sight, so the row carries a REAL id —
# which is also the id `status` tells him to answer by.
check "the hand-written row is adopted on sight and carries a REAL id" \
  "printf '%s' \"\$st19c\" | qgrep -qE '^    \[q[0-9]+\] lcars-mask-1: HAND:'"
check "no row is labelled with the literal 'pending' id any more" \
  "! printf '%s' \"\$st19c\" | qgrep -qF '[pending]'"
# THE COUNT MUST MATCH THE ROWS IT PRINTS — the header said 1 and printed 1 row
# while the file held 2 open questions, so neither number told the truth.
nrows19c="$(printf '%s\n' "$st19c" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "the printed count equals the number of question rows" \
  "[ \"$nrows19c\" = 2 ]"
nx19c="$(ap "$R19C" next --all 2>&1)"
check "next SURFACES the hand-written question while another is open" \
  "printf '%s' \"\$nx19c\" | qgrep -q 'HAND: ship the CLI'"
check "next still surfaces the ledger question too" \
  "printf '%s' \"\$nx19c\" | qgrep -q 'lcars-maskbug-1'"
# ADOPTED ONCE, LISTED ONCE. `land` carries the hand-written `.pending` into the
# ledger and re-derives the mirror from it; the adopted copy and the raw
# `.pending` are the SAME question and must appear exactly once. Deduped on
# (mission, what), the key the rest of the file uses.
ap "$R19C" land lcars-mask-1 >/dev/null 2>&1
check "land adopted the hand-written question into the ledger" \
  "[ \"\$(jget '$AP19C' 'len(d[\"questions\"])')\" = 2 ]"
st19d="$(ap "$R19C" status 2>&1)"
# Counted over the QUESTION ROWS only: `status` ends by printing `next`, whose
# WHY line quotes the top question's text too, so a naive grep over the whole
# screen reads 2 for one row.
hand19d="$(printf '%s\n' "$st19d" | sed -n 's/^    \[[^]]*\] .*HAND: ship the CLI.*/x/p' | wc -l | tr -d ' ')"
check "an ALREADY-ADOPTED pending is NOT listed twice" \
  "[ \"$hand19d\" = 1 ]"
check "and the count is still the true total (2)" \
  "printf '%s' \"\$st19d\" | qgrep -q 'open questions for the captain: 2'"
nrows19d="$(printf '%s\n' "$st19d" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "the count still equals the rows after adoption" \
  "[ \"$nrows19d\" = 2 ]"

# THE SEAM THIS OPENS. A hand-written question is now visible in a state where
# it never appeared before, and `status` tells the captain to answer rows by the
# id it printed. A visible row that cannot be answered by its own printed id
# would be a new defect, so pin it: the adopted row must close by the id on
# screen and leave the ledger question open.
R19F="$(new_repo)"
ap "$R19F" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP19F="$R19F/.git/lcars/autopilot.json"
new_mission "$R19F" lcars-seam-1 verify
new_mission "$R19F" lcars-seambug-1 implement bug lcars-seam-1
ap "$R19F" record 'missions.M0.id' lcars-seam-1 >/dev/null 2>&1
ap "$R19F" land lcars-seam-1 >/dev/null 2>&1
ap "$R19F" record pending \
  '{"mission":"lcars-seam-1","what":"HAND: a standing-rule conflict","why":"h","command":"-","rollback":"-","raisedAt":9}' \
  >/dev/null 2>&1
# S233: the row now prints a real id, and THAT is what closes it. (`answered
# pending` still works, as the POINTER the mirror is — pinned separately below.)
st19f0="$(ap "$R19F" status 2>&1)"
check "the orphan is adopted and status prints its real id" \
  "printf '%s' \"\$st19f0\" | qgrep -qE '^    \[q[0-9]+\] lcars-seam-1: HAND: a standing-rule'"
ap "$R19F" answered q2 "go ahead" >/dev/null 2>&1
check "the adopted row is answerable by the id status printed" \
  "[ \"\$(jget '$AP19F' 'len([q for q in d[\"questions\"].values() if q.get(\"answeredAt\") and \"standing-rule\" in q[\"what\"]])')\" = 1 ]"
check "answering it left the ledger question OPEN" \
  "[ \"\$(jget '$AP19F' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 1 ]"
st19f="$(ap "$R19F" status 2>&1)"
check "and the answered hand-written question is off the screen" \
  "! printf '%s' \"\$st19f\" | qgrep -q 'standing-rule'"
check "while the count drops back to 1" \
  "printf '%s' \"\$st19f\" | qgrep -q 'open questions for the captain: 1'"

# REGRESSION GUARD on the case that already worked: a hand-written `.pending`
# with NOTHING else open is still the one question shown — now under the real
# id adoption gave it — and `next` still points at it.
R19E="$(new_repo)"
ap "$R19E" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$R19E" lcars-solo-1 verify
ap "$R19E" record 'missions.M0.id' lcars-solo-1 >/dev/null 2>&1
ap "$R19E" record pending \
  '{"mission":"lcars-solo-1","what":"HAND: the only question open","why":"h","command":"-","rollback":"-"}' \
  >/dev/null 2>&1
st19e="$(ap "$R19E" status 2>&1)"
check "a lone hand-written question is still shown" \
  "printf '%s' \"\$st19e\" | qgrep -q 'HAND: the only question open'"
check "a lone hand-written question still counts as exactly 1" \
  "printf '%s' \"\$st19e\" | qgrep -q 'open questions for the captain: 1'"
check "a lone hand-written question carries the REAL id it was adopted under" \
  "printf '%s' \"\$st19e\" | qgrep -qE '^    \[q[0-9]+\] lcars-solo-1:'"
nx19e="$(ap "$R19E" next 2>&1)"
check "next still points at a lone hand-written question" \
  "printf '%s' \"\$nx19e\" | qgrep -q 'answer-pending'"
check "and names it" \
  "printf '%s' \"\$nx19e\" | qgrep -q 'HAND: the only question open'"

# ==========================================================================
# S233 — ONE HOME FOR A QUESTION: `ask` is the verb, `.pending` is a MIRROR
# ==========================================================================
# WHY THIS SECTION EXISTS. `.pending` was a DERIVED MIRROR in some code paths
# and the SOLE STORAGE in others, and nothing declared which. That single
# ambiguity produced FIVE separate defects over five rounds of testing, each one
# a different function disagreeing about it:
#   1. a second question deleted the first (the mirror was overwritten);
#   2. duplicates piled up, each one pinging the captain;
#   3. a recurrence was swallowed because two dedupe keys disagreed;
#   4. a hand-written question was masked whenever any other was open;
#   5. answering ANY question DESTROYED an un-adopted hand-written one — two
#      rows on screen, `answered q3`, and the other was gone from `pending`,
#      absent from `questions`, with the mode reporting "No questions are open
#      for the captain now" and the run continuing without him.
# 332 checks were green over all of that, because each tested the path its
# author had in mind. So the cure is not a sixth reader that copes with an
# orphan: the hand-written question gets its OWN VERB (`ask`) and lands in
# `questions` immediately with a real id, and `.pending` becomes purely
# derived. An orphan from an older run is adopted the MOMENT it is seen.
#
# A MEASUREMENT NOTE for everything below: `status` ends by printing `next`,
# whose `WHY:` line quotes the top question's text, so a grep for the text reads
# 2 for ONE row. Count QUESTION ROWS (`^    [id] `), never the text.
echo "-- S233. ask: one home for a question --"

# --- S233a: `ask` creates a durable question with an id ---------------------
R20="$(new_repo)"
ap "$R20" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP20="$R20/.git/lcars/autopilot.json"
new_mission "$R20" lcars-ask-1 implement
ap "$R20" record 'missions.M0.id' lcars-ask-1 >/dev/null 2>&1
: >"$STUB_LOG"
out20="$(ap "$R20" ask "ship the CLI without the page, or hold both?" \
          --mission lcars-ask-1 --why "a product call only he can make" \
          --command "-" --rollback "-" 2>&1)"; rc20=$?
check "ask exits 0 (a question is not a milestone stop)" "[ $rc20 -eq 0 ]"
check "ask lands the question in the LEDGER immediately" \
  "[ \"\$(jget '$AP20' 'len(d[\"questions\"])')\" = 1 ]"
check "ask gives it a REAL id, never the literal 'pending'" \
  "[ \"\$(jget '$AP20' 'sorted(d[\"questions\"])')\" = '[\"q1\"]' ]"
check "ask records the same field set write_pending does" \
  "[ \"\$(jget '$AP20' 'sorted(k for k in d[\"questions\"][\"q1\"] if d[\"questions\"][\"q1\"][k])')\" = '[\"command\", \"id\", \"mission\", \"raisedAt\", \"rollback\", \"what\", \"why\"]' ]"
check "ask prints the id his answer is recorded against" \
  "printf '%s' \"\$out20\" | qgrep -q 'answered q1'"
check "ask pings the captain EXACTLY once" \
  "[ \"\$(grep -c 'notify.sh lcars-ask-1 ' '$STUB_LOG')\" = 1 ]"
st20="$(ap "$R20" status 2>&1)"
check "status lists the asked question under its id" \
  "printf '%s' \"\$st20\" | qgrep -qE '^    \[q1\] lcars-ask-1: ship the CLI'"
check "status counts it" \
  "printf '%s' \"\$st20\" | qgrep -q 'open questions for the captain: 1'"
nrows20="$(printf '%s\n' "$st20" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "status's count equals the rows it prints" "[ \"$nrows20\" = 1 ]"
nx20="$(ap "$R20" next 2>&1)"
check "next surfaces the asked question" \
  "printf '%s' \"\$nx20\" | qgrep -q 'NEXT: answer-pending'"
check "and quotes it with its id" \
  "printf '%s' \"\$nx20\" | qgrep -q '\[q1\]: ship the CLI'"
check "pending MIRRORS the asked question (same id) — it does not own it" \
  "[ \"\$(jget '$AP20' 'd[\"pending\"][\"id\"]')\" = q1 ]"
check "ask with no question text REFUSES" \
  "! ap '$R20' ask --mission lcars-ask-1 >/dev/null 2>&1"
check "ask with no --mission REFUSES (a question must block only ITS milestone)" \
  "! ap '$R20' ask 'a question with nowhere to land' >/dev/null 2>&1"
check "ask rejects an unknown flag rather than silently dropping it" \
  "! ap '$R20' ask 'x' --mission lcars-ask-1 --urgent >/dev/null 2>&1"

# --- S233b: `ask` dedupes EXACTLY as the raise path does --------------------
: >"$STUB_LOG"
ap "$R20" ask "ship the CLI without the page, or hold both?" \
  --mission lcars-ask-1 --why "a product call only he can make" >/dev/null 2>&1
check "ask DEDUPES on (mission, what) against the OPEN set" \
  "[ \"\$(jget '$AP20' 'len(d[\"questions\"])')\" = 1 ]"
check "the duplicate ask sends NO second ping (interrupt budget)" \
  "[ \"\$(grep -c 'notify.sh lcars-ask-1 ' '$STUB_LOG')\" = 0 ]"
a20d="$(ap "$R20" ask "ship the CLI without the page, or hold both?" --mission lcars-ask-1 2>&1)"
check "the duplicate ask SAYS the question is already open" \
  "printf '%s' \"\$a20d\" | qgrep -q 'ALREADY OPEN'"
ap "$R20" ask "ship the CLI without the page, or hold both?" --mission lcars-ask-9 >/dev/null 2>&1
check "the SAME text on a DIFFERENT mission is its own question" \
  "[ \"\$(jget '$AP20' 'len(d[\"questions\"])')\" = 2 ]"
ap "$R20" answered q1 "ship the CLI" >/dev/null 2>&1
: >"$STUB_LOG"
ap "$R20" ask "ship the CLI without the page, or hold both?" --mission lcars-ask-1 >/dev/null 2>&1
check "a RECURRENCE after the answer raises a genuinely NEW question" \
  "[ \"\$(jget '$AP20' 'len(d[\"questions\"])')\" = 3 ]"
check "the recurrence is OPEN (the answered one does not swallow it)" \
  "[ \"\$(jget '$AP20' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\") and q.get(\"mission\")==\"lcars-ask-1\"])')\" = 1 ]"
check "and the recurrence pings him again (a real new event)" \
  "[ \"\$(grep -c 'notify.sh lcars-ask-1 ' '$STUB_LOG')\" = 1 ]"

# --- S233c: THE DEFECT THAT STOPPED THE SESSION ----------------------------
# Two questions open — one RAISED by `land`, one from `ask`. Answering EITHER
# one by its id must leave the OTHER alive, listed, and still reaching him.
# Before the change, answering the raised one re-derived the mirror over the
# hand-written one and it ceased to exist. Both orders are driven, because the
# defect only showed in one of them.
for order in raised-first asked-first; do
  RD="$(new_repo)"
  ap "$RD" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
  APD="$RD/.git/lcars/autopilot.json"
  new_mission "$RD" lcars-two-1 verify
  new_mission "$RD" lcars-twobug-1 implement bug lcars-two-1
  ap "$RD" record 'missions.M0.id' lcars-two-1 >/dev/null 2>&1
  ap "$RD" land lcars-two-1 >/dev/null 2>&1          # q1, raised by the refusal
  ap "$RD" ask "HAND: ship M1 without the page, or hold both?" \
    --mission lcars-two-1 --why "a product call" >/dev/null 2>&1   # q2
  check "[$order] two questions are open to start with" \
    "[ \"\$(jget '$APD' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 2 ]"
  if [ "$order" = raised-first ]; then
    kill_id=q1; live_id=q2; live_txt='HAND: ship M1'
  else
    kill_id=q2; live_id=q1; live_txt='lcars-twobug-1'
  fi
  outd="$(ap "$RD" answered "$kill_id" "his answer" 2>&1)"
  check "[$order] answering $kill_id leaves EXACTLY one question open" \
    "[ \"\$(jget '$APD' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 1 ]"
  check "[$order] the survivor is $live_id, still in the ledger with its text" \
    "[ -n \"\$(jget '$APD' \"d['questions']['$live_id'].get('what')\")\" ] && [ -z \"\$(jget '$APD' \"d['questions']['$live_id'].get('answeredAt')\")\" ]"
  check "[$order] answered NAMES the one still open (never 'no questions are open')" \
    "printf '%s' \"\$outd\" | qgrep -q 'Still open: $live_id'"
  check "[$order] it does NOT claim the captain is clear" \
    "! printf '%s' \"\$outd\" | qgrep -qi 'No questions are open'"
  std="$(ap "$RD" status 2>&1)"
  check "[$order] status still LISTS the survivor" \
    "printf '%s' \"\$std\" | qgrep -qE '^    \[$live_id\] lcars-two-1: .*$live_txt'"
  check "[$order] and still counts exactly 1" \
    "printf '%s' \"\$std\" | qgrep -q 'open questions for the captain: 1'"
  nrowsd="$(printf '%s\n' "$std" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
  check "[$order] the count equals the rows it prints" "[ \"$nrowsd\" = 1 ]"
  nxd="$(ap "$RD" next 2>&1)"
  check "[$order] next still routes him to the survivor (it reaches him)" \
    "printf '%s' \"\$nxd\" | qgrep -q 'NEXT: answer-pending' && printf '%s' \"\$nxd\" | qgrep -q '\[$live_id\]'"
  check "[$order] the mirror moved ONTO the survivor, it did not blank" \
    "[ \"\$(jget '$APD' 'd[\"pending\"][\"id\"]')\" = $live_id ]"
  # ...and the survivor still closes normally afterwards.
  ap "$RD" answered "$live_id" "and his second answer" >/dev/null 2>&1
  check "[$order] the survivor then closes and the mirror empties" \
    "[ \"\$(jget '$APD' 'd[\"pending\"]')\" = '{}' ] && [ \"\$(jget '$APD' 'len([q for q in d[\"questions\"].values() if q.get(\"answeredAt\")])')\" = 2 ]"
done

# --- S233d: an orphan `.pending` from an OLDER run is adopted on FIRST SIGHT
# Older runs and the pre-S233 playbook both produce them, so the field must
# still be HONOURED — but as a one-way repair at the moment it is seen, not as
# a question that lives there and waits for something else to be raised.
R23="$(new_repo)"
ap "$R23" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP23="$R23/.git/lcars/autopilot.json"
new_mission "$R23" lcars-legacy-1 verify
ap "$R23" record 'missions.M0.id' lcars-legacy-1 >/dev/null 2>&1
ap "$R23" record pending \
  '{"mission":"lcars-legacy-1","what":"LEGACY: the deploy host refused the key","why":"a standing-rule conflict","command":"-","rollback":"-","raisedAt":1}' \
  >/dev/null 2>&1
check "the orphan is on disk with NO ledger entry (the state older runs leave)" \
  "[ \"\$(jget '$AP23' 'len(d[\"questions\"])')\" = 0 ]"
st23="$(ap "$R23" status 2>&1)"
check "it is ADOPTED on FIRST SIGHT, not lazily when something else is raised" \
  "[ \"\$(jget '$AP23' 'len(d[\"questions\"])')\" = 1 ]"
check "the adopted question KEEPS ITS TEXT verbatim" \
  "[ \"\$(jget '$AP23' 'd[\"questions\"][\"q1\"][\"what\"]')\" = 'LEGACY: the deploy host refused the key' ]"
check "and its why/command/rollback came across too" \
  "[ \"\$(jget '$AP23' 'd[\"questions\"][\"q1\"][\"why\"]')\" = 'a standing-rule conflict' ]"
check "it got a REAL id" "[ \"\$(jget '$AP23' 'sorted(d[\"questions\"])')\" = '[\"q1\"]' ]"
check "status lists it under that real id" \
  "printf '%s' \"\$st23\" | qgrep -qE '^    \[q1\] lcars-legacy-1: LEGACY:'"
nrows23="$(printf '%s\n' "$st23" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "one row, counted once" \
  "[ \"$nrows23\" = 1 ] && printf '%s' \"\$st23\" | qgrep -q 'open questions for the captain: 1'"
ap "$R23" status >/dev/null 2>&1
ap "$R23" next --all >/dev/null 2>&1
ap "$R23" record lastForecast "anything" >/dev/null 2>&1
check "adoption is IDEMPOTENT across repeated reads (never DUPLICATED)" \
  "[ \"\$(jget '$AP23' 'len(d[\"questions\"])')\" = 1 ]"
check "pending is now purely the MIRROR of the adopted copy" \
  "[ \"\$(jget '$AP23' 'd[\"pending\"][\"id\"]')\" = q1 ]"
ap "$R23" answered q1 "key rotated" >/dev/null 2>&1
check "answering the adopted question empties the mirror" \
  "[ \"\$(jget '$AP23' 'd[\"pending\"]')\" = '{}' ]"
ap "$R23" status >/dev/null 2>&1
ap "$R23" next >/dev/null 2>&1
st23b="$(ap "$R23" status 2>&1)"
check "an ANSWERED adopted question is NOT RESURRECTED by later reads" \
  "[ \"\$(jget '$AP23' 'len(d[\"questions\"])')\" = 1 ]"
check "and the screen reports him clear" \
  "printf '%s' \"\$st23b\" | qgrep -q 'open questions for the captain: none'"
check "the captain's answer survived the whole thing" \
  "printf '%s' \"\$(jget '$AP23' 'd[\"questions\"][\"q1\"][\"answer\"]')\" | qgrep -q 'key rotated'"
# `answered pending` keeps working as the POINTER the mirror is — it closes the
# question the mirror names (the OLDEST open one), never a copy living there.
R23B="$(new_repo)"
ap "$R23B" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP23B="$R23B/.git/lcars/autopilot.json"
new_mission "$R23B" lcars-ptr-1 implement
ap "$R23B" ask "the oldest open one" --mission lcars-ptr-1 >/dev/null 2>&1
ap "$R23B" ask "the newer one" --mission lcars-ptr-2 >/dev/null 2>&1
ap "$R23B" answered pending "by the pointer" >/dev/null 2>&1
check "answered pending closes the question the MIRROR NAMES (the oldest open)" \
  "[ -n \"\$(jget '$AP23B' 'd[\"questions\"][\"q1\"].get(\"answeredAt\")')\" ] && [ -z \"\$(jget '$AP23B' 'd[\"questions\"][\"q2\"].get(\"answeredAt\")')\" ]"
check "and it created no extra question doing it" \
  "[ \"\$(jget '$AP23B' 'len(d[\"questions\"])')\" = 2 ]"

# --- S233e: answering by MISSION when two questions share that mission ------
# CHOSEN BEHAVIOUR: it closes the OLDEST open question on that mission — the
# long-standing `answered <mission>` semantics — and SAYS SO, naming what is
# still open on that same mission. It may never silently destroy one.
R24="$(new_repo)"
ap "$R24" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
AP24="$R24/.git/lcars/autopilot.json"
new_mission "$R24" lcars-share-1 verify
new_mission "$R24" lcars-sharebug-1 implement bug lcars-share-1
ap "$R24" record 'missions.M0.id' lcars-share-1 >/dev/null 2>&1
ap "$R24" land lcars-share-1 >/dev/null 2>&1                         # q1
ap "$R24" ask "HAND: a second call on the same milestone" \
  --mission lcars-share-1 --why "a scope change" >/dev/null 2>&1     # q2
out24="$(ap "$R24" answered lcars-share-1 "the first answer" 2>&1)"
check "answering by MISSION closes exactly ONE question" \
  "[ \"\$(jget '$AP24' 'len([q for q in d[\"questions\"].values() if q.get(\"answeredAt\")])')\" = 1 ]"
check "it closes the OLDEST open one (q1)" \
  "[ -n \"\$(jget '$AP24' 'd[\"questions\"][\"q1\"].get(\"answeredAt\")')\" ]"
check "the other is UNTOUCHED, not destroyed" \
  "[ -z \"\$(jget '$AP24' 'd[\"questions\"][\"q2\"].get(\"answeredAt\")')\" ] && [ -n \"\$(jget '$AP24' 'd[\"questions\"][\"q2\"].get(\"what\")')\" ]"
check "and it WARNS that the mission still has an open question, by id" \
  "printf '%s' \"\$out24\" | qgrep -qE 'still has 1 open question.*q2|q2.*still open on lcars-share-1'"
check "the warning says answering by mission closes the oldest only" \
  "printf '%s' \"\$out24\" | qgrep -qi 'oldest'"
st24="$(ap "$R24" status 2>&1)"
nrows24="$(printf '%s\n' "$st24" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "status lists the survivor, count equal to rows" \
  "[ \"$nrows24\" = 1 ] && printf '%s' \"\$st24\" | qgrep -q 'open questions for the captain: 1'"
ap "$R24" answered lcars-share-1 "the second answer" >/dev/null 2>&1
check "a second answer-by-mission closes the survivor too" \
  "[ \"\$(jget '$AP24' 'len([q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")])')\" = 0 ]"

# --- S233f: status's count ALWAYS equals the rows it prints -----------------
# Three questions over two missions, raised both ways.
R25="$(new_repo)"
ap "$R25" init --spec "$TMPROOT/spec.md" --scope M0,M1 >/dev/null 2>&1
new_mission "$R25" lcars-cnt-1 verify
new_mission "$R25" lcars-cntbug-1 implement bug lcars-cnt-1
ap "$R25" record 'missions.M0.id' lcars-cnt-1 >/dev/null 2>&1
ap "$R25" land lcars-cnt-1 >/dev/null 2>&1
ap "$R25" ask "second question" --mission lcars-cnt-1 >/dev/null 2>&1
ap "$R25" ask "third question" --mission lcars-cnt-2 >/dev/null 2>&1
st25="$(ap "$R25" status 2>&1)"
hdr25="$(printf '%s\n' "$st25" | sed -n 's/^  open questions for the captain: \([0-9]*\)$/\1/p')"
nrows25="$(printf '%s\n' "$st25" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "the header count and the printed rows agree at 3" \
  "[ \"$hdr25\" = 3 ] && [ \"$nrows25\" = 3 ]"
ap "$R25" answered q2 "ok" >/dev/null 2>&1
st25b="$(ap "$R25" status 2>&1)"
hdr25b="$(printf '%s\n' "$st25b" | sed -n 's/^  open questions for the captain: \([0-9]*\)$/\1/p')"
nrows25b="$(printf '%s\n' "$st25b" | sed -n 's/^    \[[^]]*\] .*/x/p' | wc -l | tr -d ' ')"
check "they still agree after one is answered" \
  "[ \"$hdr25b\" = 2 ] && [ \"$nrows25b\" = 2 ]"

# --- S233g: NO code path may read a question OUT OF `.pending` --------------
# The structural test of the cure. `open_questions` — the one function `status`,
# `next` and `build_plan` all read from — must derive its rows from `questions`
# alone; and `.pending` on disk must never hold a `what` that is not also a
# live ledger entry.
check "open_questions reads the ledger ONLY (no .pending fallback left in it)" \
  "[ \"\$(sed -n '/^open_questions()/,/^}/p' '$SCRIPT' | grep -c 'pending')\" = 0 ]"
MIRROR_PROBE="$TMPROOT/mirror-probe.py"
cat >"$MIRROR_PROBE" <<'PY'
import json, sys
for f in sys.argv[1:]:
    d = json.load(open(f))
    p = d.get("pending") or {}
    if not p.get("what"):
        continue
    q = (d.get("questions") or {}).get(p.get("id"))
    if not (q and q.get("what") == p.get("what") and not q.get("answeredAt")):
        sys.stderr.write("%s: .pending holds a question that is NOT a live ledger entry\n" % f)
        sys.exit(1)
PY
check "every .pending holding a question MIRRORS a live ledger entry" \
  "python3 '$MIRROR_PROBE' '$AP20' '$AP23' '$AP24' '$AP23B'"

# --- D3: one blocked milestone must not park every other milestone ---------
# `build_plan` hit answer-pending and returned BEFORE it looked at any mission,
# so with M0 blocked on a question and M1 sitting ready at its Verify gate,
# `next --all`'s "PLAN (in order)" was a ONE-ITEM list. One midnight question
# parked the whole run — and with the two-slot rule that is wrong by design.
R14="$(new_repo)"
ap "$R14" init --spec "$TMPROOT/spec.md" --scope M0,M1 >/dev/null 2>&1
AP14="$R14/.git/lcars/autopilot.json"
new_mission "$R14" lcars-blocked-1 verify
new_mission "$R14" lcars-bug-c implement bug lcars-blocked-1
new_mission "$R14" lcars-ready-1 verify
ap "$R14" record 'missions.M0.id' lcars-blocked-1 >/dev/null 2>&1
ap "$R14" record 'missions.M1.id' lcars-ready-1 >/dev/null 2>&1
ap "$R14" record 'missions.M1.verified' true >/dev/null 2>&1
ap "$R14" land lcars-blocked-1 >/dev/null 2>&1   # → a question on M0
nx14="$(ap "$R14" next --all 2>&1)"
check "the blocked milestone's question is still surfaced" \
  "printf '%s' \"\$nx14\" | qgrep -q 'answer-pending'"
check "the PLAN is NOT a one-item list while a question is open" \
  "[ \"\$(printf '%s\n' \"\$nx14\" | grep -c '^  [0-9]*\. ')\" -ge 2 ]"
check "the OTHER milestone's runnable work is still offered" \
  "printf '%s' \"\$nx14\" | qgrep -q 'verify-gate lcars-ready-1'"
check "the blocked milestone itself is NOT offered as runnable work" \
  "! printf '%s' \"\$nx14\" | qgrep -q 'verify-gate lcars-blocked-1'"
check "single \`next\` points at the runnable work too, not just the question" \
  "printf '%s' \"\$nx14\" | qgrep -q 'RUNNABLE'"
st14="$(ap "$R14" status 2>&1)"
check "status shows the question AND the other milestone's next step" \
  "printf '%s' \"\$st14\" | qgrep -q 'lcars-ready-1'"

# ==========================================================================
# 12. a CORRUPT autopilot.json fails CLOSED — it is never silently replaced
# ==========================================================================
echo "-- 12. corrupt autopilot.json --"
# OBSERVED: `ap_set`'s read was `except: d = {}`, so a file that EXISTS but will
# not parse read as "no file yet". One `record` against a mid-JSON truncation
# reported SUCCESS and left questions=0, scope=None, spec=None — 8 questions,
# every recorded answer and the whole alignment round gone, with no warning and
# no backup, while `status` printed an empty shell and never complained. The
# house precedent (S232's unreadable-record refusal) is to fail closed.
R20="$(new_repo)"
ap "$R20" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
ap "$R20" record 'liveTargets.host' 'example.com' >/dev/null 2>&1
AP20="$R20/.git/lcars/autopilot.json"
head -c 40 "$AP20" >"$AP20.cut" && mv "$AP20.cut" "$AP20"
r20a="$(ap "$R20" record 'liveTargets.host' 'other.example' 2>&1)"; rc20a=$?
check "record REFUSES a corrupt autopilot.json"  "[ $rc20a -ne 0 ]"
check "the refusal NAMES the file it could not parse" \
  "printf '%s' \"\$r20a\" | qgrep -q 'autopilot.json'"
check "the corrupt file is NOT replaced with an empty record" \
  "! python3 -c 'import json,sys;json.load(open(sys.argv[1]))' '$AP20' 2>/dev/null"
r20b="$(ap "$R20" status 2>&1)"; rc20b=$?
check "status REFUSES a corrupt autopilot.json too" "[ $rc20b -ne 0 ]"
check "status's refusal names the file"          "printf '%s' \"\$r20b\" | qgrep -q 'autopilot.json'"
check "status never prints an empty shell as if all were well" \
  "! printf '%s' \"\$r20b\" | qgrep -q 'open questions for the captain: 0'"
# An ABSENT file must still mean "no record yet" — that is how `init` works.
R21="$(new_repo)"
r21a="$(ap "$R21" status 2>&1)"; rc21a=$?
check "an ABSENT autopilot.json is still 'run init first', not a parse error" \
  "[ $rc21a -ne 0 ] && printf '%s' \"\$r21a\" | qgrep -q 'init'"
r21b="$(ap "$R21" init --spec "$TMPROOT/spec.md" --scope M0 2>&1)"; rc21b=$?
check "init on an absent file still initialises normally" \
  "[ $rc21b -eq 0 ] && [ -f '$R21/.git/lcars/autopilot.json' ]"
check "the fresh record is valid JSON" \
  "python3 -c 'import json,sys;json.load(open(sys.argv[1]))' '$R21/.git/lcars/autopilot.json'"
check "and record works on it (a clean file is never refused)" \
  "ap '$R21' record 'liveTargets.host' 'example.com' >/dev/null 2>&1 && [ \"\$(jget '$R21/.git/lcars/autopilot.json' 'd[\"liveTargets\"][\"host\"]')\" = example.com ]"

# ==========================================================================
# 10. THE CONTRACT TEST — the INSTALLED prose carries the headings `next` names
# ==========================================================================
echo "-- 10. prose/script contract (INSTALLED files) --"
# WHY THE INSTALLED COPY. The mode is what a MODEL reads at
# ~/.claude/skills/lcars-buddy/. A test over the repo copy proves the source and
# says nothing about what runs. install.sh symlinks, so the installed copy is
# the repo copy — but asserting the INSTALLED path is what catches a skill that
# was never installed, or installed from a different clone.
INSTALLED_DIR="${LCARS_SKILLS_DEST:-$HOME/.claude/skills}/lcars-buddy"
SK="$INSTALLED_DIR/SKILL.md"
APM="$INSTALLED_DIR/AUTOPILOT.md"
# NO FALLBACK TO THE REPO COPY. A fallback made these two checks print PASS
# against a genuinely EMPTY skills dir — 162/0, byte-identical to a real run,
# with the file absent — which destroyed the very intent stated above. An absent
# installed file now FAILS, naming the path it looked at. The flip is proved by
# the CONTROL at the bottom of this file.
check "AUTOPILOT.md is installed at $APM" "[ -f '$APM' ]"
check "SKILL.md is installed at $SK"      "[ -f '$SK' ]"

# The driver publishes its own action→heading table. Every heading it names MUST
# exist, verbatim, in the installed AUTOPILOT.md. That is the anti-drift lock:
# renaming a heading breaks this test, and so does adding an action with no
# prose behind it.
pb="$(ap "$R11" playbook 2>&1)"
check "the driver publishes an action→heading table" \
  "printf '%s' \"\$pb\" | qgrep -q 'verify-gate'"
nactions=0
while IFS="$(printf '\t')" read -r action heading; do
  [ -n "${action:-}" ] || continue
  case "$action" in \#*) continue ;; esac
  nactions=$((nactions + 1))
  check "AUTOPILOT.md carries the heading for '$action'" \
    "qgrep -qF -- '$heading' '$APM'"
done <<EOF
$(printf '%s\n' "$pb")
EOF
check "the table is not empty"             "[ $nactions -ge 5 ]"

# The specific prose the mode cannot work without.
check "AUTOPILOT.md § 3 is pointed at from SKILL.md" "qgrep -qF 'AUTOPILOT.md' '$SK'"
check "SKILL.md gained a '## 3.' section"            "qgrep -qE '^## 3\\.' '$SK'"
check "SKILL.md § 3 carries the trigger phrase"      "qgrep -qiF 'run it for me' '$SK'"
check "SKILL.md still has § 1 (ride-along) UNCHANGED in name" \
  "qgrep -qF '## 1. Run the diagnostic collector and show it verbatim' '$SK'"
check "SKILL.md still has § 2 (orchestrated fix)" \
  "qgrep -qF '## 2. When it' '$SK'"
check "SKILL.md points at ORCHESTRATION.md once, and does not restate the loop" \
  "[ \"\$(grep -c 'ORCHESTRATION.md' '$APM')\" -le 2 ]"
check "AUTOPILOT.md names autopilot.sh as the state's home" "qgrep -qF 'autopilot.json' '$APM'"
check "AUTOPILOT.md states the HEARTBEAT is crontab" \
  "qgrep -qF 'crontab' '$APM'"
check "AUTOPILOT.md does NOT name a harness-only tool as the heartbeat" \
  "! qgrep -qF 'CronCreate' '$APM'"
check "AUTOPILOT.md says WHY crontab and not a harness tool" \
  "qgrep -qiE 'not inside Claude Code|outside Claude Code|people who are not' '$APM'"
check "AUTOPILOT.md carries the interrupt budget"   "qgrep -qiF 'interrupt budget' '$APM'"
check "AUTOPILOT.md carries the two-parallel rule"  "qgrep -qiE 'two (missions|at a time|parallel)' '$APM'"
check "AUTOPILOT.md carries the memory rule (re-read after compaction)" \
  "qgrep -qiF 'compaction' '$APM'"
check "AUTOPILOT.md carries the communication rules" \
  "qgrep -qiE 'final message of the turn' '$APM'"
check "AUTOPILOT.md carries the deadline re-forecast rule" \
  "qgrep -qiF 're-forecast' '$APM'"
check "AUTOPILOT.md carries the copy-paste-safe secret instruction" \
  "qgrep -qF 'pbpaste | gh secret set' '$APM'"
check "AUTOPILOT.md forbids the hand-merge in writing" \
  "qgrep -qiE 'never (merge by hand|hand-merge)' '$APM'"
# S277: command-name literal ONLY. AUTOPILOT.md now names the on-PATH `lcars-autopilot <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `autopilot.sh`.
check "AUTOPILOT.md tells the model to run \`autopilot.sh next\`" \
  "qgrep -qF 'lcars-autopilot next' '$APM'"
# --- the prose for the fix-round cures, so script and playbook cannot drift --
check "AUTOPILOT.md names ALL SIX sections file.sh requires" \
  "for sec in 'Mission title' 'Type' 'Goal' 'Acceptance Criteria' 'Out of Scope' 'Constraints'; do qgrep -qF \"\$sec\" '$APM' || exit 1; done"
check "AUTOPILOT.md gives alignment question 3 a key to record its answer in" \
  "qgrep -qF 'record deploy' '$APM'"
check "AUTOPILOT.md documents the DECLINED captain-only step state" \
  "qgrep -qF '\"declined\":true' '$APM' && qgrep -qiF 'never \`done: true\`' '$APM'"
check "AUTOPILOT.md documents \`autopilot.sh answered\` as how a question closes" \
  "qgrep -qF 'lcars-autopilot answered' '$APM'"
check "AUTOPILOT.md says re-raising an OPEN question is a no-op" \
  "qgrep -qi 'raising the same question twice' '$APM'"
check "AUTOPILOT.md says questions are a LEDGER, not one slot" \
  "qgrep -qiE 'ledger, not a slot|every question ever raised' '$APM'"
# --- S233: the prose must instruct the VERB, never a hand-edit of `pending` --
# The playbook telling the model to hand-write into `.pending` is what made that
# field load-bearing storage, and that ambiguity cost five defects. § 9 now
# names `autopilot.sh ask`, and declares `pending` derived and read-only.
check "AUTOPILOT.md § 9 instructs the \`ask\` VERB" \
  "qgrep -qF 'lcars-autopilot ask' '$APM'"
check "AUTOPILOT.md gives \`ask\` its --mission flag so it blocks one milestone" \
  "qgrep -qE 'autopilot.sh ask .*--mission|--mission <' '$APM'"
check "AUTOPILOT.md no longer tells the model to hand-write a question into pending" \
  "! qgrep -qiE 'write the same shape by hand|by hand, into .pending|hand-write' '$APM'"
check "AUTOPILOT.md declares \`pending\` a DERIVED, READ-ONLY mirror" \
  "qgrep -qiE 'read-only.*mirror|mirror.*read-only|never storage' '$APM'"
check "AUTOPILOT.md says an older run's hand-written pending is still honoured" \
  "qgrep -qiE 'adopt(ed|s)? .*(the moment|on first sight|first time it is (seen|read))' '$APM'"
# `usage` exits 1 by design and this suite runs with `pipefail`, so the exit
# code has to be discarded or the pipeline reports the usage exit, not the grep.
check "the driver documents the \`ask\` subcommand in its own usage" \
  "{ ap '$R11' --help 2>&1 || true; } | qgrep -qE '^  ask '"
check "AUTOPILOT.md states the three-failure drive cap" \
  "qgrep -qiE 'three failures in a row|failures in a row' '$APM'"
check "AUTOPILOT.md states that a routine stage stop pings nobody" \
  "qgrep -qiE 'routine stage stop pings nobody|routine stage stop' '$APM'"
check "AUTOPILOT.md says one question does not park the other milestones" \
  "qgrep -qiE 'none of them parks the run|does not park' '$APM'"
check "AUTOPILOT.md does not fork ORCHESTRATION.md's loop" \
  "! qgrep -qiF 'hard stop at three rounds' '$APM'"

# ==========================================================================
# S234.1 live-check — the setup, the checklists, the record
# ==========================================================================
# WHY THE SCRIPT OWNS ONLY THE SETUP. Number One filed 0 of the weekend's 31
# bugs and every one came from a model LOOKING at a real surface. So the script
# does not try to judge: it prepares the detached worktree + throwaway HOME,
# makes the evidence dir, prints the checklist(s) for the product type, and
# records the verdict. The looking stays with the model.
echo "-- S234.1 live-check --"
RLC="$(new_repo)"
ap "$RLC" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RLC" lcars-20261001-001 verify
ap "$RLC" record missions.M0.id lcars-20261001-001 >/dev/null 2>&1
LCOUT="$(ap "$RLC" live-check lcars-20261001-001 --type cli 2>&1)"; lcrc=$?
LCEV="$RLC/.git/lcars/missions/lcars-20261001-001/live-check"
lc_wt="$(printf '%s\n' "$LCOUT" | sed -n 's/^WORKTREE: //p' | head -1)"
lc_home="$(printf '%s\n' "$LCOUT" | sed -n 's/^HOME: //p' | head -1)"

check "live-check exits 0"                    "[ $lcrc -eq 0 ]"
check "live-check prints a WORKTREE path"     "[ -n '$lc_wt' ] && [ -d '$lc_wt' ]"
check "the worktree is DETACHED (never the checked-out branch)" \
  "[ \"\$(git -C '$lc_wt' symbolic-ref -q HEAD || echo detached)\" = detached ]"
check "live-check prints a throwaway HOME"    "[ -n '$lc_home' ] && [ -d '$lc_home' ]"
check "the HOME is NOT the captain's"         "[ '$lc_home' != \"\$HOME\" ]"
check "live-check makes the evidence dir under the MISSION's state" "[ -d '$LCEV' ]"
check "live-check prints the evidence dir to write to" \
  "printf '%s' \"\$LCOUT\" | qgrep -qF '$LCEV'"
check "live-check prints the cli checklist, not a summary of it" \
  "printf '%s' \"\$LCOUT\" | qgrep -qF 'host of every outbound call'"
check "it prints the checklist's fenced step templates too (Number One's half)" \
  "printf '%s' \"\$LCOUT\" | qgrep -qF '\`\`\`run:'"
check "it names the type it printed" \
  "printf '%s' \"\$LCOUT\" | qgrep -qE 'CHECKLIST: cli'"
check "it does NOT print the web or workflow checklist when only cli was asked for" \
  "! printf '%s' \"\$LCOUT\" | qgrep -qE 'CHECKLIST: (web|workflow)'"
check "it tells you how to record the outcome" \
  "printf '%s' \"\$LCOUT\" | qgrep -qF 'live-check done'"

LCOUT2="$(ap "$RLC" live-check lcars-20261001-001 --type cli,web,workflow 2>&1)"; lcrc2=$?
check "--type takes a comma list and prints all three, in the order given" \
  "[ $lcrc2 -eq 0 ] && [ \"\$(printf '%s\n' \"\$LCOUT2\" | sed -n 's/.*CHECKLIST: \([a-z]*\).*/\1/p' | tr '\n' ' ')\" = 'cli web workflow ' ]"
check "the web checklist carries the 400 px iframe recipe" \
  "printf '%s' \"\$LCOUT2\" | qgrep -qF '400px'"
check "the workflow checklist names \`workflow-run\`" \
  "printf '%s' \"\$LCOUT2\" | qgrep -qF 'workflow-run'"

LCBAD="$(ap "$RLC" live-check lcars-20261001-001 --type api 2>&1)"; lcbrc=$?
check "an UNKNOWN type is REFUSED"            "[ $lcbrc -ne 0 ]"
check "the refusal names the types it does know" \
  "printf '%s' \"\$LCBAD\" | qgrep -qF 'cli' && printf '%s' \"\$LCBAD\" | qgrep -qF 'workflow'"
check "a refused type printed NO checklist (so nobody half-follows one)" \
  "! printf '%s' \"\$LCBAD\" | qgrep -qE 'CHECKLIST:'"
LCNOT="$(ap "$RLC" live-check lcars-20261001-001 2>&1)"; lcnrc=$?
check "a MISSING --type is refused"           "[ $lcnrc -ne 0 ]"
LCNOM="$(ap "$RLC" live-check lcars-20261001-999 --type cli 2>&1)"; lcnmrc=$?
check "an unknown MISSION is refused"         "[ $lcnmrc -ne 0 ]"

# the record
LCDONE="$(ap "$RLC" live-check done lcars-20261001-001 --verdict bugs 2>&1)"; lcdrc=$?
APLC="$RLC/.git/lcars/autopilot.json"
check "live-check done exits 0"               "[ $lcdrc -eq 0 ]"
check "the verdict is RECORDED in autopilot.json, not inferred later" \
  "[ \"\$(jget '$APLC' 'd[\"liveChecks\"][\"lcars-20261001-001\"][\"verdict\"]')\" = bugs ]"
check "the recorded verdict carries the TYPES that were checked" \
  "printf '%s' \"\$(jget '$APLC' 'd[\"liveChecks\"][\"lcars-20261001-001\"][\"types\"]')\" | qgrep -qF 'cli'"
check "the recorded verdict carries the evidence dir" \
  "printf '%s' \"\$(jget '$APLC' 'd[\"liveChecks\"][\"lcars-20261001-001\"][\"evidence\"]')\" | qgrep -qF 'live-check'"
check "the milestone's own row records it too (status reads that)" \
  "[ \"\$(jget '$APLC' 'd[\"missions\"][\"M0\"][\"liveCheck\"]')\" = bugs ]"
check "it also lands in the decisions LEDGER" \
  "qgrep -q 'live-check' '$RLC/.git/lcars/decisions.jsonl'"
LCDBAD="$(ap "$RLC" live-check done lcars-20261001-001 --verdict probably 2>&1)"; lcdbrc=$?
check "a verdict that is neither pass nor bugs is REFUSED" "[ $lcdbrc -ne 0 ]"
LCDNOV="$(ap "$RLC" live-check done lcars-20261001-001 2>&1)"; lcdnrc=$?
check "\`done\` with no --verdict is REFUSED (no silent pass)" "[ $lcdnrc -ne 0 ]"
LCDONE2="$(ap "$RLC" live-check done lcars-20261001-001 --verdict pass 2>&1)"
check "a second done OVERWRITES the verdict (a re-verify round can clear it)" \
  "[ \"\$(jget '$APLC' 'd[\"liveChecks\"][\"lcars-20261001-001\"][\"verdict\"]')\" = pass ]"
git -C "$RLC" worktree remove --force "$lc_wt" 2>/dev/null || true

# ==========================================================================
# S234.2 workflow-run — the real entrypoint, exactly as CI runs it
# ==========================================================================
# THE WEEKEND'S BREAK #4: the workflow ran `python3 pkg/hub_requests.py`, which
# dies with a relative-import ImportError, while `python3 -m pkg.hub_requests`
# works. Every test that imported the function, or ran it as a module, passed.
# Only running the step's OWN command, from the step's OWN cwd, with the env
# Actions sets, fails — so that is what this runner does. A runner that
# "helpfully" rewrites the command into the form that works is BROKEN.
echo "-- S234.2 workflow-run --"
RWF="$(new_repo)"
ap "$RWF" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RWF" lcars-20261001-002 verify
mkdir -p "$RWF/.github/workflows" "$RWF/pkg" "$RWF/sub"
cat >"$RWF/pkg/__init__.py" <<'PY'
PY
cat >"$RWF/pkg/model.py" <<'PY'
def host_of(rec): return rec.get("host", "github.com")
PY
cat >"$RWF/pkg/render.py" <<'PY'
from .model import host_of
def render(): print("rendered", host_of({}))
if __name__ == "__main__":
    render()
PY
cat >"$RWF/.github/workflows/publish.yml" <<'YML'
name: publish
on:
  push:
  schedule:
    - cron: "0 * * * *"
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Show the Actions env
        run: |
          echo "server=$GITHUB_SERVER_URL"
          echo "owner=$GITHUB_REPOSITORY_OWNER"
          echo "repo=$GITHUB_REPOSITORY"
          echo "eventfile=$GITHUB_EVENT_PATH"
          test -f "$GITHUB_EVENT_PATH" && echo "eventfile-exists=yes"
      - name: In the subdirectory
        working-directory: sub
        run: pwd
      - name: Render the page
        run: python3 pkg/render.py
      - name: Publish
        run: echo PUBLISH-RAN
YML
WFOUT="$(ap "$RWF" workflow-run lcars-20261001-002 "$RWF/.github/workflows/publish.yml" \
          --repository acme/relay 2>&1)"; wfrc=$?
WFEV="$RWF/.git/lcars/missions/lcars-20261001-002/live-check/02-workflow-run.txt"

check "workflow-run exits NON-ZERO when a step fails" "[ $wfrc -ne 0 ]"
check "it names the FIRST FAILING STEP by its workflow step name" \
  "printf '%s' \"\$WFOUT\" | qgrep -qE 'FIRST FAILING STEP: Render the page'"
check "the failing step's real error is shown (the ImportError, not a summary)" \
  "printf '%s' \"\$WFOUT\" | qgrep -qF 'attempted relative import'"
check "steps run IN ORDER" \
  "[ \"\$(printf '%s\n' \"\$WFOUT\" | sed -n 's/^STEP [0-9]*: //p' | tr '\n' '|')\" = 'actions/checkout@v4|Show the Actions env|In the subdirectory|Render the page|' ]"
check "a step AFTER the failing one does NOT run (CI stops the job)" \
  "! printf '%s' \"\$WFOUT\" | qgrep -qF 'PUBLISH-RAN'"
check "a \`uses:\` step is SKIPPED, not failed" \
  "printf '%s' \"\$WFOUT\" | qgrep -qE 'SKIP.*actions/checkout'"
check "GITHUB_SERVER_URL is set for the step" \
  "printf '%s' \"\$WFOUT\" | qgrep -qF 'server=https://github.com'"
check "GITHUB_REPOSITORY_OWNER is set for the step" \
  "printf '%s' \"\$WFOUT\" | qgrep -qF 'owner=acme'"
check "GITHUB_REPOSITORY is set for the step" \
  "printf '%s' \"\$WFOUT\" | qgrep -qF 'repo=acme/relay'"
check "GITHUB_EVENT_PATH is set AND the file really exists" \
  "printf '%s' \"\$WFOUT\" | qgrep -qF 'eventfile-exists=yes'"
check "\`working-directory\` is HONOURED (same cwd as CI, not the repo root)" \
  "printf '%s' \"\$WFOUT\" | qgrep -qE '/sub$'"
check "the transcript is saved as evidence under the mission" "[ -s '$WFEV' ]"
check "the saved evidence carries the first-failing-step line too" \
  "qgrep -qF 'FIRST FAILING STEP' '$WFEV'"
check "a non-default --server-url reaches the steps" \
  "{ ap '$RWF' workflow-run lcars-20261001-002 '$RWF/.github/workflows/publish.yml' --server-url https://github.example.com 2>&1 || true; } | qgrep -qF 'server=https://github.example.com'"

# THE CONTROL: the same workflow with the step corrected to the module form.
# Without this, "it failed" could mean the runner cannot run anything at all.
cp "$RWF/.github/workflows/publish.yml" "$RWF/.github/workflows/fixed.yml"
python3 - "$RWF/.github/workflows/fixed.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("python3 pkg/render.py", "python3 -m pkg.render")
open(p, "w").write(s)
PY
WFOK="$(ap "$RWF" workflow-run lcars-20261001-002 "$RWF/.github/workflows/fixed.yml" \
         --repository acme/relay --evidence 02-workflow-run-fixed.txt 2>&1)"; wfokrc=$?
check "CONTROL: the same workflow with \`python3 -m pkg.render\` PASSES" \
  "[ $wfokrc -eq 0 ]"
check "CONTROL: it names no failing step" \
  "! printf '%s' \"\$WFOK\" | qgrep -qF 'FIRST FAILING STEP'"
check "CONTROL: every step after the corrected one DOES run" \
  "printf '%s' \"\$WFOK\" | qgrep -qF 'PUBLISH-RAN'"
check "CONTROL: --evidence names the file it wrote" \
  "[ -s '$RWF/.git/lcars/missions/lcars-20261001-002/live-check/02-workflow-run-fixed.txt' ]"
check "the runner does NOT shell out to a third-party runner (no \`act\`)" \
  "! qgrep -qE '(^|[^a-z])act (-|run|pull)' '$SCRIPT'"
WFNOF="$(ap "$RWF" workflow-run lcars-20261001-002 "$RWF/.github/workflows/nope.yml" 2>&1)"; wfnrc=$?
check "a missing workflow file is refused"    "[ $wfnrc -ne 0 ]"

# THE REAL S234 FIXTURE PRODUCT IS THE TESTER'S LEG, NOT THIS SUITE'S.
# The inline fixture above reproduces the planted defect exactly — a package
# module invoked as a file, failing with the same ImportError on a step with the
# same name — so the mechanics are proved here, portably, in any clone. Pointing
# a committed suite at a rig in the author's lcars-dev checkout would both break
# the `no-rigs` gate (which refuses a rig-path reference in tests/*.test.sh, on
# purpose) and make this suite unrunnable for anyone else. The real fixture is
# driven by the tester, from the rig's own directory.

# ==========================================================================
# S234.3 file-bug — evidence first, or it is not filed
# ==========================================================================
# The PRD style that got fixes through FIRST TIME quotes the live output in
# AC #1 and, at a producer/consumer seam, demands a round-trip with no
# hand-written fixture between the halves. A prose description of the bug is
# what produced the re-filings.
echo "-- S234.3 file-bug --"
RFB="$(new_repo)"
ap "$RFB" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RFB" lcars-20261001-010 verify
# A log.sh stub that files for REAL the way log.sh does: a bug mission linked to
# its parent. file-bug must verify the linkage it claims, not assume exit 0.
LOGFILES='parent=""; prds=""
while [ $# -gt 0 ]; do
  case "$1" in --parent) parent="$2"; shift ;; --prd) prds="$prds $2"; shift ;; esac
  shift
done
n=0
for p in $prds; do
  n=$((n+1))
  d="$LCARS_AUTOPILOT_CWD/.git/lcars/missions/bug-00$n"
  mkdir -p "$d"
  cp "$p" "$d/prd.md"
  cat >"$d/state.json" <<JSON
{"id":"bug-00$n","stage":"align","type":"bug","title":"a filed bug",
 "branch":"lcars/$parent","parentMission":"$parent","parentIssue":"1",
 "labels":["lcars:align","lcars:bug","lcars:linked","lcars:mission"]}
JSON
done'
stub "$STUBS/log-files.sh" 0 "$LOGFILES"

PRD_BAD="$TMPROOT/bug-noevidence.md"
cat >"$PRD_BAD" <<'MD'
# Mission: the page shows the wrong host

**Type:** bug
**Seam:** none
**Goal:** The page shows the host the CLI stored.
**Acceptance Criteria:**
- The renderer reads the same field the CLI writes.
- A test covers it.
**Out of Scope:**
- Styling.
**Constraints:**
- Stdlib only.
MD
FBBAD="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 --prd "$PRD_BAD" 2>&1 )"; fbbrc=$?
check "file-bug REFUSES a PRD whose AC #1 is not an \`Observed live:\` line" "[ $fbbrc -ne 0 ]"
check "the refusal says what AC #1 must be" \
  "printf '%s' \"\$FBBAD\" | qgrep -qF 'Observed live:'"
check "the refused PRD filed NOTHING" "[ ! -d '$RFB/.git/lcars/missions/bug-001' ]"

PRD_SEAM="$TMPROOT/bug-seam-noroundtrip.md"
cat >"$PRD_SEAM" <<'MD'
# Mission: the page always shows the default host

**Type:** bug
**Seam:** relay.py cmd_file (writes the record) -> pkg/model.py host_of (reads it)
**Goal:** The host the CLI stores is the host the page renders.
**Acceptance Criteria:**
- Observed live: `RELAY_HOST=github.example.com python3 relay.py file "x"` stored `"origin": "github.example.com"`, and the rendered row shows `github.com`.
- The reader and the writer agree on one field name.
**Out of Scope:**
- Styling.
**Constraints:**
- Stdlib only.
MD
FBSEAM="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 --prd "$PRD_SEAM" 2>&1 )"; fbsrc=$?
check "a declared SEAM with no ROUND-TRIP criterion is REFUSED" "[ $fbsrc -ne 0 ]"
check "the refusal asks for the round-trip with no hand-written fixture" \
  "printf '%s' \"\$FBSEAM\" | qgrep -qi 'round-trip'"

PRD_GOOD="$TMPROOT/bug-good.md"
cat >"$PRD_GOOD" <<'MD'
# Mission: every rendered row shows the default host, never the stored one

**Type:** bug
**Seam:** relay.py cmd_file (writes the record) -> pkg/model.py host_of (reads it)
**Goal:** The host the CLI stores is the host the page renders, for every record.
**Acceptance Criteria:**
- Observed live: `RELAY_HOST=github.example.com python3 relay.py file "sandwich"` stored `"origin": "github.example.com"` in `requests/r-1759300000000.json`; `python3 -m pkg.render` then rendered `<td class="host">github.com</td>`. The writer writes `origin`; `host_of()` reads `host` with a `github.com` default, so the two halves never meet.
- ONE shared field name, declared in `pkg/model.py` and used by both halves.
- Round-trip test with NO hand-written fixture: the test files a record with the CLI's own `cmd_file`, renders it with the real `render()`, and asserts the rendered host is the one that was configured.
**Out of Scope:**
- The hardcoded `api.github.com` in `cmd_publish` (filed separately).
**Constraints:**
- Stdlib only; no network in tests.
MD
FBOK="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 --prd "$PRD_GOOD" 2>&1 )"; fbokrc=$?
check "file-bug FILES a PRD that carries the live observation" "[ $fbokrc -eq 0 ]"
check "it filed through log.sh --parent --prd (it re-implements nothing)" \
  "qgrep -qE 'log-files.sh .*--parent lcars-20261001-010' '$STUB_LOG' && qgrep -qF -- '--prd' '$STUB_LOG'"
check "the child bug mission exists" "[ -f '$RFB/.git/lcars/missions/bug-001/state.json' ]"
check "it reports the child it filed, by id" \
  "printf '%s' \"\$FBOK\" | qgrep -qF 'bug-001'"
check "the child is LINKED — parentMission is the parent" \
  "[ \"\$(jget '$RFB/.git/lcars/missions/bug-001/state.json' 'd[\"parentMission\"]')\" = lcars-20261001-010 ]"
check "it confirms the lcars:linked label it depends on" \
  "printf '%s' \"\$FBOK\" | qgrep -qF 'lcars:linked'"
check "the filing lands in the decisions ledger with the parent" \
  "qgrep -q 'bug-001' '$RFB/.git/lcars/decisions.jsonl'"
# The guard that matters: a log.sh that exits 0 WITHOUT linking must not be
# reported as a filing. "approve exited 0" was reported as a merge once already.
stub "$STUBS/log-lies.sh" 0
RFB2="$(new_repo)"
ap "$RFB2" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RFB2" lcars-20261001-010 verify
FBLIE="$( LOG_STUB="$STUBS/log-lies.sh" ap "$RFB2" file-bug --parent lcars-20261001-010 --prd "$PRD_GOOD" 2>&1 )"; fblrc=$?
check "a log.sh that exits 0 but links NOTHING is NOT reported as a filing" \
  "[ $fblrc -ne 0 ]"
check "that refusal says no linked child appeared" \
  "printf '%s' \"\$FBLIE\" | qgrep -qiE 'no linked bug|not linked'"
FBNOPRD="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 2>&1 )"; fbnprc=$?
check "file-bug with no --prd is refused"     "[ $fbnprc -ne 0 ]"
FBNOPAR="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --prd "$PRD_GOOD" 2>&1 )"; fbnparc=$?
check "file-bug with no --parent is refused (a bug is always a child)" "[ $fbnparc -ne 0 ]"
FBMISS="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 --prd "$TMPROOT/nope.md" 2>&1 )"; fbmrc=$?
check "a --prd path that does not exist is refused" "[ $fbmrc -ne 0 ]"
PRD_NOSEC="$TMPROOT/bug-nosections.md"
printf '# Mission: a thing\n\n**Type:** bug\n**Acceptance Criteria:**\n- Observed live: it broke.\n' >"$PRD_NOSEC"
FBNOSEC="$( LOG_STUB="$STUBS/log-files.sh" ap "$RFB" file-bug --parent lcars-20261001-010 --prd "$PRD_NOSEC" 2>&1 )"; fbnsrc=$?
check "a PRD missing the sections file.sh requires is refused HERE, not later" \
  "[ $fbnsrc -ne 0 ]"
check "the refusal names a missing section" \
  "printf '%s' \"\$FBNOSEC\" | qgrep -qiE 'Out of Scope|Constraints|Goal'"

# ==========================================================================
# S234.4 policy — ONE action, and an override that is recorded with its evidence
# ==========================================================================
# Playbook § 4: high -> merge; medium -> merge + follow-ups; low for a PRODUCT
# reason -> send it back; low for INFRASTRUCTURE only -> fix it, verify that
# point live, and record an OVERRIDE. In practice Number One scored every CLI
# or integration milestone low for reasons it could not reach, so the LIVE
# CHECK decided every merge — which is why a live-check of `bugs` sends back
# whatever Number One said.
echo "-- S234.4 policy --"
RPO="$(new_repo)"
ap "$RPO" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RPO" lcars-20261001-020 verify
# A real evidence file, because an override whose evidence path does not
# exist is the `deploy succeeded` of overrides.
LCEVOK="$TMPROOT/override-evidence.txt"
printf 'ran the step by hand: python3 missing on the runner\n' >"$LCEVOK"
polact() { # <args…> → the ACTION line's value
  ap "$RPO" policy "$@" 2>&1 | sed -n 's/^ACTION: //p'
}
check "high + live-check pass -> merge" \
  "[ \"\$(polact --verdict high --live-check pass)\" = merge ]"
check "medium + live-check pass -> merge+follow-ups" \
  "[ \"\$(polact --verdict medium --live-check pass)\" = 'merge+follow-ups' ]"
check "low for a PRODUCT reason + live-check pass -> send-back" \
  "[ \"\$(polact --verdict low --reason product --live-check pass)\" = 'send-back' ]"
check "low for INFRASTRUCTURE only + live-check pass -> override" \
  "[ \"\$(polact --verdict low --reason infrastructure --live-check pass --evidence '$LCEVOK')\" = override ]"
check "live-check BUGS sends back even on a HIGH verdict (the live check decides)" \
  "[ \"\$(polact --verdict high --live-check bugs)\" = 'send-back' ]"
check "live-check BUGS sends back on medium too" \
  "[ \"\$(polact --verdict medium --live-check bugs)\" = 'send-back' ]"
POL1="$(ap "$RPO" policy --verdict high --live-check pass 2>&1)"
check "policy prints EXACTLY ONE action line" \
  "[ \"\$(printf '%s\n' \"\$POL1\" | grep -c '^ACTION: ')\" = 1 ]"
check "policy cites the AUTOPILOT.md heading for the action" \
  "printf '%s' \"\$POL1\" | qgrep -qF 'PLAYBOOK: ##'"
check "policy prints the commands that carry the action out" \
  "printf '%s' \"\$POL1\" | qgrep -qE '^THEN:'"
POLSB="$(ap "$RPO" policy --verdict low --reason product --live-check bugs 2>&1)"
check "the send-back action spells out file-bug -> resolve-logs -> re-verify -> respond" \
  "printf '%s' \"\$POLSB\" | qgrep -qF 'file-bug' && printf '%s' \"\$POLSB\" | qgrep -qF 'resolve-logs' && printf '%s' \"\$POLSB\" | qgrep -qiF 'different data'"
POLNOR="$(ap "$RPO" policy --verdict low --live-check pass 2>&1)"; polnrc=$?
check "a LOW verdict with no --reason is REFUSED (the action depends on it)" \
  "[ $polnrc -ne 0 ]"
check "that refusal names both reasons" \
  "printf '%s' \"\$POLNOR\" | qgrep -qF 'product' && printf '%s' \"\$POLNOR\" | qgrep -qF 'infrastructure'"
# A FRESH repo for the ledger half: the table row above already recorded one
# override, and "no override was recorded" must mean exactly that.
RPO2="$(new_repo)"
ap "$RPO2" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RPO2" lcars-20261001-020 verify
OVL="$RPO2/.git/lcars/autopilot-overrides.jsonl"
POLNOE="$(ap "$RPO2" policy --verdict low --reason infrastructure --live-check pass 2>&1)"; polnerc=$?
check "an OVERRIDE with no --evidence is REFUSED (an unevidenced override is a shrug)" \
  "[ $polnerc -ne 0 ]"
check "the refusal names --evidence" \
  "printf '%s' \"\$POLNOE\" | qgrep -qF -- '--evidence'"
POLBADE="$(ap "$RPO2" policy --verdict low --reason infrastructure --live-check pass --evidence "$TMPROOT/not-there.txt" 2>&1)"; polberc=$?
check "an --evidence path that does not EXIST is refused" "[ $polberc -ne 0 ]"
check "no override was recorded for either refusal" "[ ! -f '$OVL' ]"
POLOV="$(ap "$RPO2" policy --verdict low --reason infrastructure --live-check pass \
           --mission lcars-20261001-020 --evidence "$LCEVOK" --note 'the runner had no python3' 2>&1)"; polovrc=$?
check "the override is accepted"              "[ $polovrc -eq 0 ]"
check "the override is RECORDED in autopilot-overrides.jsonl" "[ -s '$OVL' ]"
check "the recorded override carries the EVIDENCE PATH" \
  "qgrep -qF '$LCEVOK' '$OVL'"
check "the recorded override carries the mission, the verdict and the reason" \
  "qgrep -qF 'lcars-20261001-020' '$OVL' && qgrep -qF 'infrastructure' '$OVL' && qgrep -qF '\"verdict\": \"low\"' '$OVL'"
check "the recorded override carries the note the buddy wrote" \
  "qgrep -qF 'the runner had no python3' '$OVL'"
check "a MERGE action records NO override" \
  "ap '$RPO2' policy --verdict high --live-check pass >/dev/null 2>&1; [ \"\$(wc -l <'$OVL' | tr -d ' ')\" = 1 ]"
POLBADV="$(ap "$RPO" policy --verdict excellent --live-check pass 2>&1)"; polbvrc=$?
check "an unknown verdict is refused"         "[ $polbvrc -ne 0 ]"
POLBADL="$(ap "$RPO" policy --verdict high --live-check maybe 2>&1)"; polblrc=$?
check "an unknown live-check verdict is refused" "[ $polblrc -ne 0 ]"
POLNOLC="$(ap "$RPO" policy --verdict high 2>&1)"; polnlrc=$?
check "policy with NO --live-check is refused (it is half the table)" "[ $polnlrc -ne 0 ]"
# The verdict can come from Number One's own file rather than the flag.
mkdir -p "$RPO/.git/lcars/missions/lcars-20261001-020/xo"
printf '{"score":"medium","summary":"s"}\n' >"$RPO/.git/lcars/missions/lcars-20261001-020/xo/verdict.json"
check "with --mission and no --verdict it reads Number One's own xo/verdict.json" \
  "[ \"\$(polact --mission lcars-20261001-020 --live-check pass)\" = 'merge+follow-ups' ]"
check "policy prints the whole table so the buddy can see the row it took" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qF 'merge+follow-ups'"
# AN UNESCAPED BACKTICK IN A `say` RAN AS A COMMAND. `policy --table` printed
# "command not found: bugs" into the middle of the merge table and swallowed the
# word it was explaining. Any `say "…\`x\`…"` has this hazard, so the sweep is
# over the WHOLE driver's output, not just this line.
check "no subcommand's output leaks a shell error (an unescaped backtick in a say)" \
  "! ap '$RPO' policy --table 2>&1 | qgrep -qiE 'command not found|No such file or directory'"
check "the table's explanation keeps the word it is explaining" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qF 'live check sends back a high'"
check "no unescaped backtick inside any double-quoted \`say\` in the driver" \
  "! qgrep -qE 'say \"[^\"]*[^\\\\]\`' '$SCRIPT'"

# ==========================================================================
# S234.5 report — one page, rendered from the ledgers, byte for byte
# ==========================================================================
# A GOLDEN FILE, and no publish from a test: the renderer's job is to turn the
# RECORDS into the page, so the test fixes both. Nothing in the output comes
# from a clock — a report that changes when nothing changed cannot be reviewed.
echo "-- S234.5 report --"
RRP="$(new_repo)"
printf 'M0 the CLI\nM1 the page\n' >"$TMPROOT/spec-rpt.md"
ap "$RRP" init --spec "$TMPROOT/spec-rpt.md" --scope M0,M1 >/dev/null 2>&1
ap "$RRP" record startedAt 2026-10-01T09:00:00-07:00 >/dev/null 2>&1
new_mission "$RRP" lcars-20261001-001 done
new_mission "$RRP" lcars-20261001-002 verify
new_mission "$RRP" bug-001 done bug lcars-20261001-001
new_mission "$RRP" bug-002 done bug lcars-20261001-002
new_mission "$RRP" bug-003 implement bug lcars-20261001-002
ap "$RRP" record missions.M0.id lcars-20261001-001 >/dev/null 2>&1
ap "$RRP" record missions.M1.id lcars-20261001-002 >/dev/null 2>&1
mkdir -p "$RRP/.git/lcars/missions/lcars-20261001-001/xo" \
         "$RRP/.git/lcars/missions/lcars-20261001-001/live-check" \
         "$RRP/.git/lcars/missions/lcars-20261001-002/live-check"
printf '{"score":"medium","summary":"s"}\n' >"$RRP/.git/lcars/missions/lcars-20261001-001/xo/verdict.json"
: >"$RRP/.git/lcars/missions/lcars-20261001-001/live-check/02-desktop.png"
: >"$RRP/.git/lcars/missions/lcars-20261001-001/live-check/03-phone.png"
: >"$RRP/.git/lcars/missions/lcars-20261001-001/live-check/01-help.txt"
: >"$RRP/.git/lcars/missions/lcars-20261001-002/live-check/02-desktop.png"
ap "$RRP" record missions.M0.liveCheck pass >/dev/null 2>&1
ap "$RRP" record missions.M1.liveCheck bugs >/dev/null 2>&1
ap "$RRP" ledger overrides '{"mission":"lcars-20261001-002","verdict":"low","reason":"infrastructure","evidence":"live-check/09-override.txt","note":"the runner had no python3"}' >/dev/null 2>&1
RPOUT="$(ap "$RRP" report 2>&1)"; rprc=$?
RPHTML="$RRP/.git/lcars/autopilot/report.html"
check "report exits 0"                        "[ $rprc -eq 0 ]"
check "report prints the path it wrote"       "printf '%s' \"\$RPOUT\" | qgrep -qF '$RPHTML'"
check "report writes the page inside .git/lcars (never the working tree)" "[ -s '$RPHTML' ]"
GOLDEN="$TMPROOT/report.golden.html"
cat >"$GOLDEN" <<GOLDENEOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Autopilot progress</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
  table { border-collapse: collapse; width: 100%; }
  td, th { border-bottom: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }
  .pass { color: #0a7a2f; } .bugs { color: #c0392b; } .none { color: #888; }
  ul { padding-left: 1.2rem; }
  @media (max-width: 500px) { body { margin: .75rem; } }
</style></head>
<body>
<h1 id="report-title">Autopilot progress</h1>
<p id="report-meta">spec: $TMPROOT/spec-rpt.md &middot; started: 2026-10-01T09:00:00-07:00</p>
<table id="report-milestones">
<thead><tr><th>Milestone</th><th>Mission</th><th>Stage</th><th>Number One</th><th>Live check</th><th>Shots</th><th>Bugs filed</th><th>Bugs fixed</th></tr></thead>
<tbody>
<tr id="row-M0"><td>M0</td><td>lcars-20261001-001</td><td>done</td><td>medium</td><td class="pass">pass</td><td>2</td><td>1</td><td>1</td></tr>
<tr id="row-M1"><td>M1</td><td>lcars-20261001-002</td><td>verify</td><td class="none">-</td><td class="bugs">bugs</td><td>1</td><td>2</td><td>1</td></tr>
</tbody>
</table>
<h2 id="shots-title">Screenshots</h2>
<ul id="shots">
<li>M0 <a href="../missions/lcars-20261001-001/live-check/02-desktop.png">02-desktop.png</a></li>
<li>M0 <a href="../missions/lcars-20261001-001/live-check/03-phone.png">03-phone.png</a></li>
<li>M1 <a href="../missions/lcars-20261001-002/live-check/02-desktop.png">02-desktop.png</a></li>
</ul>
<h2 id="bugs-title">Bugs filed</h2>
<ul id="bugs">
<li>M0 bug-001 &mdash; mission bug-001 &mdash; done</li>
<li>M1 bug-002 &mdash; mission bug-002 &mdash; done</li>
<li>M1 bug-003 &mdash; mission bug-003 &mdash; implement</li>
</ul>
<h2 id="overrides-title">Overrides recorded</h2>
<ul id="overrides">
<li>lcars-20261001-002 &mdash; low / infrastructure &mdash; the runner had no python3 &mdash; evidence: live-check/09-override.txt</li>
</ul>
</body></html>
GOLDENEOF
if diff -u "$GOLDEN" "$RPHTML" >"$TMPROOT/report.diff" 2>&1; then
  ok "report matches the golden file byte for byte"
else
  bad "report does not match the golden file"
  head -40 "$TMPROOT/report.diff"
fi
check "the only timestamp on the page is the RECORDED startedAt (no clock)" \
  "qgrep -qF '2026-10-01T09:00:00-07:00' '$RPHTML' && [ \"\$(grep -cE '[0-9]{2}:[0-9]{2}:[0-9]{2}' '$RPHTML')\" = 1 ]"
RPOUT2="$(ap "$RRP" report --out "$TMPROOT/elsewhere.html" 2>&1)"
check "--out renders somewhere else"          "[ -s '$TMPROOT/elsewhere.html' ]"
ap "$RRP" report --out "$TMPROOT/elsewhere2.html" >/dev/null 2>&1
check "a re-render to the SAME shape of path is byte-identical (nothing drifts)" \
  "diff -q '$TMPROOT/elsewhere.html' '$TMPROOT/elsewhere2.html' >/dev/null"
# S234 round 1, defect 5: the screenshot hrefs were written relative to the
# DEFAULT report dir (.git/lcars/autopilot), so they resolved only from there
# and every link was DEAD under any other --out. The captain opens whatever
# path the report was written to; a link that 404s there is a shot nobody
# looks at, which is the one thing the live check exists to produce.
links_resolve() { python3 - "$1" <<'PY'
import os, re, sys
p = sys.argv[1]
base = os.path.dirname(os.path.abspath(p))
hrefs = re.findall(r'<a href="([^"]+)"', open(p).read())
if not hrefs:
    print("NO LINKS AT ALL — a vacuous pass")
    sys.exit(1)
dead = [h for h in hrefs if not os.path.exists(os.path.join(base, h))]
for h in dead:
    print("DEAD: %s (opened from %s)" % (h, base))
sys.exit(1 if dead else 0)
PY
}
check "the DEFAULT report's screenshot links resolve from the dir it was written to" \
  "links_resolve '$RPHTML'"
mkdir -p "$TMPROOT/report-elsewhere/deeper"
ap "$RRP" report --out "$TMPROOT/report-elsewhere/deeper/report.html" >/dev/null 2>&1
check "--out to another directory writes links that RESOLVE THERE (not relative to the default dir)" \
  "links_resolve '$TMPROOT/report-elsewhere/deeper/report.html'"
REMPTY="$(new_repo)"
ap "$REMPTY" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
check "a report with nothing recorded yet still renders (no crash, no fake data)" \
  "ap '$REMPTY' report >/dev/null 2>&1 && qgrep -qF 'none yet' '$REMPTY/.git/lcars/autopilot/report.html'"
check "an epoch startedAt (what \`init\` records) renders readably, not as a raw integer" \
  "qgrep -qE 'started: 20[0-9]{2}-[0-9]{2}-[0-9]{2}T' '$REMPTY/.git/lcars/autopilot/report.html'"
check "report NEVER publishes an artifact from a test" \
  "! qgrep -qiE 'claude\.ai/artifact|Artifact tool' '$SCRIPT'"

# ==========================================================================
# S234.6 the prose contracts — bug-prd.md and AUTOPILOT.md's two new sections
# ==========================================================================
echo "-- S234.6 prose contract (INSTALLED files) --"
BPRD="$INSTALLED_DIR/bug-prd.md"
check "bug-prd.md is installed at $BPRD"      "[ -f '$BPRD' ]"
check "bug-prd.md carries every section file.sh requires" \
  "( for sec in 'Mission title' 'Type' 'Goal' 'Acceptance Criteria' 'Out of Scope' 'Constraints'; do qgrep -qF \"\$sec\" '$BPRD' || exit 1; done )"
check "bug-prd.md makes AC #1 \`Observed live:\` and says it is MANDATORY" \
  "qgrep -qF 'Observed live:' '$BPRD' && qgrep -qiE 'mandator|must be|not optional' '$BPRD'"
check "bug-prd.md demands the EXACT output and the identifiers" \
  "qgrep -qiE 'exact (output|command)' '$BPRD' && qgrep -qiF 'identifier' '$BPRD'"
check "bug-prd.md carries the declared Seam field the validator reads" \
  "qgrep -qF '**Seam:**' '$BPRD'"
check "bug-prd.md demands a ROUND-TRIP criterion at a producer/consumer seam" \
  "qgrep -qi 'round-trip' '$BPRD' && qgrep -qiE 'no hand-written fixture|both real halves' '$BPRD'"
check "bug-prd.md says the title states the BROKEN BEHAVIOUR as a sentence" \
  "qgrep -qiE 'broken behaviour|broken behavior' '$BPRD'"
check "bug-prd.md says Goal states the CORRECTED INVARIANT" \
  "qgrep -qiE 'corrected invariant' '$BPRD'"
check "bug-prd.md names \`autopilot.sh file-bug\` as how it is filed" \
  "qgrep -qF 'file-bug' '$BPRD'"
check "bug-prd.md carries a filled-in EXAMPLE, not just a skeleton" \
  "qgrep -qiE 'example' '$BPRD'"

# --- the exemplar contract (S234 round 1, defects 3 and 4) ----------------
# D3: the round pointed testers at the weekend archive PRD
# `canvas-weekend-2026-09-26/evidence/filed-prds/bug-020-1.md` and told them to
# match it LINE FOR LINE. `file-bug` REFUSES that file on three counts — no
# `Out of Scope`, no `**Seam:**`, and an AC #1 reading `Observed (real code, no
# stubs on the contract):` instead of `Observed live:` — because it predates
# this template. The validator is right; the POINTER was wrong, and a tester
# who obeyed it produced a PRD that could not be filed. So the one exemplar is
# bug-prd.md's OWN worked example, and this suite proves it by running the
# round's own gate over it.
# D4: that worked example WAS the fixture product's own seam fault, named down
# to the two field names and the default value — anyone who read the template
# before working the fixture got that fault free, and finding it then proved
# nothing about the checklists.
EXAMPLE_PRD="$TMPROOT/bug-prd-worked-example.md"
python3 - "$BPRD" "$EXAMPLE_PRD" <<'PY' 2>/dev/null || :
import re, sys
try:
    t = open(sys.argv[1]).read()
except Exception:
    t = ""
m = re.search(r'#+[ \t]*A filled-in example.*?```markdown\n(.*?)\n```', t, re.S)
open(sys.argv[2], "w").write(m.group(1) if m else "")
PY
check "bug-prd.md's worked example is extractable as a PRD of its own" \
  "[ -s '$EXAMPLE_PRD' ]"
RWE="$(new_repo)"
ap "$RWE" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RWE" lcars-20261001-030 verify
FBEX="$( LOG_STUB="$STUBS/log-files.sh" ap "$RWE" file-bug --parent lcars-20261001-030 --prd "$EXAMPLE_PRD" 2>&1 )"; fbexrc=$?
if [ "$fbexrc" -ne 0 ]; then printf '%s\n' "$FBEX" | sed 's/^/    /' | head -12; fi
check "the exemplar bug-prd.md points at is FILEABLE by \`file-bug\`'s own validator" \
  "[ $fbexrc -eq 0 ]"
check "bug-prd.md does NOT send the reader at the archive PRD the validator refuses" \
  "! qgrep -qF 'bug-020-1' '$BPRD'"
check "bug-prd.md says in one line WHY the weekend archive PRDs do not conform (they predate the template)" \
  "qgrep -qiF 'filed-prds' '$BPRD' && qgrep -qiE 'predate|pre-date|older than this template' '$BPRD'"
check "the worked example is NOT the fixture product's own seam fault (it hands the tester no answer)" \
  "! qgrep -qE 'host_of|\"origin\"|pkg/model\.py|pkg/render\.py|relay\.py' '$EXAMPLE_PRD'"
check "the worked example is still CONCRETE — a quoted command, a quoted output and real identifiers" \
  "qgrep -qF 'Observed live:' '$EXAMPLE_PRD' && qgrep -qi 'round-trip' '$EXAMPLE_PRD' && qgrep -qF '**Seam:**' '$EXAMPLE_PRD'"
check "AUTOPILOT.md names bug-prd.md's WORKED EXAMPLE as the one style exemplar" \
  "qgrep -qiF 'worked example' '$APM'"
check "AUTOPILOT.md does NOT point at the archive PRD the validator refuses" \
  "! qgrep -qF 'bug-020-1' '$APM'"

check "AUTOPILOT.md's live-verification section is no longer an S234 STUB" \
  "! qgrep -qiE 'S234 — STUB|S234 - STUB' '$APM'"
check "AUTOPILOT.md points at the shared checklists by path" \
  "qgrep -qF 'lcars-run/live-check' '$APM'"
# S277: command-name literal ONLY. AUTOPILOT.md now names the on-PATH `lcars-autopilot <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `autopilot.sh`.
check "AUTOPILOT.md names the live-check verb" \
  "qgrep -qF 'lcars-autopilot live-check' '$APM'"
check "AUTOPILOT.md names the workflow-run verb for every workflow a mission adds" \
  "qgrep -qF 'lcars-autopilot workflow-run' '$APM'"
check "AUTOPILOT.md names the file-bug verb and the template" \
  "qgrep -qF 'lcars-autopilot file-bug' '$APM' && qgrep -qF 'bug-prd.md' '$APM'"
check "AUTOPILOT.md names the policy verb" \
  "qgrep -qF 'lcars-autopilot policy' '$APM'"
check "AUTOPILOT.md names the report verb" \
  "qgrep -qF 'lcars-autopilot report' '$APM'"
check "AUTOPILOT.md carries the whole merge table: all four actions" \
  "( for a in 'merge' 'follow-ups' 'send-back' 'override'; do qgrep -qF \"\$a\" '$APM' || exit 1; done )"
check "AUTOPILOT.md says a LOW for infrastructure only is fixed, verified live, and OVERRIDDEN" \
  "qgrep -qiE 'infrastructure' '$APM' && qgrep -qF 'autopilot-overrides.jsonl' '$APM'"
check "AUTOPILOT.md says THE MERGE IS THE BUDDY'S CALL — Number One recommends" \
  "qgrep -qiE \"buddy's call|the buddy decides\" '$APM' && qgrep -qi 'recommend' '$APM'"
check "AUTOPILOT.md says every override is recorded WITH its evidence path" \
  "qgrep -qiE 'evidence path' '$APM'"
check "AUTOPILOT.md keeps the send-back loop: file-bug -> resolve-logs -> re-verify with different data -> respond -> land" \
  "qgrep -qF 'resolve-logs' '$APM' && qgrep -qiF 'different data' '$APM'"
check "AUTOPILOT.md says the anchor rule and the seam constraint are HARNESS DEFAULTS now (S236/S237), not the mode's job" \
  "qgrep -qiE 'harness default' '$APM' && qgrep -qE 'S236|S237' '$APM'"
check "AUTOPILOT.md does NOT tell the mode to inject the anchor rule into every PRD (that would duplicate S236/S237)" \
  "! qgrep -qiE 'inject the anchor rule|add the anchor rule' '$APM'"
check "AUTOPILOT.md still forbids the hand-merge after the rewrite" \
  "qgrep -qiE 'never (merge by hand|hand-merge)' '$APM'"
check "AUTOPILOT.md still tells the model to run the live check from a DETACHED worktree" \
  "qgrep -qiF 'detached' '$APM'"

# ==========================================================================
# ZERO SPEND — the PATH shim must never have been reached
# ==========================================================================
echo
echo "-- worker spend --"
# THE FUSE, PROVEN LIVE. The tally above is only meaningful if the shim would
# actually have recorded a worker spawn. Probe it once into a SEPARATE log so
# the real tally stays untouched, and assert both halves of the guard: that an
# invocation is recorded at all, and that a `--model` one is marked billable.
fuse_probe="$TMPROOT/fuse-probe.log"
: >"$fuse_probe"
check "SPEND FUSE: a counting \`claude\` shim is first on PATH" \
  "[ \"\$(command -v claude)\" = '$SHIM_DIR/claude' ]"
check "SPEND FUSE: a counting \`copilot\` shim is first on PATH" \
  "[ \"\$(command -v copilot)\" = '$SHIM_DIR/copilot' ]"
( LCARS_DRIVE_SHIM_LOG="$fuse_probe" claude --model opus -p hi >/dev/null 2>&1 )
check "SPEND FUSE: the shim RECORDS an invocation (so a 0 tally means something)" \
  "[ -s '$fuse_probe' ]"
check "SPEND FUSE: the shim marks a --model invocation as billable" \
  "qgrep -q 'model=yes' '$fuse_probe'"
check "SPEND FUSE: the probe did not pollute the real tally" \
  "[ \"\$(wc -l <'$LCARS_DRIVE_SHIM_LOG' | tr -d ' ')\" = 0 ]"

shim_calls="$(wc -l <"$LCARS_DRIVE_SHIM_LOG" | tr -d ' ')"
shim_model="$( { grep -c 'model=yes' "$LCARS_DRIVE_SHIM_LOG" 2>/dev/null || true; } | head -1 )"
[ -n "$shim_model" ] || shim_model=0
echo "  PATH shim invocations: $shim_calls   carrying --model (would have billed): $shim_model"
check "zero worker CLI invocations"          "[ '$shim_calls' = 0 ]"
check "zero billed (--model) invocations"    "[ '$shim_model' = 0 ]"

# ==========================================================================
# THE CONTRACT CONTROL — prove the installed-file checks can actually FAIL
# ==========================================================================
# A contract test that cannot tell a real install from an empty directory is
# worse than no test: with the old repo-copy fallback this suite printed
# `PASS AUTOPILOT.md is installed` and 162/0 against an EMPTY skills dir, with
# the file absent. So re-run THIS suite once against an empty prefix and require
# it to go red for exactly that reason. LCARS_AP_NO_NEST stops the recursion.
if [ -z "${LCARS_AP_NO_NEST:-}" ]; then
  echo
  echo "-- contract control (the same suite against an EMPTY skills dir) --"
  EMPTY_DEST="$TMPROOT/empty-skills"
  mkdir -p "$EMPTY_DEST/lcars-buddy"
  nested="$TMPROOT/nested.txt"
  LCARS_AP_NO_NEST=1 LCARS_SKILLS_DEST="$EMPTY_DEST" \
    bash "$DIR/$(basename "${BASH_SOURCE[0]}")" >"$nested" 2>&1 </dev/null
  nrc=$?
  check "against an empty skills dir the suite goes RED (it can fail)" "[ $nrc -ne 0 ]"
  check "it fails on the ABSENT AUTOPILOT.md, naming the path it looked at" \
    "qgrep -qE 'FAIL.*AUTOPILOT.md is installed at .*empty-skills' '$nested'"
  check "it fails on the ABSENT SKILL.md too" \
    "qgrep -qE 'FAIL.*SKILL.md is installed at .*empty-skills' '$nested'"
  check "and it does NOT print a PASS for either absent file (the false green)" \
    "! qgrep -qE 'PASS.*(AUTOPILOT|SKILL).md is installed' '$nested'"
  check "the empty-dir run is NOT byte-identical to the real one (the old bug)" \
    "[ \"\$(grep -c '^  .PASS' '$nested')\" != \"$pass\" ]"
fi

echo
echo "=== lcars-buddy-autopilot: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
