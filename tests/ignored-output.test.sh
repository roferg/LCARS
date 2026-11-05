#!/usr/bin/env bash
# S347 leg A: ignored work products are reported without changing scoped staging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root, runner = map(Path, sys.argv[1:])
os.chdir(root)
with tempfile.TemporaryDirectory(prefix="ignored-output-") as tmp:
    base = Path(tmp)
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_GIT_BIN="git",
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def run(repo, *args):
        result = subprocess.run(args, cwd=repo, env=env, capture_output=True,
                                text=True, check=True, timeout=60)
        return result.stdout + result.stderr

    def fixture(name):
        repo = base / name
        repo.mkdir()
        run(repo, "git", "init", "-q", "-b", "main")
        run(repo, "git", "config", "user.email", "test@example.com")
        run(repo, "git", "config", "user.name", "Test")
        (repo / ".gitignore").write_text(
            "# captain's rules\n# reports are ignored except the judgment\n"
            "!reports/\nreports/*\n!reports/JUDGMENT-CALLS.html\n")
        (repo / "tracked.txt").write_text("before\n")
        run(repo, "git", "add", "--", ".gitignore", "tracked.txt")
        run(repo, "git", "commit", "-qm", "Initial commit")
        td = repo / ".git/lcars/missions/m-001/tickets/t-001"
        td.mkdir(parents=True)
        (td.parent.parent / "state.json").write_text(json.dumps({
            "id": "m-001", "stage": "implement", "branch": "main"}))
        (td / ".untracked-before").write_text("")
        (repo / "reports").mkdir()
        return repo

    def commit(repo):
        output = run(repo, "bash", str(runner), "commit-ticket-test",
                     "--mission", "m-001", "--ticket", "t-001", "ticket output")
        print(output, end="", flush=True)
        return output

    selected = os.environ.get("LCARS_IGNORED_CASE")
    passed = 0
    if selected in (None, "1"):
        repo = fixture("ignored")
        (repo / "reports/convert-sheets.mjs").write_text("sprite conversion\n")
        output = commit(repo)
        assert "reports/convert-sheets.mjs" in output, output
        assert ".gitignore:4:reports/*" in output, output
        assert "produced no file changes to commit" not in output, output
        assert "Move the work product to a non-ignored path" in output, output
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        assert run(repo, "git", "rev-list", "--count", "HEAD").strip() == "1"
        assert (repo / ".gitignore").read_text() == (
            "# captain's rules\n# reports are ignored except the judgment\n"
            "!reports/\nreports/*\n!reports/JUDGMENT-CALLS.html\n")
        print("PASS 1: ignored path and .gitignore:4:reports/* reported; no commit or staging")
        passed += 1

    if selected in (None, "2"):
        repo = fixture("scratch")
        cfg = repo / ".git/lcars/config.json"
        cfg.write_text('{"scratchGlobs":["reports/private/*"]}\n')
        (repo / "reports/private").mkdir()
        (repo / "reports/private/notes.txt").write_text("configured scratch\n")
        (repo / ".copilot").mkdir()
        (repo / ".copilot/session.txt").write_text("CLI scratch\n")
        output = commit(repo)
        assert output == "  ⚠ ticket t-001 produced no file changes to commit.\nCTRC=0\n", output
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        assert run(repo, "git", "rev-list", "--count", "HEAD").strip() == "1"
        print("PASS 2: configured and base scratch silent; unchanged no-changes note")
        passed += 1

    if selected in (None, "3"):
        repo = fixture("exclude")
        with (repo / ".git/info/exclude").open("a") as stream:
            stream.write("local-output.txt\n")
        (repo / "local-output.txt").write_text("work product, not scratch\n")
        output = commit(repo)
        assert "produced ignored file local-output.txt" in output, output
        assert ".git/info/exclude:" in output and ":local-output.txt" in output, output
        assert "produced no file changes to commit" not in output, output
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        print("PASS 3: non-scratch local-output.txt reported with .git/info/exclude rule")
        passed += 1

    if selected in (None, "4"):
        repo = fixture("negated")
        (repo / "reports/JUDGMENT-CALLS.html").write_text("allowed report\n")
        output = commit(repo)
        assert "produced ignored file" not in output, output
        assert output == "CTRC=0\n", output
        assert run(repo, "git", "diff", "--name-only", "HEAD^", "HEAD") == (
            "reports/JUDGMENT-CALLS.html\n")
        assert run(repo, "git", "show", "HEAD:reports/JUDGMENT-CALLS.html") == "allowed report\n"
        print("PASS 4: negated report not warned; committed normally with exact content")
        passed += 1

    if selected in (None, "5"):
        repo = fixture("mixed")
        (repo / "tracked.txt").write_text("after\n")
        (repo / "reports/convert-sheets.mjs").write_text("sprite conversion\n")
        output = commit(repo)
        assert "produced ignored file reports/convert-sheets.mjs" in output, output
        assert ".gitignore:4:reports/*" in output, output
        assert "produced no file changes to commit" not in output, output
        changed = run(repo, "git", "diff", "--name-only", "HEAD^", "HEAD")
        assert changed == "tracked.txt\n", changed
        assert run(repo, "git", "show", "HEAD:tracked.txt") == "after\n"
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        print("PASS 5: tracked.txt change committed; ignored work product still warned, not staged")
        passed += 1

    if selected in (None, "6"):
        repo = fixture("ordinary")
        (repo / "captain.txt").write_text("unrelated captain work\n")
        (repo / "reports/already.mjs").write_text("pre-existing ignored work\n")
        run(repo, "bash", str(runner), "snapshot-untracked-test",
            "--mission", "m-001", "--ticket", "t-001")
        (repo / "tracked.txt").write_text("ordinary tracked change\n")
        output = commit(repo)
        assert output == "CTRC=0\n", output
        assert run(repo, "git", "log", "-1", "--format=%B") == (
            "lcars(m-001) t-001: ticket output\n\n")
        changed = run(repo, "git", "diff", "--name-only", "HEAD^", "HEAD")
        assert changed == "tracked.txt\n", changed
        assert run(repo, "git", "show", "HEAD:tracked.txt") == "ordinary tracked change\n"
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        assert (repo / "captain.txt").read_text() == "unrelated captain work\n"
        print("PASS 6: exact existing commit message and tracked-only set; pre-existing files spared")
        passed += 1

    if selected in (None, "7"):
        repo = fixture("nothing")
        output = commit(repo)
        assert output == "  ⚠ ticket t-001 produced no file changes to commit.\nCTRC=0\n", output
        assert run(repo, "git", "rev-list", "--count", "HEAD").strip() == "1"
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        print("PASS 7: genuine no-op keeps exact no-changes note and creates no commit")
        passed += 1
    print(f"{passed} passed; 0 failed")
PY
