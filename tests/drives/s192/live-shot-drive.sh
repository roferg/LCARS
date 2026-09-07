#!/usr/bin/env bash
# ===========================================================================
# S192 CAPSTONE DRIVE RIG — the WHOLE day-zero loop, on a REAL blank repo,
# with a REAL LIVE Copilot worker, PHOTOGRAPHED in REAL HEADED CHROME.
#
#   bash tests/drives/s192/live-shot-drive.sh <repo|fixture-name> <label> \
#        [--phase front-door,grill,run,verify,approve,normal|all] [options]
#
# WHAT THIS IS FOR. Every other rig in this round proves a FACT. This one
# produces PICTURES a human looks at afterwards and judges the product on —
# plus, beside every PNG, a factual text readout of what was actually on
# screen when the shutter fired. The readout is what stops a screenshot from
# being mistaken for a passing test.
#
# HOW IT DIFFERS FROM S184's shots.sh (read that first; this inherits its
# shape). s184 pins ZERO SPEND: a counting PATH shim, a spend fuse, and a
# STUBBED recommendation. This capstone is the exact opposite — the worker is
# REAL LIVE COPILOT (free and unlimited; captain-approved for live drives) and
# the recommendation on screen is whatever the live grill actually produced.
# There is therefore NO counting shim and NO spend fuse on the live path.
# What replaces them is the ENGINE FENCE below.
#
# ---------------------------------------------------------------------------
# THE ENGINE FENCE — copilot, pinned at every point that can decide the engine
# ---------------------------------------------------------------------------
# `claude` BILLS. Copilot does not. The engine is decided in more than one
# place and the winner differs per path, so pinning one of them is not enough
# (measured in an earlier session: an env var LOSING to a persisted workerBin,
# 7 workers and $11.39 on the wrong engine, with spend as the only symptom).
# The four decision points, and how each is pinned here:
#
#   1. THE REQUEST BODY. `POST /api/align/start` takes an `engine` field
#      (server.py) — but the shipping front door sends only `{idea, vision}`
#      (board.js `frontDoorSubmit`), so on THIS path the body carries no
#      engine and the winner is the daemon's own `self.worker_bin`, which is
#      `os.environ["LCARS_WORKER_BIN"]` (__main__.py:148). We pin that.
#   2. $LCARS_WORKER_BIN. Set on the daemon, so (a) the grill uses it, and
#      (b) `Actions._run/_spawn` re-injects it into EVERY script the daemon
#      shells (actions.py:12926) — file.sh, establish-vision.sh, run.sh.
#      It is also the TOP of run.sh's own `resolve_worker_bin` precedence.
#   3. config.json `workerBin`. run.sh's second precedence slot. Written into
#      the FIXTURE repo here (fixture setup, never product code).
#   4. state.json `workerBin` — the MISSION's own persisted pin, written by
#      file.sh from $LCARS_WORKER_BIN at accept time, and the slot that beat
#      an env var in the historical incident. ASSERTED after accept; the rig
#      REFUSES to run the mission if it does not say copilot.
#
# And because no fence is trusted on its word, the rig MEASURES:
#   · `$SHIM/copilot` is a LOGGING WRAPPER around the real binary (it wraps
#     and tees; it never fakes a reply), appending one SPAWN line per turn.
#   · `$SHIM/claude` is a REFUSING STUB that logs the attempt and exits 97,
#     so a stray `claude` is loud and unbilled rather than silent and billed.
#   · the run report prints the spawn count per binary. ZERO claude spawns is
#     part of the verdict, not an assumption.
#
# ---------------------------------------------------------------------------
# OPERATIONAL RULES THIS RIG OBEYS
# ---------------------------------------------------------------------------
#   · THE STAGE, NEVER `implement-ticket`. The run phase clicks the board's
#     "▶ Start", which is `run.sh drive --mission <id>` — the driver that
#     sequences the real Stages (`run.sh implement` among them). Every harness
#     in this round that took the shortcut entry point was blind to a blocker
#     on the only path a captain actually uses.
#   · NO `timeout(1)`. macOS ships neither `timeout` nor `gtimeout` and
#     coreutils is not installed here. Hang protection is pure bash:
#     background, record the pid, poll `kill -0` to a deadline, then kill.
#   · RESUMABLE AND IDEMPOTENT. Fixture repos are EMPTIED, never deleted (the
#     GitHub remote is what makes them expensive). Each phase boots its own
#     daemon + Chrome and can be run alone, so a failure at 3am does not force
#     re-driving the expensive early legs.
#   · Bash 3.2 portable. Every path quoted (the copilot binary lives under
#     "Application Support" and "Visual Studio Code.app").
#
# OUTPUT: tests/drives/s192/shots/<label>/ — PNGs + per-shot .txt readouts +
# worker turn logs. `.gitignore` blocks `tests/drives/*/shots/`: the RIG is
# committed, the PNGs are not (captain ruling 2026-09-06).
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../s183b/rig.sh"          # LCARS_SRC, FIX_ROOT, newrepo/commitall …

