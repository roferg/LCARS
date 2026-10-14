#!/usr/bin/env bash
#
# Tests GitHub ENTERPRISE (*.ghe.com and any self-hosted host) support
# (skill source: skills/lcars-run/host-adapter.sh + skills/lcars-init/lcars-common.sh).
#
# WHY THIS EXISTS
# ---------------
# `gh issue` / `gh pr` resolve the forge host from the repo's own remote, so they
# work on an enterprise host with no configuration. `gh api` does NOT: it targets
# the DEFAULT host (github.com) and only substitutes `{owner}/{repo}` from the cwd
# repo. Verified against a real enterprise repo:
#
#   $ cd <repo on enterprise.example.com>
#   $ gh api "repos/{owner}/{repo}"
#   {"message":"Not Found","documentation_url":"https://docs.github.com/..."}
#
# — a 404 from *docs.github.com*, i.e. the call went to github.com, while `gh
# auth status` showed a valid login for the enterprise host all along.
#
# Every LCARS op built on `gh api` is therefore silently broken on enterprise:
#   • issue-comment-create / issue-comment-edit — the S65 living per-stage
#     comments, which is why enterprise issues never receive stage details;
#   • link-subissue — so Schedule's ticket sub-issues are never nested.
# All of them discard stderr, so the failure is completely invisible.
#
# THE FIX, AND WHY IT IS SHAPED THIS WAY: pin `--hostname` ONLY when the repo's
# remote names a host that is not github.com. On github.com (and with no remote)
# the argv stays byte-for-byte what it was, so the adapter's existing regression
# locks in tests/host-adapter.test.sh keep their meaning.
#
# Usage: bash tests/ghe-host-resolution.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${LCARS_HOST_ADAPTER:-$REPO_ROOT/skills/lcars-run/host-adapter.sh}"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A gh stub that records argv and answers the api shapes the adapter parses.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "api" ]; then
  # sub_issues POST → no output needed; issues/<n> GET → a db id; comments → json
  case " $* " in
    *"/sub_issues "*) exit 0 ;;
    *"--jq .id"*)     echo "987654"; exit 0 ;;
  esac
  echo '{"id":555,"user":{"id":99}}'
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

# A git repo whose origin points at $1. Echoes the repo path.
new_repo_with_remote() {
  local url="$1" repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q . && git config user.email t@t && git config user.name t
    [ -n "$url" ] && git remote add origin "$url"; : ) >/dev/null 2>&1
  echo "$repo"
}

# Run an adapter op inside $1 with the gh stub; log lands at $1/gh.log
run_op() {
  local repo="$1"; shift
  make_gh_stub "$repo/gh"
  export GH_LOG="$repo/gh.log"; : >"$GH_LOG"
  ( cd "$repo" && LCARS_GH_BIN="$repo/gh" GH_LOG="$GH_LOG" bash "$ADAPTER" "$@" ) >/dev/null 2>&1
}

echo "GitHub Enterprise host resolution"

GHE="https://enterprise.example.com/acme/widgets"

# --- 1. the api ops must pin the enterprise host --------------------------
R1="$(new_repo_with_remote "$GHE")"
printf 'hello\n' | run_op "$R1" issue-comment-create 42
check "1a. issue-comment-create pins --hostname enterprise.example.com" \
  'grep -q -- "--hostname enterprise.example.com" "$R1/gh.log"'
check "1b. it still POSTs to the right path" \
  'grep -q "issues/42/comments" "$R1/gh.log"'

R2="$(new_repo_with_remote "$GHE")"
printf 'hello\n' | run_op "$R2" issue-comment-edit 555
check "2. issue-comment-edit pins --hostname" \
  'grep -q -- "--hostname enterprise.example.com" "$R2/gh.log"'

R3="$(new_repo_with_remote "$GHE")"
run_op "$R3" link-subissue 42 314
check "3a. link-subissue pins --hostname on BOTH api calls" \
  '[ "$(grep -c -- "--hostname enterprise.example.com" "$R3/gh.log")" -ge 2 ]'
check "3b. the typed -F sub_issue_id survives the change" \
  'grep -q -- "-F sub_issue_id=" "$R3/gh.log"'

# --- 2. github.com must be byte-for-byte unchanged (regression lock) -------
R4="$(new_repo_with_remote "https://github.com/acme/widgets")"
printf 'hello\n' | run_op "$R4" issue-comment-create 42
check "4a. github.com adds NO --hostname (argv lock preserved)" \
  '! grep -q -- "--hostname" "$R4/gh.log"'
check "4b. the api argv is exactly the historic shape" \
  'grep -q "gh api --method POST repos/{owner}/{repo}/issues/42/comments" "$R4/gh.log"'

# an ssh remote on github.com is still the default host
R5="$(new_repo_with_remote "git@github.com:acme/widgets.git")"
printf 'hello\n' | run_op "$R5" issue-comment-create 42
check "5. ssh github.com remote adds no --hostname" \
  '! grep -q -- "--hostname" "$R5/gh.log"'

# --- 3. no remote at all => leave gh to its own default -------------------
R6="$(new_repo_with_remote "")"
printf 'hello\n' | run_op "$R6" issue-comment-create 42
check "6. a repo with no origin adds no --hostname" \
  '! grep -q -- "--hostname" "$R6/gh.log"'

# --- 4. ssh + self-hosted enterprise --------------------------------------
R7="$(new_repo_with_remote "git@enterprise.example.com:acme/widgets.git")"
printf 'hello\n' | run_op "$R7" issue-comment-create 42
check "7. an SSH enterprise remote is parsed to its host" \
  'grep -q -- "--hostname enterprise.example.com" "$R7/gh.log"'

