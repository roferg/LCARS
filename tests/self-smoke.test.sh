#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S99 TEST-WRITER PRE-GATE SELF-SMOKE.
#
# The bug (S99): the Test-Writer can ship a suite that HANGS (a never-settling
# awaited/thenable mock, an infinite async init) or COLLECTS ZERO tests. Today
# the red gate has NO timeout, so a hang wedges the ticket, and a zero-test suite
# can slip through — and either way the *Implementer* eats the cost.
#
# The fix: a PRE-GATE self-smoke runs the authored suite ONCE under a HARD
# TIMEOUT, BEFORE the immutable snapshot. A hang (rc 124) or a zero-test suite is
# bounced back to the TEST-WRITER (retry) with actionable feedback; nothing is
# snapshotted and the Implementer never sees it. A suite that RUNS (red / green /
# load-error) proceeds to the snapshot + the authoritative red gate unchanged.
#
# This drives the REAL run.sh through inert test-hook subcommands + a stubbed
# testCommand. OFFLINE + FREE: no real vitest, no workers, no network. ~1s.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. run-hard-timeout-test — the portable hard wall-clock timeout util.
# ---------------------------------------------------------------------------
echo "S99 run_with_hard_timeout — portable wall-clock timeout"

ht() { # secs cmd -> echoes RC=<rc>
  ( cd "$REPO_ROOT" && LCARS_HT_SECS="$1" LCARS_HT_CMD="$2" bash "$SCRIPT" run-hard-timeout-test )
}
out="$(ht 2 'sleep 30')"
[ "$out" = "RC=124" ] && ok "sleep 30 under 2s → RC=124 (timed out + killed)" \
  || bad "sleep 30 under 2s → RC=124 (got '$out')"
out="$(ht 5 'exit 3')"
[ "$out" = "RC=3" ] && ok "exit 3 under 5s → RC=3 (real rc round-trips)" \
  || bad "exit 3 under 5s → RC=3 (got '$out')"
out="$(ht 5 'echo hi; exit 0')"
[ "$out" = "RC=0" ] && ok "exit 0 under 5s → RC=0 (green round-trips)" \
  || bad "exit 0 under 5s → RC=0 (got '$out')"

# ---------------------------------------------------------------------------
# 2. self-smoke-verdict-test — the pure verdict (rc via env, output on stdin).
# ---------------------------------------------------------------------------
echo "S99 self_smoke_verdict — hang | zero-tests | ok"

verdict() { # rc output -> echoes verdict
  printf '%s' "$2" | ( cd "$REPO_ROOT" && LCARS_SS_RC="$1" bash "$SCRIPT" self-smoke-verdict-test )
}
v="$(verdict 124 'anything at all here')"
[ "$v" = "hang" ] && ok "rc 124 → hang (the hard timeout fired)" \
  || bad "rc 124 → hang (got '$v')"
# A resolution/load failure is the RED GATE's job (richer feedback) — the smoke
# must NOT bounce it, it must return 'ok' so the gate renders the verdict.
v="$(verdict 1 'Failed to resolve import "../x". Does the file exist?')"
[ "$v" = "ok" ] && ok "resolution failure → ok (deferred to the red gate)" \
  || bad "resolution failure → ok (got '$v')"
v="$(verdict 1 'No test files found')"
[ "$v" = "zero-tests" ] && ok "'No test files found' → zero-tests" \
  || bad "'No test files found' → zero-tests (got '$v')"
# A genuine assertion red is a REAL run — proceed to the gate.
v="$(verdict 1 'AssertionError: expected 3 to be 4')"
[ "$v" = "ok" ] && ok "genuine assertion red → ok (a real run; proceed)" \
  || bad "genuine assertion red → ok (got '$v')"

# ---------------------------------------------------------------------------
# 3. suite-zero-tests-test — the zero-tests detector (rc 0 = zero collected).
# ---------------------------------------------------------------------------
echo "S99 suite_collected_zero_tests — TIGHT zero-tests detector"

ztest() { printf '%s' "$1" | ( cd "$REPO_ROOT" && bash "$SCRIPT" suite-zero-tests-test ); }
ztest 'No test suite found in file x' && ok "'No test suite found in' → zero-tests" \
  || bad "'No test suite found in' → zero-tests"
# A healthy red (1 failed) is NOT zero-tests.
if ztest "$(printf 'AssertionError: expected 3 to be 4\nTests: 1 failed')"; then
  bad "healthy red (1 failed) must NOT read as zero-tests"
else
  ok "healthy red (1 failed) is NOT zero-tests"
fi
# '0 passed' alone must NOT false-positive (a red suite often prints it).
if ztest '0 passed'; then
  bad "'0 passed' alone must NOT read as zero-tests"
else
  ok "'0 passed' alone is NOT zero-tests (no false positive)"
fi

# ---------------------------------------------------------------------------
# 4. classify-impl-failure-test — the self-smoke HANG marker → test-writer-hang.
# ---------------------------------------------------------------------------
echo "S99 classify_impl_failure — hang marker → test-writer-hang"

cl="$(printf 'SELF-SMOKE — your suite HUNG: the suite never settled within the hard timeout' \
  | ( cd "$REPO_ROOT" && LCARS_CLASSIFY_FILES="$(printf 'tests/x.test.ts\n')" \
      bash "$SCRIPT" classify-impl-failure-test ))"
