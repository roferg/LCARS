#!/usr/bin/env bash
# =============================================================================
# tests/refusal-cure.test.sh — S311: A REFUSAL NAMES THE COMMAND THAT CLEARS IT
# =============================================================================
# Fast, SCOPED, zero-token. Real `skills/lcars-run/run.sh` gates, driven against
# REAL git repos with REAL commits in REAL order, through the existing inert test
# hooks (post-commit-gate-test, full-suite-gate-test, declared-edits-guard-test).
# Every refusal asserted here is TEXT THE GATE ITSELF PRODUCED — captured from
# the gate's own signal file or its own stderr. Nothing in this suite asserts on
# a string a test helper wrote; that is not proof of anything.
#
# WHAT THIS SESSION IS AND IS NOT. The three gates involved — the undeclared-
# drift gate, the declared-edits contract and the post-commit gate — are CORRECT
# and are NOT being weakened. The live run's own write-up called the drift gate
# "the single most valuable gate I hit all night". S311 changes only what they
# SAY and WHICH COMMIT they judge. Section 1 is the REGRESSION LOCK and is
# written first on purpose: a session that makes a refusal friendlier and also
# makes it weaker has failed.
#
# THE DEFECTS (ground truth, measured on a real mission 21-22 Oct 2026):
#   1. THE NAMED CURE HAS NO VERB. The refusal said "Restore the test or re-open
#      the ticket" and there is no `lcars reopen`. An unattended seat could only
#      restore the test (wrong — it reverts a correct adaptation) or stop. One
#      real mission sat BLOCKED for 4h49m on exactly this.
#   2. IT NAMED THE WRONG TICKET. The refusal named the ticket that OWNS the
#      test; the ticket that MADE the edit was a different one, and the
#      declaration belongs in the EDITOR's test-edits.json, not the owner's.
#   3. A DELETION READ AS AN UNDECLARED PRESENT FILE. A worker created a test
#      package, consolidated it into an existing module and DELETED it.
#      Deletions count as edits, so the gate refused while naming paths that no
#      longer exist, worded as though they were present and undeclared. That
#      sent a worker to the wrong file SIX SESSIONS RUNNING.
#   4. THE POST-COMMIT GATE JUDGED A SUPERSEDED COMMIT. A ticket failed at one
#      commit while a later session had already committed a green one for the
#      same ticket. A finished, passing ticket looked permanently broken.
#
# Sections:
#   1. REGRESSION LOCK — a genuine undeclared drift is STILL REFUSED, same
#      severity, at all three drift sites.
#   2. every drift refusal names the sanctioned re-open as a runnable command
#      with the REAL ids filled in.
#   3. `run.sh` with no args / a bad subcommand lists `implement-ticket`.
#   4. ticket B edits ticket A's test -> the refusal names A as OWNER and B
#      (with its commit) as the EDITOR, derived from the RECORD.
#   5. a declared-edits refusal over a DELETED path says it was deleted.
#   6. a post-commit verdict against a SUPERSEDED commit is re-evaluated at the
#      tip; a now-green ticket is NOT failed.
#   7. the refusal prints BOTH the judged commit and the current tip.
#   8. the PRE-MERGE drift site gets the same cures.
#   9. the THIRD drift site (the impl-save-result die) inherits them.
#  11. FIX ROUND 1 — the tip re-check may not MANUFACTURE a pass: the tip's
#      copy of the ticket's recorded tests must be the BYTES THAT WERE PROVED
#      (not merely an edit somebody declared), the green-on-nothing guard
#      applies there too, and a tip that could NOT be re-checked says so
#      instead of claiming it re-ran and found red. A GENUINE supersede still
#      passes, and that control is written first.
#  10. zero model spend, pinned by a PATH shim faking BOTH binaries.
#
# Usage: bash tests/refusal-cure.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { printf 'refusal-cure: node is required\n' >&2; exit 2; }

# TEARDOWN THROUGH A FILE, NOT A VARIABLE: the builders below are called in a
# command substitution, so anything they assign to a shell variable dies with
# that subshell and the throwaway repos leak into $TMPDIR — which is exactly
# what corrupts a later measurement (gate-scope learned this the hard way).
BASEFILE="$(mktemp "${TMPDIR:-/tmp}/lcars-refusalcure-bases.XXXXXX")"
cleanup() {
  local b
  while IFS= read -r b; do [ -n "$b" ] && rm -rf "$b"; done <"$BASEFILE"
  rm -f "$BASEFILE"
}
trap cleanup EXIT

# ZERO MODEL SPEND, PINNED BY A PATH SHIM FAKING BOTH BINARIES -- never an env
# var. The engine arrives from three places (env, config.workerBin, the host
# CLI) with a different winner per path, so shadowing one name is not enough.
#
#   *** FORK-BOMB HAZARD -- THESE SHIMS NEVER DELEGATE. ***
#   On this machine `command -v copilot` resolves to VS Code's own shim, which
#   RE-INVOKES `copilot` BY NAME. A wrapper that shadows `copilot` on PATH and
#   then calls "the real one" is an infinite loop at ~5 processes a lap; on
#   2026-09-15 that took the laptop to 5,538 processes. These are PURE FAKES.
SHIMDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcars-refusalcure-shim.XXXXXX")"
printf '%s\n' "$SHIMDIR" >>"$BASEFILE"
WORKER_LOG="$SHIMDIR/worker-calls.log"; : >"$WORKER_LOG"
for _b in claude copilot; do
  cat >"$SHIMDIR/$_b" <<SHIM
