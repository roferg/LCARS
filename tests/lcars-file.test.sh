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

# S128 — the precedence sentence prd.md must carry, READ OUT OF THE DAEMON
# (web/lcars_serve/actions.py `_HANDOFF_PRECEDENCE`), which is its authority.
# Pinning against the daemon's own literal instead of a copy typed here is the
# whole point: the two homes drifted once already (FL-011 — the daemon was
# reworded, skills/lcars-init/lcars-common.sh was not, and ONE prd.md carried
# both spellings). Still byte-exact, just no longer independently spelled.
PRECEDENCE="$(cd "$REPO_ROOT/web" 2>/dev/null && python3 -c 'import sys; sys.path.insert(0, "."); from lcars_serve.actions import _HANDOFF_PRECEDENCE as p; sys.stdout.write(p)' 2>/dev/null)"

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
# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

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

# S196 — `cloneId` PINS THE FINGERPRINT so this suite's expected ids stay
# literal. Mission ids are now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the
# first 4 hex of the clone's own `cloneId` (minted as a UUID4 on first use, so
# two clones of one repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning cloneId here makes <fp> the
# constant `c10e`. The LAZY acquisition path, the two-real-clones proof and the
# old-format compatibility guarantee all live in tests/mission-id.test.sh.
# Build an isolated git repo with .git/lcars/ already scaffolded. An initial
# commit exists so `lcars file` can branch off it (a Mission gets its own branch
# at filing time) — matching how `lcars file` is run in a real, non-empty repo.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  # S183: a CONFIGURED test command, so this fixture is a repo with a test
  # FOUNDATION. `lcars file` now refuses to open a normal mission on a repo that
  # has none (greenfield/untested) and points at Establish Vision instead — so a
  # suite about the MECHANICS of filing has to file against a repo that can
  # actually be filed against. `true` resolves via `command -v`, which is all the
  # readiness verdict asks of a command. The gate itself is proven in
  # tests/foundation-gate.test.sh, against real repos in all four states.
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
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
check "1. creates mission dir named lcars-20260530-001-c10e" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-001-c10e' ]"
check "1. summary reports the mission ID" \
  "grep -q 'lcars-20260530-001-c10e' '$repo/out.txt'"

# second mission the same day increments to -002
prd2="$repo/prd-in2.md"; write_prd "$prd2"
(
  cd "$repo"
  LCARS_GH_BIN="$repo/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prd2" >out2.txt 2>&1
)
check "1. second mission increments to lcars-20260530-002-c10e" \
  "[ -d '$repo/.git/lcars/missions/lcars-20260530-002-c10e' ]"

# --- Behaviour 2: directory structure -------------------------------------
M="$repo/.git/lcars/missions/lcars-20260530-001-c10e"
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
check "4. state.json id matches"      "grep -q '\"lcars-20260530-001-c10e\"' '$M/state.json'"
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
  "[ -d '$repoG/.git/lcars/missions/lcars-20260530-001-c10e' ]"
check "5. records githubIssue null when gh missing" \
  "grep -q '\"githubIssue\": *null' '$repoG/.git/lcars/missions/lcars-20260530-001-c10e/state.json'"

# --- Behaviour 6: confirmation summary ------------------------------------
check "6. summary: Mission filed line"  "grep -q 'Mission filed:.*lcars-20260530-001-c10e' '$repo/out.txt'"
check "6. summary: GitHub issue line"   "grep -q 'GitHub issue:.*#42' '$repo/out.txt'"
check "6. summary: Stage align line"    "grep -qi 'Stage:.*align' '$repo/out.txt'"
check "6. summary: Next lcars run line" "grep -q 'lcars run lcars-20260530-001-c10e' '$repo/out.txt'"

# --- Behaviour 7: the Mission gets its own branch -------------------------
# vision.md: each Mission gets its own branch. `lcars file` creates lcars/<id>
# off the current branch and records it (with the base) in state.json, so
# Implement can commit to it and `lcars approve` can push it + open the PR.
EXP_BASE="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
check "7. creates the branch lcars/<mission-id>" \
  "( cd '$repo' && git show-ref --verify --quiet 'refs/heads/lcars/lcars-20260530-001-c10e' )"
check "7. does not switch the working tree off the base branch" \
  "[ \"\$(cd '$repo' && git rev-parse --abbrev-ref HEAD)\" = '$EXP_BASE' ]"
check "7. records the branch in state.json" \
  "grep -q '\"branch\": *\"lcars/lcars-20260530-001-c10e\"' '$M/state.json'"
check "7. records the base in state.json" \
  "grep -q '\"base\": *\"$EXP_BASE\"' '$M/state.json'"
check "7. summary reports the branch" \
  "grep -q 'Branch:.*lcars/lcars-20260530-001-c10e' '$repo/out.txt'"

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
MT="$repoT/.git/lcars/missions/lcars-20260530-001-c10e"
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
MC="$repoC/.git/lcars/missions/lcars-20260530-001-c10e"
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
MBody="$repoBody/.git/lcars/missions/lcars-20260530-001-c10e"
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
# S147 DEFECT-3: copilot pins every stage to opus (alias_for_tier), so the band
# is now costed at opus rates — 4.23/8.46 where it used to under-report 3.6/7.2.
check "10d. copilot DEFAULT issue body shows usage \$ band (4.2/8.4)" \
  "grep -q '4.2' '$GH_BODY' && grep -q '8.4' '$GH_BODY'"
check "10d. copilot DEFAULT issue body mentions GitHub AI Credits" \
  "grep -qi 'AI Credits' '$GH_BODY'"
check "10d. copilot DEFAULT issue body is NOT premium requests" \
  "! grep -qi 'premium' '$GH_BODY'"
check "10d. copilot DEFAULT CLI readout shows usage \$ band" \
  "grep -q '4.2' '$repoP/outP.txt'"
unset GH_BODY

# 10f. Copilot active, LEGACY billing (config copilotBilling=legacy): the old
# premium-request rendering returns UNCHANGED for grandfathered annual subscribers.
repoL="$(new_repo)"; make_gh_stub "$repoL/gh"
# S183: keeps new_repo's testCommand — this rewrite of the config would
# otherwise strip the repo's test foundation and `lcars file` would refuse.
printf '{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "copilotBilling": "legacy" }\n' \
  >"$repoL/.git/lcars/config.json"
export GH_LOG="$repoL/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoL/gh-body.txt"; : >"$GH_BODY"
prdL="$repoL/prd.md"; write_prd "$prdL"
(
  cd "$repoL"
  LCARS_WORKER_CLI=copilot LCARS_RUN_BIN="$RICH_STUB" \
    LCARS_GH_BIN="$repoL/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdL" >outL.txt 2>&1
)
# S147 DEFECT-3: all-opus multiplier ⇒ 270/540, not the old mixed-tier 198/396.
check "10f. copilot LEGACY issue body shows premium requests (270/540)" \
  "grep -q '270' '$GH_BODY' && grep -q '540' '$GH_BODY'"
check "10f. copilot LEGACY issue body mentions premium requests" \
  "grep -qi 'premium' '$GH_BODY'"
check "10f. copilot LEGACY CLI readout shows premium requests" \
  "grep -qi 'premium' '$repoL/outL.txt' && grep -q '270' '$repoL/outL.txt'"
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
MMO="$repoMO/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
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
MMO2="$repoMO2/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
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
MMO3="$repoMO3/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
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
  "[ ! -d '$repoMO4/.git/lcars/missions/lcars-20260530-001-c10e' ]"

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
MWB="$repoWB/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
# THE PATTERN ACCEPTS A PATH (S222), and every `copilot` row below does too.
# These rows assert WHICH ENGINE was persisted, not how many letters it took to
# say it. A mission now records the real CLI's ABSOLUTE PATH whenever the bare
# name would resolve to VS Code's fork-bomb shim — which it does on any machine
# with the Copilot extension installed, so the literal string `"copilot"` made
# the result depend on the developer's own PATH. `claude` rows are untouched:
# nothing normalises claude. The rule itself, both directions, is proved in
# tests/lcars-worker-guard.test.sh (the S222 block).
check "12a. state.json persists workerBin=copilot" \
  "[ -f '$MWB' ] && cat '$MWB' | qgrep -q '\"workerBin\": *\"[^\"]*copilot\"'"
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
MWN="$repoWN/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "12b. no engine ⇒ state.json has no workerBin field" \
  "[ -f '$MWN' ] && ! cat '$MWN' | qgrep -q 'workerBin'"
