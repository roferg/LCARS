#!/usr/bin/env bash
#
# host-adapter.sh — the ONE place LCARS speaks to a forge (GitHub today).
#
# Every GitHub call in LCARS funnels through this thin, swappable seam, so the
# whole host integration is one file to re-point at a different forge. Today the
# only host is `github`, which maps each op to the EXACT `gh` invocation LCARS
# used before this adapter existed — a byte-for-byte regression lock.
#
# Contract:
#   host-adapter.sh <op> [args…]
#
#   Host selection / binaries (env-injectable, like the rest of LCARS):
#     LCARS_HOST_BIN   the host id           (default: github)
#     LCARS_GH_BIN     the github host's gh  (default: gh)
#     LCARS_HOST_ADAPTER  overrides the adapter SCRIPT PATH (so callers/tests can
#                         stub the whole adapter); honoured by callers, not here.
#
#   Ops:
#     issue-create  --title <t> --body <b> --label <l>…   → echoes new issue NUMBER
#     issue-comment <n> --body <b>                        → posts a comment on an
#                                                            issue (ADR-004 run
#                                                            progress mirror).
#                                                            Best-effort: gh
#                                                            absent OR failing →
#                                                            soft non-zero, never
#                                                            a die (mirroring is
#                                                            like notify.sh).
#     issue-comment-create <n>      (body on STDIN)       → CREATEs a comment and
#                                                            ECHOES its new id
#                                                            (S65 living per-stage
#                                                            comments). Body via
#                                                            stdin → no argv limit.
#     issue-comment-edit <comment-id> (body on STDIN)     → PATCHes (edits in
#                                                            place) that comment.
#     issue-relabel <n> --add <labels> --remove <labels>  → relabels an issue
#     issue-close   <n> [--comment <c>]                   → closes an issue
#     link-subissue <parent> <child>                      → nests child under
#                                                            parent as a native
#                                                            GitHub sub-issue
#     pr-create     --head <h> --base <b> --title <t> --body <b2> [--closes <n>…]
#                                                          → echoes the PR URL
#     pr-merge      [--number <n>|--head <branch>] [--method <m>] → merges the PR
#     pr-view       [--number <n>|--head <branch>]        → echoes `state\t<S>` +
#     (pr-status)                                            `mergedAt\t<v>` lines
#     pr-close      [--number <n>|--head <branch>]        → closes (no merge)
#
# Best-effort, jq-free, pure where possible. "Best-effort" means a forge failure
# NEVER aborts the CALLER's process — the adapter does not `die`/`exit` on a forge
# error — NOT that it masks the failure. The relabel/close ops PROPAGATE gh's
# non-zero rc so the caller (which already invokes them inside `if ! host …` /
# `host … ||`) can learn the op did not happen and set its "do it by hand" note;
# create echoes nothing on failure (its caller keys off empty output, not rc). An
# unknown host id or op is a HARD error (a `die` with a message), never a silent
# no-op — distinct from the SOFT non-zero of a forge failure (no die message).
#
set -uo pipefail

HOST="${LCARS_HOST_BIN:-github}"
GH_BIN="${LCARS_GH_BIN:-gh}"

die() { printf 'host-adapter: %s\n' "$1" >&2; exit 1; }

# --- GitHub Enterprise: pin the host for `gh api` ---------------------------
#
# `gh issue` / `gh pr` resolve the forge host from the repo's own remote, so they
# already work on an enterprise host. `gh api` does NOT — it targets the DEFAULT
# host and only substitutes `{owner}/{repo}` from the cwd repo. On a *.ghe.com
# repo that silently talks to github.com:
#
#   $ gh api "repos/{owner}/{repo}"
#   {"message":"Not Found","documentation_url":"https://docs.github.com/..."}
#
# — a 404 from *docs.github.com*, with a perfectly valid enterprise login present.
# Every api-backed op (the S65 living stage comments, sub-issue linking) therefore
# failed invisibly on enterprise, because they all discard stderr.
#
# gh_hostname echoes the host to pin, or NOTHING when the default is already
# right. Returning empty for github.com is deliberate: the argv then stays
# byte-for-byte what it has always been, so the adapter's regression locks in
# tests/host-adapter.test.sh keep their meaning and github.com users see no
# change whatsoever.
gh_hostname() {
  if [ -n "${LCARS_GH_HOST:-}" ]; then printf '%s' "$LCARS_GH_HOST"; return 0; fi
  local url h
  url="$("${LCARS_GIT_BIN:-git}" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$url" ] || return 0
  h="${url#*://}"    # drop scheme (https://, ssh://, git://)
  h="${h#*@}"        # drop user@ (scp-style git@host:owner/repo)
  h="${h%%/*}"       # drop the path
  h="${h%%:*}"       # drop :port, and the scp-style ":owner/repo"
  case "$h" in ''|github.com) return 0 ;; esac
  printf '%s' "$h"
}

