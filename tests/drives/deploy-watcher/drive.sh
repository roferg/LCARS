#!/usr/bin/env bash
# ============================================================================
# DEPLOY-WATCHER DRIVE — does a deploy's dev server actually SEE its own files?
#
# S167 moved `lcars launch`'s deploy checkout out of the repo's `.git/` and into
# `<repo-parent>/.lcars-launch/<repo>/<key>`. The reason was not tidiness: Vite's
# default `server.watch.ignored` contains `**/.git/**`, so a deploy cut inside
# `.git/` was watched by NOTHING. The server booted, served pages, and then never
# saw another change — no HMR, no `import.meta.glob` re-evaluation, no re-read of
# data files. Every chokidar-based tool (webpack, nodemon, Tailwind JIT,
# `tsc --watch`) is affected identically. That made a deploy MISLEADING rather
# than merely limited: two correctly-fixed bug missions read as failures.
#
# A PATH ASSERTION CANNOT CATCH THAT. `tests/lcars-launch.test.sh` proves the
# worktree lands at the sibling path, and it would stay green if the next
# watcher-hostile location were invented tomorrow. The only instrument that can
# see the defect is a REAL dev server, running on a REAL deploy, asked whether it
# noticed a REAL new file. That is this drive.
#
# It runs two legs, sequentially:
#
#   GREEN  the real `lcars launch` deploy (outside `.git/`). A new
#          `src/data/*.json` MUST appear in the served glob.
#   RED    the pre-S167 topology, staged BY HAND inside `.git/`. The same new
#          file MUST NOT appear.
#
# THE RED CONTROL IS NOT OPTIONAL. A drive that cannot go red proves nothing: if
# the fixture stopped exercising the watcher at all (wrong url, cached response,
# glob no longer eager) the green leg would still pass by accident. The red leg is
# what makes the green leg mean something. If red ever goes green, this drive
# reports BROKEN CONTROL and fails — it does not quietly pass.
#
# Zero tokens: both CLI names are pinned by a PATH shim (see shim/claude).
# Zero network at run time, EXCEPT the one `npm install` of vite.
#
#   bash tests/drives/deploy-watcher/drive.sh
#
# Exit codes:
#   0   both legs held — green saw the file, red did not.
#   1   the GREEN leg failed: a real deploy could not see its own writes.
#   2   the RED control failed to go red — the drive proves nothing; fix the rig.
#   77  SKIPPED / infrastructure (no node, no npm, npm install failed, no free
#       port). Loudly, with a reason. Never a silent pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The LCARS checkout under test. Default: the repo this drive is committed in, so
# the drive is relocatable — no session id, no scratchpad path, no $HOME guess.
LCARS="${LCARS_REPO:-$(cd "$HERE/../../.." && pwd -P)}"
LAUNCH_SH="$LCARS/skills/lcars-launch/launch.sh"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
ok()   { printf '   \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { printf '\n\033[33mSKIPPED (infrastructure): %s\033[0m\n' "$*" >&2; exit 77; }

# Sub-second wait without the `sleep` binary (some sandboxes block foreground
# sleep); and a millisecond clock, because the green flip is measured in tens of ms.
nap()    { perl -e 'select(undef,undef,undef,'"${1:-0.1}"')' 2>/dev/null || true; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null || echo 0; }

[ -f "$LAUNCH_SH" ] || skip "no launch.sh at $LAUNCH_SH (set \$LCARS_REPO)"
command -v node >/dev/null 2>&1 || skip "node is not installed"
command -v npm  >/dev/null 2>&1 || skip "npm is not installed"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"
command -v git  >/dev/null 2>&1 || skip "git is not installed"

# --- ZERO SPEND, PROVEN BEFORE ANYTHING RUNS -------------------------------
# Prepend the shim dir and then CHECK that both CLI names really resolve inside
# it. launch.sh takes its engine from $LCARS_WORKER_BIN, else the mission's
# persisted state.json `workerBin`, else the literal `claude` — three paths with
# three different winners. Pinning PATH covers all three, but only if it actually
# took effect, so this refuses to run rather than risk one real worker.
export PATH="$HERE/shim:$PATH"
for cli in claude copilot; do
  resolved="$(command -v "$cli" 2>/dev/null || true)"
  case "$resolved" in
    "$HERE/shim/$cli") : ;;
    *) skip "the zero-spend PATH shim did not take: \`$cli\` resolves to \"${resolved:-nothing}\", not $HERE/shim/$cli" ;;
  esac
done

ROOT="${DRIVE_ROOT:-$(mktemp -d)}"
mkdir -p "$ROOT" || skip "cannot create the drive root $ROOT"
# Canonicalize: launch.sh builds every path with `pwd -P` and git reports realpaths
# (macOS /var → /private/var), so an uncanonicalized root breaks exact-path checks.
ROOT="$(cd "$ROOT" && pwd -P)"
export LCARS_DRIVE_SHIM_LOG="$ROOT/shim-invocations.tsv"
: > "$LCARS_DRIVE_SHIM_LOG"

PARENT="$ROOT/parent"
REPO="$PARENT/fixapp"
# The red control's in-.git worktree. Declared HERE, not at the leg that creates
# it, so cleanup can always name it — an early exit must still be able to
# unregister it.
RWT="$REPO/.git/lcars/launch/m1"
RED_PGID=""
GREEN_STOPPED=0
CLEANED=0
# May the drive delete its root? Only if it minted it. A $DRIVE_ROOT the operator
# named is THEIRS — prune the worktrees inside it, never remove the directory.
OWNS_ROOT=1
[ -n "${DRIVE_ROOT:-}" ] && OWNS_ROOT=0

cleanup() {
  local rc=$?                       # the status that triggered us — preserve it
  [ "$CLEANED" -eq 1 ] && exit "$rc"
  CLEANED=1

  # Reap the red control by its process GROUP. Backgrounding a `( … ) &` subshell
  # captures the SUBSHELL's pid, not vite's: killing it leaves vite reparented to
  # init, holding a port, forever. The red leg is therefore started the same way
  # launch.sh starts an app — perl POSIX::setsid, so PID == PGID — and reaped the
  # same way `--stop` reaps: TERM the group, grace, KILL the group.
  if [ -n "$RED_PGID" ]; then
    kill -TERM -"$RED_PGID" 2>/dev/null || true
    nap 0.4
    kill -KILL -"$RED_PGID" 2>/dev/null || true
  fi
  if [ "$GREEN_STOPPED" -eq 0 ] && [ -d "$REPO" ]; then
    ( cd "$REPO" && bash "$LAUNCH_SH" m1 --stop >/dev/null 2>&1 ) || true
  fi
  # Unregister the control worktree while the repo still exists. A registration
  # left behind in .git/worktrees would make a later `git worktree add` at the
  # same path fail on a pinned $DRIVE_ROOT.
  if [ -d "$REPO/.git" ]; then
    ( cd "$REPO" && git worktree remove --force "$RWT" >/dev/null 2>&1 ) || true
    ( cd "$REPO" && git worktree prune >/dev/null 2>&1 ) || true
  fi

  # A passing run leaves NOTHING: the root carries a node_modules tree (~18MB a
  # run) and used to accumulate one per run. A non-zero exit keeps it, because
  # every failure message above points AT it ("see $ROOT/red.log") and a message
  # that names a deleted file is worse than a kept directory.
  if [ "$OWNS_ROOT" -eq 1 ] && [ "$rc" -eq 0 ]; then
    rm -rf "$ROOT" 2>/dev/null || true
    printf '\n   artifacts: removed (nothing left running, nothing left on disk)\n'
  else
    printf '\n   artifacts: %s\n' "$ROOT"
    [ "$OWNS_ROOT" -eq 1 ] \
      && printf '   kept for diagnosis — rm -rf %s when you are done with it.\n' "$ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT
# Ctrl-C / TERM: exit explicitly so the EXIT trap above actually runs. Without
# these, an interrupted drive strands exactly what the trap exists to reap.
trap 'exit 130' INT
trap 'exit 143' TERM

free_port() {
  python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null
}

# Poll the probe until it reports $2, or the window expires. Prints the elapsed ms
# on success, "TIMEOUT" on expiry — and, critically, the LAST value seen, so a
# failure says what it actually saw rather than just "no".
poll_for() { # url want window-seconds
  local url="$1" want="$2" window="$3" t0 deadline seen
  t0="$(now_ms)"; deadline=$(( t0 + window * 1000 ))
  while :; do
    seen="$(bash "$HERE/probe.sh" "$url")"
    [ "$seen" = "$want" ] && { printf '%s\n' "$(( $(now_ms) - t0 ))"; return 0; }
    [ "$(now_ms)" -ge "$deadline" ] && { printf 'TIMEOUT(last=%s)\n' "$seen"; return 1; }
    nap 0.05
  done
}

# ============================================================================
say "1. a throwaway repo with the import.meta.glob fixture"
mkdir -p "$REPO"
cp -R "$HERE/fixture/." "$REPO/"
(
  cd "$REPO"
  git init -q
  git config user.email drive@test
  git config user.name "Deploy Watcher Drive"
  git symbolic-ref HEAD refs/heads/main
  git add -A && git commit -qm "fixture app"
  git checkout -qb lcars/m1
) || skip "could not build the fixture repo"
SHA="$(cd "$REPO" && git rev-parse lcars/m1)"
( cd "$REPO" && git checkout -q main )
note "repo:   $REPO"
note "branch: lcars/m1 @ ${SHA:0:8}"

say "2. npm install vite (the drive's only network step)"
T0="$(now_ms)"
( cd "$REPO" && npm install --silent --no-audit --no-fund ) >"$ROOT/npm.log" 2>&1 \
  || skip "npm install failed — see $ROOT/npm.log"
[ -x "$REPO/node_modules/.bin/vite" ] || skip "vite did not install — see $ROOT/npm.log"
note "took $(( ($(now_ms) - T0) / 1000 ))s"

say "3. LCARS config + a mission parked at verify"
mkdir -p "$REPO/.git/lcars/missions/m1"
VER="$(cat "$LCARS/VERSION" 2>/dev/null || echo 0.0.0)"
# worktreeSetupCommand symlinks the installed deps into each deploy checkout —
# the same shape a real repo uses, and far cheaper than a second npm install.
cat > "$REPO/.git/lcars/config.json" <<JSON
{
  "lcarsVersion": "$VER",
  "testCommand": "true",
  "worktreeSetupCommand": "ln -sfn '$REPO/node_modules' node_modules"
}
JSON
# workerBin is persisted DELIBERATELY. It is the resolution path that has been
# measured beating $LCARS_WORKER_BIN, so leaving it here proves the PATH shim —
# not an env var — is what holds spend at zero.
cat > "$REPO/.git/lcars/missions/m1/state.json" <<'JSON'
{
  "id": "m1",
  "title": "deploy-watcher fixture",
  "stage": "verify",
  "branch": "lcars/m1",
  "workerBin": "claude"
}
JSON

# ============================================================================
# GREEN LEG — the real `lcars launch` deploy, outside `.git/`.
# ============================================================================
say "4. GREEN — lcars launch m1 (deploy outside .git/)"
GPORT="$(free_port)"; [ -n "$GPORT" ] || skip "could not find a free TCP port"
export LCARS_TEST_APP_CMD="./node_modules/.bin/vite --port $GPORT --strictPort --host 127.0.0.1"
export LCARS_TEST_APP_URL="http://127.0.0.1:$GPORT/"
GURL="http://127.0.0.1:$GPORT/src/data-index.js"

( cd "$REPO" && LCARS_LAUNCH_SETTLE=3 bash "$LAUNCH_SH" m1 >"$ROOT/green-launch.out" 2>&1 )
GLJ="$REPO/.git/lcars/missions/m1/launch.json"
GWT="$PARENT/.lcars-launch/fixapp/m1"
grep -q '"status": "running"' "$GLJ" 2>/dev/null \
  || { cat "$ROOT/green-launch.out" >&2; skip "lcars launch did not reach status=running"; }
[ -d "$GWT" ] || skip "the deploy did not land at the expected path $GWT"
note "deploy: $GWT"
note "url:    $GURL"

fails=0
control_broken=0

# Wait for the server to be up and serving the ORIGINAL two entries. This is the
# baseline: without it, "3" later could just be a server that started late.
if BASE="$(poll_for "$GURL" 2 25)"; then
  ok "green baseline: the server is serving 2 glob entries (${BASE}ms to boot)"
else
  bad "green baseline: never served 2 glob entries ($BASE) — see $REPO/.git/lcars/missions/m1/launch.log"
  fails=$((fails + 1))
fi

# THE MEASUREMENT. Write a third data file into the deploy's own checkout and ask
# the server whether it noticed.
printf '{"id":"gamma"}\n' > "$GWT/src/data/gamma.json"
if GMS="$(poll_for "$GURL" 3 10)"; then
  ok "green: the deploy's server SAW the new file — glob went 2 → 3 in ${GMS}ms"
else
  bad "green: the deploy's server never saw its own new file ($GMS)"
  bad "       a deploy that cannot observe its own writes is the S167 defect, back."
  fails=$((fails + 1))
fi

( cd "$REPO" && bash "$LAUNCH_SH" m1 --stop >"$ROOT/green-stop.out" 2>&1 )
GREEN_STOPPED=1
nap 0.5

# ============================================================================
# RED CONTROL — the pre-S167 topology, staged BY HAND.
#
# It has to be by hand: `lcars launch` now REFUSES to deploy under `.git/`, which
# is the fix working. $LCARS_LAUNCH_ROOT is not a way in either — the guard
# rejects an override that points under `.git/` too, and correctly so. So the
# control reproduces the OLD SHAPE directly: the same commit, the same deps, the
# same vite, the same fixture — one thing different, the path.
# ============================================================================
say "5. RED CONTROL — the same app deployed inside .git/ (staged by hand)"
# $RWT is declared next to cleanup(), so an early exit can still unregister it.
( cd "$REPO" && git worktree add --detach -q "$RWT" "$SHA" ) \
  || skip "could not stage the in-.git control worktree"
ln -sfn "$REPO/node_modules" "$RWT/node_modules"
RPORT="$(free_port)"; [ -n "$RPORT" ] || skip "could not find a free TCP port for the control"
RURL="http://127.0.0.1:$RPORT/src/data-index.js"
# Started EXACTLY as launch.sh starts an app (see its "launch the discovered
# command DETACHED" block): perl POSIX::setsid makes the child its own session and
# process-group leader, and `exec` keeps the pid — so PID == PGID and cleanup can
# group-kill the whole vite tree. A plain `( … ) &` would hand back the subshell's
# pid instead and leak the server on every single run.
perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- \
  sh -c "cd '$RWT' && exec ./node_modules/.bin/vite --port '$RPORT' --strictPort --host 127.0.0.1" \
  >"$ROOT/red.log" 2>&1 &
RED_PGID=$!
# Drop it from the job table: we reap it by process group in cleanup, and without
# this bash prints a "Terminated: 15" job notice that reads like an error in an
# otherwise passing run.
disown "$RED_PGID" 2>/dev/null || true
note "deploy: $RWT"
note "url:    $RURL"

if RBASE="$(poll_for "$RURL" 2 25)"; then
  ok "red baseline: the control server is serving 2 glob entries (${RBASE}ms to boot)"
else
  bad "red baseline: the control server never came up ($RBASE) — see $ROOT/red.log"
  bad "      WITHOUT A WORKING CONTROL THE GREEN RESULT MEANS NOTHING."
  control_broken=1
fi

if [ "$control_broken" -eq 0 ]; then
  printf '{"id":"gamma"}\n' > "$RWT/src/data/gamma.json"
  # Give it MORE time than green needed, so "did not see it" is a real verdict and
  # not just an impatient one. Green flips in tens of ms; 10s is ~200x that.
  if RMS="$(poll_for "$RURL" 3 10)"; then
    bad "red control went GREEN: the in-.git deploy saw the new file in ${RMS}ms."
    bad "      Vite no longer ignores .git here, so this drive can no longer go red"
    bad "      and therefore proves NOTHING. Fix the rig before trusting the green leg."
    control_broken=1
  else
    ok "red control held: the in-.git deploy never saw the file ($RMS) — the blind spot is real"
  fi
fi

# ============================================================================
say "6. zero spend"
SHIMS="$(wc -l < "$LCARS_DRIVE_SHIM_LOG" | tr -d ' ')"
# Answer "would this have billed?" from the drive's own artifacts, not from a
# reading of launch.sh. 0 is the expected count on the `launch` role today; a
# non-zero here is not a failure, it is a CHANGE worth looking at.
MODELED="$(grep -c 'model=yes' "$LCARS_DRIVE_SHIM_LOG" 2>/dev/null || true)"
MODELED="${MODELED:-0}"
if [ "$SHIMS" -ge 1 ]; then
  ok "the launch worker went to the PATH shim $SHIMS time(s) — no real CLI was reachable"
  note "of those, $MODELED carried --model — the launch role pins no model, so 0 is expected"
else
  bad "the shim was never invoked — did launch.sh spawn a worker at all?"
  fails=$((fails + 1))
fi

say "verdict"
if [ "$control_broken" -ne 0 ]; then
  printf '\033[31mBROKEN CONTROL — this drive cannot go red, so it proves nothing.\033[0m\n'
  exit 2
fi
if [ "$fails" -ne 0 ]; then
  printf '\033[31mFAILED — %s check(s). A deploy could not see its own writes.\033[0m\n' "$fails"
  exit 1
fi
printf '\033[32mPASS — outside .git the deploy sees its own writes; inside .git it does not.\033[0m\n'
exit 0
