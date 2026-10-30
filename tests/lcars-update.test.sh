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
  "gateTimeout": null,
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
  "gateTimeout": null,
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
  "gateTimeout": null,
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
  "gateTimeout": null,
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
  "gateTimeout": null,
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
  "gateTimeout": null,
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
# S309 — `lcars update --engine` / `--model`: a wrong seed is correctable
#        by a VERB, not by hand-editing JSON.
# ==========================================================================
# THE DEFECT: `lcars init` used to seed `model: claude-sonnet` whatever engine
# the run had recorded, and there was NO verb that could change it — so the only
# cure for a repo that had been set up on the wrong engine was to open
# config.json in an editor. A product that records a fact and then offers no way
# to correct the record is asking the captain to edit its own state file.
#
# IT FOLLOWS THE SANCTIONED-WRITER CONTRACT EXACTLY: a verb invocation does
# ONLY its verb (no label sync, no version stamp), it changes ONLY what it was
# asked to change, and every other byte of the captain's config survives.
make_copilot_stub_upd() {
  local p="$1"
  printf '#!/usr/bin/env bash\necho "copilot/0.0.1-test"\n' >"$p"
  chmod +x "$p"
}

repoEng="$(new_repo)"
init_repo "$repoEng"
make_copilot_stub_upd "$repoEng/copilot"
CFGENG="$repoEng/.git/lcars/config.json"
# The captain's own customisations, hand-written over the seeded config: a
# testCommand that is nothing LCARS would ever detect, plus a changed budget.
python3 - "$CFGENG" <<'PY'
import json, re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'"testCommand": [^\n]*,', '"testCommand": "make check-everything --captains-own",', s)
s = re.sub(r'"comprehensionBudget": [^\n,]*', '"comprehensionBudget": 4242', s)
open(p, 'w').write(s)
json.load(open(p))
PY
cp "$CFGENG" "$repoEng/config.before.json"
export GH_LOG="$repoEng/gh.log"; : >"$GH_LOG"
rcEng=0
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" LCARS_COPILOT_BIN="$repoEng/copilot" \
    bash "$SCRIPT" --engine copilot >outeng.txt 2>&1 ) || rcEng=$?
check "S309-3: lcars update --engine copilot succeeds" "[ '$rcEng' -eq 0 ]"
check "S309-3: it REWRITES the model to the one copilot actually runs" \
  "grep -q '\"model\": *\"claude-opus-5.5\"' '$CFGENG'"
check "S309-3: it RECORDS the engine as the repo's pin" \
  "grep -q '\"workerBin\": *\"copilot\"' '$CFGENG'"
check "S309-3: the captain's customised testCommand is untouched" \
  "grep -qF '\"testCommand\": \"make check-everything --captains-own\"' '$CFGENG'"
