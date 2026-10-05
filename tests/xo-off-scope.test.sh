#!/usr/bin/env bash
#
# S254 — THE OFF SWITCH PAUSES WHAT YOU NAMED, AND NOTHING ELSE.
#
# THE MEASURED DEFECT. Repo-wide `lcars xo off` — the captain turning his first
# officer off, naming no Mission — wrote `"paused": true` onto EVERY Mission
# whose `numberOne.status` was engaged (or that had a live recorded pid) PLUS
# every Mission named in those Missions' `xo/logs.json`. In a tester's fixture
# that was 5 of 5. `run.sh` halts on that flag at the stage boundary and again
# before each spawn, so turning Number One off STOPPED THE CAPTAIN'S OWN
# `lcars run` on work he never named. S245 made it announce this; the captain's
# ruling (2026-10-05) is that announcing is not enough.
#
# THE NARROWING LIVES AT THE CALLER, not inside `xo_quiesce`: `cmd_off` calls
# `stand_down <id> --opt-out` for a named Mission and `stand_down <m>` inside
# the repo-wide loop, so `stand_down` is where the two kinds of stop are told
# apart. S245's own implementor named this as a one-line narrowing.
#
# WHAT MUST NOT REGRESS. The S245 race fix is the MARKER, not the flag: the
# `xo-stop` marker is what makes `resolve-logs.sh` refuse to mint another driver
# and what makes `lcars resume` refuse. Repo-wide off still writes it, still
# stands Number One down, and still stops what is running. A TARGETED
# `lcars xo off <mission>` still quiesces in full — mission and logged children —
# because that is the Mission the captain pointed at.
#
# ZERO SPEND: a PATH shim fakes BOTH `claude` and `copilot`; the count is 0.
#
# Usage: bash tests/xo-off-scope.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ── ZERO SPEND, PINNED BY A PATH SHIM FAKING BOTH CLIs ─────────────────────
# Never an env var alone: the engine resolves from a request body, from
# $LCARS_WORKER_BIN and from a persisted `state.json workerBin`, and an env var
# has been MEASURED losing to the persisted one.
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

A="lcars-20261005-001"   # engaged, 2 logged children
B="lcars-20261005-010"   # engaged, 1 logged child
C1="lcars-20261005-002"; C2="lcars-20261005-003"; C3="lcars-20261005-011"

mkstate() { # <path> <id> <numberOne-status|-> [parent]
  local p="$1" id="$2" st="$3" par="${4:-}"
  mkdir -p "$(dirname "$p")"
  {
    printf '{\n  "id": "%s",\n  "type": "feature",\n  "title": "m %s",\n' "$id" "$id"
    printf '  "stage": "verify",\n  "githubIssue": 7,\n'
    printf '  "branch": "lcars/%s",\n  "base": "main",\n' "$id"
    [ -n "$par" ] && printf '  "parentMission": "%s",\n' "$par"
    [ "$st" = "-" ] || printf '  "numberOne": {"status": "%s", "note": "looking"},\n' "$st"
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e"\n}\n'
  } >"$p"
}

# TWO engaged Missions, THREE logged children between them. Exactly the shape a
# tester measured 5-of-5 on.
new_repo() {
  local repo
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  local M="$repo/.git/lcars/missions"
  mkdir -p "$M"
  cat >"$repo/.git/lcars/config.json" <<EOF
{
  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "projectName": "repo",
  "contextFile": null,
  "testCommand": "true",
  "numberOne": {"enabled": true, "engine": "claude"},
  "created": "2026-10-05T00:00:00Z"
}
EOF
  mkstate "$M/$A/state.json" "$A" engaged
  mkstate "$M/$B/state.json" "$B" engaged
  mkstate "$M/$C1/state.json" "$C1" - "$A"
  mkstate "$M/$C2/state.json" "$C2" - "$A"
  mkstate "$M/$C3/state.json" "$C3" - "$B"
  mkdir -p "$M/$A/xo" "$M/$B/xo"
  printf '{"filed": [{"n": 1, "mission": "%s"}, {"n": 2, "mission": "%s"}]}\n' \
    "$C1" "$C2" >"$M/$A/xo/logs.json"
  printf '{"filed": [{"n": 1, "mission": "%s"}]}\n' "$C3" >"$M/$B/xo/logs.json"
  echo "$repo"
}

