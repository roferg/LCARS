#!/usr/bin/env bash
#
# Tests for the CLONE-UNIQUE MISSION ID — Session 196, Half A, leg 4.
#
# Skill sources under test:
#   skills/lcars-init/lcars-common.sh   lcars_clone_id / lcars_clone_fingerprint
#                                       / lcars_mint_mission_id  (the ONE minter)
#   skills/lcars-file/file.sh           both filing lanes' mint sites
#   skills/lcars-log/log.sh             the bug-log mint site
#   skills/lcars-init/init.sh           seeds cloneId into config.json
#   skills/lcars-update/update.sh       backfills cloneId into an older config
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (ground truth, measured in S191's live two-laptop capstone)
# ---------------------------------------------------------------------------
# Mission ids were `lcars-YYYYMMDD-NNN` with NNN counted INSIDE ONE CLONE. That
# id is simultaneously the mission DIRECTORY the CLI addresses, the git BRANCH
# `lcars/<id>` on the SHARED remote, and (before S196) adopt's lookup key. Two
# laptops filing against one repo on one day minted the IDENTICAL id; adopting
# the colliding issue reused a MERGED branch and overwrote a shipped mission.
#
# The captain UNFROZE the id format on 2026-09-09 and chose to WIDEN THE NAME:
# a short per-clone fingerprint is appended, so the id is
#   lcars-YYYYMMDD-NNN-<fp>          (fp = 4 lowercase hex, per CLONE)
#
# TWO INVARIANTS THIS SUITE PINS, and they matter more than the minting:
#   1. EXISTING IDS ARE NEVER RE-MINTED. Every `lcars-YYYYMMDD-NNN` already on
#      disk must keep resolving, running, rendering and adopting exactly as it
#      did. Nothing migrates.
#   2. THE FINGERPRINT IS PER CLONE, NOT PER MISSION. Two clones differ; one
#      clone is stable across every mission it ever mints.
#
# The refusals leg 1 added to `lcars adopt` (id collision, branch collision)
# STAY — they are the backstop for LEGACY ids minted before this change. This
# suite does not weaken them; tests/lcars-adopt.test.sh proves they still fire.
#
# ZERO MODEL SPEND. `claude` and `copilot` are BOTH faked with PATH shims that
# record every invocation, and the shim counts are asserted to be 0.
#
# Usage: bash tests/mission-id.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$REPO_ROOT/skills/lcars-log/log.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
RESOLVE_SCRIPT="${LCARS_RESOLVE_SCRIPT:-$REPO_ROOT/skills/lcars/resolve.sh}"
COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
UPDATE_SCRIPT="$REPO_ROOT/skills/lcars-update/update.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- state.json / config.json must PARSE ----------------------------------
# S189's suite missed a real corruption because not one check parsed the JSON
# it had just written. Every mutating check here runs the file through
# `json.load` and asserts the fields it cares about, so a syntactically broken
# write can never pass as "the grep found the string".
json_ok() { # <file>
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
}
json_field() { # <file> <key>  → the value, or "" (missing prints nothing)
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
v = d.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))
PY
}

# ==========================================================================
# ZERO-SPEND HARNESS — PATH shims faking BOTH engines
# ==========================================================================
# S159: $LCARS_WORKER_BIN alone does NOT pin the engine (a code path can invoke
# `claude`/`copilot` by bare name). Both names are shadowed on PATH by shims
# that record their argv, and the recorded counts are asserted at the end.
SHIMBIN="$TMPROOT/shimbin"
mkdir -p "$SHIMBIN"
export LCARS_SHIM_LOG="$TMPROOT/worker-invocations.log"
: >"$LCARS_SHIM_LOG"
for eng in claude copilot; do
  cat >"$SHIMBIN/$eng" <<EOF
#!/usr/bin/env bash
echo "$eng \$*" >>"\$LCARS_SHIM_LOG"
exit 0
EOF
  chmod +x "$SHIMBIN/$eng"
done
export PATH="$SHIMBIN:$PATH"

# The estimator driver file.sh shells at the end of Align — stubbed so filing
# completes without a model. (Same stub shape as tests/lcars-file.test.sh.)
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

