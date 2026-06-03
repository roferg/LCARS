---
name: lcars-run
description: Advance an LCARS Mission one Stage. This build runs the Research, Validate, Plan, Plan Review, Schedule, and Implement stages — Research reads the PRD, generates 0–20 questions, dispatches stateless research subagents, and saves their findings; Validate synthesises those findings against the PRD into a validated plan, escalating scope changes to the human; Plan decomposes the validated plan into small, vertical-slice tickets in plan.json; Plan Review runs a fresh reviewer over those tickets alone, approving them to Schedule or looping back to Plan with objections (escalating to the human after three rounds); Schedule builds the ticket dependency graph into sequential waves, opens one GitHub sub-issue per ticket, and advances to Implement; Implement processes the waves sequentially, running each ticket through an adversarial Test Writer → Implementer pair (iterating up to 5 attempts, flagging the human on failure) and advancing to Verify when every ticket is green; and Verify prints the captain's pre-ship summary (mission title, every completed ticket, the test tally) and the two next moves, then stops at the human gate. It also handles the Align re-entry after `lcars feedback` bounces a Mission back from Verify — re-grilling against the PRD plus the accumulated feedback before Research. Use when the user runs `lcars run <mission-id>`, asks to advance / progress / continue a mission, or to run the Research, Validate, Plan, Plan Review, Schedule, Implement, or Verify stage on a filed mission.
---

# lcars run

`lcars run <mission-id>` advances a Mission through the LCARS pipeline **one
Stage at a time**. Every **headless** Stage's LLM work runs in a **cold
subprocess worker** — `run.sh` assembles the worker's prompt from a per-Stage
template plus the artifact *paths* alone and spawns it through `$LCARS_WORKER_BIN`
(the host CLI by default). You (Claude) do **no** Stage reasoning for those
Stages: you invoke the one driver subcommand and report what it printed. The
bundled `run.sh` does the spawning, validation, and mechanical persistence so it
all stays under test.

### Stage isolation: headless Stages are cold workers, not inline reasoning

The reason the LLM work is a subprocess and not something you do inline is
**isolation** (vision.md → *Stage Isolation*; closes BUG-004). A worker shares
**no** context with you or with the previous Stage — its prompt is built by
`run.sh` from the on-disk artifact **paths** only (the worker `Read`s them
itself), so there is no channel for one Stage's reasoning to leak into the next,
even when the whole pipeline runs in one sitting. Because the worker is one
swappable binary, this is also the CLI-portability groundwork (BUG-003): run
LCARS under Claude Code and every worker is Claude; under Copilot, every worker
is Copilot.

Each headless Stage is therefore a single driver subcommand you run and report:

| Stage | Driver | What it spawns |
|---|---|---|
| Research | `run.sh research --mission <id>` | a question-generator worker, then **N parallel** stateless research workers (one per question) |
| Validate | `run.sh validate --mission <id>` | one Validator worker (fed only `prd.md` + `research/*.json`) |
| Plan | `run.sh plan --mission <id>` | one Planner worker (fed only `prd.md` + `validated-plan.md`) |
| Plan Review | `run.sh plan-review --mission <id>` | one fresh reviewer worker (fed only `plan.json`) |
| Implement | `run.sh implement-ticket --mission <id> --ticket <id>` | a Test Writer worker, then a separate Implementer worker |

Each driver prints a **`⊘ isolated`** marker naming the worker it ran in. If no
worker binary is available the driver refuses **loudly** (`⚠ NOT ISOLATED`) and
changes nothing — an inline/uncovered run must never masquerade as isolated. A
malformed worker output stops the Stage and is re-dispatched up to a few attempts
before surfacing failure; the Stage never silently advances on bad output.

**Schedule** is mechanical (no worker), and the two **interactive** Stages —
Align's re-grill and the Verify gate — stay on the host CLI (your session), not a
cold worker. The driver subcommands sit on top of the mechanical persistence
subcommands (`gate` / `save` / `validate-*` / `plan-save` / `review-save` /
`impl-*`), which they reuse to record results.