check "12b. state.json is valid JSON (engine unset)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MWN'"

# --- Behaviour 13: durable image attachments (--attach) (S92) --------------
# `lcars file --attach <img>` (repeatable) copies each image into the mission's
# attachments/ dir under a STABLE name (attachment-NN.<ext>), references each by
# RELATIVE path in prd.md under a `## Attached images` section, and records the
# relative paths in state.json as an "attachments" array. With NO --attach,
# nothing changes: no attachments/ dir, no prd.md section, no state.json key.

# 13a. one --attach ⇒ staged file + prd.md ref + state.json array.
repoAT="$(new_repo)"; make_gh_stub "$repoAT/gh"
export GH_LOG="$repoAT/gh.log"; : >"$GH_LOG"
prdAT="$repoAT/prd.md"; write_prd "$prdAT"
imgAT="$repoAT/shot.png"; printf 'PNGDATA-AT' >"$imgAT"
rcAT=0
(
  cd "$repoAT"
  LCARS_GH_BIN="$repoAT/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdAT" --attach "$imgAT" >outAT.txt 2>&1
) || rcAT=$?
MAT="$repoAT/.git/lcars/missions/lcars-20260530-001-c10e"
check "13a. file with --attach succeeds" "[ '$rcAT' -eq 0 ]"
check "13a. attachments/attachment-01.png is staged" \
  "[ -f '$MAT/attachments/attachment-01.png' ]"
check "13a. staged bytes match the source image" \
  "[ \"\$(cat '$MAT/attachments/attachment-01.png')\" = 'PNGDATA-AT' ]"
check "13a. prd.md has the '## Attached images' section" \
  "grep -q '## Attached images' '$MAT/prd.md'"
check "13a. prd.md references the attachment by RELATIVE path" \
  "grep -q 'attachments/attachment-01.png' '$MAT/prd.md'"
check "13a. state.json lists the attachment (relative path)" \
  "grep -q '\"attachments\": *\\[ *\"attachments/attachment-01.png\"' '$MAT/state.json'"
check "13a. state.json is valid JSON (attachment set)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MAT/state.json'"

# 13b. two --attach ⇒ both staged, both listed, names increment by order.
repoAT2="$(new_repo)"; make_gh_stub "$repoAT2/gh"
export GH_LOG="$repoAT2/gh.log"; : >"$GH_LOG"
prdAT2="$repoAT2/prd.md"; write_prd "$prdAT2"
imgA="$repoAT2/a.png"; printf 'AAA' >"$imgA"
imgB="$repoAT2/b.jpg"; printf 'BBB' >"$imgB"
(
  cd "$repoAT2"
  LCARS_GH_BIN="$repoAT2/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdAT2" --attach "$imgA" --attach "$imgB" >outAT2.txt 2>&1
)
MAT2="$repoAT2/.git/lcars/missions/lcars-20260530-001-c10e"
check "13b. first attachment keeps its .png ext" \
  "[ -f '$MAT2/attachments/attachment-01.png' ]"
check "13b. second attachment keeps its .jpg ext (order-numbered)" \
  "[ -f '$MAT2/attachments/attachment-02.jpg' ]"
check "13b. state.json lists both attachments" \
  "grep -q 'attachment-01.png' '$MAT2/state.json' && grep -q 'attachment-02.jpg' '$MAT2/state.json'"

# 13c. NO --attach ⇒ no attachments/ dir, no prd.md section, no state.json key.
repoAT3="$(new_repo)"; make_gh_stub "$repoAT3/gh"
export GH_LOG="$repoAT3/gh.log"; : >"$GH_LOG"
prdAT3="$repoAT3/prd.md"; write_prd "$prdAT3"
(
  cd "$repoAT3"
  LCARS_GH_BIN="$repoAT3/gh" LCARS_DATE="20260530" bash "$SCRIPT" --prd "$prdAT3" >outAT3.txt 2>&1
)
MAT3="$repoAT3/.git/lcars/missions/lcars-20260530-001-c10e"
check "13c. no --attach ⇒ no attachments/ dir" "[ ! -d '$MAT3/attachments' ]"
check "13c. no --attach ⇒ prd.md has no Attached images section" \
  "! grep -q '## Attached images' '$MAT3/prd.md'"
check "13c. no --attach ⇒ state.json has no attachments key" \
  "! grep -q 'attachments' '$MAT3/state.json'"

# 13d. a missing --attach file is rejected before anything is written.
repoAT4="$(new_repo)"; make_gh_stub "$repoAT4/gh"
export GH_LOG="$repoAT4/gh.log"; : >"$GH_LOG"
prdAT4="$repoAT4/prd.md"; write_prd "$prdAT4"
rcAT4=0
(
  cd "$repoAT4"
  LCARS_GH_BIN="$repoAT4/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdAT4" --attach "$repoAT4/nope.png" >outAT4.txt 2>&1
) || rcAT4=$?
check "13d. missing attachment ⇒ non-zero exit" "[ '$rcAT4' -ne 0 ]"
check "13d. missing attachment ⇒ no mission written" \
  "[ ! -d '$repoAT4/.git/lcars/missions/lcars-20260530-001-c10e' ]"

# 13e. FL-010 — a holodeck hand-off travels this SAME --attach road, and prd.md
# is the mission's own document AND the GitHub issue body. Heading an HTML
# mockup "## Attached images" is a lie in the one document every downstream
# stage reads. S127 made run.sh's cold-prompt heading adaptive and MISSED this
# copy; the wording now comes from ONE shared rule (lcars_attach_prd_section in
# lcars-init/lcars-common.sh), so both surfaces move together or neither does.
repoMK="$(new_repo)"; make_gh_stub "$repoMK/gh"
export GH_LOG="$repoMK/gh.log"; : >"$GH_LOG"
prdMK="$repoMK/prd.md"; write_prd "$prdMK"
mockMK="$repoMK/mockup.html";  printf '<!doctype html>' >"$mockMK"
concMK="$repoMK/concept.md";   printf '# concept'       >"$concMK"
rcMK=0
(
  cd "$repoMK"
  LCARS_GH_BIN="$repoMK/gh" LCARS_DATE="20260530" bash "$SCRIPT" \
    --prd "$prdMK" --attach "$mockMK" --attach "$concMK" >outMK.txt 2>&1
) || rcMK=$?
MMK="$repoMK/.git/lcars/missions/lcars-20260530-001-c10e"
check "13e. file with a mockup + concept doc succeeds" "[ '$rcMK' -eq 0 ]"
check "13e. prd.md does NOT call an HTML mockup an image" \
  "! grep -q '## Attached images' '$MMK/prd.md'"
check "13e. prd.md heading names what actually arrived" \
  "grep -q '## Attached files' '$MMK/prd.md'"
check "13e. prd.md counts the mockup" \
  "grep -qi 'mockup' '$MMK/prd.md'"
check "13e. prd.md counts the written document" \
  "grep -qi 'document' '$MMK/prd.md'"
check "13e. prd.md declares the mockup LOOK AND FLOW only" \
  "grep -q 'LOOK AND FLOW' '$MMK/prd.md'"
