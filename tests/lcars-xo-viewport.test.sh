#!/usr/bin/env bash
#
# S266 — A CAMERA THAT CAN SEE A PHONE.
#
# THE MEASURED DEFECT. Number One's own embedded live-check checklist carries,
# as item 3, "Phone width — the 400 px iframe recipe", and that text is pasted
# VERBATIM into the reviewer's assembled prompt. The reviewer was then handed a
# browser that cannot do it:
#
#   • xo-drive.js HARD-CODED `--window-size=1440,900` in `chromeArgv` — one
#     occurrence, and no flag anywhere in its own arg parser.
#   • there was no `viewport` verb in the action vocabulary: xo-run.py's
#     BROWSER_KINDS was navigate, click, type, gate, press, key, goto, scroll,
#     shot, screenshot, wait, hover, select.
#   • `Emulation.setDeviceMetricsOverride` was called with `{width: 0,
#     height: 0, …}` — i.e. the width/height override was CLEARED, deliberately,
#     so that only the device scale factor was ever set.
#
# So the system handed itself an instruction and then made it impossible to
# carry out. S262's EEH found the real bug it was blind to — the week grid
# needs horizontal scrolling at 400 px and TODAY's column, the one the spec
# singles out, is scrolled off-screen by default (table.week{min-width:520px}
# inside .grid-scroll{overflow-x:auto}, with zero media queries) — and filed it
# as #163. The reviewer could not have caught it, and not for want of judgement.
#
# ⚠ THE TRAP THIS FILE IS BUILT AROUND, in the checklist's own words:
#
#     "Headless Chrome will not lay out below 500 px of viewport: asking it for
#      a 375 px window gives you a 500 px layout and a phone bug that never
#      appears."
#
# A `--window-size=400,…` flag ALONE therefore CANNOT produce a 400 px layout.
# Chrome floors it. `Emulation.setDeviceMetricsOverride` is a DIFFERENT
# mechanism and can go below that floor. So every row below that cares about
# phone width asserts THE RENDERED WIDTH, measured off a fixture page that
# reports its own `window.innerWidth`, and NOT the presence of a flag. A test
# that asserted the flag would pass over a 500-pixel-wide picture labelled
# "phone" — a false green of exactly the class this round exists to delete.
#
# ⚠ AND THE SHOT MUST STILL LAND ITS READOUT. A phone-width picture with no
# `{url, title, textSample}` beside it is demoted exactly like any other
# picture — the prompt says so itself: a picture taken any other way "cannot be
# placed, so every row citing it is scored 'I could not check this'". So
# section 2 scores a real mission over the real 400 px shot and proves the row
# citing it keeps its verdict, WITH a control that strips the readout and
# watches the same row collapse to untested.
#
# WHY A REAL BROWSER. The question is "what width did this page actually lay
# out at". A stub of the browser would be asserting the thing under test.
#
# EVERY CHECK HAS A KNOWN-GOOD CONTROL:
#   §1 the verb reaches 400          §3 no verb → still 1440x900, unchanged
#   §2 the shot places when cited    §2d the same shot, readout stripped → demoted
#   §4 a browser verb is not a reach — the argv fence is byte-identical
#   §6 the verb is named in a REAL assembled prompt; redact item 3 and it is not
#   §5 MUTATION — neutralise the override call and §1 goes red
#
# ── FIX ROUND 2 (§8-§11): THE FALSE GREEN A LIVE LOOK EXPOSED ──────────────
#
# The camera works; the look that used it never got a page. `lcars launch` died
# on a port collision (the captain's own viewscreen holds 8765), `xo.sh` set
# `nopage=1`, and the reviewer's ELEVEN declared browser steps were recorded
# `asked: 11, refused: [], dropped: [], overflow: 0` — KEPT, and not one run. It
# was never told: nothing was REFUSED and nothing was DROPPED, so neither S264
# section could fire, and rounds 2 and 3 still opened "the build is RUNNING …
# and you are looking at the pictures it took" over a directory with no PNG in
# it. With zero photographs it graded the phone-width rows `met` off unit tests
# and returned HIGH / MERGE / "checked 15 of 15" — and the tester then rendered
# the same page at a measured 400 px and falsified one of those rows.
#
#   §8  the record of a KEPT-and-never-run step, and the prompt that carries it
#       — plus the prompt no longer asserting photographs it does not have
#       CONTROLS: a healthy round's prompt has no such section and the original
#       wording back byte-for-byte; the reach step still runs with no page
#   §9  a `looks`-stamped row rated met with NO picture is `couldn't check`
#       CONTROLS: the same claim with a valid 400 px picture still settles; a
#       `works` row and an UNSTAMPED row on the same unit tests are untouched;
#       a `looks` FAULT with no picture is still a fault
#   §10 MUTATION — each of the four cures reverted on a copy and RUN, with the
#       very assertion it serves re-evaluated; §11 the round's three fences
#
# ZERO SPEND: a PATH shim fakes BOTH `claude` and `copilot`; the count is 0.
#
# Usage: bash tests/lcars-xo-viewport.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
SCORE="$REPO_ROOT/skills/lcars-xo/xo-score.py"
CAGE="$REPO_ROOT/tests/lib/cage.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
measured(){ printf '  \033[36mMEASURED\033[0m %s\n' "$1"; }

# --- ZERO SPEND ------------------------------------------------------------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
SPEND_LOG="$TMPROOT/spend.log"; : >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
EOF
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"
export LCARS_WORKER_BIN="$SHIM/claude"

echo "lcars xo — a camera that can see a phone (S266)"

HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
HAVE_CHROME=0
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && HAVE_CHROME=1
done
[ -n "${LCARS_BROWSER_CHROME:-}" ] && [ -x "${LCARS_BROWSER_CHROME:-}" ] && HAVE_CHROME=1

# ===========================================================================
# THE FIXTURE — a page that reports the width it was actually laid out at.
#
# It reports it THREE ways, each independently readable off the shot's own
# readout: as body text (`page.textExcerpt` → `landed.textSample`), as the
# document title (`page.title` → `landed.title`), and as a declared place
# (`#screen-week`, so `landed.screen` is set and the landing rail has something
# to compare). And it carries #163's actual shape — a 520 px-wide table inside
# an `overflow-x:auto` scroller with no media query — so the page under the
# camera is the page the EEH photographed, not a toy.
# ===========================================================================
FX="$TMPROOT/fx"; mkdir -p "$FX"
cat >"$FX/ruler.html" <<'HTML'
<!doctype html><html><head><title>Ruler</title></head>
<body style="margin:0;font:16px system-ui;background:#eef2f7;color:#12263a">
<div id="screen-week" style="padding:12px">
  <h1 id="w" style="font-size:20px;background:#2563eb;color:#fff;padding:6px 10px">innerWidth=?</h1>
  <div class="grid-scroll" style="overflow-x:auto;border:1px solid #94a3b8">
    <table class="week" style="min-width:520px;border-collapse:collapse">
      <tr><th style="background:#f97316;padding:6px">Mon</th><th style="background:#22c55e;padding:6px">Tue</th>
          <th style="background:#0ea5e9;padding:6px">Wed</th><th style="background:#a855f7;padding:6px">Thu</th>
          <th style="background:#eab308;padding:6px">Fri</th><th style="background:#ef4444;padding:6px">Sat</th>
          <th id="today" style="background:#111827;color:#fff;padding:6px">Sun</th></tr>
      <tr><td style="padding:14px">a</td><td style="padding:14px">b</td><td style="padding:14px">c</td>
          <td style="padding:14px">d</td><td style="padding:14px">e</td><td style="padding:14px">f</td>
          <td style="padding:14px">g</td></tr>
    </table>
  </div>
  <p id="note">the quick brown fox jumps over the lazy dog</p>
</div>
<script>
function u() {
  var n = window.innerWidth;
  document.getElementById("w").textContent = "innerWidth=" + n;
  document.title = "Ruler " + n;
}
u();
window.addEventListener("resize", u);
</script>
</body></html>
HTML

