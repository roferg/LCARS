#!/usr/bin/env bash
# RECORD-ATTACKS — S188 fix round 3. Attack the CARRY-FORWARD itself.
#
# Round 2 replaced a whole-body heuristic guard with part-aware composition (the
# right move, and `guard-attacks.sh` proves it holds). But its carry-forward
# helpers located each part in the last pushed body BY GREPPING THE CAPTAIN'S
# PROSE, which put the same disease back at a smaller scale:
#
#   NEW-1  `lcars_ib_carry_estimate` was `grep -n '^## Estimate$' | tail -1`.
#          With no real Estimate section it matched a heading inside the PRD, so
#          the "carried estimate" was everything from there to the end of the
#          body — the PRD tail plus the whole ADR set, appended AGAIN. Silent:
#          it pushed, wrote the dedup marker, left no breadcrumb, and every
#          later refresh reproduced it.
#   NEW-2  `lcars_ib_prev_has_adr` grepped the whole body for `**Context:**`,
#          `**Decision:**`, `**Alternatives considered:**`, `**Consequences:**`.
#          A PRD that merely DOCUMENTS the ADR format matched all four, so a
#          mission that never had an ADR read as carrying one and the push was
#          refused — for ever, at every transfer point, leaving the OLD SPEC on
#          the issue.
#   NEW-3  the captain could not REMOVE an ADR from an issue: deleting adr.md
#          alone silently resurrected it, while deleting it during a re-grill
#          refused for good. One act, two opposite answers.
#
# This captain writes PRDs ABOUT LCARS — a system whose own docs are full of ADR
# field names and `## Estimate` headings — so the fixture PRD here is one of his:
# a spec that documents the issue-body layout. Every leg runs the REAL verbs.
. "$(dirname "$0")/lib.sh"
IB="$LCARS_SRC/skills/lcars-run/issue-body.sh"
MID=lcars-20260907-001

# A PRD that is ABOUT the issue body: an H2 literally named "## Estimate" AND
# all four ADR field names, all of it the captain's own prose.
write_meta_prd() { cat >"$1" <<'EOF'
# Mission: Document the LCARS issue body layout

**Type:** feature
**Goal:** The handbook explains, section by section, how LCARS lays out a GitHub issue body so a reader can predict what a refresh will push.
**Acceptance Criteria:**
- The handbook shows the section order the composer emits
- The handbook names every field the board scrapes off the body
- The handbook is regenerated whenever the composer changes
**Out of Scope:**
- Changing the composer itself
- The handoff envelope's schema
**Constraints:**
- No new runtime dependencies

## Estimate

MARKER-PRD-TAIL — the composer appends this section from estimate.json and the
board scrapes its pills out of the rendered text. Each ADR in adr.md carries
**Context:**, **Decision:**, **Alternatives considered:** and **Consequences:**,
which is the shape `lcars file` validates at the filing boundary.
EOF
}

write_meta_prd "$WORK/meta.prd"; write_adr "$WORK/meta.adr"
write_prd      "$WORK/csv.prd";  write_adr "$WORK/csv.adr"

# mkm <prd-file> [adr-file] [estimator|none] → a filed mission parked at Verify
mkm() {
  local prd="$1" adr="${2:-}" est="${3:-estimator}" R
  R="$(new_repo)"
  if [ "$est" = none ]; then
    if [ -n "$adr" ]; then
      ( cd "$R" && LCARS_DATE=20260907 LCARS_RUN_BIN=/nonexistent-estimator \
          bash "$FILE_SH" --prd "$prd" --adr "$adr" ) >/dev/null 2>&1
    else
      ( cd "$R" && LCARS_DATE=20260907 LCARS_RUN_BIN=/nonexistent-estimator \
          bash "$FILE_SH" --prd "$prd" ) >/dev/null 2>&1
    fi
  else
    if [ -n "$adr" ]; then
      ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$prd" --adr "$adr" ) >/dev/null 2>&1
    else
      ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$prd" ) >/dev/null 2>&1
    fi
  fi
  sed -i '' 's/"stage": "align"/"stage": "verify"/' "$R/.git/lcars/missions/$MID/state.json"
  printf '%s' "$R"
}
reverify() { sed -i '' 's/"stage": "[a-z]*"/"stage": "verify"/' "$1/state.json"; }
drive() { ( cd "$1" && bash "$RUN_SH" drive --mission "$MID" ) >/dev/null 2>&1; }
lastbody() { printf '%s' "$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"; }
status_of() { ( cd "$1" && bash "$LCARS_SRC/skills/lcars-status/status.sh" ) 2>&1; }

