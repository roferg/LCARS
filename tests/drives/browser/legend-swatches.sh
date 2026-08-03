#!/usr/bin/env bash
# ============================================================================
# S168 — THE BOARD'S LEGEND SWATCHES, IN A REAL BROWSER.
#
#   bash tests/drives/browser/legend-swatches.sh              # the product
#   bash tests/drives/browser/legend-swatches.sh --calibrate  # the RED CONTROLS
#   bash tests/drives/browser/legend-swatches.sh --all        # both
#
# WHAT IS BEING PROVEN. The board's bottom legend explains its colour language:
# a red chip for "Awaiting you", a pink one for "Child bug mission", a teal one
# for "Ticket green". Measured in Chrome on 2026-08-02, the PINK CHIP WAS NOT
# THERE — the label sat beside empty space. `index.html` declared it
# `background:var(--lcars-pink)` with no fallback, and `--lcars-pink` is defined
# by no stylesheet in this repo, so the declaration was invalid at computed-value
# time and the background fell back to `transparent`.
#
# WHY A BROWSER AND NOT A UNIT TEST — and why this bug in particular is the
# purest possible example. `.legend i` is sized by board.css (12×12) and coloured
# inline, so the broken chip had:
#
#   • the element, in the DOM                       ✓ (any harness sees this)
#   • the right class and the right style attribute ✓ (any harness sees this)
#   • a perfect, laid-out, non-zero bounding box    ✓ (even a paint check sees this)
#   • and no paint whatsoever                       ✗ (ONLY the resolved colour)
#
# There is no assertion about markup, attributes or CSS rules that can go red on
# this. S162 shipped a warning styled as muted metadata with a rule-exists test
# green beside it; S163 shipped a blank board past 1,162 node-DOM tests. So every
# claim here is read off the LIVE element: the box, the RESOLVED background
# colour with its alpha, and that colour composited against the surface actually
# painted behind it.
#
# THE RED CONTROLS are the point of --calibrate. A check that cannot go red is
# decoration. Four variants patch a COPY of web/ and each must make the check
# fail: the chip REMOVED, the chip's fallback REVERTED (the S168 bug verbatim),
# the chip painted the SAME COLOUR as its backdrop, and the chip painted the
# WRONG COLOUR. The last two exist because the first two fail early, and an
# assertion no control ever exercises is one nobody has shown can fire. This
# repo's own web/ is never touched.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"

WORK="${LCARS_BROWSER_LEGEND_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-legend.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-legend.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-legend.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# The expectation. All THREE chips, not just the broken one: the two healthy
# neighbours are the in-run positive control that says the measurement itself
# works, so "the pink one failed" cannot be dismissed as the rig misreading.
# `hue` is decided on the resolved rgb ordering, never on a declared string.
cat >"$WORK/expect.json" <<'JSON'
{ "swatches": [
    { "label": "Awaiting you",      "hue": "red"  },
    { "label": "Child bug mission", "hue": "pink" },
    { "label": "Ticket green",      "hue": "teal" }
  ],
  "minContrast": 1.25 }
JSON

run_against() {   # $1 = web dir, $2 = run name → sets RC, LOG
  LOG="$WORK/$2.log"
  LCARS_BROWSER_WEB_DIR="$1" \
  LCARS_BROWSER_OUT="$WORK/$2" \
  LCARS_BROWSER_LEGEND_CHECK="$WORK/expect.json" \
    bash "$HERE/smoke.sh" >"$LOG" 2>&1
  RC=$?
}

# ── the product ─────────────────────────────────────────────────────────────
product_run() {
  say "S168 — the board's legend swatches, in real Chrome"
  note "artifacts: $WORK"
  run_against "$REPO/web" product
  case "$RC" in
    0)
      printf '\n\033[32mPROVEN\033[0m — every legend chip really paints on the screen.\n'
      sed -n '/legend: every named swatch/,/^  page errors/p' "$LOG" | grep -v '^  page errors' | sed 's/^/  /'
      printf '  screenshot: %s/product/legend.png  — OPEN IT AND LOOK.\n' "$WORK"
      printf '  measurements: %s/product/legend-check.json\n' "$WORK"
      return 0 ;;
    77)
      printf '\n\033[33mSKIPPED\033[0m — infrastructure, nothing proven.\n'
      sed -n '1,25p' "$LOG"
      return 77 ;;
    3)
      printf '\n\033[31mINCONCLUSIVE\033[0m — the app was served WITHOUT its stylesheet, so any\n'
      printf '  colour read off that page is a phantom.\n'
      sed -n '1,40p' "$LOG"
      return 1 ;;
    *)
      printf '\n\033[31mFAILED\033[0m — a legend chip is not on the screen.\n'
      grep -E '✗|A LEGEND SWATCH|tokens on :root|THE BOARD DID NOT PAINT' "$LOG" | sed 's/^/  /'
      printf '  full log:   %s\n' "$LOG"
      printf '  screenshot: %s/product/legend.png\n' "$WORK"
      return 1 ;;
  esac
}

# ── the red controls ────────────────────────────────────────────────────────
# A patch that did not apply is a RIG fault and exits 77: a control that quietly
# tested the healthy product would be the most flattering possible lie.
make_copy() {   # $1 = name → echoes the web dir
  local dst="$WORK/web-$1"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$dst/"
  rm -rf "$dst/lcars_serve/__pycache__"
  printf '%s' "$dst"
}

