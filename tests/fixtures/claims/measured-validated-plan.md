# Validated Plan: fixture A (the MEASURED Mission)

## Synthesis

Elided — this fixture exists for the `## Decisions` section, copied
VERBATIM from the measured Mission's validated-plan.md.

## Decisions

- Keep all three MBR screens (Reviews, Pulling data, Builder) as an internal
  screen-state enum inside `MbrBuilderView` under the single existing DEV-gated
  `#mbr` route; do not add new routed views. Default landing = Reviews; advance to
  Builder on open/create via existing `latestOnDiskDraft()`/resume logic.
- Reuse `LockedMBR({ snapshot })` as the single read-only renderer. **View** →
  navigate to `#locked/<id>` (loads locked snapshot from disk). **Preview** →
  render `LockedMBR` inline as a builder screen-state fed the live in-memory draft,
  with a Back affordance. Both run the same computed-field logic.
- Reviews "next unstarted month" = max on-disk snapshot period + 1 calendar month;
  draft id = that `YYYY-MM`; wall-clock month only as cold-start fallback when no
  snapshots exist.
- If a `status:'draft'` snapshot exists for the next month, show a "Resume draft"
  card (amber draft accent + "Draft — in progress" pill) that opens the builder on
  the loaded draft without re-seeding; otherwise show the neutral "Pull data &
  start" card.
- Source the Published list from `selectLockedSnapshots(snapshots)` (newest-first);
  label with the snapshot's `month`, `locked {formatDate(lockedAt)}` (`—`
  fallback), and a KPI count = Σ `bucket.kpis.length` (pluralised).
- "Pull data & start" fires ONE `POST /__mbr/refresh` (`refreshMbr()`) rebuilding
  the whole draft; per-bucket Queued→Collecting→done is a client-side animation
  over that single call. "Continue to builder" enables on animation completion.
- Pulling-data **Cancel is non-destructive**: return to Reviews, leave the pulled
  draft persisted on disk; never delete it (Discard is the only destructive path).
- Classify Auto vs Manual by `aiUpdateInstructions.trim() !== ''` (repo ADR-002);
  no `WIRED_METRIC_IDS`, no new boolean flag.
- Add a persisted per-KPI `origin: 'carried' | 'collected' | 'manual'` field to the
  draft Kpi. `reconcileRoster` carry-forward → `carried`; a source collect →
  `collected` (stamp `asOf`); a manual value edit → `manual`. "Carried" pill shows
  iff `origin==='carried'`.
- Delta "vs last MBR" = this-month value − `latestLockedSnapshot` value, matched by
  KPI id (sub-deltas by `SubReading.label`); auto-recompute on value change. No
  prior locked MBR, a new KPI/source, dropped source, or non-differenceable value →
  render explicit `—`/"new" marker, never a from-zero/percentage delta. Keep rows
  for both new and dropped sources.
- Seed status from the last MBR's carried `status` field (config carries none);
  set in builder via the silhouette select, overridable, written to the same
  `status` field; do NOT auto-recompute status from value.
- No-target KPI → render target as `—`, seed empty editable value, neutral status,
  skip all target-derived delta/status logic (target stays free-text/optional).
- Lock is per-month only. "Lock month" (amber primary) locks the whole snapshot;
  buckets render the "Locked" look together; a single month-level "Unlock" restores
  editability. No per-bucket lock field. Button DISABLED until every KPI has a
  non-empty (trimmed) insight; Lock dialog shows coverage toward that gate.
- "Bucket complete" = all its KPIs have a non-empty (trimmed) insight; the draft-
  banner "N of 5 buckets complete" and the "Insights added — N of M" bar both key
  off insight-presence only.
- Remove the `lockedBy` handle field and the unlock amendment-note field from the
  UI and write path; RETAIN `lockedBy`/`amendments` as optional read-only schema
  fields for backward-compatible rendering of historical snapshots.
- Autosave every edit (values + insights) on a ~500 ms trailing debounce (flush on
  blur/unmount/navigation and before lock) via the existing whole-snapshot
  `saveSnapshot` → `PUT /__data/snapshots/<id>`; no new partial write path.
- "Update all automatically" (in the amber warning box) re-collects Auto KPIs only,
  leaving Manual values and all insights untouched, behind an indeterminate strip.
- Update `MbrBuilderView.lock.test.tsx` and the other affected lock/unlock/refresh
  suites to the month-level, no-handle, no-note model; keep the full suite (incl.
  `build-purity.test.ts`) green. Do not touch the mockup or `docs/mocks/`.

## Rationale

Elided.
