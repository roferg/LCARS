#!/bin/bash
# appshot.sh <out.png> <url> [extra-eval-js] — full-page 2x shot of the launched build in its OWN tab (1440 CSS wide)
S="$(cd "$(dirname "$0")" && pwd)"; OUTF="$1"; URL="$2"; X="${3:-true}"
BOARD="${APPBASE:-http://localhost:5173/}" node "$S/drv.js" "$(python3 - "$OUTF" "$URL" "$X" <<'PY'
import json,sys
o,u,x=sys.argv[1:4]
print(json.dumps([{"nav":u,"wait":2500},{"eval":x},{"wait":900},
 {"eval":"window.__h=Math.max(document.documentElement.scrollHeight,document.body.scrollHeight); window.__h"}]))
PY
)" > /private/tmp/claude-501/-Users-roganferguson-Projects-LCARS/645365aa-c142-42c2-863f-1b417f713a67/scratchpad/appshot-h.json 2>&1
H=$(python3 -c 'import json;print([s["eval"] for s in json.load(open("/private/tmp/claude-501/-Users-roganferguson-Projects-LCARS/645365aa-c142-42c2-863f-1b417f713a67/scratchpad/appshot-h.json"))["steps"] if "eval" in s][-1])')
BOARD="${APPBASE:-http://localhost:5173/}" node "$S/drv.js" "[{\"shot\":\"$OUTF\",\"full\":true,\"clip\":{\"x\":0,\"y\":0,\"width\":1440,\"height\":$H}}]" | python3 -c 'import json,sys;o=json.load(sys.stdin);print([s for s in o["steps"]], o["pageErrors"][:3])'
