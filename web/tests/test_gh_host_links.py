"""S168 — the forge host the viewscreen's "view on GitHub" links must point at.

THE BUG. `web/static/board.js` built both of its issue links by concatenating a
LITERAL "https://github.com/" onto `meta.repo`. On a GitHub ENTERPRISE repo
(`*.ghe.com`) every one of those links landed on a github.com repository that
does not exist, so the captain hand-edited the host after every click. The CLI
had already been taught the enterprise host (host-adapter.sh `gh_hostname`,
lcars-common.sh `lcars_gh_web_host`); only the board had not.

THE SHAPE OF THE FIX, and why it is shaped this way:

  * The daemon does NOT re-derive the host in Python. It SHELLS the ONE existing
    implementation — `host-adapter.sh gh-host` (ADR-002: the board dispatches to
    the skill, it never reimplements the decision). LCARS already carries the
    scar of the other choice: the zero-collect phrase list lives in both
    lcars-init and run.sh and they have since drifted, leaving one surface
    honest and the other blind.
  * It is resolved ONCE for the daemon's lifetime. The server polls about once a
    second; a subprocess per tick would be a poll storm, and the origin remote
    does not change under a running daemon.
  * The field is ADDITIVE and ABSENT on github.com — `gh_hostname` returns EMPTY
    there on purpose — so a github.com board (and a board with no remote at all)
    serialises BYTE-IDENTICALLY to before this change. That is not asserted by
    eye here: the two goldens below are the literal bytes the pre-change daemon
    produced for these exact fixtures.
  * It carries a BARE HOST, not a base URL. The front end pins the `https://`
    scheme itself, so nothing the daemon says can ever BECOME the scheme, and
    the value is the same token `gh api --hostname` already consumes.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(REPO, "skills", "lcars-run", "host-adapter.sh")

# The bytes the daemon produced for the fixture below BEFORE this change, with
# the one genuinely non-deterministic field (`activeSecondsAt`, a wall clock)
# pinned. Regenerating these to make a failure go away defeats their whole
# purpose — every other user is on github.com and this payload is their board.
GOLDEN_GITHUB_COM = (
    "{\"stages\": [\"align\", \"research\", \"validate\", \"plan\", \"plan-review\", \"s"
    "chedule\", \"implement\", \"verify\", \"done\"], \"columns\": {\"align\": [], \"re"
    "search\": [], \"validate\": [], \"plan\": [], \"plan-review\": [], \"schedule\""
    ": [], \"implement\": [{\"id\": \"lcars-20260802-001\", \"issue\": 4101, \"title"
    "\": \"A mission in flight\", \"type\": \"feature\", \"engine\": null, \"stage\": "
    "\"implement\", \"awaiting\": false, \"paused\": false, \"running\": false, \"di"
    "spatched\": false, \"queued\": false, \"question\": null, \"gate\": null, \"li"
    "nked\": false, \"origin\": null, \"groundingResearch\": false, \"parentMissi"
    "on\": null, \"parentIssue\": null, \"prUrl\": null, \"prNumber\": null, \"revi"
    "ew\": null, \"reconcileStatus\": null, \"reconcileNote\": null, \"reconcileM"
    "ergeSha\": null, \"pills\": {\"cost\": null, \"reasoning\": null, \"implementa"
    "tion\": null}, \"modelMix\": null, \"progress\": {\"wave\": null, \"wavesTotal"
    "\": null, \"ticketsDone\": 0, \"ticketsTotal\": 0, \"label\": \"WAVE ?/? \\u00b"
    "7 TICKET 0/?\"}, \"tickets\": [], \"activeSeconds\": 0, \"activeSecondsAt\": "
    "0}], \"verify\": [{\"id\": \"lcars-20260802-002\", \"issue\": 4102, \"title\": \""
    "A mission awaiting review\", \"type\": \"feature\", \"engine\": null, \"stage\""
    ": \"verify\", \"awaiting\": false, \"paused\": false, \"running\": false, \"dis"
    "patched\": false, \"queued\": false, \"question\": null, \"gate\": null, \"lin"
    "ked\": false, \"origin\": null, \"groundingResearch\": false, \"parentMissio"
    "n\": null, \"parentIssue\": null, \"prUrl\": null, \"prNumber\": null, \"revie"
    "w\": null, \"reconcileStatus\": null, \"reconcileNote\": null, \"reconcileMe"
    "rgeSha\": null, \"pills\": {\"cost\": null, \"reasoning\": null, \"implementat"
    "ion\": null}, \"modelMix\": null, \"progress\": null, \"tickets\": [], \"activ"
    "eSeconds\": 0, \"activeSecondsAt\": 0}], \"done\": []}, \"missions\": [{\"id\":"
    " \"lcars-20260802-002\", \"issue\": 4102, \"title\": \"A mission awaiting rev"
    "iew\", \"type\": \"feature\", \"engine\": null, \"stage\": \"verify\", \"awaiting\""
    ": false, \"paused\": false, \"running\": false, \"dispatched\": false, \"queu"
    "ed\": false, \"question\": null, \"gate\": null, \"linked\": false, \"origin\":"
    " null, \"groundingResearch\": false, \"parentMission\": null, \"parentIssue"
    "\": null, \"prUrl\": null, \"prNumber\": null, \"review\": null, \"reconcileSt"
    "atus\": null, \"reconcileNote\": null, \"reconcileMergeSha\": null, \"pills\""
    ": {\"cost\": null, \"reasoning\": null, \"implementation\": null}, \"modelMix"
    "\": null, \"progress\": null, \"tickets\": [], \"activeSeconds\": 0, \"activeS"
    "econdsAt\": 0}, {\"id\": \"lcars-20260802-001\", \"issue\": 4101, \"title\": \"A"
    " mission in flight\", \"type\": \"feature\", \"engine\": null, \"stage\": \"impl"
    "ement\", \"awaiting\": false, \"paused\": false, \"running\": false, \"dispatc"
    "hed\": false, \"queued\": false, \"question\": null, \"gate\": null, \"linked\""
    ": false, \"origin\": null, \"groundingResearch\": false, \"parentMission\": "
    "null, \"parentIssue\": null, \"prUrl\": null, \"prNumber\": null, \"review\": "
    "null, \"reconcileStatus\": null, \"reconcileNote\": null, \"reconcileMergeS"
    "ha\": null, \"pills\": {\"cost\": null, \"reasoning\": null, \"implementation\""
    ": null}, \"modelMix\": null, \"progress\": {\"wave\": null, \"wavesTotal\": nu"
    "ll, \"ticketsDone\": 0, \"ticketsTotal\": 0, \"label\": \"WAVE ?/? \\u00b7 TIC"
    "KET 0/?\"}, \"tickets\": [], \"activeSeconds\": 0, \"activeSecondsAt\": 0}], "
    "\"meta\": {\"repo\": \"acme/widget\", \"adapter\": \"local\", \"mode\": \"read-writ"
    "e\"}}"
)
# Identical but for meta.repo, which falls back to the directory basename when
# there is no origin remote to read an owner/name out of.
GOLDEN_NO_REMOTE = GOLDEN_GITHUB_COM.replace(
    '"meta": {"repo": "acme/widget"', '"meta": {"repo": "repo"')


def build_repo(root, origin):
    """A deterministic LCARS repo fixture: a REAL git repo + two missions.

    Real git, because the host derivation reads a real origin remote — the whole
    point is that the chain from `git remote get-url origin` to the payload is
    exercised, not stubbed. Entirely offline: naming a remote never contacts it.
    """
    os.makedirs(root, exist_ok=True)
    quiet = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["git", "init", "-q", root], check=True, **quiet)
    if origin:
        subprocess.run(["git", "-C", root, "remote", "add", "origin", origin],
                       check=True, **quiet)
    md = os.path.join(root, ".git", "lcars", "missions")
    os.makedirs(md, exist_ok=True)
    with open(os.path.join(root, ".git", "lcars", "config.json"), "w") as fh:
        fh.write('{"lcarsVersion": "0.0.0", "repo": "acme/widget",'
                 ' "testCommand": "true"}\n')
    for mid, issue, title, stage in (
            ("lcars-20260802-001", 4101, "A mission in flight", "implement"),
            ("lcars-20260802-002", 4102, "A mission awaiting review", "verify")):
        d = os.path.join(md, mid)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "state.json"), "w") as fh:
            json.dump({"id": mid, "type": "feature", "title": title,
                       "stage": stage, "created": "2026-08-02T10:00:00Z",
                       "model": "claude", "githubIssue": issue,
                       "branch": "lcars/" + mid, "base": "main"}, fh)
    return root


def serialise(board):
    """The payload as bytes, with the one wall-clock field pinned."""
    for col in board.get("columns", {}).values():
        for c in col:
            if "activeSecondsAt" in c:
                c["activeSecondsAt"] = 0
    for c in board.get("missions", []):
        if "activeSecondsAt" in c:
            c["activeSecondsAt"] = 0
    return json.dumps(board, sort_keys=False)


class GhHostMetaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._n = 0

    def _repo(self, origin, name=None):
        self._n += 1
        return build_repo(os.path.join(self.tmp, name or "repo%d" % self._n),
                          origin)

    def _board(self, origin, name=None, **kw):
        return LocalAdapter(self._repo(origin, name), **kw).board()

    # -- the fix ------------------------------------------------------------
    def test_enterprise_https_remote_puts_its_host_on_meta(self):
        meta = self._board("https://github.ghe.com/acme/widget.git")["meta"]
        self.assertEqual(meta.get("ghHost"), "github.ghe.com")

    def test_enterprise_scp_remote_puts_its_host_on_meta(self):
        meta = self._board("git@github.ghe.com:acme/widget.git")["meta"]
        self.assertEqual(meta.get("ghHost"), "github.ghe.com")

    def test_a_self_hosted_forge_with_a_port_drops_the_port(self):
        # A host:port would be a perfectly plausible thing to forward, and it
        # would build a link to a git endpoint rather than the web UI.
        meta = self._board("https://git.internal.corp:8443/acme/widget.git")["meta"]
        self.assertEqual(meta.get("ghHost"), "git.internal.corp")

    def test_the_value_is_a_bare_host_not_a_url(self):
        # The front end pins the scheme; a daemon-supplied string must never be
        # able to become one.
        h = self._board("https://github.ghe.com/acme/widget.git")["meta"]["ghHost"]
        self.assertNotIn("/", h)
        self.assertNotIn(":", h)

    def test_the_explicit_override_is_honoured(self):
        env = os.environ.get("LCARS_GH_HOST")
        os.environ["LCARS_GH_HOST"] = "forge.example.com"
        try:
            meta = self._board("https://github.com/acme/widget.git")["meta"]
        finally:
            if env is None:
                del os.environ["LCARS_GH_HOST"]
            else:
                os.environ["LCARS_GH_HOST"] = env
        self.assertEqual(meta.get("ghHost"), "forge.example.com")

    # -- the regression that matters most -----------------------------------
    def test_github_com_carries_no_new_key_at_all(self):
        meta = self._board("https://github.com/acme/widget.git")["meta"]
        self.assertEqual(list(meta.keys()), ["repo", "adapter", "mode"])

    def test_github_com_payload_is_byte_identical_to_before_the_change(self):
        got = serialise(self._board("https://github.com/acme/widget.git"))
        self.assertEqual(got, GOLDEN_GITHUB_COM)

    def test_a_repo_with_no_remote_is_byte_identical_to_before_the_change(self):
        # `repo` as the directory name because with no origin to read an
        # owner/name out of, meta.repo IS the working-tree basename.
        got = serialise(self._board(None, name="repo"))
        self.assertEqual(got, GOLDEN_NO_REMOTE)

    def test_a_directory_that_is_not_a_git_repo_at_all_still_renders(self):
        root = os.path.join(self.tmp, "bare")
        os.makedirs(os.path.join(root, ".git", "lcars", "missions"))
        meta = LocalAdapter(root).board()["meta"]
        self.assertNotIn("ghHost", meta)

    # -- degradation: never a broken link, never a crash --------------------
    def test_a_missing_host_adapter_degrades_to_todays_behaviour(self):
        meta = self._board("https://github.ghe.com/acme/widget.git",
                           host_adapter_script=os.path.join(self.tmp, "nope.sh"))["meta"]
        self.assertNotIn("ghHost", meta)

    def test_a_host_adapter_that_fails_degrades_to_todays_behaviour(self):
        script = os.path.join(self.tmp, "boom.sh")
        with open(script, "w") as fh:
            fh.write("#!/usr/bin/env bash\necho nonsense\nexit 3\n")
        os.chmod(script, 0o755)
        meta = self._board("https://github.ghe.com/acme/widget.git",
                           host_adapter_script=script)["meta"]
        self.assertNotIn("ghHost", meta)

    def test_a_value_that_is_not_a_hostname_is_refused(self):
        # Defence in depth: the shell strips path and port, so this cannot come
        # out of a real remote — but the field is spliced into a URL the captain
        # clicks, and "it cannot happen upstream" is not a guarantee downstream.
        for junk in ("javascript:alert(1)", "evil.com/x", "a b", "-", ""):
            script = os.path.join(self.tmp, "junk.sh")
            with open(script, "w") as fh:
                fh.write("#!/usr/bin/env bash\nprintf '%s' %s\n"
                         % ("%s", json.dumps(junk)))
            os.chmod(script, 0o755)
            meta = self._board("https://github.ghe.com/acme/widget.git",
                               host_adapter_script=script)["meta"]
            self.assertNotIn("ghHost", meta, "accepted %r as a host" % junk)

    # -- cost: once per daemon, never per poll tick -------------------------
    def test_the_host_is_resolved_once_for_the_daemons_life(self):
        log = os.path.join(self.tmp, "calls.log")
        script = os.path.join(self.tmp, "counting.sh")
        with open(script, "w") as fh:
            fh.write("#!/usr/bin/env bash\necho call >>%s\n"
                     "printf 'github.ghe.com'\n" % json.dumps(log))
        os.chmod(script, 0o755)
        ad = LocalAdapter(self._repo("https://github.ghe.com/acme/widget.git"),
                          host_adapter_script=script)
        for _ in range(25):   # ~25 seconds of the server's poll loop
            self.assertEqual(ad.board()["meta"]["ghHost"], "github.ghe.com")
        with open(log) as fh:
            calls = [ln for ln in fh.read().splitlines() if ln]
        self.assertEqual(len(calls), 1, "shelled %d times, not once" % len(calls))

    def test_an_empty_answer_is_cached_too(self):
        # The github.com case is the COMMON one; caching only the non-empty
        # answer would leave every github.com daemon shelling out forever.
        log = os.path.join(self.tmp, "calls2.log")
        script = os.path.join(self.tmp, "counting2.sh")
        with open(script, "w") as fh:
            fh.write("#!/usr/bin/env bash\necho call >>%s\n" % json.dumps(log))
        os.chmod(script, 0o755)
        ad = LocalAdapter(self._repo("https://github.com/acme/widget.git"),
                          host_adapter_script=script)
        for _ in range(25):
            ad.board()
        with open(log) as fh:
            calls = [ln for ln in fh.read().splitlines() if ln]
        self.assertEqual(len(calls), 1, "shelled %d times, not once" % len(calls))


class ShellIsTheOneImplementationTest(unittest.TestCase):
    """The daemon and the CLI must answer this question the same way — because
    they ask the same program. Proven by driving the real script, not by reading
    the Python for the absence of a regex."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_the_daemon_agrees_with_the_shell_on_every_remote_shape(self):
        shapes = ["https://github.ghe.com/acme/widget",
                  "git@github.ghe.com:acme/widget.git",
                  "ssh://git@git.internal.corp:8443/acme/widget.git",
                  "https://github.com/acme/widget",
                  "git@github.com:acme/widget.git",
                  None]
        for i, origin in enumerate(shapes):
            root = build_repo(os.path.join(self.tmp, "r%d" % i), origin)
            shell = subprocess.run(["bash", ADAPTER, "gh-host"], cwd=root,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
            want = shell.stdout.decode().strip()
            got = LocalAdapter(root).board()["meta"].get("ghHost", "")
            self.assertEqual(got, want, "disagreed about %r" % origin)


if __name__ == "__main__":
    unittest.main()
