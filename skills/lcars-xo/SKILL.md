---
name: lcars-xo
description: Engage, stand down, and inspect Number One — the AI first officer that holds a Mission on the captain's behalf. `lcars xo on [--engine copilot|claude] [--model M]` turns Number One ON for this repo, recording the choice in `.git/lcars/config.json` as a one-line `numberOne` block; with no `--engine` and a terminal it opens a picker naming the engines installed on this machine, and with no terminal it refuses loudly rather than choosing in silence. `lcars xo off` stands the repo down and hands the conn back on every engaged Mission; `lcars xo off <mission>` opts one Mission out and stands just that one down (signalling its recorded worker pid, recording `stood-down` and a note); `lcars xo on <mission>` puts that Mission back in scope — it clears the per-mission opt-out AND the `stood-down` status, so the next drive can engage it again. `lcars xo answer --mission <id>` is the driver's call at a park: Number One reads the Mission's record in a read-only copy, then either ANSWERS the gate through `lcars respond` (attributed `answeredBy: number-one`, exit 0) or ESCALATES with a note and a recommendation and leaves the gate up (exit 1) — always escalating a `scope` gate, an uncited answer, and anything malformed. Bare `lcars xo` prints the status table — every Mission with its stage, Number One's RECORDED status (engaged / finished / escalated / answered / stood-down / opted-out) and its note. While a Mission is engaged the write verbs (approve, feedback, respond, log, pause, resume, resolve-logs) and the viewscreen's matching endpoints refuse with ONE sentence, because Number One is already acting through them on the captain's behalf. Use when the captain runs `lcars xo`, says "engage Number One", "turn the first officer on/off", "stand Number One down", "who has the conn", or asks what Number One is doing.
---

# lcars xo — Number One

**Number One is the AI first officer.** With it engaged, LCARS does not just stop
at a gate and wait: it takes the conn on the captain's behalf, works the gate
through the ordinary verbs, and hands the conn back with a report.

`xo.sh` does all of the mechanical work. It asks no model anything — **the
worker reasons, the skill executes** (captain ruling, 2026-09-11). You (Claude)
run it and read out what it printed.

## The verbs

```bash
bash skills/lcars-xo/xo.sh                          # the status table
bash skills/lcars-xo/xo.sh on --engine copilot      # engage for this repo
bash skills/lcars-xo/xo.sh on                       # …with the picker
bash skills/lcars-xo/xo.sh off                      # stand the repo down
bash skills/lcars-xo/xo.sh off <mission>            # opt ONE mission out
bash skills/lcars-xo/xo.sh on  <mission>            # clear that opt-out
bash skills/lcars-xo/xo.sh answer --mission <id>    # take the park (S202)
bash skills/lcars-xo/xo.sh evaluate --mission <id>  # the Verify look (S203)
bash skills/lcars-xo/xo.sh file-logs --mission <id> # file the gaps as logs (S204)
bash skills/lcars-xo/xo.sh recheck --mission <id>   # re-look after the fixes (S204)
bash skills/lcars-xo/xo.sh report [<mission>] [--all] [--seen]
                                                     # the First Officer's report (S205):
                                                     # since you last looked, then history,
                                                     # folded per mission. Scope to one
                                                     # mission's own journal by naming it;
                                                     # --all shows every entry; --seen marks
                                                     # it read (.git/lcars/xo-seen.json).
                                                     # The board's own GET /api/xo/report and
                                                     # POST /api/xo/seen read and write the
                                                     # SAME record through the SAME builder
                                                     # (skills/lcars-xo/xo-report.py).
```

The front door routes `lcars xo …` here through an explicit delegator in
`skills/lcars/lcars.sh` — **not** through smart-default routing, because a bare
`lcars xo` is a READ and the router would otherwise take `xo` for a Mission
selector and try to drive something.

## `answer` — taking a park (S202)

When a Mission stops **awaiting-human** and Number One is engaged there, the run
driver calls `xo.sh answer --mission <id>`. It:

1. copies the Mission's record into a temp **input** dir, **read-only** — the
   PRD, the ADRs, the validated plan, `plan.json`, `pending.json`,
   `answers.json`, the research findings, the last 200 events, the attachments
   (the holodeck drawing and its concept), and `claim-check.txt` /
   `reconcile-design-question.txt` when they are there;
