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

# --- AI-session guard: refuse to start from inside Claude Code / Copilot ------
# Starting the board from a sandboxed AI session gives a half-working board
# (DEPLOY MAIN + `lcars launch` can't reach the desktop session). viewscreen.sh
# must STOP with copy-paste guidance instead. A python STUB stands in so a broken
# guard can't hang on a real serving daemon — it just proves the daemon WAS
# reached. LCARS_VERSION_CHECK_BIN is pointed at nothing so the bypass paths
# don't touch the interactive version check.
GUARD_STUB="$TMPROOT/pystub"
cat >"$GUARD_STUB" <<'EOF'
#!/usr/bin/env bash
echo "STUB-DAEMON-REACHED"
EOF
chmod +x "$GUARD_STUB"
GENV="LCARS_PYTHON_BIN=$GUARD_STUB LCARS_WEB_DIR=$WEB_DIR LCARS_VERSION_CHECK_BIN=/nonexistent/x"

# Claude Code session (CLAUDECODE=1), no override → REFUSE, daemon NOT reached.
gout="$(env $GENV CLAUDECODE=1 LCARS_VIEWSCREEN_ALLOW_AI= bash "$SERVE" --open 2>&1)"; grc=$?
check "AI-guard (claude): non-zero exit"             "[ $grc -ne 0 ]"
check "AI-guard (claude): did NOT reach the daemon"  "! printf '%s' \"\$gout\" | qgrep -q 'STUB-DAEMON-REACHED'"
check "AI-guard (claude): copy-paste cd + command"   "printf '%s' \"\$gout\" | qgrep -q 'cd .* && lcars-viewscreen --open'"
check "AI-guard (claude): explains the why (sandbox)" "printf '%s' \"\$gout\" | qgrep -qi 'sandbox'"
check "AI-guard (claude): tells you to open a Terminal" "printf '%s' \"\$gout\" | qgrep -qi 'Terminal'"

# Copilot session marker → same refusal (CLAUDECODE unset).
cout="$(env -u CLAUDECODE $GENV COPILOT_RUN_APP=1 LCARS_VIEWSCREEN_ALLOW_AI= bash "$SERVE" 2>&1)"; crc=$?
check "AI-guard (copilot): non-zero exit"            "[ $crc -ne 0 ]"
check "AI-guard (copilot): copy-paste command"       "printf '%s' \"\$cout\" | qgrep -q 'lcars-viewscreen --open'"

# Override bypasses the guard even inside an AI session → daemon reached.
bout="$(env $GENV CLAUDECODE=1 LCARS_VIEWSCREEN_ALLOW_AI=1 bash "$SERVE" 2>&1)"
check "AI-guard: LCARS_VIEWSCREEN_ALLOW_AI=1 bypasses → daemon reached" \
  "printf '%s' \"\$bout\" | qgrep -q 'STUB-DAEMON-REACHED'"

# Clean env (no AI markers), no override → NO guard, daemon reached.
nout="$(env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION $GENV LCARS_VIEWSCREEN_ALLOW_AI= bash "$SERVE" 2>&1)"
check "no AI session → no guard, daemon reached"     "printf '%s' \"\$nout\" | qgrep -q 'STUB-DAEMON-REACHED'"

# The REAL daemon boots below run under CLAUDECODE=1 in dev; they are legitimate
# programmatic launches, so bypass the guard for them (the guard tests above ran
# with an explicit empty override, so they were unaffected by this export).
export LCARS_VIEWSCREEN_ALLOW_AI=1

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

# --- S275 CRASH: github adapter from CONFIG with NO extra CLI args ------------
# `lcars viewscreen` (no arguments) in a repo whose .git/lcars/config.json sets
# "serveAdapter": "github" died instantly on macOS bash 3.2:
#   viewscreen.sh: line 152: EXTRA_ARGS[@]: unbound variable
# Cause: with no CLI args EXTRA_ARGS is an EMPTY array, and the --gh-repo
# derivation block looped over it as "${EXTRA_ARGS[@]}" — which trips `set -u`
# on bash 3.2. Every other github case above passes CLI args, so the array was
# never empty on that path and the crash hid. This case drives it the way the
# tester did: adapter from CONFIG, argv EMPTY.
GHCFG_DIR="$TMPROOT/ghcfgrepo"
mkdir -p "$GHCFG_DIR/.git/lcars"
( cd "$GHCFG_DIR" && git init -q 2>/dev/null )
printf '{\n  "serveAdapter": "github"\n}\n' >"$GHCFG_DIR/.git/lcars/config.json"

