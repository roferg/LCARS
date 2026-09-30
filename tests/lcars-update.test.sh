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

# --- Session 82: backfills worktreeSetupCommand without clobbering ----------
# An OLD config predates the worktreeSetupCommand key. update must ADD it with
# the ecosystem-detected default (here npm) and preserve every existing value.
repoU="$(new_repo)"
init_repo "$repoU"
# Make the repo look like an npm project so update's detect emits a real default.
printf '{ "scripts": { "test": "jest" } }\n' >"$repoU/package.json"
: >"$repoU/package-lock.json"
cfgU="$repoU/.git/lcars/config.json"
cat >"$cfgU" <<'JSON'
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "custom-runner ${LCARS_TESTS_DIR:-.}",
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "created": "2019-09-09T00:00:00Z"
}
JSON
export GH_LOG="$repoU/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoU/existing"
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
( cd "$repoU" && LCARS_GH_BIN="$repoU/gh" bash "$SCRIPT" >outU.txt 2>&1 )
check "S82 update: backfills the missing worktreeSetupCommand (npm default)" \
  "grep -q '\"worktreeSetupCommand\"' '$cfgU' && grep -q 'npm ci' '$cfgU'"
check "S82 update: backfilled config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgU'"
check "S82 update: preserves the captain's custom model" \
  "grep -q '\"model\": *\"captain-chosen-model\"' '$cfgU'"
check "S82 update: preserves the captain's custom testCommand" \
  "grep -q 'custom-runner' '$cfgU'"
check "S82 update: preserves the captain's comprehensionBudget" \
  "grep -q '\"comprehensionBudget\": *1200' '$cfgU'"
check "S82 update: preserves the captain's created timestamp" \
  "grep -q '\"created\": *\"2019-09-09T00:00:00Z\"' '$cfgU'"
check "S82 update: reports the added worktreeSetupCommand key" \
  "grep -qi 'worktreeSetupCommand' '$repoU/outU.txt'"

