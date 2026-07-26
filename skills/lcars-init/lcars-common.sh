#!/usr/bin/env bash
#
# lcars-common.sh — shared, sourceable helpers used by both `lcars init` and
# `lcars update`. Keeping the canonical label set and the merge-preserving
# config writer in ONE place means update can extend an already-initialized repo
# with exactly the same labels/keys init would create — no drift, no duplication.
#
# This file defines functions and data only; it runs nothing on its own. Source
# it:
#
#     . "$(dirname "$0")/lcars-common.sh"
#
# Dependencies are read from the caller's environment so tests can stub them:
#   GH_BIN   the gh binary (callers set this from ${LCARS_GH_BIN:-gh})
#
# ---------------------------------------------------------------------------
# CANONICAL LABEL SET
# ---------------------------------------------------------------------------
# One source of truth for the LCARS GitHub labels: their names, group colours,
# and descriptions. Both init (first-time setup) and update (fill-the-gaps)
# create from this list, skipping any label already present on the repo.

LCARS_STAGE_COLOR="FF9900"
LCARS_TYPE_COLOR="4499FF"
LCARS_STATUS_COLOR="FF3344"
LCARS_REL_COLOR="9977FF"
LCARS_ROLE_COLOR="00B894"

LCARS_STAGE_LABELS="align research validate plan plan-review schedule implement verify done"
LCARS_TYPE_LABELS="feature bug"
LCARS_STATUS_LABELS="paused awaiting-human"
LCARS_REL_LABELS="linked"
LCARS_ROLE_LABELS="mission ticket"

lcars_label_desc() {
  case "$1" in
    lcars:align)          echo "Stage: aligning on the mission goal with the captain" ;;
    lcars:research)       echo "Stage: exploring the codebase and constraints" ;;
    lcars:validate)       echo "Stage: confirming research with the captain" ;;
    lcars:plan)           echo "Stage: drafting the implementation plan" ;;
    lcars:plan-review)    echo "Stage: captain reviewing the plan" ;;
    lcars:schedule)       echo "Stage: breaking the plan into tasks" ;;
    lcars:implement)      echo "Stage: executing the tasks" ;;
    lcars:verify)         echo "Stage: confirming the work meets the goal" ;;
    lcars:done)           echo "Stage: mission complete" ;;
    lcars:feature)        echo "Type: a feature mission" ;;
    lcars:bug)            echo "Type: a bug mission" ;;
    lcars:paused)         echo "Status: mission paused" ;;
    lcars:awaiting-human) echo "Status: waiting on the captain's orders" ;;
    lcars:linked)         echo "Relationship: linked to another mission" ;;
    lcars:mission)        echo "Role: a Mission's own command-and-control issue" ;;
    lcars:ticket)         echo "Role: an implementation sub-issue spun up by Schedule" ;;
    *)                    echo "LCARS label" ;;
  esac
}

# Emit every canonical "lcars:<name>|<color>" pair, one per line. Callers iterate
# this so the ordering/colours stay defined in exactly one place.
lcars_all_labels() {
  local n
  for n in $LCARS_STAGE_LABELS;  do echo "lcars:$n|$LCARS_STAGE_COLOR";  done
  for n in $LCARS_TYPE_LABELS;   do echo "lcars:$n|$LCARS_TYPE_COLOR";   done
  for n in $LCARS_STATUS_LABELS; do echo "lcars:$n|$LCARS_STATUS_COLOR"; done
  for n in $LCARS_REL_LABELS;    do echo "lcars:$n|$LCARS_REL_COLOR";    done
  for n in $LCARS_ROLE_LABELS;   do echo "lcars:$n|$LCARS_ROLE_COLOR";   done
}

