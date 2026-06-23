#!/usr/bin/env bash
#
# Tests for BUG-076 — a hung `copilot -p` cold worker (0% CPU, never returns,
# produces no output) must be auto-killed and retried, while a SLOW-but-working
# worker (burning CPU and/or still producing output) is left alone.
#
# The guard `run_worker_hang_guarded` (skill source: skills/lcars-run/run.sh)
# wraps a cold-worker spawn: it launches the command as its OWN process-group
# leader (perl POSIX::setsid — same trick as run_with_watchdog / BUG-048) and,
# on an interval, polls (a) the process group's CPU% and (b) the growth of the
# worker's output files ($outdir/.worker.out / .worker.err). If CPU stays ~0%
# AND the output has not grown for a SUSTAINED window (LCARS_WORKER_HANG_SECS),
# it declares the worker HUNG, group-kills it, and returns a distinct sentinel
# (137) so the spawn_worker retry loop counts it as a FAILED try. A worker that
# is using CPU OR still producing output is never killed; the stagnation timer
# resets on either. LCARS_WORKER_HANG_SECS=0 disables the guard entirely.
#
# STANDALONE, STUB-ONLY: drives the extracted function with FAKE workers made of
# `sleep`/`echo` ONLY — NO model worker, NO claude/copilot, NO gh, NO network,
# ZERO tokens. Safe to run directly. Do NOT route through tests/run.sh.
#
# Usage: bash tests/lcars-worker-hang.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# --- extract the functions under test (mirror lcars-watchdog.test.sh) --------
HG_LIB="$TMPROOT/hangguard.lib.sh"
sed -n '/^pid_alive() {/,/^}/p'                 "$RUN_SH" >"$HG_LIB"
sed -n '/^_pgid_cpu_sum() {/,/^}/p'             "$RUN_SH" >>"$HG_LIB"
sed -n '/^_file_size_mtime() {/,/^}/p'          "$RUN_SH" >>"$HG_LIB"
sed -n '/^run_worker_hang_guarded() {/,/^}/p'   "$RUN_SH" >>"$HG_LIB"
# shellcheck source=/dev/null
. "$HG_LIB"

for fn in pid_alive _pgid_cpu_sum _file_size_mtime run_worker_hang_guarded; do
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: could not extract $fn from $RUN_SH" >&2
    exit 1
  fi
done

# Short, test-tuned window + fast poll so the suite runs in a few seconds.
export LCARS_WORKER_HANG_SECS=3
export LCARS_WORKER_HANG_POLL=1
export LCARS_WORKER_HANG_CPU_MIN=2

# === A. a HUNG worker (sleeps, 0% CPU, writes nothing) is KILLED + reaped ====
# Fake worker = a REAL executable (perl exec needs one): spawns a GRANDCHILD
# that also just sleeps (a TREE, like a real nested worker), writes NOTHING to
# .worker.out/.err, then sleeps long. CPU ~0, no output growth → HUNG.
A_OUT="$TMPROOT/a"; mkdir -p "$A_OUT"
A_GC="$TMPROOT/a.gc.pid"
HUNG="$TMPROOT/hung.sh"
cat >"$HUNG" <<EOF
#!/usr/bin/env bash
sleep 300 &
echo \$! >"$A_GC"
sleep 300
EOF
chmod +x "$HUNG"

rm -f "$A_GC"
t0=$(date +%s)
run_worker_hang_guarded "$A_OUT" "$HUNG"
rc=$?
t1=$(date +%s)
sleep 1   # let group-kill grace + reaping settle
gc="$(cat "$A_GC" 2>/dev/null || true)"
elapsed=$((t1 - t0))

if [ "$rc" -eq 137 ]; then
  ok "A1. hung worker returns the HUNG sentinel (137)"
else
  bad "A1. hung worker sentinel (expected 137, got $rc)"
fi
if [ "$elapsed" -lt 12 ]; then
  ok "A2. hung worker killed promptly after the window (${elapsed}s)"
else
  bad "A2. hung worker took too long to kill (${elapsed}s)"
