# Tile Editor — modern UI refresh + light/dark mode

## The problem — what the captain is trying to solve
The Groutwork tile editor's chrome is a dated, dark-only, low-contrast UI with
ad-hoc inline styles (four unrelated surface hexes, two competing accents). The
captain wants a modern look and a proper light/dark toggle — without touching
the tile canvas.

## Decisions
- **T1** Start from a single self-contained mockup of the editor shell.
- **T1 (proposed)** Introduce a semantic token layer (surface / elevated / inset
  / border / accent / danger…) so light & dark are one switch. Basis found NO
  token layer exists.
- **T1 (proposed)** Reconcile the dual accent (blue=Maps, indigo=Objects) into
  one blue primary across all modes.
- **T1 (proposed)** Nudge radii up (4→6px controls, 8→10px panels); pills for
  mode tabs. Adopt **Inter** typeface (basis found no font set).
- **T2** Theme control is a **single toggle button** that flips to the other
  theme (not a segmented Light/Dark control).
- **T2** Map **name & size are edited in a dialog**, opened from a `⋯` on each
  map tab — NOT shown as a right-hand properties panel. Removed the Maps-mode
  right panel entirely.
- **T2** Objects mode gets its own layout: left object list, centre sprite
  preview + frames, right inspector (name/type/size + behaviour). Objects keep
  a right-hand inspector because per-object properties belong there; maps don't.
- **T3** "Game Mechanics" is a **section of selectable rows in the Maps-mode
  left sidebar, between Layers and Tileset** — modelled like Layers (icon +
  label, single-select), NOT dropdowns. The rows are **Objects, Collision, Map
  Links, Events** — a second "layer-style" stack. It is NOT a top-level mode.
  Modes are just **Maps** and **Objects**.
- **T4** Game-Mechanics rows are **select-only** for now (no visibility toggle).

## Open questions
- Is blue the right single primary, or should Objects keep an indigo identity?
- Should the theme toggle **persist** across sessions / default to OS?
- Keep the bottom **status bar**? (Still in the mockup.)
- Objects-mode inspector on the right is acceptable, even though maps' was cut?

## WHAT IT MUST DO — behaviour only

### 1. Requirements (captain's own words)
1. "give the tile editor a more modern UI look" — T1
2. "add a light/dark mode" — T1
3. "I don't want to touch the tile canvas at all" — T1

### 2. Implied by the mockup, not yet settled (asked in chat)
- Does the light/dark choice **persist** across sessions (and default to OS)?
- Map settings dialog (`⋯`) — does it also delete a map, or only rename/resize?
- Should "Saved 2m ago" / dirty-dot be a live status indicator in the toolbar?
- Is a bottom status bar (zoom / cursor / tile / layer) in scope, or noise?
- Objects mode: is the right-hand inspector the right home for object
  properties/behaviour?

### 3. Out of scope
- The tile canvas — its rendering and colours are untouched (T1).
- A right-hand **map** properties panel — explicitly rejected; edits live in the
  `⋯` dialog instead (T2).

## DECLARED FLOW
`editor` → click theme button → same `editor`, flips dark↔light, no reload
`editor` → click a map tab's `⋯` → `map-settings-dialog` (rename / resize)
`map-settings-dialog` → Save Changes / Cancel / × → `editor`
`editor` → click `Maps` mode → `maps-view` (left: Layers + Game Mechanics + Tileset; centre: canvas)
`editor` → click `Objects` mode → `objects-view` (object list + sprite preview + inspector); map tab strip hidden
`editor` → click a tool / layer / mechanics row / map tab / palette tile / object row / frame → selection updates in place
