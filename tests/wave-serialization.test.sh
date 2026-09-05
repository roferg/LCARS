#!/usr/bin/env bash
# S181 — a DISHONEST queue is not a serial plan.
#
# THE MEASUREMENT (the captain's own repo, 2026-09-03). A real 12-ticket plan was
# scheduled as 12 waves of ONE ticket each — roughly 2-3x the honest wall clock of
# the pipeline's longest Stage. `compute_waves` was not at fault: it is a correct
# layered Kahn, and tests/wave-isolation.test.sh already locks "empty dependencies
# + no infra flag ⇒ ONE wave". The ALGORITHM was fine; the INPUTS were dishonest.
#
# THE CAPTAIN'S RULING is "serialize when unsure": parallel work only on POSITIVE
# evidence of independence. A legitimately serial plan must stay serial and pass
# through untouched. Nothing here may make the planner LESS likely to isolate
# genuinely shared substrate — so every check below is either about what the
# planner is TOLD, or about a SIGNAL a reader weighs. Not one of them rejects a
# plan.
#
# The four cures under test:
#   1. the "what a dependency IS" framing reaches the FIRST plan, from ONE source
#      shared with the revision contract;
#   2. the infrastructure flag's "choose true when unsure" is calibrated with
#      NEGATIVE guidance, written as SLOT DESCRIPTIONS with nothing copyable
#      (S179: three live turns transplanted a prompt's worked example verbatim);
#   3. a single-chain graph over ≥ 6 tickets raises a NAMED SOFT signal to Plan
#      Review — never a mechanical reject, and a flagged plan still schedules;
#   4. the serial wave-shape warning NAMES ITS CAUSE, or says it cannot.
#
# Deliberately NOT the heavy tests/lcars-run.test.sh. Everything runs over run.sh's
# isolation hooks, `plan-save`, `schedule` and a stub worker adapter. NO worker is
# spawned, NO token is spent.
#
#   bash tests/wave-serialization.test.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
PLAN_MD="$REPO_ROOT/skills/lcars-run/stages/plan.md"
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

PY="${LCARS_PYTHON_BIN:-python3}"

# --- plan builders ----------------------------------------------------------
# chain_plan <file> <n>        — t-001 … t-00n, each depending on its predecessor
# flat_plan  <file> <n> [infra]— t-001 … t-00n, NO dependencies; infra=true|false
#
# Written in the CANONICAL one-field-per-line shape the fixtures use (arrays
# INLINE): run.sh's jq-free awk readers parse that shape, and a pretty-printed
# `"dependencies": [\n "t-001"\n]` would silently read as NO dependencies —
# which would make every check below pass for the wrong reason.
mk_plan() { # file  n  mode(chain|flat)  infra(true|false|omit)
  "$PY" - "$1" "$2" "$3" "$4" <<'MKPLAN'
import json, sys
path, n, mode, infra = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
rows = []
for i in range(1, n + 1):
    deps = ["t-%03d" % (i - 1)] if (mode == "chain" and i > 1) else []
    fields = [
        '    "id": "t-%03d"' % i,
        '    "title": "Ticket %d"' % i,
        '    "description": "Do the %dth piece of work."' % i,
        '    "acceptanceCriteria": %s' % json.dumps(["piece %d behaves" % i]),
        '    "estimatedReadLoc": 10',
        '    "estimatedTestLoc": 10',
        '    "estimatedNewLoc": 10',
        '    "dependencies": %s' % json.dumps(deps),
    ]
    if infra != "omit":
        fields.append('    "establishesSharedInfrastructure": %s'
                      % ("true" if infra == "true" else "false"))
    fields.append('    "rationale": "slice %d"' % i)
    rows.append("  {\n" + ",\n".join(fields) + "\n  }")
open(path, "w").write("[\n" + ",\n".join(rows) + "\n]\n")
MKPLAN
}

CHAIN12="$TMPROOT/chain12.json";  mk_plan "$CHAIN12" 12 chain false
CHAIN3="$TMPROOT/chain3.json";    mk_plan "$CHAIN3"   3 chain false
CHAIN6="$TMPROOT/chain6.json";    mk_plan "$CHAIN6"   6 chain false
FLAT12="$TMPROOT/flat12.json";    mk_plan "$FLAT12"  12 flat  false
INFRA12="$TMPROOT/infra12.json";  mk_plan "$INFRA12" 12 flat  true

# --- fixture repos ----------------------------------------------------------
make_gh() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

new_repo() { # stage  [plan-file → the stage's input artifact] -> repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t
    printf '# fixture\n' > README.md
    printf '# Context\n\nA fixture repo.\n' > CONTEXT.md
    git add -A && git commit -q -m init
    git checkout -q -b lcars/test-001 ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<JSON
{ "id": "test-001", "type": "feature", "title": "t", "stage": "$1",
  "branch": "lcars/test-001", "base": "main", "githubIssue": null }
JSON
  printf '# PRD\n\nBuild the thing.\n' > "$repo/.git/lcars/missions/test-001/prd.md"
  printf '# Validated Plan\n\n## Synthesis\nBuild it.\n' \
    > "$repo/.git/lcars/missions/test-001/validated-plan.md"
  make_gh "$repo.gh"
  echo "$repo"
}
mdir() { printf '%s/.git/lcars/missions/test-001' "$1"; }

# A stub worker adapter: records every prompt, answers `plan` from $STUB_PLAN and
# `plan-review` with a passing verdict. No CLI, no tokens.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
case "$role" in
  plan)        cp "$STUB_PLAN" "$outdir/plan.json" ;;
  plan-review) printf '{ "passed": true, "issues": [] }\n' > "$outdir/verdict.json" ;;
