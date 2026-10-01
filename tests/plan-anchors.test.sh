#!/usr/bin/env bash
#
# S237 — THE ANCHOR RULE IS INJECTED; AN ANCHOR FAILURE PATCHES OR PARKS.
# Fast, SCOPED suite. Stubbed workers only; no model, no tokens.
#
# THE GROUND TRUTH THIS EXISTS FOR. Over the weekend of 26–29 Sep a Plan Stage
# burned SIX failed attempts across TWO missions and then stopped dead. The
# Plan prompt told the worker its `drawnAt` was "your own words; there is no
# list of allowed anchors", while `validate_plan_json` REQUIRES a real element
# id from the drawing and at least one `drawnAt` per visual ticket. The prompt
# said "your own words", the validator said "a real id": that gap is the loop.
# The cure that worked first time, by hand, was the captain pasting the rule
# VERBATIM with the actual list of anchors into the PRD's Constraints.
#
# Three things are driven here:
#   A. INJECT — a mission WITH a mockup gets the rule text and the drawing's
#      ACTUAL anchor list in its assembled Plan prompt; a mission WITHOUT one
#      gets neither. Both directions: one direction cannot detect its own
#      breakage.
#   B. INJECT AT ALIGN — `file.sh` writes the same rule, from the same one
#      source file, into the PRD's Constraints, ONCE, and is idempotent.
#   C. PATCH, DON'T RE-PLAN — an anchor-only rejection names the failing
#      tickets and the valid anchors, tells the retry to fix ONLY those, and
#      REFUSES a retry that edited a ticket it was told to leave alone.
#   D. PARK, DON'T STOP — the final anchor-only failure parks the mission
#      awaiting-human with the anchors in the question, labels the card and
#      fires notify, instead of the stage stop.
#   E. CONSUME — `lcars answer` records the anchor and the next Plan run passes
#      with the answer injected.
#   F. A NON-ANCHOR failure keeps today's behaviour EXACTLY, stage stop and all.
#   G. ONE SOURCE — the rule text lives in exactly one file.
#
# FIX ROUND 1 (three defects a live tester found driving the real product):
#   H. THE WALK-AWAY PROMISE — a parked question renders IN FULL on the DRIVER
#      surface, escaped quotes and all, one question to a line. Cured as a
#      CLASS: ONE shared JSON reader, no fourth hand-rolled grep/sed read.
#   I. ONLY AN ANCHOR FAILURE PARKS — a missing "text", two declarations or a
#      wrong type fall through to the stage stop with their real reason; a
#      genuine bad or missing anchor still parks (the narrowing's control).
#   J. THE RETRY IS HANDED THE PLAN it is told to patch, so "keep every OTHER
#      ticket byte-identical — THIS IS CHECKED" is satisfiable at all.
#
# WHAT THIS SUITE CANNOT SHOW: the workers are STUBBED, so nothing here proves
# a REAL planner obeys the injected list. That is a live Copilot/Claude drive.
#
# NEVER run the full tests/run.sh for this. Usage: bash tests/plan-anchors.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
STAGES="$REPO_ROOT/skills/lcars-run/stages"
RULE_FILE="$STAGES/anchor-rule.md"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "S237 — plan anchors: inject, patch, park"

# The S237 rig's drawing (tests/drives/s237/mockup/pages-viewer.html): ELEVEN
# ids across three drawn screens. `landing-nav` is DELIBERATELY ABSENT — the
# PRD asks for a nav link on a page the drawing does not contain, which is the
# exact shape that looped on the weekend.
DRAWING="$TMPROOT/drawing.html"
cat > "$DRAWING" <<'HTML'
<!doctype html><html><body>
<section id="v-board"><h1 id="board-title">Requests</h1><div id="board-grid">
  <article id="request-card"><p id="request-text">t</p><time id="request-created">now</time></article>
</div></section>
<section id="v-person"><h1 id="person-name">Rogan</h1><div id="person-grid"></div></section>
<section id="v-empty"><p id="empty-hint">Nothing yet</p></section>
</body></html>
HTML
# Sorted + deduped, exactly as mission_mockup_place_names emits them.
ANCHORS="board-grid board-title empty-hint person-grid person-name request-card request-created request-text v-board v-empty v-person"

# ===========================================================================
section "G. ONE source of the rule text (no second copy to drift)"
# ===========================================================================
check "G1 the rule text lives in a single source file under stages/" \
  "[ -f '$RULE_FILE' ]"
check "G2 …and it carries the weekend's verbatim rule" \
  "grep -q 'PLAN RULE:' '$RULE_FILE'"
# Neither consumer may spell the rule itself — both must READ that file.
check "G3 run.sh does not spell the rule text itself" \
  "! grep -q 'PLAN RULE: every criterion' '$REPO_ROOT/skills/lcars-run/run.sh'"
check "G4 file.sh does not spell the rule text itself" \
  "! grep -q 'PLAN RULE: every criterion' '$REPO_ROOT/skills/lcars-file/file.sh'"
