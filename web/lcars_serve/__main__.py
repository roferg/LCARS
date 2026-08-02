"""`python3 -m lcars_serve` — start the LCARS Kanban daemon.

Adapter selection (ADR-003): defaults to the LOCAL adapter (reads `.git/lcars`);
set `--adapter github` (or `LCARS_SERVE_ADAPTER=github`) for the GitHub-only
read mode a hosted view-only build would use. The renderer/front end is the same
either way — it depends only on the board shape.

Write layer (ADR-006, S68): the LOCAL adapter daemon also serves the operator
POST endpoints (file / start / pause / resume / respond / verify / log), which
dispatch to the `lcars` skill scripts. The GitHub / view-only daemon is built
with NO write layer (and `--read-only` forces it off for the local adapter too),
so the read/render path keeps working with the GitHub adapter alone.

The ENTER-the-interface launcher: `--open` (`lcars viewscreen --open`) boots the
daemon on a free port (use `--port 0`), prints the URL, and opens the system
browser. Auto-open is guarded by `LCARS_SERVE_NO_OPEN` so scripts/tests never
spawn a browser; plain `lcars viewscreen` stays headless. (`lcars serve` is a
power alias for the same launcher; the `LCARS_SERVE_*` env names are unchanged.)

Stdlib only; no pip/npm/build step.
"""
import argparse
import os
import sys
import threading
import webbrowser

from .local_adapter import LocalAdapter
from .github_adapter import GitHubAdapter
from .server import make_server
from .actions import build_actions, LogFacts
from .version_check import VersionChecker


def resolve_check_script(env=None):
    """Locate skills/lcars-version/check.sh for the daemon's version banner.

    Env override first (LCARS_VERSION_CHECK_BIN — the same seam run.sh + the
    write layer use), else this clone's in-repo copy (web/ → repo/skills/…),
    else the installed symlink under ~/.claude. Returns a path (may not exist;
    VersionChecker degrades to None when it can't run).
    """
    env = env if env is not None else os.environ
    override = env.get("LCARS_VERSION_CHECK_BIN")
    if override:
        return override
    repo_root = os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    in_repo = os.path.join(repo_root, "skills", "lcars-version", "check.sh")
    if os.path.isfile(in_repo):
        return in_repo
    home = env.get("HOME", os.path.expanduser("~"))
    return os.path.join(home, ".claude", "skills", "lcars-version", "check.sh")


def build_adapter(kind, repo_root, gh_bin, repo, read_only=False):
    if kind == "github":
        # the github adapter is always view-only (meta.mode = read-only).
        return GitHubAdapter(gh_bin=gh_bin, repo=repo)
    # the local adapter is told whether the write layer is active so meta.mode
    # reflects the daemon's true read/write posture (S70-A).
    return LocalAdapter(repo_root, read_only=read_only)


def build_log_facts(kind, repo_root):
    """The READ-ONLY Mission-Log durable-facts reader, or None (S163 r4, D3).

    Wired for the LOCAL adapter only. Round 3 made "this parent's Go was
    dispatched" and "this batch left a bug unfiled" durable files under
    `.git/lcars/missions/<id>/`, so a board with no write layer can read them and
    tell the same story as the read-write board about the same repo.

    The GITHUB adapter gets NOTHING here, deliberately: it reads issues + labels
    over the network and cannot see a local `.git/lcars/` at all. Round 1 already
    refused a children-derived reading on `meta.adapter === "github"` for exactly
    this reason — a view that starts claiming facts it has no access to is worse
    than one that says less.
    """
    if kind != "local":
        return None
    return LogFacts(repo_root)


def should_open(open_flag, env=None):
    """Auto-open the browser ONLY when --open was passed AND not suppressed.

    LCARS_SERVE_NO_OPEN (any non-empty value) hard-suppresses the open so tests
    and headless scripts never spawn a browser. Plain `lcars viewscreen` (no
    --open) stays headless regardless.
    """
    env = env if env is not None else os.environ
    if not open_flag:
        return False
    if env.get("LCARS_SERVE_NO_OPEN"):
        return False
    return True


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(prog="lcars viewscreen",
                                 description="LCARS Kanban board daemon "
                                             "(the bridge viewscreen).")
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
    ap.add_argument("--open", action="store_true",
                    default=bool(os.environ.get("LCARS_SERVE_OPEN")),
                    help="open the board in the system browser once it is up "
                         "(suppressed by LCARS_SERVE_NO_OPEN)")
    ap.add_argument("--read-only", action="store_true",
                    default=bool(os.environ.get("LCARS_SERVE_READ_ONLY")),
                    help="serve the read/render path only — no write endpoints")
    args = ap.parse_args(argv)

    # The write layer is a LOCAL-BRIDGE concern (ADR-006). It is active ONLY for
    # the local adapter and only when --read-only is not set; the github /
    # view-only daemon (and an explicit --read-only) runs with no Actions, so
    # every POST is declined and the GET path is untouched.
    writes_active = (args.adapter == "local" and not args.read_only)

    adapter = build_adapter(args.adapter, args.repo_root, args.gh_bin,
                            args.gh_repo, read_only=not writes_active)

    actions = None
    if writes_active:
        actions = build_actions(
            repo_root=args.repo_root,
            worker_bin=os.environ.get("LCARS_WORKER_BIN"),
            gh_bin=args.gh_bin)

    # S130: the version-banner provider. Adapter-neutral — it shows on BOTH the
    # local and github/view-only builds (the UPDATE BUTTON is LOCAL-only; the
    # read-only 403 guard blocks its POST on view-only). check.sh runs in
    # cache/report mode ONLY (never a fetch storm: S129's stamp-file throttle +
    # the checker's in-process TTL memo bound it; a subprocess timeout means a
    # wedged git never blocks board serving). Disabled by LCARS_VERSION_CHECK=0.
    version_provider = None
    if os.environ.get("LCARS_VERSION_CHECK") != "0":
        # pass the checker OBJECT (not the bound method) so the server can also
        # invalidate its memo after an /api/update (banner clears promptly).
        version_provider = VersionChecker(
            repo_root=args.repo_root,
            check_script=resolve_check_script(),
            gh_bin=args.gh_bin)

    # S163 fix round 4 (D3): the view-only LOCAL board reads the durable
    # Mission-Log records so it stops contradicting the read-write board about
    # the same repo. Only used when there is no write layer (see make_server).
    log_facts = None if actions is not None else build_log_facts(args.adapter,
                                                                 args.repo_root)

    httpd = make_server(adapter, host=args.host, port=args.port,
                        poll_interval=args.poll_interval, actions=actions,
                        version_provider=version_provider,
                        log_facts=log_facts)
    bound = httpd.server_address
    url = "http://%s:%d/" % (bound[0], bound[1])
    mode = "read-only" if actions is None else "read+write"
    sys.stderr.write(
        "LCARS viewscreen — %s adapter (%s) — %s  (Ctrl-C to stop)\n"
        % (adapter.name, mode, url))
    sys.stderr.flush()

    # The ENTER-the-interface auto-open. Guarded so tests never spawn a browser.
    if should_open(args.open):
        # open AFTER the server is serving so the first GET succeeds. Fire it on
        # a short timer thread; webbrowser is best-effort (never blocks/raises).
        def _open():
            try:
                webbrowser.open(url)
            except Exception:
                pass
        threading.Timer(0.3, _open).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nLCARS viewscreen stopped.\n")
    finally:
        httpd.shutdown()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
