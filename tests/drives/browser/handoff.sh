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
# S169 FIX ROUND 2 adds four more, and the first is the same defect fix round 1
# cured in the textarea and walked past one box lower:
#
#   • THE GUIDANCE BLOCK IS NOT A NESTED SCROLLER either. Measured on the
#     capstone: clientHeight 228 against scrollHeight 729 — 69% of the block
#     carrying the PRECEDENCE RULE hidden behind a scrollbar of its own, inside
#     a modal body that already scrolls;
#   • THE CHECK BAND, driven END TO END. `promote` really does spawn a bounded
#     read-only pass over the room, the band really does poll for its verdict,
#     and what is measured is the FLAGGED band on the screen, above the brief
#     box, carrying the contradicted line and the mockup's evidence. The worker
#     is a python script handed in through `LCARS_BROWSER_WORKER_BIN` (the same
#     device holodeck.sh uses) — a real subprocess on the real road, zero
#     tokens, no engine;
#   • that the line above the box does not CLAIM a comparison the daemon never
#     made ("18 changes the mockup makes to today's app" — it counted the
#     bullets of a section a model wrote from the conversation);
#   • that the open-questions cue is no longer an amber ⚠ ALARM fired at every
#     open before the captain has had a second to answer anything.
#
# THE FIXTURE IS THE REAL ROOM. `web/tests/fixtures/s128-drive/concept.md` is a
# byte copy of the concept doc the holodeck wrote for the program whose mission
# then lost the look — the same file the unit suite uses. Nothing here is
# invented test data.
#
# ZERO TOKENS. The whole path — enter the deck, pick the archived program back
# up (`holodeck_open` is a warm restart read off disk), ▶ Send to Align — runs
# against a real daemon. S169 fix round 2 changed one thing about this: promote
# now spawns ONE bounded read-only CHECK worker, and rather than switch it off
# (which would leave the new band unmeasured, and a rig that stubs the band
# instead of the pass is measuring itself) the rig hands in a PYTHON SCRIPT as
# the engine. It reads the numbered claims out of the prompt the daemon really
# built and answers in the shape the parser really requires. No engine binary is
# ever invoked; smoke.sh's claude/copilot refusal shims stay on PATH so anything
# ELSE that tried to spawn would still be caught.
#
# THE RED CONTROLS are the point of --calibrate: a check that cannot go red is
# decoration. THIRTEEN variants each patch a COPY of web/ and each MUST make the
# run fail, on the sentence that names what it breaks — the daemon reverted to
# S128's brief (the change list never sent at all), the sizing pass deleted so
# the box falls back to `rows` and the inner scrollbar returns, the same defect
# reached from CSS with a height cap at the tester's measured 243px, the hint
# reverted to a sentence that says nothing about the new sections, the textarea
# clipping its own content, the modal's sticky footer defeated so ▦ File Mission
# leaves the window, the hint put back UNDER the (now tall) box so it falls out
# of the dialog's scrolling band, and a spacer that pushes the brief itself
# below the fold; plus (fix round 2) the height cap put back on the guidance
# block, the check band hidden by CSS, the band's poll deleted so it never
# resolves, the hint's overclaiming sentence restored verbatim, and the amber
# UNANSWERED alarm put back on the cue. This repo's own web/ is never touched.
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
# ── S169 FIX ROUND 2 LOWERED `minLinesShown`, AND HERE IS THE WHOLE REASON ──
#
# It was 12 / 8. It is now 9 / 6, and that is a MEASURED CONSEQUENCE of a
# deliberate change, not a bar relaxed to make a diff pass. The check band —
# what one bounded read-only pass found when it read the drafted change list
# back against the mockup — now sits between the hint and the brief box, and in
# its FLAGGED state it is ~120px tall. Those pixels come off the captain's own
# draft on the first screen; there is nowhere in this dialog they could come
# from instead (the footer strip shrinks the scrolling body by exactly as much).
#
# The band was slimmed first, and the slimming is itself measured: the first
# browser run of it came to 165px and left SIX lines of brief at 1440x677 and
# THREE at 1280x613 — a finding delivered on top of a slot. A one-line heading
# and two clamped rows brought it to 9 / 6.
#
# AND THE RIG NOW PROVES MORE THAN IT DID, not less. `expectDeriveRunning`
# requires the RUNNING band to be WHOLLY on the first screen, above the brief
# box, hit-testable, and carrying the sentence that says he may walk away; then
# `reloadProof` RELOADS THE PAGE and walks the same controls again, and
# `expectChangeLines` requires the derived change to be in the textarea he
# would send. So what these numbers mean together is "the wait, the promise he
# can leave, and nine lines of his own words — all in front of him at rest".
#
# TWO VIEWPORTS, and the second one is the tester's. 1440x677 is the S128
# window; 1280x613 is a SHORT one, where the sticky footer's band eats into the
# body and the line above the box has the least room. A dialog that measures up
# at one height and not the other is a dialog that has been checked at one
# height. `minLinesShown` falls with the window because the claim is "enough of
# it to read as a brief", not "the same 12 lines on a laptop and a phone".
write_expect() {   # $1 = width  $2 = height  $3 = min lines shown  $4 = mode
  # MODE is `reload` or `typed`, and they are two different claims that cannot
  # share one run:
  #
  #   reload — he walks away and the PAGE IS RELOADED. Every byte of client
  #            state goes: the dialog, the draft, the poll, the timer. He walks
  #            the same controls again and must find a FINISHED brief with the
  #            derived change in the textarea. If that survives, it survives
  #            because the DAEMON owns the wait.
  #   typed  — he TYPES while it is running. When the pass lands the daemon has
  #            a better draft, and putting it in the box would destroy what a
  #            human wrote (FL-013, one dialog over). His text must survive and
  #            the band must SAY it kept it. A reload would wipe the typing, so
  #            this run does not reload.
  #   turn   — S171. He presses the gate, waits, sends, closes the dialog and
  #            KEEPS CHATTING. The change list he had is derived from a mockup
  #            that no longer exists, so the gate must fall back to
  #            "generate the change list" — his own "wait guard". No reload and
  #            no typing: this run is about what happens AFTER he files or
  #            declines to.
  local mode="${4:-reload}"
  local reload=false typed='""' keeps='""' inval=false chg
  chg="[\"$CHANGE_MARK\"]"
  case "$mode" in
    typed)
      typed='"MY OWN WORDS — DO NOT CLOBBER"'
      keeps='"MY OWN WORDS — DO NOT CLOBBER"'
      ;;
    turn) inval=true ;;
    failed) ;;
    *) reload=true ;;
  esac
  # S172 — THE FAILED-PASS LEG. The pass does not answer, so there is no change
  # list, no running band to sit in front of and nothing to append. What this
  # leg exists for is the BAR: ▶ SEND TO ALIGN must be live and pressable (with
  # the escape hatch deleted it is the only road off a dead engine), and the two
  # controls on it must read as one family — the captain's own screenshot was a
  # small outlined pill beside a full-size filled button.
  local run_band=true done_band=true failed=false secs
  # S172 — THE QUESTION THE STUB PASS DECLARES IT IS NOT REPORTING. It must be
  # in the textarea he would send, in bucket 2, marked IMPLIED.
  local imp="[\"$ASK_MARK\"]"
  local names='"changes read off your project", "implies"'
  secs='"## What the mockup changes about your app as it is today",
    "## Implied by the mockup — NOT things you said"'
  if [ "$mode" = failed ]; then
    # THERE IS NO CHANGE LIST ON THIS LEG, so the line under the box must not
    # name one — and demanding that it does would be the rig failing itself.
    # `hintForbids` stays exactly as it is: nothing may overclaim, ever.
    run_band=false; done_band=false; failed=true; chg='[]'; imp='[]'
    secs='"## Implied by the mockup — NOT things you said"'
    names='"implies"'
  fi
  cat >"$WORK/expect.json" <<EOF
{
  "viewportW": $1,
  "viewportH": $2,
  "minLines": 8,
  "minLinesShown": $3,
  "minLinesShownRunning": $3,
  "sections": [
    $secs
  ],
  "briefForbids": ["## What it must do — in your own words", "**Turn "],
  "briefOpensWith": "$PROGRAM",
  "hintNames": [$names],
  "hintForbids": ["today's app", "the design chat recorded",
                  "Drafted from your concept doc", "things you said"],
  "expectGate": true,
  "expectGateFailed": $failed,
  "expectInvalidation": $inval,
  "expectQCue": true,
  "qcueForbids": ["unanswered", "⚠"],
  "expectGuidance": true,
  "expectDeriveRunning": $run_band,
  "walkAwayPhrases": ["CLOSE THIS AND WALK AWAY IF YOU LIKE",
                      "survives a reload and a restart",
                      "send the brief without one"],
  "barWalkAwayPhrases": ["survives closing the deck",
                         "come back when you like"],
  "typeWhileWaiting": $typed,
  "reloadProof": $reload,
  "expectDeriveDone": $done_band,
  "donePhrases": ["stood in your project", "produces no line"],
  "expectChangeLines": $chg,
  "expectImpliedLines": $imp,
  "expectBriefKeeps": $keeps
}
EOF
}
# ── S170: THE DERIVATION, DRIVEN FOR REAL, FOR ZERO TOKENS ────────────────
#
# `promote` spawns ONE bounded read-only worker that stands in the captain's
# project and reports what the mockup CHANGES about it. That list becomes a
# section of his brief, and a rig that stubbed the BAND instead of the PASS
# would be measuring itself.
#
# So the daemon spawns a real subprocess on the real road, and that subprocess
# is a PYTHON SCRIPT — the same device holodeck.sh already uses to drive a turn
# without an engine (`LCARS_BROWSER_WORKER_BIN`). Zero tokens, zero engine.
#
# It answers HONESTLY in the sense that matters here: it reads the numbered
# claims out of the prompt the daemon actually built, emits one verdict per
# claim in the shape the parser requires, and marks exactly one CONTRADICTED —
# the shape the parser requires, after a real wait, so the running band the
# rig measures is a band with a real process behind it.
# S170 — THE STUB EMITS A CHANGE LIST, because that is what the pass produces
# now. And it SLEEPS FIRST, deliberately: the running band is the surface this
# round exists for, and a pass that answers instantly is a wait the rig can
# never see. `LCARS_RIG_DERIVE_SLEEP` is the fuse.
CHANGE_MARK="today the mode switch and the map tabs are two separate bars"
ASK_MARK="the mockup draws zoom / fit buttons over the canvas - in or out?"
DERIVE_SLEEP="${LCARS_RIG_DERIVE_SLEEP:-6}"
# S172 — 1 makes the pass ANSWER NOTHING USABLE, which is the daemon's
# `ok: false` road: no marker, so `_handoff_derive_parse` returns None and the
# bar goes to its `failed` gate. That is the state the captain screenshotted
# and the state the deleted escape hatch used to cover.
MUTE="${LCARS_RIG_DERIVE_MUTE:-0}"

