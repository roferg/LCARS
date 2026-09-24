# Implement — per-ticket results (from tickets/<id>/result.json, flip-flop.json, events)

## t-001 · Extend the snapshot data model with derived/provenance fields
- passed: True · worker sessions: 1 · result.attempts: 3
- new tests: src/types.provenance.test.ts · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 5/5)
- summary: Added optional Kpi fields (previousValue, delta, sourceDeltas, carried) and Snapshot.lastEditedAt to shared/types.ts, all optional for backward compatibility. sourceDeltas reuses the existing SubReading {label,value} shape. Proved the type-level contract with a compiler-API test (like build-purity runs a real build) that compiles fixtures against shared/types.ts and asserts on diagnostics; green on the new tree, red on the parent (unknown-property errors).
  - ticket_test_edits: ticket t-001 test-edit declarations verified against the diff vs aced269de6df6009b4c73288661104e5cf98ed33 (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-001 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-001 verified green on the committed branch
  - ticket_green: ticket t-001 green

## t-002 · Add MBR sub-route steps and dispatch each to its screen slot
- passed: True · worker sessions: 1 · result.attempts: 2
- new tests: src/lib/useHashRoute.step.test.ts, src/views/MbrBuilderView.steps.test.tsx · declared test edits: src/lib/useHashRoute.test.ts (parseHash('#mbr') now returns { view: 'mbr', step: 'start' } per this ticket's n), src/views/MbrBuilderView.test.tsx (This ticket moves the draft builder to the #mbr/build sub-route; #mbr now shows )
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 445/445)
- summary: Extended parseHash so #mbr reads rest[0] into a new Route.step ('start'|'collect'|'build'|'preview'), defaulting to 'start' when absent or unknown (mirroring #locked/<id>). MbrBuilderView now dispatches route.step to a distinct screen slot: start/collect/preview are thin placeholders (data-testid mbr-slot-<step>) and the existing full builder is the 'build' slot; App passes route.step. KNOWN_VIEWS and the DEV gate are unchanged, so a stray #mbr still resolves to Default on the production build. Full suite green (520 tests) and typecheck clean.
  - ticket_test_edits: ticket t-002 test-edit declarations verified against the diff vs aced269de6df6009b4c73288661104e5cf98ed33 (4 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-002 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-002 verified green on the committed branch
  - ticket_green: ticket t-002 green

## t-003 · Add pure metric-value parsing and delta computation helpers
- passed: True · worker sessions: 1 · result.attempts: 1
- new tests: src/lib/metricDelta.test.ts · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, missing-new-module — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 0/19)
- summary: Added pure src/lib/metricDelta.ts with parseMetricValue (strips <= >= < > ~ approx qualifiers, first signed decimal with commas removed, normalized trailing unit), computeDelta (signed magnitude with shared unit; null when either side unparseable or units differ), and computeSourceDeltas (cohort diffing matched by label with order as tie-break, neutral placeholder for incomparable sources). No IO, no Date, no import.meta.env. 19 co-located tests green on first run; typecheck clean.
  - ticket_test_edits: ticket t-003 test-edit declarations verified against the diff vs aced269de6df6009b4c73288661104e5cf98ed33 (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-003 — tests GREEN on tip, RED on parent (missing-new-module)
  - ticket_postcommit_ok: ticket t-003 verified green on the committed branch
  - ticket_green: ticket t-003 green

## t-004 · Change the off-track status marker to an X shape app-wide
- passed: True · worker sessions: 1 · result.attempts: 1
- new tests: — · declared test edits: src/lib/status.shape.test.ts (Ticket per ADR-006 renames the off-track marker shape from 'diamond' to 'x'; the), src/styles.status-dot.test.ts (The rule-existence loop iterated the modifier names including 'diamond'; the off)
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 435/435)
- summary: Changed STATUS_META.negative.shape from 'diamond' to 'x' and updated the StatusMeta shape union in src/lib/status.ts; replaced the .status-dot--diamond CSS rule with a colour-independent .status-dot--x rule drawing two crossed strokes (transparent background, crossed currentColor gradients) distinct from the on-track filled circle; updated the two disk-reading shape tests to assert/iterate 'x'. Full suite green (510 tests) and tsc clean.
  - ticket_test_edits: ticket t-004 test-edit declarations verified against the diff vs aced269de6df6009b4c73288661104e5cf98ed33 (2 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-004 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-004 verified green on the committed branch
  - ticket_green: ticket t-004 green

## t-005 · Build the Reviews entry screen with the Next-up start card
- passed: True · worker sessions: 1 · result.attempts: 3
- new tests: src/views/MbrBuilderView.startScreen.test.tsx · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 8/8)
- summary: Built the Reviews entry screen (#mbr/start): a 'Next up' start card for the calendar month after the newest published review (grouped by YYYY-MM id prefix) with the 'N buckets · M KPIs · Source: DX Scorecard (live)' meta from the live config roster, a green 'Pull data & start' button and the verbatim '~30s · re-pullable anytime' hint; a grouped 'Published' list (lock icon, green 'Published' chip, 'M KPIs · locked {date}', 'View' → #locked/<id>). Pull mints a date-keyed draft id via nextDraftId and moves to #mbr/collect; an existing unlocked next-month draft flips the primary action to 'Continue draft' that resumes in place without reseeding. Added month-grouping helpers (monthKeyOf/nextMonthKey/publishedReviewMonths), a pending-draft handoff store, monthLabel/todayIso, and ported the start-screen classes into styles.css. Full suite green (552).
  - ticket_test_edits: ticket t-005 test-edit declarations verified against the diff vs 65761616991c65d9d273f6fd4480252b350405f4 (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-005 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-005 verified green on the committed branch
  - ticket_green: ticket t-005 green

## t-006 · Build the collection screen and seed the pulled draft
- passed: True · worker sessions: 2 · result.attempts: 3
- new tests: src/views/MbrBuilderView.collect.test.tsx · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 10/10)
- summary: Built the #mbr/collect screen: MbrCollectSlot runs the real per-KPI POST /__collect/<id> (collectKpi, concurrency 1) over the roster-resolved trim-strict aiUpdateInstructions partition (resolveAutomatable, NOT WIRED_METRIC_IDS), aggregating per bucket Queued → Collecting… → 'N values pulled' with a per-bucket progress bar, a Cancel → #mbr control and a 'Continue to builder' button disabled until every bucket finishes then navigating to #mbr/build. Added the pure seedCollectedDraft that freezes target from config (via reconcileRoster), records previousValue from the last published MBR, stamps a computed delta / cohort sourceDeltas (t-003), seeds status from the scorecard, sets asOf = pull date, and marks carried=true when a KPI has no fresh reading (fresh emitted value clears carried). Ported the collect-list/queued-chip/determinate-bar CSS into styles.css. Full suite green (562) and typecheck clean.
  - ticket_test_edits: ticket t-006 test-edit declarations verified against the diff vs 65761616991c65d9d273f6fd4480252b350405f4 (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-006 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-006 verified green on the committed branch
  - ticket_green: ticket t-006 green
  - ticket_replay_conflict: ticket t-006 conflicted on replay; rebuilding serially on the current tip
  - ticket_test_edits: ticket t-006 test-edit declarations verified against the diff vs e109afdf1ad42a374787a6339fef3f6ad764932e (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-006 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-006 verified green on the committed branch
  - ticket_green: ticket t-006 green after 2 worker sessions

## t-007 · Build the redesigned builder shell and insight authoring loop
- passed: True · worker sessions: 2 · result.attempts: 4
- new tests: — · declared test edits: src/views/MbrBuilderView.test.tsx (Rewrote the core builder tests from the old New MBR / Refresh all / carried-over), src/views/MbrBuilderView.lock.test.tsx (The per-bucket lock/unlock/amendment lifecycle is removed by this ticket; repurp), src/views/MbrBuilderView.restyle.test.tsx (The old toolbar (New MBR / Refresh all / Discard / Lock in MBR snapshot, all .ic), src/views/MbrBuilderView.themed-controls.test.tsx (The editable value <input> is gone (the value cell is now display-only via Metri), src/views/MbrBuilderView.themed-shell.test.tsx (The shell was redesigned: bucket headers moved from .bucket-card__head/__name/__), src/views/MbrBuilderView.steps.test.tsx (The build-slot dispatch test asserted the removed 'New MBR' button was present; )
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, runner-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 234/234)
- summary: Rebuilt the #mbr/build slot to the redesigned insight-authoring loop: head with eyebrow 'Monthly Business Review', 'MBR builder · {month}' title and the exact subtitle; a toolbar with a Preview button and an amber 'Lock month' primary and NO theme toggle (builder follows the app's global theme); an amber .local-banner.draft with a warning dot, the 'Draft — changes are saved locally as you go' copy and a 'Last edited {formatDate} · N of M buckets complete' meta; an 'Insights added — N of M KPIs' completion bar counting a KPI done iff its insight is non-empty; bucket cards with a .bucket-head ('N KPIs' + 'N of M insights' sub-count, no per-bucket lock/unlock); and KPI rows (name + purple 'Carried' clock pill when kpi.carried, MetricValueCell value cell, an editable .status-select over the five silhouettes, and an insight textarea that gains .filled when non-empty). Insight edits autosave debounced at 800ms with an immediate flush on blur/before-unload via PUT /__data/snapshots/<id>, stamping Snapshot.lastEditedAt; status edits persist immediately. Removed the old New MBR / Refresh all data / Discard / lockedBy-handle / unlock-amendment UI and the refreshMbr wiring, and ported the draft-banner / progress-wrap / bucket-head / carried-badge / status-select / insight-input.filled CSS into src/styles.css. Updated every existing MbrBuilderView test to the new flow. Full suite green (560) and tsc clean; flip-flop verified by running each edited test file against the parent production code (all red there, green on this tree).
  - ticket_test_edits: ticket t-007 test-edit declarations verified against the diff vs 65761616991c65d9d273f6fd4480252b350405f4 (7 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-007 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-007 verified green on the committed branch
  - ticket_green: ticket t-007 green
  - ticket_replay_conflict: ticket t-007 conflicted on replay; rebuilding serially on the current tip
  - ticket_test_edits: ticket t-007 test-edit declarations verified against the diff vs 07f7d02b737a426066edbaa30223f0436f1c97d7 (6 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-007 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-007 verified green on the committed branch
  - ticket_green: ticket t-007 green after 2 worker sessions

## t-008 · Add per-KPI collect controls to wired builder value cells
- passed: True · worker sessions: 1 · result.attempts: 3
- new tests: src/views/MbrBuilderView.wiredCollect.test.tsx · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, runner-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 7/7)
- summary: Added per-KPI collect controls to the builder's wired value cells: for roster-automatable KPIs the build-slot value cell now renders the value, a 'target N' line, a 'vs last MBR' delta, an 'Auto' tag and Collect/Re-collect/Try again controls that drive collectKpi (POST /__collect/<kpiId>), with Collecting…(spinner) / '✓ Updated' / 'Collection failed' state chips and a 'was {old} · as of {date}' line after a (re-)collect. A successful (re-)collect applies the fresh value, stamps asOf, moves the prior value into previousValue, recomputes the KPI's delta via the t-003 computeDelta helper and persists the draft; reuses the Update-KPIs collection vocabulary. Threaded the live roster into MbrBuilder to resolve automatability (ADR-002) and ported the mock's wired value-cell CSS. Full suite green (567) and tsc clean; flip-flop verified (7/7 red on parent, green on tree).
  - ticket_test_edits: ticket t-008 test-edit declarations verified against the diff vs e992018029cd629288f6cb127aa36bf4a50bfd1b (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-008 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-008 verified green on the committed branch
  - ticket_green: ticket t-008 green

## t-009 · Make unwired builder KPI values inline-editable
- passed: True · worker sessions: 2 · result.attempts: 2
- new tests: src/views/MbrBuilderView.manualValue.test.tsx · declared test edits: src/views/MbrBuilderView.test.tsx (A manual scalar KPI value now renders as an editable input (this ticket's change)
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, runner-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 250/250)
- summary: Made unwired builder KPI values inline-editable: a manual value cell now renders an editable .value-input + its .unit, a 'target N' line, a 'vs last MBR' delta, a 'From default view · edit to override' prefill note, a 'Manual' tag, and an amber 'needs value' treatment when empty — no per-value lock/asOf commit step. The value seeds from the KPI's carried committed value (split into number + stable unit); editing recomputes the delta via t-003's computeDelta (never hand-typed), clears carried, and stamps asOf to the pull date (draft.asOf), persisting through the existing PUT /__data/snapshots path. Ported the mock's .value-input.needs / .unit / .prefill-note rules into src/styles.css under .mbr-builder. Cohort (array) manual values stay read-only. Full suite 576/576 green; typecheck clean.
  - ticket_test_edits: ticket t-009 test-edit declarations verified against the diff vs e992018029cd629288f6cb127aa36bf4a50bfd1b (2 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-009 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-009 verified green on the committed branch
  - ticket_green: ticket t-009 green
  - ticket_replay_conflict: ticket t-009 conflicted on replay; rebuilding serially on the current tip
  - ticket_test_edits: ticket t-009 test-edit declarations verified against the diff vs a29564ba1c88cbb87e3042e79c5f62f4ec923b79 (2 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-009 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-009 verified green on the committed branch
  - ticket_green: ticket t-009 green after 2 worker sessions

## t-010 · Show per-source deltas on multi-value builder KPIs
- passed: True · worker sessions: 2 · result.attempts: 2
- new tests: src/components/MetricValueCell.cohortDeltas.test.tsx · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 4/4)
- summary: Extended MetricValueCell to render a cohort KPI's per-source 'change vs last MBR' deltas: each source row gets its own delta cell matched to the persisted sourceDeltas BY LABEL (never array position, via a consuming label match), with a 'change vs last MBR' caption below the list, and a neutral placeholder ('—', .sub-delta.none) for any source with no comparable prior reading — distinct from a genuine zero no-change (.flat). Wired kpi.sourceDeltas into both builder cohort value cells (wired + read-only branches), and ported the mock's .cohort-list.with-deltas / .sub-delta.up/.down/.flat/.none / .cohort-caption CSS into src/styles.css. Non-cohort and delta-less cohort rendering is unchanged (Scorecard/DefaultView/UpdateKpis pass no sourceDeltas). New test green on tree; 3 behavioural cases red on parent. Full suite 580/580 green, typecheck clean.
  - ticket_test_edits: ticket t-010 test-edit declarations verified against the diff vs e992018029cd629288f6cb127aa36bf4a50bfd1b (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-010 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-010 verified green on the committed branch
  - ticket_green: ticket t-010 green
  - ticket_replay_conflict: ticket t-010 conflicted on replay; rebuilding serially on the current tip
  - ticket_test_edits: ticket t-010 test-edit declarations verified against the diff vs 75d6e32789f19d1ae4c1736da39d077127bd3ce6 (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-010 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-010 verified green on the committed branch
  - ticket_green: ticket t-010 green after 2 worker sessions

## t-011 · Add the auto-only Refresh-all warning box and progress strip
- passed: None · worker sessions: 1 · result.attempts: None
- new tests: — · declared test edits: none
- summary: 

## t-012 · Add the month-only lock, read-only state and builder dialogs
- passed: True · worker sessions: 2 · result.attempts: 3
- new tests: src/views/MbrBuilderView.monthlock.test.tsx · declared test edits: src/views/MbrBuilderView.lock.test.tsx (The manifest names this as the lock-flow test to move to the month-only model. I), src/views/MbrBuilderView.restyle.test.tsx (Its assertion that no 'Discard draft' button renders is invalidated by t-012, wh)
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, runner-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 256/256)
- summary: Implemented the month-only lock model and three centered overlay dialogs in the MBR builder. Wired the amber 'Lock month' toolbar button to a warn 'Lock {Month Year}?' dialog whose summary reflects insight completeness and whose confirm is gated on every KPI having a non-empty insight (the completion meter is the lock gate) — locking writes status:'locked', lockedBy:null and a fresh lockedAt to the same file and flips every bucket read-only (static values, status as a label, insight as text). Added the banner 'Discard draft' danger dialog ('Keep editing' / 'Discard draft') that on confirm clears the draft and returns to #mbr, and a single centered month-unlock confirm dialog (no note field, no per-bucket unlock). All dialogs are centered over a dimmed backdrop with a coloured icon badge and dismiss on backdrop click or Esc. Ported the mockup's .overlay/.modal/.modal-icon/.summary/.lock-note CSS and --overlay + .btn.danger into src/styles.css. Full suite 586/586 green, typecheck clean; the 6 new behavioural cases are red on the parent tree.
  - ticket_test_edits: ticket t-012 test-edit declarations verified against the diff vs e992018029cd629288f6cb127aa36bf4a50bfd1b (3 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-012 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-012 verified green on the committed branch
  - ticket_green: ticket t-012 green
  - ticket_replay_conflict: ticket t-012 conflicted on replay; rebuilding serially on the current tip
  - ticket_test_edits: ticket t-012 test-edit declarations verified against the diff vs dff3ffaef5606f10ef52184bab389f5231228c4b (3 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-012 — tests GREEN on tip, RED on parent (runner-red)
  - ticket_postcommit_ok: ticket t-012 verified green on the committed branch
  - ticket_green: ticket t-012 green after 2 worker sessions

## t-013 · Share one read-only render for Preview and published View
- passed: True · worker sessions: 1 · result.attempts: 2
- new tests: src/views/SharedReadOnlyRender.test.tsx · declared test edits: none
- flip-flop: pass — tests GREEN on tip, RED on parent (exit 1, assertion-red — a compile/resolution red from the change's new symbols counts as proof) (tests run parent/tip: 5/5)
- summary: Preview (#mbr/preview) now renders the live draft read-only through the SAME shared LockedMBR component published View uses (ADR-002), with a 'Back to builder' back-out to #mbr/build that never locks; the builder toolbar's Preview button navigates there. LockedView hides the 'Locked by' provenance line when lockedBy is null (never prints 'Locked by —') while the Amendments section is retained unchanged. Full suite green (565) and typecheck clean.
  - ticket_test_edits: ticket t-013 test-edit declarations verified against the diff vs e992018029cd629288f6cb127aa36bf4a50bfd1b (1 declared path(s)) — recorded to test-edit
  - flip_flop_pass: flip-flop PASS for t-013 — tests GREEN on tip, RED on parent (assertion-red)
  - ticket_postcommit_ok: ticket t-013 verified green on the committed branch
  - ticket_green: ticket t-013 green

