#!/usr/bin/env bash
#
# gen-copilot-plugin.sh — generate the Copilot/Claude plugin manifest from the
# skill dirs, so the list is NEVER hand-maintained.
#
# Writes a `.claude-plugin/plugin.json` of the form:
#
#   { "name": "lcars", "skills": ["./skills/<a>", "./skills/<b>", ...] }
#
# with exactly one ./skills/<name> entry per directory under skills/ (sorted,
# deterministic). A Copilot plugin uses the same format as a Claude Code plugin,
# so this single manifest serves both CLIs.
#
# Inputs (env-injectable, same style as the rest of LCARS):
#   LCARS_SKILLS_SRC   the skills/ dir to scan   (default: <repo>/skills)
#   LCARS_PLUGIN_OUT   the manifest to write     (default: <repo>/.claude-plugin/plugin.json)
#   LCARS_PLUGIN_NAME  the plugin name           (default: lcars)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LCARS_SKILLS_SRC:-$SCRIPT_DIR/skills}"
OUT="${LCARS_PLUGIN_OUT:-$SCRIPT_DIR/.claude-plugin/plugin.json}"
NAME="${LCARS_PLUGIN_NAME:-lcars}"

[ -d "$SRC" ] || { echo "gen-copilot-plugin: no skills dir at $SRC" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# Collect skill dir names (basename), sorted, deterministic. POSIX-portable.
skills="$(
  find "$SRC" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
    | LC_ALL=C sort
)"

# Build the JSON array body by hand so we have zero runtime deps and a stable,
# pretty-printed shape (one entry per line).
{
  printf '{\n'
  printf '  "name": "%s",\n' "$NAME"
  printf '  "skills": [\n'
  first=1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    "./skills/%s"' "$s"
  done <<EOF
$skills
EOF
  printf '\n  ]\n'
  printf '}\n'
} >"$OUT"

echo "gen-copilot-plugin: wrote $OUT ($(printf '%s\n' "$skills" | grep -c . ) skills)"
