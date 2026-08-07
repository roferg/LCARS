#!/usr/bin/env bash
# ============================================================================
# handoff-durability.sh — KILL THE DAEMON MID-WAIT AND SEE WHAT HE GETS
#
# THE CAPTAIN'S QUESTION, asked while S170 was being built: *"If the daemon
# closes by accident while I walk away are we still good?"*
#
# SEND TO ALIGN is a stage with a wait now: one bounded read-only pass stands
# in the captain's project and works out what the mockup changes about it, and
# that takes 154–220s measured. The whole premise is that he can leave. A
# walk-away is precisely when nobody is watching the daemon, so "the answer
# died with the process" is not a corner case — it is the case.
#
# NO OTHER RIG CAN SEE THIS. `tests/drives/browser/handoff.sh` reloads the
# PAGE, which throws away client state and not the daemon; every unit test in
# `web/tests/` runs one process. The only proof is a daemon killed for real,
# with `kill -9` (SIGTERM and SIGINT are ignored — see the memory note), and a
# fresh one started over the same room.
#
# WHAT IT MEASURES, in the captain's terms:
#
#   A. He starts the wait and the daemon dies MID-PASS. He comes back to a
#      fresh daemon: it must NOT claim a pass is running (nothing is), must NOT
#      claim an answer it does not have, and must offer the wait again.
#   B. The pass FINISHES, then the daemon dies. He comes back: the answer is
#      there, in his brief, with NO SECOND WAIT and NO WORKER SPAWNED.
#
# ZERO TOKENS. The "engine" is a python script with a sleep in it (the same
# device the browser rigs use), so this costs nothing and is safe to re-run.
#
# USAGE:  bash tests/drives/handoff-durability.sh
# EXIT:   0 proven · 1 the product is wrong · 77 skipped / infrastructure
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PY="${LCARS_PYTHON_BIN:-python3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-handoff-durability.XXXXXX")"
SLEEP_S="${LCARS_RIG_DERIVE_SLEEP:-20}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
skip() {
  printf '\n\033[33m════ SKIPPED — durability was NOT proven ════\033[0m\n'
  printf '  %s\n' "$1"
  printf '  This is NOT a pass.\n\n'
  exit 77
}
FAILED=0

command -v git >/dev/null 2>&1 || skip "git not found."
"$PY" -c "import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)" ||
  skip "python3 not found."

# ── the fixture: a target repo, a sidecar, one archived program ─────────────
REPOD="$WORK/project"; SIDE="$WORK/holo/project-holodeck"; ROOM="$SIDE/redesign"
# The program NAME, read out of the transcript below — and, since S171,
# the head of the brief itself (his opening description, verbatim).
PROGRAM_NAME="Redesign"
mkdir -p "$REPOD/src" "$ROOM"
cat >"$REPOD/src/toolbar.js" <<'JS'
// the app AS IT IS TODAY — the thing the pass stands in and reads.
export const TOOLBAR_HEIGHT = 48;
export const THEME = "dark-only";
JS
( cd "$REPOD" && git init -q . && git -c user.email=a@b -c user.name=r add -A &&
  git -c user.email=a@b -c user.name=r commit -q --no-gpg-sign -m init ) \
  >/dev/null 2>&1 || skip "could not git init the fixture project"

cat >"$ROOM/transcript.md" <<'TR'
# Redesign

The holodeck's record of this program.

## Turn 1 · 2026-08-07T09:00:00Z

**Captain:** make the toolbar taller and add a light theme.

**Holodeck:** Planted by the rig.
TR
cat >"$ROOM/mockup.html" <<'MOCK'
<!doctype html>
<!-- VISUAL REFERENCE ONLY — a rig fixture. Internals deliberately fake. -->
<html><body><header style="height:52px">Redesign</header></body></html>
MOCK
cat >"$ROOM/concept.md" <<'CD'
# Redesign

## The problem
The toolbar is cramped and the app is dark-only.

## Decisions
- **T1** Grow the toolbar, because the captain asked for breathing room.

## Open questions
None open.

## WHAT IT MUST DO — behaviour only

### 1. Requirements (captain's words)
1. **T1** "Make the toolbar taller."
2. **T1** "Add a light theme."

### 2. Implied by the mockup, not yet settled
- Does the theme choice persist across sessions?

