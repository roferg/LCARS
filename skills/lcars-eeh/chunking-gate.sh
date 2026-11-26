#!/usr/bin/env bash
set -uo pipefail
[ -f "$1/autopilot.json" ] || exit 0
"${LCARS_PYTHON_BIN:-python3}" - "$@" <<'PY'
import glob
import json
import os
import sys

root = sys.argv[1]
d = json.load(open(os.path.join(root, "autopilot.json")))
needed = "chunkingBaseline" in d and not d.get("chunking")
baseline = set(d.get("chunkingBaseline", []))
filed = needed and any(
    os.path.basename(os.path.dirname(p)) not in baseline
    for p in glob.glob(os.path.join(root, "missions", "*", "state.json")))
if "--filing" in sys.argv and needed:
    sys.exit("chunking: decide before any Mission is filed: "
             "lcars-ech chunking --chunks <n> --trigger <axis|none> --why \"<reason>\"")
print("late" if filed else "yes" if needed else "no")
PY
rc=$?
[ "$rc" = 0 ] || exit 2
