#!/usr/bin/env bash
#
# Fast, SCOPED test for the Mission-Log GROUNDING mode (feat/mission-log-grounding).
#
# A bug filed via `lcars log` now ENTERS the pipeline at Research in a
# grounding-only mode (origin="log", stage="align") instead of fast-tracking to
# Plan. This locks the substantive behaviour:
#
#   B. cmd_research (grounding): a logged bug runs ONE bounded read-only worker
#      fed the PARENT Mission's PRD + plan (which name the real symbols), writes
#      research/grounding.json, and advances to validate — NO question-gen fan-out,
#      NO per-question agents, and it can NEVER escalate to awaiting-human.
#   C. cmd_validate consumes research/grounding.json (its prompt names it).
#   Regression: a NON-bug mission still runs normal question-gen research.
#   Belt-and-braces: cmd_gate never escalates a bug even at >MAX questions.
#
# This is NOT the heavy tests/lcars-run.test.sh. The cold worker is replaced by a
# fake worker-adapter (LCARS_WORKER_ADAPTER) that records each spawn's role +
# prompt and writes a canned output file per role — so no real model is spent and
# the run is sub-second. Every external CLI is stubbed.
#
# Usage: bash tests/mission-log-grounding.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- a fake worker-adapter: role-aware canned output + spawn recorder --------
# Invoked as: adapter spawn <cli> <role> <outdir> <prompt>. Records the role to
# $ADP_ROLES and the FULL prompt (with a role header) to $ADP_PROMPTS, then writes
# the output file the role's stage expects into <outdir>:
#   research-grounding -> grounding.json  (a canned, well-formed grounding artifact)
#   research-questions -> questions.txt   ($QGEN_LINES lines; empty ⇒ 0 questions)
#   validate           -> validated-plan.md
# Anything else is a no-op (writes nothing), which surfaces as a stage failure.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
# run.sh calls: adapter spawn <cli> <TOOLSET> <outdir> <prompt>, and passes the
# real env-role via $LCARS_WORKER_ROLE (the toolset is in $3). Key on the env role.
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
printf '%s\n' "$role" >>"$ADP_ROLES"
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$ADP_PROMPTS"
case "$role" in
  research-grounding)
    cat >"$outdir/grounding.json" <<'JSON'
{
  "targets": ["src/theme/themeStore.ts:toggleTheme", "src/components/ThemeIcon.tsx:ThemeIcon"],
  "kind": "modify-existing",
  "restated": "The sun/moon icon is not shown when no game is open because ThemeIcon is only mounted inside the game view; it must read the existing themeStore.toggleTheme.",
  "reuse_directive": "Modify themeStore/ThemeIcon; do NOT add a new isNight flag that duplicates the existing theme toggle."
}
JSON
    ;;
  research-questions)
    if [ -n "${QGEN_LINES:-}" ]; then printf '%s\n' "$QGEN_LINES" >"$outdir/questions.txt";
    else : >"$outdir/questions.txt"; fi
    ;;
  validate)
    cat >"$outdir/validated-plan.md" <<'VP'
# Validated Plan: theme icon
## Synthesis
Modify the existing themeStore.toggleTheme / ThemeIcon.
## Decisions
Reuse the existing theme toggle; do not add a new isNight flag.
## Rationale
The grounding artifact names the real targets — duplicating them caused the bug.
VP
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A dummy worker binary that merely EXISTS+executable so require_worker passes.
# (The adapter above is what actually "runs"; this is never invoked.)
make_worker_bin() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# A gh stub (no issue on the missions here ⇒ gh_relabel is a local-only no-op,
# but resolve/anything that shells gh still finds a binary).
make_gh() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# --- stand up a repo with a PARENT mission + one logged BUG child ------------
# The parent's plan.json names the REAL symbol (themeStore) — the highest-signal
# anchor the grounding worker must be fed. The bug child is exactly what log.sh
# now writes: stage="align", origin="log", parentMission set, githubIssue null.
new_repo() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  printf '# Context\nTest repo.\n' >"$repo/CONTEXT.md"   # path-1 context (no pack spawn)
  local mroot="$repo/.git/lcars/missions"
  mkdir -p "$mroot"
  cat >"$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "repo" }
