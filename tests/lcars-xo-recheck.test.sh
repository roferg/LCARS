#!/usr/bin/env bash
#
# Tests for S222 fix round 1 — THE RE-CHECK'S OWN EYES.
#
# ── THE DEFECT (1): THE RE-CHECK PHOTOGRAPHED THE LANDING PAGE AND NOTHING ELSE
#
# Measured on the captain's own repo on 2026-09-20, on a real hands-off run.
# The first look planned a journey and DROVE it — `xo/shots/look-1/` holds 30
# walk artefacts, `shot-walk-00-wayin` through `shot-walk-09-j9`. The re-check
# drove nothing: `xo/shots/recheck-1/` holds 37 files and NOT ONE walk shot,
# because `cmd_recheck` called the same browser driver WITHOUT `--journey` and
# `--walk-out`. The urls prove it — the look's shot is of
# `…?snapshot=2026-07-27.0#mbr`, the re-check's of `…?snapshot=2026-07-27.0`.
# It never entered the flow. Every side-by-side it produced read
#
#     42 drawn part(s): 0 matched, 42 unreachable, 0 with a measured difference
#
# against 4 / 7 / 8 matched on the three looks. Three times out of three the
# fixes held and Number One still had to hand the mission back — in its own
# words, "a new test passes, but that is code, not the button on screen". The
# refusal was right; the pictures were missing.
#
# It was worse than missing. `walk.json` was the FIRST look's, and the re-check
# worker was handed it as this look's — so it read a walk that had not happened
# and said so out loud: "walk.json shows the relaunched build walked that flow
# end to end". A record of one look presented as the record of another is the
# S204 stale-shots defect wearing a different coat.
#
# ── THE DEFECT (2): WHAT IS HIS TO DECIDE NEVER REACHED HIM
#
# On the same run Number One SAW the August→September month jump, described it
# exactly, and — because no acceptance criterion named it — recorded it under
# `escalations` in verdict.json, "worth the captain's eye". It reached
# `report.md`. It reached NEITHER the console NOR `lcars xo report`. The one
# thing it flagged for him is the one thing he would never see.
#
# ── WHAT IS NOT FAKED HERE
#
# The walk is driven through REAL HEADLESS CHROME against a real local fixture,
# because the thing that changed is which arguments reach the browser driver and
# a stubbed driver would pass this file with the bug still in it. And the proof
# is a COMPARISON, not an assertion: the fixture's second screen does not exist
# in the page until the first screen's own button builds it, and six of the
# drawing's seven parts are drawn on it. So the journey-less drive — the very
# drive the re-check used to do — is run here as a CONTROL and reproduces the
# defect (1 matched, 6 unreachable) beside the look that walks (5 matched).
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-recheck.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
DRIVER="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
JOURNEY_PY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
PARTS_PY="$REPO_ROOT/skills/lcars-xo/xo-parts.py"
SCORE_PY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
REPORT_PY="$REPO_ROOT/skills/lcars-xo/xo-report.py"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "lcars xo recheck — the walk it drives, and what it hands the captain"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

FX="$TMPROOT/fx"; mkdir -p "$FX"
export XO_LAUNCH_LOG="$FX/launch-calls.txt";   : >"$XO_LAUNCH_LOG"
export XO_LABEL_LOG="$FX/label-calls.txt";     : >"$XO_LABEL_LOG"
export XO_WORKER_LOG="$FX/worker-calls.txt";   : >"$XO_WORKER_LOG"
export XO_RESPOND_CALLS="$FX/respond-calls.txt"; : >"$XO_RESPOND_CALLS"

# --- stubs: the launch verb, the host adapter, `lcars respond`, the worker ---
LAUNCH_STUB="$FX/launch.sh"
cat >"$LAUNCH_STUB" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s\n' "$mid" "$*" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
printf '{\n  "status": "running",\n  "url": "%s",\n  "pid": 1\n}\n' \
  "$XO_LAUNCH_URL" >"$m/launch.json"
LS
chmod +x "$LAUNCH_STUB"

HOST_STUB="$FX/host-adapter.sh"
printf '#!/usr/bin/env bash\nprintf "host %%s\\n" "$*" >>"$XO_LABEL_LOG"\nexit 0\n' >"$HOST_STUB"
chmod +x "$HOST_STUB"

RESPOND_STUB="$FX/respond.sh"
printf '#!/usr/bin/env bash\nprintf "respond %%s by=%%s\\n" "$*" "${LCARS_ANSWERED_BY:-}" >>"$XO_RESPOND_CALLS"\nexit 0\n' >"$RESPOND_STUB"
chmod +x "$RESPOND_STUB"