check "G5 exactly ONE tracked source file carries the rule literal" \
  "[ \"\$(cd '$REPO_ROOT' && grep -rl 'PLAN RULE: every criterion' skills/ 2>/dev/null | wc -l | tr -d ' ')\" = 1 ]"

# ===========================================================================
section "A. INJECT at Plan — the rule AND the drawing's actual anchors"
# ===========================================================================
# A stub worker adapter that RECORDS every assembled prompt and answers the
# plan role with the fixture plan named by $STUB_PLAN.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
case "$role" in
  plan)        [ -n "${STUB_PLAN:-}" ] && cp "$STUB_PLAN" "$outdir/plan.json" ;;
  plan-review) printf '{ "passed": true, "issues": [] }\n' > "$outdir/verdict.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A real git repo on a real mission branch parked at `plan`, optionally carrying
# the drawing as attachment-01.html.
e2e_repo() { # with-mockup(yes|no) -> echoes repo dir
  local want="$1"
  local repo; repo="$(mktemp -d "$TMPROOT/e2e.XXXX")"
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
  # ONE FIELD PER LINE — lcars_state_set edits LINES and refuses anything else.
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": 42
}
JSON
  printf '# PRD\n\n## Goal\nA board filter and a landing nav link.\n\n## Constraints\nStdlib only.\n' > "$d/prd.md"
  printf '# Validated Plan\n\n## Synthesis\nBuild it.\n' > "$d/validated-plan.md"
  if [ "$want" = yes ]; then
    mkdir -p "$d/attachments"; cp "$DRAWING" "$d/attachments/attachment-01.html"
  fi
  make_adapter "$repo.adapter"
  printf '#!/usr/bin/env bash\necho UNEXPECTED-SPAWN >&2\nexit 96\n' >"$repo.worker"; chmod +x "$repo.worker"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s.gh.log"\nexit 0\n' "$repo" >"$repo.gh"; chmod +x "$repo.gh"
  printf '#!/usr/bin/env bash\necho "notify $*" >> "%s.notify.log"\nexit 0\n' "$repo" >"$repo.notify"; chmod +x "$repo.notify"
  : >"$repo.gh.log"; : >"$repo.notify.log"
  echo "$repo"
}

run_plan_stage() { # repo [tries] -> sets RC, OUT, PROMPT_FILE
  : >"$1.prompts"
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      LCARS_NOTIFY="$1.notify" LCARS_WORKER_TRIES="${2:-3}" \
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/usr/bin/false \
      PROMPTS="$1.prompts" STUB_PLAN="${STUB_PLAN:-}" \
      bash "$SCRIPT" plan --mission test-001 2>&1 )"
  RC=$?
  PROMPT_FILE="$1.prompts"
}

# A plan that PASSES the mockup contract: one visual ticket anchored at a real
# id, one notDrawn for the undrawn landing nav.
cat > "$TMPROOT/good-plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Board status filter",
    "description": "Add the open/all control above the grid.",
    "acceptanceCriteria": [{"text": "a status control sits above the grid", "drawnAt": "#board-grid, directly above it"}],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "the filter is the slice"
  },
  {
    "id": "t-002",
    "title": "Landing nav link",
    "description": "Add a Requests link to the landing nav.",
    "acceptanceCriteria": [{"text": "the landing nav carries a Requests link", "drawnAt": "#v-board, reached from the nav"}, {"text": "the link points at the board", "notVisual": true}],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "one nav link"
  }
]
JSON

# A plan whose t-002 cites a place the drawing does NOT have (`landing-nav`) —
# the weekend's exact failure. t-001 is clean.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/bad-t002.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[1]["acceptanceCriteria"][0]["drawnAt"] = "#landing-nav, the top nav"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY

R_MOCK="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/good-plan.json" run_plan_stage "$R_MOCK"
check "1a the Plan stage runs on a mission carrying a mockup" "[ '$RC' -eq 0 ]"
check "1b the assembled Plan prompt carries the rule VERBATIM" \
  "grep -q 'PLAN RULE:' '$PROMPT_FILE'"
ANCHORS_ON_RULE_LINE=1
for a in $ANCHORS; do
  grep 'PLAN RULE:' "$PROMPT_FILE" | grep -q "$a" || ANCHORS_ON_RULE_LINE=0
done
check "1c …and the rule line itself lists EVERY anchor the drawing has" \
  "[ '$ANCHORS_ON_RULE_LINE' = 1 ]"
check "1d …and the prompt no longer contradicts the validator ('no list of allowed anchors')" \
  "! grep -q 'list of allowed anchors' '$PROMPT_FILE'"

