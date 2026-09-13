#!/usr/bin/env bash
# ============================================================================
# S201 TESTER RIG — the captain's own board, and it STAYS UP.
#
#   bash tests/drives/s201/tester-rig.sh up      # plant, boot, leave running
#   bash tests/drives/s201/tester-rig.sh down    # kill by recorded pid
#
# `xo-paint.sh` (the implementor's rig) boots the same daemon and the same
# Chrome and then TEARS THEM DOWN inside one node process. That is right for a
# pixel assertion and useless for a tester, who has to press a button, read
# what happened, curl the same endpoint, run the CLI, and then press another.
# So this reuses s190's boot SHAPE verbatim — same shims, same env, same
# devtools-port handshake — and stops before the teardown, writing rig.env.
#
# The fixture is the TESTER BRIEF's seven, not s190's seven: align, implement,
# awaiting-human, verify-with-PR, verify-with-a-logged-bug, the bug child, done.
#
# ZERO SPEND: claude/copilot/gh on PATH are logging shims that exit 1.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${LCARS_S201_RIG_OUT:-${TMPDIR:-/tmp}/lcars-s201-tester}"
ENVF="$OUT/rig.env"

PY_BIN="${LCARS_PY_BIN:-python3}"
NODE_BIN="${LCARS_NODE_BIN:-node}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env at $ENVF"; return 0; }
  # shellcheck disable=SC1090
  . "$ENVF"
  for pid in "${RIG_CHROME_PID:-}" "${RIG_DAEMON_PID:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "  TERM $pid"
  done
  sleep 1
  for pid in "${RIG_CHROME_PID:-}" "${RIG_DAEMON_PID:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null && echo "  KILL $pid"
  done
  rm -f "$ENVF"
}

case "${1:-up}" in
  down) down; exit 0 ;;
esac

rm -rf "$OUT"; mkdir -p "$OUT/shim"

for eng in claude copilot gh; do
  cat >"$OUT/shim/$eng" <<EOF
#!/usr/bin/env bash
echo "$eng \$*" >>"$OUT/shim.log"
exit 1
EOF
  chmod +x "$OUT/shim/$eng"
done
: >"$OUT/shim.log"

FIXTURE="$OUT/fixture"
mkdir -p "$FIXTURE"
"$PY_BIN" - "$REPO" "$FIXTURE" <<'PYEOF' || exit 77
import sys, os, json
repo, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "web"))
from tests import _fixtures as fx

# The seven the TESTER BRIEF names — the mock's own basis.
fx.plant_simple(root, "m-align", stage="align", issue=301,
                title="Align — the idea is still being shaped",
                created="2026-06-01T10:00:00Z")
fx.plant_implementing(root, "m-implement", issue=302,
                      title="Implement — waves in flight")
fx.plant_simple(root, "m-awaiting", stage="research", issue=303,
                title="Awaiting you — a question is parked",
                created="2026-06-03T10:00:00Z",
                awaiting_human=True,
                pending_question="Should the export be CSV or JSON?")
fx.plant_simple(root, "m-verify", stage="verify", issue=304,
                title="Verify — the PR is open and waiting on you",
                created="2026-06-04T10:00:00Z",
                pr_url="https://github.com/roferg/lcars-mp-fixture/pull/7",
                pr_number="7", review="open")
fx.plant_simple(root, "m-verify-bug", stage="verify", issue=305,
                title="Verify — with a bug logged against it",
                created="2026-06-05T10:00:00Z",
                pr_url="https://github.com/roferg/lcars-mp-fixture/pull/8",
                pr_number="8", review="open")
fx.plant_simple(root, "m-bug-child", stage="plan", issue=306,
                title="The logged bug — a child of #305",
                created="2026-06-06T10:00:00Z", mtype="bug",
                origin="log", parent_mission="m-verify-bug", parent_issue=305)
fx.plant_simple(root, "m-done", stage="done", issue=307,
                title="Done — shipped, and still on the board",
                created="2026-06-07T10:00:00Z")

# Every one of them MINE. The published-owner files ownership.sh reads off disk.
cache = os.path.join(root, ".git", "lcars", "cache")
os.makedirs(cache, exist_ok=True)
for issue in range(301, 308):
    with open(os.path.join(cache, "owner-github.com-%d" % issue), "w") as fh:
        fh.write("roferg\n")

