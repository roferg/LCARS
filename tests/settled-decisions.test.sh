#!/usr/bin/env bash
# S180 — a question the captain SETTLED must never be re-raised as "open".
#
# THE MEASUREMENT (lcars-20260829-002, 2026-08-29/30). The Mission reached Verify
# green and raised FOUR human gates, all on ONE ticket, all about ONE question the
# captain had already answered TWICE. Plan Review said, verbatim:
#
#     "the brief lists '<question>' as an UNSETTLED open question with no captain
#      resolution."
#
# That was FALSE. The PRD's `## Open questions from the design session` section
# recorded `RESOLVED with the captain: <question> — <answer>` for it, and had done
# since Align. `cmd_plan_review` is deliberately never handed prd.md (S174's
# independence design, which is CORRECT and stays), so it could not see a single
# one of the captain's decisions and escalated a settled one.
#
# Four contributing mechanisms, each covered below:
#   A1  the decisions DIGEST — the RESOLVED entries, and only those, reach the
#       reviewer; prd.md still does not.
#   A2  the PRECEDENCE rule — a decision outranks the drawing on BEHAVIOUR, and
#       calling a decided question "open" is not an objection.
#   A3  answers.json is APPEND-ONLY — three successive answers to one question
#       each erased the last.
#   A4  the round budget RESETS on an answer, under a separate total cap.
#   A5  answering a gate RESUMES the drive instead of exiting.
#   A6  the hints the driver prints are commands that actually run.
#
# GENERICITY IS THE POINT. Every behaviour is proven on TWO unrelated fixtures
# (tests/fixtures/decisions/measured-prd.md, the measured Mission's own subject;
# and budget-prd.md, derived from tests/drives/undrawn/budget-brief.txt, sharing
# not one noun with it). A prompt rule that reads one screen's vocabulary passes
# the first and fails the second.
#
# Deliberately NOT the heavy tests/lcars-run.test.sh. Everything runs over run.sh's
# isolation hooks and a stub worker adapter. NO worker is ever spawned, NO token is
# ever spent.
#
#   bash tests/settled-decisions.test.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
RESPOND="${LCARS_RESPOND_SCRIPT:-$REPO_ROOT/skills/lcars-respond/respond.sh}"
FIX="$REPO_ROOT/tests/fixtures/decisions"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
assert_has() { if has "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_no()  { if has "$2" "$3"; then bad "$1 (present but must not be: $2)"; else ok "$1"; fi; }
assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

section() { printf '\n%s\n' "$1"; }

# ===========================================================================
section "A1 — the decisions digest: the RESOLVED entries, and ONLY those"
# ===========================================================================
digest() { # prd-file -> the extracted decisions, one per line
  local d; d="$(mktemp -d "$TMPROOT/dg.XXXX")"
  cp "$1" "$d/prd.md"
  LCARS_ATT_TEST_DIR="$d" bash "$SCRIPT" resolved-decisions-test 2>&1
}

# --- FIXTURE A: the measured Mission -----------------------------------------
DA="$(digest "$FIX/measured-prd.md")"
assert_eq "1a fixture A yields one line per RESOLVED entry" \
          "$(printf '%s\n' "$DA" | grep -c .)" "6"
assert_has "1b …carrying the question"  'Does "lock" happen per-bucket, per-month, or both?' "$DA"
assert_has "1c …and the captain's answer" "Per month" "$DA"
# The declaration marker is CONSUMED — the digest is question + answer, not the
# bookkeeping prefix repeated six times.
assert_no  "1d …with the RESOLVED marker stripped" "RESOLVED with the captain" "$DA"
# THE WHOLE POINT: an entry the PRD did NOT mark resolved is genuinely unsettled
# and must NOT be presented to the reviewer as decided.
assert_no  "1e …and NEVER a STILL OPEN entry" "exportable to PDF" "$DA"
# A PRD wraps at ~78 columns; a two-line bullet must arrive joined, not truncated.
assert_has "1f …joining a wrapped entry across the line break" \
           "automatically? — Delta auto-recomputes" "$DA"
# `- **RESOLVED:** …` is what a model writing markdown does by default.
assert_has "1g …reading the emphasised marker form too" "Autosaved as you type" "$DA"

# --- FIXTURE B: an unrelated Mission -----------------------------------------
DB="$(digest "$FIX/budget-prd.md")"
assert_eq "1h fixture B yields one line per RESOLVED entry" \
          "$(printf '%s\n' "$DB" | grep -c .)" "3"
assert_has "1i …carrying its question"    "Is a rolled-up line's total editable" "$DB"
assert_has "1j …and its answer"           "the total is always derived" "$DB"
assert_no  "1k …and NEVER its STILL OPEN entry" "roll over automatically" "$DB"
# A separator that is not an em dash (`RESOLVED — Q — A`) still parses.
assert_has "1l …tolerating a dash after the marker" "Inside the input." "$DB"
# Cross-contamination check: nothing of fixture A may appear in fixture B.
assert_no  "1m …and carries NOTHING of the other fixture" "per-month" "$DB"

# --- a PRD with no such section yields NOTHING -------------------------------
assert_eq "1n a PRD with no open-questions section yields an EMPTY digest" \
          "$(digest "$FIX/no-questions-prd.md")" ""
# …and so does a mission dir with no prd.md at all.
EMPTYD="$(mktemp -d "$TMPROOT/dg-none.XXXX")"
assert_eq "1o a mission with no prd.md yields an EMPTY digest" \
          "$(LCARS_ATT_TEST_DIR="$EMPTYD" bash "$SCRIPT" resolved-decisions-test 2>&1)" ""
# A section that declares NOTHING is not a refusal here (Plan already refuses it):
# plan-review must never acquire a brand-new way to die.
UND="$(mktemp -d "$TMPROOT/dg-und.XXXX")"
printf '# PRD\n\n## Open questions from the design session\n\n- Who owns the row?\n- What colour is it?\n' > "$UND/prd.md"
UOUT="$(LCARS_ATT_TEST_DIR="$UND" bash "$SCRIPT" resolved-decisions-test 2>&1)"; URC=$?
assert_eq "1p an UNDECLARED section yields an empty digest, not a refusal" "$URC" "0"
assert_eq "1q …and yields nothing"                                         "$UOUT" ""

# ===========================================================================
section "A2 — the precedence rule the reviewer is handed"
# ===========================================================================
blk() { # prd-file [mockup-name] -> the plan-review decisions block
  local d; d="$(mktemp -d "$TMPROOT/blk.XXXX")"
  cp "$1" "$d/prd.md"
  if [ -n "${2:-}" ]; then mkdir -p "$d/attachments"; printf '<html></html>\n' > "$d/attachments/$2"; fi
  LCARS_ATT_TEST_DIR="$d" bash "$SCRIPT" plan-review-decisions-block-test 2>&1
}

assert_eq "2a a Mission with NO decisions gets NO block at all" \
          "$(blk "$FIX/no-questions-prd.md")" ""

BA="$(blk "$FIX/measured-prd.md")"
BB="$(blk "$FIX/budget-prd.md")"

for f in A B; do
  eval "B=\$B$f"
  assert_has "2b$f fixture $f: the block says these are DECIDED"   "DECIDED" "$B"
  assert_has "2c$f fixture $f: a decision outranks on BEHAVIOUR"   "BEHAVIOUR" "$B"
  assert_has "2d$f fixture $f: contradicting one IS an objection"  "CONTRADICTS" "$B"
  assert_has "2e$f fixture $f: calling one open is NOT"            "is NOT an objection" "$B"
  assert_has "2f$f fixture $f: names the words it must not use"    '"unsettled"' "$B"
  assert_has "2g$f fixture $f: the decisions themselves are listed" "1." "$B"
done
assert_has "2h fixture A lists its own decisions"  "Per month" "$BA"
assert_has "2i fixture B lists its own decisions"  "the total is always derived" "$BB"

# --- THE GENERICITY FENCE ----------------------------------------------------
# S179 measured a FILLED-IN worked example in a prompt being copied verbatim onto
# an unrelated screen by 3 of 3 live turns. Nothing this round adds may carry one
# screen's nouns. The block's own PROSE (everything that is not a quoted decision
# line) must be free of them — checked against BOTH fixtures' vocabularies.
prose_only() { # block -> the block with the numbered decision lines removed
  printf '%s\n' "$1" | grep -vE '^[[:space:]]+[0-9]+\.'
}
PA="$(prose_only "$BA")"; PB="$(prose_only "$BB")"
# Whole words only — "block" must not read as "lock".
for w in KPI insight cohort collect MBR month lock unlock \
         budget quarter "cost centre" sync currency spend; do
  if printf '%s\n' "$PA" "$PB" | grep -qiE "(^|[^A-Za-z])$w([^A-Za-z]|$)"; then
    bad "2j the block's PROSE must carry no domain vocabulary (found: $w)"
  else
    ok "2j the block's PROSE carries no domain vocabulary ($w)"
  fi
done

# --- the drawing-vs-decision half is MOCKUP-GATED ----------------------------
# A rule about "the drawing" on a Mission that shipped no drawing is an
# instruction referencing an input that does not exist — the exact class S178
# was built to stop.
assert_no  "2k with NO mockup the block never mentions a drawing" "drawing" "$BA"
BM="$(blk "$FIX/measured-prd.md" mockup.html)"
assert_has "2l with a mockup it states the LOOK/BEHAVIOUR split" "the LOOK" "$BM"
assert_has "2m …and that where they disagree the answer WINS"     "the answer
WINS" "$BM"
assert_has "2n …and the drawn affordance is deliberately NOT built" \
           "deliberately NOT built" "$BM"
assert_has "2o …so its absence is not an omission to object to" "not an omission" "$BM"
BMB="$(blk "$FIX/budget-prd.md" mockup.html)"
assert_has "2p …and the same on the unrelated fixture" "deliberately NOT built" "$BMB"

# ===========================================================================
section "A1/A2 end to end — the reviewer prompt, and its byte-identity"
# ===========================================================================
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
case "$role" in
  plan-review) printf '{ "passed": true, "issues": [] }\n' > "$outdir/verdict.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
}

