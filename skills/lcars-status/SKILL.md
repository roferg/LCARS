---
name: lcars-status
description: Show the LCARS command-and-control view — every active Mission in this repo as a table with its stage, GitHub issue, and any paused / awaiting-human status, plus the pending questions the captain still needs to answer. Use when the user runs `lcars status`, asks what missions are active / in flight, what's waiting on them, or wants the kanban / board view of LCARS missions.
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
- Any Mission awaiting a human answer has its **pending question spelled out**
  below the table so the captain knows exactly what to respond to.
- A Mission with no GitHub issue yet shows `-` in the ISSUE column.

## Empty states

- **`.git/lcars/` doesn't exist** → `Not initialised. Run `lcars init`.`
- **`missions/` is empty** → `No active missions. Run `lcars file`.`

## What it reads

Each Mission's `state.json` under `.git/lcars/missions/<id>/`:

| field | used for |
|---|---|
| `id`, `title`, `stage` | the core table columns |
| `githubIssue` | the ISSUE column (`-` when `null`) |
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