# ===========================================================================
hdr "R1 — NEW-1: an '## Estimate' heading inside the PRD, and no estimate.json"
# The exact trigger: the last pushed body carries NO composer-appended Estimate
# section (the mission was filed with no estimator), but the PRD's own prose
# contains the heading the round-2 carry searched for.
R="$(mkm "$WORK/meta.prd" "$WORK/meta.adr" none)"
M="$R/.git/lcars/missions/$MID"
p="$(lastbody)"
note "filed body: ADR-001 x$(grep -c 'ADR: Stream' "$p"), '^---$' x$(grep -c '^---$' "$p"), estimate.json present? $([ -f "$M/estimate.json" ] && echo yes || echo NO)"
if [ -f "$M/.issue-body.parts/flags" ]; then
  ok "the composer wrote a part record: $(tr '\n' ' ' <"$M/.issue-body.parts/flags")"
else bad "no part record after filing"; fi
grep -q '^est=0$' "$M/.issue-body.parts/flags" 2>/dev/null \
  && ok "the record STATES the issue carries no Estimate section (est=0)" \
  || bad "the record does not state the estimate's absence"

printf '\n**Amended:** the re-grill touched this spec.\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
p="$(lastbody)"
[ "$((a-b))" = 1 ] && ok "the refresh pushed the new spec" || bad "expected 1 edit, saw $((a-b))"
grep -q 'the re-grill touched this spec' "$p" && ok "…and the body carries it" || bad "body is stale"
n=$(grep -c 'MARKER-PRD-TAIL' "$p"); [ "$n" = 1 ] \
  && ok "the PRD tail appears ONCE (round 2 duplicated it)" \
  || bad "the PRD tail appears $n times — the body is corrupt"
n=$(grep -c 'ADR: Stream' "$p"); [ "$n" = 1 ] \
  && ok "the ADR set appears ONCE (round 2 duplicated it)" \
  || bad "the ADR set appears $n times — the body is corrupt"
n=$(grep -c '^---$' "$p"); [ "$n" = 1 ] \
  && ok "exactly one composer rule (prd --- adr), nothing re-appended" \
  || bad "$n '^---\$' rules — a section was appended twice"
[ -f "$M/.issue-body.carried" ] && bad "nothing was carried, yet a carry breadcrumb was written" \
  || ok "no carry breadcrumb (est=0 is an ABSENCE, not a carry)"
# and it does not creep: a second transfer point reproduces the same body
reverify "$M"; printf '\n**Amended:** and again.\n' >>"$M/prd.md"
drive "$R"; p="$(lastbody)"
n=$(grep -c 'ADR: Stream' "$p"); [ "$n" = 1 ] \
  && ok "a SECOND refresh still carries the ADR exactly once" \
  || bad "the corruption grew on the second pass ($n)"

# ===========================================================================
hdr "R2 — NEW-2: a PRD that DOCUMENTS the ADR format, on a mission with none"
R="$(mkm "$WORK/meta.prd")"; M="$R/.git/lcars/missions/$MID"
[ -f "$M/adr.md" ] && bad "fixture is wrong: this mission has an adr.md" \
  || ok "the mission has never had an adr.md"
grep -q '\*\*Context:\*\*' "$M/prd.md" && grep -q '\*\*Consequences:\*\*' "$M/prd.md" \
  && ok "…while its PRD spells all four ADR field names" || bad "fixture PRD lost the field names"
