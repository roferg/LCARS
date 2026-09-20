#!/usr/bin/env bash
# S223 — one real-Chrome drive of the Number One reader, end to end.
#   bash tests/drives/s223/run.sh <pristine-fixture-repo> <scratch-dir> <mission> [<engaged-mission>]
# Copies the pristine fixture (never the captain's checkout) to <scratch>/fx,
# boots the real daemon + headless Chrome, drives, reaps ONLY its own PIDs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PRISTINE="$1" SCR="$2" MID="$3" MID2="${4:-}"
. "$HERE/rig.sh"
trap s223_teardown EXIT
rm -rf "$SCR/fx"; cp -R "$PRISTINE" "$SCR/fx"
OUT="$SCR/run"; rm -rf "$OUT"; mkdir -p "$OUT"
SHOTS="${S223_SHOTS:-$HERE/shots}"
s223_start_daemon "$SCR/fx" "$OUT" || exit 1
s223_start_chrome "$OUT" || exit 1
node "$HERE/drive.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" --out "$SHOTS" \
  --mission "$MID" ${MID2:+--engaged "$MID2"} >"$OUT/drive.json" 2>"$OUT/drive.err"
rc=$?
echo "drive rc=$rc (json: $OUT/drive.json)"
python3 - "$OUT/drive.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checks"]:
    print(("PASS " if c["ok"] else "FAIL ")+c["name"]+("" if c["ok"] else "  :: "+json.dumps(c["detail"])[:400]))
print("%d/%d checks ok" % (sum(c["ok"] for c in d["checks"]), len(d["checks"])))
PY
# state.json must still parse after the stand-downs the drive pressed
for f in "$SCR"/fx/.git/lcars/missions/*/state.json; do
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" || { echo "INVALID JSON: $f"; rc=1; }
done
echo "shim invocations: $(s223_shim_count "$OUT")"
exit $rc
