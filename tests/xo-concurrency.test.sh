#!/usr/bin/env bash
#
# Tests for NUMBER ONE'S MUTUAL EXCLUSION on one mission (S240 fix round 4, D1).
#
# THE DEFECT, MEASURED on a live mission 2026-10-02: two Number One looks ran
# CONCURRENTLY against ONE mission with nothing stopping them. `xo.pid` was
# empty throughout; both wrote the same `xo/` directory; `number-one.jsonl` was
# interleaved; and the SECOND look overwrote `verdict.json` and `report.md`
# AFTER the first had already filed bugs from its own verdict. So the record
# the captain reads is not the record the bugs were filed from, and nothing in
# the product refused, warned, or noticed.
#
# THE PROOF SURFACE IS REAL CONCURRENCY. A test that calls a function twice in
# sequence proves nothing about a race: a sequential second call sees a
# completed first one. So every check below starts TWO GENUINELY CONCURRENT
# OS PROCESSES against one mission directory and asserts exactly one wins.
#
# The claim is taken through the product's own non-captain-facing `xo claim`
# verb, which is the SAME `xo_claim_or_die` call `evaluate` and `answer` make —
# not a copy of it beside the product.
#
# Usage: bash tests/xo-concurrency.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ZERO SPEND, PINNED BY A PATH SHIM FAKING BOTH CLIs — never an env var alone.
# The engine arrives from three places (a request body, $LCARS_WORKER_BIN, and a
# persisted state.json workerBin) with a different winner per path, and an env
# var has been measured LOSING to a persisted workerBin. Anything that reaches
# for an engine here finds a shim that writes a line and exits.
SHIMBIN="$TMPROOT/shimbin"; mkdir -p "$SHIMBIN"
SHIM_LOG="$TMPROOT/shim.log"; : >"$SHIM_LOG"
for n in claude copilot; do
  cat >"$SHIMBIN/$n" <<SHIM
#!/usr/bin/env bash
m=no
for a in "\$@"; do case "\$a" in --model|--model=*) m=yes ;; esac; done
printf '%s\t%s\n' "$n" "\$m" >>"$SHIM_LOG"
exit 0
SHIM
  chmod +x "$SHIMBIN/$n"
done
export PATH="$SHIMBIN:$PATH"

