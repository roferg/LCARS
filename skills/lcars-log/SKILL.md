---
name: lcars-log
description: Log bugs against an active LCARS Mission — the Mission Log. Takes free-form natural language describing one or more bugs found against a pre-merge Mission, extracts each distinct bug, fast-tracks a Mission per bug straight to the Plan stage (skipping Align, Research, and Validate), and links them all to the referenced parent Mission with the lcars:linked label. The human is expected to name the parent Mission; if none is referenced it asks which active Mission to link against first. Use when the captain runs `lcars log`, says they found a bug / bugs against a mission, or wants to file bug(s) discovered while a Mission is in flight.
---

# lcars log

`lcars log` is the **Mission Log**: the captain reports one or more bugs they
found against an *active* (pre-merge) Mission in free-form prose, and the Harness
fast-tracks a Mission for each bug — straight to the **Plan** stage — and links
them all to that parent. Bugs skip Align, Research, and Validate (vision
Example 3): the report itself is the spec and the validated direction.

You (Claude) do the natural-language half — split the report into distinct bugs
and figure out which Mission they belong to. The bundled `log.sh` does the
mechanical half (mint ids, write artifacts, open issues, link) so it stays
testable.

Run `lcars init` first if `.git/lcars/` does not exist, and there must be at
least one active parent Mission to link against.

## STEP 1 — Read the report and split it into bugs

Take the captain's free-form text. It may describe **one bug or several**. Pull
out each *distinct* defect — two unrelated symptoms in one paragraph are two
bugs, not one. For each, settle on:

- a short **title** (one line, e.g. *"XP not awarded for video completions"*)
- a one-sentence **goal** describing the fixed behaviour
- enough of the report to make the bug reproducible/understandable

Don't over-interrogate — a bug log is fast intake, not an Align grilling. If the
text is genuinely a single sentence with one bug, that's one Mission. Only ask
the captain to clarify if you truly can't tell two bugs apart.

## STEP 2 — Identify the parent Mission

The captain is expected to name the open Mission the bugs were found against —
by **mission id** (`lcars-20260530-001`), by **GitHub issue number** (`#42` or
`42`), or by title (*"the gamification mission"*). Resolve it against the active
Missions.

- If the report clearly references one, use it.
- **If none is referenced, ask first — do not guess.** Run `lcars status` (or
  let `log.sh` list them: invoking it without `--parent` prints the active
  Missions and exits) and ask the captain which one to link against. Only
  proceed once you have a parent.

You pass the parent straight through to `log.sh` via `--parent`; it does the
final resolution (and refuses a Mission that has already merged / is `done`).

## STEP 3 — Write one bug PRD per bug

For each bug, write a well-formed PRD to a temp file. It uses the **same shape
as `lcars file`** so every downstream stage treats a bug Mission identically to
a feature Mission — but `Type` is always `bug`:

```bash
prd1=$(mktemp); cat > "$prd1" <<'PRD'
# Mission: XP not awarded for video completions

**Type:** bug
**Goal:** XP is awarded when a video is marked complete, not only on quizzes.
**Acceptance Criteria:**
- Marking a video complete awards the configured XP
- Quiz completions still award XP (no regression)
**Out of Scope:**
- Changing XP amounts or the badge logic
**Constraints:**
- Reuse the existing XP service; no schema change
PRD
```

The `# Mission:` title and `**Type:** bug` lines are the source of truth —
`log.sh` reads the title and rejects anything that isn't `bug`. Write one such
temp file per bug.

## STEP 4 — Hand the PRDs + parent to the script

Pass every bug PRD with a repeated `--prd`, plus the resolved `--parent`:

```bash
bash ~/.claude/skills/lcars-log/log.sh \
  --parent lcars-20260530-001 \
  --prd "$prd1" --prd "$prd2"
```

For each bug the script mints a mission id (`lcars-YYYYMMDD-NNN`, sequenced per
day), creates `.git/lcars/missions/<id>/` with `prd.md`, `validated-plan.md`,
and `state.json` (type `bug`, stage `plan`, `parentMission` set), creates the
Mission's branch `lcars/<id>` off the current branch, opens a GitHub issue
labelled `lcars:plan,lcars:bug,lcars:linked`, and prints the summary. Show its
output to the captain verbatim:

```
2 bug missions filed and linked to #42 (Add gamification):
  lcars-20260530-002  #45  XP not awarded for video completions
  lcars-20260530-003  #46  Leaderboard flicker on first load
Run `lcars run lcars-20260530-002` (or any of the above) to begin.
```

Each bug Mission now runs in parallel with the parent and with each other, on
its own branch — `lcars run <id>` picks it up at Plan.

## What gets written, per bug

```
.git/lcars/missions/<id>/
  prd.md             ← the bug report (the GitHub issue body, too)
  validated-plan.md  ← thin synthesis so Plan is runnable (bugs skip Validate)
  state.json         ← { id, type: "bug", title, stage: "plan", created, model,
                         githubIssue, parentMission, parentIssue, branch, base }
```

Plus the branch `lcars/<id>` off the current branch (the PR base), exactly like
`lcars file`. The working tree is not switched.

## Why `validated-plan.md`?

Bugs start at **Plan**, skipping Validate — but Plan's worker reads
`validated-plan.md` (Validate's normal output). So `log.sh` writes a thin one
derived from the bug report: the report *is* the validated direction. Without
it, `lcars run <id>` would have nothing for Plan to read. This is what makes a
fast-tracked bug Mission immediately runnable.

## Notes & failure modes

- **No parent referenced** → `log.sh` (run without `--parent`) lists the active
  Missions and exits non-zero. Ask the captain which to link against, then
  re-run with `--parent`.
- **Parent already merged (`done`)** → refused. Mission Log is for bugs against
  *pre-merge* Missions; a merged Mission's bugs are new standalone Missions
  (`lcars file`).
- **`gh` missing or issue creation fails** → the bug Mission is still filed
  locally; `githubIssue` is recorded as `null` and the summary shows `(local)`.
- **Mission ID** is `lcars-<UTC date>-NNN`, sequenced per day across *all*
  Missions (feature and bug). Override the date in tests with `LCARS_DATE`.
- **Model** is read from `.git/lcars/config.json`, falling back to `LCARS_MODEL`
  then `claude-sonnet`. **`gh`/`git`** are stubbable via `LCARS_GH_BIN` /
  `LCARS_GIT_BIN`.

## Implementation

The logic lives in `log.sh` next to this file so it can be exercised directly.
Its behaviour is covered by `tests/lcars-log.test.sh` in the LCARS repo (run
with `bash tests/run.sh`). The skill source lives in `skills/lcars-log/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `log.sh`, keep those tests green.
