#!/usr/bin/env bash
#
# S183 — the FOUNDATION oracle and the gate that refuses to file without one.
#
# Two things are under test, and they are deliberately separate:
#
#   1. THE ORACLE'S SECOND AXIS. `lcars_test_readiness` answers "is a test
#      command configured/detectable?" and has always answered `unknown` when
#      the answer is no — REGARDLESS of how much code or how many frameworks
#      the repo holds. That verdict cannot tell a `git init` from an
#      npm-workspaces monorepo with three tested packages, and everything in
#      this round branches on the difference. `LCARS_TESTREADY_FOUNDATION` is
#      the additive second axis: greenfield | untested | unconfigured | ready,
#      decided on POSITIVE EVIDENCE (test files, framework manifests/dev-deps,
#      per-package runners in a workspace), never on the absence of a command.
#
#   2. THE FOUNDATION GATE. `lcars file` REFUSES on greenfield/untested and
#      names Establish Vision — before any worker is hired. `unconfigured` and
#      `ready` are untouched (that is the `lcars update --test-command` case).
#
# ZERO worker spend: every drive runs under the S182 rig's PATH shim with
# COUNTING fake `claude`/`copilot` binaries and its SPEND FUSE armed.
#
# Usage: bash tests/foundation-gate.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
READINESS="$REPO_ROOT/skills/lcars-init/readiness.sh"
GATE="$REPO_ROOT/skills/lcars-init/foundation-gate.sh"
FILE_SH="$REPO_ROOT/skills/lcars-file/file.sh"

# The S182 rig — make_shim / fuse (reused, never rebuilt).
LCARS_SRC="$REPO_ROOT"
# shellcheck source=drives/s182/rig.sh
. "$REPO_ROOT/tests/drives/s182/rig.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
SHIM=""
cleanup() { rm -rf "$TMPROOT"; [ -n "$SHIM" ] && rm -rf "$SHIM"; }
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- the spend fuse, armed before a single drive ---------------------------
CALLS="$TMPROOT/worker-calls.log"; : >"$CALLS"
SHIM="$(make_shim "$CALLS")"
fuse "$SHIM" || { echo "SPEND FUSE TRIPPED — refusing to run"; exit 1; }
spawns() { awk '$1=="SPAWN"' "$CALLS" 2>/dev/null | wc -l | tr -d ' '; }

# --- fixtures: REAL git repos in REAL states -------------------------------
new_repo() { # [name] → path to an initialized-but-empty git repo
  local repo; repo="$(mktemp -d "$TMPROOT/${1:-repo}.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  write_config "$repo" null
  echo "$repo"
}
write_config() { # repo testcmd-jsonvalue
  cat >"$1/.git/lcars/config.json" <<JSON
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "stack": "unknown",
  "testCommand": $2,
  "worktreeSetupCommand": null,
  "created": "2020-01-01T00:00:00Z"
}
JSON
}

verdict() { # repo → the foundation verdict
  ( cd "$1" && bash "$READINESS" --json ) \
    | sed -n 's/.*"foundation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

why() { # repo → the foundationWhy PROSE, unescaped (the board's `found:` chip)
  ( cd "$1" && bash "$READINESS" --json ) \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("foundationWhy") or "")'
}

balanced() { # 0 when the quoting in <string> is evenly paired — i.e. it reads
             # as prose rather than as a command severed mid-quote.
  python3 - "$1" <<'PYBAL'
import sys
s = sys.argv[1]
for c in ('"', "'", "`"):
    if s.count(c) % 2:
        sys.exit(1)
for a, b in (("{", "}"), ("(", ")")):
    if s.count(a) != s.count(b):
        sys.exit(1)
sys.exit(1 if s.rstrip().endswith(("$", "\\")) else 0)
PYBAL
}

write_prd() {
  cat >"$1" <<'EOF'
# Mission: Fix the broken /about route

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router
EOF
}

file_drive() { # repo → RC/OUT from a real `lcars file --prd`, ZERO spend
  local r="$1"
  write_prd "$r/prd-in.md"
  drive "$r" "$SHIM" LCARS_DATE=20260905 LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/nonexistent -- bash "$FILE_SH" --prd "$r/prd-in.md"
}

