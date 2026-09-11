#!/usr/bin/env bash
# S189 teardown — return roferg/lcars-mp-fixture to: no open issues, no open
# PRs, only `main`, no assignees. Reuses (does not delete) the two clones.
. "$(dirname "$0")/lib.sh"

hdr "open PRs"
for n in $("$GH_REAL" pr list -R "$FIXTURE" --state open --json number --jq '.[].number'); do
  "$GH_REAL" pr close "$n" -R "$FIXTURE" >/dev/null 2>&1 && note "closed PR #$n"
done
hdr "open issues"
for n in $("$GH_REAL" issue list -R "$FIXTURE" --state open --json number --jq '.[].number'); do
  for a in $("$GH_REAL" issue view "$n" -R "$FIXTURE" --json assignees --jq '.assignees[].login'); do
    "$GH_REAL" issue edit "$n" -R "$FIXTURE" --remove-assignee "$a" >/dev/null 2>&1 && note "unassigned $a from #$n"
  done
  "$GH_REAL" issue close "$n" -R "$FIXTURE" >/dev/null 2>&1 && note "closed issue #$n"
done
hdr "assignees on CLOSED issues too"
for n in $("$GH_REAL" issue list -R "$FIXTURE" --state all --json number --jq '.[].number'); do
  for a in $("$GH_REAL" issue view "$n" -R "$FIXTURE" --json assignees --jq '.assignees[].login'); do
    "$GH_REAL" issue edit "$n" -R "$FIXTURE" --remove-assignee "$a" >/dev/null 2>&1 && note "unassigned $a from #$n"
  done
done
hdr "branches other than main"
for b in $("$GH_REAL" api "repos/$FIXTURE/branches" --jq '.[].name' | grep -v '^main$'); do
  "$GH_REAL" api -X DELETE "repos/$FIXTURE/git/refs/heads/$b" >/dev/null 2>&1 && note "deleted $b"
done
hdr "the clones"
for l in A B; do d="$S189_HOME/$l"; [ -d "$d/.git" ] && { reset_laptop "$d"; note "$l reset ($(cd "$d" && git rev-parse --abbrev-ref HEAD) @ $(cd "$d" && git rev-parse --short HEAD)), .git/lcars removed"; }; done
hdr "FINAL STATE"
note "open issues: $("$GH_REAL" issue list -R "$FIXTURE" --state open --json number --jq 'length')"
note "open PRs:    $("$GH_REAL" pr list -R "$FIXTURE" --state open --json number --jq 'length')"
note "branches:    $("$GH_REAL" api "repos/$FIXTURE/branches" --jq '[.[].name]|join(", ")')"
note "assignees:   $("$GH_REAL" issue list -R "$FIXTURE" --state all --json assignees --jq '[.[].assignees[].login]|join(", ")')"