for pass in 1 2 3; do
  reverify "$M"; printf '\n**Amended:** pass %s.\n' "$pass" >>"$M/prd.md"
  b=$(body_edits); drive "$R"; a=$(body_edits)
  if [ "$((a-b))" = 1 ]; then ok "pass $pass PUSHED (round 2 refused, permanently)"
  else bad "pass $pass pushed $((a-b)) edit(s) — the false refusal survives"
       note "breadcrumb: $(cat "$M/.issue-body.refused" 2>/dev/null)"; fi
done
p="$(lastbody)"
grep -q 'pass 3' "$p" && ok "the issue carries the LATEST spec, not the old one" || bad "the issue is stale"
[ -f "$M/.issue-body.refused" ] && bad "a refusal breadcrumb survives" || ok "no refusal breadcrumb anywhere"

# ===========================================================================
hdr "R3 — NEW-3: the captain removes an ADR from an issue"
R="$(mkm "$WORK/csv.prd" "$WORK/csv.adr")"; M="$R/.git/lcars/missions/$MID"
# (a) delete adr.md AND re-grill in the same round — round 2 refused for ever
rm -f "$M/adr.md"; printf '\n**Amended:** the spec moved in the same round\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$((a-b))" = 1 ] && ok "delete+re-grill PUSHES (round 2 refused permanently)" \
  || bad "delete+re-grill still refuses ($((a-b)) edit(s))"
p="$(lastbody)"
grep -q 'ADR: Stream' "$p" && ok "…carrying the ADR forward" || bad "the ADR was dropped"
grep -q 'the spec moved in the same round' "$p" && ok "…with the NEW spec" || bad "the spec is stale"
# (b) the carry is ANNOUNCED — it used to be completely silent
[ -s "$M/.issue-body.carried" ] && ok "a carry breadcrumb was written: $(cut -f3 <"$M/.issue-body.carried" | head -1)" \
  || bad "the carry is still silent"
status_of "$R" >"$WORK/r3.status"
grep -q 'CARRIED-FORWARD' "$WORK/r3.status" && ok "lcars status announces it" || bad "lcars status is silent"
grep -q '.issue-body.parts/adr' "$WORK/r3.status" \
  && ok "…and prints the exact act that REMOVES the ADR" || bad "the removal act is undocumented"
sed -n '/CARRIED-FORWARD/,$p' "$WORK/r3.status" | while IFS= read -r l; do note "$l"; done
# (c) run that act
reverify "$M"; rm -f "$M/.issue-body.parts/adr"
printf '\n**Amended:** and the ADR is gone for good\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
p="$(lastbody)"
if [ "$((a-b))" = 1 ] && ! grep -q 'ADR: Stream' "$p"; then
  ok "forgetting the recorded part REMOVES the ADR from the issue"
else bad "the ADR could not be removed ($((a-b)) edit(s))"; fi
grep -q 'and the ADR is gone for good' "$p" && ok "…and the spec still updated" || bad "the spec did not update"

# ===========================================================================
hdr "R4 — a 0-byte adr.md is a CRASH ARTIFACT, not 'no ADR'"
# run.sh's Validate stage copies a worker's adr.md back over the mission's, so a
# 0-byte adr.md is the same shape as the 0-byte prd.md D3 refuses on.
R="$(mkm "$WORK/csv.prd" "$WORK/csv.adr")"; M="$R/.git/lcars/missions/$MID"
: >"$M/adr.md"; printf '\n**Amended:** q\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$a" = "$b" ] && ok "a 0-byte adr.md pushes NOTHING" || bad "it pushed $((a-b)) edit(s)"
[ -s "$M/.issue-body.refused" ] && ok "…refusing BY NAME: $(cut -f3 <"$M/.issue-body.refused")" \
  || bad "no refusal breadcrumb"
fix="$(cut -f5 <"$M/.issue-body.refused" 2>/dev/null)"
note "remedy: $fix"
case "$fix" in
  *"from the mission history"*) bad "the remedy names a file the captain may never have had" ;;
  *) ok "the remedy names only files/acts that exist in this case" ;;
