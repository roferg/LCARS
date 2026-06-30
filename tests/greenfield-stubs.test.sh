#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's GREENFIELD-STUB staging in `impl-save-tests`.
#
# The bug (S94): a ticket that creates a BRAND-NEW source module can't pass the
# red gate. The Test-Writer writes `import '../src/canvas/utils'`, but that file
# doesn't exist yet, so a Vite/ESM static import fails to RESOLVE → 0 tests
# collected → `red_gate_resolution_failure` rejects it as an invalid red → after
# 3 attempts the ticket dies ("no usable tests").
#
# The fix: alongside its failing tests, the Test-Writer emits a MINIMAL EMPTY
# stub for any module its tests import that does not exist yet. The harness
# carries those stubs into the worktree source (via `--stubs`) BEFORE the red
# gate runs and LEAVES them for the Implementer to overwrite. With the empty stub
# present the suite COLLECTS and reds on an ASSERTION (valid red) → ACCEPT.
#
# This is NOT the heavy tests/lcars-run.test.sh — it stands up a minimal
# local-only mission parked at `implement` and drives the REAL `impl-save-tests`
# subcommand with a FAKE testCommand that SIMULATES vite/vitest module resolution
# (no real vitest, no tokens). Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# A FAKE testCommand that simulates vite/vitest's module resolution. It REACTS to
# $LCARS_TESTS_DIR (the gate's empty-dir probe must see a difference):
#   • empty/no test files            → "no test files found", exit 0
#   • FAKE_MODE=runner-missing        → "vitest: command not found", exit 1 (env-fail)
#   • imported module file MISSING    → resolution-failure signature, exit 1
#   • module PRESENT but a stub       → AssertionError, exit 1 (valid assertion red)
#   • module PRESENT with REAL_IMPL   → exit 0 (green)
# It runs from $REPO_ROOT (cwd), so a `../src/...` import maps to a repo path.
write_fake_cmd() { # repo
  cat > "$1/faketest.sh" <<'SH'
#!/usr/bin/env bash
set -u
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
if [ "${FAKE_MODE:-}" = "runner-missing" ]; then echo "vitest: command not found"; exit 1; fi
spec="$(grep -hoE "from[[:space:]]*['\"][^'\"]+['\"]" $files | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
rel="${spec#../}"
mod="$rel.ts"
if [ ! -f "$mod" ]; then
  echo "Failed to resolve import \"$spec\" Does the file exist?"
  exit 1
fi
if grep -q REAL_IMPL "$mod"; then exit 0; fi
echo "AssertionError: expected 5 to be defined, got undefined"
exit 1
SH
}

# Stand up a fresh git repo with one mission parked at stage "implement".
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

# Populate a tests dir with one fail-first test importing a greenfield module.
write_test() { # tests-dir
  mkdir -p "$1"
  cat > "$1/t-001.test.ts" <<'TS'
import { area } from '../src/canvas/utils';
test('area multiplies', () => {
  expect(area(2, 3)).toBe(6);
});
TS
}

# Write a stub file mirroring the repo path (stubs/src/canvas/utils.ts).
write_stub() { # stubs-dir  [real]
  mkdir -p "$1/src/canvas"
  if [ "${2:-}" = real ]; then
    printf 'export function area(w, h) { return w * h; /* REAL_IMPL */ }\n' > "$1/src/canvas/utils.ts"
  else
    printf 'export function area(w, h) {}\n' > "$1/src/canvas/utils.ts"
  fi
}

run_save() { # repo tests stubs-or-empty extra-env -> sets RC + OUT
  local repo="$1" tests="$2" stubs="$3" env="${4:-}"
  local args=(impl-save-tests --mission test-001 --ticket t-001 --tests "$tests")
  [ -n "$stubs" ] && args+=(--stubs "$stubs")
  OUT="$( cd "$repo" && eval "$env" LCARS_TEST_CMD=\"bash $repo/faketest.sh\" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" "${args[@]}" 2>&1 )"
  RC=$?
}

# --- case 1: tests + EMPTY stub for a greenfield module → ACCEPTED -----------
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "empty stub staged → assertion-red → accepted" \
  || bad "empty stub staged → accepted (rc=$RC: $OUT)"

# --- case 2: the staged stub persists on disk + is NOT snapshotted -----------
if [ -f "$repo/src/canvas/utils.ts" ]; then
  ok "staged stub persists at repo path (Implementer hand-off)"
else
  bad "staged stub persists at repo path (missing $repo/src/canvas/utils.ts)"
fi
snap="$repo/.git/lcars/missions/test-001/tickets/t-001/tests.sha256"
if [ -f "$snap" ] && ! grep -q "canvas/utils.ts" "$snap"; then
  ok "staged stub is NOT in tests.sha256 (Implementer may overwrite)"
else
  bad "staged stub absent from tests.sha256 (snap=$(cat "$snap" 2>/dev/null))"
fi

# --- case 3: a "stub" with REAL behaviour → green-on-nothing REJECT ----------
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir" real
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "PASSED with no implementation"; } \
  && ok "real-behaviour stub rejected by green-on-nothing arm" \
  || bad "real-behaviour stub rejected (rc=$RC: $OUT)"

# --- case 4: missing module, NO stubs → resolution-failure REJECT -----------
repo="$(new_mission)"; tdir="$repo/_t"
write_test "$tdir"
run_save "$repo" "$tdir" ""
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "could not RESOLVE its import"; } \
  && ok "no stubs + missing module still rejected (resolution failure)" \
  || bad "no stubs + missing module rejected (rc=$RC: $OUT)"

# --- case 5: runner-startup failure → env-failure REJECT (regardless of stub) -
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir" "FAKE_MODE=runner-missing"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "environment not provisioned"; } \
  && ok "runner-startup failure rejected by env-failure guard" \
  || bad "runner-startup failure rejected (rc=$RC: $OUT)"

echo
printf 'greenfield-stubs: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