# A config that ALREADY has a captain-customized worktreeSetupCommand is NEVER
# clobbered (idempotent, no rewrite when nothing is missing).
repoUc="$(new_repo)"
init_repo "$repoUc"
cfgUc="$repoUc/.git/lcars/config.json"
# Includes a current lcarsVersion (pinned below via LCARS_VERSION) so this repo is
# genuinely fully-current under the versioned schema — update must change nothing.
# S196 — and a `cloneId`, which joined that schema: `lcars update` BACKFILLS the
# clone's durable identity (the source of the per-clone fingerprint in every
# mission id it mints), so a config without one is no longer "fully-current" and
# this idempotence check would be asserting the wrong thing.
cat >"$cfgUc" <<'JSON'
{
  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "stack": "unknown",
  "testCommand": null,
  "worktreeSetupCommand": "my-bespoke-provision --offline",
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "lcarsVersion": "2099.1.1",
  "created": "2018-01-01T00:00:00Z"
}
JSON
cfgUc_before="$(cat "$cfgUc")"
export GH_LOG="$repoUc/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoUc/existing"
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
( cd "$repoUc" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoUc/gh" bash "$SCRIPT" >outUc.txt 2>&1 )
check "S82 update: a captain-set worktreeSetupCommand is left untouched (no clobber)" \
  "grep -q 'my-bespoke-provision --offline' '$cfgUc'"
check "S82 update: config unchanged byte-for-byte when the key is already present" \
  "[ \"\$( cat '$cfgUc' )\" = \"\$cfgUc_before\" ]"
check "S82 update: reports 'nothing to update' when fully current" \
  "grep -qi 'nothing to update' '$repoUc/outUc.txt'"

# --- Session 105: backfills the `stack` key without clobbering --------------
# A pre-S105 config has every current key EXCEPT `stack`. update must ADD ONLY
# that key (with the ecosystem-detected id), report it, and preserve everything
# else byte-for-byte. Pin lcarsVersion current so the ONLY thing missing is stack.
repoS105="$(new_repo)"
init_repo "$repoS105"
# Make the repo an npm project so detect_stack sees `js`.
printf '{ "scripts": { "test": "jest" } }\n' >"$repoS105/package.json"
: >"$repoS105/package-lock.json"
cfgS105="$repoS105/.git/lcars/config.json"
cat >"$cfgS105" <<'JSON'
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "custom-runner ${LCARS_TESTS_DIR:-.}",
  "worktreeSetupCommand": "my-bespoke-provision",
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "lcarsVersion": "2099.1.1",
  "created": "2019-09-09T00:00:00Z"
}
JSON
export GH_LOG="$repoS105/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoS105/existing"
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
( cd "$repoS105" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoS105/gh" bash "$SCRIPT" >outS105.txt 2>&1 )
check "S105 update: adds the missing 'stack' key with the detected id (js)" \
  "grep -q '\"stack\": *\"js\"' '$cfgS105'"
check "S105 update: reports the added 'stack' key" \
  "grep -qi 'stack' '$repoS105/outS105.txt'"
check "S105 update: preserves the captain's custom model" \
  "grep -q '\"model\": *\"captain-chosen-model\"' '$cfgS105'"
check "S105 update: preserves the captain's custom testCommand" \
  "grep -q 'custom-runner' '$cfgS105'"
check "S105 update: preserves the captain's custom worktreeSetupCommand" \
  "grep -q 'my-bespoke-provision' '$cfgS105'"
check "S105 update: preserves the captain's created timestamp" \
  "grep -q '\"created\": *\"2019-09-09T00:00:00Z\"' '$cfgS105'"
check "S105 update: backfilled config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgS105'"

# A config that ALREADY has a captain-set stack is NEVER clobbered.
repoS105c="$(new_repo)"
init_repo "$repoS105c"
# rust markers present, but the captain pinned stack to something bespoke.
printf '[package]\nname = "x"\n' >"$repoS105c/Cargo.toml"
cfgS105c="$repoS105c/.git/lcars/config.json"
cat >"$cfgS105c" <<'JSON'
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "stack": "captain-pinned-stack",
  "testCommand": null,
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "lcarsVersion": "2099.1.1",
  "created": "2018-01-01T00:00:00Z"
}
JSON
export GH_LOG="$repoS105c/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoS105c/existing"
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
( cd "$repoS105c" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoS105c/gh" bash "$SCRIPT" >outS105c.txt 2>&1 )
check "S105 update: a captain-pinned stack is left untouched (no clobber)" \
  "grep -q '\"stack\": *\"captain-pinned-stack\"' '$cfgS105c'"
check "S105 update: reports 'nothing to update' when stack already present + current" \
  "grep -qi 'nothing to update' '$repoS105c/outS105c.txt'"

# --- Session 145: ruby stack never-clobbers a hand-set testCommand ----------
# A pre-S105 config (no `stack`) in a ruby repo (Gemfile + spec/) with a captain-
# set testCommand. update must BACKFILL stack=ruby but leave the testCommand
# byte-for-byte — MISSING-only seeding, never overwrite a present command.
repoS145="$(new_repo)"
init_repo "$repoS145"
printf 'source "https://rubygems.org"\ngem "rspec"\n' >"$repoS145/Gemfile"
mkdir -p "$repoS145/spec"
cfgS145="$repoS145/.git/lcars/config.json"
cat >"$cfgS145" <<'JSON'
{
  "model": "captain-chosen-model",
  "projectName": "myrubyproj",
  "contextFile": null,
  "testCommand": "bundle exec rspec --my-flags spec/only",
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "lcarsVersion": "2099.1.1",
  "created": "2020-02-02T00:00:00Z"
}
JSON
export GH_LOG="$repoS145/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoS145/existing"
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
( cd "$repoS145" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoS145/gh" bash "$SCRIPT" >outS145.txt 2>&1 )
check "S145 update: backfills stack=ruby for a Gemfile+spec repo" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgS145'"
check "S145 update: preserves the captain's hand-set ruby testCommand byte-for-byte (never-clobber)" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgS145' testCommand )\" = 'bundle exec rspec --my-flags spec/only' ]"
check "S145 update: backfilled config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgS145'"

# --- Session 148: an already-initialised repo is REPAIRED, not left broken ---
# Quoting the seeder only helps repos initialised from now on. A repo initialised
# EARLIER carries the unquoted seeded testCommand in .git/lcars/config.json and
# stays broken — its Implement flip-flop gate FALSE-FAILS honest tickets as soon
# as the checkout path contains whitespace. A plain `lcars update` must repair
# exactly that persisted string, and — never-clobber being absolute — must leave
# a hand-written command that merely LOOKS similar completely alone.
s148_repo() { # testCommand → repo dir with a pre-S148 config carrying it
  local repo; repo="$(new_repo)"
  init_repo "$repo"
  printf '{ "scripts": { "test": "jest" } }\n' >"$repo/package.json"
  local esc
  esc="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_json_escape "$1" )"
  cat >"$repo/.git/lcars/config.json" <<JSON
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "stack": "js",
  "testCommand": "$esc",
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": false},
  "lcarsVersion": "2099.1.1",
  "created": "2020-02-02T00:00:00Z"
}
JSON
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
  ( cd "$repo" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out148.txt 2>&1 )
  printf '%s' "$repo"
}
S148_SEEDED='npm test -- ${LCARS_TESTS_DIR:-}'
S148_QUOTED='npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
S148_HAND='npm test -- ${LCARS_TESTS_DIR:-} --coverage'

repoS148="$(s148_repo "$S148_SEEDED")"
S148_GOT="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$repoS148/.git/lcars/config.json" testCommand )"
check "S148 update: repairs the persisted UNQUOTED seeded testCommand" \
  '[ "$S148_GOT" = "$S148_QUOTED" ]'
