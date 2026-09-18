#!/usr/bin/env bash
#
# THE TWO SURFACE FAULTS A NODE DOM CANNOT SEE (Session 213, fix round 1).
#
# Both of these were measured on the captain's REAL board and both are invisible
# to every harness this repo already has, because both are questions about what
# a BROWSER does with the stylesheet:
#
#   D1 — THE CARD SWALLOWED THE TRANSCRIPT. A verdict of 2,673 characters was
#        planted on a Verify card and the card drew all of them: 91 wrapped
#        lines, 1,752 px tall in a 200 px column, every other mission pushed off
#        the screen. `webkitLineClamp: none`, `overflow: visible`,
#        `textOverflow: clip` — nothing truncated at any length. C1 promises ONE
#        line plus a link for ANY verdict, not for short ones.
#
#   D5 — THE REPORT DID NOT FIT THE PHONE. At a true 390 CSS px viewport the
#        ◈ Number One report rendered 605 px wide: verdict lines cut off at both
#        edges and the MEDIUM score itself scrolled off to the LEFT, where no
#        scroll reaches, while "1 THING I COULD NOT CHECK" stayed visible. A
#        surface that hides its own verdict defeats C1 and C2.
#
# HOW THE VIEWPORT IS MADE REAL. macOS will not give Chrome a window narrower
# than 500 px, so 390 is produced by an IFRAME exactly 390 px wide: an iframe's
# width is what its own media queries resolve against, so `max-width:560px`
# resolves inside it exactly as it does on the phone. The page inside it is the
# SHIPPING board — index.html, board.js, board.css — and the probe walks the
# captain's own path to the surface (the band control → its menu → the First
# Officer's report → a mission header → that mission on its ◈ Number One tab).
# Nothing is faked but the daemon's answers.
#
# EVERY MEASUREMENT SHIPS AS A PAIR. Each cured behaviour is measured beside the
# same page with the cure DEFEATED by a stylesheet injected after board.css —
# so a green here cannot be the fixture being harmless.
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-phone.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
CAGE="$REPO_ROOT/tests/drives/s197/cage.py"
MKFIXTURE="$REPO_ROOT/tests/drives/s213/phone/mkfixture.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
CHROME=""
for c in "${LCARS_BROWSER_CHROME:-}" \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
done

if [ "$HAVE_NODE" -eq 0 ] || [ -z "$CHROME" ]; then
  printf 'lcars xo-phone: skipped (node or Chrome not available)\n'
  exit 0
fi

# A file:// page may not reach INTO an iframe on another file:// document unless
# Chrome is told these are one origin — and the parent doing the measuring is
# the whole point, because it is the one document board.js cannot touch.
WRAP="$TMPROOT/chrome.sh"
cat >"$WRAP" <<SH
#!/usr/bin/env bash
exec "$CHROME" "\$@" --allow-file-access-from-files
SH
chmod +x "$WRAP"

printf '[{"wait":4000},{"screenshot":"look"}]\n' >"$TMPROOT/actions.json"

probe() { # <fixture-dir> [<extra.css>] — build, drive, print the probe's JSON
  local dir="$1" extra="${2:-}"
  rm -rf "$dir"
  "$PY" "$MKFIXTURE" "$dir" "$REPO_ROOT" $extra >/dev/null 2>&1 || return 1
  "$PY" "$CAGE" 90 node "$DRIVER" --url "file://$dir/phone/outer.html" \
        --out "$dir/out" --chrome "$WRAP" --actions "$TMPROOT/actions.json" \
        >"$dir/drive.log" 2>&1
  "$PY" - "$dir/out/readout.json" <<'PYEOF'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("{}"); raise SystemExit(0)
text = (doc.get("page") or {}).get("textExcerpt", "")
i = text.find("PROBE ")
if i < 0:
    print("{}"); raise SystemExit(0)
obj, _end = json.JSONDecoder().raw_decode(text[i + 6:].lstrip())
print(json.dumps(obj))
PYEOF
}

jf() { # <json-file> <python expr over d> — one number/flag out of a probe
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
try: print(eval(sys.argv[2]))
except Exception: print("")' "$1" "$2"
}

