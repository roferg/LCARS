# LCARS — Domain Glossary

## Mission
The canonical unit of work moving through the LCARS harness. A Mission encapsulates a single human intent — a new feature, an improvement, or a bug fix — from initial idea through merged PR. Missions are independent, branch-isolated, and can run concurrently. Each Mission is represented as a GitHub issue and a card on the kanban board.

A Mission is filed via the **Entry Skill**. Bugs discovered against an active Mission (pre-merge) are logged via the **Mission Log** skill.

## Harness
The LCARS orchestration system. Takes a free-form human idea and drives it through a defined pipeline of LLM operations, automated checks, and human checkpoints, producing a merged PR as output. The Harness runs one or many Missions concurrently, each on its own branch.

## Stage
A named step in the Harness pipeline. Each Mission card on the kanban occupies exactly one Stage at a time. Stages in order: **Align → Research → Validate → Plan → Plan Review → Schedule → Implement → Verify → Done**.

## Align
The first Stage. A grill-me-with-docs session between the human and an LLM to reach shared understanding of the Mission. Output: a PRD (Product Requirements Document) that becomes the canonical spec for the Mission.

## PRD (Product Requirements Document)
The structured output of the Align stage. Contains the Mission's goals, acceptance criteria, constraints, and scope. All downstream stages refer to the PRD as the source of truth.

## Research
The second Stage. The Harness generates 0–20 questions based on the PRD. Each question is sent to a stateless Research Agent. If more than 20 questions are needed, the Harness explains why and gives the human the choice to override or loop back to Align with that context. For a **logged bug** (filed via the Mission Log) Research runs in **Grounding** mode instead of the question fan-out — see *Grounding*.

## Research Agent
A stateless LLM worker that receives a single question (no PRD, no prior context) and returns a structured response: a recommendation plus 2–3 supporting points. Research Agents have access to both the codebase and the web. Each Agent is blind to what the others are finding.

## Grounding
The mode Research runs in for a **logged bug** — a Mission filed via the Mission Log against an existing parent Mission. Instead of the 0–20 question fan-out, a single bounded, read-only worker anchors the bug's free-form symptom to the **existing code it is about** — reading the parent Mission's PRD, plan, and delivered code — and records which existing files and symbols the fix must modify, explicitly forbidding a parallel duplicate. It never escalates to the human. This is what keeps a casually-worded bug ("the icon is missing when no game is open") from being "fixed" by building a new control beside the real one instead of changing it. A logged bug then flows the full pipeline (Research → Validate → Plan → … → Verify); only Align is skipped.

## Validate
The third Stage. A Validator LLM reviews all Research Agent responses in the context of the PRD, synthesizes recommendations into a plan, and escalates to the human only when a finding implies a scope or direction change — something that would change *what* gets built, not *how*.

## Plan
The fourth Stage. The Harness decomposes the validated plan into small, independently testable GitHub issues (sub-tickets). Each issue is a vertical slice of full-stack functionality, targeting fewer than 300 lines of code (excluding tests). The output feeds directly into Plan Review before any scheduling occurs.

## Plan Review
The fifth Stage. A fresh LLM session — with no access to the planning conversation — audits every issue produced by Plan against a fixed set of quality criteria: vertical slice (touches multiple layers end-to-end, not just one horizontal layer), under 300 lines of production code, clear testable acceptance criterion, and explicit dependency edges. A **slice-pressure** heuristic (declared acceptance criteria, new files, breadth of touched directories) additionally flags a ticket that hides a whole surface behind a simple title, so the reviewer rejects a title that conceals multiple behaviors *or* a scope that silently omits part of the surface it claims (an under-slice) — a soft signal, never a mechanical size-reject.

If any issues fail, Plan Review returns the full set with specific objections and the Plan stage must revise. This loop repeats until all issues pass. After three rounds without a clean plan, Plan Review escalates to the human with the unresolved issues flagged — the human can override and proceed, or redirect.

## Schedule
The sixth Stage. The Harness builds a dependency graph of Plan issues and groups them into sequential waves. Issues within a wave have no dependencies on each other and can be implemented concurrently.

## Wave
A set of Plan issues that can be implemented concurrently because they have no mutual dependencies. Waves execute sequentially; the next Wave begins only when all issues in the current Wave are complete.

## Implement
The seventh Stage. Each issue in a Wave is handled by one **Unified (TDD) Implementer** — a single cold worker that writes both the tests and the code, in any order, running the suite freely until green. Its work is then proven by the harness's deterministic, post-hoc **proof-of-work** gates rather than by any second agent's judgment (see *Flip-flop gate*, *Declared edits*). The worker authors each ticket's suite at the repo's **own test convention** — co-located `*.test.ts`, a `__tests__/` dir, or a top-level `tests/`, detected from the repo — committed alongside the work, so the coverage **rides into the PR** and merges to the trunk instead of evaporating in a scratch dir. A quality failure never crashes the stage: a rejected ticket bounces to a fresh worker (up to three sessions) and then parks awaiting a human, with the failing gate named.