2. hires **one cold worker** through `run.sh spawn-number-one`, so the first
   officer reaches the same chokepoint every Stage uses — role → stage key
   (`numberOne`) → the pinned model → the fenced argv → the S168 fence snapshot
   → usage capture. The role is READ + author-one-file, **no shell, no
   network**, on both engines (`worker-adapter.sh`);
3. reads back the worker's one file, `xo-answer.json`, and **checks it**;
4. **ANSWER** → `respond.sh answer`, the ordinary verb, with
   `LCARS_ANSWERED_BY=number-one` (the ledger says who) and
   `LCARS_RESPOND_RESUME=0` (the driver is already running; a re-exec would put
   two drivers on one Mission). Exit **0** — the driver continues;
   **ESCALATE** → the gate is left exactly as the stage raised it,
   `numberOne.status` becomes `escalated` with a note carrying the summary and
   the recommendation. Exit **1** — the driver halts, as today.

`xo.pid` holds this script's pid for the length of the spin, and a SIGTERM (what
`lcars xo off <id>` sends) walks the whole process tree down so the worker dies
with it. Every action is appended to `<mission>/number-one.jsonl`.

### What is checked, and why

- **An ANSWER must cite a line that is really there.** At least one citation
  quote must occur, verbatim (whitespace-normalised), in the file it names. The
  prior-art on LLM judges says the failure to expect is not over-refusal but a
  judge that **reasons its way past the record** — a chain of sensible
  inferences landing somewhere the Mission never said. A verdict that cannot
  show its line is not a verdict.
- **Scope and spend are the captain's, always.** A gate whose
  `escalationType` is `scope` escalates no matter what the worker decided
  (ruling 2026-09-11). The worker still runs, so the captain gets a
  recommendation with the escalation.
- **The unsure exit is honoured.** `decision: answer` with `confidence: low` is
  taken as the escalation the prompt asked for.
- **Anything malformed escalates** with the note
  `Number One could not decide — malformed verdict` — no file, not JSON, no
  decision, an answer with no citations. Never a crash, never a silent answer.

The model is the captain's Opus pin: the S194 write floor
(`write_capable_alias` → `modelAliases.copilot.opus`, default
`claude-opus-4.8`), overridable by config `numberOne.model`, outranked by
`LCARS_WORKER_MODEL`. The prompt is `skills/lcars-xo/prompts/answer.md`.

## `evaluate` — the Verify look (S203)

The Mission has a PR open and is parked at Verify. `evaluate` launches the
build, walks it in a **headless** browser, compares it against a contract
written before it looked, and scores the intent match.

The order is the contract:

1. **`xo/criteria.json` FIRST, before any browser.** The PRD's acceptance
   criteria (marked `primary`), the plan's per-ticket criteria with their
   `drawnAt` / `notDrawn` / `notVisual`, and the drawing's place names. A judge
   that writes its checklist after looking writes a checklist of what it
   happened to notice.
2. **`launch.sh <id>`.** If the build does not come up, the score is **LOW**
   quoting the launch message — and **no browser is started at all**.
3. **Round 0** — `xo-drive.js` takes the whole page plus one clipped shot per
   place the drawing names. Every PNG gets a paired `.json` readout and a
   one-line `.txt` caption.

   **ONE LOOK, ONE DIRECTORY.** Each look writes into its own
   `xo/shots/<look>/` — `look-1`, then `recheck-1`, `recheck-2` — and the worker
   is handed THAT directory and no other. Nothing is ever deleted (the
   walkthrough is built from these pictures); which directory a look reasoned
   from is in its journal line, and `xo/look.txt` points `file-logs` at the one
   the verdict came from. Before this, a second look that took fewer shots than
   the first inherited the first's leftovers and reasoned about them as current.
4. **Up to three worker rounds.** Each round Number One writes EITHER
   `xo-actions.json` (it wants to look further — at most 12 actions, every
   screenshot named) OR `xo-verdict.json`. No verdict by the end of round three
   is a **LOW** that lists what it saw.
