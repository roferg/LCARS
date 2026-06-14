#!/usr/bin/env bash
#
# Tests for the Session-61 `render-estimate` subcommand of lcars-run (run.sh).
#
# `render-estimate` turns a mission's estimate.json into a captain-facing block,
# in the ACTIVE CLI's native cost unit, for one of two surfaces:
#   --surface issue → a markdown "## Estimate" section (criticality scores, a
#                     per-stage model table, the cost line, the rationale) that
#                     lcars-file appends to the GitHub issue body.
#   --surface cli   → a compact, two-space-indented readout block (a one-line
#                     Estimate summary with the scores + cost, a model-mix line,
#                     a one-line rationale) that lcars-file echoes to stdout.
#
# The cost unit tracks the active CLI: claude → "$X–$Y"; copilot → premium
# requests (+ overage band when available, or "unavailable" when multipliers
# aren't set). It reuses run.sh's own JSON helpers + cost_compute, so we plant a
# fixture estimate.json and assert the rendered text. We NEVER call a real model.
#
# Behaviors:
#   1. issue surface (claude): "## Estimate", both scores, a per-stage model
#      table (each stage → Sonnet/Opus), the "$X–$Y" cost line, the rationale.
#   2. cli surface (claude): compact Estimate summary line with scores + "$"
#      cost range, a model-mix line, a one-line rationale.
#   3. copilot active: BOTH surfaces render cost as premium requests (+ overage
#      band when available), NOT a "$" range as the primary unit.
#   4. copilot multipliers unavailable: BOTH surfaces say "unavailable", never a
#      bogus request count.
#   5. estimate.json ABSENT: prints nothing, exits non-zero (file.sh degradation).
#
# Usage: bash tests/render-estimate.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260613-001"
new_repo_with_estimate() { # estimate-body|NONE → repo path
  local est="$1"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions/$MID"
  printf '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null }\n' \
    >"$repo/.git/lcars/config.json"
  [ "$est" = "NONE" ] || printf '%s\n' "$est" >"$repo/.git/lcars/missions/$MID/estimate.json"
  printf '%s' "$repo"
}

render() { # repo surface [extra env...]
  local repo="$1" surface="$2"; shift 2
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" render-estimate --mission "$MID" --surface "$surface" 2>/dev/null )
}

echo "render-estimate (session 61)"
[ -f "$RUN" ] || { echo "run.sh not found at $RUN"; exit 1; }

# A mixed-tier fixture: research/implement opus, the rest sonnet. The cost.test.sh
# hand-calc applies (claude low≈3.618 high≈7.236; copilot low=198 high=396,
# overage low=7.92 high=15.84).
EST='{
  "schemaVersion": 2,
  "reasoningCriticality": "high",
  "implCriticality": "medium",
  "models": { "research":"opus","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"opus","verify":"sonnet" },
  "tokenEstimates": {
    "research":{"low":100000,"high":200000},
    "validate":{"low":50000,"high":100000},
    "plan":{"low":50000,"high":100000},
    "planReview":{"low":50000,"high":100000},
    "implement":{"low":200000,"high":400000},
    "verify":{"low":20000,"high":40000}
  },
  "requestEstimates": {
    "research":{"low":2,"high":4},
    "validate":{"low":1,"high":2},
    "plan":{"low":1,"high":2},
    "planReview":{"low":1,"high":2},
    "implement":{"low":4,"high":8},
    "verify":{"low":1,"high":2}
  },
  "deviations": [],
  "rationale": "High-criticality feature touching core contracts; routine implementation.",
  "estimatorModel": "opus"
}'

# === Behavior 1: issue surface, claude active ================================
r1="$(new_repo_with_estimate "$EST")"
iss1="$(render "$r1" issue CLAUDECODE=1)"
check "1a. issue surface has the '## Estimate' heading" \
  "printf '%s' \"\$iss1\" | grep -q '## Estimate'"
check "1b. issue surface shows reasoning=high" \
  "printf '%s' \"\$iss1\" | grep -qi 'reasoning'  && printf '%s' \"\$iss1\" | grep -qi 'high'"
check "1c. issue surface shows implementation=medium" \
  "printf '%s' \"\$iss1\" | grep -qi 'implementation' && printf '%s' \"\$iss1\" | grep -qi 'medium'"
check "1d. issue surface names each stage in the model table (research)" \
  "printf '%s' \"\$iss1\" | grep -qi 'research'"
