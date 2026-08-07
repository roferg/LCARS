# Give the tile editor a more modern UI look and add a light/dark mode

## The problem
The Groutwork tile editor is dark-only with hardcoded, inconsistent styling (mixed
surface scales, dual accents, rings-vs-borders) and no theme system. The captain
wants a cleaner, more modern chrome and a real light/dark toggle — without touching
the tile canvas itself.

## Decisions
- **T1** Introduce a net-new CSS-variable token layer (surfaces, text, border,
  accent, radius) — today all colours are hardcoded Tailwind classes / inline hex
  with no tokens → now a single themeable variable set drives every chrome surface.
- **T1** Add a light theme alongside dark — today dark-only (`bg-[#111827]`
  hardcoded on root) → now `data-theme="light|dark"` on `<html>` swaps the whole
  token set.
- **T2** Theme control is a single icon button in the toolbar that toggles on click
  and swaps its icon (sun in dark, moon in light) — T1 mock had a two-segment
  light/dark toggle → now one button.
- **T2** Theme always starts in dark on load — no OS `prefers-color-scheme` seeding,
  no persistence for now (settled T2).
- **T1** Unify the accent — today blue app-wide but indigo in Object Creator → now
  one blue accent (`#3b82f6` / `#2563eb`) everywhere including Objects mode
  (accent choice confirmed T2).
- **T1** Replace rings with consistent 1px borders + soft shadows as the separator
  system — today rings in Map mode, borders in Object mode → now one border/elevation
  language across all chrome.
- **T1** Modernize the surface stack — today four inconsistent hex levels
  (`gray`/`slate`/bespoke `#1a2332`) → now a coherent 4-level scale (app / panel /
  panel-2 / well) per theme.
- **T1** Soften geometry — today default `rounded` (4px) everywhere → now a small
  radius scale (6/8/12px); pill-shaped map tabs and segmented mode switcher.
- **T1** Grow the toolbar/tab bars for breathing room — today toolbar `h-12`,
  mode bar `h-8`, map tabs `h-9` → now toolbar 52px, single merged tab row 42px.
- **T1** Move mode switch into a segmented control and map tabs into pills on one
  shared row — today separate `ModeSwitcher` + `MapSwitcher` bars → now combined
  (consolidation confirmed T2).
- **T1** Add a brand block (logo + project/file name) at the toolbar's left edge —
  new element, no equivalent today.
- **T2** Map tabs gain a per-tab options menu (kebab → Rename / Resize… / Delete;
  Select = click the tab) — today those map actions exist scattered
  (NewMap/Resize dialogs, delete) → now surfaced from one menu on the tab itself.
- **T2** Replace the T1 mock's swatch + tile-count layer list with the real
  editor's grouped left rail, restyled: **LAYERS** (Surface, Overhead, Entities)
  and **GAME MECHANICS** (Objects, Collision, Map Links, Events), each an
  icon + name row with a hover visibility toggle; selected row uses the accent.
- **T2** Remove the Layer-properties panel that the T1 mock added (opacity /
  grid / tile-size) — it is gone from the sidebar.
- **T2** Mock the Objects mode: the object library and a Properties panel.
  (T2 first draft put the library as cards in the left sidebar with a search field →
  search removed T3; per-object ⋯ menu Edit/Duplicate/Delete added T3; **T5 the
  library moved out of the left sidebar up into the top tab strip.**) Right
  **Properties** panel (name, id, sprite, size, solid/interactable/light switches,
  tags) stays.
- **T5** Rename the mode segment `Tiles → Maps` — T1–T4 mock labeled it "Tiles" →
  now "Maps" (its content is the map list).
- **T5** The top tab strip is mode-dependent: in Maps mode it holds the **map tabs**
  (Rename/Resize/Delete); switching to Objects replaces them with the **object
  library tabs** (Edit/Duplicate/Delete) in the same strip; switching back to Maps
  restores the map tabs.
