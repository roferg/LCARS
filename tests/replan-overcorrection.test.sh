#!/usr/bin/env bash
# S178 — a Plan Review objection is a PATCH, not a licence to serialise the plan.
#
# THE MEASUREMENT (DX-Scorecard lcars-20260827-001, live Copilot, 2026-08-28).
# Plan Review raised ONE objection against a 14-ticket plan: add t-010 to t-012's
# dependencies. The Mission bounced back to Plan, a FRESH planner ran, and it
# returned a plan whose dependency graph was a perfect 14-deep single-file chain
# (t-001 <- t-002 <- … <- t-014). Schedule correctly produced 14 waves of one
# ticket each. Asked for one edge, the planner rewrote the whole graph into a
# queue and destroyed every opportunity for parallel work.
#
# The live mission dir is GONE. tests/fixtures/replan/ is a RECONSTRUCTION from
# the verbatim quotes in lcars-dev/replan-overcorrection-dev.md — see the header
# comment there for which fact each ticket's dependencies are pinned by.
#
# Deliberately NOT the heavy tests/lcars-run.test.sh. Everything here runs over
# run.sh's isolation hooks, `plan-save`, `schedule`, and a stub worker adapter.
# NO worker is ever spawned, NO token is ever spent, and the whole file finishes
# in a couple of seconds.
#
#   bash tests/replan-overcorrection.test.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FIX="$REPO_ROOT/tests/fixtures/replan"
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

# ---------------------------------------------------------------------------
# A repo with one mission parked at `plan`. Optional args: files to stage into
# the mission dir (prior plan.json, review rounds).
# ---------------------------------------------------------------------------
new_repo() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null,
  "planReviewRound": 1
}
JSON
  echo "$repo"
}

mdir() { printf '%s/.git/lcars/missions/test-001' "$1"; }

# The on-disk state review_fail leaves when it bounces a Mission back to Plan:
# the round's objections AND the REVISION TOKEN — a snapshot of the exact plan
# the reviewer reviewed. The token is the only thing that says "a revision was
# requested"; ambient plan.json never is (see the note in review_fail).
revision_pending() { # mission-dir  reviewed-plan  verdict
  cp "$2" "$1/plan.json"
  cp "$2" "$1/plan-under-review.json"
  cp "$3" "$1/plan-review-1.json"
}

run_plan_save() { # repo planfile
  OUT="$( cd "$1" && bash "$SCRIPT" plan-save --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
}

# ===========================================================================
section "PART B — the deterministic over-correction guard (plan-save)"
# ===========================================================================

# --- 1. THE MEASURED CASE ---------------------------------------------------
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
work="$TMPROOT/w1"; mkdir -p "$work"; cp "$FIX/over-corrected-plan.json" "$work/plan.json"
run_plan_save "$repo" "$work/plan.json"

assert_eq  "1a THE MEASURED CASE: the 14-deep chain is REJECTED" "$RC" "1"
assert_has "1b …and says it is an over-correction" "OVER-CORRECTION" "$OUT"
assert_has "1c …naming the objection's ticket"     "t-012" "$OUT"
# Every unlicensed added edge, by name. The objection names t-012 (its id) and
# t-003/t-010/t-011 (its prose), so those four tickets' edges are licensed; the
# chain's other seven added edges are not.
for edge in "t-006 now depends on t-005" "t-007 now depends on t-006" \
            "t-008 now depends on t-007" "t-009 now depends on t-008" \
            "t-014 now depends on t-013"; do
  assert_has "1d …and names the added edge: $edge" "$edge" "$OUT"
done
# A LICENSED ticket's added edge is NOT listed as an offence.
assert_no  "1e …and does NOT accuse t-012 (the objection names it)" "t-012 now depends on t-011 — nobody asked" "$OUT"
assert_no  "1f …and does NOT accuse t-010 (the objection's prose names it)" "t-010 now depends on t-009 — nobody asked" "$OUT"
# …nor an edge POINTING AT the ticket the objection is about (t-012 is its
# ticketId, so an inbound edge is something the objection could have asked for).
assert_no  "1f2 …and does NOT accuse an edge INTO the objection's own ticket" \
           "t-013 now depends on t-012 — nobody asked" "$OUT"
# The pre-revision plan is STILL on disk: a rejection must not overwrite the
# graph it is comparing against, or the retry would compare against the chain.
first_dep="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[11]["dependencies"])' "$d/plan.json")"
assert_eq  "1g …and plan.json on disk is still the PRE-revision plan" "$first_dep" "['t-003']"
# The reason is left where cmd_plan's retry loop reads it.
if [ -f "$work/.plan-reject-note" ] && grep -q 'OVER-CORRECTION' "$work/.plan-reject-note"; then
  ok "1h …and the rejection reason is written beside the worker's plan.json"
else
  bad "1h …and the rejection reason is written beside the worker's plan.json"
fi

# --- 2. the revision the reviewer actually asked for -------------------------
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_save "$repo" "$FIX/patched-plan.json"
assert_eq  "2a a revision adding ONLY t-010 -> t-012 is ACCEPTED" "$RC" "0"
assert_has "2b …and advances to plan-review"  "Stage:  plan-review" "$OUT"
assert_has "2c …and says the guard checked it" "Revision checked against 1 objection(s)" "$OUT"
assert_no  "2d …and does not cry over-correction" "OVER-CORRECTION" "$OUT"

# --- 3. an unrequested edge on a ticket the objection DOES name ---------------
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_save "$repo" "$FIX/named-ticket-extra-edge.json"
assert_eq  "3a an extra edge on the NAMED ticket is ACCEPTED" "$RC" "0"
assert_has "3b …and says every added edge was on a named ticket" \
           "every one on or into a ticket the objections name" "$OUT"

# --- 4. a renumbered / resized ticket set -> UNCHECKED, no false bounce -------
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_save "$repo" "$FIX/renumbered-plan.json"
assert_eq  "4a a RENUMBERED revision passes through (no false bounce)" "$RC" "0"
assert_has "4b …and SAYS it could not be checked" "REVISION UNCHECKED" "$OUT"
assert_has "4c …and says why"                      "the ticket set changed" "$OUT"
assert_no  "4d …and does not claim it was checked" "Revision checked against" "$OUT"

repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_save "$repo" "$FIX/resized-plan.json"
assert_eq  "4e a RESIZED ticket set passes through" "$RC" "0"
assert_has "4f …and SAYS it could not be checked"   "REVISION UNCHECKED" "$OUT"
assert_has "4g …and names the missing ticket"       "t-014" "$OUT"