# ==========================================================================
# PART 1 — D1: ONE LINE, AT ANY LENGTH, IN A REAL BROWSER.
#
# The renderer's half (the card carries a short string and a way in) is proven
# in web/tests/test_xo_surfaces.py, where a node DOM can see it. THIS is the
# half that node cannot: whether the stylesheet actually clamps the line the
# renderer emits. The markup below is one class name — the same class the
# renderer's own test pins — in a 200 px column, which is the width of the
# captain's board column.
# ==========================================================================
echo
echo "PART 1 — D1: the card's verdict line, measured in a browser"

FX="$TMPROOT/fx"; mkdir -p "$FX"
cp "$REPO_ROOT/web/static/board.css" "$FX/board.css"
"$PY" - "$FX" <<'PYEOF'
import sys, os
FX = sys.argv[1]
# 2,673 characters — the length the tester actually planted.
RAMBLE = ("Captain, I want to walk you through everything I did here because "
          "there is rather a lot of it and none of it is simple. " * 22
          + "None of it could be tested.")
page = """<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="board.css">
<style>body{margin:0;background:#000} .col{width:200px}</style></head>
<body>
<!-- the numbers go FIRST: the driver's readout carries the first 2,000
     characters of the page's text, and the sample text below is longer. -->
<pre id="out"></pre>
<div class="col">
  <div class="xo-block xo-signal">
    <div class="xo-verdict-line" id="clamped">%s</div>
  </div>
  <div id="unclamped">%s</div>
</div>
<script>
(function () {
  function read(id) {
    var n = document.getElementById(id), s = getComputedStyle(n);
    return { h: Math.round(n.getBoundingClientRect().height),
             clamp: s.webkitLineClamp, overflow: s.overflow,
             ellipsis: s.textOverflow };
  }
  document.getElementById("out").textContent =
    "PROBE " + JSON.stringify({ clamped: read("clamped"),
                                unclamped: read("unclamped") });
})();
</script></body></html>""" % (RAMBLE, RAMBLE)
open(os.path.join(FX, "clamp.html"), "w").write(page)
PYEOF

"$PY" "$CAGE" 60 node "$DRIVER" --url "file://$FX/clamp.html" \
      --out "$TMPROOT/clamp-out" >"$TMPROOT/clamp.log" 2>&1
"$PY" - "$TMPROOT/clamp-out/readout.json" >"$TMPROOT/clamp.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
text = (doc.get("page") or {}).get("textExcerpt", "")
i = text.find("PROBE ")
if i < 0:
    print("{}"); raise SystemExit(0)
obj, _end = json.JSONDecoder().raw_decode(text[i + 6:].lstrip())
print(json.dumps(obj))
PYEOF

check "D1 a 2,673-character verdict draws ONE line in a 200 px column" \
  "[ \"\$(jf '$TMPROOT/clamp.json' 'd[\"clamped\"][\"h\"] <= 26')\" = 'True' ]"
check "D1 …and the browser really is clamping it, not merely hiding it" \
  "[ \"\$(jf '$TMPROOT/clamp.json' 'd[\"clamped\"][\"clamp\"] not in (\"none\", \"\", None)')\" = 'True' ]"
check "D1 …with the overflow cut off rather than spilling" \
  "[ \"\$(jf '$TMPROOT/clamp.json' 'd[\"clamped\"][\"overflow\"] != \"visible\"')\" = 'True' ]"
check "D1 CONTROL — the SAME text with no class is still many lines tall" \
  "[ \"\$(jf '$TMPROOT/clamp.json' 'd[\"unclamped\"][\"h\"] > 300')\" = 'True' ]"
check "D1 CONTROL — …so the measurement can see a transcript when there is one" \
  "[ \"\$(jf '$TMPROOT/clamp.json' 'd[\"unclamped\"][\"h\"] > d[\"clamped\"][\"h\"] * 10')\" = 'True' ]"

