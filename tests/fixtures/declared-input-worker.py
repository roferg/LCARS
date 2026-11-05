#!/usr/bin/env python3
# PURE FAKE; never resolves or delegates to a real CLI.
import json
import os
from pathlib import Path

Path("src/calc.js").write_text(
    "exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\n")
Path("tests/mul.test.js").write_text(
    "const { test } = require('node:test');\n"
    "const assert = require('node:assert');\n"
    "const { mul } = require('../src/calc.js');\n"
    "test('mul multiplies', () => { assert.strictEqual(mul(2, 3), 6); });\n")
Path(os.environ["LCARS_WORK_OUT"], "result.json").write_text(json.dumps({
    "ticketId": "t-001", "passed": True, "attempts": 1,
    "summary": "Add multiplication", "newTests": ["tests/mul.test.js"],
    "testEdits": [], "flipFlop": "expected",
}))