# lcars_create_labels — create any MISSING canonical labels on the current repo.
#
# Args:
#   $1  gh binary
#   $2  newline-separated list of labels already on the repo (may be empty)
#
# Sets these globals for the caller to report on:
#   LCARS_LABELS_CREATED   count created this run
#   LCARS_LABELS_SKIPPED   count already present (skipped)
#   LCARS_LABELS_CREATED_NAMES  space-separated names created
#
# A label already present is skipped (never re-created), so this is idempotent
# and shared identically by init and update.
lcars_create_labels() {
  local gh="$1" existing="$2"
  LCARS_LABELS_CREATED=0
  LCARS_LABELS_SKIPPED=0
  LCARS_LABELS_CREATED_NAMES=""

  local line name color
  while IFS='|' read -r name color; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -Fxq "$name"; then
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
      continue
    fi
    if "$gh" label create "$name" --color "$color" \
         --description "$(lcars_label_desc "$name")" >/dev/null 2>&1; then
      LCARS_LABELS_CREATED=$((LCARS_LABELS_CREATED + 1))
      LCARS_LABELS_CREATED_NAMES="${LCARS_LABELS_CREATED_NAMES:+$LCARS_LABELS_CREATED_NAMES }$name"
    else
      # Treat "already exists" races and other soft failures as skips.
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
    fi
  done <<EOF
$(lcars_all_labels)
EOF
}

# ---------------------------------------------------------------------------
# MERGE-PRESERVING CONFIG WRITE
# ---------------------------------------------------------------------------
# config.json is written by MERGE, never by clobber: existing values for keys
# already present are preserved untouched; only MISSING keys are filled in with
# the supplied defaults. This makes re-running init (and running update)
# idempotent — a captain's customized testCommand / model / comprehensionBudget
# survives. Both init and update call this so the behaviour cannot drift.

# lcars_json_escape — escape a string for embedding inside a JSON string literal.
# Backslashes are escaped FIRST, then double-quotes (the standard order — mirrors
# json_escape in skills/lcars-run/run.sh), then awk escapes every control char
# (newline/tab/CR → \n \t \r, the rest \u00XX) so ANY value yields VALID JSON.
# The result is safe to wrap in quotes. jq-free.
lcars_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# lcars_config_has_key — 0 if the config file has a top-level "key": present.
lcars_config_has_key() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 1
  grep -q "\"$key\"[[:space:]]*:" "$config"
}

# lcars_config_get — print the JSON value of a top-level string key, with the
# standard JSON escapes un-escaped (\" → ", \\ → \). Mirrors json_str in
# skills/lcars-run/run.sh so both jq-free readers agree on a value written with
# embedded quotes (e.g. a testCommand referencing "${LCARS_TESTS_DIR:-tests}").
# Empty if absent.
lcars_config_get() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 0
  sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$config" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# lcars_config_set_string — overwrite the JSON value of ONE top-level key with a
# (JSON-escaped) string, preserving every other line, key order, and the file's
# trailing-comma structure. jq-free, line-oriented (relies on the one-key-per-line
# layout lcars_config_merge writes). Unlike lcars_config_merge this DELIBERATELY
# replaces an existing value — use it only for targeted, fingerprinted migrations.
lcars_config_set_string() {
  local config="$1" key="$2" value="$3"
  [ -f "$config" ] || return 1
  local esc; esc="$(lcars_json_escape "$value")"
  local tmp="$config.tmp.$$"
  local line indent comma
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"\"$key\""*:*)
        comma=""; case "$line" in *,) comma="," ;; esac
        indent="${line%%\"*}"
        printf '%s"%s": "%s"%s\n' "$indent" "$key" "$esc" "$comma"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done <"$config" >"$tmp"
  mv "$tmp" "$config"
}

