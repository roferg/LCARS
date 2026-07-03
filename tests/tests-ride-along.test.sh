#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S102 change: the Test-Writer's LOCKED test RIDES
# ALONG INTO THE PR — committed in its OWN commit BEFORE the Implementer runs — while
# the immutable/adversarial contract is preserved ACROSS the commit boundary.
#
# It proves, offline + free (no real vitest, no worker, no tokens):
#   1. Phase 1 (impl-save-tests) in worktree mode commits the LOCKED test in its own
#      commit (recorded to .test-commit-sha) that contains ONLY the test file(s) —
#      the greenfield STUB and every other change stay UNCOMMITTED and overwritable.
#   2. The two commits reach the branch in order: replaying .test-commit-sha then
#      .commit-sha lands test-commit BEFORE impl-commit; the branch diff carries BOTH
#      the *.test.* file and the source (would reach the PR).
#   3. Cross-boundary immutability: an Implementer that weakens the COMMITTED test is
#      caught at ticket-green (post_commit_gate → PCRC=4) AND at the pre-merge gate
#      (full_suite_gate → BLOCK/die) — never a normal red, never self-heal.
#   4. A MULTI-FILE ticket commits ALL its locked test files (and no source).
#   5. Back-compat: a branch-less / local-only mission does NOT commit (S101 behaviour)
#      and the red gate still greens (greenfield stub stays overwritable).
#
# Drives the REAL run.sh persistence subcommands + a FAKE co-located testCommand.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# FAKE testCommand: simulates CO-LOCATED module resolution for every test under
# $LCARS_TESTS_DIR, resolving each test's `./sibling` import relative to THAT test's
# OWN dir. Missing sibling → resolution red; sibling present but no REAL_IMPL → an
# assertion red; all siblings REAL_IMPL → green.
write_fake_cmd() { # repo
  cat > "$1/faketest.sh" <<'SH'
#!/usr/bin/env bash
set -u
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null | LC_ALL=C sort)"
if [ -z "$files" ]; then echo "No test files found"; exit 1; fi
red=0
for tf in $files; do
  td="$(dirname "$tf")"
  spec="$(grep -hoE "from[[:space:]]*['\"][^'\"]+['\"]" "$tf" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")"
  mod="$td/${spec#./}.ts"
  if [ ! -f "$mod" ]; then echo "Failed to resolve import \"$spec\" Does the file exist?"; exit 1; fi
  if ! grep -q REAL_IMPL "$mod"; then red=1; fi
done
if [ "$red" -ne 0 ]; then echo "AssertionError: expected value to be defined, got undefined"; exit 1; fi
exit 0
SH
}

# A fresh git repo whose main branch has src/b/bar.ts committed, plus a mission
# parked at implement. When $1=branch, state.json records a mission branch created
# at main (so tests ride along committed); otherwise it is a branch-less mission.
new_repo() { # [branch] -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/src/b"; printf 'export function bar(){}\n' > "$repo/src/b/bar.ts"
  ( cd "$repo" && git add src/b/bar.ts && git commit -q -m base )
  mkdir -p "$repo/.git/lcars/missions/m1/tickets/t-001" "$repo/.git/lcars/missions/m1/manifests"
  if [ "${1:-}" = branch ]; then
    ( cd "$repo" && git branch feat/m1 main )
    cat > "$repo/.git/lcars/missions/m1/state.json" <<'JSON'
{ "id": "m1", "type": "feature", "title": "t", "stage": "implement", "branch": "feat/m1" }
JSON
  else
    cat > "$repo/.git/lcars/missions/m1/state.json" <<'JSON'
{ "id": "m1", "type": "feature", "title": "t", "stage": "implement" }
JSON
  fi
  cat > "$repo/.git/lcars/missions/m1/manifests/t-001.md" <<'MD'
## Relevant files
- `src/a/foo.ts` — greenfield helper (new)
- `src/b/bar.ts` — existing module (edited)
MD
  write_fake_cmd "$repo"
  echo "$repo"
}

# Cut a detached ticket worktree at the branch tip; echoes its path.
cut_wt() { # repo branch -> echoes wt
  local wt="$1/.git/lcars/missions/m1/wt-t-001"
  ( cd "$1" && git worktree add -q --detach "$wt" "$2" >/dev/null 2>&1 )
  echo "$wt"
}