# --- 5. no revision requested (no token) -> the guard never runs -------------
# Objections on disk, an ambient plan.json, but NO token. That is a first plan,
# or a mission whose objections belong to history. The guard must be silent.
repo="$(new_repo)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan.json"
cp "$FIX/plan-review-1.json"   "$d/plan-review-1.json"
run_plan_save "$repo" "$FIX/over-corrected-plan.json"
assert_eq  "5a objections but NO revision token -> saved"   "$RC" "0"
assert_no  "5b …and the guard says nothing at all"          "REVISION UNCHECKED" "$OUT"
assert_no  "5c …and never accuses it"                       "OVER-CORRECTION" "$OUT"

# The token is there but the plan it points at is not readable -> UNCHECKED.
repo="$(new_repo)"; d="$(mdir "$repo")"
cp "$FIX/plan-review-1.json" "$d/plan-review-1.json"
printf 'not json at all\n' > "$d/plan-under-review.json"
run_plan_save "$repo" "$FIX/over-corrected-plan.json"
assert_eq  "5d an unreadable reviewed plan -> passes through" "$RC" "0"
assert_has "5e …and SAYS it could not be checked"   "REVISION UNCHECKED" "$OUT"
assert_has "5f …wording it from the token, not from a guess about plan.json" \
           "the plan Plan Review reviewed is not a readable list" "$OUT"

# --- 6. a plan with NO objections is untouched -------------------------------
# The guard must not run at all. The readout has to be byte-identical to a
# pre-S178 save, which is asserted below against the recorded baseline.
repo="$(new_repo)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan.json"
run_plan_save "$repo" "$FIX/over-corrected-plan.json"
assert_eq  "6a a plan with NO objections is saved"      "$RC" "0"
assert_no  "6b …the guard says NOTHING (no 'checked')"  "Revision checked" "$OUT"
assert_no  "6c …the guard says NOTHING (no 'UNCHECKED')" "REVISION UNCHECKED" "$OUT"
assert_no  "6d …and never accuses it"                    "OVER-CORRECTION" "$OUT"
NOOBJ_OUT="$OUT"

# ===========================================================================
section "PART B — the PRODUCER: who writes the revision token, and when"
# ===========================================================================
# review_fail is the ONE place in the system that asks for a revision, so it is
# the only place that can say so with evidence. These drive the real
# `review-save` subcommand.
review_repo() { # stage-round -> echoes repo dir, mission parked at plan-review
  local repo; repo="$(mktemp -d "$TMPROOT/rev.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"
  mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan-review",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null,
  "planReviewRound": ${1:-0}
}
JSON
  cp "$FIX/pre-review-plan.json" "$d/plan.json"
  echo "$repo"
}
run_review_save() { # repo verdict
  OUT="$( cd "$1" && LCARS_GH_BIN=true bash "$SCRIPT" review-save --mission test-001 --verdict "$2" 2>&1 )"
  RC=$?
}

# A loop-back (round 1 of 3) MUST leave the token, holding the exact plan the
# reviewer read.
repo="$(review_repo 0)"; d="$(mdir "$repo")"
run_review_save "$repo" "$FIX/plan-review-1.json"
assert_has "R1a a failed review bounces the Mission back to Plan" "Stage:  plan" "$OUT"
if cmp -s "$d/plan-under-review.json" "$FIX/pre-review-plan.json"; then
  ok "R1b …leaving the token — a byte-exact snapshot of the reviewed plan"
else
  bad "R1b …leaving the token — a byte-exact snapshot of the reviewed plan"
fi

# The ROUND-3 escalation must NOT leave one: it parks the Mission at plan-review
# awaiting the captain and asks Plan for nothing, so a token there would linger
# and poison a much later, unrelated re-plan.
repo="$(review_repo 2)"; d="$(mdir "$repo")"
run_review_save "$repo" "$FIX/plan-review-1.json"
assert_has "R2a the third failed round escalates to the human" "escalated" "$OUT"
if [ -f "$d/plan-under-review.json" ]; then
  bad "R2b …and leaves NO revision token behind"
else
  ok "R2b …and leaves NO revision token behind"
fi

# A PASS clears any token — belt and braces beside plan-save's own consume.
repo="$(review_repo 0)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan-under-review.json"
printf '{ "passed": true, "issues": [] }\n' > "$TMPROOT/pass.json"
run_review_save "$repo" "$TMPROOT/pass.json"
assert_has "R3a an approved plan advances to Schedule" "Stage:  schedule" "$OUT"
if [ -f "$d/plan-under-review.json" ]; then
  bad "R3b …and clears any outstanding revision token"
else
  ok "R3b …and clears any outstanding revision token"
fi

# ===========================================================================
section "PART A — the Plan prompt tells a revising planner it is patching"
# ===========================================================================

block() { # mission-dir -> the revision block
  LCARS_ATT_TEST_DIR="$1" bash "$SCRIPT" plan-revision-block-test 2>&1
}

md="$TMPROOT/blk-none"; mkdir -p "$md"
B="$(block "$md")"
assert_eq "7a a Mission with NO objections gets NO revision block (empty)" "$B" ""

# Objections WITHOUT the token — the logged-bug `lcars feedback` path, which
# deletes plan.json but keeps plan-review-*.json. The block must NOT fire: it
# would tell the worker to patch a plan that is not there.
md="$TMPROOT/blk-stale"; mkdir -p "$md"; cp "$FIX/plan-review-1.json" "$md/"
assert_eq "7a2 stale objections with NO revision token get NO block" "$(block "$md")" ""

md="$TMPROOT/blk-rev"; mkdir -p "$md"; cp "$FIX/plan-review-1.json" "$md/"
cp "$FIX/pre-review-plan.json" "$md/plan-under-review.json"
B="$(block "$md")"
assert_has "7b a REVISION is told it is a patch"       "THIS IS A REVISION, NOT A RE-PLAN" "$B"
assert_has "7c …change NOTHING ELSE"                    "change NOTHING" "$B"
assert_has "7d …keep existing dependencies unless named" "unless an
  objection names that ticket" "$B"
# The prompt must name an input that actually exists — the file cmd_plan lists.
assert_has "7d2 …and names the artifact it was actually handed" \
           "plan-under-review.json" "$B"
assert_has "7e …with the MEASURED cost"                 "14 waves of one ticket each" "$B"
assert_has "7f …and the positive rule"                  "GENUINELY needs BUILT FIRST" "$B"
assert_has "7g …'comes after' is not a dependency"      '"Comes after" is not a dependency' "$B"
# The trap this must NOT fall into: telling the planner to declare fewer edges
# trades this bug for under-declaration, which is the failure the reviewer
# CORRECTLY caught.
assert_has "7h …and explicitly refuses to ask for fewer edges" \
           "This is NOT an instruction to declare FEWER dependencies" "$B"