pr_repo() { # prd-file -> echoes repo dir, mission parked at plan-review
  local repo; repo="$(mktemp -d "$TMPROOT/pr.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    printf '# fixture\n' > README.md
    printf '# Context\n\nA fixture repo.\n' > CONTEXT.md
    git add -A && git commit -q -m init
    git checkout -q -b lcars/test-001
  ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan-review",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null
}
JSON
  cp "$1" "$d/prd.md"
  printf '[{"id":"t-001","title":"a","description":"d","acceptanceCriteria":["c"],"dependencies":[],"filesTouched":["README.md"],"estimatedReadLoc":1,"estimatedTestLoc":1,"estimatedNewLoc":1}]\n' > "$d/plan.json"
  make_adapter "$repo.adapter"
  printf '#!/usr/bin/env bash\necho UNEXPECTED-SPAWN >&2\nexit 96\n' >"$repo.worker"; chmod +x "$repo.worker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  echo "$repo"
}

run_pr_stage() { # repo [run.sh-override]
  : >"$1.prompts"
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      PROMPTS="$1.prompts" \
      bash "${2:-$SCRIPT}" plan-review --mission test-001 2>&1 )"
  RC=$?
  PROMPT_FILE="$1.prompts"
}

# --- the measured Mission: the digest reaches the reviewer, prd.md does not ---
repo="$(pr_repo "$FIX/measured-prd.md")"
run_pr_stage "$repo"
PA_PROMPT="$(cat "$PROMPT_FILE")"
assert_eq  "3a the Stage runs" "$RC" "0"
assert_has "3b the reviewer is handed the captain's decisions" "Per month" "$PA_PROMPT"
assert_has "3c …and the precedence rule"  "is NOT an objection" "$PA_PROMPT"
# S174'S DESIGN IS UNTOUCHED. The reviewer still never sees the brief.
assert_no  "3d …and STILL never sees prd.md" "/prd.md" "$PA_PROMPT"
assert_no  "3e …nor validated-plan.md"       "/validated-plan.md" "$PA_PROMPT"
# …and nothing the PRD left OPEN is smuggled in as decided.
assert_no  "3f …and no STILL-OPEN question is presented as decided" "exportable to PDF" "$PA_PROMPT"

