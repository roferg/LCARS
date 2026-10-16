#!/usr/bin/env python3
"""skill_frontmatter.py — a STRICT, stdlib-only reader for SKILL.md frontmatter.

WHY THIS EXISTS (measured, 2026-10-11). `copilot skill list` loaded 11 of
LCARS's 19 skills and refused 8 of them:

    ✖ The following skills failed to load:
      • skills/lcars-eeh/SKILL.md: failed to parse YAML frontmatter:
        mapping values are not allowed in this context at line 2 column 244
      • skills/lcars-run/SKILL.md: Skill description must be at most 1024
        characters

Two independent causes, both invisible to Claude Code:

  1. COLON-SPACE. Every SKILL.md carried a one-line *unquoted*
     `description:` whose prose contained `": "` — "…the normal surfaces
     don't show: where…". A strict YAML reader sees a nested mapping key
     inside a scalar and refuses the document. Claude Code's parser
     tolerates it; Copilot's (a real YAML library) does not. The fix is the
     one the sibling repo's `cf-buddy` already proves in BOTH CLIs on this
     laptop: a `>-` block scalar, where the prose can never be re-read as
     structure.
  2. A 1024-CHARACTER CAP on the description value, which Copilot enforces
     and Claude Code does not.

WHAT THIS CHECKER IS, AND WHAT IT IS NOT. There is no PyYAML on this
machine, and vendoring one for a test would be worse than the bug. So this
is NOT a YAML parser and does not pretend to be. It is a deliberately
narrow reader for the ONE shape a SKILL.md frontmatter is allowed to take:
a flat mapping of `key: value` pairs at column 0, where `description` is
either a block scalar or a double-quoted scalar. Anything outside that
shape is REFUSED rather than interpreted — which is the safe direction for
a build gate, because a refusal is loud and a misparse is silent.

Specifically it does NOT understand, and refuses outright, any frontmatter
containing: anchors/aliases (`&a`, `*a`), tags (`!!str`), flow collections
(`{a: b}`, `[a, b]`), nested block mappings or sequences, explicit keys
(`? k`), multiple documents, or single-quoted scalars. None of the 19
skills needs any of them. If one ever does, this file has to grow a real
parser — and that is the point at which it should be replaced, not patched.

THE RULES, one per failure mode above plus the ones that keep the two CLIs
agreeing about which skill is which:

  R1  the file opens with `---` on line 1 and the frontmatter is closed by a
      later `---` line                              (shape)
  R2  every frontmatter line is either a `key:` at column 0 or a
      continuation of a block scalar                (shape)
  R3  `name:` is present and equals the SKILL.md's directory name — the
      name a user types is the directory they read  (discovery)
  R4  `description:` is present, and is EITHER a `>-`/`>`/`|` (optionally
      `-`/`+` chomped) block scalar OR a double-quoted scalar. A plain
      unquoted one-liner is refused whether or not it happens to contain
      `": "` today, because the next sentence someone adds to it is one
      colon away from breaking the build.           (cause 1)
  R5  the FOLDED description value is at most 1024 characters. Folded, not
      the source lines: a `>-` fold joins its lines with single spaces, so
      the length that matters is the one the CLI computes, not the one the
      file looks like.                              (cause 2)
  R6  no OTHER top-level key carries an unquoted `": "` inside its value —
      the same trap as R4, one key over.            (cause 1)

USAGE
    python3 tests/lib/skill_frontmatter.py <path>...       # dirs or SKILL.md
    python3 tests/lib/skill_frontmatter.py --json <path>...

Each argument may be a skill DIRECTORY (its SKILL.md is read) or a SKILL.md
file. Exit status is 0 when every path passed, 1 when any failed, 2 on a
usage error. Every violation prints as one `FAIL <path>: <rule> <detail>`
line so a shell suite can assert on the rule id.
"""

import json
import os
import re
import sys

MAX_DESCRIPTION = 1024