check "13e. the daemon's precedence sentence is readable" "[ -n \"\$PRECEDENCE\" ]"
check "13e. prd.md carries the precedence rule VERBATIM" \
  "[ -n \"\$PRECEDENCE\" ] && grep -qF \"\$PRECEDENCE\" '$MMK/prd.md'"
check "13e. prd.md still lists both by RELATIVE path" \
  "grep -q '^- attachments/attachment-01.html\$' '$MMK/prd.md' && grep -q '^- attachments/attachment-02.md\$' '$MMK/prd.md'"

# 13f. …and the IMAGE-ONLY wording is untouched, BYTE FOR BYTE. This is shared
# pipeline code and the overwhelming majority of missions are pasted
# screenshots; their PRD must not move by one character. If this assertion has
# to be "updated" to pass, the change was not additive.
IMG_SECTION="$(printf '\n## Attached images\n\n- attachments/attachment-01.png\n- attachments/attachment-02.jpg\n')"
GOT_SECTION="$(cd "$repoAT2" && python3 - "$MAT2/prd.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.index('\n## Attached')
sys.stdout.write(t[i:])
PY
)"
check "13f. image-only prd.md section is BYTE-IDENTICAL to the pre-S128 string" \
  "[ \"\$GOT_SECTION\" = \"\$IMG_SECTION\" ]"

# --- Behaviour 14: --engine on the GRILL-FIRST (--prd) lane (S147 DEFECT-1) --
# `--engine claude|copilot` is the captain's EXPLICIT engine pin. It was honoured
# only on the park lane (do_park), and silently ignored on the grill-first --prd
# lane — so `lcars file --prd X --engine copilot` filed a mission with NO
# workerBin and it then ran on the host-detected engine (real billed spend on the
# wrong engine), while a bogus engine filed successfully instead of dying. Both
# lanes must now share ONE validation + ONE precedence rule:
#   --engine wins > $LCARS_WORKER_BIN > (nothing ⇒ no workerBin key)
# and a bogus --engine dies BEFORE anything is written, on BOTH lanes.

# 14a. --prd + --engine copilot ⇒ state.json carries workerBin=copilot.
repoEN="$(new_repo)"; make_gh_stub "$repoEN/gh"
export GH_LOG="$repoEN/gh.log"; : >"$GH_LOG"
prdEN="$repoEN/prd.md"; write_prd "$prdEN"
rcEN=0
(
  cd "$repoEN"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repoEN/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdEN" --engine copilot >outEN.txt 2>&1
) || rcEN=$?
MEN="$repoEN/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14a. --prd --engine copilot exits clean" "[ '$rcEN' -eq 0 ]"
check "14a. --prd --engine copilot persists workerBin=copilot" \
  "[ -f '$MEN' ] && cat '$MEN' | qgrep -q '\"workerBin\": *\"[^\"]*copilot\"'"
check "14a. state.json is valid JSON (--engine set)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MEN'"

# 14b. --engine BEATS a conflicting $LCARS_WORKER_BIN (explicit > threaded).
repoEN2="$(new_repo)"; make_gh_stub "$repoEN2/gh"
export GH_LOG="$repoEN2/gh.log"; : >"$GH_LOG"
prdEN2="$repoEN2/prd.md"; write_prd "$prdEN2"
(
  cd "$repoEN2"
  LCARS_WORKER_BIN=claude LCARS_GH_BIN="$repoEN2/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdEN2" --engine copilot >outEN2.txt 2>&1
)
MEN2="$repoEN2/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14b. --engine copilot beats LCARS_WORKER_BIN=claude" \
  "[ -f '$MEN2' ] && cat '$MEN2' | qgrep -q '\"workerBin\": *\"[^\"]*copilot\"'"

# 14c. a bogus --engine is REJECTED on the --prd lane, nothing written.
repoEN3="$(new_repo)"; make_gh_stub "$repoEN3/gh"
export GH_LOG="$repoEN3/gh.log"; : >"$GH_LOG"
prdEN3="$repoEN3/prd.md"; write_prd "$prdEN3"
rcEN3=0
(
  cd "$repoEN3"
  LCARS_GH_BIN="$repoEN3/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdEN3" --engine totally-bogus >outEN3.txt 2>&1
) || rcEN3=$?
check "14c. bogus --engine on --prd ⇒ non-zero exit" "[ '$rcEN3' -ne 0 ]"
check "14c. bogus --engine on --prd ⇒ names the engine in the error" \
  "grep -q \"unknown engine 'totally-bogus'\" '$repoEN3/outEN3.txt'"
check "14c. bogus --engine on --prd ⇒ no mission written" \
  "[ ! -d '$repoEN3/.git/lcars/missions/lcars-20260530-001-c10e' ]"

# 14d. no --engine and no $LCARS_WORKER_BIN ⇒ still NO workerBin key (unchanged).
repoEN4="$(new_repo)"; make_gh_stub "$repoEN4/gh"
export GH_LOG="$repoEN4/gh.log"; : >"$GH_LOG"
prdEN4="$repoEN4/prd.md"; write_prd "$prdEN4"
(
  cd "$repoEN4"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repoEN4/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdEN4" >outEN4.txt 2>&1
)
MEN4="$repoEN4/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14d. no engine at all ⇒ no workerBin key" \
  "[ -f '$MEN4' ] && ! cat '$MEN4' | qgrep -q 'workerBin'"

# 14e. --engine claude is accepted too (both valid values, not just copilot).
repoEN5="$(new_repo)"; make_gh_stub "$repoEN5/gh"
export GH_LOG="$repoEN5/gh.log"; : >"$GH_LOG"
prdEN5="$repoEN5/prd.md"; write_prd "$prdEN5"
(
  cd "$repoEN5"
  LCARS_WORKER_BIN=copilot LCARS_GH_BIN="$repoEN5/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdEN5" --engine claude >outEN5.txt 2>&1
)
MEN5="$repoEN5/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14e. --engine claude beats LCARS_WORKER_BIN=copilot" \
  "[ -f '$MEN5' ] && cat '$MEN5' | qgrep -q '\"workerBin\": *\"claude\"'"

# --- Behaviour 14f-14i: --engine on the FRONT DOOR's lane (S195) -----------
# The Establish Vision front door files through `--initialization --prd`, which
# is the SAME grill-first lane 14a-14e cover — and that lane is the one file.sh's
# own header records as having "silently ignored" --engine once already. So the
# combination the day-zero captain actually walks through is asserted HARD here:
# a mission filed from the front door on the engine he picked, running on the
# engine he picked, on a repo with NO test foundation (which is the only kind of
# repo that door ever appears on).
gf_repo() { # a repo with NO foundation — what the front door is for
  local repo; repo="$(mktemp -d "$TMPROOT/gfrepo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  # S196 — this repo deliberately has NO config.json, so the clone fingerprint
  # has nowhere canonical to live; lcars_clone_id falls back to the
  # `<lcars-dir>/clone-id` BRIDGE file. Seeding it pins the fingerprint the same
  # way new_repo's cloneId does, and incidentally exercises that fallback.
  printf 'c10ec10ec10ec10ec10ec10ec10ec10e\n' >"$repo/.git/lcars/clone-id"
  echo "$repo"
}

repoIN="$(gf_repo)"; make_gh_stub "$repoIN/gh"
export GH_LOG="$repoIN/gh.log"; : >"$GH_LOG"
prdIN="$repoIN/prd.md"; write_prd "$prdIN"
rcIN=0
(
  cd "$repoIN"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repoIN/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --initialization --prd "$prdIN" --engine copilot >outIN.txt 2>&1
) || rcIN=$?
MIN="$repoIN/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14f. --initialization --prd --engine copilot exits clean" "[ '$rcIN' -eq 0 ]"
check "14f. the FRONT DOOR's mission persists workerBin=copilot" \
  "[ -f '$MIN' ] && cat '$MIN' | qgrep -q '\"workerBin\": *\"[^\"]*copilot\"'"
