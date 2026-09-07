---
name: lcars
description: The one LCARS entry point — "do the right thing" from the current state. With nothing filed it takes a free-form idea and files a Mission (the Align flow); with work in flight and nothing pending it drives the active Mission forward (auto-advance); with a decision waiting it opens the inbox. A shared resolver picks the target Mission so the captain never juggles ids — one candidate needs none, several drop into a picker, an explicit id / partial / title always works. Use when the user runs `lcars` (no verb), says "what should I do next", "continue", "pick up where I left off", or otherwise hands LCARS work without naming a stage.
---

# lcars

`lcars` is the single thing the captain types. It adds **no** stage logic — it
is a dispatcher that reads Mission state, **announces** the action it inferred,
and delegates to a script already built. The captain learns two verbs (`lcars`
and `lcars answer`) plus a board (`lcars status`); they never have to remember
which stage they're in or paste a Mission id.

## How it routes

Run the bundled router. It prints a one-line announcement, an `ROUTE:` marker,
and then either delegates (drive / inbox) or hands the file flow back to you:

```bash
bash ~/.claude/skills/lcars/lcars.sh "$@"
```

It infers the route from state, in this precedence:

| State | Announcement | `ROUTE:` | What happens |
|---|---|---|---|
| A decision is pending (any Mission `awaitingHuman`, or parked at `verify`) | "N decision(s) waiting — opening the inbox." | `inbox` | delegates to `lcars answer` (the inbox list) |
| Work in flight, nothing pending | "Driving `<id>` from `<stage>`." | `drive <id>` | delegates to `run.sh drive --mission <id>` |
| Several drivable Missions, nothing pending | "Several missions in flight — pick one to drive:" | `picker` | lists candidates, exits 2 |
| Nothing filed | "No missions found — filing a new one." | `file` | **you** run the file flow (below) |

**Pending always wins over drivable** — if anything is waiting on the captain,
the router sends them to the inbox first. The announcement is printed *before*
any delegation, so the smart default never surprises the captain: relay it.

`lcars <selector>` (an id, a partial id, or a title substring) skips inference
and drives that Mission straight away — the power path for "continue this one".

## The shared resolver — no id juggling

`lcars.sh` (and `lcars answer`) pick the target Mission through `resolve.sh`:

- **one candidate** → resolved, no id needed;
- **several** → it prints a candidate table (`id`, title, stage, note) and exits
  `2` — surface those to the captain as a **fuzzy picker** (offer the titles +
  stages, let them choose, then re-run `lcars <id>` with their pick);
- an **explicit id / partial-id / title** is always honoured.

Never demand a full id on the common path, and never silently guess when it's
ambiguous — fall into the picker.

## When the route is `file` — run the Align flow

The router can't run Align: it's a human grilling session, not automatable. When
you see `ROUTE: file`, run the **`lcars file` flow** in your session — capture
the free-form idea, grill to a PRD, then persist via `file.sh` (see the
`lcars-file` skill for the full procedure). After it's filed, a plain `lcars`
auto-advances it.

## When the route is `vision` — run the Establish Vision flow (S184)

This repo has **no test foundation** and nothing on its board. The router has
already printed the front door and the **foundation brief** — read them; they
are the same screens and the same brief the viewscreen shows, and the brief is
the contract you are running under.

Do NOT tell the captain the repo is unusable and do NOT run `lcars file` — a
normal mission is refused here (exit 4), correctly. Instead:

1. **Grill him with the existing Align procedure** (the `lcars-file` skill's
   grilling guidance), pointed at a **PROJECT** rather than a feature. On a
   `greenfield` repo, start from what he wants to build. On an `untested` repo
   **do not ask what he is building** — LCARS can see the code; ask only what it
   cannot see (which runner suits this codebase, what one existing behaviour a
   first test should pin).
2. **Hold the scope fence.** The mission you are producing builds a running
   skeleton, a working test system, and ONE thin vertical slice that proves
   both. Every feature he names is **recorded and deferred**, never planned. A
   vision that specifies twelve features has failed.
3. **Recommend, don't decide.** End with ONE concrete stack ("Vite + React +
   Vitest") and 2–4 reasons in HIS language about HIS idea. Say plainly that he
   can override it, and if he does, **his choice is what gets filed**.
4. **File it through the one machinery** — never assemble a PRD yourself:

```bash
bash ~/.claude/skills/lcars-init/establish-vision.sh --file \
  --idea    <file with his idea, verbatim> \
  --stack   '<the stack he ACCEPTED>' \
  --reasons <file, one reason per line> \
  --deferred <file, one deferred feature per line> \
  --slice   '<the one thin vertical slice>' \
  [--engine claude|copilot]
```