repo="$(pr_repo "$FIX/budget-prd.md")"
run_pr_stage "$repo"
PB_PROMPT="$(cat "$PROMPT_FILE")"
assert_has "3g the unrelated Mission's decisions reach its reviewer" \
           "the total is always derived" "$PB_PROMPT"
assert_no  "3h …and its STILL-OPEN question does not" "roll over automatically" "$PB_PROMPT"
assert_no  "3i …and it never sees prd.md either" "/prd.md" "$PB_PROMPT"

# --- BYTE-IDENTITY: a Mission with no decisions is untouched -----------------
# The only way to prove it: diff the assembled prompt against the one the
# PREVIOUS commit's run.sh produces, over the same fixture.
repo="$(pr_repo "$FIX/no-questions-prd.md")"
run_pr_stage "$repo"
NEW_PROMPT="$TMPROOT/prompt.new"; cp "$PROMPT_FILE" "$NEW_PROMPT"
assert_no "4a a no-decisions reviewer prompt carries no decisions block" "DECIDED" "$NEW_PROMPT"

BASE_DIR="$TMPROOT/skill-base"; mkdir -p "$BASE_DIR"
for f in "$REPO_ROOT"/skills/lcars-run/*; do
  [ "$(basename "$f")" = "run.sh" ] && continue
  ln -s "$f" "$BASE_DIR/$(basename "$f")" 2>/dev/null || :
done
BASE_SH="$BASE_DIR/run.sh"
if ( cd "$REPO_ROOT" && git show "HEAD:skills/lcars-run/run.sh" > "$BASE_SH" ) 2>/dev/null && [ -s "$BASE_SH" ]; then
  repo2="$(pr_repo "$FIX/no-questions-prd.md")"
  run_pr_stage "$repo2" "$BASE_SH"
  BASE_PROMPT="$TMPROOT/prompt.base"; cp "$PROMPT_FILE" "$BASE_PROMPT"
  norm() { sed -e 's#Your scratch output directory is: .*#Your scratch output directory is: <ODIR>#' \
               -e "s#$TMPROOT/pr\.[A-Za-z0-9]*#<REPO>#g" \
               -e 's#/var/folders/[^ ]*#<TMP>#g' -e 's#^/tmp/[^ ]*#<TMP>#g' "$1"; }
  if diff <(norm "$NEW_PROMPT") <(norm "$BASE_PROMPT") >"$TMPROOT/prompt.diff" 2>&1; then
    ok "4b a no-decisions reviewer prompt is BYTE-IDENTICAL to the previous commit's"
  else
    bad "4b a no-decisions reviewer prompt is BYTE-IDENTICAL to the previous commit's"
    sed -n '1,40p' "$TMPROOT/prompt.diff" | sed 's/^/       /'
  fi
else
  bad "4b could not read HEAD:skills/lcars-run/run.sh for the byte-identity baseline"
fi

# ===========================================================================
section "A3 — answers.json is APPEND-ONLY"
# ===========================================================================
ans_repo() { # stage [planReviewRound] -> repo with a mission at an awaiting gate
  local repo; repo="$(mktemp -d "$TMPROOT/ans.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "$1",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null,
  "planReviewRound": ${2:-3},
  "awaitingHuman": true
}
JSON
  cat > "$d/pending.json" <<JSON
{
  "stage": "$1",
  "questions": [
    "$3"
  ]
}
JSON
  echo "$repo"
}
answer() { # repo text
  ANSOUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_RESPOND_RESUME=0 \
      bash "$RESPOND" answer --mission test-001 --answer "$2" 2>&1 )"
  ANSRC=$?
  # re-arm the gate so a second answer is possible (the escalation recurred)
  local d="$1/.git/lcars/missions/test-001"
  grep -q awaitingHuman "$d/state.json" || \
    sed -i.bak '1a\
  "awaitingHuman": true,
' "$d/state.json"
}
ajson() { printf '%s/.git/lcars/missions/test-001/answers.json' "$1"; }

# THE MEASURED CASE: three successive answers to the same question.
repo="$(ans_repo plan-review 3 "Does the row need a control here?")"
answer "$repo" "first answer"
answer "$repo" "second answer"
answer "$repo" "third answer"
A="$(cat "$(ajson "$repo")")"
assert_has "5a the FIRST answer survives three rounds" "first answer" "$A"
assert_has "5b …and the second"                        "second answer" "$A"
assert_has "5c …and the third"                         "third answer" "$A"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
xs=d["answers"]
assert len(xs)==3, len(xs)
assert [x["answer"] for x in xs]==["first answer","second answer","third answer"]
assert all(x["stage"]=="plan-review" for x in xs)
assert all(x["questions"] for x in xs)
' "$(ajson "$repo")" 2>"$TMPROOT/aerr"; then
  ok "5d …as an ordered list keyed by stage + question"
else
  bad "5d …as an ordered list keyed by stage + question ($(cat "$TMPROOT/aerr"))"
fi
# LEGACY CONSUMERS. json_str takes the FIRST "answer" it finds; the operative
# answer is the LATEST, so the legacy top-level slot must mirror the newest.
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["answer"]=="third answer", d["answer"]
assert d["stage"]=="plan-review"
assert isinstance(d["questions"], list) and d["questions"]
' "$(ajson "$repo")" 2>"$TMPROOT/aerr2"; then
  ok "5e …with the legacy single-slot fields mirroring the LATEST"
else
  bad "5e …with the legacy single-slot fields mirroring the LATEST ($(cat "$TMPROOT/aerr2"))"
fi
# …and the reader run.sh actually uses agrees.
LATEST="$( cd "$repo" && bash "$SCRIPT" answers-latest-test --mission test-001 2>/dev/null )" || LATEST=""
[ -n "$LATEST" ] && assert_eq "5f …and run.sh's own reader returns the latest" "$LATEST" "third answer"

# A LEGACY single-object file on disk (a Mission in flight) must migrate, not crash.
repo="$(ans_repo plan-review 3 "Which one wins?")"
cat > "$(ajson "$repo")" <<'JSON'
{
  "stage": "plan-review",
  "answeredAt": "2026-08-29T00:00:00Z",
  "answer": "the legacy answer",
  "questions": [
    "Which one wins?"
  ]
}
JSON
answer "$repo" "the new answer"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
xs=d["answers"]
assert len(xs)==2, len(xs)
assert xs[0]["answer"]=="the legacy answer"
assert xs[1]["answer"]=="the new answer"
' "$(ajson "$repo")" 2>"$TMPROOT/aerr3"; then
  ok "5g a LEGACY single-object answers.json is migrated, never discarded"
else
  bad "5g a LEGACY single-object answers.json is migrated, never discarded ($(cat "$TMPROOT/aerr3"))"
fi

# The precondition absorber (run.sh:1611) reads EVERY answer, not just the newest.
PRE="$TMPROOT/pre"; mkdir -p "$PRE"
cat > "$PRE/preconditions.json" <<'JSON'
{ "preconditions": [
  { "text": "the feed returns a figure every night", "status": "unsatisfied", "evidence": "x.json: 0 of 4" },
  { "text": "every row has an owner", "status": "unsatisfied", "evidence": "x.json: 0 of 4" }
] }
JSON
cat > "$PRE/answers.json" <<'JSON'
{
  "stage": "validate", "answeredAt": "z", "answer": "second",
  "questions": [ "This design assumes: \"every row has an owner\"." ],
  "answers": [
    { "stage": "validate", "answeredAt": "y", "answer": "first",
      "questions": [ "This design assumes: \"the feed returns a figure every night\"." ] },
    { "stage": "validate", "answeredAt": "z", "answer": "second",
      "questions": [ "This design assumes: \"every row has an owner\"." ] }
  ]
}
JSON
LCARS_ATT_TEST_DIR="$PRE" LCARS_PRECOND_SRC=/nonexistent \
  bash "$SCRIPT" precond-absorb-test >/dev/null 2>&1
if python3 -c '
import json,sys
rows={r["text"]: r.get("answer") for r in json.load(open(sys.argv[1]))["preconditions"]}
assert rows["the feed returns a figure every night"]=="first", rows
assert rows["every row has an owner"]=="second", rows
' "$PRE/preconditions.json" 2>"$TMPROOT/aerr4"; then
  ok "5h the precondition absorber folds EVERY answer, not only the newest"
else
  bad "5h the precondition absorber folds EVERY answer, not only the newest ($(cat "$TMPROOT/aerr4"))"
fi

# ===========================================================================
section "A4 — a captain's answer buys a fresh round budget, under a total cap"
# ===========================================================================
prr() { sed -n 's/.*"planReviewRound"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' \
        "$1/.git/lcars/missions/test-001/state.json" | head -1; }
pre_() { sed -n 's/.*"planReviewEscalations"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' \
        "$1/.git/lcars/missions/test-001/state.json" | head -1; }

repo="$(ans_repo plan-review 3 "Does the row need a control here?")"
assert_eq "6a the gate is reached with the budget exhausted" "$(prr "$repo")" "3"
answer "$repo" "build it the way I said"
assert_eq "6b answering a PLAN-REVIEW gate resets the round budget" "$(prr "$repo")" "0"
assert_eq "6c …and counts the escalation"                          "$(pre_ "$repo")" "1"
assert_has "6d …and says so"  "fresh review round" "$ANSOUT"

# a NON-plan-review gate must not touch the counter at all.
repo="$(ans_repo validate 2 "Is this a scope change?")"
answer "$repo" "yes, proceed"
assert_eq "6e a validate gate leaves planReviewRound alone" "$(prr "$repo")" "2"
assert_eq "6f …and never counts a plan-review escalation"   "$(pre_ "$repo")" ""

# THE CAP. Three answered escalations is the ceiling; the fourth does not buy
# another loop, so the Mission cannot babysit forever.
repo="$(ans_repo plan-review 3 "Does the row need a control here?")"
for i in 1 2 3; do
  sed -i.bak 's/"planReviewRound": [0-9]*/"planReviewRound": 3/' \
    "$repo/.git/lcars/missions/test-001/state.json"
  answer "$repo" "answer $i"