R_NOMOCK="$(e2e_repo no)"
STUB_PLAN="$TMPROOT/good-plan-nomock.json"
# Without a mockup, criteria are plain strings and no declaration is required.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$STUB_PLAN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d:
    t["acceptanceCriteria"] = [c["text"] for c in t["acceptanceCriteria"]]
    t.pop("changesScreenAppearance", None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
run_plan_stage "$R_NOMOCK"
check "1e the Plan stage runs on a mission with NO mockup" "[ '$RC' -eq 0 ]"
check "1f …and its prompt carries NO rule text" "! grep -q 'PLAN RULE:' '$PROMPT_FILE'"
check "1g …and NO anchor list" "! grep -q 'v-board' '$PROMPT_FILE'"

# A drawing with NO element ids — the graceful-degradation path. There is no
# list to hand over, so the UNFENCED form of the rule is what gets injected, and
# the prompt must not claim a list exists.
BLANK="$TMPROOT/blank.html"
printf '<!doctype html><html><body><div>a board</div></body></html>\n' > "$BLANK"
R_BLANK="$(e2e_repo yes)"
cp "$BLANK" "$R_BLANK/.git/lcars/missions/test-001/attachments/attachment-01.html"
STUB_PLAN="$TMPROOT/good-plan.json" run_plan_stage "$R_BLANK"
check "1h a mockup with NO element ids still gets the rule" \
  "[ '$RC' -eq 0 ] && grep -q 'PLAN RULE:' '$PROMPT_FILE'"
check "1i …in its UNFENCED form, with no list it cannot produce" \
  "grep 'PLAN RULE:' '$PROMPT_FILE' | grep -q 'each criterion' && ! grep 'PLAN RULE:' '$PROMPT_FILE' | grep -qF '('"
check "1j …and the prompt says so instead of claiming a list" \
  "grep -q 'anchors go UNFENCED' '$PROMPT_FILE'"

# ===========================================================================
section "B. INJECT at Align — file.sh writes the rule into Constraints"
# ===========================================================================
ESTIMATOR_STUB="$TMPROOT/estimator.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ESTIMATOR_STUB"; chmod +x "$ESTIMATOR_STUB"

file_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/file.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'JSON'
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
JSON
  printf '#!/usr/bin/env bash\nif [ "$1" = issue ] && [ "$2" = create ]; then echo "https://github.com/o/r/issues/42"; fi\nexit 0\n' >"$repo/gh"
  chmod +x "$repo/gh"
  echo "$repo"
}

write_prd_in() { # path [extra-constraint]
  cat >"$1" <<EOF
# Mission: Request Relay gets a status filter

**Type:** feature
**Goal:** The board gains a status filter and the landing page gains a nav link.
**Acceptance Criteria:**
- The board shows a status control above the grid
- The landing nav carries a Requests link
**Out of Scope:**
- Pagination
**Constraints:**
- Stdlib only; no frameworks
${2:-}
EOF
}

FR="$(file_repo)"; PRD_IN="$FR/prd-in.md"; write_prd_in "$PRD_IN"
( cd "$FR" && LCARS_RUN_BIN="$ESTIMATOR_STUB" LCARS_GH_BIN="$FR/gh" LCARS_DATE=20260530 \
    bash "$FILE_SCRIPT" --prd "$PRD_IN" --attach "$DRAWING" >out.txt 2>&1 )
MDIR="$FR/.git/lcars/missions/lcars-20260530-001-c10e"
check "2a file.sh with a mockup attachment files the mission" "[ -f '$MDIR/prd.md' ]"
check "2b the PRD on disk carries the rule" "grep -q 'PLAN RULE:' '$MDIR/prd.md'"
check "2c …exactly ONCE" \
  "[ \"\$(grep -c 'PLAN RULE:' '$MDIR/prd.md')\" = 1 ]"
check "2d …with the drawing's actual anchors" \
  "grep 'PLAN RULE:' '$MDIR/prd.md' | grep -q 'v-board' && grep 'PLAN RULE:' '$MDIR/prd.md' | grep -q 'empty-hint'"
check "2e …inside the Constraints section, not appended after it" \
  "'${LCARS_PYTHON_BIN:-python3}' - '$MDIR/prd.md' <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\\n')
start = next(i for i, l in enumerate(lines) if re.match(r'\\*\\*Constraints:\\*\\*', l))
end = next((i for i in range(start + 1, len(lines))
            if re.match(r'(\\*\\*[^*]+:\\*\\*|#{1,6} )', lines[i])), len(lines))
sys.exit(0 if any('PLAN RULE:' in l for l in lines[start:end]) else 1)
PY"

# IDEMPOTENT: a PRD whose Constraints ALREADY carry the rule (the captain pasted
# it, or an autopilot injected it) must not grow a second copy.
FR2="$(file_repo)"; PRD_IN2="$FR2/prd-in.md"
RULE_PASTED="- PLAN RULE: every criterion of a screen-changing ticket carries drawnAt (board-grid, board-title, empty-hint, person-grid, person-name, request-card, request-created, request-text, v-board, v-empty, v-person) or notDrawn: \"<reason>\""
write_prd_in "$PRD_IN2" "$RULE_PASTED"
( cd "$FR2" && LCARS_RUN_BIN="$ESTIMATOR_STUB" LCARS_GH_BIN="$FR2/gh" LCARS_DATE=20260530 \
    bash "$FILE_SCRIPT" --prd "$PRD_IN2" --attach "$DRAWING" >out.txt 2>&1 )
