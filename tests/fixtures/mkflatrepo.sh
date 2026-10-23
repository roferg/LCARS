#!/usr/bin/env bash
# =============================================================================
# mkflatrepo.sh — the FLAT-TESTS / SLOW-SUITE / MOVING-BASE fixture (S308)
# =============================================================================
# WHAT IT IS FOR. Seven of the findings from the 21–22 Oct 2026 hands-off run
# need the same three conditions, and no other fixture in this repo has them at
# once:
#
#   1. a FLAT `tests/` directory — every test module directly under `tests/`,
#      no `tests/unit/`, no `tests/integration/`. This is the condition that
#      makes the gate's `common_ancestor_dir` degenerate: the deepest shared
#      parent of two flat relpaths is the tests directory itself, i.e. the WHOLE
#      suite, so a "scoped" proof leg silently ran all 1255 tests of the repo it
#      was measured against.
#   2. a suite whose wall-clock is PARAMETERISED BY A `sleep` (--sleep), so
#      "slower than the gate" is produced with a LOW GATE (LCARS_GATE_TIMEOUT=5
#      against a ~10s suite) rather than by shipping a 228-second suite. THE
#      DEFECT IS A RATIO, NOT A DURATION: build a low gate, never a slow suite.
#   3. a LOCAL BARE REMOTE, so `main` can be advanced underneath a mission
#      branch on demand (`--advance-base`) — the condition a self-heal needs
#      (S310) to be shown chasing a regression that does not exist.
#
# It also installs a PATH-shimmed worker so a session that drives this fixture
# spends ZERO model tokens, and so a test can read back how many times a worker
# was invoked and whether any invocation carried `--model`.
#
#   *** FORK-BOMB HAZARD — DO NOT "DELEGATE TO THE REAL ONE". ***
#   On this machine `command -v copilot` resolves to VS Code's own shim, which
#   RE-INVOKES `copilot` BY NAME. A rig wrapper that shadows `copilot` on PATH
#   and then calls "the real one" is an infinite loop at ~5 processes a lap: on
#   2026-09-15 that took the captain's laptop to 5,538 processes and cost ~8
#   hours of an overnight run (see the header of tests/lib/real-worker.sh).
#   The shims below are PURE FAKES. They print scripted output and exit. They
#   never resolve, exec or delegate to any real `claude` / `copilot` binary.
#
# USAGE
#   base="$(bash tests/fixtures/mkflatrepo.sh)"             # defaults
#   base="$(bash tests/fixtures/mkflatrepo.sh --files 8 --sleep 1 --tip flat2)"
#   bash tests/fixtures/mkflatrepo.sh --advance-base "$base"   # move main
#
# It prints ONE line on stdout: the BASE directory. Everything else goes to
# stderr. The base directory holds
#
#   $base/repo/              the work repo (git, flat tests/, .git/lcars state)
#   $base/remote.git/        the local BARE remote ("origin")
#   $base/shim/              PATH shim dir: `claude` + `copilot`, pure fakes
#   $base/worker-calls.log   one TAB-separated line per shim invocation:
#                            <utc>\t<bin>\tmodel=yes|no\t<args>
#
# The repo is a THROWAWAY: it is created under $TMPDIR (or --dir) and the caller
# is responsible for removing it. Nothing here touches any real repo.
#
# TIP MODES (--tip). The parent commit always holds the flat slow suite. The tip
# adds a ticket's work on top and declares it in
# .git/lcars/missions/m-001/tickets/t-001/result.json, so the real gates can be
# driven against it with no worker at all:
#   none    (default) no tip commit — the caller writes its own
#   flat1   ONE new flat test file  + its impl        (today's correct path)
#   flat2   TWO new flat test files + their impls     (the B1-ROOT shape)
#   nested  TWO new test files under tests/a/ and tests/a/b/ (the layout whose
#           common ancestor is REAL and must not regress)
#   spec1   ONE new flat test file named `tests/ticket_up_spec.js` — a name the
#           repo's own testCommand filter (`find … -name "*.test.js"`) CANNOT
#           match. Handing that scope to the command therefore selects NOTHING,
#           the runner receives an EMPTY ARGUMENT LIST, and `node --test` falls
#           back to its OWN discovery and runs the undeclared suite instead.
#           Measured 22 Oct 2026: recorded as a "precise positional filter",
#           verdict `flip-flop FAIL — the tests PASS on the PARENT commit`,
#           while the ticket's own test never ran once.
#   tracked1 ONE new flat test file `tests/ticket_up_spec.js`, for the
#           PARENT-LEG zero-executed shape. Pair it with `--suite spec` and the
#           tracked-files testCommand (see the mode's own comment): the tip runs
#           1 test green, and the parent leg — where the staged copy is
#           UNTRACKED — runs ZERO and still exits 0.
#   spec2red TWO new flat test files, ONE of them the unmatchable
#           `tests/ticket_down_spec.js` AND RED (its assertion fails). The
#           FALSE-PASS shape: driven with a backtick selection, the leg is green
#           overall, the parent is red on the honest sibling, and the gate
#           certified `pass` while a declared test was red and never ran.
#   spec2   TWO new flat test files, ONE of them `tests/ticket_down_spec.js` —
#           the same unmatchable name, alongside a matchable one. The leg is
#           refused, and the artifact must record TWO declared files and a
#           REFUSED scope rather than "one declared test file, run as a precise
#           positional filter" (measured 22 Oct 2026, fix round 2 / LOW 4).
# =============================================================================
set -uo pipefail