# ==========================================================================
# PART 2 — D5: THE REPORT FITS THE PHONE IT IS READ ON.
#
# The shipping board, in a 390 px viewport, walked to the ◈ Number One tab by
# the captain's own route. The pair below defeats the cure with one injected
# stylesheet, so what is being measured is the cure and not the fixture.
# ==========================================================================
echo
echo "PART 2 — D5: the ◈ Number One report at a true 390 px viewport"

cat >"$TMPROOT/wide-child.css" <<'CSS'
/* A STAND-IN FOR ANY CHILD THAT CANNOT GET NARROWER — a picture at its natural
   size, an unbreakable path, a control row that will not wrap. The defect is
   never about this particular element; it is about what one wide child is
   allowed to do to the surface around it. */
.xo-lede{width:900px}
CSS
cat >"$TMPROOT/wide-child-nocure.css" <<'CSS'
.xo-lede{width:900px}
/* …and the cure switched back off. */
.overlay-stage,.modal,.detail-grid,.tabs,.tabpane,.xo-pane{min-width:auto}
.tabs{overflow:visible}
CSS

probe "$TMPROOT/plain" >"$TMPROOT/plain.json"
check "D5 the captain's own route reaches the ◈ Number One tab at 390 px" \
  "[ \"\$(jf '$TMPROOT/plain.json' 'd.get(\"missionOpened\") is True')\" = 'True' ]"
check "D5 …and the viewport under test really is 390" \
  "[ \"\$(jf '$TMPROOT/plain.json' 'd.get(\"viewport\")')\" = '390' ]"
check "D5 the report pane fits inside the phone — both edges" \
  "[ \"\$(jf '$TMPROOT/plain.json' '0 <= d[\"pane\"][\"left\"] and d[\"pane\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 the MEDIUM score itself is ON the screen, not scrolled off the left" \
  "[ \"\$(jf '$TMPROOT/plain.json' '0 <= d[\"scoreWord\"][\"left\"] and d[\"scoreWord\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 …so is the verdict line the captain came to read" \
  "[ \"\$(jf '$TMPROOT/plain.json' '0 <= d[\"lede\"][\"left\"] and d[\"lede\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 …and the count of what could not be checked" \
  "[ \"\$(jf '$TMPROOT/plain.json' '0 <= d[\"untestedPill\"][\"left\"]')\" = 'True' ]"
check "D5 nothing inside the surface overflows the phone at all" \
  "[ \"\$(jf '$TMPROOT/plain.json' 'len(d.get(\"overflowing\") or [])')\" = '0' ]"

probe "$TMPROOT/wide" "$TMPROOT/wide-child.css" >"$TMPROOT/wide.json"
check "D5 one 900 px child does NOT set the width of the surface around it" \
  "[ \"\$(jf '$TMPROOT/wide.json' 'd[\"pane\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 …the tab bar still fits too" \
  "[ \"\$(jf '$TMPROOT/wide.json' 'd[\"tabs\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 …and the score stays where he can read it" \
  "[ \"\$(jf '$TMPROOT/wide.json' '0 <= d[\"scoreWord\"][\"left\"] and d[\"scoreWord\"][\"right\"] <= d[\"viewport\"] + 1')\" = 'True' ]"

printf '\n  -- the CONTROL: the same page with the cure defeated --\n'
probe "$TMPROOT/nocure" "$TMPROOT/wide-child-nocure.css" >"$TMPROOT/nocure.json"
check "D5 CONTROL — without the cure that one child DOES take the surface with it" \
  "[ \"\$(jf '$TMPROOT/nocure.json' 'd[\"pane\"][\"right\"] > d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 CONTROL — …carrying the tab bar past the edge of the phone" \
  "[ \"\$(jf '$TMPROOT/nocure.json' 'd[\"tabs\"][\"right\"] > d[\"viewport\"] + 1')\" = 'True' ]"
check "D5 CONTROL — …and shoving what he needs to see out of place" \
  "[ \"\$(jf '$TMPROOT/nocure.json' 'd[\"untestedPill\"][\"left\"] > 150')\" = 'True' ]"

# ==========================================================================
echo
printf 'lcars xo-phone: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
