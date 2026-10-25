#!/usr/bin/env bash
# S314: generator -> persisted PRD -> real Plan gate. Python prepares fixtures
# through the daemon's HTTP hand-off; only the shell invokes/asserts the gate.
# No models or forge calls: only the turn, estimator and gh are stubs.
# Usage: bash tests/holodeck-handoff.test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export LCARS_VERSION_CHECK=0
export LCARS_HOLODECK_HANDOFF_CHECK=0
export LCARS_WORKER_CLI=copilot
pass=0
fail=0
ok() { printf '  PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

python3 - "$REPO_ROOT" "$TMPROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest.mock

root, fixtures = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / "web"))
from lcars_serve.actions import Actions
from tests.test_holodeck_endpoints import HandoffBase

q1 = "What belongs in the command list?"
q2 = "Should the palette be reachable from a mission card too?"
concept = "# Palette\n\n## Open questions\n\n- " + q1 + "\n- " + q2 + "\n"
answers = {"q1": "Only board verbs.", "q2": "No, keyboard only."}


def prd(idea):
    # Align is a model seam, not what this suite proves. Carry the generated
    # idea verbatim into a minimal PRD, as the Align contract requires.
    return ("# Mission: Palette\n\n**Type:** feature\n\n## Goal\n\n" + idea
            + "\n\n## Acceptance Criteria\n\n- Cmd-K opens the palette.\n\n"
            "## Out of Scope\n\n- Other controls.\n\n"
            "## Constraints\n\n- Reuse the router.\n")


for name, said in (("answered", answers), ("unanswered", {})):
    dest = fixtures / name
    dest.mkdir()
    (dest / "prd.md").write_text(prd(Actions._handoff_idea(
        "Build the palette", "look+behaviour", concept, said)))

guidance = fixtures / "guidance"
guidance.mkdir()
(guidance / "prd.md").write_text(
    (fixtures / "answered/prd.md").read_text().replace(
        "## Open questions from the design session\n",
        "## Design question guidance\n\n"
        "Read each question before spending a human gate.\n\n"
        "## Open questions from the design session\n"))

undeclared = fixtures / "undeclared"
undeclared.mkdir()
(undeclared / "prd.md").write_text(prd(
    "## Open questions from the design session\n\n"
    "- Should the palette also open from the toolbar?\n\n"
    "- RESOLVED with the captain: " + q1 + " \u2014 Only board verbs.\n"))

wrapped = fixtures / "wrapped"
wrapped.mkdir()
(wrapped / "prd.md").write_text(prd(
    "## Open questions from the design session\n\n"
    "- STILL OPEN: Should the palette be reachable\n"
    "  from a mission card too?\n"))
(fixtures / "expected-wrapped.txt").write_text(q2 + "\n")

declared = fixtures / "declared-only"
declared.mkdir()
(declared / "prd.md").write_text(prd(
    "## Open questions from the design session\n\n"
    "- STILL OPEN: " + q1 + "\n"
    "- STILL OPEN: " + q2 + "\n"))

old = fixtures / "old-numbered"
old.mkdir()
(old / "prd.md").write_text(prd(
    "## Open questions from the design session\n\n"
    "1. Q: " + q1 + "\n   DECIDED: Only board verbs.\n\n"
    "2. Q: " + q2 + "\n   NO ANSWER RECORDED.\n"))
(fixtures / "expected-open.txt").write_text(q1 + "\n" + q2 + "\n")
(fixtures / "expected-resolved.txt").write_text(
    q1 + " \u2014 DECIDED: Only board verbs.\n"
    + q2 + " \u2014 DECIDED: No, keyboard only.\n")


class HandoffFixture(HandoffBase):
    CONCEPT = concept


