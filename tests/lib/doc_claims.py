"""Conservative, offline resolution of concrete tokens, not prose semantics.

Only explicit shell dispatch/parsing, recognisable environment reads and simple
quoted I/O paths count as resolved. Dynamic skill front doors, scratch paths and
unsupported syntax are unchecked, never counted as passes. The only code run is
eeh.sh's read-only docs resolver. No instruction extracted from prose is run.
"""

import argparse
import difflib
import os
import re
import subprocess
from collections import Counter
from functools import lru_cache
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCUMENTS = (
    "HOLOGRAM-COMMAND-MODE.md", "DELEGATION.md", "ORCHESTRATION.md",
    "delegate-brief.md",
)
MINIMUM_RESOLVED = {
    "HOLOGRAM-COMMAND-MODE.md": 40,
    "DELEGATION.md": 20,
    "ORCHESTRATION.md": 7,
    "delegate-brief.md": 6,
}
COMMAND = re.compile(
    r"(?<![\w/-])(lcars-ech|lcars-eeh|lcars)\s+"
    r"([a-z][a-z0-9-]*|<[^>\n]+>|\{\{[^}\n]+\}\})"
)
COMMAND_NAME = re.compile(r"(?<![\w/-])(?:lcars-ech|lcars-eeh|lcars)(?![\w/-])")
FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
ENV = re.compile(r"\bLCARS_[A-Z0-9_]+\b")
SHELL_ENV_READ = re.compile(r"(?<!\\)\$(?:\{)?(LCARS_[A-Z0-9_]+)\b")
PATH = re.compile(r"(?<![\w-])(?:\.git/lcars|skills)/[A-Za-z0-9_./{}<>,*+$-]*")


def shell_code(text):
    """Keep line positions, excluding comments and here-doc bodies (not code)."""
    out = []
    pending = []
    for line in text.splitlines(keepends=True):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            out.append("\n")
        elif line.lstrip().startswith("#"):
            out.append("\n")
        else:
            pending.extend(re.findall(r"(?<!<)<<-?\s*['\"]?([A-Za-z_]\w*)", line))
            out.append(line)
    return "".join(out)


def function_body(code, name):
    match = re.search(rf"^{re.escape(name)}\(\)\s*\{{", code, re.M)
    if not match:
        return ""
    end = re.search(r"^}", code[match.end():], re.M)
    return code[match.end():match.end() + end.start()] if end else ""


@lru_cache(maxsize=None)
def source(relative):
    return shell_code((ROOT / relative).read_text())


@lru_cache(maxsize=1)
def code_files():
    return tuple(
        (path, path.read_text())
        for path in sorted((ROOT / "skills").rglob("*"))
        if path.suffix in {".sh", ".py", ".js", ".ts", ".mjs", ".cjs"}
    )


@lru_cache(maxsize=1)
def environment_reads():
    reads = {}
    other_read = re.compile(
        r"(?:os\.(?:getenv|environ\.get)\(\s*|os\.environ\[\s*)"
        r"""['"](LCARS_[A-Z0-9_]+)['"]"""
        r"|\bprocess\.env\.(LCARS_[A-Z0-9_]+)\b"
    )
    for path, text in code_files():
        code = shell_code(text) if path.suffix == ".sh" else text
        for pattern, content in ((SHELL_ENV_READ, code if path.suffix == ".sh" else ""),
                                 (other_read, text)):
            for match in pattern.finditer(content):
                name = next(group for group in match.groups() if group)
                line = content.count("\n", 0, match.start()) + 1
                reads.setdefault(name, f"{path.relative_to(ROOT)}:{line}")
    return reads


