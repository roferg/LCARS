#!/usr/bin/env bash
#
# Tests for `lcars init` (skill source: skills/lcars-init/init.sh).
#
# Tests the in-repo source directly, so they pass on a fresh clone before
# `./install.sh` has been run. Override the path with LCARS_INIT_SCRIPT.
#
# Drives the six behaviours from the build order, in order:
#   1. Creates .git/lcars/ if it doesn't exist
#   2. Creates .git/lcars/config.json with correct shape
#   3. Detects CONTEXT.md and records it in config
#   4. Detects missing Claude CLI and exits with clear error
#   5. Calls gh label create for each label, skips existing ones
#   6. Prints correct readiness summary
#
# The script under test takes its dependencies via env so we can stub them:
#   LCARS_CLAUDE_BIN  - the `claude` binary (default: claude)
#   LCARS_GH_BIN      - the `gh` binary    (default: gh)
#
# Usage: bash tests/lcars-init.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_INIT_SCRIPT:-$REPO_ROOT/skills/lcars-init/init.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- stubs ----------------------------------------------------------------
# A fake `claude` that reports a version (CLI present).
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

# Build an isolated git repo with stubs wired up. Echoes the repo path.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "$repo"
}

# ==========================================================================
echo "lcars init"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1 & 2: creates .git/lcars/ and config.json -----------------
repo="$(new_repo)"
make_claude_stub "$repo/claude"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
(
  cd "$repo"
  LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1
)
check "1. creates .git/lcars/"            "[ -d '$repo/.git/lcars' ]"
check "1. creates missions/ subdir"       "[ -d '$repo/.git/lcars/missions' ]"
check "2. creates config.json"            "[ -f '$repo/.git/lcars/config.json' ]"
check "2. config has model key"           "grep -q '\"model\"' '$repo/.git/lcars/config.json'"
check "2. config has projectName key"     "grep -q '\"projectName\"' '$repo/.git/lcars/config.json'"
check "2. config has contextFile key"     "grep -q '\"contextFile\"' '$repo/.git/lcars/config.json'"
check "2. config has created key"         "grep -q '\"created\"' '$repo/.git/lcars/config.json'"
# the red gate's test command lives in config; null when nothing is detected
check "2. config has testCommand key"     "grep -q '\"testCommand\"' '$repo/.git/lcars/config.json'"
check "2. testCommand is null in a bare repo" \
  "grep -q '\"testCommand\": *null' '$repo/.git/lcars/config.json'"
# the Plan stage's comprehension-load target lives in config; default 1200
check "2. config has comprehensionBudget key" \
  "grep -q '\"comprehensionBudget\"' '$repo/.git/lcars/config.json'"
check "2. comprehensionBudget defaults to 1200" \
  "grep -q '\"comprehensionBudget\": *1200' '$repo/.git/lcars/config.json'"

