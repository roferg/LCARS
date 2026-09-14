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
#     issue-edit-body <n>           (body on STDIN)       → REPLACES an issue's
#                                                            BODY in place (the
#                                                            S188 handoff refresh
#                                                            at the two transfer
#                                                            points). Body via
#                                                            stdin → no argv
#                                                            limit, same as the
#                                                            comment ops.
#     issue-relabel <n> --add <labels> --remove <labels>  → relabels an issue
#     label-ensure <name>|<color>|<desc> …                → creates any of those
#                                                            labels the repo does
#                                                            NOT already have, and
#                                                            echoes the names it
#                                                            created. ONE listing
#                                                            call, then a create
#                                                            per missing label —
#                                                            so a forge whose
#                                                            labels predate a
#                                                            round costs one call
#                                                            and a settled one
#                                                            costs one call and
#                                                            no writes.
#     issue-close   <n> [--comment <c>]                   → closes an issue
#     whoami                                              → echoes the LOGIN this
#                                                            repo's forge host is
#                                                            authenticated as
#                                                            (S189 identity). Goes
#                                                            through gh_api, so it
#                                                            reads the identity of
#                                                            THIS repo's host and
#                                                            not the default one.
#     issue-assignees <n>                                 → the issue's assignee
#                                                            LOGINS, one per line.
#                                                            UNASSIGNED prints
#                                                            NOTHING at rc=0 —
#                                                            empty is a valid
#                                                            answer, not an error.
#     issue-assign   <n> <login>                          → assigns the login, then
#                                                            READS BACK to confirm
#                                                            (gh's rc=0 is NOT
#                                                            proof — see below).
#     issue-unassign <n> <login>                          → removes the login
#                                                            (idempotent silent
#                                                            no-op when it was not
#                                                            assigned).
#     issue-body     <n>                                  → the issue's BODY,
#                                                            verbatim (S189
#                                                            adopt's one spec
#                                                            input).
#     issue-title    <n>                                  → the issue's TITLE.
#     issue-labels   <n>                                  → the issue's label
#                                                            NAMES, one per line.
#                                                            This is where the
#                                                            mission's STAGE
#                                                            comes from — the
#                                                            envelope deliberately
#                                                            carries no stage.
#     issue-closing-prs <n>                               → the OPEN PRs that
#                                                            would CLOSE this
#                                                            issue, as
#                                                            `<number>\t<url>`
#                                                            lines. Nothing at
#                                                            rc=0 means no such
#                                                            PR. See the spike
#                                                            record before
#                                                            changing it.
#     link-subissue <parent> <child>                      → nests child under
#                                                            parent as a native
#                                                            GitHub sub-issue
#     pr-create     --head <h> --base <b> --title <t> --body <b2> [--closes <n>…]
#                                                          → echoes the PR URL
#     pr-merge      [--number <n>|--head <branch>] [--method <m>] → merges the PR
#     pr-view       [--number <n>|--head <branch>]        → echoes `state\t<S>` +
#     (pr-status)                                            `mergedAt\t<v>` lines
#     pr-close      [--number <n>|--head <branch>]        → closes (no merge)
#     gh-host                                             → echoes the forge host
#                                                            this repo lives on,
#                                                            or NOTHING on
#                                                            github.com / no
#                                                            remote (S168). A
#                                                            pure READ of the
#                                                            origin remote — no
#                                                            gh, no network — so
#                                                            a non-bash caller
#                                                            (the viewscreen
#                                                            daemon) can ask THIS
#                                                            implementation
#                                                            instead of growing
#                                                            a second one.
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

