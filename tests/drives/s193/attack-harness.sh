#!/usr/bin/env bash
# S193 FRESH TESTER — attack the harness=false manifest rule (fix round 2).
# Every Cargo.toml below is compiled by REAL cargo; every buffer fed to the REAL
# detector via run.sh's proof-zero-collected-test hook. Edits nothing. No worker.
set -u
SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$SRC/skills/lcars-run/run.sh"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193h.XXXXXX")}"
mkdir -p "$OUT"
PASS=0; FAIL=0; HOLLOW=0; SUNK=0
ok(){   PASS=$((PASS+1));     printf '  ok      %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1));     printf '  FAIL    %s\n' "$1"; }
hol(){  HOLLOW=$((HOLLOW+1)); printf '  HOLLOW  %s\n' "$1"; }
sunk(){ SUNK=$((SUNK+1));     printf '  SUNK    %s\n' "$1"; }
note(){ printf '  ·       %s\n' "$1"; }

# verdict for buffer/rels/root → "ZERO <kind>" | "NONZERO <kind>"
verdict(){ # buf rels root
  local rc=0 o
  o="$(printf '%s' "$1" | env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        LCARS_PZC_RELS="$2" LCARS_PZC_ROOT="$3" LCARS_PZC_SHOW_KIND=1 \
        bash "$RUN_SH" proof-zero-collected-test)" || rc=$?
  local k="${o#PZK=}"
  if [ "$rc" = 0 ]; then echo "ZERO ${k:-none}"; else echo "NONZERO ${k:-none}"; fi
}
FORGE_BODY='fn main(){
  println!("");
  println!("running 2 tests");
  println!("test forged::a ... ok");
  println!("test forged::b ... ok");
  println!("");
  println!("test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");
  println!("");
}'
echo "S193 harness-rule attack — artifacts: $OUT"
echo "cargo: $(cargo --version) · python3: $(python3 -VV 2>&1 | head -1)"
echo
# --------------------------------------------------------------------------
# helper: build a crate at $OUT/<n>[/<sub>], run real cargo test, echo log path
mk(){ # name  → dir
  local d="$OUT/$1"; rm -rf "$d"; mkdir -p "$d/src" "$d/tests"; echo "$d"
}
runc(){ # dir → log to $OUT/<basename>.log ; RCC set
  RCC=0; ( cd "$1" && cargo test 2>&1 ) > "$2" || RCC=$?
}
LIBRS='pub fn add(a:i32,b:i32)->i32{a+b}'
GOODTEST='use gfapp::add;
#[test]
fn adds(){assert_eq!(add(2,2),4);}'
PKG='[package]
name = "gfapp"
version = "0.1.0"
edition = "2021"'

echo "=========== GROUP A — the common case must be BYTE-IDENTICAL (honest) ==========="
# A1 plain honest crate, no harness key anywhere
d="$(mk a1)"; printf '%s\n' "$PKG" > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
runc "$d" "$OUT/a1.log"; V="$(verdict "$(cat "$OUT/a1.log")" 'tests/add.rs' "$d")"
[ "${V%% *}" = NONZERO ] && ok "A1 honest crate, no harness key. expected NONZERO. saw $V" \
                         || sunk "A1 honest crate, no harness key. expected NONZERO. saw $V"

