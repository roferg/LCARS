#!/usr/bin/env bash
# tests/drives/lib/real-worker.sh — resolve the REAL worker CLI binary
# (copilot, claude, ...), never an editor's own re-invocation shim.
#
# THE BUG THIS FIXES (measured 2026-09-15). A tester rig needs "the real
# copilot binary" so it can build a cold-worker wrapper that shadows `copilot`
# on PATH (argv logging, a `claude` tripwire, etc). The old idiom —
#
#     REAL_COPILOT="${LCARS_S204_COPILOT:-$(command -v copilot || true)}"
#
# — is NOT safe. `command -v copilot` can resolve to an EDITOR'S OWN shim for
# that CLI. On this machine it resolves to VS Code's:
#   ~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot
# a /bin/sh script that launches Code Helper running copilotCLIShim.js. That
# shim RE-INVOKES `copilot` BY NAME — with the rig's own wrapper first on
# PATH, the two call each other forever, ~5 processes per lap. On 2026-09-15
# this fork-bombed the captain's laptop to 5,538 processes during a live
# overnight run — ~8 hours lost — until the shell could no longer fork at all.
# A wrapper's own PATH-cleaning does NOT save it: it strips its own bin dir
# before exec, but the editor's shim re-enters with a FRESH PATH that finds
# the wrapper again, so the cleaning does not survive the hop.
#
# The VS Code globalStorage layout (User/globalStorage/<extension-id>/...) is
# shared by every VS Code fork — Cursor, Windsurf, VSCodium — so this treats
# the whole family as suspect, not just Code, and the check is by WORKER NAME,
# not just "copilot": if any editor ever ships a `claude` shim the identical
# loop opens on that side, and this catches it the same way.
#
# THE FIX: walk a candidate list — an explicit override first, then known real
# install locations, then `command -v` LAST as a fallback of last resort — and
# refuse any candidate that LOOKS like an editor shim, by path shape AND by
# grepping its content for a re-invocation marker. The override is checked
# too: an explicit LCARS_*_COPILOT / LCARS_*_CLAUDE pointing at a shim is
# refused, not trusted blindly.
#
# USAGE
#   as a library (preferred — every converted rig does this):
#     . "$REPO/tests/drives/lib/real-worker.sh"
#     REAL_COPILOT="$(lcars_resolve_real_worker copilot "${LCARS_S203_COPILOT:-}")" || exit 77
#
#   as a standalone CLI (same contract — prints the chosen path on stdout,
#   diagnostics on stderr, exit 77 if nothing real is found):
#     REAL_COPILOT="$(bash "$REPO/tests/drives/lib/real-worker.sh" copilot "$LCARS_S203_COPILOT")" || exit 77
#
# Either way the decision is ALSO announced on stderr as it is made, so it is
# visible in rig output: "  ◇ real copilot: <path>".

# _lcars_worker_candidate_list NAME -> fills the global array _LCARS_CANDS
# with known-real install locations for that worker CLI, ending with whatever
# `command -v` finds (checked and possibly refused below — never trusted
# outright, because PATH is exactly where an editor's shim inserts itself).
_lcars_worker_candidate_list() {
  local name="$1"
  _LCARS_CANDS=()
  # LCARS_REAL_WORKER_TEST_NO_DEFAULTS is a TEST-ONLY hook (set only by
  # tests/real-worker-resolution.test.sh) so a run is hermetic even on a
  # machine that happens to have a real copilot/claude at one of these known
  # locations. No rig sets this; production resolution always includes them.
  if [ "${LCARS_REAL_WORKER_TEST_NO_DEFAULTS:-0}" != 1 ]; then
    case "$name" in
      copilot)
        _LCARS_CANDS=(
          /opt/homebrew/bin/copilot
          /usr/local/bin/copilot
          /opt/homebrew/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot
          /usr/local/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot
          "$HOME/.copilot/bin/copilot"
        )
        ;;
      claude)
        _LCARS_CANDS=(
          /opt/homebrew/bin/claude
          /usr/local/bin/claude
          "$HOME/.claude/local/claude"
        )
        ;;
    esac
  fi
  local pv
  pv="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$pv" ] && _LCARS_CANDS+=("$pv")
}

