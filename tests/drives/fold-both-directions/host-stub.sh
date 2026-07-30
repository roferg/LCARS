#!/usr/bin/env bash
# A LOCAL stand-in for skills/lcars-run/host-adapter.sh — the ONE seam LCARS uses
# to talk to a forge. Everything else in the drive is real: real copilot workers,
# real TDD, real commits, real fold, real approve. Only the forge is local, so the
# proof needs no GitHub repo and cannot touch one.
#
# `pr-merge` performs a REAL merge: it fast-forwards origin/main to the mission
# branch tip (the branch IS main + the mission's commits, so a fast-forward IS the
# merge). That is what makes "did the folded bug code actually reach main?" a
# genuine check rather than a simulated one.
set -uo pipefail
CMD="${1:-}"; shift || true
STATE_DIR="${DRIVE_STATE:?DRIVE_STATE not set}"
ORIGIN="${DRIVE_ORIGIN:?DRIVE_ORIGIN not set}"
REPO="${DRIVE_REPO:?DRIVE_REPO not set}"
LOG="$STATE_DIR/host.log"
echo "host $CMD $*" >>"$LOG"

next_num() {
  local f="$STATE_DIR/counter"; local n=1
  [ -f "$f" ] && n=$(( $(cat "$f") + 1 ))
  echo "$n" >"$f"; echo "$n"
}

arg() { # arg <name> <args...>
  local want="$1"; shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$want" ]; then echo "${2:-}"; return 0; fi
    shift
  done
  echo ""
}

case "$CMD" in
  issue-create)
    next_num ;;
  pr-create)
    head="$(arg --head "$@")"
    n="$(next_num)"
    echo "$n	$head" >>"$STATE_DIR/prs"
    echo "https://example.invalid/acme/repo/pull/$n" ;;
  pr-merge)
    num="$(arg --number "$@")"; head="$(arg --head "$@")"
    if [ -z "$head" ] && [ -n "$num" ]; then
      head="$(awk -F'\t' -v n="$num" '$1==n{print $2}' "$STATE_DIR/prs" | tail -1)"
    fi
    [ -n "$head" ] || { echo "pr-merge: cannot resolve a branch" >&2; exit 1; }
    # THE REAL MERGE: fast-forward origin/main to the branch tip.
    if git -C "$REPO" push "$ORIGIN" "$head:refs/heads/main" >>"$LOG" 2>&1; then
      echo "merged $head -> main" ; echo "$head" >>"$STATE_DIR/merged"
    else
      echo "pr-merge: push refused" >&2; exit 1
    fi ;;
  pr-view)
    head="$(arg --head "$@")"; num="$(arg --number "$@")"
    if [ -z "$head" ] && [ -n "$num" ]; then
      head="$(awk -F'\t' -v n="$num" '$1==n{print $2}' "$STATE_DIR/prs" | tail -1)"
    fi
    if [ -f "$STATE_DIR/merged" ] && grep -qxF "$head" "$STATE_DIR/merged"; then
      printf 'state\tMERGED\n'
    else
      printf 'state\tOPEN\n'
    fi ;;
  issue-comment|issue-comment-create|issue-comment-edit|issue-relabel|issue-close|link-subissue|pr-close)
    exit 0 ;;
  *)
    exit 0 ;;
esac
