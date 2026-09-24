#!/bin/bash
# shoot.sh <NN> <slug> <board-caption> <crop-caption> [detail-caption] [detail-tab]
# NN-slug-board-full.png, (NN+1)-slug-card-crop.png, (NN+2)-slug-detail-full.png
S="$(cd "$(dirname "$0")" && pwd)"; N=$1; SL=$2; M=lcars-20260911-001-8cb0
n1=$(printf %02d $N); n2=$(printf %02d $((N+1))); n3=$(printf %02d $((N+2)))
TAB="${6:-}"
node "$S/drv.js" "$(python3 - "$n1-$SL-board-full.png" "$n2-$SL-card-crop.png" "$n3-$SL-detail-full.png" "$M" "${5:+yes}" "$TAB" <<'PY'
import json,sys
b,c,d,m,det,tab=sys.argv[1:7]
steps=[{"eval":"try{closeOverlay()}catch(e){}; true"},{"nav":"http://127.0.0.1:8931/","wait":4000},
 {"eval":"document.querySelector('.card.xo-engaged, .card.running, .card[data-mid=\"%s\"]')?document.querySelector('.card.xo-engaged, .card.running, .card[data-mid=\"%s\"]').scrollIntoView({block:'center'}):0; true"%(m,m)},
 {"wait":800},{"shot":b},
 {"shot":c,"selector":".card[data-mid=\"%s\"]"%m,"pad":16}]
if det:
  steps += [{"eval":"openDetail('%s'%s); true"%(m, (",'%s'"%tab) if tab else "")},{"wait":3500},{"shot":d}]
print(json.dumps(steps))
PY
)" | python3 -c 'import json,sys;o=json.load(sys.stdin);print([s for s in o["steps"] if "shot" in s or "error" in s], o["pageErrors"])'
echo "$3" > "$S/shots/$n1-$SL-board-full.txt"; echo "$4" > "$S/shots/$n2-$SL-card-crop.txt"
[ -n "${5:-}" ] && echo "$5" > "$S/shots/$n3-$SL-detail-full.txt"; true
