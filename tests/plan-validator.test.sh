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
    for a in "$@"; do
      case "$a" in
        # S174 round 3: a MOCKUP is staged with the REAL drawing's element ids,
        # because `drawnAt` must now cite one of them. These twelve are the ids
        # of the actual attachment-01.html of lcars-20260814-001, so a fixture
        # anchored at #screen-builder here means what it means there. Use
        # new_mission_blank_mockup for the zero-id (unfenced) path.
        *.html) cat > "$repo/.git/lcars/missions/test-001/attachments/$a" <<'HTML'
<!doctype html><html><body>
<section id="screen-start"><div id="pullBar"></div><button id="continueBtn"></button></section>
<section id="screen-collect"><ul id="collect-list"></ul><div id="bulkBar"></div></section>
<section id="screen-builder"><button id="automateBtn"></button><button id="themeBtn"></button></section>
<div id="modal-lock"></div><div id="modal-unlock"></div><div id="modal-discard"></div>
</body></html>
HTML
          ;;
        *) printf 'x' > "$repo/.git/lcars/missions/test-001/attachments/$a" ;;
      esac
    done
  fi
  echo "$repo"
}

# A mission whose mockup carries NO element ids at all — the graceful-degradation
# path. The membership rule cannot run, so round 2's form-only check stands.
new_mission_blank_mockup() {
  local repo; repo="$(new_mission)"
  mkdir -p "$repo/.git/lcars/missions/test-001/attachments"
  printf '<!doctype html><html><body><div class="card">no ids here</div></body></html>' \
    > "$repo/.git/lcars/missions/test-001/attachments/attachment-01.html"
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
#
# ⚠ THIS FIXTURE'S VERDICT CHANGED IN S174, ON PURPOSE. `capstone-corrected.json`
# is the S169 artifact and it is kept byte-identical: each of its visual tickets
# carries ONE criterion naming the mockup and several that name nothing. That
# satisfied S169's "at least one" rule — and "at least one" is precisely the hole
# S174 closes (t-012 satisfied it and invented an affordance in the criterion
# next door). So the S169-corrected plan is now REJECTED, and it is kept here as
# the regression that proves the hole is shut. `capstone-corrected-174.json` is
# the same plan brought up to the new contract, and it is what ADVANCES.
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/capstone-corrected.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "criterion"; } \
  && ok "M2. the S169-corrected plan is REJECTED now (at-least-one is shut)" \
  || bad "M2. the S169-corrected plan is REJECTED now (rc=$RC: $OUT)"

repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/capstone-corrected-174.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "M2b. the same plan under the S174 contract ADVANCES" \
  || bad "M2b. the same plan under the S174 contract ADVANCES (rc=$RC: $OUT)"

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
      {"text": "arrow keys move focus down the nav list", "notVisual": true},
      {"text": "the nav shows its three items in that order, each with its icon left of the label",
       "drawnAt": "#screen-builder, the nav list"}
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
    "acceptanceCriteria": [{"text": "the nav shows three items, each with its icon left of the label", "drawnAt": "#screen-builder, the nav list"}],
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
mticket 'true' '[{"text": "the root gets data-theme=\"dark\" and paints on the dark page background", "drawnAt": "#screen-builder, the page background"}, {"text": "the nav shows its three items in that order", "drawnAt": "#screen-builder, the nav list"}]' > "$pf"
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
    "acceptanceCriteria": [{"text": "the sidebar shows exactly three nav items", "notVisual": true}],
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
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "description does not count"; } \
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

# ===========================================================================
# S174 — EVERY CRITERION DECLARES WHERE IT CAME FROM
#
# S169 closed "no criterion names the mockup" and left "AT LEAST ONE does".
# That hole is measured. On DX-Scorecard mission lcars-20260814-001 the real
# ticket t-012 declared changesScreenAppearance:true with three criteria: #1
# named attachment-01.html (satisfying the whole S169 rule), #2 was silent, and
# #3 INVENTED a sub-value CRUD editor — a toggle, a stack of label+value input
# pairs, a Remove per row, an Add sub-value — where the drawing shows read-only
# cohort text and one compact inline input. It shipped, fully styled, past every
# gate. No existence check can catch it: it EXISTS.
#
# ROUND 1 TRIED A STRING RULE (name the file + an anchor abutting it, or the
# literal marker "NOT DRAWN:"). A fresh tester beat it three ways in half an
# hour, and all three are regressions below:
#   D1  one sed appending "(attachment-01.html's screen)" to all 38 criteria of
#       the real plan passed the whole thing with the invention intact;
#   D2  "NOT DRAWN:" matched ANYWHERE, so burying it at the END of an invention
#       passed AND laundered that invention onto the captain's Verify list as a
#       one-word entry — a BETTER smuggling route than before the round;
#   D3  the "free text" anchor was really a word-order rule: a comma or a
#       parenthesis killed it, and 5 of 7 honest phrasings were rejected.
# One root cause: a text search cannot tell a planner who opened the drawing
# from one who pasted a filename.
#
# So the declaration moved OUT of the sentence. On a changesScreenAppearance:
# true ticket of a mockup Mission each entry is an OBJECT carrying its text and
# EXACTLY ONE of:
#     "drawnAt":   "<where in the drawing>"
#     "notDrawn":  "<why this VISIBLE thing is not in the drawing>"
#     "notVisual": true
# No suffix, paste or word order can fill a slot that is not in the string, and
# nothing can be buried mid-text because it is not in the text. `notVisual` is
# what keeps the captain's Verify list readable — see part C.
#
# SCOPE BOUND, deliberate: a plain string stays legal and preferred on every
# false ticket, on every Mission with no mockup, and everywhere else.
#
# The fixtures are the real thing: `t-012-verbatim.json` is that ticket copied
# out of the mission's approved-plan.json (only its dependency on the absent
# t-011 dropped so it stands alone) and `mbr-approved-plan.json` is the whole
# 13-ticket approved plan, byte for byte.
# ===========================================================================

