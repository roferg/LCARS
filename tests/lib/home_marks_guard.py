#!/usr/bin/env python3
"""tests/lib/home_marks_guard.py — does every checklist teach a HOME the fence takes?

S261 fix round 2, F1's third instance. F1 was cured in `run.sh`'s own paragraph:
the round used to hand the worker an ABSOLUTE throwaway HOME, the worker copied
it into a declared step's `env.HOME`, and `declared_escape` refused all six of
its steps — the seed steps, so the build it then photographed was empty.

The SAME defect was then measured three more times, in the checklists, which
reach the live worker verbatim (observed at lines 926, 1061 and 1311 of the
assembled prompt the live look received):

    live-check/cli.md:118  "HOME": "<second-throwaway-home>"
    live-check/cli.md:253  "HOME": "<a-fresh-throwaway-home>"
    live-check/web.md:223  "HOME": "<a-fresh-throwaway-home>"

None of those three is a mark `xo-run.py` mints. Two of them sit on the
second-actor item that F1's cure now actively points the worker at, so leaving
them would walk the reviewer straight into a refusal.

THE ACCEPTED SET IS READ OUT OF `xo-run.py`, NEVER TRANSCRIBED HERE. A second
copy of the allow-list in this file would be free to drift the moment the fence
mints a fourth mark — which is the whole fault class. So the marks come from
`HOME_MARK` + `EXTRA_HOME_MARKS`, and every value found is judged by running the
REAL `declared_escape`, not by comparing strings to a list.

Usage: home_marks_guard.py <xo-run.py> <checklist-dir>
Exit 0 when every taught HOME is one the fence honours, 1 otherwise.
"""
import importlib.util
import os
import re
import sys

HOME_RE = re.compile(r'"HOME"\s*:\s*"([^"]*)"')


def load(path):
    spec = importlib.util.spec_from_file_location("xorun", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def judge(mod, value):
    """The REAL gate's verdict on a step whose only sin could be its HOME."""
    return mod.declared_escape({"do": "run", "argv": ["git", "status"],
                                "cwd": "<worktree>", "env": {"HOME": value}})


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-2])
        return 2
    xorun, cldir = sys.argv[1], sys.argv[2]
    mod = load(xorun)
    accepted = (mod.HOME_MARK,) + tuple(mod.EXTRA_HOME_MARKS)
    print("the marks xo-run.py mints: %s" % ", ".join(accepted))

    # THE PROBE'S OWN CONTROL, passed literally. A gate that accepted anything
    # would make every row below pass vacuously, which is how nine probes
    # passed for nothing in one night of this project.
    good = judge(mod, "<throwaway-home>")
    bad = judge(mod, "<zz-not-a-mark>")
    print("control  <throwaway-home>  -> %s" % (good or "ACCEPTED"))
    print("control  <zz-not-a-mark>   -> %s" % (bad or "ACCEPTED"))
    if good != "" or bad == "":
        print("THE PROBE ITSELF IS BROKEN: the gate did not discriminate")
        return 1

    bad_rows, n = [], 0
    for name in sorted(os.listdir(cldir)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(cldir, name)
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                for value in HOME_RE.findall(line):
                    n += 1
                    why = judge(mod, value)
                    tag = "ACCEPTED" if why == "" else "REFUSED"
                    print("  %-9s %s:%d  %s" % (tag, name, lineno, value))
                    if why:
                        bad_rows.append((name, lineno, value, why))
    print("%d HOME value(s) taught across the checklists, %d refused by the fence"
          % (n, len(bad_rows)))
    if n == 0:
        print("NOTHING WAS SCANNED — an empty sweep is not a pass")
        return 1
    for name, lineno, value, why in bad_rows:
        print("  %s:%d teaches %s — %s" % (name, lineno, value, why))
    return 1 if bad_rows else 0


if __name__ == "__main__":
    sys.exit(main())
