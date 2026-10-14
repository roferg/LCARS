# Default-branch ruleset preparation

[`ruleset.json`](ruleset.json) is a request body for GitHub's documented
[Create a repository ruleset](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset)
endpoint: `POST /repos/{owner}/{repo}/rulesets`. It has no invented JSON comment
field; this adjacent note is intentionally separate from the API body.

**CI placeholder:** `PLACEHOLDER-lcars-ci-required` must match the exact emitted
CI job/check name when that job lands. Replace it with that name before the
owner enables the ruleset. Leaving a nonexistent required check active blocks
merges; local validation cannot establish that a check exists or runs on PRs.

The active branch ruleset selects `~DEFAULT_BRANCH`, excludes nothing, and has
no bypass actors (including no owner/admin bypass). `pull_request` requires
commits on another branch and a PR before merging, enforcing the contract's
no-direct-push workflow. `required_status_checks` requires the named CI check
to pass. It does not add mandatory approving reviews, code-owner approval,
last-push approval, conversation resolution, or an up-to-date-branch requirement:
those are not additional requirements in `CLAUDE.md`.

Preview from the repository root (Python 3 and Bash required):

```sh
bash .github/ruleset-dry-run.sh
bash .github/ruleset-dry-run.sh --dry-run --repo roferg/LCARS
bash tests/ruleset.test.sh
```

The preview validates the API keys, types, required rule parameters, and branch
selection, then prints the would-be method, endpoint, and original JSON body.
It sends nothing and does not call `gh` by default. `--apply`, `--run`, and
`--owner-opt-in` all fail before any network access. There is **no apply path**,
even with opt-in; application remains a separate owner action.

An optional `--check-availability` performs only
`GET repos/OWNER/REPO/rulesets`, via `LCARS_GH_BIN` (default `gh`). The known
private-plan HTTP 403 upgrade/public message is recorded as expected, not a
failure, and is never worked around. Other read errors fail explicitly.
Availability does not prove live enforcement. Tests inject a recorder for `gh`
and assert zero mutations, including refused apply requests.

**Not applied or live-tested.** On the current private repository and plan,
protection is unavailable until the owner makes the repository public. Live
behaviour cannot be tested until then. Follow the owner-only
[release checklist](../RELEASE-CHECKLIST.md); this file is preparation, not a
claim that GitHub has accepted or enforced the body.