PINK_I='<i style="background:var(--lcars-pink,#ff66aa)"></i>'

patch_removed() {   # the chip itself is gone; the label sits alone
  local h="$1/static/index.html"
  grep -qF "$PINK_I" "$h" || return 1
  /usr/bin/sed -i '' "s|$PINK_I||" "$h"
  ! grep -qF "$PINK_I" "$h"
}

patch_unresolved() {  # THE S168 BUG, VERBATIM: the fallback taken back off
  local h="$1/static/index.html"
  grep -qF "$PINK_I" "$h" || return 1
  /usr/bin/sed -i '' 's|background:var(--lcars-pink,#ff66aa)|background:var(--lcars-pink)|' "$h"
  grep -qF '<i style="background:var(--lcars-pink)"></i>' "$h"
}

# The two above make the chip ABSENT or UNPAINTED, and so never exercise the
# contrast or hue assertions. These two leave a perfectly opaque chip exactly
# where it belongs and make it useless anyway — the failure modes a box check
# and an alpha check are both blind to.
patch_camouflaged() {  # opaque, and the same colour as the surface behind it
  local css="$1/static/board.css"
  grep -q '^\.legend i{' "$css" || return 1
  # Repaints the LEGEND'S OWN surface in the pink chip's colour rather than
  # touching the chip: the chip's colour is an INLINE style and no selector can
  # outrank that. Which makes this control usefully targeted — the pink chip
  # vanishes into its backdrop while its red and teal neighbours stay perfectly
  # visible, so the run proves the contrast assertion fires on ONE named chip
  # and not merely on a legend that has been wrecked wholesale.
  cat >>"$css" <<'CSS'
/* red control (legend-swatches.sh): the pink chip is opaque and identical to
   the surface behind it — painted, and invisible to a reader all the same. */
.legend{background:#ff66aa}
CSS
  grep -q '^\.legend{background:#ff66aa}$' "$css"
}

patch_wrong_hue() {   # it paints, brightly, in the WRONG colour
  local h="$1/static/index.html"
  grep -qF "$PINK_I" "$h" || return 1
  /usr/bin/sed -i '' 's|background:var(--lcars-pink,#ff66aa)|background:var(--lcars-red,#ff3344)|' "$h"
  ! grep -qF "$PINK_I" "$h"
}

control_run() {   # $1 = name, $2 = patch fn, $3 = description
  local dir; dir="$(make_copy "$1")"
  if ! "$2" "$dir"; then
    printf '\n\033[33mCONTROL CANNOT RUN\033[0m — the "%s" patch did not apply to the copy.\n' "$1"
    printf '  the legend markup has been restructured; update %s.\n' "$0"
    return 77
  fi
  note "control '$1': $3"
  run_against "$dir" "control-$1"
  case "$RC" in
    1)
      printf '  \033[32m→ went RED, correctly\033[0m\n'
      grep -E '✗' "$LOG" | head -3 | sed 's/^/      /'
      return 0 ;;
    0)
      printf '  \033[31m→ PASSED a broken legend. The check is decoration.\033[0m\n'
      sed -n '1,30p' "$LOG"
      return 1 ;;
    77)
      printf '  \033[33m→ skipped (infrastructure) — nothing proven\033[0m\n'
      return 77 ;;
    *)
      printf '  \033[31m→ exited %s — red for the WRONG REASON (3 = served without its\n' "$RC"
      printf '     stylesheet), so the control is inconclusive.\033[0m\n'
      sed -n '1,30p' "$LOG"
      return 1 ;;
  esac
}

calibrate_run() {
  say "RED CONTROLS — can this check actually go red?"
  note "artifacts: $WORK"
  local rc=0 r
  control_run removed patch_removed \
    "the pink chip is deleted; the label sits beside nothing"; r=$?
  [ "$r" -ne 0 ] && rc=$r
  control_run unresolved patch_unresolved \
    "the S168 bug verbatim — var(--lcars-pink) with its fallback taken back off"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run camouflaged patch_camouflaged \
    "the chip is opaque, and exactly the colour of the surface behind it"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run wrong-hue patch_wrong_hue \
    "the chip paints brightly, in the wrong colour — red where pink is meant"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  printf '\n'
  case "$rc" in
    0) printf '\033[32mCONTROLS PASSED\033[0m — the check goes red when the chip is missing, when\n'
       printf '  its var() does not resolve, when it is camouflaged against its own\n'
       printf '  backdrop, and when it paints the wrong colour. It is not decoration.\n' ;;
    77) printf '\033[33mCONTROLS SKIPPED\033[0m — nothing proven.\n' ;;
    *) printf '\033[31mCONTROLS FAILED\033[0m — see above.\n' ;;
  esac
  return $rc
}

case "$MODE" in
  product)    product_run; exit $? ;;
  --calibrate|calibrate) calibrate_run; exit $? ;;
  --all|all)
    product_run; P=$?
    printf '\n'
    calibrate_run; C=$?
    [ "$P" -eq 0 ] && [ "$C" -eq 0 ] && exit 0
    [ "$P" -eq 77 ] || [ "$C" -eq 77 ] && exit 77
    exit 1 ;;
  *) printf 'usage: %s [--calibrate|--all]\n' "$0"; exit 2 ;;
esac