#!/usr/bin/env bash
# PURE FAKE worker (S311 refusal-cure rig). It NEVER resolves, execs or
# delegates to a real \`claude\` / \`copilot\` -- that is a fork bomb.
mdl=no
for a in "\$@"; do case "\$a" in --model|--model=*) mdl=yes ;; esac; done
printf '%s\t%s\tmodel=%s\t%s\n' "\$(date -u +%FT%TZ)" "$_b" "\$mdl" "\$*" >>"$WORKER_LOG" 2>/dev/null || :
printf 'refusal-cure rig: scripted worker output; no model was called\n'
exit 0
SHIM
  chmod +x "$SHIMDIR/$_b"
done
PATH="$SHIMDIR:$PATH"; export PATH

TESTCMD='node --test $(find "$LCARS_TESTS_DIR" -name "*.test.js")'

# --- fixture: a real repo, a real mission branch, real commits in real order --
# t-001 OWNS tests/owner.test.js and has its proof-time hash recorded.
# Returns the base dir on stdout; everything else is quiet.
mk_repo() { # → base
  local b r md
  b="$(mktemp -d "${TMPDIR:-/tmp}/lcars-refusalcure.XXXXXX")"
  printf '%s\n' "$b" >>"$BASEFILE"
  r="$b/repo"; md="$r/.git/lcars/missions/m-001"
  mkdir -p "$r/src" "$r/tests"
  ( cd "$r" && git init -q -b main && git config user.email rig@lcars.test \
      && git config user.name "LCARS rig" )
  printf '{ "name": "refusalcure", "private": true }\n' >"$r/package.json"
  printf 'exports.add = (a, b) => a + b;\n' >"$r/src/calc.js"
  cat >"$r/tests/owner.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/calc.js');
test('add adds', () => { assert.strictEqual(add(2, 2), 4); });
JS
  mkdir -p "$md/tickets/t-001" "$md/tickets/t-002"
  cat >"$r/.git/lcars/config.json" <<JSON
{ "projectName": "refusalcure", "stack": "js",
  "testCommand": "node --test \$(find \\"\$LCARS_TESTS_DIR\\" -name \\"*.test.js\\")",
  "worktreeSetupCommand": null, "gateTimeout": null }
JSON
  ( cd "$r" && git add -A && git commit -qm "parent: the owner test" \
      && git checkout -q -b lcars/m-001 )
  printf '{ "id": "m-001", "type": "feature", "title": "refusal fixture",
  "stage": "implement", "branch": "lcars/m-001" }\n' >"$md/state.json"
  # t-001's proof-time snapshot: the hash of the owner test AS IT WAS, plus the
  # commit it landed in -- the RECORD commit_ticket writes to .commit-sha.
  printf '%s tests/owner.test.js\n' \
    "$(shasum -a 256 "$r/tests/owner.test.js" | awk '{print $1}')" \
    >"$md/tickets/t-001/proof-tests.sha256"
  ( cd "$r" && git rev-parse HEAD ) >"$md/tickets/t-001/.commit-sha"
  printf '%s' "$b"
}

# t-002 EDITS t-001's owner test and commits it, recording its own .commit-sha.
# $2 picks whether the edit is DECLARED by t-002's test-edits.json.
edit_owner_as_t002() { # base [declared]
  local r="$1/repo" md="$1/repo/.git/lcars/missions/m-001"
  printf "\ntest('t-002 adapted this', () => { assert.ok(true); });\n" \
    >>"$r/tests/owner.test.js"
  ( cd "$r" && git add -A && git commit -qm "t-002: adapt the shared helper" )
  ( cd "$r" && git rev-parse HEAD ) >"$md/tickets/t-002/.commit-sha"
  if [ "${2:-}" = declared ]; then
    printf '[{"path":"tests/owner.test.js","reason":"t-002 widened the shared helper"}]\n' \
      >"$md/tickets/t-002/test-edits.json"
  fi
}

gate_pc()   { ( cd "$1/repo" && bash "$RUN_SH" post-commit-gate-test --mission m-001 --ticket "${2:-t-001}" 2>&1 ); }
# WORKTREE MODE is the mode that can go stale, and it is the only one that can.
# With $LCARS_TICKET_WORKTREE set, post_commit_gate judges the commit object
# commit_ticket RECORDED to .commit-sha; with it unset the gate judges the
# branch tip, which is stale by definition never. A fixture that drives the
# unset path cannot exercise a superseded verdict at all -- it passes for want
# of a stale commit rather than because of any re-check.
gate_pc_wt(){ ( cd "$1/repo" && LCARS_TICKET_WORKTREE="$1/repo" bash "$RUN_SH" post-commit-gate-test --mission m-001 --ticket "${2:-t-001}" 2>&1 ); }
pc_signal() { cat "$1/repo/.git/lcars/missions/m-001/pc-test-signal.txt" 2>/dev/null; }

has()  { printf '%s' "$1" | grep -Fq -- "$2"; }
hasnt(){ ! printf '%s' "$1" | grep -Fq -- "$2"; }

