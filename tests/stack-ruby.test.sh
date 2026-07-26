#!/usr/bin/env bash
# Fast, SCOPED test for the S145 RUBY stack arm — REAL runner drives.
#
# The Ruby arm adds detect/seed/classify/isolate for rspec + minitest. This
# suite is where the REAL runners live: it drives rspec 3.x and minitest against
# tiny fixtures and asserts the harness seams behave on their ACTUAL output —
#   • native_scoped_cmd(ruby) emits a command that runs ONLY the staged file(s)
#     (siblings are NOT run) — the S106 per-stack isolation invariant;
#   • the emitted command's exit code is 0 on pass / 1 on fail;
#   • a runner that COLLECTS ZERO tests (empty spec dir / no-example spec /
#     no-method minitest) is caught by proof_zero_collected → INCONCLUSIVE, never
#     a pass (the S85/S106 green-on-nothing trap);
#   • the SUBSTRING HAZARD (S106): a healthy 10-example / 10-run suite is NOT
#     falsely flagged zero;
#   • a LOAD-ERROR red (rspec still prints "0 examples" on a LoadError, exit 1)
#     is NOT flagged zero-collected — otherwise a legitimate greenfield fail-on-
#     parent would read INCONCLUSIVE and never prove work.
#
# If no usable ruby/rspec is present the suite SKIPS with a LOUD notice — it
# never silently passes. Zero tokens, offline: real ruby, no bundler/network.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }

echo "S145 ruby stack — REAL rspec + minitest drives"

# --- locate a usable ruby + rspec (user-gem bin is often off PATH) ----------
if ! command -v rspec >/dev/null 2>&1; then
  for d in "$HOME/.gem/ruby"/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
  export PATH
fi
HAVE_RUBY=0; HAVE_RSPEC=0
command -v ruby  >/dev/null 2>&1 && ruby -e 'require "minitest/autorun"' >/dev/null 2>&1 && HAVE_RUBY=1
command -v rspec >/dev/null 2>&1 && ruby -e 'require "rspec"' >/dev/null 2>&1 && HAVE_RSPEC=1

if [ "$HAVE_RUBY" -ne 1 ]; then
  skip "RUBY: no usable ruby+minitest on PATH — SKIPPING the entire ruby real-runner suite LOUDLY"
  echo
  printf 'stack-ruby: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

# --- extract the isolation + zero-collect seams into a sourceable lib --------
LIB="$(mktemp "$TMPROOT/lib.XXXX")"
for fn in resolve_stack stack_is_native native_runner_bin native_scoped_cmd \
          proof_native_run_dir rg_signature suite_collected_zero_tests proof_zero_collected; do
  sed -n "/^$fn() {/,/^}/p" "$SCRIPT" >>"$LIB"
done
# json_str is referenced by resolve_stack when LCARS_STACK is unset; we always
# set LCARS_STACK, but define a harmless stub so sourcing never explodes.
printf 'json_str() { printf ""; }\n' >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"
export LCARS_STACK=ruby

# scoped_cmd REL... → emits native_scoped_cmd(ruby) for the given staged relpaths
scoped_cmd() { printf '%s\n' "$@" | REPO_ROOT="$1" native_scoped_cmd ruby; }

# === 1. ruby is a NATIVE-isolation stack =====================================
( export LCARS_STACK=ruby; stack_is_native ) \
  && ok "1. resolve_stack=ruby ⇒ stack_is_native (native isolation branch)" \
  || bad "1. ruby should be a native-isolation stack"

# === 2. native_scoped_cmd emits an rspec command for a *_spec.rb =============
CMD="$(printf 'spec/foo_spec.rb\n' | REPO_ROOT="$TMPROOT" native_scoped_cmd ruby)"
case "$CMD" in
  "rspec spec/foo_spec.rb") ok "2. spec file ⇒ 'rspec spec/foo_spec.rb'" ;;
  *) bad "2. expected 'rspec spec/foo_spec.rb', got: [$CMD]" ;;
esac

