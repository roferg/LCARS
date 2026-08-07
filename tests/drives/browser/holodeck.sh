#!/usr/bin/env bash
# ============================================================================
# S125/S126 — THE HOLODECK, IN A REAL BROWSER.
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
#   • three CONTENT panes present, VISIBLE, in order, with real widths at
#     ~1.15:1 — and, since S128, the deck's FURNITURE judged separately as
#     itself: the chat/preview drag handle measured as a laid-out 3–24px gutter
#     that runs the height of the split and sits BETWEEN those two panes, and
#     the program-drawer's click-away scrim measured GONE and click-through
#     while the drawer is shut;
#   • EVERY child of the deck recognised — an unrecognised node fails the run by
#     name rather than disappearing out of a filtered list;
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
# ZERO TOKENS — BUT NOT NO WORKER (corrected S126; this header was stale from
# the moment the rig grew a journey). The rig DOES drive real turns: a GROUNDING
# pass and three DESIGN turns, each a genuine POST that spawns a worker. That
# worker is a SCRIPTED PYTHON STUB written by this file — it branches on the
# tool posture it is handed, kills its first design turn the way a real engine
# dies at startup, and writes mockup.html into its cwd. No engine is ever
# contacted and no token is ever spent; the only claude/copilot on PATH are
# smoke.sh's logging shims and the run reports 0 invocations of them.
# (The planted sidecar's one room is a fixture: a mockup.html AND a
# transcript.md — the record that makes a directory in the sidecar a PROGRAM at
# all. It stands in for yesterday's work, which is what the morning-state and
# warm-restart checks are about.)
#
# S169 — THREE NEW LEGS, AND THE FIRST PIXEL MEASUREMENT IN THIS RIG. All three
# came off the captain driving the real product on 2026-08-06:
#
#   • THE UNSENT TURN (FL-013). He typed a paragraph, went to the board to
#     deploy main, came back and it was gone. The rig types, then sits still
#     past two whole 4s safety-poll intervals with `renderDeck`/`render`
#     instrumented — which ANSWERS, rather than assumes, whether the poll
#     rebuilds the chat pane (measured on the shipping product: 3 board
#     re-renders, 0 deck re-renders, same composer node) — and then drives his
#     exact ⬡ HOLODECK → ▦ BOARD → ⬡ HOLODECK journey. The composer's node
#     IDENTITY is asserted with the value: a draft that survives a round trip
#     which never rebuilt the pane proves nothing.
#   • A REAL PASTE (FL-014). A genuine ClipboardEvent carrying a real File is
#     dispatched at the composer; an [Image #N] chip with a painted box must
#     appear and the deck must be holding the image. Only a browser can say
#     whether a real clipboard event reaches the handler on that textarea.
#   • THE INTENT SCRIM, IN PIXELS (FL-016). `.pv-intent` was both the scroll
#     container and its scrim's containing block, so the scrim was one
#     viewport-height rectangle that scrolled away and left the captain's own
#     requirements bare on the grid. NO EXISTING CHECK COULD SEE THIS — the rule
#     resolves to a perfect colour either way, it is simply somewhere else. The
#     driver photographs a clip of the screen behind a real line of text at the
#     top of concept.md and again after really scrolling to the bottom, plus the
#     bare grid beside the panel as calibration, and decodes the PNGs. The
#     planted room's concept.md is LONG on purpose: without a document that
#     overflows the pane the defect cannot appear, and that precondition is
#     measured, not assumed.
#
# THE RED CONTROLS are the point of --calibrate: a check that cannot go red is
# decoration. TWENTY-ONE variants each patch a COPY of web/ and each MUST make
# the run fail — the deck's accent token deleted (paints nothing, keeps every box),
# the board left visible under the deck (the replacement silently not
# happening), the preview pane not laid out, `allow-same-origin` added back
# beside `allow-scripts` (the sandbox reduced to decoration), the viewport pin
# removed, the grounding posture never handing over, a cleaner eating the
# captain's own prose, (fix round 3) RETRY TURN put back on the road to a ghost
# session, and — S126 — the banner printing a raw exit code (N5), the retry
# writing the captain's line twice (N6), and a second client-authored voice in
# the banner re-asserting an authorship claim, plus a fenced block's declared
# filename dropped from the render, and — fix round 2 — the morning state
# pointing at nothing while a program waits in the list, and the chat header's
# pill claiming WARM under the banner saying the conversation is over, and —
# S169 — the intent scrim back on the scrolling box, the composer's draft back
# in the DOM node and nowhere else, the safety poll rebuilding the deck, and the
# composer with no paste handler on it, and — S169's FL-015 trio — the composer
# with no ask/build control, the captain's declaration dropped on its way to the
# worker (the switch lights up and the prompt is unchanged), and the working
# strip asserting a RENDER again. This repo's own web/ is never touched.
# `$LCARS_HOLODECK_VARIANTS` runs a SUBSET.
#
# AND A NON-ZERO EXIT IS NOT A CONTROL GOING RED (fix round 1b). Each variant is
# judged off its own holodeck-check.json: its PRECONDITION must have fired (the
# scripted worker's first design turn actually died and the HOLODECK OFFLINE
# banner actually appeared — the half of the journey N4/N5/N6/one-voice all hang
# off) and the run must have failed ON THE SENTENCE THAT NAMES WHAT IT BREAKS.
# Anything else is loud and non-zero. Without that, a stale rig-state counter
# made the dead turn stop happening and eleven of twelve controls "went red" on
# the harness's own "THE N4 CHECK PROVED NOTHING" line while the summary printed
# "every control went red".
#
# S128 — THE RIG WENT STALE AND NOBODY NOTICED, FOR A WHOLE SESSION. S127 added
# two nodes to the deckview (`.deck-split`, the chat/preview drag handle, and
# `.holo-scrim`, the program drawer's click-away). The pane check read the
# deckview's CHILDREN, so it read those two as panes, and every run since has
# failed with "pane deck-split is 7px wide — it did not lay out" against a deck
# that was laying out perfectly. A rig this expensive that is red for a reason
# nobody acts on provides exactly as much signal as no rig.
#
# The cure was NOT to widen the expected pane list — that is the "check that
# cannot go red" this whole file is built against. The furniture is now split
# out of the pane list and asserted AS ITSELF, to a shape that is stricter than
# a size exemption; the pane claim is unchanged and still fails on a pane that
# does not lay out (`flat-preview` is that control); and the rig now names any
# child of the deck it has never measured, so the NEXT node to arrive fails the
# run by name instead of silently falling out of a filtered list.
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

