#!/usr/bin/env bash
#
# tests/lcars-ech.test.sh — the ECH half of `lcars eeh`
# (skill source: skills/lcars-eeh/ech.sh + HOLOGRAM-COMMAND-MODE.md + SKILL.md § 3).
#
# WHAT IS UNDER TEST. `lcars eeh` gained a second half: a mode the captain
# starts with "run it for me <spec>" and walks away from. The JUDGEMENT in that
# mode is prose the MODEL follows (HOLOGRAM-COMMAND-MODE.md); everything SEQUENCEABLE is
# `ech.sh`, a token-free bash driver OVER the existing LCARS verbs. This
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
#   LCARS_ECH_CWD        the repo to operate on        (default $PWD)
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
# Usage: bash tests/lcars-ech.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"

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

# qgrep: see tests/lcars-eeh.test.sh for the full reasoning. Draining stdin
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
  LCARS_ECH_CWD="$repo" \
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
  LCARS_GH_BIN="${PF_GH:-$PFGH_YES}" \
  COPILOT_ALLOW_ALL="${PF_ALLOW_ALL-true}" \
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
s="$LCARS_ECH_CWD/.git/lcars/missions/$m/state.json"
[ -f "$s" ] && python3 - "$s" <<PY
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["stage"]="done"; json.dump(d,open(p,"w"))
PY'
stub "$STUBS/notify.sh"       0
# THE FORGE-CLI STUBS (S300 fix1). `gh auth status` is a preflight check now —
# no login, no pull request — so the suite must declare which answer it is
# measuring. A real `gh` would make the arms depend on the machine that runs
# them, which is the opposite of a measurement.
PFGH_YES="$STUBS/gh-logged-in"; printf '#!/usr/bin/env bash\nexit 0\n' >"$PFGH_YES"
PFGH_NO="$STUBS/gh-logged-out"; printf '#!/usr/bin/env bash\nprintf "not logged in\\n" >&2\nexit 1\n' >"$PFGH_NO"
chmod +x "$PFGH_YES" "$PFGH_NO"
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
echo "=== lcars ech: the driver ==================================="
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
check "S260 Verify: repo playbook makes the EEH's check a standing job, never a fallback" \
  "qgrep -qF 'This is your standing job, never a fallback.' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"

usage260="$(ap "$RE" 2>&1)"; usagerc260=$?
# S277: command-name literal ONLY. HOLOGRAM-COMMAND-MODE.md now names the on-PATH `lcars-ech <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `ech.sh`.
check "S260 usage: no arguments print help with exit 1 and no shell errors" \
  "[ $usagerc260 -eq 1 ] && printf '%s' \"\$usage260\" | qgrep -q '^Usage: lcars-ech' && ! printf '%s' \"\$usage260\" | qgrep -q 'command not found'"
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
  "qgrep -qF 'holodeck_start' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md' && qgrep -qF 'holodeck_say' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md' && qgrep -qF 'holodeck_end' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md' && qgrep -qF 'mockup.html' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md' && qgrep -qF 'State which path you took.' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"

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
drv="$(LCARS_ECH_CWD="$R3" STUB_LOG="$STUB_LOG" \
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
check "heartbeat uses crontab (not a harness tool)" "qgrep -q 'ech.sh' '$CRONFILE' || qgrep -q 'the ECH' '$CRONFILE'"
check "the cron line calls 'stalled'"        "qgrep -q 'stalled' '$CRONFILE'"
check "heartbeat kept the captain's other cron entries" \
  "qgrep -q 'someone-elses-job' '$CRONFILE'"
check "heartbeat owns exactly ONE line"      "[ \"\$(grep -c 'LCARS-ECH' '$CRONFILE')\" = 1 ]"
ap "$R11" heartbeat install >/dev/null 2>&1
check "a second install is idempotent (still ONE line)" \
  "[ \"\$(grep -c 'LCARS-ECH' '$CRONFILE')\" = 1 ]"
ap "$R11" heartbeat remove >/dev/null 2>&1
check "heartbeat remove GENUINELY removes the line" \
  "! qgrep -q 'LCARS-ECH' '$CRONFILE'"
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
check "install works against an EMPTY crontab" "qgrep -q 'LCARS-ECH' '$CRONFILE'"
rmo="$(ap "$R11" heartbeat remove 2>&1)"; rcrm=$?
check "remove exits 0 when ours is the ONLY line (empty table is a success)" \
  "[ $rcrm -eq 0 ]"
check "that removal does NOT claim crontab refused the table" \
  "! printf '%s' \"\$rmo\" | qgrep -qi 'refused'"
check "the line really is gone (the empty table was written)" \
  "! qgrep -q 'LCARS-ECH' '$CRONFILE'"
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
printf '17 * * * * cd /x && bash /x/ech.sh stalled # LCARS-ECH %s\n' "$R11" >"$CRONFILE"
rmo2="$(LCARS_ECH_CWD="$R11" STUB_LOG="$STUB_LOG" \
        LCARS_CRONTAB_BIN="$STUBS/crontab-sticky" bash "$SCRIPT" heartbeat remove 2>&1 </dev/null)"; rcrm2=$?
check "remove still REFUSES to claim success while the line is present" \
  "[ $rcrm2 -ne 0 ] && printf '%s' \"\$rmo2\" | qgrep -qi 'still present'"
: >"$CRONFILE"

# ==========================================================================
# 9. Hygiene of the script itself (the §9 mistakes, as assertions)
# ==========================================================================
echo "-- 9. script hygiene --"
check "ech.sh exists and is executable" "[ -x '$SCRIPT' ]"
check "ech.sh parses under bash"        "bash -n '$SCRIPT'"
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
  LCARS_ECH_CWD="$repo" STUB_LOG="$STUB_LOG" \
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
# included. HOLOGRAM-COMMAND-MODE.md § 9 promises exactly four things reach him.
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
# interrupt-budget violation D6 exists to prevent (HOLOGRAM-COMMAND-MODE.md § 9: "exactly
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
# `.pending`, which HOLOGRAM-COMMAND-MODE.md § 9 still tells the model to write, into the
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
# hand-written one (HOLOGRAM-COMMAND-MODE.md § 9 tells the model to write exactly that shape
# for a product call, a scope change or a standing-rule conflict — the questions
# that MOST need the captain) was MASKED: zero rows in `status`, zero rows in
# `next`, and the header said "open questions for the captain: 1" while two were
# open. It masked precisely when the ECH was busiest. This display
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
# ~/.claude/skills/lcars-eeh/. A test over the repo copy proves the source and
# says nothing about what runs. install.sh symlinks, so the installed copy is
# the repo copy — but asserting the INSTALLED path is what catches a skill that
# was never installed, or installed from a different clone.
INSTALLED_DIR="${LCARS_SKILLS_DEST:-$HOME/.claude/skills}/lcars-eeh"
SK="$INSTALLED_DIR/SKILL.md"
APM="$INSTALLED_DIR/HOLOGRAM-COMMAND-MODE.md"
# NO FALLBACK TO THE REPO COPY. A fallback made these two checks print PASS
# against a genuinely EMPTY skills dir — 162/0, byte-identical to a real run,
# with the file absent — which destroyed the very intent stated above. An absent
# installed file now FAILS, naming the path it looked at. The flip is proved by
# the CONTROL at the bottom of this file.
check "HOLOGRAM-COMMAND-MODE.md is installed at $APM" "[ -f '$APM' ]"
check "SKILL.md is installed at $SK"      "[ -f '$SK' ]"

# The driver publishes its own action→heading table. Every heading it names MUST
# exist, verbatim, in the installed HOLOGRAM-COMMAND-MODE.md. That is the anti-drift lock:
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
  check "HOLOGRAM-COMMAND-MODE.md carries the heading for '$action'" \
    "qgrep -qF -- '$heading' '$APM'"
done <<EOF
$(printf '%s\n' "$pb")
EOF
check "the table is not empty"             "[ $nactions -ge 5 ]"

# The specific prose the mode cannot work without.
check "HOLOGRAM-COMMAND-MODE.md § 3 is pointed at from SKILL.md" "qgrep -qF 'HOLOGRAM-COMMAND-MODE.md' '$SK'"
check "SKILL.md gained a '## 3.' section"            "qgrep -qE '^## 3\\.' '$SK'"
check "SKILL.md § 3 carries the trigger phrase"      "qgrep -qiF 'run it for me' '$SK'"
check "SKILL.md still has § 1 (ride-along) UNCHANGED in name" \
  "qgrep -qF '## 1. Run the diagnostic collector and show it verbatim' '$SK'"
check "SKILL.md still has § 2 (orchestrated fix)" \
  "qgrep -qF '## 2. When it' '$SK'"
check "SKILL.md points at ORCHESTRATION.md once, and does not restate the loop" \
  "[ \"\$(grep -c 'ORCHESTRATION.md' '$APM')\" -le 2 ]"
check "HOLOGRAM-COMMAND-MODE.md names ech.sh as the state's home" "qgrep -qF 'autopilot.json' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md states the HEARTBEAT is crontab" \
  "qgrep -qF 'crontab' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md does NOT name a harness-only tool as the heartbeat" \
  "! qgrep -qF 'CronCreate' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says WHY crontab and not a harness tool" \
  "qgrep -qiE 'not inside Claude Code|outside Claude Code|people who are not' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the interrupt budget"   "qgrep -qiF 'interrupt budget' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the two-parallel rule"  "qgrep -qiE 'two (missions|at a time|parallel)' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the memory rule (re-read after compaction)" \
  "qgrep -qiF 'compaction' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the communication rules" \
  "qgrep -qiE 'final message of the turn' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the deadline re-forecast rule" \
  "qgrep -qiF 're-forecast' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the copy-paste-safe secret instruction" \
  "qgrep -qF 'pbpaste | gh secret set' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md forbids the hand-merge in writing" \
  "qgrep -qiE 'never (merge by hand|hand-merge)' '$APM'"
# S277: command-name literal ONLY. HOLOGRAM-COMMAND-MODE.md now names the on-PATH `lcars-ech <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `ech.sh`.
check "HOLOGRAM-COMMAND-MODE.md tells the model to run \`ech.sh next\`" \
  "qgrep -qF 'lcars-ech next' '$APM'"
# --- the prose for the fix-round cures, so script and playbook cannot drift --
check "HOLOGRAM-COMMAND-MODE.md names ALL SIX sections file.sh requires" \
  "for sec in 'Mission title' 'Type' 'Goal' 'Acceptance Criteria' 'Out of Scope' 'Constraints'; do qgrep -qF \"\$sec\" '$APM' || exit 1; done"
check "HOLOGRAM-COMMAND-MODE.md gives alignment question 3 a key to record its answer in" \
  "qgrep -qF 'record deploy' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md documents the DECLINED captain-only step state" \
  "qgrep -qF '\"declined\":true' '$APM' && qgrep -qiF 'never \`done: true\`' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md documents \`ech.sh answered\` as how a question closes" \
  "qgrep -qF 'lcars-ech answered' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says re-raising an OPEN question is a no-op" \
  "qgrep -qi 'raising the same question twice' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says questions are a LEDGER, not one slot" \
  "qgrep -qiE 'ledger, not a slot|every question ever raised' '$APM'"
# --- S233: the prose must instruct the VERB, never a hand-edit of `pending` --
# The playbook telling the model to hand-write into `.pending` is what made that
# field load-bearing storage, and that ambiguity cost five defects. § 9 now
# names `ech.sh ask`, and declares `pending` derived and read-only.
check "HOLOGRAM-COMMAND-MODE.md § 9 instructs the \`ask\` VERB" \
  "qgrep -qF 'lcars-ech ask' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md gives \`ask\` its --mission flag so it blocks one milestone" \
  "qgrep -qE 'ech.sh ask .*--mission|--mission <' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md no longer tells the model to hand-write a question into pending" \
  "! qgrep -qiE 'write the same shape by hand|by hand, into .pending|hand-write' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md declares \`pending\` a DERIVED, READ-ONLY mirror" \
  "qgrep -qiE 'read-only.*mirror|mirror.*read-only|never storage' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says an older run's hand-written pending is still honoured" \
  "qgrep -qiE 'adopt(ed|s)? .*(the moment|on first sight|first time it is (seen|read))' '$APM'"
# `usage` exits 1 by design and this suite runs with `pipefail`, so the exit
# code has to be discarded or the pipeline reports the usage exit, not the grep.
check "the driver documents the \`ask\` subcommand in its own usage" \
  "{ ap '$R11' --help 2>&1 || true; } | qgrep -qE '^  ask '"
check "HOLOGRAM-COMMAND-MODE.md states the three-failure drive cap" \
  "qgrep -qiE 'three failures in a row|failures in a row' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md states that a routine stage stop pings nobody" \
  "qgrep -qiE 'routine stage stop pings nobody|routine stage stop' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says one question does not park the other milestones" \
  "qgrep -qiE 'none of them parks the run|does not park' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md does not fork ORCHESTRATION.md's loop" \
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
# S304 — THE CHECKLIST THE SEAT CAN ACTUALLY READ
# ==========================================================================
# MEASURED LIVE 2026-10-17 18:18. A Copilot seat driving an unattended mission
# reached the Verify gate, ran `grep '^### ' …/skills/lcars-run/live-check/cli.md`
# — a path THIS SCRIPT handed it, one line above — and froze on:
#
#   "This action may read or write the following path outside the paths
#    currently allowed for this session."
#
# The seat was not browsing. It is trusted inside the PRODUCT REPOSITORY it is
# building in; LCARS's own installed source tree is a different directory, so
# every checklist read was an out-of-world read and, unattended, a frozen night.
#
# THE CURE IS A COPY, NOT A SHORTER PROMPT. The checklist is 313 lines and its
# whole value is that the seat RE-READS it at the moment it needs each item, so
# it cannot be forgotten as the seat's context grows. Inlining it into a brief
# destroys exactly that. A copy on disk inside the repo keeps it.
#
# WHAT IS PINNED HERE: the path handed out is in-repo, its CONTENT is the real
# checklist (not a stub), the SOURCE is untouched, a STALE copy from an older
# LCARS is refreshed rather than used, and LCARS_LIVE_CHECK_DIR still overrides
# the SOURCE. Every one carries a control, because a guard that cannot go red
# reads exactly like a pass.
echo "-- S304 the checklist the seat can read --"

SRCLC="$REPO_ROOT/skills/lcars-run/live-check"

# lc_paths — the checklist paths a live-check run HANDED OUT, scraped from its
# own output. Reads stdin. If this ever returns nothing the controls below go
# red, which is the point: an extractor that finds no paths proves nothing.
lc_paths() { sed -n 's/^===== CHECKLIST: [a-z][a-z]* (\(.*\)) =====$/\1/p'; }
# lc_reaches_source — "yes" if ANY of the given paths reaches into LCARS's own
# installed source tree. THIS is the predicate the defect would trip.
lc_reaches_source() {
  if printf '%s\n' "$1" | qgrep -q 'skills/lcars-run'; then echo yes; else echo no; fi
}

RLS="$(new_repo)"
ap "$RLS" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RLS" lcars-20261001-003 verify

# A STALE COPY FROM "AN OLDER LCARS", planted before the run.
mkdir -p "$RLS/.git/lcars/live-check"
printf 'STALE-FROM-AN-OLDER-LCARS\n' >"$RLS/.git/lcars/live-check/cli.md"

# The source checksums, taken BEFORE the run, so "unmodified" is measured.
SRC_CLI_SUM="$(cksum <"$SRCLC/cli.md")"
SRC_WEB_SUM="$(cksum <"$SRCLC/web.md")"
SRC_WF_SUM="$(cksum <"$SRCLC/workflow.md")"
# S304 (1c): the BUG TEMPLATE's source sum, same reason — the copy must not
# write back into LCARS's own tree.
SRCBP="$REPO_ROOT/skills/lcars-eeh/bug-prd.md"
SRC_BPRD_SUM="$(cksum <"$SRCBP")"
# A STALE staged template from "an older LCARS", planted before the run.
printf 'STALE-BUG-PRD-FROM-AN-OLDER-LCARS\n' >"$RLS/.git/lcars/bug-prd.md"

LSOUT="$(ap "$RLS" live-check lcars-20261001-003 --type cli,web,workflow 2>&1)"; lsrc=$?
ls_wt="$(printf '%s\n' "$LSOUT" | sed -n 's/^WORKTREE: //p' | head -1)"
LSPATHS="$(printf '%s\n' "$LSOUT" | lc_paths)"
LSREPO="$RLS/.git/lcars/live-check"

check "S304. live-check still exits 0" "[ $lsrc -eq 0 ]"
check "S304. it handed out one path per type asked for" \
  "[ \"\$(printf '%s\n' \"\$LSPATHS\" | grep -c . )\" -eq 3 ]"

# (1) THE DEFECT ITSELF.
check "S304. NO path it handed out reaches into LCARS's own source tree" \
  "[ \"\$(lc_reaches_source \"\$LSPATHS\")\" = no ]"
check "S304. every path it handed out is INSIDE the repo's own .git/lcars" \
  "[ \"\$(printf '%s\n' \"\$LSPATHS\" | grep -c \"^$LSREPO/\")\" -eq 3 ]"
check "S304. and each one really is a readable file there" \
  "[ -f '$LSREPO/cli.md' ] && [ -f '$LSREPO/web.md' ] && [ -f '$LSREPO/workflow.md' ]"
check "S304. the whole successful output names LCARS's checklist source nowhere" \
  "! printf '%s\n' \"\$LSOUT\" | qgrep -q 'skills/lcars-run/live-check'"

# (3) CONTROL — the same extractor + the same predicate, over an output in
# which the path IS the source path. If this says `no`, the assertion above is
# measuring nothing and its green is a lie.
LSFAKE="$(printf '%s\n' "$LSOUT" | sed "s|$LSREPO|$SRCLC|g")"
LSFAKEPATHS="$(printf '%s\n' "$LSFAKE" | lc_paths)"
check "S304. CONTROL: the extractor finds paths at all (3 of them)" \
  "[ \"\$(printf '%s\n' \"\$LSFAKEPATHS\" | grep -c . )\" -eq 3 ]"
check "S304. CONTROL: the predicate says YES when the path IS the source tree" \
  "[ \"\$(lc_reaches_source \"\$LSFAKEPATHS\")\" = yes ]"
check "S304. CONTROL: the output-wide grep also fires on a source-path output" \
  "printf '%s\n' \"\$LSFAKE\" | qgrep -q 'skills/lcars-run/live-check'"

# (2) THE COPY IS REAL, NOT A STUB OR A SUMMARY.
check "S304. the local cli.md is byte-identical to the source checklist" \
  "cmp -s '$LSREPO/cli.md' '$SRCLC/cli.md'"
check "S304. so is web.md"      "cmp -s '$LSREPO/web.md'      '$SRCLC/web.md'"
check "S304. so is workflow.md" "cmp -s '$LSREPO/workflow.md' '$SRCLC/workflow.md'"
check "S304. README.md is staged with them (so the staged dir can explain itself)" \
  "cmp -s '$LSREPO/README.md' '$SRCLC/README.md'"
check "S304. the local copy is the FULL 313-line cli checklist, not an excerpt" \
  "[ \"\$(wc -l <'$LSREPO/cli.md' | tr -d ' ')\" -eq \"\$(wc -l <'$SRCLC/cli.md' | tr -d ' ')\" ]"
check "S304. it still PRINTS the checklist, so a seat with no file read is unharmed" \
  "printf '%s' \"\$LSOUT\" | qgrep -qF 'host of every outbound call'"
check "S304. CONTROL: a stub copy would fail the byte-identical check" \
  "printf 'stub\n' >'$TMPROOT/lc-stub.md'; ! cmp -s '$TMPROOT/lc-stub.md' '$SRCLC/cli.md'"

# (4) THE STALE COPY IS REFRESHED, NEVER USED AS-IS.
check "S304. a stale copy from an older LCARS was REFRESHED, not trusted" \
  "! qgrep -q 'STALE-FROM-AN-OLDER-LCARS' '$LSREPO/cli.md'"
check "S304. CONTROL: the stale marker was genuinely there before the run" \
  "qgrep -q 'STALE-FROM-AN-OLDER-LCARS' <<<'STALE-FROM-AN-OLDER-LCARS'"
# and it is refreshed EVERY time, not once: re-stale it and run again.
printf 'STALE-AGAIN\n' >"$LSREPO/cli.md"
LSOUT2="$(ap "$RLS" live-check lcars-20261001-003 --type cli 2>&1)"
ls_wt2="$(printf '%s\n' "$LSOUT2" | sed -n 's/^WORKTREE: //p' | head -1)"
check "S304. and refreshed on EVERY run, not just the first" \
  "cmp -s '$LSREPO/cli.md' '$SRCLC/cli.md'"

# (3, second half) THE SOURCE IS READ-ONLY — it still exists where Number One
# and lcars-run look for it, byte-for-byte as it was.
check "S304. the SOURCE checklists are still at their own shared home" \
  "[ -f '$SRCLC/cli.md' ] && [ -f '$SRCLC/web.md' ] && [ -f '$SRCLC/workflow.md' ]"
check "S304. and the source cli.md is UNMODIFIED by the copy" \
  "[ \"\$(cksum <'$SRCLC/cli.md')\" = '$SRC_CLI_SUM' ]"
check "S304. source web.md unmodified" \
  "[ \"\$(cksum <'$SRCLC/web.md')\" = '$SRC_WEB_SUM' ]"
check "S304. source workflow.md unmodified" \
  "[ \"\$(cksum <'$SRCLC/workflow.md')\" = '$SRC_WF_SUM' ]"

# (5) LCARS_LIVE_CHECK_DIR STILL OVERRIDES THE **SOURCE** LOCATION.
LCOVR="$TMPROOT/lc-override"
mkdir -p "$LCOVR"
printf '# OVERRIDE CHECKLIST\n\nOVERRIDE-MARKER-9f3\n' >"$LCOVR/cli.md"
RLS2="$(new_repo)"
ap "$RLS2" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
new_mission "$RLS2" lcars-20261001-004 verify
export LCARS_LIVE_CHECK_DIR="$LCOVR"
LSOVR="$(ap "$RLS2" live-check lcars-20261001-004 --type cli 2>&1)"; lsovrc=$?
unset LCARS_LIVE_CHECK_DIR
ls_wt3="$(printf '%s\n' "$LSOVR" | sed -n 's/^WORKTREE: //p' | head -1)"
LSOVRPATHS="$(printf '%s\n' "$LSOVR" | lc_paths)"
check "S304. LCARS_LIVE_CHECK_DIR run exits 0" "[ $lsovrc -eq 0 ]"
check "S304. the override is read AS THE SOURCE (its content reaches the seat)" \
  "printf '%s' \"\$LSOVR\" | qgrep -qF 'OVERRIDE-MARKER-9f3'"
check "S304. the override's content is what landed in the in-repo copy" \
  "cmp -s '$RLS2/.git/lcars/live-check/cli.md' '$LCOVR/cli.md'"
check "S304. the override does NOT move the handed-out path out of the repo" \
  "[ \"\$(printf '%s\n' \"\$LSOVRPATHS\")\" = '$RLS2/.git/lcars/live-check/cli.md' ]"
check "S304. CONTROL: without the override the real checklist is used, not the marker" \
  "! printf '%s' \"\$LSOUT\" | qgrep -qF 'OVERRIDE-MARKER-9f3'"
check "S304. a MISSING checklist in an override dir is still refused, loudly" \
  "export LCARS_LIVE_CHECK_DIR='$LCOVR'; o=\"\$(ap '$RLS2' live-check lcars-20261001-004 --type web 2>&1)\"; r=\$?; unset LCARS_LIVE_CHECK_DIR; [ \$r -ne 0 ] && ! printf '%s' \"\$o\" | qgrep -q 'CHECKLIST:'"

# The playbook is the other route back to the source path: a seat that reads
# `skills/lcars-run/live-check/cli.md` out of the prose freezes exactly the same
# way, having never run the command.
check "S304. the playbook hands the seat NO source-tree checklist path" \
  "! qgrep -q 'skills/lcars-run/live-check/' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S304. the playbook names the in-repo copy instead" \
  "qgrep -qF '.git/lcars/live-check/' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S304. CONTROL: the playbook still has a § 6 live-check section to carry it" \
  "qgrep -qF 'lcars-ech live-check' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"

echo "-- S304 the bug TEMPLATE the seat can read --"

# THE SAME DEFECT, ONE LINE FURTHER ON. `live-check`'s last line handed the seat
#   (template: <abs>/skills/lcars-eeh/bug-prd.md)
# — a path into LCARS's own installed source tree — at the exact moment the seat
# has FOUND a bug and is reaching for the template to file it. A seat is trusted
# only inside the repository it is building in, so that read raises the same
# permission dialog that froze the Verify gate on 2026-10-17, and it freezes the
# run at its single most expensive moment. The captain's stopping rule for a
# measurement needs one filed bug carried to merged, so a seat that cannot reach
# the template cannot satisfy it.

# bp_path — the template path a run HANDED OUT, scraped from its own output.
# Reads stdin. If this returns nothing the controls below go red, which is the
# point: an extractor that finds no path proves nothing.
bp_path() { sed -n 's/^A BUG:.*(template: \(.*\))$/\1/p'; }
# bp_reaches_source — "yes" if the given path reaches into LCARS's own installed
# source tree. THIS is the predicate the defect would trip.
bp_reaches_source() {
  if printf '%s\n' "$1" | qgrep -q 'skills/lcars-eeh/bug-prd.md'; then echo yes; else echo no; fi
}

BPPATH="$(printf '%s\n' "$LSOUT" | bp_path)"
BPREPO="$RLS/.git/lcars/bug-prd.md"

check "S304. live-check hands out exactly ONE bug-template path" \
  "[ \"\$(printf '%s\n' \"\$BPPATH\" | grep -c . )\" -eq 1 ]"

# (1) THE DEFECT ITSELF.
check "S304. the bug-template path it hands out does NOT reach LCARS's source tree" \
  "[ \"\$(bp_reaches_source \"\$BPPATH\")\" = no ]"
check "S304. the bug-template path it hands out is INSIDE the repo's own .git/lcars" \
  "[ \"\$BPPATH\" = '$BPREPO' ]"
check "S304. and the path it named really is a readable file" \
  "[ -f \"\$BPPATH\" ] && [ -r \"\$BPPATH\" ]"
check "S304. the whole successful output names the bug template's SOURCE nowhere" \
  "! printf '%s\n' \"\$LSOUT\" | qgrep -q 'skills/lcars-eeh/bug-prd.md'"

# (5) CONTROLS — mandatory, and the same shape as the checklist half above.
# First: the extractor matches something at all, so a green (1) is never a
# vacuous zero about the wrong population.
check "S304. CONTROL: the extractor finds a template path at all" \
  "[ -n \"\$BPPATH\" ]"
check "S304. CONTROL: the output really does carry an 'A BUG:' line to scrape" \
  "printf '%s\n' \"\$LSOUT\" | qgrep -q '^A BUG:'"
# Second: substitute the SOURCE path back into the real output and require the
# same extractor + the same predicate to answer "yes". If this says `no`, the
# assertion above is measuring nothing and its green is a lie.
BPFAKE="$(printf '%s\n' "$LSOUT" | sed "s|$BPREPO|$SRCBP|g")"
BPFAKEPATH="$(printf '%s\n' "$BPFAKE" | bp_path)"
check "S304. CONTROL: the extractor still finds the path when it IS the source" \
  "[ \"\$(printf '%s\n' \"\$BPFAKEPATH\" | grep -c . )\" -eq 1 ]"
