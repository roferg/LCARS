#!/usr/bin/env bash
# ============================================================================
# S125 — THE HOLODECK, IN A REAL BROWSER.
#
#   bash tests/drives/browser/holodeck.sh              # the product
#   bash tests/drives/browser/holodeck.sh --calibrate  # the RED CONTROLS
#   bash tests/drives/browser/holodeck.sh --all        # both
#
# WHAT IS BEING PROVEN. The deck REPLACES the board inside the same LCARS frame
# (D1), lays out three panes — PROGRAMS · CHAT · LIVE PREVIEW (D2) — and shows
# the sidecar's REAL mockup file in a sandboxed iframe over the jailed preview
# route (D3). Every one of those claims is measured off LAID-OUT BOXES in real
# Chrome, not off markup:
#
#   • the board's columns, wrap and legend measured GONE while on the deck;
#   • three panes present, VISIBLE, in order, with real widths at ~1.15:1;
#   • the preview iframe pointing at /api/holodeck/<sid>/preview/…, with a real
#     box, `allow-scripts` present and `allow-same-origin` ABSENT;
#   • the deck's accent token resolving to a real colour;
#   • and the board BACK after the same control, now reading ▦ BOARD.
#
# WHY A BROWSER. The deck hides the board with ONE CSS class on <body>
# (`body.on-deck`) — chosen because render() rebuilds the board area on every
# SSE tick and would wipe a JS `hidden` flag. Every node harness under web/tests
# can assert that class is set and learn NOTHING about whether the board went
# away; none of them has any CSS at all. This is the half that looks.
#
# ZERO TOKENS. The program is opened in DESIGN mode, which spawns no worker
# (actions.holodeck_start opens the room; the first `say` is what opens a warm
# session), and the only claude/copilot on PATH are smoke.sh's logging shims.
# The sidecar and its mockup.html are PLANTED here, so nothing is generated.
#
# THE RED CONTROLS are the point of --calibrate: a check that cannot go red is
# decoration. EIGHT variants each patch a COPY of web/ and each MUST make the
# run fail — the deck's accent token deleted (paints nothing, keeps every box),
# the board left visible under the deck (the replacement silently not
# happening), the preview pane not laid out, `allow-same-origin` added back
# beside `allow-scripts` (the sandbox reduced to decoration), the viewport pin
# removed, the grounding posture never handing over, a cleaner eating the
# captain's own prose, and (fix round 3) RETRY TURN put back on the road to a
# ghost session. This repo's own web/ is never touched.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"
PROGRAM="Nav rail"
SLUG="nav-rail"          # actions._slug("Nav rail") — deterministic, so the
                         # room can be planted before the program is opened.

WORK="${LCARS_BROWSER_HOLODECK_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-holo.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-holo.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-holo.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
skip() {
  printf '\n\033[33m════ SKIPPED — the holodeck was NOT checked in a browser ════\033[0m\n'
  printf '  %s\n' "$1"
  printf '  This is NOT a pass. Nothing about the deck has been proven.\n\n'
  exit 77
}

command -v git >/dev/null 2>&1 || skip "git not found — the sidecar fixture needs it."

# ── the expectation the driver judges against ──────────────────────────────
cat >"$WORK/expect.json" <<EOF
{
  "program": "$PROGRAM",
  "mockText": "PROGRAMS",
  "journey": true,
  "groundedProgram": "Tile picker",
  "deadFirstTurn": true
}
EOF

