#!/usr/bin/env bash
#
# THE STOP VERB, RESTRUCTURED: QUIESCE FIRST, CENSUS BY PROVENANCE, THEN BELIEVE
# ONLY AN EMPTY CENSUS — TWICE (S245).
#
# `tests/xo-stop-real-tree.test.sh` proved a stop can CROSS A PROCESS GROUP.
# It did not prove — and could not, by its shape — the three things that kept the
# stop verb lying through TWO failed fix rounds and five patches:
#
#   1. THE RACE. The only pre-spawn stop check in LCARS is the mission's `paused`
#      flag, read by the stage driver BETWEEN stages (run.sh:20746).
#      `resolve-logs.sh` spawns `run.sh drive` per bug (:1198-1205) and reads NO
#      flag at all. So the sweep kills what exists while the resolver keeps
#      minting fresh drivers behind it. Measured live: `lcars xo off` exited 0,
#      and 25 s later a survivor had advanced a bug two stages and hired a fresh
#      billable worker.
#
#   2. THE DEAD LEADER. Once the recorded group leader is gone, a walk rooted at
#      the recorded pid finds NOTHING — and reports that as success. It reported
#      AFTER_COUNT=0 with two billable processes alive. `kill -0 -<pgid>` proved
#      the orphaned group was still reachable the whole time. A before/after walk
#      from a dead root does not fail; it passes VACUOUSLY, which is worse.
#
#   3. THE SENTENCE. `xo.sh:1266-1270` printed "stood down — you have the conn"
#      on `XO_STOOD_DOWN > 0` alone, a counter `stand_down` increments whenever
#      no stop FAILED. It never asked whether anything was still alive.
#
# SO THIS SUITE DRIVES THE SHAPE THAT CAUGHT ALL THREE:
#
#     marker → no new spawns ; census by provenance ; sweep ;
#     two empty censuses ≥2 s apart → the conn ; otherwise survivors named
#     and every handle kept.
#
# THE RIG IS THE REAL TREE, and its argv is the real argv — `run.sh drive
# --mission <id>`, `run.sh validate --mission <id>`, `worker-adapter.sh spawn
# copilot --mission <id>` — because the census reads provenance out of argv and a
# rig with convenient argv would be a rig that proves nothing. Three levels, two
# groups, one orphan at ppid 1, and the billing leaf is a PATH shim over BOTH
# engine names, so nothing here can spend.
#
# EVERY ASSERTION HAS A CONTROL THAT MAKES IT FAIL. Nine probes passed vacuously
# in one night on this project (`'' = ''`; a grep that matched a page title; a
# descendant walk from a dead root), so the walk-from-a-dead-root is driven HERE,
# deliberately, as the control for the census: it must report nothing while the
# census names a live billable process.
#
# Usage: bash tests/xo-stop-quiesce.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"
TREE_PY="$REPO_ROOT/skills/lcars-xo/xo-tree.py"
RESOLVE="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
PAUSE="$REPO_ROOT/skills/lcars-pause/pause.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
KILLME=""
cleanup() {
  for p in $KILLME; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

nap() { perl -e 'select(undef,undef,undef,'"$1"')' 2>/dev/null || sleep 1; }

# EVERY PID COMPARISON IS GUARDED ON NON-EMPTY, in front, deliberately: `[ '' =
# '' ]` is true and `! kill -0 ''` is true, which is how a stop test
# congratulates itself for killing nothing.
nonempty() { for v in "$@"; do [ -n "$v" ] || return 1; done; return 0; }
pgid_of()  { ps -o pgid= -p "$1" 2>/dev/null | tr -dc '0-9'; }
alive()    { nonempty "${1:-}" && kill -0 "$1" 2>/dev/null; }
field()    { awk -v l="$2" -v c="$3" '$1 == l { print $(c + 1); exit }' "$1"; }
snap() {
  local p list=""
  for p in "$@"; do [ -n "$p" ] && list="$list -p $p"; done
  [ -n "$list" ] || { echo "    (no pids to show)"; return 0; }
  # shellcheck disable=SC2086
  ps -o pid=,ppid=,pgid=,comm= $list 2>/dev/null | sed 's/^/    /'
}

MID="lcars-20261004-001"
BUG1="lcars-20261004-002"
BUG2="lcars-20261004-003"
BUG3="lcars-20261004-004"

# ── ZERO SPEND, PINNED BY A PATH SHIM FAKING BOTH CLIs ─────────────────────
# Never an env var alone: the engine resolves from a request body, from
# $LCARS_WORKER_BIN and from a persisted state.json workerBin, and an env var has
# been MEASURED losing to the persisted one. The shim is also the rig's billing
# leaf — the process that, unshimmed, is the one that charges the captain.
SHIMBIN="$TMPROOT/shimbin"; mkdir -p "$SHIMBIN"
SHIM_LOG="$TMPROOT/shim.log"; : >"$SHIM_LOG"
for n in claude copilot; do
  cat >"$SHIMBIN/$n" <<SHIM
#!/usr/bin/env bash
m=no
for a in "\$@"; do case "\$a" in --model|--model=*) m=yes ;; esac; done
printf '%s\t%s\n' "$n" "\$m" >>"$SHIM_LOG"
printf 'ASSISTANT %s %s %s\n' "\$\$" "\$(ps -o pgid= -p \$\$ | tr -dc 0-9)" "\$PPID" \
  >>"\$CHAINLOG"
sleep 300
SHIM
  chmod +x "$SHIMBIN/$n"
done
export PATH="$SHIMBIN:$PATH"

# ── THE RIG. REAL NAMES, REAL ARGV, REAL GROUPING ──────────────────────────
# The scripts are called `run.sh` and `worker-adapter.sh` and carry
# `--mission <id>`, because that is what `ps` shows for the real chain and the
# census reads provenance out of exactly that. The adapter makes ITSELF a session
# leader with the same `perl POSIX::setsid + exec` call run.sh uses at :10000,
# :20068 and :20221 (BUG-048's cure), so it sits in a group the driver does not
# lead and no group kill can reach it.
RIG="$TMPROOT/rig"; mkdir -p "$RIG"
cat >"$RIG/worker-adapter.sh" <<'A'
#!/usr/bin/env bash
printf 'ADAPTER %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
copilot -p 'resolve the logged bug' --model some-model
A
cat >"$RIG/late" <<'L'
#!/usr/bin/env bash
# THE RACE, MADE DETERMINISTIC. A process that is INVISIBLE to the census (its
# argv names neither the mission nor any LCARS executable — it is just a timer)
# and that mints a FRESH billable worker one second INTO the stop window. It
# waits for the product's own stop marker so the spawn is guaranteed to land
# inside the window instead of racing the clock; the worker it then spawns is
# visible, self-led and at ppid 1, so the only thing that can catch it is a
# RE-CENSUS after the sweep. A walk rooted at the recorded driver cannot.
i=0
while [ "$i" -lt 600 ] && [ ! -f "$STOPMARK" ]; do i=$((i + 1)); sleep 0.1; done
sleep 1
printf 'LATE-SPAWNING\n' >>"$CHAINLOG"
exec perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' \
  bash "$RIGDIR/worker-adapter.sh" spawn copilot --mission "$MISSION"
L
cat >"$RIG/run.sh" <<'R'
#!/usr/bin/env bash
# One script, three roles, dispatched on argv[1] exactly as run.sh is.
role="${1:-}"
case "$role" in
  drive)
    printf 'DRIVER %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
    # ITS OWN TEARDOWN — and one that ABANDONS ITS WORKER, which is what the
    # live driver did. A stop that leans on the driver tidying up after itself
    # must still produce a dead tree when the driver does not.
    trap 'printf "TEARDOWN %s\n" "$$" >>"$CHAINLOG"; exit 0' TERM
    # The stage is spawned through a wrapper that EXITS, so the stage reparents
    # to ppid 1 — the shape `ps` actually found live (31634 ppid 1 pgid 30311).
    # After this, the stage is NOT reachable by walking ppid down from here.
    bash -c 'bash "$RIGDIR/run.sh" validate --mission "$MISSION" & disown'
    if [ -n "${LATE:-}" ]; then
      perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' \
        bash "$RIGDIR/late" &
      disown 2>/dev/null || true
    fi
    sleep 300 &
    wait
    ;;
  validate)
    printf 'STAGE %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
    perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' \
      bash "$RIGDIR/worker-adapter.sh" spawn copilot --mission "$MISSION" &
    wait
    ;;
  look)
    # The FIRST OFFICER'S OWN chain — what `xo.pid` is written about.
    printf 'LOOK %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
    perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' \
      bash "$RIGDIR/worker-adapter.sh" spawn copilot --mission "$MISSION" &
    wait
    ;;
