#!/usr/bin/env bash
# ============================================================================
# S201 — NUMBER ONE'S BADGE, MEASURED IN PIXELS.
#
#   bash tests/drives/s201/xo-paint.sh
#   LCARS_BROWSER_HEADED=1 bash tests/drives/s201/xo-paint.sh   # watch it
#
# THIS IS S190'S RIG, NOT A SECOND ONE. `tests/drives/s190/owner-paint.sh`
# already boots a real daemon on a planted fixture, a real Chrome with its own
# throwaway profile and a free devtools port, and tears both down by recorded
# pid. Forking 700 lines of that to ask two more questions would have produced
# a second rig to keep in step with the first — the exact duplication this
# project has paid for before.
#
# So S190's rig grew TWO SEAMS and this file sets them:
#
#   LCARS_PAINT_PLANT   an extra planter, run AFTER its own, handed the same
#                       (repo, fixture-root). Ours engages Number One on the
#                       mission that is already there and turns the repo toggle
#                       on. It ADDS a fact; it replaces nothing.
#   LCARS_PAINT_DRIVER  which node driver asks the questions. Ours REQUIRES
#                       S190's for the CDP client, the PNG reader and the
#                       contrast formula, so there is one implementation of
#                       "what does this pixel actually say".
#
# WHAT IT PROVES:
#   • the engaged pill reads ≥ 4.5:1 on the card — off the SCREENSHOT, not off
#     getComputedStyle (S190's D2: a compositing group lies to the cascade);
#   • with the page DESATURATED in real Chrome, the peach pill is still
#     distinguishable from the amber owner pill beside it — by FILL and value,
#     never by hue, which is the axis a projector and a colourblind reader keep;
#   • the greyscale filter actually BIT (r == g == b), because a greyscale
#     check that ran in colour would pass on the broken version;
#   • the captain's vocabulary, on the real page: the pill's exact words, no
#     "fixing", no pricing word, the peach edge on the engaged card only, the
#     band toggle reading ON with the engine, two legend entries;
#   • the sweep: every write control on the engaged card locked, ■ Stand down
#     present and LIVE.
#
# ZERO SPEND — inherited whole: `claude`, `copilot` and `gh` on PATH are logging
# shims that exit 1, the identity is pinned with $LCARS_GH_USER, and the owners
# are planted on disk. No engine binary is ever invoked.
#
# EXIT: 0 proven · 1 the product is wrong · 77 skipped / infrastructure.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LCARS_PAINT_PLANT="$HERE/plant-xo.py"
export LCARS_PAINT_DRIVER="$HERE/xo-paint.js"
# Keep this round's frames in this round's work dir, so a failed S190 run and a
# failed S201 run never overwrite each other's evidence.
export LCARS_S190_PAINT_OUT="${LCARS_S201_PAINT_OUT:-${TMPDIR:-/tmp}/lcars-s201-paint}"

bash "$HERE/../s190/owner-paint.sh" "$@"
RC=$?

# THE DELIVERABLE. The shots the walkthrough is built from live under this
# round's own folder, where the next session can find them without knowing what
# $TMPDIR was that day.
if [ "$RC" -eq 0 ]; then
  SHOTS="$HERE/shots"
  mkdir -p "$SHOTS"
  for f in xo-board.png xo-engaged-card.png xo-finished-card.png \
           xo-engaged-grey.png xo-pill.png xo-pill-grey.png \
           xo-pill-finished-grey.png xo-owner-grey.png; do
    [ -f "$LCARS_S190_PAINT_OUT/product/$f" ] \
      && cp "$LCARS_S190_PAINT_OUT/product/$f" "$SHOTS/$f"
  done
  printf 'shots:     %s\n' "$SHOTS"
fi
exit "$RC"
