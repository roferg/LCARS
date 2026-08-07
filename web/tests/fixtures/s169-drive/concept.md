# Trip board — dark theme with a left stop list

## The problem
Waypoint's stops today are a plain centred list with a total line and no map.
The captain wants a proper trip board: a dark canvas where the map is the star,
the stops live in a left rail beside it, and the total distance stays in view.

## Decisions
- **Turn 2** — Theme: today `body{background:#fff;color:#111}` (light-only, per
  README) → now a dark palette (`--bg #0f1216`, `--panel #171b21`,
  `--text #e7ecf2`, accent `--accent #4ea1ff`). Introduces CSS variables the
  repo did not have.
- **Turn 2** — Layout: today single stacked column (`header`/`main`/`aside`) →
  now a two-column stage under the topbar — left rail (`320px`) + map (`1fr`)
  filling the rest.
- **Turn 2** — Stop list: today centred `main > ul#stops`, rows
  `name — km` → now moved into the **left rail** as numbered pins with a name
  and a per-leg `+X km`; the selected stop highlights.
- **Turn 6** — Rail rows: dropped the per-stop sub-label/descriptor → now one
  line per stop (pin · name · `+X km`), tighter rows closer to today's data.
- **Turn 2** — Total distance: today `aside#totals` line "Total: X km" at the
  bottom → now surfaced in the **topbar** as a persistent "Total N km" chip
  (also echoed in the rail footer).
- **Turn 2** — Map: introduced (repo had none) as the primary surface right of
  the rail, drawing the route through the stops.
- **Turn 2** — Kept the `.brand` "Waypoint" label and the "New trip" button from
  the existing topbar; kept the `6/12/16px` spacing rhythm and `system-ui`.

## Open questions
- Should stops be reorderable (drag to resequence the trip)? The rail draws an
  ordered list but nothing implies a handle yet.
- Is there a real map/tile provider, or does distance come from entered legs
  only? The mockup fakes both.

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements (captain's words)
1. "a dark theme" (Turn 2)
2. "a left rail holding the stop list" (Turn 2)
3. "the map filling the rest of the screen" (Turn 2)
4. "Keep the total distance visible somewhere" (Turn 2)

### 2. Implied by the mockup, not yet settled — ASK
- Clicking a stop in the rail selects it and highlights its node on the map.
  Should selection also pan/zoom the map to that stop?
- The "New trip" button is drawn but does nothing here. Does it clear the
  current trip (as the repo's handler does today) or open an empty new one?
- Total distance is shown as a sum of per-leg km. Are legs entered by hand, or
  computed from map positions/routing?
- The rail footer shows a leg count. Is that a real derived stat to keep?

### 3. Out of scope
- (nothing ruled out yet)

## DECLARED FLOW
- `board` (topbar + left rail stop list + map) is the only screen.
- `board` → click `#stops li` → same `board`, selected stop highlighted in the
  rail and its `.node` emphasised on the map.
