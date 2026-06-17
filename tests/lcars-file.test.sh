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

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# first match and SIGPIPEs the producer, which under `set -o pipefail` fails the
# pipeline. Buffer stdin, then grep the buffer (never `… | grep -q`).
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

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

# --- Behaviour 10: estimate rendered into BOTH captain surfaces (S61) ------
# After Align, lcars-file runs the estimator (estimate.json) and renders it into
#   (A) the GitHub issue BODY — an "## Estimate" section (both criticality
#       scores, the per-stage model table, the cost line), AND
#   (B) the CLI readout (stdout) — a compact Estimate summary with the scores +
#       cost in the ACTIVE CLI's native unit.
# The estimator MUST run BEFORE the issue is created (so estimate.json exists when
# the body is composed). The cost renders in the active CLI's unit: claude → "$"
# range; copilot → premium requests. An ABSENT estimate.json ⇒ body = prd[+adr]
# only (no "## Estimate"), readout prints normally, no crash — degradation parity.
#
# These tests use a RICHER estimator stub that drops a schema-2 estimate.json with
# token/request estimates, AND delegates `render-estimate` to the REAL run.sh so
# the cost is computed for real. The active CLI is forced via env.
REAL_RUN="$REPO_ROOT/skills/lcars-run/run.sh"
RICH_STUB="$TMPROOT/estimate-rich.sh"
cat >"$RICH_STUB" <<EOF
#!/usr/bin/env bash
# Dispatch on the subcommand: 'estimate' plants a rich estimate.json; everything
# else (render-estimate) is delegated to the REAL run.sh so cost is computed.
sub="\${1:-}"
if [ "\$sub" != "estimate" ]; then exec bash "$REAL_RUN" "\$@"; fi
shift
mid=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --mission) mid="\${2:-}"; shift 2 ;;
    --mission=*) mid="\${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="\$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "\$gitdir" in /*) : ;; *) gitdir="\$PWD/\$gitdir" ;; esac
mdir="\$gitdir/lcars/missions/\$mid"
[ -d "\$mdir" ] || exit 1
cat >"\$mdir/estimate.json" <<JSON
{ "schemaVersion": 2, "reasoningCriticality": "high", "implCriticality": "medium",
  "models": { "research":"opus","validate":"sonnet","plan":"sonnet","planReview":"sonnet","implement":"opus","verify":"sonnet" },
  "tokenEstimates": { "research":{"low":100000,"high":200000},"validate":{"low":50000,"high":100000},"plan":{"low":50000,"high":100000},"planReview":{"low":50000,"high":100000},"implement":{"low":200000,"high":400000},"verify":{"low":20000,"high":40000} },
  "requestEstimates": { "research":{"low":2,"high":4},"validate":{"low":1,"high":2},"plan":{"low":1,"high":2},"planReview":{"low":1,"high":2},"implement":{"low":4,"high":8},"verify":{"low":1,"high":2} },
  "deviations": [], "rationale": "High-criticality feature touching core contracts.", "estimatorModel": "opus" }
JSON
exit 0
EOF
chmod +x "$RICH_STUB"

# 10a. Claude active: issue body carries an "## Estimate" section with BOTH scores,
# the per-stage model table (Opus + Sonnet), and the "$X–$Y" cost range.
repoE="$(new_repo)"; make_gh_stub "$repoE/gh"
export GH_LOG="$repoE/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoE/gh-body.txt"; : >"$GH_BODY"
prdE="$repoE/prd.md"; write_prd "$prdE"
(
  cd "$repoE"
  CLAUDECODE=1 LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoE/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdE" >outE.txt 2>&1
)
check "10a. issue body has an '## Estimate' section" \
  "grep -q '## Estimate' '$GH_BODY'"
check "10a. issue Estimate shows reasoning criticality (high)" \
  "grep -qi 'reasoning' '$GH_BODY' && grep -qi 'HIGH' '$GH_BODY'"
check "10a. issue Estimate shows implementation criticality (medium)" \
  "grep -qi 'implementation' '$GH_BODY' && grep -qi 'MEDIUM' '$GH_BODY'"
check "10a. issue Estimate has a per-stage model table (Opus + Sonnet)" \
  "grep -q 'Opus' '$GH_BODY' && grep -q 'Sonnet' '$GH_BODY'"
check "10a. issue Estimate names each stage (Implement)" \
  "grep -qi 'Implement' '$GH_BODY'"
check "10a. issue Estimate shows the \$ cost range" \
  "grep -q '3.6' '$GH_BODY' && grep -q '7.2' '$GH_BODY'"
check "10a. issue Estimate section comes AFTER the PRD content" \
  "[ \"\$(grep -n 'Fix the broken /about route' '$GH_BODY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '## Estimate' '$GH_BODY' | head -1 | cut -d: -f1)\" ]"
unset GH_BODY

# 10b. Claude active: the CLI readout (stdout) shows the compact Estimate summary
# with the scores + the "$" cost range.
check "10b. CLI readout has the Estimate summary line" \
  "grep -qi 'Estimate:' '$repoE/outE.txt'"
check "10b. CLI readout shows both criticalities" \
  "grep -qi 'reasoning' '$repoE/outE.txt' && grep -qi 'implementation' '$repoE/outE.txt'"
check "10b. CLI readout shows the \$ cost range" \
  "grep -q '3.6' '$repoE/outE.txt' && grep -q '7.2' '$repoE/outE.txt'"

# 10c. estimate.json ABSENT (estimator produces nothing) ⇒ body is prd-only with
# NO "## Estimate" section; readout still prints; no crash (degradation parity).
# The estimator stub emits nothing (NONE) so no estimate.json is written.
NONE_STUB="$TMPROOT/estimate-none.sh"
cat >"$NONE_STUB" <<EOF
#!/usr/bin/env bash
# 'estimate' writes nothing (failure); 'render-estimate' delegates to real run.sh
# (which exits non-zero because estimate.json is absent).
[ "\${1:-}" = "estimate" ] && exit 1
exec bash "$REAL_RUN" "\$@"
EOF
chmod +x "$NONE_STUB"
repoN="$(new_repo)"; make_gh_stub "$repoN/gh"
export GH_LOG="$repoN/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoN/gh-body.txt"; : >"$GH_BODY"
prdN="$repoN/prd.md"; write_prd "$prdN"
rcN=0
(
  cd "$repoN"
  CLAUDECODE=1 LCARS_RUN_BIN="$NONE_STUB" \
    LCARS_GH_BIN="$repoN/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdN" >outN.txt 2>&1
) || rcN=$?
check "10c. mission still files when estimate.json is absent" "[ '$rcN' -eq 0 ]"
check "10c. absent estimate ⇒ body has NO '## Estimate' section" \
  "! grep -q '## Estimate' '$GH_BODY'"
check "10c. absent estimate ⇒ body still has the PRD content" \
  "grep -q 'Fix the broken /about route' '$GH_BODY'"
check "10c. absent estimate ⇒ readout still prints the Mission filed line" \
  "grep -q 'Mission filed:' '$repoN/outN.txt'"
unset GH_BODY

# 10d. Copilot active, DEFAULT billing (usage / GitHub AI Credits, session 64):
# cost renders as a USD band (token-metered) with the included-allotment line,
# NOT premium requests, in BOTH surfaces. Force copilot via LCARS_WORKER_CLI.
repoP="$(new_repo)"; make_gh_stub "$repoP/gh"
export GH_LOG="$repoP/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoP/gh-body.txt"; : >"$GH_BODY"
prdP="$repoP/prd.md"; write_prd "$prdP"
(
  cd "$repoP"
  LCARS_WORKER_CLI=copilot LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoP/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdP" >outP.txt 2>&1
)
check "10d. copilot DEFAULT issue body shows usage \$ band (3.6/7.2)" \
  "grep -q '3.6' '$GH_BODY' && grep -q '7.2' '$GH_BODY'"
check "10d. copilot DEFAULT issue body mentions GitHub AI Credits" \
  "grep -qi 'AI Credits' '$GH_BODY'"
check "10d. copilot DEFAULT issue body is NOT premium requests" \
  "! grep -qi 'premium' '$GH_BODY'"
check "10d. copilot DEFAULT CLI readout shows usage \$ band" \
  "grep -q '3.6' '$repoP/outP.txt'"
unset GH_BODY

# 10f. Copilot active, LEGACY billing (config copilotBilling=legacy): the old
# premium-request rendering returns UNCHANGED for grandfathered annual subscribers.
repoL="$(new_repo)"; make_gh_stub "$repoL/gh"
printf '{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "copilotBilling": "legacy" }\n' \
  >"$repoL/.git/lcars/config.json"
export GH_LOG="$repoL/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoL/gh-body.txt"; : >"$GH_BODY"
prdL="$repoL/prd.md"; write_prd "$prdL"
(
  cd "$repoL"
  LCARS_WORKER_CLI=copilot LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoL/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdL" >outL.txt 2>&1
)
check "10f. copilot LEGACY issue body shows premium requests (198/396)" \
  "grep -q '198' '$GH_BODY' && grep -q '396' '$GH_BODY'"
check "10f. copilot LEGACY issue body mentions premium requests" \
  "grep -qi 'premium' '$GH_BODY'"
check "10f. copilot LEGACY CLI readout shows premium requests" \
  "grep -qi 'premium' '$repoL/outL.txt' && grep -q '198' '$repoL/outL.txt'"
unset GH_BODY

# 10e. complex Mission (adr present) + estimate present ⇒ body order is
# prd → adr → Estimate, each separated by the '---' rule.
repoEA="$(new_repo)"; make_gh_stub "$repoEA/gh"
export GH_LOG="$repoEA/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoEA/gh-body.txt"; : >"$GH_BODY"
prdEA="$repoEA/prd.md"; write_prd "$prdEA"
adrEA="$repoEA/adr.md"; write_adr "$adrEA"
(
  cd "$repoEA"
  CLAUDECODE=1 LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoEA/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdEA" --adr "$adrEA" >outEA.txt 2>&1
)
check "10e. body order prd < adr < Estimate" \
  "[ \"\$(grep -n 'Fix the broken /about route' '$GH_BODY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'Theme delivery via a data-theme attribute' '$GH_BODY' | head -1 | cut -d: -f1)\" ] && [ \"\$(grep -n 'Theme delivery via a data-theme attribute' '$GH_BODY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '## Estimate' '$GH_BODY' | head -1 | cut -d: -f1)\" ]"
check "10e. body has two '---' rules (prd|adr and adr|Estimate)" \
  "[ \"\$(grep -cx -- '---' '$GH_BODY')\" -ge 2 ]"
unset GH_BODY

# --- Behaviour 11: captain model override (--model-override) (S62) ----------
# `lcars file --model-override '<scope>:<tier>'` persists a structured
# modelOverride object into state.json. scope ∈ {all,reasoning,implementation};
# tier ∈ {sonnet,opus}. Malformed values are rejected (nothing written). When an
# override is set AND an estimate is rendered, both captain surfaces (issue body +
# CLI readout) carry an "(override: …)" note so the captain sees the estimate was
# overridden.

# 11a. all:opus ⇒ state.json.modelOverride = { scope:"all", tier:"opus" }.
repoMO="$(new_repo)"; make_gh_stub "$repoMO/gh"
export GH_LOG="$repoMO/gh.log"; : >"$GH_LOG"
prdMO="$repoMO/prd.md"; write_prd "$prdMO"
(
  cd "$repoMO"
  LCARS_GH_BIN="$repoMO/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMO" --model-override 'all:opus' >outMO.txt 2>&1
)
MMO="$repoMO/.git/lcars/missions/lcars-20260530-001/state.json"
check "11a. state.json records modelOverride scope=all" \
  "grep -q '\"scope\": *\"all\"' '$MMO'"
check "11a. state.json records modelOverride tier=opus" \
  "grep -q '\"tier\": *\"opus\"' '$MMO'"

# 11b. implementation:sonnet ⇒ scope=implementation tier=sonnet.
repoMO2="$(new_repo)"; make_gh_stub "$repoMO2/gh"
export GH_LOG="$repoMO2/gh.log"; : >"$GH_LOG"
prdMO2="$repoMO2/prd.md"; write_prd "$prdMO2"
(
  cd "$repoMO2"
  LCARS_GH_BIN="$repoMO2/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMO2" --model-override 'implementation:sonnet' >outMO2.txt 2>&1
)
MMO2="$repoMO2/.git/lcars/missions/lcars-20260530-001/state.json"
check "11b. state.json records scope=implementation tier=sonnet" \
  "grep -q '\"scope\": *\"implementation\"' '$MMO2' && grep -q '\"tier\": *\"sonnet\"' '$MMO2'"

# 11c. NO --model-override ⇒ NO modelOverride key in state.json (degradation).
repoMO3="$(new_repo)"; make_gh_stub "$repoMO3/gh"
export GH_LOG="$repoMO3/gh.log"; : >"$GH_LOG"
prdMO3="$repoMO3/prd.md"; write_prd "$prdMO3"
(
  cd "$repoMO3"
  LCARS_GH_BIN="$repoMO3/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdMO3" >outMO3.txt 2>&1
)
MMO3="$repoMO3/.git/lcars/missions/lcars-20260530-001/state.json"
check "11c. no override ⇒ state.json has no modelOverride key" \
  "! grep -q 'modelOverride' '$MMO3'"

# 11d. malformed override rejected (bad scope) ⇒ exits non-zero, nothing written.
repoMO4="$(new_repo)"; make_gh_stub "$repoMO4/gh"
export GH_LOG="$repoMO4/gh.log"; : >"$GH_LOG"
prdMO4="$repoMO4/prd.md"; write_prd "$prdMO4"
rcMO4=0
(
  cd "$repoMO4"
  LCARS_GH_BIN="$repoMO4/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMO4" --model-override 'bogus:opus' >outMO4.txt 2>&1
) || rcMO4=$?
check "11d. bad scope ⇒ non-zero exit" "[ '$rcMO4' -ne 0 ]"
check "11d. bad scope ⇒ no mission written" \
  "[ ! -d '$repoMO4/.git/lcars/missions/lcars-20260530-001' ]"

# 11e. malformed override rejected (bad tier).
repoMO5="$(new_repo)"; make_gh_stub "$repoMO5/gh"
export GH_LOG="$repoMO5/gh.log"; : >"$GH_LOG"
prdMO5="$repoMO5/prd.md"; write_prd "$prdMO5"
rcMO5=0
(
  cd "$repoMO5"
  LCARS_GH_BIN="$repoMO5/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMO5" --model-override 'all:haiku' >outMO5.txt 2>&1
) || rcMO5=$?
check "11e. bad tier ⇒ non-zero exit" "[ '$rcMO5' -ne 0 ]"

# 11f. override + estimate ⇒ BOTH surfaces show the "(override: …)" note. Uses the
# RICH_STUB (real run.sh render-estimate), claude active.
repoMO6="$(new_repo)"; make_gh_stub "$repoMO6/gh"
export GH_LOG="$repoMO6/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoMO6/gh-body.txt"; : >"$GH_BODY"
prdMO6="$repoMO6/prd.md"; write_prd "$prdMO6"
(
  cd "$repoMO6"
  CLAUDECODE=1 LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoMO6/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMO6" --model-override 'all:opus' >outMO6.txt 2>&1
)
check "11f. issue body shows the override note" \
  "grep -qi 'override' '$GH_BODY' && grep -qi 'Opus' '$GH_BODY'"
check "11f. CLI readout shows the override note" \
  "grep -qi 'override' '$repoMO6/outMO6.txt'"
unset GH_BODY

# --- Behaviour 12: persist the chosen engine (S67) -------------------------
# When the captain picks an engine in the browser File modal, the daemon threads
# it to file.sh as $LCARS_WORKER_BIN. file.sh must persist it into state.json as
# the `workerBin` string field so the board can show it AND `lcars run` can be
# fed it on Start (the engine survives file→persist→start→run end to end). When
# $LCARS_WORKER_BIN is empty/unset, NO workerBin field is written (no regression),
# and state.json stays valid JSON in both cases.

# 12a. LCARS_WORKER_BIN=copilot ⇒ state.json carries "workerBin":"copilot".
repoWB="$(new_repo)"; make_gh_stub "$repoWB/gh"
export GH_LOG="$repoWB/gh.log"; : >"$GH_LOG"
prdWB="$repoWB/prd.md"; write_prd "$prdWB"
(
  cd "$repoWB"
  LCARS_WORKER_BIN=copilot LCARS_GH_BIN="$repoWB/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdWB" >outWB.txt 2>&1
)
MWB="$repoWB/.git/lcars/missions/lcars-20260530-001/state.json"
check "12a. state.json persists workerBin=copilot" \
  "[ -f '$MWB' ] && cat '$MWB' | qgrep -q '\"workerBin\": *\"copilot\"'"
check "12a. state.json is valid JSON (engine set)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MWB'"

# 12b. LCARS_WORKER_BIN unset ⇒ NO workerBin field; state.json still valid JSON.
repoWN="$(new_repo)"; make_gh_stub "$repoWN/gh"
export GH_LOG="$repoWN/gh.log"; : >"$GH_LOG"
prdWN="$repoWN/prd.md"; write_prd "$prdWN"
(
  cd "$repoWN"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repoWN/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdWN" >outWN.txt 2>&1
)
MWN="$repoWN/.git/lcars/missions/lcars-20260530-001/state.json"
check "12b. no engine ⇒ state.json has no workerBin field" \
  "[ -f '$MWN' ] && ! cat '$MWN' | qgrep -q 'workerBin'"
check "12b. state.json is valid JSON (engine unset)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MWN'"

# ==========================================================================
[ "$fail" -eq 0 ]
