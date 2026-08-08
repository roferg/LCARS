#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's validate_plan_json (plan-save subcommand).
#
# Regression for the demo-day Plan bug: the awk validator only recognised an
# INLINE single-line `acceptanceCriteria` array (`["a","b"]`). A Plan worker that
# emitted the SAME array pretty-printed across multiple lines was wrongly rejected
# with "needs at least one acceptance criterion", deadlocking the Plan stage.
#
# This file is deliberately NOT the heavy tests/lcars-run.test.sh — it stands up a
# minimal local-only mission (no githubIssue → gh_relabel is a no-op) and drives
# the REAL validator through `run.sh plan-save`. Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Stand up a fresh git repo with one mission parked at stage "plan".
# Any arguments are attachment BASENAMES staged into the mission's attachments/
# dir (content is irrelevant — lcars_attach_kind classifies on the extension).
new_mission() { # [attachment-basename …] -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }
JSON
  if [ "$#" -gt 0 ]; then
    mkdir -p "$repo/.git/lcars/missions/test-001/attachments"
    local a
    for a in "$@"; do printf 'x' > "$repo/.git/lcars/missions/test-001/attachments/$a"; done
  fi
  echo "$repo"
}

run_plan_save() { # repo planfile -> sets RC + OUT
  OUT="$( cd "$1" && bash "$SCRIPT" plan-save --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
}

ticket() { # acceptanceCriteria-block -> full one-ticket plan.json on stdout
  cat <<JSON
[
  {
    "id": "t-001",
    "title": "Do the thing",
    "description": "Build the thing end to end.",
$1
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "rationale": "It is the foundation."
  }
]
JSON
}

# --- case 1: INLINE array still accepted (regression guard) -----------------
repo="$(new_mission)"; pf="$repo/inline.json"
ticket '    "acceptanceCriteria": ["the thing works"],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "inline acceptanceCriteria advances" \
  || bad "inline acceptanceCriteria advances (rc=$RC: $OUT)"

# --- case 2: MULTI-LINE array accepted (the fix) ----------------------------
repo="$(new_mission)"; pf="$repo/multiline.json"
ticket '    "acceptanceCriteria": [
      "the thing works",
      "the other thing works"
    ],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "multi-line acceptanceCriteria advances" \
  || bad "multi-line acceptanceCriteria advances (rc=$RC: $OUT)"

# --- case 3: genuinely EMPTY array still rejected (gate not loosened) --------
repo="$(new_mission)"; pf="$repo/empty.json"
ticket '    "acceptanceCriteria": [
    ],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "acceptance criterion"; } \
  && ok "empty multi-line acceptanceCriteria rejected" \
  || bad "empty multi-line acceptanceCriteria rejected (rc=$RC: $OUT)"

# --- case 4: empty INLINE array still rejected ------------------------------
repo="$(new_mission)"; pf="$repo/emptyinline.json"
ticket '    "acceptanceCriteria": [],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "acceptance criterion"; } \
  && ok "empty inline acceptanceCriteria rejected" \
  || bad "empty inline acceptanceCriteria rejected (rc=$RC: $OUT)"

# ===========================================================================
# S169 fix round 2 — THE TICKETS MUST CARRY THE MOCKUP
#
# MEASURED: a live drive filed a holodeck Mission carrying `attachment-01.html`
# and planned it into 8 tickets / 44 acceptance criteria. NONE of the 44
# referenced the mockup. The word "mock" appeared 15 times in DESCRIPTIONS and
# 0 times in a criterion, and the planner stated the policy 8 times, once per
# ticket: "Visual fidelity to the mockup is judged at Verify". A builder could
# satisfy all 44 without ever opening the drawing — which is what happened.
#
# The cure is a DECLARATION + a DETERMINISTIC CHECK, not a classifier:
#   • the planner DECLARES `changesScreenAppearance` per ticket (it is the one
#     party that knows — it is writing the ticket);
#   • the harness checks, by STRING CONTAINMENT of the mockup's own filename,
#     that a ticket declared true carries a criterion naming it.
# Nothing here reads a ticket's prose to decide what a ticket IS.
#
# The fixtures under tests/fixtures/plan-mockup/ are the REAL capstone
# artifacts: `capstone-0of44.json` is the plan the live drive produced, byte
# for byte.
# ===========================================================================
FX="$REPO_ROOT/tests/fixtures/plan-mockup"
MOCK=attachment-01.html

# mtickets: N tickets, each declaring $2 for changesScreenAppearance, with the
# criteria block $3 on every one. Canonical shape (one field per line).
mticket() { # decl criteria-array
  cat <<JSON
[
  {
    "id": "t-001",
    "title": "Reskin the sidebar",
    "description": "Redraw the sidebar nav.",
    "acceptanceCriteria": $2,
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": $1,
    "rationale": "It is the foundation."
  }
]
JSON
}