# Run impl-save-tests in WORKTREE MODE (cwd = worktree, LCARS_TICKET_WORKTREE set).
save_tests_wt() { # repo wt tests stubs-or-empty -> sets RC/OUT
  local repo="$1" wt="$2" tests="$3" stubs="$4"
  local args=(impl-save-tests --mission m1 --ticket t-001 --tests "$tests")
  [ -n "$stubs" ] && args+=(--stubs "$stubs")
  OUT="$( cd "$wt" && LCARS_TICKET_WORKTREE="$wt" LCARS_TEST_CMD="bash $repo/faketest.sh" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$SCRIPT" "${args[@]}" 2>&1 )"
  RC=$?
}

echo "S102 tests ride along — committed test BEFORE impl, immutable across the boundary"

# =====================================================================================
# Case 1: worktree Phase 1 commits ONLY the locked test; the greenfield stub stays
# uncommitted + unsnapshotted (S94 intact).
# =====================================================================================
repo="$(new_repo branch)"; wt="$(cut_wt "$repo" feat/m1)"
tdir="$repo/_t"; sdir="$repo/_s"
mkdir -p "$tdir"; cat > "$tdir/foo.test.ts" <<'TS'
import { foo } from './foo';
test('foo', () => { expect(foo()).toBe(1); });
TS
mkdir -p "$sdir/src/a"; printf 'export function foo(){}\n' > "$sdir/src/a/foo.ts"
save_tests_wt "$repo" "$wt" "$tdir" "$sdir"

{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "rides along into the PR"; } \
  && ok "worktree Phase 1 accepted + reports the test committed" \
  || bad "worktree Phase 1 accepted (rc=$RC: $OUT)"

tsha="$(cat "$repo/.git/lcars/missions/m1/tickets/t-001/.test-commit-sha" 2>/dev/null || true)"
[ -n "$tsha" ] \
  && ok ".test-commit-sha recorded (worktree detached-HEAD commit)" \
  || bad ".test-commit-sha recorded"

names="$( cd "$wt" && git show --name-only --format= "$tsha" 2>/dev/null )"
{ printf '%s' "$names" | grep -qx "src/a/foo.test.ts"; } \
  && ok "the test commit contains the locked test (src/a/foo.test.ts)" \
  || bad "test commit contains the test (names=$names)"
{ ! printf '%s' "$names" | grep -qx "src/a/foo.ts"; } \
  && ok "the test commit does NOT contain the greenfield stub (uncommitted/overwritable)" \
  || bad "test commit excludes the stub (names=$names)"

snap="$repo/.git/lcars/missions/m1/tickets/t-001/tests.sha256"
{ grep -q "src/a/foo.test.ts" "$snap" && ! grep -q "src/a/foo.ts$" "$snap"; } \
  && ok "snapshot records the test relpath but NOT the stub (S94 intact)" \
  || bad "snapshot records test not stub (snap=$(cat "$snap" 2>/dev/null))"
# the stub is present in the worktree but UNTRACKED (the Implementer overwrites it)
{ [ -f "$wt/src/a/foo.ts" ] && [ -n "$( cd "$wt" && git ls-files --others -- src/a/foo.ts )" ]; } \
  && ok "greenfield stub present but UNTRACKED in the worktree" \
  || bad "greenfield stub untracked in worktree"

# =====================================================================================
# Case 2: full Phase 1 + Phase 2 → test commit BEFORE impl commit on the branch; the
# branch diff carries BOTH the *.test.* and the source (reaches the PR).
# =====================================================================================
repo="$(new_repo branch)"; wt="$(cut_wt "$repo" feat/m1)"
tdir="$repo/_t"
mkdir -p "$tdir"; cat > "$tdir/bar.test.ts" <<'TS'
import { bar } from './bar';
test('bar', () => { expect(bar()).toBe(2); });
TS
save_tests_wt "$repo" "$wt" "$tdir" ""    # bar.ts exists → assertion red, no stub
[ "$RC" -eq 0 ] || bad "case2 Phase 1 accepted (rc=$RC: $OUT)"
tsha="$(cat "$repo/.git/lcars/missions/m1/tickets/t-001/.test-commit-sha" 2>/dev/null || true)"