MDIR2="$FR2/.git/lcars/missions/lcars-20260530-001-c10e"
check "2f a PRD that already carries the rule is not given a second copy" \
  "[ \"\$(grep -c 'PLAN RULE:' '$MDIR2/prd.md')\" = 1 ]"

# NO MOCKUP ⇒ nothing at all (the other direction).
FR3="$(file_repo)"; PRD_IN3="$FR3/prd-in.md"; write_prd_in "$PRD_IN3"
( cd "$FR3" && LCARS_RUN_BIN="$ESTIMATOR_STUB" LCARS_GH_BIN="$FR3/gh" LCARS_DATE=20260530 \
    bash "$FILE_SCRIPT" --prd "$PRD_IN3" >out.txt 2>&1 )
MDIR3="$FR3/.git/lcars/missions/lcars-20260530-001-c10e"
check "2g a mission with NO mockup gets no rule in its PRD" \
  "[ -f '$MDIR3/prd.md' ] && ! grep -q 'PLAN RULE:' '$MDIR3/prd.md'"

# ===========================================================================
section "C. PATCH, DON'T RE-PLAN — name the tickets, refuse a wider rewrite"
# ===========================================================================
save_mission() { # -> echoes repo dir (mission at `plan`, carrying the drawing)
  local repo; repo="$(mktemp -d "$TMPROOT/save.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d/attachments"
  cat > "$d/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }
JSON
  cp "$DRAWING" "$d/attachments/attachment-01.html"
  echo "$repo"
}

run_plan_save() { # repo planfile -> RC, OUT, NOTE
  OUT="$( cd "$1" && bash "$SCRIPT" plan-save --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
  NOTE=""
  [ -f "$(dirname "$2")/.plan-reject-note" ] && NOTE="$(cat "$(dirname "$2")/.plan-reject-note")"
}

# Each attempt's plan goes in its OWN scratch dir (that is where a cold worker
# writes, and where the reject note is filed).
scratch_plan() { # src -> echoes plan path
  local d; d="$(mktemp -d "$TMPROOT/scratch.XXXX")"; cp "$1" "$d/plan.json"; echo "$d/plan.json"
}

SM="$(save_mission)"
P1="$(scratch_plan "$TMPROOT/bad-t002.json")"
run_plan_save "$SM" "$P1"
check "3a a bad anchor on t-002 only is REJECTED" "[ '$RC' -ne 0 ]"
check "3b the reject note names the failing ticket t-002" \
  "printf '%s' \"\$NOTE\" | grep -q 't-002'"
# RETARGETED by fix round 1, D3. This asserted that t-001 appeared NOWHERE in
# the note — and D3's cure is that the retry is HANDED the plan it must patch,
# which necessarily contains t-001. The INTENT was never "hide t-001": it was
# "do not accuse the clean ticket", i.e. the patchable list names the failing
# ticket and only it. That is what is asserted now, on the directive itself.
check "3c …and does NOT list t-001, which is clean, among the patchable" \
  "printf '%s' \"\$NOTE\" | grep 'PATCH THESE TICKETS' | grep -q 't-002' \
   && ! printf '%s' \"\$NOTE\" | grep 'PATCH THESE TICKETS' | grep -q 't-001'"
check "3d …and lists the valid anchors" \
  "printf '%s' \"\$NOTE\" | grep -q 'v-board' && printf '%s' \"\$NOTE\" | grep -q 'empty-hint'"
check "3e …and tells the retry to fix ONLY those tickets" \
  "printf '%s' \"\$NOTE\" | grep -qi 'only' && printf '%s' \"\$NOTE\" | grep -qi 'byte-identical'"

# THE RETRY THAT WENT WIDE. t-002's anchor is fixed, but t-001 was rewritten
# too — which is exactly what the weekend's planner did, and what turns a
# one-ticket patch into a fresh plan nobody reviewed.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/retry-wide.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[0]["title"] = "Board status filter, rewritten"
d[0]["acceptanceCriteria"][0]["text"] = "a completely different criterion"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
P2="$(scratch_plan "$TMPROOT/retry-wide.json")"
run_plan_save "$SM" "$P2"
check "3f a retry that ALSO changed t-001 is REJECTED" "[ '$RC' -ne 0 ]"
check "3g …for that reason, naming t-001" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -qi 'unchanged\|byte-identical\|was not'"

# THE RETRY THAT PATCHED. Only t-002 changed ⇒ accepted.
P3="$(scratch_plan "$TMPROOT/good-plan.json")"
run_plan_save "$SM" "$P3"
check "3h a retry that fixed ONLY t-002 is ACCEPTED" "[ '$RC' -eq 0 ]"
check "3i …and the plan is persisted" \
  "[ -f '$SM/.git/lcars/missions/test-001/plan.json' ]"