done
assert_eq "6g three answered escalations are counted" "$(pre_ "$repo")" "3"
sed -i.bak 's/"planReviewRound": [0-9]*/"planReviewRound": 3/' \
  "$repo/.git/lcars/missions/test-001/state.json"
answer "$repo" "answer 4"
assert_eq "6h the FOURTH does NOT buy another loop" "$(prr "$repo")" "3"
assert_has "6i …and says why, in the captain's words" "3 answered escalation" "$ANSOUT"

# ===========================================================================
section "A5 — answering a gate RESUMES the drive"
# ===========================================================================
repo="$(ans_repo plan-review 3 "Does the row need a control here?")"
STUBRUN="$repo.runstub"
cat >"$STUBRUN" <<EOF
#!/usr/bin/env bash
printf 'RESUMED %s\n' "\$*" > "$repo.resumed"
exit 0
EOF
chmod +x "$STUBRUN"
OUTR="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_RUN_SCRIPT="$STUBRUN" \
   bash "$RESPOND" answer --mission test-001 --answer "go" 2>&1 )"
if [ -f "$repo.resumed" ] && grep -q 'drive --mission test-001' "$repo.resumed"; then
  ok "7a answering a gate re-enters the driver on the same Mission"
else
  bad "7a answering a gate re-enters the driver on the same Mission"
