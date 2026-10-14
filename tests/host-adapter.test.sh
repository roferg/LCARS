#!/usr/bin/env bash
#
# Tests for the host-integration adapter — the ONE place LCARS speaks to a forge
# (skill source: skills/lcars-run/host-adapter.sh).
#
# The adapter is a thin, swappable seam. Today its only host is `github`, which
# maps each op to the EXACT `gh` invocation LCARS used before the adapter existed
# — so this suite is a regression lock on those argv shapes. A second host can be
# added later without touching any caller.
#
#   host-adapter.sh <op> [args…]
#     issue-create  --title <t> --body <b> --label <l>…   → echoes new issue number
#     issue-relabel <n> --add <labels> --remove <labels>  → relabels an issue
#     issue-close   <n> [--comment <c>]                   → closes an issue
#     pr-create     --head <h> --base <b> --title <t> --body <b2> [--closes <n>…]
#                                                          → echoes the PR URL
#
# Host selection and binaries are env-injectable so tests can stub them:
#   LCARS_HOST_BIN  - the host id (default: github)
#   LCARS_GH_BIN    - the github host's `gh` binary (default: gh)
#
# Usage: bash tests/host-adapter.test.sh

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
SCRIPT="${LCARS_HOST_ADAPTER:-$REPO_ROOT/skills/lcars-run/host-adapter.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A fake `gh` that records every call to $GH_LOG (one call per line, newlines in
# args folded to spaces) and, for the create ops, echoes a URL the way real gh
# does (issue create → an issue URL; pr create → a PR URL).
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/issues/314"
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/77"
fi
# `gh api .../issues/<n> --jq .id` → resolve the child's DATABASE id. Echo a
# synthetic db id (9000 + child number) that is distinctly NOT the issue number,
# so link-subissue tests can prove the adapter resolved the db id, not the number.
if [ "${1:-}" = "api" ] && printf '%s' "${2:-}" | grep -q '/sub_issues$' ; then
  echo '{"sub_issues_summary":{"total":1}}'
elif [ "${1:-}" = "api" ]; then
  child="$(printf '%s' "${2:-}" | sed 's#.*/issues/##')"
  echo $((9000 + child))
fi
exit 0
EOF
  chmod +x "$1"
}

# Like make_gh_stub, but every gh call FAILS (exit 1, no URL) — stands in for a
# real forge failure (auth, no remote, API error, …).
make_gh_stub_fail() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 1
EOF
  chmod +x "$1"
}

# ==========================================================================
echo "host-adapter"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

GH="$TMPROOT/gh"; make_gh_stub "$GH"
export GH_LOG="$TMPROOT/gh.log"

# --- Behaviour 1: issue-create → today's exact gh argv, echoes the number -----
: >"$GH_LOG"
out="$(LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-create \
  --title "Add the toggle" --body "Wire it up" --label "lcars:implement,lcars:feature" 2>/dev/null)"
check "1. issue-create calls gh issue create with --title/--body/--label" \
  "grep -qx 'gh issue create --title Add the toggle --body Wire it up --label lcars:implement,lcars:feature ' '$GH_LOG'"
check "1. issue-create echoes the new issue NUMBER (url trailing segment)" \
  "[ '$out' = '314' ]"

# --- Behaviour 1: issue-relabel → today's exact gh issue edit argv ------------
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-relabel 42 \
  --add "lcars:validate lcars:awaiting-human" --remove "lcars:align" >/dev/null 2>&1
check "1. issue-relabel calls gh issue edit with add/remove labels in order" \
  "grep -qx 'gh issue edit 42 --add-label lcars:validate --add-label lcars:awaiting-human --remove-label lcars:align ' '$GH_LOG'"

# add-only and remove-only render cleanly (no stray empty flags)
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-relabel 42 --add "lcars:done" --remove "" >/dev/null 2>&1
check "1. issue-relabel with empty --remove emits no --remove-label flag" \
  "grep -qx 'gh issue edit 42 --add-label lcars:done ' '$GH_LOG'"