@lru_cache(maxsize=1)
def path_references():
    references = {}
    literals = []
    assignment = re.compile(r'\b([A-Za-z_]\w*)="([^"\n]*)"')
    variable = re.compile(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)")
    io = re.compile(r"(?:\[\s*-[defrsw]\b|\b(?:cat|mkdir|cp|mv|touch|source|bash)\s|>>?)")
    for path, text in (*code_files(), (ROOT / "install.sh", (ROOT / "install.sh").read_text())):
        if path.suffix != ".sh":
            continue
        code = shell_code(text)
        literals.append(code)
        assignments = {}
        for match in assignment.finditer(code):
            assignments.setdefault(match[1], set()).add(match[2])
        known = {
            "GIT_DIR": ".git", "GITDIR": ".git", "CWD": "", "REPO_ROOT": "",
            "SKILLS_DIR": "skills", "SELF_DIR": str(path.parent.relative_to(ROOT)),
            "SKILL_DIR": str(path.parent.relative_to(ROOT)),
            "SCRIPT_DIR": str(path.parent.relative_to(ROOT)),
        }

        def expand(value, seen=()):
            def replace(match):
                name = match[1] or match[2]
                if name in known:
                    return known[name]
                choices = assignments.get(name, set())
                if name in seen or len(choices) != 1:
                    return "<dynamic>"
                return expand(next(iter(choices)), seen + (name,))
            return variable.sub(replace, value)

        for number, line in enumerate(code.splitlines(), 1):
            if not io.search(line):
                continue
            for quoted in re.finditer(r'"([^"\n]+)"', line):
                value = expand(quoted[1]).lstrip("/")
                if (value.startswith((".git/lcars", "skills/"))
                        and not re.search(r"[<>${}*;\s]", value)):
                    references.setdefault(value.rstrip("/"), f"{path.relative_to(ROOT)}:{number}")
    return references, "\n".join(literals)


def resolve_path(claim):
    value = claim.rstrip(".,/")
    references, literals = path_references()
    if value in references:
        return "PASS", references[value]
    if re.search(r"[<>{}*$]", value) or value in {"skills", ".git/lcars"}:
        return "UNCHECKED", "parameterised path or directory root; exact I/O is not proved"
    if value.startswith((".git/lcars/tmp/", ".git/lcars/autopilot/")):
        return "UNCHECKED", "caller-authored scratch/evidence; not a fixed code-owned path"
    if value.startswith("skills/") and not (ROOT / value).exists():
        return "FAIL", f"no code I/O reference: source path does not exist: {value}"
    leaf = value.rsplit("/", 1)[-1]
    if leaf in literals:
        return "UNCHECKED", "code names this leaf, but exact path I/O is not resolved"
    return "FAIL", ("no code I/O reference; resolved code paths include "
                    + ", ".join(sorted(references)[:8]))


def command_end(text, match):
    end = text.find("\n", match.end())
    end = len(text) if end < 0 else end
    while text[match.end():end].rstrip().endswith("\\"):
        following = text.find("\n", end + 1)
        end = len(text) if following < 0 else following
    # Inline code may wrap over a newline.
    start = text.rfind("\n", 0, match.start()) + 1
    if text[start:match.start()].count("`") % 2:
        tick = text.find("`", match.end())
        if tick >= 0:
            end = tick
    tail = text[match.end():end]
    boundary = re.search(r"`|[;#]|&&|\blcars(?:-ech|-eeh)?\s", tail)
    return match.end() + boundary.start() if boundary else end


def flags_for(command, verb, tail):
    if command == "lcars-eeh" and verb == "docs":
        code = source("skills/lcars-eeh/eeh.sh")
        arm = re.search(r'in (--path\|-p\)[^\n]*?)esac', code)
        return set(FLAG.findall(arm[1])) if arm else set()
    if command != "lcars-ech" or verb == "exec":
        return None
    if verb == "usage":
        return None
    code = source("skills/lcars-eeh/ech.sh")
    name = "cmd_" + verb.replace("-", "_")
    subcommand = re.match(r"\s+(done|close)\b", tail)
    if subcommand and verb in {"live-check", "delegate"}:
        name += "_" + subcommand[1]
    body = function_body(code, name)
    if not body:
        return None
    flags = set()
    for arm in re.finditer(r"^\s*((?:--[\w-]+(?:=\*)?\|?)+)\)", body, re.M):
        flags.update(FLAG.findall(arm[1]))
    flags.update(re.findall(
        r'\[\s*"\$\{?1(?::-[^}]*)?\}?"\s*=\s*["\']?(--[\w-]+)', body
    ))
    return flags