fi
# …and it is opt-out-able, because the board dispatches its own resume (BUG-028)
# and must not block its HTTP handler on a whole drive.
repo="$(ans_repo plan-review 3 "q?")"
rm -f "$repo.resumed"
OUTR="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_RESPOND_RESUME=0 LCARS_RUN_SCRIPT="$STUBRUN" \
   bash "$RESPOND" answer --mission test-001 --answer "go" 2>&1 )"
if [ -f "$repo.resumed" ]; then
  bad "7b LCARS_RESPOND_RESUME=0 suppresses the resume"
else
  ok "7b LCARS_RESPOND_RESUME=0 suppresses the resume"
fi
# The board must set it, or its blocking respond call waits for the whole drive.
if grep -q 'LCARS_RESPOND_RESUME' "$REPO_ROOT/web/lcars_serve/actions.py"; then
  ok "7c the board's respond endpoint suppresses the CLI resume (it spawns its own)"
else
  bad "7c the board's respond endpoint suppresses the CLI resume (it spawns its own)"
fi
# A gate that is NOT cleared must still exit — never a resume loop.
repo="$(ans_repo plan-review 3 "q?")"
sed -i.bak '/awaitingHuman/d' "$repo/.git/lcars/missions/test-001/state.json"
rm -f "$repo.resumed"
OUTR="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_RUN_SCRIPT="$STUBRUN" \
   bash "$RESPOND" answer --mission test-001 --answer "go" 2>&1 )"; RCR=$?