# ── S169 (FL-015): AN ASK TURN IS NOT A BUILD TURN ─────────────────────────
# The stub reads its own PROMPT and, when it carries the captain's explicit
# declaration, answers WITHOUT writing. It is standing in for a model that obeys
# the instruction — nothing here proves a real model would, and it is not meant
# to: the LIVE leg does that. What this branch makes measurable end to end is
# the PLUMBING — the composer's control → the POST's `intent` → the daemon's
# declaration in the prompt → an unchanged room → the daemon's outcome note on
# the screen. Break any link and the note on screen flips to the drift reading.
prompt = ""
for i, a in enumerate(argv):
    if a == "-p" and i + 1 < len(argv):
        prompt = argv[i + 1]
        break
if not grounding and "THE CAPTAIN DECLARED THIS TURN A QUESTION" in prompt:
    sys.stdout.write(
        "The events tab groups everything the run emitted, in order. It is a "
        "READ surface — nothing on it is editable — which is why it has no "
        "toolbar. I have changed nothing.\n")
    sys.exit(0)

if not grounding and _bump("design-turns") == 0:
    # THE FIRST DESIGN TURN DIES — NOISILY, at startup, before the CLI has
    # opened anything. `sid` is deliberately NOT remembered: nothing exists to
    # resume. This is a bad token / expired auth / rate limit, the three most
    # ordinary engine failures there are.
    #
    # IT WRITES TO **stderr** AND EXITS NON-ZERO, which is what a real CLI does
    # and what S125's finding #2 was about: the daemon merges stderr into
    # stdout, so a dead engine arrives with a perfectly non-empty reply. A stub
    # that dies SILENTLY produces a shape the real world never emits and hides
    # this entire class — it hid N4 for a whole round, and N5/N6/one-voice all
    # hang off this same banner.
    sys.stderr.write("Error: authentication failed\n")
    sys.stderr.flush()
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
        "| token | value |", "| --- | --- |", "| accent | #2de3c7 |", "",
        # S126 (#8) — A FENCE THAT DECLARES ITS FILE. The turn prompt asks for
        # exactly this shape when a write tool fails the engine, and the DAEMON
        # writes the block; the info string is the only thing on screen saying
        # WHICH FILE the slab below became, and the render dropped it.
        # `notes.md` rather than `mockup.html` on purpose — this must not fight
        # the native write the stub already did, or the preview pane is proving
        # something else. LAST, so it lands in the transcript's scrolled-to
        # position and is in the screenshot a human opens.
        "```file:notes.md", "Swatch labels live in tokens.css.", "```", ""]
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
  # THE PROGRAM'S OWN RECORD (fix round 2). A room is a PROGRAM because it
  # carries `transcript.md` — that is where the name the captain typed lives,
  # and it is what keeps the deck from listing every folder in the captain's
  # archive as a program. A planted room without one is a planted folder.
  cat >"$side/$SLUG/transcript.md" <<'TR'
