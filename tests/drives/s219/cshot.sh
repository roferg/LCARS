#!/bin/bash
# cshot.sh <NN> <slug> <mission-id> <board-caption> <crop-caption> — board full (scrolled to the card) + card crop
S="$(cd "$(dirname "$0")" && pwd)"; N=$1; SL=$2; M=$3
n1=$(printf %02d $N); n2=$(printf %02d $((N+1)))
node "$S/drv.js" "$(python3 - "$n1-$SL-board-full.png" "$n2-$SL-card-crop.png" "$M" <<'PY'
import json,sys
b,c,m=sys.argv[1:4]
print(json.dumps([{"eval":"try{closeOverlay()}catch(e){}; true"},{"nav":"http://127.0.0.1:8931/","wait":4000},
 {"eval":"var c=document.querySelector('.card[data-mid=\"%s\"]'); c&&c.scrollIntoView(true); window.scrollBy(0,-200); c?c.innerText.replace(/\\n/g,' / ').slice(0,300):'NO CARD'"%m},
 {"wait":800},{"shot":b},{"shot":c,"selector":".card[data-mid=\"%s\"]"%m,"pad":16}]))
PY
)" | python3 -c 'import json,sys;o=json.load(sys.stdin);print([s for s in o["steps"] if "eval" in s][1:], [s for s in o["steps"] if "error" in s], o["pageErrors"])'
echo "$4" > "$S/shots/$n1-$SL-board-full.txt"; echo "$5" > "$S/shots/$n2-$SL-card-crop.txt"
