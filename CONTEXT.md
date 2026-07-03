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
The seventh Stage. Each issue in a Wave is handled by two sequential LLM sessions:
1. **Test Writer** — writes failing behavioral tests against the issue's public interface only.
2. **Implementer** — implements the issue to make the tests pass, without access to the Test Writer's session.

The separation is adversarial by design: the Test Writer cannot sandbag because it does not know who will implement; the Implementer cannot skip tests because they are handed as a constraint.

The Test Writer authors each ticket's suite at the repo's **own test convention** — co-located `*.test.ts`, a `__tests__/` dir, or a top-level `tests/`, detected from the repo — and it is committed alongside the work (the locked test in its own commit, the implementation after), so the coverage **rides into the PR** and merges to the trunk instead of evaporating in a scratch dir. Immutability holds across that commit boundary: the committed test is re-hashed against its locked snapshot at ticket-green and again at the pre-merge gate.

## Verify
The eighth Stage. The human reviews the completed Mission — inspecting code, running the app locally if needed — and either approves (triggering PR creation) or sends feedback that re-enters the loop. The PR carries each ticket's Test Writer suite, committed at the repo's own test convention, so the hard-won coverage ships with the change; a pre-merge gate re-checks each committed test against its locked snapshot (provisioning its environment the same way Implement does, so an environment failure is never mistaken for a real conflict), preserving immutability across the commit boundary.

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

## .git/lcars/
The directory where the Harness stores all local state for active Missions: paused state, wave dependency graphs, question queues, and stage checkpoints. Stored inside `.git/` so it is never tracked by git and requires no `.gitignore` entry. The Harness leaves zero artifacts in the working tree.

## Kanban Board
A custom interface (outside GitHub) that visualizes all active Missions as cards moving through the Harness Stages. Provides the human with start/stop control and surfaces pending questions from the Harness. Columns correspond exactly to Stages.