check "14f. …and is still stamped missionType=initialization" \
  "cat '$MIN' | qgrep -q '\"missionType\": *\"initialization\"'"
check "14f. state.json is valid JSON (initialization + engine)" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MIN'"

# 14g. …and it BEATS a threaded $LCARS_WORKER_BIN. The daemon injects its own
# worker_bin into every dispatch (`_resolve_run`), so on the viewscreen road the
# env var is ALWAYS set — if the flag lost to it, the captain's pick would be
# silently replaced by whatever CLI the daemon happened to be launched from.
repoIN2="$(gf_repo)"; make_gh_stub "$repoIN2/gh"
export GH_LOG="$repoIN2/gh.log"; : >"$GH_LOG"
prdIN2="$repoIN2/prd.md"; write_prd "$prdIN2"
(
  cd "$repoIN2"
  LCARS_WORKER_BIN=claude LCARS_GH_BIN="$repoIN2/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --initialization --prd "$prdIN2" --engine copilot >outIN2.txt 2>&1
)
MIN2="$repoIN2/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14g. --engine beats the daemon-threaded LCARS_WORKER_BIN on this lane" \
  "[ -f '$MIN2' ] && cat '$MIN2' | qgrep -q '\"workerBin\": *\"[^\"]*copilot\"'"

# 14h. a bogus engine dies on this lane too, before anything is written.
repoIN3="$(gf_repo)"; make_gh_stub "$repoIN3/gh"
export GH_LOG="$repoIN3/gh.log"; : >"$GH_LOG"
prdIN3="$repoIN3/prd.md"; write_prd "$prdIN3"
rcIN3=0
(
  cd "$repoIN3"
  LCARS_GH_BIN="$repoIN3/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --initialization --prd "$prdIN3" --engine gpt5 >outIN3.txt 2>&1
) || rcIN3=$?
check "14h. bogus --engine on the initialization lane ⇒ non-zero exit" \
  "[ '$rcIN3' -ne 0 ]"
check "14h. …and nothing was written" \
  "[ ! -d '$repoIN3/.git/lcars/missions/lcars-20260530-001-c10e' ]"

# 14i. REGRESSION — an initialization filing with no engine is unchanged.
repoIN4="$(gf_repo)"; make_gh_stub "$repoIN4/gh"
export GH_LOG="$repoIN4/gh.log"; : >"$GH_LOG"
prdIN4="$repoIN4/prd.md"; write_prd "$prdIN4"
(
  cd "$repoIN4"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repoIN4/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --initialization --prd "$prdIN4" >outIN4.txt 2>&1
)
MIN4="$repoIN4/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "14i. no --engine on the initialization lane ⇒ no workerBin key" \
  "[ -f '$MIN4' ] && ! cat '$MIN4' | qgrep -q 'workerBin'"

# ==========================================================================
# 15. THE PRD's REQUIRED SECTIONS IN BOTH SHAPES (S176)
#
# MEASURED on the captain's own repo (DX-Scorecard, `lcars-20260827-001`): he
# designed in the holodeck, completed a FULL Align grill, sent it for costing —
# and file.sh refused, because the Align agent wrote the PRD with MARKDOWN
# HEADINGS instead of the bold inline labels. The heading form fails ALL SIX
# checks. He lost two completed grill sessions to it. The refusal was right
# about the shape and wrong about what a PRD is: the heading form says exactly
# the same six things.
#
# THE TRAP THIS PINS: validation and EXTRACTION must agree. Accepting a
# heading-form PRD and then deriving an EMPTY title or type would replace a loud
# failure with a silent one — strictly worse. So every case below asserts the
# DERIVED title and type, never merely that filing exited 0.

# The captain's exact failing shape: a bare `Mission:` title line with no `#`,
# then each label as a heading with its value on the following line.
write_prd_headings() {
  cat >"$1" <<'EOF'
Mission: MBR builder — mockup-driven Reviews flow

Type
feature
Goal
Rebuild the MBR builder to match the mockup.
Acceptance Criteria
- Reviews screen replaces the direct-to-editor entry.
Out of Scope
- Per-bucket lock model.
Constraints
- Match the attached mockup.
EOF
}

repoH1="$(new_repo)"; make_gh_stub "$repoH1/gh"
export GH_LOG="$repoH1/gh.log"; : >"$GH_LOG"
prdH1="$repoH1/prd-h.md"; write_prd_headings "$prdH1"
(
  cd "$repoH1"
  LCARS_GH_BIN="$repoH1/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH1" >outH1.txt 2>&1
)
MH1="$repoH1/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "15a. the captain's HEADING-FORM PRD files (was: refused on all six)" \
  "[ -f '$MH1' ]"
check "15b. …and the TITLE is EXTRACTED from the heading, not empty" \
  "[ -f '$MH1' ] && cat '$MH1' | qgrep -q '\"title\": \"MBR builder — mockup-driven Reviews flow\"'"
check "15c. …and the TYPE is EXTRACTED from the heading, not empty" \
  "[ -f '$MH1' ] && cat '$MH1' | qgrep -q '\"type\": \"feature\"'"
check "15d. …and the issue carries the derived title + lcars:feature label" \
  "grep -q 'MBR builder' '$repoH1/gh.log' && grep -q 'lcars:feature' '$repoH1/gh.log'"
check "15e. …and prd.md is the PRD verbatim" \
  "grep -q '^Mission: MBR builder' '$repoH1/.git/lcars/missions/lcars-20260530-001-c10e/prd.md'"

# 15f. The HASHED heading variant (`## Type`), same derivation.
repoH2="$(new_repo)"; make_gh_stub "$repoH2/gh"
export GH_LOG="$repoH2/gh.log"; : >"$GH_LOG"
prdH2="$repoH2/prd-h2.md"
cat >"$prdH2" <<'EOF'
# Mission: Fix the broken /about route

## Type

bug

## Goal

The /about route should resolve to the About page.

## Acceptance Criteria

- GET /about returns HTTP 200

## Out of Scope

- Redesigning the About page

## Constraints