printf '\n== 1. REGRESSION LOCK: a genuine undeclared drift is STILL REFUSED ==\n'
# Written FIRST and deliberately. These assertions must hold byte-for-byte in
# spirit before and after S311: same detection, same return code, same
# not-self-healable severity, same named path.
B1="$(mk_repo)"; edit_owner_as_t002 "$B1"
PC1="$(gate_pc "$B1")"
SIG1="$(pc_signal "$B1")"
has "$PC1" 'PCRC=4'                          && ok '1a. undeclared drift STILL returns the distinct drift code (4)' || bad '1a. undeclared drift STILL returns the distinct drift code (4)'
has "$SIG1" 'UNDECLARED TEST DRIFT'          && ok '1b. and it is STILL named UNDECLARED TEST DRIFT'               || bad '1b. and it is STILL named UNDECLARED TEST DRIFT'
has "$SIG1" 'tests/owner.test.js'            && ok '1c. and the drifted path is STILL named'                        || bad '1c. and the drifted path is STILL named'
has "$SIG1" 'NOT self-healable'              && ok '1d. and it is STILL declared NOT self-healable (severity kept)' || bad '1d. and it is STILL declared NOT self-healable (severity kept)'
has "$SIG1" 'refusing'                       && ok '1e. and the gate STILL says it is refusing'                     || bad '1e. and the gate STILL says it is refusing'
# CONTROL: the very same fixture with the edit DECLARED must NOT trip the drift
# gate -- otherwise 1a-1e could be passing for a reason unrelated to drift.
B2="$(mk_repo)"; edit_owner_as_t002 "$B2" declared
PC2="$(gate_pc "$B2")"
hasnt "$PC2" 'PCRC=4'                        && ok '1f. CONTROL: the SAME edit, DECLARED, does not trip the drift gate' || bad '1f. CONTROL: the SAME edit, DECLARED, does not trip the drift gate'
hasnt "$(pc_signal "$B2")" 'UNDECLARED TEST DRIFT' && ok '1g. CONTROL: and no drift refusal is written for it'          || bad '1g. CONTROL: and no drift refusal is written for it'

printf '\n== 2. the refusal names the sanctioned re-open as a RUNNABLE command ==\n'
# The command names the EDITING ticket (section 4 is why), so the id asserted
# here is t-002 -- NOT a placeholder, and not the owner.
has "$SIG1" 'run.sh implement-ticket --mission m-001 --ticket t-002' \
  && ok '2a. the post-commit drift refusal carries a copy-pasteable implement-ticket command with the REAL ids' \
  || bad '2a. the post-commit drift refusal carries a copy-pasteable implement-ticket command with the REAL ids'
hasnt "$SIG1" 'or re-open the ticket.' \
  && ok '2b. and no longer ends on the verbless "re-open the ticket"' \
  || bad '2b. and no longer ends on the verbless "re-open the ticket"'
hasnt "$SIG1" '<mission-id>' && ok '2c. and no placeholder survived into the refusal' || bad '2c. and no placeholder survived into the refusal'
hasnt "$SIG1" '<ticket-id>'  && ok '2d. ... for either id'                            || bad '2d. ... for either id'
# THE NOT-RECORDED FALLBACK. When no ticket's recorded .commit-sha accounts for
# the change, there is no editor to name -- the refusal must still hand over a
# RUNNABLE command (aimed at the owner, the only ticket it can honestly name)
# and must say plainly that the editor is not recorded rather than invent one.
B2B="$(mk_repo)"
R2B="$B2B/repo"
printf "\ntest('somebody changed this', () => { assert.ok(true); });\n" >>"$R2B/tests/owner.test.js"
( cd "$R2B" && git add -A && git commit -qm "a change no ticket recorded" )
PC2B="$(gate_pc "$B2B")"; SIG2B="$(pc_signal "$B2B")"
has "$PC2B" 'PCRC=4' && ok '2e. CONTROL: an unrecorded editor is STILL refused as undeclared drift' || bad '2e. CONTROL: an unrecorded editor is STILL refused as undeclared drift'
has "$SIG2B" 'run.sh implement-ticket --mission m-001 --ticket t-001' \
  && ok '2f. with no recorded editor the refusal still hands over a runnable command (aimed at the owner)' \
  || bad '2f. with no recorded editor the refusal still hands over a runnable command (aimed at the owner)'
printf '%s' "$SIG2B" | grep -Eqi 'NOT RECORDED' \
  && ok '2g. and it SAYS the editing ticket is not recorded rather than inventing one' \
  || bad '2g. and it SAYS the editing ticket is not recorded rather than inventing one'
hasnt "$SIG2B" 't-002' && ok '2h. and it does not misattribute the edit to an unrelated ticket' || bad '2h. and it does not misattribute the edit to an unrelated ticket'

printf '\n== 3. `run.sh` lists implement-ticket as an operator verb ==\n'
# ALREADY TRUE on this tip -- `implement-ticket` is listed under "Drivers:".
# Pinned here as a REGRESSION LOCK so it cannot silently disappear again.
U_NOARG="$( ( cd "$B1/repo" && bash "$RUN_SH" 2>&1 ) || true )"
U_BAD="$(   ( cd "$B1/repo" && bash "$RUN_SH" no-such-subcommand 2>&1 ) || true )"
has "$U_NOARG" 'implement-ticket' && ok '3a. run.sh with NO args lists implement-ticket'      || bad '3a. run.sh with NO args lists implement-ticket'
has "$U_BAD"   'implement-ticket' && ok '3b. run.sh with a BAD subcommand lists it too'       || bad '3b. run.sh with a BAD subcommand lists it too'
has "$U_NOARG" 'research'         && ok '3c. CONTROL: the same output really lists the other Stage verbs' || bad '3c. CONTROL: the same output really lists the other Stage verbs'

