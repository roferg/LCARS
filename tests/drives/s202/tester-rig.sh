#!/usr/bin/env bash
# ============================================================================
# S202 TESTER RIG — a REAL park, a LIVE Number One worker.
#
#   bash tests/drives/s202/tester-rig.sh up     # plant + install, leave it up
#   bash tests/drives/s202/tester-rig.sh down   # kill by recorded pid
#
# The proof surface S202 declares is "a LIVE Copilot worker on a REAL park",
# so exactly ONE thing here is live: the number-one role's spawn. Everything
# downstream of the answer (the Implement worker the driver resumes into) is a
# SHIM, because the continuation is what we are proving, not the next stage.
#
# The trick that lets both live in one process tree: the cold-worker binary is
# a WRAPPER that dispatches on $LCARS_WORKER_ROLE (spawn_worker exports it).
#   role == number-one  → exec the REAL copilot/claude CLI, argv untouched
#   anything else       → log the argv, print a canned line, exit 0
# Every invocation of either arm is appended to $OUT/worker.argv.log, so the
# argv difference between the two engines is on disk, not in my memory.
#
# `gh` is REAL (roferg/lcars-mp-fixture, the one forge repo this round may
# touch). The install is the S201 shape: the symlink farm ./install.sh would
# make, in a throwaway HOME this rig owns and deletes — NEVER a bare
# ./install.sh, which would repoint the captain's live machine at the worktree.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${LCARS_S202_RIG_OUT:-${TMPDIR:-/tmp}/lcars-s202-tester}"
ENVF="$OUT/rig.env"
FIXTURE_REPO="roferg/lcars-mp-fixture"
PY_BIN="${LCARS_PY_BIN:-python3}"

REAL_COPILOT="${LCARS_S202_COPILOT:-$(command -v copilot || true)}"
REAL_CLAUDE="${LCARS_S202_CLAUDE:-$(command -v claude || true)}"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env at $ENVF"; return 0; }
  # shellcheck disable=SC1090
  . "$ENVF"
  for pid in ${RIG_PIDS:-}; do
    kill "$pid" 2>/dev/null && echo "  TERM $pid"
  done
  echo "  (issues are closed by the teardown step, not here)"
}

case "${1:-up}" in
  down) down; exit 0 ;;
esac

[ -n "$REAL_COPILOT" ] || { echo "no copilot CLI on PATH"; exit 77; }

rm -rf "$OUT"; mkdir -p "$OUT/bin"
: >"$OUT/worker.argv.log"

# ---- the role-dispatching cold-worker wrapper ------------------------------
mk_wrapper() { # name real-bin
  cat >"$OUT/bin/$1" <<EOF
#!/usr/bin/env bash
# S202 rig wrapper — LIVE for the number-one role, SHIM for every other role.
ROLE="\${LCARS_WORKER_ROLE:-<unset>}"
{
  echo "=== $(date -u +%FT%TZ) cli=$1 role=\$ROLE ==="
  n=0
  for a in "\$@"; do n=\$((n+1)); printf '  argv[%d] %s\n' "\$n" "\$a"; done
} >>"$OUT/worker.argv.log"
if [ "\$ROLE" = "number-one" ]; then
  echo "  >>> LIVE $1 spawn (role number-one)" >>"$OUT/worker.argv.log"
  # Strip the rig's own bin dir back off \$PATH before handing over. The real
  # copilot launcher shells out to \`copilot --version\` itself; with the rig dir
  # still first that resolves back to THIS wrapper and forks forever.
  CLEAN="\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vxF "$OUT/bin" | paste -sd: -)"
  echo "=== \$(date -u +%FT%TZ) LIVE $1 stdout/stderr ===" >>"$OUT/worker.out.log"
  exec env PATH="\$CLEAN" "$2" "\$@" \
     > >(tee -a "$OUT/worker.out.log") 2> >(tee -a "$OUT/worker.out.log" >&2)
fi
echo "  >>> SHIMMED (role \$ROLE) — canned reply, exit 0" >>"$OUT/worker.argv.log"
echo "SHIM: stage worker for role \$ROLE did nothing."
exit 0
EOF
  chmod +x "$OUT/bin/$1"
}
mk_wrapper copilot "$REAL_COPILOT"
[ -n "$REAL_CLAUDE" ] && mk_wrapper claude "$REAL_CLAUDE"

