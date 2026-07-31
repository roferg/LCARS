#!/usr/bin/env bash
#
# Tests for the base-freshness guard (S158).
#
# Skill source:
#   skills/lcars-init/lcars-common.sh   ensure_base_current / lcars_base_report /
#                                       lcars_base_state_line
#   skills/lcars-file/file.sh           both filing lanes call it BEFORE the
#                                       mission branch is cut
#
# The verdict vocabulary is FOUR words — `current`, `updated`, `stale`, `unknown`
# — plus a carried `loud` flag and one honest `reason` sentence. It was fifteen
# bespoke names with bespoke prose each; the situations they distinguished are all
# still here, pinned by their reason strings rather than by a name (see behaviour
# 32, which holds the source to the declaration).
#
# The failure this closes: a Mission filed off a local `main` that is N commits
# behind origin makes every downstream Stage reason about a tree that no longer
# exists (DX-Scorecard lcars-20260730-001 — 19 commits behind; Research
# truthfully reported a file "does not exist" and the mission shipped into a
# decoy). The guard fast-forwards the base BEFORE `lcars/<id>` is cut, records an
# honest verdict on the mission, and NEVER blocks filing or touches a dirty tree.
#
# EVERYTHING here is real git against LOCAL BARE remotes (`git init --bare`), so
# fetch/pull are genuine operations with no network and no forge. gh and the
# estimator are stubbed; NO worker is ever spawned — zero tokens.
#
# Usage: bash tests/base-freshness.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
VERSION_STAMP="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"

# The interactive version check is irrelevant here (and would fetch the LCARS
# repo's own origin). Kill it for the whole suite — zero output, zero git calls.
export LCARS_VERSION_CHECK=0

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# qgrep: drain stdin FULLY before grepping (a piped `grep -q` short-circuits and
# SIGPIPEs the producer, which fails the pipeline under `set -o pipefail`).
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

# --- stubs ----------------------------------------------------------------
GH_STUB="$TMPROOT/gh"
cat >"$GH_STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"; exit 0
fi
exit 0
EOF
chmod +x "$GH_STUB"

ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"
cat >"$ESTIMATOR_STUB" <<'EOF'
#!/usr/bin/env bash
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="${2:-}"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
mdir="$gitdir/lcars/missions/$mid"
[ -d "$mdir" ] || exit 1
cat >"$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "low",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
chmod +x "$ESTIMATOR_STUB"
export LCARS_RUN_BIN="$ESTIMATOR_STUB"

# --- fixtures -------------------------------------------------------------
# scaffold_lcars <repo> — .git/lcars with a STAMPED config, so file.sh's version
# check has nothing to prompt about (the known "RUN lcars update? [y/N]" trap).
scaffold_lcars() {
  local repo="$1"
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<EOF
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null,
  "lcarsVersion": "$VERSION_STAMP", "created": "2026-05-30T00:00:00Z" }
EOF
}

# make_fixture <name> — a local BARE origin + a seed clone that pushed the first
# commit + the working clone under test. Echoes the working clone's path.
make_fixture() {
  local name="$1"
  local bare="$TMPROOT/$name.git" seed="$TMPROOT/$name.seed" repo="$TMPROOT/$name"
  git init -q --bare "$bare" 2>/dev/null
  git init -q "$seed" 2>/dev/null
  (
    cd "$seed"
    git config user.email t@t; git config user.name t
    git checkout -q -b main 2>/dev/null
    echo "base" >README.md
    git add -A && git commit -q -m init
    git remote add origin "$bare" && git push -q -u origin main
  ) >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$repo" 2>/dev/null
  ( cd "$repo" && git config user.email t@t && git config user.name t )
  scaffold_lcars "$repo"
  printf '%s' "$repo"
}

# advance_origin <name> <n> — push n new commits to the bare origin from the seed
# clone, so the working clone is genuinely n commits behind. The FIRST of those
# commits adds src/real-view.txt — the "file only origin has" a stale worker
# would swear does not exist.
advance_origin() {
  local name="$1" n="$2" i
  (
    cd "$TMPROOT/$name.seed"
    git pull -q --ff-only origin main
    for i in $(seq 1 "$n"); do
      mkdir -p src
      printf 'origin line %s\n' "$i" >>src/real-view.txt
      git add -A && git commit -q -m "origin commit $i"
    done
    git push -q origin main
  ) >/dev/null 2>&1
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
- Existing router; no new dependencies
EOF
}

# file_mission <repo> [args…] — grill-first filing with pinned date/now. Echoes
# nothing; stdout+stderr land in <repo>.out, the exit code in <repo>.rc.
file_mission() {
  local repo="$1"; shift
  local rc=0
  # Outputs land OUTSIDE the repo so a filing never dirties the working tree the
  # guard is supposed to be judging (that is the whole point of behaviour 2).
  (
    cd "$repo"
    LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
      GH_LOG="$repo.ghlog" bash "$FILE_SCRIPT" "$@" >"$repo.out" 2>&1
  ) || rc=$?
  printf '%s' "$rc" >"$repo.rc"
}

# reason_has <state.json> <substring> — the verdict vocabulary is four words, so
# the SITUATION lives in baseFreshness.reason. Every place a test used to pin a
# scenario by its bespoke verdict name now pins it by the sentence instead, so
# nothing that the 15 names distinguished is silently lost.
reason_has() { case "$(sf "$1" baseFreshness.reason)" in *"$2"*) return 0 ;; esac; return 1; }
# loud_is <state.json> True|False — loudness is CARRIED, never derived from the
# verdict (`unknown` covers both the silent no-remote case and the loud
# unreachable one), so it is asserted independently everywhere.
loud_is() { [ "$(sf "$1" baseFreshness.loud)" = "$2" ]; }

MID="lcars-20260530-001"
mdir() { printf '%s/.git/lcars/missions/%s' "$1" "$MID"; }

# sf <state.json> <dotted.key> — read a (possibly nested) field. Empty on miss.
sf() {
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'): d=d[k]
    print(d)
except Exception:
    pass
" "$1" "$2" 2>/dev/null
}

# ==========================================================================
echo "base freshness (S158)"
[ -f "$FILE_SCRIPT" ] || { echo "script under test not found at $FILE_SCRIPT"; exit 1; }
[ -f "$COMMON" ]      || { echo "shared lib not found at $COMMON"; exit 1; }

# --- Behaviour 0: the helper exists and is sourceable ----------------------
check "0. lcars-common.sh defines ensure_base_current" \
  "bash -c '. \"$COMMON\"; type ensure_base_current' >/dev/null 2>&1"
check "0. lcars-common.sh defines lcars_base_state_line" \
  "bash -c '. \"$COMMON\"; type lcars_base_state_line' >/dev/null 2>&1"

# --- Behaviour 1: 19 commits behind a clean, ff-able origin ----------------
# The headline case. The base must be PULLED, the mission branch cut from the NEW
# tip, and behindBy recorded as 19 (measured PRE-pull).
r1="$(make_fixture b1)"
advance_origin b1 19
ORIGIN_TIP="$(git -C "$TMPROOT/b1.git" rev-parse refs/heads/main)"
STALE_TIP="$(git -C "$r1" rev-parse HEAD)"
check "1. fixture really is 19 behind (stale tip != origin tip)" \
  "[ '$STALE_TIP' != '$ORIGIN_TIP' ]"
check "1. the origin-only file is genuinely absent before filing" \
  "[ ! -f '$r1/src/real-view.txt' ]"
prd1="$TMPROOT/prd1.md"; write_prd "$prd1"
file_mission "$r1" --prd "$prd1"
M1="$(mdir "$r1")"
check "1. filing succeeded (exit 0)"            "[ \"\$(cat '$r1.rc')\" = '0' ]"
check "1. mission dir exists"                   "[ -d '$M1' ]"
check "1. local main was fast-forwarded to the origin tip" \
  "[ \"\$(git -C '$r1' rev-parse refs/heads/main)\" = '$ORIGIN_TIP' ]"
check "1. lcars/<id> is cut from the NEW tip, not the stale one" \
  "[ \"\$(git -C '$r1' rev-parse refs/heads/lcars/$MID)\" = '$ORIGIN_TIP' ]"
check "1. the origin-only file is now in the tree a worker would read" \
  "[ -f '$r1/src/real-view.txt' ]"
check "1. verdict is 'updated'"                 "[ \"\$(sf '$M1/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "1. behindBy records the PRE-pull distance (19)" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.behindBy)\" = '19' ]"
check "1. baseSha is the post-pull base sha"    "[ \"\$(sf '$M1/state.json' baseFreshness.baseSha)\" = '$ORIGIN_TIP' ]"
check "1. checkedAt is recorded"                "[ -n \"\$(sf '$M1/state.json' baseFreshness.checkedAt)\" ]"
check "1. readout names the fast-forward"       "grep -qi 'fast-forward' '$r1.out'"
check "1. state.json is valid JSON"             "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M1/state.json'"
# D6 — the "filed against the CURRENT tree" claim is about the MISSION, so it is
# made only when the mission's own branch really was cut from the fresh base.
check "1. the mission-branch claim is made (branch really was cut fresh)" \
  "grep -q 'lcars/$MID is cut from the CURRENT tree' '$r1.out'"
check "1. missionBranchAtBase is true" \
  "[ \"\$(sf '$M1/state.json' baseFreshness.missionBranchAtBase)\" = 'True' ]"
# D2 — a fetch is a network call; it announces itself BEFORE it runs so a slow
# remote reads as a slow remote, not as a hang.
check "1. the fetch announces itself before it runs" \
  "grep -q 'base freshness — fetching origin' '$r1.out'"

# --- Behaviour 2: a DIRTY working tree is never WRITTEN to — but it IS measured
# The tree is untouchable; the NUMBER is not. A read-only fetch writes only into
# refs/remotes/, so the captain gets "you are 3 behind" (which they can act on)
# instead of "you might be behind" (which they dismiss). No pull, no local ref
# moved, not one byte of the tree changed.
r2="$(make_fixture b2)"
advance_origin b2 3
printf 'captain work in progress\n' >>"$r2/README.md"
printf 'untracked scratch\n' >"$r2/scratch.txt"
BEFORE_STATUS="$(git -C "$r2" status --porcelain)"
BEFORE_README="$(cksum <"$r2/README.md")"
BEFORE_MAIN="$(git -C "$r2" rev-parse refs/heads/main)"
BEFORE_ORIGIN_REF="$(git -C "$r2" rev-parse refs/remotes/origin/main)"
prd2="$TMPROOT/prd2.md"; write_prd "$prd2"
file_mission "$r2" --prd "$prd2"
M2="$(mdir "$r2")"
check "2. filing STILL succeeds on a dirty tree" "[ \"\$(cat '$r2.rc')\" = '0' ]"
check "2. mission was filed"                     "[ -d '$M2' ]"
check "2. verdict is 'stale' (behind, and LCARS could not fix it)" \
  "[ \"\$(sf '$M2/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "2. …and the reason names the DIRTY TREE as the blocker" \
  "reason_has '$M2/state.json' 'never writes into a dirty tree'"
check "2. …and it is flagged LOUD"                "loud_is '$M2/state.json' True"
check "2. …with the stash command recorded in fix" \
  "case \"\$(sf '$M2/state.json' baseFreshness.fix)\" in *'git stash'*) true ;; *) false ;; esac"
check "2. local main was NOT moved"              "[ \"\$(git -C '$r2' rev-parse refs/heads/main)\" = '$BEFORE_MAIN' ]"
check "2. the staleness was MEASURED anyway (behindBy 3)" \
  "[ \"\$(sf '$M2/state.json' baseFreshness.behindBy)\" = '3' ]"
check "2. the warning names the real number, not a vague 'might be behind'" \
  "grep -q '3 commit(s) behind origin' '$r2.out'"
check "2. the measurement was a read-only fetch (remote-tracking ref moved)" \
  "[ \"\$(git -C '$r2' rev-parse refs/remotes/origin/main)\" != '$BEFORE_ORIGIN_REF' ]"
check "2. the dirty file is byte-identical afterwards" \
  "[ \"\$(cksum <'$r2/README.md')\" = '$BEFORE_README' ]"
check "2. the working tree status is byte-identical afterwards" \
  "[ \"\$(git -C '$r2' status --porcelain)\" = \"\$BEFORE_STATUS\" ]"
check "2. the untracked scratch file survives"   "[ -f '$r2/scratch.txt' ]"
check "2. a loud BASE FRESHNESS block is printed" "grep -q 'BASE FRESHNESS' '$r2.out'"
check "2. the warning names the dirt"            "grep -qi 'uncommitted' '$r2.out'"
check "2. the warning names a fix command"       "grep -q 'git stash' '$r2.out'"

# --- Behaviour 3: a DIVERGED base refuses, legibly -------------------------
r3="$(make_fixture b3)"
advance_origin b3 4
( cd "$r3" && printf 'local only\n' >local.txt && git add -A && git commit -q -m "local divergent commit" ) >/dev/null 2>&1
BEFORE_MAIN3="$(git -C "$r3" rev-parse refs/heads/main)"
prd3="$TMPROOT/prd3.md"; write_prd "$prd3"
file_mission "$r3" --prd "$prd3"
M3="$(mdir "$r3")"
check "3. filing STILL succeeds on a diverged base" "[ \"\$(cat '$r3.rc')\" = '0' ]"
check "3. verdict is 'stale'"                       "[ \"\$(sf '$M3/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "3. …and the reason names the DIVERGENCE, not just 'behind'" \
  "reason_has '$M3/state.json' 'a fast-forward is impossible'"
check "3. …and it is flagged LOUD"                  "loud_is '$M3/state.json' True"
check "3. local main was NOT moved"                 "[ \"\$(git -C '$r3' rev-parse refs/heads/main)\" = '$BEFORE_MAIN3' ]"
check "3. behindBy still counts what origin has (4)" \
  "[ \"\$(sf '$M3/state.json' baseFreshness.behindBy)\" = '4' ]"
check "3. a loud BASE FRESHNESS block is printed"   "grep -q 'BASE FRESHNESS' '$r3.out'"
check "3. the refusal names the divergence"         "grep -qi 'fast-forward is impossible' '$r3.out'"
check "3. the refusal names a fix command"          "grep -q 'git pull' '$r3.out'"

# --- Behaviour 4: NO origin remote — the normal local-only case, QUIET -----
r4="$TMPROOT/b4"
mkdir -p "$r4"
( cd "$r4" && git init -q && git config user.email t@t && git config user.name t \
    && git checkout -q -b main && git commit -q --allow-empty -m init ) >/dev/null 2>&1
