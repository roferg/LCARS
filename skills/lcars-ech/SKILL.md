---
name: lcars-ech
description: >-
  The Emergency Command Hologram — Hologram Command Mode, the token-free
  driver that runs the LCARS factory for the captain while he is away. This
  skill exists so `/lcars-ech` is invokable as a slash command; it adds no
  logic of its own. All of the behaviour lives in the `lcars-ech` launcher
  (the bundled `ech.sh`) and all of the rules live in the Hologram Command
  Mode playbook, which this file points at. Use when the captain says
  `lcars ech`, asks to run LCARS for him / drive the factory / keep going
  while he sleeps, asks what the ECH is doing or what it is waiting on, or
  wants to continue, answer or land an in-flight Hologram Command Mode run.
---

# lcars ech

`lcars-ech` is the **Emergency Command Hologram**: the token-free driver that
takes the loop itself. Number One works one Mission's gates; the ECH runs the
factory — file a milestone, drive it, wait on it, look at what came out, fix
what is wrong, land it, start the next one — and comes back to the captain only
for the four things that are genuinely his.

## This file adds nothing

It exists for ONE reason: so the mode is reachable as the slash command
`/lcars-ech` the same way every other LCARS surface is. There is no logic here.

- **The behaviour** is `ech.sh`, on PATH as `lcars-ech`.
- **The rules** are the Hologram Command Mode playbook.

Do not restate either of them here. A second copy of a rule is a rule that
drifts.

## Read the playbook first

Both documents resolve from whichever mount this skill was installed through,
so no literal path is written here:

```
lcars-eeh docs ech              # the Hologram Command Mode playbook
lcars-eeh docs orchestration    # the shared orchestration rules
```

`HOLOGRAM-COMMAND-MODE.md` is the playbook and **it wins over any restatement**,
including anything in this file. `ORCHESTRATION.md` owns the fix loop, the proof
surface and the hard stop at three rounds, and is shared with the EEH,
`run-session` and `night-watch` so the loop cannot drift between them.

## The verbs

Run `lcars-ech` with no subcommand for the usage line, and
`lcars-ech playbook` for the step index. The driver announces itself on
**stderr** when a human is at a terminal, and stays silent when its output is
being captured or parsed — so adding it to a script changes nothing a script
reads. `LCARS_ECH_QUIET=1` turns the announcement off entirely.
