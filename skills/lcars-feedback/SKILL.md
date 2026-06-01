---
name: lcars-feedback
description: Send an LCARS Mission back to Align with the captain's feedback — the Verify feedback loop. Appends the note to the Mission's feedback.md (a durable, accumulating history), resets the stage to `align`, and moves the GitHub label to `lcars:align`, while deleting none of the prior artifacts (PRD, research, validated/approved plans) so the next `lcars run` re-enters Align with the full history. Use when the captain runs `lcars feedback <mission-id> "<feedback>"`, or asks to send a Mission back / reject it with changes / re-align it after reviewing it in Verify.
---

# lcars feedback

`lcars feedback <mission-id> "<feedback>"` is the captain's "send it back" at
**Verify** (vision.md → Verify can approve or send feedback that re-enters the
loop). It is purely mechanical — no LLM — so you just run the one script and
report.

## What it does

Map the captain's free-form note to the `--feedback` flag:

```bash
bash ~/.claude/skills/lcars-feedback/feedback.sh \
  --mission <id> --feedback "<the captain's feedback, verbatim>"
```

`feedback.sh`:

1. **Appends the note to `feedback.md`** — a growing, stamped history, never
   overwritten, so a Mission bounced back more than once keeps every note in
   order.
2. **Resets the stage to `align`** in `state.json`.
3. **Moves the GitHub label to `lcars:align`** — removes whatever stage label
   the card carried (and any `lcars:awaiting-human` overlay) and adds
   `lcars:align`, so the card returns to the Align column.

It **deletes nothing**: the PRD, research findings, and validated/approved plans
all stay on disk.

## Re-entering Align with the full history

When the next `lcars run <id>` finds the Mission at `align` **with a
`feedback.md` present**, that is the signal to **re-enter Align** (not jump
straight to Research): re-grill against the existing `prd.md` *and* the
accumulated `feedback.md`, fold the captain's notes in, rewrite `prd.md`, and
only then carry on to Research. The whole point of keeping the prior artifacts
is that Align resumes with the full context rather than starting cold. (See the
`lcars-run` skill's dispatch for how `align` + `feedback.md` routes back to
Align.)

## Guards & failure modes

- **Empty feedback is refused** — a send-back must say what to fix; nothing
  changes if `--feedback` is blank.
- **Unknown mission id** → the script dies without touching anything.
- **`gh` missing / edit fails / local-only mission** → the local stage reset
  still happens; you get a warning to relabel the issue by hand.

## Report

Tell the captain the note is recorded, that the Mission is back at **Align**
with its full history intact, and that `lcars run <id>` will re-enter Align.

## Implementation

The logic lives in `feedback.sh` next to this file; its behaviour is covered by
`tests/lcars-feedback.test.sh` in the LCARS repo (run with `bash tests/run.sh`).
`LCARS_GH_BIN` and `LCARS_NOW` are taken via env so tests can stub them. Edit
the repo copy, not `~/.claude` — `./install.sh` symlinks it in.