esac
exit 0
EOF
  chmod +x "$1"
  printf '#!/usr/bin/env bash\necho UNEXPECTED-SPAWN >&2\nexit 96\n' >"$1.worker"
  chmod +x "$1.worker"
}

run_stage() { # repo  subcommand  stub-plan
  : >"$1.prompts"
  make_adapter "$1.adapter"
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.adapter.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      PROMPTS="$1.prompts" STUB_PLAN="${3:-$CHAIN12}" \
      bash "$SCRIPT" "$2" --mission test-001 2>&1 )"
  RC=$?
  PROMPT="$(cat "$1.prompts" 2>/dev/null)"
}

run_plan_save() { # repo planfile
  OUT="$( cd "$1" && env LCARS_GH_BIN="$1.gh" bash "$SCRIPT" plan-save \
            --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
}
run_schedule() { # repo
  OUT="$( cd "$1" && env LCARS_GH_BIN="$1.gh" bash "$SCRIPT" schedule --mission test-001 2>&1 )"
  RC=$?
  WAVES="$(mdir "$1")/waves.json"
}
n_waves() { grep -c '"wave":' "$1" 2>/dev/null; }
tickets_of_wave() { awk -v want="$2" '
    /"wave":/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    /"id":/   { if (cur==want) { n=split($0,a,"\""); printf "%s ", a[4] } }
  ' "$1" | sed 's/ $//'; }

# ===========================================================================
section "PART 1 — the sibling framing reaches the FIRST plan, from ONE source"
# ===========================================================================
BLOCK="$(bash "$SCRIPT" dependency-semantics-block-test 2>&1)"

assert_has "1a the shared block states the POSITIVE rule" \
           "GENUINELY needs BUILT FIRST" "$BLOCK"
assert_has "1b …that 'comes after' is not a dependency" \
           '"Comes after" is not a dependency' "$BLOCK"
assert_has "1c …and names the SIBLING shape (same shell, no edge)" \
           "SIBLINGS" "$BLOCK"
assert_has "1d …and says a queue is the most expensive shape" \
           "most expensive shape" "$BLOCK"
# S178's balance must survive on BOTH paths: this is not "declare fewer edges".
assert_has "1e …while refusing to ask for fewer edges" \
           "This is NOT an instruction to declare FEWER dependencies" "$BLOCK"
assert_no  "1f …and never sets a wave-count target" "wave count" "$BLOCK"
assert_no  "1g …and never says minimise"            "minimis"    "$BLOCK"

# The FIRST plan (no reviewer objections, no revision token) must be told it.
repo="$(new_repo plan)"
run_stage "$repo" plan "$FIX/pre-review-plan.json"
assert_eq  "1h a first plan advances" "$RC" "0"
assert_has "1i …and its prompt now carries the dependency framing" \
           '"Comes after" is not a dependency' "$PROMPT"
assert_no  "1j …without the revision contract"  "THIS IS A REVISION" "$PROMPT"
# …exactly once. Two copies of the same prose is the drift this cure exists to
# prevent (one source of truth, two call sites).
n1="$(printf '%s\n' "$PROMPT" | grep -c 'Comes after')"
assert_eq  "1k …and says it EXACTLY once" "$n1" "1"

# A REVISION still carries it — proving the two call sites share one source.
repo="$(new_repo plan)"; d="$(mdir "$repo")"
cp "$FIX/pre-review-plan.json" "$d/plan.json"
cp "$FIX/pre-review-plan.json" "$d/plan-under-review.json"
cp "$FIX/plan-review-1.json"   "$d/plan-review-1.json"
run_stage "$repo" plan "$FIX/patched-plan.json"
assert_has "1l a revision still carries the dependency framing" \
           '"Comes after" is not a dependency' "$PROMPT"
assert_has "1m …inside its revision contract"  "THIS IS A REVISION, NOT A RE-PLAN" "$PROMPT"
assert_has "1n …and keeps S178's revision-specific balance" \
           "a missing dependency is a real defect" "$PROMPT"
n2="$(printf '%s\n' "$PROMPT" | grep -c 'Comes after')"
assert_eq  "1o …and is not duplicated on the revision path" "$n2" "1"

# ONE source of truth, asserted in the SOURCE — a copied paragraph drifts.
nsrc="$(grep -c '"Comes after" is not a dependency' "$SCRIPT")"
assert_eq  "1p the prose exists in exactly ONE place in run.sh" "$nsrc" "1"

# ===========================================================================
section "PART 2 — the infra flag's bias is calibrated with NEGATIVE guidance"
# ===========================================================================
MD="$(cat "$PLAN_MD")"
assert_has "2a a ticket adding into an ALREADY-EXISTING shell is false" \
           "already exists" "$MD"
assert_has "2b …named as the shape it is (its own view/route/component/screen)" \
           "route" "$MD"
assert_has "2c several tickets on one stylesheet is NOT, by itself, infrastructure" \
           "stylesheet" "$MD"
assert_has "2d …and that overlap is the scheduler's story, not this flag's" \
           "textual overlap" "$MD"
# FIX ROUND 1 (D-5): this check used to assert the OPPOSITE — that the "cannot
# tell ⇒ `true`" licence was SCOPED to the container/environment bullet and to
# nothing else. That is the captain's ruling inverted: "serialize when unsure"
# makes `true` the answer to a genuinely ambiguous call ANYWHERE, and a cure that
# flattens an honest chain is worse than the bug it was written for. The licence is
# general; what is scoped is `false`, which now needs a positive reading. See 7a–7e.
assert_has "2e the 'cannot tell ⇒ true' licence is GENERAL, not scoped to a bullet" \
           "The tie-breaker, and it is general" "$MD"
# The genuinely-shared-substrate side is NOT weakened — these must survive.
assert_has "2f …and the runner/config/manifest/CI list still says true" \
           "the **test runner** and its config" "$MD"
assert_has "2g …and the greenfield layout still says true" \
           "initial project/package/module/workspace layout" "$MD"
assert_has "2h …and the missed-true cost is still stated" \
           "reproduces a real, costly failure" "$MD"
# S179: the negative guidance is SLOT DESCRIPTIONS. It adds NO copyable example —
# three measured live turns transplanted a prompt's worked example verbatim onto
# an unrelated screen. The pre-existing examples (2 json fences on this file
# before this round) are not multiplied.
nfence="$(grep -c '^```json' "$PLAN_MD")"
assert_eq  "2i the negative guidance adds NO new copyable json example" "$nfence" "2"
nworked="$(grep -c 'Worked example' "$PLAN_MD")"
assert_eq  "2j …and no new worked example"  "$nworked" "1"

# ===========================================================================
section "PART 3 — the linear-chain SOFT signal (never a mechanical reject)"
# ===========================================================================
shape() { LCARS_PYTHON_BIN="$PY" bash "$SCRIPT" chain-shape-test --plan "$1" 2>&1; }

assert_eq "3a a 12-ticket single chain is detected" "$(shape "$CHAIN12")" "12"
assert_eq "3b a 6-ticket chain is at the threshold" "$(shape "$CHAIN6")"  "6"
assert_eq "3c a 3-ticket chain is NOT flagged"      "$(shape "$CHAIN3")"  ""
assert_eq "3d 12 tickets with NO dependencies are not a chain" "$(shape "$FLAT12")" ""
assert_eq "3e a real branching graph is not a chain" "$(shape "$FIX/pre-review-plan.json")" ""
assert_eq "3f the measured 14-deep queue IS a chain" "$(shape "$FIX/over-corrected-plan.json")" "14"

HINT="$(bash "$SCRIPT" chain-hint-test --plan "$CHAIN12" 2>&1)"
assert_has "3g the hint is a NAMED signal"      "dependency-queue" "$HINT"
assert_has "3h …declared ADVISORY, not a verdict" "advisory" "$HINT"
assert_has "3i …and says the harness has NOT rejected the plan" \
           "has NOT rejected this plan" "$HINT"
assert_has "3j …and that a genuinely serial plan must pass" \
           "legitimate plan" "$HINT"
assert_has "3k …and refuses to ask for an edge dropped on the signal alone" \
           "do NOT object merely because this signal fired" "$HINT"
assert_eq  "3l a 3-chain produces NO hint at all" \
           "$(bash "$SCRIPT" chain-hint-test --plan "$CHAIN3" 2>&1)" ""

# plan-save: the signal is RECORDED, and the plan still advances.
repo="$(new_repo plan)"
run_plan_save "$repo" "$CHAIN12"
assert_eq  "3m a flagged plan still SAVES (never a mechanical reject)" "$RC" "0"
assert_has "3n …and still advances to Plan Review" "Stage:  plan-review" "$OUT"
assert_has "3o …with the named signal recorded for provenance" \
           "DEPENDENCY-QUEUE SIGNAL" "$OUT"
repo="$(new_repo plan)"
run_plan_save "$repo" "$FLAT12"
assert_eq "3p an unflagged plan still saves" "$RC" "0"
assert_no "3q …and says nothing about a queue" "DEPENDENCY-QUEUE" "$OUT"
repo="$(new_repo plan)"
run_plan_save "$repo" "$CHAIN3"
assert_no "3r a 3-ticket chain is never flagged at plan-save" "DEPENDENCY-QUEUE" "$OUT"

# The reviewer's own input carries it.
repo="$(new_repo plan-review)"
cp "$CHAIN12" "$(mdir "$repo")/plan.json"
run_stage "$repo" plan-review "$CHAIN12"
assert_has "3s the Plan Review input carries the named soft objection" \
           "dependency-queue" "$PROMPT"
assert_has "3t …alongside the existing slice-pressure precedent" \
           "Slice-pressure signals" "$PROMPT"
repo="$(new_repo plan-review)"
cp "$FIX/pre-review-plan.json" "$(mdir "$repo")/plan.json"
run_stage "$repo" plan-review "$FIX/pre-review-plan.json"
assert_no  "3u a branching plan's reviewer hears nothing about a queue" \
           "dependency-queue" "$PROMPT"

# A flagged plan STILL SCHEDULES.
repo="$(new_repo schedule)"; cp "$CHAIN12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq  "3v a flagged plan still schedules" "$RC" "0"
assert_eq  "3w …into the 12 waves its own graph demands" "$(n_waves "$WAVES")" "12"

# ===========================================================================
section "PART 4 — the serial warning NAMES ITS CAUSE"
# ===========================================================================
# (i) 12 infra-true tickets: 12 isolated waves, each with a reason, and the
#     shape line blames DECLARED INFRASTRUCTURE.
repo="$(new_repo schedule)"; cp "$INFRA12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq  "4a twelve infra-true tickets make twelve waves" "$(n_waves "$WAVES")" "12"
nreason="$(grep -c '"reason":' "$WAVES")"
assert_eq  "4b …every one of them carrying a reason" "$nreason" "12"
assert_has "4c …and the shape line still says NO parallelism" "NO parallelism" "$OUT"
assert_has "4d …and NAMES declared infrastructure as the cause" \
           "CAUSE: infrastructure isolation" "$OUT"
assert_has "4e …counting the declarations it read"  "establishesSharedInfrastructure: true" "$OUT"
assert_no  "4f …and does not blame a dependency queue it cannot see" \
           "dependency queue" "$OUT"

# (ii) the 12-chain: the shape line blames the DECLARED QUEUE.
repo="$(new_repo schedule)"; cp "$CHAIN12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_has "4g a chain's shape line says NO parallelism"  "NO parallelism" "$OUT"
assert_has "4h …and NAMES the declared dependency queue" \
           "CAUSE: the plan declares a dependency queue" "$OUT"
assert_has "4i …stating the chain length it measured"     "all 12 tickets" "$OUT"
assert_no  "4j …and does not blame infrastructure it never saw" \
           "CAUSE: infrastructure isolation" "$OUT"

# (iii) neither explains it ⇒ the HONEST DEFAULT. Driven through the isolation
#       hook so the cause can be withheld without inventing a plan that has none.
wsl() { LCARS_WS_NT="$1" LCARS_WS_NW="$2" LCARS_WS_PEAK="$3" LCARS_WS_CAUSE="${4:-}" \
          bash "$SCRIPT" wave-shape-line-test 2>&1; }
D="$(wsl 12 12 1)"
assert_has "4k with no attributable cause it still says NO parallelism" "NO parallelism" "$D"
assert_no  "4l …and invents NO cause (not infrastructure)" "CAUSE: infrastructure" "$D"
assert_no  "4m …and invents NO cause (not a queue)"        "CAUSE: the plan declares" "$D"
assert_has "4n …and SAYS it could not attribute the shape" "could not attribute" "$D"
assert_has "4o a queue cause reaches the line"  "dependency queue" "$(wsl 12 12 1 'queue:12')"
assert_has "4p an infra cause reaches the line" "infrastructure isolation" "$(wsl 12 12 1 'infra:12:12')"
# The non-serial branches are untouched by the cause argument.
assert_has "4q a parallel plan still reports its peak" "up to 5 ticket(s)" "$(wsl 12 4 5 'queue:12')"
assert_eq  "4r an unreadable wavemap still says NOTHING" "$(wsl 4 2 0 'queue:4')" ""

# ===========================================================================
section "PART 5 — the wave MATH is unchanged (the algorithm was never at fault)"
# ===========================================================================
repo="$(new_repo schedule)"; cp "$FLAT12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq "5a twelve independent tickets are still ONE wave" "$(n_waves "$WAVES")" "1"
assert_has "5b …reported as fully parallel" "1 wave of 12 ticket(s)" "$OUT"
assert_no  "5c …and never flagged as a queue" "DEPENDENCY-QUEUE" "$OUT"

# The MIXED graph — real edges AND an infra ticket. Wave math unchanged, no flag.
MIXED="$TMPROOT/mixed.json"
"$PY" - "$FIX/pre-review-plan.json" "$MIXED" <<'MIX'
import json, sys
p = json.load(open(sys.argv[1]))
for t in p:
    t["establishesSharedInfrastructure"] = (t["id"] == "t-001")
open(sys.argv[2], "w").write(json.dumps(p, indent=2) + "\n")
MIX
repo="$(new_repo schedule)"; cp "$MIXED" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq  "5d a mixed graph still schedules"  "$RC" "0"
assert_eq  "5e …with t-001 isolated in wave 1" "$(tickets_of_wave "$WAVES" 1)" "t-001"
assert_no  "5f …and no chain flag"             "DEPENDENCY-QUEUE" "$OUT"
assert_no  "5g …and no serial warning"         "NO parallelism" "$OUT"
assert_eq  "5h …and the chain detector agrees" "$(shape "$MIXED")" ""

# ===========================================================================
section "PART 6 — ONE reader. A pretty-printed plan is the SAME plan (D-1/D-2)"
# ===========================================================================
# D-1 (INHERITED, reproduces on HEAD). parse_plan_table read `dependencies` only
# off the line the key appeared on. A plan pretty-printed by json.dump(indent=2)
# puts the ids on the FOLLOWING lines, so Schedule read NO dependencies at all and
# built every ticket in ONE blind wave — the S156 blind-sibling class, arrived at
# by silently discarding a real graph. S174 had already solved this exact shape one
# function above for acceptanceCriteria (the `in_ac` accumulator); this mirrors it.
#
# D-2. Two readers over one plan gave two answers: plan_chain_shape (python) said
# "12 waves of ONE ticket" while Schedule (awk) built 1 fully-parallel wave, and
# that false premise reached the Plan Review worker verbatim. Fixing D-1 removes
# today's divergence; the DURABLE hazard is two readers, so the signal now reads
# the graph through the SAME reader Schedule uses and these checks pin the two
# views in agreement over every array shape a worker can emit.
pretty() { # src dst — the same plan, json.dump(indent=2)
  "$PY" -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), indent=2)' "$1" "$2"
}
deps_view() { LCARS_PYTHON_BIN="$PY" bash "$SCRIPT" plan-deps-test --plan "$1" 2>&1; }

