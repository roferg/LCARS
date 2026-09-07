set -u
. "/Users/roganferguson/Projects/LCARS/tests/drives/s183b/rig.sh"
OUT="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/verify/uninit"; rm -rf "$OUT"; mkdir -p "$OUT"
LOG="$OUT/calls.log"; : > "$LOG"; SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99
# a PRISTINE untested repo — code, no tests, NEVER `lcars init`ed.
p="$(newrepo uninit-untested)"; mkdir -p "$p/src"
printf '{ "name":"app", "scripts": { "dev":"vite" } }\n' > "$p/package.json"
echo "console.log(1)" > "$p/src/i.js"; commitall "$p"
echo "CLI gate: $( (cd "$p" && bash "$GATE_SH" --check >/dev/null 2>&1); echo rc=$? )"
echo "CLI readiness: $( (cd "$p" && bash "$READINESS_SH" --json) )"
( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 LCARS_WORKER_BIN="$SHIM/claude" \
    LCARS_GH_BIN="$SHIM/claude" python3 -m lcars_serve --port 0 --repo-root "$p" ) >"$OUT/daemon.log" 2>&1 &
D=$!
U=""; for _ in $(seq 1 150); do U="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log"|head -1)"; [ -n "$U" ] && break; sleep .1; done
[ -n "$U" ] || { echo FAIL-daemon; cat "$OUT/daemon.log"; kill $D; exit 1; }
echo "daemon $U"
echo "board meta: $(curl -s "${U%/}/api/board" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("meta",{})))')"
post() { printf '  %-12s ' "$1"; curl -s -o "$OUT/$1.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$3" "${U%/}$2"; echo "  body: $(head -c 200 "$OUT/$1.body" | tr '\n' ' ')"; }
post file /api/mission '{"idea":"a spending summary card"}'
post park /api/mission '{"idea":"a spending summary card","park":true}'
post holodeck /api/holodeck/start '{"brief":"a screen","program":"p1"}'
kill $D 2>/dev/null
echo "missions on disk: $(ls "$p/.git/lcars/missions" 2>/dev/null | tr '\n' ' ')"
echo "SPAWNS=$(calls "$LOG")"