# github_issue_edit_body <n>  — body on STDIN — REPLACE the issue's body.
#
# S188: the ONE op that pushes a recomposed issue body. It mirrors the filing
# lanes' own `gh issue edit <n> --body-file <f>` argv — the same command, with
# `-` for the file so the body arrives on stdin and can be arbitrarily large
# (a PRD + ADR + Estimate section is well past a comfortable argv). Deliberately
# `gh issue edit` and NOT `gh api`: `gh issue` resolves the forge host from the
# repo's own remote, so this works on GitHub Enterprise with no host pinning and
# stays byte-comparable to what file.sh has always sent.
#
# Best-effort like relabel/close: never `die` on a forge error, but PROPAGATE
# gh's rc so the caller learns the push did not land (the refresh keys off that
# to retry at the next transfer point rather than record a false "pushed").
# gh absent → soft non-zero.
github_issue_edit_body() { # <n>   (body on stdin)
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-edit-body: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue edit "$issue" --body-file - >/dev/null 2>&1
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

# label-ensure — the create-if-missing half of the label set, for the labels a
# round INTRODUCES. `lcars init` creates the whole canonical set on a fresh repo;
# a repo initialized before this round has none of the new family, and the score
# swap would then relabel an issue with a label the forge has never heard of.
#
# LIST ONCE, CREATE WHAT IS MISSING. Never `--force`: a label already on the repo
# is left exactly as it is, colour, description and all — this op adds, it does
# not curate. Best-effort like relabel (gh absent → soft non-zero, never a die),
# because a forge that is down must never lose a verdict that is already on disk.
github_label_ensure() { # <name>|<color>|<description> …
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  local existing rc=0 spec rest name color desc
  existing="$("$GH_BIN" label list --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
  for spec in "$@"; do
    name="${spec%%|*}"; rest="${spec#*|}"
    color="${rest%%|*}"; desc="${rest#*|}"
    [ -n "$name" ] || continue
    printf '%s\n' "$existing" | grep -Fxq "$name" && continue
    if "$GH_BIN" label create "$name" --color "$color" \
         --description "$desc" >/dev/null 2>&1; then
      printf '%s\n' "$name"
    else
      rc=1
    fi
  done
  return "$rc"
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

# ===========================================================================
# S189 — IDENTITY AND ASSIGNEES. The forge half of solo ownership.
#
# The whole design rests on three facts measured against real gh 2.96.0 and
# recorded in ADOPT-RESOLUTION-SPIKE.md (LEG A). Read that file before changing
# anything here; each one is a silent-failure trap, not a style preference.
# ===========================================================================

# github_whoami — the LOGIN this repo's forge host is authenticated as.
#
# `.login` is THE identity key: it is the same string `--add-assignee` takes and
# the same string `assignees[].login` returns. It is NOT `.id` — the SAME login
# has a DIFFERENT numeric id per host (40493721 on github.com, 97261 on the
# enterprise host for the captain's own account), so an id is not a portable
# identity and must never be compared across hosts. Identity is the (host, login)
# PAIR. `.name` is nullable and is not read here at all.
#
# MANDATORY: this goes through gh_api, never a bare `gh api`. `gh issue`/`gh pr`
# resolve the forge from the repo's own remote, but `gh api` does NOT — a bare
# `gh api user` inside a *.ghe.com checkout returns the GITHUB.COM account's
# identity, with no error. That is the S168 class of silent bug, and reading the
# wrong forge's identity is exactly what makes the light lock lock the wrong
# person out. gh_api pins --hostname off the origin remote (and emits argv
# byte-identical to today's on github.com).
#
# Best-effort: gh absent or failing → echo NOTHING and soft non-zero, never a
# die. Callers key off the empty output.
github_whoami() { # (no args)
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  local login
  login="$(gh_api user --jq .login 2>/dev/null)" || return 1
  [ -n "$login" ] || return 1
  printf '%s\n' "$login"
  return 0
}

# github_issue_assignees <n> — the assignee LOGINS, one per line.
#
# `gh issue view` self-resolves the forge host from the repo's own remote, so no
# host pin here (same reasoning as github_issue_edit_body).
#
# AN UNASSIGNED ISSUE PRINTS NOTHING AND RETURNS 0. GitHub returns an empty
# ARRAY for "nobody" — never `null`, never a missing key — on both the
# `--json assignees` and the REST path, at rc=0 in every case. So "unowned" is
# EMPTY OUTPUT, not a failure, and the light lock must read it as "nobody owns
# this, my verbs are allowed". Returning non-zero here would turn every
# unassigned mission into an error.
github_issue_assignees() { # <n>
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-assignees: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  local out
  out="$("$GH_BIN" issue view "$issue" --json assignees --jq '.assignees[].login' 2>/dev/null)" \
    || return 1
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# github_issue_assign <n> <login> — assign, THEN READ BACK AND CONFIRM.
#
# *** THE LOAD-BEARING FAILURE MODE OF THIS WHOLE SESSION. ***
#
# Assigning a REAL user who cannot be assigned on this repo (a private repo they
# have no access to) returns rc=0 WITH A SUCCESS-SHAPED ISSUE URL, and the
# assignment silently does not happen. The REST path lies identically: HTTP 201
# with a full issue payload whose `assignees` is []. Only a NONEXISTENT login
# fails loudly (rc=1, a GraphQL "could not resolve to a user or bot").
#
# So rc=0 IS NOT PROOF. Without the read-back below, LCARS records "this mission
# is mine" for an assignment GitHub refused — and the second laptop sees an
# unowned mission while this one thinks it holds it. That is the exact bug the
# light lock exists to prevent, arriving through the lock itself.
#
# The refusal message must NOT say the login does not exist: the assignability
# endpoint (repos/{owner}/{repo}/assignees/<login>) returns a bare 404 for BOTH
# "real user without access" and "no such user", so nothing available here can
# tell them apart. We say what we actually know — the assignment did not stick.
#
# Idempotent: assigning a login that is already assigned is a silent no-op at
# gh's end and the read-back confirms it, so this returns 0.
github_issue_assign() { # <n> <login>
  local issue="${1:-}" login="${2:-}"
  [ -n "$issue" ] || die "issue-assign: missing issue number"
  [ -n "$login" ] || die "issue-assign: missing login"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  if ! "$GH_BIN" issue edit "$issue" --add-assignee "$login" >/dev/null 2>&1; then
    printf 'host-adapter: issue-assign: gh refused to assign %s to #%s.\n' "$login" "$issue" >&2
    return 1
  fi
  # THE READ-BACK. Never trust the rc above.
  local back
  back="$(github_issue_assignees "$issue")" || {
    printf 'host-adapter: issue-assign: assigned %s to #%s but could not read the assignees back to confirm it.\n' \
      "$login" "$issue" >&2
    return 1
  }
  if printf '%s\n' "$back" | grep -qx -- "$login"; then
    return 0
  fi
  printf 'host-adapter: issue-assign: GitHub accepted the request but #%s is still not assigned to %s — that login cannot be assigned on this repo (no access, or the account is not reachable from here). Assign it on GitHub.\n' \
    "$issue" "$login" >&2
  return 1
}

# github_issue_unassign <n> <login> — remove an assignee.
#
# No read-back here, deliberately: the spike found no silent-drop mode on the
# REMOVE side. Removing a login that is not assigned is an idempotent silent
# no-op at rc=0, and removing one that is assigned takes effect at rc=0. The
# asymmetry is a measured fact, not an oversight — see ADOPT-RESOLUTION-SPIKE.md
# A.3 cases 4 and 5. Best-effort like relabel/close: never `die`, but PROPAGATE
# gh's rc so the caller learns the removal did not happen.
github_issue_unassign() { # <n> <login>
  local issue="${1:-}" login="${2:-}"
  [ -n "$issue" ] || die "issue-unassign: missing issue number"
  [ -n "$login" ] || die "issue-unassign: missing login"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue edit "$issue" --remove-assignee "$login" >/dev/null 2>&1
  return $?
}

# ===========================================================================
# S189 leg B — THE READ OPS `lcars adopt` REBUILDS A MISSION FROM.
#
# A second laptop has no `.git/lcars` at all, so everything adopt knows comes
# back through these four ops. Three of them are plain reads of the issue; the
# fourth answers the one genuinely hard question — "which OPEN pull request
# closes this issue?" — and its implementation is the recorded outcome of the
# S189 spike (ADOPT-RESOLUTION-SPIKE.md, LEG B). Read that before touching it.
#
# All four use `gh issue`/`gh pr`, which self-resolve the forge host from the
# repo's own remote, so none of them needs the gh_api host pin (spike B.5).
# ===========================================================================

# github_issue_body <n> — the issue's body, verbatim, on stdout.
#
# THE ONE INPUT `lcars adopt` REBUILDS THE SPEC FROM. It is emitted byte-for-byte
# as GitHub holds it — including the trailing `<!-- lcars:handoff v1 … -->`
# envelope, which is the caller's to parse (issue-body.sh owns that grammar, and
# no second reader of it may grow here). An issue with an EMPTY body prints
# nothing at rc=0: empty is a valid body, not a failure.
github_issue_body() { # <n>
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-body: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue view "$issue" --json body --jq .body 2>/dev/null
  return $?
}

# github_issue_title <n> — the issue's title on one line.
github_issue_title() { # <n>
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-title: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue view "$issue" --json title --jq .title 2>/dev/null
  return $?
}

# github_issue_labels <n> — the issue's label NAMES, one per line.
#
# This is how `lcars adopt` learns the mission's STAGE, and the reason it is a
# label rather than a field in the handoff envelope: the envelope is refreshed at
# exactly TWO transfer points (S188), so an envelope stage would be stale
# mid-pipeline BY CONSTRUCTION, while `lcars:<stage>` is swapped at every single
# stage transition and is already what the github board adapter treats as the
# canonical remote stage (web/lcars_serve/github_adapter.py:_stage_of). One
# source per fact.
#
# An issue with NO labels prints nothing at rc=0 — same shape as issue-assignees.
github_issue_labels() { # <n>
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-labels: missing issue number"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  local out
  out="$("$GH_BIN" issue view "$issue" --json labels --jq '.labels[].name' 2>/dev/null)" || return 1
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# github_issue_closing_prs <n> — the OPEN PRs that would close this issue, as
# `<number><TAB><url>` lines. Nothing + rc=0 means "no such PR".
#
# *** THE SPIKE'S RECORDED WINNER (B.1/B.5), AND WHY IT IS NOT THE OBVIOUS ONE ***
#
# `gh issue view <n> --json closedByPullRequestsReferences` asks GitHub the exact
# question, computed from the parsed closing keywords plus UI-created development
# links. Measured against real gh 2.96.0 on a deliberately adversarial fixture:
#   * it EXCLUDES a decoy PR that merely mentions the issue (a text search does
#     not — `gh pr list --search "Closes #2"` returned the decoy);
#   * it SELF-FILTERS TO LIVE PRs — a closed-unmerged PR vanishes from the list,
#     so adopt cannot latch onto an abandoned PR without a second state call;
#   * it returns the `url` verbatim — the SAME string open_pr() records as
#     state.json's prUrl, so an adopted mission's PR fields are byte-identical to
#     the originating laptop's and approve/feedback work with no reconstruction;
#   * it resolves from a SUB-ISSUE too (a ticket resolves to its wave's PR);
#   * it is a LIVE GraphQL read, not the search index.
#
# That last point is why `gh pr list --search` is REJECTED outright rather than
# kept as a fallback: GitHub's search index is eventually consistent and was
# observed stale in BOTH directions (a just-closed PR still reported OPEN for
# ~a minute). `lcars adopt` runs the INSTANT Verify opens the PR — precisely when
# that index is least trustworthy.
#
# DETECTION, NOT VERSION-GATING. An older gh (or a GHES whose GraphQL schema
# lags) answers rc=1 with `Unknown JSON field: "…"`. The spike could not
# establish which gh release introduced the field, so this probes and reacts
# instead of comparing version numbers — the same signal covers a client that is
# too old and a server that is too old.
#
# AMBIGUITY WE DO NOT PAPER OVER (failure mode 11): an empty result at rc=0 means
# "there is no PR" AND "the only PR is closed-unmerged", indistinguishably. This
# op reports empty and says nothing more; a caller that needs to tell those apart
# must scan with --state all, and none does today.
github_issue_closing_prs() { # <n>
  local issue="${1:-}"
  [ -n "$issue" ] || die "issue-closing-prs: missing issue number"
  case "$issue" in *[!0-9]*) die "issue-closing-prs: not an issue number: $issue" ;; esac
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1

  local outf errf rc=0
  outf="$(mktemp)" || return 1
  errf="$(mktemp)" || { rm -f "$outf"; return 1; }
  "$GH_BIN" issue view "$issue" --json closedByPullRequestsReferences \
    --jq '.closedByPullRequestsReferences[] | [(.number|tostring), .url] | @tsv' \
    >"$outf" 2>"$errf" || rc=$?

  if [ "$rc" -eq 0 ]; then
    cat "$outf"
    rm -f "$outf" "$errf"
    return 0
  fi

  # A genuinely missing issue is NOT a reason to fall back — scanning every open
  # PR for a directive naming an issue that does not exist would answer a
  # question nobody asked, slowly. Everything else (the `Unknown JSON field:`
  # case above all) means "this gh/host cannot answer the question", which is
  # exactly what the fallback is for.
  if grep -qi 'could not resolve to an issue' "$errf" 2>/dev/null; then
    cat "$errf" >&2
    rm -f "$outf" "$errf"
    return 1
  fi
  rm -f "$outf" "$errf"
  github_closing_prs_fallback "$issue"
}

# github_closing_prs_fallback <n> — scan OPEN PR bodies for the anchored
# directive. The spike's candidate 4, chosen over `--search` on CORRECTNESS:
# `gh pr list` hits the LIST endpoint, which has no index lag, so a PR opened one
# second ago is already there — the exact case adopt lives in.
#
# Its three real limits, all measured, all stated on stderr when it runs:
#   * the match MUST be anchored — unanchored, `Closes #2` also matches
#     `Closes #21` (failure mode 14). Hence `(?m)^Closes #<n>$`.
#   * `--limit` is a SILENT ceiling: a repo with more open PRs than the limit can
#     miss the answer and say nothing. LCARS_PR_SCAN_LIMIT tunes it.
#   * it only sees PRs whose body carries the directive LCARS writes. A PR linked
#     by hand through GitHub's Development sidebar has no body text at all and is
#     invisible here — the winner sees it, this does not.
#
# The directive's spelling is load-bearing (failure mode 15): `Closes #<n>`,
# capital C, one per line, appended at the END of the body by append_closes()
# above. If that ever changes, this changes with it — they are one unit.
github_closing_prs_fallback() { # <n>
  local issue="${1:-}" limit="${LCARS_PR_SCAN_LIMIT:-100}"
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  printf 'host-adapter: issue-closing-prs: this gh cannot answer closedByPullRequestsReferences — scanning the %s most recent OPEN PRs for `Closes #%s` instead (a PR linked without that line, or beyond the limit, will be missed).\n' \
    "$limit" "$issue" >&2
  "$GH_BIN" pr list --state open --limit "$limit" --json number,url,body \
    --jq '.[] | select(.body | test("(?m)^Closes #'"$issue"'$")) | [(.number|tostring), .url] | @tsv' \
    2>/dev/null
  return 0
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
  issue-edit-body)      github_issue_edit_body "$@" ;;
  issue-relabel) github_issue_relabel "$@" ;;
  label-ensure)  github_label_ensure  "$@" ;;
  issue-close)   github_issue_close   "$@" ;;
  whoami)          github_whoami          "$@" ;;
  issue-assignees) github_issue_assignees "$@" ;;
  issue-assign)    github_issue_assign    "$@" ;;
  issue-unassign)  github_issue_unassign  "$@" ;;
  issue-body)        github_issue_body        "$@" ;;
  issue-title)       github_issue_title       "$@" ;;
  issue-labels)      github_issue_labels      "$@" ;;
  issue-closing-prs) github_issue_closing_prs "$@" ;;
  link-subissue) github_link_subissue "$@" ;;
  pr-create)     github_pr_create     "$@" ;;
  pr-merge)      github_pr_merge      "$@" ;;
  pr-view|pr-status) github_pr_view   "$@" ;;
  pr-close)      github_pr_close      "$@" ;;
  gh-host)       gh_hostname; exit 0 ;;
  *) die "unknown op '$OP'." ;;
esac
