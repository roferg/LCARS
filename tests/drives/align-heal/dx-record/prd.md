# Snapshot age label — DX Scorecard

A short relative age beside the snapshot selector, so anyone looking at the
scorecard can tell instantly whether it is current. Quiet metadata, not a
warning.

## Decisions

- RESOLVED with the captain: Which date should the relative age be measured from — the snapshot id's own date, a "Data as of" field, or a "Generated" timestamp? — The snapshot id's own date. Ids are already date-keyed YYYY-MM-DD.N and the selector already parses that date. We add no new field, read no file mtime, and introduce no lock-date concept.
- RESOLVED with the captain: Where exactly does the age label render? — Inline on the same line as the snapshot selector, immediately after the id. Not in the page header, not as a banner, not as a toast, not in a tooltip.
- RESOLVED with the captain: How coarse should the age buckets be? — today, yesterday, then N days ago up to 13 days, then N weeks ago up to 8 weeks, then N months ago. No hours, no minutes, no exact dates.
- RESOLVED with the captain: How should it be styled — does it draw attention? — Muted secondary text at the existing small size. No colour change, no icon, no amber, no red, no bold, however old the snapshot is.
- RESOLVED with the captain: Should an old snapshot show a staleness warning? — No. This label is descriptive only. A staleness warning is a separate decision we are not taking now.
- RESOLVED with the captain: Do draft and locked snapshots render the age differently? — No, identically. The label describes the snapshot's date, not its lifecycle state, which is already shown elsewhere.
- RESOLVED with the captain: Does the label update live while the page is open? — No. It is computed once when the view renders and recomputes when the view does. No timer, no ticking, no interval re-render.
- RESOLVED with the captain: Which timezone decides what "today" means? — The browser's local calendar date, compared date to date. We count calendar days, not elapsed hours, so a snapshot dated yesterday reads yesterday whatever the hour.
- RESOLVED with the captain: What renders when a snapshot id is malformed or dated in the future? — No label at all. The selector looks exactly as it does today. It never renders NaN, never throws, and never falls back to repeating the raw date.
- RESOLVED with the captain: May we add a date library for this? — No. Use whatever helpers already exist under src/lib/date. We are not taking a dependency for one label.
- RESOLVED with the captain: Where do the tests live and what must they cover? — Beside the existing view tests. They cover the bucket boundaries at today, yesterday, 13 days, 14 days and 8 weeks, plus the malformed-id case.
- RESOLVED with the captain: Should this touch anything under docs/mocks/? — No. That directory is a design reference and ships nothing. The work happens in src/.
- RESOLVED with the captain: Is sorting or filtering snapshots by age in scope? — No. Out of scope, along with any badge, any colour treatment, and any change to the snapshot id format.
- RESOLVED with the captain: Should an absolute date be shown anywhere alongside the relative age? — No. The relative age replaces nothing and adds nothing else; the id already carries the date for anyone who wants it.
