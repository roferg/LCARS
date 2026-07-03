#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S101 MULTI-DIR fix in `impl-save-tests`.
#
# The defect (found on a real groutwork drive): when a ticket's Test-Writer authors
# MULTIPLE test files whose target sources live in DIFFERENT dirs, the S101 placement
# put ALL of them in ONE dir (the first target's dir). A test importing `./editorCanvas`
# then resolved to the WRONG dir → module-resolution failure → the red gate rejected
# every attempt → the ticket cap-exhausted.
#
# The fix: PER-FILE co-located placement (each test lands next to the source its
# `./<sibling>` import resolves to, via the manifest / package search / fallback),
# PER-FILE greenfield stub placement (each stub next to ITS OWN test), and MULTI-DIR
# scoping (the in-place red gate scopes to the deepest COMMON ANCESTOR of the placed
# test files when they span dirs; a single file scopes to the file exactly as before).
#
# This is NOT the heavy tests/lcars-run.test.sh. It stands up minimal local-only
# missions parked at `implement` and drives the REAL run.sh subcommands with a FAKE
# testCommand that SIMULATES co-located module resolution PER test file (resolving
# each `./sibling` relative to that test file's OWN in-tree dir). No real vitest, no
# tokens. Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# A FAKE testCommand that simulates CO-LOCATED module resolution for EVERY test file
# under $LCARS_TESTS_DIR (the scope may be a common-ancestor dir spanning several test
# files). It resolves each test's `./sibling` import RELATIVE TO THAT TEST FILE'S OWN
# DIRECTORY — so it only passes when each test is run IN PLACE, next to its source.
#   • empty/no test files            → "No test files found", exit 1  (distinct output)
#   • FAKE_MODE=runner-missing        → "vitest: command not found", exit 1 (env-fail)
#   • FAKE_MODE=ignore-var            → fixed red, IGNORES $LCARS_TESTS_DIR (probe test)
#   • ANY sibling MISSING             → resolution-failure signature, exit 1
#   • all siblings present, any stub  → AssertionError, exit 1 (valid assertion red)
#   • all siblings present, REAL_IMPL → exit 0 (green)
write_fake_cmd() { # repo
  cat > "$1/faketest.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FAKE_MODE:-}" = "ignore-var" ]; then echo "repo suite: 1 failing (fixed target)"; exit 1; fi
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null | LC_ALL=C sort)"
if [ -z "$files" ]; then echo "No test files found"; exit 1; fi
if [ "${FAKE_MODE:-}" = "runner-missing" ]; then echo "vitest: command not found"; exit 1; fi
red=0
for tf in $files; do
  td="$(dirname "$tf")"
  spec="$(grep -hoE "from[[:space:]]*['\"][^'\"]+['\"]" "$tf" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
  [ -n "$spec" ] || spec="$(grep -hoE "import[[:space:]]+['\"][^'\"]+['\"]" "$tf" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
  mod="$td/${spec#./}.ts"
  if [ ! -f "$mod" ]; then echo "Failed to resolve import \"$spec\" Does the file exist?"; exit 1; fi
  if ! grep -q REAL_IMPL "$mod"; then red=1; fi
done
if [ "$red" -ne 0 ]; then echo "AssertionError: expected value to be defined, got undefined"; exit 1; fi
exit 0
SH
}

# Stand up a fresh git repo with one mission parked at implement + a manifest listing
# TWO target sources in DIFFERENT dirs (src/a/foo.ts greenfield, src/b/bar.ts existing).
new_mission() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001/tickets/t-001" \
           "$repo/.git/lcars/missions/test-001/manifests"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "implement" }
JSON
  cat > "$repo/.git/lcars/missions/test-001/manifests/t-001.md" <<'MD'
## Relevant files
- `src/a/foo.ts` — greenfield helper (new)
- `src/b/bar.ts` — existing module (edited)
MD
  write_fake_cmd "$repo"
  echo "$repo"
}

