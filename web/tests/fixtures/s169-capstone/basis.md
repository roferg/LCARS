# Design basis — LedgerBook redesign

What the holodeck found by reading <fixture-project>, read-only. Correct anything wrong here: it is what the mockup is built from.

I'll explore the repository to document its existing design language. Let me start by understanding the structure.

The design language lives in `styles.css`. Let me read it fully along with the HTML structure.

Let me check the JS files for any inline styling or additional visual tokens.

I have everything I need. The styling is entirely in one 82-line `styles.css` with hardcoded values — no token system. Here's the basis.

---

# LedgerBook redesign — basis.md

*What the existing project actually is, read from source. Every value below was read from a file; the filename is named beside it. Nothing here is inferred or filled in with "reasonable" defaults.*

## What this project is

A tiny personal expense ledger — plain HTML, CSS, and ES modules, **no framework, no build step, no dependencies** (`README.md` lines 3–4; `package.json` has no `dependencies` block at all). All styling lives in a single **82-line** stylesheet, `public/styles.css`. There is **no design-token layer**: not one CSS custom property (`--*`), no `:root` block, no Sass/Less, no theme file. Every value is a literal hardcoded into a rule.

## Colour — actual values (all from `public/styles.css`)

There is no palette abstraction; these are the literal hex values in the file.

| Role (as used) | Value | Where |
|---|---|---|
| Page background | `#f0f0f0` | `body` (l.5) |
| Body text | `#333333` | `body` (l.4) |
| Top bar background | `#4a6b8a` (steel blue) | `#topbar` (l.11) |
| Top bar text | `#ffffff` | `#topbar` (l.12) |
| Top bar bottom border | `#33495e` (dark navy) | `#topbar` (l.14) |
| Tagline text | `#cfd9e3` | `.tagline` (l.21) |
| Tab strip background | `#dfe4e9` | `#tabs` (l.33) |
| Tab strip border | `#aaaaaa` | `#tabs` (l.34) |
| Inactive tab background | `#cfd5db` | `.tab` (l.41) |
| Tab text / navy accent | `#33495e` | `.tab` (l.44) |
| Active tab background | `#f0f0f0` | `.tab.active` (l.48) |
| Add button background | `#dddddd`, border `#bbbbbb` | `#add-expense` (l.24–25) |
| Table background | `#ffffff` | `table` (l.52) |
| Table header background | `#e6e6e6`, border `#bbbbbb` | `table th` (l.54–55) |
| Table cell border | `#dddddd` | `table td` (l.60) |
| Over-budget row highlight | `#ffeeee` (pink) | `tr.over td` (l.61) |
| Delete link / danger | `#aa0000` (dark red) | `.del` (l.64) |
| Add-form background | `#ffffdd` (pale yellow), border `#ccccaa` | `#add-form` (l.69–70) |
| Muted / secondary text | `#888888` | `#empty-note` (l.66), `#footer` (l.80) |
| Footer top border | `#cccccc` | `#footer` (l.77) |

**Character:** a muted, cool grey-and-steel-blue Windows-desktop palette with a navy accent (`#33495e`), one danger red (`#aa0000`), and two "notice" tints — pink for over-budget rows, pale yellow for the add form. Semantics are ad-hoc, expressed by literal colour at the point of use, not by named tokens.

## Type scale (from `public/styles.css`)

- **Family:** `Arial, Helvetica, sans-serif` for the UI (`body`, l.2); `monospace` for amounts (`.amount`, l.63). No web fonts, no `@font-face`, no font import.
- **Sizes** — only px, no `rem`/`em`, no ratio: base **13px** (`body`, l.4); **18px** bold brand (`.brand`, l.17); **12px** for buttons, tabs, table th, form inputs (l.26, 46, 58, 74); **11px** for tagline, month label, delete link, footer (l.21, 22, 64, 81). So the scale is effectively **11 / 12 / 13 / 18 px** — four steps, no formal ratio.
- **Weight:** only `bold` appears (brand, active tab); no numeric weights, no light/medium.

