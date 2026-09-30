#!/usr/bin/env python3
"""Rewrite a state.json so <key> is its LAST field — the shape S207 cures.

Used by tests/lcars-state-writer.test.sh to plant the corrupting shape through
a REAL verb: the writer's defect is positional, so a test that never puts the
field it is about to clear at the end of the object cannot see it.

    lcars-state-writer-last.py <state.json> <key> <json-value>

The output keeps LCARS's one-field-per-line convention (`{` alone on line 1,
`}` alone on the last), because every LCARS reader assumes it.
"""
import json
import sys

path, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
value = json.loads(raw)
doc = json.load(open(path))
doc.pop(key, None)
items = list(doc.items()) + [(key, value)]
with open(path, "w") as fh:
    fh.write("{\n")
    fh.write(",\n".join("  %s: %s" % (json.dumps(k), json.dumps(v)) for k, v in items))
    fh.write("\n}\n")
