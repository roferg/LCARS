---
name: lcars-run
description: Advance an LCARS Mission one Stage. This build runs the Research and Validate stages — Research reads the PRD, generates 0–20 questions, dispatches stateless research subagents, and saves their findings; Validate synthesises those findings against the PRD into a validated plan, escalating scope changes to the human. Use when the user runs `lcars run <mission-id>`, asks to advance / progress / continue a mission, or to run the Research or Validate stage on a filed mission.
---

# lcars run

`lcars run <mission-id>` advances a Mission through the LCARS pipeline **one
Stage at a time**. You (Claude) drive the LLM work; the bundled `run.sh` does
the mechanical, testable persistence so it stays under test.

**This build implements the Research and Validate stages.** A Mission filed by
`lcars file` sits at stage `align` (the Align grilling already happened during
`lcars file`), so the next Stage to execute is **Research**; when Research
finishes the Mission parks at `validate`, ready for the **Validate** stage.
Later Stages (Plan, …) are added in subsequent builds.

## Dispatch on the current stage

1. Read `.git/lcars/missions/<id>/state.json`. If the mission dir or
   `state.json` is missing, tell the captain the id is wrong / the mission
   isn't filed, and stop.
2. Look at `state.json.stage`:
   - `align` → run the **Research stage** (below).
   - `validate` → run the **Validate stage** (below). But first check
     `awaitingHuman`: if it is `true`, the Mission is parked at a human gate —
     a scope question is unanswered. **Do not re-run the Validator.** Tell the
     captain the Mission is waiting on them (`lcars respond <id>`) and stop.
     (Once `lcars respond` records the answer it clears `awaitingHuman`, so the
     next `lcars run` falls through and resumes Validate with the answer in
     hand.)
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

GitHub labels are the board's source of truth; `.git/lcars/` is the run-time
store. Keeping them in lockstep is what lets you call `lcars run` repeatedly and
trust the board to show exactly where every Mission is.

## What gets written

```
.git/lcars/missions/<id>/
  research/
    1.json, 2.json, …   ← one stateless agent's findings per file (Research)
  validated-plan.md     ← the Validator's synthesis (Validate → Plan)
  pending.json          ← scope questions, while paused at the human gate only
  state.json            ← stage pointer; + awaitingHuman/pendingQuestion while paused
```

Nothing else in the working tree changes; all state stays inside `.git/`.

## Notes & failure modes

- **Wrong stage for the Stage** → `run.sh` exits non-zero and changes nothing.
  Research only runs on an `align` mission; Validate only on a `validate` one.
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

## Implementation

The mechanical logic lives in `run.sh` next to this file (subcommands `gate`,
`save`, `validate-pause`, `validate-advance`) so it can be exercised directly.
Its behaviour is covered by
`tests/lcars-run.test.sh` in the LCARS repo (run with `bash tests/run.sh`). The
skill source lives in `skills/lcars-run/` and is symlinked into
`~/.claude/skills/` by `./install.sh`; edit the repo copy, not `~/.claude`. If
you change `run.sh`, keep those tests green.
