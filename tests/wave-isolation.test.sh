#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's Schedule wave builder — infrastructure-ticket
# isolation (Session 156).
#
# Ground truth (live mission lcars-20260727-001, 2026-07-27): wave 1 held BOTH
# t-001 (Vite + React + TS scaffold) and t-012 (docs + a vitest suite), because
# t-012 declared no CODE dependency on t-001 — but it depended totally on the
# test infrastructure t-001 was creating. Siblings in a wave are blind to each
# other by design, so t-012 authored a test against a base with no Vite config;
# t-001's vite.config then broke that test file permanently, and eleven more
# tickets built on top before anything noticed.
#
# The prevention under test: a ticket that ESTABLISHES shared build/test
# infrastructure rides ALONE in its wave, and every ticket after it in plan order
# lands in a LATER wave. The classification is DECLARED by the Plan worker
# (`establishesSharedInfrastructure`) and only guessed from prose when the field
# is absent — so this file has two kinds of test: wave-layout behaviour driven
# through the REAL `run.sh schedule`, and a MEASURED accuracy corpus for the
# heuristic backstop (both corpora are the real false positives / false negatives
# an adversarial tester found against the first, prose-only classifier).
#
# This file is deliberately NOT the heavy tests/lcars-run.test.sh (which spawns
# real billable workers). It stands up minimal LOCAL-ONLY missions (no
# githubIssue → gh_relabel and sub-issue creation are no-ops) and drives the REAL
# `run.sh schedule` subcommand. Runs in about a second, zero model calls.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
RENDER_LIB="$REPO_ROOT/skills/lcars-status/render.sh"
RESOLVE_LOGS="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"
WEB_DIR="$REPO_ROOT/web"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { # desc  test-expression…
  local desc="$1"; shift
  if eval "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# --- fixture: a fresh repo with one mission parked at stage "schedule" -------
# Local-only (no githubIssue) so Schedule opens no sub-issues and relabels
# nothing — the wave MATH is what's under test.
new_mission() { # plan-json-file -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "schedule" }
JSON
  cp "$1" "$repo/.git/lcars/missions/test-001/approved-plan.json"
  echo "$repo"
}

run_schedule() { # repo -> sets RC + OUT + WAVES
  OUT="$( cd "$1" && bash "$SCRIPT" schedule --mission test-001 2>&1 )"
  RC=$?
  WAVES="$1/.git/lcars/missions/test-001/waves.json"
}

# The wave a ticket landed in (jq-free, same idea as lcars-run.test.sh's wave_of).
wave_of() { # waves.json ticket-id
  awk -v want="$2" '
    /"wave":/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    $0 ~ ("\"id\": \"" want "\"") { print cur; exit }
  ' "$1"
}
# Space-separated ticket ids of a wave, in emitted order.
tickets_of_wave() { # waves.json wave-number
  awk -v want="$2" '
    /"wave":/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    /"id":/   { if (cur==want) { n=split($0,a,"\""); printf "%s ", a[4] } }
  ' "$1" | sed 's/ $//'
}
n_waves() { grep -c '"wave":' "$1"; }

ticket() { # id title description criteria deps-json [extra-json-field]
  cat <<JSON
  {
    "id": "$1",
    "title": "$2",
    "description": "$3",
    "acceptanceCriteria": ["$4"],
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": $5,${6:+
    $6,}
    "rationale": "r"
  }
JSON
}

# ============================================================================
# (a) THE GROUND-TRUTH SHAPE — scaffold + docs-with-tests, no declared dependency
#     between them. Pre-S156: ONE wave holding both (the failure). Required: TWO
#     waves, t-001 alone in wave 1.
# ============================================================================
PLAN_GROUND="$TMPROOT/ground.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite + React + TypeScript app" \
    "Create the project scaffold — package.json, vite.config.ts, tsconfig.json and the Vitest wiring." \
    "the dev server boots and the test runner runs" "[]" \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-012 "Author the ADR and backlog docs" \
    "Write docs/adr/0001-record-architecture-decisions.md and docs/backlog.md, plus a suite asserting each doc exists." \
    "tests/docs-artifacts.test.ts asserts every ADR and the backlog exist" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_GROUND"

repo="$(new_mission "$PLAN_GROUND")"; run_schedule "$repo"
check "a. schedule exits 0 on the ground-truth plan"   "[ '$RC' -eq 0 ]"
check "a. writes waves.json"                           "[ -f '$WAVES' ]"
gw="$(n_waves "$WAVES" 2>/dev/null)"
check "a. scaffold + docs produce TWO waves, not one"  "[ '$gw' = '2' ]"
check "a. t-001 (infrastructure) is ALONE in wave 1" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ]"
check "a. t-012 is pushed into wave 2" \
  "[ \"\$(wave_of '$WAVES' t-012)\" = '2' ]"
GROUND_OUT="$OUT"
GROUND_WAVES="$WAVES"

# ============================================================================
# (d) THE REASON — waves.json AND the readout explain the one-ticket wave, and
#     say WHICH mechanism decided it (declared fact vs heuristic inference).
# ============================================================================
check "d. waves.json carries a reason on the isolated wave" \
  "grep -q '\"reason\":' '$GROUND_WAVES'"
check "d. the reason names the ticket" \
  "grep '\"reason\":' '$GROUND_WAVES' | grep -q 't-001'"
check "d. a DECLARED flag is reported as a declaration, not a guess" \
  "grep '\"reason\":' '$GROUND_WAVES' | grep -q 'declares establishesSharedInfrastructure: true'"
check "d. a declared reason never claims to have inferred anything" \
  "! grep '\"reason\":' '$GROUND_WAVES' | grep -qi 'inferred'"
check "d. the reason says WHY it is alone" \
  "grep '\"reason\":' '$GROUND_WAVES' | grep -q 'isolated into a wave of its own so later tickets build against it'"
check "d. the readout names the isolated wave" \
  "printf '%s' \"\$GROUND_OUT\" | grep -q 'wave 1'"
check "d. the readout carries the same reason" \
  "printf '%s' \"\$GROUND_OUT\" | grep -q 'declares establishesSharedInfrastructure: true'"
check "d. the readout counts the isolation" \
  "printf '%s' \"\$GROUND_OUT\" | grep -qi 'isolat'"

