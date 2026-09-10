#!/usr/bin/env bash
# S196 tester rig — daemon + real headed Chrome, reusable by every drive.
# Sourced, never run. Inherits s190's daemon/Chrome discipline verbatim
# (recorded PIDs only, never kill by name).
REPO="${REPO:-/Users/roganferguson/Projects/LCARS}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
NODE_BIN="${NODE_BIN:-node}"
PY_BIN="${PY_BIN:-python3}"
S196_PIDS=""

start_daemon() { # <repo-root> <out-dir> [extra env assignments...]
  local root="$1" out="$2"; shift 2
  mkdir -p "$out"
  ( cd "$REPO/web" && exec env -u LCARS_SERVE_PORT "$@" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
      "$PY_BIN" -m lcars_serve --port 0 --repo-root "$root" ) \
    >"$out/daemon.log" 2>&1 &
  DAEMON_PID=$!
  S196_PIDS="$S196_PIDS $DAEMON_PID"
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

start_chrome() { # <out-dir>
  local out="$1" profile="$1/chrome-profile"
  mkdir -p "$profile"; rm -f "$profile/DevToolsActivePort"
  local headless="--headless=new"
  [ "${LCARS_BROWSER_HEADED:-1}" = "1" ] && headless=""
  "$CHROME" --user-data-dir="$profile" --remote-debugging-port=0 $headless \
    --no-first-run --no-default-browser-check --no-service-autorun \
    --disable-background-networking --disable-sync --disable-extensions \
    --disable-component-update --disable-default-apps --disable-popup-blocking \
    --window-size=1600,1100 about:blank >"$out/chrome.log" 2>&1 &
  CHROME_PID=$!
  S196_PIDS="$S196_PIDS $CHROME_PID"
  DEV_PORT=""
  local deadline=$(( $(date +%s) + 40 )) p ws
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$profile/DevToolsActivePort" ]; then
      p="$(sed -n 1p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
      ws="$(sed -n 2p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
      case "$p" in ''|*[!0-9]*) p="" ;; esac
      case "$ws" in /devtools/*) ;; *) p="" ;; esac
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

s196_teardown() {
  local pid
  for pid in $S196_PIDS; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in $S196_PIDS; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
  S196_PIDS=""
}
