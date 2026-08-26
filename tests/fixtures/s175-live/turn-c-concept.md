# Metrics Refresh C

## The problem
The scorecard collects many KPIs automatically, but there is no single place to
see whether that collection is actually healthy. The captain wants one view that
shows every auto-collected KPI's refresh state and surfaces the stale ones.

## Decisions
- **A dedicated "Auto-collected metrics" screen, reached as its own nav tab** (T1).
  The captain asked for "a new screen," so it sits alongside Scorecard/Trends in
  the existing underline-tab nav rather than as a panel on an existing page.
- **Stale KPIs are split into their own group at the top, above a "Fresh" group**
  (T1). The captain wants stale ones grouped to the top; a labelled section break
  reads more clearly than a single sorted list and lets the fresh majority stay
  quiet below.
- **Each row shows source + cadence, a relative + absolute last-refresh time, a
  success/failed/stale status glyph, and a per-row "Refresh now" button** (T1).
  These are the three per-item facts the captain named; the glyph reuses the
  project's currentColor shape vocabulary so status reads without colour alone.
- **The header strip is a segmented count band: Automatic, Manual, Stale, plus a
  ratio bar** (T1). The captain asked for auto-vs-manual counts; the ratio bar and
  the stale count give that comparison at a glance in the project's card idiom.

## Open questions
- When "Refresh now" is pressed, should it kick off a real collection run and
  reflect live progress, or just re-request the latest value? The mockup shows an
  optimistic spinner that flips the row to fresh.
- Should manual KPIs be reachable from this screen (e.g. a "switch to automatic"
  action), or is this screen strictly a read-only health view of the auto set?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements
1. List every KPI that is collected automatically (T1).
2. For each, show its per-item refresh state: when it was last refreshed, whether
   the last refresh succeeded or failed, and a small "refresh now" control (T1).
3. Group the ones that are stale to the top (T1).
4. Add a header strip showing how many KPIs are on automatic collection versus how
   many are still manual (T1).

### 2. Implied by the mockup, not yet settled
- What threshold makes a KPI "stale"? The mockup flags overdue-past-cadence, but
  the actual staleness rule is not stated.
- Does "Refresh now" trigger a real collection run with live progress, or just a
  re-fetch of the last value?
- The header strip's "Stale" count and ratio bar are drawn but not wired — should
  the Stale count be clickable to jump to that group?
- Is the ordering within the stale group oldest-first by design, or should failed
  runs always sort above merely-overdue ones?

### 3. Out of scope

## DECLARED FLOW
`auto-metrics` → click `.btn` Refresh now on a row → row shows spinner, then flips to fresh `Succeeded` state in place
`auto-metrics` → click `.icon-btn` Theme → toggles `data-color-mode` dark/light, same screen

## DATA PRECONDITIONS
Each KPI carries a collection mode (automatic vs manual) so the two cohorts can be counted and the list filtered to the automatic set.
Auto-collected KPIs record a last-refresh timestamp and a last-run outcome (success/failure) per item.
Each auto-collected KPI has a known collection cadence, so "overdue / stale" can be computed against it.