- Existing router
EOF
(
  cd "$repoH2"
  LCARS_GH_BIN="$repoH2/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH2" >outH2.txt 2>&1
)
MH2="$repoH2/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "15f. the hashed-heading (## Type) form files too" "[ -f '$MH2' ]"
check "15g. …with the title off the hashed Mission line" \
  "[ -f '$MH2' ] && cat '$MH2' | qgrep -q '\"title\": \"Fix the broken /about route\"'"
check "15h. …and type 'bug' read from the line UNDER the heading" \
  "[ -f '$MH2' ] && cat '$MH2' | qgrep -q '\"type\": \"bug\"'"

# 15i. The BOLD form keeps working EXACTLY as it did — both derivations too.
repoH3="$(new_repo)"; make_gh_stub "$repoH3/gh"
export GH_LOG="$repoH3/gh.log"; : >"$GH_LOG"
prdH3="$repoH3/prd-b.md"; write_prd "$prdH3"
(
  cd "$repoH3"
  LCARS_GH_BIN="$repoH3/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH3" >outH3.txt 2>&1
)
MH3="$repoH3/.git/lcars/missions/lcars-20260530-001-c10e/state.json"
check "15i. the BOLD form still derives its title" \
  "[ -f '$MH3' ] && cat '$MH3' | qgrep -q '\"title\": \"Fix the broken /about route\"'"
check "15j. …and its type" \
  "[ -f '$MH3' ] && cat '$MH3' | qgrep -q '\"type\": \"bug\"'"

# 15k/l. THE GATE IS STILL A GATE. A PRD genuinely missing a section is still
# refused — accepting both shapes must not become accepting anything.
repoH4="$(new_repo)"; make_gh_stub "$repoH4/gh"
export GH_LOG="$repoH4/gh.log"; : >"$GH_LOG"
prdH4="$repoH4/prd-x.md"
cat >"$prdH4" <<'EOF'
Mission: A mission with no constraints at all

Type
feature
Goal
Do a thing.
Acceptance Criteria
- it works
Out of Scope
- everything else
EOF
rcH4=0
(
  cd "$repoH4"
  LCARS_GH_BIN="$repoH4/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH4" >outH4.txt 2>&1
) || rcH4=$?
check "15k. a PRD with NO Constraints section is still REFUSED" "[ '$rcH4' -ne 0 ]"
check "15l. …naming Constraints, and writing nothing" \
  "grep -q \"missing the 'Constraints' section\" '$repoH4/outH4.txt' && [ ! -d '$repoH4/.git/lcars/missions/lcars-20260530-001-c10e' ]"

# 15m/n. A heading-form PRD whose title line carries NO title fails LOUDLY at
# extraction — never silently with an empty title. This is the whole risk of
# accepting a second shape, so it is pinned.
repoH5="$(new_repo)"; make_gh_stub "$repoH5/gh"
export GH_LOG="$repoH5/gh.log"; : >"$GH_LOG"
prdH5="$repoH5/prd-t.md"
cat >"$prdH5" <<'EOF'
Mission:

Type
feature
Goal
Do a thing.
Acceptance Criteria
- it works
Out of Scope
- everything else
Constraints
- none
EOF
rcH5=0
(
  cd "$repoH5"
  LCARS_GH_BIN="$repoH5/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH5" >outH5.txt 2>&1
) || rcH5=$?
check "15m. a titleless PRD is refused LOUDLY, not filed with an empty title" \
  "[ '$rcH5' -ne 0 ] && [ ! -d '$repoH5/.git/lcars/missions/lcars-20260530-001-c10e' ]"
check "15n. …with the extraction's own message" \
  "grep -q 'could not read the Mission title' '$repoH5/outH5.txt'"

# 15o/p. …and a heading-form PRD whose Type is not feature|bug is refused with
# the real value, not "empty" — proof extraction ran on the heading shape.
repoH6="$(new_repo)"; make_gh_stub "$repoH6/gh"
export GH_LOG="$repoH6/gh.log"; : >"$GH_LOG"
prdH6="$repoH6/prd-y.md"
cat >"$prdH6" <<'EOF'
Mission: A mission of the wrong type

Type
chore
Goal
Do a thing.
Acceptance Criteria
- it works
Out of Scope
- everything else
Constraints
- none
EOF
rcH6=0
(
  cd "$repoH6"
  LCARS_GH_BIN="$repoH6/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdH6" >outH6.txt 2>&1
) || rcH6=$?
check "15o. a heading-form Type outside feature|bug is refused" "[ '$rcH6' -ne 0 ]"
check "15p. …quoting the value it EXTRACTED ('chore'), not 'empty'" \
  "grep -q \"got: 'chore'\" '$repoH6/outH6.txt'"

# ==========================================================================
# 16. THE S175 QUESTIONS GATE RUNS ON THE --complete LANE TOO (S176)
#
# MEASURED: `_validate_prd` forwards `"${@:2}"` to lcars_prd_questions_gate, and
# do_complete called it with NO attachment arguments — so the gate saw no design
# brief, found no open questions, and returned 0 for EVERY PRD. The whole
# park→grill→--complete lane (the one the viewscreen's holodeck hand-off uses)
# had the gate silently disabled. On the captain's real mission his PRD came
# back clean here and refused correctly the moment the staged brief was handed
# over. The brief is MISSION-RELATIVE on this lane — park already staged it.

BRIEF_2SEC='# MBR builder

## Open questions

- What makes a KPI "carried"?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements

1. (T1) Render the builder screen.

### 2. Implied by the mockup, not yet settled

- What do Preview and View actually do?
'

# Park a mission WITH the design brief staged as an attachment.
repoQ="$(new_repo)"; make_gh_stub "$repoQ/gh"
export GH_LOG="$repoQ/gh.log"; : >"$GH_LOG"
briefQ="$repoQ/concept.md"; printf '%s' "$BRIEF_2SEC" >"$briefQ"
(
  cd "$repoQ"
  LCARS_GH_BIN="$repoQ/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --park "rebuild the MBR builder" --attach "$briefQ" >outQ0.txt 2>&1
)
MQ="$repoQ/.git/lcars/missions/lcars-20260530-001-c10e"
check "16a. the parked mission staged the brief" "[ -f '$MQ/attachments/attachment-01.md' ]"

prdQdrop="$repoQ/prd-drop.md"; write_prd "$prdQdrop"
rcQ1=0
(
  cd "$repoQ"
  LCARS_GH_BIN="$repoQ/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdQdrop" >outQ1.txt 2>&1
) || rcQ1=$?
check "16b. --complete REFUSES a PRD that drops the staged brief's questions" \
  "[ '$rcQ1' -ne 0 ]"
check "16c. …naming a dropped question from ## Open questions" \
  "grep -q 'What makes a KPI' '$repoQ/outQ1.txt'"
check "16d. …AND one from bucket 2 of ## WHAT IT MUST DO" \
  "grep -q 'What do Preview and View actually do' '$repoQ/outQ1.txt'"
check "16e. …and the refusal writes NOTHING (mission still parked)" \
  "[ ! -f '$MQ/prd.md' ] && cat '$MQ/state.json' | qgrep -q '\"prdPending\": true'"

# The same lane, with the questions carried: it completes.
prdQok="$repoQ/prd-ok.md"
{ write_prd "$prdQok"; cat >>"$prdQok" <<'EOF'

## Open questions from the design session

- STILL OPEN: What makes a KPI "carried"?
- STILL OPEN: What do Preview and View actually do?
EOF
}
(
  cd "$repoQ"
  LCARS_GH_BIN="$repoQ/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdQok" >outQ2.txt 2>&1
)
check "16f. …and a PRD that CARRIES them completes the mission" \
  "[ -f '$MQ/prd.md' ] && cat '$MQ/state.json' | qgrep -q '\"stage\": \"align\"' && ! cat '$MQ/state.json' | qgrep -q '\"prdPending\": true'"

# 16g. A parked mission with NO brief is untouched — the gate stays a no-op.
repoQ2="$(new_repo)"; make_gh_stub "$repoQ2/gh"
export GH_LOG="$repoQ2/gh.log"; : >"$GH_LOG"
(
  cd "$repoQ2"
  LCARS_GH_BIN="$repoQ2/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --park "just an idea" >outQ3.txt 2>&1
)
prdQ2="$repoQ2/prd.md"; write_prd "$prdQ2"
(
  cd "$repoQ2"
  LCARS_GH_BIN="$repoQ2/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdQ2" >outQ4.txt 2>&1
)
check "16g. a parked mission with NO design brief completes untouched" \
  "[ -f '$repoQ2/.git/lcars/missions/lcars-20260530-001-c10e/prd.md' ]"

# ==========================================================================
# 17. ON A VALIDATION FAILURE THE AGENT FIXES THE PRD — IT NEVER RE-GRILLS
#
# The cost the captain actually paid was not the refusal (file.sh refuses
# cleanly and writes nothing — correct). It was the Align agent's RESPONSE:
# it restarted the whole grill. A completed alignment thrown away over a
# heading. SKILL.md must say so, in the shape the agent will actually meet.
SKILL_MD="$REPO_ROOT/skills/lcars-file/SKILL.md"
check "17a. SKILL.md forbids re-grilling on a validation failure" \
  "grep -q 'NEVER RE-GRILL' '$SKILL_MD'"
check "17b. …in words, not just a heading" \
  "grep -q 'Do not restart the interview' '$SKILL_MD'"
check "17c. …and says to re-run the SAME command with the repaired PRD" \
  "grep -q 'Repair the' '$SKILL_MD' && grep -q -- '--complete <id> --prd' '$SKILL_MD'"
check "17d. …naming failure shape 1: a missing/misformatted section" \
  "grep -q \"PRD is missing the '<X>' section\" '$SKILL_MD'"
check "17e. …naming failure shape 2: dropped open questions" \
  "grep -q \"drops N of the design brief\" '$SKILL_MD'"
check "17f. …and that a STILL OPEN entry SATISFIES the gate (no captain needed)" \
  "grep -q 'wants the questions to SURVIVE, not to be answered' '$SKILL_MD'"
check "17g. …explicitly: do not go back to the captain for an answer" \
  "grep -q 'you do \*\*not\*\* need an answer' '$SKILL_MD'"

# ==========================================================================
# 18. THE EXIT-CODE CONTRACT — 3 MEANS "THE PRD IS WRONG AND A REDRAFT COULD
#     FIX IT"; 1 STAYS "THE ENVIRONMENT IS WRONG"
#
# The live blocker: the viewscreen's Align console dispatched
# `file.sh --complete` on the closing turn, file.sh REFUSED the PRD (correctly —
# it had dropped 5 of the brief's 14 open questions), and the daemon had no way
# to tell that refusal apart from `gh` being unauthenticated. So it did the only
# thing it could: die. The captain — who did not write that PRD, a worker did —
# was left with no way forward.
#
# The daemon now SELF-HEALS a redraftable PRD by handing the refusal back to the
# warm Align worker. It must never do that for an environment failure (retrying
# a missing mission or a dead `gh` just burns tokens), so the two classes are
# split at the EXIT STATUS — never at the wording of the message (S165: key the
# filter off exit status, not the refusal wording).
#
#   exit 3 → the PRD/ADR artifact itself is wrong: a missing section, an
#            unreadable title/type, dropped design-brief questions, malformed ADR.
#   exit 1 → everything else: bad argv, no such mission, unreadable file, git.
#   exit 0 → unchanged.
#
# The gate's JUDGEMENT is untouched by all of this — only the number it exits with.

# --- 18a-e: the --complete lane (the one that actually broke) --------------
repoX="$(new_repo)"; make_gh_stub "$repoX/gh"
export GH_LOG="$repoX/gh.log"; : >"$GH_LOG"
briefX="$repoX/concept.md"; printf '%s' "$BRIEF_2SEC" >"$briefX"
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --park "rebuild the MBR builder" --attach "$briefX" >outX0.txt 2>&1
)
MX="$repoX/.git/lcars/missions/lcars-20260530-001-c10e"

