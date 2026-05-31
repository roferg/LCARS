#!/usr/bin/env bash
#
# lcars run — advance a Mission one Stage. This build implements the Research,
# Validate, and Plan stages (align → validate → plan → plan-review).
#
# `lcars run <id>` dispatches on state.json.stage. A mission filed by
# `lcars file` sits at stage "align" (Align already happened conversationally),
# so the next Stage to execute is Research. Research has two halves:
#
#   • Claude (per SKILL.md) reads prd.md, generates 0–20 research questions,
#     and spawns one STATELESS subagent per question. Each agent gets only its
#     question text and returns { question, recommendation, supporting_points }.
#   • This script does the mechanical, testable parts, via two subcommands:
#
#       gate  --mission <id> --questions <file>
#             Branch on the question count BEFORE any agent runs:
#               0          → skip Research, advance the mission (prints GATE: skip)
#               1..20      → dispatch that many agents       (prints GATE: dispatch N)
#               >20        → stop and ask the human          (prints GATE: too-many N, exit 3)
#
#       save  --mission <id> --responses <dir>
#             Persist the agents' response JSON to research/<n>.json, then
#             advance the mission.
#
# "Advance the mission" means: set state.json.stage to "validate" AND move the
# GitHub label from lcars:align to lcars:validate, so the on-disk state and the
# board's label always agree on one answer — the Stage `lcars run` will execute
# next. A freshly filed mission sits at "align" (Align already happened in
# `lcars file`), so `lcars run` treats "align" as the signal to run Research and
# lands the card in the Validate column when it's done.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary (default: gh)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
MAX_QUESTIONS=20
MAX_REVIEW_ROUNDS=3
RELABEL_NOTE=""

