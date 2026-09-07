#!/usr/bin/env bash
# S184 tester — attack the SCOPE FENCE end to end. Zero spend (shim + fuse).
# NOTE: rig.sh's drive() sets the globals RC and OUT; use DEST for our own dir.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EV="$LCARS_SRC/skills/lcars-init/establish-vision.sh"
DEST="$HERE/verify"; mkdir -p "$DEST"
LOG="$DEST/fence.calls.log"; : > "$LOG"
SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99

mkrepo() { newrepo "$1" >/dev/null; echo "$FIX_ROOT/$1"; }

case_run() { # name idea stack slice reasons deferred
  local name="$1" idea="$2" stack="$3" slice="$4" reasons="$5" deferred="$6"
  local repo; repo="$(mkrepo "s184-$name")"
  printf '%s\n' "$idea"    > "$repo/../$name.idea"
  printf '%s\n' "$reasons" > "$repo/../$name.reasons"
  printf '%s\n' "$deferred"> "$repo/../$name.deferred"
  echo "########################### CASE: $name"
  drive "$repo" "$SHIM" -- bash "$EV" --file \
      --idea "$repo/../$name.idea" --stack "$stack" --slice "$slice" \
      --reasons "$repo/../$name.reasons" --deferred "$repo/../$name.deferred"
  echo "RC=$RC"; echo "$OUT"
  local mid; mid="$(printf '%s' "$OUT" | sed -n 's/^MISSION_ID=//p' | head -1)"
  echo "--- mission=$mid"
  if [ -n "$mid" ]; then
    mkdir -p "$DEST/$name"
    cp "$repo/.git/lcars/missions/$mid/prd.md" "$DEST/$name/prd.md" 2>/dev/null
    cp "$repo/.git/lcars/vision.md" "$DEST/$name/vision.md" 2>/dev/null
    cp "$repo/.git/lcars/missions/$mid/state.json" "$DEST/$name/state.json" 2>/dev/null
  fi
  echo "REPO=$repo"
}