assert_eq "7d a Mission not awaiting a human is still refused" "$RCR" "1"
if [ -f "$repo.resumed" ]; then
  bad "7e …and never resumes anything"
else
  ok "7e …and never resumes anything"
fi

# ===========================================================================
section "A6 — the hints the driver prints are commands that actually run"
# ===========================================================================
SRC="$REPO_ROOT/skills"
BADPAT='lcars respond \$MISSION_ID|lcars respond <id>|lcars run \$MISSION_ID|lcars run <id>'
badhint=0
while IFS= read -r line; do
  badhint=$((badhint+1)); printf '       %s\n' "$line"
done < <(grep -rnE "$BADPAT" "$SRC/lcars-run/run.sh" "$SRC/lcars-respond/respond.sh" 2>/dev/null)
assert_eq "8a no un-runnable \`lcars respond|run <id>\` text remains in the two scripts" "$badhint" "0"

# The SKILL.md bodies too — but NOT the frontmatter `description:`, which
# describes the NATURAL-LANGUAGE trigger the captain types at his CLI ("lcars
# respond"), not a shell command. Rewriting that would break skill discovery.
#
# S276: the exclusion used to be `grep -v ':[0-9]*:description:'`, which only
# ever skipped the ONE line that starts with `description:`. Every SKILL.md's
# description is now a `>-` BLOCK SCALAR — it had to be, because a strict YAML
# reader (Copilot's) refuses an unquoted one-liner containing ": " — so the
# description spans several INDENTED continuation lines, and a line-prefix
# exclusion no longer covers it. The scan now strips the whole frontmatter
# first, which is what "the SKILL.md bodies" says on the tin.
body_only() { # print a SKILL.md with its `---` frontmatter removed, keeping
              # the original line numbers so a hit is still locatable
  awk -v f="$1" '
    NR==1 && $0=="---" { inf=1; printf "%s:%d:\n", f, NR; next }
    inf && $0=="---"   { inf=0; printf "%s:%d:\n", f, NR; next }
    inf                { printf "%s:%d:\n", f, NR; next }
                       { printf "%s:%d:%s\n", f, NR, $0 }
  ' "$1"
}
badhint=0
while IFS= read -r line; do
  badhint=$((badhint+1)); printf '       %s\n' "$line"
