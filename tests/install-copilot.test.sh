#!/usr/bin/env bash
#
# Tests for Session 23: Copilot CLI packaging + install.
#
# One ./install.sh serves BOTH CLIs:
#   - links every skills/<name> into ~/.claude/skills (unchanged)
#   - ALSO registers the repo as a live Copilot plugin (symlink + registry
#     entry), idempotently, never touching the real ~/.copilot in tests.
#
# Everything is env-injected so the tests use temp dirs only:
#   LCARS_SKILLS_DEST           the ~/.claude/skills dest (default ~/.claude/skills)
#   LCARS_COPILOT_PLUGINS_DIR   the Copilot plugins dir (default ~/.copilot/installed-plugins/_direct)
#   LCARS_COPILOT_CONFIG        the Copilot config.json (default ~/.copilot/config.json)
#   LCARS_COPILOT_BIN           the copilot binary, for the "installed?" probe
#
# Usage: bash tests/install-copilot.test.sh

set -uo pipefail

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# its first match and closes the pipe; a still-writing upstream producer then
# takes SIGPIPE and exits non-zero, and under `set -o pipefail` that flips a
# genuine match into a phantom assertion failure (timing/load-sensitive — it bit
# the worker-prompt assertions only under the full back-to-back suite). Draining
# first removes the race; exit status and output are otherwise identical to grep.
# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
GEN="$REPO_ROOT/gen-copilot-plugin.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d "${TMPDIR:-.}/lcars-install-copilot.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# config.json is JSONC (leading // comment lines, then a JSON object). Strip the
# header before handing it to jq — mirrors how a JSONC reader would.
cjq() {
  local f="$1"; shift
  awk 'BEGIN{h=1} h==1 && /^[[:space:]]*\/\// {next} {h=0; print}' "$f" | jq "$@"
}
export -f cjq

# A fake copilot binary so the "is Copilot installed?" probe passes.
make_copilot_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "1.0.60"
EOF
  chmod +x "$p"
}

# Build a fresh isolated env (temp claude dest, temp copilot dir + config).
# Echoes the env dir.
new_env() {
  local e; e="$(mktemp -d "$TMPROOT/env.XXXX")"
  # S290: `bin` and `fakehome` are NOT decoration. This suite used to set only
  # the claude + copilot destinations, leaving LCARS_BIN_DEST to default to
  # $HOME/.local/bin — so EVERY RUN of this suite rewrote the real on-PATH
  # launchers to exec whatever checkout the suite ran from. That is the
  # mechanism behind "the dangling launchers regenerate and nobody notices":
  # measured 2026-10-12, when a scoped run from a worktree repointed all five
  # of the captain's live commands at that worktree. Redirecting HOME as well
  # makes the omission impossible to repeat for the two remaining destinations.
  mkdir -p "$e/claude-skills" "$e/copilot/_direct" "$e/bin" "$e/fakehome"
  # seed config.json with a JSONC header + an UNRELATED plugin entry to prove
  # preservation. (Auto-managed file — header lines start with //.)
  cat >"$e/copilot/config.json" <<'JSON'
// User settings belong in settings.json.
// This file is managed automatically.
{
  "installedPlugins": [
    {
      "name": "other-plugin",
      "marketplace": "",
      "installed_at": "2020-01-01T00:00:00.000Z",
      "enabled": true,
      "cache_path": "/somewhere/other-plugin",
      "source": { "source": "github", "repo": "someone/other" }
    }
  ],
  "firstLaunchAt": "2020-01-01T00:00:00.000Z",
  "someOtherKey": 42
}
JSON
  make_copilot_stub "$e/copilot-bin"
  echo "$e"
}

# Run install.sh against an env dir.
run_install() {
  local e="$1"
  HOME="$e/fakehome" \
  LCARS_INSTALL_PREFIX="$e/inst" \
  LCARS_SKILLS_DEST="$e/claude-skills" \
  LCARS_BIN_DEST="$e/bin" \
  LCARS_COPILOT_PLUGINS_DIR="$e/copilot/_direct" \
  LCARS_COPILOT_CONFIG="$e/copilot/config.json" \
  LCARS_COPILOT_BIN="$e/copilot-bin" \
    bash "$INSTALL" >"$e/out.txt" 2>&1
}

# expected skill count = number of dirs under skills/
SKILL_COUNT="$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo "install (copilot)"

[ -f "$INSTALL" ] || { echo "install.sh not found at $INSTALL"; exit 1; }

# ==========================================================================
# Behaviour 1: one install links into BOTH the claude dest AND the copilot
# plugins dir; a second run is idempotent (same counts, no dupes).
# ==========================================================================
e1="$(new_env)"
run_install "$e1"

claude_links="$(find "$e1/claude-skills" -maxdepth 1 -type l | wc -l | tr -d ' ')"
check "1. links every skill into the claude dest" \
  "[ '$claude_links' -eq '$SKILL_COUNT' ]"

