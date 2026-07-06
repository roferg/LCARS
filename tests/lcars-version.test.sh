#!/usr/bin/env bash
#
# Tests for `lcars version` (skill source: skills/lcars-version/version.sh) plus
# the two-level version STAMPING that `lcars init` / `lcars update` write into a
# repo's config.json.
#
# `lcars version` prints:
#   - the RUNNING version (this clone's VERSION file, or the LCARS_VERSION pin)
#   - the SOURCE path + git state (branch, clean/dirty; NO fetch)
#   - the current repo's stamped lcarsVersion + a one-line verdict:
#       stamped == running -> current
#       stamped <  running -> repo needs `lcars update`
#       stamped absent     -> unknown (predates versioning)
#   comparing YYYY.M.N field-by-field NUMERICALLY (2026.7.10 > 2026.7.2).
#
# A malformed / empty / missing VERSION is a readable error + non-zero exit,
# never an unbound-variable / arithmetic crash.
#
# Dependencies are env-injected so tests pin fixtures with zero tokens:
#   LCARS_REPO         the LCARS checkout (source root; holds VERSION + skills/)
#   LCARS_VERSION      pin the running version string (overrides the VERSION file)
#   GIT_BIN            git binary
#   LCARS_VERSION_CWD  repo to inspect for a stamp
#
# Usage: bash tests/lcars-version.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_VERSION_SCRIPT:-$REPO_ROOT/skills/lcars-version/version.sh}"
INIT="$REPO_ROOT/skills/lcars-init/init.sh"
UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"

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
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "label" ] && [ "$2" = "list" ]; then exit 0; fi
exit 0
EOF
  chmod +x "$p"
}

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "$repo"
}

# An LCARS-initialized repo whose config.json stamps a given lcarsVersion. Pass an
# empty stamp to leave it UNSTAMPED (predates versioning).
init_repo_stamped() {
  local repo="$1" stamp="$2"
  local cfg="$repo/.git/lcars"
  mkdir -p "$cfg"
  if [ -n "$stamp" ]; then
    cat >"$cfg/config.json" <<JSON
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "testCommand": null,
  "comprehensionBudget": 1200,
  "lcarsVersion": "$stamp",
  "created": "2020-01-01T00:00:00Z"
}
JSON
  else
    cat >"$cfg/config.json" <<'JSON'
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "testCommand": null,
  "comprehensionBudget": 1200,
  "created": "2020-01-01T00:00:00Z"
}
JSON
  fi
}

# ==========================================================================
echo "lcars version"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- 1. running version + source path ------------------------------------
repo="$(new_repo)"; init_repo_stamped "$repo" "2026.7.5"
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.5" LCARS_VERSION_CWD="$repo" \
  bash "$SCRIPT" >"$repo/out.txt" 2>&1
check "1. prints the running version" \
  "grep -q 'running version: 2026.7.5' '$repo/out.txt'"
check "1. prints the source path (the LCARS checkout)" \
  "grep -q 'source path: *$REPO_ROOT' '$repo/out.txt'"
check "1. prints the source git state (branch + clean/dirty)" \
  "grep -qi 'source git:' '$repo/out.txt' && grep -qiE 'clean|dirty' '$repo/out.txt'"

# --- 1a. verdict: stamped == running -> current ---------------------------
repo="$(new_repo)"; init_repo_stamped "$repo" "2026.7.5"
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.5" LCARS_VERSION_CWD="$repo" \
  bash "$SCRIPT" >"$repo/out.txt" 2>&1
check "1a. stamped == running -> verdict 'current'" \
  "grep -q 'stamped version: 2026.7.5' '$repo/out.txt' && grep -qi 'verdict: *current' '$repo/out.txt'"

# --- 1b. verdict: stamped < running (NUMERIC field compare) ---------------
# 2026.7.2 < 2026.7.10 only under NUMERIC compare (string compare says "2" > "10").
repo="$(new_repo)"; init_repo_stamped "$repo" "2026.7.2"
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.10" LCARS_VERSION_CWD="$repo" \
  bash "$SCRIPT" >"$repo/out.txt" 2>&1
check "1b. stamped 2026.7.2 < running 2026.7.10 -> needs update (numeric compare)" \
  "grep -qi 'needs .*lcars update' '$repo/out.txt'"