# ── the SCRIPTED worker (fix round 1) ───────────────────────────────────────
# Round 0's rig drove the BLANK-DECK path against a planted mockup and never
# spawned anything, so it passed green while the DEFAULT, RECOMMENDED path —
# "this project's look" — could not write a file at all: `sess.mode` never left
# "grounding", so every later turn kept read-only tools and the captain's own
# project as its cwd, and the engine answered "I can't write files, save this
# yourself" under a cheerful `status: "ok"`.
#
# So the rig now drives that journey for real, against a stub that BRANCHES ON
# THE POSTURE IT IS GIVEN rather than on a turn counter:
#   • a turn whose --disallowedTools contains Write is a GROUNDING pass — it
#     prints a basis and writes nothing (it could not anyway);
#   • anything else is a DESIGN turn — it writes mockup.html into its cwd.
# That is the whole defect, expressed as a fixture: if the posture never
# switches, the stub takes the grounding branch forever, no mockup is ever
# written, and the preview stays empty. Zero tokens — it is a python script.
write_worker() {   # $1 = dir
  mkdir -p "$1"
  cat >"$1/claude" <<'STUB'
#!/usr/bin/env python3
import os, sys
argv = sys.argv[1:]
deny = ""
for i, a in enumerate(argv):
    if a == "--disallowedTools" and i + 1 < len(argv):
        deny = argv[i + 1]
grounding = "Write" in deny

# ── N4 (fix round 3): A REAL CLI'S SESSION SEMANTICS ────────────────────────
# The stub OPENS a conversation on `--session-id <uuid>` and REFUSES to
# `--resume` one it never opened — which is exactly what both real CLIs do, and
# the only reason a kept-but-never-created session id is a permanent dead end
# rather than a harmless flag. A stub that ignores the flags cannot see N4 at
# all: it happily answers a resume of a ghost, and the defect reads as green.
sid, opening = None, None
for i, a in enumerate(argv):
    for flag, op in (("--session-id", True), ("--resume", False)):
        if a == flag and i + 1 < len(argv):
            sid, opening = argv[i + 1], op
        elif a.startswith(flag + "="):
            sid, opening = a.split("=", 1)[1], op
state = os.environ.get("LCARS_RIG_STATE", "")
if state:
    os.makedirs(state, exist_ok=True)
opened_path = os.path.join(state, "opened.txt") if state else ""


def _opened():
    if not opened_path or not os.path.exists(opened_path):
        return set()
    with open(opened_path) as fh:
        return set(x.strip() for x in fh if x.strip())


def _remember(s):
    if opened_path and s:
        with open(opened_path, "a") as fh:
            fh.write(s + "\n")


def _bump(name):
    """A counter that survives across spawns — the stub's only memory."""
    if not state:
        return 0
    p = os.path.join(state, name)
    n = 0
    if os.path.exists(p):
        try:
            n = int(open(p).read().strip() or "0")
        except ValueError:
            n = 0
    with open(p, "w") as fh:
        fh.write(str(n + 1))
    return n


log = os.environ.get("LCARS_RIG_WORKER_LOG", "")
if log:
    with open(log, "a") as fh:
        fh.write(("grounding" if grounding else "design") + "\t"
                 + ("open" if opening else "resume") + "\t" + str(sid) + "\t"
                 + os.getcwd() + "\n")

if opening is False and sid not in _opened():
    # THE DEAD END, spoken as the CLIs speak it.
    sys.stdout.write("Error: no conversation found with session id %s\n" % sid)
    sys.exit(1)

if not grounding and _bump("design-turns") == 0:
    # THE FIRST DESIGN TURN DIES — noisily, at startup, before the CLI has
    # opened anything. `sid` is deliberately NOT remembered: nothing exists to
    # resume. This is a bad token / expired auth / rate limit, the three most
    # ordinary engine failures there are, and the daemon merges stderr into
    # stdout so it arrives with a perfectly non-empty reply.
    sys.stdout.write("Error: authentication failed\n")
    sys.exit(1)
_remember(sid)

if grounding:
    sys.stdout.write(
        "# Design basis\n\n"
        "## Colour\n\n"
        "- `--ink` **#101318** (tokens.css)\n"
        "- `--accent` **#2de3c7** (tokens.css)\n\n"
        "| token | value |\n| --- | --- |\n| radius | 6px |\n\n"
        "No light theme — the project is dark-only today.\n")
    sys.exit(0)
# A DESIGN turn. It writes into its cwd — which is the program's room, and
# nowhere else, or the daemon's own audit would call it a stray write.
with open(os.path.join(os.getcwd(), "mockup.html"), "w") as fh:
    fh.write("<!doctype html><html><head><meta charset='utf-8'>"
             "<title>Nav rail</title></head><body "
             "style='margin:0;background:#0a0a0f;color:#e8ecf5;"
             "font:14px system-ui'><h1 style='padding:14px'>Tile picker"
             "</h1></body></html>\n")
# A LONG reply, in the engine's own idiom: markdown source AND a tool trace.
# Long because the deck's scroll defect is only visible under a long transcript
# (measured: innerHeight 913 vs .deckview 1897 after ONE long turn), and in the
# engine's idiom because the chat used to print both verbatim.
#
# It ALSO carries the two things round 1's cleaner silently DESTROYED — an
# ASCII diagram and a `●`-prefixed design note — because those are among the
# most likely things to be said in a design conversation, and the rig could not
# see the class at all. They must come back out on the screen.
out = ["● List directory .", "└ 3 files found", "● Create mockup.html +68", "",
       "# Tile picker", "", "Built it with **two** states and a `rail` class.",
       "",
       "Here is the shape I have in mind:", "",
       "┌────────────┐", "│  SWATCHES  │", "├────────────┤",
       "│  PREVIEW   │", "└────────────┘", "",
       "● Read the swatch labels before you decide the accent.", ""]
for n in range(1, 26):
    out.append("Revision note %d — the swatch grid keeps a 6px radius and the "
               "accent stays #2de3c7 so the picker reads as part of the same "
               "product rather than a stranger's panel." % n)
    out.append("")
out += ["- collapsed, 56px", "- expanded, 216px", "",
        "| token | value |", "| --- | --- |", "| accent | #2de3c7 |", ""]
sys.stdout.write("\n".join(out) + "\n")
STUB
  chmod +x "$1/claude"
  cp "$1/claude" "$1/copilot"
  echo "$1/claude"
}

