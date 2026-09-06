# Does running `lcars init` (the normal first step) FLIP the gate's answer?
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/logs/flip.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"
for n in "$@"; do
  bash "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" >/dev/null 2>&1 || true
  r="$FIX_ROOT/$n"
  echo "════════════════════ $n"
  echo "  BEFORE init : $( (cd "$r" && bash "$GATE_SH" --json) )"
  drive "$r" "$SH" -- bash "$INIT_SH"
  echo "$OUT" | sed 's/^/  init| /'
  echo "  AFTER  init : $( (cd "$r" && bash "$GATE_SH" --json) )"
  ( cd "$r" && bash "$GATE_SH" --check >/dev/null 2>&1 ); echo "  gate rc AFTER = $?  (20=refuse, 0=allow)"
done
echo "SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