P_CHAIN12="$TMPROOT/p-chain12.json"; pretty "$CHAIN12" "$P_CHAIN12"
P_FLAT12="$TMPROOT/p-flat12.json";   pretty "$FLAT12"  "$P_FLAT12"
P_BRANCH="$TMPROOT/p-branch.json";   pretty "$FIX/pre-review-plan.json" "$P_BRANCH"

# (i) the reader itself: a multi-line array is READ, and reads IDENTICALLY to the
#     inline array it was pretty-printed from.
assert_has "6a a pretty-printed dependencies array is read at all" \
           "t-002	t-001" "$(deps_view "$P_CHAIN12")"
assert_eq  "6b …identically to the inline shape of the same plan" \
           "$(deps_view "$P_CHAIN12")" "$(deps_view "$CHAIN12")"
assert_eq  "6c …and an EMPTY array still reads as no dependencies (both shapes)" \
           "$(deps_view "$P_FLAT12")" "$(deps_view "$FLAT12")"
assert_eq  "6d …and a real BRANCHING graph survives the round trip" \
           "$(deps_view "$P_BRANCH")" "$(deps_view "$FIX/pre-review-plan.json")"

# (ii) the two views AGREE — the chain signal and the graph Schedule will honour.
assert_eq "6e the chain signal sees the pretty-printed chain" "$(shape "$P_CHAIN12")" "12"
assert_eq "6f …and agrees with the inline shape of the same plan" \
          "$(shape "$P_CHAIN12")" "$(shape "$CHAIN12")"
