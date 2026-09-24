# Plan — the 13 tickets (titles + acceptance criteria)

## t-001 · Extend the snapshot data model with derived/provenance fields
- The Kpi interface exposes optional previousValue, delta, sourceDeltas and carried fields, and Snapshot exposes an optional lastEditedAt
- A snapshot JSON object omitting every new field still satisfies the Snapshot type (all new fields optional)
- sourceDeltas reuses the existing SubReading {label,value} shape rather than a new type

## t-002 · Add MBR sub-route steps and dispatch each to its screen slot
- parseHash('#mbr') returns { view: 'mbr', step: 'start' } and parseHash('#mbr/collect'|'#mbr/build'|'#mbr/preview') return the matching step
- An unknown #mbr/<x> segment falls back to the 'start' step
- MbrBuilderView renders a different step slot for each of start/collect/build/preview based on route.step
- App still resolves view==='mbr' to the Default view on a production (non-DEV) build (gate unchanged)

## t-003 · Add pure metric-value parsing and delta computation helpers
- parseMetricValue('<= 1 day') and parseMetricValue('~9.4h') return the numeric value with the normalized unit; parseMetricValue('WIP') returns null
- computeDelta returns null (neutral, no arrow) when either side is unparseable or the normalized units differ
- computeDelta of two same-unit numbers returns a signed magnitude string with the shared unit
- cohort diffing matches sub-readings by label, not by array position

## t-004 · Change the off-track status marker to an X shape app-wide
- {"text": "STATUS_META.negative.shape is 'x' and the StatusMeta shape union includes 'x'", "notVisual": true}
- {"text": "src/styles.css defines a .status-dot--x rule that renders an X silhouette (two crossed strokes), visibly unlike the filled on-track circle by shape alone", "drawnAt": "#screen-builder, the off-track status marker on the Ship Confidence 'Flaky test rate' row"}
- {"text": "The four other status shapes remain circle/triangle/ring/half-circle", "notVisual": true}
- {"text": "The disk-reading shape tests assert 'x' for negative instead of 'diamond' and the suite stays green", "notVisual": true}

## t-005 · Build the Reviews entry screen with the Next-up start card
_depends on: t-002_
- {"text": "The start card shows a 'Next up' pill, the next-up month heading, a 'N buckets \u00b7 M KPIs \u00b7 Source: DX Scorecard (live)' meta line, a green 'Pull data & start' button and a '~30s \u00b7 re-pullable anytime' hint", "drawnAt": "#screen-start, the start-card at the top of the Reviews screen"}
- {"text": "The Published list renders one row per prior locked month with a lock icon, a green 'Published' chip, an 'M KPIs \u00b7 locked {date}' meta and a 'View' button", "drawnAt": "#screen-start, the Published review-list beneath the start card"}
- {"text": "Clicking 'View' on a published row navigates to that month's #locked/<id> route", "notVisual": true}
- {"text": "When an unlocked draft for the next month already exists on disk, the start card's primary action reads 'Continue draft' and resumes it rather than reseeding", "notDrawn": "the mockup only draws the un-started 'Pull data & start' state; the resume-in-place variant is a behaviour the drawing does not show"}
- {"text": "Starting a fresh pull mints the draft id via nextDraftId (date-keyed YYYY-MM-DD.N), never a bare YYYY-MM", "notVisual": true}

## t-006 · Build the collection screen and seed the pulled draft
_depends on: t-001, t-002, t-003_
- {"text": "Each bucket row cycles through a Queued chip, a Collecting\u2026 chip with a spinner, and an 'N values pulled' chip as its KPIs finish, with the progress bar advancing per bucket", "drawnAt": "#screen-collect, the collect-list rows and the progress bar above them"}
- {"text": "'Continue to builder' is disabled until every bucket has finished, then navigates to #mbr/build; Cancel returns to #mbr", "drawnAt": "#continueBtn and the Cancel control in the collect-list footer"}
- {"text": "The seeded draft freezes target from config, records previousValue from the last published MBR, and stamps a computed delta per KPI", "notVisual": true}
- {"text": "A KPI whose pull returns no fresh reading (failure or empty) carries the previous MBR's value/status forward with carried=true; an emitted value clears carried", "notVisual": true}
- {"text": "The automatable partition driving which KPIs are collected is derived from trim-strict non-empty aiUpdateInstructions resolved from the roster, not from WIRED_METRIC_IDS", "notVisual": true}

## t-007 · Build the redesigned builder shell and insight authoring loop
_depends on: t-001, t-002_
- {"text": "The head shows the eyebrow, 'MBR builder \u00b7 {month}' title and the exact subtitle sentence, and the toolbar shows a Preview button and an amber 'Lock month' button with no theme-toggle button", "drawnAt": "#screen-builder, the head-row and its toolbar"}
- {"text": "An amber draft banner shows a warning dot, the 'Draft \u2014 changes are saved locally as you go' text and a 'Last edited {t} \u00b7 N of M buckets complete' meta", "drawnAt": "#screen-builder, the amber .local-banner.draft under the head"}
- {"text": "An 'Insights added \u2014 N of M KPIs' completion bar sits under the banner and counts a KPI as done exactly when its insight text is non-empty", "drawnAt": "#screen-builder, the progress-wrap bar under the banner"}
- {"text": "Each bucket header reads 'N KPIs' with an 'N of M insights' sub-count and carries no per-bucket lock badge or unlock control", "drawnAt": "#screen-builder, a bucket-card header"}
- {"text": "A KPI row renders the name, a value cell, an editable status select over the five silhouettes, and an insight textarea that gains a filled background when non-empty", "drawnAt": "#screen-builder, a kpi-row in the Velocity bucket"}
- {"text": "Typing an insight autosaves via a PUT to /__data/snapshots/<id> debounced at ~800ms with a flush on blur, stamping Snapshot.lastEditedAt", "notVisual": true}
- {"text": "The old New MBR / Refresh all data / lockedBy-handle / amendment-note builder controls are gone and the existing MbrBuilderView tests are updated to the new flow", "notVisual": true}

