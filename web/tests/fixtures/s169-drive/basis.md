# Design basis — Trip board — dark theme with a left stop list

What the holodeck found by reading /private/tmp/claude-501/-Users-roganferguson-Projects-LCARS/bb41f80a-24d6-4638-a50d-4eeb3626f1e2/scratchpad/target, read-only. Correct anything wrong here: it is what the mockup is built from.

I'll explore the repository to report its existing design language.

README says "light theme only" — notable. Let me read the source files.

I've read the entire project. Here's the basis.

---

# Basis — Waypoint (existing design language)

Grounding for the **"Trip board — dark theme with a left stop list"** program against the real repository. Everything below was read from files; nothing is inferred or invented.

## What the project is
A tiny single-page trip planner called **Waypoint** (`package.json` → `"name": "waypoint"`, `"version": "0.1.0"`). It's plain HTML/CSS/JS — no framework, no build step. Only script is `node --test` (`package.json`). Three source files total: `src/index.html`, `src/app.css`, `src/app.js`.

## Colour tokens (from `src/app.css`)
There is **no token system** — no CSS variables, no theme file. Colours are hard-coded literals inline in rules:

| Value | Where | Role (as used) |
|---|---|---|
| `#fff` | `body { background }` | page background |
| `#111` | `body { color }` | text |
| `#ddd` | `.topbar { border-bottom }` | topbar divider |
| `#eee` | `#stops li { border-bottom }` | stop row divider |

That's the entire palette — four greys/near-blacks/whites. No brand colour, no accent, no semantic colours (success/warn/error), no hover/active states.

## Type scale (from `src/app.css`)
There is **no scale**. One family declaration: `font-family: system-ui` (`body`). One weight override: `font-weight: 700` on `.brand`. No `font-size` is set anywhere, so everything is the browser default (~16px). No line-height, letter-spacing, or heading levels defined.

## Spacing (from `src/app.css`)
No spacing tokens. Raw pixel values used ad hoc:
- `.topbar` → `gap: 12px`, `padding: 12px 16px`
- `main` → `padding: 16px`
- `#stops li` → `padding: 6px 0`
- `#totals` → `padding: 16px`
- `body` → `margin: 0`

So the informal rhythm in use is **6 / 12 / 16 px**.

## Radius
**None.** There is no `border-radius` anywhere in `src/app.css`. Every corner is square today.

## Existing components / structure (from `src/index.html` + `src/app.js`)
- **Topbar** (`header.topbar`): a `.brand` label ("Waypoint") plus a `<button id="new">New trip</button>`. Flex row with a bottom border.
- **Stop list** (`main > ul#stops`): a plain vertical `<ul>`. Rows rendered in JS as `<li>${s.name} — ${s.km} km</li>` (`app.js`). Rows are divided by a bottom border, no leading/number, no drag, no selection.
- **Totals** (`aside#totals`): a single line, text set in JS to `'Total: ' + …sum… + ' km'`. Renders "Total: 0 km" empty.
- **State/behaviour** (`app.js`): `stops` is an empty in-memory array (`const stops = []`) — no data, no persistence. The only interaction is the **New trip** button, whose handler `stops.length = 0; render()` **clears** the list (it does not add a stop). `render()` rewires innerHTML on each call.

## What I did NOT find (often the more useful half)
- **No dark theme.** Despite the new program's name, the project is **light-only today** — `body { background:#fff; color:#111 }`, and the README states plainly *"light theme only."* There is no dark palette, no `prefers-color-scheme`, no theme toggle.
- **No left stop list.** The current stop list sits in the **centre** `main`, not a left rail. Layout is a single stacked column (`header` / `main` / `aside`) — no CSS grid, no flex sidebar, no left column. The README even describes the sidebar (totals) as **right-hand**.
- **No design tokens** — no CSS custom properties, no theme/tokens file, no Sass/Tailwind config. Colours, spacing and weight are hard-coded per rule.
- **No type scale, no radius scale, no elevation/shadow, no transitions or animation.**
- **No component library or framework** — no React/Vue, no CSS framework; raw DOM strings in `app.js`.
- **No icons, no imagery, no font imports** (system-ui only).
- **No responsive rules** — no media queries, no breakpoints.
- **No accessibility affordances** beyond native elements — no ARIA, no focus styling, no landmarks beyond `header/main/aside`.
- **No persistence or real data** — the stops array is empty and only ever cleared.

## Implications for the new program
Building "dark theme with a left stop list" means **introducing**, not extending: the repo has no dark colours to reuse, no token layer to hang a theme on, and no side-rail layout. Two of the three existing dividers (`#ddd`, `#eee`) and both backgrounds (`#fff`, `#111`) are light-mode assumptions that a dark theme must replace. The existing `6/12/16px` spacing rhythm, the `system-ui` family, and the `.topbar` / `#stops` / `#totals` component seams are the only genuine footholds to build on.