## Unified (TDD) Implementer
The single cold worker that builds one ticket in the Implement Stage. It replaces the retired adversarial Test-Writer / Implementer split (each ran as a separate session; the split stopped a ticket dead whenever the test-authoring agent failed). One worker ping-pongs tests and code; correctness is enforced afterward by the proof-of-work gates in the deterministic driver, because an LLM rewarded for a green suite would otherwise game a contract written by another LLM.

## Flip-flop gate
The core proof-of-work gate. A ticket's new and changed tests must **fail on the parent commit and pass on the tip** — the harness runs them scoped in the worker's worktree (green) and again in a disposable scratch worktree at the parent (red). Order-independent and mechanical. A test file that is **new at the parent** is staged into the scratch worktree, so its red proves the test depends on the change; a file that **already existed** there runs the **parent's own committed copy**, so its red proves that file was already failing — the distinction that makes a *Repair* provable. A leg whose runner announces it collected nothing is **inconclusive, never a pass**; a fully-skipped file that reports a clean zero instead is caught on the repair path by the executed-count comparison (see *Repair*). Replaces the old pre-implementation fail-first check; strictly stronger.

## Repair (test-infrastructure repair)
A ticket whose whole diff is test files, restoring a **pre-existing** test that another change broke without altering what it asserts (the classic: a build-config change rewrites how a test resolves the repo root, so the file throws at import and its tests silently stop running). Because the parent leg runs the parent's own copy, a repair produces a real red and can be certified — the alternative was an unexitable loop, since a repair changes no product behaviour. Two rules bound it. A diff that touches **any non-test path** is judged as an ordinary ticket (a repair is test-infrastructure only; a build config counts, since a config caused the original break) — where "non-test path" means a path the WORKER wrote, so an untracked symlink is excluded as harness provisioning (LCARS symlinks the dependency directory into each worktree, and a `node_modules/` ignore rule does not match a symlink, which made every repair on a standard JS repo read as a mixed diff) — and when that happens the rejection names the paths that withdrew the repair path, so a worker is never told its genuinely-broken test "passes on the parent" with no explanation. One check guards that path, and it reads no source: the tip may not **execute fewer** tests than the parent did, counting tests that actually ran (skipped ones excluded, since several runners report them in their totals) and only when the same runner parsed both legs — which catches a block disabled by `describe.skip`, an `if (false)` or an early `return`, where the source is identical and every test is still written down. A source-reading guard for the rest (test-name sets, skip markers, an assertion floor) was built and then **deleted**: five successive reviewers broke it at a new token, and its false-fails bounced honest repairs. In its place the repair is made VISIBLE — Verify lists every repaired file for the human, and the declared-edits contract already forces a reason for each. **Known residuals**, each pinned as an assertion: a parent copy dead at import executes nothing, so the count check is **vacuous for the very class this stage exists for**, leaving the declared edit and the human as the only protection; a runner with no executed count (go's default, cargo) or two legs read by different runner grammars makes the check unavailable; a test that keeps its name and its place in the run while checking less changes no count; a whole test file renamed is new-at-the-parent and never reaches the repair path; and a repair-only ticket satisfies this gate with no feature work of its own. The gate does not claim a repair removed nothing; the acceptance bar (weakening a test that PASSED on the parent) does not rest on that claim.

## Declared edits (contract amendments)
The unified worker may adapt an existing test the ticket genuinely invalidates, but must declare each edit — `{path, reason}` — in `result.json`. The harness diffs the tests against the parent commit (the commit **is** the snapshot); an **undeclared** test change blocks the ticket, naming the file. Declared edits are recorded to `tickets/<id>/test-edits.json` and surface at Verify as the **contract-amendments** readout, so the human sees which existing tests the change rewrote and why.

## gate-signal
The durable verdict a rejected proof gate writes (`tickets/<id>/gate-signal.txt`): which gate rejected the ticket, its verdict, and the runner tail. It rides the next (fresh) worker's prompt so a bounce carries forward exactly what was wrong — the mechanism that lets a quality failure retry instead of crashing, capped at three sessions before the ticket parks awaiting a human.

## Verify
The eighth Stage. The human reviews the completed Mission — inspecting code, running the app locally if needed — and either approves (triggering PR creation) or sends feedback that re-enters the loop. The PR carries each ticket's tests, committed at the repo's own test convention, so the hard-won coverage ships with the change; the pre-ship readout shows the per-ticket flip-flop verdict and any declared **contract amendments**, and a pre-merge check re-audits that no committed test drifted without a ticket declaring the edit.

## Setup Skill
A one-time-per-repo CLI skill (`lcars init`) that prepares a repo for LCARS usage. Does two things:

**Local:** Creates `.git/lcars/` state directory, writes repo-level config (default model, any project-specific preferences), scans for `CONTEXT.md` and reports it will be used, verifies CLI authentication.

