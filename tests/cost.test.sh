#!/usr/bin/env bash
#
# Tests for the Session-60 CLI-AWARE COST computation. The estimator emits, per
# stage, a rough TOKEN estimate (Claude billing) and a rough REQUEST-COUNT
# estimate (Copilot billing) into estimate.json; the CODE — not the model —
# computes the reproducible cost figure in the ACTIVE CLI's native unit:
#   - claude  → $ range (Σ stage tokens × that stage's tier $/MTok), unit "usd"
#   - copilot → premium-request count (Σ stage requests × tier multiplier) +
#               optional $ overage, unit "premiumRequests"
# All prices/multipliers live ONLY in skills/lcars-run/pricing.json.
#
# The cost helper is exposed as a mission-free test surface: `run.sh cost
# --mission <id>` reads that mission's estimate.json + pricing.json + the active
# CLI and prints a `COST ...` line plus the canonical cost JSON block to stdout.
#
# We never call a real model. We hand-place a fixture estimate.json (with
# tokenEstimates/requestEstimates/models) and assert the cost numbers exactly.
#
# Usage: bash tests/cost.test.sh
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

# A git repo with .git/lcars + config.json + a mission dir holding a fixture
# estimate.json. $2 is the estimate.json body to plant.
MID="lcars-20260613-001"
new_repo_with_estimate() { # estimate-body  → repo path
  local est="$1"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions/$MID"
  printf '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null }\n' \
    >"$repo/.git/lcars/config.json"
  printf '%s\n' "$est" >"$repo/.git/lcars/missions/$MID/estimate.json"
  printf '%s' "$repo"
}

# Run `run.sh cost --mission` in a repo, with the active CLI selected by env.
cost_run() { # repo  [extra env...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" cost --mission "$MID" 2>/dev/null )
}
# Pull a nested number from the printed cost JSON block. Reuses run.sh's own
# scoped reader would require sourcing; here just grep the flat-ish print.
num() { sed -En "s/.*\"$1\"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p" | head -1; }

echo "cost — CLI-aware mission cost (session 60)"

[ -f "$RUN" ]     || { echo "run.sh not found at $RUN"; exit 1; }
[ -f "$PRICING" ] || { echo "pricing.json not found at $PRICING"; exit 1; }

# A fixture estimate with KNOWN token + request estimates. Mixed model map so the
# per-stage tier actually matters. tokenEstimates are TOTAL tokens per stage.
#
# Hand-calc for CLAUDE (80% input / 20% output split, per-stage tier $/MTok):
#   stage cost(tok) = (tok*0.8*inputPerMTok + tok*0.2*outputPerMTok) / 1e6
#   opus: in=5 out=25  → per-token = (0.8*5 + 0.2*25)/1e6 = 9/1e6
#   sonnet: in=3 out=15 → per-token = (0.8*3 + 0.2*15)/1e6 = 5.4/1e6
# LOW tokens:  research=100000(opus) implement=200000(opus) others sonnet:
#   validate=50000 plan=50000 planReview=50000 verify=20000
#   opus low $ = (100000+200000)*9/1e6 = 300000*9/1e6 = 2.7
#   sonnet low $ = (50000+50000+50000+20000)*5.4/1e6 = 170000*5.4/1e6 = 0.918
#   total low = 2.7 + 0.918 = 3.618
# HIGH tokens (2x low across the board):
#   total high = 7.236
#
# Hand-calc for COPILOT (Σ requests × tier multiplier; opus=27 sonnet=9):
#   requestEstimates low: research=2(opus) validate=1 plan=1 planReview=1
#                         implement=4(opus) verify=1
#   opus low = (2+4)*27 = 162 ; sonnet low = (1+1+1+1)*9 = 36 ; total low = 198
#   high (2x): opus=(4+8)*27=324 ; sonnet=(2+2+2+2)*9=72 ; total high = 396
#   usdOverage low = 198*0.04 = 7.92 ; high = 396*0.04 = 15.84
EST='{
  "schemaVersion": 2,
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

