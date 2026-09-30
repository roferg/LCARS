#!/usr/bin/env bash
#
# Tests for the end-of-Align ESTIMATOR (session 59). The estimator runs once at
# the end of Align: a cold repo-read worker reasons over the finalized PRD + ADR
# + repo and writes estimate.json — two criticality scores (reasoningCriticality,
# implCriticality) + a per-stage model map (logical tiers sonnet/opus) that
# session-58's resolve_stage_model CONSUMES. This suite is the PRODUCER side.
#
# We never call a real model. The estimator's cold worker is a RECORDING STUB CLI
# that writes a canned estimate.json into its scratch output dir (LCARS_WORK_OUT),
# driven through the REAL run.sh `estimate` subcommand + the REAL file.sh Align
# wiring (LCARS_RUN_BIN points at the real run.sh; LCARS_WORKER_BIN at the stub).
#
# Behaviors covered:
#   1. `lcars file` on a trivial PRD ⇒ estimate.json exists, valid schema, both
#      scores present, models map has all 6 keys with sonnet/opus values.
#   2. A high-reasoning fixture ⇒ research/validate = opus (ramp applied, persisted).
#   3. A deviation the estimator records survives into the persisted estimate.json.
#   4. Estimator unavailable / invalid JSON ⇒ mission STILL files (exit 0,
#      state.json written, readout printed); no estimate.json; no crash.
#   5. The produced estimate.json then drives S58's resolver end-to-end:
#      resolve-stage-model / spawn-stage per-stage --model matches the map, for
#      BOTH claude and copilot. S78: copilot is OPUS-SAFE — both tiers map to
#      claude-opus-4.8 (claude keeps its dynamic per-stage tiers).
#
# Usage: bash tests/estimate.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
FILE="$REPO_ROOT/skills/lcars-file/file.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A canned-estimate stub CLI: ignores its prompt, writes $STUB_ESTIMATE (an
# estimate.json body) into its scratch output dir (LCARS_WORK_OUT). $STUB_ESTIMATE
# may be the literal "NONE" to emulate a worker that produces NO file (failure).
make_estimator_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_ESTIMATE:-}" = "NONE" ]; then exit 0; fi
printf '%s\n' "${STUB_ESTIMATE:-}" >"$LCARS_WORK_OUT/estimate.json"
exit 0
EOF
  chmod +x "$1"
}

# A recording stub CLI for the RESOLVER side (behavior 5): writes its argv to
# $STUB_ARGV so per-stage --model can be asserted from the spawned call.
make_argv_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
: >"$STUB_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$STUB_ARGV"; done
exit 0
EOF
  chmod +x "$1"
}

# Build a git repo with .git/lcars scaffolded + a config.json. An initial commit
# lets file.sh branch off it. No CONTEXT.md (so the estimator's context_extra_block
# would generate a pack — but our stub worker writes estimate.json regardless).
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  # S183: a CONFIGURED test command, so this fixture is a repo with a test
  # FOUNDATION. `lcars file` now refuses to open a normal mission on a repo that
  # has none (greenfield/untested) and points at Establish Vision instead — so a
  # suite that files missions has to file against a repo that can actually be
  # filed against. `true` resolves via `command -v`, which is all the readiness
  # verdict asks of a command. The gate itself is proven in
  # tests/foundation-gate.test.sh, against real repos in all four states.
  printf '{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-01-01T00:00:00Z" }\n' \
    >"$repo/.git/lcars/config.json"
  # A repo-root CONTEXT.md so resolve_context_source never tries to spawn a pack
  # worker (the stub only knows how to emit estimate.json, not a context pack).
  printf '# Context\nTest repo.\n' >"$repo/CONTEXT.md"
  printf '%s' "$repo"
}

write_prd() { # path
  cat >"$1" <<'EOF'
# Mission: Fix the broken /about route

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
- The About page renders its heading
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
}

