# S213 — DECLARED CLAIMS, frozen 2026-09-17 19:0x PT

Frozen by the ORCHESTRATOR from the session brief BEFORE any implementor or
tester ran. Per HANDOFF-number-one-close.md § *good enough*: good enough = every
one of these passes. Anything found that is NOT on this list is TRIAGED, not
automatically fixed — blocker and HIGH (it tells the captain something untrue, or
silently does not do what it claims) get fixed; medium/low are LEDGERED.

**These cannot be edited after testing starts.**

## GROUP A — the blocker
- **A1** With a context pack present, a Copilot worker STARTS — it does not die at
  argument parsing. (Premise verified live by the orchestrator before the session
  began: copilot 1.0.86 refuses a FILE to `--add-dir` — "Not a directory" — while a
  DIRECTORY gets past that parse. Control fired.)

## GROUP B — make the reviewer honest
- **B1** An evaluate action can PRESS A KEY. Pressing ArrowRight five times delivers
  five real key events to the page. (Today the entire vocabulary is navigate/click/
  type/wait/screenshot — there is no way to send a key at all.)
- **B2** A correctly-spaced toolbar, tab bar or tight list produces NO crowding
  complaint. **CONTROL: a genuinely crowded pair still does.**
- **B3** A HORIZONTAL New/Open pair is not reported as a 90px VERTICAL misalignment.
  **CONTROL: a genuinely misaligned row still is.**
- **B4** The test step runs the project's tests in a pnpm workspace without exit 127.
- **B5** No message ever reads "could not launch: the app is running". The wording
  that replaces it is not self-contradictory and is safe to show on a board card.
- **B6** `lcars xo off` halts a chain that is ALREADY RUNNING — without anyone
  killing a PID by hand.

## GROUP C — the surfaces (build the APPROVED mock-up; the design is SETTLED)
- **C1** A card with a long verdict renders ONE line plus a link — not the transcript.
- **C2** The tab LEADS with the verdict; `alsoChecked` is LAST and LABELLED.
- **C3** A criterion settled by TESTS shows a different evidence word from one settled
  by a PICTURE, and UNTESTED shows neither.
- **C4** Entries group under their mission, newest mission first.
- **C5** ✓ Seen moves ONE entry to history, decrements the count, and NEVER deletes.
- **C6** Clearing the last entry dims the mission and re-tags it.
- **C7** The default filter is Needs-you, and by-time is one tap away.
- **C8** NOTHING on any surface shows a verdict that contradicts the score. This is the
  regression test for the fault that made this session necessary.

## THE CAPTAIN'S RULINGS — decided 2026-09-17, not open to re-litigation
- **C9** A flush tab bar / segmented control is NOT a crowding fault (sibling buttons
  touching there are deliberate). Ships as a PERMANENT REGRESSION TEST beside a
  positive control that must still fire. *(This is B2's captain-facing half.)*
- **C10** Mission blocks are NOT collapsible. His reason: lifecycle steps already fold,
  and a collapsed block can hide a needs-you item.
- **C11** A needs-you item does NOT float out of its block — its MISSION sorts first,
  block intact. His reason: grouping stays pure and he sees the item AND its context.
