# Modern UX look for the top toolbar + left-hand edit selections

## The problem
The Groutwork editor's chrome (top toolbar + left edit rail) is built from raw,
inconsistent Tailwind utilities with no token layer, no font, and mixed
hover/focus rules. The captain wants it to feel like a modern, intentional UX.

## Decisions
- **T2** — Keep the existing dark surface ramp and blue accent from basis.md
  (#111827 / #1f2937 / #1a2332 / #0f172a, accent blue-600, focus blue-500).
  The mock recolours nothing; it re-composes.
- **T2** — Introduce the project's first token layer (surfaces, accent, text,
  lines, radius, shadow, motion) as CSS variables, since basis says none exist.
- **T2** — Adopt **Inter** as the chrome typeface (basis: no font is defined).
- **T2** — Group toolbar tools into segmented **clusters** (inset pill groups)
  instead of a flat row + 1px divider.
- **T2** — Left-rail layer rows get: leading icon, hover-revealed visibility
  eye, and an active state = soft-blue fill + inset ring + a 3px left accent bar.
- **T2** — Larger touch targets: toolbar 52px, tools 34px, rows ~36px; radii
  softened to 6–12px; consistent hover token everywhere.
- **T3** — Add a **light + dark theme**. Dark stays the default (matches today's
  dark-only app); light is a new proposal built by overriding the same token
  layer. A moon/sun toggle in the toolbar flips `data-theme` on `:root`, with a
  ~140ms cross-fade. Accent blue is shared across both themes.
- **T4** — In **light mode**, panels/toolbar are **white** and the palette
  leans on **lighter blues** — light-blue surface washes, blue-tinted lines and
  hovers, and a lighter accent (blue-500/blue-400) instead of the dark theme's
  blue-600.
- **T5** — Light-mode legibility: selected/active text (active layer row, active
  mode pill, tile chip) is **black**, not light blue. The canvas status bar
  keeps a dark scrim in both themes, so its text is **white** in light mode.

## Open questions
- Should the **mode switcher** (Tiles / Entities / Objects) live inside the left
  rail (as mocked) or stay as a separate 32px bar under the toolbar (basis)?
- Do layer rows need a **per-row visibility toggle** at all, or is that new
  behaviour I invented? (mock shows an eye — confirm.)
- Is a **tile search** field wanted in the picker, or out of scope for a
  visual-only pass?
- Should the toolbar show a **project glyph/logo**, or just the editable name?
- Keep the **status bar** at the bottom of the canvas, or is that scope creep?

## WHAT IT MUST DO — behaviour only

### 1. Requirements (captain's words)
1. "give the top tool bar and edit selections on the left hand side a modern UX
   look" — T1.
2. "Can we add a light and dark mode?" — T3.
3. "Can we use lighter blues along with white in light mode?" — T4.
4. "The selected text in light mode is too light. Text needs to be black in
   light mode. Also the bottom bar on the canvas isn't readable in light mode. I
   think the text needs to be white there." — T5.

### 2. Implied by the mockup, not yet settled (asked in chat)
- Q: Layer rows expose a hover-revealed visibility eye that toggles per-layer
  hidden state — is per-layer visibility a real feature?
- Q: Drawing tools behave as one exclusive segmented group (one active at a
  time); grid/snap are independent toggles — is that the intended split?
- Q: Tileset picker has a text search filter — wanted or decorative only?
- Q: Mode switcher moved into the rail header — acceptable relocation?
- Q: Canvas status bar (layer · tool · size · cursor · zoom) — in scope?
- Q: Should the theme choice **persist** (remembered between sessions) and/or
  follow the OS `prefers-color-scheme`? The mock only toggles in-memory.
- Q: Which theme is the **default** — dark (as today) or system-follow?

### 3. Out of scope
- (none stated yet)

## DECLARED FLOW
- `editor` → click a drawing `.tool` → tool becomes active (exclusive within its cluster)
- `editor` → click grid/snap `.tool` → independent toggle, no exclusivity
- `editor` → click a `.row` in the rail → that layer becomes the active edit target
- `editor` → click a row's `.vis` eye → toggles that layer's hidden state, selection unchanged
- `editor` → click a `.mode` → switches picker context (Tiles/Entities/Objects)
- `editor` → click a `.tile` → selects the paint tile shown in the picker chip
- `editor` → click the moon/sun `#themeToggle` → flips `:root[data-theme]` between dark and light, whole UI cross-fades

## Hand-off summary
A visual-reference restyle of the Groutwork editor's top toolbar and left edit
rail, built strictly on the existing dark palette and blue accent but adding the
project's first token layer, the Inter typeface, and a consistent
hover/focus/active contract. The toolbar groups tools into inset segmented
clusters with a primary Save; the left rail organizes Layers, Game Mechanics,
and a Tileset picker into titled groups with modern rows (icon + label +
hover-revealed visibility, soft-blue active state with a left accent bar).
Nothing new is coloured — the work is composition, spacing, radius, motion, and
consistency. Open questions center on whether the mode switcher, per-layer
visibility, tile search, and status bar are real behaviour or just mock dressing.
