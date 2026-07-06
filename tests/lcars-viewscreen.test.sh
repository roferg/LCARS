#!/usr/bin/env bash
#
# Smoke test for the lcars-viewscreen skill launcher
# (skills/lcars-viewscreen/viewscreen.sh) and the Kanban daemon it starts.
#
# The board verb was renamed `lcars serve` → `lcars viewscreen`; `lcars serve`
# stays as a documented power alias via a thin serve.sh shim that execs
# viewscreen.sh. This suite locks BOTH entry paths and the new banner.
#
# The Python adapter/API logic has its own thorough suite under web/ (run with
# `cd web && python3 -m unittest discover`). THIS bash suite is the integration
# lock for the launcher: it proves viewscreen.sh boots the stdlib daemon against
# a fixture .git/lcars tree and that /api/board + / answer over HTTP — no model,
# no gh, no network. Dependencies are stubbed via env (LCARS_PYTHON_BIN,
# LCARS_WEB_DIR, LCARS_SERVE_PORT — the env names are intentionally unchanged).
#
# Usage: bash tests/lcars-viewscreen.test.sh
set -uo pipefail

# qgrep: drain stdin fully before grepping (see host-adapter.test.sh) so a piped
# `grep -q` never SIGPIPEs an upstream producer into a phantom failure under
# `set -o pipefail`.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVE="${LCARS_VIEWSCREEN_SCRIPT:-$REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh}"
# The `lcars serve` power-alias shim — must launch the SAME daemon as viewscreen.sh.
SERVE_ALIAS="$REPO_ROOT/skills/lcars-viewscreen/serve.sh"
WEB_DIR="$REPO_ROOT/web"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null   # reap quietly (no job-control "Terminated")
  fi
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "lcars-viewscreen: launcher + Kanban daemon smoke (+ serve alias)"

# --- the serve.sh power alias exists and execs viewscreen.sh ------------------
check "serve.sh power-alias shim exists"          "[ -f \"$SERVE_ALIAS\" ]"
check "serve.sh shim execs viewscreen.sh"         "qgrep -q 'exec .*viewscreen.sh' < \"$SERVE_ALIAS\""

# --- S80 docs: SKILL.md documents the on-PATH command, not the ~/.claude path --
# The board is launched via the real `lcars-viewscreen` command on ~/.local/bin
# (alias `lcars-serve`) installed by ./install.sh — identical + correct under BOTH
# Claude Code and Copilot. The old `bash ~/.claude/skills/lcars-viewscreen/...`
# invocation was wrong under Copilot (skill installs under ~/.copilot/...), so it
# must NOT appear in the skill doc at all.
SKILL_MD="$REPO_ROOT/skills/lcars-viewscreen/SKILL.md"
check "SKILL.md exists"                            "[ -f \"$SKILL_MD\" ]"
check "SKILL.md has NO ~/.claude/skills/lcars-viewscreen path" \
  "! qgrep -q '~/.claude/skills/lcars-viewscreen' < \"$SKILL_MD\""
check "SKILL.md documents the on-PATH lcars-viewscreen command" \
  "qgrep -q 'lcars-viewscreen' < \"$SKILL_MD\""
check "SKILL.md documents the lcars-serve alias" \
  "qgrep -q 'lcars-serve' < \"$SKILL_MD\""

# --- preflight: python3 present? (the daemon is python-stdlib-only) ----------
PY_BIN="${LCARS_PYTHON_BIN:-python3}"
if ! command -v "$PY_BIN" >/dev/null 2>&1; then
  echo "  (skip) python3 not on PATH — daemon smoke needs it; launcher dies cleanly."
  # Even without python, viewscreen.sh must die with a clear message, not hang.
  out="$(LCARS_PYTHON_BIN=definitely-not-python bash "$SERVE" 2>&1)"; rc=$?
  check "missing python3 → non-zero exit"        "[ $rc -ne 0 ]"
  check "missing python3 → clear message"        "printf '%s' \"\$out\" | qgrep -q 'python3 not found'"
  # the alias must die identically (proving it routes to the same launcher).
  outa="$(LCARS_PYTHON_BIN=definitely-not-python bash "$SERVE_ALIAS" 2>&1)"; rca=$?
  check "serve alias: missing python3 → non-zero exit"   "[ $rca -ne 0 ]"
  check "serve alias: missing python3 → clear message"   "printf '%s' \"\$outa\" | qgrep -q 'python3 not found'"
  echo
  [ "$fail" -eq 0 ] && echo "lcars-viewscreen: ALL PASS ($pass)" || echo "lcars-viewscreen: $fail FAILED"
  exit "$fail"
