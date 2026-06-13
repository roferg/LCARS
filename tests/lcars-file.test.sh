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
# A stub for the lcars-run estimator driver (session 59). file.sh runs
# `run.sh estimate` at the end of Align; pointing LCARS_RUN_BIN at this stub keeps
# that call fast and deterministic (no real model spawn) while exercising the
# success path: it writes a minimal valid estimate.json into the mission dir. The
# mission id is the last positional arg following --mission. These tests do not
# assert on estimate.json — they only need filing to complete cleanly.
ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"
cat >"$ESTIMATOR_STUB" <<'EOF'
#!/usr/bin/env bash
# usage (as called by file.sh): estimate --mission <id>
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
# Every file.sh invocation in this suite uses the stub estimator (NEVER a real
# model). Exported once so the existing test bodies need no per-call change.
export LCARS_RUN_BIN="$ESTIMATOR_STUB"

# A fake `gh` that records every invocation and, on `issue create`, prints
# the URL of the new issue (number 42) the way real gh does.
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
# When a --body-file is passed and GH_BODY is set, capture its contents so a
# test can assert what file.sh actually handed gh as the issue body.
if [ -n "${GH_BODY:-}" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ]; then cat "$a" >"$GH_BODY"; fi
    prev="$a"
  done
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"
  exit 0
fi
exit 0
EOF
  chmod +x "$p"
}

# Build an isolated git repo with .git/lcars/ already scaffolded. An initial
# commit exists so `lcars file` can branch off it (a Mission gets its own branch
# at filing time) — matching how `lcars file` is run in a real, non-empty repo.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
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
check "5. tags the Mission issue lcars:mission (role)" "grep -q 'lcars:align,lcars:bug,lcars:mission' '$repo/gh.log'"
check "5. never tags a Mission issue lcars:ticket"     "! grep -q 'lcars:ticket' '$repo/gh.log'"
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

# --- Behaviour 7: the Mission gets its own branch -------------------------
# vision.md: each Mission gets its own branch. `lcars file` creates lcars/<id>
# off the current branch and records it (with the base) in state.json, so
# Implement can commit to it and `lcars approve` can push it + open the PR.
EXP_BASE="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
check "7. creates the branch lcars/<mission-id>" \
  "( cd '$repo' && git show-ref --verify --quiet 'refs/heads/lcars/lcars-20260530-001' )"
check "7. does not switch the working tree off the base branch" \
  "[ \"\$(cd '$repo' && git rev-parse --abbrev-ref HEAD)\" = '$EXP_BASE' ]"
check "7. records the branch in state.json" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-001\"' '$M/state.json'"
check "7. records the base in state.json" \
  "grep -q '\"base\": *\"$EXP_BASE\"' '$M/state.json'"
check "7. summary reports the branch" \
  "grep -q 'Branch:.*lcars/lcars-20260530-001' '$repo/out.txt'"

# --- Behaviour 8: adaptive-depth ADR artifact (Session 36) ----------------
# Align scales depth to complexity. A TRIVIAL Mission is filed with --prd only
# and NO --adr: no adr.md must be written (never burden small work). A COMPLEX
# Mission passes --adr <path>: file.sh copies it to $MISSION_DIR/adr.md after
# shape-checking it. The ADR shape is Context / Decision / Alternatives /
# Consequences — file.sh rejects a malformed adr.md (writing nothing), exactly
# the way it rejects a malformed PRD. An ABSENT adr.md is always fine.

# Write a well-formed ADR file with every required section.
write_adr() {
  cat >"$1" <<'EOF'
# Architecture Decision Records: Add dark mode

## ADR-001: Theme delivery via a data-theme attribute

**Context:** The app already ships a `--color-*` CSS variable layer.
**Decision:** Drive theming by flipping a `data-theme` attribute on `<html>`.
**Alternatives considered:** A parallel dark stylesheet; a CSS-in-JS theme provider.
**Consequences:** Reuses the token layer; no parallel colour system to maintain.
EOF
}

# 8a. Trivial Mission: --prd only, no --adr → succeeds, writes NO adr.md.
repoT="$(new_repo)"; make_gh_stub "$repoT/gh"
export GH_LOG="$repoT/gh.log"; : >"$GH_LOG"
prdT="$repoT/prd.md"; write_prd "$prdT"
rcT=0
(
  cd "$repoT"
  LCARS_GH_BIN="$repoT/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdT" >outT.txt 2>&1
) || rcT=$?
MT="$repoT/.git/lcars/missions/lcars-20260530-001"
check "8a. trivial Mission (no --adr) files successfully" "[ '$rcT' -eq 0 ]"
check "8a. no adr.md is written for a trivial Mission" "[ ! -f '$MT/adr.md' ]"

