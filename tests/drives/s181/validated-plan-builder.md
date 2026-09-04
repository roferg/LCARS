# Validated plan — rebuild the MBR builder screen

## What already exists (not built by this mission)

An existing React + Vite + TypeScript app, tooling established and green:

- `package.json`, the lockfile, and `vite.config.ts` — present, unchanged.
- `vitest.config.ts` and the global test setup — present, unchanged.
- `src/App.tsx` — the shell: left nav rail, top bar, router outlet.
- `src/routes.tsx` — the route table; the builder route is already registered.
- `src/styles.css` — the app's single stylesheet. The design tokens are defined
  at the top of it and are consumed, never redefined.
- `src/builder/BuilderView.tsx` — the builder screen container. It renders a
  section list, currently holding placeholders.
- CI already runs the test command.

## The work

The builder screen is rebuilt one section at a time, top to bottom down the
page. Each section becomes a component under `src/builder/sections/`, is
registered in `BuilderView.tsx`'s section list, reads its own mocked data
module, and carries its own tests.

1. **Header band** — record name, status chip, last-saved timestamp.
2. **Summary strip** — the four headline counters.
3. **Filter row** — the period selector and the segment dropdown.
4. **Coverage block** — the coverage ring and its legend.
5. **Ownership block** — the owning-team table.
6. **Alerts block** — the severity-sorted alert list.
7. **Backlog block** — collapsible work-item groups.
8. **Throughput block** — the bar series and its range control.
9. **Incidents block** — the incident timeline.
10. **Dependencies block** — the searchable package list.
11. **Notes block** — the free-text notes area and its character count.
12. **Footer bar** — the save and discard controls.

## Surfaces the sections have in common

All twelve register themselves in `BuilderView.tsx`'s section list, and all
twelve add their rules to `src/styles.css` beneath the token block. Each section
reads only its own mocked data module.

## Risks

- Twelve additions land in one section list and one stylesheet, so each addition
  must be additive and must not reorder or restyle what is already there.
- The tokens at the top of `styles.css` are consumed by every section and are
  not redefined by any of them.
