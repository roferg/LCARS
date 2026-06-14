#!/usr/bin/env bash
#
# Tests for Session-64: Copilot USAGE-BASED (token / GitHub AI Credits) billing,
# behind a config switch, with the legacy premium-request path preserved for
# grandfathered annual subscribers. Plus Deliverable-2: render USD to exactly two
# decimal places.
#
# GitHub moved Copilot to usage-based "AI Credits" (token) billing 2026-06-01:
#   1 AI credit = $0.01 USD. Per-tier token rates == the model's API rates:
#     sonnet: in $3 / out $15  ;  opus: in $5 / out $25  (per MTok)
#   Monthly included AI-credit allotment per plan (credits ×$0.01 = USD):
#     pro 1000 ($10) · proPlus 3900 ($39) · business 1900 ($19) · enterprise 3900 ($39)
#
# Usage-based cost is computed by the SAME math as the Claude branch (Σ stage
# tokens × tier rate, 0.8/0.2 input/output split), then the plan's monthly
# allotment is netted off. Legacy stays Σ(requests × multiplier) verbatim.
#
# We never call a real model — we hand-place a fixture estimate.json and assert
# the cost numbers exactly via `run.sh cost --mission <id>`.
#
# Usage: bash tests/copilot-usage.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
PRICING="$REPO_ROOT/skills/lcars-run/pricing.json"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260614-001"
# Build a git repo with .git/lcars + config.json + a mission dir holding a
# fixture estimate.json. $1 = estimate body; $2 = extra config json keys (raw,
# leading comma, may be empty).
new_repo() { # estimate-body  config-extra  → repo path
  local est="$1" cfgextra="${2:-}"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions/$MID"
  printf '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null%s }\n' \
    "$cfgextra" >"$repo/.git/lcars/config.json"
  printf '%s\n' "$est" >"$repo/.git/lcars/missions/$MID/estimate.json"
  printf '%s' "$repo"
}

cost_run() { # repo  [extra env...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" cost --mission "$MID" 2>/dev/null )
}

echo "copilot-usage — usage-based AI-Credit billing + legacy preserve (S64)"

[ -f "$RUN" ]     || { echo "run.sh not found at $RUN"; exit 1; }
[ -f "$PRICING" ] || { echo "pricing.json not found at $PRICING"; exit 1; }

# Fixture: mixed model map. tokenEstimates identical to the Claude cost test so
# the hand-calc is shared. Per-token $/tok: opus=9/1e6, sonnet=5.4/1e6.
#   research=opus implement=opus ; validate/plan/planReview/verify=sonnet
# LOW tokens:  research 100000 implement 200000 (opus) → 300000*9/1e6 = 2.7
#   sonnet 50000+50000+50000+20000 = 170000 *5.4/1e6 = 0.918 → total low 3.618
# HIGH (2x): total high 7.236
EST='{
  "schemaVersion": 3,
  "reasoningCriticality": "high",
  "implCriticality": "high",
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
  "rationale": "High-criticality feature touching core contracts.",
  "estimatorModel": "opus"
}'

# === Behavior 1: copilot + usage ⇒ token dollars, billing=usage ================
# DEFAULT config (no copilotBilling key) ⇒ usage. Default plan = pro (1000cr=$10).
# usd low 3.618 / high 7.236 ; includedCreditsUsd 10 ; netUsd both 0 (under plan).
r1="$(new_repo "$EST")"
out1="$(cost_run "$r1" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "1a. copilot cli field" "printf '%s' \"\$out1\" | grep -q '\"cli\": *\"copilot\"'"
check "1b. unit=usd"          "printf '%s' \"\$out1\" | grep -q '\"unit\": *\"usd\"'"
check "1c. billing=usage"     "printf '%s' \"\$out1\" | grep -q '\"billing\": *\"usage\"'"
ulo1="$(printf '%s' "$out1" | sed -En 's/.*"usd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "1d. usage usd.low ≈ 3.618" "awk -v v='$ulo1' 'BEGIN{exit !(v>3.6 && v<3.64)}'"
uhi1="$(printf '%s' "$out1" | sed -En 's/.*"usd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "1e. usage usd.high ≈ 7.236" "awk -v v='$uhi1' 'BEGIN{exit !(v>7.2 && v<7.27)}'"
check "1f. includedCreditsUsd present" "printf '%s' \"\$out1\" | grep -q 'includedCreditsUsd'"

# === Behavior 6: DEFAULT selection (no copilotBilling key) ⇒ usage, NOT legacy ==
check "6a. default copilot ⇒ usage (not premiumRequests)" \
  "! printf '%s' \"\$out1\" | grep -q 'premiumRequests'"

# === Behavior 5: allotment netting ============================================
# pro = $10 included. mission usd 3.618–7.236 fully under it ⇒ netUsd 0/0.
nlo1="$(printf '%s' "$out1" | sed -En 's/.*"netUsd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
nhi1="$(printf '%s' "$out1" | sed -En 's/.*"netUsd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "5a. sub-allotment ⇒ netUsd.low 0"  "awk -v v='$nlo1' 'BEGIN{exit !(v==0)}'"
check "5b. sub-allotment ⇒ netUsd.high 0" "awk -v v='$nhi1' 'BEGIN{exit !(v==0)}'"

