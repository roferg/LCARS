#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S101 "tests ride along, part 1": the Test-Writer's
# per-ticket fail-first test lands IN THE REPO at the repo's OWN test convention
# (co-located / __tests__/ / top-level tests/) instead of only in the .git/lcars
# quarantine. It RELOCATES where the test is AUTHORED + SNAPSHOTTED and runs the red
# gate IN PLACE (co-located `./sibling` imports resolve). It must keep the red gate
# red-first, the immutable-test snapshot, and the empty-dir probe intact.
#
# This is NOT the heavy tests/lcars-run.test.sh. It stands up minimal local-only
# missions parked at `implement` and drives the REAL run.sh subcommands + inert test
# hooks with a FAKE testCommand that SIMULATES co-located module resolution (no real
# vitest, no tokens). Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. detect_test_convention — pure filesystem inference.
# ---------------------------------------------------------------------------
echo "S101 detect_test_convention — co-located | __tests__ | tests | default"

dtc() { # root target -> echoes convention
  ( cd "$REPO_ROOT" && LCARS_DTC_ROOT="$1" LCARS_DTC_TARGET="$2" \
      bash "$SCRIPT" detect-test-convention-test )
}

# a repo with a co-located sibling test in the target's dir
r1="$(mktemp -d "$TMPROOT/r1.XXXX")"; mkdir -p "$r1/src/x"
printf 'export const a=1\n' > "$r1/src/x/foo.ts"
printf 'test("x",()=>{})\n' > "$r1/src/x/foo.test.ts"
[ "$(dtc "$r1" "src/x/foo.ts")" = "co-located" ] \
  && ok "co-located sibling → co-located" || bad "co-located sibling → co-located (got '$(dtc "$r1" src/x/foo.ts)')"

# a repo whose tests live under __tests__/
r2="$(mktemp -d "$TMPROOT/r2.XXXX")"; mkdir -p "$r2/src/x/__tests__"
printf 'export const a=1\n' > "$r2/src/x/foo.ts"
printf 'test("x",()=>{})\n' > "$r2/src/x/__tests__/foo.test.ts"
[ "$(dtc "$r2" "src/x/foo.ts")" = "__tests__" ] \
  && ok "__tests__ dir → __tests__" || bad "__tests__ dir → __tests__ (got '$(dtc "$r2" src/x/foo.ts)')"

# a repo whose tests live under a top-level tests/
r3="$(mktemp -d "$TMPROOT/r3.XXXX")"; mkdir -p "$r3/src/x" "$r3/tests"
printf 'export const a=1\n' > "$r3/src/x/foo.ts"
printf 'test("x",()=>{})\n' > "$r3/tests/foo.test.ts"
[ "$(dtc "$r3" "src/x/foo.ts")" = "tests" ] \
  && ok "top-level tests/ → tests" || bad "top-level tests/ → tests (got '$(dtc "$r3" src/x/foo.ts)')"

# a TS/JS repo with NO existing tests → default co-located
r4="$(mktemp -d "$TMPROOT/r4.XXXX")"; mkdir -p "$r4/src/x"
printf 'export const a=1\n' > "$r4/src/x/foo.ts"
[ "$(dtc "$r4" "src/x/foo.ts")" = "co-located" ] \
  && ok "no existing tests → default co-located" || bad "no tests → co-located (got '$(dtc "$r4" src/x/foo.ts)')"

# ---------------------------------------------------------------------------
# 2. test_path_for — pure path mapping (extension family preserved).
# ---------------------------------------------------------------------------
echo "S101 test_path_for — source path → in-tree test relpath"

tpf() { ( cd "$REPO_ROOT" && LCARS_TPF_CONV="$1" LCARS_TPF_TARGET="$2" bash "$SCRIPT" test-path-for-test ); }
[ "$(tpf co-located a/b/foo.ts)" = "a/b/foo.test.ts" ]            && ok "co-located map" || bad "co-located map (got '$(tpf co-located a/b/foo.ts)')"
[ "$(tpf __tests__ a/b/foo.ts)" = "a/b/__tests__/foo.test.ts" ]  && ok "__tests__ map"  || bad "__tests__ map (got '$(tpf __tests__ a/b/foo.ts)')"
[ "$(tpf tests a/b/foo.ts)" = "tests/foo.test.ts" ]              && ok "tests map"      || bad "tests map (got '$(tpf tests a/b/foo.ts)')"
[ "$(tpf co-located a/b/foo.tsx)" = "a/b/foo.test.tsx" ]         && ok "extension family preserved (.tsx)" || bad "ext family (got '$(tpf co-located a/b/foo.tsx)')"
[ "$(tpf co-located a/b/foo.jsx)" = "a/b/foo.test.jsx" ]         && ok "extension family preserved (.jsx)" || bad "ext family (got '$(tpf co-located a/b/foo.jsx)')"

