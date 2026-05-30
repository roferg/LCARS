#!/usr/bin/env bash
#
# Tests for `lcars file` (skill source: skills/lcars-file/file.sh).
#
# `lcars file` has two halves. The conversational half (Capture + Align) is
# driven by Claude per SKILL.md and produces a PRD on disk. The mechanical
# half — persisting the mission, opening the GitHub issue, and confirming —
# lives in file.sh so it can be exercised directly. These tests drive that
# script, covering the six behaviours from the build order, in order:
#   1. Generates a valid mission ID with correct date format (and increments)
#   2. Creates the correct directory structure under .git/lcars/missions/
#   3. Writes prd.md with all required sections present
#   4. Writes state.json with the correct shape
#   5. Creates the GitHub issue and saves the issue number
#   6. Prints the correct confirmation summary
#
# The script takes its dependencies via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary    (default: gh)
#   LCARS_DATE     - the YYYYMMDD used in the mission ID (default: today, UTC)
#
# Usage: bash tests/lcars-file.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- stubs ----------------------------------------------------------------
# A fake `gh` that records every invocation and, on `issue create`, prints
# the URL of the new issue (number 42) the way real gh does.
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"
  exit 0
fi
exit 0
EOF
  chmod +x "$p"
}

# Build an isolated git repo with .git/lcars/ already scaffolded.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "created": "2026-05-30T00:00:00Z" }
EOF
  echo "$repo"
}

# Write a well-formed PRD file with every required section.
write_prd() {
  cat >"$1" <<'EOF'
# Mission: Fix the broken /about route

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

# ==========================================================================
echo "lcars file"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: valid mission ID with correct date format ----------------
repo="$(new_repo)"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
prd="$repo/prd-in.md"; write_prd "$prd"
(
  cd "$repo"
  LCARS_GH_BIN="$repo/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prd" >out.txt 2>&1
)
check "1. creates mission dir named lcars-20260530-001" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-001' ]"
check "1. summary reports the mission ID" \
  "grep -q 'lcars-20260530-001' '$repo/out.txt'"

# second mission the same day increments to -002
prd2="$repo/prd-in2.md"; write_prd "$prd2"
(
  cd "$repo"
  LCARS_GH_BIN="$repo/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prd2" >out2.txt 2>&1
)
check "1. second mission increments to lcars-20260530-002" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-002' ]"

# --- Behaviour 2: directory structure -------------------------------------
M="$repo/.git/lcars/missions/lcars-20260530-001"
check "2. mission dir contains prd.md"    "[ -f '$M/prd.md' ]"
check "2. mission dir contains state.json" "[ -f '$M/state.json' ]"

# --- Behaviour 3: prd.md has all required sections ------------------------
check "3. prd.md has Mission title"        "grep -q '^# Mission:' '$M/prd.md'"
check "3. prd.md has Type"                 "grep -q '\\*\\*Type:\\*\\*' '$M/prd.md'"
check "3. prd.md has Goal"                 "grep -q '\\*\\*Goal:\\*\\*' '$M/prd.md'"
check "3. prd.md has Acceptance Criteria"  "grep -q '\\*\\*Acceptance Criteria:\\*\\*' '$M/prd.md'"
check "3. prd.md has Out of Scope"         "grep -q '\\*\\*Out of Scope:\\*\\*' '$M/prd.md'"
check "3. prd.md has Constraints"          "grep -q '\\*\\*Constraints:\\*\\*' '$M/prd.md'"

# a PRD missing a required section is rejected before anything is written
repoX="$(new_repo)"; make_gh_stub "$repoX/gh"
export GH_LOG="$repoX/gh.log"; : >"$GH_LOG"
badprd="$repoX/bad.md"
printf '# Mission: incomplete\n\n**Type:** bug\n**Goal:** nope\n' >"$badprd"
rcX=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$badprd" >outX.txt 2>&1
) || rcX=$?
check "3. rejects PRD missing required sections" "[ '$rcX' -ne 0 ]"
check "3. no mission created from a bad PRD" \
  "[ -z \"\$(ls -A '$repoX/.git/lcars/missions')\" ]"

# --- Behaviour 4: state.json correct shape --------------------------------
check "4. state.json has id"          "grep -q '\"id\"' '$M/state.json'"
check "4. state.json id matches"      "grep -q '\"lcars-20260530-001\"' '$M/state.json'"
check "4. state.json type is bug"     "grep -q '\"type\": *\"bug\"' '$M/state.json'"
check "4. state.json stage is align"  "grep -q '\"stage\": *\"align\"' '$M/state.json'"
check "4. state.json has created"     "grep -q '\"created\"' '$M/state.json'"
check "4. state.json has model"       "grep -q '\"model\"' '$M/state.json'"

# --- Behaviour 5: GitHub issue created and number saved -------------------
check "5. calls gh issue create"              "grep -q 'issue create' '$repo/gh.log'"
check "5. passes the align + type labels"     "grep -q 'lcars:align,lcars:bug' '$repo/gh.log'"
check "5. uses --body-file for the PRD"        "grep -q 'body-file' '$repo/gh.log'"
check "5. saves the issue number to state"     "grep -q '\"githubIssue\": *42' '$M/state.json'"

# gh unavailable -> mission still filed locally, issue recorded as null
repoG="$(new_repo)"
export GH_LOG="$repoG/gh.log"; : >"$GH_LOG"
prdG="$repoG/prd.md"; write_prd "$prdG"
rcG=0
(
  cd "$repoG"
  LCARS_GH_BIN="$repoG/definitely-no-gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdG" >outG.txt 2>&1
) || rcG=$?
check "5. still files the mission when gh is missing" \
  "[ -d '$repoG/.git/lcars/missions/lcars-20260530-001' ]"
check "5. records githubIssue null when gh missing" \
  "grep -q '\"githubIssue\": *null' '$repoG/.git/lcars/missions/lcars-20260530-001/state.json'"

# --- Behaviour 6: confirmation summary ------------------------------------
check "6. summary: Mission filed line"  "grep -q 'Mission filed:.*lcars-20260530-001' '$repo/out.txt'"
check "6. summary: GitHub issue line"   "grep -q 'GitHub issue:.*#42' '$repo/out.txt'"
check "6. summary: Stage align line"    "grep -qi 'Stage:.*align' '$repo/out.txt'"
check "6. summary: Next lcars run line" "grep -q 'lcars run lcars-20260530-001' '$repo/out.txt'"

# ==========================================================================
echo
printf 'lcars file: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