# Phase 2: the Implementer makes bar.ts REAL_IMPL, then impl-save-result commits it.
printf 'export function bar(){ return 2; /* REAL_IMPL */ }\n' > "$wt/src/b/bar.ts"
cat > "$repo/result.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "implement bar" }
JSON
OUT2="$( cd "$wt" && LCARS_TICKET_WORKTREE="$wt" LCARS_TEST_CMD="bash $repo/faketest.sh" \
          LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$SCRIPT" impl-save-result \
          --mission m1 --ticket t-001 --result "$repo/result.json" 2>&1 )"; RC2=$?
{ [ "$RC2" -eq 0 ] && printf '%s' "$OUT2" | grep -q "result saved"; } \
  && ok "Phase 2 impl-save-result green (post-commit gate passed against committed test in place)" \
  || bad "Phase 2 green (rc=$RC2: $OUT2)"
isha="$(cat "$repo/.git/lcars/missions/m1/tickets/t-001/.commit-sha" 2>/dev/null || true)"
[ -n "$isha" ] && [ "$isha" != "$tsha" ] \
  && ok ".commit-sha (impl) recorded, distinct from the test commit" \
  || bad ".commit-sha distinct from test commit (t=$tsha i=$isha)"

# Replay both onto the real branch in wave order: test commit FIRST, then impl.
( cd "$repo" && git worktree remove --force "$wt" >/dev/null 2>&1 || : )
replay() { ( cd "$repo" && LCARS_GIT_BIN=git bash "$SCRIPT" replay-commit \
              --mission m1 --branch feat/m1 --sha "$1" --ticket t-001 >/dev/null 2>&1 ); }
replay "$tsha" && replay "$isha"

log1="$( cd "$repo" && git log --format=%s feat/m1 | sed -n '1p' )"
log2="$( cd "$repo" && git log --format=%s feat/m1 | sed -n '2p' )"
{ printf '%s' "$log1" | grep -q '^lcars(' && printf '%s' "$log2" | grep -q "^test(t-001):"; } \
  && ok "branch history: TEST commit is the PARENT of the impl commit (test before impl)" \
  || bad "commit order (top='$log1' below='$log2')"

diff_ns="$( cd "$repo" && git diff --name-status main..feat/m1 )"
{ printf '%s' "$diff_ns" | grep -q "src/b/bar.test.ts" && printf '%s' "$diff_ns" | grep -q "src/b/bar.ts$"; } \
  && ok "branch diff carries BOTH the locked test AND the source (reaches the PR)" \
  || bad "branch diff has test + source (diff=$diff_ns)"

# Clean committed path: the pre-merge gate runs the committed test IN PLACE (no overlay)
# and passes green — proving the intact-committed reconciliation works before we tamper.
cat > "$repo/.git/lcars/missions/m1/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001" }
      ]
    }
  ]
}
JSON
fsclean="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/faketest.sh" LCARS_GIT_BIN=git \
            bash "$SCRIPT" full-suite-gate-test --mission m1 2>&1 )"
printf '%s' "$fsclean" | grep -q 'FSRC=0' \
  && ok "pre-merge: intact COMMITTED test runs IN PLACE + passes (no overlay of a committed file)" \
  || bad "pre-merge clean committed (fsclean=$fsclean)"

# =====================================================================================
# Case 3 + 4: an Implementer that WEAKENS the committed test is caught at ticket-green
# (post_commit_gate → PCRC=4) AND at the pre-merge gate (full_suite_gate → BLOCK/die).
# Reuse case 2's branch (feat/m1 has base→test→impl, snapshot intact) and add a
# tamper commit that rewrites the locked test.
# =====================================================================================
( cd "$repo" && git checkout -q feat/m1 \
    && printf 'import { bar } from "./bar";\ntest("bar", () => { expect(true).toBe(true); });\n' > src/b/bar.test.ts \
    && git commit -q -am "weaken the locked test" )

# ticket-green (post_commit_gate) — non-worktree mode reads the branch tip.
pcrc="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/faketest.sh" LCARS_GIT_BIN=git \
        LCARS_PC_SIGNAL_OUT="$repo/pc.txt" bash "$SCRIPT" post-commit-gate-test \
        --mission m1 --ticket t-001 2>"$repo/pc.err" )"
{ printf '%s' "$pcrc" | grep -q 'PCRC=4' && grep -q "LOCKED-TEST TAMPERING" "$repo/pc.txt" 2>/dev/null; } \
  && ok "ticket-green: tampered COMMITTED test → post_commit_gate BLOCK (PCRC=4, distinct)" \
  || bad "ticket-green tamper block (pcrc='$pcrc' sig='$(cat "$repo/pc.txt" 2>/dev/null)')"

