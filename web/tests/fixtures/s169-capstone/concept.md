# LedgerBook redesign

## The problem
LedgerBook looks like a 2003 desktop intranet app — flat, square, steel-blue,
light-only. The captain wants it to feel like a modern personal finance app he'd
happily open every day: dark by default, money made the visual hero.

## Decisions
- **T2 · Theme model** — `basis.md` is light-only with no theming → now **two
  themes** (dark + light) switched by a single semantic-token layer.
- **T3 · Theme default** — (supersedes T2's dark-always-default) → theme now
  **follows the OS `prefers-color-scheme` on first load**, and an **explicit
  toggle click is remembered** (`localStorage`) and overrides the OS from then on.
  Resolved pre-paint to avoid a flash of the wrong theme.
- **T2 · Theme toggle** — no toggle existed → added a **sun/moon icon button**.
  **T3:** moved from the top bar to the **bottom of the left sidebar**, beside a
  "signed in" line.
- **T2 · Design tokens** — every value was a hardcoded hex/px literal → now a
  **two-tier token system**: a raw palette (`--c-*`) feeding **semantic roles**
  (`--bg`, `--surface`, `--fg`, `--accent`, `--danger`, `--over-*` …); theming
  flips only the semantic layer. Adds a **rem type scale** (1.25 ratio, 12→40px)
  and a **4pt spacing scale** replacing the per-rule px.
- **T2 · Money typography** — amounts were `monospace` 13px, same weight as body →
  now **big, confident tabular figures**: JetBrains Mono, `tabular-nums`, weight
  600–700, a **40px hero balance** in the summary card, 16px amounts in rows.
- **T2 · Over-budget signal** — the faint `#ffeeee` pink row wash → now a **loud
  red signal**: a solid red left bar on the row, the amount rendered in red, and
  an uppercase red **"OVER" pill** on the description (and on category cards).
- **T2 · Brand chrome** — steel-blue full-width band with navy border → now a
  **translucent blurred surface bar** with a gradient app mark and emerald accent.
- **T2 · Tabs → T3 · Sidebar** — the original bevelled folder tabs (T2 replaced
  them with flat top underline tabs) → now **removed from the top entirely** and
  moved into a **persistent left-hand sidebar** (Expenses / Categories / Summary
  as a vertical nav list with icons), the current view marked with an emerald
  filled pill. The top bar now shows just the active view's title + Add expense.
- **T3 · Month control** — was float-right in the top bar (T2), now **removed
  from the top bar and placed at the top of the sidebar**, with ‹ › steppers.
- **T3 · Month total** — the spent-this-month figure moves out of the expenses
  stat-cards and sits **directly under the month in the sidebar** (40px hero
  figure + of-budget/left line + progress bar), visible the instant the page
  loads on every view.
- **T3 · Layout** — single centered column (T2) → now a **two-column app shell**:
  fixed 260px sidebar + fluid main content column.
- **T2 · Surfaces** — square white tables with hairline grey borders → now
  **rounded cards/panels** (radius 10–16px) with soft shadows on a dark canvas.
- **T2 · Summary strip** — none existed above the table → added a **stat-card row**
  (spent-vs-budget with progress bar, largest category, over-budget count).
- **T2 · Categories view (grid) → T6** — the category cards now carry a
  **budget-status progress bar with three colour bands**: green "On track"
  (<80% of budget), amber "Close" (80–100%), red "Over" (>100%), driven by a
  per-card `--bar` token and echoed in a status pill. Card keeps the numbers and
  adds a **"NN% used" / "$X left" (or "$X over")** foot line. (Supersedes the
  earlier per-category-colour bar, which didn't signal budget health.)
- **T2 · Summary view → T6 · Stat tiles** — the summary top row of plain
  label+number cards read as "three lines of text" → now **finished stat tiles**:
  each with a rounded icon badge (up/down/piggy-bank), uppercase label, a 40px
  mono value, and a sub line (Income / Expenses / Net saved). The by-category
  table beneath is unchanged.
- **T2 · Add-expense form → T4 · Slide-over** — the original hidden pale-yellow
  inline panel (`#add-form`, `#ffffdd`) that pushed the table down the page →
  now a **right-hand slide-over sheet** (420px) over a **dimmed, blurred scrim**,
  with **stacked, labelled fields**: a large mono Amount input with a `$` prefix,
  Description, a Category/Date row, and an optional Note, plus Cancel / Save in a
  bottom bar. Opens from the existing Add-expense button; closes on ✕, Cancel,
  scrim click, or Esc. The button itself is **unchanged** (same place, same label).
- **T2 · Tables → T5 · Expenses rows** — the redesigned table still read
  spreadsheet-like → now the expenses list **breathes**: vertical cell padding
  raised (`16px → 20px`), a single soft row separator only (no vertical rules —
  confirmed none remain), the **category chip made subtle** (was a filled
  `--surface-3` pill; now just a colour dot + muted label, no background/border),
  and amounts stay hard-right in the mono face.
- **T2 · Delete affordance → T5** — the trash icon button was always visible →
  now **quiet: hidden (`opacity:0`) until its row is hovered** (or the button is
  keyboard-focused), then reveals and turns danger-red on hover.

## Open questions
- Is emerald/green the right brand accent? **Settled T3: keep emerald.**
- (Theme default/persistence — settled T3, moved to Decisions.)

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements (captain's words)
1. "Give me a proper dark theme as the default, with a light theme available too."
   (T2) — **refined T3: default now follows the OS, remembered after a toggle.**
2. "Put a toggle somewhere sensible in the top bar." (T2) — **T3: captain moved
   the nav to a sidebar; toggle now lives at the foot of the sidebar.**
3. "Real design tokens this time, not hex codes scattered through the file." (T2)
4. "The numbers should carry weight — big, confident, tabular figures." (T2)
5. "The over-budget signal [should] be a colour I actually notice, not a faint
   pink wash." (T2)
6. "Move Expenses / Categories / Summary into a proper left-hand sidebar … with
   the current one clearly marked." (T3)
7. "Put the month at the top of it … and give me the month total right underneath
   it so I can see where I stand the second the page loads." (T3)
8. Theme should "follow the OS by default but remember my choice once I've clicked
   the toggle." (T3)

### 2. Implied by the mockup, not yet settled (asked in chat)
- The **month stepper** (‹ August 2026 › in the sidebar) is drawn but not wired —
  should paging months actually re-load that month's data + total?
- The **Add expense** slide-over has a Save button that only shows a placeholder
  alert — what happens on save (validation, which fields are required, does the
  new row appear immediately)? The add flow's *look* is settled; its behaviour is not.
- The **budget progress bar / "$352.40 left"** implies live budget tracking — is
  budget-vs-actual a real feature, and are per-category budgets user-editable? The
  category cards also use fixed **status thresholds (green <80%, amber 80–100%,
  red >100%)** — are those the right cutoffs?
- The **sidebar nav badges** (a "7" on Expenses, a red "2" on Categories) are drawn
  static — should they be live counts (item count / over-budget count)?
- **Delete** is an icon button with no confirmation — should deleting confirm?

### 3. Out of scope
- (none stated yet)

## DECLARED FLOW
- `expenses` (default) → click sidebar `Categories` → `categories`
- `expenses` → click sidebar `Summary` → `summary`
- any view → click a sidebar nav item → that view (three-way switch, `.view`
  show/hide; nav `aria-current` + top-bar title update to match)
- sidebar foot → click theme toggle → same view, `data-theme` flips dark⇄light
  and the choice is persisted to `localStorage`
- first load → no stored choice → theme follows OS `prefers-color-scheme`
- `topbar` → click `Add expense` → `add-sheet` slides in from right over dimmed
  scrim → ✕ / Cancel / scrim-click / Esc → closes, returns to current view
- `topbar` → click `Add expense` → placeholder alert (add flow not yet designed)
