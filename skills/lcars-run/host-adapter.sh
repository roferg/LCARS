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
#     issue-relabel <n> --add <labels> --remove <labels>  → relabels an issue
#     issue-close   <n> [--comment <c>]                   → closes an issue
#     link-subissue <parent> <child>                      → nests child under
#                                                            parent as a native
#                                                            GitHub sub-issue
#     pr-create     --head <h> --base <b> --title <t> --body <b2> [--closes <n>…]
#                                                          → echoes the PR URL
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
  id="$("$GH_BIN" api "repos/{owner}/{repo}/issues/$child" --jq .id 2>/dev/null)"
  [ -n "$id" ] || return 1
  # POST the link. CRITICAL: sub_issue_id MUST be a TYPED integer — use `-F`
  # (capital F = typed). `-f` would send a STRING and the API returns HTTP 422
  # ("not of type integer"). Never regress this to `-f`.
  "$GH_BIN" api --method POST "repos/{owner}/{repo}/issues/$parent/sub_issues" \
    -F sub_issue_id="$id" >/dev/null 2>&1
  rc=$?
  return $rc
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
  issue-create)  github_issue_create  "$@" ;;
  issue-comment) github_issue_comment "$@" ;;
  issue-relabel) github_issue_relabel "$@" ;;
  issue-close)   github_issue_close   "$@" ;;
  link-subissue) github_link_subissue "$@" ;;
  pr-create)     github_pr_create     "$@" ;;
  *) die "unknown op '$OP'." ;;
esac
