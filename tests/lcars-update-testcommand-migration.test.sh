#!/usr/bin/env bash
#
# Fast scoped tests for the S101 stale-testCommand migration in `lcars update`
# (skills/lcars-update/update.sh + skills/lcars-init/lcars-common.sh).
#
# S101 requires an IN-PLACE (positional) vitest testCommand: the Test-Writer's
# per-ticket test is authored IN THE REPO and the red gate runs IN PLACE, because
# a co-located test imports its sibling source via `./sibling` and copying it into
# a `.lcars-tests` staging dir detaches it from that source. Repos initialized by
# an OLDER `lcars init` carry a copy-staging vitest testCommand which is now
# INCOMPATIBLE. `lcars update` must recognize that unambiguous LCARS-generated
# fingerprint and rewrite it to the in-place form — and touch nothing else.
#
# Mirrors tests/lcars-update.test.sh: a temp git repo + a stubbed gh + a
# hand-written config.json, running the REAL update.sh and asserting config.json.
#
# Usage: bash tests/lcars-update-testcommand-migration.test.sh

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

make_claude_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  chmod +x "$p"
}

make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "owner/repo"; exit 0; fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  [ -f "$GH_EXISTING" ] && cat "$GH_EXISTING"; exit 0; fi
exit 0
EOF
  chmod +x "$p"
}

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "$repo"
}