# Over-allotment: a tiny plan via config so the mission cost exceeds it. Use a
# pricing override whose pro allotment is 100 credits ($1), so 3.618/7.236 > $1.
PRICING_SMALL="$TMPROOT/pricing-small.json"
cat >"$PRICING_SMALL" <<'EOF'
{
  "claude": { "opus": {"inputPerMTok":5,"outputPerMTok":25}, "sonnet":{"inputPerMTok":3,"outputPerMTok":15}, "cacheReadMult":0.1, "cacheWriteMult":1.25 },
  "copilot": {
    "billingModel": "usage",
    "usage": { "opus":{"inputPerMTok":5,"outputPerMTok":25}, "sonnet":{"inputPerMTok":3,"outputPerMTok":15},
               "creditUsd":0.01, "creditAllotmentByPlan":{"pro":100,"proPlus":3900,"business":1900,"enterprise":3900}, "asOf":"x" },
    "legacy": { "opus":{"premiumRequestMultiplier":27}, "sonnet":{"premiumRequestMultiplier":9}, "overagePerRequest":0.04, "asOf":"2026-06-13" }
  }
}
EOF
r5="$(new_repo "$EST")"
out5="$(cost_run "$r5" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_SMALL")"
# included $1 ; netUsd.low = 3.618-1 = 2.618 ; netUsd.high = 7.236-1 = 6.236
n5lo="$(printf '%s' "$out5" | sed -En 's/.*"netUsd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
n5hi="$(printf '%s' "$out5" | sed -En 's/.*"netUsd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "5c. over-allotment netUsd.low ≈ 2.618"  "awk -v v='$n5lo' 'BEGIN{exit !(v>2.6 && v<2.64)}'"
check "5d. over-allotment netUsd.high ≈ 6.236" "awk -v v='$n5hi' 'BEGIN{exit !(v>6.2 && v<6.27)}'"

# === Behavior 2: copilot + legacy ⇒ S60 premium-request figure BYTE-FOR-BYTE ===
# config copilotBilling=legacy. Same hand-calc as cost.test.sh:
#   premiumRequests.low 198 high 396 ; usdOverage.low 7.92 high 15.84
r2="$(new_repo "$EST" ', "copilotBilling": "legacy"')"
out2="$(cost_run "$r2" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "2a. legacy unit=premiumRequests" "printf '%s' \"\$out2\" | grep -q '\"unit\": *\"premiumRequests\"'"
check "2b. legacy billing field"        "printf '%s' \"\$out2\" | grep -q '\"billing\": *\"legacy\"'"
check "2c. legacy premiumRequests.low 198"  "printf '%s' \"\$out2\" | grep -q '198'"
check "2d. legacy premiumRequests.high 396" "printf '%s' \"\$out2\" | grep -q '396'"
check "2e. legacy usdOverage.low 7.92"      "printf '%s' \"\$out2\" | grep -q '7.92'"
check "2f. legacy usdOverage.high 15.84"    "printf '%s' \"\$out2\" | grep -q '15.84'"
check "2g. legacy ⇒ no netUsd"           "! printf '%s' \"\$out2\" | grep -q 'netUsd'"

# === Behavior 3: sonnet→opus on a stage raises usage $ =========================
EST_PLAN_OPUS="$(printf '%s' "$EST" | sed 's/"plan":"sonnet"/"plan":"opus"/')"
r3="$(new_repo "$EST_PLAN_OPUS")"
out3="$(cost_run "$r3" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
ulo3="$(printf '%s' "$out3" | sed -En 's/.*"usd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "3a. usage $ rises when plan→opus" "awk -v a='$ulo1' -v b='$ulo3' 'BEGIN{exit !(b>a)}'"

# === Behavior 4: copilot.usage rates unset/null ⇒ unavailable ==================
PRICING_NULL="$TMPROOT/pricing-null.json"
cat >"$PRICING_NULL" <<'EOF'
{
  "claude": { "opus": {"inputPerMTok":5,"outputPerMTok":25}, "sonnet":{"inputPerMTok":3,"outputPerMTok":15}, "cacheReadMult":0.1, "cacheWriteMult":1.25 },
  "copilot": {
    "billingModel": "usage",
    "usage": { "opus":{"inputPerMTok":null,"outputPerMTok":null}, "sonnet":{"inputPerMTok":null,"outputPerMTok":null},
               "creditUsd":0.01, "creditAllotmentByPlan":{"pro":1000,"proPlus":3900,"business":1900,"enterprise":3900}, "asOf":"unset" },
    "legacy": { "opus":{"premiumRequestMultiplier":27}, "sonnet":{"premiumRequestMultiplier":9}, "overagePerRequest":0.04, "asOf":"2026-06-13" }
  }
}
EOF
r4="$(new_repo "$EST")"
out4="$(cost_run "$r4" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_NULL")"
check "4a. null usage rates ⇒ unavailable" "printf '%s' \"\$out4\" | grep -qi 'unavailable'"
check "4b. null usage ⇒ no bogus usd band" "! printf '%s' \"\$out4\" | grep -q '\"usd\": *{'"

