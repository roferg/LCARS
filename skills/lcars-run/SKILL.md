---
name: lcars-run
description: Advance an LCARS Mission one Stage. This build runs the Research, Validate, Plan, Plan Review, Schedule, and Implement stages — Research reads the PRD, generates 0–20 questions, dispatches stateless research subagents, and saves their findings; Validate synthesises those findings against the PRD into a validated plan, escalating scope changes to the human; Plan decomposes the validated plan into small, vertical-slice tickets in plan.json; Plan Review runs a fresh reviewer over those tickets alone, approving them to Schedule or looping back to Plan with objections (escalating to the human after three rounds); Schedule builds the ticket dependency graph into sequential waves, opens one GitHub sub-issue per ticket, and advances to Implement; Implement processes the waves sequentially, running each ticket through an adversarial Test Writer → Implementer pair (iterating up to 5 attempts, flagging the human on failure) and advancing to Verify when every ticket is green; and Verify prints the captain's pre-ship summary (mission title, every completed ticket, the test tally) and the two next moves, then stops at the human gate. It also handles the Align re-entry after `lcars feedback` bounces a Mission back from Verify — re-grilling against the PRD plus the accumulated feedback before Research. Use when the user runs `lcars run <mission-id>`, asks to advance / progress / continue a mission, or to run the Research, Validate, Plan, Plan Review, Schedule, Implement, or Verify stage on a filed mission.
---

# lcars run

`lcars run <mission-id>` advances a Mission through the LCARS pipeline **one
Stage at a time**. You (Claude) drive the LLM work; the bundled `run.sh` does
the mechanical, testable persistence so it stays under test.

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

### STEP 1 — Read the PRD

Read `.git/lcars/missions/<id>/prd.md`. This is the canonical spec produced by
Align. It is your **only** input for generating questions.

### STEP 2 — Generate 0–20 research questions

From the PRD, write the set of questions that genuinely need an answer before
implementation — each a design choice, product consideration, or engineering
decision the PRD leaves open. Be honest about ambiguity:

- **If the PRD is simple and unambiguous, generate 0 questions.** A one-line
  bug ("/about 404s") needs no research. Don't manufacture questions to look
  thorough.
- **Aim for 0–20.** Most missions need a handful.
- **If you genuinely need more than 20,** that's a signal the PRD is
  underspecified — see the gate below.

Write one question per line to a temp file, then run the **gate** so the count
decision is mechanical and logged:

```bash
qs=$(mktemp)
cat > "$qs" <<'Q'
Which colour token should drive the dark theme?
Where is the user's theme choice persisted?
Q
bash ~/.claude/skills/lcars-run/run.sh gate --mission <id> --questions "$qs"
```

The gate prints one of three outcomes and sets its exit code accordingly:

| Output | Meaning | What you do next |
|---|---|---|
| `GATE: skip` | 0 questions. The script has **already** advanced the mission (stage and label both → `validate`). | Report it to the captain. **Done.** |
| `GATE: dispatch N` | 1–20 questions. Nothing changed yet. | Go to STEP 3 — spawn N agents. |
| `GATE: too-many N` (exit 3) | More than 20. Nothing changed. | Go to the **>20 escalation** below. Do **not** spawn agents. |

> For an empty question set, pass an empty file (or `--questions /dev/null`);
> the gate treats zero non-blank lines as "skip".

#### >20 escalation

The gate has already printed the explanation and the two options. Surface them
to the captain and let them decide — do not proceed on your own:

- **override** — re-run the gate is *not* needed; instead spawn all N agents
  anyway (STEP 3), because the captain has accepted the larger set.
- **return-to-align** — the PRD needs sharpening. Re-run `lcars file` for this
  mission with the unresolved questions appended as context, so Align can
  resolve them, then run Research again.

### STEP 3 — Dispatch one stateless agent per question

For each question, spawn a **parallel** subagent (use the Agent tool; send them
together in one message so they run concurrently). Each agent is **stateless**:

- It receives **only the question text** — **no PRD, no other context, no other
  agents' findings.** This is deliberate (see CONTEXT.md → *Research Agent*).
- It has **web search** and **read access to the repo**.
- It returns exactly this shape:

  ```json
  {
    "question": "<the question, verbatim>",
    "recommendation": "<a single clear recommendation>",
    "supporting_points": ["<point 1>", "<point 2>", "<point 3>"]
  }
  ```

Give each agent a prompt like:

> You are a stateless LCARS research agent. You have web search and read-only
> access to this repository. Answer ONLY this question — you have no other
> context, and that is intentional. Return a JSON object with keys `question`
> (verbatim), `recommendation` (one clear recommendation), and
> `supporting_points` (2–3 short strings). Output only the JSON.
>
> Question: «<question text>»

Collect each agent's JSON and write it to its own file in a temp dir, named in
question order so the saved order is stable — zero-pad them:

```bash
out=$(mktemp -d)
# write agent 1's JSON to $out/001.json, agent 2's to $out/002.json, …
```

### STEP 4 — Save the responses and advance

Hand the response dir to the script. It validates each response has
`question` / `recommendation` / `supporting_points`, copies them to
`research/<n>.json`, advances the stage to `validate`, and moves the GitHub
label from `lcars:align` to `lcars:validate` (the two stay in agreement):

```bash
bash ~/.claude/skills/lcars-run/run.sh save --mission <id> --responses "$out"
```

A malformed response stops the save without advancing — fix the agent output
and re-run. On success it prints:

```
SAVE: 2 responses
  Saved 2 research response(s) to research/.
  Stage:  validate
```

### STEP 5 — Report

Tell the captain how many questions ran, where the findings live
(`research/`), and that the mission is now ready for **Validate**:
`lcars run <id>` again will pick up the Validate stage.

## The Validate stage

Runs when `state.json.stage` is `validate` and `awaitingHuman` is not `true`
(see Dispatch). A single **Validator** session reviews every Research Agent's
finding *in the context of the PRD*, synthesises them into a plan, and decides
each open point. The Validator owns **implementation** decisions; it escalates
only **scope/direction** changes — things that change *what* gets built, not
*how* — to the human (see CONTEXT.md → *Validate*).

### STEP 1 — Read the PRD and every research finding

Read `.git/lcars/missions/<id>/prd.md` and **all** of
`.git/lcars/missions/<id>/research/*.json`. Unlike the stateless research
agents, the Validator gets the full context: the spec plus every finding. If a
`pending.json` exists with answers filled in (a resume after `lcars respond`),
read those answers too and treat them as settled.

### STEP 2 — Run the Validator: synthesise + surface scope questions

Produce two things:

1. **A synthesis** — a `validated-plan.md` that resolves the findings into a
   coherent implementation plan. It **must** have these sections (the script
   enforces them, mirroring how `lcars file` enforces the PRD's sections):

   ```markdown
   # Validated Plan: <mission title>

   ## Synthesis
   <prose: how the research findings combine into one plan, with conflicts
   resolved and the reasoning for each implementation decision you made>

   ## Decisions
   - <concrete implementation decision 1>
   - <concrete implementation decision 2>
   ```

2. **Scope-change questions** — zero or more. A point belongs here **only** if
   answering it changes *what* gets built (e.g. "global vs. per-course
   leaderboard — this changes the DB schema"). Anything you can decide as an
   implementation detail, decide it yourself in `## Decisions`; do **not**
   escalate it. Most missions raise **zero** scope questions.

### STEP 3 — Branch on scope questions

**If there are zero scope questions**, write your synthesis to a temp file and
advance straight to Plan:

```bash
bash ~/.claude/skills/lcars-run/run.sh validate-advance \
  --mission <id> --plan /tmp/validated-plan.md
```

This writes `validated-plan.md`, sets the stage to `plan`, and moves the label
`lcars:validate` → `lcars:plan`.

**If there are scope questions**, write one per line to a temp file and pause
at the human gate — do **not** write the plan yet:

```bash
qs=$(mktemp)
cat > "$qs" <<'Q'
Global or per-course leaderboard? (changes the DB schema)
Q
bash ~/.claude/skills/lcars-run/run.sh validate-pause --mission <id> --questions "$qs"
```

`validate-pause` writes the questions to `pending.json`, sets
`awaitingHuman: true` + `pendingQuestion` in `state.json` (so `lcars status`
shows the card as ❓ awaiting input), adds the `lcars:awaiting-human` label, and
keeps the card in the Validate column. Surface the printed questions to the
captain and tell them to answer with `lcars respond <id>`. **Then STOP** — do
not advance until the questions are answered.

### STEP 4 — Resume after the human answers

When the captain runs `lcars respond <id>` (a later build), it records their
answers into `pending.json` and clears `awaitingHuman`. The next `lcars run
<id>` falls through to Validate again: re-read the PRD, the findings, **and the
recorded answers**, fold the answers into your synthesis, and — assuming no new
scope question — call `validate-advance` as in STEP 3. That writes
`validated-plan.md`, clears the awaiting-human gate (state fields,
`pending.json`, the `lcars:awaiting-human` label), and advances to Plan.

### STEP 5 — Report

Tell the captain the Mission is synthesised, where the plan lives
(`validated-plan.md`), and that it is now at **Plan** — or, if you paused, what
you're waiting on and how to answer it.

## The Plan stage

Runs when `state.json.stage` is `plan`. A single **Planning** session decomposes
the validated plan into a list of small, independently-buildable tickets — the
unit each Implement pair will pick up later (see CONTEXT.md → *Plan*). You run
the Planner and emit `plan.json`; the script validates and installs it.

### STEP 1 — Read the PRD and the validated plan

Read `.git/lcars/missions/<id>/prd.md` (the canonical spec) and
`.git/lcars/missions/<id>/validated-plan.md` (the Validator's synthesis +
decisions). Together they are your full input — the *what* (PRD) and the agreed
*how* (validated plan).

### STEP 2 — Run the Planner: decompose into tickets

Produce a list of tickets. **Every ticket must be:**

- **A vertical slice** — UI + logic + data end-to-end, not one horizontal layer
  ("add all the migrations" is wrong; "add the XP trigger for video completions,
  through to the dashboard" is right).
- **Under 300 lines of production code** (tests excluded) — keep each ticket
  inside an implementer LLM's effective window. Put your estimate in
  `estimatedLoc`.
- **Independently testable** — at least one clear, observable acceptance
  criterion.
- **Titled in the imperative** — "Add XP trigger for video completions", not
  "XP trigger" or "Adds XP trigger".

Capture dependencies between tickets explicitly: if ticket B can only be built
after ticket A, list A's id in B's `dependencies`. A dependency may reference
**only** ids that exist in this same plan — the script rejects dangling refs.

### STEP 3 — Write plan.json and advance

Write the whole list to a temp file as a JSON array, in this **canonical
shape** — one field per line, with `acceptanceCriteria` and `dependencies` as
inline single-line arrays (the validator is line-oriented, like the rest of
`run.sh`):

```json
[
  {
    "id": "t-001",
    "title": "Add the data-theme attribute and dark token set",
    "description": "Flip data-theme on <html> and wire the dark --color-* tokens end-to-end.",
    "acceptanceCriteria": ["Setting data-theme=dark recolours the page"],
    "estimatedLoc": 120,
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle and persist the choice",
    "description": "Render a toggle that writes to localStorage and restores on load.",
    "acceptanceCriteria": ["Toggling persists across reload", "Defaults to prefers-color-scheme"],
    "estimatedLoc": 90,
    "dependencies": ["t-001"]
  }
]
```

Ticket ids are `t-001`, `t-002`, … in plan order. Then hand the file to the
script:

```bash
bash ~/.claude/skills/lcars-run/run.sh plan-save --mission <id> --plan /tmp/plan.json
```

`plan-save` validates the list — every ticket carries all six fields
(`id`, `title`, `description`, `acceptanceCriteria`, `estimatedLoc`,
`dependencies`), has **at least one** acceptance criterion, and every
dependency points to a real ticket id in the same plan — then writes
`plan.json`, sets the stage to `plan-review`, and moves the label
`lcars:plan` → `lcars:plan-review`. A malformed plan stops the advance with the
first failure named; fix it and re-run.

### STEP 4 — Report

Tell the captain how many tickets the plan holds, where it lives (`plan.json`),
and that the Mission is now at **Plan Review**.

## The Plan Review stage

Runs when `state.json.stage` is `plan-review` and `awaitingHuman` is not `true`
(see Dispatch). A **fresh reviewer** session audits the tickets against a fixed
quality bar — and the same LLM that planned the work must not also grade it, so
the reviewer is independent by design (see vision.md → *Plan Review*).

### STEP 1 — Run a FRESH reviewer over `plan.json` ONLY

Read `.git/lcars/missions/<id>/plan.json` and review it in a session that gets
**only** the tickets. **Do not read `prd.md` or `validated-plan.md`, and do not
carry over any planning context** — the reviewer judges the tickets on their own
terms. This independence is the whole point of the Stage; passing the spec in
would defeat it (the same way a Research agent must stay stateless).

Audit **every** ticket against the four criteria:

- **Vertical slice** — does it touch multiple layers end-to-end (UI + logic +
  data), not just one horizontal layer ("add all the migrations")?
- **Size** — is `estimatedLoc` under 300 lines of production code?
- **Testability** — is there at least one clear, observable acceptance
  criterion?
- **Dependencies** — does every id in `dependencies` reference another ticket
  **in this same plan**?

Produce a single verdict object:

```json
{
  "passed": false,
  "issues": [
    { "ticketId": "t-001", "objection": "Oversized: ~450 LoC; split it." },
    { "ticketId": "t-003", "objection": "Horizontal slice — only the data layer." }
  ]
}
```

`passed` is `true` only when **every** ticket clears all four criteria — then
`issues` is empty. Otherwise `passed` is `false` and `issues` names each
offending ticket with a specific, actionable objection. Keep it to the
**canonical one-issue-per-line shape** above (the script parses objections
line-oriented, like the rest of `run.sh`).

### STEP 2 — Hand the verdict to the script

Write the verdict to a temp file and pass it to the one subcommand. The script
branches on `passed`:

```bash
bash ~/.claude/skills/lcars-run/run.sh review-save --mission <id> --verdict /tmp/verdict.json
```

| `passed` | What the script does |
|---|---|
| `true` | Writes `approved-plan.json` (a copy of `plan.json`), sets the stage to `schedule`, and moves the label `lcars:plan-review` → `lcars:schedule`. The Mission is ready for **Schedule**. |
| `false` (rounds 1–2) | Logs the verdict to `plan-review-<round>.json`, increments `state.json.planReviewRound`, and loops the Mission back to `plan` (label `lcars:plan-review` → `lcars:plan`). Re-run `lcars run <id>` to **revise the tickets** against the objections, then Plan Review again. |
| `false` (round 3) | Logs `plan-review-3.json`, then **escalates**: writes the unresolved objections to `pending.json`, sets `awaitingHuman: true` + `pendingQuestion`, adds `lcars:awaiting-human`, and keeps the card in the Plan Review column. **Stop** — the captain decides. |

A failing verdict with an empty `issues` list is malformed — the script refuses
it and nothing moves; name the objections and re-run.

### STEP 3 — On a loop-back, revise then re-review

When the script loops the Mission back to `plan`, the next `lcars run <id>`
runs the **Plan stage** again. Read the latest `plan-review-<round>.json`
objections alongside the PRD and validated plan, revise `plan.json` to resolve
them, and `plan-save` advances back to `plan-review` — where the reviewer runs
fresh once more. `planReviewRound` persists across the loop, so the third
failure escalates rather than looping forever.

### STEP 4 — Report

If the plan passed, tell the captain it cleared review, where the approved plan
lives (`approved-plan.json`), and that the Mission is now at **Schedule**. If it
looped back, say which round it is and surface the objections so the Plan revise
has them. If it escalated, surface the unresolved objections and tell the
captain to override (proceed to Schedule) or redirect with `lcars respond <id>`.

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

### STEP 2 — Build each pending ticket (two sessions, in parallel across the wave)

For each pending ticket in the current wave, run the two phases **in order**.
Different tickets in the same wave are independent, so run their pairs
concurrently. Read the ticket's `title` / `description` / `acceptanceCriteria`
from `approved-plan.json` to brief each session.

#### PHASE 1 — Test Writer (a new session)

Spawn a session whose **only** job is to write failing tests for this one
ticket. Constraints (enforce them in the prompt):

- Write **only failing tests** — no implementation code.
- Test **behaviour through public interfaces only** — no internal mocks.
- Tests must be **immediately runnable**.

Give it read access to the repo and the ticket. Have it write its test files to
a temp dir, then quarantine them under the ticket:

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-save-tests \
  --mission <id> --ticket <ticket-id> --tests /tmp/tw-out
```

`impl-save-tests` copies the files into
`.git/lcars/missions/<id>/tickets/<ticket-id>/tests/` — **that dir is the only
channel to the Implementer**, which is what keeps the separation adversarial. An
**empty** Test Writer output is refused (Phase 1 must produce tests).

#### PHASE 2 — Implementer (a new session — NO Test Writer context)

Spawn a **fresh** session. It must **not** carry any of the Test Writer's
session — its sole handoff is the tests now on disk. Give it the ticket and
**read+write** access to the repo. Constraints:

- Implement **only** what makes the tests pass.
- **Do not modify the test files.**
- Run the tests; iterate until green, **at most 5 attempts**. If still red after
  the 5th, stop and report the failure (don't keep going).

When it finishes, write the result to a temp file in this shape and hand it over:

```json
{
  "ticketId": "t-001",
  "passed": true,
  "attempts": 3,
  "summary": "Wired data-theme end-to-end; suite green on attempt 3."
}
```

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-save-result \
  --mission <id> --ticket <ticket-id> --result /tmp/result.json
```

`impl-save-result` requires the ticket's tests to already exist (Phase 1 first),
validates the four fields, checks `ticketId` matches, and **caps `attempts` at
5**. It saves `tickets/<ticket-id>/result.json`. Then it branches on `passed`:

- **`passed: true`** → the ticket is green. The script **commits the
  Implementer's produced files to the Mission's branch** (the `branch` recorded
  in `state.json` by `lcars file`): on the first green ticket it checks that
  branch out — Implement is the first Stage to touch git, so the working tree
  the Implementer wrote into follows the checkout onto the branch — then
  `git add -A` + `git commit`. This is what gives the eventual PR its content;
  without it the Implementer's work would sit uncommitted on the base branch and
  `lcars approve` would have nothing to open a PR from. A missing branch / no
  changes / git failure is best-effort: the result is still saved and you get a
  warning to commit by hand.
- **`passed: false`** → the Implementer exhausted its 5 attempts. The script
  **flags the human**: it writes the blocker to `pending.json`, sets
  `awaitingHuman: true` + `pendingQuestion`, adds the `lcars:awaiting-human`
  label, and keeps the card in the Implement column. **Surface this to the
  captain and stop** — the ticket needs a human (`lcars respond <id>`); do not
  advance.

Only once **all** of the current wave's tickets are green do you loop back to
STEP 1, which will reveal the next wave.

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

- **No `feedback.md`** → a freshly filed Mission. Run **Research** as usual.
- **`feedback.md` present** → a re-entry from Verify. **Re-run Align, not
  Research first:** read `prd.md` *and* the full `feedback.md` (every stamped
  note, in order) plus any other artifacts you need, re-grill the same way
  `lcars file` did, and **rewrite `prd.md`** to fold in the captain's feedback.
  Once the PRD reflects the feedback, carry on into the **Research stage** in
  the same run (generate questions from the updated PRD, run the gate, …). Leave
  `feedback.md` in place as the durable history; it accumulates across rounds.

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
  validated-plan.md     ← the Validator's synthesis (Validate → Plan)
  plan.json             ← the Planner's ticket list (Plan → Plan Review)
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

- **Wrong stage for the Stage** → `run.sh` exits non-zero and changes nothing.
  Research only runs on an `align` mission; Validate only on a `validate` one;
  Plan only on a `plan` one; Plan Review only on a `plan-review` one; Schedule
  only on a `schedule` one; Implement only on an `implement` one.
- **No GitHub issue on file** (`githubIssue: null`) → the stage still advances;
  the relabel is skipped with a warning telling you to do it by hand.
- **`gh` missing / edit fails** → same: the local stage advances; you get a
  warning with the exact `gh` relabel to run later.
- **Research agents must stay stateless.** Never pass the PRD or sibling
  findings into a research agent — synthesis against the PRD is the Validator's
  job, in the Validate Stage.
- **Validate escalates scope, not implementation.** Only a finding that changes
  *what* gets built belongs in a scope question. Decide everything else
  yourself and record it in the plan's `## Decisions` — over-escalating turns
  the walk-away gate into a chat.
- **A paused Validate must not re-run on its own.** When `awaitingHuman` is
  `true`, do not call the Validator again — wait for `lcars respond`. The
  Validator only re-runs once the answer is recorded and the gate is cleared.
- **Malformed plan** (missing a required section) → `validate-advance` refuses
  and the Mission stays at `validate`; fix the synthesis and re-run.
- **Malformed ticket list** → `plan-save` refuses and the Mission stays at
  `plan` (no `plan.json` written) when any ticket is missing a required field,
  has zero acceptance criteria, or depends on a ticket id not in the plan. The
  error names the first failure; fix `plan.json` and re-run.
- **Every Plan ticket is a vertical slice under 300 LoC.** That sizing keeps
  each ticket inside an implementer LLM's window — don't emit horizontal,
  layer-only tickets or ones that blow past the limit.
- **The Plan Review reviewer must stay independent.** Never pass `prd.md`,
  `validated-plan.md`, or any planning context into the reviewer session — it
  judges `plan.json` alone, on its own terms. The same LLM that planned the
  work must not also grade it (vision.md → *Plan Review*); leaking the spec
  defeats the Stage, just as passing the PRD defeats a stateless Research agent.
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
  The Implementer's *only* handoff from the Test Writer is the tests on disk
  (`tickets/<id>/tests/`) — never the Test Writer's session. `impl-save-result`
  refuses a result for a ticket whose tests aren't saved yet, so Phase 1 always
  precedes Phase 2. Don't let the Implementer modify the test files, and don't
  pour implementation code into the Test Writer.
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

The mechanical logic lives in `run.sh` next to this file (subcommands `gate`,
`save`, `validate-pause`, `validate-advance`, `plan-save`, `review-save`,
`schedule`, `impl-save-tests`, `impl-save-result`, `impl-status`, `impl-advance`,
`verify-summary`) so it can be exercised directly. The Verify gate's two
outcomes are separate skills — `lcars-approve` and `lcars-feedback` — each with
its own script and test suite.
Its behaviour is covered by
`tests/lcars-run.test.sh` in the LCARS repo (run with `bash tests/run.sh`). The
skill source lives in `skills/lcars-run/` and is symlinked into
`~/.claude/skills/` by `./install.sh`; edit the repo copy, not `~/.claude`. If
you change `run.sh`, keep those tests green.