esac
R
chmod +x "$RIG/run.sh" "$RIG/worker-adapter.sh" "$RIG/late"
export RIGDIR="$RIG" MISSION="$MID"

# A repo fixture with a parent at Verify, Number One engaged, and three linked
# bug children — the resolve-logs shape.
new_repo() { # [n-children]
  local repo n="${1:-3}" i seq d
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/$MID/xo"
  cat >"$repo/.git/lcars/config.json" <<EOF
{
  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "projectName": "repo",
  "contextFile": null,
  "testCommand": "true",
  "numberOne": {"enabled": true, "engine": "claude"},
  "created": "2026-10-04T00:00:00Z"
}
EOF
  cat >"$repo/.git/lcars/missions/$MID/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "A build to look at",
  "stage": "verify",
  "created": "2026-10-04T00:00:00Z",
  "githubIssue": 7,
  "branch": "lcars/$MID",
  "base": "main",
  "numberOne": {"status": "engaged", "note": "looking"},
  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e"
}
EOF
  local entries=""
  for i in $(seq 1 "$n" 2>/dev/null); do
    [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || continue
    seq="$(printf '%03d' "$((i + 1))")"
    d="$repo/.git/lcars/missions/lcars-20261004-$seq"
    mkdir -p "$d"
    cat >"$d/state.json" <<EOF
{
  "id": "lcars-20261004-$seq",
  "type": "bug",
  "title": "Logged bug number $i",
  "stage": "plan",
  "githubIssue": $((50 + i)),
  "parentMission": "$MID",
  "parentIssue": 7,
  "branch": "lcars/lcars-20261004-$seq",
  "base": "main"
}
EOF
    entries="$entries${entries:+, }{\"n\": $i, \"mission\": \"lcars-20261004-$seq\", \"title\": \"bug $i\"}"
  done
  printf '{"filed": [%s]}\n' "$entries" \
    >"$repo/.git/lcars/missions/$MID/xo/logs.json"
  echo "$repo"
}

# Bring the three-level rig up under a given pidfile, through the PRODUCT's own
# detach seam, and wait until the billing leaf is actually on the table.
bring_up() { # <chainlog> <pidfile> [LATE]
  CHAINLOG="$1"; : >"$CHAINLOG"; export CHAINLOG
  LATE="${3:-}" bash "$XO" detach --pidfile "$2" --log "$TMPROOT/detach.log" \
    -- bash "$RIG/run.sh" drive --mission "$MID"
  local i=0
  while [ "$i" -lt 200 ] && ! grep -q ASSISTANT "$CHAINLOG" 2>/dev/null; do
    i=$((i + 1)); nap 0.1
  done
  grep -q ASSISTANT "$CHAINLOG" 2>/dev/null
}

cat >"$TMPROOT/nokill" <<'NK'
#!/usr/bin/env bash
exit 0
NK
chmod +x "$TMPROOT/nokill"

echo "Number One: a stop that quiesces first and believes only an empty census"
[ -f "$XO" ] || { echo "script under test not found at $XO"; exit 1; }

check "0. both engine names are shimmed on PATH, so nothing here can bill" \
  "[ \"\$(command -v copilot)\" = '$SHIMBIN/copilot' ] && [ \"\$(command -v claude)\" = '$SHIMBIN/claude' ]"
check "0. the census is its own seam, drivable from outside (xo census)" \
  "grep -q '^  census)' '$XO'"
check "0. the walker answers to 'census', not only to 'closure'" \
  "python3 '$TREE_PY' census '$MID' >/dev/null 2>&1"

# ===========================================================================
# 1. QUIESCE FIRST — the marker stops the resolver MINTING NEW DRIVERS.
# ===========================================================================
# The real `resolve-logs.sh`, the real wave loop, a run-driver stub that only
# LOGS what it was asked to drive. Bug 1's drive sleeps long enough for the stop
# to land mid-wave, so bugs 2 and 3 are genuinely DUE during the stop window.
#
# CONTROL FIRST, so the probe is known to be able to see a spawn at all: with no
# stop, all three are driven.
make_run_stub() { # <path>
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="$2"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
printf 'run drive %s\n' "$mid" >>"$RUN_LOG"
[ "$mid" = "$SLOW_ID" ] && sleep "${SLOW_FOR:-6}"
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
state="$gitdir/lcars/missions/$mid/state.json"
tmp="$(mktemp)"
awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' \
  "$state" >"$tmp" && mv "$tmp" "$state"
exit 0
EOF
  chmod +x "$1"
}
make_gh_stub() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }
make_notify_stub() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# --- 1a. CONTROL: no stop, so every bug is driven --------------------------
repoC="$(new_repo 3)"
make_run_stub "$repoC/run"; make_gh_stub "$repoC/gh"; make_notify_stub "$repoC/notify"
RUNLOG_C="$repoC/run.log"; : >"$RUNLOG_C"
(
  cd "$repoC"
  RUN_LOG="$RUNLOG_C" SLOW_ID="$BUG1" SLOW_FOR=1 \
  LCARS_XO_ENFORCE=0 LCARS_OWNER_ENFORCE=0 LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_GH_BIN="$repoC/gh" LCARS_GIT_BIN="$(command -v git)" \
  LCARS_NOTIFY="$repoC/notify" LCARS_RUN_SCRIPT="$repoC/run" \
    bash "$RESOLVE" "$MID"
) >"$TMPROOT/resolveC.out" 2>&1
NC="$(grep -c 'run drive' "$RUNLOG_C" 2>/dev/null | tr -d ' ')"; NC="${NC:-0}"
check "1a. CONTROL — with no stop the resolver drives all three bugs (saw $NC)" \
  "[ '$NC' -eq 3 ]"

# --- 1b. THE MARKER ALONE STOPS EVERY SPAWN --------------------------------
# The stop runs FIRST, with nothing of this mission alive, so the census cannot
# be what stops anything here — the resolver did not exist when the census was
# taken. The ONLY thing between the captain and three fresh billable drivers is
# the marker on disk.
repoM="$(new_repo 3)"
make_run_stub "$repoM/run"; make_gh_stub "$repoM/gh"; make_notify_stub "$repoM/notify"
RUNLOG_M="$repoM/run.log"; : >"$RUNLOG_M"
MDIR_M="$repoM/.git/lcars/missions/$MID"
( cd "$repoM" && bash "$XO" off "$MID" ) >"$TMPROOT/offM.out" 2>&1 || true
check "1b. the stop wrote its marker, atomically, on disk" \
  "[ -f '$MDIR_M/xo-stop' ] && [ ! -f '$MDIR_M/.xo-stop.'* ] 2>/dev/null || [ -f '$MDIR_M/xo-stop' ]"
check "1b. the marker is a RECORD of what it paused, not a bare flag" \
  "grep -q '^mission $MID' '$MDIR_M/xo-stop' && grep -q '^child $BUG1 paused-by-us' '$MDIR_M/xo-stop'"
check "1b. every linked child is paused, so a stage driver will not advance one" \
  "grep -q '\"paused\": *true' '$repoM/.git/lcars/missions/$BUG2/state.json' && grep -q '\"paused\": *true' '$repoM/.git/lcars/missions/$BUG3/state.json'"
check "1b. and the parent mission itself is paused" \
  "grep -q '\"paused\": *true' '$MDIR_M/state.json'"
(
  cd "$repoM"
  RUN_LOG="$RUNLOG_M" SLOW_ID="" SLOW_FOR=0 \
  LCARS_XO_ENFORCE=0 LCARS_OWNER_ENFORCE=0 LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_GH_BIN="$repoM/gh" LCARS_GIT_BIN="$(command -v git)" \
  LCARS_NOTIFY="$repoM/notify" LCARS_RUN_SCRIPT="$repoM/run" \
    bash "$RESOLVE" "$MID"
) >"$TMPROOT/resolveM.out" 2>&1
NM="$(grep -c 'run drive' "$RUNLOG_M" 2>/dev/null | tr -d ' ')"; NM="${NM:-0}"
check "1b. WITH THE MARKER DOWN THE RESOLVER MINTS NOTHING (saw $NM drivers, control saw $NC)" \
  "[ '$NM' -eq 0 ] && [ '$NC' -eq 3 ]"