echo "S183 foundation oracle + gate"
[ -f "$COMMON" ] || { echo "lcars-common.sh not found"; exit 1; }

# ==========================================================================
# 1. THE FOUR REPO STATES → THE FOUR VERDICTS
# ==========================================================================

# --- greenfield: git init and nothing else ---------------------------------
blank="$(new_repo blank)"
check "1a. blank repo → greenfield" "[ \"\$(verdict '$blank')\" = greenfield ]"

# --- greenfield: a README describing an idea, and nothing else -------------
readme="$(new_repo readme)"
printf '# My app\n\nAn idea.\n' >"$readme/README.md"
check "1b. README-only repo → greenfield" "[ \"\$(verdict '$readme')\" = greenfield ]"

# --- untested: real code, no test system -----------------------------------
notests="$(new_repo notests)"
mkdir -p "$notests/src"
cat >"$notests/package.json" <<'JSON'
{ "name": "app", "version": "0.0.0",
  "scripts": { "dev": "vite", "build": "vite build" },
  "dependencies": { "react": "^18.0.0" },
  "devDependencies": { "vite": "^5.0.0" } }
JSON
printf 'export default function App() { return null; }\n' >"$notests/src/App.jsx"
check "1c. code with no test system → untested" "[ \"\$(verdict '$notests')\" = untested ]"

# --- unconfigured: a test system exists, LCARS has no command for it -------
unconf="$(new_repo unconf)"
mkdir -p "$unconf/src"
cat >"$unconf/package.json" <<'JSON'
{ "name": "app", "version": "0.0.0",
  "scripts": { "dev": "vite" },
  "devDependencies": { "vitest": "^1.0.0" } }
JSON
printf 'export default 1;\n' >"$unconf/src/App.js"
printf "import { test } from 'vitest'; test('a', () => {});\n" >"$unconf/src/App.test.js"
check "1d. test system present, no command → unconfigured" \
  "[ \"\$(verdict '$unconf')\" = unconfigured ]"

# --- ready: a configured, resolvable test command --------------------------
ready="$(new_repo ready)"
write_config "$ready" '"true"'
check "1e. configured runner → ready" "[ \"\$(verdict '$ready')\" = ready ]"

# ==========================================================================
# 1f/1g. THE MEASURED LIE: a workspace is NEVER greenfield
# ==========================================================================
mono="$(new_repo mono)"
cat >"$mono/package.json" <<'JSON'
{ "name": "root", "private": true, "workspaces": ["packages/*"] }
JSON
for p in a b c; do
  mkdir -p "$mono/packages/$p/src"
  cat >"$mono/packages/$p/package.json" <<JSON
{ "name": "$p", "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^1.0.0" } }
JSON
  printf "import { test } from 'vitest'; test('x', () => {});\n" \
    >"$mono/packages/$p/src/index.test.js"
done
check "1f. npm-workspaces monorepo with tested packages → NOT greenfield" \
  "[ \"\$(verdict '$mono')\" != greenfield ]"
check "1f. …and NOT untested either" "[ \"\$(verdict '$mono')\" != untested ]"

pnpm="$(new_repo pnpm)"
printf 'packages:\n  - "packages/*"\n' >"$pnpm/pnpm-workspace.yaml"
mkdir -p "$pnpm/packages/one/src"
cat >"$pnpm/packages/one/package.json" <<'JSON'
{ "name": "one", "scripts": { "test": "jest" },
  "devDependencies": { "jest": "^29.0.0" } }
JSON
printf "test('x', () => {});\n" >"$pnpm/packages/one/src/i.test.js"
check "1g. pnpm workspace with NO root manifest → NOT greenfield" \
  "[ \"\$(verdict '$pnpm')\" != greenfield ]"

# ==========================================================================
# 1h–1l. THE ATTACKS
# ==========================================================================

