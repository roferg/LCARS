# S189 spike — identity, assignee ops, and resolving "the PR that closes issue #n"

Author-local decision record for the portability round's ownership session
(S189: `whoami` + assignee ops on the host adapter, the light lock, and
`lcars adopt`). This is the committed output of the **S189 SPIKE GATE**:

- **(a)** *Is `gh api user` a usable `whoami`, and what are the exact
  assignee round-trip semantics for ONE account?*
- **(b)** *Can a second laptop, with NO local state, reliably resolve the OPEN
  pull request that closes a mission's issue?*

**Verdict: GATE PASSES on both legs.** Every probe below was run for real
against the throwaway private fixture repo `roferg/lcars-mp-fixture` on
2026-09-08 and torn down afterwards. Nothing here is paraphrased — the outputs
are the real ones, trimmed only where a JSON blob was long.

- **gh version tested:** `gh version 2.96.0 (2026-07-02)`
- **Accounts:** `gh auth status` shows the captain logged into BOTH
  `github.com` (account `roferg`) and `github.ghe.com` (account `roferg`).
- **Fixture:** `roferg/lcars-mp-fixture`, PRIVATE, default branch `main`,
  one collaborator (`roferg`, the owner).

---

## LEG A — identity (`whoami`) and assignee round-trip

### A.1 `gh api user` — the stable login and the fields `whoami` wants

```
$ gh api user
{"login":"roferg","id":40493721,"node_id":"MDQ6VXNlcjQwNDkzNzIx",
 "avatar_url":"https://avatars.githubusercontent.com/u/40493721?v=4",
 …,"type":"User","name":"Rogan Ferguson","company":"GitHub",
 "location":"Las Vegas, Nevada","email":null,…}
[rc=0]
```

**The exact JSON paths S189/S190 need:**

| What | Path | Value seen | Notes |
|------|------|-----------|-------|
| stable login (the assignee handle) | `.login` | `roferg` | THE identity key. This is what `--add-assignee` takes and what `assignees[].login` returns — the two must be the same string, and they are. |
| numeric id | `.id` | `40493721` | Stable per-host, **NOT portable across hosts** — see A.5. Do NOT use it as the cross-forge identity. |
| display name | `.name` | `Rogan Ferguson` | **Nullable** — a user with no profile name returns `null`. Never render it without a `.login` fallback. |
| avatar (S190) | `.avatar_url` | `https://avatars.githubusercontent.com/u/40493721?v=4` | Present on `gh api user`. NOTE: the same user's avatar_url comes back with a `?u=<hash>&v=4` query string when read via an *issue* payload — same image, different URL string. Compare users by `.login`, never by avatar_url. |

Extraction, three ways (all verified):

```
$ gh api user --jq .login
roferg
[rc=0]

$ gh api user -q '[.login,(.id|tostring),.name,.avatar_url]|join("\t")'
roferg	40493721	Rogan Ferguson	https://avatars.githubusercontent.com/u/40493721?v=4
[rc=0]

# jq-free, house style (same tr/sed pluck as github_issue_comment_create):
$ gh api user 2>/dev/null | tr ',{}' '\n\n\n' \
    | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
roferg
```

The adapter already uses gh's built-in `--jq` in `github_link_subissue`, so
`--jq .login` is in-convention. The jq-free pluck is recorded as the fallback
if a future reviewer wants the op to hold the file's jq-free preference.