for name, answered in (("http-answered", True), ("http-unanswered", False)):
    case = HandoffFixture()
    case.setUp()
    try:
        repo = Path(case.repo)
        # Keep fixture subprocesses owned and reaped, with no real remotes.
        def command(argv, env=None):
            result = subprocess.run(argv, cwd=repo, env=env, text=True,
                                    capture_output=True, timeout=60)
            if result.returncode == 97 or "FENCE" in result.stdout + result.stderr:
                print(result.stdout + result.stderr)
                raise SystemExit(97)
            if result.returncode:
                raise RuntimeError(str(argv) + "\n" + result.stdout + result.stderr)
            return result

        for args in (["init", "-q", "-b", "main"],
                     ["config", "user.name", "Test"],
                     ["config", "user.email", "test@example.invalid"],
                     ["add", "board.css"], ["commit", "-qm", "Fixture"]):
            command(["git"] + args)
        (repo / ".git/lcars/config.json").write_text(json.dumps({
            "testCommand": "true", "workerBin": "copilot",
            "numberOne": {"enabled": False}}))
        gh = Path(case.bindir) / "gh"
        gh.write_text("#!/bin/sh\n"
                      "if [ \"$1 $2\" = 'issue create' ]; then\n"
                      " echo https://github.com/owner/repo/issues/42\nfi\n")
        gh.chmod(0o755)
        estimator = Path(case.bindir) / "estimate.sh"
        estimator.write_text("#!/bin/sh\nexit 0\n")
        estimator.chmod(0o755)
        env = dict(os.environ, LCARS_GH_BIN=str(gh),
                   LCARS_RUN_BIN=str(estimator))
        file_script = str(root / "skills/lcars-file/file.sh")
        case.actions.scripts["file"] = file_script
        with unittest.mock.patch.dict(os.environ, env):
            sid = case._program()
            status, promo = case._promote(sid)
            if status != 200:
                raise RuntimeError(str(promo))
            questions = promo["state"]["questions"]
            if [q["text"] for q in questions] != [q1, q2]:
                raise AssertionError(questions)
            said = ({q["id"]: answer for q, answer in
                     zip(questions, answers.values())} if answered else {})
            status, body = case._post("/api/park", {
                "idea": "Build the palette", "holodeck": sid, "engine": "copilot",
                "holodeckAnswers": said})
        if status != 200:
            raise RuntimeError(str(body))
        mid = body["state"]["holodeck"]["missionId"]
        if not mid:
            raise AssertionError(body)
        mission = repo / ".git/lcars/missions" / mid
        aligned = fixtures / (name + "-aligned.md")
        aligned.write_text(prd((mission / "idea.md").read_text()))
        command(["bash", file_script, "--complete", mid, "--prd", str(aligned)], env)
        # Keep the actual filed artifact, not a reconstruction. The shell gate
        # runs before tearDown can remove the mission, via this exact snapshot.
        dest = fixtures / name
        dest.mkdir()
        (dest / "prd.md").write_bytes((mission / "prd.md").read_bytes())
        print("HTTP hand-off + real file.sh --complete: " + name)
    finally:
        case.tearDown()
        case.doCleanups()
PY

gate() {
  local dir="$1" hook="$2"
  rc=0
  LCARS_ATT_TEST_DIR="$TMPROOT/$dir" bash "$RUN" "$hook" \
    >"$TMPROOT/$dir/$hook.out" 2>"$TMPROOT/$dir/$hook.err" || rc=$?
  if [ "$rc" -eq 97 ] || grep -q 'FENCE' \
    "$TMPROOT/$dir/$hook.out" "$TMPROOT/$dir/$hook.err"; then
    cat "$TMPROOT/$dir/$hook.out" "$TMPROOT/$dir/$hook.err"
    exit 97
  fi
  printf '  GATE %s %s rc=%s\n' "$dir" "$hook" "$rc"
}

accepts() {
  local dir="$1" name="$2"
  gate "$dir" open-questions-test
  if [ "$rc" -eq 0 ] && [ ! -s "$TMPROOT/$dir/open-questions-test.err" ]; then
    ok "$name"
  else
    bad "$name (expected rc 0, got $rc)"
    cat "$TMPROOT/$dir/open-questions-test.err"
  fi
}