# tests present, runner NOT installed — still a test system, just unconfigured
norunner="$(new_repo norunner)"
mkdir -p "$norunner/src"
cat >"$norunner/package.json" <<'JSON'
{ "name": "app", "scripts": { "start": "node ." } }
JSON
printf 'module.exports = 1;\n' >"$norunner/src/i.js"
printf "describe('a', () => { it('b', () => {}); });\n" >"$norunner/src/i.test.js"
check "1h. test files but no runner installed → unconfigured (never greenfield)" \
  "[ \"\$(verdict '$norunner')\" = unconfigured ]"

# a test/ directory with no framework in it is NOT a test system
emptytest="$(new_repo emptytest)"
mkdir -p "$emptytest/test" "$emptytest/src"
printf 'Notes about testing we have not done.\n' >"$emptytest/test/NOTES.md"
printf 'console.log(1);\n' >"$emptytest/src/i.js"
check "1i. a test/ dir containing no framework → untested" \
  "[ \"\$(verdict '$emptytest')\" = untested ]"

# a workspace where only ONE package is tested still HAS a test system
onepkg="$(new_repo onepkg)"
printf 'packages:\n  - "packages/*"\n' >"$onepkg/pnpm-workspace.yaml"
mkdir -p "$onepkg/packages/one/src" "$onepkg/packages/two/src"
cat >"$onepkg/packages/one/package.json" <<'JSON'
{ "name": "one", "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^1.0.0" } }
JSON
printf "import { test } from 'vitest'; test('x', () => {});\n" \
  >"$onepkg/packages/one/src/i.test.js"
cat >"$onepkg/packages/two/package.json" <<'JSON'
{ "name": "two", "scripts": { "build": "tsc" } }
JSON
printf 'export default 2;\n' >"$onepkg/packages/two/src/i.js"
check "1j. workspace with ONE tested package → unconfigured" \
  "[ \"\$(verdict '$onepkg')\" = unconfigured ]"

# the npm DEFAULT test script is not a test system
npmdefault="$(new_repo npmdefault)"
mkdir -p "$npmdefault/src"
cat >"$npmdefault/package.json" <<'JSON'
{ "name": "app", "version": "1.0.0",
  "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
JSON
printf 'console.log(1);\n' >"$npmdefault/src/i.js"
check "1k. npm default \"no test specified\" script → untested" \
  "[ \"\$(verdict '$npmdefault')\" = untested ]"

# a script literally named test, that tests nothing
faketest="$(new_repo faketest)"
mkdir -p "$faketest/src"
cat >"$faketest/package.json" <<'JSON'
{ "name": "app", "scripts": { "test": "echo all good" } }
JSON
printf 'console.log(1);\n' >"$faketest/src/i.js"
check "1l. a \"test\" script that tests nothing → untested" \
  "[ \"\$(verdict '$faketest')\" = untested ]"

# --- FIX ROUND 3 -----------------------------------------------------------
# F1. `*.t` is PERL's test-file name, and Perl's convention is DIRECTORY-
# scoped: `t/*.t`. The D4 widening added the EXTENSION alone, which is not a
# naming convention at all — `.t` on its own is a template, a Perl script, a
# tuple dump, or, MEASURED here, a `CHANGELOG.t` sitting in the root of an
# otherwise untested JS repo. That one file read as "test files (CHANGELOG.t)"
# → `unconfigured` → the foundation gate OPENED, and LCARS told the captain a
# changelog was this repo's test system.
changelogt="$(new_repo changelogt)"
mkdir -p "$changelogt/src"
printf 'notes about releases\n' >"$changelogt/CHANGELOG.t"
printf 'console.log(1);\n' >"$changelogt/src/i.js"
check "1m. a root-level CHANGELOG.t is NOT a test system" \
  "[ \"\$(verdict '$changelogt')\" = untested ]"
check "1m. …and the gate REFUSES the repo (rc=20)" \
  "( cd '$changelogt' && bash '$GATE' --check >/dev/null 2>&1 ); [ \$? -eq 20 ]"
check "1m. …the evidence phrase never names the changelog" \
  "! why '$changelogt' | grep -q CHANGELOG"

# …while a `.t` file where Perl actually puts one is still evidence. The cure
# must not un-cure D4: `t/add.t` is the whole reason the name is on the list.
perlt="$(new_repo perlt)"
mkdir -p "$perlt/lib" "$perlt/t"
printf 'package M;\nsub add { $_[0] + $_[1] }\n1;\n' >"$perlt/lib/M.pm"
printf 'use Test::More tests => 1;\nis(1+1, 2, "adds");\n' >"$perlt/t/add.t"
check "1m. a Perl t/*.t suite is STILL a test system" \
  "[ \"\$(verdict '$perlt')\" = unconfigured ]"

# F3. `foundationWhy` is CAPTAIN-FACING PROSE — the CLI prints it and the board
# renders it in its `found: …` chip. Rule 2 cut the detected command at exactly
# 60 characters, which lands mid-token on the command LCARS itself seeds and
# leaves the quoting hanging open:
#   this repo already runs `npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"`
longcmd="$(new_repo longcmd)"
mkdir -p "$longcmd/src"
cat >"$longcmd/package.json" <<'JSON'
{ "name": "tested-app", "private": true,
  "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^2.0.0" } }