# ── the planted sidecar: a real local git repo with one program room ────────
# The daemon ADOPTS this (actions._ensure_sidecar is idempotent — an existing
# sidecar with a .git is returned untouched) and actions._slug maps the program
# name to the room, so the mockup is already on disk when the program opens and
# no worker is ever spawned.
plant_sidecar() {   # $1 = the run's artifact dir (smoke.sh's OUT)
  local root="$1/holo-root"
  local side="$root/fixture-holodeck"
  rm -rf "$root"
  mkdir -p "$side/$SLUG"
  cat >"$side/README.md" <<'MD'
# fixture-holodeck — planted by tests/drives/browser/holodeck.sh
Not a captain's archive. A fixture.
MD
  cat >"$side/$SLUG/mockup.html" <<'MOCK'
<!DOCTYPE html>
<!-- VISUAL REFERENCE ONLY — a rig fixture standing in for a model-written
     mockup. NOT shipping code, no daemon behind it, internals deliberately
     fake. It exists so the preview pane has something REAL on disk to render
     from the sidecar, over the jailed route, in a sandboxed frame. -->
<html><head><meta charset="utf-8"><title>Nav rail — mockup</title>
<style>
  body{margin:0;background:#0a0a0f;color:#e8ecf5;
       font:14px/1.5 -apple-system,'Segoe UI',system-ui,sans-serif}
  .hd{display:flex;align-items:center;gap:8px;padding:10px 12px;background:#12121c;
      border-bottom:1px solid #23233a;font-weight:600}
  .db{padding:12px}
  .row{display:flex;gap:8px;align-items:center;padding:9px 10px;border-radius:6px;
       background:#12121c;margin-bottom:7px;font-size:12px}
  .sw{width:22px;height:22px;border-radius:5px;background:#4a7dff}
  .grow{flex:1 1 auto}
</style></head>
<body>
  <div class="hd"><span>Nav rail</span><span class="grow"></span><span>MOCKUP</span></div>
  <div class="db">
    <div class="row"><span class="sw"></span><span class="grow">Kitchen splashback</span><span>2d</span></div>
    <div class="row"><span class="sw" style="background:#f0a028"></span><span class="grow">Ensuite floor</span><span>5d</span></div>
    <div class="row"><span class="sw" style="background:#59c07a"></span><span class="grow">Hallway border</span><span>1w</span></div>
  </div>
  <script>document.title = "Nav rail — mockup (scripts ran)";</script>
</body></html>
MOCK
  ( cd "$side" && git init -q . &&
    git -c user.email=h@l -c user.name=holo add -A &&
    git -c user.email=h@l -c user.name=holo commit -q --no-gpg-sign \
        -m "holodeck: sidecar created" ) >/dev/null 2>&1 ||
    skip "could not git init the planted sidecar at $side"
  echo "$root"
}

# ── one run of smoke.sh with the holodeck act turned on ─────────────────────
run_once() {   # $1 = label, $2 = web dir, $3 = artifact dir
  local label="$1" web="$2" out="$3"
  mkdir -p "$out"
  local root; root="$(plant_sidecar "$out")"
  local worker; worker="$(write_worker "$out/holo-bin")"
  say "── $label"
  note "web:       $web"
  note "sidecar:   $root/fixture-holodeck/$SLUG/mockup.html"
  note "worker:    $worker (scripted, zero tokens)"
  LCARS_BROWSER_OUT="$out" \
  LCARS_BROWSER_WEB_DIR="$web" \
  LCARS_BROWSER_HOLODECK_CHECK="$WORK/expect.json" \
  LCARS_BROWSER_WORKER_BIN="$worker" \
  LCARS_RIG_WORKER_LOG="$out/holo-worker.log" \
  LCARS_RIG_STATE="$out/holo-rig-state" \
  LCARS_HOLODECK_ROOT="$root" \
    bash "$HERE/smoke.sh"
  return $?
}

# ── the red controls: a COPY of web/, each broken one way ───────────────────
# Every variant must FAIL. A green control means the check cannot see the thing
# it claims to see, and the whole rig is decoration.
make_variant() {   # $1 = name, $2 = dest
  local name="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  cp -R "$REPO/web/." "$dest/" 2>/dev/null
  local css="$dest/static/board.css" js="$dest/static/board.js"
  case "$name" in
    no-accent)
      # the deck's accent token deleted. Every box stays perfect and the deck
      # paints in transparent — the S168 defect class, applied to the holodeck.
      "${LCARS_PYTHON_BIN:-python3}" - "$css" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("body.lcars-serve{--holo-grid:#2de3c7;--holo-line:rgba(45,227,199,.30)}", "")
open(p, "w").write(s)
PY
      ;;
    board-stays)
      # the replacement silently not happening: the deck opens ON TOP of a board
      # that is still laid out underneath it.
      "${LCARS_PYTHON_BIN:-python3}" - "$css" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("body.on-deck .board-wrap,\nbody.on-deck .legend,",
              "body.on-deck .nothing-at-all,\nbody.on-deck .also-nothing,")
open(p, "w").write(s)
PY
      ;;
    flat-preview)
      # the preview pane present in the DOM but not laid out — the exact shape a
      # markup assertion cannot tell from a working one.
      printf '\n.deckview .preview{display:none}\n' >>"$css"
      ;;
    sandbox-decoration)
      # allow-same-origin added back beside allow-scripts. The attribute is
      # still there, still says "sandbox", and grants everything back.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('f.setAttribute("sandbox", "allow-scripts");',
              'f.setAttribute("sandbox", "allow-scripts allow-same-origin");')