`--engine` is OPTIONAL and is the captain's choice of the CLI that drives the
mission — the viewscreen's front door offers it as a picker before the grill
starts. On the CLI you are already running inside the engine he chose, so pass
it only if he NAMES one; omit it and the mission is filed exactly as before.
What it does when present: it pins the mission's `state.json.workerBin` AND
records that engine as the repo's default in `.git/lcars/config.json`, so later
missions inherit it.

That writes the durable project vision to `.git/lcars/vision.md`, assembles the
foundation-scoped PRD, and files the **initialization mission** through
`lcars file --initialization`. Read back the mission id it prints and tell him
`lcars run <id>` takes it from here.

## When the route is `inbox`

The router already delegated to `lcars answer list` and its output is shown.
Relay the inbox to the captain and help them clear a card — see the
`lcars-answer` skill for the actions (respond / approve / send-back).

## When the route is `drive`

The router resolved a drivable Mission. Don't call `run.sh drive` as a single
blocking step — that shows the captain **nothing** until the whole pipeline
returns, forcing them into a second window to watch. Drive it with the same
**portable, CLI-agnostic** mechanism the `lcars-run` skill prescribes: a
**foreground per-Stage loop**. Two naive shapes both break — one blocking `drive`
can exceed a host's per-call time cap and get killed mid-Stage, and backgrounding
(`&`) + piping (`| tee`) is **denied under headless GitHub Copilot CLI** even with
`--allow-all-tools`, so a route that mandates `&` reliably fails there. So the
**required** way is to drive **one Stage at a time in the foreground** with
`--step`, relay each Stage's output, and **loop until the driver reports a halt**.
No `&`, no `| tee`, no pipe — every call is a plain foreground invocation:

```bash
# Loop, one foreground Stage per pass, until the driver reports a halt.
bash ~/.claude/skills/lcars-run/run.sh drive --mission <id> --step
```

Each pass:

1. **Run exactly one foreground `--step`** and **relay what it printed** — the
   per-Stage line and its `⊘ isolated … via <cli>` marker — so the session reads
   as a Stage-by-Stage ticker, not a wall of repeats.
2. **Read the printed halt line** the driver returns after the Stage: either
   `⏹ stepped one Stage → now at: <stage>` (keep looping) **or** a terminal halt.
3. **If it stepped to a new non-terminal stage, loop** — run the next foreground
   `--step`. **If it reported a halt** (a pending question / awaiting-human gate,
   the Verify gate, an `align` feedback re-entry, `done`, or `⚠ NOT ISOLATED` /
   error), **stop the loop**, print the driver's **final summary byte-for-byte**,
   and **fire/echo the notification exactly as today** at the two human gates.

The dispatcher does **no** Stage reasoning — it sequences the foreground `--step`
calls and relays output. The end-of-run summary and the
`⊘ isolated … via <cli>` / `⚠ NOT ISOLATED` markers are the driver's, relayed
**byte-for-byte** — the loop changes only *when* progress is shown, never its
shape.

> **Optional, job-control-only:** in a shell that *permits* backgrounding (e.g.
> an interactive Claude Code session — **never** headless Copilot, which denies
> `&`/pipes), you may instead run `drive` (no `--step`) **detached** —
> `bash …/run.sh drive --mission <id> > <logfile> 2>&1 &` — and relay a periodic
> digest while it runs, rendering each pass every `${LCARS_WATCH_INTERVAL:-60}`
> seconds with `bash ~/.claude/skills/lcars-status/status.sh --once <id>` (the
> deterministic snapshot, which reads `events.jsonl` directly, **never** through
> the worker). This is a convenience for shells with job control only — **not**
> the default path.

`run.sh drive` auto-advances the Mission Stage to Stage until a human gate, then
stops and pings. Relay its summary and the reason it stopped (a pending question,
the Verify gate, an Align re-grill, or an error). If it halted at an **Align
re-grill** (a Mission sent back from Verify), run the re-grill in your session per
the `lcars-run` skill, then `lcars <id>` again.

## The old verbs still work

`lcars file` / `lcars run` / `lcars respond` / `lcars approve` / `lcars feedback`
remain as power entry points so nothing breaks and scripts that call them are
fine. But the **documented surface** is just `lcars` + `lcars answer` +
`lcars status` + `lcars init` + `lcars log`. Reuse the existing scripts — this
skill never reimplements their logic.

## Implementation

The logic lives in `lcars.sh` and the shared `resolve.sh` next to this file, both
covered by `tests/lcars.test.sh` (run with `bash tests/run.sh`). Dependencies are
env-injectable so tests stub them: `LCARS_RUN_SCRIPT`, `LCARS_ANSWER_SCRIPT`,
`LCARS_RESOLVE_SCRIPT`. The skill source lives in `skills/lcars/` and is symlinked
into `~/.claude/skills/` by `./install.sh`; edit the repo copy, not `~/.claude`.
If you change either script, keep those tests green.