# The declared places, in the shape xo.sh really passes (`--place-names
# criteria.json`), so `landed.screen` is populated exactly as it is in
# production and the landing rail has a screen to compare.
cat >"$FX/places.json" <<'JSON'
{"mission": "s266-viewport", "placeNames": ["#screen-week", "#today"]}
JSON

# ===========================================================================
# 0. THE FLAG AND THE VERB EXIST AT ALL — read off the source, cheap, and the
#    only rows in this file that look at anything other than a rendered pixel.
#    They are here so that a missing flag reads as "the flag is missing" rather
#    than as a browser that would not start.
# ===========================================================================
printf '\n\033[1m0. the flag and the verb are declared\033[0m\n'
check "0a. xo-drive.js no longer hard-codes a window size it cannot be told" \
  "$PY -c \"
import re,sys
src=open('$DRIVER',encoding='utf-8').read()
m=re.search(r'function chromeArgv\\(.*?\\n\\}', src, re.S)
body=m.group(0) if m else ''
lit=re.findall(r'--window-size=\\d', body)
built=re.findall(r'--window-size=\\\" *\\+', body)
print('literal',lit,'built',built)
sys.exit(0 if built and not lit else 1)\""
check "0b. the viewport verb is a browser kind xo-run.py knows" \
  "$PY -c \"
import re,sys
src=open('$XORUN',encoding='utf-8').read()
m=re.search(r'BROWSER_KINDS = \\((.*?)\\)', src, re.S)
sys.exit(0 if m and 'viewport' in m.group(1) else 1)\""
check "0c. --headless=new is still unconditional in the argv builder" \
  "grep -q -- '\"--headless=new\"' '$DRIVER'"
# A BEHAVIOURAL control, not a grep over prose: the header has always SAID there
# is no --headed flag, so a grep for the word finds the promise and not a
# breach. This asks the argv builder itself, with every flag that has ever been
# proposed for raising a window passed at once and the one env var the board's
# eyeball legs use exported.
if [ "$HAVE_NODE" -eq 1 ]; then
  # The argv goes to a FILE and is grepped from there. A JSON array carries
  # double quotes, and interpolating it into an eval'd check string mangles
  # them — which is how the first draft of this very row went green on a
  # pattern it was no longer looking for.
  LCARS_BROWSER_HEADED=1 node "$DRIVER" --print-chrome-argv --headed \
    --headless=false --window-size=1024,768 --url x --out "$TMPROOT/argv" \
    >"$TMPROOT/argv-headed.json" 2>/dev/null
  check "0d. nothing a caller or the environment can say makes this browser headed" \
    "grep -qF -- '\"--headless=new\"' '$TMPROOT/argv-headed.json' && ! grep -qF -- '\"--headed\"' '$TMPROOT/argv-headed.json'"
fi

if [ "$HAVE_NODE" -ne 1 ] || [ "$HAVE_CHROME" -ne 1 ]; then
  printf '  (node or Chrome not available — the rendered width cannot be measured without a real browser; SECTIONS 1-3 and 5 SKIPPED)\n'
fi

# ── the driver, caged; prints its exit code -------------------------------
drive() { # <driver> <outdir> <actions-json> [extra driver args…]
  local drv="$1" out="$2" acts_json="$3"; shift 3
  mkdir -p "$out"
  printf '%s\n' "$acts_json" >"$out/actions.json"
  # cage.py always exits 0 and PRINTS the caged process's status, so the
  # driver's own exit code is read out of its line and never off $?.
  "$PY" "$CAGE" 60 node "$drv" --url "file://$FX/ruler.html" --out "$out" \
    --actions "$out/actions.json" --walk-out "$out/walk.json" \
    --place-names "$FX/places.json" "$@" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  sed -n 's/^ELAPSED .* EXIT \([0-9][0-9]*\)$/\1/p' "$out/stdout.txt" | head -1
}

# The width the page SAYS it was laid out at, read off one shot's own readout.
# Two independent witnesses in one file: the body text and the title. They must
# agree, or the answer is "?" and every row that reads it fails.
width_of() { # <shot json>
  "$PY" - "$1" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("?"); raise SystemExit(0)
page = d.get("page") or {}
landed = d.get("landed") or {}
hay = " ".join([str(page.get("textExcerpt") or ""), str(landed.get("textSample") or "")])
body = re.findall(r"innerWidth=(\d+)", hay)
ttl = re.findall(r"Ruler (\d+)", " ".join([str(page.get("title") or ""),
                                           str(landed.get("title") or "")]))
vals = set(body) | set(ttl)
print(vals.pop() if len(vals) == 1 and body and ttl else "?")
PY
}

# ===========================================================================
# 1. THE RENDERED WIDTH CHANGES. Not the flag — the width the page says it got.
# ===========================================================================
printf '\n\033[1m1. a viewport step at 400 px changes the RENDERED width\033[0m\n'
W400="?"; WDEF="?"; WFLAG="?"
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then
  # THE THREE LOOKS, taken together so every width below is measured against
  # the others under one browser build: the verb, nothing at all, and the flag
  # on its own.
  RC_V="$(drive "$DRIVER" "$TMPROOT/phone" \
    '[{"viewport":{"width":400}},{"screenshot":"phone"}]')"
  RC_D="$(drive "$DRIVER" "$TMPROOT/wide" '[{"screenshot":"wide"}]')"
  RC_F="$(drive "$DRIVER" "$TMPROOT/flagonly" '[{"screenshot":"flagonly"}]' --window-size=400,900)"
  W400="$(width_of "$TMPROOT/phone/phone.json")"
  WDEF="$(width_of "$TMPROOT/wide/wide.json")"
  WFLAG="$(width_of "$TMPROOT/flagonly/flagonly.json")"
  check "1a. the look finished without a rig failure" \
    "[ \"$RC_V\" = '0' ] || [ \"$RC_V\" = '3' ]"
  check "1b. it produced the picture it was asked for, with a readout beside it" \
    "[ -f '$TMPROOT/phone/phone.png' ] && [ -f '$TMPROOT/phone/phone.json' ]"
  measured "the page reports window.innerWidth = ${W400} after a 400 px viewport step"
  check "1c. the page really laid out at 400 CSS px — BELOW headless Chrome's 500 px window floor" \
    "[ \"$W400\" = '400' ]"
  check "1d. the driver wrote down that it changed the viewport" \
    "grep -q '400' '$TMPROOT/phone/walk.json' && $PY -c \"
import json,sys
w=json.load(open('$TMPROOT/phone/walk.json'))
got=[a for a in (w.get('actions') or []) if isinstance(a,dict) and 'viewport' in a]
print(got)
sys.exit(0 if got and int(got[0]['viewport']['width'])==400 else 1)\""
  check "1e. …and said so in the notes the worker reads back" \
    "grep -qi 'viewport\|400' '$TMPROOT/phone/readout.json'"
else
  printf '  (skipped — no browser)\n'
fi

# ===========================================================================
# 2. THE SHOT PLACES WHEN CITED. The acceptance criterion, with its control.
# ===========================================================================
printf '\n\033[1m2. the 400 px shot has a landing readout and PLACES when a row cites it\033[0m\n'
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ] && [ -f "$TMPROOT/phone/phone.json" ]; then
  check "2a. the three facts a citation needs are all recorded beside the PNG" \
    "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/phone/phone.json'))
l=d.get('landed') or {}
print({k:(l.get(k) or '')[:40] for k in ('url','title','textSample')})
sys.exit(0 if l.get('url') and l.get('title') and l.get('textSample') else 1)\""
  check "2b. the page's own declared screen is recorded, so the rail can place it" \
    "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/phone/phone.json'))
