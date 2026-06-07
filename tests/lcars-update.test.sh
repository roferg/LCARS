#!/usr/bin/env bash
#
# Tests for `lcars update` (skill source: skills/lcars-update/update.sh).
#
# `lcars update` brings an ALREADY-INITIALIZED repo up to date with the current
# LCARS schema WITHOUT clobbering the captain's customizations:
#   1. creates any MISSING labels, skips ones already present (via the gh stub log)
#   2. adds any MISSING config keys with their defaults, preserving existing values
#   3. never touches missions/
#   4. on an up-to-date repo, it's a no-op and reports "nothing to update"
#   5. refuses (points to `lcars init`) when .git/lcars/ doesn't exist yet
#
# The script takes its dependencies via env so we can stub them:
#   LCARS_GH_BIN  - the `gh` binary (default: gh)
#
# Usage: bash tests/lcars-update.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_UPDATE_SCRIPT:-$REPO_ROOT/skills/lcars-update/update.sh}"
INIT="$REPO_ROOT/skills/lcars-init/init.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- stubs ----------------------------------------------------------------
make_claude_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  chmod +x "$p"
}

# A fake `gh` that records every invocation and answers `label list`.
# Pre-existing labels come from the file named in $GH_EXISTING (one per line).
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "owner/repo"
  exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  [ -f "$GH_EXISTING" ] && cat "$GH_EXISTING"
  exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$p"
}

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "$repo"
}

# Init a repo so `update` has something to update. All 16 labels are created on
# init; update then sees them as existing.
init_repo() {
  local repo="$1"
  make_claude_stub "$repo/claude"; make_gh_stub "$repo/gh"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
  ( cd "$repo" && LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" bash "$INIT" >/dev/null 2>&1 )
}

# ==========================================================================
echo "lcars update"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 5: refuses when not initialized ----------------------------
repo="$(new_repo)"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
rc=0
( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1 ) || rc=$?
check "5. exits non-zero when .git/lcars/ is absent" "[ '$rc' -ne 0 ]"
check "5. tells the captain to run lcars init first" \
  "grep -qi 'lcars init' '$repo/out.txt'"

# --- Behaviour 1: creates a MISSING label, skips present ones --------------
repo="$(new_repo)"
init_repo "$repo"
# Now pretend the repo has every canonical label EXCEPT lcars:ticket (a newly
# added one). update must create just that one and skip the other 15.
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"
cat >"$GH_EXISTING" <<'EOF'
lcars:align
lcars:research
lcars:validate
lcars:plan
lcars:plan-review
lcars:schedule
lcars:implement
lcars:verify
lcars:done
lcars:feature
lcars:bug
lcars:paused
lcars:awaiting-human
lcars:linked
lcars:mission
EOF
( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "1. creates the one missing label (lcars:ticket)" \
  "grep -q 'label create lcars:ticket' '$repo/gh.log'"
check "1. does NOT re-create an already-present label (lcars:align)" \
  "! grep -q 'label create lcars:align' '$repo/gh.log'"
created="$(grep -c 'label create' "$repo/gh.log")"
check "1. creates exactly one label this run" "[ '$created' -eq 1 ]"
check "1. reports the created label and skipped count" \
  "grep -qi 'lcars:ticket' '$repo/out.txt' && grep -qiE 'present|skip|already' '$repo/out.txt'"

# --- Behaviour 2 & 3: adds missing config key, preserves values & missions/ -
repo="$(new_repo)"
init_repo "$repo"
cfg="$repo/.git/lcars/config.json"
# Captain's config is on an OLDER schema: it has a custom model and testCommand
# but is MISSING comprehensionBudget (a key added later).
cat >"$cfg" <<'JSON'
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "custom-runner ${LCARS_TESTS_DIR:-.}",
  "created": "2019-09-09T00:00:00Z"
}
JSON
# Drop a dummy mission so we can prove update never touches missions/.
mkdir -p "$repo/.git/lcars/missions/lcars-19990101-001"
mfile="$repo/.git/lcars/missions/lcars-19990101-001/state.json"
printf '{"id":"lcars-19990101-001","stage":"plan"}\n' >"$mfile"
mhash_before="$(md5 -q "$mfile" 2>/dev/null || md5sum "$mfile" | awk '{print $1}')"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"
# all 16 present so no label noise
cat >"$GH_EXISTING" <<'EOF'
lcars:align
lcars:research
lcars:validate
lcars:plan
lcars:plan-review
lcars:schedule
lcars:implement
lcars:verify
lcars:done
lcars:feature
lcars:bug
lcars:paused
lcars:awaiting-human
lcars:linked
lcars:mission
lcars:ticket
EOF
( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "2. adds the missing comprehensionBudget key with its default" \
  "grep -q '\"comprehensionBudget\": *1200' '$cfg'"
check "2. preserves the captain's custom model" \
  "grep -q '\"model\": *\"captain-chosen-model\"' '$cfg'"
check "2. preserves the captain's custom testCommand" \
  "grep -q 'custom-runner' '$cfg'"
check "2. preserves the captain's created timestamp" \
  "grep -q '\"created\": *\"2019-09-09T00:00:00Z\"' '$cfg'"
check "2. reports the added config key" \
  "grep -qi 'comprehensionBudget' '$repo/out.txt'"
mhash_after="$(md5 -q "$mfile" 2>/dev/null || md5sum "$mfile" | awk '{print $1}')"
check "3. missions/ is byte-identical (never touched)" \
  "[ '$mhash_before' = '$mhash_after' ]"

# --- Behaviour 4: up-to-date repo -> no-op, 'nothing to update' ------------
repo="$(new_repo)"
init_repo "$repo"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"
cat >"$GH_EXISTING" <<'EOF'
lcars:align
lcars:research
lcars:validate
lcars:plan
lcars:plan-review
lcars:schedule
lcars:implement
lcars:verify
lcars:done
lcars:feature
lcars:bug
lcars:paused
lcars:awaiting-human
lcars:linked
lcars:mission
lcars:ticket
EOF
cfg="$repo/.git/lcars/config.json"
cfg_before="$(cat "$cfg")"
( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "4. up-to-date repo reports 'nothing to update'" \
  "grep -qi 'nothing to update' '$repo/out.txt'"
check "4. up-to-date repo creates no labels" \
  "! grep -q 'label create' '$repo/gh.log'"
check "4. up-to-date config.json is unchanged" \
  "[ \"\$( cat '$cfg' )\" = \"\$cfg_before\" ]"

# ==========================================================================
echo
printf 'lcars update: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