write_check_worker() {   # $1 = dest path
  cat >"$1" <<PYW
#!/usr/bin/env python3
"""The rig's stand-in for a derivation worker. NOT an engine — a script."""
import sys
import time

argv = sys.argv[1:]
prompt = ""
for i, a in enumerate(argv):
    if a == "-p" and i + 1 < len(argv):
        prompt = argv[i + 1]
        break
if "=== CHANGES ===" not in prompt:
    # S171 — A DESIGN TURN. The gate's WAIT GUARD only exists because a further
    # composer turn REDRAWS THE MOCKUP, which moves the daemon's fingerprint
    # and strands the change list it already had. A rig that faked that (by
    # touching the file behind the daemon's back) would be measuring itself, so
    # this branch is a real turn doing what a real design turn does: it writes
    # mockup.html into its cwd, which IS the program's room.
    if "mockup" not in prompt.lower():
        sys.stderr.write("HANDOFF RIG: an unexpected worker was spawned.\n")
        sys.exit(1)
    import os
    with open(os.path.join(os.getcwd(), "mockup.html"), "w") as fh:
        fh.write("<!doctype html>\n"
                 "<!-- VISUAL REFERENCE ONLY - rig fixture, turn 2. -->\n"
                 "<html><body><div class='bar' "
                 "style='justify-content:flex-end'>Maps Objects</div>"
                 "</body></html>\n")
    sys.stdout.write("Moved the toolbar buttons to the right edge.\n")
    sys.exit(0)
# THE ANCHOR IS THE PROMPT'S OWN CLAIM, and it is deliberately TWO of them.
# The first shape of this guard read "LOOK AND FLOW ONLY", which S171 reworded
# when the pass was widened to cover behaviour — so the rig refused the real
# derivation prompt and the run failed saying "the pass never wrote its change
# list", accusing the product for the rig's own stale string. It went red
# honestly, which is what the guard is for; the anchor is now on the two
# sentences the pass exists to carry, so a REAL loss of either is still caught.
if "NEVER REPORT IMPLEMENTATION" not in prompt or "WIRED TO" not in prompt:
    sys.stderr.write("HANDOFF RIG: the derivation prompt does not carry its "
                     "own contract (the implementation ban, or what a thing "
                     "is wired to). Re-point this guard or fix the prompt.\n")
    sys.exit(1)
# THE WAIT IS REAL. The live pass is 154-220s; this is the same shape, short
# enough for a rig and long enough that the running band is a thing a browser
# can be pointed at.
time.sleep(${DERIVE_SLEEP})
if ${MUTE}:
    # THE PASS THAT DID NOT ANSWER. It ran, it took as long as a real one, and
    # it wrote no change marker - so the daemon reports ok: false and the deck
    # goes to its failed gate. Nothing here fakes the daemon's state.
    sys.stdout.write("I got partway through and lost my thread.\n")
    sys.exit(0)
sys.stdout.write("I read the toolbar, the mode switcher and the map tabs.\n")
sys.stdout.write("=== ASK ===\n")
sys.stdout.write("- the mockup draws zoom / fit buttons over the canvas - in "
                 "or out?\n")
sys.stdout.write("=== CHANGES ===\n")
sys.stdout.write("- today the toolbar is 48px tall -> the mockup grows it to "
                 "52px\n")
sys.stdout.write("- ${CHANGE_MARK} -> the mockup merges them into one 42px "
                 "row with pill map tabs\n")
sys.stdout.write("- today there is no theme control and the app is dark-only "
                 "-> the mockup adds a sun/moon toggle and a light theme\n")
PYW
  chmod +x "$1"
}

