#!/usr/bin/env bash
# S321: real proof gates and paste-back commands, never fabricated runner output.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lcars-gate-execution.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

fixture() {
  bash "$ROOT/tests/fixtures/mkflatrepo.sh" --dir "$TMP/$1" --files 2 --sleep 0 --tip "$2" >/dev/null 2>&1
}
config() {
  python3 - "$TMP/$1/repo/.git/lcars/config.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["testCommand"] = sys.argv[2]
d["stack"] = "py" if "unittest" in sys.argv[2] else "js"
with open(p, "w") as f:
    for i, (k, v) in enumerate(d.items()):
        f.write(("{\n" if i == 0 else "") + json.dumps(k) + ": " + json.dumps(v)
                + (",\n" if i < len(d)-1 else "\n}\n"))
PY
}
gate() {
  local b="$TMP/$1"
  if [ ! -f "$b/parent.sha" ]; then git -C "$b/repo" rev-parse HEAD~1 >"$b/parent.sha"; fi
  (cd "$b/repo" && PATH="$b/shim:$PATH" LCARS_GH_BIN=true LCARS_GATE_TIMEOUT=15 \
    bash "$RUN" flip-flop-gate-test --mission m-001 --ticket t-001 \
    --sha "$(cat "$b/parent.sha")") >"$b/gate.log" 2>&1
}
check() {
  local name="$1"; shift
  if python3 - "$TMP/$name/repo/.git/lcars/missions/m-001/tickets/t-001/flip-flop.json" "$@" <<'PY'
import json, os, re, subprocess, sys
d = json.load(open(sys.argv[1]))
mode = sys.argv[2]
if mode == "pass":
    assert d["verdict"] == "pass", d["reason"]
    assert d["gate"]["scopeKind"] == "files", d["gate"]
    run = subprocess.run(["bash", "-c", d["tip"]["cmd"]], capture_output=True, text=True)
    assert run.returncode == 0, run.stdout + run.stderr
    out = run.stdout + run.stderr
    if "unittest" in out or "Ran " in out:
        assert out.count("Ran 1 test") == 2, out
    else:
        assert len(re.findall(r"\bpass 1\s*$", out, re.M)) == 2, out
    assert not d["declaredRan"]["unaccounted"], d["declaredRan"]
elif mode == "inconclusive":
    assert d["verdict"] == "inconclusive", d
    assert "executed" in d["reason"].lower(), d["reason"]
    assert d["tip"]["cmd"] in d["reason"], d["reason"]
elif mode == "red":
    assert d["verdict"] == "fail", d
    assert "TIP leg is RED" in d["reason"], d["reason"]
elif mode == "excluded":
    assert d["verdict"] == "pass", d
    excluded = d["declaredRan"]["excluded"]
    assert {x["path"] for x in excluded} == {"tests/__init__.py", "tests/test_helpers.py"}, excluded
    assert all(x["reason"] for x in excluded), excluded
    assert not d["declaredRan"]["unaccounted"], d["declaredRan"]
elif mode == "ancestor":
    assert d["verdict"] == "pass", d["reason"]
    assert d["gate"]["scopeKind"] == "ancestor", d["gate"]
    root = os.path.realpath(sys.argv[1].split("/.git/")[0])
    raw = 'python3 -m unittest discover -s "${LCARS_TESTS_DIR:-tests}" -p "test_*.py"'
    expected = "cd '%s' && LCARS_TESTS_DIR='%s/tests/unit' bash -c '%s'" % (root, root, raw)
    assert d["tip"]["cmd"] == expected, d["tip"]["cmd"]
    run = subprocess.run(["bash", "-c", d["tip"]["cmd"]], capture_output=True, text=True)
    assert run.returncode == 0, run.stdout + run.stderr
    assert "Ran 2 tests" in run.stderr, run.stderr
    assert {x["path"] for x in d["declaredRan"]["excluded"]} == {
        "tests/unit/__init__.py", "tests/unit/test_helpers.py"}, d["declaredRan"]
elif mode == "skipped":
    assert d["verdict"] == "inconclusive", d
    assert "tests/unit/test_helpers.py" in d["declaredRan"]["unaccounted"], d["declaredRan"]
    assert "tests/unit/test_helpers.py" not in {
        x["path"] for x in d["declaredRan"]["excluded"]}, d["declaredRan"]
PY
  then ok "$name $*"; else bad "$name $*"; fi
}

