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
#
# ---------------------------------------------------------------------------
# USAGE
#   ./install.sh              install / re-install (idempotent, reconciling)
#   ./install.sh uninstall    remove everything an install created, and say so
#
# IT NEVER EDITS A SHELL PROFILE. `~/.local/bin` is not on PATH by default on
# macOS, so an install can finish and still leave every command answering
# "command not found". The cure is guidance the user cannot miss plus a
# no-PATH fallback — never a write to ~/.zshrc, ~/.bash_profile or ~/.profile.
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

# The generated-by marker is the ONE test for "this file is LCARS's". It is the
# only thing that may ever authorise deleting or rewriting a file in BIN_DEST:
# ~/.local/bin belongs to the user and routinely holds other projects' commands
# (the captain's holds nine `cf-*` launchers). The manifest below is a RECORD of
# what we installed, not a licence to delete — when the two disagree, the marker
# wins: a marked file is ours even if the manifest has never heard of it (an
# older LCARS wrote no manifest), and an unmarked file is NOT ours even if the
# manifest names it (the user replaced it).
MARKER_TEXT="lcars-launcher: generated by install.sh"
MANIFEST_NAME=".lcars-launchers"

# Partial-install bookkeeping (S290 fix round 1). The closing verdict used to be
# a single READY/NOT READY about ONE probe launcher, so three different ways of
# half-installing all still ended "✓ READY":
#   D2  a launcher written for a script that is not in this checkout at all
#       (ticked green, then hung when run)
#   D6  a launcher directory that is not writable (aborted with a raw bash line
#       number and NO verdict at all)
#   D8  Copilot present but registration refused (bad config JSON / no jq), so
#       LCARS is not actually registered and the install still said READY
# Each records itself here, and launcher_verdict/final_note read it.
LAUNCHERS_SKIPPED=""
BIN_DEST_PROBLEM=""
COPILOT_PARTIAL=""

# --------------------------------------------------------------------------
# Mode dispatch.
# --------------------------------------------------------------------------
MODE="install"
case "${1:-}" in
  ""|install|--install) : ;;
  uninstall|--uninstall) MODE="uninstall" ;;
  -h|--help|help)
    # S290 fix round 1 (D11): the old `sed -n '/^# USAGE/,/^# ----/p'` INCLUDED
    # the terminating `# ----…` rule, so `--help` ended with a bare line of
    # dashes lifted out of the source header. Stop AT the rule, never print it.
    awk '/^# USAGE/{f=1} f && /^# ---/{exit} f' "${BASH_SOURCE[0]}" \
      | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *)
    echo "lcars install: unknown argument '$1' (expected: install | uninstall)" >&2
    exit 64 ;;
esac

# S290 fix round 1 (D10): `./install.sh bogus` exited 64, but
# `./install.sh uninstall --wipe-everything /etc` silently ACCEPTED and ignored
# the extras. Same shape, opposite answer. Reject both the same way: an argument
# this script does not understand is never quietly dropped.
if [ "$#" -gt 1 ]; then
  echo "lcars install: unexpected extra argument(s) after '$1': ${*:2}" >&2
  echo "lcars install: usage: ./install.sh [install | uninstall]" >&2
  exit 64
fi