JSON
printf 'console.log(1);\n' >"$longcmd/src/i.js"
check "1n. a long detected command is still recognised as a test system" \
  "[ \"\$(verdict '$longcmd')\" = unconfigured ]"
check "1n. …and its quoting is left BALANCED (reads as prose)" \
  "balanced \"\$(why '$longcmd')\""
check "1n. …while still naming the runner it found" \
  "why '$longcmd' | grep -q vitest"

# ==========================================================================
# 2. THE GATE — `lcars file` refuses, having hired NOBODY
# ==========================================================================
before="$(spawns)"
file_drive "$blank"
check "2a. greenfield: lcars file REFUSES (non-zero exit)" "[ '$RC' -ne 0 ]"
check "2a. …no mission was written" \
  "[ -z \"\$(ls -A '$blank/.git/lcars/missions' 2>/dev/null)\" ]"
check "2a. …the refusal names Establish Vision" \
  "printf '%s' \"\$OUT\" | grep -qi 'establish vision'"
check "2a. …and says the repo has no test foundation, in plain English" \
  "printf '%s' \"\$OUT\" | grep -qiE 'no (test|way to prove)'"

file_drive "$notests"
check "2b. untested: lcars file REFUSES" "[ '$RC' -ne 0 ]"
check "2b. …the refusal names Establish Vision" \
  "printf '%s' \"\$OUT\" | grep -qi 'establish vision'"
check "2b. …no mission was written" \
  "[ -z \"\$(ls -A '$notests/.git/lcars/missions' 2>/dev/null)\" ]"

check "2c. ZERO workers were hired across every refusal" \
  "[ \"\$(spawns)\" = '$before' ]"

# ==========================================================================
# 3. REGRESSION — unconfigured and ready file exactly as before
# ==========================================================================
file_drive "$unconf"
check "3a. unconfigured: lcars file SUCCEEDS (the --test-command case)" "[ '$RC' -eq 0 ]"
check "3a. …a mission was written" \
  "[ -n \"\$(ls -A '$unconf/.git/lcars/missions' 2>/dev/null)\" ]"

file_drive "$ready"
check "3b. ready: lcars file SUCCEEDS" "[ '$RC' -eq 0 ]"
check "3b. …a mission was written" \
  "[ -n \"\$(ls -A '$ready/.git/lcars/missions' 2>/dev/null)\" ]"

# --park is the same gate (it is the other filing lane)
before2="$(spawns)"
drive "$blank" "$SHIM" LCARS_DATE=20260905 LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/nonexistent -- bash "$FILE_SH" --park "an idea"
check "3c. --park is gated too" "[ '$RC' -ne 0 ]"
check "3c. …still zero hires" "[ \"\$(spawns)\" = '$before2' ]"

drive "$ready" "$SHIM" LCARS_DATE=20260905 LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/nonexistent -- bash "$FILE_SH" --park "an idea"
check "3d. --park on a ready repo is unchanged" "[ '$RC' -eq 0 ]"

