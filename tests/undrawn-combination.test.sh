#!/usr/bin/env bash
# S179 — THE COMBINATION NOBODY DREW. Fast, SCOPED test.
#
# THE MEASUREMENT (DX-Scorecard lcars-20260814-001). The MBR-builder mockup has
# two independent axes on a KPI row — collection (automatic|manual) and shape
# (scalar|cohort). Counted in `attachments/attachment-01.html`: 3 `tag-manual`,
# 11 `cohort`, and ZERO rows that are BOTH. The brief asserts each axis on its
# own ("a Manual KPI is edited inline"; "a cohort KPI shows each source") and
# never their intersection, so nothing said what a MANUAL COHORT does. The build
# resolved it by accident — a cohort row is read-only whether it is automatic or
# manual, while still rendering the word "Manual" — and the captain got a Manual
# tag on a read-only list with nothing to type into.
#
# S174 catches INVENTIONS (a criterion the drawing does not contain). NOTHING
# caught OMISSIONS. This round gives the omission the SAME road S175 built for
# an open question: the design DECLARES the combination it did not draw, it
# rides `## Open questions` → prd.md → Plan, Plan Review is told to hunt an
# unresolved intersection, and one nobody resolved is listed at Verify.
#
# Deliberately NOT tests/lcars-run.test.sh. Everything here runs over run.sh's
# isolation hooks, file.sh's PRD gate and a direct import of the daemon module —
# no worker is ever spawned, no token is ever spent.
#
# Usage: bash tests/undrawn-combination.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
PY="${LCARS_PYTHON_BIN:-python3}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
assert_has() { if has "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_no()  { if has "$2" "$3"; then bad "$1 (present but must not be: $2)"; else ok "$1"; fi; }
assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

# The MARKER. One string, written by the design worker, read by the Verify
# readout. It is a DECLARATION, not a classifier — the whole point of the shape.
MARK='UNDRAWN COMBINATION'

# ── fixtures ───────────────────────────────────────────────────────────────

# The measured case, written the way the contract asks for it.
CONCEPT_UNDRAWN='# MBR builder

## Decisions

- The builder is one screen. (T2)

## Open questions

- UNDRAWN COMBINATION: collection (automatic/manual) x shape (scalar/cohort) —
  drawn: automatic scalar, automatic cohort, manual scalar. NOT DRAWN: a manual
  cohort. What does one do?
- What makes a KPI "carried"?

## DATA PRECONDITIONS

## DECLARED FLOW

`start` → `builder`
'

# The SAME design with nothing undrawn — the byte-identical control.
CONCEPT_PLAIN='# MBR builder

## Decisions

- The builder is one screen. (T2)

## Open questions

- What makes a KPI "carried"?

## DATA PRECONDITIONS

## DECLARED FLOW

`start` → `builder`
'

# The full question text, joined the way every parser here joins a wrapped
# bullet. Everything downstream is asserted against THIS string.
QTEXT='UNDRAWN COMBINATION: collection (automatic/manual) x shape (scalar/cohort) — drawn: automatic scalar, automatic cohort, manual scalar. NOT DRAWN: a manual cohort. What does one do?'

new_mission() { # [concept-text] [mockup?] -> echoes mission dir
  local d; d="$(mktemp -d "$TMPROOT/m.XXXX")"
  mkdir -p "$d/attachments"
  printf '{ "id": "test-001", "stage": "verify" }\n' > "$d/state.json"
  [ "$#" -gt 0 ] && [ -n "${1:-}" ] && printf '%s' "$1" > "$d/attachments/attachment-02.md"
  if [ "${2:-}" = mockup ]; then
    printf '<html><body><div id="row-kpi">x</div></body></html>\n' \
      > "$d/attachments/attachment-01.html"
  fi
  echo "$d"
}

hook() { # subcommand mission-dir [env…] -> OUT/RC, stderr merged
  local sub="$1" dir="$2"; shift 2
  OUT="$(LCARS_ATT_TEST_DIR="$dir" "$@" bash "$SCRIPT" "$sub" 2>&1)"; RC=$?
}

echo "== 1. PART A — the contract asks what the drawing did NOT combine =="

CONTRACT="$(cd "$REPO_ROOT/web" && "$PY" -c \
  'from lcars_serve.actions import _CONCEPT_CONTRACT; print(_CONCEPT_CONTRACT)' 2>&1)"

assert_has "the contract names the marker the whole road keys off" "$MARK" "$CONTRACT"
assert_has "…and asks for the AXES to be named" "axes" "$CONTRACT"
assert_has "…and says which combinations were DRAWN" "DREW" "$CONTRACT"
# 3. of the brief: word it from the MEASUREMENT, not abstractly.
assert_has "…and carries the measured shape of the mistake (manual)" "manual" "$CONTRACT"
assert_has "…and the other axis of it (cohort)" "cohort" "$CONTRACT"
# The round takes NO position on the product answer.
assert_has "…and forbids answering it yourself" "ASK" "$CONTRACT"
# ONE HOME EACH would otherwise send this to bucket 2 — say so explicitly, the
# way DATA PRECONDITIONS already does.
assert_has "…and carves itself out of the one-home-each rule" "one-home-each" "$CONTRACT"

# 4. of the brief: KEEP IT SHORT. The `## Open questions` bucket is measured, not
# eyeballed — S175 watched a model drop the last instruction of a long block.
QBUCKET_LINES="$(cd "$REPO_ROOT/web" && "$PY" - <<'PYEOF'
from lcars_serve.actions import _CONCEPT_CONTRACT
lines = _CONCEPT_CONTRACT.split("\n")
start = next(i for i, l in enumerate(lines) if l.strip().startswith("## Open questions"))
end = next(i for i in range(start + 1, len(lines))
           if lines[i].strip().startswith("## "))
print(end - start)
PYEOF
)"
if [ "${QBUCKET_LINES:-999}" -le 30 ] 2>/dev/null; then
  ok "the '## Open questions' bucket is $QBUCKET_LINES lines (<= 30)"
