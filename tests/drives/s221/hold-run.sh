#!/usr/bin/env bash
# S221 fix 5 — cold-to-verdict proof that `{"press":…,"hold":MS}` walks a
# character, and that the same action WITHOUT `hold` does not.
#
#   bash tests/drives/s221/hold-run.sh [<out-dir>]
#
# Boots the example game on Vite and a headless Chrome, then runs the REAL
# skills/lcars-xo/xo-drive.js against it twice — tap and hold — and measures
# how far the character actually moved. Adapted from the S221 control rig,
# which established the boot recipe and the scene-graph probe.
#
# ZERO SPEND: no worker CLI is involved anywhere. It is a browser and a game.
#
# PIDS: every process this starts is recorded and killed BY PID on the way out.
# Never by name or pattern — the captain runs his own daemons.
#
# THE TARGET REPO IS READ-ONLY. It is cloned from nothing, written to never;
# the drive only serves it and looks at it.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/lcars-s221-hold}"
# THE BUILD UNDER THE DRIVE: the captain's own capstone checkout, READ-ONLY and
# UNMODIFIED. $S221_GAME_DIR can point it somewhere else, which is how it was
# run for one round while `xo-drive.js` still refused a page with no DOM text —
# this game is canvas-only, so the driver exited 1 before a single action ran.
# That gate now asks "did anything RENDER" instead (S221 fix 6), so the real
# repo works as-is and the override is a convenience, not a workaround.
GAME="${S221_GAME_DIR:-${GROUTWORK_REPO:-$HOME/Projects/groutwork-capstone}/example-game}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
HOLD_MS="${S221_HOLD_MS:-250}"

[ -x "$GAME/node_modules/.bin/vite" ] || {
  echo "no vite in $GAME — set \$GROUTWORK_REPO to the capstone checkout"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/shots"
STARTED=""
cleanup() {
  local p
  for p in $STARTED; do kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; done
  sleep 1
  for p in $STARTED; do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

# --- 1. the game, on Vite -------------------------------------------------
( cd "$GAME" && exec ./node_modules/.bin/vite --host 127.0.0.1 ) >"$OUT/vite.log" 2>&1 &
VITE_PID=$!; STARTED="$STARTED $VITE_PID"
URL=""
for _ in $(seq 1 150); do
  URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/vite.log" | head -1)"
  [ -n "$URL" ] && break
  kill -0 "$VITE_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$URL" ] || { echo "vite never bound; see $OUT/vite.log"; exit 1; }
echo "game at $URL (pid $VITE_PID)"

# --- 2. headless Chrome ----------------------------------------------------
# TWO FLAGS THAT ARE NOT OPTIONAL HERE, both learned the hard way:
#   swiftshader — Pixi's WebGL is unreliable in headless Chrome without it.
#   a window >=900px — below that the camera un-pins from the map and every
#   position read is wrong.
PROFILE="$OUT/chrome-profile"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=0 --headless=new \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --use-gl=swiftshader --enable-unsafe-swiftshader \
  --window-size=1200,1000 about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!; STARTED="$STARTED $CHROME_PID"
DEV_PORT=""
for _ in $(seq 1 200); do
  if [ -s "$PROFILE/DevToolsActivePort" ]; then
    p="$(sed -n 1p "$PROFILE/DevToolsActivePort" | tr -d '[:space:]')"
    case "$p" in ''|*[!0-9]*) p="" ;; esac
    if [ -n "$p" ] && curl -sf --max-time 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
      DEV_PORT="$p"; break
    fi
  fi
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$DEV_PORT" ] || { echo "chrome never opened devtools; see $OUT/chrome.log"; exit 1; }
echo "chrome pid $CHROME_PID devtools $DEV_PORT"

# --- 3. drive the REAL xo-drive.js, twice ---------------------------------
node "$HERE/hold.js" --devtools-port "$DEV_PORT" --url "$URL" \
  --out "$OUT/shots" --hold "$HOLD_MS" \
  --drive "$REPO_ROOT/skills/lcars-xo/xo-drive.js" >"$OUT/hold.json" 2>&1
rc=$?
python3 - "$OUT/hold.json" <<'PY' || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception:
    print(open(sys.argv[1]).read()[-2000:]); raise SystemExit(0)
if d.get("error"):
    print("ERROR:", d["error"][:800])
    d = d.get("out") or {}
for c in d.get("checks", []):
    print(("PASS " if c["ok"] else "FAIL ") + c["name"]
          + ("" if c["ok"] else "   :: " + json.dumps(c["detail"])[:300]))
for k, r in (d.get("runs") or {}).items():
    print("  %-5s dx=%-8s dy=%-6s exit=%s  walk.actions=%s"
          % (k, r.get("dx"), r.get("dy"), r.get("exit"),
             json.dumps((r.get("walk") or {}).get("actions"))))
PY
echo "full json: $OUT/hold.json"
exit $rc