# gh_api — `gh api`, host-pinned when this repo is not on github.com. Every api
# call in this adapter goes through here so a new op cannot forget the host.
gh_api() {
  local h; h="$(gh_hostname)"
  if [ -n "$h" ]; then
    "$GH_BIN" api --hostname "$h" "$@"
  else
    "$GH_BIN" api "$@"
  fi
}

# Append `Closes #<n>` directives to a PR body. GitHub and GitLab both honour
# this in a PR/MR description, so the merge→close tie is host-portable rather
# than gh-only. With no issues the body is returned byte-for-byte unchanged.
append_closes() { # body  n…
  local body="$1"; shift
  local n
  for n in "$@"; do
    [ -n "$n" ] || continue
    body="$body
Closes #$n"
  done
  printf '%s' "$body"
}

# --- the github host: maps each op to today's exact gh argv -----------------
github_issue_create() { # --title <t> --body <b> --label <l>…
  local title="" body="" labels=() url
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift 2 ;;
      --body)  body="${2:-}";  shift 2 ;;
      --label) labels+=("${2:-}"); shift 2 ;;
      *) die "issue-create: unknown argument: $1" ;;
    esac
  done
  # Forward exactly the labels we were given (the caller owns label composition),
  # mirroring create_issue's `gh issue create --title … --body … --label …` and
  # echoing the URL's trailing path segment as the new issue number.
  local labelargs=() l
  for l in "${labels[@]:-}"; do [ -n "$l" ] && labelargs+=(--label "$l"); done
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    if url="$("$GH_BIN" issue create --title "$title" --body "$body" "${labelargs[@]}" 2>/dev/null)"; then
      url="$(printf '%s' "$url" | tail -1)"
      printf '%s' "${url##*/}"
      return 0
    fi
  fi
  # Best-effort: gh missing or create failed → echo nothing, never block.
  return 0
}

github_issue_comment() { # <n> --body <b>
  local issue="" body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --body) body="${2:-}"; shift 2 ;;
      -*) die "issue-comment: unknown flag: $1" ;;
      *)  issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "issue-comment: missing issue number"
  # Best-effort like notify.sh: a forge failure NEVER aborts the caller's run.
  # gh absent → soft non-zero (the mirror swallows it); gh present → PROPAGATE
  # gh's rc so the mirror can decide whether the post landed (it only writes the
  # comment_mirrored marker on success, so a transient failure is retried next
  # pass). The `gh issue comment <n> --body <b>` argv is the canonical form.
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue comment "$issue" --body "$body" >/dev/null 2>&1
  return $?
}

# github_issue_comment_create <n>  — body on STDIN — echoes the NEW comment id.
# Session 65 (living per-stage comments): the create op must RETURN the created
# comment's id so the mirror can EDIT it in place later. Bodies are large/
# multiline (rich <details> dashboards) so they come via STDIN and are POSTed
# with `-F body=@-` (the `-F/--field` form READS stdin; `-f/--raw-field` would
# store the literal string "@-" — that was the S65 #188 defect). Parse `.id` jq-free
# from the returned JSON. Best-effort like notify.sh: gh absent/failing → echo
# NOTHING (the mirror keys off empty output), never a die, never abort the run.
github_issue_comment_create() { # <n>   (body on stdin)
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-comment-create: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  local out id
  out="$(gh_api --method POST \
        "repos/{owner}/{repo}/issues/$issue/comments" -F body=@- 2>/dev/null)" || return 0
  # Parse the comment's own "id":<n> from the response, jq-free. The real gh
  # response is a SINGLE line carrying several "id" fields (the comment id FIRST,
  # then a nested user.id, etc.); a greedy `.*"id"` match would grab the LAST id
  # (the user's) and corrupt the create→edit map. Split on object/array
  # punctuation so each "id" lands on its own line, then take the FIRST one.
  id="$(printf '%s' "$out" | tr ',{}[]' '\n\n\n\n\n' \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [ -n "$id" ] && printf '%s' "$id"
  return 0
}

# github_issue_comment_edit <comment-id>  — body on STDIN — PATCH that comment.
# The in-place edit of a living per-stage comment. Best-effort: gh absent →
# soft non-zero (the mirror swallows it); a PATCH failure propagates gh's rc so
# the mirror can leave its on-disk truth and retry next pass. Body via stdin.
github_issue_comment_edit() { # <comment-id>   (body on stdin)
  local cid="${1:-}"
  [ -n "$cid" ] || die "issue-comment-edit: missing comment id"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  gh_api --method PATCH \
    "repos/{owner}/{repo}/issues/comments/$cid" -F body=@- >/dev/null 2>&1
  return $?
}

