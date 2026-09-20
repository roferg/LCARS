# S220 · the baseline — what Number One's LOOK finds on today's code

Recorded 2026-09-19 on `feat/number-one` at **`d37979f`**, before any part of
Session 220 changed anything. These are the numbers the rest of S220 has to
move. Read `README.md` first for the rule they are scored by, and
`selftest.sh` for the proof that the rule can report a 5 as well as a 0.

Everything below is what actually happened. The planted arm did **not** produce
the number the plan expected, and it says so.

---

## The numbers

**Re-stated 2026-09-20 in the provenance shape (fix round 1, D1).** Recall is
now three numbers, not one: what the MODEL'S OWN EYE found, what the
DETERMINISTIC DETECTORS found, and the union. The single number these runs were
first recorded with could not tell the two apart, and a look whose model said
nothing at all could still score full marks on the detectors' work. Nothing was
re-looked to produce this table — the same recorded verdicts were re-scored.

| arm | model's eye | detectors | union | false alarms | grade | the look said | how it moved |
|---|---|---|---|---|---|---|---|
| **planted** (live, this session) | **5 / 5** | 0 / 5 | **5 / 5** | **0 / 2** | low, **earned** | 6 didn't-work, 0 couldn't-check | 3 clicks, 1 typing, **0 address jumps** |
| **real** (live, this session) | **0 / 5** | **0 / 5** | **0 / 5** | 0 / 1 | **medium**, not earned | **0 didn't-work, 72 met**, 7 couldn't-check | 2 clicks, 0 typings, 0 address jumps |
| real (reference: the S219 look) | 0 / 5 | 0 / 5 | 0 / 5 | 0 / 1 | low, not earned | 0 didn't-work, 39 couldn't-check | 3 clicks, 0 typings, 4 address jumps past the front door |

At the baseline the two columns say the same thing, because there were no
part-B/F detectors yet: everything the look found on the planted arm, it found
with its own eye, and on the real arm neither eye found anything. The columns
start to diverge in `AFTER-EFG.md`, which is the point of keeping them apart.

Both live looks ran at `d37979f` on 2026-09-19 evening: planted 18:32–18:43
(665s), real 18:31–18:49 (~18 min), both LIVE Copilot, both caged, neither
capped out.

`gradeEarned` is the honest half of the grade column. A grade that is low
enough is not the same as a grade the build earned: on both real runs the grade
was inside the cap and not one of the five declared faults had anything to do
with why — one was low because the look could not see, the other was medium in
spite of seeing.

Raw evidence, each the look's own `xo/` directory (verdict, criteria,
observations, action lists, per-shot readouts):

    baseline-run/planted/                 + planted.score.json, planted.look.log
    baseline-run/real/                    + real.score.json, real.look.log
    baseline-run/reference-s219-real/     + reference-s219-real.json

No PNGs and no >80KB DOM dumps — `.gitignore` covers `tests/drives/**/*.png`
repo-wide, and the dumps regenerate on a rerun.

---

## The headline, and it is not the one the plan predicted

**S220's premise — "the benchmark must FAIL on today's code" — holds on the
real case and fails completely on the planted one.**

On the planted fixture today's code found **every single planted fault**, in
its own words, with measurements, and flagged **neither** correct control. It
also clicked its way onto the second screen, typed, and caught the lock gate
publishing an empty note. That is not a blind look. That is a very good one.

Both arms ran the same shipped `lcars xo evaluate`, on the same engine, at the
same commit. What differs is the size of the thing being looked at:

| | planted | real |
|---|---|---|
| criteria in the contract | 9 (9 primary) | 79 (21 primary) |
| screens | 2 | 6+ |
| drawn parts with an id | 9 of 9 built | 12 named, **0 matching ids in the build** |
| result | 5/5, 0 couldn't-check | 0/5, 72 graded "worked" |

So the question S220 is really answering is **not** "can the look see a wrapped
label" — it demonstrably can — but "why does it stop seeing one when the
contract is 79 items long, the drawing's ids match nothing, and it has to walk
six screens to get there". Parts B–G should be read, and measured, against
that. A later agent who builds part B and finds the planted arm still at 5/5
has learned nothing; the real arm is where the movement has to show.

---

## The real case — DX-Scorecard PR #206 at `672825b`

**0 of 5 known faults found. 0 of 1 correct controls flagged. Graded MEDIUM.**

This is the fresh live look, and it is the worse of the two real-case runs. Its
own ledger: **72 met, 0 gap, 7 untested**. Its worker wanted to grade the build
HIGH; the ledger pulled it to MEDIUM, and its one-line meaning to the captain
reads:

> *"The point of the mission works; it would ship with 1 item I could not check"*

It looked straight at the broken controls and wrote them up as correct —
`prd-3`: *"a Preview toolbar button and an amber 'Lock month' primary with a
lock glyph"* — the glyph in question being 34px in a 32px button with the label
on two lines.