# --- Behaviour 1: pr-create → today's exact gh pr create argv, echoes URL ------
: >"$GH_LOG"
out="$(LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-create \
  --head "lcars/m-1" --base "main" --title "Add dark mode" --body "## Summary" 2>/dev/null)"
check "1. pr-create calls gh pr create --title/--body/--head/--base (today's order)" \
  "grep -qx 'gh pr create --title Add dark mode --body ## Summary --head lcars/m-1 --base main ' '$GH_LOG'"
check "1. pr-create echoes the PR URL" \
  "[ '$out' = 'https://github.com/acme/repo/pull/77' ]"

# --- Behaviour 2: issue-close → gh issue close <n> [--comment …] --------------
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-close 103 >/dev/null 2>&1
check "2. issue-close calls gh issue close <n>" \
  "grep -qx 'gh issue close 103 ' '$GH_LOG'"

: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-close 103 --comment "Shipped in #77" >/dev/null 2>&1
check "2. issue-close with --comment passes it through" \
  "grep -qx 'gh issue close 103 --comment Shipped in #77 ' '$GH_LOG'"

# --- Behaviour 2: pr-create --closes appends host-portable Closes lines --------
# Without --closes the body is byte-for-byte unchanged (today's regression).
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-create \
  --head "lcars/m-1" --base "main" --title "T" --body "## Summary" >/dev/null 2>&1
check "2. pr-create with NO --closes leaves the body unchanged" \
  "grep -qx 'gh pr create --title T --body ## Summary --head lcars/m-1 --base main ' '$GH_LOG'"

# With --closes the body gains a `Closes #<n>` line per issue (GitHub/GitLab both
# honour this), so merge→close is host-portable, not gh-only.
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-create \
  --head "lcars/m-1" --base "main" --title "T" --body "## Summary" \
  --closes 101 --closes 102 >/dev/null 2>&1
check "2. pr-create --closes appends Closes #101 into the PR body" \
  "grep -q 'Closes #101' '$GH_LOG'"
check "2. pr-create --closes appends Closes #102 into the PR body" \
  "grep -q 'Closes #102' '$GH_LOG'"
check "2. pr-create --closes keeps the original body too" \
  "grep -q '## Summary' '$GH_LOG'"

# --- Behaviour 2b: link-subissue → resolve child db id, POST a TYPED integer --
# Native GitHub sub-issue nesting (Session 35). The op takes <parent> <child>
# ISSUE NUMBERS, resolves the child's DATABASE id via `gh api .../issues/<child>
# --jq .id`, then POSTs to `.../issues/<parent>/sub_issues` with the db id as a
# TYPED integer field. The typed integer is the crux: `gh api -F` sends a number
# (the API requires it), `-f` would send a string and the API 422s. This suite
# locks: --method POST, the sub_issues path, AND `-F` (never `-f`).
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" link-subissue 42 314 >/dev/null 2>&1
check "2b. link-subissue resolves the child db id via gh api issues/<child> --jq .id" \
  "grep -q 'gh api repos/{owner}/{repo}/issues/314 --jq .id' '$GH_LOG'"
check "2b. link-subissue POSTs to the parent's sub_issues endpoint (--method POST)" \
  "grep -q 'gh api --method POST repos/{owner}/{repo}/issues/42/sub_issues' '$GH_LOG'"
check "2b. link-subissue sends sub_issue_id as a TYPED integer (-F, the resolved db id 9314)" \
  "grep -q 'sub_issues -F sub_issue_id=9314' '$GH_LOG'"
check "2b. link-subissue NEVER uses -f (string) for sub_issue_id (would 422)" \
  "! grep -q -- '-f sub_issue_id' '$GH_LOG'"

# --- S75: pr-merge / pr-view / pr-close — the PR lifecycle ops ----------------
# pr-merge identifies the PR by --number or --head and shells `gh pr merge`.
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-merge --number 77 >/dev/null 2>&1
check "S75. pr-merge calls gh pr merge <number> --merge (by --number)" \
  "grep -qx 'gh pr merge 77 --merge ' '$GH_LOG'"
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-merge --head "lcars/m-1" >/dev/null 2>&1
check "S75. pr-merge can identify the PR by --head (branch selector)" \
  "grep -qx 'gh pr merge lcars/m-1 --merge ' '$GH_LOG'"
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-merge --number 77 --method squash >/dev/null 2>&1
check "S75. pr-merge honours --method squash" \
  "grep -qx 'gh pr merge 77 --squash ' '$GH_LOG'"