die() { printf 'lcars run: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as file.sh / status.sh) ----------
json_str() { # file key  → first matching "key": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key  → first matching bare token (number/null/bool)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- tiny JSON writers (pretty, one-field-per-line state.json) --------------
# state.json is written one field per line (see file.sh), so we edit it by the
# line. New fields are inserted right after the opening brace — always valid
# because `id` always follows. Untrusted text (question text) is JSON-escaped
# and handed to awk via the environment so awk never reinterprets its escapes.
json_escape() { # string → backslash/quote-escaped (printed)
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  printf '%s' "$s"
}
state_del() { # key   — drop the field's line if present (no-op otherwise)
  local tmp; tmp="$(mktemp)"
  grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
state_set_str() { # key value   — add or replace a string field
  state_del "$1"
  local esc tmp; esc="$(json_escape "$2")"; tmp="$(mktemp)"
  K="$1" V="$esc" awk 'NR==1{print; printf "  \"%s\": \"%s\",\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
state_set_raw() { # key token   — add or replace a bare field (true/false/number)
  state_del "$1"
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- locate the mission ----------------------------------------------------
# Resolves MISSION_DIR / STATE for the given id, mirroring file.sh's .git
# resolution. Dies if the mission or its state.json is absent.
locate_mission() {
  local id="$1" gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$id"
  STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$id' under .git/lcars/missions/ — check the id (or run \`lcars file\` first)."
  [ -f "$STATE" ]       || die "mission '$id' has no state.json — its state is corrupt."
}

# Each Stage runs only when the Mission is parked at the stage that feeds it,
# so we never relabel or overwrite a mission mid-flight. Research runs on
# `align`; Validate runs on `validate`.
require_stage() { # wanted-stage
  local stage; stage="$(json_str "$STATE" stage)"
  [ "$stage" = "$1" ] || die "mission is at stage '${stage:-unknown}', not '$1' — this Stage only runs on a mission parked at '$1'."
}

# --- rewrite state.json's stage field in place (portable sed) --------------
set_stage() {
  local newstage="$1" tmp
  tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# --- gh relabel: keep the board's label in step with the on-disk stage -----
# Best-effort: a missing issue / missing gh / failed edit never blocks the
# local stage change — it just leaves a note telling the captain what to fix
# by hand. Add/remove lists are space-separated (labels carry no spaces).
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2" l
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null)
      RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."
      return 0 ;;
  esac

  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    local args=()
    for l in $add; do args+=(--add-label "$l"); done
    for l in $rem; do args+=(--remove-label "$l"); done
    if ! "$GH_BIN" issue edit "$issue" "${args[@]}" >/dev/null 2>&1; then
      RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand ($hand)."
    fi
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: $hand)."
  fi
}

# --- advance Research: stage pointer → validate, label align → validate -----
advance() {
  set_stage "validate"
  gh_relabel "lcars:validate" "lcars:align"
}

# --- subcommand: gate ------------------------------------------------------
cmd_gate() {
  locate_mission "$MISSION_ID"
  require_stage align

  local n=0
  if [ -n "$QFILE" ] && [ -f "$QFILE" ]; then
    n="$(grep -cve '^[[:space:]]*$' "$QFILE")"
  fi

  if [ "$n" -eq 0 ]; then
    advance
    echo "GATE: skip"
    echo "  No research questions — the PRD is unambiguous. Skipping Research."
    echo "  Stage:  validate"
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  if [ "$n" -gt "$MAX_QUESTIONS" ]; then
    echo "GATE: too-many $n"
    echo "  Research wants $n questions — over the cap of $MAX_QUESTIONS. That"
    echo "  many open questions usually means the PRD is underspecified."
    echo "  Nothing has changed. Choose how to proceed:"
    echo "    • override         — run all $n research agents anyway"
    echo "    • return-to-align  — re-run \`lcars file\` with this context appended"
    echo "                         so the PRD can be sharpened"
    exit 3
  fi

  echo "GATE: dispatch $n"
  echo "  Dispatching $n stateless research agent(s) — one per question."
  exit 0
}

# --- subcommand: save ------------------------------------------------------
cmd_save() {
  locate_mission "$MISSION_ID"
  require_stage align

  [ -n "$RESPONSES" ]   || die "no responses dir — pass --responses <dir>."
  [ -d "$RESPONSES" ]   || die "responses dir not found: $RESPONSES"

  local research_dir="$MISSION_DIR/research"
  mkdir -p "$research_dir"

  # Persist each response as research/<n>.json, renumbered 1..N in the input's
  # lexical order. Every response must carry the three required fields — a
  # malformed agent reply stops the save so we never advance on bad data.
  local n=0 f
  shopt -s nullglob
  for f in "$RESPONSES"/*.json; do
    grep -q '"question"'          "$f" || die "response $f is missing \"question\"."
    grep -q '"recommendation"'    "$f" || die "response $f is missing \"recommendation\"."
    grep -q '"supporting_points"' "$f" || die "response $f is missing \"supporting_points\"."
    n=$((n + 1))
    cp "$f" "$research_dir/$n.json"
  done
  shopt -u nullglob

  [ "$n" -gt 0 ] || die "no *.json responses in $RESPONSES — nothing to save."

  advance
  echo "SAVE: $n responses"
  echo "  Saved $n research response(s) to research/."
  echo "  Stage:  validate"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Validate stage ========================================================
# The Validator (Claude, per SKILL.md) reads prd.md + research/*.json and
# produces two things: a synthesis (validated-plan.md) and 0-N scope-change
# questions. The script handles the two mechanical outcomes:
#
#   validate-pause    --mission <id> --questions <file>
#         A finding implies a scope/direction change. Persist the questions to
#         pending.json, flip the Mission into the awaiting-human gate (state +
#         lcars:awaiting-human label), and stop. The card stays in Validate.
#
#   validate-advance  --mission <id> --plan <file>
#         No open scope question (or the human has since answered). Write the
#         synthesis to validated-plan.md, clear any awaiting-human gate, and
#         advance the Mission to Plan (stage + label validate → plan).

# --- write pending.json: the captain's scope-change questions ---------------
# One JSON string per non-blank line of the questions file, escaped. This is
# the queue `lcars respond` (a later build) reads to record the answers.
write_pending() { # questions-file  stage
  local pj="$MISSION_DIR/pending.json"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$2"
    echo '  "questions": ['
    awk 'NF{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); q[++n]=$0 }
         END{ for(i=1;i<=n;i++) printf "    \"%s\"%s\n", q[i], (i<n?",":"") }' "$1"
    echo '  ]'
    echo '}'
  } >"$pj"
}

# --- subcommand: validate-pause --------------------------------------------
cmd_validate_pause() {
  locate_mission "$MISSION_ID"
  require_stage validate

  [ -n "$QFILE" ] && [ -f "$QFILE" ] || die "no questions file — pass --questions <file>."
  local n; n="$(grep -cve '^[[:space:]]*$' "$QFILE")"
  [ "$n" -gt 0 ] || die "no scope questions in $QFILE — use validate-advance when there are none."

  write_pending "$QFILE" "validate"

  # Mark the awaiting-human gate. pendingQuestion is what `lcars status` (the
  # board) prints, so surface the first question there; the full set lives in
  # pending.json.
  local first; first="$(grep -ve '^[[:space:]]*$' "$QFILE" | head -1)"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$first"

  gh_relabel "lcars:awaiting-human" ""

  echo "VALIDATE: paused — $n scope question(s)"
  echo "  A finding implies a scope change. The Mission is waiting on you:"
  while IFS= read -r q; do
    [ -n "$q" ] && echo "    • $q"
  done < <(grep -ve '^[[:space:]]*$' "$QFILE")
  echo "  Stage:  validate (awaiting-human)"
  echo "  Answer with \`lcars respond $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- subcommand: validate-advance ------------------------------------------
cmd_validate_advance() {
  locate_mission "$MISSION_ID"
  require_stage validate

  [ -n "$PLAN" ] && [ -f "$PLAN" ] || die "no plan file — pass --plan <file>."

  # The synthesis must carry its required sections — same contract as the PRD
  # (file.sh) and research responses (save): a malformed plan stops the advance
  # so we never move on with a half-formed plan.
  grep -q '^# Validated Plan'  "$PLAN" || die "plan is missing its '# Validated Plan' title."
  grep -q '^## Synthesis'      "$PLAN" || die "plan is missing the '## Synthesis' section."
  grep -q '^## Decisions'      "$PLAN" || die "plan is missing the '## Decisions' section."

  cp "$PLAN" "$MISSION_DIR/validated-plan.md"

  # Resume cleanly whether or not we ever paused: clear the awaiting-human gate
  # (state fields, pending.json) — no-ops on the straight-through path.
  state_del awaitingHuman
  state_del pendingQuestion
  rm -f "$MISSION_DIR/pending.json"

  set_stage "plan"
  gh_relabel "lcars:plan" "lcars:validate lcars:awaiting-human"

  echo "VALIDATE: advanced"
  echo "  Wrote validated-plan.md."
  echo "  Stage:  plan"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Plan stage ============================================================
# The Planning LLM (Claude, per SKILL.md) reads prd.md + validated-plan.md and
# decomposes the plan into a list of small, vertical-slice tickets. It writes
# the whole list as plan.json (a JSON array) to a temp file and hands it here:
#
#   plan-save  --mission <id> --plan <file>
#         Validate the ticket list, install it as plan.json, and advance the
#         Mission to Plan Review (stage + label plan → plan-review).
#
# plan.json is a JSON array of ticket objects in a canonical one-field-per-line
# shape (acceptanceCriteria / dependencies are inline single-line arrays), so
# the validator below can stay line-oriented and jq-free — same spirit as the
# other readers in this file.

# --- validate the ticket list ----------------------------------------------
# Enforces the plan.json contract so we never advance on a half-formed plan,
# mirroring how `save` guards research responses and `validate-advance` guards
# the synthesis. Pure awk over the canonical one-field-per-line shape (inline
# acceptanceCriteria / dependencies arrays), so it stays jq-free. Each ticket
# must carry every required field, at least one acceptance criterion, and only
# depend on ticket ids that exist in this same plan. Prints the first failure
# and returns non-zero; silent on success.
validate_plan_json() { # file
  awk '
    function fail(msg) { printf "lcars run: %s\n", msg > "/dev/stderr"; exit 1 }
    # object boundaries — canonical format puts { and } on their own lines, and
    # the only braces in the file are object delimiters (arrays are inline).
    /^[[:space:]]*\{[[:space:]]*$/ {
      inobj=1; delete have; acok=0; id=""; ndep=0; next
    }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ {
      if (!inobj) next
      tickets++
      for (k=1; k<=6; k++) if (!have[req[k]]) fail("ticket " tickets " is missing \"" req[k] "\".")
      if (!acok) fail("ticket " tickets " (" id ") needs at least one acceptance criterion.")
      ids[id]=1
      for (d=1; d<=ndep; d++) { depof[++drefs]=dep[d]; depticket[drefs]=id }
      inobj=0; next
    }
    inobj {
      n=split($0, a, "\"")          # inside-quote contents land at even indices
      if (n < 2) next
      key=a[2]; have[key]=1
      if (key=="id") id=a[4]
      else if (key=="acceptanceCriteria") { if (n >= 4) acok=1 }
      else if (key=="dependencies") { for (i=4; i<=n; i+=2) if (a[i] != "") dep[++ndep]=a[i] }
    }
    BEGIN { req[1]="id"; req[2]="title"; req[3]="description";
            req[4]="acceptanceCriteria"; req[5]="estimatedLoc"; req[6]="dependencies" }
    END {
      if (tickets == 0) fail("no tickets in the plan — a plan needs at least one ticket.")
      for (r=1; r<=drefs; r++)
        if (!(depof[r] in ids))
          fail("ticket " depticket[r] " depends on \"" depof[r] "\", which is not a ticket id in this plan.")
    }
  ' "$1"
}

# --- subcommand: plan-save -------------------------------------------------
cmd_plan_save() {
  locate_mission "$MISSION_ID"
  require_stage plan

  [ -n "$PLAN" ] && [ -f "$PLAN" ] || die "no plan file — pass --plan <file>."

  validate_plan_json "$PLAN" || exit 1

  cp "$PLAN" "$MISSION_DIR/plan.json"

  set_stage "plan-review"
  gh_relabel "lcars:plan-review" "lcars:plan"

  echo "PLAN: advanced"
  echo "  Wrote plan.json."
  echo "  Stage:  plan-review"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Plan Review stage =====================================================
# A FRESH reviewer session (Claude, per SKILL.md) audits plan.json — and ONLY
# plan.json, never prd.md or validated-plan.md — against the fixed quality bar
# (vertical slice, <300 LoC, testable, deps in-plan) and emits a verdict:
#
#   { "passed": <bool>, "issues": [ { "ticketId": "...", "objection": "..." } ] }
#
# It hands that verdict to the one mechanical subcommand, which branches on it:
#
#   review-save  --mission <id> --verdict <file>
#         passed=true  → write approved-plan.json, advance to Schedule.
#         passed=false → log the round's objections to plan-review-<round>.json,
#                        bump planReviewRound, and loop the Mission back to Plan
#                        for revision — UNTIL the 3rd round, which escalates to
#                        the human (awaiting-human gate, card stays in Plan
#                        Review) instead of looping forever.
#
# The reviewer's independence from the planner is deliberate (see vision.md →
# Plan Review): the session that planned the work must not also grade it, so it
# is given the tickets alone, not the spec that produced them.

# --- approve: copy plan.json → approved-plan.json, advance to schedule -------
review_pass() {
  [ -f "$MISSION_DIR/plan.json" ] || die "no plan.json to approve — has Plan run?"
  cp "$MISSION_DIR/plan.json" "$MISSION_DIR/approved-plan.json"

  set_stage "schedule"
  gh_relabel "lcars:schedule" "lcars:plan-review"

  echo "PLAN-REVIEW: passed"
  echo "  Every ticket cleared review. Wrote approved-plan.json."
  echo "  Stage:  schedule"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- print the verdict's objections, one bulleted "<ticket> — <objection>" --
# Canonical one-issue-per-line shape means splitting on " lands the ticketId at
# field 4 and the objection text at field 8 (same jq-free spirit as the rest).
print_objections() { # verdict-file  prefix
  awk -F'"' -v p="$2" '/"objection"/ { printf "%s%s — %s\n", p, $4, $8 }' "$1"
}

# --- fail: log this round, then loop back to Plan or escalate at round 3 -----
review_fail() {
  grep -q '"objection"' "$VERDICT" \
    || die "verdict says failed but lists no issues — a failing review must name its objections."

  local round; round="$(json_raw "$STATE" planReviewRound)"; round="${round:-0}"
  round=$((round + 1))

  # Log the full verdict for this round so the planner (and the human, on
  # escalation) can see exactly what was objected to.
  cp "$VERDICT" "$MISSION_DIR/plan-review-$round.json"
  state_set_raw planReviewRound "$round"

  if [ "$round" -ge "$MAX_REVIEW_ROUNDS" ]; then
    # Out of rounds — hand the unresolved issues to the human. The card stays in
    # the Plan Review column with the awaiting-human overlay (same gate shape as
    # validate-pause), so it reads as "in Plan Review, awaiting me".
    local obj; obj="$(mktemp)"
    print_objections "$VERDICT" "" >"$obj"
    write_pending "$obj" "plan-review"

    local first; first="$(head -1 "$obj")"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "$first"
    gh_relabel "lcars:awaiting-human" ""

    echo "PLAN-REVIEW: escalated — $round rounds without a clean plan"
    echo "  Plan Review could not reach a clean plan after $round rounds. Unresolved:"
    print_objections "$VERDICT" "    • "
    echo "  Stage:  plan-review (awaiting-human)"
    echo "  Override (proceed to Schedule) or redirect — answer with \`lcars respond $MISSION_ID\`."
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  # Still have rounds left — bounce the Mission back to Plan to revise.
  set_stage "plan"
  gh_relabel "lcars:plan" "lcars:plan-review"

  echo "PLAN-REVIEW: revise — round $round"
  echo "  Tickets did not pass review. Logged objections to plan-review-$round.json:"
  print_objections "$VERDICT" "    • "
  echo "  Stage:  plan (revise the tickets and re-run)"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- subcommand: review-save -----------------------------------------------
cmd_review_save() {
  locate_mission "$MISSION_ID"
  require_stage plan-review

  [ -n "$VERDICT" ] && [ -f "$VERDICT" ] || die "no verdict file — pass --verdict <file>."

  case "$(json_raw "$VERDICT" passed)" in
    true)  review_pass ;;
    false) review_fail ;;
    *)     die "verdict is missing a boolean \"passed\" field." ;;
  esac
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; QFILE=""; RESPONSES=""; PLAN=""; VERDICT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)     MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*)   MISSION_ID="${1#--mission=}"; shift ;;
    --questions)   QFILE="${2:-}"; shift 2 ;;
    --questions=*) QFILE="${1#--questions=}"; shift ;;
    --responses)   RESPONSES="${2:-}"; shift 2 ;;
    --responses=*) RESPONSES="${1#--responses=}"; shift ;;
    --plan)        PLAN="${2:-}"; shift 2 ;;
    --plan=*)      PLAN="${1#--plan=}"; shift ;;
    --verdict)     VERDICT="${2:-}"; shift 2 ;;
    --verdict=*)   VERDICT="${1#--verdict=}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  gate|save|validate-pause|validate-advance|plan-save|review-save)
    [ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>." ;;
esac

case "$SUB" in
  gate)             cmd_gate ;;
  save)             cmd_save ;;
  validate-pause)   cmd_validate_pause ;;
  validate-advance) cmd_validate_advance ;;
  plan-save)        cmd_plan_save ;;
  review-save)      cmd_review_save ;;
  ''|*) die "unknown subcommand '${SUB:-}'. Usage: run.sh gate|save|validate-pause|validate-advance|plan-save|review-save --mission <id> [--questions <f>|--responses <d>|--plan <f>|--verdict <f>]." ;;
esac
