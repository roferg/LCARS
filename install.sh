#!/usr/bin/env bash
#
# LCARS installer.
#
# Symlinks every skill in ./skills/ into ~/.claude/skills/ so the `lcars`
# commands are available globally, in every repo.
#
# Because these are symlinks back into this clone, updates are effortless:
#
#     git pull          # updates the skill source in place
#                       # the symlinks already point at it — nothing to redo
#
# Re-running this script is safe and idempotent. Run it again after pulling
# only to pick up brand-new skills added since you last installed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_ROOT/skills"
DEST="$HOME/.claude/skills"

[ -d "$SRC" ] || { echo "lcars install: no skills/ directory at $SRC" >&2; exit 1; }
mkdir -p "$DEST"

echo "Installing LCARS skills -> $DEST"
linked=0
for dir in "$SRC"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  name="$(basename "$dir")"
  target="$DEST/$name"

  # If a real file/dir (not one of our symlinks) is already there, back it up
  # rather than clobber someone's existing skill.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    backup="$target.bak.$$"
    mv "$target" "$backup"
    echo "  ! $name already existed — backed up to $(basename "$backup")"
  fi

  ln -sfn "$dir" "$target"
  echo "  ✓ $name"
  linked=$((linked + 1))
done

echo "Linked $linked skill(s)."
command -v claude >/dev/null 2>&1 \
  || echo "  ⚠ Claude CLI not on PATH — install it before running lcars commands."
echo "Done. Run \`lcars init\` inside any repo to get started."
