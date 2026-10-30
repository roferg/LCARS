# Contributing to LCARS

Issues and pull requests are welcome. **CONTRIBUTING.md is the contract for humans;
[CLAUDE.md](CLAUDE.md) is the contract for AI agents building this project.**
They describe the same build workflow for different audiences. Start here if
you are a person; read the agent contract before using an agent to contribute.
Read [vision.md](vision.md) for why LCARS is the way it is, and [CONTEXT.md](CONTEXT.md)
for the domain language before substantial work.

Participation follows our [Code of Conduct](CODE_OF_CONDUCT.md). Use the bug or
feature issue templates for public discussion; report vulnerabilities privately
as described in [SECURITY.md](SECURITY.md), never in a public issue.

## The shape of the repo

```text
skills/<name>/SKILL.md     one directory per `lcars` command: what it does
skills/<name>/<name>.sh    its logic, kept in a script so it can be tested
tests/<name>.test.sh       one suite per command
tests/run.sh               runs every suite (slow — it is the merge gate)
install.sh                 links the commands into the AI CLIs you have
web/                       the viewscreen: server, board, and its Python tests
docs/                      this project's pages, hand-written, no build step
```

## Making a change

Start on a branch cut from `main`: `feat/<round>` for a round or session, or
`fix/<slug>` for a fix. Work **never on `main` itself**; changes land through PRs.

1. **Author it in this repo**, under `skills/<name>/` — never by hand inside an
   AI CLI's own skills directory. `./install.sh` symlinks them, which is what
   makes `git pull` deliver updates with no re-install.
2. **Write the failing test first**, in `tests/<name>.test.sh`. Keep the logic
   in a shell script rather than in prose so a test can reach it, and take
   external dependencies through environment variables (`LCARS_GH_BIN`,
   `LCARS_WORKER_BIN`, …) so tests can stub them.
3. **Install changed skills with `./install.sh`**, which (re)links the repo
   source into the AI CLIs you have. A docs-only change needs no installation.
4. **Verify with the fast scoped suite** for what you touched:
   `bash tests/<name>.test.sh`. For unattended runs use
   `python3 tests/lib/cage.py <seconds> bash tests/<name>.test.sh` to bound the
   whole process group. The full `bash tests/run.sh` is `ship-it`'s **merge gate**,
   not an inner loop; do not run it or the heavy `tests/lcars-run.test.sh` to
   completion mid-session. A scoped pass is not evidence that all suites pass.
5. **Commit the source, the test and any doc change together.** Keep everything
   needed to clone and use the change in tracked paths, not author-local scratch
   or an AI CLI's own skill directory.

## Pull requests

Say what changed and why, and name the suites you ran. If you changed anything a
reader sees — `README.md`, `vision.md` or a page under `docs/` — run
`bash tests/docs-links.test.sh` and `bash tests/docs-sync.test.sh` too.

Use the [pull-request template](.github/PULL_REQUEST_TEMPLATE.md): identify the
skill (or explain why this is not a skill change), its test, and the exact scoped
command and passed/failed counts. Include failing-before/passing-after evidence
for a regression guard, and explain any existing test assertions you changed.

**Every PR into `main` must bump [VERSION](VERSION)** using `YYYY.M.N` (year,
month without a leading zero, per-month counter) and add a matching newest-first
[CHANGELOG.md](CHANGELOG.md) entry summarised from the PR body. Keep scope small
and include relevant documentation; do not claim an unrun merge gate is green.