### 3. Out of scope
- The canvas renderer.
CD
cat >"$ROOM/basis.md" <<'BD'
# basis.md — what the app was when this program started
The toolbar is 48px. Dark only.
BD
( cd "$SIDE" && git init -q . && git -c user.email=a@b -c user.name=r add -A &&
  git -c user.email=a@b -c user.name=r commit -q --no-gpg-sign -m init ) \
  >/dev/null 2>&1 || skip "could not git init the sidecar"

# ── the "engine": a script with a real wait in it ──────────────────────────
WORKER="$WORK/derive-worker"
cat >"$WORKER" <<PYW
#!/usr/bin/env python3
"""The rig's stand-in for a derivation worker. NOT an engine — a script."""
import sys, time
argv = sys.argv[1:]
prompt = ""
for i, a in enumerate(argv):
    if a == "-p" and i + 1 < len(argv):
        prompt = argv[i + 1]
        break
if "=== CHANGES ===" not in prompt:
    sys.stderr.write("DURABILITY RIG: an unexpected worker was spawned.\n")
    sys.exit(1)
with open("$WORK/spawns.log", "a") as fh:
    fh.write("spawn\n")
time.sleep($SLEEP_S)
sys.stdout.write("read the toolbar.\n=== CHANGES ===\n")
sys.stdout.write("- today the toolbar is 48px tall -> the mockup makes it 52px\n")
PYW
chmod +x "$WORKER"

start_daemon() {
  ( cd "$REPO/web" && exec env -u LCARS_SERVE_PORT \
      LCARS_HOLODECK_ROOT="$WORK/holo" \
      LCARS_HOLODECK_HANDOFF_CHECK=1 \
      LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT=600 \
      LCARS_WORKER_BIN="$WORKER" \
      "$PY" -m lcars_serve --port 0 --repo-root "$REPOD" ) \
    >"$WORK/daemon.log" 2>&1 &
  DPID=$!
  PORT=""
  for _ in $(seq 1 60); do
    PORT="$(sed -n 's|.*http://127.0.0.1:\([0-9]*\)/.*|\1|p' "$WORK/daemon.log" \
            | head -1)"
    [ -n "$PORT" ] && break
    sleep 0.4
  done
  [ -n "$PORT" ] || { cat "$WORK/daemon.log"; skip "the daemon never printed a port"; }
}

stop_daemon() {   # THE ONLY THING THAT REAPS IT (memory: it ignores TERM+INT)
  [ -n "${DPID:-}" ] && kill -9 "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  DPID=""
}

api() {   # $1 = path  $2 = json body ("" for GET)
  if [ -z "${2:-}" ]; then
    curl -sS "http://127.0.0.1:$PORT$1"
  else
    curl -sS -X POST -H 'Content-Type: application/json' -d "$2" \
      "http://127.0.0.1:$PORT$1"
  fi
}

# `open` the archived room → a NEW session id every time, which is exactly why
# the persisted record must not be keyed on one.
open_room() {
  OPENED="$(api /api/holodeck/open '{"room": "redesign"}')"
  SID="$(printf '%s' "$OPENED" | "$PY" -c \
    'import json,sys; d=json.load(sys.stdin); d=d.get("state",d); print(d.get("sessionId",""))')"
  [ -n "$SID" ] || { printf '%s\n' "$OPENED"; skip "could not open the room"; }
}

# S171 — ▶ SEND TO ALIGN IS THE GATE, so the deck posts `derive` and the
# dialog then READS what that produced. `promote` no longer starts anything,
# which is why the two are separate calls here: a rig that only promoted would
# sit on `none` for ever and prove nothing about the wait.
derive() {
  api "/api/holodeck/$SID/derive" '{}' >/dev/null
}

promote() {
  PROMO="$(api "/api/holodeck/$SID/promote" '{}')"
  DSTATE="$(printf '%s' "$PROMO" | "$PY" -c \
    'import json,sys; d=json.load(sys.stdin); d=d.get("state",d); v=d.get("derive") or {}; print(v.get("state",""), "ok" if v.get("ok") else "-")')"
  BRIEF="$(printf '%s' "$PROMO" | "$PY" -c \
    'import json,sys; d=json.load(sys.stdin); d=d.get("state",d); print(d.get("brief",""))')"
}

