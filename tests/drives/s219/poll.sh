#!/bin/bash
M=~/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260911-001-8cb0
date +%H:%M:%S
python3 - "$M" <<'PY'
import json,sys,os,time
m=sys.argv[1]; s=json.load(open(m+"/state.json"))
print("stage=%s awaiting=%s status=%s paused=%s xo=%s pr=%s"%(s.get("stage"),s.get("awaitingHuman"),s.get("status"),s.get("paused"),(s.get("numberOne") or {}).get("status"),s.get("prUrl")))
try:
  l=json.load(open(m+"/worker-liveness.json")); print("liveness",l.get("stage"),l.get("state"),"quiet-for",int(time.time()-l.get("lastOutputTs",0)),"s bytes",l.get("outputBytes"))
except Exception as e: print("liveness n/a")
ev=[json.loads(x) for x in open(m+"/events.jsonl") if x.strip()]
for e in ev[-6:]: print(time.strftime("%H:%M:%S",time.localtime(e["ts"])),e.get("stage"),e.get("type"),str(e.get("detail"))[:140])
PY
ls $M; ps -A | wc -l; ps -p 98041,58635,61159 -o pid= | tr '\n' ' '; echo
