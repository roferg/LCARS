#!/usr/bin/env bash
# S180/B — a negative-existence claim is CHECKED by the harness, and a decision
# recorded at Validate must REACH THE TICKETS.
#
# THE MEASUREMENT (lcars-20260829-002, 2026-08-29/30). A Research worker wrote,
# as a supporting point in research/6.json:
#
#     "There is no WIRED_METRIC_IDS symbol anywhere in the repo (grep returns
#      zero matches)"
#
# It was FALSE — the name is defined and used three times in the one file the
# Mission was about to rewrite — and nobody ran the grep the sentence reports.
# It then propagated (validated-plan.md 2 occurrences, adr.md 2) and EVAPORATED
# (plan.json 0, approved-plan.json 0), so the prohibition built on it reached no
# ticket, the implementer left the existing list in place and added the new rule
# beside it, and one control shipped gated on BOTH.
#
# Two holes. ONE deterministic check ships:
#   B1  the harness runs the search itself (`git grep`), and parks the Mission
#       when the repository contradicts the finding.
#
# THE SECOND — B2, `plan_prohibition_check`: a name the validated plan's
# `## Decisions` section PROHIBITS must be named by a ticket — was built, took
# three rounds, and was PULLED by the captain. Each fix traded one failure for
# another; the last one false-positived on a plain mission, reading a
# test-coverage bullet ("check that `getRecent()` returns a defensive copy …
# does not affect subsequent calls") as a prohibition of `getRecent`. That is
# the S147/S156/S157 shape: a prose classifier past three rounds is cured by
# DELETION. Its code, tests and fixtures are in git at 8c5d5a2 and its live
# drives under tests/drives/align-heal/runs/; it returns in its own session
# against a MIXED corpus that holds that false positive as a fixture.
#
# ⛔ THE ANTI-CLASSIFIER PROOF IS THE POINT OF THIS FILE. S147/S156/S157 each
# spent a session on a text classifier and each was cured by DELETING it. So the
# heaviest test here is section 2: every negative-existence sentence the
# captain's 58 real Missions produced — 126 of them, VERBATIM, in
# tests/fixtures/claims/swept-research/ — must be REFUSED, with the single
# fabrication above the only thing that fires.
#
# GENERICITY. Every behaviour is proven on TWO unrelated fixtures: the measured
# Mission's own artifacts, and a Budget-Lines fixture derived from
# tests/drives/undrawn/budget-brief.txt that shares not one noun with it.
#
# Deliberately NOT the heavy tests/lcars-run.test.sh. NO worker is ever spawned,
# NO token is ever spent.
#
#   bash tests/claim-check.test.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FIX="$REPO_ROOT/tests/fixtures/claims"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Part A measured this: without it a respond/drive path can launch a REAL driver.
export LCARS_RESPOND_RESUME=0

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
assert_has() { if has "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_no()  { if has "$2" "$3"; then bad "$1 (present but must not be: $2)"; else ok "$1"; fi; }
assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
section() { printf '\n%s\n' "$1"; }

scan() { # mode file… -> path<TAB>id<TAB>sentence lines
  local mode="$1"; shift
  LCARS_CLAIM_MODE="$mode" LCARS_CLAIM_FILES="$*" bash "$SCRIPT" claim-scan-test 2>&1
}
ids() { printf '%s\n' "$1" | awk -F'\t' 'NF>1{print $2}' | sort -u | paste -sd, - ; }

# ===========================================================================
section "1 — the scan FIRES on a repo-wide absence claim about a named identifier"
# ===========================================================================
SA="$(scan absent-claim "$FIX"/measured-research/*.json)"
assert_eq  "1a fixture A yields exactly ONE candidate" "$(printf '%s\n' "$SA" | grep -c .)" "1"
assert_eq  "1b …and it is the fabricated name"        "$(ids "$SA")" "WIRED_METRIC_IDS"
assert_has "1c …carrying the sentence that made the claim" \
           "There is no WIRED_METRIC_IDS symbol anywhere in the repo" "$SA"
# The SAME finding asserts things about names that DO exist, in the same file,
# in the same three paragraphs. None of them may be dragged in.
assert_no  "1d …and nothing else from the same finding" "aiUpdateInstructions	" "$SA"

SB="$(scan absent-claim "$FIX"/budget-research/*.json)"
assert_eq  "1e fixture B yields exactly ONE candidate" "$(printf '%s\n' "$SB" | grep -c .)" "1"
assert_eq  "1f …and it is ITS fabricated name"        "$(ids "$SB")" "SYNCED_LINE_IDS"
assert_no  "1g …and carries NOTHING of the other fixture" "WIRED" "$SB"
assert_no  "1h …nor of its own file's SCOPED claims"  "probeCloseEndpoint" "$SB"
assert_no  "1i …nor its conceptual ones"              "child_process" "$SB"

# ===========================================================================
section "2 — THE ANTI-CLASSIFIER PROOF: silent on 126 REAL near-miss sentences"
# ===========================================================================
# tests/fixtures/claims/swept-research/*.json holds EVERY sentence a crude
# negative-existence regex flags across all 144 research findings of all 58
# Missions in the captain's own repo — verbatim, with the one fabrication
# removed. A rule that reads meaning instead of shape lights up here.
NM="$(scan absent-claim "$FIX"/swept-research/*.json)"
assert_eq "2a the real near-miss corpus fires NOTHING" "$(printf '%s\n' "$NM" | grep -c .)" "0"
NMN="$("${LCARS_PYTHON_BIN:-python3}" - "$FIX"/swept-research/*.json <<'CNT'
import json, sys
print(sum(len(json.load(open(f))["supporting_points"]) for f in sys.argv[1:]))
CNT
)"
if [ "${NMN:-0}" -ge 100 ]; then
  ok "2b …and the corpus really is that big ($NMN sentences)"