# === 3. native_scoped_cmd emits a minitest command for a *_test.rb ===========
CMD="$(printf 'test/foo_test.rb\n' | REPO_ROOT="$TMPROOT" native_scoped_cmd ruby)"
case "$CMD" in
  "ruby -Itest -e 'ARGV.each { |f| require File.expand_path(f) }' test/foo_test.rb")
    ok "3. test file ⇒ minitest require-each command" ;;
  *) bad "3. unexpected minitest command: [$CMD]" ;;
esac

# === 4. neither spec nor test file ⇒ EMPTY (no runnable target) ==============
CMD="$(printf 'lib/foo.rb\n' | REPO_ROOT="$TMPROOT" native_scoped_cmd ruby)"
[ -z "$CMD" ] && ok "4. non-test staged file ⇒ empty command (no runnable target)" \
             || bad "4. expected empty command for a non-test file, got: [$CMD]"

# === 5. proof_native_run_dir(ruby) = the leg root (Gemfile/repo dir) =========
D="$(proof_native_run_dir ruby /some/root spec/foo_spec.rb)"
[ "$D" = "/some/root" ] && ok "5. run dir for ruby is the repo/Gemfile root" \
                        || bad "5. expected /some/root, got: [$D]"

# ============================================================================
# RSPEC real-runner drives
# ============================================================================
if [ "$HAVE_RSPEC" -ne 1 ]; then
  skip "RSPEC: rspec not usable — SKIPPING the rspec real-runner drives LOUDLY"
else
  RS="$TMPROOT/rspec"; mkdir -p "$RS/spec"
  cat > "$RS/spec/pass_spec.rb" <<'RB'
RSpec.describe("adder") { it("adds") { expect(1 + 1).to eq(2) } }
RB
  cat > "$RS/spec/fail_spec.rb" <<'RB'
RSpec.describe("adder") { it("adds wrong") { expect(1 + 1).to eq(3) } }
RB
  cat > "$RS/spec/ten_spec.rb" <<'RB'
RSpec.describe("ten") { (1..10).each { |i| it("ex #{i}") { expect(i).to eq(i) } } }
RB
  cat > "$RS/spec/empty_spec.rb" <<'RB'
RSpec.describe("nothing") { }
RB
  cat > "$RS/spec/load_spec.rb" <<'RB'
require_relative "../lib/not_yet_created"
RSpec.describe("x") { it("y") { expect(1).to eq(1) } }
RB

  # 6. staged-path isolation: run ONLY pass_spec — siblings (fail/ten) NOT run.
  cmd="$(printf 'spec/pass_spec.rb\n' | REPO_ROOT="$RS" native_scoped_cmd ruby)"
  out="$( cd "$RS" && bash -c "$cmd" 2>&1 )"; rc=$?
  [ "$rc" = 0 ] && ok "6a. scoped rspec pass_spec ⇒ exit 0" \
                || bad "6a. scoped pass_spec should exit 0 (rc=$rc): $out"
  printf '%s' "$out" | grep -q '1 example, 0 failures' \
    && ok "6b. only ONE example ran (siblings not collected)" \
    || bad "6b. expected exactly 1 example, got: $out"

  # 7. a failing scoped spec ⇒ exit 1.
  cmd="$(printf 'spec/fail_spec.rb\n' | REPO_ROOT="$RS" native_scoped_cmd ruby)"
  out="$( cd "$RS" && bash -c "$cmd" 2>&1 )"; rc=$?
  [ "$rc" = 1 ] && ok "7. scoped rspec fail_spec ⇒ exit 1" \
                || bad "7. failing spec should exit 1 (rc=$rc): $out"

  # 8. ZERO-collect traps → proof_zero_collected TRUE (never a pass).
  out="$( cd "$RS" && rspec spec/empty_spec.rb 2>&1 )"
  proof_zero_collected "$out" \
    && ok "8a. no-example spec ('0 examples, 0 failures') ⇒ zero-collected" \
    || bad "8a. no-example spec should read zero-collected: $out"
  out="$( cd "$RS" && rspec spec/empty_only 2>/dev/null; mkdir -p "$RS/empty_only"; rspec "$RS/empty_only" 2>&1 )"
  proof_zero_collected "$out" \
    && ok "8b. empty spec DIR ⇒ zero-collected" \
    || bad "8b. empty dir should read zero-collected: $out"

  # 9. SUBSTRING HAZARD: a healthy 10-example suite is NOT flagged zero.
  out="$( cd "$RS" && rspec spec/ten_spec.rb 2>&1 )"
  proof_zero_collected "$out" \
    && bad "9. 10-example suite ('10 examples') FALSELY flagged zero-collected: $out" \
    || ok "9. 10-example suite is NOT zero-collected (substring hazard guarded)"

  # 10. LOAD-ERROR red: rspec prints '0 examples' + 'No examples found.' on a
  #     LoadError but exits 1 — it must NOT read zero-collected, else a real
  #     greenfield fail-on-parent would be swallowed as inconclusive.
  out="$( cd "$RS" && rspec spec/load_spec.rb 2>&1 )"; rc=$?
  [ "$rc" = 1 ] && ok "10a. LoadError spec ⇒ exit 1 (a real red)" \
                || bad "10a. LoadError spec should exit 1 (rc=$rc)"
  proof_zero_collected "$out" \
    && bad "10b. LoadError red FALSELY flagged zero-collected (greenfield red would be swallowed): $out" \
    || ok "10b. LoadError red is NOT zero-collected (greenfield fail-on-parent survives)"
  printf '%s' "$out" | grep -Eq "$(rg_signature resolution)" \
    && ok "10c. LoadError classifies as a RESOLUTION failure (cannot load such file)" \
    || bad "10c. LoadError should classify as resolution: $out"