# lcars_config_merge — write config.json preserving existing keys.
#
# Args:
#   $1  path to config.json (may not yet exist)
#   $2  newline-separated "key=jsonvalue" desired pairs, in the canonical key
#       order. Each jsonvalue is already JSON-formatted (quoted string, number,
#       null) by the caller.
#
# For each desired key: if the existing config already has it, the EXISTING raw
# JSON value is preserved; otherwise the supplied default jsonvalue is written.
# Keys present in the file but not in the desired list are dropped (the desired
# list is the canonical schema) — but every current key IS in the schema, so in
# practice nothing the captain set is lost.
#
# Sets for the caller to report on:
#   LCARS_CONFIG_ADDED_KEYS    space-separated keys newly added this write
#   LCARS_CONFIG_PRESENT_KEYS  space-separated keys preserved from existing
lcars_config_merge() {
  local config="$1" desired="$2"
  LCARS_CONFIG_ADDED_KEYS=""
  LCARS_CONFIG_PRESENT_KEYS=""

  local existing=""
  [ -f "$config" ] && existing="$(cat "$config")"

  local body="" key default rawval
  while IFS='=' read -r key default; do
    [ -n "$key" ] || continue
    if [ -n "$existing" ] && printf '%s' "$existing" | grep -q "\"$key\"[[:space:]]*:"; then
      # Preserve the existing raw value verbatim (string, number, or null).
      rawval="$(printf '%s' "$existing" \
        | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\(.*\)/\1/p" | head -1)"
      # Strip a trailing comma and surrounding whitespace from the captured tail.
      rawval="${rawval%,}"
      rawval="$(printf '%s' "$rawval" | sed 's/[[:space:]]*$//')"
      LCARS_CONFIG_PRESENT_KEYS="${LCARS_CONFIG_PRESENT_KEYS:+$LCARS_CONFIG_PRESENT_KEYS }$key"
    else
      rawval="$default"
      LCARS_CONFIG_ADDED_KEYS="${LCARS_CONFIG_ADDED_KEYS:+$LCARS_CONFIG_ADDED_KEYS }$key"
    fi
    body="${body:+$body,$'\n'}  \"$key\": $rawval"
  done <<EOF
$desired
EOF

  printf '{\n%s\n}\n' "$body" >"$config"
}

# ---------------------------------------------------------------------------
# WORKTREE PROVISIONING DEFAULT (ecosystem detection)
# ---------------------------------------------------------------------------
# `lcars run` provisions each Stage's isolated git worktree by running the
# config's `worktreeSetupCommand` ONCE with the worktree as CWD (via `bash -c`).
# A fresh worktree shares the object store but NOT the main checkout's
# uncommitted/gitignored installed deps (node_modules, venv), so a Stage that
# needs the test runner installed would otherwise break. This emits a sensible
# per-ecosystem default that REUSES what the main checkout already has —
# symlinking its node_modules (root + each pnpm-workspace package) into the
# worktree, falling back to an OFFLINE, lockfile-frozen install when the main
# checkout has none. No network, no special cache.
#
# Shared by BOTH `lcars init` (seed on first setup) and `lcars update` (backfill
# the key into an older config) so the default can never drift between them.
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# init's detect_test_cmd.
#
# IMPORTANT: the emitted string is a SINGLE shell command whose `$MAIN` / `$(…)`
# must be evaluated AT PROVISION TIME in the worktree — NOT now. It is therefore
# emitted as a single-quoted literal (no expansion here); the caller stores it
# via lcars_json_escape (valid JSON) and the runtime `bash -c` expands it. Empty
# when LCARS can't infer a safe default (Python/Rust/Go/Make/bash/none) — the
# provisioner then warns and skips rather than running a command that errors.
detect_worktree_setup_cmd() {
  # JS/TS: symlink the main checkout's node_modules (root + every pnpm workspace
  # package's own, which nests its .bin), else an offline lockfile-frozen install.
  if [ -f "$TOPLEVEL/package.json" ]; then
    local install
    if [ -f "$TOPLEVEL/pnpm-lock.yaml" ] || [ -f "$TOPLEVEL/pnpm-workspace.yaml" ]; then
      install='pnpm install --frozen-lockfile --prefer-offline --silent'
    elif [ -f "$TOPLEVEL/yarn.lock" ]; then
      install='yarn install --immutable'
    else
      install='npm ci'
    fi
    # find symlinks EVERY node_modules that is not nested inside another one
    # (-prune halts the descent at each match), recreating its path relative to
    # the main checkout inside the worktree. Generic across npm/yarn/pnpm.
    printf '%s\n' 'MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ]; then find "$MAIN" -path "$MAIN/.git" -prune -o -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else '"$install"'; fi'
    return
  fi
  # Python and everything else: no single offline-safe string we can guarantee —
  # emit empty and let the provisioner warn (never emit a command that errors).
  echo ""
}