scaffold_lcars "$r4"
prd4="$TMPROOT/prd4.md"; write_prd "$prd4"
file_mission "$r4" --prd "$prd4"
M4="$(mdir "$r4")"
check "4. filing succeeds with no remote"        "[ \"\$(cat '$r4.rc')\" = '0' ]"
check "4. verdict is 'unknown' (nothing to measure against)" \
  "[ \"\$(sf '$M4/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "4. …and the reason names the missing remote" \
  "reason_has '$M4/state.json' \"no 'origin' remote\""
check "4. …and it is NOT loud (this is the everyday local-only repo)" \
  "loud_is '$M4/state.json' False"
check "4. …and there is no fix to offer"        "[ -z \"\$(sf '$M4/state.json' baseFreshness.fix)\" ]"
check "4. NO warning block is printed (quiet)"   "! grep -q 'BASE FRESHNESS' '$r4.out'"
check "4. no stray freshness chatter at all"     "! grep -qi 'fast-forward' '$r4.out'"
check "4. the readout is the normal filing readout" "grep -q 'Mission filed: $MID' '$r4.out'"

# --- Behaviour 5: an UNREACHABLE origin degrades, filing succeeds ----------
r5="$(make_fixture b5)"
( cd "$r5" && git remote set-url origin "$TMPROOT/definitely-not-here.git" )
prd5="$TMPROOT/prd5.md"; write_prd "$prd5"
file_mission "$r5" --prd "$prd5"
M5="$(mdir "$r5")"
check "5. filing succeeds against an unreachable origin" "[ \"\$(cat '$r5.rc')\" = '0' ]"
check "5. verdict is 'unknown' (freshness could not be determined)" \
  "[ \"\$(sf '$M5/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "5. …and the reason names the failed fetch" \
  "reason_has '$M5/state.json' 'could not fetch from origin'"
check "5. …and THIS unknown is loud, unlike the no-remote one" \
  "loud_is '$M5/state.json' True"
check "5. a loud BASE FRESHNESS block is printed"        "grep -q 'BASE FRESHNESS' '$r5.out'"
check "5. the reason names the unreachable origin"       "grep -qi 'could not fetch' '$r5.out'"
check "5. the mission branch was still cut"              "git -C '$r5' show-ref --verify --quiet refs/heads/lcars/$MID"

# --- Behaviour 6: ALREADY CURRENT — no pull, no noise ---------------------
r6="$(make_fixture b6)"
BEFORE_MAIN6="$(git -C "$r6" rev-parse refs/heads/main)"
prd6="$TMPROOT/prd6.md"; write_prd "$prd6"
file_mission "$r6" --prd "$prd6"
M6="$(mdir "$r6")"
check "6. filing succeeds"                        "[ \"\$(cat '$r6.rc')\" = '0' ]"
check "6. verdict is 'current'"                    "[ \"\$(sf '$M6/state.json' baseFreshness.verdict)\" = 'current' ]"
check "6. …and the reason says it matches origin exactly" \
  "reason_has '$M6/state.json' \"is exactly origin's\""
check "6. …and it is not loud"                    "loud_is '$M6/state.json' False"
check "6. behindBy is 0"                          "[ \"\$(sf '$M6/state.json' baseFreshness.behindBy)\" = '0' ]"
check "6. main is unmoved"                        "[ \"\$(git -C '$r6' rev-parse refs/heads/main)\" = '$BEFORE_MAIN6' ]"
check "6. NO warning block (no noise)"            "! grep -q 'BASE FRESHNESS' '$r6.out'"
check "6. NO fast-forward chatter"                "! grep -qi 'fast-forwarded' '$r6.out'"

# --- Behaviour 7: the --park lane gets the IDENTICAL treatment -------------
r7="$(make_fixture b7)"
advance_origin b7 6
ORIGIN_TIP7="$(git -C "$TMPROOT/b7.git" rev-parse refs/heads/main)"
file_mission "$r7" --park "make the leaderboard sortable"
M7="$(mdir "$r7")"
check "7. --park filing succeeds"                 "[ \"\$(cat '$r7.rc')\" = '0' ]"
check "7. --park pulled the base"                 "[ \"\$(git -C '$r7' rev-parse refs/heads/main)\" = '$ORIGIN_TIP7' ]"
check "7. --park cut lcars/<id> from the NEW tip" \
  "[ \"\$(git -C '$r7' rev-parse refs/heads/lcars/$MID)\" = '$ORIGIN_TIP7' ]"
