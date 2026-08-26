# Metrics Refresh A

## The problem
KPIs collected automatically can silently go stale or fail to refresh, and today
there is no one place to see per-item refresh health or force a refresh. The
captain wants a dedicated "Auto-collected metrics" view that surfaces which KPIs
are on automatic collection, their last-refresh state, and lets you re-run one.

## Decisions
- **T2 — Stale KPIs are grouped into a section at the top, above a "Fresh"
  section.** The captain asked for stale-first ordering; a labelled section
  (rather than just a sort) makes the split legible and countable at a glance.
- **T2 — Each row shows last-refresh time as relative + absolute, a
  success/failed/running state, and a "Refresh now" control.** These are the
  three per-item facts the captain named; relative time answers "is it stale?"
  fastest while the absolute timestamp stays available underneath.
- **T2 — Last-refresh state reuses the app's bespoke status-dot shape language
  (filled circle = succeeded, diamond = failed, hollow ring = running).** The
  basis shows this is the established idiom for per-item status, so refresh
  outcomes read the same way as scorecard status.
- **T2 — A header strip counts On automatic / Still manual / Stale now, with a
  proportion meter.** The captain asked for auto-vs-manual counts; "Stale now"
  is added alongside because it is the number this screen exists to act on.
- **T2 — Drawn dark-default in the Primer-mirrored token palette, on the
  underline-tab nav and scorecard-table container from the basis, with a
  light-theme toggle.** Keeps the screen native to the existing product.

## Open questions
- Should "Refresh now" be available per-item only, or is a "Refresh all stale"
  bulk action wanted at the section header too?
- Should the manual KPIs be reachable from this screen (e.g. a link/tab), or is
  this view strictly the automatic ones with manual shown only as a count?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements
1. (T2) A new screen: an "Auto-collected metrics" view.
2. (T2) List every KPI that is collected automatically.
3. (T2) For each KPI show its per-item refresh state: when it was last
   refreshed, whether the last refresh succeeded or failed, and a small
   "refresh now" control.
4. (T2) Group the ones that are stale to the top.
5. (T2) Add a header strip showing how many KPIs are on automatic collection
   versus how many are still manual.

### 2. Implied by the mockup, not yet settled
- What defines "stale"? The mockup draws it as "past its expected refresh
  interval" and shows each KPI's interval (e.g. "every 6h") — is that the real
  rule, and where does the interval come from?
- "Refresh now" is drawn as: button spins, row moves to Running, then settles to
  Succeeded. Is a single click meant to trigger a real synchronous collection,
  and what should the row show if that manual refresh itself fails?
- The header strip's counts and the per-row source/interval line assume this
  data is queryable live — is there a store behind them, or are they computed
  from the KPI config at load?
- A "running" refresh state is drawn — does the backend expose an in-progress
  collection status, or is Running only ever the local optimistic state after a
  click?

### 3. Out of scope

## DECLARED FLOW
`auto-metrics` view is one tab in the existing underline nav (`Scorecard`,
`Buckets`, `Auto-collected metrics`, `Roster`).
`auto-metrics` → click `.icon-btn[data-refresh]` on a row → row enters Running →
settles to Succeeded, last-refreshed resets. (Mockup animates this locally.)
`auto-metrics` → click theme toggle → palette swaps dark/light in place.

## DATA PRECONDITIONS