# --- S1: the REAL t-012, verbatim → REJECTED, naming ticket and criteria ----
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-verbatim.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "t-012"; } \
  && ok "S1. the real t-012 is REJECTED and the ticket is named" \
  || bad "S1. the real t-012 is REJECTED and the ticket is named (rc=$RC: $OUT)"
printf '%s' "$OUT" | grep -qF "criterion 3" \
  && ok "S1. the rejection names the INVENTED criterion (3)" \
  || bad "S1. the rejection names the INVENTED criterion (3): $OUT"
printf '%s' "$OUT" | grep -qF "ManualValueEditor" \
  && ok "S1. the rejection quotes the offending criterion back (actionable)" \
  || bad "S1. the rejection quotes the offending criterion back: $OUT"
for want in drawnAt notDrawn notVisual; do
  printf '%s' "$OUT" | grep -qF "$want" \
    && ok "S1. the rejection names the way out: $want" \
    || bad "S1. the rejection names the way out: $want"
done
[ ! -f "$repo/.git/lcars/missions/test-001/plan.json" ] \
  && ok "S1. the rejected plan is not persisted (no advance)" \
  || bad "S1. the rejected plan is not persisted (no advance)"

# --- S2: the same ticket DECLARED → ACCEPTED -------------------------------
# One of each: criterion 1 drawnAt, criterion 2 notVisual, criterion 3 — the
# invention — notDrawn.
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-declared.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S2. t-012 with all three declarations ADVANCES" \
  || bad "S2. t-012 with all three declarations ADVANCES (rc=$RC: $OUT)"

# --- S3: zero / two / blank declarations → REJECTED ------------------------
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-two-declarations.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "2 declarations"; } \
  && ok "S3. a criterion carrying TWO declarations is REJECTED" \
  || bad "S3. a criterion carrying TWO declarations is REJECTED (rc=$RC: $OUT)"

repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-blank-anchor.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "is blank"; } \
  && ok "S3. a BLANK drawnAt is REJECTED (a slot is not a declaration)" \
  || bad "S3. a BLANK drawnAt is REJECTED (rc=$RC: $OUT)"

# ROUND 3 — a slot that real JSON says is EMPTY is not an anchor. `blank()` was
# a byte check, so null / true / 0 / "\t" / "\n" all read as content and all
# five PASSED as anchors. The value must be a non-empty STRING.
for bad in 'null' 'true' 'false' '0' '[]' '{"screen": "b"}' '"\t"' '"\n"' '"  "'; do
  repo="$(new_mission "$MOCK")"; pf="$repo/typed.json"
  mticket 'true' "[{\"text\": \"the cell renders\", \"drawnAt\": \"#screen-builder\"}, {\"text\": \"and this one\", \"drawnAt\": $bad}]" > "$pf"
  run_plan_save "$repo" "$pf"
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "criterion 2"; } \
    && ok "S3/R3. drawnAt: $bad is REJECTED" \
    || bad "S3/R3. drawnAt: $bad is REJECTED (rc=$RC: $OUT)"
done
# …and the message says WHY, in the planner's own terms.
repo="$(new_mission "$MOCK")"; pf="$repo/typed2.json"
mticket 'true' '[{"text": "the cell renders", "drawnAt": "#screen-builder"}, {"text": "and this one", "drawnAt": null}]' > "$pf"
run_plan_save "$repo" "$pf"
printf '%s' "$OUT" | grep -q "must be a quoted string" \
  && ok "S3/R3. …and the rejection names the TYPE problem" \
  || bad "S3/R3. the rejection names the TYPE problem: $OUT"
# notDrawn is held to the same type rule (a null reason produced an empty Verify entry).
repo="$(new_mission "$MOCK")"; pf="$repo/ndnull.json"
mticket 'true' '[{"text": "the cell renders", "drawnAt": "#screen-builder"}, {"text": "an editor", "notDrawn": null}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "must be a quoted string"; } \
  && ok "S3/R3. notDrawn: null is REJECTED (no empty Verify entries)" \
  || bad "S3/R3. notDrawn: null is REJECTED (rc=$RC: $OUT)"

repo="$(new_mission "$MOCK")"; pf="$repo/notrue.json"
mticket 'true' '[{"text": "the cell renders", "drawnAt": "#screen-builder"}, {"text": "it persists", "notVisual": "sure"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "bare value true"; } \
  && ok "S3. notVisual must be the bare true, not a string" \
  || bad "S3. notVisual must be the bare true (rc=$RC: $OUT)"