# shq <string> — <string> as a SINGLE-QUOTED shell literal, embedded single
# quotes closed/escaped/reopened the usual way ('"'"'\''"'"').
#
# S290 fix round 2 (R1-D1): the generated launcher is written through an
# EXPANDING heredoc, so every character of the checkout path lands in the
# generated file where bash will EVALUATE it. Round 1 removed the backticks that
# install.sh itself wrote, but the baked path was still interpolated into
# DOUBLE-quoted strings, so the path could bring its own. Measured from seven
# hostile checkouts: a path containing a backtick ran the backticked word as a
# command (twice) and truncated the printed path; a path containing $lar
# expanded it to nothing, breaking the launcher while the checkout still
# existed. A single-quoted literal is inert: nothing inside it is expanded,
# including a newline. Every use in the generated file then reads the VARIABLE,
# at run time, with ordinary double quotes.
shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# launcher_target <file> — the absolute script path a generated launcher execs.
# Reads the quoted assignment this install.sh writes, then the comment
# breadcrumb an S290-round-1 launcher wrote, then the `exec` line of an older
# one still, so a launcher from any generation is readable.
launcher_target() {
  local t=""
  t="$(sed -n "s/^LCARS_LAUNCHER_TARGET='\(.*\)'\$/\1/p" "$1" 2>/dev/null | head -1)"
  if [ -n "$t" ]; then
    # undo shq's escaping: '\'' back to a plain single quote
    t="$(printf '%s' "$t" | sed "s/'\\\\''/'/g")"
  fi
  if [ -z "$t" ]; then
    t="$(sed -n 's/^# lcars-launcher-target: //p' "$1" 2>/dev/null | head -1)"
  fi
  if [ -z "$t" ]; then
    t="$(sed -n 's/^exec bash "\(.*\)" "\$@"$/\1/p' "$1" 2>/dev/null | head -1)"
  fi
  printf '%s' "$t"
}