# --- the same plan with the flag ABSENT: the backstop fires, and SAYS SO -----
PLAN_GROUND_UNDECLARED="$TMPROOT/ground-undeclared.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite + React + TypeScript app" \
    "Create the project scaffold — package.json, vite.config.ts, tsconfig.json and the Vitest wiring." \
    "the dev server boots and the test runner runs" "[]"
  echo "  ,"
  ticket t-012 "Author the ADR and backlog docs" \
    "Write docs/adr/0001-record-architecture-decisions.md and docs/backlog.md, plus a suite asserting each doc exists." \
    "tests/docs-artifacts.test.ts asserts every ADR and the backlog exist" "[]"
  echo "]"
} > "$PLAN_GROUND_UNDECLARED"
repoU="$(new_mission "$PLAN_GROUND_UNDECLARED")"; run_schedule "$repoU"
check "d. an UNDECLARED plan still isolates via the backstop" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ] && [ \"\$(wave_of '$WAVES' t-012)\" = '2' ]"
check "d. an inferred reason is worded as an INFERENCE, not a fact" \
  "grep '\"reason\":' '$WAVES' | grep -q 'INFERRED shared build/test infrastructure because its text changes a shared config file'"
check "d. an inferred reason names the missing declaration" \
  "grep '\"reason\":' '$WAVES' | grep -q 'has no establishesSharedInfrastructure flag'"
check "d. an inferred reason names the CONFIG FILE it matched (not a prose fragment)" \
  "grep '\"reason\":' '$WAVES' | grep -q '(package.json)'"
RWAVES="$WAVES"

# ============================================================================
# DECLARED BEATS PROSE — the field is the mechanism, the prose is the backstop.
# ============================================================================
PLAN_DECL_FALSE="$TMPROOT/decl-false.json"
{
  echo "["
  ticket t-001 "Add the version footer" \
    "Render the version from package.json in the footer; create the tsconfig path alias for it." \
    "the footer shows the version" "[]" '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-002 "Add the metrics list" \
    "Render each metric row from the store." "rows render" "[]"
  echo "]"
} > "$PLAN_DECL_FALSE"
repo="$(new_mission "$PLAN_DECL_FALSE")"; run_schedule "$repo"
check "decl. establishesSharedInfrastructure:false is OBEYED over screaming prose" \
  "[ \"\$(n_waves '$WAVES')\" = '1' ]"
check "decl. …and emits no reason" "! grep -q 'reason' '$WAVES'"

PLAN_DECL_TRUE="$TMPROOT/decl-true.json"
{
  echo "["
  ticket t-001 "Add the metrics list" \
    "Render each metric row from the store." "rows render" "[]" \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-002 "Add the team filter" \
    "Filter rows by team." "filtering works" "[]"
  echo "]"
} > "$PLAN_DECL_TRUE"
repo="$(new_mission "$PLAN_DECL_TRUE")"; run_schedule "$repo"
check "decl. establishesSharedInfrastructure:true isolates prose-free work" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ] && [ \"\$(wave_of '$WAVES' t-002)\" = '2' ]"

# ============================================================================
# (b) NO INFRA TICKET → wave layout BYTE-IDENTICAL to the pre-change output.
#     The expected file below was captured by running THIS subcommand on the
#     tree before the S156 change; it is the no-regression guard.
# ============================================================================
PLAN_NOINFRA="$TMPROOT/noinfra.json"
{
  echo "["
  ticket t-001 "Render the scorecard header" \
    "Add the header component and its styles." "the header renders" "[]"
  echo "  ,"
  ticket t-002 "Add the metrics list" \
    "Render each metric row from the store." "rows render" "[]"
  echo "  ,"
  ticket t-003 "Sort the metrics" \
    "Sort rows by score descending." "sorted" '["t-001"]'
  echo "  ,"
  ticket t-004 "Filter the metrics" \
    "Filter rows by team." "filtered" '["t-001", "t-002"]'
  echo "]"
} > "$PLAN_NOINFRA"

cat > "$TMPROOT/noinfra-expected.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      },
      {
        "id": "t-002",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-003",
        "issue": null
      },
      {
        "id": "t-004",
        "issue": null
      }
    ]
  }
]
EOF

repo="$(new_mission "$PLAN_NOINFRA")"; run_schedule "$repo"
check "b. schedule exits 0 on the no-infra plan"        "[ '$RC' -eq 0 ]"
check "b. no-infra waves.json is BYTE-IDENTICAL to pre-S156 output" \
  "cmp -s '$TMPROOT/noinfra-expected.json' '$WAVES'"
check "b. no-infra waves.json carries NO reason key (additive-absent)" \
  "! grep -q 'reason' '$WAVES'"
check "b. no-infra readout says nothing about isolation" \
  "! printf '%s' \"\$OUT\" | grep -qi 'isolat'"

# ============================================================================
# (c) TWO INFRA TICKETS → each alone, in plan order
# ============================================================================
PLAN_TWO="$TMPROOT/twoinfra.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite + React application" \
    "Create package.json, vite.config.ts and tsconfig.json for the new app." \
    "the app builds" "[]"
  echo "  ,"
  ticket t-002 "Wire the shared Vitest setup and the CI workflow" \
    "Add vitest.setup.ts and .github/workflows/test.yml so every suite runs on push." \
    "CI runs the suite" "[]"
  echo "  ,"
  ticket t-003 "Render the scorecard header" \
    "Add the header component and its styles." "the header renders" "[]"
  echo "]"
} > "$PLAN_TWO"

repo="$(new_mission "$PLAN_TWO")"; run_schedule "$repo"
check "c. two infra tickets produce three waves"        "[ \"\$(n_waves '$WAVES')\" = '3' ]"
check "c. t-001 alone in wave 1" "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ]"
check "c. t-002 alone in wave 2" "[ \"\$(tickets_of_wave '$WAVES' 2)\" = 't-002' ]"
check "c. t-003 lands in wave 3" "[ \"\$(tickets_of_wave '$WAVES' 3)\" = 't-003' ]"
check "c. both isolated waves carry a reason" \
  "[ \"\$(grep -c '\"reason\":' '$WAVES')\" = '2' ]"

# ============================================================================
# (e) THE REAL FALSE-POSITIVE PLAN — six tickets of ordinary product work, each
#     mentioning a config file INCIDENTALLY. Against the first classifier this
#     plan went from 1 wave to 6 fully-serial waves. It must stay ONE wave.
# ============================================================================
PLAN_FP="$TMPROOT/falsepos.json"
{
  echo "["
  ticket t-001 "Add the router links" \
    "Wire the nav links to the router." "package.json lists react-router" "[]"
  echo "  ,"
  ticket t-002 "Show the version in the footer" \
    "Render the app version in the footer." \
    "Footer text equals the version field of package.json" "[]"
  echo "  ,"
  ticket t-003 "Add specs for the invoice total" \
    "Cover the rounding rules." "Specs use the existing spec_helper" "[]"
  echo "  ,"
  ticket t-004 "Add a test for the parser" \
    "Cover the malformed-input branch. Reuse the existing fixtures in conftest.py." \
    "the parser rejects malformed input" "[]"
  echo "  ,"
  ticket t-005 "Add the metrics endpoint" \
    "Return the scorecard metrics as JSON; no changes to go.mod are needed." \
    "the endpoint returns 200" "[]"
  echo "  ,"
  ticket t-006 "Document the release process" \
    "Add a Gemfile entry note in the contributing guide." \
    "the guide names the gem" "[]"
  echo "]"
} > "$PLAN_FP"

