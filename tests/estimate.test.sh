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
#      BOTH claude and copilot (copilot opus→claude-opus-4.8, sonnet→claude-sonnet-4.6).
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
  printf '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "created": "2026-01-01T00:00:00Z" }\n' \
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

MDIR() { printf '%s/.git/lcars/missions/lcars-20260613-001' "$1"; }

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
      "$@" bash "$RUN" resolve-stage-model --mission lcars-20260613-001 "$key" 2>/dev/null )
}
sm_model() { sed -En 's/.*model=(.*)$/\1/p' | sed 's/^-$//'; }
model_of() { awk '/^--model$/{getline; print; exit}'; }

# claude active: high fixture → research=opus, implement=sonnet.
check "5a. claude research → opus (from estimate.json)" \
  "[ \"\$(rsm5 \"$r2\" research CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "5b. claude implement → sonnet (from estimate.json)" \
  "[ \"\$(rsm5 \"$r2\" implement CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"

# copilot active: opus tier → claude-opus-4.8, sonnet tier → claude-sonnet-4.6.
check "5c. copilot research → claude-opus-4.8 (opus tier)" \
  "[ \"\$(rsm5 \"$r2\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "5d. copilot implement → claude-sonnet-4.6 (sonnet tier)" \
  "[ \"\$(rsm5 \"$r2\" implement COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-sonnet-4.6' ]"

# And the SAME via the real spawned argv through a recording stub.
spawn5() { # repo role
  local repo="$1" role="$2"; shift 2
  local stub="$repo/argv-stub"; make_argv_stub "$stub"
  local argv="$repo/argv.out"
  ( cd "$repo" && STUB_ARGV="$argv" env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      "$@" STUB_ARGV="$argv" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=claude \
      bash "$RUN" spawn-stage --mission lcars-20260613-001 "$role" >/dev/null 2>&1 )
  cat "$argv" 2>/dev/null
}
check "5e. spawn research-questions argv carries --model opus" \
  "[ \"\$(spawn5 \"$r2\" research-questions CLAUDECODE=1 | model_of)\" = 'opus' ]"
check "5f. spawn implement-implementer argv carries --model sonnet" \
  "[ \"\$(spawn5 \"$r2\" implement-implementer CLAUDECODE=1 | model_of)\" = 'sonnet' ]"

echo "estimate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
