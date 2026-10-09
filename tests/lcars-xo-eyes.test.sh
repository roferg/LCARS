#!/usr/bin/env bash
# tests/lcars-xo-eyes.test.sh — S261: the reviewer gets to look for itself.
#
# WHAT WAS MEASURED, AND WHY THIS SUITE EXISTS AT ALL. On 2026-10-08 (S260) the
# reviewer was run against the captain's buddy on three milestones of a real
# product. Number One found 0 real defects and filed 0; the buddy found 4 and
# filed 4. Of the six recorded failures, THREE WERE THE FENCE — 10 of 13 drawn
# parts unreachable, a HOME store read fenced out, a shell action fenced out —
# and one was that it could not run a thing and watch it. Not one was a prompt
# problem. Every previous round revised the prompt.
#
# So the S168 clause is AMENDED, with the captain's explicit approval recorded at
# 2026-10-08 19:33 MDT (`lcars-dev/OVERNIGHT-2026-10-08.md` § The fence change,
# as approved): the reviewer gets a real shell, and the protection that must
# still be true — IT CANNOT MODIFY THE THING IT IS REVIEWING — is carried by a
# DISPOSABLE COPY instead of by denying a shell.
#
# THE SHAPE, AND THE ONE THING THIS SUITE IS REALLY FOR: the shell is never
# issued without the copy. There are TWO toolset roles, not one —
#   `number-one`       the paper gates (`answer`, `recheck`): the S168 posture,
#                      byte-for-byte, because those modes have no copy;
#   `number-one-live`  the Verify LOOK: the same posture PLUS a shell, handed out
#                      by `spawn_number_one` only when a disposable detached
#                      worktree is actually standing, and with the worker's cwd
#                      INSIDE it.
# A role table cannot be traded for the other by accident: section 2 drives the
# real chokepoint and reads which role the adapter was handed.
#
# WHAT IS NOT TOUCHED, and is re-asserted here so a later session cannot read
# this suite as permission:
#   • the argv fence in `xo-run.py` (`declared_escape`, `refuse_reason`) — the
#     DECLARED-step path ("it proposes, the harness executes") is unchanged and
#     still shell-free. The two paths coexist; `lcars-xo-refusal` owns that one.
#   • the post-turn mission-state fence audit (`worker_fence_check`) — section 4
#     proves it still KILLS a shelled reviewer that writes judge-critical state.
#   • the worker's own HOME stays REAL. Chrome under a throwaway HOME times out
#     on CDP and the look silently scores everything LOW, and the engine's own
#     credentials live there. The THROWAWAY HOME is what the reviewer types in
#     front of the PRODUCT's commands, and section 5 proves it is told the path.
#
# EVERY assertion here is paired with something that makes it fire: a control
# case, a mutation, or both. ZERO SPEND: a PATH shim fakes both engines.
#
# Usage: bash tests/lcars-xo-eyes.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
XOSH="$REPO_ROOT/skills/lcars-xo/xo.sh"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
PROMPTS="$REPO_ROOT/skills/lcars-xo/prompts"
EVALUATE_MD="$PROMPTS/evaluate.md"
GUARD="$REPO_ROOT/tests/lib/evaluate_prompt_guard.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND ------------------------------------------------------------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
export SPEND_LOG="$TMPROOT/spend.log"; : >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"\$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

printf '\n=== S261: the reviewer gets to look for itself ===\n'

# ===========================================================================
# 1. THE ADAPTER — the shell comes WITH the copy, and never without it
# ===========================================================================
echo ""
echo "1. the two roles: the paper gate keeps the S168 posture, the look gets a shell"

AOUT="$TMPROOT/aout"; mkdir -p "$AOUT"
# The tool list and the deny list, read out of the REAL argv the adapter emits
# (not out of its source), so a role that is never wired into argv cannot pass.
tools_of() { # <cli> <role> → the list that follows the cli's tools flag
  bash "$ADAPTER" argv "$1" "$2" "$AOUT" 2>/dev/null | "$PY" -c '
import sys
flag = {"copilot": "--available-tools", "claude": "--allowedTools"}[sys.argv[1]]
rows = [l.rstrip("\n") for l in sys.stdin]
for i, r in enumerate(rows):
    if r == flag and i + 1 < len(rows):
        print(rows[i + 1]); break
' "$1"
}
has() { printf ',%s,' "$1" | grep -qF ",$2,"; }