[ "$cl" = "test-writer-hang" ] && ok "hang marker (files written) → test-writer-hang" \
  || bad "hang marker → test-writer-hang (got '$cl')"

# ---------------------------------------------------------------------------
# 5. END-TO-END via impl-save-tests (mirror greenfield-stubs).
# ---------------------------------------------------------------------------
echo "S99 impl-save-tests — pre-gate self-smoke bounces a HANG, passes a healthy suite"

# A fake testCommand: HANG mode when a test file carries HANG_MOCK; otherwise the
# greenfield behaviour (missing module → resolution failure; empty stub present →
# assertion red; REAL_IMPL → green). Runs from $REPO_ROOT so `../src/...` maps to
# a repo path (repo-root ticket, empty pkg_rel).
write_fake_cmd() { # repo
  cat > "$1/faketest.sh" <<'SH'
#!/usr/bin/env bash
set -u
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
if grep -ql HANG_MOCK $files 2>/dev/null; then sleep 30; fi
spec="$(grep -hoE "from[[:space:]]*['\"][^'\"]+['\"]" $files | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
rel="${spec#../}"; mod="$rel.ts"
if [ ! -f "$mod" ]; then echo "Failed to resolve import \"$spec\" Does the file exist?"; exit 1; fi
if grep -q REAL_IMPL "$mod"; then exit 0; fi
echo "AssertionError: expected 5 to be defined, got undefined"
exit 1
SH
}

new_mission() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001/tickets/t-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "implement" }
JSON
  write_fake_cmd "$repo"
  echo "$repo"
}

write_stub() { # stubs-dir
  mkdir -p "$1/src/canvas"
  printf 'export function area(w, h) {}\n' > "$1/src/canvas/utils.ts"
}

run_save() { # repo tests stubs -> sets RC + OUT
  local repo="$1" tests="$2" stubs="$3"
  local args=(impl-save-tests --mission test-001 --ticket t-001 --tests "$tests")
  [ -n "$stubs" ] && args+=(--stubs "$stubs")
  OUT="$( cd "$repo" && LCARS_SELF_SMOKE_TIMEOUT_SECS=2 \
            LCARS_TEST_CMD="bash $repo/faketest.sh" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" "${args[@]}" 2>&1 )"
  RC=$?
}

# --- 5a. a HANGING suite → bounced at the self-smoke, nothing snapshotted -----
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
mkdir -p "$tdir"
cat > "$tdir/t-001.test.ts" <<'TS'
import { area } from '../src/canvas/utils';
// HANG_MOCK — an awaited never-settling thenable double
test('never settles', () => { expect(area(2, 3)).toBe(6); });
TS
write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir"
snap="$repo/.git/lcars/missions/test-001/tickets/t-001/tests.sha256"
sig="$repo/.git/lcars/missions/test-001/tickets/t-001/red-gate-signal.txt"
{ [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -qi "self-smoke" \
  && printf '%s' "$OUT" | grep -q "HUNG"; } \
  && ok "HANG suite → impl-save-tests exits non-zero, mentions self-smoke + HUNG" \
  || bad "HANG suite → non-zero + self-smoke/HUNG (rc=$RC: $OUT)"
[ ! -f "$snap" ] \
  && ok "HANG suite → tests.sha256 NOT written (nothing snapshotted, rolled back)" \
  || bad "HANG suite → tests.sha256 must be absent (found $snap)"
{ [ -f "$sig" ] && grep -q "HUNG" "$sig"; } \
  && ok "HANG suite → red-gate-signal.txt holds the hang reason (grounded retry)" \
  || bad "HANG suite → red-gate-signal.txt hang reason (sig=$(cat "$sig" 2>/dev/null))"

# --- 5b. a HEALTHY greenfield suite (empty stub) → passes through unchanged ---
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
mkdir -p "$tdir"
cat > "$tdir/t-001.test.ts" <<'TS'
import { area } from '../src/canvas/utils';
test('area multiplies', () => { expect(area(2, 3)).toBe(6); });
TS
write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "healthy greenfield suite → self-smoke passes it to the gate → accepted" \
  || bad "healthy greenfield suite → accepted (rc=$RC: $OUT)"

# ---------------------------------------------------------------------------
# 6. the Test-Writer template carries the four byte-exact hazard-rule strings.
# ---------------------------------------------------------------------------
echo "S99 implement-test-writer.md — four byte-exact hazard-rule strings"

TPL="$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md"
grep_tpl() { grep -qF "$1" "$TPL"; }
grep_tpl 'MUST return `undefined` for `then`' \
  && ok "hazard #1: thenable carve-out string present" \
  || bad "hazard #1: 'MUST return \`undefined\` for \`then\`' missing"
grep_tpl 'never `await` a synchronously-constructed mock' \
  && ok "hazard #2: no-await-sync-mock string present" \
  || bad "hazard #2: 'never \`await\` a synchronously-constructed mock' missing"
grep_tpl '// @vitest-environment jsdom' \
  && ok "hazard #3: jsdom pragma string present" \
  || bad "hazard #3: '// @vitest-environment jsdom' missing"
grep_tpl '`localStorage`/`window` that Node shadows' \
  && ok "hazard #4: Node-shadow globals string present" \
  || bad "hazard #4: '\`localStorage\`/\`window\` that Node shadows' missing"

echo
printf 'self-smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
