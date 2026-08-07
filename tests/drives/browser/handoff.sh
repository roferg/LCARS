#!/usr/bin/env bash
# ============================================================================
# S169 — THE ▶ SEND TO ALIGN BOX, IN A REAL BROWSER.
#
#   bash tests/drives/browser/handoff.sh              # the product
#   bash tests/drives/browser/handoff.sh --calibrate  # the RED CONTROLS
#   bash tests/drives/browser/handoff.sh --all        # both
#
# WHY THIS EXISTS, AND WHY IT IS COMMITTED. S128 built a rig for this same
# dialog, proved a real defect with it, and then TORE IT DOWN — so S169 opened
# with no equipment for the one screen it changes. That has now happened three
# rounds running (S140's headed rig, S163's, S128's). This one is tracked.
#
# WHAT IS BEING PROVEN. The hand-off brief used to be the captain's own words
# and nothing else — six lines in an eight-row box, all of it on screen. It now
# also carries what the mockup CHANGES about the app he has today and what it
# IMPLIES that nobody has settled, which on the real fixture room is a 31-line
# draft. That is the whole value of the holodeck ("if I have to spell out each
# change… the value is lost") and it is also the exact shape of the defect that
# session shipped: S128's promote dialog is 1812px against a ~677px window, and
# its open questions sat 546–780px BELOW THE FOLD while ▦ File Mission did not.
# The session's own goal, delivered and invisible.
#
# So this rig does not check that the text exists — 30 unit tests in
# web/tests/test_holodeck_endpoints.py own that, and every one of them would
# stay green on a box the captain cannot read. It measures, at 1440x677 in real
# Chrome, off laid-out boxes:
#
#   • the draft the DAEMON actually delivered to the live textarea, by its three
#     section headings — a node harness calls the builders itself and stays
#     green against a daemon that sends nothing (the S168 lesson);
#   • that he MEETS THE TOP OF HIS OWN BRIEF — the box starts inside the
#     dialog's scrolling band, and it is clickable where it sits;
#   • that NOTHING IS BEHIND A NESTED SCROLLBAR (S169 fix round 1). This is the
#     check the first shape was structurally blind to: it counted SOURCE lines,
#     and this draft's lines wrap three and four ways at 613px, so a box
#     "showing 16 of 31 lines" was in fact showing 269px of 817px — two thirds
#     of his brief inside a scrollbox inside a scrolling modal, with
#     `## Implied by the mockup` at the bottom of the INNER one;
#   • how many lines are genuinely in front of him at rest, off the laid-out
#     intersection of the box with that band;
#   • that the rest is REACHABLE on the one scroller that is left;
#   • that the line ABOVE the box NAMES what the draft is made of, and is itself
#     above the fold — the one signal for a captain who reads only one screen;
#   • that ▦ File Mission is still hit-testable (elementFromPoint, not "it is
#     in the DOM"), and that S128's open-questions cue still is too.
#
# THE FIXTURE IS THE REAL ROOM. `web/tests/fixtures/s128-drive/concept.md` is a
# byte copy of the concept doc the holodeck wrote for the program whose mission
# then lost the look — the same file the unit suite uses. Nothing here is
# invented test data.
#
# ZERO TOKENS AND NO WORKER AT ALL. The whole path — enter the deck, pick the
# archived program back up (`holodeck_open` is a warm restart read off disk),
# ▶ Send to Align (`holodeck_promote` is a read) — spawns nothing. smoke.sh's
# claude/copilot shims are on PATH and the run reports 0 invocations.
#
# THE RED CONTROLS are the point of --calibrate: a check that cannot go red is
# decoration. EIGHT variants each patch a COPY of web/ and each MUST make the run
# fail, on the sentence that names what it breaks — the daemon reverted to
# S128's brief (the change list never sent at all), the sizing pass deleted so
# the box falls back to `rows` and the inner scrollbar returns, the same defect
# reached from CSS with a height cap at the tester's measured 243px, the hint
# reverted to a sentence that says nothing about the new sections, the textarea
# clipping its own content, the modal's sticky footer defeated so ▦ File Mission
# leaves the window, the hint put back UNDER the (now tall) box so it falls out
# of the dialog's scrolling band, and a spacer that pushes the brief itself
# below the fold. This repo's own web/ is never touched.
# `$LCARS_HANDOFF_VARIANTS` runs a SUBSET.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"
PROGRAM="Tile editor"
SLUG="tile-editor"        # actions._slug("Tile editor") — deterministic, so the
                          # room can be planted before the daemon ever runs.
FIXTURE="$REPO/web/tests/fixtures/s128-drive/concept.md"

