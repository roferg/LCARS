# S220 parts E/F/G — the walk, measured on the real build

These files are the RECORD of one live look at DX-Scorecard PR #206 at
`672825b` (the real benchmark arm), taken 2026-09-19 with parts E, F and G in
place. They are the round-0 evidence: what the harness itself measured before
the worker said anything.

- `journey.json` — the flow, declared from the record (the drawing's screen
  order, the PRD's own steps, the fields and gates the screens carry).
- `walk.json` — what actually happened: **7 clicks, 2 typings, 0 address
  jumps**, five screens, every declared step taken, including `Preview` and
  `Back to builder` on a screen the drawing never drew.
- `observations.json` — the layout pass on every screen it stood on, plus the
  two measurements a pair of pictures cannot take: four controls holding an
  icon bigger than themselves (**Pull data & start, Continue to builder, Lock
  month, Back to builder**) and **"August 2026 became September 2026 after I
  clicked Pull data & start"**.
- `scan.json`, `carry.json` — those two measurements on their own.
- `seed.json` — nothing declared, said plainly, nothing invented.

The worker rounds of that look had not finished when this was written, so
`real.score.json` for this arm is not here yet; the look was running in
`$TMPDIR/s220-bench-c`.

## The scored looks (real arm, DX-Scorecard @ 672825b)

| look | recall | false alarms | grade | how it moved |
|---|---|---|---|---|
| baseline (before S220) | 0/5 | 0 | — | teleport |
| after B/C/D | 3/5 | 0 | medium | 0 clicks, 3 address jumps |
| **A** — E/F/G, walk could not find the way in | **4/5** (r4 found, r5 missed) | 0 | low | 6 clicks, 1 keypress, 1 address jump |
| **B** — same code as A | **3/5** | 0 | medium | 2 clicks, 0 jumps |
| **C** — E/F/G with the entry fix | *pending* | | | 7 clicks, 2 typings, **0** address jumps, 5 screens |

A and B were started before the walk could find its way into the flow (the app's
front door is a scorecard; the drawn flow is behind an "MBR builder" button), so
their declared journeys came back all-unreachable and the carry check never ran
— which is exactly why `r5` is missed in both. `r4` in look A was found by the
new per-screen icon measurement, on a preview screen the model reached itself.
C is the arm where the harness walked the whole flow; its round-0 record above
already carries all five faults.