# ---------------------------------------------------------------------------
# TEST-COMMAND DETECTION (S146: moved here from init.sh so the readiness
# verdict below — shared by init, update, status AND the viewscreen daemon —
# can consult the SAME detector. Byte-identical logic; init.sh still calls it.)
# ---------------------------------------------------------------------------
# The Implement red gate (BUG-007) runs testCommand to prove the fail-first
# suite FAILS before the Implementer runs — scoped to $LCARS_TESTS_DIR. We emit
# a $LCARS_TESTS_DIR-honouring default per ecosystem. Reads $TOPLEVEL from the
# caller's environment. Empty when nothing can be detected.
# The vitest test command must RELATIVIZE $LCARS_TESTS_DIR to the runner's cwd
# (vitest's positional filter is package-root-relative; the gate exports an
# ABSOLUTE path) — stripping a leading "$PWD/" turns it package-relative.
VITEST_RELATIVIZING_CMD='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'

# detect_workspace_runner — name the local test runner a monorepo actually uses,
# so the workspace fallback emits a runner-SCOPED command instead of a bare
# `npm test` fan-out. Inspects (in order) a runner config at the workspace root,
# the pnpm lockfile, then every sub-package's package.json devDependencies.
# Echoes vitest|jest|mocha (empty when none found).
detect_workspace_runner() {
  local r
  for r in vitest jest mocha; do
    ls "$TOPLEVEL/$r.config".* >/dev/null 2>&1 && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -qs -- "$r" "$TOPLEVEL/pnpm-lock.yaml" 2>/dev/null && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -rqs --include='package.json' --exclude-dir='node_modules' -- "\"$r\"" "$TOPLEVEL" 2>/dev/null \
      && { echo "$r"; return; }
  done
  echo ""
}

