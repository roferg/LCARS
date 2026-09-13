#!/usr/bin/env bash
#
# Fast, SCOPED test for the RESEARCH in-flight board label.
#
# The bug: the board's Research column was ALWAYS EMPTY. A Mission's stage
# POINTER stays "align" for the whole of Research (the pointer only moves at
# advance, align → validate), so no stage transition ever applied
# `lcars:research`. The only place the label was EVER written is the >20-question
# escalation in cmd_gate — so a card only ever reached the Research column by
# getting STUCK there. An ordinary Research run went align → validate with the
# card sitting in Align the whole time (CLAUDE.md build item #11, whose text
# describes exactly this defect as the thing it fixed; only the escalation half
# shipped).
#
# What is locked here — the ORDER and CONTENT of the relabel calls across a
# Research run, read off a recording `$LCARS_GH_BIN` stub:
#
#   A. NORMAL research (questions dispatched): `lcars:research` is applied when
#      Research STARTS (dropping lcars:align), and is GONE again by the time the
#      Mission reaches validate.
#   B. The 0-question SKIP path is still a Research run: same in-flight label,
#      same removal on advance.
#   C. ESCALATING research (>20 questions): UNCHANGED from before — the gate
#      still writes `lcars:research lcars:awaiting-human` / removes lcars:align.
#   D. GROUNDING-mode research (a logged bug, origin=log): the SAME in-flight
#      label as the normal path (CLAUDE.md build item #18 — one generic card).
#
# This is NOT the heavy tests/lcars-run.test.sh. The cold worker is replaced by a
# fake worker-adapter that writes canned artifacts per role, and every external
# CLI is stubbed — no model is spent and the run is sub-second.
#
# Usage: bash tests/research-inflight-label.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- a recording gh stub: every invocation lands as one line in $GH_LOG ------
make_gh() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# --- a fake worker-adapter: role-aware canned output -------------------------
# Invoked as: adapter spawn <cli> <TOOLSET> <outdir> <prompt>; the real role
# rides in $LCARS_WORKER_ROLE.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"
[ "$sub" = "spawn" ] || exit 0
case "$role" in
  research-questions)
    if [ -n "${QGEN_LINES:-}" ]; then printf '%s\n' "$QGEN_LINES" >"$outdir/questions.txt";
    else : >"$outdir/questions.txt"; fi
    ;;
  research-agent)
    cat >"$outdir/response.json" <<'JSON'
{ "question": "q", "recommendation": "do the thing", "supporting_points": ["a"] }
JSON
    ;;
  research-grounding)
    cat >"$outdir/grounding.json" <<'JSON'
{ "targets": ["src/theme/themeStore.ts:toggleTheme"], "kind": "modify-existing",
  "restated": "icon missing", "reuse_directive": "modify themeStore, do not duplicate" }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

make_worker_bin() { printf '#!/usr/bin/env bash\nexit 0\n' >"$1"; chmod +x "$1"; }

# --- a repo with a feature Mission at align + a logged bug child -------------
# BOTH carry a real githubIssue, so gh_relabel is NOT the local-only no-op.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  printf '# Context\nTest repo.\n' >"$repo/CONTEXT.md"
  local mroot="$repo/.git/lcars/missions"
  mkdir -p "$mroot"
  printf '{ "model": "claude-sonnet", "projectName": "repo" }\n' >"$repo/.git/lcars/config.json"

  mkdir -p "$mroot/feat-001"
  cat >"$mroot/feat-001/state.json" <<'JSON'
{
  "id": "feat-001",
  "type": "feature",
  "title": "A feature",
  "stage": "align",
  "githubIssue": 42
}
JSON
  printf '# Mission: A feature\n\n**Type:** feature\nBuild a feature.\n' >"$mroot/feat-001/prd.md"

  # a PARENT for the logged bug to ground against
  mkdir -p "$mroot/parent-000"
  cat >"$mroot/parent-000/state.json" <<'JSON'
{
  "id": "parent-000",
  "type": "feature",
  "title": "Theme toggle",
  "stage": "verify",
  "githubIssue": 41
}
JSON
  printf '# Mission: Theme toggle\nAdd a theme toggle.\n' >"$mroot/parent-000/prd.md"

  mkdir -p "$mroot/bug-002"
  cat >"$mroot/bug-002/state.json" <<'JSON'
{
  "id": "bug-002",
  "type": "bug",
  "origin": "log",
  "title": "icon missing",
  "stage": "align",
  "githubIssue": 43,
  "parentMission": "parent-000",
  "parentIssue": 41
}
JSON
  printf '# Mission: icon missing\n\n**Type:** bug\nThe icon vanishes.\n' >"$mroot/bug-002/prd.md"
  echo "$repo"
}