echo "S321 — the gate cannot fail tests it did not execute"
fixture python none
P="$TMP/python/repo"
mkdir -p "$P/tests"
cat >"$P/tests/test_slow.py" <<'PY'
import time
import unittest
class Slow(unittest.TestCase):
    def test_slow(self):
        time.sleep(20)
PY
printf '__pycache__/\n' >"$P/.gitignore"
git -C "$P" add -A && git -C "$P" commit -qm "python parent with undeclared slow test"
for op in up down; do
  cat >"$P/tests/test_$op.py" <<PY
import unittest
from src.$op import convert
class Ticket(unittest.TestCase):
    def test_convert(self):
        self.assertEqual(convert('Hi'), '${op}')
PY
  printf "def convert(s):\n    return '%s'\n" "$op" >"$P/src/$op.py"
done
git -C "$P" add -A && git -C "$P" commit -qm "python ticket"
cat >"$P/.git/lcars/missions/m-001/tickets/t-001/result.json" <<'JSON'
{"ticketId":"t-001","passed":true,"newTests":["tests/test_up.py","tests/test_down.py"],"testEdits":[],"flipFlop":"expected"}
JSON
config python 'python3 -m unittest discover -s "${LCARS_TESTS_DIR:-tests}" -p "test_*.py"'
gate python
check python pass

printf '"""Package marker, not a test suite."""\n' >"$P/tests/__init__.py"
printf 'def helper():\n    return 42\n' >"$P/tests/test_helpers.py"
python3 - "$P/.git/lcars/missions/m-001/tickets/t-001/result.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["newTests"].extend(["tests/__init__.py", "tests/test_helpers.py"])
json.dump(d, open(p, "w"))
PY
git -C "$P" add -A && git -C "$P" commit -qm "declared package marker and helper without test methods"
gate python
check python excluded

mkdir -p "$P/tests/unit"
mv "$P/tests/__init__.py" "$P/tests/test_up.py" "$P/tests/test_down.py" \
  "$P/tests/test_helpers.py" "$P/tests/unit/"
python3 - "$P/.git/lcars/missions/m-001/tickets/t-001/result.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["newTests"] = [x.replace("tests/", "tests/unit/") for x in d["newTests"]]
json.dump(d, open(p, "w"))
PY
git -C "$P" add -A && git -C "$P" commit -qm "nested Python test scope with support files"
gate python
check python ancestor

cat >"$P/tests/unit/test_helpers.py" <<'PY'
import unittest
class Skipped(unittest.TestCase):
    @unittest.skip("must not be treated as a support file")
    def test_skipped(self):
        self.fail("skipped")
PY
git -C "$P" add -A && git -C "$P" commit -qm "skipped tests remain accountable"
gate python
check python skipped

fixture node flat2
gate node
check node pass

fixture support-only none
: >"$TMP/support-only/repo/tests/__init__.py"
printf 'def helper():\n    return 42\n' >"$TMP/support-only/repo/tests/test_helpers.py"
git -C "$TMP/support-only/repo" add -A && git -C "$TMP/support-only/repo" commit -qm "only support files"
cat >"$TMP/support-only/repo/.git/lcars/missions/m-001/tickets/t-001/result.json" <<'JSON'
{"ticketId":"t-001","passed":true,"newTests":["tests/__init__.py","tests/test_helpers.py"],"testEdits":[],"flipFlop":"expected"}
JSON
config support-only 'python3 -m unittest discover -s "${LCARS_TESTS_DIR:-tests}" -p "test_*.py"'
gate support-only
check support-only inconclusive

fixture zero flat2
config zero 'node --test --test-concurrency=1 "$LCARS_TESTS_DIR"/*.test.js; exit 1'
gate zero
check zero inconclusive

fixture uncountable flat2
config uncountable 'node --test "$LCARS_TESTS_DIR" >/dev/null; exit 1'
gate uncountable
check uncountable inconclusive

fixture uncountable-green flat1
config uncountable-green 'node --test "$LCARS_TESTS_DIR" >/dev/null; true'
gate uncountable-green
check uncountable-green inconclusive

fixture red flat2
printf "\nrequire('node:test').test('real failure', () => { require('node:assert').fail('red'); });\n" \
  >>"$TMP/red/repo/tests/ticket_up.test.js"
git -C "$TMP/red/repo" add -A && git -C "$TMP/red/repo" commit -qm "genuine failing assertion"
gate red
check red red

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