check "1b. ...and it says so rather than failing silently" \
  "grep -q 'stood down' '$TMPROOT/resolveM.out'"

# --- 1c. THE RACE ITSELF: the marker lands MID-WAVE ------------------------
# Bug 1's drive is slow, so the stop lands while the resolver is between bugs and
# the next bug is genuinely due inside the stop window.
#
# ONE SEAM IS NARROWED FOR THIS PROBE, and said out loud: the census's declared
# exec list ($LCARS_XO_CENSUS_EXECS) is cut to the worker adapter, so the census
# cannot see — and therefore cannot kill — the test's own foreground resolver.
# Without that, the resolver would be swept by provenance and the probe could not
# tell "the marker stopped it" from "the sweep killed it". The sweep's reach is
# what cases 2-4 measure; THIS case measures the marker.
repoR="$(new_repo 3)"
make_run_stub "$repoR/run"; make_gh_stub "$repoR/gh"; make_notify_stub "$repoR/notify"
RUNLOG_R="$repoR/run.log"; : >"$RUNLOG_R"
MDIR_R="$repoR/.git/lcars/missions/$MID"
(
  cd "$repoR"
  RUN_LOG="$RUNLOG_R" SLOW_ID="$BUG1" SLOW_FOR=10 \
  LCARS_XO_ENFORCE=0 LCARS_OWNER_ENFORCE=0 LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_GH_BIN="$repoR/gh" LCARS_GIT_BIN="$(command -v git)" \
  LCARS_NOTIFY="$repoR/notify" LCARS_RUN_SCRIPT="$repoR/run" \
    bash "$RESOLVE" "$MID" >"$TMPROOT/resolveR.out" 2>&1
) &
RESOLVE_PID=$!
KILLME="$KILLME $RESOLVE_PID"
i=0
while [ "$i" -lt 150 ] && ! grep -q 'run drive' "$RUNLOG_R" 2>/dev/null; do
  i=$((i + 1)); nap 0.1
done
SPAWNS_BEFORE="$(grep -c 'run drive' "$RUNLOG_R" 2>/dev/null | tr -d ' ')"
SPAWNS_BEFORE="${SPAWNS_BEFORE:-0}"
( cd "$repoR" && LCARS_XO_CENSUS_EXECS="worker-adapter.sh" bash "$XO" off "$MID" ) \
  >"$TMPROOT/offR.out" 2>&1 || true
MARKED=0; [ -f "$MDIR_R/xo-stop" ] && MARKED=1
wait "$RESOLVE_PID" 2>/dev/null || true
SPAWNS_AFTER="$(grep -c 'run drive' "$RUNLOG_R" 2>/dev/null | tr -d ' ')"
SPAWNS_AFTER="${SPAWNS_AFTER:-0}"
echo "  --- the resolver's spawn log across a mid-wave stop ---"
sed 's/^/    /' "$RUNLOG_R"
check "1c. CONTROL — the resolver really was mid-wave when the stop landed" \
  "[ '$SPAWNS_BEFORE' -ge 1 ] && [ '$SPAWNS_BEFORE' -lt 3 ]"
check "1c. CONTROL — the resolver was NOT killed; it ran to its own end" \
  "grep -q 'stood down' '$TMPROOT/resolveR.out'"
check "1c. the marker was on disk before the sweep could matter" "[ '$MARKED' -eq 1 ]"
check "1c. ZERO new drivers after the marker (before $SPAWNS_BEFORE, after $SPAWNS_AFTER)" \
  "[ '$SPAWNS_AFTER' -eq '$SPAWNS_BEFORE' ]"
check "1c. ...so the bugs that were still due never started" \
  "! grep -q 'run drive $BUG3' '$RUNLOG_R'"

# ===========================================================================
# 2. CENSUS BY PROVENANCE — and the walk-from-a-dead-root that cannot see it.
# ===========================================================================
# The control IS the pre-fix gate: `xo-tree.py closure <recorded pid> <pgid>`
# rooted at a driver we have killed ourselves. It must report NOTHING while a
# billable process of this mission is alive — that is the vacuous pass, driven on
# purpose — and the census must name that same process.
repo2="$(new_repo 1)"
MDIR2="$repo2/.git/lcars/missions/$MID"
CL2="$TMPROOT/chain2.log"
UP2=1; bring_up "$CL2" "$MDIR2/xo-resolve.pid" || UP2=0
D2="$(sed -n 1p "$MDIR2/xo-resolve.pid" 2>/dev/null | tr -dc '0-9')"
G2="$(sed -n 2p "$MDIR2/xo-resolve.pid" 2>/dev/null | tr -dc '0-9')"
S2="$(field "$CL2" STAGE 1)"; A2="$(field "$CL2" ADAPTER 1)"; W2="$(field "$CL2" ASSISTANT 1)"
KILLME="$KILLME $D2 $S2 $A2 $W2"
echo "  --- the real tree, before anything is killed ---"
snap "$D2" "$S2" "$A2" "$W2"
check "2. CONTROL — all four levels are up, two groups, one orphan at ppid 1" \
  "[ '$UP2' -eq 1 ] && alive '$D2' && alive '$S2' && alive '$A2' && alive '$W2' && [ \"\$(ps -o ppid= -p ${S2:-0} | tr -dc 0-9)\" = '1' ] && nonempty '$A2' && [ \"\$(pgid_of ${A2:-0})\" = '$A2' ]"

# Kill the RECORDED LEADER by hand — the exact live state the stop could not see.
kill -9 "$D2" 2>/dev/null || true
k=0; while [ "$k" -lt 50 ] && alive "$D2"; do k=$((k + 1)); nap 0.1; done
CLOSURE_OUT="$( (cd "$repo2" && python3 "$TREE_PY" closure "${D2:-0}" "${G2:-0}" "$$") 2>/dev/null )"
CLOSURE_N="$(printf '%s\n' "$CLOSURE_OUT" | sed -n 's/^PID //p' | grep -c . | tr -d ' ')"
CLOSURE_N="${CLOSURE_N:-0}"
CENSUS_OUT="$( (cd "$repo2" && bash "$XO" census "$MID") 2>/dev/null )"
CENSUS_N="$(printf '%s\n' "$CENSUS_OUT" | sed -n 's/^PID //p' | grep -c . | tr -d ' ')"
CENSUS_N="${CENSUS_N:-0}"
echo "  --- with the recorded leader DEAD: the old walk vs the census ---"
printf '    closure (rooted at the dead pid %s): %s pid(s)\n' "${D2:-?}" "$CLOSURE_N"
printf '%s\n' "$CENSUS_OUT" | sed 's/^/    census: /'

check "2. CONTROL — the billing leaf and the orphan are STILL ALIVE" \
  "alive '$S2' && alive '$A2' && alive '$W2'"
check "2. CONTROL — the pre-fix walk from the dead root reports NOTHING (the vacuous pass: saw $CLOSURE_N)" \
  "[ '$CLOSURE_N' -eq 0 ]"
check "2. the census finds them anyway, by provenance (saw $CENSUS_N)" \
  "[ '$CENSUS_N' -ge 2 ]"
check "2. the census names the ORPHANED STAGE at ppid 1" \
  "nonempty '$S2' && printf '%s\n' \"\$CENSUS_OUT\" | grep -qx 'PID $S2'"
check "2. the census names the SELF-LED ADAPTER, in a group the chain never led" \
  "nonempty '$A2' && printf '%s\n' \"\$CENSUS_OUT\" | grep -qx 'PID $A2'"
check "2. the census names THE BILLING LEAF" \
  "nonempty '$W2' && printf '%s\n' \"\$CENSUS_OUT\" | grep -qx 'PID $W2'"
check "2. the census never names the process that asked" \
  "! printf '%s\n' \"\$CENSUS_OUT\" | grep -qx 'PID $$'"

# ===========================================================================
# 3. DEAD RECORDED LEADER → SURVIVORS NAMED, EXIT 1, HANDLES KEPT, NO CONN.
# ===========================================================================
rc3=0
( cd "$repo2" && LCARS_XO_KILL_BIN="$TMPROOT/nokill" bash "$XO" off "$MID" ) \
  >"$TMPROOT/off3.out" 2>&1 || rc3=$?
echo "  --- \`xo off\` over a dead leader, signals swallowed ---"
sed 's/^/    /' "$TMPROOT/off3.out"
check "3. CONTROL — nothing died, so there is something to lie about" \
  "alive '$A2' && alive '$W2'"
check "3. it does NOT say the captain has the conn" \
  "! grep -q 'you have the conn' '$TMPROOT/off3.out'"
