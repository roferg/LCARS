# Validated Plan: fixture B (unrelated)

## Synthesis

Elided. This fixture shares not one noun with fixture A.

## Decisions

- Keep all three Budget screens as an internal screen-state enum inside
  `BudgetLinesView` under the single existing `#budget` route; do not add new
  routed views.
- Classify tracked-automatically vs by-hand by `pullRecipe.trim() !== ''`;
  no `SYNCED_LINE_IDS`, no new boolean flag.
- A rolled-up line's total is always derived from its cost centres and is never
  editable; only a cost centre amount takes an edit.
- Autosave every edit on a ~500 ms trailing debounce via the existing
  `saveQuarter` write path; no new partial write path.
- Do not touch `docs/mocks/` (reference only) and do not add a second sync
  bridge — extend the one that exists.

## Rationale

Elided.