# is_ours <file> — true only for a file carrying the generated-by marker.
is_ours() { [ -f "$1" ] && grep -q "$MARKER_TEXT" "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Path IDENTITY, not path STRINGS (S290 fix round 1, D3).
#
# The closing verdict compared `command -v`'s output as a STRING against
# "$BIN_DEST/$probe" and called any difference a shadow. Two perfectly healthy
# setups fail that test while the command runs fine:
#
#   PATH=/home/me/binlink:…   where binlink is a SYMLINK to the launcher dir
#   PATH=prefix/bin:…         a RELATIVE PATH entry
#
# Both resolve to the very file just installed, by another route. Declaring them
# a shadow was wrong, and the old remedy ("remove the shadowing file") told the
# reader to delete their own working launcher. So: resolve both sides and
# compare identity. Genuine shadowing — a DIFFERENT file earlier on PATH — has a
# different identity and stays caught.
#
# Portable to macOS bash 3.2: no `realpath`, no `readlink -f`.
# ---------------------------------------------------------------------------

# file_identity <path> — "<device>:<inode>", identical for two paths that reach
# the SAME file. Empty when it cannot be determined (then same_file falls back).
file_identity() {
  local id=""
  if [ -e "$1" ]; then
    # BSD/macOS flags first, GNU second; `|| true` so a `stat` that rejects both
    # cannot make this a FAILING statement (which `set -e` would turn into an
    # installer exit from inside the $(…) that captures it).
    # -L: FOLLOW symlinks (stat(2), not lstat(2)). Without it, an earlier PATH
    # directory holding a symlink TO our launcher reads as a different file and
    # gets called a shadow, though running it runs exactly what we installed.
    id="$(stat -L -f '%d:%i' "$1" 2>/dev/null || stat -L -c '%d:%i' "$1" 2>/dev/null || true)"
  fi
  printf '%s' "$id"
}

# canon_path <path> — absolute, with every symlinked DIRECTORY component
# resolved (`cd -P`), in a subshell so the caller's cwd never moves.
canon_path() {
  local p="$1" d b
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd -P "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
}

# same_file <a> <b> — do these two paths name one and the same file?
same_file() {
  local a="$1" b="$2" ia ib
  if [ "$a" = "$b" ]; then return 0; fi
  ia="$(file_identity "$a")"
  ib="$(file_identity "$b")"
  if [ -n "$ia" ] && [ "$ia" = "$ib" ]; then return 0; fi
  if [ "$(canon_path "$a")" = "$(canon_path "$b")" ]; then return 0; fi
  return 1
}

# is_lcars_skill_link <path> — true only for a SYMLINK that resolves to
# <checkout>/skills/<name> in an LCARS checkout (a dir holding install.sh beside
# skills/). A user's own real skill directory, and a symlink pointing anywhere
# else, are never ours. A DANGLING link of that exact shape counts as ours, which
# is the case a deleted worktree leaves behind.
is_lcars_skill_link() {
  local l="$1" t root
  [ -L "$l" ] || return 1
  t="$(readlink "$l")" || return 1
  case "$t" in /*) ;; *) t="$(dirname "$l")/$t" ;; esac
  [ "$(basename "$(dirname "$t")")" = "skills" ] || return 1
  root="$(dirname "$(dirname "$t")")"
  if [ -f "$root/install.sh" ] && [ -d "$root/skills" ]; then return 0; fi
  # dangling: the checkout is gone, so nothing can be read from it
  [ ! -e "$t" ] && [ "$(basename "$t")" = "$(basename "$l")" ]
}

# --------------------------------------------------------------------------
# uninstall — removes exactly what an install created, names each thing, and
# refuses to delete anything unmarked. Safe to run twice.
# --------------------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  echo "Uninstalling LCARS"
  removed=0

  if [ -d "$BIN_DEST" ]; then
    for f in "$BIN_DEST"/*; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"
      [ "$name" = "$MANIFEST_NAME" ] && continue
      if is_ours "$f"; then
        rm -f "$f"
        echo "  ✗ removed launcher $name"
        removed=$((removed + 1))
      fi
    done
    if [ -f "$BIN_DEST/$MANIFEST_NAME" ]; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -e "$BIN_DEST/$name" ]; then
          echo "  ⓘ kept $name — it carries no LCARS marker, so it is not ours to delete."
        fi
      done <"$BIN_DEST/$MANIFEST_NAME"
      rm -f "$BIN_DEST/$MANIFEST_NAME"
      echo "  ✗ removed the launcher manifest ($MANIFEST_NAME)"
      removed=$((removed + 1))
    fi
  fi

  # Skill farm 1: Claude Code's ~/.claude/skills
  if [ -d "$DEST" ]; then
    for l in "$DEST"/*; do
      [ -e "$l" ] || [ -L "$l" ] || continue
      if is_lcars_skill_link "$l"; then
        rm -f "$l"
        echo "  ✗ removed Claude skill link $(basename "$l")"
        removed=$((removed + 1))
      fi
    done
  fi

  # Skill farm 2: Copilot's plugin mount
  plink="$COPILOT_PLUGINS_DIR/$PLUGIN_NAME"
  if [ -L "$plink" ]; then
    pt="$(readlink "$plink")"
    if { [ -f "$pt/install.sh" ] && [ -d "$pt/skills" ]; } || [ ! -e "$pt" ]; then
      rm -f "$plink"
      echo "  ✗ removed Copilot plugin link $plink"
      removed=$((removed + 1))
    else
      echo "  ⓘ kept $plink — it does not point at an LCARS checkout."
    fi
  fi

  # The Copilot registry entry, header and other plugins preserved.
  if [ -f "$COPILOT_CONFIG" ] && grep -q "\"$PLUGIN_NAME\"" "$COPILOT_CONFIG" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
      header="$(awk 'BEGIN{h=1} h==1 && /^[[:space:]]*\/\// {print; next} {h=0}' "$COPILOT_CONFIG")"
      body="$(awk 'BEGIN{h=1} h==1 && /^[[:space:]]*\/\// {next} {h=0; print}' "$COPILOT_CONFIG")"
      if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        new_body="$(printf '%s' "$body" | jq --arg name "$PLUGIN_NAME" \
          '.installedPlugins = ((.installedPlugins // []) | map(select(.name != $name)))')"
        tmp="$(mktemp "${COPILOT_CONFIG}.lcars.XXXXXX")"
        { [ -n "$header" ] && printf '%s\n' "$header"; printf '%s\n' "$new_body"; } >"$tmp"
        mv "$tmp" "$COPILOT_CONFIG"
        echo "  ✗ removed the '$PLUGIN_NAME' entry from $COPILOT_CONFIG"
        removed=$((removed + 1))
      else
        echo "  ⚠ $COPILOT_CONFIG body is not valid JSON — leaving it untouched." >&2
      fi
    else
      echo "  ⚠ jq not on PATH — cannot edit $COPILOT_CONFIG; the '$PLUGIN_NAME' entry remains." >&2
    fi
  fi

  if [ "$removed" -eq 0 ]; then
    echo "  nothing to remove — LCARS is not installed here (or was already uninstalled)."
  fi
  echo "Uninstalled $removed item(s). The LCARS clone itself was not touched; delete it yourself if you want it gone."
  exit 0
fi

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
# S290 fix round 1 (D6): a non-writable launcher dir used to abort the whole
# installer with bash's own `install.sh: line 329: …: Permission denied`, exit 1,
# and NO verdict at all. Detect it here, say what is wrong in words, skip the
# launcher section, and still reach a closing verdict.
mkdir -p "$BIN_DEST" 2>/dev/null || true
if [ ! -d "$BIN_DEST" ]; then
  BIN_DEST_PROBLEM="could not be created"
elif [ ! -w "$BIN_DEST" ] || [ ! -x "$BIN_DEST" ]; then
  BIN_DEST_PROBLEM="is not writable by you"
fi

# install_launcher <command-name> <repo-relative-script>
# Idempotent + safe: a pre-existing NON-ours real file is backed up (.bak.$$),
# never clobbered; re-running cleanly re-points to the current repo path.
CURRENT_LAUNCHERS=()

# in_current <name> — is this launcher name one THIS checkout generates?
in_current() {
  local n="$1" c
  for c in ${CURRENT_LAUNCHERS[@]+"${CURRENT_LAUNCHERS[@]}"}; do
    if [ "$c" = "$n" ]; then return 0; fi
  done
  return 1
}

install_launcher() {
  local cmd="$1" script_rel="$2"
  local dest="$BIN_DEST/$cmd"
  local script_abs="$REPO_ROOT/$script_rel"
  local marker="# $MARKER_TEXT — edit the repo, not this file"
  CURRENT_LAUNCHERS+=("$cmd")

  # S290 fix round 1 (D2): the launcher set is a hardcoded list, so a checkout
  # MISSING one of those skills still got a launcher written for it — printed
  # with a green ✓ naming a file that does not exist, and the install still
  # closed "✓ READY". Running it then hit the dangling-target guard. Never write
  # a launcher we already know is broken; name it and let the verdict say so.
  if [ ! -f "$script_abs" ]; then
    echo "  ✗ $cmd SKIPPED — its script is not in this checkout:"
    echo "      $script_abs"
    echo "    Your clone is incomplete (try \`git pull\`). No launcher file was"
    echo "    written for $cmd, because one pointing at a missing script is worse"
    echo "    than none. Its NAME is still recorded in the manifest beside the"
    echo "    launchers: that is deliberate, so an incomplete clone can never make"
    echo "    the next install reclaim that name and delete a working $cmd."
    LAUNCHERS_SKIPPED="$LAUNCHERS_SKIPPED $cmd"
    return 0
  fi

  # D6, per-file: the dir-level check above covers the usual case, but a single
  # read-only FILE sitting at $dest would still abort the installer. Probe it —
  # only when it already exists, with `>>` so nothing is truncated and no empty
  # file is conjured (an empty file would carry no marker and the backup branch
  # below would dutifully "rescue" it).
  if [ -e "$dest" ] && ! : 2>/dev/null >>"$dest"; then
    echo "  ✗ $cmd SKIPPED — cannot write $dest (permission denied)."
    LAUNCHERS_SKIPPED="$LAUNCHERS_SKIPPED $cmd"
    return 0
  fi

  # If something is already there and it is NOT one of our generated launchers,
  # back it up rather than clobber it.
  if [ -e "$dest" ] && ! is_ours "$dest"; then
    local backup="$dest.bak.$$"
    mv "$dest" "$backup"
    echo "  ! $cmd already existed — backed up to $(basename "$backup")"
  fi

  # Reconciliation cases (b) and (c): the name IS in the current set but the
  # launcher sitting there points somewhere else. Repoint it — and SAY SO,
  # naming the old path. (b) is the measured failure of 2026-10-12: a worktree
  # install baked that worktree's paths in, the worktree was deleted, and all
  # five commands exited 127 with nothing anywhere saying why. (c) is the same
  # thing before the deletion, and it is reported rather than left silent
  # because a silent repoint means the user cannot tell which checkout their
  # commands run.
  local old=""
  if is_ours "$dest"; then old="$(launcher_target "$dest")"; fi

  # ⚠ THIS IS AN EXPANDING HEREDOC: every character written here lands in the
  # generated launcher, where bash will EVALUATE it. Two measured consequences:
  #
  #  (1) a backtick written HERE is a backtick IN THE GENERATED FILE. 2026-10-12:
  #      the dangling-target guard quoted the command name as \`$cmd\`, so the
  #      generated file read  echo "lcars: `lcars-buddy` points at …"  — running a
  #      launcher whose target was gone RAN THE LAUNCHER AGAIN. With the bin dir
  #      on PATH (the shipped configuration) that is unbounded recursion: caged
  #      at 20 s it never returned, and install.sh's own READY probe inherited
  #      the hang, so a whole install produced no verdict. Off PATH it printed
  #      the name BLANK — "lcars:  points at…" — and naming the command was the
  #      entire point of the guard.
  #
  #  (2) the same mechanism, one step removed: the baked CHECKOUT PATH is data
  #      from outside, and interpolating it into a double-quoted string in the
  #      generated file let the PATH bring its own backtick, $var or $(…).
  #      Measured from hostile checkouts: `.../back`tick`/` ran `tick` twice and
  #      printed a truncated path; `.../dol$lar/` expanded to nothing and broke
  #      the launcher while the checkout still existed (exit 127, nothing
  #      deleted).
  #
  # SO: the target and the command name are emitted ONCE EACH, as inert
  # single-quoted literals via shq(), and every use below reads the resulting
  # VARIABLE at run time. No `$script_abs` / `$cmd` interpolation anywhere else
  # in this heredoc, and no backticks in it, ever.
  # tests/install-reconcile.test.sh behaviours 10, 17 and 18 pin all of this by
  # RUNNING the generated launchers, under a cage, from hostile paths.
  local script_q cmd_q
  script_q="$(shq "$script_abs")"
  cmd_q="$(shq "$cmd")"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
$marker
# Resolves to this LCARS clone's own script, by absolute path, so it works from
# any shell on either CLI and a 'git pull' needs no re-install. These two lines
# are also the breadcrumb install.sh reads to find out where an already-present
# launcher points (see launcher_target).
LCARS_LAUNCHER_TARGET=$script_q
LCARS_LAUNCHER_NAME=$cmd_q

# A launcher outlives its checkout. Without this guard a deleted clone left the
# command installed and executable, and 'exec bash' failed with bash's own
# "No such file or directory" and exit 127 — which says nothing a reader can act
# on. Measured across all five launchers on 2026-10-12.
if [ ! -f "\$LCARS_LAUNCHER_TARGET" ]; then
  echo "lcars: '\$LCARS_LAUNCHER_NAME' points at an LCARS checkout that no longer exists:" >&2
  echo "         \$LCARS_LAUNCHER_TARGET" >&2
  echo "       Re-run ./install.sh from your LCARS clone to repoint it, or" >&2
  echo "       delete this launcher (\$0)." >&2
  exit 127
fi

# ...and PRESENT is not RUNNABLE. 'exec bash FILE' fails whenever FILE cannot be
# READ, so [ -r ] is exactly the predicate the line at the bottom depends on.
# Without this check a target the user cannot read passed the guard, the
# self-test said nothing was wrong, install.sh printed "✓ READY" — and the
# command then died with bash's "Permission denied" and exit 126. A missing
# checkout and an unreadable file are different problems with different cures,
# so they get different messages and different exit statuses.
if [ ! -r "\$LCARS_LAUNCHER_TARGET" ]; then
  echo "lcars: '\$LCARS_LAUNCHER_NAME' points at a file it cannot read:" >&2
  echo "         \$LCARS_LAUNCHER_TARGET" >&2
  echo "       The checkout is there, but that file's permissions do not let you" >&2
  echo "       read it, so bash cannot run it. Either make it readable" >&2
  echo "       (chmod +r on the file, and +rx on the directories above it), or" >&2
  echo "       re-run ./install.sh from a clone you own." >&2
  exit 126
fi

# Resolution self-test, used by install.sh's closing verdict: proves the name
# resolves, this file runs, and the baked target is both present AND readable —
# because it sits BELOW both guards above, which are the very predicates
# 'exec bash' needs. It deliberately asserts nothing of its own: a self-test
# with its own copy of the checks could drift from the real path and go on
# saying READY after the real path had stopped working, which is the whole
# class this session exists to remove. It stops short only of starting the
# product. Matched only as an exact first argument, so every other invocation
# stays a byte-identical pass-through.
if [ "\${1:-}" = "--lcars-launcher-selftest" ]; then
  echo "\$LCARS_LAUNCHER_NAME -> \$LCARS_LAUNCHER_TARGET"
  exit 0
fi

exec bash "\$LCARS_LAUNCHER_TARGET" "\$@"
EOF
  chmod +x "$dest"

  if [ -n "$old" ] && [ "$old" != "$script_abs" ]; then
    if [ ! -f "$old" ]; then
      echo "  ↻ $cmd was pointing into a checkout that no longer exists:"
      echo "      $old"
      echo "    repointed at this checkout (that is why it had stopped working)."
    else
      echo "  ↻ $cmd was pointing at another LCARS checkout:"
      echo "      $old"
      echo "    repointed at this checkout."
    fi
  fi
  echo "  ✓ $cmd -> $script_abs"
}

# reconcile_launchers — case (a): a launcher bearing OUR marker whose name this
# checkout no longer generates is stale, so remove it. This is the half a plain
# re-install could never do: `main` does not generate `lcars-buddy`, so it could
# not reclaim the name a branch install had left behind, and the dangling command
# survived every repair attempt. Only marked files are ever touched.
reconcile_launchers() {
  local f name tgt reconciled=0

  # Manifest cross-check first, for the one case the marker alone cannot explain:
  # a name we recorded whose file is no longer ours. The user replaced it. Say so
  # rather than silently skipping, so "it is still there" is not read as a bug.
  if [ -f "$BIN_DEST/$MANIFEST_NAME" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      in_current "$name" && continue
      f="$BIN_DEST/$name"
      [ -e "$f" ] || continue
      is_ours "$f" && continue
      echo "  ⓘ $name is not an LCARS launcher (no marker) — left alone."
    done <"$BIN_DEST/$MANIFEST_NAME"
  fi

  for f in "$BIN_DEST"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "$MANIFEST_NAME" ] && continue
    case "$name" in *.bak.*) continue ;; esac
    is_ours "$f" || continue          # never a file that is not ours
    in_current "$name" && continue
    tgt="$(launcher_target "$f")"
    rm -f "$f"
    echo "  ✗ removed stale launcher $name — this checkout no longer provides it${tgt:+ (it pointed at $tgt)}"
    reconciled=$((reconciled + 1))
  done

  # The manifest: the record of what this install put here, read by the next run
  # and by `uninstall`. Names only, one per line, so it stays trivially parseable.
  printf '%s\n' ${CURRENT_LAUNCHERS[@]+"${CURRENT_LAUNCHERS[@]}"} >"$BIN_DEST/$MANIFEST_NAME"
}

# launcher_verdict — the closing PASS/FAIL. It is produced by RESOLVING a
# launcher through the real PATH and RUNNING it, never by asserting that an
# install "succeeded": on 2026-10-12 five installed commands all exited 127 and
# nothing in any output said so.
launcher_verdict() {
  local probe="lcars-buddy" resolved="" out="" rc=0

  # D6: if the launcher directory itself was unusable, nothing was installed
  # there. Say that, in words, rather than leaving the reader with a bash line
  # number and no verdict.
  if [ -n "$BIN_DEST_PROBLEM" ]; then
    echo "  ✗ NOT READY — the launcher directory $BIN_DEST_PROBLEM:"
    echo "      $BIN_DEST"
    echo "    No LCARS command was installed there, so \`lcars-buddy\`,"
    echo "    \`lcars-viewscreen\` and the rest will say \"command not found\"."
    echo "    Cures, either works:"
    echo "      1. make it writable (chmod u+w \"$BIN_DEST\"), then re-run ./install.sh"
    echo "      2. choose another directory:"
    echo "         LCARS_BIN_DEST=\"\$HOME/bin\" ./install.sh"
    echo "      3. skip the launchers entirely and call the script directly:"
    echo "         bash $REPO_ROOT/skills/lcars-buddy/buddy.sh"
    return 0
  fi

  in_current "$probe" || probe="${CURRENT_LAUNCHERS[0]:-}"
  [ -n "$probe" ] || return 0

  # D2: never probe a name we refused to write — report the refusal instead.
  if [ -n "$LAUNCHERS_SKIPPED" ]; then
    case " $LAUNCHERS_SKIPPED " in
      *" $probe "*)
        echo "  ✗ NOT READY — \`$probe\` was not installed (see the ✗ above):"
        echo "      its script is missing from this checkout, so no launcher was written."
        echo "    Re-clone or \`git pull\` this repo, then re-run ./install.sh."
        return 0 ;;
    esac
  fi

  resolved="$(command -v "$probe" 2>/dev/null || true)"

  if [ -z "$resolved" ]; then
    echo "  ✗ NOT READY — \`$probe\` does not resolve on your PATH, so LCARS"
    echo "    commands will say \"command not found\". Two cures, either works:"
    echo "      1. export PATH=\"$BIN_DEST:\$PATH\"   (add to your shell profile, new shell)"
    echo "      2. bash $REPO_ROOT/skills/lcars-buddy/buddy.sh   (no PATH change at all)"
    if [ -r "$REPO_ROOT/skills/lcars-buddy/buddy.sh" ] \
       && bash -n "$REPO_ROOT/skills/lcars-buddy/buddy.sh" 2>/dev/null; then
      echo "    (route 2 verified just now: that file is present and parses.)"
    else
      echo "    ⚠ route 2's script is missing from this checkout — your clone is incomplete."
    fi
    return 0
  fi

  # D3: compare IDENTITY, not path strings. A symlinked or relative PATH entry
  # reaches the very file we installed and must NOT be called a shadow; a
  # different file earlier on PATH still is one. And the remedy no longer says
  # "remove the shadowing file" — in the two healthy shapes above there was no
  # shadowing file, so that advice told the reader to delete their own working
  # launcher. We never recommend deleting a file we have not identified.
  if ! same_file "$resolved" "$BIN_DEST/$probe"; then
    echo "  ✗ NOT READY — \`$probe\` resolves to a DIFFERENT file from the one"
    echo "    just installed, so your shell will run something else:"
    echo "      found first on PATH: $resolved"
    echo "      installed by LCARS:  $BIN_DEST/$probe"
    echo "    Something earlier on your PATH provides \`$probe\` too. Put"
    echo "    $BIN_DEST earlier on PATH so the LCARS launcher wins. (Look at both"
    echo "    files above and decide for yourself what the other one is — this"
    echo "    installer will not delete either of them.)"
    return 0
  fi

  out="$("$probe" --lcars-launcher-selftest 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ NOT READY — \`$probe\` resolves to $resolved but failed when run"
    echo "    (exit $rc): $out"
    return 0
  fi

  # The probe resolves and runs. That is necessary but, D2/D8 showed, not
  # sufficient: other parts of the install may have been refused. READY is
  # reserved for an install with nothing outstanding.
  if [ -n "$LAUNCHERS_SKIPPED" ] || [ -n "$COPILOT_PARTIAL" ]; then
    echo "  ⚠ PARTIAL — \`$probe\` resolves on your PATH and ran: tested just now,"
    echo "    $out"
    echo "    ...but this install did NOT finish everything:"
    if [ -n "$LAUNCHERS_SKIPPED" ]; then
      echo "      • not installed:$LAUNCHERS_SKIPPED (script missing from this checkout)"
    fi
    if [ -n "$COPILOT_PARTIAL" ]; then
      echo "      • LCARS is NOT registered with GitHub Copilot CLI: $COPILOT_PARTIAL"
    fi
    return 0
  fi

  echo "  ✓ READY — \`$probe\` resolves on your PATH and ran: tested just now,"
  echo "    $out"
}

# final_note — every install exit path ends here. NOT READY returns 1 so
# shell && chains cannot continue with unusable commands; READY/PARTIAL return 0.
#
# S290 fix round 1:
#  D4 (INHERITED from main, cured because it makes THIS session's promise —
#      "a stranger's first run works" — dishonest): the sign-off used to read
#      "Run `lcars init` inside any repo to get started." After fifteen lines
#      about shell commands and PATH, a stranger types `lcars init` at a shell
#      prompt and gets `bash: lcars: command not found`. There is no `lcars`
#      launcher — every installed command is `lcars-<something>` — because
#      `lcars init` is a SKILL, run inside Claude Code or GitHub Copilot CLI.
#      The wording now says where it is run. No `lcars` launcher was invented.
#  D5: that line also printed verbatim two lines under "✗ NOT READY", so a
#      failed install ended "you are broken" / "Done." The sign-off is now
#      conditional on the verdict it follows.
final_note() {
  local verdict=""
  verdict="$(launcher_verdict || true)"
  if [ -n "$verdict" ]; then printf '%s\n' "$verdict"; fi

  case "$verdict" in
    *"NOT READY"*)
      echo "Not finished — see the ✗ above, then re-run ./install.sh."
      echo "(Once it reads READY: open a repo in Claude Code or GitHub Copilot CLI"
      echo " and ask for the \`lcars init\` skill there. It is a CLI skill, not a"
      echo " shell command.)"
      return 1
      ;;
    *"PARTIAL"*)
      echo "Partly done — the shell commands work; see the ⚠ above for what did not."
      echo "To get started: open a repo in Claude Code or GitHub Copilot CLI and ask"
      echo "for the \`lcars init\` skill there. It is a CLI skill, not a shell command."
      ;;
    *)
      echo "Done. To get started, open any repo in Claude Code or GitHub Copilot CLI"
      echo "and ask for the \`lcars init\` skill there — \`lcars init\` is a CLI skill,"
      echo "not a shell command, so it is not typed at a shell prompt."
      ;;
  esac
}

echo "Installing LCARS launchers -> $BIN_DEST"
if [ -n "$BIN_DEST_PROBLEM" ]; then
  # D6: say it here too, where the reader is looking, then carry on to the
  # Copilot/Claude work and the closing verdict instead of dying mid-write.
  echo "  ✗ this directory $BIN_DEST_PROBLEM — skipping all shell launchers."
  echo "    (The closing verdict below explains the cures.)"
else
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

reconcile_launchers
fi

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
  final_note
  exit $?
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⚠ jq not on PATH — cannot edit Copilot config.json; skipping Copilot registration."
  # D8: Copilot IS installed and we could not register with it. That is a
  # partial install, not a READY one.
  COPILOT_PARTIAL="jq is not on PATH, so $COPILOT_CONFIG could not be edited"
  final_note
  exit $?
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
  # D8: refusing to corrupt the file is right; closing "✓ READY" over the top of
  # it was not. LCARS is not registered with Copilot and the verdict must say so.
  COPILOT_PARTIAL="$COPILOT_CONFIG is not valid JSON, so it was left untouched"
  final_note
  exit $?
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

final_note
