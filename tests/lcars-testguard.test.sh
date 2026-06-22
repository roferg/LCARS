#!/usr/bin/env bash
#
# Tests for BUG-074 — the Test-Writer portable-source guard
# (skill source: skills/lcars-run/run.sh `nonportable_path_in_tests`).
#
# A ticket Test Writer wrote a test that loads game.js via a HARDCODED ABSOLUTE
# build-worktree path (fs.readFileSync('/private/var/worktrees/t-001/game.js')).
# It passes in its build worktree but ENOENTs when the full-suite gate re-runs it
# from a clean checkout elsewhere → spurious regression → futile billed self-heal,
# unfixable (the path lives in the immutable test). The guard rejects such a test
# BEFORE it locks in so the Test Writer retries with a portable walk-up locator.
#
# STANDALONE, STUB-ONLY: extracts the guard function from run.sh and drives it
# against FIXTURE test files on disk — NO model workers, NO gh, NO network, ZERO
# tokens. Safe to run directly. Do NOT route this through tests/run.sh, and NEVER
# run tests/lcars-run.test.sh (it spawns real billable workers).
#
# Usage: bash tests/lcars-testguard.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# --- extract the function under test (mirror lcars-watchdog.test.sh) ----------
GUARD_LIB="$TMPROOT/guard.lib.sh"
sed -n '/^nonportable_path_in_tests() {/,/^}/p' "$RUN_SH" >"$GUARD_LIB"
# shellcheck source=/dev/null
. "$GUARD_LIB"

if ! type nonportable_path_in_tests >/dev/null 2>&1; then
  echo "FATAL: could not extract nonportable_path_in_tests from $RUN_SH" >&2
  exit 1
fi

mkdir_tests() { local d="$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

# === A. REJECT: hardcoded /private/var/worktrees/.../game.js (the BUG-074 path) ==
D="$(mkdir_tests "$TMPROOT/a")"
cat >"$D/t-001.test.js" <<'EOF'
const fs = require('fs');
const assert = require('assert');
const gameSrc = fs.readFileSync('/private/var/worktrees/t-001/game.js', 'utf8');
test('bird falls', () => { assert.ok(gameSrc.includes('gravity')); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '/private/var/worktrees/t-001/game.js'; then
  ok "A. rejects hardcoded /private/var/worktrees/... path (reported: $out)"
else
  bad "A. should reject /private/var/worktrees path (rc=$rc out='$out')"
fi

# === B. ACCEPT: portable findGameJs() walk-up from __dirname ==================
D="$(mkdir_tests "$TMPROOT/b")"
cat >"$D/t-002.test.js" <<'EOF'
const fs = require('fs'), path = require('path');
const assert = require('assert');
function findGameJs() {
  let dir = __dirname;
  for (let i = 0; i < 8; i++) {
    const p = path.join(dir, 'game.js');
    if (fs.existsSync(p)) return p;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  throw new Error('game.js not found');
}
const gameSrc = fs.readFileSync(findGameJs(), 'utf8');
test('bird falls', () => { assert.ok(gameSrc.includes('gravity')); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "B. accepts portable findGameJs() walk-up (no offending path)"
else
  bad "B. should accept portable walk-up (rc=$rc out='$out')"
fi

# === C. ACCEPT: a relative path is not flagged ===============================
D="$(mkdir_tests "$TMPROOT/c")"
cat >"$D/t-003.test.js" <<'EOF'
const fs = require('fs'), path = require('path');
const assert = require('assert');
const gameSrc = fs.readFileSync(path.join(__dirname, '..', 'game.js'), 'utf8');
const cfg = require('./fixtures/config.json');
test('x', () => { assert.ok(gameSrc.length > 0); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "C. relative ../game.js + ./fixtures require not flagged"
else
  bad "C. relative paths false-positived (rc=$rc out='$out')"
fi

# === D. ACCEPT: an absolute path inside a COMMENT does not false-positive =====
D="$(mkdir_tests "$TMPROOT/d")"
cat >"$D/t-004.test.js" <<'EOF'
const fs = require('fs'), path = require('path');
const assert = require('assert');
// historically this read fs.readFileSync('/private/var/worktrees/old/game.js')
// # note: never use /Users/someone/game.js here
const gameSrc = fs.readFileSync(path.join(__dirname, 'game.js'), 'utf8');
test('x', () => { assert.ok(gameSrc); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "D. absolute path inside a comment not flagged"
else
  bad "D. comment-only absolute path false-positived (rc=$rc out='$out')"
fi

# === E. REJECT: absolute /Users/ home path in a readFileSync =================
D="$(mkdir_tests "$TMPROOT/e")"
cat >"$D/t-005.test.js" <<'EOF'
const fs = require('fs');
const assert = require('assert');
const gameSrc = fs.readFileSync('/Users/dev/Projects/app/game.js', 'utf8');
test('x', () => { assert.ok(gameSrc); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '/Users/dev/Projects/app/game.js'; then
  ok "E. rejects absolute /Users/ home path (reported: $out)"
else
  bad "E. should reject /Users/ home path (rc=$rc out='$out')"
fi

# === F. REJECT: require() of an absolute /private/var/folders temp path ======
D="$(mkdir_tests "$TMPROOT/f")"
cat >"$D/t-006.test.js" <<'EOF'
const assert = require('assert');
const game = require('/private/var/folders/ab/cd/T/game.js');
test('x', () => { assert.ok(game); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '/private/var/folders/ab/cd/T/game.js'; then
  ok "F. rejects require() of /private/var/folders temp path (reported: $out)"
else
  bad "F. should reject /private/var/folders require (rc=$rc out='$out')"
fi

# === G. ACCEPT: clean suite with no source loads at all ======================
D="$(mkdir_tests "$TMPROOT/g")"
cat >"$D/t-007.test.js" <<'EOF'
const assert = require('assert');
test('pure logic', () => { assert.strictEqual(1 + 1, 2); });
EOF
out="$(nonportable_path_in_tests "$D")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "G. clean assertion-only suite not flagged"
else
  bad "G. clean suite false-positived (rc=$rc out='$out')"
fi

# --- summary ----------------------------------------------------------------
echo
printf 'testguard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
