---
name: lcars-file
description: File a new LCARS Mission. Captures a free-form idea from the captain, runs an Align session to produce a PRD, then persists the mission under .git/lcars/missions/ and opens a labelled GitHub issue at the align stage. Use when the user runs `lcars file`, asks to start / file / open a new LCARS mission, feature, or bug.
---

# lcars file

`lcars file` is the **Entry Skill**: it turns a free-form human idea into a
filed Mission sitting at the **Align** stage, ready for `lcars run` to pick up.
You (Claude) run the conversation; the bundled `file.sh` does the mechanical
persistence so it stays testable.

Run `lcars init` first if `.git/lcars/` does not exist — `file.sh` will create
the `missions/` dir if needed, but a repo without the LCARS labels can't be
issue-labelled properly.

## STEP 1 — Capture

Ask the captain for a free-form description of the idea. One open prompt:

> What do you want to build or fix?

If it isn't obvious from their answer whether this is a **feature** or a
**bug**, ask. Don't over-interrogate here — capture is just intake; the real
sharpening happens in Align.

## STEP 2 — Align

**First, resolve the repo context source — once.** Before grilling, run the
shared resolver so Align reads the same durable repo facts every later Stage
will (architecture, conventions, how tests run, key interfaces / domain terms),
instead of re-deriving them from the tree each session:

```bash
ctx=$(bash ~/.claude/skills/lcars-run/run.sh context-source)
```

It prints ONE path and you read it:

- If a `CONTEXT.md` exists at the repo root, that is the source (no pack is
  generated).
- Otherwise it returns `.git/lcars/context-pack.md`, generating it lazily on
  first use via a single cold worker (and reusing it thereafter). The pack lives
  inside `.git/` — it never touches the working tree and is never committed.

Read `$ctx` and treat it as the ground truth for repo facts during Align. Where
this guide below says "the codebase or `CONTEXT.md`", it means `$ctx`.

Align is a **relentless, one-question-at-a-time interview** in the style of the
`grill-me` / `grill-with-docs` skills — not a fixed questionnaire, and **never a
batch of questions fired off at once**. Run it like this:

- **One question at a time.** Ask, then *wait* for the captain's answer before
  asking the next. Do **not** present a multi-question form or pick-list to be
  answered in one go — that short-circuits the whole point, which is to let each
  answer steer the next question.
- **Walk the decision tree.** Every answer opens new branches and creates
  dependencies between decisions; resolve them one by one. *How sleep gets
  captured* changes *what the summary can show* — follow that thread rather than
  pre-scripting a list.
- **Always lead with your recommended answer.** Don't just interrogate —
  propose the answer you'd pick and why, so the captain can confirm or push
  back. This is what keeps a simple idea moving fast instead of stalling.
- **Explore instead of asking when you can.** If a question is answerable from
  the codebase or `CONTEXT.md`, go look — don't make the captain tell you.
- **Sharpen fuzzy language.** When the captain uses a vague or overloaded term,
  propose a precise one. If `CONTEXT.md` defines it differently, surface the
  conflict immediately.

There is **no fixed number of questions** — let complexity set the depth. A
one-line bug ("the /about link 404s") may converge after a single exchange; a
broad feature may take many turns. Keep grilling until you and the captain share
a clear picture of what's being built *and what isn't*, then stop. Don't
manufacture ambiguity to pad the session, and don't cut it short while real
branches are still unresolved.

When alignment is reached, write the PRD. It **must** contain all of these
sections, in this exact shape — `file.sh` rejects a PRD that is missing any of
them:

```markdown
# Mission: <title>

**Type:** feature | bug
**Goal:** <one sentence>
**Acceptance Criteria:**
- <bullet>
- <bullet>
**Out of Scope:**
- <anything explicitly excluded>
**Constraints:**
- <tech stack, perf requirements, etc.>
```

The `# Mission:` title and `**Type:**` value are the source of truth — the
script reads the mission title and type straight from the PRD, so get them
right. Use `lcars:feature` / `lcars:bug` vocabulary consistently.

When the captain is happy with the PRD, write it to a temp file, e.g.:

```bash
prd=$(mktemp); cat > "$prd" <<'PRD'
# Mission: ...
...
PRD
```

## STEP 3–5 — Persist, open the issue, confirm

Hand the PRD to the bundled script. It mints the mission ID
(`lcars-YYYYMMDD-NNN`, sequenced per day), creates
`.git/lcars/missions/<id>/{prd.md,state.json}`, **creates the Mission's own
branch `lcars/<id>` off the current branch** (recording the branch and its base
in `state.json`), opens the GitHub issue with the `lcars:align,lcars:<type>`
labels, records the issue number, and prints the summary:

```bash
bash ~/.claude/skills/lcars-file/file.sh --prd "$prd"
```

Show the captain its output verbatim:

```
  Mission filed: lcars-20260530-001
  GitHub issue:  #42
  Branch:        lcars/lcars-20260530-001 (off main)
  Stage:         align
  Next:          run `lcars run lcars-20260530-001` to continue
```

## What gets written

```
.git/lcars/missions/<id>/
  prd.md        ← the PRD from Align (the GitHub issue body, too)
  state.json    ← { id, type, title, stage: "align", created, model, githubIssue, branch, base }
```

Plus, in git itself: the branch `lcars/<id>` is created off the current branch
(the `base` the PR will later target). The working tree is **not** switched to
it — `lcars file` leaves the captain's checkout exactly as it was. Implement
checks the branch out when it commits the first green ticket; `lcars approve`
pushes it and opens the PR with `--head lcars/<id> --base <base>`.

## Notes & failure modes

- **PRD missing a required section** → the script exits non-zero and writes
  nothing. Finish Align — produce the missing section — and re-run.
- **`gh` missing or issue creation fails** → the mission is still filed
  locally; `githubIssue` is recorded as `null` and the summary says so. Re-run
  after fixing `gh`, or open the issue by hand and record the number.
- **Mission ID** is `lcars-<UTC date>-NNN`; `NNN` increments per day from the
  existing missions in `.git/lcars/missions/`. Override the date in tests with
  `LCARS_DATE=YYYYMMDD`.
- **Model** is read from `.git/lcars/config.json` (written by `lcars init`),
  falling back to `LCARS_MODEL` then `claude-sonnet`.
- **Branch creation is best-effort.** In a repo with no commits there is nothing
  to branch from, so `lcars file` records the intended branch name but warns and
  leaves creation to Implement's first commit. An already-existing `lcars/<id>`
  branch is reused. Stub the git binary in tests with `LCARS_GIT_BIN`.

## Implementation

The logic lives in `file.sh` next to this file so it can be exercised directly.
Its behaviour is covered by `tests/lcars-file.test.sh` in the LCARS repo (run
with `bash tests/run.sh`). The skill source lives in `skills/lcars-file/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `file.sh`, keep those tests green.
