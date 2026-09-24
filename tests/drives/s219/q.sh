#!/bin/bash
# q.sh <turn#> — read the live grill question off the board into prompts/turn-N.q.txt
S="$(cd "$(dirname "$0")" && pwd)"
node "$S/drv.js" '[{"eval":"(function(){function t(s){var e=document.querySelector(s);return e?e.innerText:\"\"} return t(\".qcount\")+\"\\n\\n\"+t(\".qtext\")+(t(\".choice\").trim()?\"\\n\\nOptions offered:\\n\"+t(\".choice\"):\"\")})()"}]' \
 | python3 -c 'import json,sys; print(json.load(sys.stdin)["steps"][0]["eval"])' > "$S/prompts/turn-$1.q.txt"
cat "$S/prompts/turn-$1.q.txt"
