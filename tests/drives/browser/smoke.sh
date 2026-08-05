#!/usr/bin/env bash
# ============================================================================
# REAL-CHROME BOARD SMOKE — one command, real browser, screenshot to look at.
#
#   bash tests/drives/browser/smoke.sh
#
# WHY THIS EXISTS. On 2026-08-02, S163's fix round 5 deleted `.then(render)`
# from `refresh()` in web/static/board.js while inserting a comment beside it.
# The viewscreen was a PERMANENTLY BLANK PAGE for three fix rounds while 1,162
# unit tests and six tester rounds stayed green — because every harness under
# web/tests/ calls `render()` itself, so not one of them ever asked the app to
# paint. Real Chrome found it in about five minutes. That rig was then thrown
# away, and S140's headed-Chrome rig before it, so the equipment gets rebuilt
# from scratch every round. This is that rig, committed.
#
# WHAT IT PROVES: booting the SHIPPING front end against a REAL daemon in REAL
# Chrome produces REAL, laid-out, visible card nodes in the REAL DOM.
#
# WHAT IT DOES NOT PROVE — plainly, because the last blind spot cost three hours
# precisely because nobody wrote down what the harness could not see: it proves
# the board PAINTS, not that it is CORRECT. Wrong copy, a wrong pill, a card in
# the wrong column, an ugly layout, a control that does nothing — all of it
# passes here. THE TESTER STILL OPENS THE SCREENSHOT AND LOOKS. This rig only
# removes the excuse for never having looked at all.
#
# ZERO TOKENS. The fixture board is planted on disk; the only `claude`/`copilot`
# on PATH are logging shims (never an env var — the daemon's align path can
# override LCARS_WORKER_BIN from a REQUEST BODY, so the env is not a safe pin).
# The rig issues GETs only; a non-zero shim count means something spawned a
# worker and is worth investigating.
#
# EXIT: 0 painted · 1 did not paint (a real failure) · 3 painted but the app was
# served INCOMPLETE (a stylesheet 404'd — you are looking at a phantom) · 4 the
# board painted but the HOLODECK check failed (only possible under
# LCARS_BROWSER_HOLODECK_CHECK, and it says WHY) · 77 SKIPPED / infrastructure,
# loudly, with the reason named. 77 is never a pass.
#
# Exit 1 is an ACCUSATION AGAINST THE BOARD, so nothing that is the rig's own
# problem is allowed to leave through it. A rig whose whole purpose is to stop
# harness trouble being blamed on the product must not do it itself: Chrome
# refusing to become drivable, a nonsense timeout, a driver crash — all 77.
#
# ENV
#   LCARS_BROWSER_CHROME    Chrome binary (default: the installed Google Chrome)
#   LCARS_BROWSER_OUT       artifact dir (default: a fresh mktemp -d, printed)
#   LCARS_BROWSER_WEB_DIR   the web/ app root to serve (default: this repo's).
#                           This is the CALIBRATION SEAM — see calibrate.sh. A
#                           copy is made FAITHFUL here (see ensure_shared_css).
#   LCARS_BROWSER_EXPECT    visible cards required (default: 2 = the fixture)
#   LCARS_BROWSER_HEADED=1  run a visible Chrome window instead of headless
#   LCARS_BROWSER_TIMEOUT   ms to wait for the paint (default 30000, min 2000 —
#                           below that nothing could be proven, so it is a skip)
#   LCARS_BROWSER_BASEFRESH       (S164) path to a base-freshness record JSON.
#                           Planted as a STUB reporter the daemon shells for
#                           GET /api/base-freshness, so the pre-flight can be
#                           driven at a chosen repo state without one existing.
#   LCARS_BROWSER_LEGEND_CHECK    (S168) path to an expectation JSON. Makes the
#                           driver MEASURE the board's bottom legend swatches —
#                           resolved background colour, real box, contrast
#                           against what is behind them. Unset = the rig behaves
#                           exactly as it did before.
#   LCARS_BROWSER_ORIGIN    (S168) make the fixture a REAL git repo with this
#                           origin remote (or "-" for a real repo with none).
#                           The daemon reads it to decide which FORGE the board's
#                           "view on GitHub" links point at. Offline: naming a
#                           remote never contacts it. Unset = not a git repo, as
#                           before.
#   LCARS_BROWSER_LOGBUG=1  (S168) plant a third mission — a LOGGED BUG child —
#                           whose card carries the board's OTHER GitHub link.
#                           Changes the fixture's card count; set EXPECT to 3.
#   LCARS_BROWSER_GHLINK_CHECK    (S168) path to an expectation JSON. Makes the
#                           driver read the RESOLVED href off every GitHub link
#                           in the live DOM (board card badge + detail header).
#   LCARS_BROWSER_HOLODECK_CHECK  (S125) path to an expectation JSON. Makes the
#                           driver CLICK into the holodeck, open a program
#                           through the real dialog, and MEASURE the deck: the
#                           board actually gone, three laid-out panes, the
#                           preview iframe's src and its sandbox flags, and the
#                           board back after ▦ BOARD. Unset = the rig behaves
#                           exactly as it did before. See holodeck.sh.
#   LCARS_BROWSER_CONSOLE_CHECK   (S164) path to an expectation JSON. Makes the
#                           driver open the File console and MEASURE its
#                           pre-flight line in the real cascade. Unset = the rig
#                           behaves exactly as it did before.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WEB_DIR="${LCARS_BROWSER_WEB_DIR:-$REPO/web}"
EXPECT="${LCARS_BROWSER_EXPECT:-2}"
TIMEOUT_MS="${LCARS_BROWSER_TIMEOUT:-30000}"
PY_BIN="${LCARS_PYTHON_BIN:-python3}"
NODE_BIN="${LCARS_NODE_BIN:-node}"

