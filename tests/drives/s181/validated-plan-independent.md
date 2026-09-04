# Validated plan — twelve independent panels into an existing shell

## What already exists (not built by this mission)

The repo is an existing React + Vite + TypeScript app with its tooling already
established and green:

- `package.json`, the lockfile, and `vite.config.ts` are present and unchanged.
- `vitest.config.ts` and the global test setup file are present and unchanged.
- `src/App.tsx` renders the application shell: a persistent left nav rail, a top
  bar, and an outlet the router fills.
- `src/routes.tsx` holds the route table; adding a panel means adding one entry.
- `src/styles.css` defines the design tokens (color, spacing, type scale). Panels
  consume these tokens. The token block itself is not edited.
- The CI workflow already runs the test command and is unchanged.

## The work

Twelve panels are added into that existing shell. Each panel is a self-contained
screen: its own directory under `src/panels/<name>/`, its own component, its own
locally-scoped class names, its own mocked data module, and its own test file.

1. **Reviews landing** — a list of submitted reviews, one status pill per row.
2. **Pulling-data** — an animated in-flight state shown while a fetch resolves.
3. **Coverage** — a percentage ring plus a per-area breakdown list.
4. **Ownership** — a table of components against their owning team.
5. **Alerts** — a severity-sorted list, each row with a dismiss control.
6. **Backlog** — work items in collapsible groups.
7. **Throughput** — a bar series with a range selector.
8. **Incidents** — a timeline with a per-incident detail drawer.
9. **Dependencies** — a searchable list of external packages.
10. **Settings** — the notification-preference toggles.
11. **Glossary** — an alphabetised term list with anchor links.
12. **About** — build metadata and a link to the release notes.

## How the panels relate to each other

They do not. No panel imports, renders, reads, or asserts on another panel. Each
one reads only its own mocked data module and the tokens already defined in
`styles.css`. Each panel's tests pass with every other panel absent from the
tree. The only file all twelve touch in common is the route table, where each
adds its own independent entry.

## Risks

- Twelve entries land in one route table; each entry is independent, but the file
  is shared, so the additions must be additive and not reorder existing routes.
- The design tokens must be consumed rather than redefined, so panels stay
  visually consistent without any panel owning the token block.