# A top-level key line: `key:` or `key: value`, no leading whitespace.
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*):(?:[ \t](.*))?$")
# A block-scalar header: `>`, `>-`, `>+`, `|`, `|-`, `|+`, optional explicit
# indentation indicator (`>2`), optional trailing comment.
BLOCK_RE = re.compile(r"^([|>])([1-9]?)([-+]?)(?:\s+#.*)?$|^([|>])([-+]?)([1-9]?)(?:\s+#.*)?$")
# Constructs this reader refuses rather than guesses at. These characters are
# YAML indicators only at the START of a node, which is why the test is on
# raw[0] and not a scan of the whole value: `*` and `!` appear mid-sentence in
# this repo's prose (markdown emphasis, exclamations) and are ordinary content
# there. An earlier spelling scanned the whole value and mis-refused
# lcars-adopt and lcars-viewscreen with the wrong rule id.
REFUSED_FIRST = set("&*!?{[%@`")


class Violation(Exception):
    def __init__(self, rule, detail):
        super().__init__(f"{rule} {detail}")
        self.rule = rule
        self.detail = detail


def fold_block(header, lines):
    """Fold a block scalar exactly as a YAML reader would.

    `lines` are the raw continuation lines, still carrying their indentation
    and with trailing blank lines included. `header` is the `>`/`|` style
    plus its chomping indicator.

    The three rules that actually matter for a description:
      * the block's indentation is set by its first non-empty line, and that
        much indentation is stripped from every line;
      * for `>` (folded), a single line break between two normally-indented
        non-empty lines becomes ONE SPACE, k consecutive breaks become k-1
        newlines, and a MORE-indented line is held literally (its breaks are
        never folded away);
      * chomping: `-` strips every trailing newline, `+` keeps them all, and
        the default clips to exactly one (or none, if the body is empty).
    """
    style = header[0]
    chomp = "-" if "-" in header else ("+" if "+" in header else "")

    indent = None
    for line in lines:
        if line.strip():
            indent = len(line) - len(line.lstrip(" "))
            break
    if indent is None:  # an empty block
        return "" if chomp == "-" else ("\n" * len(lines) if chomp == "+" else "")

    body = []
    for line in lines:
        if not line.strip():
            body.append("")
        else:
            body.append(line[indent:])

    # Split the trailing run of empty lines off; chomping owns it.
    tail = 0
    while body and body[-1] == "":
        body.pop()
        tail += 1

    if style == "|":
        out = "\n".join(body)
    else:
        def is_more(s):
            return s.startswith(" ") or s.startswith("\t")

        out = ""
        i = 0
        at_start = True
        while i < len(body):
            line = body[i]
            if line == "":
                # A run of k+1 breaks collapses to k newlines; the run's own
                # separator is consumed, so the following line joins with no
                # extra space.
                run = 0
                while i < len(body) and body[i] == "":
                    run += 1
                    i += 1
                if i < len(body):
                    out += "\n" * run
                    out += body[i]
                    i += 1
                continue
            if at_start:
                out += line
                at_start = False
                i += 1
                continue
            prev = body[i - 1]
            out += ("\n" if (is_more(line) or is_more(prev)) else " ") + line
            i += 1

    if chomp == "-":
        return out
    if chomp == "+":
        return out + "\n" * (tail + 1 if body else tail)
    return out + ("\n" if body else "")


def parse_frontmatter(text):
    """Return an ordered list of (key, value, kind) for the frontmatter.

    kind is "plain", "dquote", or "block". Raises Violation for any shape
    this reader refuses to interpret.
    """
    lines = text.split("\n")
    if not lines or lines[0].rstrip() != "---":
        raise Violation("R1", "no `---` on line 1 (no frontmatter)")
    end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            end = i
            break
    if end is None:
        raise Violation("R1", "frontmatter is never closed by a `---` line")

    out = []
    i = 1
    while i < end:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = KEY_RE.match(line)
        if not m:
            raise Violation(
                "R2", f"line {i + 1} is neither a top-level `key:` nor a block "
                      f"continuation: {line[:60]!r}")
        key = m.group(1)
        raw = (m.group(2) or "").rstrip()
        if BLOCK_RE.match(raw):
            cont = []
            i += 1
            while i < end:
                nxt = lines[i]
                if nxt.strip() and KEY_RE.match(nxt):
                    break
                cont.append(nxt)
                i += 1
            out.append((key, fold_block(raw, cont), "block"))
            continue
        if raw and (raw[0] in REFUSED_FIRST or raw.startswith("- ")):
            raise Violation(
                "R2", f"`{key}:` uses a YAML construct this reader refuses to "
                      f"guess at (anchor/alias/tag/flow): {raw[:40]!r}")
        if raw.startswith('"'):
            if not raw.endswith('"') or len(raw) < 2:
                raise Violation("R2", f"`{key}:` opens a double-quoted scalar "
                                      f"that does not close on the same line")
            try:
                out.append((key, json.loads(raw), "dquote"))
            except ValueError as exc:
                raise Violation("R2", f"`{key}:` is not a valid double-quoted "
                                      f"scalar ({exc})")
            i += 1
            continue
        if raw.startswith("'"):
            raise Violation("R2", f"`{key}:` is single-quoted; use `>-` or a "
                                  f"double-quoted scalar")
        out.append((key, raw, "plain"))
        i += 1
    return out


