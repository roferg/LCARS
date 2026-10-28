# The anchor rule — ONE source of the text (S237)

**This file is the only place the anchor rule's wording lives.** `file.sh`
writes it into a PRD's Constraints at Align; `run.sh` reads it into the
assembled Plan prompt. Neither spells it itself, because a divergence between
two copies of a rule is the defect this round exists to cure, one level up.

## Where the wording comes from

Not invented here. Over the weekend of 26–29 Sep 2026 a Plan Stage burned SIX
failed attempts across TWO missions and then stopped dead. The Plan prompt told
the worker its `drawnAt` was "your own words; there is no list of allowed
anchors", while `validate_plan_json` REQUIRES a real element id from the drawing
and, at the time, at least one `drawnAt` per visual ticket. The prompt said
"your own words", the validator said "a real id": that gap was the loop.

The cure that worked FIRST TIME, by hand, was the captain pasting the rule
verbatim — **with the actual list of anchors** — into the PRD's Constraints.
Both lines below are his, lifted byte-for-byte from the PRDs he filed that
weekend (`canvas-weekend-2026-09-26/evidence/filed-prds/`):

- the anchored form from `bug-m6-3.md` — the one that broke the loop
- the unfenced form from `prd-hublink.md` — a drawing with no element ids to
  cite, so there is no list to hand over

`@ANCHORS@` is substituted with the SAME list `validate_plan_json` checks
against (`mission_mockup_place_names`), comma-separated. Injecting the very
list the validator checks is the whole point — there is no second source of
anchors anywhere in the harness, and there must never be one.

S335 removes that ticket-level minimum: a genuinely all-undrawn ticket uses
`notDrawn` with a non-empty reason for every visible criterion, and `notVisual`
for genuinely non-visual criteria. Every criterion still declares exactly one;
every `drawnAt` still obeys membership, every `notDrawn` reaches Verify, and Plan
Review still audits false `notVisual` claims. The historical rule lines below
already allow all-undrawn tickets.

<!-- lcars:anchor-rule:anchored -->
PLAN RULE: every criterion of a screen-changing ticket carries drawnAt (@ANCHORS@) or notDrawn: "<reason>"
<!-- lcars:anchor-rule:end -->

<!-- lcars:anchor-rule:unfenced -->
PLAN RULE: each criterion of a screen-changing ticket carries drawnAt or notDrawn: "<reason>"
<!-- lcars:anchor-rule:end -->
