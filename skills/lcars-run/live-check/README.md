# `live-check/` — the checks that actually found the bugs

Over the weekend of 26–29 Sep 2026 a buddy drove LCARS to build a real product.
**Number One filed 0 of the 31 bugs. All 31 came from the checks in this
directory**, performed by hand: running the real CLI, two actors, following one
record end to end, checking the host of every outbound call, reading the
deployed artifact instead of trusting "deploy succeeded".

The 16 bugs Number One missed were, every one, a **reach** error and never a
judgement error: there was no screen to look at, nothing was seeded so the
surface was never reached, or a stub made the seam untestable. These checklists
exist to remove the reach problem. They are not advice; they are the steps.

## Two readers, one file

| Reader | What it uses | How |
|---|---|---|
| **The buddy / autopilot** (`lcars buddy` → AUTOPILOT.md § 6) | the **prose** | a session with a shell: it runs the command, looks at the output, judges |
| **Number One** (`lcars xo`, the rebuilt verifier) | **the whole file**, as **advice the worker reads** | the checklists are catted into its prompt whole, it chooses its own steps and invents its own values. Since **S261** it has a **real shell inside a disposable detached worktree** and does the items itself; it may still DECLARE a `run`/`workflow`/`read` step for the harness to execute (S246/S247 — LCARS no longer lifts the templates itself) |

That is why every numbered item carries **both forms**, and why they must stay
in **lockstep**: the prose's `**Evidence:**` path and the template's `evidence`
key are asserted equal by `tests/live-check.test.sh`. If they drift, one of the
two readers is quietly checking something else.

**The template is an EXAMPLE, not a form anybody fills.** Until S247 LCARS lifted
each `run:` block and substituted the two or three placeholders a record can
supply — which is why *every* item needing a second actor, an owner-not-login
pair or a non-default host (`cli#4-8`, `web#4-6`) went unbuilt on **every healthy
mission**, and the captain read that refusal on every look. That mechanism is
deleted. The whole file now goes to the worker as **advice the worker reads**,
with the values deliberately left out, because the values are the reader's to
invent — which is exactly what the buddy did when it found all 31.

**The model does the looking. The script owns the setup, the evidence paths and
the record.** No checklist item is "verify that X works" — each is an action
plus the evidence to capture plus what counts as a defect.

## Running them

```bash
# setup: a DETACHED worktree of the mission branch + a THROWAWAY HOME,
# the evidence dir, and the checklist(s) to follow
autopilot.sh live-check <mission> --type cli,web,workflow

# ... do the looking, writing evidence as each item says ...

autopilot.sh live-check done <mission> --verdict pass|bugs
```

Never check from the checked-out branch: on the modelled weekend a whole round
was tested against the wrong tree because the orchestrator forgot. `live-check`
detaches a worktree and hands you a throwaway `HOME` so a config you wrote
earlier cannot make a broken product look configured.

## Evidence conventions

Everything lands under the mission's own state, which git never tracks:

```
.git/lcars/missions/<mission-id>/live-check/
  01-help.txt          NN- is the ITEM NUMBER from the checklist
  02-bad-input.txt     .txt for a transcript, .png for a screenshot
  03-desktop.png
```

- `NN-` is the item's number in its checklist, zero-padded to two digits. An
  evidence file nobody can trace back to an item is not evidence.
- **This directory is FLAT, so no filename may be claimed by two checklists.**
  A milestone with a CLI that writes a page published by a workflow runs all
  three, in one evidence dir: when `web.md` item 7 and `workflow.md` item 7 both
  wrote `07-reverify-r2.txt`, the second overwrote the first and the rule above
  was broken silently. Where an item's name would otherwise collide, the
  checklist's own name goes in it — `07-reverify-web-r2.txt`,
  `07-reverify-workflow-r2.txt`, `08-reverify-cli-r2.txt`.
  `tests/live-check.test.sh` asserts the whole set of evidence paths across the
  three files is unique, so a new item cannot reintroduce the collision.
- A transcript holds **the command, then its exact output** — the bug PRD's
  AC #1 quotes it verbatim (`skills/lcars-buddy/bug-prd.md`).
- A screenshot is **looked at**, not merely produced. "The shot was taken" is
  the `deploy succeeded` of the web checklist.
- Re-verification after a fix round writes a **new** numbered file with the
  round in its name (`08-reverify-cli-r2.txt`), never over the first pass. The
  first observation is what the fix is judged against.

## The three template kinds

| Kind | Shape | For |
|---|---|---|
| `run:` | `{"argv": [...], "cwd": ..., "env": {...}, "evidence": ..., "expect": {...}}` | execute a command and judge its output |
| `workflow:` | `{"file": ..., "expect": {...}, "evidence": ...}` | run a CI workflow's own steps locally, exactly as CI runs them (`autopilot.sh workflow-run`) |
| `read:` | `{"path": ..., "expect": {...}, "evidence": ...}` | read a produced or deployed artifact and judge its content |

`argv[0]` is always a `<placeholder>` for the product's own entrypoint: these
checklists are product-agnostic, and the caller substitutes its own names.
**So is every other `argv` entry.** No template bakes in a flag of the product
under test — a prose reader adapts `--owner x` to a positional, and a fenced
no-shell reader cannot, so the two readers would stop being equally runnable.
A placeholder may expand to one argv entry, to a flag-and-value pair, or to
nothing at all when the product takes that value from the environment. The only
literal flags you will find belong to a **third-party tool the item names
itself** (headless Chrome's `--headless`, `--screenshot=`), plus `--help`,
which is the subject of the item that runs it.
`expect` is prose for a model, not a matcher — the judgement stays with the
reader; what is mechanical is that the step ran and the evidence exists.

## The checklists

- [`cli.md`](cli.md) — a command-line surface
- [`web.md`](web.md) — a generated or deployed page
- [`workflow.md`](workflow.md) — a CI workflow

Pick every type the milestone touches; a milestone with a CLI that writes a
page read by a workflow runs all three.
