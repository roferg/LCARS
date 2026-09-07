# POST the daemon's write endpoints on a foundationless repo — expect 409.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
REPO="${1:?}"
OUT="$(dirname "${BASH_SOURCE[0]}")/logs/http-$REPO"; mkdir -p "$OUT"
LOG="$OUT/calls.log"; : > "$LOG"; SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99
FIX="$FIX_ROOT/$REPO"
( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 LCARS_WORKER_BIN="$SHIM/claude" \
    LCARS_GH_BIN="$SHIM/claude" python3 -m lcars_serve --port 0 --repo-root "$FIX" ) >"$OUT/daemon.log" 2>&1 &
D=$!
U=""; for _ in $(seq 1 150); do U="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log"|head -1)"; [ -n "$U" ] && break; sleep .1; done
[ -n "$U" ] || { echo FAIL-daemon; cat "$OUT/daemon.log"; kill $D; exit 1; }
echo "daemon $U repo=$REPO"
post() { printf '  %-28s ' "$1"; curl -s -o "$OUT/$1.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$3" "${U%/}$2"; echo "  body: $(head -c 220 "$OUT/$1.body" | tr '\n' ' ')"; }
post file      /api/mission   '{"idea":"a spending summary card"}'
post park      /api/mission   '{"idea":"a spending summary card","park":true}'
post holodeck  /api/holodeck/start '{"brief":"a dashboard screen"}'
kill $D 2>/dev/null
echo "SPAWNS during HTTP drive: $(calls "$LOG")"