# Artifacts are KEPT on purpose — the screenshot IS the deliverable, and a run
# you cannot look at afterwards is not evidence. Kept, but BOUNDED: before
# minting its own, a run prunes its older siblings so they cannot pile up in
# /var/folders forever. Only dirs matching this rig's own mktemp pattern are
# touched, and only when we are the one minting (an explicit LCARS_BROWSER_OUT
# means the caller is managing the artifacts and we keep our hands off).
prune_artifacts() {   # $1 = mktemp prefix, $2 = how many dirs may remain AFTER
  local d n=0 tmp="${TMPDIR:-/tmp}" keep=$(( $2 - 1 ))   # …this run mints its own
  for d in $(ls -dt "$tmp/$1".?????? 2>/dev/null); do
    n=$((n + 1))
    [ "$n" -le "$keep" ] && continue
    case "$d" in "$tmp/$1".??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
}

if [ -n "${LCARS_BROWSER_OUT:-}" ]; then
  OUT="$LCARS_BROWSER_OUT"
else
  prune_artifacts lcars-browser 5
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser.XXXXXX")"
fi
mkdir -p "$OUT"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
skip() {
  printf '\n\033[33m════ SKIPPED — the board was NOT checked in a browser ════\033[0m\n'
  printf '  %s\n' "$1"
  printf '  This is NOT a pass. Nothing about the board has been proven.\n\n'
  exit 77
}

