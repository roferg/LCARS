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
  LCARS_CLAUDE_BIN="$repo/definitely-not-claude" \
  LCARS_COPILOT_BIN="$repo/definitely-not-copilot" \
  LCARS_GH_BIN="$repo/gh" bash "$SCRIPT" >out.txt 2>&1
) || rc=$?
check "4. exits non-zero when NO engine is installed"   "[ '$rc' -ne 0 ]"
check "4. prints a clear error about claude"    "grep -qi 'claude' '$repo/out.txt' && grep -qi 'not found\\|not available\\|install' '$repo/out.txt'"
check "4. and names copilot too (both engines are offered)" \
  "grep -qi 'copilot' '$repo/out.txt'"

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
# S111: the symlink FIND must PRUNE .git — LCARS itself parks worktrees with
# node_modules under .git/lcars/ (launch worktrees), and mirroring a .git/ path
# inside a linked worktree fails ('.git' is a FILE there): caught live when a
# launched mission's node_modules broke every later gate's provisioning.
check "S111 init (pnpm): the node_modules find prunes the .git dir" \
  "python3 -c \"import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if '.git\\\" -prune -o' in c['worktreeSetupCommand'] else 1)\" '$cfgWTp'"

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
#     `npm test -- <scope>` default is preserved verbatim (S148 quoted its
#     scope; the invocation is otherwise byte-identical).
repoSingle="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoSingle/package.json"
printf '{}\n' >"$repoSingle/package-lock.json"
make_claude_stub "$repoSingle/claude"; make_gh_stub "$repoSingle/gh"
export GH_LOG="$repoSingle/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoSingle/existing"; : >"$GH_EXISTING"
( cd "$repoSingle" && LCARS_CLAUDE_BIN="$repoSingle/claude" LCARS_GH_BIN="$repoSingle/gh" bash "$SCRIPT" >outSingle.txt 2>&1 )
cfgSingle="$repoSingle/.git/lcars/config.json"
S85_NPM_WANT='npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
S85_NPM_GOT="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$cfgSingle" testCommand )"
check "S85 init (single-package npm): testCommand is the UNCHANGED 'npm test --' default (S148: scope quoted)" \
  '[ "$S85_NPM_GOT" = "$S85_NPM_WANT" ]'

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

# --- Session 87: vitest gate staging — relativizing testCommand + __lcarsq__ --
# The Implement gates stage a sub-package's quarantine INSIDE the package and run
# vitest FROM there; vitest's positional filter is matched RELATIVE to that cwd but
# $LCARS_TESTS_DIR is exported ABSOLUTE. So init must emit a RELATIVIZING vitest
# command (strip a leading "$PWD/") for BOTH single-package and monorepo vitest, the
# workspace fan-out fallback must DETECT the sub-package runner, and __lcarsq__ must
# be ignored via .git/info/exclude.
RELCMD='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'

# (1) A monorepo whose ROOT "test" script does NOT name the runner (a bare
#     `pnpm -r test` fan-out) must DETECT vitest from a sub-package and emit the
#     RELATIVIZING command, never a fan-out.
repoMR="$(new_repo)"
printf '{ "scripts": { "test": "pnpm -r test" } }\n' >"$repoMR/package.json"
printf 'packages:\n  - "packages/*"\n' >"$repoMR/pnpm-workspace.yaml"
printf 'lockfileVersion: 9\n' >"$repoMR/pnpm-lock.yaml"
mkdir -p "$repoMR/packages/core"
printf '{ "name": "@x/core", "devDependencies": { "vitest": "^2" } }\n' >"$repoMR/packages/core/package.json"
make_claude_stub "$repoMR/claude"; make_gh_stub "$repoMR/gh"
export GH_LOG="$repoMR/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoMR/existing"; : >"$GH_EXISTING"
( cd "$repoMR" && LCARS_CLAUDE_BIN="$repoMR/claude" LCARS_GH_BIN="$repoMR/gh" bash "$SCRIPT" >outMR.txt 2>&1 )
cfgMR="$repoMR/.git/lcars/config.json"
check "S87 init (monorepo fan-out): NOT a 'pnpm -r' fan-out testCommand" \
  "! grep -q 'pnpm -r' '$cfgMR'"
check "S87 init (monorepo fan-out): NOT a bare 'npm test' fan-out" \
  "! grep -qE '\"testCommand\": *\"npm test' '$cfgMR'"
check "S87 init (monorepo fan-out): detects vitest from the sub-package and emits the RELATIVIZING command" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgMR' testCommand )\" = '$RELCMD' ]"
check "S87 init (monorepo fan-out): config.json is VALID JSON after the \$/{/}/#/\" round-trip" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgMR'"

# (2) A single-package VITEST repo (root "test" names vitest) now emits the
#     RELATIVIZING command too (same abs-positional bug), reading back intact.
repoSV="$(new_repo)"
printf '{ "scripts": { "test": "vitest run" } }\n' >"$repoSV/package.json"
printf '{}\n' >"$repoSV/package-lock.json"
make_claude_stub "$repoSV/claude"; make_gh_stub "$repoSV/gh"
export GH_LOG="$repoSV/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoSV/existing"; : >"$GH_EXISTING"
( cd "$repoSV" && LCARS_CLAUDE_BIN="$repoSV/claude" LCARS_GH_BIN="$repoSV/gh" bash "$SCRIPT" >outSV.txt 2>&1 )
cfgSV="$repoSV/.git/lcars/config.json"
check "S87 init (single-package vitest): testCommand is the RELATIVIZING form" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgSV' testCommand )\" = '$RELCMD' ]"
check "S87 init (single-package vitest): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgSV'"

