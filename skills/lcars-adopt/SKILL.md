---
name: lcars-adopt
description: Pick up an existing LCARS Mission on THIS laptop from its GitHub issue alone — the portability verb. `lcars adopt <issue#>` reads the issue and its machine-readable `lcars:handoff` envelope, REUSES the mission's own id (never mints a new one), and rebuilds `.git/lcars/missions/<id>/` locally: at **Align** it claims the mission (assigns you on GitHub), rebuilds the spec from the issue body and fetches the branch if origin has one; at **Verify** it joins without claiming, resolves the OPEN pull request that closes the issue and records prUrl/prNumber so `lcars approve` and `lcars feedback` work with no further command. Any OTHER stage is refused honestly — v1 portability is the two ENDS, and the stages between keep their working artifacts on the laptop driving them. Idempotent: adopting a mission that is already local refreshes it and keeps local artifacts. Use when the captain runs `lcars adopt <issue#>`, switches laptops, asks to pick up / continue / catch a mission filed on another machine, or wants a mission that exists on GitHub to show up on this clone's board.
---

# lcars adopt

`lcars adopt <issue#>` is how a Mission crosses machines. The captain files on
laptop A and catches it at Verify on laptop B; the issue is the handoff
document, and this verb turns it back into a local Mission.

It is purely mechanical — **no LLM** — so run the one script and report.

## What to run

```bash
bash ~/.claude/skills/lcars-adopt/adopt.sh --issue <issue-number>
```

Run it from the clone the captain wants the Mission in. `--issue 42`, `42` and
`#42` are all accepted.

## What it does

1. **Reads the issue + its `lcars:handoff` envelope.** The envelope (appended to
   every body since S188) carries the mission's `id`, `branch`, `base`, `type`,
   `engine`, `parentIssue`, `attachments` and `parked`. Those are the identity
   facts, and they are the ONLY place adopt takes them from.
2. **Reads the STAGE from the `lcars:<stage>` label** — not from the envelope.
   The envelope is refreshed at two transfer points only, so it would go stale
   mid-pipeline; the label is swapped at every stage transition and is already
   what the board's GitHub adapter treats as canonical.
3. **Rebuilds `.git/lcars/missions/<id>/`** — `prd.md` from the issue body and
   `state.json` from the envelope + the label + the issue title. The mission
   **id is reused**, never minted: the id already names the branch and the
   issue, so a new one would fork the Mission in two.
4. **At Align** it also **claims** the Mission (assigns the captain on GitHub,
   best-effort) and fetches the branch if origin has one.
5. **At Verify** it resolves the **open PR that closes the issue** and records
   `prUrl` / `prNumber` / `review: open`, so `lcars approve` and `lcars
   feedback` work immediately. It does **not** claim — looking is never gated —
   but *acting* still requires ownership, and those verbs enforce that
   themselves.

## What it refuses, and why

Each refusal touches the disk not at all — there is never a half-built Mission.

- **Any stage other than align/verify** → *"mission is mid-pipeline at
  `<stage>`; portable ends are Align and Verify."* The stages in between keep
  their working artifacts (research findings, `plan.json`, ticket state) on the
  laptop that is driving them; those are deliberately not on the issue, so a
  rebuild here would be a Mission with its middle missing.
- **An issue with no `lcars:handoff` envelope** (filed before this round) → it
  says exactly which facts are unrecorded. Drive it from the laptop that filed
  it, or re-file it here.
- **An envelope from a newer schema** → refuses rather than guessing; run
  `lcars update`.
- **An issue with no `lcars:<stage>` label** → the stage is not recorded
  anywhere adopt may read, and adopt will not infer it from the issue text.

## The rule behind all of that

**Adopt never re-scans the captain's prose.** Every field comes from the
envelope or the label. It does not grep the body for the branch, the type, the
estimate, or where the PRD ends — the captain writes PRDs *about LCARS*, so any
such pattern eventually meets a document that talks about exactly those things.
When a fact is not recorded, adopt refuses and says so.

One visible consequence: `prd.md` is rebuilt as the **whole body minus the
envelope**, ADR and Estimate sections included. Nothing records where one
section ends and the next begins, so adopt keeps the body whole rather than
guessing at a boundary. A **parked** mission's body lands in `idea.md` (with
`prdPending`) instead, because no PRD exists for it yet.

## Notes it may print

- **`assigned to <login>`** — someone else holds the Mission. It is still
  rebuilt (reads are never blocked), but the write verbs will refuse until it is
  reassigned **on GitHub**.
- **`attachment(s) … are NOT here`** — GitHub has no API to carry issue assets;
  copy them into the mission's `attachments/` by hand if a stage needs them.
- **`no open PR resolves to #<n>`** — either Verify has not opened one yet, or
  the one it opened was closed unmerged. Those two are indistinguishable from
  GitHub's answer, so adopt says both rather than picking one.

## Report

Tell the captain the Mission is local, at which stage, where its directory is,
whether the branch was fetched, who owns it, and the PR URL when there is one —
then the next command (`lcars run <id>` at Align, `lcars approve <id>` /
`lcars feedback <id>` at Verify).

## Implementation

The logic lives in `adopt.sh` next to this file; the forge calls go through
`skills/lcars-run/host-adapter.sh` (`issue-body`, `issue-title`, `issue-labels`,
`issue-closing-prs`), the envelope parsing through
`skills/lcars-run/issue-body.sh`, and ownership through
`skills/lcars-run/ownership.sh`. The PR-resolution strategy is the recorded
outcome of the S189 spike — see `skills/lcars-run/ADOPT-RESOLUTION-SPIKE.md`
before changing it. Behaviour is covered by `tests/lcars-adopt.test.sh`.
`LCARS_GH_BIN`, `LCARS_GIT_BIN` and `LCARS_NOW` are taken via env so tests can
stub them. Edit the repo copy, not `~/.claude` — `./install.sh` symlinks it in.