else
  bad "the '## Open questions' bucket is $QBUCKET_LINES lines — over the 30-line cap"
fi

echo "== 2. PART A path — it reaches the PRD as an open question (S175's road) =="

. "$COMMON"

D_UN="$(new_mission "$CONCEPT_UNDRAWN")"
GOT="$(lcars_concept_open_questions "$D_UN/attachments/attachment-02.md")"
assert_has "the brief's undrawn combination is read as an open question" "$QTEXT" "$GOT"
assert_eq "…and it is ONE question, wrap joined, not two" \
  "$(printf '%s\n' "$GOT" | grep -c .)" "2"

# The daemon's own hand-off block — what the Align worker is actually handed.
BLOCK="$(cd "$REPO_ROOT/web" && "$PY" - "$D_UN/attachments/attachment-02.md" <<'PYEOF'
import sys
from lcars_serve.actions import Actions
print(Actions._handoff_questions_block(open(sys.argv[1]).read(), {}), end="")
PYEOF
)"
assert_has "…and rides the hand-off block to Align verbatim" "$QTEXT" "$BLOCK"

# The gate: a PRD that drops it is REFUSED; one that carries it is accepted.
PRD_DROP="$TMPROOT/prd-drop.md"
cat > "$PRD_DROP" <<'PRD'
# Mission: MBR builder
**Type:** lcars:feature
**Goal:** build it
**Acceptance Criteria:**
- it works
**Out of Scope:**
- nothing
**Constraints:**
- none

## Open questions from the design session

- STILL OPEN: What makes a KPI "carried"?
PRD
GMSG="$(lcars_prd_questions_gate "$PRD_DROP" "$D_UN/attachments/attachment-02.md" 2>&1)"; GRC=$?
assert_eq "a PRD that drops the undrawn combination is REFUSED" "$GRC" "1"
assert_has "…and the refusal names it verbatim" "$MARK" "$GMSG"

PRD_KEEP="$TMPROOT/prd-keep.md"
sed 's|^- STILL OPEN: What makes|- STILL OPEN: '"$QTEXT"'\n- STILL OPEN: What makes|' \
  "$PRD_DROP" > "$PRD_KEEP"
GMSG="$(lcars_prd_questions_gate "$PRD_KEEP" "$D_UN/attachments/attachment-02.md" 2>&1)"; GRC=$?
assert_eq "a PRD that carries it as STILL OPEN passes the gate" "$GRC" "0"

