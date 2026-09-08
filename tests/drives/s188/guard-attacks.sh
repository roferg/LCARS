#!/usr/bin/env bash
# GUARD-ATTACKS — verification round. Attack the S188 regression guard itself:
# false refusals, the heal path, stage-halting, and a missing/stale baseline.
#
# ---------------------------------------------------------------------------
# FIX ROUND 2 — WHAT CHANGED UNDER THIS DRIVE, AND WHY
# ---------------------------------------------------------------------------
# This drive was written against fix round 1's WHOLE-BODY REGRESSION GUARD: a
# recompose was pushed only if the finished text did not "look" lossy next to
# the last pushed body (a size ratio, a `^---$` count, a marker search). It
# found four defects in that guard (N1–N4), and round 2 answered them by
# DELETING the mechanism rather than patching it — the body is now resolved
# PART BY PART from each part's own SOURCE before anything is composed.
#
# Four legs below asserted the OLD mechanism's behaviour and could not survive
# its deletion. Each is re-aimed here, and the outcome change is stated rather
# than quietly swapped:
#
#   A0   measured "rule 2's floor". There is no rule 2 and no floor. The leg now
#        states that and shows the body shape it used to measure.
#   A3   drove `lcars_ib_regression` directly to find the ratio's exact cliff
#        (0.500 allow / 0.499 refuse). The function is gone; the leg now PROVES
#        it is gone and that no size comparison replaced it.
#   A6   asserted that deleting estimate.json is a TRUE REFUSAL. It is not, any
#        more. Refusing there was itself half of N2: it left the issue carrying
#        the OLD SPEC, which is the defect S188 exists to close. estimate.json
#        is the source of ONE part, and when it is gone that part is CARRIED
#        FORWARD verbatim out of the last pushed body — so the spec update goes
#        through AND the "## Estimate" section (with all three pills) survives.
#        Strictly better: the old behaviour lost the spec to save the estimate;
#        the new one keeps both. The leg now asserts that.
#   A7   was the heal path OUT of A6's refusal. With A6 no longer refusing there
#        is nothing to heal from, so the heal path is re-driven from the case
#        that DOES still refuse (no baseline + no estimate.json).
#   A9d  a 6-byte hand-written `.issue-body.last` used to disarm the guard. A
#        baseline is now only honoured when it carries the envelope every
#        composed body ends with, so a corrupt one reads as NO record and the
#        estimate refuses instead of silently dropping. The leg now asserts that.
#
# ONE FIXTURE FIX: lib.sh's canned estimate.json said `"implCriticality": "med"`.
# `estimate_validate_and_write` only ever writes low|medium|high, so "med" is a
# value the product cannot produce — and it silently cost every pill assertion
# in this rig its implementation pill. Corrected to "medium" so the D4 pill
# proof is real.
. "$(dirname "$0")/lib.sh"
IB="$LCARS_SRC/skills/lcars-run/issue-body.sh"

# a filed, aligned mission sitting one drive away from the Verify transfer point
mkv() { local R; R="$(new_repo)"; write_prd "$R/prd-in.md"; write_adr "$R/adr-in.md"
  ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" ) >/dev/null 2>&1
  sed -i '' 's/"stage": "align"/"stage": "verify"/' "$R/.git/lcars/missions/lcars-20260907-001/state.json"
  printf '%s' "$R"; }
lastbody() { printf '%s' "$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"; }

hdr "A0 — the shape of a real composed body (nothing measures it any more)"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
tot=$(wc -c <"$M/.issue-body.last"|tr -d ' ')
prd=$(wc -c <"$M/prd.md"|tr -d ' ')
note "filed body = $tot bytes, of which prd.md = $prd bytes (non-PRD = $((tot-prd)))"
note "round 1 refused below half of $tot bytes. Round 2 has NO size rule at all:"
note "the spec is rebuilt from prd.md whatever its length, so a shorter spec is"
note "no longer evidence of anything and cannot be refused for being short."
if grep -q 'lcars_ib_regression' "$IB"; then
  bad "the whole-body regression guard is still in the library"
else
  ok "no whole-body guard survives in issue-body.sh"
fi

