#!/usr/bin/env bash
# S377: render every driver gate/notification from its actual call site.
set -euo pipefail
python3 - "$@" <<'PY'
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path.cwd()
RUN = Path(os.environ.get("LCARS_RUN_SCRIPT", "skills/lcars-run/run.sh")).resolve()
GUARD = Path(os.environ.get("LCARS_MERGE_GUARD", "skills/lcars-run/merge-guard.sh")).resolve()
APPROVE = Path(os.environ.get("LCARS_APPROVE_SCRIPT", "skills/lcars-approve/approve.sh")).resolve()
RESOLVE = Path(os.environ.get("LCARS_RESOLVE_LOGS_SCRIPT", "skills/lcars-resolve-logs/resolve-logs.sh")).resolve()
ECH = Path(os.environ.get("LCARS_ECH_SCRIPT", "skills/lcars-eeh/ech.sh")).resolve()
ANSWER = Path(os.environ.get("LCARS_ANSWER_SCRIPT", "skills/lcars-answer/answer.sh")).resolve()


def calls(source, path):
    lines = source.splitlines()
    for i, line in enumerate(lines):
        text = line.strip()
        matched = re.match(r'(notify_gate (?!\()|emit_event (gate |approve_refused |reconcile_(?:escalated|env_blocked|reapprove) ))', text)
        if path == ECH and text.startswith('notify "$1" "awaiting-human"'):
            matched = True
        if path == ANSWER and text.startswith("printf '    →"):
            matched = True
        if path == APPROVE:
            match = re.search(r'(echo "(?:APPROVE:|lcars approve: reconcile failed)|die "(?:no open PR|gh not found|Mission stays at verify|\$(?:f?note|mnote)))', text)
            if match:
                text = text[match.start():].split("; exit ")[0]
                matched = True
            if text.startswith('echo "APPROVE: merged'):
                continue
        assignment = re.match(r'(?:local )?(note|fnote|mnote|ask|ASK|STUCK_NOTE)=".+', text)
        if assignment and (text.endswith('=""') or '="$(json_str ' in text):
            assignment = None
        if path in (APPROVE, RESOLVE) and assignment:
            matched = True
        if path == RUN:
            match = re.search(r'(die "mission is awaiting a human answer|emit_event error |echo "RECONCILE: (?:escalated|cannot reconcile|awaiting-reapprove))', text)
            if match:
                text = text[match.start():]
                matched = True
            if re.match(r"""(?:echo "  (?:Merge through|Stage: verify)|printf '(?:  (?:Merge the PR|Send back with feedback)|Resume|rewrite the PRD|RECONCILE: (?:escalated|env-blocked)|⏹ stopped at: verify \(folds))""", text):
                matched = True
        if path == RESOLVE and re.match(r"""(?:echo "  (?:Record the parent|Fix the push|Answer this child|Accept \()|printf '  Send the Mission back)""", text):
            matched = True
        if not matched:
            continue
        if text.startswith("emit_event gate done "):
            continue  # Completed work is not an instruction.
        while text.endswith("\\"):
            i += 1
            text = text[:-1] + lines[i].strip()
        text = re.sub(r'\s*;;$', '', text)
        if assignment and path in (APPROVE, RESOLVE):
            text += f'; printf \'%s\\n\' "${assignment[1]}"'
        yield i + 1, text


def hint_functions(source):
    lines = source.splitlines()
    for i, line in enumerate(lines):
        if re.match(r'^\w+_hint\(\) \{', line):
            block = [line]
            if not line.endswith("}"):
                for tail in lines[i + 1:]:
                    block.append(tail)
                    if tail == "}":
                        break
            yield "\n".join(block)


