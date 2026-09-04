# Mission: Rebuild the MBR builder screen

**Type:** feature

**Goal:** The MBR builder screen is the app's main authoring surface. It is one
long scrolling view, `src/builder/BuilderView.tsx`, rendered inside the app
shell that already exists, and styled from the app's single `src/styles.css`.
The screen is being rebuilt section by section. Work through the sections in
the order they appear down the page, so the screen fills in top to bottom as
the work lands.

**Acceptance Criteria:**
- The **header band** at the top of the builder shows the record name, its
  status chip, and the last-saved timestamp
- Below it, the **summary strip** shows the four headline counters
- Then the **filter row** offers the period selector and the segment dropdown
- Then the **coverage block** renders the coverage ring and its legend
- Then the **ownership block** renders the owning-team table
- Then the **alerts block** renders the severity-sorted alert list
- Then the **backlog block** renders the collapsible work-item groups
- Then the **throughput block** renders the bar series and its range control
- Then the **incidents block** renders the incident timeline
- Then the **dependencies block** renders the searchable package list
- Then the **notes block** renders the free-text notes area and its character count
- Finally, the **footer bar** at the bottom of the builder shows the save and
  discard controls
- Each section renders from its own mocked data module and has its own tests

**Out of Scope:**
- The application shell, the router, and the nav rail — they exist and are unchanged
- The test runner, the build config, the package manifest, and CI — all unchanged
- Any backend, API, or persistence work — each section reads a local mocked module
- Introducing a component library or a shared layout abstraction

**Constraints:**
- Every section is a child component of `src/builder/BuilderView.tsx` and is
  registered in that file's section list
- Every section's styles go in the app's existing `src/styles.css`, using the
  design tokens already defined there
- No section may import another section's module
