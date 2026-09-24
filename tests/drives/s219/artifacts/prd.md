# Mission: MBR View Builder

**Type:** feature
**Goal:** Rebuild the MBR (Monthly Business Review) builder to match the new mockup — a Reviews entry screen, a data-pull collection screen, and a redesigned builder — with real backend, state, and persistence behind the redesigned look and flow.

**Acceptance Criteria:**
- **Reviews entry screen** is the landing view: the next unstarted month sits in a "Next up · {Month Year}" start card showing "N buckets · M KPIs · Source: DX Scorecard (live)", a green "Pull data & start" button, and a "~30s · re-pullable anytime" hint. A "Published" list beneath shows prior months, each with a lock icon, a "Published" chip, "M KPIs · locked {date}", and a "View" button.
- **Collection screen** shows each bucket cycling Queued → Collecting… → "N values pulled" behind a progress bar, with a Cancel control and a "Continue to builder" button that stays disabled until the pull finishes.
- **Builder** matches the mockup: eyebrow "Monthly Business Review"; title "MBR builder · {month}"; subtitle "Assemble this month's review from the live scorecard. Add an insight to each KPI, then lock the month to publish it."; a Preview toolbar button; an amber primary "Lock month" button.
- **Draft banner** is an amber-tinted banner with a warning dot reading "Draft — changes are saved locally as you go", a "Last edited {t} · N of M buckets complete" meta, and a "Discard draft" button inside it.
- **Refresh-all** lives in an amber warning box stating it only collects KPIs with automated instructions ("11 of 14"), leaves the manual KPIs unchanged, and drives an indeterminate progress strip.
- An **"Insights added — N of M KPIs" completion bar** sits under the banner; a KPI counts as done when its insight text is non-empty (status is not part of the meter). The meter reaching all KPIs is exactly the month-lockable condition.
- **Per-KPI status** is set in the builder: seeded from the scorecard's current status at data-pull time and freely overridable (editorial snapshot, not a live mirror). Rendered as an editable select over the five silhouettes (On track / Watch / Off track / Tracking / WIP). Status is never auto-recomputed — human-only. The off-track marker is an X shape (distinct from the on-track circle without relying on colour).
- **Value/target/delta** arrive with the data pull: wired KPIs collect a fresh value; target comes from the KPI's config/default view; delta-vs-last-MBR is always computed (this month's value minus the same KPI's value in the previous published MBR). Editing a manual value recomputes its delta automatically; deltas are never hand-typed.
- **Manual (unwired) KPIs** are edited inline (unit, target, delta, "From default view · edit to override" note, "Manual" tag, amber "needs value" state) with no per-value lock/asOf step; "As of" defaults to the pull date.
- **Wired KPI value cells** show the value, target, a "vs last MBR" delta, an "Auto" tag, and Collect / Re-collect / Try again controls with Collecting…/✓ Updated/Collection failed chips, a spinner, and a "was {old} · as of {date}" line.
- **Multi-value (cohort) KPIs** show a per-source "change vs last MBR" delta column (up/down/no-change) with a "change vs last MBR" caption.
- **Carried KPIs** render a purple "Carried" pill with a clock icon. A KPI is Carried when the data pull returns no fresh value and the builder carries forward the value/status from the previous published MBR — an objective, computed-at-pull-time provenance fact, kept separate from the status marker.
- **Bucket headers** read "N KPIs" with an "N of M insights" sub-count. Buckets carry no per-bucket lock state, badge, or unlock control.
- **Insights** autosave on blur and debounced while typing (no explicit save control); a non-empty insight gets a distinct filled background. The whole draft persists to `data/snapshots/<id>.json` via the existing dev-write bridge; the "last edited" meta reflects the latest autosave.
- **Re-pull** re-runs collection for automated KPIs only, recomputing their deltas; every manual value and every insight is preserved untouched; a KPI that returns no fresh value stays as it was (Carried included).
- **Locking is per-month only.** There is no per-bucket lock: buckets are never individually locked or unlocked. The month cannot lock or publish while any KPI has a blank insight, so a published month never contains an insight-less KPI. The lock dialog is "Lock {Month Year}?" with a summary reflecting insight completeness (empty insights block the lock), and no "Locked by" handle field.
- **When the month is locked, all its buckets render read-only** solely because the month is locked: static values, status shown as a label (not a select), insight shown as text (not a textarea). The only way to make them editable again is to unlock the month.
- **Dialogs** (discard, lock, unlock-month) are centered overlay dialogs over a dimmed backdrop, each with a coloured icon badge, dismissable by backdrop click or Esc. Discard is "Discard this draft?" with a danger icon and a "Keep editing" / "Discard draft" pair. Unlock is a simple confirm to unlock the month, with no note field. There is no "Unlock this bucket?" dialog.
- **Nav actions:** Continue to builder enters the draft builder for the month once the pull finishes; Preview renders the current draft read-only exactly as it will publish (back out without locking); View opens a published month's locked snapshot in that same read-only rendering (reusing the existing LockedView path). Preview and View share one presentation component, differing only in draft-vs-snapshot source.
- **Theme:** the builder follows the app's global theme; the builder-local theme toggle drawn in the mockup is dropped.
- Visual and flow parity with the mockup (layout, colour, spacing, wording, screen transitions) is met, except where the per-month lock model and the single global theme override the mockup's per-bucket lock affordances and builder-local theme toggle.