check "S309-3: config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGENG'"
# THE REAL ASSERTION: EVERY OTHER KEY IS BYTE-IDENTICAL. Comparing the parsed
# objects key by key is what catches a writer that reflowed the file, dropped an
# unlisted key, or quietly refreshed the version stamp on a verb invocation.
check "S309-3: every key except model/workerBin is byte-identical" \
  "python3 -c '
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
changed = {k for k in set(a) | set(b) if a.get(k, 0) != b.get(k, 1)}
assert changed <= {\"model\", \"workerBin\"}, changed
' '$repoEng/config.before.json' '$CFGENG'"
check "S309-3: numberOne is STILL on one line (readers depend on it)" \
  "grep -q '\"numberOne\": {' '$CFGENG' && [ \"\$(grep -c '\"numberOne\"' '$CFGENG')\" = 1 ]"
check "S309-3: a verb invocation syncs NO labels" "[ ! -s '$repoEng/gh.log' ]"
check "S309-3: it says what it changed" \
  "grep -qi 'copilot' '$repoEng/outeng.txt' && grep -q 'claude-opus-5.5' '$repoEng/outeng.txt'"

# …and back again: the verb is symmetric, so a repo recorded wrong the other way
# is correctable too, and the model follows the engine both directions.
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" bash "$SCRIPT" --engine claude >outeng2.txt 2>&1 )
check "S309-3: --engine claude moves the model back" \
  "grep -q '\"model\": *\"claude-sonnet\"' '$CFGENG' && grep -q '\"workerBin\": *\"claude\"' '$CFGENG'"

# `--model` alone sets the model VERBATIM and never touches the engine pin.
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" bash "$SCRIPT" --model 'opus' >outeng3.txt 2>&1 )
check "S309-3: --model sets the model verbatim" \
  "grep -q '\"model\": *\"opus\"' '$CFGENG'"
check "S309-3: --model alone leaves the engine pin alone" \
  "grep -q '\"workerBin\": *\"claude\"' '$CFGENG'"

# Both together: the engine is recorded, and the explicit model wins over the
# engine's default (the captain named it).
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" LCARS_COPILOT_BIN="$repoEng/copilot" \
    bash "$SCRIPT" --engine copilot --model 'claude-sonnet-4.6' >outeng4.txt 2>&1 )
check "S309-3: --engine with an explicit --model honours the captain's model" \
  "grep -q '\"model\": *\"claude-sonnet-4.6\"' '$CFGENG' && grep -q '\"workerBin\": *\"copilot\"' '$CFGENG'"

# An unknown engine is REFUSED, and nothing is written.
cp "$CFGENG" "$repoEng/before-bad.json"
rcBad=0
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" bash "$SCRIPT" --engine gpt5 >outbad.txt 2>&1 ) || rcBad=$?
check "S309-3: an unknown engine is refused non-zero" "[ '$rcBad' -ne 0 ]"
check "S309-3: …naming the engines it knows" \
  "grep -q 'claude' '$repoEng/outbad.txt' && grep -q 'copilot' '$repoEng/outbad.txt'"
check "S309-3: …and config.json is untouched by the refusal" \
  "cmp -s '$repoEng/before-bad.json' '$CFGENG'"
# An empty value is refused too, rather than writing an empty pin.
rcBad=0
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" bash "$SCRIPT" --model '' >outbad2.txt 2>&1 ) || rcBad=$?
check "S309-3: an empty --model is refused, not written" \
  "[ '$rcBad' -ne 0 ] && cmp -s '$repoEng/before-bad.json' '$CFGENG'"

# --- S309: a PLAIN `lcars update` must not DELETE the engine pin ------------
# lcars_config_merge treats its desired list as the canonical schema and DROPS
# every top-level key absent from it. `workerBin` was never on update's list, so
# a plain `lcars update` silently un-pinned the repo — the exact failure S196
# paid for with cloneId and S308 paid for with gateTimeout. A verb that records
# the engine is worthless if the next ordinary update throws the record away.
repoKeep="$(new_repo)"
init_repo "$repoKeep"
make_copilot_stub_upd "$repoKeep/copilot"
CFGKEEP="$repoKeep/.git/lcars/config.json"
( cd "$repoKeep" && LCARS_GH_BIN="$repoKeep/gh" LCARS_COPILOT_BIN="$repoKeep/copilot" \
    bash "$SCRIPT" --engine copilot >/dev/null 2>&1 )
export GH_LOG="$repoKeep/gh.log"; : >"$GH_LOG"
( cd "$repoKeep" && LCARS_GH_BIN="$repoKeep/gh" bash "$SCRIPT" >outkeep.txt 2>&1 )
check "S309-3: a plain lcars update PRESERVES the recorded engine pin" \
  "grep -q '\"workerBin\": *\"copilot\"' '$CFGKEEP'"
check "S309-3: …and preserves the model that goes with it" \
  "grep -q '\"model\": *\"claude-opus-5.5\"' '$CFGKEEP'"

# --- S309 fix round 1, D1: AN EMPTY OR MISSING `--engine` IS A REFUSAL -----
# MEASURED, side by side, against the fix that shipped this session:
#
#   args=[--engine]            RC=0  OUT=[]                 config untouched
#   args=[--engine ""]         RC=0  OUT=[]                 config untouched
#   args=[--model]             RC=1  "an empty model names nothing"
#   args=[--model ""]          RC=1  "an empty model names nothing"
#
# and its sharpest form, `--engine '' --model 'only-model-given'`: RC=0, a tick
# printed for the model, the model WRITTEN, and the engine SILENTLY DROPPED. A
# caller doing `update --engine "$E" --model "$M"` with $E unset reads a tick
# and believes the engine was recorded.
#
# THAT IS THIS SESSION'S OWN FAILURE CLASS reproduced inside the fix for it:
# something did not happen and nothing said so. The `--model` guard was already
# right; `--engine` had no equivalent anywhere in the file. Both flags now
# refuse BEFORE ANY WRITE, non-zero, naming the flag that was empty.
repoArg="$(new_repo)"
init_repo "$repoArg"
CFGARG="$repoArg/.git/lcars/config.json"
cp "$CFGARG" "$repoArg/arg.before.json"
arg_case() { # <label> <expected-rc 0|nonzero> <args...>
  local label="$1" want="$2"; shift 2
  local rc=0
  cp "$repoArg/arg.before.json" "$CFGARG"
  ( cd "$repoArg" && LCARS_GH_BIN="$repoArg/gh" bash "$SCRIPT" "$@" \
      >"$repoArg/arg.out" 2>&1 ) || rc=$?
  ARG_RC="$rc"
}
# The two halves of the asymmetry, now symmetric.
arg_case "engine-missing" x --engine
check "S309-D1: a MISSING --engine value is refused non-zero" "[ '$ARG_RC' -ne 0 ]"
check "S309-D1: …naming the flag, not nothing" \
  "grep -qF -- '--engine' '$repoArg/arg.out' && grep -qi 'nothing was written' '$repoArg/arg.out'"
check "S309-D1: …and config.json is untouched" \
  "cmp -s '$repoArg/arg.before.json' '$CFGARG'"
arg_case "engine-empty" x --engine ''
check "S309-D1: an EMPTY --engine value is refused non-zero" "[ '$ARG_RC' -ne 0 ]"
check "S309-D1: …and config.json is untouched" \
  "cmp -s '$repoArg/arg.before.json' '$CFGARG'"
arg_case "model-missing" x --model
check "S309-D1: a MISSING --model value is still refused non-zero" "[ '$ARG_RC' -ne 0 ]"
arg_case "model-empty" x --model ''
check "S309-D1: an EMPTY --model value is still refused non-zero" "[ '$ARG_RC' -ne 0 ]"

# THE SHARPEST FORM: the engine must not be dropped while the model is written.
arg_case "engine-empty-model-given" x --engine '' --model 'only-model-given'
check "S309-D1: an empty --engine beside a valid --model is REFUSED" \
  "[ '$ARG_RC' -ne 0 ]"
check "S309-D1: …the refusal happens BEFORE any write — no model landed" \
  "cmp -s '$repoArg/arg.before.json' '$CFGARG' && ! grep -q 'only-model-given' '$CFGARG'"
check "S309-D1: …and it never printed a tick for work it dropped" \
  "! grep -q '✓ model set' '$repoArg/arg.out'"

# The valid rows of the same matrix still work, so the guard refuses the empty
# value and nothing else.
arg_case "engine-valid" 0 --engine claude
check "S309-D1: a VALID --engine value still succeeds" \
  "[ '$ARG_RC' -eq 0 ] && grep -q '\"workerBin\": *\"claude\"' '$CFGARG'"
arg_case "model-valid" 0 --model 'claude-opus-5.5'
check "S309-D1: a VALID --model value still succeeds" \
  "[ '$ARG_RC' -eq 0 ] && grep -q '\"model\": *\"claude-opus-5.5\"' '$CFGARG'"

# D5 — A FLAG-SHAPED VALUE IS A MISSING VALUE. `--engine --model 'zzz'` used to
# let `--engine` swallow `--model` as its value and then refuse with
# `unknown option "zzz"`, which names the wrong token: the mistake is the empty
# --engine, not the model string.
arg_case "engine-swallows-flag" x --engine --model 'zzz'
check "S309-D5: a flag-shaped --engine value is refused as a MISSING value" \
  "[ '$ARG_RC' -ne 0 ] && grep -qF -- '--engine' '$repoArg/arg.out'"
check "S309-D5: …and it does not blame the token that was not the mistake" \
  "! grep -qF 'unknown option \"zzz\"' '$repoArg/arg.out'"
check "S309-D5: …and config.json is untouched" \
  "cmp -s '$repoArg/arg.before.json' '$CFGARG'"

# --- S309 fix round 2, D15: `--model` TAKES THE SAME FLAG-SHAPED RULE -------
# MEASURED on the fix-round-1 shipment: `--engine` learned that a value
# beginning with `-` is a MISSING value (D5 above) and `--model` did not. So
# `lcars update --model $M --engine $E` with BOTH variables unset and unquoted
# collapses to `--model --engine` — and that WROTE the literal string
# `--engine` into config.json as the model, exited 0, and printed
#
#   ✓ model set: --engine
#
# The engine was silently dropped behind a success tick: this session's own
# failure class (something did not happen and nothing said so) reproduced in
# the flag this session added. The two flags now read a flag-shaped value the
# same way, so the refusal names whichever flag lost its value and NOTHING is
# written.
arg_case "model-swallows-flag" x --model --engine
check "S309-D15: a flag-shaped --model value is refused as a MISSING value" \
  "[ '$ARG_RC' -ne 0 ]"
check "S309-D15: …it never prints a tick for a model it did not set" \
  "! grep -qF '✓ model set' '$repoArg/arg.out'"
check "S309-D15: …the flag it was handed is NEVER written as the model" \
  "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(\"model\",\"\"))' '$CFGARG')\" != '--engine' ]"
check "S309-D15: …the refusal precedes every write — config.json is untouched" \
  "cmp -s '$repoArg/arg.before.json' '$CFGARG'"
check "S309-D15: …and config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGARG'"

# The rest of the matrix: a flag-shaped --model value followed by anything at
# all is still a missing value, and the refusal names --model rather than
# blaming the next token (D5's lesson, applied to the other flag).
arg_case "model-flag-then-junk" x --model --engine zzz
check "S309-D15: --model --engine zzz is refused, config untouched" \
  "[ '$ARG_RC' -ne 0 ] && cmp -s '$repoArg/arg.before.json' '$CFGARG'"
check "S309-D15: …naming the flag that lost its value, not the next token" \
  "grep -qF -- '--model' '$repoArg/arg.out' \
     && ! grep -qF 'unknown option' '$repoArg/arg.out'"
arg_case "model-flag-then-engine" x --model --engine copilot
check "S309-D15: --model --engine copilot is refused, config untouched" \
  "[ '$ARG_RC' -ne 0 ] && cmp -s '$repoArg/arg.before.json' '$CFGARG'"
check "S309-D15: …and it never ticked a model it never set" \
  "! grep -qF '✓ model set' '$repoArg/arg.out'"

# --- S309 fix round 1, D6: --engine puts `workerBin` WHERE INIT PUTS IT -----
# `--engine` added the key through the generic single-key writer, which inserts
# a brand-new key as the FIRST key after the opening brace — while `lcars init`
# writes it straight after `model`. So the first init or update after an engine
# verb REORDERED one key (identical values, one shot, then stable). Harmless,
# and still a diff in a file the captain reads. The key now lands in the same
# slot both writers use.
repoOrd="$(new_repo)"
init_repo "$repoOrd"
make_copilot_stub_upd "$repoOrd/copilot"
CFGORD="$repoOrd/.git/lcars/config.json"
( cd "$repoOrd" && LCARS_GH_BIN="$repoOrd/gh" LCARS_COPILOT_BIN="$repoOrd/copilot" \
    bash "$SCRIPT" --engine copilot >/dev/null 2>&1 )
ord_keys() { python3 -c 'import json,sys,collections; print(" ".join(json.load(open(sys.argv[1]), object_pairs_hook=collections.OrderedDict).keys()))' "$1"; }
check "S309-D6: --engine writes workerBin immediately after model, as init does" \
  "[ \"\$(ord_keys '$CFGORD' | sed 's/.*\(model workerBin\).*/\1/')\" = 'model workerBin' ]"
check "S309-D6: …and config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$CFGORD'"
cp "$CFGORD" "$repoOrd/ord.after-verb.json"
( cd "$repoOrd" && LCARS_GH_BIN="$repoOrd/gh" bash "$SCRIPT" >/dev/null 2>&1 )
check "S309-D6: …so the NEXT plain update reorders nothing" \
  "[ \"\$(ord_keys '$repoOrd/ord.after-verb.json')\" = \"\$(ord_keys '$CFGORD')\" ]"

# ==========================================================================
echo
printf 'lcars update: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
