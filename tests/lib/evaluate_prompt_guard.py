#!/usr/bin/env python3
"""Check the Number One evaluate prompt's load-bearing contract."""

import sys


REQUIRED = (
    "# You are Number One — the first officer, at the Verify look",
    "## The contract was written BEFORE you looked",
    "## What you are looking at",
    "## What you can reach that is not on a screen — and you choose it",
    "## Two decisions, one file",
    "## The rules that make this honest",
    "You have no shell, and you are not getting one",
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