assert_eq "6g …flat stays unflagged in both shapes" "$(shape "$P_FLAT12")" "$(shape "$FLAT12")"
assert_eq "6h …branching stays unflagged in both shapes" \
          "$(shape "$P_BRANCH")" "$(shape "$FIX/pre-review-plan.json")"

# (iii) THE PIN: if the signal says N waves, real Schedule must build N waves.
waves_for() { # plan -> wave count Schedule actually produced
  local r; r="$(new_repo schedule)"; cp "$1" "$(mdir "$r")/approved-plan.json"
  run_schedule "$r"; n_waves "$WAVES"
}
assert_eq "6i a pretty chain schedules into the 12 waves its graph demands" \
          "$(waves_for "$P_CHAIN12")" "12"
assert_eq "6j …the same count the signal predicted" "$(waves_for "$P_CHAIN12")" "$(shape "$P_CHAIN12")"
assert_eq "6k inline and pretty forms of one plan schedule identically (chain)" \
          "$(waves_for "$P_CHAIN12")" "$(waves_for "$CHAIN12")"
assert_eq "6l …(flat: still one wave, both shapes)" \
          "$(waves_for "$P_FLAT12")" "$(waves_for "$FLAT12")"
assert_eq "6m …(branching: the same layered answer, both shapes)" \
          "$(waves_for "$P_BRANCH")" "$(waves_for "$FIX/pre-review-plan.json")"
