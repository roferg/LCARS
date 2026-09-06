set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="${1:?}"; shift
: > "$LOG"; SH="$(make_shim "$LOG")"
for n in "$@"; do
  r="$FIX_ROOT/$n"
  [ -d "$r/.git/lcars" ] || { echo "== init $n"; drive "$r" "$SH" -- bash "$INIT_SH" >/dev/null; }
  echo "════════════════ lcars update --fix-tests @ $n"
  drive "$r" "$SH" -- bash "$UPDATE_SH" --fix-tests
  echo "$OUT"; echo "--- rc=$RC"
  echo "--- gate AFTER: $( (cd "$r" && bash "$GATE_SH" --json) )"
done
echo "SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
