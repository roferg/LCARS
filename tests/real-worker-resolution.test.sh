#!/usr/bin/env bash
# Tests for the shared worker-CLI resolver (source: tests/lib/real-worker.sh
# — lcars_resolve_real_worker), which every tester rig that builds a cold-worker
# wrapper (S202, S203, S204, S184, align-heal/matrix.sh, ...) sources instead of
# hand-rolling its own resolution.
#
# THE BUG THIS LOCKS DOWN (measured 2026-09-15): rigs used to resolve "the real
# copilot binary" with
#     REAL_COPILOT="${LCARS_S204_COPILOT:-$(command -v copilot || true)}"
# `command -v copilot` can resolve to an EDITOR'S OWN shim for that CLI (VS
# Code ships one under .../User/globalStorage/github.copilot-chat/...). That
# shim re-invokes `copilot` BY NAME; with the rig's own wrapper first on PATH,
# the two call each other forever. This fork-bombed the captain's laptop to
# 5,538 processes during a live overnight run and cost ~8 hours. See
# tests/drives/s204/tester-rig.sh (the first fix, commit 734f223) and
# tests/lib/real-worker.sh (the shared generalisation of that fix).
#
# THE CONTROL THAT MATTERS: run this file with REAL_WORKER_TEST_MODE=old and
# section 0 fails (the pre-fix idiom picks the shim) — proving this suite would
# have caught the bug. Run it plain (the default) and everything passes,
# because lcars_resolve_real_worker refuses the shim instead.
#
#   bash tests/real-worker-resolution.test.sh            # exercises the FIX (must pass)
#   REAL_WORKER_TEST_MODE=old bash tests/real-worker-resolution.test.sh   # exercises the BUG (must fail)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/tests/lib/real-worker.sh"
MODE="${REAL_WORKER_TEST_MODE:-new}"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"
type lcars_resolve_real_worker >/dev/null 2>&1 || { echo "FATAL: lcars_resolve_real_worker not defined by $LIB" >&2; exit 1; }

# The OLD, unsafe idiom this file replaced — kept here ONLY so REAL_WORKER_TEST_MODE=old
# can prove the new suite actually would have caught the historical bug. It is
# NEVER what a rig should run; it is the control.
_naive_old_style_resolve() { # name override -> stdout: resolved path (may be a shim!)
  local name="$1" override="${2:-}"
  if [ -n "$override" ]; then printf '%s\n' "$override"; return 0; fi
  local p; p="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$p" ] && printf '%s\n' "$p"
}

# resolve NAME OVERRIDE -> dispatches to the mode under test. "new" is what
# ships; "old" reproduces the pre-fix bug so the control can demonstrate it.
resolve() {
  if [ "$MODE" = old ]; then _naive_old_style_resolve "$1" "${2:-}"
  else LCARS_REAL_WORKER_TEST_NO_DEFAULTS=1 lcars_resolve_real_worker "$1" "${2:-}" 2>/dev/null
  fi
}

echo "real-worker resolution — mode=$MODE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-real-worker-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- fixtures ---------------------------------------------------------------
# A. an editor shim caught by PATH SHAPE ALONE — plausible Code-family layout,
#    generic body (no content marker), at a path under .../User/globalStorage/.
mkdir -p "$WORK/fake-vscode/User/globalStorage/github.copilot-chat/copilotCli"
SHIM_BY_PATH="$WORK/fake-vscode/User/globalStorage/github.copilot-chat/copilotCli/copilot"
cat >"$SHIM_BY_PATH" <<'SH'
#!/bin/sh
exec "/Applications/Visual Studio Code.app/Contents/MacOS/Electron" --ms-enable-electron-run-as-node "$@"
SH
chmod +x "$SHIM_BY_PATH"

# B. an editor shim caught by CONTENT ALONE — an innocuous-looking path, but the
#    body carries the exact re-invocation marker a real CLI shim uses.
mkdir -p "$WORK/looks-normal/bin"
SHIM_BY_CONTENT="$WORK/looks-normal/bin/copilot"
cat >"$SHIM_BY_CONTENT" <<'SH'
#!/bin/sh
# launches Code Helper running copilotCLIShim.js, which re-invokes `copilot` by name
exec "/Applications/Visual Studio Code.app/Contents/MacOS/Electron" copilotCLIShim.js "$@"
SH
chmod +x "$SHIM_BY_CONTENT"

# C. a REAL binary: ordinary path, ordinary body, no shim traits at all.
mkdir -p "$WORK/real/bin"
REAL_BIN="$WORK/real/bin/copilot"
cat >"$REAL_BIN" <<'SH'
#!/bin/sh
echo "copilot 1.2.3 (the real deal)"
SH
chmod +x "$REAL_BIN"