# …and the branching plan is NOT one blind wave, which is what the bug produced.
assert_eq "6n a pretty branching graph is not flattened into one wave" \
          "$(waves_for "$P_BRANCH")" "6"

# (iv) the signal the REVIEWER is handed can no longer contradict Schedule.
repo="$(new_repo plan)"
run_plan_save "$repo" "$P_CHAIN12"
assert_has "6o a pretty-printed queue raises the signal at plan-save" \
           "DEPENDENCY-QUEUE SIGNAL" "$OUT"
repo="$(new_repo plan)"
run_plan_save "$repo" "$P_FLAT12"
assert_no  "6p …and a pretty-printed flat plan still raises none" "DEPENDENCY-QUEUE" "$OUT"

# ===========================================================================
section "PART 6b — the serial CAUSE matches what was MEASURED (D-3/D-4)"
# ===========================================================================
# D-3. With 12 tickets that declare NOTHING but whose text names a config file,
# the line said "0 of them declared establishesSharedInfrastructure: true" and
# then blamed "its flag" in the same sentence. With no declaration there is no
# flag; declared and inferred are DIFFERENT repairs and must read differently.
D_ALL="$(wsl 12 12 1 'infra:12:12')"
D_NONE="$(wsl 12 12 1 'infra:12:0')"
D_SOME="$(wsl 12 12 1 'infra:12:5')"
assert_has "6q an ALL-DECLARED run blames the declaration" \
           "the declared flag on that ticket" "$D_ALL"
assert_no  "6r …and does not send the captain to the ticket text" \
           "no flag to clear" "$D_ALL"
assert_has "6s a NOTHING-DECLARED run says no ticket declared the field" \
           "NO ticket declared the field" "$D_NONE"
assert_has "6t …and says there is no flag to clear" "no flag to clear" "$D_NONE"
assert_no  "6u …and never blames a flag that does not exist" \
           "the declared flag on that ticket" "$D_NONE"
assert_has "6v a MIXED run names both repairs" "different repairs" "$D_SOME"
assert_has "6w …counting the inferred ones it actually measured" "7 were inferred" "$D_SOME"

# D-4. Both mechanisms present ⇒ name BOTH. Fixing only one does not widen the
# plan, and the old code short-circuited on infra and never looked at the chain.
D_BOTH="$(wsl 12 12 1 'both:12:12:12')"
assert_has "6x both causes present ⇒ infrastructure isolation is named" \
           "infrastructure isolation" "$D_BOTH"
assert_has "6y …and the dependency queue is named too" "dependency queue" "$D_BOTH"
assert_has "6z …and it says fixing ONE of them will not widen the plan" \
           "Repairing either one ALONE will not widen this plan" "$D_BOTH"

# End to end: a plan that is a 12-chain AND all-infra-true.
BOTH12="$TMPROOT/both12.json"; mk_plan "$BOTH12" 12 chain true
repo="$(new_repo schedule)"; cp "$BOTH12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq  "6A a both-causes plan still schedules" "$RC" "0"
assert_has "6B …and the readout names infrastructure isolation" \
           "infrastructure isolation" "$OUT"
assert_has "6C …and names the dependency queue in the same line" \
           "dependency queue" "$OUT"
assert_has "6D …and warns that one repair alone is not enough" \
           "will not widen this plan" "$OUT"
# The single-cause readouts are UNCHANGED — no cause is ever invented.
repo="$(new_repo schedule)"; cp "$INFRA12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_no  "6E an infra-only plan still never mentions a queue" "dependency queue" "$OUT"
repo="$(new_repo schedule)"; cp "$CHAIN12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_no  "6F a queue-only plan still never mentions infrastructure isolation" \
           "infrastructure isolation" "$OUT"

# ===========================================================================
section "PART 7 — the guidance obeys 'serialize when unsure' (D-5/D-6)"
# ===========================================================================
MD="$(cat "$PLAN_MD")"
# D-5.1 — a planner writing the first ticket of a greenfield plan CANNOT name its
# future consumers. "If you cannot name both, it is false" turned that into a
# false, which inverts the captain's ruling in the de-serializing direction.
assert_no  "7a un-nameable consumers no longer force a false" \
           "If you cannot name both, it is \`false\`" "$MD"