LIVE_CLAUDE="$(tools_of claude number-one-live)"
GATE_CLAUDE="$(tools_of claude number-one)"
LIVE_COP="$(tools_of copilot number-one-live)"
GATE_COP="$(tools_of copilot number-one)"
LIVE_DENY="$(bash "$ADAPTER" deny claude number-one-live 2>/dev/null)"
GATE_DENY="$(bash "$ADAPTER" deny claude number-one 2>/dev/null)"

check "1z. the seam reads a list at all for every role this section judges" \
  '[ -n "$LIVE_CLAUDE" ] && [ -n "$GATE_CLAUDE" ] && [ -n "$LIVE_COP" ] && [ -n "$GATE_COP" ]'
check "1a. THE BEHAVIOUR — claude/number-one-live holds Bash" \
  'has "$LIVE_CLAUDE" Bash'
check "1a2. CONTROL — claude/number-one (the paper gate) still does NOT" \
  '! has "$GATE_CLAUDE" Bash'
check "1b. …and Bash is GONE from its deny list, so the grant is real on claude" \
  '[ -n "$LIVE_DENY" ] && ! printf ",%s," "$LIVE_DENY" | grep -qF ",Bash,"'
check "1b2. CONTROL — the paper gate still DENIES Bash (S168, untouched)" \
  'printf ",%s," "$GATE_DENY" | grep -qF ",Bash,"'
check "1c. …but the NETWORK is still denied: no WebSearch, no WebFetch" \
  'printf ",%s," "$LIVE_DENY" | grep -qF ",WebSearch," &&
   printf ",%s," "$LIVE_DENY" | grep -qF ",WebFetch,"'
check "1c2. …and NotebookEdit, so the deny table has no silent hole" \
  'printf ",%s," "$LIVE_DENY" | grep -qF ",NotebookEdit,"'
# NB the argv file is written first rather than piped: `adapter_argv`'s last
# statement is a conditional `printf`, so on claude it RETURNS 1 with a perfect
# argv on stdout — an inherited quirk, and under `pipefail` it would mask grep.
bash "$ADAPTER" argv claude number-one-live "$AOUT" >"$TMPROOT/argv-live.txt" 2>/dev/null
check "1d. the live role's deny list is NON-EMPTY — adapter_spawn refuses an unfenced claude argv" \
  '[ -n "$LIVE_DENY" ] && grep -qx -- "--disallowedTools" "$TMPROOT/argv-live.txt"'
check "1e. it can still see and author: Read, Grep, Glob, Write all survive" \
  'has "$LIVE_CLAUDE" Read && has "$LIVE_CLAUDE" Grep &&
   has "$LIVE_CLAUDE" Glob && has "$LIVE_CLAUDE" Write'
check "1f. THE BEHAVIOUR — copilot/number-one-live holds bash" \
  'has "$LIVE_COP" bash'
check "1f2. CONTROL — copilot/number-one still does not" \
  '! has "$GATE_COP" bash'
check "1g. copilot's live role can still see: view, rg, glob" \
  'has "$LIVE_COP" view && has "$LIVE_COP" rg && has "$LIVE_COP" glob'
check "1h. the paper gate is BYTE-FOR-BYTE the S168 posture on both engines" \
  '[ "$GATE_CLAUDE" = "Read,Grep,Glob,Write" ] &&
   [ "$GATE_DENY" = "Edit,Bash,NotebookEdit,WebSearch,WebFetch" ] &&
   [ "$GATE_COP" = "view,rg,glob" ]'
# THE TRIPWIRE: these tables are really consulted, and an unknown role is still
# a hard non-zero from BOTH of them. Without this, every row above could be
# passing against an adapter that answers anything.
check "1i. TRIPWIRE — an unknown role still exits non-zero from argv" \
  '! bash "$ADAPTER" argv claude number-one-liveX "$AOUT" >/dev/null 2>&1'
