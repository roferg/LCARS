#!/usr/bin/env bash
#
# Tests for THE STOP THAT MISSED THE PAID WORKER — and then said it hadn't
# (S240 fix round 5, D1).
#
# `tests/xo-stop-tree.test.sh` proved a cascade kill on a TWO-LEVEL rig whose
# worker sat in the driver's OWN process group. A stop by pgid reaches that.
# THE REAL CHAIN IS NOT THAT SHAPE, and the live measurement says so:
#
#   `lcars xo off <mission>` printed "stood down … you have the conn", exit 0.
#   It killed the driver's group LEADER (30311) and nothing else. Immediately
#   after, `ps -eo pid,ppid,pgid`:
#
#     pid     ppid    pgid    what
#     31634   1       30311   run.sh drive --mission …      ← orphaned to init
#     36323   31634   30311   run.sh validate …
#     36610   36610   36610   worker-adapter.sh spawn copilot …  ← OWN group
#     36662   36610   36610   copilot -p …                  ← THE PAID ASSISTANT
#
#   25 seconds later the surviving driver had advanced a bug align→research→
#   validate→plan and spawned a FRESH paid assistant. And the stop had DELETED
#   `xo-resolve.pid`, so the product had no handle left to try again with. A
#   human killed the tree by hand.
#
# WHY pgid ALONE CAN NEVER REACH IT, and why that is not a bug to "fix" in the
# grouping: `skills/lcars-run/run.sh` DELIBERATELY launches each worker as its
# own process-group leader (`perl -e 'use POSIX qw(setsid); … exec @ARGV'`, at
# run.sh:10000, :20068 and :20221) — that is BUG-048's cure, so nested workers
# that reparent and forked test pools (vitest/jest) cannot outlive a stop. A
# worker is therefore BY DESIGN in a different group from its driver. The stop
# has to find the groups; the groups are not going to come to the stop.
#
# And the ORDER made it worse: killing the driver's group leader FIRST orphaned
# the rest of the chain to ppid 1, so the driver's own teardown never ran and
# its worker was abandoned.
#
# SO THIS RIG IS THE REAL SHAPE, three levels and two groups:
#
#   DRIVER   — group leader, spawned through the product's own `xo detach`
#     └ STAGE  — same group, and ORPHANED TO ppid 1 (its spawning wrapper exits),
#               exactly as 31634 was found
#        └ ADAPTER — made ITSELF a new group leader with the SAME
#                    `perl POSIX::setsid + exec` call run.sh uses
#           └ ASSISTANT — a PATH-shimmed `copilot`, the process that bills
#
# And every claim below is checked against real `ps -eo pid,ppid,pgid` output,
# printed before and after, not against a man page.
#
# Usage: bash tests/xo-stop-real-tree.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"

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

# EVERY PID COMPARISON IS GUARDED ON NON-EMPTY, deliberately and in front.
# The round before this one shipped a probe file that passed VACUOUSLY: the
# verb it drove did not exist, every pid came back as the empty string, and
# `[ '' = '' ]` is true — four assertions about process groups "passed" with no
# process group in sight. `! kill -0 ''` is true too, which is how a stop test
# congratulates itself for killing nothing.
nonempty() { for v in "$@"; do [ -n "$v" ] || return 1; done; return 0; }
pgid_of()  { ps -o pgid= -p "$1" 2>/dev/null | tr -dc '0-9'; }
alive()    { nonempty "${1:-}" && kill -0 "$1" 2>/dev/null; }

# ── ZERO SPEND, PINNED BY A PATH SHIM FAKING BOTH CLIs ─────────────────────
# Never an env var alone: the engine is resolved from three places (a request
# body, $LCARS_WORKER_BIN, and a persisted `state.json` workerBin) and an env
# var has been MEASURED losing to the persisted one. So the names themselves
# are shadowed on PATH. The shim is also the ASSISTANT in the rig — the leaf
# process that, unshimmed, is the one that bills.
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

