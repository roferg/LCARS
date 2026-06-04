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

## When the route is `inbox`

The router already delegated to `lcars answer list` and its output is shown.
Relay the inbox to the captain and help them clear a card — see the
`lcars-answer` skill for the actions (respond / approve / send-back).

## When the route is `drive`

The router delegated to `run.sh drive`, which auto-advances the Mission Stage to
Stage until a human gate, then stops and pings. Relay its summary and the reason
it stopped (a pending question, the Verify gate, an Align re-grill, or an error).
If it halted at an **Align re-grill** (a Mission sent back from Verify), run the
re-grill in your session per the `lcars-run` skill, then `lcars <id>` again.

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
