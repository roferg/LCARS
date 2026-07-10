#!/usr/bin/env bash
# Fast, SCOPED test for the S104 multi-stack breadth round.
#
# The red-gate classifier (rg_signature + the three detectors) has recognised
# only JS/TS + Python failure phrasings since S96. A Rust cargo compile error, a
# Go build "cannot find package", a dotnet CS#### error, or a JVM javac "cannot
# find symbol" was UNRECOGNIZED — a new-stack repo died illegibly. This round
# ADDS anchored rust / go / dotnet / jvm signatures to the compile + resolution
# arms, following the EXISTING arm discipline: every new signature is anchored so
# a genuine assertion diff that merely QUOTES a compile phrase stays a valid red.
#
# OFFLINE + FREE: pure string classification. Extract the classifier functions
# out of run.sh into a temp lib and source them (the red-gate-preflight pattern).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# --- extract the classifier functions into a sourceable lib -----------------
# red_gate_compile_failure delegates to red_gate_resolution_failure, so BOTH
# must be present; rg_signature backs all three detectors.
LIB="$(mktemp "$TMPROOT/lib.XXXX")"
sed -n '/^rg_signature() {/,/^}/p'                "$SCRIPT" >"$LIB"
sed -n '/^red_gate_compile_failure() {/,/^}/p'    "$SCRIPT" >>"$LIB"
sed -n '/^red_gate_resolution_failure() {/,/^}/p' "$SCRIPT" >>"$LIB"
sed -n '/^red_gate_env_failure() {/,/^}/p'        "$SCRIPT" >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"

compile()    { red_gate_compile_failure    "$1"; }   # rc 0 = compile/load failure
resolution() { red_gate_resolution_failure "$1"; }   # rc 0 = module-resolution failure
env_fail()   { red_gate_env_failure        "$1"; }   # rc 0 = runner could not launch

# === REAL runner-output fixtures (as the tools actually print) ==============

# cargo build/compile error (rustc E-coded + the crate-compile summary).
CARGO_COMPILE='   Compiling app v0.1.0 (/src/app)
error[E0425]: cannot find function `comput` in this scope
  --> src/lib.rs:5:13
   |
5  |     let x = comput(2, 3);
   |             ^^^^^^ help: a function with a similar name exists: `compute`
error: could not compile `app` (lib) due to 1 previous error'

# cargo test ASSERTION failure — a genuine red (runner ran, an assert failed).
CARGO_ASSERT='running 1 test
test tests::it_adds ... FAILED

failures:

---- tests::it_adds stdout ----
thread '\''tests::it_adds'\'' panicked at src/lib.rs:7:9:
assertion `left == right` failed
  left: 4
 right: 5
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace

failures:
    tests::it_adds

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out'

# go build — a missing package (modern modules phrasing).
GO_RESOLUTION='# example.com/app
main.go:6:2: no required module provides package example.com/util; to add it:
	go get example.com/util'

# go test ASSERTION failure — a genuine red.
GO_ASSERT='--- FAIL: TestAdd (0.00s)
    add_test.go:12: Add(2, 3) = 6; want 5
FAIL
FAIL	example.com/app	0.002s'

# dotnet / csc compiler error + the MSBuild summary.
DOTNET_COMPILE='Program.cs(12,17): error CS0103: The name '\''Comput'\'' does not exist in the current context [/src/App/App.csproj]

Build FAILED.
    0 Warning(s)
    1 Error(s)'

# javac "cannot find symbol" (file-prefixed, as javac/gradle print it).
JVM_COMPILE='src/main/java/com/example/App.java:14: error: cannot find symbol
        int x = comput();
                ^
  symbol:   method comput()
  location: class App
1 error'

echo "S104 multi-stack — rust / go / dotnet / jvm signatures"

# 1. cargo compile error → compile-failure detected.
compile "$CARGO_COMPILE" && ok "1. cargo compile error → compile-failure" \
  || bad "1. cargo compile error not detected as compile-failure"

# 2. cargo test assertion → valid red (NOT compile, NOT env).
compile  "$CARGO_ASSERT" && bad "2a. cargo assertion falsely matched compile-failure" \
  || ok "2a. cargo assertion → not a compile-failure (valid red)"
env_fail "$CARGO_ASSERT" && bad "2b. cargo assertion falsely matched env-failure" \
  || ok "2b. cargo assertion → not an env-failure (valid red)"

# 3. go "cannot find package" → resolution-failure; go assertion → valid red.
resolution "$GO_RESOLUTION" && ok "3a. go missing-package → resolution-failure" \
  || bad "3a. go missing-package not detected as resolution-failure"
compile  "$GO_ASSERT" && bad "3b. go assertion falsely matched compile-failure" \
  || ok "3b. go assertion → not a compile-failure (valid red)"
env_fail "$GO_ASSERT" && bad "3c. go assertion falsely matched env-failure" \
  || ok "3c. go assertion → not an env-failure (valid red)"

# 4. dotnet CS error → compile; javac cannot-find-symbol → compile.
compile "$DOTNET_COMPILE" && ok "4a. dotnet CS#### error → compile-failure" \
  || bad "4a. dotnet CS error not detected as compile-failure"
compile "$JVM_COMPILE" && ok "4b. javac cannot-find-symbol → compile-failure" \
  || bad "4b. javac cannot-find-symbol not detected as compile-failure"

# 5. QUOTED-PHRASE GUARD — an assertion diff that QUOTES a compile phrase stays a
#    valid red (the anchoring discipline, mirroring the env arm's line-start guard).
JS_QUOTES_COMPILE="AssertionError: expected 'error: could not compile foo' to equal 'ok'"
compile "$JS_QUOTES_COMPILE" && bad "5a. quoted 'could not compile' falsely matched compile" \
  || ok "5a. assertion quoting 'could not compile' → valid red (not compile)"
GO_QUOTED_ASSERT='--- FAIL: TestErr (0.00s)
    err_test.go:8: got error "cannot find package foo", want nil
FAIL'
resolution "$GO_QUOTED_ASSERT" && bad "5b. quoted 'cannot find package' falsely matched resolution" \
  || ok "5b. assertion quoting 'cannot find package' → valid red (not resolution)"

# 6. REGRESSION — pre-existing JS/Python arms unchanged.
compile 'Cannot find module ../src/foo' && ok "6a. JS 'Cannot find module' → compile (unchanged)" \
  || bad "6a. JS 'Cannot find module' regressed"
compile 'AssertionError: expected 3 to be 4' && bad "6b. plain assertion falsely matched compile" \
  || ok "6b. plain 'expected 3 to be 4' → valid red (unchanged)"

echo
printf 'multi-stack-classify: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
