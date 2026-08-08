#!/usr/bin/env bash
#
# Tests for Session 79: install.sh puts `lcars-viewscreen` (+ `lcars-serve`
# alias) launchers on ~/.local/bin so the viewscreen is a real on-PATH command
# from any shell, on either CLI.
#
# The launchers are generated wrappers that `exec` the repo's real
# viewscreen.sh / serve.sh by ABSOLUTE path — so they survive viewscreen.sh's
# WEB_DIR trap (WEB_DIR = $SKILL_DIR/../../web) which a naive symlink would break.
#
# Everything is env-injected so tests use temp dirs only and NEVER touch the real
# ~/.local/bin, ~/.claude, or ~/.copilot:
#   LCARS_BIN_DEST              the PATH launcher dir   (default ~/.local/bin)   <-- NEW (S79)
#   LCARS_SKILLS_DEST           the ~/.claude/skills dest
#   LCARS_COPILOT_PLUGINS_DIR   the Copilot plugins dir
#   LCARS_COPILOT_CONFIG        the Copilot config.json
#   LCARS_COPILOT_BIN           the copilot binary (the "installed?" probe)
#
# Usage: bash tests/install.test.sh
set -uo pipefail

# qgrep: drain stdin fully before grepping (mirrors install-copilot.test.sh) so a
# piped `grep -q` never SIGPIPEs an upstream producer into a phantom failure under
# `set -o pipefail`.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
WEB_DIR="$REPO_ROOT/web"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# Build a fresh isolated env: temp bin dest, temp claude dest, copilot ABSENT
# (so we exercise the graceful-degrade path and never touch a real copilot).
new_env() {
  local e; e="$(mktemp -d "$TMPROOT/env.XXXX")"
  mkdir -p "$e/bin" "$e/claude-skills" "$e/copilot/_direct"
  echo "$e"
}

# Run install.sh against an env dir. $2, if set, is an extra PATH value to expose
# (so we can control whether LCARS_BIN_DEST is on PATH for the hint test).
run_install() {
  local e="$1"; local extra_path="${2:-}"
  LCARS_BIN_DEST="$e/bin" \
  LCARS_SKILLS_DEST="$e/claude-skills" \
  LCARS_COPILOT_PLUGINS_DIR="$e/copilot/_direct" \
  LCARS_COPILOT_CONFIG="$e/copilot/config.json" \
  LCARS_COPILOT_BIN="$e/definitely-no-copilot" \
  PATH="${extra_path:+$extra_path:}$PATH" \
    bash "$INSTALL" >"$e/out.txt" 2>&1
}

SKILL_COUNT="$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo "install (PATH launchers)"

[ -f "$INSTALL" ] || { echo "install.sh not found at $INSTALL"; exit 1; }

# ==========================================================================
# Behaviour 1 + 2: launchers exist and are executable in the bin dest.
# ==========================================================================
e1="$(new_env)"
run_install "$e1"

check "1. lcars-viewscreen launcher exists in the bin dest" \
  "[ -f '$e1/bin/lcars-viewscreen' ]"
check "1. lcars-viewscreen launcher is executable" \
  "[ -x '$e1/bin/lcars-viewscreen' ]"
check "2. lcars-serve alias launcher exists in the bin dest" \
  "[ -f '$e1/bin/lcars-serve' ]"
check "2. lcars-serve alias launcher is executable" \
  "[ -x '$e1/bin/lcars-serve' ]"

# the launcher bakes the repo's ABSOLUTE script path (survives a pull / WEB_DIR trap)
check "1. lcars-viewscreen launcher execs the repo's viewscreen.sh by absolute path" \
  "qgrep -q -- '$REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh' < '$e1/bin/lcars-viewscreen'"
check "2. lcars-serve launcher execs the repo's serve.sh by absolute path" \
  "qgrep -q -- '$REPO_ROOT/skills/lcars-viewscreen/serve.sh' < '$e1/bin/lcars-serve'"

# S128: `lcars launch` documents an escape hatch ($LCARS_WORKTREE_SETUP_CMD) that
# was UNREACHABLE from either surface a person uses — the viewscreen button runs
# in the daemon's own environment, and there was no shell command to set it on.
# A real on-PATH `lcars-launch` makes it reachable from any shell:
#   LCARS_WORKTREE_SETUP_CMD='pnpm install --no-frozen-lockfile' lcars-launch <id>
check "2b. lcars-launch launcher exists and is executable in the bin dest" \
  "[ -f '$e1/bin/lcars-launch' ] && [ -x '$e1/bin/lcars-launch' ]"
check "2b. lcars-launch launcher execs the repo's launch.sh by absolute path" \
  "qgrep -q -- '$REPO_ROOT/skills/lcars-launch/launch.sh' < '$e1/bin/lcars-launch'"

# ==========================================================================
# Behaviour 3: running the launcher resolves WEB_DIR correctly — it reaches the
# repo's web/ dir, NOT a broken ../../bin/../web. Prove with a stubbed python
# that echoes its cwd + argv, LCARS_WEB_DIR UNSET, LCARS_SERVE_NO_OPEN=1.
# ==========================================================================
PYSTUB="$TMPROOT/py-echo"
cat >"$PYSTUB" <<'SH'
#!/usr/bin/env bash
printf 'CWD: %s\n' "$PWD"
printf 'ARGV: %s\n' "$*"
exit 0
SH
chmod +x "$PYSTUB"

