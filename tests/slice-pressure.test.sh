#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S100 SOFT under-slice signal (slice_pressure).
#
# Plan Review was passing a mega-ticket that hid a whole surface behind a simple
# title (the "migrate the chrome to tokens" ticket that left App.tsx / Toolbar
# unscoped). S100 adds a HEURISTIC, ADVISORY-ONLY hint (slice_pressure /
# build_slice_pressure_hint) surfaced to the reviewer, plus a sharper reviewer
# bar in stages/plan-review.md. It is SIGNAL ONLY: it NEVER mechanically rejects
# a ticket — the reviewer LLM still decides.
#
# CRITICAL guarantee under test: the LoC signal is driven by estimatedNewLoc
# (implementation weight), NOT estimatedReadLoc — so a ticket that is over budget
# ONLY because it must READ a big existing file must NOT read as high pressure
# (budget is a PLANNING TARGET, not a reject).
#
# Drives the REAL functions through inert `run.sh` test-hook subcommands:
#   • slice-pressure-test       → slice_pressure (scalar; inputs via env)
#   • slice-pressure-hint-test  → build_slice_pressure_hint (over a plan.json)
# OFFLINE + FREE: no workers, no network — pure string/arithmetic classification.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TEMPLATE="$REPO_ROOT/skills/lcars-run/stages/plan-review.md"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# --- slice_pressure scalar: echoes "<level>\t<reason>" ----------------------
sp() { # nCriteria nFiles nDirs newLoc budget -> "<level>\t<reason>"
  LCARS_SP_NC="$1" LCARS_SP_NF="$2" LCARS_SP_ND="$3" LCARS_SP_NEWLOC="$4" \
    LCARS_SP_BUDGET="$5" bash "$SCRIPT" slice-pressure-test
}
sp_level() { printf '%s' "$1" | cut -f1; }

echo "S100 slice_pressure — scalar level"

# 1. many-criteria / many-file / broad-glob / high-newLoc → high
OUT="$(sp 6 12 4 480 400)"
[ "$(sp_level "$OUT")" = high ] && ok "1. many+broad+over-budget → high" \
  || bad "1. many+broad+over-budget → high (got '$OUT')"

# 1b. single-criterion / single-file / small → low
OUT="$(sp 1 1 1 10 400)"
[ "$(sp_level "$OUT")" = low ] && ok "1b. single+small → low" \
  || bad "1b. single+small → low (got '$OUT')"

# 1c. the reason names the firing signals (numbers present)
OUT="$(sp 6 12 4 480 400)"
printf '%s' "$OUT" | grep -q "estimatedNewLoc 480 > budget 400" \
  && printf '%s' "$OUT" | grep -q "6 criteria" \
  && ok "1c. reason names criteria + newLoc-vs-budget" \
  || bad "1c. reason names criteria + newLoc-vs-budget (got '$OUT')"

# --- build_slice_pressure_hint over a plan.json -----------------------------
hint() { # planfile [manifests_dir] [budget] -> stdout hint block
  bash "$SCRIPT" slice-pressure-hint-test --plan "$1" ${2:+--manifests "$2"} "${3:-1200}"
}

# A two-ticket plan: t-001 is a mega under-slice, t-002 is a clean small slice.
PLAN="$TMPROOT/plan.json"
cat > "$PLAN" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Migrate all the chrome to tokens",
    "description": "Swap every hard-coded colour for a token across the app.",
    "acceptanceCriteria": ["header themed", "toolbar themed", "footer themed", "buttons themed", "inputs themed", "cards themed"],
    "estimatedReadLoc": 120,
    "estimatedTestLoc": 40,
    "estimatedNewLoc": 480,
    "dependencies": [],
    "rationale": "Everything must use tokens."
  },
  {
    "id": "t-002",
    "title": "Add a single theme toggle button",
    "description": "One button flips the data-theme attribute.",
    "acceptanceCriteria": ["clicking toggles data-theme"],
    "estimatedReadLoc": 20,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 15,
    "dependencies": [],
    "rationale": "Small, self-contained."
  }
]
JSON

echo
echo "S100 build_slice_pressure_hint — advisory block injected"

