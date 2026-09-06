#!/usr/bin/env bash
# S184 tester — the daemon's write endpoints: /api/vision/file parity + S183's
# 409 backstops. Zero spend (shim + fuse).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/verify"; mkdir -p "$DEST"
REPO="$(newrepo "s184-http")"
LOG="$DEST/http.calls.log"; : > "$LOG"
SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99

( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$SHIM/claude" LCARS_GH_BIN="$SHIM/claude" \
    python3 -m lcars_serve --port 0 --repo-root "$REPO" ) >"$DEST/http.daemon.log" 2>&1 &
DPID=$!
trap 'kill $DPID 2>/dev/null' EXIT
U=""
for _ in $(seq 1 150); do
  U="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$DEST/http.daemon.log" | head -1)"
  [ -n "$U" ] && break; sleep 0.1
done
[ -n "$U" ] || { echo "FAIL: no daemon"; cat "$DEST/http.daemon.log"; exit 1; }
U="${U%/}"
echo "daemon: $U  repo=$REPO"

post() { # path json
  curl -s -o "$DEST/body.$$" -w '%{http_code}' -X POST -H 'content-type: application/json' \
       -d "$2" "$U$1"
}
echo "== GET /api/board meta.frontDoor"
curl -s "$U/api/board" | python3 -c 'import json,sys;m=json.load(sys.stdin)["meta"];print(json.dumps({k:m.get(k) for k in ("adapter","foundation","frontDoor")},indent=1))'

echo "== S183 BACKSTOP: POST /api/mission"
code=$(post /api/mission '{"title":"x","body":"y"}'); echo "HTTP $code"; head -c 400 "$DEST/body.$$"; echo
echo "== S183 BACKSTOP: POST /api/holodeck/start"
code=$(post /api/holodeck/start '{"idea":"x"}'); echo "HTTP $code"; head -c 400 "$DEST/body.$$"; echo
echo "== POST /api/vision/file (the viewscreen half of BOTH DOORS)"
code=$(post /api/vision/file '{"idea":"a website that does personal finance stuff","stack":"Vite + React + Vitest","reasons":["r one","r two"],"deferred":["Budgets","Charts"],"slice":"importing a CSV row and showing it"}')
echo "HTTP $code"; head -c 200 "$DEST/body.$$"; echo
mid="$(ls -t "$REPO/.git/lcars/missions" 2>/dev/null | head -1)"
echo "mission=$mid"
mkdir -p "$DEST/http"
cp "$REPO/.git/lcars/missions/$mid/prd.md" "$DEST/http/prd.md" 2>/dev/null
cp "$REPO/.git/lcars/vision.md" "$DEST/http/vision.md" 2>/dev/null
cp "$REPO/.git/lcars/missions/$mid/state.json" "$DEST/http/state.json" 2>/dev/null
echo "== board after filing (front door should be gone)"
curl -s "$U/api/board" | python3 -c 'import json,sys;b=json.load(sys.stdin);print("frontDoor:",b["meta"].get("frontDoor"),"missions:",len(b.get("missions") or []))'
rm -f "$DEST/body.$$"
echo "WORKER SPAWNS: $(calls "$LOG")  probes=$(probes "$LOG")"
echo "REPO=$REPO"