# (3) A monorepo whose ROOT "test" names vitest directly — still RELATIVIZING.
repoMV="$(new_repo)"
printf '{ "workspaces": ["packages/*"], "scripts": { "test": "vitest run" } }\n' >"$repoMV/package.json"
printf 'packages:\n  - "packages/*"\n' >"$repoMV/pnpm-workspace.yaml"
make_claude_stub "$repoMV/claude"; make_gh_stub "$repoMV/gh"
export GH_LOG="$repoMV/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoMV/existing"; : >"$GH_EXISTING"
( cd "$repoMV" && LCARS_CLAUDE_BIN="$repoMV/claude" LCARS_GH_BIN="$repoMV/gh" bash "$SCRIPT" >outMV.txt 2>&1 )
cfgMV="$repoMV/.git/lcars/config.json"
check "S87 init (monorepo vitest script): testCommand is the RELATIVIZING form" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgMV' testCommand )\" = '$RELCMD' ]"

# (4) pytest is UNCHANGED (no regression) — non-vitest ecosystems keep their default.
repoPY="$(new_repo)"
printf '[tool.pytest]\n' >"$repoPY/pyproject.toml"
make_claude_stub "$repoPY/claude"; make_gh_stub "$repoPY/gh"
export GH_LOG="$repoPY/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPY/existing"; : >"$GH_EXISTING"
( cd "$repoPY" && LCARS_CLAUDE_BIN="$repoPY/claude" LCARS_GH_BIN="$repoPY/gh" bash "$SCRIPT" >outPY.txt 2>&1 )
cfgPY="$repoPY/.git/lcars/config.json"
S87_PY_WANT='pytest "${LCARS_TESTS_DIR:-.}"'
S87_PY_GOT="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$cfgPY" testCommand )"
check "S87 init (pytest unchanged): testCommand is the pytest default (S148: scope quoted)" \
  '[ "$S87_PY_GOT" = "$S87_PY_WANT" ]'

# (5) .git/info/exclude lists the __lcarsq__ globs so a gate's in-package
#     quarantine can never be git-added into a ticket commit.
check "S87 init: .git/info/exclude ignores __lcarsq__ (dir form)" \
  "grep -qxF '__lcarsq__/' '$repoPY/.git/info/exclude'"
check "S87 init: .git/info/exclude ignores nested */__lcarsq__" \
  "grep -qxF '*/__lcarsq__' '$repoPY/.git/info/exclude'"

# --- Session 105: stack detection (multi-stack breadth) ---------------------
# init now sniffs the repo's top-level markers into a `stack` id (the S104
# classifier key) and, when SEVERAL stacks are present, refuses to guess a
# testCommand and warns instead of silently seeding one by precedence.

# helper: run init in a fresh repo with the given marker files pre-created.
# usage: s105_init <repo-var-name> ; caller pre-populates $repo first is awkward,
# so we inline per-case below following the existing fixture idiom.

# (1) rust: Cargo.toml → stack rust + testCommand "cargo test"
repoRust="$(new_repo)"
printf '[package]\nname = "x"\n' >"$repoRust/Cargo.toml"
make_claude_stub "$repoRust/claude"; make_gh_stub "$repoRust/gh"
export GH_LOG="$repoRust/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoRust/existing"; : >"$GH_EXISTING"
( cd "$repoRust" && LCARS_CLAUDE_BIN="$repoRust/claude" LCARS_GH_BIN="$repoRust/gh" bash "$SCRIPT" >outRust.txt 2>&1 )
cfgRust="$repoRust/.git/lcars/config.json"
check "S105 init (rust): stack is 'rust'" \
  "grep -q '\"stack\": *\"rust\"' '$cfgRust'"
check "S105 init (rust): testCommand is the byte-equivalent 'cargo test'" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgRust' testCommand )\" = 'cargo test' ]"
check "S105 init (rust): worktreeSetupCommand is null (compiles deps in-tree)" \
  "grep -q '\"worktreeSetupCommand\": *null' '$cfgRust'"
check "S105 init (rust): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgRust'"

# (2) go: go.mod → stack go + testCommand "go test ./..."
repoGo="$(new_repo)"
printf 'module x\n\ngo 1.22\n' >"$repoGo/go.mod"
make_claude_stub "$repoGo/claude"; make_gh_stub "$repoGo/gh"
export GH_LOG="$repoGo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoGo/existing"; : >"$GH_EXISTING"
( cd "$repoGo" && LCARS_CLAUDE_BIN="$repoGo/claude" LCARS_GH_BIN="$repoGo/gh" bash "$SCRIPT" >outGo.txt 2>&1 )
cfgGo="$repoGo/.git/lcars/config.json"
check "S105 init (go): stack is 'go'" \
  "grep -q '\"stack\": *\"go\"' '$cfgGo'"
check "S105 init (go): testCommand is the byte-equivalent 'go test ./...'" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgGo' testCommand )\" = 'go test ./...' ]"

# (3) python: pyproject.toml → stack python (testCommand already covered above)
repoPy105="$(new_repo)"
printf '[tool.pytest]\n' >"$repoPy105/pyproject.toml"
make_claude_stub "$repoPy105/claude"; make_gh_stub "$repoPy105/gh"
export GH_LOG="$repoPy105/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPy105/existing"; : >"$GH_EXISTING"
( cd "$repoPy105" && LCARS_CLAUDE_BIN="$repoPy105/claude" LCARS_GH_BIN="$repoPy105/gh" bash "$SCRIPT" >outPy105.txt 2>&1 )
cfgPy105="$repoPy105/.git/lcars/config.json"
check "S105 init (python): stack is 'python'" \
  "grep -q '\"stack\": *\"python\"' '$cfgPy105'"
S105_PY_WANT='pytest "${LCARS_TESTS_DIR:-.}"'
S105_PY_GOT="$( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$cfgPy105" testCommand )"
check "S105 init (python): testCommand still the pytest default (S148: scope quoted)" \
  '[ "$S105_PY_GOT" = "$S105_PY_WANT" ]'