open(p, "w").write(s)
PY
      ;;
    deck-grows)
      # THE FIX ROUND'S OWN RED CONTROL. The viewport pin removed: the deck
      # grows past the viewport again, the page scrolls, and the composer and
      # the LIVE PREVIEW ride off the bottom. Round 0's rig reported GREEN
      # through exactly this, because it measured pane widths on a one-turn
      # transcript. If this control passes, the new geometry checks are
      # decoration.
      "${LCARS_PYTHON_BIN:-python3}" - "$css" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("body.on-deck{overflow:hidden}\n"
              "body.on-deck .lcars-frame{height:100vh;min-height:100vh;overflow:hidden}", "")
s = s.replace("grid-template-rows:minmax(0,1fr);flex:1 1 auto;",
              "flex:1 1 auto;")
open(p, "w").write(s)
PY
      ;;
    trace-eats-prose)
      # FIX ROUND 2'S RED CONTROL. Round 1's cleaner, restored: a FILTER that
      # deletes any line opening with a box-drawing glyph or a bullet-plus-verb.
      # The captain's ASCII diagram comes back as its top edge alone and his
      # `● Read the swatch labels…` note is gone, with nothing on screen saying
      # so. If this control passes, the reply check cannot see the class that
      # cost this round a defect — and the shipping cleaner could go back to
      # deleting text tomorrow.
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): round 1's DELETING cleaner. */
holoSegments = function (text) {
  return [{ trace: false, lines: String(text == null ? "" : text)
    .replace(/\r\n/g, "\n").split("\n").filter(function (ln) {
      return !/^\s*[●⏺◆]\s*(list directory|read|create|update|edit|write|search|grep|glob|view|bash|fetch|task|delete|move|copy|thinking)\b/i.test(ln)
        && !/^\s*[└⎿├│]/.test(ln);
    }) }];
};
JS
      ;;
    retry-is-a-dead-end)
      # FIX ROUND 3'S RED CONTROL — N4, restored. `reply or` put back on the
      # "this session exists" test: a first turn that dies at startup prints to
      # stderr, the daemon merges that into stdout, so the id of a session the
      # CLI never opened is KEPT — and the deck's own RETRY TURN then `--resume`s
      # a ghost forever. Every failure-path cure in this round was unit-test
      # only, and it was N4's unit test (a SILENT death) that hid this for a
      # whole round. If this control passes, the rig still cannot see the class.
      "${LCARS_PYTHON_BIN:-python3}" - "$dest/lcars_serve/actions.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "            if changed or (proc.returncode == 0 and not timed_out):"
