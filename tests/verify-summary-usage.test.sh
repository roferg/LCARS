#!/usr/bin/env bash
#
# S113 — the Verify pre-ship readout shows ACTUAL cost beside the ESTIMATE.
#
# `run.sh verify-summary` prints the captain's pre-ship summary. This round adds
# a "Cost: EST … → ACTUAL …" line, computed DISPLAY-ONLY from the S112 usage.json
# (JSONL — one code-costed record per cold-worker spawn) beside the estimate.json
# band. The invariants proven here:
#   1. usage.json present (claude/usd)     → EST → ACTUAL line, usd, exact total.
#   2. usage.json present (copilot legacy) → ACTUAL renders in premium reqs.
#   3. one `source":"unavailable"` record  → ACTUAL marked "· partial".
#   4. NO usage.json                       → NO cost line at all (byte-identical).
#
# This is a FAST, self-contained test: it hand-builds a minimal verify mission
# (git repo + state@verify + waves.json + result.json + estimate.json + usage.json)
# and drives ONLY `verify-summary` (no worker spawn, no model). NEVER run the full
# lcars-run suite for this.
#
# Usage: bash tests/verify-summary-usage.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
MID="lcars-20260530-001"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

make_gh_stub() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# Build a minimal repo with a mission parked at verify, four green tickets, an
# estimate.json, and (optionally) a usage.json. `$2` = estimate cost cli
# ("claude"/"copilot"), `$3..` = usage.json JSONL lines (none ⇒ no usage.json).
new_verify_repo() { # cli-and-cost-block-selector  [usage-lines...]
  local sel="$1"; shift
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{ "id": "$MID", "type": "feature", "title": "Add dark mode",
  "stage": "verify", "created": "2026-05-30T10:00:00Z",
  "model": "claude", "githubIssue": 42,
  "branch": "lcars/$MID", "base": "main" }
EOF
  # NOTE: parse_waves_table is line-oriented (one "wave"/"id" key per line), so
  # the fixture must keep each field on its own line.
  cat >"$m/waves.json" <<'EOF'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": 101 },
      { "id": "t-002", "issue": 102 } ] },
  { "wave": 2, "tickets": [
      { "id": "t-003", "issue": 103 },
      { "id": "t-004", "issue": 104 } ] }
]
EOF
  local tid
  for tid in t-001 t-002 t-003 t-004; do
    mkdir -p "$m/tickets/$tid"
    printf '{ "ticketId": "%s", "passed": true, "attempts": 2 }\n' "$tid" >"$m/tickets/$tid/result.json"
  done
  if [ "$sel" = "copilot" ]; then
    cat >"$m/estimate.json" <<'EOF'
{ "schemaVersion": 3, "reasoningCriticality": "low", "implCriticality": "medium",
  "cost": { "cli": "copilot", "unit": "premiumRequests", "billing": "legacy",
            "premiumRequests": { "low": 10, "high": 14 } } }
EOF
  else
    cat >"$m/estimate.json" <<'EOF'
{ "schemaVersion": 3, "reasoningCriticality": "medium", "implCriticality": "high",
  "cost": { "cli": "claude", "unit": "usd", "currency": "USD",
            "usd": { "low": 4.2, "high": 6.4 } } }
EOF
  fi
  if [ "$#" -gt 0 ]; then
    : >"$m/usage.json"
    local line
    for line in "$@"; do printf '%s\n' "$line" >>"$m/usage.json"; done
  fi
  echo "$repo"
}

run_summary() { # repo → captures stdout to $OUT, rc to $RC
  OUT="$1/out.txt"; RC=0
  ( cd "$1" && LCARS_GH_BIN="$1/gh" bash "$SCRIPT" verify-summary --mission "$MID" >"$OUT" 2>&1 ) || RC=$?
}

# ── 1. claude / usd: 0.05 + 0.10 = $0.15 ──────────────────────────────────────
repo1="$(new_verify_repo claude \
  '{"stage":"research","billingUnit":"usd","source":"session-transcript","costUsd":0.05,"cost":0.05}' \
  '{"stage":"plan","billingUnit":"usd","source":"session-transcript","costUsd":0.10,"cost":0.10}')"
make_gh_stub "$repo1/gh"
run_summary "$repo1"
check "1. verify-summary exits 0 with usage present" "[ '$RC' -eq 0 ]"
check "1. prints the EST → ACTUAL cost line" "grep -q 'EST .* → ACTUAL' '$OUT'"
check "1. EST band is the claude estimate (\$4.20–\$6.40)" "grep -qF 'EST \$4.20–\$6.40' '$OUT'"
check "1. ACTUAL is the summed usd total (\$0.15)" "grep -qF 'ACTUAL \$0.15' '$OUT'"

# ── 2. copilot legacy: 10 + 5 = 15 premium reqs ──────────────────────────────
repo2="$(new_verify_repo copilot \
  '{"stage":"research","billingUnit":"premiumRequests","source":"session-state","premiumRequests":10,"costUsd":0.40}' \
  '{"stage":"plan","billingUnit":"premiumRequests","source":"session-state","premiumRequests":5,"costUsd":0.20}')"
make_gh_stub "$repo2/gh"
run_summary "$repo2"
check "2. copilot-legacy ACTUAL renders in premium reqs (~15 reqs)" "grep -qF 'ACTUAL ~15 reqs' '$OUT'"
check "2. copilot-legacy EST renders in premium reqs too (same unit)" "grep -q 'EST ~10–14 premium reqs' '$OUT'"

# ── 3. partial: one stage unavailable → "· partial" marker ───────────────────
repo3="$(new_verify_repo claude \
  '{"stage":"research","billingUnit":"usd","source":"session-transcript","costUsd":0.05,"cost":0.05}' \
  '{"stage":"plan","billingUnit":"usd","source":"unavailable"}')"
make_gh_stub "$repo3/gh"
run_summary "$repo3"
check "3. a partial capture marks ACTUAL '· partial'" "grep -qF 'ACTUAL \$0.05 · partial' '$OUT'"

# ── 4. NO usage.json → NO cost line (byte-identical to before this round) ─────
repo4="$(new_verify_repo claude)"   # no usage lines ⇒ no usage.json written
make_gh_stub "$repo4/gh"
run_summary "$repo4"
check "4. exits 0 without usage.json" "[ '$RC' -eq 0 ]"
check "4. NO 'Cost:' line at all when usage.json is absent" "! grep -q 'Cost:' '$OUT'"
check "4. NO 'ACTUAL' text at all when usage.json is absent" "! grep -q 'ACTUAL' '$OUT'"
# and the pre-existing readout is intact.
check "4. still prints the test tally (4/4 green)" "grep -q '4/4' '$OUT'"

echo
echo "verify-summary-usage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
