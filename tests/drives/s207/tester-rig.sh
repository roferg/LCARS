#!/usr/bin/env bash
# S207 TESTER RIG — throwaway $HOME symlink farm + throwaway repos.
# NEVER a bare ./install.sh: LCARS_INSTALL_PREFIX derives all five destinations.
#   bash tester-rig.sh up    # build farm, print rig.env
#   bash tester-rig.sh down  # kill recorded pids
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${LCARS_S207_OUT:-/private/tmp/claude-501/-Users-roganferguson-Projects-lcars-dev/f9038875-3809-4f2c-bf19-ce287de46c31/scratchpad/s207}"
ENVF="$OUT/rig.env"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env"; return 0; }
  . "$ENVF"
  for pid in ${RIG_PIDS:-}; do kill "$pid" 2>/dev/null && echo "  TERM $pid"; done
}
case "${1:-up}" in down) down; exit 0;; esac

rm -rf "$OUT/home" "$OUT/prefix"; mkdir -p "$OUT/bin" "$OUT/home" "$OUT/prefix"
FAKEHOME="$OUT/home"
mkdir -p "$FAKEHOME/.claude/skills"
for d in "$REPO"/skills/*/; do ln -sfn "${d%/}" "$FAKEHOME/.claude/skills/$(basename "${d%/}")"; done
cp "$HOME/.gitconfig" "$FAKEHOME/.gitconfig" 2>/dev/null || true
mkdir -p "$FAKEHOME/.config"; cp -R "$HOME/.config/gh" "$FAKEHOME/.config/gh" 2>/dev/null || true
cp -R "$HOME/.copilot" "$FAKEHOME/.copilot" 2>/dev/null || true
cat >"$ENVF" <<EOF
RIG_OUT="$OUT"
RIG_REPO="$REPO"
RIG_HOME="$FAKEHOME"
RIG_PREFIX="$OUT/prefix"
RIG_PIDS=""
EOF
echo "rig up: $ENVF ($(ls "$FAKEHOME/.claude/skills" | wc -l | tr -d ' ') skills linked)"