printf '\n== 4. the refusal names BOTH tickets: the OWNER and the EDITOR ==\n'
T002SHA="$(git -C "$B1/repo" rev-parse "$(cat "$B1/repo/.git/lcars/missions/m-001/tickets/t-002/.commit-sha")")"
has "$SIG1" "t-001" && ok '4a. the OWNER of the drifted test is still named'  || bad '4a. the OWNER of the drifted test is still named'
has "$SIG1" "t-002" && ok '4b. and the ticket that CHANGED it is named too'   || bad '4b. and the ticket that CHANGED it is named too'
has "$SIG1" "${T002SHA:0:9}" && ok '4c. and the EDITOR is named with its own recorded commit' || bad '4c. and the EDITOR is named with its own recorded commit'
has "$SIG1" 'run.sh implement-ticket --mission m-001 --ticket t-002' \
  && ok '4d. and the re-open command points at the EDITOR -- the declaration belongs in its test-edits.json' \
  || bad '4d. and the re-open command points at the EDITOR -- the declaration belongs in its test-edits.json'

printf '\n== 5. a declared-edits refusal over a DELETED path says it was DELETED ==\n'
# Real repo, real commits: t-001 creates a test package at the tip, declares
# NOTHING, and DELETES one of the files it created. Deletions count as edits, so
# the guard must refuse -- but it must not word an ABSENT path as a present one.
B5="$(mk_repo)"
R5="$B5/repo"; MD5="$R5/.git/lcars/missions/m-001"
mkdir -p "$R5/tests/hub_requests_token"
cat >"$R5/tests/hub_requests_token/probe.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('probe', () => { assert.ok(true); });
JS
cat >"$R5/tests/kept.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('kept', () => { assert.ok(true); });
JS
( cd "$R5" && git add -A && git commit -qm "t-001: create the probe package" )
PARENT5="$(git -C "$R5" rev-parse HEAD)"
# ... then CONSOLIDATE: delete the package it just created, keep the other file.
( cd "$R5" && git rm -q -r tests/hub_requests_token \
    && printf "\ntest('consolidated', () => { assert.ok(true); });\n" >>tests/kept.test.js \
    && git add -A && git commit -qm "t-001: consolidate into the existing module" )
# A result.json that declares NEITHER path -- so both are undeclared edits, and
# one of them is a DELETION.
cat >"$MD5/tickets/t-001/result.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "consolidated", "newTests": [], "testEdits": [],
  "flipFlop": "expected" }
JSON
DE5="$( ( cd "$R5" && bash "$RUN_SH" declared-edits-guard-test \
          --mission m-001 --ticket t-001 --sha "$PARENT5" 2>&1 ) || true )"
has "$DE5" 'DERC=1' && ok '5a. REGRESSION LOCK: an undeclared edit over a deleted path is STILL refused' || bad '5a. REGRESSION LOCK: an undeclared edit over a deleted path is STILL refused'
has "$DE5" 'tests/hub_requests_token/probe.test.js' && ok '5b. and the deleted path is still named' || bad '5b. and the deleted path is still named'
# NOT a bare /delet/ match: the refusal ALREADY ended "Deletions count as
# edits.", so a bare match is green before the fix and proves nothing. The
# deleted path and the word must land in the SAME sentence.
printf '%s' "$DE5" | grep -Ei '[^.]*tests/hub_requests_token/probe\.test\.js[^.]*' \
  | grep -Eqi 'delet' && ok '5c. the refusal says THAT PATH was deleted (same sentence, not a generic aside)' \
                      || bad '5c. the refusal says THAT PATH was deleted (same sentence, not a generic aside)'
printf '%s' "$DE5" | grep -Eqi 'deletion is a declared edit' && ok '5d. and that a deletion is itself a declared edit' || bad '5d. and that a deletion is itself a declared edit'
has "$DE5" 'tests/kept.test.js' && ok '5e. CONTROL: the PRESENT undeclared path is named too' || bad '5e. CONTROL: the PRESENT undeclared path is named too'
# The two classes must be told APART, not lumped into one list: the absent path
# must not appear in the present-path sentence.
PRESENT_LINE="$(printf '%s' "$DE5" | grep -i 'still present\|present on the branch' | head -1 || true)"
if [ -n "$PRESENT_LINE" ]; then
  hasnt "$PRESENT_LINE" 'tests/hub_requests_token/probe.test.js' \
    && ok '5f. and the DELETED path is not listed among the present-and-undeclared ones' \
    || bad '5f. and the DELETED path is not listed among the present-and-undeclared ones'
else
  bad '5f. and the DELETED path is not listed among the present-and-undeclared ones (no present-path sentence found)'
fi

