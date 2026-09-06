#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="${1:?calls log}"
: > "$LOG"
SH="$(make_shim "$LOG")"
echo "SHIM=$SH"
for n in "${@:2}"; do
  r="$FIX_ROOT/$n"
  echo "════════════════════════════════════ lcars init @ $n"
  drive "$r" "$SH" -- bash "$INIT_SH"
  echo "$OUT"
  echo "--- init rc=$RC"
done
echo "SPAWNS=$(calls "$LOG")  PROBES=$(probes "$LOG")"