else
  bad "2b …and the corpus really is that big (only ${NMN:-0} sentences)"
fi
# Named shapes that must NEVER be read as a claim, one assertion each, so a
# regression names the shape it broke.
probe() { # label json-body must-be-empty
  local d; d="$(mktemp -d "$TMPROOT/p.XXXX")"
  printf '%s\n' "$2" > "$d/1.json"
  local out; out="$(scan absent-claim "$d/1.json")"
  if [ -z "$out" ]; then ok "$1"; else bad "$1 (fired: $(ids "$out"))"; fi
}
J() { printf '{ "question":"q", "recommendation":"r", "supporting_points": [%s] }' "$1"; }
probe "2c a SCOPED claim (one file, not the repo) is refused" \
      "$(J '"BudgetLinesView.tsx contains no probeCloseEndpoint reference."')"
probe "2d a QUALIFIED claim (absent FOR A SUBJECT) is refused" \
      "$(J '"Codebase search shows no child_process invocation tied to the roll-up."')"
probe "2e a CONCEPTUAL claim naming no identifier is refused" \
      "$(J '"There is no export functionality anywhere in the repo."')"
probe "2f a lone lowercase word is not an identifier" \
      "$(J '"The codebase has no `shape` field anywhere in the repo."')"
probe "2g a lone PascalCase word is not an identifier" \
      "$(J '"There is no SubReading anywhere in the repo."')"
probe "2h an identifier in a DIFFERENT clause is not the negated one" \
      "$(J '"No such check exists anywhere in the repo: buildSnapshot assigns the value verbatim."')"
probe "2i an identifier after a contrast conjunction is not the negated one" \
      "$(J '"There is no such helper anywhere in the repo, but refreshAll covers it."')"