DAEMON_PID=""; CHROME_PID=""; DAEMON_PORT=""
record_pids() {
  cat >"$OUT/pids.json" <<EOF
{"daemonPid": ${DAEMON_PID:-0}, "chromePid": ${CHROME_PID:-0}, "daemonPort": ${DAEMON_PORT:-0}}
EOF
}
# Teardown runs on EVERY exit path — pass, fail, ^C, or a mid-run error. The
# daemon has honoured a plain SIGTERM since 78450eb; the -9 is a backstop, and a
# daemon that needs it is a REGRESSION worth reporting, not working around.
cleanup() {
  local rc=$?
  record_pids
  for pid in "$CHROME_PID" "$DAEMON_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null
  done
  local waited=0
  while [ "$waited" -lt 30 ]; do
    local alive=0
    for pid in "$CHROME_PID" "$DAEMON_PID"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1; waited=$((waited + 1))
  done
  # …and it NAMES WHICH PROCESS (fix round 1b). The old message said "if this is
  # the daemon, that is a REGRESSION" and left the reader to match a bare pid
  # against pids.json — so it printed twice during a calibration run and was read
  # by nobody. Both of those were CHROME, which is routine: headless Chrome's
  # launcher regularly outlives a SIGTERM while its zygote children go down.
  # A regression detector nobody reads is not a detector, so the two cases are
  # now different messages, and only the daemon's is loud.
  local daemon_ignored_sigterm=0
  if [ -n "$CHROME_PID" ] && kill -0 "$CHROME_PID" 2>/dev/null; then
    printf '  note: chrome (pid %s) outlived SIGTERM — SIGKILLing it. Routine for\n' "$CHROME_PID"
    printf '        headless Chrome, and nothing to do with the daemon signal fix.\n'
    kill -9 "$CHROME_PID" 2>/dev/null
  fi
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    printf '\033[31m  THE DAEMON (pid %s) IGNORED SIGTERM\033[0m — SIGKILLing it. That is a\n' "$DAEMON_PID"
    printf '  REGRESSION of the 78450eb signal fix, and this run fails on it.\n'
    kill -9 "$DAEMON_PID" 2>/dev/null
    daemon_ignored_sigterm=1
  fi
  wait 2>/dev/null
  record_pids
  # A run that passed only because nobody read its own teardown is not a pass.
  # `exit` is what actually sets the status from inside an EXIT trap — a `return`
  # here is discarded, which is half of why this warning was survivable.
  if [ "$daemon_ignored_sigterm" -eq 1 ] && [ "$rc" -eq 0 ]; then
    exit 1
  fi
  return $rc
}
trap cleanup EXIT INT TERM

# ── preconditions ───────────────────────────────────────────────────────────
[ -x "$CHROME" ] || skip "no runnable Chrome at: $CHROME
  Install Google Chrome, or point LCARS_BROWSER_CHROME at the binary."
command -v "$NODE_BIN" >/dev/null 2>&1 || skip "node not found ($NODE_BIN) — the CDP driver needs it."
command -v "$PY_BIN"  >/dev/null 2>&1 || skip "python3 not found ($PY_BIN) — the daemon needs it."
[ -f "$WEB_DIR/static/board.js" ] || skip "no board.js under $WEB_DIR/static (bad LCARS_BROWSER_WEB_DIR?)"

# A timeout too small to reach a first DOM probe is a RIG MISCONFIGURATION, and
# the honest answer to one is a skip. Left unchecked it produced the rig's worst
# possible output: "the board did not paint", exit 1, about a board that was
# never asked. Configuration trouble is never the product's fault.
case "$TIMEOUT_MS" in
  ''|*[!0-9]*) skip "LCARS_BROWSER_TIMEOUT must be a whole number of ms; got '$TIMEOUT_MS'." ;;
esac
[ "$TIMEOUT_MS" -ge 2000 ] || skip "LCARS_BROWSER_TIMEOUT=$TIMEOUT_MS is too short to boot a
  browser and probe a page — nothing could be proven at that budget. Use >= 2000."

WEB_DIR="$(cd "$WEB_DIR" && pwd)"

say "LCARS real-Chrome board smoke"
note "artifacts: $OUT"
note "serving:   $WEB_DIR"

# ── the calibration seam must serve the WHOLE app, not most of it ───────────
# The daemon resolves the SHARED ADR-007 token stylesheet as <web-dir>/../docs/
# lcars.css (server.py `_SHARED_CSS`, two levels up from the module). A plain
# `cp -R web/` copy — the documented seam, and what calibrate.sh does — has no
# sibling docs/, so /lcars.css 404s and EVERY --lcars-* token vanishes. The
# board still paints (board.css uses var(--lcars-x, fallback) throughout), so it
# still PASSES, while the title goes yellow-on-yellow, the header pills lose
# their teal and the legend swatches disappear. A visual rig whose own seam
# silently drops the token stylesheet is the S162 disease with the rig's badge
# on: a tester chasing a look-and-feel bug through the seam is looking at a
# phantom. So make the copy FAITHFUL. Deliberately fixed HERE and not in
# server.py: the daemon is shipped production code and changing how it resolves
# the shared sheet has a blast radius far past this rig. cdp.js then FAILS LOUD
# (exit 3) if a stylesheet 404s anyway, so this can never be silent again.
if [ "$WEB_DIR" != "$REPO/web" ]; then
  SEAM_ROOT="$(cd "$WEB_DIR/.." && pwd)"
  if [ ! -f "$SEAM_ROOT/docs/lcars.css" ]; then
    if mkdir -p "$SEAM_ROOT/docs" 2>/dev/null &&
       cp "$REPO/docs/lcars.css" "$SEAM_ROOT/docs/lcars.css" 2>/dev/null; then
      note "seam:      placed the shared token stylesheet at $SEAM_ROOT/docs/lcars.css"
    else
      note "seam:      WARNING could not place docs/lcars.css beside $WEB_DIR —"
      note "           the board will be served UNSTYLED (the run will say so)."
    fi
  fi