**This build implements the Research, Validate, Plan, Plan Review, Schedule,
Implement, and Verify stages.** A Mission filed by `lcars file` sits at stage
`align` (the Align grilling already happened during `lcars file`), so the next
Stage to execute is **Research**; when Research finishes the Mission parks at
`validate`, ready for **Validate**; when Validate finishes it parks at `plan`,
ready for **Plan**; when Plan finishes it parks at `plan-review`, ready for
**Plan Review**; when Plan Review passes it parks at `schedule`, ready for
**Schedule**; when Schedule finishes it parks at `implement`, ready for
**Implement**; when Implement finishes it parks at `verify`, ready for
**Verify**. Verify is a human gate: `lcars run` prints the pre-ship summary and
stops, and the captain ships with **`lcars approve`** or bounces it back with
**`lcars feedback`** (each its own skill). A feedback bounce resets the Mission
to `align` with `feedback.md` on disk, so the next `lcars run` re-enters Align
rather than running Research cold.

## Dispatch on the current stage

1. Read `.git/lcars/missions/<id>/state.json`. If the mission dir or
   `state.json` is missing, tell the captain the id is wrong / the mission
   isn't filed, and stop.
2. Look at `state.json.stage`:
   - `align` → **first check for `feedback.md`** in the mission dir. If it
     exists, the Mission was bounced back from Verify (`lcars feedback`), so
     run the **Align re-entry** (below) — re-grill against the existing PRD
     *and* the accumulated feedback before Research. If there is no
     `feedback.md`, this is a freshly filed Mission: run the **Research stage**
     (below).
   - `validate` → run the **Validate stage** (below). But first check
     `awaitingHuman`: if it is `true`, the Mission is parked at a human gate —
     a scope question is unanswered. **Do not re-run the Validator.** Tell the
     captain the Mission is waiting on them (`lcars respond <id>`) and stop.
     (Once `lcars respond` records the answer it clears `awaitingHuman`, so the
     next `lcars run` falls through and resumes Validate with the answer in
     hand.)
   - `plan` → run the **Plan stage** (below).
   - `plan-review` → run the **Plan Review stage** (below). But first check
     `awaitingHuman` exactly as Validate does: if it is `true`, Plan Review has
     already escalated three failed rounds and is parked at the human gate.
     **Do not re-run the reviewer.** Tell the captain the Mission is waiting on
     them (`lcars respond <id>` — to override and proceed, or redirect) and
     stop.
   - `schedule` → run the **Schedule stage** (below).
   - `implement` → run the **Implement stage** (below). But first check
     `awaitingHuman` exactly as Validate does: if it is `true`, a ticket
     exhausted its 5 attempts and the Mission is parked at the human gate.
     **Do not re-run the ticket.** Tell the captain the Mission is waiting on
     them (`lcars respond <id>`) and stop. (Once the human resolves it and
     `lcars respond` clears the gate, the next `lcars run` falls through and
     resumes the open waves.)
   - `verify` → run the **Verify stage** (below): print the summary and hand
     the ship-or-send-back decision to the captain. Do **not** advance — Verify
     is a human gate, resolved by `lcars approve` / `lcars feedback`.
   - `done` → the Mission has shipped. Tell the captain it is complete (the PR
     is open) and stop.
   - anything else → not implemented in this build; report the current stage
     and stop. (`run.sh` also refuses to run a Stage on the wrong stage.)

## The Research stage

**Do not read the PRD, generate questions, or spawn agents yourself.** Research
is a headless Stage: run the one driver and report. It spawns a cold
question-generator worker (fed only `prd.md`), gates on the count, and on
dispatch fans out **N parallel** stateless research workers — each given only its
single question, no PRD and no siblings (CONTEXT.md → *Research Agent*) — then
saves the findings and advances to `validate`.

```bash
bash ~/.claude/skills/lcars-run/run.sh research --mission <id>
```

The driver prints the gate decision plus a `⊘ isolated` marker:

| Driver output | Meaning | What you do |
|---|---|---|
| `GATE: skip` then `⊘ isolated` | 0 questions — the PRD was unambiguous. The mission has **already** advanced (stage + label → `validate`). | Report it. **Done.** |
| `GATE: dispatch N` … `SAVE: N responses` … `⊘ isolated` | N research workers ran in parallel and their findings were saved; the mission advanced to `validate`. | Report how many ran and that it is ready for **Validate**. |
| `GATE: too-many N` (exit 3) | More than 20 questions — the driver escalated to the **awaiting-human** gate (card moved to the Research column, `lcars:awaiting-human` overlaid). | Surface the two options — **override** (re-run `research` to proceed) or **return-to-align** (re-run `lcars file` with the context to sharpen the PRD). The captain answers with `lcars respond <id>`. |