# _lcars_is_editor_shim PATH NAME -> true (0) if PATH looks like an editor's
# own re-invocation shim for the worker CLI called NAME, rather than a real
# binary that can safely be exec'd from a wrapper.
_lcars_is_editor_shim() {
  local path="$1" name="$2"
  # Path shape: the VS Code family's extension-storage layout (Code, Code -
  # Insiders, Cursor, Windsurf, VSCodium all lay CLI shims an extension ships
  # under "User/globalStorage/<extension-id>/"), the macOS Electron helper
  # process that runs them, and any editor's on-disk extensions directory
  # (where an installed extension's own CLI binary/shim can live too).
  case "$path" in
    *"/User/globalStorage/"*) return 0 ;;
    *"Code Helper"*) return 0 ;;
    *"/.vscode/extensions/"*|*"/.vscode-insiders/extensions/"*) return 0 ;;
    *"/.cursor/extensions/"*|*"/.windsurf/extensions/"*|*"/.vscode-server/extensions/"*) return 0 ;;
  esac
  # Content: a known "this file re-invokes <name> by name" shim marker.
  # Generalised past copilotCLIShim (VS Code's exact one for copilot) to the
  # same shape for any worker name, so a future claude/other shim is caught
  # the same way even before it is named here specifically.
  grep -qsE "(${name}CLIShim|CLIShim\.js|copilotCLIShim|claudeCLIShim)" "$path" 2>/dev/null && return 0
  return 1
}

# lcars_resolve_real_worker NAME [OVERRIDE]
#   NAME     the worker CLI name: copilot, claude, ...
#   OVERRIDE optional explicit path (e.g. $LCARS_S203_COPILOT) — checked, not
#            trusted blindly: a shim here is refused exactly like any other
#            candidate, and the search falls through to the rest of the list.
# Prints the resolved real binary's path on stdout and returns 0, or prints a
# loud diagnosis on stderr and returns 1 with nothing on stdout.
lcars_resolve_real_worker() {
  local name="$1" override="${2:-}" c chosen=""
  _lcars_worker_candidate_list "$name"
  # Guard the array expansion: under `set -u`, older bash (3.2, macOS system
  # bash) treats "${arr[@]}" on a ZERO-element array as an unbound-variable
  # error rather than an empty expansion — even though the array was declared.
  local cands=("$override")
  [ "${#_LCARS_CANDS[@]}" -gt 0 ] && cands+=("${_LCARS_CANDS[@]}")
  for c in "${cands[@]}"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if _lcars_is_editor_shim "$c" "$name"; then
      if [ -n "$override" ] && [ "$c" = "$override" ]; then
        echo "  ⚠ the override for $name ($c) is an editor shim — refusing it, not trusting it blindly" >&2
      else
        echo "  ⚠ skipping $c — that is an editor shim, not the real $name (it would recurse)" >&2
      fi
      continue
    fi
    chosen="$c"; break
  done
  if [ -z "$chosen" ]; then
    local upper
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    echo "FATAL: no real $name binary found — every candidate was either missing or an editor shim." >&2
    echo "  set an explicit override, e.g. LCARS_S203_${upper}=/path/to/the/real/$name, and retry." >&2
    return 1
  fi
  echo "  ◇ real $name: $chosen" >&2
  printf '%s\n' "$chosen"
  return 0
}

# Standalone CLI mode: `bash real-worker.sh <name> [override]`
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -u
  [ $# -ge 1 ] || { echo "usage: real-worker.sh <name> [override]" >&2; exit 2; }
  lcars_resolve_real_worker "$1" "${2:-}" || exit 77
fi