# The re-check worker: writes $XO_RC_BODY as its verdict. It is a shell script,
# never a CLI — this file spends nothing.
RC_SHIM="$FX/rc-worker"
cat >"$RC_SHIM" <<'RCS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
[ -n "${XO_RC_BODY:-}" ] && printf '%s\n' "$XO_RC_BODY" >"$out/xo-recheck.json"
exit 0
RCS
chmod +x "$RC_SHIM"

new_repo() {
  local repo
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'CJ'
{
  "cloneId": "aaaaaaaa",
  "projectName": "repo",
  "contextFile": null,
  "stack": null,
  "testCommand": "true",
  "numberOne": {"enabled": true, "engine": "copilot"},
  "created": "2026-09-20T00:00:00Z"
}
CJ
  printf '%s' "$repo"
}

plant_parent() { # <repo> <id> — a mission parked at Verify with a first look
  local repo="$1" id="$2" m="$1/.git/lcars/missions/$2"
  mkdir -p "$m/xo/logs" "$m/attachments"
  cat >"$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "round": "1"},
  "id": "$id",
  "type": "feature",
  "title": "The readings flow",
  "stage": "verify",
  "prUrl": "https://github.com/x/y/pull/7",
  "created": "2026-09-20T10:00:00Z",
  "githubIssue": 42
}
SJ
  cat >"$m/pending.json" <<'PJ'
{"stage": "verify", "kind": "reverify",
 "questions": ["2 logged bugs resolved on this branch — ready for your single re-verify."]}
PJ
  cat >"$m/xo/logs.json" <<'LJ'
{"round": 1, "overflow": 0, "filed": [
 {"n": 1, "mission": "lcars-20260920-901", "issue": "501", "criterion": "prd-1", "title": "gap 1", "shots": ["shot-01"]},
 {"n": 2, "mission": "lcars-20260920-902", "issue": "502", "criterion": "prd-2", "title": "gap 2", "shots": ["shot-01"]}]}
LJ
  cat >"$m/xo/verdict.json" <<'VJ'
{"score": "medium", "derivation": "two things short of the mark",
 "counts": {"met": 0, "gap": 0, "untested": 0, "contradictions": 2},
 "criteria": [], "gaps": [], "summary": "Two mismatches against your drawing."}
VJ
  printf 'the first look\n' >"$m/xo/report.md"
  printf '%s' "$m"
}

plant_child() { # <repo> <parent> <n>
  local repo="$1" parent="$2" n="$3" cid d
  cid="$(printf 'lcars-20260920-90%d' "$n")"
  d="$repo/.git/lcars/missions/$cid"; mkdir -p "$d"
  cat >"$d/state.json" <<SJ
{"id": "$cid", "type": "bug", "title": "gap $n", "stage": "verify",
 "githubIssue": $((500 + n)), "parentMission": "$parent", "branch": "lcars/$parent"}
SJ
}

run_recheck() { # <repo> <id> — the verb itself, real driver, real Chrome
  local repo="$1" id="$2"
  ( cd "$repo" && \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$DRIVER" LCARS_NODE_BIN="$NODE" \
    LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
    LCARS_WORKER_BIN="$RC_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" recheck --mission "$id" 2>&1 )
}

# ===========================================================================
# THE FIXTURE — a router, like the real one. The second screen does NOT exist
# in the page until the first screen's own button builds it, so a drive that
# does not click cannot photograph it, cannot measure it, and cannot pair it
# with the drawing. Six of the drawing's seven parts are drawn on it.
# ===========================================================================
APP="$FX/app"; mkdir -p "$APP"
cat >"$APP/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Tides</title>
<body style="font-family:sans-serif">
<div id="app">
  <h1>Readings</h1>
  <h2>August 2026</h2>
  <button id="startBtn">Pull data &amp; start</button>
</div>
<script>
  document.getElementById("startBtn").onclick = function () {
    document.getElementById("app").innerHTML =
      '<h2>Pulling data &middot; September 2026</h2>' +
      '<textarea id="note" placeholder="Add a note for this reading&hellip;"></textarea>' +
      '<button id="lockBtn">Lock month</button>' +
      '<button id="draftBtn">Save draft</button>' +
      '<button id="exportBtn">Export</button>' +
      '<button id="previewBtn">Preview</button><p id="out"></p>';
    document.getElementById("lockBtn").onclick = function () {
      var n = document.getElementById("note"), o = document.getElementById("out");
      if (!n.value.trim()) { o.textContent = "Add a note first."; return; }
      o.textContent = "Locked: " + n.value;
    };
  };