@lru_cache(maxsize=None)
def resolve_doc(name):
    if "docs" not in dispatches()["lcars-eeh"]:
        return 1, "eeh.sh has no docs dispatch; resolver was not invoked"
    result = subprocess.run(
        ["bash", str(ROOT / "skills/lcars-eeh/eeh.sh"), "docs", name],
        capture_output=True, text=True, timeout=3, cwd=ROOT,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent"},
    )
    return result.returncode, " ".join(result.stderr.split())


def dispatches():
    ech = source("skills/lcars-eeh/ech.sh")
    eeh = source("skills/lcars-eeh/eeh.sh")
    router = source("skills/lcars/lcars.sh")
    dispatch = re.search(r'^case "\$SUB" in\n(.*?)^esac', ech, re.M | re.S)
    ech_verbs = set()
    if dispatch:
        for arm in re.finditer(r"^\s+(\S+)\)\s+(?:cmd_\w+|usage)\b", dispatch[1], re.M):
            ech_verbs.update(v for v in arm[1].split("|") if re.fullmatch(r"[a-z][\w-]*", v))
    early = r'^if \[ "\$\{1:-\}" = "?([a-z][\w-]*)"? \]; then'
    return {
        "lcars-ech": ech_verbs | set(re.findall(early, ech, re.M)),
        "lcars-eeh": set(re.findall(early, eeh, re.M)),
        "lcars": set(re.findall(r"^\s+([a-z][\w-]*)\)\s+shift",
                               router.split("esac", 1)[0], re.M)),
    }