prdXdrop="$repoX/prd-drop.md"; write_prd "$prdXdrop"
rcX1=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdXdrop" >outX1.txt 2>&1
) || rcX1=$?
check "18a. --complete dropping the brief's questions exits 3 (redraftable)" \
  "[ '$rcX1' -eq 3 ]"
check "18b. …still naming the dropped question, and still writing nothing" \
  "grep -q 'What makes a KPI' '$repoX/outX1.txt' && [ ! -f '$MX/prd.md' ]"

prdXsec="$repoX/prd-nosec.md"
cat >"$prdXsec" <<'EOF'
# Mission: A mission with no constraints at all

**Type:** feature
**Goal:** Do a thing.
**Acceptance Criteria:**
- it works
**Out of Scope:**
- everything else
EOF
rcX2=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdXsec" >outX2.txt 2>&1
) || rcX2=$?
check "18c. --complete with a missing PRD section exits 3 too" \
  "[ '$rcX2' -eq 3 ] && grep -q \"missing the 'Constraints' section\" '$repoX/outX2.txt'"

# …and the ENVIRONMENT failures on the SAME lane stay 1. Retrying these with a
# fresh PRD cannot possibly help, so they must never reach the heal.
rcX3=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-999 --prd "$prdXdrop" >outX3.txt 2>&1
) || rcX3=$?
check "18d. --complete of a mission that does not exist stays exit 1" \
  "[ '$rcX3' -eq 1 ] && grep -q 'no mission' '$repoX/outX3.txt'"

rcX4=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$repoX/nope.md" >outX4.txt 2>&1
) || rcX4=$?
check "18e. …and an unreadable --prd path stays exit 1" \
  "[ '$rcX4' -eq 1 ] && grep -q 'PRD file not found' '$repoX/outX4.txt'"

rcX5=0
(
  cd "$repoX"
  LCARS_GH_BIN="$repoX/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdXdrop" \
      --model-override "nonsense" >outX5.txt 2>&1
) || rcX5=$?
check "18f. …and a malformed --model-override stays exit 1 (bad argv, not a bad PRD)" \
  "[ '$rcX5' -eq 1 ]"

# --- 18g-k: the grill-first (--prd) lane carries the SAME contract ---------
repoY="$(new_repo)"; make_gh_stub "$repoY/gh"
export GH_LOG="$repoY/gh.log"; : >"$GH_LOG"
briefY="$repoY/concept.md"; printf '%s' "$BRIEF_2SEC" >"$briefY"
prdYdrop="$repoY/prd-drop.md"; write_prd "$prdYdrop"
rcY1=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYdrop" --attach "$briefY" >outY1.txt 2>&1
) || rcY1=$?
check "18g. grill-first dropping the brief's questions exits 3" "[ '$rcY1' -eq 3 ]"

prdYsec="$repoY/prd-nosec.md"; cp "$prdXsec" "$prdYsec"
rcY2=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYsec" >outY2.txt 2>&1
) || rcY2=$?
check "18h. grill-first with a missing PRD section exits 3" \
  "[ '$rcY2' -eq 3 ] && grep -q \"missing the 'Constraints' section\" '$repoY/outY2.txt'"

prdYt="$repoY/prd-title.md"
cat >"$prdYt" <<'EOF'
# Mission:

**Type:** feature
**Goal:** Do a thing.
**Acceptance Criteria:**
- it works
**Out of Scope:**
- everything else
**Constraints:**
- none
EOF
rcY3=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYt" >outY3.txt 2>&1
) || rcY3=$?
check "18i. an unreadable Mission title exits 3 — the PRD is what is wrong" \
  "[ '$rcY3' -eq 3 ] && grep -q 'could not read the Mission title' '$repoY/outY3.txt'"

prdYty="$repoY/prd-type.md"
cat >"$prdYty" <<'EOF'
# Mission: Something

**Type:** enhancement
**Goal:** Do a thing.
**Acceptance Criteria:**
- it works
**Out of Scope:**
- everything else
**Constraints:**
- none
EOF
rcY4=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYty" >outY4.txt 2>&1
) || rcY4=$?
check "18j. a Type that is neither feature nor bug exits 3" "[ '$rcY4' -eq 3 ]"

adrY="$repoY/adr-bad.md"; printf '**Context:** x\n' >"$adrY"
prdYok="$repoY/prd-ok.md"; write_prd "$prdYok"
rcY5=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYok" --adr "$adrY" >outY5.txt 2>&1
) || rcY5=$?
check "18k. a malformed ADR (the same worker's other artifact) exits 3" \
  "[ '$rcY5' -eq 3 ]"

rcY6=0
(
  cd "$repoY"
  LCARS_GH_BIN="$repoY/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdYok" --adr "$repoY/no-such-adr.md" >outY6.txt 2>&1
) || rcY6=$?
check "18l. …but an ADR path that does not EXIST stays exit 1" "[ '$rcY6' -eq 1 ]"

# --- 18m: a clean filing is untouched -------------------------------------
repoZ="$(new_repo)"; make_gh_stub "$repoZ/gh"
export GH_LOG="$repoZ/gh.log"; : >"$GH_LOG"
prdZ="$repoZ/prd.md"; write_prd "$prdZ"
rcZ=0
(
  cd "$repoZ"
  LCARS_GH_BIN="$repoZ/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdZ" >outZ.txt 2>&1
) || rcZ=$?
check "18m. a clean filing still exits 0 and writes prd.md" \
  "[ '$rcZ' -eq 0 ] && [ -f '$repoZ/.git/lcars/missions/lcars-20260530-001-c10e/prd.md' ]"