github_issue_relabel() { # <n> --add <labels> --remove <labels>
  local issue="" add="" rem="" l
  while [ $# -gt 0 ]; do
    case "$1" in
      --add)    add="${2:-}"; shift 2 ;;
      --remove) rem="${2:-}"; shift 2 ;;
      -*) die "issue-relabel: unknown flag: $1" ;;
      *)  issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "issue-relabel: missing issue number"
  # Exactly gh_relabel's argv: --add-label per add label, --remove-label per
  # remove label, in add-then-remove order. Best-effort means we never `die`,
  # but we PROPAGATE gh's rc so the caller can fire its "relabel by hand" note.
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    local args=()
    for l in $add; do args+=(--add-label "$l"); done
    for l in $rem; do args+=(--remove-label "$l"); done
    "$GH_BIN" issue edit "$issue" "${args[@]}" >/dev/null 2>&1
    return $?
  fi
  # gh absent (callers already guard this themselves) → soft non-zero, not a die.
  return 1
}

github_issue_close() { # <n> [--comment <c>]
  local issue="" comment="" have_comment=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --comment) comment="${2:-}"; have_comment=1; shift 2 ;;
      -*) die "issue-close: unknown flag: $1" ;;
      *)  issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "issue-close: missing issue number"
  # Best-effort like relabel: never `die`, but PROPAGATE gh's rc so a future
  # caller can detect the close did not happen (no live caller today — session 29).
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    if [ "$have_comment" -eq 1 ]; then
      "$GH_BIN" issue close "$issue" --comment "$comment" >/dev/null 2>&1
    else
      "$GH_BIN" issue close "$issue" >/dev/null 2>&1
    fi
    return $?
  fi
  # gh absent → soft non-zero, not a die.
  return 1
}

github_link_subissue() { # <parent_number> <child_number>
  local parent="${1:-}" child="${2:-}" id rc
  [ -n "$parent" ] || die "link-subissue: missing parent issue number"
  [ -n "$child" ]  || die "link-subissue: missing child issue number"
  # Best-effort like relabel/close: never `die` on a forge error, but PROPAGATE
  # a non-zero rc so cmd_schedule can set its "nest by hand" note. gh absent →
  # soft non-zero (callers already guard this themselves too).
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  # Native GitHub sub-issue linking takes the child's DATABASE id, NOT its issue
  # number. Resolve it; {owner}/{repo} are substituted by gh from the cwd repo.
  id="$(gh_api "repos/{owner}/{repo}/issues/$child" --jq .id 2>/dev/null)"
  [ -n "$id" ] || return 1
  # POST the link. CRITICAL: sub_issue_id MUST be a TYPED integer — use `-F`
  # (capital F = typed). `-f` would send a STRING and the API returns HTTP 422
  # ("not of type integer"). Never regress this to `-f`.
  gh_api --method POST "repos/{owner}/{repo}/issues/$parent/sub_issues" \
    -F sub_issue_id="$id" >/dev/null 2>&1
  rc=$?
  return $rc
}

# github_pr_merge — merge an open PR. Identify it by --number (the PR number) OR
# --head (the branch); gh accepts either as the [<number> | <url> | <branch>]
# selector. Best-effort like relabel/close: never `die` on a forge error, but
# PROPAGATE gh's rc so the caller (approve) learns the merge did not happen and
# stays at verify (no false Done). `--method` (merge|squash|rebase) is optional;
# we default to a plain merge commit. gh absent → soft non-zero.
github_pr_merge() { # [--number <n>] [--head <branch>] [--method <m>]
  local number="" head="" method="" sel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) number="${2:-}"; shift 2 ;;
      --head)   head="${2:-}";   shift 2 ;;
      --method) method="${2:-}"; shift 2 ;;
      -*) die "pr-merge: unknown flag: $1" ;;
      *)  sel="$1"; shift ;;
    esac
  done
  # Prefer an explicit --number, then the bare positional, then the branch.
  [ -n "$number" ] && sel="$number"
  [ -n "$sel" ] || sel="$head"
  [ -n "$sel" ] || die "pr-merge: need --number or --head to identify the PR."
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  local margs=(--"${method:-merge}")
  "$GH_BIN" pr merge "$sel" "${margs[@]}" >/dev/null 2>&1
  return $?
}

