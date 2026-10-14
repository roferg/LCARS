# Owner-only public release checklist

These are deliberate actions for the repository owner, not instructions for an
agent to execute. Preparation and dry runs do not authorize changing visibility,
rules, security settings, or Pages. No such settings have been changed here.

**Current limitation:** the repository is private on a plan without branch
protection. The read-only command
`gh api --method GET repos/roferg/lcars/branches/main/protection` returned the
expected response:

```text
gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)
{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","documentation_url":"https://docs.github.com/rest/branches/branch-protection#get-branch-protection","status":"403"}
```

This is not a failed release check or a reason for an agent to change visibility
or upgrade the plan. The ruleset's live behaviour **cannot be tested until the
repository is public** on this plan. Local JSON validation and recorder tests
are not GitHub enforcement evidence.

1. **Establish private reporting channels before publication.** Replace
   `[PLACEHOLDER: OWNER MUST SET A PRIVATE SECURITY REPORTING CONTACT]` in
   `SECURITY.md` and `[PLACEHOLDER: OWNER MUST SET A PRIVATE CONDUCT CONTACT]` in
   `CODE_OF_CONDUCT.md` with monitored private channels through a branch and PR.
   If desired, enable GitHub private vulnerability reporting in the repository's
   security settings yourself. **Verify:** both placeholders are gone, a harmless
   test message reaches each intended recipient privately, and any enabled
   vulnerability-reporting route works. Do not put real sensitive reports in
   public issues; disclose any lack of an independent conduct reviewer honestly.

2. **Prepare CI and inspect what will become public.** Arrange for the later CI
   job to land and run on pull requests, then replace
   `PLACEHOLDER-lcars-ci-required` in `.github/ruleset.json` with its exact emitted
   check name through a branch and PR. Review source, history, assets, license,
   credentials, and publication rights; remove or remediate anything unsuitable
   for public release before flipping visibility. **Verify:** the real check
   appears on a PR, it fails on a failing run and passes on a passing run, and
   `bash .github/ruleset-dry-run.sh` prints the intended method, endpoint, and
   validated body. The dry run sends nothing and cannot apply, even with opt-in.
   Do not enable the ruleset with a nonexistent placeholder check.

3. **Make the repository public yourself.** In GitHub repository settings,
   deliberately change visibility after reviewing GitHub's warnings. This
   publishes the repository and makes protection available on the current plan;
   it does not automatically apply this prepared ruleset. **Verify:** a signed-out
   browser can read the intended repository and its published history, and a
   read-only `gh api --method GET repos/roferg/lcars` reports `private: false`
   with the intended `default_branch`. Minimize the gap before step 4 and avoid
   merges or direct pushes during that unprotected interval.

4. **Apply the prepared ruleset yourself, only after the public flip.** Review
   `.github/ruleset.md` and the dry-run body, inspect existing rulesets to avoid
   duplicates, and use GitHub **Settings > Rules > Rulesets** to import the JSON
   or configure the equivalent branch ruleset. Application is the owner's
   decision; the preview script deliberately has no apply mode. Select **Active**,
   the default branch, no exclusions or bypass actors, PR-required merging, and
   the actual CI check. **Verify:** GitHub saves the ruleset successfully and
   shows those exact settings. Record its ID for step 5. If GitHub rejects it,
   resolve the reported error explicitly; a local validation pass is not API
   acceptance. Do not add an admin bypass just to get it working.

5. **Verify effective protection after the flip, not merely a saved file.** Use
   read-only `gh api --method GET repos/roferg/lcars/rulesets` and
   `gh api --method GET repos/roferg/lcars/rulesets/RULESET_ID` (substitute the saved
   numeric ID). Resolve the current default branch from step 3 and read
   `gh api --method GET repos/roferg/lcars/rules/branches/DEFAULT_BRANCH` (substitute
   and URL-encode the branch name). **Verify:** the ruleset is `active`, targets
   `~DEFAULT_BRANCH`, has no bypasses, and effective rules include `pull_request`
   and the real `required_status_checks` context. The legacy
   `/branches/main/protection` endpoint is not authoritative for rulesets and
   may return 404 even when ruleset protection is active. In an owner-controlled,
   disposable PR exercise, verify that a missing/failing required check blocks
   merging and a passing check permits a PR merge. Verify direct-push rejection
   only with an owner-approved controlled probe; if it unexpectedly succeeds,
   stop, record the failure, and restore via a reviewed PR. Do not claim runtime
   enforcement until these owner checks are actually performed.

6. **Optionally enable Pages yourself.** If a documentation site is wanted,
   configure **Settings > Pages** to deploy from the default branch's `/docs`
   directory (the repository already has `docs/index.html` and `docs/.nojekyll`).
   Alternatively choose an owner-reviewed Actions deployment if added later.
   Pages is independent of the ruleset and must not weaken it. **Verify:** the
   deployment succeeds and the URL GitHub reports loads the intended site,
   assets, and links in a signed-out browser without publishing private material.
   If Pages is not wanted, leave it disabled and record that decision.

7. **Open participation only after checking the public result.** Inspect the
   signed-out repository's contributing guide, license, security/conduct routes,
   issue and PR templates, and any Pages site. **Verify:** contacts work, the
   ruleset and actual CI check remain effective, and there are no unresolved
   publication placeholders or unexpected bypasses. Record owner verification
   evidence and any omitted checks; do not represent preparation as a completed
   public release.