OUT="$(hint "$PLAN" "" 400)"
# 2. the block is present and clearly advisory (not a verdict)
{ printf '%s' "$OUT" | grep -qi "Slice-pressure signals" \
  && printf '%s' "$OUT" | grep -qi "advisory only" \
  && printf '%s' "$OUT" | grep -qi "NOT a verdict"; } \
  && ok "2. advisory hint block present and labelled advisory" \
  || bad "2. advisory hint block present and labelled advisory (got: $OUT)"

# 2b. the mega ticket is flagged high with its firing reason
{ printf '%s' "$OUT" | grep -E -q "t-001 \[high\]" \
  && printf '%s' "$OUT" | grep -q "estimatedNewLoc 480 > budget 400"; } \
  && ok "2b. mega ticket t-001 flagged [high] with reason" \
  || bad "2b. mega ticket t-001 flagged [high] with reason (got: $OUT)"

# 2c. the concrete failure mode is restated in the block
printf '%s' "$OUT" | grep -qi "under-slice" \
  && ok "2c. concrete under-slice failure mode restated" \
  || bad "2c. concrete under-slice failure mode restated (got: $OUT)"

# 2d. the small clean ticket is NOT high
printf '%s' "$OUT" | grep -E -q "t-002 \[high\]" \
  && bad "2d. small clean ticket t-002 must NOT be high (got: $OUT)" \
  || ok "2d. small clean ticket t-002 not high"

echo
echo "S100 budget-is-a-target — over-budget-BY-READ is NOT high, NOT rejected"

# 3. A ticket that is over comprehensionBudget ONLY because estimatedReadLoc is
#    huge (reads a big existing file), but is one criterion / small newLoc, must
#    NOT be high — and the hook still exits 0 (the signal never rejects).
READPLAN="$TMPROOT/read-heavy.json"
cat > "$READPLAN" <<'JSON'
[
  {
    "id": "t-010",
    "title": "Read a huge legacy file and add one guard",
    "description": "Understand a 5000-line module, then add one small guard clause.",
    "acceptanceCriteria": ["the guard rejects a null id"],
    "estimatedReadLoc": 5000,
    "estimatedTestLoc": 15,
    "estimatedNewLoc": 20,
    "dependencies": [],
    "rationale": "The read is unavoidable existing code."
  }
]
JSON
OUT="$(hint "$READPLAN" "" 400)"; RC=$?
{ [ "$RC" -eq 0 ] \
  && ! printf '%s' "$OUT" | grep -E -q "t-010 \[high\]"; } \
  && ok "3. over-budget-by-READ ticket is NOT high and NOT rejected (rc=$RC)" \
  || bad "3. over-budget-by-READ ticket is NOT high / was rejected (rc=$RC: $OUT)"

# --- manifest breadth contributes (files / dirs) ----------------------------
echo
echo "S100 manifest breadth feeds the file/dir signal"

MDIR="$TMPROOT/manifests"; mkdir -p "$MDIR"
cat > "$MDIR/t-001.md" <<'MD'
# t-001 manifest

## Relevant files
- src/App.tsx — root shell
- src/ui/Toolbar.tsx
- src/ui/Header.tsx
- src/ui/Footer.tsx
- src/theme/tokens.ts
- styles/base.css
MD
OUT="$(hint "$PLAN" "$MDIR" 400)"
# 6 files across 4 distinct dirs (src, src/ui, src/theme, styles).
printf '%s' "$OUT" | grep -q "t-001 \[high\] 6 criteria, 6 file(s) across 4 dir(s)" \
  && ok "4. manifest file/dir breadth (6 files, 4 dirs) surfaced in t-001 reason" \
  || bad "4. manifest file/dir breadth surfaced in t-001 reason (got: $OUT)"

# --- durable reviewer bar line lives in the template ------------------------
echo
echo "S100 durable reviewer bar in stages/plan-review.md"

{ grep -qi "hides multiple behaviors" "$TEMPLATE" \
  && grep -qi "silently omits" "$TEMPLATE"; } \
  && ok "5. template bar line rejects hidden-surface / silent-omission tickets" \
  || bad "5. template bar line rejects hidden-surface / silent-omission tickets"

echo
printf 'slice-pressure: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