write_expect 1440 677 9 reload

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
  # the scripted check worker (see above) — a python script, never an engine.
  local cw="$out/check-worker"
  write_check_worker "$cw"
  LCARS_BROWSER_OUT="$out" \
  LCARS_BROWSER_WEB_DIR="$web" \
  LCARS_BROWSER_HANDOFF_CHECK="$WORK/expect.json" \
  LCARS_BROWSER_WORKER_BIN="$cw" \
  LCARS_HOLODECK_ROOT="$root" \
    bash "$HERE/smoke.sh"
  return $?
}

# EVERY INLINE PATCH BELOW ASSERTS ITS OWN ANCHOR, AND THAT ASSERTION IS NOW
# LOAD-BEARING. It used to run in a python process whose exit status nothing
# read: a control whose anchor a fix round had rewritten copied `web/`
# UNMODIFIED, ran the real product, passed, and was reported as "THE CHECK
# CANNOT SEE THIS" — an accusation against the product for a control that was
# never applied. Measured here twice in one session. `patch_or_die` makes a
# dead anchor an INFRASTRUCTURE failure, which is what it is.
patch_or_die() {   # $1 = file to patch; the patch script arrives on stdin
  if ! "${LCARS_PYTHON_BIN:-python3}" - "$1"; then
    printf '\033[31m  ✗ THE RED CONTROL COULD NOT BE APPLIED\033[0m — its anchor is\n'
    printf '    gone from %s. The control is measuring NOTHING; re-point it.\n' "$1"
    return 1
  fi
  return 0
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


def _handoff_parts(concept_text, changes=(), asks=()):   # RED CONTROL — S128
    return _handoff_requirements(concept_text), [], [], []
PY
      ;;
    derive-not-durable)
      # S170's OWN CONTROL, and the captain's own question asked mid-session:
      # "If the daemon closes by accident while I walk away are we still good?"
      # Delete the persistence and the answer is no — the in-memory cache dies
      # with the process and he pays the 154-220s wait a second time.
      patch_or_die "$py" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = "        self._handoff_derive_write(sess.program_dir, fp, result)"
