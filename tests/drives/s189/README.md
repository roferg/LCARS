# S189 tester drives — two real laptops, one real repo

Built by the Session 189 TESTER sub-agent (captain stand-in), NOT by the
implementor. These are the drives the unit suites cannot be: **real `gh`, the
real private fixture repo `roferg/lcars-mp-fixture`, and TWO REAL LOCAL CLONES
of it** — "laptop A" (files and drives the mission) and "laptop B" (a clone with
no `.git/lcars` at all, which adopts it). Real issues, real branches, real pull
requests, real assignees.

The rig is inherited from `tests/drives/s188/lib.sh`, with one difference: **`gh`
is NOT stubbed.** Both worker CLIs (`claude`, `copilot`) are still PATH shims
behind the S188 spend fuse, so **zero model tokens** are spent; every drive
prints its spawn / billable counts.

Run `setup.sh` once, then any drive:

    S189_HOME=/tmp/s189 bash tests/drives/s189/setup.sh
    S189_HOME=/tmp/s189 LCARS_SRC=/path/to/LCARS bash tests/drives/s189/ends-e2e.sh

`light-lock.sh`, `assign-traps.sh` and `refresh-board.sh` reuse the mission `ends-e2e.sh` leaves
behind (`$S189_HOME/last-issue`, `last-mid`, `last-pr`). `teardown.sh` returns the fixture
to no open issues, no open PRs, only `main`, no assignees.

| drive | what it proves |
| --- | --- |
| `setup.sh` | the `lcars:*` label set on the fixture, both clones on `main`, `whoami` answers |
| `ends-e2e.sh` | THE MAIN ROAD: laptop A files → real branch + real PR at Verify; laptop B (no `.git/lcars`) adopts from the issue alone, `lcars status` lists it, every envelope-carried field matches A, the branch arrives at the same tip, `prd.md` is a byte-exact superset of A's, and `lcars approve` reaches `gh pr merge <the real PR>` |
| `light-lock.sh` | the lock on a REAL issue really assigned to `roferg`: read verbs (status / buddy / respond list) never blocked; approve / feedback / respond answer / run drive / log each refuse with ONE plain line and leave no trace; `LCARS_OWNER_ENFORCE=0` bypasses; an unassigned mission and an unreachable forge are never locks |
| `assign-traps.sh` | THE SILENT-DROP TRAP for real — `--add-assignee octocat` on a private repo returns rc=0 and does not assign; `issue-assign` must fail, must not claim the login does not exist, and `lcars_claim_mission` must record no ownership. Plus the assign/unassign round-trip, whoami's env override / host-scoped cache / gh-absent no-hang, and the lock bypass at library level |
| `adopt-attacks.sh` | PROSE IMMUNITY (a PRD *about LCARS* carrying a decoy `lcars:handoff` envelope, a wrong branch/stage/id in its text, `## Estimate`, `---` rules and the ADR field names), a REAL DECOY PR that only mentions the issue, mid-pipeline refusal, a missing stage label, an envelope-less issue, idempotency, and whether the refreshed mission survives on the **viewscreen board** |
| `refresh-board.sh` | **FIX ROUND 2** — the refresh cure measured where it hurt: `adopt` ×3 on a real Verify mission with an ACTUAL viewscreen daemon on a free port, `GET /api/board` over HTTP after every one (round 1 could only call `LocalAdapter.board()` in-process, and said so). Valid JSON + card on the live board after each; adopt 2 and 3 byte-identical; injected local-only fields survive; `base` stays the LAST field (what keeps the five unfixed sibling helpers latent). Then a REAL `approve` with the merge FUSED OFF — four fields written through one of those unfixed siblings, and the object must still parse with `review` not last. Then cure 2 on the real surface: `prNumber` is a STRING, approve's bare-token reader sees `""`, and the `--head <branch>` fallback must resolve the REAL PR and not a real DECOY PR that merely mentions the issue. Kills only the PID it started, and asserts the port is free afterwards |
| `board-probe.py` | read-only helper: is a mission on the board? `lcars status` reads state.json with `sed` and never notices malformed JSON; the board parses it with `json.load` and silently drops what it cannot read |
| `fuse-check.sh` | proves the zero-spend fuse is ARMED: both `claude` and `copilot` resolve to the shim, and one deliberate `--model` call moves the counters |
| `teardown.sh` | closes every issue/PR the drives opened, deletes their branches, unassigns, resets both clones |

## The traps this rig already fell into — do not re-pay for them

* **`git clone -b main`, never `git init --bare`.** A bare repo left on an
  unborn `master` checks out nothing, and a branch cut there is an ORPHAN — which
  makes every "is the base ahead?" check answer YES and silently diverts
  `approve` into reconcile instead of merging.
* **The host adapter must be run FROM INSIDE the clone** (`hostin` in `lib.sh`).
  `gh issue view` resolves the repo from the CWD's remote, so an adapter call
  made from the LCARS checkout quietly answers about a *different* repository —
  it reported an unassigned issue that GitHub had assigned correctly.
* **`lcars file` already cuts the mission branch.** A drive that does
  `git checkout -b <branch>` after filing fails, silently skips its commit, and
  the PR open dies with "no commits ahead of base".
* **Delete the remote mission branch before a re-run** (`fixture_drop_branch`),
  or `open_pr`'s push is a non-fast-forward and the drive dies with a misleading
  "could not push".
* **`lcars feedback` CLOSES the real PR when it bounces a mission.** Do not use
  it as a throwaway probe on a fixture you want to keep.
* **A backgrounded `( cd … && bash viewscreen.sh ) &` leaks the daemon.** bash
  forks python as a CHILD, so `kill $!` reaps the wrapper and the board keeps
  holding the port. Use `( cd … && exec env … bash … ) &` so the subshell
  *becomes* the daemon and `$!` is its real pid — and assert the port is free
  after the kill. Never kill boards by name or pattern; other sessions' daemons
  are running on this machine.
* **Cure 2 changed the merge SELECTOR.** `adopt` writes `prNumber` as a JSON
  string, so `approve`'s bare-token reader returns `""` and it merges by
  `--head <branch>`, not `--number <n>`. A drive that asserts on the PR number
  is asserting on the old behaviour: assert the selector RESOLVES the real PR.
* Argv: `approve.sh --mission <id>`, `respond.sh answer --mission <id> --answer …`
  (a SUBCOMMAND first), `feedback.sh --mission <id> --feedback …`. None takes a
  bare positional mission id.
