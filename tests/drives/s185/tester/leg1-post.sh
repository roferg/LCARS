#!/usr/bin/env bash
# S185 TESTER LEG 1b — continue the driven leg-1 repo: the SUITE BY HAND, then
# open-pr → approve → PROMOTION → the unlock, on the REAL verbs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rig.sh"

WORK="$FIX_ROOT/leg1"
REPO="$FIX_ROOT/work/leg1-vitest"
MD="$REPO/.git/lcars/missions/init-001"
SHIM="$WORK/shim"
BR="lcars/init-001"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"
[ -d "$MD" ] || { echo "run vitest-e2e.sh first"; exit 1; }
fuse "$SHIM" || exit 99

jsonget() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }
export LCARS_VERSION_CHECK=0

# Give the fixture a REAL origin (a bare clone) so `open-pr` can push and the
# merge below is a genuine one — nothing about the unlock is faked.
ORIGIN="$WORK/origin.git"
if [ ! -d "$ORIGIN" ]; then
  git init -q --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN" 2>/dev/null || git -C "$REPO" remote set-url origin "$ORIGIN"
  BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" push -q origin "$BASE" "$BR"
fi

echo "############ H. THE SUITE, BY MY OWN HAND ############"
CMD="$(jsonget "$MD/test-command.json" testCommand)"
echo "the command LCARS recorded (verbatim): $CMD"
HW="$WORK/handcheck"; rm -rf "$HW"; git -C "$REPO" worktree prune >/dev/null 2>&1
git -C "$REPO" worktree add -q --detach "$HW" "$BR"
echo "fresh worktree at $BR tip: $(git -C "$HW" rev-parse --short HEAD)"
git -C "$HW" ls-files | sed 's/^/    /'
( cd "$HW" && npm install --no-audit --no-fund ) > "$WORK/hand-install.log" 2>&1
echo "my npm install rc=$?"
( cd "$HW" && eval "$CMD" ) > "$WORK/hand-test.log" 2>&1; HRC=$?
echo "--- MY OWN RUN (rc=$HRC) ---"; cat "$WORK/hand-test.log"
[ "$HRC" -eq 0 ] && ok "H1. the recorded command RUNS AND PASSES by my hand" || bad "H1. FAILED by hand (rc=$HRC)"
grep -qE '[0-9]+ passed' "$WORK/hand-test.log" && ok "H2. …and it COLLECTED real tests" || bad "H2. no test collected"
grep -qE 'Test Files.*2 passed' "$WORK/hand-test.log" && ok "H3. …both tickets' test files ran" || note "H3. (files line: $(grep -m1 'Test Files' "$WORK/hand-test.log" || echo none))"

echo
echo "############ PR + APPROVE ############"
# A gh stub that REALLY MERGES the branch into base, so the repo genuinely gains
# the foundation on its default branch — nothing about the unlock is faked.
GH="$WORK/gh"; cat > "$GH" <<GHS
#!/usr/bin/env bash
echo "gh \$*" >> "$WORK/gh.log"
if [ "\${1:-}" = pr ] && [ "\${2:-}" = create ]; then
  echo "https://github.com/acme/gf/pull/7"; exit 0
fi
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  git -C "$REPO" merge --no-ff -q -m "merge $BR" "$BR" || exit 1
  git -C "$REPO" push -q origin HEAD 2>/dev/null || :
fi
exit 0
GHS
chmod +x "$GH"; : > "$WORK/gh.log"

python3 - "$MD/state.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.setdefault("githubIssue",42); json.dump(d,open(p,"w"),indent=2)
PYX
run_sub "$REPO" "$SHIM" LCARS_GH_BIN="$GH" LCARS_VERSION_CHECK=0 bash "$RUN_SH" open-pr --mission init-001
printf '%s\n' "$OUT"
PRURL="$(jsonget "$MD/state.json" prUrl)"
[ -n "$PRURL" ] && ok "P0. Verify opened a PR ($PRURL)" || bad "P0. no prUrl recorded"

echo "--- repo config BEFORE approve ---"; cat "$REPO/.git/lcars/config.json"
grep -q testCommand "$REPO/.git/lcars/config.json" && bad "P1. testCommand present BEFORE approve" || ok "P1. no testCommand before approve"

# a reconcile stub so approve's self-heal never spawns a worker
cat > "$WORK/recon.sh" <<'R'
#!/usr/bin/env bash
exit 0
R
chmod +x "$WORK/recon.sh"

APOUT="$( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN="$GH" \
   LCARS_GIT_BIN="$(command -v git)" LCARS_RUN_SCRIPT="$WORK/recon.sh" \
   bash "$APPROVE_SH" --mission init-001 2>&1 )"; ARC=$?
echo "--- approve (rc=$ARC) ---"; printf '%s\n' "$APOUT"
[ "$ARC" -eq 0 ] && ok "P2. approve merged and exited 0" || bad "P2. approve rc=$ARC"
echo "--- repo config AFTER approve ---"; cat "$REPO/.git/lcars/config.json"
PROMOTED="$(jsonget "$REPO/.git/lcars/config.json" testCommand)"
[ -n "$PROMOTED" ] && ok "P3. testCommand PROMOTED to repo config" || bad "P3. NOT promoted"
[ "$PROMOTED" = "$CMD" ] && ok "P4. …and it is byte-identical to the established command" \
  || bad "P4. promoted '$PROMOTED' != established '$CMD'"
printf '%s' "$APOUT" | grep -q 'FOUNDATION ESTABLISHED' && ok "P5. approve TELLS the captain" || bad "P5. silent promotion"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$REPO/.git/lcars/config.json" \
  && ok "P6. repo config is still VALID JSON after the promotion" || bad "P6. config.json is now invalid JSON"

echo
echo "############ U. THE UNLOCK, ON THE REAL VERBS ############"
echo "--- foundation gate AFTER ---"; G="$(gate "$REPO")"; printf '%s\n' "$G"
case "$G" in *GATE_RC=0*) ok "U1. the foundation gate now ALLOWS";; *) bad "U1. still refusing: $G";; esac
echo "--- readiness verdict AFTER ---"; verdict "$REPO"

cat > "$WORK/prd.md" <<'PRD'
# Mission: Add a subtract helper
**Type:** feature
**Goal:** Provide a subtract() helper beside add().
**Acceptance Criteria:**
- subtract(4,1) is 3
**Out of Scope:**
- anything else
**Constraints:**
- none
PRD
FOUT="$( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
   LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/nonexistent bash "$FILE_SH" --prd "$WORK/prd.md" 2>&1 )"; FRC=$?
echo "--- lcars file AFTER approve (rc=$FRC) ---"; printf '%s\n' "$FOUT"
[ "$FRC" -eq 0 ] && ok "U2. \`lcars file\` now FILES a normal mission end to end" || bad "U2. lcars file still refuses (rc=$FRC)"
printf '%s' "$FOUT" | grep -q 'NO TEST FOUNDATION' && bad "U3. the refusal text is still printed" || ok "U3. no foundation refusal in the output"
ls "$REPO/.git/lcars/missions" | sed 's/^/    mission: /'

printf '\nLEG 1b: %d ok, %d FAIL   (worker sessions total: %d, billable: %d)\n' \
  "$PASS" "$FAIL" "$(spawns)" "$(billable)"
[ "$FAIL" -eq 0 ]
