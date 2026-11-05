"""Land Plan's declared input files using an isolated index, never the captain's."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


class Refusal(Exception):
    pass


def main():
    repo, planfile, mission, branch = sys.argv[1:5]
    git = os.environ.get("LCARS_GIT_BIN", "git")

    def call(*args, env=None):
        p = subprocess.run([git, "-C", repo, *args], env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode:
            raise Refusal(f"git {' '.join(args)}: {p.stderr.strip()}")
        return p.stdout.strip()

    plan = json.loads(Path(planfile).read_text())
    if not isinstance(plan, list):
        raise Refusal("plan must be an array of tickets")
    paths = []
    for ticket in plan:
        if not isinstance(ticket, dict):
            raise Refusal("each plan ticket must be an object")
        values = ticket.get("inputPaths", [])
        if not isinstance(values, list):
            raise Refusal(f"ticket {ticket.get('id')}: inputPaths must be an array")
        for path in values:
            if (not isinstance(path, str) or not path or path.startswith(("/", "~"))
                    or "\\" in path or ":" in path
                    or any(p in ("", ".", "..", ".git", ".gitignore") for p in path.split("/"))
                    or any(ord(c) < 32 for c in path)):
                raise Refusal(f"ticket {ticket.get('id')}: unsafe input path {path!r}")
            if path not in paths:
                paths.append(path)
    if not paths:
        return
    if sys.argv[5:] == ["validate"]:
        return
    for path in paths:
        node = Path(repo)
        for part in path.split("/"):
            node /= part
            if node.is_symlink():
                raise Refusal(f"declared input '{path}' traverses a symlink — nothing staged")
        if not (Path(repo) / path).exists():
            raise Refusal(f"declared input '{path}' does not exist — nothing staged")
        if not (Path(repo) / path).is_file():
            raise Refusal(f"declared input '{path}' is not a regular file — nothing staged")
    if sys.argv[5:] == ["paths"]:
        print("\n".join(paths))
        return
    if not branch:
        raise Refusal("declared inputs require a recorded Mission branch")
    old = call("rev-parse", "--verify", f"refs/heads/{branch}")
    current = call("rev-parse", "--abbrev-ref", "HEAD")
    if current != branch:
        for block in call("worktree", "list", "--porcelain").split("\n\n"):
            if f"\nbranch refs/heads/{branch}" in block:
                raise Refusal(f"Mission branch '{branch}' is checked out elsewhere — "
                              "run Schedule in that checkout before landing inputs")
    receipt = Path(mission, "ticket-zero.json")
    if receipt.exists():
        landed = json.loads(receipt.read_text())
        if (not isinstance(landed, dict) or not isinstance(landed.get("commit"), str)
                or not isinstance(landed.get("paths"), list)):
            raise Refusal("ticket-zero.json is corrupt — inspect it before resuming Schedule")
        call("merge-base", "--is-ancestor", landed["commit"], old)
        if landed["paths"] == paths:
            same = True
            for path in paths:
                entry = call("ls-tree", old, "--", f":(literal){path}").split()
                blob = call("hash-object", f"--path={path}", "--", path)
                mode = "100755" if os.access(Path(repo) / path, os.X_OK) else "100644"
                if len(entry) < 3 or entry[:3] != [mode, "blob", blob]:
                    same = False
            if same:
                return
    new = [path for path in paths if not call("ls-files", "--", f":(literal){path}")]
    if new:
        listed = ", ".join(f"{path} (blob {call('hash-object', f'--path={path}', '--', path)})"
                           for path in new)
        question = (f"Ticket zero needs approval to commit NEW input paths: {listed}. "
                    "Reply 'approve' to land only these declared files; any other answer "
                    "leaves them uncommitted. LCARS will not change .gitignore or "
                    "force-add ignored files.")
        answers = Path(mission, "answers.json")
        answer = json.loads(answers.read_text()) if answers.exists() else {}
        approved = (answer.get("stage") == "schedule"
                    and answer.get("questions") == [question]
                    and answer.get("answer", "").strip().lower() == "approve")
        if not approved:
            Path(mission, "ticket-zero-question.txt").write_text(question + "\n")
            return 3
    fd, index = tempfile.mkstemp(prefix="ticket-zero-index-", dir=mission)
    os.close(fd)
    os.unlink(index)  # read-tree needs an absent index, not an empty file
    env = dict(os.environ, GIT_INDEX_FILE=os.path.abspath(index))
    try:
        call("read-tree", old, env=env)
        for path in paths:
            blob = call("hash-object", "-w", f"--path={path}", "--", path)
            mode = "100755" if os.access(Path(repo) / path, os.X_OK) else "100644"
            call("update-index", "--add", "--cacheinfo", mode, blob, path, env=env)
        tree = call("write-tree", env=env)
        if current == branch:
            if call("rev-parse", "HEAD") != old:
                raise Refusal("Mission branch moved while preparing ticket zero — nothing committed")
            call("--literal-pathspecs", "add", "--", *paths)
            call("--literal-pathspecs", "commit", "--only", "--allow-empty", "-m",
                 "ticket zero: land declared inputs", "--", *paths)
            commit = call("rev-parse", "HEAD")
        else:
            commit = call("commit-tree", tree, "-p", old, "-m",
                          "ticket zero: land declared inputs")
            call("update-ref", f"refs/heads/{branch}", commit, old)
        Path(mission, "ticket-zero.json").write_text(
            json.dumps({"commit": commit, "paths": paths}, indent=2) + "\n")
        print(f"  Ticket zero: committed {len(paths)} declared input(s) on {branch} @ {commit}.")
    finally:
        if os.path.exists(index):
            os.unlink(index)


try:
    sys.exit(main() or 0)
except (Refusal, OSError, ValueError) as e:
    print(f"lcars run: declared inputs refused: {e}", file=sys.stderr)
    sys.exit(1)
