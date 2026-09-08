#!/usr/bin/env bash
# VERIFY-ENTRY — transfer point 2: it pushes when the body changed, and only then.
. "$(dirname "$0")/lib.sh"

# (the `lcars log` legs live in logged-bug.sh — this drive is the Verify end only)

hdr "V1 — Verify entry DOES push when the body genuinely changed"
R2="$(new_repo)"; write_prd "$R2/prd-in.md"; write_adr "$R2/adr-in.md"
( cd "$R2" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R2/prd-in.md" --adr "$R2/adr-in.md" ) >/dev/null 2>&1
M2="$R2/.git/lcars/missions/lcars-20260907-001"
printf '\n**Amended at Verify:** the export now also writes a manifest.\n' >>"$M2/prd.md"
sed -i '' 's/"stage": "align"/"stage": "verify"/' "$M2/state.json"
b=$(body_edits); ( cd "$R2" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >"$WORK/v1.out" 2>&1
a=$(body_edits)
[ "$((a-b))" = 1 ] && ok "Verify entry pushed exactly ONE body edit" || bad "Verify-entry edits: $((a-b))"
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
grep -q 'Amended at Verify' "$p" && ok "the pushed Verify body carries the current PRD" || bad "Verify body is stale"
note "envelope: $(tail -1 "$p")"
note "marker: $(cat "$M2/.issue-body.sha" 2>/dev/null)"
b=$(body_edits); ( cd "$R2" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
a=$(body_edits); [ "$a" = "$b" ] && ok "a second Verify pass pushes nothing" || bad "Verify re-entry spammed $((a-b))"

hdr "V2 — a mission that was NEVER bounced still gets a Verify refresh"
note "(V1 is exactly that case: filed, never bounced, refreshed at Verify) — see above."

hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)"
echo "WORK=$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