repo="$(new_mission "$MOCK")"; pf="$repo/notext.json"
mticket 'true' '[{"text": "the cell renders", "drawnAt": "#screen-builder"}, {"drawnAt": "#screen-start"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no "text"'; } \
  && ok "S3. a criterion with no text is REJECTED (the Implementer builds on it)" \
  || bad "S3. a criterion with no text is REJECTED (rc=$RC: $OUT)"

# --- S4: THE THREE MEASURED BYPASSES, on the WHOLE real plan ---------------
# Each is one sed a planner (or a model) could apply in a second. Under the
# string rule the first two PASSED the entire 13-ticket plan and the third
# passed AND laundered the invention onto the Verify list.
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/bypass-suffix.json"
[ "$RC" -ne 0 ] \
  && ok "S4/D1. the one-sed suffix \"(<mockup>'s screen)\" is REJECTED" \
  || bad "S4/D1. the one-sed suffix \"(<mockup>'s screen)\" is REJECTED (rc=$RC)"
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/bypass-junk-anchor.json"
[ "$RC" -ne 0 ] \
  && ok "S4/D3. the junk anchor \"<mockup>'s x\" is REJECTED" \
  || bad "S4/D3. the junk anchor \"<mockup>'s x\" is REJECTED (rc=$RC)"
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/bypass-buried-marker.json"
[ "$RC" -ne 0 ] \
  && ok "S4/D2. a buried \"NOT DRAWN: minor\" is REJECTED (it is not a field)" \
  || bad "S4/D2. a buried \"NOT DRAWN: minor\" is REJECTED (rc=$RC)"

