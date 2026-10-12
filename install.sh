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
# It ALSO drops a real on-PATH launcher for the viewscreen — `lcars-viewscreen`
# (plus a `lcars-serve` alias) into ~/.local/bin — so the Kanban board is one word
# to start from any raw shell, identically under both CLIs.
#
# Because both CLIs register THIS clone via symlinks AND the launcher bakes in
# THIS clone's absolute path, `git pull` delivers updates with nothing to re-run:
#
#     git pull          # updates the skill source in place
#                       # the symlinks (and the launcher's baked-in repo path)
#                       # already point at it — nothing to redo
#
# Re-running this script is safe and idempotent. Run it again after pulling
# only to pick up brand-new skills added since you last installed.
#
# ---------------------------------------------------------------------------
# AN LCARS INSTALL WRITES TO FIVE DESTINATIONS UNDER $HOME — and only the first
# is obvious:
#
#   LCARS_SKILLS_DEST          the Claude skills dir (default ~/.claude/skills)
#   LCARS_BIN_DEST             on-PATH launcher dir  (default ~/.local/bin)
#                              — lcars-viewscreen, lcars-serve, lcars-launch
#   LCARS_COPILOT_PLUGINS_DIR  Copilot plugins dir   (default ~/.copilot/installed-plugins/_direct)
#   LCARS_COPILOT_CONFIG       Copilot config.json   (default ~/.copilot/config.json)
#   LCARS_VERSION_STAMP        the version-check throttle stamp
#                              (default ~/.claude/lcars-version-check) — written by
#                              skills/lcars-version/check.sh, not by this script,
#                              which is exactly why it was missed: four
#                              destinations were redirected and this FIFTH one was
#                              not, so under an "isolated" install the stamp was
#                              always absent, the throttle never engaged, and
#                              every single check ran `git fetch origin main`.
#                              Against a network origin that fetch BLOCKS on a
#                              credential prompt even with stdin closed — measured
#                              at 600 s, i.e. a hung test run or a hung session.
#
# SETTING ONLY ONE OF THEM does NOT isolate the install. The others still default
# into $HOME, so an "isolated" install off a work-in-progress branch silently
# rewrites the real on-PATH launchers to exec that branch and repoints the real
# Copilot plugin at it. That happened on 2026-09-11 and had to be repaired by hand.
#
# To get a genuinely isolated install, set ONE variable:
#
#   LCARS_INSTALL_PREFIX=/some/scratch/dir ./install.sh
#
# which derives ALL FIVE destinations from that prefix:
#   $PREFIX/claude-skills  $PREFIX/bin  $PREFIX/copilot-plugins
#   $PREFIX/copilot-config.json  $PREFIX/version-check
#
# The five individual variables keep working and still OVERRIDE the prefix, so
# existing tests and docs that set them directly are unaffected.
#
# One more env dependency, which is NOT a destination (nothing is written to it):
#   LCARS_COPILOT_BIN          the copilot binary    (default copilot)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_ROOT/skills"

# Defaults: derived from LCARS_INSTALL_PREFIX when it is set, else $HOME. The
# prefix exists so ONE variable isolates ALL FIVE destinations (see the block
# above) — an install that leaks into $HOME is the hazard it was added to close.
# The fifth, $PREFIX/version-check, is derived in skills/lcars-version/check.sh
# (the script that writes it) from the same LCARS_INSTALL_PREFIX.
PREFIX="${LCARS_INSTALL_PREFIX:-}"
if [ -n "$PREFIX" ]; then
  DEFAULT_SKILLS_DEST="$PREFIX/claude-skills"
  DEFAULT_BIN_DEST="$PREFIX/bin"
  DEFAULT_COPILOT_PLUGINS_DIR="$PREFIX/copilot-plugins"
  DEFAULT_COPILOT_CONFIG="$PREFIX/copilot-config.json"
else
  DEFAULT_SKILLS_DEST="$HOME/.claude/skills"
  DEFAULT_BIN_DEST="$HOME/.local/bin"
  DEFAULT_COPILOT_PLUGINS_DIR="$HOME/.copilot/installed-plugins/_direct"
  DEFAULT_COPILOT_CONFIG="$HOME/.copilot/config.json"
fi

DEST="${LCARS_SKILLS_DEST:-$DEFAULT_SKILLS_DEST}"

BIN_DEST="${LCARS_BIN_DEST:-$DEFAULT_BIN_DEST}"

COPILOT_BIN="${LCARS_COPILOT_BIN:-copilot}"
COPILOT_PLUGINS_DIR="${LCARS_COPILOT_PLUGINS_DIR:-$DEFAULT_COPILOT_PLUGINS_DIR}"
COPILOT_CONFIG="${LCARS_COPILOT_CONFIG:-$DEFAULT_COPILOT_CONFIG}"
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