**Out of Scope:**
- A synced/server-side backend for drafts or snapshots — persistence stays local-only on disk.
- A per-value "Lock in value" + editable As-of commit step for manual KPIs (the existing Update KPIs page's model) — the MBR builder uses inline manual editing instead.
- Per-bucket locking/unlocking of any kind (badge, per-bucket Unlock button, per-bucket read-only rendering, "Unlock this bucket?" dialog).
- A builder-local theme toggle.
- Changing the existing commit/PR-to-publish path.

**Constraints:**
- Build for real — backend, state, and persistence behind the redesigned look; the mockup's own interactions are illustrative only.
- Visual/flow parity with the mockup is an acceptance criterion.
- Where mockup and brief disagree on WHAT IT MUST DO, the brief wins; where they disagree on HOW IT LOOKS, the mockup wins.
- Draft and snapshot persistence is local-only on disk (`data/snapshots/<id>.json` via the existing dev-write bridge); no backend service.
- Reuse the existing LockedView rendering path for View and Preview.
- Locking is month-only; the lock gate is every KPI having a non-empty insight (LAW 2).

## Open questions from the design session

- RESOLVED with the captain: Does "lock" happen per-bucket, per-month, or both? — Per month only; there is no per-bucket lock.
- RESOLVED with the captain: Must every KPI have an insight before the month can be locked? — All insights need text before locking.
- RESOLVED with the captain: Status set in builder or inherited from the scorecard? — Set in the builder, seeded from the scorecard's current status on pull, freely overridable.
- RESOLVED with the captain: What makes a KPI "Carried"? — No fresh value this pull; value/status carried from the previous published MBR (data-provenance), kept separate from the status marker.
- RESOLVED with the captain: Manual value entry model (inline vs Lock-in-value + As-of)? — Inline editing, no lock/asOf step (follow the mockup); As-of defaults to the pull date.
- RESOLVED with the captain: What do "Preview", "View", and "Continue to builder" do? — Continue enters the draft builder once the pull finishes; Preview renders the current draft read-only as it will publish (no lock); View opens a published month's locked snapshot in that same read-only rendering (reuses the existing LockedView path); Preview and View share one presentation component.
- RESOLVED with the captain: The theme toggle in the toolbar flips dark/light — should the builder follow the app's global theme instead of having its own toggle? — Follow the app's global theme; drop the builder's own toggle.
- RESOLVED with the captain: The mockup adds a theme-toggle button to the builder toolbar, but the app already has a global theme toggle — should the builder carry its own, or just follow the global theme? — Just follow the global theme; the builder carries no toggle of its own (single source of truth per CONTEXT.md).
- RESOLVED with the captain: Is a non-empty insight the bar for "done", or must status also be set? — Completion = non-empty insight only; status is not part of the meter; the meter equals the lock gate.
- RESOLVED with the captain: Do value/target/delta arrive with the pull, and does editing a value recompute delta/status? — Value/target/delta arrive on pull; delta is always computed (this month minus last published MBR); editing a manual value recomputes delta only; status stays human; target from the KPI's config/default view.
- RESOLVED with the captain: Does an insight-less KPI still publish? — No; the month cannot lock or publish with any blank insight, so a published month never contains an insight-less KPI. The mockup's lock-modal copy about publishing blanks is dropped.
- RESOLVED with the captain: Is the draft stored locally only or synced? — Local-only on disk via the dev-write bridge to `data/snapshots/<id>.json`; no backend; publish via the existing commit/PR path.
- RESOLVED with the captain: Is an insight saved on blur/autosaved, or does it need an explicit save action? — Autosave on blur + debounced while typing; no explicit save control; the "last edited" meta reflects the latest autosave.
- RESOLVED with the captain: Is the re-pull rule "automatic only, manual + insights untouched"? — Yes; re-pull refreshes automated values only (recomputing their deltas); manual values and all insights are untouched; a KPI with no fresh value stays as it was (Carried included).

## Attached files

What arrived: 1 HTML mockup, 1 written document. Each is listed below by path relative to this mission's directory.

The HTML mockup is a VISUAL REFERENCE ONLY. It defines LOOK AND FLOW — layout,
colour, spacing, wording, and the transitions between screens — and matching it
visually is an acceptance criterion of this work. It is NOT an implementation:
its internals are deliberately fake, hand-written to look right and wired to
nothing. Do not import it, do not copy its internals as code, do not edit it to
change behaviour, and never ship it — it is not part of this repository's
source and it is not a file this work may modify.
Where the mockup and the brief disagree about WHAT IT MUST DO, the brief OVERRIDES the mockup. That is a TIE-BREAK, not a claim that the brief is exhaustive — the brief can be missing something the mockup has. Where they disagree about HOW IT LOOKS, it is the other way round: the mockup is the authority and OVERRIDES the brief, including any line of the brief that says a thing was kept or left unchanged. The mockup IS the design; the brief is an ACCOUNT of the conversation that drew it, written afterwards, and an account can describe the picture wrongly.

- attachments/attachment-01.html
- attachments/attachment-02.md