# A `gh` stub: records argv, and prints a new issue URL on `issue create`.
make_gh_stub() { # <path>
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"${GH_LOG:-/dev/null}"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

write_prd() { # <path> [title]
  cat >"$1" <<EOF
# Mission: ${2:-Fix the broken /about route}

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
- The About page renders its heading
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
}

# An LCARS-initialised repo, with the MULTI-LINE config.json real `lcars init`
# writes (lcars_config_merge emits one key per line). A ONE-LINE config is
# exercised separately in check 4c, because the lazy cloneId write must not be
# the thing that breaks it.
#
# INHERITED (ledgered, NOT cured here): `lcars_config_merge` itself CORRUPTS a
# ONE-LINE config.json — its value-preservation regex captures the rest of the
# LINE, so `lcars update` over the one-line fixture the other suites use emits
# unparseable JSON. Pre-existing, unrelated to the mission id, and out of this
# leg's scope; recorded so the next session does not rediscover it.
seed_lcars() { # <repo>
  mkdir -p "$1/.git/lcars/missions"
  cat >"$1/.git/lcars/config.json" <<'EOF'
{
  "model": "claude-sonnet",
  "projectName": "repo",
  "contextFile": null,
  "testCommand": "true",
  "created": "2026-05-30T00:00:00Z"
}
EOF
  make_gh_stub "$1/gh"
}

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  seed_lcars "$repo"
  echo "$repo"
}

file_one() { # <repo> <prd> <date> ; echoes the minted id
  ( cd "$1" \
      && LCARS_GH_BIN="$1/gh" LCARS_DATE="$3" GH_LOG="$1/gh.log" \
         bash "$FILE_SCRIPT" --prd "$2" >>"$1/out.txt" 2>&1 )
  ls -1 "$1/.git/lcars/missions" 2>/dev/null | grep "^lcars-$3-" | sort | tail -1
}

FP_RE='^lcars-[0-9]{8}-[0-9]{3}-[0-9a-f]{4}$'
is_new_shape() { printf '%s' "$1" | grep -Eq "$FP_RE"; }

echo "mission id — clone-unique fingerprint (S196 A4)"

[ -f "$FILE_SCRIPT" ] || { echo "script under test not found at $FILE_SCRIPT"; exit 1; }

# ==========================================================================
# 1. TWO REAL CLONES OF ONE REPO, SAME DAY → DIFFERENT IDS
# ==========================================================================
# Two genuine `git clone`s of one origin — the fingerprint is NOT mocked, NOT
# injected by env, and NOT derived from the login, the hostname or the repo
# path (both clones share all three). This is the capstone collision, reduced.
ORIGIN="$TMPROOT/origin.git"
SEED="$TMPROOT/seed"
mkdir -p "$SEED"
( cd "$SEED" && git init -q && git config user.email t@t && git config user.name t \
    && echo hi >README.md && git add -A && git commit -q -m init ) >/dev/null 2>&1