JSON
  # parent
  mkdir -p "$mroot/parent-001"
  cat >"$mroot/parent-001/state.json" <<'JSON'
{
  "id": "parent-001",
  "type": "feature",
  "title": "Theme toggle",
  "stage": "verify",
  "branch": "lcars/parent-001",
  "githubIssue": 42
}
JSON
  printf '# Mission: Theme toggle\nAdd a light/dark theme toggle.\n' >"$mroot/parent-001/prd.md"
  printf '# Validated Plan: Theme toggle\nUse a themeStore with toggleTheme().\n' >"$mroot/parent-001/validated-plan.md"
  cat >"$mroot/parent-001/plan.json" <<'JSON'
[ { "id": "t-001", "title": "themeStore.toggleTheme", "description": "Hoist the theme toggle into themeStore.", "acceptanceCriteria": ["toggles theme"], "dependencies": [] } ]
JSON
  # the logged bug child (as log.sh now writes it)
  mkdir -p "$mroot/bug-002"
  cat >"$mroot/bug-002/state.json" <<'JSON'
{
  "id": "bug-002",
  "type": "bug",
  "origin": "log",
  "title": "sun/moon icon missing when no game open",
  "stage": "align",
  "branch": "lcars/parent-001",
  "base": "main",
  "githubIssue": null,
  "parentMission": "parent-001",
  "parentIssue": 42
}
JSON
  printf '# Mission: sun/moon icon missing when no game open\n\n**Type:** bug\nThe theme icon vanishes when no game is open.\n' >"$mroot/bug-002/prd.md"
  echo "$repo"
}

drive() { # repo subcommand args...  -> sets RC + OUT (worker fully stubbed)
  local repo="$1"; shift
  OUT="$( cd "$repo" && env \
      LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
      LCARS_WORKER_BIN="$repo/worker" LCARS_WORKER_CLI=claude \
      LCARS_WORKER_ADAPTER="$repo/adapter" \
      LCARS_WORKER_HANG_SECS=0 \
      ADP_ROLES="$repo/roles.log" ADP_PROMPTS="$repo/prompts.log" \
      bash "$SCRIPT" "$@" 2>&1 )"
  RC=$?
}

setup() { # -> echoes repo, all stubs wired + logs truncated
  local repo; repo="$(new_repo)"
  make_adapter "$repo/adapter"; make_worker_bin "$repo/worker"; make_gh "$repo/gh"
  : >"$repo/roles.log"; : >"$repo/prompts.log"
  echo "$repo"
}

echo "mission-log grounding"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# ==========================================================================
# B. GROUNDING RESEARCH: a logged bug runs grounding, not question-gen.
# ==========================================================================
repo="$(setup)"
drive "$repo" research --mission bug-002
BUG="$repo/.git/lcars/missions/bug-002"

check "B. grounding research exits zero" "[ '$RC' -eq 0 ]"
check "B. runs the grounding worker (role research-grounding)" \
  "grep -q '^research-grounding$' '$repo/roles.log'"
check "B. does NOT run the question-generator (no research-questions role)" \
  "! grep -q '^research-questions$' '$repo/roles.log'"
check "B. does NOT fan out per-question research agents (no research-agent role)" \
  "! grep -q '^research-agent$' '$repo/roles.log'"
check "B. writes NO questions.txt (no question-gen)" \
  "[ ! -f '$BUG/research/questions.txt' ]"
check "B. saves research/grounding.json from the worker output" \
  "[ -f '$BUG/research/grounding.json' ]"
check "B. grounding.json carries the worker's targets (themeStore)" \
  "grep -q 'themeStore' '$BUG/research/grounding.json'"
check "B. advances the bug to stage validate" \
  "grep -q '\"stage\": *\"validate\"' '$BUG/state.json'"
check "B. NEVER sets awaitingHuman (grounding cannot escalate)" \
  "! grep -q 'awaitingHuman' '$BUG/state.json'"