fi
if [ -n "$gc" ] && ! pid_alive "$gc"; then
  ok "A3. grandchild ($gc) is DEAD (whole process group reaped)"
else
  bad "A3. grandchild ($gc) survived — group NOT reaped"
  [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
fi

# === B. a WORKING worker (keeps appending output) is NOT killed =============
# Appends to .worker.out every second for ~6s (> the 3s window), THEN exits 0.
# Output keeps growing, so the stagnation timer never reaches the window.
B_OUT="$TMPROOT/b"; mkdir -p "$B_OUT"
WORKING="$TMPROOT/working.sh"
cat >"$WORKING" <<'EOF'
#!/usr/bin/env bash
# $LCARS_WORK_OUT is exported by the guard; fall back to argv if absent.
out="${LCARS_WORK_OUT:-$1}/.worker.out"
for i in 1 2 3 4 5 6; do
  printf 'progress %s\n' "$i" >>"$out"
  sleep 1
done
exit 0
EOF
chmod +x "$WORKING"

t0=$(date +%s)
run_worker_hang_guarded "$B_OUT" "$WORKING" "$B_OUT"
rc=$?
t1=$(date +%s)
elapsed=$((t1 - t0))

if [ "$rc" -eq 0 ]; then
  ok "B1. working worker runs to completion, returns its real rc (0)"
else
  bad "B1. working worker rc (expected 0, got $rc) — was it killed?"
fi
if [ "$elapsed" -ge 5 ]; then
  ok "B2. working worker ran the full ~6s (not killed early at ${elapsed}s)"
else
  bad "B2. working worker exited too early (${elapsed}s) — likely killed"
fi

# === C. stagnation timer RESETS on output growth ============================
# Quiet for ~2s (under the 3s window), then produces output, then quiet ~2s,
# then exits 0. Each quiet stretch is < the window, and the burst between them
# resets the timer, so it must SURVIVE. A non-resetting timer would kill it.
C_OUT="$TMPROOT/c"; mkdir -p "$C_OUT"
QUIET_BURST="$TMPROOT/quietburst.sh"
cat >"$QUIET_BURST" <<'EOF'
#!/usr/bin/env bash
out="${LCARS_WORK_OUT:-$1}/.worker.out"
sleep 2
printf 'burst\n' >>"$out"
sleep 2
exit 0
EOF
chmod +x "$QUIET_BURST"

run_worker_hang_guarded "$C_OUT" "$QUIET_BURST" "$C_OUT"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "C. timer resets on output growth — quiet/burst/quiet worker survives (rc 0)"
else
  bad "C. quiet/burst/quiet worker was killed (rc=$rc) — timer did not reset"
fi

# === D. LCARS_WORKER_HANG_SECS=0 DISABLES the guard ========================
# A would-be-hung worker that simply exits 9 quickly must round-trip its rc with
# the guard disabled (no kill, no sentinel).
D_OUT="$TMPROOT/d"; mkdir -p "$D_OUT"
RC9="$TMPROOT/rc9.sh"; printf '#!/usr/bin/env bash\nsleep 1\nexit 9\n' >"$RC9"; chmod +x "$RC9"
LCARS_WORKER_HANG_SECS=0 run_worker_hang_guarded "$D_OUT" "$RC9"
rc=$?
if [ "$rc" -eq 9 ]; then
  ok "D. HANG_SECS=0 disables the guard — worker runs unguarded, rc 9 round-trips"
else
  bad "D. HANG_SECS=0 disabled-guard rc (expected 9, got $rc)"
fi

# === E. a worker that exits CLEANLY before the window returns its rc =========
E_OUT="$TMPROOT/e"; mkdir -p "$E_OUT"
RC0="$TMPROOT/rc0.sh"; printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' >"$RC0"; chmod +x "$RC0"
run_worker_hang_guarded "$E_OUT" "$RC0"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "E. quick clean worker returns rc 0 (not flagged hung)"
else
  bad "E. quick clean worker rc (expected 0, got $rc)"
fi

# --- summary ----------------------------------------------------------------
echo
printf 'worker-hang guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
