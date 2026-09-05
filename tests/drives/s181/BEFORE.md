# S181 — the measured "before", on unchanged main (`6e8a9c8`)

Live Copilot (`claude-opus-4.8`), Plan → Plan Review → Schedule, stopping before
Implement. Three fixtures, nine cold draws, 108 tickets.

## Verdict: mechanism (a), a linear `dependencies` chain authored on the FIRST pass

Not blanket `establishesSharedInfrastructure: true`, and not the S156 filename
heuristic.

| fixture | draws | chained | wide | infra `true` | `"reason"` keys |
|---|---|---|---|---|---|
| `prd-independent` (control — must stay wide) | 5 (incl. 1 post-objection revision) | 0 | 5 | 0/60 | 0 |
| `prd-builder` (**the reproduction**) | 3 | **2** | 1 | 0/36 | 0 |
| `prd-serial` (control — must stay serial) | 1 | 1 (correctly) | 0 | 0/12 | 0 |

**Mechanism (b) is dead.** Across 108 tickets on three very different briefs the
planner set `establishesSharedInfrastructure: true` **zero times** — it never once
defaulted the flag true, so a blanket of trues cannot be what happened on
2026-09-01. The one-look disambiguator agrees: every chained wave carries **no
`"reason"` key** and every readout reads `0 true, 12 false`, which is the chain
signature, not the infra signature. The filename heuristic stays ruled out by code:
`classify_infra_ticket` returns 1 on an explicit `false` without reading the prose,
and all 108 tickets declared the field.

**The ledger's §L3 premise was void.** It reported "every ticket's `dependsOn`
empty"; `dependsOn` appears zero times in `run.sh` and `stages/plan.md`. It was
reading a field LCARS has never had, so its "no declared dependencies" conclusion
carried no information either way.

## The defect is a LOTTERY, not a constant — 2/3 on an identical brief

Draw 202 refused both temptations on the same input that chained 201 and 203.
So an "after" drive proving one wide plan proves nothing: the after must run the
same multi-draw protocol and be read as a **rate**, not a pass/fail.

## Two distinct rationales — two different defects, both real

The planner writes down why it chained, and it is not the same reason twice.

**Draw 201 — narrative page order treated as a dependency:**
> *t-002:* "Depends on t-001 so the registry addition is additive and lands after
> the header, preserving top-to-bottom order."
> *t-012:* "Depends on t-011 so it appends last, completing the top-to-bottom fill-in."

**Draw 203 — file contention treated as a dependency:**
> *t-002:* "it depends on t-001 because both edit the shared sections array and
> stylesheet, which blind parallel siblings would clobber."
> *t-005:* "chained on t-004 for shared-file serialization."

**Draw 202, same brief, refused both:**
> "It is an independent vertical slice with its own mocked data module and does
> not depend on any other section."

`dependencies` is being overloaded as (i) an append/ordering mechanism and
(ii) a write-lock against concurrent edits to one file. Schedule reads it as
neither.

### Why the file-contention rationale is also wrong (resolved from the code, not by opinion)

It sounds legitimate under "serialize when unsure", but the harness **already
composes** this case. `replay_ticket_commit` cherry-picks each green ticket in
plan order; on a same-anchor conflict `rebuild_ticket_on_tip` rebuilds just that
ticket serially against the current tip, reusing its locked tests
(`run.sh:14590-14630`): *"Disjoint waves never conflict → stay fully concurrent;
a fully-overlapping wave degrades gracefully toward serial."*

So chaining for shared-file safety pays 12 waves of wall clock **up front** to buy
a guarantee the harness already provides, and provides only where a conflict
actually occurs. This does not weaken S156: that guarantee is about shared
*substrate* other tickets build ON TOP OF (where blindness silently breaks a
suite), not two additive edits to one file.

## Plan Review is not a backstop

It passed **both** chained plans on round 1, without comment, 3 for 3. Its prompt
gives it a criterion for the *coupling* direction (A requires changing behavior
B's tests pin) and none for the inverse — a dependency edge asserted with no
build-blocking justification. A cure that only hardens `plan.md` leaves the
reviewer blind; this is the evidence for routing a named soft signal to it.

## Asymmetry that explains the whole defect

`establishesSharedInfrastructure` gets a full section in `stages/plan.md` with
explicit "three cases people get wrong" rulings. `dependencies` got ONE sentence
(`plan.md:73-75`). The output mirrors the guidance exactly: **zero** spurious
infra flags across 108 tickets, and improvisation on the under-specified field.

## Rig (left standing for the after-drive)

- Pinned main worktree: `scratchpad/s181-main` @ `6e8a9c8`
- `scratchpad/fx-builder` @ `64e28de` — missions `lcars-20260904-201/-202/-203`
- `scratchpad/fx-independent` — missions `-001`…`-004`
- `scratchpad/fx-serial` — mission `-101`
- Logs: `scratchpad/schedule-builder-20{1,2,3}.log`

Implement was never entered on any mission.

## Inherited defects found while driving (ledgered, not cured here)

1. **The Copilot opus pin is not unconditional.** `resolve_stage_model` reaches
   `alias_for_tier` only via an `estimate.json` tier, a config `stages.<key>.model`,
   or a captain override. With none present it emits **no `--model` flag at all**
   (`STAGE-MODEL key=plan model=-`), so Copilot runs its default model — which
   strips the `create` tool under the LCARS fence and burns plan attempts that
   write no file. The S78 comment claims the pin holds "on EVERY stage regardless
   of the estimator's tier"; it is in fact conditional on a tier source existing.
   Latent for real missions, which do write `estimate.json`.
2. **`lcars init` reported `0 labels created, 16 already present` in a repo with
   no git remote at all** (`gh repo view` → "no git remotes found") — claiming a
   GitHub state it cannot have observed.
