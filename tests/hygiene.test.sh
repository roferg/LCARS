#!/usr/bin/env bash
# Public-source hygiene: scan only git ls-files paths, including unstaged edits.
# Usage: bash tests/hygiene.test.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PYTEST'
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

# Split deny-list values so the guard does not match its own source. GitHub as
# a platform name is legitimate; a personal company/employer field is not.
identity = re.compile(
    r"rogan" r"\s*ferguson\b|"
    r"https?://avatars\.githubusercontent\.com/u/" r"40493721\b|"
    r"\b(?:ro" r"ferg|rogan" r"[._+-]?ferguson)@[\w.-]+\.[a-z]{2,}\b|"
    r"\b(?:lcars-mp-" r"fixture|lcars-" r"sandbox|pages" r"ai)\b", re.I)
employer = re.compile(
    r"(?:company|employer)[\"']?\s*[:=]\s*[\"']?git" r"hub\b|"
    r"(?:works?|working|employed)\s+(?:at|by|for)\s+git" r"hub\b", re.I)
author = "rogan" + "ferguson"
home = re.compile(r"/(?:Users|home)/" + author + r"(?=$|[^\w.-])")
enterprise = "github" + ".ghe.com"
doc_suffixes = {".md", ".markdown", ".rst", ".txt", ".adoc", ".html", ".htm"}
rules = ("home-path", "personal-identity", "tracked-ds-store", "enterprise-doc-host")


def scan(repo):
    paths = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"],
        check=True, capture_output=True).stdout.split(b"\0")
    hits = {rule: [] for rule in rules}
    for raw in paths:
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = repo / name
        if path.name == ".DS_Store":
            hits["tracked-ds-store"].append(name)
        if path.is_symlink():
            text = os.readlink(path)
        else:
            # Missing/unreadable tracked files are errors, never a clean scan.
            text = path.read_bytes().decode("utf-8", errors="replace")
        prose = (path.suffix.lower() in doc_suffixes
                 or path.name.lower().startswith(("readme", "license", "copying")))
        for n, line in enumerate(text.splitlines(), 1):
            where = "%s:%d" % (name, n)
            if home.search(line):
                hits["home-path"].append(where)
            attribution = (name == "LICENSE"
                           and line == "Copyright (c) 2026 Rogan" + " Ferguson")
            if (identity.search(line) and not attribution) or employer.search(line):
                hits["personal-identity"].append(where)
            if prose and enterprise in line.lower():
                hits["enterprise-doc-host"].append(where)
    return hits


passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print("  PASS " + label)
    else:
        failed += 1
        print("  FAIL " + label)


print("hygiene: tracked public-source inventory")
hits = scan(Path("."))
for rule in rules:
    check(rule, not hits[rule])
    for where in hits[rule]:
        print("       " + where)