FILES=8          # how many modules in the flat slow suite
SLEEP=1          # seconds each flat module sleeps  → suite ≈ FILES*SLEEP
# --suite names the SLOW SUITE's modules. `test` (default) is `slow_NN.test.js`,
# which node:test's OWN discovery finds; `spec` is `slow_NN_spec.js`, which it
# does NOT (node's default patterns are *.test.js / *-test.js / *_test.js /
# test-*.js / test.js / test/**). That difference is the whole point: with a
# `spec`-named suite, a testCommand whose selection comes back EMPTY leaves
# `node --test` with nothing to discover, so it prints `tests 0 / pass 0 /
# fail 0` and EXITS 0 — a GREEN leg carrying no evidence at all, which is the
# shape the parent-leg zero-executed defect (S308 fix round 3) is measured on.
SUITE=test
TIP=none
DIR=""
ADVANCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --files)        FILES="$2"; shift 2 ;;
    --suite)        SUITE="$2"; shift 2 ;;
    --sleep)        SLEEP="$2"; shift 2 ;;
    --tip)          TIP="$2"; shift 2 ;;
    --dir)          DIR="$2"; shift 2 ;;
    --advance-base) ADVANCE="$2"; shift 2 ;;
    -h|--help)      sed -n '1,60p' "$0"; exit 0 ;;
    *) printf 'mkflatrepo: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

git_q() { git -c init.defaultBranch=main "$@"; }

# --------------------------------------------------------------------------
# --advance-base <base>: move `main` on the BARE REMOTE (and fast-forward the
# repo's own `origin/main` ref) WITHOUT touching the work repo's worktree or
# checked-out branch. That is what "the base moved under a mission" means: a
# mission branch cut earlier is now behind origin/main.
# --------------------------------------------------------------------------
if [ -n "$ADVANCE" ]; then
  base="$ADVANCE"
  [ -d "$base/remote.git" ] || { printf 'mkflatrepo: %s is not a mkflatrepo base (no remote.git)\n' "$base" >&2; exit 2; }
  tmpclone="$base/.advance.$$"
  rm -rf "$tmpclone"
  git_q clone -q "$base/remote.git" "$tmpclone" >/dev/null 2>&1 \
    || { printf 'mkflatrepo: could not clone the bare remote\n' >&2; exit 1; }
  (
    cd "$tmpclone" || exit 1
    git config user.email rig@lcars.test
    git config user.name  "LCARS rig"
    n="$(git rev-list --count HEAD)"
    printf 'base advance %s at %s\n' "$n" "$(date -u +%FT%TZ)" >> BASE-MOVES.md
    git add -A
    git commit -qm "base: advance main (#$n) while a mission is in flight"
    git push -q origin main
  ) || { rm -rf "$tmpclone"; printf 'mkflatrepo: advance failed\n' >&2; exit 1; }
  rm -rf "$tmpclone"
  git -C "$base/repo" fetch -q origin 2>/dev/null || :
  printf 'mkflatrepo: main advanced on the bare remote; %s/repo origin/main is now %s\n' \
    "$base" "$(git -C "$base/repo" rev-parse --short origin/main 2>/dev/null)" >&2
  printf '%s\n' "$base"
  exit 0