# 8b. Complex Mission: --adr <well-formed> → adr.md persisted with its sections.
repoC="$(new_repo)"; make_gh_stub "$repoC/gh"
export GH_LOG="$repoC/gh.log"; : >"$GH_LOG"
prdC="$repoC/prd.md"; write_prd "$prdC"
adrC="$repoC/adr.md"; write_adr "$adrC"
rcC=0
(
  cd "$repoC"
  LCARS_GH_BIN="$repoC/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdC" --adr "$adrC" >outC.txt 2>&1
) || rcC=$?
MC="$repoC/.git/lcars/missions/lcars-20260530-001"
check "8b. complex Mission with --adr files successfully" "[ '$rcC' -eq 0 ]"
check "8b. adr.md is persisted into the mission dir" "[ -f '$MC/adr.md' ]"
check "8b. adr.md carries its Context section"      "grep -q '\\*\\*Context:\\*\\*' '$MC/adr.md'"
check "8b. adr.md carries its Decision section"     "grep -q '\\*\\*Decision:\\*\\*' '$MC/adr.md'"
check "8b. adr.md carries its Alternatives section" "grep -q '\\*\\*Alternatives considered:\\*\\*' '$MC/adr.md'"
check "8b. adr.md carries its Consequences section" "grep -q '\\*\\*Consequences:\\*\\*' '$MC/adr.md'"

# 8c. A malformed adr.md (missing a required ADR section) is REJECTED: non-zero
# exit and NOTHING written (no mission dir created), mirroring a bad PRD.
repoB="$(new_repo)"; make_gh_stub "$repoB/gh"
export GH_LOG="$repoB/gh.log"; : >"$GH_LOG"
prdB="$repoB/prd.md"; write_prd "$prdB"
badadr="$repoB/bad-adr.md"
printf '# ADRs\n\n## ADR-001\n\n**Context:** x\n**Decision:** y\n' >"$badadr"
rcB=0
(
  cd "$repoB"
  LCARS_GH_BIN="$repoB/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdB" --adr "$badadr" >outB.txt 2>&1
) || rcB=$?
check "8c. rejects an adr.md missing required ADR sections" "[ '$rcB' -ne 0 ]"
check "8c. no mission created from a bad adr.md" \
  "[ -z \"\$(ls -A '$repoB/.git/lcars/missions')\" ]"
check "8c. error names the missing ADR section" \
  "grep -qi 'alternatives\\|adr' '$repoB/outB.txt'"

# --- Behaviour 9: issue body combines PRD + ADR set (BUG-012) -------------
# For a COMPLEX Mission, Align produces both a PRD and an ADR set; both are
# persisted to disk as separate artifacts. The GitHub issue body must show the
# architectural decisions too, so the body handed to gh is prd.md + a
# `\n\n---\n\n` separator + adr.md, PRD FIRST. A TRIVIAL Mission (no adr.md)
# keeps a PRD-only body, exactly as before. The on-disk prd.md and adr.md stay
# separate, untouched files.

# 9a. Complex Mission: body contains BOTH PRD and ADR content, PRD first.
repoBody="$(new_repo)"; make_gh_stub "$repoBody/gh"
export GH_LOG="$repoBody/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoBody/gh-body.txt"; : >"$GH_BODY"
prdBody="$repoBody/prd.md"; write_prd "$prdBody"
adrBody="$repoBody/adr.md"; write_adr "$adrBody"
(
  cd "$repoBody"
  LCARS_GH_BIN="$repoBody/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdBody" --adr "$adrBody" >outBody.txt 2>&1
)
MBody="$repoBody/.git/lcars/missions/lcars-20260530-001"
check "9a. issue body contains the PRD content" \
  "grep -q 'Fix the broken /about route' '$GH_BODY'"
check "9a. issue body contains the ADR content" \
  "grep -q 'Theme delivery via a data-theme attribute' '$GH_BODY'"
check "9a. issue body has the --- separator" \
  "grep -qx -- '---' '$GH_BODY'"
check "9a. PRD content appears before the ADR content in the body" \
  "[ \"\$(grep -n 'Fix the broken /about route' '$GH_BODY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'Theme delivery via a data-theme attribute' '$GH_BODY' | head -1 | cut -d: -f1)\" ]"
check "9a. on-disk prd.md is unchanged (no ADR content leaked in)" \
  "! grep -q 'Theme delivery via a data-theme attribute' '$MBody/prd.md'"
check "9a. on-disk adr.md is unchanged (no PRD content leaked in)" \
  "! grep -q 'Fix the broken /about route' '$MBody/adr.md'"
unset GH_BODY

# 9b. Trivial Mission (no --adr): body is PRD-only, no ADR content.
repoBody2="$(new_repo)"; make_gh_stub "$repoBody2/gh"
export GH_LOG="$repoBody2/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoBody2/gh-body.txt"; : >"$GH_BODY"
prdBody2="$repoBody2/prd.md"; write_prd "$prdBody2"
(
  cd "$repoBody2"
  LCARS_GH_BIN="$repoBody2/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdBody2" >outBody2.txt 2>&1
)
check "9b. PRD-only body contains the PRD content" \
  "grep -q 'Fix the broken /about route' '$GH_BODY'"
check "9b. PRD-only body has no ADR content" \
  "! grep -q 'Theme delivery via a data-theme attribute' '$GH_BODY'"
check "9b. PRD-only body has no --- separator" \
  "! grep -qx -- '---' '$GH_BODY'"
unset GH_BODY

# ==========================================================================
[ "$fail" -eq 0 ]