init_repo() {
  local repo="$1"
  make_claude_stub "$repo/claude"; make_gh_stub "$repo/gh"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
  ( cd "$repo" && LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" bash "$INIT" >/dev/null 2>&1 )
}

# All canonical labels present, so update reports no label noise.
all_labels() {
  cat >"$1" <<'EOF'
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
}

run_update() {
  local repo="$1"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$repo/existing"; all_labels "$GH_EXISTING"
  ( cd "$repo" && LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >"$repo/out.txt" 2>&1 )
}

# Read a top-level JSON string value jq-free (same escapes as lcars_config_get).
cfg_get() {
  sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" \
    | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# The groutwork stale copy-based form (the exact primary fixture).
STALE='cd packages/editor; if [ -n "${LCARS_TESTS_DIR:-}" ]; then rm -rf .lcars-tests && mkdir -p .lcars-tests && cp -R "${LCARS_TESTS_DIR%/}/." .lcars-tests/; rc=0; node_modules/.bin/vitest run --pool=forks --dir .lcars-tests || rc=$?; rm -rf .lcars-tests; exit $rc; else exec node_modules/.bin/vitest run --pool=forks; fi'
# The exact in-place target it must become.
TARGET='cd packages/editor 2>/dev/null; exec node_modules/.bin/vitest run --pool=forks ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'

# Write a config.json with a chosen testCommand, using lcars_json_escape so the
# stored value is valid JSON regardless of special chars.
write_cfg() {
  local cfg="$1" tc="$2"
  local esc
  esc="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_json_escape "$tc" )"
  cat >"$cfg" <<JSON
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "$esc",
  "worktreeSetupCommand": "my-bespoke-provision --offline",
  "comprehensionBudget": 1200,
  "created": "2019-09-09T00:00:00Z"
}
JSON
}

echo "lcars update — S101 stale testCommand migration"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Case 1: groutwork stale copy-based form -> EXACT in-place target ---------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
write_cfg "$cfg" "$STALE"
run_update "$repo"
got="$(cfg_get "$cfg" testCommand)"
check "1. testCommand migrated to EXACT in-place target (byte-for-byte)" \
  "[ \"\$got\" = \"\$TARGET\" ]"
check "1. --pool=forks flag preserved" \
  "grep -q -- '--pool=forks' '$cfg'"
check "1. leading cd packages/editor preserved" \
  "printf '%s' \"\$got\" | grep -q '^cd packages/editor 2>/dev/null;'"
check "1. no .lcars-tests copy-staging residue remains" \
  "! grep -q '.lcars-tests' '$cfg'"
check "1. output reports the migration" \
  "grep -qi 'testCommand migrated to in-place' '$repo/out.txt'"
check "1. other keys preserved (model)" \
  "grep -q '\"model\": *\"captain-chosen-model\"' '$cfg'"
check "1. other keys preserved (worktreeSetupCommand)" \
  "grep -q 'my-bespoke-provision --offline' '$cfg'"
check "1. created timestamp preserved" \
  "grep -q '\"created\": *\"2019-09-09T00:00:00Z\"' '$cfg'"
check "1. config remains VALID JSON" \
  "python3 -c 'import json,sys;json.load(open(sys.argv[1]))' '$cfg'"

# --- Case 2: ALREADY in-place -> UNCHANGED (idempotent across two runs) -------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
write_cfg "$cfg" "$TARGET"
before="$(cat "$cfg")"
run_update "$repo"
run_update "$repo"     # run twice: migration is a no-op on the in-place form
got="$(cfg_get "$cfg" testCommand)"
check "2. already-in-place testCommand is UNCHANGED after two updates" \
  "[ \"\$got\" = \"\$TARGET\" ]"
check "2. update reports nothing to update (no migration fired)" \
  "grep -qi 'nothing to update' '$repo/out.txt' && ! grep -qi 'testCommand migrated' '$repo/out.txt'"

# --- Case 3: genuine custom command (no fingerprint) -> UNCHANGED ------------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
write_cfg "$cfg" 'npm test'
run_update "$repo"
got="$(cfg_get "$cfg" testCommand)"
check "3. custom 'npm test' left completely untouched" \
  "[ \"\$got\" = 'npm test' ]"
check "3. no migration reported for a custom command" \
  "! grep -qi 'testCommand migrated' '$repo/out.txt'"

# --- Case 4: null testCommand -> migration leaves it (merge unchanged) --------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
cat >"$cfg" <<'JSON'
{
  "model": "captain-chosen-model",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": null,
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "created": "2019-09-09T00:00:00Z"
}
JSON
run_update "$repo"
check "4. null testCommand stays null" \
  "grep -q '\"testCommand\": *null' '$cfg'"
check "4. no migration reported for a null testCommand" \
  "! grep -qi 'testCommand migrated' '$repo/out.txt'"

# --- Case 5: other keys + created preserved, missions/ untouched -------------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
write_cfg "$cfg" "$STALE"
mkdir -p "$repo/.git/lcars/missions/lcars-19990101-001"
mfile="$repo/.git/lcars/missions/lcars-19990101-001/state.json"
printf '{"id":"lcars-19990101-001","stage":"plan"}\n' >"$mfile"
mhash_before="$(md5 -q "$mfile" 2>/dev/null || md5sum "$mfile" | awk '{print $1}')"
run_update "$repo"
check "5. model preserved through migration" \
  "grep -q '\"model\": *\"captain-chosen-model\"' '$cfg'"
check "5. comprehensionBudget preserved" \
  "grep -q '\"comprehensionBudget\": *1200' '$cfg'"
check "5. worktreeSetupCommand preserved" \
  "grep -q 'my-bespoke-provision --offline' '$cfg'"
check "5. created preserved" \
  "grep -q '\"created\": *\"2019-09-09T00:00:00Z\"' '$cfg'"
mhash_after="$(md5 -q "$mfile" 2>/dev/null || md5sum "$mfile" | awk '{print $1}')"
check "5. missions/ byte-identical (never touched)" \
  "[ '$mhash_before' = '$mhash_after' ]"

# --- Case 6: no-cd stale form -> in-place with no cd prefix -------------------
repo="$(new_repo)"; init_repo "$repo"; cfg="$repo/.git/lcars/config.json"
NOCD_STALE='if [ -n "${LCARS_TESTS_DIR:-}" ]; then rm -rf .lcars-tests && mkdir -p .lcars-tests && cp -R "${LCARS_TESTS_DIR%/}/." .lcars-tests/; rc=0; node_modules/.bin/vitest run --dir .lcars-tests || rc=$?; rm -rf .lcars-tests; exit $rc; else exec node_modules/.bin/vitest run; fi'
NOCD_TARGET='exec node_modules/.bin/vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
write_cfg "$cfg" "$NOCD_STALE"
run_update "$repo"
got="$(cfg_get "$cfg" testCommand)"
check "6. no-cd stale form migrates with no cd prefix" \
  "[ \"\$got\" = \"\$NOCD_TARGET\" ]"

echo
printf 'lcars update testCommand migration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