# --- the two real binaries --------------------------------------------------
# The copilot the captain actually has. It is a /bin/sh launcher that execs an
# ABSOLUTE Code Helper (checked) — it does NOT re-resolve `copilot` from PATH,
# so s184's 215-deep recursion hazard does not apply. The wrapper still strips
# the shim from PATH before exec'ing it, because that guarantee is not ours.
COPILOT_DEFAULT="/Users/roganferguson/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot"
COPILOT="${LCARS_COPILOT_BIN:-$COPILOT_DEFAULT}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

# --- argv -------------------------------------------------------------------
TARGET="${1:-}"; LABEL="${2:-}"
[ -n "$TARGET" ] && [ -n "$LABEL" ] || {
  sed -n '3,7p' "${BASH_SOURCE[0]}" >&2
  echo "phases: front-door | grill | run | verify | approve | normal | all" >&2
  exit 2
}
shift 2
PHASES="all"; RESET="auto"; TURNS="${S192_TURNS:-10}"
TURN_TIMEOUT="${S192_TURN_TIMEOUT:-600}"     # seconds, per copilot invocation
TURN_RETRIES="${S192_TURN_RETRIES:-1}"       # extra attempts after a hang
RUN_BUDGET="${S192_RUN_BUDGET:-5400}"        # seconds the run phase may watch
RUN_EVERY="${S192_RUN_EVERY:-45}"            # seconds between run-phase shots
IDEA_FILE="$HERE/captain-idea.txt"
ANSWERS_FILE="$HERE/captain-answers.txt"
NORMAL_PRD="$HERE/normal-mission-prd.md"
KEEP_UP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --phase)     PHASES="${2:-all}"; shift 2 ;;
    --phase=*)   PHASES="${1#--phase=}"; shift ;;
    --reset)     RESET=1; shift ;;
    --no-reset)  RESET=0; shift ;;
    --turns)     TURNS="${2:-10}"; shift 2 ;;
    --idea)      IDEA_FILE="$2"; shift 2 ;;
    --answers)   ANSWERS_FILE="$2"; shift 2 ;;
    --keep-up)   KEEP_UP=1; shift ;;           # leave daemon+Chrome running
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case ",$PHASES," in *,all,*) PHASES="front-door,grill,run,verify,approve,normal" ;; esac
want() { case ",$PHASES," in *",$1,"*) return 0 ;; esac; return 1; }

# --- the repo ---------------------------------------------------------------
if [ -d "$TARGET/.git" ]; then REPO="$TARGET"; else REPO="$FIX_ROOT/$TARGET"; fi
[ -d "$REPO/.git" ] || { echo "SKIP 77: no git repo at $REPO"; exit 77; }
REPO="$(cd "$REPO" && pwd)"