setup() {
  local repo; repo="$(new_repo)"
  make_adapter "$repo/adapter"; make_worker_bin "$repo/worker"; make_gh "$repo/gh"
  : >"$repo/gh.log"
  echo "$repo"
}

drive() { # repo [QGEN_LINES=…] subcommand args...
  local repo="$1"; shift
  OUT="$( cd "$repo" && env \
      GH_LOG="$repo/gh.log" \
      LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
      LCARS_WORKER_BIN="$repo/worker" LCARS_WORKER_CLI=claude \
      LCARS_WORKER_ADAPTER="$repo/adapter" \
      LCARS_WORKER_HANG_SECS=0 \
      QGEN_LINES="${QGEN_LINES:-}" \
      bash "$SCRIPT" "$@" 2>&1 )"
  RC=$?
}

# The ORDERED list of `gh issue edit` calls for one issue — the relabel trace.
relabels() { # repo issue -> one line per relabel, in order
  grep "issue edit ${2} " "$1/gh.log" 2>/dev/null
}
nth_relabel() { relabels "$1" "$2" | sed -n "${3}p"; }

echo "research in-flight board label"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# ==========================================================================
# A. NORMAL research (2 questions dispatched, agents fan out, save advances).
# ==========================================================================
repoA="$(setup)"
QGEN_LINES="$(printf 'What about X?\nWhat about Y?')" drive "$repoA" research --mission feat-001
FA="$repoA/.git/lcars/missions/feat-001"

check "A. normal research exits zero" "[ '$RC' -eq 0 ]"
check "A. reaches validate" "grep -q '\"stage\": *\"validate\"' '$FA/state.json'"
check "A. relabels the mission issue at least twice (in-flight, then advance)" \
  "[ \"\$(relabels '$repoA' 42 | wc -l | tr -d ' ')\" -ge 2 ]"
# The FIRST relabel of the run is the in-flight one: research on, align off.
check "A. FIRST relabel applies lcars:research (Research is in flight)" \
  "nth_relabel '$repoA' 42 1 | grep -q -- '--add-label lcars:research'"
check "A. FIRST relabel drops lcars:align" \
  "nth_relabel '$repoA' 42 1 | grep -q -- '--remove-label lcars:align'"
check "A. FIRST relabel does NOT apply lcars:validate (Research has not finished)" \
  "! nth_relabel '$repoA' 42 1 | grep -q -- '--add-label lcars:validate'"
check "A. FIRST relabel does NOT apply lcars:awaiting-human (no escalation)" \
  "! nth_relabel '$repoA' 42 1 | grep -q -- 'lcars:awaiting-human'"
# The LAST relabel is the advance: validate on, research off again.
check "A. LAST relabel applies lcars:validate" \
  "relabels '$repoA' 42 | tail -1 | grep -q -- '--add-label lcars:validate'"
check "A. LAST relabel REMOVES lcars:research (the card leaves Research)" \
  "relabels '$repoA' 42 | tail -1 | grep -q -- '--remove-label lcars:research'"
# ORDER: research is applied strictly before validate.
posA_r="$(relabels "$repoA" 42 | grep -n -- '--add-label lcars:research' | head -1 | cut -d: -f1)"
posA_v="$(relabels "$repoA" 42 | grep -n -- '--add-label lcars:validate'  | head -1 | cut -d: -f1)"
check "A. ORDER: lcars:research is applied BEFORE lcars:validate" \
  "[ -n '$posA_r' ] && [ -n '$posA_v' ] && [ '$posA_r' -lt '$posA_v' ]"

# ==========================================================================
# B. 0-question SKIP path is still a Research run — same in-flight label.
# ==========================================================================
repoB="$(setup)"
drive "$repoB" research --mission feat-001    # QGEN_LINES empty ⇒ 0 questions ⇒ gate skip
FB="$repoB/.git/lcars/missions/feat-001"
check "B. skip-path research exits zero" "[ '$RC' -eq 0 ]"
check "B. reaches validate" "grep -q '\"stage\": *\"validate\"' '$FB/state.json'"
check "B. FIRST relabel applies lcars:research even on the 0-question skip" \
  "nth_relabel '$repoB' 42 1 | grep -q -- '--add-label lcars:research'"