assert old in s, "the persistence call moved - this control measures nothing"
s = s.replace(old, "        pass  # red control: nothing is persisted", 1)
old2 = "        disk = self._handoff_derive_read(sess.program_dir, fp)"
assert old2 in s, "the persistence read moved - this control measures nothing"
s = s.replace(old2, "        disk = None  # red control: nothing is read back", 1)
open(p, "w").write(s)
PY
      ;;
    band-hides-the-wait)
      # THE WAIT, MADE SILENT. The running band drops the one sentence the
      # whole stage exists to deliver — that he may close this and walk away —
      # and becomes S169's spinner again: a progress note that tells a captain
      # nothing about whether it is safe to leave.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
mark = '"\u29d7 Working out what the mockup changes about your project"'
assert mark in s, "the running copy moved - this control is measuring nothing"
i = s.index(mark)
j = s.index("));", i)
open(p, "w").write(s[:i] + '"Reading these lines back against the mockup..."'
                  + s[j:])
PY
      ;;
    brief-clobbers-his-edits)
      # FL-013, ONE DIALOG OVER. The derivation lands while he is typing and
      # the redraft overwrites what he wrote. NEVER OVERWRITE WHAT A HUMAN
      # TYPED is the rule; this control removes the test that enforces it.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = "  function briefIsPristine() { return brief.value === seed.brief; }"
