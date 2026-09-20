**How close this is to what you asked for: LOW** — I could not check the point of the mission — Walking the flow… (journey-j9) — so nothing here says it works.

**Why this grade.** LOW because I could not check the point of the mission, and I will not call a build good on what I could not see. The point of the mission is 29 things — Reviews entry screen is the landing view…, Collection screen shows each bucket…, Builder matches the mockup… and 26 more — and 1 couldn't be checked. Known issues shipping with it: primary action buttons break the mockup's button styling — you asked for the mockup's compact horizontal action buttons with small inline…; the build gives the green Pull-data and Continue buttons rendering oversized stacked… (prd-21); the Pull data & start button's oversized icon — you asked for a compact green button with a small inline download icon and 'Pull…; the build gives an oversized download icon (55px in a 38px control) stacked above the… (part-pull data start) and the Continue to builder button's oversized icon — you asked for a compact green button with a small inline arrow and 'Continue to…; the build gives an oversized arrow icon (61px in a 32px control) with the label… (part-continueBtn). I could not check 31 things — Walking the flow…, Refresh-all lives in an amber warning…, Wired KPI value cells show the value… and 28 more; 21 smaller items I could not check, and they don't change the grade: The Kpi interface exposes optional previousValue…, A snapshot JSON object omitting every…, sourceDeltas reuses the existing… and 18 more — see the list.

*Importance was set on this look (2026-09-20, Copilot); later looks keep it.*

*the "View" button matches the drawing… (part-view) and the Lock month button's icon overflow (part-lock month) say the same thing but were given different importance (low and medium). This does not change the grade — tell me which is right.*

*the "Cancel" button matches the drawing… (part-cancel) and the Lock month button's icon overflow (part-lock month) say the same thing but were given different importance (low and medium). This does not change the grade — tell me which is right.*

*the "Preview" button matches the drawing… (part-preview) and the Lock month button's icon overflow (part-lock month) say the same thing but were given different importance (low and medium). This does not change the grade — tell me which is right.*