## Spacing (from `public/styles.css`)

No spacing scale or unit variable — raw px per rule. Observed values: `2px`, `3px`, `4px`, `6px`, `8px`, `10px`, `12px`, `14px`, `20px`. Padding is written mostly as pairs like `8px 10px` (`#topbar` l.13, `#footer` l.79), `4px 6px` (table cells l.56/60), `12px 10px` (`#page` l.50), `4px 12px` (tabs l.39). It reads as hand-tuned per element rather than a 4- or 8-pt system, though 4/8/10/12 recur.

## Radius, shadow, borders (from `public/styles.css`)

- **Border-radius: none.** There is not a single `border-radius` in the file — every corner is square.
- **Shadow: none.** No `box-shadow`, no `text-shadow`.
- **Borders** carry all the separation: `1px solid` in greys, plus a `2px solid #33495e` under the top bar (l.14) and a retro **`1px outset #bbbbbb`** bevel on the Add button (`#add-expense`, l.25).
- **No transitions, animations, or gradients** anywhere.

## Component shapes (from `public/index.html` + `public/styles.css`)

- **Top bar** (`#topbar`): steel-blue full-width band; left-aligned bold brand + small tagline + an "Add expense" button, with a right-floated month label (`float: right`, l.22).
- **Tab strip** (`#tabs` / `.tab`): three inline-block tabs (Expenses / Categories / Summary), bottom-border-less so the active tab (`.tab.active`) merges into the page — a classic folder-tab metaphor. View switching is `display:none/block` toggled in `public/app.js` (l.59), active class set in `app.js` (l.62).
- **Tables** are the primary data surface: full-width, `border-collapse: collapse`, grey header row, right-aligned monospace `.amount` cells (l.63), inline underlined `.del` delete links (l.64), and an over-budget row state `tr.over` (added in `app.js` l.34) tinted pink.
- **Add-expense form** (`#add-form`): a pale-yellow bordered panel, hidden by default (`style="display:none"` in HTML l.51, toggled in `app.js` l.67/72), with unstyled native inputs/selects and Save/Cancel buttons.
- **Footer** (`#footer`): muted 11px note with a top rule.

Layout is **static, non-responsive**: fixed px sizing, a `float:right` for the month label, and no media queries, flexbox, or grid despite the viewport meta tag in `index.html` (l.5).

## What I did NOT find (equally important)

- **No token/theme system** — no CSS custom properties, no `:root`, no Sass/Less/PostCSS, no config. Colours, sizes, and spacing are all inline literals.
- **No light/dark theming — and note it's the *inverse* of dark-only: this app is *light-only* today.** Grey page, white tables, no dark surface anywhere, no `prefers-color-scheme`, no theme toggle.
- **No border-radius, no shadows, no gradients, no transitions/animations.** Everything is square and flat with hairline borders.
- **No spacing/type scale abstraction** — no rem/em, no modular ratio, just per-rule px.
- **No responsive design** — no media queries, no flex/grid; fixed px and a float.
- **No web fonts / icon system** — system sans + monospace only; delete affordance is a text link, not an icon.
- **No component framework or class utility system** — styling hangs off IDs and a few semantic classes (`.tab`, `.amount`, `.del`, `.over`, `.view`).
- **No CSS reset/normalize** beyond `body { margin:0; padding:0 }`.
- **No focus/hover/disabled states** defined for buttons, tabs, or links (only `.tab.active`); the only interactive cue is `cursor: pointer`.
- **No accessibility styling** — no visible focus ring, no ARIA-driven styles.

**Summary for the redesign:** you're starting from a flat, square, light-only, token-less desktop-utility look — steel-blue chrome over grey/white tables, a four-step px type scale, hand-tuned px spacing, borders instead of shadows, and zero theming or responsiveness. Any tokens, dark mode, radii, or scale you introduce will be net-new, not a modification of an existing system.
