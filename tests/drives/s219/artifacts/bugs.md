# S219 Phase C — the bugs Number One filed

**None.** Number One's first look ended at 05:10 PDT with **MEDIUM · checked 47 of 79 · core met**
and then journalled:

> `filed-logs` · filed: 0 · "no contradictions to file"
> ◈ NUMBER ONE: nothing on lcars-20260911-001-8cb0 contradicts what you wrote down — no logs filed.

Its verdict counts were: 47 worked, **0 gaps**, 32 could-not-check, 0 contradictions. The product files
mission logs only for gaps (something seen to fail); "could not check" items go on the report as known
issues, not as bugs. So by design there was **no fix round, no re-check, no before/after pair and no
second score.** `artifacts/xo-second/` does not exist for that reason. The mission sits at Verify,
PR #206 open (13 commits, untouched since it opened 04:42), Number One still ENGAGED.

## What Number One could not check (its escalations, verbatim)

1. "This build's data set has zero automatable KPIs — every one of the 19 KPIs is manual … three
   automation-dependent surfaces could not be seen at all: the amber refresh-all box (prd-5 / t-011),
   the wired 'Auto' value cells with Collect/Re-collect controls (prd-10 / t-008), and re-pull behaviour
   (prd-15). Deciding whether to accept these unverified, or to re-run Verify against a data set that
   includes at least one automated KPI, is the captain's call."
2. "The unlock-month dialog (t-012-ac5) was never captured in any shot, so its month-only shape and
   absence of a note field remain unverified."

## What the stand-in driver saw that Number One did NOT file (not filed by us either — for the captain)

### A. Four buttons render with giant icons and wrapped labels (visual-parity miss)
- **Where:** MBR start card 'Pull data & start'; collect step 'Continue to builder'; builder header
  'Lock month'; preview 'Back to builder'.
- **Mock-up:** small inline icon, one-line label (shots 52, 55).
- **Build:** icon drawn several times too big, spilling past the button; label broken over 2–3 lines.
  Visible in **Number One's own evidence pictures** (shots 53/54 = its mbr-start.png; 66 = its
  mbr-build.png; 67 = its mbr-collect.png; 68 = its preview.png) and in my own shots of the same build
  (47, 48, 49, 50).
- **How Number One graded it:** prd-1 'Reviews entry screen…' → "I saw the start card and Published row
  exactly as specified (evidence: mbr-start). Outcome: worked." Visual/flow parity with the mock-up
  (impact HIGH) → worked. Its layout observer (`observations.json`: 112 elements, 0 found) ran only on the
  round-0 Default-view shot (journal `observed` at 04:43, before rounds 1–3), never on the MBR pages.
