#!/usr/bin/env bash
#
# Tests for the durable repo CONTEXT SOURCE — the one-time static base every
# Align / Validate / Plan / Plan-Review / Implement worker reuses instead of
# re-deriving repo facts each run (skill source: skills/lcars-run/run.sh,
# subcommand `context-source`; stage template stages/context-pack.md).
#
# Resolution order (the spec):
#   1. CONTEXT.md at the repo root            → use it; generate NO pack.
#   2. .git/lcars/context-pack.md (generated) → reuse it; do NOT regenerate.
#   3. neither                                → generate the pack via ONE cold
#      worker, then use it.
#
# HARD INVARIANTS proven here:
#   - Zero working-tree footprint: the pack lives ONLY at
#     .git/lcars/context-pack.md; `git status --porcelain` stays empty and no
#     tracked CONTEXT.md is ever created.
#   - Lazy + once: generation happens on first resolution, never twice.
#   - Research-agent PURITY: the resolved source reaches the declarative Stages
#     (Validate/Plan/Plan-Review/Implement) but NEVER the research agents.
#
# Deps are stubbed via env ($LCARS_WORKER_BIN, $LCARS_GH_BIN, $LCARS_GIT_BIN).
#
# Usage: bash tests/lcars-context.test.sh

set -uo pipefail

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# its first match and closes the pipe; a still-writing upstream producer then
# takes SIGPIPE and exits non-zero, and under `set -o pipefail` that flips a
# genuine match into a phantom assertion failure (timing/load-sensitive — it bit
# the worker-prompt assertions only under the full back-to-back suite). Draining
# first removes the race; exit status and output are otherwise identical to grep.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

# The cold-worker CLI flags/tool names now live in worker-adapter.sh, keyed by a
# cli id run.sh derives from the worker binary's basename (`claude` in production).
# These suites stub the worker under the generic name `worker`, so point the cli
# id at the claude adapter for the whole suite (like LCARS_GH_BIN selects gh).
export LCARS_WORKER_CLI="${LCARS_WORKER_CLI:-claude}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "lcars context — the durable repo context source (session 44)"

# --- stubs ----------------------------------------------------------------
# A fake `gh` that records calls and otherwise succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"${GH_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "$1"
}

# A canned worker. Records every call's role to $WORKER_LOG and its prompt to
# $WORKER_CALLS/<role>.<pid>.txt, then writes a role-appropriate artifact. The
# context-pack role mirrors the REAL worker contract: it writes the pack ONLY to
# the expanded SCRATCH file path baked into its prompt (never to a `.git/` path),
# proving the bash-side scratch→.git/lcars/ copy actually works. It must never be
# handed a `$LCARS_CONTEXT_PACK_PATH` token to expand, and must never write
# anywhere inside the cwd / working tree.
make_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""; tools=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --allowedTools) tools="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'role=%s tools=%s\n' "$LCARS_WORKER_ROLE" "$tools" >>"$WORKER_LOG"
printf '%s' "$prompt" >"$WORKER_CALLS/$LCARS_WORKER_ROLE.$$.txt"
out="$LCARS_WORK_OUT"
case "$LCARS_WORKER_ROLE" in
  context-pack)
    # Mirror the real worker: write the pack ONLY to the EXACT scratch file path
    # the harness baked into the prompt ("Write your context pack to EXACTLY:
    # <path>"). Parse it out of the prompt — do NOT expand any env-var token.
    dest="$(printf '%s' "$prompt" \
      | sed -n 's/^Write your context pack to EXACTLY: //p' | head -n1)"
    [ -n "$dest" ] && printf '# Context Pack\n\nStub repo facts.\n' >"$dest"
    ;;
  research-questions)
    : >"$out/questions.txt"
    echo "Stub question 1?" >>"$out/questions.txt"
    echo "Stub question 2?" >>"$out/questions.txt"
    ;;
  research-agent)
    cat >"$out/response.json" <<JSON
{ "question": "q", "recommendation": "do it", "supporting_points": ["a","b"] }
JSON
    ;;
  validate)
    cat >"$out/validated-plan.md" <<MD