# ── THE RIG: three levels, two groups, one orphan ──────────────────────────
# The adapter is started with the EXACT perl incantation run.sh uses, so this
# proves against the real grouping and not a convenient one.
cat >"$TMPROOT/adapter" <<'A'
#!/usr/bin/env bash
printf 'ADAPTER %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
# The leaf that bills. Shimmed on PATH; --model so the shim can count it.
copilot -p 'resolve the logged bug' --model some-model
A
cat >"$TMPROOT/stage" <<'S'
#!/usr/bin/env bash
printf 'STAGE %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
# EXACTLY run.sh's worker launch (run.sh:10000, :20068, :20221): the child
# makes itself a session/group leader and then becomes the adapter, so the
# adapter is in a group the DRIVER DOES NOT LEAD.
perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' bash "$ADAPTERBIN" &
wait
S
cat >"$TMPROOT/driver" <<'D'
#!/usr/bin/env bash
printf 'DRIVER %s %s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -dc 0-9)" "$PPID" >>"$CHAINLOG"
# ITS OWN TEARDOWN, and a teardown that ABANDONS ITS WORKER — which is what the
# live driver did. A stop that leans on the driver tidying up after itself must
# still produce a dead tree when the driver does not.
trap 'printf "TEARDOWN %s\n" "$$" >>"$CHAINLOG"; exit 0' TERM
# The stage is spawned through a wrapper that EXITS, so the stage is reparented
# to ppid 1 — the shape `ps` actually found (31634 ppid 1 pgid 30311). After
# this, the stage is NOT reachable by walking ppid down from the driver.
bash -c 'bash "$STAGEBIN" & disown'
sleep 300 &
wait
D
chmod +x "$TMPROOT/adapter" "$TMPROOT/stage" "$TMPROOT/driver"
export ADAPTERBIN="$TMPROOT/adapter" STAGEBIN="$TMPROOT/stage"

# Bring the rig up and report what `ps` says about it.
bring_up() { # <chainlog> <pidfile> → 0 when all four levels are on the table
  CHAINLOG="$1"; : >"$CHAINLOG"; export CHAINLOG
  bash "$XO" detach --pidfile "$2" --log "$TMPROOT/detach.log" -- bash "$TMPROOT/driver"
  local i=0
  while [ "$i" -lt 150 ] && ! grep -q ASSISTANT "$CHAINLOG" 2>/dev/null; do
    i=$((i + 1)); nap 0.1
  done
  grep -q ASSISTANT "$CHAINLOG" 2>/dev/null
}
field() { # <chainlog> <LABEL> <col 1=pid 2=pgid 3=ppid>
  awk -v l="$2" -v c="$3" '$1 == l { print $(c + 1); exit }' "$1"
}
snap() { # <pids…> — real ps output for exactly these pids
  local p list=""
  for p in "$@"; do [ -n "$p" ] && list="$list -p $p"; done
  [ -n "$list" ] || { echo "    (no pids to show)"; return 0; }
  # shellcheck disable=SC2086
  ps -o pid=,ppid=,pgid=,comm= $list 2>/dev/null | sed 's/^/    /'
}

echo "Number One: the stop that has to cross a process group"
[ -f "$XO" ] || { echo "script under test not found at $XO"; exit 1; }

check "0. the product has a detach seam to drive (else everything below is vacuous)" \
  "grep -q '^  detach)' '$XO'"
check "0. the product has a signal-pidfile seam to drive" \
  "grep -q '^  signal-pidfile)' '$XO'"
check "0. both engine names are shimmed on PATH, so nothing here can bill" \
  "[ -x '$SHIMBIN/claude' ] && [ -x '$SHIMBIN/copilot' ] && [ \"\$(command -v copilot)\" = '$SHIMBIN/copilot' ] && [ \"\$(command -v claude)\" = '$SHIMBIN/claude' ]"

