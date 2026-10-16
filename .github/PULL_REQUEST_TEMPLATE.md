## Change and reason

What changes for a user, and why? Link the relevant issue and explain scope.
Humans follow [CONTRIBUTING.md](../CONTRIBUTING.md); AI agents follow
[CLAUDE.md](../CLAUDE.md). Both use the same build contract.

## Skill and test

- Affected skill source: `skills/<name>/` (or explain a non-skill change).
- Skill test: `tests/<name>.test.sh` (or name the relevant scoped guard).
- Failing-before/passing-after evidence and any changed test assertions:
- Related documentation updated:

## Scoped verification

Exact scoped command, passed/failed counts, and result:

```text
python3 tests/lib/cage.py <seconds> bash tests/<name>.test.sh
Result: <passed> passed, <failed> failed
```

- [ ] Wrote a failing test first and kept source/tests in tracked repo paths.
- [ ] Worked on a branch, never directly on `main`.
- [ ] Installed changed skills with `./install.sh` (or not applicable).
- [ ] Ran the fast scoped suite; did not substitute a full run for the inner loop.

The full `bash tests/run.sh` is `ship-it`'s merge gate, not a mid-session task.
Do not claim it passed unless it actually ran at that gate.

## Release contract (every PR into main)

- [ ] Bumped root `VERSION` using `YYYY.M.N` (month without a leading zero).
- [ ] Added a matching newest-first `CHANGELOG.md` entry summarised from this PR.

Version and changelog heading:

<!-- Do not include secrets or private vulnerability details; see SECURITY.md. -->