# === Behavior: plan selection nets the right allotment ========================
# copilotPlan=business ($19) ⇒ includedCreditsUsd 19 (1900 credits *0.01).
r7="$(new_repo "$EST" ', "copilotPlan": "business"')"
out7="$(cost_run "$r7" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
inc7="$(printf '%s' "$out7" | sed -En 's/.*"includedCreditsUsd"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "plan-a. business plan ⇒ includedCreditsUsd 19" "awk -v v='$inc7' 'BEGIN{exit !(v==19)}'"

# === Behavior 7: pricing.json is the ONLY home for rates/allotments ===========
CODE_ONLY="$TMPROOT/run-code-only.sh"
sed -E 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$RUN" >"$CODE_ONLY"
check "7a. no bare allotment 1900 literal in run.sh code" \
  "! grep -Eq '(^|[^0-9.])1900([^0-9.]|\$)' '$CODE_ONLY'"
check "7b. no bare allotment 3900 literal in run.sh code" \
  "! grep -Eq '(^|[^0-9.])3900([^0-9.]|\$)' '$CODE_ONLY'"
check "7c. no bare creditUsd 0.01 literal in run.sh code" \
  "! grep -Eq '0\\.01' '$CODE_ONLY'"
check "7d. pricing.json carries copilot.usage rates" \
  "grep -q 'creditAllotmentByPlan' '$PRICING'"
check "7e. pricing.json carries copilot.legacy multipliers" \
  "grep -q 'premiumRequestMultiplier' '$PRICING'"

# === Deliverable 2: USD rendered to EXACTLY two decimals ======================
# A fixture whose computed claude cost is 0.477 / 3.5892. Pick tokens so the
# claude branch yields those. We instead drive render-estimate and check the
# rendered surfaces show 2dp. Simpler: a fixture that produces ragged decimals.
# Use small sonnet tokens: per-tok sonnet = 5.4/1e6.
#   low: 88333 tokens *5.4/1e6 = 0.4769982 ≈ 0.477
#   We just need ragged output; assert the RENDERED issue/cli shows 2dp.
EST_RAGGED='{
  "schemaVersion": 3,
  "reasoningCriticality": "low",
  "implCriticality": "low",
  "models": { "research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet" },
  "tokenEstimates": {
    "research":{"low":88333,"high":664667},
    "validate":{"low":0,"high":0},
    "plan":{"low":0,"high":0},
    "planReview":{"low":0,"high":0},
    "implement":{"low":0,"high":0},
    "verify":{"low":0,"high":0}
  },
  "requestEstimates": {
    "research":{"low":1,"high":1},"validate":{"low":1,"high":1},"plan":{"low":1,"high":1},
    "planReview":{"low":1,"high":1},"implement":{"low":1,"high":1},"verify":{"low":1,"high":1}
  },
  "deviations": [],
  "rationale": "Tiny fix.",
  "estimatorModel": "opus"
}'
render_run() { # repo surface  [env...]
  local repo="$1" surface="$2"; shift 2
  ( cd "$repo" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" render-estimate --mission "$MID" --surface "$surface" 2>/dev/null )
}
rd="$(new_repo "$EST_RAGGED")"
# raw claude cost: low ~0.4769982, high ~3.5892018. Confirm the RENDER shows 2dp.
riss="$(render_run "$rd" issue CLAUDECODE=1)"
rcli="$(render_run "$rd" cli CLAUDECODE=1)"
check "d2-a. issue shows \$0.48 (2dp)"  "printf '%s' \"\$riss\" | grep -q '\\\$0.48'"
check "d2-b. issue shows \$3.59 (2dp)"  "printf '%s' \"\$riss\" | grep -q '\\\$3.59'"
check "d2-c. issue does NOT show ragged \$0.477"  "! printf '%s' \"\$riss\" | grep -q '0.477'"
check "d2-d. issue does NOT show ragged 3.5892"   "! printf '%s' \"\$riss\" | grep -q '3.5892'"
check "d2-e. cli readout shows \$0.48"  "printf '%s' \"\$rcli\" | grep -q '\\\$0.48'"
check "d2-f. cli readout shows \$3.59"  "printf '%s' \"\$rcli\" | grep -q '\\\$3.59'"

# Copilot usage USD also 2dp on the surfaces.
rdc="$(new_repo "$EST_RAGGED")"
rissc="$(render_run "$rdc" issue COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "d2-g. copilot usage issue shows \$0.48 (2dp)" "printf '%s' \"\$rissc\" | grep -q '\\\$0.48'"
check "d2-h. copilot usage issue no ragged 0.477"    "! printf '%s' \"\$rissc\" | grep -q '0.477'"

# === schemaVersion 3 canonicalization =========================================
check "sv-a. canonical estimate.json schemaVersion 3" \
  "grep -q '\"schemaVersion\": *3' '$r1/.git/lcars/missions/$MID/estimate.json'"

echo "copilot-usage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