check "3. it does NOT print the stood-down line" \
  "! grep -q 'stood down on' '$TMPROOT/off3.out'"
check "3. it exits NON-ZERO" "[ '$rc3' -ne 0 ]"
check "3. it NAMES a surviving billable pid" \
  "nonempty '$W2' && grep -q '$W2' '$TMPROOT/off3.out'"
check "3. IT KEEPS EVERY HANDLE — xo-resolve.pid survives a failed stop" \
  "[ -s '$MDIR2/xo-resolve.pid' ]"
check "3. ...and the stop marker survives too, so nothing can restart behind it" \
  "[ -f '$MDIR2/xo-stop' ]"
check "3. the record says stop-failed, never stood-down" \
  "grep -q 'stop-failed' '$MDIR2/number-one.jsonl' 2>/dev/null || grep -q 'could NOT stop' '$MDIR2/state.json'"

# A SECOND `xo off` finds them and kills them — the retry the live defect had
# made impossible by deleting its own handle.
rc3b=0
( cd "$repo2" && bash "$XO" off "$MID" ) >"$TMPROOT/off3b.out" 2>&1 || rc3b=$?
echo "  --- the second try, signals real ---"
sed 's/^/    /' "$TMPROOT/off3b.out"
snap "$S2" "$A2" "$W2"
check "3. the kept handle let the captain try again, and it worked (rc 0)" "[ '$rc3b' -eq 0 ]"
check "3. the orphan, the adapter and THE BILLING LEAF are all gone" \
  "nonempty '$S2' '$A2' '$W2' && ! kill -0 '$S2' 2>/dev/null && ! kill -0 '$A2' 2>/dev/null && ! kill -0 '$W2' 2>/dev/null"
check "3. ...and only NOW is the conn the captain's" \
  "grep -q 'you have the conn' '$TMPROOT/off3b.out'"
CENSUS_AFTER="$( (cd "$repo2" && bash "$XO" census "$MID") 2>/dev/null | sed -n 's/^PID //p' | grep -c . | tr -d ' ')"
check "3. THE SUCCESS LINE AGREES WITH THE CENSUS — it is empty (saw ${CENSUS_AFTER:-?})" \
  "[ \"\${CENSUS_AFTER:-1}\" -eq 0 ]"
check "3. ...and only now are the handles released" \
  "[ ! -f '$MDIR2/xo-resolve.pid' ]"

# ===========================================================================
# 4. A WORKER MINTED INSIDE THE STOP WINDOW IS DEAD BEFORE THE CONN LINE.
# ===========================================================================
# The rig's invisible timer waits for the product's own stop marker, then mints a
# fresh self-led billable worker at ppid 1. Nothing rooted at the recorded driver
# can reach it; only a RE-CENSUS can. So the conn line must come AFTER it is dead.
repo4="$(new_repo 1)"
MDIR4="$repo4/.git/lcars/missions/$MID"
CL4="$TMPROOT/chain4.log"
export STOPMARK="$MDIR4/xo-stop"
UP4=1; bring_up "$CL4" "$MDIR4/xo-resolve.pid" LATE || UP4=0
D4="$(sed -n 1p "$MDIR4/xo-resolve.pid" 2>/dev/null | tr -dc '0-9')"
S4="$(field "$CL4" STAGE 1)"; A4="$(field "$CL4" ADAPTER 1)"; W4="$(field "$CL4" ASSISTANT 1)"
KILLME="$KILLME $D4 $S4 $A4 $W4"
check "4. CONTROL — the rig is up with a late-spawner armed on the stop marker" \
  "[ '$UP4' -eq 1 ] && alive '$D4' && alive '$W4' && [ ! -f '$STOPMARK' ]"
rc4=0
( cd "$repo4" && bash "$XO" off "$MID" ) >"$TMPROOT/off4.out" 2>&1 || rc4=$?
echo "  --- \`xo off\` with a worker minted inside the window ---"
sed 's/^/    /' "$TMPROOT/off4.out"
echo "  --- the rig's own chain log ---"
sed 's/^/    /' "$CL4"
LATE_A="$(awk '$1 == "ADAPTER" { p = $2 } END { print p }' "$CL4")"
LATE_W="$(awk '$1 == "ASSISTANT" { p = $2 } END { print p }' "$CL4")"
KILLME="$KILLME $LATE_A $LATE_W"
CENSUS4="$( (cd "$repo4" && bash "$XO" census "$MID") 2>/dev/null )"
CENSUS4_N="$(printf '%s\n' "$CENSUS4" | sed -n 's/^PID //p' | grep -c . | tr -d ' ')"
check "4. CONTROL — the late spawner DID fire inside the window (a second worker exists)" \
  "grep -q 'LATE-SPAWNING' '$CL4' && nonempty '$LATE_A' '$A4' && [ '$LATE_A' != '$A4' ]"
check "4. the late worker is DEAD by the time the verb returns" \
  "grep -q 'LATE-SPAWNING' '$CL4' && nonempty '$LATE_W' '$W4' && [ '$LATE_W' != '$W4' ] && ! kill -0 '$LATE_W' 2>/dev/null"
check "4. the late ADAPTER is dead too" \
  "grep -q 'LATE-SPAWNING' '$CL4' && nonempty '$LATE_A' '$A4' && [ '$LATE_A' != '$A4' ] && ! kill -0 '$LATE_A' 2>/dev/null"
check "4. the whole census is empty after the verb (saw ${CENSUS4_N:-?})" \
  "grep -q 'LATE-SPAWNING' '$CL4' && [ \"\${CENSUS4_N:-1}\" -eq 0 ]"
check "4. and ONLY THEN is the conn handed over (rc 0 + the line)" \
  "grep -q 'LATE-SPAWNING' '$CL4' && [ '$rc4' -eq 0 ] && grep -q 'you have the conn' '$TMPROOT/off4.out'"
unset STOPMARK

# ===========================================================================
# 5. `xo.pid` GOES THROUGH THE VERIFIED PATH — handle kept until it is proven.
# ===========================================================================
# `xo.sh:800-803` was `kill -TERM "$pid"; rm -f xo.pid`: unverified, and it threw
# away the captain's only handle on the look. So: swallow the signals and the
# handle must stay; let them through and it must go — and not before.
repo5="$(new_repo 1)"
MDIR5="$repo5/.git/lcars/missions/$MID"
CL5="$TMPROOT/chain5.log"
CHAINLOG="$CL5"; : >"$CL5"; export CHAINLOG
bash "$XO" detach --pidfile "$MDIR5/xo.pid" --log "$TMPROOT/detach5.log" \
  -- bash "$RIG/run.sh" look --mission "$MID"
i=0
while [ "$i" -lt 200 ] && ! grep -q ASSISTANT "$CL5" 2>/dev/null; do i=$((i + 1)); nap 0.1; done
L5="$(sed -n 1p "$MDIR5/xo.pid" 2>/dev/null | tr -dc '0-9')"
A5="$(field "$CL5" ADAPTER 1)"; W5="$(field "$CL5" ASSISTANT 1)"
KILLME="$KILLME $L5 $A5 $W5"
check "5. CONTROL — the look chain is up and xo.pid records WHO, not just a number" \
  "alive '$L5' && alive '$W5' && [ \"\$(grep -c . '$MDIR5/xo.pid')\" -ge 3 ]"
rc5=0
( cd "$repo5" && LCARS_XO_KILL_BIN="$TMPROOT/nokill" bash "$XO" off "$MID" ) \
  >"$TMPROOT/off5.out" 2>&1 || rc5=$?
echo "  --- the look's stop, signals swallowed ---"
sed 's/^/    /' "$TMPROOT/off5.out"
check "5. CONTROL — the look is still alive, so a false claim is possible" "alive '$L5'"
check "5. a TERM that did not take exits NON-ZERO" "[ '$rc5' -ne 0 ]"
check "5. ...and does not claim the conn" \
  "! grep -q 'you have the conn' '$TMPROOT/off5.out'"
KEPT5=0
[ -s "$MDIR5/xo.pid" ] \
  && [ "$(sed -n 1p "$MDIR5/xo.pid" | tr -dc '0-9')" = "$L5" ] && KEPT5=1