# --- M1: the REAL 0/44 plan, against the REAL mockup → REJECTED -------------
# Note it is not "no mention of the file anywhere": `attachment-01.html` appears
# once in t-001's DESCRIPTION. The check must look at acceptanceCriteria ONLY.
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/capstone-0of44.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "changesScreenAppearance"; } \
  && ok "M1. the live 0/44 capstone plan is REJECTED" \
  || bad "M1. the live 0/44 capstone plan is REJECTED (rc=$RC: $OUT)"
[ ! -f "$repo/.git/lcars/missions/test-001/plan.json" ] \
  && ok "M1. a rejected plan is not persisted (no advance)" \
  || bad "M1. a rejected plan is not persisted (no advance)"

# --- M2: the SAME plan corrected → ACCEPTED --------------------------------
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/capstone-corrected.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M2. the corrected capstone plan ADVANCES" \
  || bad "M2. the corrected capstone plan ADVANCES (rc=$RC: $OUT)"

# --- M3: declared true, criteria that never name the mockup → REJECTED ------
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/capstone-declared-no-criterion.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "$MOCK"; } \
  && ok "M3. declared-visual with no naming criterion is REJECTED" \
  || bad "M3. declared-visual with no naming criterion is REJECTED (rc=$RC: $OUT)"

# --- M4: the trivial escape — declare every ticket false → REJECTED ---------
# This fixture KEEPS the mockup-naming criteria and only flips the declarations,
# so it also proves the check keys off the DECLARATION, not off the string.
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/capstone-all-false.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "no ticket"; } \
  && ok "M4. an all-false plan for a mockup Mission is REJECTED" \
  || bad "M4. an all-false plan for a mockup Mission is REJECTED (rc=$RC: $OUT)"

# --- M5: the field left OFF entirely, mockup present → REJECTED ------------
repo="$(new_mission "$MOCK")"; pf="$repo/undeclared.json"
ticket '    "acceptanceCriteria": ["the sidebar renders"],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "changesScreenAppearance"; } \
  && ok "M5. an undeclared ticket on a mockup Mission is REJECTED" \
  || bad "M5. an undeclared ticket on a mockup Mission is REJECTED (rc=$RC: $OUT)"

# --- M6: a NON-BOOLEAN declaration → REJECTED ------------------------------
repo="$(new_mission "$MOCK")"; pf="$repo/nonbool.json"
mticket '"yes"' '["renders per attachment-01.html'"'"'s sidebar"]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "non-boolean"; } \
  && ok "M6. a non-boolean changesScreenAppearance is REJECTED" \
  || bad "M6. a non-boolean changesScreenAppearance is REJECTED (rc=$RC: $OUT)"

# --- M7: a MULTI-LINE criteria array naming the mockup is ACCEPTED ---------
# Parity with the pretty-printed-array regression this file exists for.
repo="$(new_mission "$MOCK")"; pf="$repo/multi.json"
mticket 'true' '[
      "the sidebar renders",
      "the nav reproduces attachment-01.html'"'"'s three items in its order, each with its icon left of the label"
    ]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M7. a multi-line criterion naming the mockup ADVANCES" \
  || bad "M7. a multi-line criterion naming the mockup ADVANCES (rc=$RC: $OUT)"

# --- M8: a false ticket needs NO naming criterion --------------------------
# Two tickets: one true (carrying the reference), one false (carrying none).
repo="$(new_mission "$MOCK")"; pf="$repo/mixed.json"
cat > "$pf" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Reskin the sidebar",
    "description": "Redraw the sidebar nav.",
    "acceptanceCriteria": ["the nav reproduces attachment-01.html's three items, each with its icon left of the label"],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "The nav is the frame."
  },
  {
    "id": "t-002",
    "title": "Add the CSV export endpoint",
    "description": "Serve expenses as CSV. No screen changes.",
    "acceptanceCriteria": ["GET /export.csv returns text/csv with one row per expense"],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": false,
    "rationale": "Export is a server behaviour."
  }
]
JSON
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M8. a non-visual ticket needs no mockup criterion" \
  || bad "M8. a non-visual ticket needs no mockup criterion (rc=$RC: $OUT)"

# --- M12: ESCAPED QUOTES in a sibling criterion must not hide the reference --
# The measured plan carries `data-theme=\"dark\"` in three of its criteria.
# Escaped quotes shift the odd/even parity of a split-on-quote parse, so a naive
# accumulator drops half the criteria text and FALSE-REJECTS an honest plan.
repo="$(new_mission "$MOCK")"; pf="$repo/escaped.json"
mticket 'true' '["the root gets data-theme=\"dark\" and paints on the dark background", "the nav reproduces attachment-01.html'"'"'s three items in that file'"'"'s order"]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M12. escaped quotes do not hide a naming criterion" \
  || bad "M12. escaped quotes do not hide a naming criterion (rc=$RC: $OUT)"

