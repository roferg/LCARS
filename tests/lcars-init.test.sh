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

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# its first match and closes the pipe; a still-writing upstream producer then
# takes SIGPIPE and exits non-zero, and under `set -o pipefail` that flips a
# genuine match into a phantom assertion failure (timing/load-sensitive — it bit
# the worker-prompt assertions only under the full back-to-back suite). Draining
# first removes the race; exit status and output are otherwise identical to grep.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

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
# BUG-007: the detected testCommand MUST honour $LCARS_TESTS_DIR so the red gate
# can scope it to the QUARANTINED tests (not the repo's existing suite). The
# detected default therefore references $LCARS_TESTS_DIR.
repoTC="$(new_repo)"
printf '{\n  "scripts": { "test": "jest" }\n}\n' >"$repoTC/package.json"
make_claude_stub "$repoTC/claude"; make_gh_stub "$repoTC/gh"
export GH_LOG="$repoTC/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTC/existing"; : >"$GH_EXISTING"
( cd "$repoTC" && LCARS_CLAUDE_BIN="$repoTC/claude" LCARS_GH_BIN="$repoTC/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "2b. detects an npm test command from a package.json test script" \
  "grep -q '\"testCommand\":.*npm test' '$repoTC/.git/lcars/config.json'"
check "2b. the detected testCommand HONOURS \$LCARS_TESTS_DIR (red-gate-scopable)" \
  "grep -q 'LCARS_TESTS_DIR' '$repoTC/.git/lcars/config.json'"

# pytest default also honours $LCARS_TESTS_DIR
repoTCp="$(new_repo)"
printf '[tool.pytest]\n' >"$repoTCp/pyproject.toml"
make_claude_stub "$repoTCp/claude"; make_gh_stub "$repoTCp/gh"
export GH_LOG="$repoTCp/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTCp/existing"; : >"$GH_EXISTING"
( cd "$repoTCp" && LCARS_CLAUDE_BIN="$repoTCp/claude" LCARS_GH_BIN="$repoTCp/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "2b. the pytest default honours \$LCARS_TESTS_DIR" \
  "grep -q '\"testCommand\":.*pytest' '$repoTCp/.git/lcars/config.json' && grep -q 'LCARS_TESTS_DIR' '$repoTCp/.git/lcars/config.json'"

# an explicit LCARS_TEST_CMD overrides detection. If it does NOT mention
# $LCARS_TESTS_DIR, init records it (the captain chose it) but FLAGS it LOUD so a
# dir-ignoring command never silently becomes a green-on-nothing red gate.
repoTCe="$(new_repo)"
make_claude_stub "$repoTCe/claude"; make_gh_stub "$repoTCe/gh"
export GH_LOG="$repoTCe/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTCe/existing"; : >"$GH_EXISTING"
( cd "$repoTCe" && LCARS_TEST_CMD='make check' LCARS_CLAUDE_BIN="$repoTCe/claude" LCARS_GH_BIN="$repoTCe/gh" bash "$SCRIPT" >outTCe.txt 2>&1 )
check "2b. an explicit LCARS_TEST_CMD is recorded in config" \
  "grep -q '\"testCommand\": *\"make check\"' '$repoTCe/.git/lcars/config.json'"
check "2b. a testCommand that IGNORES \$LCARS_TESTS_DIR is FLAGGED LOUD (not silent)" \
  "grep -qiE 'LCARS_TESTS_DIR|red gate|quarantin' '$repoTCe/outTCe.txt'"

# an explicit LCARS_TEST_CMD that DOES honour $LCARS_TESTS_DIR is NOT flagged
repoTCh="$(new_repo)"
make_claude_stub "$repoTCh/claude"; make_gh_stub "$repoTCh/gh"
export GH_LOG="$repoTCh/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTCh/existing"; : >"$GH_EXISTING"
( cd "$repoTCh" && LCARS_TEST_CMD='pytest ${LCARS_TESTS_DIR:-.}' LCARS_CLAUDE_BIN="$repoTCh/claude" LCARS_GH_BIN="$repoTCh/gh" bash "$SCRIPT" >outTCh.txt 2>&1 )
check "2b. a \$LCARS_TESTS_DIR-honouring explicit command is NOT flagged" \
  "! grep -qiE 'does not.*honour|ignores .LCARS_TESTS_DIR|will run the repo' '$repoTCh/outTCh.txt'"

# --- Behaviour 2c: a bash tests/run.sh runner is detected (BUG-009) ---------
# A copy of LCARS has no npm/pytest/cargo/go/Makefile-test, only an executable
# bash test runner at tests/run.sh. init must recommend a testCommand that ALREADY
# honours $LCARS_TESTS_DIR so the red gate is satisfied with no hand-edit.
repoTCb="$(new_repo)"
mkdir -p "$repoTCb/tests"
printf '#!/usr/bin/env bash\necho runner\n' >"$repoTCb/tests/run.sh"
make_claude_stub "$repoTCb/claude"; make_gh_stub "$repoTCb/gh"
export GH_LOG="$repoTCb/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoTCb/existing"; : >"$GH_EXISTING"
( cd "$repoTCb" && LCARS_CLAUDE_BIN="$repoTCb/claude" LCARS_GH_BIN="$repoTCb/gh" bash "$SCRIPT" >outTCb.txt 2>&1 )
check "2c. detects a bash tests/run.sh runner as the testCommand" \
  "grep -q '\"testCommand\":.*tests/run.sh' '$repoTCb/.git/lcars/config.json'"
check "2c. the bash-runner default HONOURS \$LCARS_TESTS_DIR (red-gate-scopable)" \
  "grep -q 'LCARS_TESTS_DIR' '$repoTCb/.git/lcars/config.json'"
check "2c. the bash-runner default is NOT flagged as dir-ignoring" \
  "! grep -qiE 'does not.*honour|ignores .LCARS_TESTS_DIR|will run the repo' '$repoTCb/outTCb.txt'"

# BUG (S47 regression): init must write VALID JSON. The bash-runner default
# embeds inner double-quotes (`"${LCARS_TESTS_DIR:-tests}"`); if init does not
# JSON-escape them, config.json becomes invalid and the jq-free reader truncates
# the value to `bash tests/run.sh `, killing the red-gate command on arrival.
check "2c. config.json is VALID JSON after a bash-runner init" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repoTCb/.git/lcars/config.json'"
# The REAL regression guard: read the value back through lcars_config_get (same
# jq-free reader the Implement red gate uses) — it must return the FULL command
# INCLUDING the inner quotes, not a truncated `bash tests/run.sh `.
check "2c. testCommand reads back as the FULL bash-runner command (incl. inner quotes)" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$repoTCb/.git/lcars/config.json' testCommand )\" = 'bash tests/run.sh \"\${LCARS_TESTS_DIR:-tests}\"' ]"
check "2c. the read-back testCommand is gate-scopable (references \$LCARS_TESTS_DIR)" \
  "printf '%s' \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$repoTCb/.git/lcars/config.json' testCommand )\" | qgrep -q 'LCARS_TESTS_DIR'"

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
check "5. creates the 14 missing labels"        "[ '$created_count' -eq 14 ]"
check "5. skips pre-existing lcars:align"        "! grep -q 'label create lcars:align' '$GH_LOG'"
check "5. skips pre-existing lcars:bug"          "! grep -q 'label create lcars:bug' '$GH_LOG'"
check "5. creates lcars:done with stage colour"  "grep -q 'label create lcars:done .*FF9900' '$GH_LOG'"
check "5. creates lcars:feature with type colour" "grep -q 'label create lcars:feature .*4499FF' '$GH_LOG'"
check "5. creates lcars:paused with status colour" "grep -q 'label create lcars:paused .*FF3344' '$GH_LOG'"
check "5. creates lcars:linked with rel colour"  "grep -q 'label create lcars:linked .*9977FF' '$GH_LOG'"
check "5. creates lcars:mission role label"      "grep -q 'label create lcars:mission .*[0-9A-Fa-f]' '$GH_LOG'"
check "5. creates lcars:ticket role label"       "grep -q 'label create lcars:ticket .*[0-9A-Fa-f]' '$GH_LOG'"

# all-missing repo creates all 16
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
check "5. creates all 16 labels when none exist" "[ '$all_count' -eq 16 ]"

# --- Behaviour 6: readiness summary ---------------------------------------
check "6. summary: .git/lcars created"   "grep -q '.git/lcars/ created' '$repo3/out.txt'"
check "6. summary: config.json written"  "grep -q 'config.json written' '$repo3/out.txt'"
check "6. summary: Claude CLI verified"   "grep -qi 'Claude CLI verified' '$repo3/out.txt'"
check "6. summary: labels created line"    "grep -q '16 labels' '$repo3/out.txt'"
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

# --- Session 43: config write MERGES (no clobber of captain's customizations) -
# Re-running init must PRESERVE keys the captain customized in config.json and
# only fill in MISSING keys. This fixes the clobber where init rewrote the whole
# file from detected defaults on every run.
repoM="$(new_repo)"
make_claude_stub "$repoM/claude"; make_gh_stub "$repoM/gh"
export GH_LOG="$repoM/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoM/existing"; : >"$GH_EXISTING"
# First init creates a default config.
( cd "$repoM" && LCARS_CLAUDE_BIN="$repoM/claude" LCARS_GH_BIN="$repoM/gh" bash "$SCRIPT" >/dev/null 2>&1 )
# Captain hand-edits config: a custom test command, model, and budget.
cfgM="$repoM/.git/lcars/config.json"
cat >"$cfgM" <<'JSON'
{
  "model": "claude-opus-custom",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "my-bespoke-runner ${LCARS_TESTS_DIR:-.}",
  "comprehensionBudget": 4242,
  "created": "2020-01-01T00:00:00Z"
}
JSON
# Re-run init.
( cd "$repoM" && LCARS_CLAUDE_BIN="$repoM/claude" LCARS_GH_BIN="$repoM/gh" bash "$SCRIPT" >/dev/null 2>&1 )
check "S43 init: custom testCommand survives re-run (no clobber)" \
  "grep -q 'my-bespoke-runner' '$cfgM'"
check "S43 init: custom model survives re-run" \
  "grep -q '\"model\": *\"claude-opus-custom\"' '$cfgM'"
check "S43 init: custom comprehensionBudget survives re-run" \
  "grep -q '\"comprehensionBudget\": *4242' '$cfgM'"
check "S43 init: custom created survives re-run" \
  "grep -q '\"created\": *\"2020-01-01T00:00:00Z\"' '$cfgM'"

# A config MISSING a key gets it filled in on re-run, existing values untouched.
repoF="$(new_repo)"
make_claude_stub "$repoF/claude"; make_gh_stub "$repoF/gh"
export GH_LOG="$repoF/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoF/existing"; : >"$GH_EXISTING"
( cd "$repoF" && LCARS_CLAUDE_BIN="$repoF/claude" LCARS_GH_BIN="$repoF/gh" bash "$SCRIPT" >/dev/null 2>&1 )
cfgF="$repoF/.git/lcars/config.json"
# Captain's config has a custom model but is MISSING comprehensionBudget.
cat >"$cfgF" <<'JSON'
{
  "model": "captain-model",
  "projectName": "p",
  "contextFile": null,
  "testCommand": null,
  "created": "2021-05-05T00:00:00Z"
}
JSON
( cd "$repoF" && LCARS_CLAUDE_BIN="$repoF/claude" LCARS_GH_BIN="$repoF/gh" bash "$SCRIPT" >/dev/null 2>&1 )
check "S43 init: a MISSING key (comprehensionBudget) is filled with its default" \
  "grep -q '\"comprehensionBudget\": *1200' '$cfgF'"
check "S43 init: the present custom model is preserved while filling a missing key" \
  "grep -q '\"model\": *\"captain-model\"' '$cfgF'"

# --- Session 43 follow-up: the readiness banner reflects the PERSISTED config -
# Because init is now config-PRESERVING, the summary line on a re-run must report
# the values that ACTUALLY survived in config.json (the captain's customizations),
# not the freshly-detected defaults. Otherwise the banner misleads the captain
# into thinking their customization was reset when it actually survived.
repoB="$(new_repo)"
make_claude_stub "$repoB/claude"; make_gh_stub "$repoB/gh"
export GH_LOG="$repoB/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoB/existing"; : >"$GH_EXISTING"
( cd "$repoB" && LCARS_CLAUDE_BIN="$repoB/claude" LCARS_GH_BIN="$repoB/gh" bash "$SCRIPT" >/dev/null 2>&1 )
cfgB="$repoB/.git/lcars/config.json"
cat >"$cfgB" <<'JSON'
{
  "model": "claude-opus-custom",
  "projectName": "myproj",
  "contextFile": null,
  "testCommand": "my-custom-test-cmd ${LCARS_TESTS_DIR:-.}",
  "comprehensionBudget": 1200,
  "created": "2020-01-01T00:00:00Z"
}
JSON
( cd "$repoB" && LCARS_CLAUDE_BIN="$repoB/claude" LCARS_GH_BIN="$repoB/gh" bash "$SCRIPT" >outB.txt 2>&1 )
check "S43 init: summary banner reflects the PERSISTED custom model" \
  "grep -q 'config.json written' '$repoB/outB.txt' && grep -q 'model: claude-opus-custom' '$repoB/outB.txt'"
check "S43 init: summary banner reflects the PERSISTED custom testCommand" \
  "grep -q 'my-custom-test-cmd' '$repoB/outB.txt'"
check "S43 init: summary banner does NOT show the detected default model on a re-run" \
  "! grep -q 'model: claude-sonnet' '$repoB/outB.txt'"

# --- Session 82: worktreeSetupCommand detection (gate-worktree-deps) --------
# init seeds a default worktreeSetupCommand per ecosystem so the S81 provisioning
# seam works in ANY repo without hand-editing config. The default REUSES the main
# checkout's installed deps (symlinks its node_modules) with an OFFLINE-install
# fallback. The emitted string runs under `bash -c` in the worktree, so its
# $MAIN / $(...) must survive into config UN-expanded (escaped, valid JSON).

# pnpm repo: git-common-dir resolution + node_modules symlink + pnpm offline fallback
repoWTp="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoWTp/package.json"
printf 'lockfileVersion: 9\n' >"$repoWTp/pnpm-lock.yaml"
make_claude_stub "$repoWTp/claude"; make_gh_stub "$repoWTp/gh"
export GH_LOG="$repoWTp/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoWTp/existing"; : >"$GH_EXISTING"
( cd "$repoWTp" && LCARS_CLAUDE_BIN="$repoWTp/claude" LCARS_GH_BIN="$repoWTp/gh" bash "$SCRIPT" >outWTp.txt 2>&1 )
cfgWTp="$repoWTp/.git/lcars/config.json"
check "S82 init: config has worktreeSetupCommand key" \
  "grep -q '\"worktreeSetupCommand\"' '$cfgWTp'"
check "S82 init (pnpm): default resolves the main checkout via git-common-dir" \
  "grep -q 'git rev-parse' '$cfgWTp' && grep -q 'git-common-dir' '$cfgWTp'"
check "S82 init (pnpm): default symlinks node_modules" \
  "grep -q 'ln -snf' '$cfgWTp' && grep -q 'node_modules' '$cfgWTp'"
check "S82 init (pnpm): default names a pnpm offline-install fallback" \
  "grep -q 'pnpm install' '$cfgWTp' && grep -q 'prefer-offline' '$cfgWTp'"
check "S82 init (pnpm): config.json is VALID JSON after the worktree default" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgWTp'"
# Read back through the SAME jq-free reader the provisioner uses: the value must
# be the FULL command (terminating `fi` survives), not truncated at an inner quote.
check "S82 init (pnpm): worktreeSetupCommand reads back un-truncated (ends in 'fi')" \
  "printf '%s' \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgWTp' worktreeSetupCommand )\" | qgrep -q '; fi\$'"

# npm repo (package-lock.json): the fallback is `npm ci`
repoWTn="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoWTn/package.json"
: >"$repoWTn/package-lock.json"
make_claude_stub "$repoWTn/claude"; make_gh_stub "$repoWTn/gh"
export GH_LOG="$repoWTn/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoWTn/existing"; : >"$GH_EXISTING"
( cd "$repoWTn" && LCARS_CLAUDE_BIN="$repoWTn/claude" LCARS_GH_BIN="$repoWTn/gh" bash "$SCRIPT" >outWTn.txt 2>&1 )
cfgWTn="$repoWTn/.git/lcars/config.json"
check "S82 init (npm): default names 'npm ci' as the install fallback" \
  "grep -q 'npm ci' '$cfgWTn'"
check "S82 init (npm): default still symlinks node_modules first" \
  "grep -q 'ln -snf' '$cfgWTn'"
check "S82 init (npm): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgWTn'"

# pure-bash repo (only tests/run.sh): no installed runner to provision -> null
repoWTb="$(new_repo)"
mkdir -p "$repoWTb/tests"
printf '#!/usr/bin/env bash\necho runner\n' >"$repoWTb/tests/run.sh"
make_claude_stub "$repoWTb/claude"; make_gh_stub "$repoWTb/gh"
export GH_LOG="$repoWTb/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoWTb/existing"; : >"$GH_EXISTING"
( cd "$repoWTb" && LCARS_CLAUDE_BIN="$repoWTb/claude" LCARS_GH_BIN="$repoWTb/gh" bash "$SCRIPT" >outWTb.txt 2>&1 )
cfgWTb="$repoWTb/.git/lcars/config.json"
check "S82 init (bash): worktreeSetupCommand is null in a pure-bash repo (no provisioning)" \
  "grep -q '\"worktreeSetupCommand\": *null' '$cfgWTb'"

# When the persisted testCommand is genuinely null, the banner still shows 'none'.
repoBn="$(new_repo)"
make_claude_stub "$repoBn/claude"; make_gh_stub "$repoBn/gh"
export GH_LOG="$repoBn/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoBn/existing"; : >"$GH_EXISTING"
( cd "$repoBn" && LCARS_CLAUDE_BIN="$repoBn/claude" LCARS_GH_BIN="$repoBn/gh" bash "$SCRIPT" >outBn.txt 2>&1 )
check "S43 init: a null persisted testCommand renders as 'none' in the banner" \
  "grep -q 'tests: none' '$repoBn/outBn.txt'"

# --- Session 85: monorepo testCommand + local-dep runner warning ------------
# Two changes that stop init from emitting a testCommand that NEEDS provisioning
# while saying nothing: (1) monorepo-aware detection avoids a blind `npm test`
# fan-out across every package, and (2) a loud warning when the runner is a LOCAL
# dependency (vitest/jest/mocha/pytest) but worktreeSetupCommand is null — the
# runner won't exist in the gate worktree unless provisioning is wired.

# (1) A monorepo (pnpm-workspace.yaml / a "workspaces" field) must NOT emit a bare
#     `npm test` / `pnpm -r test` fan-out — that can't be scoped to the touched
#     package's quarantined tests. It scopes to the local runner while still
#     honouring $LCARS_TESTS_DIR so the red gate stays satisfiable.
repoMono="$(new_repo)"
printf '{ "workspaces": ["packages/*"], "scripts": { "test": "vitest run" } }\n' >"$repoMono/package.json"
printf 'packages:\n  - "packages/*"\n' >"$repoMono/pnpm-workspace.yaml"
make_claude_stub "$repoMono/claude"; make_gh_stub "$repoMono/gh"
export GH_LOG="$repoMono/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoMono/existing"; : >"$GH_EXISTING"
( cd "$repoMono" && LCARS_CLAUDE_BIN="$repoMono/claude" LCARS_GH_BIN="$repoMono/gh" bash "$SCRIPT" >outMono.txt 2>&1 )
cfgMono="$repoMono/.git/lcars/config.json"
check "S85 init (monorepo): testCommand is NOT a bare 'npm test' fan-out" \
  "! grep -qE '\"testCommand\": *\"npm test' '$cfgMono'"
check "S85 init (monorepo): testCommand is NOT a 'pnpm -r' fan-out" \
  "! grep -q 'pnpm -r' '$cfgMono'"
check "S85 init (monorepo): testCommand is scoped to the local runner (vitest)" \
  "grep -q 'vitest' '$cfgMono'"
check "S85 init (monorepo): testCommand still honours \$LCARS_TESTS_DIR (red-gate-scopable)" \
  "grep -q 'LCARS_TESTS_DIR' '$cfgMono'"
check "S85 init (monorepo): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgMono'"

# (2) A single-package npm repo is UNCHANGED from today (no regression): the bare
#     `npm test -- ${LCARS_TESTS_DIR:-}` default is preserved verbatim.
repoSingle="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoSingle/package.json"
printf '{}\n' >"$repoSingle/package-lock.json"
make_claude_stub "$repoSingle/claude"; make_gh_stub "$repoSingle/gh"
export GH_LOG="$repoSingle/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoSingle/existing"; : >"$GH_EXISTING"
( cd "$repoSingle" && LCARS_CLAUDE_BIN="$repoSingle/claude" LCARS_GH_BIN="$repoSingle/gh" bash "$SCRIPT" >outSingle.txt 2>&1 )
cfgSingle="$repoSingle/.git/lcars/config.json"
check "S85 init (single-package npm): testCommand is the UNCHANGED 'npm test --' default" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgSingle' testCommand )\" = 'npm test -- \${LCARS_TESTS_DIR:-}' ]"

# (3) A local-dep runner (pytest, resolvable only from a venv) with a NULL
#     worktreeSetupCommand (Python has no auto-provision default) warns LOUD:
#     the runner won't exist in the gate worktree unless provisioning is wired.
repoLD="$(new_repo)"
printf '[tool.pytest]\n' >"$repoLD/pyproject.toml"
make_claude_stub "$repoLD/claude"; make_gh_stub "$repoLD/gh"
export GH_LOG="$repoLD/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoLD/existing"; : >"$GH_EXISTING"
( cd "$repoLD" && LCARS_CLAUDE_BIN="$repoLD/claude" LCARS_GH_BIN="$repoLD/gh" bash "$SCRIPT" >outLD.txt 2>&1 )
cfgLD="$repoLD/.git/lcars/config.json"
check "S85 init: the local-dep case really has a NULL worktreeSetupCommand" \
  "grep -q '\"worktreeSetupCommand\": *null' '$cfgLD'"
check "S85 init: a local-dep runner + NULL worktreeSetupCommand warns LOUD on stderr" \
  "grep -qi 'local dependency' '$repoLD/outLD.txt' && grep -q 'worktreeSetupCommand' '$repoLD/outLD.txt'"

# (4) When worktreeSetupCommand IS set (the normal S82 JS path), NO nag fires —
#     the gap is already handled, so init must not nag about it.
repoNoNag="$(new_repo)"
printf '{ "scripts": { "test": "vitest run" } }\n' >"$repoNoNag/package.json"
printf '{}\n' >"$repoNoNag/package-lock.json"
make_claude_stub "$repoNoNag/claude"; make_gh_stub "$repoNoNag/gh"
export GH_LOG="$repoNoNag/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoNoNag/existing"; : >"$GH_EXISTING"
( cd "$repoNoNag" && LCARS_CLAUDE_BIN="$repoNoNag/claude" LCARS_GH_BIN="$repoNoNag/gh" bash "$SCRIPT" >outNoNag.txt 2>&1 )
cfgNoNag="$repoNoNag/.git/lcars/config.json"
check "S85 init: the no-nag case really has a worktreeSetupCommand set" \
  "! grep -q '\"worktreeSetupCommand\": *null' '$cfgNoNag'"
check "S85 init: a local-dep runner WITH worktreeSetupCommand does NOT warn (no nag)" \
  "! grep -qi 'local dependency' '$repoNoNag/outNoNag.txt'"

# ==========================================================================
echo
printf 'lcars init: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