assert_no  "7i …and never sets a wave-count target"     "wave count" "$B"
assert_no  "7j …and never says minimise"                "minimis" "$B"

# ===========================================================================
section "PART A/B end to end — the prompt, and the bounce reaching the retry"
# ===========================================================================
# A stub worker adapter: records every prompt it is handed, and answers the plan
# role with a file chosen by $STUB_PLAN. No CLI, no tokens.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
case "$role" in
  plan) cp "$STUB_PLAN" "$outdir/plan.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
}
make_worker_bin() { printf '#!/usr/bin/env bash\necho UNEXPECTED-SPAWN >&2\nexit 96\n' >"$1"; chmod +x "$1"; }
make_gh()        { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

e2e_repo() { # -> echoes repo dir (a real git repo on a real mission branch)
  local repo; repo="$(mktemp -d "$TMPROOT/e2e.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    printf '# fixture\n' > README.md
    # A CONTEXT.md so resolve_context_source never reaches for a context-pack
    # worker — this suite spawns exactly the plan worker and nothing else.
    printf '# Context\n\nA fixture repo.\n' > CONTEXT.md
    git add -A && git commit -q -m init
    git checkout -q -b lcars/test-001
  ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null
}
JSON
  printf '# PRD\n\nBuild the MBR builder.\n' > "$repo/.git/lcars/missions/test-001/prd.md"
  printf '# Validated Plan\n\n## Synthesis\nBuild it.\n' > "$repo/.git/lcars/missions/test-001/validated-plan.md"
  make_adapter    "$repo.adapter"
  make_worker_bin "$repo.worker"
  make_gh         "$repo.gh"
  echo "$repo"
}

run_plan_stage() { # repo stub-plan [run.sh-override]
  : >"$1.prompts"
  # LCARS_WORKER_HANG_SECS=0 runs the (instant) stub adapter INLINE. Left on, the
  # hang guard's poll loop sleeps up to 15s per spawn and this section takes two
  # minutes for nothing.
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      PROMPTS="$1.prompts" STUB_PLAN="$2" \
      bash "${3:-$SCRIPT}" plan --mission test-001 2>&1 )"
  RC=$?
  PROMPT_FILE="$1.prompts"
}

# --- 8. no objections: the Plan prompt is BYTE-IDENTICAL to today ------------
# Byte-identity is proven the only way it can be: the prompt with the S178 code
# in place is diffed against the prompt the PREVIOUS commit's run.sh produces,
# over the same fixture. Nothing about a first plan may move.
repo="$(e2e_repo)"
run_plan_stage "$repo" "$FIX/pre-review-plan.json"
assert_eq "8a a first plan advances" "$RC" "0"
NEW_PROMPT="$TMPROOT/prompt.new"; cp "$PROMPT_FILE" "$NEW_PROMPT"