fi

# --------------------------------------------------------------------------
# Build the base dir
# --------------------------------------------------------------------------
if [ -n "$DIR" ]; then base="$DIR"; mkdir -p "$base"
else base="$(mktemp -d "${TMPDIR:-/tmp}/lcars-flatrepo.XXXXXX")"; fi
repo="$base/repo"
shim="$base/shim"
WLOG="$base/worker-calls.log"
mkdir -p "$repo" "$shim"
: >"$WLOG"

# --- the PURE-FAKE worker shims (claude AND copilot) ----------------------
# BOTH are shimmed, never an env var alone: the engine arrives from three
# places (env, config.workerBin, the host CLI) with a different winner per
# path, so shadowing one name is not enough. Neither shim resolves ANY real
# binary — see the fork-bomb note at the top of this file.
for bin in claude copilot; do
  cat >"$shim/$bin" <<SHIM
#!/usr/bin/env bash
# PURE FAKE worker (mkflatrepo rig). Scripted output only. It NEVER resolves,
# execs or delegates to a real \`claude\` / \`copilot\` — that is a fork bomb.
log="\${LCARS_RIG_WORKER_LOG:-$WLOG}"
mdl=no
for a in "\$@"; do case "\$a" in --model|--model=*) mdl=yes ;; esac; done
printf '%s\t%s\tmodel=%s\t%s\n' "\$(date -u +%FT%TZ)" "$bin" "\$mdl" "\$*" >>"\$log" 2>/dev/null || :
printf '%s\n' "\${LCARS_RIG_WORKER_SAY:-mkflatrepo rig: scripted worker output; no model was called}"
exit "\${LCARS_RIG_WORKER_RC:-0}"
SHIM
  chmod +x "$shim/$bin"
done

# --- the bare remote -------------------------------------------------------
git_q init -q --bare "$base/remote.git"

# --- the work repo ---------------------------------------------------------
( cd "$repo" && git_q init -q -b main \
  && git config user.email rig@lcars.test && git config user.name "LCARS rig" )

printf '{ "name": "flatslow", "private": true }\n' >"$repo/package.json"
mkdir -p "$repo/src" "$repo/tests"
printf 'exports.add = (a, b) => a + b;\n' >"$repo/src/calc.js"

# THE FLAT SLOW SUITE — every module DIRECTLY under tests/. Each one sleeps
# $SLEEP seconds, so the whole suite is ≈ FILES*SLEEP: the ratio the gate
# timeout is set against, never a genuinely slow suite.
case "$SUITE" in
  test) SUITESFX='.test.js' ;;
  spec) SUITESFX='_spec.js' ;;
  *) printf 'mkflatrepo: unknown --suite %s (test|spec)\n' "$SUITE" >&2; exit 2 ;;
esac
i=1
while [ "$i" -le "$FILES" ]; do
  n="$(printf '%02d' "$i")"
  cat >"$repo/tests/slow_$n$SUITESFX" <<JS
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/calc.js');
// Flat module $n of the slow suite. The sleep is the PARAMETER: the suite is
// slow by arithmetic, so "slower than the gate" is set with a LOW gate.
test('slow_$n adds (sleeps ${SLEEP}s)', async () => {
  await new Promise((r) => setTimeout(r, ${SLEEP} * 1000));
  assert.strictEqual(add(2, 2), 4);
});
JS
  i=$((i + 1))
done

# --- the LCARS mission fixture (inside .git/, never the worktree) ----------
MD="$repo/.git/lcars/missions/m-001"
mkdir -p "$MD/tickets/t-001"
cat >"$MD/state.json" <<'JSON'
{ "id": "m-001", "type": "feature", "title": "flat-slow fixture mission",
  "stage": "implement" }
