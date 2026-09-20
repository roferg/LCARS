#!/usr/bin/env bash
# S223 rig — the real daemon against a THROWAWAY fixture repo, with a PATH
# shim that fakes `claude`, `copilot` and `gh` (log argv, exit 1) so nothing
# this drive does can bill. Sourced, never run.
#
#   . tests/drives/s223/rig.sh
#   s223_start_daemon <fixture-repo> <out-dir>    # sets DAEMON_PID, BOARD_URL
#   s223_start_chrome <out-dir>                    # sets CHROME_PID, DEV_PORT
#   s223_teardown                                  # reaps ONLY the PIDs above
#   s223_shim_count <out-dir>                      # how many times a shim ran
#
# Never kills by name or pattern. The captain runs his own viewscreen daemon;
# this touches only the PIDs it started. Port 0 = a free port.
S223_REPO="${S223_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
S223_PIDS=""

s223_make_shim() { # <out-dir>
  local out="$1" b
  mkdir -p "$out/shim"
  for b in claude copilot gh; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/shim.log"\nexit 1\n' "$b" "$out" >"$out/shim/$b"
    chmod +x "$out/shim/$b"
  done
  : >>"$out/shim.log"
}

s223_shim_count() { grep -c '' "$1/shim.log" 2>/dev/null || echo 0; }

s223_start_daemon() { # <repo-root> <out-dir>
  local root="$1" out="$2" home="${S223_HOME:-}"
  mkdir -p "$out"; s223_make_shim "$out"
  local xo="$S223_REPO/skills/lcars-xo/xo.sh"
  ( cd "$S223_REPO/web" && exec env -u LCARS_SERVE_PORT \
      PATH="$out/shim:$PATH" ${home:+HOME="$home"} \
      LCARS_GH_BIN="$out/shim/gh" LCARS_WORKER_BIN="$out/shim/claude" \
      LCARS_CLAUDE_BIN="$out/shim/claude" LCARS_XO_SCRIPT="$xo" \
      GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
      LCARS_VERSION_STAMP="$out/stamp" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
      python3 -m lcars_serve --port 0 --repo-root "$root" ) \
    >"$out/daemon.log" 2>&1 &
  DAEMON_PID=$!
  S223_PIDS="$S223_PIDS $DAEMON_PID"
  BOARD_URL=""
  local i
  for i in $(seq 1 200); do
    BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$out/daemon.log" 2>/dev/null | head -1)"
    [ -n "$BOARD_URL" ] && break
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$BOARD_URL" ] || { echo "DAEMON never bound; see $out/daemon.log"; return 1; }
  echo "daemon pid=$DAEMON_PID url=$BOARD_URL"
}

s223_start_chrome() { # <out-dir>
  local out="$1" profile="$1/chrome-profile"
  mkdir -p "$profile"; rm -f "$profile/DevToolsActivePort"
  "$CHROME" --user-data-dir="$profile" --remote-debugging-port=0 --headless=new \
    --no-first-run --no-default-browser-check --no-service-autorun \
    --disable-background-networking --disable-sync --disable-extensions \
    --disable-component-update --disable-default-apps --disable-popup-blocking \
    --window-size=1600,1000 about:blank >"$out/chrome.log" 2>&1 &
  CHROME_PID=$!
  S223_PIDS="$S223_PIDS $CHROME_PID"
  DEV_PORT=""
  local deadline=$(( $(date +%s) + 40 )) p
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$profile/DevToolsActivePort" ]; then
      p="$(sed -n 1p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
      case "$p" in ''|*[!0-9]*) p="" ;; esac
      if [ -n "$p" ] && curl -sf --max-time 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
        DEV_PORT="$p"; break
      fi
    fi
    kill -0 "$CHROME_PID" 2>/dev/null || break
    sleep 0.2
  done
  [ -n "$DEV_PORT" ] || { echo "CHROME never opened devtools; see $out/chrome.log"; return 1; }
  echo "chrome pid=$CHROME_PID devtools=$DEV_PORT"
}

s223_teardown() {
  local pid
  for pid in $S223_PIDS; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
  sleep 1
  # The daemon ignores SIGTERM (memory: viewscreen-daemon-detach) — reap by PID.
  for pid in $S223_PIDS; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
  for pid in $S223_PIDS; do wait "$pid" 2>/dev/null; done
  S223_PIDS=""
}