sys.exit(0 if (d.get('landed') or {}).get('screen')=='screen-week' else 1)\""

  # ── A REAL SCORING RUN over the real shot. ------------------------------
  mkmission() { # <dir> [--strip]
    local d="$1" strip="${2:-}"
    mkdir -p "$d/shots/look-1"
    cp "$TMPROOT/phone/phone.png" "$TMPROOT/phone/phone.json" "$d/shots/look-1/"
    # A SECOND picture that DOES carry a landing, in both missions. The rail
    # switches OFF for a look in which no picture records a landing at all
    # (`landing_records_exist`) — so without this the strip control below would
    # pass vacuously, by turning the rail off rather than by failing the row.
    cp "$TMPROOT/wide/wide.png" "$d/shots/look-1/" 2>/dev/null
    cp "$TMPROOT/wide/wide.json" "$d/shots/look-1/" 2>/dev/null
    [ "$strip" = "--strip" ] && $PY - "$d/shots/look-1/phone.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("landed", None); d.pop("page", None)
json.dump(d, open(p, "w"), indent=1)
PY
    cat >"$d/criteria.json" <<'JSON'
{"mission": "s266-viewport", "hasDrawing": true, "placeNames": ["#screen-week"],
 "criteria": [
   {"id": "prd-1", "text": "At phone width the week grid shows today's column.",
    "source": "prd", "primary": true,
    "drawnAt": "the week grid on #screen-week"}
 ]}
JSON
    cat >"$d/verdict.json" <<'JSON'
{"score": "medium", "summary": "looked at the week grid at phone width",
 "criteria": [
   {"id": "prd-1", "status": "met", "evidence": "picture", "note": "",
    "shot": "phone", "checkedBy": "browser"}
 ],
 "gaps": [], "couldNot": []}
JSON
  }
  scorerun() { # <mission dir> <out dir>
    local d="$1" o="$2"; mkdir -p "$o"
    "$PY" "$CAGE" 180 "$PY" "$SCORE" "$d/verdict.json" "$d/criteria.json" \
      "$o/verdict.json" "" "" "" "" "" "" "" "" "" "" "$d/shots" \
      >"$o/wire.txt" 2>"$o/err.txt"
  }
  M="$TMPROOT/m-good"; mkmission "$M"; scorerun "$M" "$TMPROOT/s-good"
  check "2c. the row citing the 400 px shot KEEPS its verdict — it is not demoted" \
    "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/s-good/verdict.json'))
r=[c for c in d['criteria'] if c['id']=='prd-1'][0]
print(r.get('status'), '|', (r.get('note') or '')[:80])
sys.exit(0 if r.get('status')=='met' and 'no landing record' not in (r.get('note') or '')
         and 'I could not check this picture' not in (r.get('note') or '') else 1)\""
  check "2c. …and the report the captain reads carries no unplaced-picture mark" \
    "[ -s '$TMPROOT/s-good/report.md' ] && ! grep -q 'I did not check this picture' '$TMPROOT/s-good/report.md' && ! grep -q 'no landing record' '$TMPROOT/s-good/report.md'"

  N="$TMPROOT/m-bare"; mkmission "$N" --strip; scorerun "$N" "$TMPROOT/s-bare"
  check "2d. CONTROL — strip the readout off the SAME picture and the SAME row collapses" \
    "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/s-bare/verdict.json'))
r=[c for c in d['criteria'] if c['id']=='prd-1'][0]
print(r.get('status'), '|', (r.get('note') or '')[:80])
sys.exit(0 if r.get('status')=='untested' else 1)\""
check "2d. CONTROL — …and the SAME grep 2c relies on DOES fire on that report" \
  "grep -q 'no landing record' '$TMPROOT/s-bare/report.md'"
else
  printf '  (skipped — no 400 px shot to score)\n'
fi

# ===========================================================================
# 3. CONTROL — THE DEFAULT IS UNCHANGED. Every existing caller asked for
#    nothing and must still get 1440x900.
# ===========================================================================
printf '\n\033[1m3. CONTROL — with no viewport step and no flag, nothing moved\033[0m\n'
if [ "$HAVE_NODE" -eq 1 ]; then
  # Every argv goes to a file; see the note at row 0d.
  node "$DRIVER" --print-chrome-argv --url x --out "$TMPROOT/argv" \
    >"$TMPROOT/argv-default.json" 2>/dev/null
  check "3a. the default argv still says --window-size=1440,900, exactly once" \
    "[ \"\$(grep -o -- '--window-size=[0-9,]*' '$TMPROOT/argv-default.json' | wc -l | tr -d ' ')\" = '1' ] && grep -qF -- '\"--window-size=1440,900\"' '$TMPROOT/argv-default.json'"
  node "$DRIVER" --print-chrome-argv --window-size=1024,768 --url x --out "$TMPROOT/argv" \
    >"$TMPROOT/argv-eq.json" 2>/dev/null
  node "$DRIVER" --print-chrome-argv --window-size 1024,768 --url x --out "$TMPROOT/argv" \
    >"$TMPROOT/argv-sp.json" 2>/dev/null
  check "3b. the flag is honoured when a caller gives one, in either spelling" \
    "grep -qF -- '\"--window-size=1024,768\"' '$TMPROOT/argv-eq.json' && grep -qF -- '\"--window-size=1024,768\"' '$TMPROOT/argv-sp.json'"
  node "$DRIVER" --print-chrome-argv --window-size=not-a-size --url x --out "$TMPROOT/argv" \
    >"$TMPROOT/argv-junk.json" 2>/dev/null
  check "3c. a nonsense size falls back to the default rather than to nothing" \
    "grep -qF -- '\"--window-size=1440,900\"' '$TMPROOT/argv-junk.json'"
  check "3d. --headless=new is still in the argv, unconditionally" \
    "grep -qF -- '\"--headless=new\"' '$TMPROOT/argv-default.json'"
else
  printf '  (skipped — no node)\n'
fi
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then
  measured "with no viewport step the page reports window.innerWidth = ${WDEF}"
  check "3e. a look that asked for nothing still lays out at 1440 CSS px" \
    "[ \"$WDEF\" = '1440' ]"
  check "3f. …and its shot still carries the same landing readout it always did" \
    "$PY -c \"
import json,sys
l=(json.load(open('$TMPROOT/wide/wide.json')).get('landed') or {})
sys.exit(0 if l.get('url') and l.get('title') and l.get('textSample') else 1)\""

  # THE TRAP, MEASURED RATHER THAN ASSUMED: what the FLAG alone does at 400.
  # This is why no row in this file asserts the flag. Recorded, not graded —
  # Chrome's floor is Chrome's, and the capability does not rest on it.
  measured "--window-size=400,900 with NO viewport step lays out at window.innerWidth = ${WFLAG} (the checklist says Chrome floors a window at 500)"
  check "3g. the flag alone is a WINDOW, and the verb is the only thing proven to set a LAYOUT" \
    "[ \"$W400\" = '400' ] && [ \"$WFLAG\" != '?' ]"
else
  printf '  (skipped — no browser)\n'
fi

# ===========================================================================
# 4. CONTROL — A BROWSER VERB IS NOT A REACH. The argv fence did not move one
#    byte, and it still refuses a shell-shaped step.
# ===========================================================================
printf '\n\033[1m4. CONTROL — the argv fence is untouched and still refuses a shell\033[0m\n'
FENCE_MD5="$(sed -n '/^def argv_refusal/,/^def refuse_reason/p' "$XORUN" | sed '$d' | md5)"
check "4a. argv_refusal is byte-identical (md5 82278f1b3bf34f8b6a667b493b0cfbcc)" \
  "[ '$FENCE_MD5' = '82278f1b3bf34f8b6a667b493b0cfbcc' ]"

MDIR="$TMPROOT/mission"; mkdir -p "$MDIR"; : >"$MDIR/number-one.jsonl"
cat >"$TMPROOT/acts-fence.json" <<'JSON'
{"actions": [
  {"viewport": {"width": 400}},
  {"screenshot": "phone"},
  {"do": "run", "key": "w1", "argv": ["bash", "-c", "id"], "cwd": "<worktree>"},
  {"do": "run", "key": "w2", "argv": ["python3", "-c", "import os"], "cwd": "<worktree>"},
  {"do": "run", "key": "w3", "argv": ["bash", "run-tests.sh"], "cwd": "<worktree>"},
  {"teleport": "#screen-week"}
]}
JSON
"$PY" "$XORUN" actions --actions "$TMPROOT/acts-fence.json" \
  --out "$TMPROOT/acts-kept.json" --mission-dir "$MDIR" \
  >"$TMPROOT/acts.out" 2>&1