# Drive the REAL file.sh Align flow with the estimator wired to the real run.sh
# but its cold worker swapped for the canned-estimate stub. $1=repo, $2=estimate
# body (or "NONE"). Returns file.sh's exit code; estimate.json lands in the
# mission dir on success.
file_with_estimate() { # repo estimate-body
  local repo="$1" est="$2"
  local stub="$repo/estimator-stub"; make_estimator_stub "$stub"
  local prd="$repo/prd-in.md"; write_prd "$prd"
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      CLAUDECODE=1 \
      STUB_ESTIMATE="$est" \
      LCARS_RUN_BIN="$RUN" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=claude \
      LCARS_GH_BIN="$repo/definitely-no-gh" \
      LCARS_DATE=20260613 \
      bash "$FILE" --prd "$prd" >"$repo/file.out" 2>&1 )
}

# S196 — the fingerprint the pinned cloneId above produces. A minted mission
# id is now `lcars-YYYYMMDD-NNN-<fp>` (per-clone, so two laptops filing on one
# day cannot mint one name for one shared branch); pinning cloneId in the
# fixture makes <fp> the constant `c10e`. See tests/mission-id.test.sh.
MDIR() { printf '%s/.git/lcars/missions/lcars-20260613-001-c10e' "$1"; }

echo "estimate — end-of-Align estimator (session 59)"

[ -f "$FILE" ] || { echo "file.sh not found at $FILE"; exit 1; }
[ -f "$RUN" ]  || { echo "run.sh not found at $RUN"; exit 1; }

# A well-formed, ramp-consistent estimate (trivial bug → all low → all sonnet).
EST_TRIVIAL='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"deviations":[],"estimatorModel":"opus"}'

# === Behavior 1: estimate.json produced, valid schema, all keys ============
r1="$(new_repo)"
file_with_estimate "$r1" "$EST_TRIVIAL"
m1="$(MDIR "$r1")"
check "1a. file.sh exits 0"                 "[ -f '$m1/state.json' ]"
check "1b. estimate.json exists"            "[ -f '$m1/estimate.json' ]"
check "1c. estimate.json has schemaVersion 3" "grep -q '\"schemaVersion\": *3' '$m1/estimate.json'"
check "1d. reasoningCriticality present (enum)" \
  "grep -Eq '\"reasoningCriticality\": *\"(low|medium|high)\"' '$m1/estimate.json'"
check "1e. implCriticality present (enum)" \
  "grep -Eq '\"implCriticality\": *\"(low|medium|high)\"' '$m1/estimate.json'"
for k in research validate plan planReview implement verify; do
  check "1f. models.$k present, sonnet|opus" \
    "[ -n \"\$(sed -En 's/.*\"$k\"[[:space:]]*:[[:space:]]*\"(sonnet|opus)\".*/\1/p' '$m1/estimate.json' | head -1)\" ]"
done

# === Behavior 2: high-reasoning fixture ⇒ research/validate = opus (ramp) ====
# The worker (stub) emits the ramp-correct map for a high-reasoning mission.
EST_HIGH='{"schemaVersion":1,"reasoningCriticality":"high","implCriticality":"low","models":{"research":"opus","validate":"opus","plan":"opus","planReview":"opus","implement":"sonnet","verify":"sonnet"},"deviations":[],"estimatorModel":"opus"}'
r2="$(new_repo)"
file_with_estimate "$r2" "$EST_HIGH"
m2="$(MDIR "$r2")"
check "2a. high reasoning ⇒ research=opus (persisted)" \
  "[ \"\$(sed -En 's/.*\"research\"[[:space:]]*:[[:space:]]*\"([a-z]*)\".*/\1/p' '$m2/estimate.json' | head -1)\" = 'opus' ]"
check "2b. high reasoning ⇒ validate=opus (persisted)" \
  "[ \"\$(sed -En 's/.*\"validate\"[[:space:]]*:[[:space:]]*\"([a-z]*)\".*/\1/p' '$m2/estimate.json' | head -1)\" = 'opus' ]"
