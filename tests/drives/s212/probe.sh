#!/usr/bin/env bash
# S212 fresh-tester rig. Drives ONE planted page through the REAL product path:
#   real headless Chrome -> skills/lcars-xo/xo-drive.js -> readout.json
#   -> skills/lcars-xo/xo-observe.py -> observations.json
# then prints exactly the sentences the captain would read.
#
#   bash probe.sh <page.html> [outname] [extra xo-drive argv...]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$ROOT/tests/drives/s197/cage.py"
DRIVER="$ROOT/skills/lcars-xo/xo-drive.js"
OBSERVE="$ROOT/skills/lcars-xo/xo-observe.py"
page="$1"; name="${2:-$(basename "$page" .html)}"; shift 2 2>/dev/null || shift 1
OUT="${S212_OUT:-$ROOT/tests/drives/s212/out}/$name"
rm -rf "$OUT"; mkdir -p "$OUT"
"$PY" "$CAGE" 90 node "$DRIVER" --url "file://$page" --out "$OUT" "$@" \
   >"$OUT/drive.log" 2>&1
drv=$?
echo "── $name ── driver cage exit $drv"
tail -3 "$OUT/drive.log"
[ -f "$OUT/readout.json" ] || { echo "NO READOUT"; exit 1; }
"$PY" "$OBSERVE" "$OUT/readout.json" "$OUT/observations.json"
"$PY" - "$OUT/observations.json" <<'PYP'
import json,sys
d=json.load(open(sys.argv[1]))
print("  elements measured: %d   unseen(skipped): %d   found: %d   printed: %d"
      % (d["elementCount"], d.get("unseenCount",0), d.get("foundCount",0), len(d["observations"])))
for n in d.get("notes",[]):
    print("  NOTE: %s" % n)
for o in d["observations"]:
    print("  * %s" % (o.get("message") or o.get("text") or json.dumps(o)))
if not d["observations"] and not d.get("notes"):
    print("  (silent — no observations)")
PYP