# BEHAVIOUR 2 — ZERO undrawn combinations changes NOTHING on this road.
D_PL="$(new_mission "$CONCEPT_PLAIN")"
GOT="$(lcars_concept_open_questions "$D_PL/attachments/attachment-02.md")"
assert_eq "a design with nothing undrawn yields only its own question" \
  "$GOT" 'What makes a KPI "carried"?'
BLOCK_PLAIN="$(cd "$REPO_ROOT/web" && "$PY" - "$D_PL/attachments/attachment-02.md" <<'PYEOF'
import sys
from lcars_serve.actions import Actions
print(Actions._handoff_questions_block(open(sys.argv[1]).read(), {}), end="")
PYEOF
)"
assert_no "…and its hand-off block says NOT ONE WORD about combinations" \
  "$MARK" "$BLOCK_PLAIN"

echo "== 3. PART B — the auditor is told to hunt the intersection =="

D_MOCK="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
hook plan-review-mockup-block-test "$D_MOCK"
assert_eq "the hook runs clean" "$RC" "0"
assert_has "the reviewer is told to look where two rules meet" \
  "where the two meet" "$OUT"
assert_has "…named as a combination the drawing never shows" \
  "combination the drawing never shows" "$OUT"
assert_has "…carrying the measurement, not a rule" "not one that was both" "$OUT"
assert_has "…and told it is NOT to decide the answer" "nobody has" "$OUT"
assert_has "…and it counts as a bounceable objection (all FIVE now)" \
  "All five are objections" "$OUT"
assert_no "…and the old count is gone" "All four are objections" "$OUT"

# BEHAVIOUR 3 (second half) — no mockup, NOT ONE BYTE. This block is the only
# thing S179 adds to that prompt, so zero bytes here IS byte-identity.
D_NOMOCK="$(new_mission "$CONCEPT_PLAIN")"
hook plan-review-mockup-block-test "$D_NOMOCK"
assert_eq "a Mission with NO mockup adds not one byte to Plan Review" "$OUT" ""

echo "== 4. PART C — the captain sees the hole at Verify =="

mk_prd() { # mission-dir  question-line
  cat > "$1/prd.md" <<PRD
# Mission: MBR builder

## Open questions from the design session

$2
- STILL OPEN: What makes a KPI "carried"?
PRD
}
mk_plan() { printf '%s\n' "$2" > "$1/plan.json"; }

PLAN_NONE='[{"id":"t-001","title":"row","acceptanceCriteria":[{"text":"a manual scalar is editable","drawnAt":"#row-kpi"}]}]'

D_V="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_V" "- STILL OPEN: $QTEXT"
mk_plan "$D_V" "$PLAN_NONE"
hook verify-undrawn-test "$D_V"
assert_eq "the hook runs clean" "$RC" "0"
# The QUESTION leads the line; the marker is a routing tag and the heading has
# already said what these are, so it is not repeated on every bullet.
assert_has "an undrawn combination nobody resolved is LISTED" \
  "${QTEXT#UNDRAWN COMBINATION: }" "$OUT"
assert_no "…with the routing marker dropped from the line itself" \
  "⊙ $MARK" "$OUT"
assert_has "…under a heading that says what it is" "NOBODY DECIDED" "$OUT"
# THE HONESTY REQUIREMENT: say what "resolved" actually means here.
assert_has "…and the readout states the LIMIT of what it checked" \
  "no ticket" "$OUT"
assert_has "…naming the two facts it actually has" "decides" "$OUT"
assert_has "…and refusing to imply a judgement nobody made" \
  "Nobody judged" "$OUT"
assert_has "…with the measurement that earns the section" "Manual" "$OUT"

# A ticket that DECLARED it settled the question — quoting it, as the Plan
# contract already prescribes — takes it off the list.
PLAN_DECIDES="$("$PY" - "$QTEXT" <<'PYEOF'
import json, sys
q = sys.argv[1]
print(json.dumps([{"id": "t-001", "title": "row", "acceptanceCriteria": [
    {"text": "a manual cohort is read-only", "drawnAt": "#row-kpi",
     "decides": q + " -> read-only, like the automatic one, because the drawing "
                    "shows no per-source input anywhere"}]}]))
PYEOF
)"
D_V2="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_V2" "- STILL OPEN: $QTEXT"
mk_plan "$D_V2" "$PLAN_DECIDES"
hook verify-undrawn-test "$D_V2"
assert_eq "a ticket that CITED it prints nothing at all" "$OUT" ""

