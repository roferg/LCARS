#!/usr/bin/env bash
# DRIVE 1 — the captain's end-to-end: file → bounce ×2 → re-grill → Verify entry.
. "$(dirname "$0")/lib.sh"
REPO="$(new_repo)"; MID="lcars-20260907-001"; MDIR="$REPO/.git/lcars/missions/$MID"
write_prd "$REPO/prd-in.md"; write_adr "$REPO/adr-in.md"

hdr "STEP 1 — lcars file (grill-first lane)"
( cd "$REPO" && LCARS_DATE=20260907 LCARS_NOW=2026-09-07T10:00:00Z \
    bash "$FILE_SH" --prd "$REPO/prd-in.md" --adr "$REPO/adr-in.md" >"$WORK/file.out" 2>&1 )
[ -d "$MDIR" ] && ok "mission filed: $MID" || { bad "filing failed"; cat "$WORK/file.out"; exit 1; }
note "state: $(tr -d '\n' <"$MDIR/state.json" | cut -c1-400)"
note "mission dir: $(ls -a "$MDIR" | tr '\n' ' ')"
E0=$(body_edits)

hdr "STEP 2 — mid-flight stages"
for st in research validate plan plan-review schedule implement; do
  ( cd "$REPO" && bash "$RUN_SH" "$st" --mission "$MID" >"$WORK/stage.$st.out" 2>&1 )
  note "$st rc=$? stage=$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$MDIR/state.json"|head -1)"
done
E1=$(body_edits); [ "$E1" = "$E0" ] && ok "mid-flight stages fired ZERO body edits" || bad "mid-flight edits: $((E1-E0))"

hdr "STEP 3 — the pipeline reaches Verify (state set the way the pipeline leaves it)"
st_set_str "$MDIR/state.json" stage verify
st_add "$MDIR/state.json" '"prUrl": "https://github.com/owner/repo/pull/77"'
st_add "$MDIR/state.json" '"prNumber": 77'
note "state now: $(tr -d '\n' <"$MDIR/state.json" | cut -c1-200)"

hdr "STEP 3a — send-back #1"
( cd "$REPO" && LCARS_NOW=2026-09-07T12:00:00Z bash "$FEEDBACK_SH" --mission "$MID" \
   --feedback "The CSV must also carry the invoice PDF link column, and the filename needs the account slug in it. Also: finance wants a UTF-8 BOM so Excel stops mangling accented names." >"$WORK/fb1.out" 2>&1 )
note "rc=$?"; sed 's/^/    /' "$WORK/fb1.out"
E2=$(body_edits); [ "$E2" = "$E1" ] && ok "a send-back edits NO issue body" || bad "send-back edited the body"
note "state after send-back: $(tr -d '\n' <"$MDIR/state.json" | cut -c1-300)"

hdr "STEP 3b — send-back #2"
( cd "$REPO" && LCARS_NOW=2026-09-07T13:30:00Z bash "$FEEDBACK_SH" --mission "$MID" \
   --feedback "Second look: the button should be disabled while an export is in flight." >"$WORK/fb2.out" 2>&1 )
CC=$(grep -c 'method POST.*issues/42/comments' "$GH_LOG"||true); CE=$(grep -c 'method PATCH.*issues/comments' "$GH_LOG"||true)
[ "$CC" = 1 ] && ok "exactly ONE comment CREATE for two send-backs" || bad "comment creates: $CC"
[ "$CE" = 1 ] && ok "the second send-back PATCHed in place" || bad "comment edits: $CE"

hdr "STEP 4 — the captain re-grills; prd.md is rewritten; Research runs"
cat >"$MDIR/prd.md" <<'EOF'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the current invoice list as a CSV — with the PDF link column and an Excel-safe encoding — so month-end reconciliation stops being copy-paste out of the table.
**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table, disabled while an export is in flight
- Clicking it downloads `<account-slug>-invoices-<YYYY-MM-DD>.csv`
- The CSV carries the table's rows and columns in order, PLUS an `invoice_pdf_url` column
- The file is written with a UTF-8 BOM so Excel renders accented names correctly
- The export respects the active filters
**Out of Scope:**
- XLSX or PDF export
- Scheduled/emailed exports
**Constraints:**
- No new runtime dependencies
- Must stream for >10k rows rather than buffering
EOF
( cd "$REPO" && bash "$RUN_SH" research --mission "$MID" >"$WORK/research2.out" 2>&1 )
E3=$(body_edits); [ "$((E3-E2))" = 1 ] && ok "re-grill fired EXACTLY ONE body edit" || bad "re-grill body edits: $((E3-E2))"
note "sha marker: $(cat "$MDIR/.issue-body.sha" 2>/dev/null)"

hdr "STEP 5 — Verify entry (real drive_verify)"
st_set_str "$MDIR/state.json" stage verify
( cd "$REPO" && bash "$RUN_SH" drive --mission "$MID" >"$WORK/verify.out" 2>&1 )
note "drive rc=$?"; sed 's/^/    /' "$WORK/verify.out" | head -30
E4=$(body_edits); note "Verify-entry body edits: $((E4-E3))"

hdr "STEP 5b — a SECOND Verify entry (reconcile / re-drive): must not spam"
( cd "$REPO" && bash "$RUN_SH" drive --mission "$MID" >"$WORK/verify2.out" 2>&1 )
E5=$(body_edits); [ "$E5" = "$E4" ] && ok "Verify re-entry pushed NOTHING (idempotent)" || bad "re-entry pushed $((E5-E4))"

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)"
hdr "RECORDED"; ls "$BODIES" | grep -v argv | sed 's/^/    /'
echo "WORK=$WORK"; echo "REPO=$REPO"; echo "MDIR=$MDIR"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