check "S304. CONTROL: the predicate says YES when the path IS the source tree" \
  "[ \"\$(bp_reaches_source \"\$BPFAKEPATH\")\" = yes ]"
check "S304. CONTROL: the output-wide grep also fires on a source-path output" \
  "printf '%s\n' \"\$BPFAKE\" | qgrep -q 'skills/lcars-eeh/bug-prd.md'"

# (2) THE COPY IS THE REAL TEMPLATE, NOT A STUB OR A SUMMARY.
check "S304. the staged bug-prd.md is byte-identical to the source template" \
  "cmp -s '$BPREPO' '$SRCBP'"
check "S304. it is the FULL template, not an excerpt" \
  "[ \"\$(wc -l <'$BPREPO' | tr -d ' ')\" -eq \"\$(wc -l <'$SRCBP' | tr -d ' ')\" ]"
check "S304. the staged copy carries the mandatory AC #1 the validator reads" \
  "qgrep -qF 'Observed live:' '$BPREPO'"
check "S304. CONTROL: a stub copy would fail the byte-identical check" \
  "printf 'stub\n' >'$TMPROOT/bp-stub.md'; ! cmp -s '$TMPROOT/bp-stub.md' '$SRCBP'"

# (4) THE STALE STAGED COPY IS REFRESHED, NEVER TRUSTED-IF-PRESENT. Copy-if-
# missing lets a repo staged by an older LCARS shadow a newer template for ever,
# and a silently out-of-date bug template is a bug that gets re-filed.
check "S304. a stale template from an older LCARS was REFRESHED, not trusted" \
  "! qgrep -q 'STALE-BUG-PRD-FROM-AN-OLDER-LCARS' '$BPREPO'"
check "S304. CONTROL: the stale marker was genuinely detectable before the run" \
  "qgrep -q 'STALE-BUG-PRD' <<<'STALE-BUG-PRD-FROM-AN-OLDER-LCARS'"
printf 'STALE-BUG-PRD-AGAIN\n' >"$BPREPO"
BPOUT2="$(ap "$RLS" live-check lcars-20261001-003 --type cli 2>&1)"
ls_wt4="$(printf '%s\n' "$BPOUT2" | sed -n 's/^WORKTREE: //p' | head -1)"
check "S304. and refreshed on EVERY run, not just the first" \
  "cmp -s '$BPREPO' '$SRCBP'"

# (3) THE SOURCE IS READ-ONLY HERE — it is still where `lcars-eeh docs bug-prd`
# and Number One look for it, byte-for-byte as it was.
check "S304. the SOURCE template is still at its own location" "[ -f '$SRCBP' ]"
check "S304. and the source template is UNMODIFIED by the copy" \
  "[ \"\$(cksum <'$SRCBP')\" = '$SRC_BPRD_SUM' ]"

# `file-bug`'s OWN refusals are the other moment the seat needs the template,
# and they named the source path too. A refusal that freezes is worse than a
# success that freezes: the seat is already mid-filing.
BPFB1="$(ap "$RLS" file-bug --parent lcars-20261001-003 2>&1)"; bpfb1=$?
check "S304. file-bug with no --prd still refuses" "[ $bpfb1 -ne 0 ]"
check "S304. file-bug's no-PRD refusal names the in-repo template, not the source" \
  "printf '%s\n' \"\$BPFB1\" | qgrep -qF '$BPREPO'"
check "S304. file-bug's no-PRD refusal names LCARS's source tree nowhere" \
  "! printf '%s\n' \"\$BPFB1\" | qgrep -q 'skills/lcars-eeh/bug-prd.md'"
check "S304. CONTROL: that refusal does still point at a template at all" \
  "printf '%s\n' \"\$BPFB1\" | qgrep -qiF 'template'"

printf 'not a bug PRD at all\n' >"$TMPROOT/bp-junk.md"
BPFB2="$(ap "$RLS" file-bug --parent lcars-20261001-003 --prd "$TMPROOT/bp-junk.md" 2>&1)"; bpfb2=$?
check "S304. file-bug still refuses a PRD that is not evidence-first" "[ $bpfb2 -ne 0 ]"
check "S304. that refusal names the in-repo template, not the source" \
  "printf '%s\n' \"\$BPFB2\" | qgrep -qF '$BPREPO'"
check "S304. that refusal names LCARS's source tree nowhere" \
  "! printf '%s\n' \"\$BPFB2\" | qgrep -q 'skills/lcars-eeh/bug-prd.md'"
check "S304. CONTROL: it still says nothing was filed" \
  "printf '%s\n' \"\$BPFB2\" | qgrep -qF 'Nothing was filed'"

# The playbook is the other route back: a seat that reads "bug-prd.md, beside
# this file" out of § 6 goes hunting in the source tree, having never run the
# command. § 6.1 was cured the same way for the checklists.
check "S304. the playbook sends the seat at the in-repo bug template" \
  "qgrep -qF '.git/lcars/bug-prd.md' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S304. the playbook no longer says the template is 'beside this file'" \
  "! qgrep -qF 'bug-prd.md\`, beside this file' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S304. the playbook hands the seat NO source-tree bug-template path at all" \
  "! qgrep -q 'skills/lcars-eeh/bug-prd' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S304. CONTROL: the playbook still carries the bug-PRD contract it had" \
  "qgrep -qF 'Observed live:' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md' && qgrep -qF 'round-trip' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"

for w in "$ls_wt" "$ls_wt2" "$ls_wt3" "$ls_wt4"; do
  [ -n "$w" ] || continue
  git -C "$RLS"  worktree remove --force "$w" 2>/dev/null || true
  git -C "$RLS2" worktree remove --force "$w" 2>/dev/null || true
done

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
  d="$LCARS_ECH_CWD/.git/lcars/missions/bug-00$n"
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
check "policy cites the HOLOGRAM-COMMAND-MODE.md heading for the action" \
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
check "the recorded override carries the note the EEH wrote" \
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
check "policy prints the whole table so the EEH can see the row it took" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qF 'merge+follow-ups'"
# AN UNESCAPED BACKTICK IN A `say` RAN AS A COMMAND. `policy --table` printed
# "command not found: bugs" into the middle of the merge table and swallowed the
# word it was explaining. Any `say "…\`x\`…"` has this hazard, so the sweep is
# over the WHOLE driver's output, not just this line.
check "no subcommand's output leaks a shell error (an unescaped backtick in a say)" \
  "! ap '$RPO' policy --table 2>&1 | qgrep -qiE 'command not found|No such file or directory'"
check "the table's explanation keeps the word it is explaining" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qF 'live check sends back a high'"
# THE TABLE IS FILMED. The 2026.10.5 rename retired the old companion and driver
# names, but this footer still printed the ENGINEERING hologram where it means the
# COMMAND hologram, and spelled out the un-migrated ledger FILENAME, which still
# carries the retired driver name. The file keeps its name (the on-disk state and
# ~60 assertions depend on it); the prose stops broadcasting it.
check "the table names the deciding hologram without an initialism a viewer must decode" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qF \"THE MERGE IS THE HOLOGRAM'S CALL\""
check "the table no longer names the ENGINEERING hologram as the merge authority" \
  "! ap '$RPO' policy --table 2>&1 | qgrep -qF \"THE MERGE IS THE EEH'S CALL\""
check "the table prints no retired driver name (it is filmed)" \
  "! ap '$RPO' policy --table 2>&1 | qgrep -qi 'autopilot'"
check "the table still says every override is recorded with its evidence" \
  "ap '$RPO' policy --table 2>&1 | qgrep -qi 'evidence'"
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
<title>ECH progress</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
  table { border-collapse: collapse; width: 100%; }
  td, th { border-bottom: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }
  .pass { color: #0a7a2f; } .bugs { color: #c0392b; } .none { color: #888; }
  ul { padding-left: 1.2rem; }
  @media (max-width: 500px) { body { margin: .75rem; } }
</style></head>
<body>
<h1 id="report-title">ECH progress</h1>
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
# S234.6 the prose contracts — bug-prd.md and HOLOGRAM-COMMAND-MODE.md's two new sections
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
check "bug-prd.md names \`ech.sh file-bug\` as how it is filed" \
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
check "HOLOGRAM-COMMAND-MODE.md names bug-prd.md's WORKED EXAMPLE as the one style exemplar" \
  "qgrep -qiF 'worked example' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md does NOT point at the archive PRD the validator refuses" \
  "! qgrep -qF 'bug-020-1' '$APM'"

check "HOLOGRAM-COMMAND-MODE.md's live-verification section is no longer an S234 STUB" \
  "! qgrep -qiE 'S234 — STUB|S234 - STUB' '$APM'"
# S304 INVERTED THIS ONE. It used to assert the playbook points at the SHARED
# source path (`lcars-run/live-check`) — and that is precisely the instruction
# that froze a measured unattended run on 2026-10-17: a seat is trusted inside
# the repository it is building in, so a read of LCARS's installed source tree
# stops it dead on a permission prompt nothing in the run can answer. The
# command now stages the checklists into `.git/lcars/live-check/` and the prose
# must send the seat THERE. The source home is unchanged and unmoved; only the
# reader's route to it is.
check "HOLOGRAM-COMMAND-MODE.md points the seat at the IN-REPO staged checklists" \
  "qgrep -qF '.git/lcars/live-check/' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md hands the seat NO path into LCARS's own source tree" \
  "! qgrep -qF 'lcars-run/live-check' '$APM'"
check "CONTROL: the installed playbook is a real file with the live-check section in it" \
  "[ -s '$APM' ] && qgrep -qF 'lcars-ech live-check' '$APM'"
# S277: command-name literal ONLY. HOLOGRAM-COMMAND-MODE.md now names the on-PATH `lcars-ech <verb>` (a Copilot user has no ~/.claude/skills path). The asserted BEHAVIOUR is unchanged -- do not revert to `ech.sh`.
check "HOLOGRAM-COMMAND-MODE.md names the live-check verb" \
  "qgrep -qF 'lcars-ech live-check' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md names the workflow-run verb for every workflow a mission adds" \
  "qgrep -qF 'lcars-ech workflow-run' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md names the file-bug verb and the template" \
  "qgrep -qF 'lcars-ech file-bug' '$APM' && qgrep -qF 'bug-prd.md' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md names the policy verb" \
  "qgrep -qF 'lcars-ech policy' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md names the report verb" \
  "qgrep -qF 'lcars-ech report' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md carries the whole merge table: all four actions" \
  "( for a in 'merge' 'follow-ups' 'send-back' 'override'; do qgrep -qF \"\$a\" '$APM' || exit 1; done )"
check "HOLOGRAM-COMMAND-MODE.md says a LOW for infrastructure only is fixed, verified live, and OVERRIDDEN" \
  "qgrep -qiE 'infrastructure' '$APM' && qgrep -qF 'autopilot-overrides.jsonl' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says THE MERGE IS THE HOLOGRAM'S CALL — Number One recommends" \
  "qgrep -qiE \"the hologram's call|the hologram\" '$APM' && qgrep -qi 'recommend' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says every override is recorded WITH its evidence path" \
  "qgrep -qiE 'evidence path' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md keeps the send-back loop: file-bug -> resolve-logs -> re-verify with different data -> respond -> land" \
  "qgrep -qF 'resolve-logs' '$APM' && qgrep -qiF 'different data' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md says the anchor rule and the seam constraint are HARNESS DEFAULTS now (S236/S237), not the mode's job" \
  "qgrep -qiE 'harness default' '$APM' && qgrep -qE 'S236|S237' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md does NOT tell the mode to inject the anchor rule into every PRD (that would duplicate S236/S237)" \
  "! qgrep -qiE 'inject the anchor rule|add the anchor rule' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md still forbids the hand-merge after the rewrite" \
  "qgrep -qiE 'never (merge by hand|hand-merge)' '$APM'"
check "HOLOGRAM-COMMAND-MODE.md still tells the model to run the live check from a DETACHED worktree" \
  "qgrep -qiF 'detached' '$APM'"

# ==========================================================================
# S300. preflight — the setup questions get asked WHILE A HUMAN IS STILL HERE,
#       and with nobody there the run DECIDES instead of waiting
# ==========================================================================
# THE DEFECT. The driver discovered what it needed at the moment it failed. On
# 2026-10-14/15 three overnight runs died at verification waiting on a
# permission nobody was awake to give, and a fourth could not open a PR because
# there was no remote — a fact LCARS had ALREADY written into the mission's own
# state.json (`githubIssue: null`) and never surfaced at the gate. A blocked run
# and a healthy idle one look identical from outside; nothing inside the run can
# detect or recover from it, so the cost is the rest of the night, every time.
#
# THE RIG, AND WHY IT HAS TWO GENUINELY DIFFERENT ARMS. "No terminal" is the
# behaviour most easily faked by a test that never actually detaches one, so
# both arms are real and every assertion below is paired with the other arm
# printing a DIFFERENT answer:
#
#   ap_pty   — pty.fork(), so the child is a session leader whose CONTROLLING
#              TERMINAL is the pty. Not merely `[ -t 0 ]`-satisfying: /dev/tty
#              genuinely opens, which is what the driver detects.
#   ap_caged — tests/lib/cage.py, which gives the child stdin=DEVNULL AND
#              start_new_session=True. A new session with no tty attached has NO
#              CONTROLLING TERMINAL, so /dev/tty cannot be opened — the
#              detached-daemon case, which is the one that ate the nights.
#
# NOTHING KEYS ON THE CAGE'S OWN EXIT STATUS for the hang question: the printed
# `ELAPSED …` line is parsed, because a cage that comes back silent and a cage
# that was killed are the same $? to a reader who does not look.
echo "-- S300. preflight (asked while he is still here; never hangs) --"

CAGE="$REPO_ROOT/tests/lib/cage.py"
check "the cage this section depends on exists" "[ -f '$CAGE' ]"

PTYRIG="$TMPROOT/ptyrig.py"
cat >"$PTYRIG" <<'PYRIG'
# A REAL controlling terminal. pty.fork() (not openpty + Popen) is deliberate:
# only the fork path makes the child a session leader with the slave as its
# CONTROLLING terminal, which is the thing the driver tests for.
#
# IT ANSWERS WHEN ASKED, NOT UP FRONT. The first version wrote every answer
# 0.4s in and they were silently lost: in CANONICAL mode an incomplete line is
# never delivered, and `ANSWERS="$(printf 'x\n')"` loses its newline to command
# substitution, so the driver's bounded read correctly timed out and the arm
# measured "nobody answered" while claiming to measure "he answered". A rig that
# can report the wrong arm is worse than no rig, so answers are now written in
# response to the prompt the driver actually printed.
#
# ANSWERS is `|`-joined and each entry gets its own newline. UNSET means nobody
# is behind the terminal at all; set-but-empty means one bare return.
import os, pty, select, signal, sys, time
raw = os.environ.get("ANSWERS")
pending = raw.split("|") if raw is not None else []
deadline = float(os.environ.get("PTY_DEADLINE", "15"))
pid, fd = pty.fork()
if pid == 0:
    # STDIN_DEVNULL keeps the pty as the CONTROLLING terminal (so /dev/tty still
    # opens) while fd 0 is /dev/null. That separates the two halves of the
    # detection, and it is the shape every suite in this repo runs commands in.
    if os.environ.get("STDIN_DEVNULL"):
        dn = os.open(os.devnull, os.O_RDONLY)
        os.dup2(dn, 0)
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except Exception:
        pass
    os._exit(127)
out, written, stop = b"", 0, time.time() + deadline
while time.time() < stop:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            b = os.read(fd, 4096)
        except OSError:
            break
        if not b:
            break
        out += b
        # One answer per prompt the driver printed, in order.
        while pending and out.count(b"\n> ") > written:
            os.write(fd, (pending.pop(0) + "\n").encode())
            written += 1
    elif os.waitpid(pid, os.WNOHANG)[0]:
        break
sys.stdout.write(out.decode("utf-8", "replace"))
sys.stdout.write("\nPTYPROMPTS %d ANSWERED %d\n" % (out.count(b"\n> "), written))
try:
    os.kill(pid, signal.SIGKILL)
except OSError:
    pass
try:
    st = os.waitpid(pid, 0)[1]
except OSError:
    st = 0
rc = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)
sys.stdout.write("\nPTYEXIT %d\n" % rc)
PYRIG

# The env both arms share — the same stubs `ap` uses, plus the four git
# credential muzzles (GIT_TERMINAL_PROMPT alone is not enough: git prefers
# $GIT_ASKPASS, and it does not read its prompt from stdin, so closing stdin is
# no defence either).
pf_env() {
  printf '%s\n' \
    "TMPDIR=$TMPROOT/tmp" \
    "LCARS_ECH_CWD=$1" \
    "STUB_LOG=$STUB_LOG" \
    "LCARS_RUN_SCRIPT=$STUBS/run.sh" \
    "LCARS_APPROVE_SCRIPT=$STUBS/approve.sh" \
    "LCARS_XO_SCRIPT=$STUBS/xo.sh" \
    "LCARS_RESPOND_SCRIPT=$STUBS/respond.sh" \
    "LCARS_LOG_SCRIPT=$STUBS/log.sh" \
    "LCARS_FILE_SCRIPT=$STUBS/file.sh" \
    "LCARS_RESOLVE_LOGS_SCRIPT=$STUBS/resolve-logs.sh" \
    "LCARS_NOTIFY=$STUBS/notify.sh" \
    "LCARS_CRONTAB_BIN=$STUBS/crontab" \
    "LCARS_ECH_ASK_TIMEOUT=${PF_ASKT:-6}" \
    "LCARS_ECH_PROBE_TIMEOUT=${PF_PROBET:-10}" \
    "LCARS_GH_BIN=${PF_GH:-$PFGH_YES}" \
    "COPILOT_ALLOW_ALL=${PF_ALLOW_ALL-true}" \
    "GIT_TERMINAL_PROMPT=0" "GIT_ASKPASS=" "SSH_ASKPASS="
}

# ap_pty <repo> <answers> <args…> — the driver with a real controlling terminal.
# <answers> is `|`-joined; the literal string NONE means nobody is behind the
# terminal at all (ANSWERS stays unset), which is a different measurement from
# one bare return.
ap_pty() {
  local repo="$1" answers="$2"; shift 2
  mkdir -p "$TMPROOT/tmp"
  local e; e="$(pf_env "$repo" | tr '\n' ' ')"
  if [ "$answers" = NONE ]; then
    PTY_DEADLINE="${PF_PTYDL:-12}" \
      python3 "$CAGE" 40 python3 "$PTYRIG" env $e bash "$SCRIPT" "$@" 2>&1
  else
    ANSWERS="$answers" PTY_DEADLINE="${PF_PTYDL:-12}" \
      python3 "$CAGE" 40 python3 "$PTYRIG" env $e bash "$SCRIPT" "$@" 2>&1
  fi
}

# ap_caged <secs> <repo> <args…> — the driver with NO controlling terminal.
ap_caged() {
  local secs="$1" repo="$2"; shift 2
  mkdir -p "$TMPROOT/tmp"
  local e; e="$(pf_env "$repo" | tr '\n' ' ')"
  python3 "$CAGE" "$secs" env $e bash "$SCRIPT" "$@" 2>&1
}

# cage_first <output> — the ELAPSED line, which is the only verdict a cage can
# support. Printed in the report for every no-terminal arm.
cage_first() { printf '%s\n' "$1" | sed -n 1p; }

# --- B1 + B2: ONE repo state, the two arms, different answers ---------------
# Both repos are identical and fully provisioned (a testCommand in config.json
# and a real origin), so the ONLY question outstanding is where the launch
# copies go — which is exactly the question that must be asked, or defaulted
# and SAID, rather than waited on.
PFA="$(new_repo)"
PFB="$(new_repo)"
printf 'M0 the CLI\n' >"$TMPROOT/pf-spec.md"