check "7. --park records verdict 'updated'"       "[ \"\$(sf '$M7/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "7. --park records behindBy 6"              "[ \"\$(sf '$M7/state.json' baseFreshness.behindBy)\" = '6' ]"
check "7. parked state.json is valid JSON"        "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M7/state.json'"
# --complete RE-CHECKS (D3). Nothing has moved since the park here, so the fresh
# verdict is 'current' — the park-time 'updated' claim is NOT carried forward,
# because it describes a moment that has passed.
prd7="$TMPROOT/prd7.md"; write_prd "$prd7"
file_mission "$r7" --complete "$MID" --prd "$prd7"
check "7. --complete RE-CHECKS rather than copying the park-time verdict" \
  "[ \"\$(sf '$M7/state.json' baseFreshness.verdict)\" = 'current' ]"
check "7. --complete records the freshly measured behindBy (0)" \
  "[ \"\$(sf '$M7/state.json' baseFreshness.behindBy)\" = '0' ]"
check "7. completed state.json is valid JSON"     "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M7/state.json'"

# --- Behaviour 8: the baseFreshness SHAPE is complete for every verdict ----
# `behindBy` is an int ONLY when staleness was really measured. Where it was not,
# the value is JSON null — never 0, which is the one value that reads as
# reassuring and is indistinguishable from a genuinely current base.
for pair in "$M1|updated|int" "$M2|stale(dirty)|int" "$M3|stale(diverged)|int" "$M4|unknown(no-remote)|null" \
            "$M5|unknown(unreachable)|null" "$M6|current|int" "$M7|current|int"; do
  d="$(printf '%s' "$pair" | cut -d'|' -f1)"
  v="$(printf '%s' "$pair" | cut -d'|' -f2)"
  k="$(printf '%s' "$pair" | cut -d'|' -f3)"
  check "8. $v: baseFreshness has exactly the nine documented keys" \
    "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if set(f)=={\"verdict\",\"loud\",\"reason\",\"fix\",\"behindBy\",\"aheadBy\",\"baseSha\",\"checkedAt\",\"missionBranchAtBase\"} else 1)' '$d/state.json'"
  # The vocabulary is FOUR words and nothing else may leak into the record.
  check "8. $v: the verdict is one of the four" \
    "case \"\$(sf '$d/state.json' baseFreshness.verdict)\" in current|updated|stale|unknown) true ;; *) false ;; esac"
  check "8. $v: loud is a real boolean, not a string or a number" \
    "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if isinstance(f[\"loud\"],bool) else 1)' '$d/state.json'"
  # The specificity the 15 names carried has to live SOMEWHERE — it lives here.
  check "8. $v: a non-empty reason is always recorded" \
    "[ -n \"\$(sf '$d/state.json' baseFreshness.reason)\" ]"
  if [ "$k" = "int" ]; then
    check "8. $v: behindBy is a MEASURED int" \
      "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if isinstance(f[\"behindBy\"],int) else 1)' '$d/state.json'"
  else
    check "8. $v: behindBy is null (it was never measured)" \
      "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if f[\"behindBy\"] is None else 1)' '$d/state.json'"
  fi
  check "8. $v: checkedAt is the pinned ISO stamp" \
    "[ \"\$(sf '$d/state.json' baseFreshness.checkedAt)\" = '2026-05-30T00:00:00Z' ]"
done

# --- Behaviour 9: a repo with NO COMMITS still files -----------------------
r9="$TMPROOT/b9"
mkdir -p "$r9"
( cd "$r9" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
scaffold_lcars "$r9"
prd9="$TMPROOT/prd9.md"; write_prd "$prd9"
file_mission "$r9" --prd "$prd9"
M9="$(mdir "$r9")"
check "9. an empty repo still files"              "[ \"\$(cat '$r9.rc')\" = '0' ]"
check "9. the existing no-commits warning still fires" \
  "grep -q 'repo has no commits yet' '$r9.out'"
check "9. state.json is valid JSON"               "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M9/state.json'"
check "9. a verdict is still recorded"            "[ -n \"\$(sf '$M9/state.json' baseFreshness.verdict)\" ]"

# --- Behaviour 10: an unpushed local base is NOT a false alarm -------------
# A captain filing from a feature branch origin has never seen must not be
# shouted at — there is nothing to be stale against.
r10="$(make_fixture b10)"
( cd "$r10" && git checkout -q -b feature/local-only ) >/dev/null 2>&1
prd10="$TMPROOT/prd10.md"; write_prd "$prd10"
file_mission "$r10" --prd "$prd10"
M10="$(mdir "$r10")"
check "10. filing from an unpushed branch succeeds" "[ \"\$(cat '$r10.rc')\" = '0' ]"
check "10. verdict is 'current'"                     "[ \"\$(sf '$M10/state.json' baseFreshness.verdict)\" = 'current' ]"
check "10. …and the reason says WHY it is current: no such branch on origin, and it already has the trunk" \
  "reason_has '$M10/state.json' \"origin has no 'feature/local-only' branch\" \
   && reason_has '$M10/state.json' 'already contains everything on origin/main'"
check "10. …and it is not loud"                     "loud_is '$M10/state.json' False"
check "10. NO false-alarm warning block"            "! grep -q 'BASE FRESHNESS' '$r10.out'"
# …and the quiet is EARNED, not assumed: it was measured against origin's trunk
# and really is 0 behind (D1 — the old code declared this quiet without looking).
check "10. the quiet verdict is a MEASURED zero, not an unmeasured one" \
  "[ \"\$(sf '$M10/state.json' baseFreshness.behindBy)\" = '0' ]"
check "10. the base recorded is the feature branch" \
  "[ \"\$(sf '$M10/state.json' base)\" = 'feature/local-only' ]"

# --- Behaviour 11: the helper NEVER blocks and NEVER mutates unsafely ------
# Direct unit-level drives of ensure_base_current, outside file.sh.
r11="$(make_fixture b11)"
advance_origin b11 2
RC11=0
( cd "$r11" && . "$COMMON" && ensure_base_current main >/dev/null 2>&1 ) || RC11=$?
check "11. ensure_base_current returns 0 on the happy path" "[ '$RC11' -eq 0 ]"
RC11b=0
( cd "$r11" && printf 'dirt\n' >>README.md \
    && . "$COMMON" && ensure_base_current main >/dev/null 2>&1 ) || RC11b=$?
check "11. ensure_base_current returns 0 on a dirty tree"   "[ '$RC11b' -eq 0 ]"
( cd "$r11" && git checkout -q -- README.md ) >/dev/null 2>&1
RC11c=0
( cd "$TMPROOT" && . "$COMMON" && ensure_base_current main >/dev/null 2>&1 ) || RC11c=$?
check "11. ensure_base_current returns 0 outside a git repo" "[ '$RC11c' -eq 0 ]"
# It must never reach for a destructive verb. Asserted against the git VERBS the
# function actually invokes (every call goes through "$g"), not against prose —
# the refusal messages legitimately mention `git stash` / `git checkout` as the
# captain's own fix, and a text-matching guard would either false-fail on that or
# have to be weakened until it proved nothing.
# The WHOLE base-freshness section, not just ensure_base_current: round 2 moved
# the network calls into helpers (_lcars_base_fetch_ref / _lcars_base_probe), and
# a guard that only reads the entry point would let a destructive verb hide one
# function away.
BODY11="$TMPROOT/base-freshness.body"
sed -n '/^# BASE FRESHNESS (S158)/,/^# MERGE-PRESERVING CONFIG WRITE/p' "$COMMON" >"$BODY11"
VERBS11="$(grep -oE '"\$g" [a-z-]+' "$BODY11" | sed 's/.*" //' | sort -u | tr '\n' ' ')"
check "11. the extracted function body is non-trivial" "[ \"\$(wc -l <'$BODY11' | tr -d ' ')\" -gt 40 ]"
check "11. some git verbs were actually found (the extraction works)" \
  "[ -n \"\$(printf '%s' \"\$VERBS11\" | tr -d ' ')\" ]"
# Exact verb membership — `merge-base` is a read-only query and must not be
# mistaken for `merge` (a `grep -w` would, since '-' is a word boundary).
#
# ROUND 2, D1 — why `merge` left this list. The property this guard exists to
# protect is "the only ref-moving commands are FAST-FORWARD-ONLY ones", and the
# round-2 restructure made the ref-moving step a purely LOCAL
# `git merge --ff-only <already-fetched-sha>` — exactly the second half of what
# `git pull --ff-only` runs internally, minus the network half that had to be
# bounded (and whose kill is what wrote 8,455 files into a captain's tree while
# reporting "nothing was pulled"). `--ff-only` is non-destructive BY DEFINITION:
# git refuses outright unless the move is a fast-forward. So the honest assertion
# is not "never merge" but "never merge WITHOUT --ff-only", plus the outright ban
# on every verb that can rewrite or discard.
for v in reset checkout switch stash clean push rebase branch commit; do
  check "11. the helper never invokes 'git $v'" \
    "case \" \$VERBS11 \" in *' $v '*) false ;; *) true ;; esac"
done
check "11. 'merge-base' is still matched exactly, never as 'merge'" \
  "case \" \$VERBS11 \" in *' merge-base '*) true ;; *) false ;; esac"
check "11. every 'git merge' invocation is fast-forward-only (never a bare merge)" \
  "[ \"\$(grep -cE '\"[\$]g\" merge ' '$BODY11')\" = \"\$(grep -cE '\"[\$]g\" merge --ff-only ' '$BODY11')\" ]"
check "11. there is exactly ONE ref-moving invocation, and it is merge --ff-only" \
  "[ \"\$(grep -cE '\"[\$]g\" (merge|pull|reset|rebase|update-ref|branch) ' '$BODY11')\" = '1' ] && grep -q '\"[\$]g\" merge --ff-only' '$BODY11'"
# …and the ref-moving step is NEVER bounded: a kill is the only thing that can
# leave a half-written tree, and there is nothing left to kill (round 2, D1).
check "11. the fast-forward is never run through the bounded (killable) runner" \
  "! grep -E '_lcars_base_run_bounded' '$BODY11' | grep -q 'merge'"

# ==========================================================================
# ROUND 1 — the defects a fresh captain-stand-in tester found by driving the real
# product. Each one below reproduces the tester's scenario, not the code's shape.
# ==========================================================================

# --- Behaviour 12 (D1): an unpushed base is measured against origin's TRUNK ---
# The captain does the ordinary thing — `git checkout -b my-wip` — and files. The
# old guard called that "nothing to be stale against" and said NOTHING, while the
# branch sat 4 commits behind trunk and the file only origin had was missing from
# the mission's tree. A topic branch IS stale against the trunk it was cut from.
r12="$(make_fixture b12)"
advance_origin b12 4
ORIGIN_TIP12="$(git -C "$TMPROOT/b12.git" rev-parse refs/heads/main)"
( cd "$r12" && git checkout -q -b my-wip ) >/dev/null 2>&1
WIP_TIP12="$(git -C "$r12" rev-parse refs/heads/my-wip)"
prd12="$TMPROOT/prd12.md"; write_prd "$prd12"
file_mission "$r12" --prd "$prd12"
M12="$(mdir "$r12")"
check "12. filing from an unpushed topic branch succeeds" "[ \"\$(cat '$r12.rc')\" = '0' ]"
check "12. verdict is 'stale' (NOT a silent 'current')" \
  "[ \"\$(sf '$M12/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "12. …and the reason says it was measured against origin's TRUNK" \
  "reason_has '$M12/state.json' 'LCARS measured against origin/main'"
check "12. …and that LCARS refuses to merge a trunk into a topic branch" \
  "reason_has '$M12/state.json' 'will not merge a trunk into a topic branch'"
check "12. …and it is loud"                              "loud_is '$M12/state.json' True"
check "12. behindBy carries the REAL number (4)" \
  "[ \"\$(sf '$M12/state.json' baseFreshness.behindBy)\" = '4' ]"
check "12. the captain is told OUT LOUD"                 "grep -q 'BASE FRESHNESS' '$r12.out'"
check "12. the warning names origin's trunk"             "grep -q 'origin/main' '$r12.out'"
check "12. the warning names the distance"               "grep -q '4 commit(s) behind' '$r12.out'"
check "12. the topic branch was NOT moved" \
  "[ \"\$(git -C '$r12' rev-parse refs/heads/my-wip)\" = '$WIP_TIP12' ]"
check "12. the trunk was NOT merged into the topic branch (no merge, ever)" \
  "[ \"\$(git -C '$r12' rev-parse refs/heads/my-wip)\" != '$ORIGIN_TIP12' ]"
check "12. the origin-only file is still absent (nothing was pulled in)" \
  "[ ! -f '$r12/src/real-view.txt' ]"

# --- Behaviour 12b (D1): the SAME, from a linked git worktree ---------------
# How this captain actually works on LCARS itself: a worktree on an unpushed
# branch. The tester reproduced the silence here too.
WT12="$TMPROOT/b12.worktree"
( cd "$r12" && git worktree add -q -b wip-worktree "$WT12" my-wip ) >/dev/null 2>&1
WTGD12="$(git -C "$WT12" rev-parse --git-dir 2>/dev/null)"
case "$WTGD12" in /*) : ;; *) WTGD12="$WT12/$WTGD12" ;; esac
mkdir -p "$WTGD12/lcars/missions"
cat >"$WTGD12/lcars/config.json" <<EOF
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null,
  "lcarsVersion": "$VERSION_STAMP", "created": "2026-05-30T00:00:00Z" }
EOF
file_mission "$WT12" --prd "$prd12"
M12W="$WTGD12/lcars/missions/$MID"
check "12b. filing from a linked worktree succeeds"      "[ \"\$(cat '$WT12.rc')\" = '0' ]"
check "12b. verdict is 'stale' there too" \
  "[ \"\$(sf '$M12W/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "12b. …measured against the trunk, in the worktree too" \
  "reason_has '$M12W/state.json' 'LCARS measured against origin/main'"
check "12b. behindBy is 4 in the worktree" \
  "[ \"\$(sf '$M12W/state.json' baseFreshness.behindBy)\" = '4' ]"
check "12b. the captain is told OUT LOUD in the worktree" "grep -q 'BASE FRESHNESS' '$WT12.out'"

# --- Behaviour 13 (D1): origin's trunk cannot be resolved → its OWN verdict --
r13="$(make_fixture b13)"
git -C "$TMPROOT/b13.git" symbolic-ref HEAD refs/heads/no-such-branch
( cd "$r13" && git symbolic-ref -d refs/remotes/origin/HEAD && git checkout -q -b topic ) >/dev/null 2>&1
prd13="$TMPROOT/prd13.md"; write_prd "$prd13"
file_mission "$r13" --prd "$prd13"
M13="$(mdir "$r13")"
check "13. filing succeeds when the trunk is unresolvable" "[ \"\$(cat '$r13.rc')\" = '0' ]"
check "13. verdict is 'unknown'"                          "[ \"\$(sf '$M13/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "13. …and the reason names the unresolvable trunk, not some other unknown" \
  "reason_has '$M13/state.json' \"DEFAULT branch could not be resolved\""
check "13. behindBy is null (nothing could be measured)" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"behindBy\"] is None else 1)' '$M13/state.json'"
check "13. the unknown is stated out loud, not swallowed"  "grep -q 'BASE FRESHNESS' '$r13.out'"
check "13. it says staleness is UNKNOWN"                   "grep -qi 'UNKNOWN' '$r13.out'"
# Round 2: the trunk lookup may make a network call, and every network call
# ANNOUNCES itself — so resolving it through a `$(…)` captured the announcement
# as part of the branch NAME and printed
#   ⟳ base freshness — fetching origin/  ⟳ base freshness — asking origin what…
check "13. no announcement is ever captured INSIDE another one" \
  "! grep -q 'fetching origin/.*⟳' '$r13.out'"
check "13. every ⟳ line carries exactly one ⟳" \
  "! grep '⟳' '$r13.out' | grep -q '⟳.*⟳'"

# --- Behaviour 14 (D2): a blackholed remote can NEVER hold filing hostage ----
# Before this, `lcars file` against a firewalled remote printed nothing for 75
# seconds. The fetch is now announced, bounded, and incapable of prompting for
# credentials. `git` is stubbed with one that hangs on `fetch` and delegates
# everything else — a deterministic stand-in for VPN-off.
HANG_GIT="$TMPROOT/hang-git"
cat >"$HANG_GIT" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "fetch" ]; then
    if [ -n "${HANG_ENV_LOG:-}" ]; then
      env | grep -E '^(GIT_TERMINAL_PROMPT|GIT_ASKPASS|SSH_ASKPASS|GIT_SSH_COMMAND)=' \
        >"$HANG_ENV_LOG" 2>/dev/null || true
    fi
    sleep 45
    exit 0
  fi
done
exec git "$@"
EOF
chmod +x "$HANG_GIT"
r14="$(make_fixture b14)"
advance_origin b14 2
ENVLOG14="$TMPROOT/b14.env"
OUT14="$TMPROOT/b14.out"
T14="$SECONDS"
( cd "$r14" && LCARS_GIT_BIN="$HANG_GIT" HANG_ENV_LOG="$ENVLOG14" \
    LCARS_BASE_FETCH_TIMEOUT_SECS=2 \
    bash -c ". '$COMMON'; ensure_base_current main; \
             printf 'VERDICT=%s\n' \"\$LCARS_BASE_VERDICT\"" ) >"$OUT14" 2>&1
EL14=$((SECONDS - T14))
check "14. a blackholed fetch does not hang filing (bounded)" "[ '$EL14' -lt 20 ]"
check "14. the very FIRST thing printed is the fetch announcement" \
  "head -1 '$OUT14' | grep -q 'base freshness — fetching origin'"
check "14. the announcement names the bound"      "head -1 '$OUT14' | grep -q 'up to 2s'"
# ROUND 2, promoted copy (b): this stub hangs `fetch` and delegates EVERYTHING
# else, so origin answers a ref listing instantly — it is demonstrably alive.
# Saying "LCARS could not reach origin" about it was false, and the distinction is
# DETERMINED (origin was asked), not guessed. It survives the four-word collapse
# in the reason sentence: this one says origin ANSWERED, and the remote that
# answers nothing at all says the opposite — proven immediately below.
# The verdict is `unknown` — nothing about '$base' was measured — and WHICH
# unknown it is lives in the reason. The two are still told apart, just not by
# two different verdict names.
check "14. verdict is 'unknown' — nothing was measured" \
  "grep -q '^VERDICT=unknown$' '$OUT14'"
check "14. the reason says origin ANSWERED and the fetch was just slow" \
  "grep -q 'origin ANSWERED a plain ref listing straight away' '$OUT14'"
check "14. …and does NOT claim origin failed to answer" \
  "! grep -q 'did not answer a plain ref listing' '$OUT14'"
check "14. the reason says it TIMED OUT (not a vague failure)" "grep -q 'timed out after 2s' '$OUT14'"
check "14. GIT_TERMINAL_PROMPT=0 is set for the fetch (no credential prompt)" \
  "grep -q '^GIT_TERMINAL_PROMPT=0$' '$ENVLOG14'"
check "14. an askpass is pinned so no GUI/tty prompt can appear" \
  "grep -q '^GIT_ASKPASS=' '$ENVLOG14'"
check "14. ssh is put in BatchMode"               "grep -q 'BatchMode=yes' '$ENVLOG14'"
# …and a remote that answers NOTHING — not a fetch, not a ref listing — is the
# one that really is unreachable.
HANG_ALL_GIT="$TMPROOT/hang-all-git"
cat >"$HANG_ALL_GIT" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in fetch|ls-remote) sleep 45; exit 0 ;; esac
done
exec git "$@"
EOF
chmod +x "$HANG_ALL_GIT"
OUT14C="$TMPROOT/b14c.out"
( cd "$r14" && LCARS_GIT_BIN="$HANG_ALL_GIT" LCARS_BASE_FETCH_TIMEOUT_SECS=2 \
    bash -c ". '$COMMON'; ensure_base_current main; printf 'VERDICT=%s\n' \"\$LCARS_BASE_VERDICT\"" ) \
  >"$OUT14C" 2>&1
check "14. a remote that answers NOTHING is also 'unknown'…" \
  "grep -q '^VERDICT=unknown$' '$OUT14C'"
check "14. …but its reason is the OPPOSITE one — origin never answered" \
  "! grep -q 'origin ANSWERED' '$OUT14C'"
check "14. …and says so: it did not answer a ref listing either" \
  "grep -q 'did not answer a plain ref listing' '$OUT14C'"
# …and the whole filing, not just the helper, survives a blackholed remote.
OUT14B="$TMPROOT/b14b.out"; RC14B=0
prd14="$TMPROOT/prd14.md"; write_prd "$prd14"
T14B="$SECONDS"
( cd "$r14" && LCARS_GIT_BIN="$HANG_GIT" LCARS_BASE_FETCH_TIMEOUT_SECS=2 \
    LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --prd "$prd14" ) >"$OUT14B" 2>&1 || RC14B=$?
EL14B=$((SECONDS - T14B))
check "14. filing still succeeds against a blackholed remote" "[ '$RC14B' -eq 0 ]"
check "14. filing is not held hostage by the network"         "[ '$EL14B' -lt 30 ]"
check "14. the mission was filed"                             "[ -d '$(mdir "$r14")' ]"

# --- Behaviour 15 (D3): park→complete RE-CHECKS, and never carries an expiry --
# Park exists so an idea can sit in the backlog. Origin moves on while it sits —
# that is the point of park — so the park-time verdict is EXPIRED by the time the
# pipeline starts, and copying it forward makes the mission assert it is filed
# against a current tree while local main is behind.
r15="$(make_fixture b15)"
file_mission "$r15" --park "make the leaderboard sortable"
M15="$(mdir "$r15")"
PARK_TIP15="$(git -C "$r15" rev-parse "refs/heads/lcars/$MID")"
check "15. park recorded a verdict"    "[ -n \"\$(sf '$M15/state.json' baseFreshness.verdict)\" ]"
advance_origin b15 5
ORIGIN_TIP15="$(git -C "$TMPROOT/b15.git" rev-parse refs/heads/main)"
prd15="$TMPROOT/prd15.md"; write_prd "$prd15"
(
  cd "$r15"
  LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" LCARS_NOW="2026-06-02T00:00:00Z" \
    bash "$FILE_SCRIPT" --complete "$MID" --prd "$prd15" >"$r15.complete.out" 2>&1
) || true
check "15. --complete re-checks: the verdict is the FRESH one" \
  "[ \"\$(sf '$M15/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "15. --complete records the freshly measured distance (5)" \
  "[ \"\$(sf '$M15/state.json' baseFreshness.behindBy)\" = '5' ]"
check "15. checkedAt is the COMPLETE-time stamp, not the park-time one" \
  "[ \"\$(sf '$M15/state.json' baseFreshness.checkedAt)\" = '2026-06-02T00:00:00Z' ]"
check "15. the base really was brought up to date at complete time" \
  "[ \"\$(git -C '$r15' rev-parse refs/heads/main)\" = '$ORIGIN_TIP15' ]"
check "15. the already-cut mission branch was NOT re-cut or moved" \
  "[ \"\$(git -C '$r15' rev-parse refs/heads/lcars/$MID)\" = '$PARK_TIP15' ]"
check "15. the branch's lag is stated OUT LOUD"  "grep -q 'MISSION BRANCH' '$r15.complete.out'"
check "15. …naming how far behind it is"         "grep -q 'is 5 commit(s) behind main' '$r15.complete.out'"
check "15. …with the exact command that fixes it" \
  "grep -q 'git branch -f lcars/$MID main' '$r15.complete.out'"
check "15. missionBranchAtBase is honestly false" \
  "[ \"\$(sf '$M15/state.json' baseFreshness.missionBranchAtBase)\" = 'False' ]"
check "15. completed state.json is valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M15/state.json'"

# --- Behaviour 16 (D4): the ff is REFUSED when it would eat a local file -----
# `.gitignore` has dist/, the captain has a local dist/bundle.js, upstream
# force-adds that path. `git status --porcelain` is EMPTY, so the tree reads clean
# and a pull nobody typed silently destroys the captain's file.
r16="$(make_fixture b16)"
(
  cd "$TMPROOT/b16.seed"
  printf 'dist/\n' >.gitignore
  git add -A && git commit -q -m "ignore dist"
  git push -q origin main
) >/dev/null 2>&1
( cd "$r16" && git pull -q --ff-only origin main ) >/dev/null 2>&1
mkdir -p "$r16/dist"
printf 'MY LOCAL BUILD\n' >"$r16/dist/bundle.js"
LOCAL_BUNDLE16="$(cksum <"$r16/dist/bundle.js")"
(
  cd "$TMPROOT/b16.seed"
  mkdir -p dist && printf 'UPSTREAM BUILD\n' >dist/bundle.js
  git add -f dist/bundle.js && git commit -q -m "force-add dist/bundle.js"
  git push -q origin main
) >/dev/null 2>&1
BEFORE_MAIN16="$(git -C "$r16" rev-parse refs/heads/main)"
check "16. the trap is real: git status reads CLEAN" \
  "[ -z \"\$(git -C '$r16' status --porcelain)\" ]"
prd16="$TMPROOT/prd16.md"; write_prd "$prd16"
file_mission "$r16" --prd "$prd16"
M16="$(mdir "$r16")"
check "16. filing still succeeds"                 "[ \"\$(cat '$r16.rc')\" = '0' ]"
check "16. verdict is 'stale'"                     "[ \"\$(sf '$M16/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "16. …and the reason names the CLOBBER as the blocker, not a dirty tree" \
  "reason_has '$M16/state.json' 'would OVERWRITE local file(s) git is not tracking'"
check "16. the captain's gitignored file is byte-identical" \
  "[ \"\$(cksum <'$r16/dist/bundle.js')\" = '$LOCAL_BUNDLE16' ]"
check "16. NO pull happened (main unmoved)" \
  "[ \"\$(git -C '$r16' rev-parse refs/heads/main)\" = '$BEFORE_MAIN16' ]"
check "16. the refusal NAMES the colliding path" "grep -q 'dist/bundle.js' '$r16.out'"
check "16. the refusal is loud and legible"      "grep -q 'BASE FRESHNESS' '$r16.out'"
check "16. behindBy was still measured (1)"      "[ \"\$(sf '$M16/state.json' baseFreshness.behindBy)\" = '1' ]"

# --- Behaviour 17 (D6): a leftover mission branch never gets a false ✓ -------
r17="$(make_fixture b17)"
advance_origin b17 4
STALE17="$(git -C "$r17" rev-parse HEAD)"
git -C "$r17" branch "lcars/$MID" "$STALE17" >/dev/null 2>&1
prd17="$TMPROOT/prd17.md"; write_prd "$prd17"
file_mission "$r17" --prd "$prd17"
M17="$(mdir "$r17")"
check "17. filing succeeds"                        "[ \"\$(cat '$r17.rc')\" = '0' ]"
check "17. the leftover branch was reused, not moved" \
  "[ \"\$(git -C '$r17' rev-parse refs/heads/lcars/$MID)\" = '$STALE17' ]"
check "17. the readout still says it was reused"   "grep -q 'already exists — reusing it' '$r17.out'"
# Matched on the CLAIM, not on one wording of it: the pre-fix line said "this
# mission is filed against the CURRENT tree" and the new one would say "is cut
# from the CURRENT tree", so a phrase-specific check would pass against the very
# defect it exists to catch.
check "17. it makes NO claim, in any wording, that this mission is on the current tree" \
  "! grep -qi 'CURRENT tree' '$r17.out'"
check "17. the contradiction is replaced by the truth"  "grep -q 'MISSION BRANCH' '$r17.out'"
check "17. …naming the lag"                             "grep -q 'is 4 commit(s) behind main' '$r17.out'"
check "17. …and the exact command to fix it"            "grep -q 'git branch -f lcars/$MID main' '$r17.out'"
check "17. missionBranchAtBase is false, so baseSha cannot be misread" \
  "[ \"\$(sf '$M17/state.json' baseFreshness.missionBranchAtBase)\" = 'False' ]"

# --- Behaviour 18 (D7): a detached HEAD reads as a detached commit -----------
r18="$(make_fixture b18)"
advance_origin b18 3
( cd "$r18" && git checkout -q --detach HEAD ) >/dev/null 2>&1
prd18="$TMPROOT/prd18.md"; write_prd "$prd18"
file_mission "$r18" --prd "$prd18"
M18="$(mdir "$r18")"
check "18. filing succeeds on a detached HEAD"   "[ \"\$(cat '$r18.rc')\" = '0' ]"
check "18. verdict is 'stale'"                    "[ \"\$(sf '$M18/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "18. …and the reason names the un-checked-out base as the blocker" \
  "reason_has '$M18/state.json' 'LCARS will not check out another branch'"
check "18. it never prints the tautology \"HEAD is on 'HEAD'\"" \
  "! grep -q \"HEAD is on 'HEAD'\" '$r18.out'"
check "18. it says HEAD is on a detached commit" "grep -q 'HEAD is on a detached commit' '$r18.out'"

# --- Behaviour 19 (copy): the Means block says only what is TRUE of a verdict -
# `no-base` fires precisely because there is no local base — so it must not print
# the boilerplate "this mission is filed against your LOCAL main".
r19="$(make_fixture b19)"
( cd "$r19" && git branch -m main mymain && git checkout -q --detach ) >/dev/null 2>&1
prd19="$TMPROOT/prd19.md"; write_prd "$prd19"
file_mission "$r19" --prd "$prd19"
M19="$(mdir "$r19")"
check "19. filing succeeds"                      "[ \"\$(cat '$r19.rc')\" = '0' ]"
check "19. verdict is 'unknown'"                 "[ \"\$(sf '$M19/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "19. …and the reason names the missing local base, not some other unknown" \
  "reason_has '$M19/state.json' \"there is no local 'main' branch\""
check "19. it does NOT claim a LOCAL main it just said does not exist" \
  "! grep -q 'filed against your LOCAL' '$r19.out'"
check "19. the Means line is true of THIS verdict" \
  "grep -q 'cut from HEAD as it stands' '$r19.out'"
check "19. behindBy is null (nothing was measurable)" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"behindBy\"] is None else 1)' '$M19/state.json'"

# --- Behaviour 20 (copy): 'disabled' still records the sha it trivially had ---
r20="$(make_fixture b20)"
HEAD20="$(git -C "$r20" rev-parse HEAD)"
prd20="$TMPROOT/prd20.md"; write_prd "$prd20"
(
  cd "$r20"
  LCARS_BASE_FRESHNESS=0 LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" \
    LCARS_NOW="2026-05-30T00:00:00Z" bash "$FILE_SCRIPT" --prd "$prd20" >"$r20.out" 2>&1
) || true
M20="$(mdir "$r20")"
check "20. verdict is 'unknown'"                  "[ \"\$(sf '$M20/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "20. …and the reason names the kill switch, so it is not mistaken for a failure" \
  "reason_has '$M20/state.json' 'LCARS_BASE_FRESHNESS=0'"
check "20. …and it is silent (a switched-off guard must not shout)" \
  "loud_is '$M20/state.json' False"
check "20. baseSha is recorded, not left empty"  "[ \"\$(sf '$M20/state.json' baseFreshness.baseSha)\" = '$HEAD20' ]"
check "20. behindBy is null (nothing was measured)" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"behindBy\"] is None else 1)' '$M20/state.json'"
check "20. the kill switch really made no network call" \
  "! grep -q 'fetching origin' '$r20.out'"

# ==========================================================================
# ROUND 2 — the defects the ROUND-1 FIXES THEMSELVES introduced, as a second
# fresh captain-stand-in tester found them by driving the real product.
# ==========================================================================

# now_s — sub-second wall clock. `SECONDS` has 1s granularity, which is too
# coarse to tell "the bound was honoured" from "the bound was overshot by 2.3s".
now_s() { python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || printf '0'; }
# el_lt <t0> <limit> — 0 when (now - t0) < limit.
el_lt() { python3 -c 'import sys; sys.exit(0 if (float(sys.argv[1])-float(sys.argv[2])) < float(sys.argv[3]) else 1)' "$(now_s)" "$1" "$2"; }

# --- Behaviour 21 (D1): a low pull bound can NEVER half-write the tree --------
# The tester set LCARS_BASE_PULL_TIMEOUT_SECS=1 against a clone one commit behind
# — where that commit adds thousands of files — so the kill landed mid-checkout.
# Result: 8,455 files written into the captain's tree and `?? big/` untracked,
# while the printed block said "nothing was pulled". The pull's NETWORK half is
# already covered by the bounded fetch that precedes it, so the ref-moving step
# is now a purely LOCAL fast-forward that is NEVER bounded and therefore never
# killable. There is nothing left that can land mid-checkout.
r21="$(make_fixture b21)"
(
  cd "$TMPROOT/b21.seed"
  git pull -q --ff-only origin main
  python3 -c "
import os
os.makedirs('big', exist_ok=True)
for i in range(12000):
    open('big/f%d.txt' % i, 'w').write('x' * 200 + str(i))
"
  git add -A && git commit -q -m "a commit that adds a great many files"
  git push -q origin main
) >/dev/null 2>&1
ORIGIN_TIP21="$(git -C "$TMPROOT/b21.git" rev-parse refs/heads/main)"
BEFORE_STATUS21="$(git -C "$r21" status --porcelain)"
prd21="$TMPROOT/prd21.md"; write_prd "$prd21"
RC21=0
(
  cd "$r21"
  LCARS_BASE_PULL_TIMEOUT_SECS=1 LCARS_GH_BIN="$GH_STUB" LCARS_DATE="20260530" \
    LCARS_NOW="2026-05-30T00:00:00Z" bash "$FILE_SCRIPT" --prd "$prd21" >"$r21.out" 2>&1
) || RC21=$?
M21="$(mdir "$r21")"
check "21. filing succeeds with an absurdly low pull bound" "[ '$RC21' -eq 0 ]"
check "21. the ref-moving step is NOT bounded — verdict is 'updated'" \
  "[ \"\$(sf '$M21/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "21. the base really did move to the origin tip" \
  "[ \"\$(git -C '$r21' rev-parse refs/heads/main)\" = '$ORIGIN_TIP21' ]"
check "21. NOT ONE untracked file was written into the captain's tree" \
  "[ -z \"\$(git -C '$r21' status --porcelain | grep '^??')\" ]"
check "21. the working tree status is exactly what it was before filing" \
  "[ \"\$(git -C '$r21' status --porcelain)\" = \"\$BEFORE_STATUS21\" ]"
check "21. it never claims 'nothing was pulled' while having written files" \
  "! grep -q 'nothing was pulled' '$r21.out'"
check "21. a follow-up pull is a clean no-op (the repo is not left wedged)" \
  "git -C '$r21' pull --ff-only origin main >/dev/null 2>&1"

# --- Behaviour 22 (D2): a timeout prints NO bash job-control noise ------------
# The tester saw, on stderr, between the ⟳ line and the warning block:
#   …/lcars-common.sh: line 248: 92631 Terminated: 15  perl -e 'use POSIX …'
# It reads like a crash, names an internal path, and lands in whatever captures
# the CLI's output — the viewscreen daemon included.
r22="$(make_fixture b22)"
advance_origin b22 2
OUT22="$TMPROOT/b22.out"
(
  cd "$r22" && LCARS_GIT_BIN="$HANG_GIT" LCARS_BASE_FETCH_TIMEOUT_SECS=2 \
    bash -c ". '$COMMON'; ensure_base_current main"
) >"$OUT22" 2>&1
check "22. stdout+stderr contain no 'Terminated' report"      "! grep -q 'Terminated' '$OUT22'"
check "22. …no mention of the internal perl runner"           "! grep -q 'perl' '$OUT22'"
check "22. …and no 'lcars-common.sh: line N' crash-looking prefix" \
  "! grep -q 'lcars-common.sh: line' '$OUT22'"
check "22. the captain DOES still see the ⟳ announcement"     "grep -q 'base freshness' '$OUT22'"
check "22. …and the warning block"                            "grep -q 'BASE FRESHNESS' '$OUT22'"

# --- Behaviour 23 (copy a): the announced bound is not UNDER-stated -----------
# Measured by the tester: claimed 2s → 3.7s, claimed 5s → 6.9s, claimed 8s →
# 10.3s. The claim and the accounting must agree.
T23="$(now_s)"
(
  cd "$r22" && LCARS_GIT_BIN="$HANG_GIT" LCARS_BASE_FETCH_TIMEOUT_SECS=3 \
    bash -c ". '$COMMON'; ensure_base_current main"
) >"$TMPROOT/b23.out" 2>&1
check "23. a claimed 3s bound really returns within ~3s (not 5s+)" "el_lt '$T23' 4.5"
check "23. the announcement states the bound it actually honours" \
  "grep -q 'up to 3s' '$TMPROOT/b23.out'"
check "23. every bounded network call announces itself (not just the first)" \
  "[ \"\$(grep -c 'base freshness' '$TMPROOT/b23.out')\" -ge 1 ]"

# --- Behaviour 24 (copy b): a TIMEOUT is not unreachability -------------------
# The hang-git stub hangs `fetch` and delegates everything else, so origin is
# demonstrably alive — it answers a ref listing instantly. Calling that
# "LCARS could not reach origin" is simply false.
check "24. a slow-but-alive origin is NOT reported as unreachable" \
  "! grep -q 'could not reach origin' '$OUT22'"
check "24. the copy says origin ANSWERED, it was just too slow" \
  "grep -qi 'answered' '$OUT22'"
check "24. the REASON distinguishes a timeout from a dead remote" \
  "grep -q 'timed out after' '$OUT22' && grep -q 'origin ANSWERED' '$OUT22'"
# …and a genuinely dead remote still reads as unreachable (behaviour 5's repo).
check "24. a genuinely dead origin still says it could not be reached" \
  "grep -q 'could not fetch' '$r5.out'"

# --- Behaviour 25 (copy c): dirty + unreachable names CONNECTIVITY first ------
# The printed fix was `git stash … then git pull --ff-only origin main`. Verified
# by the tester: the pull fails ("Please make sure you have the correct access
# rights") — the fix cannot succeed while origin is unreachable, and the copy
# never mentioned connectivity.
r25="$(make_fixture b25)"
( cd "$r25" && git remote set-url origin "$TMPROOT/definitely-not-here.git" )
printf 'captain work\n' >>"$r25/README.md"
prd25="$TMPROOT/prd25.md"; write_prd "$prd25"
file_mission "$r25" --prd "$prd25"
M25="$(mdir "$r25")"
check "25. filing succeeds"                       "[ \"\$(cat '$r25.rc')\" = '0' ]"
# NOTE the verdict split the four-word vocabulary makes explicit: a dirty tree
# whose staleness was actually MEASURED is `stale` (behaviour 26), but a dirty
# tree behind an origin that never answered measured NOTHING — calling that
# `stale` would assert a staleness LCARS never established. It is `unknown`, and
# the dirt is still named in the reason.
check "25. verdict is 'unknown' — nothing was measured"  "[ \"\$(sf '$M25/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "25. …and behindBy is null, matching that claim" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"behindBy\"] is None else 1)' '$M25/state.json'"
check "25. …and the reason still names the dirty tree"  "reason_has '$M25/state.json' 'the working tree has'"
check "25. …and names the unreachable origin as the reason nothing was measured" \
  "reason_has '$M25/state.json' 'could not fetch from origin'"
check "25. the fix names the connectivity problem FIRST, not just a stash" \
  "grep -qi 'reach origin first' '$r25.out'"
check "25. it does not present a bare pull as a working fix" \
  "! grep -qE 'Fix: +git stash' '$r25.out'"

# --- Behaviour 26 (copy d): the copy matches the KIND of dirt -----------------
# Untracked-only dirt was reported as "N uncommitted change(s)" with the fix
# `git stash` — which does not touch untracked files at all.
r26="$(make_fixture b26)"
advance_origin b26 2
printf 'scratch\n' >"$r26/only-untracked.txt"
prd26="$TMPROOT/prd26.md"; write_prd "$prd26"
file_mission "$r26" --prd "$prd26"
M26="$(mdir "$r26")"
check "26. verdict is 'stale' — dirty AND measured"  "[ \"\$(sf '$M26/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "26. …and behindBy really was measured (2)"   "[ \"\$(sf '$M26/state.json' baseFreshness.behindBy)\" = '2' ]"
check "26. the block names the dirt as UNTRACKED, not vaguely 'uncommitted'" \
  "grep -q 'untracked file(s)' '$r26.out'"
check "26. the suggested stash is the one that actually moves untracked files" \
  "grep -q 'git stash -u' '$r26.out'"
check "26. …and it does NOT suggest a plain \`git stash\` that would no-op" \
  "! grep -qE 'Fix: +git stash +(\\(|t)' '$r26.out'"
# RUN the printed fix in a throwaway copy and prove it lands where the copy says.
FIXDIR26="$TMPROOT/b26.fixrun"
rm -rf "$FIXDIR26"; cp -R "$r26" "$FIXDIR26"
FIXRC26=0
( cd "$FIXDIR26" && git stash -u && git pull --ff-only origin main ) >"$TMPROOT/b26.fix.out" 2>&1 || FIXRC26=$?
check "26. the printed fix RUNS clean"            "[ '$FIXRC26' -eq 0 ]"
check "26. …and leaves the base where the copy promises" \
  "[ \"\$(git -C '$FIXDIR26' rev-parse refs/heads/main)\" = \"\$(git -C '$TMPROOT/b26.git' rev-parse refs/heads/main)\" ]"
# A TRACKED modification still gets the plain stash — the copy follows the dirt.
r26b="$(make_fixture b26b)"
advance_origin b26b 2
printf 'edit\n' >>"$r26b/README.md"
prd26b="$TMPROOT/prd26b.md"; write_prd "$prd26b"
file_mission "$r26b" --prd "$prd26b"
check "26b. a tracked edit is named as an unstaged change" \
  "grep -q 'unstaged change(s)' '$r26b.out'"

# --- Behaviour 27 (D3): a DETACHED HEAD is described honestly -----------------
# 3 local `main` commits + 2 origin commits, then `git checkout --detach HEAD~3`.
# The mission branch is cut from the DETACHED commit — not from `main` — so
# "this mission is filed against your LOCAL 'main'" is false, "(off main)" is
# false, "lcars/<id> already existed" is false (this filing created it), and
# `git branch -f` must not be offered as if it were free.
r27="$(make_fixture b27)"
advance_origin b27 2
(
  cd "$r27"
  for i in 1 2 3; do
    printf 'local %s\n' "$i" >>"local$i.txt"
    git add -A && git commit -q -m "local commit $i"
  done
  git checkout -q --detach HEAD~3
) >/dev/null 2>&1
DETACHED27="$(git -C "$r27" rev-parse HEAD)"
DETACHED27S="$(git -C "$r27" rev-parse --short HEAD)"
prd27="$TMPROOT/prd27.md"; write_prd "$prd27"
file_mission "$r27" --prd "$prd27"
M27="$(mdir "$r27")"
check "27. filing succeeds on a detached HEAD"   "[ \"\$(cat '$r27.rc')\" = '0' ]"
check "27. the mission branch really was cut from the detached commit" \
  "[ \"\$(git -C '$r27' rev-parse refs/heads/lcars/$MID)\" = '$DETACHED27' ]"
check "27. it does NOT claim the mission is filed against your LOCAL main" \
  "! grep -q \"filed against your LOCAL 'main'\" '$r27.out'"
check "27. the readout does NOT say '(off main)' when it is not" \
  "! grep -q '(off main)' '$r27.out'"
check "27. the readout names where the branch really came from" \
  "grep -q '$DETACHED27S' '$r27.out'"
check "27. the MISSION BRANCH block does NOT claim the branch pre-existed" \
  "! grep -q 'already existed at' '$r27.out'"
check "27. …it says the branch was CUT from that commit by this filing" \
  "grep -qi 'was cut by this filing from' '$r27.out'"
check "27. …and names the commit the mission branch is really on" \
  "grep -q 'MISSION BRANCH' '$r27.out' && grep -q '$DETACHED27S' '$r27.out'"
# The offered fix must state its own consequence honestly, and must RUN.
check "27. any 'git branch -f' offered is labelled as a loss-free fast-forward" \
  "! grep -q 'git branch -f' '$r27.out' || grep -qi 'no commits of its own' '$r27.out'"
FIXDIR27="$TMPROOT/b27.fixrun"
rm -rf "$FIXDIR27"; cp -R "$r27" "$FIXDIR27"
FIXRC27=0
( cd "$FIXDIR27" && git branch -f "lcars/$MID" main ) >/dev/null 2>&1 || FIXRC27=$?
check "27. the printed branch fix RUNS clean"    "[ '$FIXRC27' -eq 0 ]"

# --- Behaviour 27b (D3): a mission branch with its OWN commits is never -f'd --
r27b="$(make_fixture b27b)"
advance_origin b27b 3
( cd "$r27b" && git branch "lcars/$MID" HEAD \
    && git checkout -q "lcars/$MID" \
    && printf 'mission work\n' >mission.txt && git add -A && git commit -q -m "mission work" \
    && git checkout -q main ) >/dev/null 2>&1
MTIP27B="$(git -C "$r27b" rev-parse "refs/heads/lcars/$MID")"
prd27b="$TMPROOT/prd27b.md"; write_prd "$prd27b"
file_mission "$r27b" --prd "$prd27b"
check "27b. the mission branch keeps its own commit" \
  "[ \"\$(git -C '$r27b' rev-parse refs/heads/lcars/$MID)\" = '$MTIP27B' ]"
check "27b. NO destructive 'git branch -f' is suggested for a branch with work" \
  "! grep -q 'git branch -f' '$r27b.out'"
check "27b. a safe route is offered instead"     "grep -q 'git rebase' '$r27b.out'"
# R5 SMELL: the command is right and its RESULT is right — but it silently
# RELOCATES the captain. `git rebase <base> <mb>` checks <mb> out and LEAVES them
# there, in a feature whose entire doctrine is "LCARS will not check out another
# branch" (behaviour 7). The command does not change; the string has to admit
# what it does and name the way back.
check "27b. …and the fix admits it leaves you ON the mission branch" \
  "grep -qi 'leaves you on' '$r27b.out'"
check "27b. …and prints the way back to the branch you were on" \
  "grep -q 'git checkout main' '$r27b.out'"
# RUN IT. Six unrunnable `Fix:` strings have been caught in this round; a fix
# string that is touched is a fix string that gets executed.
FIXDIR27B="$TMPROOT/b27b.fixrun"
rm -rf "$FIXDIR27B"; cp -R "$r27b" "$FIXDIR27B"
FIXRC27B=0
( cd "$FIXDIR27B" && git rebase main "lcars/$MID" ) >/dev/null 2>&1 || FIXRC27B=$?
check "27b. the printed rebase fix RUNS clean"   "[ '$FIXRC27B' -eq 0 ]"
check "27b. …the mission branch's own commit survives it" \
  "git -C '$FIXDIR27B' log --oneline 'refs/heads/lcars/$MID' | qgrep -q 'mission work'"
check "27b. …and the base tip is now contained in the mission branch" \
  "git -C '$FIXDIR27B' merge-base --is-ancestor refs/heads/main 'refs/heads/lcars/$MID'"
# …and the relocation the new clause warns about is REAL, not a hedge.
check "27b. …it really does leave HEAD on the mission branch, exactly as warned" \
  "[ \"\$(git -C '$FIXDIR27B' symbolic-ref -q --short HEAD)\" = 'lcars/$MID' ]"
check "27b. the printed way back RUNS clean and returns you to main" \
  "( cd '$FIXDIR27B' && git checkout -q main ) && [ \"\$(git -C '$FIXDIR27B' symbolic-ref -q --short HEAD)\" = 'main' ]"
prd27bf="$TMPROOT/prd27bf.md"; write_prd "$prd27bf"
file_mission "$FIXDIR27B" --prd "$prd27bf"
check "27b. re-filing after the fix succeeds"    "[ \"\$(cat '$FIXDIR27B.rc')\" = '0' ]"
check "27b. …and there is no MISSION BRANCH lag left to warn about" \
  "! grep -q 'MISSION BRANCH' '$FIXDIR27B.out'"

# --- Behaviour 28 (D4): filing does NOT restructure the captain's remote refs --
# The tester's clone had 2 remote-tracking refs and 0 tags; ONE `lcars file`
# turned that into 62 refs and 1 tag, because round 1 widened the call to a bare
# `git fetch origin` to make origin/<trunk> available.
r28="$(make_fixture b28)"
(
  cd "$TMPROOT/b28.seed"
  for i in $(seq 1 30); do git branch "topic/$i" main; done
  git tag v9.9.9
  git push -q origin --all
  git push -q origin v9.9.9
) >/dev/null 2>&1
advance_origin b28 1
REFS28_BEFORE="$(git -C "$r28" for-each-ref --format='%(refname)' refs/remotes | wc -l | tr -d ' ')"
TAGS28_BEFORE="$(git -C "$r28" tag -l | wc -l | tr -d ' ')"
prd28="$TMPROOT/prd28.md"; write_prd "$prd28"
file_mission "$r28" --prd "$prd28"
M28="$(mdir "$r28")"
REFS28_AFTER="$(git -C "$r28" for-each-ref --format='%(refname)' refs/remotes | wc -l | tr -d ' ')"
TAGS28_AFTER="$(git -C "$r28" tag -l | wc -l | tr -d ' ')"
check "28. filing still brought the base up to date" \
  "[ \"\$(sf '$M28/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "28. the remote-tracking ref count is UNCHANGED (no whole-remote fetch)" \
  "[ '$REFS28_AFTER' = '$REFS28_BEFORE' ]"
check "28. no tags were auto-followed into the captain's clone" \
  "[ '$TAGS28_AFTER' = '$TAGS28_BEFORE' ] && [ '$TAGS28_AFTER' = '0' ]"
# …and the behind-the-trunk measurement round 1 widened the fetch FOR still works,
# without dragging the rest of the remote in.
r28b="$(make_fixture b28b)"
(
  cd "$TMPROOT/b28b.seed"
  for i in $(seq 1 30); do git branch "topic/$i" main; done
  git tag v1.2.3
  git push -q origin --all
  git push -q origin v1.2.3
) >/dev/null 2>&1
advance_origin b28b 4
( cd "$r28b" && git checkout -q -b my-wip ) >/dev/null 2>&1
REFS28B_BEFORE="$(git -C "$r28b" for-each-ref --format='%(refname)' refs/remotes | wc -l | tr -d ' ')"
TAGS28B_BEFORE="$(git -C "$r28b" tag -l | wc -l | tr -d ' ')"
prd28b="$TMPROOT/prd28b.md"; write_prd "$prd28b"
file_mission "$r28b" --prd "$prd28b"
M28B="$(mdir "$r28b")"
check "28b. the distance behind the trunk is still measured (4) with a NARROW fetch" \
  "[ \"\$(sf '$M28B/state.json' baseFreshness.behindBy)\" = '4' ]"
check "28b. …and the verdict is still stale, measured against the trunk" \
  "[ \"\$(sf '$M28B/state.json' baseFreshness.verdict)\" = 'stale' ] \
   && reason_has '$M28B/state.json' 'LCARS measured against origin/main'"
check "28b. the trunk fetch pulled in only the trunk, not 30 topic branches" \
  "[ '$(git -C "$r28b" for-each-ref --format='%(refname)' refs/remotes | wc -l | tr -d " ")' = '$REFS28B_BEFORE' ]"
check "28b. …and still no tags"                   "[ \"\$(git -C '$r28b' tag -l | wc -l | tr -d ' ')\" = '$TAGS28B_BEFORE' ]"

# --- Behaviour 29 (copy e): an unknown baseSha is JSON null, like every other --
check "29. the empty repo records baseSha as null, not an empty string" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"baseSha\"] is None else 1)' '$M9/state.json'"
check "29. a known baseSha is still a string"     "[ -n \"\$(sf '$M1/state.json' baseFreshness.baseSha)\" ]"

# --- Behaviour 30 (copy f): the MISSION BRANCH block gets its blank line -------
# The block's trailing newline is stripped by command substitution, so it butted
# straight against `Mission filed:` — unlike the BASE FRESHNESS block.
check "30. a blank line separates the MISSION BRANCH block from the readout" \
  "grep -B1 'Mission filed: $MID' '$r17.out' | head -1 | grep -qE '^[[:space:]]*\$'"
check "30. the BASE FRESHNESS block keeps its blank line too" \
  "grep -B1 'Mission filed: $MID' '$r3.out' | head -1 | grep -qE '^[[:space:]]*\$'"

# --- Behaviour 31 (copy g): an IDENTICAL ignored file loses nothing -----------
# The clobber refusal exists to protect a file whose content would be destroyed. When
# the local content is byte-identical to the incoming file, nothing is at risk.
r31="$(make_fixture b31)"
(
  cd "$TMPROOT/b31.seed"
  printf 'dist/\n' >.gitignore
  git add -A && git commit -q -m "ignore dist"
  git push -q origin main
) >/dev/null 2>&1
( cd "$r31" && git pull -q --ff-only origin main ) >/dev/null 2>&1
mkdir -p "$r31/dist"
printf 'SAME BUILD\n' >"$r31/dist/bundle.js"
(
  cd "$TMPROOT/b31.seed"
  mkdir -p dist && printf 'SAME BUILD\n' >dist/bundle.js
  git add -f dist/bundle.js && git commit -q -m "force-add an identical dist/bundle.js"
  git push -q origin main
) >/dev/null 2>&1
ORIGIN_TIP31="$(git -C "$TMPROOT/b31.git" rev-parse refs/heads/main)"
prd31="$TMPROOT/prd31.md"; write_prd "$prd31"
file_mission "$r31" --prd "$prd31"
M31="$(mdir "$r31")"
check "31. an identical ignored file does not trigger the clobber refusal" \
  "[ \"\$(sf '$M31/state.json' baseFreshness.verdict)\" = 'updated' ]"
check "31. the base was brought up to date"       "[ \"\$(git -C '$r31' rev-parse refs/heads/main)\" = '$ORIGIN_TIP31' ]"
check "31. the file's content is unchanged"       "grep -q 'SAME BUILD' '$r31/dist/bundle.js'"
check "31. a DIFFERENT ignored file still refuses (behaviour 16 still holds)" \
  "[ \"\$(sf '$M16/state.json' baseFreshness.verdict)\" = 'stale' ] \
   && reason_has '$M16/state.json' 'would OVERWRITE local file(s) git is not tracking'"

# ==========================================================================
# ROUND 3 — five defects a THIRD fresh captain-stand-in tester found, in
# territory no earlier round exercised: filenames that are not ASCII, a base
# that is merely AHEAD, a fix command that cannot run, and a sha the record
# substitutes when it has none.
# ==========================================================================

# --- Behaviour 33 (R3 D1): the clobber guard is QUOTING-PROOF ----------------
# `core.quotePath` is git's DEFAULT, so `git diff --name-only` emits C-quoted
# paths — "build/caf\303\251.txt" — for any path with a non-ASCII byte, a `"` or
# a `\`. The guard read that literal string, `[ -e "$p" ]` failed, and the path
# was silently dropped: the fast-forward went through with a ✓ and the captain's
# gitignored file was destroyed. Worse, with a mixed set the warning named ONLY
# the ASCII sibling, so obeying the printed fix and re-filing overwrote the rest.
r33="$(make_fixture b33)"
(
  cd "$TMPROOT/b33.seed"
  printf 'build/\n' >.gitignore
  git add -A && git commit -q -m "ignore build"
  git push -q origin main
) >/dev/null 2>&1
( cd "$r33" && git pull -q --ff-only origin main ) >/dev/null 2>&1
# The captain's own irreplaceable local files, in six flavours of name.
N33_1='build/plain.txt'
N33_2='build/café-résumé.txt'
N33_3='build/日本語.txt'
N33_4='build/with space.txt'
N33_5='build/quo"te.txt'
N33_6='build/back\slash.txt'
mkdir -p "$r33/build"
for n33 in "$N33_1" "$N33_2" "$N33_3" "$N33_4" "$N33_5" "$N33_6"; do
  printf 'IRREPLACEABLE LOCAL DATA\n' >"$r33/$n33"
done
SUM33_1="$(cksum <"$r33/$N33_1")"; SUM33_2="$(cksum <"$r33/$N33_2")"
SUM33_3="$(cksum <"$r33/$N33_3")"; SUM33_4="$(cksum <"$r33/$N33_4")"
SUM33_5="$(cksum <"$r33/$N33_5")"; SUM33_6="$(cksum <"$r33/$N33_6")"
(
  cd "$TMPROOT/b33.seed"
  mkdir -p build
  for n33 in "$N33_1" "$N33_2" "$N33_3" "$N33_4" "$N33_5" "$N33_6"; do
    printf 'UPSTREAM BUILD\n' >"$n33"
  done
  git add -f build && git commit -q -m "force-add a build/ directory of many-named files"
  git push -q origin main
) >/dev/null 2>&1
BEFORE_MAIN33="$(git -C "$r33" rev-parse refs/heads/main)"
check "33. the trap is real: git status reads CLEAN" \
  "[ -z \"\$(git -C '$r33' status --porcelain)\" ]"
check "33. …and git really does C-quote those paths by default" \
  "git -C '$TMPROOT/b33.git' diff --name-only '$BEFORE_MAIN33' refs/heads/main | qgrep -q '^\"build/'"
prd33="$TMPROOT/prd33.md"; write_prd "$prd33"
file_mission "$r33" --prd "$prd33"
M33="$(mdir "$r33")"
check "33. filing still succeeds"                  "[ \"\$(cat '$r33.rc')\" = '0' ]"
check "33. the fast-forward is REFUSED (verdict stale), not waved through" \
  "[ \"\$(sf '$M33/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "33. …and the reason names the clobber" \
  "reason_has '$M33/state.json' 'would OVERWRITE local file(s) git is not tracking'"
check "33. NO pull happened (main unmoved)" \
  "[ \"\$(git -C '$r33' rev-parse refs/heads/main)\" = '$BEFORE_MAIN33' ]"
i33=1
for n33 in "$N33_1" "$N33_2" "$N33_3" "$N33_4" "$N33_5" "$N33_6"; do
  check "33. the refusal NAMES the colliding path ($n33)" \
    "grep -Fq '$n33' '$r33.out'"
  i33=$((i33 + 1))
done
check "33. the accented file survives byte-identical"  "[ \"\$(cksum <'$r33/$N33_2')\" = '$SUM33_2' ]"
check "33. the CJK file survives byte-identical"       "[ \"\$(cksum <'$r33/$N33_3')\" = '$SUM33_3' ]"
check "33. the spaced file survives byte-identical"    "[ \"\$(cksum <'$r33/$N33_4')\" = '$SUM33_4' ]"
check "33. the quoted file survives byte-identical"    "[ \"\$(cksum <'$r33/$N33_5')\" = '$SUM33_5' ]"
check "33. the backslashed file survives byte-identical" "[ \"\$(cksum <'$r33/$N33_6')\" = '$SUM33_6' ]"
check "33. the ASCII file survives byte-identical"     "[ \"\$(cksum <'$r33/$N33_1')\" = '$SUM33_1' ]"
check "33. no C-quoted escape sequence is ever shown to the captain" \
  "! grep -q '\\\\303' '$r33.out'"
check "33. state.json survives quotes and backslashes in a path (valid JSON)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M33/state.json'"

# --- Behaviour 34 (R3 D2): a base merely AHEAD of origin is CURRENT, silently -
# The most ordinary state there is — one unpushed local commit. It was called
# `stale`, loudly, with `behindBy: 0` in the same record, and a `git pull
# --rebase` fix that is a literal no-op, so re-filing reproduced it forever.
r34="$(make_fixture b34)"
( cd "$r34" && printf 'local work\n' >local.txt && git add -A \
    && git commit -q -m "local work not yet pushed" ) >/dev/null 2>&1
BEFORE_MAIN34="$(git -C "$r34" rev-parse refs/heads/main)"
prd34="$TMPROOT/prd34.md"; write_prd "$prd34"
file_mission "$r34" --prd "$prd34"
M34="$(mdir "$r34")"
check "34. filing succeeds with an unpushed commit"  "[ \"\$(cat '$r34.rc')\" = '0' ]"
check "34. verdict is 'current' — the base has everything origin has" \
  "[ \"\$(sf '$M34/state.json' baseFreshness.verdict)\" = 'current' ]"
check "34. …and it is SILENT"                         "loud_is '$M34/state.json' False"
check "34. NO warning block is printed"               "! grep -q 'BASE FRESHNESS' '$r34.out'"
check "34. the record does not contradict itself: behindBy 0 and not stale" \
  "[ \"\$(sf '$M34/state.json' baseFreshness.behindBy)\" = '0' ]"
check "34. aheadBy records the unpushed commit (1)" \
  "[ \"\$(sf '$M34/state.json' baseFreshness.aheadBy)\" = '1' ]"
check "34. the unpushed commit is NOT touched (main unmoved)" \
  "[ \"\$(git -C '$r34' rev-parse refs/heads/main)\" = '$BEFORE_MAIN34' ]"
check "34. nothing claims the base is out of date" \
  "! grep -q 'is out of date' '$r34.out'"
check "34. no no-op fix is prescribed"                "[ -z \"\$(sf '$M34/state.json' baseFreshness.fix)\" ]"

# --- Behaviour 35 (R3 D2): a GENUINELY diverged base is stale, and its fix ----
# ---            actually CLEARS the condition when you run it -----------------
r35="$(make_fixture b35)"
advance_origin b35 3
(
  cd "$r35"
  printf 'mine 1\n' >mine1.txt && git add -A && git commit -q -m "local commit 1"
  printf 'mine 2\n' >mine2.txt && git add -A && git commit -q -m "local commit 2"
) >/dev/null 2>&1
R35FIX="$TMPROOT/b35.fixrun"
rm -rf "$R35FIX"; cp -R "$r35" "$R35FIX"      # pristine copy, taken BEFORE filing
prd35="$TMPROOT/prd35.md"; write_prd "$prd35"
file_mission "$r35" --prd "$prd35"
M35="$(mdir "$r35")"
check "35. a genuinely diverged base is 'stale'" \
  "[ \"\$(sf '$M35/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "35. …and loud"                                "loud_is '$M35/state.json' True"
check "35. behindBy is the real distance (3)"        "[ \"\$(sf '$M35/state.json' baseFreshness.behindBy)\" = '3' ]"
check "35. aheadBy is the real distance (2)"         "[ \"\$(sf '$M35/state.json' baseFreshness.aheadBy)\" = '2' ]"
check "35. the reason names the divergence" \
  "reason_has '$M35/state.json' 'a fast-forward is impossible'"
# RUN the exact command the block printed, then re-file: it has to end the
# warning, not reproduce it.
FIX35="$(sf "$M35/state.json" baseFreshness.fix)"
CMD35="${FIX35%%   *}"
check "35. the printed fix is a real reconciliation command" \
  "[ -n '$CMD35' ] && case '$CMD35' in git*) true ;; *) false ;; esac"
FIXRC35=0
( cd "$R35FIX" && eval "$CMD35" ) >"$TMPROOT/b35.fix.out" 2>&1 || FIXRC35=$?
check "35. the printed fix RUNS clean on the very fixture that produced it" \
  "[ '$FIXRC35' -eq 0 ]"
file_mission "$R35FIX" --prd "$prd35"
M35F="$(mdir "$R35FIX")"
check "35. …and re-filing afterwards is CLEAN, not the same warning again" \
  "[ \"\$(sf '$M35F/state.json' baseFreshness.verdict)\" = 'current' ]"
check "35. …with no warning block at all"            "! grep -q 'BASE FRESHNESS' '$R35FIX.out'"

# --- Behaviour 36 (R3 D3): the no-trunk fix is a command that can SUCCEED -----
# The fixture that produces this verdict is a fresh repo whose origin is EMPTY,
# and on it every substitution of the old `git remote set-head origin …` errors:
# set-head needs refs/remotes/origin/<name> to exist locally, and it never does.
BARE36="$TMPROOT/b36.git"; git init -q --bare "$BARE36" 2>/dev/null
r36="$TMPROOT/b36"
mkdir -p "$r36"
(
  cd "$r36" && git init -q && git config user.email t@t && git config user.name t \
    && git checkout -q -b main && echo seed >README.md && git add -A \
    && git commit -q -m init && git remote add origin "$BARE36"
) >/dev/null 2>&1
scaffold_lcars "$r36"
R36FIX="$TMPROOT/b36.fixrun"
rm -rf "$R36FIX"; cp -R "$r36" "$R36FIX"      # pristine copy, taken BEFORE filing
# Evidence the RETIRED fix really was unrunnable, on this exact state.
OLD36A="$TMPROOT/b36.old-a"; rm -rf "$OLD36A"; cp -R "$r36" "$OLD36A"
OLDRC36A=0; ( cd "$OLD36A" && git remote set-head origin main ) >/dev/null 2>&1 || OLDRC36A=$?
OLDRC36B=0; ( cd "$OLD36A" && git remote set-head origin --auto ) >/dev/null 2>&1 || OLDRC36B=$?
check "36. the retired 'set-head <name>' fix really does fail here" "[ '$OLDRC36A' -ne 0 ]"
check "36. …and so does 'set-head --auto'"                          "[ '$OLDRC36B' -ne 0 ]"
prd36="$TMPROOT/prd36.md"; write_prd "$prd36"
file_mission "$r36" --prd "$prd36"
M36="$(mdir "$r36")"
check "36. filing succeeds against an empty origin"  "[ \"\$(cat '$r36.rc')\" = '0' ]"
check "36. verdict is 'unknown'"                     "[ \"\$(sf '$M36/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "36. …and the reason names the unresolvable trunk" \
  "reason_has '$M36/state.json' 'DEFAULT branch could not be resolved'"
check "36. the unrunnable set-head command is NOT offered any more" \
  "! grep -q 'set-head' '$r36.out'"
FIX36="$(sf "$M36/state.json" baseFreshness.fix)"
CMD36="${FIX36%%   *}"
FIXRC36=0
( cd "$R36FIX" && eval "$CMD36" ) >"$TMPROOT/b36.fix.out" 2>&1 || FIXRC36=$?
check "36. the printed fix RUNS clean on the very fixture that produced it" \
  "[ '$FIXRC36' -eq 0 ]"
file_mission "$R36FIX" --prd "$prd36"
M36F="$(mdir "$R36FIX")"
check "36. …and re-filing afterwards gives a CLEAN verdict" \
  "[ \"\$(sf '$M36F/state.json' baseFreshness.verdict)\" = 'current' ]"
check "36. …with no warning block at all"            "! grep -q 'BASE FRESHNESS' '$R36FIX.out'"
# The empty-remote path asked origin the SAME question twice — once from the
# failed fetch's probe, once from the trunk resolver, whose own comment claims it
# "never costs a second network call".
check "36. origin is asked what it has exactly ONCE" \
  "[ \"\$(grep -c 'asking origin what it has' '$r36.out')\" = '1' ]"

# --- Behaviour 37 (R3 D4): baseSha never SUBSTITUTES HEAD for a missing base --
# `behindBy` is null rather than a reassuring 0 when nothing was measured; a
# baseSha that quietly reports HEAD when there is no local base branch is the
# same lie, and a consumer cannot detect it.
HEAD19="$(git -C "$r19" rev-parse HEAD)"
check "37. no local base ⇒ baseSha is null, not HEAD" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"baseSha\"] is None else 1)' '$M19/state.json'"
check "37. …and it is certainly not HEAD's sha" \
  "[ \"\$(sf '$M19/state.json' baseFreshness.baseSha)\" != '$HEAD19' ]"
check "37. a base that DOES exist still records its real sha" \
  "[ -n \"\$(sf '$M1/state.json' baseFreshness.baseSha)\" ]"

# --- Behaviour 38 (R3, honesty): no copy asserts a branch that exists NOWHERE -
# A detached HEAD in a `master`-only repo: file.sh's pre-existing fallback makes
# BASE the literal string `main`, and the block then talked about whether 'main'
# was out of date — a branch that exists neither locally nor on origin.
BARE38="$TMPROOT/b38.git"; git init -q --bare "$BARE38" 2>/dev/null
(
  cd "$TMPROOT" && git init -q b38.seed && cd b38.seed \
    && git config user.email t@t && git config user.name t \
    && git checkout -q -b master && echo seed >README.md && git add -A \
    && git commit -q -m init && git remote add origin "$BARE38" \
    && git push -q -u origin master
) >/dev/null 2>&1
git -C "$BARE38" symbolic-ref HEAD refs/heads/master
r38="$TMPROOT/b38"
git clone -q "$BARE38" "$r38" 2>/dev/null
( cd "$r38" && git config user.email t@t && git config user.name t \
    && git checkout -q --detach ) >/dev/null 2>&1
scaffold_lcars "$r38"
prd38="$TMPROOT/prd38.md"; write_prd "$prd38"
file_mission "$r38" --prd "$prd38"
M38="$(mdir "$r38")"
check "38. filing succeeds in a master-only repo on a detached HEAD" \
  "[ \"\$(cat '$r38.rc')\" = '0' ]"
check "38. verdict is 'unknown'"                     "[ \"\$(sf '$M38/state.json' baseFreshness.verdict)\" = 'unknown' ]"
check "38. the block does NOT talk about whether the invented 'main' is out of date" \
  "! grep -q \"'main' is out of date\" '$r38.out'"
check "38. …it says outright that there is no such local branch" \
  "grep -q \"no local branch named 'main'\" '$r38.out'"
check "38. baseSha is null — there is no 'main' to have a sha" \
  "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"baseFreshness\"][\"baseSha\"] is None else 1)' '$M38/state.json'"
check "38. the reason still names the real situation" \
  "reason_has '$M38/state.json' \"there is no local 'main' branch\""
check "38. …and the honest header reaches behaviour 19's repo too" \
  "grep -q \"no local branch named 'main'\" '$r19.out'"

# --- Behaviour 39 (R3): aheadBy obeys the same doctrine as behindBy ----------
for pair39 in "$M1|updated|int" "$M2|stale(dirty)|int" "$M3|stale(diverged)|int" \
              "$M4|unknown(no-remote)|null" "$M5|unknown(unreachable)|null" \
              "$M10|current(unpushed)|int" "$M12|stale(behind-trunk)|int" \
              "$M34|current(ahead-only)|int" "$M35|stale(diverged)|int"; do
  d39="$(printf '%s' "$pair39" | cut -d'|' -f1)"
  v39="$(printf '%s' "$pair39" | cut -d'|' -f2)"
  k39="$(printf '%s' "$pair39" | cut -d'|' -f3)"
  if [ "$k39" = "int" ]; then
    check "39. $v39: aheadBy is a MEASURED int" \
      "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if isinstance(f[\"aheadBy\"],int) else 1)' '$d39/state.json'"
  else
    check "39. $v39: aheadBy is null (it was never measured)" \
      "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"baseFreshness\"]; sys.exit(0 if f[\"aheadBy\"] is None else 1)' '$d39/state.json'"
  fi
done
check "39. a consumer can tell 0-behind/1-ahead from 3-behind/2-ahead" \
  "[ \"\$(sf '$M34/state.json' baseFreshness.behindBy)\" = '0' ] \
   && [ \"\$(sf '$M34/state.json' baseFreshness.aheadBy)\" = '1' ] \
   && [ \"\$(sf '$M35/state.json' baseFreshness.behindBy)\" = '3' ] \
   && [ \"\$(sf '$M35/state.json' baseFreshness.aheadBy)\" = '2' ]"

# ==========================================================================
# ROUND 4 — four defects a FOURTH fresh captain-stand-in tester found once the
# whole scenario matrix and every structural property already held: a printed
# fix that cannot run, a record that does not parse, an announced bound that is
# not the bound, and documentation that denies what the code does.
# ==========================================================================

# --- Behaviour 40 (R4 D1): the no-commits fix names the branch git will CREATE
# A repo with NO COMMITS whose origin is EMPTY. `git rev-parse --abbrev-ref HEAD`
# FAILS on an unborn HEAD, so file.sh falls back to the literal string `main` —
# but the branch the captain's first commit will actually land on is whatever
# `init.defaultBranch` says, and git's stock default is `master`. So the printed
# fix said `git push -u origin main`, and obeying it errors outright:
#   error: src refspec main does not match any
# `git symbolic-ref --short HEAD` DOES answer on an unborn HEAD, so the fix can
# name the branch the captain is really on.
BARE40="$TMPROOT/b40.git"; git init -q --bare "$BARE40" 2>/dev/null
r40="$TMPROOT/b40"
# `-b master` PINS the unborn name regardless of this machine's config — Apple's
# CLT gitconfig ships `init.defaultbranch=main`, which would hide the defect
# entirely on the very machine the tester ran on.
git init -q -b master "$r40" 2>/dev/null || {
  mkdir -p "$r40"
  ( cd "$r40" && git init -q && git symbolic-ref HEAD refs/heads/master ) >/dev/null 2>&1
}
( cd "$r40" && git config user.email t@t && git config user.name t \
    && git remote add origin "$BARE40" ) >/dev/null 2>&1
scaffold_lcars "$r40"
check "40. the fixture is genuinely unborn-on-master (the defect's precondition)" \
  "[ \"\$(git -C '$r40' symbolic-ref --short HEAD)\" = 'master' ] \
   && ! git -C '$r40' rev-parse --verify -q HEAD >/dev/null 2>&1"
R40FIX="$TMPROOT/b40.fixrun"; rm -rf "$R40FIX"; cp -R "$r40" "$R40FIX"
prd40="$TMPROOT/prd40.md"; write_prd "$prd40"
file_mission "$r40" --prd "$prd40"
M40="$(mdir "$r40")"
check "40. filing succeeds with no commits and an empty origin" \
  "[ \"\$(cat '$r40.rc')\" = '0' ]"
FIX40="$(sf "$M40/state.json" baseFreshness.fix)"
check "40. the fix names the branch git will really create" \
  "case \"\$FIX40\" in *'origin master'*) true ;; *) false ;; esac"
check "40. …and never the invented 'main', which cannot be pushed" \
  "case \"\$FIX40\" in *'origin main'*) false ;; *) true ;; esac"
# Obey the printed fix VERBATIM on a pristine copy: the captain's own first
# commit, then the push command exactly as printed.
PUSH40="$(printf '%s' "$FIX40" | grep -oE 'git push -u origin [^ ]+' | head -1)"
check "40. the fix really does carry a push command to run" "[ -n \"\$PUSH40\" ]"
FIXRC40=0
(
  cd "$R40FIX" && echo hi >README.md && git add -A \
    && git commit -q -m "first commit" && eval "$PUSH40"
) >"$TMPROOT/b40.fix.out" 2>&1 || FIXRC40=$?
check "40. the printed fix RUNS clean on the very fixture that produced it" \
  "[ '$FIXRC40' -eq 0 ]"
file_mission "$R40FIX" --prd "$prd40"
M40F="$(mdir "$R40FIX")"
check "40. …and re-filing afterwards gives a CLEAN verdict" \
  "[ \"\$(sf '$M40F/state.json' baseFreshness.verdict)\" = 'current' ]"
check "40. …with no warning block at all" "! grep -q 'BASE FRESHNESS' '$R40FIX.out'"
# Cosmetic, same fixture: the readout printed `(off main)` two lines under
# "repo has no commits yet — branch … not created", naming a local `main` that
# exists nowhere.
check "40. the readout does not claim the branch was cut off a 'main' that does not exist" \
  "! grep -q '(off main)' '$r40.out'"
check "40. …it names the unborn branch HEAD is actually on" \
  "grep -q '(off master' '$r40.out'"

# --- Behaviour 41 (R4 D2): an awkward collider path still yields VALID JSON ---
# `state.json` is the record SKILL.md documents as consumable and that S159/S160
# are specified to read: it must ALWAYS parse. A gitignored collider whose name
# holds a raw 0x01 put that byte into `baseFreshness.reason` verbatim, and
# `python3 -m json.tool` refused the file ("Invalid control character").
# The SMELL alongside it: a collider whose name holds a NEWLINE was flattened to
# a space by `tr '\n' ' '`, making it indistinguishable from a genuine space in
# a name (and from two separate files).
CTL41="$(printf '\001')"
N41_CTL="dist/ctl${CTL41}name.txt"
NL41=$'\n'
N41_NL="dist/two${NL41}line.txt"
r41="$(make_fixture b41)"
(
  cd "$TMPROOT/b41.seed"
  printf 'dist/\n' >.gitignore
  git add -A && git commit -q -m "ignore dist"
  git push -q origin main
) >/dev/null 2>&1
( cd "$r41" && git pull -q --ff-only origin main ) >/dev/null 2>&1
mkdir -p "$r41/dist"
printf 'IRREPLACEABLE LOCAL DATA\n' >"$r41/$N41_CTL"
printf 'IRREPLACEABLE LOCAL DATA\n' >"$r41/$N41_NL"
SUM41C="$(cksum <"$r41/$N41_CTL")"; SUM41N="$(cksum <"$r41/$N41_NL")"
(
  cd "$TMPROOT/b41.seed"
  mkdir -p dist
  printf 'UPSTREAM BUILD\n' >"$N41_CTL"
  printf 'UPSTREAM BUILD\n' >"$N41_NL"
  git add -f dist && git commit -q -m "force-add dist files with awkward names"
  git push -q origin main
) >/dev/null 2>&1
BEFORE_MAIN41="$(git -C "$r41" rev-parse refs/heads/main)"
check "41. the trap is real: git status reads CLEAN" \
  "[ -z \"\$(git -C '$r41' status --porcelain)\" ]"
prd41="$TMPROOT/prd41.md"; write_prd "$prd41"
file_mission "$r41" --prd "$prd41"
M41="$(mdir "$r41")"
check "41. filing still succeeds"                  "[ \"\$(cat '$r41.rc')\" = '0' ]"
check "41. the fast-forward is REFUSED (verdict stale)" \
  "[ \"\$(sf '$M41/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "41. NO pull happened (main unmoved)" \
  "[ \"\$(git -C '$r41' rev-parse refs/heads/main)\" = '$BEFORE_MAIN41' ]"
check "41. the control-char file survives byte-identical" \
  "[ \"\$(cksum <'$r41/$N41_CTL')\" = '$SUM41C' ]"
check "41. the newline file survives byte-identical" \
  "[ \"\$(cksum <'$r41/$N41_NL')\" = '$SUM41N' ]"
# THE DEFECT: the record must parse. `python3 -m json.tool` is the tester's
# own reproduction command.
check "41. state.json PARSES (python3 -m json.tool), control character and all" \
  "python3 -m json.tool '$M41/state.json' >/dev/null 2>&1"
check "41. …and no raw control byte is embedded in the record at all" \
  "! LC_ALL=C grep -q \"\$(printf '\\001')\" '$M41/state.json'"
# THE SMELL: both awkward names are rendered so a human can tell what they are.
check "41. the refusal shows the control byte VISIBLY, not as an invisible glyph" \
  "grep -Fq 'dist/ctl\\x01name.txt' '$r41.out'"
check "41. …and the newline path is rendered, not flattened to a space" \
  "grep -Fq 'dist/two\\nline.txt' '$r41.out'"
check "41. …so it can no longer be misread as a genuine space in the name" \
  "! grep -Fq 'dist/two line.txt' '$r41.out'"
check "41. …and each colliding path is delimited, so a space in a name is unambiguous" \
  "[ \"\$(grep -o \"'dist/\" '$r41.out' | wc -l | tr -d ' ')\" = '2' ]"
# The ESCAPER itself, driven directly: ANY control character in ANY recorded
# sentence must come out as valid JSON, not only the ones a collider produces.
# `_lcars_base_json` stripped \n\r\t and escaped only \ and " — every other
# control byte went in verbatim. Its sibling `lcars_json_escape`, in the same
# file, already maps them all to \u00XX.
UNIT41="$TMPROOT/b41.unit.json"
(
  . "$COMMON"
  LCARS_BASE_BRANCH="main"
  LCARS_BASE_VERDICT="stale"; LCARS_BASE_LOUD=1
  LCARS_BASE_REASON="ctl$(printf '\001')name and a \"quote\" and a \\ backslash"
  LCARS_BASE_FIX="fix$(printf '\002')me"
  LCARS_BASE_CHECKED_AT="2026-05-30T00:00:00Z"
  LCARS_BASE_BEHIND=1; LCARS_BASE_AHEAD=0; LCARS_BASE_SHA=""
  printf '{\n'
  lcars_base_state_line | sed 's/,$//'
  printf '\n}\n'
) >"$UNIT41" 2>/dev/null
cat >"$TMPROOT/ctl41.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["baseFreshness"]
sys.exit(0 if "\u0001" in d["reason"] and "\u0002" in d["fix"]
         and '"' in d["reason"] and "\\" in d["reason"] else 1)
PY
check "41. the state-line escaper survives a raw control character (valid JSON)" \
  "python3 -m json.tool '$UNIT41' >/dev/null 2>&1"
check "41. …preserving the byte as an escape rather than dropping it, quotes and backslashes intact" \
  "python3 '$TMPROOT/ctl41.py' '$UNIT41'"
check "41. …and the record is still exactly ONE line (run.sh's editors are line-oriented)" \
  "[ \"\$(grep -c baseFreshness '$UNIT41')\" = '1' ] \
   && [ \"\$(wc -l <'$UNIT41' | tr -d ' ')\" = '3' ]"

# --- Behaviour 42 (R4 D3): the ANNOUNCED bound is the bound HONOURED ---------
# `_lcars_base_run_bounded` silently sanitises a non-numeric bound to 8, but the
# announcement echoed the raw env var: `(up to abcs)…` over a call that really
# stopped at 8s. A stated bound that is not the bound is a lie the captain has no
# way to catch.
r42="$(make_fixture b42)"
advance_origin b42 1
OUT42="$TMPROOT/b42.out"
T42="$SECONDS"
( cd "$r42" && LCARS_GIT_BIN="$HANG_GIT" LCARS_BASE_FETCH_TIMEOUT_SECS=abc \
    bash -c ". '$COMMON'; ensure_base_current main" ) >"$OUT42" 2>&1
EL42=$((SECONDS - T42))
check "42. junk in LCARS_BASE_FETCH_TIMEOUT_SECS never reaches the captain's eyes" \
  "! grep -q 'up to abcs' '$OUT42'"
check "42. …the announcement states the real (sanitised) bound instead" \
  "head -1 '$OUT42' | grep -q 'up to 8s'"
check "42. …and the stated bound is the one actually honoured" \
  "[ '$EL42' -ge 6 ] && [ '$EL42' -lt 25 ]"
check "42. a VALID bound is still announced verbatim (behaviour 14/23 unbroken)" \
  "head -1 '$OUT14' | grep -q 'up to 2s'"

# --- Behaviour 43 (R4 D4): SKILL.md does not deny the merge it performs -------
# The git-verb audit confirms `git merge --ff-only <sha>` really is run, and
# SKILL.md itself describes it four bullets earlier — then the "clone is sacred"
# sentence claimed it "never … merges". No merge commit can ever be created, so
# the BEHAVIOUR is safe; the SENTENCE is not. CONTEXT.md says "rebases" and is
# correct.
SKILLMD43="$REPO_ROOT/skills/lcars-file/SKILL.md"
SACRED43="$(grep -A3 "clone is sacred" "$SKILLMD43" | tr '\n' ' ')"
check "43. the sacred-clone sentence was found at all" \
  "[ -n \"\$SACRED43\" ]"
check "43. it no longer claims the guard never MERGES" \
  "case \"\$SACRED43\" in *' merges,'*) false ;; *) true ;; esac"
check "43. …it lists 'rebases', exactly as CONTEXT.md does" \
  "case \"\$SACRED43\" in *rebases*) true ;; *) false ;; esac"
check "43. …and names the one merge it does make as fast-forward-only" \
  "case \"\$SACRED43\" in *fast-forward-only*) true ;; *) false ;; esac"
check "43. CONTEXT.md's honest verb list is what it is being aligned to" \
  "grep -q 'never resets, forces, stashes, rebases' '$REPO_ROOT/CONTEXT.md'"
check "43. …while the source demonstrably DOES run a fast-forward-only merge" \
  "grep -q '\"[\$]g\" merge --ff-only' '$BODY11'"
check "43. the true statement about topic branches is untouched" \
  "grep -q 'never merges a trunk into a topic branch' '$SKILLMD43'"

# --- Behaviour 44 (R5 D1): a colliding path holding the DELIMITER ITSELF ------
# `_lcars_base_render_paths` wraps each path in single quotes precisely so that
# `a b.txt` cannot be misread as the two files `a` and `b.txt`. It escaped `\`,
# `"` and control characters — but not `'`, the delimiter it uses. So the two
# colliders `dist/it's.txt` and `dist/plain.txt` rendered as
#     'dist/it's.txt' 'dist/plain.txt'
# which reads just as well as `dist/it` + `s.txt'` — the exact ambiguity the
# quoting exists to close. The files ARE protected and named and the JSON IS
# valid; only the rendering is ambiguous.
APO44="dist/it's.txt"
PLAIN44="dist/plain.txt"
r44="$(make_fixture b44)"
(
  cd "$TMPROOT/b44.seed"
  printf 'dist/\n' >.gitignore
  git add -A && git commit -q -m "ignore dist"
  git push -q origin main
) >/dev/null 2>&1
( cd "$r44" && git pull -q --ff-only origin main ) >/dev/null 2>&1
mkdir -p "$r44/dist"
printf 'IRREPLACEABLE LOCAL DATA\n' >"$r44/$APO44"
printf 'IRREPLACEABLE LOCAL DATA\n' >"$r44/$PLAIN44"
SUM44A="$(cksum <"$r44/$APO44")"; SUM44P="$(cksum <"$r44/$PLAIN44")"
(
  cd "$TMPROOT/b44.seed"
  mkdir -p dist
  printf 'UPSTREAM BUILD\n' >"$APO44"
  printf 'UPSTREAM BUILD\n' >"$PLAIN44"
  git add -f dist && git commit -q -m "force-add dist files"
  git push -q origin main
) >/dev/null 2>&1
BEFORE_MAIN44="$(git -C "$r44" rev-parse refs/heads/main)"
check "44. the trap is real: git status reads CLEAN" \
  "[ -z \"\$(git -C '$r44' status --porcelain)\" ]"
prd44="$TMPROOT/prd44.md"; write_prd "$prd44"
file_mission "$r44" --prd "$prd44"
M44="$(mdir "$r44")"
check "44. filing still succeeds"                  "[ \"\$(cat '$r44.rc')\" = '0' ]"
check "44. the fast-forward is REFUSED (verdict stale)" \
  "[ \"\$(sf '$M44/state.json' baseFreshness.verdict)\" = 'stale' ]"
check "44. NO pull happened (main unmoved)" \
  "[ \"\$(git -C '$r44' rev-parse refs/heads/main)\" = '$BEFORE_MAIN44' ]"
AP44PATH="$r44/$APO44"
check "44. the apostrophe file survives byte-identical" \
  "[ \"\$(cksum <\"\$AP44PATH\")\" = '$SUM44A' ]"
check "44. the plain sibling survives byte-identical" \
  "[ \"\$(cksum <'$r44/$PLAIN44')\" = '$SUM44P' ]"
check "44. state.json is still valid JSON"         "python3 -m json.tool '$M44/state.json' >/dev/null 2>&1"
# THE DEFECT: the delimiter inside the name must be escaped, not left bare.
ESC44="dist/it'\\''s.txt"
check "44. the delimiter inside the name is escaped for the captain" \
  "grep -Fq \"\$ESC44\" '$r44.out'"
check "44. …so the bare, ambiguous rendering is gone" \
  "! grep -Fq \"'dist/it's.txt'\" '$r44.out'"
check "44. both colliding paths are still named in the refusal" \
  "grep -Fq \"'dist/plain.txt'\" '$r44.out' && grep -Fq 'dist/it' '$r44.out'"
# The renderer, driven directly: "unambiguous" means the rendered list splits
# back into EXACTLY the paths that went in — nothing else is proof.
cat >"$TMPROOT/roundtrip44.sh" <<'SH'
#!/usr/bin/env bash
# roundtrip44.sh <rendered-list> <expected-path…> — the rendered list is only
# unambiguous if a reader splitting it on its own delimiters recovers exactly
# the paths that went in.
rendered="$1"; shift
exp_n=$#
expected=""
for e in "$@"; do expected="$expected$e"$'\034'; done
eval "set -- $rendered" 2>/dev/null || exit 1
[ "$#" -eq "$exp_n" ] || exit 1
got=""
for g in "$@"; do got="$got$g"$'\034'; done
[ "$got" = "$expected" ] || exit 1
exit 0
SH
REND44="$( . "$COMMON" >/dev/null 2>&1; _lcars_base_render_paths "$(printf '%s\n%s\n' "$APO44" "$PLAIN44")" )"
check "44. the rendered list re-parses to EXACTLY the two original paths" \
  "bash '$TMPROOT/roundtrip44.sh' \"\$REND44\" \"\$APO44\" \"\$PLAIN44\""
# …and the names behaviours 33/41 already protect must not regress: `\` and `"`
# stay VERBATIM so the captain can compare the warning against their own `ls`.
BS44='build/back\slash.txt'; QT44='build/quo"te.txt'; SP44='build/a b.txt'
REND44B="$( . "$COMMON" >/dev/null 2>&1; _lcars_base_render_paths "$(printf '%s\n%s\n%s\n' "$BS44" "$QT44" "$SP44")" )"
printf '%s' "$REND44B" >"$TMPROOT/rend44b.txt"
check "44. …backslash / quote / space paths still re-parse verbatim (33 intact)" \
  "bash '$TMPROOT/roundtrip44.sh' \"\$REND44B\" \"\$BS44\" \"\$QT44\" \"\$SP44\""
check "44. …and the backslash path is shown exactly as 'ls' shows it" \
  "grep -Fq 'build/back\\slash.txt' '$TMPROOT/rend44b.txt'"
check "44. …and the quoted path is shown exactly as 'ls' shows it" \
  "grep -Fq 'build/quo\"te.txt' '$TMPROOT/rend44b.txt'"

# --- Behaviour 45 (R5 D2): a comment may not assert a consumer that is unbuilt -
# The source claimed state.json is "the record … that `lcars run`'s re-check
# reads". Nothing reads `baseFreshness` anywhere: S159 (the drive-time re-check)
# and S160 (the board badge) are UNBUILT. file.sh gets this right — "Today
# `lcars file` is its only consumer" — and this round has paid repeatedly for
# prose claiming more than the machine does. A comment is not exempt.
READERS45="$TMPROOT/readers45.txt"
grep -rl 'baseFreshness' "$REPO_ROOT/skills" >"$READERS45" 2>/dev/null
check "45. the only files mentioning baseFreshness are its writer and its doc" \
  "! grep -v -e 'lcars-init/lcars-common.sh\$' -e 'lcars-file/SKILL.md\$' '$READERS45' | grep -q ."
check "45. …so no comment claims lcars run's re-check reads it today" \
  "! grep -q \"re-check reads\" '$COMMON'"
check "45. …and the unbuilt sessions are NAMED rather than asserted as present" \
  "grep -q 'S159' '$COMMON' && grep -q 'S160' '$COMMON'"
check "45. file.sh's honest phrasing (the model for it) is untouched" \
  "grep -q 'Today .lcars file. is its only consumer' '$REPO_ROOT/skills/lcars-file/file.sh'"

# --- Behaviour 46 (R5 D3): the cross-reference between the two docs is TRUE ---
# SKILL.md said its sacred-clone verb list is "the same verb list `CONTEXT.md`
# gives". It listed seven verbs (adding *cleans* and *switches*); CONTEXT.md
# listed five. Both sentences were individually true about the behaviour — only
# the claim that they MATCH was false. Neither list may be weakened to fix it.
verb_list_of() { tr '\n' ' ' <"$1" | tr -s ' ' | grep -o 'never resets[a-z, ]*checks anything out' | head -1; }
VERBS_CTX46="$(verb_list_of "$REPO_ROOT/CONTEXT.md")"
VERBS_SKILL46="$(verb_list_of "$SKILLMD43")"
check "46. CONTEXT.md's verb list was found"       "[ -n \"\$VERBS_CTX46\" ]"
check "46. SKILL.md's verb list was found"         "[ -n \"\$VERBS_SKILL46\" ]"
check "46. …and the two are now genuinely the SAME list, verb for verb" \
  "[ \"\$VERBS_CTX46\" = \"\$VERBS_SKILL46\" ]"
for v46 in resets forces stashes cleans rebases switches; do
  check "46. neither list was weakened — '$v46' is in both" \
    "case \"\$VERBS_CTX46\" in *$v46*) case \"\$VERBS_SKILL46\" in *$v46*) true ;; *) false ;; esac ;; *) false ;; esac"
done

# ==========================================================================
# CONSOLIDATION — the vocabulary is a DECLARATION, and the source is held to it.
# It used to be fifteen names, each with its own bespoke Why/Means/Fix prose; two
# tester rounds found eleven defects and every one of them was either a wrong git
# decision or copy that lied about one. These checks read the SOURCE, so a
# sixteenth situation cannot quietly grow a sixteenth name (or a silent one).
# ==========================================================================
SETS32="$TMPROOT/base-set-calls"
grep -oE '_lcars_base_set [a-z-]+ [0-9]' "$BODY11" >"$SETS32"
check "32. every outcome really does go through _lcars_base_set" \
  "[ \"\$(wc -l <'$SETS32' | tr -d ' ')\" -ge 10 ]"
check "32. …and every verdict it can ever emit is one of the four" \
  "! awk '{print \$2}' '$SETS32' | grep -qvE '^(current|updated|stale|unknown)\$'"
check "32. …and every one of them carries an EXPLICIT loudness (0 or 1)" \
  "! awk '{print \$3}' '$SETS32' | grep -qvE '^[01]\$'"
check "32. all four verdicts are actually reachable (none is dead vocabulary)" \
  "for v in current updated stale unknown; do awk '{print \$2}' '$SETS32' | grep -qx \"\$v\" || exit 1; done"
# Loudness must not be inferable from the verdict: `unknown` has to appear BOTH
# quiet (the everyday no-remote repo) and loud (an unreachable origin), or a
# consumer would be free to derive the badge from the verdict and be right by
# accident until the day it changed.
check "32. 'unknown' is emitted both quietly and loudly" \
  "grep -q '_lcars_base_set unknown 0' '$BODY11' && grep -q '_lcars_base_set unknown 1' '$BODY11'"
# …and the product agrees with the source: two `unknown` missions from this run,
# one silent, one shouting.
check "32. …and the product proves it: no-remote is quiet, unreachable is loud" \
  "loud_is '$M4/state.json' False && loud_is '$M5/state.json' True"
check "32. the retired 15-name vocabulary is gone from the source entirely" \
  "! grep -oE '_lcars_base_set [a-z-]+' '$BODY11' | grep -qE 'no-remote|no-upstream|already-current|disabled|no-repo|dirty|diverged|unreachable|fetch-timeout|ff-failed|not-checked-out|no-base|behind-trunk|would-clobber|no-trunk'"
# The per-verdict `Means:` prose is retired for ONE constant sentence: a sentence
# that does not vary cannot describe the wrong situation.
check "32. the ⚠ block's consequence line is a single constant, not per-verdict prose" \
  "[ \"\$(grep -c 'LCARS_BASE_IMPACT=' '$BODY11')\" = '1' ]"
check "32. …and it is what the captain actually sees" \
  "grep -q 'Impact:' '$r3.out'"

# ==========================================================================
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
