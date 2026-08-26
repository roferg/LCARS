# Legend Restyle B

## The problem
The scorecard's status legend reads poorly: items are stacked, the swatches are
small and sit loosely beside their labels. Same information, better read.

## Decisions
- **T1 — Legend items on one row.** Horizontal flex row (wraps only if the
  viewport forces it) instead of a vertical stack, because the captain asked for
  a single row and it makes the five markers scan as one key rather than a list.
- **T1 — Swatch dots slightly larger (10px vs the 8px in-table dots).** A legend
  swatch is read on its own, not beside a KPI name, so a touch more size makes
  the shape-coding legible without changing the table dots.
- **T1 — Tight swatch→label gap (5px).** Binds each swatch to its own label so
  the pairing is unambiguous across a single row; the space *between items* stays
  wider (18px) so pairs don't run together.
- **T1 — Labels use the muted foreground token (`--fg-muted`).** The legend is a
  reference key, not primary content — muted text keeps it subordinate to the
  scorecard, per the captain's ask.

## Open questions
None.

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements
1. Put the legend items on one row instead of stacked. (T1)
2. Give each swatch a slightly larger dot. (T1)
3. Tighten the gap between the swatch and its label. (T1)
4. Use the muted text colour for the labels. (T1)
5. Keep everything else on the page exactly as it is. (T1)

### 2. Implied by the mockup, not yet settled
- When the row is too narrow for all five items, the mockup lets them wrap to a
  second line. Is wrapping acceptable, or must the legend stay on a single line
  (e.g. scroll / shrink) at every width?

### 3. Out of scope
- No new legend data (no added or renamed markers).
- No new controls.
- Any change to the rest of the page.

## DECLARED FLOW
`scorecard` (single screen; legend sits below the table, no transitions)

## DATA PRECONDITIONS