**GitHub:** Creates the full set of LCARS Labels on the repo. These labels are the Kanban board's data model — the harness applies them as Missions move through stages, and the future Kanban reads them directly via the GitHub Issues API. No other GitHub setup is required.

Outputs a readiness summary. The only file-system change is inside `.git/`; the working tree is untouched.

## LCARS Labels
A standard set of GitHub issue labels created by the Setup Skill. They are the single source of truth for Mission state — the harness updates them, the Kanban board queries them.

**Stage labels** (one per stage, applied exclusively): `lcars:align`, `lcars:research`, `lcars:validate`, `lcars:plan`, `lcars:plan-review`, `lcars:schedule`, `lcars:implement`, `lcars:verify`, `lcars:done`

**Type labels**: `lcars:feature`, `lcars:bug`

**Status labels** (additive — overlaid on the stage label): `lcars:paused`, `lcars:awaiting-human`

**Relationship label**: `lcars:linked` — applied to bug Missions created via Mission Log that are linked to an active parent Mission.

**Role labels** (additive and permanent — they ride the issue for its whole life and are never swapped by a stage transition): `lcars:mission`, `lcars:ticket`. `lcars:mission` marks a Mission's own command-and-control issue (every Mission, including a logged bug); `lcars:ticket` marks an implementation sub-issue Schedule opens. The two are disjoint — a Mission never carries `lcars:ticket`, a sub-issue never carries `lcars:mission`. Filtering to `lcars:mission` is the command-and-control list (the Missions); `lcars:ticket` is the work (the per-ticket sub-issues), so during Implement a Mission and its tickets are distinguishable on the board.

## Entry Skill
A global CLI skill invokable from any repo. Accepts a free-form description of a new Mission (feature or bug) and launches the Harness pipeline from the Align stage. Used for standalone Missions with no relationship to other active work.

## Mission Log
A global CLI skill for logging bugs or feedback against an active Mission (one whose PR has not yet merged). Accepts free-form natural language — a single session can describe multiple bugs. The Harness extracts each distinct bug, creates a Mission for each — **grounded against the parent Mission's existing code** (it enters at Research in Grounding mode, skipping only Align) — and links all of them to the referenced open Mission.

The human is expected to name the open Mission in their feedback. If none is referenced, the skill asks which active Mission to link against before proceeding.

## Base freshness
The Harness's **best-effort** attempt to have a Mission reason about the codebase *as it exists*, not as the captain's checkout happens to have it — and, where it cannot, to say so out loud. It is explicitly not a guarantee: there are a dozen documented conditions under which it declines to act (a dirty tree, a diverged base, an unreachable or slow remote, a base with no counterpart on origin, a fast-forward that would overwrite an ignored local file), and in each of them the Mission is still filed against whatever the captain has.

A Mission's **base** is the branch its own `lcars/<id>` branch is cut from and the branch its PR will eventually target. Before that branch is cut, the Harness measures the base against `origin` and fast-forwards it — but ONLY when the working tree is clean, the base is checked out, the move is a genuine fast-forward, and it would not overwrite an untracked or ignored local file. It never resets, forces, stashes, rebases, cleans, switches or checks anything out, and never writes into a dirty tree. The work is deliberately split: a narrow, bounded, tagless `fetch` of that one branch (the network half — killable, and provably unable to touch the working tree), then an unbounded, purely local fast-forward onto the sha already fetched (the only ref-moving step, and never killed, so no timeout can ever land mid-checkout). Each bounded network call is announced with the bound it really honours, and can never stop to ask for credentials.

The outcome is recorded on the Mission as a **freshness verdict** — one of four words: `current` (up to date — including a base that is merely *ahead* of origin, since unpushed local commits are not staleness), `updated` (the Harness brought it up to date), `stale` (behind, and the Harness could not fix it) or `unknown` (freshness could not be determined). *Which* situation produced that verdict is deliberately NOT a name: it lives beside the verdict as one honest sentence and the exact command that fixes it, together with how far behind — and how far ahead — the base was, each a number when it was really measured and `null` when it could not be. Whether an outcome is loud is carried as its own field rather than inferred from the verdict, because `unknown` covers both the silent everyday no-remote case and a loud unreachable origin. Anything loud is stated out loud — what was skipped, why, and the fix — but a freshness verdict NEVER blocks filing or running. It makes an otherwise invisible condition visible.

## .git/lcars/
The directory where the Harness stores all local state for active Missions: paused state, wave dependency graphs, question queues, and stage checkpoints. Stored inside `.git/` so it is never tracked by git and requires no `.gitignore` entry. The Harness leaves zero artifacts in the working tree.

## Kanban Board
A custom interface (outside GitHub) that visualizes all active Missions as cards moving through the Harness Stages. Provides the human with start/stop control and surfaces pending questions from the Harness. Columns correspond exactly to Stages.