# ---------------------------------------------------------------------------
# 3-5. impl-save-tests relocation + in-place red gate + snapshot + tamper.
# ---------------------------------------------------------------------------
echo "S101 impl-save-tests — authored IN-TREE, red gate IN PLACE, immutable snapshot"

# A FAKE testCommand that simulates CO-LOCATED module resolution. It REACTS to
# $LCARS_TESTS_DIR (the empty-dir probe must see a difference) and resolves the
# imported `./sibling` RELATIVE TO THE TEST FILE'S OWN DIRECTORY — so it only passes
# when the test is run IN PLACE, next to its source:
#   • empty/no test files            → "No test files found", exit 1
#   • FAKE_MODE=runner-missing        → "vitest: command not found", exit 1 (env-fail)
#   • FAKE_MODE=ignore-var            → fixed red, IGNORES $LCARS_TESTS_DIR (probe test)
#   • sibling MISSING                 → resolution-failure signature, exit 1
#   • sibling present, a stub         → AssertionError, exit 1 (valid assertion red)
#   • sibling present, REAL_IMPL      → exit 0 (green)
write_fake_cmd() { # repo
  cat > "$1/faketest.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FAKE_MODE:-}" = "ignore-var" ]; then echo "repo suite: 1 failing (fixed target)"; exit 1; fi
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "No test files found"; exit 1; fi
if [ "${FAKE_MODE:-}" = "runner-missing" ]; then echo "vitest: command not found"; exit 1; fi
tf="$(printf '%s\n' "$files" | head -1)"; td="$(dirname "$tf")"
spec="$(grep -hoE "from[[:space:]]*['\"][^'\"]+['\"]" "$tf" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
mod="$td/${spec#./}.ts"
if [ ! -f "$mod" ]; then echo "Failed to resolve import \"$spec\" Does the file exist?"; exit 1; fi
if grep -q REAL_IMPL "$mod"; then exit 0; fi
echo "AssertionError: expected 6 to be defined, got undefined"
exit 1
SH
}

# Stand up a fresh git repo with one mission parked at implement + a manifest naming
# the target source (src/canvas/utils.ts) so the harness derives the convention path.
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
- `src/canvas/utils.ts` — the greenfield area helper
MD
  write_fake_cmd "$repo"
  echo "$repo"
}

# A co-located fail-first test importing its sibling `./utils`.
write_test() { # tests-dir
  mkdir -p "$1"
  cat > "$1/utils.test.ts" <<'TS'
import { area } from './utils';
test('area multiplies', () => {
  expect(area(2, 3)).toBe(6);
});
TS
}

# A greenfield stub named for the CO-LOCATED sibling (`./utils` → stubs/utils.ts);
# the harness reroots it BY BASENAME next to the relocated test.
write_stub() { # stubs-dir [real]
  mkdir -p "$1"
  if [ "${2:-}" = real ]; then
    printf 'export function area(w,h){return w*h;/*REAL_IMPL*/}\n' > "$1/utils.ts"
  else
    printf 'export function area(w,h){}\n' > "$1/utils.ts"
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

INTREE=".git/../src/canvas/utils.test.ts"   # note: relative to repo root below

# --- case A: co-located test + empty stub → ACCEPTED, authored at in-tree path -
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "co-located greenfield → assertion-red IN PLACE → accepted" \
  || bad "co-located greenfield → accepted (rc=$RC: $OUT)"
[ -f "$repo/src/canvas/utils.test.ts" ] \
  && ok "test AUTHORED at the in-tree convention path (src/canvas/utils.test.ts)" \
  || bad "test authored at in-tree path (missing $repo/src/canvas/utils.test.ts)"

snap="$repo/.git/lcars/missions/test-001/tickets/t-001/tests.sha256"
grep -q "src/canvas/utils.test.ts" "$snap" 2>/dev/null \
  && ok "tests.sha256 records the IN-TREE relpath" \
  || bad "tests.sha256 records in-tree relpath (snap=$(cat "$snap" 2>/dev/null))"
# the greenfield stub persists on disk but is NOT snapshotted (Implementer overwrites it)
{ [ -f "$repo/src/canvas/utils.ts" ] && ! grep -q "src/canvas/utils.ts$" "$snap"; } \
  && ok "stub persists at repo path + NOT snapshotted" \
  || bad "stub persists + not snapshotted (snap=$(cat "$snap" 2>/dev/null))"

# --- case B: immutability — a post-snapshot edit to the IN-TREE test is caught ---
tu() { ( cd "$repo" && LCARS_GIT_BIN=git bash "$SCRIPT" tests-unchanged-test --mission test-001 --ticket t-001 ); }
[ "$(tu)" = "TURC=0" ] \
  && ok "tests_unchanged → unchanged (TURC=0) right after save" \
  || bad "tests_unchanged unchanged after save (got '$(tu)')"
printf '\n// tampered by the Implementer\n' >> "$repo/src/canvas/utils.test.ts"
[ "$(tu)" = "TURC=1" ] \
  && ok "post-snapshot edit to the in-tree test → tamper DETECTED (TURC=1)" \
  || bad "tamper detected (got '$(tu)')"

# --- case C: greenfield, NO stub → resolution-failure REJECT + rolled back ------
repo="$(new_mission)"; tdir="$repo/_t"
write_test "$tdir"
run_save "$repo" "$tdir" ""
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "could not RESOLVE its import"; } \
  && ok "no stub + missing sibling → resolution-failure REJECT (in place)" \
  || bad "no stub → resolution reject (rc=$RC: $OUT)"
