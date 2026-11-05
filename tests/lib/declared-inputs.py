import atexit
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path.cwd()
SCRATCH = Path(tempfile.mkdtemp(prefix="declared-inputs-"))
atexit.register(shutil.rmtree, SCRATCH)
SCRIPT = Path(os.environ.get("LCARS_RUN_SCRIPT", ROOT / "skills/lcars-run/run.sh"))
PASS = FAIL = 0


def run(args, cwd=None, env=None, good=True):
    p = subprocess.run(args, cwd=cwd, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if good and p.returncode:
        raise AssertionError(f"{args}: exit {p.returncode}\n{p.stdout}")
    return p


def fixture(name, paths):
    base = SCRATCH / ("legB-case-" + name)
    base.mkdir()
    # The stock fixture uses add -A for its own initial files. This copy stages
    # those explicitly instead; its worker shims remain PURE FAKES.
    source = Path("tests/fixtures/mkflatrepo.sh").read_text()
    fixture_script = SCRATCH / "legB-mkflatrepo.sh"
    fixture_script.write_text(source.replace("git add -A", "git add -- package.json src tests")
                             .replace('git remote add origin "$base/remote.git"',
                                      'git remote add origin "$(cd "$base/remote.git" && pwd)"'))
    run(["bash", str(fixture_script), "--dir", str(base), "--files", "1", "--sleep", "0"])
    repo = base / "repo"
    mission = repo / ".git/lcars/missions/m-001"
    state = {"id": "m-001", "stage": "schedule", "type": "feature",
             "title": "Declared inputs", "branch": "lcars/m-001", "baseBranch": "main"}
    (mission / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    ticket = {"id": "t-001", "title": "Build using inputs", "description": "Build it.",
              "acceptanceCriteria": ["It works"], "estimatedReadLoc": 10,
              "estimatedTestLoc": 10, "estimatedNewLoc": 10, "dependencies": [],
              "establishesSharedInfrastructure": False}
    if paths is not None:
        ticket["inputPaths"] = paths
    (mission / "approved-plan.json").write_text(json.dumps([ticket], indent=2))
    run(["git", "branch", "lcars/m-001"], cwd=repo)
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_RESPOND_RESUME="0",
               LCARS_RESPOND_SCRIPT=str(ROOT / "skills/lcars-respond/respond.sh"),
               LCARS_WORKER_BIN="copilot",
               PATH=str((base / "shim").resolve()) + ":" + os.environ["PATH"])
    return repo, mission, env


def schedule(repo, env, script=SCRIPT, good=True):
    return run(["bash", str(script), "schedule", "--mission", "m-001"],
               cwd=repo, env=env, good=good)


def tracked():
    repo, m, env = fixture("tracked", ["src/calc.js", "src/source.png"])
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")
    (repo / "src/source.png").write_bytes(png)
    run(["git", "add", "--", "src/source.png"], cwd=repo)
    run(["git", "commit", "-qm", "captain: supplied source PNG"], cwd=repo)
    expected = "exports.add = (a, b) => a + b + 1;\n"
    (repo / "src/calc.js").write_text(expected)
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout.strip()
    out = schedule(repo, env)
    blob = run(["git", "cat-file", "blob", "lcars/m-001:src/calc.js"], cwd=repo).stdout
    assert blob == expected, f"ticket zero did not land declared bytes: {blob!r}\n{out.stdout}"
    tip = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout.strip()
    assert before != tip
    assert json.loads((m / "state.json").read_text())["stage"] == "implement"
    artifact = json.loads((m / "ticket-zero.json").read_text())
    assert artifact["commit"] == tip and artifact["paths"] == ["src/calc.js", "src/source.png"]
    binary = subprocess.run(["git", "cat-file", "blob", "lcars/m-001:src/source.png"],
                            cwd=repo, check=True, stdout=subprocess.PIPE).stdout
    assert binary == png
    subject = run(["git", "log", "-1", "--format=%s", "lcars/m-001"], cwd=repo).stdout.strip()
    assert subject == "ticket zero: land declared inputs", subject
    assert run(["git", "branch", "--show-current"], cwd=repo).stdout.strip() == "main"
    print(f"git cat-file blob lcars/m-001:src/calc.js = {blob!r}; commit {tip}")
    print(f"git cat-file blob lcars/m-001:src/source.png = {binary!r}; binary bytes preserved")
    print(f"Commit subject: {subject}")


def symbolic_mission_ref():
    repo, m, env = fixture("symbolic-ref", ["src/calc.js"])
    run(["git", "branch", "decoy"], cwd=repo)
    run(["git", "symbolic-ref", "refs/heads/lcars/m-001", "refs/heads/decoy"], cwd=repo)
    before = run(["git", "rev-parse", "refs/heads/decoy"], cwd=repo).stdout.strip()
    expected = "exports.add = () => 348;\n"
    (repo / "src/calc.js").write_text(expected)
    out = schedule(repo, env, good=False)
    decoy = run(["git", "rev-parse", "refs/heads/decoy"], cwd=repo).stdout.strip()
    assert decoy == before, f"Symbolic mission publication moved decoy: {before} -> {decoy}\n{out.stdout}"
    tip = run(["git", "rev-parse", "refs/heads/lcars/m-001"], cwd=repo).stdout.strip()
    if out.returncode:
        assert tip == before and not (m / "ticket-zero.json").exists(), out.stdout
        print("Symbolic mission publication refused; decoy and mission unchanged:", out.stdout.strip())
    else:
        assert tip != before
        assert run(["git", "symbolic-ref", "-q", "refs/heads/lcars/m-001"],
                   cwd=repo, good=False).returncode == 1
        assert run(["git", "cat-file", "blob", "lcars/m-001:src/calc.js"], cwd=repo).stdout == expected
        assert json.loads((m / "ticket-zero.json").read_text())["commit"] == tip
        assert json.loads((m / "state.json").read_text())["stage"] == "implement"
        print(f"Symbolic mission ref replaced by ticket zero {tip}; decoy unchanged at {decoy}")


def moved_mission_ref():
    repo, m, env = fixture("moved-ref", ["src/calc.js"])
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout.strip()
    blob = run(["git", "cat-file", "blob", "lcars/m-001:src/calc.js"], cwd=repo).stdout
    (repo / "src/calc.js").write_text("exports.add = () => 348;\n")
    git = repo.parent / "shim/racing-git"
    git.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ "${3-}" == commit-tree ]]; then
  moved=$(git -C "$2" commit-tree 'HEAD^{tree}' -p refs/heads/lcars/m-001 -m "captain: advance mission branch")
  git -C "$2" update-ref --no-deref refs/heads/lcars/m-001 "$moved"