repo="$(new_mission "$PLAN_FP")"; run_schedule "$repo"
check "e. six incidental config mentions stay in ONE wave" \
  "[ \"\$(n_waves '$WAVES')\" = '1' ]"
check "e. all six share wave 1 in plan order" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001 t-002 t-003 t-004 t-005 t-006' ]"
check "e. no reason emitted for a non-isolated wave" \
  "! grep -q 'reason' '$WAVES'"

# --- the live failure restated in PYTHON, DECLARED (the mechanism) ----------
#     Its t-001 names no config file, so the backstop cannot see it — that is
#     exactly why the declared field is the mechanism, and the undeclared
#     variant below is asserted as a KNOWN MISS.
PLAN_PY="$TMPROOT/python-ground.json"
{
  echo "["
  ticket t-001 "Create the FastAPI service skeleton" \
    "Create the package layout, install pytest, and add a first passing test." \
    "pytest runs green" "[]" '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-002 "Add the health endpoint" "Return 200 from /health." \
    "GET /health returns 200" "[]" '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-003 "Add the scorecard docs and a test asserting they exist" \
    "Write docs/adr and a test that reads the repo root." "docs/adr/0001 exists" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-004 "Add the metrics endpoint" "Return the metrics as JSON." \
    "the endpoint returns 200" "[]" '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_PY"
repo="$(new_mission "$PLAN_PY")"; run_schedule "$repo"
check "py. the Python restatement of the live failure isolates t-001" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ]"
check "py. the docs-with-a-test ticket lands in a LATER wave" \
  "[ \"\$(wave_of '$WAVES' t-003)\" = '2' ]"
check "py. the two plain endpoints share the later wave (no over-serialising)" \
  "[ \"\$(tickets_of_wave '$WAVES' 2)\" = 't-002 t-003 t-004' ]"

# The SAME plan with the field omitted: a documented KNOWN MISS, end to end.
PLAN_PY_UNDECL="$TMPROOT/python-ground-undeclared.json"
{
  echo "["
  ticket t-001 "Create the FastAPI service skeleton" \
    "Create the package layout, install pytest, and add a first passing test." \
    "pytest runs green" "[]"
  echo "  ,"
  ticket t-002 "Add the health endpoint" "Return 200 from /health." \
    "GET /health returns 200" "[]"
  echo "]"
} > "$PLAN_PY_UNDECL"
repo="$(new_mission "$PLAN_PY_UNDECL")"; run_schedule "$repo"
check "py. KNOWN MISS: undeclared, it names no config file → NOT isolated" \
  "[ \"\$(n_waves '$WAVES')\" = '1' ]"
check "py. …and the readout WARNS that nothing was declared" \
  "printf '%s' \"\$OUT\" | grep -q 'NO ticket declared establishesSharedInfrastructure'"