# setup.py is also a python signal
repoPy2="$(new_repo)"
printf 'from setuptools import setup\nsetup()\n' >"$repoPy2/setup.py"
make_claude_stub "$repoPy2/claude"; make_gh_stub "$repoPy2/gh"
export GH_LOG="$repoPy2/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPy2/existing"; : >"$GH_EXISTING"
( cd "$repoPy2" && LCARS_CLAUDE_BIN="$repoPy2/claude" LCARS_GH_BIN="$repoPy2/gh" bash "$SCRIPT" >outPy2.txt 2>&1 )
check "S105 init (python/setup.py): stack is 'python'" \
  "grep -q '\"stack\": *\"python\"' '$repoPy2/.git/lcars/config.json'"

# (4) js: package.json → stack js (testCommand already covered above)
repoJs="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoJs/package.json"
make_claude_stub "$repoJs/claude"; make_gh_stub "$repoJs/gh"
export GH_LOG="$repoJs/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoJs/existing"; : >"$GH_EXISTING"
( cd "$repoJs" && LCARS_CLAUDE_BIN="$repoJs/claude" LCARS_GH_BIN="$repoJs/gh" bash "$SCRIPT" >outJs.txt 2>&1 )
check "S105 init (js): stack is 'js'" \
  "grep -q '\"stack\": *\"js\"' '$repoJs/.git/lcars/config.json'"

# (5) dotnet: a *.csproj → stack dotnet; no auto testCommand (null), no crash
repoNet="$(new_repo)"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' >"$repoNet/App.csproj"
make_claude_stub "$repoNet/claude"; make_gh_stub "$repoNet/gh"
export GH_LOG="$repoNet/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoNet/existing"; : >"$GH_EXISTING"
( cd "$repoNet" && LCARS_CLAUDE_BIN="$repoNet/claude" LCARS_GH_BIN="$repoNet/gh" bash "$SCRIPT" >outNet.txt 2>&1 )
cfgNet="$repoNet/.git/lcars/config.json"
check "S105 init (dotnet): stack is 'dotnet'" \
  "grep -q '\"stack\": *\"dotnet\"' '$cfgNet'"
check "S105 init (dotnet): testCommand is null (no auto default for dotnet)" \
  "grep -q '\"testCommand\": *null' '$cfgNet'"
check "S105 init (dotnet): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgNet'"

# a *.sln is also a dotnet signal
repoSln="$(new_repo)"
printf 'Microsoft Visual Studio Solution File\n' >"$repoSln/App.sln"
make_claude_stub "$repoSln/claude"; make_gh_stub "$repoSln/gh"
export GH_LOG="$repoSln/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoSln/existing"; : >"$GH_EXISTING"
( cd "$repoSln" && LCARS_CLAUDE_BIN="$repoSln/claude" LCARS_GH_BIN="$repoSln/gh" bash "$SCRIPT" >outSln.txt 2>&1 )
check "S105 init (dotnet/.sln): stack is 'dotnet'" \
  "grep -q '\"stack\": *\"dotnet\"' '$repoSln/.git/lcars/config.json'"

# (6) jvm: pom.xml → stack jvm; build.gradle also → jvm
repoJvm="$(new_repo)"
printf '<project></project>\n' >"$repoJvm/pom.xml"
make_claude_stub "$repoJvm/claude"; make_gh_stub "$repoJvm/gh"
export GH_LOG="$repoJvm/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoJvm/existing"; : >"$GH_EXISTING"
( cd "$repoJvm" && LCARS_CLAUDE_BIN="$repoJvm/claude" LCARS_GH_BIN="$repoJvm/gh" bash "$SCRIPT" >outJvm.txt 2>&1 )
cfgJvm="$repoJvm/.git/lcars/config.json"
check "S105 init (jvm/maven): stack is 'jvm'" \
  "grep -q '\"stack\": *\"jvm\"' '$cfgJvm'"
check "S105 init (jvm): testCommand is null (no auto default for jvm)" \
  "grep -q '\"testCommand\": *null' '$cfgJvm'"

repoGradle="$(new_repo)"
printf 'plugins { id "java" }\n' >"$repoGradle/build.gradle"
make_claude_stub "$repoGradle/claude"; make_gh_stub "$repoGradle/gh"
export GH_LOG="$repoGradle/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoGradle/existing"; : >"$GH_EXISTING"
( cd "$repoGradle" && LCARS_CLAUDE_BIN="$repoGradle/claude" LCARS_GH_BIN="$repoGradle/gh" bash "$SCRIPT" >outGradle.txt 2>&1 )
check "S105 init (jvm/gradle): stack is 'jvm'" \
  "grep -q '\"stack\": *\"jvm\"' '$repoGradle/.git/lcars/config.json'"

# --- Session 145: ruby stack arm (rspec / minitest) -------------------------
# helper: run init in $1 with stubs, echoing nothing (config assertions follow).
s145_run() { # repo-dir
  make_claude_stub "$1/claude"; make_gh_stub "$1/gh"
  export GH_LOG="$1/gh.log"; : >"$GH_LOG"
  export GH_EXISTING="$1/existing"; : >"$GH_EXISTING"
  ( cd "$1" && LCARS_CLAUDE_BIN="$1/claude" LCARS_GH_BIN="$1/gh" bash "$SCRIPT" >out.txt 2>&1 )
}
s145_tc() { # config-path → the read-back testCommand
  ( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; lcars_config_get "$1" testCommand )
}

# (R1) rspec: Gemfile names rspec + spec/ → stack ruby, testCommand "bundle exec rspec"
repoRb1="$(new_repo)"
printf 'source "https://rubygems.org"\ngem "rspec"\n' >"$repoRb1/Gemfile"
mkdir -p "$repoRb1/spec"
s145_run "$repoRb1"
cfgRb1="$repoRb1/.git/lcars/config.json"
check "S145 init (rspec): stack is 'ruby'" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgRb1'"
check "S145 init (rspec): testCommand is 'bundle exec rspec'" \
  "[ \"\$(s145_tc '$cfgRb1')\" = 'bundle exec rspec' ]"