Worse than "it missed them": it graded every criterion covering those four
buttons **"worked"**, in shots it took itself, with the oversized icons in
frame. Each fault was measured in a browser before being declared
(`known-answers/real.json` carries the numbers):

| | part | measured | the look said |
|---|---|---|---|
| r1 | Pull data & start | 55px icon in a 38px control, label on 3 lines | worked |
| r2 | Continue to builder | 61px icon in a 32px control, label on 3 lines | worked |
| r3 | Lock month | 34px icon in a 32px control, label on 2 lines | worked |
| r4 | Back to builder | 41px icon in a 30px control, label on 3 lines | worked |
| r5 | start card vs collect step | "August 2026" then "Pulling data · September 2026" | worked |

Two further facts from the same record:

- **The layout pass found nothing, in both runs.** `observations.json` reports
  `elementCount: 112`, `foundCount: 0`. Buttons whose icons overflow them were
  on screen and the overflow/wrap/clipping pass came back empty, twice.
- **Neither run typed anything.** 0 typings, 0 keypresses in both. Nothing was
  entered into an insight box, so nothing could be checked carrying from one
  screen to the next — which is exactly the shape of the month mismatch.

**About the second real row.** It is scored from the look Number One ran
against PR #206 on 2026-09-19, 05:21–07:02 PDT — a real live look on real code,
its whole output committed under `baseline-run/reference-s219-real/`. It is
labelled a **reference** rather than a fresh baseline for one reason: `d37979f`
landed at 18:08 PDT that day and it touched `skills/lcars-xo/`, so this look ran
a few commits earlier on the same branch. Nothing in `d37979f` is about what the
look can see — but that is an argument, not a measurement, so the row says what
it is. It is kept beside the fresh run because the two differ in a way worth
knowing: **the reference teleported four times and the fresh run clicked**
(`actions-1.json`: navigate to `#mbr`, then `click .start-action .btn`, then
`click [data-testid="continue-btn"]`). Same code, same engine, same app, one
walked and one did not — so *how it moved* is a lottery today, and a single run
showing a click is not evidence that part F is unnecessary. Recall was 0/5 on
both, walking or not.

---

## The planted case — the Tide Board fixture

**5 of 5 planted faults found. 0 of 2 correct controls flagged. Grade low, and
earned.** Live look, 665s wall (11 minutes), two worker rounds, `xo/` under
`baseline-run/planted/`.

In its own words, lightly trimmed:

| | it said |
|---|---|
| p1 save icon | "in the build the square is far larger than that — it fills the button's full height and bulges past its top and bottom edges" |
| p2 publish wrap | "the button is only 74px wide so the label wraps onto TWO lines ('Publish' over 'board'), and the box is 41px tall instead of the 34px control height" |
| p3 chip colour | "your drawing paints it red (#c0392b) as a warning; in the build it is GREEN (rgb(30,142,62)) — which reads as a healthy, all-good state" |
| p4 help corner | "your drawing puts Help in the top-right of the head; in the build it sits at the top-LEFT … measured x=45, hard against the left edge" |
| p5 export missing | "in the build it isn't there at all — the row goes Save reading, Publish board, then straight to the green '2 readings stale' chip" |

And the two it correctly left alone:

- the tab bar — *"run edge to edge with no gap at either end (tabBar box x=25
  w=820 sits flush inside the screen x=24 w=822)"* → **met**
- the notice — *"is 230px wide and wraps to two lines … matching the drawing"*
  → **met**. It saw the wrap and did not call it a fault, because the drawing
  wraps too. That is the discrimination the false-alarm column exists to check.

The journey arm: 3 clicks, 1 typing, **zero address jumps past the front door**,
and it caught the lock gate — *"with the note box still empty … it has already
published … It locked and published an empty note instead of refusing."*

One nuance the p4 row hides: the look reported Help in the top-**left**; the
fixture puts it bottom-left. It named the part and the kind of fault correctly
and got the corner half right, so the rule scores it found. A later part could
reasonably tighten this.

---

## What the baseline is NOT evidence of

- **Not** that the look is blind in general. See the planted arm.
- **Not** a Claude measurement. Both arms ran on Copilot.
- **Not** a statement about one run being typical. Each arm is **one** live
  look, and a model's output is a lottery. Before reading a small movement as
  progress, run the arm more than once.
- The planted arm's first two attempts measured the **harness**, not the look:
  the first was refused by the state writer (a compact `state.json`), the second
  could not launch a bare `index.html` with no start command. Both are fixed in
  the fixture. **A zero from a build that never came up is not a zero from a
  look that could not see** — any later agent reading a recall of 0 should
  check `out/<arm>.look.log` for "the build is up" before believing it.
