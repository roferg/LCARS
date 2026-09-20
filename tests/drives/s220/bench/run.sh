#!/usr/bin/env bash
# ===========================================================================
# S220 · THE BENCHMARK — does Number One's LOOK find what a careful person
# finds? One command, two arms, a recorded number.
#
#   bash tests/drives/s220/bench/run.sh [--case real|planted|all] [options]
#
# It sets itself up (clone, install, seed, copy the mission), runs the look
# LIVE, scores recall / false alarms / grade against known answers DECLARED in
# known-answers/*.json, and prints a compact table plus a JSON result.
#
# Read README.md first — it states the matching rule the score turns on.
#
# OPTIONS
#   --case real|planted|all   which arm (default: all)
#   --work DIR                where clones and fixtures live
#                             (default: $TMPDIR/s220-bench; survives reruns)
#   --score-only              skip the look, score whatever is already on disk
#   --from DIR                score THIS xo/ directory instead of running a
#                             look (for scoring a look captured elsewhere)
#   --timeout SECS            cage on one live look (default 2700 = 45 min)
#   --fresh                   throw the work dir away first
#   --label TEXT              goes into the result JSON, e.g. "after part B"
#
# RESUMABLE. A live look costs real minutes, so nothing already on disk is
# redone: an existing clone is reused, node_modules is installed once, and an
# arm whose verdict.json already exists is scored rather than re-looked (pass
# --fresh, or delete that arm's directory, to force a new look).
#
# HARD RULES BAKED IN
#   · Copilot ONLY, and only by absolute path. `copilot` is never put on PATH —
#     a VS Code shim of that name fork-bombs the machine (memory 2026-09-18).
#   · Claude is never spawned. $LCARS_WORKER_BIN is pinned at every level.
#   · The captain's own checkouts are never touched: the real arm CLONES
#     DX-Scorecard and COPIES the mission out of it read-only.
#   · No git prompts, no version stamp writes outside the work dir.
# ===========================================================================
set -uo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BENCH/../../../.." && pwd)"
COPILOT="${LCARS_BENCH_COPILOT:-/opt/homebrew/bin/copilot}"

