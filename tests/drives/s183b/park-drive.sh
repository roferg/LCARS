set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/logs/park.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"
PRD="$FIX_ROOT/s183b.prd.md"
for n in "$@"; do
  r="$FIX_ROOT/$n"
  [ -d "$r/.git/lcars" ] || drive "$r" "$SH" -- bash "$INIT_SH" >/dev/null
  echo "════════ --park @ $n"
  drive "$r" "$SH" -- bash "$FILE_SH" --park "a spending summary card"
  echo "$OUT" | sed 's/^/  /'; echo "  park rc=$RC"
  id="$(printf '%s' "$OUT" | sed -n 's/.*Mission filed: *\([a-z0-9-]*\).*/\1/p' | head -1)"
  if [ -n "$id" ]; then
    echo "════════ --complete $id @ $n"
    drive "$r" "$SH" -- bash "$FILE_SH" --complete "$id" --prd "$PRD"
    echo "$OUT" | sed 's/^/  /'; echo "  complete rc=$RC"
  fi
done
echo "SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