probe "2j a name inside a quoted error string is not a repo-wide claim" \
      "$(J '"The guard raises collectFailure(\"row has no pullRecipe; nothing to sync\")."')"
# …and the shape that MUST fire still does, in a file of its own.
probe_fires() { # label body wanted-id
  local d; d="$(mktemp -d "$TMPROOT/pf.XXXX")"
  printf '%s\n' "$2" > "$d/1.json"
  assert_eq "$1" "$(ids "$(scan absent-claim "$d/1.json")")" "$3"
}
probe_fires "2k an UNQUALIFIED repo-wide claim about a named identifier fires" \
            "$(J '"There is no PULL_RECIPE_IDS symbol anywhere in the repo (grep returns zero matches)."')" \
            "PULL_RECIPE_IDS"
probe_fires "2l …and on a camelCase name too" \
            "$(J '"No pullRecipeIds constant exists anywhere in the codebase."')" \
            "pullRecipeIds"
# THE PROHIBITION SHAPES, put to B1 as a finding's own claim, must STILL be
# refused. These three sentences are real prohibition phrasings lifted off live
# validated plans — the shapes B2 (pulled; see the header) was widened to accept.
# B1 sweeps FREE PROSE and must stay strict, so a future widening of the shared
# reader cannot quietly loosen it.
probe "2m B1 refuses a prohibition qualified by a verb phrase" \
      "$(J '"Populate the field; do not grow a hardcoded id list and do not conflate with `PULL_RECIPE_IDS`."')"
probe "2n B1 refuses a prohibition on ADDING a named field" \
      "$(J '"Do not add a `pullRecipeIds` field anywhere in the repo — the existing predicate stays."')"
probe "2o B1 refuses a NEVER-read prohibition" \
      "$(J '"Never read the codebase draft'"'"'s embedded `pullRecipeIds` as the automatability signal."')"

# ===========================================================================
section "3 — the VERDICT is a literal search the harness runs"
# ===========================================================================
claim_repo() { # research-src-dir  "symbol-to-plant-or-empty"  -> repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/cr.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    printf '# fixture\n' > README.md
    if [ -n "$2" ]; then
      printf 'export const %s: readonly string[] = [];\nconst use = %s;\n' "$2" "$2" > src.ts
    else
      printf 'export const somethingElse = 1;\n' > src.ts
    fi
    git add -A && git commit -q -m init
    git branch -q lcars/test-001
  ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d/research"
  cp "$1"/*.json "$d/research/"
  cat > "$d/state.json" <<'JSON'
{ "id": "test-001", "stage": "align", "branch": "lcars/test-001", "base": "main" }
JSON
  echo "$repo"
}
run_check() { # repo
  CHKOUT="$( cd "$1" && env LCARS_ATT_TEST_DIR="$1/.git/lcars/missions/test-001" \
      LCARS_CLAIM_REPO="$1" bash "$SCRIPT" claim-check-test 2>&1 )"
  CHKRC=$?
}

# --- fixture A: the name IS there -> REFUTED ---------------------------------
repo="$(claim_repo "$FIX/measured-research" WIRED_METRIC_IDS)"
run_check "$repo"
assert_eq  "3a the check REFUTES the measured claim" "$CHKRC" "1"
assert_has "3b …naming the identifier"      'name `WIRED_METRIC_IDS`' "$CHKOUT"
assert_has "3c …the ref it searched"        'search of `lcars/test-001`' "$CHKOUT"
assert_has "3d …how many lines it found"    "returns 2 line(s)" "$CHKOUT"
assert_has "3e …and WHERE"                  "src.ts:1" "$CHKOUT"
assert_has "3f …quoting the finding's own sentence" \
           "There is no WIRED_METRIC_IDS symbol anywhere in the repo" "$CHKOUT"
assert_has "3g …and which finding said it"  "6.json" "$CHKOUT"
assert_eq  "3h …as ONE line (write_pending splits on newlines)" \
           "$(printf '%s\n' "$CHKOUT" | grep -c .)" "1"

# --- THE IMPORTANT HALF: genuinely absent -> SILENT --------------------------
repo="$(claim_repo "$FIX/measured-research" "")"
run_check "$repo"
assert_eq "3i a claim the repo CONFIRMS is silent" "$CHKRC" "0"
assert_eq "3j …and says nothing at all"            "$CHKOUT" ""

# --- fixture B, both ways ----------------------------------------------------
repo="$(claim_repo "$FIX/budget-research" SYNCED_LINE_IDS)"
run_check "$repo"
assert_eq  "3k the unrelated fixture is refuted the same way" "$CHKRC" "1"
assert_has "3l …naming ITS identifier" 'name `SYNCED_LINE_IDS`' "$CHKOUT"
assert_no  "3m …and nothing of the other fixture" "WIRED" "$CHKOUT"
repo="$(claim_repo "$FIX/budget-research" "")"
run_check "$repo"
assert_eq "3n …and is silent when its name really is absent" "$CHKRC" "0"

# --- the whole corpus against a repo that contains ALL of it -----------------
# Every near-miss sentence, checked against a repo where every name it mentions
# is present. Still silent: the scan refused them before any search ran.
repo="$(claim_repo "$FIX/swept-research" ANYTHING)"
( cd "$repo" && git checkout -q -b tmp main 2>/dev/null
  grep -ho '[A-Za-z_$][A-Za-z0-9_$]*' "$FIX"/swept-research/*.json | sort -u > src.ts
  git add -A && git commit -q -m all && git branch -qf lcars/test-001 tmp ) >/dev/null 2>&1
run_check "$repo"
assert_eq "3o the 126-sentence corpus is silent even against a repo holding every name" "$CHKRC" "0"

# --- UNCHECKED is said out loud ----------------------------------------------
repo="$(claim_repo "$FIX/measured-research" WIRED_METRIC_IDS)"
sed -i.bak 's#"branch": "lcars/test-001"#"branch": "lcars/test-001"#' "$repo/.git/lcars/missions/test-001/state.json"
CHKOUT="$( cd "$repo" && env LCARS_ATT_TEST_DIR="$repo/.git/lcars/missions/test-001" \
   LCARS_CLAIM_REPO="$repo" LCARS_CLAIM_REF=refs/heads/nope bash "$SCRIPT" claim-check-test 2>&1 )"; CHKRC=$?
assert_eq  "3p an unreadable ref is UNCHECKED, not clean" "$CHKRC" "3"
assert_has "3q …and says so"  "CLAIM CHECK UNCHECKED" "$CHKOUT"

# ===========================================================================
section "4 — Research SAVE parks the Mission instead of advancing on a fabrication"
# ===========================================================================
save_repo() { # research-src  symbol-or-empty -> repo (mission at align, responses staged)
  local repo; repo="$(claim_repo "$1" "$2")"
  local d="$repo/.git/lcars/missions/test-001"
  mkdir -p "$repo.resp"; cp "$1"/*.json "$repo.resp/"
  rm -rf "$d/research"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  echo "$repo"
}
run_save() { # repo [run.sh-override]
  SAVEOUT="$( cd "$1" && env LCARS_GH_BIN="$1.gh" \
      bash "${2:-$SCRIPT}" save --mission test-001 --responses "$1.resp" 2>&1 )"
  SAVERC=$?
  SD="$1/.git/lcars/missions/test-001"
}
stg() { sed -n 's/.*"stage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/state.json" | head -1; }

repo="$(save_repo "$FIX/measured-research" WIRED_METRIC_IDS)"
run_save "$repo"
assert_eq  "4a the save still SUCCEEDS (a park is not an error)" "$SAVERC" "0"
assert_eq  "4b …the findings are on disk for the captain to read" \
           "$(ls "$SD/research"/*.json 2>/dev/null | wc -l | tr -d ' ')" "3"
assert_eq  "4c …the Mission is parked at Validate"  "$(stg "$SD")" "validate"
assert_has "4d …awaiting the human"        '"awaitingHuman": true' "$(cat "$SD/state.json")"
assert_has "4e …with the refutation as the pending question" \
           "WIRED_METRIC_IDS" "$(cat "$SD/pending.json")"
assert_has "4f …the pending question is filed against Validate" \
           '"stage": "validate"' "$(cat "$SD/pending.json")"
if [ -f "$SD/claim-check.txt" ]; then ok "4g …and a durable record is written"
else bad "4g …and a durable record is written"; fi
assert_no  "4h …deliberately NOT inside research/ (it is not a finding)" \
           "claim-check" "$(ls "$SD/research")"
assert_has "4i the operator is told what was refuted" "REFUTED" "$SAVEOUT"
assert_has "4j …and how to answer, with a command that runs" "respond.sh answer --mission test-001" "$SAVEOUT"
assert_no  "4k …and NOT the form the CLI rejects" 'lcars respond test-001' "$SAVEOUT"

repo="$(save_repo "$FIX/budget-research" SYNCED_LINE_IDS)"
run_save "$repo"
assert_eq  "4l the unrelated Mission parks the same way" "$(stg "$SD")" "validate"
assert_has "4m …on ITS identifier" "SYNCED_LINE_IDS" "$(cat "$SD/pending.json")"
assert_no  "4n …and nothing of the other fixture" "WIRED" "$(cat "$SD/pending.json")"

# --- the NO-CLAIM path advances exactly as before ----------------------------
repo="$(save_repo "$FIX/swept-research" ANYTHING)"
run_save "$repo"
NOCLAIM_OUT="$SAVEOUT"
assert_eq "4o a Mission with no refuted claim ADVANCES"    "$(stg "$SD")" "validate"
assert_no "4p …and is not parked" '"awaitingHuman": true' "$(cat "$SD/state.json")"
assert_no "4q …and says nothing about a claim"             "REFUTED" "$SAVEOUT"

# --- BYTE-IDENTITY against the previous commit -------------------------------
BASE_DIR="$TMPROOT/skill-base"; mkdir -p "$BASE_DIR"
for f in "$REPO_ROOT"/skills/lcars-run/*; do
  [ "$(basename "$f")" = "run.sh" ] && continue
  ln -s "$f" "$BASE_DIR/$(basename "$f")" 2>/dev/null || :
done
BASE_SH="$BASE_DIR/run.sh"
if ( cd "$REPO_ROOT" && git show "${LCARS_BASE_REF:-HEAD}:skills/lcars-run/run.sh" > "$BASE_SH" ) 2>/dev/null && [ -s "$BASE_SH" ]; then
  repo2="$(save_repo "$FIX/swept-research" ANYTHING)"
  run_save "$repo2" "$BASE_SH"
  if [ "$NOCLAIM_OUT" = "$SAVEOUT" ]; then
    ok "4r a no-claim Research SAVE is BYTE-IDENTICAL to the previous commit's"
  else
    bad "4r a no-claim Research SAVE is BYTE-IDENTICAL to the previous commit's"
    diff <(printf '%s\n' "$NOCLAIM_OUT") <(printf '%s\n' "$SAVEOUT") | sed 's/^/       /'
  fi
else
  bad "4r could not read ${LCARS_BASE_REF:-HEAD}:skills/lcars-run/run.sh for the byte-identity baseline"
fi

# ===========================================================================
section "5 — THE FALSE POSITIVE THAT PULLED B2, kept as a FENCE"
# ===========================================================================
# B2 (plan_prohibition_check) is GONE — three rounds, each fix trading one
# failure for another. The last one, MEASURED on a live plain mission
# (tests/drives/align-heal/runs/plain-1), read a TEST-COVERAGE bullet in the
# validated plan's `## Decisions` section —
#
#   "…and that `getRecent()` returns a defensive copy (mutating the returned
#    array does not affect subsequent `getRecent()` calls)"
#
# — as a PROHIBITION of `getRecent`, and bounced an honest, complete plan for
# not "carrying" it. The sentence prohibits nothing; it describes a test.
#
# This is not a test of the deleted code. It is the FENCE the next B2 must clear,
# driven through the REAL `plan-save` path over the drive's own artifacts: this
# exact pair must SAVE, silently. Nothing in the removal makes it pass by
# accident — the same pair is what bounced.
REPRO="$REPO_ROOT/tests/drives/align-heal/runs/plain-1"
plan_repo() { # validated-plan  -> repo with a mission at stage plan
  local repo; repo="$(mktemp -d "$TMPROOT/pl.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t \
    && printf '# f\n' > README.md && git add -A && git commit -q -m init ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<'JSON'
{ "id": "test-001", "stage": "plan", "branch": "lcars/test-001", "base": "main" }
JSON
  cp "$1" "$d/validated-plan.md"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  echo "$repo"
}
run_plan_save() { # repo plan-json [--final-attempt] [run.sh-override]
  local repo="$1" pj="$2" extra="${3:-}" sh="${4:-$SCRIPT}"
  mkdir -p "$repo.odir"; cp "$pj" "$repo.odir/plan.json"; rm -f "$repo.odir/.plan-reject-note"
  PSOUT="$( cd "$repo" && env LCARS_GH_BIN="$repo.gh" \
      bash "$sh" plan-save --mission test-001 --plan "$repo.odir/plan.json" $extra 2>&1 )"
  PSRC=$?
  PSD="$repo/.git/lcars/missions/test-001"
}

if [ -f "$REPRO/mission-final-snapshot/validated-plan.md" ] \
   && [ -f "$REPRO/b2-falsepositive-repro-plan.json" ]; then
  # The bullet really is in there, verbatim — otherwise this fence proves nothing.
  assert_has "5a the live plain mission's decisions really do carry the bullet" \
             'does not affect subsequent `getRecent()` calls' \
             "$(cat "$REPRO/mission-final-snapshot/validated-plan.md")"
  repo="$(plan_repo "$REPRO/mission-final-snapshot/validated-plan.md")"
  run_plan_save "$repo" "$REPRO/b2-falsepositive-repro-plan.json"
  assert_eq "5b …and the plan that bounced on it now SAVES" "$PSRC" "0"
  assert_no "5c …with nothing said about a decision reaching no ticket" \
            "REACHED NO TICKET" "$PSOUT"
  assert_no "5d …and no carry-through verdict of any kind" "DECISION" "$PSOUT"
  if [ -f "$repo.odir/.plan-reject-note" ]; then
    bad "5e …and no rejection note is left for the retry loop"
  else
    ok "5e …and no rejection note is left for the retry loop"
  fi
  assert_eq "5f …and the Mission advances to Plan Review" \
            "$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$PSD/state.json" | head -1)" "plan-review"
else
  bad "5a the plain-mission repro artifacts are missing — the fence is NOT checked"
fi

# ===========================================================================
section "7 — THE GENERICITY FENCE"
# ===========================================================================
# S179 measured a FILLED-IN worked example in a prompt being copied verbatim onto
# an unrelated screen by 3 of 3 live turns. Nothing this round adds may carry one
# screen's nouns. Checked over EVERY string this round emits to a worker or a
# human: the refutation question and the operator output.
# The QUOTED artifact lines and the SUBSTITUTED identifier are the Mission's own
# words, not vocabulary this round authored — normalise them out and check what
# is left, which is every word run.sh actually wrote.
repo="$(save_repo "$FIX/measured-research" WIRED_METRIC_IDS)"; run_save "$repo"; SAVE_A="$SAVEOUT"
repo="$(save_repo "$FIX/budget-research" SYNCED_LINE_IDS)"; run_save "$repo"; SAVE_B="$SAVEOUT"
SP="$(printf '%s\n%s\n' "$SAVE_A" "$SAVE_B" | grep -v '^    • ' \
  | sed -e 's/WIRED_METRIC_IDS/<ID>/g' -e 's/SYNCED_LINE_IDS/<ID>/g')"
for w in KPI insight cohort collect MBR month lock unlock wired metric automatable \
         budget quarter "cost centre" sync currency spend recipe; do
  if printf '%s\n' "$SP" | grep -qiE "(^|[^A-Za-z])$w([^A-Za-z]|$)"; then
    bad "7a the round's PROSE must carry no domain vocabulary (found: $w)"
  else
    ok "7a the round's PROSE carries no domain vocabulary ($w)"
  fi
done
# And the run.sh prose the two checks emit is built from the ARTIFACTS, never
# from a worked example: no filled-in illustration may sit in the source.
if grep -n 'WIRED_METRIC_IDS\|SYNCED_LINE_IDS' "$REPO_ROOT/skills/lcars-run/run.sh" \
     | grep -v '^[0-9]*:#' | grep -q .; then
  bad "7b no fixture identifier is baked into run.sh's executable text"
else
  ok "7b no fixture identifier is baked into run.sh's executable text"
fi

# ===========================================================================
section "8 — END TO END: the whole Research Stage parks, and the driver halts"
# ===========================================================================
# Not just cmd_save in isolation: the real cmd_research path — question generator,
# per-question fan-out, save — over a STUB worker adapter, so the Stage that
# produced the measured fabrication is driven end to end with zero tokens.
e2e_repo() { # research-src  symbol-or-empty -> repo at stage align
  local repo; repo="$(mktemp -d "$TMPROOT/e2e.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    printf '# fixture\n' > README.md
    printf '# Context\n\nA fixture repo.\n' > CONTEXT.md
    if [ -n "$2" ]; then
      printf 'export const %s: readonly string[] = [];\n' "$2" > src.ts
    else
      printf 'export const somethingElse = 1;\n' > src.ts
    fi
    git add -A && git commit -q -m init
    git branch -q lcars/test-001
  ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "align",
  "branch": "lcars/test-001", "base": "main", "githubIssue": null }
JSON
  printf '# PRD\n\nBuild the thing.\n' > "$d/prd.md"
  cat >"$repo.adapter" <<EOF
#!/usr/bin/env bash
sub="\$1"; role="\${LCARS_WORKER_ROLE:-\$3}"; outdir="\$4"
[ "\$sub" = "spawn" ] || exit 0
case "\$role" in
  research-questions) printf 'How is the thing classified?\n' > "\$outdir/questions.txt" ;;
  research-agent)     mkdir -p "\$outdir"; cp "$repo.finding" "\$outdir/response.json" ;;
esac
exit 0
EOF
  chmod +x "$repo.adapter"
  cp "$1"/1.json "$repo.finding" 2>/dev/null || cp "$1"/6.json "$repo.finding"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.worker"; chmod +x "$repo.worker"
  echo "$repo"
}
run_drive() { # repo
  DRIVEOUT="$( cd "$1" && env LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 LCARS_NOTIFY=true \
      bash "$SCRIPT" drive --mission test-001 2>&1 )"
  DRIVERC=$?
  ED="$1/.git/lcars/missions/test-001"
}

# The measured finding, against a repo that HAS the name it says is absent.
cp "$FIX/measured-research/6.json" "$TMPROOT/one-A.json"
mkdir -p "$TMPROOT/srcA" && cp "$TMPROOT/one-A.json" "$TMPROOT/srcA/1.json"
repo="$(e2e_repo "$TMPROOT/srcA" WIRED_METRIC_IDS)"
run_drive "$repo"
assert_eq  "8a the driver stops cleanly" "$DRIVERC" "0"
assert_eq  "8b …with the Mission parked at Validate" \
           "$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$ED/state.json" | head -1)" "validate"
assert_has "8c …awaiting the human"  '"awaitingHuman": true' "$(cat "$ED/state.json")"
assert_has "8d …over the refuted name" "WIRED_METRIC_IDS" "$(cat "$ED/pending.json")"
assert_has "8e …and the driver says it stopped at a gate" "awaiting" "$DRIVEOUT"

# The unrelated fixture, same path.
mkdir -p "$TMPROOT/srcB" && cp "$FIX/budget-research/1.json" "$TMPROOT/srcB/1.json"
repo="$(e2e_repo "$TMPROOT/srcB" SYNCED_LINE_IDS)"
run_drive "$repo"
assert_eq  "8f the unrelated Mission parks the same way" \
           "$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$ED/state.json" | head -1)" "validate"
assert_has "8g …over ITS name" "SYNCED_LINE_IDS" "$(cat "$ED/pending.json")"

# THE CONTROL: the SAME finding against a repo that really lacks the name.
# It must flow straight through Research without stopping.
repo="$(e2e_repo "$TMPROOT/srcB" "")"
run_drive "$repo"
assert_no "8h a TRUE absence claim never parks the Mission" \
          '"awaitingHuman": true' "$(cat "$ED/state.json")"
# …and prove the Stage really RAN rather than dying early: the finding is saved.
if [ -f "$ED/research/1.json" ] && grep -q SYNCED_LINE_IDS "$ED/research/1.json"; then
  ok "8i …and Research still saved the finding and moved on"
else
  bad "8i …and Research still saved the finding and moved on"
fi

printf '\n────────────────────────────────────────────\n'
printf 'claim-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
