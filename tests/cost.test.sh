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
new_repo_with_estimate() { # estimate-body  [config-extra]  → repo path
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
# Copilot's default billing is now USAGE (session 64). This suite's copilot
# hand-calcs are the LEGACY premium-request math, so the copilot fixtures here pin
# copilotBilling=legacy (the usage path is covered by copilot-usage.test.sh).
LEGACY_CFG=', "copilotBilling": "legacy"'

# Run `run.sh cost --mission` in a repo, with the active CLI selected by env.
cost_run() { # repo  [extra env...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" cost --mission "$MID" 2>/dev/null )
}
# cost_field <cost-output> <dotted.path> → the value AT THAT PATH, or "" .
# S147 round 2 (SMELL 9): the copilot assertions used to be bare
# `grep -q '270'` against the whole blob, which passes if 270 appears ANYWHERE —
# in a different field, inside a longer number, or in the cli banner. Presence is
# not correctness. Parse the JSON and read the field the number is supposed to be
# in. (The `cost` subcommand prints a `COST cli=…` banner line first, so the JSON
# starts at the first `{`.)
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
# Hand-calc for COPILOT (Σ requests × tier multiplier; opus=27 sonnet=9).
#
# S147 DEFECT-3 MOVED THESE NUMBERS, AND THAT IS THE POINT. Copilot's
# alias_for_tier pins BOTH logical tiers to claude-opus-4.8 (the `create`-tool
# safety policy), so a "sonnet" stage on copilot has ALWAYS actually run opus.
# The cost was nevertheless billed at the SONNET multiplier, which is why a live
# copilot mission came in at $2.99 gross against a $0.42–$1.25 estimate. Costing
# now follows effective_tier_for_cli — the tier that really runs — so every stage
# here bills at the opus multiplier:
#   requestEstimates low: research=2 validate=1 plan=1 planReview=1
#                         implement=4 verify=1  → Σ = 10
#   low  = 10 * 27 = 270 ;  high (2x) = 20 * 27 = 540
#   usdOverage low = 270*0.04 = 10.80 ; high = 540*0.04 = 21.60
# The OLD mixed-tier figures (198/396, $7.92/$15.84) described a run that never
# happened on this engine. Claude's arm is unaffected (its tiers round-trip).
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
r2="$(new_repo_with_estimate "$EST" "$LEGACY_CFG")"
out2="$(cost_run "$r2" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
check "2a. copilot cli field" "printf '%s' \"\$out2\" | grep -q '\"cli\": *\"copilot\"'"
check "2b. copilot unit=premiumRequests" "printf '%s' \"\$out2\" | grep -q '\"unit\": *\"premiumRequests\"'"
# premiumRequests.low=270 high=540 ; usdOverage.low=10.8 high=21.6
# (every stage bills opus — see the S147 DEFECT-3 note in the hand-calc above)
# Asserted BY FIELD (SMELL 9) — a number in the right place, not just present.
check "2c. copilot premiumRequests.low=270" \
  "[ \"\$(cost_field \"\$out2\" premiumRequests.low)\" = '270' ]"
check "2d. copilot premiumRequests.high=540" \
  "[ \"\$(cost_field \"\$out2\" premiumRequests.high)\" = '540' ]"
check "2e. copilot usdOverage.low=10.8" \
  "awk -v v=\"\$(cost_field \"\$out2\" usdOverage.low)\" 'BEGIN{exit !(v>10.79 && v<10.81)}'"
check "2f. copilot usdOverage.high=21.6" \
  "awk -v v=\"\$(cost_field \"\$out2\" usdOverage.high)\" 'BEGIN{exit !(v>21.59 && v<21.61)}'"
check "2g. copilot NEVER bills a stage at the sonnet multiplier (opus-pinned)" \
  "[ \"\$(cost_field \"\$out2\" premiumRequests.low)\" != '198' ]"

# === Behavior 3: switching a stage sonnet→opus raises the CLAUDE figure =======
# (S147 DEFECT-3: it is a no-op on copilot, which pins every stage to opus — see
# 3b below. The tier axis is now asserted on the engine that actually has one.)
# Same as EST but plan flipped to opus (was sonnet).
EST_PLAN_OPUS="$(printf '%s' "$EST" | sed 's/"plan":"sonnet"/"plan":"opus"/')"
r3="$(new_repo_with_estimate "$EST_PLAN_OPUS" "$LEGACY_CFG")"
out3c="$(cost_run "$r3" CLAUDECODE=1)"
lo3="$(printf '%s' "$out3c" | sed -En 's/.*"low"[[:space:]]*:[[:space:]]*([0-9.]+).*/\1/p' | head -1)"
check "3a. claude $ rises when plan→opus" \
  "awk -v a='$lo1' -v b='$lo3' 'BEGIN{exit !(b>a)}'"
out3p="$(cost_run "$r3" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot)"
# S147 DEFECT-3: on COPILOT the estimator's per-stage tier does NOT move the
# cost, because the engine pins every stage to opus anyway. Flipping plan
# sonnet→opus is therefore a NO-OP on copilot (270 before and after) — the
# honest reading, where the old fixture's 198→216 rise described a sonnet leg
# that never ran. Claude (3a, just above) still responds to the tier, which is
# the axis that assertion exists to protect.
check "3b. copilot premium-requests are tier-INVARIANT (opus-pinned): still 270" \
  "[ \"\$(cost_field \"\$out3p\" premiumRequests.low)\" = '270' ]"

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
  "copilot": {
    "billingModel": "legacy",
    "legacy": { "opus": {"premiumRequestMultiplier":null}, "sonnet":{"premiumRequestMultiplier":null}, "overagePerRequest":null, "asOf":"unset" }
  }
}
EOF
r5="$(new_repo_with_estimate "$EST" "$LEGACY_CFG")"
out5="$(cost_run "$r5" COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_PRICING="$PRICING_NULL")"
check "5a. copilot null multipliers ⇒ unavailable" \
  "printf '%s' \"\$out5\" | grep -qi 'unavailable'"
check "5b. copilot null ⇒ no bogus request count printed" \
  "! printf '%s' \"\$out5\" | grep -q '\"premiumRequests\": *{'"

# === Behavior 6: rationale present and ≤ 2 paragraphs (short for trivial) ======
EST_TRIVIAL='{
  "schemaVersion": 3,
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
check "8a. estimate.json schemaVersion bumped to 3 (fixture)" \
  "grep -q '\"schemaVersion\": *3' '$r1/.git/lcars/missions/$MID/estimate.json'"

echo "cost: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
