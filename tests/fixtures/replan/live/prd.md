# Settings panel v2

## Problem
The settings panel (`src/panel.js`) renders every setting as a static
label/value row. Nothing can be changed, nothing persists, and with more than a
handful of settings the list is hard to scan.

## What we are building
A v2 panel that is editable, persistent and navigable:

- A reusable `SettingsRow` element extracted from `renderPanel`, so every later
  control mounts into one row shape instead of forking the markup.
- Settings persisted to `localStorage` in `src/store.js`, loaded on boot.
- A "Reset to defaults" button in the panel header.
- Overlay/modal primitives in `src/styles.css` (`.overlay`, `.modal`,
  `.modal-foot`) plus a small `Modal` helper — the app has none today.
- A toggle control for boolean settings, replacing the plain `true`/`false` text.
- A confirmation modal before a reset actually discards the user's settings.
- An "unsaved changes" banner shown when the in-memory settings differ from
  what is persisted.
- Keyboard navigation across rows (arrow keys move focus, Enter activates).

## Out of scope
Theming, server sync, and any change to the boot sequence in `src/app.js`.