# ===========================================================================
# 1. THE RIG IS THE REAL SHAPE — three levels, TWO groups, one orphan.
# ===========================================================================
CL="$TMPROOT/chain1.log"
PF="$TMPROOT/xo-resolve.pid"
UP=1; bring_up "$CL" "$PF" || UP=0
DPID="$(sed -n 1p "$PF" 2>/dev/null | tr -dc '0-9')"
DPGID="$(sed -n 2p "$PF" 2>/dev/null | tr -dc '0-9')"
SPID="$(field "$CL" STAGE 1)";     SPGID="$(field "$CL" STAGE 2)"
APID="$(field "$CL" ADAPTER 1)";   APGID="$(field "$CL" ADAPTER 2)"
WPID="$(field "$CL" ASSISTANT 1)"; WPGID="$(field "$CL" ASSISTANT 2)"
KILLME="$KILLME $DPID $SPID $APID $WPID"
SPPID_NOW="$(ps -o ppid= -p "${SPID:-0}" 2>/dev/null | tr -dc '0-9')"
MYPGID="$(pgid_of $$)"

echo "  --- BEFORE (real ps -o pid,ppid,pgid) ---"
snap "$DPID" "$SPID" "$APID" "$WPID"
printf '    xo-resolve.pid: pid=%s pgid=%s   this shell: pid=%s pgid=%s\n' \
  "${DPID:-?}" "${DPGID:-?}" "$$" "${MYPGID:-?}"

check "1. all four levels came up and are alive" \
  "[ '$UP' -eq 1 ] && alive '$DPID' && alive '$SPID' && alive '$APID' && alive '$WPID'"
check "1. the DRIVER leads the group the pidfile recorded (saw $DPGID vs $DPID)" \
  "nonempty '$DPGID' '$DPID' && [ '$DPGID' = '$DPID' ]"
check "1. the STAGE is in the driver's group (saw $SPGID)" \
  "nonempty '$SPGID' '$DPGID' && [ '$SPGID' = '$DPGID' ]"
check "1. ...and the STAGE is ORPHANED to ppid 1, as ps found it live (saw $SPPID_NOW)" \
  "nonempty '$SPPID_NOW' && [ '$SPPID_NOW' = '1' ]"
check "1. the ADAPTER leads a group OF ITS OWN (saw $APGID vs $APID)" \
  "nonempty '$APGID' '$APID' && [ '$APGID' = '$APID' ]"
check "1. ...which is NOT the driver's group — this is what pgid alone cannot reach" \
  "nonempty '$APGID' '$DPGID' && [ '$APGID' != '$DPGID' ]"
check "1. the ASSISTANT (the billing leaf) is in the adapter's group, not the driver's" \
  "nonempty '$WPGID' '$APGID' '$DPGID' && [ '$WPGID' = '$APGID' ] && [ '$WPGID' != '$DPGID' ]"
check "1. ...and no part of the rig shares this shell's group" \
  "nonempty '$MYPGID' '$DPGID' '$APGID' && [ '$DPGID' != '$MYPGID' ] && [ '$APGID' != '$MYPGID' ]"

# ===========================================================================
# 2. ONE STOP KILLS ALL OF IT — including across the group boundary.
# ===========================================================================
rc2=0
bash "$XO" signal-pidfile "$PF" >"$TMPROOT/stop1.out" 2>&1 || rc2=$?
k=0
while [ "$k" -lt 100 ] && { alive "$DPID" || alive "$SPID" || alive "$APID" || alive "$WPID"; }; do
  k=$((k + 1)); nap 0.1
done
echo "  --- AFTER (real ps -o pid,ppid,pgid; empty means gone) ---"
snap "$DPID" "$SPID" "$APID" "$WPID"
sed 's/^/    /' "$TMPROOT/stop1.out"

check "2. the DRIVER is gone" "nonempty '$DPID' && ! kill -0 '$DPID' 2>/dev/null"
check "2. the STAGE is gone — the orphan at ppid 1" \
  "nonempty '$SPID' && ! kill -0 '$SPID' 2>/dev/null"