detect_test_cmd() {
  if [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json"; then
    # Monorepo (a pnpm workspace, or a "workspaces" field): a bare `npm test` /
    # `pnpm -r test` here FANS OUT across every package, so the red gate can never
    # scope itself to the touched package's quarantined tests. Prefer a command
    # scoped to the local runner that STILL honours $LCARS_TESTS_DIR — LCARS points
    # the var at the touched package (it knows it from the plan/manifests). When the
    # root "test" script doesn't name the runner, DETECT it from the sub-packages
    # (lockfile / config / devDependencies) rather than emitting a fan-out.
    if [ -f "$TOPLEVEL/pnpm-workspace.yaml" ] || grep -q '"workspaces"[[:space:]]*:' "$TOPLEVEL/package.json"; then
      local script runner
      script="$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)"
      case "$script" in
        *vitest*) echo "$VITEST_RELATIVIZING_CMD";              return ;;
        *jest*)   echo 'npx jest ${LCARS_TESTS_DIR:-}';         return ;;
        *mocha*)  echo 'npx mocha ${LCARS_TESTS_DIR:-}';        return ;;
        *)
          runner="$(detect_workspace_runner)"
          case "$runner" in
            vitest) echo "$VITEST_RELATIVIZING_CMD";            return ;;
            jest)   echo 'npx jest ${LCARS_TESTS_DIR:-}';       return ;;
            mocha)  echo 'npx mocha ${LCARS_TESTS_DIR:-}';      return ;;
            *)      echo 'npm test -- ${LCARS_TESTS_DIR:-}';    return ;;
          esac ;;
      esac
    fi
    # Single package: a vitest runner needs the RELATIVIZING positional (same abs-
    # path bug as the monorepo); jest/mocha/other keep the `npm test --` positional
    # default (empty runs the suite).
    case "$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)" in
      *vitest*) echo "$VITEST_RELATIVIZING_CMD"; return ;;
    esac
    echo 'npm test -- ${LCARS_TESTS_DIR:-}'; return; fi
  if [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ]; then
    echo 'pytest ${LCARS_TESTS_DIR:-.}'; return; fi
  if [ -f "$TOPLEVEL/Cargo.toml" ]; then echo "cargo test"; return; fi
  if [ -f "$TOPLEVEL/go.mod" ]; then echo "go test ./..."; return; fi
  # Ruby (S145): pick the runner from the layout. rspec when the Gemfile names it
  # or a spec/ dir exists; minitest via `rake test` when a test/ dir + Rakefile are
  # present. A Gemfile prefixes `bundle exec`. When BOTH an rspec (spec/) and a
  # minitest (test/ + Rakefile) layout are present WITHOUT a decisive Gemfile rspec
  # signal, the runner is internally AMBIGUOUS: emit NO command (the caller warns,
  # naming both) rather than guess. A gem library with only a *.gemspec/Rakefile and
  # no spec//test/ also emits nothing. Reached only for a single-stack ruby repo.
  if [ -f "$TOPLEVEL/Gemfile" ] || [ -f "$TOPLEVEL/Rakefile" ] || [ -f "$TOPLEVEL/config.ru" ] \
     || [ -d "$TOPLEVEL/spec" ] || ls "$TOPLEVEL"/*.gemspec >/dev/null 2>&1; then
    local rb_prefix="" rb_rspec=0 rb_mini=0 rb_gem_rspec=0
    [ -f "$TOPLEVEL/Gemfile" ] && rb_prefix="bundle exec "
    { [ -f "$TOPLEVEL/Gemfile" ] && grep -q 'rspec' "$TOPLEVEL/Gemfile"; } && rb_gem_rspec=1
    { [ "$rb_gem_rspec" = 1 ] || [ -d "$TOPLEVEL/spec" ]; } && rb_rspec=1
    { [ -d "$TOPLEVEL/test" ] && [ -f "$TOPLEVEL/Rakefile" ]; } && rb_mini=1
    # A Gemfile explicitly naming rspec is decisive even if a test/ dir also exists.
    [ "$rb_gem_rspec" = 1 ] && rb_mini=0
    if [ "$rb_rspec" = 1 ] && [ "$rb_mini" = 1 ]; then echo ""; return; fi
    if [ "$rb_rspec" = 1 ]; then echo "${rb_prefix}rspec"; return; fi
    if [ "$rb_mini" = 1 ];  then echo "${rb_prefix}rake test"; return; fi
    echo ""; return
  fi
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile"; then echo "make test"; return; fi
  # A bash test runner (LCARS dogfoods its own tests/run.sh). It already resolves
  # a positional dir / $LCARS_TESTS_DIR (BUG-009), so scope it to the quarantined
  # tests when the var is set, else the whole `tests` dir for a human. Checked LAST
  # so a real ecosystem (npm/pytest/…) always wins when both are present.
  if [ -f "$TOPLEVEL/tests/run.sh" ]; then
    echo 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'; return; fi
  echo ""
}

# ---------------------------------------------------------------------------
# STACK DETECTION (S105 — multi-stack breadth)
# ---------------------------------------------------------------------------
# detect_stack — inspect the repo's TOP LEVEL for language/build markers and echo
# ONE stack id. The id is the classifier key the S104 `lcars run` arms are keyed
# by (rust/go/python/js/dotnet/jvm), so seeding it into config.json lets every
# downstream stage know the mission's ecosystem without re-sniffing.
#
# Marker → id:
#   Cargo.toml                                   → rust
#   go.mod                                       → go
#   pyproject.toml / setup.py                    → python
#   package.json                                 → js
#   *.csproj / *.sln                             → dotnet
#   pom.xml / build.gradle / build.gradle.kts    → jvm
#   Gemfile / *.gemspec / Rakefile / config.ru   → ruby
#
# Several DISTINCT stacks present   → ambiguous(<comma-list, in detection order>)
# NONE present                      → unknown
#
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# detect_worktree_setup_cmd / init's detect_test_cmd. POSIX/bash-3.2 portable and
# nullglob-safe: glob markers (*.csproj, build.gradle*) are probed with a
# `for f in …; do [ -e "$f" ]` guard so an UNMATCHED glob (which stays a literal
# under bash-3.2) can never false-positive. Shared by BOTH `lcars init` and
# `lcars update` so the two can never disagree on a repo's stack.
detect_stack() {
  local candidates="" f matched

  [ -f "$TOPLEVEL/Cargo.toml" ] && candidates="$candidates rust"
  [ -f "$TOPLEVEL/go.mod" ]     && candidates="$candidates go"
  { [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/setup.py" ]; } \
    && candidates="$candidates python"
  [ -f "$TOPLEVEL/package.json" ] && candidates="$candidates js"

  # dotnet — any *.csproj or *.sln at the top level (nullglob-safe glob probe).
  matched=0
  for f in "$TOPLEVEL"/*.csproj "$TOPLEVEL"/*.sln; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates dotnet"

  # jvm — Maven (pom.xml) or Gradle (build.gradle / build.gradle.kts).
  matched=0
  for f in "$TOPLEVEL"/pom.xml "$TOPLEVEL"/build.gradle "$TOPLEVEL"/build.gradle.kts; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates jvm"

  # ruby (S145) — Gemfile / *.gemspec / Rakefile / config.ru (nullglob-safe probe;
  # an unmatched *.gemspec glob stays literal under bash-3.2, so the -e guard keeps
  # it from false-positiving). A spec/ or test/ dir is runner evidence (seed side),
  # never a stack marker on its own.
  matched=0
  for f in "$TOPLEVEL"/Gemfile "$TOPLEVEL"/*.gemspec "$TOPLEVEL"/Rakefile "$TOPLEVEL"/config.ru; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates ruby"

  # Strip the leading space and split on whitespace to count distinct stacks.
  # shellcheck disable=SC2086
  set -- $candidates
  case $# in
    0) echo "unknown" ;;
    1) echo "$1" ;;
    *) echo "ambiguous($(echo "$candidates" | sed 's/^ *//; s/ /,/g'))" ;;
  esac
}