# A plan that re-flows its JSON (indent, key order) without changing a ticket's
# CONTENT is not an edit. A false rejection here is the deadlock this cures.
SM2="$(save_mission)"
P4="$(scratch_plan "$TMPROOT/bad-t002.json")"; run_plan_save "$SM2" "$P4"
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/retry-reflow.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump(d, open(sys.argv[2], "w"), indent=6, sort_keys=True)
PY
P5="$(scratch_plan "$TMPROOT/retry-reflow.json")"
run_plan_save "$SM2" "$P5"
check "3j a retry that only RE-FLOWED the untouched ticket's JSON is accepted" \
  "[ '$RC' -eq 0 ]"

# ===========================================================================
section "D. PARK, DON'T STOP — the final anchor failure is a gate"
# ===========================================================================
RP="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/bad-t002.json" run_plan_stage "$RP" 3
RPSTATE="$RP/.git/lcars/missions/test-001/state.json"
check "4a three anchor-only failures do NOT stage-stop" \
  "! printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "4b …the Stage exits cleanly (a gate, not a failure)" "[ '$RC' -eq 0 ]"
check "4c …the mission is awaiting-human" "grep -q '\"awaitingHuman\": true' '$RPSTATE'"
check "4d …and still at the plan stage" "grep -q '\"stage\": \"plan\"' '$RPSTATE'"
check "4e the pending question names the failing ticket" \
  "grep -q 't-002' '$RP/.git/lcars/missions/test-001/pending.json'"
check "4f …and LISTS the anchors" \
  "grep -q 'v-board' '$RP/.git/lcars/missions/test-001/pending.json' && grep -q 'empty-hint' '$RP/.git/lcars/missions/test-001/pending.json'"
check "4g …and asks the notDrawn/notVisual question" \
  "grep -qi 'notDrawn' '$RP/.git/lcars/missions/test-001/pending.json'"
check "4h the lcars:awaiting-human label is applied" \
  "grep -q 'awaiting-human' '$RP.gh.log'"
check "4i notify fired at the gate" \
  "[ -s '$RP.notify.log' ] && grep -q 'awaiting-human' '$RP.notify.log'"
check "4j no plan.json was persisted" \
  "[ ! -f '$RP/.git/lcars/missions/test-001/plan.json' ]"

# ===========================================================================
section "E. CONSUME — the captain's anchor reaches the next Plan run"
# ===========================================================================
RESPOND="$REPO_ROOT/skills/lcars-respond/respond.sh"
( cd "$RP" && LCARS_RESPOND_RESUME=0 LCARS_GH_BIN="$RP.gh" \
    bash "$RESPOND" answer --mission test-001 \
      --answer 't-002 sits at #v-board — the nav link lands there; the landing page itself is notDrawn.' >ans.txt 2>&1 )
check "5a lcars answer records the anchor" \
  "[ -f '$RP/.git/lcars/missions/test-001/answers.json' ] && grep -q 'v-board' '$RP/.git/lcars/missions/test-001/answers.json'"
check "5b …and clears the gate" "! grep -q '\"awaitingHuman\": true' '$RPSTATE'"
STUB_PLAN="$TMPROOT/good-plan.json" run_plan_stage "$RP" 3
check "5c the next Plan run is handed the captain's answer" \
  "grep -q 'answers.json' '$PROMPT_FILE'"
check "5d …and the rule + anchors are still injected" \
  "grep -q 'PLAN RULE:' '$PROMPT_FILE'"
check "5e …and the Stage advances" \
  "[ '$RC' -eq 0 ] && grep -q '\"stage\": \"plan-review\"' '$RPSTATE'"

