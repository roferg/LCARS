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
import time

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

    def fixture(name, extra_ignore=""):
        repo = base / name
        repo.mkdir()
        run(repo, "git", "init", "-q", "-b", "main")
        run(repo, "git", "config", "user.email", "test@example.com")
        run(repo, "git", "config", "user.name", "Test")
        (repo / ".gitignore").write_text(
            "# captain's rules\n# reports are ignored except the judgment\n"
            "!reports/\nreports/*\n!reports/JUDGMENT-CALLS.html\n" + extra_ignore)
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

    if selected in (None, "8"):
        repo = fixture("bulk", "node_modules/\n")
        (repo / "node_modules/pkg").mkdir(parents=True)
        for number in range(200):
            (repo / f"node_modules/pkg/f{number:03}.js").write_text("dependency\n")
        (repo / "tracked.txt").write_text("after\n")
        wrapper = base / "git-meter"
        calls = base / "check-ignore-calls"
        wrapper.write_text(
            '#!/usr/bin/env bash\n'
            'for arg in "$@"; do\n'
            '  if [ "$arg" = check-ignore ]; then\n'
            f'    printf "call\\n" >> "{calls}"\n'
            '    sleep 0.02\n'
            '    break\n'
            '  fi\n'
            'done\n'
            'exec git "$@"\n')
        wrapper.chmod(0o755)
        env["LCARS_GIT_BIN"] = str(wrapper)
        started = time.monotonic()
        output = commit(repo)
        elapsed = time.monotonic() - started
        env["LCARS_GIT_BIN"] = "git"
        call_count = len(calls.read_text().splitlines())
        print(f"MEASURE bulk: {elapsed:.3f}s; {len(output.splitlines())} lines; "
              f"{call_count} check-ignore forks (20ms external-call latency)", flush=True)
        assert len(output.splitlines()) < 15, output
        assert "produced 200 ignored files" in output, output
        assert ".gitignore:6:node_modules/ matched 200 path(s)" in output, output
        assert "node_modules/pkg/f000.js" in output, output
        assert "and 198 more" in output, output
        assert "Move the work product to a non-ignored path" in output, output
        assert elapsed < 10, elapsed
        assert call_count == 1, call_count
        assert run(repo, "git", "diff", "--name-only", "HEAD^", "HEAD") == "tracked.txt\n"
        assert run(repo, "git", "show", "HEAD:tracked.txt") == "after\n"
        assert run(repo, "git", "ls-files") == ".gitignore\ntracked.txt\n"
        print("PASS 8: 200 ignored files bounded, counted, one fork under 10s; tracked change committed")
        passed += 1

    if selected in (None, "9"):
        repo = fixture("grouped")
        with (repo / ".git/info/exclude").open("a") as stream:
            stream.write("local-output-*\n")
        for number in range(3):
            (repo / f"reports/f{number}.mjs").write_text("report\n")
            (repo / f"local-output-{number}").write_text("local\n")
        output = commit(repo)
        assert "produced 6 ignored files" in output, output
        assert ".gitignore:4:reports/* matched 3 path(s)" in output, output
        assert ".git/info/exclude:" in output and ":local-output-* matched 3 path(s)" in output, output
        assert output.count("and 1 more") == 2, output
        assert len(output.splitlines()) < 15, output
        assert "Move the work product to a non-ignored path" in output, output
        assert run(repo, "git", "rev-list", "--count", "HEAD").strip() == "1"
        print("PASS 9: two rules grouped independently with source, count and capped examples")
        passed += 1

    if selected in (None, "10"):
        wrapper = base / "git-meter-fix2"
        calls = base / "check-ignore-calls-fix2"
        wrapper.write_text(
            '#!/usr/bin/env bash\n'
            'for arg in "$@"; do\n'
            '  if [ "$arg" = check-ignore ]; then\n'
            f'    printf "call\\n" >> "{calls}"\n'
            '    break\n'
            '  fi\n'
            'done\n'
            'exec git "$@"\n')
        wrapper.chmod(0o755)
        for count in (1, 1000):
            repo = fixture(f"scale-{count}", "node_modules/\n")
            (repo / "node_modules/pkg").mkdir(parents=True)
            for number in range(count):
                (repo / f"node_modules/pkg/f{number:03}.js").write_text("dependency\n")
            (repo / "tracked.txt").write_text("after\n")
            calls.write_text("")
            env["LCARS_GIT_BIN"] = str(wrapper)
            started = time.monotonic()
            output = commit(repo)
            elapsed = time.monotonic() - started
            env["LCARS_GIT_BIN"] = "git"
            call_count = len(calls.read_text().splitlines())
            print(f"MEASURE fix2: {count} files; {elapsed:.3f}s; "
                  f"{len(output.splitlines())} lines; {call_count} check-ignore forks",
                  flush=True)
            remedy = (
                "    Move the work product to a non-ignored path, or review the matched "
                "rule and commit it by hand; LCARS will not change ignore rules or "
                "force-add it.\n")
            if count == 1:
                expected = (
                    "CTRC=0\n"
                    "  ⚠ ticket t-001 produced ignored file node_modules/pkg/f000.js — NOT staged.\n"
                    "    Matched ignore rule: .gitignore:6:node_modules/\tnode_modules/pkg/f000.js\n"
                    + remedy)
            else:
                expected = (
                    "CTRC=0\n"
                    "  ⚠ ticket t-001 produced 1000 ignored files — NOT staged.\n"
                    "    .gitignore:6:node_modules/ matched 1000 path(s), e.g.\n"
                    "      node_modules/pkg/f000.js\n"
                    "      node_modules/pkg/f001.js\n"
                    "      … and 998 more\n" + remedy)
            assert output == expected, output
            assert call_count == 1, call_count
            assert run(repo, "git", "diff", "--name-only", "HEAD^", "HEAD") == "tracked.txt\n"
            assert run(repo, "git", "show", "HEAD:tracked.txt") == "after\n"
            assert elapsed < 3, f"{count} ignored files took {elapsed:.3f}s (bound 3s)"
        print("PASS 10: 1000 files under 3s; exact reports, one lookup at both scales; tracked commit")
        passed += 1

    if selected in (None, "11"):
        repo = fixture("scratch-parity")
        cfg = repo / ".git/lcars/config.json"
        cfg.write_text(json.dumps({"scratchGlobs": [
            "reports/private/*", "custom?.txt", "range[0-9].txt",
            "not[!a].txt", "caret[^a].txt", r"literal\*.txt",
            "class[[:digit:]].txt"]}))
        source = runner.read_text()
        functions = "\n".join(
            name + source.split(name, 1)[1].split("\n}\n", 1)[0] + "\n}\n"
            for name in ("scratch_globs() {", "is_scratch() {"))
        env["LCARS_CFG"] = str(cfg)
        globs = run(repo, "bash", "-c", functions + "\nscratch_globs").splitlines()
        paths = sorted(set(
            globs + [glob.replace("*", "nested/file").replace("?", "x") for glob in globs]
            + [".lcars-run-test.sh", "nested/.lcars-notes", ".copilot/session.txt",
               "nested/.claude/deep/session", "__lcarsq__/queue", "dir/__lcarsq__",
               ".test-run.py", "dir/.test-run.mjs", "reports/private/deep/file",
               "tracked.txt", "reports/public/file", "copilot/session.txt",
               "customx.txt", "range5.txt", "rangez.txt", "notb.txt", "nota.txt",
               "caretb.txt", "careta.txt", "literal*.txt", r"literal\other.txt",
               "class5.txt", "classz.txt", '"reports/private/quoted file"',
               "reports/private/space file", "reports/private/café"]))
        result = subprocess.run(
            ["bash", "-c", functions + """
while IFS= read -r path; do
  if is_scratch "$path"; then printf 'yes\\n'; else printf 'no\\n'; fi
done
"""], cwd=repo, env=env, input="\n".join(paths) + "\n",
            capture_output=True, text=True, check=True, timeout=60)
        verdicts = result.stdout.splitlines()
        assert len(verdicts) == len(paths), result.stdout
        marker = "<<'IGNORE_CANDIDATES_PY' >\"$ignore_candidates\""
        scan = source.split(marker, 1)[1].split("\nIGNORE_CANDIDATES_PY", 1)[0]
        listing = base / "parity-listing"
        listing.write_text("\n".join(paths) + "\n")
        git = base / "parity-git"
        git.write_text(f'#!/usr/bin/env bash\nexec cat "{listing}"\n')
        git.chmod(0o755)
        now = base / "parity-now"
        before = base / "parity-before"
        now.write_text("")
        before.write_text("")
        args = [str(git), str(repo), str(now), str(before), "\n".join(globs)]
        candidate_output = subprocess.run(
            ["python3", "-", *args], input=scan, cwd=repo, env=env,
            capture_output=True, text=True, check=True, timeout=60).stdout
        expected = "".join(path + "\n" for path, verdict in zip(paths, verdicts)
                           if verdict == "no")
        assert candidate_output == expected, (candidate_output, expected)
        print(f"PASS 11: in-process matcher agrees with real is_scratch on "
              f"{len(paths)} paths and all {len(globs)} real/configured globs")
        env.pop("LCARS_CFG")
        passed += 1

    if selected in (None, "12"):
        repo = fixture("quoted")
        (repo / "reports/café.mjs").write_text("pre-existing ignored\n")
        run(repo, "bash", str(runner), "snapshot-untracked-test",
            "--mission", "m-001", "--ticket", "t-001")
        (repo / "reports/space file.mjs").write_text("new ignored\n")
        (repo / "reports/naïve.mjs").write_text("new ignored\n")
        output = commit(repo)
        expected = (
            "CTRC=0\n"
            "  ⚠ ticket t-001 produced 2 ignored files — NOT staged.\n"
            "    .gitignore:4:reports/* matched 2 path(s), e.g.\n"
            '      "reports/na\\303\\257ve.mjs"\n'
            "      reports/space file.mjs\n"
            "    Move the work product to a non-ignored path, or review the matched "
            "rule and commit it by hand; LCARS will not change ignore rules or "
            "force-add it.\n")
        assert output == expected, output
        print("PASS 12: Git quoting preserved; quoted pre-existing ignored path not attributed")
        passed += 1
    print(f"{passed} passed; 0 failed")
PY