check "4b. the viewport step is KEPT, as a browser step beside the screenshot" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/acts-kept.json'))
steps=d.get('steps') or []
print(steps)
sys.exit(0 if any('viewport' in s for s in steps) and any('screenshot' in s for s in steps) else 1)\""
check "4c. …and it is a BROWSER step, never handed to the reach executor" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/acts-kept.json'))
sys.exit(0 if not any('viewport' in s for s in (d.get('reachSteps') or [])) else 1)\""
check "4d. the two shell-shaped reach steps are still REFUSED" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/acts-kept.json'))
kept={s.get('key') for s in (d.get('reachSteps') or [])}
print('kept', kept, 'refused', [r.get('why','')[:30] for r in (d.get('refused') or [])])
sys.exit(0 if not (kept & {'w1','w2'}) and len(d.get('refused') or [])>=2 else 1)\""
check "4e. POSITIVE CONTROL — the legitimate reach step is still kept" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/acts-kept.json'))
sys.exit(0 if 'w3' in {s.get('key') for s in (d.get('reachSteps') or [])} else 1)\""
check "4f. an unknown verb is still refused BY NAME — the vocabulary widened by one, not open" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/acts-kept.json'))
named=[r.get('verb') or '' for r in (d.get('refused') or [])]
print(named)
sys.exit(0 if any('teleport' in n for n in named) else 1)\""

# ===========================================================================
# 5. MUTATION — neutralise the override call and watch section 1 go RED.
#    Without this row, section 1 could be passing on a browser that was
#    already laying out at 400 for some other reason.
# ===========================================================================
printf '\n\033[1m5. MUTATION — remove the override call and the rendered width stops moving\033[0m\n'
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then
  MUT="$TMPROOT/mutant.js"
  MUTSAID="$("$PY" - "$DRIVER" "$MUT" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding="utf-8").read().splitlines(True)
hits = 0
out = []
for ln in src:
    if "VIEWPORT-OVERRIDE" in ln:
        hits += 1
        out.append("          await Promise.resolve(); // MUTATED: override removed\n")
    else:
        out.append(ln)
io.open(sys.argv[2], "w", encoding="utf-8").write("".join(out))
print("mutated %d line(s)" % hits)
PY
)"
  measured "$MUTSAID"
  check "5a. there is exactly ONE override call in the driver, and it was removed" \
    "[ '$MUTSAID' = 'mutated 1 line(s)' ] && [ -s '$MUT' ] && ! grep -q 'VIEWPORT-OVERRIDE' '$MUT'"
  drive "$MUT" "$TMPROOT/mut" '[{"viewport":{"width":400}},{"screenshot":"phone"}]' >/dev/null
  WMUT="$(width_of "$TMPROOT/mut/phone.json")"
  measured "with the override call removed the page reports window.innerWidth = ${WMUT}"
  check "5b. the mutant does NOT reach 400 px — section 1 is measuring the override" \
    "[ \"$WMUT\" != '400' ]"
  check "5c. …it falls back to the window it was launched with, 1440" \
    "[ \"$WMUT\" = '1440' ]"
else
  printf '  (skipped — no browser)\n'
fi

# ===========================================================================
# 6. THE VERB IS NAMED WHERE THE REVIEWER WILL READ IT (S266 fix round 1).
#
# A capability nothing tells the reviewer about is not a capability. The verb
# worked from the day it landed and the reviewer's own embedded checklist still
# taught the iframe workaround, so a live look could not have produced the
# phone-width shot this round exists for — and the next question, "does a
# reviewer actually use it?", would have answered no for the wrong reason.
#
# WHERE IT IS TAUGHT. `skills/lcars-run/live-check/web.md` item 3, which
# `run.sh`'s `number_one_checklists` cats VERBATIM into the assembled prompt
# when the mission's criteria declare a `web` product type. That is the route
# S265 used, and it never touches `prompts/evaluate.md` (which has a 689-line
# ceiling that lcars-xo-near-miss 6a holds).
#
# THIS IS NOT A GREP OVER THE CHECKLIST FILE. It assembles a REAL prompt
# through `run.sh spawn-number-one`, with the worker adapter replaced by a
# script that writes the prompt it was handed to disk — so what is asserted is
# the text the reviewer is actually served, not the text on disk upstream of an
# assembler that might drop it.
#
# THE MUTATION CONTROL: the same assembly, over a copy of the live-check dir
# with item 3's viewport step and preference sentence removed. Every row below
# must go the other way there, or the row is passing on something else.
# ===========================================================================
printf '\n\033[1m6. the verb is named in a REAL assembled prompt, and nothing else teaches it\033[0m\n'
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
LCDIR="$REPO_ROOT/skills/lcars-run/live-check"