# ===========================================================================
section "F. A NON-ANCHOR failure keeps today's behaviour EXACTLY"
# ===========================================================================
# A plan missing `changesScreenAppearance` fails a DIFFERENT rule. Only
# anchor-only failures park; everything else keeps the stage stop.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/nonanchor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d:
    t.pop("changesScreenAppearance", None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RN="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/nonanchor.json" run_plan_stage "$RN" 3
RNSTATE="$RN/.git/lcars/missions/test-001/state.json"
check "6a a non-anchor failure x3 still STAGE STOPS" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "6b …and does NOT park the mission" \
  "! grep -q 'awaitingHuman' '$RNSTATE'"
check "6c …and writes no pending.json" \
  "[ ! -f '$RN/.git/lcars/missions/test-001/pending.json' ]"
check "6d …and fires no gate notify" "[ ! -s '$RN.notify.log' ]"

# ===========================================================================
section "H. THE WALK-AWAY PROMISE — the parked question renders ON THE DRIVER"
# ===========================================================================
# S237 FIX ROUND 1, DEFECT 1. `drive_pending_questions` read pending.json with
# `grep -oE '^[[:space:]]*"[^"]*"...'`. `"[^"]*"` CANNOT span a string carrying
# an escaped quote — and S237's own park question carries them BY CONSTRUCTION
# (it offers `notDrawn ("<why …>")`). So on the UNATTENDED surface — `lcars
# run`, the autopilot, night-watch — the captain saw a heading, an EMPTY list
# and a hint, while the question sat in pending.json the whole time.
#
# This is the THIRD human-facing surface in one day to lose text to a
# hand-rolled JSON read (print_objections was cut at the first escaped quote;
# the Verify readout clipped its note). So it is cured as a CLASS: ONE shared
# JSON reader that both readers call, and that a fourth surface can reach for.
# Driven on the REAL driver surface (`run.sh drive`), not on the function.
pending_json_write() { # path  question...
  local p="$1"; shift
  "${LCARS_PYTHON_BIN:-python3}" - "$p" "$@" <<'PY'
import json, sys
# ensure_ascii=False and indent=2 — byte-for-byte the shape write_pending puts
# on disk (raw UTF-8, one question per line), so this fixture is the real file.
json.dump({"stage": "plan", "questions": list(sys.argv[2:])},
          open(sys.argv[1], "w"), indent=2, ensure_ascii=False)
PY
}

parked_repo() { # question... -> echoes repo dir (awaiting-human at plan)
  local repo; repo="$(e2e_repo yes)"
  local d="$repo/.git/lcars/missions/test-001"
  cat > "$d/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": 42,
  "awaitingHuman": true,
  "pendingQuestion": "see pending.json"
}
JSON
  pending_json_write "$d/pending.json" "$@"
  echo "$repo"
}

run_drive() { # repo [EXTRA_ENV=val …] -> DOUT, DRC
  local repo="$1"; shift
  DOUT="$( cd "$repo" && env \
      LCARS_GH_BIN="$repo.gh" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" LCARS_WORKER_HANG_SECS=0 \
      LCARS_NOTIFY="$repo.notify" LCARS_XO_DRIVE=0 \
      LCARS_VERSION_CHECK_BIN=/nonexistent/version-check \
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/usr/bin/false \
      "$@" bash "$SCRIPT" drive --mission test-001 2>&1 )"
  DRC=$?
}

# THE REAL ONE: S237's park question, verbatim in shape — escaped quotes and all.
QREAL='ticket t-002 describes "the landing nav carries a Requests link"; which of these anchors does it sit at — board-grid board-title v-board — or is it notDrawn ("<why this visible thing is not in the drawing>") or notVisual (it makes no visual claim at all)?'
RQ="$(parked_repo "$QREAL")"
run_drive "$RQ"
check "7a the driver halts at the gate" \
  "printf '%s' \"\$DOUT\" | grep -q 'awaiting your answer'"
check "7b a question carrying ESCAPED QUOTES renders AT ALL" \
  "printf '%s' \"\$DOUT\" | grep -q 'ticket t-002 describes'"
check "7c …IN FULL, to its last character (nothing clipped at a quote)" \
  "printf '%s' \"\$DOUT\" | grep -qF 'notVisual (it makes no visual claim at all)?'"
check "7d …with the inner quoted criterion text intact" \
  "printf '%s' \"\$DOUT\" | grep -qF '\"the landing nav carries a Requests link\"'"
check "7e …and the anchors the captain has to choose between" \
  "printf '%s' \"\$DOUT\" | grep -qF 'board-grid board-title v-board'"

# THE KNOWN-GOOD CONTROL: a question with NO inner quotes rendered fine before
# this fix and must render identically after it.
RC2="$(parked_repo 'the scope grew — ship the filter alone or both?')"
run_drive "$RC2"
check "7f the plain-question control still renders EXACTLY as before" \
  "printf '%s' \"\$DOUT\" | grep -qxF '  • the scope grew — ship the filter alone or both?'"

# ONE QUESTION IS ONE LINE. drive_halt_awaiting consumes this output in a
# `while read` loop, so a newline inside a question would become TWO questions
# and truncate the captain's at the wrap.
QNL='first half of the question
second half of the same question'
RC3="$(parked_repo "$QNL")"
run_drive "$RC3"
check "7g a question containing a NEWLINE stays ONE bullet line" \
  "[ \"\$(printf '%s\n' \"\$DOUT\" | grep -c '^  • ')\" = 1 ]"
check "7h …with BOTH halves on it (collapsed, never clipped)" \
  "printf '%s' \"\$DOUT\" | grep -q 'first half of the question second half of the same question'"

# TWO questions are TWO lines (the loop's other direction).
RC4="$(parked_repo 'first question?' 'second question?')"
run_drive "$RC4"
check "7i two questions render as two bullet lines" \
  "[ \"\$(printf '%s\n' \"\$DOUT\" | grep -c '^  • ')\" = 2 ]"

# FAIL OPEN. A display path during a park must never take the Stage down when
# the interpreter is missing — it degrades to something READABLE.
RC5="$(parked_repo "$QREAL")"
run_drive "$RC5" LCARS_PYTHON_BIN=/nonexistent/python3
check "7j with NO python the driver still reaches the gate" \
  "printf '%s' \"\$DOUT\" | grep -q 'awaiting your answer'"