check "1i2. TRIPWIRE — …and from deny" \
  '! bash "$ADAPTER" deny claude number-one-liveX >/dev/null 2>&1 &&
   ! bash "$ADAPTER" deny copilot number-one-liveX >/dev/null 2>&1'

# ===========================================================================
# 2. THE CHOKEPOINT — a disposable copy, or no shell. Driven for real.
# ===========================================================================
echo ""
echo "2. run.sh spawn-number-one: the copy is what buys the shell"

repo="$TMPROOT/repo"
mkdir -p "$repo"
( cd "$repo" && git init -q -b main &&
  git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'original\n' >"$repo/product.py"
( cd "$repo" && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$repo/.git/lcars/missions/lcars-1/xo"
cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$repo/.git/lcars/missions/lcars-1/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-08T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

IN="$TMPROOT/in"; mkdir -p "$IN"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "x"}]}' >"$IN/criteria.json"

# THE DISPOSABLE COPY, made the way the look makes it: detached, off the branch.
WT="$TMPROOT/wt"
( cd "$repo" && git worktree add --detach "$WT" main ) >/dev/null 2>&1
THOME="$TMPROOT/throwaway-home"; mkdir -p "$THOME"
check "2z. the disposable copy really is a detached worktree of the branch" \
  '[ -f "$WT/product.py" ] &&
   [ "$( cd "$WT" && git rev-parse --abbrev-ref HEAD )" = "HEAD" ]'

# The seam: the adapter is handed <cli> <role> <outdir> <prompt> as $2..$5, and
# it runs with the worker's own cwd. Record all four facts.
DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${3:-}" >"$XO_ROLE_DUMP"
printf '%s' "$PWD"   >"$XO_CWD_DUMP"
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
# A SHELLED REVIEWER, FAKED AT THE RIGHT LAYER: whatever it does, it does in
# the cwd it was given. That is the whole mechanism under test.
printf 'scribble\n' >"$PWD/SCRIBBLE.txt" 2>/dev/null || true
printf 'clobbered\n' >"$PWD/product.py" 2>/dev/null || true
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

spawn_n1() { # <tag> <mode> [worktree] [throwaway-home]
  local tag="$1" mode="$2" wt="${3:-}" th="${4:-}"
  rm -f "$WT/SCRIBBLE.txt" "$repo/SCRIBBLE.txt"
  ( cd "$WT" && git checkout -q -- . ) >/dev/null 2>&1
  ( cd "$repo" && git checkout -q -- . ) >/dev/null 2>&1
  ( cd "$repo" && \
    XO_ROLE_DUMP="$TMPROOT/role-$tag.txt" \
    XO_CWD_DUMP="$TMPROOT/cwd-$tag.txt" \
    XO_PROMPT_DUMP="$TMPROOT/prompt-$tag.txt" \
    LCARS_WORKER_ADAPTER="$DUMP" LCARS_WORKER_BIN="$WORKER" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_WORKTREE="$wt" LCARS_XO_THROWAWAY_HOME="$th" \
    bash "$RUNSH" spawn-number-one --mission lcars-1 \
      --mode "$mode" --outdir "$TMPROOT/out-$tag" ) >"$TMPROOT/log-$tag.txt" 2>&1
  printf '%s' "$?" >"$TMPROOT/rc-$tag.txt"
}
roleof() { cat "$TMPROOT/role-$1.txt" 2>/dev/null; }
cwdof()  { cat "$TMPROOT/cwd-$1.txt" 2>/dev/null; }

spawn_n1 live evaluate "$WT" "$THOME"
check "2a. THE BEHAVIOUR — with a copy standing, the adapter is handed number-one-live" \
  '[ "$(roleof live)" = "number-one-live" ]'
check "2b. …and the worker RUNS IN the copy" \
  '[ "$(cwdof live)" = "$WT" ] ||
   [ "$( cd "$(cwdof live)" 2>/dev/null && pwd -P )" = "$( cd "$WT" && pwd -P )" ]'