fi

# --- a fixture repo with one active mission in implement ----------------------
REPO="$TMPROOT/repo"
MDIR="$REPO/.git/lcars/missions/m-001"
mkdir -p "$MDIR"
cat >"$MDIR/state.json" <<'JSON'
{
  "id": "m-001",
  "type": "feature",
  "title": "Smoke mission",
  "stage": "implement",
  "created": "2026-06-13T10:00:00Z",
  "githubIssue": 142,
  "branch": "lcars/m-001",
  "base": "main"
}
JSON
cat >"$MDIR/estimate.json" <<'JSON'
{
  "schemaVersion": 3,
  "reasoningCriticality": "medium",
  "implCriticality": "high",
  "models": { "research": "opus", "validate": "opus", "plan": "opus",
              "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "rationale": "x",
  "cost": { "cli": "claude", "unit": "usd", "currency": "USD",
            "usd": { "low": 4.2, "high": 6.4 } },
  "estimatorModel": "opus"
}
JSON

# --- pick a free ephemeral port (let the OS choose, then reuse it) ------------
PORT="$("$PY_BIN" - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
)"

# --- boot the daemon via the launcher, against the fixture repo --------------
# We do NOT cd into REPO; instead point the local adapter at it via repo-root so
# the launcher's own git resolution is exercised from $REPO.
(
  cd "$REPO" && git init -q 2>/dev/null
)
# --read-only: the view-only shape — the GET read/render path works, the S68
# write endpoints are inactive (this section's "POST is declined" lock). The
# read+write local daemon (write endpoints active) is exercised separately below.
LCARS_WEB_DIR="$WEB_DIR" \
LCARS_SERVE_PORT="$PORT" \
LCARS_SERVE_HOST="127.0.0.1" \
  bash "$SERVE" --repo-root "$REPO" --read-only --poll-interval 0.1 >"$TMPROOT/serve.log" 2>&1 &
SERVER_PID=$!

# --- wait for it to answer (up to ~5s) ---------------------------------------
up=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1; then up=1; break; fi
  sleep 0.1
done
check "daemon comes up and answers /api/board"   "[ $up -eq 1 ]"

# the startup banner now reads "LCARS viewscreen" (the renamed verb), not "serve".
check "startup banner reads 'LCARS viewscreen'"  "qgrep -q 'LCARS viewscreen' < \"$TMPROOT/serve.log\""
check "startup banner no longer says 'LCARS serve'" "! qgrep -q 'LCARS serve' < \"$TMPROOT/serve.log\""

if [ "$up" -eq 1 ]; then
  board="$(curl -fsS "http://127.0.0.1:$PORT/api/board" 2>/dev/null)"
  check "/api/board is the board shape (has columns)" "printf '%s' \"\$board\" | qgrep -q '\"columns\"'"
  check "/api/board places the mission in implement"  "printf '%s' \"\$board\" | qgrep -q '\"stage\": *\"implement\"'"

  root="$(curl -fsS "http://127.0.0.1:$PORT/" 2>/dev/null)"
  check "/ serves the static board HTML"              "printf '%s' \"\$root\" | qgrep -qi 'id=\"board\"'"

  css="$(curl -fsS "http://127.0.0.1:$PORT/lcars.css" 2>/dev/null)"
  check "shares the docs/lcars.css token set"         "printf '%s' \"\$css\" | qgrep -q -- '--lcars'"

  detail="$(curl -fsS "http://127.0.0.1:$PORT/api/mission/m-001" 2>/dev/null)"
  check "/api/mission/<id> has an activity feed"      "printf '%s' \"\$detail\" | qgrep -q '\"activity\"'"

  # view-only (--read-only): a write action is DECLINED (403) — never silently
  # accepted. The GET read path above still served the board, proving the
  # renderer/read path is independent of the write layer (ADR-006).
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/mission/m-001/start" 2>/dev/null)"
  check "view-only: write action declined (403)"      "[ \"\$code\" = 403 ]"
fi

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

# --- S67 RENAME: the `lcars serve` POWER ALIAS still launches the same daemon --
# Boot via serve.sh (the shim) instead of viewscreen.sh and assert the identical
# daemon answers /api/board and prints the SAME "LCARS viewscreen" banner — i.e.
# the old entry path resolves to the renamed launcher with zero divergence.
APORT="$("$PY_BIN" - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
LCARS_WEB_DIR="$WEB_DIR" \
LCARS_SERVE_PORT="$APORT" \
LCARS_SERVE_HOST="127.0.0.1" \
  bash "$SERVE_ALIAS" --repo-root "$REPO" --read-only --poll-interval 0.1 >"$TMPROOT/serve-alias.log" 2>&1 &