# Nav rail

The holodeck's record of this program.

## Turn 1 · 2026-08-05T09:00:00Z

**Captain:** Draft a nav rail.

**Holodeck:** Planted by the rig — first pass is up.
TR
  # THE CONCEPT DOC, AND IT IS DELIBERATELY LONG (S169, FL-016). The INTENT
  # panel's readability scrim was on the same element as `overflow:auto`, so it
  # was one viewport-height rectangle that scrolled away with the content and
  # left everything past the first screen bare on the deck's grid. That defect
  # CANNOT APPEAR on a document that fits the pane, so the fixture has to
  # overflow it — this is the precondition of the pixel check in cdp.js, and it
  # is asserted there rather than assumed here.
  #
  # It is planted (rather than written by the scripted worker) so the check's
  # precondition holds under EVERY red control, including the ones that stop a
  # design turn ever landing. The rig's own warm-restart leg opens this room.
  {
    cat <<'CONCEPT'
# Nav rail — what it must do

## WHAT IT MUST DO

**Turn 1:** "give the tile editor a more modern UI look" — T1

**Turn 2:** "the rail has to collapse, and it has to remember" — T2

**Turn 3:** "I want to see the swatch labels without hovering" — T3

## Decisions

- The rail is 56px collapsed and 216px expanded.
- The accent stays `#2de3c7` so this reads as part of the same product.
- Radius is 6px everywhere, matching the grounding pass.
CONCEPT
    n=1
    while [ "$n" -le 34 ]; do
      printf '\n### Note %d\n\nThe swatch grid keeps a 6px radius and the accent stays #2de3c7, so the picker reads as part of the same product rather than a stranger'"'"'s panel. This paragraph exists to make the document longer than the pane it is read in.\n' "$n"
      n=$((n + 1))
    done
  } >"$side/$SLUG/concept.md"
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
  # ── THE STUB'S MEMORY IS PER-RUN, AND MUST BE WIPED BEFORE EVERY RUN ───────
  # (fix round 1b — the finding that made this session's own evidence false.)
  # The scripted worker's only memory is `$out/holo-rig-state`: a `design-turns`
  # counter that decides WHICH design turn dies, and the list of session ids it
  # has opened. `$out` is routinely REUSED — LCARS_BROWSER_HOLODECK_OUT pointed
  # at a fixed dir is how anyone re-runs a calibration and keeps the artifacts —
  # and nothing here ever cleared that state. So the SECOND run into a given dir
  # started with the counter already past zero, THE FIRST DESIGN TURN NO LONGER
  # DIED, and the entire N4/N5/N6/one-voice half of the check measured a journey
  # with no death: every one of those controls then "went red" on the harness's
  # own "THE N4 CHECK PROVED NOTHING" line rather than on the defect it injects,
  # and --calibrate printed "every control went red" over four worthless proofs.
  # A stale counter is not a fixture; it is a memory of a different run.
  rm -rf "$out/holo-rig-state"
  rm -f  "$out/holo-worker.log"
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
    n5-exit-code-in-banner)
      # S126's RED CONTROL FOR N5 — round 1's banner, restored. It printed
      # "(claude exited -9)": a number that answers neither of the two questions
      # a captain actually has (what it stopped, and how to try again) and that
      # he cannot act on. The cure was unit-test-only until now, and a unit test
      # cannot see whether the number reaches the screen.
      "${LCARS_PYTHON_BIN:-python3}" - "$dest/lcars_serve/actions.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = ('                     "running; say it again to retry.%s"\n'
       '                     % (os.path.basename(bin_),')