class Instructions(unittest.TestCase):
    def test_every_audited_message_ends_in_runnable_command(self):
        source = RUN.read_text()
        # These are the product's real hint functions, not a test's command list.
        start = source.index('RESPOND_SCRIPT=')
        end = source.index('# --- tiny JSON readers', start)
        helpers = source[start:end]
        environment = dict(os.environ, SELF=str(RUN), SKILL_DIR=str(RUN.parent),
                           MISSION_ID="lcars-audit", BASE="main", RECONCILE_MAX="3",
                           first="A real question", what="Proof failed", summary="Details",
                           parent="lcars-parent", pr2="https://example.test/pull/77",
                           total="2", short="abcdef", open="lcars-bug\tBug\timplement",
                           broken="bad/state.json", RUN_SCRIPT=str(RUN), PARENT_ID="lcars-parent",
                           PARENT_TITLE="Parent", bid="lcars-bug", bstage="implement",
                           bq="Which design?", waiting=" Two siblings queued.", qid="q1",
                           n="2", noun="logged bugs", id="lcars-audit",
                           PR_URL="https://example.test/pull/77", merge_tries="2",
                           APPROVE_SCRIPT=str(APPROVE), FEEDBACK_SCRIPT=str(ROOT / "skills/lcars-feedback/feedback.sh"),
                           WAVE_ERRORED="lcars-bug", STUCK_NOTE="", action="research",
                           stage_timeout="30")
        rendered = 0
        commands = set()
        for path in (RUN, GUARD, APPROVE, RESOLVE, ECH, ANSWER):
            content = path.read_text()
            for number, call in calls(content, path):
                with self.subTest(path=path.name, line=number):
                    note = ""
                    for var in ("note", "fnote", "mnote"):
                        if re.search(r'\$' + var + r'\b', call) and not call.startswith("local "):
                            assignments = re.findall(r'^\s*local ' + var + r'=".*$', "\n".join(content.splitlines()[:number - 1]), re.M)
                            self.assertTrue(assignments, "message's note has no auditable producer")
                            note += "\n" + assignments[-1]
                    script = f"""
{helpers}
. {shlex.quote(str(GUARD))}
{chr(10).join(hint_functions(content)) if path in (APPROVE, RESOLVE) else ""}
emit_event() {{ printf '%s\\n' "$3"; }}
notify_gate() {{ printf '%s\\n' "$2"; }}
notify() {{ printf '%s\\n' "$3"; }}
die() {{ printf '%s\\n' "$1"; }}
json_str() {{ printf 'implement'; }}
audit() {{
set -- lcars-audit "A question"
{note}
{call}
}}
audit
"""
                    env = dict(environment, SELF=str(path), SKILL_DIR=str(path.parent), SELF_DIR=str(path.parent))
                    result = subprocess.run(["bash", "-c", script], env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    message = (result.stdout + result.stderr).strip()
                    self.assertRegex(message, r' — run: bash .+$', message)
                    command = message.rsplit(" — run: ", 1)[-1]
                    args = shlex.split(command)
                    self.assertEqual(args[0], "bash")
                    self.assertTrue(Path(args[1]).is_file(), command)
                    if "PR opened —" in message or message.startswith("PR open:") or "in review — PR open;" in message:
                        self.assertEqual(Path(args[1]).name, "approve.sh", "Verify must name the sanctioned merge command")
                    commands.add(tuple(args))
                    rendered += 1
        self.assertGreaterEqual(rendered, 40, "audit unexpectedly stopped discovering gates")
        # Resolve the actual commands through their real parsers, against an
        # empty repo: no Mission exists, so no worker/merge can be dispatched.
        scratch = ROOT / ".s377"
        scratch.mkdir(exist_ok=True)
        repo = Path(tempfile.mkdtemp(prefix="hint-dispatch-", dir=scratch))
        try:
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            for args in commands:
                with self.subTest(command=shlex.join(args)):
                    env = dict(os.environ, LCARS_VERSION_CHECK="0", LCARS_GH_BIN="false",
                               LCARS_WORKER_BIN="false", LCARS_RESPOND_RESUME="0")
                    result = subprocess.run(args, cwd=repo, env=env, text=True,
                                            capture_output=True, timeout=15)
                    output = result.stdout + result.stderr
                    self.assertNotEqual(result.returncode, 0, output)
                    self.assertNotRegex(output, r"unknown (?:subcommand|argument)|unexpected argument|command not found|No such file")
                    self.assertRegex(output.lower(), r"mission|not initialized|lcars init|no .*autopilot|no .*state")
        finally:
            shutil.rmtree(repo)
        print(f"Audited {rendered} messages; resolved {len(commands)} distinct commands")


unittest.main(argv=["merge-instructions", *__import__("sys").argv[1:]], verbosity=2)
PY
