#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's S106 MULTI-STACK isolation seam in the Implement
# red gate.
#
# The problem: LCARS's red gate proves the Test-Writer's suite FAILS-first, scoped
# to ONLY the ticket's tests, via a $LCARS_TESTS_DIR quarantine dir (vitest/jest/
# pytest honor a positional dir) + an EMPTY-dir probe that proves scope-was-honored
# (S85). But cargo and go CANNOT be pointed at a tests dir — their tests compile
# INSIDE the crate/package — so scope must be expressed per-runner:
#   rust: `cargo test --test <file-stem>`   (runs ONLY that integration test file)
#   go:   `go test -run '^(<funcs>)$'`       (runs ONLY the staged file's funcs)
# and scope-was-honored is proven by a FILE-ABSENCE probe (rerun the same scoped
# invocation with the staged test removed; a DETECTABLE difference proves the
# runner reacted). This drives the REAL `impl-save-tests` subcommand against REAL
# cargo/go (no tokens, no live model) with a STUB (recording) worker idiom.
#
# It stands up minimal git repos parked at `implement`; the stack is selected with
# LCARS_STACK (the S105 config key's env override). NOT the heavy lcars-run.test.sh.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- common: a fresh git repo with a mission parked at implement (on a branch) ---
new_repo() { # stack -> echoes repo dir; seeds a committed source + branch feat/m
  local stack="$1" repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  case "$stack" in
    rust)
      printf '[package]\nname = "fix"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/Cargo.toml"
      mkdir -p "$repo/src"; printf 'pub fn placeholder() {}\n' > "$repo/src/lib.rs" ;;
    go)
      printf 'module fix\n\ngo 1.26\n' > "$repo/go.mod"
      printf 'package fix\nfunc Placeholder() {}\n' > "$repo/math.go" ;;
  esac
  ( cd "$repo" && git add -A && git commit -qm init && git checkout -q -b feat/m )
  mkdir -p "$repo/.git/lcars/missions/m-001/tickets/t-001"
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement","branch":"feat/m" }\n' \
    > "$repo/.git/lcars/missions/m-001/state.json"
  echo "$repo"
}

save_tests() { # repo stack tests-dir -> sets RC + OUT
  OUT="$( cd "$1" && LCARS_STACK="$2" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" impl-save-tests --mission m-001 --ticket t-001 --tests "$3" 2>&1 )"
  RC=$?
}

SNAP="tests.sha256"
snap_path() { echo "$1/.git/lcars/missions/m-001/tickets/t-001/tests.sha256"; }

# ==========================================================================
# RUST
# ==========================================================================
if ! have cargo; then
  skip "RUST: cargo not installed — SKIPPING all rust assertions LOUDLY (install cargo to cover them)"
else
  # -- authored FAILING integration test importing a not-yet-existent fn --------
  repo="$(new_repo rust)"; adir="$TMPROOT/ar"; mkdir -p "$adir"
  cat > "$adir/add.rs" <<'RS'
#[test]
fn adds() { assert_eq!(fix::add(2, 2), 4); }
RS
  save_tests "$repo" rust "$adir"
  { [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
    && ok "rust: fail-first test passes the red gate (RED accepted)" \
    || bad "rust: red gate should accept the failing test (rc=$RC: $OUT)"

  # rides along at the crate's tests/ convention + committed
  if ls "$repo"/tests/__lcarsq_*.rs >/dev/null 2>&1; then
    ok "rust: staged at the crate tests/ convention (tests/*.rs)"
  else
    bad "rust: expected staged tests/*.rs (found: $(ls "$repo"/tests 2>&1))"
  fi
  if ( cd "$repo" && git show --stat HEAD --format= 2>/dev/null | grep -q 'tests/__lcarsq_.*\.rs' ); then
    ok "rust: locked test committed (rides along into the PR)"
  else
    bad "rust: staged test not committed ($( cd "$repo" && git show --stat HEAD --format=))"
  fi
  # no probe leftover on any path
  if [ -z "$(find "$repo" -name '*.__lcarsq_probe_bak' 2>/dev/null)" ]; then
    ok "rust: file-absence probe leaves no *.bak leftover"
  else
    bad "rust: probe backup leaked: $(find "$repo" -name '*.__lcarsq_probe_bak')"
  fi

  # -- scoped invocation goes RED (no impl) then GREEN (stub impl) --------------
  SC="$( cd "$repo" && LCARS_STACK=rust LCARS_GIT_BIN=git bash "$SCRIPT" native-scope --mission m-001 --ticket t-001 2>&1 )"
  CMD="$(printf '%s\n' "$SC" | sed -n 's/^SCOPED_CMD=//p')"
  case "$CMD" in
    cargo\ test\ --test\ *) ok "rust: scoped invocation is 'cargo test --test <stem>'" ;;
    *) bad "rust: unexpected scoped cmd '$CMD'" ;;
  esac
  ( cd "$repo" && eval "$CMD" >/dev/null 2>&1 ); rrc=$?
  [ "$rrc" -ne 0 ] && ok "rust: scoped run is RED before the impl exists (rc=$rrc)" \
                   || bad "rust: scoped run should be RED pre-impl (rc=$rrc)"
  printf 'pub fn placeholder() {}\npub fn add(a:i32,b:i32)->i32{a+b}\n' > "$repo/src/lib.rs"
  ( cd "$repo" && eval "$CMD" >/dev/null 2>&1 ); grc=$?
  [ "$grc" -eq 0 ] && ok "rust: scoped run GREEN once the stub impl lands (rc=$grc)" \
                   || bad "rust: scoped run should be GREEN post-impl (rc=$grc)"

  # -- SCOPING: a SIBLING integration test must NOT run under the ticket scope ---
  repo="$(new_repo rust)"; adir="$TMPROOT/ar2"; mkdir -p "$adir"
  cat > "$adir/add.rs" <<'RS'