check "B. writes no pending.json (no escalation)" \
  "[ ! -f '$BUG/pending.json' ]"
check "B. no attachments dir => grounding prompt has NO attachments section" \
  "! grep -q 'Attached images' '$repo/prompts.log'"

# ==========================================================================
# B2. GROUNDING + ATTACHMENTS: a logged bug's screenshot reaches the grounding
# worker — attachments_extra_block is threaded into the research-grounding
# spawn (S92 contract, re-seated by the 2026-07-03 main merge). The captain's
# screenshot is often THE symptom; the worker that anchors it must see it.
# ==========================================================================
repo="$(setup)"
BUG="$repo/.git/lcars/missions/bug-002"
mkdir -p "$BUG/attachments"
printf 'PNGDATA-B2' >"$BUG/attachments/attachment-01.png"
drive "$repo" research --mission bug-002

check "B2. grounding research exits zero with an attachment present" "[ '$RC' -eq 0 ]"
check "B2. grounding prompt carries the Attached-images section" \
  "grep -q 'Attached images' '$repo/prompts.log'"
check "B2. grounding prompt carries the ABSOLUTE attachment path" \
  "grep -qF -- '$BUG/attachments/attachment-01.png' '$repo/prompts.log'"
check "B2. still saves grounding.json + advances to validate" \
  "[ -f '$BUG/research/grounding.json' ] && grep -q '\"stage\": *\"validate\"' '$BUG/state.json'"

# --- the assembled grounding prompt is fed the PARENT's artifacts -----------
check "B. grounding prompt names the parent's prd.md path" \
  "grep -q 'parent-001/prd.md' '$repo/prompts.log'"
check "B. grounding prompt names the parent's validated-plan.md path" \
  "grep -q 'parent-001/validated-plan.md' '$repo/prompts.log'"
check "B. grounding prompt names the parent's plan.json path (highest signal)" \
  "grep -q 'parent-001/plan.json' '$repo/prompts.log'"
check "B. grounding prompt names the bug's own prd.md (the symptom)" \
  "grep -q 'bug-002/prd.md' '$repo/prompts.log'"
check "B. grounding prompt points at the delivered-code branch (lcars/parent-001)" \
  "grep -q 'lcars/parent-001' '$repo/prompts.log'"

# ==========================================================================
# C. VALIDATE consumes the grounding artifact.
# ==========================================================================
# Continue the SAME mission: it is now at validate with research/grounding.json.
drive "$repo" validate --mission bug-002
check "C. validate exits zero with a grounding artifact present" "[ '$RC' -eq 0 ]"
check "C. validate ran its worker (role validate)" \
  "grep -q '^validate$' '$repo/roles.log'"
check "C. validate prompt INCLUDES research/grounding.json as an input" \
  "grep -q 'research/grounding.json' '$repo/prompts.log'"
check "C. validate prompt carries the modify-not-duplicate GROUNDING note" \
  "grep -q 'GROUNDING artifact' '$repo/prompts.log'"
check "C. validate advances the bug to stage plan" \
  "grep -q '\"stage\": *\"plan\"' '$BUG/state.json'"

# ==========================================================================
# E(regression). A NON-BUG mission still runs NORMAL question-gen research.
# ==========================================================================
repo2="$(setup)"
# a feature mission at align (no origin=log, type=feature)
mkdir -p "$repo2/.git/lcars/missions/feat-003"
cat >"$repo2/.git/lcars/missions/feat-003/state.json" <<'JSON'
{
  "id": "feat-003",
  "type": "feature",
  "title": "A feature",
  "stage": "align",
  "githubIssue": null
}
JSON
printf '# Mission: A feature\n\n**Type:** feature\nBuild a feature.\n' >"$repo2/.git/lcars/missions/feat-003/prd.md"
# QGEN_LINES empty ⇒ the question-gen worker emits 0 questions ⇒ gate skip ⇒ advance.
drive "$repo2" research --mission feat-003
FEAT="$repo2/.git/lcars/missions/feat-003"
check "E. non-bug research exits zero" "[ '$RC' -eq 0 ]"
check "E. non-bug runs the QUESTION generator (role research-questions)" \
  "grep -q '^research-questions$' '$repo2/roles.log'"