# Drive the SAME predicate red then green in a disposable git index. These
# controls run every time, so a disabled rule cannot pass on a clean checkout.
with tempfile.TemporaryDirectory(prefix=".hygiene-", dir=".") as tmp:
    repo = Path(tmp)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    samples = (
        ("home-path", "author macOS home", "probe.md", "/Users/" + author + "/project\n"),
        ("home-path", "author Linux home", "probe.md", "/home/" + author + "/project\n"),
        ("personal-identity", "author username", "probe.md", author + "\n"),
        ("personal-identity", "real name", "probe.md", "Rogan" + " Ferguson\n"),
        ("personal-identity", "employer field", "probe.md", '{"company":"Git' + 'Hub"}\n'),
        ("personal-identity", "employer prose", "probe.md", "Works at Git" + "Hub\n"),
        ("personal-identity", "personal email", "probe.md", "ro" + "ferg@github.com\n"),
        ("personal-identity", "real avatar", "probe.md",
         "https://avatars.githubusercontent.com/u/" + "40493721?v=4\n"),
        ("personal-identity", "private fixture repo", "probe.md", "lcars-mp-" + "fixture\n"),
        ("personal-identity", "private sandbox repo", "probe.md", "lcars-" + "sandbox\n"),
        ("personal-identity", "private employer repo", "probe.md", "pages" + "ai\n"),
        ("tracked-ds-store", "metadata", "nested/.DS_Store", "metadata\n"),
        ("enterprise-doc-host", "employer host", "probe.md", enterprise + "\n"),
    )
    for rule, label, name, text in samples:
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        subprocess.run(["git", "-C", str(repo), "add", "-f", "--", name], check=True)
        check("control RED " + rule + " (" + label + ")", bool(scan(repo)[rule]))
        subprocess.run(["git", "-C", str(repo), "rm", "-q", "-f", "--", name], check=True)
        check("control GREEN " + rule, not any(scan(repo).values()))

    (repo / "scratch.md").write_text(samples[0][3] + samples[2][3] + enterprise)
    (repo / ".DS_Store").write_text("untracked metadata")
    check("untracked scratch and metadata do not trip the guard", not any(scan(repo).values()))
    public = ("GitHub CLI supports enterprise hosts at enterprise.example.com.\n"
              "https://github.com/ro" + "ferg/lcars.git\n"
              "https://github.com/ro" + "ferg/lcars/security/advisories/new\n"
              "* @ro" + "ferg\n"
              "/home/me/binlink /Users/\u2026/Projects/LCARS/\u2026\n"
              "/Users/o'brien /Users/somebody-else\n"
              "/Users/stranger/project\n")
    (repo / "public.md").write_text(public)
    (repo / "runtime.sh").write_text("HOST=" + enterprise + "\n")
    subprocess.run(["git", "-C", str(repo), "add", "public.md", "runtime.sh"], check=True)
    check("platform documentation and runtime host capability remain valid", not any(scan(repo).values()))
    (repo / "LICENSE").write_text("Copyright (c) 2026 Rogan" + " Ferguson\n")
    subprocess.run(["git", "-C", str(repo), "add", "LICENSE"], check=True)
    check("public URLs, ownership, illustrative paths and license attribution remain valid",
          not any(scan(repo).values()))
    (repo / "public.md").write_text(samples[1][3])
    check("unstaged violations in tracked files are detected", bool(scan(repo)["home-path"]))
    (repo / "public.md").write_text("Clean public documentation.\n")
    check("removing an unstaged violation restores green", not any(scan(repo).values()))

root = Path(".").resolve()
with tempfile.TemporaryDirectory(prefix=".hygiene-portable-", dir=".") as tmp:
    work = Path(tmp).resolve()
    env = dict(os.environ)
    env.pop("LCARS_SRC", None)
    env.pop("FI_REPO", None)
    rig = root / "tests/lib/drive-rig.sh"
    cmd = ["bash", "-c", '. "$1"; printf "%s" "$LCARS_SRC"', "rig", str(rig)]
    got = subprocess.run(cmd, cwd=work, env=env, check=True, capture_output=True, text=True)
    check("drive rig defaults to this clone from another cwd", got.stdout == str(root))
    env["LCARS_SRC"] = str(work / "another clone")
    got = subprocess.run(cmd, cwd=work, env=env, check=True, capture_output=True, text=True)
    check("drive rig preserves LCARS_SRC overrides", got.stdout == env["LCARS_SRC"])

    brief = work / "brief with spaces.md"
    brief.write_text("## Open questions\n- Should the theme persist?\n")
    shim = root / "tests/lib/shims/align-heal-faultinj/copilot"
    env.update(FI_STATE=str(work / "counter"), FI_BRIEF=str(brief),
               FI_QUESTIONS="0", FI_DROP="0")
    got = subprocess.run(["bash", str(shim)], cwd=work, env=env,
                         check=True, capture_output=True, text=True)
    check("fault-injection shim defaults to this clone and quotes the brief",
          "STILL OPEN: Should the theme persist?" in json.loads(got.stdout)["prd"])
    other = work / "override clone"
    helper = other / "skills/lcars-init/lcars-common.sh"
    helper.parent.mkdir(parents=True)
    helper.write_text('lcars_concept_open_questions() { echo "Override question?"; }\n')
    env["FI_REPO"] = str(other)
    got = subprocess.run(["bash", str(shim)], cwd=work, env=env,
                         check=True, capture_output=True, text=True)
    check("fault-injection shim preserves and quotes FI_REPO overrides",
          "STILL OPEN: Override question?" in json.loads(got.stdout)["prd"])

print("\nhygiene: %d passed, %d failed" % (passed, failed))
raise SystemExit(1 if failed else 0)
PYTEST