OUT="$HERE/shots/$LABEL"
mkdir -p "$OUT" || exit 1
SHIM="$OUT/shim"; mkdir -p "$SHIM"
WORKDIR="$OUT/worker"; mkdir -p "$WORKDIR"
SPAWNLOG="$OUT/spawns.log"; : >> "$SPAWNLOG"
RUNLOG="$OUT/drive.log"
# The spawn ledger is CUMULATIVE across invocations (an overnight campaign is
# several invocations and the captain wants the whole hire list). A RUN marker
# separates them so the per-invocation report cannot inherit an earlier run's
# spawns — a resumable rig that reports stale facts is worse than one that
# cannot resume.
RUN_MARK="$(date +%s)"
printf 'RUN\t%s\t%s\t%s\n' "$RUN_MARK" "$LABEL" "$PHASES" >> "$SPAWNLOG"

say()  { printf '%s\n' "$*" | tee -a "$RUNLOG"; }
step() { printf '\n=== %s ===\n' "$*" | tee -a "$RUNLOG"; }

step "S192 capstone drive — label=$LABEL phases=$PHASES"
say "repo:    $REPO"
say "out:     $OUT"
say "copilot: $COPILOT"

[ -x "$COPILOT" ] || { echo "FAIL: no copilot at '$COPILOT'"; exit 1; }
[ -x "$CHROME" ]  || { echo "SKIP 77: no Chrome at '$CHROME'"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP 77: no node"; exit 77; }

# ===========================================================================
# THE ENGINE FENCE — the shim
# ===========================================================================
# The copilot WRAPPER. It changes NOTHING about the invocation: same argv, same
# cwd, same env, same stdout/stderr back to the caller. What it adds is a
# record (argv, timing, rc, and copilot's own trailer — AI Credits and the
# `--resume` session id, which is what proves a later turn RESUMED rather than
# opening a fresh session) and pure-bash hang protection.
cat > "$SHIM/copilot" <<WRAP
#!/usr/bin/env bash
# S192 LIVE COPILOT WRAPPER — logs and tees; never fakes.
set -u
REAL="$COPILOT"
LOGD="$WORKDIR"
SPAWNS="$SPAWNLOG"
TMO="$TURN_TIMEOUT"
TRIES=\$(( $TURN_RETRIES + 1 ))
case " \$* " in
  *" --version "*|*" -v "*)
    printf 'PROBE\tcopilot\t%s\t--version\n' "\$(date +%s)" >> "\$SPAWNS"
    exec "\$REAL" "\$@" ;;
esac
d="\$(mktemp -d "\$LOGD/turn-XXXXXX")"
{
  printf '=== S192 WORKER TURN ===\n'
  printf 'when:    %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'cwd:     %s\n' "\$PWD"
  printf 'bin:     %s\n' "\$REAL"
  printf 'role:    %s\n' "\${LCARS_WORKER_ROLE:-}"
  printf 'mission: %s\n' "\${LCARS_MISSION:-}"
  printf 'ticket:  %s\n' "\${LCARS_TICKET:-}"
  printf '=== ARGV (%s args) ===\n' "\$#"
  for a in "\$@"; do printf -- '--- arg\n%s\n' "\$a"; done
} > "\$d/argv.txt"
printf 'SPAWN\tcopilot\t%s\t%s\t%s\t%s\n' "\$(date +%s)" "\$(basename "\$d")" \\
       "\${LCARS_WORKER_ROLE:-}" "\$(printf '%s' "\$*" | tr '\n' ' ' | head -c 200)" >> "\$SPAWNS"