#[test]
fn adds() { assert_eq!(fix::add(2, 2), 4); }
RS
  # a pre-existing sibling integration test that PANICS if ever run
  mkdir -p "$repo/tests"
  cat > "$repo/tests/sibling.rs" <<'RS'
#[test]
fn sibling() { panic!("SIBLING SHOULD NOT RUN"); }
RS
  save_tests "$repo" rust "$adir"
  SC="$( cd "$repo" && LCARS_STACK=rust LCARS_GIT_BIN=git bash "$SCRIPT" native-scope --mission m-001 --ticket t-001 2>&1 )"
  CMD="$(printf '%s\n' "$SC" | sed -n 's/^SCOPED_CMD=//p')"
  SIBOUT="$( cd "$repo" && eval "$CMD" 2>&1 )"
  printf '%s' "$SIBOUT" | grep -q "SIBLING SHOULD NOT RUN" \
    && bad "rust: sibling test RAN under the ticket scope (isolation broken)" \
    || ok "rust: sibling integration test does NOT run under 'cargo test --test <stem>'"

  # -- BLOCK LOUD: a green-on-nothing suite is rejected + cleaned up ------------
  repo="$(new_repo rust)"; gdir="$TMPROOT/rg"; mkdir -p "$gdir"
  cat > "$gdir/g.rs" <<'RS'
#[test]
fn trivially_true() { assert_eq!(2 + 2, 4); }
RS
  save_tests "$repo" rust "$gdir"
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "FAIL first"; } \
    && ok "rust: green-on-nothing suite BLOCKED loud (must fail first)" \
    || bad "rust: green-on-nothing should block (rc=$RC: $OUT)"
  ls "$repo"/tests/__lcarsq_*.rs >/dev/null 2>&1 \
    && bad "rust: staged copy leaked after a BLOCK (not cleaned)" \
    || ok "rust: staged copy removed on the BLOCK exit path"

  # -- BLOCK LOUD: scope unprovable — a file with an assertion but NO #[test] ---
  repo="$(new_repo rust)"; udir="$TMPROOT/ru"; mkdir -p "$udir"
  cat > "$udir/u.rs" <<'RS'
fn helper() { assert_eq!(1, 1); }
RS
  save_tests "$repo" rust "$udir"
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "scope"; } \
    && ok "rust: un-scopable suite (no #[test]) BLOCKED loud, reason names scope" \
    || bad "rust: no-#[test] suite should block on scope (rc=$RC: $OUT)"

  # -- IMMUTABILITY: a tampered staged test is caught at impl-save-result -------
  repo="$(new_repo rust)"; adir="$TMPROOT/ai"; mkdir -p "$adir"
  cat > "$adir/add.rs" <<'RS'
#[test]
fn adds() { assert_eq!(fix::add(2, 2), 4); }
RS
  save_tests "$repo" rust "$adir"
  tampered="$(ls "$repo"/tests/__lcarsq_*.rs 2>/dev/null | head -1)"
  printf '#[test]\nfn adds() { assert_eq!(1, 1); }\n' > "$tampered"   # weaken after lock
  RES="$TMPROOT/res.json"
  printf '{ "ticketId":"t-001","passed":true,"attempts":1,"summary":"x" }\n' > "$RES"
  IMOUT="$( cd "$repo" && LCARS_STACK=rust LCARS_GH_BIN=true LCARS_GIT_BIN=git \
             bash "$SCRIPT" impl-save-result --mission m-001 --ticket t-001 --result "$RES" 2>&1 )"; imrc=$?
  { [ "$imrc" -ne 0 ] && printf '%s' "$IMOUT" | grep -qi "modified the locked test"; } \
    && ok "rust: tampered locked test caught by the immutability guardrail" \
    || bad "rust: tamper should be caught (rc=$imrc: $IMOUT)"
