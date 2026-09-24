#!/bin/bash
# cycle.sh <secs> — wait for change or timeout; then tripwire + compact status
S="$(cd "$(dirname "$0")" && pwd)"; M=~/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260911-001-8cb0
"$S/waitchg.sh" "$1"
T=$("$S/trip.sh"); echo "$(date +%H:%M:%S) $T" | tee -a "$S/tripwire.log"
python3 - "$M" <<'PY'
import json,sys,time
m=sys.argv[1]; s=json.load(open(m+"/state.json"))
print("stage=%s awaiting=%s pr=%s xo=%s"%(s.get("stage"),s.get("awaitingHuman"),s.get("prUrl"),(s.get("numberOne") or {}).get("status")))
ev=[json.loads(x) for x in open(m+"/events.jsonl") if x.strip()]
for e in ev[-8:]: print(" ",time.strftime("%H:%M:%S",time.localtime(e["ts"])),e.get("stage"),e.get("type"),str(e.get("detail"))[:160])
PY