# Resolved with the captain during Align — the other way it leaves the list.
D_V3="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_V3" "- RESOLVED with the captain: $QTEXT — read-only, he said so in the grill."
mk_plan "$D_V3" "$PLAN_NONE"
hook verify-undrawn-test "$D_V3"
assert_eq "one RESOLVED during Align prints nothing at all" "$OUT" ""

# BEHAVIOUR 4 (second half) + fail-open-and-silent.
D_V4="$(new_mission "$CONCEPT_PLAIN" mockup)"
mk_prd "$D_V4" '- STILL OPEN: What do Preview and View actually do?'
mk_plan "$D_V4" "$PLAN_NONE"
hook verify-undrawn-test "$D_V4"
assert_eq "open questions that are NOT combinations print nothing" "$OUT" ""
assert_eq "…and do not refuse" "$RC" "0"

D_V5="$(new_mission "" mockup)"
hook verify-undrawn-test "$D_V5"
assert_eq "no prd.md at all: nothing printed" "$OUT" ""
assert_eq "…and NEVER an error (fail open, fail silent)" "$RC" "0"

D_V6="$(new_mission "" mockup)"
printf 'not: json\n' > "$D_V6/prd.md"
printf 'not json either\n' > "$D_V6/plan.json"
hook verify-undrawn-test "$D_V6"
assert_eq "unreadable inputs: nothing printed" "$OUT" ""
assert_eq "…and still never an error" "$RC" "0"

echo "== 4b. FIX ROUND 2 — the string he reads is the string that counts =="

# The question AS THE CAPTAIN READS IT — the marker is a routing tag, dropped
# from the row, and this is what a planner quoting "the question" would copy.
QBODY="${QTEXT#UNDRAWN COMBINATION: }"

plan_decides() { # <decides text> -> a one-ticket plan.json on stdout
  "$PY" - "$1" <<'PYEOF'
import json, sys
print(json.dumps([{"id": "t-001", "title": "row", "acceptanceCriteria": [
    {"text": "a manual cohort is read-only", "drawnAt": "#row-kpi",
     "decides": sys.argv[1]}]}]))
PYEOF
}

undrawn() { # <decides text> -> OUT/RC for the standard measured fixture
  local d; d="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
  mk_prd "$d" "- STILL OPEN: $QTEXT"
  mk_plan "$d" "$(plan_decides "$1")"
  hook verify-undrawn-test "$d"
}

# ── D1. ONE STRING, DISPLAYED AND LOAD-BEARING ────────────────────────────
# The row is printed with the marker stripped and was MATCHED with it attached,
# so a planner who quoted the question exactly as the captain sees it was not
# credited — and this readout printed "no ticket quoted it" while
# `verify_decided_readout`, four lines above, printed that ticket's decision.
undrawn "$QBODY → read-only, like the automatic one, because nothing is drawn to type into"
assert_eq "D1: a decides quoting the question AS DISPLAYED is credited" "$OUT" ""

undrawn "The undrawn combination of $QBODY → read-only"
assert_eq "D1: …and one that quotes it inside a sentence of its own" "$OUT" ""

undrawn "$QTEXT → read-only"
assert_eq "D1: …and the marker-included quote is credited exactly as before" "$OUT" ""

# KNOWN MISS, encoded so a flattering number cannot drift. The test is exact
# normalised CONTAINMENT of the whole question — the identical test the PRD
# gate uses — never similarity. A decides quoting only the question's last
# sentence does NOT contain it, so the row stays; and the readout's wording is
# literally true when it does, because no ticket quoted the question.
undrawn "What does one do? → read-only"
assert_has "D1 KNOWN MISS: a decides quoting only a FRAGMENT is not credited" \
  "NOBODY DECIDED" "$OUT"

# ── D5. QUOTING THE QUESTION IS NOT DECIDING IT ───────────────────────────
undrawn "$QBODY"
assert_has "D5: quoting the question and deciding NOTHING does not silence it" \
  "NOBODY DECIDED" "$OUT"
undrawn "UNDRAWN COMBINATION: $QBODY"
assert_has "D5: …nor does quoting it with its marker and nothing else" \
  "NOBODY DECIDED" "$OUT"

# ── D2. A FENCED BLOCK IS NOT A DECLARATION ───────────────────────────────
D_F="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
cat > "$D_F/prd.md" <<PRD
# Mission: MBR builder