# ---------------------------------------------------------------------------
# TEST READINESS — the ONE verdict (S146)
# ---------------------------------------------------------------------------
# lcars_test_readiness — compute the repo's test-readiness verdict, CHEAP by
# construction: no test run, no network, no worker. The four states:
#
#   ready    testCommand set AND its first token resolves via `command -v`
#   missing  testCommand null/absent, detection has a candidate (suggestion)
#   broken   testCommand set but its first token does NOT resolve
#   unknown  testCommand null/absent AND no candidate (stack unknown/ambiguous,
#            or a detected stack whose runner can't be pinned) — the greenfield
#            state: EXPECTED, not an alarm.
#
# Shared by `lcars init`/`lcars update`/`lcars status` (they source this file)
# and by the viewscreen daemon (via skills/lcars-init/readiness.sh), so CLI and
# board can never disagree. It NEVER writes anything — the sanctioned writers
# are `lcars update --test-command|--fix-tests` alone.
#
# Args: $1 = path to config.json. Reads $TOPLEVEL (repo root) for detection and
# for resolving a relative runner path. Sets, for the caller:
#   LCARS_TESTREADY_STATUS      ready|missing|broken|unknown
#   LCARS_TESTREADY_TESTCMD     the stored testCommand ("" when null/absent)
#   LCARS_TESTREADY_SUGGESTION  the detected candidate ("" unless status=missing)
lcars_test_readiness() {
  local config="$1"
  LCARS_TESTREADY_STATUS=""
  LCARS_TESTREADY_TESTCMD=""
  LCARS_TESTREADY_SUGGESTION=""

  local tc=""
  [ -f "$config" ] && tc="$(lcars_config_get "$config" testCommand)"

  if [ -n "$tc" ]; then
    LCARS_TESTREADY_TESTCMD="$tc"
    # First token of the command (no glob expansion — `read` splits safely).
    local first rest
    read -r first rest <<EOF2
$tc
EOF2
    # Resolve from the repo root so a relative runner (node_modules/.bin/…)
    # resolves the way the gate would run it.
    if ( cd "${TOPLEVEL:-.}" 2>/dev/null && command -v "$first" >/dev/null 2>&1 ); then
      LCARS_TESTREADY_STATUS="ready"
    else
      LCARS_TESTREADY_STATUS="broken"
    fi
    return 0
  fi

  # No command stored: does detection have a candidate? Mirror init's seeding
  # rule EXACTLY (S105): only an AMBIGUOUS multi-stack repo refuses to guess;
  # an unknown stack still consults detect_test_cmd (Makefile / tests/run.sh
  # repos have a perfectly detectable runner without a stack id).
  local stack cand=""
  stack="$(detect_stack)"
  case "$stack" in
    ambiguous*) cand="" ;;
    *)          cand="$(detect_test_cmd)" ;;
  esac
  if [ -n "$cand" ]; then
    LCARS_TESTREADY_STATUS="missing"
    LCARS_TESTREADY_SUGGESTION="$cand"
  else
    LCARS_TESTREADY_STATUS="unknown"
  fi
  return 0
}