PREPO="$TMPROOT/prompt-repo"; mkdir -p "$PREPO"
( cd "$PREPO" && git init -q -b main && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' >"$PREPO/f.txt"
( cd "$PREPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$PREPO/.git/lcars/missions/lcars-1/xo"
cat >"$PREPO/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$PREPO/.git/lcars/missions/lcars-1/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-06T10:00:00Z"}
SJ
printf '# p\n' >"$PREPO/.git/lcars/missions/lcars-1/prd.md"
PIN="$TMPROOT/prompt-in"; mkdir -p "$PIN"
cat >"$PIN/criteria.json" <<'CR'
{"productTypes": [{"type": "web", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "At phone width the week grid shows today."}]}
CR
# THE SEAM: the adapter is handed the assembled prompt as $5 and writes it out.
PDUMP="$TMPROOT/prompt-dump.sh"
cat >"$PDUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$PDUMP"
assemble() { # <out-prompt> <live-check-dir>
  ( cd "$PREPO" && XO_PROMPT_DUMP="$1" LCARS_WORKER_ADAPTER="$PDUMP" \
      LCARS_WORKER_BIN="$SHIM/claude" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$PIN" \
      LCARS_GH_BIN=/usr/bin/true LCARS_LIVE_CHECK_DIR="$2" \
      bash "$RUNSH" spawn-number-one --mission lcars-1 --mode evaluate \
        --outdir "$TMPROOT/pout-$RANDOM" ) >/dev/null 2>&1
}

# The MUTANT checklist dir: item 3's viewport step and its preference sentence
# deleted, everything else byte-identical.
MUTLC="$TMPROOT/live-check-mutant"; mkdir -p "$MUTLC"; cp "$LCDIR"/*.md "$MUTLC"/
MUTLCSAID="$("$PY" - "$MUTLC/web.md" <<'PY'
import io, re, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
n = 0
for pat in (r'\[\{"viewport": \{"width": 400\}\}, \{"screenshot": "phone"\}\]',
            r'`\{"viewport": \{"width": 400\}\}`',
            r'\*\*Prefer the viewport step[^*]*\*\*'):
    t, k = re.subn(pat, "REDACTED", t)
    n += k
t = re.sub(r'viewport', "window", t, flags=re.I)
io.open(p, "w", encoding="utf-8").write(t)
print("redacted %d passage(s)" % n)
PY
)"
measured "$MUTLCSAID"

P_REAL="$TMPROOT/prompt-real.txt"; assemble "$P_REAL" "$LCDIR"
P_MUT="$TMPROOT/prompt-mutant.txt"; assemble "$P_MUT" "$MUTLC"

check "6a. the assembly seam works at all — a real prompt was produced, with the web checklist in it" \
  "[ -s '$P_REAL' ] && grep -qF 'live-check/web.md' '$P_REAL' && grep -qF 'Phone width' '$P_REAL'"
check "6b. the assembled prompt names the verb, in the exact shape xo-run.py accepts" \
  "grep -qF '{\"viewport\": {\"width\": 400}}' '$P_REAL'"
check "6c. …as a step list the reviewer can hand straight to the driver, beside a screenshot" \
  "grep -qF '[{\"viewport\": {\"width\": 400}}, {\"screenshot\": \"phone\"}]' '$P_REAL'"
check "6d. …and it says WHICH to prefer, so a reader does not have to infer it" \
  "grep -qiF 'Prefer the viewport step' '$P_REAL'"
check "6e. …and states the trap: the flag alone is a window, not a layout" \
  "grep -qF -- 'A \`--window-size\` of' '$P_REAL' && grep -qF 'window.innerWidth =' '$P_REAL'"
check "6f. the iframe survives, explicitly demoted to the no-browser fallback" \
  "grep -qF 'FALLBACK' '$P_REAL' && grep -qF 'width:400px' '$P_REAL'"
check "6g. last round's namespaced near-miss evidence file is undisturbed" \
  "grep -qF '08-near-miss-web.txt' '$P_REAL'"
# ── THE CONTROL. Same assembler, same mission, checklist redacted. ─────────
check "6h. CONTROL — with item 3 redacted the assembled prompt does NOT name the verb" \
  "! grep -qF '{\"viewport\": {\"width\": 400}}' '$P_MUT'"
check "6i. CONTROL — …nor say which to prefer" \
  "! grep -qiF 'Prefer the viewport step' '$P_MUT'"
check "6j. CONTROL — …while still being a real assembled prompt with the web checklist in it" \
  "[ -s '$P_MUT' ] && grep -qF 'live-check/web.md' '$P_MUT' && grep -qF 'Phone width' '$P_MUT'"

# ===========================================================================
# 8. S266 FIX ROUND 2, FIX 1 — A STEP THAT WAS KEPT AND NEVER RAN REACHES THE
#    NEXT ROUND'S PROMPT, AND THE PROMPT STOPS CLAIMING PICTURES.
#
# THE MEASURED DEFECT, on one real review of this very branch. `lcars launch`
# died — "Could not start the server on port 8765: [Errno 48] Address already
# in use" (the captain's own viewscreen holds that port) — so `xo.sh` set
# `nopage=1` and skipped everything from the seed to the last round's shots.
# The reviewer's ELEVEN declared browser steps were recorded
# `asked: 11, refused: [], dropped: [], overflow: 0`: KEPT, and not one
# executed. Because nothing was REFUSED and nothing was DROPPED, neither of the
# two sections S264 added could fire — and rounds 2 and 3 still opened with
# "The build is RUNNING, in a browser LCARS drove for you, and you are looking
# at the pictures it took", over a directory with no PNG in it.
# ===========================================================================
printf '\n\033[1m8. a step KEPT and never run reaches the prompt, and the prompt stops claiming pictures\033[0m\n'

NP="$TMPROOT/nopage"; mkdir -p "$NP"
cat >"$NP/xo-actions.json" <<'AJ'
{"actions": [
  {"viewport": {"width": 400}, "key": "phone-width", "for": "prd-1",
   "fromChecklist": "3. Phone width"},
  {"screenshot": "phone", "key": "phone-shot", "for": "prd-1"},
  {"run": true, "argv": ["echo", "hello"], "key": "suite-verbose", "for": "prd-2",
   "evidence": "live-check/01-suite.txt"}
]}
AJ
WHY="your build did not start - could not start the server on port 8765: [Errno 48] Address already in use"
"$PY" "$XORUN" actions --actions "$NP/xo-actions.json" --out "$NP/kept-nopage.json" \
  --cap 12 --no-page "$WHY" >"$NP/say-nopage.txt" 2>&1
"$PY" "$XORUN" actions --actions "$NP/xo-actions.json" --out "$NP/kept-page.json" \
  --cap 12 >"$NP/say-page.txt" 2>&1
measured "with no page: $(tr -d '\n' <"$NP/say-nopage.txt")"
measured "with a page: $(tr -d '\n' <"$NP/say-page.txt")"

check "8a. with no page, every KEPT BROWSER step is recorded as kept-and-never-run" \
  "$PY -c \"
import json,sys
d=json.load(open('$NP/kept-nopage.json'))
u=d.get('unrun') or []
print('asked',d['asked'],'refused',len(d['refused']),'dropped',len(d['dropped']),'unrun',len(u))
print([r.get('key') for r in u])
sys.exit(0 if len(u)==2 and sorted(r.get('key') for r in u)==['phone-shot','phone-width']
         and not d['refused'] and not d['dropped'] else 1)\""
check "8a. …with the worker's own label, what it asked for, and the launch reason on each row" \
  "$PY -c \"
import json,sys
d=json.load(open('$NP/kept-nopage.json'))
r=[x for x in d['unrun'] if x.get('key')=='phone-width'][0]
print(r)
sys.exit(0 if r.get('for')=='prd-1' and r.get('fromChecklist','').startswith('3.')
         and 'never came up' in r.get('why','') and 'port 8765' in r.get('why','')
         and 'refused' not in r.get('why','').replace('nothing about its shape was refused','')
         else 1)\""
check "8a. …and the REACH step is untouched — a command line still runs with no page" \
  "$PY -c \"
import json,sys
d=json.load(open('$NP/kept-nopage.json'))
print('reachSteps',[s.get('key') for s in d['reachSteps']])
sys.exit(0 if [s.get('key') for s in d['reachSteps']]==['suite-verbose'] else 1)\""
check "8b. CONTROL — with a page the SAME three steps record NO un-run rows at all" \
  "$PY -c \"
import json,sys
d=json.load(open('$NP/kept-page.json'))
print('unrun',d.get('unrun'),'noPage',d.get('noPage'))
sys.exit(0 if (d.get('unrun') or [])==[] and not d.get('noPage')
         and len(d['steps'])==2 and len(d['reachSteps'])==1 else 1)\""

# ── THE RECORD REACHES THE JOURNEY, which is what the prompt reads. ────────
JDIR="$TMPROOT/journey"; mkdir -p "$JDIR"
printf '{"steps": []}\n' >"$JDIR/nopage.json"
printf '{"steps": []}\n' >"$JDIR/healthy.json"
"$PY" "$REPO_ROOT/skills/lcars-xo/xo-journey.py" reach-record \
  --journey "$JDIR/nopage.json" --steps "$NP/kept-nopage.json" --round 1 \
  >"$JDIR/say.txt" 2>&1
"$PY" "$REPO_ROOT/skills/lcars-xo/xo-journey.py" reach-record \
  --journey "$JDIR/healthy.json" --steps "$NP/kept-page.json" --round 1 \
  >"$JDIR/say-healthy.txt" 2>&1
measured "reach-record said: $(tr -d '\n' <"$JDIR/say.txt")"
check "8c. the un-run rows land on journey.json.unrunSteps with their round, and the reason beside them" \
  "$PY -c \"
import json,sys
j=json.load(open('$JDIR/nopage.json'))
u=j.get('unrunSteps') or []
print(len(u), [r.get('round') for r in u], (j.get('noPage') or '')[:40])
sys.exit(0 if len(u)==2 and all(r.get('round')=='1' for r in u)
         and 'port 8765' in (j.get('noPage') or '') else 1)\""
check "8c. CONTROL — the healthy round writes NEITHER key onto the journey" \
  "$PY -c \"
import json,sys
j=json.load(open('$JDIR/healthy.json'))
print(sorted(j.keys()))
sys.exit(0 if 'unrunSteps' not in j and 'noPage' not in j else 1)\""

# ── AND INTO THE NEXT ROUND'S PROMPT. Same real assembler as section 6. ───
PICIN="$TMPROOT/prompt-in-pics"; mkdir -p "$PICIN/shots"
cp "$PIN/criteria.json" "$PICIN/criteria.json"
"$PY" - "$PICIN/shots/shot-01.png" <<'PY'
import base64, sys
open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="))
PY
assemble2() { # <out-prompt> <input-dir> [extra env assignments…]
  local out="$1" indir="$2"; shift 2
  ( cd "$PREPO" && env XO_PROMPT_DUMP="$out" LCARS_WORKER_ADAPTER="$PDUMP" \
      LCARS_WORKER_BIN="$SHIM/claude" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$indir" \
      LCARS_GH_BIN=/usr/bin/true LCARS_LIVE_CHECK_DIR="$LCDIR" "$@" \
      bash "$RUNSH" spawn-number-one --mission lcars-1 --mode evaluate \
        --outdir "$TMPROOT/pout8-$RANDOM" ) >/dev/null 2>&1
}
P_NOPAGE="$TMPROOT/prompt-nopage.txt"
assemble2 "$P_NOPAGE" "$PIN" \
  LCARS_XO_JOURNEY="$JDIR/nopage.json" LCARS_XO_ROUND=2 LCARS_XO_NOPAGE="$WHY"
P_HEALTHY="$TMPROOT/prompt-healthy.txt"
assemble2 "$P_HEALTHY" "$PICIN" \
  LCARS_XO_JOURNEY="$JDIR/healthy.json" LCARS_XO_ROUND=2

check "8d. the assembly seam still produced two real prompts" \
  "[ -s '$P_NOPAGE' ] && [ -s '$P_HEALTHY' ] && grep -qF 'Phone width' '$P_NOPAGE' && grep -qF 'Phone width' '$P_HEALTHY'"
check "8d. round 2's prompt NAMES both un-run steps and says they did not run" \
  "grep -qF 'phone-width' '$P_NOPAGE' && grep -qF 'phone-shot' '$P_NOPAGE' && grep -qF 'did not run' '$P_NOPAGE'"
check "8d. …says the build did not come up, and that THERE ARE NO PICTURES" \
  "grep -qF 'THE BUILD DID NOT COME UP IN A BROWSER, SO THERE ARE NO PICTURES' '$P_NOPAGE'"
check "8d. …quotes the launch failure the harness recorded, rather than a guess" \
  "grep -qF 'port 8765' '$P_NOPAGE'"
check "8d. …and never calls a kept step 'refused', which would send it rewriting a good one" \
  "$PY -c \"
import io,re,sys
t=io.open('$P_NOPAGE',encoding='utf-8').read()
i=t.find('THE BUILD DID NOT COME UP')
sec=t[i:t.find('## ', i+10)]
print(sec.count('refused'), '|', len(sec))
sys.exit(0 if 'nothing was refused' in sec and 'In round 1' in sec else 1)\""
check "8d. …and tells it not to grade a LOOKS claim on the unit tests instead" \
  "grep -qiF 'do not grade a criterion about what the page LOOKS LIKE' '$P_NOPAGE'"
check "8e. CONTROL — the healthy round's prompt carries NO such section at all" \
  "! grep -qF 'THE BUILD DID NOT COME UP' '$P_HEALTHY' && ! grep -qF 'WHAT THE HARNESS DID NOT RUN LAST ROUND' '$P_HEALTHY' && ! grep -qF 'phone-width' '$P_HEALTHY'"
check "8f. the no-pictures prompt does NOT tell the reviewer it is looking at pictures" \
  "! grep -qF 'you are looking at the pictures it took' '$P_NOPAGE' && ! grep -qF 'The build is RUNNING, in a browser LCARS drove' '$P_NOPAGE'"
check "8f. …and says so positively, so a reader is not left to infer it" \
  "grep -qF 'THERE ARE' '$P_NOPAGE' && grep -qF 'NO PICTURES' '$P_NOPAGE'"
check "8g. CONTROL — with a picture in the input directory the original wording is BYTE-FOR-BYTE back" \
  "grep -qF 'you are looking at the pictures it took' '$P_HEALTHY' && ! grep -qF 'NO PICTURES' '$P_HEALTHY'"
# ── AND THE CURE LEAVES NO LITTER IN THE WORKER'S OWN DIRECTORY. ──────────
# `worker_produced_nothing` reads "any real file in $outdir" as "the worker did
# something", so a harness-written file there would make a worker that produced
# NOTHING look like one that tried. The rewritten template is a temp file,
# removed after the spawn, and this proves it never lands in $outdir.
POUT="$TMPROOT/pout8-fixed"
( cd "$PREPO" && env XO_PROMPT_DUMP="$TMPROOT/prompt-litter.txt" \
    LCARS_WORKER_ADAPTER="$PDUMP" LCARS_WORKER_BIN="$SHIM/claude" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$PIN" \
    LCARS_GH_BIN=/usr/bin/true LCARS_LIVE_CHECK_DIR="$LCDIR" \
    LCARS_XO_JOURNEY="$JDIR/nopage.json" LCARS_XO_ROUND=2 LCARS_XO_NOPAGE="$WHY" \
    bash "$RUNSH" spawn-number-one --mission lcars-1 --mode evaluate \
      --outdir "$POUT" ) >/dev/null 2>&1
# `.worker.*` are the adapter's own captures and `xo-channel.json` is written
# AFTER the spawn by number_one_claim_output — both predate this round and
# neither is read as a worker artifact. Anything else would be new litter.
litter() { find "$POUT" -type f ! -name '.worker.*' ! -name 'xo-channel.json' "$@" 2>/dev/null; }
measured "files the harness left in the worker's output directory: $(litter | wc -l | tr -d ' ') ($(litter | sed "s|$POUT/||" | tr '\n' ' '))"
check "8h. the picture-less prompt was still produced on that very run" \
  "grep -qF 'NO PICTURES' '$TMPROOT/prompt-litter.txt'"
check "8h. …and the harness planted NO real file in the worker's output directory" \
  "[ -z \"\$(litter -print -quit)\" ]"
check "8g. CONTROL — and prompts/evaluate.md itself is untouched on disk" \
  "git -C '$REPO_ROOT' diff --quiet -- skills/lcars-xo/prompts/evaluate.md && [ \"\$(grep -c '' '$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md')\" -eq 688 ]"

# ===========================================================================
# 9. S266 FIX ROUND 2, FIX 2 — A ROW THAT CAN ONLY BE SETTLED BY LOOKING,
#    WITH NOTHING TO LOOK AT, IS NOT `met`.
#
# THE MEASURED DEFECT, on the same real review. With ZERO photographs the
# phone-width rows were graded `met` on the strength of the project's unit
# tests, and one row's own note admitted the gap: "I could not take a rendered
# 400px screenshot … so the pixel-level wrap/overflow is settled by the suite,
# not a photo." It said it could not check, and then said it was fine. The look
# returned HIGH / MERGE / "checked 15 of 15 (100%)", and the tester then
# rendered that same page at a measured 400 px and FALSIFIED one of those rows:
# 715 CSS px of document against a 400 px viewport, with three day-columns
# including TODAY entirely past the edge.
#
# WHERE THE LINE IS DRAWN, and it is deliberately the narrow one: `kind:
# "looks"` is the EYE'S OWN produce-time stamp meaning "a picture settles
# this". A row carrying that stamp, rated MET, citing NO picture at any width,
# is `couldn't check`. Everything else is untouched — a row WITH a picture (the
# landing rail already judges whether it was the right screen), a `works` or
# `notVisual` or unstamped row (nobody promised those a photograph), and any
# `gap` (a fault found without a camera is still a fault).
# ===========================================================================
printf '\n\033[1m9. a phone-width looks row with no picture scores "couldn'"'"'t check"\033[0m\n'

SC="$TMPROOT/score2"; mkdir -p "$SC/shots/look-1"
"$PY" - "$SC/shots/look-1/phone.png" <<'PY'
import base64, sys
open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="))
PY
# The sidecar a REAL 400 px shot carries — xo-drive.js writes exactly these
# fields, including the CSS width in `pixels`/`deviceScaleFactor`.
cat >"$SC/shots/look-1/phone.json" <<'PJ'
{"shot": "phone", "capturedAt": "2026-10-09T10:00:00Z", "selector": null,
 "clip": "full-page", "deviceScaleFactor": 2,
 "pixels": {"width": 800, "height": 1800, "painted": true, "distinctColours": 40},
 "page": {"url": "http://127.0.0.1:8765/week", "title": "Week - 400",
          "textExcerpt": "innerWidth=400 Mon Tue Wed",
          "places": {"screen-week": {"present": true, "laidOut": true,
                                     "box": {"x": 0, "y": 0, "w": 400, "h": 900}}}},
 "intent": null,
 "landed": {"url": "http://127.0.0.1:8765/week", "title": "Week - 400",
            "textSample": "innerWidth=400 Mon Tue Wed", "screen": "screen-week"}}
PJ
cat >"$SC/tests.json" <<'TJ'
{"ran": true, "outcome": "passed", "command": "true",
 "testCases": ["week_grid_has_today_column", "week_grid_wraps_at_phone_width"],
 "outputTail": "ok week_grid_has_today_column\nok week_grid_wraps_at_phone_width\n2 passing"}
TJ
cat >"$SC/criteria.json" <<'CJ'
{"mission": "s266-fix2", "hasDrawing": true, "placeNames": ["#screen-week"],
 "criteria": [
  {"id": "prd-1", "text": "At 400 px the week grid wraps and today's column is on screen.",
   "source": "prd", "primary": true, "drawnAt": "the week grid on #screen-week"},
  {"id": "prd-2", "text": "At 400 px the week grid wraps and today's column is on screen.",
   "source": "prd", "primary": true, "drawnAt": "the week grid on #screen-week"},
  {"id": "prd-3", "text": "Saving an entry stores it.", "source": "prd",
   "drawnAt": "the save control on #screen-week"},
  {"id": "prd-4", "text": "The totals add up.", "source": "prd",
   "drawnAt": "the totals row on #screen-week"},
  {"id": "prd-5", "text": "At 400 px nothing overflows.", "source": "prd",
   "drawnAt": "the week grid on #screen-week"}
 ]}
CJ
# ONE verdict carrying all five shapes, so every row below is scored by the SAME
# run of the scorer over the SAME evidence — the difference is the row, never
# the fixture.
cat >"$SC/verdict.json" <<'VJ'
{"score": "high", "summary": "checked the week screen",
 "criteria": [
  {"id": "prd-1", "status": "met", "kind": "looks", "evidence": "tests",
   "checkedBy": "test", "testQuote": "week_grid_wraps_at_phone_width",
   "note": "I could not take a rendered 400px screenshot, so the pixel-level wrap/overflow is settled by the suite, not a photo."},
  {"id": "prd-2", "status": "met", "kind": "looks", "evidence": "picture",
   "checkedBy": "browser", "shot": "phone", "note": "the 400 px picture shows the grid wrapped"},
  {"id": "prd-3", "status": "met", "kind": "works", "evidence": "tests",
   "checkedBy": "test", "testQuote": "week_grid_has_today_column",
   "note": "the suite exercises saving"},
  {"id": "prd-4", "status": "met", "evidence": "tests",
   "checkedBy": "test", "testQuote": "week_grid_has_today_column",
   "note": "the suite adds the totals up"},
  {"id": "prd-5", "status": "gap", "kind": "looks", "evidence": "tests",
   "checkedBy": "test", "testQuote": "week_grid_wraps_at_phone_width",
   "note": "the suite says the row overflows"}
 ],
 "gaps": [{"criterion": "prd-5", "title": "the week grid overflows at 400 px",
           "kind": "contradiction", "evidence": "tests",
           "testQuote": "week_grid_wraps_at_phone_width"}],
 "couldNot": []}
VJ
score2() { # <out dir> <score script>
  local o="$1" sp="$2"; mkdir -p "$o"
  "$PY" "$CAGE" 180 "$PY" "$sp" "$SC/verdict.json" "$SC/criteria.json" \
    "$o/verdict.json" "" "$SC/tests.json" "" "" "" "" "" "" "" "" "$SC/shots" \
    >"$o/wire.txt" 2>"$o/err.txt"
}
rowof() { # <out dir> <id> <field>
  "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]+'/verdict.json'))
r=[c for c in d['criteria'] if c['id']==sys.argv[2]]
print((r[0].get(sys.argv[3]) if r else '') or '')" "$1" "$2" "$3"
}
score2 "$TMPROOT/s2" "$SCORE"
measured "prd-1 (looks, no picture, settled on the suite) -> $(rowof "$TMPROOT/s2" prd-1 status)/$(rowof "$TMPROOT/s2" prd-1 couldNotCheck)"
measured "prd-2 (looks, WITH the 400 px picture)        -> $(rowof "$TMPROOT/s2" prd-2 status)"
measured "prd-3 (works, settled on the suite)           -> $(rowof "$TMPROOT/s2" prd-3 status)"
measured "prd-4 (UNSTAMPED, settled on the suite)       -> $(rowof "$TMPROOT/s2" prd-4 status)"
measured "prd-5 (looks, no picture, a FAULT)            -> $(rowof "$TMPROOT/s2" prd-5 status)"

check "9a. the looks row with no picture is NOT met — it is couldn't check, by name" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-1 status)\" = untested ] && \
   [ \"\$(rowof '$TMPROOT/s2' prd-1 couldNotCheck)\" = needs-a-picture ] && \
   [ \"\$(rowof '$TMPROOT/s2' prd-1 evidence)\" = none ]"
check "9a. …its reason says a photograph is what settles it, and the tests do not" \
  "rowof '$TMPROOT/s2' prd-1 note | grep -qiF 'no picture of it' && \
   rowof '$TMPROOT/s2' prd-1 note | grep -qiF 'the project'\\''s tests do not'"
check "9a. …it reads as a gap in MY checking (couldnt-see), never a doubt about the build" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-1 outcome)\" = couldnt-see ]"
check "9a. …and the captain's report no longer counts it as checked" \
  "[ -s '$TMPROOT/s2/report.md' ] && ! grep -q 'checked 5 of 5' '$TMPROOT/s2/report.md'"
check "9a. …and it is named as data, so no surface has to re-derive it" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/s2/verdict.json'))
n=[r['id'] for r in (d.get('looksWithNoPicture') or [])]
print(n)
sys.exit(0 if n==['prd-1'] else 1)\""
check "9b. CONTROL — the SAME claim WITH a valid 400 px picture still settles" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-2 status)\" = met ] && \
   [ -z \"\$(rowof '$TMPROOT/s2' prd-2 couldNotCheck)\" ]"
check "9c. CONTROL — a works row the unit tests legitimately settle is UNAFFECTED" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-3 status)\" = met ] && \
   [ -z \"\$(rowof '$TMPROOT/s2' prd-3 couldNotCheck)\" ]"
check "9c. CONTROL — and so is an UNSTAMPED row with no picture (nobody promised it one)" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-4 status)\" = met ]"
check "9d. CONTROL — a looks FAULT found with no picture is still a fault, not demoted" \
  "[ \"\$(rowof '$TMPROOT/s2' prd-5 status)\" = gap ]"
check "9e. the grade rules themselves are untouched — derive_grade/derive_recommendation and the floor" \
  "[ \"\$(git -C '$REPO_ROOT' diff -U0 -- skills/lcars-xo/xo-score.py | grep -c '^[-+].*def derive_grade\\|^[-+].*def derive_recommendation')\" = 0 ]"

# ===========================================================================
# 10. MUTATION — REVERT EACH CURE AND WATCH THE RIGHT CHECK GO RED.
#
# BY BEHAVIOUR, NEVER BY A SOURCE GREP. Each mutant is a COPY of the real file
# with exactly one cure neutralised; the mutant is then RUN, and the very
# assertion section 8 or 9 relies on is re-evaluated against its output. A grep
# for a comment would pass over a cure that had stopped working.
# ===========================================================================
printf '\n\033[1m10. MUTATION — revert each cure, one at a time\033[0m\n'
MUT="$TMPROOT/mutants"; mkdir -p "$MUT"

# ── M1. The producer stops recording the kept-but-never-run steps. ─────────
"$PY" - "$XORUN" "$MUT/xo-run-m1.py" <<'PY'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
t = io.open(src, encoding="utf-8").read()
hook = ("        if nopage_why and kind in BROWSER_KINDS and kind not in REACH_KINDS:\n"
        "            unrun.append(unrun_row(a, kind, nopage_why))\n")
assert t.count(hook) == 1, "the FIX 1 producer hook is not where the mutation expects it"
t = t.replace(hook, "        if False:\n            unrun.append(unrun_row(a, kind, nopage_why))\n", 1)
io.open(dst, "w", encoding="utf-8").write(t)
print("M1 written")
PY
"$PY" "$MUT/xo-run-m1.py" actions --actions "$NP/xo-actions.json" \
  --out "$MUT/kept-m1.json" --cap 12 --no-page "$WHY" >/dev/null 2>&1
check "10a. MUTATION M1 — with the producer hook reverted, 8a's assertion FAILS" \
  "! $PY -c \"
import json,sys
d=json.load(open('$MUT/kept-m1.json'))
u=d.get('unrun') or []
sys.exit(0 if len(u)==2 else 1)\""
check "10a. …and it is still a working classifier (the mutant kept the same steps)" \
  "$PY -c \"
import json,sys
d=json.load(open('$MUT/kept-m1.json'))
sys.exit(0 if len(d['steps'])==2 and len(d['reachSteps'])==1 else 1)\""

# ── A MUTANT SKILLS TREE, so run.sh still finds its own neighbours. Every
#    OTHER skill directory is SYMLINKED to the real one and only `lcars-run` is
#    a copy, so the one and only difference between the mutant and the shipped
#    harness is the line each mutation below deletes. (`run.sh` resolves its
#    state library, its prompts and its adapters through `$SKILL_DIR/../`, so a
#    bare copy of the one file cannot start at all — measured.)
mutskill() { # <dest> — a skills/ tree whose lcars-run is a writable copy
  local dest="$1" d
  mkdir -p "$dest/skills"
  for d in "$REPO_ROOT/skills"/*; do
    [ -d "$d" ] || continue
    ln -s "$d" "$dest/skills/$(basename "$d")"
  done
  rm -f "$dest/skills/lcars-run"
  cp -R "$REPO_ROOT/skills/lcars-run" "$dest/skills/lcars-run"
}
mutskill "$MUT/m2"; mutskill "$MUT/m3"
"$PY" - "$MUT/m2/skills/lcars-run/run.sh" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
hook = 'if unrun:\n    out.append("**THE BUILD DID NOT COME UP IN A BROWSER, SO THERE ARE NO PICTURES.** "'
assert t.count(hook) == 1, "the FIX 1 prompt section is not where the mutation expects it"
t = t.replace(hook, 'if False:\n    out.append("**THE BUILD DID NOT COME UP IN A BROWSER, SO THERE ARE NO PICTURES.** "', 1)
io.open(p, "w", encoding="utf-8").write(t)
print("M2 written")
PY
"$PY" - "$MUT/m3/skills/lcars-run/run.sh" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
hook = 'CLAIM = ("The build is RUNNING, in a browser LCARS drove\\n"'
assert t.count(hook) == 1, "the FIX 1 no-pictures substitution is not where the mutation expects it"
t = t.replace(hook, 'CLAIM = ("The build is CRUISING, in a browser LCARS drove\\n"', 1)
io.open(p, "w", encoding="utf-8").write(t)
print("M3 written")
PY
assemble_mut() { # <out-prompt> <mutant run.sh> <input-dir> [env…]
  local out="$1" rsh="$2" indir="$3"; shift 3
  ( cd "$PREPO" && env XO_PROMPT_DUMP="$out" LCARS_WORKER_ADAPTER="$PDUMP" \
      LCARS_WORKER_BIN="$SHIM/claude" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$indir" \
      LCARS_GH_BIN=/usr/bin/true LCARS_LIVE_CHECK_DIR="$LCDIR" "$@" \
      bash "$rsh" spawn-number-one --mission lcars-1 --mode evaluate \
        --outdir "$TMPROOT/poutm-$RANDOM" ) >/dev/null 2>&1
}
P_M2="$MUT/prompt-m2.txt"
assemble_mut "$P_M2" "$MUT/m2/skills/lcars-run/run.sh" "$PIN" \
  LCARS_XO_JOURNEY="$JDIR/nopage.json" LCARS_XO_ROUND=2 LCARS_XO_NOPAGE="$WHY"
P_M3="$MUT/prompt-m3.txt"
assemble_mut "$P_M3" "$MUT/m3/skills/lcars-run/run.sh" "$PIN" \
  LCARS_XO_JOURNEY="$JDIR/nopage.json" LCARS_XO_ROUND=2 LCARS_XO_NOPAGE="$WHY"
check "10b. MUTATION M2 — with the prompt section reverted, 8d's assertion FAILS" \
  "[ -s '$P_M2' ] && ! grep -qF 'phone-width' '$P_M2'"
check "10b. …and it is still a real assembled prompt (the mutant only lost that section)" \
  "grep -qF 'live-check/web.md' '$P_M2' && grep -qF 'Phone width' '$P_M2'"
check "10c. MUTATION M3 — with the substitution reverted, 8f's assertion FAILS" \
  "[ -s '$P_M3' ] && grep -qF 'you are looking at the pictures it took' '$P_M3'"
check "10c. …and the sibling cure is untouched in that same mutant, so the two are independent" \
  "grep -qF 'THE BUILD DID NOT COME UP IN A BROWSER' '$P_M3'"

# ── M4. The scorer stops demoting a looks row with no picture. ─────────────
"$PY" - "$SCORE" "$MUT/xo-score-m4.py" <<'PY'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
t = io.open(src, encoding="utf-8").read()
hook = ('        if kind == "looks" and e["status"] == "met" \\\n'
        '                and not str(e.get("shot") or "").strip():\n')
assert t.count(hook) == 1, "the FIX 2 downgrade is not where the mutation expects it"
t = t.replace(hook, '        if False:\n', 1)
io.open(dst, "w", encoding="utf-8").write(t)
print("M4 written")
PY
score2 "$MUT/s4" "$MUT/xo-score-m4.py"
measured "M4: prd-1 scores $(rowof "$MUT/s4" prd-1 status) with the downgrade reverted"
check "10d. MUTATION M4 — with the downgrade reverted, 9a's assertion FAILS (back to met)" \
  "[ \"\$(rowof '$MUT/s4' prd-1 status)\" = met ]"
check "10d. …and the mutant scorer still scored the file (the controls are unmoved)" \
  "[ \"\$(rowof '$MUT/s4' prd-2 status)\" = met ] && [ \"\$(rowof '$MUT/s4' prd-5 status)\" = gap ]"

# ── THE THREE INVARIANTS THIS ROUND WAS FENCED BY. ─────────────────────────
printf '\n\033[1m11. the fences this round was given\033[0m\n'
check "11a. argv_refusal is STILL byte-identical (md5 82278f1b3bf34f8b6a667b493b0cfbcc)" \
  "[ \"\$(sed -n '/^def argv_refusal/,/^def refuse_reason/p' '$XORUN' | sed '\$d' | md5)\" = 82278f1b3bf34f8b6a667b493b0cfbcc ]"
check "11b. skills/lcars-eeh/ has a zero diff" \
  "git -C '$REPO_ROOT' diff --quiet -- skills/lcars-eeh && [ -z \"\$(git -C '$REPO_ROOT' status --porcelain -- skills/lcars-eeh)\" ]"
check "11c. prompts/evaluate.md is 688 lines and git-clean" \
  "[ \"\$(grep -c '' '$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md')\" -eq 688 ] && git -C '$REPO_ROOT' diff --quiet -- skills/lcars-xo/prompts/evaluate.md"
check "11d. xo-drive.js's viewport verb and its one override call are untouched by this round" \
  "[ \"\$(grep -c 'VIEWPORT-OVERRIDE' '$DRIVER')\" = 1 ]"

# ===========================================================================
# ZERO SPEND
# ===========================================================================
printf '\n\033[1m7. zero engine spend\033[0m\n'
SPEND="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
measured "engine invocations through the PATH shim: $SPEND"
check "7a. neither claude nor copilot was invoked once" "[ '$SPEND' = '0' ]"

printf '\nlcars xo-viewport: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
