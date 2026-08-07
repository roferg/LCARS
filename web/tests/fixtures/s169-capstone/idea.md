LedgerBook redesign

## What it must do — in your own words

1. "Give me a proper dark theme as the default, with a light theme available too." (T2) — refined T3: default now follows the OS, remembered after a toggle.
2. "Put a toggle somewhere sensible in the top bar." (T2) — T3: captain moved the nav to a sidebar; toggle now lives at the foot of the sidebar.
3. "Real design tokens this time, not hex codes scattered through the file." (T2)
4. "The numbers should carry weight — big, confident, tabular figures." (T2)
5. "The over-budget signal [should] be a colour I actually notice, not a faint pink wash." (T2)
6. "Move Expenses / Categories / Summary into a proper left-hand sidebar … with the current one clearly marked." (T3)
7. "Put the month at the top of it … and give me the month total right underneath it so I can see where I stand the second the page loads." (T3)
8. Theme should "follow the OS by default but remember my choice once I've clicked the toggle." (T3)

## What the mockup changes — as the design chat recorded it

The design chat's own account of what it settled — not a reading of your code, and not everything the mockup changes. The mockup is what gets built: where a line here disagrees with the picture, the picture wins. Correct or delete anything that is wrong.

- T2 · Theme model — `basis.md` is light-only with no theming → now two themes (dark + light) switched by a single semantic-token layer.
- T3 · Theme default — (supersedes T2's dark-always-default) → theme now follows the OS `prefers-color-scheme` on first load, and an explicit toggle click is remembered (`localStorage`) and overrides the OS from then on. Resolved pre-paint to avoid a flash of the wrong theme.
- T2 · Theme toggle — no toggle existed → added a sun/moon icon button. T3: moved from the top bar to the bottom of the left sidebar, beside a "signed in" line.
- T2 · Design tokens — every value was a hardcoded hex/px literal → now a two-tier token system: a raw palette (`--c-*`) feeding semantic roles (`--bg`, `--surface`, `--fg`, `--accent`, `--danger`, `--over-*` …); theming flips only the semantic layer. Adds a rem type scale (1.25 ratio, 12→40px) and a 4pt spacing scale replacing the per-rule px.
- T2 · Money typography — amounts were `monospace` 13px, same weight as body → now big, confident tabular figures: JetBrains Mono, `tabular-nums`, weight 600–700, a 40px hero balance in the summary card, 16px amounts in rows.
- T2 · Over-budget signal — the faint `#ffeeee` pink row wash → now a loud red signal: a solid red left bar on the row, the amount rendered in red, and an uppercase red "OVER" pill on the description (and on category cards).
- T2 · Brand chrome — steel-blue full-width band with navy border → now a translucent blurred surface bar with a gradient app mark and emerald accent.
- T2 · Tabs → T3 · Sidebar — the original bevelled folder tabs (T2 replaced them with flat top underline tabs) → now removed from the top entirely and moved into a persistent left-hand sidebar (Expenses / Categories / Summary as a vertical nav list with icons), the current view marked with an emerald filled pill. The top bar now shows just the active view's title + Add expense.
- T3 · Month control — was float-right in the top bar (T2), now removed from the top bar and placed at the top of the sidebar, with ‹ › steppers.
- T3 · Month total — the spent-this-month figure moves out of the expenses stat-cards and sits directly under the month in the sidebar (40px hero figure + of-budget/left line + progress bar), visible the instant the page loads on every view.
- T3 · Layout — single centered column (T2) → now a two-column app shell: fixed 260px sidebar + fluid main content column.
- T2 · Surfaces — square white tables with hairline grey borders → now rounded cards/panels (radius 10–16px) with soft shadows on a dark canvas.
- T2 · Summary strip — none existed above the table → added a stat-card row (spent-vs-budget with progress bar, largest category, over-budget count).
- T2 · Categories view (grid) → T6 — the category cards now carry a budget-status progress bar with three colour bands: green "On track" (<80% of budget), amber "Close" (80–100%), red "Over" (>100%), driven by a per-card `--bar` token and echoed in a status pill. Card keeps the numbers and adds a "NN% used" / "$X left" (or "$X over") foot line. (Supersedes the earlier per-category-colour bar, which didn't signal budget health.)
- T2 · Summary view → T6 · Stat tiles — the summary top row of plain label+number cards read as "three lines of text" → now finished stat tiles: each with a rounded icon badge (up/down/piggy-bank), uppercase label, a 40px mono value, and a sub line (Income / Expenses / Net saved). The by-category table beneath is unchanged.
- T2 · Add-expense form → T4 · Slide-over — the original hidden pale-yellow inline panel (`#add-form`, `#ffffdd`) that pushed the table down the page → now a right-hand slide-over sheet (420px) over a dimmed, blurred scrim, with stacked, labelled fields: a large mono Amount input with a `$` prefix, Description, a Category/Date row, and an optional Note, plus Cancel / Save in a bottom bar. Opens from the existing Add-expense button; closes on ✕, Cancel, scrim click, or Esc. The button itself is unchanged (same place, same label).
- T2 · Tables → T5 · Expenses rows — the redesigned table still read spreadsheet-like → now the expenses list breathes: vertical cell padding raised (`16px → 20px`), a single soft row separator only (no vertical rules — confirmed none remain), the category chip made subtle (was a filled `--surface-3` pill; now just a colour dot + muted label, no background/border), and amounts stay hard-right in the mono face.
- T2 · Delete affordance → T5 — the trash icon button was always visible → now quiet: hidden (`opacity:0`) until its row is hovered (or the button is keyboard-focused), then reveals and turns danger-red on hover.

## Implied by the mockup — NOT things you said

The mockup implies these; nobody has settled them. They travel marked as IMPLIED, never as your words — answer them, correct them, or delete them.

- The month stepper (‹ August 2026 › in the sidebar) is drawn but not wired — should paging months actually re-load that month's data + total?
- The Add expense slide-over has a Save button that only shows a placeholder alert — what happens on save (validation, which fields are required, does the new row appear immediately)? The add flow's *look* is settled; its behaviour is not.
- The budget progress bar / "$352.40 left" implies live budget tracking — is budget-vs-actual a real feature, and are per-category budgets user-editable? The category cards also use fixed status thresholds (green <80%, amber 80–100%, red >100%) — are those the right cutoffs?
- The sidebar nav badges (a "7" on Expenses, a red "2" on Categories) are drawn static — should they be live counts (item count / over-budget count)?
- Delete is an icon button with no confirmation — should deleting confirm?

## Open questions from the design session

These were raised while the design was being drawn and they are NOT settled by this brief. An answered one is the captain's own decision and is a requirement. Anything marked STILL OPEN has no answer yet: ASK IT (`lcars:awaiting-human`). Do not settle it by choosing what the mockup happens to show, and do not treat it as agreed because nobody objected.

1. Q: Is emerald/green the right brand accent? Settled T3: keep emerald.
   ⚠ STILL OPEN — he was not asked, or did not answer. Treat as undecided.
2. Q: (Theme default/persistence — settled T3, moved to Decisions.)
   ⚠ STILL OPEN — he was not asked, or did not answer. Treat as undecided.

## How to read the attached mockup

- HOW MUCH TO BUILD: look AND behaviour. Build it for real — backend, state, persistence, the lot. The mockup says how it LOOKS; the brief above says WHAT IT MUST DO. The mockup's own interactions are illustrative only.
- Where the mockup and the brief disagree about WHAT IT MUST DO, the brief OVERRIDES the mockup. That is a TIE-BREAK, not a claim that the brief is exhaustive — the brief can be missing something the mockup has. Where they disagree about HOW IT LOOKS, it is the other way round: the mockup is the authority and OVERRIDES the brief, including any line of the brief that says a thing was kept or left unchanged. The mockup IS the design; the brief is an ACCOUNT of the conversation that drew it, written afterwards, and an account can describe the picture wrongly.
- A DISAGREEMENT between the mockup and the brief is EVIDENCE, not a decision for you to make. If the mockup shows or implements something the brief never mentions, treat that as a sign the hand-off may have LOST a requirement the human actually stated. ESCALATE it (`lcars:awaiting-human`) and name what the two sides say, rather than resolving it yourself. A stage that quietly picks a side produces work that is correct against its brief and wrong against the person who asked for it — and every gate downstream will pass it.
- The same applies when the brief CONTRADICTS the mockup rather than missing it — and one shape of that is easy to walk straight past: a brief line saying some element was KEPT, left UNCHANGED or carried over from the app as it is today, when the mockup has plainly redrawn it. The brief's change list is written from the design conversation, not read off the mockup, so such a line is the account being wrong about the picture. BUILD WHAT THE MOCKUP SHOWS (look is its call — see the precedence rule) and ESCALATE the contradiction so a human sees it; never read it as an instruction to leave that element alone.
- The mockup defines LOOK AND FLOW: layout, colour, spacing, wording, and the transitions between screens. Matching it visually is an ACCEPTANCE CRITERION of this work, not a suggestion.
- The mockup is NOT an implementation. Its internals are deliberately fake — hand-written to look right and wired to nothing. Nothing in it is code to copy, import, edit or ship.
- The mockup and the concept doc are REFERENCE ATTACHMENTS. They are not in this repository's working tree and they never enter it; they are not files this work may change, and a bug is never fixed by editing them.
- What a mockup CANNOT convey is feel — timing, weight, responsiveness. Named values (durations, easings) are in the concept doc; the rest is judged by the captain at the Verify gate.