# A repo to be "launched in" (so viewscreen.sh's git resolution has a tree).
LAUNCH_REPO="$TMPROOT/launchrepo"
mkdir -p "$LAUNCH_REPO/.git/lcars"
( cd "$LAUNCH_REPO" && git init -q 2>/dev/null )

# Invoke the INSTALLED launcher with LCARS_WEB_DIR unset; the stubbed python
# prints the cwd it was launched from, which must be the repo's web/ dir.
runout="$(cd "$LAUNCH_REPO" && \
  LCARS_PYTHON_BIN="$PYSTUB" LCARS_SERVE_NO_OPEN=1 \
  "$e1/bin/lcars-viewscreen" --open 2>&1)"
check "3. launcher resolves WEB_DIR to the repo's web/ (not a broken ../../web)" \
  "printf '%s' \"\$runout\" | qgrep -q -- 'CWD: $WEB_DIR'"
check "3. lcars-serve alias resolves WEB_DIR identically" \
  "[ \"\$(cd '$LAUNCH_REPO' && LCARS_PYTHON_BIN='$PYSTUB' LCARS_SERVE_NO_OPEN=1 '$e1/bin/lcars-serve' --open 2>&1 | grep -c -- 'CWD: $WEB_DIR')\" -ge 1 ]"

# ==========================================================================
# Behaviour 4: re-running install.sh is idempotent — launchers still point at the
# repo, no .bak churn (our own generated launchers are not treated as foreign).
# ==========================================================================
run_install "$e1"
baks="$(find "$e1/bin" -maxdepth 1 -name 'lcars-viewscreen.bak.*' | wc -l | tr -d ' ')"
check "4. re-install creates NO .bak churn for our own launcher" \
  "[ '$baks' -eq 0 ]"
check "4. re-install: lcars-viewscreen still execs the repo viewscreen.sh" \
  "qgrep -q -- '$REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh' < '$e1/bin/lcars-viewscreen'"
check "4. re-install: exactly one lcars-viewscreen + one lcars-serve in bin" \
  "[ \"\$(find '$e1/bin' -maxdepth 1 -name 'lcars-viewscreen' | wc -l | tr -d ' ')\" -eq 1 ] && [ \"\$(find '$e1/bin' -maxdepth 1 -name 'lcars-serve' | wc -l | tr -d ' ')\" -eq 1 ]"

# ==========================================================================
# Behaviour 5: a pre-existing NON-ours real file at the launcher path is backed
# up (.bak.$$), not clobbered.
# ==========================================================================
e5="$(new_env)"
printf '#!/bin/sh\necho i was here first\n' >"$e5/bin/lcars-viewscreen"
chmod +x "$e5/bin/lcars-viewscreen"
run_install "$e5"
check "5. a pre-existing foreign lcars-viewscreen is backed up (.bak.*)" \
  "[ \"\$(find '$e5/bin' -maxdepth 1 -name 'lcars-viewscreen.bak.*' | wc -l | tr -d ' ')\" -ge 1 ]"
check "5. the backed-up file preserved the original content" \
  "qgrep -q 'i was here first' < \"\$(find '$e5/bin' -maxdepth 1 -name 'lcars-viewscreen.bak.*' | head -1)\""
check "5. the launcher path now holds OUR generated wrapper" \
  "qgrep -q -- '$REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh' < '$e5/bin/lcars-viewscreen'"

# ==========================================================================
# Behaviour 6: PATH hint printed only when LCARS_BIN_DEST is NOT on PATH.
# ==========================================================================
e6a="$(new_env)"
run_install "$e6a"   # bin dest NOT on PATH
check "6. prints add-to-PATH hint when bin dest is NOT on PATH" \
  "qgrep -qi 'PATH' < '$e6a/out.txt'"
check "6. the hint mentions the bin dest path" \
  "qgrep -q -- '$e6a/bin' < '$e6a/out.txt'"

e6b="$(new_env)"
run_install "$e6b" "$e6b/bin"   # bin dest IS on PATH (passed as extra_path)
check "6. prints NO add-to-PATH hint when bin dest IS already on PATH" \
  "! qgrep -qi 'add .* to your PATH\|not on .*PATH\|export PATH' < '$e6b/out.txt'"

# ==========================================================================
# Behaviour 7: the EXISTING claude symlink install + copilot-absent graceful
# path still pass (no regression to install.sh's current behaviour).
# ==========================================================================
e7="$(new_env)"
rc7=0
run_install "$e7" || rc7=$?
check "7. install still exits 0 with copilot absent" \
  "[ '$rc7' -eq 0 ]"
check "7. claude dest still has the lcars skill symlinked" \
  "[ -L '$e7/claude-skills/lcars' ]"
check "7. claude dest has all skills linked (count matches)" \
  "[ \"\$(find '$e7/claude-skills' -maxdepth 1 -type l | wc -l | tr -d ' ')\" -eq '$SKILL_COUNT' ]"
check "7. still prints the copilot-skipped note (graceful degrade)" \
  "qgrep -qi 'copilot' < '$e7/out.txt'"
check "7. does NOT create a copilot symlink when copilot is absent" \
  "[ ! -L '$e7/copilot/_direct/lcars' ]"

# ==========================================================================
echo
printf 'install (PATH launchers): %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