# --- Behaviour 19 (S188): every lane composes through the ONE composer ------
#
# `lcars file` no longer builds an issue body inline. All four lanes call
# `lcars_issue_body_compose` (skills/lcars-run/issue-body.sh), so this suite —
# which owns the filing mechanics — asserts the two things the FILING side is
# responsible for: the composer is genuinely the only body builder here, and
# every body it ships carries a `lcars:handoff` envelope that agrees with the
# state.json this same run wrote. Byte-for-byte parity against pre-S188 goldens,
# the envelope's parse contract, and the two refresh transfer points are proven
# in tests/handoff-payload.test.sh.

# 19a-c. No inline body composition survives in file.sh. A future edit that
# re-inlines "cat prd.md; separator; cat adr.md" into one of the lanes is the
# exact drift the composer exists to prevent, so lock it structurally.
check "19a. file.sh builds no issue body inline any more" \
  "! grep -q 'cat \"\$MISSION_DIR/adr.md\"' '$SCRIPT'"
check "19b. every filing lane goes through lcars_issue_body_compose" \
  "[ \"\$(grep -c 'lcars_issue_body_compose \"\$MISSION_DIR\"' '$SCRIPT')\" = 3 ]"
check "19c. file.sh refuses to file at all if the composer is missing" \
  "grep -q 'the issue-body composer is missing' '$SCRIPT'"

# 19d-i. The grill-first lane's recorded body, envelope and all.
repoE="$(new_repo)"; make_gh_stub "$repoE/gh"
export GH_LOG="$repoE/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoE/body.txt"
prdE="$repoE/prd-in.md"; write_prd "$prdE"
(
  cd "$repoE"
  LCARS_GH_BIN="$repoE/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdE" >outE.txt 2>&1
)
ME="$repoE/.git/lcars/missions/lcars-20260530-001-c10e"
check "19d. the filed body carries exactly one lcars:handoff envelope" \
  "[ \"\$(grep -c 'lcars:handoff' '$repoE/body.txt')\" = 1 ]"
check "19e. the envelope is the LAST line of the body" \
  "tail -1 '$repoE/body.txt' | grep -q '^<!-- lcars:handoff v1 .* -->\$'"
check "19f. the PRD is still the top of the body, untouched" \
  "head -1 '$repoE/body.txt' | grep -q '^# Mission:'"
check "19g. the envelope's branch/base agree with state.json" \
  "grep -q '\"branch\":\"lcars/lcars-20260530-001-c10e\",\"base\":\"main\"' '$repoE/body.txt'"
check "19h. the envelope's type agrees with the PRD-derived type" \
  "grep -q '\"type\":\"bug\"' '$repoE/body.txt'"
check "19i. no issue-body temp file is left behind in the mission dir" \
  "[ -z \"\$(ls -A '$ME' | grep '^\\.issue-body\\.[A-Za-z0-9]\\{6\\}\$')\" ]"
check "19i. …but the regression-guard baseline IS kept (S188 fix round)" \
  "[ -f '$ME/.issue-body.last' ]"
check "19i. …and it is the body that actually reached GitHub" \
  "cmp -s '$ME/.issue-body.last' '$repoE/body.txt'"

# 19j-l. The PARK lane's envelope says "parked" — there is no PRD yet, and a
# reader must be able to tell that from the machine-readable block alone.
repoP="$(new_repo)"; make_gh_stub "$repoP/gh"
export GH_LOG="$repoP/gh.log"; : >"$GH_LOG"
export GH_BODY="$repoP/body.txt"
(
  cd "$repoP"
  LCARS_GH_BIN="$repoP/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --park "Make the /about route work again" >outP.txt 2>&1
)
check "19j. a parked body's envelope carries parked:true" \
  "grep -q '\"parked\":true' '$repoP/body.txt'"
check "19k. a parked body's envelope carries no type (none is known yet)" \
  "grep -q '\"type\":null' '$repoP/body.txt'"
check "19l. the STANDBY note is still the visible body" \
  "grep -q 'STANDBY — parked awaiting alignment' '$repoP/body.txt'"

# 19m-o. --complete OVERRIDES the envelope from the values it has just
# re-resolved, because it composes before state.json is finalised (prdPending is
# cleared last, on purpose, so a gh failure leaves the mission parked). Reading
# state.json there would ship a stale type/engine on that one lane.
export GH_BODY="$repoP/body2.txt"
prdP="$repoP/prd-in.md"; write_prd "$prdP"
(
  cd "$repoP"
  LCARS_GH_BIN="$repoP/gh" LCARS_DATE="20260530" LCARS_WORKER_BIN="copilot" \
    bash "$SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdP" >outP2.txt 2>&1
)
MP="$repoP/.git/lcars/missions/lcars-20260530-001-c10e"
check "19m. the aligned body's envelope is no longer marked parked" \
  "! grep -q '\"parked\":true' '$repoP/body2.txt'"
check "19n. the aligned envelope carries the PRD-derived type" \
  "grep -q '\"type\":\"bug\"' '$repoP/body2.txt'"
check "19o. the aligned envelope carries the RE-RESOLVED engine, not the parked one" \
  "grep -q '\"engine\":\"copilot\"' '$repoP/body2.txt' \
   && grep -q '\"workerBin\": *\"[^\"]*copilot\"' '$MP/state.json'"

# ==========================================================================
# 20. RE-GRILLING A FEEDBACK-RE-ENTERED MISSION MUST SAVE prd.md (S238)
#
# MEASURED: `lcars feedback` bounces a verified mission back to `align` and
# appends the captain's note to feedback.md. Re-grilling it on the board ends at
# `_complete_from_align`, which dispatches `file.sh --complete` — and that
# refused with "already aligned", because prdPending is long cleared. The only
# thing left on disk was the daemon's best-effort `prd-draft.md`, so ten answers
# of re-alignment produced NO prd.md and the pipeline re-ran the OLD one.
#
# ADR-002 is untouched: file.sh still writes prd.md. What is added is the
# RE-ENTRY arm — stage `align` WITH a feedback.md is a re-grill, not a
# first filing — and it keeps every prior PRD as `prd.<n>.md`, the same
# "nothing prior is ever deleted" rule `lcars feedback` itself obeys.
echo "20. the feedback re-entry arm of --complete"

repoR="$(new_repo)"; make_gh_stub "$repoR/gh"
export GH_LOG="$repoR/gh.log"; : >"$GH_LOG"
unset GH_BODY
prdR1="$repoR/prd-v1.md"; write_prd "$prdR1"; printf '\nv1-marker\n' >>"$prdR1"
(
  cd "$repoR"
  LCARS_GH_BIN="$repoR/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdR1" >outR0.txt 2>&1
)
MIDR="$(cd "$repoR/.git/lcars/missions" && ls -d lcars-20260530-* | head -1)"
MR="$repoR/.git/lcars/missions/$MIDR"
check "20a. a grill-first mission is aligned with prd.md v1" \
  "[ -n '$MIDR' ] && qgrep -q 'v1-marker' '$MR/prd.md'"

# --- 20b: THE REGRESSION GUARD. No feedback.md → today's refusal, unchanged.
prdR2="$repoR/prd-v2.md"; write_prd "$prdR2"; printf '\nv2-marker\n' >>"$prdR2"
rcR=0
(
  cd "$repoR"
  LCARS_GH_BIN="$repoR/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete "$MIDR" --prd "$prdR2" >outR1.txt 2>&1
) || rcR=$?
check "20b. REGRESSION — an aligned mission with NO feedback still refuses" \
  "[ '$rcR' -ne 0 ]"
check "20b. REGRESSION — …with the same 'already aligned' sentence" \
  "qgrep -q 'already aligned' '$repoR/outR1.txt'"