# pr-view reads the merge state via gh pr view --json state,mergedAt and echoes
# the parsed `state` / `mergedAt` lines. Use a stub that returns a MERGED PR.
GHM="$TMPROOT/ghmerged"
cat >"$GHM" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  echo '{"state":"MERGED","mergedAt":"2026-06-19T10:00:00Z"}'
fi
exit 0
EOF
chmod +x "$GHM"
: >"$GH_LOG"
mout="$(LCARS_GH_BIN="$GHM" bash "$SCRIPT" pr-view --number 77 2>/dev/null)"
check "S75. pr-view calls gh pr view <n> --json state,mergedAt" \
  "grep -q 'pr view 77 --json state,mergedAt' '$GH_LOG'"
check "S75. pr-view echoes the parsed MERGED state" \
  "printf '%s' \"$mout\" | qgrep -q 'state	MERGED'"
check "S75. pr-view echoes the mergedAt timestamp" \
  "printf '%s' \"$mout\" | qgrep -q 'mergedAt	'"

# An OPEN PR (no mergedAt) — state OPEN, mergedAt null.
GHO="$TMPROOT/ghopen"
cat >"$GHO" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  echo '{"state":"OPEN","mergedAt":null}'
fi
exit 0
EOF
chmod +x "$GHO"
: >"$GH_LOG"
oout="$(LCARS_GH_BIN="$GHO" bash "$SCRIPT" pr-view --number 77 2>/dev/null)"
check "S75. pr-view echoes OPEN state for an open PR" \
  "printf '%s' \"$oout\" | qgrep -q 'state	OPEN'"
check "S75. pr-view echoes mergedAt null for an open PR" \
  "printf '%s' \"$oout\" | qgrep -q 'mergedAt	null'"

# pr-close closes (without merging).
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-close --number 77 >/dev/null 2>&1
check "S75. pr-close calls gh pr close <number>" \
  "grep -qx 'gh pr close 77 ' '$GH_LOG'"
: >"$GH_LOG"
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-close --head "lcars/m-1" >/dev/null 2>&1
check "S75. pr-close can identify the PR by --head" \
  "grep -qx 'gh pr close lcars/m-1 ' '$GH_LOG'"

# Best-effort: a forge failure on merge/close PROPAGATES non-zero (so approve /
# feedback can note it) but never dies. pr-view echoes nothing on failure.
GHF75="$TMPROOT/ghfail75"; make_gh_stub_fail "$GHF75"
ERR75="$TMPROOT/err75"
: >"$GH_LOG"; rc=0
LCARS_GH_BIN="$GHF75" bash "$SCRIPT" pr-merge --number 77 >/dev/null 2>"$ERR75" || rc=$?
check "S75. pr-merge returns NON-ZERO when gh fails (so approve stays at verify)" \
  "[ '$rc' -ne 0 ]"
check "S75. pr-merge forge failure does NOT die" "! grep -q 'host-adapter:' '$ERR75'"
rc=0
LCARS_GH_BIN="$GHF75" bash "$SCRIPT" pr-close --number 77 >/dev/null 2>"$ERR75" || rc=$?
check "S75. pr-close returns NON-ZERO when gh fails" "[ '$rc' -ne 0 ]"
rc=0
vout="$(LCARS_GH_BIN="$GHF75" bash "$SCRIPT" pr-view --number 77 2>/dev/null)" || rc=$?
check "S75. pr-view returns 0 and echoes the empty/blank state when gh fails" \
  "[ '$rc' -eq 0 ]"

# missing selector is a HARD error (a die), distinct from a soft forge failure.
LCARS_GH_BIN="$GH" bash "$SCRIPT" pr-merge >/dev/null 2>&1
check "S75. pr-merge with no selector dies" "[ $? -ne 0 ]"

