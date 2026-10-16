---
name: lcars-status
description: >-
  Show the LCARS command-and-control view — every active Mission in this
  repo as a table with its stage, GitHub issue, and any paused /
  awaiting-human status, plus the pending questions the captain still needs
  to answer. Use when the user runs `lcars status`, asks what missions are
  active / in flight, what's waiting on them, or wants the kanban / board
  view of LCARS missions.
---

# lcars status

`lcars status` is the text stand-in for the future **Kanban Board**: one glance
at every active Mission in this repo, the Stage each sits at, and any pending
human action. It is **read-only** — it scans `.git/lcars/missions/`, loads each
`state.json`, and renders a table. It writes nothing and changes no state.

Unlike the conversational skills, there's no Claude-driven half — the whole
thing is the bundled `status.sh`. Just run it and show the captain its output
verbatim:

```bash
bash ~/.claude/skills/lcars-status/status.sh
```

## What it prints

```
LCARS — Active Missions
───────────────────────────────────────────────────────────────
ID                    ISSUE  STAGE            TITLE
lcars-20260530-002    #43    research     ❓ Add dark mode
lcars-20260530-001    #42    implement    ⏸ Add gamification
lcars-20260530-003    -      align          Fix broken /about route
───────────────────────────────────────────────────────────────
⏸ paused    ❓ awaiting your input

Awaiting your input:
  lcars-20260530-002 (#43): Global or per-course leaderboard?

Respond with `lcars respond <id>`.
```

- **Missions are listed newest-first** (by the `created` stamp in `state.json`).
- The **status glyph** column flags a Mission that is `⏸` paused, `❓` awaiting
  a human answer, or both — mirroring the `lcars:paused` / `lcars:awaiting-human`
  labels.
- A recorded `done` Stage never shows a live pause glyph, even if a pending
  gate changes the displayed Stage. The pause legend appears only when a row
  actually shows `⏸`; recorded state is unchanged.
- Any Mission awaiting a human answer has its **pending question spelled out**
  below the table so the captain knows exactly what to respond to.
- A Mission with no GitHub issue yet shows `-` in the ISSUE column (so does
  a `githubIssue` of `0`: GitHub numbers issues from 1, so `0` is a missing
  issue, not a real one).
- **Issue body NOT updated.** The issue body is rebuilt from the mission dir at
  exactly two transfer points. If a part of it could not be BUILT there — an
  interrupted re-grill left a 0-byte `prd.md`; `estimate.json` went missing and
  there is no local record of the last pushed body to carry the `## Estimate`
  section (and its three board pills) forward — the refresh refuses the push
  rather than delete content off GitHub that nothing can put back. That refusal
  is footed here, naming the Mission, the part, and the fix:

  ```
  Issue body NOT updated (the mission ran; its GitHub issue is behind):
    lcars-20260530-001 (#42): could not build the "## Estimate" section — estimate.json is gone …
        → restore …/estimate.json (`lcars run lcars-20260530-001 --step` re-runs the estimator) …
  ```

  It **gates nothing** — the Mission ran and advanced normally; only its GitHub
  issue is behind, and the next transfer point heals it (and clears the line)
  once the source is back.
- **Issue body pushed with CARRIED-FORWARD parts.** The quieter half of the same
  story. When a part's source is gone but the composer's own record says what
  the issue already carries, the refresh reuses that part VERBATIM and pushes —
  nothing is lost and nothing is gated. But the captain should know that (say)
  his board pills are the ones last pushed rather than a fresh estimate, so
  every carried part is footed here with the act that changes it back:

  ```
  Issue body pushed with CARRIED-FORWARD parts (a source was missing, so the part the issue already carried was reused):
    lcars-20260530-001 (#42): Estimate carried forward; estimate.json is missing …
        → re-run the estimator (`lcars run lcars-20260530-001 --step`) to rebuild it from source
  ```

  A refresh that rebuilds every part from source clears the line, so this block
  always describes the issue as it stands right now.

## Live view — `--watch` / `--once`

Beyond the board snapshot, `status.sh` has a per-Mission **live event view** that
follows one Mission through Implement:

```bash
bash ~/.claude/skills/lcars-status/status.sh --watch [<id-or-partial>]
bash ~/.claude/skills/lcars-status/status.sh --once  [<id-or-partial>]
```

