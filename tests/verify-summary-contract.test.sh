#!/usr/bin/env bash
#
# S134 — the Verify pre-ship readout shows the CONTRACT-CHANGES story.
#
# The S133 unified TDD Implementer proves each ticket with post-hoc gates and
# writes tickets/<id>/{result.json (v2), flip-flop.json, test-edits.json}. The
# Verify readout (`run.sh verify-summary`) surfaces, per ticket:
#   • new/changed test count + a flip-flop verdict chip (PROVEN / N/A + reason),
#   • declared test edits as a CONTRACT AMENDMENTS block ({path, reason} verbatim).
# Invariants proven here:
#   1. declared edits present → CONTRACT AMENDMENTS block, path+reason VERBATIM.
#   2. proofed but NO declared edits → exactly one quiet "no ... contract" line.
#   3. flip-flop N/A → chip reads N/A with the flipFlopReason shown.
#   4. pre-S133 mission (no flip-flop.json / test-edits.json) → BYTE-IDENTICAL to
#      today: no "Proof of work" / "CONTRACT AMENDMENTS" text at all.
#
# FAST + self-contained: hand-built verify missions, drives ONLY verify-summary
# (no worker spawn, no model). NEVER run the full lcars-run suite for this.
#
# Usage: bash tests/verify-summary-contract.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
MID="lcars-20260723-001"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

make_gh_stub() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# Build a verify mission with two green tickets. $1 = "proof" | "noproof".
#   proof   → each ticket carries v2 result + flip-flop.json + test-edits.json.
#   noproof → v1 result only (a pre-S133 mission).
new_repo() { # mode
  local mode="$1"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{ "id": "$MID", "type": "feature", "title": "Add dark mode",
  "stage": "verify", "created": "2026-07-23T10:00:00Z",
  "model": "claude", "githubIssue": 42,
  "branch": "lcars/$MID", "base": "main" }
EOF
  cat >"$m/waves.json" <<'EOF'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": 101 },
      { "id": "t-002", "issue": 102 } ] }
]
EOF
  local tid
  for tid in t-001 t-002; do mkdir -p "$m/tickets/$tid"; done
  if [ "$mode" = "noproof" ]; then
    printf '{ "ticketId": "t-001", "passed": true, "attempts": 2 }\n' >"$m/tickets/t-001/result.json"
    printf '{ "ticketId": "t-002", "passed": true, "attempts": 1 }\n' >"$m/tickets/t-002/result.json"
    echo "$repo"; return
  fi
  # t-001: honest new-test ticket, flip-flop PROVEN, no declared edits.
  cat >"$m/tickets/t-001/result.json" <<'EOF'
{ "ticketId": "t-001", "passed": true, "attempts": 2,
  "summary": "add toggle", "newTests": ["src/toggle.test.ts", "src/theme.test.ts"],
  "testEdits": [], "flipFlop": "expected" }
EOF
  cat >"$m/tickets/t-001/flip-flop.json" <<'EOF'
{ "ticketId": "t-001", "parentSha": "abc", "verdict": "pass",
  "reason": "tests GREEN on tip, RED on parent", "testFiles": ["src/toggle.test.ts"] }
EOF
  echo '[]' >"$m/tickets/t-001/test-edits.json"
  # t-002: adapts an existing test — a declared contract amendment.
  cat >"$m/tickets/t-002/result.json" <<'EOF'
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "wire persistence", "newTests": ["src/persist.test.ts"],
  "testEdits": [ { "path": "src/legacy.test.ts",
                   "reason": "the ticket changes the return shape from string to object" } ],
  "flipFlop": "expected" }
EOF
  cat >"$m/tickets/t-002/flip-flop.json" <<'EOF'
{ "ticketId": "t-002", "parentSha": "abc", "verdict": "pass",
  "reason": "tests GREEN on tip, RED on parent", "testFiles": ["src/persist.test.ts"] }
EOF
  cat >"$m/tickets/t-002/test-edits.json" <<'EOF'
[ { "path": "src/legacy.test.ts",
    "reason": "the ticket changes the return shape from string to object" } ]
EOF
  echo "$repo"
}

