# Validated Plan: fixture B2 (unrelated)

## Synthesis

Elided. This fixture shares not one noun with fixture A2. Its decisions are the
SAME SHAPES the captain's 56 real validated plans actually use to prohibit a
name — a negation cue and a code-shaped name in the same clause, and never the
one phrasing B2 was first built for.

## Decisions

- Keep all three Budget screens as an internal screen-state enum inside
  `BudgetLinesView` under the single existing `#budget` route; do not add new
  routed views.
- Derive tracked-automatically from `pullRecipe` via the existing `isTracked`
  predicate (non-empty after trim = tracked). Populate that per-line field in
  `data/quarters.json` to make lines tracked; do not grow a hardcoded id list
  and do not conflate with `SYNCED_LINE_IDS`.
- A rolled-up line's total is always derived from its cost centres and is never
  editable; only a cost centre amount takes an edit.
- Autosave every edit on a ~500 ms trailing debounce via the existing
  `saveQuarter` write path; no new partial write path.
- Do not touch `docs/mocks/` (reference only) and do not add a second sync
  bridge — extend the one that exists.

## Rationale

Elided.