WT_SCRIBBLED=0
[ -f "$WT/SCRIBBLE.txt" ] && WT_SCRIBBLED=1
REPO_DIRTY_LIVE="$( cd "$repo" && git status --porcelain )"
check "2c. …so what it wrote landed in the COPY" '[ "$WT_SCRIBBLED" = 1 ]'
check "2d. THE PROTECTION — the captain's own checkout is untouched" \
  '[ -z "$REPO_DIRTY_LIVE" ] && [ "$(cat "$repo/product.py")" = "original" ]'

# THE MUTATION FOR 2d: the SAME fake worker, with no copy to stand in, dirties
# the real checkout. 2d is therefore not passing on a worker that writes nothing.
spawn_n1 nowt evaluate "" ""
check "2e. CONTROL — with NO copy the adapter is handed the paper-gate role" \
  '[ "$(roleof nowt)" = "number-one" ]'
check "2f. MUTATION — and the same worker, cwd in the real repo, DOES dirty it" \
  '[ -n "$( cd "$repo" && git status --porcelain )" ]'
( cd "$repo" && git checkout -q -- . ) >/dev/null 2>&1; rm -f "$repo/SCRIBBLE.txt"

spawn_n1 ghost evaluate "$TMPROOT/not-a-worktree" "$THOME"
check "2g. CONTROL — a copy that is not there buys NO shell (never on a promise)" \
  '[ "$(roleof ghost)" = "number-one" ]'
( cd "$repo" && git checkout -q -- . ) >/dev/null 2>&1; rm -f "$repo/SCRIBBLE.txt"

# The paper gates keep the old posture even if something hands them a worktree:
# `answer` and `recheck` are judged off the record, not by running anything.
spawn_n1 answer answer "$WT" "$THOME"
check "2h. the paper gate (answer mode) stays fenced even WITH a worktree in the env" \
  '[ "$(roleof answer)" = "number-one" ]'
( cd "$repo" && git checkout -q -- . ) >/dev/null 2>&1; rm -f "$repo/SCRIBBLE.txt"

# --- AND THROUGH THE REAL ADAPTER, NOT A STUB -------------------------------
# Every row above stubs `worker-adapter.sh`, which is the right seam for reading
# the ROLE. But a stub cannot prove the real adapter turns that role into an
# argv the engine will honour, or that the cwd survives the exec. So this pair
# runs the REAL adapter with a fake BINARY that records its own argv and cwd.
echo ""
echo "2b. the same thing through the real worker-adapter, with a fake engine binary"
FAKEBIN="$TMPROOT/fakebin.sh"
cat >"$FAKEBIN" <<'FB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$XO_ARGV_DUMP"
printf '%s' "$PWD" >"$XO_CWD_DUMP"
exit 0
FB
chmod +x "$FAKEBIN"
real_spawn() { # <tag> <worktree> <cli>
  ( cd "$repo" && \
    XO_ARGV_DUMP="$TMPROOT/rargv-$1.txt" XO_CWD_DUMP="$TMPROOT/rcwd-$1.txt" \
    LCARS_WORKER_BIN="$FAKEBIN" LCARS_WORKER_CLI="$3" \
    LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_WORKTREE="$2" LCARS_XO_THROWAWAY_HOME="$THOME" \
    bash "$RUNSH" spawn-number-one --mission lcars-1 \
      --mode evaluate --outdir "$TMPROOT/rout-$1" ) >/dev/null 2>&1
}
real_spawn claude "$WT" claude
real_spawn claudegate "" claude
real_spawn copilot "$WT" copilot
check "2i. the fake engine was reached at all, both ways" \
  '[ -s "$TMPROOT/rargv-claude.txt" ] && [ -s "$TMPROOT/rargv-claudegate.txt" ]'
check "2j. REAL ADAPTER — the claude argv the engine is handed carries Bash" \
  'grep -qxF "Read,Grep,Glob,Write,Bash" "$TMPROOT/rargv-claude.txt"'
check "2j2. …and its deny list no longer takes Bash away" \
  'grep -qxF "Edit,NotebookEdit,WebSearch,WebFetch" "$TMPROOT/rargv-claude.txt" &&
   grep -qx -- "--disallowedTools" "$TMPROOT/rargv-claude.txt"'