# --- Behaviour 3: an unknown host id exits NON-ZERO (no silent no-op) ---------
: >"$GH_LOG"
rc=0
LCARS_HOST_BIN="bitbucket" LCARS_GH_BIN="$GH" bash "$SCRIPT" issue-relabel 42 --add "x" --remove "" >/dev/null 2>&1 || rc=$?
check "3. unknown host id exits non-zero" "[ '$rc' -ne 0 ]"
check "3. unknown host id makes no gh call" "! grep -q 'gh ' '$GH_LOG' 2>/dev/null"

# unknown OP also exits non-zero (defensive — not a silent success)
rc=0
LCARS_GH_BIN="$GH" bash "$SCRIPT" not-an-op >/dev/null 2>&1 || rc=$?
check "3. unknown op exits non-zero" "[ '$rc' -ne 0 ]"

# --- Behaviour 4: a forge failure is SOFT — never aborts the caller, but the rc
# PROPAGATES so the caller can set its "do it by hand" note ---------------------
# "Best-effort" means the adapter must never `die`/`exit`/abort the CALLER's
# process — NOT that it masks failure. The callers invoke relabel/close inside
# `if ! host …` / `host … ||`, so a NON-ZERO return is caught (never fatal) and is
# exactly how the caller learns to set its note. So a forge failure must:
#   (a) make the adapter return NON-ZERO, and
#   (b) NOT `die` — print no "host-adapter:" message (distinct from the HARD
#       non-zero of an unknown host/op in behaviour 3, which DOES die).
GHF="$TMPROOT/ghfail"; make_gh_stub_fail "$GHF"
ERR="$TMPROOT/err"

: >"$GH_LOG"
rc=0
LCARS_GH_BIN="$GHF" bash "$SCRIPT" issue-relabel 42 --add "lcars:done" --remove "lcars:verify" >/dev/null 2>"$ERR" || rc=$?
check "4. issue-relabel returns NON-ZERO when gh fails (so the caller's note fires)" \
  "[ '$rc' -ne 0 ]"
check "4. issue-relabel forge failure does NOT die (no host-adapter: message)" \
  "! grep -q 'host-adapter:' '$ERR'"

: >"$GH_LOG"
rc=0
LCARS_GH_BIN="$GHF" bash "$SCRIPT" issue-close 103 >/dev/null 2>"$ERR" || rc=$?
check "4. issue-close returns NON-ZERO when gh fails (propagates the forge rc)" \
  "[ '$rc' -ne 0 ]"
check "4. issue-close forge failure does NOT die (no host-adapter: message)" \
  "! grep -q 'host-adapter:' '$ERR'"

# link-subissue is best-effort like relabel/close: a forge failure (id resolution
# or the POST) returns NON-ZERO so cmd_schedule can set its "nest by hand" note,
# but it never `die`s — distinct from the hard error of an unknown op.
: >"$GH_LOG"
rc=0
LCARS_GH_BIN="$GHF" bash "$SCRIPT" link-subissue 42 314 >/dev/null 2>"$ERR" || rc=$?
check "4. link-subissue returns NON-ZERO when gh fails (so cmd_schedule's note fires)" \
  "[ '$rc' -ne 0 ]"
check "4. link-subissue forge failure does NOT die (no host-adapter: message)" \
  "! grep -q 'host-adapter:' '$ERR'"

# Contrast: the HARD non-zero of an unknown op DOES die with a message — proving
# the suite distinguishes a soft forge failure from a hard contract violation.
rc=0
LCARS_GH_BIN="$GHF" bash "$SCRIPT" not-an-op >/dev/null 2>"$ERR" || rc=$?
check "4. unknown op (hard error) returns non-zero AND prints a host-adapter: die" \
  "[ '$rc' -ne 0 ] && grep -q 'host-adapter:' '$ERR'"

# issue-create on failure echoes nothing and does not abort (today's create_issue
# spirit: leave the issue null, never block the schedule — its caller keys the
# "could not create sub-issues" note off EMPTY OUTPUT, not the exit code).
: >"$GH_LOG"
rc=0
out="$(LCARS_GH_BIN="$GHF" bash "$SCRIPT" issue-create --title T --body B --label L 2>/dev/null)" || rc=$?
check "4. issue-create returns 0 and echoes nothing when gh fails" \
  "[ '$rc' -eq 0 ] && [ -z '$out' ]"

