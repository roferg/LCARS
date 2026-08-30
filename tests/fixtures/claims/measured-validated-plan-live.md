# Validated Plan: fixture A2 (the SECOND measured run, 2026-08-30)

## Synthesis

Elided. This fixture exists for the `## Decisions` section below, copied
VERBATIM from the live capstone run's validated-plan.md — the run on which B2
stayed silent because the Validator wrote its prohibition in its own words
("do not conflate with `X`") instead of the one phrasing B2 had been built for
("no `X`").

## Decisions

- **Persistence split (Findings 1, 2, ADR-002).** Move the in-progress draft to
  browser `localStorage` under a namespaced key (e.g. `dx-scorecard-mbr-draft`),
  storing `{ snapshot: Snapshot, carried: string[] }`, autosaved on change,
  hydrated on mount (fall back to on-disk draft when the key is absent). Stop
  calling `saveSnapshot()` on every edit. The **only** write to
  `data/snapshots/<id>.json` (via the existing dev-write `PUT`) is at **lock**;
  clear/replace the localStorage entry once locked. Follow the existing
  `useColorMode` localStorage convention (typed load/save helper, guarded for
  `typeof window` and `JSON.parse` failure).
- **Shared store = git-committed snapshots (Finding 2).** Locking writes the
  locked `Snapshot` to `data/snapshots/<id>.json`; git commit/merge to `main`
  (GitHub Pages) is the "publish". No new persistence target.
- **DEV-only authoring surface (Finding 3).** Landing, collect, and builder stay
  gated behind `import.meta.env.DEV` so Rollup tree-shakes them out; only the
  read-only published View ships. Keep `build-purity.test.ts` green.
- **Routing (Findings 4, 14).** Add a `reviews` head to `parseHash`
  (`useHashRoute.ts`): `#reviews` (landing), `#reviews/collect` (data-pull),
  `#reviews/<month>` (per-month builder, id after head like `#locked/<id>`).
  **Reuse `#locked/<id>` for the published "View"** — do not mint a new route
  (optionally relabel the nav entry to "View").
- **Next-month rule (Finding 5).** Target month = current calendar month
  (`now → YYYY-MM`), matching the refresh pipeline default. If a local draft for
  that month already exists, **resume** it; re-pull is a separate explicit action
  (never clobber in-progress insights/status silently).
- **Single shared renderer (Finding 14).** Extend `Scorecard` (+ `LockedMBR`
  provenance wrapper) with a published-review mode prop; add the "This
  month"/"target N" value-column header and per-source delta cells to the existing
  `kpi-head`/`kpi-row` — do not author a parallel component. Preview = live draft
  (no lock), View = locked snapshot.
- **Auto/Manual classification (Finding 9).** Derive from `aiUpdateInstructions`
  via the existing `isAutomatable` predicate (non-empty after trim = Auto).
  Populate that per-KPI field in `data/config.json` to make KPIs Auto; do not grow
  a hardcoded id list and do not conflate with `WIRED_METRIC_IDS`.
- **Collection source & Cancel (Finding 11).** Auto values come from the live
  per-KPI `POST /__collect/<kpiId>` (`collectKpi`) cycle already used by Update
  KPIs — not `/__mbr/refresh`, not simulated. Collected values live in in-memory
  React state; Cancel discards all partial results, writing nothing.
- **Status mapping & authoring (Finding 12, ADR-003).** Use `STATUS_META` as the
  single label↔enum source (On track→positive, Watch→warning, Off track→negative,
  Tracking→neutral, WIP→wip). Seed from the draft KPI status; overridable; never
  auto-recompute on value change.
- **Deltas (Findings 8, 15).** Compute delta by extracting the leading signed
  numeric magnitude (+unit) from the `MetricValue` string, normalising units, and
  subtracting the same KPI id's value in the previous **locked** snapshot; sign
  (with a float epsilon) gives up/down/no-change; polarity comes from the `target`
  comparator (`<=` lower-is-better, `>=` higher-is-better); colour with existing
  `--status-positive/-negative/-neutral` tokens. Non-numeric / unit-mismatch /
  cohort-scalar-mismatch / missing-prior ⇒ neutral, suppress the badge. Cohorts
  match per **SubReading label** (trim, case-insensitive); unmatched member ⇒ new,
  no delta.
- **Manual cohort editing (Finding 15).** Reuse the existing `ManualValueEditor`
  pattern: one editable row (label+value) per SubReading with add/remove, re-derive
  `MetricValue` on change; seed cohort members from the default-view latest.
- **Model changes (Findings 6, 7, 15).** Retain `lockedBy` (default null on lock)
  and `amendments[]` (leave empty). Add `Snapshot.lastEditedAt: string`
  (ISO), bumped on every content autosave (value/status/insight) on draft
  snapshots only. Add optional `Bucket.lockedAt`/`Bucket.lockedBy`; per-bucket
  "Locked" badge derives from `lockedAt != null`; persist inline on the draft's
  embedded `buckets[]`; never touch `ConfigBucket`.
- **Completion metrics (Finding 13).** KPI "done" = non-empty trimmed insight.
  Bucket complete = all its KPIs have a non-empty insight. "Insights added — N of
  M KPIs" and "N of {buckets.length} buckets complete" derive from the live
  snapshot; do not hardcode 5. Status is a separate axis and never gates
  completion.
- **Tests (Finding 17).** Rewrite existing `MbrBuilderView.*` and
  `LockedView.test.tsx` assertions to the new copy/controls (drop "New MBR",
  "Refresh all data", trailing status line, handle/amendment-note assertions);
  preserve surviving contracts (DEV gating, dev-write persistence at lock,
  provenance). Add co-located tests for the Reviews landing and data-pull screens.
- **Theme / copy (PRD).** Builder follows the global app theme (no page-local
  toggle). Eyebrow "Monthly Business Review"; title "MBR builder · {month}";
  subtitle per PRD. "Carried" pill (uppercase, clock icon, WIP/purple) shows while
  value still equals the carried-forward value; clears on collect (auto) or edit
  (manual). Discard/Lock/Unlock are centered overlay dialogs (Cancel/Esc/backdrop
  dismiss); Lock dialog drops the handle field and summarises insight coverage;
  Unlock has no note field and re-opens a single bucket; "Update all
  automatically" sits in the amber warning box and re-collects only automated
  KPIs.

## Rationale

Elided.
