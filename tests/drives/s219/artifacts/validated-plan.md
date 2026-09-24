# Validated Plan: MBR View Builder

## Synthesis

The Mission rebuilds the MBR (Monthly Business Review) authoring experience to match the
attached mockup across three screens — a **Reviews entry** list, a **Collection** ("Pull
data & start") progress screen, and a redesigned **Builder** — plus a shared read-only
**Preview/View** rendering, all backed by real state and local-disk persistence. The 16
research findings agree on one internally consistent plan; there are no contradictions to
resolve between them, and none of them contradicts the grounded ADRs Align seeded. Below I
fold them into a single build.

**Routing & screens (R9).** Keep one `mbr` RouteView but namespace the four screens as
segmented sub-routes parsed exactly like the existing `#locked/<id>` pattern: `#mbr`
(Reviews entry) → `#mbr/collect` → `#mbr/build` → `#mbr/preview`. Extend `parseHash` so
head `mbr` reads `rest[0]` into a new `step` field (defaulting to the Reviews entry when
absent). App keeps dispatching the whole family to the single DEV-gated `MbrBuilderView`,
which switches on `route.step`. Transitions: Continue-to-builder `#mbr/collect → #mbr/build`;
Preview `#mbr/build → #mbr/preview`; back-out `#mbr/preview → #mbr/build`; Cancel (collect)
and Discard (after confirm) both unwind to `#mbr`.

**Production purity (R8).** The Reviews entry, Collection, Builder, and Preview are all
authoring surfaces and MUST stay behind `import.meta.env.DEV`, exactly like today's
`MbrBuilderView`/`EditRosterView`, so Rollup tree-shakes them and `build-purity.test.ts`
stays green. Only the read-only published-month view served by the existing `#locked/<id>`
`LockedView` route (the "View" button target) ships in the production bundle — it renders
committed immutable snapshot JSON with no write path. Preview, despite feeling view-like, is
a *pre-publish* authoring step and is DEV-gated; its post-publish public equivalent is
precisely the `LockedView` render (ADR-002).

**Reviews entry & the "Next up" month (R5, R16).** "Next up · {Month Year}" is a *display
label only*: group existing snapshots by their human `month` field (or the id's `YYYY-MM`
date prefix), find the calendar month after the newest review, and render it as an
unstarted start card. When a draft is actually started, mint its id with the canonical
date-keyed `YYYY-MM-DD.N` scheme via `nextDraftId(existingIds, today)` (ADR-003) — never a
bare `YYYY-MM`, which would collide with the legacy id form and break numeric ordering. The
human `month` string ("August 2026") drives the by-month grouping of the Reviews/Published
lists; id and month label are separate concerns. **If an unlocked draft for the next month
already exists on disk, the start card offers "Continue draft" (resume in place), NOT a
"Pull data & start" reseed** — reseed is destructive and must stay behind the confirmed
Discard path. The Published list shows prior locked months with lock icon, "Published" chip,
"M KPIs · locked {date}", and a "View" button.

**Collection engine (R4).** Drive "Pull data & start" off the REAL per-KPI endpoint
`POST /__collect/<kpiId>` (the shelled-out Copilot CLI, concurrency 1, 240s per-KPI
timeout), NOT the fast stub `POST /__mbr/refresh`. Model per-bucket "Queued → Collecting… →
N values pulled" as an aggregation over sequential per-KPI runs, advancing the bar as each
KPI finishes, mirroring `UpdateKpisView`'s existing sweep and per-row state chips. Real
collection is minutes, so the collection *screen* shows honest per-KPI substeps and estimate
rather than a single fast spinner. **The static "~30s · re-pullable anytime" hint on the
start card is mockup wording and a visual acceptance criterion — render it verbatim on the
start card** (LOOK is the mockup's authority); the collection screen's live progress is the
surface that reflects true latency. "Continue to builder" stays disabled until the pull
finishes; Cancel returns to `#mbr`.

**Auto vs manual partition (R3).** Auto/Manual (the tags, Collect controls, and the "N of M
automated" count) is derived from a **non-empty `aiUpdateInstructions`** (trim-strict
predicate), resolved from the roster/`config.json` as the sole authority — the same
`isAutomatable`/`resolveAutomatable` predicate `UpdateKpisView` uses — NOT the two-id
hardcoded `WIRED_METRIC_IDS` list (which is a separate, narrower refresh-wiring signal). The
"11 of 14" figure is `automatableCount` over the flattened draft
(`draft.buckets.flatMap(b => b.kpis)`).

**Refresh-all (R12).** The auto-only re-pull reuses the standalone collection pipeline
(`UpdateKpisView`'s per-row Collecting/✓ chips + indeterminate `.update-progress` strip);
do NOT build a second chip pipeline inside the builder. Lay it out as the mockup does: the
amber `.warn-line` box carries ONLY the "11 of 14 automated · manual KPIs unchanged" text;
the indeterminate progress strip is a SEPARATE sibling below the action bar — the strip is
not nested inside the amber box.

**Deltas & value parsing (R1, R6, R11).** Add a single pure, unit-tested helper
`parseMetricValue(raw): { n, unit } | null` that strips leading inequality/qualifier tokens
(`<= >= < > ~ approx`), matches the first signed decimal (`-?\d[\d,]*(?:\.\d+)?`, commas
stripped), and normalizes the trailing unit (`% days s /day` …). Compute a delta ONLY when
both current and previous parse to a number AND share the same normalized unit; otherwise
render a neutral em-dash `—` (no arrow/sign) — so `WIP`, `<= 1 day`, etc. never yield a
misleading numeric delta. For cohort `SubReading[]`, diff **per matching `label`** (order
only as a fallback tie-breaker; `SubReading` has no id), never across the whole array.
**When no prior published MBR baseline exists** (first-ever MBR, or a KPI/source absent from
the last published MBR): render `—`, do NOT emit "no change" or "0"; a subtle "new" badge
only for a KPI/source genuinely new against an *existing* prior snapshot. "no change" is
reserved strictly for a baseline that existed and is unchanged. Editing a manual value
recomputes its delta automatically (delta is never hand-typed); cohort per-source deltas
likewise recompute on inline sub-row edit, matched by label.

**Persisted derived/provenance fields (R2).** Add optional per-`Kpi` fields —
`previousValue?: MetricValue` (backs "was {old}" and the scalar delta), `delta?: string`
(pre-computed display string), `sourceDeltas?: SubReading[]` (per-cohort-source deltas,
reusing `{label,value}`), and `carried?: boolean` (provenance flag replacing the in-memory
`Set`) — plus `Snapshot.lastEditedAt?: string` (ISO, stamped by the draft save path). All
optional for backward compatibility with locked snapshots. Compute/stamp these at
seed/refresh time so read-only View/Preview is pure display of stored data, not
render-time recomputation.

**Target sourcing & manual seeding (R15).** Freeze `target` into the draft snapshot at
pull/seed time (`reconcileRoster`/`buildSnapshot` copy `config.target` into the JSON so a
locked MBR is self-contained and immutable per ADR-002); the live Default view keeps
mirroring `config.json` read-only via the pure `overlayRoster`. A draft's target is
snapshotted at pull, not continuously mirrored. Manual KPIs seed "From default view · edit
to override" by carrying forward the KPI's committed `value` (via `manualSeedValue`) from
the latest snapshot, matched by stable id; that seed stays editable until lock.

**Carried provenance (R14).** "No fresh value" is detected purely by ABSENCE of a source
reading for that KPI id in the current pull — both a collection failure and an empty result
collapse to the same missing entry and carry value/status/insight forward. An *unchanged but
emitted* value is treated as fresh (clears the badge). **Fix the latent bug:** move `carried`
onto persisted `Kpi.carried`, and clear it when the user manually overwrites that KPI's value
(a manual entry IS a fresh value, so provenance is no longer "carried"). Re-pull preserves
Carried for KPIs that still return no fresh value.

**Status marker (R13).** The label↔enum mapping is confirmed: positive=On track,
warning=Watch, negative=Off track, neutral=Tracking, wip=WIP. The AC mandates the off-track
marker be an **X shape**, but today `STATUS_META.negative.shape` is `'diamond'`. Change it to
a new `'x'` shape in `src/lib/status.ts` (single source of truth — this updates the off-track
marker app-wide, which is correct and intended), add a matching `.status-dot--x` rule in
`src/styles.css`, and update the disk-reading shape tests (`status.shape.test.ts`) that
currently assert `'diamond'`. The other four markers are unchanged. Status is an editable
select over the five silhouettes, seeded from the scorecard on pull, human-only, never
auto-recomputed.

**Autosave & "last edited" (R10).** Insights autosave on blur and debounce at **800ms** of
typing-inactivity before `PUT /__data/snapshots/<id>`, with a flush on blur/before-unload so
no edit is lost. Render "Last edited {t}" as an **absolute, UTC-pinned locale timestamp** via
the existing `src/lib/date.ts formatDate()` (deterministic and testable) — not a live "2 min
ago" string. A non-empty insight gets the distinct filled background and counts toward the
completion meter.

**Lock model & LockedView reuse (R8's sibling — lock findings, ADR-003).** Locking is
month-only; the lock gate is every KPI having non-empty insight text. When locked, all
buckets render read-only solely because the month is locked. Set `Snapshot.lockedBy = null`
on newly locked snapshots (keep the `string | null` type); do NOT delete `LockedView`'s
provenance/amendments rendering — instead **hide the "Locked by {handle}" line when
`lockedBy` is null** (guard the span so it never prints "Locked by —") and RETAIN the
Amendments section unchanged (it already renders nothing when empty). This drops the removed
fields from the new flow while still faithfully rendering historical snapshots that carry a
handle/amendments. Preview and View share one presentation component, differing only in
draft-vs-snapshot source, reusing the `LockedView` path.

**Theme.** Drop the mockup's builder-local theme toggle; the builder follows the app's
global theme (single source of truth per CONTEXT.md).

## Decisions

- **Routing:** one `mbr` RouteView, sub-routes `#mbr` / `#mbr/collect` / `#mbr/build` /
  `#mbr/preview`; extend `parseHash` to read `rest[0]` into a `step` field defaulting to the
  Reviews entry; bare `#mbr` → Reviews entry.
- **DEV gating:** Reviews entry, Collection, Builder, Preview all behind
  `import.meta.env.DEV`; only `#locked/<id>` `LockedView` ships in production.
- **"Next up" month:** a computed display label = calendar month after the newest existing
  review, grouped by the human `month` field / id `YYYY-MM` prefix.
- **Draft id:** minted via `nextDraftId(existingIds, today)` → date-keyed `YYYY-MM-DD.N`;
  never a bare `YYYY-MM`.
- **Existing unlocked draft:** start card shows **"Continue draft"** (resume in place), not
  "Pull data & start"; reseed stays behind the confirmed Discard modal.
- **Collection:** driven by real `POST /__collect/<kpiId>` (concurrency 1, 240s timeout),
  aggregated per-bucket; NOT the `/__mbr/refresh` stub. Live per-KPI progress on the
  collection screen; keep the static "~30s · re-pullable anytime" hint verbatim on the start
  card (mockup-authoritative LOOK).
- **Auto/Manual partition & "N of M" count:** derived from trim-strict non-empty
  `aiUpdateInstructions` resolved from the roster; NOT `WIRED_METRIC_IDS`.
- **Refresh-all:** reuse the standalone collection pipeline's per-row chips + indeterminate
  strip; "11 of 14" text in the amber `.warn-line`, progress strip as a separate sibling
  below the action bar (not nested in the box).
- **Delta parsing:** add pure `parseMetricValue`; delta only when both sides parse and units
  match, else `—`; cohort diffs matched by `label`.
- **Missing baseline:** render `—` (never "0"/"no change"); "new" badge only for a genuinely
  new item against an existing prior snapshot; first-ever MBR shows `—` everywhere.
- **New persisted fields:** `Kpi.previousValue?`, `Kpi.delta?`, `Kpi.sourceDeltas?`,
  `Kpi.carried?` (all optional) and `Snapshot.lastEditedAt?`; computed/stamped at
  seed/refresh, not at render.
- **Targets:** frozen into the draft snapshot at pull/seed via `reconcileRoster`; Default
  view mirrors config read-only via `overlayRoster`.
- **Manual seed:** carry forward the committed `value` by stable id ("From default view ·
  edit to override"), editable until lock.
- **Carried detection:** absence of a source reading = carried; unchanged-but-emitted =
  fresh; persist on `Kpi.carried`; clear it when the user manually overwrites the value; a
  re-pull preserves Carried for still-missing KPIs.
- **Status marker:** confirm five-label↔enum mapping; change `STATUS_META.negative.shape`
  from `'diamond'` to a new `'x'` shape, add `.status-dot--x` CSS, update
  `status.shape.test.ts`; status is a human-only editable select, seeded on pull.
- **Autosave:** 800ms debounce + blur/before-unload flush; "Last edited {t}" as an absolute
  UTC-pinned `formatDate()` timestamp.
- **Lock:** month-only, gated on every KPI having a non-empty insight; `lockedBy = null` on
  new locks; hide the "Locked by" line when null; retain Amendments rendering; reuse
  `LockedView` for both Preview and View via one shared presentation component.
- **Theme:** drop the builder-local toggle; follow the global theme.

## Rationale

- **Sub-routes under one `mbr` view** keep App's production dead-code guard
  (`route.view === 'mbr'`) and `useHashRoute`'s `KNOWN_VIEWS` untouched — no new top-level
  view to gate or strip — while reusing the proven `#locked/<id>` `[head, ...rest]` parse.
  Cancel/Discard unwinding to `#mbr` and the reversible Preview↔build hop give natural
  browser Back behaviour.
- **DEV gating** is a binding repo invariant (CONTEXT.md, ADR-003): every write path
  (`/__data`, `/__mbr`, `/__collect`) is dev-only and `build-purity.test.ts` fails on any
  leaked editing marker. `LockedView` is fundamentally different — a shareable read-only
  render of committed immutable JSON — so it must stay public; no viewing capability is lost.
- **Date-keyed ids** are enforced repo-wide (ADR-003); a bare `YYYY-MM` id would collide
  with the legacy form and break lexical/numeric ordering. Month is a label, not an
  identifier, so grouping keys off `month` while the id stays date-keyed.
- **Real `/__collect`** is the only endpoint that actually collects per-value data; the
  `/__mbr/refresh` stub only emits readings for a tiny wired set and carries everything else
  forward. The brief's "build for real" overrides the mockup's faked ~30s collection, but
  the *start-card wording* is a LOOK matter where the mockup is authoritative, so it is kept
  verbatim while the collection screen tells the truth about latency.
- **`aiUpdateInstructions` as the automatability signal** is the single canonical rule
  (CONTEXT.md, ADR-002) — there is deliberately no `autoUpdate` field. `WIRED_METRIC_IDS`
  (two ids) is a narrower refresh-wiring detail and must not drive the "N of M" count, or the
  displayed automation figure would be wrong.
- **Parse-then-compare with unit guarding** is the only robust way to diff the heterogeneous
  free-text `MetricValue` corpus (scalars, %, durations, rates, inequalities, `WIP`); a
  neutral `—` for incomparable/missing values keeps the delta trustworthy. Matching cohort
  sub-readings by `label` is forced by the data model — `SubReading` carries no id and labels
  can be added/renamed between months, so positional subtraction is undefined.
- **Persisting derived/provenance fields** (rather than recomputing at render) makes the
  read-only View/Preview a pure display of stored data and preserves provenance across the
  component-state boundary — the current in-memory `carried` Set is lost once the component
  unmounts, and locked snapshots must be self-contained (ADR-002/ADR-004/ADR-005). All fields
  optional so older locked snapshots still load.
- **Freezing targets at pull** upholds snapshot immutability/audit while `overlayRoster` still
  gives live editors an up-to-date Default view — the codebase already splits these two
  mechanisms by design.
- **Carried = absence of a fresh reading** matches `buildSnapshot`'s existing
  `if (!fromSource) return kpi` carry-forward; treating a manual overwrite as clearing the
  badge fixes a real latent bug (today `editKpi` never touches the carried Set, so a
  manually-corrected carried KPI wrongly keeps the badge) and aligns with the provenance
  definition — a hand-entered value is not "carried from last MBR".
- **The X marker** is an explicit acceptance criterion for colourblind distinctness; because
  `STATUS_META` is the single source of truth for status shape, editing it there is the
  correct, minimal change and it necessarily (and intentionally) updates the off-track marker
  everywhere the app renders status — consistent with CONTEXT.md's "one source of truth" and
  "shape *and* colour" accessibility rule. The disk-reading shape test currently pins
  `'diamond'`, so it must be updated in the same change.
- **800ms debounce + absolute UTC timestamp** matches established autosave ergonomics and the
  repo's deterministic-timestamp convention (`date.ts` pins `timeZone:'UTC'` so CI and every
  viewer see the same string); a relative "2 min ago" label is non-deterministic, needs a
  re-render timer, and is untestable without clock-mocking.
- **`lockedBy = null` + hide-when-null** is correct because the app has no auth/identity — the
  handle field the redesign removes was the only source of `lockedBy`. Hiding rather than
  deleting the `LockedView` provenance/amendments render preserves faithful rendering of
  already-committed historical snapshots that carry a handle and amendments.
- **Month-only lock gated on insight completeness** and **one shared Preview/View component**
  make the completion meter, the lock gate, and "what gets published" express the same
  condition and guarantee Preview is faithful to the published output (ADR-002/ADR-003) — the
  mockup's per-bucket lock affordances and builder-local theme toggle are deliberately not
  built, per the captain's resolved decisions.