check "2. the ADAPTER is gone — a leader of a group the driver never led" \
  "nonempty '$APID' && ! kill -0 '$APID' 2>/dev/null"
check "2. THE PAID ASSISTANT IS GONE — the kill that was missing live" \
  "nonempty '$WPID' && ! kill -0 '$WPID' 2>/dev/null"
check "2. the stop reports success only because it confirmed it (rc 0)" "[ '$rc2' -eq 0 ]"
check "2. the DRIVER was given a gentle TERM first, so its own teardown ran" \
  "grep -q '^TEARDOWN ' '$CL'"
check "2. ...and this shell, which asked for the stop, is untouched" "kill -0 $$ 2>/dev/null"
check "2. ...as is its process group" \
  "nonempty '$MYPGID' && [ \"\$(pgid_of $$)\" = '$MYPGID' ]"

# ===========================================================================
# 3. A STOP THAT CANNOT CONFIRM DEATH MUST NOT CLAIM IT.
# ===========================================================================
# The signals are sent through `$LCARS_XO_KILL_BIN`, defaulting to the shell's
# own `kill`. Pointed at a no-op, every signal is swallowed and the rig stays
# GENUINELY ALIVE — real pids, on the real process table. The liveness checks
# are NOT stubbed, so this measures whether the product actually re-reads the
# table before it speaks. Nothing here is a mock of a process.
cat >"$TMPROOT/nokill" <<'NK'
#!/usr/bin/env bash
exit 0
NK
chmod +x "$TMPROOT/nokill"

CL3="$TMPROOT/chain3.log"
PF3="$TMPROOT/xo-resolve3.pid"
UP3=1; bring_up "$CL3" "$PF3" || UP3=0
D3="$(sed -n 1p "$PF3" 2>/dev/null | tr -dc '0-9')"
S3="$(field "$CL3" STAGE 1)"
A3="$(field "$CL3" ADAPTER 1)"
W3="$(field "$CL3" ASSISTANT 1)"
KILLME="$KILLME $D3 $S3 $A3 $W3"

check "3. CONTROL — the rig came up again, all four alive" \
  "[ '$UP3' -eq 1 ] && alive '$D3' && alive '$S3' && alive '$A3' && alive '$W3'"
check "3. the product routes its signals through an overridable kill seam" \
  "grep -q 'LCARS_XO_KILL_BIN' '$XO'"

rc3=0
LCARS_XO_KILL_BIN="$TMPROOT/nokill" \
  bash "$XO" signal-pidfile "$PF3" >"$TMPROOT/stop3.out" 2>&1 || rc3=$?
echo "  --- AFTER A SWALLOWED STOP (everything must still be here) ---"
snap "$D3" "$S3" "$A3" "$W3"
sed 's/^/    /' "$TMPROOT/stop3.out"

check "3. CONTROL — nothing died, so there is something to lie about" \
  "alive '$D3' && alive '$W3'"
check "3. the stop refuses to report success it did not confirm (rc != 0, != 1)" \
  "[ '$rc3' -ne 0 ] && [ '$rc3' -ne 1 ]"
check "3. it names the survivors by pid, so the captain can act" \
  "nonempty '$W3' && grep -q '$W3' '$TMPROOT/stop3.out'"
check "3. THE HANDLE IS NOT DROPPED — the pidfile survives a failed stop" \
  "[ -s '$PF3' ] && [ \"\$(sed -n 1p '$PF3' | tr -dc 0-9)\" = '$D3' ]"
for p in $D3 $S3 $A3 $W3; do kill -9 "$p" 2>/dev/null || true; done