check "1b. does NOT mis-verdict a numerically-lower stamp as current" \
  "! grep -qi 'verdict: *current' '$repo/out.txt'"

# --- 1c. verdict: unstamped (initialized, predates versioning) -> needs update -
# Captain amendment (S130): an LCARS-initialized repo with NO lcarsVersion key
# predates versioning, so its verdict is the ACTIONABLE "needs lcars update
# (predates versioning)" — NOT the passive "unknown".
repo="$(new_repo)"; init_repo_stamped "$repo" ""
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.5" LCARS_VERSION_CWD="$repo" \
  bash "$SCRIPT" >"$repo/out.txt" 2>&1
check "1c. unstamped (predates) repo -> actionable 'needs lcars update'" \
  "grep -qi 'needs .*lcars update' '$repo/out.txt' && grep -qi 'predates' '$repo/out.txt'"
check "1c. unstamped (predates) repo does NOT verdict a passive 'unknown'" \
  "! grep -qi 'verdict: *unknown' '$repo/out.txt'"

# --- 1d. verdict: MALFORMED stamp -> stays 'unknown' (never nag on garbage) ----
repo="$(new_repo)"; init_repo_stamped "$repo" "not-a-version"
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.5" LCARS_VERSION_CWD="$repo" \
  bash "$SCRIPT" >"$repo/out.txt" 2>&1
check "1d. malformed stamp -> verdict 'unknown' (malformed), NOT needs-update" \
  "grep -qi 'verdict: *unknown' '$repo/out.txt' && grep -qi 'malformed' '$repo/out.txt'"
check "1d. malformed stamp does NOT tell the captain to run lcars update" \
  "! grep -qi 'needs .*lcars update' '$repo/out.txt'"

# --- 1e. UNINITIALIZED cwd -> silent about a stamp (no false predates nag) ------
bare="$(new_repo)"   # a git repo, but NO .git/lcars/config.json
LCARS_REPO="$REPO_ROOT" LCARS_VERSION="2026.7.5" LCARS_VERSION_CWD="$bare" \
  bash "$SCRIPT" >"$bare/out.txt" 2>&1
check "1e. uninitialized cwd -> 'not LCARS-initialized', no stamp verdict" \
  "grep -qi 'not LCARS-initialized' '$bare/out.txt' && ! grep -qi 'predates' '$bare/out.txt'"

# --- 2. init stamps lcarsVersion; re-init PRESERVES a hand-edit ------------
repoI="$(new_repo)"
make_claude_stub "$repoI/claude"; make_gh_stub "$repoI/gh"
( cd "$repoI" && LCARS_VERSION="2050.5.5" LCARS_CLAUDE_BIN="$repoI/claude" \
    LCARS_GH_BIN="$repoI/gh" bash "$INIT" >/dev/null 2>&1 )
cfgI="$repoI/.git/lcars/config.json"
check "2. init stamps lcarsVersion with the running version" \
  "grep -q '\"lcarsVersion\": *\"2050.5.5\"' '$cfgI'"
check "2. init config.json is VALID JSON with the stamp" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgI'"
# Captain hand-edits the stamp; a RE-init must PRESERVE it (MISSING-only merge).
( cd "$repoI" && sed -i.bak 's/"lcarsVersion": *"2050.5.5"/"lcarsVersion": "1999.1.1"/' "$cfgI" && rm -f "$cfgI.bak" )
( cd "$repoI" && LCARS_VERSION="2050.5.5" LCARS_CLAUDE_BIN="$repoI/claude" \
    LCARS_GH_BIN="$repoI/gh" bash "$INIT" >/dev/null 2>&1 )
check "2. re-init PRESERVES a hand-edited lcarsVersion (never clobbers)" \
  "grep -q '\"lcarsVersion\": *\"1999.1.1\"' '$cfgI'"

# --- 3. update REFRESHES the stamp old->new, clobbers nothing else ---------
repoU="$(new_repo)"
make_claude_stub "$repoU/claude"; make_gh_stub "$repoU/gh"
( cd "$repoU" && LCARS_VERSION="2001.1.1" LCARS_CLAUDE_BIN="$repoU/claude" \
    LCARS_GH_BIN="$repoU/gh" bash "$INIT" >/dev/null 2>&1 )
