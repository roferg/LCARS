# S179 — the undrawn-combination live rig

> A real holodeck design turn, driven headlessly over the daemon's HTTP API,
> with `claude` fenced off so the leg is copilot-only and free.

```bash
bash tests/drives/undrawn/live-drive.sh <label> tests/drives/undrawn/budget-brief.txt
# results land in the script's own runs/<label>/: concept.md, mockup.html,
# start.json, say.json, daemon.log, claude-attempts.log
```

It boots `python3 -m lcars_serve` on a free port against a throwaway git repo it
creates itself, POSTs `/api/holodeck/start` then `/api/holodeck/<sid>/say`, and
copies the room's `concept.md` + `mockup.html` out. `LCARS_DRIVE_REPO` points it
at a different checkout (a pristine worktree, to measure a baseline before a
change lands).

## Why it exists

S179 changed `_CONCEPT_CONTRACT` — prompt prose. Every fixture test around it can
assert only that the contract CONTAINS an instruction, never what a model does
with it. All four of this session's real findings were invisible to its 65-case
suite and visible only here:

* pristine HEAD drew all four cells of a 2x2 and **decided the awkward one by
  fiat**, filing it under `## Decisions` — the defect in its "silently decided"
  form, which the session's doc had predicted only in its "silently omitted" form;
* the changed contract flipped that: the cell was left undrawn and ASKED about,
  3/3 runs;
* the first wording **leaked the worked example's vocabulary** ("collection x
  shape (scalar/cohort)") onto a budget screen, 3/3 runs;
* the slot-template rewording cured it, 3/3, with no literal placeholders.

## The two briefs are not interchangeable

`explicit-axes-brief.txt` NAMES its two axes. The model then dutifully covers the
matrix and there is no gap to find — it is a weak probe, kept as the control.
`budget-brief.txt` is the real one: it asserts each axis in its own paragraph of
prose (one says the row is EDITED, the other says it is SHOWN) and never mentions
their intersection. That is the shape of the DX-Scorecard drawing this round was
built from, and it is what makes the gap appear naturally rather than on request.

Never instruct a design worker to leave a gap. That is teaching to the test, and
the resulting pass measures nothing.

## Reading the result

The declaration is SELF-DECLARED and must be checked against the drawing, not
believed. Two generic row-classifiers written during this session both returned
WRONG answers (one nearly reported a false "the model lied"); the mockups were
verified by hand instead. Three runs is small enough to read. If you write a
parser, calibrate it against a run you have already read.