pfa="$(ap_pty "$PFA" "" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pfb="$(ap_caged 30 "$PFB" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
PFA_J="$PFA/.git/lcars/autopilot.json"
PFB_J="$PFB/.git/lcars/autopilot.json"
echo "    [terminal arm]   $(printf '%s' "$pfa" | sed -n '/PTYEXIT/p')"
echo "    [no-terminal arm] $(cage_first "$pfb")"

# B1 — a terminal is present, so it ASKS, once, with a recommended default.
check "B1 a terminal present: starting a run ASKS its setup question" \
  "printf '%s' \"\$pfa\" | qgrep -q 'asked 1 question'"
check "B1 the question carries a RECOMMENDED default" \
  "printf '%s' \"\$pfa\" | qgrep -q 'RECOMMENDED'"
check "B1 the recommended default is the value it proposes to use" \
  "printf '%s' \"\$pfa\" | qgrep -qF '$TMPROOT/tmp'"
check "B1 return accepts it, and the answer is RECORDED, not re-derived later" \
  "[ \"\$(jget '$PFA_J' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ]"
check "B1 'yes to all' is offered, so one keystroke answers the block" \
  "printf '%s' \"\$pfa\" | qgrep -qi 'yes'"
check "B1 RIG CONTROL: the rig actually answered the prompt it was shown" \
  "printf '%s' \"\$pfa\" | qgrep -q 'PTYPROMPTS 1 ANSWERED 1'"
check "B1 the terminal arm exits 0" \
  "printf '%s' \"\$pfa\" | qgrep -q 'PTYEXIT 0'"

# B2 — THE ONE THAT MATTERS. No controlling terminal at all: it must come back.
check "B2 no terminal: the caged run RETURNED (it did not hang)" \
  "cage_first \"\$pfb\" | qgrep -q 'EXIT' && ! cage_first \"\$pfb\" | qgrep -q 'TIMED OUT'"
check "B2 no terminal: and it returned 0 — a stated default, not a stop" \
  "cage_first \"\$pfb\" | qgrep -q 'EXIT 0'"
check "B2 no terminal: it SAYS there is no terminal rather than waiting on one" \
  "printf '%s' \"\$pfb\" | qgrep -q 'NO TERMINAL'"
check "B2 no terminal: it prints the question it WOULD have asked" \
  "printf '%s' \"\$pfb\" | qgrep -qi 'would have asked'"
check "B2 no terminal: and names the value it is proceeding with" \
  "printf '%s' \"\$pfb\" | qgrep -qF '$TMPROOT/tmp'"
check "B2 no terminal: nothing was asked (nobody was there to ask)" \
  "printf '%s' \"\$pfb\" | qgrep -q 'asked 0 question'"
check "B2 no terminal: the default it proceeded on is RECORDED all the same" \
  "[ \"\$(jget '$PFB_J' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ]"
# THE LIVE CONTROL for every B2 assertion above: the identical command on the
# identical repo state, with a terminal, prints the OTHER answer. Two arms
# printing the same thing would mean the detection is not detecting anything.
check "B2 CONTROL: the terminal arm did NOT take the no-terminal path" \
  "! printf '%s' \"\$pfa\" | qgrep -q 'NO TERMINAL'"
check "B2 CONTROL: the two arms disagree about how many questions were asked" \
  "printf '%s' \"\$pfa\" | qgrep -q 'asked 1 question' && printf '%s' \"\$pfb\" | qgrep -q 'asked 0 question'"

# --- B4: the questions cover all three prerequisites -----------------------
check "B4 covers where the launch copies go" \
  "printf '%s' \"\$pfb\" | qgrep -qi 'launch copies'"
check "B4 covers whether a test command is recorded" \
  "printf '%s' \"\$pfb\" | qgrep -qi 'test command'"
check "B4 covers whether there is somewhere to push" \
  "printf '%s' \"\$pfb\" | qgrep -qi 'somewhere to push'"
check "B4 reads the ALREADY RECORDED test command instead of re-deriving it" \
  "printf '%s' \"\$pfb\" | qgrep -qF 'bash tests/run.sh'"
check "B4 names the remote it found, so the push gate is settled up front" \
  "printf '%s' \"\$pfb\" | qgrep -q 'origin'"

# --- B3: prerequisites already satisfied → it asks NOTHING ------------------
# Same rig, same repo, a terminal present both times — so the only difference
# is that the first run settled the question. That is the control.
pfa2="$(ap_pty "$PFA" "" preflight)"
check "B3 satisfied: a second run with a terminal asks NOTHING" \
  "printf '%s' \"\$pfa2\" | qgrep -q 'asked 0 question'"
check "B3 satisfied: it says the recorded answer is why" \
  "printf '%s' \"\$pfa2\" | qgrep -qi 'already recorded'"
check "B3 CONTROL: the FIRST run on that same repo did ask one" \
  "printf '%s' \"\$pfa\" | qgrep -q 'asked 1 question'"
check "B3 satisfied: exits 0" "printf '%s' \"\$pfa2\" | qgrep -q 'PTYEXIT 0'"

# --- B2 (stdin closed, terminal still attached) ----------------------------
# THE REGRESSION THIS PINS, MEASURED. The first cut of this detected a human by
# `/dev/tty` ALONE. tests/harness.test.sh runs every suite from a pty with stdin
# OPEN on purpose, and `tests/lcars-eeh.test.sh` invokes `the ECH init`; the
# prompt opened /dev/tty, nobody was behind it, and that suite went from 5.9s to
# ELAPSED 120.0s — the exact read bound — and was killed by the cage. A bounded
# read turned a hang into a long hang, which is not the same as not hanging.
#
# So stdin being redirected is itself an answer: this whole repo's convention is
# that a command run with stdin closed is unattended (CLAUDE.md: `tests/run.sh`
# invokes every suite that way), and the detection has to honour it. Both halves
# must agree before anything is asked.
PFS="$(new_repo)"
pfs="$(STDIN_DEVNULL=1 PF_ASKT=4 ap_pty "$PFS" NONE init --spec "$TMPROOT/pf-spec.md" --scope M0)"
echo "    [terminal attached, stdin /dev/null] $(cage_first "$pfs")"
check "B2-stdin: a terminal with stdin REDIRECTED asks nothing and does not wait" \
  "printf '%s' \"\$pfs\" | qgrep -q 'asked 0 question' && printf '%s' \"\$pfs\" | qgrep -q 'NO TERMINAL'"
check "B2-stdin: it never even printed a prompt (nothing to time out on)" \
  "printf '%s' \"\$pfs\" | qgrep -q 'PTYPROMPTS 0 ANSWERED 0'"
check "B2-stdin: and it came back fast — no bounded read was entered at all" \
  "cage_first \"\$pfs\" | qgrep -q 'EXIT 0' && ! cage_first \"\$pfs\" | qgrep -q 'TIMED OUT'"
# CONTROL: the SAME rig, the SAME repo, stdin left on the pty — it asks. The only
# variable is fd 0, which is what makes this a measurement and not a tautology.
PFS2="$(new_repo)"
pfs2="$(ap_pty "$PFS2" "" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "B2-stdin CONTROL: with stdin left on the terminal the same run DOES ask" \
  "printf '%s' \"\$pfs2\" | qgrep -q 'asked 1 question' && printf '%s' \"\$pfs2\" | qgrep -q 'PTYPROMPTS 1 ANSWERED 1'"

# --- B2 (stop arm): the question with nothing safe to default to ------------
# No remote means there is nowhere to push and no PR can be opened. There is
# nothing to invent, so with nobody to ask the run STOPS DELIBERATELY — the
# other legal outcome — and records the question rather than finding out at
# 03:00.
PFC="$(new_repo)"; git -C "$PFC" remote remove origin
PFD="$(new_repo)"; git -C "$PFD" remote remove origin
pfc="$(ap_caged 30 "$PFC" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
echo "    [no-remote, no terminal] $(cage_first "$pfc")"
PFC_J="$PFC/.git/lcars/autopilot.json"
check "B2-stop: the caged run RETURNED (it did not hang)" \
  "cage_first \"\$pfc\" | qgrep -q 'EXIT' && ! cage_first \"\$pfc\" | qgrep -q 'TIMED OUT'"
check "B2-stop: it STOPPED deliberately, with the captain-question exit code" \
  "cage_first \"\$pfc\" | qgrep -q 'EXIT 10'"
check "B2-stop: it says it is stopping, and why" \
  "printf '%s' \"\$pfc\" | qgrep -qi 'STOPPING' && printf '%s' \"\$pfc\" | qgrep -qi 'nowhere to push'"
check "B2-stop: the stop is RECORDED as a real question, not just printed" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [q for q in d[\"questions\"].values() if not q.get(\"answeredAt\")] else 1)' '$PFC_J'"
check "B2-stop: and the question names the one command that would fix it" \
  "printf '%s' \"\$pfc\" | qgrep -q 'git remote add origin'"
# CONTROL: the same missing prerequisite, WITH a terminal, is a question he can
# answer in one line instead of a stop.
# TWO prompts are outstanding on this repo (the launch dir, then the push), so
# the answers are "return, then local" - in order.
pfd="$(ap_pty "$PFD" "|local" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
PFD_J="$PFD/.git/lcars/autopilot.json"
check "B2-stop CONTROL: with a terminal the same gap is ASKED, not stopped on" \
  "printf '%s' \"\$pfd\" | qgrep -q 'asked 2 question' && printf '%s' \"\$pfd\" | qgrep -q 'PTYEXIT 0'"
check "B2-stop CONTROL: his answer is recorded as the push mode" \
  "[ \"\$(jget '$PFD_J' 'd[\"push\"][\"mode\"]')\" = 'local-only' ]"
check "B2-stop CONTROL: and it did NOT record a question" \
  "[ \"\$(jget '$PFD_J' 'd[\"questions\"]')\" = '{}' ]"

# --- B2 (the tty with nobody behind it) ------------------------------------
# A terminal EXISTS but the human has gone — `nohup … &` from a login shell, or
# a detached tmux pane. /dev/tty still opens, so detection alone cannot save
# this case: every read is BOUNDED, and a read that nobody answers falls through
# to exactly the no-terminal decision. Costing 2 seconds, never the night.
PFE="$(new_repo)"
pfe="$(PF_ASKT=2 PF_PTYDL=20 ap_pty "$PFE" NONE init --spec "$TMPROOT/pf-spec.md" --scope M0)"
echo "    [tty, nobody answering] $(cage_first "$pfe")"
check "B2-idle RIG CONTROL: a prompt WAS printed and nothing answered it" \
  "printf '%s' \"\$pfe\" | qgrep -q 'PTYPROMPTS 1 ANSWERED 0'"
check "B2-idle: a terminal nobody answers still RETURNS (bounded read)" \
  "cage_first \"\$pfe\" | qgrep -q 'EXIT' && ! cage_first \"\$pfe\" | qgrep -q 'TIMED OUT'"
check "B2-idle: it says nobody answered" \
  "printf '%s' \"\$pfe\" | qgrep -qi 'nobody answered'"
check "B2-idle: and proceeds on the stated default" \
  "[ \"\$(jget '$PFE/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ]"

# --- RECORD, DON'T INFER: the fourth failure, surfaced at the gate ---------
# The run that could not open a PR had the answer on disk already. LCARS writes
# `githubIssue: null` into a mission's OWN state.json when it had no forge to
# reach; the gate re-derived its own view and missed it. preflight READS that
# record.
PFR="$(new_repo)"
ap "$PFR" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
new_mission "$PFR" lcars-pf-noissue verify
pfr_state="$PFR/.git/lcars/missions/lcars-pf-noissue/state.json"
pf_set_issue() { # <json-value>
  python3 - "$pfr_state" "$1" <<'PFPY'
import json, sys
p, v = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["githubIssue"] = None if v == "null" else int(v)
json.dump(d, open(p, "w"))
PFPY
}
pf_set_issue null
pfr="$(ap_caged 25 "$PFR" preflight)"
echo "    [no forge issue recorded] $(cage_first "$pfr")"
check "record-dont-infer: the caged run RETURNED" \
  "cage_first \"\$pfr\" | qgrep -q 'EXIT' && ! cage_first \"\$pfr\" | qgrep -q 'TIMED OUT'"
check "record-dont-infer: a mission LCARS recorded as having NO forge issue is surfaced AT THE GATE" \
  "printf '%s' \"\$pfr\" | qgrep -q 'lcars-pf-noissue' && printf '%s' \"\$pfr\" | qgrep -q 'githubIssue'"
# CONTROL: the same repo, the same command, with a real issue recorded - silent.
pf_set_issue 7
pfr2="$(ap_caged 25 "$PFR" preflight)"
check "record-dont-infer CONTROL: with an issue recorded it says nothing of the kind" \
  "! printf '%s' \"\$pfr2\" | qgrep -q 'lcars-pf-noissue'"

# --- the recorded answer is LOAD-BEARING, not theatre ----------------------
# Recording where the launch copies go would be decoration if `worktree` still
# hard-coded ${TMPDIR:-/tmp}. It is read back.
PFW="$(new_repo)"
ap "$PFW" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
mkdir -p "$TMPROOT/elsewhere"
ap "$PFW" record launchDir "$TMPROOT/elsewhere" >/dev/null 2>&1
new_mission "$PFW" lcars-pf-wt verify
pfw="$(ap "$PFW" worktree lcars-pf-wt 2>&1)"
check "the recorded launch directory is where the launch copies are MADE" \
  "printf '%s' \"\$pfw\" | qgrep -qF 'WORKTREE: $TMPROOT/elsewhere'"
# CONTROL on the SAME repo: delete the record and the launch copies go back to
# ${TMPDIR:-/tmp}. Two arms, two different directories.
ap "$PFW" record launchDir '' >/dev/null 2>&1
check "CONTROL: with none recorded they fall back to TMPDIR" \
  "printf '%s' \"\$(ap '$PFW' worktree lcars-pf-wt 2>&1)\" | qgrep -qF 'WORKTREE: $TMPROOT/tmp'"

# The playbook and the script must not drift: the mode's own prose has to name
# the verb, or the next model walks away without running it.
check "HOLOGRAM-COMMAND-MODE.md names the preflight verb, and says to run it before walking away" \
  "qgrep -qF 'lcars-ech preflight' '$APM'"
check "the driver documents the \`preflight\` subcommand in its own usage" \
  "out=\$(ap '$PFB' --help 2>&1 || true); printf '%s' \"\$out\" | qgrep -q 'preflight'"

# ==========================================================================
# S300 fix round 1 — the three environmental facts, the background launch,
#                    and a stop he can actually settle
# ==========================================================================
# WHAT A FRESH TESTER FOUND after the block above went green: preflight was
# "checking the three things it can compute locally and missing the three
# environmental facts that actually killed the nights", plus two high-severity
# holes of its own. Each arm below is one of those, and each is paired with a
# live control that must print a DIFFERENT answer.

echo
echo "-- S300 fix1. the background launch, reachability, the environment, a settleable stop --"

PTYRUN="$REPO_ROOT/tests/lib/ptyrun.py"
check "F0 the pty runner this section depends on exists" "[ -f '$PTYRUN' ]"

# --- the rigs -------------------------------------------------------------
# A FAITHFUL BACKGROUND LAUNCH, and `set -m` is what makes it faithful: job
# control is ON in every interactive and login shell, so `cmd &` there gets its
# OWN process group and is NOT the terminal's foreground group — which is the
# only condition that produces SIGTTIN. Without `set -m` the `&` child stays in
# the shell's foreground group, the bug cannot happen, and a rig built that way
# would pass while proving nothing. The verdict is read from `ps -o stat=`:
# process state `T` IS the failure, measured, not inferred.
PFBG="$TMPROOT/pf-bg.sh"
cat >"$PFBG" <<'BGRIG'
#!/usr/bin/env bash
set -m
OUT="$1"; shift
"$@" >"$OUT" 2>&1 &
child=$!
echo "BGPID $child"
i=0
while [ "$i" -lt 80 ]; do
  if kill -0 "$child" 2>/dev/null; then
    st="$(ps -o stat= -p "$child" 2>/dev/null | tr -d ' ')"
    case "$st" in
      *T*) echo "BGSTAT $st"; echo "BGVERDICT STOPPED-SIGTTIN"; kill -9 "$child" 2>/dev/null; exit 0 ;;
    esac
    echo "BGSTAT $st"
  else
    echo "BGVERDICT EXITED"
    exit 0
  fi
  sleep 0.25
  i=$((i + 1))
done
echo "BGVERDICT STILL-RUNNING"
kill -9 "$child" 2>/dev/null
exit 0
BGRIG

# ap_bg <repo> <args…> — the driver launched as a REAL background job from a
# REAL terminal: the pty is its controlling terminal, and it is in a process
# group that is not the foreground one. Prints the rig's verdict lines and then
# the driver's own output.
ap_bg() {
  local repo="$1"; shift
  mkdir -p "$TMPROOT/tmp"
  local e; e="$(pf_env "$repo" | tr '\n' ' ')"
  local out; out="$(mktemp "$TMPROOT/bg.XXXXXX")"
  local rep
  rep="$(python3 "$CAGE" 45 python3 "$PTYRUN" bash "$PFBG" "$out" env $e bash "$SCRIPT" "$@" 2>&1)"
  printf '%s\nBGCHILD-OUTPUT\n%s\n' "$rep" "$(cat "$out")"
}

# --- F1: a background launch must not hang for ever on SIGTTIN -------------
# MEASURED BEFORE THE FIX: `bash ech.sh init --spec … &` from a terminal
# printed question 1, went to process state `T`, and stayed there for the full
# 60s of observation — zero output, zero progress, no exit. That is the
# `nohup`/detached-tmux shape AND the shape ORCHESTRATION.md tells the captain
# to use ("detach every leg"), so it is the common case, not the exotic one. It
# is also exactly "a blocked run and a healthy idle run look identical from
# outside" — the failure this whole step exists to abolish — reintroduced by the
# fix for it.
PF1="$(new_repo)"
pf1="$(ap_bg "$PF1" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
echo "    [background job] $(printf '%s' "$pf1" | qgrep -o 'BGVERDICT .*' | sed -n 1p)"
check "F1 a REAL background job EXITED (it did not sit in SIGTTIN state T)" \
  "printf '%s' \"\$pf1\" | qgrep -q 'BGVERDICT EXITED'"
check "F1 and it was NEVER once observed in process state T" \
  "! printf '%s' \"\$pf1\" | qgrep -qE '^BGSTAT [A-Z]*T'"
check "F1 RIG CONTROL: the rig did observe the job running at all (it is watching something)" \
  "printf '%s' \"\$pf1\" | qgrep -qE '^BGSTAT |BGVERDICT EXITED' && printf '%s' \"\$pf1\" | qgrep -q 'BGPID '"
check "F1 it says WHY it asked nothing: it is a background job" \
  "printf '%s' \"\$pf1\" | qgrep -qi 'BACKGROUND job'"
check "F1 and it names the measurement — the foreground group it is not in" \
  "printf '%s' \"\$pf1\" | qgrep -qi 'foreground group'"
check "F1 it did the work anyway: the defaulted answer is RECORDED" \
  "[ \"\$(jget '$PF1/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ]"
check "F1 it asked nothing (a background job cannot be answered)" \
  "printf '%s' \"\$pf1\" | qgrep -q 'asked 0 question'"
# THE LIVE CONTROL. The same driver, the same repo state, the same pty — in the
# FOREGROUND. It asks. Two arms, one variable (the process group), two answers.
PF1C="$(new_repo)"
pf1c="$(ap_pty "$PF1C" "" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F1 CONTROL: in the FOREGROUND of a terminal the same run DOES ask" \
  "printf '%s' \"\$pf1c\" | qgrep -q 'asked 1 question' && printf '%s' \"\$pf1c\" | qgrep -q 'PTYPROMPTS 1 ANSWERED 1'"
check "F1 CONTROL: and the foreground arm says nothing about a background job" \
  "! printf '%s' \"\$pf1c\" | qgrep -qi 'BACKGROUND job'"

# --- F1b: the reason printed is the reason FOUND, not one guess ------------
# "NO TERMINAL — there is no /dev/tty to ask on" was printed for every case,
# including a run whose /dev/tty was perfectly good and whose stdin was merely
# redirected. Three arms, three different reasons, is the control.
PF1S="$(new_repo)"
ap "$PF1S" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
pf1s="$(STDIN_DEVNULL=1 PF_ASKT=4 ap_pty "$PF1S" NONE preflight)"
PF1N="$(new_repo)"
ap "$PF1N" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
pf1n="$(ap_caged 30 "$PF1N" preflight)"
check "F1b stdin redirected: the reason names STDIN, not a missing /dev/tty" \
  "printf '%s' \"\$pf1s\" | qgrep -qi 'stdin is not a terminal'"
check "F1b no controlling terminal: THAT reason names /dev/tty" \
  "printf '%s' \"\$pf1n\" | qgrep -qi 'no /dev/tty'"
check "F1b CONTROL: the three no-ask reasons are three DIFFERENT sentences" \
  "! printf '%s' \"\$pf1s\" | qgrep -qi 'no /dev/tty' && ! printf '%s' \"\$pf1n\" | qgrep -qi 'stdin is not a terminal' && ! printf '%s' \"\$pf1n\" | qgrep -qi 'BACKGROUND job'"

# --- F2: the push check must speak to the remote, not read its name --------
# MEASURED BEFORE THE FIX: `git remote set-url origin
# https://github.invalid.example/nope/nope.git` and a dead local path both gave
# `ELAPSED 0.4s EXIT 0 … Somewhere to push: origin -> … — not asking.` The 0.4s
# is itself the proof it never spoke to the far end. A deleted repo, a typo'd
# host and revoked auth all pass a name check and die at the pull-request gate
# at 03:00 — the fourth dead night's exact class.
PF2="$(new_repo)"
ap "$PF2" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
git -C "$PF2" remote set-url origin "$TMPROOT/there-is-no-repo-here.git"
pf2="$(ap_caged 40 "$PF2" preflight)"
echo "    [origin is a dead path] $(cage_first "$pf2")"
check "F2 RIG CONTROL: a NAME check still passes on this repo (get-url succeeds)" \
  "git -C '$PF2' remote get-url origin >/dev/null 2>&1"
check "F2 the dead remote is caught: it STOPS with the captain-question code" \
  "cage_first \"\$pf2\" | qgrep -q 'EXIT 10'"
check "F2 and it says the remote does not answer" \
  "printf '%s' \"\$pf2\" | qgrep -qi 'does NOT answer'"
check "F2 the stop is a RECORDED question, not just a printed line" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [q for q in d[\"questions\"].values() if not q.get(\"answeredAt\") and \"does not answer\" in q[\"what\"]] else 1)' '$PF2/.git/lcars/autopilot.json'"
check "F2 and it names the command that shows him what the remote said" \
  "printf '%s' \"\$pf2\" | qgrep -q 'ls-remote origin'"
# CONTROL: the SAME repo, origin pointed back at the real local bare repo it was
# created with. Reachable, and it says so. One variable, two answers.
git -C "$PF2" remote set-url origin "$PF2.git"
pf2c="$(ap_caged 40 "$PF2" preflight)"
check "F2 CONTROL: with a remote that DOES answer the same run proceeds" \
  "cage_first \"\$pf2c\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf2c\" | qgrep -qi 'reachable'"
check "F2 CONTROL: and the two arms disagree (one stops, one proceeds)" \
  "cage_first \"\$pf2\" | qgrep -q 'EXIT 10' && cage_first \"\$pf2c\" | qgrep -q 'EXIT 0'"
# AND THE PROBE ITSELF CANNOT BECOME THE HANG. A reachability check that hangs
# is strictly worse than none: it IS the silent forever-hang this step exists to
# abolish. 10.255.255.1 is a non-routable address that black-holes the SYN, so
# an unbounded probe would sit there until the TCP stack gave up (minutes).
PF2B="$(new_repo)"
ap "$PF2B" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
git -C "$PF2B" remote set-url origin https://10.255.255.1/nope/nope.git
pf2b="$(PF_PROBET=6 ap_caged 60 "$PF2B" preflight)"
pf2b_el="$(cage_first "$pf2b" | sed -n 's/^ELAPSED \([0-9.]*\)s.*/\1/p')"
echo "    [origin black-holes the connection, 6s bound] $(cage_first "$pf2b")"
check "F2b a black-holed host does NOT hang: the cage got a verdict, not a timeout" \
  "! cage_first \"\$pf2b\" | qgrep -q 'TIMED OUT' && cage_first \"\$pf2b\" | qgrep -q 'EXIT 10'"
check "F2b and it came back inside the bound it printed (measured ELAPSED ${pf2b_el:-?}s < 30s)" \
  "python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 30 else 1)' \"\${pf2b_el:-999}\""
check "F2b it says the probe outran its bound, rather than inventing a reason" \
  "printf '%s' \"\$pf2b\" | qgrep -qi 'outran its'"
check "F2b and it leaves no orphan ls-remote behind (the bound kills the group)" \
  "[ \"\$(ps -eo command= | grep -c '[l]s-remote --exit-code origin' || true)\" = 0 ]"

# --- F3: the unattended permission is NOT a prerequisite -------------------
# S303 MEASURED THE REQUIREMENT AWAY. For four nights this preflight STOPPED a
# copilot run whose COPILOT_ALLOW_ALL was not exactly `true`, on the belief that
# a run without that blanket trust is refused on every command. One S303 seat
# then stripped the variable from every child call it made (`env -u
# COPILOT_ALLOW_ALL`, 21 times) and the build still completed and merged: the
# flag is NOT load-bearing for the work. Demanding it, meanwhile, cost three
# seat models — a GPT seat refused on policy rather than rely on it, and a
# Claude Sonnet seat was blocked by its own safety classifier for being told to
# self-grant that authority and to launch a fully-trusted agent.
#
# THE NEW CONTRACT, one arm below per clause:
#   * a seat WITHOUT the flag PROCEEDS — it is not a stop, and no question is
#     recorded for the captain to answer;
#   * nothing printed instructs anyone to export it or arrange that authority;
#   * the flag is still HONOURED when the environment happens to carry it;
#   * a question an OLDER version already recorded is WITHDRAWN, so a captain
#     who ran the requiring build is not left holding a dead question.
# Every arm keeps a CONTROL, because the only way this regresses is someone
# re-introducing the stop, and a test that cannot go red would not see it.
PF3="$(new_repo)"
pf3="$(PF_ALLOW_ALL= ap_caged 40 "$PF3" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
echo "    [engine copilot, COPILOT_ALLOW_ALL unset] $(cage_first "$pf3")"
check "F3a COPILOT_ALLOW_ALL unset on a copilot run PROCEEDS — it is not a prerequisite" \
  "cage_first \"\$pf3\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf3\" | qgrep -qF 'NOT a prerequisite'"
check "F3a it is still NAMED, so a reader can see it was considered and dismissed" \
  "printf '%s' \"\$pf3\" | qgrep -q 'COPILOT_ALLOW_ALL'"
check "F3a it does NOT instruct anyone to export it (nothing self-grants trust)" \
  "! printf '%s' \"\$pf3\" | qgrep -qF 'export COPILOT_ALLOW_ALL'"
check "F3a and NO question is recorded for the captain to answer" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(1 if [q for q in d.get(\"questions\",{}).values() if not q.get(\"answeredAt\") and \"COPILOT_ALLOW_ALL\" in q.get(\"what\",\"\")] else 0)' '$PF3/.git/lcars/autopilot.json'"
# CONTROL 1: a captain whose environment DOES carry it is told it is honoured,
# and that arm proceeds too — the two arms now AGREE, which is the whole point.
pf3c="$(ap_caged 40 "$PF3" preflight)"
check "F3a CONTROL: with COPILOT_ALLOW_ALL=true exported the same run also proceeds" \
  "cage_first \"\$pf3c\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf3c\" | qgrep -qi 'honoured'"
check "F3a CONTROL: the two arms AGREE — neither the presence nor the absence is a stop" \
  "cage_first \"\$pf3\" | qgrep -q 'EXIT 0' && cage_first \"\$pf3c\" | qgrep -q 'EXIT 0'"
# CONTROL 2, AND THIS ONE IS THE NON-VACUOUS GUARD. `EXIT 0` only means
# something if this same preflight, this same harness, can still return EXIT 10
# on a prerequisite that IS load-bearing. F2's unreachable-remote arm is that
# proof: a run with nowhere to push still stops dead. If someone neutered
# `pf_stop` rather than this one question, THIS is the check that goes red.
check "F3a NOT VACUOUS: the same preflight still STOPS on a genuinely fatal gap" \
  "cage_first \"\$pf2\" | qgrep -q 'EXIT 10' && printf '%s' \"\$pf2\" | qgrep -qi 'STOPPING'"
# TRUTHY-BUT-WRONG used to be a FAILING value that stopped the run: `1`, `yes`,
# `on` and `y` auto-approve TOOLS without trusting the working directory. The
# distinction is still TRUE of copilot and still worth reporting — it is just
# not a reason to refuse to start, because no spelling of it is required.
PF3T="$(new_repo)"
ap "$PF3T" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
pf3t="$(PF_ALLOW_ALL=1 ap_caged 40 "$PF3T" preflight)"
check "F3b COPILOT_ALLOW_ALL=1 no longer refuses the run (no spelling is required)" \
  "cage_first \"\$pf3t\" | qgrep -q 'EXIT 0'"
check "F3b it still REPORTS the value it found rather than hiding it" \
  "printf '%s' \"\$pf3t\" | qgrep -qF '\"1\"'"
check "F3b CONTROL: and it does not demand the string true as a remedy" \
  "! printf '%s' \"\$pf3t\" | qgrep -qF 'export COPILOT_ALLOW_ALL'"
# MIGRATION: a captain who ran the REQUIRING build has the old question sitting
# open in his inbox. Curing the requirement must retire it, or he is left
# answering a question that is no longer true to unstick his own run — the
# defect `pf_withdraw_say` exists to prevent. The `what` below is the literal
# legacy ledger key, as it is written in the autopilot.json files on disk.
PF3W="$(new_repo)"
ap "$PF3W" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
python3 - "$PF3W/.git/lcars/autopilot.json" <<'PFW'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
qs = d.setdefault("questions", {})
qs["q99"] = {
    "id": "q99",
    "mission": "-",
    "what": "the engine has no unattended permission: COPILOT_ALLOW_ALL is not exactly `true`, so an unattended copilot run is refused on every command.",
    "why": "recorded by the build that still required it",
    "command": "export COPILOT_ALLOW_ALL=true",
    "rollback": "nothing has run",
    "raisedAt": "2026-10-13T00:00:00Z",
}
json.dump(d, open(p, "w"))
PFW
pf3w="$(PF_ALLOW_ALL= ap_caged 40 "$PF3W" preflight)"
check "F3d MIGRATION: a question the requiring build recorded is WITHDRAWN" \
  "printf '%s' \"\$pf3w\" | qgrep -qF 'WITHDRAWN [q99]'"
check "F3d MIGRATION: and it is closed on the record, not just un-printed" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"questions\"][\"q99\"].get(\"answeredAt\") else 1)' '$PF3W/.git/lcars/autopilot.json'"
check "F3d CONTROL: that arm really did start with the question OPEN (not vacuous)" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if \"q99\" in d[\"questions\"] else 1)' '$PF3W/.git/lcars/autopilot.json'"
# ENGINE-AWARE: a claude run never had the variable in play, and still says so.
# The engine distinction survives the cure — it is now about WHAT IS SAID
# rather than about who stops, and the control pins that it is still a real
# difference and not the same sentence twice.
PF3E="$(new_repo)"
python3 - "$PF3E/.git/lcars/config.json" <<'PFE'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["engine"] = "claude"
json.dump(d, open(p, "w"))
PFE
pf3e="$(PF_ALLOW_ALL= ap_caged 40 "$PF3E" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F3c engine-aware: a CLAUDE run says the variable is a copilot fact" \
  "cage_first \"\$pf3e\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf3e\" | qgrep -qi 'engine is claude'"
check "F3c CONTROL: the COPILOT arm does NOT claim to be a claude run" \
  "cage_first \"\$pf3\" | qgrep -q 'EXIT 0' && ! printf '%s' \"\$pf3\" | qgrep -qi 'engine is claude'"

# 2. `gh auth status`. No authentication, no pull request — the same class and
#    the same cost as having no remote, and a one-line check.
PF3G="$(new_repo)"
ap "$PF3G" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
PF3G_J="$PF3G/.git/lcars/autopilot.json"
# A forge-SHAPED url (so there IS an account to log in to) at a non-routable
# address (so no arm here depends on the network). Its reachability question is
# answered first, deliberately: this arm measures the LOGIN, not the host.
git -C "$PF3G" remote set-url origin https://10.255.255.1/nope/nope.git
pf3g0="$(PF_PROBET=4 PF_GH="$PFGH_YES" ap_caged 60 "$PF3G" preflight)"
ap "$PF3G" answered "$(jget "$PF3G_J" 'd["pending"]["id"]')" "push anyway" >/dev/null 2>&1
pf3g="$(PF_PROBET=4 PF_GH="$PFGH_NO" ap_caged 60 "$PF3G" preflight)"
echo "    [forge remote, gh logged OUT] $(cage_first "$pf3g")"
check "F3d a forge remote with the CLI logged OUT is caught" \
  "printf '%s' \"\$pf3g\" | qgrep -qi 'NOT logged in'"
check "F3d it STOPS: no login, no pull request, whatever the run builds" \
  "cage_first \"\$pf3g\" | qgrep -q 'EXIT 10'"
check "F3d and it names the one command that fixes it" \
  "printf '%s' \"\$pf3g\" | qgrep -q 'auth login'"
check "F3d recorded as a settleable question" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [q for q in d[\"questions\"].values() if not q.get(\"answeredAt\") and \"not logged in\" in q[\"what\"]] else 1)' '$PF3G/.git/lcars/autopilot.json'"
# CONTROL: the same repo, the same remote, a logged-IN CLI. Proceeds.
pf3gc="$(PF_PROBET=4 PF_GH="$PFGH_YES" ap_caged 60 "$PF3G" preflight)"
check "F3d CONTROL: with the CLI logged IN the same run proceeds" \
  "printf '%s' \"\$pf3gc\" | qgrep -qi 'says logged in' && ! printf '%s' \"\$pf3gc\" | qgrep -qi 'NOT logged in'"
# AND IT IS SCOPED. The suite's own origin is a local bare repo: there is no
# forge and no account, so stopping on a login would be a false stop. Fourth
# answer from the same check.
check "F3d scoped: a LOCAL-path origin has no forge to log in to, and is not stopped on" \
  "printf '%s' \"\$pf2c\" | qgrep -qi 'local path' && cage_first \"\$pf2c\" | qgrep -q 'EXIT 0'"

# --- F4: the stop must be SETTLEABLE, and must WITHDRAW when cured ---------
# MEASURED BEFORE THE FIX, both halves:
#   `answered q1 "ship local-only, no push"` recorded the answer and NOTHING
#   read it, so the next preflight minted q2 with identical text. Four attempts
#   produced ['q1','q2','q3','q4','q5'] — one question, five times, in the inbox
#   of a man answering from his phone.
#   And after `git remote add origin …`, preflight said `proceeding` while
#   `status` still showed `open questions: 1 [q5] … no origin remote` and `next`
#   said `answer-pending`: he had to hand-answer something no longer true to
#   unstick a run that was already unstuck.
PF4="$(new_repo)"; git -C "$PF4" remote remove origin
PF4_J="$PF4/.git/lcars/autopilot.json"
pf4a="$(ap_caged 40 "$PF4" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf4qid="$(jget "$PF4_J" 'd["pending"]["id"]')"
check "F4 the no-remote stop raised exactly ONE question, with an id" \
  "[ -n '$pf4qid' ] && [ \"\$(jget '$PF4_J' 'len(d[\"questions\"])')\" = 1 ]"
# He answers it, from his phone, in his own words.
ap "$PF4" answered "$pf4qid" "ship local-only, no push" >/dev/null 2>&1
pf4b="$(ap_caged 40 "$PF4" preflight)"
pf4c="$(ap_caged 40 "$PF4" preflight)"
pf4d="$(ap_caged 40 "$PF4" preflight)"
echo "    [answered, then three more preflights] $(cage_first "$pf4d") / questions: $(jget "$PF4_J" 'sorted(d["questions"])')"
check "F4a his answer is READ: the stop is settled and the run proceeds" \
  "cage_first \"\$pf4b\" | qgrep -q 'EXIT 0'"
check "F4a and three further runs mint NO clones — still exactly one question" \
  "[ \"\$(jget '$PF4_J' 'len(d[\"questions\"])')\" = 1 ]"
check "F4a the free-form answer is ACTED ON, not just stored (push.mode = local-only)" \
  "[ \"\$(jget '$PF4_J' 'd[\"push\"][\"mode\"]')\" = 'local-only' ]"
check "F4a and it says whose decision it is proceeding on" \
  "printf '%s' \"\$pf4b\" | qgrep -qi 'SETTLED BY YOU'"
# CONTROL: the identical repo state with the question LEFT UNANSWERED keeps
# stopping, and says nothing about being settled. One variable: the answer.
PF4U="$(new_repo)"; git -C "$PF4U" remote remove origin
pf4u1="$(ap_caged 40 "$PF4U" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf4u2="$(ap_caged 40 "$PF4U" preflight)"
check "F4a CONTROL: unanswered, the same stop still stops" \
  "cage_first \"\$pf4u2\" | qgrep -q 'EXIT 10' && ! printf '%s' \"\$pf4u2\" | qgrep -qi 'SETTLED BY YOU'"
check "F4a CONTROL: and it still never minted a second question either" \
  "[ \"\$(jget '$PF4U/.git/lcars/autopilot.json' 'len(d[\"questions\"])')\" = 1 ]"

# WITHDRAWAL: cure the cause and the question retires itself.
PF4W="$(new_repo)"; git -C "$PF4W" remote remove origin
PF4W_J="$PF4W/.git/lcars/autopilot.json"
pf4w1="$(ap_caged 40 "$PF4W" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf4w_before_status="$(ap "$PF4W" status 2>&1 || true)"
pf4w_before_next="$(ap "$PF4W" next 2>&1 || true)"
git -C "$PF4W" remote add origin "$PF4W.git"
pf4w2="$(ap_caged 40 "$PF4W" preflight)"
pf4w_after_status="$(ap "$PF4W" status 2>&1 || true)"
pf4w_after_next="$(ap "$PF4W" next 2>&1 || true)"
check "F4b CONTROL (before the cure): status shows the open question and next is parked" \
  "printf '%s' \"\$pf4w_before_status\" | qgrep -q 'open questions for the captain: 1' && printf '%s' \"\$pf4w_before_next\" | qgrep -q 'answer-pending'"
check "F4b after the cure the run proceeds" \
  "cage_first \"\$pf4w2\" | qgrep -q 'EXIT 0'"
check "F4b and the question WITHDRAWS itself — he never answers a dead question" \
  "printf '%s' \"\$pf4w2\" | qgrep -q 'WITHDRAWN'"
check "F4b status agrees: nothing is open any more" \
  "printf '%s' \"\$pf4w_after_status\" | qgrep -q 'open questions for the captain: none'"
check "F4b and next is no longer parked on an answer that is not needed" \
  "! printf '%s' \"\$pf4w_after_next\" | qgrep -q 'answer-pending'"
check "F4b it never DELETED the question — the record keeps it, withdrawn" \
  "[ \"\$(jget '$PF4W_J' 'len(d[\"questions\"])')\" = 1 ] && [ -n \"\$(jget '$PF4W_J' 'd[\"questions\"][\"q1\"].get(\"withdrawnAt\")')\" ]"
# A WITHDRAWAL IS NOT A DECISION. Break it again: a prerequisite that breaks
# AFTER being cured is a real new event and must earn a real new question, not
# proceed silently on preflight's own retirement note.
git -C "$PF4W" remote remove origin
pf4w3="$(ap_caged 40 "$PF4W" preflight)"
check "F4c a prerequisite that breaks AGAIN raises a real new question" \
  "cage_first \"\$pf4w3\" | qgrep -q 'EXIT 10' && [ \"\$(jget '$PF4W_J' 'len(d[\"questions\"])')\" = 2 ]"
check "F4c CONTROL: and it did NOT read its own withdrawal as the captain's decision" \
  "! printf '%s' \"\$pf4w3\" | qgrep -qi 'SETTLED BY YOU'"
# AN ANSWER IT CANNOT ACT ON is said out loud and raises NOTHING. The inbox is
# never the place a misunderstanding multiplies.
PF4G="$(new_repo)"; git -C "$PF4G" remote remove origin
pf4g1="$(ap_caged 40 "$PF4G" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
ap "$PF4G" answered q1 "ok" >/dev/null 2>&1
pf4g2="$(ap_caged 40 "$PF4G" preflight)"
check "F4d an answer that is neither a URL nor local-only is named as unusable" \
  "printf '%s' \"\$pf4g2\" | qgrep -qi 'cannot act on it'"
check "F4d it still stops (nothing was invented) but raises no clone" \
  "cage_first \"\$pf4g2\" | qgrep -q 'EXIT 10' && [ \"\$(jget '$PF4G/.git/lcars/autopilot.json' 'len(d[\"questions\"])')\" = 1 ]"

# --- F5: an answer that cannot work is caught while he is in the room ------
# MEASURED: `/nonexistent/…`, `/System/Library` (real, unwritable) and a bare
# `ok` were all accepted verbatim — `ok` recorded as a RELATIVE launchDir — and
# each one fails hours later inside `worktree`, with nobody there.
PF5="$(new_repo)"
pf5="$(ap_pty "$PF5" "ok" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F5 a relative answer is NOT recorded as the launch directory" \
  "[ \"\$(jget '$PF5/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" != 'ok' ]"
check "F5 it says why, and names the vetted default it took instead" \
  "printf '%s' \"\$pf5\" | qgrep -qi 'not an absolute path' && [ \"\$(jget '$PF5/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ]"
PF5U="$(new_repo)"
pf5u="$(ap_pty "$PF5U" "/System/Library" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F5 a real but UNWRITABLE directory is not recorded either" \
  "[ \"\$(jget '$PF5U/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" = '$TMPROOT/tmp' ] && printf '%s' \"\$pf5u\" | qgrep -qi 'NOT WRITABLE'"
# CONTROL: a writable absolute answer IS recorded, so this is a check and not a
# refusal to listen.
PF5W="$(new_repo)"
mkdir -p "$TMPROOT/launch-here"
pf5w="$(ap_pty "$PF5W" "$TMPROOT/launch-here" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F5 CONTROL: a writable absolute answer IS recorded, verbatim" \
  "[ \"\$(jget '$PF5W/.git/lcars/autopilot.json' 'd[\"launchDir\"]')\" = '$TMPROOT/launch-here' ]"

# --- F7: the driver must not offer to drive past its own preflight stop ----
# MEASURED: the driver printed `ALSO RUNNABLE: foundation` beside its own
# preflight stop, while HOLOGRAM-COMMAND-MODE.md says plainly not to drive a milestone past
# one. `next` is the one line a model reads for its next move, so the two
# surfaces cannot disagree there.
PF7="$(new_repo)"; git -C "$PF7" remote remove origin
pf7init="$(ap_caged 40 "$PF7" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf7="$(ap "$PF7" next 2>&1 || true)"
check "F7 a run-wide prerequisite is surfaced as the next step" \
  "printf '%s' \"\$pf7\" | qgrep -q 'answer-pending'"
check "F7 and NOTHING else is offered beside it" \
  "! printf '%s' \"\$pf7\" | qgrep -q 'ALSO RUNNABLE' && printf '%s' \"\$pf7\" | qgrep -q 'NOTHING ELSE IS OFFERED'"
check "F7 it names the way out rather than a milestone to drive" \
  "printf '%s' \"\$pf7\" | qgrep -qi 'do not drive a milestone past a preflight stop'"
# CONTROL: § 9 is untouched — a question filed against ONE MILESTONE still parks
# only that milestone, and `next` still names the other milestone's work. Same
# command, same verb, a question with a mission instead of none.
check "F7 CONTROL: a MILESTONE question still leaves the other milestone runnable" \
  "printf '%s' \"\$nx14\" | qgrep -q 'answer-pending' && printf '%s' \"\$nx14\" | qgrep -q 'verify-gate lcars-ready-1' && ! printf '%s' \"\$nx14\" | qgrep -q 'NOTHING ELSE IS OFFERED'"

# ==========================================================================
# S300 fix round 2 — what a fresh tester measured on the cures above
# ==========================================================================
echo "-- S300r2. a deadline is not a refusal; one command settles local-only --"

# --- F8: a HEALTHY BUT SLOW remote must not be called dead ----------------
# MEASURED: an `ext::` origin that answers correctly after 25s (a cold VPN
# handshake, a monorepo with a huge ref advertisement, a loaded forge all look
# like this). `git ls-remote origin` → EXIT 0 with refs in 25.2s. Preflight →
# `ELAPSED 15.8s EXIT 10`, headline "The remote does NOT answer", body blaming
# "a deleted repo, a typo'd host and revoked auth", advice "fix the URL or the
# auth". Every word of that is FALSE for this repo, and the only honest part —
# `rc 124` — was in small type underneath it. Worse, it is the ONE stop that can
# never retire itself, because the remote stays slow, so it demands an answer
# for ever.
#
# THE RIG. `ext::` runs a command as the transport, so a slow-but-correct remote
# is a script that sleeps and then serves the suite's OWN bare repo. No network
# is involved, and the far side is genuinely healthy — which is the whole point.
PF8="$(new_repo)"
PF8_J="$PF8/.git/lcars/autopilot.json"
cat >"$TMPROOT/slowpack" <<SLOW
#!/bin/sh
sleep 6
exec git upload-pack "$PF8.git"
SLOW
chmod +x "$TMPROOT/slowpack"
git -C "$PF8" remote set-url origin "ext::$TMPROOT/slowpack"
git -C "$PF8" config protocol.ext.allow always
# RIG CONTROL, LIVE AND TIMED: the remote this arm calls "may be slow" really
# does answer. Without this the arm could be measuring a broken fixture.
pf8_t0="$(date +%s)"
pf8_refs="$(git -C "$PF8" ls-remote origin 2>/dev/null | wc -l | tr -d ' ')"
pf8_el=$(( $(date +%s) - pf8_t0 ))
echo "    [ext:: origin, sleeps 6s then serves the real bare repo] unbounded ls-remote: ${pf8_refs} ref(s) in ${pf8_el}s"
check "F8 RIG CONTROL: the remote is HEALTHY — an unbounded ls-remote returns refs" \
  "[ '$pf8_refs' -ge 1 ]"
check "F8 RIG CONTROL: and it is genuinely SLOWER than the bound the probe will use" \
  "[ '$pf8_el' -ge 4 ]"
ap "$PF8" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
pf8="$(PF_PROBET=3 ap_caged 60 "$PF8" preflight)"
pf8qid="$(jget "$PF8_J" 'd["pending"]["id"]')"
echo "    [preflight, 3s bound] $(cage_first "$pf8")"
check "F8a it does NOT claim the remote does not answer" \
  "! printf '%s' \"\$pf8\" | qgrep -qi 'does NOT answer'"
check "F8a it names the DEADLINE instead, and says git never refused" \
  "printf '%s' \"\$pf8\" | qgrep -qi 'did not answer IN TIME' && printf '%s' \"\$pf8\" | qgrep -qF 'rc 124' && printf '%s' \"\$pf8\" | qgrep -qi 'git never said no'"
check "F8b it blames NOTHING it cannot support — no deleted repo, typo, revoked auth" \
  "! printf '%s' \"\$pf8\" | qgrep -qi 'deleted' && ! printf '%s' \"\$pf8\" | qgrep -qi \"typo\" && ! printf '%s' \"\$pf8\" | qgrep -qi 'revoked auth'"
check "F8b and it does not advise fixing the URL or the auth" \
  "! printf '%s' \"\$pf8\" | qgrep -qi 'fix the URL'"
check "F8c it says the remote may simply be SLOW, and names the healthy causes" \
  "printf '%s' \"\$pf8\" | qgrep -qi 'may simply be slow' && printf '%s' \"\$pf8\" | qgrep -qi 'VPN'"
check "F8d it offers the settle route explicitly, as a command he can paste" \
  "printf '%s' \"\$pf8\" | qgrep -qF \"answered <id> \\\"it's just slow\\\"\""
check "F8d and the widen-the-bound route, with the variable that does it" \
  "printf '%s' \"\$pf8\" | qgrep -qF 'LCARS_ECH_PROBE_TIMEOUT=60'"
check "F8e it says this stop cannot retire itself (a slow remote stays slow)" \
  "printf '%s' \"\$pf8\" | qgrep -qi 'cannot retire itself'"
check "F8f the INBOX headline is the deadline, not the false 'cannot reach' one" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [q for q in d[\"questions\"].values() if not q.get(\"answeredAt\") and \"inside the probe deadline\" in q[\"what\"]] else 1)' '$PF8_J'"
check "F8f and the recorded WHY calls it a deadline rather than a refusal" \
  "printf '%s' \"\$(jget '$PF8_J' 'd[\"pending\"][\"why\"]')\" | qgrep -qi 'a deadline, not a refusal'"
check "F8f the recorded COMMAND offers the settle route and does NOT say fix the URL" \
  "printf '%s' \"\$(jget '$PF8_J' 'd[\"pending\"][\"command\"]')\" | qgrep -qF \"it's just slow\" && ! printf '%s' \"\$(jget '$PF8_J' 'd[\"pending\"][\"command\"]')\" | qgrep -qi 'fix the URL'"
# IT CLEARS FOR GOOD. The whole complaint is that this stop can never retire
# itself, so the escape hatch it prints has to work on the very next run.
ap "$PF8" answered "$pf8qid" "it's just slow" >/dev/null 2>&1
pf8s="$(PF_PROBET=3 ap_caged 60 "$PF8" preflight)"
pf8s2="$(PF_PROBET=3 ap_caged 60 "$PF8" preflight)"
check "F8g the printed settle route WORKS: the next run proceeds on his answer" \
  "cage_first \"\$pf8s\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf8s\" | qgrep -qi 'SETTLED BY YOU'"
check "F8g and a slow remote that stays slow mints NO clone (still one question)" \
  "cage_first \"\$pf8s2\" | qgrep -q 'EXIT 0' && [ \"\$(jget '$PF8_J' 'len(d[\"questions\"])')\" = 1 ]"
# THE LIVE CONTROL: a remote that genuinely REFUSES, fast, on the same preflight.
# 127.0.0.1:1 is nothing listening — connection refused in 0ms, no network, no
# bound involved — so rc is a refusal and not 124. One variable (slow vs
# refusing), and the two arms must print DIFFERENT findings.
PF8C="$(new_repo)"
git -C "$PF8C" remote set-url origin https://127.0.0.1:1/nope/nope.git
ap "$PF8C" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
pf8c="$(PF_PROBET=3 PF_GH="$PFGH_YES" ap_caged 60 "$PF8C" preflight)"
echo "    [CONTROL: https origin, connection REFUSED] $(cage_first "$pf8c")"
check "F8 CONTROL: a remote that REFUSES keeps the genuine-failure wording" \
  "printf '%s' \"\$pf8c\" | qgrep -qi 'does NOT answer' && printf '%s' \"\$pf8c\" | qgrep -qi 'deleted'"
# The ADVICE lives in the recorded question (that is what reaches his inbox),
# and both arms are read out of the same field so the comparison is honest.
check "F8 CONTROL: and the question it files still advises fixing the URL or the auth" \
  "printf '%s' \"\$(jget '$PF8C/.git/lcars/autopilot.json' 'd[\"pending\"][\"command\"]')\" | qgrep -qi 'fix the URL'"
check "F8 CONTROL: the two arms DISAGREE — neither sentence appears in both" \
  "! printf '%s' \"\$pf8c\" | qgrep -qi 'may simply be slow' && ! printf '%s' \"\$pf8\" | qgrep -qi 'fix the URL'"
check "F8 CONTROL: and its inbox headline is the unreachable one, not the deadline" \
  "python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [q for q in d[\"questions\"].values() if \"git cannot reach\" in q[\"what\"]] else 1)' '$PF8C/.git/lcars/autopilot.json'"

# --- F9: "settleable in one command" has to be TRUE for the offline captain -
# MEASURED: an https origin with the forge CLI logged out raised BOTH the push
# question and the gh-auth question. `answered q1 "ship local-only, no push"`
# answered the first and printed "Still open: q2", and the next preflight still
# stopped on the forge login. So the offline/train/local-only case cost TWO
# commands against a playbook that promises one — and it contradicted the login
# check's own stated scope ("skipped when … a run recorded as local-only"): a
# question answered *local-only* is the plainest record of that intent there is.
PF9="$(new_repo)"
PF9_J="$PF9/.git/lcars/autopilot.json"
git -C "$PF9" remote set-url origin https://127.0.0.1:1/nope/nope.git
pf9a="$(PF_PROBET=3 PF_GH="$PFGH_NO" ap_caged 60 "$PF9" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf9qid="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next((k for k,q in sorted(d["questions"].items()) if "push remote" in q["what"]), ""))' "$PF9_J")"
echo "    [https origin + logged OUT] $(cage_first "$pf9a") / questions: $(jget "$PF9_J" 'sorted(d["questions"])')"
check "F9 RIG CONTROL: this state really does raise BOTH questions (two cards)" \
  "[ \"\$(jget '$PF9_J' 'len(d[\"questions\"])')\" = 2 ] && [ -n '$pf9qid' ]"
# ONE command, in his own words, from his phone.
pf9ans="$(ap "$PF9" answered "$pf9qid" "ship local-only, no push" 2>&1)"
pf9b="$(PF_PROBET=3 PF_GH="$PFGH_NO" ap_caged 60 "$PF9" preflight)"
echo "    [after ONE answer: ship local-only, no push] $(cage_first "$pf9b")"
check "F9a ONE answer is enough: the whole round proceeds" \
  "cage_first \"\$pf9b\" | qgrep -q 'EXIT 0'"
check "F9b the forge-login check is SKIPPED, and says on whose authority" \
  "printf '%s' \"\$pf9b\" | qgrep -q 'NOT CHECKED' && printf '%s' \"\$pf9b\" | qgrep -qF \"you answered [$pf9qid]\""
check "F9b it never ran the probe it had nothing to prove with" \
  "! printf '%s' \"\$pf9b\" | qgrep -qi 'NOT logged in'"
check "F9c and the forge question WITHDRAWS — his inbox is empty, not at one" \
  "printf '%s' \"\$(ap '$PF9' status 2>&1)\" | qgrep -q 'open questions for the captain: none'"
check "F9d \`answered\` itself says he does not owe the second one an answer" \
  "printf '%s' \"\$pf9ans\" | qgrep -qi 'you do not owe it an answer'"
# THE LIVE CONTROL: the identical repo state and the identical verb, with an
# answer that means the OPPOSITE. One variable (what he decided), two answers.
PF9C="$(new_repo)"
PF9C_J="$PF9C/.git/lcars/autopilot.json"
git -C "$PF9C" remote set-url origin https://127.0.0.1:1/nope/nope.git
pf9c0="$(PF_PROBET=3 PF_GH="$PFGH_NO" ap_caged 60 "$PF9C" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
pf9cqid="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next((k for k,q in sorted(d["questions"].items()) if "push remote" in q["what"]), ""))' "$PF9C_J")"
pf9cans="$(ap "$PF9C" answered "$pf9cqid" "push anyway" 2>&1)"
pf9c="$(PF_PROBET=3 PF_GH="$PFGH_NO" ap_caged 60 "$PF9C" preflight)"
check "F9 CONTROL: answered 'push anyway' instead, the login check still RUNS and STOPS" \
  "cage_first \"\$pf9c\" | qgrep -q 'EXIT 10' && printf '%s' \"\$pf9c\" | qgrep -qi 'NOT logged in'"
check "F9 CONTROL: and it is NOT skipped as local-only (the two arms disagree)" \
  "! printf '%s' \"\$pf9c\" | qgrep -q 'NOT CHECKED'"
check "F9 CONTROL: \`answered 'push anyway'\` still names the second question as owed" \
  "printf '%s' \"\$pf9cans\" | qgrep -q 'Still open' && ! printf '%s' \"\$pf9cans\" | qgrep -qi 'do not owe'"

# --- F10: `record localOnly true` must DO something, or refuse -------------
# MEASURED: it printed "recorded localOnly" and nothing read it — a repo with no
# remote kept stopping at question 3. An accepted key that does nothing is the
# worst of the three available behaviours: it reads as success.
PF10="$(new_repo)"; git -C "$PF10" remote remove origin
PF10_J="$PF10/.git/lcars/autopilot.json"
pf10a="$(ap_caged 40 "$PF10" init --spec "$TMPROOT/pf-spec.md" --scope M0)"
check "F10 CONTROL (before): with no remote and no record, preflight STOPS" \
  "cage_first \"\$pf10a\" | qgrep -q 'EXIT 10'"
pf10rec="$(ap "$PF10" record localOnly true 2>&1)"
pf10b="$(ap_caged 40 "$PF10" preflight)"
echo "    [record localOnly true, then preflight] $(cage_first "$pf10b")"
check "F10a the record says which key it landed in, not just 'recorded'" \
  "printf '%s' \"\$pf10rec\" | qgrep -qF 'push.mode = local-only'"
check "F10a and it is HONOURED: the same repo now proceeds" \
  "cage_first \"\$pf10b\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf10b\" | qgrep -q 'NOT ASKING'"
check "F10a the push question withdraws itself rather than waiting on him" \
  "printf '%s' \"\$(ap '$PF10' status 2>&1)\" | qgrep -q 'open questions for the captain: none'"
check "F10a and it names the undo" \
  "printf '%s' \"\$pf10rec\" | qgrep -qF 'record push.mode origin'"
# IT IS REVERSIBLE — a second answer from the same verb.
ap "$PF10" record localOnly false >/dev/null 2>&1
pf10c="$(ap_caged 40 "$PF10" preflight)"
check "F10b CONTROL: \`record localOnly false\` clears it and the stop comes back" \
  "cage_first \"\$pf10c\" | qgrep -q 'EXIT 10'"
# AND IT IS SPECIFIC. A key that is NOT this one is still stored verbatim and
# still changes nothing — so F10a measured an alias, not a blanket effect.
ap "$PF10" record somethingElse true >/dev/null 2>&1
pf10d="$(ap_caged 40 "$PF10" preflight)"
check "F10b CONTROL: an unrelated key is stored verbatim and does NOT unstick it" \
  "[ \"\$(jget '$PF10_J' 'd[\"somethingElse\"]')\" = true ] && cage_first \"\$pf10d\" | qgrep -q 'EXIT 10'"
check "F10c a value that is neither true nor false is REFUSED, not stored silently" \
  "! ap '$PF10' record localOnly maybe >/dev/null 2>&1"
# AND A RECORDED LOCAL-ONLY RUN IS NOT OVERRULED BY A REMOTE BEING PRESENT. The
# old body wrote push.mode = origin unconditionally and then probed a remote the
# run was never going to use.
PF10R="$(new_repo)"
git -C "$PF10R" remote set-url origin https://127.0.0.1:1/nope/nope.git
ap "$PF10R" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
ap "$PF10R" record localOnly true >/dev/null 2>&1
pf10r="$(PF_PROBET=3 PF_GH="$PFGH_NO" ap_caged 60 "$PF10R" preflight)"
check "F10d with an origin present, a recorded local-only run neither uses nor probes it" \
  "cage_first \"\$pf10r\" | qgrep -q 'EXIT 0' && printf '%s' \"\$pf10r\" | qgrep -qi 'neither used nor probed'"
check "F10d and the forge login is skipped too (one decision, both questions)" \
  "printf '%s' \"\$pf10r\" | qgrep -q 'NOT CHECKED' && ! printf '%s' \"\$pf10r\" | qgrep -qi 'NOT logged in'"

# --- F11: the bound must leave no `ppid 1` orphan, measured over HTTPS ------
# MEASURED on the https black-hole probe: `93085 ppid 1 … git-remote-https
# origin https://10.255.255.1/x.git`, still alive 50s later, drifting toward
# libcurl's ~300s connect timeout. The bound SIGKILLed the DIRECT CHILD, so the
# transport helper one level down survived and re-parented to init.
#
# WHY F2b DID NOT CATCH IT: F2b greps for `ls-remote --exit-code origin` — the
# process that IS killed. The survivor is the helper `git ls-remote` execs, and
# only the URL attributes it. A `ppid 1` orphan outlives the cage and corrupts
# every later process measurement (`harness` 7b asserts zero attributed ones),
# so this arm watches for the helper, by URL, on an HTTPS remote.
PF11="$(new_repo)"
PF11_URL="https://10.255.255.231/orphan-f11/x.git"
git -C "$PF11" remote set-url origin "$PF11_URL"
ap "$PF11" init --spec "$TMPROOT/pf-spec.md" --scope M0 >/dev/null 2>&1
f11_helpers() { ps -eo pid=,ppid=,command= | grep 'remote-https' | grep -c '10\.255\.255\.231' || true; }
f11_orphans() { ps -eo pid=,ppid=,command= | grep 'remote-https' | grep '10\.255\.255\.231' | awk '$2 == 1' | wc -l | tr -d ' '; }
pf11_out="$TMPROOT/f11.out"
( PF_PROBET=6 ap_caged 60 "$PF11" preflight >"$pf11_out" 2>&1 ) &
pf11_pid=$!
BG_PIDS="$BG_PIDS $pf11_pid"
sleep 3
pf11_during="$(f11_helpers)"
wait "$pf11_pid" 2>/dev/null || true
sleep 2
pf11_after="$(f11_helpers)"
pf11_orph="$(f11_orphans)"
pf11="$(cat "$pf11_out")"
echo "    [https black hole, 6s bound] $(cage_first "$pf11") / helpers during: $pf11_during  after: $pf11_after  at ppid 1: $pf11_orph"
check "F11 RIG CONTROL (live): the transport helper IS spawned — so zero after means something" \
  "[ '$pf11_during' -ge 1 ]"
check "F11 RIG CONTROL: the probe really did hit the bound on this arm" \
  "cage_first \"\$pf11\" | qgrep -q 'EXIT 10' && printf '%s' \"\$pf11\" | qgrep -qF 'rc 124'"
check "F11a NO git-remote-https survives the run (the bound kills the GROUP)" \
  "[ '$pf11_after' = 0 ]"
check "F11b and specifically ZERO at ppid 1 — nothing re-parented to init" \
  "[ '$pf11_orph' = 0 ]"

# --- F12: no raw job-control line in the captain's report ------------------
# SEEN mid-report, between items 3 and 3b:
#   ech.sh: line 740: 93081 Killed: 9  "$@" > /dev/null 2>&1 < /dev/null
# It exposes an internal line number and a raw `"$@"`, and reads like a crash to
# a human at 03:00. Measured on the arms above, which are the ones that kill.
check "F12a the report carries no job-control notification (no 'Killed: 9')" \
  "! printf '%s' \"\$pf11\" | qgrep -qF 'Killed: 9' && ! printf '%s' \"\$pf8\" | qgrep -qF 'Killed: 9'"
check "F12a and no internal line number or raw \"\\\$@\" leaks into it" \
  "! printf '%s' \"\$pf11\" | qgrep -qE 'ech\.sh: line [0-9]+:' && ! printf '%s' \"\$pf8\" | qgrep -qE 'ech\.sh: line [0-9]+:'"
# THE CONTROL THAT GIVES THAT ASSERTION TEETH. The same bash, the same SIGKILL,
# in the shape the driver used to have: spawn, kill the child, reap it in THIS
# shell. If that arm were silent too, F12a would be measuring nothing.
f12old="$TMPROOT/f12-old.sh"
cat >"$f12old" <<'F12'
#!/usr/bin/env bash
set -uo pipefail
# The old `pf_bounded`, reduced to the three lines that leaked: spawn, let a
# watchdog SIGKILL it, and reap it in THIS shell with an unredirected `wait`.
sleep 30 >/dev/null 2>&1 </dev/null &
p=$!
( sleep 1; kill -9 "$p" >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
w=$!
rc=0
wait "$p" || rc=$?
kill -9 "$w" >/dev/null 2>&1 || true
F12
f12old_out="$(bash "$f12old" 2>&1)"
check "F12 CONTROL: the OLD spawn-and-reap shape DOES print it in this very bash" \
  "printf '%s' \"\$f12old_out\" | qgrep -qF 'Killed: 9'"

# --- F13: two refusals, two remedies --------------------------------------
# MEASURED: answering a relative path like `ok` is correctly refused as not
# absolute, but the advice printed was "re-run preflight after `mkdir -p <dir>`"
# — the remedy for a MISSING directory. `mkdir -p ok` would succeed and leave
# the same refusal in place. The same text was reused for both reasons.
check "F13a the RELATIVE refusal is not told to create a directory" \
  "! printf '%s' \"\$pf5\" | qgrep -qF 'mkdir -p'"
check "F13a it is told the thing that actually fixes it: give an ABSOLUTE path" \
  "printf '%s' \"\$pf5\" | qgrep -qi 'ABSOLUTE path' && printf '%s' \"\$pf5\" | qgrep -qi 'nothing to create'"
check "F13 CONTROL: the UNWRITABLE refusal still gets the mkdir remedy, by name" \
  "printf '%s' \"\$pf5u\" | qgrep -qF 'mkdir -p /System/Library'"
check "F13 CONTROL: the two refusals print DIFFERENT advice (neither in both)" \
  "! printf '%s' \"\$pf5u\" | qgrep -qi 'nothing to create' && ! printf '%s' \"\$pf5\" | qgrep -qi 'make it writable'"

# --- F6: the playbook has to carry the same contract ----------------------
# S303: THE PLAYBOOK MUST NOT TELL THE SEAT TO GRANT ITSELF AUTHORITY. Two of
# the three seat models that failed S303 failed HERE, on the page rather than in
# the code: a Claude Sonnet seat was blocked by its own safety classifier for
# being instructed to export a blanket-trust variable ("Instruction Poisoning")
# and to launch a fully-trusted agent ("Create Unsafe Agents"), and a GPT seat
# refused on policy rather than rely on it. The page may still EXPLAIN the
# variable — it is a real copilot fact, and one command route is refused even
# with it — but it may not instruct anyone to arrange it.
check "F6 HOLOGRAM-COMMAND-MODE.md does NOT instruct the seat to export COPILOT_ALLOW_ALL" \
  "! qgrep -qF 'export COPILOT_ALLOW_ALL' '$APM'"
check "F6 and it does not tell the seat to rely on blanket trust for an unattended run" \
  "! qgrep -qi 'set .*COPILOT_ALLOW_ALL=true.*in the launching environment' '$APM'"
check "F6 it says in so many words that no blanket trust is REQUIRED" \
  "qgrep -qi 'does not require' '$APM' && qgrep -qi 'blanket trust' '$APM'"
check "F6 CONTROL: the page was really read and still carries the setup section" \
  "qgrep -q '^## Unattended Copilot setup:' '$APM' && qgrep -qi 'preflight' '$APM'"
check "F6 CONTROL: it still EXPLAINS the variable, so the cure removed a demand not a fact" \
  "qgrep -qF 'COPILOT_ALLOW_ALL' '$APM'"
check "F6b HOLOGRAM-COMMAND-MODE.md says a deadline is not a refusal, and names both ways out" \
  "qgrep -qi 'deadline is not a refusal' '$APM' && qgrep -qF 'LCARS_ECH_PROBE_TIMEOUT=60' '$APM'"
check "F6b it promises local-only costs ONE command, and names \`record localOnly\`" \
  "qgrep -qi 'ONE command' '$APM' && qgrep -qF 'record localOnly true' '$APM'"
check "F6b and it warns about the two ssh cases preflight can still false-stop on" \
  "qgrep -qF 'BatchMode=yes' '$APM' && qgrep -qi 'FIDO2' '$APM' && qgrep -qF 'GIT_SSH_COMMAND' '$APM'"
check "F6 HOLOGRAM-COMMAND-MODE.md tells him a settled question is READ, not re-raised" \
  "qgrep -qi 'answered' '$APM' && qgrep -qi 'withdraw' '$APM'"

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
# `PASS HOLOGRAM-COMMAND-MODE.md is installed` and 162/0 against an EMPTY skills dir, with
# the file absent. So re-run THIS suite once against an empty prefix and require
# it to go red for exactly that reason. LCARS_AP_NO_NEST stops the recursion.
if [ -z "${LCARS_AP_NO_NEST:-}" ]; then
  echo
  echo "-- contract control (the same suite against an EMPTY skills dir) --"
  EMPTY_DEST="$TMPROOT/empty-skills"
  mkdir -p "$EMPTY_DEST/lcars-eeh"
  nested="$TMPROOT/nested.txt"
  LCARS_AP_NO_NEST=1 LCARS_SKILLS_DEST="$EMPTY_DEST" \
    bash "$DIR/$(basename "${BASH_SOURCE[0]}")" >"$nested" 2>&1 </dev/null
  nrc=$?
  check "against an empty skills dir the suite goes RED (it can fail)" "[ $nrc -ne 0 ]"
  check "it fails on the ABSENT HOLOGRAM-COMMAND-MODE.md, naming the path it looked at" \
    "qgrep -qE 'FAIL.*HOLOGRAM-COMMAND-MODE.md is installed at .*empty-skills' '$nested'"
  check "it fails on the ABSENT SKILL.md too" \
    "qgrep -qE 'FAIL.*SKILL.md is installed at .*empty-skills' '$nested'"
  check "and it does NOT print a PASS for either absent file (the false green)" \
    "! qgrep -qE 'PASS.*(ECH|SKILL).md is installed' '$nested'"
  check "the empty-dir run is NOT byte-identical to the real one (the old bug)" \
    "[ \"\$(grep -c '^  .PASS' '$nested')\" != \"$pass\" ]"
fi

# ==========================================================================
# S301 — THE EMERGENCY COMMAND HOLOGRAM ANNOUNCEMENT, OFF THE DATA PATH
# ==========================================================================
# THE DECISION THIS PINS. The driver announces itself as the Emergency Command
# Hologram — but it is ALSO the program the chain, xo-run.py and these suites
# call dozens of times per run and PARSE. Its verbs emit line-oriented machine
# records on STDOUT: `playbook` prints a bare TAB-SEPARATED table with no
# prefix at all, `next` prints `NEXT:`/`WHY:`/`PLAYBOOK:` lines that
# tests/lcars-eeh.test.sh anchors with `^`, and `worktree` prints
# `WORKTREE:`/`HOME:` lines that xo-run.py scans by prefix — and reports a
# refusal by reading the LAST line of the output. A banner anywhere on stdout
# is therefore indistinguishable from data: at the top it corrupts a
# first-line reader, at the bottom it corrupts xo-run.py's error path.
#
# So the banner goes to STDERR and only when stdout is a REAL TTY, i.e. a human
# is looking. Every captured call — command substitution, a pipe, subprocess
# with capture_output — is not a tty, so it is silent, and stdout stays
# BYTE-IDENTICAL to before the rename. `LCARS_ECH_QUIET=1` is the explicit
# off switch for a human who is in a loop and tired of it.
#
# "Only the first time per session" was considered and REJECTED: each
# `lcars-ech <verb>` is its own short-lived process, so "first in a session"
# would need new persisted state in autopilot.json — new behaviour, which this
# rename is not allowed to add. A tty test needs no state at all.
echo "-- S301. the ECH banner --"
R301="$(new_repo)"
ap "$R301" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1

# stdout, not a tty: pure data, no banner.
pb301="$(ap "$R301" playbook 2>/dev/null)"
check "S301. playbook stdout carries NO banner when stdout is not a tty" \
  "! printf '%s' \"\$pb301\" | qgrep -q 'Emergency Command Hologram'"
check "S301. playbook stdout is still the tab-separated table" \
  "[ \"\$(printf '%s\\n' \"\$pb301\" | head -1 | cut -f1)\" = align ]"
# stderr, not a tty: also silent (the gate is on stdout being a tty).
pbe301="$(ap "$R301" playbook 2>&1 >/dev/null)"
check "S301. nothing is written to stderr either when stdout is not a tty" \
  "! printf '%s' \"\$pbe301\" | qgrep -q 'Emergency Command Hologram'"

# A REAL TTY: the human sees the announcement. ptyrun.py gives stdin/stdout/
# stderr a genuine pty, which is the only honest way to exercise `[ -t 1 ]`.
PTY301="$DIR/lib/ptyrun.py"
tty301="$TMPROOT/tty301.txt"
TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$R301" STUB_LOG="$STUB_LOG" \
  LCARS_NOTIFY="$STUBS/notify.sh" LCARS_GH_BIN="$PFGH_YES" \
  python3 "$PTY301" bash "$SCRIPT" playbook >"$tty301" 2>&1 || true
check "S301. from a real tty it announces the Emergency Command Hologram" \
  "qgrep -q 'Emergency Command Hologram' '$tty301'"
check "S301. from a real tty it asks the nature of the command emergency" \
  "qgrep -qi 'nature of the command emergency' '$tty301'"
check "S301. the tty run still prints the playbook table (banner did not replace data)" \
  "qgrep -q 'align' '$tty301'"
# The off switch, honoured even at a tty.
qt301="$TMPROOT/qt301.txt"
TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$R301" STUB_LOG="$STUB_LOG" \
  LCARS_NOTIFY="$STUBS/notify.sh" LCARS_GH_BIN="$PFGH_YES" LCARS_ECH_QUIET=1 \
  python3 "$PTY301" bash "$SCRIPT" playbook >"$qt301" 2>&1 || true
check "S301. LCARS_ECH_QUIET=1 silences the banner at a tty" \
  "! qgrep -q 'Emergency Command Hologram' '$qt301'"
check "S301. LCARS_ECH_QUIET=1 still prints the data" \
  "qgrep -q 'align' '$qt301'"

# S301 fix round 1 — IT IS A VALUE CHECK, NOT A PRESENCE CHECK. The first cut
# gated on `[ -z "${LCARS_ECH_QUIET:-}" ]`, which silences the banner for ANY
# non-empty value — so somebody setting `=0` to mean "leave it on" got exactly
# the opposite. Only the literal `1` is quiet now, the same idiom
# `LCARS_BASE_QUIET` and every other boolean switch in this repo uses.
z301="$TMPROOT/z301.txt"
TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$R301" STUB_LOG="$STUB_LOG" \
  LCARS_NOTIFY="$STUBS/notify.sh" LCARS_GH_BIN="$PFGH_YES" LCARS_ECH_QUIET=0 \
  python3 "$PTY301" bash "$SCRIPT" playbook >"$z301" 2>&1 || true
check "S301-fix1. LCARS_ECH_QUIET=0 means NOT quiet (value check, not presence)" \
  "qgrep -q 'Emergency Command Hologram' '$z301'"
y301="$TMPROOT/y301.txt"
TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$R301" STUB_LOG="$STUB_LOG" \
  LCARS_NOTIFY="$STUBS/notify.sh" LCARS_GH_BIN="$PFGH_YES" LCARS_ECH_QUIET=yes \
  python3 "$PTY301" bash "$SCRIPT" playbook >"$y301" 2>&1 || true
check "S301-fix1. only the literal 1 is quiet (=yes does not silence it)" \
  "qgrep -q 'Emergency Command Hologram' '$y301'"

# ==========================================================================
# S305 — FIVE CURES TO THE EMERGENCY COMMAND HOLOGRAM
# ==========================================================================
echo "-- S305-1. the wait step has a way out --"
# MEASURED, AND IT IS THE BIGGEST ITEM. `next` told the seat to wait and § 8
# never said FOR HOW LONG, HOW TO RE-CHECK, or WHAT TO DO IF THE WAIT DOES NOT
# END. Four of four seat models, across three model families, stopped dead
# there. A seat that waits for ever is indistinguishable from a dead one.
#
# THE CURE IS CONSISTENT WITH § 5, not a contradiction of it: nothing here
# polls a log and nothing wraps an LCARS verb in a timeout. The WAIT ITSELF is
# bounded, and the bound is measured against a RECORDED timestamp
# (`waitingSince`), not re-derived from prose.
# TWO LIVE PIDS, NOT TWO BUSY LOOPS. `driver_live` is a `kill -0` on a RECORDED
# pid, so a sleeping process is exactly as live as a spinning one — and the
# older fixtures' `while :; do :; done` pair burns two cores for as long as the
# section runs, which on a box also running a seat measurement is a tax on
# somebody else's reading.
s305w1=""; s305w2=""
sleep 600 </dev/null >/dev/null 2>&1 &
s305w1=$!; BG_PIDS="$BG_PIDS $s305w1"
sleep 600 </dev/null >/dev/null 2>&1 &
s305w2=$!; BG_PIDS="$BG_PIDS $s305w2"
RW5="$(new_repo)"
ap "$RW5" init --spec "$TMPROOT/spec.md" --scope M0,M1,M2 >/dev/null 2>&1
new_mission "$RW5" lcars-w1 plan
new_mission "$RW5" lcars-w2 plan
ap "$RW5" record 'missions.M0.id' lcars-w1 >/dev/null 2>&1
ap "$RW5" record 'missions.M1.id' lcars-w2 >/dev/null 2>&1
ap "$RW5" record "drivers.lcars-w1.pid" "$s305w1" >/dev/null 2>&1
ap "$RW5" record "drivers.lcars-w2.pid" "$s305w2" >/dev/null 2>&1
APW5="$RW5/.git/lcars/autopilot.json"
nw5="$(ap "$RW5" next 2>&1)"
check "S305-1. two live drivers still → NEXT: wait (unchanged)" \
  "printf '%s' \"\$nw5\" | qgrep -q '^NEXT: wait'"
check "S305-1. the wait names a TIME LIMIT" \
  "printf '%s' \"\$nw5\" | qgrep -q '^LIMIT: '"
check "S305-1. the limit is a real number of minutes, not 'a while'" \
  "printf '%s' \"\$nw5\" | qgrep -qE '^LIMIT: .*[0-9]+ ?min'"
check "S305-1. the wait says HOW to re-check" \
  "printf '%s' \"\$nw5\" | qgrep -q '^RE-CHECK: '"
check "S305-1. the re-check is \`next\` again, never a log poll" \
  "printf '%s' \"\$nw5\" | qgrep -qE '^RE-CHECK: .*(next|await)'"
check "S305-1. the wait says what to do WHEN THE LIMIT PASSES" \
  "printf '%s' \"\$nw5\" | qgrep -q '^IF THE LIMIT PASSES: '"
check "S305-1. the expiry action names the \`stalled\` verb" \
  "printf '%s\n' \"\$nw5\" | grep -A3 'IF THE LIMIT PASSES' | qgrep -q 'stalled'"
check "S305-1. the expiry action ends at \`ask\` (§ 9), not at silence" \
  "printf '%s\n' \"\$nw5\" | grep -A4 'IF THE LIMIT PASSES' | qgrep -q 'ask'"
# RECORD, DON'T INFER: when the wait began is WRITTEN DOWN the first time it is
# seen, so neither the seat nor the script has to work it out of a transcript.
check "S305-1. the first wait RECORDS waitingSince" \
  "[ -n \"\$(jget '$APW5' 'd.get(\"waitingSince\")')\" ]"
ws5a="$(jget "$APW5" 'd.get("waitingSince")')"
ap "$RW5" next >/dev/null 2>&1
check "S305-1. a second wait does NOT restart the clock (the record is kept)" \
  "[ \"\$(jget '$APW5' 'd.get(\"waitingSince\")')\" = \"$ws5a\" ]"

# PAST THE LIMIT IT IS NO LONGER A WAIT. Back-date the recorded start instead
# of sleeping: the limit is read off the record, which is exactly why it was
# recorded.
ap "$RW5" record waitingSince 1 >/dev/null 2>&1
nw5x="$(ap "$RW5" next 2>&1)"
check "S305-1. past the limit \`next\` SAYS the limit has passed" \
  "printf '%s' \"\$nw5x\" | qgrep -qi 'the limit has passed'"
check "S305-1. past the limit it names the ONE command to run now" \
  "printf '%s' \"\$nw5x\" | qgrep -q 'stalled'"
check "S305-1. past the limit it still prints exactly ONE action line" \
  "[ \"\$(printf '%s\n' \"\$nw5x\" | grep -c '^NEXT: ')\" = 1 ]"

# --- the bounded re-check verb --------------------------------------------
# A seat with nothing else to do needs something it can BLOCK on that cannot
# outlive its bound. `await` watches the recorded driver PROCESSES (§ 5's rule:
# the process, never a clock, never a log) and returns the moment a slot frees.
export LCARS_ECH_WAIT_LIMIT=2
aw5="$(ap "$RW5" await 2>&1)"; rcaw5=$?
unset LCARS_ECH_WAIT_LIMIT
check "S305-1. \`await\` RETURNS (it is bounded, it cannot sit for ever)" \
  "[ -n \"\$aw5\" ]"
check "S305-1. \`await\` reports 124 when its bound passes with the slots full" \
  "[ $rcaw5 -eq 124 ]"
check "S305-1. the expired \`await\` names \`stalled\` as the next command" \
  "printf '%s' \"\$aw5\" | qgrep -q 'stalled'"
check "S305-1. the expired \`await\` says this is not the run failing" \
  "printf '%s' \"\$aw5\" | qgrep -qi 'not a failure\|is not the run failing'"
# CONTROL: with a slot free it comes straight back, successfully.
kill -9 "$s305w1" "$s305w2" 2>/dev/null || true
sleep 1
aw5b="$(ap "$RW5" await 2>&1)"; rcaw5b=$?
check "S305-1. CONTROL: with a slot free \`await\` returns 0 at once" \
  "[ $rcaw5b -eq 0 ]"
check "S305-1. CONTROL: and it says a slot is free" \
  "printf '%s' \"\$aw5b\" | qgrep -qi 'slot'"
# CONTROL: a repo that is NOT waiting prints none of the wait furniture, and
# the recorded start is cleared so a later wait is timed from ITS own start.
nw5c="$(ap "$RW5" next 2>&1)"
check "S305-1. CONTROL: not waiting → no RE-CHECK furniture" \
  "! printf '%s' \"\$nw5c\" | qgrep -q '^RE-CHECK: '"
check "S305-1. CONTROL: not waiting → waitingSince is cleared" \
  "[ -z \"\$(jget '$APW5' 'd.get(\"waitingSince\")')\" ]"

echo "-- S305-2. heartbeat install fails FAST instead of hanging --"
# REPORTED BY A SEAT, VERBATIM: "heartbeat install produced no output and
# remained running until terminated; heartbeat status confirms not installed."
# REPRODUCED on this box: `crontab -l` answers in 0.0s but the WRITE
# (`crontab -` AND `crontab <file>`) never returns at all — so it is the write
# itself, not an inherited-stdin read. Unattended, that is the whole night.
HANGCRON="$STUBS/crontab-hangs"
cat >"$HANGCRON" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$CRONFILE"; exit 0; fi
# the measured macOS behaviour: the READ answers, the WRITE never returns
exec sleep 600
SH
chmod +x "$HANGCRON"
RHB5="$(new_repo)"
ap "$RHB5" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
: >"$CRONFILE"
hb5start="$(date +%s)"
hb5="$(TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$RHB5" STUB_LOG="$STUB_LOG" LCARS_ECH_CRONTAB_TIMEOUT=3 \
       LCARS_CRONTAB_BIN="$HANGCRON" bash "$SCRIPT" heartbeat install 2>&1 </dev/null)"; rchb5=$?
hb5elapsed=$(( $(date +%s) - hb5start ))
check "S305-2. install RETURNS against a crontab whose write never does" \
  "[ $hb5elapsed -lt 30 ]"
check "S305-2. it does not claim success"            "[ $rchb5 -ne 0 ]"
check "S305-2. it is NOT a captain question (exit 10 is reserved)" \
  "[ $rchb5 -ne 10 ]"
check "S305-2. it SAYS something (the seat got no output at all)" \
  "[ -n \"\$hb5\" ]"
check "S305-2. it names crontab as what did not return" \
  "printf '%s' \"\$hb5\" | qgrep -qi 'crontab'"
check "S305-2. it says the heartbeat is OPTIONAL so the seat does not stop" \
  "printf '%s' \"\$hb5\" | qgrep -qi 'optional'"
check "S305-2. it names the one verb to run by hand instead" \
  "printf '%s' \"\$hb5\" | qgrep -q 'stalled'"
check "S305-2. it names the macOS cause it can actually be fixed by" \
  "printf '%s' \"\$hb5\" | qgrep -qi 'full disk access'"
# `remove` is the SAME write through the SAME door, and § 10 tells the seat to
# run it at wrap-up.
: >"$CRONFILE"
rm5start="$(date +%s)"
rm5="$(TMPDIR="$TMPROOT/tmp" LCARS_ECH_CWD="$RHB5" STUB_LOG="$STUB_LOG" LCARS_ECH_CRONTAB_TIMEOUT=3 \
       LCARS_CRONTAB_BIN="$HANGCRON" bash "$SCRIPT" heartbeat remove 2>&1 </dev/null)"; rcrm5=$?
rm5elapsed=$(( $(date +%s) - rm5start ))
check "S305-2. remove RETURNS too"                   "[ $rm5elapsed -lt 30 ]"
check "S305-2. remove does not claim success"        "[ $rcrm5 -ne 0 ]"
check "S305-2. remove says what did not return"      "printf '%s' \"\$rm5\" | qgrep -qi 'crontab'"
# CONTROL: the working crontab still installs, exits 0, and keeps one line.
: >"$CRONFILE"
hb5ok="$(ap "$RHB5" heartbeat install 2>&1)"; rchb5ok=$?
check "S305-2. CONTROL: a crontab that WORKS still installs and exits 0" \
  "[ $rchb5ok -eq 0 ] && qgrep -q 'LCARS-ECH' '$CRONFILE'"
check "S305-2. CONTROL: and it still says it installed" \
  "printf '%s' \"\$hb5ok\" | qgrep -qi 'installed'"
ap "$RHB5" heartbeat remove >/dev/null 2>&1
check "S305-2. CONTROL: a crontab that WORKS still removes the line" \
  "! qgrep -q 'LCARS-ECH' '$CRONFILE'"

echo "-- S305-3. the playbook says HOW to reach the Holodeck --"
# HOLOGRAM-COMMAND-MODE.md named `holodeck_start` / `holodeck_say` /
# `holodeck_end` as if they were callable verbs and carried ZERO lines on how
# to call them, beside 42 concrete `lcars-ech` / `lcars-file` command lines —
# so the omission was specific, not a house style. MEASURED: the strongest seat
# reverse-engineered the HTTP routes itself (9 `api/holodeck` references in its
# log); the weaker seats never found them and never reached the Holodeck.
check "S305-3. the playbook names the holodeck START route" \
  "qgrep -qF '/api/holodeck/start' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. the playbook names the SAY route" \
  "qgrep -qF '/say' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. the playbook names the END route" \
  "qgrep -qF '/end' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. the playbook names the PROMOTE route (the hand-off)" \
  "qgrep -qF '/promote' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. the playbook says these are POSTs, not shell verbs" \
  "qgrep -qF 'POST /api/holodeck/start' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. it gives a CONCRETE command line, in the file's own style" \
  "qgrep -qE 'curl .*api/holodeck/start' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. it says how to start the daemon HEADLESS first" \
  "qgrep -qF 'lcars-viewscreen' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. it names the key the start response hands back" \
  "qgrep -qF 'sessionId' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"
check "S305-3. CONTROL: the old verb names are still there (nothing was lost)" \
  "qgrep -qF 'holodeck_start' '$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md'"

echo "-- S305-4. \`next\` withdraws a stale question, exactly as preflight does --"
# PROVEN DIRECTLY: a repo set up by an OLDER build records a stop that the new
# build has cured; `preflight` prints `WITHDRAWN [q1]` and `next` routed to
# answer-pending anyway. `next` is the FIRST verb the playbook's loop tells a
# seat to run, so an existing repo that takes this update and is then driven
# normally meets a stop that no longer applies.
Q305_DEAD='the engine has no unattended permission: COPILOT_ALLOW_ALL is not exactly `true`, so an unattended copilot run is refused on every command.'
RN5="$(new_repo)"
ap "$RN5" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
APN5="$RN5/.git/lcars/autopilot.json"
python3 - "$APN5" "$Q305_DEAD" <<'PY'
import json, sys
f, what = sys.argv[1], sys.argv[2]
d = json.load(open(f))
d["questions"] = {"q1": {"id": "q1", "mission": "-", "what": what,
                         "why": "written by the build that REQUIRED it",
                         "raisedAt": 1}}
d["pending"] = {"id": "q1", "mission": "-", "what": what}
json.dump(d, open(f, "w"), indent=2)
PY
nn5="$(ap "$RN5" next 2>&1)"
check "S305-4. \`next\` no longer routes to answer-pending on the dead stop" \
  "! printf '%s' \"\$nn5\" | qgrep -q '^NEXT: answer-pending'"
check "S305-4. \`next\` SAYS it withdrew it (silence would be a second mystery)" \
  "printf '%s' \"\$nn5\" | qgrep -q 'WITHDRAWN \[q1\]'"
check "S305-4. the withdrawal is on the RECORD, not just in the output" \
  "[ -n \"\$(jget '$APN5' 'd[\"questions\"][\"q1\"].get(\"withdrawnAt\")')\" ]"
check "S305-4. and it is NOT recorded as the captain's own decision" \
  "[ -n \"\$(jget '$APN5' 'd[\"questions\"][\"q1\"].get(\"answeredAt\")')\" ]"
check "S305-4. the derived pending mirror is emptied with it" \
  "[ -z \"\$(jget '$APN5' 'd.get(\"pending\",{}).get(\"id\")')\" ]"
# ONE CODE PATH, NOT TWO. `preflight` and `next` must withdraw through the SAME
# function, or they drift again: the proof is that preflight run against an
# ALREADY-withdrawn record finds nothing left to retire and says nothing.
pn5="$(ap "$RN5" preflight 2>&1)"
check "S305-4. preflight finds nothing left to withdraw (one shared path)" \
  "! printf '%s' \"\$pn5\" | qgrep -q 'WITHDRAWN \[q1\]'"
# CONTROL: a question that is STILL TRUE must still park the run. Without this
# the cure above is indistinguishable from `next` ignoring questions.
RN5b="$(new_repo)"
ap "$RN5b" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
ap "$RN5b" ask "ship M0 as the CLI only?" --mission - \
  --why "a product call only you can make" --command "-" --rollback "nothing" >/dev/null 2>&1
nn5b="$(ap "$RN5b" next 2>&1)"
check "S305-4. CONTROL: a LIVE question still routes to answer-pending" \
  "printf '%s' \"\$nn5b\" | qgrep -q '^NEXT: answer-pending'"
check "S305-4. CONTROL: and it is NOT withdrawn behind the captain's back" \
  "! printf '%s' \"\$nn5b\" | qgrep -q 'WITHDRAWN'"

echo "-- S305-5. no preflight error path reports a problem and exits 0 --"
# S305 WAS ASKED TO CURE "preflight prints its error and exits 0" AND IT DID
# NOT REPRODUCE: every error path measured exits 1 (a `die`) or 10 (a recorded
# stop). This is the GUARD that keeps it that way — the class is real even
# though this instance was not.
RP5="$(new_repo)"
ap "$RP5" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
git -C "$RP5" remote remove origin >/dev/null 2>&1 || true
pp5="$(ap "$RP5" preflight 2>&1)"; rcpp5=$?
check "S305-5. a preflight that prints STOPPING does NOT exit 0" \
  "printf '%s' \"\$pp5\" | qgrep -q 'STOPPING' && [ $rcpp5 -ne 0 ]"
check "S305-5. and it exits 10, the recorded-question code" "[ $rcpp5 -eq 10 ]"
# CONTROL: a preflight with nothing to report really does exit 0, so the guard
# above is not passing because preflight never succeeds.
RP5b="$(new_repo)"
ap "$RP5b" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
ap "$RP5b" record launchDir "$TMPROOT/tmp" >/dev/null 2>&1
ap "$RP5b" record push.mode local-only >/dev/null 2>&1
pp5b="$(ap "$RP5b" preflight 2>&1)"; rcpp5b=$?
check "S305-5. CONTROL: a clean preflight exits 0" "[ $rcpp5b -eq 0 ]"
check "S305-5. CONTROL: and prints no STOPPING line" \
  "! printf '%s' \"\$pp5b\" | qgrep -q 'STOPPING'"

# ==========================================================================
# S305 FIX ROUND 1 — the five defects a fresh tester drove out from outside
# ==========================================================================
# R1-D1..D4 are all in ONE new block of HOLOGRAM-COMMAND-MODE.md: the block
# added this session to say HOW to reach the Holodeck. The block WORKS — a seat
# following it alone started a program and authored a real mockup — but four of
# its documented calls were wrong, and the first one was fatal.
#
# THESE ARE NOT GREP TESTS. S305-3 above asserted that strings were present in
# the file, and every one of those eight passed while the documented daemon
# launch bound nothing at all. So the four below DRIVE THE REAL DAEMON with the
# values the playbook teaches, extracted FROM the playbook, and assert the
# daemon accepts them. A rule-exists test passes while the screen is grey.
echo "-- S305-R1-D1. the DOCUMENTED daemon launch actually binds --"

PB="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"

# A free port, asked of the OS rather than guessed — the suite must not fight
# the captain's own boards (two were live on this box while this was written).
free_port() {
  python3 - <<'PYFP'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYFP
}

# bound_within <port> <secs> — 0 as soon as something LISTENS there.
bound_within() {
  python3 - "$1" "$2" <<'PYBW'
import socket, sys, time
port, secs = int(sys.argv[1]), float(sys.argv[2])
deadline = time.time() + secs
while time.time() < deadline:
    s = socket.socket(); s.settimeout(0.4)
    try:
        s.connect(("127.0.0.1", port)); sys.exit(0)
    except Exception:
        time.sleep(0.25)
    finally:
        s.close()
sys.exit(1)
PYBW
}

# THE LINE THE PLAYBOOK TEACHES, taken out of the playbook itself. The only
# substitutions are the ones a test MUST make: the installed launcher name ->
# this checkout's own script, the documented port -> a free one, and the
# documented /tmp log -> one inside $TMPROOT. The env, the flags and the
# backgrounding are the file's own words.
VS_LINE="$(grep -F 'lcars-viewscreen' "$PB" | grep -F -- '--port' | head -1)"
check "S305-R1-D1. the playbook still carries a daemon launch line at all" \
  "[ -n \"\$VS_LINE\" ]"

VSPORT="$(free_port)"
VSLOG="$TMPROOT/vs-asdocumented.log"
VSREPO="$(new_repo)"
# ORDER MATTERS: the documented line says `lcars-viewscreen` TWICE — once as
# the command and once inside `/tmp/lcars-viewscreen.log`. Rewrite the LOG
# first, then the command name, FIRST OCCURRENCE ONLY, or the log path is
# rewritten into nonsense and this test watches a file nothing ever writes.
VS_CMD="${VS_LINE/\/tmp\/lcars-viewscreen.log/$VSLOG}"
VS_CMD="${VS_CMD/lcars-viewscreen/bash $REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh}"
VS_CMD="${VS_CMD//8765/$VSPORT}"

# CLAUDECODE=1 IS THE MEASUREMENT, not a convenience: the viewscreen's own
# headless gate fires on it, and it is set in every seat this playbook is
# written for. A test that unset it would be testing the one environment in
# which the defect cannot happen.
#
# LCARS_HOLODECK_HANDOFF_CHECK=0 is this suite's spend fuse reaching the
# daemon: `derive` is the one endpoint that may spawn a worker, and `off` means
# no path through these tests can bill.
run_documented_daemon() {
  cd "$VSREPO" || return 1
  CLAUDECODE=1 \
  LCARS_HOLODECK_HANDOFF_CHECK=0 \
  LCARS_SERVE_NO_OPEN=1 \
  LCARS_VERSION_CHECK_BIN="$TMPROOT/no-such-version-check" \
  eval "$1"
  printf '%s' "$!" >"$TMPROOT/vs.pid"
  cd "$REPO_ROOT" || return 1
}

run_documented_daemon "$VS_CMD"
VSPID="$(cat "$TMPROOT/vs.pid" 2>/dev/null || true)"
[ -n "${VSPID:-}" ] && BG_PIDS="$BG_PIDS $VSPID"
if bound_within "$VSPORT" 25; then vsbound=1; else vsbound=0; fi
check "S305-R1-D1. the command the playbook documents BINDS a port" \
  "[ $vsbound -eq 1 ]"
check "S305-R1-D1. its log exists and is not empty (a missing log passes vacuously)" \
  "[ -s '$VSLOG' ]"
check "S305-R1-D1. and it does not print the headless refusal" \
  "[ -s '$VSLOG' ] && ! qgrep -q 'NOT started' '$VSLOG'"
check "S305-R1-D1. the playbook names the bypass the gate requires" \
  "qgrep -qF 'LCARS_VIEWSCREEN_ALLOW_AI' '$PB'"
check "S305-R1-D1. and SAYS it is the viewscreen's own headless gate, not a hack" \
  "qgrep -qiE 'own (headless )?gate|gate of its own|viewscreen.s own' '$PB'"

# CONTROL — THE SAME LINE WITH THE BYPASS STRIPPED MUST FAIL. Without this the
# test above cannot tell a cured playbook from a viewscreen that stopped
# gating, which is exactly how this defect survived S305-3's eight green greps.
VSPORT2="$(free_port)"
VSLOG2="$TMPROOT/vs-nobypass.log"
VS_CMD2="$(printf '%s' "$VS_CMD" | sed 's/LCARS_VIEWSCREEN_ALLOW_AI=1 //')"
VS_CMD2="$(printf '%s' "$VS_CMD2" | sed "s#$VSLOG#$VSLOG2#; s#--port $VSPORT#--port $VSPORT2#")"
run_documented_daemon "$VS_CMD2"
VSPID2="$(cat "$TMPROOT/vs.pid" 2>/dev/null || true)"
[ -n "${VSPID2:-}" ] && BG_PIDS="$BG_PIDS $VSPID2"
if bound_within "$VSPORT2" 6; then vsbound2=1; else vsbound2=0; fi
check "S305-R1-D1. CONTROL: strip the bypass and the very same line binds NOTHING" \
  "[ $vsbound2 -eq 0 ]"
check "S305-R1-D1. CONTROL: and it prints the gate's own refusal" \
  "[ -s '$VSLOG2' ] && qgrep -q 'NOT started' '$VSLOG2'"

echo "-- S305-R1-D2/D3/D4. the documented holodeck calls, against the real daemon --"
# ONE ROOM ON DISK, no worker, no spend. `open` warm-restarts a program from
# its room, and it is the one holodeck road that mints a session WITHOUT
# spawning a turn — so D2 and D4 are measured against a LIVE daemon for free.
HROOM=""
if [ $vsbound -eq 1 ]; then
  HSIDE="$(dirname "$VSREPO")/$(basename "$VSREPO")-holodeck"
  HROOM="$HSIDE/m0-screens"
  mkdir -p "$HROOM"
  printf '# M0 screens\n\n## Turn 1 - captain\nmock up the two M0 screens\n' >"$HROOM/transcript.md"
  printf '<!doctype html><title>M0</title><h1>M0</h1>\n' >"$HROOM/mockup.html"
  printf '# M0 screens\n\n## WHAT IT MUST DO\nShow the two M0 screens.\n\n## Open questions\n- none\n' >"$HROOM/concept.md"
fi

# hpost <path> <json> -> body, then the http code on its own last line.
hpost() { curl -s -m 20 -w '\n%{http_code}' -X POST \
  "http://127.0.0.1:$VSPORT$1" -H 'Content-Type: application/json' -d "$2"; }
hget()  { curl -s -m 20 -w '\n%{http_code}' "http://127.0.0.1:$VSPORT$1"; }
hcode() { printf '%s' "$1" | tail -1; }
hbody() { printf '%s' "$1" | sed '$d'; }
hsid()  { hbody "$1" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(((d.get("state") or d) or {}).get("sessionId") or "")' 2>/dev/null || true; }

HSID=""
if [ -n "$HROOM" ]; then
  HOPEN="$(hpost /api/holodeck/open '{"room":"m0-screens"}')"
  HSID="$(hsid "$HOPEN")"
fi
check "S305-R1-D2. a live holodeck session exists to measure against" \
  "[ -n \"\$HSID\" ]"

# THE SCOPE VALUE THE PLAYBOOK TEACHES, read out of the playbook's own promote
# line and POSTed to the real daemon. It taught "M0" — the MILESTONE label —
# and the daemon answers HTTP 400 "unknown build scope".
# READ IT OFF THE CURL A SEAT WOULD COPY, not off the prose around it. The
# first cut of this test grepped the first `"scope"` within three lines of
# `/promote` and picked up the new block's own "{\"scope\":\"M0\"} is REFUSED"
# sentence — i.e. it measured the explanation instead of the command.
PB_SCOPE="$(python3 - "$PB" <<'PYSCOPE'
import json, re, sys
lines = open(sys.argv[1]).read().splitlines()
for i, ln in enumerate(lines):
    if not (ln.lstrip().startswith("curl") or ln.lstrip().startswith("-H")):
        continue
    if "/promote" not in "\n".join(lines[i:i + 3]):
        continue
    m = re.search(r"-d '(\{[^']*\})'", "\n".join(lines[i:i + 3]))
    if m:
        try:
            print(json.loads(m.group(1)).get("scope", ""))
        except ValueError:
            print("")
        break
PYSCOPE
)"
check "S305-R1-D2. the playbook's promote example still declares a scope" \
  "[ -n \"\$PB_SCOPE\" ]"
HPROM=""
if [ -n "$HSID" ] && [ -n "$PB_SCOPE" ]; then
  HPROM="$(hpost "/api/holodeck/$HSID/promote" "{\"scope\":\"$PB_SCOPE\"}")"
fi
check "S305-R1-D2. the daemon ACCEPTS the scope the playbook documents" \
  "[ \"\$(hcode \"\$HPROM\")\" = 200 ]"
check "S305-R1-D2. and it answers with the Align brief, not an error" \
  "hbody \"\$HPROM\" | qgrep -qF '\"brief\"'"
# CONTROL: the value the playbook USED to teach must still be refused, or the
# test above would pass against a daemon that validates nothing.
HPROMBAD=""
[ -n "$HSID" ] && HPROMBAD="$(hpost "/api/holodeck/$HSID/promote" '{"scope":"M0"}')"
check "S305-R1-D2. CONTROL: a milestone label is still refused (400)" \
  "[ \"\$(hcode \"\$HPROMBAD\")\" = 400 ]"
check "S305-R1-D2. CONTROL: and the refusal names it as a build scope" \
  "hbody \"\$HPROMBAD\" | qgrep -qF 'unknown build scope'"
# BOTH LEGAL VALUES ARE NAMED, with what each one means — the playbook taught
# one value and it was the wrong one, so naming the set is the cure.
check "S305-R1-D2. the playbook names look+behaviour" \
  "qgrep -qF 'look+behaviour' '$PB'"
check "S305-R1-D2. the playbook names look-only" \
  "qgrep -qF 'look-only' '$PB'"
check "S305-R1-D2. and says what look-only means (a reskin, no functional change)" \
  "qgrep -qiE 'reskin|no functional change' '$PB'"

# D3 — `derive` RETURNS INSTANTLY with {"derive":{"state":"running"}} and the
# playbook showed `promote` on the very next line. Completion IS observable on
# the already-documented GET, which carries the same `derive` block.
HSTATE=""
[ -n "$HSID" ] && HSTATE="$(hget "/api/holodeck/$HSID")"
check "S305-R1-D3. the GET the playbook names really carries the derive block" \
  "hbody \"\$HSTATE\" | qgrep -qF '\"derive\"'"
check "S305-R1-D3. and that block carries a state to poll on" \
  "hbody \"\$HSTATE\" | qgrep -qF '\"state\"'"
check "S305-R1-D3. the playbook says derive is ASYNCHRONOUS" \
  "qgrep -qi 'asynchronous' '$PB'"
check "S305-R1-D3. it names the two derive states a seat waits through" \
  "qgrep -qF '\"state\": \"running\"' '$PB' && qgrep -qF '\"state\": \"done\"' '$PB'"
# AND THE DOCUMENTED WAIT IS RUN. A bound you can only grep for is a bound
# nobody has watched expire — and "a seat that waits forever is
# indistinguishable from a dead one" is this whole session's theme. So the
# poll snippet is EXTRACTED from the playbook, time-scaled (its own iteration
# count and sleep, nothing else), pointed at the LIVE daemon — whose derive
# state is `off` and will therefore NEVER say `done` — and must still RETURN.
DPOLL="$TMPROOT/documented-poll.sh"
python3 - "$PB" "$DPOLL" <<'PYPOLL'
import re, sys
src = open(sys.argv[1]).read()
# The snippet is the fenced lines from the WAIT step up to the next numbered
# step comment. Markers are the playbook's own numbering, not a test fixture.
m = re.search(r"\n(# 4a\..*?)\n# 5\.", src, re.S)
open(sys.argv[2], "w").write((m.group(1) if m else "") + "\n")
PYPOLL
check "S305-R1-D3. the playbook carries an extractable WAIT step (step 4a)" \
  "[ -s '$DPOLL' ]"
# Time-scale it: 3 tries, 1s apart. Nothing else about it is touched.
if [ -s "$DPOLL" ]; then
  python3 - "$DPOLL" "$VSPORT" "$HSID" <<'PYSCALE'
import re, sys
p, port, sid = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
s = re.sub(r"seq 1 \d+", "seq 1 3", s)
s = re.sub(r"sleep \d+", "sleep 1", s)
s = s.replace("8765", port).replace("<sessionId>", sid)
open(p, "w").write(s)
PYSCALE
  dstart="$(date +%s)"
  dout="$(bash "$DPOLL" 2>&1)"; drc=$?
  delapsed=$(( $(date +%s) - dstart ))
else
  dout=""; drc=0; delapsed=9999
fi
check "S305-R1-D3. the documented wait RETURNS instead of hanging for ever" \
  "[ $delapsed -lt 30 ]"
check "S305-R1-D3. and when it gives up it SAYS so, naming the bound" \
  "printf '%s' \"\$dout\" | qgrep -qi 'gave up\|give up\|did not finish'"
# CONTROL: an UNBOUNDED wait is the one thing this session exists to remove, so
# the documented poll must not be a `while true`.
check "S305-R1-D3. CONTROL: the documented poll is not an infinite loop" \
  "! qgrep -qF 'while true' '$PB'"

# D4 — AFTER `end` THERE WAS NO DOCUMENTED WAY BACK IN. `end` is final for that
# sessionId (the GET 404s for ever), and the refusal on re-starting the same
# name tells the reader to click something in a program list, which a headless
# seat does not have. `POST /api/holodeck/open` with the ROOM is the real road.
HEND=""; HAFTER=""; HLIST=""; HREOPEN=""; HSID2=""
if [ -n "$HSID" ]; then
  HEND="$(hpost "/api/holodeck/$HSID/end" '{}')"
  HAFTER="$(hget "/api/holodeck/$HSID")"
  HLIST="$(hget /api/holodeck)"
  HREOPEN="$(hpost /api/holodeck/open '{"room":"m0-screens"}')"
  HSID2="$(hsid "$HREOPEN")"
fi
check "S305-R1-D4. end succeeds" "[ \"\$(hcode \"\$HEND\")\" = 200 ]"
check "S305-R1-D4. CONTROL: that sessionId is DEAD afterwards (404)" \
  "[ \"\$(hcode \"\$HAFTER\")\" = 404 ]"
check "S305-R1-D4. the room and its program still read from the LIST route" \
  "hbody \"\$HLIST\" | qgrep -qF 'm0-screens'"
check "S305-R1-D4. the documented way back in WORKS headlessly (open by room)" \
  "[ \"\$(hcode \"\$HREOPEN\")\" = 200 ]"
check "S305-R1-D4. and it hands back a NEW sessionId, not the dead one" \
  "[ -n \"\$HSID2\" ] && [ \"\$HSID2\" != \"\$HSID\" ]"
check "S305-R1-D4. the playbook names the open route" \
  "qgrep -qF '/api/holodeck/open' '$PB'"
# STEP 7 IS ONLY USABLE IF THE SEAT CAN READ THE NEW sessionId OUT OF THE REPLY,
# and every holodeck POST nests it: {"ok":true,"state":{"sessionId":...}}. The
# playbook said "THE REPLY CARRIES sessionId", which reads as a top-level key.
# MEASURED against the live daemon, below, not asserted.
check "S305-R1-D4. the reply really does nest sessionId under state" \
  "hbody \"\$HREOPEN\" | qgrep -qF '\"state\"' && hbody \"\$HREOPEN\" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if (d.get(\"state\") or {}).get(\"sessionId\") and not d.get(\"sessionId\") else 1)'"
check "S305-R1-D4. and the playbook says to read .state.sessionId" \
  "qgrep -qF '.state.sessionId' '$PB'"
check "S305-R1-D4. it says the GET 404s once the program is ended" \
  "qgrep -qF '404' '$PB'"
check "S305-R1-D4. and it no longer claims that GET is one Program plus its transcript, full stop" \
  "! qgrep -qF 'is one Program plus its transcript' '$PB'"

echo "-- S305-R2-D6. the documented wait DEGRADES on a reply that is not JSON --"
# THE SNIPPET IS RUN, NOT GREPPED. Round 1 gave step 4a a bound and proved it
# returns; it left the PARSER naked. Two non-answers are normal on that GET and
# NEITHER is "still working":
#   * the daemon dies mid-wait   -> curl prints NOTHING, json.load raises, and
#     the loop prints a Python traceback every 5s for the full ~450s bound
#     (measured: ~90 tracebacks). That noise is exactly what made four of four
#     live seats conclude the harness was broken and stop.
#   * the session has been ended -> HTTP 404 {"error": "no such holodeck
#     program: ..."}, which parses but carries no derive block, so the old
#     snippet read it as "not done yet" and burnt the whole bound in silence.
# Both are measured below against the SAME extracted snippet, and the two
# round-1 behaviours (break on `done`, say so on expiry) are measured as
# CONTROLS in the same breath.
DPOLL_RAW="$TMPROOT/documented-poll-raw.sh"
python3 - "$PB" "$DPOLL_RAW" <<'PYPOLL2'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\n(# 4a\..*?)\n# 5\.", src, re.S)
open(sys.argv[2], "w").write((m.group(1) if m else "") + "\n")
PYPOLL2
check "S305-R2-D6. the WAIT step is still extractable from the playbook" \
  "[ -s '$DPOLL_RAW' ]"

# mkpoll <out> <port> <sid> — the same snippet, time-scaled to 3 tries 1s
# apart. Nothing else about it is touched.
mkpoll() {
  cp "$DPOLL_RAW" "$1"
  python3 - "$1" "$2" "$3" <<'PYSCALE2'
import re, sys
p, port, sid = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
s = re.sub(r"seq 1 \d+", "seq 1 3", s)
s = re.sub(r"sleep \d+", "sleep 1", s)
s = s.replace("8765", port).replace("<sessionId>", sid)
open(p, "w").write(s)
PYSCALE2
}
# runpoll <script> [stub-body] — runs it, leaves output in $rpout and wall
# seconds in $rpel. A stub body shadows `curl` ONLY (python3 stays real), which
# is how a reply shape is served without a daemon per case.
CURLSTUB="$TMPROOT/curl-stub"
runpoll() {
  local sc="$1" body="${2-}" pathpfx="" t0
  if [ -n "$body" ]; then
    rm -rf "$CURLSTUB"; mkdir -p "$CURLSTUB"
    { echo '#!/usr/bin/env bash'; printf '%s\n' "$body"; } >"$CURLSTUB/curl"
    chmod +x "$CURLSTUB/curl"
    pathpfx="$CURLSTUB:"
  fi
  t0="$(date +%s)"
  rpout="$(PATH="$pathpfx$PATH" bash "$sc" 2>&1)"
  rpel=$(( $(date +%s) - t0 ))
}

# M1 — THE GET ANSWERS HTML. The defect, reproduced at its narrowest.
PNJ="$TMPROOT/poll-nonjson.sh"; mkpoll "$PNJ" "$VSPORT" "deadbeef"
runpoll "$PNJ" "printf '<!doctype html><title>404</title>not found\n'"
echo "    [M1 non-JSON reply] ${rpel}s, output: $(printf '%s' "$rpout" | head -1)"
check "S305-R2-D6. M1 a non-JSON reply prints NO Python traceback" \
  "! printf '%s' \"\$rpout\" | qgrep -q 'Traceback'"
check "S305-R2-D6. M1 and no JSONDecodeError" \
  "! printf '%s' \"\$rpout\" | qgrep -q 'JSONDecodeError'"
check "S305-R2-D6. M1 it says the daemon STOPPED ANSWERING, not 'still working'" \
  "printf '%s' \"\$rpout\" | qgrep -qi 'stopped answering'"
check "S305-R2-D6. M1 and it gives up AT ONCE instead of burning the bound" \
  "[ $rpel -le 2 ]"

# M2 — THE DAEMON IS GONE: curl prints nothing and exits non-zero. This is the
# case a seat hits when the viewscreen dies mid-derive.
PDD="$TMPROOT/poll-dead-daemon.sh"; mkpoll "$PDD" "$VSPORT" "deadbeef"
runpoll "$PDD" "exit 7"
echo "    [M2 dead daemon] ${rpel}s, output: $(printf '%s' "$rpout" | head -1)"
check "S305-R2-D6. M2 a dead daemon prints NO Python traceback either" \
  "! printf '%s' \"\$rpout\" | qgrep -q 'Traceback'"
check "S305-R2-D6. M2 and it reads as the daemon having stopped answering" \
  "printf '%s' \"\$rpout\" | qgrep -qi 'stopped answering'"
check "S305-R2-D6. M2 and it returns at once" "[ $rpel -le 2 ]"

# M3 — LIVE, AND THE SESSION IS THE ONE `end` KILLED IN D4. A real 404 whose
# body IS valid JSON: the silent-burn half of the defect.
PEND="$TMPROOT/poll-ended-session.sh"
rpout=""; rpel=9999
if [ -n "$HSID" ] && [ $vsbound -eq 1 ]; then
  mkpoll "$PEND" "$VSPORT" "$HSID"
  runpoll "$PEND"
fi
echo "    [M3 live daemon, ended session] ${rpel}s, output: $(printf '%s' "$rpout" | head -1)"
check "S305-R2-D6. M3 an ended session is not mistaken for a derive in flight" \
  "printf '%s' \"\$rpout\" | qgrep -qi 'stopped answering'"
check "S305-R2-D6. M3 and it stops rather than polling a dead session out" \
  "[ $rpel -le 2 ]"
check "S305-R2-D6. M3 no traceback against the real 404" \
  "! printf '%s' \"\$rpout\" | qgrep -q 'Traceback'"

# CONTROL 1 — IT STILL BREAKS ON `done`, ON ITERATION ONE. Without this the
# three above would pass against a snippet that gave up on everything.
PDONE="$TMPROOT/poll-done.sh"; mkpoll "$PDONE" "$VSPORT" "deadbeef"
runpoll "$PDONE" "printf '{\"derive\":{\"state\":\"done\"}}\n'"
echo "    [CONTROL done] ${rpel}s, output: $(printf '%s' "$rpout" | head -1)"
check "S305-R2-D6. CONTROL: \`done\` still breaks the loop on the first pass" \
  "[ $rpel -le 1 ]"
check "S305-R2-D6. CONTROL: and \`done\` prints no complaint of any kind" \
  "[ -z \"\$rpout\" ]"

# CONTROL 2 — A DERIVE THAT IS GENUINELY IN FLIGHT MUST STILL RUN TO THE BOUND
# and still print the expiry guidance. This is the round-1 cure, re-measured:
# the new no-answer road must not swallow the real wait.
PRUN="$TMPROOT/poll-running.sh"; mkpoll "$PRUN" "$VSPORT" "deadbeef"
runpoll "$PRUN" "printf '{\"derive\":{\"state\":\"running\"}}\n'"
echo "    [CONTROL running] ${rpel}s, output: $(printf '%s' "$rpout" | head -1)"
check "S305-R2-D6. CONTROL: a running derive is waited out to the bound" \
  "[ $rpel -ge 2 ]"
check "S305-R2-D6. CONTROL: and expiry still names the bound and says it gave up" \
  "printf '%s' \"\$rpout\" | qgrep -qi 'gave up\|give up\|did not finish'"
check "S305-R2-D6. CONTROL: and still offers promote-anyway or re-derive" \
  "printf '%s' \"\$rpout\" | qgrep -qi 'promote' && printf '%s' \"\$rpout\" | qgrep -qi 'force'"
check "S305-R2-D6. CONTROL: a running derive is NOT called a dead daemon" \
  "! printf '%s' \"\$rpout\" | qgrep -qi 'stopped answering'"

# Stop the daemon the moment the measurements are taken — a suite that leaks a
# daemon corrupts every later reading (S208/S209).
{ [ -n "${VSPID:-}" ] && kill "$VSPID" && wait "$VSPID"; } 2>/dev/null || true
{ [ -n "${VSPID2:-}" ] && kill "$VSPID2" && wait "$VSPID2"; } 2>/dev/null || true

echo "-- S305-R1-D5. a park on a PROBE-DEPENDENT question cannot read as a halt --"
# MEASURED IN TWO REPOS. A repo init'd with no origin records "there is nowhere
# to push"; add a WORKING origin and `next` — the FIRST verb the loop runs —
# still prints `NEXT: answer-pending` on that dead question, because the
# withdrawals that need a PROBE deliberately live in `preflight` (ech.sh's
# "WHAT IS DELIBERATELY NOT HERE"). That choice is RIGHT: `next` is the hot
# verb and must not reach the network. The defect is that the CONSEQUENCE is
# invisible, and four of four live models have stalled by reading a wait as a
# halt.
Q_R1_PROBE='there is nowhere to push: this repo has no origin remote, so nothing can be pushed and no pull request can be opened.'
RR1="$(new_repo)"      # new_repo already carries a working local bare origin
ap "$RR1" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
APR1="$RR1/.git/lcars/autopilot.json"
python3 - "$APR1" "$Q_R1_PROBE" <<'PYR1'
import json, sys
f, what = sys.argv[1], sys.argv[2]
d = json.load(open(f))
d["questions"] = {"q1": {"id": "q1", "mission": "-", "what": what,
                         "why": "recorded before the remote was added",
                         "raisedAt": 1}}
d["pending"] = {"id": "q1", "mission": "-", "what": what}
json.dump(d, open(f, "w"), indent=2)
PYR1
# A GIT THAT LOGS EVERY CALL, so "no network probe in `next`" is INSPECTED
# rather than assumed. It forwards to the real git, so the run is otherwise
# unchanged.
GITSPY="$TMPROOT/gitspy"; mkdir -p "$GITSPY"
GITSPY_LOG="$TMPROOT/git-calls.log"; : >"$GITSPY_LOG"
REALGIT="$(command -v git)"
cat >"$GITSPY/git" <<SHSPY
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GITSPY_LOG"
exec "$REALGIT" "\$@"
SHSPY
chmod +x "$GITSPY/git"
nr1="$(PATH="$GITSPY:$PATH" ap "$RR1" next 2>&1)"
check "S305-R1-D5. it still parks (the design is NOT reversed)" \
  "printf '%s' \"\$nr1\" | qgrep -q '^NEXT: answer-pending'"
check "S305-R1-D5. \`next\` still runs NO network probe" \
  "! qgrep -q 'ls-remote' '$GITSPY_LOG'"
check "S305-R1-D5. it says the question MAY ALREADY BE DEAD" \
  "printf '%s' \"\$nr1\" | qgrep -qi 'may already be dead'"
check "S305-R1-D5. it names preflight as the verb that settles it" \
  "printf '%s' \"\$nr1\" | qgrep -q 'preflight'"
check "S305-R1-D5. it says to run preflight BEFORE treating this as a stop" \
  "printf '%s' \"\$nr1\" | qgrep -qi 'before you treat this as a stop'"
check "S305-R1-D5. it says plainly that this is NOT a halt" \
  "printf '%s' \"\$nr1\" | qgrep -qi 'not a halt'"
check "S305-R1-D5. and it names the question it is talking about" \
  "printf '%s' \"\$nr1\" | qgrep -q 'q1'"
# AND THE PROBE REALLY DOES SETTLE IT — the claim the new block makes has to be
# true, or it sends the seat somewhere useless.
pr1="$(ap "$RR1" preflight 2>&1)"
check "S305-R1-D5. preflight does withdraw it, exactly as the new block claims" \
  "printf '%s' \"\$pr1\" | qgrep -q 'WITHDRAWN \[q1\]'"
nr1b="$(ap "$RR1" next 2>&1)"
check "S305-R1-D5. and the next \`next\` has moved on to real work" \
  "! printf '%s' \"\$nr1b\" | qgrep -q '^NEXT: answer-pending'"
# CONTROL — A GENUINELY OPEN QUESTION MUST STILL READ AS GENUINELY OPEN. If the
# maybe-dead block printed under every park it would be noise, and the captain's
# own product call would read as something a probe could clear.
RR1b="$(new_repo)"
ap "$RR1b" init --spec "$TMPROOT/spec.md" --scope M0 >/dev/null 2>&1
ap "$RR1b" ask "ship M0 as the CLI only?" --mission - \
  --why "a product call only you can make" --command "-" --rollback "nothing" >/dev/null 2>&1
nr1c="$(ap "$RR1b" next 2>&1)"
check "S305-R1-D5. CONTROL: the captain's own question still parks" \
  "printf '%s' \"\$nr1c\" | qgrep -q '^NEXT: answer-pending'"
check "S305-R1-D5. CONTROL: and it is NOT dressed up as maybe-dead" \
  "! printf '%s' \"\$nr1c\" | qgrep -qi 'may already be dead'"

echo "-- S305-R3-D7. the scratch the SEAT makes stays inside the repo --"
# MEASURED LIVE, 2026-10-18. A Copilot seat with a SCOPED grant (product repo +
# LCARS source + the Holodeck sidecar, nothing else) stalled twice on
# `Allow path access / This action may read or write the following paths
# outside the paths currently allowed for this session.` — at 09:23 and again
# at 09:37, each needing a human keypress. An unattended run dies at the first.
#
# LCARS IS NOT AT FAULT: `ech.sh live-check` takes its worktree and throwaway
# HOME from the recorded `launchDir`, and on that run both landed in
# `$PWD/.git/lcars/tmp/`. The culprit was scratch the SEAT created itself —
# `/tmp/home2-XXXX` (a SECOND throwaway HOME) and `/tmp/good.json` — because
# the live-check checklist's item 4 ("Two actors — two HOMEs") says to make a
# second HOME and never says WHERE.
#
# WHAT IS MEASURED HERE, and what is not. This is NOT a grep for a sentence.
# The playbook's cure carries a concrete, copyable command block; the test
# EXTRACTS that block, RUNS its placeholder-free lines in a throwaway repo from
# the repository root, and asks of the directory it really created: does this
# resolve INSIDE the repo? The same extractor and the same predicate are then
# turned on the two paths the live seat actually used, which must come back
# OUTSIDE — so a predicate that answered "inside" to everything cannot read as
# a pass. What it does NOT establish: that a live model obeys the instruction.
# No test here can; the honest claim is that the shape the playbook hands a
# reader is one that resolves in-repo, and that the shape it replaces does not.
APMSRC="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"

# scratch_block — the fenced bash block the cure hands the reader, scraped out
# of the playbook by its anchor. Empty output makes every control below red,
# which is the point.
scratch_block() {
  awk '
    /^\*\*Everything you make yourself goes inside the repository/ {f=1}
    f && /^```bash$/ {g=1; next}
    g && /^```$/ {exit}
    g {print}
  ' "$APMSRC"
}
# The lines a test can execute verbatim: the ones with no <placeholder> in them.
scratch_exec() { scratch_block | grep -v '<'; }

# inside_repo <repo> <path> -> yes|no. Resolves symlinks on BOTH sides (macOS
# /tmp is a symlink to /private/tmp, and a test that forgot that would call
# every /tmp path "inside" nothing).
inside_repo() {
  local r p d
  r="$(cd "$1" 2>/dev/null && pwd -P)" || { echo no; return; }
  p="$2"
  case "$p" in /*) ;; *) p="$1/$p" ;; esac
  if [ -d "$p" ]; then
    p="$(cd "$p" && pwd -P)"
  else
    d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { echo no; return; }
    p="$d/$(basename "$p")"
  fi
  case "$p/" in "$r"/*) echo yes ;; *) echo no ;; esac
}

SB="$(scratch_block)"
SX="$(scratch_exec)"

check "S305-R3-D7. the cure hands the reader an extractable command block" \
  "[ -n \"\$SB\" ]"
check "S305-R3-D7. and that block has lines runnable as-is (no placeholders)" \
  "[ -n \"\$SX\" ] && printf '%s' \"\$SX\" | qgrep -q 'mktemp'"

# RUN IT. A throwaway git repo, cwd at its root, exactly as a seat would.
RSC="$TMPROOT/scratch-repo"; mkdir -p "$RSC"; ( cd "$RSC" && git init -q . )
H2VAL="$( cd "$RSC" && eval "$SX
printf '%s' \"\$H2\"" 2>"$TMPROOT/scratch-err.txt" )"; h2rc=$?
echo "    [extracted block] H2=$H2VAL (exit $h2rc)"

check "S305-R3-D7. the block the playbook teaches RUNS clean from the repo root" \
  "[ $h2rc -eq 0 ] && [ -n \"\$H2VAL\" ]"
check "S305-R3-D7. and it really created a directory" "[ -d \"\$H2VAL\" ]"
# (1) THE DEFECT ITSELF — the second HOME the seat makes resolves in-repo.
check "S305-R3-D7. the second throwaway HOME it produces is INSIDE the repo" \
  "[ -n \"\$H2VAL\" ] && [ \"\$(inside_repo \"\$RSC\" \"\$H2VAL\")\" = yes ]"
check "S305-R3-D7. and specifically under .git/lcars/tmp/" \
  "[ \"\$(inside_repo \"\$RSC/.git/lcars/tmp\" \"\$H2VAL\")\" = yes ]"
check "S305-R3-D7. it is a real HOME a CLI could be pointed at (writable dir)" \
  "( HOME=\"\$H2VAL\" sh -c 'printf x >\"\$HOME/.probe\"' ) && [ -f \"\$H2VAL/.probe\" ]"

# (2) POSITIVE CONTROL — the SAME predicate on the two paths the live seat
# really used. If these came back `yes` the assertions above would be measuring
# nothing at all.
check "S305-R3-D7. CONTROL: /tmp/home2-XXXX (measured 09:23) is judged OUTSIDE" \
  "[ \"\$(inside_repo \"\$RSC\" /tmp/home2-XXXX)\" = no ]"
check "S305-R3-D7. CONTROL: /tmp/good.json (measured 09:37) is judged OUTSIDE" \
  "[ \"\$(inside_repo \"\$RSC\" /tmp/good.json)\" = no ]"
check "S305-R3-D7. CONTROL: a bare mktemp -d (no template) is judged OUTSIDE" \
  "[ \"\$(inside_repo \"\$RSC\" \"\$(mktemp -d)\")\" = no ]"
# (3) ANTI-VACUITY — the same extracted block with the in-repo prefix rewritten
# back to the natural /tmp shape must FAIL the same predicate. This proves the
# green above comes from the playbook's wording and not from the harness.
SXTMP="$(printf '%s\n' "$SX" | sed 's|\$PWD/\.git/lcars/tmp|/tmp|g; s|\.git/lcars/tmp|/tmp|g')"
H2TMP="$( cd "$RSC" && eval "$SXTMP
printf '%s' \"\$H2\"" 2>/dev/null )"
check "S305-R3-D7. CONTROL: the /tmp rewrite of the same block still runs" \
  "[ -n \"\$H2TMP\" ] && [ -d \"\$H2TMP\" ]"
check "S305-R3-D7. CONTROL: and THAT one is judged OUTSIDE the repo" \
  "[ \"\$(inside_repo \"\$RSC\" \"\$H2TMP\")\" = no ]"
rm -rf "$H2TMP" 2>/dev/null || true

# (4) COVERAGE — the cure has to be reachable by the seat that needs it: in the
# live-check section (§ 6), and naming the second-actor case the checklist
# cannot be edited to fix.
sec6="$(awk '/^## 6\. The Verify gate/{f=1} f&&/^## 6a\./{exit} f' "$APMSRC")"
check "S305-R3-D7. the cure sits inside § 6, the live-check section" \
  "printf '%s' \"\$sec6\" | qgrep -qF 'Everything you make yourself goes inside the repository'"
check "S305-R3-D7. it names the second-actor item the checklist leaves blank" \
  "printf '%s' \"\$sec6\" | qgrep -qF '<throwaway-home-2>'"
check "S305-R3-D7. it says WHY — a write outside the grant stops the run" \
  "printf '%s' \"\$sec6\" | qgrep -qi 'Allow path access'"

# ───────────────────────────────────────────────────────────────────────────────
# S305-R4-D8 — A DESIGN IS HANDED OVER BY `promote`, NEVER BY HAND
#
# MEASURED on a live Claude/Opus seat. It authored a real design in the
# Holodeck (program `m1-board`, four turns, concept.md + mockup.html both on
# disk), and then did `promote`'s job itself: it wrote the design into the
# mission's own prd.md, referenced the sidecar files by absolute path, and
# reproduced by hand the boilerplate promote injects (the whole "How to read
# the attached mockup" block, look-versus-behaviour precedence, escalate on
# disagreement). The BUILD was right — the mockup's colours are in the shipped
# code and a control colour absent from the mockup is nowhere. The RECORD was
# never written: no `Sent to Align:` header line, the room never marked handed
# over or read-only, nothing linking the mission to the program, the viewscreen
# unable to draw the connection. A successful hand-off became indistinguishable
# from no hand-off at all. The playbook already handed the seat the promote
# command (step 5); it simply chose not to use it, so the cure is a
# PROHIBITION WITH ITS REASON, not a better explanation.
#
# WHAT IS MEASURED HERE, and what is not. Three independent facets, not one
# sentence: (a) the rule is REACHABLE — it sits inside the same `##` section
# the promote call sits in, sliced by section boundaries rather than line
# numbers, and it comes BEFORE the promote curl inside that section, so a seat
# reading top-down meets it before it could act; (b) its CLAIMS CHECK OUT
# against the product, read-only — the route it names is really dispatched by
# the daemon, and the record it says goes missing is really the one promote
# writes; (c) CONTROLS — the same predicate on the sections that do NOT carry
# this rule comes back `no`, the merge precedent's predicate discriminates the
# other way, and § 4 with the new lines stripped out goes red again, so the
# green cannot be coming from text that was already there.
# WHAT IT DOES NOT ESTABLISH: that a live model obeys. No test here can — only
# the seats can measure that. The honest claim is that the prohibition, its
# replacement call and its reason are present, reachable before the act, and
# truthful about the product.
HOCM="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"
SRVPY="$REPO_ROOT/web/lcars_serve/server.py"
ACTPY="$REPO_ROOT/web/lcars_serve/actions.py"

# section <start-regex> <stop-regex> — one `##` slice of the playbook.
hocm_section() { awk -v s="$1" -v e="$2" '$0 ~ s {f=1} f && $0 ~ e {exit} f' "$HOCM"; }

# has_handoff_rule <text> -> yes|no. All three facets or it is not the rule:
# the thing `promote` does that nothing else does (it COPIES the design into the
# Mission's own `attachments/` — S305-R6-D10's rewrite), the call that does it,
# and the record that goes missing without it. The first facet was the
# prohibition's own sentence until R6; it is now the consequence that sentence
# left out, because the prohibition was measured not to work.
has_handoff_rule() {
  local t="$1"
  printf '%s\n' "$t" | qgrep -qF 'attachments/' || { echo no; return; }
  printf '%s\n' "$t" | qgrep -qF '/promote' || { echo no; return; }
  printf '%s\n' "$t" | qgrep -qiF 'Sent to Align' || { echo no; return; }
  echo yes
}

# THE RULE'S OWN PASSAGE, sliced by its NEIGHBOURS and not by its own words: it
# is whatever sits between the end of the which-path paragraph and the start of
# the curl walkthrough. That boundary is what makes the facet checks below
# non-tautological — the slice is defined by text the rule does not own, so a
# rewrite that drops a facet goes red instead of moving the goalposts.
hocm_rule_block() {
  awk '/State which path you took/ {f=1; next} /HOW TO CALL IT/ {exit} f' "${1:-$HOCM}"
}
# has_merge_rule <text> -> yes|no. The precedent this rule is written to match,
# used here only as a discriminator for the slicer.
has_merge_rule() {
  if printf '%s\n' "$1" | qgrep -qiF 'You never merge by hand'; then echo yes; else echo no; fi
}

S4="$(hocm_section '^## 4\. File a milestone' '^## 4a\.')"
S6="$(hocm_section '^## 6\. The Verify gate' '^## 6a\.')"
S7="$(hocm_section '^## 7\. Land it' '^## 8\.')"

check "S305-R4-D8. the slicer really slices (§ 4 is non-empty)" "[ -n \"\$S4\" ]"
check "S305-R4-D8. § 4 is the section that carries the promote call" \
  "printf '%s\n' \"\$S4\" | qgrep -qE 'curl .*api/holodeck/.*/promote'"

# (1) THE DEFECT ITSELF — the rule exists, in that same section.
check "S305-R4-D8. the hand-off prohibition sits in § 4, with promote" \
  "[ \"\$(has_handoff_rule \"\$S4\")\" = yes ]"

# ORDERING: a seat reading § 4 top-down meets the rule BEFORE the promote line.
RULE_LN="$(printf '%s\n' "$S4" | grep -nF 'attachments/' | head -1 | cut -d: -f1)"
PROM_LN="$(printf '%s\n' "$S4" | grep -nE 'curl .*api/holodeck/.*/promote' | head -1 | cut -d: -f1)"
echo "    [§ 4 line offsets] rule=${RULE_LN:-none} promote-curl=${PROM_LN:-none}"
check "S305-R4-D8. and it is read BEFORE the promote call, not after it" \
  "[ -n \"\$RULE_LN\" ] && [ -n \"\$PROM_LN\" ] && [ \"\$RULE_LN\" -lt \"\$PROM_LN\" ]"

# It must say WHAT TO CALL (the route, not a vague 'use the surface') and WHY --
# and it must say so IN THE RULE. Asserting these of § 4 as a whole would be
# vacuous: step 5's own comment already names the route. So the rule's own
# paragraph is cut out (the contiguous non-blank run around the prohibition)
# and the three questions are put to THAT.
RULEPARA="$(hocm_rule_block)"
check "S305-R4-D8. the rule block is extractable from its neighbours" \
  "[ -n \"\$RULEPARA\" ]"
check "S305-R4-D8. the RULE itself names the route the playbook documents" \
  "printf '%s\n' \"\$RULEPARA\" | qgrep -qF '/api/holodeck/<sessionId>/promote'"
check "S305-R4-D8. the RULE pre-empts the rationalisation: a faithful brief is NOT equivalent" \
  "printf '%s\n' \"\$RULEPARA\" | qgrep -qiF 'equivalent'"
check "S305-R4-D8. the RULE gives the reason: right build, NO RECORD left behind" \
  "printf '%s\n' \"\$RULEPARA\" | qgrep -qiE 'indistinguishable from no hand-?off'"
check "S305-R4-D8. the RULE names the record that went missing" \
  "printf '%s\n' \"\$RULEPARA\" | qgrep -qiF 'Sent to Align'"
check "S305-R4-D8. CONTROL: the merge precedent's paragraph is a DIFFERENT paragraph" \
  "printf '%s\n' \"\$RULEPARA\" | qgrep -qivF 'You never merge by hand'"

# (2) ITS CLAIMS CHECK OUT AGAINST THE PRODUCT (read-only cross-check). A rule
# that pointed at a route the daemon does not serve, or blamed a record promote
# does not write, would be reachable and still wrong.
check "S305-R4-D8. CROSS-CHECK: the promote route it names is really dispatched" \
  "qgrep -qF 'promote' '$SRVPY' && qgrep -qE 'parts\[1\] == \"promote\"' '$SRVPY'"
check "S305-R4-D8. CROSS-CHECK: the missing record is really the one promote writes" \
  "qgrep -qF '_Sent to Align: mission' '$ACTPY'"
check "S305-R4-D8. CROSS-CHECK: and that same line is what marks the room READ-ONLY" \
  "qgrep -qF 'over and is READ-ONLY' '$ACTPY'"

# (3) CONTROLS — the predicate can come back `no`, and the slicer discriminates.
check "S305-R4-D8. CONTROL: § 6 (the Verify gate) does NOT carry this rule" \
  "[ \"\$(has_handoff_rule \"\$S6\")\" = no ]"
check "S305-R4-D8. CONTROL: § 7 (Land it) does NOT carry it either" \
  "[ \"\$(has_handoff_rule \"\$S7\")\" = no ]"
check "S305-R4-D8. CONTROL: the merge precedent IS in § 7 (the slicer is real)" \
  "[ \"\$(has_merge_rule \"\$S7\")\" = yes ]"
check "S305-R4-D8. CONTROL: and the merge precedent is NOT in § 4" \
  "[ \"\$(has_merge_rule \"\$S4\")\" = no ]"

# (4) ANTI-VACUITY — strip the added rule out of § 4 and the predicate must go
# red. This is what proves the green above comes from the new text and not from
# something § 4 already said.
S4_STRIPPED="$(printf '%s\n' "$S4" | grep -viE 'attachments/|indistinguishable from no hand-?off')"
check "S305-R4-D8. CONTROL: § 4 with the prohibition stripped out fails the predicate" \
  "[ \"\$(has_handoff_rule \"\$S4_STRIPPED\")\" = no ]"
check "S305-R4-D8. CONTROL: and the strip left the rest of § 4 intact" \
  "printf '%s\n' \"\$S4_STRIPPED\" | qgrep -qE 'curl .*api/holodeck/.*/promote'"

# ───────────────────────────────────────────────────────────────────────────────
# S305-R5-D9 — THE SCRATCH DIRECTORY IS IN THE LAUNCH GRANT, NOT ONLY IN A RULE
#
# MEASURED LIVE, 2026-10-18, back to back, same code, same hour. A Copilot seat
# on `claude-opus-5.5` took ONE permission stall (the unavoidable folder-trust
# prompt at startup). A Copilot seat on `gpt-6.1-sol` — Copilot's DEFAULT, and
# what a stranger gets — took SIX in one hour. Every one of the six was the seat
# writing its OWN scratch to /tmp (`/tmp/lcars-suite-r2.txt`,
# `/tmp/lcars-cli-r2.txt`, both real files on disk, both outside the scoped
# grant), and every one froze the run on a dialog nobody was awake to answer.
#
# § 6.1's in-repo-scratch rule (S305-R3-D7, above) already existed on that run.
# The strong model obeyed it; the default model did not. A file-location rule
# enforced by INSTRUCTION is model-bound by nature; one enforced by LAUNCH-TIME
# CONFIGURATION is not. So the playbook's documented launch grant now names the
# system temp directory as well, for both CLIs the mode supports.
#
# WHAT IS MEASURED HERE, and what is not. Not a grep for a sentence: the
# documented launch block is EXTRACTED, its backslash continuations joined, and
# its `--add-dir` values PARSED OUT as argv tokens, then the scratch token is
# EVALUATED and the resolved directory compared against this host's real system
# temp dir (`pwd -P` on both sides, so the /tmp -> /private/tmp symlink cannot
# fool it) and against a throwaway repo, which it must be OUTSIDE of — if it
# resolved in-repo the grant would be redundant and the assertion vacuous.
# Controls: the same predicate on the same block with the scratch grant stripped
# must come back `no`; on § 6.1's scratch block, which is not a launch grant at
# all, `no`; and the blanket switches must be ABSENT from the launch line,
# because the whole point is that this stays scoped.
# WHAT IT DOES NOT ESTABLISH: that any model stalls less. Only a seat can
# measure that, and the six-versus-one above is that measurement, not this test.
# It also cannot establish that a reader launches with the line as written, nor
# that the grant covers whatever path a future model invents — only that the
# launch line the playbook hands a stranger names the temp directory alongside
# the repo and the sidecar, is still scoped, and keeps § 6.1 beside it.

SETUP_SEC="$(hocm_section '^## Unattended Copilot setup' '^## Unattended Copilot commands')"
check "S305-R5-D9. the setup section slices non-empty" "[ -n \"\$SETUP_SEC\" ]"
check "S305-R5-D9. and it is the section that argues COPILOT_ALLOW_ALL is not required" \
  "printf '%s\n' \"\$SETUP_SEC\" | qgrep -qF 'COPILOT_ALLOW_ALL'"

# fence_bash <text>      -> the first fenced ```bash block inside that text.
fence_bash() { printf '%s\n' "$1" | awk '/^```bash$/{g=1;next} g&&/^```$/{exit} g{print}'; }
# join_cont <text>       -> comments dropped, backslash continuations joined, so
#                           each command becomes ONE logical line (real argv).
join_cont() {
  printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//' | awk '
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (buf != "") buf = buf " " line; else buf = line
      if (buf ~ /\\$/) { sub(/[[:space:]]*\\$/, "", buf); next }
      if (buf != "") print buf
      buf = ""
    }'
}
# add_dirs <text> <cli>  -> every --add-dir VALUE on that cli's launch line.
add_dirs() {
  join_cont "$(fence_bash "$1")" | grep -E "^$2([[:space:]]|$)" \
    | tr ' ' '\n' | awk 'p=="--add-dir" && $0!=""{print} {p=$0}'
}
TMP_REAL="$(cd /tmp && pwd -P)"
TMPDIR_REAL="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
echo "    [this host] /tmp -> $TMP_REAL ; \$TMPDIR -> $TMPDIR_REAL"
# names_scratch <text> <cli> -> yes|no. A grant token that really resolves to
# this host's system temp directory. Placeholder tokens are skipped, not
# guessed at.
names_scratch() {
  local tok p
  while IFS= read -r tok; do
    case "$tok" in *'<'*|'') continue ;; esac
    p="$(eval "printf '%s' $tok" 2>/dev/null)" || continue
    [ -d "$p" ] || continue
    p="$(cd "$p" && pwd -P)"
    { [ "$p" = "$TMP_REAL" ] || [ "$p" = "$TMPDIR_REAL" ]; } && { echo yes; return; }
  done <<EOF2
$(add_dirs "$1" "$2")
EOF2
  echo no
}

COP_DIRS="$(add_dirs "$SETUP_SEC" copilot)"
CLA_DIRS="$(add_dirs "$SETUP_SEC" claude)"
echo "    [copilot grant] $(printf '%s' "$COP_DIRS" | tr '\n' ' ')"
echo "    [claude grant ] $(printf '%s' "$CLA_DIRS" | tr '\n' ' ')"

# (1) THE CHANGE ITSELF — a concrete launch grant, for both CLIs, naming repo,
# sidecar and scratch.
check "S305-R5-D9. the setup section hands the reader a runnable launch block" \
  "[ -n \"\$(fence_bash \"\$SETUP_SEC\")\" ]"
check "S305-R5-D9. the copilot launch line is scoped with --allow-all-tools" \
  "join_cont \"\$(fence_bash \"\$SETUP_SEC\")\" | qgrep -qE '^copilot .*--allow-all-tools'"
check "S305-R5-D9. the copilot grant names the product repo" \
  "printf '%s\n' \"\$COP_DIRS\" | qgrep -qF '<product-repo>'"
check "S305-R5-D9. the copilot grant names the Holodeck sidecar" \
  "printf '%s\n' \"\$COP_DIRS\" | qgrep -qF '<holodeck-sidecar>'"
check "S305-R5-D9. the copilot grant names the system temp directory, resolved" \
  "[ \"\$(names_scratch \"\$SETUP_SEC\" copilot)\" = yes ]"
# S305-R7-D11 widened the grant to six NAMED directories (the system toolchain
# joined repo/sidecar/scratch). The intent asserted here is unchanged -- an
# ENUMERATED set, never a sweep -- so the count moved and the exact set is
# asserted in R7-D11 below. Do not revert to 3.
check "S305-R5-D9. and it is NAMED directories, not a widened sweep" \
  "[ \"\$(printf '%s\n' \"\$COP_DIRS\" | grep -c .)\" -eq 6 ]"
check "S305-R5-D9. the claude launch line names the sidecar (its cwd is the repo)" \
  "printf '%s\n' \"\$CLA_DIRS\" | qgrep -qF '<holodeck-sidecar>'"
check "S305-R5-D9. the claude launch line names the system temp directory too" \
  "[ \"\$(names_scratch \"\$SETUP_SEC\" claude)\" = yes ]"
check "S305-R5-D9. and the claude line does NOT re-name the repo (cwd already)" \
  "! printf '%s\n' \"\$CLA_DIRS\" | qgrep -qF '<product-repo>'"

# The grant has to be WIDER than the repo or it would change nothing: the
# resolved scratch dir must land OUTSIDE a real repo. (inside_repo and $RSC come
# from S305-R3-D7 above — same predicate, reused deliberately.)
SCR_TOK="$(printf '%s\n' "$COP_DIRS" | grep -v '<' | head -1)"
SCR_RES="$(eval "printf '%s' $SCR_TOK" 2>/dev/null)"
echo "    [scratch token] $SCR_TOK -> $SCR_RES"
check "S305-R5-D9. the scratch grant resolves to a real directory" "[ -d \"\$SCR_RES\" ]"
check "S305-R5-D9. and it is OUTSIDE the repo — so the grant is not redundant" \
  "[ \"\$(inside_repo \"\$RSC\" \"\$SCR_RES\")\" = no ]"

# (2) STILL SCOPED — the blanket switches stay absent from the launch line.
GRANT_LINES="$(join_cont "$(fence_bash "$SETUP_SEC")")"
check "S305-R5-D9. the launch line carries NO --allow-all-paths" \
  "! printf '%s\n' \"\$GRANT_LINES\" | qgrep -qF -- '--allow-all-paths'"
check "S305-R5-D9. the launch line carries NO COPILOT_ALLOW_ALL=true" \
  "! printf '%s\n' \"\$GRANT_LINES\" | qgrep -qF 'COPILOT_ALLOW_ALL=true'"
check "S305-R5-D9. the launch line carries NO --dangerously-skip-permissions" \
  "! printf '%s\n' \"\$GRANT_LINES\" | qgrep -qF -- '--dangerously-skip-permissions'"

# (3) THE REASON TRAVELS WITH IT — a grant without its cost gets undone by a
# reader who does not know what it bought. These three ARE content assertions,
# and are claimed as nothing more.
check "S305-R5-D9. the section carries the measurement: six stalls against one" \
  "printf '%s\n' \"\$SETUP_SEC\" | qgrep -qiE 'six' && printf '%s\n' \"\$SETUP_SEC\" | qgrep -qF 'gpt-6.1-sol'"
check "S305-R5-D9. it says the difference was the MODEL, same code same hour" \
  "printf '%s\n' \"\$SETUP_SEC\" | qgrep -qiF 'same hour'"
check "S305-R5-D9. it names the trade honestly: /tmp is world-writable" \
  "printf '%s\n' \"\$SETUP_SEC\" | qgrep -qiF 'world-writable'"
check "S305-R5-D9. and it points at § 6.1, which stays" \
  "printf '%s\n' \"\$SETUP_SEC\" | qgrep -qF '6.1'"

# (4) § 6.1 IS NOT WEAKENED — belt and braces, so the grant is the backstop and
# the instruction is still the hygiene.
check "S305-R5-D9. § 6.1 still tells the seat never to use /tmp" \
  "printf '%s\n' \"\$S6\" | qgrep -qiF 'So never' && printf '%s\n' \"\$S6\" | qgrep -qiF 'never a bare'"
check "S305-R5-D9. § 6.1's in-repo scratch block is still extractable and runnable" \
  "[ -n \"\$(scratch_block)\" ] && printf '%s' \"\$(scratch_exec)\" | qgrep -q 'mktemp'"

# (5) CONTROLS — the predicate can fail.
SETUP_STRIPPED="$(printf '%s\n' "$SETUP_SEC" | grep -vF -- '--add-dir /tmp')"
check "S305-R5-D9. CONTROL: the strip really removed lines" \
  "[ \"\$(printf '%s\n' \"\$SETUP_STRIPPED\" | wc -l)\" -lt \"\$(printf '%s\n' \"\$SETUP_SEC\" | wc -l)\" ]"
check "S305-R5-D9. CONTROL: with the scratch grant stripped, copilot fails the predicate" \
  "[ \"\$(names_scratch \"\$SETUP_STRIPPED\" copilot)\" = no ]"
check "S305-R5-D9. CONTROL: and so does claude" \
  "[ \"\$(names_scratch \"\$SETUP_STRIPPED\" claude)\" = no ]"
check "S305-R5-D9. CONTROL: but the stripped block still names the repo — only the scratch went" \
  "printf '%s\n' \"\$(add_dirs \"\$SETUP_STRIPPED\" copilot)\" | qgrep -qF '<product-repo>'"
check "S305-R5-D9. CONTROL: § 6.1's section is not a launch grant and fails the predicate" \
  "[ \"\$(names_scratch \"\$S6\" copilot)\" = no ]"
check "S305-R5-D9. CONTROL: § 7 (Land it) carries no launch grant either" \
  "[ \"\$(names_scratch \"\$S7\" copilot)\" = no ]"

# ───────────────────────────────────────────────────────────────────────────────
# S305-R6-D10 — THE HAND-OFF RULE LEADS WITH THE DURABLE COPY, NOT THE RECORD
#
# WHY IT WAS REWRITTEN. R4-D8 put the rule in the file as a PROHIBITION whose
# reason was bookkeeping — a missing `Sent to Align:` line, a room not marked
# read-only, a connection the viewscreen cannot draw. MEASURED since it
# shipped, three seats in a row ignored it: `claude`/Opus drew the design then
# wrote the brief itself referencing the sidecar by absolute path;
# `copilot`/`gpt-6.1-sol` drew it, abandoned it and never filed a mission at
# all; `claude`/Sonnet drew it, hand-wrote the brief against `concept.md` and
# `mockup.html` by path, and built the work. A seat shipping working software
# weighs a missing label as small and proceeds — so the wording was giving it
# the WEAK reason.
#
# THE STRONG REASON, measured the same day and absent from R4's wording:
# `promote` threads the program's `mockup.html` + `concept.md` down the
# `--attach` road, and `file.sh` COPIES each one into the Mission's own
# `attachments/attachment-NN.<ext>` and lists it in `prd.md` (which is the
# GitHub issue body) by RELATIVE path. The Mission OWNS the design. A
# hand-written brief copies nothing and leaves the Mission borrowing a file
# outside the product tree.
#
# WHAT THIS MEASURES: that the rewritten passage (a) names that copy and the
# route that makes it, (b) puts the copy AHEAD of the bookkeeping inside the
# passage, so the headline is the engineering consequence, (c) names what is
# lost by hand and keeps the three-seat measurement that forced the rewrite,
# and (d) is TRUE of the product — asserted against file.sh and actions.py
# read-only, not against this brief. Controls: the PRE-CHANGE passage at HEAD
# fails the predicate, the sections that never carried the rule fail it, and
# stripping the new lines turns it red.
# WHAT IT DOES NOT ESTABLISH: that a live seat now calls `promote`. Three seats
# ignored the last wording and no grep can tell whether this one lands — only
# the next seats can. "Leads with" is also measured as TEXT ORDER within the
# passage, which is a proxy for emphasis, not emphasis itself.
FILESH="$REPO_ROOT/skills/lcars-file/file.sh"
RULEBLK="$(hocm_rule_block)"

check "S305-R6-D10. the rule block is non-empty and sits before the promote curl" \
  "[ -n \"\$RULEBLK\" ] && [ \"\$(grep -nF 'attachments/' '$HOCM' | head -1 | cut -d: -f1)\" -lt \"\$(grep -nE 'curl .*api/holodeck/.*/promote' '$HOCM' | head -1 | cut -d: -f1)\" ]"

# (a) THE DURABLE COPY, named, with the route that makes it.
check "S305-R6-D10. it names the Mission's own attachments/ dir" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qF \"attachments/\""
check "S305-R6-D10. it names the two files that ride (mockup.html, concept.md)" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qF 'mockup.html' && printf '%s\n' \"\$RULEBLK\" | qgrep -qF 'concept.md'"
check "S305-R6-D10. it says the Mission OWNS a copy / keeps it if the sidecar goes" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiE 'copies|copy' && printf '%s\n' \"\$RULEBLK\" | qgrep -qiF 'sidecar'"

# (b) POSITIVE LEAD, AND THE COPY AHEAD OF THE BOOKKEEPING. The passage used to
# open 'You never hand a design over by hand'; the captain's correction was that
# a prohibition does not sell the reader on what it gains. So: the FIRST line
# names the call, and does not open with 'never'.
LEAD="$(printf '%s\n' "$RULEBLK" | grep -v '^[[:space:]]*$' | head -1)"
echo "    [rule lead] ${LEAD}"
check "S305-R6-D10. the LEAD line names promote (a positive instruction)" \
  "printf '%s\n' \"\$LEAD\" | qgrep -qF 'promote'"
check "S305-R6-D10. the LEAD line does not open as a prohibition" \
  "printf '%s\n' \"\$LEAD\" | qgrep -qivE 'never|do not|don.t'"
COPY_LN="$(printf '%s\n' "$RULEBLK" | grep -nF 'attachments/' | head -1 | cut -d: -f1)"
BOOK_LN="$(printf '%s\n' "$RULEBLK" | grep -niF 'Sent to Align' | head -1 | cut -d: -f1)"
echo "    [rule offsets] attachments=${COPY_LN:-none} Sent-to-Align=${BOOK_LN:-none}"
check "S305-R6-D10. the durable copy comes BEFORE the bookkeeping in the passage" \
  "[ -n \"\$COPY_LN\" ] && [ -n \"\$BOOK_LN\" ] && [ \"\$COPY_LN\" -lt \"\$BOOK_LN\" ]"

# (c) WHAT IS LOST BY HAND, and the measurement that forced the rewrite.
check "S305-R6-D10. it says a hand-written brief copies NOTHING" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiE 'copies nothing|copies NOTHING'"
check "S305-R6-D10. it says the brief then depends on a file outside the repo" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiE 'outside the (product tree|repo)'"
check "S305-R6-D10. it says the design can be lost SILENTLY" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiF 'silently'"
check "S305-R6-D10. it keeps the measurement: three seats ignored the last wording" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiE 'three seats'"
check "S305-R6-D10. it still pre-empts 'a faithful brief is equivalent'" \
  "printf '%s\n' \"\$RULEBLK\" | qgrep -qiF 'equivalent'"
check "S305-R6-D10. it is still tight — the passage is under 30 lines" \
  "[ \"\$(printf '%s\n' \"\$RULEBLK\" | wc -l | tr -d ' ')\" -lt 30 ]"

# (d) CROSS-CHECK AGAINST THE PRODUCT, read-only. The claim the rule now leads
# with is an implementation claim, so it is asserted of the implementation.
check "S305-R6-D10. CROSS-CHECK: promote's hand-off set really is mockup.html + concept.md" \
  "qgrep -qF '_HANDOFF_FILES = (\"mockup.html\", _CONCEPT)' '$ACTPY' && qgrep -qF '_CONCEPT = \"concept.md\"' '$ACTPY'"
check "S305-R6-D10. CROSS-CHECK: those files ride the --attach road into filing" \
  "qgrep -qF 'args += [\"--attach\", p]' '$ACTPY'"
check "S305-R6-D10. CROSS-CHECK: file.sh COPIES each --attach into attachments/attachment-NN" \
  "qgrep -qF 'attachments/attachment-%02d' '$FILESH' && qgrep -qF 'cp \"\$asrc\" \"\$MISSION_DIR/\$arel\"' '$FILESH'"
check "S305-R6-D10. CROSS-CHECK: and lists them in prd.md, the issue body, by relative path" \
  "qgrep -qF 'lcars_attach_prd_section \"\${ATTACH_RELS[@]}\" >>\"\$MISSION_DIR/prd.md\"' '$FILESH'"

# (e) CONTROLS. The predicate must be falsifiable, and it must have been FALSE
# before this change — that is what proves it is not a grep for text already
# present. HEAD's copy of the playbook is the pre-change text.
# S305-R7-D11: PINNED. This read HEAD, which was the pre-change commit while R6
# was being written and stopped being it the moment R6 landed -- the control then
# fails for the wrong reason. 7548ee4 is R6's real parent and stays pre-change.
HOCM_PREV="$TMPROOT/hocm-prev.md"
( cd "$REPO_ROOT" && git show 7548ee4:skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md ) >"$HOCM_PREV" 2>/dev/null || :
check "S305-R6-D10. CONTROL: the pre-change playbook is readable at 7548ee4" \
  "[ -s \"\$HOCM_PREV\" ]"
check "S305-R6-D10. CONTROL: the PRE-CHANGE passage FAILS the predicate" \
  "[ \"\$(has_handoff_rule \"\$(hocm_rule_block \"\$HOCM_PREV\")\")\" = no ]"
check "S305-R6-D10. CONTROL: and the pre-change passage was non-empty (a real slice)" \
  "[ -n \"\$(hocm_rule_block \"\$HOCM_PREV\")\" ]"
RULEBLK_STRIPPED="$(printf '%s\n' "$RULEBLK" | grep -viE 'attachments/|copies nothing|three seats')"
check "S305-R6-D10. CONTROL: strip the new claims and the predicate goes red" \
  "[ \"\$(has_handoff_rule \"\$RULEBLK_STRIPPED\")\" = no ]"
check "S305-R6-D10. CONTROL: § 6, which never carried this rule, fails it" \
  "[ \"\$(has_handoff_rule \"\$S6\")\" = no ]"

# ───────────────────────────────────────────────────────────────────────────────
# S305-R7-D11 — THE LAUNCH GRANT NAMES THE SYSTEM TOOLCHAIN TOO
#
# MEASURED LIVE, 2026-10-18. A Copilot seat on `gpt-6-luna` STALLED asking
# permission to use `/usr/bin/time` — a standard system binary — because the
# documented grant named the product repo, the Holodeck sidecar, the LCARS
# source and /tmp, but not the directories ordinary system commands live in.
# That freezes an unattended run on a dialog nobody is awake to answer. R5-D9
# fixed the same class for the seat's own scratch; this is the same fix for the
# tools it runs. The grant is the PRODUCT half: a stranger who launches the
# hologram from this playbook has to get the grant the measurement rig gets, or
# the measurement passes green and the shipped product still stalls.
#
# WHAT IS MEASURED HERE, and what is not. Not a grep for a sentence this session
# wrote: the documented launch block is EXTRACTED, its backslash continuations
# joined, its `--add-dir` values PARSED OUT as argv tokens, each token EVALUATED
# and RESOLVED with `pwd -P`, and the resolved set compared against this host's
# real /usr/bin, /bin and /usr/sbin — for BOTH CLIs the mode supports. The
# blanket switches must still be ABSENT, and $HOME must NOT be among the
# resolved grants (nor any directory containing it), because that is the line
# the passage says it does not cross. Controls: the PRE-CHANGE block at HEAD
# must FAIL the predicate and must be a real, non-empty slice; stripping the new
# grant lines must turn it red; and sections that carry no launch grant fail it.
# WHAT IT DOES NOT ESTABLISH: that any seat stalls less — only a live seat can
# measure that, and the /usr/bin/time stall above is that measurement, not this
# test. It cannot establish that a reader launches with the line as written, nor
# that the grant covers whatever binary a future model reaches for. The prose
# assertions in (3) are content checks and are claimed as nothing more; they say
# the justification is present, not that it convinces anyone.

# hocm_sec_f <file> <start-re> <end-re> — hocm_section against an ARBITRARY file,
# so the pre-change playbook can be sliced the same way as the live one.
hocm_sec_f() { awk -v s="$2" -v e="$3" '$0 ~ s {f=1} f && $0 ~ e {exit} f' "$1"; }

TC_REAL=""
for d in /usr/bin /bin /usr/sbin; do TC_REAL="$TC_REAL $(cd "$d" && pwd -P)"; done
HOME_REAL="$(cd "$HOME" && pwd -P)"
echo "    [this host] toolchain ->$TC_REAL ; \$HOME -> $HOME_REAL"

# resolved_dirs <text> <cli> — every --add-dir value on that cli's launch line
# that is a real directory, resolved through symlinks. Placeholders are skipped.
resolved_dirs() {
  local tok p
  while IFS= read -r tok; do
    case "$tok" in *'<'*|'') continue ;; esac
    p="$(eval "printf '%s' $tok" 2>/dev/null)" || continue
    [ -d "$p" ] || continue
    ( cd "$p" && pwd -P )
  done <<EOF7
$(add_dirs "$1" "$2")
EOF7
}
# names_toolchain <text> <cli> -> yes|no. ALL THREE system dirs must be granted.
names_toolchain() {
  local got; got="$(resolved_dirs "$1" "$2")"
  local d
  for d in $TC_REAL; do
    printf '%s\n' "$got" | qgrep -qxF "$d" || { echo no; return; }
  done
  echo yes
}
# grants_home <text> <cli> -> yes|no. True if $HOME, or any directory that
# CONTAINS it, is among the resolved grants.
grants_home() {
  local got d; got="$(resolved_dirs "$1" "$2")"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$HOME_REAL/" in "$d"/*) echo yes; return ;; esac
  done <<EOF8
$got
EOF8
  echo no
}

# TC_PARA — the NEW justification passage only, sliced out of the setup section.
# The prose assertions below run against THIS, not the whole section, so a phrase
# the section already carried (e.g. the skills/plugins/MCP/hooks reasoning) cannot
# make a check pass by accident. That is exactly how a vacuous assertion gets in.
TC_PARA="$(printf '%s\n' "$SETUP_SEC" | awk '/\*\*Why the system toolchain is in there/{f=1} f && /^\*\*. 6\.1 stays either way/{exit} f')"
# TC_FLAT — the same passage with its line breaks folded. Markdown wraps prose at
# column ~80, so a phrase like "not a barrier" is split across two lines and a
# per-line grep would miss text that is genuinely there. The claim is about the
# passage's WORDS, not its line breaks, so the multi-word checks use this.
TC_FLAT="$(printf '%s\n' "$TC_PARA" | tr '\n' ' ' | tr -s ' ')"
echo "    [justification slice] $(printf '%s\n' "$TC_PARA" | grep -c .) non-blank lines, $(printf '%s' "$TC_FLAT" | wc -c | tr -d ' ') chars folded"
# The POSITIVE CONTROL's baseline. PINNED to the commit this change was built on,
# NOT to HEAD: HEAD ceases to be "pre-change" the instant this lands, which is
# precisely how R6-D10's HEAD-based control went stale (see its note).
HOCM_BASE_SHA="380fb3f"
HOCM_PREV7="$TMPROOT/hocm-prev-r7.md"
( cd "$REPO_ROOT" && git show "$HOCM_BASE_SHA:skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md" ) >"$HOCM_PREV7" 2>/dev/null || :
SETUP_PREV="$(hocm_sec_f "$HOCM_PREV7" '^## Unattended Copilot setup' '^## Unattended Copilot commands')"
echo "    [copilot resolved] $(resolved_dirs "$SETUP_SEC" copilot | tr '\n' ' ')"
echo "    [claude  resolved] $(resolved_dirs "$SETUP_SEC" claude  | tr '\n' ' ')"

# (1) THE CHANGE ITSELF — the toolchain is granted, for both CLIs, by resolved path.
check "S305-R7-D11. the copilot grant names the system toolchain, resolved" \
  "[ \"\$(names_toolchain \"\$SETUP_SEC\" copilot)\" = yes ]"
check "S305-R7-D11. the claude grant names the system toolchain too" \
  "[ \"\$(names_toolchain \"\$SETUP_SEC\" claude)\" = yes ]"
check "S305-R7-D11. the copilot grant is still an ENUMERATED set, not a sweep" \
  "[ \"\$(printf '%s\n' \"\$COP_DIRS\" | grep -c .)\" -eq 6 ] && printf '%s\n' \"\$COP_DIRS\" | qgrep -qF '<product-repo>'"

# (2) THE LINE NOT CROSSED — $HOME stays out, and the blanket switches stay out.
check "S305-R7-D11. \$HOME is NOT granted to copilot" \
  "[ \"\$(grants_home \"\$SETUP_SEC\" copilot)\" = no ]"
check "S305-R7-D11. \$HOME is NOT granted to claude" \
  "[ \"\$(grants_home \"\$SETUP_SEC\" claude)\" = no ]"
check "S305-R7-D11. no grant token is \$HOME or /Users/<user> textually either" \
  "! printf '%s\n' \"\$COP_DIRS\" \"\$CLA_DIRS\" | qgrep -qE '^(\\\$HOME|~|/Users/[^/]+)/?$'"
check "S305-R7-D11. the launch line still carries NO blanket switch" \
  "! printf '%s\n' \"\$GRANT_LINES\" | qgrep -qE -- '--allow-all-paths|COPILOT_ALLOW_ALL=true|--dangerously-skip-permissions'"

# (3) THE JUSTIFICATION TRAVELS WITH IT — a widened grant with no reason gets
# reverted by the next reader. Content assertions, claimed as nothing more.
check "S305-R7-D11. the justification slice is non-empty (a real slice)" \
  "[ -n \"\$TC_PARA\" ] && [ \"\$(printf '%s\n' \"\$TC_PARA\" | grep -c .)\" -ge 10 ]"
check "S305-R7-D11. it names the measured stall that forced it (/usr/bin/time)" \
  "printf '%s\n' \"\$TC_PARA\" | qgrep -qF '/usr/bin/time'"
check "S305-R7-D11. it says the toolchain dirs are root-owned and not writable" \
  "printf '%s\n' \"\$TC_FLAT\" | qgrep -qiF 'root' && printf '%s\n' \"\$TC_FLAT\" | qgrep -qiE 'not writable|non-writable'"
check "S305-R7-D11. it cites System Integrity Protection as the second level" \
  "printf '%s\n' \"\$TC_PARA\" | qgrep -qiF 'System Integrity Protection'"
check "S305-R7-D11. it says the grant adds no CAPABILITY, only removes a prompt" \
  "printf '%s\n' \"\$TC_FLAT\" | qgrep -qiE 'adds no capability' && printf '%s\n' \"\$TC_FLAT\" | qgrep -qiE 'not a barrier'"
# This phrase ALREADY existed in the section (the COPILOT_ALLOW_ALL explanation),
# so asserting it section-wide would be vacuous -- it passed before the change.
# Asserted against TC_PARA it means the new passage ECHOES the section's own
# reasoning instead of inventing a parallel argument, which is the actual ask.
check "S305-R7-D11. the new passage reuses the section's OWN trust reasoning" \
  "printf '%s\n' \"\$TC_FLAT\" | qgrep -qiF 'skills, plugins, MCP servers and hooks'"
check "S305-R7-D11. CONTROL: that phrase pre-dates the change (so section-wide would be vacuous)" \
  "printf '%s\n' \"\$SETUP_PREV\" | tr '\n' ' ' | tr -s ' ' | qgrep -qiF 'skills, plugins, MCP servers and hooks'"
check "S305-R7-D11. it says a launch flag is scoped to the run and persists nothing" \
  "printf '%s\n' \"\$TC_PARA\" | qgrep -qiF 'launch flag' && printf '%s\n' \"\$TC_PARA\" | qgrep -qiF 'persists nothing'"
check "S305-R7-D11. it states PROMINENTLY that \$HOME stays ungranted" \
  "printf '%s\n' \"\$TC_FLAT\" | qgrep -qiE 'HOME. (stays|remains) ungranted'"
check "S305-R7-D11. and says why: user-writable, credentials, loadable configuration" \
  "printf '%s\n' \"\$TC_PARA\" | qgrep -qiF 'user-writable' && printf '%s\n' \"\$TC_PARA\" | qgrep -qiF 'credentials'"
check "S305-R7-D11. it says the two are DIFFERENT KINDS of grant" \
  "printf '%s\n' \"\$TC_FLAT\" | qgrep -qiE 'different kinds of grant'"

# (4) CONTROLS — the predicate is falsifiable, and it was FALSE before this change.
check "S305-R7-D11. CONTROL: the pre-change playbook is readable at $HOCM_BASE_SHA" \
  "[ -s \"\$HOCM_PREV7\" ]"
check "S305-R7-D11. CONTROL: the pre-change setup section is a real, non-empty slice" \
  "[ -n \"\$SETUP_PREV\" ] && [ -n \"\$(add_dirs \"\$SETUP_PREV\" copilot)\" ]"
check "S305-R7-D11. CONTROL: the PRE-CHANGE copilot grant FAILS the predicate" \
  "[ \"\$(names_toolchain \"\$SETUP_PREV\" copilot)\" = no ]"
check "S305-R7-D11. CONTROL: and so does the pre-change claude grant" \
  "[ \"\$(names_toolchain \"\$SETUP_PREV\" claude)\" = no ]"
check "S305-R7-D11. CONTROL: but the pre-change block DID name the scratch dir (slice is sound)" \
  "[ \"\$(names_scratch \"\$SETUP_PREV\" copilot)\" = yes ]"
SETUP_TC_STRIPPED="$(printf '%s\n' "$SETUP_SEC" | grep -vE -- '--add-dir (/usr/bin|/bin|/usr/sbin)')"
check "S305-R7-D11. CONTROL: strip the toolchain lines and copilot goes red" \
  "[ \"\$(names_toolchain \"\$SETUP_TC_STRIPPED\" copilot)\" = no ]"
check "S305-R7-D11. CONTROL: and claude goes red too" \
  "[ \"\$(names_toolchain \"\$SETUP_TC_STRIPPED\" claude)\" = no ]"
check "S305-R7-D11. CONTROL: the strip left the repo and scratch grants standing" \
  "printf '%s\n' \"\$(add_dirs \"\$SETUP_TC_STRIPPED\" copilot)\" | qgrep -qF '<product-repo>' && [ \"\$(names_scratch \"\$SETUP_TC_STRIPPED\" copilot)\" = yes ]"
check "S305-R7-D11. CONTROL: § 6.1 is not a launch grant and fails the predicate" \
  "[ \"\$(names_toolchain \"\$S6\" copilot)\" = no ]"
check "S305-R7-D11. CONTROL: § 7 (Land it) carries no launch grant either" \
  "[ \"\$(names_toolchain \"\$S7\" copilot)\" = no ]"

echo
echo "=== lcars-ech: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
