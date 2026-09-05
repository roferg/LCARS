# Mission: Dashboard shell gains twelve independent panels

**Type:** feature

**Goal:** An existing React + Vite app already ships a working application
shell — a persistent left navigation rail, a top bar, a router with a route
table, and a global `styles.css` with the design tokens already defined. This
mission adds TWELVE separate panels into that existing shell. Each panel is its
own screen behind its own route; each reads only its own mocked data module;
none of them imports, renders, or reads any other panel's code. The shell, the
router, the nav rail and the tokens all already exist and are NOT created by
this mission.

**Acceptance Criteria:**
- A **Reviews landing** panel lists submitted reviews with a status pill per row
- A **Pulling-data** panel shows an animated progress state while a fetch is in flight
- A **Coverage** panel renders a percentage ring and a per-area breakdown list
- A **Ownership** panel renders a table of components and their owning team
- A **Alerts** panel renders a severity-sorted list with a dismiss control per row
- A **Backlog** panel renders grouped work items with a collapse control per group
- A **Throughput** panel renders a bar series with a range selector
- A **Incidents** panel renders a timeline of incidents with a detail drawer
- A **Dependencies** panel renders a searchable list of external packages
- A **Settings** panel renders the toggles for the notification preferences
- A **Glossary** panel renders an alphabetised term list with anchor links
- A **About** panel renders the build metadata and the release notes link
- Every panel is reachable from the existing nav rail and renders standalone
- Every panel has its own tests that pass without any other panel present

**Out of Scope:**
- Creating or changing the application shell, the router, or the nav rail — they exist
- Changing the test runner, the build config, the package manifest, or CI
- Introducing a shared component library, a shared layout, or shared helpers
- Any backend, API, or persistence work — each panel reads a local mocked module

**Constraints:**
- Each panel owns its own directory and its own stylesheet-scoped class names
- Panels must not import from one another
- The existing design tokens in `styles.css` are consumed, never redefined