check "2c. reasoningCriticality recorded high" \
  "grep -q '\"reasoningCriticality\": *\"high\"' '$m2/estimate.json'"

# === Behavior 3: a recorded deviation survives into estimate.json ============
EST_DEV='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"opus","verify":"sonnet"},"deviations":["implement: subtle concurrency despite low overall criticality"],"estimatorModel":"opus"}'
r3="$(new_repo)"
file_with_estimate "$r3" "$EST_DEV"
m3="$(MDIR "$r3")"
check "3a. deviation string survives into estimate.json" \
  "grep -q 'implement: subtle concurrency' '$m3/estimate.json'"
check "3b. the deviated tier (implement=opus) is persisted" \
  "[ \"\$(sed -En 's/.*\"implement\"[[:space:]]*:[[:space:]]*\"([a-z]*)\".*/\1/p' '$m3/estimate.json' | head -1)\" = 'opus' ]"

# === Behavior 4: estimator unavailable/invalid ⇒ mission STILL files =========
# 4a — worker produces NO file at all.
r4="$(new_repo)"
rc4=0; file_with_estimate "$r4" "NONE" || rc4=$?
m4="$(MDIR "$r4")"
check "4a. file.sh still exits 0 when estimator produces nothing" "[ '$rc4' -eq 0 ]"
check "4b. mission still filed (state.json written)" "[ -f '$m4/state.json' ]"
check "4c. no estimate.json when worker produced nothing" "[ ! -f '$m4/estimate.json' ]"
check "4d. readout still printed (Mission filed line)" \
  "grep -q 'Mission filed:' '$r4/file.out'"
check "4e. an estimator note is surfaced (degradation parity)" \
  "grep -qi 'estimator' '$r4/file.out'"

# 4f — worker produces INVALID JSON (bad enum) ⇒ rejected, still files.
EST_BAD='{"schemaVersion":1,"reasoningCriticality":"banana","implCriticality":"low","models":{"research":"sonnet"}}'
r4b="$(new_repo)"
rc4b=0; file_with_estimate "$r4b" "$EST_BAD" || rc4b=$?
m4b="$(MDIR "$r4b")"
check "4f. invalid estimate ⇒ file.sh still exits 0" "[ '$rc4b' -eq 0 ]"
check "4g. invalid estimate ⇒ no estimate.json persisted" "[ ! -f '$m4b/estimate.json' ]"
check "4h. invalid estimate ⇒ mission still filed" "[ -f '$m4b/state.json' ]"

# 4i — run.sh driver missing entirely ⇒ still files (parity).
r4c="$(new_repo)"
prd4c="$r4c/prd.md"; write_prd "$prd4c"
rc4c=0
( cd "$r4c" && env -u CLAUDECODE CLAUDECODE=1 \
    LCARS_RUN_BIN="$r4c/no-such-run.sh" \
    LCARS_GH_BIN="$r4c/no-gh" LCARS_DATE=20260613 \
    bash "$FILE" --prd "$prd4c" >"$r4c/file.out" 2>&1 ) || rc4c=$?
check "4i. missing run.sh driver ⇒ file.sh still exits 0" "[ '$rc4c' -eq 0 ]"
check "4j. missing run.sh driver ⇒ mission still filed" \
  "[ -f '$(MDIR "$r4c")/state.json' ]"

# === Behavior 5: estimate.json drives S58's resolver end-to-end =============
# Reuse the high fixture's mission (m2) — but the resolver reads estimate.json by
# $MISSION_DIR, and m2 lives under r2's git dir. Drive resolve-stage-model and
# spawn-stage against r2's mission for both claude and copilot.
rsm5() { # repo key  [extra env...]
  local repo="$1" key="$2"; shift 2
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" resolve-stage-model --mission lcars-20260613-001-c10e "$key" 2>/dev/null )
}
sm_model() { sed -En 's/.*model=(.*)$/\1/p' | sed 's/^-$//'; }
model_of() { awk '/^--model$/{getline; print; exit}'; }