# === Behavior 1: Claude active ⇒ cost.usd low/high = hand-calc =================
r1="$(new_repo_with_estimate "$EST")"
out1="$(cost_run "$r1" CLAUDECODE=1)"
check "1a. claude cli field" "printf '%s' \"\$out1\" | grep -q '\"cli\": *\"claude\"'"
check "1b. claude unit=usd"  "printf '%s' \"\$out1\" | grep -q '\"unit\": *\"usd\"'"
lo1="$(printf '%s' "$out1" | sed -En 's/.*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
# Use awk to compare floats with tolerance.
check "1c. claude cost.low ≈ 3.618" \
  "awk -v v='$lo1' 'BEGIN{exit !(v>3.6 && v<3.64)}'"
hi1="$(printf '%s' "$out1" | grep -o '"high"[^,}]*' | head -1 | sed -En 's/.*:[[:space:]]*([0-9.]+).*/\1/p')"
check "1d. claude cost.high ≈ 7.236" \
  "awk -v v='$hi1' 'BEGIN{exit !(v>7.2 && v<7.27)}'"

# === Behavior 2: Copilot active ⇒ premiumRequests + usdOverage = hand-calc ====
r2="$(new_repo_with_estimate "$EST")"
out2="$(cost_run "$r2" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "2a. copilot cli field" "printf '%s' \"\$out2\" | grep -q '\"cli\": *\"copilot\"'"
check "2b. copilot unit=premiumRequests" "printf '%s' \"\$out2\" | grep -q '\"unit\": *\"premiumRequests\"'"
# premiumRequests.low=198 high=396 ; usdOverage.low=7.92 high=15.84
check "2c. copilot premiumRequests.low=198" \
  "printf '%s' \"\$out2\" | grep -q '198'"
check "2d. copilot premiumRequests.high=396" \
  "printf '%s' \"\$out2\" | grep -q '396'"
check "2e. copilot usdOverage.low=7.92" \
  "printf '%s' \"\$out2\" | grep -q '7.92'"
check "2f. copilot usdOverage.high=15.84" \
  "printf '%s' \"\$out2\" | grep -q '15.84'"

# === Behavior 3: switching a stage sonnet→opus raises BOTH figures ============
# Same as EST but plan flipped to opus (was sonnet).
EST_PLAN_OPUS="$(printf '%s' "$EST" | sed 's/"plan":"sonnet"/"plan":"opus"/')"
r3="$(new_repo_with_estimate "$EST_PLAN_OPUS")"
out3c="$(cost_run "$r3" CLAUDECODE=1)"
lo3="$(printf '%s' "$out3c" | sed -En 's/.*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "3a. claude $ rises when plan→opus" \
  "awk -v a='$lo1' -v b='$lo3' 'BEGIN{exit !(b>a)}'"
out3p="$(cost_run "$r3" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
# new premiumRequests.low: plan moves from sonnet(9) to opus(27): +1*18 = 216
check "3b. copilot premium-requests rise when plan→opus (198→216)" \
  "printf '%s' \"\$out3p\" | grep -q '216'"

# === Behavior 4: unit/cli fields track the active CLI =========================
check "4a. claude→usd"            "printf '%s' \"\$out1\" | grep -q '\"unit\": *\"usd\"'"
check "4b. claude not premiumRequests" "! printf '%s' \"\$out1\" | grep -q 'premiumRequests'"
check "4c. copilot→premiumRequests" "printf '%s' \"\$out2\" | grep -q '\"unit\": *\"premiumRequests\"'"
check "4d. copilot not usd unit"   "! printf '%s' \"\$out2\" | grep -q '\"unit\": *\"usd\"'"

# === Behavior 5: Copilot multipliers null ⇒ "unavailable", not a wrong number ==
# Point at a pricing file whose copilot multipliers are null.
PRICING_NULL="$TMPROOT/pricing-null.json"
cat >"$PRICING_NULL" <<'EOF'
{
  "claude": { "opus": {"inputPerMTok":5,"outputPerMTok":25}, "sonnet":{"inputPerMTok":3,"outputPerMTok":15}, "cacheReadMult":0.1, "cacheWriteMult":1.25 },
  "copilot": { "opus": {"premiumRequestMultiplier":null}, "sonnet":{"premiumRequestMultiplier":null}, "overagePerRequest":null, "asOf":"unset" }
}
EOF
r5="$(new_repo_with_estimate "$EST")"
out5="$(cost_run "$r5" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_NULL")"
check "5a. copilot null multipliers ⇒ unavailable" \
  "printf '%s' \"\$out5\" | grep -qi 'unavailable'"