def check_skill(path):
    """Check one skill. Returns a list of `rule detail` strings (empty = pass)."""
    if os.path.isdir(path):
        skill_md = os.path.join(path, "SKILL.md")
        dirname = os.path.basename(os.path.abspath(path))
    else:
        skill_md = path
        dirname = os.path.basename(os.path.dirname(os.path.abspath(path)))

    if not os.path.isfile(skill_md):
        return ["R1 no SKILL.md at %s" % skill_md]

    with open(skill_md, encoding="utf-8") as fh:
        text = fh.read()

    try:
        pairs = parse_frontmatter(text)
    except Violation as exc:
        return ["%s %s" % (exc.rule, exc.detail)]

    problems = []
    keys = [k for k, _, _ in pairs]

    for k in set(keys):
        if keys.count(k) > 1:
            problems.append("R2 duplicate top-level key `%s:`" % k)

    if "name" not in keys:
        problems.append("R3 no `name:` key")
    else:
        name = [v for k, v, _ in pairs if k == "name"][0]
        if name != dirname:
            problems.append(
                "R3 name %r != directory name %r" % (name, dirname))

    if "description" not in keys:
        problems.append("R4 no `description:` key")
    else:
        _, value, kind = [p for p in pairs if p[0] == "description"][0]
        if kind == "plain":
            problems.append(
                "R4 description is a plain unquoted scalar; it must be a "
                "`>-`/`>`/`|` block scalar or a double-quoted scalar"
                + (" (and it contains \": \", which strict YAML reads as a "
                   "nested mapping)" if ": " in value else ""))
        if len(value) > MAX_DESCRIPTION:
            problems.append(
                "R5 folded description is %d characters, over the %d cap"
                % (len(value), MAX_DESCRIPTION))

    for k, v, kind in pairs:
        if k == "description":
            continue
        if kind == "plain" and ": " in v:
            problems.append(
                "R6 `%s:` is unquoted and its value contains \": \", which "
                "strict YAML reads as a nested mapping" % k)

    return problems


def describe(path):
    """Return {name, description, length} for a passing skill, for reporting."""
    skill_md = os.path.join(path, "SKILL.md") if os.path.isdir(path) else path
    with open(skill_md, encoding="utf-8") as fh:
        pairs = parse_frontmatter(fh.read())
    d = {k: v for k, v, _ in pairs}
    return {
        "path": skill_md,
        "name": d.get("name", ""),
        "description": d.get("description", ""),
        "length": len(d.get("description", "")),
    }


def main(argv):
    as_json = False
    paths = []
    for a in argv:
        if a == "--json":
            as_json = True
        elif a.startswith("-"):
            sys.stderr.write("skill_frontmatter: unknown option %s\n" % a)
            return 2
        else:
            paths.append(a)
    if not paths:
        sys.stderr.write(__doc__.split("USAGE")[1].strip() + "\n")
        return 2

    failed = 0
    report = []
    for p in paths:
        problems = check_skill(p)
        if problems:
            failed += 1
            for prob in problems:
                print("FAIL %s: %s" % (p, prob))
            report.append({"path": p, "ok": False, "problems": problems})
        else:
            info = describe(p)
            print("OK   %s: %s (description %d chars)"
                  % (p, info["name"], info["length"]))
            report.append({"path": p, "ok": True, **info})

    if as_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