- **T5** In Objects mode the left sidebar shows the **tileset selector** — T2–T4
  had the object cards there → now it's the tileset grid (same selector as Maps mode).
- **T3** Add a Close button to the toolbar, right of Save (with a divider), that
  closes the currently open project — today the editor already has a close-project
  control; the mock now models it correctly as a labeled "Close" button (T6: was a
  bare × icon → now a ghost button reading "Close").
- **T6** Redraw Undo/Redo as the simpler rounded hook-arrow style (matching the
  editor's own icons) in the modern line-icon treatment.
- **T4** Remap the toolbar to modern versions of the editor's real tool set — T1–T3
  mock showed Paint/Fill/Erase/Select/Eyedropper (invented) → now Draw (pencil),
  Curve, Shape (triangle), Select (marquee), a grid-toggle, Contrast, and Undo/Redo,
  in the modern line-icon style.

## Open questions
None open.

## WHAT IT MUST DO — behaviour only

### 1. Requirements (captain's words)
1. **T1** "Give the tile editor a more modern UI look."
2. **T1** "Add a light/dark mode."
3. **T1** "I don't want to touch the tile canvas at all." (out of scope, below)
4. **T2** "Start each time with dark theme. No OS default or persistence right now."
5. **T2** Light/dark is "a single button click that changes icons as you go from
   light to dark instead of a toggle."
6. **T2** Maps need their existing options to "select, rename, delete, or resize."
7. **T2** "Bound to the real dirty-state" — the Save/unsaved indicator reflects
   actual document dirty state, not a fake flip.
8. **T2** "Mock the tile objects tab" — the Objects mode gets a designed UI.
9. **T2** Left-rail selections "need to match what's currently there above the
   tileset, but mapped to your new modern style."
10. **T2** "We don't need the layer properties." (removed)
11. **T3** "You're missing the close button near save." → **T6** it must be a
    labeled "Close" button that closes the currently open project (an existing
    editor control), not a bare × icon.
12. **T3** "Remove the search for the object library." (removed)
13. **T3** Object library keeps the object cards and adds a ⋯ menu for Edit,
    Duplicate, and Delete.
14. **T4** The mock's toolbar must carry a modern version of every icon in the
    real editor bar (draw, curve, shape, select, grid, contrast, undo, redo).
15. **T5** In Objects mode, move the object library up into the top bar in place
    of the maps; clicking the Maps button switches the top bar back to the maps.
16. **T5** Rename the "Tiles" button to "Maps".
17. **T5** In Objects mode, the left sidebar has the tileset selector.

### 2. Implied by the mockup, not yet settled
- (none — the dirty-state binding and the canvas-overlay ownership questions from
  T1 were answered by the captain in T2.)

### 3. Out of scope
- The tile canvas rendering — left as an untouched placeholder well; canvas-internal
  drawing colours (`#3b82f6`, `rgba(59,130,246,0.25)`, tileset art) are not restyled.
- OS-preference detection and theme persistence — explicitly deferred ("not right now").

## DECLARED FLOW
- `editor` → click toolbar theme button → whole chrome re-themes in place, icon swaps sun↔moon, no navigation
- `editor` (Maps) → click `.maptab` → switch active map (active pill highlights)
- `editor` (Maps) → click `.maptab` kebab → options menu → Rename (inline edit) / Resize… (opens resize dialog) / Delete (removes tab)
- `editor` → click mode segment Maps → top strip shows map tabs, left rail = layers+tileset
- `editor` → click mode segment Objects → top strip shows object tabs, left = tileset selector, right = Properties panel, well caption swaps
- `editor` → click `.row` → select layer/mechanic (highlights); hover → `.reye` toggles visibility
- `editor` (Objects) → click object tab → select object (highlights); Properties panel reflects it
- `editor` (Objects) → click object tab kebab → options menu → Edit (opens object editor) / Duplicate (clones the tab) / Delete (removes it)
- `editor` → click Close → closes the currently open project
- `editor` → click Save → dirty indicator flips to "All changes saved", back to "Unsaved changes" when edited again