check "7k …and still prints the question readably (degraded, not empty)" \
  "printf '%s' \"\$DOUT\" | grep -q 'the landing nav carries a Requests link'"

# THE CLASS, not the instance: ONE reader, and no fourth bespoke one.
DPQ="$(sed -n '/^drive_pending_questions() {/,/^}/p' "$REPO_ROOT/skills/lcars-run/run.sh")"
POJ="$(sed -n '/^_print_objections_json() {/,/^}/p' "$REPO_ROOT/skills/lcars-run/run.sh")"
check "7l the driver no longer hand-rolls a JSON read" \
  "! printf '%s' \"\$DPQ\" | grep -q 'grep -oE'"
check "7m the driver's questions come from the SHARED reader" \
  "printf '%s' \"\$DPQ\" | grep -q '_lcars_json_lines'"
check "7n …and so do the reviewer's objections (one reader, two surfaces)" \
  "printf '%s' \"\$POJ\" | grep -q '_lcars_json_lines'"
check "7o the shared reader parses with python, not grep" \
  "sed -n '/^_lcars_json_lines() {/,/^}/p' '$REPO_ROOT/skills/lcars-run/run.sh' | grep -q 'LCARS_PYTHON_BIN'"

# ===========================================================================
section "I. ONLY AN ANCHOR FAILURE PARKS — a shape error stage-stops"
# ===========================================================================
# S237 FIX ROUND 1, DEFECT 2. `anchor_failure_tickets` classified by the whole
# mockup-declaration block's signature, so EVERY failure inside that block —
# a missing "text", two declarations, a wrong type — was triaged as an anchor
# failure and PARKED, asking the captain "which of these anchors does it sit
# at" about a criterion whose text does not exist. The round's own contract is
# that non-anchor failures keep today's behaviour, STAGE STOP INCLUDED.
#
# A criterion with a VALID anchor and NO "text" — the anchor is not the fault.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/no-text.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[1]["acceptanceCriteria"][0].pop("text")
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RNT="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/no-text.json" run_plan_stage "$RNT" 3
RNTSTATE="$RNT/.git/lcars/missions/test-001/state.json"
check "8a a criterion with NO \"text\" x3 STAGE STOPS" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "8b …naming its REAL reason, not an anchor question" \
  "printf '%s' \"\$OUT\" | grep -qF 'has no \"text\"'"
check "8c …with awaitingHuman unset" "! grep -q 'awaitingHuman' '$RNTSTATE'"
check "8d …no pending.json" \
  "[ ! -f '$RNT/.git/lcars/missions/test-001/pending.json' ]"
check "8e …and no gate notification" "[ ! -s '$RNT.notify.log' ]"

# TWO declarations on one criterion — the anchor is a VALID id and the fault is
# the extra key. The live park→answer→re-plan cycle died here.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/two-decl.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[1]["acceptanceCriteria"][0]["notVisual"] = True   # keeps its valid drawnAt
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RTD="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/two-decl.json" run_plan_stage "$RTD" 3
RTDSTATE="$RTD/.git/lcars/missions/test-001/state.json"
check "8f a criterion carrying TWO declarations x3 STAGE STOPS" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "8g …naming its REAL reason (two declarations, exactly one allowed)" \
  "printf '%s' \"\$OUT\" | grep -q 'declarations'"
check "8h …with awaitingHuman unset" "! grep -q 'awaitingHuman' '$RTDSTATE'"
check "8i …and no pending.json" \
  "[ ! -f '$RTD/.git/lcars/missions/test-001/pending.json' ]"

# A criterion declaring a NON-STRING anchor — a type error, not a placement
# question. Nothing the captain can answer makes `drawnAt: 7` legal.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/bad-type.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[1]["acceptanceCriteria"][0]["drawnAt"] = 7
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RBT="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/bad-type.json" run_plan_stage "$RBT" 3
check "8j a NON-STRING anchor x3 STAGE STOPS (a type error is not a question)" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "8k …and does not park" \
  "! grep -q 'awaitingHuman' '$RBT/.git/lcars/missions/test-001/state.json'"

# A MIXED plan — one genuine bad anchor AND one shape error. Parking would ask
# about the anchor and leave the shape error unfixed forever, so the whole plan
# stage-stops: a wrong stage stop tells the truth, a wrong park does not.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/mixed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[0]["acceptanceCriteria"][0]["drawnAt"] = "#landing-nav, the top nav"  # genuine bad anchor
d[1]["acceptanceCriteria"][0].pop("text")                              # shape error
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RMX="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/mixed.json" run_plan_stage "$RMX" 3
check "8l a plan mixing a bad anchor with a shape error STAGE STOPS" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage stopped'"
check "8m …and does not park on the anchor half" \
  "! grep -q 'awaitingHuman' '$RMX/.git/lcars/missions/test-001/state.json'"

