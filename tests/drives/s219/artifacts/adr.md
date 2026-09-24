# Architecture Decision Records: MBR View Builder

## ADR-001: Local-only persistence for drafts and snapshots

**Context:** The mockup's draft banner implies autosave and a published archive, and the app today already persists drafts to `data/snapshots/<id>.json` and publishes via commit + PR. A synced backend would materially expand scope.
**Decision:** Keep persistence local-only. The draft autosaves to `data/snapshots/<id>.json` through the existing dev-write bridge; "Lock month" writes the immutable snapshot locally; publishing stays the existing commit/PR path. No server-side store is introduced.
**Alternatives considered:** A synced backend service for drafts/snapshots — rejected as out of scope and inconsistent with the app's current local-dev model.
**Consequences:** No new service, auth, or network layer. Autosave and "last edited" are backed by local writes. The builder cannot rely on cross-device sync, which is acceptable for the current single-workstation authoring flow.

## ADR-002: One shared read-only render component for Preview and published View

**Context:** Preview (of the current draft) and View (of a locked published month) must render identically to what publishes, and the app already has a LockedView rendering path.
**Decision:** Preview and View use a single shared read-only presentation component, differing only in their data source (live draft vs immutable snapshot). It reuses the existing LockedView path.
**Alternatives considered:** Separate bespoke renderers for Preview and View — rejected as duplicative and prone to drift between "what you preview" and "what ships".
**Consequences:** Preview is guaranteed faithful to the published output. Locked-month read-only rendering and Preview share one implementation; changes to published presentation affect both by construction.

## ADR-003: Month-only lock model gated on insight completeness

**Context:** The mockup draws both per-bucket unlock and a month-level lock, but the captain's rule is month-only locking, and the lock gate is every KPI having a non-empty insight (LAW 2). WHAT-IT-MUST-DO overrides the mockup's look here.
**Decision:** Locking is per-month only. A month locks (and thereby publishes) only when every KPI has non-empty insight text; when locked, all buckets render read-only purely as a consequence of the month being locked, and the only unlock is unlocking the whole month. No per-bucket lock state, badge, unlock control, or per-bucket unlock dialog exists.
**Alternatives considered:** Per-bucket locking as the mockup literally draws it — rejected as contradicting the captain's per-month model and splitting the commitment gate.
**Consequences:** The completion meter, the lock gate, and "what gets published" all express the same condition. The mockup's per-bucket lock affordances are deliberately not built.

## ADR-004: Derived deltas, human-owned status, config-sourced targets

**Context:** Each KPI surfaces a value, a target, a delta-vs-last-MBR, and a status. Some are objective/derivable and some are editorial judgements.
**Decision:** Value and target arrive with the data pull (target from the KPI's config/default view). Delta-vs-last-MBR is always computed (this month's value minus the same KPI's value in the previous published MBR) and recomputes whenever a manual value is edited — it is never hand-typed. Status is seeded from the scorecard on pull but only ever changed by a human; it is never auto-recomputed.
**Alternatives considered:** Hand-entered deltas, or auto-recomputing status from value changes — rejected because deltas are purely derived and status is an editorial call for the month.
**Consequences:** Deltas are consistent by construction; editorial control of status is preserved. The builder must retain access to the previous published MBR to compute deltas and carry-forwards.

## ADR-005: "Carried" is pull-time provenance, distinct from status

**Context:** The mockup shows a purple "Carried" pill, and the off-track status marker must remain unambiguous.
**Decision:** A KPI is Carried when a data pull returns no fresh value and the builder carries forward the previous published MBR's value/status. Carried is an objective, computed-at-pull-time provenance flag, rendered as its own pill and kept entirely separate from the five-silhouette status marker.
**Alternatives considered:** Deriving Carried from status (e.g. off-track/unresolved) or an explicit per-KPI carry choice — rejected to avoid overloading status with provenance meaning.
**Consequences:** Provenance and status are independent signals. Re-pull preserves Carried state for KPIs that still return no fresh value.