# --- the mature-repo cases the dev doc names, DECLARED -----------------------
PLAN_MATURE="$TMPROOT/mature.json"
{
  echo "["
  ticket t-001 "Add the invoice line item" "Render the line item." "it renders" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-002 "Migrate the suite from Jest to Vitest" \
    "Move every test to the new runner." "the suite runs" "[]" \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-003 "Switch the compiler to project references" \
    "Restructure the compiler settings across the packages." "the build succeeds" "[]" \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-004 "Add the totals column" "Render the totals column." "it renders" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_MATURE"
repo="$(new_mission "$PLAN_MATURE")"; run_schedule "$repo"
check "mature. a runner migration is isolated" \
  "[ \"\$(tickets_of_wave '$WAVES' \$(wave_of '$WAVES' t-002))\" = 't-002' ]"
check "mature. a tsconfig restructure is isolated" \
  "[ \"\$(tickets_of_wave '$WAVES' \$(wave_of '$WAVES' t-003))\" = 't-003' ]"
check "mature. the later product ticket lands after both" \
  "[ \"\$(wave_of '$WAVES' t-004)\" -gt \"\$(wave_of '$WAVES' t-003)\" ]"
check "mature. the readout reports a fully-declared plan" \
  "printf '%s' \"\$OUT\" | grep -q 'all 4 ticket(s) declared establishesSharedInfrastructure (2 true, 2 false)'"

# ============================================================================
# (f) MIXED PLAN — dependency + contiguity invariants hold
# ============================================================================
PLAN_MIX="$TMPROOT/mixed.json"
{
  echo "["
  ticket t-001 "Render the scorecard header" \
    "Add the header component and its styles." "the header renders" "[]"
  echo "  ,"
  ticket t-002 "Add the metrics list" \
    "Render each metric row from the store." "rows render" "[]"
  echo "  ,"
  ticket t-003 "Migrate the test runner to Vitest" \
    "Replace jest.config.js with vitest.config.ts and update package.json scripts." \
    "the whole suite runs under the new runner" '["t-001"]'
  echo "  ,"
  ticket t-004 "Sort the metrics" \
    "Sort rows by score descending." "sorted" '["t-003"]'
  echo "  ,"
  ticket t-005 "Filter the metrics" \
    "Filter rows by team." "filtered" "[]"
  echo "]"
} > "$PLAN_MIX"

repo="$(new_mission "$PLAN_MIX")"; run_schedule "$repo"
w1="$(wave_of "$WAVES" t-001)"; w2="$(wave_of "$WAVES" t-002)"
w3="$(wave_of "$WAVES" t-003)"; w4="$(wave_of "$WAVES" t-004)"
w5="$(wave_of "$WAVES" t-005)"
check "f. every ticket is scheduled" \
  "[ -n '$w1' ] && [ -n '$w2' ] && [ -n '$w3' ] && [ -n '$w4' ] && [ -n '$w5' ]"
check "f. DEPENDENCY: t-003 lands after its dep t-001"        "[ '$w3' -gt '$w1' ]"
check "f. DEPENDENCY: t-004 lands after its dep t-003"        "[ '$w4' -gt '$w3' ]"
check "f. the infra ticket rides ALONE" \
  "[ \"\$(tickets_of_wave '$WAVES' $w3)\" = 't-003' ]"
check "f. BARRIER: t-004 (after infra in plan order) is later" "[ '$w4' -gt '$w3' ]"
check "f. BARRIER: t-005 (after infra in plan order) is later" "[ '$w5' -gt '$w3' ]"
check "f. tickets BEFORE the infra ticket keep their early wave" \
  "[ '$w1' = '1' ] && [ '$w2' = '1' ]"
check "f. plan order preserved inside wave 1" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001 t-002' ]"
mixnw="$(n_waves "$WAVES")"
check "f. CONTIGUITY: wave numbers are 1..N with no gaps" \
  "[ \"\$(awk '/\"wave\":/ { w=\$0; gsub(/[^0-9]/,\"\",w); printf \"%s \", w }' '$WAVES')\" = \"\$(awk -v n='$mixnw' 'BEGIN{for(i=1;i<=n;i++) printf \"%s \", i}')\" ]"
check "f. CONTIGUITY: every wave holds at least one ticket" \
  "[ \"\$(grep -c '\"id\":' '$WAVES')\" -ge '$mixnw' ]"

# ============================================================================
# D5 — the FORWARD-DEPENDENCY case (c4). An infra ticket whose dependency points
#      FORWARD in plan order cannot satisfy the barrier and the dependency at
#      once. Only the tickets needed to UNBLOCK it may jump the barrier; an
#      unrelated later ticket must NOT, and the reason must name the exception.
# ============================================================================
PLAN_C4="$TMPROOT/c4.json"
{
  echo "["
  ticket t-001 "Add A" "Add the A view." "A renders" '["t-002"]'
  echo "  ,"
  ticket t-002 "Scaffold the project" \
    "Create package.json, vite.config.ts and the test runner wiring." \
    "the app builds" '["t-003"]'
  echo "  ,"
  ticket t-003 "Add C" "Add the C view." "C renders" "[]"
  echo "  ,"
  ticket t-004 "Add D" "Add the D view." "D renders" "[]"
  echo "]"
} > "$PLAN_C4"

repo="$(new_mission "$PLAN_C4")"; run_schedule "$repo"
c1="$(wave_of "$WAVES" t-001)"; c2="$(wave_of "$WAVES" t-002)"
c3="$(wave_of "$WAVES" t-003)"; c4="$(wave_of "$WAVES" t-004)"
check "D5. schedule still succeeds on a forward-dep plan" "[ '$RC' -eq 0 ]"
check "D5. DEPENDENCY: t-003 builds before the infra ticket that needs it" \
  "[ '$c3' -lt '$c2' ]"
check "D5. DEPENDENCY: t-001 builds after the infra ticket it needs" \
  "[ '$c1' -gt '$c2' ]"
check "D5. the infra ticket still rides ALONE" \
  "[ \"\$(tickets_of_wave '$WAVES' $c2)\" = 't-002' ]"
check "D5. BARRIER HOLDS: unrelated later t-004 does NOT jump the barrier" \
  "[ '$c4' -gt '$c2' ]"
check "D5. the relaxation admitted ONLY the unblocking dependency" \
  "[ \"\$(tickets_of_wave '$WAVES' $c3)\" = 't-003' ]"
check "D5. the reason names the ticket that legitimately preceded it" \
  "grep '\"reason\":' '$WAVES' | grep -q 'except t-003, which it depends on'"

# ============================================================================
# THE FEATURE'S REAL LIMIT — a PHRASING COIN-FLIP on an undeclared plan.
#     Same ticket, same intent, two ways of writing it. One names config files
#     and is isolated; the other does not and shares wave 1 with the docs
#     ticket — reproducing the 2026-07-27 failure exactly. Both are asserted, so
#     this file records the limit instead of hiding it, and any future widening
#     has to confront the miss deliberately.
# ============================================================================
PLAN_COIN_A="$TMPROOT/coin-a.json"
{
  echo "["
  ticket t-001 "Scaffold the app" \
    "Create the project scaffold — package.json, vite.config.ts and tsconfig.json." \
    "the dev server boots" "[]"
  echo "  ,"
  ticket t-012 "Author the ADR and backlog docs" \
    "Write docs/adr and a suite asserting each doc exists." "the docs exist" "[]"
  echo "]"
} > "$PLAN_COIN_A"
repo="$(new_mission "$PLAN_COIN_A")"; run_schedule "$repo"
check "coin. NAMING the config files → isolated, the 2026-07-27 failure prevented" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ] && [ \"\$(wave_of '$WAVES' t-012)\" = '2' ]"

PLAN_COIN_B="$TMPROOT/coin-b.json"
{
  echo "["
  ticket t-001 "Scaffold the app" \
    "Create the app entry and wire the dev/build/test scripts." \
    "the dev server boots" "[]"
  echo "  ,"
  ticket t-012 "Author the ADR and backlog docs" \
    "Write docs/adr and a suite asserting each doc exists." "the docs exist" "[]"
  echo "]"
} > "$PLAN_COIN_B"
repo="$(new_mission "$PLAN_COIN_B")"; run_schedule "$repo"
check "coin. KNOWN MISS: the SAME ticket naming no config file shares wave 1" \
  "[ \"\$(n_waves '$WAVES')\" = '1' ]"
check "coin. …which is the 2026-07-27 failure shape, undeclared" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001 t-012' ]"
check "coin. …and the readout WARNS the plan declared nothing" \
  "printf '%s' \"\$OUT\" | grep -q 'NO ticket declared establishesSharedInfrastructure'"

# Declaring the field removes the coin-flip entirely.
PLAN_COIN_C="$TMPROOT/coin-c.json"
{
  echo "["
  ticket t-001 "Scaffold the app" \
    "Create the app entry and wire the dev/build/test scripts." \
    "the dev server boots" "[]" '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-012 "Author the ADR and backlog docs" \
    "Write docs/adr and a suite asserting each doc exists." "the docs exist" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_COIN_C"
repo="$(new_mission "$PLAN_COIN_C")"; run_schedule "$repo"
check "coin. DECLARING the field isolates it regardless of phrasing" \
  "[ \"\$(tickets_of_wave '$WAVES' 1)\" = 't-001' ] && [ \"\$(wave_of '$WAVES' t-012)\" = '2' ]"

# ============================================================================
# NEW-1 — TWO blocked infra tickets must not leak past each other's barrier, and
#         the reason may never assert a dependency the graph disproves.
#         (d5min: all flags DECLARED, so this is the primary path.)
# ============================================================================
PLAN_D5MIN="$TMPROOT/d5min.json"
{
  echo "["
  ticket t-001 "Scaffold the project" "Create the project." "it builds" '["t-004"]' \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-002 "Scaffold the workspace" "Create the workspace." "it builds" '["t-003"]' \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-003 "Add the CSV export" "Export rows as CSV." "the export works" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-004 "Add the team filter" "Filter rows by team." "filtering works" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_D5MIN"
repo="$(new_mission "$PLAN_D5MIN")"; run_schedule "$repo"
m1="$(wave_of "$WAVES" t-001)"; m2="$(wave_of "$WAVES" t-002)"
m3="$(wave_of "$WAVES" t-003)"; m4="$(wave_of "$WAVES" t-004)"
check "NEW-1. both infra tickets ride ALONE" \
  "[ \"\$(tickets_of_wave '$WAVES' $m1)\" = 't-001' ] && [ \"\$(tickets_of_wave '$WAVES' $m2)\" = 't-002' ]"
check "NEW-1. t-003 does NOT jump t-001's barrier (it is no dependency of t-001)" \
  "[ '$m3' -gt '$m1' ]"
check "NEW-1. t-004 precedes t-001 — it IS its dependency" "[ '$m4' -lt '$m1' ]"
check "NEW-1. t-003 precedes t-002 — it IS its dependency"  "[ '$m3' -lt '$m2' ]"
# The reason line belonging to one isolated ticket (they start with its id).
reason_of() { grep '"reason":' "$1" | grep -F "$2 declares" | head -n 1; }
r1="$(reason_of "$WAVES" t-001)"; r2="$(reason_of "$WAVES" t-002)"
check "NEW-1. t-001's reason names t-004 as its dependency (TRUE per the graph)" \
  "printf '%s' \"\$r1\" | grep -q 'except t-004, which it depends on'"
check "NEW-1. t-001's reason never mentions t-003 (it is NOT its dependency)" \
  "! printf '%s' \"\$r1\" | grep -q 't-003'"
check "NEW-1. t-002's reason names t-003 as its dependency (TRUE per the graph)" \
  "printf '%s' \"\$r2\" | grep -q 'except t-003, which it depends on'"
check "NEW-1. t-002's reason never calls t-004 a dependency (the graph disproves it)" \
  "! printf '%s' \"\$r2\" | grep -q 't-004, which it depends on'"
check "NEW-1. t-002's reason states plainly that t-004 built earlier anyway" \
  "printf '%s' \"\$r2\" | grep -q 'NOTE t-004 built earlier despite coming later in the plan'"
check "NEW-1. …and that t-004 did NOT build against this infrastructure" \
  "printf '%s' \"\$r2\" | grep -q 'did NOT build against this infrastructure'"
# The graph itself is never weakened by any of the above.
check "NEW-1. DEPENDENCY: t-001 after t-004" "[ '$m1' -gt '$m4' ]"
check "NEW-1. DEPENDENCY: t-002 after t-003" "[ '$m2' -gt '$m3' ]"

# ============================================================================
# NEW-2 — PROVENANCE is in the readout on EVERY path, so the captain can tell
#         "the planner decided" from "the harness guessed" from "nobody said".
# ============================================================================
# (i) all declared
repo="$(new_mission "$PLAN_GROUND")"; run_schedule "$repo"
check "prov. all-declared: the readout says so, with the true/false split" \
  "printf '%s' \"\$OUT\" | grep -q 'all 2 ticket(s) declared establishesSharedInfrastructure (1 true, 1 false)'"
# (ii) none declared
repo="$(new_mission "$PLAN_GROUND_UNDECLARED")"; run_schedule "$repo"
check "prov. none-declared: the readout WARNS, and says what that costs" \
  "printf '%s' \"\$OUT\" | grep -q 'NO ticket declared establishesSharedInfrastructure'"
check "prov. none-declared: names the limitation (only a NAMED config file)" \
  "printf '%s' \"\$OUT\" | grep -q 'NAMES a build/test config file'"
# (iii) mixed
PLAN_MIXDECL="$TMPROOT/mixed-decl.json"
{
  echo "["
  ticket t-001 "Scaffold the app" "Create package.json and vite.config.ts." "it builds" "[]" \
    '"establishesSharedInfrastructure": true'
  echo "  ,"
  ticket t-002 "Add the header" "Render the header." "it renders" "[]"
  echo "  ,"
  ticket t-003 "Add the footer" "Render the footer." "it renders" "[]"
  echo "]"
} > "$PLAN_MIXDECL"
repo="$(new_mission "$PLAN_MIXDECL")"; run_schedule "$repo"
check "prov. mixed: counts declared vs read-from-text" \
  "printf '%s' \"\$OUT\" | grep -q '1 of 3 ticket(s) declared establishesSharedInfrastructure (1 true, 0 false); 2 undeclared, read from ticket text instead (0 matched a config file)'"
# (iv) a `false` that contradicts the text — the plan wins, and it is SAID
PLAN_CONTRA="$TMPROOT/contradicted.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite + React + TypeScript app" \
    "Create package.json, vite.config.ts and tsconfig.json." "the app builds" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "  ,"
  ticket t-002 "Add the header" "Render the header." "it renders" "[]" \
    '"establishesSharedInfrastructure": false'
  echo "]"
} > "$PLAN_CONTRA"
repo="$(new_mission "$PLAN_CONTRA")"; run_schedule "$repo"
check "prov. contradicted-false: the declaration still WINS (one wave)" \
  "[ \"\$(n_waves '$WAVES')\" = '1' ]"
check "prov. contradicted-false: but the override is stated, naming the file" \
  "printf '%s' \"\$OUT\" | grep -q 't-001 declares establishesSharedInfrastructure: false, overriding a config-file match (package.json)'"
check "prov. contradicted-false: the readout says the plan's call wins" \
  "printf '%s' \"\$OUT\" | grep -q \"the plan's call wins\""
check "prov. an uncontradicted false is NOT reported as an override" \
  "[ \"\$(printf '%s' \"\$OUT\" | grep -c 'overriding a config-file match')\" = '1' ]"

# ============================================================================
# SINGLE-TICKET FAST PATH — a lone infra ticket is classified too, and worded
# honestly (there is no "later ticket" on a one-ticket plan).
# ============================================================================
PLAN_LONE="$TMPROOT/lone.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite + React application" \
    "Create package.json, vite.config.ts and tsconfig.json." "the app builds" "[]"
  echo "]"
} > "$PLAN_LONE"
repo="$(new_mission "$PLAN_LONE")"; run_schedule "$repo"
check "lone. a one-ticket infra plan still emits a reason" \
  "grep -q '\"reason\":' '$WAVES'"
check "lone. the reason does NOT claim later tickets build against it" \
  "! grep '\"reason\":' '$WAVES' | grep -q 'later tickets'"
check "lone. the reason says it is the only ticket" \
  "grep '\"reason\":' '$WAVES' | grep -q 'only ticket'"

PLAN_LONE_PLAIN="$TMPROOT/lone-plain.json"
{
  echo "["
  ticket t-001 "Render the scorecard header" \
    "Add the header component and its styles." "the header renders" "[]"
  echo "]"
} > "$PLAN_LONE_PLAIN"
repo="$(new_mission "$PLAN_LONE_PLAIN")"; run_schedule "$repo"
check "lone. a one-ticket NON-infra plan is unchanged (no reason)" \
  "! grep -q 'reason' '$WAVES'"

# ============================================================================
# CYCLE PATH UNTOUCHED
# ============================================================================
PLAN_CYC="$TMPROOT/cycle.json"
{
  echo "["
  ticket t-001 "Scaffold the Vite app" \
    "Create package.json and vite.config.ts." "builds" '["t-002"]'
  echo "  ,"
  ticket t-002 "Add the metrics list" \
    "Render each metric row." "rows render" '["t-001"]'
  echo "]"
} > "$PLAN_CYC"

repo="$(new_mission "$PLAN_CYC")"; run_schedule "$repo"
check "cycle. exits non-zero"          "[ '$RC' -ne 0 ]"
check "cycle. reports it clearly"      "printf '%s' \"\$OUT\" | grep -qi 'circular\|cycle'"
check "cycle. names the stuck tickets" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -q 't-002'"
check "cycle. writes no waves.json"    "[ ! -f '$WAVES' ]"
check "cycle. does not advance the stage" \
  "grep -q '\"stage\": *\"schedule\"' '$repo/.git/lcars/missions/test-001/state.json'"

# ============================================================================
# THE HEURISTIC BACKSTOP'S MEASURED ACCURACY
#     Driven through the REAL classify_infra_ticket (extracted by name, since
#     run.sh self-dispatches on load). Corpus 1 = the false positives an
#     adversarial tester found, plus extra probes written to break it; corpus 2 =
#     the false negatives, including the live failure restated in Python and one
#     scaffold per stack LCARS supports. These numbers are MEASURED — if the
#     backstop regresses, the printed count moves.
# ============================================================================
CLIB="$TMPROOT/classifier.sh"
sed -n '/^# --- the backstop.s vocabulary/,/^# The classification of ONE ticket/p' \
  "$REPO_ROOT/skills/lcars-run/run.sh" > "$CLIB"
check "corpus. classifier extraction found the entry point" \
  "grep -q 'classify_infra_ticket() {' '$CLIB' && grep -q 'infra_heuristic() {' '$CLIB'"
# shellcheck disable=SC1090
. "$CLIB"

# A plan-table line: id, title, desc, criteria, deps, rationale, infra-flag.
tline() { printf 't-001\t%s\t%s\t%s\t\t%s\t%s' "$1" "$2" "$3" "${4:-}" "${5:-}"; }

FP_N=0; FP_CLEAN=0; FP_BAD=""
neg() { # title desc crit
  FP_N=$((FP_N+1))
  if classify_infra_ticket "$(tline "$1" "$2" "$3")" >/dev/null 2>&1
  then FP_BAD="$FP_BAD
      fired on: $1"
  else FP_CLEAN=$((FP_CLEAN+1)); fi
}
FN_N=0; FN_CAUGHT=0; FN_BAD=""
pos() { # title desc crit
  FN_N=$((FN_N+1))
  if classify_infra_ticket "$(tline "$1" "$2" "$3")" >/dev/null 2>&1
  then FN_CAUGHT=$((FN_CAUGHT+1))
  else FN_BAD="$FN_BAD
      missed: $1"; fi
}

# --- PRECISION REGRESSION GUARD: ordinary product work must stay clean -------
#     These are the false positives an adversarial tester found (plus probes
#     written to break the classifier, not to pass it). This list is a guard
#     against regressions — it is NOT a measurement of accuracy.
neg "Add the router links" "Wire the nav links to the router." "package.json lists react-router"
neg "Show the version in the footer" "Render the app version in the footer." "Footer text equals the version field of package.json"
neg "Document the compiler options" "Explain the build settings for contributors." "compiler options are documented in tsconfig"
neg "Add the build badge to the README" "Show CI status at the top of the README." "Link the badge to .github/workflows/ci.yml"
neg "Add specs for the invoice total" "Cover the rounding rules." "Specs use the existing spec_helper"
neg "Add a test for the parser" "Cover the malformed-input branch." "Reuse the existing fixtures in conftest.py"
neg "Add the metrics endpoint" "Return the metrics as JSON; no changes to go.mod are needed." "the endpoint returns 200"
neg "Add the report view model" "Add the view model to the reporting project; it already belongs to the existing .sln" "the view model binds"
neg "Rename the setup wizard component" "Rename SetupWizard to OnboardingWizard under src/tests/setup.tsx" "the wizard still renders"
neg "Document the release process" "Add a Gemfile entry note in the contributing guide" "the guide names the gem"
neg "Add tests for the score formatter" "Add a vitest suite covering the rounding rules." "rounding is under test"
neg "Add the scorecard docs and a test asserting they exist" "Write docs/adr and a test that reads the repo root." "docs/adr/0001 exists"
neg "Add the health endpoint" "Return 200 from /health." "GET /health returns 200"
neg "Build the team filter" "Filter the rows by team, with a test for the empty selection." "filtering works"
# the `port`-as-a-noun pair — `port` was removed from the verb list for these
neg "Show the dev server port" "Create the banner that reads the port from package.json." "the banner shows the port"
neg "Display the bound port" "Display the port the dev server bound, from vite.config." "the port is shown"
# probes written to break it (unanchored-substring family: repo⊂report, cli⊂client)
neg "Generate the quarterly report" "Create the quarterly report view." "the report renders"
neg "Initialise the reporting dashboard" "Set up the reporting dashboard shell." "the dashboard renders"
neg "Bootstrap the client onboarding flow" "Add the onboarding steps." "onboarding completes"
neg "Scaffold the client directory listing" "Render the client directory." "the listing renders"
neg "Stand up the observer for price changes" "Add the price observer." "prices update"
neg "Add a workspace switcher to the sidebar" "Switch between workspaces from the nav." "the switcher works"
neg "Create the scoreboard skeleton component" "Render a loading skeleton while data loads." "the skeleton shows"
neg "Replace the config screen with a modal" "Move the settings form into a modal." "the modal opens"
neg "Switch the build button to a link" "Render the build action as a link." "the link works"
neg "Initialise the counter state in the app" "Seed the counter to zero on mount." "the counter starts at zero"
neg "Add a test suite for the invoice total" "Cover the rounding rules." "totals are correct"
# plan.md mandates a rationale in exactly this voice — neither may fire
neg "Add the team filter" "Filter rows by team." "filtering works" # (rationale below)
check "corpus. plan.md-voice rationale 'the same project structure' does not fire" \
  "! classify_infra_ticket \"\$(tline 'Add the team filter' 'Filter rows by team.' 'filtering works' 'Later tickets add filters on top of the same project structure.')\""
check "corpus. plan.md-voice rationale 'generate the report' does not fire" \
  "! classify_infra_ticket \"\$(tline 'Add the report' 'Render the report.' 'it renders' 'we can generate the report on demand instead')\""

# --- RECALL, STATED HONESTLY -------------------------------------------------
#     The backstop has exactly ONE signal: a config FILE named next to a
#     create/change verb. Anything that establishes infrastructure WITHOUT
#     naming a config file is MISSED — by design, after prose matching was
#     measured at 5/14 on a reworded corpus and 13/23 on unseen tickets. These
#     are asserted as KNOWN MISSES so this file documents real recall. If a
#     future change makes one of them fire, this test fails and the change has
#     to be a deliberate, measured decision — not a quiet pattern widening.
KM_N=0; KM_MISSED=0; KM_FIRED=""
known_miss() { # title desc crit
  KM_N=$((KM_N+1))
  if classify_infra_ticket "$(tline "$1" "$2" "$3")" >/dev/null 2>&1
  then KM_FIRED="$KM_FIRED
      now fires: $1"
  else KM_MISSED=$((KM_MISSED+1)); fi
}
known_miss "Add coverage thresholds to the Vitest setup" "Fail the run under 80 percent." "coverage gates the run"
known_miss "Add TypeScript path aliases for the shared packages" "Point the aliases at the shared source." "imports resolve"
known_miss "Split the pnpm workspace into apps and packages" "Move each app under apps/." "the install succeeds"
known_miss "Add the GitHub Actions job that runs the unit tests on push" "Run the unit tests in CI." "CI is green on push"
known_miss "Create the Django project and its settings module" "Create the project and settings." "the server starts"
known_miss "Replace unittest with pytest across the suite" "Move every test to the new runner." "the suite runs"
known_miss "Add JUnit 5 to the Gradle build" "Wire the test task to JUnit 5." "the tests run"
known_miss "Add a dual ESM and CJS bundler configuration" "Emit both module formats." "both entry points load"
known_miss "Migrate the existing Jest suites onto Vitest" "Move every suite to the new runner." "the suites run"
known_miss "Create the Next.js application" "Create the app and its first route." "the route renders"
known_miss "Create the FastAPI service skeleton" "Create the package layout, install pytest, and add a first passing test." "pytest runs green"
known_miss "Stand up the test runner" "Stands up the test harness for the repo." "the runner runs"
known_miss "Install RSpec and a first spec" "Add the spec runner and one spec." "rspec runs"
known_miss "Create the Rust workspace and crate layout" "Create the workspace and the first crate." "cargo build succeeds"

# --- BLOCKER ANCHORING (fix round 3): an unanchored blocker swallowed genuine
#     infrastructure through unrelated substrings — "guide" inside styleguide /
#     guidelines, "display" inside displays. All three must CLASSIFY.
pos "Add the Vite config" "Add vite.config.ts as described in the styleguide." "the build runs"
pos "Add the TS config" "Create tsconfig per our guidelines." "the build runs"
pos "Add the pytest config" "Create pytest.ini; the runner displays progress." "pytest runs"

# --- NEGATION FORMS the blocker must still swallow (fix round 3) -------------
neg "Add the widget" "It does not introduce tsconfig changes." "the widget renders"
neg "Add the pure helper" "The helper is pure; none of them create package.json entries." "the helper is pure"
neg "Add the constant" "Add a constant rather than create package.json entries." "the constant is exported"

# --- what the surviving signal DOES catch: a named config file + a verb -------
pos "Scaffold the app" "Create package.json, vite.config.ts and tsconfig.json." "the app builds"
pos "Wire the shared test setup" "Add vitest.setup.ts and .github/workflows/test.yml." "CI runs the suite"
pos "Migrate the runner" "Replace jest.config.js with vitest.config.ts." "the suite runs"
pos "Initialise the module" "Create go.mod and the package tree." "go build succeeds"
pos "Add the pytest config" "Create pytest.ini and conftest.py." "pytest runs"
pos "Create the crate" "Add Cargo.toml for the new crate." "cargo build succeeds"
pos "Create the web project" "Add Web.csproj and wire it into the build." "dotnet build succeeds"
pos "Add the spec runner config" "Create .rspec and spec_helper.rb." "rspec runs"
pos "Add the Gradle build" "Create build.gradle and settings.gradle." "gradle build succeeds"

check "corpus. PRECISION GUARD: all $FP_N ordinary tickets stay clean" \
  "[ '$FP_CLEAN' -eq '$FP_N' ]"
[ "$FP_CLEAN" -eq "$FP_N" ] || printf '    misfires:%s\n' "$FP_BAD"
check "corpus. the config-file signal still catches all $FN_N file-naming tickets" \
  "[ '$FN_CAUGHT' -eq '$FN_N' ]"
[ "$FN_CAUGHT" -eq "$FN_N" ] || printf '    misses:%s\n' "$FN_BAD"
check "corpus. KNOWN MISSES: all $KM_N still miss (recall is NOT silently widened)" \
  "[ '$KM_MISSED' -eq '$KM_N' ]"
[ "$KM_MISSED" -eq "$KM_N" ] || printf '    newly firing:%s\n' "$KM_FIRED"
printf '    backstop reality: catches a NAMED config file (%d/%d) · KNOWN MISS on infra that names none (%d/%d) · precision guard %d/%d\n' \
  "$FN_CAUGHT" "$FN_N" "$KM_MISSED" "$KM_N" "$FP_CLEAN" "$FP_N"

# --- word-boundary regression (D4): "django.models" is not go.mod ------------
check "corpus. django.models does NOT match go.mod" \
  "! classify_infra_ticket \"\$(tline 'Add the report model' 'Create the report model in django.models.' 'the model saves')\""
check "corpus. mongo.models does NOT match go.mod" \
  "! classify_infra_ticket \"\$(tline 'Add the user model' 'Create the user model in mongo.models.' 'the model saves')\""
check "corpus. a real go.mod ticket DOES match" \
  "classify_infra_ticket \"\$(tline 'Initialise the module' 'Create go.mod and the package tree.' 'go build succeeds')\""
check "corpus. an extension token still matches inside a filename (Web.csproj)" \
  "classify_infra_ticket \"\$(tline 'Create the web project' 'Add Web.csproj and wire it into the build.' 'dotnet build succeeds')\""

# --- the rationale is read too (parse_plan_table previously dropped it) ------
check "corpus. a config file named ONLY in the rationale is read" \
  "classify_infra_ticket \"\$(tline 'Add the widget' 'Render the widget.' 'the widget renders' 'This ticket also creates vitest.config.ts, which every later ticket runs under.')\""

# --- the declared flag short-circuits the prose entirely ---------------------
check "corpus. declared true wins over ordinary prose" \
  "classify_infra_ticket \"\$(tline 'Add the widget' 'Render the widget.' 'ok' '' 'true')\" | grep -q '^declared'"
check "corpus. declared false wins over infrastructure prose" \
  "! classify_infra_ticket \"\$(tline 'Scaffold the project' 'Create package.json and vite.config.ts.' 'builds' '' 'false')\""
check "corpus. an absent flag is reported as inferred" \
  "classify_infra_ticket \"\$(tline 'Scaffold the project' 'Create package.json and vite.config.ts.' 'builds')\" | grep -q '^inferred'"

# ============================================================================
# THE DECLARED FIELD IS OPTIONAL AND TYPE-CHECKED (validate_plan_json)
# ============================================================================
plan_save() { # plan-file -> RC + OUT
  local repo; repo="$(mktemp -d "$TMPROOT/psave.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }
JSON
  OUT="$( cd "$repo" && bash "$SCRIPT" plan-save --mission test-001 --plan "$1" 2>&1 )"
  RC=$?
}
{ echo "["; ticket t-001 "Do the thing" "Build it." "it works" "[]"; echo "]"; } > "$TMPROOT/v-absent.json"
plan_save "$TMPROOT/v-absent.json"
check "validate. establishesSharedInfrastructure ABSENT is still valid" "[ '$RC' -eq 0 ]"
{ echo "["; ticket t-001 "Do the thing" "Build it." "it works" "[]" '"establishesSharedInfrastructure": true'; echo "]"; } > "$TMPROOT/v-true.json"
plan_save "$TMPROOT/v-true.json"
check "validate. establishesSharedInfrastructure true is accepted" "[ '$RC' -eq 0 ]"
{ echo "["; ticket t-001 "Do the thing" "Build it." "it works" "[]" '"establishesSharedInfrastructure": false'; echo "]"; } > "$TMPROOT/v-false.json"
plan_save "$TMPROOT/v-false.json"
check "validate. establishesSharedInfrastructure false is accepted" "[ '$RC' -eq 0 ]"
{ echo "["; ticket t-001 "Do the thing" "Build it." "it works" "[]" '"establishesSharedInfrastructure": "maybe"'; echo "]"; } > "$TMPROOT/v-bad.json"
plan_save "$TMPROOT/v-bad.json"
check "validate. a non-boolean flag is REJECTED" "[ '$RC' -ne 0 ]"
check "validate. the rejection names the field" \
  "printf '%s' \"\$OUT\" | grep -q 'establishesSharedInfrastructure'"
