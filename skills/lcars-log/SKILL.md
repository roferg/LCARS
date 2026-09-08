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
labelled `lcars:plan,lcars:bug,lcars:linked`, **runs the dynamic estimator on
each child** (writing `estimate.json` — see below), and prints the summary. Show
its output to the captain verbatim:

```
2 bug missions filed and linked to #42 (Add gamification):
  lcars-20260530-002  #45  XP not awarded for video completions
  lcars-20260530-003  #46  Leaderboard flicker on first load
Run `lcars run lcars-20260530-002` (or any of the above) to begin.
```

**The issue body is a handoff document.** A logged bug is a Mission, so its issue
body is composed by the SAME composer every other filing lane uses
(`skills/lcars-run/issue-body.sh`): the `> 🐞 Logged via …` provenance lead-in,
then `prd.md`, then one invisible `<!-- lcars:handoff v1 {…} -->` envelope. This
is the only lane whose envelope ever carries a real `parentIssue`, and the only
one that emits a lead-in — both are rebuilt from `state.json` when the body is
refreshed at Verify entry, so the provenance survives a bounce-and-re-grill
instead of being replaced by the bare PRD.

Each bug Mission now runs in parallel with the parent and with each other, on
its own branch — `lcars run <id>` picks it up at Plan.

## What gets written, per bug

```
.git/lcars/missions/<id>/
  prd.md             ← the bug report (the GitHub issue body, too)
  validated-plan.md  ← thin synthesis so Plan is runnable (bugs skip Validate)
  state.json         ← { id, type: "bug", title, stage: "plan", created, model,
                         [modelOverride], githubIssue, parentMission,
                         parentIssue, branch, base }
  estimate.json      ← the dynamic estimate (best-effort — see below)
```

Plus the branch `lcars/<id>` off the current branch (the PR base), exactly like
`lcars file`. The working tree is not switched.

## The dynamic estimate (same as a Mission)

A logged bug is just a Mission whose estimate is computed from its bug PRD, so
each child gets the **same dynamic estimator** scoring a top-level Mission gets —
cost + reasoning/impl criticality + a per-stage model map. `log.sh` invokes the
**existing** estimator (`lcars-run`'s `estimate`) on each child once its `prd.md`
+ `state.json` exist, exactly the way `lcars file` does at the end of Align. It
is **strictly best-effort and never blocks the log**: if the estimator is
unavailable or produces nothing, the bug still files and every stage falls back
to its legacy model (no `estimate.json` is written) — identical to `lcars file`'s
degradation. The estimator inherits the child's engine (`workerBin`) like the
rest of the pipeline. The web Mission-Log review panel reads each filed child's
`estimate.json` to show its one cost pill + two difficulty pills + suggested
per-stage model, so CLI and viewscreen stay at parity.

`$LCARS_RUN_BIN` locates the estimator driver (default
`~/.claude/skills/lcars-run/run.sh`); tests point it at a stub.

## Steering the model per bug — `--model-override`

The captain can steer the model for a bug, reusing the **exact** lever
`lcars file` uses. Pass `--model-override "<scope>:<tier>"` **right after** the
`--prd` it applies to (it pairs positionally), with scope ∈
`{all, reasoning, implementation}` and tier ∈ `{sonnet, opus}`:

```bash
bash ~/.claude/skills/lcars-log/log.sh \
  --parent lcars-20260530-001 \
  --prd "$prd1" --model-override "all:opus" \
  --prd "$prd2"
```

A bug with no paired override gets none. A malformed value is rejected **before**
anything is filed (nothing partial). The override is persisted into the child's
`state.json.modelOverride = { scope, tier }`, which `lcars run`'s
`active_model_override` picks up natively — no resolve-logs change needed. This is
the same format the Launch panel's override sends, so the Mission-Log review panel
and Mission Start stay consistent.

## Routing pasted screenshots per bug — `--attach`

When the captain pastes screenshots into the report, each is a durable image
attachment. `--attach <path>` is **positional**, mirroring `--model-override`:

- `--attach` **before any `--prd`** → a **global** attach: copied into **every**
  bug (this is the default all-images-to-all-bugs behaviour).
- `--attach` **after a `--prd`** → a **per-bug** attach: copied into **that one**
  bug only, paired positionally with the most recent `--prd`.

Each bug's final image set is `global ∪ its-own-positional` (deduped by source
path, renumbered `attachment-01..` locally per bug). So route an image the report
ties to a specific bug as that bug's positional `--attach`, and leave an image
tied to no specific bug as a global (it reaches all bugs):

```bash
bash ~/.claude/skills/lcars-log/log.sh \
  --parent lcars-20260530-001 \
  --attach "$orphan_shot" \                 # no bug named it → all bugs get it
  --prd "$prd1" --attach "$bug1_shot" \      # only bug 1 shows this crash
  --prd "$prd2"                              # bug 2 gets just the orphan
```

With **only** global `--attach` (all before the first `--prd`), the output is
byte-identical to the pre-routing behaviour — every bug gets every image. A
missing/empty `--attach` path is rejected **before** anything is filed. In the
web flow the split worker returns per-bug `imageRefs` (1-based paste-order
indices) and the daemon computes this same union for you.

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
  `LCARS_GIT_BIN`; the **estimator driver** via `LCARS_RUN_BIN`.

## Implementation

The logic lives in `log.sh` next to this file so it can be exercised directly.
Its behaviour is covered by `tests/lcars-log.test.sh` in the LCARS repo (run
with `bash tests/run.sh`). The skill source lives in `skills/lcars-log/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `log.sh`, keep those tests green.