# --- M13: the DESCRIPTION naming the mockup is NOT enough ------------------
# The exact shape of the measured defect, isolated: the plan says the file's
# name in prose and the criteria never do.
repo="$(new_mission "$MOCK")"; pf="$repo/descOnly.json"
cat > "$pf" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Reskin the sidebar",
    "description": "Redraw the sidebar nav. Visual fidelity is judged at Verify; do not import, copy internals of, or ship attachment-01.html.",
    "acceptanceCriteria": ["the sidebar shows exactly three nav items"],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "The nav is the frame."
  }
]
JSON
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "acceptance criterion references the mockup"; } \
  && ok "M13. naming the mockup in the DESCRIPTION does not satisfy the check" \
  || bad "M13. naming the mockup in the DESCRIPTION does not satisfy the check (rc=$RC: $OUT)"

# ===========================================================================
# THE NO-MOCKUP WORLD IS UNTOUCHED. Every non-holodeck Mission in existence
# has no HTML mockup; none of the above may reach it.
# ===========================================================================

# --- M9: NO attachments at all → the 0/44 plan is FINE ---------------------
repo="$(new_mission)"
run_plan_save "$repo" "$FX/capstone-0of44.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M9. no attachments ⇒ the 0/44 plan advances (unchanged)" \
  || bad "M9. no attachments ⇒ the 0/44 plan advances (rc=$RC: $OUT)"

# --- M10: IMAGE + DOC attachments only (no mockup) → the 0/44 plan is FINE --
# The overwhelming majority of missions are pasted screenshots.
repo="$(new_mission attachment-01.png attachment-02.md)"
run_plan_save "$repo" "$FX/capstone-0of44.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M10. screenshots-only ⇒ the 0/44 plan advances (unchanged)" \
  || bad "M10. screenshots-only ⇒ the 0/44 plan advances (rc=$RC: $OUT)"

# --- M11: no mockup + an undeclared ticket → still fine --------------------
repo="$(new_mission attachment-01.png)"; pf="$repo/plain.json"
ticket '    "acceptanceCriteria": ["the thing works"],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M11. no mockup ⇒ changesScreenAppearance stays OPTIONAL" \
  || bad "M11. no mockup ⇒ changesScreenAppearance stays OPTIONAL (rc=$RC: $OUT)"

# ===========================================================================
# THE PROMPT. The planner is told WHY, not just what — it currently produces
# "visual match is judged at Verify" spontaneously, and plan.md's own worked
# example ("visual unobtrusiveness is judged at Verify") is where it learned to.
# The block is emitted ONLY for a Mission carrying a mockup.
# ===========================================================================
mblock_for() { # mission-dir
  LCARS_ATT_TEST_DIR="$1" bash "$SCRIPT" plan-mockup-block-test 2>/dev/null
}

repo="$(new_mission "$MOCK")"
B="$(mblock_for "$repo/.git/lcars/missions/test-001")"
printf '%s' "$B" | grep -q 'changesScreenAppearance' \
  && ok "P1. the prompt names the declared field" \
  || bad "P1. the prompt names the declared field"
printf '%s' "$B" | grep -qF "$MOCK" \
  && ok "P2. the prompt names the mockup file the criteria must reference" \
  || bad "P2. the prompt names the mockup file the criteria must reference"
printf '%s' "$B" | grep -qi 'judged at Verify' \
  && ok "P3. the prompt confronts the 'judged at Verify' belief by name" \
  || bad "P3. the prompt confronts the 'judged at Verify' belief by name"
printf '%s' "$B" | grep -qi 'demo' \
  && ok "P4. the prompt says what Verify actually is (demo day, not the net)" \
  || bad "P4. the prompt says what Verify actually is"
printf '%s' "$B" | grep -qi 'Matches the mockup' \
  && ok "P5. the prompt rejects the vague criterion by example" \
  || bad "P5. the prompt rejects the vague criterion by example"

# no mockup ⇒ NO block at all, so a non-holodeck Plan prompt is byte-identical.
repo="$(new_mission attachment-01.png)"
[ -z "$(mblock_for "$repo/.git/lcars/missions/test-001")" ] \
  && ok "P6. screenshots-only ⇒ EMPTY block (prompt byte-identical)" \
  || bad "P6. screenshots-only ⇒ EMPTY block"
repo="$(new_mission)"
[ -z "$(mblock_for "$repo/.git/lcars/missions/test-001")" ] \
  && ok "P7. no attachments ⇒ EMPTY block (prompt byte-identical)" \
  || bad "P7. no attachments ⇒ EMPTY block"

echo
printf 'plan-validator: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