fi

# ── zero-spend PATH shim (both engines, never an env var) ───────────────────
mkdir -p "$OUT/shim"
for engine in claude copilot; do
  cat >"$OUT/shim/$engine" <<EOF
#!/usr/bin/env bash
echo "$engine \$*" >>"$OUT/worker-shim.log"
echo "SMOKE RIG: a worker was spawned. This rig is read-only; investigate." >&2
exit 1
EOF
  chmod +x "$OUT/shim/$engine"
done
: >"$OUT/worker-shim.log"
export PATH="$OUT/shim:$PATH"

# S125 fix round 1 — a rig that DRIVES A TURN needs a worker that answers.
# The shim above exists to prove nothing spawns; a drive of the holodeck's
# grounding→design journey must actually spawn something, so holodeck.sh hands
# in its own SCRIPTED stub (still zero tokens — a python script, no engine).
# Unset ⇒ the shim, and every existing rig is byte-for-byte what it was.
WORKER_BIN="${LCARS_BROWSER_WORKER_BIN:-$OUT/shim/claude}"

# ── a fixture board on disk: two missions, no git, no gh, no model ──────────
FIXTURE="$OUT/fixture"
mkdir -p "$FIXTURE"

# S168: the fixture is normally NOT a git repo at all (nothing here needs one).
# LCARS_BROWSER_ORIGIN makes it a REAL one with a REAL origin remote, which is
# what the daemon reads to decide which FORGE its "view on GitHub" links point
# at. Naming a remote never contacts it, so this stays entirely offline — the
# whole enterprise-host question is answerable with no network and no account.
#   <url>  a real git repo whose origin is that url
#   -      a real git repo with NO origin remote (the degenerate case)
#   unset  today's behaviour exactly: not a git repo at all
FIX_ORIGIN="${LCARS_BROWSER_ORIGIN:-}"
if [ -n "$FIX_ORIGIN" ]; then
  ( cd "$FIXTURE" && git init -q . && git config user.email t@t &&
    git config user.name t ) >/dev/null 2>&1 ||
    skip "could not git init the fixture at $FIXTURE"
  if [ "$FIX_ORIGIN" != "-" ]; then
    ( cd "$FIXTURE" && git remote add origin "$FIX_ORIGIN" ) >/dev/null 2>&1 ||
      skip "could not set the fixture's origin to $FIX_ORIGIN"
    note "fixture:   origin $FIX_ORIGIN"
  else
    note "fixture:   a real git repo with NO origin remote"
  fi
fi

mkdir -p "$FIXTURE/.git/lcars/missions"
cat >"$FIXTURE/.git/lcars/config.json" <<EOF
{"lcarsVersion": "$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)",
 "repo": "acme/browser-smoke", "testCommand": "true"}
EOF
plant_mission() {  # id issue title stage
  local d="$FIXTURE/.git/lcars/missions/$1"
  mkdir -p "$d"
  cat >"$d/state.json" <<EOF
{"id": "$1", "type": "feature", "title": "$3", "stage": "$4",
 "created": "2026-08-02T10:00:00Z", "model": "claude", "githubIssue": $2,
 "branch": "lcars/$1", "base": "main"}
EOF
}
plant_mission "lcars-20260802-001" 4101 "Smoke: a mission in flight" "implement"
plant_mission "lcars-20260802-002" 4102 "Smoke: a mission awaiting review" "verify"

