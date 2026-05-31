---
name: lcars-run
description: Advance an LCARS Mission one Stage. This build runs the Research stage — reads the Mission's PRD, generates 0–20 research questions, dispatches one stateless research subagent per question, saves their findings, and moves the Mission on toward Validate. Use when the user runs `lcars run <mission-id>`, asks to advance / progress / continue a mission, or to run the Research stage on a filed mission.
---

# lcars run

`lcars run <mission-id>` advances a Mission through the LCARS pipeline **one
Stage at a time**. You (Claude) drive the LLM work; the bundled `run.sh` does
the mechanical, testable persistence so it stays under test.

**This build implements the Research stage only.** A Mission filed by
`lcars file` sits at stage `align` (the Align grilling already happened during
`lcars file`), so the next Stage to execute is **Research**. Later Stages
(Validate, Plan, …) are added in subsequent builds.

## Dispatch on the current stage

1. Read `.git/lcars/missions/<id>/state.json`. If the mission dir or
   `state.json` is missing, tell the captain the id is wrong / the mission
   isn't filed, and stop.
2. Look at `state.json.stage`:
   - `align` → run the **Research stage** (below).
   - anything else → not implemented in this build; report the current stage
     and stop. (`run.sh` also refuses to run Research on a non-align mission.)

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
| `GATE: skip` | 0 questions. The script has **already** advanced the mission (stage → `validate`, label → `lcars:research`). | Report it to the captain. **Done.** |
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
`research/<n>.json`, advances the stage pointer to `validate`, and moves the
GitHub label from `lcars:align` to `lcars:research`:

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
`lcars run <id>` again will pick up the Validate stage (next build).

## Stage pointer vs. GitHub label — the intentional one-stage lag

After Research, `state.json.stage` becomes **`validate`** but the GitHub label
becomes **`lcars:research`**. This is not a bug:

- **`state.json.stage`** points at the **next** Stage `lcars run` will execute.
  Research is done, so the next run does Validate → `validate`.
- **The GitHub label** marks the **column the card sits in** — the Stage just
  processed. Research just ran, so the card is in the Research column →
  `lcars:research`.

The Validate build will move both forward together (label `research` →
`validate`, stage → `plan`). GitHub labels are the board's source of truth;
`.git/lcars/` is the run-time store.

## What gets written

```
.git/lcars/missions/<id>/
  research/
    1.json, 2.json, …   ← one stateless agent's findings per file
  state.json            ← stage flipped to "validate"
```

Nothing else in the working tree changes; all state stays inside `.git/`.

## Notes & failure modes

- **Not an align-stage mission** → `run.sh` exits non-zero and changes nothing.
  Research only runs once, on a freshly-aligned mission.
- **No GitHub issue on file** (`githubIssue: null`) → the stage still advances;
  the relabel is skipped with a warning telling you to do it by hand.
- **`gh` missing / edit fails** → same: the local stage advances; you get a
  warning with the exact `gh` relabel to run later.
- **Agents must stay stateless.** Never pass the PRD or sibling findings into a
  research agent — synthesis against the PRD is the Validator's job, in the
  next Stage.

## Implementation

The mechanical logic lives in `run.sh` next to this file (subcommands `gate`
and `save`) so it can be exercised directly. Its behaviour is covered by
`tests/lcars-run.test.sh` in the LCARS repo (run with `bash tests/run.sh`). The
skill source lives in `skills/lcars-run/` and is symlinked into
`~/.claude/skills/` by `./install.sh`; edit the repo copy, not `~/.claude`. If
you change `run.sh`, keep those tests green.