printf '\n== 6. a SUPERSEDED post-commit verdict is re-evaluated at the tip ==\n'
# Real history, real order. t-003 is judged at commit X, where its test is RED
# because the implementation is absent. A LATER session then commits Y on the
# same branch, where the implementation IS present and the suite is GREEN. X is
# an ancestor of Y: Y strictly SUPERSEDES it. The finished, passing ticket must
# not be reported as permanently broken at X.
B6="$(mk_repo)"
R6="$B6/repo"; MD6="$R6/.git/lcars/missions/m-001"
mkdir -p "$MD6/tickets/t-003"
cat >"$R6/tests/feature.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { feature } = require('../src/feature.js');
test('feature works', () => { assert.strictEqual(feature(), 'ok'); });
JS
# commit X: the TEST lands, the IMPLEMENTATION does not -> genuinely RED.
printf 'module.exports = {};\n' >"$R6/src/feature.js"
( cd "$R6" && git add -A && git commit -qm "t-003: the test, without its implementation" )
X6="$(git -C "$R6" rev-parse HEAD)"
printf '%s tests/feature.test.js\n' \
  "$(shasum -a 256 "$R6/tests/feature.test.js" | awk '{print $1}')" \
  >"$MD6/tickets/t-003/proof-tests.sha256"
printf '%s\n' "$X6" >"$MD6/tickets/t-003/.commit-sha"
# CONTROL: judged at X, with X as the tip, the gate must FAIL it -- otherwise
# section 6 would pass for want of a red rather than because of the re-check.
PC6A="$(gate_pc_wt "$B6" t-003)"
has "$PC6A" 'PCRC=1' && ok '6a. CONTROL: at the judged commit, a genuinely absent implementation STILL fails' || bad '6a. CONTROL: at the judged commit, a genuinely absent implementation STILL fails'
# commit Y: a later session lands the implementation. The branch tip supersedes X.
printf "exports.feature = () => 'ok';\n" >"$R6/src/feature.js"
( cd "$R6" && git add -A && git commit -qm "t-003: land the implementation (a later session)" )
Y6="$(git -C "$R6" rev-parse HEAD)"
PC6B="$(gate_pc_wt "$B6" t-003)"
SIG6B="$(pc_signal "$B6")"
has "$PC6B" 'PCRC=0' && ok '6b. judged at a SUPERSEDED commit, the now-green ticket is NOT failed' || bad '6b. judged at a SUPERSEDED commit, the now-green ticket is NOT failed'
# ... and a red that is STILL red at the tip must STILL fail. The re-check adds a
# second chance at the tip; it never grants a pass the tip does not support.
B6C="$(mk_repo)"
R6C="$B6C/repo"; MD6C="$R6C/.git/lcars/missions/m-001"
mkdir -p "$MD6C/tickets/t-003"
cp "$R6/tests/feature.test.js" "$R6C/tests/feature.test.js"
printf 'module.exports = {};\n' >"$R6C/src/feature.js"
( cd "$R6C" && git add -A && git commit -qm "t-003: the test, without its implementation" )
X6C="$(git -C "$R6C" rev-parse HEAD)"
printf '%s tests/feature.test.js\n' \
  "$(shasum -a 256 "$R6C/tests/feature.test.js" | awk '{print $1}')" \
  >"$MD6C/tickets/t-003/proof-tests.sha256"
printf '%s\n' "$X6C" >"$MD6C/tickets/t-003/.commit-sha"
printf 'unrelated\n' >"$R6C/NOTES.md"
( cd "$R6C" && git add -A && git commit -qm "an unrelated later commit" )
PC6C="$(gate_pc_wt "$B6C" t-003)"
has "$PC6C" 'PCRC=1' \
  && ok '6c. REGRESSION LOCK: still red at the tip -> the gate STILL fails the ticket' \
  || bad '6c. REGRESSION LOCK: still red at the tip -> the gate STILL fails the ticket'

printf '\n== 7. the refusal prints BOTH the judged commit and the current tip ==\n'
SIG6C="$(pc_signal "$B6C")"
TIP6C="$(git -C "$R6C" rev-parse HEAD)"
has "$SIG6C" "${X6C:0:9}"  && ok '7a. the JUDGED commit is named in the refusal'        || bad '7a. the JUDGED commit is named in the refusal'
has "$SIG6C" "${TIP6C:0:9}" && ok '7b. and the CURRENT tip is named alongside it'        || bad '7b. and the CURRENT tip is named alongside it'
printf '%s' "$SIG6C" | grep -Eqi 'current (branch )?tip' && ok '7c. and the tip is labelled as the current tip, so staleness is visible' || bad '7c. and the tip is labelled as the current tip, so staleness is visible'
has "$SIG6B" "${X6:0:9}"   && ok '7d. the SUPERSEDED-and-now-green path names the judged commit too' || bad '7d. the SUPERSEDED-and-now-green path names the judged commit too'
has "$SIG6B" "${Y6:0:9}"   && ok '7e. ... and the tip that superseded it'                 || bad '7e. ... and the tip that superseded it'