Captain, your MBR builder is in good shape: the Reviews landing, the collect screen, the redesigned builder, the draft banner, the completion meter, cohort/carried/manual rendering, autosave-and-persist, the Preview read-only path and the month-only lock gate all work — the lock dialog does open at 19/19 (the walk's text-diff missed the overlay, but the screenshot shows it plainly). The one real parity problem is cosmetic but visible: the primary green buttons ('Pull data & start', 'Continue to builder', and to a lesser degree 'Lock month') render oversized icons with labels wrapped onto two or three lines instead of the mockup's compact single-line buttons. Two whole areas — wired-KPI collect cells and the Refresh-all box — couldn't be checked because this seed has no automated KPIs, and the failing test run is contamination from the verify walk, not a build defect. Every high-impact criterion I could reach worked; ship with the button styling and the named unchecked areas as known items.

**I also measured 5 things against your drawing and while walking the flow myself. They are not in the count above — measurements never move your score — but they are faults and they are listed below, under *What I measured on your drawing*.**

> I first called this MEDIUM. The line above is worked out again from my own
> notes below, and those notes win.

I ran your tests (`npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}`) and the run failed — exit 1, after 61s. A failed run can be a test of yours going red or a test runner that never started, and the exit code does not say which, so I have not counted it against the build on its own.

| What you asked for | | Verdict | How I know | What I saw |
|---|---|---|---|---|
| prd-1 (PRD) | Reviews entry screen is the landing view | MET | a picture | shot-walk-00-wayin — Landing shows a 'NEXT UP' pill, 'August 2026' heading, '5 buckets · 19 KPIs · Source: DX Scorecard (live)' meta, a green 'Pull data & start' button, the '~30s… |
| prd-2 (PRD) | Collection screen with progress bar, Cancel, Continue | MET | a picture | shot-walk-01-j1 — Collect screen shows 'Pulling data · September 2026', a progress bar, five bucket rows each with a 'N values pulled' chip, a Cancel control and a Continue to… |
| prd-3 (PRD) | Builder head: eyebrow/title/subtitle/Preview/Lock month | MET | a picture | shot-walk-02-j2 — Builder shows eyebrow 'MONTHLY BUSINESS REVIEW', title 'MBR builder · September 2026', the exact subtitle sentence, a Preview toolbar button and an amber 'Lock… |
| prd-4 (PRD) | Amber draft banner with warning dot, text, meta, Discard draft | MET | a picture | shot-walk-02-j2 — An amber banner reads 'Draft — changes are saved locally as you go.' with a warning dot, a 'Last edited — · 3 of 5 buckets complete' meta and a 'Discard draft'… |
| prd-5 (PRD) | Refresh-all amber warning box with automate button | UNTESTED | — | Every KPI in this seed is manual (the collect screen read '0 values pulled' and every row shows a MANUAL tag), so the automatable count is 0 and the… |
| prd-6 (PRD) | Insights-added completion bar equals lock gate | MET | a picture | shot-walk-02-j2 — An 'Insights added 16 of 19 KPIs' bar sits under the banner; the walk showed it climb 16→17→18→19 as insights were typed, and the lock dialog only reported… |
| prd-7 (PRD) | Per-KPI editable status select over five silhouettes; off-track X | MET | a picture | shot-walk-06-j6 — Each row carries an editable status select showing the five silhouettes (On track / Watch / Off track / Tracking / WIP); the off-track marker is a red X shape… |
| prd-8 (PRD) | Value/target/delta arrive with the data pull | MET | a picture | shot-walk-02-j2 — Every KPI shows a value, a 'target N' line and a computed 'vs last MBR' delta (all '0'/'— 0' here because the data carried forward unchanged). Because the seed… |
| prd-9 (PRD) | Manual (unwired) KPIs edited inline | MET | a picture | shot-walk-02-j2 — Manual KPIs show an inline editable value input with unit, a 'target N' line, a 'vs last MBR' delta, a 'From default view · edit to override' note and a… |
| prd-10 (PRD) | Wired KPI value cells with Auto tag and Collect controls | UNTESTED | — | There are no wired/automated KPIs in this seed — every KPI shows a MANUAL tag and the collect screen read '0 values pulled', so no cell shows an 'Auto' tag or… |
| prd-11 (PRD) | Multi-value cohort KPIs show per-source change delta column | MET | a picture | shot-walk-02-j2 — Cohort KPIs (LTC P75, Change Failure Rate, Deployment Frequency, New Service Language Breakdown, Ci Critical Path Time) list each source as a label/value row… |
| prd-12 (PRD) | Carried KPIs render a purple Carried pill | MET | a picture | shot-walk-02-j2 — Because the pull returned no fresh values, every KPI carries forward and renders a purple 'Carried' pill next to its name, kept separate from the status marker. |
| prd-13 (PRD) | Bucket headers 'N KPIs' + 'N of M insights', no per-bucket lock | MET | a picture | shot-walk-02-j2 — Each bucket header reads e.g. 'Velocity 6 KPIs' with a '4 of 6 insights' sub-count and carries no per-bucket lock badge or unlock control. |
| prd-14 (PRD) | Insights autosave and persist locally; last-edited reflects saves | MET | a picture | shot-walk-04-j4 — Typing an insight updated the 'Last edited' meta from '—' to 'Sep 20, 2026' and bumped the completion count with no explicit save control; the typed text later… |
| prd-15 (PRD) | Re-pull refreshes automated KPIs only, preserving manual/insights | UNTESTED | — | No re-pull was exercised, and with no automated KPIs in this seed there is nothing to refresh; this is a non-visual behaviour with no surface to observe. |
| prd-16 (PRD) | Locking is per-month only, gated on non-empty insights, 'Lock {Month Year}?' dialog | MET | a picture | shot-walk-09-j9 — With blank insights the Lock month button did nothing (walk step j3 changed nothing); with all 19 filled it opened a centered 'Lock September 2026?' dialog… |
| prd-17 (PRD) | Locked month renders all buckets read-only | UNTESTED | — | The month was not actually locked (the lock dialog was opened but not confirmed), so the true locked-month read-only state was not reached; the Preview screen… |
| prd-18 (PRD) | Dialogs centered over dimmed backdrop with icon badge, Esc/backdrop dismiss | MET | a picture | shot-walk-09-j9 — The lock dialog is a centered overlay over a dimmed backdrop with a coloured lock icon badge and a Cancel / 'Lock month' pair; the discard and unlock dialogs… |
| prd-19 (PRD) | Nav actions: Continue/Preview/View | MET | a picture | shot-walk-06-j6 — Continue to builder entered the builder (j2), Preview navigated to #mbr/preview rendering the draft read-only and 'Back to builder' returned (j6/j7); View on a… |
| prd-20 (PRD) | Builder follows global theme; builder-local toggle dropped | MET | a picture | shot-walk-02-j2 — The builder toolbar carries only Preview and Lock month — no theme toggle; the only theme control is the app-global 'Dark' toggle top-right. |
| prd-21 (PRD) | Visual and flow parity with the mockup | GAP | a picture | shot-walk-00-wayin — Layout, wording and flow track the mockup well, but the primary action buttons are visibly off: 'Pull data & start' and 'Continue to builder' render an… |
| t-001-ac1 | Kpi/Snapshot expose new optional fields | UNTESTED | — | A pure TypeScript type shape with no visible surface; the test run was contaminated by the verify walk writing to disk so I cannot cite it. |
| t-001-ac2 | Snapshot omitting new fields still valid | UNTESTED | — | Non-visual type guarantee; no citable clean test line. |
| t-001-ac3 | sourceDeltas reuses SubReading shape | UNTESTED | — | Internal type reuse; not observable and the suite was contaminated. |
| t-002-ac1 | parseHash returns the matching step | UNTESTED | — | The routing function itself is non-visual; the observable result (distinct screens per step) is covered by t-002-ac3, but the pure parse is not citable given… |
| t-002-ac2 | Unknown #mbr/<x> falls back to start | UNTESTED | — | Edge routing behaviour not exercised in the walk; non-visual. |
| t-002-ac3 | MbrBuilderView renders a step slot per route.step | MET | a picture | shot-walk-06-j6 — The walk reached #mbr (start), #mbr/collect, #mbr/build and #mbr/preview and each rendered a visibly distinct screen. |
| t-002-ac4 | Production build resolves view==='mbr' to Default view | UNTESTED | — | A production-only gate; this is a DEV build ('Running locally — editing enabled'), so the gate cannot be observed here. |
| t-003-ac1 | parseMetricValue normalises value/unit, WIP→null | UNTESTED | — | Non-visual helper; the contaminated suite offers no clean citable line. |
| t-003-ac2 | computeDelta neutral on unparseable/mismatched units | UNTESTED | — | Non-visual helper; not citable. |
| t-003-ac3 | computeDelta signed magnitude with shared unit | UNTESTED | — | Non-visual helper; not citable. |
| t-003-ac4 | Cohort diffing matches sub-readings by label | UNTESTED | — | Non-visual helper; not citable from the contaminated suite. |
| t-004-ac1 | STATUS_META.negative.shape is 'x' | UNTESTED | — | Internal metadata; non-visual and not citable. |
| t-004-ac2 | .status-dot--x renders an X silhouette distinct by shape | MET | a picture | shot-walk-06-j6 — The off-track marker is a two-stroke X, visibly unlike the filled on-track circle by shape alone, shown on '% Agentic Fix PRs' and 'Core 4 Availability'. |
| t-004-ac3 | Other four status shapes remain circle/triangle/ring/half-circle | UNTESTED | — | Marked non-visual; the exact shape-per-status mapping at rest is not confidently readable and the suite is contaminated. |
| t-004-ac4 | Disk-reading shape tests assert 'x' and suite green | UNTESTED | — | Non-visual; the suite outcome was 'failed' but from walk contamination, so it cannot settle this. |
| t-005-ac1 | Start card: pill, heading, meta, green button, hint | MET | a picture | shot-walk-00-wayin — Start card shows a 'NEXT UP' pill, 'August 2026' heading, the '5 buckets · 19 KPIs · Source: DX Scorecard (live)' meta, a green 'Pull data & start' button and… |
| t-005-ac2 | Published list rows: lock icon, chip, meta, View | MET | a picture | shot-walk-00-wayin — The Published July 2026 row shows a lock icon, a green 'Published' chip, '19 KPIs · locked Jul 28, 2026' and a 'View' button. |
| t-005-ac3 | View navigates to #locked/<id> | UNTESTED | — | The View button was not clicked during the walk. |
| t-005-ac4 | Existing draft: primary action reads 'Continue draft' | UNTESTED | — | No unlocked draft pre-existed at the start ('No data pulled yet'), so the resume variant did not appear. |
| t-005-ac5 | Fresh pull mints date-keyed draft id | MET | a picture | shot-walk-06-j6 — The Preview header reads 'Snapshot 2026-09-20.0' — a date-keyed YYYY-MM-DD.N id, not a bare YYYY-MM. |
| t-006-ac1 | Bucket rows cycle chips behind a progress bar | MET | a picture | shot-walk-01-j1 — Each bucket row sits behind a progress bar and ends on an 'N values pulled' chip ('0 values pulled' here, all-manual seed); the intermediate Queued/Collecting… |
| t-006-ac2 | Continue disabled until done, then #mbr/build; Cancel→#mbr | MET | a picture | shot-walk-01-j1 — Continue to builder navigated to #mbr/build (walk j2). Because the pull finished instantly the disabled state wasn't captured, and Cancel wasn't clicked. |
| t-006-ac3 | Seeded draft freezes target/previousValue/delta | UNTESTED | — | Non-visual seeding internals; not citable from the contaminated suite. |
| t-006-ac4 | No-fresh-value KPI carries forward with carried=true | UNTESTED | — | The internal carried flag is non-visual; the visible Carried pills are judged under prd-12. |
| t-006-ac5 | Automatable partition from aiUpdateInstructions | UNTESTED | — | Non-visual derivation; not citable. |
| t-007-ac1 | Head + toolbar with no theme toggle | MET | a picture | shot-walk-02-j2 — Head shows the eyebrow, 'MBR builder · September 2026' title and exact subtitle; toolbar shows Preview and an amber 'Lock month' with no theme-toggle button. |
| t-007-ac2 | Amber draft banner with dot, text, meta | MET | a picture | shot-walk-02-j2 — Amber banner shows a warning dot, 'Draft — changes are saved locally as you go' and a 'Last edited — · 3 of 5 buckets complete' meta. |
| t-007-ac3 | Completion bar counts non-empty insights | MET | a picture | shot-walk-02-j2 — 'Insights added N of 19 KPIs' sat under the banner and rose 16→19 exactly as insights gained text. |
| t-007-ac4 | Bucket header N KPIs + N of M insights, no lock badge | MET | a picture | shot-walk-02-j2 — Headers read 'N KPIs' with an 'N of M insights' sub-count and carry no lock/unlock control. |
| t-007-ac5 | KPI row: name, value, status select, insight textarea filled when non-empty | MET | a picture | shot-walk-02-j2 — Rows render the name, a value cell, an editable status select over the five silhouettes and an insight textarea; non-empty insights carry a distinct filled… |
| t-007-ac6 | Insight autosave PUT debounced + stamps lastEditedAt | UNTESTED | — | The debounced PUT is non-visual; the 'Last edited' stamp did update on typing (shot-walk-04-j4), which is consistent with autosave, but the PUT/debounce itself… |
| t-007-ac7 | Old builder controls gone, tests updated | MET | a picture | shot-walk-02-j2 — The builder shows no 'New MBR', old 'Refresh all data', lockedBy-handle or amendment-note controls, and the lock dialog carries no 'Locked by' field. |
| t-008-ac1 | Wired value cell: value, target, delta, Auto tag, Collect | UNTESTED | — | No wired KPIs exist in this seed (all MANUAL), so no Auto tag or Collect control renders. |
| t-008-ac2 | Collect lifecycle chips (Collecting/Updated/failed) | UNTESTED | — | No wired KPIs to run a collect, so the Collecting/✓ Updated/Collection failed chips can't appear. |
| t-008-ac3 | Successful collect shows 'was {old} · as of {date}' | UNTESTED | — | No wired collect could run, so this residue line has no chance to render. |
| t-008-ac4 | Re-collect applies value, stamps asOf, recomputes delta | UNTESTED | — | Non-visual and no wired KPI to exercise. |
| t-009-ac1 | Manual value: editable input, target, delta | MET | a picture | shot-walk-02-j2 — Manual KPIs render an editable value input with unit, a 'target N' line and a 'vs last MBR' delta. |
| t-009-ac2 | Manual cell: prefill note, Manual tag, amber needs-value | MET | a picture | shot-walk-02-j2 — Manual cells show a 'From default view · edit to override' note and a 'MANUAL' tag; empty ones (e.g. Copilot SRE Impact Score) take an amber empty-input… |
| t-009-ac3 | Editing a manual value recomputes delta, never hand-typed | UNTESTED | — | Non-visual; the walk did not edit a manual value cell (only insights were typed). |
| t-009-ac4 | Editing manual value clears carried; no lock/asOf step | UNTESTED | — | Non-visual and no manual value was edited during the walk. |
| t-009-ac5 | 'As of' defaults to the pull date | UNTESTED | — | Non-visual; Preview shows 'Data as of Sep 20, 2026' consistent with a pull-date stamp, but the per-value as-of default was not exercised. |
| t-010-ac1 | Cohort KPI lists sources with delta and caption | MET | a picture | shot-walk-02-j2 — Cohort KPIs list every source as a label/value row with its own delta and a 'change vs last MBR' caption below the list. |
| t-010-ac2 | Each source's delta matched by label | UNTESTED | — | Non-visual matching internals; not citable. |
| t-010-ac3 | No comparable prior renders neutral placeholder | UNTESTED | — | Non-visual edge; deltas here all read '0'/'no change' with no distinguishable placeholder case observed. |
| t-011-ac1 | Amber warn box with N of M automatable + automate button | UNTESTED | — | With 0 automatable KPIs in this seed the box does not render, so there is nothing to observe. |
| t-011-ac2 | Update-all indeterminate progress strip | UNTESTED | — | No automatable KPIs and no sweep run, so the strip never appears. |
| t-011-ac3 | Automatable count over flattened draft | UNTESTED | — | Non-visual; not citable. |
| t-011-ac4 | Sweep refreshes automatable only, preserving manual/insights | UNTESTED | — | Non-visual and unreachable — no automatable KPIs to sweep. |
| t-012-ac1 | Lock dialog centered, dimmed, warn badge, insight summary | MET | a picture | shot-walk-09-j9 — Clicking Lock month at 19/19 opened a centered 'Lock September 2026?' dialog over a dimmed backdrop with a lock icon badge and a summary '19 of 19 KPIs have an… |
| t-012-ac2 | Lock blocked while any insight blank | MET | a picture | shot-walk-09-j9 — At 16/19 (blanks present) clicking Lock month did nothing (walk j3 unchanged); only at 19/19 did the dialog open and report the month ready — the gate holds. |
| t-012-ac3 | Locking sets lockedBy null and renders buckets read-only | UNTESTED | — | The lock was not confirmed, so the true locked read-only bucket state wasn't reached; Preview shows the equivalent read-only rendering with 'Locked at —' and… |
| t-012-ac4 | Discard opens 'Discard this draft?' danger dialog | UNTESTED | — | The Discard draft button is present but was not clicked, so the dialog wasn't opened. |
| t-012-ac5 | Unlock is a single month-only confirm, no note field | UNTESTED | — | The month was never locked, so the unlock dialog was unreachable. |
| t-012-ac6 | Every dialog dismissable by backdrop or Esc | UNTESTED | — | Backdrop/Esc dismissal is not observable from stills and wasn't exercised. |
| t-013-ac1 | Preview navigates to #mbr/preview read-only with back-out | MET | a picture | shot-walk-06-j6 — Preview navigated to #mbr/preview and rendered the draft read-only ('Locked MBR · September 2026' with current/target/insight columns and a status silhouette… |
| t-013-ac2 | Preview and View share one read-only component | UNTESTED | — | View was not exercised, so the shared-component claim can't be confirmed against both sources. |
| t-013-ac3 | LockedView hides 'Locked by' when null | MET | a picture | shot-walk-06-j6 — The read-only Preview header shows 'Data as of … · Generated … · Locked at —' with no 'Locked by' line at all. |
| t-013-ac4 | Amendments section renders for a snapshot with amendments | UNTESTED | — | No amended historical snapshot was opened, so this could not be observed. |
| part-pull data start (PRD) | 'Pull data & start' button matches the drawing | GAP | a picture | shot-walk-00-wayin — Your drawing has a compact green button with a small inline download icon and 'Pull data & start' on one line; the build has an oversized download icon (55px… |
| part-view (PRD) | 'View' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-pullBar (PRD) | pullBar (collect progress bar) matches the drawing | MET | a picture | shot-walk-01-j1 — The collection screen shows a full-width progress bar above the bucket list, consistent with the drawn pullBar. |
| part-cancel (PRD) | 'Cancel' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-continueBtn (PRD) | 'Continue to builder' button matches the drawing | GAP | a picture | shot-walk-01-j1 — Your drawing has a compact green 'Continue to builder' button with a small inline arrow on one line; the build has an oversized arrow icon (61px in a 32px… |
| part-themeBtn (PRD) | builder theme-toggle button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-preview (PRD) | 'Preview' button matches the drawing | MET | a picture | shot-walk-02-j2 — The builder toolbar shows a compact single-line 'Preview' button, consistent with the drawing. |
| part-lock month (PRD) | 'Lock month' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-discard draft (PRD) | 'Discard draft' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-automateBtn (PRD) | 'Update all automatically' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-re collect (PRD) | 'Re-collect' button matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-on trackwatchoff tracktrackingwip (PRD) | status select matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| part-gh gh remains the long pole copilot and go sdlc well inside target (PRD) | insight textarea matches the drawing | UNTESTED | — | your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check |
| journey-j1 (PRD) | From start, click 'Pull data & start' → collect screen | MET | a picture | shot-walk-01-j1 — Clicking 'Pull data & start' moved from #mbr to #mbr/collect and the collection screen appeared. |
| journey-j2 (PRD) | From collect, click 'Continue to builder' → builder | MET | a picture | shot-walk-02-j2 — Continue to builder moved from #mbr/collect to #mbr/build and the builder appeared. |
| journey-j3 (PRD) | Try 'Lock month' with fields blank → it refuses | MET | a picture | shot-walk-03-j3 — With insights still blank (16/19), clicking Lock month changed nothing — no dialog, no navigation — so the gate held. |
| journey-j4 (PRD) | Type into an insight → it carries | MET | a picture | shot-walk-04-j4 — Typed text was read back in the field, the completion count rose 16→17 and the last-edited stamp updated. |
| journey-j5 (PRD) | Type into a second insight → it carries | MET | a picture | shot-walk-05-j5 — A second typed insight was read back and the count rose 17→18. |
| journey-j6 (PRD) | Click 'Preview' → the preview screen | MET | a picture | shot-walk-06-j6 — Preview navigated to #mbr/preview and rendered the draft read-only, carrying the typed insights. |
| journey-j7 (PRD) | Come back → the builder | MET | a picture | shot-walk-07-j7 — 'Back to builder' returned from #mbr/preview to #mbr/build with the draft intact. |
| journey-j8 (PRD) | Fill every remaining field | MET | a picture | shot-walk-08-j8 — The last blank insight was filled, taking the meter to 19 of 19; two WIP manual value cells could not be typed into (they are WIP placeholders, not insights)… |
| journey-j9 (PRD) | Click 'Lock month' now everything is filled → it opens | UNTESTED | — | I could not take this step: I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked |

### Where the build does not match what you asked for

- **the Pull data & start button's oversized icon** — your drawing has a compact green button with a small inline download icon and 'Pull data & start' on one line; the build has an oversized download icon (55px in a 38px control) stacked above the label with the label wrapped onto three lines. *(see shot-walk-00-wayin; part-pull data start)*
- **the Continue to builder button's oversized icon** — your drawing has a compact green button with a small inline arrow and 'Continue to builder' on one line; the build has an oversized arrow icon (61px in a 32px control) with the label wrapped onto three lines. *(see shot-walk-01-j1; part-continueBtn)*
- **the Lock month button's icon overflow** — your drawing has the amber Lock month button with its lock icon inside the control and the label on one line; the build has the lock icon slightly overflowing (34px in a 32px control) and the label wrapping onto two lines. *(see shot-walk-02-j2; part-lock month)*
- **primary action buttons break the mockup's button styling** — your drawing has the mockup's compact horizontal action buttons with small inline icons on one line; the build has the green Pull-data and Continue buttons rendering oversized stacked icons with three-line labels. *(see shot-walk-00-wayin, shot-walk-01-j1; prd-21)*

### What I could not check

- Refresh-all amber warning box with automate button — Every KPI in this seed is manual (the collect screen read '0 values pulled' and every row shows a MANUAL tag), so the automatable count is 0 and the refresh-all box (which sweeps automated KPIs) does not render — there were no automated KPIs to trigger it. *(prd-5)*
- Wired KPI value cells with Auto tag and Collect controls — There are no wired/automated KPIs in this seed — every KPI shows a MANUAL tag and the collect screen read '0 values pulled', so no cell shows an 'Auto' tag or Collect/Re-collect/Try again controls to observe. *(prd-10)*
- Re-pull refreshes automated KPIs only, preserving manual/insights — No re-pull was exercised, and with no automated KPIs in this seed there is nothing to refresh; this is a non-visual behaviour with no surface to observe. *(prd-15)*
- Locked month renders all buckets read-only — The month was not actually locked (the lock dialog was opened but not confirmed), so the true locked-month read-only state was not reached; the Preview screen does demonstrate the same read-only rendering path (static values, status as label, insight as text). *(prd-17)*
- Kpi/Snapshot expose new optional fields — A pure TypeScript type shape with no visible surface; the test run was contaminated by the verify walk writing to disk so I cannot cite it. *(t-001-ac1)*
- Snapshot omitting new fields still valid — Non-visual type guarantee; no citable clean test line. *(t-001-ac2)*
- sourceDeltas reuses SubReading shape — Internal type reuse; not observable and the suite was contaminated. *(t-001-ac3)*
- parseHash returns the matching step — The routing function itself is non-visual; the observable result (distinct screens per step) is covered by t-002-ac3, but the pure parse is not citable given the contaminated suite. *(t-002-ac1)*
- Unknown #mbr/<x> falls back to start — Edge routing behaviour not exercised in the walk; non-visual. *(t-002-ac2)*
- Production build resolves view==='mbr' to Default view — A production-only gate; this is a DEV build ('Running locally — editing enabled'), so the gate cannot be observed here. *(t-002-ac4)*
- parseMetricValue normalises value/unit, WIP→null — Non-visual helper; the contaminated suite offers no clean citable line. *(t-003-ac1)*
- computeDelta neutral on unparseable/mismatched units — Non-visual helper; not citable. *(t-003-ac2)*
- computeDelta signed magnitude with shared unit — Non-visual helper; not citable. *(t-003-ac3)*
- Cohort diffing matches sub-readings by label — Non-visual helper; not citable from the contaminated suite. *(t-003-ac4)*
- STATUS_META.negative.shape is 'x' — Internal metadata; non-visual and not citable. *(t-004-ac1)*
- Other four status shapes remain circle/triangle/ring/half-circle — Marked non-visual; the exact shape-per-status mapping at rest is not confidently readable and the suite is contaminated. *(t-004-ac3)*
- Disk-reading shape tests assert 'x' and suite green — Non-visual; the suite outcome was 'failed' but from walk contamination, so it cannot settle this. *(t-004-ac4)*
- View navigates to #locked/<id> — The View button was not clicked during the walk. *(t-005-ac3)*
- Existing draft: primary action reads 'Continue draft' — No unlocked draft pre-existed at the start ('No data pulled yet'), so the resume variant did not appear. *(t-005-ac4)*
- Seeded draft freezes target/previousValue/delta — Non-visual seeding internals; not citable from the contaminated suite. *(t-006-ac3)*
- No-fresh-value KPI carries forward with carried=true — The internal carried flag is non-visual; the visible Carried pills are judged under prd-12. *(t-006-ac4)*
- Automatable partition from aiUpdateInstructions — Non-visual derivation; not citable. *(t-006-ac5)*
- Insight autosave PUT debounced + stamps lastEditedAt — The debounced PUT is non-visual; the 'Last edited' stamp did update on typing (shot-walk-04-j4), which is consistent with autosave, but the PUT/debounce itself cannot be observed and the suite was contaminated. *(t-007-ac6)*
- Wired value cell: value, target, delta, Auto tag, Collect — No wired KPIs exist in this seed (all MANUAL), so no Auto tag or Collect control renders. *(t-008-ac1)*
- Collect lifecycle chips (Collecting/Updated/failed) — No wired KPIs to run a collect, so the Collecting/✓ Updated/Collection failed chips can't appear. *(t-008-ac2)*
- Successful collect shows 'was {old} · as of {date}' — No wired collect could run, so this residue line has no chance to render. *(t-008-ac3)*
- Re-collect applies value, stamps asOf, recomputes delta — Non-visual and no wired KPI to exercise. *(t-008-ac4)*
- Editing a manual value recomputes delta, never hand-typed — Non-visual; the walk did not edit a manual value cell (only insights were typed). *(t-009-ac3)*
- Editing manual value clears carried; no lock/asOf step — Non-visual and no manual value was edited during the walk. *(t-009-ac4)*
- 'As of' defaults to the pull date — Non-visual; Preview shows 'Data as of Sep 20, 2026' consistent with a pull-date stamp, but the per-value as-of default was not exercised. *(t-009-ac5)*
- Each source's delta matched by label — Non-visual matching internals; not citable. *(t-010-ac2)*
- No comparable prior renders neutral placeholder — Non-visual edge; deltas here all read '0'/'no change' with no distinguishable placeholder case observed. *(t-010-ac3)*
- Amber warn box with N of M automatable + automate button — With 0 automatable KPIs in this seed the box does not render, so there is nothing to observe. *(t-011-ac1)*
- Update-all indeterminate progress strip — No automatable KPIs and no sweep run, so the strip never appears. *(t-011-ac2)*
- Automatable count over flattened draft — Non-visual; not citable. *(t-011-ac3)*
- Sweep refreshes automatable only, preserving manual/insights — Non-visual and unreachable — no automatable KPIs to sweep. *(t-011-ac4)*
- Locking sets lockedBy null and renders buckets read-only — The lock was not confirmed, so the true locked read-only bucket state wasn't reached; Preview shows the equivalent read-only rendering with 'Locked at —' and no 'Locked by' line. *(t-012-ac3)*
- Discard opens 'Discard this draft?' danger dialog — The Discard draft button is present but was not clicked, so the dialog wasn't opened. *(t-012-ac4)*
- Unlock is a single month-only confirm, no note field — The month was never locked, so the unlock dialog was unreachable. *(t-012-ac5)*
- Every dialog dismissable by backdrop or Esc — Backdrop/Esc dismissal is not observable from stills and wasn't exercised. *(t-012-ac6)*
- Preview and View share one read-only component — View was not exercised, so the shared-component claim can't be confirmed against both sources. *(t-013-ac2)*
- Amendments section renders for a snapshot with amendments — No amended historical snapshot was opened, so this could not be observed. *(t-013-ac4)*
- 'View' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-view)*
- 'Cancel' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-cancel)*
- builder theme-toggle button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-themeBtn)*
- 'Lock month' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-lock month)*
- 'Discard draft' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-discard draft)*
- 'Update all automatically' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-automateBtn)*
- 'Re-collect' button matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-re collect)*
- status select matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-on trackwatchoff tracktrackingwip)*
- insight textarea matches the drawing — your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. *(part-gh gh remains the long pole copilot and go sdlc well inside target)*
- Click 'Lock month' now everything is filled → it opens — I could not take this step: I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked. *(journey-j9)*