# ===========================================================================
# 4. THE SAME, THROUGH THE CAPTAIN'S OWN VERB: `lcars xo off <mission>`.
# ===========================================================================
# The defect's whole cost was the SENTENCE, not the signal: "stood down on
# <mission> — you have the conn", exit 0, over a live paid assistant. So the
# verb itself is driven here, in a real repo fixture, with the signals
# swallowed — and it must not say that.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/lcars-20261003-001/xo"
  {
    printf '{\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "testCommand": "true",\n'
    printf '  "numberOne": {"enabled": true, "engine": "claude"},\n'
    printf '  "created": "2026-10-03T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  {
    printf '{\n'
    printf '  "id": "lcars-20261003-001",\n'
    printf '  "type": "feature",\n'
    printf '  "title": "A build to look at",\n'
    printf '  "stage": "verify",\n'
    printf '  "created": "2026-10-03T00:00:00Z",\n'
    printf '  "githubIssue": 7,\n'
    printf '  "branch": "lcars/lcars-20261003-001",\n'
    printf '  "base": "main",\n'
    printf '  "numberOne": {"status": "engaged", "note": "looking"},\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e"\n'
    printf '}\n'
  } >"$repo/.git/lcars/missions/lcars-20261003-001/state.json"
  printf '{"logs": [{"mission": "lcars-20261003-002"}]}\n' \
    >"$repo/.git/lcars/missions/lcars-20261003-001/xo/logs.json"
  echo "$repo"
}
repo4="$(new_repo)"
MDIR="$repo4/.git/lcars/missions/lcars-20261003-001"
CL4="$TMPROOT/chain4.log"
UP4=1; bring_up "$CL4" "$MDIR/xo-resolve.pid" || UP4=0
D4="$(sed -n 1p "$MDIR/xo-resolve.pid" 2>/dev/null | tr -dc '0-9')"
S4="$(field "$CL4" STAGE 1)"
A4="$(field "$CL4" ADAPTER 1)"
W4="$(field "$CL4" ASSISTANT 1)"
KILLME="$KILLME $D4 $S4 $A4 $W4"

rc4=0
( cd "$repo4" && LCARS_XO_KILL_BIN="$TMPROOT/nokill" \
    bash "$XO" off lcars-20261003-001 ) >"$TMPROOT/off4.out" 2>&1 || rc4=$?
echo "  --- \`lcars xo off\` WITH ITS SIGNALS SWALLOWED ---"
sed 's/^/    /' "$TMPROOT/off4.out"
snap "$D4" "$S4" "$A4" "$W4"

check "4. CONTROL — the rig is up and still alive, so a false claim is possible" \
  "[ '$UP4' -eq 1 ] && alive '$D4' && alive '$W4'"
check "4. it does NOT print the stood-down line over a live tree" \
  "! grep -q 'stood down on' '$TMPROOT/off4.out'"
check "4. it does NOT say the captain has the conn" \
  "! grep -q 'you have the conn' '$TMPROOT/off4.out'"
check "4. it exits NON-ZERO" "[ '$rc4' -ne 0 ]"
check "4. it names a surviving pid" \
  "nonempty '$D4' && grep -q '$D4' '$TMPROOT/off4.out'"
check "4. IT KEEPS THE HANDLE — xo-resolve.pid is not deleted by a failed stop" \
  "[ -s '$MDIR/xo-resolve.pid' ]"
check "4. ...and the recorded note does not claim the conn either" \
  "! grep -q 'you have the conn' '$MDIR/state.json'"

# And with the seam back to the real `kill`, the same verb finishes the job and
# only then says so. SECOND TRY ON THE SAME HANDLE — which the live defect had
# made impossible.
rc5=0
( cd "$repo4" && bash "$XO" off lcars-20261003-001 ) >"$TMPROOT/off5.out" 2>&1 || rc5=$?
k=0
while [ "$k" -lt 100 ] && { alive "$D4" || alive "$S4" || alive "$A4" || alive "$W4"; }; do
  k=$((k + 1)); nap 0.1
done
echo "  --- THE SECOND TRY, with signals real ---"
sed 's/^/    /' "$TMPROOT/off5.out"
snap "$D4" "$S4" "$A4" "$W4"
check "5. the kept handle let the captain try again, and it worked (rc 0)" \
  "[ '$rc5' -eq 0 ]"