# plan-save WARNS at the earliest actionable point when nothing is declared
plan_save "$TMPROOT/v-absent.json"
check "plan-save. warns when NO ticket declares the field" \
  "printf '%s' \"\$OUT\" | grep -q 'no ticket declares establishesSharedInfrastructure'"
check "plan-save. the warning is NOT a gate (the plan still advances)" \
  "[ '$RC' -eq 0 ] && printf '%s' \"\$OUT\" | grep -q 'Stage:  plan-review'"
plan_save "$TMPROOT/v-false.json"
check "plan-save. a declared plan gets no warning" \
  "! printf '%s' \"\$OUT\" | grep -q 'no ticket declares'"

# ============================================================================
# (g) EVERY jq-FREE READER STILL PARSES A REASON-BEARING waves.json
#     Readers: run.sh parse_waves_table + ticket_issue, lcars-status/render.sh
#     read_waves_totals, lcars-resolve-logs, web/lcars_serve/local_adapter.py.
#     ($RWAVES is the INFERRED-reason file — the longest, most prose-heavy
#     reason the harness can emit.)
# ============================================================================
check "g. fixture waves.json really does carry a reason" "grep -q '\"reason\":' '$RWAVES'"

LIB="$TMPROOT/readers.sh"
sed -n '/^parse_waves_table() {/,/^}/p;/^ticket_issue() {/,/^}/p' \
  "$REPO_ROOT/skills/lcars-run/run.sh" > "$LIB"