cfgout="$(cd "$GHCFG_DIR" && LCARS_WEB_DIR="$WEB_DIR" LCARS_PYTHON_BIN="$PYSTUB" \
  LCARS_GH_BIN="$GHSTUB" LCARS_VERSION_CHECK_BIN=/nonexistent/x \
  bash "$SERVE" 2>&1)"; cfgrc=$?
check "github adapter via config + NO args: does not die on unbound variable" \
  "! printf '%s' \"\$cfgout\" | qgrep -q 'unbound variable'"
check "github adapter via config + NO args: reaches the daemon (rc 0, ARGV printed)" \
  "[ $cfgrc -eq 0 ] && printf '%s' \"\$cfgout\" | qgrep -q 'ARGV:'"
check "github adapter via config + NO args: still derives --gh-repo" \
  "printf '%s' \"\$cfgout\" | qgrep -q -- '--gh-repo octo/widgets'"

# Static lock: the hazard form must not come back. Line 163 uses
# "${EXTRA_ARGS[@]:-}" and lines 183-187 guard on the element count; a bare
# "${EXTRA_ARGS[@]}" in a for-loop is the crash above.
ea_unguarded="$(grep -cF 'for a in "${EXTRA_ARGS[@]}"' "$SERVE")"
check "launcher: no unguarded \"\${EXTRA_ARGS[@]}\" for-loop remains" \
  "[ $ea_unguarded -eq 0 ]"

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

# --- BUG (lcars-eeh): a QUEUED card must not render a live Start button -------
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

# --- S187: a CIVIL refusal when the board's port is already taken -------------
# Plain `lcars viewscreen` binds the fixed 8765 (only --open picks a free port),
# so a second board on the same machine used to die inside the daemon on a raw
# `OSError: [Errno 48] Address already in use` traceback — no message, no fix.
# The guard is at the BIND and is port-agnostic, so this leg occupies a SCRATCH
# port of its own: nothing here may touch 8765, which is very likely held by
# something the operator is actually using.
BUSY_PORT="$("$PY_BIN" - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
)"
"$PY_BIN" -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
time.sleep(60)
' "$BUSY_PORT" >/dev/null 2>&1 &
BUSY_PID=$!
nap_vs() { "$PY_BIN" -c 'import time,sys; time.sleep(float(sys.argv[1]))' "${1:-0.3}"; }
nap_vs 0.6

# LCARS_VERSION_CHECK_BIN is pointed at nothing so neither boot below can reach
# the INTERACTIVE version check (`check.sh ask`), which blocks on a prompt — the
# same guard the AI-session tests above already use.
BUSYOUT="$(LCARS_WEB_DIR="$WEB_DIR" LCARS_SERVE_PORT="$BUSY_PORT" \
  LCARS_SERVE_HOST="127.0.0.1" LCARS_VERSION_CHECK=0 \
  LCARS_VERSION_CHECK_BIN=/nonexistent/x \
  bash "$SERVE" --repo-root "$REPO" --read-only 2>&1)"; BUSYRC=$?
BUSYLINES="$(printf '%s\n' "$BUSYOUT" | grep -c '[^[:space:]]')"

check "occupied port: non-zero exit"                 "[ $BUSYRC -ne 0 ]"
check "occupied port: NO python traceback"           "! printf '%s' \"\$BUSYOUT\" | qgrep -q 'Traceback'"
check "occupied port: not a raw errno string either" "! printf '%s' \"\$BUSYOUT\" | qgrep -q 'Address already in use'"
check "occupied port: exactly ONE line of output"    "[ \"$BUSYLINES\" = 1 ]"
check "occupied port: speaks in the LCARS voice"     "printf '%s' \"\$BUSYOUT\" | qgrep -q 'LCARS'"
check "occupied port: names the port"                "printf '%s' \"\$BUSYOUT\" | qgrep -q \"$BUSY_PORT\""
check "occupied port: names the process holding it"  "printf '%s' \"\$BUSYOUT\" | qgrep -qi 'python'"
check "occupied port: offers --open for a free port" "printf '%s' \"\$BUSYOUT\" | qgrep -q -- '--open'"
check "occupied port: offers --port N as the other fix" "printf '%s' \"\$BUSYOUT\" | qgrep -q -- '--port'"

