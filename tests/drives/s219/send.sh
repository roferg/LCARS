#!/bin/bash
# send.sh <turn#> <answer-file> — type the answer into the live grill, submit, wait for the next turn
S="$(cd "$(dirname "$0")" && pwd)"
STEPS="$(python3 - "$2" <<'PY'
import json,sys
ans=open(sys.argv[1]).read().strip()
wait = """(function(){var c=document.querySelector('.qcount'); var q=document.querySelector('.qtext');
 if(!c||!q) return true; if(!window.__s219prev) return false; return c.innerText!==window.__s219prev && q.innerText.trim().length>5})()"""
steps=[{"eval":"window.__s219prev=(document.querySelector('.qcount')||{}).innerText||''"},
 {"type":{"sel":".console-l textarea","text":ans}},
 {"eval":"(function(){var b=Array.from(document.querySelectorAll('button')).find(b=>/submit/i.test(b.innerText)); b.click(); return b.innerText})()"},
 {"wait":2000},{"waitFor":wait,"timeout":540000},{"wait":1000},
 {"eval":"(document.querySelector('.modal, .overlay')||document.body).innerText.slice(0,500)"}]
print(json.dumps(steps))
PY
)"
node "$S/drv.js" "$STEPS"