5. **The score is RECOMPUTED from the ledger** (`xo-score.py`). The model
   reasons; the skill decides:

   | the ledger | the score | |
   |---|---|---|
   | a contradicted PRIMARY (PRD) criterion | **LOW** | the stated goal is not met |
   | any other contradiction | **MEDIUM** | the flow works; read the gaps |
   | any UNTESTED, everything else met | **MEDIUM** | *not* HIGH — "could not see it" is not "it is fine" |
   | every criterion met | **HIGH** | ship as is |

   **A worker score that disagrees with its own ledger is overwritten, and the
   disagreement is journaled** (`score-overruled`). Both scores stay in
   `xo/verdict.json`.
6. **`launch.sh <id> --stop`** — on every path out.
7. **The record:** `xo/verdict.json`, `xo/report.md` (what the living comment
   includes), journal lines, `numberOne.score`, status `finished` (a HIGH) or
   `engaged` (gaps → S204), and the score **LABEL** `lcars:xo:<score>` with the
   other two removed. One source per fact: the label is the score, the comment
   is the report.

   The four `lcars:xo:*` labels are part of `lcars init`'s canonical set, and
   the swap **ensures its own family first** (host adapter `label-ensure`) so a
   repo initialized before this round does not silently lose the verdict to a
   label the forge has never heard of. `lcars update` fills them in too.

`evaluate` is idempotent on `numberOne.evaluatedAt`, and a logged bug child
(`parentMission`) is never evaluated — its parent carries the build.

**The driver starts the look, detached.** `drive_verify` hands the build to
`xo.sh evaluate` at both Verify halts — the pass that opens the PR and the pass
that finds one already open — as a `setsid`/`nohup` child with its pid in
`xo.pid`, so the halt returns the captain's terminal immediately. Same two
guards on the driver's side (`evaluatedAt`, `parentMission`), because a spawn
that only refuses *inside* the verb has already paid for a launch and a browser.
`LCARS_XO_DRIVE=0` turns the hook off.

**The score travels.** Because it is a LABEL, a board on another laptop reads it
off the one listing the remote poll already fetched (S191) and draws an
`INTENT MATCH · HIGH|MEDIUM|LOW` pill — teal / amber / red, and labelled in full
so it never reads as one of the card's two DIFFICULTY pills, whose HIGH means
the opposite kind of news. `lcars:xo:engaged` carries the badge the same way.

**It files nothing.** S203 finds and scores; S204 is the round that acts.

### The captain's focus is never taken

Captain's ruling, 2026-09-13. `xo-drive.js` launches Chrome **headless, always,
with no flag and no environment variable that can raise a window** — not even
`LCARS_BROWSER_HEADED`, which is a test affordance for the board's eyeball legs
and must never become a product path. Nothing here opens a tab, an app window or
a file for the captain: `launch.sh` starts the app on a port and returns a url,
and the only thing that ever visits that url is Number One's own headless
Chrome, in a throwaway profile, TERMed by its own pid on the way out.
`tests/drives/s203/drive-rig.sh` asserts it by reading the frontmost application
before and after a whole real drive.

## The engine picker

It **names engines and nothing else**: `copilot` and `claude`, each *installed*
or *not installed*, detected through the one shared probe
(`lcars_engine_available`, `skills/lcars-init/lcars-common.sh`).

**There are no pricing words in this product — not "free", not "billed", not
"costs"** (captain ruling, 2026-09-11). Not everyone's situation is the
captain's, and a product that prices a choice for you is making the choice for
you. Do not add them to any surface, ever.

**No terminal and no `--engine` is a loud refusal**, the `lcars adopt`
precedent. Choosing an engine in silence *is* the defect; failing loudly is the
cure.

## The two records

Everything downstream reads these, and nothing infers them from prose — the
producer records, the surface displays.

**`.git/lcars/config.json` — the repo switch, ON ONE LINE:**

```json
  "numberOne": {"enabled": true, "engine": "copilot"}
```

**The engine is a real pin, not a label.** `numberOne.engine` is what Number
One's worker actually runs on: `xo.sh` exports it as `$LCARS_WORKER_BIN` with
`$LCARS_WORKER_BIN_INTERNAL=1` when it spawns the spin, and `run.sh`'s
`spawn-number-one` entry honours it ABOVE the Mission's own `workerBin`. The
Mission's `engineSource` / `engineResolved` / `workerBin` are left untouched —
those answer "why does this MISSION run on this engine", and Number One's engine
is Number One's. The captain's own `$LCARS_WORKER_BIN` still outranks the pin,
because it is per-invocation and unmistakably deliberate. (Fix round 1: the
engine was recorded and displayed and consulted by nothing, so a repo pinned to
claude spawned copilot while every surface said claude.)