APID=$!
aup=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$APORT/api/board" >/dev/null 2>&1; then aup=1; break; fi
  sleep 0.1
done
check "serve alias: launches the same daemon (answers /api/board)" "[ $aup -eq 1 ]"
check "serve alias: same 'LCARS viewscreen' banner" \
  "qgrep -q 'LCARS viewscreen' < \"$TMPROOT/serve-alias.log\""
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null

# --- DEFECT 2 (S67 fix-loop r1): --adapter github derives --gh-repo from the ---
# launch repo's remote, so the github adapter targets THIS repo (not gh's
# cwd-resolved default — viewscreen.sh cd's into web/ before exec). We stub both
# the python bin (echo argv + exit, so the daemon never really boots) and gh (echo
# a known nameWithOwner), then assert viewscreen.sh injected `--gh-repo owner/name`.
GHREPO_DIR="$TMPROOT/ghrepo"
mkdir -p "$GHREPO_DIR/.git/lcars"
( cd "$GHREPO_DIR" && git init -q 2>/dev/null )

# stub python: print its args, exit 0 (no real server).
PYSTUB="$TMPROOT/py-echo"
cat >"$PYSTUB" <<'SH'
#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*"
printf 'ENV_GH_REPO: %s\n' "${LCARS_SERVE_GH_REPO:-}"
exit 0
SH
chmod +x "$PYSTUB"

# stub gh: answer `repo view --json nameWithOwner -q .nameWithOwner`.
GHSTUB="$TMPROOT/gh-stub"
cat >"$GHSTUB" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) printf 'octo/widgets\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$GHSTUB"

ghout="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" LCARS_GH_BIN="$GHSTUB" \
  bash "$SERVE" --repo-root "$GHREPO_DIR" --adapter github 2>&1)"
check "github adapter: viewscreen.sh derives --gh-repo from remote" \
  "printf '%s' \"\$ghout\" | qgrep -q -- '--gh-repo octo/widgets'"

# explicit --gh-repo / env override still wins (no clobber).
ghout2="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_SERVE_GH_REPO="manual/override" \
  bash "$SERVE" --repo-root "$GHREPO_DIR" --adapter github 2>&1)"
check "github adapter: explicit LCARS_SERVE_GH_REPO overrides derivation" \
  "printf '%s' \"\$ghout2\" | qgrep -q -- 'ENV_GH_REPO: manual/override' && ! printf '%s' \"\$ghout2\" | qgrep -q -- '--gh-repo octo/widgets'"

# local adapter: no --gh-repo injected (derivation is github-only).
locout="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" LCARS_GH_BIN="$GHSTUB" \
  bash "$SERVE" --repo-root "$GHREPO_DIR" --adapter local 2>&1)"
check "local adapter: no --gh-repo injected" \
  "! printf '%s' \"\$locout\" | qgrep -q -- '--gh-repo'"

# graceful: gh absent → launch still proceeds (no --gh-repo, no hard-fail).
ghgone="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" LCARS_GH_BIN="$TMPROOT/no-such-gh" \
  bash "$SERVE" --repo-root "$GHREPO_DIR" --adapter github 2>&1)"; rc=$?
check "github adapter: missing gh degrades (launch still proceeds)" \
  "[ $rc -eq 0 ] && printf '%s' \"\$ghgone\" | qgrep -q 'ARGV:'"

# --- S68 write layer: the LOCAL daemon dispatches a POST to the skill script ---
# Boot the read+write local daemon against the fixture repo, point the pause
# skill path env at a RECORDING STUB, POST /api/mission/m-001/pause, and assert
# the stub saw the dispatch (argv) — no model/gh/git spend, just the bridge.
if [ "$up" -eq 1 ] || command -v "$PY_BIN" >/dev/null 2>&1; then
  WPORT="$("$PY_BIN" - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  PAUSE_REC="$TMPROOT/pause-rec.txt"
  PAUSE_STUB="$TMPROOT/pause-stub.sh"
  cat >"$PAUSE_STUB" <<SH