fi

# ============================================================================
# MINITEST real-runner drives (system gem — available whenever ruby is)
# ============================================================================
MT="$TMPROOT/minitest"; mkdir -p "$MT/test"
cat > "$MT/test/pass_test.rb" <<'RB'
require "minitest/autorun"
class PassTest < Minitest::Test
  def test_adds; assert_equal 2, 1 + 1; end
end
RB
cat > "$MT/test/fail_test.rb" <<'RB'
require "minitest/autorun"
class FailTest < Minitest::Test
  def test_adds; assert_equal 3, 1 + 1; end
end
RB
cat > "$MT/test/ten_test.rb" <<'RB'
require "minitest/autorun"
class TenTest < Minitest::Test
  (1..10).each { |i| define_method("test_#{i}") { assert_equal i, i } }
end
RB
cat > "$MT/test/empty_test.rb" <<'RB'
require "minitest/autorun"
class EmptyTest < Minitest::Test
end
RB

# 11. staged isolation: run ONLY pass_test — sibling fail_test NOT run.
cmd="$(printf 'test/pass_test.rb\n' | REPO_ROOT="$MT" native_scoped_cmd ruby)"
out="$( cd "$MT" && bash -c "$cmd" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && ok "11a. scoped minitest pass_test ⇒ exit 0" \
             || bad "11a. scoped pass_test should exit 0 (rc=$rc): $out"
printf '%s' "$out" | grep -q '1 runs, 1 assertions, 0 failures' \
  && ok "11b. exactly ONE test ran (sibling not required)" \
  || bad "11b. expected 1 runs, got: $out"

# 12. failing minitest ⇒ exit 1.
cmd="$(printf 'test/fail_test.rb\n' | REPO_ROOT="$MT" native_scoped_cmd ruby)"
out="$( cd "$MT" && bash -c "$cmd" 2>&1 )"; rc=$?
[ "$rc" = 1 ] && ok "12. scoped minitest fail_test ⇒ exit 1" \
             || bad "12. failing minitest should exit 1 (rc=$rc): $out"

# 13. no-method minitest ('0 runs, 0 assertions') ⇒ zero-collected.
out="$( cd "$MT" && ruby -Itest test/empty_test.rb 2>&1 )"
proof_zero_collected "$out" \
  && ok "13. no-method minitest ⇒ zero-collected (never a pass)" \
  || bad "13. no-method minitest should read zero-collected: $out"

# 14. SUBSTRING HAZARD: a healthy 10-run minitest is NOT flagged zero.
out="$( cd "$MT" && ruby -Itest test/ten_test.rb 2>&1 )"
proof_zero_collected "$out" \
  && bad "14. 10-run minitest ('10 runs') FALSELY flagged zero-collected: $out" \
  || ok "14. 10-run minitest is NOT zero-collected (substring hazard guarded)"

echo
printf 'stack-ruby: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