check "S148 update: config.json stays VALID JSON after the repair" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repoS148/.git/lcars/config.json'"
check "S148 update: the repair is reported to the captain" \
  "grep -qi 'testCommand migrated' '$repoS148/out148.txt'"

repoS148b="$(s148_repo "$S148_HAND")"
S148_GOT_B="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$repoS148b/.git/lcars/config.json" testCommand )"
check "S148 update: NEVER-CLOBBER — a hand-written lookalike is left byte-for-byte" \
  '[ "$S148_GOT_B" = "$S148_HAND" ]'
check "S148 update: no repair reported for a hand-written command" \
  "! grep -qi 'testCommand migrated' '$repoS148b/out148.txt'"


# ==========================================================================
# S201 — `numberOne` SURVIVES `lcars update`.
#
# lcars_config_merge treats DESIRED_CONFIG as the canonical schema: a top-level
# key that is NOT on the list is DELETED. That is the exact failure S196 paid
# for with cloneId, and it would silently un-engage Number One on the next
# update. It also preserves a raw value only when the value sits on ONE LINE —
# so the block must be written as one line and must come back byte-identical.
# ==========================================================================
echo
echo "S201: the numberOne block"

repoXO="$(new_repo)"
init_repo "$repoXO"
CFGXO="$repoXO/.git/lcars/config.json"
check "S201 init: seeds numberOne DISABLED, on one line" \
  "[ \"\$(grep -c '\"numberOne\"' '$CFGXO')\" = '1' ] && grep -q '\"numberOne\": {\"enabled\": false}' '$CFGXO'"
check "S201 init: config.json is valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGXO'"

# Now engage it by hand, exactly the bytes `lcars xo on --engine copilot` writes,
# and prove `lcars update` gives them back UNCHANGED.
XOLINE='  "numberOne": {"enabled": true, "engine": "copilot"},'
python3 - "$CFGXO" "$XOLINE" <<'PY2'
import re, sys
path, line = sys.argv[1], sys.argv[2]
src = open(path).read().splitlines(True)
out = []
for ln in src:
    if '"numberOne"' in ln:
        out.append(line + "\n")
    else:
        out.append(ln)
open(path, "w").writelines(out)
PY2
BEFORE_XO="$(grep '"numberOne"' "$CFGXO")"
export GH_LOG="$repoXO/gh.log"; : >"$GH_LOG"
( cd "$repoXO" && LCARS_GH_BIN="$repoXO/gh" bash "$SCRIPT" >outxo.txt 2>&1 )
AFTER_XO="$(grep '"numberOne"' "$CFGXO")"
check "S201 update: the numberOne block survives (not deleted by the merge)" \
  "grep -q '\"numberOne\"' '$CFGXO'"
check "S201 update: …BYTE-IDENTICAL, on one line" \
  "[ \"\$AFTER_XO\" = \"\$BEFORE_XO\" ] && [ \"\$(grep -c '\"numberOne\"' '$CFGXO')\" = '1' ]"
check "S201 update: config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGXO'"

# An OLD config with no numberOne key at all gets the disabled default backfilled.
repoXOb="$(new_repo)"
init_repo "$repoXOb"
CFGXOb="$repoXOb/.git/lcars/config.json"
grep -v '"numberOne"' "$CFGXOb" >"$CFGXOb.tmp" && mv "$CFGXOb.tmp" "$CFGXOb"
export GH_LOG="$repoXOb/gh.log"; : >"$GH_LOG"
( cd "$repoXOb" && LCARS_GH_BIN="$repoXOb/gh" bash "$SCRIPT" >outxob.txt 2>&1 )
check "S201 update: backfills a MISSING numberOne as disabled, on one line" \
  "grep -q '\"numberOne\": {\"enabled\": false}' '$CFGXOb'"
check "S201 update: …and reports the added key" \
  "grep -q 'numberOne' '$repoXOb/outxob.txt'"
check "S201 update: config.json is valid JSON after the backfill" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGXOb'"


# ==========================================================================
echo
printf 'lcars update: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