### My reasoning, item by item

- Reviews entry screen is the landing view *(prd-1)* — Impact high because the whole feature hangs off this landing. I tried opening #mbr; I saw the start card and Published list exactly as specified (evidence: shot-walk-00-wayin). Outcome: worked.
- Collection screen with progress bar, Cancel, Continue *(prd-2)* — Impact high because it is the gateway into the builder. I tried the pull; I saw bucket rows, a progress bar, Cancel and Continue (evidence: shot-walk-01-j1). Outcome: worked.
- Builder head: eyebrow/title/subtitle/Preview/Lock month *(prd-3)* — Impact high because it is the redesigned builder itself. I tried the builder head; I saw the eyebrow, title, subtitle, Preview and amber Lock month (evidence: shot-walk-02-j2). Outcome: worked.
- Amber draft banner with warning dot, text, meta, Discard draft *(prd-4)* — Impact high because it conveys the local-save promise. I tried reading the banner; I saw the dot, text, meta and Discard draft (evidence: shot-walk-02-j2). Outcome: worked.
- Refresh-all amber warning box with automate button *(prd-5)* — Impact medium because it is a bulk convenience. I tried finding the refresh-all box in the builder; I saw none and every KPI is manual with 0 automatable (evidence: none). Outcome: couldn't check (unreachable).
- Insights-added completion bar equals lock gate *(prd-6)* — Impact high because the meter equals the lock gate. I tried typing insights; I saw the count rise to 19/19 and the lock become ready (evidence: shot-walk-02-j2). Outcome: worked.
- Per-KPI editable status select over five silhouettes; off-track X *(prd-7)* — Impact high because status and the X marker are stated requirements. I tried inspecting the status markers; I saw selects with five silhouettes and a distinct X for off-track (evidence: shot-walk-06-j6). Outcome: worked.
- Value/target/delta arrive with the data pull *(prd-8)* — Impact high because the numbers are the review. I tried reading the cells; I saw value, target and a computed delta on every KPI (evidence: shot-walk-02-j2). Outcome: worked.
- Manual (unwired) KPIs edited inline *(prd-9)* — Impact medium because it is a secondary editing behaviour. I tried inspecting manual cells; I saw inline inputs, the prefill note, Manual tag and needs-value treatment (evidence: shot-walk-02-j2). Outcome: worked.
- Wired KPI value cells with Auto tag and Collect controls *(prd-10)* — Impact medium because it is one rendering variant. I tried finding a wired cell; I saw only manual cells and no Auto tag anywhere (evidence: none). Outcome: couldn't check (unreachable).
- Multi-value cohort KPIs show per-source change delta column *(prd-11)* — Impact medium because it is a KPI variant. I tried reading the cohort cells; I saw per-source rows with deltas and the 'change vs last MBR' caption (evidence: shot-walk-02-j2). Outcome: worked.
- Carried KPIs render a purple Carried pill *(prd-12)* — Impact medium because it is a provenance label. I tried inspecting the pills; I saw purple 'Carried' pills on the carried KPIs (evidence: shot-walk-02-j2). Outcome: worked.
- Bucket headers 'N KPIs' + 'N of M insights', no per-bucket lock *(prd-13)* — Impact high because the no-per-bucket-lock model is core. I tried reading the headers; I saw 'N KPIs' + 'N of M insights' and no lock badge (evidence: shot-walk-02-j2). Outcome: worked.
- Insights autosave and persist locally; last-edited reflects saves *(prd-14)* — Impact high because real persistence is the point. I tried typing an insight; I saw the last-edited stamp update and the text carry to Preview and disk (evidence: shot-walk-04-j4). Outcome: worked.
- Re-pull refreshes automated KPIs only, preserving manual/insights *(prd-15)* — Impact medium because it is a refinement of the pull. I tried to find a re-pull path; there were no automated KPIs and no re-pull was run (evidence: none). Outcome: couldn't check (unobservable).
- Locking is per-month only, gated on non-empty insights, 'Lock {Month Year}?' dialog *(prd-16)* — Impact high because the lock model is the mission law. I tried locking blank then full; I saw it refuse while blank and open the 'Lock September 2026?' dialog at 19/19 (evidence: shot-walk-09-j9). Outcome: worked.
- Locked month renders all buckets read-only *(prd-17)* — Impact medium because it guards a published month. I tried to reach the locked state; the lock was not confirmed so I only saw the equivalent read-only Preview (evidence: none). Outcome: couldn't check (unreachable).
- Dialogs centered over dimmed backdrop with icon badge, Esc/backdrop dismiss *(prd-18)* — Impact medium because it is dialog polish. I tried opening the lock dialog; I saw a centered dimmed-backdrop overlay with a lock icon badge (evidence: shot-walk-09-j9). Outcome: worked.
- Nav actions: Continue/Preview/View *(prd-19)* — Impact high because these actions are the flow. I tried Continue and Preview/back; I saw the builder, the read-only preview and a working back-out (evidence: shot-walk-06-j6). Outcome: worked.
- Builder follows global theme; builder-local toggle dropped *(prd-20)* — Impact medium because it is a simplification. I tried to find a builder-local toggle; I saw only Preview and Lock month, with theme handled globally (evidence: shot-walk-02-j2). Outcome: worked.
- Visual and flow parity with the mockup *(prd-21)* — Impact medium because parity is close but the buttons are cosmetically wrong. I tried comparing to the drawing; I saw oversized icons and three-line labels on the green buttons (evidence: shot-walk-00-wayin). Outcome: didn't.
- Kpi/Snapshot expose new optional fields *(t-001-ac1)* — Impact low because it is an internal type. I tried to settle it; there is no visual surface and the suite was contaminated (evidence: none). Outcome: couldn't check (unobservable).
- Snapshot omitting new fields still valid *(t-001-ac2)* — Impact low because it is an internal type rule. I tried to settle it; nothing visible and no clean test line (evidence: none). Outcome: couldn't check (unobservable).
- sourceDeltas reuses SubReading shape *(t-001-ac3)* — Impact low because it is code hygiene. I tried to settle it; no surface and no clean test line (evidence: none). Outcome: couldn't check (unobservable).
- parseHash returns the matching step *(t-002-ac1)* — Impact medium because routing drives the flow. I tried to settle the parse itself; it is non-visual and the suite was contaminated (evidence: none). Outcome: couldn't check (unobservable).
- Unknown #mbr/<x> falls back to start *(t-002-ac2)* — Impact low because it is an edge guard. I tried to settle it; it was not exercised and is non-visual (evidence: none). Outcome: couldn't check (unreachable).
- MbrBuilderView renders a step slot per route.step *(t-002-ac3)* — Impact high because the flow needs distinct screens. I tried each route; I saw start, collect, build and preview render differently (evidence: shot-walk-06-j6). Outcome: worked.
- Production build resolves view==='mbr' to Default view *(t-002-ac4)* — Impact low because it is a build-variant gate. I tried to check it; this is a dev build so it is unreachable (evidence: none). Outcome: couldn't check (unreachable).
- parseMetricValue normalises value/unit, WIP→null *(t-003-ac1)* — Impact medium because it underpins deltas. I tried to settle it; it is non-visual and the suite was contaminated (evidence: none). Outcome: couldn't check (unobservable).
- computeDelta neutral on unparseable/mismatched units *(t-003-ac2)* — Impact medium because it guards delta correctness. I tried to settle it; non-visual, contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- computeDelta signed magnitude with shared unit *(t-003-ac3)* — Impact medium because it feeds visible deltas. I tried to settle it; non-visual, contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- Cohort diffing matches sub-readings by label *(t-003-ac4)* — Impact medium because it guards cohort deltas. I tried to settle it; non-visual, contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- STATUS_META.negative.shape is 'x' *(t-004-ac1)* — Impact low because it is internal metadata. I tried to settle it; non-visual, contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- .status-dot--x renders an X silhouette distinct by shape *(t-004-ac2)* — Impact medium because shape-not-colour distinction is intended. I tried comparing markers; I saw an X for off-track versus a filled circle for on-track (evidence: shot-walk-06-j6). Outcome: worked.
- Other four status shapes remain circle/triangle/ring/half-circle *(t-004-ac3)* — Impact low because they are pre-existing shapes. I tried to confirm each mapping; it is non-visual and not cleanly readable (evidence: none). Outcome: couldn't check (unobservable).
- Disk-reading shape tests assert 'x' and suite green *(t-004-ac4)* — Impact low because it is test maintenance. I tried to settle it; non-visual and the suite was contaminated (evidence: none). Outcome: couldn't check (unobservable).
- Start card: pill, heading, meta, green button, hint *(t-005-ac1)* — Impact high because it is the primary CTA. I tried reading the card; I saw the pill, heading, meta, green button and hint (evidence: shot-walk-00-wayin). Outcome: worked.
- Published list rows: lock icon, chip, meta, View *(t-005-ac2)* — Impact medium because it is history access. I tried reading the row; I saw the lock icon, chip, meta and View (evidence: shot-walk-00-wayin). Outcome: worked.
- View navigates to #locked/<id> *(t-005-ac3)* — Impact medium because it opens history. I tried to confirm the route; View was not clicked (evidence: none). Outcome: couldn't check (unreachable).
- Existing draft: primary action reads 'Continue draft' *(t-005-ac4)* — Impact medium because it prevents reseeding loss. I tried to see the resume state; the start showed a fresh un-started card (evidence: none). Outcome: couldn't check (unreachable).
- Fresh pull mints date-keyed draft id *(t-005-ac5)* — Impact medium because ids underpin history. I tried reading the id; I saw 'Snapshot 2026-09-20.0' (evidence: shot-walk-06-j6). Outcome: worked.
- Bucket rows cycle chips behind a progress bar *(t-006-ac1)* — Impact medium because it must show progress. I tried reading the rows; I saw a progress bar and per-bucket values-pulled chips (evidence: shot-walk-01-j1). Outcome: worked.
- Continue disabled until done, then #mbr/build; Cancel→#mbr *(t-006-ac2)* — Impact high because it gates the builder. I tried Continue; I saw it move to #mbr/build (evidence: shot-walk-01-j1). Outcome: worked.
- Seeded draft freezes target/previousValue/delta *(t-006-ac3)* — Impact medium because it feeds the cells. I tried to settle it; non-visual and contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- No-fresh-value KPI carries forward with carried=true *(t-006-ac4)* — Impact medium because it drives the pill. I tried to settle the flag; it is non-visual and the suite was contaminated (evidence: none). Outcome: couldn't check (unobservable).
- Automatable partition from aiUpdateInstructions *(t-006-ac5)* — Impact medium because it decides collection. I tried to settle it; non-visual and contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- Head + toolbar with no theme toggle *(t-007-ac1)* — Impact high because it is the builder chrome. I tried reading them; I saw eyebrow/title/subtitle and Preview + amber Lock month, no toggle (evidence: shot-walk-02-j2). Outcome: worked.
- Amber draft banner with dot, text, meta *(t-007-ac2)* — Impact high because it signals local save. I tried reading it; I saw the dot, text and meta (evidence: shot-walk-02-j2). Outcome: worked.
- Completion bar counts non-empty insights *(t-007-ac3)* — Impact high because it is the lock gate. I tried typing insights; I saw the bar count only non-empty insights up to 19/19 (evidence: shot-walk-02-j2). Outcome: worked.
- Bucket header N KPIs + N of M insights, no lock badge *(t-007-ac4)* — Impact high because the no-per-bucket-lock model is core. I tried reading the header; I saw the counts and no lock badge (evidence: shot-walk-02-j2). Outcome: worked.
- KPI row: name, value, status select, insight textarea filled when non-empty *(t-007-ac5)* — Impact high because rows are where the review is built. I tried inspecting a row; I saw name/value/status-select/insight with filled backgrounds when non-empty (evidence: shot-walk-02-j2). Outcome: worked.
- Insight autosave PUT debounced + stamps lastEditedAt *(t-007-ac6)* — Impact medium because saving is confirmed visibly elsewhere. I tried to observe the PUT; only the last-edited stamp is visible, not the request (evidence: none). Outcome: couldn't check (unobservable).
- Old builder controls gone, tests updated *(t-007-ac7)* — Impact medium because leftovers would confuse. I tried to find the old controls; none are present (evidence: shot-walk-02-j2). Outcome: worked.
- Wired value cell: value, target, delta, Auto tag, Collect *(t-008-ac1)* — Impact medium because it is one variant. I tried to find one; every KPI is manual (evidence: none). Outcome: couldn't check (unreachable).
- Collect lifecycle chips (Collecting/Updated/failed) *(t-008-ac2)* — Impact medium because they are wired-only. I tried to trigger a collect; no wired KPIs exist (evidence: none). Outcome: couldn't check (unreachable).
- Successful collect shows 'was {old} · as of {date}' *(t-008-ac3)* — Impact low because it is a wired-only detail. I tried to find it; no wired collect is possible (evidence: none). Outcome: couldn't check (unreachable).
- Re-collect applies value, stamps asOf, recomputes delta *(t-008-ac4)* — Impact medium because it keeps deltas honest. I tried to settle it; non-visual and no wired KPI (evidence: none). Outcome: couldn't check (unreachable).
- Manual value: editable input, target, delta *(t-009-ac1)* — Impact medium because it is the common cell type. I tried inspecting one; I saw an editable input with target and delta (evidence: shot-walk-02-j2). Outcome: worked.
- Manual cell: prefill note, Manual tag, amber needs-value *(t-009-ac2)* — Impact medium because it guides editing. I tried inspecting them; I saw the note, Manual tag and amber empty state (evidence: shot-walk-02-j2). Outcome: worked.
- Editing a manual value recomputes delta, never hand-typed *(t-009-ac3)* — Impact medium because it keeps deltas trustworthy. I tried to settle it; no manual value was edited and it is non-visual (evidence: none). Outcome: couldn't check (unobservable).
- Editing manual value clears carried; no lock/asOf step *(t-009-ac4)* — Impact medium because it keeps provenance honest. I tried to settle it; no edit was made and it is non-visual (evidence: none). Outcome: couldn't check (unobservable).
- 'As of' defaults to the pull date *(t-009-ac5)* — Impact low because it is a stamping detail. I tried to settle it; no manual value was committed and it is non-visual (evidence: none). Outcome: couldn't check (unobservable).
- Cohort KPI lists sources with delta and caption *(t-010-ac1)* — Impact medium because it is a KPI variant. I tried inspecting it; I saw per-source rows with deltas and the caption (evidence: shot-walk-02-j2). Outcome: worked.
- Each source's delta matched by label *(t-010-ac2)* — Impact medium because it guards cohort deltas. I tried to settle it; non-visual and contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- No comparable prior renders neutral placeholder *(t-010-ac3)* — Impact low because it is an edge case. I tried to settle it; non-visual and not distinguishable here (evidence: none). Outcome: couldn't check (unobservable).
- Amber warn box with N of M automatable + automate button *(t-011-ac1)* — Impact medium because it is a bulk convenience. I tried to find it; no automatable KPIs so no box (evidence: none). Outcome: couldn't check (unreachable).
- Update-all indeterminate progress strip *(t-011-ac2)* — Impact low because it is sweep-only. I tried to trigger it; no automatable KPIs (evidence: none). Outcome: couldn't check (unreachable).
- Automatable count over flattened draft *(t-011-ac3)* — Impact low because it is internal. I tried to settle it; non-visual and contaminated suite (evidence: none). Outcome: couldn't check (unobservable).
- Sweep refreshes automatable only, preserving manual/insights *(t-011-ac4)* — Impact medium because it protects manual work. I tried to settle it; no automatable KPIs and non-visual (evidence: none). Outcome: couldn't check (unreachable).
- Lock dialog centered, dimmed, warn badge, insight summary *(t-012-ac1)* — Impact high because locking publishes the month. I tried it; I saw the centered dimmed 'Lock September 2026?' dialog with the insight-count summary (evidence: shot-walk-09-j9). Outcome: worked.
- Lock blocked while any insight blank *(t-012-ac2)* — Impact high because it is the publish gate. I tried both states; blank did nothing and full opened a 'ready to publish' dialog (evidence: shot-walk-09-j9). Outcome: worked.
- Locking sets lockedBy null and renders buckets read-only *(t-012-ac3)* — Impact medium because it guards published data. I tried to reach it; the lock was not confirmed (evidence: none). Outcome: couldn't check (unreachable).
- Discard opens 'Discard this draft?' danger dialog *(t-012-ac4)* — Impact medium because it protects against loss. I tried to confirm it; the button was not clicked (evidence: none). Outcome: couldn't check (unreachable).
- Unlock is a single month-only confirm, no note field *(t-012-ac5)* — Impact medium because it reverses a lock. I tried to reach it; no month was locked (evidence: none). Outcome: couldn't check (unreachable).
- Every dialog dismissable by backdrop or Esc *(t-012-ac6)* — Impact low because it is a dismissal nicety. I tried to settle it; it is not observable from a still (evidence: none). Outcome: couldn't check (unobservable).
- Preview navigates to #mbr/preview read-only with back-out *(t-013-ac1)* — Impact high because previewing before lock is core. I tried Preview and back; I saw the read-only draft and a working back-out (evidence: shot-walk-06-j6). Outcome: worked.
- Preview and View share one read-only component *(t-013-ac2)* — Impact medium because it is a consistency choice. I tried to settle it; View was not opened (evidence: none). Outcome: couldn't check (unreachable).
- LockedView hides 'Locked by' when null *(t-013-ac3)* — Impact low because it is a cosmetic guard. I tried reading the header; there is no 'Locked by' line (evidence: shot-walk-06-j6). Outcome: worked.
- Amendments section renders for a snapshot with amendments *(t-013-ac4)* — Impact low because it is a historical case. I tried to reach it; no such snapshot was opened (evidence: none). Outcome: couldn't check (unreachable).
- 'Pull data & start' button matches the drawing *(part-pull data start)* — Impact medium because it is the landing CTA and works but looks wrong. I tried comparing to the drawing; I saw an oversized icon and a three-line label (evidence: shot-walk-00-wayin). Outcome: didn't.
- 'View' button matches the drawing *(part-view)* — Impact low because it is a small secondary control that renders cleanly. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- pullBar (collect progress bar) matches the drawing *(part-pullBar)* — Impact low because it is a decorative bar. I tried comparing; I saw the progress bar above the bucket rows (evidence: shot-walk-01-j1). Outcome: worked.
- 'Cancel' button matches the drawing *(part-cancel)* — Impact low because it is a plain text control that renders cleanly. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- 'Continue to builder' button matches the drawing *(part-continueBtn)* — Impact medium because it is the collect CTA and works but looks wrong. I tried comparing; I saw an oversized arrow and a three-line label (evidence: shot-walk-01-j1). Outcome: didn't.
- builder theme-toggle button matches the drawing *(part-themeBtn)* — Impact low because the brief dropped it. I tried to find the toggle; it is intentionally absent per prd-20 (evidence: none). Outcome: couldn't check (unreachable).
- 'Preview' button matches the drawing *(part-preview)* — Impact low because it is a clean toolbar control. I tried comparing; I saw a compact Preview button (evidence: shot-walk-02-j2). Outcome: worked.
- 'Lock month' button matches the drawing *(part-lock month)* — Impact medium because it is the primary publish action and shows a minor icon overflow. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- 'Discard draft' button matches the drawing *(part-discard draft)* — Impact low because it renders as a plain in-banner control. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- 'Update all automatically' button matches the drawing *(part-automateBtn)* — Impact low because its box is absent. I tried to find it; no automatable KPIs so no button (evidence: none). Outcome: couldn't check (unreachable).
- 'Re-collect' button matches the drawing *(part-re collect)* — Impact low because it is wired-only. I tried to find it; no wired collect is possible (evidence: none). Outcome: couldn't check (unreachable).
- status select matches the drawing *(part-on trackwatchoff tracktrackingwip)* — Impact medium because it is the row's editorial control shown across every KPI. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- insight textarea matches the drawing *(part-gh gh remains the long pole copilot and go sdlc well inside target)* — Impact medium because writing insights is the builder's main task. Your drawing names this part and I could not find it in the build, so there was nothing to look at — couldn't check. Outcome: couldn't check.
- From start, click 'Pull data & start' → collect screen *(journey-j1)* — Impact high because it is the first flow step. I tried the click; I saw the collect screen appear (evidence: shot-walk-01-j1). Outcome: worked.
- From collect, click 'Continue to builder' → builder *(journey-j2)* — Impact high because it enters the builder. I tried the click; I saw the builder appear (evidence: shot-walk-02-j2). Outcome: worked.
- Try 'Lock month' with fields blank → it refuses *(journey-j3)* — Impact high because it proves the gate refuses. I tried the click; nothing opened or navigated (evidence: shot-walk-03-j3). Outcome: worked.
- Type into an insight → it carries *(journey-j4)* — Impact high because insight entry is essential. I tried typing; I saw the text stick and the count rise (evidence: shot-walk-04-j4). Outcome: worked.
- Type into a second insight → it carries *(journey-j5)* — Impact high because it confirms repeated entry works. I tried typing; I saw it stick and the count rise (evidence: shot-walk-05-j5). Outcome: worked.
- Click 'Preview' → the preview screen *(journey-j6)* — Impact high because previewing is core. I tried the click; I saw the read-only preview with my insights (evidence: shot-walk-06-j6). Outcome: worked.
- Come back → the builder *(journey-j7)* — Impact medium because it is a supporting move. I tried the click; I returned to the builder (evidence: shot-walk-07-j7). Outcome: worked.
- Fill every remaining field *(journey-j8)* — Impact medium because it sets up the lock. I tried filling; the meter reached 19/19 though two WIP value cells stayed non-editable (evidence: shot-walk-08-j8). Outcome: worked.
- Click 'Lock month' now everything is filled → it opens *(journey-j9)* — Impact high because completing the lock is the end of the mission's flow. I could not take this step: I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked. Outcome: couldn't check.