check "2k. CONTROL — with no copy the engine is handed the S168 argv, Bash denied" \
  'grep -qxF "Read,Grep,Glob,Write" "$TMPROOT/rargv-claudegate.txt" &&
   grep -qxF "Edit,Bash,NotebookEdit,WebSearch,WebFetch" "$TMPROOT/rargv-claudegate.txt"'
check "2l. REAL ADAPTER — the engine itself runs INSIDE the copy" \
  '[ "$( cd "$(cat "$TMPROOT/rcwd-claude.txt")" && pwd -P )" = "$( cd "$WT" && pwd -P )" ]'
check "2m. CONTROL — with no copy it runs in the repo, not the copy" \
  '[ "$( cd "$(cat "$TMPROOT/rcwd-claudegate.txt")" && pwd -P )" != "$( cd "$WT" && pwd -P )" ]'
check "2n. REAL ADAPTER — copilot is handed view,rg,glob,bash and no deny flag" \
  'grep -qxF "view,rg,glob,bash" "$TMPROOT/rargv-copilot.txt" &&
   ! grep -qx -- "--disallowedTools" "$TMPROOT/rargv-copilot.txt"'
( cd "$repo" && git checkout -q -- . ) >/dev/null 2>&1; rm -f "$repo/SCRIBBLE.txt"

# ===========================================================================
# 3. THE PROTECTION THAT MUST SURVIVE — mission state is still fatal
# ===========================================================================
echo ""
echo "3. a shelled reviewer that writes judge-critical state is still KILLED"

# The post-turn fence audit (`worker_fence_check`) is what makes "it cannot
# modify the thing it is reviewing" true of the MISSION's own state, which lives
# outside the copy. The live role must not be exempt from it.
FENCE_DUMP="$TMPROOT/fence.sh"
cat >"$FENCE_DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${3:-}" >"$XO_ROLE_DUMP"
[ -n "${XO_WRITE_STATE:-}" ] && printf '{"id":"lcars-1","stage":"done"}\n' >"$XO_WRITE_STATE"
exit 0
AD
chmod +x "$FENCE_DUMP"

fence_spawn() { # <tag> <write-state-path-or-empty>
  ( cd "$repo" && \
    XO_ROLE_DUMP="$TMPROOT/frole-$1.txt" XO_WRITE_STATE="$2" \
    LCARS_WORKER_ADAPTER="$FENCE_DUMP" LCARS_WORKER_BIN="$WORKER" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_WORKTREE="$WT" LCARS_XO_THROWAWAY_HOME="$THOME" \
    bash "$RUNSH" spawn-number-one --mission lcars-1 \
      --mode evaluate --outdir "$TMPROOT/fout-$1" ) >"$TMPROOT/flog-$1.txt" 2>&1
  printf '%s' "$?" >"$TMPROOT/frc-$1.txt"
}
fence_spawn breach "$repo/.git/lcars/missions/lcars-1/state.json"
check "3a. it ran as the LIVE role (so this is not the old fence passing)" \
  '[ "$(cat "$TMPROOT/frole-breach.txt" 2>/dev/null)" = "number-one-live" ]'
LIVE_ROLE_BREACH='[ "$(cat "$TMPROOT/frole-breach.txt" 2>/dev/null)" = "number-one-live" ]'
check "3b. THE BEHAVIOUR — the LIVE spawn DIES, naming a worker fence breach" \
  "$LIVE_ROLE_BREACH"' &&
   [ "$(cat "$TMPROOT/frc-breach.txt")" != "0" ] &&
   grep -qi "FENCE BREACH" "$TMPROOT/flog-breach.txt"'
check "3b2. …and it names state.json, the file that judges its own output" \
  "$LIVE_ROLE_BREACH"' && grep -q "state.json" "$TMPROOT/flog-breach.txt"'
# AND IT DIES BEFORE THE VERDICT CHANNEL RUNS. `die` inside `worker_spawn` is
# what stops `number_one_claim_output` claiming a breaching worker's answer —
# measured here, because a subshell around the cwd move would have downgraded it
# to a return code and the claim would have gone ahead.
check "3b3. …and no verdict is claimed out of a breaching turn" \
  "$LIVE_ROLE_BREACH"' && [ ! -s "$TMPROOT/fout-breach/xo-verdict.json" ]'