printf '\n== 8. the PRE-MERGE drift refusal gets the same three cures ==\n'
# The pre-merge site is a `die` inside retest_ticket_suites, reached through the
# REAL full_suite_gate. Driven on the same real history as section 1.
B8="$(mk_repo)"; edit_owner_as_t002 "$B8"
MD8="$B8/repo/.git/lcars/missions/m-001"
cat >"$MD8/waves.json" <<'WJ'
{ "waves": [
  { "wave": 1,
    "tickets": [
      { "id": "t-001", "issue": null }
    ] }
] }
WJ
FS8="$( ( cd "$B8/repo" && bash "$RUN_SH" full-suite-gate-test --mission m-001 2>&1 ) || true )"
has "$FS8" 'PRE-MERGE UNDECLARED TEST DRIFT' && ok '8a. REGRESSION LOCK: the pre-merge drift check STILL blocks' || bad '8a. REGRESSION LOCK: the pre-merge drift check STILL blocks'
has "$FS8" 'cannot merge an undeclared test edit' && ok '8b. and still refuses the merge in the same words'      || bad '8b. and still refuses the merge in the same words'
has "$FS8" 'run.sh implement-ticket --mission m-001 --ticket t-002' && ok '8c. and now names the runnable re-open for the EDITING ticket' || bad '8c. and now names the runnable re-open for the EDITING ticket'
has "$FS8" 't-002' && ok '8d. and names the editor'  || bad '8d. and names the editor'

printf '\n== 9. THE THIRD drift site: the impl-save-result die ==\n'
# There are THREE drift refusal sites, not two. This one is the `die` in
# cmd_impl_save_result, reached by driving the REAL `impl-save-result`
# subcommand -- an actual save of a worker result, not a hook. It appends the
# post-commit gate's signal, so it inherits the cure rather than carrying its
# own copy; this section pins that it really does arrive at the operator.
B10="$(mk_repo)"; edit_owner_as_t002 "$B10"
cat >"$B10/res.json" <<'RJ'
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "did the thing", "newTests": [], "testEdits": [],
  "flipFlop": "expected" }
RJ
SR10="$( ( cd "$B10/repo" && LCARS_GH_BIN=/usr/bin/true bash "$RUN_SH" \
            impl-save-result --mission m-001 --ticket t-001 --result "$B10/res.json" 2>&1 ) || true )"
has "$SR10" 'UNDECLARED TEST DRIFT' && ok '9a. REGRESSION LOCK: impl-save-result STILL refuses an undeclared drift'        || bad '9a. REGRESSION LOCK: impl-save-result STILL refuses an undeclared drift'
has "$SR10" 'Rejected by the cross-boundary drift guardrail' && ok '9b. and still rejects it by the same named guardrail'   || bad '9b. and still rejects it by the same named guardrail'
has "$SR10" 'run.sh implement-ticket --mission m-001 --ticket t-002' && ok '9c. and the cure reaches the operator here too' || bad '9c. and the cure reaches the operator here too'
has "$SR10" 't-002' && ok '9d. naming the EDITING ticket' || bad '9d. naming the EDITING ticket'
# ... and the result must NOT have been recorded as green.
[ ! -f "$B10/repo/.git/lcars/missions/m-001/tickets/t-001/result.json" ] \
  && ok '9e. REGRESSION LOCK: the not-actually-green result was NOT kept' \
  || bad '9e. REGRESSION LOCK: the not-actually-green result was NOT kept'

printf '\n== 11. the TIP re-check may not MANUFACTURE a pass (S311 fix round 1) ==\n'
# Printed BEFORE section 10 on purpose: section 10 counts worker dispatches over
# the whole run, so every gate drive must happen before it.
#
# THE DEFECT (D-A, found by the fresh tester, proven NEW with a control at
# bacae6f). The tip re-check above gated on "did SOMEBODY DECLARE this edit?"
# (proof_drift_declared_ok) instead of "is this still the test that was proved?".
# A sibling ticket declaring an edit to this ticket's test is the ordinary
# owner/editor case this very session is built around -- and the declaration the
# attack needs is EXACTLY what S311's own drift cure tells an operator to create.
# So at a tip where the implementation was STILL ABSENT, a test rewritten to
# assert nothing (or truncated to zero bytes) and declared by a sibling bought
# rc 0 and the announcement "the ticket's own recorded tests are present,
# undrifted and GREEN. A later session landed the work." Nothing had landed.
# The rule is now SNAPSHOT IDENTITY, not a declaration.
#
# THE SECOND DEFECT (D-B). When the recorded test was absent or drifted, the leg
# set rc 1 WITHOUT RUNNING ANYTHING and still said "RE-CHECKED there too, and
# the suite is STILL RED" -- sending an operator hunting a red test that is not
# there, which is the identical wrong-file hunt section 5 just cured.

# t-002 DECLARES an edit to t-004's test -- the forgiveness the attack needs.
declare_feature_edit() { # base
  printf '[{"path":"tests/feature.test.js","reason":"t-002 widened the shared contract"}]\n' \
    >"$1/repo/.git/lcars/missions/m-001/tickets/t-002/test-edits.json"
}
gut_feature_test() { # base   (rewritten to assert NOTHING about the feature)
  cat >"$1/repo/tests/feature.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('feature works', () => { assert.ok(true); });
JS
}