fi
exec git "$@"
""")
    git.chmod(0o755)
    env["LCARS_GIT_BIN"] = str(git)
    out = schedule(repo, env, good=False)
    assert out.returncode != 0 and "but expected" in out.stdout, out.stdout
    assert before in out.stdout, out.stdout
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout.strip() != before
    assert run(["git", "log", "-1", "--format=%s", "lcars/m-001"],
               cwd=repo).stdout.strip() == "captain: advance mission branch"
    assert run(["git", "cat-file", "blob", "lcars/m-001:src/calc.js"], cwd=repo).stdout == blob
    assert not (m / "ticket-zero.json").exists() and not list(m.glob("ticket-zero-index-*"))
    assert json.loads((m / "state.json").read_text())["stage"] == "schedule"
    print("Compare-and-swap refused a moved Mission branch; captain's commit preserved:", out.stdout.strip())


def new_input():
    repo, m, env = fixture("new", ["src/input.txt"])
    expected = "captain supplied source\n"
    (repo / "src/input.txt").write_text(expected)
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout
    out = schedule(repo, env)
    state = json.loads((m / "state.json").read_text())
    assert state["stage"] == "schedule" and state.get("awaitingHuman") is True, out.stdout
    question = json.loads((m / "pending.json").read_text())["questions"][0]
    assert "src/input.txt" in question and "approve" in question.lower()
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout == before
    assert not run(["git", "diff", "--cached", "--name-only"], cwd=repo).stdout
    assert not (m / "waves.json").exists()
    print("Gate:", question)
    respond = ROOT / "skills/lcars-respond/respond.sh"
    run(["bash", str(respond), "answer", "--mission", "m-001",
         "--answer", "no"], cwd=repo, env=env)
    schedule(repo, env)
    assert json.loads((m / "state.json").read_text()).get("awaitingHuman") is True
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout == before
    run(["bash", str(respond), "answer", "--mission", "m-001",
         "--answer", "approve"], cwd=repo, env=env)
    assert not json.loads((m / "state.json").read_text()).get("awaitingHuman")
    schedule(repo, env)
    blob = run(["git", "cat-file", "blob", "lcars/m-001:src/input.txt"], cwd=repo).stdout
    assert blob == expected
    assert json.loads((m / "state.json").read_text())["stage"] == "implement"
    print(f"git cat-file blob lcars/m-001:src/input.txt = {blob!r}")


def ignored_input():
    repo, m, env = fixture("ignored", ["src/secret.dat"])
    (repo / "src/secret.dat").write_text("ignored source\n")
    # Approval cannot bypass an ignore rule added while the captain answered.
    schedule(repo, env)
    (repo / ".gitignore").write_bytes(b"# captain owned\n*.dat\n")
    run(["git", "add", "--", ".gitignore"], cwd=repo)
    run(["git", "commit", "-qm", "captain: ignore data"], cwd=repo)
    ignore_before = (repo / ".gitignore").read_bytes()
    branch_before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout
    run(["bash", str(ROOT / "skills/lcars-respond/respond.sh"), "answer",
         "--mission", "m-001", "--answer", "approve"], cwd=repo, env=env)
    out = schedule(repo, env, good=False)
    assert out.returncode != 0, out.stdout
    assert "src/secret.dat" in out.stdout and "*.dat" in out.stdout and ".gitignore" in out.stdout
    assert (repo / ".gitignore").read_bytes() == ignore_before
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout == branch_before
    assert not run(["git", "diff", "--cached", "--name-only"], cwd=repo).stdout
    assert json.loads((m / "state.json").read_text())["stage"] == "schedule"
    print(out.stdout.strip(), "; .gitignore bytes unchanged after approval")


def missing_input():
    repo, m, env = fixture("missing", ["src/calc.js", "src/missing.txt"])
    (repo / "src/calc.js").write_text("changed but must not stage\n")
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout
    out = schedule(repo, env, good=False)
    assert out.returncode != 0
    assert "src/missing.txt" in out.stdout and "does not exist" in out.stdout, out.stdout
    assert not run(["git", "diff", "--cached", "--name-only"], cwd=repo).stdout
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout == before
    assert not list(m.glob("ticket-zero-index-*")) and not (m / "ticket-zero.json").exists()
    assert not (m / "pending.json").exists()
    print(out.stdout.strip(), "; no paths staged, no commit")


def only_declared():
    repo, m, env = fixture("scope", ["src/input[1].txt"])
    (repo / "src/input[1].txt").write_text("only declared\n")
    (repo / "src/input1.txt").write_text("pathspec lookalike\n")
    (repo / "src/captain-notes.txt").write_text("unrelated\n")
    (repo / "src/calc.js").write_text("captain staged edit\n")
    run(["git", "add", "--", "src/calc.js"], cwd=repo)
    index_before = run(["git", "write-tree"], cwd=repo).stdout
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout.strip()
    schedule(repo, env)
    run(["bash", str(ROOT / "skills/lcars-respond/respond.sh"), "answer",
         "--mission", "m-001", "--answer", "approve"], cwd=repo, env=env)
    schedule(repo, env)
    changed = run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r",
                   before, "lcars/m-001"], cwd=repo).stdout
    assert changed == "src/input[1].txt\n", changed
    assert run(["git", "write-tree"], cwd=repo).stdout == index_before
    untracked = run(["git", "ls-files", "--others", "--exclude-standard"], cwd=repo).stdout
    assert "src/captain-notes.txt\n" in untracked and "src/input1.txt\n" in untracked
    assert run(["git", "cat-file", "blob", "lcars/m-001:src/input[1].txt"], cwd=repo).stdout == "only declared\n"
    print("Only src/input[1].txt landed; unrelated untracked files and pre-staged index unchanged")


def no_inputs():
    repo, m, env = fixture("none", None)
    context = repo / ".git/lcars/context"
    context.mkdir()
    (context / "context-pack.md").write_text("# Flat JS fixture\n")
    shutil.copyfile("tests/fixtures/declared-input-worker.py", repo.parent / "shim/copilot")
    (repo.parent / "shim/copilot").chmod(0o755)
    parent = SCRATCH / "legB-parent-skills/lcars-run/run.sh"
    if not parent.exists():
        shutil.copytree("skills", SCRATCH / "legB-parent-skills")
        parent.write_text(run(["git", "show", "HEAD:skills/lcars-run/run.sh"]).stdout)
    backup = repo.parent / "repo-backup"
    shutil.copytree(repo, backup)
    old_schedule = schedule(repo, env, parent).stdout
    old_waves = (m / "waves.json").read_bytes()
    old_impl = run(["bash", str(parent), "implement", "--mission", "m-001"],
                   cwd=repo, env=env, good=False)
    # Restore this explicitly-owned fixture at the SAME path, making output
    # comparison byte-for-byte, not a path-normalized approximation.
    shutil.rmtree(repo)
    shutil.copytree(backup, repo)
    new_schedule = schedule(repo, env).stdout
    new_waves = (m / "waves.json").read_bytes()
    new_impl = run(["bash", str(SCRIPT), "implement", "--mission", "m-001"],
                   cwd=repo, env=env, good=False)
    assert old_schedule == new_schedule, (old_schedule, new_schedule)
    assert old_waves == new_waves
    assert old_impl.returncode == new_impl.returncode and old_impl.stdout == new_impl.stdout, (old_impl.stdout, new_impl.stdout)
    assert new_impl.returncode == 0
    assert json.loads((m / "state.json").read_text())["stage"] == "verify", new_impl.stdout
    assert not json.loads((m / "state.json").read_text()).get("awaitingHuman")
    assert not (m / "ticket-zero.json").exists()
    assert "Ticket zero" not in new_schedule and "ticket zero" not in new_impl.stdout
    (SCRATCH / "legB-control-schedule-parent.log").write_text(old_schedule)
    (SCRATCH / "legB-control-schedule-tip.log").write_text(new_schedule)
    (SCRATCH / "legB-control-implement-parent.log").write_text(old_impl.stdout)
    (SCRATCH / "legB-control-implement-tip.log").write_text(new_impl.stdout)
    print(f"Parent/tip Schedule ({len(new_schedule)} bytes), waves.json and Implement "
          f"({len(new_impl.stdout)} bytes, exit {new_impl.returncode}) byte-identical; fake worker")


def plan_contract():
    repo, m, env = fixture("plan", None)
    state = json.loads((m / "state.json").read_text())
    state["stage"] = "plan"
    (m / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    plan = json.loads((m / "approved-plan.json").read_text())
    plan[0]["rationale"] = "A cohesive slice."
    plan[0]["inputPaths"] = "src/input.txt"
    path = m / "candidate.json"
    path.write_text(json.dumps(plan, indent=2))
    out = run(["bash", str(SCRIPT), "plan-save", "--mission", "m-001",
               "--plan", str(path.resolve())], cwd=repo, env=env, good=False)
    assert out.returncode != 0 and "inputPaths" in out.stdout, out.stdout
    assert "inputPaths" in (m / ".plan-reject-note").read_text()
    plan[0]["inputPaths"] = ["src/input.txt"]
    path.write_text(json.dumps(plan, indent=2))
    run(["bash", str(SCRIPT), "plan-save", "--mission", "m-001",
         "--plan", str(path.resolve())], cwd=repo, env=env)
    assert json.loads((m / "plan.json").read_text())[0]["inputPaths"] == ["src/input.txt"]
    print("Plan rejects a non-array with actionable retry note; valid inputPaths survives Plan save")


def no_input_lock():
    repo, m, env = fixture("no-lock", None)
    lock = repo / ".git/lcars/replay.lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    p = subprocess.Popen(["bash", str(SCRIPT), "schedule", "--mission", "m-001"],
                         cwd=repo, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=3)
        assert p.returncode == 0, out
        assert json.loads((m / "state.json").read_text())["stage"] == "implement"
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        raise AssertionError("No-input Schedule waited on a NEW ticket-zero lock")
    finally:
        (lock / "pid").unlink()
        lock.rmdir()
    print("No-input Schedule bypassed the ticket-zero mutex")


def symlink_input():
    repo, m, env = fixture("symlink", ["src/link.js"])
    (repo / "src/link.js").symlink_to("calc.js")
    out = schedule(repo, env, good=False)
    assert out.returncode != 0 and "symlink" in out.stdout, out.stdout
    assert not (m / "ticket-zero.json").exists()
    print("Symlink input refused rather than copying its target as a regular file")


def repeated_schedule():
    repo, m, env = fixture("repeat", ["src/input.txt"])
    (repo / "src/input.txt").write_text("approved bytes\n")
    schedule(repo, env)
    run(["bash", str(ROOT / "skills/lcars-respond/respond.sh"), "answer",
         "--mission", "m-001", "--answer", "approve"], cwd=repo, env=env)
    schedule(repo, env)
    before = run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout
    state = json.loads((m / "state.json").read_text())
    state["stage"] = "schedule"
    (m / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    schedule(repo, env)
    assert run(["git", "rev-parse", "lcars/m-001"], cwd=repo).stdout == before, "Schedule landed ticket zero twice"
    assert not json.loads((m / "state.json").read_text()).get("awaitingHuman")
    print("Re-entering Schedule reused already-landed ticket zero")


def checked_out_branch():
    repo, m, env = fixture("checked-out", ["src/calc.js"])
    run(["git", "switch", "-q", "lcars/m-001"], cwd=repo)
    (repo / "src/calc.js").write_text("exports.add = () => 99;\n")
    (repo / "package.json").write_text('{"private":true,"captain":"staged"}\n')
    run(["git", "add", "--", "package.json"], cwd=repo)
    staged = run(["git", "diff", "--cached", "--", "package.json"], cwd=repo).stdout
    (repo / "src/captain.txt").write_text("unrelated\n")
    schedule(repo, env)
    assert run(["git", "diff", "--cached", "--name-only"], cwd=repo).stdout == "package.json\n", "Ticket zero left a reverse staged edit in the checked-out Mission branch"
    assert run(["git", "diff", "--cached", "--", "package.json"], cwd=repo).stdout == staged
    assert not run(["git", "diff", "--name-only"], cwd=repo).stdout
    assert run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], cwd=repo).stdout == "src/calc.js\n"
    assert "src/captain.txt\n" in run(["git", "ls-files", "--others", "--exclude-standard"], cwd=repo).stdout
    print("Checked-out Mission branch landed inputs with a consistent index")


def live_landed_input():
    repo, m, env = fixture("live", ["src/source.txt"])
    expected = "S347_TICKET_ZERO_INPUT_f395a127\n"
    (repo / "src/source.txt").write_text(expected)
    schedule(repo, env)
    run(["bash", str(ROOT / "skills/lcars-respond/respond.sh"), "answer",
         "--mission", "m-001", "--answer", "approve"], cwd=repo, env=env)
    schedule(repo, env)
    blob = run(["git", "cat-file", "blob", "lcars/m-001:src/source.txt"], cwd=repo).stdout
    assert blob == expected
    wt = repo.parent / "live-worker"
    run(["git", "--git-dir=" + str(repo / ".git"), "worktree", "add",
         "-q", "--detach", str(wt), "lcars/m-001"])
    worker = run(["bash", "tests/lib/real-worker.sh", "copilot"]).stdout.splitlines()[-1]
    flags = run(["bash", "skills/lcars-run/worker-adapter.sh", "argv",
                 "copilot", "repo-write", "."], good=False).stdout.splitlines()
    assert flags[:2] == ["-p", "-s"] and flags[-2:] == ["--add-dir", "."], flags
    # No fixture env or shim PATH enters this subprocess. It is a REAL worker
    # with the unchanged adapter surface, cwd limited to the committed worktree.
    out = run([worker, "-p",
               "Read src/source.txt with a file-reading tool and return its exact "
               "contents. Do not guess, edit, delegate, or read outside this checkout.",
               *flags[1:]], cwd=wt)
    assert expected.strip() in out.stdout, out.stdout
    print(f"git cat-file blob lcars/m-001:src/source.txt = {blob!r}")
    print("REAL Copilot, unchanged repo-write adapter, no extra input grant:", out.stdout.strip())


def ignore_file_input():
    repo, m, env = fixture("ignore-file", [".gitignore"])
    (repo / ".gitignore").write_bytes(b"# captain owned\ncaptain-only/\n")
    before = (repo / ".gitignore").read_bytes()
    out = schedule(repo, env, good=False)
    assert out.returncode != 0 and ".gitignore" in out.stdout, out.stdout
    assert (repo / ".gitignore").read_bytes() == before
    assert not (m / "pending.json").exists()
    print("Captain's .gitignore cannot be declared as a ticket-zero input")


def directory_input():
    repo, m, env = fixture("directory", ["src"])
    out = schedule(repo, env, good=False)
    assert out.returncode != 0 and "regular file" in out.stdout and "'src'" in out.stdout, out.stdout
    assert not (m / "pending.json").exists()
    assert not run(["git", "diff", "--cached", "--name-only"], cwd=repo).stdout
    print("Directory declaration refused before staging or approval")


CASES = {"1": tracked, "2": new_input, "3": ignored_input, "4": missing_input,
         "5": only_declared, "6": no_inputs, "plan": plan_contract, "no-lock": no_input_lock,
         "symlink": symlink_input, "repeat": repeated_schedule, "checked-out": checked_out_branch,
         "ignore-file": ignore_file_input, "directory": directory_input,
         "symbolic-ref": symbolic_mission_ref, "moved-ref": moved_mission_ref}
if sys.argv[1:] == ["live"]:
    CASES = {"live": live_landed_input}
for key in sys.argv[1:] or CASES:
    try:
        CASES[key]()
        PASS += 1
        print(f"PASS behavior {key}")
    except (AssertionError, OSError, ValueError) as e:
        FAIL += 1
        print(f"FAIL behavior {key}: {e}")
print(f"{PASS} passed, {FAIL} failed")
sys.exit(bool(FAIL))