One line is load-bearing twice over. `lcars_config_merge` preserves an existing
raw value only when it sits on a single line, and it **deletes** any top-level
key missing from `DESIRED_CONFIG` — so `numberOne` is listed in both
`lcars-update/update.sh` and `lcars-init/init.sh`. That second rule is the exact
failure S196 paid for with `cloneId`.

**`state.json` — the per-mission record, AT THE TOP OF THE FILE:**

```json
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "…", "note": "…"}
```

`status` is one of `engaged`, `finished`, `escalated`, `answered`,
`stood-down`. `optOut: true` means "never engage here". The key goes at the top
because a last-key corruption bug is latent in the state writers (the S189
rule) — keeping new keys off the end keeps it latent.

## When the driver calls it (S202)

`lcars run` engages Number One **once, at the top of a drive**, when the repo
switch is on and the Mission is not opted out (and never re-engages one the
captain stood down, nor overwrites one that is `escalated` while the gate it
handed back — the one whose cksum is in `lastPending` — is still up; once the
captain has answered that gate, the next drive re-engages and drops the stale
note). Engaging is the driver's act and only the driver's:
`lcars xo on` is a repo switch, and `lcars xo on <mission>` only returns a
Mission to scope — it clears the opt-out AND the `stood-down` status the
matching `off` wrote, leaving the Mission looking exactly like one that was
never stood down, so the NEXT drive is what engages it. It does not touch
`escalated`: that gate is still the captain's.

Every park in the pipeline lands on ONE line of `cmd_drive` — the awaiting halt
at the top of the loop — so the hook is there, not at the two dozen raisers:

* `numberOne.status == engaged` → `bash xo.sh answer --mission <id>`
* exit **0** → the gate is cleared; the loop goes round and the drive carries
  on. There is **no second driver**: `xo.sh` pins `LCARS_RESPOND_RESUME=0`, so
  `respond.sh` records the answer and returns instead of re-entering the driver.
* exit **1** → the driver halts at the gate exactly as it did before S202.

`--step` has its **own** arm. A Stage that finishes by asking has finished, so
the first officer answers there and the step **ends, cleared** — rather than the
gate falling through to the top of the loop, where auto mode would clear it and
then run a second Stage the captain never asked for.

**The same question is never asked twice.** An escalated gate is still a gate,
and the next pass would otherwise hire a worker to be told the same thing. The
driver **records** the `cksum` of the `pending.json` it acted on as
`numberOne.lastPending` — written BEFORE the spawn, so a crash mid-spin does not
buy a second one — and skips a gate whose pending matches. It is recorded, never
worked out afterwards from a journal or a comment.

`LCARS_XO_DRIVE=0` takes the hook out of the loop entirely.

## Number One's report — the living comment

`comment-mirror.sh` renders `<mission>/number-one.jsonl` into **one** issue
comment keyed `number-one`: status, engine, the last answer with the line that
grounded it, the escalation note, and the whole journal folded into a
`<details>`. It is CREATED once and **EDITED** thereafter — the S65 model,
unchanged; two answers are two lines in one comment, never two comments.

The one exception is an **escalation**, and it is S65's own exception: an edit
does not notify on GitHub, so a gate that has just become the captain's also
goes out through `cm_ping_gate` as a fresh comment (idempotent by its recorded
gate key, so a re-render never pings twice). That ping **replaces** the generic
"Awaiting your answer" one rather than joining it — one gate, one notification —
and with Number One off, or engaged but not escalated, the pre-existing ping
fires exactly as it always has. `lcars answer` prints the same note on the card,
read off `state.numberOne` — the inbox infers nothing.

## The engaged lock

While `status` is `engaged`, these refuse with **one sentence**:

```
Number One is engaged on this mission on your behalf — stand it down (lcars xo off <id>) to act yourself
```