check "B. LAST relabel removes lcars:research on the way to validate" \
  "relabels '$repoB' 42 | tail -1 | grep -q -- '--remove-label lcars:research'"

# ==========================================================================
# C. ESCALATION (>20 questions) — UNCHANGED. The gate subcommand on its own
#    still emits exactly one relabel: +research +awaiting-human, -align.
# ==========================================================================
repoC="$(setup)"
qC="$repoC/many.txt"; for i in $(seq 1 21); do echo "Question $i?"; done >"$qC"
drive "$repoC" gate --mission feat-001 --questions "$qC"
FC="$repoC/.git/lcars/missions/feat-001"
check "C. gate escalates (exit 3)" "[ '$RC' -eq 3 ]"
check "C. gate emits exactly ONE relabel" \
  "[ \"\$(relabels '$repoC' 42 | wc -l | tr -d ' ')\" -eq 1 ]"
check "C. gate relabel is unchanged: +research +awaiting-human -align" \
  "nth_relabel '$repoC' 42 1 | grep -q -- '--add-label lcars:research --add-label lcars:awaiting-human --remove-label lcars:align'"
check "C. stage pointer stays align (Research re-runs on align)" \
  "grep -q '\"stage\": *\"align\"' '$FC/state.json'"

# The escalation reached through the DRIVER keeps the research label too (the
# in-flight apply is idempotent with the gate's own).
repoC2="$(setup)"
QGEN_LINES="$(for i in $(seq 1 21); do echo "Question $i?"; done)" \
  drive "$repoC2" research --mission feat-001
FC2="$repoC2/.git/lcars/missions/feat-001"
check "C2. driver escalation still parks awaiting-human" \
  "grep -q '\"awaitingHuman\": *true' '$FC2/state.json'"
check "C2. driver escalation leaves the card labelled lcars:research" \
  "relabels '$repoC2' 42 | grep -q -- '--add-label lcars:research'"
check "C2. driver escalation never applies lcars:validate" \
  "! relabels '$repoC2' 42 | grep -q -- '--add-label lcars:validate'"

# ==========================================================================
# D. GROUNDING-mode research (logged bug) gets the SAME in-flight label.
# ==========================================================================
repoD="$(setup)"
drive "$repoD" research --mission bug-002
FD="$repoD/.git/lcars/missions/bug-002"
check "D. grounding research exits zero" "[ '$RC' -eq 0 ]"
check "D. grounding wrote research/grounding.json" "[ -f '$FD/research/grounding.json' ]"
check "D. grounding reaches validate" "grep -q '\"stage\": *\"validate\"' '$FD/state.json'"
check "D. FIRST relabel on the bug applies lcars:research" \
  "nth_relabel '$repoD' 43 1 | grep -q -- '--add-label lcars:research'"
check "D. FIRST relabel on the bug drops lcars:align" \
  "nth_relabel '$repoD' 43 1 | grep -q -- '--remove-label lcars:align'"
check "D. LAST relabel on the bug removes lcars:research" \
  "relabels '$repoD' 43 | tail -1 | grep -q -- '--remove-label lcars:research'"
check "D. LAST relabel on the bug applies lcars:validate" \
  "relabels '$repoD' 43 | tail -1 | grep -q -- '--add-label lcars:validate'"
check "D. grounding never touches the PARENT's issue (#41)" \
  "[ \"\$(relabels '$repoD' 41 | wc -l | tr -d ' ')\" -eq 0 ]"

# ==========================================================================
# E. Role labels are still never stripped by the new relabel (BUG-005 guard).
# ==========================================================================
check "E. no relabel in any of these runs removes lcars:mission" \
  "! grep -hq 'remove-label lcars:mission' '$repoA/gh.log' '$repoB/gh.log' '$repoC/gh.log' '$repoD/gh.log'"
check "E. no relabel in any of these runs removes lcars:ticket" \
  "! grep -hq 'remove-label lcars:ticket' '$repoA/gh.log' '$repoB/gh.log' '$repoC/gh.log' '$repoD/gh.log'"

# ==========================================================================
echo
printf 'research in-flight board label: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