check "1e. issue surface maps a stage to Opus and another to Sonnet" \
  "printf '%s' \"\$iss1\" | grep -qi 'Opus' && printf '%s' \"\$iss1\" | grep -qi 'Sonnet'"
check "1f. issue surface shows the \$ cost range (low and high)" \
  "printf '%s' \"\$iss1\" | grep -q '3.6' && printf '%s' \"\$iss1\" | grep -q '7.2'"
check "1g. issue surface carries the rationale text" \
  "printf '%s' \"\$iss1\" | grep -qi 'core contracts'"
check "1h. issue surface uses a \$ sign for claude cost" \
  "printf '%s' \"\$iss1\" | grep -q '[$]'"

# === Behavior 2: cli surface, claude active =================================
cli2="$(render "$r1" cli CLAUDECODE=1)"
check "2a. cli surface has a compact Estimate summary line" \
  "printf '%s' \"\$cli2\" | grep -qi 'Estimate:'"
check "2b. cli summary names both criticalities" \
  "printf '%s' \"\$cli2\" | grep -qi 'reasoning' && printf '%s' \"\$cli2\" | grep -qi 'implementation'"
check "2c. cli summary shows the \$ cost range" \
  "printf '%s' \"\$cli2\" | grep -q '3.6' && printf '%s' \"\$cli2\" | grep -q '7.2'"
check "2d. cli surface has a model-mix line (research)" \
  "printf '%s' \"\$cli2\" | grep -qi 'research'"
check "2e. cli surface is two-space indented" \
  "printf '%s' \"\$cli2\" | grep -q '^  '"

# === Behavior 3: copilot active ⇒ premium requests on BOTH surfaces ==========
r3="$(new_repo_with_estimate "$EST")"
iss3="$(render "$r3" issue COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
cli3="$(render "$r3" cli COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "3a. issue surface shows premium requests (198/396)" \
  "printf '%s' \"\$iss3\" | grep -q '198' && printf '%s' \"\$iss3\" | grep -q '396'"
check "3b. issue surface mentions premium requests" \
  "printf '%s' \"\$iss3\" | grep -qi 'premium'"
check "3c. issue surface shows the \$ overage band (7.92/15.84)" \
  "printf '%s' \"\$iss3\" | grep -q '7.92' && printf '%s' \"\$iss3\" | grep -q '15.84'"
check "3d. cli surface shows premium requests (198/396)" \
  "printf '%s' \"\$cli3\" | grep -q '198' && printf '%s' \"\$cli3\" | grep -q '396'"
check "3e. cli surface mentions premium reqs" \
  "printf '%s' \"\$cli3\" | grep -qi 'premium'"

# === Behavior 4: copilot multipliers unavailable ⇒ both say 'unavailable' ====
PRICING_NULL="$TMPROOT/pricing-null.json"
cat >"$PRICING_NULL" <<'EOF'
{
  "claude": { "opus": {"inputPerMTok":5,"outputPerMTok":25}, "sonnet":{"inputPerMTok":3,"outputPerMTok":15} },
  "copilot": { "opus": {"premiumRequestMultiplier":null}, "sonnet":{"premiumRequestMultiplier":null}, "overagePerRequest":null }
}
EOF
r4="$(new_repo_with_estimate "$EST")"
iss4="$(render "$r4" issue COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_NULL")"
cli4="$(render "$r4" cli COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_NULL")"
check "4a. issue surface says cost unavailable" \
  "printf '%s' \"\$iss4\" | grep -qi 'unavailable'"
check "4b. issue surface prints no bogus request count" \
  "! printf '%s' \"\$iss4\" | grep -q '198'"
check "4c. cli surface says cost unavailable" \
  "printf '%s' \"\$cli4\" | grep -qi 'unavailable'"
check "4d. cli surface never doubles the word cost" \
  "! printf '%s' \"\$cli4\" | grep -qi 'cost cost'"
check "4e. cli summary line mentions cost exactly once" \
  "[ \"\$(printf '%s' \"\$cli4\" | grep -i 'Estimate:' | grep -oi 'cost' | wc -l | tr -d ' ')\" = '1' ]"

# === Behavior 5: estimate.json absent ⇒ nothing printed, non-zero exit =======
r5="$(new_repo_with_estimate "NONE")"
rc5=0
out5="$(render "$r5" issue CLAUDECODE=1)" || rc5=$?
check "5a. absent estimate.json ⇒ non-zero exit" "[ '$rc5' -ne 0 ]"
check "5b. absent estimate.json ⇒ no output" "[ -z \"\$out5\" ]"

echo "render-estimate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