check "S145 init (rspec): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgRb1'"

# (R2) minitest: test/ + Rakefile + Gemfile (no rspec) → 'bundle exec rake test'
repoRb2="$(new_repo)"
printf 'source "https://rubygems.org"\ngem "minitest"\n' >"$repoRb2/Gemfile"
printf 'task :test\n' >"$repoRb2/Rakefile"
mkdir -p "$repoRb2/test"
s145_run "$repoRb2"
cfgRb2="$repoRb2/.git/lcars/config.json"
check "S145 init (minitest): stack is 'ruby'" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgRb2'"
check "S145 init (minitest): testCommand is 'bundle exec rake test'" \
  "[ \"\$(s145_tc '$cfgRb2')\" = 'bundle exec rake test' ]"

# (R3) Gemfile-LESS ruby (Rakefile only) → stack ruby, rake test (no bundle prefix)
repoRb3="$(new_repo)"
printf 'task :test\n' >"$repoRb3/Rakefile"
mkdir -p "$repoRb3/test"
s145_run "$repoRb3"
cfgRb3="$repoRb3/.git/lcars/config.json"
check "S145 init (gemfile-less minitest): stack is 'ruby'" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgRb3'"
check "S145 init (gemfile-less minitest): testCommand is bare 'rake test' (no bundle exec)" \
  "[ \"\$(s145_tc '$cfgRb3')\" = 'rake test' ]"

# (R4) gemspec-only gem library → stack ruby, NO testCommand (null), no crash
repoRb4="$(new_repo)"
printf 'Gem::Specification.new\n' >"$repoRb4/mygem.gemspec"
s145_run "$repoRb4"
cfgRb4="$repoRb4/.git/lcars/config.json"
check "S145 init (gemspec-only): stack is 'ruby'" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgRb4'"
check "S145 init (gemspec-only): testCommand is null (runner unresolved)" \
  "grep -q '\"testCommand\": *null' '$cfgRb4'"
check "S145 init (gemspec-only): warns naming BOTH rspec and minitest candidates" \
  "grep -qi 'rspec' '$repoRb4/out.txt' && grep -qi 'minitest\\|rake test' '$repoRb4/out.txt'"
check "S145 init (gemspec-only): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgRb4'"

# (R5) INTERNALLY-ambiguous: spec/ AND test/+Rakefile, Gemfile does NOT name rspec
#      → stack ruby, NO testCommand, warning names both runners.
repoRb5="$(new_repo)"
printf 'source "https://rubygems.org"\n' >"$repoRb5/Gemfile"
printf 'task :test\n' >"$repoRb5/Rakefile"
mkdir -p "$repoRb5/spec" "$repoRb5/test"
s145_run "$repoRb5"
cfgRb5="$repoRb5/.git/lcars/config.json"
check "S145 init (rspec+minitest ambiguous): stack is 'ruby'" \
  "grep -q '\"stack\": *\"ruby\"' '$cfgRb5'"
check "S145 init (rspec+minitest ambiguous): NO testCommand guessed (null)" \
  "grep -q '\"testCommand\": *null' '$cfgRb5'"

# (R6) ruby + js mixed → ambiguous(js,ruby), no testCommand, warns both stacks
repoRbJs="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoRbJs/package.json"
printf 'source "https://rubygems.org"\ngem "rspec"\n' >"$repoRbJs/Gemfile"
mkdir -p "$repoRbJs/spec"
s145_run "$repoRbJs"
cfgRbJs="$repoRbJs/.git/lcars/config.json"
check "S145 init (ruby+js): stack is ambiguous(js,ruby)" \
  "grep -q '\"stack\": *\"ambiguous(js,ruby)\"' '$cfgRbJs'"
check "S145 init (ruby+js): NO testCommand (null, not a silent 'npm test')" \
  "grep -q '\"testCommand\": *null' '$cfgRbJs'"
check "S145 init (ruby+js): the warning NAMES both js and ruby" \
  "grep -qi '\\bjs\\b' '$repoRbJs/out.txt' && grep -qi 'ruby' '$repoRbJs/out.txt'"

# (7) AMBIGUOUS: Cargo.toml + package.json → stack ambiguous(rust,js), NO
#     testCommand seeded, warning NAMES BOTH candidate stacks.
repoAmb="$(new_repo)"
printf '[package]\nname = "x"\n' >"$repoAmb/Cargo.toml"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoAmb/package.json"
make_claude_stub "$repoAmb/claude"; make_gh_stub "$repoAmb/gh"
export GH_LOG="$repoAmb/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoAmb/existing"; : >"$GH_EXISTING"
( cd "$repoAmb" && LCARS_CLAUDE_BIN="$repoAmb/claude" LCARS_GH_BIN="$repoAmb/gh" bash "$SCRIPT" >outAmb.txt 2>&1 )
cfgAmb="$repoAmb/.git/lcars/config.json"
check "S105 init (ambiguous): stack records the ambiguous token naming both stacks" \
  "grep -q '\"stack\": *\"ambiguous(rust,js)\"' '$cfgAmb'"
check "S105 init (ambiguous): NO testCommand is guessed (null, not a silent 'npm test')" \
  "grep -q '\"testCommand\": *null' '$cfgAmb'"
check "S105 init (ambiguous): the warning NAMES both candidate stacks (rust AND js)" \
  "grep -qi 'rust' '$repoAmb/outAmb.txt' && grep -qi '\\bjs\\b' '$repoAmb/outAmb.txt'"
check "S105 init (ambiguous): config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgAmb'"