spawns() { [ -f "$WORK/spawns.log" ] && wc -l <"$WORK/spawns.log" | tr -d ' ' || echo 0; }

say "── A. THE DAEMON DIES MID-PASS ────────────────────────────────────────"
start_daemon
note "daemon pid $DPID on port $PORT · room $ROOM"
open_room
derive
promote
note "he presses ▶ SEND TO ALIGN → derive: $DSTATE"
case "$DSTATE" in
  running*) ok "the wait starts, and the dialog answers at once" ;;
  *) bad "the first promote should be RUNNING, it was: $DSTATE" ;;
esac
sleep 3
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""
note "kill -9 on the daemon, $((SLEEP_S - 3))s before the pass would answer"
if [ -f "$ROOM/handoff-changes.json" ]; then
  bad "a record was written for a pass that never finished — a fresh daemon
      would read a state it cannot know is true"
else
  ok "NOTHING was persisted for a pass in flight (no lie left on disk)"
fi
BEFORE_A="$(spawns)"

start_daemon
note "a FRESH daemon (pid $DPID, port $PORT) — its caches are empty"
open_room
promote
note "the deck reads the gate on a fresh daemon → derive: $DSTATE"
case "$DSTATE" in
  "none "*) ok "no phantom 'still running' from a process that is gone, and no
      answer it does not have — the gate offers the wait again" ;;
  *) bad "after a mid-pass death the gate should read NONE, got: $DSTATE" ;;
esac
printf '%s' "$BRIEF" | grep -q "$PROGRAM_NAME" \
  && ok "and he still has a brief he can file — his own words, unrewritten" \
  || bad "the brief is gone"
derive
promote
case "$DSTATE" in
  running*) ok "and pressing it again really does start a new pass" ;;
  *) bad "a re-press should start the wait, it was: $DSTATE" ;;
esac
printf '%s' "$BRIEF" | grep -q "## What the mockup changes" \
  && bad "the brief claims a change list the pass never produced" \
  || ok "…without a change section, which is the honest degraded shape"

say ""
say "── B. THE PASS FINISHES, THEN THE DAEMON DIES ─────────────────────────"
note "waiting for the pass to land…"
for _ in $(seq 1 120); do
  promote
  case "$DSTATE" in "done ok") break ;; esac
  sleep 2
done
case "$DSTATE" in
  "done ok") ok "the pass landed: $DSTATE" ;;
  *) bad "the pass never landed (got $DSTATE)"; ;;
esac
printf '%s' "$BRIEF" | grep -q "48px tall" \
  && ok "the derived change is in his brief" \
  || bad "the derived change never reached the brief"
[ -f "$ROOM/handoff-changes.json" ] \
  && ok "and it is PERSISTED in the program's room" \
  || bad "nothing was written to the room — the answer dies with this daemon"
AFTER_B="$(spawns)"

stop_daemon
note "kill -9 on the daemon again, with the answer already in hand"
start_daemon
note "a FRESH daemon (pid $DPID, port $PORT)"
open_room
T0=$(date +%s)
promote
T1=$(date +%s)
case "$DSTATE" in
  "done ok") ok "he reopens and the answer is ALREADY THERE ($((T1 - T0))s)" ;;
  *) bad "after a restart he was made to wait again (got $DSTATE)" ;;
esac
printf '%s' "$BRIEF" | grep -q "48px tall" \
  && ok "the derived change is in the brief a restarted daemon drafts" \
  || bad "the restarted daemon lost the change list"
if [ "$(spawns)" = "$AFTER_B" ]; then
  ok "NO WORKER WAS SPAWNED — he does not pay the wait twice"
else
  bad "a second worker was spawned ($AFTER_B → $(spawns)) — the record was
      not used, so the durability is theatre"
fi
stop_daemon

say ""
if [ "$FAILED" = "0" ]; then
  printf '\033[32m✓ THE WAIT SURVIVES A DAEMON THAT DIES — BOTH WAYS ROUND.\033[0m\n'
  printf '  artifacts: %s\n\n' "$WORK"
  exit 0
fi
printf '\033[31m✗ %s CHECK(S) FAILED.\033[0m\n' "$FAILED"
printf '  artifacts: %s   daemon log: %s/daemon.log\n\n' "$WORK" "$WORK"
exit 1
