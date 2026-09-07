# Mission: Show the imported total on the page

**Type:** feature

## Problem

The foundation landed with a thin slice, but nothing on screen tells the
captain how much money the imported rows add up to. He has to add them up
himself, which is the one arithmetic a finance app should never leave to a
human.

## Scope

ONE thin vertical slice on the foundation that the initialization mission
established:

- a pure function that sums the amounts of a list of imported rows
- the running total rendered on the page beside the rows
- one real test for the sum, written first and red before the code exists

## Out of Scope

Budgets, charts, bank sync, categories, currency handling, persistence, and
every other feature recorded in the vision. This mission exists to prove that
ORDINARY work now files and runs on the new foundation.

## Acceptance Criteria

- the sum function returns 0 for an empty list
- the sum function totals a list of rows correctly
- the total is visible on the page
- the project's own test command runs the new test and it passes