# pre-merge (full_suite_gate) — needs waves.json listing the ticket.
cat > "$repo/.git/lcars/missions/m1/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001" }
      ]
    }
  ]
}
JSON
fsout="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/faketest.sh" LCARS_GIT_BIN=git \
          bash "$SCRIPT" full-suite-gate-test --mission m1 2>&1 )"; fsrc=$?
{ [ "$fsrc" -ne 0 ] && printf '%s' "$fsout" | grep -q "PRE-MERGE LOCKED-TEST TAMPERING"; } \
  && ok "pre-merge: tampered COMMITTED test → full_suite_gate BLOCKS loud (die, non-zero)" \
  || bad "pre-merge tamper block (rc=$fsrc: $fsout)"

# =====================================================================================
# Case 5: a MULTI-FILE ticket commits ALL its locked test files (and no source).
# =====================================================================================
repo="$(new_repo branch)"; wt="$(cut_wt "$repo" feat/m1)"
tdir="$repo/_t"; sdir="$repo/_s"
mkdir -p "$tdir"
cat > "$tdir/foo.test.ts" <<'TS'
import { foo } from './foo';
test('foo', () => { expect(foo()).toBe(1); });
TS
cat > "$tdir/bar.test.ts" <<'TS'
import { bar } from './bar';
test('bar', () => { expect(bar()).toBe(2); });
TS
mkdir -p "$sdir/src/a"; printf 'export function foo(){}\n' > "$sdir/src/a/foo.ts"
save_tests_wt "$repo" "$wt" "$tdir" "$sdir"
[ "$RC" -eq 0 ] || bad "case5 multi-file Phase 1 accepted (rc=$RC: $OUT)"
tsha="$(cat "$repo/.git/lcars/missions/m1/tickets/t-001/.test-commit-sha" 2>/dev/null || true)"
names="$( cd "$wt" && git show --name-only --format= "$tsha" 2>/dev/null )"
{ printf '%s' "$names" | grep -qx "src/a/foo.test.ts" && printf '%s' "$names" | grep -qx "src/b/bar.test.ts"; } \
  && ok "multi-file: BOTH locked test files in ONE test commit" \
  || bad "multi-file both tests committed (names=$names)"
{ ! printf '%s' "$names" | grep -qE 'foo\.ts$|bar\.ts$' | grep -v test; } \
  && ok "multi-file: no source file committed by the test commit" \
  || bad "multi-file no source in test commit (names=$names)"

# =====================================================================================
# Case 6: back-compat — a branch-less / local-only mission does NOT commit (S101), and
# the red gate still greens (greenfield stub overwritable, test recorded untracked).
# =====================================================================================
repo="$(new_repo)"          # no branch
tdir="$repo/_t"; sdir="$repo/_s"
mkdir -p "$tdir"; cat > "$tdir/foo.test.ts" <<'TS'
import { foo } from './foo';
test('foo', () => { expect(foo()).toBe(1); });
TS
mkdir -p "$sdir/src/a"; printf 'export function foo(){}\n' > "$sdir/src/a/foo.ts"
OUT="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/faketest.sh" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" impl-save-tests --mission m1 --ticket t-001 --tests "$tdir" --stubs "$sdir" 2>&1 )"; RC=$?
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
  && ok "branch-less mission: red gate still greens (S101 flow intact)" \
  || bad "branch-less accepted (rc=$RC: $OUT)"
[ ! -f "$repo/.git/lcars/missions/m1/tickets/t-001/.test-commit-sha" ] \
  && ok "branch-less mission: NO test commit (.test-commit-sha absent — back-compat)" \
  || bad "branch-less no test commit"
ub="$repo/.git/lcars/missions/m1/tickets/t-001/.untracked-before"
grep -q "src/a/foo.test.ts" "$ub" 2>/dev/null \
  && ok "branch-less mission: test recorded in .untracked-before (commit_ticket skips it, S101)" \
  || bad "branch-less test in .untracked-before (ub=$(cat "$ub" 2>/dev/null))"

echo
printf 'tests-ride-along: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