[ ! -f "$repo/src/canvas/utils.test.ts" ] \
  && ok "rejected suite → in-tree test ROLLED BACK (no trace)" \
  || bad "rejected suite → in-tree test rolled back (found $repo/src/canvas/utils.test.ts)"

# --- case D: real-behaviour stub → green-on-nothing REJECT ----------------------
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir" real
run_save "$repo" "$tdir" "$sdir"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "PASSED with no implementation"; } \
  && ok "real-behaviour stub → green-on-nothing REJECT" \
  || bad "real stub → green-on-nothing reject (rc=$RC: $OUT)"

# --- case E: regression — a runner that IGNORES $LCARS_TESTS_DIR is still BLOCKED -
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir" "FAKE_MODE=ignore-var"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'IGNORES'; } \
  && ok "runner ignoring \$LCARS_TESTS_DIR → red-gate probe BLOCKS (discrimination intact)" \
  || bad "ignore-var runner blocked (rc=$RC: $OUT)"

# --- case F: runner-startup failure → env-failure REJECT ------------------------
repo="$(new_mission)"; tdir="$repo/_t"; sdir="$repo/_s"
write_test "$tdir"; write_stub "$sdir"
run_save "$repo" "$tdir" "$sdir" "FAKE_MODE=runner-missing"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "environment not provisioned"; } \
  && ok "runner-startup failure → env-failure REJECT" \
  || bad "runner-missing → env reject (rc=$RC: $OUT)"

# --- case G: NON-greenfield co-located test (existing sibling) → assertion red ---
# The module under test ALREADY exists in the tree; the test imports it co-located
# and reds on an assertion IN PLACE (no stub needed). Proves a non-greenfield
# co-located ticket collects + reds at the in-tree location.
repo="$(new_mission)"; tdir="$repo/_t"
mkdir -p "$repo/src/canvas"; printf 'export function area(w,h){}\n' > "$repo/src/canvas/utils.ts"
write_test "$tdir"
run_save "$repo" "$tdir" ""
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "non-greenfield co-located (existing ./sibling) → collects + assertion-red in place" \
  || bad "non-greenfield co-located → accepted (rc=$RC: $OUT)"
[ -f "$repo/src/canvas/utils.test.ts" ] \
  && ok "non-greenfield → test authored at in-tree co-located path" \
  || bad "non-greenfield → in-tree path (missing $repo/src/canvas/utils.test.ts)"

# --- case H: resolution-failure hint is CO-LOCATED (pushes the retry the right way) -
repo="$(new_mission)"; tdir="$repo/_t"
write_test "$tdir"
run_save "$repo" "$tdir" ""
{ printf '%s' "$OUT" | grep -q "CO-LOCATED" && printf '%s' "$OUT" | grep -q "'./utils'"; } \
  && ok "resolution-failure hint tells the Test-Writer to import CO-LOCATED ./sibling" \
  || bad "resolution hint co-located (rc=$RC: $OUT)"

# --- case I: template import contract flipped to in-tree co-located --------------
TPL="$REPO_ROOT/skills/lcars-run/stages/implement-test-writer.md"
grep -q "co-located" "$TPL" && grep -qF "from './utils'" "$TPL" \
  && ok "template instructs co-located ./sibling imports for in-tree placement" \
  || bad "template co-located import guidance present"
! grep -q "NEVER.*co-located \`./<sibling>\`" "$TPL" && ! grep -q "__lcarsq__" "$TPL" \
  && ok "template no longer forbids ./sibling / references __lcarsq__ quarantine" \
  || bad "template still forbids ./sibling or mentions __lcarsq__"

echo
printf 'test-convention: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