fence_spawn clean ""
check "3c. CONTROL — the same live role writing no state is NOT killed" \
  '[ "$(cat "$TMPROOT/frole-clean.txt" 2>/dev/null)" = "number-one-live" ] &&
   [ "$(cat "$TMPROOT/frc-clean.txt")" = "0" ] &&
   ! grep -qi "FENCE BREACH" "$TMPROOT/flog-clean.txt"'

# ===========================================================================
# 4. WHAT THE WORKER IS TOLD — the copy, by path, in the round's own prompt
# ===========================================================================
echo ""
echo "4. the round tells the reviewer it may run things, and where"

P_LIVE="$TMPROOT/prompt-live.txt"
P_NOWT="$TMPROOT/prompt-nowt.txt"
check "4z. both prompts were captured at all" '[ -s "$P_LIVE" ] && [ -s "$P_NOWT" ]'
check "4a. THE BEHAVIOUR — the prompt NAMES the disposable copy's path" \
  'grep -qF "$WT" "$P_LIVE"'
check "4b. …says it is a throwaway copy whose damage dies with it" \
  'tr "\n" " " <"$P_LIVE" | tr -s " " | grep -qi "dies with the copy"'
check "4c. …tells it, in so many words, that it HAS a shell" \
  'tr "\n" " " <"$P_LIVE" | tr -s " " | grep -qi "you have a real shell"'
check "4d. …names the THROWAWAY HOME to put in front of the product's commands" \
  'grep -qF "$THOME" "$P_LIVE"'
check "4e. …and says its OWN home is not that one (the CDP landmine)" \
  'tr "\n" " " <"$P_LIVE" | tr -s " " | grep -qi "your own HOME is the real one"'
check "4f. …and tells it not to reach back into the captain's checkout" \
  'tr "\n" " " <"$P_LIVE" | tr -s " " | grep -qi "never reach back"'
check "4g. CONTROL — with no copy the round promises NONE of it" \
  '! tr "\n" " " <"$P_NOWT" | tr -s " " | grep -qi "you have a real shell" &&
   ! grep -qF "$WT" "$P_NOWT"'
check "4h. CONTROL — and the rest of the prompt is still there either way" \
  'grep -q "Your output file" "$P_LIVE" && grep -q "Your output file" "$P_NOWT" &&
   grep -q "xo-verdict.json" "$P_LIVE" && grep -q "xo-verdict.json" "$P_NOWT"'

# ===========================================================================
# 5. evaluate.md — the refusal is replaced by the discipline, not deleted
# ===========================================================================
echo ""
echo "5. the prompt template: go and look, instead of 'you are not getting a shell'"

check "5a. THE BEHAVIOUR — the refusal sentence is GONE from the template" \
  '! tr "\n" " " <"$EVALUATE_MD" | tr -s " " |
     grep -q "You have no shell, and you are not getting one"'
check "5a2. …and gone from the ASSEMBLED prompt, which is what a model reads" \
  '! tr "\n" " " <"$P_LIVE" | tr -s " " |
     grep -q "You have no shell, and you are not getting one"'
check "5b. it tells the reviewer to run the product itself and watch it" \
  'tr "\n" " " <"$EVALUATE_MD" | tr -s " " | grep -qi "run it yourself"'
check "5c. …to try the input that must be refused" \
  'tr "\n" " " <"$EVALUATE_MD" | tr -s " " | grep -qi "bad input"'
check "5d. …and to write up what it SAW, quoted" \
  'tr "\n" " " <"$EVALUATE_MD" | tr -s " " | grep -qi "quote the transcript"'
check "5e. the DECLARED-step path survives beside it (the harness still executes those)" \
  'grep -q "xo-actions.json" "$EVALUATE_MD" &&
   tr "\n" " " <"$EVALUATE_MD" | tr -s " " | grep -qi "the harness runs"'
check "5f. the load-bearing contract still holds (the prompt guard passes)" \
  '"$PY" "$GUARD" "$P_LIVE"'