attempt=1; rc=99; hung=0
while [ "\$attempt" -le "\$TRIES" ]; do
  : > "\$d/out"; : > "\$d/err"
  t0=\$(date +%s)
  # PATH stripped of the shim: nothing downstream can recurse back into us.
  PATH="\${PATH#\$(dirname "\$0"):}" "\$REAL" "\$@" > "\$d/out" 2> "\$d/err" < /dev/null &
  p=\$!
  # PURE-BASH WATCHDOG. There is no timeout(1) on this machine, and writing
  # writing 'timeout 300 copilot ...' would fail with "command not found" in a way that
  # looks exactly like the worker returning instantly.
  deadline=\$(( t0 + TMO )); hung=0
  while kill -0 "\$p" 2>/dev/null; do
    if [ "\$(date +%s)" -ge "\$deadline" ]; then
      hung=1
      kill -TERM "\$p" 2>/dev/null
      k=0; while kill -0 "\$p" 2>/dev/null && [ "\$k" -lt 10 ]; do sleep 1; k=\$((k+1)); done
      kill -KILL "\$p" 2>/dev/null
      break
    fi
    sleep 2
  done
  wait "\$p"; rc=\$?
  t1=\$(date +%s)
  printf 'attempt=%s rc=%s secs=%s hung=%s\n' "\$attempt" "\$rc" "\$((t1-t0))" "\$hung" >> "\$d/attempts.txt"
  if [ "\$hung" = 1 ]; then
    printf 'HANG\tcopilot\t%s\t%s\tattempt=%s timeout=%ss\n' "\$(date +%s)" \\
      "\$(basename "\$d")" "\$attempt" "\$TMO" >> "\$SPAWNS"
    cp "\$d/out" "\$d/out.hung.\$attempt" 2>/dev/null
    cp "\$d/err" "\$d/err.hung.\$attempt" 2>/dev/null
    attempt=\$((attempt+1)); continue
  fi
  break
done

# copilot's own trailer — the cost and the resume id, kept per turn.
{ cat "\$d/out"; cat "\$d/err"; } 2>/dev/null \\
  | grep -E '^(Changes|AI Credits|Tokens|Resume|Total duration)' > "\$d/trailer.txt" 2>/dev/null
credits="\$(sed -n 's/^AI Credits[[:space:]]*//p' "\$d/trailer.txt" | head -1)"
resume="\$(sed -n 's/.*--resume=\\([^[:space:]]*\\).*/\\1/p' "\$d/trailer.txt" | head -1)"
printf 'TURN\t%s\trc=%s\tcredits=%s\tresume=%s\thung=%s\n' \\
  "\$(basename "\$d")" "\$rc" "\${credits:-?}" "\${resume:-?}" "\$hung" >> "\$SPAWNS"

cat "\$d/out"
cat "\$d/err" >&2
exit "\$rc"
WRAP
chmod +x "$SHIM/copilot"

# The REFUSING claude. Not absent — absent means the real, BILLED claude is
# found one PATH entry later. It logs the attempt so the report can name it.
cat > "$SHIM/claude" <<CLAUDE
#!/usr/bin/env bash
printf 'SPAWN\tclaude\t%s\t\t\t%s\n' "\$(date +%s)" "\$(printf '%s' "\$*" | tr '\n' ' ' | head -c 200)" >> "$SPAWNLOG"
echo "S192 ENGINE FENCE: the claude CLI was invoked and is REFUSED — this drive is copilot-only (claude bills). argv: \$*" >&2
exit 97
CLAUDE
chmod +x "$SHIM/claude"

# The INVERSE of s183b's spend fuse: that one refuses when the fakes are
# MISSING (an empty shim puts the billed claude on PATH). Same reasoning, live
# shape — refuse unless the real copilot is there AND claude is fenced.
engine_fuse() {
  [ -x "$SHIM/copilot" ] || { echo "ENGINE FUSE: no copilot wrapper at $SHIM" >&2; return 1; }
  [ -x "$SHIM/claude" ]  || { echo "ENGINE FUSE: no refusing claude stub at $SHIM — the billed claude is reachable" >&2; return 1; }
  [ -x "$COPILOT" ]      || { echo "ENGINE FUSE: real copilot missing at $COPILOT" >&2; return 1; }
  return 0
}
engine_fuse || exit 99