check "5. XO.PID IS KEPT — the captain's only handle on a live look" "[ '$KEPT5' -eq 1 ]"
rc5b=0
( cd "$repo5" && bash "$XO" off "$MID" ) >"$TMPROOT/off5b.out" 2>&1 || rc5b=$?
k=0; while [ "$k" -lt 100 ] && { alive "$L5" || alive "$W5"; }; do k=$((k + 1)); nap 0.1; done
check "5. with real signals the look and its worker are gone" \
  "nonempty '$L5' '$W5' && ! kill -0 '$L5' 2>/dev/null && ! kill -0 '$W5' 2>/dev/null"
check "5. ...the verb succeeds and says so" \
  "[ '$rc5b' -eq 0 ] && grep -q 'you have the conn' '$TMPROOT/off5b.out'"
check "5. ...and ONLY NOW is xo.pid removed" \
  "[ '$KEPT5' -eq 1 ] && [ ! -f '$MDIR5/xo.pid' ]"

# ===========================================================================
# 6. THE SUCCESS LINE IS GATED ON THE CENSUS, NOT ON A COUNT OF SIGNALS SENT.
# ===========================================================================
# Asserted on the CENSUS OUTPUT, never on a pid count rooted at a recorded pid —
# that count is the vacuous one. The gate is TWO censuses, ≥2 s apart, both
# empty, so a stop cannot win by being asked at a lucky instant.
check "6. the verb that said 'conn' and the census agree (case 4)" \
  "grep -q 'you have the conn' '$TMPROOT/off4.out' && [ \"\${CENSUS4_N:-1}\" -eq 0 ]"
check "6. the verb that refused and the census agree too (case 3)" \
  "! grep -q 'you have the conn' '$TMPROOT/off3.out'"
check "6. the gate is TWO censuses, a measured interval apart" \
  "grep -q 'LCARS_XO_CENSUS_GAP' '$XO'"
check "6. ...and the vacuous before/after walk gate is GONE from the stop path" \
  "! grep -q 'xo_stop_refresh' '$XO'"

# ===========================================================================
# 7. `xo on <id>` LIFTS THE QUIESCE — AND ONLY WHAT THE STOP ITSELF PUT ON.
# ===========================================================================
# A child the captain had paused FOR HIS OWN REASON before the stop must still be
# paused afterwards. The marker RECORDS which children the stop paused, so this
# is read back from a record rather than guessed from the current flag.
repo7="$(new_repo 3)"
MDIR7="$repo7/.git/lcars/missions/$MID"
# BUG2 is paused for its own reason, BEFORE any stop.
python3 - "$repo7/.git/lcars/missions/$BUG2/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["paused"] = True
json.dump(d, open(p, "w"), indent=2)
PY
check "7. CONTROL — one child is paused for its own reason before the stop" \
  "grep -q '\"paused\": *true' '$repo7/.git/lcars/missions/$BUG2/state.json' && ! grep -q '\"paused\"' '$repo7/.git/lcars/missions/$BUG1/state.json'"
( cd "$repo7" && bash "$XO" off "$MID" ) >"$TMPROOT/off7.out" 2>&1 || true
check "7. the stop quiesced everything" \
  "[ -f '$MDIR7/xo-stop' ] && grep -q '\"paused\": *true' '$repo7/.git/lcars/missions/$BUG1/state.json'"
check "7. ...and RECORDED which children it paused and which were already paused" \
  "grep -q \"^child $BUG1 paused-by-us\" '$MDIR7/xo-stop' && grep -q \"^child $BUG2 already-paused\" '$MDIR7/xo-stop'"
Q7=0
[ -f "$MDIR7/xo-stop" ] \
  && grep -q '"paused": *true' "$repo7/.git/lcars/missions/$BUG1/state.json" && Q7=1
( cd "$repo7" && bash "$XO" on "$MID" ) >"$TMPROOT/on7.out" 2>&1 || true
check "7. \`xo on\` clears the marker, so work may start again" \
  "[ '$Q7' -eq 1 ] && [ ! -f '$MDIR7/xo-stop' ]"
check "7. it un-pauses the children the STOP paused" \
  "[ '$Q7' -eq 1 ] && ! grep -q '\"paused\": *true' '$repo7/.git/lcars/missions/$BUG1/state.json' && ! grep -q '\"paused\": *true' '$repo7/.git/lcars/missions/$BUG3/state.json'"
check "7. A CHILD PAUSED FOR ITS OWN REASON STAYS PAUSED" \
  "[ '$Q7' -eq 1 ] && grep -q '\"paused\": *true' '$repo7/.git/lcars/missions/$BUG2/state.json'"
check "7. ...and the parent is back in play" \
  "[ '$Q7' -eq 1 ] && ! grep -q '\"paused\": *true' '$MDIR7/state.json'"

# ===========================================================================
# 7b. THE REPO-WIDE SWITCH IS SYMMETRIC — OFF QUIESCES ALL, ON LIFTS ALL.
# ===========================================================================
# `lcars xo off` with no mission stands DOWN every engaged mission, so it writes a
# marker on each. If `lcars xo on` lifted none of them, "ON" would be a word with
# nothing behind it: every stage driver and every resolver would still refuse to
# spawn, and the only way back would be `lcars xo on <id>` once per mission, which
# nobody would know to do. This is the same shape as the defect S240 fix round 2
# cured one fact ago, so it gets its own control.
repo7b="$(new_repo 2)"
MDIR7B="$repo7b/.git/lcars/missions/$MID"
( cd "$repo7b" && bash "$XO" off ) >"$TMPROOT/off7b.out" 2>&1 || true
Q7B=0
[ -f "$MDIR7B/xo-stop" ] \
  && grep -q '"paused": *true' "$repo7b/.git/lcars/missions/$BUG1/state.json" && Q7B=1
check "7b. CONTROL — the repo-wide OFF quiesced the mission and its children" \
  "[ '$Q7B' -eq 1 ]"
( cd "$repo7b" && bash "$XO" on --engine claude --no-sweep ) >"$TMPROOT/on7b.out" 2>&1 || true
check "7b. the repo-wide ON lifts the marker, so work can start again" \
  "[ '$Q7B' -eq 1 ] && [ ! -f '$MDIR7B/xo-stop' ]"
check "7b. ...and un-pauses the children it paused" \
  "[ '$Q7B' -eq 1 ] && ! grep -q '\"paused\": *true' '$repo7b/.git/lcars/missions/$BUG1/state.json'"
check "7b. ...and says ON" "grep -q 'NUMBER ONE: ON' '$TMPROOT/on7b.out'"

# ===========================================================================
# 8. THE STAGE DRIVER REFUSES TO SPAWN A WORKER WITH THE MARKER DOWN.
# ===========================================================================
# run.sh honours `paused` BETWEEN stages (:20746). The window this closes is the
# one between that check and the spawn: the stop can land in it.
check "8. run.sh checks the stop marker immediately before it spawns a stage worker" \
  "grep -q 'xo-stop' '$RUN_SH'"
check "8. resolve-logs checks it before EVERY driver spawn, not once per batch" \
  "[ \"\$(grep -c 'xo-stop\\|quiesced' '$RESOLVE')\" -ge 2 ]"

# ===========================================================================
# 10. THE OTHER HALF OF THE RULE: A CENSUS MUST NOT KILL THE WRONG THING.
# ===========================================================================
# A whole-machine sweep keyed on argv is one loose match away from killing the
# captain's own `grep <mission-id>`, his editor open on the mission's state file,
# or the `tail` he left on its log. So the inferred half carries a second,
# DECLARED condition — the argv must also name something LCARS launches
# ($LCARS_XO_CENSUS_EXECS) — and this is the control for it: three bystanders that
# all NAME the mission, none of which LCARS launched, beside one process that is
# genuinely a driver. The bystanders must live; the driver must not.
repo10="$(new_repo 1)"
MDIR10="$repo10/.git/lcars/missions/$MID"
BY1=""; BY2=""; BY3=""; DRV10=""
# A reader of the mission's own state file. The captain does this constantly.
tail -f "$MDIR10/state.json" >/dev/null 2>&1 & BY1=$!
# Somebody looking for the mission by name — the exact shape of a tester's own
# whole-machine check, which must not be collateral of the thing it is checking.
perl -e 'sleep 300' -- "grep $MID" >/dev/null 2>&1 & BY2=$!
# A shell holding the mission directory open.
perl -e 'sleep 300' -- "$MDIR10" >/dev/null 2>&1 & BY3=$!
# And one that IS a driver of this mission, by name and by executable.
cp "$RIG/run.sh" "$TMPROOT/run.sh" 2>/dev/null || true
perl -e 'sleep 300' -- "run.sh" drive --mission "$MID" >/dev/null 2>&1 & DRV10=$!
KILLME="$KILLME $BY1 $BY2 $BY3 $DRV10"
nap 0.5
CEN10="$( (cd "$repo10" && bash "$XO" census "$MID") 2>/dev/null )"
echo "  --- the census over three bystanders and one driver ---"
printf '%s\n' "$CEN10" | sed 's/^/    /'
check "10. CONTROL — all four are alive and all four NAME the mission" \
  "alive '$BY1' && alive '$BY2' && alive '$BY3' && alive '$DRV10'"