# (8) UNKNOWN: a bare repo (no markers) → stack unknown, no testCommand, a warning, no crash
repoUnk="$(new_repo)"
make_claude_stub "$repoUnk/claude"; make_gh_stub "$repoUnk/gh"
export GH_LOG="$repoUnk/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoUnk/existing"; : >"$GH_EXISTING"
rcUnk=0
( cd "$repoUnk" && LCARS_CLAUDE_BIN="$repoUnk/claude" LCARS_GH_BIN="$repoUnk/gh" bash "$SCRIPT" >outUnk.txt 2>&1 ) || rcUnk=$?
cfgUnk="$repoUnk/.git/lcars/config.json"
check "S105 init (unknown): does not crash (exit 0)" "[ '$rcUnk' -eq 0 ]"
check "S105 init (unknown): stack is 'unknown'" \
  "grep -q '\"stack\": *\"unknown\"' '$cfgUnk'"
check "S105 init (unknown): testCommand is null" \
  "grep -q '\"testCommand\": *null' '$cfgUnk'"
check "S146 init (unknown/greenfield): ONE calm bootstrap status — no ⚠ config lecture" \
  "grep -qi 'engineering crew' '$repoUnk/outUnk.txt' && ! grep -q '⚠' '$repoUnk/outUnk.txt'"

# (9) a bash tests/run.sh repo has NO stack marker (unknown) but STILL keeps its
#     detected bash testCommand — byte-equivalence with pre-S105 (no suppression).
repoBash105="$(new_repo)"
mkdir -p "$repoBash105/tests"
printf '#!/usr/bin/env bash\necho runner\n' >"$repoBash105/tests/run.sh"
make_claude_stub "$repoBash105/claude"; make_gh_stub "$repoBash105/gh"
export GH_LOG="$repoBash105/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoBash105/existing"; : >"$GH_EXISTING"
( cd "$repoBash105" && LCARS_CLAUDE_BIN="$repoBash105/claude" LCARS_GH_BIN="$repoBash105/gh" bash "$SCRIPT" >outBash105.txt 2>&1 )
cfgBash105="$repoBash105/.git/lcars/config.json"
check "S105 init (bash-runner): stack is 'unknown' (no language marker)" \
  "grep -q '\"stack\": *\"unknown\"' '$cfgBash105'"
check "S105 init (bash-runner): testCommand PRESERVED as the bash runner (byte-equivalent, not suppressed)" \
  "[ \"\$( . '$REPO_ROOT/skills/lcars-init/lcars-common.sh'; lcars_config_get '$cfgBash105' testCommand )\" = 'bash tests/run.sh \"\${LCARS_TESTS_DIR:-tests}\"' ]"

# (10) banner reports the detected stack
check "S105 init: the readiness banner reports the detected stack" \
  "grep -qi 'stack: *rust' '$repoRust/outRust.txt'"

# ==========================================================================
# Session 148: the SEEDED testCommand must survive a WHITESPACE repo path.
#
# Every seeded shape hands the Implement proof gates their scope through
# $LCARS_TESTS_DIR. Interpolated UNQUOTED, the scope WORD-SPLITS the moment the
# repo lives at a path containing a space/tab/newline — the runner is handed two
# half-paths, cannot find either, and the flip-flop gate FALSE-FAILS a perfectly
# honest ticket purely because of where the repo is checked out (which bounces it
# to a fresh worker up to 3 times and then parks it awaiting-human).
#
# The contract asserted here is about ARGV, not about the string: whatever the
# seeded shape is, the runner must receive the scope as EXACTLY ONE argument,
# byte-identical to $LCARS_TESTS_DIR — and, when the scope is UNSET, must receive
# NO extra (empty) argument, because an empty positional is a different run.
# `bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"` has always been quoted; it is
# the model the other arms are held to.

# The probe is deliberately RUNNER-FREE: substituting `printf` for the command
# name makes the shell itself report how the seeded string words out, so the same
# assertion works for every arm (npm/npx/pytest/bash/…) without stubbing a binary
# per runner — and cannot be fooled by a runner that tolerates a split path.
cmd_words() { # cmd [scope] → each expanded word on its own line
  if [ "$#" -ge 2 ]; then
    ( LCARS_TESTS_DIR="$2" bash -c "printf '%s\n' $1" ) 2>/dev/null
  else
    ( bash -c "printf '%s\n' $1" ) 2>/dev/null
  fi
}
cmd_argc() { # cmd [scope] → how many words it expands to (NUL-counted, so a
             # newline INSIDE one argument is not miscounted as two)
  local n
  if [ "$#" -ge 2 ]; then
    n="$( ( LCARS_TESTS_DIR="$2" bash -c "printf '%s\000' $1" ) 2>/dev/null | tr -cd '\000' | wc -c )"
  else
    n="$( ( bash -c "printf '%s\000' $1" ) 2>/dev/null | tr -cd '\000' | wc -c )"
  fi
  printf '%s' "$n" | tr -d ' '
}
# The scope shapes that break an unquoted interpolation: IFS whitespace.
SP_SCOPE='/tmp/sp test/src/calc.test.js'
TAB_SCOPE="$(printf '/tmp/sp\ttest/src/calc.test.js')"
NL_SCOPE="$(printf '/tmp/sp\ntest/src/calc.test.js')"
PLAIN_SCOPE='/tmp/sptest/src/calc.test.js'

# The seeded shape per stack, asked of the REAL detector (never a copy of the
# string): whatever detect_test_cmd emits for that repo layout IS what is tested.
seeded_cmd_for() { # repo-dir → the command lcars init would seed
  ( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; TOPLEVEL="$1" detect_test_cmd )
}