fi

# ==========================================================================
# GO
# ==========================================================================
if ! have go; then
  skip "GO: go not installed — SKIPPING all go assertions LOUDLY (install go to cover them)"
else
  # -- authored FAILING test calling a not-yet-existent fn ---------------------
  repo="$(new_repo go)"; adir="$TMPROOT/ag"; mkdir -p "$adir"
  cat > "$adir/add.go" <<'GO'
package fix
import "testing"
func TestAdds(t *testing.T) { if Add(2, 2) != 4 { t.Fatalf("want 4") } }
GO
  save_tests "$repo" go "$adir"
  { [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; } \
    && ok "go: fail-first test passes the red gate (RED accepted)" \
    || bad "go: red gate should accept the failing test (rc=$RC: $OUT)"

  # rides along as an in-package *_test.go, committed; NOT leading-underscore
  if ls "$repo"/*_test.go 2>/dev/null | grep -q 'lcarsq_.*_test\.go'; then
    ok "go: staged as an in-package *_test.go (go's own convention)"
  else
    bad "go: expected a staged *_test.go (found: $(ls "$repo"/*_test.go 2>&1))"
  fi
  # go IGNORES files that begin with '_' — the marker must NOT lead with underscore
  if ls "$repo"/_*_test.go >/dev/null 2>&1; then
    bad "go: staged test begins with '_' — go would IGNORE it (invisible test)"
  else
    ok "go: staged marker does not lead with '_' (go will compile it)"
  fi
  if ( cd "$repo" && git show --stat HEAD --format= 2>/dev/null | grep -q 'lcarsq_.*_test\.go' ); then
    ok "go: locked test committed (rides along into the PR)"
  else
    bad "go: staged test not committed ($( cd "$repo" && git show --stat HEAD --format=))"
  fi
  if [ -z "$(find "$repo" -name '*.__lcarsq_probe_bak' 2>/dev/null)" ]; then
    ok "go: file-absence probe leaves no *.bak leftover"
  else
    bad "go: probe backup leaked: $(find "$repo" -name '*.__lcarsq_probe_bak')"
  fi

  # -- scoped invocation RED then GREEN ----------------------------------------
  SC="$( cd "$repo" && LCARS_STACK=go LCARS_GIT_BIN=git bash "$SCRIPT" native-scope --mission m-001 --ticket t-001 2>&1 )"
  CMD="$(printf '%s\n' "$SC" | sed -n 's/^SCOPED_CMD=//p')"
  case "$CMD" in
    go\ test\ -run\ *TestAdds*) ok "go: scoped invocation is 'go test -run ^(<funcs>)\$'" ;;
    *) bad "go: unexpected scoped cmd '$CMD'" ;;
  esac
  ( cd "$repo" && eval "$CMD" >/dev/null 2>&1 ); rrc=$?
  [ "$rrc" -ne 0 ] && ok "go: scoped run is RED before the impl exists (rc=$rrc)" \
                   || bad "go: scoped run should be RED pre-impl (rc=$rrc)"
  printf 'package fix\nfunc Placeholder(){}\nfunc Add(a,b int)int{return a+b}\n' > "$repo/math.go"
  ( cd "$repo" && eval "$CMD" >/dev/null 2>&1 ); grc=$?
  [ "$grc" -eq 0 ] && ok "go: scoped run GREEN once the stub impl lands (rc=$grc)" \
                   || bad "go: scoped run should be GREEN post-impl (rc=$grc)"

  # -- SCOPING: a sibling *_test.go in the package must NOT run -----------------
  repo="$(new_repo go)"; adir="$TMPROOT/ag2"; mkdir -p "$adir"
  cat > "$adir/add.go" <<'GO'
package fix
import "testing"
func TestAdds(t *testing.T) { if Add(2, 2) != 4 { t.Fatalf("want 4") } }
GO
  cat > "$repo/sibling_test.go" <<'GO'
package fix
import "testing"
func TestSibling(t *testing.T) { t.Fatal("SIBLING SHOULD NOT RUN") }
GO
  ( cd "$repo" && git add sibling_test.go && git commit -qm sib )
  save_tests "$repo" go "$adir"
  SC="$( cd "$repo" && LCARS_STACK=go LCARS_GIT_BIN=git bash "$SCRIPT" native-scope --mission m-001 --ticket t-001 2>&1 )"
  CMD="$(printf '%s\n' "$SC" | sed -n 's/^SCOPED_CMD=//p')"
  SIBOUT="$( cd "$repo" && eval "$CMD" 2>&1 )"
  printf '%s' "$SIBOUT" | grep -q "SIBLING SHOULD NOT RUN" \
    && bad "go: sibling test RAN under the ticket -run scope (isolation broken)" \
    || ok "go: sibling *_test.go does NOT run under the ticket's -run pattern"

  # -- BLOCK LOUD: green-on-nothing rejected + cleaned up ----------------------
  repo="$(new_repo go)"; gdir="$TMPROOT/gg"; mkdir -p "$gdir"
  cat > "$gdir/g.go" <<'GO'
package fix
import "testing"
func TestGreen(t *testing.T) { if 1 != 1 { t.Fatal("nope") } }
GO
  save_tests "$repo" go "$gdir"
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "FAIL first"; } \
    && ok "go: green-on-nothing suite BLOCKED loud (must fail first)" \
    || bad "go: green-on-nothing should block (rc=$RC: $OUT)"
  ls "$repo"/lcarsq_*_test.go >/dev/null 2>&1 \
    && bad "go: staged copy leaked after a BLOCK (not cleaned)" \
    || ok "go: staged copy removed on the BLOCK exit path"

  # -- BLOCK LOUD: scope unprovable — assertion but NO func Test… --------------
  repo="$(new_repo go)"; udir="$TMPROOT/gu"; mkdir -p "$udir"
  cat > "$udir/u.go" <<'GO'
package fix
import "testing"
func helper(t *testing.T) { t.Fatal("has assertion but is not a Test func") }
GO
  save_tests "$repo" go "$udir"
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "scope"; } \
    && ok "go: un-scopable suite (no func Test…) BLOCKED loud, reason names scope" \
    || bad "go: no-Test-func suite should block on scope (rc=$RC: $OUT)"

  # -- IMMUTABILITY: tampered staged test caught at impl-save-result -----------
  repo="$(new_repo go)"; adir="$TMPROOT/agi"; mkdir -p "$adir"
  cat > "$adir/add.go" <<'GO'
package fix
import "testing"
func TestAdds(t *testing.T) { if Add(2, 2) != 4 { t.Fatalf("want 4") } }
GO
  save_tests "$repo" go "$adir"
  tampered="$(ls "$repo"/lcarsq_*_test.go 2>/dev/null | head -1)"
  cat > "$tampered" <<'GO'
package fix
import "testing"
func TestAdds(t *testing.T) { if 1 != 1 { t.Fatal("weakened") } }
GO
  RES="$TMPROOT/gres.json"
  printf '{ "ticketId":"t-001","passed":true,"attempts":1,"summary":"x" }\n' > "$RES"
  IMOUT="$( cd "$repo" && LCARS_STACK=go LCARS_GH_BIN=true LCARS_GIT_BIN=git \
             bash "$SCRIPT" impl-save-result --mission m-001 --ticket t-001 --result "$RES" 2>&1 )"; imrc=$?
  { [ "$imrc" -ne 0 ] && printf '%s' "$IMOUT" | grep -qi "modified the locked test"; } \
    && ok "go: tampered locked test caught by the immutability guardrail" \
    || bad "go: tamper should be caught (rc=$imrc: $IMOUT)"
fi

# ==========================================================================
# js/python: the DEFAULT $LCARS_TESTS_DIR path must stay BYTE-IDENTICAL.
# Delegate to the existing scoped suites (they run the unchanged code path).
# ==========================================================================
echo
echo "--- js/python byte-equivalence: running the existing scoped gate suites ---"
JS_OK=1
for suite in red-gate-preflight red-gate-hint greenfield-stubs impl-failure-classify; do
  f="$REPO_ROOT/tests/$suite.test.sh"
  if [ ! -f "$f" ]; then skip "byte-equiv: $suite.test.sh not found"; continue; fi
  if bash "$f" >/dev/null 2>&1; then
    ok "byte-equiv: $suite.test.sh still GREEN (js/python path unchanged)"
  else
    JS_OK=0; bad "byte-equiv: $suite.test.sh REGRESSED (js/python path changed!)"
  fi
done
[ "$JS_OK" -eq 1 ] || :

echo
printf 'multi-stack-isolation: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