# Validated Plan
## Synthesis
x
## Decisions
- y
## Rationale
z
MD
    ;;
  plan)
    cat >"$out/plan.json" <<JSON
[
  {
    "id": "t-001",
    "title": "Wire the data-theme attribute",
    "description": "End-to-end token wiring.",
    "acceptanceCriteria": ["data-theme=dark recolours the page"],
    "estimatedReadLoc": 200,
    "estimatedTestLoc": 80,
    "estimatedNewLoc": 120,
    "dependencies": [],
    "rationale": "Foundational token layer every later slice paints on."
  }
]
JSON
    ;;
  plan-review)
    printf '{ "passed": true, "issues": [] }\n' >"$out/verdict.json"
    ;;
  implement-tdd)
    printf 'export const ok=true;\n' > impl-output.js
    tid="$(printf '%s' "$prompt" | awk '/## Your ticket/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print; exit}')"
    cat >"$out/result.json" <<JSON
{ "ticketId": "${tid:-t-001}", "passed": true, "attempts": 1, "summary": "green",
  "newTests": [], "testEdits": [],
  "flipFlop": "not-applicable", "flipFlopReason": "context-suite stub: no testable behaviour change" }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A fresh git repo with one commit (so rev-parse --show-toplevel works) and the
# LCARS scaffold. No CONTEXT.md, no pack — the "must generate" baseline.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" \
      && git init -q && git config user.email t@t && git config user.name t \
      && echo "hello" > README.md && git add README.md && git commit -qm init )
  mkdir -p "$repo/.git/lcars/missions"
  echo "$repo"
}

# Stubs + logs live OUTSIDE the repo (in a sibling bin dir) so they never show
# up in the target repo's `git status` — the zero-footprint contract under test.
# Echoes the bin dir; the caller uses $BIN/worker and $BIN/gh.
arm() { # repo
  local bin; bin="$1.bin"; rm -rf "$bin"; mkdir -p "$bin"
  make_worker_stub "$bin/worker"; make_gh_stub "$bin/gh"
  export GH_LOG="$bin/gh.log"; : >"$GH_LOG"
  export WORKER_LOG="$bin/worker.log"; : >"$WORKER_LOG"
  export WORKER_CALLS="$bin/calls"; rm -rf "$WORKER_CALLS"; mkdir -p "$WORKER_CALLS"
  BIN="$bin"
}

ctx_calls() { local n; n="$(grep -c 'role=context-pack ' "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# The realpath of a repo dir — macOS resolves /var → /private/var, and
# `git rev-parse --show-toplevel` returns the resolved path, so the resolver's
# output and the pack path are realpath-based. Compare against the same.
rp() { ( cd "$1" && pwd -P ); }

# ==========================================================================
# Behaviour 1 — no CONTEXT.md + no pack → resolution GENERATES the pack, ONCE,
# and the working tree stays CLEAN (no CONTEXT.md created).
# ==========================================================================
r1="$(new_repo)"; arm "$r1"
clean_before="$(cd "$r1" && git status --porcelain)"
out1="$( cd "$r1" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" context-source 2>/dev/null )"
# The pack path is derived from `git rev-parse --git-dir` ($PWD/.git), so it
# carries the $PWD form (NOT the symlink-resolved --show-toplevel form).
pack1="$r1/.git/lcars/context-pack.md"
check "1. resolver prints the generated pack path" \
  "[ \"$out1\" = \"$pack1\" ]"
check "1. the pack file was actually created in .git/lcars/" \
  "[ -f \"$r1/.git/lcars/context-pack.md\" ]"
check "1. the context-pack worker was invoked exactly once" \
  "[ \"$(ctx_calls "$WORKER_LOG")\" -eq 1 ]"
check "1. NO CONTEXT.md was created in the working tree" \
  "[ ! -f \"$r1/CONTEXT.md\" ]"
check "1. working tree stays CLEAN (git status --porcelain unchanged)" \
  "[ -z \"$clean_before\" ] && [ -z \"\$(cd '$r1' && git status --porcelain)\" ]"
check "1. the context worker runs read-only (no Bash/Edit)" \
  "! grep 'role=context-pack ' '$WORKER_LOG' | qgrep -qE 'Bash|Edit'"