hdr "A1 — FALSE REFUSAL: an honest re-grill that legitimately SHORTENS the spec"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
cat >"$M/prd.md" <<'P'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** Download the invoice list as CSV.
**Acceptance Criteria:**
- An "Export CSV" button downloads the current rows
P
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
p="$(lastbody)"
if grep -q 'Download the invoice list as CSV' "$p"; then ok "a scope-cutting re-grill still pushed"
else bad "an honest scope cut was REFUSED"; note "$(cat "$M/.issue-body.refused" 2>/dev/null)"; fi

hdr "A2 — FALSE REFUSAL: a re-grill that RETITLES '# Mission: …'"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
sed -i '' '1s/.*/# Mission: Export invoices to CSV (renamed)/' "$M/prd.md"
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
p="$(lastbody)"
grep -q 'renamed' "$p" && ok "a retitle pushed" || { bad "a retitle was REFUSED"; note "$(cat "$M/.issue-body.refused" 2>/dev/null)"; }

hdr "A3 — THE CLIFF IS GONE: no ratio, no separator count, no marker search"
( set +u; . "$IB"
  if command -v lcars_ib_regression >/dev/null 2>&1; then
    echo "  FAIL lcars_ib_regression is still defined"; exit 1
  fi
  exit 0 ) \
  && ok "lcars_ib_regression is not defined at all — the mechanism is deleted" \
  || bad "lcars_ib_regression survived the restructure"
grep -q "grep -c '\^---\$'" "$IB" \
  && bad "the '---' separator count survives (N1)" \
  || ok "no '^---\$' counting anywhere — a PRD's own rules are never counted"
grep -Eq 'nn \* 2|\* 2\)\) -lt' "$IB" \
  && bad "a size-ratio comparison survives (N2)" \
  || ok "no size-ratio comparison anywhere"
note "round 1's measured cliff was: ratio 0.500 ALLOW / 0.499 REFUSE. Both sides"
note "of that cliff now push, because neither side is a question any more."

hdr "A3b — a PRD-heavy mission honestly cut hard in ONE re-grill"
R="$(new_repo)"
{ echo "# Mission: Rebuild the billing pipeline"; echo; echo "**Type:** feature"
  echo "**Goal:** Replace the batch biller."; echo "**Acceptance Criteria:**"
  for i in $(seq 1 60); do echo "- The new biller handles case number $i exactly as the old one did, byte for byte"; done
  echo "**Out of Scope:**"; echo "- anything else"; echo "**Constraints:**"; echo "- none"; } >"$R/prd-in.md"