assert old in s, "the pristine test moved - this control is measuring nothing"
open(p, "w").write(s.replace(
    old, "  function briefIsPristine() { return true; }", 1))
PY
      ;;
    no-fit)
      # S169 FIX ROUND 1'S OWN CONTROL, and the tester's exact defect. The
      # sizing pass is deleted, so the box falls back to its `rows` attribute —
      # which counts SOURCE lines while the draft's lines wrap three and four
      # ways — and two thirds of his brief goes back behind an inner scrollbar
      # inside a modal body that is itself scrolling. MEASURED before the cure:
      # a 269px box over 817px of content at 1440x677.
      patch_or_die "$js" <<'PY' || return 1
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
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
# NEUTERED AT THE SOURCE, not at one call site. The hint is composed once when
# the dialog opens AND recomposed when the derivation lands (`rehint`), so a
# control that only patched the first would be measuring nothing after the
# pass answered — which is precisely how the previous version of this control
# went silently GREEN.
old = '  return "In this brief: "'
assert old in s, "the hint wording moved - this control is measuring nothing"
new = ('  return "Rewrite this however you like."; // red control\n'
       '  return "In this brief: "')
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
    capped-guidance)
      # S169 FIX ROUND 2's OWN CONTROL, and the capstone's exact defect: the
      # height cap put back on the block that carries the PRECEDENCE RULE.
      # MEASURED before the cure: clientHeight 228 against scrollHeight 729 —
      # 69% of the paragraph that tells every stage the mockup wins on look,
      # behind an inner scrollbar nobody notices, inside a body that already
      # scrolls. Fix round 1 cured the textarea and walked past this box.
      printf '\n.handoff-guidance{max-height:230px;overflow-y:auto}\n' >>"$css"
      ;;
    hide-derive)
      # THE BAND, DELIVERED AND INVISIBLE. The daemon runs the pass, the band
      # is built, the state is in the DOM — and it paints nowhere. That is D1
      # one level down, and it is the shape every "we added a warning" round in
      # this project has shipped at least once.
      printf '\n.field .handoff-derive{display:none}\n' >>"$css"
      ;;
    derive-never-asks)
      # THE SPINNER THAT NEVER RESOLVES. The daemon answers the dialog
      # immediately with "running" — a hand-off held up by a verification step
      # is worse than the defect — and the band is supposed to come back for
      # the verdict. Delete the poll and it sits on "Reading these lines back
      # against the mockup…" for as long as he looks at it while the answer
      # waits unread. THIS IS A REAL BUG THIS ROUND SHIPPED AND FIXED: the poll
      # was started where the band is built, which is BEFORE `showOverlay` puts
      # the dialog in the document, so its own "is this still on the page?"
      # guard was false on the very first call.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if ((seed.derive || {}).state === "running") {
    holoDerivePoll(seed, checkBox, picked, 1, briefLanded);
  }'''
assert old in s, "the poll moved — this control is measuring nothing"
open(p, "w").write(s.replace(old, "  /* red control: never asks again */", 1))
PY
      ;;
    hint-overclaims)
      # THE LINE THAT ASSERTED A COMPARISON NOBODY MADE, put back verbatim.
      # "18 changes the mockup makes to today's app" — the daemon has never
      # opened the captain's repository; it counted the bullets of a section a
      # model wrote from the conversation. Fix round 1 corrected the caption
      # INSIDE the box and left this line four inches above it saying the same
      # thing.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    parts.push(holoCount(d, "change read off your project",
                         "changes read off your project"));'''
assert old in s, "the hint wording moved — this control is measuring nothing"
new = '''    parts.push(holoCount(d, "change the design chat recorded",
                         "changes the design chat recorded"));'''
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    cue-cries-wolf)
      # THE AMBER ALARM PUT BACK. `⚠ N OPEN QUESTIONS UNANSWERED — READ THEM
      # FIRST`, beside ▦ FILE MISSION, fired at EVERY open, before the captain
      # had had one second to answer anything — and on the capstone it was
      # FALSE: both questions were settled in their own text, and one was then
      # re-asked at a real human gate. A warning that is always on is not a
      # warning; it trains him to click past the strip where a real finding
      # appears.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]