JSON
# testCommand: the find form, so the runner collects everything UNDER the scope
# it is handed, whether that scope is a directory or a single file. (`node --test
# <dir>` does not recurse on every node; the find stands in for a real js
# runner's directory collection, exactly as tests/proof-gates.test.sh does.)
# `--test-concurrency=1` makes the suite's wall-clock the SUM of its sleeps, so
# "10 modules x 1s is slower than a 5s gate" is arithmetic rather than a
# function of how many cores the machine running the test happens to have.
cat >"$repo/.git/lcars/config.json" <<'JSON'
{
  "projectName": "flatslow",
  "model": "claude-sonnet",
  "contextFile": null,
  "stack": "js",
  "testCommand": "node --test --test-concurrency=1 $(find \"$LCARS_TESTS_DIR\" -name \"*.test.js\")",
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "gateTimeout": null,
  "numberOne": {"enabled": false},
  "created": "2026-10-22T00:00:00Z"
}
JSON

( cd "$repo" && git add -A && git commit -qm "parent: flat slow suite ($FILES modules, ${SLEEP}s each)" \
  && git remote add origin "$base/remote.git" && git push -q -u origin main )

# --------------------------------------------------------------------------
# the tip commit — a ticket's work, DECLARED in result.json
# --------------------------------------------------------------------------
write_result() { # newTests-json
  cat >"$MD/tickets/t-001/result.json" <<JSON
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "mkflatrepo rig tip", "newTests": $1, "testEdits": [],
  "flipFlop": "expected" }
JSON
}
new_test_file() { # path requires-rel symbol
  cat >"$1" <<JS
const { test } = require('node:test');
const assert = require('node:assert');
const { $3 } = require('$2');
test('$3 works (sleeps ${SLEEP}s)', async () => {
  await new Promise((r) => setTimeout(r, ${SLEEP} * 1000));
  assert.strictEqual($3('hi'), $3('hi'));
  assert.ok(typeof $3('hi') === 'string');
});
JS
}