check "10. the census names the one that is a DRIVER of this mission" \
  "nonempty '$DRV10' && printf '%s\n' \"\$CEN10\" | grep -qx 'PID $DRV10'"
check "10. it does NOT name the reader of the mission's state file" \
  "nonempty '$BY1' && ! printf '%s\n' \"\$CEN10\" | grep -qx 'PID $BY1'"
check "10. it does NOT name the process searching for the mission by name" \
  "nonempty '$BY2' && ! printf '%s\n' \"\$CEN10\" | grep -qx 'PID $BY2'"
check "10. it does NOT name the process holding the mission directory" \
  "nonempty '$BY3' && ! printf '%s\n' \"\$CEN10\" | grep -qx 'PID $BY3'"
( cd "$repo10" && bash "$XO" off "$MID" ) >"$TMPROOT/off10.out" 2>&1 || true
k=0; while [ "$k" -lt 60 ] && alive "$DRV10"; do k=$((k + 1)); nap 0.1; done
check "10. the stop killed the driver" \
  "nonempty '$DRV10' && ! kill -0 '$DRV10' 2>/dev/null"
check "10. AND EVERY BYSTANDER LIVES — the captain's own work is not collateral" \
  "alive '$BY1' && alive '$BY2' && alive '$BY3'"
check "10. ...and so does the shell that asked" "kill -0 $$ 2>/dev/null"
for p in $BY1 $BY2 $BY3; do kill -9 "$p" 2>/dev/null || true; done

# ===========================================================================
# 11. THE STOP SAYS WHAT IT PAUSED (S245 fix round 1, D1).
# ===========================================================================
# Quiescing is HALF THE STOP, and it is the half that outlives the command: the
# processes are gone but `paused` is still on the mission and on every linked
# child, and `lcars run` will refuse to move for as long as it is. The stop never
# said so — the word "paused" appeared nowhere in its output — so the captain met
# `⏸ paused at: …` days later with no idea which command had done it, and no idea
# that `lcars xo on` was the thing that lifts it.
#
# ASSERTED ON THE COUNT, NOT ON A STRING. The number printed has to be the number
# of state.json files that actually carry the flag, so a line that says "4" over
# three paused missions fails here. And a stop that paused NOTHING must not print
# the line at all — that is the control, below, and it is what stops this
# assertion being "the output contains a word we hard-coded".
repo11="$(new_repo 3)"
M11="$repo11/.git/lcars/missions"
( cd "$repo11" && bash "$XO" off ) >"$TMPROOT/off11.out" 2>&1 || true
echo "  --- the repo-wide stop ---"
sed 's/^/    /' "$TMPROOT/off11.out"
P11="$(grep -l '"paused": *true' "$M11"/*/state.json 2>/dev/null | grep -c .)"
P11="$(printf '%s' "$P11" | tr -dc '0-9')"
check "11. CONTROL — the stop really did pause 4 missions (the mission + 3 children)" \
  "[ '$P11' -eq 4 ]"
check "11. ...and the captain is TOLD he paused something" \
  "grep -qi 'paused' '$TMPROOT/off11.out'"
check "11. ...with the RIGHT COUNT, read back off the flags on disk" \
  "[ '$P11' -eq 4 ] && grep -q '4 missions' '$TMPROOT/off11.out'"
check "11. ...and the command that lifts it, named" \
  "grep -q 'lcars xo on' '$TMPROOT/off11.out'"
# THE CONTROL THAT MAKES THE THREE ABOVE FIRE. Same verb, a repo where nothing is
# engaged and nothing gets paused: the paused line must be ABSENT. If it printed
# here, "it says paused" above would be a constant, not a measurement.
repo11b="$(new_repo 0)"
python3 - "$repo11b/.git/lcars/missions/$MID/state.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["numberOne"] = {"status": "finished"}
open(p, "w").write("{\n" + ",\n".join(
    '  %s: %s' % (json.dumps(k), json.dumps(v)) for k, v in d.items()) + "\n}\n")
PY
( cd "$repo11b" && bash "$XO" off ) >"$TMPROOT/off11b.out" 2>&1 || true
P11B="$(grep -l '"paused": *true' "$repo11b"/.git/lcars/missions/*/state.json 2>/dev/null | grep -c .)"
P11B="$(printf '%s' "$P11B" | tr -dc '0-9')"
check "11. CONTROL — a stop with nothing engaged pauses nothing" "[ '$P11B' -eq 0 ]"
check "11. ...and so says nothing about pausing" \
  "[ '$P11B' -eq 0 ] && ! grep -qi 'paused' '$TMPROOT/off11b.out'"
# AND THE TARGETED FORM SAYS IT TOO — same quiesce, same consequence, and a
# captain who typed a mission id is no less entitled to know.
repo11c="$(new_repo 2)"
( cd "$repo11c" && bash "$XO" off "$MID" ) >"$TMPROOT/off11c.out" 2>&1 || true
echo "  --- the targeted stop ---"
sed 's/^/    /' "$TMPROOT/off11c.out"
P11C="$(grep -l '"paused": *true' "$repo11c"/.git/lcars/missions/*/state.json 2>/dev/null | grep -c .)"
P11C="$(printf '%s' "$P11C" | tr -dc '0-9')"
check "11. CONTROL — the targeted stop paused the mission and its 2 children" \
  "[ '$P11C' -eq 3 ]"
check "11. ...and says so, with the count and the way back" \
  "grep -q '3 missions' '$TMPROOT/off11c.out' && grep -qi 'paused' '$TMPROOT/off11c.out' \
     && grep -q 'lcars xo on' '$TMPROOT/off11c.out'"

# ===========================================================================
# 12. `lcars resume` CANNOT REPORT SUCCESS OVER A MISSION THAT WILL NOT MOVE.
# ===========================================================================
# This is the SAME CLASS OF LIE this whole session exists to kill, one surface
# along. run.sh halts on EITHER `paused` OR the `xo-stop` marker (:20821, and
# :20823 for a bug child whose PARENT holds it). `lcars resume` knew only about
# `paused`: it cleared the flag, dropped the label, printed "re-entering the
# driver" and handed back a mission that could not take a step, because only
# `lcars xo on` removes the marker.
#
# THE MUTATION IS ONE FILE. Every assertion below is run twice on the SAME repo —
# once with the marker on disk, once after `rm`-ing exactly that one file — so a
# refusal that fired for any other reason fails the second half.
repo12="$(new_repo 3)"
M12="$repo12/.git/lcars/missions"
cat >"$TMPROOT/runstub" <<'R'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$XO_DRIVE_WITNESS"
R
chmod +x "$TMPROOT/runstub"
( cd "$repo12" && bash "$XO" off "$MID" ) >"$TMPROOT/off12.out" 2>&1 || true
check "12. CONTROL — the stop left the marker on disk and `paused` on the mission" \
  "[ -f '$M12/$MID/xo-stop' ] && grep -q '\"paused\": *true' '$M12/$MID/state.json'"
check "12. CONTROL — and run.sh halts on EITHER of them" \
  "grep -q 'xo-stop' '$RUN_SH' && grep -q 'json_raw \"\$STATE\" paused' '$RUN_SH'"
W12="$TMPROOT/drove12"; : >"$W12"
rc12=0
( cd "$repo12" && XO_DRIVE_WITNESS="$W12" LCARS_GH_BIN="$TMPROOT/nogh" \
    LCARS_RUN_SCRIPT="$TMPROOT/runstub" bash "$PAUSE" resume "$MID" ) \
  >"$TMPROOT/res12.out" 2>&1 || rc12=$?
echo "  --- resume over Number One's stop ---"
sed 's/^/    /' "$TMPROOT/res12.out"
check "12. resume over the marker exits NON-ZERO" "[ '$rc12' -ne 0 ]"
check "12. ...and never claims it resumed anything" \
  "! grep -q 'RESUME: resuming' '$TMPROOT/res12.out' \
     && ! grep -q 're-entering the driver' '$TMPROOT/res12.out'"