def check(docs_dir):
    dispatch = dispatches()
    skills = {p.name[6:] for p in (ROOT / "skills").glob("lcars-*")
              if (p / "SKILL.md").is_file()}
    reads = environment_reads()
    totals = Counter()
    kinds = Counter()
    all_checked_lines = 0
    all_lines = 0
    minimum_failures = 0
    for name in DOCUMENTS:
        path = docs_dir / name
        if not path.is_file():
            print(f"FAIL {path}:1: minimum resolved claims: "
                  f"expected >= {MINIMUM_RESOLVED[name]}, got 0; document is missing")
            minimum_failures += 1
            continue
        text = path.read_text()
        counts = Counter()
        resolved = set()
        checked_lines = set()

        def record(status, offset, kind, claim, actual):
            line = text.count("\n", 0, offset) + 1
            counts[status] += 1
            kinds[kind, status] += 1
            if status != "UNCHECKED":
                checked_lines.add(line)
            if status == "PASS":
                resolved.add((kind, claim))
            else:
                print(f"{status} {path}:{line}: {claim!r}: {actual}")

        for match in ENV.finditer(text):
            if match[0] not in reads:
                installer = source("install.sh")
                installer_read = next(
                    (read for read in SHELL_ENV_READ.finditer(installer) if read[1] == match[0]),
                    None,
                )
                if installer_read:
                    number = installer.count("\n", 0, installer_read.start()) + 1
                    record("UNCHECKED", match.start(), "env", match[0],
                           f"installer-only read at install.sh:{number}; outside skills/ scope")
                    continue
            nearby = ", ".join(difflib.get_close_matches(match[0], reads, n=3))
            record("PASS" if match[0] in reads else "FAIL", match.start(), "env", match[0],
                   reads.get(match[0], "no environment read under skills/; "
                             f"nearest code reads: {nearby or '(none)'}"))

        for match in PATH.finditer(text):
            status, actual = resolve_path(match[0])
            record(status, match.start(), "path", match[0], actual)

        claimed_flags = set()
        claimed_commands = set()
        for match in COMMAND.finditer(text):
            claimed_commands.add(match.start())
            command, verb = match.groups()
            claim = f"{command} {verb}"
            if verb in dispatch[command]:
                record("PASS", match.start(), "verb", claim, "explicit shell dispatch")
            elif verb.startswith(("<", "{{")) or (command == "lcars" and verb in skills):
                record("UNCHECKED", match.start(), "verb", claim,
                       "skill/prose routing, not an explicit shell dispatch")
            else:
                record("FAIL", match.start(), "verb", claim,
                       f"dispatch has {', '.join(sorted(dispatch[command]))}"
                       + (f"; skill front doors: {', '.join(sorted(skills))}"
                          if command == "lcars" else ""))
            tail = text[match.end():command_end(text, match)]
            if command == "lcars-eeh" and verb == "docs":
                pointer = re.match(r"\s+(?:--path\s+)?([a-zA-Z][\w.-]*)", tail)
                if pointer:
                    status, actual = resolve_doc(pointer[1])
                    record("PASS" if status == 0 else "FAIL", match.start(), "docs",
                           "docs " + pointer[1], f"resolver exited {status}: {actual}")
                else:
                    record("UNCHECKED", match.start(), "docs", claim,
                           "document name is missing or parameterised")
            accepted = flags_for(command, verb, tail) if verb in dispatch[command] else None
            for flag in FLAG.finditer(tail):
                offset = match.end() + flag.start()
                claimed_flags.add(offset)
                status = ("UNCHECKED" if accepted is None else
                          "PASS" if flag[0] in accepted else "FAIL")
                record(status, offset, "flag", claim + " " + flag[0],
                       "delegated or parameterised parser is not resolved" if accepted is None
                       else f"{verb} parser accepts {', '.join(sorted(accepted)) or '(no flags)'}")
        for match in COMMAND_NAME.finditer(text):
            if match.start() not in claimed_commands:
                record("UNCHECKED", match.start(), "verb", match[0],
                       "no concrete verb; bare command or computed argument")
        for match in FLAG.finditer(text):
            if match.start() not in claimed_flags:
                record("UNCHECKED", match.start(), "flag", match[0],
                       "no unambiguous owning command")
        for match in re.finditer(r"(?<!`)`([^`]+)`(?!`)", text):
            pointer = re.fullmatch(r"docs\s+(?:--path\s+)?([a-zA-Z][\w.-]*|<[^>]+>)",
                                   match[1].strip())
            if not pointer:
                continue
            if pointer[1].startswith("<"):
                record("UNCHECKED", match.start(), "docs", pointer[0],
                       "document name is parameterised")
            else:
                status, actual = resolve_doc(pointer[1])
                record("PASS" if status == 0 else "FAIL", match.start(), "docs",
                       pointer[0], f"resolver exited {status}: {actual}")

        checked = counts["PASS"] + counts["FAIL"]
        if len(resolved) < MINIMUM_RESOLVED[name]:
            print(f"FAIL {path}:1: minimum resolved claims: "
                  f"expected >= {MINIMUM_RESOLVED[name]}, got {len(resolved)} distinct")
            minimum_failures += 1
        print(f"COVERAGE {name}: checked={checked} skipped={counts['UNCHECKED']} "
              f"failed={counts['FAIL']} resolved-distinct={len(resolved)} "
              f"minimum={MINIMUM_RESOLVED[name]}")
        totals.update(counts)
        all_checked_lines += len(checked_lines)
        all_lines += len(text.splitlines())
    checked = totals["PASS"] + totals["FAIL"]
    skipped = totals["UNCHECKED"]
    fraction = checked / (checked + skipped) if checked + skipped else 0
    print(f"COVERAGE TOTAL: checked={checked} skipped={skipped} "
          f"candidates={checked + skipped} ({fraction:.1%}); "
          f"failed={totals['FAIL']}; minimum-failures={minimum_failures}; "
          f"lines-with-checks={all_checked_lines}/{all_lines}")
    for kind in sorted({kind for kind, _ in kinds}):
        print(f"KIND {kind}: checked={kinds[kind, 'PASS'] + kinds[kind, 'FAIL']} "
              f"skipped={kinds[kind, 'UNCHECKED']} failed={kinds[kind, 'FAIL']}")
    print("SCOPE: token existence/recognition only; other prose and runtime semantics "
          "are not verified. Failed resolutions count as checked, not resolved.")
    return 1 if totals["FAIL"] or minimum_failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs-dir", type=Path, default=ROOT / "skills/lcars-eeh")
    args = parser.parse_args()
    return check(args.docs_dir)


if __name__ == "__main__":
    raise SystemExit(main())