# S168: a LOGGED BUG child, only when asked for. Its card carries the second of
# the board's two GitHub links — the "⊗ BUG · child of #<parent>" badge, which
# links to the PARENT's issue. Off by default (it would change the fixture's
# mission count, and every other caller's LCARS_BROWSER_EXPECT with it).
if [ "${LCARS_BROWSER_LOGBUG:-}" = "1" ]; then
  LB="$FIXTURE/.git/lcars/missions/lcars-20260802-003"
  mkdir -p "$LB"
  cat >"$LB/state.json" <<EOF
{"id": "lcars-20260802-003", "type": "bug", "title": "Smoke: a logged bug",
 "stage": "implement", "created": "2026-08-02T11:00:00Z", "model": "claude",
 "githubIssue": 4103, "branch": "lcars/lcars-20260802-003", "base": "main",
 "linked": true, "parentMission": "lcars-20260802-001"}
EOF
  note "fixture:   + a logged-bug child card (its badge links to the parent issue)"
fi

# ── S164: a STUB base-freshness reporter, when one is asked for ─────────────
# The daemon shells the SHARED reporter (skills/lcars-init/base-freshness.sh)
# for GET /api/base-freshness and resolves it injected → LCARS_BASE_FRESHNESS_
# SCRIPT → in-repo → installed (local_adapter._resolve_base_freshness_script).
# Pointing that env at a stub is how a given repo STATE — one commit behind, a
# dirty tree, an unreachable origin — is put in front of a real browser without
# constructing the git situation that produces it. The record is the guard's
# own JSON either way; nothing here re-words a verdict.
BASEFRESH_REC="${LCARS_BROWSER_BASEFRESH:-}"
if [ -n "$BASEFRESH_REC" ]; then
  [ -f "$BASEFRESH_REC" ] || skip "LCARS_BROWSER_BASEFRESH points at no file: $BASEFRESH_REC"
  cp "$BASEFRESH_REC" "$OUT/basefresh-record.json"
  cat >"$OUT/basefresh-stub.sh" <<EOF
#!/usr/bin/env bash
cat "$OUT/basefresh-record.json"
EOF
  chmod +x "$OUT/basefresh-stub.sh"
  export LCARS_BASE_FRESHNESS_SCRIPT="$OUT/basefresh-stub.sh"
  note "basefresh: stub reporter serving $BASEFRESH_REC"
fi