WORK="${LCARS_BROWSER_HANDOFF_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-handoff.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-handoff.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-handoff.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
skip() {
  printf '\n\033[33m════ SKIPPED — the hand-off box was NOT checked in a browser ════\033[0m\n'
  printf '  %s\n' "$1"
  printf '  This is NOT a pass. Nothing about the dialog has been proven.\n\n'
  exit 77
}

command -v git >/dev/null 2>&1 || skip "git not found — the sidecar fixture needs it."
[ -f "$FIXTURE" ] || skip "the S128 fixture room is missing: $FIXTURE"

# ── the expectation the driver judges against ──────────────────────────────
# 677px is the height that produced S128's D1 on a 1440x900 screen. Measuring
# this dialog in a taller window would hide the entire defect class.
#
# `minLines` is what the fixture room's draft actually is (31) with headroom
# below it, so it fails on a brief that lost a section rather than on wording.
# `minLinesShown` (S169 fix round 1) is now judged against the LAID-OUT band the
# captain can actually see, not against the `rows` attribute — see judgeHandoff.
#
# TWO VIEWPORTS, and the second one is the tester's. 1440x677 is the S128
# window; 1280x613 is a SHORT one, where the sticky footer's band eats into the
# body and the line above the box has the least room. A dialog that measures up
# at one height and not the other is a dialog that has been checked at one
# height. `minLinesShown` falls with the window because the claim is "enough of
# it to read as a brief", not "the same 12 lines on a laptop and a phone".
write_expect() {   # $1 = width  $2 = height  $3 = min lines on screen at rest
  cat >"$WORK/expect.json" <<EOF
{
  "viewportW": $1,
  "viewportH": $2,
  "minLines": 24,
  "minLinesShown": $3,
  "sections": [
    "## What it must do — in your own words",
    "## What the mockup changes — as the design chat recorded it",
    "## Implied by the mockup — NOT things you said"
  ],
  "hintNames": ["changes the mockup makes", "implies"],
  "expectQCue": true
}
EOF
}
write_expect 1440 677 12