If the driver prints `⚠ NOT ISOLATED` and refuses, there is no worker binary —
tell the captain to set `$LCARS_WORKER_BIN` (e.g. `claude`); do **not** try to do
the Stage inline.

## The Validate stage

Runs when `state.json.stage` is `validate` and `awaitingHuman` is not `true`
(see Dispatch). **Do not synthesise the findings yourself.** Run the driver: it
spawns one cold **Validator** worker fed only `prd.md` + `research/*.json`. The
worker reviews every finding *in the context of the PRD*, writes a
`validated-plan.md` synthesis (with `## Synthesis`, `## Decisions`, and a
`## Rationale` section recording the *why*), and emits zero or more
**scope-change** questions — a point counts only if it changes *what* gets built,
not *how* (CONTEXT.md → *Validate*). The driver persists the outcome.

```bash
bash ~/.claude/skills/lcars-run/run.sh validate --mission <id>
```

| Driver output | Meaning | What you do |
|---|---|---|
| `VALIDATE: advanced` … `⊘ isolated` | No scope question. The worker's `validated-plan.md` is saved and the mission advanced to `plan`. | Report that it is at **Plan**. |
| `VALIDATE: paused` … | A scope question. The driver wrote `pending.json`, set the awaiting-human gate, and kept the card in Validate. | Surface the question(s); the captain answers with `lcars respond <id>`. **Stop.** |

A worker whose plan is malformed (e.g. it drops the `## Rationale`) is rejected
and re-dispatched; if it never produces a valid plan the driver stops the Stage
without advancing.

**Resume after the human answers:** once `lcars respond <id>` records the answers
and clears `awaitingHuman`, the next `lcars run <id>` falls through to Validate
again and re-runs the driver. The fresh Validator worker reads the recorded
answers alongside the PRD and findings, folds them in, and — assuming no new
scope question — advances to Plan, clearing the gate.

## The Plan stage

Runs when `state.json.stage` is `plan`. **Do not decompose the plan yourself.**
Run the driver: it spawns one cold **Planner** worker fed only `prd.md` +
`validated-plan.md` — the *what* and the agreed *how* — which decomposes them
into small, vertical-slice tickets and writes `plan.json`. The driver validates
and installs it, advancing to `plan-review`.

```bash
bash ~/.claude/skills/lcars-run/run.sh plan --mission <id>
```

Each ticket the worker produces carries `id`, `title`, `description`,
`acceptanceCriteria` (≥1), `estimatedLoc` (<300), `dependencies` (only ids in
this plan), and a **`rationale`** — *why* this slice exists and why it is drawn
where it is. `plan-save` (invoked by the driver) refuses a plan that drops any
required field, including the rationale, so the Stage will re-dispatch the worker
and ultimately stop rather than advance on a half-formed plan. On success the
driver prints `PLAN: advanced` and a `⊘ isolated` marker.

**Report:** how many tickets the plan holds (`plan.json`) and that the Mission is
now at **Plan Review**. (On a Plan Review loop-back, this same driver re-runs; the
fresh Planner worker reads the latest `plan-review-<round>.json` objections
itself — see Plan Review below.)

## The Plan Review stage

Runs when `state.json.stage` is `plan-review` and `awaitingHuman` is not `true`
(see Dispatch). **Do not review the tickets yourself.** Run the driver: it spawns
one **fresh reviewer** worker fed **only** `plan.json` — never `prd.md` or
`validated-plan.md`. That independence is the whole point (vision.md → *Plan
Review*): the session that planned the work must not also grade it, so leaking
the spec in is structurally prevented — the driver simply doesn't put it on the
worker's path list. The worker audits every ticket (vertical slice, <300 LoC,
testable, deps in-plan) and emits a verdict; the driver branches on it.

```bash
bash ~/.claude/skills/lcars-run/run.sh plan-review --mission <id>
```