git clone -q --bare "$SEED" "$ORIGIN" >/dev/null 2>&1
CLONE_A="$TMPROOT/laptopA"
CLONE_B="$TMPROOT/laptopB"
git clone -q "$ORIGIN" "$CLONE_A" >/dev/null 2>&1
git clone -q "$ORIGIN" "$CLONE_B" >/dev/null 2>&1
for c in "$CLONE_A" "$CLONE_B"; do
  ( cd "$c" && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  seed_lcars "$c"
done
prdA="$CLONE_A/prd.md"; write_prd "$prdA" "Laptop A files first"
prdB="$CLONE_B/prd.md"; write_prd "$prdB" "Laptop B files the same day"
IDA="$(file_one "$CLONE_A" "$prdA" 20260530)"
IDB="$(file_one "$CLONE_B" "$prdB" 20260530)"

check "1. laptop A minted a fingerprinted id (got: '${IDA:-none}')" \
  "is_new_shape '$IDA'"
check "1. laptop B minted a fingerprinted id (got: '${IDB:-none}')" \
  "is_new_shape '$IDB'"
check "1. both are the SAME date and the SAME sequence number (only the fp differs)" \
  "[ \"\$(printf '%s' '$IDA' | sed 's/-[^-]*\$//')\" \
     = \"\$(printf '%s' '$IDB' | sed 's/-[^-]*\$//')\" ] \
   && [ \"\$(printf '%s' '$IDA' | sed 's/-[^-]*\$//')\" = 'lcars-20260530-001' ]"
check "1. TWO CLONES, SAME DAY, DIFFERENT IDS ('$IDA' vs '$IDB')" \
  "[ '$IDA' != '$IDB' ] && [ -n '$IDA' ] && [ -n '$IDB' ]"
check "1. each clone's state.json parses and records its own id" \
  "json_ok '$CLONE_A/.git/lcars/missions/$IDA/state.json' \
   && json_ok '$CLONE_B/.git/lcars/missions/$IDB/state.json' \
   && [ \"\$(json_field '$CLONE_A/.git/lcars/missions/$IDA/state.json' id)\" = '$IDA' ] \
   && [ \"\$(json_field '$CLONE_B/.git/lcars/missions/$IDB/state.json' id)\" = '$IDB' ]"
check "1. the branch each clone cut carries its own id" \
  "[ \"\$(json_field '$CLONE_A/.git/lcars/missions/$IDA/state.json' branch)\" = 'lcars/$IDA' ] \
   && [ \"\$(json_field '$CLONE_B/.git/lcars/missions/$IDB/state.json' branch)\" = 'lcars/$IDB' ]"
check "1. each clone's config.json is still VALID JSON after the lazy write" \
  "json_ok '$CLONE_A/.git/lcars/config.json' && json_ok '$CLONE_B/.git/lcars/config.json'"
check "1. the two clones hold DIFFERENT cloneId values" \
  "[ -n \"\$(json_field '$CLONE_A/.git/lcars/config.json' cloneId)\" ] \
   && [ \"\$(json_field '$CLONE_A/.git/lcars/config.json' cloneId)\" \
        != \"\$(json_field '$CLONE_B/.git/lcars/config.json' cloneId)\" ]"

# ==========================================================================
# 2. ONE CLONE, TWO FILINGS, SAME DAY → NNN INCREMENTS, FP IS STABLE
# ==========================================================================
prdA2="$CLONE_A/prd2.md"; write_prd "$prdA2" "Laptop A files again"
IDA2="$(file_one "$CLONE_A" "$prdA2" 20260530)"
check "2. the second filing is a NEW mission ('$IDA2')" "[ '$IDA2' != '$IDA' ]"
check "2. the sequence incremented 001 → 002" \
  "printf '%s' '$IDA2' | grep -q -- '-002-'"
check "2. the FINGERPRINT is identical across both missions (per CLONE, not per mission)" \
  "[ \"\$(printf '%s' '$IDA'  | sed 's/.*-//')\" = \"\$(printf '%s' '$IDA2' | sed 's/.*-//')\" ]"
check "2. mission 2's state.json parses and is internally consistent" \
  "json_ok '$CLONE_A/.git/lcars/missions/$IDA2/state.json' \
   && [ \"\$(json_field '$CLONE_A/.git/lcars/missions/$IDA2/state.json' id)\" = '$IDA2' ] \
   && [ \"\$(json_field '$CLONE_A/.git/lcars/missions/$IDA2/state.json' stage)\" = 'align' ]"
check "2. mission 1 was NOT touched by mission 2's filing" \
  "[ \"\$(json_field '$CLONE_A/.git/lcars/missions/$IDA/state.json' id)\" = '$IDA' ]"
check "2. the clone's cloneId did not change between filings" \
  "[ \"\$(json_field '$CLONE_A/.git/lcars/config.json' cloneId)\" \
     = \"\$(json_field '$CLONE_A/.git/lcars/config.json' cloneId)\" ] \
   && [ -n \"\$(json_field '$CLONE_A/.git/lcars/config.json' cloneId)\" ]"

# ==========================================================================
# 3. THE COMPATIBILITY GUARANTEE — AN OLD-FORMAT ID STILL WORKS
# ==========================================================================
# `lcars-20260530-001` / `-003`, no fingerprint: exactly what every repo in the
# world already holds. They must resolve, run, be valid log parents, and be
# counted by the minter's sequence scan.
#
# TWO fixtures, because the two probes need different stages and neither may
# cost a token: the `done` one drives `lcars run` into its terminal arm (no
# worker is ever spawned), the `align` one is an ACTIVE mission `lcars log` and
# `resolve.sh` will accept.
OLD="$TMPROOT/oldrepo"
mkdir -p "$OLD"
( cd "$OLD" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
seed_lcars "$OLD"

mk_old_mission() { # <repo> <id> <stage> <issue>
  local d="$1/.git/lcars/missions/$2"
  mkdir -p "$d"
  write_prd "$d/prd.md" "A mission filed before S196"
  cat >"$d/state.json" <<EOF
{
  "id": "$2",
  "title": "A mission filed before S196",
  "type": "bug",
  "stage": "$3",
  "githubIssue": $4,
  "created": "2026-05-30T00:00:00Z",
  "branch": "lcars/$2",
  "base": "main"
}
EOF
}
OLD_DONE="lcars-20260530-001"
OLD_IDLE="lcars-20260530-002"     # nothing in this suite touches it
OLD_ACTIVE="lcars-20260530-003"
mk_old_mission "$OLD" "$OLD_DONE"   done  7
mk_old_mission "$OLD" "$OLD_IDLE"   plan  9
mk_old_mission "$OLD" "$OLD_ACTIVE" align 8
DONEDIR="$OLD/.git/lcars/missions/$OLD_DONE"
IDLEDIR="$OLD/.git/lcars/missions/$OLD_IDLE"
ACTDIR="$OLD/.git/lcars/missions/$OLD_ACTIVE"
IDLE_SNAPSHOT="$(cksum "$IDLEDIR/state.json")"

check "3. the old-format fixtures start as valid JSON at the OLD shape" \
  "json_ok '$DONEDIR/state.json' && json_ok '$ACTDIR/state.json' \
   && ! is_new_shape '$OLD_DONE' && ! is_new_shape '$OLD_ACTIVE'"

# 3a. `lcars run` LOCATES and DRIVES an old-format id (stage=done → the drive
#     loop's terminal arm; no worker is spawned, which is why this costs
#     nothing).
( cd "$OLD" && LCARS_GH_BIN="$OLD/gh" GH_LOG="$OLD/gh.log" \
    bash "$RUN_SCRIPT" drive --mission "$OLD_DONE" >"$OLD/run-old.txt" 2>&1 )
check "3a. lcars run RESOLVED the old-format id (no 'no mission' refusal)" \
  "! grep -q \"no mission '$OLD_DONE'\" '$OLD/run-old.txt'"
check "3a. lcars run drove it to its terminal arm" \
  "grep -q 'stopped at: done' '$OLD/run-old.txt'"
check "3a. state.json still parses after the run (no corruption)" \
  "json_ok '$DONEDIR/state.json' \
   && [ \"\$(json_field '$DONEDIR/state.json' id)\" = '$OLD_DONE' ] \
   && [ \"\$(json_field '$DONEDIR/state.json' stage)\" = 'done' ]"

# 3b. the shared resolver still finds an old-format id, in full and by partial.
RESOLVED="$( cd "$OLD" && bash "$RESOLVE_SCRIPT" --scope active --id "$OLD_ACTIVE" 2>/dev/null )"
RESOLVED_PARTIAL="$( cd "$OLD" && bash "$RESOLVE_SCRIPT" --scope active --id "20260530-003" 2>/dev/null )"
check "3b. resolve.sh resolves the old-format id in full" "[ \"$RESOLVED\" = '$OLD_ACTIVE' ]"
check "3b. resolve.sh resolves it by partial id" "[ \"$RESOLVED_PARTIAL\" = '$OLD_ACTIVE' ]"

# 3c. an old-format mission is a valid `lcars log` PARENT, and the bug child it
#     mints gets the NEW shape while the parent keeps the OLD one.
bugprd="$OLD/bug.md"
cat >"$bugprd" <<'EOF'
# Mission: The About heading is the wrong size

**Type:** bug
EOF
( cd "$OLD" && LCARS_GH_BIN="$OLD/gh" LCARS_DATE=20260530 GH_LOG="$OLD/gh.log" \
    bash "$LOG_SCRIPT" --parent "$OLD_ACTIVE" --prd "$bugprd" >"$OLD/log.txt" 2>&1 )
CHILD="$(ls -1 "$OLD/.git/lcars/missions" \
           | grep -v "^$OLD_DONE\$" | grep -v "^$OLD_IDLE\$" | grep -v "^$OLD_ACTIVE\$" | head -1)"
check "3c. lcars log accepted the old-format parent and minted a child ('${CHILD:-none}')" \
  "[ -n '$CHILD' ]"
check "3c. the child's sequence CONTINUES past the highest old-format NNN (003 → 004)" \
  "printf '%s' '$CHILD' | grep -q -- '-004-'"
check "3c. the child carries the new fingerprinted shape" "is_new_shape '$CHILD'"
check "3c. the child's state.json parses and names the OLD-format parent" \
  "json_ok '$OLD/.git/lcars/missions/$CHILD/state.json' \
   && [ \"\$(json_field '$OLD/.git/lcars/missions/$CHILD/state.json' parentMission)\" = '$OLD_ACTIVE' ] \
   && [ \"\$(json_field '$OLD/.git/lcars/missions/$CHILD/state.json' base)\" = 'lcars/$OLD_ACTIVE' ]"
check "3c. the UNTOUCHED old-format mission is byte-identical — nothing migrated" \
  "[ \"\$(cksum '$IDLEDIR/state.json')\" = \"$IDLE_SNAPSHOT\" ]"
check "3c. every old mission still declares its OLD-format id (never re-minted)" \
  "[ \"\$(json_field '$DONEDIR/state.json' id)\"  = '$OLD_DONE' ] \
   && [ \"\$(json_field '$IDLEDIR/state.json' id)\" = '$OLD_IDLE' ] \
   && [ \"\$(json_field '$ACTDIR/state.json' id)\"  = '$OLD_ACTIVE' ]"
check "3c. no old mission directory was renamed" \
  "[ -d '$DONEDIR' ] && [ -d '$IDLEDIR' ] && [ -d '$ACTDIR' ]"
check "3c. every old mission's state.json still parses" \
  "json_ok '$DONEDIR/state.json' && json_ok '$IDLEDIR/state.json' && json_ok '$ACTDIR/state.json'"

# ==========================================================================
# 4. LAZY ACQUISITION — AN ALREADY-INITIALISED REPO WITH NO cloneId
# ==========================================================================
# Every repo on this machine was initialised before S196, so none has a
# fingerprint. Acquiring one must need no captain action and must change no
# existing mission.
LAZY="$TMPROOT/lazyrepo"
mkdir -p "$LAZY"
( cd "$LAZY" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
seed_lcars "$LAZY"
LEGACY="lcars-20260530-001"
mkdir -p "$LAZY/.git/lcars/missions/$LEGACY"
write_prd "$LAZY/.git/lcars/missions/$LEGACY/prd.md" "Legacy"
cat >"$LAZY/.git/lcars/missions/$LEGACY/state.json" <<EOF
{ "id": "$LEGACY", "title": "Legacy", "type": "bug", "stage": "align",
  "githubIssue": 3, "branch": "lcars/$LEGACY", "base": "main" }
EOF
BEFORE_DIRS="$(ls -1 "$LAZY/.git/lcars/missions" | sort | tr '\n' ' ')"
BEFORE_LEGACY="$(cksum "$LAZY/.git/lcars/missions/$LEGACY/state.json")"
check "4. the fixture config has NO cloneId to begin with" \
  "[ -z \"\$(json_field '$LAZY/.git/lcars/config.json' cloneId)\" ]"
prdL="$LAZY/prd.md"; write_prd "$prdL" "First mission after the upgrade"
IDL="$(file_one "$LAZY" "$prdL" 20260530)"
AFTER_DIRS="$(ls -1 "$LAZY/.git/lcars/missions" | sort | tr '\n' ' ')"
check "4. the repo acquired a cloneId with no captain action" \
  "[ -n \"\$(json_field '$LAZY/.git/lcars/config.json' cloneId)\" ]"
check "4. config.json is still valid JSON" "json_ok '$LAZY/.git/lcars/config.json'"
check "4. the captain's existing config keys survived the lazy write" \
  "[ \"\$(json_field '$LAZY/.git/lcars/config.json' testCommand)\" = 'true' ] \
   && [ \"\$(json_field '$LAZY/.git/lcars/config.json' model)\" = 'claude-sonnet' ] \
   && [ \"\$(json_field '$LAZY/.git/lcars/config.json' created)\" = '2026-05-30T00:00:00Z' ]"
check "4. the pre-existing mission id was NOT re-minted" \
  "[ -d '$LAZY/.git/lcars/missions/$LEGACY' ] \
   && [ \"\$(cksum '$LAZY/.git/lcars/missions/$LEGACY/state.json')\" = \"$BEFORE_LEGACY\" ]"
check "4. the only directory added is the new mission" \
  "[ \"$AFTER_DIRS\" = \"$BEFORE_DIRS$IDL \" ]"
LAZY_CID="$(json_field "$LAZY/.git/lcars/config.json" cloneId)"
LAZY_CID2="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_clone_id "$LAZY/.git/lcars/config.json" )"
check "4. the fingerprint is STABLE on a second read (nothing re-mints it)" \
  "[ -n \"$LAZY_CID\" ] && [ \"$LAZY_CID\" = \"$LAZY_CID2\" ]"

# 4b. `lcars update` must not DROP the key — lcars_config_merge treats its
#     desired list as the canonical schema and discards anything absent from it.
CLONEID_BEFORE_UPDATE="$(json_field "$LAZY/.git/lcars/config.json" cloneId)"
( cd "$LAZY" && LCARS_GH_BIN="$LAZY/gh" GH_LOG="$LAZY/gh.log" \
    bash "$UPDATE_SCRIPT" >"$LAZY/update.txt" 2>&1 )
check "4b. \`lcars update\` PRESERVED the cloneId (the merge schema knows it)" \
  "[ \"\$(json_field '$LAZY/.git/lcars/config.json' cloneId)\" = \"$CLONEID_BEFORE_UPDATE\" ] \
   && [ -n \"$CLONEID_BEFORE_UPDATE\" ]"
check "4b. config.json still parses after \`lcars update\`" \
  "json_ok '$LAZY/.git/lcars/config.json'"

# 4c. A ONE-LINE config.json (the shape every other suite's fixture uses, and
#     the shape a hand-written config takes) must survive the LAZY write. A
#     naive "insert a line after line 1" writer emits a second top-level object
#     here and the file stops parsing.
ONELINE="$TMPROOT/onelinerepo"
mkdir -p "$ONELINE"
( cd "$ONELINE" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
mkdir -p "$ONELINE/.git/lcars/missions"
make_gh_stub "$ONELINE/gh"
printf '%s\n' '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }' \
  >"$ONELINE/.git/lcars/config.json"
prd1L="$ONELINE/prd.md"; write_prd "$prd1L" "One-line config repo"
ID1L="$(file_one "$ONELINE" "$prd1L" 20260530)"
check "4c. a ONE-LINE config.json still parses after the lazy cloneId write" \
  "json_ok '$ONELINE/.git/lcars/config.json'"
check "4c. it gained a cloneId and kept every existing key" \
  "[ -n \"\$(json_field '$ONELINE/.git/lcars/config.json' cloneId)\" ] \
   && [ \"\$(json_field '$ONELINE/.git/lcars/config.json' testCommand)\" = 'true' ] \
   && [ \"\$(json_field '$ONELINE/.git/lcars/config.json' created)\" = '2026-05-30T00:00:00Z' ]"
check "4c. and the mission it filed carries the fingerprinted shape ('${ID1L:-none}')" \
  "is_new_shape '$ID1L'"

# 4d. An EMPTY config object is the degenerate case the same writer must survive.
EMPTYCFG="$TMPROOT/empty-config.json"
printf '{}\n' >"$EMPTYCFG"
EMPTY_CID="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_clone_id "$EMPTYCFG" )"
check "4d. an EMPTY config object survives the insert and parses" \
  "json_ok '$EMPTYCFG' && [ -n \"$EMPTY_CID\" ] \
   && [ \"\$(json_field '$EMPTYCFG' cloneId)\" = \"$EMPTY_CID\" ]"

# 4e. A config carrying a GARBAGE cloneId, on a shared line. The in-place
#     value repair would rewrite the whole line and take the neighbouring keys
#     with it, so it must not be reached for: the value goes to the bridge file
#     and the answer is still STABLE across calls.
BADCFG_DIR="$TMPROOT/badcfg"
mkdir -p "$BADCFG_DIR"
BADCFG="$BADCFG_DIR/config.json"
printf '%s\n' '{ "cloneId": "NOT-A-CLONE-ID", "model": "claude-sonnet", "testCommand": "true" }' >"$BADCFG"
BAD_CID1="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_clone_id "$BADCFG" )"
BAD_CID2="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_clone_id "$BADCFG" )"
check "4e. a garbage cloneId is replaced by a usable one, STABLY across calls" \
  "[ -n \"$BAD_CID1\" ] && [ \"$BAD_CID1\" = \"$BAD_CID2\" ] \
   && printf '%s' \"$BAD_CID1\" | grep -Eq '^[0-9a-f]{32}$'"
check "4e. and the hand-written config was NOT rewritten (still valid, keys intact)" \
  "json_ok '$BADCFG' \
   && [ \"\$(json_field '$BADCFG' testCommand)\" = 'true' ] \
   && [ \"\$(json_field '$BADCFG' model)\" = 'claude-sonnet' ]"

# ==========================================================================
# 5. THE WIDENED ID IS A VALID GIT REF, AND THE BRANCH ROUND-TRIPS
# ==========================================================================
NEWBRANCH="lcars/$IDA2"
check "5. git itself accepts lcars/<widened-id> as a branch name" \
  "git check-ref-format --branch '$NEWBRANCH' >/dev/null 2>&1"
check "5. filing actually created that local branch" \
  "( cd '$CLONE_A' && git show-ref --verify --quiet 'refs/heads/$NEWBRANCH' )"
( cd "$CLONE_A" && git push -q origin "$NEWBRANCH" ) >/dev/null 2>&1
PUSH_RC=$?
check "5. the branch pushes to the shared remote" "[ $PUSH_RC -eq 0 ]"
check "5. the remote holds it under the same name" \
  "( cd '$ORIGIN' && git show-ref --verify --quiet 'refs/heads/$NEWBRANCH' )"
RT="$TMPROOT/roundtrip"
git clone -q "$ORIGIN" "$RT" >/dev/null 2>&1
check "5. a third clone can check the branch out by name (round-trip)" \
  "( cd '$RT' && git checkout -q '$NEWBRANCH' >/dev/null 2>&1 \
     && [ \"\$(git rev-parse --abbrev-ref HEAD)\" = '$NEWBRANCH' ] )"
check "5. the OLD-format branch name is still valid too (no regression)" \
  "git check-ref-format --branch 'lcars/lcars-20260530-001' >/dev/null 2>&1"

# ==========================================================================
# 6. THE MINTER ITSELF — the ONE parser, driven directly
# ==========================================================================
# The sequence scan is the matcher most likely to break: it used to read the
# text after the LAST '-', which on a fingerprinted id is the FINGERPRINT.
MINT="$TMPROOT/mintdir"
mkdir -p "$MINT"
mkdir -p "$MINT/lcars-20260530-001"          # old shape
mkdir -p "$MINT/lcars-20260530-002-beef"     # new shape
mkdir -p "$MINT/lcars-20260530-007-0a1b"     # new shape, higher
mkdir -p "$MINT/lcars-20260530-junk"         # garbage: must not explode
mkdir -p "$MINT/lcars-20260531-099"          # a DIFFERENT day: must not count
MINTED="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_mint_mission_id "$MINT" 20260530 abcd )"
check "6. the scan reads NNN past a fingerprint (got '${MINTED:-none}')" \
  "[ '$MINTED' = 'lcars-20260530-008-abcd' ]"
MINTED2="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_mint_mission_id "$MINT" 20260601 abcd )"
check "6. a fresh day restarts at 001" "[ '$MINTED2' = 'lcars-20260601-001-abcd' ]"
FPOUT="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_clone_fingerprint "$CLONE_A/.git/lcars/config.json" )"
check "6. the fingerprint helper returns 4 lowercase hex chars ('${FPOUT:-none}')" \
  "printf '%s' '$FPOUT' | grep -Eq '^[0-9a-f]{4}$'"
check "6. and it matches the fingerprint baked into that clone's ids" \
  "[ \"\$(printf '%s' '$IDA' | sed 's/.*-//')\" = '$FPOUT' ]"

# ==========================================================================
# 7. ZERO MODEL SPEND
# ==========================================================================
SHIM_CLAUDE="$(awk '/^claude /{n++} END{print n+0}' "$LCARS_SHIM_LOG")"
SHIM_COPILOT="$(awk '/^copilot /{n++} END{print n+0}' "$LCARS_SHIM_LOG")"
check "7. the faked \`claude\` was invoked 0 times (saw $SHIM_CLAUDE)" \
  "[ '$SHIM_CLAUDE' -eq 0 ]"
check "7. the faked \`copilot\` was invoked 0 times (saw $SHIM_COPILOT)" \
  "[ '$SHIM_COPILOT' -eq 0 ]"

# ==========================================================================
printf '\n  %d checks, %d failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
