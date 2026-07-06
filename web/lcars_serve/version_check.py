"""The daemon's version-check bridge (S130 — the viewscreen update banner).

The board grows an ADDITIVE `meta.version` block when the LCARS install is stale,
so the front end can render a themed update banner. The verdicts are NOT
recomputed here — that would let the board drift from the CLI. Instead we shell
out to the ONE shared helper, `skills/lcars-version/check.sh`, in its
machine-readable `report` mode (cache/throttle-identical to warn: no prompt, no
stdin, and the git fetch is bounded by S129's user-level stamp file).

Two guards keep the daemon honest about the walk-away principle:
  1. check.sh's stamp-file throttle bounds the real `git fetch` to once per TTL
     window — so serving the board never triggers a fetch storm.
  2. an in-process TTL memo here bounds how often we even SPAWN check.sh, so
     rapid /api/board polls / SSE ticks don't fork a subprocess each time.
  3. a hard subprocess timeout means a wedged git can never block board serving —
     on timeout we degrade to the last cached block (or None).

`block()` returns None when the install is CURRENT (no verdicts) — the caller
then omits `meta.version` entirely, so a current board is BYTE-IDENTICAL to the
pre-S130 shape and every existing web test stays green. It returns
`{"running", "remote"?, "verdicts": [...]}` when at least one verdict holds.

stdlib only; no pip/build step (ADR-007).
"""
import os
import subprocess
import threading
import time

# The verdict tokens check.sh's `report` mode emits, in the order we surface them.
_VERDICTS = ("source_behind", "repo_stale", "repo_predates", "drift")


class VersionChecker(object):
    def __init__(self, repo_root, check_script, gh_bin=None, env=None,
                 ttl=60.0, timeout=8.0, clock=time.monotonic):
        self.repo_root = repo_root
        self.check_script = check_script
        self.gh_bin = gh_bin
        self._env = env if env is not None else os.environ
        self.ttl = ttl
        self.timeout = timeout
        self._clock = clock
        self._lock = threading.Lock()
        self._cached = None      # last parsed block (dict | None)
        self._cached_at = None   # monotonic time of the last real spawn

    def invalidate(self):
        """Drop the memo so the next block() re-probes (called after an update
        so the banner clears promptly instead of lingering for the memo window)."""
        with self._lock:
            self._cached_at = None

    def block(self):
        """The additive meta.version block, or None when the install is current.

        Memoized for `ttl` seconds so board serving never spawns check.sh on a
        hot loop. Never raises — any failure degrades to None (the banner simply
        does not show); a version check must NEVER be what breaks the board.
        """
        with self._lock:
            now = self._clock()
            if (self._cached_at is not None
                    and (now - self._cached_at) < self.ttl):
                return self._cached
            block = self._probe()
            self._cached = block
            self._cached_at = now
            return block

    def _probe(self):
        if not self.check_script or not os.path.isfile(self.check_script):
            return None
        env = dict(self._env)
        # The repo being VIEWED anchors the REPO_STALE / predates verdict; the
        # source root (LCARS_REPO) is resolved by check.sh from its own path.
        env["LCARS_VERSION_CWD"] = self.repo_root or env.get("LCARS_VERSION_CWD", "")
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        try:
            proc = subprocess.run(
                ["bash", self.check_script, "report"],
                env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=self.timeout)
        except (OSError, subprocess.SubprocessError):
            # a wedged/absent git or a timeout must not block the board — degrade.
            return self._cached
        return _parse_report((proc.stdout or b"").decode("utf-8", "replace"))


def _parse_report(text):
    """Parse check.sh `report` output into the meta.version block, or None.

    Lines are KEY=VALUE: `running=`, `remote=`, `verdict=<token>`. Returns None
    when NO verdict line is present (a current install → no banner, byte-identical
    board). Verdicts are de-duplicated and ordered by _VERDICTS.
    """
    running = None
    remote = None
    stamped = None
    seen = set()
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if key == "running":
            running = val or None
        elif key == "remote":
            remote = val or None
        elif key == "stamped":
            stamped = val or None
        elif key == "verdict" and val:
            seen.add(val)
    verdicts = [v for v in _VERDICTS if v in seen]
    # any unknown/extra verdict tokens still surface (forward-compatible).
    verdicts += [v for v in sorted(seen) if v not in _VERDICTS]
    if not verdicts:
        return None
    block = {"running": running, "verdicts": verdicts}
    if remote:
        block["remote"] = remote
    # the viewed repo's stamped version (from→to on the banner); omitted for an
    # unstamped/predates repo, where the front end shows "unstamped".
    if stamped:
        block["stamped"] = stamped
    return block