check "g. reader extraction found parse_waves_table + ticket_issue" \
  "grep -q 'parse_waves_table' '$LIB' && grep -q 'ticket_issue' '$LIB'"
# shellcheck disable=SC1090
. "$LIB"
pwt="$(parse_waves_table "$RWAVES")"
check "g. parse_waves_table yields exactly 2 rows" \
  "[ \"\$(printf '%s\n' \"\$pwt\" | grep -c .)\" = '2' ]"
check "g. parse_waves_table maps t-001 → wave 1" \
  "printf '%s' \"\$pwt\" | grep -q '^1$(printf '\t')t-001$'"
check "g. parse_waves_table maps t-012 → wave 2" \
  "printf '%s' \"\$pwt\" | grep -q '^2$(printf '\t')t-012$'"
check "g. parse_waves_table never mistakes the reason for a ticket" \
  "! printf '%s' \"\$pwt\" | grep -qi 'inferred'"
check "g. ticket_issue reads t-001's issue (null, local-only)" \
  "[ \"\$(ticket_issue '$RWAVES' t-001)\" = 'null' ]"
check "g. ticket_issue reads t-012's issue (null, local-only)" \
  "[ \"\$(ticket_issue '$RWAVES' t-012)\" = 'null' ]"
check "g. ticket_issue returns nothing for an unknown ticket" \
  "[ -z \"\$(ticket_issue '$RWAVES' t-999)\" ]"

