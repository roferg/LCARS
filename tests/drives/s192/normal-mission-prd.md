# Mission: Print a routine of the requested length

## Type

feature

## Goal

`warmup 1` should print a real routine of at least the requested number of
minutes, drawn from the exercises the foundation mission already ships, with no
exercise repeated inside one routine. Today the duration argument is accepted
and ignored — this mission makes it mean something. It exists to prove that
ORDINARY work now files and runs on the foundation LCARS just built.

## Acceptance Criteria

- `warmup 1` prints a routine whose total duration is at least 1 minute
- no exercise appears twice in a single routine
- an invalid duration exits non-zero with a message on stderr
- the project's own test command runs the new tests and they pass

## Out of Scope

Randomisation seeding, always ending with a stretch, config files, and every
other feature recorded in the vision. One thin vertical slice only.

## Constraints

- Build on the existing foundation: `src/warmup/`, `data/exercises.json`, and
  the pytest runner the initialization mission established. Do not replace them.
- Tests are written first and must be red on the parent commit before the code
  exists.
- Python 3, standard library only — do not add dependencies.