check "E. non-bug NEVER runs the grounding worker (no research-grounding role)" \
  "! grep -q '^research-grounding$' '$repo2/roles.log'"
check "E. non-bug writes NO grounding.json" \
  "[ ! -f '$FEAT/research/grounding.json' ]"
check "E. non-bug advances to validate (0-question skip path)" \
  "grep -q '\"stage\": *\"validate\"' '$FEAT/state.json'"

# ==========================================================================
# Belt-and-braces: cmd_gate NEVER escalates a bug, even at >MAX questions.
# ==========================================================================
repo3="$(setup)"
# 25 fake questions (> the default cap of 20) fed straight to the gate for bug-002.
qf="$repo3/many.txt"; for i in $(seq 1 25); do echo "Q$i?"; done >"$qf"
drive "$repo3" gate --mission bug-002 --questions "$qf"
BUG3="$repo3/.git/lcars/missions/bug-002"
check "G. gate on a bug with 25 questions does NOT escalate (no non-zero exit 3)" \
  "[ '$RC' -eq 0 ]"
check "G. gate does NOT set awaitingHuman for a bug" \
  "! grep -q 'awaitingHuman' '$BUG3/state.json'"
check "G. gate writes no pending.json for a bug" \
  "[ ! -f '$BUG3/pending.json' ]"
# and a NON-bug with >MAX questions STILL escalates (gate not loosened generally)
mkdir -p "$repo3/.git/lcars/missions/feat-004"
cat >"$repo3/.git/lcars/missions/feat-004/state.json" <<'JSON'
{
  "id": "feat-004",
  "type": "feature",
  "title": "F",
  "stage": "align",
  "githubIssue": null
}
JSON
printf '# Mission: F\n' >"$repo3/.git/lcars/missions/feat-004/prd.md"
drive "$repo3" gate --mission feat-004 --questions "$qf"
FEAT4="$repo3/.git/lcars/missions/feat-004"
check "G. a NON-bug with >MAX questions STILL escalates (gate not loosened)" \
  "[ '$RC' -eq 3 ] && grep -q 'awaitingHuman' '$FEAT4/state.json'"

# ==========================================================================
# F. BRANCH-ANCHORING: the four read-only stages (Research-questions, Validate,
#    Plan, Plan Review) pin their repo-read worker to the MISSION's OWN branch,
#    not the ambient working-tree checkout. Regression guard for the cross-mission
#    "reason leak": a bug filed while the tree sat on a sibling branch had Validate
#    read that checked-out branch and override the grounding. We deliberately put
#    the working tree on a DIFFERENT branch than the missions' branch and assert
#    every stage prompt still names the mission branch + tells the worker to
#    IGNORE the working-tree checkout.
# ==========================================================================
repoF="$(setup)"
( cd "$repoF" && git checkout -q -b some-other-branch )   # mismatch: tree != mission branch
mF="$repoF/.git/lcars/missions"
BR="lcars/parent-x"
IGN='checkout may be on an UNRELATED branch; IGNORE it and its history'

# --- Research (question-gen): a feature mission with a branch -----------------
mkdir -p "$mF/fa-010"
cat >"$mF/fa-010/state.json" <<JSON
{
  "id": "fa-010",
  "type": "feature",
  "title": "Anchor feat",
  "stage": "align",
  "branch": "$BR",
  "githubIssue": null
}
JSON
printf '# Mission: Anchor feat\n\n**Type:** feature\nBuild it.\n' >"$mF/fa-010/prd.md"
: >"$repoF/prompts.log"; : >"$repoF/roles.log"
drive "$repoF" research --mission fa-010
check "F. research-questions ran (role research-questions)" \
  "grep -q '^research-questions$' '$repoF/roles.log'"
check "F. research-questions prompt names the Mission branch ($BR)" \
  "grep -qF -- '$BR' '$repoF/prompts.log'"
