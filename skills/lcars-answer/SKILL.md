---
name: lcars-answer
description: >-
  The LCARS inbox — every pending decision across ALL Missions in one list,
  and one place to clear each. Surfaces scope escalations, plan-review
  stand-offs, blocked tickets, and the Verify ship/send-back gate; each card
  shows the Mission, the question, and its actions. It absorbs `lcars
  respond` (answer an escalation), `lcars approve` (ship a Verify card), and
  `lcars feedback` (send one back) as card actions, delegating to the
  scripts already built. Use when the user runs `lcars answer`, asks what
  needs an answer / what's waiting on them, or wants to approve, send back,
  or respond to a Mission without juggling ids.
---

# lcars answer

`lcars answer` is the inbox: the union of "what needs me" across every Mission,
collected into one list to clear rather than scattered across Missions. It adds
**no** stage logic — it lists pending decisions and delegates each action to a
script already built.

Two kinds of card show up:

- **Escalation** (`awaitingHuman`) — Research over its 20-question cap, a Validate
  scope change, a Plan-Review stand-off, or a blocked Implement ticket. Cleared
  by recording a free-form answer (→ `respond.sh`).
- **Verify gate** (`stage: verify`) — a finished Mission awaiting review. Cleared
  by **approving** (→ `approve.sh`, merges its open PR) or **sending back** with
  a note (→ `feedback.sh`, returns it to Align). Without a recorded PR, approval
  is listed as unavailable; for an ordinary Mission, run `lcars run <id>` so
  Verify opens the PR first. A logged-bug child (`parentMission` set) intentionally
  has no PR of its own: it ships via its parent. Run `lcars resolve-logs <parent>`
  for the consolidated parent review instead.
  Ordinary Verify review does not set the red escalation flag.

## Show the inbox

```bash
bash ~/.claude/skills/lcars-answer/answer.sh list      # `list` is the default
```

Each card prints the Mission id, its GitHub issue, the stage it's stuck in, the
question or review, and the exact action(s). Relay it to the captain. An empty
inbox says so — nothing is waiting on them.

## Clear a card

Each action is a subcommand. `--mission` is **optional**: with exactly one
pending decision the shared resolver picks it; a partial id / title also
resolves; several → it prints a picker (pass `--mission <id>` to choose).

```bash
# Answer an escalation (delegates to respond.sh — records the answer, clears the gate)
bash ~/.claude/skills/lcars-answer/answer.sh respond  --mission <id> --answer "<text>"

# Ship a Verify card (delegates to approve.sh — merges its open PR, marks Done)
bash ~/.claude/skills/lcars-answer/answer.sh approve  --mission <id>

# Send a Verify card back (delegates to feedback.sh — back to Align with a note)
bash ~/.claude/skills/lcars-answer/answer.sh send-back --mission <id> --feedback "<text>"
```

For an escalation, capture the captain's reply in their own words and pass it as
`--answer`. After `respond`, a plain `lcars` (or `lcars run <id>`) resumes the
same Stage and consumes the answer instead of re-asking. For a Verify card, lead
with what you'd do, then approve or send back per the captain's call.

## Notes

- The actions are exactly `lcars respond` / `lcars approve` / `lcars feedback`
  under the hood — this skill is the single front door that absorbs them so the
  captain doesn't pick a verb per Mission. The old verbs still work directly.
- The resolver is shared with `lcars` (see the `lcars` skill) — one candidate
  needs no id, several drop into a picker, an explicit id always works.

## Implementation

The logic lives in `answer.sh` next to this file, covered by
`tests/lcars-answer.test.sh` (run with `bash tests/lcars-answer.test.sh`). Dependencies are
env-injectable so tests stub them: `LCARS_RESPOND_SCRIPT`, `LCARS_APPROVE_SCRIPT`,
`LCARS_FEEDBACK_SCRIPT`, `LCARS_RESOLVE_SCRIPT`. The skill source lives in
`skills/lcars-answer/` and is symlinked into `~/.claude/skills/` by
`./install.sh`; edit the repo copy, not `~/.claude`. Keep the tests green.