case "$TIP" in
  none) : ;;
  flat1)
    printf 'exports.up = (s) => String(s).toUpperCase();\n' >"$repo/src/up.js"
    new_test_file "$repo/tests/ticket_up.test.js" '../src/up.js' up
    write_result '["tests/ticket_up.test.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up (one declared test file)" ) ;;
  flat2)
    printf 'exports.up = (s) => String(s).toUpperCase();\n' >"$repo/src/up.js"
    printf 'exports.down = (s) => String(s).toLowerCase();\n' >"$repo/src/down.js"
    new_test_file "$repo/tests/ticket_up.test.js"   '../src/up.js'   up
    new_test_file "$repo/tests/ticket_down.test.js" '../src/down.js' down
    write_result '["tests/ticket_up.test.js","tests/ticket_down.test.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up + down (two declared test files, FLAT)" ) ;;
  nested)
    mkdir -p "$repo/tests/a/b"
    printf 'exports.up = (s) => String(s).toUpperCase();\n' >"$repo/src/up.js"
    printf 'exports.down = (s) => String(s).toLowerCase();\n' >"$repo/src/down.js"
    new_test_file "$repo/tests/a/ticket_up.test.js"     '../../src/up.js'     up
    new_test_file "$repo/tests/a/b/ticket_down.test.js" '../../../src/down.js' down
    write_result '["tests/a/ticket_up.test.js","tests/a/b/ticket_down.test.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up + down (two declared test files, NESTED)" ) ;;
  spec1)
    # The declared file the runner's own filter cannot match. Everything else is
    # identical to flat1 — ONE declared test file, one impl — so the ONLY
    # difference between a correct leg and a leg that proved nothing is the
    # test file's NAME.
    printf 'exports.up = (s) => String(s).toUpperCase();\n' >"$repo/src/up.js"
    new_test_file "$repo/tests/ticket_up_spec.js" '../src/up.js' up
    write_result '["tests/ticket_up_spec.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up (declared test file the testCommand's filter cannot match)" ) ;;
  spec2)
    # The LOW-4 shape: TWO declared test files, ONE of which the repo's own
    # testCommand filter cannot match. The leg is correctly refused — and the
    # artifact must then record TWO declared files and a REFUSED scope, not
    # "one declared test file, run as a precise positional filter".
    printf 'exports.up = (s) => String(s).toUpperCase();\n'   >"$repo/src/up.js"
    printf 'exports.down = (s) => String(s).toLowerCase();\n' >"$repo/src/down.js"
    new_test_file "$repo/tests/ticket_up.test.js"    '../src/up.js'   up
    new_test_file "$repo/tests/ticket_down_spec.js"  '../src/down.js' down
    write_result '["tests/ticket_up.test.js","tests/ticket_down_spec.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up + down (two declared files, ONE unmatchable)" ) ;;
  tracked1)
    # THE PARENT-LEG ZERO-EXECUTED SHAPE (S308 fix round 3, cure 3), measured by
    # a captain-stand-in tester 22 Oct 2026 as
    #     executed { parent: "0", tip: "1", checked: true }, parent rc 0,
    #     parent tail `tests 0`  →  verdict FAIL, "the ticket's tests PASS on
    #     the PARENT commit"
    # The parent's count was READ and IGNORED: nothing ran there, so "they pass
    # on the parent" describes a run that never happened.
    #
    # Produced with a testCommand that selects only TRACKED test files —
    #     node --test `git ls-files -- "$LCARS_TESTS_DIR"`
    # an ordinary thing for a repo to want, and NOT a synthetic hook. On the TIP
    # the declared file is committed, so it is listed and runs (1 test, green).
    # On the PARENT scratch worktree the gate STAGES the tip's copy in, so the
    # file is present but UNTRACKED — `git ls-files` lists nothing, the runner
    # gets an EMPTY argument list, and with a `spec`-named suite (--suite spec)
    # its own discovery finds nothing either: `tests 0`, exit 0. GREEN on zero.
    # The caller sets that testCommand (cfg_set_testcmd); this mode only builds
    # the tip the shape needs.
    printf 'exports.up = (s) => String(s).toUpperCase();\n' >"$repo/src/up.js"
    new_test_file "$repo/tests/ticket_up_spec.js" '../src/up.js' up
    write_result '["tests/ticket_up_spec.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up (one declared, spec-named, tracked test file)" ) ;;
  spec2red)
    # THE FALSE PASS (S308 fix round 3), the tester's exact shape. Identical to
    # spec2 except that the UNMATCHABLE declared file is RED — its assertion
    # fails. Drive it with the BACKTICK selection the pre-flight is blind to:
    #   node --test --test-concurrency=1 `find "$LCARS_TESTS_DIR" -name "*.test.js"`
    # Invocation 1 (the matchable, honest sibling) runs 1 test green. Invocation
    # 2 is handed the unmatchable file, selects NOTHING, and `node --test` falls
    # back to its own discovery — which cannot see a `_spec.js` name either, so
    # it runs the UNDECLARED suite, green. The leg is GREEN overall and the
    # parent is red on the honest sibling, so the gate certified `pass` with one
    # of the ticket's two declared tests RED ON THE TIP and never executed once.
    printf 'exports.up = (s) => String(s).toUpperCase();\n'   >"$repo/src/up.js"
    printf 'exports.down = (s) => String(s).toLowerCase();\n' >"$repo/src/down.js"
    new_test_file "$repo/tests/ticket_up.test.js"    '../src/up.js'   up
    cat >"$repo/tests/ticket_down_spec.js" <<'JSRED'
const { test } = require('node:test');
const assert = require('node:assert');
const { down } = require('../src/down.js');
// THE TICKET'S REAL TEST, AND IT IS RED. If this file ever executes, the leg
// must go red. The false PASS is that it never executes at all.
test('down works', () => {
  assert.strictEqual(down('HI'), 'DEFINITELY NOT THIS');
});
JSRED
    write_result '["tests/ticket_up.test.js","tests/ticket_down_spec.js"]'
    ( cd "$repo" && git add -A && git commit -qm "t-001: up + down (two declared files; the unmatchable one is RED)" ) ;;
  *) printf 'mkflatrepo: unknown --tip %s\n' "$TIP" >&2; exit 2 ;;
esac

printf 'mkflatrepo: %s\n' "$base" >&2
printf '  repo            %s  (flat tests/: %s modules x %ss ≈ %ss)\n' \
  "$repo" "$FILES" "$SLEEP" "$((FILES * SLEEP))" >&2
printf '  bare remote     %s  (advance main: %s --advance-base %s)\n' \
  "$base/remote.git" "$0" "$base" >&2
printf '  worker shim     %s  (PATH-prepend; pure fake, both claude + copilot)\n' "$shim" >&2
printf '  worker call log %s\n' "$WLOG" >&2
printf '  tip mode        %s  (suite naming: %s)\n' "$TIP" "$SUITE" >&2
printf '%s\n' "$base"
