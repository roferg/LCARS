# Validated plan — Settings panel v2

Research confirmed the repo state: `src/styles.css` today defines only
`:root`, `body`, `.panel`, `.row` and `.row-label`. There is NO `.overlay`,
`.modal` or `.modal-foot` rule anywhere in the repo, and no modal helper — the
overlay/modal primitives are genuinely new work.

`src/panel.js` builds its rows inline inside `renderPanel`; extracting a
`SettingsRow` is the foundation every later control mounts into.
`src/store.js` returns a fresh copy of `DEFAULTS` and touches no storage.

## Approach
Extract the row foundation and add persistence first — they are independent of
each other and of everything else. Every later addition (reset button, modal
primitives, toggle control, confirmation modal, unsaved banner, keyboard
navigation) mounts into the row foundation and is independent of its siblings,
so they can be built in parallel.

## Risks
The confirmation modal needs the overlay/modal CSS; if it is built before those
primitives exist it will render unstyled.