# …_of counts EVERY invocation ever recorded; …_run counts only this one.
spawns_of()  { awk -F'\t' -v b="$2" '$1=="SPAWN" && $2==b {n++} END{print n+0}' "$1" 2>/dev/null; }
hangs_of()   { awk -F'\t' '$1=="HANG"{n++} END{print n+0}' "$1" 2>/dev/null; }
spawns_run() { awk -F'\t' -v b="$2" -v m="$3" '$1=="RUN" && $2==m {seen=1; next} seen && $1=="SPAWN" && $2==b {n++} END{print n+0}' "$1" 2>/dev/null; }
hangs_run()  { awk -F'\t' -v m="$2" '$1=="RUN" && $2==m {seen=1; next} seen && $1=="HANG" {n++} END{print n+0}' "$1" 2>/dev/null; }

# ===========================================================================
# FIXTURE — reused and EMPTIED, never deleted (the GitHub remote is the value)
# ===========================================================================
empty_repo() {
  local r="$1"
  say "emptying fixture (kept, never deleted): $r"
  # kill any leftover mission worktrees before touching branches
  git -C "$r" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | while read -r w; do
        [ "$w" = "$r" ] && continue
        git -C "$r" worktree remove --force "$w" >/dev/null 2>&1
      done
  git -C "$r" worktree prune >/dev/null 2>&1
  local base; base="$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$base" ] || base=main
  git -C "$r" checkout -q "$base" >/dev/null 2>&1 || git -C "$r" checkout -q -B "$base" >/dev/null 2>&1
  git -C "$r" branch --list 'lcars/*' 2>/dev/null | tr -d ' *' | while read -r b; do
    [ -n "$b" ] && git -C "$r" branch -qD "$b" >/dev/null 2>&1
  done
  git -C "$r" reset -q --hard >/dev/null 2>&1
  git -C "$r" clean -qxfd >/dev/null 2>&1
  rm -rf "$r/.git/lcars"
  git -C "$r" config user.email >/dev/null 2>&1 || git -C "$r" config user.email t@e.x
  git -C "$r" config user.name  >/dev/null 2>&1 || git -C "$r" config user.name  t
  git -C "$r" config commit.gpgsign false
}

# config.json `workerBin` — resolution point 3. Written into the FIXTURE.
pin_config() {
  mkdir -p "$REPO/.git/lcars"
  printf '{\n  "version": 1,\n  "workerBin": "copilot"\n}\n' > "$REPO/.git/lcars/config.json"
  say "pinned config.json workerBin=copilot"
}

if [ "$RESET" = 1 ] || { [ "$RESET" = auto ] && want front-door; }; then
  empty_repo "$REPO"
fi
[ -f "$REPO/.git/lcars/config.json" ] || pin_config
grep -q '"workerBin"' "$REPO/.git/lcars/config.json" 2>/dev/null || pin_config

# ===========================================================================
# DAEMON + CHROME (one pair for this invocation, whatever phases it runs)
# ===========================================================================
DPID=""; CPID=""; BOARD_URL=""; DEV_PORT=""
teardown() {
  [ "$KEEP_UP" = 1 ] && { say "left up: daemon pid $DPID, chrome pid $CPID"; return 0; }
  [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
  return 0
}
trap teardown EXIT

boot_daemon() {
  # PER-INVOCATION log, archived not appended. Measured in smoke: with an
  # APPENDED daemon.log the boot loop's `tail -1` read the PREVIOUS run's URL
  # before this run had printed its own, and drove Chrome at a DEAD port — the
  # app "never painted", which reads exactly like a product failure.
  [ -f "$OUT/daemon.log" ] && mv -f "$OUT/daemon.log" "$OUT/daemon.log.prev"
  : > "$OUT/daemon.log"
  # `env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT` is LOAD-BEARING: this rig is
  # itself launched from a Claude Code session, and run.sh's `detect_host_cli`
  # reads CLAUDECODE=1 as "the host CLI is claude". Leaving it set would let
  # host detection name the billed engine on any path where the higher-
  # precedence pins were somehow absent.
  ( cd "$LCARS_SRC/web" && exec env \
      -u LCARS_SERVE_PORT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
      PATH="$SHIM:$PATH" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
      LCARS_WORKER_BIN="$SHIM/copilot" \
      LCARS_LIVE_LOG="$OUT/worker.live.log" \
      python3 -m lcars_serve --port 0 --repo-root "$REPO" ) \
      >>"$OUT/daemon.log" 2>&1 &
  DPID=$!
  local i
  for i in $(seq 1 200); do
    BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" | tail -1)"
    [ -n "$BOARD_URL" ] && break
    kill -0 "$DPID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$BOARD_URL" ] || { echo "FAIL: daemon never came up"; tail -25 "$OUT/daemon.log"; return 1; }
  say "daemon: $BOARD_URL (pid $DPID)"
}