# A repo config with NO numberOne key at all — the toggle must start OFF from
# absence, which is the state every existing repo is actually in.
cfgd = os.path.join(root, ".git", "lcars")
os.makedirs(cfgd, exist_ok=True)
with open(os.path.join(cfgd, "config.json"), "w") as fh:
    json.dump({"cloneId": "tester-a", "model": "claude",
               "projectName": "lcars-mp-fixture", "contextFile": "CONTEXT.md",
               "stack": "python", "testCommand": "true",
               "comprehensionBudget": "3", "lcarsVersion": "2026.9.6",
               "created": "2026-06-01T10:00:00Z"}, fh, indent=2)
print("planted 7 missions at", root)
PYEOF

# ---- A REAL INSTALL, IN A THROWAWAY HOME --------------------------------
# The daemon resolves every write verb to $HOME/.claude/skills/<skill>/… — the
# symlink `./install.sh` creates. The captain's real ~/.claude is installed
# from `Projects/LCARS` (main), so a daemon run with the real HOME dispatches
# `lcars xo` at a path that does not exist and answers 502. Re-running
# install.sh from the worktree would repoint the captain's whole machine, which
# a tester may not do. So: the same symlink farm install.sh makes, in a HOME
# this rig owns and deletes — every skill from THIS worktree, nothing mixed.
FAKEHOME="$OUT/home"
mkdir -p "$FAKEHOME/.claude/skills"
for d in "$REPO"/skills/*/; do
  ln -sfn "${d%/}" "$FAKEHOME/.claude/skills/$(basename "${d%/}")"
done
cp -R "$HOME/.gitconfig" "$FAKEHOME/.gitconfig" 2>/dev/null || true
echo "  install: $(ls "$FAKEHOME/.claude/skills" | wc -l | tr -d ' ') skills linked from the worktree"

( cd "$REPO/web" && exec env -u LCARS_SERVE_PORT \
    PATH="$OUT/shim:$PATH" HOME="$FAKEHOME" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 LCARS_OWNER_WARM=0 \
    LCARS_GH_USER=roferg LCARS_GH_BIN="$OUT/shim/gh" \
    LCARS_WORKER_BIN="$OUT/shim/claude" \
    "$PY_BIN" -m lcars_serve --port 0 --repo-root "$FIXTURE" ) \
  >"$OUT/daemon.log" 2>&1 &
DAEMON_PID=$!

URL=""
for i in $(seq 1 150); do
  URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" 2>/dev/null | head -1)"
  [ -n "$URL" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$URL" ] || { echo "daemon never bound; see $OUT/daemon.log"; exit 77; }
echo "  daemon:  $URL (pid $DAEMON_PID)"

PROFILE="$OUT/chrome-profile"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
HEADLESS="--headless=new"
[ "${LCARS_BROWSER_HEADED:-}" = "1" ] && HEADLESS=""
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=0 $HEADLESS \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1440,1000 about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!

DEV_PORT=""
deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -s "$PROFILE/DevToolsActivePort" ]; then
    p="$(sed -n 1p "$PROFILE/DevToolsActivePort" | tr -d '[:space:]')"
    ws="$(sed -n 2p "$PROFILE/DevToolsActivePort" | tr -d '[:space:]')"
    case "$p" in ''|*[!0-9]*) p="" ;; esac
    case "$ws" in /devtools/*) ;; *) p="" ;; esac
    if [ -n "$p" ] && "$NODE_BIN" -e '
      fetch("http://127.0.0.1:" + process.argv[1] + "/json/version",
            { signal: AbortSignal.timeout(2000) })
        .then((r) => r.json())
        .then((j) => process.exit(j && j.webSocketDebuggerUrl ? 0 : 1))
        .catch(() => process.exit(1));' "$p" >/dev/null 2>&1; then
      DEV_PORT="$p"; break
    fi
  fi
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$DEV_PORT" ] || { echo "chrome never opened devtools; see $OUT/chrome.log"; exit 77; }
echo "  chrome:  devtools :$DEV_PORT (pid $CHROME_PID)"

cat >"$ENVF" <<EOF
RIG_OUT="$OUT"
RIG_URL="$URL"
RIG_FIXTURE="$FIXTURE"
RIG_DEV_PORT="$DEV_PORT"
RIG_DAEMON_PID="$DAEMON_PID"
RIG_CHROME_PID="$CHROME_PID"
RIG_SHIMLOG="$OUT/shim.log"
EOF
echo "  rig.env: $ENVF"