# claude active: high fixture → research=opus, implement=sonnet.
check "5a. claude research → opus (from estimate.json)" \
  "[ \"\$(rsm5 \"$r2\" research CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "5b. claude implement → sonnet (from estimate.json)" \
  "[ \"\$(rsm5 \"$r2\" implement CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"

# copilot active (S78): OPUS-SAFE — BOTH tiers resolve to claude-opus-4.8 (the
# copilot create-tool can't overwrite on a non-opus tier → Implement breaks).
check "5c. copilot research → claude-opus-4.8 (opus tier)" \
  "[ \"\$(rsm5 \"$r2\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "5d. copilot implement → claude-opus-4.8 (sonnet tier, opus-safe default)" \
  "[ \"\$(rsm5 \"$r2\" implement COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"

# And the SAME via the real spawned argv through a recording stub.
spawn5() { # repo role
  local repo="$1" role="$2"; shift 2
  local stub="$repo/argv-stub"; make_argv_stub "$stub"
  local argv="$repo/argv.out"
  ( cd "$repo" && STUB_ARGV="$argv" env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      "$@" STUB_ARGV="$argv" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=claude \
      bash "$RUN" spawn-stage --mission lcars-20260613-001-c10e "$role" >/dev/null 2>&1 )
  cat "$argv" 2>/dev/null
}
check "5e. spawn research-questions argv carries --model opus" \
  "[ \"\$(spawn5 \"$r2\" research-questions CLAUDECODE=1 | model_of)\" = 'opus' ]"
check "5f. spawn implement-tdd argv carries --model sonnet" \
  "[ \"\$(spawn5 \"$r2\" implement-tdd CLAUDECODE=1 | model_of)\" = 'sonnet' ]"

# === Behavior 6: a quote/newline-bearing rationale round-trips to valid JSON ==
# The worker's rationale may carry embedded double-quotes (quoting code or the
# captain) and escaped newlines. json_scoped_str DECODES the value, so the
# canonical re-emit MUST re-escape bare quotes — else estimate.json is invalid
# JSON (the S69 escaping discipline; S74 added the logged-bug path that hits it).
EST_QUOTED='{"schemaVersion":1,"reasoningCriticality":"medium","implCriticality":"high","models":{"research":"opus","validate":"opus","plan":"opus","planReview":"sonnet","implement":"opus","verify":"sonnet"},"rationale":"He said \"fix it\" — paragraph one.\n\nParagraph two: a tab\there and a closing quote: \".","deviations":[],"estimatorModel":"opus"}'
r6="$(new_repo)"
file_with_estimate "$r6" "$EST_QUOTED"
m6="$(MDIR "$r6")"
check "6a. quoted-rationale estimate.json exists" "[ -f '$m6/estimate.json' ]"
check "6b. quoted-rationale estimate.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m6/estimate.json'"
check "6c. the rationale text survives (its words are present)" \
  "grep -q 'paragraph one' '$m6/estimate.json' && grep -q 'Paragraph two' '$m6/estimate.json'"

# === Behavior 7: BUG-AWARE estimator (S74 follow-up) =========================
# A LOGGED BUG fast-tracks straight to Plan — it NEVER runs Research or Validate
# (see skills/lcars-log/log.sh: child state.json stage="plan", type="bug"). The
# estimator's worker prompt still scores all six stages, but the HARNESS must
# canonicalize a bug's estimate.json down to ONLY the stages it runs:
#   plan, planReview, implement, verify   (research + validate excluded)
# from models / tokenEstimates / requestEstimates AND from the computed cost.
# A NON-bug (feature) mission keeps all six stages — byte-identical to today.
#
# qgrep: a pipe-friendly grep so a check can read a captured blob without a temp.
# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

# Plant a mission dir directly (prd.md + a chosen-type state.json), then drive
# the REAL `run.sh estimate` with the canned-estimate stub as the cold worker.
# $1=repo  $2=mission-type ("bug"|"feature")  $3=estimate-body  [extra env...]
estimate_typed_mission() { # repo type est-body [env...]
  local repo="$1" mtype="$2" est="$3"; shift 3
  local stub="$repo/estimator-stub"; make_estimator_stub "$stub"
  local mid="lcars-typed-001"
  local mdir="$repo/.git/lcars/missions/$mid"
  mkdir -p "$mdir"
  write_prd "$mdir/prd.md"
  printf '{ "id": "%s", "stage": "plan", "type": "%s" }\n' "$mid" "$mtype" >"$mdir/state.json"
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      CLAUDECODE=1 \
      STUB_ESTIMATE="$est" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=claude \
      LCARS_GH_BIN="$repo/definitely-no-gh" \
      "$@" \
      bash "$RUN" estimate --mission "$mid" >"$repo/est.out" 2>&1 )
  printf '%s' "$mdir/estimate.json"
}

# A six-stage fixture with deterministic per-stage TOKEN + REQUEST estimates so
# the 4-stage-vs-6-stage cost arithmetic is hand-checkable. Every stage = opus.
#   claude usd per stage: tokens * (0.8*5 + 0.2*25) / 1e6 = tokens * 9 / 1e6
#     low tokens 1,000,000 ⇒ $9/stage ; high 2,000,000 ⇒ $18/stage
#     six stages: low=54  high=108 ; four stages: low=36  high=72
#   copilot legacy premiumRequests per stage: requests * 27 (opus mult)
#     low 1 req ⇒ 27/stage ; high 2 req ⇒ 54/stage
#     six stages: low=162 high=324 ; four stages: low=108 high=216
EST_COSTED='{"schemaVersion":1,"reasoningCriticality":"high","implCriticality":"high","models":{"research":"opus","validate":"opus","plan":"opus","planReview":"opus","implement":"opus","verify":"opus"},"tokenEstimates":{"research":{"low":1000000,"high":2000000},"validate":{"low":1000000,"high":2000000},"plan":{"low":1000000,"high":2000000},"planReview":{"low":1000000,"high":2000000},"implement":{"low":1000000,"high":2000000},"verify":{"low":1000000,"high":2000000}},"requestEstimates":{"research":{"low":1,"high":2},"validate":{"low":1,"high":2},"plan":{"low":1,"high":2},"planReview":{"low":1,"high":2},"implement":{"low":1,"high":2},"verify":{"low":1,"high":2}},"deviations":[],"rationale":"costed fixture","estimatorModel":"opus"}'

# 7. BUG mission ⇒ research + validate are EXCLUDED from the canonical file.
r7="$(new_repo)"
e7="$(estimate_typed_mission "$r7" bug "$EST_COSTED")"
check "7a. bug estimate.json exists"      "[ -f '$e7' ]"
check "7b. bug estimate.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e7'"
# models: plan/planReview/implement/verify present; research/validate gone.
check "7c. bug models has plan/planReview/implement/verify" \
  "python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"models\"]; sys.exit(0 if set(m)=={\"plan\",\"planReview\",\"implement\",\"verify\"} else 1)' '$e7'"
check "7d. bug tokenEstimates excludes research+validate" \
  "python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))[\"tokenEstimates\"]; sys.exit(0 if set(t)=={\"plan\",\"planReview\",\"implement\",\"verify\"} else 1)' '$e7'"
check "7e. bug requestEstimates excludes research+validate" \
  "python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))[\"requestEstimates\"]; sys.exit(0 if set(t)=={\"plan\",\"planReview\",\"implement\",\"verify\"} else 1)' '$e7'"
# cost (claude usd): 4-stage sum = low 36, high 72 (NOT the six-stage 54/108).
check "7f. bug claude cost.usd.low == 36 (4-stage sum)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"usd\"]; sys.exit(0 if float(c[\"low\"])==36 else 1)' '$e7'"
check "7g. bug claude cost.usd.high == 72 (4-stage sum)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"usd\"]; sys.exit(0 if float(c[\"high\"])==72 else 1)' '$e7'"
check "7h. bug cost is LESS than the six-stage sum (54/108)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"usd\"]; sys.exit(0 if float(c[\"low\"])<54 and float(c[\"high\"])<108 else 1)' '$e7'"

# 8. FEATURE mission ⇒ all six stages, full six-stage cost (regression guard).
r8="$(new_repo)"
e8="$(estimate_typed_mission "$r8" feature "$EST_COSTED")"
check "8a. feature estimate.json exists"  "[ -f '$e8' ]"
check "8b. feature models keeps all six stages" \
  "python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"models\"]; sys.exit(0 if set(m)=={\"research\",\"validate\",\"plan\",\"planReview\",\"implement\",\"verify\"} else 1)' '$e8'"
check "8c. feature tokenEstimates keeps all six stages" \
  "python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))[\"tokenEstimates\"]; sys.exit(0 if len(t)==6 else 1)' '$e8'"
check "8d. feature claude cost.usd == 54/108 (full six-stage sum)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"usd\"]; sys.exit(0 if float(c[\"low\"])==54 and float(c[\"high\"])==108 else 1)' '$e8'"

# 8f. A type="bug" mission STILL AT stage="align" (a regular `lcars file` bug,
#     NOT a logged fast-tracked one) runs the FULL pipeline — research+validate
#     are NOT skipped. The skip is keyed on the logged-bug signal (type==bug AND
#     stage==plan), so a filed bug at align must keep all six stages.
r8c="$(new_repo)"
mid8c="lcars-typed-001"; mdir8c="$r8c/.git/lcars/missions/$mid8c"
mkdir -p "$mdir8c"; write_prd "$mdir8c/prd.md"
printf '{ "id": "%s", "stage": "align", "type": "bug" }\n' "$mid8c" >"$mdir8c/state.json"
stub8c="$r8c/estimator-stub"; make_estimator_stub "$stub8c"
( cd "$r8c" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
    CLAUDECODE=1 STUB_ESTIMATE="$EST_COSTED" \
    LCARS_WORKER_BIN="$stub8c" LCARS_WORKER_CLI=claude \
    LCARS_GH_BIN="$r8c/definitely-no-gh" \
    bash "$RUN" estimate --mission "$mid8c" >"$r8c/est.out" 2>&1 )
check "8f. filed bug at stage=align keeps all six stages (NOT fast-tracked)" \
  "python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"models\"]; sys.exit(0 if len(m)==6 else 1)' '$mdir8c/estimate.json'"

# 8e. A mission with NO type key behaves exactly like a feature (full six).
r8b="$(new_repo)"
mid8b="lcars-typed-001"; mdir8b="$r8b/.git/lcars/missions/$mid8b"
mkdir -p "$mdir8b"; write_prd "$mdir8b/prd.md"
printf '{ "id": "%s", "stage": "plan" }\n' "$mid8b" >"$mdir8b/state.json"
stub8b="$r8b/estimator-stub"; make_estimator_stub "$stub8b"
( cd "$r8b" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
    CLAUDECODE=1 STUB_ESTIMATE="$EST_COSTED" \
    LCARS_WORKER_BIN="$stub8b" LCARS_WORKER_CLI=claude \
    LCARS_GH_BIN="$r8b/definitely-no-gh" \
    bash "$RUN" estimate --mission "$mid8b" >"$r8b/est.out" 2>&1 )
check "8e. typeless mission keeps all six stages (default = full pipeline)" \
  "python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"models\"]; sys.exit(0 if len(m)==6 else 1)' '$mdir8b/estimate.json'"

# 9. COPILOT legacy billing: a bug sums premiumRequests over ONLY the 4 stages.
r9="$(new_repo)"
# Pin legacy billing on this repo so the deterministic multiplier math applies.
# S183: keeps new_repo's testCommand — this rewrite of the config would
# otherwise strip the test foundation and `lcars file` would refuse.
printf '{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "copilotBilling": "legacy", "created": "2026-01-01T00:00:00Z" }\n' \
  >"$r9/.git/lcars/config.json"
e9="$(estimate_typed_mission "$r9" bug "$EST_COSTED" LCARS_WORKER_CLI=copilot COPILOT_RUN_APP=1)"
check "9a. copilot bug estimate.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e9'"
check "9b. copilot bug premiumRequests.low == 108 (4-stage sum)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"premiumRequests\"]; sys.exit(0 if float(c[\"low\"])==108 else 1)' '$e9'"
check "9c. copilot bug premiumRequests.high == 216 (4-stage sum)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"premiumRequests\"]; sys.exit(0 if float(c[\"high\"])==216 else 1)' '$e9'"
check "9d. copilot bug premiumRequests LESS than six-stage (162/324)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"premiumRequests\"]; sys.exit(0 if float(c[\"low\"])<162 and float(c[\"high\"])<324 else 1)' '$e9'"

# 9e. COPILOT legacy FEATURE keeps the full six-stage premiumRequests (162/324).
r9b="$(new_repo)"
# S183: keeps new_repo's testCommand — this rewrite of the config would
# otherwise strip the test foundation and `lcars file` would refuse.
printf '{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "copilotBilling": "legacy", "created": "2026-01-01T00:00:00Z" }\n' \
  >"$r9b/.git/lcars/config.json"
e9b="$(estimate_typed_mission "$r9b" feature "$EST_COSTED" LCARS_WORKER_CLI=copilot COPILOT_RUN_APP=1)"
check "9e. copilot feature premiumRequests == 162/324 (full six-stage)" \
  "python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))[\"cost\"][\"premiumRequests\"]; sys.exit(0 if float(c[\"low\"])==162 and float(c[\"high\"])==324 else 1)' '$e9b'"

# === Behavior 10: robust JSON-string escaping for ALL worker string fields ===
# (S69) The harness hand-builds estimate.json with printf and only partially
# escaped one field. A stray char in rationale / a deviations[] entry /
# estimatorModel could emit INVALID JSON on disk (the S67 local board adapter
# then loses that Mission's pills). Every worker-derived STRING field must
# round-trip through a REAL JSON encoder so the on-disk file is always valid.
#
# A python json-value extractor for asserting a string field's decoded value.
jval() { # file dotted.path → decoded value to stdout
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if k.isdigit() and isinstance(d,list): d=d[int(k)]
    else: d=d[k]
sys.stdout.write(d if isinstance(d,str) else json.dumps(d))
' "$1" "$2"
}

# 10a/b/c — rationale with an embedded quote AND a literal newline.
# In JSON source the newline is the escape \n; json_scoped_str leaves it as the
# two chars backslash-n, and rationale must re-encode to a valid \n token.
EST_RNL='{"schemaVersion":1,"reasoningCriticality":"medium","implCriticality":"high","models":{"research":"opus","validate":"opus","plan":"opus","planReview":"sonnet","implement":"opus","verify":"sonnet"},"rationale":"Quote: \"alpha\".\n\nLine two here.","deviations":[],"estimatorModel":"opus"}'
r10="$(new_repo)"
e10="$(estimate_typed_mission "$r10" feature "$EST_RNL")"
check "10a. quote+newline rationale ⇒ estimate.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e10'"
check "10b. quote+newline rationale ⇒ the quote text survives" \
  "[ \"\$(jval '$e10' rationale | head -1)\" = 'Quote: \"alpha\".' ]"
check "10c. quote+newline rationale ⇒ a real newline is present in the value" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"rationale\"]; sys.exit(0 if \"\n\" in r and \"alpha\" in r and \"Line two\" in r else 1)' '$e10'"

# 10d/e — a BACKSLASH (and JSON-hostile chars) in rationale AND a deviations[]
# entry. In JSON source a backslash is \\; json_scoped_str decodes it to one \,
# which must be re-encoded back to \\ (else invalid JSON).
EST_BSLASH='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"rationale":"path C:\\\\temp\\\\x and a tab\\there","deviations":["regex \\\\d+ matched","quoted \"thing\" inside"],"estimatorModel":"opus"}'
r11="$(new_repo)"
e11="$(estimate_typed_mission "$r11" feature "$EST_BSLASH")"
check "10d. backslash-in-rationale ⇒ estimate.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e11'"
check "10e. backslash rationale value preserved (a literal backslash survives)" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"rationale\"]; sys.exit(0 if \"C:\\\\\\\\temp\" in r else 1)' '$e11'"
check "10f. backslash-bearing deviations[] entry preserved" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"deviations\"]; sys.exit(0 if any(\"d+\" in x and \"regex\" in x for x in d) else 1)' '$e11'"
check "10g. quote-bearing deviations[] entry preserved" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"deviations\"]; sys.exit(0 if any(\"thing\" in x for x in d) else 1)' '$e11'"

# 10h/i — a deviations[] entry carrying a quote and a newline → valid JSON, kept.
EST_DEVNL='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"deviations":["implement: said \"race\"\nplus a second line"],"estimatorModel":"opus"}'
r12="$(new_repo)"
e12="$(estimate_typed_mission "$r12" feature "$EST_DEVNL")"
check "10h. quote+newline deviations[] entry ⇒ VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e12'"
check "10i. quote+newline deviations[] entry preserved" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"deviations\"]; sys.exit(0 if any(\"race\" in x and \"second line\" in x for x in d) else 1)' '$e12'"

# 10j — a JSON-hostile estimatorModel string → valid JSON, value preserved.
EST_EM='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"deviations":[],"rationale":"ok","estimatorModel":"weird\"model\\name"}'
r13="$(new_repo)"
e13="$(estimate_typed_mission "$r13" feature "$EST_EM")"
check "10j. hostile estimatorModel ⇒ VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e13'"
check "10k. hostile estimatorModel value preserved" \
  "python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"estimatorModel\"]; sys.exit(0 if \"weird\" in m and \"model\" in m else 1)' '$e13'"

# 10l — REGRESSION: a clean estimate stays byte-for-byte equivalent to before.
# We compare a clean fixture rendered today against a captured golden so a future
# encoder change can't silently alter the on-disk bytes for normal input.
# (EST_COSTED is a clean six-stage feature fixture with a plain rationale.)
r14="$(new_repo)"
e14="$(estimate_typed_mission "$r14" feature "$EST_COSTED")"
check "10l. clean estimate ⇒ VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$e14'"
check "10m. clean estimate ⇒ plain rationale is the simple printf form (no over-escaping)" \
  "grep -q '\"rationale\": \"costed fixture\",' '$e14'"
check "10n. clean estimate ⇒ estimatorModel is the simple printf form" \
  "grep -q '\"estimatorModel\": \"opus\"' '$e14'"
# A clean single deviation must render exactly as the old printf would.
EST_CLEANDEV='{"schemaVersion":1,"reasoningCriticality":"low","implCriticality":"low","models":{"research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet"},"deviations":["implement: subtle concurrency"],"rationale":"plain text","estimatorModel":"opus"}'
r15="$(new_repo)"
e15="$(estimate_typed_mission "$r15" feature "$EST_CLEANDEV")"
check "10o. clean deviation ⇒ rendered as a plain quoted token" \
  "grep -q '\"deviations\": \\[ \"implement: subtle concurrency\" \\],' '$e15'"

# 10p — truly unrecoverable model output ⇒ NO malformed estimate.json written
# (degrades the documented way: bad enum → rejected → no file).
EST_JUNK='{"schemaVersion":1,"reasoningCriticality":"nope","models":{}}'
r16="$(new_repo)"
file_with_estimate "$r16" "$EST_JUNK" || true
m16="$(MDIR "$r16")"
check "10p. unrecoverable output ⇒ no estimate.json (clean degrade)" \
  "[ ! -f '$m16/estimate.json' ]"

echo "estimate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
