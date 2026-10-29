#!/usr/bin/env python3
"""Read explicit declarations and runner-owned failure locations, never source."""
import json
import os
from pathlib import Path
import re
import sys


def declarations(result):
    with open(result) as f:
        return [e for e in json.load(f).get("testEdits", [])
                if isinstance(e, dict) and e.get("kind") == "stored-output"
                and isinstance(e.get("path"), str) and e["path"]
                and isinstance(e.get("reason"), str) and e["reason"].strip()]


def failure_locations(stack, text):
    if stack in ("py", "python"):
        if not re.search(r"^Ran \d+ tests? in ", text, re.M):
            return None, "only unittest/doctest output is supported; pytest/custom Python output is not checked"
        blocks = re.findall(r"^(?:FAIL|ERROR): .*?(?=^={10,}|\Z)", text, re.M | re.S)
        return [p for block in blocks for p in re.findall(r'^\s*File "([^"]+)", line \d+', block, re.M)], "unittest/doctest failure traceback locations"
    if stack == "js":
        if not re.search(r"^Test Suites:", text, re.M):
            return None, "only Jest text output is supported; other JS runners/reporters are not checked"
        paths = re.findall(r"^\s*FAIL\s+(.+?)(?:\s+\([\d.]+\s*s\))?\s*$", text, re.M)
        for block in re.findall(r"^\s*FAIL\s+.*?(?=^\s*(?:PASS|FAIL|Test Suites:)|\Z)", text, re.M | re.S):
            paths.extend(re.findall(r"^\s+at .*?\(?([^()\s]+):\d+:\d+\)?\s*$", block, re.M))
        return paths, "Jest FAIL suite headers and failure stack locations"
    if stack == "go":
        if not re.search(r"^(?:ok\s|FAIL\s|FAIL$)", text, re.M):
            return None, "Go text test/build output was not recognized"
        if re.search(r"^=== (?:PAUSE|CONT|NAME)\s", text, re.M):
            return None, "parallel/interleaved Go logs are not supported by the named-failure reader"
        paths = []
        # A passing test's Log output must not become another test's failure.
        for block in re.findall(r"^=== RUN\s+.*?(?=^=== RUN|\Z)", text, re.M | re.S):
            if re.search(r"^\s*--- FAIL:", block, re.M):
                paths.extend(re.findall(r"^\s+([^\s:]+\.go):\d+:", block, re.M))
        for block in re.findall(r"^--- FAIL:.*?(?=^--- (?:PASS|FAIL):|^FAIL|\Z)", text, re.M | re.S):
            paths.extend(re.findall(r"^\s+([^\s:]+\.go):\d+:", block, re.M))
        if "[build failed]" in text:
            paths.extend(re.findall(r"^([^\s:]+\.go):\d+(?::\d+)?:", text, re.M))
        return paths, "Go sequential failing-test and build-error locations; basename-only paths require a unique file in the checkout"
    if stack == "ruby":
        if not re.search(r"\d+ examples?, \d+ failures?|An error occurred while loading ", text):
            return None, "RSpec text output was not recognized"
        paths = re.findall(r"An error occurred while loading (\S+?)(?:\.\s*$|\s)", text, re.M)
        for block in re.findall(r"^Failures:.*?(?=^Finished in |\Z)", text, re.M | re.S):
            paths.extend(re.findall(r"^\s+#\s+([^:\n]+):\d+", block, re.M))
        return paths, "RSpec failure backtraces and load-error paths"
    return None, "no named-failure reader for this stack"


def matches(location, rel, root, run_dir):
    # Runner paths may be relative to the package cwd or, for Go, the source
    # package. No substring matching of assertion prose or source excerpts.
    location = location.replace("\\", "/")
    if os.path.isabs(location):
        return os.path.normpath(location) == os.path.normpath(str(Path(root) / rel))
    if "/" not in location and location == Path(rel).name:
        candidates = [p for p in Path(root).rglob(location)
                      if ".git" not in p.relative_to(root).parts and p.is_file()]
        return len(candidates) == 1 and candidates[0] == Path(root) / rel
    if os.path.normpath(str(Path(run_dir) / location)) == os.path.normpath(str(Path(root) / rel)):
        return True
    return False


mode = sys.argv[1]
if mode == "paths":
    print("\n".join(e["path"] for e in declarations(sys.argv[2])))
elif mode == "excluded":
    print(json.dumps([dict(path=e["path"], reason="worker declared stored-output: " + e["reason"])
                      for e in declarations(sys.argv[2])]))
elif mode == "check":
    result, root, run_dir, stack, leg, rc, command, scope, output = sys.argv[2:]
    text = Path(output).read_text(errors="replace")
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    locations, method = failure_locations(stack, text)
    contradicted = []
    if int(rc) != 0 and locations is not None:
        contradicted = [e["path"] for e in declarations(result)
                        if any(matches(p, e["path"], root, run_dir) for p in locations)]
    print(json.dumps(dict(leg=leg, rc=int(rc), cmd=command, scope=scope,
                          checked=locations is not None, method=method,
                          contradicted=contradicted, output=text)))