# Add a not-applicable ticket t-003 to a proof repo (flip-flop skipped).
add_na_ticket() { # repo
  local m="$1/.git/lcars/missions/$MID"
  mkdir -p "$m/tickets/t-003"
  cat >"$m/waves.json" <<'EOF'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": 101 },
      { "id": "t-002", "issue": 102 },
      { "id": "t-003", "issue": 103 } ] }
]
EOF
  cat >"$m/tickets/t-003/result.json" <<'EOF'
{ "ticketId": "t-003", "passed": true, "attempts": 1,
  "summary": "pure refactor", "newTests": [], "testEdits": [],
  "flipFlop": "not-applicable", "flipFlopReason": "pure rename, no behavior change" }
EOF
  cat >"$m/tickets/t-003/flip-flop.json" <<'EOF'
{ "ticketId": "t-003", "parentSha": "abc", "verdict": "skipped",
  "reason": "declared not-applicable: pure rename, no behavior change", "testFiles": [] }
EOF
  echo '[]' >"$m/tickets/t-003/test-edits.json"
}

run_summary() { # repo
  OUT="$1/out.txt"; RC=0
  ( cd "$1" && LCARS_GH_BIN="$1/gh" bash "$SCRIPT" verify-summary --mission "$MID" >"$OUT" 2>&1 ) || RC=$?
}

# ── 1. proofed mission WITH a declared edit → CONTRACT AMENDMENTS, verbatim ────
repo1="$(new_repo proof)"; make_gh_stub "$repo1/gh"; run_summary "$repo1"
check "1. exits 0" "[ '$RC' -eq 0 ]"
check "1. renders a CONTRACT AMENDMENTS block" "grep -qi 'CONTRACT AMENDMENTS' '$OUT'"
check "1. names the edited path" "grep -qF 'src/legacy.test.ts' '$OUT'"
check "1. shows the reason VERBATIM" "grep -qF 'the ticket changes the return shape from string to object' '$OUT'"
check "1. flip-flop PROVEN chip present" "grep -q 'PROVEN' '$OUT'"
check "1. shows the new/changed test count" "grep -qi 'new/changed test' '$OUT'"

# ── 2. proofed mission with NO declared edits → one quiet line ────────────────
repo2="$(new_repo proof)"
# strip t-002's declared edit so the mission has zero contract changes.
m2="$repo2/.git/lcars/missions/$MID"
cat >"$m2/tickets/t-002/result.json" <<'EOF'
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "wire persistence", "newTests": ["src/persist.test.ts"],
  "testEdits": [], "flipFlop": "expected" }
EOF
echo '[]' >"$m2/tickets/t-002/test-edits.json"
make_gh_stub "$repo2/gh"; run_summary "$repo2"
check "2. no CONTRACT AMENDMENTS rows (block collapses)" "! grep -qF 'src/legacy.test.ts' '$OUT'"
check "2. exactly one quiet 'no ... contract' line" "[ \"\$(grep -ci 'no .*contract\|contract .*none' '$OUT')\" -eq 1 ]"

# ── 5. S157: a certified REPAIR of a pre-existing test is SURFACED ───────────
# The harness deliberately does NOT try to prove a repair was honest — that guard
# was built, broken by five successive reviewers, and ruled out. So Verify must
# put the repair in front of the human at the gate they already stop at, name the
# file, and say plainly what was and was not established.
repo5="$(new_repo proof)"
m5="$repo5/.git/lcars/missions/$MID"
cat >"$m5/tickets/t-002/flip-flop.json" <<'EOF'
{ "ticketId": "t-002", "parentSha": "abc", "verdict": "pass",
  "reason": "tests GREEN on tip, RED on parent",
  "testFiles": ["src/legacy.test.ts"],
  "parentLeg": { "ran": true, "mode": "parent-own", "repairPathRefused": "",
                 "sources": [ { "path": "src/legacy.test.ts", "source": "parent-own" } ] },
  "executed": { "parent": "3", "tip": "3", "runner": "node", "checked": true } }
EOF
make_gh_stub "$repo5/gh"; run_summary "$repo5"
check "5. exits 0" "[ '$RC' -eq 0 ]"
check "5. renders a REPAIRED PRE-EXISTING TESTS block" "grep -q 'REPAIRED PRE-EXISTING TESTS' '$OUT'"
check "5. names the repaired file" "grep -qF 'src/legacy.test.ts' '$OUT'"
check "5. names the ticket that repaired it" "grep -q 't-002 . src/legacy.test.ts' '$OUT'"
check "5. states what WAS established (already failing at the parent)" \
  "grep -qi 'already FAILING at the parent' '$OUT'"
check "5. states what was NOT established (removal is unverified)" \
  "grep -qi 'does NOT verify that nothing was removed' '$OUT'"