# A2 harness key COMMENTED OUT
d="$(mk a2)"; { printf '%s\n' "$PKG"; printf '\n# harness = false  (we removed criterion)\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=misses
runc "$d" "$OUT/a2.log"; V="$(verdict "$(cat "$OUT/a2.log")" 'tests/add.rs' "$d")"
note "tier-1 grep $T on the comment"
[ "${V%% *}" = NONZERO ] && ok "A2 harness in a COMMENT. expected NONZERO. saw $V" \
                         || sunk "A2 harness in a COMMENT. expected NONZERO. saw $V"

# A3 the word harness inside a string VALUE
d="$(mk a3)"; { printf '%s\n' "$PKG"; printf 'description = "harness = false, we do not use it"\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
runc "$d" "$OUT/a3.log"; V="$(verdict "$(cat "$OUT/a3.log")" 'tests/add.rs' "$d")"
[ "${V%% *}" = NONZERO ] && ok "A3 harness inside a string value. expected NONZERO. saw $V" \
                         || sunk "A3 harness inside a string value. expected NONZERO. saw $V"

# A4 harness = false at column 0 INSIDE a multi-line string (tier1 must fire, tier2 must clear it)
d="$(mk a4)"; { printf '%s\n' "$PKG"; printf 'description = """\nharness = false\n"""\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=misses
runc "$d" "$OUT/a4.log"; V="$(verdict "$(cat "$OUT/a4.log")" 'tests/add.rs' "$d")"
note "tier-1 grep $T inside the multi-line string"
[ "${V%% *}" = NONZERO ] && ok "A4 harness=false inside a multi-line STRING. expected NONZERO. saw $V" \
                         || sunk "A4 harness=false inside a multi-line STRING. expected NONZERO. saw $V"

# A5 explicit harness = true
d="$(mk a5)"; { printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "add"\nharness = true\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
runc "$d" "$OUT/a5.log"; V="$(verdict "$(cat "$OUT/a5.log")" 'tests/add.rs' "$d")"
[ "${V%% *}" = NONZERO ] && ok "A5 explicit harness = true. expected NONZERO. saw $V" \
                         || sunk "A5 explicit harness = true. expected NONZERO. saw $V"

# A6 criterion shape: [[bench]] harness = false, ticket's real libtest test passes
d="$(mk a6)"; mkdir -p "$d/benches"
{ printf '%s\n' "$PKG"; printf '\n[[bench]]\nname = "perf"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
printf 'fn main(){println!("bench");}\n' > "$d/benches/perf.rs"
runc "$d" "$OUT/a6.log"; V="$(verdict "$(cat "$OUT/a6.log")" 'tests/add.rs' "$d")"
[ "${V%% *}" = NONZERO ] && ok "A6 criterion [[bench]] harness=false + real test. expected NONZERO. saw $V" \
                         || sunk "A6 criterion [[bench]] harness=false + real test. expected NONZERO. saw $V"

# A7 same, with hostile whitespace/indentation
d="$(mk a7)"; mkdir -p "$d/benches"
{ printf '%s\n' "$PKG"; printf '\n  [[bench]]\n    name   =   "perf"\n\tharness\t=\tfalse\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
printf 'fn main(){println!("bench");}\n' > "$d/benches/perf.rs"
runc "$d" "$OUT/a7.log"; V="$(verdict "$(cat "$OUT/a7.log")" 'tests/add.rs' "$d")"
[ "${V%% *}" = NONZERO ] && ok "A7 indented/tabbed [[bench]] harness=false + real test. expected NONZERO. saw $V" \
                         || sunk "A7 indented/tabbed [[bench]] harness=false + real test. expected NONZERO. saw $V"

# A8 [lib] harness=false (a real pattern) but the TICKET's test is a normal tests/*.rs
d="$(mk a8)"
{ printf '%s\n' "$PKG"; printf '\n[lib]\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\nfn main(){}\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$GOODTEST" > "$d/tests/add.rs"
runc "$d" "$OUT/a8.log"; V="$(verdict "$(cat "$OUT/a8.log")" 'tests/add.rs' "$d")"
note "rc=$RCC"
[ "${V%% *}" = NONZERO ] && ok "A8 [lib] harness=false, ticket test in tests/. expected NONZERO. saw $V" \
                         || sunk "A8 [lib] harness=false, ticket test in tests/. expected NONZERO. saw $V"
echo
echo "=========== GROUP B — beat the attribution (every one must be ZERO) ==========="
# B1 canonical [[test]] harness=false, NO SPACES
d="$(mk b1)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname="forge"\nharness=false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
runc "$d" "$OUT/b1.log"; V="$(verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
note "forged board present: $(grep -c '2 passed' "$OUT/b1.log")"
[ "${V%% *}" = ZERO ] && ok "B1 [[test]] harness=false, no spaces. expected ZERO. saw $V" \
                      || hol "B1 [[test]] harness=false, no spaces. expected ZERO. saw $V"

# B2 the SAME opt-out expressed as a top-level INLINE-TABLE ARRAY (valid TOML, cargo honours it)
d="$(mk b2)"
{ printf 'test = [{ name = "forge", path = "tests/forge.rs", harness = false }]\n\n'; printf '%s\n' "$PKG"; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/b2.log"; V="$(verdict "$(cat "$OUT/b2.log")" 'tests/forge.rs' "$d")"
note "tier-1 grep $T · cargo honoured the opt-out: $(grep -c 'test forged::a' "$OUT/b2.log") forged line(s)"
[ "${V%% *}" = ZERO ] && ok "B2 inline-table [[test]] harness=false. expected ZERO. saw $V" \
                      || hol "B2 inline-table [[test]] harness=false. expected ZERO. saw $V"

# B3 the SAME opt-out with a QUOTED KEY (valid TOML)
d="$(mk b3)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\n"harness" = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/b3.log"; V="$(verdict "$(cat "$OUT/b3.log")" 'tests/forge.rs' "$d")"
note "tier-1 grep $T · forged line(s): $(grep -c 'test forged::a' "$OUT/b3.log")"
[ "${V%% *}" = ZERO ] && ok "B3 quoted key \"harness\" = false. expected ZERO. saw $V" \
                      || hol "B3 quoted key \"harness\" = false. expected ZERO. saw $V"

# B4 explicit path with ./ and .. noise
d="$(mk b4)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "zzz"\npath = "./tests/../tests/forge.rs"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
runc "$d" "$OUT/b4.log"; V="$(verdict "$(cat "$OUT/b4.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "B4 path = ./tests/../tests/forge.rs, name != file. expected ZERO. saw $V" \
                      || hol "B4 path = ./tests/../tests/forge.rs, name != file. expected ZERO. saw $V"

# B5 the declared file is a SYMLINK to the real forge source
d="$(mk b5)"; mkdir -p "$d/hidden"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/hidden/real.rs"
ln -s ../hidden/real.rs "$d/tests/forge.rs"
runc "$d" "$OUT/b5.log"; V="$(verdict "$(cat "$OUT/b5.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "B5 declared file is a SYMLINK. expected ZERO. saw $V" \
                      || hol "B5 declared file is a SYMLINK. expected ZERO. saw $V"

# B6 crate in a SUBDIRECTORY under a workspace root; declared path is repo-root-relative
d="$(mk b6)"; rm -rf "$d"; mkdir -p "$d/crates/app/src" "$d/crates/app/tests"
printf '[workspace]\nmembers = ["crates/app"]\nresolver = "2"\n' > "$d/Cargo.toml"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\nharness = false\n'; } > "$d/crates/app/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/crates/app/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/crates/app/tests/forge.rs"
runc "$d" "$OUT/b6.log"; V="$(verdict "$(cat "$OUT/b6.log")" 'crates/app/tests/forge.rs' "$d")"
note "cargo announced: $(grep -Eo 'Running tests/[^ ]+' "$OUT/b6.log" | head -1)"
[ "${V%% *}" = ZERO ] && ok "B6 workspace + member crate in a subdir. expected ZERO. saw $V" \
                      || hol "B6 workspace + member crate in a subdir. expected ZERO. saw $V"

# B7 [lib] harness=false and the ticket's test is an INLINE #[cfg(test)] mod in src/lib.rs
d="$(mk b7)"
{ printf '%s\n' "$PKG"; printf '\n[lib]\nharness = false\n'; } > "$d/Cargo.toml"
cat > "$d/src/lib.rs" <<'X'
pub fn add(a:i32,b:i32)->i32{a+b}
fn main(){
  println!("running 1 test");
  println!("test tests::adds ... ok");
  println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");
}
X
runc "$d" "$OUT/b7.log"; V="$(verdict "$(cat "$OUT/b7.log")" 'src/lib.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "B7 [lib] harness=false, ticket declares src/lib.rs. expected ZERO. saw $V" \
                      || hol "B7 [lib] harness=false, ticket declares src/lib.rs. expected ZERO. saw $V"

# B8 [[bin]] harness=false, name == package, src/main.rs
d="$(mk b8)"
{ printf '%s\n' "$PKG"; printf '\n[[bin]]\nname = "gfapp"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"
{ printf 'fn main(){\n'; printf '  println!("running 1 test");\n'; printf '  println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");\n'; printf '}\n'; } > "$d/src/main.rs"
runc "$d" "$OUT/b8.log"; V="$(verdict "$(cat "$OUT/b8.log")" 'src/main.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "B8 [[bin]] harness=false -> src/main.rs. expected ZERO. saw $V" \
                      || hol "B8 [[bin]] harness=false -> src/main.rs. expected ZERO. saw $V"
echo
echo "=========== GROUP B2 — how wide is the tier-1 hole? ==========="
# B9 [lib] harness=false written as a DOTTED KEY
d="$(mk b9)"
{ printf 'lib.harness = false\n\n'; printf '%s\n' "$PKG"; } > "$d/Cargo.toml"
cat > "$d/src/lib.rs" <<'X'
pub fn add(a:i32,b:i32)->i32{a+b}
fn main(){
  println!("running 1 test");
  println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");
}
X
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/b9.log"; V="$(verdict "$(cat "$OUT/b9.log")" 'src/lib.rs' "$d")"
note "tier-1 grep $T · cargo honoured it: $(grep -c 'running 1 test' "$OUT/b9.log")"
[ "${V%% *}" = ZERO ] && ok "B9 dotted key lib.harness = false. expected ZERO. saw $V" \
                      || hol "B9 dotted key lib.harness = false. expected ZERO. saw $V"

# B10 [lib] as an INLINE TABLE
d="$(mk b10)"
{ printf 'lib = { harness = false }\n\n'; printf '%s\n' "$PKG"; } > "$d/Cargo.toml"
cp "$OUT/b9/src/lib.rs" "$d/src/lib.rs" 2>/dev/null || cat > "$d/src/lib.rs" <<'X'
pub fn add(a:i32,b:i32)->i32{a+b}
fn main(){ println!("running 1 test");
  println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"); }
X
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/b10.log"; V="$(verdict "$(cat "$OUT/b10.log")" 'src/lib.rs' "$d")"
note "tier-1 grep $T"
[ "${V%% *}" = ZERO ] && ok "B10 inline table lib = { harness = false }. expected ZERO. saw $V" \
                      || hol "B10 inline table lib = { harness = false }. expected ZERO. saw $V"

# B11 THE SAME inline-table opt-out as B2, but the manifest ALSO carries an
# ordinary bare `harness =` line elsewhere so TIER 1 fires. If this is caught,
# the defect is proven to be the tier-1 GREP alone, not the tomllib mapper.
d="$(mk b11)"; mkdir -p "$d/benches"
{ printf 'test = [{ name = "forge", path = "tests/forge.rs", harness = false }]\n\n'
  printf '%s\n' "$PKG"; printf '\n[[bench]]\nname = "perf"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
printf 'fn main(){println!("bench");}\n' > "$d/benches/perf.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/b11.log"; V="$(verdict "$(cat "$OUT/b11.log")" 'tests/forge.rs' "$d")"
note "tier-1 grep $T (thanks to the [[bench]] line)"
[ "${V%% *}" = ZERO ] && ok "B11 inline-table opt-out + a tier-1-visible harness line. expected ZERO. saw $V" \
                      || hol "B11 inline-table opt-out + a tier-1-visible harness line. expected ZERO. saw $V"
echo
echo "=========== GROUP C — the FAIL-CLOSED path (every one must be ZERO) ==========="
# C1 manifest with a harness key that does NOT parse as TOML
d="$(mk c1)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
# cargo cannot build this, so replay a real forged buffer captured in B1
V="$(verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "C1 unparseable Cargo.toml with a harness key. expected ZERO. saw $V" \
                      || hol "C1 unparseable Cargo.toml with a harness key. expected ZERO. saw $V"

# C2 harness is not a boolean
d="$(mk c2)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\nharness = "false"\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
V="$(verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "C2 harness = \"false\" (a string). expected ZERO. saw $V" \
                      || hol "C2 harness = \"false\" (a string). expected ZERO. saw $V"

# C3 stanza whose target path cannot be derived (no name, no path)
d="$(mk c3)"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge.rs"
V="$(verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "C3 [[test]] harness=false with no name and no path. expected ZERO. saw $V" \
                      || hol "C3 [[test]] harness=false with no name and no path. expected ZERO. saw $V"

# C4 a python3 that EXISTS but has NO tomllib (pre-3.11 simulated; real python untouched)
FAKE="$OUT/fakepy"; mkdir -p "$FAKE"
REALPY="$(command -v python3)"
cat > "$FAKE/_block.py" <<'BLK'
import sys
from importlib.abc import MetaPathFinder
class _Block(MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        if name == "tomllib":
            raise ImportError("No module named 'tomllib'")
        return None
sys.meta_path.insert(0, _Block())
BLK
cat > "$FAKE/python3" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = -c ]; then
  code="\$2"; shift 2
  exec "$REALPY" -c "\$(cat "$FAKE/_block.py"; printf '%s' "\$code")" "\$@"
fi
exec "$REALPY" "\$@"
WRAP
chmod +x "$FAKE/python3"
if "$FAKE/python3" -c 'import tomllib' >/dev/null 2>&1; then
  note "RIG BUG: fake python3 still has tomllib — C4 not exercised"
else
  note "fake python3 confirmed: 'import tomllib' raises (real interpreter untouched)"
fi
d="$OUT/b1"
V="$(PATH="$FAKE:$PATH" verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
[ "$V" = "ZERO manifest-unreadable" ] && ok "C4 python3 without tomllib. expected 'ZERO manifest-unreadable'. saw $V" \
                                     || hol "C4 python3 without tomllib. expected 'ZERO manifest-unreadable'. saw $V"

# C5 NO python3 on PATH at all
EMPTY="$OUT/nopy"; mkdir -p "$EMPTY"
for b in bash sh grep sed awk tr cat printf env dirname basename sort git; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$EMPTY/$b"
done
command -v python3 >/dev/null && :
V="$(PATH="$EMPTY" verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "$d")"
[ "$V" = "ZERO manifest-unreadable" ] && ok "C5 no python3 on PATH. expected 'ZERO manifest-unreadable'. saw $V" \
                                     || hol "C5 no python3 on PATH. expected 'ZERO manifest-unreadable'. saw $V"
echo "=========== GROUP E — tier-2 path derivation & multi-manifest union ==========="
# E1 DIRECTORY-STYLE integration test: cargo auto-discovers tests/<name>/main.rs
#    and ANNOUNCES that path, but tier 2 derives the default `tests/<name>.rs`.
d="$(mk e1)"; mkdir -p "$d/tests/forge"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"; printf '%s\n' "$FORGE_BODY" > "$d/tests/forge/main.rs"
grep -Eq '^[[:space:]]*harness[[:space:]]*=' "$d/Cargo.toml" && T=fires || T=MISSES
runc "$d" "$OUT/e1.log"; V="$(verdict "$(cat "$OUT/e1.log")" 'tests/forge/main.rs' "$d")"
note "tier-1 grep $T · cargo announced $(grep -Eo 'Running tests/[^ ]+' "$OUT/e1.log" | head -1) · tier-2 derives tests/forge.rs"
[ "${V%% *}" = ZERO ] && ok "E1 tests/<name>/main.rs directory-style target. expected ZERO. saw $V" \
                      || hol "E1 tests/<name>/main.rs directory-style target. expected ZERO. saw $V"

# E2 the same shape for a BIN: src/bin/<name>/main.rs
d="$(mk e2)"; mkdir -p "$d/src/bin/tool"
{ printf '%s\n' "$PKG"; printf '\n[[bin]]\nname = "tool"\nharness = false\n'; } > "$d/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/src/lib.rs"
{ printf 'fn main(){\n  println!("running 1 test");\n  println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");\n}\n'; } > "$d/src/bin/tool/main.rs"
runc "$d" "$OUT/e2.log"; V="$(verdict "$(cat "$OUT/e2.log")" 'src/bin/tool/main.rs' "$d")"
note "cargo announced: $(grep -Eo 'Running [^ ]+' "$OUT/e2.log" | tr '\n' ' ')"
[ "${V%% *}" = ZERO ] && ok "E2 src/bin/<name>/main.rs directory-style bin. expected ZERO. saw $V" \
                      || hol "E2 src/bin/<name>/main.rs directory-style bin. expected ZERO. saw $V"

# E3 MULTI-MANIFEST UNION: a workspace ROOT package declaring an opt-out
#    `tests/forge.rs` while the MEMBER crate's tests/forge.rs is HONEST libtest.
#    The union + ends-with rule may attribute the ROOT's opt-out to the MEMBER's file.
d="$(mk e3)"; rm -rf "$d"; mkdir -p "$d/src" "$d/tests" "$d/crates/app/src" "$d/crates/app/tests"
{ printf '[workspace]\nmembers = ["crates/app"]\nresolver = "2"\n\n'
  printf '[package]\nname = "wsroot"\nversion = "0.1.0"\nedition = "2021"\n\n'
  printf '[[test]]\nname = "forge"\nharness = false\n'; } > "$d/Cargo.toml"
printf 'pub fn r()->i32{1}\n' > "$d/src/lib.rs"
printf 'fn main(){println!("root custom harness");}\n' > "$d/tests/forge.rs"
printf '%s\n' "$PKG" > "$d/crates/app/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/crates/app/src/lib.rs"
printf 'use gfapp::add;\n#[test]\nfn forged(){assert_eq!(add(2,2),4);}\n' > "$d/crates/app/tests/forge.rs"
RCC=0; ( cd "$d" && cargo test --workspace 2>&1 ) > "$OUT/e3.log" || RCC=$?
V="$(verdict "$(cat "$OUT/e3.log")" 'crates/app/tests/forge.rs' "$d")"
note "rc=$RCC · the member's HONEST libtest really executed: $(grep -c '^test forged' "$OUT/e3.log") board(s) · cargo announces BOTH targets as tests/forge.rs"
[ "${V%% *}" = NONZERO ] && ok "E3 honest member test vs ROOT opt-out of the same basename. expected NONZERO. saw $V" \
                         || sunk "E3 honest member test vs ROOT opt-out of the same basename. expected NONZERO. saw $V"
echo
echo "=========== GROUP D — the disclosed residual (no root + warm cargo cache) ==========="
d="$OUT/b1"
RCC=0; ( cd "$d" && cargo test 2>&1 ) > "$OUT/d_warm.log" || RCC=$?
CN=$(grep -c '^[[:space:]]*Compiling ' "$OUT/d_warm.log")
note "second (warm) cargo run: 'Compiling' lines = $CN"
V="$(verdict "$(cat "$OUT/d_warm.log")" 'tests/forge.rs' "$d")"
[ "${V%% *}" = ZERO ] && ok "D1 warm cache WITH crate root. expected ZERO. saw $V" \
                      || hol "D1 warm cache WITH crate root. expected ZERO. saw $V"
V="$(verdict "$(cat "$OUT/d_warm.log")" 'tests/forge.rs' "")"
if [ "$CN" -eq 0 ] && [ "${V%% *}" = NONZERO ]; then
  note "D2 RESIDUAL CONFIRMED (unattributed callers only): warm cache + NO root => $V"
  ok "D2 residual is exactly as disclosed"
elif [ "${V%% *}" = ZERO ]; then
  ok "D2 warm cache + NO root still ZERO ($V) — residual not reachable even unattributed"
else
  bad "D2 unexpected: Compiling=$CN verdict=$V"
fi
# D3 cold cache + NO root: the Compiling fallback must save it
V="$(verdict "$(cat "$OUT/b1.log")" 'tests/forge.rs' "")"
note "D3 cold-cache buffer + NO root (Compiling fallback): $V"
[ "${V%% *}" = ZERO ] && ok "D3 Compiling-line fallback works when no root is passed. expected ZERO. saw $V" \
                      || bad "D3 Compiling-line fallback failed. expected ZERO. saw $V"
# D4 does the GATE ever call proof_zero_collected without a root? read the product.
CALLS="$(grep -n 'proof_zero_collected ' "$SRC/skills/lcars-run/run.sh" | grep -v '^[0-9]*:#' | grep -v 'proof_zero_collected()')"
BAD="$(printf '%s\n' "$CALLS" | grep -v 'LCARS_PZC_ROOT' | grep -vc '"\$wt"')"
note "product call sites of proof_zero_collected (excl. the test hook):"
printf '%s\n' "$CALLS" | sed 's/^/         /'
[ "$BAD" -eq 0 ] && ok "D4 every product call site passes a crate root (\$wt)" \
                 || bad "D4 $BAD product call site(s) pass NO crate root"
echo "=========== GROUP F — shadowing the manifest walk-up ==========="
# F1 A STRAY Cargo.toml planted in tests/ stops the walk-up BEFORE the real
#    crate manifest that carries the opt-out. Cargo builds and runs unchanged.
d="$(mk f1)"; rm -rf "$d"; mkdir -p "$d/crates/app/src" "$d/crates/app/tests"
printf '[workspace]\nmembers = ["crates/app"]\nresolver = "2"\n' > "$d/Cargo.toml"
{ printf '%s\n' "$PKG"; printf '\n[[test]]\nname = "forge"\nharness = false\n'; } > "$d/crates/app/Cargo.toml"
printf '%s\n' "$LIBRS" > "$d/crates/app/src/lib.rs"
printf '%s\n' "$FORGE_BODY" > "$d/crates/app/tests/forge.rs"
printf '# not a real package\n[workspace]\n' > "$d/crates/app/tests/Cargo.toml"
RCC=0; ( cd "$d" && cargo test --workspace 2>&1 ) > "$OUT/f1.log" || RCC=$?
V="$(verdict "$(cat "$OUT/f1.log")" 'crates/app/tests/forge.rs' "$d")"
note "cargo rc=$RCC, unaffected by the stray manifest; forged board present: $(grep -c '2 passed' "$OUT/f1.log")"
[ "${V%% *}" = ZERO ] && ok "F1 stray tests/Cargo.toml shadowing the walk-up. expected ZERO. saw $V" \
                      || hol "F1 stray tests/Cargo.toml shadowing the walk-up. expected ZERO. saw $V"
# F1b same tree WITHOUT the stray manifest — the control
d2="$(mk f1b)"; rm -rf "$d2"; cp -R "$d" "$d2"; rm -f "$d2/crates/app/tests/Cargo.toml"
V="$(verdict "$(cat "$OUT/f1.log")" 'crates/app/tests/forge.rs' "$d2")"
[ "${V%% *}" = ZERO ] && ok "F1b control, same buffer, no stray manifest. expected ZERO. saw $V" \
                      || hol "F1b control, same buffer, no stray manifest. expected ZERO. saw $V"
echo
echo "==================== TOTALS ===================="
printf 'ok=%d  FAIL=%d  HOLLOW=%d  SUNK=%d\n' "$PASS" "$FAIL" "$HOLLOW" "$SUNK"
echo "artifacts: $OUT"
[ "$FAIL" -eq 0 ] && [ "$HOLLOW" -eq 0 ] && [ "$SUNK" -eq 0 ]