new = ('                     "running; say it again to retry. (%s exited %d)%s"\n'
       '                     % (os.path.basename(bin_), os.path.basename(bin_),\n'
       '                        proc.returncode,')
assert old in s, "the N5 control could not find the banner it breaks"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    retry-doubles-the-line)
      # S126's RED CONTROL FOR N6 — the daemon's dedupe, removed. A retry is the
      # SAME line: the captain typed it once, the turn died, he pressed RETRY.
      # Round 1 appended a second turn on both sides and he read himself saying
      # it twice. Broken in the DAEMON on purpose: its turn list is what the
      # deck re-reads after every settled turn, so a client-only break would
      # heal itself on the next refresh and the control would flicker green.
      #
      # The worker that raises this path dies NOISILY (stderr + non-zero) — a
      # SILENT stub is the shape that hid this whole class for a round.
      "${LCARS_PYTHON_BIN:-python3}" - "$dest/lcars_serve/actions.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        if last and last.get("text") == text and last.get("failed"):'
new = '        if False and last and last.get("text") == text and last.get("failed"):'
assert old in s, "the N6 control could not find the dedupe it breaks"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    two-voices-in-the-banner)
      # S126's RED CONTROL FOR THE ONE-VOICE RULE — round 1's client-authored
      # banner copy, restored verbatim in spirit: it repeats the daemon's own
      # sentences AND re-asserts the authorship claim the daemon had just been
      # cured of ("nothing out there has been changed") — a claim the audit
      # cannot make, because it watches files, not who touched them.
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): round 1's SECOND VOICE. */
holoBannerNode = (function (orig) {
  return function () {
    var n = orig.apply(this, arguments);
    if (n) {
      n.appendChild(el("span", "bt",
        "Your program is safe and the chat is still running. The holodeck "
        + "never touches your project, and nothing out there has been changed "
        + "or removed by LCARS."));
    }
    return n;
  };
})(holoBannerNode);
JS
      ;;
    fence-loses-its-filename)
      # S126's RED CONTROL FOR #8 — the info string dropped again. The block
      # still renders perfectly; nothing on the screen says which file it is.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '      if (info) body.appendChild(el("div", "fence-info", info));\n'
assert old in s, "the fence-info control could not find the line it breaks"
open(p, "w").write(s.replace(old, ""))
PY
      ;;
    morning-points-nowhere)
      # FIX ROUND 2'S RED CONTROL FOR DEFECT 6 — the opening pane's copy, as it
      # was. Every box stays exactly where it is and the deck paints perfectly;
      # the captain is simply told to describe a screen, over one prominent
      # ＋ NEW PROGRAM, while yesterday's program sits in the list beside it
      # unmentioned. If this control passes, the morning-state check is reading
      # a pane it cannot actually judge.
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): the pre-fix opening pane. */
holoEmptyDeck = function () {
  var e = el("div", "holo-empty");
  e.appendChild(el("div", "arch", "Holodeck"));
  e.appendChild(el("div", "sub", "Program standing by"));
  e.appendChild(el("p", null,
    "Describe a screen, a component, or a whole flow and I will build it as a "
    + "live mockup you can look at. We iterate here — cheaply, no missions, no "
    + "branches — until it looks right."));
  e.appendChild(applyWriteState(holoBtn("＋ New Program", "go big",
                                        openNewProgram)));
  var where = el("div", "where");
  where.appendChild(document.createTextNode("Files land in "));
  where.appendChild(el("b", null, HOLO.sidecarDisplay || HOLO.sidecarName
    || (holoRepoName() + "-holodeck")));
  where.appendChild(document.createTextNode(
    " — a separate repo beside this one, never inside your project. "
    + "It is local git, pushed only if you ask."));
  e.appendChild(where);
  return e;
};
JS
      ;;
    warm-pill-lies)
      # FIX ROUND 2'S RED CONTROL FOR DEFECT 5 — the pill asserting WARM again.
      # Nothing else moves: the banner under it still says the conversation is
      # over and the next worker is fresh, which is the whole point — the defect
      # is a CONTRADICTION on one screen, and only a rig that reads both strings
      # off the same painted deck can see it.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  var warm = !!p.warm;"