# THE MUTATION: the guard is the thing that would catch a section deleted to
# make room, so it must be shown to FIRE. Measured here on a copy with one
# required heading removed.
"$PY" - "$P_LIVE" "$TMPROOT/mangled.md" <<'PYM'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
out = "\n".join(l for l in text.splitlines()
                if "## Two decisions, one file" not in l)
open(dst, "w", encoding="utf-8").write(out)
PYM
check "5f2. MUTATION — the guard FIRES when a load-bearing section is removed" \
  '! "$PY" "$GUARD" "$TMPROOT/mangled.md" >/dev/null 2>&1'
check "5g. evaluate.md is still under its 689-line ceiling" \
  '[ "$(grep -c "" "$EVALUATE_MD")" -lt 689 ]'

# ===========================================================================
# 6. THE ARGV FENCE IS NOT OPEN — the declared-step path is unchanged
# ===========================================================================
echo ""
echo "6. the reach-step fence (xo-run.py) is untouched — the two paths coexist"

check "6a. a DECLARED step still has no shell: the refusal is still in xo-run.py" \
  'grep -q "a step has no shell" "$XORUN"'
check "6b. declared_escape and refuse_reason are both still there" \
  'grep -q "def declared_escape" "$XORUN" && grep -q "def refuse_reason" "$XORUN"'
check "6c. and nothing in this round gave a declared step a shell" \
  '! grep -qE "LCARS_XO_(ALLOW|ENABLE)_SHELL" "$XORUN"'

# ===========================================================================
# 7. ONE PLACE MINTS THE COPY, AND ONE PLACE HANDS IT OVER
# ===========================================================================
echo ""
echo "7. xo.sh hands over the one tree it already mints — no second helper"

# ASSERTED AT SOURCE LEVEL, AND SAID SO OUT LOUD. The env → worker half of this
# hand-over is driven FOR REAL in sections 2–4; this half is read off the
# source, because `xo.sh` dispatches on load and cannot be sourced to call one
# function. What is checked is that there is exactly ONE exporter and that BOTH
# setters of the tree reach it — a second exporter is the drift this guards.
check "7a. the look's own tree is handed to the spawn by name, from ONE place" \
  '[ "$(grep -c "export LCARS_XO_WORKTREE" "$XOSH")" = 1 ] &&
   grep -q "^xo_hand_over_copy()" "$XOSH"'
check "7b. …and BOTH setters of the tree call that one place, each once" \
  '"$PY" - "$XOSH" <<'"'"'PYX'"'"'
import re, sys
fn, hits = None, {}
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"^([a-z_0-9]+)\(\) \{", line)
    if m:
        fn = m.group(1)
    if line.strip() == "xo_hand_over_copy":
        hits[fn] = hits.get(fn, 0) + 1
sys.exit(0 if {"xo_reach_prepare", "xo_reach_adopt"} <= set(hits) else 1)
PYX'
check "7c. …and the throwaway HOME rides with it" \
  'grep -q "export LCARS_XO_THROWAWAY_HOME" "$XOSH"'
check "7c2. …and the hand-over is CLEARED when the copy is torn down" \
  'grep -q "unset LCARS_XO_WORKTREE LCARS_XO_THROWAWAY_HOME" "$XOSH"'
check "7d. the copy is still minted by the BUDDY's one helper, not a new one" \
  'grep -q "autopilot.sh" "$XORUN" &&
   grep -qE "\"?worktree\"?" "$XORUN" &&
   grep -q "XO_RUN_PY. prepare" "$XOSH"'
check "7e. CONTROL — run.sh never mints a worktree of its own for the reviewer" \
  '! grep -n "worktree add" "$RUNSH" | grep -qi "number.one"'
check "7f. the worker's own HOME is never set to the throwaway one" \
  '! grep -qE "HOME=\"?\$\{?LCARS_XO_THROWAWAY_HOME" "$RUNSH"'

# ===========================================================================
# 8. ZERO SPEND
# ===========================================================================
echo ""
check "8a. no engine was ever called — this suite spends nothing" \
  '[ ! -s "$SPEND_LOG" ]'

( cd "$repo" && git worktree remove --force "$WT" ) >/dev/null 2>&1

printf '\n%s\n' "-------------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
