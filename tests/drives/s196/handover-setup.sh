#!/usr/bin/env bash
# S196 TESTER — set the stage for the VISUAL WALKTHROUGH and for A4/A5.
# Laptop A files a real mission (real gh); laptop B is an INITIALISED clone that
# holds no missions, so the board there must show A's mission as a REMOTE card.
# Leaves everything in place for board.sh to photograph.
. "$(dirname "$0")/../s189/lib.sh"
DATE="${S196_DATE:-20260909}"
A="$(laptop A)"; B="$(laptop B)"
reset_laptop "$A"; reset_laptop "$B"
lcars_config "$A"; lcars_config "$B"
cat >"$WORK/prd.md" <<'EOF'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the current invoice list as a CSV from the list page, so month-end reconciliation stops being copy-paste out of the table.
**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table
- Clicking it downloads `invoices-<YYYY-MM-DD>.csv`
- The CSV carries the same rows the table shows
**Out of Scope:**
- XLSX or PDF export
**Constraints:**
- No new runtime dependencies
EOF
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T15:00:00Z bash "$FILE_SH" --prd "$WORK/prd.md" --engine copilot ) >"$WORK/f.out" 2>&1
sed 's/^/    /' "$WORK/f.out" | tail -8
MID="$(ls "$A/.git/lcars/missions" | head -1)"; MD="$A/.git/lcars/missions/$MID"
ISSUE="$(st_raw "$MD/state.json" githubIssue)"
ok "laptop A holds $MID (issue #$ISSUE, engine $(st_get "$MD/state.json" workerBin))"
[ -f "$MD/estimate.json" ] && ok "A has estimate.json (the pills' source)" || bad "no estimate.json on A"
[ -z "$(ls "$B/.git/lcars/missions" 2>/dev/null)" ] && ok "laptop B holds NO missions" || bad "B is not empty"
printf '%s\n' "$MID" >"$S189_HOME/s196-wt-mid"
printf '%s\n' "$ISSUE" >"$S189_HOME/s196-wt-issue"
printf '%s\n' "$A" >"$S189_HOME/s196-wt-A"
printf '%s\n' "$B" >"$S189_HOME/s196-wt-B"
note "SHIM=$SHIM  GH_REC=$LCARS_GH_BIN  GH_LOG=$GH_LOG"
printf '%s\n' "$SHIM" >"$S189_HOME/s196-wt-shim"
printf '%s\n' "$LCARS_GH_BIN" >"$S189_HOME/s196-wt-gh"
printf '%s\n' "$WORK" >"$S189_HOME/s196-wt-work"
printf '\n%d passed, %d failed\nWORK=%s MID=%s ISSUE=#%s\n' "$PASS" "$FAIL" "$WORK" "$MID" "$ISSUE"