assert old in s, "the warm-pill control could not find the line it breaks"
open(p, "w").write(s.replace(old, "  var warm = true;"))
PY
      ;;
    intent-scrim-scrolls-away)
      # S169'S RED CONTROL FOR FL-016 — the scrim put back on the SCROLLING
      # box, exactly as the captain met it. `.pv-intent` becomes both the
      # scroll container and the scrim's containing block again, so the
      # absolutely-positioned ::before is sized to the padding box and rides up
      # with the content; and the inner scroller is collapsed away so the
      # geometry is byte-for-byte the pre-fix one rather than an approximation
      # of it. Every rule still resolves to a perfect colour — that is the
      # whole point, and why no node harness under web/tests/ can see this.
      "${LCARS_PYTHON_BIN:-python3}" - "$css" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
new = """.pv-intent{flex:1 1 auto;min-height:0;min-width:0;display:flex;
  position:relative;color:var(--lcars-text);font-size:13.5px;line-height:1.6}"""
old = """.pv-intent{flex:1 1 auto;min-height:0;overflow:auto;padding:18px 20px;
  position:relative;color:var(--lcars-text);font-size:13.5px;line-height:1.6}"""
assert new in s, "the FL-016 control could not find the .pv-intent rule"
s = s.replace(new, old)
s = s.replace(""".pv-intent .pv-intent-scroll{flex:1 1 auto;min-height:0;min-width:0;
  overflow:auto;padding:18px 20px}
""", "")
open(p, "w").write(s)
PY
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): FL-016's panel, restored. The
   document goes straight back into the box that carries the scrim, so that one
   element is the scroll container AND the containing block again. */
holoIntentScroller = function (host) { return host; };
JS
      ;;
    draft-dies-on-repaint)
      # S169'S RED CONTROL FOR FL-013 — the composer's value put back in the
      # DOM node and nowhere else, which is precisely what it was when he lost
      # a paragraph going to the board and back. Nothing else moves: the deck
      # paints perfectly, the textarea is right there, and it is empty.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = ('  var draft = holoDraftFor(p.sessionId);\n'
       '  ta.value = draft.text || "";\n')
assert old in s, "the FL-013 control could not find the draft restore"
open(p, "w").write(s.replace(old, ""))
PY
      ;;
    poll-rebuilds-the-deck)
      # THE CONTROL FOR THE MEASUREMENT ITSELF (S169). On a healthy product the
      # "does the 4s safety poll rebuild the chat pane?" check is SILENT, and a
      # check that is only ever silent is indistinguishable from one that
      # cannot fire. This makes every board poll rebuild the deck — the world in
      # which an unsent turn dies four seconds after it is typed, whatever else
      # is done about it — and the check has to say so.
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): the safety poll rebuilding the deck. */
render = (function (orig) {
  return function (board) {
    var r = orig.apply(this, arguments);
    if (HOLO.on) renderDeck();
    return r;
  };
})(render);
JS
      ;;
    no-paste-on-the-composer)
      # S169'S RED CONTROL FOR FL-014 — the composer with no paste handler,
      # which is the state the captain met: a real clipboard event carrying a
      # PNG arrives, nothing harvests it, nothing is sent, and the daemon's own
      # honest refusal can never fire. Silence was the defect.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = ('  var compImgs = attachImagePaster(ta, function (msg) { showErr(cerr, msg); }, {\n'
       '    get: function () { return holoDraftFor(p.sessionId).images; },\n'
       '    set: function (list) { holoDraftPut(p.sessionId).images = list; },\n'
       '  });\n')
assert old in s, "the FL-014 control could not find the composer's paster"
new = ('  var compImgs = { payload: function () { return undefined; },\n'
       '                   clear: function () {} };\n')
open(p, "w").write(s.replace(old, new))
PY
      ;;
    no-ask-on-the-composer)
      # S169'S RED CONTROL FOR FL-015, CLIENT HALF — the composer with no
      # ask/build control at all, which is what the captain had: every turn was
      # a build turn and there was no way to say otherwise. The deck paints
      # perfectly and the textarea is right there; the only thing missing is the
      # one mechanism a rewording cannot defeat.
      cat >>"$js" <<'JS'

