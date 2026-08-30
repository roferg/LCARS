# Metrics Refresh D

## The problem
The scorecard collects many KPIs automatically, but there is nowhere to see the
health of that collection. The captain wants one screen that shows every
auto-collected KPI, when each last refreshed, whether it succeeded or failed,
and a way to re-run one on demand — with the stale ones surfaced first.

## Decisions
- **A dedicated "Auto-collected metrics" screen, separate from the scorecard**
  (T1) — the captain asked for "a new screen," so refresh health lives on its
  own surface rather than being folded into the existing bucket cards.
- **Stale metrics are grouped into their own section at the top, sorted oldest
  first; up-to-date ones sit in a second section below** (T1) — the captain
  said "group the ones that are stale to the top," so the layout is two labelled
  groups rather than one sortable list, making "what needs attention" readable
  at a glance.
- **Per-row refresh state = a relative age ("2d 1h ago") with the exact
  timestamp beneath it, plus a shape-and-colour outcome chip** (T1) —
  succeeded/failed/collecting reuse the scorecard's existing shape-encoded
  status vocabulary (filled circle / diamond / spinner) so outcome is not
  colour-only.
- **The header strip is a three-part coverage panel: an automatic count, a
  manual count, and a proportion bar** (T1) — the captain asked to show "how
  many KPIs are on automatic collection versus how many are still manual," so
  both raw counts and the split are shown together.
- **"Refresh now" is a small per-row button that shows a collecting state, then
  resolves** (T1) — the captain asked for "a small refresh-now control" on each
  item; it sits at the row's trailing edge in the scorecard's `.btn.sm` style.
- **Built in the existing dark-default Primer look** (T1) — the captain said
  "draw it in our existing look"; tokens, pills, and status shapes are taken
  from `basis.md`. A theme toggle is included to show the light retint too.

## Open questions
- Should the header strip's counts be clickable filters (e.g. jump to the manual
  KPIs), or is it a read-only summary?
- Should a failed refresh surface *why* it failed (an error reason / last-error
  line), or is the pass/fail chip enough for this screen?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements
1. Provide a new "Auto-collected metrics" screen for the scorecard. (T1)
2. List every KPI that is collected automatically. (T1)
3. For each KPI show its per-item refresh state: when it was last refreshed and
   whether the last refresh succeeded or failed. (T1)
4. Give each KPI a small "refresh now" control. (T1)
5. Group the ones that are stale to the top. (T1)
6. Show a header strip with how many KPIs are on automatic collection versus how
   many are still manual. (T1)

### 2. Implied by the mockup, not yet settled
- What makes a KPI "stale"? The mockup draws the cut at a fixed age (older than
  48h since last refresh) — is staleness an age threshold, and if so what is it,
  or is it driven by each KPI's own expected cadence?
- "Refresh now" in the mockup re-runs a single KPI and, on success, moves it out
  of the stale group. Should triggering a refresh be synchronous (block and show
  a result) or fire-and-forget (queue it and let the row update later)?
- The row shows the collection source (e.g. `ci.runs`) as a caption. Is the
  source/collector meant to be surfaced on this screen, or is that internal?
- Does this screen need a "refresh all stale" bulk action, or is per-row enough?

### 3. Out of scope

## DECLARED FLOW
`auto-metrics` → click `.btn.sm` "Refresh now" on a `.m-row` → row shows collecting state → on success row moves to the "Up to date" group, counts update
`auto-metrics` → click theme toggle → same screen re-themed (dark ⇄ light)

## DATA PRECONDITIONS
`each KPI record carries an is-automatic (vs manual) collection flag`
`each auto-collected KPI carries a last-refresh timestamp and a last-refresh outcome (success/failure)`
`each KPI belongs to one of the known buckets in accents.ts (for the bucket swatch colour)`