R8="$(new_repo_with_remote "https://git.internal.corp:8443/acme/widgets.git")"
printf 'hello\n' | run_op "$R8" issue-comment-create 42
check "8. a self-hosted host with a PORT drops the port" \
  'grep -q -- "--hostname git.internal.corp" "$R8/gh.log"'

# --- 5. explicit override wins -------------------------------------------
R9="$(new_repo_with_remote "$GHE")"
make_gh_stub "$R9/gh"; export GH_LOG="$R9/gh.log"; : >"$GH_LOG"
( cd "$R9" && LCARS_GH_BIN="$R9/gh" GH_LOG="$GH_LOG" LCARS_GH_HOST="other.example.com" \
    bash "$ADAPTER" issue-comment-create 42 <<<"hi" ) >/dev/null 2>&1
check "9. LCARS_GH_HOST overrides the derived host" \
  'grep -q -- "--hostname other.example.com" "$R9/gh.log"'

# --- 6. the readout links must name the real host -------------------------
# `lcars init` / `lcars update` printed a hardcoded "on github.com/<owner>/<repo>",
# so on enterprise the link the captain clicks is simply wrong.
# shellcheck source=/dev/null
. "$COMMON"
if type lcars_gh_web_host >/dev/null 2>&1; then
  RH="$(cd "$R1" && lcars_gh_web_host)"
  check "10a. the shared web-host helper reports the enterprise host" \
    '[ "$RH" = "enterprise.example.com" ]'
  RH2="$(cd "$R4" && lcars_gh_web_host)"
  check "10b. it reports github.com for a github.com repo" \
    '[ "$RH2" = "github.com" ]'
else
  bad "10. lcars_gh_web_host helper exists in lcars-common.sh"
fi
check "10c. init.sh no longer hardcodes the github.com readout host" \
  '! grep -q "on github.com/\$GH_REPO" "$REPO_ROOT/skills/lcars-init/init.sh"'
check "10d. update.sh no longer hardcodes it either" \
  '! grep -q "on github.com/\$GH_REPO" "$REPO_ROOT/skills/lcars-update/update.sh"'

# --- 7. the `gh-host` op: gh_hostname, ASKABLE from outside bash -----------
# S168: the VIEWSCREEN's "view on GitHub" links string-concatenated
# "https://github.com/", so on an enterprise repo every link the captain clicked
# landed on a github.com repository that does not exist and had to be hand-edited.
# The daemon must not re-derive the host in Python — LCARS already carries a
# drifted-duplicate-list scar from exactly that (the zero-collect phrase list
# lives in two places and one is now blind). So gh_hostname is exposed as an op
# and the daemon SHELLS it (ADR-002: the board dispatches to the skill).
#
# Same contract as the internal helper, deliberately: EMPTY for github.com, so
# the daemon's payload can omit the field entirely and a github.com board stays
# byte-identical.
gh_host_of() {  # $1 = repo dir; echoes the op's stdout verbatim
  ( cd "$1" && bash "$ADAPTER" gh-host ) 2>/dev/null
}
check "11a. gh-host echoes the enterprise host" \
  '[ "$(gh_host_of "$R1")" = "enterprise.example.com" ]'
check "11b. gh-host echoes NOTHING for github.com (the byte-identity contract)" \
  '[ -z "$(gh_host_of "$R4")" ]'
check "11c. gh-host echoes nothing for a repo with no origin" \
  '[ -z "$(gh_host_of "$R6")" ]'
check "11d. gh-host parses an scp-style enterprise remote" \
  '[ "$(gh_host_of "$R7")" = "enterprise.example.com" ]'
check "11e. gh-host drops a :port" \
  '[ "$(gh_host_of "$R8")" = "git.internal.corp" ]'
check "11f. gh-host exits 0 even where there is no forge host" \
  '( cd "$R6" && bash "$ADAPTER" gh-host >/dev/null 2>&1 )'
R10="$(new_repo_with_remote "$GHE")"
check "11g. LCARS_GH_HOST overrides gh-host too" \
  '[ "$( ( cd "$R10" && LCARS_GH_HOST=other.example.com bash "$ADAPTER" gh-host ) )" = "other.example.com" ]'
check "11h. gh-host does not need gh installed (it is a git question)" \
  '[ "$( ( cd "$R1" && PATH=/usr/bin:/bin LCARS_GH_BIN=/nonexistent/gh bash "$ADAPTER" gh-host ) )" = "enterprise.example.com" ]'

# --- 8. DRIFT LOCK: the two host derivations must agree --------------------
# gh_hostname (host-adapter.sh, for `gh api --hostname`) and lcars_gh_web_host
# (lcars-common.sh, for a link the captain CLICKS) carry the same four stripping
# rules in two files. Their contracts differ ONLY at the github.com/no-remote
# default: the adapter says "" (leave the argv historic), the display helper says
# "github.com" (that IS the right thing to print). Everywhere else they must
# produce the SAME string, or the CLI readout and the board link will one day
# name different hosts. A comment cannot enforce that; this table can.
drift=0
for u in "https://enterprise.example.com/acme/widgets" \
         "git@enterprise.example.com:acme/widgets.git" \
         "ssh://git@git.internal.corp:8443/acme/widgets.git" \
         "https://github.com/acme/widgets" \
         "git@github.com:acme/widgets.git" \
         ""; do
  RD="$(new_repo_with_remote "$u")"
  a="$(gh_host_of "$RD")"
  b="$(cd "$RD" && lcars_gh_web_host)"
  [ -z "$a" ] && a="github.com"      # the ONE deliberate difference
  [ "$a" = "$b" ] || { drift=1; printf '    drift on %s: adapter=%s common=%s\n' "${u:-<none>}" "$a" "$b"; }
done
check "12. gh_hostname and lcars_gh_web_host agree on every remote shape" \
  '[ "$drift" -eq 0 ]'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