check "20b. REGRESSION — …and prd.md is untouched (still v1)" \
  "qgrep -q 'v1-marker' '$MR/prd.md' && ! qgrep -q 'v2-marker' '$MR/prd.md'"
check "20b. REGRESSION — …and no history file was invented" "[ ! -e '$MR/prd.1.md' ]"

# --- 20c: the re-entry. Stage `align` WITH feedback.md → it saves. ----------
printf -- '## 2026-10-02\n\nThe /about fix missed the trailing-slash case.\n' \
  >"$MR/feedback.md"
FBSUM_BEFORE="$(cksum <"$MR/feedback.md")"
rcR2=0
(
  cd "$repoR"
  LCARS_GH_BIN="$repoR/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete "$MIDR" --prd "$prdR2" >outR2.txt 2>&1
) || rcR2=$?
check "20c. re-entry exits 0" "[ '$rcR2' -eq 0 ]"
check "20c. prd.md is OVERWRITTEN with the re-grilled PRD" \
  "qgrep -q 'v2-marker' '$MR/prd.md'"
check "20c. the previous PRD is kept as prd.1.md — nothing prior is deleted" \
  "[ -f '$MR/prd.1.md' ] && qgrep -q 'v1-marker' '$MR/prd.1.md'"
check "20c. feedback.md is untouched" \
  "[ \"\$(cksum <'$MR/feedback.md')\" = '$FBSUM_BEFORE' ]"
check "20c. state.json records realignedAt" \
  "qgrep -q '\"realignedAt\"' '$MR/state.json'"
check "20c. the mission is still at align" \
  "qgrep -q '\"stage\": \"align\"' '$MR/state.json'"
check "20c. …and the saved PRD path is printed, so the daemon can carry it back" \
  "qgrep -qF '$MR/prd.md' '$repoR/outR2.txt'"
check "20c. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MR/state.json'"

# --- 20d: a SECOND re-entry stacks the history, it never overwrites it ------
prdR3="$repoR/prd-v3.md"; write_prd "$prdR3"; printf '\nv3-marker\n' >>"$prdR3"
(
  cd "$repoR"
  LCARS_GH_BIN="$repoR/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete "$MIDR" --prd "$prdR3" >outR3.txt 2>&1
)
check "20d. a second re-grill writes prd.md v3" "qgrep -q 'v3-marker' '$MR/prd.md'"
check "20d. …keeps v2 as prd.2.md" "qgrep -q 'v2-marker' '$MR/prd.2.md'"
check "20d. …and prd.1.md still holds v1 (NOTHING prior is ever deleted)" \
  "qgrep -q 'v1-marker' '$MR/prd.1.md'"

# --- 20e: the daemon SURFACES a refusal for any OTHER reason ----------------
# No silent "already aligned": `_run` raises with the skill's exit code AND its
# output, so whatever file.sh said reaches the API response text.
SURFPY="$TMPROOT/s238-surface.py"
cat >"$SURFPY" <<'PYEOF'
import sys, os
sys.path.insert(0, ".")
from lcars_serve.actions import Actions, ActionError
repo = sys.argv[1]
stub = os.path.join(repo, "refusing-file.sh")
with open(stub, "w") as fh:
    fh.write("#!/bin/sh\n")
    fh.write("echo \"mission 'x' has no state.json - its state is corrupt.\"\n")
    fh.write("exit 7\n")
os.chmod(stub, 0o755)
a = Actions(repo, {"file": stub})
try:
    a._run("file", ["--complete", "x", "--prd", "/tmp/nope"])
except ActionError as exc:
    print("STATUS=%s" % exc.status)
    print("EXIT=%s" % getattr(exc, "skill_exit", ""))
    print("MESSAGE=%s" % exc.message)
else:
    print("NO-RAISE")
PYEOF
SURFOUT="$(cd "$REPO_ROOT/web" && python3 "$SURFPY" "$repoR" 2>&1)"
check "20e. a file.sh refusal reaches the API response as a 502" \
  "printf '%s' \"\$SURFOUT\" | qgrep -q 'STATUS=502'"
check "20e. …carrying file.sh's OWN refusal text, not a daemon paraphrase" \
  "printf '%s' \"\$SURFOUT\" | qgrep -q 'its state is corrupt'"
check "20e. …and the skill's exit code, so callers key off status not prose" \
  "printf '%s' \"\$SURFOUT\" | qgrep -q 'EXIT=7'"

# --- 20f: A STATE WRITE THAT FAILED MUST NOT BE REPORTED AS A SUCCESS -------
# S238 FIX ROUND 1, DEFECT 3. `_complete_reentry` ignored
# `lcars_state_set_string`'s exit code: against a malformed state.json the
# setter printed "⚠ … left untouched (field \"realignedAt\" NOT written)" and
# returned 1, and the arm went on to print "Mission re-aligned" and exit 0 — so
# the daemon answered ok=true with a prdPath for a re-alignment that was never
# recorded. A success that half happened is the thing this project least
# tolerates. The PRD really IS on disk by then, so the honest answer says both:
# the PRD was written, the re-alignment was NOT recorded, and it fails.
repoF="$(new_repo)"; make_gh_stub "$repoF/gh"
export GH_LOG="$repoF/gh.log"; : >"$GH_LOG"
unset GH_BODY
prdF1="$repoF/prd-f1.md"; write_prd "$prdF1"; printf '\nf1-marker\n' >>"$prdF1"
(
  cd "$repoF"
  LCARS_GH_BIN="$repoF/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --prd "$prdF1" >outF0.txt 2>&1
)
MIDF="$(cd "$repoF/.git/lcars/missions" && ls -d lcars-20260530-* | head -1)"
MF="$repoF/.git/lcars/missions/$MIDF"
printf -- '## 2026-10-02\n\nstill wrong.\n' >"$MF/feedback.md"
prdF2="$repoF/prd-f2.md"; write_prd "$prdF2"; printf '\nf2-marker\n' >>"$prdF2"

# POSITIVE CONTROL first, in the claim's own phrasing family: a SOUND
# state.json re-enters, says "Mission re-aligned", and exits 0.
rcF0=0
(
  cd "$repoF"
  LCARS_GH_BIN="$repoF/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete "$MIDF" --prd "$prdF2" >outF1.txt 2>&1
) || rcF0=$?
check "20f. CONTROL — a sound state.json re-enters, exits 0, and says so" \
  "[ '$rcF0' -eq 0 ] && qgrep -q 'Mission re-aligned' '$repoF/outF1.txt'"

# Now break state.json so the shared writer REFUSES it, and re-grill again.
cp "$MF/state.json" "$MF/state.json.good"
printf '{ "id": "%s", "stage": "align", NOT JSON\n}\n' "$MIDF" >"$MF/state.json"
prdF3="$repoF/prd-f3.md"; write_prd "$prdF3"; printf '\nf3-marker\n' >>"$prdF3"
rcF=0
(
  cd "$repoF"
  LCARS_GH_BIN="$repoF/gh" LCARS_DATE="20260530" \
    bash "$SCRIPT" --complete "$MIDF" --prd "$prdF3" --reentry >outF2.txt 2>&1
) || rcF=$?
check "20f. a refused state write FAILS the arm (non-zero), it is not swallowed" \
  "[ '$rcF' -ne 0 ]"
check "20f. …and it never claims 'Mission re-aligned'" \
  "! qgrep -q 'Mission re-aligned' '$repoF/outF2.txt'"
check "20f. …it says the re-alignment was NOT recorded" \
  "qgrep -q 'NOT recorded' '$repoF/outF2.txt'"
check "20f. …and it still says where the PRD went, because that part IS true" \
  "qgrep -qF '$MF/prd.md' '$repoF/outF2.txt' && qgrep -q 'f3-marker' '$MF/prd.md'"
check "20f. …and realignedAt was genuinely not written" \
  "! qgrep -q 'realignedAt' '$MF/state.json'"

# ==========================================================================
[ "$fail" -eq 0 ]