s = open(p).read()
mark = '"\u25b8 " + open + " open question" + (open === 1 ? "" : "s")'
assert mark in s, "the cue wording moved — this control is measuring nothing"
bad = '"\u26a0 " + open + " open question" + (open === 1 ? "" : "s") + " unanswered"'
open(p, "w").write(s.replace(mark, bad, 1))
PY
      ;;
    # ══ S171 ══════════════════════════════════════════════════════════════
    timeline-is-back)
      # THE DEFECT THIS SESSION EXISTS TO END, reinstated in the DAEMON. The
      # brief regrows the numbered, turn-attributed "in your own words" list —
      # the raw chat feed the captain deleted by hand before sending, twice.
      # The front end is untouched and perfect; a node harness cannot see it.
      cat >>"$py" <<'PY'


_HANDOFF_REQ_TITLE = "## What it must do — in your own words"   # RED CONTROL


def _handoff_brief(concept_text, program="", changes=(), asks=()):  # RED
    reqs, changed, implied, scope = _handoff_parts(concept_text, changes,
                                                   asks)
    head = "\n".join([_HANDOFF_REQ_TITLE, ""]
                     + ["%d. %s" % (i + 1, r) for i, r in enumerate(reqs)])
    blocks = [b for b in (
        head,
        _handoff_section(_HANDOFF_CHANGE_TITLE, _HANDOFF_CHANGE_NOTE, changed),
        _handoff_section(_HANDOFF_IMPLIED_TITLE, _HANDOFF_IMPLIED_NOTE,
                         implied),
        _handoff_section(_HANDOFF_SCOPE_TITLE, _HANDOFF_SCOPE_NOTE,
                         scope)) if b]
    return _handoff_titled("\n\n".join(blocks), program)
PY
      ;;
    gate-does-not-gate)
      # ▶ SEND TO ALIGN LIVE WHILE THE PASS RUNS — the captain's own report:
      # *"I could have clicked send to align before it was done and it wasn't
      # clear."* The bar still says `running` and still shows the bars; only
      # the disabling goes, which is precisely the shape a screenshot passes.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = '  } else if (gate === "running") {\n    /* DISABLED BECAUSE THE DAEMON SAYS'
assert old in s, "the gate's running branch moved - this control measures nothing"
new = '  } else if (false) {   /* RED CONTROL: the wait no longer disables */\n    /* DISABLED BECAUSE THE DAEMON SAYS'
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    gate-has-no-spinner)
      # "Generating…" WITH NOTHING MOVING BESIDE IT. The label is right, the
      # button is properly disabled, and there is no evidence anything is
      # happening — which is the state a captain reads as "stuck".
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = "    bar.appendChild(holoWorkingBars());"
assert old in s, "the gate's loading indicator moved - this control measures nothing"
open(p, "w").write(s.replace(old, "    /* RED CONTROL: no indicator */", 1))
PY
      ;;
    hatch-is-back)
      # == S172: THE CONTROL IS INVERTED, BECAUSE THE PRODUCT WAS ===========
      # This was `no-escape-hatch`: it DELETED `Send without the change list`
      # and required the rig to notice. The captain has now deleted it for
      # real — *"we don't need the send without change list one"* — so the
      # claim is the other way round and so is the control: PUT IT BACK, and
      # the rig must catch it on every gated state.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = '  if (gate === "failed") {'
assert old in s, "the hand-off bar's failed branch moved - this control measures nothing"
new = ('  if (p.handoffReady && (gate === "none" || gate === "running"\n'
       '                         || gate === "failed")) {          // RED\n'
       '    var skip = holoBtn("Send without the change list", "small",\n'
       '                       function () { holoPromote(p.sessionId); });\n'
       '    skip.setAttribute("data-holo", "handoff-skip");\n'
       '    bar.appendChild(applyWriteState(skip));\n'
       '  }\n' + old)
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    mismatched-bar)
      # THE CAPTAIN'S SCREENSHOT, REPRODUCED. The secondary control goes back
      # to the small outlined pill it was, beside a full-size filled primary —
      # two weights of control on one row. Broken in BOTH places it was fixed
      # (the class on the button and the CSS rule that sized it), because
      # either one alone leaves the other still making the bar look right.
      patch_or_die "$js" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = 'holoBtn("\u21bb Try the change list again", "big"'
