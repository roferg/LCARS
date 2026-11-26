"""Read declared review policy; prose contracts require an explicit decision."""
import json
from pathlib import Path
import re
import sys


root, config = map(Path, sys.argv[1:])
try:
    policy = json.loads(config.read_text()) if config.exists() else {}
    reviewers = policy.get("prReviewers")
    if reviewers is None:
        contracts = [name for name in ("AGENTS.md", "CLAUDE.md")
                     if (root / name).is_file()]
        if contracts:
            raise ValueError("read %s and record prReviewers in .git/lcars/config.json "
                             "(an array of reviewer logins, e.g. [\"@copilot\"]; "
                             "[] only when no review is required)" % ", ".join(contracts))
        reviewers = []
    if not isinstance(reviewers, list) or any(
        not isinstance(value, str) or not re.fullmatch(r"@?[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?", value)
        for value in reviewers
    ):
        raise ValueError("prReviewers must be an array of reviewer logins")
    print("\n".join(dict.fromkeys(value if value == "@copilot" else value.removeprefix("@")
                                  for value in reviewers)))
except (OSError, ValueError) as error:
    sys.exit("PR review policy: %s" % error)