`lcars approve`, `lcars feedback`, `lcars respond answer`, `lcars log`,
`lcars pause`, `lcars resume`, `lcars resolve-logs` — and the viewscreen's
matching endpoints, with a 403 carrying the same bytes.

`lcars run` and `lcars xo` are **exempt**: Number One's own actions go through
them, so locking them would lock Number One out of itself. `start` is likewise
absent from the daemon's set — an engaged mission is already being driven.

It is a **second reason on the existing owner-lock seam**
(`skills/lcars-run/ownership.sh`), not a new mechanism, and it keeps that seam's
posture exactly: every uncertain case proceeds (no state file, no key, an
unreadable value), one sentence pinned byte-identical everywhere, and
`LCARS_XO_ENFORCE=0` bypasses it for harness debugging.

**Number One's own hand is not a second hand** (S204 fix round 1, D1). Number
One acts THROUGH these very verbs, so without an exemption the lock refuses the
first officer's own `log.sh`, `resolve-logs.sh` and `respond.sh answer` calls —
and nothing it decides can ever be filed. `xo.sh` sets
**`$LCARS_XO_INTERNAL=<mission-id>`** on exactly those child calls, and
`lcars_xo_lock_reason` exempts a call only when the marker names the SAME
mission it is being asked to lock. It is the S207 `$LCARS_WORKER_BIN_INTERNAL`
shape (the producer states who set it), narrowed: Number One holding mission A
buys no free pass on mission B, and the captain's own `lcars log` on A is
refused with the same sentence as before. It is never set process-wide and never
exported to a worker. `LCARS_XO_ENFORCE=0` is NOT the cure — it switches the
lock off wholesale for everything the call spawns.

## The fix round (S204) — `file-logs` and `recheck`

A look that scores MEDIUM or LOW has found gaps. Number One does with them what
the captain would: it files an ordinary **mission log** for each one and lets
LCARS drive it.

**`file-logs`** reads `xo/verdict.json` and takes the gaps of kind
`contradiction` — the build disagreeing with something written down, with a
picture of it. An **interpretation** (a call the build made where the record is
silent) is never filed; it is on the report, as the captain's own call. The cap
is **ten**; an eleventh gap is journalled (`N more gaps not filed — cap 10`),
never dropped in silence. For each gap it writes a bug PRD under `xo/logs/`,
then makes **one** `lcars log` call in the shape `run.sh` already uses —
`--parent <id> --prd 1.md --attach shot-a.png --prd 2.md --attach shot-b.png` —
so each shot binds to its OWN bug by argument order. The parent's drawing is
**not** attached by hand: `log.sh` inherits a holodeck parent's mockup itself.
The child ids come back off the verb's own summary and land in
**`xo/logs.json`**, which is the only thing `recheck` reads to know what it
filed. Then `resolve-logs` is started detached, its pid in **`xo-resolve.pid`**.

