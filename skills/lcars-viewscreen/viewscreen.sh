#!/usr/bin/env bash
#
# lcars viewscreen — start the LCARS Kanban web daemon, the bridge viewscreen
# (PRD §5.1–5.2, §6; ADR-001/002/003/007). `lcars serve` is a documented power
# alias that execs this same script via the serve.sh shim next to this file.
#
# A Python-3-stdlib-only http.server daemon (NO pip/npm/build step) that serves a
# vanilla static Kanban front end and a small read API:
#
#   GET /                  the static board (renders every active Mission as a
#                          card in its Stage column, with cost + difficulty pills,
#                          awaiting/paused states, nested tickets, Implement progress)
#   GET /api/board         the full adapter-neutral board JSON
#   GET /api/mission/<id>  mission detail incl. the activity feed
#   GET /api/events        a live channel (SSE) that pushes on state change
#
# It is READ-ONLY — there are NO write endpoints this session.
#
# ONE adapter-neutral board shape backs TWO interchangeable read adapters
# (ADR-003): the LOCAL adapter parses .git/lcars/missions/* off disk (default),
# and the GITHUB adapter reads issues + lcars:* labels via $LCARS_GH_BIN. The
# front end depends only on the shape, never on which adapter served it.
#
# Dependencies/paths are taken via env so tests can stub them and the launcher
# stays host-agnostic:
#   LCARS_PYTHON_BIN     the python 3 interpreter  (default: python3)
#   LCARS_WEB_DIR        the web/ app root          (default: ../../web from here)
#   LCARS_GH_BIN         the gh binary (github adapter) (default: gh)
#   LCARS_SERVE_HOST     bind host                  (default: 127.0.0.1)
#   LCARS_SERVE_PORT     bind port                  (default: 8765)
#   LCARS_SERVE_ADAPTER  local | github             (default: local; also the
#                        config.json `serveAdapter` key when present)
#
set -uo pipefail

# Help is a read, not a request to start a board in an agent session.
for arg in "$@"; do
  case "$arg" in
    --) break ;;
    -h|--help)
      cat <<'EOF'
Usage: lcars-viewscreen [options]  (alias: lcars-serve)

Start the LCARS Kanban board from a plain terminal.
  --open                 Open the browser; choose a free port unless specified.
  --host HOST            Bind address (default: 127.0.0.1).
  --port PORT            Bind port (default: 8765; 0 chooses a free port).
  --adapter local|github Read local mission state or GitHub issues.
  --repo-root PATH       Working tree to serve (default: current repository).
  --gh-bin COMMAND       GitHub CLI executable (default: gh).
  --gh-repo OWNER/NAME   Repository for the GitHub adapter.
  --poll-interval SECS   State-change polling interval (default: 1).
  --read-only            Disable write endpoints.
  -h, --help             Show this help without starting the board.

Starting a board inside Claude Code or Copilot is refused. Run it in a
normal terminal; help is available in either environment.
EOF
      exit 0 ;;
  esac
done

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"

PY_BIN="${LCARS_PYTHON_BIN:-python3}"
# The web app lives at the repo's web/. From skills/lcars-viewscreen/ that is ../../web.
WEB_DIR="${LCARS_WEB_DIR:-$(cd "$SKILL_DIR/../../web" 2>/dev/null && pwd)}"

die() { printf 'lcars viewscreen: %s\n' "$1" >&2; exit 1; }

command -v "$PY_BIN" >/dev/null 2>&1 \
  || die "python3 not found ($PY_BIN). The daemon is Python-3-stdlib-only."
[ -n "$WEB_DIR" ] && [ -d "$WEB_DIR" ] \
  || die "web app dir not found (set LCARS_WEB_DIR). Run ./install.sh from the repo."

# --- repo root + .git/lcars (so the local adapter reads THIS repo's missions) -
# The daemon's local adapter reads <repo-root>/.git/lcars/missions/*. Resolve the
# working tree root for the repo we are launched in; harmless for the github
# adapter (which ignores it). --show-toplevel is empty in a bare/worktree edge
# case, so fall back to PWD.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"