</script>
HTML
cat >"$APP/drawing.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>drawing</title>
<div id="screen-one"><h1>Readings</h1><button>Pull data &amp; start</button></div>
<div id="screen-two"><h2>Collect</h2><textarea placeholder="Add a note for this reading&hellip;"></textarea>
<button>Lock month</button><button>Save draft</button><button>Export</button><button>Preview</button></div>
HTML

HAVE_CHROME=0
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && HAVE_CHROME=1
done
command -v "$NODE" >/dev/null 2>&1 || HAVE_CHROME=0

# ===========================================================================
# W. THE RE-CHECK WALKS THE JOURNEY THE LOOK WALKED
# ===========================================================================
echo
echo "W. the re-check walks the journey the look walked (real headless Chrome)"

if [ "$HAVE_CHROME" -eq 0 ]; then
  printf '  (node or a Chrome is not on this machine — W SKIPPED)\n'
else

repoW="$(new_repo)"
mW="$(plant_parent "$repoW" "lcars-20260920-801")"
plant_child "$repoW" "lcars-20260920-801" 1
plant_child "$repoW" "lcars-20260920-801" 2
export XO_LAUNCH_URL="file://$APP/index.html"

cat >"$mW/xo/criteria.json" <<'CJ'
{"mission":"lcars-20260920-801","hasDrawing":true,"placeNames":[],"criteria":[
 {"id":"prd-1","text":"The reading screen offers the month and a Pull data & start button.","primary":true},
 {"id":"prd-2","text":"Lock month refuses while the note is blank.","primary":true}]}
CJ

# The drawing, read by the REAL driver exactly as `xo_read_drawing` reads it.
mkdir -p "$mW/xo/drawing"
"$NODE" "$DRIVER" --url "file://$APP/drawing.html" --out "$mW/xo/drawing" \
  --parts-out "$mW/xo/drawing-parts.json" --prefix drawn \
  >"$FX/drawing.json" 2>"$FX/drawing.err" || true
# The journey, planned by the REAL planner and left on disk the way a first look
# leaves it. THIS is the recorded plan the re-check has to re-use.
"$PY" "$JOURNEY_PY" build --criteria "$mW/xo/criteria.json" \
  --drawing-html "$APP/drawing.html" --drawing "$mW/xo/drawing-parts.json" \
  --title "Tides" --out "$mW/xo/journey.json" --criteria-out "$FX/criteria2.json" \
  >"$FX/journey.out" 2>&1 || true
[ -s "$FX/criteria2.json" ] && cp "$FX/criteria2.json" "$mW/xo/criteria.json"

# --- THE LOOK, driven exactly as `cmd_evaluate`'s round 0 drives it --------
mkdir -p "$mW/xo/shots/look-1"
"$NODE" "$DRIVER" --url "file://$APP/index.html" --out "$mW/xo/shots/look-1" \
  --place-names "$mW/xo/criteria.json" --prefix shot \
  --parts-out "$mW/xo/build-parts-0.json" \
  --journey "$mW/xo/journey.json" --walk-out "$mW/xo/walk.json" \
  >"$FX/drive-look.json" 2>"$FX/drive-look.err" || true
"$PY" "$PARTS_PY" pair --drawing "$mW/xo/drawing-parts.json" \
  --build "$mW/xo/build-parts-0.json" --out "$FX/pairs-look.json" >/dev/null 2>&1 || true

# --- THE CONTROL: the drive the re-check used to do — no journey ----------
mkdir -p "$FX/ctl"
"$NODE" "$DRIVER" --url "file://$APP/index.html" --out "$FX/ctl" \
  --place-names "$mW/xo/criteria.json" --prefix recheck \
  --parts-out "$FX/build-parts-ctl.json" \
  >"$FX/drive-ctl.json" 2>"$FX/drive-ctl.err" || true
"$PY" "$PARTS_PY" pair --drawing "$mW/xo/drawing-parts.json" \
  --build "$FX/build-parts-ctl.json" --out "$FX/pairs-ctl.json" >/dev/null 2>&1 || true

