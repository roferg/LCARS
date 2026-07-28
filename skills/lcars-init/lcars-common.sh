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
    local install lock
    if [ -f "$TOPLEVEL/pnpm-lock.yaml" ] || [ -f "$TOPLEVEL/pnpm-workspace.yaml" ]; then
      install='pnpm install --frozen-lockfile --prefer-offline --silent'
      lock='pnpm-lock.yaml'
    elif [ -f "$TOPLEVEL/yarn.lock" ]; then
      install='yarn install --immutable'
      lock='yarn.lock'
    else
      install='npm ci'
      lock='package-lock.json'
    fi
    # THE LOCKFILE GUARD comes first: reusing the main checkout's node_modules is
    # only correct while this worktree wants the SAME dependencies. A ticket that
    # changes the lockfile makes the shared install the WRONG set by definition,
    # and symlinking it would test the ticket against packages its own commit
    # replaced — a failure no committed change could ever repair, which then reads
    # downstream as "the implementation is not present". Diverged ⇒ real install.
    #
    # find symlinks EVERY node_modules that is not nested inside another one
    # (-prune halts the descent at each match), recreating its path relative to
    # the main checkout inside the worktree. Generic across npm/yarn/pnpm.
    printf '%s\n' 'MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ] && [ -f '"$lock"' ] && [ -f "$MAIN/'"$lock"'" ] && ! cmp -s '"$lock"' "$MAIN/'"$lock"'"; then '"$install"'; elif [ -d "$MAIN/node_modules" ]; then find "$MAIN" -path "$MAIN/.git" -prune -o -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else '"$install"'; fi'
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
#
# S148 — QUOTE THE SCOPE. Every seeded command interpolates $LCARS_TESTS_DIR as
# the positional scope, and the gate exports it as an ABSOLUTE path. Interpolated
# UNQUOTED, that path WORD-SPLITS on IFS whitespace the moment the repo is checked
# out somewhere containing a space or a tab: `node --test ${LCARS_TESTS_DIR:-}`
# with a scope of `/x/sp test/src/calc.test.js` hands the runner TWO arguments,
# `/x/sp` and `test/src/calc.test.js`, and the flip-flop proof gate then FALSE-
# FAILS a perfectly honest ticket purely because of WHERE the repo lives (which
# bounces it to a fresh worker up to 3 times and then parks it awaiting-human).
#
# The two quoting shapes below are NOT interchangeable, and which one an arm takes
# is decided by its DEFAULT, not by taste:
#   `"${LCARS_TESTS_DIR:-<default>}"`   when the default is NON-EMPTY (pytest's
#       `.`, the bash runner's `tests`) — always exactly one argument either way.
#   `${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}`  when the default is EMPTY. Writing
#       `"${LCARS_TESTS_DIR:-}"` here would quote it but ALSO hand the runner an
#       EMPTY positional argument when the scope is unset — a different run (mocha
#       errors on it, npm forwards it to the script), i.e. a behaviour change
#       smuggled in under a quoting fix. `:+` keeps "no scope ⇒ no argument"
#       byte-for-byte and is the idiom VITEST_RELATIVIZING_CMD above already uses.
# Every seeded command is otherwise unchanged; the only delta is the quoting.
# `lcars update` migrates the already-persisted unquoted strings (update.sh).

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

# detect_dotnet_test_projects (S147) — echo every TEST project in the repo, one
# $TOPLEVEL-relative *.csproj path per line (LC_ALL=C sorted, so the "exactly
# one" decision is deterministic). A project counts as a TEST project when it
# either references `Microsoft.NET.Test.Sdk` (the real signal — every xunit /
# nunit / mstest template adds it) OR carries the `*Tests*.csproj` naming
# convention (a hand-rolled project that inherits the ref from Directory.Build
# .props still reads as a test project). `bin/` and `obj/` are EXCLUDED: a build
# leaves copies of the csproj under obj/, and counting those would make every
# already-built repo look "ambiguous". Reads $TOPLEVEL like its siblings.
detect_dotnet_test_projects() {
  find "$TOPLEVEL" -type d \( -name bin -o -name obj -o -name .git \) -prune -o \
       -type f -name '*.csproj' -print 2>/dev/null \
  | LC_ALL=C sort \
  | while IFS= read -r p; do
      [ -n "$p" ] || continue
      dotnet_csproj_is_test "$p" && printf '%s\n' "${p#"$TOPLEVEL/"}"
    done
}