boot_chrome() {
  [ -f "$OUT/chrome.log" ] && mv -f "$OUT/chrome.log" "$OUT/chrome.log.prev"
  : > "$OUT/chrome.log"
  local profile="${LCARS_DRIVE_PROFILE:-${TMPDIR:-/tmp}/lcars-s192-chrome/$LABEL}"
  rm -rf "$profile"; mkdir -p "$profile"
  "$CHROME" --remote-debugging-port=0 --user-data-dir="$profile" \
    --no-first-run --no-default-browser-check --window-size=1440,1000 \
    --disable-features=Translate,MediaRouter about:blank \
    >>"$OUT/chrome.log" 2>&1 &
  CPID=$!
  local i
  for i in $(seq 1 200); do
    [ -f "$profile/DevToolsActivePort" ] && { DEV_PORT="$(head -1 "$profile/DevToolsActivePort")"; break; }
    sleep 0.1
  done
  [ -n "$DEV_PORT" ] || { echo "SKIP 77: chrome never became drivable"; return 77; }
  say "chrome: devtools $DEV_PORT (pid $CPID, HEADED)"
}

boot_daemon || exit 1
boot_chrome || exit 77

probe() { # phase [extra argv…]
  node "$HERE/shot-probe.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" \
       --out "$OUT" --phase "$@" 2>&1 | tee -a "$RUNLOG"
  return "${PIPESTATUS[0]}"
}