# ==========================================================================
# 4. THE SEAM — one named place S184 replaces
# ==========================================================================
check "4a. the gate lives in ONE named seam" "[ -f '$GATE' ]"
check "4a. …whose header tells session 184 it is the replacement point" \
  "grep -qi 'session 184' '$GATE'"
check "4b. the seam answers --json for the daemon" \
  "( cd '$blank' && bash '$GATE' --json ) | grep -q '\"foundation\"'"
check "4b. …and reports allowed=false on a greenfield repo" \
  "( cd '$blank' && bash '$GATE' --json ) | grep -q '\"allowed\"[[:space:]]*:[[:space:]]*false'"
check "4b. …and allowed=true on a ready repo" \
  "( cd '$ready' && bash '$GATE' --json ) | grep -q '\"allowed\"[[:space:]]*:[[:space:]]*true'"

# ==========================================================================
# 5. The readiness LINE contract, where it is still true
# ==========================================================================
check "5a. a genuinely greenfield repo still reads NO TEST SYSTEMS FOUND" \
  "( cd '$blank' && bash '$READINESS' --line ) | grep -q 'NO TEST SYSTEMS FOUND'"
check "5b. the monorepo is NO LONGER told it is a greenfield repo" \
  "! ( cd '$mono' && bash '$READINESS' --line ) | grep -q 'greenfield'"
check "5c. a ready repo is still silent" \
  "[ -z \"\$( cd '$ready' && bash '$READINESS' --line )\" ]"

# FIX ROUND 1 (D3, the CLI half of it). A repo carrying npm's default `test`
# script reads status=missing (detection HAS a candidate) and foundation=untested
# (there is no test system behind it). The line offered that candidate and the
# ⚡ --fix-tests repair — one line above a closing line that says to start with
# Establish Vision, and beside band controls the board has LOCKED. One repo, two
# stories. The line branches on the foundation, like the board now does.
check "5d. the npm-default repo is not offered its placeholder as a candidate" \
  "! ( cd '$npmdefault' && bash '$READINESS' --line ) | grep -q 'detected candidate'"
check "5d. …it is told it has code and no test system" \
  "( cd '$npmdefault' && bash '$READINESS' --line ) | grep -qi 'code'"
check "5e. a repo with a REAL detected candidate still gets the repair voice" \
  "( cd '$unconf' && bash '$READINESS' --line ) | grep -q 'TEST SYSTEMS OFFLINE'"

# ==========================================================================
# 6. FIX ROUND 1 / D1 — `lcars init` must not MANUFACTURE a foundation
# ==========================================================================
# MEASURED (S183b tester): a repo whose only `test` script is npm's default
# `echo "Error: no test specified" && exit 1` was refused BEFORE `lcars init`
# and ALLOWED after it. init seeded `detect_test_cmd`'s candidate into config
# regardless of the evidence, the status axis then read `ready`, and the
# foundation axis followed it — so the attack only ever failed in a repo no
# captain is ever in (init always precedes file).
#
# THE DISTINCTION IS PROVENANCE, NOT AUTHENTICITY. A command the CAPTAIN
# configured (`lcars update --test-command`) is their ruling and stays `ready`;
# a command LCARS auto-seeded from detection must not, by itself, manufacture a
# foundation the evidence denies. There is NO mechanical check here that a
# runner is genuine — that is the shelved trap.
INIT_SH="$REPO_ROOT/skills/lcars-init/init.sh"

raw_repo() { # [name] → a git repo with NO .git/lcars at all (init's own input)
  local repo; repo="$(mktemp -d "$TMPROOT/${1:-raw}.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  echo "$repo"
}
init_drive() { # repo → RC/OUT from a real `lcars init`, ZERO spend
  drive "$1" "$SHIM" LCARS_VERSION_CHECK=0 LCARS_INIT_SKIP_PROBE=1 -- bash "$INIT_SH"
}
cfg_testcmd() { # repo → the persisted testCommand line
  grep '"testCommand"' "$1/.git/lcars/config.json" 2>/dev/null
}

