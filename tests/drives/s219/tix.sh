#!/bin/bash
# tix.sh — per-ticket results digest -> artifacts/ticket-results.md (+ copies raw ticket dirs)
S="$(cd "$(dirname "$0")" && pwd)"; M=~/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260911-001-8cb0
mkdir -p "$S/artifacts/tickets"; cp -R "$M/tickets/." "$S/artifacts/tickets/"
python3 - "$M" > "$S/artifacts/ticket-results.md" <<'PY'
import json,sys,os,glob
m=sys.argv[1]; plan={t["id"]:t["title"] for t in json.load(open(m+"/plan.json"))}
ev=[json.loads(x) for x in open(m+"/events.jsonl") if x.strip()]
print("# Implement — per-ticket results (from tickets/<id>/result.json, flip-flop.json, events)\n")
for d in sorted(glob.glob(m+"/tickets/t-*")):
  t=os.path.basename(d); r={}; f={}
  try: r=json.load(open(d+"/result.json"))
  except: pass
  try: f=json.load(open(d+"/flip-flop.json"))
  except: pass
  sess=sum(1 for e in ev if e.get("type")=="ticket_attempt" and e.get("detail","").endswith(" "+t))
  gates=[e["type"]+": "+e["detail"][:150] for e in ev if t in e.get("detail","") and e.get("type") not in("ticket_attempt","ticket_start","worker_usage")]
  print("## %s · %s"%(t,plan.get(t,"")))
  print("- passed: %s · worker sessions: %d · result.attempts: %s"%(r.get("passed"),sess,r.get("attempts")))
  print("- new tests: %s · declared test edits: %s"%(", ".join(r.get("newTests",[]) or ["—"]), ", ".join((x if isinstance(x,str) else x.get("path","?")+" ("+str(x.get("reason",x.get("kind","")))[:80]+")") for x in (r.get("testEdits") or [])) or "none"))
  if f: print("- flip-flop: %s — %s (tests run parent/tip: %s/%s)"%(f.get("verdict"),f.get("reason"),(f.get("executed") or {}).get("parent"),(f.get("executed") or {}).get("tip")))
  print("- summary: %s"%r.get("summary",""))
  for g in gates: print("  - "+g)
  print()
PY
grep -E "^## |passed:" "$S/artifacts/ticket-results.md"