# --- S5: the anchor is a PUBLISHED vocabulary, not a closed guess ----------
# Round 1 shipped an undocumented word-order rule and 5 of 7 honest phrasings
# were rejected. Round 3 publishes the drawing's own element ids to the planner
# and to every rejection message, and the citation may sit anywhere in whatever
# wording the planner likes. These are the seven phrasings a real planner writes.
while IFS= read -r a; do
  [ -n "$a" ] || continue
  repo="$(new_mission "$MOCK")"; pf="$repo/anchor.json"
  mticket 'true' "[{\"text\": \"The value cell renders every sub-reading\", \"drawnAt\": \"$a\"}]" > "$pf"
  run_plan_save "$repo" "$pf"
  { [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
    && ok "S5. honest phrasing accepted: $a" \
    || bad "S5. honest phrasing accepted: $a (rc=$RC: $OUT)"
done <<'ANCHORS'
#screen-builder cohort row
screen-builder, the cohort value cell
the cohort row in #screen-builder
section #screen-builder, right column
the cohort value cell of a KPI row (screen-builder)
screen-builder — right column, under the value
builder -> KPI row -> value cell in screen-builder
ANCHORS

# --- S5b: THE CAPTAIN'S OWN jq ATTACK --------------------------------------
# One line beat round 2 completely:
#   jq 'map(if .changesScreenAppearance then .acceptanceCriteria |=
#           map({text: ., drawnAt: "the builder screen"}) else . end)'
# 38 criteria, ONE distinct anchor, t-012's invention byte-unchanged, Verify list
# EMPTY, "PLAN: advanced". A free-text slot is a free-text sentence with extra
# steps, so the anchor now has to name a place the drawing HAS.
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-constant-anchor.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "names no place in the drawing"; } \
  && ok "S5b. the constant anchor \"the builder screen\" is REJECTED" \
  || bad "S5b. the constant anchor is REJECTED (rc=$RC: $OUT)"
# A rejection must ALWAYS show the legal answers — that is what round 1's closed
# vocabulary got wrong, and it is not optional.
printf '%s' "$OUT" | grep -q "The places this drawing actually has" \
  && ok "S5b. the rejection LISTS the drawing's place names" \
  || bad "S5b. the rejection lists the place names: $OUT"
for want in screen-builder screen-start modal-lock collect-list; do
  printf '%s' "$OUT" | grep -qF "$want" \
    && ok "S5b. …including $want" \
    || bad "S5b. …including $want"
done

# --- S5c: whole-token membership, not a substring sweep --------------------
# `screen-collect` and `collect-list` overlap on the word "collect"; a naive
# index() would let either satisfy a citation of the other, or find a name
# inside a longer word.
repo="$(new_mission "$MOCK")"; pf="$repo/tok.json"
mticket 'true' '[{"text": "the list renders", "drawnAt": "the collect-list rows"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ]; } \
  && ok "S5c. collect-list is accepted on its own name" \
  || bad "S5c. collect-list is accepted on its own name (rc=$RC: $OUT)"
repo="$(new_mission "$MOCK")"; pf="$repo/tok2.json"
mticket 'true' '[{"text": "the list renders", "drawnAt": "the screen-builders panel"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ]; } \
  && ok "S5c. a place name inside a LONGER word does not count" \
  || bad "S5c. a place name inside a longer word does not count (rc=$RC)"
repo="$(new_mission "$MOCK")"; pf="$repo/tok3.json"
mticket 'true' '[{"text": "the list renders", "drawnAt": "the pre-screen-builder area"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ]; } \
  && ok "S5c. a place name suffixed onto another token does not count" \
  || bad "S5c. a place name suffixed onto another token does not count (rc=$RC)"

# --- S5d: GRACEFUL DEGRADATION — a drawing with NO ids ---------------------
# It cannot be fenced, so round 2's form-only check stands: a non-empty string
# passes. It must NOT silently pass a blank one, and it must NOT hard-fail the
# mission. Both the planner prompt and the Verify readout say so out loud.
repo="$(new_mission_blank_mockup)"; pf="$repo/unfenced.json"
mticket 'true' '[{"text": "The value cell renders", "drawnAt": "the builder screen"}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S5d. a no-id drawing falls back to the form-only check (ADVANCES)" \
  || bad "S5d. a no-id drawing falls back to form-only (rc=$RC: $OUT)"
repo="$(new_mission_blank_mockup)"; pf="$repo/unfenced2.json"
mticket 'true' '[{"text": "The value cell renders", "drawnAt": "   "}]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ]; } \
  && ok "S5d. …but a BLANK anchor is still REJECTED there" \
  || bad "S5d. a blank anchor is still rejected on a no-id drawing (rc=$RC)"
repo="$(new_mission_blank_mockup)"
B0="$(mblock_for "$repo/.git/lcars/missions/test-001")"
printf '%s' "$B0" | grep -q "UNFENCED" \
  && ok "S5d. the PROMPT says the anchors go unfenced" \
  || bad "S5d. the prompt says the anchors go unfenced"
repo="$(new_mission "$MOCK")"
B1="$(mblock_for "$repo/.git/lcars/missions/test-001")"
printf '%s' "$B1" | grep -q "UNFENCED" \
  && bad "S5d. a FENCED drawing must not carry the unfenced note" \
  || ok "S5d. a fenced drawing does not carry the unfenced note"
printf '%s' "$B1" | grep -q "The places in" \
  && ok "S5d. …it publishes the vocabulary instead" \
  || bad "S5d. it publishes the vocabulary instead"
for want in screen-builder collect-list themeBtn; do
  printf '%s' "$B1" | grep -qF "$want" \
    && ok "S5d. the planner is shown the place name $want" \
    || bad "S5d. the planner is shown the place name $want"
done

# --- S6: a screen-changing ticket must be drawn SOMEWHERE ------------------
# The S169 rule survives the schema change, restated in it. Without it every
# criterion could be notVisual and the whole screen declared away.
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-nothing-drawn.json"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "drawnAt"; } \
  && ok "S6. a true ticket with NO drawnAt anywhere is REJECTED" \
  || bad "S6. a true ticket with NO drawnAt anywhere is REJECTED (rc=$RC: $OUT)"
printf '%s' "$OUT" | grep -q "description does not count" \
  && ok "S6. …and the description still does not count" \
  || bad "S6. …and the description still does not count: $OUT"

# --- S7: a changesScreenAppearance:FALSE ticket is untouched ---------------
# Plain strings, no declarations, nothing. This is most of the world.
repo="$(new_mission "$MOCK")"; pf="$repo/falseticket.json"
cat > "$pf" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Reskin the sidebar",
    "description": "Redraw the sidebar nav.",
    "acceptanceCriteria": [{"text": "the nav shows three items, icon left of the label", "drawnAt": "#screen-builder, the nav list"}],
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
    "description": "Serve expenses as CSV.",
    "acceptanceCriteria": ["GET /export.csv returns text/csv", "a malformed range returns 400", "the handler streams rather than buffering"],
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
  && ok "S7. a false ticket's PLAIN STRINGS are untouched by the rule" \
  || bad "S7. a false ticket's PLAIN STRINGS are untouched (rc=$RC: $OUT)"

# --- S8: NO MOCKUP ⇒ the whole rule is inert -------------------------------
repo="$(new_mission)"
run_plan_save "$repo" "$FX/t-012-verbatim.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S8. no mockup ⇒ t-012 advances (pre-174 behaviour, unchanged)" \
  || bad "S8. no mockup ⇒ t-012 advances (rc=$RC: $OUT)"
repo="$(new_mission attachment-01.png attachment-02.md)"
run_plan_save "$repo" "$FX/mbr-approved-plan.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S8. screenshots+doc only ⇒ the whole real plan advances (unchanged)" \
  || bad "S8. screenshots+doc only ⇒ the real plan advances (rc=$RC: $OUT)"

# --- S9: D4 — EVERY offending ticket in ONE message ------------------------
# The round-1 validator fail()ed on the first offending TICKET. On the real plan
# 12 of 12 screen-changing tickets offend, so a Plan worker fixing one per bounce
# hits MAX_WORKER_TRIES=3 and the Stage DEADLOCKS ("failed validation after 3
# attempt(s)"). A plan is rewritten in one pass; this is the wrong axis to fail
# fast on.
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/mbr-approved-plan.json"
NT="$(printf '%s' "$OUT" | grep -c '^  ticket ')"
{ [ "$RC" -ne 0 ] && [ "$NT" -eq 12 ]; } \
  && ok "S9/D4. all 12 offending tickets are reported in ONE message" \
  || bad "S9/D4. all 12 offending tickets in one message (rc=$RC, tickets named=$NT)"
printf '%s' "$OUT" | grep -qF "t-013" \
  && ok "S9/D4. …including the LAST one (not just the first)" \
  || bad "S9/D4. …including the LAST one: $OUT"

# --- S10: the whole real plan, DECLARED → ACCEPTED -------------------------
repo="$(new_mission "$MOCK" attachment-02.md)"
run_plan_save "$repo" "$FX/mbr-approved-plan-declared.json"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S10. the real 13-ticket plan, declared, ADVANCES" \
  || bad "S10. the real 13-ticket plan, declared, ADVANCES (rc=$RC: $OUT)"

# --- S11: MIXED FORMS and a MULTI-LINE array -------------------------------
# The pretty-printed array is what this file was originally written for, and the
# entry parser must survive escaped quotes inside a criterion's text (the
# measured plan carries data-theme=\"dark\" in three of them) without shifting
# the criterion INDEX.
repo="$(new_mission "$MOCK")"; pf="$repo/multi.json"
mticket 'true' '[
      {"text": "the root gets data-theme=\"dark\" and paints on the dark background",
       "drawnAt": "#screen-builder, the page background"},
      {"text": "the choice survives a reload", "notVisual": true},
      {"text": "an Add sub-value button sits under the value", "notDrawn": "the drawing has no editor here"}
    ]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "S11. a MULTI-LINE object array with escaped quotes ADVANCES" \
  || bad "S11. a MULTI-LINE object array with escaped quotes ADVANCES (rc=$RC: $OUT)"