d1a="$(raw_repo d1npm)"
mkdir -p "$d1a/src"
cat >"$d1a/package.json" <<'JSON'
{ "name": "defaulty", "version": "1.0.0",
  "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
JSON
printf 'console.log(1);\n' >"$d1a/src/i.js"
before_d1="$(spawns)"
check "6a. npm-default repo: refused BEFORE init" \
  "( cd '$d1a' && bash '$GATE' --check >/dev/null 2>&1 ); [ \$? -eq 20 ]"
init_drive "$d1a"
check "6a. …lcars init succeeds" "[ '$RC' -eq 0 ]"
check "6a. …and does NOT seed a testCommand it has no evidence for" \
  "cfg_testcmd '$d1a' | grep -q 'null'"
check "6a. …the verdict is STILL untested after init" \
  "[ \"\$(verdict '$d1a')\" = untested ]"
check "6a. …and the gate STILL refuses after init (no flip)" \
  "( cd '$d1a' && bash '$GATE' --check >/dev/null 2>&1 ); [ \$? -eq 20 ]"
file_drive "$d1a"
check "6a. …so filing is refused after init too" "[ '$RC' -ne 0 ]"

# the same flip on a script literally named `test` that tests nothing — the
# probe even PASSES there, which is what made the whole proof gate fake.
d1b="$(raw_repo d1fake)"
mkdir -p "$d1b/src"
cat >"$d1b/package.json" <<'JSON'
{ "name": "app", "scripts": { "test": "echo all good" } }
JSON
printf 'console.log(1);\n' >"$d1b/src/i.js"
init_drive "$d1b"
check "6b. a do-nothing test script is not seeded either" \
  "cfg_testcmd '$d1b' | grep -q 'null'"
check "6b. …verdict STILL untested after init" \
  "[ \"\$(verdict '$d1b')\" = untested ]"
check "6b. …gate STILL refuses after init" \
  "( cd '$d1b' && bash '$GATE' --check >/dev/null 2>&1 ); [ \$? -eq 20 ]"

# REGRESSION: a repo with REAL evidence still gets its detected command seeded,
# exactly as before — the cure must not stop init configuring a real test system.
d1c="$(raw_repo d1real)"
mkdir -p "$d1c/src"
cat >"$d1c/package.json" <<'JSON'
{ "name": "app", "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^1.0.0" } }
JSON
printf "import { test } from 'vitest'; test('x', () => {});\n" >"$d1c/src/i.test.js"
init_drive "$d1c"
check "6c. a repo WITH a test system still gets its command seeded" \
  "cfg_testcmd '$d1c' | grep -qi 'vitest'"