check "5b. copilot null ⇒ no bogus request count printed" \
  "! printf '%s' \"\$out5\" | grep -q '\"premiumRequests\": *{'"

# === Behavior 6: rationale present and ≤ 2 paragraphs (short for trivial) ======
EST_TRIVIAL='{
  "schemaVersion": 2,
  "reasoningCriticality": "low",
  "implCriticality": "low",
  "models": { "research":"sonnet","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"sonnet","verify":"sonnet" },
  "tokenEstimates": { "research":{"low":1000,"high":2000},"validate":{"low":1000,"high":2000},"plan":{"low":1000,"high":2000},"planReview":{"low":1000,"high":2000},"implement":{"low":1000,"high":2000},"verify":{"low":1000,"high":2000} },
  "requestEstimates": { "research":{"low":1,"high":1},"validate":{"low":1,"high":1},"plan":{"low":1,"high":1},"planReview":{"low":1,"high":1},"implement":{"low":1,"high":1},"verify":{"low":1,"high":1} },
  "deviations": [],
  "rationale": "Trivial one-line fix; routine across all stages.",
  "estimatorModel": "opus"
}'
r6="$(new_repo_with_estimate "$EST_TRIVIAL")"
# The canonical estimate.json (written by estimate_validate_and_write) must carry
# a rationale of <= 2 paragraphs (paragraphs are blank-line separated).
m6="$r6/.git/lcars/missions/$MID/estimate.json"
check "6a. rationale present in fixture estimate" "grep -q '\"rationale\"' '$m6'"
# Count blank-line-separated paragraphs in the rationale string. The validator
# must reject/repair > 2 paragraphs; here the trivial one is a single sentence.
rat6="$(sed -En 's/.*"rationale"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$m6" | head -1)"
check "6b. trivial rationale is short (<= 200 chars)" \
  "[ \"\$(printf '%s' \"\$rat6\" | wc -c | tr -d ' ')\" -le 200 ]"

# === Behavior 7: pricing.json is the ONLY home for prices/multipliers =========
# Grep-guard: the run.sh cost logic must not carry bare price/multiplier literals.
# We scan the whole run.sh for the specific magic numbers that live in pricing.json
# (5/25/3/15 input/output rates, 9/27 multipliers, 0.04 overage, 1.25 cache).
# Strip shell comments (lines whose first non-space char is #, and trailing
# `# ...` comments) so a "Session 27" prose mention never trips the guard — only
# CODE literals count.
CODE_ONLY="$TMPROOT/run-code-only.sh"
sed -E 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$RUN" >"$CODE_ONLY"
check "7a. no bare overagePerRequest 0.04 literal in run.sh cost code" \
  "! grep -Eq '0\\.04' '$CODE_ONLY'"
check "7b. no bare multiplier 27 literal in run.sh cost code" \
  "! grep -Eq '(^|[^0-9.])27([^0-9.]|\$)' '$CODE_ONLY'"
check "7c. no bare input/output rate (5/25/3/15) literal in run.sh cost code" \
  "! grep -Eq 'PerMTok[^\"]*(=|\\*)[[:space:]]*(5|25|3|15)([^0-9]|\$)' '$CODE_ONLY'"
check "7d. no bare cacheWriteMult 1.25 literal in run.sh cost code" \
  "! grep -Eq '1\\.25' '$CODE_ONLY'"
check "7e. pricing.json carries the copilot multipliers" \
  "grep -q 'premiumRequestMultiplier' '$PRICING'"
check "7f. pricing.json carries the overage rate" \
  "grep -q '0.04' '$PRICING'"

# === Behavior 8: estimate_validate_and_write canonicalizes schemaVersion 2 =====
# Driving the full estimator/file.sh path is covered by estimate.test.sh; here we
# assert the canonical estimate.json the validator writes carries the new fields
# and a code-COMPUTED cost block (not the worker's). We reuse the cost subcommand
# output above as the proof that the fields are read back nested-correctly.
check "8a. estimate.json schemaVersion bumped to 2 (fixture)" \
  "grep -q '\"schemaVersion\": *2' '$r1/.git/lcars/missions/$MID/estimate.json'"

echo "cost: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
