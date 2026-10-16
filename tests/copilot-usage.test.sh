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
# Usage cost uses the larger of token-priced and measured invocation workload
# bands per stage, plus estimator overhead, then nets the monthly allotment.
# Legacy stays Σ(requests × multiplier) verbatim.
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

# cost_field <cost-output> <dotted.path> → the value AT THAT PATH, or "".
# S147 round 2 (SMELL 9): bare `grep -q '270'` against the whole blob passes if
# the number turns up anywhere at all. Read the field it belongs in instead.
cost_field() { # cost-output dotted.path
  printf '%s' "$1" | "${LCARS_PYTHON_BIN:-python3}" -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
cur = d
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur:
        sys.exit(0)
    cur = cur[k]
print("" if cur is None else cur)
' "$2"
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

# Fixture: mixed model map. tokenEstimates identical to the Claude cost test.
# Per-token $/tok: opus=9/1e6, sonnet=5.4/1e6.
#   research=opus implement=opus ; validate/plan/planReview/verify=sonnet
#
# S147 DEFECT-3 MOVED THESE NUMBERS, AND THAT IS THE POINT. Copilot's
# alias_for_tier pins BOTH logical tiers to claude-opus-4.8 (the `create`-tool
# safety policy), so the "sonnet" stages have ALWAYS actually run opus — while
# being BILLED at sonnet rates. That understated band is a live-observed defect:
# a copilot mission estimated $0.42–$1.25 came in at $2.99 gross. Costing now
# follows effective_tier_for_cli, so every stage bills opus:
#   Workload-adjusted stage LOW: .9 + .45 + .575 + .45 + 6.6 + .18
#   HIGH: 7.1 + 3.95 + 14.15 + 4.25 + 214 + .36
#   Estimator overhead .275/.6 gives gross 9.43/244.41.
# The OLD mixed figures (3.618/7.236) priced sonnet legs this engine never runs.
# Claude's own cost test still asserts 3.618/7.236 — its tiers round-trip.
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
# usd low 9.43 / high 244.41 (see hand-calc); includedCreditsUsd 10;
# netUsd low 0 / high 234.41.
r1="$(new_repo "$EST")"
out1="$(cost_run "$r1" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "1a. copilot cli field" "printf '%s' \"\$out1\" | grep -q '\"cli\": *\"copilot\"'"
check "1b. unit=usd"          "printf '%s' \"\$out1\" | grep -q '\"unit\": *\"usd\"'"
check "1c. billing=usage"     "printf '%s' \"\$out1\" | grep -q '\"billing\": *\"usage\"'"
ulo1="$(printf '%s' "$out1" | sed -En 's/.*"usd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "1d. usage usd.low ≈ 9.43 (workload floors, opus)" "awk -v v='$ulo1' 'BEGIN{exit !(v>9.429 && v<9.431)}'"
uhi1="$(printf '%s' "$out1" | sed -En 's/.*"usd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "1e. usage usd.high ≈ 244.41 (workload floors, opus)" "awk -v v='$uhi1' 'BEGIN{exit !(v>244.409 && v<244.411)}'"
check "1f. includedCreditsUsd present" "printf '%s' \"\$out1\" | grep -q 'includedCreditsUsd'"

# === Behavior 6: DEFAULT selection (no copilotBilling key) ⇒ usage, NOT legacy ==
check "6a. default copilot ⇒ usage (not premiumRequests)" \
  "! printf '%s' \"\$out1\" | grep -q 'premiumRequests'"

# === Behavior 5: allotment netting ============================================
# pro = $10 included. Gross 9.43–244.41 ⇒ netUsd 0/234.41.
nlo1="$(printf '%s' "$out1" | sed -En 's/.*"netUsd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
nhi1="$(printf '%s' "$out1" | sed -En 's/.*"netUsd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "5a. sub-allotment ⇒ netUsd.low 0"  "awk -v v='$nlo1' 'BEGIN{exit !(v==0)}'"
check "5b. high above allotment ⇒ netUsd.high 234.41" "awk -v v='$nhi1' 'BEGIN{exit !(v>234.409 && v<234.411)}'"

# Over-allotment: a tiny plan via config so the mission cost exceeds it. Use a
# pricing override whose pro allotment is 100 credits ($1), so both bounds exceed it.
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
# included $1; netUsd.low = 9.43-1 = 8.43; netUsd.high = 244.41-1 = 243.41
n5lo="$(printf '%s' "$out5" | sed -En 's/.*"netUsd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
n5hi="$(printf '%s' "$out5" | sed -En 's/.*"netUsd"[^}]*"high"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "5c. over-allotment netUsd.low ≈ 8.43"  "awk -v v='$n5lo' 'BEGIN{exit !(v>8.429 && v<8.431)}'"
check "5d. over-allotment netUsd.high ≈ 243.41" "awk -v v='$n5hi' 'BEGIN{exit !(v>243.409 && v<243.411)}'"

# === Behavior 2: copilot + legacy ⇒ S60 premium-request figure BYTE-FOR-BYTE ===
# config copilotBilling=legacy. Same hand-calc as cost.test.sh:
#   premiumRequests.low 270 high 540 ; usdOverage.low 10.80 high 21.60
#   (all-opus multiplier — same S147 DEFECT-3 reason as the usage figures above)
r2="$(new_repo "$EST" ', "copilotBilling": "legacy"')"
out2="$(cost_run "$r2" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "2a. legacy unit=premiumRequests" "printf '%s' \"\$out2\" | grep -q '\"unit\": *\"premiumRequests\"'"
check "2b. legacy billing field"        "printf '%s' \"\$out2\" | grep -q '\"billing\": *\"legacy\"'"
check "2c. legacy premiumRequests.low 270"  "[ \"\$(cost_field \"\$out2\" premiumRequests.low)\" = '270' ]"
check "2d. legacy premiumRequests.high 540" "[ \"\$(cost_field \"\$out2\" premiumRequests.high)\" = '540' ]"
check "2e. legacy usdOverage.low 10.8"      "awk -v v=\"\$(cost_field \"\$out2\" usdOverage.low)\" 'BEGIN{exit !(v>10.79 && v<10.81)}'"
check "2f. legacy usdOverage.high 21.6"    "awk -v v=\"\$(cost_field \"\$out2\" usdOverage.high)\" 'BEGIN{exit !(v>21.59 && v<21.61)}'"
check "2g. legacy ⇒ no netUsd"           "! printf '%s' \"\$out2\" | grep -q 'netUsd'"

# === Behavior 3: on COPILOT the estimator tier does NOT move the cost ==========
# S147 DEFECT-3: copilot pins every stage to opus, so flipping plan sonnet→opus
# changes nothing here. That INVARIANCE is the honest behaviour; the tier axis is
# still asserted on the claude path (tests/cost.test.sh 3a).
EST_PLAN_OPUS="$(printf '%s' "$EST" | sed 's/"plan":"sonnet"/"plan":"opus"/')"
r3="$(new_repo "$EST_PLAN_OPUS")"
out3="$(cost_run "$r3" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
ulo3="$(printf '%s' "$out3" | sed -En 's/.*"usd"[^}]*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "3a. usage $ is tier-INVARIANT on copilot (opus-pinned)" "awk -v a='$ulo1' -v b='$ulo3' 'BEGIN{exit !(b==a)}'"

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

# Copilot usage USD also 2dp on the surfaces. This assertion is about the 2dp
# RENDER, not the magnitude — and the magnitude moved with S147 DEFECT-3: the
# all-sonnet fixture bills opus and includes invocation workload floors, giving
# 3.867497/44.507003; Claude's same fixture stays $0.48 (d2-a above).
rdc="$(new_repo "$EST_RAGGED")"
rissc="$(render_run "$rdc" issue COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "d2-g. copilot usage issue shows \$3.87 (2dp)" "printf '%s' \"\$rissc\" | grep -q '\\\$3.87'"
check "d2-h. copilot usage issue does NOT show the ragged 3.867497" \
  "! printf '%s' \"\$rissc\" | grep -q '3.8674'"
check "d2-h. copilot usage issue no ragged 0.477"    "! printf '%s' \"\$rissc\" | grep -q '0.477'"

# === schemaVersion 3 canonicalization =========================================
check "sv-a. canonical estimate.json schemaVersion 3" \
  "grep -q '\"schemaVersion\": *3' '$r1/.git/lcars/missions/$MID/estimate.json'"

echo "copilot-usage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