- **`--watch`** tails the Mission's `events.jsonl` and re-renders on a ~1s tick
  so the **pace line** stays live (`elapsed` keeps moving). Every field — including
  the `waves.json`-derived totals — is re-read each frame, so a `waves.json` that
  Schedule writes *after* the watch starts is picked up live (the denominator
  resolves the moment it appears). It stops cleanly at a terminal gate (a
  `verify`/`done` gate or an `error`), and on `q` / Ctrl-C. The ~1s throttle holds
  whether or not stdin is a terminal: with a real TTY it uses a timed key-read so
  `q` stays responsive; backgrounded / no-TTY it `sleep`s, so a redirected-to-a-log
  watch ticks once a second instead of busy-spinning. (SIGINT works from a
  foreground terminal; an `&`-backgrounded watch inherits SIGINT as ignored — the
  shell's doing — so tear those down with SIGTERM.)
- **`--once`** is the deterministic, non-follow sibling: it reads the current
  `events.jsonl` + `waves.json`, renders every event line, prints one final
  progress line, and exits. Handy for a quick "where is it now?" and used by the
  tests. `$LCARS_NOW` pins the clock for reproducible `elapsed`.

With no id, both modes resolve the **sole active Mission** via the shared
resolver (`skills/lcars/resolve.sh`); several candidates drop into its picker, and
an explicit id / partial is always honoured.

Each event renders to a concise human line (reusing the event's own `detail`),
followed by the **pace line**:

```
Wave <cur>/<total> · ticket <id> (<k>/<n>)[ · hire <a>][ · <b> bounces] · ~<avg>s avg/ticket · elapsed <Hh Mm Ss>
```

- `Wave cur/total` — current wave from the latest `wave_start`; total from
  `waves.json` (count of wave objects), falling back to the max `wave_start.totalWaves`
  seen when `waves.json` isn't on disk yet.
- `ticket <id> (k/n)` — current ticket from the latest `ticket_start`; `k` = green
  tickets so far, `n` = total tickets across all waves in `waves.json`, falling
  back to the sum of `wave_start.ticketCount` over distinct waves before
  `waves.json` exists (so the denominator degrades to a best-effort count, not `?`).
- `hire <a>` — the HIRE count for the current ticket: the NUMBER of
  `ticket_attempt` events recorded for it, ANY phase — how many times LCARS
  cold-spawned a worker for it (capped at 3). ONE derivation rule, shared with
  `run.sh`'s `ticket_hire_count`, the comment mirror's `cm_ticket_sessions` and
  the board's `sessionCount`; it is NOT the max `attempt` value, which
  under-counts a pre-S133 two-phase ticket and over-counts a gapped index. With
  no `ticket_attempt` on file the count is UNKNOWN and the field is OMITTED —
  never floored to a number nobody counted. NOT the worker's own internal
  iteration count, which is forensic and shown nowhere.
- `<b> bounces` — how many times a proof gate REJECTED a hire and LCARS
  re-spawned (`ticket_gate_bounce`). Present only when it is non-zero: silence
  means nothing went wrong.
- `~<avg>s avg/ticket` — mean of completed durations (`ticket_green.ts` minus its
  matching `ticket_start.ts`); shows an em-dash `—s` before any ticket is green.
- `elapsed` — `now` (or `$LCARS_NOW`) minus the first event's timestamp.

## Empty states

- **`.git/lcars/` doesn't exist** → `Not initialised. Run `lcars init`.`
- **`missions/` is empty** → `No active missions. Run `lcars file`.`

## What it reads

Each Mission's `state.json` under `.git/lcars/missions/<id>/`:

| field | used for |
|---|---|
| `id`, `title`, `stage` | the core table columns |
| `githubIssue` | the ISSUE column (`-` when `null` — or `0`, which is the absence of an issue written down, never issue number zero) |
| `created` | sort order (newest first) |
| `paused` | the `⏸` glyph (when `true`) |
| `pendingQuestion` | the `❓` glyph + the awaiting-input footer |

`paused` and `pendingQuestion` are optional — they appear once the
pause/respond flow writes them; a freshly filed Mission has neither and shows a
clean row. Subdirectories without a readable `state.json` are skipped silently.

## Implementation

The logic lives in `status.sh` next to this file so it can be exercised
directly. Its behaviour is covered by `tests/lcars-status.test.sh` in the LCARS
repo (run with `bash tests/run.sh`). The skill source lives in
`skills/lcars-status/` in the repo and is symlinked into `~/.claude/skills/` by
`./install.sh`; edit the repo copy, not `~/.claude`. If you change `status.sh`,
keep those tests green.