# NB: the seeded command is handed to `check` through a VARIABLE, never
# interpolated into the assertion string — `check` evals its argument, and a
# literal `${LCARS_TESTS_DIR:-.}` (or an embedded `"`) would be expanded/broken
# by that eval before the probe ever saw it. Single-quoted assertions here.
ws_case() { # label repo-dir expected-argc-when-scoped expected-argc-when-unset
  local label="$1"
  WS_CMD="$(seeded_cmd_for "$2")"; WS_ARGC="$3"; WS_UNSET_ARGC="$4"
  check "S148 seed ($label): a SPACED scope survives as ONE argument" \
    '[ "$(cmd_argc "$WS_CMD" "$SP_SCOPE")" = "$WS_ARGC" ] && [ "$(cmd_words "$WS_CMD" "$SP_SCOPE" | tail -1)" = "$SP_SCOPE" ]'
  check "S148 seed ($label): a TABBED scope survives as ONE argument" \
    '[ "$(cmd_argc "$WS_CMD" "$TAB_SCOPE")" = "$WS_ARGC" ] && [ "$(cmd_words "$WS_CMD" "$TAB_SCOPE" | tail -1)" = "$TAB_SCOPE" ]'
  check "S148 seed ($label): a NEWLINE in the scope survives as ONE argument" \
    '[ "$(cmd_argc "$WS_CMD" "$NL_SCOPE")" = "$WS_ARGC" ]'
  check "S148 seed ($label): an UNSET scope is byte-for-byte the pre-fix behaviour" \
    '[ "$(cmd_argc "$WS_CMD")" = "$WS_UNSET_ARGC" ]'
}

# --- (a) single-package npm (`npm test -- <scope>`) ------------------------
repoWS1="$(new_repo)"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoWS1/package.json"
ws_case "npm single-package" "$repoWS1" 4 3

# --- (b) monorepo jest (`npx jest <scope>`) --------------------------------
repoWS2="$(new_repo)"
printf '{ "workspaces": ["packages/*"], "scripts": { "test": "jest" } }\n' >"$repoWS2/package.json"
WS_JEST="$(seeded_cmd_for "$repoWS2")"
check "S148 seed (monorepo jest): the seeded command really is the jest arm" \
  'printf "%s" "$WS_JEST" | grep -q jest'
ws_case "monorepo jest" "$repoWS2" 3 2

# --- (c) monorepo mocha (`npx mocha <scope>`) ------------------------------
repoWS3="$(new_repo)"
printf '{ "workspaces": ["packages/*"], "scripts": { "test": "mocha" } }\n' >"$repoWS3/package.json"
ws_case "monorepo mocha" "$repoWS3" 3 2

# --- (d) monorepo, runner not named in the root script → `npm test -- <scope>`
repoWS4="$(new_repo)"
printf '{ "workspaces": ["packages/*"], "scripts": { "test": "run-all" } }\n' >"$repoWS4/package.json"
ws_case "monorepo fallback" "$repoWS4" 4 3

# --- (e) python (`pytest <scope>`), incl. the `.` default ------------------
repoWS5="$(new_repo)"
printf '[tool.pytest]\n' >"$repoWS5/pyproject.toml"
ws_case "pytest" "$repoWS5" 2 2
WS_PY="$(seeded_cmd_for "$repoWS5")"
check "S148 seed (pytest): an UNSET scope still defaults to exactly one '.' argument" \
  '[ "$(cmd_words "$WS_PY" | tail -1)" = "." ]'

# --- (f) the bash runner arm — the pre-existing MODEL, must not regress ----
repoWS6="$(new_repo)"
mkdir -p "$repoWS6/tests"
printf '#!/usr/bin/env bash\necho runner\n' >"$repoWS6/tests/run.sh"
WS_BASH="$(seeded_cmd_for "$repoWS6")"
WS_BASH_WANT='bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'
check "S148 seed (bash runner): the already-quoted model arm is unchanged" \
  '[ "$WS_BASH" = "$WS_BASH_WANT" ]'
ws_case "bash runner" "$repoWS6" 3 3