#!/usr/bin/env bash
printf 'ARGV: %s\n' "\$*" >> "$PAUSE_REC"
exit 0
SH
  chmod +x "$PAUSE_STUB"

  LCARS_WEB_DIR="$WEB_DIR" \
  LCARS_SERVE_PORT="$WPORT" \
  LCARS_SERVE_HOST="127.0.0.1" \
  LCARS_PAUSE_SCRIPT="$PAUSE_STUB" \
    bash "$SERVE" --repo-root "$REPO" --poll-interval 0.1 >"$TMPROOT/serve-w.log" 2>&1 &
  WPID=$!

  wup=0
  for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$WPORT/api/board" >/dev/null 2>&1; then wup=1; break; fi
    sleep 0.1
  done
  check "read+write daemon comes up" "[ $wup -eq 1 ]"
  if [ "$wup" -eq 1 ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -d '{}' \
      "http://127.0.0.1:$WPORT/api/mission/m-001/pause" 2>/dev/null)"
    check "POST /pause accepted by write daemon"  "[ \"\$code\" = 200 ]"
    check "pause dispatch reached the skill stub" \
      "[ -f \"$PAUSE_REC\" ] && qgrep -q 'pause m-001' < \"$PAUSE_REC\""
  fi
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
fi

# --- S68 launcher: --open is guarded so a test NEVER spawns a browser ----------
# With LCARS_SERVE_NO_OPEN=1 and a stubbed python that echoes argv (no real
# server), assert viewscreen.sh forwards --open AND that the guard env is exported, so
# the daemon would suppress the open. `lcars serve` (no --open) stays headless.
OPENOUT="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_SERVE_NO_OPEN=1 \
  bash "$SERVE" --repo-root "$GHREPO_DIR" --open 2>&1)"
check "launcher forwards --open to the daemon" \
  "printf '%s' \"\$OPENOUT\" | qgrep -q -- '--open'"

# --- BUG (lcars-buddy): a QUEUED card must not render a live Start button -------
# A logged bug SCHEDULED in a resolve-logs batch carries state.json.queued:true; the
# board derives runState→"queued" and shows a "QUEUED · WAITING" pill. But the card's
# action control (cardControls) branched only on paused/pausing/running and otherwise
# FELL THROUGH to a live "▶ Start" — so a queued card showed Start, and clicking it
# RACES the batch driver for the same mission (two drivers, lock contention).
# cardControls MUST handle rs==="queued" with a DISABLED affordance, BEFORE the Start
# fallthrough. Locked structurally: this app is python-stdlib-only with NO JS DOM
# harness (the board *shape* — queued:true — is covered in web/tests/test_local_adapter).
CARDCTRL="$(awk '/^function cardControls\(m\) \{/{f=1} f{print} f&&/^\}/{exit}' \
  "$WEB_DIR/static/board.js")"
qln="$(printf '%s\n' "$CARDCTRL" | grep -n 'rs === "queued"' | head -1 | cut -d: -f1)"
sln="$(printf '%s\n' "$CARDCTRL" | grep -n 'openLaunch'      | head -1 | cut -d: -f1)"
check "cardControls resolves the queued state before the Start fallthrough" \
  "[ -n \"$qln\" ] && [ -n \"$sln\" ] && [ \"$qln\" -lt \"$sln\" ]"
QARM="$(printf '%s\n' "$CARDCTRL" \
  | awk '/rs === "queued"/{f=1} /isRunningStage\(m\.stage\) && m\.dispatched/{f=0} f{print}')"
check "queued card renders a DISABLED affordance, never a live Start" \
  "printf '%s' \"\$QARM\" | qgrep -q 'disabled = true' && ! printf '%s' \"\$QARM\" | qgrep -q 'openLaunch'"

# --- Mission-Log per-bug image routing: the preview renders an images pill ------
# renderLogPreview draws each split bug as a child card; when the daemon routed
# pasted screenshots to a bug, that child carries `images` (its final index set)
# and the card shows a "🖼 N" pill. No JS DOM harness (python-stdlib-only), so
# lock the render structurally: the function must key the pill off `c.images` and
# emit a `pill img` chip. The union math itself is covered in the web unit tests.
RENDERLOG="$(awk '/^function renderLogPreview\(/{f=1} f{print} f&&/^\}/{exit}' \
  "$WEB_DIR/static/board.js")"
check "renderLogPreview drives an images pill off each child's images" \
  "printf '%s' \"\$RENDERLOG\" | qgrep -q 'c.images'"
check "renderLogPreview emits a themed 'pill img' chip" \
  "printf '%s' \"\$RENDERLOG\" | qgrep -q 'pill img'"

echo
[ "$fail" -eq 0 ] && echo "lcars-viewscreen: ALL PASS ($pass)" || echo "lcars-viewscreen: $fail FAILED"
exit "$fail"
