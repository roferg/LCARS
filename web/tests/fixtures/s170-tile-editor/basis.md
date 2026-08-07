# Design basis — Give the tile editor a more modern UI look and add a light/dark mode. I don't want to touch the tile canvas at all

What the holodeck found by reading /Users/roganferguson/Projects/groutwork, read-only. Correct anything wrong here: it is what the mockup is built from.

I'll explore the repository to understand its existing design language.

The editor is Tailwind + Radix. Let me explore its structure and styling config.

Tailwind config is empty (no custom tokens). Let me read the global styles, App, and components.

Colors are hardcoded hex + Tailwind palette classes. Let me survey all component styling to extract real values.

Let me read the ToolButton, a dialog, and the pickers/panels to complete the picture.

Let me confirm there are no centralized theme tokens and scan color usage across all components.

Let me capture the semantic/accent colors in the data-layer panels, which likely use distinct hues.

I have a complete picture. Here is the basis.

---

# basis.md — Groutwork Tile Editor: Existing Design Language

Grounding for the "modern UI + light/dark mode" program. Everything below is read from real files in `packages/editor/`. The tile canvas (`components/MapCanvas/`, `components/canvas/`) is out of scope and was not treated as a source of design tokens.

## The single most important finding

**There are no design tokens.** `packages/editor/tailwind.config.js` is empty — `theme: { extend: {} }`, `plugins: []`. There is no CSS variable layer, no theme file, no `ThemeProvider`. Every colour, size, and radius is a **hardcoded Tailwind utility class or arbitrary hex value inline on each component**. Any token system this program introduces would be net-new, not a refactor of an existing one.

**No light theme exists — the project is dark-only today.** Zero `dark:` variants, zero `prefers-color-scheme`, zero `data-theme`, zero theme state in Zustand or `localStorage`. (Searched all of `src/` — no matches.) The root element hardcodes dark surfaces: `App.tsx:133` → `bg-[#111827] text-gray-200`. Light mode is a from-scratch addition.

## Colour — actual values

### Surfaces (arbitrary hex, the four-level dark stack)
Read from `App.tsx`, `Toolbar.tsx`, `MapSwitcher.tsx`, `ObjectCreator.tsx`, dialogs:

| Role | Hex | Where |
|---|---|---|
| App shell / mode bar | `#111827` | `App.tsx:133`, `App.tsx:171`; also used as an *input* bg in `ObjectToolbar.tsx`, `ObjectPicker.tsx` |
| Panels, toolbar, dialogs | `#1f2937` | `App.tsx:143`, `Toolbar.tsx:151`, `NewMapDialog.tsx:95`, all dialogs, `ObjectCreator` asides |
| Canvas/main well | `#0f172a` | `App.tsx:152`, `ObjectCreator.tsx:194` |
| Tab bar (maps/objects) | `#1a2332` | `MapSwitcher.tsx:49`, `ObjectCreator.tsx:160` |

Note these four are **not from a single Tailwind scale** — `#111827`/`#1f2937` are `gray-900`/`gray-800`, but `#0f172a` is `slate-900` and `#1a2332` is a bespoke value. The surface stack is already slightly inconsistent.

### Greys (Tailwind `gray-*`, used as named classes)
- Text: `text-gray-100` (headings/emphasis), `text-gray-200` (body default), `text-gray-300` (secondary), `text-gray-400` (muted/inactive), `text-gray-500` (labels/placeholder), `text-gray-600` (disabled/hint).
- Borders & rings: `border-gray-700`, `ring-gray-700` (dividers), `ring-gray-600` (input outline), `bg-gray-600` (toolbar divider `Toolbar.tsx:272`), `bg-gray-800` (input fill), `bg-gray-700` (hover fill).

### Accent — primary
**`blue-600`** is the primary/selected/CTA colour everywhere: active tools (`ToolButton.tsx:20`), active tab (`App.tsx`, `MapSwitcher.tsx:68`), CTA buttons (`bg-blue-600 hover:bg-blue-500`, `NewMapDialog.tsx:188`), Radix highlighted items (`data-[highlighted]:bg-blue-600`), focus rings (`focus:ring-blue-500`, `ring-blue-500`). Selected-but-quiet state uses `bg-blue-600/20 text-blue-300` (`LayerPanel.tsx:61`). Tile-selection highlight in `TilePicker.tsx:170` uses the literal hex `#3b82f6` (= `blue-500`) and fill `rgba(59,130,246,0.25)`.

### Accent — secondary (an inconsistency to resolve)
The **Object Creator surface uses `indigo` instead of `blue`**: `bg-indigo-700 hover:bg-indigo-600` for its add button and `hover:bg-indigo-600` on menu items (`ObjectList.tsx:33,83,89`). So the app currently has *two* primary accents depending on which mode you're in. A modern token system should decide whether that's intentional.

### Semantic colours
- Danger/delete: `text-red-400`, destructive menu `data-[highlighted]:bg-red-600`, error banners `bg-red-900/50 text-red-200 ring-red-700` (`Toolbar.tsx:249`, `LinkPanel.tsx:101`).
- Success: `text-green-400` ("Saved" flash, `Toolbar.tsx:184`).
- Warning/dirty: `text-yellow-400` (unsaved dot, `Toolbar.tsx:178`), `text-yellow-300` (canvas hint).

