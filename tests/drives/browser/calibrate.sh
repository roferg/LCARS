#!/usr/bin/env bash
# ============================================================================
# CALIBRATION — prove the smoke rig can still go RED.
#
#   bash tests/drives/browser/calibrate.sh
#
# A green check that cannot go red is decoration. S163's blank board survived
# 1,162 passing tests and six tester rounds; S162 shipped a warning styled
# invisible while a test asserting the CSS rule existed stayed green. So this
# rig does not get to CLAIM it would catch a blank board — it demonstrates it,
# on demand, against the exact defect that started all this.
#
# It copies web/ to a scratch dir, deletes the `.then(render)` line from the
# COPY's board.js (S163 fix round 5's mistake, verbatim: the line went along
# with a comment someone was writing beside it), and runs the rig against that
# copy. The rig must FAIL. This repo's own web/ is never touched.
#
# EXIT: 0 the rig correctly went red (calibration PASSED)
#       1 the rig passed a broken board, or went red for the WRONG REASON — a
#         rig exit of 3 (app served without its stylesheet) is INCONCLUSIVE, not
#         a pass: it never got to demonstrate it can see the cut render chain.
#       77 skipped (no Chrome / infrastructure) — never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

# Kept on purpose (the red run's screenshot is the evidence), but BOUNDED — the
# three newest calibrations survive, older ones are pruned so /var/folders does
# not silently accumulate them. Only this script's own mktemp pattern is touched.
if [ -z "${LCARS_BROWSER_CALIB_OUT:-}" ]; then
  n=0                                # 2 older + the one minted below = 3 kept
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-calib.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-calib.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
fi
WORK="${LCARS_BROWSER_CALIB_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-calib.XXXXXX")}"
mkdir -p "$WORK"
printf '\033[1mCALIBRATION — can the rig see a blank board?\033[0m\n'
printf 'calibration artifacts: %s\n' "$WORK"

# 1. a private copy of the shipping web app.
BROKEN_WEB="$WORK/web-broken"
mkdir -p "$BROKEN_WEB"
cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$BROKEN_WEB/"
rm -rf "$BROKEN_WEB/lcars_serve/__pycache__"

# 2. cut the exact line round 5 cut. Nothing else changes — the .catch and its
#    comment stay, which is what made the original so easy to miss in review.
BJS="$BROKEN_WEB/static/board.js"
BEFORE=$(grep -c '^\s*\.then(render)$' "$BJS")
if [ "$BEFORE" -ne 1 ]; then
  printf '\033[31mCALIBRATION CANNOT RUN\033[0m — expected exactly one `.then(render)` line in\n'
  printf '  web/static/board.js, found %s. The refresh() chain has been restructured;\n' "$BEFORE"
  printf '  update this script to cut whatever now carries payload → render.\n'
  exit 1
fi
grep -v '^\s*\.then(render)$' "$BJS" >"$BJS.cut" && mv "$BJS.cut" "$BJS"
printf '  removed `.then(render)` from the copy at %s\n' "$BJS"

# 3. the rig, against the broken copy. It must NOT pass.
LCARS_BROWSER_WEB_DIR="$BROKEN_WEB" LCARS_BROWSER_OUT="$WORK/run" \
  bash "$HERE/smoke.sh" >"$WORK/run.log" 2>&1
RC=$?

printf '\n'
case "$RC" in
  0)
    printf '\033[31mCALIBRATION FAILED\033[0m — the rig reported PAINTED on a board whose\n'
    printf '  fetch→render chain is CUT. It cannot see the defect it exists for.\n'
    sed -n '1,40p' "$WORK/run.log"
    exit 1 ;;
  77)
    printf '\033[33mCALIBRATION SKIPPED\033[0m — the rig skipped (no Chrome, or an\n'
    printf '  infrastructure failure). Nothing proven.\n'
    sed -n '1,20p' "$WORK/run.log"
    exit 77 ;;
  3)
    # 3 = "painted, but served without its stylesheet". That is a real finding,
    # but it is NOT proof the rig can see a blank board, so it is not a pass —
    # accepting any non-zero here would let a degraded seam masquerade as
    # calibration, which is precisely the silence being cured.
    printf '\033[31mCALIBRATION INCONCLUSIVE\033[0m — the rig went red for the WRONG REASON:\n'
    printf '  the app was served incomplete (a stylesheet 404), so it never got to\n'
    printf '  demonstrate that it can see the cut fetch→render chain.\n'
    sed -n '1,40p' "$WORK/run.log"
    exit 1 ;;
  1)
    printf '\033[32mCALIBRATION PASSED\033[0m — with `.then(render)` removed the rig exited %s.\n' "$RC"
    grep -E 'THE BOARD DID NOT PAINT|expected >=|status line' "$WORK/run.log" | sed 's/^/  /'
    printf '  A blank board is visible to this rig. Screenshot of it: %s/run/board.png\n' "$WORK"
    exit 0 ;;
  *)
    printf '\033[31mCALIBRATION FAILED\033[0m — the rig exited %s, which is neither the\n' "$RC"
    printf '  "board did not paint" verdict (1) nor a skip. Unexpected; look at the log.\n'
    sed -n '1,40p' "$WORK/run.log"
    exit 1 ;;
esac
