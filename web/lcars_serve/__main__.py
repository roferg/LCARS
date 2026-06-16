"""`python3 -m lcars_serve` — start the read-only LCARS Kanban daemon.

Adapter selection (ADR-003): defaults to the LOCAL adapter (reads `.git/lcars`);
set `--adapter github` (or `LCARS_SERVE_ADAPTER=github`) for the GitHub-only
read mode a hosted view-only build would use. The renderer/front end is the same
either way — it depends only on the board shape.

Stdlib only; no pip/npm/build step.
"""
import argparse
import os
import sys

from .local_adapter import LocalAdapter
from .github_adapter import GitHubAdapter
from .server import make_server


def build_adapter(kind, repo_root, gh_bin, repo):
    if kind == "github":
        return GitHubAdapter(gh_bin=gh_bin, repo=repo)
    return LocalAdapter(repo_root)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(prog="lcars serve",
                                 description="Read-only LCARS Kanban board daemon.")
    ap.add_argument("--host", default=os.environ.get("LCARS_SERVE_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("LCARS_SERVE_PORT", "8765")))
    ap.add_argument("--adapter",
                    default=os.environ.get("LCARS_SERVE_ADAPTER", "local"),
                    choices=["local", "github"],
                    help="read backend: local (.git/lcars) or github (issues+labels)")
    ap.add_argument("--repo-root",
                    default=os.environ.get("LCARS_SERVE_REPO_ROOT", os.getcwd()),
                    help="working tree whose .git/lcars the local adapter reads")
    ap.add_argument("--gh-bin", default=os.environ.get("LCARS_GH_BIN", "gh"))
    ap.add_argument("--gh-repo", default=os.environ.get("LCARS_SERVE_GH_REPO"))
    ap.add_argument("--poll-interval", type=float,
                    default=float(os.environ.get("LCARS_SERVE_POLL", "1.0")),
                    help="live-channel state-change poll interval (seconds)")
    args = ap.parse_args(argv)

    adapter = build_adapter(args.adapter, args.repo_root, args.gh_bin, args.gh_repo)
    httpd = make_server(adapter, host=args.host, port=args.port,
                        poll_interval=args.poll_interval)
    bound = httpd.server_address
    sys.stderr.write(
        "LCARS serve — %s adapter — http://%s:%d/  (Ctrl-C to stop)\n"
        % (adapter.name, bound[0], bound[1]))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nLCARS serve stopped.\n")
    finally:
        httpd.shutdown()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