| Driver output | Meaning | What you do |
|---|---|---|
| `PLAN-REVIEW: passed` … `⊘ isolated` | Every ticket cleared review. `approved-plan.json` written; advanced to `schedule`. | Report it is at **Schedule**. |
| `PLAN-REVIEW: revise — round N` | The verdict failed (rounds 1–2). Objections logged to `plan-review-<round>.json`; looped back to `plan`. | Surface the objections; the next `lcars run <id>` re-runs **Plan**, whose worker reads the objections and revises. |
| `PLAN-REVIEW: escalated` | The 3rd failed round. The driver wrote the unresolved objections to `pending.json`, set the awaiting-human gate, and kept the card in Plan Review. | Surface them; the captain overrides (proceed) or redirects via `lcars respond <id>`. **Stop.** |

`planReviewRound` persists across the loop, so the third failure escalates rather
than looping forever. A `passed:false` verdict with no issues is malformed — the
driver re-dispatches the reviewer and ultimately stops rather than moving on a
verdict that names nothing.

## The Schedule stage

Runs when `state.json.stage` is `schedule`. **This Stage is purely mechanical —
there is no LLM work to do.** The dependency graph, the wave grouping, and the
GitHub sub-issue creation are all deterministic, so you do **not** spawn agents
or reason over the plan: you just run the one subcommand and report what it did.

### STEP 1 — Run the schedule subcommand

```bash
bash ~/.claude/skills/lcars-run/run.sh schedule --mission <id>
```

`schedule` reads `approved-plan.json` (the ticket list Plan Review approved) and:

1. **Builds the dependency graph** from each ticket's `dependencies` array.
2. **Groups the tickets into sequential waves** by topological order — wave 1 is
   every ticket with no dependencies; wave *N* is every remaining ticket whose
   dependencies all sit in earlier waves (see CONTEXT.md → *Wave*). Tickets in a
   wave are mutually independent and so implementable in parallel.