repo="$(new_mission "$MOCK")"; pf="$repo/mixed.json"
mticket 'true' '[{"text": "the cell renders", "drawnAt": "#screen-builder"}, "a bare string snuck in beside the objects"]' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "criterion 2"; } \
  && ok "S11. a PLAIN STRING on a true ticket is caught, by index" \
  || bad "S11. a PLAIN STRING on a true ticket is caught, by index (rc=$RC: $OUT)"

# --- S12: THE KNOWN LIMIT, stated as a test -------------------------------
# A visible control mislabelled `notVisual` PASSES. The schema cannot see it,
# and it is deliberately not guessed at from the prose — that is a classifier,
# and a classifier is what this whole design replaced. Plan Review is told to
# hunt exactly this (part B), and the fixture exists so the limit is measured
# rather than assumed.
repo="$(new_mission "$MOCK")"
run_plan_save "$repo" "$FX/t-012-notvisual-lie.json"
[ "$RC" -eq 0 ] \
  && ok "S12. KNOWN LIMIT: an invention mislabelled notVisual is NOT caught here" \
  || bad "S12. KNOWN LIMIT fixture changed behaviour unexpectedly (rc=$RC: $OUT)"

# --- S13: the CONTRACT PROSE teaches the schema ----------------------------
repo="$(new_mission "$MOCK")"
B="$(mblock_for "$repo/.git/lcars/missions/test-001")"
for want in '"drawnAt"' '"notDrawn"' '"notVisual"' 'EXACTLY ONE'; do
  printf '%s' "$B" | grep -qF "$want" \
    && ok "S13. the prompt teaches $want" \
    || bad "S13. the prompt teaches $want"
done
printf '%s' "$B" | grep -qi 'not a loophole' \
  && ok "S13. the prompt says plainly notDrawn is not a loophole" \
  || bad "S13. the prompt says plainly notDrawn is not a loophole"
printf '%s' "$B" | grep -qi 'Verify' \
  && ok "S13. the prompt says every notDrawn is surfaced at Verify" \
  || bad "S13. the prompt says every notDrawn is surfaced at Verify"
printf '%s' "$B" | grep -qi 'plain string' \
  && ok "S13. the prompt states the scope bound (plain strings stay legal)" \
  || bad "S13. the prompt states the scope bound"

# ===========================================================================
# S174 — THE CONSUMER CONTRACT: an object criterion RENDERS AS ITS TEXT
#
# THE BIGGEST RISK IN THIS ROUND. Every consumer of acceptanceCriteria used to
# read the array by splitting the line on double quotes and taking every other
# field. Fed {"text": "…", "drawnAt": "…"} that yields
#     text | A manual cohort is edited… | drawnAt | #screen-builder…
# — the KEYS render as criteria. Silently. The Implementer would then build
# against a mangled spec with every gate still green, which is precisely the
# class of failure this whole round exists to stop.
#
# So there is ONE normalizer ($LCARS_AWK_CRIT in run.sh) and every consumer
# calls it. These cases prove the EQUIVALENCE that protects the Implementer: the
# same criterion, written as a string and as an object, renders identically.
# ===========================================================================
CONSUME="$TMPROOT/consume"; mkdir -p "$CONSUME"
CTEXT="The value cell renders every sub-reading with its own delta arrow"