# ── the planted sidecar: a real local git repo with one archived program ────
# The daemon ADOPTS this (`_ensure_sidecar` is idempotent) and the deck lists
# the room as an ARCHIVED program, which is what makes it openable with no
# worker: `holodeck_open` warm-restarts from the transcript on disk.
plant_sidecar() {   # $1 = the run's artifact dir
  local root="$1/handoff-root"
  local side="$root/fixture-holodeck"
  rm -rf "$root"
  mkdir -p "$side/$SLUG"
  cat >"$side/README.md" <<'MD'
# fixture-holodeck — planted by tests/drives/browser/handoff.sh
Not a captain's archive. A fixture.
MD
  # THE CONCEPT DOC IS THE REAL ONE, copied from the tracked fixture rather than
  # retyped here. A rig that writes its own concept doc is measuring the rig.
  cp "$FIXTURE" "$side/$SLUG/concept.md"
  # A room is a PROGRAM because it carries `transcript.md` — and the program's
  # NAME is read out of it, which is what the brief's first line becomes.
  cat >"$side/$SLUG/transcript.md" <<TR
# $PROGRAM

The holodeck's record of this program.

## Turn 1 · 2026-08-06T09:00:00Z

**Captain:** give the tile editor a more modern UI look and add a light/dark mode.

**Holodeck:** Planted by the rig — the mockup and concept doc are on disk.
TR
  cat >"$side/$SLUG/mockup.html" <<'MOCK'
<!DOCTYPE html>
<!-- VISUAL REFERENCE ONLY — a rig fixture standing in for the model-written
     mockup. NOT shipping code, internals deliberately fake. It exists so the
     room reads as ready to hand over; this rig measures the DIALOG, not the
     preview pane (holodeck.sh owns that). -->
<html><head><meta charset="utf-8"><title>Tile editor — mockup</title>
<style>
  body{margin:0;background:#0f1729;color:#e8ecf5;font:14px/1.5 system-ui}
  .bar{display:flex;gap:8px;padding:10px 12px;background:#1f2937}
  .pill{padding:4px 10px;border-radius:999px;background:#2563eb}
</style></head>
<body>
  <div class="bar"><span class="pill">Maps</span><span class="pill">Objects</span></div>
</body></html>
MOCK
  ( cd "$side" && git init -q . &&
    git -c user.email=h@l -c user.name=holo add -A &&
    git -c user.email=h@l -c user.name=holo commit -q --no-gpg-sign \
        -m "holodeck: sidecar created" ) >/dev/null 2>&1 ||
    skip "could not git init the planted sidecar at $side"
  echo "$root"
}

# ── one run of smoke.sh with the hand-off act turned on ────────────────────
run_once() {   # $1 = label, $2 = web dir, $3 = artifact dir
  local label="$1" web="$2" out="$3"
  mkdir -p "$out"
  local root; root="$(plant_sidecar "$out")"
  say "── $label"
  note "web:       $web"
  note "room:      $root/fixture-holodeck/$SLUG/  (concept.md is the real S128 doc)"
  LCARS_BROWSER_OUT="$out" \
  LCARS_BROWSER_WEB_DIR="$web" \
  LCARS_BROWSER_HANDOFF_CHECK="$WORK/expect.json" \
  LCARS_HOLODECK_ROOT="$root" \
    bash "$HERE/smoke.sh"
  return $?
}

# ── the red controls: a COPY of web/, each broken one way ───────────────────
make_variant() {   # $1 = name, $2 = dest
  local name="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  cp -R "$REPO/web/." "$dest/" 2>/dev/null
  local css="$dest/static/board.css" js="$dest/static/board.js"
  local py="$dest/lcars_serve/actions.py"
  case "$name" in
    no-change-list)
      # THE DAEMON REVERTED TO S128. The front end is untouched and perfect;
      # the brief simply arrives with the captain's words and nothing else,
      # which is the state this whole session exists to end. It is the control
      # a node harness is structurally blind to.
      cat >>"$py" <<'PY'


def _handoff_parts(concept_text):   # S169 RED CONTROL — S128's behaviour
    return _handoff_requirements(concept_text), [], []
PY
      ;;
    no-fit)
      # S169 FIX ROUND 1'S OWN CONTROL, and the tester's exact defect. The
      # sizing pass is deleted, so the box falls back to its `rows` attribute —
      # which counts SOURCE lines while the draft's lines wrap three and four
      # ways — and two thirds of his brief goes back behind an inner scrollbar
      # inside a modal body that is itself scrolling. MEASURED before the cure:
      # a 269px box over 817px of content at 1440x677.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '  fitBrief();\n  brief.addEventListener("input", fitBrief);'
assert old in s, "the sizing pass moved — this control is measuring nothing"
open(p, "w").write(s.replace(old, "  /* red control: no fit */", 1))
PY
      ;;
    capped-box)
      # THE SAME DEFECT REACHED FROM CSS: a height cap on the box, at the exact
      # number the tester measured in his 1280x700 window. The sizing pass still
      # runs and still cannot win.
      printf '\n[data-holo="handoff-brief"]{max-height:243px}\n' >>"$css"
      ;;
    mute-hint)
      # THE LINE UNDER THE BOX SAYS NOTHING ABOUT WHAT GREW. This is the one
      # signal for a captain who reads only the first screen.
      "${LCARS_PYTHON_BIN:-python3}" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'f1.appendChild(el("span", "hint", holoBriefHint(seed)));'
assert old in s, "the hint line moved — this control is measuring nothing"
new = ('f1.appendChild(el("span", "hint", "Drafted from your concept doc. '
       'Rewrite it however you like."));')
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    clip-box)
      # THE BOX CLIPS ITS OWN CONTENT. Perfectly sized, and the part of the
      # draft past its height cannot be reached by any means.
      printf '\n.field textarea{overflow-y:hidden}\n' >>"$css"
      ;;
    no-sticky-foot)
      # THE STICKY FOOTER DEFEATED. The modal grows past the window and takes
      # ▦ File Mission (and S128's open-questions cue) off the bottom with it.
      printf '\n.modal{max-height:none}\n.modal-body{overflow-y:visible}\n' >>"$css"
      ;;
    hint-below-box)
      # THE LINE THAT SAYS WHAT THE DRAFT IS MADE OF, PUT BACK UNDER THE BOX.
      # That was its position until S169 fix round 1, and it only ever worked
      # while the box was short enough to share the first screen with it. With
      # the box as tall as the draft it lands ~800px down — out of the dialog's
      # scrolling band, behind the footer, and unreadable by the captain who
      # reads one screen, who is the only reason the line exists.
      printf '\n[data-holo="handoff-brief-field"]{display:flex;flex-direction:column}\n[data-holo="handoff-brief-field"] .hint{order:9}\n' >>"$css"
      ;;
    brief-below-fold)
      # D1 ITSELF, aimed at the new content: the box is pushed below the fold,
      # so the draft is delivered, sized, scrollable — and off screen.
      printf '\n[data-holo=handoff-brief-field]{margin-top:900px}\n' >>"$css"
      ;;
    *) return 1 ;;
  esac
  return 0
}