# The baseline is HEAD's run.sh, standing in a skill dir that is otherwise this
# one — its stages/, templates and adapters are symlinked in, because run.sh
# resolves them relative to itself and a bare copy in /tmp finds none of them
# (which silently changes the prompt and makes the comparison meaningless).
BASE_DIR="$TMPROOT/skill-base"
mkdir -p "$BASE_DIR"
for f in "$REPO_ROOT"/skills/lcars-run/*; do
  [ "$(basename "$f")" = "run.sh" ] && continue
  ln -s "$f" "$BASE_DIR/$(basename "$f")"
done
BASE_SH="$BASE_DIR/run.sh"
if ( cd "$REPO_ROOT" && git show "${LCARS_BASE_REF:-HEAD}:skills/lcars-run/run.sh" > "$BASE_SH" ) 2>/dev/null && [ -s "$BASE_SH" ]; then
  repo2="$(e2e_repo)"
  run_plan_stage "$repo2" "$FIX/pre-review-plan.json" "$BASE_SH"
  BASE_PROMPT="$TMPROOT/prompt.base"; cp "$PROMPT_FILE" "$BASE_PROMPT"
  # Both prompts embed per-run absolute paths (the worker's mktemp scratch dir,
  # the fixture repo, the mission dir). Those are normalised out of BOTH sides;
  # everything else must match to the byte.
  norm() { sed -e 's#Your scratch output directory is: .*#Your scratch output directory is: <ODIR>#' \
               -e "s#$TMPROOT/e2e\.[A-Za-z0-9]*#<REPO>#g" \
               -e 's#/var/folders/[^ ]*#<TMP>#g' -e 's#^/tmp/[^ ]*#<TMP>#g' "$1"; }
  # S181 RE-SCOPED THIS, deliberately. It asserted BYTE-IDENTITY on the premise
  # that "nothing about a first plan may move" — which S178 was entitled to,
  # because S178 changed only the revision path. S181 changes the first pass ON
  # PURPOSE: the "what a dependency IS" framing was revision-only, and a MEASURED
  # first-pass 12-ticket plan came back as a queue having never read a word of it.
  # So the guard now permits EXACTLY ONE difference — the lines of the shared
  # dependency_semantics_block — and still fails on anything else, in either
  # direction. Once this round is committed the two prompts are identical again
  # and the first branch takes over; the check reads the same either way.
  LICENCE="$TMPROOT/dep-semantics-block.txt"
  bash "$SCRIPT" dependency-semantics-block-test >"$LICENCE" 2>/dev/null || : >"$LICENCE"
  if diff <(norm "$NEW_PROMPT") <(norm "$BASE_PROMPT") >"$TMPROOT/prompt.diff" 2>&1; then
    ok "8b a first plan's prompt moves ONLY by the shared dependency framing (identical)"
  else
    diff -u <(norm "$BASE_PROMPT") <(norm "$NEW_PROMPT") >"$TMPROOT/prompt.udiff" 2>&1
    n_removed="$(grep '^-' "$TMPROOT/prompt.udiff" | grep -vc '^---')"
    n_unlicensed=0
    while IFS= read -r dl; do
      dl="${dl#+}"
      [ -n "$dl" ] || continue
      grep -Fqx -- "$dl" "$LICENCE" || n_unlicensed=$((n_unlicensed + 1))
    done < <(grep '^+' "$TMPROOT/prompt.udiff" | grep -v '^+++')
    if [ -s "$LICENCE" ] && [ "$n_removed" -eq 0 ] && [ "$n_unlicensed" -eq 0 ]; then
      ok "8b a first plan's prompt moves ONLY by the shared dependency framing"
    else
      bad "8b a first plan's prompt moves ONLY by the shared dependency framing ($n_removed removed, $n_unlicensed unlicensed added)"
      sed -n '1,40p' "$TMPROOT/prompt.diff" | sed 's/^/       /'
    fi
  fi
else
  bad "8b could not read ${LCARS_BASE_REF:-HEAD}:skills/lcars-run/run.sh for the byte-identity baseline"
fi
assert_no "8c …and carries no revision contract" "THIS IS A REVISION" "$(cat "$NEW_PROMPT")"

# --- 9. a revision: the prior plan is fed, and the bounce reaches the retry ---
repo="$(e2e_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_stage "$repo" "$FIX/over-corrected-plan.json"
P="$(cat "$PROMPT_FILE")"

assert_has "9a a revising planner is handed the reviewer objections" \
           "plan-review-1.json   (reviewer objections" "$P"
assert_has "9b …and the exact plan under review, to patch" \
           "plan-under-review.json   (THE PLAN UNDER REVIEW" "$P"
assert_has "9c …and the revision contract"  "THIS IS A REVISION, NOT A RE-PLAN" "$P"

# The stub returns the 14-deep chain EVERY time. Attempts 1 and 2 are rejected
# and TOLD WHY; the LAST attempt is advisory — the plan is VALID, so it is saved
# and handed to Plan Review unresolved rather than deadlocking the Mission at
# `plan` with no gate and no state change. That is the existing Plan Review loop
# absorbing it, exactly as the brief requires, with no new gate.
assert_eq  "9d …the Stage does NOT deadlock on a valid plan" "$RC" "0"
assert_has "9d2 …it advances to Plan Review"       "Stage:  plan-review" "$OUT"
assert_has "9d3 …saying the over-correction is UNRESOLVED" "OVER-CORRECTION UNRESOLVED" "$OUT"
assert_has "9d4 …and naming what it objected to"   "now depends on" "$OUT"
nrej="$(grep -c 'YOUR PREVIOUS ATTEMPT WAS REJECTED' "$PROMPT_FILE")"
assert_eq "9e …and the rejection reached the RETRY prompts (2 of 3 spawns)" "$nrej" "2"
assert_has "9f …carrying the guard's verbatim reason" "OVER-CORRECTION" "$P"
assert_has "9g …and the specific edges"               "now depends on" "$P"
# The retry note must not be a generic scold: the "no file" channel is a
# DIFFERENT failure and must not fire here (the worker DID produce a file).
assert_no  "9h …and never claims the worker produced no file" \
           "ended its turn WITHOUT creating the required" "$P"

# --- 10. a revision that obeys is saved, and the retry note never appears -----
repo="$(e2e_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_stage "$repo" "$FIX/patched-plan.json"
assert_eq "10a an obedient revision advances" "$RC" "0"
nrej="$(grep -c 'YOUR PREVIOUS ATTEMPT WAS REJECTED' "$PROMPT_FILE")"
assert_eq "10b …and no retry prompt was ever needed" "$nrej" "0"

# ===========================================================================
section "PART B — the LIVE-COPILOT baseline: three real revisions, all churn"
# ===========================================================================
# tests/fixtures/replan/live/ is REAL model output, measured against pristine
# HEAD on 2026-08-28: an 8-ticket plan, ONE objection asking for ONE edge
# (t-004 -> t-006), three identical live Copilot runs, three failures. NONE of
# them is a chain — they are graph CHURN, and run 3 barely moves the wave count.
# They are here because a guard keyed on "it became a chain", or on wave count,
# or on any aggregate shape, would wave all three straight through. The guard is
# a per-ticket EDGE DIFF and this section is what holds it to that.
LFIX="$FIX/live"
for n in 1 2 3; do
  repo="$(new_repo)"; d="$(mdir "$repo")"
  revision_pending "$d" "$LFIX/pre-review-plan.json" "$LFIX/plan-review-1.json"
  run_plan_save "$repo" "$LFIX/live-revision-$n.json"
  assert_eq  "L${n}a live Copilot run $n (non-chain CHURN) is REJECTED" "$RC" "1"
  assert_has "L${n}b …as an over-correction"  "OVER-CORRECTION" "$OUT"
  # t-007 gaining t-001 is the invariant across all three runs, and no objection
  # names t-007. It is the single edge run 3 can be caught on.
  assert_has "L${n}c …naming t-007's unrequested edge" "t-007 now depends on t-001" "$OUT"
  # …while the edge the objection DID ask for is never called an offence.
  assert_no  "L${n}d …and never accuses the edge that WAS requested" \
             "t-006 now depends on t-004 — nobody asked" "$OUT"
done
# Run 3 is the sharpest of the three: its ONLY unlicensed addition is that one
# t-007 edge, so it is the case an aggregate-shape guard would certainly miss.
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$LFIX/pre-review-plan.json" "$LFIX/plan-review-1.json"
run_plan_save "$repo" "$LFIX/live-revision-3.json"
assert_has "L4 …and run 3 is caught on ONE unlicensed edge (1 of 3 added)" \
           "and 1 of them touch no ticket" "$OUT"
# All three runs also DELETED edges nobody asked about — t-004 lost t-001 every
# time. Those removals are NOT what catches them, and in these three cases they
# are not even reported: every removal landed on a ticket the objection NAMES
# (t-001/t-004/t-006), so the same licence that permits an added edge there
# permits a dropped one. Asserted so nobody later reads the removal signal as
# load-bearing for this measurement — the added edges are what do the work.
assert_no  "L5 …a removal on a NAMED ticket is not reported as unrequested" \
           "t-004 no longer depends on t-001" "$OUT"

# A revision that ONLY removes an unrequested edge is ACCEPTED, and says so.
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_plan_save "$repo" "$FIX/dropped-edge-plan.json"
assert_eq  "L6a a revision that only REMOVES an edge is ACCEPTED" "$RC" "0"
assert_has "L6b …and the removal is reported"      "t-007 no longer depends on t-005" "$OUT"
assert_has "L6c …explicitly as not a rejection"    "not a rejection" "$OUT"

# ===========================================================================
section "FIX ROUND 1 — the guard must never kill an honest plan"
# ===========================================================================

# --- F1. `lcars feedback` — the most common human action in the pipeline -----
# The ORDINARY Verify send-back (skills/lcars-feedback/feedback.sh) resets the
# stage to `align` and DELIBERATELY KEEPS every artifact: "The prior PRD and
# artifacts are kept". So plan.json AND plan-review-*.json both survive, and the
# Mission then re-runs align -> research -> validate -> plan against a CORRECTED
# PRD. Keying "this is a revision" off those ambient files bounced that honest
# new plan (measured: 6 edges) and told the worker to patch a plan the captain
# had just rejected. The token cures it by construction — review_fail wrote one,
# the revision that answered it CONSUMED it, and nothing has written another.
feedback_sendback_state() { # mission-dir  — exactly what feedback.sh leaves
  cp "$FIX/pre-review-plan.json" "$1/plan.json"          # kept, not deleted
  cp "$FIX/plan-review-1.json"   "$1/plan-review-1.json" # kept, not deleted
  rm -f "$1/plan-under-review.json"                      # consumed by the save
}
repo="$(new_repo)"; d="$(mdir "$repo")"
feedback_sendback_state "$d"
run_plan_save "$repo" "$FIX/over-corrected-plan.json"
assert_eq  "F1a after an lcars-feedback send-back, a fresh plan is SAVED" "$RC" "0"
assert_no  "F1b …with no false bounce"                "OVER-CORRECTION" "$OUT"
assert_no  "F1c …and no UNCHECKED noise either"       "REVISION UNCHECKED" "$OUT"
assert_has "F1d …it advances normally"                "Stage:  plan-review" "$OUT"

# …and the same state end to end: the Plan prompt must NOT tell the worker to
# patch a plan the captain just rejected, and must not claim an input it has not
# listed (the logged-bug feedback path deletes plan.json and keeps the verdicts).
repo="$(e2e_repo)"; d="$(mdir "$repo")"
feedback_sendback_state "$d"
run_plan_stage "$repo" "$FIX/over-corrected-plan.json"
P="$(cat "$PROMPT_FILE")"
assert_eq  "F1e …and the Plan Stage advances"          "$RC" "0"
assert_no  "F1f …the prompt carries NO revision contract" "THIS IS A REVISION" "$P"
assert_no  "F1g …and never names a plan it did not list" "plan-under-review.json" "$P"

# …and `lcars feedback` itself clears an OUTSTANDING request, closing the one
# window where a token could survive a send-back: a Mission sent back while a
# revision was still owed. The real feedback.sh is driven here, both branches.
FEEDBACK_SH="${LCARS_FEEDBACK_SCRIPT:-$REPO_ROOT/skills/lcars-feedback/feedback.sh}"
# The extra fields arrive ALREADY one-per-line and indented — state.json's
# one-field-per-line shape is LCARS's own invariant and the writer refuses a
# file that breaks it, so a fixture must be written the way file.sh writes one.
feedback_repo() { # extra-state-json-lines -> echoes repo dir, mission at plan, token owed
  local repo; repo="$(mktemp -d "$TMPROOT/fb.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"
  mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "title": "t",
  "stage": "plan",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null,
${1:-  "type": "feature"}
}
JSON
  printf '# PRD\n' > "$d/prd.md"
  revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
  echo "$repo"
}
for variant in 'ORDINARY|  "type": "feature"' \
               $'LOGGED-BUG|  "type": "bug",\n  "parentMission": "test-000"'; do
  label="${variant%%|*}"; extra="${variant#*|}"
  repo="$(feedback_repo "$extra")"; d="$(mdir "$repo")"
  ( cd "$repo" && LCARS_GH_BIN=true bash "$FEEDBACK_SH" --mission test-001 \
      --feedback "the nav is wrong" ) >/dev/null 2>&1
  if [ -f "$d/plan-under-review.json" ]; then
    bad "F1h a $label send-back clears an outstanding revision request"
  else
    ok "F1h a $label send-back clears an outstanding revision request"
  fi
done

# --- F2. the guard is ADVISORY at the last attempt, never fatal --------------
# Covered end to end at 9d–9d4 (the Stage advances instead of deadlocking).
# Here: --final-attempt on plan-save alone, so the contract is pinned at the one
# place that implements it.
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
OUT="$( cd "$repo" && bash "$SCRIPT" plan-save --mission test-001 \
          --plan "$FIX/over-corrected-plan.json" --final-attempt 2>&1 )"; RC=$?
assert_eq  "F2a --final-attempt SAVES a valid over-corrected plan" "$RC" "0"
assert_has "F2b …saying it is unresolved, not that it is fine" "OVER-CORRECTION UNRESOLVED" "$OUT"
assert_has "F2c …and hands it to Plan Review"       "Stage:  plan-review" "$OUT"
assert_has "F2d …naming the edges it could not get fixed" "now depends on" "$OUT"
# …and the token is consumed on that save, so the NEXT plan is not diffed
# against this ancient graph.
if [ -f "$d/plan-under-review.json" ]; then
  bad "F2e …and the revision token is consumed on save"
else
  ok "F2e …and the revision token is consumed on save"
fi

# --- F3. odd ticketId formats: resolve them, and FAIL OPEN when you cannot ---
# Three plausible reviewer formattings. The normaliser resolves each to a real
# ticket, so the check RUNS and the edge the objection asks for is accepted —
# that is the convenience half. The load-bearing half is F3d below.
odd_verdict() { # file  ticketId-json  prose
  cat > "$1" <<JSON
{ "passed": false, "issues": [ { "ticketId": $2, "objection": "$3" } ] }
JSON
}
# A revision that adds exactly ONE edge, on t-005 — the ticket each formatting
# below is trying to name.
ASKED="$TMPROOT/asked-t005.json"
python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
for t in p:
    if t["id"] == "t-005":
        t["dependencies"] = sorted(set(t["dependencies"]) | {"t-002"})
open(sys.argv[2], "w").write(json.dumps(p, indent=2) + "\n")
' "$FIX/pre-review-plan.json" "$ASKED"

n=0
for spec in 'NUMERIC|5|Ticket 5 needs ticket 2 built first.' \
            'UPPERCASE|"T-005"|T-005 must be built after the data layer.' \
            'PADDED|" t-005 "|It needs the data layer built first.'; do
  n=$((n+1))
  label="${spec%%|*}"; rest="${spec#*|}"; tj="${rest%%|*}"; prose="${rest#*|}"
  repo="$(new_repo)"; d="$(mdir "$repo")"
  cp "$FIX/pre-review-plan.json" "$d/plan.json"
  cp "$FIX/pre-review-plan.json" "$d/plan-under-review.json"
  odd_verdict "$d/plan-review-1.json" "$tj" "$prose"
  run_plan_save "$repo" "$ASKED"
  assert_eq  "F3${n}a a ${label} ticketId resolves — the asked-for edge is ACCEPTED" "$RC" "0"
  assert_no  "F3${n}b …and is never called over-correction" "OVER-CORRECTION" "$OUT"
  assert_has "F3${n}c …and the check actually RAN"  "Revision checked against" "$OUT"
done

# THE LOAD-BEARING HALF. When nothing an objection says resolves to a ticket in
# this plan, the licence map is provably wrong — every added edge would look
# unlicensed and the whole plan would bounce. That is exactly where this round's
# own principle says to fail open. Driven with the 14-deep chain, so a guard that
# did not fail open here would certainly reject.
repo="$(new_repo)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan.json"
cp "$FIX/pre-review-plan.json" "$d/plan-under-review.json"
odd_verdict "$d/plan-review-1.json" '"the sidebar ticket"' \
            "The sidebar work must come after the shell is built."
run_plan_save "$repo" "$FIX/over-corrected-plan.json"
assert_eq  "F3d an objection naming NO ticket in the plan does NOT bounce" "$RC" "0"
assert_no  "F3e …and is never called over-correction"  "OVER-CORRECTION" "$OUT"
assert_has "F3f …it says UNCHECKED out loud"           "REVISION UNCHECKED" "$OUT"
assert_has "F3g …and names why"  "no objection names any ticket id in this plan" "$OUT"

# --- F4. an edge POINTING AT the ticket an objection is about ----------------
# "t-004 ports the stylesheet every later row-rendering ticket relies on; the
# tickets that render rows must depend on it." Nobody NAMES t-005/t-006; the
# objection unambiguously ASKS for those edges.
repo="$(new_repo)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan.json"
cp "$FIX/pre-review-plan.json" "$d/plan-under-review.json"
cat > "$d/plan-review-1.json" <<'JSON'
{ "passed": false, "issues": [ { "ticketId": "t-004",
  "objection": "t-004 ports the stylesheet every later row-rendering ticket relies on; the tickets that render rows must depend on it." } ] }
JSON
INBOUND="$TMPROOT/inbound.json"
python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
for t in p:
    if t["id"] in ("t-005", "t-006"):
        t["dependencies"] = sorted(set(t["dependencies"]) | {"t-004"})
open(sys.argv[2], "w").write(json.dumps(p, indent=2) + "\n")
' "$FIX/pre-review-plan.json" "$INBOUND"
run_plan_save "$repo" "$INBOUND"
assert_eq  "F4a edges INTO the objection's own ticket are ACCEPTED" "$RC" "0"
assert_no  "F4b …and never called unrequested"  "OVER-CORRECTION" "$OUT"
assert_has "F4c …and the check ran (not a fail-open)" "Revision checked against" "$OUT"

# --- F6/F7. only 0/1/3/4 may be trusted --------------------------------------
# A crash in the check is the CHECK failing, not the plan. Measured: an ascii
# stdout encoding made the block raise on its own ⚠, exit 1, and DISCARD a
# well-formed plan — the fail-open branch itself failing closed.
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
OUT="$( cd "$repo" && PYTHONIOENCODING=ascii bash "$SCRIPT" plan-save \
          --mission test-001 --plan "$FIX/patched-plan.json" 2>&1 )"; RC=$?
assert_eq  "F6a an ascii stdout encoding cannot break the guard" "$RC" "0"
assert_has "F6b …the honest revision is still saved"  "Stage:  plan-review" "$OUT"
assert_no  "F6c …and it is not accused of anything"   "OVER-CORRECTION" "$OUT"

repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
OUT="$( cd "$repo" && LCARS_PYTHON_BIN=/nonexistent-python bash "$SCRIPT" plan-save \
          --mission test-001 --plan "$FIX/over-corrected-plan.json" 2>&1 )"; RC=$?
assert_eq  "F7a a missing interpreter passes the plan through"  "$RC" "0"
assert_has "F7b …and SAYS the guard could not run"  "REVISION UNCHECKED" "$OUT"
assert_has "F7c …naming it as the CHECK breaking, not the plan" \
           "the over-correction guard itself failed to run" "$OUT"

# --- F8. peak 0 means UNKNOWN, never serial ----------------------------------
wsl() { LCARS_WS_NT="$1" LCARS_WS_NW="$2" LCARS_WS_PEAK="$3" \
          bash "$SCRIPT" wave-shape-line-test 2>&1; }
assert_eq  "F8a an unreadable wavemap says NOTHING (4 tickets, 2 waves, peak ?)" \
           "$(wsl 4 2 0)" ""
assert_has "F8b …while a real serial plan still says so" "NO parallelism" "$(wsl 14 14 1)"
assert_has "F8c …and a parallel one reports its peak"    "up to 5 ticket(s)" "$(wsl 12 4 5)"

# ===========================================================================
section "FIX ROUND 2 — the signals reach the path the captain actually runs"
# ===========================================================================
# `lcars run` (cmd_drive, auto AND --step) captures each Stage's stdout and
# re-emits ONE synthesized line, so everything plan-save prints is invisible
# there unless drive_detail carries it. The tester's repro was exact: grepping
# the DRIVE output for OVER-CORRECTION|UNRESOLVED|UNCHECKED returned 0 hits.
# These drive the real `drive --step`, and also read events.jsonl — a marker
# that lives only in terminal scrollback is not durable.
NOTIFY_STUB="$TMPROOT/notify"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOTIFY_STUB"; chmod +x "$NOTIFY_STUB"

run_drive_step() { # repo stub-plan [extra-env…]
  : >"$1.prompts"
  local repo="$1" plan="$2"; shift 2
  OUT="$( cd "$repo" && env \
      LCARS_GH_BIN="$repo.gh" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" LCARS_WORKER_HANG_SECS=0 \
      LCARS_NOTIFY="$NOTIFY_STUB" \
      PROMPTS="$repo.prompts" STUB_PLAN="$plan" "$@" \
      bash "$SCRIPT" drive --mission test-001 --step 2>&1 )"
  RC=$?
}
events() { cat "$(mdir "$1")/events.jsonl" 2>/dev/null; }

# --- D1a. an UNRESOLVED over-correction on the drive line -------------------
# One try, so that single attempt IS the final one: plan-save saves the valid
# plan with the UNRESOLVED note rather than deadlocking (F2), and the driver
# must say so.
repo="$(e2e_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_drive_step "$repo" "$FIX/over-corrected-plan.json" LCARS_WORKER_TRIES=1
assert_has "D1a an lcars-run --step shows the unresolved over-correction" \
           "over-correction unresolved" "$OUT"
assert_has "D1b …saying where it went"  "passed to Plan Review" "$OUT"
assert_has "D1c …beside the ticket count, on the one Stage line" "14 ticket(s) —" "$OUT"
assert_has "D1d …and it is DURABLE in events.jsonl"  "over-correction unresolved" "$(events "$repo")"

# --- D1b. an UNCHECKED revision on the drive line ---------------------------
repo="$(e2e_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
run_drive_step "$repo" "$FIX/renumbered-plan.json" LCARS_WORKER_TRIES=1
assert_has "D1e …and an UNCHECKED revision is visible too" "revision unchecked" "$OUT"
assert_has "D1f …durably"  "revision unchecked" "$(events "$repo")"

# --- D1c. a clean plan's drive line is unchanged ----------------------------
repo="$(e2e_repo)"
run_drive_step "$repo" "$FIX/pre-review-plan.json"
assert_has "D1g a clean first plan still reads exactly as before" "14 ticket(s)" "$OUT"
assert_no  "D1h …with no over-correction marker"   "over-correction" "$OUT"
assert_no  "D1h2 …and no unchecked marker"        "revision unchecked" "$OUT"
assert_no  "D1i …and none in the event stream" "unresolved" "$(events "$repo")"

# --- D1d. the WAVE SHAPE on the drive line ----------------------------------
# Part C's stated purpose is that the captain sees the cost without opening a
# file. The board card does; the Schedule CLI does; this is the path he runs.
drive_sched() { # plan-file -> sets OUT, and echoes the repo
  local repo; repo="$(e2e_repo)"
  local d; d="$(mdir "$repo")"
  cp "$1" "$d/approved-plan.json"
  sed 's/"stage": "plan"/"stage": "schedule"/' "$d/state.json" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state.json"
  OUT="$( cd "$repo" && env LCARS_GH_BIN="$repo.gh" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" LCARS_NOTIFY="$NOTIFY_STUB" \
      bash "$SCRIPT" drive --mission test-001 --step 2>&1 )"
  DSREPO="$repo"
}
drive_sched "$FIX/over-corrected-plan.json"
assert_has "D1j the drive line names the wave COUNT (as before)" "14 wave(s)" "$OUT"
assert_has "D1k …and now the SHAPE"  "1 ticket each, no parallelism" "$OUT"
assert_has "D1l …durably in events.jsonl" "no parallelism" "$(events "$DSREPO")"

drive_sched "$FIX/pre-review-plan.json"
assert_has "D1m a parallel plan reports its peak on the drive line" "up to " "$OUT"
assert_no  "D1n …and is never called serial"  "no parallelism" "$OUT"

# --- D2. the two surfaces derive from ONE string ----------------------------
# Not two hand-copied literals: the board's one-ticket shape IS the CLI's phrase
# upper-cased, so drift fails here instead of reaching the captain.
CLI_SOLO="$(wsl 1 1 1 | sed -n 's/^Wave shape: \(.*\)\.$/\1/p')"
BOARD_SOLO="$(cd "$REPO_ROOT/web" && python3 -c '
from lcars_serve.local_adapter import _progress
print(_progress([{"wave": 1, "tickets": [{"id": "a"}]}], [])["shape"])')"
assert_eq "D2a the board shape IS the CLI phrase, upper-cased" \
          "$(printf '%s' "$CLI_SOLO" | tr '[:lower:]' '[:upper:]')" "$BOARD_SOLO"
assert_eq "D2b …and the CLI phrase is the one this round settled on" \
          "$CLI_SOLO" "a single ticket — nothing to parallelise"

# --- D4. prior_reject must not outlive the attempt it describes -------------
# Attempt 1 guard-rejected; attempt 2 produces NO file. Attempt 3 must be told
# about the no-file failure and NOT carry attempt 1's rejection under a heading
# about "your previous attempt".
repo="$(e2e_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
cat >"$repo.adapter" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
if [ "$role" = plan ]; then
  n=$(( $(grep -c '=== ROLE plan ===' "$PROMPTS") ))
  # 1: the over-corrected chain (guard-rejected) · 2: NOTHING at all · 3: chain
  case "$n" in 1|3) cp "$STUB_PLAN" "$outdir/plan.json" ;; esac
fi
exit 0
EOF
chmod +x "$repo.adapter"
run_plan_stage "$repo" "$FIX/over-corrected-plan.json"
THIRD="$(awk '/^=== ROLE plan ===$/{n++} n==3' "$PROMPT_FILE")"
assert_has "D4a attempt 3 is told about attempt 2's missing file" \
           "ended its turn WITHOUT creating the required" "$THIRD"
assert_no  "D4b …and does NOT carry attempt 1's stale rejection" \
           "YOUR PREVIOUS ATTEMPT WAS REJECTED" "$THIRD"
# …while attempt 2, which DID follow a rejection, still gets it.
SECOND="$(awk '/^=== ROLE plan ===$/{n++} n==2' "$PROMPT_FILE")"
assert_has "D4c …attempt 2, which followed the rejection, still gets it" \
           "YOUR PREVIOUS ATTEMPT WAS REJECTED" "$SECOND"

# --- D5. the UNRESOLVED note cannot state a wrong attempt count -------------
repo="$(new_repo)"; d="$(mdir "$repo")"
revision_pending "$d" "$FIX/pre-review-plan.json" "$FIX/plan-review-1.json"
OUT="$( cd "$repo" && bash "$SCRIPT" plan-save --mission test-001 \
          --plan "$FIX/over-corrected-plan.json" --final-attempt 2>&1 )"
assert_no  "D5a a hand-run --final-attempt claims no attempt count" "time(s) to" "$OUT"
assert_no  "D5b …and never says '3 time(s)' after one attempt" "3 time(s)" "$OUT"
assert_has "D5c …it says what is true on every path" "last attempt was asked to" "$OUT"

# ===========================================================================
section "PART C — the wave SHAPE at Schedule"
# ===========================================================================
sched_repo() { # plan-file -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/sch.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "schedule",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null
}
JSON
  cp "$1" "$repo/.git/lcars/missions/test-001/approved-plan.json"
  make_gh "$repo.gh"
  echo "$repo"
}
run_schedule() { # repo
  OUT="$( cd "$1" && env LCARS_GH_BIN="$1.gh" bash "$SCRIPT" schedule --mission test-001 2>&1 )"
  RC=$?
}

repo="$(sched_repo "$FIX/over-corrected-plan.json")"
run_schedule "$repo"
assert_has "11a the 14-deep chain still reports its COUNT" "into 14 wave(s)" "$OUT"
assert_has "11b …and now reports its SHAPE"  "Wave shape: 14 waves, 1 ticket each" "$OUT"
assert_has "11c …in words the captain can act on" "NO parallelism" "$OUT"

repo="$(sched_repo "$FIX/pre-review-plan.json")"
run_schedule "$repo"
assert_has "11d a plan WITH parallelism says so" "Wave shape: 6 waves, up to " "$OUT"
assert_no  "11e …and is not called serial"       "NO parallelism" "$OUT"

# A one-ticket plan has no shape to speak of and must not be called serial.
ONE="$TMPROOT/one-ticket.json"
python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))[:1]
p[0]["dependencies"] = []
open(sys.argv[2], "w").write(json.dumps(p, indent=2) + "\n")
' "$FIX/pre-review-plan.json" "$ONE"
repo="$(sched_repo "$ONE")"
run_schedule "$repo"
assert_has "11f a one-ticket plan says there is nothing to parallelise" \
           "Wave shape: a single ticket — nothing to parallelise." "$OUT"
assert_no  "11g …and is never called serial"     "NO parallelism" "$OUT"

# ===========================================================================
section "PART C — the wave SHAPE on the board (data, then the real DOM)"
# ===========================================================================
PY_SHAPE="$(cd "$REPO_ROOT/web" && python3 - <<'PY' 2>&1
import json
from lcars_serve.local_adapter import _progress
serial = [{"wave": i + 1, "tickets": [{"id": "t-%03d" % (i + 1)}]} for i in range(14)]
par = [{"wave": 1, "tickets": [{"id": "a"}]},
       {"wave": 2, "tickets": [{"id": "b"}, {"id": "c"}, {"id": "d"}]},
       {"wave": 3, "tickets": [{"id": "e"}, {"id": "f"}]}]
one = [{"wave": 1, "tickets": [{"id": "a"}, {"id": "b"}]}]
solo = [{"wave": 1, "tickets": [{"id": "a"}]}]
print(json.dumps({
    "serial": _progress(serial, []),
    "par": _progress(par, []),
    "one": _progress(one, []),
    "solo": _progress(solo, []),
    "none": _progress([], []),
}, ensure_ascii=False))
PY
)"
assert_has "12a board progress marks a 14x1 plan as serial" \
           '"shape": "14 WAVES · 1 TICKET EACH — NO PARALLELISM"' "$PY_SHAPE"
assert_has "12b …reports the peak on a parallel plan" '"shape": "3 WAVES · UP TO 3 IN PARALLEL"' "$PY_SHAPE"
assert_has "12c …and a single wave reads as fully parallel" '"1 WAVE · ALL 2 IN PARALLEL"' "$PY_SHAPE"
# The two surfaces must not describe the same plan differently: the CLI says
# "a single ticket — there is nothing to parallelise" at Schedule, so the board
# must not say "ALL 1 IN PARALLEL" beside it.
assert_has "12c2 …and a ONE-ticket plan agrees with the CLI, word for word" \
           '"A SINGLE TICKET — NOTHING TO PARALLELISE"' "$PY_SHAPE"
assert_has "12c3 …which is what the CLI says too" "a single ticket — nothing to parallelise" \
           "$(wsl 1 1 1)"
assert_has "12d …with no waves there is no shape at all"     '"shape": null' "$PY_SHAPE"
assert_has "12e …and wavesTotal/ticketsTotal are untouched"  '"wavesTotal": 14' "$PY_SHAPE"

# The node harness renders the SHIPPING board.js cardNode(). It is a STUB of a
# browser and cannot tell a painted pill from a blank card — the real-Chrome rig
# at tests/drives/browser/ is what proves it reaches the screen. This only proves
# the node is built and carries the class the CSS keys off.
if command -v node >/dev/null 2>&1; then
  card="$TMPROOT/card.json"
  cat > "$card" <<'JSON'
{ "id": "m-1", "issue": 1, "stage": "implement", "title": "Serialised plan",
  "type": "feature", "engine": "claude",
  "progress": { "wave": 1, "wavesTotal": 14, "ticketsDone": 0, "ticketsTotal": 14,
                "peakParallel": 1, "shape": "14 WAVES · 1 TICKET EACH — NO PARALLELISM",
                "label": "WAVE 1/14 · TICKET 0/14" },
  "tickets": [] }
JSON
  CARD_OUT="$(node "$REPO_ROOT/web/tests/board_card_harness.js" "$card" 2>&1)"
  assert_has "13a the card renders the shape text" "14 WAVES" "$CARD_OUT"
  assert_has "13b …in a node the serial CSS rule keys off" '"cls":"shape serial"' "$CARD_OUT"
  # …and a payload with NO shape (every pre-S178 adapter, and the GitHub
  # adapter) renders exactly as it did before.
  python3 - "$card" "$TMPROOT/card-noshape.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["progress"].pop("shape"); m["progress"].pop("peakParallel")
json.dump(m, open(sys.argv[2], "w"))
PY
  NOSHAPE_OUT="$(node "$REPO_ROOT/web/tests/board_card_harness.js" "$TMPROOT/card-noshape.json" 2>&1)"
  assert_no "13c a card with no shape renders no shape node" '"shape"' "$NOSHAPE_OUT"
else
  bad "13a node not on PATH — the card render was NOT checked"
fi

printf '\n────────────────────────────────────────────\n'
printf 'replan-overcorrection: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

# ── 2026-08-30 — THE CAPTAIN'S ANSWER REACHES THE PLANNER ──────────────────
# Measured on his own MBR mission: he answered a plan-review escalation, the
# REVIEWER was given answers.json and honoured it, and cmd_plan — the Stage that
# rewrites the tickets — was not, so it re-emitted the contradicted criterion and
# the Mission escalated again on a settled question. An infinite babysit loop.
section "the captain's answer reaches the PLANNER, not just the reviewer"

PLAN_FN="$(awk '/^cmd_plan\(\)/,/^cmd_[a-z_]*\(\)$/' "$REPO_ROOT/skills/lcars-run/run.sh" | head -200)"
case "$PLAN_FN" in
  *'$MISSION_DIR/answers.json'*) ok "cmd_plan lists answers.json among its inputs" ;;
  *) bad "cmd_plan does NOT feed answers.json — a settled question will be re-raised" ;;
esac
# S180 turned answers.json into an append-only LEDGER, so the annotation reads
# "treat them as DECIDED" (plural) rather than "it". Match the binding claim, not
# the grammatical number, so the shape can change again without a false failure.
case "$PLAN_FN" in
  *"as DECIDED"*) ok "…and tells the planner to treat the answer(s) as DECIDED" ;;
  *) bad "cmd_plan feeds the file without saying it is binding" ;;
esac
# the guard must stay conditional: a mission that never escalated has no
# answers.json and its plan prompt must be unchanged.
case "$PLAN_FN" in
  *'[ -f "$MISSION_DIR/answers.json" ]'*) ok "…only when an answer exists (no drift for a clean mission)" ;;
  *) bad "answers.json is fed unconditionally" ;;
esac