# --- (g) the STRUCTURAL backstop over EVERY seed literal in the seeder ------
# So a NEW arm cannot quietly reintroduce the defect: harvest every single-quoted
# command literal in lcars-common.sh that interpolates the scope, and require its
# word count to be IDENTICAL for a spaced scope and an unspaced one. A quoted
# interpolation is invariant; an unquoted one is not.
WS_SEEDS="$(grep -oE "'[^']*LCARS_TESTS_DIR[^']*'" "$REPO_ROOT/skills/lcars-init/lcars-common.sh" \
            | sed -E "s/^'//; s/'\$//" | sort -u)"
check "S148 seed: the structural sweep actually found seed literals to check" \
  "[ \"\$(printf '%s\n' \"\$WS_SEEDS\" | grep -c . )\" -ge 4 ]"
ws_bad=0; ws_n=0
while IFS= read -r ws_seed; do
  [ -n "$ws_seed" ] || continue
  ws_n=$((ws_n + 1))
  if [ "$(cmd_argc "$ws_seed" "$SP_SCOPE")" != "$(cmd_argc "$ws_seed" "$PLAIN_SCOPE")" ]; then
    ws_bad=$((ws_bad + 1)); printf '       unquoted seed literal: %s\n' "$ws_seed"
  fi
done <<WS_EOF
$WS_SEEDS
WS_EOF
check "S148 seed: EVERY seed literal ($ws_n) words out identically for a spaced and an unspaced scope" \
  "[ '$ws_bad' -eq 0 ]"

# --- S182: an UNBORN HEAD gets an empty initial commit, announced ----------
# LCARS proves every ticket against its PARENT COMMIT. A repo with no commits
# has no parent, so Implement used to die on it mid-ticket — one `git commit`
# standing between the captain and a working mission, discovered at the worst
# possible moment. `lcars init` seeds it at setup, where it costs nothing.
# It must be NON-DESTRUCTIVE: staged work stays staged, and a repo that already
# has commits is not touched at all.
ub="$(new_repo)"
make_claude_stub "$ub/claude"; make_gh_stub "$ub/gh"
export GH_LOG="$ub/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$ub/existing"; : >"$GH_EXISTING"
printf 'staged\n' > "$ub/kept.txt"
( cd "$ub" && git add kept.txt )
check "S182: fixture really starts with an UNBORN head" \
  "! ( cd '$ub' && git rev-parse --verify -q HEAD >/dev/null 2>&1 )"
( cd "$ub" && LCARS_CLAUDE_BIN="$ub/claude" LCARS_GH_BIN="$ub/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "S182: init seeds an initial commit on a repo with no HEAD" \
  "( cd '$ub' && git rev-parse --verify -q HEAD >/dev/null 2>&1 )"
check "S182: the seeded commit is EMPTY (it commits nothing of the captain's)" \
  "[ -z \"\$( cd '$ub' && git ls-tree -r --name-only HEAD )\" ]"
check "S182: the captain's STAGED file is still staged, not swallowed by the seed" \
  "( cd '$ub' && git diff --cached --name-only ) | qgrep -qx 'kept.txt'"
check "S182: init ANNOUNCES the seeded commit in the readout" \
  "qgrep -q 'seeded an empty initial commit' '$ub/out.txt'"
check "S182: and says WHY (LCARS proves work against a parent)" \
  "qgrep -qi 'proves work against a parent' '$ub/out.txt'"

# A repo that ALREADY has commits must be left completely alone.
hb="$(new_repo)"
make_claude_stub "$hb/claude"; make_gh_stub "$hb/gh"
export GH_LOG="$hb/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$hb/existing"; : >"$GH_EXISTING"
( cd "$hb" && printf 'x\n' > a.txt && git add a.txt && git commit -qm real )
HB_BEFORE="$( cd "$hb" && git rev-parse HEAD )"
HB_COUNT_BEFORE="$( cd "$hb" && git rev-list --count HEAD )"
( cd "$hb" && LCARS_CLAUDE_BIN="$hb/claude" LCARS_GH_BIN="$hb/gh" bash "$SCRIPT" >out.txt 2>&1 )
check "S182: a repo that already has commits keeps the SAME HEAD" \
  "[ \"\$( cd '$hb' && git rev-parse HEAD )\" = '$HB_BEFORE' ]"
check "S182: and gains no extra commit" \
  "[ \"\$( cd '$hb' && git rev-list --count HEAD )\" = '$HB_COUNT_BEFORE' ]"
check "S182: and the seed line is NOT printed (nothing was seeded)" \
  "! qgrep -q 'seeded an empty initial commit' '$hb/out.txt'"

# --- S207 item 1: the front door accepts a COPILOT-ONLY laptop -------------
# Captain's ruling 2026-09-11: require AT LEAST ONE engine. With both installed
# nothing changes (claude still wins, covered by every case above); with only
# copilot, init succeeds, SAYS which engine it picked, and records it in the
# config so every later surface opens on the engine this laptop can actually
# run. `CLAUDE_VERSION` must never be read when claude is absent.
make_copilot_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "copilot/0.0.1-test"
EOF
  chmod +x "$p"
}

repoCo="$(new_repo)"
make_copilot_stub "$repoCo/copilot"
make_gh_stub "$repoCo/gh"
export GH_LOG="$repoCo/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoCo/existing"; : >"$GH_EXISTING"
rcCo=0
(
  cd "$repoCo"
  LCARS_CLAUDE_BIN="$repoCo/definitely-not-claude" \
  LCARS_COPILOT_BIN="$repoCo/copilot" \
  LCARS_GH_BIN="$repoCo/gh" bash "$SCRIPT" >out.txt 2>&1
) || rcCo=$?
check "S207-1: init SUCCEEDS on a copilot-only laptop" "[ '$rcCo' -eq 0 ]"
check "S207-1: it scaffolds .git/lcars/ there"         "[ -d '$repoCo/.git/lcars/missions' ]"
check "S207-1: it SAYS claude was missing and copilot was used" \
  "qgrep -q 'claude not found — using copilot' '$repoCo/out.txt'"
check "S207-1: the verified line names copilot, not Claude" \
  "qgrep -qi 'copilot CLI verified' '$repoCo/out.txt'"
check "S207-1: and reports the copilot stub's version (the bin it actually ran)" \
  "qgrep -q 'copilot/0.0.1-test' '$repoCo/out.txt'"
check "S207-1: config RECORDS the engine it picked" \
  "qgrep -q '\"workerBin\": *\"copilot\"' '$repoCo/.git/lcars/config.json'"
check "S207-1: it never shelled out to a 'claude' that is not there" \
  "! qgrep -qi 'definitely-not-claude' '$repoCo/out.txt'"

# With BOTH installed nothing changes: claude wins, and the config is NOT
# pinned (an unpinned repo keeps run.sh's historical default).
repoBoth="$(new_repo)"
make_claude_stub "$repoBoth/claude"
make_copilot_stub "$repoBoth/copilot"
make_gh_stub "$repoBoth/gh"
export GH_LOG="$repoBoth/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoBoth/existing"; : >"$GH_EXISTING"
(
  cd "$repoBoth"
  LCARS_CLAUDE_BIN="$repoBoth/claude" LCARS_COPILOT_BIN="$repoBoth/copilot" \
  LCARS_GH_BIN="$repoBoth/gh" bash "$SCRIPT" >out.txt 2>&1
)
check "S207-1: with BOTH engines, claude is still the one verified" \
  "qgrep -q 'Claude CLI verified' '$repoBoth/out.txt'"
check "S207-1: with BOTH engines, no fallback note is printed" \
  "! qgrep -q 'claude not found' '$repoBoth/out.txt'"
check "S207-1: with BOTH engines, the config is left UNPINNED" \
  "! qgrep -q 'workerBin' '$repoBoth/.git/lcars/config.json'"

# A config that ALREADY pins an engine survives init (the merge drops every key
# absent from the desired schema, so an unlisted workerBin was being WIPED).
repoPin="$(new_repo)"
make_claude_stub "$repoPin/claude"
make_copilot_stub "$repoPin/copilot"
make_gh_stub "$repoPin/gh"
export GH_LOG="$repoPin/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPin/existing"; : >"$GH_EXISTING"
mkdir -p "$repoPin/.git/lcars"
printf '{\n  "workerBin": "copilot",\n  "model": "claude-sonnet"\n}\n' >"$repoPin/.git/lcars/config.json"
(
  cd "$repoPin"
  LCARS_CLAUDE_BIN="$repoPin/claude" LCARS_COPILOT_BIN="$repoPin/copilot" \
  LCARS_GH_BIN="$repoPin/gh" bash "$SCRIPT" >out.txt 2>&1
)
check "S207-1: an existing workerBin pin SURVIVES init" \
  "qgrep -q '\"workerBin\": *\"copilot\"' '$repoPin/.git/lcars/config.json'"
check "S207-1: and init verifies the engine the repo is pinned to" \
  "qgrep -qi 'copilot CLI verified' '$repoPin/out.txt'"

# --- S207 item 4: the `npm ci` seed only with a lockfile -------------------
# `npm ci` ERRORS without package-lock.json, and the seeded worktreeSetupCommand
# used it unconditionally — 4 provisioning failures in one live run.
repoJS="$(new_repo)"
make_claude_stub "$repoJS/claude"; make_gh_stub "$repoJS/gh"
export GH_LOG="$repoJS/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoJS/existing"; : >"$GH_EXISTING"
printf '{"name":"x","scripts":{"test":"node --test"}}\n' >"$repoJS/package.json"
( cd "$repoJS" && LCARS_CLAUDE_BIN="$repoJS/claude" LCARS_GH_BIN="$repoJS/gh" bash "$SCRIPT" >out.txt 2>&1 )
WT_NOLOCK="$(sed -n 's/.*"worktreeSetupCommand": *"\(.*\)",*$/\1/p' "$repoJS/.git/lcars/config.json")"
check "S207-4: a JS repo with NO lockfile is seeded a command (not empty)" \
  "[ -n \"\$WT_NOLOCK\" ]"
check "S207-4: and that command does NOT contain 'npm ci'" \
  "! printf '%s' \"\$WT_NOLOCK\" | qgrep -q 'npm ci'"
check "S207-4: it falls back to 'npm install'" \
  "printf '%s' \"\$WT_NOLOCK\" | qgrep -q 'npm install'"

repoJSL="$(new_repo)"
make_claude_stub "$repoJSL/claude"; make_gh_stub "$repoJSL/gh"
export GH_LOG="$repoJSL/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoJSL/existing"; : >"$GH_EXISTING"
printf '{"name":"x","scripts":{"test":"node --test"}}\n' >"$repoJSL/package.json"
printf '{"lockfileVersion":3}\n' >"$repoJSL/package-lock.json"
( cd "$repoJSL" && LCARS_CLAUDE_BIN="$repoJSL/claude" LCARS_GH_BIN="$repoJSL/gh" bash "$SCRIPT" >out.txt 2>&1 )
WT_LOCK="$(sed -n 's/.*"worktreeSetupCommand": *"\(.*\)",*$/\1/p' "$repoJSL/.git/lcars/config.json")"
check "S207-4: WITH a package-lock.json the seed DOES use 'npm ci'" \
  "printf '%s' \"\$WT_LOCK\" | qgrep -q 'npm ci'"

# pnpm: --frozen-lockfile errors the same way when there is no pnpm-lock.yaml
# (a pnpm-workspace.yaml alone takes that arm).
repoPN="$(new_repo)"
make_claude_stub "$repoPN/claude"; make_gh_stub "$repoPN/gh"
export GH_LOG="$repoPN/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPN/existing"; : >"$GH_EXISTING"
printf '{"name":"x"}\n' >"$repoPN/package.json"
printf 'packages:\n  - "pkg/*"\n' >"$repoPN/pnpm-workspace.yaml"
( cd "$repoPN" && LCARS_CLAUDE_BIN="$repoPN/claude" LCARS_GH_BIN="$repoPN/gh" bash "$SCRIPT" >out.txt 2>&1 )
WT_PN="$(sed -n 's/.*"worktreeSetupCommand": *"\(.*\)",*$/\1/p' "$repoPN/.git/lcars/config.json")"
check "S207-4: a pnpm workspace with NO pnpm-lock.yaml drops --frozen-lockfile" \
  "! printf '%s' \"\$WT_PN\" | qgrep -q 'frozen-lockfile'"
check "S207-4: and still installs with pnpm" \
  "printf '%s' \"\$WT_PN\" | qgrep -q 'pnpm install'"

repoPNL="$(new_repo)"
make_claude_stub "$repoPNL/claude"; make_gh_stub "$repoPNL/gh"
export GH_LOG="$repoPNL/gh.log"; : >"$GH_LOG"
export GH_EXISTING="$repoPNL/existing"; : >"$GH_EXISTING"
printf '{"name":"x"}\n' >"$repoPNL/package.json"
printf 'lockfileVersion: 9\n' >"$repoPNL/pnpm-lock.yaml"
( cd "$repoPNL" && LCARS_CLAUDE_BIN="$repoPNL/claude" LCARS_GH_BIN="$repoPNL/gh" bash "$SCRIPT" >out.txt 2>&1 )
WT_PNL="$(sed -n 's/.*"worktreeSetupCommand": *"\(.*\)",*$/\1/p' "$repoPNL/.git/lcars/config.json")"
check "S207-4: WITH a pnpm-lock.yaml the seed KEEPS --frozen-lockfile" \
  "printf '%s' \"\$WT_PNL\" | qgrep -q 'frozen-lockfile'"

# ==========================================================================
echo
printf 'lcars init: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
