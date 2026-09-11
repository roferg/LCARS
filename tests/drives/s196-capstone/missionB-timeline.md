# S196 CAPSTONE — MISSION B timeline

A real, live, end-to-end LCARS run against `roferg/lcars-mp-fixture`, driven and
photographed step by step. Written AS IT HAPPENS, so a run that stops early
still leaves the captain the part that happened.

- Product under test: `/Users/roganferguson/Projects/LCARS` @ `feat/portability` (`6ea253f`) — **not modified**.
- Laptop A2: `/tmp/s196cap/A2` (files the mission, engine **claude**, BILLED).
- Laptop B2: `/tmp/s196cap/B2` (cold clone; adopts, engine switched to **copilot**, free).
- Shots: `tests/drives/s196-capstone/shots/missionB/`, ~1400px wide.
- Every Chrome invocation is `--headless=new`. No headed browser was ever launched.

Mission A's agent owns `/tmp/s196cap/A1` and `/tmp/s196cap/B1`; nothing here touches those.

| key | value |
|---|---|
| mission id | `lcars-20260910-001-50e6` |
| issue | [#74](https://github.com/roferg/lcars-mp-fixture/issues/74) |
| branch | `lcars/lcars-20260910-001-50e6` (off `main`) |
| PR | [#75](https://github.com/roferg/lcars-mp-fixture/pull/75) (opened by Verify at 10:56) |

---

## Log

### 10:40:xx · setup · two cold clones + init

- **Did:** cloned `roferg/lcars-mp-fixture` twice — `/tmp/s196cap/A2` ("laptop A2") and
  `/tmp/s196cap/B2` ("laptop B2", left untouched and cold for now). Ran
  `lcars-init/init.sh` in A2 only.
- **LCARS did:** `✓ .git/lcars/ created`, stack detected `js`, test command
  `npm test -- ${LCARS_TESTS_DIR:+…}`, Claude CLI 2.1.263 verified, 16 labels already
  present, and — notably — it **actually ran the suite** as a live probe:
  `PROBE COMPLETE — test systems responding: the suite ran and passed.`
- **Surprise:** the fixture is a **JavaScript** repo (`src/invoices.js`, `node --test`),
  not Python. The suggested `src/b_money.py` was adapted to `src/b_money.js` +
  `test/b_money.test.js` — same shape, same `b_` fence.
- **Shot:** none.

### 10:42:31 → 10:44:22 · step 1 · FILE IT ON A2, ENGINE = CLAUDE (billed)

- **Did:** wrote a PRD whose **Constraints** section carries the file fence in bold
  ("may create or modify ONLY files whose basename begins with `b_`"), then:
  `lcars file --prd <prd> --engine claude` in `/tmp/s196cap/A2`.
- **LCARS did:** base-freshness check (`current`), minted the mission, opened the issue,
  and ran a **live estimator worker** (this is the first billed call):

  ```
  Mission filed: lcars-20260910-001-50e6
  GitHub issue:  #74
  Branch:        lcars/lcars-20260910-001-50e6 (off main)
  Stage:         align
  Estimate: reasoning=LOW implementation=MEDIUM  (cost $0.57–$3.11)
  Models:   research/validate=Sonnet/Sonnet · plan/plan-review=Sonnet/Sonnet · implement=Opus · verify=Sonnet
  ```

  The estimator's rationale independently spotted the real risk in the mission
  ("…exactly the IEEE-754 traps where the naive `Math.round(x*100)/100` silently rounds
  down"), which is why it put **Opus** on Implement.
- **Engine in effect:** `claude` — verified in `state.json`: `"workerBin": "claude"`.
- **Mission id / issue / branch:** `lcars-20260910-001-50e6` / #74 / `lcars/lcars-20260910-001-50e6`. No PR yet.
- **Elapsed:** 1m51s (almost all of it the estimator worker).

### 10:47 · step 1b · the board, photographed

- **Did:** started the A2 viewscreen daemon and shot the board headlessly.
- **LCARS did:** served the board. Card **#74** sits in **ALIGN** with the owner pill
  `ROFERG`, cost pill `$0.57–$3.11`, and both estimate pills (`REASON ●○○ LOW`,
  `IMPL ●●○ MEDIUM`), control row `▶ START`.
- **Surprise (a good one):** Mission A's card **#73** is *already visible on my board* as
  `◈ REMOTE · DRIVEN ELSEWHERE` with only `◆ ADOPT ▸` offered — the multiplayer view
  working live, unprompted, between two agents' clones. The ownership filter strip reads
  `ALL · 2 / MINE · 2 / REMOTE · 1`.
- **Shot:** `01-A2-filed-align.png` (+ `.txt` readout)
- **Daemon:** viewscreen A2 started, **PID 10499**, port 8790. Headless Chrome for shots:
  **PID 30673**, CDP port 9333, `--headless=new`.

### 10:49:56 · step 2 · DRIVE THE LIVE PIPELINE (`lcars run`, engine = claude)

- **Did:** `run.sh drive --mission lcars-20260910-001-50e6` in A2, backgrounded, plus an
  automatic stage watcher that polls `/api/board` every 5s and fires a headless shot on
  every stage change — so no transition is missed and none is invented.
- **Engine in effect:** `claude` (BILLED). The card itself proves it: the provenance line
  under the issue number reads **`claude · mission pin`**.

| time | stage | what LCARS did | shot |
|---|---|---|---|
| 10:49:56 | research ▶ | worker spawned; card shows a live status line, `⏸ PAUSE` offered | `02-A2-stage-research.png` |
| 10:50:2x | research ✓ | `0 questions (PRD unambiguous)  ⊘ isolated  ⌂ lcars/…-50e6 @ 2749acb` | — |
| 10:50:59 | validate ▶ | card moved to VALIDATE | `03-A2-stage-validate.png` |

- **Surprise:** the RESEARCH card renders a genuinely live worker readout —
  `SENSORS SWEEPING THE CODEBASE… — THINKING · SUBSPACE QUIET 9s`, then
  `… — WRITING OUTPUT` — not just a spinner. It is watching the worker, not the clock.

### 10:51 · step 3 (part 1) · B2, THE COLD CLONE — the mission as a REMOTE card

- **Did:** `lcars init` on the untouched `/tmp/s196cap/B2`, started its own viewscreen
  daemon on 8791, shot the board. B2 has **zero** local missions
  (`.git/lcars/missions/` is empty).
- **LCARS did:** B2's board shows **both** missions purely from GitHub, each badged
  `◈ REMOTE · DRIVEN ELSEWHERE`, with the cost and estimate pills intact.
- **Finding (by design, and worth stating):** #74's control row is **empty** right now —
  no `◆ ADOPT ▸`. `web/lcars_serve/remote.py` offers adopt only at
  `ADOPTABLE_STAGES = ("align", "verify")`, on the stated reasoning that only at those two
  ends is everything the next stage needs on the forge; in between, adopt would hand the
  captain a mission missing un-synced local artifacts. Mission A's #73, still at `align`,
  *does* show `◆ ADOPT ▸` on the same board — so this is the rule working, not a gap.
  The adopt shot the mission calls for therefore comes at **verify**.
- **Shot:** `04-B2-cold-remote-midflight.png`
- **Daemon:** viewscreen B2 started, **PID 52993**, port 8791.

- **Note on the ownership strip (`ALL · 2 / MINE · 2 / REMOTE · 1`):** not a
  miscount. `MINE` matches `owner.login === self`, and both "laptops" in this drive are
  the same GitHub account (`roferg`), so a card can honestly be both mine and remote.
  `MINE` and `REMOTE` are different axes, not a partition.

### 10:50–10:53 · step 2 continued · validate → plan

| time | stage | what LCARS did | shot |
|---|---|---|---|
| 10:50:59 | validate ▶ | worker spawned | `03-A2-stage-validate.png` |
| ~10:53:2x | validate ✓ | `no scope changes  ⊘ isolated  ⌂ lcars/…-50e6 @ 2749acb` — no human gate | — |
| 10:53:32 | plan ▶ | card in PLAN, live readout `PLOTTING THE COURSE TO ENGINEERING… — THINKING` | `05-A2-stage-plan.png` |

- Each stage's card carries its own themed live readout (`SENSORS SWEEPING THE CODEBASE…`
  at Research, `PLOTTING THE COURSE TO ENGINEERING…` at Plan). Every stage so far has run
  `⊘ isolated` in the mission's own worktree at the recorded base sha.
- **Measured spend at this point** (`run.sh usage --mission …`, real recorded actuals):
  `TOTAL records=3 costUsd=1.4967` — infra/context-pack $0.658 (opus), estimate $0.594
  (opus), research $0.244 (sonnet).

### 10:54 · step 2 continued · plan → plan review

| time | stage | what LCARS did | shot |
|---|---|---|---|
| ~10:54:1x | plan ✓ | `1 ticket(s)` — `t-001 Add roundHalfUp currency helper with red-to-green TDD tests`, 12 acceptance criteria, the last of which is *"No file other than src/b_money.js and test/b_money.test.js is created or modified"* — the PRD's file fence survived Align → Validate → Plan intact | — |
| 10:54:23 | plan-review ▶ | live readout `BRIDGE OFFICERS REVIEWING THE FLIGHT PLAN… — THINKING` | `06-A2-stage-plan-review.png` |

- **Measured spend at plan-review start:** `TOTAL records=5 costUsd=2.74687`
  (validate $0.555, plan $0.695 on top of the earlier $1.497).
  The mission's own estimate was `$0.57–$3.11` for the WHOLE run; we are at $2.75 with
  Implement (Opus) still ahead. Tracked as a finding, not a failure — see the cost section.

### 10:55–10:57 · step 2 finished · schedule → implement → VERIFY, PR open

| time | stage | what LCARS did | shot |
|---|---|---|---|
| 10:55:13 | schedule ▶/✓ | `1 wave(s)` | `07-A2-stage-schedule.png` |
| 10:55:22 | implement ▶ | the TDD worker (Opus, per the estimate's model mix) | `08-A2-stage-implement.png` |
| ~10:56:2x | implement ✓ | `1/1 ticket(s) green  ⊘ isolated` | — |
| 10:56:28 | verify | card in VERIFY | `09-A2-stage-verify.png` |
| 10:56:5x | verify | **PR opened automatically**, notification fired, driver stopped at the human gate | `10-A2-verify-PR75-open.png` |

Driver's closing readout:

```
🔔 LCARS lcars-20260910-001-50e6 — verify gate: PR open — review & merge:
   https://github.com/roferg/lcars-mp-fixture/pull/75
⏹ stopped at: verify  (in review — PR open)
```

**Every one of the eight transitions was observed and photographed** — align → research →
validate → plan → plan review → schedule → implement → verify. Nothing here is
reconstructed. Total pipeline wall time: **6m32s** (10:49:56 → 10:56:28).

- **What actually landed** (`origin/lcars/lcars-20260910-001-50e6`, commit `dccdd18`):
  `src/b_money.js` (+14) and `test/b_money.test.js` (+34). **Two files, both `b_`-prefixed.**
  The fence held. `npm test` green 14/14 (7 new + 7 pre-existing).
- **The card now shows its own actual cost.** Beside the `⬡ $0.57–$3.11` estimate pill sits
  `⬢ ACTUAL ~$3.88`. LCARS reports the overrun itself, on the card, without being asked.
- **Measured claude-leg spend, 7 recorded worker spawns:**

  | stage | role/model | cost |
  |---|---|---|
  | infra | context-pack, opus | $0.658 |
  | (filing) | estimate, opus | $0.594 |
  | research | sonnet | $0.244 |
  | validate | sonnet | $0.555 |
  | plan | sonnet | $0.695 |
  | planReview | sonnet | $0.538 |
  | implement | opus | $0.591 |
  | **TOTAL** | 936 in / 51,528 out | **$3.87652** |

### 10:58 · step 3 · B2, the cold clone, NOW offers ◆ ADOPT ▸

- **Did:** re-shot B2's board with the mission parked at verify.
- **LCARS did:** #74 is `◈ REMOTE · DRIVEN ELSEWHERE` with **exactly one control: `◆ ADOPT ▸`**
  — no Start, no Pause, no Approve. Mission A's #73, mid-pipeline at `implement`, correctly
  offers nothing at all. Both estimate pills and the owner pill render from GitHub alone;
  the `⬢ ACTUAL` pill does not, because the usage ledger is local to A2.
- **Shot:** `11-B2-remote-card-adopt-offered.png`

### 10:58:20 · step 4 · ADOPT ON B2 AND SWITCH THE ENGINE TO COPILOT

- **Setup (fixture, not product):** B2 is "the copilot laptop", so its own
  `.git/lcars/config.json` was given `"workerBin": "copilot"`. That is the repo-config
  knob adopt already reads (`CFG_ENGINE`); nothing in the product was touched.
- **Did:** `LCARS_ASSUME_TTY=1 adopt.sh --issue 74`, answering the prompt with `copilot`.
- **LCARS did — the prompt, verbatim:**

  ```
    This mission was filed on claude; this repo's config.json prefers copilot. Both are installed here.
    Which engine should drive this mission here? [claude] (claude copilot): copilot
  ```

  and then:

  ```
  ◇ Adopted lcars-20260910-001-50e6 — stage verify
    Issue:    #74 — Add a half-up currency rounding helper at src/b_money.js
    Mission:  /tmp/s196cap/B2/.git/lcars/missions/lcars-20260910-001-50e6
    Spec:     prd.md (rebuilt from the issue body)
    Branch:   lcars/lcars-20260910-001-50e6 — fetched from origin (local branch created)
    Engine:   copilot — your choice at the handoff (filed on claude, config.json prefers copilot). Recorded on the mission.
    Owner:    roferg (you)
    PR:       https://github.com/roferg/lcars-mp-fixture/pull/75
  ```

  Adopt took **6 seconds**, and it resolved the open PR by itself — `state.json` on B2 now
  carries `prNumber: "75"`, `review: "open"`, `workerBin: "copilot"`,
  `engineSource: "adopt-chosen"`.
- **The card afterwards** shows `copilot · chosen at adopt` under the issue number, the
  `ROFERG` owner pill, both estimate pills, and `✓ REVIEW PR ▸`.
- **Wording note, stated precisely:** the brief expected `copilot · converted at adopt`.
  The product writes **`chosen at adopt`** on this path and reserves `converted at adopt`
  for the non-interactive `--engine copilot` act (`adopt-converted` in
  `adopt.sh`, rendered by `board.js`'s `ENGINE_SOURCE_LABEL`). Both mean "the engine
  changed at the handoff"; `chosen` records that a human answered a prompt, `converted`
  that a flag decided it. The interactive path was driven here because the brief asked for
  the **prompt** to be captured, and only that path prints one.
- **Shots:** `12-B2-adopt-prompt-terminal.png` (the verbatim terminal capture, rendered
  to a page so it sits in the same timeline), `13-B2-adopted-copilot-card.png`.
- **Engine from here on: `copilot`.**

### 10:59:27 → 11:01:37 · step 5 · ONE REAL BUG, FILED FROM B2 WITH `lcars log`

- **Did:** read the shipped `src/b_money.js`, probed it in node, found a genuine defect,
  and filed it: `log.sh --parent lcars-20260910-001-50e6 --prd <bug-prd>`.
- **The bug (real, measured on the shipped code, not invented):** the helper ends
  `Math.sign(amount) * Math.round(cents) / 100`. When the magnitude rounds to zero and the
  sign is negative, the product is IEEE-754 **negative zero**:

  ```
  roundHalfUp(-0.001)                        => -0
  Object.is(roundHalfUp(-0.001), 0)          => false
  1 / roundHalfUp(-0.001)                    => -Infinity
  assert.strictEqual(roundHalfUp(-0.001), 0) => FAILS
  ```

  Money code hits this constantly (a sub-half-cent discount or refund), and
  `assert.strictEqual`/`Object.is` treat `-0` and `0` as different values.
- **LCARS did:** `1 bug mission filed and linked to #74 … lcars-20260910-002-b52b  #77`.
- **Bug mission:** `lcars-20260910-002-b52b` / issue **#77** / **engine `copilot`**
  (`engineSource: "config"` — B2's own preference, no flag needed).
- **Notable, and correct:** the bug's `branch` is the **parent's** branch
  `lcars/lcars-20260910-001-50e6`, not one of its own — `log.sh` (BUG-011) commits a
  pre-merge bug fix straight onto the parent's branch so the fix rides the parent's PR.
- **The card:** pink child edge, `⊗ BUG · CHILD OF #74` pill, `copilot · repo config`
  provenance, `⬡ $0.25–$0.85`. On the parent's card the link shows from the other side as
  `⚙ FIX 1 FILED BUG`.
- **Shots:** `14-B2-bug-77-filed-linked.png`, `15-B2-parent-74-shows-fix-1-filed-bug.png`
- **Copilot's measured usage for the filing legs:** `TOTAL records=2 … costUsd=0.57579
  premiumRequests=30` — copilot bills in **premium requests**, so 30 requests against the
  subscription and **no marginal dollars**; the USD figure is LCARS's notional conversion.

### 11:03:02 · step 6 · DRIVE THE BUG MISSION — on COPILOT, free

- **Did:** `run.sh drive --mission lcars-20260910-002-b52b` in B2.
- **LCARS did:** opened with a line that shows it understood the parentage —
  `⊘ base lcars/lcars-20260910-001-50e6 is a Mission branch — left exactly as it is
  (nothing fetched, nothing moved).` — then entered Research in **grounding mode**.
- **Engine in effect:** `copilot`. The card says so: `copilot · repo config`.
- **The card also carries a mode badge** the feature mission never showed:
  `grounding · scoped to existing code` — the S-series behaviour where a logged bug
  anchors itself to the code that already exists instead of building a parallel fix.

| time | stage | shot |
|---|---|---|
| 11:03:13 | research ▶ | `16-B2bug-stage-research.png` |

| 11:03:59 | validate ▶ | `17-B2bug-stage-validate.png` |
| 11:05:26 | plan ▶ | `18-B2bug-stage-plan.png` |
| 11:07:03 | plan-review ▶ | `19-B2bug-stage-plan-review.png` |
| 11:07:54 | schedule ▶ | `20-B2bug-stage-schedule.png` |
| 11:08:01 | implement ▶ | `21-B2bug-stage-implement.png` |
| 11:09:02 | verify | `22-B2bug-stage-verify.png` |

All seven of the bug's transitions were observed and photographed. Wall time
**6m00s** (11:03:02 → 11:09:02) — within seconds of the claude leg's 6m32s, on the free
engine.

- **The fix that landed** (`f362ee6`, on the PARENT's branch, `src/b_money.js` only):

  ```js
  const result = Math.sign(amount) * Math.round(cents) / 100;
  return result === 0 ? 0 : result;
  ```

  Suite green at **16 tests** (14 + 2 new zero-sign cases).
- **The verify readout is the interesting bit:**

  ```
  verify   ◇  bug fix folds onto parent lcars-20260910-001-50e6 — no per-bug PR (parent carries it)
  ⏹ stopped at: verify  (folds onto the parent — accept via the parent's re-verify gate)
  ```

  So there is **no second PR**. The whole shape of step 7 changes: you do not approve the
  bug, you accept it through the parent's consolidated gate.
- At this moment `f362ee6` was **local only** — `origin` was still at `dccdd18`, so PR #75
  did not yet carry the fix. That is correct (the push comes on the parent's verify pass,
  below), but it is worth knowing: between the child's verify stop and the parent's
  re-verify, the forge does not show the fix.
- **Copilot's measured usage for the bug, 7 spawns:** 455,777 in / 12,823 out,
  **105 premium requests**, notional $2.59946. No dollars billed.

### 11:10:19 · step 7a · `lcars resolve-logs` — one consolidated gate

- **Did:** `resolve-logs.sh lcars-20260910-001-50e6` (6 seconds).
- **LCARS did:**

  ```
  1 logged bug resolved to Verify and folded onto #74 …
  Raised ONE consolidated re-verify gate on lcars-20260910-001-50e6 and pinged you once.
  The fixes ride this Mission's PR — there is NO per-bug PR.
  ```

  The parent's card flipped to `● AWAITING YOU` with a single `ANSWER ▸` control.
- **Shot:** `23-B2-consolidated-reverify-gate.png`

### 11:10:46 · step 7b · the gate, answered (by me, so the captain was not interrupted)

- **The question, verbatim from `pending.json`:**
  *"1 logged bug resolved on lcars-20260910-001-50e6 … ready for your single re-verify.
  Re-inspect the fixes (they ride this Mission's PR — no per-bug PR), then ANSWER this
  gate to accept them (each logged bug is folded to Done) or send the Mission back."*
- **My answer, verbatim:** *"Accepted. I re-inspected the folded fix myself: commit
  f362ee6 changes only src/b_money.js, adding `return result === 0 ? 0 : result;` so a
  negative amount that rounds to zero now returns canonical +0. `Object.is(roundHalfUp(-0.001), 0)`
  is true and `assert.strictEqual` passes; every prior case (-0.005 => -0.01, -1.005 =>
  -1.01, 1.005 => 1.01, 2.675 => 2.68, TypeError guards) is unchanged. `npm test` green at
  16 tests. Both commits on this branch touch only `b_`-prefixed files, so the file fence
  held and this will not collide with the parallel mission. Ship it."*
- **LCARS did:** folded bug #77 to **Done**, resumed verify, and **pushed** — `origin` moved
  `dccdd18 → f362ee6`, so PR #75 now carries both commits.
- **Shot:** `24-B2-bug-77-done-parent-ready.png`

### 11:11:43 · step 7c · MERGE

- **Did:** `approve.sh --mission lcars-20260910-002-b52b` first (the brief's order), then
  the parent.
- **LCARS did (the bug):** refused, correctly and in one line —
  `lcars approve: mission is at stage 'done', not 'verify' — approve only ships a verified
  mission.` The bug was already Done, folded by the gate; there was never a PR to merge.
- **LCARS did (the parent):**

  ```
    worker: copilot (bin: env) model=- (model: unset)
  RECONCILE: ok — base 'main' not ahead of 'lcars/lcars-20260910-001-50e6'; proceeding
  APPROVE: merged — Add a half-up currency rounding helper at src/b_money.js
    Merged PR: https://github.com/roferg/lcars-mp-fixture/pull/75
    Branch:    lcars/lcars-20260910-001-50e6 → main
    Stage:     done
  ```

- **On `main` now:** `6c34830` (merge) over `f362ee6` + `dccdd18`. Two new files,
  `src/b_money.js` and `test/b_money.test.js`. **Nothing else changed** — the `b_` fence
  held end to end, across two missions, two engines and two laptops. `npm test` on `main`:
  **pass 16, fail 0**.
- **Shots:** `25-B2-both-done-merged.png`, `26-A2-after-merge-elsewhere.png`

---

## COST — measured, not estimated

Both figures come from LCARS's own per-spawn ledger
(`.git/lcars/missions/<id>/usage.json`, read with `run.sh usage --mission <id>`), which
records real token counts and a `source: "session-transcript"` per worker.

### The CLAUDE legs (billed) — mission `lcars-20260910-001-50e6`

| stage | role | model | in | out | cost |
|---|---|---|---|---|---|
| infra | context-pack | opus | 260 | 6,280 | **$0.65796** |
| (filing) | estimate | opus | 260 | 5,390 | **$0.594379** |
| research | research-questions | sonnet | 10 | 2,748 | **$0.244357** |
| validate | — | sonnet | 30 | 13,595 | **$0.555444** |
| plan | — | sonnet | 30 | 7,604 | **$0.69473** |
| planReview | — | sonnet | 24 | 7,157 | **$0.538302** |
| implement | TDD worker | opus | 322 | 8,754 | **$0.591345** |
| **TOTAL** | 7 spawns | | 936 | 51,528 | **$3.87652** |

**The billed total for this mission is $3.88.** (Cache reads/writes are recorded per
record too — e.g. 215,145 cache-read on the context pack — and are already priced into
those figures.)

Verify itself recorded **no** usage row, so the ledger's 7 spawns cover align→implement
only. That is either a stage that spawns no worker or a gap in the ledger; I did not
determine which, and I am not going to guess. Everything above is captured; verify is
**not captured**.

### The COPILOT legs (free) — bug `lcars-20260910-002-b52b`

| stage | in | out | premium requests | notional $ |
|---|---|---|---|---|
| infra | 38,295 | 1,597 | 15 | 0.2314 |
| (filing) | 60,023 | 1,771 | 15 | 0.34439 |
| research | 54,809 | 1,139 | 15 | 0.30252 |
| validate | 71,522 | 3,829 | 15 | 0.453335 |
| plan | 105,109 | 1,971 | 15 | 0.57482 |
| planReview | 50,778 | 965 | 15 | 0.278015 |
| implement | 75,241 | 1,551 | 15 | 0.41498 |
| **TOTAL** | 455,777 | 12,823 | **105** | 2.59946 |

Copilot's billing unit is the **premium request**: **105 requests** against the
subscription, **$0 marginal**. The USD column is LCARS's notional conversion, shown
because the board renders `⬢ ACTUAL ~$2.60` from it — useful for comparison, not a bill.

### Estimate vs actual

| | estimate | actual |
|---|---|---|
| mission #74 (claude) | $0.57–$3.11 | **$3.88** — 25% over the high end |
| bug #77 (copilot) | $0.25–$0.85 | **~$2.60 notional** — 3× the high end |

LCARS **reports this itself**: once actuals exist, the card grows a second pill,
`⬢ ACTUAL ~$3.88`, right beside `⬡ $0.57–$3.11`. It is not hiding the overrun. But the
estimator was low on both engines and by a wide margin on copilot, which matters because
the estimate is what a captain approves spend against.

---

## FINDINGS — things a captain should know

**1. `engineSource` provenance is destroyed by `approve`.** *(product defect)*
- Did: adopted #74 on B2 answering the engine prompt with `copilot`, then
  `approve.sh --mission …`.
- Expected: the card keeps saying **`copilot · chosen at adopt`** — the whole argument in
  `adopt.sh`'s header is that *how* the engine was decided is a fact worth recording.
- Saw: after the merge the card reads **`copilot · $LCARS_WORKER_BIN`**.
  `state.json.engineSource` went `adopt-chosen` → **`env`**. The approve pass exports the
  mission's `workerBin` into the environment and then re-persists the source as `env`,
  overwriting the human decision with a mechanical one. The engine value is still right;
  only the provenance is lost. (Approve's own readout shows the mechanism:
  `worker: copilot (bin: env)`.)

**2. The filing laptop goes stale after the mission ships from another laptop.** *(gap)*
- Did: filed and drove #74 on A2, adopted and merged it on B2, then re-read A2's board.
- Expected: A2 shows the mission Done, or at least stops offering an action on it.
- Saw: A2 still shows **`#74 · lcars:verify … ✓ REVIEW PR ▸`** with
  `state.json` at `stage: verify, review: open`. The local record beats the remote overlay
  (dedupe is by issue number, local wins), so the laptop that *filed* the mission is the
  one showing a stale card and offering to review an already-merged PR. Its own
  `⬢ ACTUAL ~$3.88` pill is also the only place the claude spend is visible — B2 has no
  idea what the first half cost, since `usage.json` never leaves the laptop that wrote it.
- Not investigated: whether a subsequent `lcars run` on A2 self-heals via the reconcile
  path (`reconcileStatus` exists on the card shape). Reported as observed, not as a verdict.

**3. `engine: null` in a logged bug's handoff envelope.** *(observation, probably correct)*
- Issue #77's envelope reads `"engine":null`, even though the bug is pinned to copilot
  locally (`engineResolved: copilot, engineSource: config`). Per `adopt.sh` that is the
  documented meaning of null — "the filing laptop made no explicit pin" — and the pin here
  came from repo config, not a flag. Consistent, but it means adopting #77 on a third
  laptop would re-decide the engine from that laptop's config rather than inherit copilot.

**4. Adopt says `chosen at adopt`, not `converted at adopt`.** *(not a defect — a wording
distinction worth knowing)* See step 4. `converted` is the `--engine <x>` flag path;
`chosen` is the answered-prompt path. Both switch the engine.

**Nothing else went wrong.** No stage escalated to an awaiting-human gate except the one
the design intends (the consolidated re-verify), no worker was rejected, no ticket needed
a second session, and the file fence was never breached on either engine.

---

## DISCIPLINE

- **Every Chrome invocation was `--headless=new`.** One long-lived headless Chrome
  (PID 30673, CDP port 9333) took all 26 shots. No headed browser was launched, no `open`
  was called, no window was focused. The captain's mouse was never touched.
- **Daemons I started (and the only PIDs I may kill):** `10499` (viewscreen, A2, :8790),
  `52993` (viewscreen, B2, :8791), plus Chrome `30673`.
  Left strictly alone: `54060`, `59527`, `59747` (S187), `77044` (:8765, mission A),
  `2225` (:8871), and every mission-A process.
- `tests/lcars-run.test.sh` and `tests/run.sh` were never run.
- **The LCARS product was not modified.** The only files written outside `/tmp/s196cap/`
  are this timeline and the shots beside it.
- `/tmp/s196cap/A1` and `/tmp/s196cap/B1` (mission A's) were never touched.

## SHOT MANIFEST

All in `tests/drives/s196-capstone/shots/missionB/`, 1400px wide, every one taken with `--headless=new`. Each `.png` has a sibling `.txt` recording the card text that was actually on screen when the shutter fired.

| shot | what it shows |
|---|---|
| `01-A2-filed-align.png` | A2, just filed on **claude**: card #74 in ALIGN with the ROFERG owner pill, the `$0.57-$3.11` cost pill, REASON LOW / IMPL MEDIUM, and `▶ START`. Mission A's #73 already visible beside it as a remote card. |
| `02-A2-stage-research.png` | RESEARCH. The provenance line `claude · mission pin` appears under the issue number; the card carries a live worker readout (`SENSORS SWEEPING THE CODEBASE… — WRITING OUTPUT`) and `⏸ PAUSE`. |
| `03-A2-stage-validate.png` | VALIDATE, the moment the card moved. |
| `04-B2-cold-remote-midflight.png` | B2, the cold clone, mid-flight: both missions drawn from GitHub alone as `◈ REMOTE · DRIVEN ELSEWHERE`. #74's control row is deliberately EMPTY — adopt is offered only at align and verify. |
| `05-A2-stage-plan.png` | PLAN, live readout `PLOTTING THE COURSE TO ENGINEERING… — THINKING`. |
| `06-A2-stage-plan-review.png` | PLAN REVIEW, `BRIDGE OFFICERS REVIEWING THE FLIGHT PLAN… — THINKING`. |
| `07-A2-stage-schedule.png` | SCHEDULE — one wave. |
| `08-A2-stage-implement.png` | IMPLEMENT — the Opus TDD worker running. |
| `09-A2-stage-verify.png` | VERIFY, the instant the card arrived. |
| `10-A2-verify-PR75-open.png` | VERIFY with PR #75 open and `✓ REVIEW PR ▸`. The card has grown a second cost pill: `⬢ ACTUAL ~$3.88` beside the `⬡ $0.57-$3.11` estimate. |
| `11-B2-remote-card-adopt-offered.png` | B2 with the mission at verify: #74 is `◈ REMOTE · DRIVEN ELSEWHERE` and its control row now offers exactly one thing — `◆ ADOPT ▸`. |
| `12-B2-adopt-prompt-terminal.png` | The adopt prompt itself, verbatim (the answer was piped, not typed at a tty, so `copilot` is not echoed after the colon — the readout that follows it is the proof it was taken): *"This mission was filed on claude; this repo's config.json prefers copilot. Both are installed here. / Which engine should drive this mission here? [claude] (claude copilot):"* — answered `copilot` — followed by the full adopt readout. |
| `13-B2-adopted-copilot-card.png` | The adopted card on B2: `copilot · chosen at adopt`, ROFERG owner pill, both estimate pills, `✓ REVIEW PR ▸`. |
| `14-B2-bug-77-filed-linked.png` | The bug, filed from B2 with `lcars log`: pink child edge, `⊗ BUG · CHILD OF #74`, `copilot · repo config`, `⬡ $0.25-$0.85`, `▶ START`. |
| `15-B2-parent-74-shows-fix-1-filed-bug.png` | The same link from the parent's side — #74's control row reads `⚙ FIX 1 FILED BUG`. |
| `16-B2bug-stage-research.png` | The bug at RESEARCH on copilot, carrying a badge the feature mission never had: `grounding · scoped to existing code`. |
| `17-B2bug-stage-validate.png` | Bug at VALIDATE. |
| `18-B2bug-stage-plan.png` | Bug at PLAN. |
| `19-B2bug-stage-plan-review.png` | Bug at PLAN REVIEW. |
| `20-B2bug-stage-schedule.png` | Bug at SCHEDULE. |
| `21-B2bug-stage-implement.png` | Bug at IMPLEMENT. |
| `22-B2bug-stage-verify.png` | Bug at VERIFY — with `⬢ ACTUAL ~$2.60` and no PR of its own. |
| `23-B2-consolidated-reverify-gate.png` | After `resolve-logs`: the parent flips to `● AWAITING YOU` with a single `ANSWER ▸`, one gate for the whole batch. |
| `24-B2-bug-77-done-parent-ready.png` | Gate answered — bug #77 folded to `lcars:done`; the parent back at verify with the fix now pushed onto PR #75. |
| `25-B2-both-done-merged.png` | Both DONE on B2 after the merge. Also the evidence for finding 1: #74's provenance now reads `copilot · $LCARS_WORKER_BIN`, no longer `chosen at adopt`. |
| `26-A2-after-merge-elsewhere.png` | Finding 2, photographed: A2 — the laptop that FILED the mission — still shows #74 at `lcars:verify` offering `✓ REVIEW PR ▸`, minutes after B2 merged it. |

---

## CLOSE-OUT (11:14)

- Fixture repo left as found: **issues #74 and #77 CLOSED**, **PR #75 MERGED**, nothing of
  mine left open. (#73, #78 and PR #76 are mission A's and are theirs to close.)
- `main` at `6c34830`; `npm test` on `main`: **pass 16, fail 0**.
- Daemons I started, all three killed by exact PID at close: **10499**, **52993**, **30673**.
  Confirmed still alive and untouched afterwards: 54060, 59527, 59747, 77044, 2225.

## SUMMARY

| | |
|---|---|
| mission | `lcars-20260910-001-50e6` · issue **#74** · branch `lcars/lcars-20260910-001-50e6` · PR **#75 (merged)** |
| bug | `lcars-20260910-002-b52b` · issue **#77** · rides the parent's branch · **no PR of its own** |
| engine, align→verify | **claude** (billed) — `claude · mission pin` |
| engine, adopt→merge | **copilot** (free) — `copilot · chosen at adopt` |
| billed spend | **$3.87652** measured (7 claude spawns) |
| free spend | **105 premium requests** (7 copilot spawns), $0 marginal |
| pipeline wall time | 6m32s (claude leg) + 6m00s (copilot leg) |
| shots | 26, all `--headless=new` |
| arc | **complete** — filed, driven, shown remote, adopted with an engine switch, bugged, re-driven, merged |