check "5. the whole tree is gone, paid assistant included" \
  "nonempty '$D4' '$S4' '$A4' '$W4' && ! kill -0 '$D4' 2>/dev/null && ! kill -0 '$S4' 2>/dev/null && ! kill -0 '$A4' 2>/dev/null && ! kill -0 '$W4' 2>/dev/null"
check "5. ...and only NOW does it say the conn is the captain's" \
  "grep -q 'you have the conn' '$TMPROOT/off5.out'"
check "5. ...and only now is the handle released" \
  "[ ! -f '$MDIR/xo-resolve.pid' ]"

# ===========================================================================
# 7. THE OTHER HALF OF THE RULE: IT MUST NOT KILL THE WRONG THING.
# ===========================================================================
# A stop that enumerates process groups is one bad expansion away from taking
# out the look that started the job, the captain's shell, and the viewscreen
# above it. So the dangerous case is driven directly: a recorded pid that sits
# in the ASKER'S OWN process group (the no-session-maker fallback), with a
# BYSTANDER beside it in that same group standing in for the look. The
# bystander must live.
sleep 300 & TPID=$!
sleep 300 & BYST=$!
KILLME="$KILLME $TPID $BYST"
PF7="$TMPROOT/xo-resolve7.pid"
bash "$XO" record-pid "$TPID" "$PF7"
T7PGID="$(pgid_of "$TPID")"; B7PGID="$(pgid_of "$BYST")"
P7GROUP="$(sed -n 2p "$PF7" 2>/dev/null | tr -dc '0-9')"
check "7. CONTROL — the target and the bystander really do share one group, and it is this shell's" \
  "nonempty '$T7PGID' '$B7PGID' '$MYPGID' && [ '$T7PGID' = '$B7PGID' ] && [ '$T7PGID' = '$MYPGID' ]"
check "7. CONTROL — and the pidfile therefore records NO group (never a borrowed one)" \
  "[ -z '$P7GROUP' ]"
rc7=0
bash "$XO" signal-pidfile "$PF7" >"$TMPROOT/stop7.out" 2>&1 || rc7=$?
k=0; while [ "$k" -lt 60 ] && alive "$TPID"; do k=$((k + 1)); nap 0.1; done
check "7. the recorded process itself is stopped (rc 0)" \
  "[ '$rc7' -eq 0 ] && nonempty '$TPID' && ! kill -0 '$TPID' 2>/dev/null"
check "7. THE BYSTANDER IN THAT GROUP LIVES — the look is not collateral" \
  "alive '$BYST'"
check "7. ...and so does the shell that asked" "kill -0 $$ 2>/dev/null"
kill -9 "$BYST" 2>/dev/null || true

# ===========================================================================
# 8. THE DEAD RECORDED LEADER (S245) — on THIS rig, with NO mission in scope.
# ===========================================================================
# The gate this suite shipped with polled a set it built by walking DOWN from the
# recorded pid. That walk is sound until the stop works: kill the recorded root
# and every later walk returns NOTHING, so the poll reads empty and the stop says
# it is done. It did not FAIL — it passed VACUOUSLY, and that is how a live stop
# reported AFTER_COUNT=0 over two billable processes.
#
# So the state is driven directly: the recorded leader is killed BY HAND, leaving
# its group orphaned at ppid 1 with the adapter and the paid assistant alive under
# it. The control is the walk itself — `xo-tree.py closure` from that dead pid must
# report nothing — and then the product must stop the tree anyway and only then
# say so.
#
# AND NOTHING IN THIS RIG NAMES A MISSION. Its argv is `bash /tmp/…/driver`, and
# the leaf is a bare `copilot -p …`. So this is the case the provenance half of
# the census CANNOT see, and it is here deliberately: the stop has to work from
# the RECORDED pid file alone, through the one verb that takes nothing else.
CL8="$TMPROOT/chain8.log"
PF8="$TMPROOT/xo-resolve8.pid"
UP8=1; bring_up "$CL8" "$PF8" || UP8=0
D8="$(sed -n 1p "$PF8" 2>/dev/null | tr -dc '0-9')"
G8="$(sed -n 2p "$PF8" 2>/dev/null | tr -dc '0-9')"
S8="$(field "$CL8" STAGE 1)"
A8="$(field "$CL8" ADAPTER 1)"
W8="$(field "$CL8" ASSISTANT 1)"
KILLME="$KILLME $D8 $S8 $A8 $W8"
check "8. CONTROL — the rig is up, four levels, and the pidfile records the group" \
  "[ '$UP8' -eq 1 ] && alive '$D8' && alive '$S8' && alive '$A8' && alive '$W8' && nonempty '$G8' '$D8' && [ '$G8' = '$D8' ]"