outIS="$( cd "$repoU" && bash "$SCRIPT" impl-status --mission test-001 2>&1 )"
check "g. impl-status reports wave 1 active on a reason-bearing waves.json" \
  "printf '%s' \"\$outIS\" | grep -q 'IMPLEMENT: wave 1 active'"
check "g. impl-status names wave 1's pending ticket (t-001, alone)" \
  "printf '%s' \"\$outIS\" | grep -q 'Pending ticket(s) in wave 1: t-001$'"
outIA="$( cd "$repoU" && bash "$SCRIPT" impl-advance --mission test-001 2>&1 )"
check "g. impl-advance still blocks on the un-green wave-1 ticket" \
  "printf '%s' \"\$outIA\" | grep -q 'ticket t-001 (wave 1) is not green'"

totals="$( WAVES="$RWAVES" bash -c '. "$0"; read_waves_totals' "$RENDER_LIB" 2>/dev/null )"
check "g. render.sh read_waves_totals reads 2 waves / 2 tickets" \
  "[ \"\$totals\" = '2 2' ]"

# lcars-resolve-logs owns its OWN resolve-waves.json ({wave, bugs:[…]}) and never
# reads a Mission's waves.json — so the additive reason cannot reach it.
check "g. resolve-logs.sh reads no Mission waves.json (own shape only)" \
  "! grep -n '[^-]waves\.json\"' '$RESOLVE_LOGS' | grep -qv 'resolve-waves'"

PY="${LCARS_PYTHON_BIN:-python3}"
if command -v "$PY" >/dev/null 2>&1; then
  pyout="$( cd "$WEB_DIR" && "$PY" - "$RWAVES" <<'PY' 2>&1
import json, sys
from lcars_serve import local_adapter as la
waves = json.load(open(sys.argv[1]))
prog = la._progress(waves, [{"type": "wave_start", "data": {"wave": 1}}])
rows = la._tickets([], waves, [])
print(prog["wavesTotal"], prog["ticketsTotal"], prog["label"],
      "|", ",".join(r["id"] for r in rows))
PY
)"
  check "g. local_adapter counts 2 waves / 2 tickets from a reason-bearing file" \
    "printf '%s' \"\$pyout\" | grep -q '^2 2 '"
  check "g. local_adapter still derives the ticket rows (t-001, t-012)" \
    "printf '%s' \"\$pyout\" | grep -q '| t-001,t-012$'"
  check "g. local_adapter never treats the reason as a ticket" \
    "! printf '%s' \"\$pyout\" | grep -qi 'inferred'"
else
  echo "  (skip) python3 not on PATH — local_adapter reader check"
fi

echo
printf 'wave-isolation: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