# dotnet_csproj_is_test — is this *.csproj a TEST project? It either references
# `Microsoft.NET.Test.Sdk` (the real signal — every xunit / nunit / mstest
# template adds it) or carries the `*Tests*.csproj` naming convention (a
# hand-rolled project inheriting the ref from Directory.Build.props still reads
# as a test project). The ONE predicate both the marker probe and the seed
# enumeration use, so they can never disagree about what a test system is.
# The Test.Sdk match is CASE-INSENSITIVE: NuGet package ids are, so a hand-
# written `microsoft.net.test.sdk` reference is a perfectly valid test project
# and used to fall through to the greenfield "no test systems found" voice.
dotnet_csproj_is_test() { # abs csproj path
  case "${1##*/}" in *Tests*.csproj) return 0 ;; esac
  grep -qi 'Microsoft\.NET\.Test\.Sdk' "$1" 2>/dev/null
}

# detect_dotnet_markers (S147) — does this repo look like a .NET repo at all?
# 0 = yes. TWO rules, deliberately different in strength:
#
#   TOP LEVEL — any *.csproj / *.sln / *.slnx counts, whatever it contains.
#     This is the pre-147 rule, kept BYTE-IDENTICAL: a repo whose root is a C#
#     project is a C# repo, full stop.
#
#   BELOW IT — a bounded scan that counts a project ONLY when it is an actual
#     TEST SYSTEM. The recursion exists for one reason: the single most common
#     C# layout on earth, `dotnet new xunit -o MyApp.Tests`, puts the only
#     project ONE DIRECTORY DOWN and writes no root solution, so a top-level-only
#     glob read it as stack:unknown and told the captain the repo was greenfield.
#     Counting *any* nested csproj overshot badly: a vendored C# sample or a
#     `tools/` helper flipped a healthy js/python/rust repo to `ambiguous` and
#     REMOVED its working seed — and the verdict contradicted itself, offering
#     one candidate while insisting it would not choose between them. A bare
#     .csproj with no test SDK reference is not a test system, so it is not a
#     signal; a nested *Tests* project still is. Nested solutions do not count
#     at all (a .sln says nothing about tests).
#
# Bounded and cheap: `$DOTNET_MARKER_MAXDEPTH`, `bin`/`obj`/`.git`/`node_modules`
# pruned (a build leaves csproj copies under obj/), stops at the first hit.
#
# WHERE EACH SCAN LOOKS, stated once, because the two scans deliberately differ:
#   • THIS probe is bounded, because it runs on EVERY repo — including every
#     js/python/rust one that will never be .NET — on every detection and every
#     board render. It is a hot path and must stay cheap.
#   • detect_dotnet_test_projects is EXHAUSTIVE (no maxdepth), because it runs
#     only once a repo is already known to be .NET, and a solution may legitimately
#     nest its test projects deeper than this bound. Bounding it too would make a
#     repo detect as dotnet and then seed nothing, which is strictly worse.
# The two agree on WHAT a test system is (dotnet_csproj_is_test, the single
# predicate); they differ on WHERE only, for the reason above.
#
# LEDGERED (recorded, not fixed): a test project deeper than the bound, in a repo
# with no top-level marker, still reads as greenfield — the surface asserts
# absence ("no test systems found") rather than admitting it only looked
# `$DOTNET_MARKER_MAXDEPTH` levels down. Raising the bound trades that for a
# slower scan on every board render; revisit with a real repo that needs it.
#
# KEEP IN STEP with `_DETECT_MARKER_GLOBS`/`_DETECT_MARKER_RGLOBS` in
# web/lcars_serve/local_adapter.py — the board's memo must move when these do,
# or CLI and board drift apart (the S146 D2 contract).
DOTNET_MARKER_MAXDEPTH=3
detect_dotnet_markers() {
  local f p
  for f in "$TOPLEVEL"/*.csproj "$TOPLEVEL"/*.sln "$TOPLEVEL"/*.slnx; do
    [ -e "$f" ] && return 0
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    dotnet_csproj_is_test "$p" && return 0
  done <<DN_MARK
$(find "$TOPLEVEL" -maxdepth "$DOTNET_MARKER_MAXDEPTH" \
    -type d \( -name bin -o -name obj -o -name .git -o -name node_modules \) -prune -o \
    -type f -name '*.csproj' -print 2>/dev/null)
DN_MARK
  return 1
}

# ---------------------------------------------------------------------------
# The per-stack seed ARMS (S147). detect_test_cmd used to be one long if-chain;
# each ecosystem's rule now lives in its own `_dtc_<stack>` helper and the chain
# just walks them IN THE SAME ORDER, so behaviour is unchanged for every stack.
# The split exists so ONE stack's rule can be asked in isolation
# (detect_test_cmd_for_stack) — which is how an AMBIGUOUS repo can offer the
# captain a real command per candidate instead of hiring a discovery worker.
#
# CONTRACT: an arm returns 0 when it CLAIMS the repo (stdout = the command,
# possibly EMPTY when that stack is internally ambiguous and must not be
# guessed) and 1 when it does not apply, letting the chain continue. That
# distinction is what lets dotnet-with-no-test-project fall THROUGH to the
# generic Makefile / tests/run.sh fallbacks it always used to reach.
# ---------------------------------------------------------------------------
_dtc_js() {
  [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json" || return 1
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
        *jest*)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';         return ;;
        *mocha*)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';        return ;;
        *)
          runner="$(detect_workspace_runner)"
          case "$runner" in
            vitest) echo "$VITEST_RELATIVIZING_CMD";            return ;;
            jest)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';       return ;;
            mocha)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';      return ;;
            *)      echo 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';    return ;;
          esac ;;
      esac
    fi
    # Single package: a vitest runner needs the RELATIVIZING positional (same abs-
    # path bug as the monorepo); jest/mocha/other keep the `npm test --` positional
    # default (empty runs the suite).
    case "$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)" in
      *vitest*) echo "$VITEST_RELATIVIZING_CMD"; return ;;
    esac
    echo 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'; return 0
}

_dtc_python() {
  [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ] || return 1
  echo 'pytest "${LCARS_TESTS_DIR:-.}"'
}

_dtc_rust() { [ -f "$TOPLEVEL/Cargo.toml" ] || return 1; echo "cargo test"; }
_dtc_go()   { [ -f "$TOPLEVEL/go.mod" ]     || return 1; echo "go test ./..."; }

# dotnet/C# (S147): `dotnet test` is project-oriented, not directory-oriented —
# it wants the TEST PROJECT, so the seed names it explicitly (a bare `dotnet
# test` from the root either finds nothing or fans out across the solution).
# Exactly ONE test project seeds; SEVERAL is internally AMBIGUOUS — emit NO
# command (the caller warns, naming them all, per the S105 idiom) rather than
# pick one by sort order.
#
# The arm CLAIMS the repo only when a dotnet TEST PROJECT was actually found.
# Claiming on the mere presence of a marker was a regression: a repo with
# `App.csproj` plus a Makefile `test:` target seeded `make test` before S147 and
# suddenly seeded nothing — S147 is supposed to ADD dotnet's missing legs, never
# to take an existing arm's answer away. With no test project it returns 1 and
# the chain falls through to the pre-existing fallbacks exactly as it always did.
_dtc_dotnet() {
  detect_dotnet_markers || return 1
  local dn_projs dn_n
  dn_projs="$(detect_dotnet_test_projects | grep . || :)"
  # NB: `grep -c` exits 1 on a zero count, hence the `|| :` and the numeric guard.
  dn_n="$(printf '%s' "$dn_projs" | grep -c . || :)"
  case "$dn_n" in ''|*[!0-9]*) dn_n=0 ;; esac
  [ "$dn_n" -ge 1 ] || return 1
  [ "$dn_n" -eq 1 ] && { echo "dotnet test $dn_projs"; return 0; }
  echo ""   # several → claimed, but deliberately no command
}

# Ruby (S145): pick the runner from the layout. rspec when the Gemfile names it
# or a spec/ dir exists; minitest via `rake test` when a test/ dir + Rakefile are
# present. A Gemfile prefixes `bundle exec`. When BOTH an rspec (spec/) and a
# minitest (test/ + Rakefile) layout are present WITHOUT a decisive Gemfile rspec
# signal, the runner is internally AMBIGUOUS: emit NO command (the caller warns,
# naming both) rather than guess. A gem library with only a *.gemspec/Rakefile and
# no spec//test/ also emits nothing. Reached only for a single-stack ruby repo.
_dtc_ruby() {
  [ -f "$TOPLEVEL/Gemfile" ] || [ -f "$TOPLEVEL/Rakefile" ] || [ -f "$TOPLEVEL/config.ru" ] \
    || [ -d "$TOPLEVEL/spec" ] || ls "$TOPLEVEL"/*.gemspec >/dev/null 2>&1 || return 1
  local rb_prefix="" rb_rspec=0 rb_mini=0 rb_gem_rspec=0
  [ -f "$TOPLEVEL/Gemfile" ] && rb_prefix="bundle exec "
  { [ -f "$TOPLEVEL/Gemfile" ] && grep -q 'rspec' "$TOPLEVEL/Gemfile"; } && rb_gem_rspec=1
  { [ "$rb_gem_rspec" = 1 ] || [ -d "$TOPLEVEL/spec" ]; } && rb_rspec=1
  { [ -d "$TOPLEVEL/test" ] && [ -f "$TOPLEVEL/Rakefile" ]; } && rb_mini=1
  # A Gemfile explicitly naming rspec is decisive even if a test/ dir also exists.
  [ "$rb_gem_rspec" = 1 ] && rb_mini=0
  if [ "$rb_rspec" = 1 ] && [ "$rb_mini" = 1 ]; then echo ""; return 0; fi
  if [ "$rb_rspec" = 1 ]; then echo "${rb_prefix}rspec"; return 0; fi
  if [ "$rb_mini" = 1 ];  then echo "${rb_prefix}rake test"; return 0; fi
  echo ""
}

# The generic runners, checked LAST so a real ecosystem always wins. A bash test
# runner (LCARS dogfoods its own tests/run.sh) already resolves a positional dir
# / $LCARS_TESTS_DIR (BUG-009), so scope it to the quarantined tests when the var
# is set, else the whole `tests` dir for a human.
_dtc_generic() {
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile"; then
    echo "make test"; return 0; fi
  if [ -f "$TOPLEVEL/tests/run.sh" ]; then
    echo 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'; return 0; fi
  return 1
}

# The arm ORDER — the pre-147 if-chain order, preserved exactly.
DETECT_TEST_CMD_ARMS="js python rust go dotnet ruby generic"

detect_test_cmd() {
  local arm out
  for arm in $DETECT_TEST_CMD_ARMS; do
    if out="$("_dtc_$arm")"; then printf '%s\n' "$out"; return 0; fi
  done
  echo ""
}

# detect_test_cmd_for_stack <stack> — ONE stack's seed rule, asked in isolation.
# Used to offer a real command per candidate on an AMBIGUOUS repo, so choosing
# never costs a discovery worker. Empty when that stack has no rule here or
# cannot pin a runner.
detect_test_cmd_for_stack() {
  case " $DETECT_TEST_CMD_ARMS " in
    *" $1 "*) "_dtc_$1" 2>/dev/null || printf '' ;;
    *)        printf '' ;;
  esac
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

  # dotnet — any *.csproj, *.sln or *.slnx, at the top level or within the
  # bounded marker depth (detect_dotnet_markers). S147: `.slnx` is the XML
  # solution format .NET 10's `dotnet new sln` now emits by default, and the
  # canonical `dotnet new xunit -o MyApp.Tests` layout keeps its only project one
  # directory down with no root solution at all — both OBSERVED in-session with
  # SDK 10.0.107, and both read as `unknown` under a top-level-only glob. Purely
  # ADDITIVE: every path that matched before still matches.
  detect_dotnet_markers && candidates="$candidates dotnet"

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
# TEST PROBE — the ONE live run (shared by `lcars update` and `lcars init`)
# ---------------------------------------------------------------------------
# lcars_test_readiness (below) is CHEAP: it never runs anything, so "ready"
# means the COMMAND resolves, not that the SUITE works. This is the other half
# — an actual bounded run — for the one-off callers that can afford it.

# run_probe <cmd> — run the test command ONCE from the repo root, BOUNDED by
# $LCARS_PROBE_TIMEOUT (default 120s; perl's alarm survives exec, so the timer
# rides into the spawned bash). Sets PROBE_OUTCOME (pass|fail|zero-collected|
# timeout), PROBE_RC, and PROBE_OUT (captured-output file). Zero-collected is
# its OWN honest outcome, never a pass — the signature REUSES the rg_signature
# `zerotests` + proof_zero_collected phrasings from skills/lcars-run/run.sh
# (keep the two in step).
PROBE_TIMEOUT="${LCARS_PROBE_TIMEOUT:-120}"
run_probe() {
  local cmd="$1"
  PROBE_OUT="$(mktemp "${TMPDIR:-/tmp}/lcars-probe.XXXXXX")"
  ( cd "$TOPLEVEL" && perl -e 'alarm shift; exec @ARGV or exit 127' \
      "$PROBE_TIMEOUT" bash -c "$cmd" ) >"$PROBE_OUT" 2>&1
  PROBE_RC=$?
  # S147: THREE VSTest phrasings, all exiting 0 (observed, SDK 10.0.107) — a
  # filter that matches nothing, a test project with no test methods, and a run
  # whose every discovered case was SKIPPED (`[Fact(Skip=…)]`), which prints
  # neither "no test" phrase and used to read here as "the suite ran and passed".
  # They are the dotnet green-on-nothing trap, so the probe names them too; the
  # skipped form keys on the NUMBERS (zero failed AND zero passed) so a real
  # 1-passed/1-skipped run stays a pass. Keep in step with rg_signature
  # `zerotests` + proof_zero_collected in skills/lcars-run/run.sh.
  local zero='No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items|(^|[^0-9])0 examples, 0 failures$|(^|[^0-9])0 runs, 0 assertions|no tests to run|test result: ok\. 0 passed|^No test matches the given testcase filter .*\.dll|^No test is available in .*\.dll|^(Passed|Failed|Skipped)! +- +Failed: +0, +Passed: +0,'
  # S147: MSBuild never even REACHED a test run — the project/solution the
  # command names is not there. Reporting that as "the suite ran but reported
  # failures" sends the captain hunting a test failure that does not exist.
  local cantrun='^MSBUILD : error MSB100[39]:'
  if [ "$PROBE_RC" -eq 142 ]; then          # 128 + SIGALRM(14): the alarm fired
    PROBE_OUTCOME="timeout"
  elif grep -Eq "$cantrun" "$PROBE_OUT"; then
    PROBE_OUTCOME="cannot-run"
  elif grep -Eq "$zero" "$PROBE_OUT"; then  # runner finished but ran NOTHING
    PROBE_OUTCOME="zero-collected"
  elif [ "$PROBE_RC" -eq 0 ]; then
    PROBE_OUTCOME="pass"
  else
    PROBE_OUTCOME="fail"
  fi
}

# report_probe — the ship-status readout for the last run_probe.
report_probe() {
  case "$PROBE_OUTCOME" in
    pass)
      echo "  ✓ PROBE COMPLETE — test systems responding: the suite ran and passed." ;;
    fail)
      echo "  ✗ PROBE FAILED — the suite ran but reported failures (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    zero-collected)
      echo "  ⚠ PROBE INCONCLUSIVE — the runner started but collected ZERO tests."
      echo "    That is not a pass: the command may be scoped to the wrong place." ;;
    cannot-run)
      echo "  ⚠ PROBE COULD NOT RUN — the command never reached a test run: the"
      echo "    project or solution it names could not be loaded (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    timeout)
      echo "  ⚠ PROBE TIMED OUT — no verdict within ${PROBE_TIMEOUT}s; the suite never settled." ;;
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
#   unknown  testCommand null/absent AND no candidate, with NO stack detected —
#            the greenfield state: EXPECTED, not an alarm.
#   ambiguous  (S147) testCommand null/absent because SEVERAL test systems are
#            present and LCARS refuses to guess. NOT greenfield: this repo HAS
#            test systems, LCARS just cannot pick one — it needs the captain to
#            choose. Given its own voice so the bootstrap ("the crew will
#            establish them") and repair voices never blur on a repo that
#            already has real test infrastructure. TWO shapes reach it:
#              • several STACKS (rust + js …), and
#              • one stack that cannot pin its runner because it has several
#                candidates — today a dotnet repo with two test projects, which
#                warned and NAMED both projects and then declared the repo
#                greenfield on the very next line.
#
# Shared by `lcars init`/`lcars update`/`lcars status` (they source this file)
# and by the viewscreen daemon (via skills/lcars-init/readiness.sh), so CLI and
# board can never disagree. It NEVER writes anything — the sanctioned writers
# are `lcars update --test-command|--fix-tests` alone.
#
# Args: $1 = path to config.json. Reads $TOPLEVEL (repo root) for detection and
# for resolving a relative runner path. Sets, for the caller:
#   LCARS_TESTREADY_STATUS      ready|missing|broken|unknown|ambiguous
#   LCARS_TESTREADY_TESTCMD     the stored testCommand ("" when null/absent)
#   LCARS_TESTREADY_SUGGESTION  the detected candidate ("" unless status=missing)
#   LCARS_TESTREADY_STACKS      the ambiguity's candidate LABELS, comma-separated
#                               — stack ids for a multi-stack repo, test-project
#                               paths for one stack that cannot pin its runner
#                               ("" unless status=ambiguous)
#   LCARS_TESTREADY_CANDIDATES  one candidate COMMAND per line, so the captain
#                               can PICK instead of hiring a discovery worker
#                               ("" unless status=ambiguous)
lcars_test_readiness() {
  local config="$1"
  LCARS_TESTREADY_STATUS=""
  LCARS_TESTREADY_TESTCMD=""
  LCARS_TESTREADY_SUGGESTION=""
  LCARS_TESTREADY_STACKS=""
  LCARS_TESTREADY_CANDIDATES=""

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
  local stack cand="" s
  stack="$(detect_stack)"
  case "$stack" in
    # S147: an AMBIGUOUS repo is its OWN state, not greenfield. It has test
    # systems — several — and LCARS refuses to guess between them; calling that
    # "no test systems found" (and promising the first mission's crew would
    # establish them) was a lie on a repo that already has real infrastructure.
    ambiguous*)
      LCARS_TESTREADY_STATUS="ambiguous"
      LCARS_TESTREADY_STACKS="${stack#ambiguous(}"
      LCARS_TESTREADY_STACKS="${LCARS_TESTREADY_STACKS%)}"
      # A real command per candidate stack, so `--fix-tests` can offer a PICK
      # instead of hiring a paid discovery crew to choose (which is exactly what
      # the "LCARS will not choose for you" line promised it would not do).
      for s in $(printf '%s' "$LCARS_TESTREADY_STACKS" | tr ',' ' '); do
        cand="$(detect_test_cmd_for_stack "$s")"
        [ -n "$cand" ] && LCARS_TESTREADY_CANDIDATES="${LCARS_TESTREADY_CANDIDATES}${cand}
"
      done
      return 0 ;;
    *)          cand="$(detect_test_cmd)" ;;
  esac
  if [ -n "$cand" ]; then
    LCARS_TESTREADY_STATUS="missing"
    LCARS_TESTREADY_SUGGESTION="$cand"
    return 0
  fi
  # No command AND no candidate. Before calling this greenfield, ask whether the
  # single detected stack is ambiguous WITHIN ITSELF — a dotnet repo with two
  # test projects has real test infrastructure and simply needs the captain to
  # choose. Folding that into `unknown` made init warn "SEVERAL test projects are
  # present", name both, and then declare the repo greenfield on the next line.
  local alt; alt="$(lcars_stack_alternatives "$stack")"
  if [ -n "$alt" ]; then
    LCARS_TESTREADY_STATUS="ambiguous"
    LCARS_TESTREADY_CANDIDATES="$alt"
    LCARS_TESTREADY_STACKS="$(printf '%s' "$alt" | sed 's/^dotnet test //' | tr '\n' ',' | sed 's/,$//')"
    return 0
  fi
  LCARS_TESTREADY_STATUS="unknown"
  return 0
}

# stack_uses_native_isolation <stack> — 0 when this stack's Implement gate legs
# are scoped by the RUNNER's own flags rather than by pointing it at an external
# $LCARS_TESTS_DIR quarantine (`cargo test --test <stem>`, `go test -run`, an
# explicit rspec/minitest file, `dotnet test --filter`). These runners are
# compiled/loaded per crate/package/project and simply cannot be aimed at a
# detached directory, which is why they took the native path in the first place.
#
# MUST STAY IN STEP with `stack_is_native` in skills/lcars-run/run.sh — that is
# the gate-side authority; this is the init/update-side reader of the same fact
# (run.sh does not source this file). Adding a stack to one means adding it to
# the other.
stack_uses_native_isolation() { # stack → 0 = native isolation
  case "${1:-}" in rust|go|ruby|dotnet) return 0 ;; *) return 1 ;; esac
}

# lcars_stack_alternatives <stack> — the candidate COMMANDS when a SINGLE stack
# is present but cannot pin ONE runner, newline-separated; empty when the stack
# has no such shape (which is every stack that never reaches here with a real
# choice to make). Today: dotnet with several test projects.
#
# Ruby has the same disease — an rspec (spec/) AND a minitest (test/ + Rakefile)
# layout without a decisive Gemfile signal also seeds nothing and reads as
# greenfield — and is deliberately LEDGERED rather than changed here: S145's
# shipped init/update output is regression-locked by tests/stack-ruby.test.sh and
# the S147 brief scopes this fix to the dotnet path. Same cure when it is due.
lcars_stack_alternatives() { # stack → candidate commands, one per line
  case "${1:-}" in
    dotnet)
      local projs n p
      projs="$(detect_dotnet_test_projects | grep . || :)"
      n="$(printf '%s' "$projs" | grep -c . || :)"
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      [ "$n" -ge 2 ] || return 0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf 'dotnet test %s\n' "$p"
      done <<DN_ALT
$projs
DN_ALT
      ;;
    *) : ;;
  esac
}

# lcars_readiness_line — render the ONE human status line for the verdict the
# globals above carry. Ship-status voice (never a config lecture):
#   ready    → EMPTY (ready repos are silent everywhere — zero chrome drift)
#   broken/  → the REPAIR voice: ⚠ TEST SYSTEMS OFFLINE + the one-click fix verb
#   missing
#   unknown  → the BOOTSTRAP voice: a greenfield repo is EXPECTED, not an alarm —
#              reads as status, never an action item.
#   ambiguous→ (S147) the CHOOSE voice: this repo HAS test systems, several of
#              them, and LCARS will not pick for the captain. Never the
#              bootstrap voice (it is not greenfield) and never the bare repair
#              voice (nothing is broken) — it points at the same ⚡ fix verb.
# The unready voices must NEVER blur (captain ruling, S146).
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
    # LEDGERED (recorded, not fixed): `$LCARS_TESTREADY_STACKS` is a list of
    # STACK IDS for a multi-stack repo — "(rust,js)" reads perfectly — but a list
    # of .csproj PATHS when one stack cannot pin its runner, and
    # "MULTIPLE TEST SYSTEMS DETECTED (One.Tests/One.Tests.csproj,…)" reads
    # awkwardly. It is accurate and it is what the captain must choose between,
    # so it ships; a per-shape phrasing (stacks vs projects) is the tidier fix
    # whenever this line is next opened.
    ambiguous)
      printf '⚠ MULTIPLE TEST SYSTEMS DETECTED (%s) — LCARS will not choose for you; missions cannot be proof-gated until one is selected. Select: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_STACKS"
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