# Two plans that differ ONLY in the FORM of the criteria: same texts, one plain,
# one object. Every consumer must render them the same.
consumer_plan() { # form(string|object) outfile
  if [ "$1" = string ]; then
    cat > "$2" <<JSON
[
  {
    "id": "t-001",
    "title": "Render the value cell",
    "description": "Draw it.",
    "acceptanceCriteria": ["$CTEXT", "It persists across a reload"],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "r"
  }
]
JSON
  else
    cat > "$2" <<JSON
[
  {
    "id": "t-001",
    "title": "Render the value cell",
    "description": "Draw it.",
    "acceptanceCriteria": [{"text": "$CTEXT", "drawnAt": "#screen-builder cohort value cell"}, {"text": "It persists across a reload", "notVisual": true}],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "r"
  }
]
JSON
  fi
}
consumer_plan string "$CONSUME/str.json"
consumer_plan object "$CONSUME/obj.json"

# The consumers are sourced from run.sh itself, so this exercises the SHIPPING
# functions, not a copy of them.
consumer_probe() { # plan-file  -> prints one section per consumer
  LCARS_CONSUMER_PLAN="$1" bash "$SCRIPT" consumer-probe-test 2>/dev/null
}
CS="$(consumer_probe "$CONSUME/str.json")"
CO="$(consumer_probe "$CONSUME/obj.json")"

[ -n "$CS" ] && [ -n "$CO" ] \
  && ok "N0. the consumer probe produced output for both forms" \
  || bad "N0. the consumer probe produced output for both forms (str=${#CS} obj=${#CO})"
[ "$CS" = "$CO" ] \
  && ok "N1. EVERY consumer renders the object form IDENTICALLY to the string form" \
  || bad "N1. consumer outputs DIFFER:
--- string ---
$CS
--- object ---
$CO"
printf '%s' "$CO" | grep -qF "$CTEXT" \
  && ok "N2. the criterion TEXT itself reaches the consumers" \
  || bad "N2. the criterion TEXT itself reaches the consumers: $CO"
printf '%s' "$CO" | grep -q 'drawnAt' \
  && bad "N3. a DECLARATION KEY leaked into a rendered consumer: $CO" \
  || ok "N3. no declaration key (drawnAt/notVisual) leaks into any consumer"
printf '%s' "$CO" | grep -qx 'text' \
  && bad "N3. the literal key \"text\" rendered as a criterion: $CO" \
  || ok "N3. the literal key \"text\" never renders as a criterion"

# The Implementer's inlined ticket spec is the one that would be catastrophic:
# a worker building against `- text` and `- drawnAt` passes every gate.
printf '%s' "$CO" | grep -qF -- "- $CTEXT" \
  && ok "N4. the IMPLEMENTER's ticket spec lists the criterion as plain text" \
  || bad "N4. the IMPLEMENTER's ticket spec lists the criterion as plain text: $CO"

# The advisory slice-pressure count must count ENTRIES, not quoted strings.
printf '%s' "$CO" | grep -q 'slice-rows: t-001	Render the value cell	2	10' \
  && ok "N5. the slice-pressure row counts 2 criteria, not 4 quoted strings" \
  || bad "N5. slice-pressure row counts entries: $(printf '%s' "$CO" | grep slice-rows)"

# ===========================================================================
# S174 PART B — THE AUDITOR SEES THE DRAWING
#
# Plan Review is the one stage whose whole job is auditing the ticket set, and
# it was the one stage that could not open the drawing the tickets claim to
# reproduce. It gets attachments_extra_block now — and the instruction to hunt
# for (i) a criterion introducing a control the drawing does not contain that
# is not marked NOT DRAWN, and (ii) a screen the DECLARED FLOW names that no
# ticket owns the look of.
#
# Its deliberate BLINDNESS to prd.md / validated-plan.md is preserved: it
# reviews TICKETS. The mockup is not a brief; it is the drawing.
# ===========================================================================
PRWORK="$TMPROOT/prbin"; mkdir -p "$PRWORK"
# Named `claude` because the worker ADAPTER dispatches on the binary's basename;
# an unknown cli produces no argv and the Stage dies before a prompt exists.
# It is a recording stub on an absolute path — nothing on $PATH is spawned.
cat > "$PRWORK/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$prompt" > "$PR_PROMPT_OUT"
printf '{ "passed": true, "issues": [] }\n' > "$LCARS_WORK_OUT/verdict.json"
exit 0
EOF
chmod +x "$PRWORK/claude"

# Drive the REAL plan-review Stage against that stub and leave the prompt the
# reviewer was handed in $PR_OUT (and its mission dir in $PR_MDIR). Assigned as
# GLOBALS, deliberately: a `$(…)` capture would lose them, and a later `set -u`
# miss inside a pipeline subshell runs this file's own EXIT trap.
PR_OUT=""; PR_MDIR=""
pr_prompt() { # [attachment-basename …]
  local repo; repo="$(new_mission "$@")"
  local md="$repo/.git/lcars/missions/test-001"
  cat > "$md/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan-review" }
JSON
  cat > "$md/plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Reskin the sidebar",
    "description": "Redraw the sidebar nav.",
    "acceptanceCriteria": ["the nav reproduces attachment-01.html's nav list"],
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
  local pf="$repo/prompt.txt"; : > "$pf"
  PR_MDIR="$md"
  # One try: the assertions are about the PROMPT, which is recorded on the first
  # spawn — the default 3 retries would triple this suite's wall clock for nothing.
  ( cd "$repo" && PR_PROMPT_OUT="$pf" LCARS_WORKER_BIN="$PRWORK/claude" \
      LCARS_WORKER_TRIES=1 \
      LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      bash "$SCRIPT" plan-review --mission test-001 >/dev/null 2>&1 )
  PR_OUT="$(cat "$pf")"
}