check "12. ...and names \`lcars xo on\` as the thing that lifts it" \
  "grep -q 'lcars xo on' '$TMPROOT/res12.out'"
check "12. ...and changed NOTHING — the flag is still on, the marker still down" \
  "grep -q '\"paused\": *true' '$M12/$MID/state.json' && [ -f '$M12/$MID/xo-stop' ]"
check "12. ...and never started a driver over a mission that cannot move" \
  "[ ! -s '$W12' ]"
# ── THE MUTATION: remove that ONE file and nothing else. ───────────────────
rm -f "$M12/$MID/xo-stop"
W12B="$TMPROOT/drove12b"; : >"$W12B"
rc12b=0
( cd "$repo12" && XO_DRIVE_WITNESS="$W12B" LCARS_GH_BIN="$TMPROOT/nogh" \
    LCARS_RUN_SCRIPT="$TMPROOT/runstub" bash "$PAUSE" resume "$MID" ) \
  >"$TMPROOT/res12b.out" 2>&1 || rc12b=$?
check "12. CONTROL — with the marker gone the SAME resume succeeds" \
  "[ '$rc12b' -eq 0 ] && grep -q 'RESUME: resuming' '$TMPROOT/res12b.out'"
check "12. CONTROL — ...clears the flag" \
  "! grep -q '\"paused\": *true' '$M12/$MID/state.json'"
check "12. CONTROL — ...and DOES re-enter the driver" \
  "grep -q 'drive --mission $MID' '$W12B'"
# ── AND THE BUG CHILD, whose halt is keyed on its PARENT's marker. ─────────
repo12c="$(new_repo 3)"
M12C="$repo12c/.git/lcars/missions"
( cd "$repo12c" && bash "$XO" off "$MID" ) >"$TMPROOT/off12c.out" 2>&1 || true
check "12c. CONTROL — the child is paused and its PARENT holds the marker (it has none of its own)" \
  "grep -q '\"paused\": *true' '$M12C/$BUG1/state.json' && [ ! -f '$M12C/$BUG1/xo-stop' ] \
     && [ -f '$M12C/$MID/xo-stop' ]"
W12C="$TMPROOT/drove12c"; : >"$W12C"
rc12c=0
( cd "$repo12c" && XO_DRIVE_WITNESS="$W12C" LCARS_GH_BIN="$TMPROOT/nogh" \
    LCARS_RUN_SCRIPT="$TMPROOT/runstub" bash "$PAUSE" resume "$BUG1" ) \
  >"$TMPROOT/res12c.out" 2>&1 || rc12c=$?
echo "  --- resume of a bug child under its parent's stop ---"
sed 's/^/    /' "$TMPROOT/res12c.out"
check "12c. resuming a child under its parent's stop refuses, and names the parent" \
  "[ '$rc12c' -ne 0 ] && grep -q '$MID' '$TMPROOT/res12c.out' \
     && grep -q 'lcars xo on' '$TMPROOT/res12c.out'"
check "12c. ...and starts no driver" "[ ! -s '$W12C' ]"
rm -f "$M12C/$MID/xo-stop"
W12D="$TMPROOT/drove12d"; : >"$W12D"
rc12d=0
( cd "$repo12c" && XO_DRIVE_WITNESS="$W12D" LCARS_GH_BIN="$TMPROOT/nogh" \
    LCARS_RUN_SCRIPT="$TMPROOT/runstub" bash "$PAUSE" resume "$BUG1" ) \
  >"$TMPROOT/res12d.out" 2>&1 || rc12d=$?
check "12c. CONTROL — with the parent's marker gone the child resumes and drives" \
  "[ '$rc12d' -eq 0 ] && grep -q 'drive --mission $BUG1' '$W12D'"

# ===========================================================================
# 13. A REFUSAL NEVER CLAIMS IT CHANGED NOTHING AFTER IT HAS CHANGED THINGS.
# ===========================================================================
# `lcars_state_refusal_die` says "Nothing was written and nothing else in this
# command took effect." That sentence is a CONTRACT, and it was true of every
# verb that calls it — because every one of them called it immediately before its
# success line and after a single write. The quiesce broke it by writing FIRST:
# with one malformed state.json anywhere in the repo, `lcars xo off` printed that
# sentence and exited 1 having already written the stop marker, paused 4 missions
# and set `enabled: false`.
#
# THE CURE IS STRUCTURAL, NOT A LONGER SENTENCE: the stop's own writes no longer
# leave the refusal latched, so that sentence is UNREACHABLE once the stop has
# written — and what could not be recorded is named instead. 13b is the proof the
# contract still holds where it is still true.
repo13="$(new_repo 3)"
M13="$repo13/.git/lcars/missions"
# ONE malformed file, on a mission that is engaged — compact JSON, which is valid
# JSON and NOT the one-field-per-line object the writer will touch.
cat >"$M13/$BUG3/state.json" <<EOF
{"id": "$BUG3", "type": "bug", "stage": "plan", "numberOne": {"status": "engaged"}}
EOF
rc13=0
( cd "$repo13" && bash "$XO" off ) >"$TMPROOT/off13.out" 2>&1 || rc13=$?
echo "  --- the stop with one malformed state.json ---"
sed 's/^/    /' "$TMPROOT/off13.out"
P13="$(grep -l '"paused": *true' "$M13"/*/state.json 2>/dev/null | grep -c .)"
P13="$(printf '%s' "$P13" | tr -dc '0-9')"
check "13. CONTROL — it DID write: the marker, the paused flags and the config switch" \
  "[ -f '$M13/$MID/xo-stop' ] && [ '$P13' -ge 3 ] \
     && grep -q '\"enabled\": *false' '$repo13/.git/lcars/config.json'"
check "13. so it must NOT say nothing was written" \
  "! grep -q 'was NOT changed' '$TMPROOT/off13.out' \
     && ! grep -q 'nothing else in this command took effect' '$TMPROOT/off13.out'"
check "13. it names the mission it could not RECORD the stop on" \
  "grep -q '$BUG3' '$TMPROOT/off13.out'"
check "13. ...and still exits non-zero, so nothing downstream reads it as clean" \
  "[ '$rc13' -ne 0 ]"
check "13. ...and still says what it DID do" \
  "grep -q 'NUMBER ONE: OFF' '$TMPROOT/off13.out' && grep -qi 'paused' '$TMPROOT/off13.out'"
# THE CONTROL: the SAME repo shape with the file put back to one field per line.
# No warning, exit 0 — so the assertions above are keyed on that one file.
repo13b="$(new_repo 3)"
rc13b=0
( cd "$repo13b" && bash "$XO" off ) >"$TMPROOT/off13b.out" 2>&1 || rc13b=$?
check "13. CONTROL — with every state.json well-formed the stop is clean and exits 0" \
  "[ '$rc13b' -eq 0 ] && ! grep -qi 'could NOT record' '$TMPROOT/off13b.out'"
# 13b. AND THE CONTRACT SURVIVES WHERE IT IS TRUE. A targeted stop on a mission
# that is NOT engaged writes nothing at all: no marker, no flags. If its one write
# is refused, "Nothing was written" is the honest sentence and must still print.
repo13c="$(new_repo 0)"
M13C="$repo13c/.git/lcars/missions"
cat >"$M13C/$MID/state.json" <<EOF
{"id": "$MID", "type": "feature", "stage": "verify", "numberOne": {"status": "finished"}}
EOF
rc13c=0
( cd "$repo13c" && bash "$XO" off "$MID" ) >"$TMPROOT/off13c.out" 2>&1 || rc13c=$?
echo "  --- a refusal where nothing HAD been written ---"
sed 's/^/    /' "$TMPROOT/off13c.out"
check "13b. CONTROL — nothing was written on this path: no marker, no paused flag" \
  "[ ! -f '$M13C/$MID/xo-stop' ] && ! grep -q '\"paused\"' '$M13C/$MID/state.json'"
check "13b. ...so the true refusal still prints, unchanged" \
  "grep -q 'was NOT changed' '$TMPROOT/off13c.out' \
     && grep -q 'nothing else in this command took effect' '$TMPROOT/off13c.out' \
     && [ '$rc13c' -ne 0 ]"
check "13b. ...and it does NOT claim a stand-down or the conn" \
  "! grep -q 'you have the conn' '$TMPROOT/off13c.out'"