3. **Creates one GitHub sub-issue per ticket**, titled with the ticket title and
   bodied with its description plus an **Acceptance Criteria** list, labelled
   `lcars:implement,lcars:<type>` (the Mission's type — `feature`/`bug`).
4. **Writes `waves.json`** — an array of `{ wave, tickets:[ { id, issue } ] }`,
   each ticket carrying the number of the sub-issue just opened for it.
5. **Advances** the stage to `implement` and moves the Mission's own issue label
   `lcars:schedule` → `lcars:implement`.

On success it prints:

```
SCHEDULE: advanced
  Grouped 4 ticket(s) into 2 wave(s); opened 4 sub-issue(s).
  Wrote waves.json.
  Stage:  implement
```

### STEP 2 — Circular dependencies stop the Stage

If the tickets form a dependency cycle, no wave can be built. `schedule` names
the stuck tickets and **changes nothing** — no `waves.json`, no sub-issues, no
stage move:

```
lcars run: circular dependency detected among the remaining tickets: t-002 t-003
```

The approved plan should never contain a cycle (`plan-save` already rejects
dangling dependency refs, and a clean plan is acyclic), so treat this as a
planning bug: surface the cycle to the captain. It cannot be resolved by
re-running Schedule — the plan itself has to change.

### STEP 3 — Report

Tell the captain how many waves the Mission was scheduled into, where the wave
graph lives (`waves.json`), that one sub-issue was opened per ticket, and that
the Mission is now at **Implement**.

## The Implement stage

Runs when `state.json.stage` is `implement` and `awaitingHuman` is not `true`
(see Dispatch). The Mission's `waves.json` (from Schedule) is the work plan:
**process the waves in order, and within a wave build the tickets in parallel.**
Each ticket is built by two **adversarially-separated** LLM sessions (see
vision.md → *Implement*): a **Test Writer** that writes failing tests, then a
**fresh Implementer** — with *no* Test Writer context — that makes them pass.
The script owns the mechanical, testable handoffs; you drive the two sessions.

### STEP 1 — Find the current wave

Ask the script which wave to build and which of its tickets still need work:

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-status --mission <id>
```

`impl-status` prints the **lowest-numbered wave that still has an unfinished
ticket** and lists that wave's pending ticket ids — it will **not** reveal a
later wave while an earlier one has open work, which is exactly the
sequential-wave rule. Two outcomes:

| Output | Meaning | What you do next |
|---|---|---|
| `IMPLEMENT: wave N active` | Wave N is the current wave; the line lists its pending tickets. | Build **every** listed ticket (STEP 2), then loop back to STEP 1. |
| `IMPLEMENT: complete` | Every ticket in every wave is green. | Go to STEP 4 — advance to Verify. |

### STEP 2 — Build each pending ticket (the cold adversarial pair)

For each pending ticket the current wave lists, run the **implement-ticket**
driver. **Do not write tests or implement anything yourself** — the driver
spawns the two cold, adversarially-separated workers for you: a **Test Writer**
worker (fed only the ticket from `approved-plan.json`) writes failing tests,
which are quarantined to `tickets/<id>/tests/`; then a **separate Implementer**
worker (fed only the ticket + those on-disk tests — *never* the Test Writer's
session) makes them pass, iterating up to 5 attempts.

```bash
bash ~/.claude/skills/lcars-run/run.sh implement-ticket --mission <id> --ticket <ticket-id>
```

The two workers never share a session: the on-disk `tests/` dir is the
Implementer's *entire* handoff, which is what keeps the split adversarial. The
driver persists each phase (`impl-save-tests`, then `impl-save-result`) and, on a
green ticket, **commits the Implementer's produced files to the Mission's
branch** (the `branch` from `state.json`) so the eventual PR has content — a
missing branch / no changes / git failure is a best-effort warning, the result
still stands. On success it prints `⊘ isolated — implement(<id>)`.

If the Implementer exhausts its 5 attempts (`passed:false`), the driver **flags
the human**: it writes the blocker to `pending.json`, sets the awaiting-human
gate, and keeps the card in Implement. Surface that and **stop** — the ticket
needs `lcars respond <id>`; do not re-run it.

Run `implement-ticket` for **every** pending ticket the current wave lists (they
are independent within the wave), then loop back to STEP 1, which reveals the
next wave only once this one is fully green.

### STEP 3 — Finish the wave before the next

`impl-status` enforces this for you: it never surfaces wave N+1 while wave N has
a pending ticket. So the loop is simply: STEP 1 → build the wave (STEP 2) →
STEP 1 again, until `impl-status` reports `complete`.

### STEP 4 — Advance to Verify

When `impl-status` reports `complete`, advance the Mission:

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-advance --mission <id>
```

`impl-advance` re-checks that **every** ticket in **every** wave has a passing
result, then sets the stage to `verify` and moves the label `lcars:implement` →
`lcars:verify`. If any ticket is still unfinished (or flagged), it refuses and
names the first blocker — a half-built Mission can never slip into Verify.

### STEP 5 — Report

Tell the captain that every ticket passed across all waves, where the per-ticket
tests and results live (`tickets/<id>/tests/`, `tickets/<id>/result.json`), and
that the Mission is now at **Verify** — or, if a ticket flagged the human, which
ticket failed and how to resolve it (`lcars respond <id>`).

## The Verify stage

Runs when `state.json.stage` is `verify`. Implement parks the Mission here once
every ticket is green across every wave. **This Stage is a human gate** — the
captain reads the diff, runs the app, and decides whether to ship. You print the
summary and stop; you do **not** advance the Mission yourself.

### STEP 1 — Print the pre-ship summary

```bash
bash ~/.claude/skills/lcars-run/run.sh verify-summary --mission <id>
```

`verify-summary` is read-only. It prints the mission title, every completed
ticket with its result (✓ + attempt count, read from each
`tickets/<id>/result.json`), the overall test tally (e.g. `4/4 ticket(s) green
across 2 wave(s)`), and the two next moves:

```
VERIFY: <title>
  All tickets completed:
    ✓ t-001 — passed in 2 attempt(s)
    …
  Test results: 4/4 ticket(s) green across 2 wave(s).
  Review the changes and run the app if needed.
    lcars approve <id>    — create the PR
    lcars feedback <id>   — send back with feedback
```

### STEP 2 — Hand the decision to the captain

Surface that summary and stop. The captain drives the outcome with a separate
skill — neither is part of `lcars run`:

- **`lcars approve <id>`** (the `lcars-approve` skill) — ship it: open the PR,
  mark the Mission `done`.
- **`lcars feedback <id> "<feedback>"`** (the `lcars-feedback` skill) — send it
  back: append the note to `feedback.md` and reset the Mission to `align`.

Do not call `verify-summary` again on a loop and do not try to advance the
Mission — Verify only moves when the captain approves or sends feedback.

## The Align re-entry (after feedback)

When `lcars feedback` bounces a Mission back, it resets the stage to `align`,
writes `feedback.md`, and **keeps every prior artifact** (PRD, research,
validated/approved plans). So an `align` Mission falls into one of two cases,
and the dispatch tells them apart by whether `feedback.md` exists:

- **No `feedback.md`** → a freshly filed Mission. Run **Research** as usual (the
  `research` driver).
- **`feedback.md` present** → a re-entry from Verify. The re-grill is
  **interactive**, so it stays on the host CLI (your session), not a cold worker:
  read `prd.md` *and* the full `feedback.md` (every stamped note, in order) plus
  any other artifacts you need, re-grill the same way `lcars file` did, and
  **rewrite `prd.md`** to fold in the captain's feedback. Once the PRD reflects
  the feedback, carry on into the **Research stage** in the same run — run the
  `research` driver, which reads the now-updated `prd.md`. Leave `feedback.md` in
  place as the durable history; it accumulates across rounds, and the `research`
  driver does not treat its presence as a blocker (the re-grill already ran).

This is what makes the Verify → Align loop pick up with the full context instead
of starting cold.

## One source of truth: stage and label always agree

A Mission's position is stored in two places — `state.json.stage` on disk and
the GitHub label (which is what the kanban board reads). **They always hold the
same value**, so there is one unambiguous answer to "where is this Mission?" —
the Stage `lcars run` will execute next:

- A freshly filed Mission sits at **`align`** (Align already happened during
  `lcars file`). `lcars run` treats `align` as the signal to run **Research**.
- When Research finishes, both move to **`validate`** together — the card lands
  in the Validate column, and the next `lcars run` will run Validate.
- When Validate finishes, both move to **`plan`** together. While Validate is
  paused on a scope question, the stage stays `validate` and the additive
  `lcars:awaiting-human` label overlays it — the card stays in the Validate
  column, flagged as awaiting input, until the captain answers.
- When Plan finishes, both move to **`plan-review`** together — the card lands
  in the Plan Review column, ready for the Plan Review stage.
- When Plan Review passes, both move to **`schedule`** together. When it fails,
  both loop back to **`plan`** together so the card returns to the Plan column
  for revision; after three failed rounds the stage stays `plan-review` and the
  additive `lcars:awaiting-human` label overlays it — the card stays in the Plan
  Review column, flagged as awaiting input, until the captain answers.
- When Schedule finishes, both move to **`implement`** together — the card lands
  in the Implement column. The per-ticket sub-issues Schedule opens are *new*
  GitHub issues, each created already at `lcars:implement`; the Mission's own
  issue label is what moves `lcars:schedule` → `lcars:implement`.
- When Implement finishes (every ticket green across every wave), both move to
  **`verify`** together — the card lands in the Verify column. While a ticket is
  flagged for the human (it exhausted its 5 attempts), the stage stays
  `implement` and the additive `lcars:awaiting-human` label overlays it — the
  card stays in the Implement column, flagged as awaiting input, until the
  captain resolves it.
- At **`verify`** the Mission waits on the captain. `lcars run` only prints the
  summary; the move out of Verify is the captain's: **`lcars approve`** advances
  both stage and label to **`done`** (the card lands in the Done column once the
  PR is open), while **`lcars feedback`** resets both back to **`align`** and
  drops a `feedback.md` so the card returns to the Align column for a re-grill
  with the full prior history.

GitHub labels are the board's source of truth; `.git/lcars/` is the run-time
store. Keeping them in lockstep is what lets you call `lcars run` repeatedly and
trust the board to show exactly where every Mission is.

## What gets written

```
.git/lcars/missions/<id>/
  research/
    1.json, 2.json, …   ← one stateless agent's findings per file (Research)
  validated-plan.md     ← the Validator's synthesis: Synthesis + Decisions + Rationale (Validate → Plan)
  plan.json             ← the Planner's ticket list, each ticket carrying its rationale (Plan → Plan Review)
  approved-plan.json    ← copy of plan.json once Plan Review passes (→ Schedule)
  plan-review-<n>.json  ← the reviewer's verdict for failed round n (Plan Review)
  waves.json            ← the wave graph: [ { wave, tickets:[ { id, issue } ] } ] (Schedule → Implement)
  tickets/
    <ticket-id>/
      tests/            ← the Test Writer's failing tests (Implement, Phase 1)
      result.json       ← { ticketId, passed, attempts, summary } (Implement, Phase 2)
  pending.json          ← scope/objection/flagged-ticket questions, while paused at the human gate only
  feedback.md           ← the captain's Verify feedback, accumulated (written by `lcars feedback`; read by the Align re-entry)
  state.json            ← stage pointer + branch/base; + planReviewRound, awaitingHuman/pendingQuestion while paused
```

All LCARS state stays inside `.git/`. The **one** thing Implement writes to the
git history proper is the Mission's branch: each green ticket's produced files
are committed to `lcars/<id>` (never to the base branch). Nothing else in the
working tree changes.

## Notes & failure modes

- **Headless Stages are cold workers — never do their reasoning inline.** For
  Research / Validate / Plan / Plan Review / Implement you run the driver and
  report; the LLM thinking happens in a subprocess worker whose prompt `run.sh`
  builds from artifact *paths* alone. If a driver prints `⚠ NOT ISOLATED` it
  found no worker binary — set `$LCARS_WORKER_BIN` (e.g. `claude`); do **not**
  substitute your own session for the worker.
- **Wrong stage for the Stage** → `run.sh` exits non-zero and changes nothing.
  Research only runs on an `align` mission; Validate only on a `validate` one;
  Plan only on a `plan` one; Plan Review only on a `plan-review` one; Schedule
  only on a `schedule` one; Implement only on an `implement` one.
- **No GitHub issue on file** (`githubIssue: null`) → the stage still advances;
  the relabel is skipped with a warning telling you to do it by hand.
- **`gh` missing / edit fails** → same: the local stage advances; you get a
  warning with the exact `gh` relabel to run later.
- **Research workers stay stateless — by construction.** The driver hands each
  research worker only its single question; it never puts `prd.md` or a sibling
  finding on the worker's path list. Synthesis against the PRD is the Validate
  worker's job.
- **Validate escalates scope, not implementation.** Only a finding that changes
  *what* gets built belongs in a scope question; the Validator worker decides
  everything else and records it under `## Decisions` (with its `## Rationale`).
  Over-escalating turns the walk-away gate into a chat.
- **A paused Validate must not re-run on its own.** When `awaitingHuman` is
  `true`, the `validate` driver refuses — wait for `lcars respond`. A fresh
  Validator worker only runs once the answer is recorded and the gate is cleared.
- **Decisions/rationale are required, not optional.** `validate-advance` refuses
  a `validated-plan.md` with no `## Rationale`, and `plan-save` refuses any
  ticket missing its `rationale` field — the artifact is the only thing crossing
  the Stage boundary, so it must carry the *why* (vision.md → *Stage Isolation*).
  The driver re-dispatches the worker and ultimately stops; it never advances on
  an artifact that drops its reasoning.
- **Malformed worker output stops the Stage, after retries.** Any worker artifact
  that fails its persistence validator is re-dispatched up to a few attempts;
  if it never validates the driver stops the Stage and changes nothing — no
  silent advance.
- **Every Plan ticket is a vertical slice under 300 LoC.** That sizing keeps
  each ticket inside an implementer LLM's window — the Planner worker must not
  emit horizontal, layer-only tickets or ones that blow past the limit.
- **The Plan Review reviewer is independent by construction.** The driver puts
  only `plan.json` on the reviewer worker's path list — never `prd.md` or
  `validated-plan.md` — so the session that planned the work cannot also grade it
  (vision.md → *Plan Review*), the same way a research worker never sees the PRD.
- **A failed verdict must name its objections.** `review-save` refuses a
  `passed:false` verdict with an empty `issues` list and changes nothing — a
  failing review has to say *what* failed so Plan can revise.
- **Plan Review escalates after three rounds, it does not loop forever.**
  `planReviewRound` persists across the loop-back to Plan; the third failure
  parks the card at the awaiting-human gate (stage stays `plan-review`) for the
  captain to override or redirect, rather than bouncing Plan again.
- **Schedule is mechanical — don't reason over it.** The wave grouping and
  sub-issue creation are deterministic; never spawn an LLM to "decide" the
  waves. Just run `schedule` and report. A canonical `approved-plan.json` is
  acyclic (deps were validated at `plan-save`), so a reported cycle is a
  planning bug to surface, not something Schedule can retry away.
- **Schedule degrades gracefully without gh.** If `gh` is missing or a create
  fails, the waves are still grouped and `waves.json` is still written (with
  `"issue": null` for the un-opened tickets) and the stage still advances; you
  get a warning to open the sub-issues by hand.
- **Implement keeps the Test Writer and Implementer adversarially separate.**
  They are two distinct cold workers: the Implementer's *only* handoff from the
  Test Writer is the tests on disk (`tickets/<id>/tests/`) — the
  `implement-ticket` driver never gives the Implementer the Test Writer's output
  channel beyond that dir. `impl-save-result` refuses a result for a ticket whose
  tests aren't saved yet, so Phase 1 always precedes Phase 2. The Implementer
  must not modify the test files, and the Test Writer must not write
  implementation code.
- **Implement processes waves strictly in order.** `impl-status` never reveals a
  later wave while an earlier one has an open ticket, and `impl-advance` refuses
  to reach Verify until *every* ticket in *every* wave is green — so a half-built
  Mission can't slip forward. Build all of the current wave before looping back.
- **A ticket flags the human at the 5-attempt cap.** `impl-save-result` caps
  `attempts` at 5 and, on `passed: false`, parks the Mission at the
  awaiting-human gate (stage stays `implement`, `lcars:awaiting-human` overlays
  the card). Don't keep re-running a flagged ticket — wait for `lcars respond`.
- **Implement commits each green ticket to the Mission's branch.** The files
  the Test Writer / Implementer produce are committed to `lcars/<id>` (recorded
  by `lcars file`) the moment a ticket goes green, so the eventual PR has
  content. The commit is best-effort and jq-free: no branch on file, no file
  changes, or a git failure just leaves a warning — the saved result still
  stands. Don't hand-commit the Implementer's output elsewhere; let
  `impl-save-result` do it onto the branch.
- **Verify is a human gate — `lcars run` never advances it.** `verify-summary`
  is read-only; the Mission only leaves Verify when the captain runs
  `lcars approve` (→ `done`) or `lcars feedback` (→ `align`). Don't try to ship
  or bounce a Mission from inside `lcars run`.
- **An `align` Mission with a `feedback.md` is a re-entry, not a fresh file.**
  Re-run Align (re-grill against the PRD + feedback and rewrite `prd.md`) before
  Research; only a `feedback.md`-free `align` Mission goes straight to Research.

## Implementation

`run.sh` next to this file holds two layers. **Stage drivers** spawn the cold
workers and persist their output: `research`, `validate`, `plan`, `plan-review`,
`implement-ticket`. **Persistence subcommands** (which the drivers reuse, and
which the test suite drives directly) do the mechanical, jq-free recording:
`gate`, `save`, `validate-pause`, `validate-advance`, `plan-save`, `review-save`,
`schedule`, `impl-save-tests`, `impl-save-result`, `impl-status`, `impl-advance`,
`verify-summary`. Each headless Stage's worker prompt is a template under
`skills/lcars-run/stages/<role>.md`; `run.sh` assembles the final prompt from the
template plus the artifact *paths* and spawns it via `$LCARS_WORKER_BIN`
(default `claude`) with the Stage's restricted tool set.

The Verify gate's two outcomes are separate skills — `lcars-approve` and
`lcars-feedback` — each with its own script and test suite. Behaviour is covered
by `tests/lcars-run.test.sh` (run with `bash tests/run.sh`); its stage-isolation
section stubs `$LCARS_WORKER_BIN` so the spawn/assemble/validate/persist plumbing
runs token-free. The skill source lives in `skills/lcars-run/` and is symlinked
into `~/.claude/skills/` by `./install.sh`; edit the repo copy, not `~/.claude`.
If you change `run.sh` or a stage template, keep those tests green.