kill -9 "$D8" 2>/dev/null || true
k=0; while [ "$k" -lt 50 ] && alive "$D8"; do k=$((k + 1)); nap 0.1; done
WALK8="$(python3 "$REPO_ROOT/skills/lcars-xo/xo-tree.py" closure "${D8:-0}" "${G8:-0}" "$$" 2>/dev/null \
          | sed -n 's/^PID //p' | grep -c . | tr -d ' ')"
WALK8="${WALK8:-0}"
echo "  --- the recorded leader killed by hand: what is left, and what the walk sees ---"
snap "$S8" "$A8" "$W8"
printf '    closure rooted at the dead pid %s: %s pid(s)\n' "${D8:-?}" "$WALK8"
check "8. CONTROL — the orphan, the adapter and the PAID ASSISTANT are still alive" \
  "alive '$S8' && alive '$A8' && alive '$W8'"
check "8. CONTROL — and the walk from the dead root reports NOTHING (the vacuous pass)" \
  "[ '$WALK8' -eq 0 ]"
check "8. CONTROL — but the orphaned group is still REACHABLE, which is the proof it is there" \
  "nonempty '$G8' && kill -0 \"-\$G8\" 2>/dev/null"

rc8=0
bash "$XO" signal-pidfile "$PF8" >"$TMPROOT/stop8.out" 2>&1 || rc8=$?
k=0
while [ "$k" -lt 100 ] && { alive "$S8" || alive "$A8" || alive "$W8"; }; do
  k=$((k + 1)); nap 0.1
done
echo "  --- after the stop ---"
snap "$S8" "$A8" "$W8"
sed 's/^/    /' "$TMPROOT/stop8.out"
check "8. the stop reaches the orphaned group anyway — the stage is gone" \
  "nonempty '$S8' && ! kill -0 '$S8' 2>/dev/null"
check "8. ...the self-led adapter is gone" \
  "nonempty '$A8' && ! kill -0 '$A8' 2>/dev/null"
check "8. ...AND THE PAID ASSISTANT IS GONE, with its leader already dead" \
  "nonempty '$W8' && ! kill -0 '$W8' 2>/dev/null"
check "8. ...and it does not report 'nothing there' over a tree it had to stop (rc 0)" \
  "[ '$rc8' -eq 0 ]"
check "8. ...and this shell is untouched" "kill -0 $$ 2>/dev/null"

# ===========================================================================
# 6. NOTHING BILLED. The shim is the only engine the rig could have reached.
# ===========================================================================
SHIM_N="$(grep -c . "$SHIM_LOG" 2>/dev/null | tr -d ' ')"; SHIM_N="${SHIM_N:-0}"
SHIM_MODEL="$(grep -c 'yes$' "$SHIM_LOG" 2>/dev/null | tr -d ' ')"; SHIM_MODEL="${SHIM_MODEL:-0}"
printf '  shim invocations: %s (of which carried --model: %s) — real spend: 0\n' \
  "$SHIM_N" "$SHIM_MODEL"
check "6. the shim was the assistant every time the rig came up (>= 4)" \
  "[ '$SHIM_N' -ge 4 ]"
check "6. ...and every one of them carried --model, as a real worker would" \
  "[ '$SHIM_N' -eq '$SHIM_MODEL' ]"

echo
printf 'Number One stop across groups: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