assert_no  "7b …and the tie-breaker is no longer scoped to one bullet" \
           "applies to that bullet and to nothing else" "$MD"
assert_has "7c the general tie-breaker IS 'true' — serialize when unsure" \
           "the answer is \`true\`" "$MD"
assert_has "7d …stated as the ruling it is, not a bullet's footnote" \
           "serialise when unsure" "$MD"
assert_has "7e …and a \`false\` requires POSITIVE recognition, not mere doubt" \
           "positively recognise" "$MD"
# D-5.2 — "a config each ticket adds a line to" ⇒ false sat directly under a list
# saying the build/compiler config and the test runner config are true, on exactly
# the file class S156's ground-truth failure was about.
assert_no  "7f the false-list no longer contradicts the true-list on configs" \
           "a config each ticket adds a line to" "$MD"
assert_has "7g …and says outright which list wins where they overlap" \
           "the list above wins" "$MD"
# The correct, evidence-backed negative guidance SURVIVES.
assert_has "7h a ticket adding into an ALREADY-EXISTING shell is still false" \
           "already exists" "$MD"
assert_has "7i …and one ordinary stylesheet is still not, by itself, substrate" \
           "stylesheet" "$MD"
# S179 again: still nothing copyable.
assert_eq  "7j still no new copyable json example" "$(grep -c '^```json' "$PLAN_MD")" "2"
assert_eq  "7k …and still exactly one worked example" "$(grep -c 'Worked example' "$PLAN_MD")" "1"

# D-6 — the SECOND measured rationale. Draw 203 chained on FILE CONTENTION
# ("both edit the shared sections array and stylesheet, which blind parallel
# siblings would clobber"). The shared block did not address it, and it sounds
# like a safety argument, so a planner can still reach for it. The factual answer
# is that the harness ALREADY composes that case (replay in plan order, rebuild on
# tip on conflict) — and pays for it only where a conflict happens.
assert_has "7l the block addresses two tickets touching the SAME FILE" \
           "same file" "$BLOCK"
assert_has "7m …and says the harness already composes those edits" \
           "already composes" "$BLOCK"
assert_has "7n …naming the mechanism (plan order, rebuilt on top on a conflict)" \
           "rebuilt on top of the first" "$BLOCK"
assert_has "7o …and that the cost is paid ONLY where a conflict happens" \
           "only where a conflict" "$BLOCK"
# NOT an overreach into S156: creating substrate others build on is STILL an edge.
assert_has "7p …while a ticket that CREATES what another builds on is still an edge" \
           "is a real edge and must be declared" "$BLOCK"
# S178's balance and S179's no-template rule survive the addition.
assert_has "7q …and it still refuses to ask for fewer edges" \
           "This is NOT an instruction to declare FEWER dependencies" "$BLOCK"
assert_no  "7r …and still sets no wave-count target" "wave count" "$BLOCK"
assert_no  "7s …and still never says minimise"       "minimis"    "$BLOCK"
assert_eq  "7t …and the prose is still in exactly ONE place in run.sh" \
           "$(grep -c '"Comes after" is not a dependency' "$SCRIPT")" "1"

# ===========================================================================
section "PART 8 — the REVIEWER reads the same definition as the planner (D-7)"
# ===========================================================================
# MEASURED, live Copilot, builder draw 302. The reviewer objected about a shared
# `sections` registry and offered the planner two routes verbatim: "either
# establish the composed registry in one foundational ticket the section tickets
# depend on, OR CHAIN THE SECTION TICKETS VIA DEPENDENCIES, so concurrent blind
# appends to the same array do not collide." That is the reviewer recommending
# the shared-file serialization the PLANNER has just been told is not an edge —
# and the planner is now insulated from that pressure while the reviewer is not.
# `dependency_semantics_block` was fed at TWO of the three surfaces that argue
# about edges. It is now fed at all three, from the one function.
#
# THE RISK RUNS THE OTHER WAY and these checks guard it: the reviewer's job
# includes demanding a MISSING edge, and the same drive showed it doing that job
# well. Nothing here may make it likelier to wave a real edge through.
repo="$(new_repo plan-review)"
cp "$FIX/pre-review-plan.json" "$(mdir "$repo")/plan.json"
run_stage "$repo" plan-review "$FIX/pre-review-plan.json"
RV_PROMPT="$PROMPT"
assert_has "8a the reviewer's prompt carries the dependency framing" \
           '"Comes after" is not a dependency' "$RV_PROMPT"
assert_has "8b …including the SHARED-FILE paragraph its measured objection contradicted" \
           "already composes" "$RV_PROMPT"
assert_has "8c …and S178's balance reaches the reviewer intact" \
           "This is NOT an instruction to declare FEWER dependencies" "$RV_PROMPT"
assert_has "8d …and a ticket that CREATES substrate is still a REAL edge" \
           "is a real edge and must be declared" "$RV_PROMPT"
# A reviewer-specific FRAME, because the block is written to the ticket AUTHOR.
# It must say out loud that the definition cuts BOTH ways.
assert_has "8e …framed for a reviewer, cutting BOTH ways" \
           "IN BOTH DIRECTIONS" "$RV_PROMPT"
assert_has "8f …with a MISSING edge named as the worse defect to object to" \
           "undeclared is the WORSE" "$RV_PROMPT"
# ONE copy per prompt — the property 1k/1o pin on the planner's side.
nrv="$(printf '%s\n' "$RV_PROMPT" | grep -c 'Comes after')"
assert_eq  "8g …exactly once" "$nrv" "1"
# NO NEW DE-SERIALIZING PRESSURE. The framing is not a queue verdict: a branching
# plan's reviewer still hears no queue signal at all, and no wave-count target is
# ever set for it.
assert_no  "8h a branching plan's reviewer still hears no queue signal" \
           "dependency-queue" "$RV_PROMPT"