CASE=all
WORK="${LCARS_BENCH_WORK:-${TMPDIR:-/tmp}/s220-bench}"
SCORE_ONLY=0
FROM=""
TIMEOUT=2700
FRESH=0
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --case) CASE="${2:-all}"; shift 2 ;;
    --work) WORK="${2:?}"; shift 2 ;;
    --score-only) SCORE_ONLY=1; shift ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$BENCH/run.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[36m◈\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$COPILOT" ] || die "no copilot at $COPILOT — the look cannot run."
case "$COPILOT" in /*) : ;; *) die "copilot must be an ABSOLUTE path (a shim named 'copilot' on PATH fork-bombs the machine)." ;; esac

[ "$FRESH" -eq 1 ] && rm -rf "$WORK"
mkdir -p "$WORK/out"
RESULTS="$WORK/out"

# --- the environment every live look runs under -----------------------------
# One place, so the two arms cannot drift apart, and so nothing here can reach
# the captain's machine state.
# A LIST, not a function: the cage below is `timeout`, which can only exec a
# program, so what it is handed has to be `env VAR=… prog`.
BENCH_ENV=(
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=
  LCARS_VERSION_CHECK=0 "LCARS_VERSION_STAMP=$WORK/version-stamp"
  "LCARS_INSTALL_PREFIX=$WORK/install"
  "LCARS_WORKER_BIN=$COPILOT" LCARS_XO_ENGINE=copilot
  "LCARS_COPILOT_BIN=$COPILOT"
  "LCARS_GH_BIN=$WORK/bin/gh"
  LCARS_ASSUME_TTY=0
)

mkdir -p "$WORK/bin"
# A gh that answers nothing. The benchmark is about the LOOK, and a look that
# tried to reach GitHub from a clone would fail for a reason that has nothing
# to do with what it can see.
cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/gh"

# ---------------------------------------------------------------------------
# run_look <repo-dir> <mission-id> <label>
# One bounded live look, through the shipped verb a human would type.
# ---------------------------------------------------------------------------
run_look() {
  local repo="$1" mid="$2" label="$3"
  local xodir="$repo/.git/lcars/missions/$mid/xo"
  if [ -f "$xodir/verdict.json" ]; then
    say "$label: a verdict is already on disk — scoring that (use --fresh for a new look)."
    return 0
  fi
  say "$label: the look, live on copilot, caged at ${TIMEOUT}s…"
  local t0 rc; t0=$(date +%s)
  # The cage is OUTSIDE `env`, because `env` can only exec a program and
  # timeout_wrap is a shell function. Inside, it would silently not apply.
  ( cd "$repo" && timeout_wrap "$TIMEOUT" \
      env "${BENCH_ENV[@]}" bash "$REPO_ROOT/skills/lcars-xo/xo.sh" evaluate --mission "$mid" \
  ) >"$WORK/out/$label.look.log" 2>&1
  rc=$?
  say "$label: the look came back rc=$rc after $(( $(date +%s) - t0 ))s → $WORK/out/$label.look.log"
  [ "$rc" -eq 124 ] && warn "$label: it hit the cage, not an answer — score what it managed."
  return 0
}

# `timeout` is not on a stock macOS. This is the cage, written once.
timeout_wrap() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" & local pid=$!
  ( sleep "$secs"; kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null ) & local watch=$!
  wait "$pid"; local rc=$?
  kill "$watch" 2>/dev/null
  return $rc
}
export -f timeout_wrap 2>/dev/null || true

# ===========================================================================
# ARM 1 — THE PLANTED CASE
# A small fixture app with a named-part drawing beside it: five planted faults,
# two correct controls, a second screen only a click can reach, and a gate that
# opens when it should refuse. Everything the arm needs is in fixture/.
# ===========================================================================
PLANTED_MID="lcars-20260919-s220-plant"
setup_planted() {
  local repo="$WORK/planted"
  if [ -d "$repo/.git" ]; then echo "$repo"; return 0; fi
  mkdir -p "$repo"
  cp -R "$BENCH/fixture/app/." "$repo/"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email bench@lcars.local && git config user.name "s220 bench"
    git add -A && git commit -q -m "the tide board"
    git checkout -q -b "lcars/$PLANTED_MID"
    git commit -q --allow-empty -m "mission tip"
    git checkout -q main
  ) >/dev/null 2>&1
  local md="$repo/.git/lcars/missions/$PLANTED_MID"
  mkdir -p "$md/attachments"
  printf '{ "projectName": "tide-board", "workerBin": "%s" }\n' "$COPILOT" \
    >"$repo/.git/lcars/config.json"
  cp "$BENCH/fixture/drawing.html" "$md/attachments/attachment-01.html"
  cp "$BENCH/fixture/prd.md" "$md/prd.md"
  # ONE FIELD PER LINE, `{` and `}` alone on their own — the shape LCARS's own
  # state writer insists on (S223). A compact object here is REFUSED by the
  # writer, which then declines to record anything, and the look stops before
  # it has looked at anything at all.
  cat >"$md/state.json" <<JSON
{
 "id": "$PLANTED_MID",
 "type": "feature",
 "title": "Tide Board",
 "stage": "verify",
 "branch": "lcars/$PLANTED_MID",
 "base": "main",
 "githubIssue": null,
 "workerBin": "$COPILOT",
 "attachments": [
  "attachments/attachment-01.html"
 ]
}
JSON
  # The launch answer is DECLARED, not discovered. A static page has exactly one
  # sensible way to be served and spending a worker turn to be told so would add
  # a minute and a lottery to every rerun. The look itself is untouched.
  cat >"$md/launch-discovery.json" <<JSON
{ "target": "Tide Board (static)", "command": "python3 -m http.server 8220",
  "cwd": ".", "url": "http://127.0.0.1:8220/index.html",
  "howToStop": "Press Ctrl+C in the terminal running the server.",
  "status": "ready" }
JSON
  echo "$repo"
}

# ===========================================================================
# ARM 2 — THE REAL CASE
# DX-Scorecard PR #206 at 672825b, with the mission's drawing and PRD.
# A CLONE. The captain's own checkout is read for two things only — the git
# objects and a copy of the mission directory — and written to never.
# ===========================================================================
REAL_MID="lcars-20260911-001-8cb0"
REAL_SHA="672825b"
REAL_SRC="${LCARS_BENCH_DX_SRC:-$HOME/Projects/DX-Scorecard}"
setup_real() {
  local repo="$WORK/dx"
  if [ ! -d "$repo/.git" ]; then
    [ -d "$REAL_SRC/.git" ] || { warn "no DX-Scorecard at $REAL_SRC — the real arm cannot be set up."; return 1; }
    say "real: cloning DX-Scorecard (local objects only, no network)…"
    GIT_TERMINAL_PROMPT=0 git clone -q --no-hardlinks "$REAL_SRC" "$repo" || { warn "clone failed"; return 1; }
    ( cd "$repo" && git checkout -q -B "lcars/$REAL_MID" "$REAL_SHA" ) \
      || { warn "cannot check out $REAL_SHA"; return 1; }
  fi
  if [ ! -d "$repo/node_modules" ]; then
    # INSTALLED INTO THE CLONE. Never a symlink to the captain's node_modules:
    # the spike did that and vite wrote a cache into his checkout.
    say "real: npm install in the clone (once; this is the slow part)…"
    ( cd "$repo" && npm install --no-audit --no-fund ) >"$WORK/out/real.npm.log" 2>&1 \
      || warn "npm install complained — see $WORK/out/real.npm.log"
  fi
  local md="$repo/.git/lcars/missions/$REAL_MID"
  if [ ! -f "$md/prd.md" ]; then
    mkdir -p "$(dirname "$md")"
    cp -R "$REAL_SRC/.git/lcars/missions/$REAL_MID" "$md" || { warn "cannot copy the mission"; return 1; }
    # The copy arrives with a look already recorded against it. This arm is
    # about what a look finds HERE, so the record of the last one goes.
    rm -rf "$md/xo" "$md/xo.pid" "$md/launch.json"
    python3 - "$md/state.json" "$COPILOT" <<'PY'
import json, sys
p, cop = sys.argv[1], sys.argv[2]
s = json.load(open(p))
s.pop("numberOne", None)
s["workerBin"] = cop
s["stage"] = "verify"
json.dump(s, open(p, "w"), indent=1)
PY
    [ -f "$REAL_SRC/.git/lcars/config.json" ] \
      && cp "$REAL_SRC/.git/lcars/config.json" "$repo/.git/lcars/config.json"
  fi
  echo "$repo"
}

# ===========================================================================
score_arm() { # <xo-dir> <answers> <label>
  # THE OLD RESULT GOES FIRST. A look that dies before it writes a verdict
  # leaves the previous run's JSON sitting in the results dir, and the next
  # reader takes it for this run's answer — which is how a benchmark reports a
  # number from a run that never happened.
  rm -f "$RESULTS/$3.json"
  python3 "$BENCH/score.py" "$1" "$2" --label "${LABEL:-$3}" --json "$RESULTS/$3.json"
}

ran=0
if [ "$CASE" = "planted" ] || [ "$CASE" = "all" ]; then
  if [ -n "$FROM" ]; then
    score_arm "$FROM" "$BENCH/known-answers/planted.json" planted; ran=1
  else
    repo="$(setup_planted)"
    [ "$SCORE_ONLY" -eq 1 ] || run_look "$repo" "$PLANTED_MID" planted
    score_arm "$repo/.git/lcars/missions/$PLANTED_MID/xo" "$BENCH/known-answers/planted.json" planted
    ran=1
  fi
fi
if [ "$CASE" = "real" ] || [ "$CASE" = "all" ]; then
  if [ -n "$FROM" ]; then
    score_arm "$FROM" "$BENCH/known-answers/real.json" real; ran=1
  else
    if repo="$(setup_real)"; then
      [ "$SCORE_ONLY" -eq 1 ] || run_look "$repo" "$REAL_MID" real
      score_arm "$repo/.git/lcars/missions/$REAL_MID/xo" "$BENCH/known-answers/real.json" real
      ran=1
    fi
  fi
fi
[ "$ran" -eq 1 ] || die "nothing ran — check --case."
say "results: $RESULTS"