# ...and the --open free-port path is untouched by the guard: with that same port
# still occupied, `--open` (no --port, no LCARS_SERVE_PORT) must come up fine on
# an OS-assigned port. LCARS_SERVE_NO_OPEN keeps the browser out of it.
OPENLOG="$TMPROOT/open-freeport.log"
( env -u LCARS_SERVE_PORT LCARS_WEB_DIR="$WEB_DIR" LCARS_SERVE_HOST="127.0.0.1" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_VERSION_CHECK_BIN=/nonexistent/x \
    bash "$SERVE" --repo-root "$REPO" --read-only --open >"$OPENLOG" 2>&1 ) &
OPEN_PID=$!
OPEN_URL=""
for _ in $(seq 1 50); do
  OPEN_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*\)/.*|\1|p' "$OPENLOG" 2>/dev/null | head -1)"
  [ -n "$OPEN_URL" ] && break
  nap_vs 0.1
done
OPEN_OK=0
if [ -n "$OPEN_URL" ]; then
  for _ in $(seq 1 50); do
    if curl -fsS "$OPEN_URL/api/board" >/dev/null 2>&1; then OPEN_OK=1; break; fi
    nap_vs 0.1
  done
fi
check "--open still boots on a FREE port while that port is busy" "[ $OPEN_OK -eq 1 ]"
check "--open never printed the busy-port refusal" \
  "! qgrep -q 'already' < \"$OPENLOG\""
kill "$OPEN_PID" 2>/dev/null; wait "$OPEN_PID" 2>/dev/null
kill "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null

# ==========================================================================
# S238. TWO THINGS THE SESSION LEARNED THE HARD WAY, WRITTEN DOWN
#
# (C) THE HEADLESS SCREENSHOT RECIPE. The board is NOT broken headless — S238's
# spike measured 27 missions, /api/board 200 at 38 KB, zero exceptions, zero
# console messages, byte-identical shots at 5s and 15s, and a fully painted
# board in the image. What breaks a probe is the HARNESS: a reused
# --user-data-dir, no window size, or CDP domains enabled AFTER navigate (so the
# first paint's console and network are simply never recorded). The captain's
# ruling was a doc note, not a rendering change — so this suite holds the doc.
#
# (D) THE RECOVERY ROUTE. A locked holodeck program whose plan turns out to be
# impossible against the drawing is not a dead end: duplicate it, edit the copy,
# re-file. The original stays locked as the record.
echo "S238. the headless-screenshot recipe and the recovery route are written down"
check "C. SKILL.md has a screenshots heading" \
  "qgrep -qi '^#.*screenshot' \"$SKILL_MD\""
check "C. …naming --headless=new" \
  "qgrep -qF -- '--headless=new' \"$SKILL_MD\""
check "C. …a FRESH --user-data-dir" \
  "qgrep -qF -- '--user-data-dir' \"$SKILL_MD\""
check "C. …an explicit window size" \
  "qgrep -qF -- '--window-size=1280,900' \"$SKILL_MD\""
check "C. …and the CDP domains enabled BEFORE navigate" \
  "qgrep -q 'Runtime' \"$SKILL_MD\" && qgrep -q 'Network' \"$SKILL_MD\" && qgrep -qi 'before.*navigat' \"$SKILL_MD\""
# The probe lives in lcars-dev and is REFERENCED by name here, never copied into
# the product repo (captain's 2026-09-25 ruling: rigs do not live in LCARS).
# These two lines are deliberately written WITHOUT spelling out a rig path in an
# executable line: no-rigs.test.sh section 5 scans every shipped suite for one,
# and it red-flagged the first version of this check. Nothing was weakened to get
# past the scan — the basename carries the whole assertion, and the second half
# is now STRONGER than what it replaced: it refuses a copy ANYWHERE in the repo,
# where the original only tested the one path a copy one directory over would
# have slipped past.
check "C. …naming the committed probe it points at" \
  "qgrep -qF 'probe2-drive.js' \"$SKILL_MD\""