check "F. research-questions prompt says to ignore the working-tree checkout" \
  "grep -qF -- '$IGN' '$repoF/prompts.log'"

# --- Validate: a logged bug with grounding.json (also asserts escalate note) --
mkdir -p "$mF/va-011/research"
cat >"$mF/va-011/state.json" <<JSON
{
  "id": "va-011",
  "type": "bug",
  "origin": "log",
  "title": "V",
  "stage": "validate",
  "branch": "$BR",
  "githubIssue": null,
  "parentMission": "parent-001"
}
JSON
printf '# Mission: V\n\n**Type:** bug\nSymptom.\n' >"$mF/va-011/prd.md"
cat >"$mF/va-011/research/grounding.json" <<'JSON'
{ "targets": ["src/x.ts:foo"], "kind": "modify-existing", "restated": "x", "reuse_directive": "modify foo" }
JSON
: >"$repoF/prompts.log"; : >"$repoF/roles.log"
drive "$repoF" validate --mission va-011
check "F. validate prompt names the Mission branch ($BR)" \
  "grep -qF -- '$BR' '$repoF/prompts.log'"
check "F. validate prompt says to ignore the working-tree checkout" \
  "grep -qF -- '$IGN' '$repoF/prompts.log'"
check "F. validate prompt carries the escalate-on-override (grounding AUTHORITATIVE) note" \
  "grep -q 'AUTHORITATIVE' '$repoF/prompts.log'"
check "F. validate escalate note routes through the scope.txt gate" \
  "grep -q 'emit scope.txt' '$repoF/prompts.log'"

# --- Plan: worker output stubbed absent → stage will fail, but the PROMPT is
#     recorded on the first spawn (that is all we assert). -----------------------
mkdir -p "$mF/pl-012"
cat >"$mF/pl-012/state.json" <<JSON
{
  "id": "pl-012",
  "type": "feature",
  "title": "P",
  "stage": "plan",
  "branch": "$BR",
  "githubIssue": null
}
JSON
printf '# Mission: P\n' >"$mF/pl-012/prd.md"
printf '# Validated Plan: P\n## Synthesis\nx\n## Decisions\n- y\n## Rationale\nz\n' >"$mF/pl-012/validated-plan.md"
: >"$repoF/prompts.log"; : >"$repoF/roles.log"
drive "$repoF" plan --mission pl-012
check "F. plan ran its worker (role plan)" \
  "grep -q '^plan$' '$repoF/roles.log'"
check "F. plan prompt names the Mission branch ($BR)" \
  "grep -qF -- '$BR' '$repoF/prompts.log'"
check "F. plan prompt says to ignore the working-tree checkout" \
  "grep -qF -- '$IGN' '$repoF/prompts.log'"

# --- Plan Review: worker output stubbed absent → stage fails; prompt recorded. -
mkdir -p "$mF/pr-013"
cat >"$mF/pr-013/state.json" <<JSON
{
  "id": "pr-013",
  "type": "feature",
  "title": "R",
  "stage": "plan-review",
  "branch": "$BR",
  "githubIssue": null
}
JSON
cat >"$mF/pr-013/plan.json" <<'JSON'
[ { "id": "t-001", "title": "t", "description": "d", "acceptanceCriteria": ["a"], "dependencies": [], "estimatedReadLoc": 10, "estimatedTestLoc": 10, "estimatedNewLoc": 10 } ]
JSON
: >"$repoF/prompts.log"; : >"$repoF/roles.log"
drive "$repoF" plan-review --mission pr-013
check "F. plan-review ran its worker (role plan-review)" \
  "grep -q '^plan-review$' '$repoF/roles.log'"
check "F. plan-review prompt names the Mission branch ($BR)" \
  "grep -qF -- '$BR' '$repoF/prompts.log'"
check "F. plan-review prompt says to ignore the working-tree checkout" \
  "grep -qF -- '$IGN' '$repoF/prompts.log'"

# ==========================================================================
echo
printf 'mission-log grounding: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