# ── the daemon, on a FREE port (--port 0), against the fixture ──────────────
# --port 0 means the kernel picks; two runs back to back cannot collide, and the
# daemon prints the port it actually got.
# `python3 -m lcars_serve` must be imported from WEB_DIR, and STATIC_DIR is
# resolved relative to that package — which is exactly what makes WEB_DIR the
# calibration seam: point it at a patched copy and the patched board.js is what
# the browser downloads. The cd happens in the subshell so this shell's own
# relative paths are untouched.
( cd "$WEB_DIR" && exec env -u LCARS_SERVE_PORT \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$WORKER_BIN" LCARS_GH_BIN="$OUT/shim/claude" \
    "$PY_BIN" -m lcars_serve --port 0 --repo-root "$FIXTURE" ) \
  >"$OUT/daemon.log" 2>&1 &
DAEMON_PID=$!

# Wait on the daemon's own "I am serving at <url>" line — a real signal, not a
# sleep. It is the first thing main() prints after the socket is bound.
BOARD_URL=""
for _ in $(seq 1 150); do
  BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" 2>/dev/null | head -1)"
  [ -n "$BOARD_URL" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$BOARD_URL" ]; then
  printf '\n\033[31mFAILED\033[0m — the daemon never came up.\n'
  sed -n '1,20p' "$OUT/daemon.log"
  exit 1
fi
DAEMON_PORT="${BOARD_URL##*:}"; DAEMON_PORT="${DAEMON_PORT%/}"
record_pids
note "daemon:    $BOARD_URL (pid $DAEMON_PID)"

# ── real Chrome, its own throwaway profile, its own free devtools port ──────
# --remote-debugging-port=0 lets Chrome pick and write the real port into
# DevToolsActivePort inside the profile dir: collision-free by construction, and
# a file whose appearance is the "devtools is listening" signal.
HEADLESS_FLAG="--headless=new"
[ "${LCARS_BROWSER_HEADED:-}" = "1" ] && HEADLESS_FLAG=""
PROFILE="$OUT/chrome-profile"
mkdir -p "$PROFILE"
# Any DevToolsActivePort here now is from a PREVIOUS run of this profile dir and
# is a lie waiting to be believed. Chrome will rewrite it.
rm -f "$PROFILE/DevToolsActivePort"
"$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port=0 \
  $HEADLESS_FLAG \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1440,1000 \
  about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!
record_pids

# DevToolsActivePort is written by Chrome, not for us, and reading it naively is
# a RACE — measured on a cold headed launch (with GoogleUpdater starting), the
# rig read one port while chrome.log showed Chrome listening on another, then
# reported "the board did not paint" about a board that was fine. So: (1) the
# file is only believed once the browser ws path has arrived after the port —
# see try_devtools_port for why that is a CONTENT test and never a line COUNT;
# (2) the port must actually ANSWER /json/version before it is
# trusted; (3) on any failure we go back and RE-READ, because Chrome may have
# rewritten the file, rather than committing to the first value seen.
port_answers() {   # $1 = port. True only if Chrome's devtools endpoint is there.
  "$NODE_BIN" -e '
    fetch("http://127.0.0.1:" + process.argv[1] + "/json/version",
          { signal: AbortSignal.timeout(2000) })
      .then((r) => r.json())
      .then((j) => process.exit(j && j.webSocketDebuggerUrl ? 0 : 1))
      .catch(() => process.exit(1));
  ' "$1" >/dev/null 2>&1
}
DEV_PORT=""
SEEN_PORT=""   # the last syntactically-valid port we read, for the diagnostic
# Sets DEV_PORT (globals, NOT a subshell — SEEN_PORT has to survive the call).
try_devtools_port() {
  local f="$PROFILE/DevToolsActivePort" p ws
  DEV_PORT=""
  [ -s "$f" ] || return 1
  p="$(sed -n 1p "$f" | tr -d '[:space:]')"
  ws="$(sed -n 2p "$f" | tr -d '[:space:]')"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -gt 0 ] || return 1
  # The SECOND line is the completeness test: Chrome writes "<port>\n<ws-path>"
  # with NO trailing newline, so line-COUNTING lies (a finished file reports one
  # newline). A file that is only the port is a mid-write snapshot; the ws path
  # arriving is what says Chrome has finished with it.
  case "$ws" in /devtools/*) ;; *) return 1 ;; esac
  SEEN_PORT="$p"
  port_answers "$p" || return 1
  DEV_PORT="$p"
  return 0
}

DEV_DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEV_DEADLINE" ]; do
  try_devtools_port && break
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.2
done
if [ -z "$DEV_PORT" ]; then
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    skip "Chrome exited immediately and never opened a devtools port.
  binary: $CHROME
  $(sed -n '1,5p' "$OUT/chrome.log" 2>/dev/null)"
  fi
  if [ -n "$SEEN_PORT" ]; then
    skip "Chrome wrote devtools port $SEEN_PORT but nothing ever answered
  /json/version there. This is the RIG's problem, not the board's — the board
  was never opened. chrome.log: $OUT/chrome.log
  $(sed -n '1,5p' "$OUT/chrome.log" 2>/dev/null)"
  fi
  skip "Chrome started but never wrote a complete DevToolsActivePort — cannot
  drive it. binary: $CHROME"
fi
note "chrome:    devtools :$DEV_PORT (pid $CHROME_PID)"

# ── drive it ────────────────────────────────────────────────────────────────
DRIVE_ARGS=()
if [ -n "${LCARS_BROWSER_LEGEND_CHECK:-}" ]; then
  [ -f "$LCARS_BROWSER_LEGEND_CHECK" ] || \
    skip "LCARS_BROWSER_LEGEND_CHECK points at no file: $LCARS_BROWSER_LEGEND_CHECK"
  DRIVE_ARGS+=(--legend-check "$LCARS_BROWSER_LEGEND_CHECK")
  note "legend:    the bottom legend's colour swatches will be measured too"
fi
if [ -n "${LCARS_BROWSER_CONSOLE_CHECK:-}" ]; then
  [ -f "$LCARS_BROWSER_CONSOLE_CHECK" ] || \
    skip "LCARS_BROWSER_CONSOLE_CHECK points at no file: $LCARS_BROWSER_CONSOLE_CHECK"
  DRIVE_ARGS+=(--console-check "$LCARS_BROWSER_CONSOLE_CHECK")
  note "console:   the File console pre-flight will be measured too"
fi
if [ -n "${LCARS_BROWSER_HOLODECK_CHECK:-}" ]; then
  [ -f "$LCARS_BROWSER_HOLODECK_CHECK" ] || \
    skip "LCARS_BROWSER_HOLODECK_CHECK points at no file: $LCARS_BROWSER_HOLODECK_CHECK"
  DRIVE_ARGS+=(--holodeck-check "$LCARS_BROWSER_HOLODECK_CHECK")
  note "holodeck:  the ⬡ HOLODECK deck will be entered and MEASURED too"
fi
if [ -n "${LCARS_BROWSER_GHLINK_CHECK:-}" ]; then
  [ -f "$LCARS_BROWSER_GHLINK_CHECK" ] || \
    skip "LCARS_BROWSER_GHLINK_CHECK points at no file: $LCARS_BROWSER_GHLINK_CHECK"
  DRIVE_ARGS+=(--ghlink-check "$LCARS_BROWSER_GHLINK_CHECK")
  note "ghlinks:   the board's GitHub links will be read off the live DOM"
fi
"$NODE_BIN" "$HERE/cdp.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" \
  --out "$OUT" --expect "$EXPECT" --timeout "$TIMEOUT_MS" "${DRIVE_ARGS[@]+"${DRIVE_ARGS[@]}"}"
RC=$?

SHIM_CALLS=$(wc -l <"$OUT/worker-shim.log" 2>/dev/null | tr -d ' ')
printf '\n'
note "worker shim invocations: ${SHIM_CALLS:-0} (expected 0 — this rig only GETs)"
printf 'screenshot: %s/board.png\n' "$OUT"
[ -f "$OUT/legend.png" ] && printf 'screenshot: %s/legend.png  (the legend, close-up)\n' "$OUT"
[ -f "$OUT/gh-links.png" ] && printf 'screenshot: %s/gh-links.png  (the detail overlay + its GitHub link)\n' "$OUT"
[ -f "$OUT/file-console.png" ] && printf 'screenshot: %s/file-console.png  (the File console)\n' "$OUT"
[ -f "$OUT/holodeck.png" ] && printf 'screenshot: %s/holodeck.png  (THE HOLODECK — open this one)\n' "$OUT"
[ -f "$OUT/holodeck-back-on-board.png" ] && printf 'screenshot: %s/holodeck-back-on-board.png  (the board, after ▦ BOARD)\n' "$OUT"
note "result:     $OUT/result.json"
case "$RC" in
  0)
    printf '\033[32mPAINTED\033[0m — the board rendered in real Chrome. NOW OPEN THE SCREENSHOT\n'
    printf '        AND LOOK AT IT: this proves it paints, never that it is right.\n' ;;
  3)
    printf '\033[31mSERVED INCOMPLETE\033[0m — the board painted, but not with the app it ships\n'
    printf '        with. The screenshot is a picture of a PHANTOM, not of the product.\n' ;;
  4)
    # The board painted; the HOLODECK check is what failed, and cdp.js has just
    # printed each ✗ reason above. Saying "the board did not paint" here — which
    # is what the default branch used to do, two lines under this rig's own
    # "real Chrome painted N card node(s)" — is the exact lie this rig exists to
    # stop anyone telling.
    printf '\033[31mTHE HOLODECK IS WRONG\033[0m — the board painted fine; the deck did not\n'
    printf '        measure up. The reasons are printed above, in full in\n'
    printf '        %s/holodeck-check.json. Open %s/holodeck.png.\n' "$OUT" "$OUT" ;;
  77)
    # The driver could not reach a browser at all. That is the rig's failure and
    # it exits as one — this rig exists to stop harness trouble being reported as
    # a product defect, so it may never do that itself.
    printf '\n\033[33m════ SKIPPED — the board was NOT checked in a browser ════\033[0m\n'
    printf '  The driver never got a browser to drive (see above). This is an\n'
    printf '  INFRASTRUCTURE failure, not a verdict on the board.\n'
    printf '  This is NOT a pass. Nothing about the board has been proven.\n\n' ;;
  *)
    printf '\033[31mBLANK / WRONG\033[0m — the board did not paint. Open the screenshot; it is\n'
    printf '        a picture of exactly what the browser saw.\n' ;;
esac
exit "$RC"