resolved() {
  local dir="$1" name="$2"
  gate "$dir" resolved-decisions-test
  if [ "$rc" -eq 0 ] && cmp -s "$TMPROOT/expected-resolved.txt" \
    "$TMPROOT/$dir/resolved-decisions-test.out" \
    && [ ! -s "$TMPROOT/$dir/open-questions-test.out" ]; then
    ok "$name"
  else
    bad "$name"
  fi
  gate "$dir" plan-open-questions-block-test
  if [ "$rc" -eq 0 ] && [ ! -s "$TMPROOT/$dir/plan-open-questions-block-test.out" ]; then
    ok "$name: no unresolved-question block reaches Plan"
  else
    bad "$name: no unresolved-question block reaches Plan"
  fi
}

reaches_plan() {
  local dir="$1" name="$2" output="$TMPROOT/$1/plan-open-questions-block-test.out"
  if cmp -s "$TMPROOT/expected-open.txt" "$TMPROOT/$dir/open-questions-test.out"; then
    ok "$name: gate carries exactly both questions"
  else
    bad "$name: gate carries exactly both questions"
  fi
  gate "$dir" plan-open-questions-block-test
  if [ "$rc" -eq 0 ] \
    && grep -Fxq '  1. What belongs in the command list?' "$output" \
    && grep -Fxq '  2. Should the palette be reachable from a mission card too?' "$output"; then
    ok "$name: both questions reach the real Plan prompt block"
  else
    bad "$name: both questions reach the real Plan prompt block"
  fi
}

gate undeclared open-questions-test
if [ "$rc" -eq 1 ] \
  && [ ! -s "$TMPROOT/undeclared/open-questions-test.out" ] \
  && grep -Fq 'Should the palette also open from the toolbar?' \
    "$TMPROOT/undeclared/open-questions-test.err"; then
  ok "REGRESSION: an undeclared question beside a declared bullet is refused and named"
else
  bad "REGRESSION: an undeclared question beside a declared bullet is refused and named (got rc $rc)"
fi

accepts wrapped "CONTROL A: wrapped STILL OPEN bullet passes (D4)"
if cmp -s "$TMPROOT/expected-wrapped.txt" "$TMPROOT/wrapped/open-questions-test.out"; then
  ok "CONTROL A: wrapped bullet is ONE question joined across the line break"
else
  bad "CONTROL A: wrapped bullet is ONE question joined across the line break"
fi
gate wrapped plan-open-questions-block-test
if [ "$rc" -eq 0 ] \
  && grep -Fxq '  1. Should the palette be reachable from a mission card too?' \
    "$TMPROOT/wrapped/plan-open-questions-block-test.out"; then
  ok "CONTROL A: joined question reaches the real Plan prompt block"
else
  bad "CONTROL A: joined question reaches the real Plan prompt block"
fi

accepts declared-only "CONTROL B: only declared bullets passes"
reaches_plan declared-only "CONTROL B: only declared bullets"

accepts answered "CONTROL C: answered real generator output is accepted"
resolved answered "1. both captain answers are carried as resolved decisions"
accepts unanswered "CONTROL C: unanswered real generator output is accepted"
reaches_plan unanswered "2. unanswered generator output"
accepts guidance "3. guidance prose outside the questions section is not counted as an entry"
resolved guidance "3. guidance does not change either resolved decision"

gate old-numbered open-questions-test
if [ "$rc" -eq 1 ] && [ ! -s "$TMPROOT/old-numbered/open-questions-test.out" ] \
  && grep -Fq '0 of 2 bullet entries declare themselves' \
    "$TMPROOT/old-numbered/open-questions-test.err"; then
  ok "CONTROL: old numbered N. Q: format is refused (rc 1, two undeclared entries)"
  cat "$TMPROOT/old-numbered/open-questions-test.err"
else
  bad "CONTROL: old numbered N. Q: format must be refused with rc 1"
fi

accepts http-answered "6. answered HTTP hand-off -> real filing -> Plan gate accepts"
resolved http-answered "6. filed answers reach the resolved-decisions consumer"
accepts http-unanswered "6. unanswered HTTP hand-off -> real filing -> Plan gate accepts"
reaches_plan http-unanswered "6. filed unanswered questions"

printf '\nholodeck handoff: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