write_adr "$R/adr-in.md"
( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" ) >/dev/null 2>&1
M="$R/.git/lcars/missions/lcars-20260907-001"
sed -i '' 's/"stage": "align"/"stage": "verify"/' "$M/state.json"
{ echo "# Mission: Rebuild the billing pipeline"; echo; echo "**Type:** feature"
  echo "**Goal:** Replace the batch biller."; echo "**Acceptance Criteria:**"
  for i in 1 2 3; do echo "- The new biller handles case number $i exactly as the old one did, byte for byte"; done
  echo "**Out of Scope:**"; echo "- anything else"; echo "**Constraints:**"; echo "- none"; } >"$M/prd.md"
for pass in 1 2 3; do
  b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
  [ "$pass" = 1 ] && { [ "$((a-b))" -ge 1 ] && ok "the honest hard cut PUSHED" \
      || bad "FALSE REFUSAL on an honest hard scope cut — and there is no force flag"; }
  note "pass $pass: edits=$((a-b))"
done
[ -f "$M/.issue-body.refused" ] && bad "an honest hard cut left a refusal breadcrumb" \
  || ok "no refusal breadcrumb — the hard cut was never in question"

hdr "A4 — FALSE REFUSAL HUNT: a PRD that contains its own '---' horizontal rule"
R="$(new_repo)"
cat >"$R/prd-in.md" <<'P'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the invoice list as a CSV.

---

**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table
- Clicking it downloads `invoices-<YYYY-MM-DD>.csv`
- The CSV carries the same rows and columns the table shows
**Out of Scope:**
- XLSX or PDF export
**Constraints:**
- No new runtime dependencies
P
write_adr "$R/adr-in.md"
( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" ) >/dev/null 2>&1
M="$R/.git/lcars/missions/lcars-20260907-001"
sed -i '' 's/"stage": "align"/"stage": "verify"/' "$M/state.json"
# the re-grill drops the captain's own horizontal rule and edits a line — the
# body gets no longer, and NOTHING the composer owns is lost.
grep -v '^---$' "$M/prd.md" >"$WORK/p4" && mv "$WORK/p4" "$M/prd.md"
sed -i '' 's/XLSX or PDF export/XLSX export/' "$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
if [ "$((a-b))" -ge 1 ]; then ok "a PRD that drops its OWN '---' rule still pushed"
else bad "FALSE REFUSAL: deleting a horizontal rule INSIDE the captain's PRD was read as losing a composer-owned section"
     note "breadcrumb: $(cat "$M/.issue-body.refused" 2>/dev/null)"; fi

hdr "A5 — TRUE REFUSAL: 0-byte prd.md"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
: >"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >"$WORK/a5.out" 2>&1; a=$(body_edits)
[ "$a" = "$b" ] && ok "a 0-byte prd.md pushed NOTHING" || bad "a 0-byte prd.md still pushed $((a-b)) edit(s)"

hdr "A6 — CARRY-FORWARD: estimate.json deleted (the D4 case) + pills survive"
# Round 1 REFUSED here, which kept the Estimate section by keeping the OLD SPEC
# — half of N2. estimate.json is the source of ONE part; when it is gone that
# part is carried forward verbatim from the last pushed body, so the spec update
# goes through and nothing is deleted off the issue.
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
rm -f "$M/estimate.json"; printf '\n**Amended:** manifest too\n' >>"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
[ "$((a-b))" = 1 ] && ok "the spec update PUSHED despite the missing estimate.json" \
  || bad "the spec update was blocked ($((a-b)) edit(s)) — the issue keeps the old spec"
p="$(lastbody)"
grep -q 'manifest too' "$p" && ok "the pushed body carries the NEW spec" || bad "pushed body is stale"
grep -q '^## Estimate$' "$p" && ok "the '## Estimate' section was CARRIED FORWARD" || bad "the Estimate section was dropped"
[ -f "$M/.issue-body.refused" ] && bad "a carried-forward part was recorded as a refusal" || ok "no refusal breadcrumb (nothing was lost)"
[ -f "$M/.issue-body.sha" ] && ok "the successful push recorded the dedup marker" || bad "no dedup marker after a push"
( cd "$LCARS_SRC/web" && python3 -c '
import sys,json; sys.path.insert(0,".")
from lcars_serve import github_adapter as ga
d = ga._pills_from_body(open(sys.argv[1]).read())
print("  ·    pills still on the issue:", json.dumps(d))
print("  ·    non-null pills:", sum(1 for v in d.values() if v), "of 3")' "$p" )

hdr "A7 — THE HEAL PATH: from the case that DOES still refuse"
# A6 no longer refuses, so the heal path is driven from the one that does: no
# carry-forward record AND no estimate.json, where the refresh is blind.
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
rm -f "$M/.issue-body.last" "$M/estimate.json"; printf '\n**Amended:** heal me\n' >>"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
[ "$a" = "$b" ] && ok "blind (no record + no estimate.json) → REFUSED, no edit" || bad "pushed $((a-b)) edit(s) while blind"
[ -f "$M/.issue-body.refused" ] && ok "breadcrumb written: $(cut -f3 <"$M/.issue-body.refused")" || bad "no breadcrumb"
[ -f "$M/.issue-body.sha" ] && bad "a REFUSED refresh wrote the dedup marker" || ok "no dedup marker on refusal"
cat >"$M/estimate.json" <<'J'
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "medium",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
J
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
[ "$((a-b))" -ge 1 ] && ok "the NEXT transfer point healed the issue ($((a-b)) edit)" || bad "STUCK: the mission never pushed again"
p="$(lastbody)"; grep -q 'heal me' "$p" && ok "the healed body carries the new spec" || bad "healed body is stale"
grep -q '## Estimate' "$p" && ok "and the Estimate section is back" || bad "Estimate still missing"
[ -f "$M/.issue-body.refused" ] && bad "the breadcrumb SURVIVED a successful heal" || ok "breadcrumb deleted on heal"
# and the captain is TOLD: `lcars status` reads the breadcrumb (round 1 wrote it
# and nothing anywhere read it — the silent half of N2).
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
: >"$M/prd.md"
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
( cd "$R" && bash "$LCARS_SRC/skills/lcars-status/status.sh" ) >"$WORK/status.out" 2>&1
grep -q 'Issue body NOT updated' "$WORK/status.out" \
  && ok "lcars status surfaces the refusal to the captain" || bad "the refusal is STILL invisible"
sed -n '/Issue body NOT updated/,$p' "$WORK/status.out" | while IFS= read -r l; do note "$l"; done

hdr "A8 — DOES A REFUSAL HALT THE STAGE?"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
rm -f "$M/estimate.json"; printf '\n**Amended:** x\n' >>"$M/prd.md"
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >"$WORK/a8.out" 2>&1; rc=$?
note "drive rc=$rc"
note "stage after: $(grep -o '"stage"[^,]*' "$M/state.json" | head -1)"
grep -qi 'refus' "$WORK/a8.out" && note "refusal text leaked to the captain's console" || note "refusal is SILENT on the console (both call sites redirect stderr)"
[ "$rc" = 0 ] && ok "the drive did not fail on a refusal" || bad "a refusal made the drive exit $rc"

hdr "A9 — THE BASELINE FILE: absent, empty, stale, hand-deleted"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
note "does filing seed a baseline? $([ -f "$M/.issue-body.last" ] && echo yes || echo NO)"
# A9a: baseline hand-deleted, then a catastrophic recompose
rm -f "$M/.issue-body.last" "$M/estimate.json"; : >"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
note "no baseline + 0-byte prd → edits: $((a-b)) (the -s prd guard, not the baseline guard, must catch this)"
[ "$a" = "$b" ] && ok "0-byte prd still blocked with NO baseline" || bad "with no baseline a 0-byte prd reached GitHub"
# A9b: baseline gone, estimate gone, prd fine → the D4 case with no baseline
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
rm -f "$M/.issue-body.last" "$M/estimate.json"; printf '\nx\n' >>"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
p="$(lastbody)"
if [ "$((a-b))" -ge 1 ] && ! grep -q '## Estimate' "$p"; then
  bad "NO BASELINE ⇒ ALLOW EVERYTHING: the Estimate section was silently deleted off the issue"
else ok "a missing baseline did not open the D4 hole (it refuses BY NAME instead)"; fi
[ -s "$M/.issue-body.refused" ] && ok "…naming the part: $(cut -f3 <"$M/.issue-body.refused")" \
  || bad "the no-baseline case refused silently"
# A9c: EMPTY baseline file
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
: >"$M/.issue-body.last"; rm -f "$M/estimate.json"; printf '\nx\n' >>"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
[ "$a" = "$b" ] && ok "an EMPTY baseline degrades like an absent one (refused, no edit)" \
  || bad "an empty baseline pushed $((a-b)) edit(s) — the old silent-disarm hole"
# A9d: STALE / hand-written baseline. A baseline is only honoured when it
# carries the envelope every composed body ends with, so a 6-byte hand-written
# file is NOT a record and cannot "prove" the issue has no Estimate section.
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
printf 'stale\n' >"$M/.issue-body.last"; rm -f "$M/estimate.json"; printf '\nx\n' >>"$M/prd.md"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1; a=$(body_edits)
[ "$a" = "$b" ] && ok "a 6-byte hand-written baseline is NOT read as a record (refused, no edit)" \
  || bad "a corrupt baseline let the Estimate section be deleted ($((a-b)) edit)"
[ -s "$M/.issue-body.refused" ] && ok "…and the refusal names the part: $(cut -f3 <"$M/.issue-body.refused")" \
  || bad "no breadcrumb for the corrupt-baseline refusal"

hdr "SPEND"; note "worker spawns: $(spawns)  billable(--model): $(billable)"
echo "WORK=$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