# lcars_readiness_line — render the ONE human status line for the verdict the
# globals above carry. Ship-status voice (never a config lecture):
#   ready    → EMPTY (ready repos are silent everywhere — zero chrome drift)
#   broken/  → the REPAIR voice: ⚠ TEST SYSTEMS OFFLINE + the one-click fix verb
#   missing
#   unknown  → the BOOTSTRAP voice: a greenfield repo is EXPECTED, not an alarm —
#              reads as status, never an action item.
# The two unready voices must NEVER blur (captain ruling, S146).
lcars_readiness_line() {
  case "${LCARS_TESTREADY_STATUS:-}" in
    broken)
      printf '⚠ TEST SYSTEMS OFFLINE — testCommand runner "%s" not operational; missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$(printf '%s' "$LCARS_TESTREADY_TESTCMD" | awk '{print $1}')"
      ;;
    missing)
      printf '⚠ TEST SYSTEMS OFFLINE — no test command configured (detected candidate: %s); missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_SUGGESTION"
      ;;
    unknown)
      printf '◇ NO TEST SYSTEMS FOUND — a greenfield repo; the first mission%s engineering crew will establish them.\n' "'s"
      ;;
    *) : ;;  # ready (or uncomputed) → silent
  esac
}

# lcars_config_set_or_add_string — the sanctioned-writer primitive: overwrite a
# top-level string key IN PLACE (lcars_config_set_string), or — when the key is
# absent from an older config — INSERT it as the first key after the opening
# brace. Line-oriented and jq-free like its siblings; every other line is
# preserved byte-for-byte.
lcars_config_set_or_add_string() {
  local config="$1" key="$2" value="$3"
  [ -f "$config" ] || return 1
  if lcars_config_has_key "$config" "$key"; then
    lcars_config_set_string "$config" "$key" "$value"
    return $?
  fi
  local esc; esc="$(lcars_json_escape "$value")"
  local tmp="$config.tmp.$$" line inserted=0
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    if [ "$inserted" -eq 0 ]; then
      case "$line" in
        '{'*)
          printf '  "%s": "%s",\n' "$key" "$esc"
          inserted=1
          ;;
      esac
    fi
  done <"$config" >"$tmp"
  mv "$tmp" "$config"
}