**ONE ROUND ONLY** (captain's ruling). `numberOne.round` is set to `1` and never
incremented. A fix that does not hold goes to the captain, not to round two.

**`recheck`** runs when the consolidated re-verify gate comes up. It relaunches
the build from the parent branch (the children's fixes are on it), drives it,
and asks ONE worker the narrow question: **for each gap you filed, did its fix
hold?** Every fix holding is accepted through `respond.sh answer`, attributed to
`number-one` — which is what triggers `resolve-logs complete`'s fold of each
child to Done and the push of the parent branch. Anything that does not hold
leaves the gate exactly where it was, with the list beside it. The second score
is recomputed from the ledger by the same `xo-score.py` that scored the first
look, and `xo/report.md` becomes *after the fixes* with the first look folded
underneath it.

A child that **parked** blocks all of it — `resolve-logs complete`'s
completeness guard would refuse the whole batch — so `recheck` escalates
"log #n needs you" **before** spending a launch, a browser or a worker.

**AN ACCEPT IS FINAL (captain's ruling, S205, 2026-09-14).** Once
`numberOne.status` is recorded `finished` — the terminal state BOTH a clean
first look and a successful `recheck` leave behind — a further `recheck` is
**refused, verbatim, before a look name is even minted**: *"I've already
handed this one back — the PR is yours."* Wanting a fresh opinion after
changing the branch is a deliberate restart (stand it down, re-engage), never
a second call to `recheck` on a mission it already closed out.

**`recheck` FETCHES — it never trusts the local branch alone (captain's
ruling, S205, 2026-09-14).** Before relaunching, it fetches the mission's
branch from `origin` (best-effort — no remote, no network, or no recorded
branch never blocks the look) and fast-forwards the LOCAL branch ref when that
is safe (origin moved past local, no local-only work). When it cannot — the
histories have diverged, or origin is unreachable — it never force-resets (the
same data-loss `reconcile_sync_local_branch` in `run.sh` was written to stop);
it says, plainly, which commit it is about to look at instead. Either way the
captain never gets a confident "every fix held" against a branch this process
never actually looked at. See `xo_recheck_branch_report` in `xo.sh`.

### Which gate is this? The record says, not the prose

`resolve-logs.sh` writes `"kind": "reverify"` into the parent's `pending.json`
when it raises the consolidated gate, and `"kind": "reverify-blocked"` when it
re-raises it because the fold could not happen. **`xo.sh answer` routes on that
recorded field and on nothing else.** Matching the question's wording would be
the same defect this project has already paid for three times (S147, S156,
S188), and it is cured the same way every time: the producer records the fact,
the consumer reads it. The captain rewords gate prose freely; a matcher over it
eventually meets a question that contains its vocabulary.

## Standing down

`lcars xo off <mission>` **signals first, then records**: it TERMs the pid in
the mission's `xo.pid` (best effort — a stale pid file is not a reason to refuse
to hand the conn back, and nothing is ever KILLed, so a worker gets to finish
its own cleanup), then writes `stood-down` plus the note
`Number One stood down <time> · you have the conn`, and the lock lifts.

Standing down is an **action**, so it appends its own `stood-down` line to
`<mission>/number-one.jsonl` — the living comment's journal is otherwise the one
surface with no record that a spin was aborted. It also **clears
`lastPending`**: that cksum is stamped BEFORE the spin, so a worker killed
mid-spin would otherwise leave Number One locked out of a gate it never actually
read. The conn comes back, and so does the gate.

**It never stops the fixes.** `xo.pid` is Number One's own chain — its worker,
its browser, its launch. `xo-resolve.pid` is the `lcars resolve-logs` driver
working the logged bugs, and **those are LCARS's missions, not the first
officer's**: each has its own issue, its own branch and its own worker. That pid
is read and never signalled. When it is alive the stand-down note says so —
`Number One stood down <time> · N log/logs still driving · the re-verify gate will
wait for you` — because a captain taking the conn back mid-fix-round needs to
know both that the fixes are still going and that the gate at the end of them is
now his.

A repo-level `lcars xo off` does that for every engaged mission and flips
`enabled` to `false` — **keeping the recorded engine**, because the captain
turned Number One off, he did not un-choose his engine.

## Related

- `skills/lcars-run/ownership.sh` — `lcars_xo_lock_reason`, `xo-lock-reason`
- `skills/lcars-init/lcars-common.sh` — `lcars_engine_available`,
  `lcars_xo_default_engine`, `lcars_config_set_or_add_raw`, `lcars_config_get_raw`
- `skills/lcars-run/worker-adapter.sh` — the `number-one` role (both CLIs)
- `skills/lcars-run/run.sh` — `spawn_number_one`, `spawn-number-one`,
  `stage_key_for_role number-one → numberOne`, `drive_engage_number_one`,
  `drive_number_one_gate` (the `cmd_drive` hook + the `--step` arm)
- `skills/lcars-run/comment-mirror.sh` — `cm_render_number_one`,
  `cm_mirror_number_one`
- `skills/lcars-answer/answer.sh` — the escalation note on the inbox card
- `skills/lcars-respond/respond.sh` — `$LCARS_ANSWERED_BY` → `answeredBy`
- `tests/lcars-xo.test.sh`, `tests/worker-adapter.test.sh`,
  `tests/stage-model.test.sh`, `tests/lcars-respond.test.sh`,
  `tests/ownership.test.sh`,
  `tests/lcars-update.test.sh`, `web/tests/test_xo_lock_endpoints.py`,
  `tests/lcars-drive-xo.test.sh` (the driver hook — scoped, seconds, never the
  whole run suite), `tests/lcars-comment.test.sh`, `tests/lcars-answer.test.sh`