new_repo() { # → repo path, with one mission at verify
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/lcars-20261002-001/xo"
  # THE SHAPE A REAL config.json HAS — one key per line, matching what
  # `lcars init` writes and what tests/lcars-drive-xo.test.sh plants. A
  # fixture crammed onto one line is rewritten by
  # `lcars_config_set_or_add_raw` into `{ "numberOne": {...}` with its other
  # keys AND its closing brace gone, which silently turns `cfg_enabled` false
  # and made the "nothing was swept" check below pass VACUOUSLY at baseline.
  {
    printf '{\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "testCommand": "true",\n'
    printf '  "numberOne": {"enabled": true, "engine": "claude"},\n'
    printf '  "created": "2026-10-02T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$repo/.git/lcars/config.json" || { echo "FIXTURE CONFIG IS NOT VALID JSON"; exit 1; }
  {
    printf '{\n'
    printf '  "id": "lcars-20261002-001",\n'
    printf '  "type": "feature",\n'
    printf '  "title": "A build to look at",\n'
    printf '  "stage": "verify",\n'
    printf '  "created": "2026-10-02T00:00:00Z",\n'
    printf '  "githubIssue": 7,\n'
    printf '  "branch": "lcars/lcars-20261002-001",\n'
    printf '  "base": "main",\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e"\n'
    printf '}\n'
  } >"$repo/.git/lcars/missions/lcars-20261002-001/state.json"
  echo "$repo"
}

MISSION=lcars-20261002-001

echo "Number One: mutual exclusion (real concurrency)"
[ -f "$XO" ] || { echo "script under test not found at $XO"; exit 1; }

# ===========================================================================
# 1. TWO CONCURRENT CLAIMS: exactly one wins, the other REFUSES.
# ===========================================================================
# Both processes are started from one shell with `&` and then waited on, so
# their claims genuinely overlap: the winner holds the claim for 4 seconds,
# which is far longer than the loser takes to read it.
repo1="$(new_repo)"
A="$repo1/a.out"; B="$repo1/b.out"; : >"$A"; : >"$B"
(
  cd "$repo1"
  bash "$XO" claim --mission "$MISSION" --hold 4 >"$A" 2>&1 &
  p1=$!
  bash "$XO" claim --mission "$MISSION" --hold 4 >"$B" 2>&1 &
  p2=$!
  wait $p1; echo "$?" >"$repo1/rc.a"
  wait $p2; echo "$?" >"$repo1/rc.b"
)
RCA="$(cat "$repo1/rc.a" 2>/dev/null || echo 99)"
RCB="$(cat "$repo1/rc.b" 2>/dev/null || echo 99)"
WON="$(grep -l 'CLAIMED' "$A" "$B" 2>/dev/null | grep -c . | tr -d ' ')"
LOST="$(grep -L 'CLAIMED' "$A" "$B" 2>/dev/null | grep -c . | tr -d ' ')"
ZEROES=0
[ "$RCA" -eq 0 ] 2>/dev/null && ZEROES=$((ZEROES + 1))
[ "$RCB" -eq 0 ] 2>/dev/null && ZEROES=$((ZEROES + 1))
check "1. exactly ONE of two concurrent looks takes the mission" "[ '$WON' -eq 1 ]"
check "1. the other one does NOT take it" "[ '$LOST' -eq 1 ]"
check "1. exactly one of the two exits zero; the other refuses non-zero" \
  "[ '$ZEROES' -eq 1 ]"
check "1. the refusal is ONE plain line naming the look already running" \
  "cat '$A' '$B' | grep -qi 'already looking at' && cat '$A' '$B' | grep -q '$MISSION'"
check "1. the refusal says how to clear it (lcars xo off)" \
  "cat '$A' '$B' | grep -q 'lcars xo off'"
check "1. the refusal never pretends it looked" \
  "[ \"\$(cat '$A' '$B' | grep -c 'CLAIMED')\" -eq 1 ]"
check "1. nothing billed — no shim invocation carried a --model" \
  "[ \"\$(awk -F'\t' '\$2==\"yes\"{n++} END{print n+0}' '$SHIM_LOG')\" -eq 0 ]"

# ===========================================================================
# 2. TEN CONCURRENT CLAIMS: still exactly one. One winner is not luck.
# ===========================================================================
repo2="$(new_repo)"
(
  cd "$repo2"
  i=1
  while [ "$i" -le 10 ]; do
    bash "$XO" claim --mission "$MISSION" --hold 3 >"$repo2/o.$i" 2>&1 &
    i=$((i + 1))
  done
  wait
)
W2="$(grep -l 'CLAIMED' "$repo2"/o.* 2>/dev/null | grep -c .)"
check "2. ten concurrent looks: exactly one wins" "[ '$W2' -eq 1 ]"
check "2. ten concurrent looks: the other nine all refuse by name" \
  "[ \"\$(cat '$repo2'/o.* | grep -ci 'already looking at')\" -eq 9 ]"

# ===========================================================================
# 3. A STALE CLAIM MUST NOT DEADLOCK THE MISSION.
# ===========================================================================
# A look killed outright (a laptop asleep, a SIGKILL, a crashed session) leaves
# its claim on disk with nothing behind it. That must be RECLAIMABLE: a dead
# owner is not an owner. Proven by claiming, KILL -9ing the holder so no trap
# can clean up, then claiming again.
repo3="$(new_repo)"
(
  cd "$repo3"
  bash "$XO" claim --mission "$MISSION" --hold 30 >"$repo3/held" 2>&1 &
  echo $! >"$repo3/holder.pid"
  # wait for the claim to be visibly taken, then kill it dead
  n=0
  while [ "$n" -lt 50 ] && ! grep -q CLAIMED "$repo3/held" 2>/dev/null; do
    n=$((n + 1)); perl -e 'select(undef,undef,undef,0.1)' 2>/dev/null || true
  done
)
HOLDER="$(cat "$repo3/holder.pid" 2>/dev/null)"
check "3. the first claim was really taken before we killed it" \
  "grep -q CLAIMED '$repo3/held'"
kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
CLAIMDIR="$repo3/.git/lcars/missions/$MISSION/xo.claim"
check "3. a KILL -9 leaves the claim behind on disk (nothing could clean up)" \
  "[ -e '$CLAIMDIR' ]"
rc3=0
( cd "$repo3" && bash "$XO" claim --mission "$MISSION" --hold 0 >"$repo3/after" 2>&1 ) || rc3=$?
check "3. a dead owner's claim is RECLAIMED, not a deadlock" \
  "[ '$rc3' -eq 0 ] && grep -q CLAIMED '$repo3/after'"
check "3. ...and it says out loud that it took over a dead look's claim" \
  "grep -qi 'stale' '$repo3/after'"

# ===========================================================================
# 4. THE CLAIM IS RELEASED on a normal finish — one look after another is fine.
# ===========================================================================
repo4="$(new_repo)"
rc4a=0; rc4b=0
( cd "$repo4" && bash "$XO" claim --mission "$MISSION" --hold 0 >"$repo4/one" 2>&1 ) || rc4a=$?
( cd "$repo4" && bash "$XO" claim --mission "$MISSION" --hold 0 >"$repo4/two" 2>&1 ) || rc4b=$?
check "4. a finished look releases its claim (the next one is not refused)" \
  "[ '$rc4a' -eq 0 ] && [ '$rc4b' -eq 0 ]"
check "4. the second look is a clean claim, not a stale takeover" \
  "grep -q CLAIMED '$repo4/two' && ! grep -qi 'stale' '$repo4/two'"

# ===========================================================================
# 5. `xo on --engine <e>` CAN BE ASKED NOT TO SPEND — AND THE DEFAULT IS THE
#    CAPTAIN'S CALL, NOT THIS ROUND'S.
# ===========================================================================
# MEASURED surprise: `lcars xo on --engine copilot` reads as "change the
# engine" and SWEPT every scoreless mission at Verify into a real look —
# launching builds, driving a browser, hiring workers, filing bugs. That is the
# captain's money spent as the side effect of a settings change.
#
# S241 — THE CAPTAIN'S RULING: keep the catch-up, make it opt-in. So the
# DEFAULT is now the free announcement — switched on, told by name what is
# waiting, nothing started — and `--sweep` (or $LCARS_XO_SWEEP_ON_START=1) is
# the word that works through the backlog exactly as the default used to.
# BOTH directions are still asserted here, because both are still supported:
# 5a is the default (announce, spend nothing), 5b/5c the same thing asked for
# explicitly, and 5d the opt-in that really runs it. The journey suite's G
# section carries the full contract.
sweep_rig() { # <repo> → sets SWEEPLOG, writes a sweepbin
  SWEEPLOG="$1/swept.log"; : >"$SWEEPLOG"
  cat >"$1/sweepbin" <<SB
#!/usr/bin/env bash
printf 'swept %s\n' "\$1" >>"$SWEEPLOG"
SB
  chmod +x "$1/sweepbin"
}

# 5a. THE DEFAULT — switched on, and it STARTS NOTHING (S241).
repo5="$(new_repo)"; sweep_rig "$repo5"
rc5=0
( cd "$repo5" && LCARS_XO_SWEEP_BIN="$repo5/sweepbin" \
    bash "$XO" on --engine claude >"$repo5/on.out" 2>&1 ) || rc5=$?
check "5a. xo on --engine switches Number One on" \
  "[ '$rc5' -eq 0 ] && grep -q 'NUMBER ONE: ON' '$repo5/on.out'"
check "5a. the default starts NO look — the catch-up is opt-in now" \
  "[ ! -s '$repo5/swept.log' ] && grep -q 'lcars xo on --sweep' '$repo5/on.out'"

# 5b. `--no-sweep` — switched on, told what is waiting, nothing started.
repo6="$(new_repo)"; sweep_rig "$repo6"
rc6=0
( cd "$repo6" && LCARS_XO_SWEEP_BIN="$repo6/sweepbin" \
    bash "$XO" on --engine claude --no-sweep >"$repo6/on.out" 2>&1 ) || rc6=$?
check "5b. --no-sweep still switches Number One on" \
  "[ '$rc6' -eq 0 ] && grep -q 'NUMBER ONE: ON' '$repo6/on.out'"
check "5b. ...and STARTS NO LOOK (nothing was swept)" \
  "[ ! -s '$repo6/swept.log' ]"
check "5b. ...but still SAYS what is waiting, by name, for free" \
  "grep -q '$MISSION' '$repo6/on.out'"
check "5b. ...and names the one command that starts it" \
  "grep -q 'lcars xo on --sweep' '$repo6/on.out'"
check "5b. nothing billed on the --no-sweep path" \
  "[ \"\$(awk -F'\t' '\$2==\"yes\"{n++} END{print n+0}' '$SHIM_LOG')\" -eq 0 ]"

# 5c. The variable does the same thing, for an autopilot with no argv to change.
repo7="$(new_repo)"; sweep_rig "$repo7"
( cd "$repo7" && LCARS_XO_SWEEP_ON_START=0 LCARS_XO_SWEEP_BIN="$repo7/sweepbin" \
    bash "$XO" on --engine claude >"$repo7/on.out" 2>&1 ) || true
check "5c. LCARS_XO_SWEEP_ON_START=0 also starts nothing" \
  "[ ! -s '$repo7/swept.log' ]"

# 5d. And `--sweep` says it out loud for the same result as the default, so a
# script that wants the spend can be explicit about it.
repo8="$(new_repo)"; sweep_rig "$repo8"
( cd "$repo8" && LCARS_XO_SWEEP_BIN="$repo8/sweepbin" \
    bash "$XO" on --engine claude --sweep >"$repo8/on.out" 2>&1 ) || true
check "5d. --sweep runs the sweep explicitly" \
  "grep -q 'swept $MISSION' '$repo8/swept.log'"

echo
printf 'Number One concurrency: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
