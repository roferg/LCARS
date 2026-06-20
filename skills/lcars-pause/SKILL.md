---
name: lcars-pause
description: Pause or resume a running LCARS Mission at a safe boundary — user-initiated pause/resume (ADR-005, PRD §5.10). `lcars pause <id>` halts a Mission cleanly: it sets a `paused` flag in state.json and applies the `lcars:paused` label, so the driver stops advancing at the next safe boundary — between Stages, or between waves/tickets in Implement — and NEVER hard-kills a worker mid-step. The Mission stays put until resumed; `lcars status` shows it with the ⏸ paused glyph and the bare `lcars` driver will not auto-pick it. `lcars resume <id>` clears the flag, removes the `lcars:paused` label, and re-enters the driver from the recorded stage. Both verbs are idempotent (double-pause / double-resume safe; resuming a non-paused Mission is a clean no-op that still drives). Use when the captain runs `lcars pause <id>` / `lcars resume <id>`, asks to pause / hold / halt / stop a Mission for now, or to resume / un-pause / continue a paused Mission.
---

# lcars pause / resume

`lcars pause` is the **user-initiated pause** (ADR-005, PRD §5.10). It lets the
captain halt a running Mission cleanly without losing work — the driver stops at
the next **safe boundary** and the Mission waits, fully resumable, until the
captain runs `lcars resume`.

The bundled `pause.sh` does the mechanical persistence so it stays testable; you
(Claude) just announce the action and report.

## Pause

When the captain runs `lcars pause <id>`:

```bash
bash ~/.claude/skills/lcars-pause/pause.sh pause <id>
```

`pause.sh pause`:

- **Sets `paused: true` in state.json** (via the same `state_set_raw` field
  editor the driver uses). The stage is **unchanged** — the Mission keeps its
  place in the pipeline.
- **Applies the existing `lcars:paused` label** via `gh` (adds it; removes
  nothing — best-effort, never blocks the local flag).
- **Emits a `paused` event** to the Mission log (append-only; on the transition
  only, so a double-pause does not double-log).
- **Idempotent.** A double-pause re-applies the flag/label at most
  once-effectively (exactly one `paused: true` field; `gh` tolerates a label
  already applied).

The flag halts the driver at boundaries **only** — between Stages (the top of
`cmd_drive`'s loop) and between waves/tickets in Implement (the top of
`cmd_implement`'s loop). A worker already running its step is **never** killed
mid-flight; the Mission simply does not start the next Stage / wave / ticket.

## Resume

When the captain runs `lcars resume <id>`:

```bash
bash ~/.claude/skills/lcars-pause/pause.sh resume <id>
```

`pause.sh resume`:

- **Clears the `paused` flag** from state.json.
- **Removes the `lcars:paused` label** via `gh` (best-effort; `gh` tolerates
  removing a label that isn't applied).
- **Emits a `resumed` event** (on the transition only).
- **Re-enters the driver** from the recorded stage (`lcars run <id>` /
  `run.sh drive`), so the Mission picks up exactly where it stopped.
- **Idempotent.** Resuming a Mission that is not paused is a clean no-op that
  still drives.

## How the flag is honoured (no mid-step kill)

The guarantee lives in the driver, not here: `run.sh`'s `cmd_drive` and
`cmd_implement` re-read `paused` at the **top of their loops** — the only safe
boundaries — and stop cleanly with a `⏸ paused` readout before spawning the next
worker. So even if `lcars` / `lcars run` re-enters a paused Mission, it halts at
the boundary instead of advancing. The bare-`lcars` resolver also excludes paused
Missions from the drivable set, so it never keeps selecting one that won't move.

## Status reflection

A paused Mission shows in `lcars status` with the ⏸ paused glyph — driven by the
`paused: true` flag this skill sets in state.json (status.sh already renders it).

## Guards & failure modes

- **Unknown mission id** → dies without touching anything.
- **`gh` missing / edit fails / local-only mission** → the local flag change
  still happens; you get a note to adjust the label by hand.

## Report

After `pause`, tell the captain the Mission will stop at the next safe boundary
and resumes with `lcars resume <id>`. After `resume`, tell them the flag is
cleared and the Mission is driving again from its recorded stage.

## Implementation

The logic lives in `pause.sh` next to this file; its behaviour is covered by
`tests/lcars-pause.test.sh` in the LCARS repo (run with `bash tests/run.sh`).
`LCARS_GH_BIN` and `LCARS_RUN_SCRIPT` are taken via env so tests can stub them.
Edit the repo copy, not `~/.claude` — `./install.sh` symlinks it in.
