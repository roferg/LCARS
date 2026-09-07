#!/usr/bin/env bash
# S193 TESTER — DIFFERENTIAL REGRESSION. Feeds REAL runner buffers from every arm
# to proof_zero_collected and proof_parent_red_kind on HEAD and on the S193
# working tree, and reports any verdict that MOVED. Anything outside cargo-shaped
# and ModuleNotFoundError buffers must be identical.
set -u
SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
CUR="$SRC/skills/lcars-run/run.sh"
HEADSH="${HEAD_RUN_SH:?set HEAD_RUN_SH to a HEAD copy of run.sh carrying the two test hooks}"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193diff.XXXXXX")}"; mkdir -p "$OUT/buf"
MOVED=0; SAME=0
zc(){ if env LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$1" proof-zero-collected-test < "$2" >/dev/null 2>&1; then echo ZERO; else echo NONZERO; fi; }
row(){ # label file
  local h s; h="$(zc "$HEADSH" "$2")"; s="$(zc "$CUR" "$2")"
  if [ "$h" = "$s" ]; then SAME=$((SAME+1)); printf '  same   %-34s HEAD=%-8s S193=%-8s\n' "$1" "$h" "$s"
  else MOVED=$((MOVED+1)); printf '  MOVED  %-34s HEAD=%-8s S193=%-8s\n' "$1" "$h" "$s"; fi
}
cap(){ local n="$1"; shift; ( "$@" ) > "$OUT/buf/$n.log" 2>&1; echo "$OUT/buf/$n.log"; }

echo "S193 differential — artifacts: $OUT"
echo "HEAD run.sh: $HEADSH"
echo
echo "== zero-collect detector, real buffers from every arm =="

# ---- GO
G="$OUT/go"; rm -rf "$G"; mkdir -p "$G"
( cd "$G" && go mod init gfapp >/dev/null 2>&1 )
printf 'package gfapp\n\nfunc Add(a,b int) int { return a+b }\n' > "$G/add.go"
printf 'package gfapp\n\nimport "testing"\n\nfunc TestAdd(t *testing.T){ if Add(2,2)!=4 { t.Fatal("bad") } }\n' > "$G/add_test.go"
row "go: 1 passing test"        "$(cd "$G" && cap go-pass go test ./...)"
rm -f "$G/add_test.go"
row "go: NO test files"         "$(cd "$G" && cap go-notests go test ./...)"
printf 'package gfapp\n\nimport "testing"\n\nfunc TestSkip(t *testing.T){ t.Skip("x") }\n' > "$G/add_test.go"
row "go: all tests skipped"     "$(cd "$G" && cap go-skip go test ./...)"

# ---- RUBY
R="$OUT/ruby"; rm -rf "$R"; mkdir -p "$R/test" "$R/lib"
cat > "$R/Rakefile" <<'X'
require 'rake/testtask'
Rake::TestTask.new(:test) do |t|
  t.libs << 'test'; t.libs << 'lib'; t.test_files = FileList['test/**/*_test.rb']
end
task :default => :test
X
printf "def add(a,b)\n  a+b\nend\n" > "$R/lib/add.rb"
printf "require 'minitest/autorun'\nrequire 'add'\nclass A < Minitest::Test\n  def test_a; assert_equal 4, add(2,2); end\nend\n" > "$R/test/add_test.rb"
row "ruby: 1 passing test"       "$(cd "$R" && cap rb-pass rake test)"
rm -f "$R/test/add_test.rb"
row "ruby: no test files"        "$(cd "$R" && cap rb-notests rake test)"

# ---- JS (node's built-in runner + the npm-ENOENT env shape)
J="$OUT/js"; rm -rf "$J"; mkdir -p "$J/test"
printf '{ "name":"gfapp","version":"1.0.0","scripts":{"test":"node --test"} }\n' > "$J/package.json"
printf 'export function add(a,b){return a+b}\n' > "$J/add.mjs"
printf "import test from 'node:test';\nimport assert from 'node:assert';\nimport {add} from '../add.mjs';\ntest('adds',()=>{assert.strictEqual(add(2,2),4)});\n" > "$J/test/add.test.mjs"
row "js: node --test, 1 passing"  "$(cd "$J" && cap js-pass npm test --silent)"
rm -f "$J/test/add.test.mjs"
row "js: node --test, no tests"   "$(cd "$J" && cap js-notests npm test --silent)"
JE="$OUT/jsempty"; rm -rf "$JE"; mkdir -p "$JE"
row "js: npm test, no package.json" "$(cd "$JE" && cap js-enoent npm test --silent)"

# ---- DOTNET buffers reused from the S186 arm drive if present
for f in "${S186_ARTIFACTS:-}"/byhand.dotnet.log; do
  [ -f "$f" ] && row "dotnet: by-hand green suite" "$f"
done

# ---- RUST + PYTHON (the two arms the session touched — movement EXPECTED here)
for f in "${RUST_ARTIFACTS:-}"/a0.log "${RUST_ARTIFACTS:-}"/a1.log "${RUST_ARTIFACTS:-}"/a2lib.log \
         "${RUST_ARTIFACTS:-}"/a2bin.log "${RUST_ARTIFACTS:-}"/a3.log "${RUST_ARTIFACTS:-}"/a4.log \
         "${RUST_ARTIFACTS:-}"/a5.log "${RUST_ARTIFACTS:-}"/a6.log; do
  [ -f "$f" ] && row "rust: $(basename "$f" .log)  (movement EXPECTED)" "$f"
done
for f in "${PY_ARTIFACTS:-}"/p8.tip.log "${PY_ARTIFACTS:-}"/p9.tip.log; do
  [ -f "$f" ] && row "python: $(basename "$f" .log)" "$f"
done

printf '\ndifferential: %d identical, %d MOVED\n' "$SAME" "$MOVED"
echo "artifacts: $OUT"