pr_prompt "$MOCK"
printf '%s' "$PR_OUT" | grep -qF "/attachments/$MOCK" \
  && ok "B1. Plan Review's prompt carries the mockup's ABSOLUTE path" \
  || bad "B1. Plan Review's prompt carries the mockup's ABSOLUTE path"
printf '%s' "$PR_OUT" | grep -qF 'drawnAt' \
  && ok "B2. the reviewer is told to hunt a drawnAt that is not true" \
  || bad "B2. the reviewer is told to hunt a drawnAt that is not true"
printf '%s' "$PR_OUT" | grep -qi 'DECLARED FLOW' \
  && ok "B3. the reviewer is told to hunt a screen NO ticket owns the look of" \
  || bad "B3. the reviewer is told to hunt a screen NO ticket owns the look of"
# B7 (D6). The shared attachment note carries the brief-vs-mockup tie-break,
# because the Stages that DO get a brief share it. This Stage does not, and
# being told "the brief OVERRIDES the mockup" twelve lines after being told it
# may not read the brief is incoherent. The block says so, without touching the
# blindness itself.
printf '%s' "$PR_OUT" | grep -qi 'no brief' \
  && ok "B7/D6. the reviewer is told it has NO brief in this Stage" \
  || bad "B7/D6. the reviewer is told it has NO brief in this Stage"
# B8. The one lie the schema cannot catch is handed to the only thing that can.
printf '%s' "$PR_OUT" | grep -qF 'notVisual' \
  && ok "B8. the reviewer is told to hunt a notVisual that is plainly visual" \
  || bad "B8. the reviewer is told to hunt a notVisual that is plainly visual"
printf '%s' "$PR_OUT" | grep -qF "$PR_MDIR/prd.md" \
  && bad "B4. Plan Review must stay BLIND to prd.md" \
  || ok "B4. Plan Review stays BLIND to prd.md (independence preserved)"
printf '%s' "$PR_OUT" | grep -qF "$PR_MDIR/validated-plan.md" \
  && bad "B4. Plan Review must stay BLIND to validated-plan.md" \
  || ok "B4. Plan Review stays BLIND to validated-plan.md"

# No attachments at all ⇒ nothing new in the prompt. This is every non-holodeck
# mission in the world; its reviewer prompt must not move by one character.
pr_prompt
printf '%s' "$PR_OUT" | grep -qi 'attached' \
  && bad "B5. no attachments ⇒ NO attachment block in the reviewer prompt" \
  || ok "B5. no attachments ⇒ NO attachment block in the reviewer prompt"
printf '%s' "$PR_OUT" | grep -qF 'notDrawn' \
  && bad "B5. no mockup ⇒ NO mockup-hunt block in the reviewer prompt" \
  || ok "B5. no mockup ⇒ NO mockup-hunt block in the reviewer prompt"

# A screenshots-only mission DOES get its screenshots (that is S92, unchanged)
# but must NOT get the mockup-hunt instruction — there is no drawing to hunt in.
pr_prompt attachment-01.png
printf '%s' "$PR_OUT" | grep -qF "/attachments/attachment-01.png" \
  && ok "B6. screenshots reach the reviewer too (S92 parity)" \
  || bad "B6. screenshots reach the reviewer too (S92 parity)"
printf '%s' "$PR_OUT" | grep -qF 'notDrawn' \
  && bad "B6. screenshots-only ⇒ NO mockup-hunt block" \
  || ok "B6. screenshots-only ⇒ NO mockup-hunt block"


# ===========================================================================
# S174 PART C — THE CAPTAIN SEES WHAT WAS INVENTED
#
# Every criterion the planner DECLARED `notDrawn` is collected into its own
# short list at Verify, its OWN TEXT first and the reason beneath — round 1
# printed the reason alone, and a tester smuggled an invention in as
# "⊘ t-001 · minor". `notVisual` criteria are deliberately absent: on the real
# plan 21 of 38 were persistence and test-hygiene trivia, and a list that long
# is one the captain scrolls past.
#
# The un-drawn surface is not a footnote — it is where
# the bug was. On the mission that produced this round, `screen-preview` and
# `screen-locked` appear ZERO times in the mockup: the preview screen was never
# drawn, was never named in DECLARED FLOW, and shipped an unanswered open
# question — and that is exactly where the composite-KPI value cell came out
# scrambled. These are the surfaces nobody judged.
# ===========================================================================
verify_out() { # plan.json-content -> echoes the verify summary
  local repo; repo="$(new_mission "$MOCK")"
  local md="$repo/.git/lcars/missions/test-001"
  cat > "$md/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "MBR builder", "stage": "verify" }
JSON
  cat > "$md/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-012",
        "issue": null
      }
    ]
  }
]
JSON
  mkdir -p "$md/tickets/t-012"
  printf '{ "ticketId": "t-012", "passed": true, "attempts": 1 }\n' > "$md/tickets/t-012/result.json"
  cp "$1" "$md/plan.json"
  ( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      bash "$SCRIPT" verify-summary --mission test-001 2>&1 )
}