done < <( { body_only "$SRC/lcars-run/SKILL.md"; body_only "$SRC/lcars-respond/SKILL.md"; } \
            | grep -E "$BADPAT" )
assert_eq "8a2 …nor in the SKILL.md bodies" "$badhint" "0"

# The forms that replaced them must be the ones that actually run. Proven by
# RUNNING them, not by trusting the string.
repo="$(ans_repo plan-review 3 "q?")"
OUT1="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_RESPOND_RESUME=0 \
   bash "$RESPOND" answer --mission test-001 --answer "x" 2>&1 )"; RC1=$?
assert_eq "8b \`respond.sh answer --mission <id> --answer …\` really runs" "$RC1" "0"
# A Mission with nothing left to do: `drive` must ACCEPT the verb and exit clean.
repo="$(ans_repo done 0 "q?")"
sed -i.bak '/awaitingHuman/d' "$repo/.git/lcars/missions/test-001/state.json"
OUT2="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_NOTIFY=true \
   bash "$SCRIPT" drive --mission test-001 2>&1 )"; RC2=$?
assert_eq "8c \`run.sh drive --mission <id>\` really runs" "$RC2" "0"
# and the driver's own gate banner now prints a runnable command.
repo="$(ans_repo plan-review 3 "Does the row need a control here?")"
OUT3="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_NOTIFY=true \
   bash "$SCRIPT" drive --mission test-001 2>&1 )"
assert_has "8d the awaiting-human banner names respond.sh" "respond.sh answer --mission test-001" "$OUT3"
assert_no  "8e …and not the form the CLI rejects" 'lcars respond test-001' "$OUT3"

printf '\n────────────────────────────────────────────\n'
printf 'settled-decisions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