# ---- the fixture repo ------------------------------------------------------
FIXTURE="$OUT/fixture"
mkdir -p "$FIXTURE"
( cd "$FIXTURE" \
  && git init -q -b main \
  && git remote add origin "https://github.com/$FIXTURE_REPO.git" \
  && printf 'Review queue fixture app for LCARS S202.\n' >README.md \
  && mkdir -p src && printf 'export function queue(){ return []; }\n' >src/queue.js \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "fixture app" )

echo "  fixture: $FIXTURE (origin $FIXTURE_REPO)"

# ---- the real forge issues -------------------------------------------------
mk_issue() { # title
  gh issue create --repo "$FIXTURE_REPO" --title "$1" \
    --body "S202 tester fixture — a parked Mission for Number One. Closed at teardown." \
    2>/dev/null | sed -n 's|.*/issues/\([0-9]*\).*|\1|p'
}
ISSUE_CAP="$(mk_issue "S202 fixture — review queue (cap park)")"
ISSUE_SCOPE="$(mk_issue "S202 fixture — review queue (scope park)")"
[ -n "$ISSUE_CAP" ] && [ -n "$ISSUE_SCOPE" ] || { echo "gh issue create failed"; exit 77; }
echo "  issues:  #$ISSUE_CAP (cap)  #$ISSUE_SCOPE (scope)"
gh issue edit "$ISSUE_CAP"   --repo "$FIXTURE_REPO" --add-label "lcars:implement,lcars:mission,lcars:awaiting-human" >/dev/null 2>&1
gh issue edit "$ISSUE_SCOPE" --repo "$FIXTURE_REPO" --add-label "lcars:implement,lcars:mission,lcars:awaiting-human" >/dev/null 2>&1

# ---- plant the two parked missions ----------------------------------------
# The repo config first (plant.py deliberately never touches it), then the two
# Missions. plant.py is re-runnable on its own between drives: it is how the
# tester resets ONE mission back to its parked state without minting new
# forge issues.
"$PY_BIN" - "$FIXTURE" "$OUT/bin/copilot" <<'PYEOF' || exit 77
import json, os, sys
root, wbin = sys.argv[1], sys.argv[2]
L = os.path.join(root, ".git", "lcars"); os.makedirs(L, exist_ok=True)
json.dump({"cloneId": "s202-tester", "model": "copilot",
           "projectName": "lcars-mp-fixture", "contextFile": "CONTEXT.md",
           "stack": "node", "testCommand": "true",
           "comprehensionBudget": "3", "lcarsVersion": "2026.9.6",
           "workerBin": wbin, "created": "2026-09-12T10:00:00Z"},
          open(os.path.join(L, "config.json"), "w"), indent=2)
PYEOF
"$PY_BIN" "$HERE/plant.py" "$FIXTURE" "$ISSUE_CAP" "$ISSUE_SCOPE" "$OUT/bin/copilot" || exit 77

# ---- the throwaway HOME symlink farm (NEVER a bare ./install.sh) ----------
FAKEHOME="$OUT/home"
mkdir -p "$FAKEHOME/.claude/skills"
for d in "$REPO"/skills/*/; do
  ln -sfn "${d%/}" "$FAKEHOME/.claude/skills/$(basename "${d%/}")"
done
cp -R "$HOME/.gitconfig" "$FAKEHOME/.gitconfig" 2>/dev/null || true
mkdir -p "$FAKEHOME/.config"
cp -R "$HOME/.config/gh" "$FAKEHOME/.config/gh" 2>/dev/null || true
cp -R "$HOME/.copilot" "$FAKEHOME/.copilot" 2>/dev/null || true
echo "  install: $(ls "$FAKEHOME/.claude/skills" | wc -l | tr -d ' ') skills linked from the worktree"

cat >"$ENVF" <<EOF
RIG_OUT="$OUT"
RIG_FIXTURE="$FIXTURE"
RIG_HOME="$FAKEHOME"
RIG_BIN="$OUT/bin"
RIG_ARGVLOG="$OUT/worker.argv.log"
RIG_ISSUE_CAP="$ISSUE_CAP"
RIG_ISSUE_SCOPE="$ISSUE_SCOPE"
RIG_FIXTURE_REPO="$FIXTURE_REPO"
RIG_PIDS=""
EOF
echo "  rig.env: $ENVF"