# ==========================================================================
# Behaviour 2 — pack already present → REUSED, NOT regenerated (worker stub is
# NOT invoked a second time; assert via the invocation counter).
# ==========================================================================
r2="$(new_repo)"; arm "$r2"
mkdir -p "$r2/.git/lcars"
printf '# pre-existing pack\n' > "$r2/.git/lcars/context-pack.md"
out2="$( cd "$r2" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" context-source 2>/dev/null )"
check "2. resolver returns the existing pack path" \
  "[ \"$out2\" = \"$r2/.git/lcars/context-pack.md\" ]"
check "2. the worker was NOT invoked (pack reused, not regenerated)" \
  "[ \"$(ctx_calls "$WORKER_LOG")\" -eq 0 ]"
check "2. the pre-existing pack content is untouched" \
  "grep -q 'pre-existing pack' '$r2/.git/lcars/context-pack.md'"

# ==========================================================================
# Behaviour 3 — CONTEXT.md present → used directly; NO pack generated.
# ==========================================================================
r3="$(new_repo)"; arm "$r3"
printf '# Repo CONTEXT\nhand-written facts\n' > "$r3/CONTEXT.md"
( cd "$r3" && git add CONTEXT.md && git commit -qm ctx )
out3="$( cd "$r3" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" context-source 2>/dev/null )"
check "3. resolver returns the repo-root CONTEXT.md" \
  "[ \"$out3\" = \"$(rp "$r3")/CONTEXT.md\" ]"
check "3. NO pack was generated (worker never invoked)" \
  "[ \"$(ctx_calls "$WORKER_LOG")\" -eq 0 ]"
check "3. no context-pack.md exists under .git/lcars/" \
  "[ ! -f \"$r3/.git/lcars/context-pack.md\" ]"

# ==========================================================================
# Behaviour 3b — CONTEXT.md added AFTER init (filesystem check, not config):
# its mere presence wins over generating a pack.
# ==========================================================================
r3b="$(new_repo)"; arm "$r3b"
# config.json says contextFile=null (as if init ran before CONTEXT.md existed)…
cat > "$r3b/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "x", "contextFile": null, "testCommand": null, "comprehensionBudget": 1200, "created": "2026-01-01T00:00:00Z" }
JSON
# …but a CONTEXT.md now exists on disk.
printf '# late CONTEXT\n' > "$r3b/CONTEXT.md"
( cd "$r3b" && git add CONTEXT.md && git commit -qm late )
out3b="$( cd "$r3b" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" context-source 2>/dev/null )"
check "3b. a CONTEXT.md added after init still wins (resolver returns it)" \
  "[ \"$out3b\" = \"$(rp "$r3b")/CONTEXT.md\" ]"
check "3b. no pack generated despite config contextFile=null" \
  "[ \"$(ctx_calls "$WORKER_LOG")\" -eq 0 ] && [ ! -f \"$r3b/.git/lcars/context-pack.md\" ]"

# ==========================================================================
# Behaviour 4 — Readership + PURITY. The resolved source path appears in the
# Validate / Plan / Plan-Review / Implement worker prompts; it appears in
# NEITHER the research-questions nor the research-agent prompts.
# ==========================================================================
# Build a mission rich enough to walk Validate → … → Implement against the stub.
new_full_mission() {
  local repo; repo="$(new_repo)"
  local m="$repo/.git/lcars/missions/lcars-20260530-001"
  mkdir -p "$m/research"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
**Out of Scope:**
- Per-component theming
**Constraints:**
- Existing CSS variables
EOF
  cat >"$m/research/1.json" <<'EOF'
{ "question": "q", "recommendation": "do it", "supporting_points": ["a","b"] }
EOF
  cat >"$m/validated-plan.md" <<'EOF'
# Validated Plan
## Synthesis
x
## Decisions
- y
## Rationale
z
EOF
  cat >"$m/plan.json" <<'EOF'
[ { "id": "t-001", "title": "T", "description": "d", "acceptanceCriteria": ["a"], "estimatedReadLoc": 10, "estimatedTestLoc": 10, "estimatedNewLoc": 10, "dependencies": [], "rationale": "r" } ]
EOF
  cp "$m/plan.json" "$m/approved-plan.json"
  echo "$repo"
}