/* RED CONTROL (holodeck.sh --calibrate): the composer with no declaration. */
holoIntentToggle = function () { return el("span", "grow"); };
JS
      ;;
    ask-never-reaches-the-prompt)
      # S169'S RED CONTROL FOR FL-015, DAEMON HALF — the captain's declaration
      # dropped on the way to the worker. This is the failure mode a control
      # like his invites: the switch is on the screen, it lights up when he
      # clicks it, the POST carries it… and the prompt says exactly what it said
      # before. Broken in the DAEMON on purpose — a client-only break would show
      # up as a missing control, which the check above already owns; this one
      # can ONLY be seen by driving the whole stack and looking at what the turn
      # DID, which is the half that would have caught the original defect.
      "${LCARS_PYTHON_BIN:-python3}" - "$dest/lcars_serve/actions.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        return _ASK_DECLARED if intent == "ask" else _ANSWER_THEN_STOP'
new = '        return _ANSWER_THEN_STOP'
assert old in s, "the FL-015 control could not find the intent clause"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    banner-says-rendering)
      # S169'S RED CONTROL FOR FL-015'S SECOND HALF — the working strip
      # asserting a RENDER again, which is what he read through a long turn on
      # which he had asked a question. Nothing else moves: the strip is in the
      # right place, animating, at the right moment. It simply claims a reason
      # neither side has earned.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'var HOLO_WORKING_TEXT = "Working on the holodeck\u2026";'
assert old in s, "the banner control could not find the working text"
new = 'var HOLO_WORKING_TEXT = "Rendering on the holodeck\u2026";'
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

# `$LCARS_HOLODECK_VARIANTS` calibrates a SUBSET — for re-proving the controls a
# fix round just added without paying for fourteen full browser runs. The
# default is every one of them, and a round is not calibrated until the default
# has been run.
VARIANTS="${LCARS_HOLODECK_VARIANTS:-no-accent board-stays flat-preview sandbox-decoration deck-grows grounding-sticks trace-eats-prose retry-is-a-dead-end n5-exit-code-in-banner retry-doubles-the-line two-voices-in-the-banner fence-loses-its-filename morning-points-nowhere warm-pill-lies intent-scrim-scrolls-away draft-dies-on-repaint poll-rebuilds-the-deck no-paste-on-the-composer no-ask-on-the-composer ask-never-reaches-the-prompt banner-says-rendering}"

# ── WHAT EACH CONTROL OWNS (fix round 1b) ───────────────────────────────────
# A NON-ZERO EXIT IS NOT A CONTROL GOING RED. Every variant here breaks ONE
# thing, and the only evidence that the check can see that thing is that the run
# failed ON THE SENTENCE THAT NAMES IT. Until this table existed, --calibrate
# accepted any failure at all — so when the rig's own precondition stopped
# firing, eleven of twelve controls "went red" on the harness's "THE N4 CHECK
# PROVED NOTHING" line, the summary printed "every control went red", and three
# of this session's four deliverables were proven by nothing whatsoever.
variant_signature() {   # $1 = variant → the failure text that control OWNS
  case "$1" in
    no-accent)                 echo "--holo-grid resolves to nothing" ;;
    board-stays)               echo "still visible on the deck" ;;
    flat-preview)              echo "pane preview is 0px wide" ;;
    sandbox-decoration)        echo "THE SANDBOX IS DECORATION" ;;
    deck-grows)                echo "THE PAGE SCROLLS ON THE DECK" ;;
    grounding-sticks)          echo "THE RECOMMENDED PATH WROTE NO MOCKUP" ;;
    trace-eats-prose)          echo "THE CHAT DELETED WHAT THE MODEL WROTE" ;;
    retry-is-a-dead-end)       echo "RETRY TURN IS A DEAD END (N4)" ;;
    n5-exit-code-in-banner)    echo "N5: the HOLODECK OFFLINE banner leaks a raw exit code" ;;
    retry-doubles-the-line)    echo "N6: the captain's line is on the deck TWICE" ;;
    two-voices-in-the-banner)  echo "TWO VOICES IN THE BANNER" ;;
    fence-loses-its-filename)  echo "A FENCE'S DECLARED FILENAME NEVER REACHED THE SCREEN" ;;
    morning-points-nowhere)    echo "THE MORNING STATE POINTS AT NOTHING" ;;
    warm-pill-lies)            echo "THE SCREEN SAYS TWO THINGS AT ONCE" ;;
    intent-scrim-scrolls-away) echo "THE INTENT SCRIM SCROLLS AWAY" ;;
    draft-dies-on-repaint)     echo "THE HOLODECK ATE AN UNSENT TURN ON THE BOARD ROUND-TRIP" ;;
    poll-rebuilds-the-deck)    echo "THE 4s POLL REBUILDS THE CHAT PANE" ;;
    no-paste-on-the-composer)  echo "A PASTED IMAGE DID NOTHING ON THE COMPOSER" ;;
    no-ask-on-the-composer)    echo "THE ASK AFFORDANCE IS NOT ON THE SCREEN" ;;
    ask-never-reaches-the-prompt) echo "HE ASKED AND THE HOLODECK BUILT ANYWAY" ;;
    banner-says-rendering)     echo "THE WORKING STRIP STILL ASSERTS A RENDER" ;;
    *)                         echo "" ;;
  esac
}