# the copilot plugin is a single live symlink 'lcars' -> repo root
check "1. creates a live 'lcars' symlink in the copilot plugins dir" \
  "[ -L '$e1/copilot/_direct/lcars' ]"
check "1. the copilot 'lcars' symlink resolves to the repo root" \
  "[ \"\$(cd '$e1/copilot/_direct/lcars' && pwd -P)\" = \"\$(cd '$REPO_ROOT' && pwd -P)\" ]"

# registry entry added with cache_path = that symlink
check "1. config.json gains an installedPlugins entry named lcars" \
  "cjq '$e1/copilot/config.json' -e '.installedPlugins[] | select(.name==\"lcars\")' >/dev/null"
check "1. the lcars entry cache_path points at the live symlink" \
  "[ \"\$(cjq '$e1/copilot/config.json' -r '.installedPlugins[] | select(.name==\"lcars\") | .cache_path')\" = '$e1/copilot/_direct/lcars' ]"
check "1. the lcars entry source.source is local" \
  "[ \"\$(cjq '$e1/copilot/config.json' -r '.installedPlugins[] | select(.name==\"lcars\") | .source.source')\" = 'local' ]"
check "1. the lcars entry is enabled" \
  "[ \"\$(cjq '$e1/copilot/config.json' -r '.installedPlugins[] | select(.name==\"lcars\") | .enabled')\" = 'true' ]"

# the JSONC header + unrelated keys/entries survive
check "1. preserves the JSONC '// managed automatically' header" \
  "head -2 '$e1/copilot/config.json' | qgrep -q '// '"
check "1. preserves the unrelated other-plugin entry" \
  "cjq '$e1/copilot/config.json' -e '.installedPlugins[] | select(.name==\"other-plugin\")' >/dev/null"
check "1. preserves the unrelated top-level someOtherKey" \
  "[ \"\$(cjq '$e1/copilot/config.json' -r '.someOtherKey')\" = '42' ]"

# claude path stays green regardless
check "1. claude dest still has the lcars skill linked" \
  "[ -L '$e1/claude-skills/lcars' ]"

# --- second run: idempotent ---
run_install "$e1"
claude_links2="$(find "$e1/claude-skills" -maxdepth 1 -type l | wc -l | tr -d ' ')"
copilot_links2="$(find "$e1/copilot/_direct" -maxdepth 1 -type l | wc -l | tr -d ' ')"
lcars_entries="$(cjq "$e1/copilot/config.json" '[.installedPlugins[] | select(.name=="lcars")] | length')"
all_entries="$(cjq "$e1/copilot/config.json" '.installedPlugins | length')"
check "1. second run: claude link count unchanged" \
  "[ '$claude_links2' -eq '$SKILL_COUNT' ]"
check "1. second run: exactly one copilot 'lcars' symlink (no dupes)" \
  "[ '$copilot_links2' -eq 1 ]"
check "1. second run: exactly one lcars registry entry (no dupes)" \
  "[ '$lcars_entries' -eq 1 ]"
check "1. second run: total entries == 2 (lcars + other-plugin, no growth)" \
  "[ '$all_entries' -eq 2 ]"

# ==========================================================================
# Behaviour 2: the generated manifest lists EXACTLY the repo's skills, is
# valid JSON, and every referenced dir has SKILL.md with name/description.
# ==========================================================================
[ -f "$GEN" ] || bad "2. gen-copilot-plugin.sh exists ([ -f $GEN ])"
manifest="$REPO_ROOT/.claude-plugin/plugin.json"
# generation happens as part of install; assert on the committed/generated file
check "2. manifest .claude-plugin/plugin.json exists after install" \
  "[ -f '$manifest' ]"
check "2. manifest is valid JSON" \
  "jq -e . '$manifest' >/dev/null"
check "2. manifest name is lcars" \
  "[ \"\$(jq -r .name '$manifest')\" = 'lcars' ]"
# exactly one ./skills/<name> per dir under skills/, sorted, no extras/omissions
expected_skills="$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | sed 's#^#./skills/#')"
manifest_skills="$(jq -r '.skills[]' "$manifest" | sort)"
check "2. manifest lists EXACTLY one ./skills/<name> per skill dir" \
  "[ \"\$manifest_skills\" = \"\$expected_skills\" ]"
# the committed manifest matches a fresh generation (no drift)
if [ -f "$GEN" ]; then
  fresh="$(mktemp -d "$TMPROOT/fresh.XXXX")"
  ( cd "$fresh" && LCARS_PLUGIN_OUT="$fresh/plugin.json" LCARS_SKILLS_SRC="$REPO_ROOT/skills" bash "$GEN" >/dev/null 2>&1 )
  check "2. committed manifest == fresh generation (no drift)" \
    "diff <(jq -S . '$manifest') <(jq -S . '$fresh/plugin.json') >/dev/null"