# --- small repo readers (escape-aware; s185's lesson) ----------------------
json_str_of() { # file key
  sed -En 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$1" \
    | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}
init_mission_id() {
  local d
  for d in "$REPO"/.git/lcars/missions/*/; do
    [ -d "$d" ] || continue
    grep -q '"missionType"[[:space:]]*:[[:space:]]*"initialization"' "$d/state.json" 2>/dev/null \
      && { basename "$d"; return 0; }
  done
  return 1
}
mission_stage() { json_str_of "$REPO/.git/lcars/missions/$1/state.json" stage; }

# A phase clears its OWN outputs before it runs. Without this a re-run whose
# probe crashed still found the PREVIOUS run's readout on disk and reported it
# as this run's result (measured in smoke).
phase_clean() { local g; for g in "$@"; do rm -f "$OUT"/$g.png "$OUT"/$g.json "$OUT"/$g.txt; done; }

FAILS=0
bad() { FAILS=$((FAILS+1)); say "  FAIL $*"; }
ok()  { say "  ok   $*"; }

# ===========================================================================
# PHASE 1 — THE FRONT DOOR (shot 01)
# The picture the captain most wants: on a blank repo the BOARD IS REPLACED by
# the day-zero screen. The readout proves it — a visible front door and ZERO
# visible board columns/cards.
# ===========================================================================
if want front-door; then
  step "PHASE front-door — shot 01"
  phase_clean "01-front-door" "00-never-painted"
  probe front-door
  rc=$?
  if [ -f "$OUT/01-front-door.json" ]; then
    if grep -q '"frontDoorVisible": true' "$OUT/01-front-door.json" \
       && grep -q '"visibleColumns": 0' "$OUT/01-front-door.json"; then
      ok "01 the front door REPLACES the board (front door visible, 0 visible columns)"
    else
      bad "01 the board rendered (or the door did not) — see $OUT/01-front-door.json"
    fi
  else
    bad "01 no readout written (probe rc=$rc)"
  fi
fi

# ===========================================================================
# PHASE 2 — THE LIVE GRILL + ACCEPT (shots 02..NN, 20, 30)
# The real model asks its real questions through the shipping front end. The
# recommendation on screen is the LIVE one; nothing here is stubbed.
# ===========================================================================
if want grill; then
  step "PHASE grill — shots 02..NN (turns), 20 (recommendation), 30 (board after accept)"
  phase_clean "02-grill-*" "20-recommendation" "30-board-after-accept"
  probe grill --answers "$ANSWERS_FILE" --idea "$(cat "$IDEA_FILE")" \
        --turns "$TURNS" --turn-ms "$((TURN_TIMEOUT * 1000))"
  rc=$?
  MID="$(init_mission_id || true)"
  if [ -n "${MID:-}" ]; then
    ok "30 the initialization mission exists on disk: $MID (stage $(mission_stage "$MID"))"
    WB="$(json_str_of "$REPO/.git/lcars/missions/$MID/state.json" workerBin)"
    say "  state.json workerBin = ${WB:-<absent>}"
    case "$(basename "${WB:-}")" in
      copilot) ok "engine pin 4/4: the mission's OWN persisted workerBin is copilot" ;;
      *) bad "the mission persisted workerBin='${WB:-<absent>}' — NOT copilot. REFUSING to run it (this is the slot that beat an env var and billed \$11.39)." ;;
    esac
  else
    bad "no initialization mission was filed — the accept did not land"
  fi
fi

# ===========================================================================
# PHASE 3 — THE RUN (shots 40-run-NN)
# Clicks the board's "▶ Start", which is `run.sh drive --mission <id>` — the
# STAGE driver, never `implement-ticket`. Then photographs the board every
# RUN_EVERY seconds while waves/tickets move, until Verify or a human gate.
# ===========================================================================
if want run; then
  step "PHASE run — shots 40-run-NN (the board while the mission runs)"
  phase_clean "40-run-*"
  MID="${MID:-$(init_mission_id || true)}"
  if [ -z "${MID:-}" ]; then
    bad "run: no initialization mission on disk — run the grill phase first"
  else
    WB="$(json_str_of "$REPO/.git/lcars/missions/$MID/state.json" workerBin)"
    case "$(basename "${WB:-}")" in
      copilot) : ;;
      *) bad "run: REFUSING — mission workerBin='${WB:-<absent>}' is not copilot"; MID="" ;;
    esac
  fi
  if [ -n "${MID:-}" ]; then
    say "  starting mission $MID from the BOARD (▶ Start → run.sh drive --mission)"
    probe run --mission "$MID" --budget "$RUN_BUDGET" --every "$RUN_EVERY"
    say "  stage now: $(mission_stage "$MID")"
  fi
fi

# ===========================================================================
# PHASE 4 — VERIFY (shot 50)
# ===========================================================================
if want verify; then
  step "PHASE verify — shot 50 (the board at Verify)"
  phase_clean "50-verify"
  MID="${MID:-$(init_mission_id || true)}"
  probe verify --mission "${MID:-}"
  say "  stage: $(mission_stage "${MID:-}")"
fi

# ===========================================================================
# PHASE 5 — APPROVE (shot 60)
# `lcars approve` MERGES the PR and PROMOTES the established test command into
# repo config — the graduation. Run through the real skill script, on the real
# remote, then photographed: the board with the repo UNLOCKED.
# ===========================================================================
if want approve; then
  step "PHASE approve — the repo graduates (shot 60)"
  phase_clean "60-approved-unlocked"
  MID="${MID:-$(init_mission_id || true)}"
  if [ -z "${MID:-}" ]; then
    bad "approve: no initialization mission"
  else
    ( cd "$REPO" && env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT PATH="$SHIM:$PATH" \
        LCARS_WORKER_BIN="$SHIM/copilot" \
        bash "$LCARS_SRC/skills/lcars-approve/approve.sh" "$MID" ) \
      >"$OUT/60-approve.txt" 2>&1
    say "  approve rc=$? (transcript: $OUT/60-approve.txt)"
    tail -5 "$OUT/60-approve.txt" | sed 's/^/  | /' | tee -a "$RUNLOG"
    if grep -q '"testCommand"' "$REPO/.git/lcars/config.json" 2>/dev/null; then
      ok "60 the repo GRADUATED — testCommand promoted into config.json: $(json_str_of "$REPO/.git/lcars/config.json" testCommand)"
    else
      bad "60 config.json has no testCommand — the repo did not graduate"
    fi
    probe approve --mission "$MID"
  fi
fi

# ===========================================================================
# PHASE 6 — A NORMAL MISSION ON THE NEW FOUNDATION (shots 70, 71)
# The point of the whole loop: ordinary work now files and runs on a repo that
# had nothing an hour ago.
# ===========================================================================
if want normal; then
  step "PHASE normal — a normal mission on the new foundation (shots 70, 71)"
  phase_clean "70-normal-filed" "71-normal-run-*"
  if [ ! -f "$NORMAL_PRD" ]; then
    bad "normal: no PRD fixture at $NORMAL_PRD"
  else
    ( cd "$REPO" && env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT PATH="$SHIM:$PATH" \
        LCARS_WORKER_BIN="$SHIM/copilot" \
        bash "$LCARS_SRC/skills/lcars-file/file.sh" --prd "$NORMAL_PRD" \
             --engine copilot ) >"$OUT/70-file-normal.txt" 2>&1
    say "  file rc=$? (transcript: $OUT/70-file-normal.txt)"
    NMID="$(ls -t "$REPO/.git/lcars/missions" 2>/dev/null | while read -r m; do
              grep -q '"missionType"' "$REPO/.git/lcars/missions/$m/state.json" 2>/dev/null || { echo "$m"; break; }
            done)"
    if [ -n "${NMID:-}" ]; then
      ok "70 a NORMAL mission filed on the new foundation: $NMID"
      probe normal --mission "$NMID" --budget "${S192_NORMAL_BUDGET:-1800}" --every "$RUN_EVERY"
    else
      bad "70 no normal mission filed — the foundation gate may still be locked"
      probe normal --mission ""
    fi
  fi
fi

# ===========================================================================
# THE REPORT — hires, cost, and the engine verdict
# ===========================================================================
step "REPORT"
CS="$(spawns_run "$SPAWNLOG" copilot "$RUN_MARK")"
CL="$(spawns_run "$SPAWNLOG" claude  "$RUN_MARK")"
HG="$(hangs_run  "$SPAWNLOG" "$RUN_MARK")"
say "worker spawns THIS RUN: copilot=$CS  claude=$CL  hangs(retried)=$HG"
say "worker spawns CUMULATIVE (all invocations for this label): copilot=$(spawns_of "$SPAWNLOG" copilot)  claude=$(spawns_of "$SPAWNLOG" claude)"
awk -F'\t' '$1=="TURN"{printf "  turn %-14s rc=%-3s credits=%-14s resume=%s\n",$2,$3,$4,$5}' "$SPAWNLOG" \
  | tee -a "$RUNLOG"
if [ "$CL" -eq 0 ]; then
  ok "ZERO claude spawns — nothing billed"
else
  bad "$CL CLAUDE SPAWN(S) THIS RUN — the fence caught them (exit 97, unbilled) but something tried to bill:"
  awk -F'\t' '$1=="SPAWN" && $2=="claude"{print "    "$0}' "$SPAWNLOG" | tee -a "$RUNLOG"
fi
say ""
say "shots + readouts: $OUT"
ls "$OUT"/*.png 2>/dev/null | sed 's/^/  /' | tee -a "$RUNLOG"
say ""
say "failures: $FAILS"
[ "$FAILS" -eq 0 ]