esac
[ -f "$M/.issue-body.sha" ] && bad "a REFUSED refresh wrote the dedup marker" || ok "no dedup marker on refusal"

# ===========================================================================
hdr "R5 — the RECORD is honest about what it is"
# (a) a record whose body no longer matches it is not a record
R="$(mkm "$WORK/csv.prd" "$WORK/csv.adr")"; M="$R/.git/lcars/missions/$MID"
printf 'tampered\n' >>"$M/.issue-body.last"; rm -f "$M/estimate.json"
printf '\n**Amended:** x\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$a" = "$b" ] && ok "a tampered baseline reads as NO record (refused, no edit)" \
  || bad "a tampered baseline was trusted ($((a-b)) edit)"
# (b) a mission recorded by an LCARS that predates this layout
R="$(mkm "$WORK/csv.prd" "$WORK/csv.adr")"; M="$R/.git/lcars/missions/$MID"
rm -rf "$M/.issue-body.parts"; rm -f "$M/estimate.json"
printf '\n**Amended:** y\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$a" = "$b" ] && ok "a body with no part record degrades honestly (refused, no edit)" \
  || bad "a legacy body was guessed at ($((a-b)) edit)"
[ -s "$M/.issue-body.refused" ] && ok "…naming the part: $(cut -f3 <"$M/.issue-body.refused")" \
  || bad "the legacy case refused silently"
# (c) …and it heals itself at the first successful push
cat >"$M/estimate.json" <<'J'
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "medium",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
J
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$((a-b))" -ge 1 ] && ok "the next transfer point healed it" || bad "STUCK — it never pushed again"
[ -f "$M/.issue-body.parts/flags" ] && ok "…and re-seeded the part record" || bad "no record after the heal"
[ -f "$M/.issue-body.refused" ] && bad "the breadcrumb survived the heal" || ok "breadcrumb deleted on heal"

# ===========================================================================
hdr "R6 — the CARRIED estimate is no longer a silent fossil"
R="$(mkm "$WORK/csv.prd" "$WORK/csv.adr")"; M="$R/.git/lcars/missions/$MID"
rm -f "$M/estimate.json"; printf '\n**Amended:** pills are a fossil\n' >>"$M/prd.md"
b=$(body_edits); drive "$R"; a=$(body_edits)
[ "$((a-b))" = 1 ] && ok "the spec pushed despite the missing estimate.json" || bad "it did not push"
p="$(lastbody)"
grep -q '^## Estimate$' "$p" && ok "the '## Estimate' section was carried forward" || bad "it was dropped"
status_of "$R" >"$WORK/r6.status"
grep -q 'Estimate carried forward' "$WORK/r6.status" \
  && ok "lcars status says the pills are carried, not rebuilt" || bad "the carry is still silent"
grep -q 'estimate.json' "$WORK/r6.status" && ok "…and names the missing source" || bad "no source named"
sed -n '/CARRIED-FORWARD/,$p' "$WORK/r6.status" | while IFS= read -r l; do note "$l"; done
( cd "$LCARS_SRC/web" && python3 -c '
import sys,json; sys.path.insert(0,".")
from lcars_serve import github_adapter as ga
d = ga._pills_from_body(open(sys.argv[1]).read())
print("  ·    pills:", json.dumps(d), "→", sum(1 for v in d.values() if v), "of 3")' "$p" )
# restoring the source clears the line
cat >"$M/estimate.json" <<'J'
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "medium",
  "models": {}, "deviations": [], "estimatorModel": "opus" }
J
reverify "$M"; printf '\n**Amended:** rebuilt\n' >>"$M/prd.md"; drive "$R"
[ -f "$M/.issue-body.carried" ] && bad "the carry line survived a full rebuild" \
  || ok "a fully rebuilt body clears the carry line"

hdr "SPEND"; note "worker spawns: $(spawns)  billable(--model): $(billable)"
echo "WORK=$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