# A ticket judged RED at commit X, with a branch TIP that $1 varies. At X the
# implementation is GENUINELY ABSENT, so the ticket is honestly red there; what
# the tip carries is the whole question. Real repo, real commits, real order.
mk_tip_case() { # mode → base
  local mode="$1" b r md X
  b="$(mk_repo)"
  r="$b/repo"; md="$r/.git/lcars/missions/m-001"
  mkdir -p "$md/tickets/t-004"
  cat >"$r/tests/feature.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { feature } = require('../src/feature.js');
test('feature works', () => { assert.strictEqual(feature(), 'ok'); });
JS
  printf 'module.exports = {};\n' >"$r/src/feature.js"
  if [ "$mode" = zerocollect ]; then
    # THE REPO'S OWN TEST WRAPPER, committed in the repo, with a selection the
    # REPO controls -- the shape every real runner has (vitest's `include`,
    # pytest's `testpaths`, a Makefile target). Its empty-selection sentence is
    # vitest's own wording. The runner here is a STAND-IN; what is under test is
    # what the GATE does with a run that selected nothing, and only the
    # green-on-nothing guard can catch this one -- the test file's BYTES are
    # untouched at the tip, so snapshot identity holds.
    cat >"$r/run-tests.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
scope="${1:-tests}"
here="$(cd "$(dirname "$0")" && pwd)"
list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -f "$here/skip.txt" ] && grep -Fq "$(basename "$f")" "$here/skip.txt"; then continue; fi
  list="${list:+$list }$f"
done <<EOF
$(find "$scope" -name '*.test.js' 2>/dev/null)
EOF
if [ -z "$list" ]; then printf 'No test files found\n'; exit 0; fi
exec node --test $list
SH
    chmod +x "$r/run-tests.sh"
    cat >"$r/.git/lcars/config.json" <<'JSON'
{ "projectName": "refusalcure", "stack": "js",
  "testCommand": "bash ./run-tests.sh \"$LCARS_TESTS_DIR\"",
  "worktreeSetupCommand": null, "gateTimeout": null }
JSON
  fi
  ( cd "$r" && git add -A && git commit -qm "t-004: the test, without its implementation" )
  X="$(git -C "$r" rev-parse HEAD)"
  printf '%s tests/feature.test.js\n' \
    "$(shasum -a 256 "$r/tests/feature.test.js" | awk '{print $1}')" \
    >"$md/tickets/t-004/proof-tests.sha256"
  printf '%s\n' "$X" >"$md/tickets/t-004/.commit-sha"
  case "$mode" in
    supersede)     printf "exports.feature = () => 'ok';\n" >"$r/src/feature.js" ;;
    declaredgut)   declare_feature_edit "$b"; gut_feature_test "$b" ;;
    zerobyte)      declare_feature_edit "$b"; : >"$r/tests/feature.test.js" ;;
    declaredgone)  declare_feature_edit "$b"; rm -f "$r/tests/feature.test.js" ;;
    undeclaredgut) gut_feature_test "$b" ;;
    zerocollect)   printf 'feature.test.js\n' >"$r/skip.txt" ;;
    stillred)      printf '// a later session, still not fixed\n' >>"$r/src/feature.js" ;;
    *) printf 'mk_tip_case: unknown mode %s\n' "$mode" >&2; return 2 ;;
  esac
  ( cd "$r" && git add -A && git commit -qm "the branch tip" )
  printf '%s' "$b"
}

# --- THE CONTROL, WRITTEN FIRST. A genuine supersede must STILL pass ---------
# The implementation really lands at the tip and the recorded test is BYTE-
# IDENTICAL to its proof-time snapshot. This is the case the tip re-check exists
# for, and the case snapshot identity must not cost. (It is also what a genuine
# re-prove produces: a fresh implement-ticket session rewrites
# proof-tests.sha256 from its own tree before it commits, so snapshot and tip
# stay consistent by construction.)
B11A="$(mk_tip_case supersede)"
PC11A="$(gate_pc_wt "$B11A" t-004)"; SIG11A="$(pc_signal "$B11A")"
has "$PC11A" 'PCRC=0' \
  && ok '11a. THE CONTROL: a GENUINE supersede -- work landed, test byte-identical -- still PASSES' \
  || bad '11a. THE CONTROL: a GENUINE supersede -- work landed, test byte-identical -- still PASSES'
has "$SIG11A" 'STALE VERDICT' \
  && ok '11b. and it is still reported as a stale verdict re-checked at the tip' \
  || bad '11b. and it is still reported as a stale verdict re-checked at the tip'

# --- THE ATTACK: a DECLARED edit is not the same test ------------------------
B11C="$(mk_tip_case declaredgut)"
PC11C="$(gate_pc_wt "$B11C" t-004)"; SIG11C="$(pc_signal "$B11C")"
has "$PC11C" 'PCRC=1' \
  && ok '11c. a tip whose recorded test was REWRITTEN to assert nothing (and DECLARED by a sibling) FAILS' \
  || bad '11c. a tip whose recorded test was REWRITTEN to assert nothing (and DECLARED by a sibling) FAILS'
hasnt "$SIG11C" 'A later session landed the work' \
  && ok '11d. and the gate does not assert that a later session landed the work' \
  || bad '11d. and the gate does not assert that a later session landed the work'
hasnt "$SIG11C" 'undrifted' \
  && ok '11e. and it does not call a rewritten test undrifted' \
  || bad '11e. and it does not call a rewritten test undrifted'
printf '%s' "$SIG11C" | grep -Eqi 'could NOT be re-checked|was NOT re-checked' \
  && ok '11f. and it says the tip could not be re-checked rather than inventing a result' \
  || bad '11f. and it says the tip could not be re-checked rather than inventing a result'