V="$(verify_out "$FX/mbr-approved-plan-declared.json")"
printf '%s' "$V" | grep -qi 'not in your drawing' \
  && ok "C1. Verify lists what was built but not drawn" \
  || bad "C1. Verify lists what was built but not drawn: $V"
printf '%s' "$V" | grep -qF 't-012' \
  && ok "C1. the list names the ticket" \
  || bad "C1. the list names the ticket: $V"
printf '%s' "$V" | grep -qF 'ManualValueEditor' \
  && ok "C1. THE CRITERION'S OWN TEXT leads the entry (not the excuse)" \
  || bad "C1. the criterion's own text leads the entry: $V"
printf '%s' "$V" | grep -qi 'read-only text' \
  && ok "C1. …with the planner's stated reason beneath it" \
  || bad "C1. the planner's stated reason is shown: $V"
printf '%s' "$V" | grep -qi 'nobody judged' \
  && ok "C2. the heading carries the lesson (nobody judged these)" \
  || bad "C2. the heading carries the lesson (nobody judged these): $V"
printf '%s' "$V" | grep -qi 'open these FIRST' \
  && ok "C2. the heading tells the captain to open them FIRST" \
  || bad "C2. the heading tells the captain to open them FIRST: $V"

# THE PAYOFF, measured on the real plan: notVisual keeps the list SHORT enough
# to read. 38 criteria on 12 screen-changing tickets, 21 of them notVisual
# (persistence, derivations, "the tests stay green") — and the list the captain
# gets is ONE entry, the invention that caused this round.
NENT="$(printf '%s' "$V" | grep -c '⊘ ')"
[ "$NENT" -eq 1 ] \
  && ok "C3. the real plan's Verify list is ONE entry — the invention, findable" \
  || bad "C3. the real plan's Verify list is ONE entry (got $NENT): $V"

# NONE ⇒ the block is ABSENT ENTIRELY: a clean mission's Verify output is
# byte-identical to before this round.
V2="$(verify_out "$FX/capstone-corrected-174.json")"
printf '%s' "$V2" | grep -qi 'drawing' \
  && bad "C4. no notDrawn criteria ⇒ NO block at all: $V2" \
  || ok "C4. no notDrawn criteria ⇒ NO block at all (byte-identical)"
printf '%s' "$V2" | grep -q 'Test results:' \
  && ok "C4. the rest of the Verify summary is unchanged" \
  || bad "C4. the rest of the Verify summary is unchanged: $V2"

# A pre-S174 plan (plain strings everywhere) reaches Verify unchanged: no block,
# and nothing in the readout moves. Every plan in flight is one of these.
V3="$(verify_out "$FX/capstone-0of44.json")"
printf '%s' "$V3" | grep -qi 'drawing' \
  && bad "C4. a pre-S174 string plan gets NO block: $V3" \
  || ok "C4. a pre-S174 string plan gets NO block (in-flight missions unmoved)"

# --- C6 (round 3): the unfenced note is on the READOUT too ----------------
# A drawing with no ids cannot be fenced, and the captain must not read that
# green as a fenced mission. Present ONLY there.
verify_out_blank() { # plan -> verify summary for a mission whose mockup has no ids
  local repo; repo="$(new_mission_blank_mockup)"
  local md="$repo/.git/lcars/missions/test-001"
  cat > "$md/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "MBR builder", "stage": "verify" }
JSON
  cat > "$md/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-012",
        "issue": null
      }
    ]
  }
]
JSON
  mkdir -p "$md/tickets/t-012"
  printf '{ "ticketId": "t-012", "passed": true, "attempts": 1 }\n' > "$md/tickets/t-012/result.json"
  cp "$1" "$md/plan.json"
  ( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      bash "$SCRIPT" verify-summary --mission test-001 2>&1 )
}
VU="$(verify_out_blank "$FX/capstone-corrected-174.json")"
printf '%s' "$VU" | grep -q "carries no element ids" \
  && ok "C6. Verify SAYS the anchors went unfenced on a no-id drawing" \
  || bad "C6. Verify says the anchors went unfenced: $VU"
printf '%s' "$V2" | grep -q "carries no element ids" \
  && bad "C6. a FENCED mission must not carry the unfenced note: $V2" \
  || ok "C6. a fenced mission carries no unfenced note"
V5="$(verify_out "$FX/capstone-0of44.json")"
printf '%s' "$V5" | grep -q "carries no element ids" \
  && bad "C6. a mission whose drawing HAS ids gets no note: $V5" \
  || ok "C6. a mission whose drawing has ids gets no note"

# The tester's D2 laundering, restated on the schema: a `NOT DRAWN:` string
# buried in a criterion is now just text. It reaches nothing, because the Verify
# list reads the FIELD.
V4="$(verify_out "$FX/bypass-buried-marker.json")"
printf '%s' "$V4" | grep -qi 'not in your drawing' \
  && bad "C5. a buried NOT DRAWN: string must NOT reach the Verify list: $V4" \
  || ok "C5/D2. a buried \"NOT DRAWN:\" string reaches nothing — the list reads the FIELD"

echo
printf 'plan-validator: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