# --- Behaviour 4 (end-to-end): the real run.sh gh_relabel still sets its note --
# Lock the note fidelity against regression: with a failing gh stub, drive run.sh's
# ACTUAL gh_relabel and assert RELABEL_NOTE picks up "gh issue edit failed". This
# proves the adapter's propagated non-zero reaches the live caller's note branch.
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
if [ -f "$RUN_SH" ]; then
  STATE_DIR="$TMPROOT/e2e"; mkdir -p "$STATE_DIR"
  printf '{ "githubIssue": 42 }\n' >"$STATE_DIR/state.json"
  note="$(
    GH_BIN="$GHF" \
    LCARS_GH_BIN="$GHF" \
    STATE="$STATE_DIR/state.json" \
    bash -c '
      set -uo pipefail
      RUN_SH="'"$RUN_SH"'"
      # Faithfully reuse run.sh’s OWN host() seam + json_raw, then eval its real
      # gh_relabel body — so this drives the live caller path, not a copy.
      HOST_ADAPTER="$(dirname "$RUN_SH")/host-adapter.sh"
      host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }
      eval "$(awk "/^json_raw\\(\\) \\{/{f=1} f{print} f&&/^\\}/{exit}" "$RUN_SH")"
      RELABEL_NOTE=""
      eval "$(awk "/^gh_relabel\\(\\) \\{/{f=1} f{print} f&&/^\\}/{exit}" "$RUN_SH")"
      gh_relabel "lcars:done" "lcars:verify"
      printf "%s" "$RELABEL_NOTE"
    '
  )"
  check "4. e2e: run.sh gh_relabel sets RELABEL_NOTE on a gh failure (note fidelity)" \
    "printf '%s' \"$note\" | qgrep -q 'gh issue edit failed'"
fi

# ==========================================================================
# Session 65: the living per-stage comment ops — issue-comment-create (POST,
# echoes the new id) + issue-comment-edit (PATCH). Bodies come via STDIN.
# ==========================================================================
# A gh stub that records the api argv AND the body that REALLY reaches gh, and
# echoes {"id":<n>} for a POST and {"id":<id>} for a PATCH (so create can parse
# the new id). It models REAL `gh api` field semantics so a literal-`@-` defect
# can't sneak through (S65 fix-loop):
#   -F/--field  key=@-   → reads the value from STDIN  (the real stdin path)
#   -f/--raw-field key=@- → LITERAL string "@-" (gh does NOT read stdin here)
# So if the adapter passes `-f body=@-`, the recorded body is the literal "@-"
# (the production defect), and the rich-body assertions below FAIL.
GHC="$TMPROOT/ghc"
cat >"$GHC" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
allargs="$*"   # preserve argv for the endpoint match below (the loop shifts it)
# Resolve the `body` payload exactly as real gh would, by walking the flags.
body=""; have_body=0
while [ $# -gt 0 ]; do
  case "$1" in
    -F|--field)
      case "$2" in
        body=@-) body="$(cat)"; have_body=1 ;;          # field @- → stdin
        body=@*) body="$(cat "${2#body=@}")"; have_body=1 ;;  # field @file
        body=*)  body="${2#body=}"; have_body=1 ;;       # typed literal
      esac
      shift 2; continue ;;
    -f|--raw-field)
      case "$2" in
        body=*) body="${2#body=}"; have_body=1 ;;        # ALWAYS literal (incl. "@-")
      esac
      shift 2; continue ;;
    --body-file)
      case "$2" in
        -) body="$(cat)"; have_body=1 ;;
        *) body="$(cat "$2")"; have_body=1 ;;
      esac
      shift 2; continue ;;
    --body) body="$2"; have_body=1; shift 2; continue ;;
  esac
  shift
