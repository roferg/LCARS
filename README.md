# LCARS

Local mission control — a reusable AI harness that drives a human idea to a
merged pull request. LCARS installs as a set of Claude Code skills (`lcars
init`, `lcars file`, …) that work in **any** repo.

See [`vision.md`](vision.md) for the full design and [`CONTEXT.md`](CONTEXT.md)
for the domain glossary.

## Install

Clone this repo, then run the installer. It symlinks the skills into
`~/.claude/skills/`, so they're available globally in every repo:

```bash
git clone <this-repo> lcars
cd lcars
./install.sh
```

Requires the [Claude CLI](https://claude.com/claude-code). GitHub label setup
also needs the [`gh` CLI](https://cli.github.com), authenticated (`gh auth
login`).

## Update

Because the install uses symlinks back into your clone, updating is just:

```bash
git pull          # skills update in place — symlinks already point at them
./install.sh      # only needed to pick up newly added skills
```

## Use

Inside any repo you want to run missions in:

```bash
lcars init        # one-time per-repo setup (local config + GitHub labels)
lcars file        # file your first Mission
```

## Develop

Skill source lives in `skills/<name>/`; tests in `tests/`. See
[`CLAUDE.md`](CLAUDE.md) for the contributor contract. Run the suite with:

```bash
bash tests/run.sh
```
