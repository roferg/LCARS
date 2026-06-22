#!/usr/bin/env bash
#
# Tests for BUG-048 — run_with_watchdog must reap the WHOLE descendant process
# tree on a timeout, portably on macOS/BSD (skill source:
# skills/lcars-run/run.sh `run_with_watchdog` + `pid_alive`).
#
# The old code killed only $cmd_pid + DIRECT children found via GNU
# `ps -o pid= --ppid` — broken on macOS (the flag no-ops → empty kids list, only
# cmd_pid dies) and even on Linux it never reaped deep descendants. The fix runs
# the watched command in its OWN process group (perl POSIX::setsid) and on
# overrun kills the GROUP (kill -TERM/-KILL -$cmd_pid), reaping the full tree.
#
# STANDALONE, STUB-ONLY: drives the extracted functions with FAKE child trees
# made of `sleep` ONLY — NO model workers, NO gh, NO network, ZERO tokens. Safe
# to run directly. Do NOT route this through tests/run.sh.
#
# NB: run_with_watchdog launches via `perl ... exec @ARGV`, so the watched
# command must be a REAL executable (the production callers pass a worker binary,
# never a shell function). The fakes here are therefore real `sleep`-only scripts.
#
# Usage: bash tests/lcars-watchdog.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# --- extract the functions under test (mirror lcars-reconcile.test.sh) -------
WD_LIB="$TMPROOT/watchdog.lib.sh"
sed -n '/^pid_alive() {/,/^}/p'          "$RUN_SH" >"$WD_LIB"
sed -n '/^run_with_watchdog() {/,/^}/p'  "$RUN_SH" >>"$WD_LIB"
# shellcheck source=/dev/null
. "$WD_LIB"

if ! type run_with_watchdog >/dev/null 2>&1 || ! type pid_alive >/dev/null 2>&1; then
  echo "FATAL: could not extract run_with_watchdog / pid_alive from $RUN_SH" >&2
  exit 1
fi

GC_PIDF="$TMPROOT/grandchild.pid"

# A FAKE stage as a REAL executable: spawn a GRANDCHILD then sleep — a process
# TREE, all `sleep`, NO model worker. The grandchild reparents/orphans the way
# real nested workers do, so it dies only if the WHOLE group is reaped (not just
# the direct child). Mirrors run.sh → ... → worker shape with plain sleeps.
TREE="$TMPROOT/fake_tree.sh"
cat >"$TREE" <<EOF
#!/usr/bin/env bash
sleep 300 &
echo \$! >"$GC_PIDF"
sleep 300
EOF
chmod +x "$TREE"

# Real executables for the rc / under-budget fast paths.
RC42="$TMPROOT/rc42.sh"; printf '#!/usr/bin/env bash\nexit 42\n' >"$RC42"; chmod +x "$RC42"
QUICK7="$TMPROOT/quick7.sh"; printf '#!/usr/bin/env bash\nsleep 1\nexit 7\n' >"$QUICK7"; chmod +x "$QUICK7"
QUICK0="$TMPROOT/quick0.sh"; printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' >"$QUICK0"; chmod +x "$QUICK0"

# === A/B. timeout reaps the WHOLE tree (child AND grandchild) ===============
rm -f "$GC_PIDF"
run_with_watchdog 2 "$TREE"
rc=$?
sleep 1   # let the group-kill grace + reaping settle
gc="$(cat "$GC_PIDF" 2>/dev/null || true)"

if [ "$rc" -eq 124 ]; then
  ok "A. overrun returns 124 (timeout sentinel)"
else
  bad "A. overrun returns 124 (got rc=$rc)"
fi

if [ -n "$gc" ] && ! pid_alive "$gc"; then
  ok "B. grandchild ($gc) is DEAD after timeout (whole group reaped)"
else
  bad "B. grandchild ($gc) survived the watchdog timeout (group NOT reaped)"
  [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
fi

# === C. fast path: secs<=0 runs inline, returns the command's real rc =======
run_with_watchdog 0 "$RC42"
rc=$?
if [ "$rc" -eq 42 ]; then
  ok "C. secs=0 runs inline and returns the command rc (42)"
else
  bad "C. secs=0 inline rc (expected 42, got $rc)"
fi

# === D. command that finishes BEFORE the budget returns its real rc =========
run_with_watchdog 10 "$QUICK7"
rc=$?
if [ "$rc" -eq 7 ]; then
  ok "D. command under budget returns its real rc (7), not killed"
else
  bad "D. under-budget rc (expected 7, got $rc)"
fi

# === E. a quick SUCCESS also round-trips (rc 0) ============================
run_with_watchdog 10 "$QUICK0"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "E. successful under-budget command returns rc 0"
else
  bad "E. under-budget success rc (expected 0, got $rc)"
fi

# --- summary ----------------------------------------------------------------
echo
printf 'watchdog: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