fi
# every referenced skill dir has a SKILL.md with name + description frontmatter
m2_ok=1
while IFS= read -r s; do
  d="$REPO_ROOT/$s"
  [ -f "$d/SKILL.md" ] || { m2_ok=0; break; }
  grep -q '^name:' "$d/SKILL.md" || { m2_ok=0; break; }
  grep -q '^description:' "$d/SKILL.md" || { m2_ok=0; break; }
done < <(jq -r '.skills[]' "$manifest")
check "2. every manifest skill dir has SKILL.md with name+description" \
  "[ '$m2_ok' -eq 1 ]"

# ==========================================================================
# Behaviour 3: re-running after a skill dir is added/removed updates manifest
# + links with NO stale links / orphan entries; unrelated config entry stays.
# ==========================================================================
e3="$(new_env)"
# pre-seed a STALE copilot symlink and STALE claude link that should be cleaned
# only if they are ours (a foreign skill link in claude dest should NOT be left
# orphaned by our process, but we only manage lcars in copilot). We focus on the
# manifest reflecting the live skills set after a transient extra skill.
run_install "$e3"
# add a transient skill dir, regenerate manifest, confirm it appears
transient="$REPO_ROOT/skills/lcars-zzz-transient"
mkdir -p "$transient"
cat >"$transient/SKILL.md" <<'EOF'
---
name: lcars-zzz-transient
description: transient test skill, removed by the test.
---
test
EOF
run_install "$e3"
check "3. manifest picks up a newly-added skill dir" \
  "jq -e '.skills | index(\"./skills/lcars-zzz-transient\")' '$REPO_ROOT/.claude-plugin/plugin.json' >/dev/null"
check "3. the new skill is linked into the claude dest" \
  "[ -L '$e3/claude-skills/lcars-zzz-transient' ]"
# remove it, re-install, confirm manifest no longer lists it (no orphan)
rm -rf "$transient"
run_install "$e3"
check "3. manifest drops a removed skill dir (no orphan)" \
  "! jq -e '.skills | index(\"./skills/lcars-zzz-transient\")' '$REPO_ROOT/.claude-plugin/plugin.json' >/dev/null"
check "3. the unrelated other-plugin entry is still preserved" \
  "cjq '$e3/copilot/config.json' -e '.installedPlugins[] | select(.name==\"other-plugin\")' >/dev/null"
# restore the committed manifest to its repo-true state (no transient drift left)
( cd "$REPO_ROOT" && LCARS_PLUGIN_OUT="$REPO_ROOT/.claude-plugin/plugin.json" LCARS_SKILLS_SRC="$REPO_ROOT/skills" bash "$GEN" >/dev/null 2>&1 )

# ==========================================================================
# Behaviour 4: a skill's bash entry point resolves under the copilot layout to
# the SAME repo script the claude symlink reaches.
# ==========================================================================
e4="$(new_env)"
run_install "$e4"
# init.sh is a known bundled entry point.
copilot_path="$e4/copilot/_direct/lcars/skills/lcars-init/init.sh"
claude_path="$e4/claude-skills/lcars-init/init.sh"
repo_path="$REPO_ROOT/skills/lcars-init/init.sh"
check "4. copilot layout reaches the repo's init.sh through the symlink" \
  "[ -f '$copilot_path' ] && [ \"\$(cd \"\$(dirname '$copilot_path')\" && pwd -P)/init.sh\" = \"\$(cd \"\$(dirname '$repo_path')\" && pwd -P)/init.sh\" ]"
check "4. claude layout reaches the same repo init.sh" \
  "[ -f '$claude_path' ] && [ \"\$(cd \"\$(dirname '$claude_path')\" && pwd -P)/init.sh\" = \"\$(cd \"\$(dirname '$repo_path')\" && pwd -P)/init.sh\" ]"

# ==========================================================================
# Behaviour 5: graceful degrade — no copilot bin / no config dir still succeeds
# at the claude linking.
# ==========================================================================
e5="$(new_env)"
rc5=0
HOME="$e5/fakehome" \
LCARS_INSTALL_PREFIX="$e5/inst" \
LCARS_SKILLS_DEST="$e5/claude-skills" \
LCARS_BIN_DEST="$e5/bin" \
LCARS_COPILOT_PLUGINS_DIR="$e5/copilot/_direct" \
LCARS_COPILOT_CONFIG="$e5/copilot/config.json" \
LCARS_COPILOT_BIN="$e5/definitely-no-copilot" \
PATH="$e5/bin:$PATH" \
  bash "$INSTALL" >"$e5/out.txt" 2>&1 || rc5=$?
check "5. install still succeeds (exit 0) when copilot is absent" \
  "[ '$rc5' -eq 0 ]"
check "5. claude links are still created when copilot is absent" \
  "[ -L '$e5/claude-skills/lcars' ]"
check "5. prints a note that copilot was skipped" \
  "grep -qi 'copilot' '$e5/out.txt'"
check "5. does NOT create a copilot symlink when copilot is absent" \
  "[ ! -L '$e5/copilot/_direct/lcars' ]"

# ==========================================================================
echo
printf 'install (copilot): %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