prompt_of() { cat "$1/$2".*.txt 2>/dev/null; }

# The pack path the resolver hands the declarative Stages ($PWD/.git form).
pack_path() { echo "$1/.git/lcars/context-pack.md"; }
state_at() { # mission-dir  stage
  cat > "$1/state.json" <<JSON
{ "id": "lcars-20260530-001", "type": "feature", "title": "Add dark mode", "stage": "$2", "githubIssue": 42, "branch": "lcars/lcars-20260530-001", "base": "main" }
JSON
}

# Validate
rV="$(new_full_mission)"; arm "$rV"
state_at "$rV/.git/lcars/missions/lcars-20260530-001" validate
( cd "$rV" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" validate --mission lcars-20260530-001 >/dev/null 2>&1 )
check "4. Validate worker prompt names the context source path" \
  "prompt_of '$WORKER_CALLS' validate | qgrep -qF '$(pack_path "$rV")'"

# Plan
rP="$(new_full_mission)"; arm "$rP"
state_at "$rP/.git/lcars/missions/lcars-20260530-001" plan
( cd "$rP" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" plan --mission lcars-20260530-001 >/dev/null 2>&1 )
check "4. Plan worker prompt names the context source path" \
  "prompt_of '$WORKER_CALLS' plan | qgrep -qF '$(pack_path "$rP")'"

# Plan Review — gets the context source, but STILL not prd.md / validated-plan.md
# as readable artifact PATHS (independence preserved).
rR="$(new_full_mission)"; arm "$rR"
mrR="$rR/.git/lcars/missions/lcars-20260530-001"
state_at "$mrR" plan-review
( cd "$rR" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" plan-review --mission lcars-20260530-001 >/dev/null 2>&1 )
check "4. Plan-Review worker prompt names the context source path" \
  "prompt_of '$WORKER_CALLS' plan-review | qgrep -qF '$(pack_path "$rR")'"
check "4. Plan-Review prompt is NOT fed the prd.md PATH (independence preserved)" \
  "! prompt_of '$WORKER_CALLS' plan-review | qgrep -qF '$mrR/prd.md'"
check "4. Plan-Review prompt is NOT fed the validated-plan.md PATH" \
  "! prompt_of '$WORKER_CALLS' plan-review | qgrep -qF '$mrR/validated-plan.md'"

# Implement (Test Writer + Implementer)
rI="$(new_full_mission)"; arm "$rI"
mrI="$rI/.git/lcars/missions/lcars-20260530-001"
state_at "$mrI" implement
cat > "$mrI/waves.json" <<'JSON'
[ { "wave": 1, "tickets": ["t-001"] } ]
JSON
# S182: this fixture is about the worker PROMPT, not about the no-runner wall —
# give it a testCommand so it gets past the pre-worker guard (a repo with NO
# test command now parks before any worker is hired, which is the point of S182).
( cd "$rI" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_TEST_CMD=true \
    bash "$SCRIPT" implement-ticket --mission lcars-20260530-001 --ticket t-001 >/dev/null 2>&1 )
check "4. unified TDD worker prompt names the context source path" \
  "prompt_of '$WORKER_CALLS' implement-tdd | qgrep -qF '$(pack_path "$rI")'"

# PURITY — Research must NEVER receive the context source. The pack EXISTS on
# disk (pre-generated), so if Research leaked it the path would be available;
# assert neither the question-gen nor the agent prompts name the pack OR a
# CONTEXT.md.
rRes="$(new_full_mission)"; arm "$rRes"
state_at "$rRes/.git/lcars/missions/lcars-20260530-001" align
printf '# pack\n' > "$rRes/.git/lcars/context-pack.md"
( cd "$rRes" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" research --mission lcars-20260530-001 >/dev/null 2>&1 )
# The pack path must not reach either research worker, and neither may carry the
# "## Repo context" block that context_extra_block injects into the declarative
# Stages. (The research-agent TEMPLATE prose mentions "CONTEXT.md" as a design
# pointer — that is fixed template text, NOT an injected context source, so we
# assert on the pack path + the injected block, which are the real leak vectors.)
check "4. PURITY: research-questions prompt does NOT name the pack path" \
  "! prompt_of '$WORKER_CALLS' research-questions | qgrep -qF '.git/lcars/context-pack.md'"
check "4. PURITY: research-agent prompt does NOT name the pack path" \
  "! prompt_of '$WORKER_CALLS' research-agent | qgrep -qF '.git/lcars/context-pack.md'"
check "4. PURITY: research-questions prompt has NO injected '## Repo context' block" \
  "! prompt_of '$WORKER_CALLS' research-questions | qgrep -qF '## Repo context'"
check "4. PURITY: research-agent prompt has NO injected '## Repo context' block" \
  "! prompt_of '$WORKER_CALLS' research-agent | qgrep -qF '## Repo context'"

# ==========================================================================
# Behaviour 5 (S194) — THE BEST-EFFORT GUARD MUST ACTUALLY BE BEST-EFFORT.
# cmd_implement resolves the durable context source ONCE, up front, behind a
# comment that says "a failure here just leaves the old lazy path to try again
# per ticket". It did the opposite: resolve_context_source ends in `die`, and
# `die` is `printf >&2; exit 1` — so `resolve_context_source >/dev/null 2>&1 ||:`
# could not catch it (a redirection is not a subshell) and the WHOLE STAGE
# exited rc=1, with `2>&1` throwing the reason away. Measured on copilot: 52
# bytes of output and a 696-line `bash -x` trace containing zero non-trace
# output. Two requirements, both asserted here:
#   a. the failure does NOT kill the stage — it reaches the wave driver;
#   b. the REASON is not discarded — it reaches the caller (and therefore the
#      BUG-051 err_tail the driver puts on the board event).
# ==========================================================================

# A worker stub that answers every OTHER role normally but writes NOTHING for
# context-pack — exactly what copilot's default model did (only read tools were
# offered, so `create` was never available and the pack was never created).
make_dead_pack_worker() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="${2:-}"; shift 2 ;; *) shift ;; esac; done
printf 'role=%s tools=\n' "$LCARS_WORKER_ROLE" >>"$WORKER_LOG"
printf '%s' "$prompt" >"$WORKER_CALLS/$LCARS_WORKER_ROLE.$$.txt"
# context-pack: reply only, create no file (the measured copilot failure).
exit 0
EOF
  chmod +x "$1"
}

r5="$(new_full_mission)"; arm "$r5"
make_dead_pack_worker "$BIN/worker"
m5="$r5/.git/lcars/missions/lcars-20260530-001"
state_at "$m5" implement
cat > "$m5/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001", "issue": null }
      ] }
  ]
}
JSON
# A real branch is NOT created — the stage's serial in-tree fallback is enough,
# and this leg is about the guard, not about building a ticket.
OUT5="$( cd "$r5" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" \
    LCARS_GIT_BIN="$(command -v git)" LCARS_TEST_CMD=true \
    LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 \
    bash "$SCRIPT" implement --mission lcars-20260530-001 2>&1 )"

check "5a. the context-pack worker WAS hired and produced no pack (the defect's shape)" \
  "[ \"$(ctx_calls "$WORKER_LOG")\" -ge 1 ] && [ ! -f \"$r5/.git/lcars/context-pack.md\" ]"
# THE STAGE SURVIVED: it reached the wave driver, which emits wave_start. Before
# the cure the process was already dead at the resolve line and no such event
# (nor anything else past it) was ever written.
check "5b. the stage is NOT killed by the failure — it reaches the wave driver" \
  "grep -q '\"type\": *\"wave_start\"' '$m5/events.jsonl' 2>/dev/null"
# THE REASON SURVIVED: the caller can see WHY, so the driver's BUG-051 err_tail
# names the cause instead of a bare 'failed'.
check "5c. the REASON reaches the caller (not discarded by 2>&1 >/dev/null)" \
  "printf '%s' \"\$OUT5\" | qgrep -qi 'context'"
check "5d. and the reason names the context pack it could not produce" \
  "printf '%s' \"\$OUT5\" | qgrep -qF 'context-pack.md'"

# ==========================================================================
echo
printf 'lcars context: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
