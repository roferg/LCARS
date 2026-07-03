#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S98 empty-worker-output DETECTION.
#
# S98 distinguishes a cold worker that produced NOTHING (empty stdout/stderr AND
# no files written) from one that produced BAD work (had output, or wrote a file).
# An empty worker is the transient-CLI signal (seen with copilot): it must be
# LABELLED with the existing S96 `empty-worker-output` category and bounded-retried
# then escalated with a DISTINCT message — never silently folded into the generic
# "no usable tests" / "failed validation" retry budget.
#
# This drives the REAL detector through the inert `run.sh` test-hook subcommand:
#   • worker-empty-detect-test → worker_produced_nothing "$LCARS_TEST_OUTDIR"
#
# Detection reads ONLY the outdir contents (files written + .worker.out/.worker.err),
# NEVER the CLI name — inherently engine-agnostic (proven by case 5).
#
# OFFLINE + FREE: no workers, no network, no runner — pure filesystem inspection.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# empty_detect <outdir> [cli_stub] → rc of worker_produced_nothing (0 = nothing)
empty_detect() {
  local outdir="$1" cli="${2:-}"
  ( cd "$REPO_ROOT" \
    && LCARS_TEST_OUTDIR="$outdir" \
       LCARS_WORKER_CLI="$cli" LCARS_WORKER_BIN="$cli" \
       bash "$SCRIPT" worker-empty-detect-test )
}
expect_rc() { # label  expected-rc  actual-rc
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected rc $2, got $3)"; fi
}

echo "S98 worker_produced_nothing — empty-vs-bad detection (outdir contents only)"

# 1. empty dir (no files, no .worker.out/.err at all) → rc 0 (nothing produced).
D1="$(mktemp -d)"
rc=0; empty_detect "$D1" || rc=$?
expect_rc "1. empty dir (no files, no capture) → nothing (rc 0)" 0 "$rc"
rm -rf "$D1"

# 2. empty .worker.out + empty .worker.err, no real files → rc 0 (nothing).
D2="$(mktemp -d)"
: >"$D2/.worker.out"; : >"$D2/.worker.err"
rc=0; empty_detect "$D2" || rc=$?
expect_rc "2. empty capture files, no real files → nothing (rc 0)" 0 "$rc"
rm -rf "$D2"

# 3. .worker.out has REAL text but NO real file → rc 1 (had output = a real
#    bad attempt, e.g. it reasoned toward a bad suite; NOT empty).
D3="$(mktemp -d)"
printf 'I analyzed the ticket and wrote a suite\n' >"$D3/.worker.out"
: >"$D3/.worker.err"
rc=0; empty_detect "$D3" || rc=$?
expect_rc "3. non-empty .worker.out, no real file → produced something (rc 1)" 1 "$rc"
rm -rf "$D3"

# 3b. output ONLY in .worker.err (some CLIs log to stderr) → rc 1.
D3b="$(mktemp -d)"
: >"$D3b/.worker.out"
printf 'thinking... done\n' >"$D3b/.worker.err"
rc=0; empty_detect "$D3b" || rc=$?
expect_rc "3b. non-empty .worker.err, no real file → produced something (rc 1)" 1 "$rc"
rm -rf "$D3b"

# 4. a real file present (tests/foo.test.ts) + empty capture → rc 1 (produced).
D4="$(mktemp -d)"
mkdir -p "$D4/tests"
printf 'test("x",()=>{})\n' >"$D4/tests/foo.test.ts"
: >"$D4/.worker.out"; : >"$D4/.worker.err"
rc=0; empty_detect "$D4" || rc=$?
expect_rc "4. real file written (empty capture) → produced something (rc 1)" 1 "$rc"
rm -rf "$D4"

# 4b. a real file at the TOP level (not under tests/) also counts as produced.
D4b="$(mktemp -d)"
printf '{}\n' >"$D4b/result.json"
rc=0; empty_detect "$D4b" || rc=$?
expect_rc "4b. top-level real file (result.json) → produced something (rc 1)" 1 "$rc"
rm -rf "$D4b"

# 5. engine-agnostic: the SAME empty dir under two different CLI stub names must
#    give the IDENTICAL verdict (detection ignores the CLI name entirely).
D5="$(mktemp -d)"
rc_a=0; empty_detect "$D5" "/usr/bin/claude" || rc_a=$?
rc_b=0; empty_detect "$D5" "/usr/bin/copilot" || rc_b=$?
expect_rc "5. engine-agnostic: claude stub → nothing (rc 0)" 0 "$rc_a"
expect_rc "5. engine-agnostic: copilot stub → nothing (rc 0)" 0 "$rc_b"
if [ "$rc_a" = "$rc_b" ]; then ok "5. identical verdict across CLI stubs"; \
  else bad "5. verdict differs across CLI stubs (claude=$rc_a copilot=$rc_b)"; fi
rm -rf "$D5"

echo
echo "S98 escalation is reachable — distinct message + category phrase present"

# The distinct DIE message and the reused S96 phrase must both exist in run.sh so
# the empty-worker escalation reads as a transient-CLI failure, not a code fault.
if grep -q 'produced no output' "$SCRIPT"; then \
  ok "distinct escalation message 'produced no output' present"; \
  else bad "distinct escalation message 'produced no output' present"; fi
if grep -q 'transient CLI failure' "$SCRIPT"; then \
  ok "'transient CLI failure' phrasing reachable"; \
  else bad "'transient CLI failure' phrasing reachable"; fi
if grep -q 'ticket_worker_empty_output' "$SCRIPT"; then \
  ok "per-attempt event 'ticket_worker_empty_output' emitted"; \
  else bad "per-attempt event 'ticket_worker_empty_output' emitted"; fi

echo
printf 'worker-empty-output: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
