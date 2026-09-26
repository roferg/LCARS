#!/usr/bin/env python3
"""stdin_guard.py FILE... — flag any suite line that reads INHERITED stdin.

The S208 hang class: a `cat` with no file operand and no `<` redirect reads
whatever stdin the suite was launched with. From a terminal that blocks forever;
with stdin closed it returns empty and the assertion passes by accident.

Skipped, because they are not the suite's own stdin:
  * comment lines;
  * heredoc BODIES — those are stub scripts being written to disk (a `gh` stub
    reading `$(cat)` for `--field body=@-` is reading a real pipe, correctly);
  * any line carrying the cured qgrep's drain verbatim — the ONE legitimate
    bare cat, reached only when no FILE operand was passed (and the harness
    suite's own copy of that string, which it greps for to detect drift).

Prints one "file:line: text" per offender and exits 1 if there are any.
"""
import re
import sys

CANON = '  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"'
BARE = re.compile(r'\$\(\s*cat\s*\)|`\s*cat\s*`|^\s*cat\s*(\||$)')
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

offenders = []
for path in sys.argv[1:]:
    delim = None
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = line.rstrip("\n")
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        m = HEREDOC.search(line)
        stripped = line.lstrip()
        if not stripped.startswith("#") and CANON not in line and BARE.search(line):
            offenders.append("%s:%d: %s" % (path, n, line.strip()))
        if m:
            delim = m.group(2)

for o in offenders:
    print(o)
sys.exit(1 if offenders else 0)