# D. a NON-VS-CODE editor family shim — proves the path-shape check
#    generalises past VS Code's own product name, and a CLAUDE-named shim
#    proves the content check is worker-agnostic (not copilot-specific).
mkdir -p "$WORK/fake-cursor/User/globalStorage/anthropic.claude-code/claudeCli"
CLAUDE_SHIM="$WORK/fake-cursor/User/globalStorage/anthropic.claude-code/claudeCli/claude"
cat >"$CLAUDE_SHIM" <<'SH'
#!/bin/sh
# a hypothetical editor-shipped claude shim: re-invokes `claude` by name
exec "/Applications/Cursor.app/Contents/MacOS/Electron" claudeCLIShim.js "$@"
SH
chmod +x "$CLAUDE_SHIM"

mkdir -p "$WORK/realclaude/bin"
REAL_CLAUDE_BIN="$WORK/realclaude/bin/claude"
cat >"$REAL_CLAUDE_BIN" <<'SH'
#!/bin/sh
echo "claude 1.0.0 (the real deal)"
SH
chmod +x "$REAL_CLAUDE_BIN"

echo
echo "-- section 1: a fake editor shim (path shape) is REJECTED (mode=$MODE demonstrates $([ "$MODE" = old ] && echo BUG || echo FIX)) --"
got="$(resolve copilot "$SHIM_BY_PATH" 2>/dev/null || true)"
[ "$got" != "$SHIM_BY_PATH" ] && ok "1. path-shape shim rejected as an override" \
  || bad "1. path-shape shim was accepted: $got"

echo
echo "-- section 2: a fake editor shim (content marker only) is REJECTED --"
got="$(resolve copilot "$SHIM_BY_CONTENT" 2>/dev/null || true)"
[ "$got" != "$SHIM_BY_CONTENT" ] && ok "2. content-marker shim rejected as an override" \
  || bad "2. content-marker shim was accepted: $got"

echo
echo "-- section 3: a REAL binary is ACCEPTED (the positive control) --"
got="$(resolve copilot "$REAL_BIN" 2>/dev/null || true)"
[ "$got" = "$REAL_BIN" ] && ok "3. a genuine real binary is accepted and returned verbatim" \
  || bad "3. expected $REAL_BIN, got '$got'"

echo
echo "-- section 4: an explicit override pointing at a shim falls through to a real fallback --"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
ln -sf "$REAL_BIN" "$FAKEBIN/copilot"
got="$(PATH="$FAKEBIN:$PATH" resolve copilot "$SHIM_BY_CONTENT" 2>/dev/null || true)"
[ "$got" = "$FAKEBIN/copilot" ] && ok "4. a shim override is refused and the real fallback on PATH is used instead" \
  || bad "4. expected fallback $FAKEBIN/copilot, got '$got' (the naive idiom trusts a bad override blindly — this is the bug)"

echo
echo "-- section 5: generalises past VS Code (a Cursor-shaped path) and past copilot (a claude shim) --"
got="$(resolve claude "$CLAUDE_SHIM" 2>/dev/null || true)"
[ "$got" != "$CLAUDE_SHIM" ] && ok "5. a Cursor-family claude shim is rejected (worker-agnostic, editor-agnostic)" \
  || bad "5. the claude-named editor shim was accepted: $got"
got="$(resolve claude "$REAL_CLAUDE_BIN" 2>/dev/null || true)"
[ "$got" = "$REAL_CLAUDE_BIN" ] && ok "5b. a real claude binary is still accepted" \
  || bad "5b. expected $REAL_CLAUDE_BIN, got '$got'"

echo
echo "-- section 6: whatever the resolver returns never carries a self re-invocation marker --"
for candidate in "$REAL_BIN" "$REAL_CLAUDE_BIN"; do
  name="$(basename "$candidate")"
  got="$(resolve "$name" "$candidate" 2>/dev/null || true)"
  if [ -n "$got" ] && ! grep -qsE 'CLIShim' "$got" 2>/dev/null; then
    ok "6. resolved $name ($got) carries no re-invocation shim marker"
  else
    bad "6. resolved $name candidate carries a shim marker or resolution failed: '$got'"
  fi
done

echo
echo "-- section 7: nothing real anywhere fails LOUDLY (not silently empty) --"
NOWHERE_PATH="$WORK/does-not-exist/copilot"
out="$(PATH="/usr/bin:/bin" LCARS_REAL_WORKER_TEST_NO_DEFAULTS=1 lcars_resolve_real_worker copilot "$NOWHERE_PATH" 2>&1 1>/dev/null)"
if [ "$MODE" = new ]; then
  printf '%s\n' "$out" | grep -qi "FATAL" && ok "7. absence of any real binary is reported loudly (FATAL)" \
    || bad "7. no loud failure message on total absence: '$out'"
fi

echo
printf 'real-worker-resolution (mode=%s): %d passed, %d failed\n' "$MODE" "$pass" "$fail"
[ "$fail" -eq 0 ]