assert old in s, "the retry control moved - this control is measuring nothing"
new = 'holoBtn("\u21bb Try the change list again", "small"'
open(p, "w").write(s.replace(old, new, 1))
PY
      printf '\n.holo-handoff .btn.small{font-size:9px;letter-spacing:.1em;padding:4px 10px;border-radius:9px}\n' >>"$css"
      ;;
    questions-dropped-on-the-floor)
      # == S172, ITEM 1 - THE BIG ONE =======================================
      # THE DEFECT AS IT WAS: the pass finds a real difference, decides not to
      # report it because the captain's own out-of-scope ruling makes it
      # ambiguous, and DROPS IT — nobody downstream can see a line that was
      # never written. This control puts that behaviour back in the DAEMON:
      # the reply's declared questions are parsed and then thrown away, so
      # bucket 2 loses them. The front end is untouched and perfect; a node
      # harness cannot see it.
      cat >>"$py" <<'PY'


def _handoff_derive_asks(reply):    # RED CONTROL: found, and dropped
    return []
PY
      ;;
    no-wait-guard)
      # THE STALE LIST. A further composer turn no longer invalidates, so he
      # sends a change list derived from a mockup he has since redrawn. Broken
      # in the DAEMON, at the FINGERPRINT, which is where the invalidation
      # actually lives — a client-side flag would be the wrong thing to break.
      patch_or_die "$py" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old = "        parts = [os.path.abspath(target_repo or \"\")]"
assert old in s, "the fingerprint moved - this control measures nothing"
new = ("        return hashlib.sha1(str(program_dir).encode(\"utf-8\")"
       ").hexdigest()   # RED CONTROL: the files stop counting\n" + old)
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    *) return 1 ;;
  esac
  return 0
}

VARIANTS="${LCARS_HANDOFF_VARIANTS:-no-change-list no-fit capped-box mute-hint clip-box no-sticky-foot hint-below-box brief-below-fold capped-guidance hide-derive derive-never-asks hint-overclaims cue-cries-wolf band-hides-the-wait brief-clobbers-his-edits timeline-is-back gate-does-not-gate gate-has-no-spinner hatch-is-back mismatched-bar questions-dropped-on-the-floor no-wait-guard}"

# DELIBERATELY NOT IN THAT LIST: `derive-not-durable`. It breaks the persisted
# record in the program room — the cure for "the daemon closed while I walked
# away" — and THIS RIG CANNOT SEE IT. A page reload throws away client state,
# not the daemon, so the in-memory cache still answers on the second open and
# the variant comes back GREEN. A control that cannot go red is the thing this
# rig has three times printed reassuring output about, so it is not run here.
# The variant is kept below because it is the right shape once something CAN
# kill the daemon; durability is proven instead by the real kill -9 drive and
# by S170DeriveSurvivesTheDaemonTest.

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
    capped-guidance)   echo "the guidance block hides" ;;
    hide-derive)       echo "not on the screen" ;;
    derive-never-asks) echo "never settled" ;;
    hint-overclaims)   echo "CLAIMS" ;;
    cue-cries-wolf)    echo "reads as a WARNING" ;;
    band-hides-the-wait)     echo "never says" ;;
    brief-clobbers-his-edits) echo "was DESTROYED by the redraft" ;;
    timeline-is-back)  echo "THE BRIEF IS A TIMELINE AGAIN" ;;
    gate-does-not-gate) echo "was NOT disabled while the pass ran" ;;
    gate-has-no-spinner) echo "no loading indicator" ;;
    hatch-is-back)     echo "ESCAPE HATCH IS BACK ON THE BAR" ;;
    mismatched-bar)    echo "CONTROLS ARE MISMATCHED" ;;
    questions-dropped-on-the-floor) echo "DECLARED QUESTION" ;;
    no-wait-guard)     echo "DID NOT INVALIDATE THE CHANGE LIST" ;;
  esac
}