# WHICH "PROVED NOTHING" LINES A CONTROL IS ALLOWED TO EMIT (S169).
#
# The judge below treats any "…CHECK PROVED NOTHING" line as a failed
# PRECONDITION — the harness saying it could not look — and refuses to call the
# control red on the strength of it. That rule is right, and it means a control
# which BY CONSTRUCTION blinds one of the other checks would otherwise be
# reported as proving nothing even when it went red for its own reason.
#
# Four of the eighteen do this to S169's INTENT-SCRIM check, and each does it
# for a reason that is a fact about the control rather than a convenience:
#
#   no-accent      deletes `--holo-grid`, which is what the deck's grid LINES
#                  are drawn in — so the check's own calibration sample (the
#                  bare grid beside the panel) becomes the same colour as the
#                  scrim, and "the text is backed" is unfalsifiable. The check
#                  says so itself, which is the correct behaviour.
#   flat-preview   hides the whole preview pane, so there is no laid-out line of
#                  text anywhere to photograph.
#   deck-grows     removes the viewport pin, so nothing scrolls internally: the
#                  panel is as tall as the document and the scrim cannot leave.
#   poll-rebuilds- rebuilds the deck every 4s, which destroys BOTH the composer
#   the-deck       node mid-measurement and the intent panel's scroll position.
#
# Naming the exemption here keeps that honest and narrow — it exempts a LINE,
# never the control's own signature, which is still required.
variant_blind_exemptions() {   # $1 = variant → substrings that may be ignored
  case "$1" in
    no-accent|flat-preview|deck-grows)
      echo "THE INTENT-SCRIM CHECK PROVED NOTHING" ;;
    poll-rebuilds-the-deck)
      echo "THE INTENT-SCRIM CHECK PROVED NOTHING|THE DRAFT CHECK PROVED NOTHING|THE ASK CHECK PROVED NOTHING|THE ASK-OUTCOME CHECK PROVED NOTHING" ;;
    # S169: with no control on the composer there is nothing to click, so the
    # ask TURN is never sent and its downstream checks correctly say they could
    # not look. The control's own signature is still required.
    no-ask-on-the-composer)
      echo "THE ASK-TURN CHECK PROVED NOTHING|THE ASK-OUTCOME CHECK PROVED NOTHING|THE WORKING-COPY CHECK PROVED NOTHING" ;;
    *)
      echo "" ;;
  esac
}

# THE PRECONDITION. Four of these controls (N4, N5, N6, one-voice) can only be
# seen at all if the scripted worker's FIRST DESIGN TURN ACTUALLY DIED and the
# HOLODECK OFFLINE banner actually appeared. If it did not, those controls
# measured an empty room — which is exactly what happened, silently, for two
# whole calibration runs. Every variant must face that dead turn.
#
# `grounding-sticks` is the ONE honest exemption, and it is exempt by
# construction rather than by convenience: it stops the posture ever handing
# over, so NO design turn is ever spawned and there is no turn left to kill. Its
# own signature (the recommended path wrote no mockup) is what proves it fired.
variant_needs_dead_turn() {   # $1 = variant → 0 if the dead first turn must fire
  case "$1" in
    grounding-sticks) return 1 ;;
    *) return 0 ;;
  esac
}