# --- Behaviour 2b: detects a test command from the repo's ecosystem --------
repoTC="$(new_repo)"
printf '{\n  "scripts": { "test": "jest" }\n}\n' >"$repoTC/package.json"
make_claude_stub "$repoTC/claude"; make_gh_stub "$repoTC/gh"
export GH_LOG="$repoTC/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTC/existing"; : >"$GH_EXISTING"
( cd "$repoTC" && LCARS_CLAUDE_BIN="$repoTC/claude" LCARS_GH_BIN="$repoTC/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "2b. detects 'npm test' from a package.json test script" \
  "grep -q '\"testCommand\": *\"npm test\"' '$repoTC/.git/lcars/config.json'"

# an explicit LCARS_TEST_CMD overrides detection
repoTCe="$(new_repo)"
make_claude_stub "$repoTCe/claude"; make_gh_stub "$repoTCe/gh"
export GH_LOG="$repoTCe/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTCe/existing"; : >"$GH_EXISTING"
( cd "$repoTCe" && LCARS_TEST_CMD='make check' LCARS_CLAUDE_BIN="$repoTCe/claude" LCARS_GH_BIN="$repoTCe/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "2b. an explicit LCARS_TEST_CMD is recorded in config" \
  "grep -q '\"testCommand\": *\"make check\"' '$repoTCe/.git/lcars/config.json'"

# --- Behaviour 3: detects CONTEXT.md --------------------------------------
repo="$(new_repo)"
printf '# Context\n' >"$repo/CONTEXT.md"
make_claude_stub "$repo/claude"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
(
  cd "$repo"
  LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1
)
check "3. records CONTEXT.md in config"   "grep -q 'CONTEXT.md' '$repo/.git/lcars/config.json'"

# repo WITHOUT context records null
repo2="$(new_repo)"
make_claude_stub "$repo2/claude"
make_gh_stub "$repo2/gh"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo2/existing"; : >"$GH_EXISTING"
(
  cd "$repo2"
  LCARS_CLAUDE_BIN="$repo2/claude" LCARS_GH_BIN="$repo2/gh" bash "$SCRIPT" >out.txt 2>&1
)
check "3. contextFile is null when absent" "grep -q '\"contextFile\": *null' '$repo2/.git/lcars/config.json'"

# --- Behaviour 4: missing Claude CLI -> clear error, non-zero exit --------
repo="$(new_repo)"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo/existing"; : >"$GH_EXISTING"
rc=0
(
  cd "$repo"
  LCARS_CLAUDE_BIN="$repo/definitely-not-claude" LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1
) || rc=$?
check "4. exits non-zero when claude missing"   "[ '$rc' -ne 0 ]"
check "4. prints a clear error about claude"    "grep -qi 'claude' '$repo/out.txt' && grep -qi 'not found\\|not available\\|install' '$repo/out.txt'"

# --- Behaviour 5: gh label create per label, skips existing ----------------
repo="$(new_repo)"
make_claude_stub "$repo/claude"
make_gh_stub "$repo/gh"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
# Pretend two labels already exist; they should be skipped.
export GH_EXISTING="$repo/existing"
printf 'lcars:align\nlcars:bug\n' >"$GH_EXISTING"
(
  cd "$repo"
  LCARS_CLAUDE_BIN="$repo/claude" LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1
)
created_count="$(grep -c 'label create' "$GH_LOG")"
check "5. creates the 12 missing labels"        "[ '$created_count' -eq 12 ]"
check "5. skips pre-existing lcars:align"        "! grep -q 'label create lcars:align' '$GH_LOG'"
check "5. skips pre-existing lcars:bug"          "! grep -q 'label create lcars:bug' '$GH_LOG'"
check "5. creates lcars:done with stage colour"  "grep -q 'label create lcars:done .*FF9900' '$GH_LOG'"
check "5. creates lcars:feature with type colour" "grep -q 'label create lcars:feature .*4499FF' '$GH_LOG'"
check "5. creates lcars:paused with status colour" "grep -q 'label create lcars:paused .*FF3344' '$GH_LOG'"
check "5. creates lcars:linked with rel colour"  "grep -q 'label create lcars:linked .*9977FF' '$GH_LOG'"

# all-missing repo creates all 14
repo3="$(new_repo)"
make_claude_stub "$repo3/claude"
make_gh_stub "$repo3/gh"
export GH_LOG="$repo3/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repo3/existing"; : >"$GH_EXISTING"
(
  cd "$repo3"
  LCARS_CLAUDE_BIN="$repo3/claude" LCARS_GH_BIN="$repo3/gh" bash "$SCRIPT" >out.txt 2>&1
)
all_count="$(grep -c 'label create' "$repo3/gh.log")"
check "5. creates all 14 labels when none exist" "[ '$all_count' -eq 14 ]"

# --- Behaviour 6: readiness summary ---------------------------------------
check "6. summary: .git/lcars created"   "grep -q '.git/lcars/ created' '$repo3/out.txt'"
check "6. summary: config.json written"  "grep -q 'config.json written' '$repo3/out.txt'"
check "6. summary: Claude CLI verified"   "grep -qi 'Claude CLI verified' '$repo3/out.txt'"
check "6. summary: labels created line"    "grep -q '14 labels' '$repo3/out.txt'"
check "6. summary: LCARS ready line"       "grep -q 'LCARS ready' '$repo3/out.txt'"
check "6. summary: points to lcars file"   "grep -q 'lcars file' '$repo3/out.txt'"

# --- Session 30: scratch globs land in .git/info/exclude, .gitignore intact -
# init owns ignoring the harness's scratch via .git/info/exclude (inside .git/,
# like .git/lcars/) — NEVER the target repo's tracked .gitignore (vision forbids
# editing it). The append is idempotent and lists the CLI/host-agnostic set.
printf '*.log\n' > "$repo3/.gitignore"   # captain's tracked .gitignore
gi3_before="$( cat "$repo3/.gitignore" )"
exclude3="$repo3/.git/info/exclude"
check "S30 init: .git/info/exclude lists .lcars-* scratch glob" \
  "[ -f '$exclude3' ] && grep -qxF '.lcars-*' '$exclude3'"
check "S30 init: .git/info/exclude lists the .claude/ CLI scratch glob" \
  "grep -qxF '.claude/' '$exclude3'"
check "S30 init: .git/info/exclude lists the harness runner glob (.lcars-run-*)" \
  "grep -qxF '.lcars-run-*' '$exclude3'"
check "S30 init: the tracked .gitignore is UNTOUCHED" \
  "[ \"\$( cat '$repo3/.gitignore' )\" = '$gi3_before' ]"

# --- idempotency: second run preserves created timestamp ------------------
first_created="$(grep '"created"' "$repo3/.git/lcars/config.json")"
sleep 1
(
  cd "$repo3"
  LCARS_CLAUDE_BIN="$repo3/claude" LCARS_GH_BIN="$repo3/gh" bash "$SCRIPT" >out2.txt 2>&1
)
second_created="$(grep '"created"' "$repo3/.git/lcars/config.json")"
check "idempotent: created timestamp preserved" "[ '$first_created' = '$second_created' ]"
check "S30 init: exclude append is idempotent (no duplicate .lcars-* lines)" \
  "[ \"\$( grep -c '^\.lcars-\*\$' '$repo3/.git/info/exclude' )\" = '1' ]"

# ==========================================================================
echo
printf 'lcars init: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