npaused() { grep -l '"paused": *true' "$1"/.git/lcars/missions/*/state.json 2>/dev/null | grep -c . | tr -dc '0-9'; }

printf '\n\033[1m1. REPO-WIDE OFF PAUSES NOTHING THE CAPTAIN DID NOT NAME\033[0m\n'

R1="$(new_repo)"
check "1. CONTROL — nothing is paused before the stop" "[ \"\$(npaused '$R1')\" = 0 ]"
( cd "$R1" && bash "$XO" off ) >"$TMPROOT/off1.out" 2>&1 || true
sed 's/^/    /' "$TMPROOT/off1.out"
check "1. ZERO \`paused\` flags written anywhere — 5 of 5 Missions left alone" \
  "[ \"\$(npaused '$R1')\" = 0 ]"
check "1. ...and neither engaged Mission is paused" \
  "! grep -q '\"paused\"' '$R1/.git/lcars/missions/$A/state.json' \
   && ! grep -q '\"paused\"' '$R1/.git/lcars/missions/$B/state.json'"
check "1. ...and no logged child is paused" \
  "! grep -q '\"paused\"' '$R1/.git/lcars/missions/$C1/state.json' \
   && ! grep -q '\"paused\"' '$R1/.git/lcars/missions/$C2/state.json' \
   && ! grep -q '\"paused\"' '$R1/.git/lcars/missions/$C3/state.json'"
check "1. ...so it never tells the captain it paused anything" \
  "! grep -qi 'paused' '$TMPROOT/off1.out'"
check "1. the switch really is OFF in the config" \
  "grep -q 'NUMBER ONE: OFF' '$TMPROOT/off1.out' \
   && grep -q '\"enabled\": *false' '$R1/.git/lcars/config.json'"
check "1. BOTH engaged Missions are still stood down" \
  "grep -q '\"status\": *\"stood-down\"' '$R1/.git/lcars/missions/$A/state.json' \
   && grep -q '\"status\": *\"stood-down\"' '$R1/.git/lcars/missions/$B/state.json'"
check "1. ...and the stop marker IS still down on each — the S245 race fix" \
  "[ -f '$R1/.git/lcars/missions/$A/xo-stop' ] \
   && [ -f '$R1/.git/lcars/missions/$B/xo-stop' ]"
check "1. ...and the marker still RECORDS the children, so \`xo on\` can be symmetric" \
  "grep -q '^child $C1' '$R1/.git/lcars/missions/$A/xo-stop' \
   && grep -q '^child $C3' '$R1/.git/lcars/missions/$B/xo-stop'"
check "1. the repo-wide ON lifts every marker again" \
  "( cd '$R1' && bash '$XO' on --engine claude --no-sweep ) >'$TMPROOT/on1.out' 2>&1; \
   [ ! -f '$R1/.git/lcars/missions/$A/xo-stop' ] \
   && [ ! -f '$R1/.git/lcars/missions/$B/xo-stop' ] \
   && grep -q 'NUMBER ONE: ON' '$TMPROOT/on1.out'"
check "1. ...and leaves no Mission paused on the way back either" \
  "[ \"\$(npaused '$R1')\" = 0 ]"

printf '\n\033[1m2. THE CONTROL — a TARGETED off still quiesces in full (S245)\033[0m\n'

R2="$(new_repo)"
( cd "$R2" && bash "$XO" off "$A" ) >"$TMPROOT/off2.out" 2>&1 || true
sed 's/^/    /' "$TMPROOT/off2.out"
check "2. the named Mission IS paused" \
  "grep -q '\"paused\": *true' '$R2/.git/lcars/missions/$A/state.json'"
check "2. ...and so are ITS two logged children" \
  "grep -q '\"paused\": *true' '$R2/.git/lcars/missions/$C1/state.json' \
   && grep -q '\"paused\": *true' '$R2/.git/lcars/missions/$C2/state.json'"
check "2. exactly 3 paused — the Mission he named and its own children, nothing else" \
  "[ \"\$(npaused '$R2')\" = 3 ]"
check "2. the OTHER engaged Mission is untouched: not paused, not stood down" \
  "! grep -q '\"paused\"' '$R2/.git/lcars/missions/$B/state.json' \
   && ! grep -q '\"paused\"' '$R2/.git/lcars/missions/$C3/state.json' \
   && [ ! -f '$R2/.git/lcars/missions/$B/xo-stop' ]"
check "2. ...and the captain is TOLD the targeted stop paused something" \
  "grep -qi 'paused' '$TMPROOT/off2.out'"
check "2. a targeted ON puts the three back" \
  "( cd '$R2' && bash '$XO' on '$A' ) >'$TMPROOT/on2.out' 2>&1; \
   [ \"\$(npaused '$R2')\" = 0 ] && [ ! -f '$R2/.git/lcars/missions/$A/xo-stop' ]"

printf '\n\033[1m3. THE MARKER STILL REFUSES A RESUME (S245 D3) — repo-wide too\033[0m\n'

R3="$(new_repo)"
( cd "$R3" && bash "$XO" off ) >"$TMPROOT/off3.out" 2>&1 || true
RES_OUT="$TMPROOT/resume3.out"
( cd "$R3" && bash "$REPO_ROOT/skills/lcars-pause/pause.sh" resume "$A" ) >"$RES_OUT" 2>&1
RES_RC=$?
check "3. CONTROL — the repo-wide off really did lay the marker down" \
  "[ -f '$R3/.git/lcars/missions/$A/xo-stop' ]"
check "3. \`lcars resume\` REFUSES over a live xo-stop marker, even though nothing is paused" \
  "[ -f '$R3/.git/lcars/missions/$A/xo-stop' ] && [ '$RES_RC' -ne 0 ]"
check "3. CONTROL — with the marker lifted, the same resume is not refused for that reason" \
  "rm -f '$R3/.git/lcars/missions/$A/xo-stop'; \
   ( cd '$R3' && bash '$REPO_ROOT/skills/lcars-pause/pause.sh' resume '$A' ) \
     >'$TMPROOT/resume3b.out' 2>&1; \
   ! grep -qi 'xo-stop' '$TMPROOT/resume3b.out'"

printf '\n\033[1m4. ZERO SPEND\033[0m\n'
check "4. no engine was invoked" "[ ! -s '$SHIM_LOG' ]"
check "4. ...and nothing carried a --model" "! grep -q 'yes' '$SHIM_LOG' 2>/dev/null"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