# ---------------------------------------------------------------------------
# 1b) PATH launchers: drop real `lcars-viewscreen` (+ `lcars-serve` alias)
#     commands onto ~/.local/bin so the board starts from any raw shell, on
#     either CLI. Each launcher is a GENERATED wrapper that `exec`s the repo's
#     real script by ABSOLUTE path — this survives viewscreen.sh's WEB_DIR trap
#     (WEB_DIR = $SKILL_DIR/../../web), which a naive symlink would break, and
#     keeps `git pull` self-updating (the baked path tracks this clone).
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DEST"

# install_launcher <command-name> <repo-relative-script>
# Idempotent + safe: a pre-existing NON-ours real file is backed up (.bak.$$),
# never clobbered; re-running cleanly re-points to the current repo path.
install_launcher() {
  local cmd="$1" script_rel="$2"
  local dest="$BIN_DEST/$cmd"
  local script_abs="$REPO_ROOT/$script_rel"
  local marker="# lcars-launcher: generated by install.sh — edit the repo, not this file"

  # If something is already there and it is NOT one of our generated launchers,
  # back it up rather than clobber it.
  if [ -e "$dest" ] && ! grep -q "lcars-launcher: generated by install.sh" "$dest" 2>/dev/null; then
    local backup="$dest.bak.$$"
    mv "$dest" "$backup"
    echo "  ! $cmd already existed — backed up to $(basename "$backup")"
  fi

  cat >"$dest" <<EOF
#!/usr/bin/env bash
$marker
# Resolves to this LCARS clone's own script, by absolute path, so it works from
# any shell on either CLI and a \`git pull\` needs no re-install.
exec bash "$script_abs" "\$@"
EOF
  chmod +x "$dest"
  echo "  ✓ $cmd -> $script_abs"
}

echo "Installing LCARS launchers -> $BIN_DEST"
install_launcher "lcars-viewscreen" "skills/lcars-viewscreen/viewscreen.sh"
install_launcher "lcars-serve"      "skills/lcars-viewscreen/serve.sh"
# S128: `lcars launch` documents an escape hatch — $LCARS_WORKTREE_SETUP_CMD — that
# no surface could reach. The viewscreen's RUN button runs inside the daemon's own
# environment, and there was no shell command to set the variable on. This launcher
# makes it reachable from any shell:
#   LCARS_WORKTREE_SETUP_CMD='pnpm install --no-frozen-lockfile' lcars-launch <id>
install_launcher "lcars-launch"     "skills/lcars-launch/launch.sh"
# S277: the buddy's documents name a COMMAND and the model runs it verbatim.
# They used to name `bash ~/.claude/skills/lcars-buddy/<script>`, which is
# Claude Code's install location — a Copilot-only machine has no `~/.claude`,
# and a real Copilot turn given that prose took exit 127, reported it, and
# stopped rather than finding the plugin mount it had loaded the skill from.
# These two launchers are the CLI-neutral front door the prose now names.
install_launcher "lcars-buddy"      "skills/lcars-buddy/buddy.sh"
install_launcher "lcars-autopilot"  "skills/lcars-buddy/autopilot.sh"

# PATH hint: only when BIN_DEST is not already a :-segment of $PATH.
case ":$PATH:" in
  *":$BIN_DEST:"*) : ;;  # already on PATH — say nothing
  *)
    # LOUD, not a footnote. $BIN_DEST (~/.local/bin) is NOT on PATH by default on
    # macOS, so an install can finish "successfully" and still leave every
    # launcher the buddy's prose names — `lcars-buddy`, `lcars-autopilot`,
    # `lcars-viewscreen` — answering "command not found". install.sh does not and
    # must not edit anyone's shell profile, so the only cure is this message
    # being impossible to miss, plus the absolute-path fallback below.
    echo "  ────────────────────────────────────────────────────────────────"
    echo "  ⚠  ACTION NEEDED: $BIN_DEST is NOT on your PATH."
    echo "     Until you add it, \`lcars-buddy\`, \`lcars-autopilot\` and"
    echo "     \`lcars-viewscreen\` will say \"command not found\"."
    echo "     Add this line to your ~/.zshrc (or ~/.bashrc), then open a new shell:"
    echo "         export PATH=\"$BIN_DEST:\$PATH\""
    echo "     Fallback, works right now with no PATH change:"
    echo "         bash $REPO_ROOT/skills/lcars-buddy/buddy.sh"
    echo "  ────────────────────────────────────────────────────────────────"
    ;;
esac

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