# Judge one control off its MEASUREMENTS, never off its exit code. Prints the
# reason it went red (or why it proved nothing) and returns 0 only when the
# control is honest.
judge_control() {   # $1 = variant, $2 = its artifact dir
  "${LCARS_PYTHON_BIN:-python3}" - "$1" "$2/holodeck-check.json" \
      "$(variant_signature "$1")" \
      "$(variant_needs_dead_turn "$1" && echo yes || echo no)" \
      "$(variant_blind_exemptions "$1")" <<'PY'
import json, sys
name, path, sig, needs_dead = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "yes"
exempt = [x for x in (sys.argv[5] if len(sys.argv) > 5 else "").split("|") if x]
try:
    with open(path) as fh:
        d = json.load(fh)
except Exception as e:
    print("    NOTHING WAS MEASURED: could not read %s (%s) — this control "
          "exited non-zero without ever judging the deck." % (path, e))
    sys.exit(1)
failures = d.get("failures") or []
n4 = (d.get("want") or {}).get("n4") or {}
if not failures:
    print("    THE CONTROL DID NOT GO RED: the run recorded no failures at all.")
    sys.exit(1)
# 1. THE PRECONDITION. A "PROVED NOTHING" line is the harness saying it could
#    not look — it is never a control going red.
blind = [f for f in failures if "CHECK PROVED NOTHING" in f]
if not needs_dead:
    blind = [f for f in blind if "THE N4 CHECK PROVED NOTHING" not in f]
# …and the lines this control is DECLARED to blind by construction (S169).
for ex in exempt:
    blind = [f for f in blind if ex not in f]
if blind:
    print("    PRECONDITION DID NOT FIRE — this control proved NOTHING:")
    for f in blind:
        print("      · " + f)
    sys.exit(1)
if needs_dead and not n4.get("died"):
    print("    PRECONDITION DID NOT FIRE: the scripted worker's first design "
          "turn never died, so the whole N4/N5/N6/one-voice half of the check "
          "measured an empty room (n4=%s)." % json.dumps(n4))
    sys.exit(1)
# 2. AND IT WENT RED FOR ITS OWN REASON.
if not sig:
    print("    NO SIGNATURE IS DECLARED FOR %r — add one to variant_signature() "
          "or this control is only ever proving that something failed." % name)
    sys.exit(1)
own = [f for f in failures if sig in f]
if not own:
    print("    WENT RED FOR THE WRONG REASON — nothing it failed on names what "
          "it breaks (%r). What it actually failed on:" % sig)
    for f in failures:
        print("      · " + f[:160])
    sys.exit(1)
print("    ✓ its own reason: " + own[0][:150])
if needs_dead:
    print("      (precondition: the first design turn died, RETRY %s, "
          "recovered %s)" % (n4.get("retried"), n4.get("recovered")))
sys.exit(0)
PY
}

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
  local bad=0 blind=0 v
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
    elif judge_control "$v" "$WORK/variant-$v/out"; then
      printf '\033[32m  ✓ %s failed, as it must.\033[0m\n' "$v"
    else
      # A NON-ZERO EXIT THAT PROVES NOTHING. This is the state the whole round
      # was reported green from, so it gets its own loud category and its own
      # non-zero exit: a control that cannot go red is decoration, and a
      # calibrate run that PRINTS "every control went red" while proving nothing
      # is worse than no calibrate at all.
      printf '\033[31m  ✗ %s exited non-zero but PROVED NOTHING (see above).\033[0m\n' "$v"
      blind=$((blind + 1))
    fi
  done
  printf '\n'
  if [ "$bad" -eq 0 ] && [ "$blind" -eq 0 ]; then
    printf '\033[32mCALIBRATED\033[0m — every control went red FOR ITS OWN REASON, and every\n'
    printf '        one of them faced the dead first turn it is meant to face. The\n'
    printf '        check can see.\n'
    return 0
  fi
  [ "$bad" -gt 0 ] &&
    printf '\033[31m%d CONTROL(S) DID NOT GO RED\033[0m — the check is decoration until they do.\n' "$bad"
  [ "$blind" -gt 0 ] &&
    printf '\033[31m%d CONTROL(S) WENT RED WITHOUT PROVING ANYTHING\033[0m — they failed on a\n' "$blind"
  [ "$blind" -gt 0 ] &&
    printf '        precondition the rig never met, or on something other than the\n' &&
    printf '        defect they inject. Their evidence does not exist.\n'
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
