#!/usr/bin/env bash
#
# Tests for THE CASCADE KILL (S240 fix round 4, D3).
#
# `xo file-logs` detaches `resolve-logs.sh` — a chain that files issues, cuts
# branches and runs a worker per stage per bug, unattended, for a long time —
# and records its pid in `xo-resolve.pid` so `lcars xo off` can stop it. The
# code claimed `setsid` gave that chain its own process group.
#
# MEASURED REALITY on this machine (ps -o pid,pgid,ppid, not the man page):
#
#   setsid on PATH: ABSENT      ← macOS ships none; the nohup fallback runs
#   LOOK    pid=25669 pgid=25654
#   DRIVER  pid=25680 pgid=25654   ← the LOOK's group, not its own
#   WORKER  pid=25692 pgid=25654   ← same group again
#   xo-resolve.pid: pid=25680 pgid=25654
#
# So the pidfile recorded THE LOOK'S GROUP. Two consequences, both measured:
#   • killing that group by pgid would have killed the look as well;
#   • the product's own guard (`pgid == pid`) therefore correctly declined to
#     kill it — and stopped ONE process. The DRIVER died. THE WORKER DID NOT:
#     "DRIVER gone / WORKER STILL ALIVE".
#
# So one stop verb left a billed worker running with nothing left watching it.
#
# THE CURE recorded here: the chain is started in a session of its OWN —
# `setsid` where there is one, and `os.setsid()` through a shipped two-line
# python shim where there is not (the same syscall, on every machine that has
# python3) — so the recorded pgid is a group the chain genuinely LEADS, and one
# group kill reaches the driver and its worker and nothing else. And where a
# machine has NO way at all, the pidfile records NO pgid rather than a borrowed
# one, because a stop that kills the wrong group is worse than one that admits
# it can only reach the one process.
#
# Usage: bash tests/xo-stop-tree.test.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
KILLME=""
cleanup() { for p in $KILLME; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$TMPROOT"; }
trap cleanup EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

nap() { perl -e 'select(undef,undef,undef,'"$1"')' 2>/dev/null || sleep 1; }

# The chain under test, two deep: a DRIVER that spawns a WORKER and waits.
# Nothing here reaches a network or an engine — the "worker" sleeps.
cat >"$TMPROOT/worker" <<'W'
#!/usr/bin/env bash
printf 'WORKER %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" >>"$CHAINLOG"
sleep 120
W
cat >"$TMPROOT/driver" <<'D'
#!/usr/bin/env bash
printf 'DRIVER %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" >>"$CHAINLOG"
bash "$WORKERBIN" &
wait
D
chmod +x "$TMPROOT/worker" "$TMPROOT/driver"

export WORKERBIN="$TMPROOT/worker"

echo "Number One: the cascade kill"
[ -f "$XO" ] || { echo "script under test not found at $XO"; exit 1; }

# EVERY CHECK BELOW IS GUARDED ON NON-EMPTY. Written loosely, this whole file
# passed VACUOUSLY the first time it ran: the verbs it drives did not exist
# yet, every pid came back as the empty string, and `[ '' = '' ]` is true. Four
# assertions about process groups "passed" without a process group in sight.
# So `nonempty` is in front of every comparison, and the verbs themselves are
# asserted to exist before anything leans on them.
nonempty() { for v in "$@"; do [ -n "$v" ] || return 1; done; return 0; }

# The seams are asserted in the SOURCE, not by running the verb in this repo:
# xo.sh refuses outright in a repo with no .git/lcars, so a runtime probe here
# never reaches the dispatch at all and "no unknown-verb message" passed
# vacuously for a verb that did not exist.
check "0. the product has a detach seam to drive (else everything below is vacuous)" \
  "grep -q '^  detach)' '$XO'"
check "0. the product has a signal-pidfile seam to drive" \
  "grep -q '^  signal-pidfile)' '$XO'"

# ===========================================================================
# 1. THE DETACHED CHAIN LEADS ITS OWN GROUP.
# ===========================================================================
# Driven through the PRODUCT's own `xo detach` seam, which is the exact spawn
# `file_logs_for` makes — not a copy of it beside the product.
CHAINLOG="$TMPROOT/chain1.log"; : >"$CHAINLOG"
export CHAINLOG
PF="$TMPROOT/xo-resolve.pid"
bash "$XO" detach --pidfile "$PF" --log "$TMPROOT/detach1.log" -- bash "$TMPROOT/driver"
i=0; while [ "$i" -lt 100 ] && ! grep -q WORKER "$CHAINLOG" 2>/dev/null; do i=$((i+1)); nap 0.1; done
DPID="$(sed -n 1p "$PF" 2>/dev/null | tr -dc '0-9')"
DPGID="$(sed -n 2p "$PF" 2>/dev/null | tr -dc '0-9')"
WPID="$(sed -n 's/^WORKER \([0-9]*\).*/\1/p' "$CHAINLOG" | head -1)"
WPGID="$(sed -n 's/^WORKER [0-9]* \([0-9]*\)$/\1/p' "$CHAINLOG" | head -1)"
MYPGID="$(ps -o pgid= -p $$ | tr -dc '0-9')"
KILLME="$KILLME $DPID $WPID"

check "1. the chain really came up (a driver and a worker)" \
  "[ -n '$DPID' ] && [ -n '$WPID' ] && kill -0 '$DPID' 2>/dev/null && kill -0 '$WPID' 2>/dev/null"
check "1. the recorded pgid is a group the chain LEADS (pgid == pid; saw $DPGID vs $DPID)" \
  "nonempty '$DPGID' '$DPID' && [ '$DPGID' = '$DPID' ]"
check "1. ...and it is NOT the group of whoever started it (saw $DPGID vs $MYPGID)" \
  "nonempty '$DPGID' '$MYPGID' && [ '$DPGID' != '$MYPGID' ]"
check "1. the WORKER is inside that same group, so one kill can reach it (saw $WPGID)" \
  "nonempty '$WPGID' '$DPGID' && [ '$WPGID' = '$DPGID' ]"

# ===========================================================================
# 2. ONE STOP STOPS THE WHOLE TREE — driver AND worker.
# ===========================================================================
# Through the product's own signaller, the one `lcars xo off` calls.
bash "$XO" signal-pidfile "$PF" || true
k=0; while [ "$k" -lt 60 ] && { kill -0 "$DPID" 2>/dev/null || kill -0 "$WPID" 2>/dev/null; }; do k=$((k+1)); nap 0.1; done
# nonempty FIRST: "a pid that does not exist is not running" is true of the
# empty string too, and that is how a stop test congratulates itself for
# killing nothing.
check "2. one stop killed the DRIVER" \
  "nonempty '$DPID' && ! kill -0 '$DPID' 2>/dev/null"
check "2. one stop killed its WORKER too — the kill that used to be missing" \
  "nonempty '$WPID' && ! kill -0 '$WPID' 2>/dev/null"
check "2. ...and it did NOT kill the process that asked for the stop" \
  "kill -0 $$ 2>/dev/null"

# ===========================================================================
# 3. NO WAY TO MAKE A SESSION? THEN NO BORROWED GROUP IS EVER RECORDED.
# ===========================================================================
# The fallback path is forced by pointing both session-makers at nothing. The
# chain then shares its starter's group — and the pidfile must record NO pgid,
# so no reader can be handed a group that kills the look, the viewscreen, or
# the captain's own shell.
CHAINLOG="$TMPROOT/chain3.log"; : >"$CHAINLOG"
export CHAINLOG
PF3="$TMPROOT/xo-resolve3.pid"
LCARS_XO_SETSID=none \
  bash "$XO" detach --pidfile "$PF3" --log "$TMPROOT/detach3.log" -- bash "$TMPROOT/driver"
i=0; while [ "$i" -lt 100 ] && ! grep -q DRIVER "$CHAINLOG" 2>/dev/null; do i=$((i+1)); nap 0.1; done
D3PID="$(sed -n 1p "$PF3" 2>/dev/null | tr -dc '0-9')"
D3PGID="$(sed -n 2p "$PF3" 2>/dev/null | tr -dc '0-9')"
W3PID="$(sed -n 's/^WORKER \([0-9]*\).*/\1/p' "$CHAINLOG" | head -1)"
KILLME="$KILLME $D3PID $W3PID"
check "3. the fallback chain still starts (a stop verb is never a reason not to run)" \
  "[ -n '$D3PID' ] && kill -0 '$D3PID' 2>/dev/null"
check "3. with no session-maker, the pidfile records NO pgid — never a borrowed one" \
  "nonempty '$D3PID' && [ -z '$D3PGID' ]"
check "3. ...so the recorded pgid can never be this shell's group" \
  "nonempty '$D3PID' '$MYPGID' && [ '$D3PGID' != '$MYPGID' ]"
check "3. ...and the single process is still stoppable by pid" \
  "nonempty '$D3PID' && { bash '$XO' signal-pidfile '$PF3' || true; }; k=0; while [ \$k -lt 60 ] && kill -0 '$D3PID' 2>/dev/null; do k=\$((k+1)); nap 0.1; done; nonempty '$D3PID' && ! kill -0 '$D3PID' 2>/dev/null"

# ===========================================================================
# 4. A pid that is NOT who the file was written about is still left ALONE.
# ===========================================================================
# The S213 identity rule must survive this change: a stop that stops the wrong
# process is worse than one that admits it cannot.
PF4="$TMPROOT/xo-resolve4.pid"
sleep 120 & SAFE=$!
KILLME="$KILLME $SAFE"
printf '%s\n' "$SAFE" >"$PF4"          # a BARE pid: no identity recorded
rc4=0
bash "$XO" signal-pidfile "$PF4" || rc4=$?
nap 0.4
check "4. CONTROL — a pidfile with no identity is refused (rc 2)" "[ '$rc4' -eq 2 ]"
check "4. CONTROL — ...and that process is left strictly alone" \
  "nonempty '$SAFE' && kill -0 '$SAFE' 2>/dev/null"

echo
printf 'Number One cascade kill: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