## Open questions from the design session

Write each one in this shape:

\`\`\`
- STILL OPEN: UNDRAWN COMBINATION: <axis A> x <axis B> — DREW: <the pairs the
  drawing shows>. NOT DRAWN: <the pair it does not>. What does one do?
\`\`\`

- STILL OPEN: What makes a KPI "carried"?
PRD
mk_plan "$D_F" "$PLAN_NONE"
hook verify-undrawn-test "$D_F"
assert_eq "D2: the contract's own template, fenced, is not a captain-facing row" \
  "$OUT" ""
assert_eq "…and does not refuse" "$RC" "0"

# ── D2. THE PREFIX CONTRACT, READ THE SAME WAY BY BOTH READERS ────────────
# An undeclared bullet is one `mission_open_questions` drops on the floor, so
# the Plan Stage was never told about it. This readout may not print, at Verify,
# a question its own pipeline never carried.
D_NP="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_NP" "- $QTEXT"
mk_plan "$D_NP" "$PLAN_NONE"
hook verify-undrawn-test "$D_NP"
assert_eq "D2: an UNDECLARED bullet (no STILL OPEN:) prints nothing…" "$OUT" ""
hook open-questions-test "$D_NP"
assert_no "D2: …exactly as mission_open_questions drops it from the Plan prompt" \
  "manual cohort" "$OUT"

# ── D3. THE CAVEAT STATES THE FACT IT ACTUALLY CHECKED ────────────────────
undrawn "some unrelated decision about the header"
assert_has "D3: the caveat names the check it really made" \
  "still marks it STILL OPEN" "$OUT"
assert_no "D3: …and no longer claims a fact about the whole PRD" \
  "recorded no answer" "$OUT"
assert_has "D3: …and says out loud that it never read the PRD's prose" \
  "read the PRD's prose" "$OUT"

# ── D4. `**UNDRAWN COMBINATION:**` — what a model writing markdown does ────
D_E="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_E" '- STILL OPEN: **UNDRAWN COMBINATION:** manual x cohort. What does one do?'
mk_plan "$D_E" "$PLAN_NONE"
hook verify-undrawn-test "$D_E"
assert_has "D4: emphasis around the marker comes off with the marker" \
  "⊙ manual x cohort. What does one do?" "$OUT"
assert_no "D4: …leaving no literal asterisks leading the row" "⊙ **" "$OUT"

# ── D6. GUARDED ON THE MISSION CARRYING A DRAWING ─────────────────────────
D_NM="$(new_mission "$CONCEPT_UNDRAWN")"
mk_prd "$D_NM" "- STILL OPEN: $QTEXT"
mk_plan "$D_NM" "$PLAN_NONE"
hook verify-undrawn-test "$D_NM"
assert_eq "D6: a Mission with NO drawing is never told about \"your drawing\"" \
  "$OUT" ""
assert_eq "…and does not refuse" "$RC" "0"

# ── identical bullets are ONE row ─────────────────────────────────────────
D_D="$(new_mission "$CONCEPT_UNDRAWN" mockup)"
mk_prd "$D_D" "- STILL OPEN: $QTEXT
- STILL OPEN: $QTEXT"
mk_plan "$D_D" "$PLAN_NONE"
hook verify-undrawn-test "$D_D"
assert_eq "an identical bullet twice is ONE row, not two" \
  "$(printf '%s\n' "$OUT" | grep -c '⊙')" "1"

echo "== 5. it reaches the real Verify readout, and nothing else moves =="

# A full verify mission, driven through the REAL `verify-summary` — the surface
# the captain reads — and then the same mission through the run.sh at HEAD, so
# "byte-identical" is COMPARED, not eyeballed.
MID="lcars-20260829-001"
new_repo() { # [prd-question-line] [mockup:yes|no] [plan.json]
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m/tickets/t-001"
  cat >"$m/state.json" <<EOF
{ "id": "$MID", "type": "feature", "title": "MBR builder",
  "stage": "verify", "created": "2026-08-29T10:00:00Z",
  "model": "claude", "githubIssue": 42,
  "branch": "lcars/$MID", "base": "main" }
EOF
  cat >"$m/waves.json" <<'WAVES'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": 101 } ] }
]
WAVES
  printf '{ "passed": true, "attempts": 1 }\n' >"$m/tickets/t-001/result.json"
  printf '%s\n' "${3:-$PLAN_NONE}" >"$m/plan.json"
  # D6: the readout is guarded on the Mission CARRYING a drawing, so the repo
  # that exercises it has to have one. DEFAULT NO — the byte-identity control
  # below is a mission with no drawing and no design questions at all.
  mkdir -p "$m/attachments"
  if [ "${2:-no}" = yes ]; then
    printf '<html><body><div id="row-kpi">x</div></body></html>\n' \
      >"$m/attachments/attachment-01.html"
  fi
  if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
    cat >"$m/prd.md" <<PRD
# Mission: MBR builder

## Open questions from the design session

$1
PRD
  fi
  echo "$repo"
}

R1="$(new_repo "- STILL OPEN: $QTEXT" yes)"
OUT="$(cd "$R1" && bash "$SCRIPT" verify-summary --mission "$MID" 2>&1)"; RC=$?
assert_eq "verify-summary exits 0" "$RC" "0"
assert_has "the captain's Verify readout carries the undrawn combination" \
  "NOBODY DECIDED" "$OUT"
assert_has "…with the question itself" "manual cohort" "$OUT"

# BEHAVIOUR 5 — a Mission with NO mockup and no design questions is BYTE-IDENTICAL
# end to end. Compared against the run.sh from BEFORE this session — pinned to a
# SHA, never `HEAD`. A moving baseline made this suite's own control test go red
# the moment S179 was committed: it asserts the pre-S179 code printed NOTHING for
# an undrawn combination, which is only true of the commit BEFORE the feature.
# `HEAD` stopped being that commit at 5dab519, so the test could pass only in the
# window before its own commit — and a permanently-red test teaches everyone to
# ignore red. Staged beside a symlink to lcars-init so its
# `$SKILL_DIR/../lcars-init` resolution still works.
S179_PARENT="${LCARS_PRE_S179_SHA:-dd9268a}"
HEADDIR="$TMPROOT/head/skills"
mkdir -p "$HEADDIR/lcars-run"
git -C "$REPO_ROOT" show "$S179_PARENT":skills/lcars-run/run.sh > "$HEADDIR/lcars-run/run.sh"
ln -s "$REPO_ROOT/skills/lcars-init" "$HEADDIR/lcars-init"
chmod +x "$HEADDIR/lcars-run/run.sh"

R2="$(new_repo)"
NOW_OUT="$(cd "$R2" && bash "$SCRIPT" verify-summary --mission "$MID" 2>&1)"
R3="$(new_repo)"
HEAD_OUT="$(cd "$R3" && bash "$HEADDIR/lcars-run/run.sh" verify-summary --mission "$MID" 2>&1)"
if [ "$NOW_OUT" = "$HEAD_OUT" ]; then
  ok "a Mission with no mockup and no design questions: BYTE-IDENTICAL to pre-S179"
else
  bad "a Mission with no mockup drifted from pre-S179"
  diff <(printf '%s\n' "$HEAD_OUT") <(printf '%s\n' "$NOW_OUT") | head -20
fi

# …and the mission that DOES carry one differs ONLY by the new section, so the
# byte-identity above is not an accident of an inert code path.
R4="$(new_repo "- STILL OPEN: $QTEXT" yes)"
HEAD_Q="$(cd "$R4" && bash "$HEADDIR/lcars-run/run.sh" verify-summary --mission "$MID" 2>&1)"
if [ "$HEAD_Q" = "$HEAD_OUT" ]; then
  ok "pre-S179 printed nothing for it — this section is genuinely new"
else
  bad "pre-S179 already printed something for an undrawn combination"
fi

# D1, ON THE SURFACE THE CAPTAIN ACTUALLY READS. `verify_decided_readout` and
# this one are four lines apart in the same summary. Before the fix they printed
# the SAME question — one as "a ticket settled it", the other as "nobody did".
R5="$(new_repo "- STILL OPEN: $QTEXT" yes "$(plan_decides "$QBODY → read-only, like the automatic one")")"
OUT="$(cd "$R5" && bash "$SCRIPT" verify-summary --mission "$MID" 2>&1)"
assert_has "the Verify summary says a ticket DECIDED it" "DECIDED FOR YOU" "$OUT"
assert_no "…and does NOT also say nobody did, about that same question" \
  "NOBODY DECIDED" "$OUT"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