new = "            if reply or changed or (proc.returncode == 0 and not timed_out):"
assert old in s, "the N4 control could not find the line it breaks"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    grounding-sticks)
      # THE CRITICAL DEFECT, restored: the posture never leaves "grounding", so
      # every turn after the opening pass keeps read-only tools and the
      # captain's own PROJECT as its cwd. The scripted worker then takes its
      # grounding branch forever, no mockup is ever written, and the preview
      # stays on NOTHING ON THE HOLODECK YET — under `status: "ok"`.
      "${LCARS_PYTHON_BIN:-python3}" - "$dest/lcars_serve/actions.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("        if sess.mode != \"grounding\":\n            return\n"
              "        sess.mode = \"design\"",
              "        if sess.mode != \"grounding\":\n            return\n"
              "        sess.mode = \"grounding\"")
open(p, "w").write(s)
PY
      ;;
  esac
}

VARIANTS="no-accent board-stays flat-preview sandbox-decoration deck-grows grounding-sticks trace-eats-prose retry-is-a-dead-end"

product_run() {
  run_once "PRODUCT — this repo's web/" "$REPO/web" "$WORK/product"
  local rc=$?
  printf '\n'
  if [ "$rc" -eq 0 ]; then
    printf '\033[32mHOLODECK MEASURED\033[0m — the deck replaced the board, three panes laid\n'
    printf '        out, the preview iframe is jailed AND sandboxed, and the board came\n'
    printf '        back. NOW OPEN %s/holodeck.png AND LOOK AT IT.\n' "$WORK/product"
  elif [ "$rc" -eq 77 ]; then
    printf '\033[33mSKIPPED\033[0m — infrastructure, not the deck. Nothing was proven.\n'
  else
    printf '\033[31mFAILED\033[0m — see %s/holodeck-check.json for the measured values\n' "$WORK/product"
    printf '        and %s/holodeck.png for the picture.\n' "$WORK/product"
  fi
  return $rc
}

calibrate_run() {
  local n=0 v0
  for v0 in $VARIANTS; do n=$((n + 1)); done
  say "── CALIBRATION: $n deliberately broken copies. Each MUST fail."
  local bad=0 v
  for v in $VARIANTS; do
    make_variant "$v" "$WORK/variant-$v/web"
    run_once "CONTROL: $v (must FAIL)" "$WORK/variant-$v/web" "$WORK/variant-$v/out"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '\033[31m  ✗ %s PASSED — the check is BLIND to it.\033[0m\n' "$v"
      bad=$((bad + 1))
    elif [ "$rc" -eq 77 ]; then
      printf '\033[33m  ? %s skipped — infrastructure; the control proved nothing.\033[0m\n' "$v"
      bad=$((bad + 1))
    else
      printf '\033[32m  ✓ %s failed, as it must.\033[0m\n' "$v"
    fi
  done
  printf '\n'
  if [ "$bad" -eq 0 ]; then
    printf '\033[32mCALIBRATED\033[0m — every control went red. The check can see.\n'
    return 0
  fi
  printf '\033[31m%d CONTROL(S) DID NOT GO RED\033[0m — the check is decoration until they do.\n' "$bad"
  return 1
}

case "$MODE" in
  --calibrate) calibrate_run; exit $? ;;
  --all)
    product_run; P=$?
    calibrate_run; C=$?
    [ "$P" -eq 0 ] && [ "$C" -eq 0 ] && exit 0
    [ "$P" -eq 77 ] && exit 77
    exit 1 ;;
  *) product_run; exit $? ;;
esac