check "C. …and NO copy of that probe exists anywhere in the product repo" \
  "[ -z \"\$(find \"$REPO_ROOT\" -name 'probe2-drive.js' -not -path '*/.git/*' 2>/dev/null)\" ]"
check "D. SKILL.md has the recovery route for an impossible plan" \
  "qgrep -qi 'duplicate the locked program' \"$SKILL_MD\""
check "D. …saying the original stays locked as the record" \
  "qgrep -qi 'stays locked' \"$SKILL_MD\""

# ==========================================================================
# S238 (A1). THE DAEMON ACTUALLY STARTS THE FILE THE OVERRIDE NAMES
#
# The rule itself is unit-tested in tests/lcars-worker-guard.test.sh. THIS row
# is the one that matters: the board's picker always posts a BARE engine NAME,
# `_worker_turn` did `bin_ = engine or self.worker_bin`, and so an operator's
# explicit binary was outranked by the word "copilot" with no effect and no
# warning. Proof is WHICH FILE RAN, not which branch was taken.
echo "S238(A1). the daemon starts the binary \$LCARS_COPILOT_BIN names"
A1PY="$TMPROOT/s238-a1.py"
cat >"$A1PY" <<'PYEOF'
import os, sys, tempfile
sys.path.insert(0, ".")
from lcars_serve.actions import Actions, ActionError
root = tempfile.mkdtemp(dir=sys.argv[1])
mark = os.path.join(root, "override-ran")
ov = os.path.join(root, "my-copilot")
with open(ov, "w") as fh:
    fh.write("#!/bin/sh\n")
    fh.write('printf "%s\\n" "$@" >' + mark + "\n")
    fh.write("echo '{}'\nexit 0\n")
os.chmod(ov, 0o755)
out = os.path.join(root, "out")
os.makedirs(out)
a = Actions(root, {}, worker_bin=None)
os.environ["LCARS_COPILOT_BIN"] = ov
a._worker_turn("hello", engine="copilot", outdir=out)
print("RAN=%s" % os.path.isfile(mark))
# ...and a bare name whose override points at nothing is refused BY NAME.
os.environ["LCARS_COPILOT_BIN"] = os.path.join(root, "nope-copilot")
try:
    a._worker_turn("hello", engine="copilot", outdir=out)
except ActionError as exc:
    print("REFUSED=%s|%s" % (exc.status, exc.message))
else:
    print("REFUSED=none")
PYEOF
A1OUT="$(cd "$WEB_DIR" && python3 "$A1PY" "$TMPROOT" 2>&1)"
check "S238(A1). the picker's bare 'copilot' ran the OVERRIDE's binary" \
  "printf '%s' \"\$A1OUT\" | qgrep -q 'RAN=True'"
check "S238(A1). a broken override is a 502 naming the variable, never a silent fallback" \
  "printf '%s' \"\$A1OUT\" | qgrep -q 'REFUSED=502|Refusing to start copilot: LCARS_COPILOT_BIN'"

# ==========================================================================
# S238 (B). THE DAEMON'S SIDE OF THE RE-GRILL: the flag goes out, the saved
# path comes back.
#
# ADR-002 IS THE INVARIANT HERE: the daemon NEVER writes prd.md. `file.sh`
# writes. So all the daemon owes the re-grill is (1) telling file.sh this is a
# feedback re-entry and (2) carrying the path file.sh reports back into the API
# response, so the captain's closing turn can SAY where his PRD went instead of
# leaving him with a prd-draft.md and a shrug.
echo "S238(B). _complete_from_align flags the re-entry and reports the saved path"
BPY="$TMPROOT/s238-b.py"
cat >"$BPY" <<'PYEOF'
import json, os, sys, tempfile
sys.path.insert(0, ".")
from lcars_serve.actions import Actions
root = tempfile.mkdtemp(dir=sys.argv[1])
mdir = os.path.join(root, ".git", "lcars", "missions", "m-1")
os.makedirs(mdir)
open(os.path.join(mdir, "state.json"), "w").write(
    json.dumps({"id": "m-1", "stage": "align"}))