- Before shot: 54 (Number One's own) · After shot: none (never filed, never fixed).

### B. 'Next up · August 2026' opens a September 2026 review
- Start card: "NEXT UP · August 2026" (shot 48/53). Collect and builder: "Pulling data · September 2026",
  "MBR builder · September 2026" (49, 47). The mock-up's start card also says August 2026 (its demo date).
  Not mentioned in the verdict. Possibly the start card's label, possibly by design (current month) —
  the captain's call.

### C. (LCARS display, not the app) raw markdown in 'Why this grade'
- The ◈ Number One tab prints `**Reviews entry screen**` etc. with the asterisks literally (shot 59/60).

---

# S219 Phase D — the bugs the captain's STAND-IN logged (05:17– PDT)

Who logged them: **the stand-in product owner** (one live Copilot turn, claude-opus-4.8, shown the drawing and
Number One's own shots; verbatim in `stand-in-decisions.md` → Phase D). Filed through the CLI `lcars log`
(the board's Log console was unusable — see D1), parent `lcars-20260911-001-8cb0` (#192), one call, per-bug shots
attached. PRDs: `artifacts/phase-d-logs/bug-{1..4}.md`.

| # | Issue | Child mission | Bug (stand-in's title) | Before shots | Fixed? | After shots |
|---|---|---|---|---|---|---|
| 1 | #207 | lcars-20260919-001-8cb0 | Primary action buttons render with oversized icons and labels wrapped onto 2–3 lines (Pull data & start, Continue to builder, Lock month, Back to builder) | 54, 67, 66, 68 (Number One's own); 48, 49, 47, 50 (mine) | YES (f879337) | 121, 122, 123, 124 (113, 115, 117, 120) |
| 2 | #208 | lcars-20260919-002-8cb0 | Draft banner shows "Last edited —" instead of the last autosave time | 73 | YES (3f564ab) | 125 (118) |
| 3 | #209 | lcars-20260919-003-8cb0 | "Next up · August 2026" opens a September 2026 review (stand-in ruled: YES, a bug) | 54, 49 | PARTLY at first (dccc1e9: builder + saved draft August; collect step still September) → YES after #211 | 126 → 139 |
| 4 | #210 | lcars-20260919-004-8cb0 | Builder header "Preview" button is missing its eye icon | 73 | YES — no own commit; #207's sizing made the existing EyeIcon visible | 123 (117) |
| 5 | #211 | lcars-20260919-005-8cb0 | Data-pull (collect) step still shows September 2026 after pulling the August review — logged by the stand-in at the re-verify gate (turn D2), 06:23 | 126 | YES (d89be5a) | 139 (137, 138) |

## LCARS defects found in Phase D (the harness, not the app)

- **D1 — `lcars xo off <mission>` corrupts state.json when Number One's headline contains a `}`/`{`.**
  At 05:21 the stand-down rewrote the parent's `numberOne` line as invalid JSON:
  `…A successfulcollect renders a 'was {old, "status": "stood-down", …}` — the rest of the headline, its
  closing quote and every field after it (evaluatedAt, etc.) were lost. Root cause: `state_xo_block` in
  `skills/lcars-xo/xo.sh` reads the object with `{[^}]*}` (stops at the FIRST `}`), and `lcars_json1_*`
  (`skills/lcars-init/lcars-state.sh`) say in their own comment they are wrong "the moment a value could contain
  a `{`, a `}` or a quote" — but `numberOne.headline` is model-written prose (here it quoted an AC containing
  `{old, new}`). Consequence on the captain's surface: the board's python reader drops the LOCAL mission;
  #192 reappears only as a REMOTE "driven elsewhere" card with ADOPT, a placeholder PRD, no actual cost, and a
  **disabled Mission Log** (shots 71, 72, 74, 75). Not repaired (no hand edits).
- **D2 — `lcars log` from the CLI does not inherit the parent's engine.** The parent is a copilot mission
  (`workerBin: copilot`), but `log.sh` only threads `$LCARS_WORKER_BIN` (the daemon sets it; a CLI captain does
  not). Inside a Claude Code session (CLAUDECODE=1) the per-child estimator host-detected **claude** — four
  claude estimate turns ≈ $2.48 — and the board labels the children "claude · host CLI" (shot 76). Partly my
  own miss (I had not exported LCARS_WORKER_BIN); the resolve run was then started with it set, and #207 shows
  "copilot · LCARS re-pin".
- **D3 (small) — resolve-logs.md cuts titles at a double quote** ("Draft banner shows \", "— \") — the order
  worker's output keeps the escaped quote and drops the rest.
- **Observation — Number One re-engages on the children.** Standing Number One down on the PARENT does not
  stop it engaging on the parent's new log children (repo-level ON): #207's card reads "Number One has the conn"
  (shot 78).

**Outcome (06:38):** the stand-in accepted the single re-verify gate (turn D3); LCARS folded all five logs to Done
(issues #207–#211 CLOSED) and pushed the fixes onto PR #206 (head d89be5a, 17 commits). PR still OPEN — not approved, not merged.
- **D4 (small) — finished children keep "Number One has the conn".** After the fold, every Done child card still
  shows '◈ NUMBER ONE · ENGAGED' + a STAND DOWN button (shot 140).
- **D5 (small) — `lcars launch` and `lcars answer` are not routed by `lcars.sh`** ("no active mission matches
  \"launch\"/\"answer\""); I called `skills/lcars-launch/launch.sh` and `skills/lcars-answer/answer.sh` directly.

## The second score (Number One, 06:40–07:02)

| | First look (04:42–05:10) | Second look (06:40–07:02) |
|---|---|---|
| Grade | **MEDIUM** (worker MEDIUM = ledger) | **LOW** (worker MEDIUM, **ledger overruled → LOW**) |
| Checked | 47 of 79 · core **met** | 40 of 79 · core **unverified** |
| Counts | 47 met / 0 gap / 32 untested / 0 contradictions | 40 met / 0 gap / 39 untested / 0 contradictions |
| Label | lcars:xo:medium | lcars:xo:low |
| Logs filed | 0 | 0 |
| Importance | recorded (22 high / 43 medium / 14 low) | **reused** — impacts.json unchanged (sha ac32cc614bdc), 20 impact-kept lines |
| Spend | $10.87 | $11.96 |

What moved it: not the fixes. The second look did not reach the locked month (3 insights blank, lock correctly
blocked), so t-012-ac3 (high impact, "Locking sets lockedBy to null and renders every bucket read-only") went
met → untested, and the ledger refuses to vouch for a mission whose point it could not see. Nothing it checked
failed. Does it now see the buttons correctly? Its own shots show them fixed (141–144), but neither look's words
ever mention icon size or label wrapping — it graded the broken buttons "met" and the fixed ones "met". Its layout
observer again ran only on the round-0 Default-view shot (`observed count 0`).

Also seen in its own second-look evidence (not filed by anyone): reaching the builder by URL (#mbr/build) before
pulling still opens a **September 2026** draft (shot 142) while the start card and collect step say August.