# THE CONTROL that proves the classifier was NARROWED, not disabled: a genuine
# bad anchor — one that names no place in the drawing — still PARKS.
RGB="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/bad-t002.json" run_plan_stage "$RGB" 3
check "8n CONTROL: a genuine BAD ANCHOR x3 still PARKS (not disabled)" \
  "[ '$RC' -eq 0 ] && grep -q '\"awaitingHuman\": true' '$RGB/.git/lcars/missions/test-001/state.json'"
check "8o …and its question still names the ticket and the anchors" \
  "grep -q 't-002' '$RGB/.git/lcars/missions/test-001/pending.json' && grep -q 'v-board' '$RGB/.git/lcars/missions/test-001/pending.json'"

# THE OTHER genuine anchor failure: NO declaration at all on a criterion.
"${LCARS_PYTHON_BIN:-python3}" - "$TMPROOT/good-plan.json" "$TMPROOT/no-decl.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[1]["acceptanceCriteria"][0].pop("drawnAt", None)   # text stays; the ANCHOR is missing
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
RND="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/no-decl.json" run_plan_stage "$RND" 3
check "8p CONTROL: a MISSING anchor x3 still PARKS" \
  "[ '$RC' -eq 0 ] && grep -q '\"awaitingHuman\": true' '$RND/.git/lcars/missions/test-001/state.json'"

# ===========================================================================
section "J. THE RETRY IS HANDED THE PLAN IT IS TOLD TO PATCH"
# ===========================================================================
# S237 FIX ROUND 1, DEFECT 3. The anchor-only reject note told a COLD,
# STATELESS worker to "keep every OTHER ticket byte-identical to the plan you
# were just handed back" and that "THIS IS CHECKED" — and the rejected plan
# appeared NOWHERE in the assembled prompt. Each attempt gets a fresh temp dir,
# so the check passed only when a worker happened to regenerate the same
# tickets. That is luck, not design, and it is structurally the same defect
# this round exists to cure: a prompt demanding what the worker cannot do.
plan_prompt_n() { # prompts-file  n -> that plan prompt alone
  awk -v want="$2" '
    /^=== ROLE plan ===$/ { n++; cur=(n==want); next }
    /^=== ROLE /          { cur=0; next }
    cur
  ' "$1"
}

RJ="$(e2e_repo yes)"
STUB_PLAN="$TMPROOT/bad-t002.json" run_plan_stage "$RJ" 3
P_FIRST="$(plan_prompt_n "$PROMPT_FILE" 1)"
P_RETRY="$(plan_prompt_n "$PROMPT_FILE" 2)"
P_THIRD="$(plan_prompt_n "$PROMPT_FILE" 3)"
check "9a the retry prompt says the previous attempt was rejected" \
  "printf '%s' \"\$P_RETRY\" | grep -q 'PREVIOUS ATTEMPT WAS REJECTED'"
check "9b …and names the patch directive it must obey" \
  "printf '%s' \"\$P_RETRY\" | grep -q 'PATCH THESE TICKETS'"
check "9c the retry is HANDED the other tickets it must keep unchanged" \
  "printf '%s' \"\$P_RETRY\" | grep -qF 'Board status filter'"
check "9d …and their criteria, so the instruction is satisfiable" \
  "printf '%s' \"\$P_RETRY\" | grep -qF 'a status control sits above the grid'"
check "9e …by a readable PATH it is told to read, as well as inline" \
  "printf '%s' \"\$P_RETRY\" | grep -q 'anchor-patch.json'"
check "9f the FIRST attempt is handed none of it (byte-identical to before)" \
  "! printf '%s' \"\$P_FIRST\" | grep -qF 'Board status filter'"
check "9g …and names no patch baseline" \
  "! printf '%s' \"\$P_FIRST\" | grep -q 'anchor-patch.json'"
check "9h the third attempt is handed it too" \
  "printf '%s' \"\$P_THIRD\" | grep -qF 'Board status filter'"

# AND THE CHECK IS STILL ENFORCED — being handed the plan does not license a
# wider rewrite. (Same surface as 3f/3g, re-asserted here because D3's whole
# argument is that the instruction and the check must now BOTH be fair.)
SMJ="$(save_mission)"
PJ1="$(scratch_plan "$TMPROOT/bad-t002.json")"; run_plan_save "$SMJ" "$PJ1"
check "9i the baseline plan is kept on disk for the retry to read" \
  "[ -f '$SMJ/.git/lcars/missions/test-001/.anchor-patch.json' ]"
PJ2="$(scratch_plan "$TMPROOT/retry-wide.json")"; run_plan_save "$SMJ" "$PJ2"
check "9j a retry that edited an UNLISTED ticket is still refused" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 't-001'"
PJ3="$(scratch_plan "$TMPROOT/good-plan.json")"; run_plan_save "$SMJ" "$PJ3"
check "9k …and a retry that patched only the listed ticket is still accepted" \
  "[ '$RC' -eq 0 ]"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
