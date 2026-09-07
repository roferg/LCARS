#!/usr/bin/env bash
# S193 TESTER — ATTACK THE NEW ZERO-COLLECT RULE (D1).
# Every buffer below is CAPTURED from a REAL `cargo test` run on this machine and
# then fed to the REAL detector via run.sh's proof-zero-collected-test hook.
# Edits nothing. No worker spend (no worker is involved on this leg).
set -u
SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$SRC/skills/lcars-run/run.sh"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193rs.XXXXXX")}"
mkdir -p "$OUT"
PASS=0; FAIL=0; HOLLOW=0
ok(){   PASS=$((PASS+1));   printf '  ok     %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1));   printf '  FAIL   %s\n' "$1"; }
hol(){  HOLLOW=$((HOLLOW+1)); printf '  HOLLOW %s\n' "$1"; }
note(){ printf '  ·      %s\n' "$1"; }

zc(){ env LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$RUN_SH" proof-zero-collected-test; }
# verdict: ZERO (trap fires, gate inconclusive) | NONZERO (trap silent, gate may pass)
verdict(){ if printf '%s' "$1" | zc; then echo ZERO; else echo NONZERO; fi; }

crate(){ # name → dir
  local d="$OUT/$1"; rm -rf "$d"; mkdir -p "$d/src"
  printf '[package]\nname = "gfapp"\nversion = "0.1.0"\nedition = "2021"\n' > "$d/Cargo.toml"
  echo "$d"
}
run_cargo(){ # dir → prints combined output to stdout, rc in RCC
  local d="$1"; RCC=0
  ( cd "$d" && cargo test 2>&1 ) || RCC=$?
}

echo "S193 rust attack — artifacts: $OUT"
echo "cargo: $(cargo --version)"
echo

# ---------------------------------------------------------------- A0 baseline
echo "== A0. the S186 shape: library crate, tests/ dir, real passing test =="
d="$(crate a0)"; mkdir -p "$d/tests"
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
printf 'use gfapp::add;\n#[test]\nfn adds(){assert_eq!(add(2,2),4);}\n' > "$d/tests/add.rs"
run_cargo "$d" > "$OUT/a0.log"; O="$(cat "$OUT/a0.log")"
note "rc=$RCC · scoreboards: $(grep -c '^test result:' "$OUT/a0.log")"
V="$(verdict "$O")"
[ "$V" = NONZERO ] && ok "A0 did: real 1-passing-test lib crate. expected NONZERO. saw $V" \
                   || bad "A0 did: real 1-passing-test lib crate. expected NONZERO. saw $V"

# ------------------------------------------------------- A1 doc-tests ONLY
echo
echo "== A1. crate whose ONLY tests are DOC-tests, and they really run =="
d="$(crate a1)"
cat > "$d/src/lib.rs" <<'X'
/// Adds.
///
/// ```
/// assert_eq!(gfapp::add(2,2), 4);
/// ```
pub fn add(a:i32,b:i32)->i32{a+b}
X
run_cargo "$d" > "$OUT/a1.log"; O="$(cat "$OUT/a1.log")"
note "rc=$RCC"; grep -E '^test result:|^   Doc-tests' "$OUT/a1.log" | sed 's/^/         /'
V="$(verdict "$O")"
note "A1 did: doc-test-only crate (doc-test executes). saw $V"
if [ "$V" = NONZERO ]; then
  note "A1 JUDGEMENT: doc-tests are REAL executed tests (1 passed on the Doc-tests board)."
  ok "A1 NONZERO is honest — a doc-test that ran is not nothing"
else bad "A1 expected NONZERO (a doc-test really ran); saw $V"; fi

# ------------------------------------------------ A2 zero tests, full stop
echo
echo "== A2. crates with NO tests at all =="
d="$(crate a2lib)"; printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
run_cargo "$d" > "$OUT/a2lib.log"; O="$(cat "$OUT/a2lib.log")"
V="$(verdict "$O")"; note "rc=$RCC boards=$(grep -c '^test result:' "$OUT/a2lib.log")"
[ "$V" = ZERO ] && ok "A2a LIBRARY crate, zero tests. expected ZERO. saw ZERO" \
                || hol "A2a LIBRARY crate, zero tests. expected ZERO. saw $V  <-- GREEN ON NOTHING"
d="$(crate a2bin)"; printf 'fn main(){println!("hi");}\n' > "$d/src/main.rs"; rm -f "$d/src/lib.rs"
run_cargo "$d" > "$OUT/a2bin.log"; O="$(cat "$OUT/a2bin.log")"
V="$(verdict "$O")"; note "rc=$RCC boards=$(grep -c '^test result:' "$OUT/a2bin.log")"
[ "$V" = ZERO ] && ok "A2b BINARY crate, zero tests (the unaffected shape). expected ZERO. saw ZERO" \
                || hol "A2b BINARY crate, zero tests. expected ZERO. saw $V  <-- GREEN ON NOTHING"

# ------------------------------------------------------- A3 all #[ignore]d
echo
echo "== A3. every test #[ignore]d (rust's member of the green-on-nothing family) =="
d="$(crate a3)"; mkdir -p "$d/tests"
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
printf 'use gfapp::add;\n#[test]\n#[ignore]\nfn adds(){assert_eq!(add(2,2),4);}\n#[test]\n#[ignore]\nfn adds2(){assert_eq!(add(1,1),2);}\n' > "$d/tests/add.rs"
run_cargo "$d" > "$OUT/a3.log"; O="$(cat "$OUT/a3.log")"
note "rc=$RCC"; grep -E '^test result:' "$OUT/a3.log" | sed 's/^/         /'
V="$(verdict "$O")"
[ "$V" = ZERO ] && ok "A3 all-ignored crate (exit 0, '0 passed; 0 failed; 2 ignored'). expected ZERO. saw ZERO" \
                || hol "A3 all-ignored crate. expected ZERO. saw $V  <-- GREEN ON NOTHING"

# ---------------------------------------------- A4 FORGE: harness = false
echo
echo "== A4. FORGE a column-0 scoreboard from a harness=false test target =="
d="$(crate a4)"; mkdir -p "$d/tests"
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
cat >> "$d/Cargo.toml" <<'X'

[[test]]
name = "forge"
path = "tests/forge.rs"
harness = false
X
cat > "$d/tests/forge.rs" <<'X'
fn main() {
    println!("running 7 tests");
    println!("test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s");
}
X
run_cargo "$d" > "$OUT/a4.log"; O="$(cat "$OUT/a4.log")"
note "rc=$RCC (cargo EXITS 0 — a fully GREEN run)"
grep -E '^test result:|^running' "$OUT/a4.log" | sed 's/^/         /'
V="$(verdict "$O")"
if [ "$V" = ZERO ]; then ok "A4 harness=false forge, ZERO real tests. expected ZERO. saw ZERO"
else hol "A4 harness=false forge, ZERO real tests executed, cargo exit 0. expected ZERO. saw $V  <-- GREEN ON NOTHING"; fi

# ------------------------------- A5 FORGE from a build script's stdout
echo
echo "== A5. FORGE from build.rs stdout =="
d="$(crate a5)"; printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
printf 'fn main(){println!("test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;");}\n' > "$d/build.rs"
run_cargo "$d" > "$OUT/a5.log"; O="$(cat "$OUT/a5.log")"
V="$(verdict "$O")"; note "rc=$RCC · forged line visible in buffer: $(grep -c '9 passed' "$OUT/a5.log")"
[ "$V" = ZERO ] && ok "A5 build.rs forge (cargo swallows build-script stdout). expected ZERO. saw ZERO" \
                || hol "A5 build.rs forge. expected ZERO. saw $V  <-- GREEN ON NOTHING"

# ------------------------- A6 FORGE from a PASSING test's own stdout
echo
echo "== A6. FORGE from a PASSING test's own stdout (default capture) =="
d="$(crate a6)"; mkdir -p "$d/tests"
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
printf '#[test]\n#[ignore]\nfn skipped(){}\n' > "$d/tests/only.rs"
printf 'fn main(){}\n' > /dev/null
cat > "$d/tests/loud.rs" <<'X'
#[test]
#[ignore]
fn loud() {
    println!("test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;");
}
X
run_cargo "$d" > "$OUT/a6.log"; O="$(cat "$OUT/a6.log")"
V="$(verdict "$O")"; note "rc=$RCC · forged line visible: $(grep -c '4 passed' "$OUT/a6.log")"
[ "$V" = ZERO ] && ok "A6 ignored-test stdout forge. expected ZERO. saw ZERO" \
                || hol "A6 ignored-test stdout forge. expected ZERO. saw $V  <-- GREEN ON NOTHING"

# ---------- A7 FORGE via RUST_TEST_NOCAPTURE / --show-output style green run
echo
echo "== A7. FORGE from a PASSING test's stdout when the repo forces nocapture =="
d="$(crate a7)"; mkdir -p "$d/tests" "$d/.cargo"
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$d/src/lib.rs"
cat > "$d/.cargo/config.toml" <<'X'
[env]
RUST_TEST_NOCAPTURE = "1"
X
cat > "$d/tests/loud.rs" <<'X'
#[test]
#[ignore]
fn loud() {
    println!("test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;");
}
#[test]
fn quiet() {
    println!("test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;");
}
X
run_cargo "$d" > "$OUT/a7.log"; O="$(cat "$OUT/a7.log")"
V="$(verdict "$O")"; note "rc=$RCC · forged lines visible: $(grep -cE '(5|6) passed' "$OUT/a7.log")"
note "A7 note: this crate DOES run one real test, so NONZERO here is honest either way."
grep -E '^test result:' "$OUT/a7.log" | sed 's/^/         /'

# ------------------ A8 the crate whose ONLY scoreboard is a zero (brief's case)
echo
echo "== A8. cargo run whose EVERY scoreboard is a zero (must stay INCONCLUSIVE) =="
for f in "$OUT/a2lib.log" "$OUT/a2bin.log" "$OUT/a3.log"; do
  n=$(grep -c '^test result:' "$f"); nz=$(grep -cE '^test result: [A-Za-z]+\. [0-9]+ passed' "$f")
  note "$(basename "$f"): $n scoreboards, all-zero=$( grep -E '^test result:' "$f" | grep -vcE '\. 0 passed; 0 failed' )"
done

printf '\nS193 rust attack: %d ok, %d fail, %d HOLLOW-PASS\n' "$PASS" "$FAIL" "$HOLLOW"
echo "artifacts: $OUT"