cfgU="$repoU/.git/lcars/config.json"
# Give the captain a customization we must NOT clobber.
( cd "$repoU" && sed -i.bak 's/"model": *"[^"]*"/"model": "captain-model"/' "$cfgU" && rm -f "$cfgU.bak" )
( cd "$repoU" && LCARS_VERSION="2050.5.5" LCARS_GH_BIN="$repoU/gh" bash "$UPDATE" >"$repoU/out.txt" 2>&1 )
check "3. update refreshes lcarsVersion to the running version" \
  "grep -q '\"lcarsVersion\": *\"2050.5.5\"' '$cfgU'"
check "3. update reports the stamp move old -> new" \
  "grep -q '2001.1.1' '$repoU/out.txt' && grep -q '2050.5.5' '$repoU/out.txt'"
check "3. update does NOT clobber the captain's model" \
  "grep -q '\"model\": *\"captain-model\"' '$cfgU'"
check "3. updated config.json is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgU'"

# update on an UNSTAMPED (predates-versioning) config seeds it, rendered as
# "(unstamped) -> <running>".
repoUn="$(new_repo)"
make_gh_stub "$repoUn/gh"
mkdir -p "$repoUn/.git/lcars"
cat >"$repoUn/.git/lcars/config.json" <<'JSON'
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "testCommand": null,
  "comprehensionBudget": 1200,
  "created": "2018-01-01T00:00:00Z"
}
JSON
( cd "$repoUn" && LCARS_VERSION="2050.5.5" LCARS_GH_BIN="$repoUn/gh" bash "$UPDATE" >"$repoUn/out.txt" 2>&1 )
check "3. update on an unstamped repo seeds lcarsVersion" \
  "grep -q '\"lcarsVersion\": *\"2050.5.5\"' '$repoUn/.git/lcars/config.json'"
check "3. update renders an unstamped -> new stamp move" \
  "grep -qi '(unstamped)' '$repoUn/out.txt' && grep -q '2050.5.5' '$repoUn/out.txt'"

# --- 4. malformed / empty / missing VERSION -> readable error, non-zero ----
# no crash: never emits an unbound-variable / arithmetic / syntax blow-up.
srcBad="$(mktemp -d "$TMPROOT/src.XXXX")"
printf 'not-a-version\n' >"$srcBad/VERSION"
rc=0
LCARS_REPO="$srcBad" LCARS_VERSION_CWD="$(new_repo)" \
  bash "$SCRIPT" >"$srcBad/out.txt" 2>&1 || rc=$?
check "4. malformed VERSION exits non-zero" "[ '$rc' -ne 0 ]"
check "4. malformed VERSION prints a readable error (mentions VERSION/malformed)" \
  "grep -qiE 'malformed|VERSION' '$srcBad/out.txt'"
check "4. malformed VERSION does NOT crash (no unbound/arithmetic/syntax error)" \
  "! grep -qiE 'unbound variable|syntax error|integer expression|value too great' '$srcBad/out.txt'"

srcEmpty="$(mktemp -d "$TMPROOT/src.XXXX")"
: >"$srcEmpty/VERSION"
rc=0
LCARS_REPO="$srcEmpty" LCARS_VERSION_CWD="$(new_repo)" \
  bash "$SCRIPT" >"$srcEmpty/out.txt" 2>&1 || rc=$?
check "4. empty VERSION exits non-zero" "[ '$rc' -ne 0 ]"
check "4. empty VERSION prints a readable error" \
  "grep -qiE 'missing|empty|malformed|VERSION' '$srcEmpty/out.txt'"

srcMissing="$(mktemp -d "$TMPROOT/src.XXXX")"   # no VERSION file at all
rc=0
LCARS_REPO="$srcMissing" LCARS_VERSION_CWD="$(new_repo)" \
  bash "$SCRIPT" >"$srcMissing/out.txt" 2>&1 || rc=$?
check "4. missing VERSION exits non-zero (no crash)" \
  "[ '$rc' -ne 0 ] && ! grep -qiE 'unbound variable|syntax error' '$srcMissing/out.txt'"

# ==========================================================================
echo
printf 'lcars version: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