## Type scale (Tailwind sizes actually used)
Small and dense. From smallest up:
- `text-[9px]` — tag/badge chips (`ObjectPicker.tsx:43`, `ObjectList.tsx:61`).
- `text-[10px]` — the workhorse label size: section headings, uppercase labels, tooltips (`ToolButton.tsx:33`). Almost every `<h3>` is `text-[10px] font-semibold uppercase tracking-wider text-gray-500`.
- `text-[11px]` — occasional descriptions.
- `text-xs` (12px) — the default body/control size for nearly all buttons, inputs, list rows, menu items.
- `text-sm` (14px) — dialog titles, project name, canvas empty-state.
- No larger sizes anywhere. No `text-base`+, no display type.

Weights: `font-medium` and `font-semibold` only. Headings pattern: `uppercase` + `tracking-wider` / `tracking-widest`. One `font-mono` usage for id badges.

## Spacing
Tailwind 4px grid, small end only. Padding: `p-1`, `p-2`, `p-3`, `p-6` (dialogs); button padding overwhelmingly `px-2 py-1` / `px-2 py-1.5` / `px-3 py-1.5`. Gaps: `gap-0.5`, `gap-1`, `gap-2`, `gap-3`. Fixed bar heights: toolbar `h-12`, map tabs `h-9`, mode bar `h-8`, controls `h-7`/`h-8`. Fixed widths: main sidebar `w-[280px]` (`App.tsx:143`), object-mode asides `w-[240px]`/`w-[220px]`, dialogs `w-[360px]`/`w-[400px]`/`w-[440px]`.

## Radius
Almost entirely the default **`rounded`** (0.25rem/4px) on buttons, inputs, rows, menus. Dialogs step up to **`rounded-lg`** (8px, `NewMapDialog.tsx:95` etc). One-offs: `rounded-r` (tab option button), `rounded-full` (anchor dot, `ResizeMapDialog.tsx:101`). No `rounded-md`, no `rounded-xl`+. Elevation is `shadow-lg`/`shadow-xl` on menus/dialogs plus a `ring-1` hairline — **rings, not borders, are the dominant separator** (`ring-1 ring-gray-600/700`), though `ObjectCreator`/`ObjectToolbar` break pattern and use `border border-gray-600/700` instead.

## Component shapes (what already exists to modernize)
- **Global CSS** (`styles.css`) is only Tailwind's three `@tailwind` directives plus `body { margin:0; padding:0; overflow:hidden }`. No custom classes, no variables. `index.html` has no theme class on `<html>`.
- **Buttons**: no shared `Button` component. Each is an inline `<button>` with repeated class strings. Three de-facto variants: primary (`bg-blue-600 text-white hover:bg-blue-500 disabled:opacity-40`), ghost/toolbar (`text-gray-300 hover:bg-gray-700`), and icon (`h-8 w-8 rounded` in `ToolButton.tsx`).
- **ToolButton** (`Toolbar/ToolButton.tsx`) is the one real reusable control — wraps Radix `Tooltip`, holds all the inline SVG tool icons (16×16, `stroke="currentColor"`, `strokeWidth="1.5"`).
- **Inputs**: repeated pattern `h-8 rounded bg-gray-800 px-2 text-xs text-gray-200 ring-1 ring-gray-600 outline-none focus:ring-blue-500` — duplicated across every dialog/panel, not componentized.
- **Radix primitives in use** (`package.json` / imports): `Dialog`, `Select`, `DropdownMenu`, `Tabs`, `Tooltip`. Overlays use `bg-black/60`. Menus: `bg-gray-800 p-1 rounded ring-1 ring-gray-600 shadow-lg` with `data-[highlighted]:bg-blue-600` items. These are the styling seams a theme layer would hook into.
- **Layout** (`App.tsx`): flex column shell → `Toolbar` → `ModeSwitcher` → `MapSwitcher` → (`aside` sidebar + `main` canvas). Object mode swaps in `ObjectCreator` with its own three-pane layout.

## What I did NOT find (gaps this program must fill)
- No light theme, no theme toggle, no theme persistence, no theme context/store — **dark-only, hardcoded**.
- No Tailwind theme tokens / CSS custom properties — colours are literal hex + palette classes scattered inline.
- No shared `Button`/`Input`/`Panel` components — styling is copy-pasted, so a token migration touches many files.
- No documented palette or type scale in `docs/` or `specs/` (the editor spec is `specs/editor-canvas.md`; ARCHITECTURE.md only says "Tailwind + Radix, components dumb, state in Zustand").
- Inconsistencies already present: mixed surface scales (`gray` vs `slate` vs bespoke `#1a2332`), dual accents (`blue` app-wide vs `indigo` in Object Creator), and rings-vs-borders split between Map mode and Object mode.

**Stay-out zone:** the user asked not to touch the tile canvas. `components/MapCanvas/MapCanvas.tsx` and `components/canvas/` own their own rendering colours (e.g. Pixi/2D-canvas fills like `#3b82f6`, `rgba(59,130,246,0.25)` in `TilePicker`); leave canvas-internal drawing colours alone and confine theme work to the surrounding React chrome.