**`whoami` MUST go through the adapter's `gh_api` helper, not bare `gh api`.**
`gh api` targets the DEFAULT host; `gh_api` pins `--hostname` from the origin
remote (and returns argv byte-identical to today's on github.com). Reading
identity from the wrong forge is exactly the S168 class of silent bug.

### A.2 Reading assignees — the shape of "nobody"

```
$ gh issue view 1 --json assignees
{"assignees":[]}
[rc=0]

$ gh issue view 1 --json assignees --jq '.assignees[].login'
                       ← prints NOTHING
[rc=0]

$ gh api repos/{owner}/{repo}/issues/1 --jq '.assignees'
[]
[rc=0]
```

**An unassigned issue returns an EMPTY ARRAY — never `null`, never a missing
key**, on both the `gh issue view --json` path and the REST path. rc is 0 in
every unassigned case. So "unowned" is *empty output*, not an error: an
`issue-assignees` op should echo zero lines and return 0, and the light lock
must treat empty as "unowned → my verbs are allowed", never as a failure.

Assigned shape (note `login` is the field to key on; `id` here is the GraphQL
node id, `databaseId` the numeric one):

```
$ gh issue view 1 --json assignees
{"assignees":[{"id":"MDQ6VXNlcjQwNDkzNzIx","login":"roferg",
               "name":"Rogan Ferguson","databaseId":40493721}]}
[rc=0]
```

### A.3 The round-trip, case by case — exact argv and exit codes

Every case below was run against real issue #1 in the fixture.

| # | Case | argv | rc | stdout | Read-back |
|---|------|------|----|--------|-----------|
| 1 | assign self | `gh issue edit 1 --add-assignee roferg` | **0** | `https://github.com/roferg/lcars-mp-fixture/issues/1` | `["roferg"]` ✅ |
| 2 | assign self via alias | `gh issue edit 1 --add-assignee @me` | **0** | issue URL | `["roferg"]` ✅ (gh resolves `@me` client-side) |
| 3 | assign an ALREADY-assigned issue to the SAME login | `gh issue edit 1 --add-assignee roferg` | **0** | issue URL | still exactly 1 assignee — **idempotent, silent no-op, no duplicate, no error** ✅ |
| 4 | unassign an assigned login | `gh issue edit 1 --remove-assignee roferg` | **0** | issue URL | `[]` ✅ |
| 5 | unassign a login that is NOT assigned | `gh issue edit 1 --remove-assignee roferg` | **0** | issue URL | `[]` — **idempotent, silent no-op, no error** ✅ |
| 6 | assign a REAL user with NO access to this private repo | `gh issue edit 1 --add-assignee octocat` | **0** ⚠️ | issue URL | `[]` — **SILENTLY DROPPED** ⚠️ |
| 7 | assign a login that DOES NOT EXIST | `gh issue edit 1 --add-assignee lcars-s189-no-such-user-xyz` | **1** | (stderr) `failed to update https://…/issues/1: GraphQL: Could not resolve to a user or bot with the login 'lcars-s189-no-such-user-xyz'. (replaceActorsForAssignable)` / `failed to update 1 issue` | `[]` |

**⚠️ THE LOAD-BEARING FAILURE MODE (case 6).** Assigning a real user who
cannot be assigned on this repo returns **rc=0 and a success-shaped issue URL**,
and the assignment simply does not happen. The REST path lies the same way —
HTTP 201 with an issue payload whose `assignees` is `[]`:

```
$ gh api --method POST repos/{owner}/{repo}/issues/1/assignees -f 'assignees[]=octocat'
{… "number":1, … "assignee":null,"assignees":[], …}
[rc=0]

$ gh issue view 1 --json assignees
{"assignees":[]}
```

**Consequence for S189: `issue-assign` MUST NOT trust rc=0. It must READ BACK
and confirm the login is present** before recording local ownership. Otherwise
the light lock records "mine" for an assignment GitHub silently refused, and
the second laptop sees an unowned mission. This is the single most important
thing on this leg.

### A.4 The assignability pre-check (recommended)

There is an explicit endpoint that answers "can this login be assigned here?",
and it does NOT lie:

```
$ gh api repos/{owner}/{repo}/assignees/roferg
                       ← empty body, HTTP 204
[rc=0]

$ gh api repos/{owner}/{repo}/assignees/octocat
{"message":"Not Found","documentation_url":"https://docs.github.com/rest/issues/assignees#check-if-a-user-can-be-assigned","status":"404"}
gh: Not Found (HTTP 404)
[rc=1]

$ gh api repos/{owner}/{repo}/assignees/lcars-s189-no-such-user-xyz
{"message":"Not Found", … "status":"404"}
gh: Not Found (HTTP 404)
[rc=1]

# and the whole assignable set:
$ gh api repos/{owner}/{repo}/assignees --jq '.[].login'
roferg
[rc=0]
```

Note this endpoint **cannot distinguish "real user without access" from
"user does not exist"** — both are a bare 404. That is fine for the light
lock's purposes ("this login cannot own work here"), but the error message
S189 prints must not claim the user doesn't exist.

Read-back (A.3) is still mandatory even with the pre-check — the pre-check is
a nicer error message, not a guarantee.

### A.5 GitHub Enterprise notes — do NOT hard-code github.com

- `gh issue edit` / `gh issue view` / `gh pr *` resolve the forge host from the
  repo's own `origin` remote, so the assignee ops work on GHE with **no host
  pinning**, exactly as `github_issue_edit_body` already documents.
- `gh api` does NOT. A bare `gh api user` inside a `*.ghe.com` checkout reads
  the identity of the **github.com** account. The adapter's existing `gh_api`
  wrapper (which calls `gh_hostname` off the origin remote) is therefore
  **mandatory for the `whoami` op**.
- Verified that the enterprise account resolves independently:

```
$ gh api --hostname github.ghe.com user --jq '[.login,(.id|tostring)]|join("\t")'
roferg	97261
[rc=0]
```

  Same `.login`, **different `.id`** (`97261` on GHE vs `40493721` on
  github.com). Identity is **per-host**. `.id` is not a portable key and
  logins collide across forges only by coincidence — S189 should treat the
  identity as the pair (host, login), and at minimum must never compare a
  numeric id read on one host against one read on another.
- `repos/{owner}/{repo}/assignees/{login}` is plain REST v3, present on GHES.
  Assumed available; not exercised there (no fixture repo on the GHE host).

---

## LEG B — resolving "the open PR that closes issue #n"

### B.0 The real scenario, and the real directive format

**How LCARS actually writes it.** The directive is composed by
`append_closes()` in `skills/lcars-run/host-adapter.sh` and applied by
`github_pr_create` to the body built by `pr_body()` in
`skills/lcars-approve/pr-lib.sh`:

```sh
body="$body
Closes #$n"
```

So: the word is **`Closes`** (capital C — never `Fixes`, never `Resolves`),
one directive **per line**, appended at the **very END of the body**, with
**NO blank line** before the first one, one line per closed issue — the parent
mission issue first, then each Schedule-opened sub-issue (`open_pr()`'s
`add_close` order in pr-lib.sh).

The fixture PR was opened through the **real adapter**, not by hand:

```
$ bash skills/lcars-run/host-adapter.sh pr-create \
    --head lcars/s189-spike-b --base main \
    --title "S189 spike B — …" --body "$BODY" --closes 2 --closes 3
https://github.com/roferg/lcars-mp-fixture/pull/4
```

and GitHub stored exactly:

```
$ gh pr view 4 --json body --jq .body
## Summary

Mission **S189 spike B** — implemented across its scheduled waves.

## Technical summary

- spike: s189 closes-resolution probe

### Wave 1
- `t1` — the ticket that stands in for a real one
Closes #2
Closes #3
```

**The scenario built for the evaluation** (deliberately adversarial):

| Object | Role |
|--------|------|
| issue **#2** | the parent mission issue — OPEN |
| issue **#3** | a sub-issue / ticket — OPEN |
| issue **#1** | the *no-PR* control — OPEN, nothing references it |
| PR **#4** | the real one, OPEN, `Closes #2` + `Closes #3` |
| PR **#5** | a **DECOY**, OPEN, body `Related to #2 but carries no Closes directive.` |

A correct answer for issue #2 is **exactly `{4}`** — #5 must be excluded.

### B.1 Candidate 1 — `gh issue view <n> --json closedByPullRequestsReferences`

The field EXISTS on gh 2.96.0 (`gh issue view 2 --json` lists it among
`assignees … closedByPullRequestsReferences … comments …`).

```
$ gh issue view 2 --json closedByPullRequestsReferences
{"closedByPullRequestsReferences":[{"id":"PR_kwDOUR1thc8AAAABCpMEnw","number":4,
  "repository":{"id":"R_kgDOUR1thQ","name":"lcars-mp-fixture",
                "owner":{"id":"MDQ6VXNlcjQwNDkzNzIx","login":"roferg"}},
  "url":"https://github.com/roferg/lcars-mp-fixture/pull/4"}]}
[rc=0]

$ gh issue view 3 --json closedByPullRequestsReferences --jq '…[].number'
4                       ← the sub-issue resolves to the SAME PR

$ gh issue view 2 --json closedByPullRequestsReferences --jq '.closedByPullRequestsReferences[].number'
4
[rc=0]

$ gh issue view 2 --json closedByPullRequestsReferences --jq '.closedByPullRequestsReferences[].url'
https://github.com/roferg/lcars-mp-fixture/pull/4
```

- **PR OPEN, issue OPEN:** ✅ returns it.
- **DECOY excluded:** ✅ #5 never appears. The field means *"PRs that would
  close this issue"*, not *"PRs that mention it"*. **Exact — no filtering.**
- **Gives the URL directly**, so `prUrl` needs no reconstruction from
  owner/repo/number (matches what `open_pr` records into `state.json`).
- **No-PR case (issue #1):**

```
$ gh issue view 1 --json closedByPullRequestsReferences
{"closedByPullRequestsReferences":[]}
[rc=0]

$ gh issue view 1 --json closedByPullRequestsReferences --jq '…[].number'
                       ← nothing
[rc=0]
```

  **Empty array, rc=0.** "No PR" is empty output, not an error — same shape as
  the unassigned-issue case, and the same rule applies: key off empty output.

- **CLOSED-but-unmerged PR — the decisive property.** After
  `gh pr close 4` (no merge):

```
$ gh pr close 4
✓ Closed pull request roferg/lcars-mp-fixture#4 (…)

$ gh issue view 2 --json closedByPullRequestsReferences
{"closedByPullRequestsReferences":[]}
[rc=0]
```

  **The field SELF-FILTERS to live PRs.** A closed, unmerged PR disappears.
  So the field answers *"the OPEN PR that closes issue #n"* directly — adopt
  does not have to state-check to avoid latching onto an abandoned PR.

- **Failure modes:**
  - nonexistent issue → `GraphQL: Could not resolve to an issue or pull
    request with the number of 99. (repository.issue)`, **rc=1**.
  - gh too old to know the field → `Unknown JSON field: "<name>"` followed by
    an `Available fields:` list, **rc=1**. That is the exact, cheap detection
    for the fallback (probe once, on rc=1 fall back).

**Composing with the existing adapter.** The field carries no `state`, so if
S189 wants the state anyway it costs one extra call through an op that already
exists:

```
$ PRN=$(gh issue view 2 --json closedByPullRequestsReferences \
        --jq '.closedByPullRequestsReferences[].number' | head -1)
$ bash skills/lcars-run/host-adapter.sh pr-view --number "$PRN"
state	OPEN
mergedAt	null
[rc=0]
```

### B.2 Candidate 2 — `gh pr list --search "…"`

```
$ gh pr list --search "Closes #2" --state open --json number,title,state
[{"number":5,"state":"OPEN","title":"S189 spike B — DECOY pr (mentions #2, closes nothing)"},
 {"number":4,"state":"OPEN","title":"S189 spike B — resolve the open PR that closes this issue"}]
[rc=0]                 ← ❌ UNQUOTED SEARCH MATCHES THE DECOY

$ gh pr list --search '"Closes #2" in:body' --state open --json number,title
[{"number":4,"title":"S189 spike B — resolve the open PR that closes this issue"}]
[rc=0]                 ← ✅ quoted phrase + in:body is exact HERE

$ gh pr list --search 'linked:issue' --state open --json number,title
[{"number":4,"title":"…"}]
[rc=0]                 ← finds linked PRs, but does NOT say WHICH issue

$ gh pr list --search '2 in:body' --state open --json number,title
[{"number":5,…},{"number":4,…}]
[rc=0]                 ← ❌ bare number matches everything
```

- No-match case: `[]` with **rc=0** on the `--json` path; **rc=0 and empty
  stdout, empty stderr** on the plain path — so a caller cannot key off rc.
- **⚠️ THE DISQUALIFYING FAILURE MODE — index staleness.** Immediately after
  `gh pr close 4`, the same search still reported the PR as OPEN:

```
# seconds after PR #4 was CLOSED:
$ gh pr list --search '"Closes #2" in:body' --state open --json number
[{"number":4}]
[rc=0]                 ← ❌ WRONG. #4 is closed.

$ gh pr list --search '"Closes #2" in:body' --state all --json number,state
[{"number":4,"state":"CLOSED"}]
                       ← the index knows the PR, but its state filter is stale

# ~1 minute later, the same query:
$ gh pr list --search '"Closes #2" in:body' --state open --json number
[]
```

  GitHub code/issue search is **eventually consistent**. The window cuts both
  ways: a PR opened seconds ago may not be findable yet (adopt run right after
  Verify opens the PR — the exact moment adopt is meant to work), and a PR
  just closed may still look open. Observed lag here: **under a minute, but
  non-zero and unbounded in principle**.
- Also: `--search` is a text query, so it depends on the `Closes` spelling
  never changing, and would match a *quotation* of the directive in someone's
  PR body.

### B.3 Candidate 3 — issue timeline cross-references

No preview header was needed on gh 2.96 / current github.com — plain
`gh api` worked:

```
$ gh api "repos/{owner}/{repo}/issues/2/timeline" \
    --jq '.[] | {event, source_issue: (.source.issue.number // null),
                 source_is_pr: (.source.issue.pull_request != null),
                 actor: .actor.login}'
{"actor":"roferg","event":"cross-referenced","source_is_pr":true,"source_issue":4}
{"actor":"roferg","event":"cross-referenced","source_is_pr":true,"source_issue":5}
[rc=0]
```

- ❌ **Returns the DECOY.** `cross-referenced` means *mentioned*, and carries
  no signal about whether the reference is a closing one. Not exact; would
  need a second pass over each candidate's body — at which point it is
  candidate 4 with extra calls.
- While the PR is OPEN there is **no** `connected` / `closed` event to key on
  — those appear on merge, i.e. after the moment adopt cares about.
- Needs `gh api`, so it needs the `gh_api` host pin on GHE (candidates 1, 2
  and 4 use `gh issue`/`gh pr`, which self-resolve the host).
- Paginates on a busy issue; the timeline of a long-running mission issue is
  large and the cross-ref may not be on page 1.

### B.4 Candidate 4 — scan open PR bodies for the directive

```
$ gh pr list --state open --limit 100 --json number,body
[{"body":"Related to #2 but carries no Closes directive.","number":5},
 {"body":"## Summary\n\n…\n### Wave 1\n- `t1` — …\nCloses #2\nCloses #3","number":4}]
[rc=0]

# gh-side filter on the EXACT anchored directive line:
$ gh pr list --state open --limit 100 --json number,body \
    --jq '.[] | select(.body | test("(?m)^Closes #2$")) | .number'
4
[rc=0]

# jq-free, house style:
$ for n in $(gh pr list --state open --limit 100 --json number --jq '.[].number'); do
    gh pr view "$n" --json body --jq .body | grep -qx 'Closes #2' && echo "match: $n"
  done
match: 4

# no-PR case:
$ gh pr list --state open --limit 100 --json number,body \
    --jq '.[] | select(.body | test("(?m)^Closes #1$")) | .number'
                       ← nothing
[rc=0]
```

- ✅ **Exact** with an anchored `^Closes #N$` match (the decoy is excluded).
- ✅ **Uses the LIST endpoint, not the search index** — no staleness. A PR
  opened one second ago is in `gh pr list` immediately.
- ✅ `--state open` on the list endpoint is authoritative, so the result is
  open-only by construction.
- ⚠️ Anchoring matters: `grep -q 'Closes #2'` (unanchored) would also match
  `Closes #21`. Use `grep -qx` / `(?m)^Closes #N$`.
- ⚠️ O(open PRs) bodies to fetch, and `--limit` is a real ceiling — a repo
  with >limit open PRs can miss the answer silently.
- ⚠️ Only finds LCARS-written PRs. A human who linked the issue through the
  GitHub UI's *Development* sidebar (no body text at all) is invisible to it.

### B.5 Scoreboard

| Candidate | Exact? | Works PR-open / issue-open? | Excludes decoy? | No-PR failure mode | Staleness | Host-pin needed |
|-----------|--------|------------------------------|-----------------|--------------------|-----------|-----------------|
| 1. `closedByPullRequestsReferences` | ✅ exact, plus self-filters closed PRs | ✅ | ✅ | `[]`, rc=0 | none (GraphQL live read) | no (`gh issue`) |
| 2. `gh pr list --search` | only with `"…" in:body`; unquoted matches decoy | ✅ | ⚠️ only when quoted | `[]`, rc=0 | ❌ **observed stale for ~1 min** | no |
| 3. timeline cross-refs | ❌ mentions == closes | ✅ | ❌ | empty list, rc=0 | none | yes (`gh api`) |
| 4. scan open PR bodies | ✅ if anchored | ✅ | ✅ | empty, rc=0 | none | no |

---

## WINNER

### 🏆 `gh issue view <n> --json closedByPullRequestsReferences`

**S189 implements this as the host-adapter op (suggested name
`issue-closing-prs <n>`, echoing `<number>\t<url>` lines like `pr-view` echoes
tab-separated pairs).**

Reasoning:

1. **It is semantically the exact question.** GitHub itself computes "which
   PRs would close this issue" from the parsed closing keywords plus UI-created
   development links. No text matching, no `Closes`-spelling dependency, no
   decoy.
2. **It self-filters to LIVE PRs.** A closed-unmerged PR vanishes from the
   list (proved in B.1). Adopt-at-Verify wants *the open PR*, and that is
   precisely what the field returns — with no extra state call.
3. **It is a live GraphQL read, not the search index.** It is correct the
   instant Verify opens the PR, which is exactly when the second laptop runs
   `lcars adopt`.
4. **It returns the `url` directly**, which is the field `open_pr()` already
   records as `prUrl` in `state.json` — adopt writes the same value the
   originating laptop would have, so `approve` / `feedback` / `log` work with
   no reconstruction.
5. **It resolves from the sub-issue too** (issue #3 → PR #4), which is free
   robustness if adopt is ever pointed at a ticket instead of the parent.
6. **`gh issue view` self-resolves the forge host from the remote**, so it
   works on GitHub Enterprise without the `gh_api` host pin.
7. **Its no-PR case is empty-with-rc-0**, matching every other "nothing here"
   shape in this adapter.

Cost: one call. Failure to find a PR is empty output, so the caller's guard is
`[ -n "$out" ]`, the same idiom `github_issue_comment_create` and
`github_pr_create` already use.

### FALLBACK — scan open PR bodies for the anchored directive (candidate 4)

Use when the winner is unavailable. **Detection is exact and cheap:** the op
runs the winner first; on **rc=1 with `Unknown JSON field:`** (old gh) — or on
any rc=1 that is not the "could not resolve to an issue" case — it falls back.

```sh
# fallback: authoritative list endpoint, anchored match, open-only by construction
gh pr list --state open --limit 100 --json number,body \
  --jq '.[] | select(.body | test("(?m)^Closes #'"$N"'$")) | .number'
```

or, holding the file's jq-free preference:

```sh
for n in $(gh pr list --state open --limit 100 --json number --jq '.[].number'); do
  gh pr view "$n" --json body --jq .body 2>/dev/null | grep -qx "Closes #$N" && printf '%s\n' "$n"
done
```

Why this and not `--search`: the fallback must be *more* trustworthy than the
winner in the situations that trigger it, and `--search` fails exactly where
adopt is used — right after the PR is opened. The list endpoint has no index
lag. The fallback is chosen for **correctness**, not convenience.

The fallback's own limits, to be stated in whatever message S189 prints when
it is used:

- anchor the match (`grep -qx` / `(?m)^…$`) or `#2` matches `#21`;
- `--limit 100` is a real ceiling — over it, the answer can be silently missed;
- it only sees PRs whose body carries the directive LCARS writes, so a
  UI-linked PR is invisible.

**`gh pr list --search` is explicitly REJECTED** as both winner and fallback,
on the observed staleness evidence in B.2. The timeline is REJECTED as
imprecise (B.3), but is worth keeping in mind as a *diagnostic* when a captain
asks "why does adopt not see my PR" — it will show the cross-reference even
when no closing link exists, which is itself the answer.

---

## Failure modes to encode in S189 (the complete list found)

**Leg A**

1. `gh issue edit --add-assignee <real-but-unassignable-login>` → **rc=0,
   success-shaped output, assignment silently dropped**. `issue-assign` MUST
   read back and confirm.
2. Same silent drop on the REST path (`POST …/issues/<n>/assignees`) — HTTP
   201 with `"assignees":[]`.
3. Nonexistent login → rc=1, GraphQL `Could not resolve to a user or bot…
   (replaceActorsForAssignable)`.
4. `repos/{owner}/{repo}/assignees/<login>` cannot tell "no access" from "no
   such user" — both are a bare 404. Don't claim the user doesn't exist.
5. Unassigned issue is `[]` / no output with rc=0 — never `null`, never a
   missing key. Empty is a valid answer, not an error.
6. Re-assign and re-unassign are both idempotent silent no-ops (rc=0).
7. `gh api user` without `--hostname` reads the DEFAULT host's identity even
   inside a GHE checkout — `whoami` must go through `gh_api`.
8. `.id` differs per host for the same login (40493721 vs 97261). `.name` can
   be `null`. `.avatar_url` differs in query string between the `user` payload
   and an issue payload — compare on `.login` only.

**Leg B**

9. Winner on a nonexistent issue → rc=1, GraphQL "could not resolve".
10. Winner on old gh → rc=1, `Unknown JSON field:` + `Available fields:` list.
11. Winner returns `[]` (rc=0) when there is no PR AND when the only PR is
    closed-unmerged — those two are indistinguishable from the field alone. If
    adopt needs to say *"there was a PR and it was abandoned"*, it must fall
    back to the body scan with `--state all`.
12. `gh pr list --search` is index-backed and observably stale in both
    directions (missed-new and stale-open) — never load-bearing.
13. Timeline `cross-referenced` includes plain mentions; there is no
    `connected`/`closed` event while the PR is open.
14. Body scan: unanchored `Closes #2` also matches `Closes #21`; `--limit` is a
    silent ceiling; UI-linked PRs carry no body directive.
15. The directive format itself is load-bearing for the fallback: `Closes #<n>`,
    capital C, one per line, appended at the END of the body with no blank
    line, by `append_closes()`. If that ever changes, the fallback changes with
    it — they are one unit.

---

## What this spike did NOT determine

- **GHE behaviour of the winner.** `closedByPullRequestsReferences` is a gh
  GraphQL field; no fixture repo exists on `github.ghe.com`, so it was not
  exercised there. GHES lags github.com's GraphQL schema, so an older GHES may
  not have it — which is exactly what the fallback is for, and the detection
  (`Unknown JSON field`, rc=1) covers a server-side gap the same way it covers
  an old client.
- **The gh version in which `closedByPullRequestsReferences` first appeared.**
  Present in 2.96.0; the introducing release was not verified, so S189 should
  detect the field rather than gate on a version number.
- **Multi-account behaviour.** Only ONE account (`roferg`) was probed on each
  host, per the brief. Two-collaborator semantics (assigning a real teammate,
  the light lock's "someone else owns this" path) were NOT exercised against a
  real second account — case 6 is the closest real evidence, and it is the
  *refusal* path, not the success path.
- **Whether a MERGED PR still appears in `closedByPullRequestsReferences`.**
  Merging would have closed the fixture issues; not probed. Adopt-at-Verify
  runs pre-merge, so it does not matter for S189, but do not assume either way.

---

## Fixture-repo ledger (this spike ran for real, and cleaned up)

Created in `roferg/lcars-mp-fixture` and then torn down:

| Object | Purpose | Final state |
|--------|---------|-------------|
| issue #1 | assignee round-trip (leg A) | CLOSED, assignees `[]` |
| issue #2 | parent mission issue (leg B) | CLOSED |
| issue #3 | sub-issue / ticket (leg B) | CLOSED |
| PR #4 | the real LCARS-shaped PR, `Closes #2` + `Closes #3` | CLOSED (unmerged) |
| PR #5 | decoy, mentions `#2`, no directive | CLOSED (unmerged) |
| branch `lcars/s189-spike-b` | PR #4's head | DELETED |
| branch `lcars/s189-decoy` | PR #5's head | DELETED |

The repo is back to `main` with `README.md` only, no open issues, no open PRs,
no extra branches, no assignees anywhere.