## t-008 · Add per-KPI collect controls to wired builder value cells
_depends on: t-001, t-003, t-007_
- {"text": "A wired value cell shows the value, a 'target N' line, a 'vs last MBR' delta, an 'Auto' tag and a Collect control", "drawnAt": "#screen-builder, the Deployment frequency row's value cell in the Velocity bucket"}
- {"text": "Running a collect shows a Collecting\u2026 chip with a spinner, then a '\u2713 Updated' chip with a 'Re-collect' link on success or a 'Collection failed' chip with a 'Try again' button on failure", "drawnAt": "#screen-builder, the value cells showing the \u2713 Updated and Collection failed states"}
- {"text": "A successful (re-)collect renders a 'was {old} \u00b7 as of {date}' line", "drawnAt": "#screen-builder, the .val-updated line under the AI-assisted PRs value"}
- {"text": "A successful re-collect applies the fresh value, stamps asOf, sets previousValue to the prior value and recomputes the KPI's delta via the delta helper", "notVisual": true}

## t-009 · Make unwired builder KPI values inline-editable
_depends on: t-001, t-003, t-007_
- {"text": "A manual KPI value renders as an editable input with its unit, a 'target N' line and a 'vs last MBR' delta", "drawnAt": "#screen-builder, the PR review latency row's value cell in the Velocity bucket"}
- {"text": "A manual value cell shows a 'From default view \u00b7 edit to override' note and a 'Manual' tag, and takes an amber 'needs value' treatment when empty", "drawnAt": "#screen-builder, the PR review latency value cell (prefill note + Manual tag)"}
- {"text": "Editing a manual value recomputes its delta automatically and never lets the delta be hand-typed", "notVisual": true}
- {"text": "Editing a manual value clears carried on that KPI, and there is no per-value 'Lock in value' + As-of commit step", "notVisual": true}
- {"text": "'As of' defaults to the pull date when a manual value is entered", "notVisual": true}

## t-010 · Show per-source deltas on multi-value builder KPIs
_depends on: t-001, t-003, t-007_
- {"text": "A cohort KPI lists every source as a label/value row with its own delta and a 'change vs last MBR' caption below the list", "drawnAt": "#screen-builder, the LTC P75 cohort value cell in the Velocity bucket"}
- {"text": "Each source's delta is matched to the previous published MBR by label, not by array position", "notVisual": true}
- {"text": "A source with no comparable prior reading renders a neutral placeholder rather than 'no change'", "notVisual": true}

## t-011 · Add the auto-only Refresh-all warning box and progress strip
_depends on: t-003, t-008_
- {"text": "The amber warning box states it only collects KPIs with automated instructions, shows the automatable count 'N of M', says the manual KPIs stay unchanged, and holds the 'Update all automatically' button inside it", "drawnAt": "#screen-builder, the .warn-line box containing the automateBtn"}
- {"text": "Running the sweep shows a separate indeterminate progress strip below the action bar, not nested inside the amber box", "drawnAt": "#bulkBar, the update-progress strip below the warn-line"}
- {"text": "The automatable count is automatableCount over the flattened draft, derived from trim-strict non-empty aiUpdateInstructions", "notVisual": true}
- {"text": "The sweep refreshes automatable KPIs only, recomputing their deltas, while every manual value and every insight is preserved and a still-empty KPI stays Carried", "notVisual": true}

## t-012 · Add the month-only lock, read-only state and builder dialogs
_depends on: t-007_
- {"text": "The 'Lock month' button opens a centered 'Lock {Month Year}?' dialog over a dimmed backdrop with a warn icon badge and a summary reflecting how many KPIs have an insight", "drawnAt": "#modal-lock, the lock dialog"}
- {"text": "The lock action is blocked while any KPI has a blank insight, so a published month never contains an insight-less KPI", "notVisual": true}
- {"text": "Locking sets lockedBy to null (no handle field) and renders every bucket read-only \u2014 static values, status as a label, insight as text \u2014 until the month is unlocked", "drawnAt": "#screen-builder, the locked (read-only) Ship Confidence and Platform Health bucket rows"}
- {"text": "The banner's 'Discard draft' button opens a 'Discard this draft?' danger dialog with 'Keep editing' / 'Discard draft'; confirming clears the draft and returns to the Reviews screen", "drawnAt": "#modal-discard, the discard dialog"}
- {"text": "Unlock is a single centered confirm dialog to unlock the whole month with no note field, and there is no per-bucket unlock control or 'Unlock this bucket?' dialog", "drawnAt": "#modal-unlock, the unlock dialog (repurposed to month-only, no note field)"}
- {"text": "Every dialog is dismissable by backdrop click or Esc", "notVisual": true}

## t-013 · Share one read-only render for Preview and published View
_depends on: t-002, t-007_
- {"text": "The builder's Preview button navigates to #mbr/preview and renders the current draft read-only in the same presentation the locked buckets use, with a back-out that returns to #mbr/build without locking", "drawnAt": "#screen-builder, the Preview toolbar button and the locked (read-only) bucket rendering it mirrors"}
- {"text": "Preview and View render through one shared read-only component, differing only in draft-vs-snapshot source", "notVisual": true}
- {"text": "LockedView hides the 'Locked by' provenance line when lockedBy is null and never prints 'Locked by \u2014'", "notVisual": true}
- {"text": "The Amendments section still renders for a historical snapshot that carries amendments", "notVisual": true}

