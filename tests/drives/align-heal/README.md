# The Align filing lane — recovery drives

> Two rigs. `heal-test.sh` FORCES the failure and proves the recovery
> deterministically; `matrix.sh` drives REAL copilot grills on both paths and
> measures how often a live worker still drops questions.

```bash
# deterministic — scripted worker, everything else real
bash tests/drives/align-heal/heal-test.sh heal-A 5 1   # drops 5, fixes itself -> FILES
bash tests/drives/align-heal/heal-test.sh heal-B 5 0   # never fixes -> caps, keeps draft, RESUMABLE

# live — one real copilot grill, driven to FILED
bash tests/drives/align-heal/matrix.sh run-1 holo      # the captain's 14-question brief
bash tests/drives/align-heal/matrix.sh run-1 plain     # a hand-typed idea, no attachments
LCARS_DRIVE_REPO=/path/to/worktree bash …              # run a DIFFERENT checkout (baselines)
```

## What happened (2026-08-29), and why both rigs exist

The captain's capstone died at filing: his PRD dropped 5 of the brief's 14 open
questions, `lcars file` refused (correctly), and the harness killed the filing,
DELETED the drafted PRD and left the card offering a fresh grill. Ten answered
questions, gone, with a defect he did not write and could not fix.

**The live rate is a LOTTERY.** Pristine holodeck runs against the same brief
dropped **5, 2, 1, 0, 0, 0, 0** questions — ~3 in 7 fail, and severity swings
wildly. Three runs a side cannot measure that, so a green matrix proves only
"nothing broke", never "the cure works". That is why `heal-test.sh` exists: it
scripts the WORKER (the thing already measured misbehaving) and leaves the
daemon, `file.sh`, the gate, the exit codes, the heal loop and the draft
handling REAL, so the recovery path is hit on demand instead of by chance.

## Two traps this rig was built around — do not remove these

1. **PIN EVERY SKILL TO THE DAEMON'S CHECKOUT.** The daemon resolves `file.sh`
   from `~/.claude/skills/`, a symlink to the MAIN checkout — so a "pristine"
   baseline silently ran the FIXED `file.sh`. Both rigs now export
   `LCARS_FILE_SCRIPT` / `LCARS_RUN_SCRIPT` / `LCARS_VERSION_CHECK_BIN`.
   Verify the pin bites before trusting a baseline (`grep -c die_prd`).
2. **`/api/align/start` takes `images`, NOT `attachments`.** An unknown key is
   silently ignored, so passing attachments there gives the gate no brief, no
   questions, and a PASS that means nothing. The holo cell reproduces the real
   lane instead: a PARKED mission with its attachments on disk, completed in
   place (`file.sh --complete`), which is exactly how the captain hit it.

The fault injector must also ASK a question or two before returning `done` — a
session with no `last_question` is not resumable for reasons that have nothing
to do with the code under test.

## Reading a result

`heals: N` on a filed mission is the cure working. On the plain (non-holodeck)
path it must always be **0**: a mission with no concept doc has no open-questions
gate to fail, so a heal there means the exit-code split is leaking. `prd-draft.md`
must be absent after a SUCCESS and present after an exhausted cap.