assert_no  "8i …and is never given a wave-count target" "wave count" "$RV_PROMPT"
assert_no  "8j …and is never told to minimise anything" "minimis" "$RV_PROMPT"
# The independence guarantee is untouched: still tickets only, never the brief.
assert_no  "8k …and the reviewer still never receives the PRD" "/prd.md" "$RV_PROMPT"
assert_has "8l …its blindness to the brief stated as before" \
           "you carry no planning context" "$RV_PROMPT"
# ONE SOURCE, now THREE call sites — still one copy of the prose in run.sh.
assert_eq  "8m the prose is STILL in exactly ONE place in run.sh" \
           "$(grep -c '"Comes after" is not a dependency' "$SCRIPT")" "1"

# ===========================================================================
section "PART 9 — the queue detector reads the waves SCHEDULE will build (D-8)"
# ===========================================================================
# MEASURED, serial draw 322. A genuine 12-wave queue whose t-012 (an orchestrator)
# depended on ALL eleven predecessors raised NO signal, and the serial warning
# fell through to "could not attribute this shape". Draw 321 — the SAME brief, the
# same 12 waves, a pure chain — was named correctly. The old predicate bailed on
# `len(deps) != 1` for any ticket, so a fan-in tail was invisible.
#
# The cure applies THIS session's own D-2 lesson. D-2 was a false claim caused by
# the signal computing the shape with a DIFFERENT reader than Schedule used. The
# queue condition is no longer a hand-matched graph shape at all: it is the wave
# layout `compute_waves` itself produces from the declared dependencies — all one
# ticket wide, over N >= 6. It catches the integrator tail, catches every other
# 1-wide shape, and by construction cannot disagree with what Schedule builds.
#
# mk_graph writes an explicit graph in the SAME canonical inline-array shape
# mk_plan uses (a pretty-printed array would read as NO dependencies — 6a–6d).
mk_graph() { # file  '[["t-001",[]],["t-002",["t-001"]], …]'
  "$PY" - "$1" "$2" <<'MKGRAPH'
import json, sys
path, spec = sys.argv[1], json.loads(sys.argv[2])
rows = []
for n, (tid, deps) in enumerate(spec, 1):
    rows.append("  {\n" + ",\n".join([
        '    "id": "%s"' % tid,
        '    "title": "Ticket %d"' % n,
        '    "description": "Do the %dth piece of work."' % n,
        '    "acceptanceCriteria": %s' % json.dumps(["piece %d behaves" % n]),
        '    "estimatedReadLoc": 10',
        '    "estimatedTestLoc": 10',
        '    "estimatedNewLoc": 10',
        '    "dependencies": %s' % json.dumps(deps),
        '    "establishesSharedInfrastructure": false',
        '    "rationale": "slice %d"' % n,
    ]) + "\n  }")
open(path, "w").write("[\n" + ",\n".join(rows) + "\n]\n")
MKGRAPH
}

# The measured shape: an 11-chain whose 12th ticket fans in on all eleven.
INTEG12="$TMPROOT/integrator12.json"
"$PY" -c '
import json,sys
n=12
spec=[("t-001",[])]
for i in range(2,n): spec.append(("t-%03d"%i,["t-%03d"%(i-1)]))
spec.append(("t-%03d"%n,["t-%03d"%i for i in range(1,n)]))
print(json.dumps(spec))' >"$TMPROOT/integ12.spec"
mk_graph "$INTEG12" "$(cat "$TMPROOT/integ12.spec")"

# The CONTROL that must stay wide: eleven independent tickets and one integrator.
WIDE12="$TMPROOT/wide12.json"
"$PY" -c '
import json
spec=[("t-%03d"%i,[]) for i in range(1,12)]
spec.append(("t-012",["t-%03d"%i for i in range(1,12)]))
print(json.dumps(spec))' >"$TMPROOT/wide12.spec"
mk_graph "$WIDE12" "$(cat "$TMPROOT/wide12.spec")"

# Below the threshold: a 4-chain with an integrator tail — 5 waves of one, N<6.
INTEG5="$TMPROOT/integrator5.json"
"$PY" -c '
import json
spec=[("t-001",[])]
for i in range(2,5): spec.append(("t-%03d"%i,["t-%03d"%(i-1)]))
spec.append(("t-005",["t-%03d"%i for i in range(1,5)]))
print(json.dumps(spec))' >"$TMPROOT/integ5.spec"
mk_graph "$INTEG5" "$(cat "$TMPROOT/integ5.spec")"

# (i) THE DEFECT.
assert_eq "9a an integrator tail on a chain IS a queue" "$(shape "$INTEG12")" "12"
# (ii) THE PIN — the signal's number is the wave count Schedule really builds.
assert_eq "9b …and Schedule builds exactly that many waves" "$(waves_for "$INTEG12")" "12"
assert_eq "9c …the same number the signal predicted" \
          "$(waves_for "$INTEG12")" "$(shape "$INTEG12")"
# (iii) it reaches the surfaces that argue about it.
repo="$(new_repo plan)"
run_plan_save "$repo" "$INTEG12"
assert_eq  "9d an integrator-tail queue still SAVES" "$RC" "0"
assert_has "9e …and raises the named signal at plan-save" "DEPENDENCY-QUEUE SIGNAL" "$OUT"
repo="$(new_repo plan-review)"
cp "$INTEG12" "$(mdir "$repo")/plan.json"
run_stage "$repo" plan-review "$INTEG12"
assert_has "9f …and the reviewer is handed it" "dependency-queue" "$PROMPT"
repo="$(new_repo schedule)"; cp "$INTEG12" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_has "9g …and the serial warning NAMES the queue instead of giving up" \
           "CAUSE: the plan declares a dependency queue" "$OUT"
