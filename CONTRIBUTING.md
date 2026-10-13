# Contributing to LCARS

Issues and pull requests are welcome. This is the short version; it will grow.

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

1. **Author it in this repo**, under `skills/<name>/` — never by hand inside an
   AI CLI's own skills directory. `./install.sh` symlinks them, which is what
   makes `git pull` deliver updates with no re-install.
2. **Write the failing test first**, in `tests/<name>.test.sh`. Keep the logic
   in a shell script rather than in prose so a test can reach it, and take
   external dependencies through environment variables (`LCARS_GH_BIN`,
   `LCARS_WORKER_BIN`, …) so tests can stub them.
3. **Run `./install.sh`**, then the scoped suite for what you touched:
   `bash tests/<name>.test.sh`. The full `bash tests/run.sh` is slow; it is the
   gate before a merge, not an inner loop.
4. **Commit the source, the test and any doc change together.** Work on a
   branch; `main` takes pull requests only.

## Pull requests

Say what changed and why, and name the suites you ran. If you changed anything a
reader sees — `README.md`, `vision.md` or a page under `docs/` — run
`bash tests/docs-links.test.sh` and `bash tests/docs-sync.test.sh` too.