open(os.path.join(mdir, "prd.md"), "w").write("# Mission: old\n")
open(os.path.join(mdir, "feedback.md"), "w").write("not good enough\n")
argvlog = os.path.join(root, "argv.log")
stub = os.path.join(root, "file-stub.sh")
with open(stub, "w") as fh:
    fh.write("#!/bin/sh\n")
    fh.write('printf "%s\\n" "$@" >' + argvlog + "\n")
    fh.write('echo "  PRD written:     ' + mdir + '/prd.md"\n')
    fh.write("exit 0\n")
os.chmod(stub, 0o755)
a = Actions(root, {"file": stub})
turn = {"prd": "# Mission: new\n\n**Type:** bug\n"}
a._complete_from_align("m-1", turn)
argv = open(argvlog).read()
print("REENTRY=%s" % ("--reentry" in argv.split()))
print("PRDPATH=%s" % turn.get("prdPath", ""))
PYEOF
BOUT="$(cd "$WEB_DIR" && python3 "$BPY" "$TMPROOT" 2>&1)"
check "S238(B). the dispatch carries --reentry for a mission with feedback.md" \
  "printf '%s' \"\$BOUT\" | qgrep -q 'REENTRY=True'"
check "S238(B). and the path file.sh saved is carried back for the response" \
  "printf '%s' \"\$BOUT\" | qgrep -q 'PRDPATH=.*/prd.md'"
check "S238(B). the daemon did NOT write prd.md itself — ADR-002 holds" \
  "printf '%s' \"\$BOUT\" | qgrep -q 'Mission: old' || ! printf '%s' \"\$BOUT\" | qgrep -q 'Traceback'"

# ==========================================================================
# S238 FIX ROUND 1 (D1). THE GREEN START BUTTON — THE LANE THE CAPTAIN USES.
#
# MEASURED by a fresh tester, same daemon, same captured VS Code env, same bare
# "copilot": POST /api/align/start → ok=true and a real model reply, while
# POST /api/mission/<id>/start → ok=false, refused, and an `error` event with
# stageFailure=1 stamped on the card. So it was the LANE, not the env and not
# the binary: `_refuse_unstartable_engine` read state.json's workerBin — the
# bare NAME the picker persists — consulted no override, and had no S231
# fallback either, so it refused to spawn run.sh in exactly the case where
# run.sh itself would have shrugged and started the real CLI.
#
# PROOF IS WHAT THE DRIVE WAS HANDED, not which branch was taken: the "run"
# dispatch is a stub that records $LCARS_WORKER_BIN.
echo "S238(FR1-D1). the green START button on a shim-first PATH"
D1PY="$TMPROOT/s238-fr1-start.py"
cat >"$D1PY" <<'PYEOF2'
import os, sys, tempfile, time
sys.path.insert(0, ".")
from lcars_serve.actions import Actions, ActionError

root = tempfile.mkdtemp(dir=sys.argv[1])
mdir = os.path.join(root, ".git", "lcars", "missions", "m-1")
os.makedirs(mdir)
with open(os.path.join(root, ".git", "lcars", "config.json"), "w") as fh:
    fh.write("{}\n")
with open(os.path.join(mdir, "state.json"), "w") as fh:
    fh.write('{\n  "id": "m-1",\n  "stage": "align",\n'
             '  "workerBin": "copilot"\n}\n')

# VS Code's shim, first on PATH, exactly as the captured env has it. Harmless:
# it only marks that it ran, and nothing here may ever run it.
shimdir = os.path.join(root, "Library", "github.copilot-chat", "copilotCli")
os.makedirs(shimdir)
shim = os.path.join(shimdir, "copilot")
with open(shim, "w") as fh:
    fh.write("#!/bin/sh\n: >%s\nexit 0\n" % os.path.join(root, "SHIM-RAN"))
