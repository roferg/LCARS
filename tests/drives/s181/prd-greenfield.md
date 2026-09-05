# Mission: Stand up the expense-tracker app from an empty repository

**Type:** feature

**Goal:** The repository is EMPTY — no package manifest, no build config, no test
runner, no source tree, no CI. Everything below is being created for the first
time. The finished app is a small single-page expense tracker.

**Acceptance Criteria:**
- The repository has a working project scaffold: a package manifest, a lockfile,
  a build config, and a `src/` tree that builds
- The repository has a working test runner with its config and its global setup
  file, and `npm test` runs green on an empty suite
- A CI workflow runs that test command on every push
- An **app shell** renders a persistent nav rail and a router outlet
- A **design-token stylesheet** defines the app's colors, spacing, and type scale
- An **expense list** screen lists expenses with a category chip per row
- An **expense entry** form adds a new expense
- A **category manager** screen renames and recolors categories
- A **monthly summary** screen totals expenses by category for a chosen month
- A **budget** screen sets a per-category monthly cap and flags overruns
- A **settings** screen holds the currency and the start-of-week preference
- An **export** action writes the current expenses out as a CSV file

**Out of Scope:**
- Any backend, hosted API, or real persistence — data lives in browser storage
- Authentication, multi-user support, or sharing
- Mobile-native packaging

**Constraints:**
- The stack is Vite + React + TypeScript, tested with Vitest
- Every screen is reachable from the app shell's nav rail
- Screens consume the design tokens and do not define their own colors