# S157 (live nit): a repair declares its work in testEdits, not newTests, so the
# chip used to read "0 new/changed test(s)" next to a PROVEN verdict and a
# REPAIRED block — as if the ticket had touched no tests at all.
check "5. the new/changed count includes the repaired file (not 0)" \
  "! grep -q 't-002 .* 0 new/changed test' '$OUT'"

# ── 6. a mission with NO repair says nothing about repairs ───────────────────
repo6="$(new_repo proof)"; make_gh_stub "$repo6/gh"; run_summary "$repo6"
check "6. no repair block when no file was parent-own" "! grep -q 'REPAIRED PRE-EXISTING TESTS' '$OUT'"
check "6. and the pre-existing amendments block is untouched" "grep -qi 'CONTRACT AMENDMENTS' '$OUT'"

# ── 3. flip-flop N/A → chip N/A + reason shown ───────────────────────────────
repo3="$(new_repo proof)"; add_na_ticket "$repo3"; make_gh_stub "$repo3/gh"; run_summary "$repo3"
check "3. flip-flop N/A chip present" "grep -qi 'N/A' '$OUT'"
check "3. the flipFlopReason is shown" "grep -qF 'pure rename, no behavior change' '$OUT'"

# ── 4. pre-S133 mission → BYTE-IDENTICAL (no proof/contract text) ─────────────
repo4="$(new_repo noproof)"; make_gh_stub "$repo4/gh"; run_summary "$repo4"
check "4. exits 0" "[ '$RC' -eq 0 ]"
check "4. NO 'CONTRACT AMENDMENTS' text at all" "! grep -qi 'CONTRACT AMENDMENTS' '$OUT'"
check "4. NO 'Proof of work' text at all" "! grep -qi 'Proof of work' '$OUT'"
check "4. NO 'flip-flop' text at all" "! grep -qi 'flip-flop' '$OUT'"
check "4. still prints the test tally (2/2 green)" "grep -q '2/2' '$OUT'"

# ── 6. S173: the Verify roll-up counts HIRES, not the worker's own swings ────
# The result.json `attempts` field (t-001: 2, t-002: 1) is the WORKER's internal
# iteration count — forensic, and never a headline. The number the captain reads
# is how many times LCARS had to hire, counted from ticket_attempt events.
repo6="$(new_repo proof)"; m6="$repo6/.git/lcars/missions/$MID"
cat >"$m6/events.jsonl" <<EOF
{"ts":1000,"mission":"$MID","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-001","data":{"ticket":"t-001","phase":"tdd","attempt":1}}
{"ts":1001,"mission":"$MID","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":1}}
{"ts":1002,"mission":"$MID","stage":"implement","type":"ticket_gate_bounce","detail":"ticket t-002 bounced by the flip-flop gate (FAIL) — session 1","data":{"ticket":"t-002","gate":"flip-flop","attempt":1}}
{"ts":1003,"mission":"$MID","stage":"implement","type":"ticket_attempt","detail":"tdd session 2 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":2}}
EOF
make_gh_stub "$repo6/gh"; run_summary "$repo6"
check "6. exits 0" "[ '$RC' -eq 0 ]"
check "6. a FIRST-HIRE ticket says only 'green' (silence when nothing went wrong)" \
  "grep -qF '✓ t-001 — green' '$OUT' && ! grep -E '✓ t-001' '$OUT' | grep -q 'session'"
check "6. a RE-HIRED ticket names the hire count" \
  "grep -qF '✓ t-002 — green after 2 worker sessions' '$OUT'"
check "6. the worker's own iteration count (2) is nowhere on the ✓ lines" \
  "! grep -E '^ +✓' '$OUT' | grep -qE '\\b2 attempt'"
check "6. the retired word 'attempt' is gone from the Verify roll-up" \
  "! grep -qi 'attempt' '$OUT'"

# ── 7. S173 back-compat: a mission with NO events.jsonl still reads sanely ────
repo7="$(new_repo proof)"; make_gh_stub "$repo7/gh"; run_summary "$repo7"
check "7. no events.jsonl → every ticket reads as a clean first-hire green" \
  "grep -qF '✓ t-001 — green' '$OUT' && grep -qF '✓ t-002 — green' '$OUT'"
check "7. no '?' placeholder and no phantom hire count leaks in" \
  "! grep -E '^ +✓' '$OUT' | grep -qE '[?]|worker session'"

echo
echo "verify-summary-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
