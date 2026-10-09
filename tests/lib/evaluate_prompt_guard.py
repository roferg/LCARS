#!/usr/bin/env python3
"""Check the Number One evaluate prompt's load-bearing contract."""

import sys


REQUIRED = (
    "# You are Number One — the first officer, at the Verify look",
    "## The contract was written BEFORE you looked",
    "## First, before you judge anything: how much does each one MATTER?",
    "## Then look: worked, didn't, or couldn't check",
    "## Write your reason down, one sentence per criterion",
    "## What you are looking at",
    "## `pairs.json` — what was DRAWN, beside what was BUILT",
    "## `observations.json` — things nobody's checklist says to look for",
    "## `tests.json` — the project's own tests, run for you",
    "## Say WHERE each judgement came from",
    "## Say WHICH KIND OF QUESTION each one is — as you judge it",
    "## No drawing at all",
    "## What you can reach that is not on a screen — and you choose it",
    "## Two decisions, one file",
    "## The rules that make this honest",
    "## The mission",
    "## The pictures taken AFTER your set-up steps",
    # S263 — THE HEADING CARRIES THE FRAME NOW. It read "## Something wrong that
    # NOBODY ASKED FOR — `volunteered`" until 2026-10-09. S262 measured a reviewer
    # that settled 54 of 65 rows itself and FILED NOTHING while the captain's
    # buddy filed three, two of them with no criterion at all. Permission was not
    # enough; the heading says it is EXPECTED OUTPUT, and that is load-bearing.
    "## Something wrong that NOBODY ASKED FOR — `volunteered`, and it is EXPECTED OUTPUT",
    # …and the second severed lane: `"cause"` was named NOWHERE in the assembled
    # prompt, so `xo-logs.py`'s product-cause filing rule had never once fired.
    '## WHOSE FAULT IT WAS WHEN YOU COULD NOT CHECK — `"cause"`, on every `untested` row',
    "## The live-check checklists — ADVICE YOU FOLLOW, not a schema anybody fills",
    "## Your input directory — the mission's RECORD, read-only",
    "## Your output file",
    "## IF YOU HAVE NO FILE-WRITING TOOL, SAY YOUR FILE INSTEAD",
    "## Where to write your output — READ THIS, IT IS NOT OPTIONAL",
    # S261 — THE CLAUSE THAT REPLACED THE REFUSAL. Until 2026-10-08 this entry
    # read "You have no shell, and you are not getting one". The captain amended
    # the S168 fence that day (19:33 MDT): the reviewer gets a real shell in a
    # DISPOSABLE COPY, because three of the six failures measured against his
    # buddy that morning were the fence and not the prompt. What has to survive
    # is the INSTRUCTION TO GO AND LOOK — a prompt that merely stops refusing is
    # the same form-filler with better manners.
    "Go and look. Run it yourself",
    "bad input",
    # …and the DECLARED-step path is still taught beside it. That path's own
    # fence (xo-run.py declared_escape / refuse_reason) is untouched.
    "DECLARE a step and have the harness run it",
    "xo-actions.json",
    "xo-verdict.json",
    "Two actors — two HOMEs, two laptops",
    "Re-verify after every fix round",
    "invent the values a human would",
    "a second user is a second home",
    "you decide when you have seen enough",
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: evaluate_prompt_guard.py <assembled-prompt>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        prompt = " ".join(handle.read().split()).casefold()
    missing = [
        item for item in REQUIRED
        if " ".join(item.split()).casefold() not in prompt
    ]
    if missing:
        for item in missing:
            print(f"missing required prompt contract: {item}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
