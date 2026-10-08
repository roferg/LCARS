#!/usr/bin/env python3
"""Reject forbidden landing-rail cures in a unified diff."""

import re
import sys


GOVERNED = {
    "skills/lcars-xo/xo-journey.py",
    "skills/lcars-xo/xo-score.py",
    "skills/lcars-xo/xo-drive.js",
}
FORBIDDEN = (
    ("image hash or similarity", re.compile(
        r"md5|sha1|sha256|hashlib|createHash|similarity|pixelmatch|ssim", re.I)),
    ("navigation retry", re.compile(r"retr(?:y|ies|ying)", re.I)),
    ("prose pattern match", re.compile(r"re\.(?:search|match|findall|sub|compile)")),
    ("filename inference", re.compile(r"basename|splitext")),
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: landing_forbidden_cures.py <unified-diff>", file=sys.stderr)
        return 2
    current = ""
    violations = []
    with open(sys.argv[1], encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if line.startswith("+++ "):
                path = line[4:].strip()
                current = path[2:] if path.startswith("b/") else path
                continue
            if current not in GOVERNED or not line.startswith("+") or line.startswith("+++"):
                continue
            for label, pattern in FORBIDDEN:
                if pattern.search(line[1:]):
                    violations.append(f"{current}:{number}: {label}: {line[1:].rstrip()}")
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