### What I measured on your drawing, and what I saw walking it

I held each part of your drawing against the part the build renders, and I walked the flow myself. These are what came back. They are findings — act on them.

- the "Pull data & start" button on http://localhost:5173/DX-Scorecard/?snapshot=2026-07-27.0#mbr holds an icon 55px tall inside a control only 38px tall — the icon is bigger than the button it sits in, and its label runs onto 3 lines
- the "Continue to builder" button on http://localhost:5173/DX-Scorecard/?snapshot=2026-07-27.0#mbr/collect holds an icon 61px tall inside a control only 32px tall — the icon is bigger than the button it sits in, and its label runs onto 3 lines
- the "Back to builder" button on http://localhost:5173/DX-Scorecard/?snapshot=2026-07-27.0#mbr/preview holds an icon 41px tall inside a control only 30px tall — the icon is bigger than the button it sits in, and its label runs onto 3 lines
- the "Lock month" button on http://localhost:5173/DX-Scorecard/?snapshot=2026-07-27.0#mbr/build holds an icon 34px tall inside a control only 32px tall — the icon is bigger than the button it sits in, and its label runs onto 2 lines
- August 2026 became September 2026 after I clicked "pull data & start" — the month did not carry from one screen to the next  *(on http://localhost:5173/DX-Scorecard/?snapshot=2026-07-27.0#mbr/collect)*

### Things I noticed that are not on your list

None of these come from your drawing or your PRD — they never change the score above. I am just telling you what I saw.

- the unlabeled button and the unlabeled button are crowded together — 7 px between them
- the Cancel button and the unlabeled button are crowded together — 7 px between them

Three things on this page were behind something solid, so I could not look at them.

*The numbers I used: I flag two controls less than 8 px apart, a row whose left edge is more than 6 px off from the others, and text that needs more than 2 px of room it does not have. Tell me if these are wrong for your eye — that calibration is yours to make.*

### How I walked it

I moved through it with 7 click(s), 3 typing(s) and 0 keypress(es), and never by typing an address.

- find the way in by clicking "mbr builder" — and nothing on the screen changed
- from the start screen, click "Pull data & start"
- from the collect screen, click "Continue to builder"
- try "Lock month" with the field(s) still blank — and nothing on the screen changed
- type into "gh/gh remains the long pole; Copilot and"
- type into "Above target for the third month running"
- click "Preview", the way the PRD describes it
- come back the way the record says you can
- fill every field this screen still wants — I filled 1 of 33 field(s); I could not fill [wip] baseline skills and shift left metrics value, copilot sre impact score value
- **couldn't check (nothing changed)** — click "Lock month" now everything is filled: I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked

**Nothing in this repo declares sample data for a look, so the screens that only appear once there is data in them I could not see: #screen-builder, #bulkBar, #modal-discard, #modal-unlock, view.** That is not a fault in your build — it is a gap in what I was given.

**I also looked at:** The Preview screen renders a clean read-only 'Locked MBR · September 2026' with current/target/insight columns and a status silhouette per row, and hides the 'Locked by' line ('Locked at —'); it looks correct.; The month heading changes from 'August 2026' on the start card to 'September 2026' on the collect screen — an observation flagged it as a value not carrying, but it reads as intentional (the pull opens the next month), so I did not file it.; Content differences from the drawing (build shows 19 KPIs and one Published month; drawing shows 14 KPIs and two) are seed/data differences, not build faults.

**These are yours to decide:** The project's test suite came back 'failed' (7 of 597), but every failure is contamination from the Verify walk itself writing to disk: the failing diffs contain the walk's own typed text ('Number One typed this to see it carry') and a new walk-created snapshot '2026-09-20.0' that the snapshot-listing tests then picked up. These are not clean build defects — they are the verify run mutating the shared data/snapshots fixtures. Re-run the suite from a clean checkout before reading anything into it.; This seed has no wired/automated KPIs (every KPI is 'Manual', the pull reported '0 values pulled'), so the wired value-cell, Collect/Re-collect chips and the Refresh-all/'Update all automatically' box could not be exercised at all. A seed containing at least one automated KPI is needed to verify prd-5, prd-10 and the t-008/t-011 tickets.

<details><summary>How I put this together</summary>

- journey-j9 is the journey step "click "Lock month" now everything is filled", and I could not take it (I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked) — so it is not-checkable, whatever the look called it
- part-view is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it
- part-cancel is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it
- part-lock month is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it
- part-discard draft is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it
- part-on trackwatchoff tracktrackingwip is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it
- part-gh gh remains the long pole copilot and go sdlc well inside target is about a part of your drawing the build has not got (your drawing names this part; I could not find it anywhere I looked, by test id, by id, by its label or by its role), so I am marking it couldn't-check rather than trusting what the look called it

</details>