# --- guard: don't start the board from INSIDE a sandboxed AI session ----------
# When this runs inside a Claude Code (CLAUDECODE=1) or GitHub Copilot
# (COPILOT_RUN_APP=1 / COPILOT_CLI_BINARY_VERSION) session, that session is
# sandboxed: the board itself would load, but DEPLOY MAIN and `lcars launch`
# can't reach macOS's windowing session from here, so starting any app fails
# (mach_port 1100). Rather than launch a half-working board, we STOP and hand the
# human a copy-paste command to run in a real terminal. Automation that genuinely
# wants a headless daemon here sets LCARS_VIEWSCREEN_ALLOW_AI=1 to bypass.
_ai_session() {
  # Copilot can inherit CLAUDECODE from the terminal that launched it.
  { [ "${COPILOT_RUN_APP:-}" = "1" ] || [ -n "${COPILOT_CLI_BINARY_VERSION:-}" ]; } \
    && { printf 'Copilot'; return 0; }
  [ "${CLAUDECODE:-}" = "1" ] && { printf 'Claude Code'; return 0; }
  return 1
}
if [ "${LCARS_VIEWSCREEN_ALLOW_AI:-}" != "1" ] && _AI="$(_ai_session)"; then
  cat <<EOF
LCARS viewscreen — NOT started (you're inside a $_AI session).

Why: a $_AI session is sandboxed, so the board would load but the DEPLOY MAIN
button and \`lcars launch\` can't reach the macOS desktop session from here —
starting any app fails. The board must run from a normal terminal that owns a
real desktop session.

▶ Open a new Terminal window and paste this:

    cd "$REPO_ROOT" && lcars-viewscreen --open

That boots the board in your browser with deploy + launch fully working.
Stop it later with Ctrl-C in that terminal.

(Headless automation that really wants the daemon here: set
LCARS_VIEWSCREEN_ALLOW_AI=1 to bypass this.)
EOF
  exit 3
fi

# --- version check + ask-to-update (interactive; S129) ---------------------
# The launcher is a REAL terminal before the daemon detaches, so it CAN ask.
# Run the throttled check in ASK mode against the repo we are about to serve,
# BEFORE `cd web/` + the exec. Fully guarded; the kill switch disables it.
VERSION_CHECK="${LCARS_VERSION_CHECK_BIN:-$SKILL_DIR/../lcars-version/check.sh}"
[ -f "$VERSION_CHECK" ] && LCARS_VERSION_CWD="$REPO_ROOT" bash "$VERSION_CHECK" ask || true

# --- adapter selection: flag/env > config.json `serveAdapter` > local --------
# config.json lives under .git/lcars/config.json (init/update write it). A
# `serveAdapter` key, when present, picks the default adapter; the env var /
# --adapter flag still wins so a github-only mode is always reachable.
ADAPTER="${LCARS_SERVE_ADAPTER:-}"
if [ -z "$ADAPTER" ]; then
  CFG="$REPO_ROOT/.git/lcars/config.json"
  if [ -f "$CFG" ]; then
    cfg_adapter="$(sed -n 's/.*"serveAdapter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
    [ -n "$cfg_adapter" ] && ADAPTER="$cfg_adapter"
  fi
fi
[ -n "$ADAPTER" ] || ADAPTER="local"

# Pass through any extra args verbatim (e.g. --adapter github, --port 9000) so
# `lcars viewscreen --adapter github` overrides everything resolved above. Build the
# array bash-3.2-safely: `("$@")` on an empty `$@` trips `set -u` on bash 3.2.
EXTRA_ARGS=()
[ "$#" -gt 0 ] && EXTRA_ARGS=("$@")

# An explicit `--adapter <x>` in EXTRA_ARGS wins over everything resolved above
# (argparse honours the last value, and we must mirror that when deciding whether
# to derive a gh-repo below).
for i in "${!EXTRA_ARGS[@]}"; do
  if [ "${EXTRA_ARGS[$i]}" = "--adapter" ]; then
    j=$((i + 1)); [ "$j" -lt "${#EXTRA_ARGS[@]}" ] && ADAPTER="${EXTRA_ARGS[$j]}"
  fi
done

# --- github adapter: derive the target repo from THIS repo's remote ----------
# viewscreen.sh cd's into web/ before exec, so the github adapter would otherwise let
# gh resolve the repo from web/'s cwd — the wrong repo. When the github adapter
# is selected and the operator gave neither an explicit --gh-repo flag nor
# LCARS_SERVE_GH_REPO, derive owner/name from $REPO_ROOT's remote (env-injected
# gh, run IN $REPO_ROOT) and inject it as --gh-repo. Degrade gracefully: if gh is
# absent/unauthed/no-remote, launch anyway with no derived repo.
if [ "$ADAPTER" = "github" ] && [ -z "${LCARS_SERVE_GH_REPO:-}" ]; then
  have_explicit_repo=0
  # Same bash-3.2 hazard the comments at 117 and 183 name: "${arr[@]}" on an
  # EMPTY array trips `set -u`, and with no CLI args EXTRA_ARGS IS empty — so
  # `lcars viewscreen` (no args) with serveAdapter=github in config died here.
  # Keep the `:-` form (as below); the body ignores the empty element it yields.
  for a in "${EXTRA_ARGS[@]:-}"; do
    [ "$a" = "--gh-repo" ] && { have_explicit_repo=1; break; }
  done
  if [ "$have_explicit_repo" -eq 0 ]; then
    gh_bin_probe="${LCARS_GH_BIN:-gh}"
    if command -v "$gh_bin_probe" >/dev/null 2>&1; then
      derived_repo="$(cd "$REPO_ROOT" 2>/dev/null \
        && "$gh_bin_probe" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
      if [ -n "$derived_repo" ]; then
        EXTRA_ARGS+=("--gh-repo" "$derived_repo")
      fi
    fi
  fi
fi

# --- ENTER-the-interface: --open boots on a FREE port + opens the browser -----
# When the captain passes --open (the one-command "enter the interface" path) we
# pick a FREE port by default (bind 0, the daemon reads back the OS-assigned port
# and prints the resolved URL) instead of the fixed 8765, so two boards never
# clash. An explicit --port / LCARS_SERVE_PORT still wins. Auto-open itself is
# guarded inside the daemon by LCARS_SERVE_NO_OPEN so tests never spawn a browser;
# `lcars viewscreen` with NO --open stays headless.
WANT_OPEN=0
HAVE_PORT_FLAG=0
for a in "${EXTRA_ARGS[@]:-}"; do
  case "$a" in
    --open) WANT_OPEN=1 ;;
    --port|--port=*) HAVE_PORT_FLAG=1 ;;
  esac
done
DEFAULT_PORT="8765"
if [ "$WANT_OPEN" -eq 1 ] && [ "$HAVE_PORT_FLAG" -eq 0 ] && [ -z "${LCARS_SERVE_PORT:-}" ]; then
  DEFAULT_PORT="0"   # let the OS assign a free port; the daemon prints the URL.
fi

# Export the env the daemon reads (it also accepts these as flags; the flags in
# EXTRA_ARGS take precedence over these defaults inside argparse).
export LCARS_SERVE_HOST="${LCARS_SERVE_HOST:-127.0.0.1}"
export LCARS_SERVE_PORT="${LCARS_SERVE_PORT:-$DEFAULT_PORT}"
export LCARS_SERVE_ADAPTER="$ADAPTER"
export LCARS_SERVE_REPO_ROOT="$REPO_ROOT"
export LCARS_GH_BIN="${LCARS_GH_BIN:-gh}"

# Launch the daemon. `python3 -m lcars_serve` from web/ so the package imports.
# Expand EXTRA_ARGS in a bash-3.2-safe way: "${arr[@]}" on an EMPTY array trips
# `set -u` on macOS bash 3.2, so guard on the element count first.
cd "$WEB_DIR" || die "cannot enter web app dir $WEB_DIR"
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  exec "$PY_BIN" -m lcars_serve "${EXTRA_ARGS[@]}"
else
  exec "$PY_BIN" -m lcars_serve
fi
