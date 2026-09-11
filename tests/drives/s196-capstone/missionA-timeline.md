# S196 Capstone — MISSION A timeline

A live, end-to-end LCARS drive on the real `roferg/lcars-mp-fixture` repo,
photographed at every step. Written **as it happened**.

- Product under test: `/Users/roganferguson/Projects/LCARS` @ `feat/portability` `6ea253f` (VERSION 2026.9.3)
- Laptop **A1** = `/tmp/s196cap/A1` (files the mission) — laptop **B1** = `/tmp/s196cap/B1` (cold clone, adopts)
- Mission B runs in parallel on A2/B2; Mission A touches only files whose names begin with `a_`.
- Shots: `tests/drives/s196-capstone/shots/missionA/`
- **Every** browser capture used `chrome --headless=new`. No headed browser was ever launched.

| key | value |
|---|---|
| mission id | `lcars-20260910-001-c118` |
| issue | [#73](https://github.com/roferg/lcars-mp-fixture/issues/73) |
| branch | `lcars/lcars-20260910-001-c118` (off `main`) |
| engine at file | copilot |

## Log

| time | what I did | what LCARS did | shot | notes |
|---|---|---|---|---|
| 10:40:28 | Cloned the fixture twice — `/tmp/s196cap/A1`, `/tmp/s196cap/B1` — from real GitHub. | two cold clones, `main` @ fixture HEAD; 0 open issues, 0 open PRs at start. | — | Fixture is a **Node** repo (`src/invoices.js`, `node --test test/*.test.js`), not Python — so the mission's file is `src/a_export.js`, not `.py`. `test/*.test.js` already globs the new test, so **no non-`a_` file needs touching.** |
| 10:40:48 | `lcars init` in A1. | stack `js`, `testCommand` `npm test`, 16 labels already present, and a **live probe** — it actually ran `npm test` and reported "TEST SYSTEMS ONLINE". | — | Init is not a claim, it is a run. Good. |
| 10:41:0x | (my own mis-step) ran `file.sh` from the wrong cwd. | Foundation gate refused: `◇ NO TEST FOUNDATION`. **Nothing was written** — the refused repo (`lcars-dev`) has no `.git/lcars` afterwards. | — | Operator error, not a product bug — but worth recording that the gate refuses **before** anything is created, exactly as its header promises. |
| 10:41:46 | `file.sh --prd … --engine copilot` in A1. | Mission `lcars-20260910-001-c118` · issue **#73** · branch `lcars/lcars-20260910-001-c118` off `main` · stage `align`. Estimator ran and priced it **$0.28–$0.93**, reasoning **LOW**, implementation **LOW**, and printed its reasoning. | — | The estimator is the only paid step at file time and it ran on **copilot**. |
| 10:49 | Board up on `http://127.0.0.1:8871` (A1, local adapter, PID 2225). Captured headlessly. | Card **#73** sits in **ALIGN**: owner pill `ROFERG` with avatar, cost pill `$0.28–$0.93`, `REASON ●○○ LOW`, `IMPL ●○○ LOW`, and a `▶ START` control. Mission B's #74 is visible in RESEARCH as `◆ REMOTE · DRIVEN ELSEWHERE` — the two parallel missions can see each other. | **capture FAILED — see `02-stage-align.png`, the same board state two minutes later** | **Chrome capture needed `--timeout`**: the board holds an SSE connection open, so the page never fires `load` and `--screenshot` alone hangs for ever. `--headless=new … --timeout=7000 --screenshot` is what works. Recorded because anyone automating the board will hit it. |
| 10:52 | Read `state.json` after filing. | `"workerBin": "copilot"` is recorded — but **no `engineSource`**, so the Align card shows no `copilot · mission pin` provenance line yet. `run.sh` writes `engineSource` on the first advance (run.sh:14136), and `adopt.sh` writes it at adopt. | — | Not a defect, a sequencing fact: the provenance line appears once something *resolves* the engine, not when `--engine` merely pins it. Worth knowing if you expect it on a freshly filed card. |
| 10:56:0x | Started a headless stage-watcher (polls the board every 4s, shoots on every stage/gate change) and then `run.sh drive --mission lcars-20260910-001-c118`. | Driver printed `auto-advance`, re-checked base freshness, then `research ▶ running…`. Engine: **copilot** (free). | `02-…` onward, captured automatically | Stage transitions are photographed by the watcher so nothing is faked — if a shot is missing it is because the transition was faster than a 4s poll, and it will say so. |
| 10:51:52 | Watcher's first frame. | Card still in **ALIGN**, pre-drive. | `02-stage-align.png` | Baseline frame. |
| 10:52:01 | — | Card moves to **RESEARCH** and goes `running`. | `03-stage-research.png` | The label swap and the on-disk stage move together, so the board is honest within one poll. |
| 10:54 | Started B1's board (`http://127.0.0.1:8872`, PID 63734) on the **cold** clone — no `lcars init`, no `.git/lcars`. | Both missions show up as **`◆ REMOTE · DRIVEN ELSEWHERE`** cards with their cost + difficulty pills carried across from the issue. B1 had literally never seen either mission. | `04-b1-remote-card.png` | **The remote card carries NO control row while the mission is mid-pipeline** — `adoptControl()` is gated on `m.adoptable`, which the daemon derives from the stage, and Adopt is honest only at the two ENDS (Align / Verify). So at Research the correct control row is *empty*, and `◆ Adopt ▸` appears when it reaches Verify. Photographed again there. |
| 10:54 | Also hit: the B1 board's first paint says `loading…` for ~10s while the remote overlay calls GitHub. | A 7s headless capture caught an empty board; an 18s one caught the real thing. | — | Not a bug — a capture lesson. The remote overlay is a live `gh` round-trip. |
| 10:57 | `run.sh usage --mission …` mid-flight. | Real per-worker actuals are already on disk in `usage.json`: `infra/context-pack` 44,899 in / 1,731 out, `estimate` 48,181/1,592, `research-questions` 50,611/1,280 — all `engine=copilot`, `model=claude-opus-4.8`, `source=session-state`. | — | **Two things worth flagging** (see Defects): the `estimate` record has an **empty `stage`**, and the **4 parallel research agents left no usage records at all** — only the question-generator did. (I first also wrote that the `ts` field was null; that was **my** error — I read the wrong key. Every record does carry a real `ts`.) |
| 10:57 | — | `research ✓ 4 research agent(s) complete ⊘ isolated ⌂ lcars/… @ 2749acb` → `validate ▶ running…`. | (watcher) | The `⊘ isolated` marker is printed per stage, so the cold-worker contract is visible from the outside. |
| 10:54:26 | — | **VALIDATE** — `validate ✓ no scope changes`. | **capture FAILED (blank `loading…` frame, deleted)** | The only stage frame of Mission A that was lost. |
| 10:55:46 | — | **PLAN** — `plan ✓ 1 ticket(s)`. | `06-stage-plan.png` | |
| 10:56:39 | — | **PLAN REVIEW** — `plan-review ✓ passed review` first time round, no objection loop. | `07-stage-plan-review.png` | |
| 10:57:31 | — | **SCHEDULE** — `schedule ✓ 1 wave(s)`, sub-issue opened. | `08-stage-schedule.png` | |
| 10:57:40 | — | **IMPLEMENT** — one unified TDD worker; `implement ✓ 1/1 ticket(s) green ⊘ isolated`. | `09-stage-implement.png` | |
| 10:58:58 → 10:59:25 | — | **VERIFY** — `verify ✓ PR opened` → **PR [#76](https://github.com/roferg/lcars-mp-fixture/pull/76)**, walk-away notification fired, driver `⏹ stopped at: verify (in review — PR open)`. | `10-stage-verify.png` | **Whole pipeline, Align → Verify, in 7m24s on Copilot.** All eight transitions were caught by the watcher; none is faked. |
| 11:0x | Checked what the PR actually changed. | `gh pr view 76` → **exactly two files**: `src/a_export.js`, `test/a_export.test.js`. +108 / −0. | — | The `a_`-only constraint written into the PRD held all the way through Implement. That is what makes the two parallel missions mergeable. |
| 11:0x | Re-framed the board capture. | — | `10-stage-verify.png` (re-shot), `13-a1-verify-card-detail.png` | **Capture defect of MINE, recorded for honesty:** shots `09`/`10`/`11` were first taken in a 1400px-wide viewport, and the board is ~2170px wide across its 9 columns — so IMPLEMENT / VERIFY / DONE were off-screen and those frames are blank past SCHEDULE. From here on every frame captures the **whole** board (2400 CSS px @2x, downscaled) and key cards also get a native-resolution detail crop. `09-stage-implement.png` and `11-stage-verify.png` cannot be re-taken and stay as they were. |
| 11:0x | Detail crop of the Verify card. | Card **#73**: provenance line **`copilot · mission pin`**, owner pill `ROFERG` + avatar, estimate `$0.28–$0.93`, **`ACTUAL ~$2.33`**, `REASON ●○○ LOW`, `IMPL ●○○ LOW`, control `✓ REVIEW PR ▸`. | `13-a1-verify-card-detail.png` | The provenance line **did** appear once `run.sh` resolved the engine — as predicted at 10:52. And the board carries the **measured** cost beside the estimate: **actual ~$2.33 against an estimate of $0.28–$0.93 — 2.5× over the top of the range.** |
| 11:0x | B1 board again, now that #73 is at Verify. | The remote card's control row now offers **`◆ ADOPT ▸`** and nothing else — the read-only sweep hides every other control on a remote card. | `12-b1-remote-adopt-control.png` | Confirms the earlier note: `adoptable` is stage-derived, so Adopt is offered at the two ENDS only. (The frame also caught Mission B's bug **#77** arriving as a remote Align card with its own `◆ ADOPT ▸`.) |
| 11:04:40 | **Adopt, attempt 1** — on B1, through a real pty: `script -q /dev/null bash …/adopt.sh --issue 73`. | `◇ Adopted lcars-20260910-001-c118 — stage verify`. Rebuilt `prd.md` from the issue body, fetched the branch, resolved **PR #76** and recorded `prUrl`/`prNumber`, claimed nothing (Verify never claims), and **seeded a `config.json`** on a clone that had none — with a warning saying so and telling me to run `lcars init` to finish. **Engine: `copilot` — kept**, because this machine has copilot too. | — | **It asked me nothing, and that was correct.** Adopt only asks when the mission's engine is missing here, or when the repo's `config.json` disagrees. Both CLIs are installed on this laptop and a cold clone has no config, so the ask-branch is unreachable in this shape. *Also worth the captain's attention:* **no `lcars` verb writes `config.json workerBin`** — `init` doesn't seed it and `update` has no flag for it — so the "config disagrees, so I ask" branch has no CLI path to reach it at all. |
| 11:05:5x | **Adopt, attempt 2 — the engine switch.** Same pty, same command, plus the product's own engine seam: `LCARS_COPILOT_BIN=copilot-not-on-this-laptop`. That makes the shared detector answer, truthfully for that shell, "copilot is not on this machine" — the real portability case. I typed `claude` at the prompt. | The prompt, verbatim: <br>`This mission was filed on copilot, which is NOT installed on this machine.`<br>`Installed here: claude`<br>`Which engine should drive this mission here? [claude] (claude):`<br>…and then: `Engine: claude — CONVERTED here (the mission was filed on copilot, which this machine does not have). Recorded on the mission; it outranks config.json from now on.` | `14-adopt-prompt-engine-switch.png` | Idempotent as advertised — *"(refreshed an existing local mission — local artifacts kept)"*. `state.json` now reads `workerBin: claude`, `engineResolved: claude`, `engineSource: adopt-converted`. |
| 11:06 | Board on B1 after the adopt. | Card **#73** is now a LOCAL card at **VERIFY**: provenance **`claude · converted at adopt`**, owner pill `ROFERG`, estimate `$0.28–$0.93`, `REASON ●○○ LOW`, `IMPL ●○○ LOW`, `✓ REVIEW PR ▸`. | `15-b1-adopted-claude-converted.png` | The estimate pills survived the machine hop (they ride in the handoff envelope). **The `ACTUAL ~$2.33` pill did NOT** — `usage.json` is not carried across, so the adopting laptop sees the estimate but not what the mission has actually cost so far. Worth knowing before you approve from the other laptop. |
| 11:07:31 | **`lcars log`** from B1 — one real bug against the code the mission had just written. I read `src/a_export.js` off the branch first: its `toInteger()` returns `0` for anything `Number.isInteger` rejects, so a line with `qty: 1.5` exports as `x,0,500` — silent data loss. | `1 bug mission filed and linked to #73` → mission **`lcars-20260910-002-ddb2`**, issue **#78**. Its **branch is the PARENT's branch** (`lcars/lcars-20260910-001-c118`), and its base is that branch too — a logged bug's fix lands on the mission it was found in. | `16-b1-bug-card-linked.png`, `17-b1-bug-card-detail.png` | The card carries the link on its face: **`⊗ BUG · CHILD OF #73`**, plus `claude · host CLI`, estimate `$0.57–$2.46`, `REASON ●○○ LOW`, `IMPL ●○○ LOW`, `▶ START`. |
| 11:11:11 | `run.sh drive --mission lcars-20260910-002-ddb2` on B1. **This leg is BILLED — it runs on claude.** | `research ▶ running…`, and two honest notes first: `⊘ base lcars/… is a Mission branch — left exactly as it is (nothing fetched, nothing moved)`, and `⚠ this repo predates LCARS versioning — run lcars update`. | (watcher) | **The version warning is a portability wart:** `adopt` seeded B1's `config.json` but did **not** stamp `lcarsVersion`, so the very next `lcars run` on a freshly adopted clone tells the captain his repo "predates LCARS versioning". `lcars init` writes that key; adopt's minimal seed does not. |
| 11:13:20 | — | Bug mission: `research ✓ research complete` (role `research-grounding` — a logged bug enters at **Research in grounding mode**, not straight to Plan), then `validate ✓ no scope changes`. | `18-stage-align.png`, `19-stage-research.png`, `20-stage-validate.png` | Every worker so far is `engine=claude`, models `claude-opus-5` / `claude-sonnet-5`. |
| 11:17 | Read both missions' `usage.json` in full. | Copilot leg (mission A): **7 records, $2.33, 105 premium requests**. Claude leg (the bug) at this point: **4 records, $2.95**. | — | **Three measurement defects fall out of this** — see the Defects section at the bottom. Short version: the parallel research agents are **not** metered, every Copilot worker reports **exactly 15** premium requests, and `run.sh usage`'s summary omits the cache columns that are actually paying the bill. |
| 11:15:10 → 11:19:42 | — | Bug mission ran the rest on **claude**: `plan ✓ 1 ticket(s)` → `plan-review ✓ passed review` → `schedule ✓ 1 wave(s)` → `implement ✓ 1/1 ticket(s) green` → **Verify**: `◇ bug fix folds onto parent lcars-20260910-001-c118 — no per-bug PR (parent carries it)`, `⏹ stopped at: verify (folds onto the parent — accept via the parent's re-verify gate)`. | `21-stage-plan.png`, `22-stage-plan-review.png`, `23-stage-schedule.png`, `24-stage-implement.png`, `25-stage-verify.png`, `26-stage-verify.png` | **Whole bug pipeline, Align → Verify, in 8m36s on Claude.** The fix it wrote: swap `toInteger`'s `Number.isInteger` guard for `Number.isFinite`, so a finite fractional value passes through and `null`/`undefined`/`NaN`/`Infinity` still coerce to `0`. `npm test` 21/21. |
| 11:20 | `lcars approve --mission lcars-20260910-002-ddb2` (the bug first, as asked). | **Refused**: *"no open PR recorded for this mission — run `lcars run lcars-20260910-002-ddb2` so Verify opens the PR, then approve to merge it."* | — | **Defect (see below).** The refusal is right that there is no PR, but its advice cannot ever work: this mission's Verify *deliberately* opens no PR — it folds onto the parent. Following the message loops forever. |
| 11:20 | Checked where the bug-fix commit actually was. | Commit `8423df3` sat on B1's **local** `lcars/lcars-20260910-001-c118`; `origin`'s copy of that branch — and therefore PR #76 — still had only the original commit. | — | Not a leak: `approve.sh` pushes the branch itself right before merging (approve.sh:392), so the fold lands at merge time. Worth knowing that between the bug's Verify and the parent's approve, **the PR on GitHub does not show the fix**. |
| 11:21 | `lcars approve --mission lcars-20260910-001-c118`. | It did **not** merge — it noticed `main` had moved (Mission B merged 3 commits while I was driving), **reconciled `main` into the branch** (merge `b239192`), **re-ran the tests green (1/1)**, and raised a fresh human gate: *"Reapprove to merge."* | `27-reconcile-awaiting-reapprove.png` | This is the multiplayer guard doing its job, live and unprompted. The card also shows the bug's measured **`ACTUAL ~$4.49`**. |
| 11:21 | — | Noticed on the same card: #73's provenance line had changed from **`claude · converted at adopt`** to **`claude · $LCARS_WORKER_BIN`**. `state.json` confirms `engineSource` was rewritten `adopt-converted` → `env`. | `27-reconcile-awaiting-reapprove.png` | **Defect (see below).** The engine value is unchanged and correct; what is lost is the *provenance* S196 exists to show — approve's own `LCARS_WORKER_BIN` pin overwrites the record of the captain's choice at adopt. |
| 11:22:36 | `lcars approve --mission lcars-20260910-001-c118 --reapprove`. | `Folded logged bug: lcars-20260910-002-ddb2 → done` · `Logged bugs closed out: 1` · **`APPROVE: merged`** · **PR [#76](https://github.com/roferg/lcars-mp-fixture/pull/76) merged** → `main` · `Stage: done`. | `28-stage-done.png`, `29-both-done.png`, `30-both-done-detail.png` | Both cards land in **DONE** together — the child bug is closed out by the parent's merge, exactly as its Verify promised. |
| 11:23 | Verified the result on real GitHub. | PR **#76 MERGED**, three commits (feature, bug fix, the reconcile merge), **files: `src/a_export.js`, `test/a_export.test.js` only**. `main`'s `src/` now holds `a_export.js` (mine), `b_money.js` (Mission B's) and the original `invoices.js`. **0 open issues, 0 open PRs** — the fixture is back as I found it. | — | **The two parallel missions merged clean.** The `a_`/`b_` file discipline written into both PRDs is the whole reason. |
| 11:24 | Last look at **A1**, the laptop that filed the mission. | A1 still shows **#73 in VERIFY**, `copilot · mission pin`, `ACTUAL ~$2.33`, and an active **`✓ REVIEW PR ▸`** control — for a PR that merged two minutes ago on the other laptop. | `31-a1-after-merge-elsewhere.png` | **Defect (see below).** The local adapter reads only local `state.json`; nothing tells the originating clone the mission shipped, so it offers a live control on merged work. `lcars adopt 73` on A1 would refresh it, but nothing says so. |

## Cost — measured, not estimated

Both numbers come from each mission's own `usage.json` (one record per cold-worker spawn, written by `run.sh`'s post-exit usage capture), read back with `run.sh usage --mission <id>`.

### The Copilot leg — mission `lcars-20260910-001-c118` on A1 (free under the subscription)

| stage | role | model | in | out | cache r/w | cost | premium reqs |
|---|---|---|---|---|---|---|---|
| infra | context-pack | claude-opus-4.8 | 44,899 | 1,731 | 34,138 / 10,751 | $0.268 | 15 |
| *(blank)* | estimate | claude-opus-4.8 | 48,181 | 1,592 | 34,226 / 13,947 | $0.281 | 15 |
| research | research-questions | claude-opus-4.8 | 50,611 | 1,280 | 40,987 / 9,612 | $0.285 | 15 |
| validate | validate | claude-opus-4.8 | 54,281 | 3,646 | 39,809 / 14,464 | $0.363 | 15 |
| plan | plan | claude-opus-4.8 | 49,820 | 2,133 | 33,419 / 16,395 | $0.302 | 15 |
| plan-review | plan-review | claude-opus-4.8 | 49,173 | 1,067 | 38,639 / 10,526 | $0.273 | 15 |
| implement | implement-tdd | claude-opus-4.8 | 95,605 | 3,190 | 77,518 / 18,075 | $0.558 | 15 |
| **TOTAL** | **7 records** | | **392,570** | **14,639** | | **$2.329** | **105** |

Board pill: **`ACTUAL ~$2.33`**, against an estimate of **$0.28–$0.93** — **2.5× over the top of the estimated range.**
**This total is an undercount:** the run reported `4 research agent(s) complete` and **none of those four workers wrote a usage record**.

### The Claude leg — bug mission `lcars-20260910-002-ddb2` on B1 (BILLED)

| stage | role | model | in | out | cost |
|---|---|---|---|---|---|
| infra | context-pack | claude-opus-5 | 258 | 5,229 | $0.408 |
| *(blank)* | estimate | claude-opus-5 | 452 | 10,109 | $0.811 |
| research | research-grounding | claude-sonnet-5 | 18 | 4,218 | $0.501 |
| validate | validate | claude-opus-5 | 392 | 16,360 | $1.228 |
| plan | plan | claude-opus-5 | 28 | 5,767 | $0.640 |
| plan-review | plan-review | claude-opus-5 | 18 | 5,912 | $0.373 |
| implement | implement-tdd | claude-opus-5 | 22 | 6,445 | $0.528 |
| **TOTAL** | **7 records** | | **1,188** | **54,040** | **$4.489** |

Board pill: **`ACTUAL ~$4.49`**, against an estimate of **$0.57–$2.46** — **1.8× over the top of the range.**
The `in` column looks impossibly small only because the summary omits the cache columns; the records themselves carry them (e.g. the Validate worker: 415,694 cache-read + 97,490 cache-write) and the cost figure **does** include them.

**Total measured billed spend for MISSION A: $4.49.**
Not captured: the four Copilot research subagents, and whatever (if anything) the reconcile/re-test step inside `lcars approve` spent — no `usage.json` was written for the parent mission on B1 at all.

## Product defects found by this run

Each is *did / expected / saw*. None of them stopped the arc.

**D1 — `lcars approve` on a folded child bug gives advice that can never work.**
*Did:* `approve.sh --mission lcars-20260910-002-ddb2` on a child bug parked at Verify, whose own Verify had just printed *"folds onto parent — no per-bug PR (parent carries it)"*.
*Expected:* a refusal that points at the parent — "this bug folds onto `lcars-20260910-001-c118`; approve that".
*Saw:* *"no open PR recorded for this mission — run `lcars run lcars-20260910-002-ddb2` so Verify opens the PR, then approve to merge it."* Running that again just re-prints the fold message. The two code paths disagree about what a child bug is.

**D2 — the parallel research subagents are never metered.**
*Did:* ran mission A's Research; the driver reported `research ✓ 4 research agent(s) complete`.
*Expected:* 5 usage records for that stage (the question-generator + 4 agents), or at worst 4 `"source":"unavailable"` records.
*Saw:* exactly **one** record, `role: research-questions`. The four agents left no trace at all — not even an unavailable marker — so the mission's `ACTUAL` pill silently understates the run. Research was the most parallel stage in the drive and it is the one blind spot.

**D3 — every Copilot worker reports exactly 15 premium requests.**
*Did:* read all 7 Copilot usage records.
*Expected:* a per-spawn count that varies with the size of the work.
*Saw:* `premiumRequests: 15` on all seven — the tiny plan-review worker and the big implement worker alike, totalling a suspiciously round 105. It reads like a whole-session or default figure being attributed to each spawn rather than a per-worker measurement. (The dollar figure is derived from tokens and looks sound; it is the premium-request count that does not.)

**D4 — `lcars approve` destroys the engine provenance that `lcars adopt` just recorded.**
*Did:* adopted #73 with an explicit engine conversion (`engineSource: adopt-converted`, card reading `claude · converted at adopt`), then ran `lcars approve`.
*Expected:* the provenance to survive — approve is not a re-decision about the engine.
*Saw:* `engineSource` rewritten to `env` and the card reading `claude · $LCARS_WORKER_BIN`. Approve exports `$LCARS_WORKER_BIN` to pin the engine, and the resolver records that as the source. The captain's answer at the adopt prompt is overwritten by a mechanism that was only trying to preserve it.

**D5 — the originating laptop never learns its mission shipped.**
*Did:* filed and drove #73 on A1, adopted and merged it from B1, then looked at A1's board.
*Expected:* A1 to show it Done, or at least not to offer an action on it.
*Saw:* A1 shows #73 in **VERIFY** with a live `✓ REVIEW PR ▸` control for an already-merged PR. The local adapter reads only local `state.json`, and nothing in the merge path touches the other clone. Re-adopting on A1 would fix it, but nothing on the board says so.

**D6 — `lcars adopt` seeds a `config.json` with no `lcarsVersion`, so the next run warns the fresh clone is out of date.**
*Did:* adopted onto a cold clone (adopt seeded `config.json`, saying so), then ran `lcars run`.
*Expected:* no version complaint on a clone LCARS itself had just configured.
*Saw:* `⚠ this repo predates LCARS versioning — run 'lcars update'.` on every subsequent command. `lcars init` writes `lcarsVersion`; adopt's minimal seed does not.

**D7 (cosmetic) — the `estimate` usage record has an empty `stage`.**
*Saw:* `run.sh usage --mission …` prints a headless row: `STAGE  records=1 …`. Both missions, both engines. The record's `role` is `estimate`; it just has no stage key.

**D8 (cosmetic) — `run.sh usage` hides the tokens that are paying the bill.**
*Saw:* `TOTAL records=7 inputTokens=1,188 outputTokens=54,040 costUsd=4.4892`. The cache-read / cache-write columns are in every record and dominate the cost (one worker alone: 415,694 cache-read), but the summary never prints them, so the line reads as though $4.49 came from 1,188 input tokens.

## Not a defect, but worth the captain knowing

- **The adopt engine prompt is unreachable on a laptop that has both CLIs.** Adopt asks only when the mission's engine is missing here, or when the repo's `config.json` disagrees — and **no `lcars` verb ever writes `config.json workerBin`** (`init` doesn't seed it, `update` has no flag for it). On a normal two-CLI machine the branch that exists to protect the captain simply never fires. I reached it honestly by telling the product's own detector, via `LCARS_COPILOT_BIN`, that copilot is not on this shell — the real single-CLI laptop case.
- **The `ACTUAL` cost pill does not travel.** The estimate pills ride the handoff envelope and survive the machine hop; `usage.json` does not, so the adopting laptop can see what a mission was *predicted* to cost but not what it *has* cost.
- **The board is ~2170 CSS px wide across its nine columns.** Anything narrower silently hides IMPLEMENT / VERIFY / DONE off the right edge with no scroll affordance in a screenshot.
- **Capturing the board headlessly needs `--timeout`.** The page holds an SSE connection open, so it never fires `load` and `chrome --headless=new --screenshot` waits for ever. `--timeout=<ms>` forces the capture. B1's board, which builds a remote overlay from live `gh` calls, needed 30–45s to paint.

## Shot manifest

All 29 frames were captured with `chrome --headless=new`. No headed browser was launched at any point.
Frames `02`–`11` are 1400px-wide viewports (ALIGN…SCHEDULE visible); from `10` onward every frame is the
whole nine-column board (2400 CSS px @2× retina, downscaled to 1400), and the `-detail` frames are
native-resolution crops of one column. Numbers `01` and `05` are absent — those two captures came back blank.

| file | what it shows |
|---|---|
| `02-stage-align.png` | A1 board the moment the mission is filed — #73 in ALIGN, owner pill ROFERG, `$0.28–$0.93`, REASON LOW, IMPL LOW, `▶ START`. Mission B's #74 sits beside it as a REMOTE card. |
| `03-stage-research.png` | #73 moves to RESEARCH and goes running. |
| `04-b1-remote-card.png` | Laptop B1, a cold clone with no `.git/lcars` — both missions appear as `◆ REMOTE · DRIVEN ELSEWHERE`, pills carried from the issue, and **no control row** (mid-pipeline is not adoptable). |
| `06-stage-plan.png` | #73 in PLAN. |
| `07-stage-plan-review.png` | #73 in PLAN REVIEW. |
| `08-stage-schedule.png` | #73 in SCHEDULE — the card is off the right edge of this 1400px frame. |
| `09-stage-implement.png` | #73 in IMPLEMENT — likewise off the right edge. |
| `10-stage-verify.png` | Whole board with #73 in VERIFY, PR open (re-framed wide). |
| `11-stage-verify.png` | The watcher's second Verify frame (running → parked). Card off the right edge. |
| `12-b1-remote-adopt-control.png` | B1's remote card for #73 now offers **`◆ ADOPT ▸`** and nothing else — Adopt is honest only at Align and Verify. Mission B's bug #77 has arrived as a remote Align card too. |
| `13-a1-verify-card-detail.png` | Native-resolution card #73 at Verify on A1: `copilot · mission pin`, ROFERG, `$0.28–$0.93`, **`ACTUAL ~$2.33`**, REASON LOW, IMPL LOW, `✓ REVIEW PR ▸`. |
| `14-adopt-prompt-engine-switch.png` | The adopt terminal, verbatim — *"This mission was filed on copilot, which is NOT installed on this machine / Installed here: claude / Which engine should drive this mission here? [claude] (claude):"* — and the conversion it recorded. |
| `15-b1-adopted-claude-converted.png` | The same mission on B1 after adopt: **`claude · converted at adopt`**, owner pill, estimate pills carried across. No ACTUAL pill — usage does not travel. |
| `16-b1-bug-card-linked.png` | Whole B1 board with the newly logged bug #78 in ALIGN. |
| `17-b1-bug-card-detail.png` | The bug card up close: **`⊗ BUG · CHILD OF #73`**, `claude · host CLI`, `$0.57–$2.46`, REASON LOW, IMPL LOW, `▶ START`. |
| `18-stage-align.png` | Bug #78 at ALIGN, pre-drive. |
| `19-stage-research.png` | Bug #78 in RESEARCH (grounding mode). |
| `20-stage-validate.png` | Bug #78 in VALIDATE. |
| `21-stage-plan.png` | Bug #78 in PLAN. |
| `22-stage-plan-review.png` | Bug #78 in PLAN REVIEW. |
| `23-stage-schedule.png` | Bug #78 in SCHEDULE. |
| `24-stage-implement.png` | Bug #78 in IMPLEMENT with wave 1/1 progress — and the parent #73 beside it showing `◆ RESOLVING 1 LOGGED BUG…`. |
| `25-stage-verify.png` | Bug #78 reaches VERIFY. |
| `26-stage-verify.png` | Bug #78 parked at Verify (folds onto the parent). |
| `27-reconcile-awaiting-reapprove.png` | After `lcars approve`: the reconcile gate. Bug card shows **`ACTUAL ~$4.49`**; #73's provenance has been rewritten to `claude · $LCARS_WORKER_BIN`. |
| `28-stage-done.png` | The moment #78 flips to DONE. |
| `29-both-done.png` | Whole board: DONE · 2. |
| `30-both-done-detail.png` | Both cards in DONE, native resolution — #78 `lcars:done` with `ACTUAL ~$4.49`, #73 `lcars:done`. |
| `31-a1-after-merge-elsewhere.png` | A1, two minutes after the merge: still showing #73 in VERIFY with a live `✓ REVIEW PR ▸` for an already-merged PR. |

## Housekeeping

**Processes I started, and killed — by PID, never by name or pattern.**

| PID | what | started | killed |
|---|---|---|---|
| 2225 | A1 viewscreen daemon, `127.0.0.1:8871` | 10:44 | 11:26 ✓ |
| 63734 | B1 viewscreen daemon, `127.0.0.1:8872` | 10:54 | 11:26 ✓ |
| 56432 | A1 stage-change watcher | 10:56 | 11:26 ✓ |
| 12671 | B1 stage-change watcher | 11:11 | 11:26 ✓ |
| 57029 / 12672 | the two `run.sh drive` processes | 10:56 / 11:11 | exited on their own |
| (transient) | every headless Chrome, killed by matching its own `--user-data-dir` | | ✓ |

The three unrelated S187 daemons — **54060, 59527, 59747** — were confirmed still alive afterwards and were never touched. Mission B's processes were never touched either.

**No headed browser was launched at any point in this mission.** Every capture used `--headless=new`, and every Chrome process was killed by matching the profile directory this mission created.

`tests/lcars-run.test.sh` and `tests/run.sh` were never run. The LCARS product tree was not modified — the only files written under it are this timeline and the shots beside it.

**Fixture left as found:** `roferg/lcars-mp-fixture` has 0 open issues and 0 open PRs from this mission; PR #76 is merged and both `src/a_export.js` and Mission B's `src/b_money.js` are on `main`.