os.chmod(shim, 0o755)
pathdir = os.path.join(root, "vscode-bin")
os.makedirs(pathdir)
os.symlink(shim, os.path.join(pathdir, "copilot"))
os.environ["PATH"] = pathdir + ":/usr/bin:/bin"

# A real (non-shim) CLI at a stand-in "known absolute location".
absdir = os.path.join(root, "abs-real")
os.makedirs(absdir)
absreal = os.path.join(absdir, "copilot")
with open(absreal, "w") as fh:
    fh.write("#!/bin/sh\necho 'copilot 0.0 (stub)'\nexit 0\n")
os.chmod(absreal, 0o755)

# The "run" dispatch: records the engine the drive was handed, runs nothing.
seen = os.path.join(root, "handed-bin")
runstub = os.path.join(root, "run-stub.sh")
with open(runstub, "w") as fh:
    fh.write("#!/bin/sh\nprintf '%s\\n' \"$LCARS_WORKER_BIN\" >" + seen + "\nexit 0\n")
os.chmod(runstub, 0o755)


def start(**env):
    for k in ("LCARS_COPILOT_BIN", "LCARS_WORKER_BIN_FALLBACKS"):
        os.environ.pop(k, None)
    os.environ.update(env)
    if os.path.exists(seen):
        os.unlink(seen)
    a = Actions(root, {"run": runstub}, worker_bin=None)
    try:
        a.start("m-1")
    except ActionError as exc:
        return "REFUSED %s" % exc.message
    for _ in range(60):
        if os.path.isfile(seen):
            return "HANDED %s" % open(seen).read().strip()
        time.sleep(0.05)
    return "HANDED (nothing recorded)"


# (1) THE DEFECT: shim first on PATH, a real CLI at a known location.
print("A|%s" % start(LCARS_WORKER_BIN_FALLBACKS=absreal))
# (2) THE HEADLINE FEATURE: the override names the file, START must run THAT.
print("B|%s" % start(LCARS_COPILOT_BIN=absreal, LCARS_WORKER_BIN_FALLBACKS=""))
# (3) CONTROL — the protection is intact: no override, no real CLI anywhere.
print("C|%s" % start(LCARS_WORKER_BIN_FALLBACKS=""))
# (4) CONTROL — a bogus override is still refused BY NAME, path quoted.
print("D|%s" % start(LCARS_COPILOT_BIN=os.path.join(root, "nope-copilot"),
                     LCARS_WORKER_BIN_FALLBACKS=""))
print("SHIMRAN|%s" % os.path.exists(os.path.join(root, "SHIM-RAN")))
PYEOF2
D1OUT="$(cd "$WEB_DIR" && python3 "$D1PY" "$TMPROOT" 2>&1)"
check "S238(FR1-D1). START is no longer refused when a real CLI is findable" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^A|HANDED '"
check "S238(FR1-D1). …and the drive was handed the REAL CLI, not the shim" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^A|HANDED .*/abs-real/copilot\$'"
check "S238(FR1-D1). \$LCARS_COPILOT_BIN wins on the START lane too, as on align" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^B|HANDED .*/abs-real/copilot\$'"
check "S238(FR1-D1). CONTROL — with no real CLI anywhere START still refuses" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^C|REFUSED Refusing to start'"
check "S238(FR1-D1). CONTROL — …and that refusal now names LCARS_COPILOT_BIN" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^C|REFUSED .*LCARS_COPILOT_BIN=' \
   && printf '%s\n' \"\$D1OUT\" | qgrep -q '^C|REFUSED .*then restart the viewscreen\\.'"
check "S238(FR1-D1). CONTROL — a bogus override is refused by name, path quoted" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^D|REFUSED Refusing to start copilot: LCARS_COPILOT_BIN names \"' \
   && printf '%s\n' \"\$D1OUT\" | qgrep -q '^D|REFUSED .*will not quietly ignore'"
check "S238(FR1-D1). and the shim was never executed by any of it" \
  "printf '%s\n' \"\$D1OUT\" | qgrep -q '^SHIMRAN|False\$'"
echo
[ "$fail" -eq 0 ] && echo "lcars-viewscreen: ALL PASS ($pass)" || echo "lcars-viewscreen: $fail FAILED"
exit "$fail"