VARIANTS="${LCARS_HANDOFF_VARIANTS:-no-change-list no-fit capped-box mute-hint clip-box no-sticky-foot hint-below-box brief-below-fold}"

# WHAT EACH CONTROL MUST FAIL ON. A non-zero exit is not a control going red —
# a variant that fell over for an unrelated reason proves nothing about the
# check it was built to exercise. This is holodeck.sh's discipline, and it is
# there because a stale rig once printed "every control went red" over eleven
# runs that had failed on the harness's own error line.
expected_reason() {   # $1 = variant
  case "$1" in
    no-change-list)    echo "does not contain" ;;
    no-fit)            echo "INNER scrollbar" ;;
    capped-box)        echo "INNER scrollbar" ;;
    mute-hint)         echo "never mentions" ;;
    clip-box)          echo "clips its own content" ;;
    no-sticky-foot)    echo "File Mission is not clickable" ;;
    hint-below-box)    echo "not WHOLLY on" ;;
    brief-below-fold)  echo "does not start on screen" ;;
  esac
}

run_product() {
  local rc=0 worst=0 dir
  # 1440x677 — S128's window. 1280x613 — the tester's short one (fix round 1),
  # where the footer band is at its most expensive and the line above the box
  # has the least room. Both must pass; the second is not a bonus.
  for pass in "1440 677 12 product" "1280 613 8 product-short"; do
    set -- $pass
    write_expect "$1" "$2" "$3"
    dir="$WORK/$4"
    run_once "PRODUCT — this repo's web/, unmodified · ${1}x${2}" "$REPO/web" "$dir"
    rc=$?
    case "$rc" in
      0) printf '\n\033[32m✓ THE SEND-TO-ALIGN BOX MEASURED UP AT %sx%s.\033[0m\n' "$1" "$2"
         printf '  Now open it: %s/handoff.png\n\n' "$dir" ;;
      77) return 77 ;;
      *) printf '\n\033[31m✗ THE HAND-OFF DIALOG IS WRONG AT %sx%s.\033[0m See above and\n' "$1" "$2"
         printf '  %s/handoff-check.json\n\n' "$dir"
         worst=1 ;;
    esac
  done
  write_expect 1440 677 12
  return $worst
}

run_calibrate() {
  local bad=0
  for v in $VARIANTS; do
    local dest="$WORK/variant-$v/web" out="$WORK/variant-$v/run"
    mkdir -p "$WORK/variant-$v"
    if ! make_variant "$v" "$dest"; then
      printf '\033[31m✗ %s — unknown variant\033[0m\n' "$v"; bad=$((bad + 1)); continue
    fi
    run_once "RED CONTROL — $v" "$dest" "$out" >"$WORK/variant-$v.log" 2>&1
    local rc=$?
    local want; want="$(expected_reason "$v")"
    local fired=1
    if [ "$rc" = "0" ]; then
      fired=0
    elif ! grep -qF "$want" "$out/handoff-check.json" 2>/dev/null; then
      fired=2
    fi
    case "$fired" in
      1) printf '  \033[32m✓ RED\033[0m %-18s failed on %s\n' "$v" "$(printf '%s' "$want")" ;;
      0) printf '  \033[31m✗ GREEN\033[0m %-16s THE CHECK CANNOT SEE THIS. rc=%s\n' "$v" "$rc"
         bad=$((bad + 1)) ;;
      2) printf '  \033[31m✗ WRONG REASON\033[0m %-9s rc=%s but never said %s\n' "$v" "$rc" "$(printf '%s' "$want")"
         printf '      %s\n' "$WORK/variant-$v.log"
         bad=$((bad + 1)) ;;
    esac
  done
  if [ "$bad" = "0" ]; then
    printf '\n\033[32m✓ EVERY RED CONTROL WENT RED, ON ITS OWN SENTENCE.\033[0m\n\n'
    return 0
  fi
  printf '\n\033[31m✗ %s CONTROL(S) DID NOT GO RED FOR THE RIGHT REASON.\033[0m\n' "$bad"
  printf '  The check proves less than it claims. Fix the check, not the product.\n\n'
  return 1
}

say "S169 — the ▶ SEND TO ALIGN box, measured in real Chrome"
note "artifacts: $WORK"
printf '\n'
case "$MODE" in
  product)   run_product; exit $? ;;
  --calibrate) run_calibrate; exit $? ;;
  --all)
    run_calibrate; C=$?
    run_product;   P=$?
    [ "$P" = "77" ] && exit 77
    [ "$C" = "0" ] && [ "$P" = "0" ] && exit 0
    exit 1 ;;
  *) skip "unknown mode $MODE — use (nothing), --calibrate or --all" ;;
esac