# REGRESSION: the captain's OWN ruling is never second-guessed. `--test-command`
# is provenance the gate honours even on a repo with no other evidence.
d1d="$(raw_repo d1captain)"
mkdir -p "$d1d/src"
cat >"$d1d/package.json" <<'JSON'
{ "name": "app", "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
JSON
printf 'console.log(1);\n' >"$d1d/src/i.js"
init_drive "$d1d"
drive "$d1d" "$SHIM" LCARS_VERSION_CHECK=0 -- bash "$REPO_ROOT/skills/lcars-update/update.sh" --test-command 'true'
check "6d. update --test-command is the captain's ruling → ready" \
  "[ \"\$(verdict '$d1d')\" = ready ]"
check "6d. …and filing is allowed again" \
  "( cd '$d1d' && bash '$GATE' --check >/dev/null 2>&1 )"

check "6e. ZERO workers were hired across the whole D1 section" \
  "[ \"\$(spawns)\" = '$before_d1' ]"

# ==========================================================================
# 7. FIX ROUND 1 / D5 — init must not close by pointing a REFUSED repo at file
# ==========================================================================
init_drive "$blank" >/dev/null 2>&1 || true
init_drive "$d1a"
check "7a. init on a refused repo does NOT end with 'run lcars file'" \
  "! printf '%s' \"\$OUT\" | grep -q 'run .lcars file'"
check "7a. …it points at Establish Vision instead" \
  "printf '%s' \"\$OUT\" | grep -qi 'establish vision'"
init_drive "$d1c"
check "7b. init on a repo WITH a foundation still says run \`lcars file\`" \
  "printf '%s' \"\$OUT\" | grep -q 'lcars file'"

# ==========================================================================
# 8. FIX ROUND 1 / D4 — ecosystems LCARS CLAIMS must not be hard-refused
# ==========================================================================
# `swift test` is in LCARS_TEST_RUNNER_TOKENS and Package.swift in
# LCARS_MANIFEST_FILES, so LCARS claims SwiftPM. A real SwiftPM package with
# Tests/AppTests/AppTests.swift full of XCTAssertEqual read `untested` and was
# REFUSED — told to Establish Vision on a project that already exists. Perl
# (t/*.t + Test::More) failed identically. Refusing a repo that HAS a test
# system is the worse failure (the tie-breaker in the round's own rules).
swiftpkg="$(new_repo swiftpkg)"
mkdir -p "$swiftpkg/Sources/App" "$swiftpkg/Tests/AppTests"
printf '// swift-tools-version:5.9\nimport PackageDescription\n' >"$swiftpkg/Package.swift"
printf 'public func add(_ a: Int, _ b: Int) -> Int { a + b }\n' >"$swiftpkg/Sources/App/App.swift"
cat >"$swiftpkg/Tests/AppTests/AppTests.swift" <<'SWIFT'
import XCTest
@testable import App
final class AppTests: XCTestCase {
  func testAdd() { XCTAssertEqual(add(1, 2), 3) }
}
SWIFT
check "8a. a genuinely tested SwiftPM package → unconfigured, never untested" \
  "[ \"\$(verdict '$swiftpkg')\" = unconfigured ]"
check "8a. …so filing is ALLOWED" \
  "( cd '$swiftpkg' && bash '$GATE' --check >/dev/null 2>&1 )"

perlpkg="$(new_repo perlpkg)"
mkdir -p "$perlpkg/lib" "$perlpkg/t"
printf 'use ExtUtils::MakeMaker;\nWriteMakefile(NAME => "M");\n' >"$perlpkg/Makefile.PL"
printf 'package M;\nsub add { $_[0] + $_[1] }\n1;\n' >"$perlpkg/lib/M.pm"
cat >"$perlpkg/t/add.t" <<'PERL'
use strict;
use Test::More tests => 1;
use M;
is(M::add(1, 2), 3, 'adds');
PERL
check "8b. a Perl distribution with t/*.t → unconfigured, never untested" \
  "[ \"\$(verdict '$perlpkg')\" = unconfigured ]"

# CASE SENSITIVITY, proven WITHOUT relying on the filesystem. The directory scan
# was lowercase-only, so `Tests/` missed entirely on a case-sensitive volume and
# only reached the scan on the tester's Mac because APFS folds case. A repo whose
# ONLY evidence is a CAPITAL `Tests/` directory must both be found AND be named
# by the evidence phrase as `Tests/` — a lowercase phrase here is the filesystem
# answering, not the code.
capdir="$(new_repo capdir)"
mkdir -p "$capdir/Sources/App" "$capdir/Tests"
printf '// swift-tools-version:5.9\n' >"$capdir/Package.swift"
printf 'public let x = 1\n' >"$capdir/Sources/App/App.swift"
cat >"$capdir/Tests/helpers.swift" <<'SWIFT'
import XCTest
func checkIt() { XCTAssertEqual(1, 1) }
SWIFT
check "8c. a CAPITAL Tests/ directory is found" \
  "[ \"\$(verdict '$capdir')\" = unconfigured ]"
check "8c. …and the evidence names the directory that actually exists" \
  "( cd '$capdir' && bash '$READINESS' --json ) | grep -q 'Tests/'"

# REGRESSION on the widened patterns: a `test/` dir of notes is STILL not a
# test system, and a repo with code and nothing else is STILL untested.
check "8d. the widened patterns did not let the notes-only test/ dir through" \
  "[ \"\$(verdict '$emptytest')\" = untested ]"
check "8d. …nor the npm default script" "[ \"\$(verdict '$npmdefault')\" = untested ]"
check "8d. …nor the do-nothing test script" "[ \"\$(verdict '$faketest')\" = untested ]"

# ==========================================================================
# 9. FIX ROUND 1 / D6 + D7 — the refusal reads well, and changes nothing
# ==========================================================================
# D6: the untested refusal stuttered — "This repo has code, but no test system:
# this repo has code and no test system." — because the offer pasted $why after
# a colon that had already said it. This string is also the daemon's 409 body.
refusal="$( cd "$notests" && bash "$GATE" 2>&1 )"
check "9a. the untested refusal does not repeat itself" \
  "! printf '%s' \"\$refusal\" | grep -qi 'no test system: this repo'"
check "9a. …and still says, in one sentence, what it found" \
  "printf '%s' \"\$refusal\" | grep -qi 'code'"
check "9a. …and still names Establish Vision" \
  "printf '%s' \"\$refusal\" | grep -qi 'establish vision'"

# D7: a REFUSED filing must leave the repo untouched — the gate header's own
# promise. file.sh created .git/lcars/missions/ BEFORE the gate ran.
untouched="$(raw_repo untouched)"
mkdir -p "$untouched/src"
printf 'console.log(1);\n' >"$untouched/src/i.js"
mkdir -p "$untouched/.git/lcars"
cat >"$untouched/.git/lcars/config.json" <<'JSON'
{
  "model": "claude-sonnet",
  "testCommand": null
}
JSON
before_d7="$(spawns)"
file_drive "$untouched"
check "9b. a refused filing is refused" "[ '$RC' -ne 0 ]"
check "9b. …and creates NO missions directory in a repo that had none" \
  "[ ! -d '$untouched/.git/lcars/missions' ]"
drive "$untouched" "$SHIM" LCARS_DATE=20260905 LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/nonexistent -- bash "$FILE_SH" --park "an idea"
check "9b. …and --park leaves it untouched too" \
  "[ ! -d '$untouched/.git/lcars/missions' ]"
check "9b. …with zero hires" "[ \"\$(spawns)\" = '$before_d7' ]"

# ==========================================================================
# 10. FIX ROUND 1 / D3 (CLI) — `lcars update --fix-tests` reads the FOUNDATION
# ==========================================================================
# update.sh keyed its greenfield message off ORIG_STATUS = unknown, so a tested
# npm-workspaces monorepo was told it was greenfield and sent to Establish
# Vision — a flow that does not apply to it. S183 made that line WORSE than it
# was, so it is cured here.
UPDATE_SH_T="$REPO_ROOT/skills/lcars-update/update.sh"
drive "$mono" "$SHIM" LCARS_VERSION_CHECK=0 -- bash "$UPDATE_SH_T" --fix-tests </dev/null
check "10a. the tested monorepo is NOT told it is greenfield" \
  "! printf '%s' \"\$OUT\" | grep -qi 'greenfield'"
check "10a. …nor sent to Establish Vision" \
  "! printf '%s' \"\$OUT\" | grep -qi 'establish vision'"
check "10a. …it is told a test system EXISTS and needs a command" \
  "printf '%s' \"\$OUT\" | grep -qi 'test-command\|HAS a test system'"
drive "$blank" "$SHIM" LCARS_VERSION_CHECK=0 -- bash "$UPDATE_SH_T" --fix-tests </dev/null
check "10b. a genuinely greenfield repo still gets the greenfield answer" \
  "printf '%s' \"\$OUT\" | grep -qi 'greenfield'"
drive "$notests" "$SHIM" LCARS_VERSION_CHECK=0 -- bash "$UPDATE_SH_T" --fix-tests </dev/null
check "10c. an UNTESTED repo is told it has code and no test system" \
  "printf '%s' \"\$OUT\" | grep -qi 'code'"
check "10c. …and is NOT called greenfield" \
  "! printf '%s' \"\$OUT\" | grep -qi 'greenfield'"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
