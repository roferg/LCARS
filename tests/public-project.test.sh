#!/usr/bin/env bash
# Pure-local guard for the public project's contributor and governance files.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Require both meaningful size and nonblank lines; a heading alone is a stub.
while read -r file min_lines min_bytes; do
  if [ ! -f "$file" ]; then
    bad "$file exists and is non-trivial (missing)"
    continue
  fi
  lines="$(grep -c '[^[:space:]]' "$file")"
  bytes="$(wc -c < "$file")"
  if [ "$lines" -ge "$min_lines" ] && [ "$bytes" -ge "$min_bytes" ]; then
    ok "$file exists and is non-trivial"
  else
    bad "$file exists and is non-trivial ($lines nonblank lines, $bytes bytes; need $min_lines and $min_bytes)"
  fi
done <<'FILES'
LICENSE 15 900
CONTRIBUTING.md 30 1800
SECURITY.md 25 1800
CODE_OF_CONDUCT.md 25 1800
.github/CODEOWNERS 3 100
.github/ISSUE_TEMPLATE/bug_report.md 15 650
.github/ISSUE_TEMPLATE/feature_request.md 12 550
.github/PULL_REQUEST_TEMPLATE.md 15 800
FILES

contains() {
  if [ ! -f "$1" ]; then
    bad "$3 ($1 missing)"
  elif grep -Eq "$2" "$1"; then
    ok "$3"
  else
    bad "$3 ($1 lacks $2)"
  fi
}

contains CONTRIBUTING.md 'contract for humans' 'human contract is explicit'
contains CONTRIBUTING.md '\[.*CLAUDE\.md.*\]\(CLAUDE\.md\)' 'human guide links the agent contract'
contains CLAUDE.md '\[.*CONTRIBUTING\.md.*\]\(CONTRIBUTING\.md\)' 'agent contract links the human guide'
contains CONTRIBUTING.md 'skills/<name>/' 'skill source belongs in the repo'
contains CONTRIBUTING.md 'failing test first' 'human workflow requires TDD'
contains CONTRIBUTING.md 'never on `main`' 'human workflow requires a branch'
contains CONTRIBUTING.md 'merge gate' 'full suite remains the merge gate'
contains SECURITY.md 'security/advisories/new' 'security policy offers private reporting'
contains SECURITY.md 'shell commands' 'security policy names command execution'
contains SECURITY.md 'hooks and plugins' 'security policy names directory trust risk'
contains CODE_OF_CONDUCT.md 'Contributor Covenant' 'conduct policy identifies its standard'
contains CODE_OF_CONDUCT.md 'PLACEHOLDER: OWNER MUST SET A PRIVATE CONDUCT CONTACT' 'conduct contact is an explicit owner placeholder'
contains .github/CODEOWNERS '^\*[[:space:]]+@roferg$' 'default ownership names the repository owner'
contains .github/ISSUE_TEMPLATE/bug_report.md 'SECURITY.md' 'bug reports route vulnerabilities privately'
contains .github/ISSUE_TEMPLATE/feature_request.md 'acceptance' 'feature requests ask for acceptance criteria'
contains .github/PULL_REQUEST_TEMPLATE.md 'skills/<name>/' 'PR template asks which skill changed'
contains .github/PULL_REQUEST_TEMPLATE.md 'tests/<name>\.test\.sh' 'PR template asks for the skill test'
contains .github/PULL_REQUEST_TEMPLATE.md 'scoped.*(counts|passed)' 'PR template asks for scoped test evidence'
contains .github/PULL_REQUEST_TEMPLATE.md 'VERSION' 'PR template requires a version bump'
contains .github/PULL_REQUEST_TEMPLATE.md 'CHANGELOG.md' 'PR template requires a changelog entry'

echo
printf 'public-project: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