# ===========================================================================
# 14. THE DEAD RECORDED LEADER'S NOTE SAYS WHAT STOPPED, TOO.
# ===========================================================================
# The note's logs clause was keyed on a LIVE recorded resolve pid, so it vanished
# in exactly the case that should alarm the captain most: the chain's recorded
# leader is already gone, nobody knows what it left behind, and the card read
# "Number One stood down 20:25 · you have the conn" — four fewer facts than the
# ordinary stop gives him. What stopped is a property of the logs, not of whether
# one pid file happened to still be valid.
repo14="$(new_repo 3)"
M14="$repo14/.git/lcars/missions"
note14() { python3 - "$1" <<'PY'
import json, sys
try: print(json.load(open(sys.argv[1])).get("numberOne", {}).get("note", ""))
except Exception: print("")
PY
}
check "14. CONTROL — 3 logs on file and NO recorded resolve leader at all" \
  "[ \"\$(grep -o '\"mission\"' '$M14/$MID/xo/logs.json' | grep -c .)\" -eq 3 ] \
     && [ ! -f '$M14/$MID/xo-resolve.pid' ]"
( cd "$repo14" && bash "$XO" off "$MID" ) >"$TMPROOT/off14.out" 2>&1 || true
N14="$(note14 "$M14/$MID/state.json")"
echo "  --- the note, recorded leader dead ---"
printf '    %s\n' "$N14"
check "14. the note names the 3 logs it was driving" \
  "printf '%s' \"\$N14\" | grep -q '3 logs'"
check "14. ...and still hands over the conn" \
  "printf '%s' \"\$N14\" | grep -q 'you have the conn'"
# CONTROL 1 — no logs, no logs clause. Keeps the assertion above a measurement.
repo14b="$(new_repo 0)"
( cd "$repo14b" && bash "$XO" off "$MID" ) >"$TMPROOT/off14b.out" 2>&1 || true
N14B="$(note14 "$repo14b/.git/lcars/missions/$MID/state.json")"
check "14. CONTROL — with no logs on file the note has no logs clause" \
  "printf '%s' \"\$N14B\" | grep -q 'you have the conn' \
     && ! printf '%s' \"\$N14B\" | grep -qi 'it was driving'"
# CONTROL 2 — one log is "1 log", never "1 logs" (the S204 D5 rule, on this path).
repo14c="$(new_repo 1)"
( cd "$repo14c" && bash "$XO" off "$MID" ) >"$TMPROOT/off14c.out" 2>&1 || true
N14C="$(note14 "$repo14c/.git/lcars/missions/$MID/state.json")"
check "14. one log reads '1 log', not '1 logs'" \
  "printf '%s' \"\$N14C\" | grep -q '1 log ' && ! printf '%s' \"\$N14C\" | grep -q '1 logs'"
# ...AND THE VERB AGREES WITH IT (fix round 2). The noun was already singular and
# already measured; the VERB beside it was not, so the card the captain reads said
# "the 1 log it was driving ARE no longer running". Half a fix is still a sentence
# he does not trust. Normalised through `tr` first: the note reaches some surfaces
# wrapped, and a grep for a sentence that a newline has split matches nothing and
# passes as a negative — that exact vacuous probe happened twice on this session.
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
repo14d="$(new_repo 2)"
( cd "$repo14d" && bash "$XO" off "$MID" ) >"$TMPROOT/off14d.out" 2>&1 || true
N14D="$(note14 "$repo14d/.git/lcars/missions/$MID/state.json")"
echo "  --- one log ---"; printf '    %s\n' "$N14C"
echo "  --- two logs ---"; printf '    %s\n' "$N14D"
check "14. one log takes the SINGULAR verb: '1 log it was driving is no longer running'" \
  "flat \"\$N14C\" | grep -q '1 log it was driving is no longer running'"
check "14. ...and never the plural verb over one log" \
  "! flat \"\$N14C\" | grep -q 'it was driving are no longer'"
# POSITIVE CONTROL FOR THE SAME GREP — it must be able to MATCH, or the assertion
# above is a tautology; and a cure that swaps the word everywhere must break here.
check "14. CONTROL — 2 logs keep the plural verb: '2 logs it was driving are no longer running'" \
  "flat \"\$N14D\" | grep -q '2 logs it was driving are no longer running'"
check "14. CONTROL — 3 logs keep the plural verb too" \
  "flat \"\$N14\" | grep -q '3 logs it was driving are no longer running'"
check "14. CONTROL — and the plural note never takes the singular verb" \
  "! flat \"\$N14D\" | grep -q 'it was driving is no longer' \
     && ! flat \"\$N14\" | grep -q 'it was driving is no longer'"
# NEGATIVE CONTROL FOR THE GREP ITSELF — a note that cannot contain the clause at
# all. If this ever matches, every grep above is reading something it should not.
check "14. CONTROL — the no-logs note matches NEITHER verb form" \
  "! flat \"\$N14B\" | grep -q 'no longer running'"

# ===========================================================================
# 14b. THE SAME AGREEMENT ON THE UNSURE SENTENCE.
# ===========================================================================
# A resolve pid file that does not say WHO it was written about is REFUSED — the
# process on that number is left strictly alone — and the note has to admit it
# could not confirm. That sentence counts the same logs and had the same slip:
# "the 1 log it was driving HAVE stopped".
# Sets UNSURE_NOTE and UNSURE_PID in THIS shell — never inside a command
# substitution, because a `check` run in a subshell prints nowhere and increments
# nobody's counter, which is its own species of vacuous pass.
unsure_note() { # <n-logs>
  local n="$1" r
  r="$(new_repo "$n")"
  UNSURE_PID="$(sh -c 'sleep 30 >/dev/null 2>&1 & echo $!')"
  KILLME="$KILLME $UNSURE_PID"
  # A BARE pid: no identity line, so the stop must not signal it (and does not).
  printf '%s\n' "$UNSURE_PID" >"$r/.git/lcars/missions/$MID/xo-resolve.pid"
  ( cd "$r" && bash "$XO" off "$MID" ) >"$TMPROOT/off14u$n.out" 2>&1 || true
  UNSURE_NOTE="$(note14 "$r/.git/lcars/missions/$MID/state.json")"
}
unsure_note 1; N14U1="$UNSURE_NOTE"
check "14b. CONTROL — the unnamed pid was left strictly alone (1 log)" \
  "kill -0 '$UNSURE_PID' 2>/dev/null"
kill -TERM "$UNSURE_PID" 2>/dev/null || true
unsure_note 2; N14U2="$UNSURE_NOTE"
check "14b. CONTROL — the unnamed pid was left strictly alone (2 logs)" \
  "kill -0 '$UNSURE_PID' 2>/dev/null"
kill -TERM "$UNSURE_PID" 2>/dev/null || true
echo "  --- unsure, one log ---"; printf '    %s\n' "$N14U1"
echo "  --- unsure, two logs ---"; printf '    %s\n' "$N14U2"
check "14b. CONTROL — the unsure sentence is the one being measured" \
  "flat \"\$N14U1\" | grep -q 'could not confirm' \
     && flat \"\$N14U2\" | grep -q 'could not confirm'"
check "14b. one log takes the SINGULAR verb: '1 log it was driving has stopped'" \
  "flat \"\$N14U1\" | grep -q '1 log it was driving has stopped'"
check "14b. ...and never the plural verb over one log" \
  "! flat \"\$N14U1\" | grep -q 'it was driving have stopped'"
check "14b. CONTROL — 2 logs keep the plural verb: '2 logs it was driving have stopped'" \
  "flat \"\$N14U2\" | grep -q '2 logs it was driving have stopped'"
check "14b. CONTROL — ...and never the singular verb over two logs" \
  "! flat \"\$N14U2\" | grep -q 'it was driving has stopped'"

# ===========================================================================
# 9. NOTHING BILLED.
# ===========================================================================
SHIM_N="$(grep -c . "$SHIM_LOG" 2>/dev/null | tr -d ' ')"; SHIM_N="${SHIM_N:-0}"
SHIM_MODEL="$(grep -c 'yes$' "$SHIM_LOG" 2>/dev/null | tr -d ' ')"; SHIM_MODEL="${SHIM_MODEL:-0}"
printf '  shim invocations: %s (of which carried --model: %s) — real spend: 0\n' \
  "$SHIM_N" "$SHIM_MODEL"
check "9. the shim was the assistant every time the rig came up (>= 4)" \
  "[ '$SHIM_N' -ge 4 ]"
check "9. ...and every one of them carried --model, as a real worker would" \
  "[ '$SHIM_N' -eq '$SHIM_MODEL' ]"

echo
printf 'Number One quiesce + census: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
