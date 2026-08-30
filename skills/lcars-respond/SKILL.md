---
name: lcars-respond
description: Answer an LCARS Mission's awaiting-human gate, walk-away style. When a stage escalates — Research over its 20-question cap, Validate on a scope change, Plan Review after three failed rounds, or Implement after a ticket's three worker sessions — it parks the Mission with `lcars:awaiting-human` and a pending question. `lcars respond` (no id) lists every Mission awaiting the captain and its question(s); `lcars respond <id>` shows that Mission's pending question(s), captures the captain's free-form answer, records it next to the question in answers.json, clears the awaiting-human gate (the stage is unchanged — the Mission stays at the stage that escalated), and removes the `lcars:awaiting-human` label so a plain `lcars run <id>` resumes that same stage and consumes the answer instead of re-asking. Use when the captain runs `lcars respond`, asks what's waiting on them / what needs an answer, or wants to answer a paused / escalated / blocked Mission.
---

# lcars respond

`lcars respond` is the **async human gate** (vision.md → "Respond to a pending
question"). Stages escalate to the captain — Research over its 20-question cap,
Validate on a scope change, Plan Review after three failed rounds, Implement
after a ticket's three worker sessions (the hire cap — a gate rejection bounces
the session and costs a hire). Each escalation parks the Mission behind an
**awaiting-human gate**: `awaitingHuman: true` in `state.json`, the question(s)
in `pending.json`, and the `lcars:awaiting-human` label on the issue. This skill
is how the captain answers that gate — and because the answer is persisted, the
captain can walk away and resume later rather than answering synchronously.

You (Claude) run the short conversation; the bundled `respond.sh` does the
mechanical persistence so it stays testable.

## No id — list what's waiting

When the captain runs `lcars respond` with **no mission id**, list every Mission
awaiting them and its pending question(s):

```bash
bash ~/.claude/skills/lcars-respond/respond.sh list
```

This mirrors how `lcars status` surfaces pending questions. If nothing is
awaiting a human, it says so and exits — tell the captain there's nothing to
answer.

## With an id — answer the gate

When the captain asks to answer a specific Mission's gate:

1. **Show the pending question(s).** Run `show` and read them to the captain:

   ```bash
   bash ~/.claude/skills/lcars-respond/respond.sh show --mission <id>
   ```

2. **Capture the answer.** Ask the captain for their answer in free form, the
   same one-question-at-a-time spirit as Align — lead with a recommendation when
   you have one, and let the question's framing guide you (a Research
   over-cap escalation offers `override` vs `return-to-align`; a Validate scope
   question wants a direction; a Plan Review escalation wants `override` or
   redirection; an Implement flag wants guidance on the stuck ticket). **Wait for
   the captain to answer — do not plow ahead.**

3. **Record it.** Pass the captain's answer verbatim to `answer`:

   ```bash
   bash ~/.claude/skills/lcars-respond/respond.sh \
     answer --mission <id> --answer "<the captain's answer, verbatim>"
   ```

`respond.sh answer`:

- **Appends the answer next to the question** in `answers.json` — an
  APPEND-ONLY ledger (`answers`: an ordered list, one entry per answer, each
  carrying its stage and the exact questions it answered), with the top-level
  `stage` / `answer` / `questions` slot mirroring the newest entry for the cheap
  readers. Nothing is ever overwritten: three successive answers to one question
  used to erase each other (S180).
- **Clears the awaiting-human gate** — drops `awaitingHuman` and
  `pendingQuestion` from `state.json`. **The stage is unchanged**: the Mission
  stays parked at the stage that escalated.
- **Removes the `lcars:awaiting-human` label** via `gh` (best-effort; `gh`
  tolerates removing a label that isn't applied, so it never pre-queries).
- **Resumes the Mission itself** — it runs `run.sh drive --mission <id>` as a
  child, so the stage that escalated re-enters immediately instead of waiting for
  a second command. The driver's exit code is deliberately NOT respond's: a
  non-zero `respond` means "your answer was not recorded" to every caller, and by
  then it is. A logged-bug child is exempt (its resume is the parent's
  `resolve-logs` batch, which it names instead). Set `LCARS_RESPOND_RESUME=0` to
  suppress the resume and just print the command — the viewscreen does, because
  it dispatches its own detached driver.
- **On a Plan Review gate, resets the round budget** (`planReviewRound` → 0) and
  counts the escalation (`planReviewEscalations`), capped at 3 — see the note in
  `respond.sh`.

## The resume contract

Answering **re-enters the same stage** on the spot, **consumes the persisted
answers** (it does not re-ask), and continues. `answers.json` is a LEDGER, not a
mailbox: every answer the captain has given on the Mission is in it, oldest
first, and where two answer the same question the LATER one stands. Two stage
boundaries still clear it (`validate-advance` and `impl-advance`) so a Mission
that has moved on does not carry an old gate's answer forward. When you resume a
stage and find an `answers.json`, **read every entry and fold the captain's
answers into that stage's work** before carrying on.

To resume by hand instead:

```bash
bash ~/.claude/skills/lcars-run/run.sh drive --mission <id>
```

## Guards & failure modes

- **Unknown mission id** → dies without touching anything.
- **Mission isn't awaiting a human** → refused; there is nothing to answer.
- **Empty answer** → refused; an answer must say something, and the gate is left
  intact.
- **`gh` missing / edit fails / local-only mission** → the local clear still
  happens; you get a warning to drop the label by hand.

## Report

Tell the captain their answer is recorded, that the gate is cleared (the Mission
is still at its escalated stage), and that the driver has been re-entered on it
(or, with `LCARS_RESPOND_RESUME=0`, the exact command that resumes it) — without
re-asking.

## Implementation

The logic lives in `respond.sh` next to this file; its behaviour is covered by
`tests/lcars-respond.test.sh` in the LCARS repo (run with `bash tests/run.sh`).
`LCARS_GH_BIN` and `LCARS_NOW` are taken via env so tests can stub them. Edit the
repo copy, not `~/.claude` — `./install.sh` symlinks it in.
