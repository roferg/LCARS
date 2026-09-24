#!/usr/bin/env bash
# S224 item 1 — THE REAL-BROWSER HALF.
#
# A node DOM harness is a browser stub. This drives REAL HEADLESS CHROME, via
# the real `xo-drive.js`, over a four-screen hash-routed SPA that REPRODUCES
# the two symptoms measured on the S222 capstone (mission
# lcars-20260920-001-8cb0):
#
#   1. the drawing is ONE long page with every screen stacked down it, so
#      "Cancel" is drawn twice — the second instance found nothing left to
#      claim and the criterion about a control that IS in the build read
#      "your drawing names this part and I could not find it";
#   2. the build labels its selects and textareas with `aria-label` while the
#      hand-written drawing names the same controls by their printed text and
#      their placeholder, so the two records never met.
#
# It also carries the CONTROL: "Re-collect" is drawn and is NOT in the build,
# and must still come back unreachable. Without that half this only proves the
# pairer has learned to say yes.
#
# HEADLESS, never headed. $0 — no worker CLI runs here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$HERE/out}"
DRIVER="$ROOT/skills/lcars-xo/xo-drive.js"
PARTS="$ROOT/skills/lcars-xo/xo-parts.py"
NODE="${LCARS_NODE_BIN:-node}"
PY="${LCARS_PYTHON_BIN:-python3}"
rm -rf "$OUT"; mkdir -p "$OUT/build" "$OUT/drawing"

echo "— the drawing, read in real Chrome"
"$NODE" "$DRIVER" --url "file://$HERE/drawing.html" --out "$OUT/drawing" \
  --parts-out "$OUT/drawing-parts.json" --prefix drawn \
  >"$OUT/drawing-drive.json" 2>"$OUT/drawing-drive.err" || true

echo "— the build, WALKED in real Chrome"
"$NODE" "$DRIVER" --url "file://$HERE/app.html" --out "$OUT/build" \
  --parts-out "$OUT/build-parts.json" --journey "$HERE/journey.json" \
  --walk-out "$OUT/walk.json" --prefix shot \
  >"$OUT/build-drive.json" 2>"$OUT/build-drive.err" || true

echo "— the pairing"
"$PY" "$PARTS" pair --drawing "$OUT/drawing-parts.json" \
  --build "$OUT/build-parts.json" --out "$OUT/pairs.json" >/dev/null 2>&1

"$PY" - "$OUT" <<'PY'
import json, os, sys
o = sys.argv[1]
b = json.load(open(os.path.join(o, "build-parts.json")))
p = json.load(open(os.path.join(o, "pairs.json")))
w = json.load(open(os.path.join(o, "walk.json")))
done = [s for s in w.get("steps", []) if s.get("status") == "done"]
print("\nwalk            : %d steps, %d done" % (len(w.get("steps", [])), len(done)))
print("screens kept    : %d  (%s)" % (len(b["screens"]),
      ", ".join((s.split("#")[-1] or "start") for s in b["screens"])))
print("build parts     : %d" % len(b["parts"]))
print("pair entries    : %d   paired %d   unreachable %d"
      % (len(p["pairs"]), p["matched"], p["unreachable"]))
for q in p["pairs"]:
    print("   %-26s %-14s %s" % (q["part"][:26],
          "PAIRED" if q.get("reachable") else "couldn't check", q.get("handle") or ""))
fails = []
by = {}
for q in p["pairs"]:
    by.setdefault(q["part"], []).append(q)
def one(k):
    return len(by.get(k, [])) == 1 and by[k][0].get("reachable")
if len(b["screens"]) < 4: fails.append("the walk kept fewer than 4 screens")
if not one("cancel"): fails.append("`cancel` — drawn twice, in the build — did not pair once")
if not one("lock month"): fails.append("`lock month` did not pair")
if not one("on track watch off track"): fails.append("the status select did not pair by its printed text")
if not one("add an insight for this kpi"): fails.append("the insight box did not pair by its placeholder")
ctl = by.get("re collect") or []
if not ctl or ctl[0].get("reachable"):
    fails.append("CONTROL BROKEN: `re collect` is NOT in the build and came back paired")
tt = by.get("toggle theme") or []
if not tt or tt[0].get("reachable"):
    fails.append("CONTROL BROKEN: `toggle theme` shares no label with the build's button and came back paired")
print("\nshots: %s" % os.path.join(o, "build"))
if fails:
    print("\nFAILED:"); [print("  - " + f) for f in fails]; sys.exit(1)
print("\nALL CHECKS OK")
PY