B11G="$(mk_tip_case zerobyte)"
PC11G="$(gate_pc_wt "$B11G" t-004)"; SIG11G="$(pc_signal "$B11G")"
has "$PC11G" 'PCRC=1' \
  && ok '11g. a tip whose recorded test was TRUNCATED TO ZERO BYTES (and DECLARED) FAILS' \
  || bad '11g. a tip whose recorded test was TRUNCATED TO ZERO BYTES (and DECLARED) FAILS'
hasnt "$SIG11G" 'A later session landed the work' \
  && ok '11h. and nothing is claimed to have landed' \
  || bad '11h. and nothing is claimed to have landed'

# --- D-B: SAY ONLY WHAT WAS OBSERVED ----------------------------------------
# The WORDING CONTROL first: a tip that really was re-run and really is red must
# still say so -- otherwise 11k/11m below pass for want of the phrase anywhere.
B11I="$(mk_tip_case stillred)"
PC11I="$(gate_pc_wt "$B11I" t-004)"; SIG11I="$(pc_signal "$B11I")"
has "$PC11I" 'PCRC=1' \
  && ok '11i. REGRESSION LOCK: a tip that supersedes X and is STILL RED still fails' \
  || bad '11i. REGRESSION LOCK: a tip that supersedes X and is STILL RED still fails'
has "$SIG11I" 'STILL RED' \
  && ok '11j. WORDING CONTROL: a tip that WAS re-run and is red still says STILL RED' \
  || bad '11j. WORDING CONTROL: a tip that WAS re-run and is red still says STILL RED'

B11K="$(mk_tip_case declaredgone)"
PC11K="$(gate_pc_wt "$B11K" t-004)"; SIG11K="$(pc_signal "$B11K")"
has "$PC11K" 'PCRC=1' \
  && ok '11k. an ABSENT recorded test at the tip still fails the ticket' \
  || bad '11k. an ABSENT recorded test at the tip still fails the ticket'
hasnt "$SIG11K" 'STILL RED' \
  && ok '11l. and it does NOT claim the suite is still red at the tip -- nothing was run there' \
  || bad '11l. and it does NOT claim the suite is still red at the tip -- nothing was run there'
printf '%s' "$SIG11K" | grep -Eqi 'could NOT be re-checked|was NOT re-checked' \
  && ok '11m. it says the tip could not be re-checked instead' \
  || bad '11m. it says the tip could not be re-checked instead'

B11N="$(mk_tip_case undeclaredgut)"
PC11N="$(gate_pc_wt "$B11N" t-004)"; SIG11N="$(pc_signal "$B11N")"
has "$PC11N" 'PCRC=1' \
  && ok '11n. a tip whose recorded test drifted UNDECLARED still fails the ticket' \
  || bad '11n. a tip whose recorded test drifted UNDECLARED still fails the ticket'
hasnt "$SIG11N" 'STILL RED' \
  && ok '11o. and it does NOT claim the suite is still red at the tip -- nothing was run there' \
  || bad '11o. and it does NOT claim the suite is still red at the tip -- nothing was run there'
printf '%s' "$SIG11N" | grep -Eqi 'could NOT be re-checked|was NOT re-checked' \
  && ok '11p. it says the tip could not be re-checked instead' \
  || bad '11p. it says the tip could not be re-checked instead'

# --- THE GREEN-ON-NOTHING GUARD AT THE TIP ----------------------------------
# Byte-identical test, implementation still absent, and the repo's own runner
# selects NOTHING at the tip. Snapshot identity cannot see this one; only the
# zero-collected guard the other proof legs already apply can.
B11Q="$(mk_tip_case zerocollect)"
PC11Q="$(gate_pc_wt "$B11Q" t-004)"; SIG11Q="$(pc_signal "$B11Q")"
has "$PC11Q" 'PCRC=1' \
  && ok '11q. a tip run that collected ZERO tests does not buy a pass (green-on-nothing)' \
  || bad '11q. a tip run that collected ZERO tests does not buy a pass (green-on-nothing)'
printf '%s' "$SIG11Q" | grep -Eqi 'ZERO tests' \
  && ok '11r. and the refusal says the tip run collected zero tests' \
  || bad '11r. and the refusal says the tip run collected zero tests'

printf '\n== 10. ZERO MODEL SPEND ==\n'
# `grep -c` EXITS 1 on an empty file while still printing 0, so `cmd || printf 0`
# emits "0\n0" and every numeric comparison below breaks. Count with wc.
DISPATCH="$(  { grep -c .          "$WORKER_LOG" 2>/dev/null || true; } | head -1 )"
WITHMODEL="$( { grep -c 'model=yes' "$WORKER_LOG" 2>/dev/null || true; } | head -1 )"
DISPATCH="${DISPATCH:-0}"; WITHMODEL="${WITHMODEL:-0}"
[ "$DISPATCH" = 0 ] && ok "10a. no worker was dispatched at all (dispatches=$DISPATCH, with --model=$WITHMODEL)" \
                    || bad "10a. a worker WAS dispatched (dispatches=$DISPATCH, with --model=$WITHMODEL)"
[ -x "$SHIMDIR/claude" ] && [ -x "$SHIMDIR/copilot" ] && ok '10b. CONTROL: both shims were installed and executable on PATH' || bad '10b. CONTROL: both shims were installed and executable on PATH'

printf '\nrefusal-cure: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