done
[ "$have_body" -eq 1 ] && printf '%s' "$body" >>"$GH_BODY"
case "$allargs" in
  # Mirror real gh: the comment's own id comes FIRST, a nested user.id LATER on
  # the same line. The adapter must echo 555 (the comment), NOT 40493721 (user).
  *POST*comments*)  echo '{"url":"u","id":555,"node_id":"n","user":{"login":"x","id":40493721},"body":"x"}' ;;
  *PATCH*comments*) echo '{"url":"u","id":777,"node_id":"n","user":{"login":"x","id":40493721},"body":"x"}' ;;
esac
exit 0
EOF
chmod +x "$GHC"
export GH_LOG="$TMPROOT/ghc.log"; : >"$GH_LOG"
export GH_BODY="$TMPROOT/ghc.body"; : >"$GH_BODY"

# create: POSTs to the issue's comments endpoint and ECHOES the new id.
: >"$GH_LOG"; : >"$GH_BODY"
NEWID="$(printf 'a rich\nmultiline body' | LCARS_GH_BIN="$GHC" bash "$SCRIPT" issue-comment-create 42)"
check "C1. issue-comment-create POSTs to the issue comments endpoint" \
  "qgrep -q 'api --method POST repos/{owner}/{repo}/issues/42/comments' <'$GH_LOG'"
check "C1. issue-comment-create passes the body via the stdin FIELD (-F body=@-)" \
  "qgrep -q -- '-F body=@-' <'$GH_LOG'"
check "C1. issue-comment-create echoes the new comment id" "[ '$NEWID' = '555' ]"
check "C1. the multiline body reached gh over stdin" \
  "qgrep -q 'multiline body' <'$GH_BODY'"
# The defect guard: the body that reached gh must be the REAL markdown, not the
# literal sentinel "@-". If the adapter used `-f body=@-`, gh stores "@-" and
# this fails — reproducing acme/widget#188.
check "C1. the body that reached gh is NOT the literal sentinel @-" \
  "[ \"\$(cat '$GH_BODY')\" != '@-' ]"

# edit: PATCHes the comment-id endpoint with the body via stdin.
: >"$GH_LOG"; : >"$GH_BODY"
printf 'edited body' | LCARS_GH_BIN="$GHC" bash "$SCRIPT" issue-comment-edit 555
check "C2. issue-comment-edit PATCHes the comments/<id> endpoint" \
  "qgrep -q 'api --method PATCH repos/{owner}/{repo}/issues/comments/555' <'$GH_LOG'"
check "C2. issue-comment-edit passes the body via stdin" \
  "qgrep -q 'edited body' <'$GH_BODY'"
check "C2. issue-comment-edit uses the stdin FIELD (-F body=@-), not raw -f" \
  "qgrep -q -- '-F body=@-' <'$GH_LOG'"
check "C2. the edit body that reached gh is NOT the literal sentinel @-" \
  "[ \"\$(cat '$GH_BODY')\" != '@-' ]"

# best-effort: gh ABSENT → create echoes nothing (no id), exits 0; edit soft-fails.
rc_c=0
NEWID2="$(printf 'b' | LCARS_GH_BIN="$TMPROOT/not-a-real-gh" bash "$SCRIPT" issue-comment-create 42)" || rc_c=$?
check "C3. create with gh ABSENT echoes nothing, never dies" \
  "[ -z '$NEWID2' ] && [ '$rc_c' -eq 0 ]"
printf 'b' | LCARS_GH_BIN="$TMPROOT/not-a-real-gh" bash "$SCRIPT" issue-comment-edit 555 >/dev/null 2>&1
check "C3. edit with gh ABSENT soft-fails (non-zero), never dies" "[ $? -ne 0 ]"

# missing args are HARD errors (a die), distinct from a soft forge failure.
LCARS_GH_BIN="$GHC" bash "$SCRIPT" issue-comment-create >/dev/null 2>&1
check "C4. create with no issue number dies" "[ $? -ne 0 ]"
LCARS_GH_BIN="$GHC" bash "$SCRIPT" issue-comment-edit >/dev/null 2>&1
check "C4. edit with no comment id dies" "[ $? -ne 0 ]"

# ==========================================================================
echo
printf 'host-adapter: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
