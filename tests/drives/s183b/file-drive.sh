#!/usr/bin/env bash
# Drive the REAL `lcars file` (grill-first --prd lane) across fixtures.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="${1:?calls log}"; shift
: > "$LOG"
SH="$(make_shim "$LOG")"
PRD="$FIX_ROOT/s183b.prd.md"
cat > "$PRD" <<'P'
**Mission**: Add a spending summary card

**Type**: feature

**Goal**: Show the user a monthly spending total on the dashboard.

**Acceptance Criteria**:
- A card appears on the dashboard showing the month's total.
- The total updates when a transaction is added.

**Out of Scope**: budgets, forecasting.

**Constraints**: no new dependencies.
P
echo "SHIM=$SH"
for n in "$@"; do
  r="$FIX_ROOT/$n"
  echo "════════════════════════════════════ lcars file --prd @ $n"
  before="$(calls "$LOG")"
  drive "$r" "$SH" -- bash "$FILE_SH" --prd "$PRD"
  echo "$OUT"
  echo "--- file rc=$RC  hires-during=$(( $(calls "$LOG") - before ))"
done
echo "TOTAL SPAWNS=$(calls "$LOG")  PROBES=$(probes "$LOG")"