# Two co-located fail-first tests, each importing its OWN sibling in its OWN dir.
write_tests() { # tests-dir
  mkdir -p "$1"
  cat > "$1/foo.test.ts" <<'TS'
import { foo } from './foo';
test('foo', () => { expect(foo()).toBe(1); });
TS
  cat > "$1/bar.test.ts" <<'TS'
import { bar } from './bar';
test('bar', () => { expect(bar()).toBe(2); });
TS
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

echo "S101 multi-dir — per-file co-located placement + common-ancestor scoping"

# --- case 1: two tests, DIFFERENT dirs (greenfield ./foo in A, existing ./bar in B) --
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_tests "$tdir"
# existing source for ./bar (no REAL_IMPL → reds on assertion)
mkdir -p "$repo/src/b"; printf 'export function bar(){}\n' > "$repo/src/b/bar.ts"
# greenfield EMPTY stub for ./foo (named for the sibling)
mkdir -p "$sdir"; printf 'export function foo(){}\n' > "$sdir/foo.ts"
run_save "$repo" "$tdir" "$sdir"

{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "multi-dir suite → red gate collects BOTH + REDs in place → accepted" \
  || bad "multi-dir accepted (rc=$RC: $OUT)"

[ -f "$repo/src/a/foo.test.ts" ] \
  && ok "test A placed co-located in its OWN dir (src/a/foo.test.ts)" \
  || bad "test A placed in src/a (missing $repo/src/a/foo.test.ts)"
[ -f "$repo/src/b/bar.test.ts" ] \
  && ok "test B placed co-located in its OWN dir (src/b/bar.test.ts)" \
  || bad "test B placed in src/b (missing $repo/src/b/bar.test.ts)"
[ -f "$repo/src/a/foo.ts" ] \
  && ok "greenfield stub placed next to ITS OWN test (src/a/foo.ts)" \
  || bad "greenfield stub in src/a (missing $repo/src/a/foo.ts)"

snap="$repo/.git/lcars/missions/test-001/tickets/t-001/tests.sha256"
{ grep -q "src/a/foo.test.ts" "$snap" 2>/dev/null && grep -q "src/b/bar.test.ts" "$snap" 2>/dev/null; } \
  && ok "tests.sha256 records BOTH in-tree relpaths" \
  || bad "tests.sha256 records both relpaths (snap=$(cat "$snap" 2>/dev/null))"
# the greenfield stub must NOT be snapshotted (Implementer overwrites it)
! grep -q "src/a/foo.ts$" "$snap" 2>/dev/null \
  && ok "greenfield stub NOT snapshotted (Implementer may overwrite)" \
  || bad "stub not snapshotted (snap=$(cat "$snap" 2>/dev/null))"

# --- case 2: common-ancestor scope reported; a post-snapshot edit is tamper --------
printf '%s' "$OUT" | grep -qE ': +src(\b|$)' \
  && ok "multi-dir scope reported as the common ancestor (src)" \
  || bad "multi-dir scope reported (OUT=$OUT)"
tu() { ( cd "$repo" && LCARS_GIT_BIN=git bash "$SCRIPT" tests-unchanged-test --mission test-001 --ticket t-001 ); }
[ "$(tu)" = "TURC=0" ] \
  && ok "tests_unchanged → unchanged (TURC=0) right after save" \
  || bad "tests_unchanged unchanged after save (got '$(tu)')"
printf '\n// tampered\n' >> "$repo/src/b/bar.test.ts"
[ "$(tu)" = "TURC=1" ] \
  && ok "post-snapshot edit to EITHER in-tree test → tamper DETECTED (TURC=1)" \
  || bad "tamper detected (got '$(tu)')"

# --- case 3: single-file ticket still scopes to the FILE (byte-identical) ----------
repo="$(new_mission)"; tdir="$repo/_t"
mkdir -p "$tdir"
cat > "$tdir/bar.test.ts" <<'TS'
import { bar } from './bar';
test('bar', () => { expect(bar()).toBe(2); });
TS
mkdir -p "$repo/src/b"; printf 'export function bar(){}\n' > "$repo/src/b/bar.ts"
run_save "$repo" "$tdir" ""
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "single-file co-located → accepted in place" \
  || bad "single-file accepted (rc=$RC: $OUT)"
[ -f "$repo/src/b/bar.test.ts" ] \
  && ok "single-file placed co-located (src/b/bar.test.ts)" \
  || bad "single-file placed (missing $repo/src/b/bar.test.ts)"
printf '%s' "$OUT" | grep -q "src/b/bar.test.ts" \
  && ok "single-file scope reported as the FILE (not a dir)" \
  || bad "single-file scope is the file (OUT=$OUT)"

# --- case 4: rejection rolls back ALL placed tests AND ALL stubs (no trace) --------
# Two greenfield tests, but a stub only for ./foo — ./bar cannot resolve → the red
# gate rejects on resolution-failure. Nothing must be left behind in ANY dir.
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_tests "$tdir"
mkdir -p "$sdir"; printf 'export function foo(){}\n' > "$sdir/foo.ts"   # stub for ./foo only
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "could not RESOLVE its import"; } \
  && ok "unresolved ./bar → resolution-failure REJECT" \
  || bad "unresolved sibling reject (rc=$RC: $OUT)"
{ [ ! -f "$repo/src/a/foo.test.ts" ] && [ ! -f "$repo/src/b/bar.test.ts" ] && [ ! -f "$repo/src/a/foo.ts" ]; } \
  && ok "rejection → ALL placed tests + stubs rolled back across all dirs (no trace)" \
  || bad "rejection rollback (foo.test=$([ -f "$repo/src/a/foo.test.ts" ] && echo Y) bar.test=$([ -f "$repo/src/b/bar.test.ts" ] && echo Y) stub=$([ -f "$repo/src/a/foo.ts" ] && echo Y))"

echo
printf 'multi-dir-tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
