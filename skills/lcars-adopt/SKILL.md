---
name: lcars-adopt
description: >-
  Pick up an existing LCARS Mission on THIS laptop from its GitHub issue
  alone — the portability verb. `lcars adopt <issue#>` reads the issue and
  its machine-readable `lcars:handoff` envelope, REUSES the mission's own id
  (never mints a new one), and rebuilds `.git/lcars/missions/<id>/` locally:
  at **Align** it claims the mission (assigns you on GitHub), rebuilds the
  spec from the issue body and fetches the branch if origin has one; at
  **Verify** it joins without claiming, resolves the OPEN pull request that
  closes the issue and records prUrl/prNumber so `lcars approve` and `lcars
  feedback` work with no further command. Any OTHER stage is refused
  honestly — v1 portability is the two ENDS, and the stages between keep
  their working artifacts on the laptop driving them. Use when the captain
  runs `lcars adopt <issue#>`, switches laptops, asks to pick up / continue
  / catch a mission filed on another machine, or wants a mission that exists
  on GitHub to show up on this clone's board.
---

# lcars adopt

`lcars adopt <issue#>` is how a Mission crosses machines. The captain files on
laptop A and catches it at Verify on laptop B; the issue is the handoff
document, and this verb turns it back into a local Mission.

It is purely mechanical — **no LLM** — so run the one script and report.

## When to use

The sentences below were part of this skill's frontmatter `description:` until
S276 moved them here. GitHub Copilot's CLI caps a skill description at 1024
characters and refused to load this skill over it; the description now keeps
the identity, the command forms and the `Use when…` trigger phrases that both
CLIs match on, and the detail it could not hold is relocated here verbatim.
Nothing was deleted.

Idempotent: adopting a mission that is already local refreshes it and keeps
local artifacts.

## What to run

```bash
bash ~/.claude/skills/lcars-adopt/adopt.sh --issue <issue-number> [--engine <claude|copilot>]
```

Run it from the clone the captain wants the Mission in. `--issue 42`, `42` and
`#42` are all accepted. `--engine` is how a non-interactive adopt converts the
Mission onto a CLI this laptop actually has — see *The engine* below.

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
4. **Settles the ENGINE** (S196) — see the next section. The answer is written
   to `state.json` as `workerBin` + `engineSource` + `engineResolved`, and from
   then on it OUTRANKS the repo's `config.json workerBin`.
5. **Seeds `config.json` when the clone has none**, through the same detectors
   `lcars init` uses (`detect_stack` / `detect_test_cmd` / the test-system
   evidence gate), so the adopted Mission has a `testCommand` for the Implement
   red gate and a `stack` for every stage that keys on the ecosystem. It never
   clobbers an existing config, and it never MANUFACTURES a `testCommand` in a
   repo with no test system — it warns instead. `lcars init` is still the full
   front door (labels, `.gitignore`); adopt seeds the minimum a drive needs.
6. **Carries the ESTIMATE across**, so the cost pill and the two difficulty
   pills the REMOTE card was showing survive the moment the Mission becomes
   local. The three values ride in the envelope as recorded fields
   (`estCostUnit` / `estCostLow` / `estCostHigh` / `estReasoning` / `estImpl`);
   a locally computed `estimate.json` is never overwritten, and an envelope
   without them writes no `estimate.json` at all.
7. **At Align** it also **claims** the Mission (assigns the captain on GitHub,
   best-effort) and fetches the branch if origin has one.
8. **At Verify** it resolves the **open PR that closes the issue** and records
   `prUrl` / `prNumber` / `review: open`, so `lcars approve` and `lcars
   feedback` work immediately. It does **not** claim — looking is never gated —
   but *acting* still requires ownership, and those verbs enforce that
   themselves.

## The engine — asked, converted, RECORDED

A laptop may only have ONE CLI installed, so adopt does not simply impose the
Mission's engine. It probes what this machine actually has (through the one
shared detector `lcars init` and the board's engine picker use), then:

- **the Mission's engine is here** → it takes over, and adopt says so;
- **it is here and this repo's `config.json` prefers a different one** → adopt
  ASKS, defaulting to the Mission's;
- **it is NOT here** → adopt ASKS which installed engine should take over, and
  records the CONVERSION;
- **no terminal to ask on, and no `--engine`** → adopt REFUSES, naming the
  engine the Mission wants and the ones this machine has. Nothing is created and
  nothing is recorded.

**It never switches an engine in silence.** That was a real, measured defect: a
Mission filed on Copilot, adopted onto a clone whose `config.json` said claude,
ran three billed workers and nothing anywhere said why. The chosen engine is
recorded on the Mission and now outranks `config.json`; `$LCARS_WORKER_BIN`
still outranks everything, because it is a per-invocation deliberate act.

The board shows the pair — `copilot · mission pin`, `claude · converted at
adopt`, `claude · repo config` — under the issue line on the card.

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
- **`config.json … was seeded`** — this clone was not initialised; adopt wrote a
  usable config so the Mission can be driven, and names what it detected (and
  what it could not).
- **`no testCommand could be detected`** — the Implement red gate has nothing to
  prove against. Set one with `lcars update --test-command '<command>'`.
- **`config.json prefers <engine>`** — a non-interactive adopt kept the
  Mission's engine over the repo's preference, and says so rather than
  resolving it behind the captain's back.
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
outcome of the S189 spike, documented beside `github_issue_closing_prs` in
`host-adapter.sh`. Behaviour is covered by `tests/lcars-adopt.test.sh`.
The engine probe and the config seeding both go through
`skills/lcars-init/lcars-common.sh` (`lcars_engine_available`,
`lcars_available_engines`, `detect_stack`, `detect_test_cmd`,
`lcars_config_merge`) — one implementation, shared with `lcars init`.
`LCARS_GH_BIN`, `LCARS_GIT_BIN`, `LCARS_NOW`, `LCARS_COMMON_LIB` and
`LCARS_ASSUME_TTY` (which forces the interactive branch so the prompt itself is
testable) are taken via env so tests can stub them. Edit the repo copy, not `~/.claude` — `./install.sh` symlinks it in.
