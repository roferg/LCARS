# PRD — measured fixture A

Reconstructed from the captain's own Mission (lcars-20260829-002), whose
`## Open questions from the design session` section recorded ten decisions and
whose Plan Review then called one of them "an UNSETTLED open question with no
captain resolution". The subject matter is deliberately NOT the point — what is
under test is the SHAPE: a declared `RESOLVED` prefix, a question, a separator,
an answer.

## Goal

Build the thing the drawing shows.

## Open questions from the design session

- RESOLVED with the captain: Does "lock" happen per-bucket, per-month, or both? — Per month; the mockup's per-bucket "Locked"/Unlock chrome is reinterpreted as the month's locked appearance with month-level unlock.
- RESOLVED with the captain: Must every KPI have an insight before the month can be locked? — Yes; "publishes without commentary" note dropped.
- RESOLVED with the captain: Should the builder follow the app's global theme instead of its own toggle? — Follow global; drop own toggle.
- RESOLVED with the captain: Is the draft stored locally only, or synced? — Local only.
- STILL OPEN: Should a locked month be exportable to PDF?
- RESOLVED with the captain: When a value is edited manually, do the delta-vs-last-MBR and status recompute
  automatically? — Delta auto-recomputes; status does not.
- **RESOLVED:** Is a KPI's insight saved on blur, or explicitly saved? — Autosaved as you type.

## Constraints

- Visual/flow parity with the mockup is an acceptance criterion.