run_product() {
  local rc=0 worst=0 dir
  # 1440x677 — S128's window. 1280x613 — the tester's short one (fix round 1),
  # where the footer band is at its most expensive and the line above the box
  # has the least room. Both must pass; the second is not a bonus.
  # THREE RUNS. 1440x677 is S128's window; 1280x613 is the tester's short one
  # (fix round 1), where the footer band is at its most expensive and the line
  # above the box has the least room. The third is the SAME window with him
  # TYPING while the pass runs — a different claim, and one a reload erases.
  # …and a FOURTH (S171): the gate's wait guard. He gets his change list, then
  # keeps chatting — and the list must fall back to "generate one".
  # …and a FIFTH (S172): the pass DID NOT ANSWER. With `Send without the change
  # list` deleted, ▶ SEND TO ALIGN is the only road off a dead engine — and it
  # is the pairing whose two controls the captain photographed mismatched.
  for pass in "1440 677 9 product reload" "1280 613 6 product-short reload" \
              "1440 677 9 product-typed typed" \
              "1440 677 9 product-turn turn" \
              "1440 677 9 product-failed failed"; do
    set -- $pass
    write_expect "$1" "$2" "$3" "$5"
    # THE MUTE IS BAKED INTO THE WORKER AT GENERATION TIME (`run_once` writes
    # it fresh per pass), so the failing pass is a REAL subprocess that runs,
    # waits and answers with no marker — the daemon's own "it did not answer"
    # road, not a state poked into the daemon from outside.
    if [ "$5" = failed ]; then MUTE=1; else MUTE=0; fi
    dir="$WORK/$4"
    run_once "PRODUCT — this repo's web/, unmodified · ${1}x${2} · $5" \
             "$REPO/web" "$dir"
    rc=$?
    case "$rc" in
      0) printf '\n\033[32m✓ THE SEND-TO-ALIGN BOX MEASURED UP AT %sx%s (%s).\033[0m\n' "$1" "$2" "$5"
         printf '  Now open it: %s/handoff.png\n\n' "$dir" ;;
      77) return 77 ;;
      *) printf '\n\033[31m✗ THE HAND-OFF DIALOG IS WRONG AT %sx%s (%s).\033[0m See above and\n' "$1" "$2" "$5"
         printf '  %s/handoff-check.json\n\n' "$dir"
         worst=1 ;;
    esac
  done
  # PUT THE WORKER BACK. `--all` runs the calibration after this loop, and the
  # loop's last pass leaves the pass MUTED — every red control would then be
  # measured against a derivation that never answers, which is a rig grading
  # itself. (This file has printed "every control went red" over eleven runs
  # that had failed on the harness's own error line; not again.)
  MUTE=0
  write_expect 1440 677 9 typed
  return $worst
}

run_calibrate() {
  local bad=0
  for v in $VARIANTS; do
    local dest="$WORK/variant-$v/web" out="$WORK/variant-$v/run"
    mkdir -p "$WORK/variant-$v"
    # THE EXPECTATION HAS TO MATCH THE CLAIM THE CONTROL BREAKS. S171's wait
    # guard only exists on the run that KEEPS CHATTING after the list lands, so
    # calibrating it against the default expectation asked a question the run
    # never reaches — and the control came back GREEN while the product was
    # genuinely broken. That is the "reassuring output proving nothing" shape
    # this rig keeps a note about; it is now selected per variant.
    #
    # S172 — AND `mismatched-bar` ONLY EXISTS ON THE FAILED GATE. The pairing
    # the captain photographed (▶ SEND TO ALIGN beside ↻ try again) is drawn on
    # exactly one state, so calibrating it against the default run would ask a
    # question the walk never reaches — the same trap `no-wait-guard` fell into.
    # MUTE is what puts the pass into that state; it is reset afterwards or
    # every later control would be graded against a derivation that never
    # answers.
    MUTE=0
    #
    # ── S172 FOUND A THIRD ONE, AND IT WAS INHERITED ────────────────────────
    # `brief-clobbers-his-edits` breaks `briefIsPristine`, and the ONLY judge
    # that reads that is `expectBriefKeeps` — which is empty on every mode but
    # `typed`. So it was calibrated on a run that never types, asked a question
    # the run cannot reach, and came back GREEN. Verified against HEAD before
    # it was moved: the selector below has never carried it, so it has been
    # reported as a verified red control while measuring NOTHING. That is the
    # sixth time this rig has produced that shape and the reason `patch_or_die`
    # and this selector both exist.
    case "$v" in
      no-wait-guard)  write_expect 1440 677 9 turn ;;
      mismatched-bar) write_expect 1440 677 9 failed; MUTE=1 ;;
      brief-clobbers-his-edits) write_expect 1440 677 9 typed ;;
      *)              write_expect 1440 677 9 reload ;;
    esac
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