# github_pr_view — read a PR's merge state. Identify it by --number or --head.
# Echoes two lines: `state\t<STATE>` and `mergedAt\t<value>` parsed jq-free from
# `gh pr view <sel> --json state,mergedAt`, so the caller can decide "merged" =
# state == MERGED or mergedAt non-null. Best-effort: gh absent/failing → echo
# nothing (the caller keys off empty output, like create), never a die.
github_pr_view() { # [--number <n>] [--head <branch>]
  local number="" head="" sel="" out st merged
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) number="${2:-}"; shift 2 ;;
      --head)   head="${2:-}";   shift 2 ;;
      -*) die "pr-view: unknown flag: $1" ;;
      *)  sel="$1"; shift ;;
    esac
  done
  [ -n "$number" ] && sel="$number"
  [ -n "$sel" ] || sel="$head"
  [ -n "$sel" ] || die "pr-view: need --number or --head to identify the PR."
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  out="$("$GH_BIN" pr view "$sel" --json state,mergedAt 2>/dev/null)" || return 0
  # jq-free: split the single-line JSON so each field lands alone, then pluck.
  st="$(printf '%s' "$out" | tr ',{}' '\n\n\n' \
        | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  # mergedAt is either a quoted ISO stamp or the bare token `null`; pluck the raw
  # value after the colon, strip quotes/trailing space (portable BRE — no `\?`).
  merged="$(printf '%s' "$out" | tr ',{}' '\n\n\n' \
        | sed -n 's/.*"mergedAt"[[:space:]]*:[[:space:]]*//p' \
        | sed 's/"//g; s/[[:space:]]*$//' | head -1)"
  printf 'state\t%s\n' "$st"
  printf 'mergedAt\t%s\n' "$merged"
  return 0
}

# github_pr_close — close (without merging) an open PR. Identify it by --number
# or --head. Best-effort like issue-close: never `die`, PROPAGATE gh's rc so the
# caller (feedback's send-back) can note a close-by-hand. gh absent → non-zero.
github_pr_close() { # [--number <n>] [--head <branch>]
  local number="" head="" sel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) number="${2:-}"; shift 2 ;;
      --head)   head="${2:-}";   shift 2 ;;
      -*) die "pr-close: unknown flag: $1" ;;
      *)  sel="$1"; shift ;;
    esac
  done
  [ -n "$number" ] && sel="$number"
  [ -n "$sel" ] || sel="$head"
  [ -n "$sel" ] || die "pr-close: need --number or --head to identify the PR."
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" pr close "$sel" >/dev/null 2>&1
  return $?
}

github_pr_create() { # --head <h> --base <b> --title <t> --body <b2> [--closes <n>…]
  local head="" base="" title="" body="" closes=() url
  while [ $# -gt 0 ]; do
    case "$1" in
      --head)   head="${2:-}";  shift 2 ;;
      --base)   base="${2:-}";  shift 2 ;;
      --title)  title="${2:-}"; shift 2 ;;
      --body)   body="${2:-}";  shift 2 ;;
      --closes) closes+=("${2:-}"); shift 2 ;;
      *) die "pr-create: unknown argument: $1" ;;
    esac
  done
  # Render host-portable auto-close directives INTO the body. With no --closes
  # the body is unchanged (byte-for-byte regression for today's approve PR).
  body="$(append_closes "$body" "${closes[@]:-}")"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  # Exactly approve's argv + `| tail -1` URL semantics.
  url="$("$GH_BIN" pr create --title "$title" --body "$body" --head "$head" --base "$base" 2>/dev/null | tail -1)"
  printf '%s' "$url"
  return 0
}

# --- dispatch ---------------------------------------------------------------
[ $# -ge 1 ] || die "no op — usage: host-adapter.sh <op> [args…]"
OP="$1"; shift

case "$HOST" in
  github) : ;;
  *) die "unknown host '$HOST' — no integration for this forge." ;;
esac

case "$OP" in
  issue-create)         github_issue_create  "$@" ;;
  issue-comment)        github_issue_comment "$@" ;;
  issue-comment-create) github_issue_comment_create "$@" ;;
  issue-comment-edit)   github_issue_comment_edit "$@" ;;
  issue-relabel) github_issue_relabel "$@" ;;
  issue-close)   github_issue_close   "$@" ;;
  link-subissue) github_link_subissue "$@" ;;
  pr-create)     github_pr_create     "$@" ;;
  pr-merge)      github_pr_merge      "$@" ;;
  pr-view|pr-status) github_pr_view   "$@" ;;
  pr-close)      github_pr_close      "$@" ;;
  *) die "unknown op '$OP'." ;;
esac