matched_in() { "$PY" -c 'import json,sys
try: print(int(json.load(open(sys.argv[1]))["matched"]))
except Exception: print(-1)' "$1"; }
walk_keys() { # <shots-dir> <prefix> — "j1 j2 j3 …", the steps it photographed
  ls "$1" 2>/dev/null | sed -n "s/^$2-walk-[0-9][0-9]*-\(.*\)\.png\$/\1/p" \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}
LOOK_KEYS="$(walk_keys "$mW/xo/shots/look-1" shot)"
LOOK_MATCHED="$(matched_in "$FX/pairs-look.json")"
CTL_MATCHED="$(matched_in "$FX/pairs-ctl.json")"
CTL_KEYS="$(walk_keys "$FX/ctl" recheck)"
WALK_BEFORE="$(cat "$mW/xo/walk.json" 2>/dev/null)"
# The recorded plan, as the first look left it. A re-check that RE-PLANS can
# produce a second, differently-shaped journey — and then the before and after
# pictures are not of the same thing.
cp "$mW/xo/journey.json" "$FX/journey-as-planned.json"

# The fixture is only a proof if the defect reproduces IN it.
check "W0. the look walked — it has a picture of each declared step" \
  "[ -n '$LOOK_KEYS' ]"
check "W0. the CONTROL — the journey-less drive takes no walk picture at all" \
  "[ -z '$CTL_KEYS' ]"
check "W0. …and pairs far fewer of the drawing's parts: that IS the defect" \
  "[ '$CTL_MATCHED' -ge 0 ] && [ '$LOOK_MATCHED' -gt '$CTL_MATCHED' ]"

# --- AND NOW THE RE-CHECK, through the verb itself ------------------------
: >"$XO_WORKER_LOG"; : >"$XO_RESPOND_CALLS"; : >"$XO_LAUNCH_LOG"
RC_HELD='{"score":"high","summary":"The fixes are on the build.","criteria":[{"id":"prd-1","text":"one list","status":"met","shot":"recheck-01","note":"there"},{"id":"prd-2","text":"the gate","status":"met","shot":"recheck-01","note":"there"}],"gaps":[],"escalations":["The month reads August 2026 on the first screen and September 2026 on the next — no criterion names it, but it is worth the captain'"'"'s eye."],"held":[{"criterion":"prd-1","held":true,"why":"it is under the list now","shots":["recheck-01"]},{"criterion":"prd-2","held":true,"why":"it refuses while blank","shots":["recheck-01"]}]}'
outW="$(XO_RC_BODY="$RC_HELD" run_recheck "$repoW" "lcars-20260920-801")" || true

RC_KEYS="$(walk_keys "$mW/xo/shots/recheck-1" recheck)"
RC_MATCHED="$(matched_in "$mW/xo/pairs.json")"

check "W1. the re-check produced walk pictures at all (it produced NONE)" \
  "[ -n '$RC_KEYS' ]"
check "W2. …for the SAME steps the look produced them for, one for one" \
  "[ '$RC_KEYS' = '$LOOK_KEYS' ]"
check "W3. the side-by-side stops calling the whole drawing unreachable" \
  "[ '$RC_MATCHED' -gt '$CTL_MATCHED' ]"
check "W4. …and lands on the look's own number, so the two are comparable" \
  "[ '$RC_MATCHED' -eq '$LOOK_MATCHED' ]"
check "W5. the re-check's walk record is its OWN, under this look's name" \
  "[ -s '$mW/xo/walk-recheck-1.json' ]"
check "W6. …and the first look's walk record is left exactly as it was" \
  "[ \"\$(cat '$mW/xo/walk.json' 2>/dev/null)\" = \"\$WALK_BEFORE\" ]"
check "W7. the journey was RE-USED from the first look, never re-planned" \
  "printf '%s' \"\$outW\" | grep -q 'the same journey'"
check "W8. …so the plan on disk is byte for byte the one the look walked" \
  "cmp -s '$mW/xo/journey.json' '$FX/journey-as-planned.json'"
check "W9. what the walk measured is added to THIS look's observations" \
  "[ -s '$mW/xo/scan.json' ] || [ -s '$mW/xo/carry.json' ]"
check "W10. the re-check still reached its verdict" "[ -s '$mW/xo/verdict-2.json' ]"

# --- THE OTHER CONTROL: a mission with NO journey on record ---------------
# A mission first looked at before any of this existed has no `journey.json`.
# It must cost the re-check nothing — it says in one plain sentence what it can
# and cannot see, and it still reaches a verdict. (It also walks the empty-array
# expansion in the drive call, which under `set -u` is its own hazard.)
repoN="$(new_repo)"
mN="$(plant_parent "$repoN" "lcars-20260920-802")"
plant_child "$repoN" "lcars-20260920-802" 1
plant_child "$repoN" "lcars-20260920-802" 2
cp "$mW/xo/criteria.json" "$mN/xo/criteria.json"
outN="$(XO_RC_BODY="$RC_HELD" run_recheck "$repoN" "lcars-20260920-802")" || true
check "W11. no journey on record costs the re-check nothing — it still scores" \
  "[ -s '$mN/xo/verdict-2.json' ]"
check "W12. …and it says plainly what it could and could not see" \
  "printf '%s' \"\$outN\" | grep -q 'no journey on record'"
check "W13. …and invents no walk record out of nothing" \
  "[ -z \"\$(ls '$mN/xo'/walk-*.json 2>/dev/null)\" ]"

unset XO_LAUNCH_URL
fi

# ===========================================================================
# E. WHAT IS HIS TO DECIDE REACHES HIM
#
# `escalations` is DATA, written by the look into verdict.json and carried by
# the scorer. Nothing below re-derives it from prose: the scorer prints it on
# the same tab-separated wire it already prints NOTE on, xo.sh journals it
# through the same `journal()` every other finding goes through, and the report
# renders it because the journal has it. One display path, not a second one.
# ===========================================================================
echo
echo "E. the escalation reaches the console and \`lcars xo report\`"

# --- E1. the scorer puts it on the wire, off the record, unchanged --------
ESC_DIR="$TMPROOT/esc"; mkdir -p "$ESC_DIR"
cat >"$ESC_DIR/criteria.json" <<'CJ'
{"criteria": [{"id": "prd-1", "text": "The board shows every open task.", "primary": true}]}
CJ
cat >"$ESC_DIR/worker.json" <<'WJ'
{"score": "high", "summary": "It does what you asked.",
 "criteria": [{"id": "prd-1", "text": "The board shows every open task.", "status": "met", "shot": "shot-01", "note": "saw it"}],
 "gaps": [],
 "escalations": ["The month reads August on one screen and September on the next — worth the captain's eye."]}
WJ
esc_out="$("$PY" "$SCORE_PY" "$ESC_DIR/worker.json" "$ESC_DIR/criteria.json" \
            "$ESC_DIR/verdict.json" 2>/dev/null)" || esc_out=""
check "E1. the scorer prints the escalation on its own line, word for word" \
  "printf '%s' \"\$esc_out\" | grep -q '^ESCALATION	The month reads August on one screen'"
# THE CONTROL: no escalation in, no line out — a display that fires on every
# verdict would put an empty heading in front of him for ever.
cat >"$ESC_DIR/quiet.json" <<'WJ'
{"score": "high", "summary": "It does what you asked.",
 "criteria": [{"id": "prd-1", "text": "The board shows every open task.", "status": "met", "shot": "shot-01", "note": "saw it"}],
 "gaps": [], "escalations": []}
WJ
quiet_out="$("$PY" "$SCORE_PY" "$ESC_DIR/quiet.json" "$ESC_DIR/criteria.json" \
              "$ESC_DIR/verdict2.json" 2>/dev/null)" || quiet_out=""
check "E1. CONTROL — a verdict with nothing to escalate prints no such line" \
  "! printf '%s' \"\$quiet_out\" | grep -q '^ESCALATION'"

# --- E2/E3. xo.sh says it on the console and writes it into the journal ---
if [ "$HAVE_CHROME" -eq 0 ]; then
  printf '  (E2–E4 ride on the re-check above — SKIPPED)\n'
else
check "E2. the re-check says it on the console, in his words" \
  "printf '%s' \"\$outW\" | grep -q 'August 2026 on the first screen'"
check "E3. …and it is in the mission's journal as its own entry" \
  "grep -q '\"action\": \"escalation\"' '$mW/number-one.jsonl'"

SEEN="$FX/xo-seen.json"
rep="$("$PY" "$REPORT_PY" "$repoW/.git/lcars/missions" "$SEEN" \
        --mission "lcars-20260920-801" --format text 2>/dev/null)" || rep=""
check "E4. \`lcars xo report\` shows it — the surface he actually reads" \
  "printf '%s' \"\$rep\" | grep -q 'worth the captain'"
check "E4. …ranked as something to read, not folded under the machinery" \
  "\"\$PY\" '$REPORT_PY' '$repoW/.git/lcars/missions' '$FX/seen2.json' \
     --mission lcars-20260920-801 --format json \
   | \"\$PY\" -c 'import json,sys
d=json.load(sys.stdin)
e=[x for x in d[\"since\"][\"entries\"] if x.get(\"action\")==\"escalation\"]
sys.exit(0 if e and all(x[\"rank\"]!=\"step\" for x in e) else 1)'"
fi

echo
printf 'lcars xo recheck: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
