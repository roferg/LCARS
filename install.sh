#!/usr/bin/env bash
#
# LCARS installer.
#
# A single `./install.sh` serves BOTH supported CLIs:
#
#   Claude Code  — symlinks every skill in ./skills/ into ~/.claude/skills/.
#   Copilot CLI  — generates the plugin manifest from ./skills/ and registers
#                  THIS repo as a live local plugin (a symlink + a registry
#                  entry in ~/.copilot/config.json).
#
# Because both register THIS clone via symlinks, `git pull` delivers updates
# with nothing to re-run:
#
#     git pull          # updates the skill source in place
#                       # the symlinks already point at it — nothing to redo
#
# Re-running this script is safe and idempotent. Run it again after pulling
# only to pick up brand-new skills added since you last installed.
#
# Dependencies/paths are taken via env so tests can stub them and never touch
# the real ~/.claude or ~/.copilot:
#   LCARS_SKILLS_DEST          the Claude skills dir (default ~/.claude/skills)
#   LCARS_COPILOT_BIN          the copilot binary    (default copilot)
#   LCARS_COPILOT_PLUGINS_DIR  Copilot plugins dir   (default ~/.copilot/installed-plugins/_direct)
#   LCARS_COPILOT_CONFIG       Copilot config.json   (default ~/.copilot/config.json)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_ROOT/skills"
DEST="${LCARS_SKILLS_DEST:-$HOME/.claude/skills}"

COPILOT_BIN="${LCARS_COPILOT_BIN:-copilot}"
COPILOT_PLUGINS_DIR="${LCARS_COPILOT_PLUGINS_DIR:-$HOME/.copilot/installed-plugins/_direct}"
COPILOT_CONFIG="${LCARS_COPILOT_CONFIG:-$HOME/.copilot/config.json}"
PLUGIN_NAME="lcars"

[ -d "$SRC" ] || { echo "lcars install: no skills/ directory at $SRC" >&2; exit 1; }
mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# 1) Claude Code: symlink every skill into ~/.claude/skills/ (unchanged).
# ---------------------------------------------------------------------------
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
echo "Linked $linked skill(s) into Claude."

command -v "$COPILOT_BIN" >/dev/null 2>&1 \
  || command -v claude >/dev/null 2>&1 \
  || echo "  ⚠ Claude CLI not on PATH — install it before running lcars commands."

# ---------------------------------------------------------------------------
# 2) Generate the plugin manifest from the skill dirs (never hand-maintained).
#    Same format for Claude Code plugins and Copilot plugins.
# ---------------------------------------------------------------------------
LCARS_SKILLS_SRC="$SRC" \
LCARS_PLUGIN_OUT="$REPO_ROOT/.claude-plugin/plugin.json" \
LCARS_PLUGIN_NAME="$PLUGIN_NAME" \
  bash "$REPO_ROOT/gen-copilot-plugin.sh" >/dev/null
echo "Generated plugin manifest -> .claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
# 3) Copilot CLI: register THIS repo as a live local plugin, idempotently.
#    Degrade gracefully if Copilot isn't installed.
# ---------------------------------------------------------------------------
# Copilot counts as installed only if its CLI is on PATH. (We never auto-create
# a ~/.copilot just because the config path's parent happens to exist.)
copilot_present=1
command -v "$COPILOT_BIN" >/dev/null 2>&1 || copilot_present=0

if [ "$copilot_present" -eq 0 ]; then
  echo "  ⓘ GitHub Copilot CLI not detected — skipping Copilot plugin registration."
  echo "    (Claude install above is complete. Install copilot, then re-run ./install.sh.)"
  echo "Done. Run \`lcars init\` inside any repo to get started."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⚠ jq not on PATH — cannot edit Copilot config.json; skipping Copilot registration."
  echo "Done. Run \`lcars init\` inside any repo to get started."
  exit 0
fi

mkdir -p "$COPILOT_PLUGINS_DIR"
link="$COPILOT_PLUGINS_DIR/$PLUGIN_NAME"

# Live symlink: <plugins_dir>/lcars -> repo root. -fn replaces any stale link.
ln -sfn "$REPO_ROOT" "$link"
echo "Linked Copilot plugin -> $link"

# Resolve the link to an absolute path for the registry cache_path.
cache_path="$link"

# --- edit config.json, preserving its JSONC header + all other keys/entries --
if [ ! -f "$COPILOT_CONFIG" ]; then
  mkdir -p "$(dirname "$COPILOT_CONFIG")"
  printf '{\n  "installedPlugins": []\n}\n' >"$COPILOT_CONFIG"
fi

# Split the file into its leading // comment header and the JSON body. The
# header is a run of lines at the top that start with optional whitespace + //.
header="$(awk 'BEGIN{h=1} h==1 && /^[[:space:]]*\/\// {print; next} {h=0}' "$COPILOT_CONFIG")"
body="$(awk 'BEGIN{h=1} h==1 && /^[[:space:]]*\/\// {next} {h=0; print}' "$COPILOT_CONFIG")"

# If the body is not valid JSON, bail out without corrupting the file.
if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
  echo "  ⚠ $COPILOT_CONFIG body is not valid JSON after stripping the header — leaving it untouched." >&2
  echo "Done. Run \`lcars init\` inside any repo to get started."
  exit 0
fi

now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
new_body="$(
  printf '%s' "$body" | jq \
    --arg name "$PLUGIN_NAME" \
    --arg cache "$cache_path" \
    --arg src "$REPO_ROOT" \
    --arg now "$now" '
    # ensure installedPlugins exists as an array
    .installedPlugins = (.installedPlugins // [])
    # preserve an existing installed_at for our entry, if any (first match, or null)
    | ([.installedPlugins[] | select(.name == $name) | .installed_at] | first) as $existing_at
    # drop any existing lcars entry, keep everyone else untouched
    | .installedPlugins |= map(select(.name != $name))
    # append a single fresh lcars entry
    | .installedPlugins += [{
        name: $name,
        marketplace: "",
        installed_at: ($existing_at // $now),
        enabled: true,
        cache_path: $cache,
        source: { source: "local", path: $src }
      }]
  '
)"

# Re-prepend the preserved header (if any) and write back atomically.
tmp="$(mktemp "${COPILOT_CONFIG}.lcars.XXXXXX")"
{
  [ -n "$header" ] && printf '%s\n' "$header"
  printf '%s\n' "$new_body"
} >"$tmp"
mv "$tmp" "$COPILOT_CONFIG"
echo "Registered Copilot plugin '$PLUGIN_NAME' in $COPILOT_CONFIG"

echo "Done. Run \`lcars init\` inside any repo to get started."