assert_no  "9h …no longer falling through to 'could not attribute'" \
           "could not attribute" "$OUT"

# (iv) THE CONTROLS — nothing genuinely parallel is newly flagged.
assert_eq "9i eleven independent tickets + an integrator are NOT a queue" \
          "$(shape "$WIDE12")" ""
assert_eq "9j …and still schedule into 2 waves" "$(waves_for "$WIDE12")" "2"
assert_eq "9k a 5-ticket integrator is below the N>=6 threshold" "$(shape "$INTEG5")" ""
assert_eq "9l a real branching graph is still not a queue" \
          "$(shape "$FIX/pre-review-plan.json")" ""
assert_eq "9m twelve independent tickets are still not a queue" "$(shape "$FLAT12")" ""
# INFRA isolation is NOT a dependency queue. The shape cause must stay separable
# (6E/6F) — the detector reads the DECLARED GRAPH's wave layout, and an all-infra
# plan with no edges has a one-wave graph.
assert_eq "9n twelve infra-true tickets with NO edges are not a queue" \
          "$(shape "$INFRA12")" ""

# (v) FAIL-SILENT, ALWAYS. The round-1 tester proved this across malformed plans;
# it is pinned here so the rewrite cannot lose it. A signal that can fail a plan
# would not be a signal: every one of these must print NOTHING and exit 0.
shape_rc() { LCARS_PYTHON_BIN="$PY" bash "$SCRIPT" chain-shape-test --plan "$1" >/dev/null 2>&1; echo $?; }
CYCLE="$TMPROOT/cycle.json"
"$PY" -c '
import json
spec=[("t-001",["t-002"]),("t-002",["t-001"])]
for i in range(3,7): spec.append(("t-%03d"%i,["t-%03d"%(i-1)]))
print(json.dumps(spec))' >"$TMPROOT/cycle.spec"
mk_graph "$CYCLE" "$(cat "$TMPROOT/cycle.spec")"
DANGLE="$TMPROOT/dangle.json"
"$PY" -c '
import json
spec=[("t-001",["t-999"])]
for i in range(2,7): spec.append(("t-%03d"%i,["t-%03d"%(i-1)]))
print(json.dumps(spec))' >"$TMPROOT/dangle.spec"
mk_graph "$DANGLE" "$(cat "$TMPROOT/dangle.spec")"
DUPE="$TMPROOT/dupe.json"
"$PY" -c '
import json
spec=[("t-001",[]),("t-002",["t-001"]),("t-003",["t-002"]),
      ("t-003",["t-002"]),("t-005",["t-003"]),("t-006",["t-005"])]
print(json.dumps(spec))' >"$TMPROOT/dupe.spec"
mk_graph "$DUPE" "$(cat "$TMPROOT/dupe.spec")"
STRDEP="$TMPROOT/strdep.json"
"$PY" -c '
import re,sys
src=open(sys.argv[1]).read()
open(sys.argv[2],"w").write(src.replace("\"dependencies\": [\"t-001\"]","\"dependencies\": \"t-001\""))' \
  "$CHAIN12" "$STRDEP"
WRAP="$TMPROOT/wrapped.json"
"$PY" -c '
import json,sys
json.dump({"tickets": json.load(open(sys.argv[1]))}, open(sys.argv[2],"w"), indent=2)' \
  "$CHAIN12" "$WRAP"
EMPTY="$TMPROOT/empty.json"; : >"$EMPTY"
GARBAGE="$TMPROOT/garbage.json"; printf 'not json at all {{{\n' >"$GARBAGE"
MISSING="$TMPROOT/does-not-exist.json"

for f in CYCLE DANGLE DUPE STRDEP EMPTY GARBAGE MISSING; do
  eval "p=\$$f"
  assert_eq "9o[$f] a malformed plan says NOTHING" "$(shape "$p")" ""
  assert_eq "9p[$f] …and NEVER exits nonzero"      "$(shape_rc "$p")" "0"
done
# The WRAPPER object is the one that is NOT rubble: `{"tickets": [ … ]}` parses to
# the SAME twelve tickets under parse_plan_table, which is the reader Schedule
# uses, so the honest answer is the one Schedule would act on — not silence. The
# only invariant here is the one that always holds: it never exits nonzero.
assert_eq "9o[WRAP] a wrapped plan answers what SCHEDULE would read" \
          "$(shape "$WRAP")" "$(waves_for "$WRAP")"
assert_eq "9p[WRAP] …and NEVER exits nonzero" "$(shape_rc "$WRAP")" "0"
# A cycle still stops SCHEDULE (fail-closed there) — the SIGNAL going quiet must
# not have made the real gate quiet too.
repo="$(new_repo schedule)"; cp "$CYCLE" "$(mdir "$repo")/approved-plan.json"
run_schedule "$repo"
assert_eq "9q a dependency cycle still fails Schedule" "$RC" "1"

# (vi) NO python. The detector is now parse_plan_table + compute_waves, both awk,
# so the "absent python3" degenerate case cannot even arise.
NOPY="$(LCARS_PYTHON_BIN=/nonexistent/python3 bash "$SCRIPT" chain-shape-test --plan "$CHAIN12" 2>/dev/null)"
assert_eq "9r the detector needs no python at all" "$NOPY" "12"
NOPY2="$(LCARS_PYTHON_BIN=/nonexistent/python3 bash "$SCRIPT" chain-shape-test --plan "$INTEG12" 2>/dev/null)"
assert_eq "9s …on the integrator tail too" "$NOPY2" "12"

echo
printf 'wave-serialization: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
