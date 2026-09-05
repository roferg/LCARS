# Validated plan — expense tracker, from an empty repository

## Starting state

The repository is empty. There is no package manifest, no lockfile, no build
config, no test runner, no `src/` tree, and no CI workflow. Every one of those is
created by this mission.

## The work

**Foundation.** The project scaffold is created first: the package manifest and
lockfile, the Vite build config, and the initial `src/` tree that builds. The
Vitest runner is stood up with its config and its global setup file, so that the
test command runs green against an empty suite. A CI workflow is added that runs
that test command on every push.

**Shell and tokens.** The app shell renders the persistent nav rail and the
router outlet that every screen mounts into. The design-token stylesheet defines
the colors, spacing and type scale that every screen reads.

**Screens.** On top of that foundation the app's screens are built:

1. **Expense list** — expenses with a category chip per row.
2. **Expense entry** — the form that adds a new expense.
3. **Category manager** — renaming and recoloring categories.
4. **Monthly summary** — totals by category for a chosen month.
5. **Budget** — a per-category monthly cap, flagging overruns.
6. **Settings** — currency and start-of-week preferences.
7. **Export** — writes the current expenses out as CSV.

Each screen reads and writes expense data through browser storage, is reachable
from the nav rail, and carries its own tests.

## Risks

- Everything in this mission is new, so the foundation's shape determines what
  every later piece can assume — the runner's config decides what the screens'
  tests run under, and the shell decides how a screen mounts.
- The screens share the token stylesheet and the nav rail, and each adds its own
  entry to the route table.
