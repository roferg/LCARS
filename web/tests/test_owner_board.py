"""S190 — the visible layer: owner, avatar, and the light lock ON THE BOARD.

Three things are pinned here, in this order of importance:

  1. THE BOARD WITH NO IDENTITY IS UNCHANGED. A repo with no owner published and
     no gh must serve a payload — and render a card — BYTE-IDENTICAL to the one
     it served before this session. Proven against baselines captured from the
     pre-change tree (fixtures/s190/), not against a hand-written expectation:
     an expectation written after the fact can only ever agree with the code it
     was written from.

  2. THE SHAPE IS ADDITIVE AND ADAPTER-NEUTRAL (ADR-003). A card gains `owner`
     {login, avatarUrl} only when an owner is KNOWN; meta gains `self` {login}
     only when an identity RESOLVES. Absent, never null — the rule every additive
     key in this shape has followed since S109.

  3. THE LOOK AND THE LOCK ARE WIRED. Avatar + handle render; a mission held by
     someone else disables the card's write affordances and names the owner in
     the tooltip; a dead image degrades to the handle ALONE.

WHAT THIS FILE CANNOT SEE, and does not claim to: whether the board LOOKS right.
A projected class name is not a rendered pixel, and a dead <img> has the same box
and class as a live one (S164). The picture is proven by a human looking at real
headed Chrome at real rendered dimensions. This file proves the wiring beneath it.

No gh, no network, no model: identity comes from an env pin or a stub script, and
the published-owner cache is a plain file on disk.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve import board as board_shape  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures", "s190")
HARNESS = os.path.join(HERE, "board_owner_harness.js")
CARD_HARNESS = os.path.join(HERE, "board_card_harness.js")
NODE = shutil.which("node")

# The identity the suites act as, and the one that plays "somebody else".
ME = "roferg"
OTHER = "picard"


def _silent_ownership_stub(tmp, whoami="", owner_map=None):
    """A stand-in for skills/lcars-run/ownership.sh.

    Speaks the same three-op contract the daemon shells (whoami / owner N /
    lock-reason N) with the same posture: an unassigned mission and an
    unresolvable identity BOTH answer "not locked". `whoami=""` models gh being
    absent entirely, which is the case the byte-identity tests turn on.
    """
    owner_map = owner_map or {}
    lines = ["#!/usr/bin/env bash", 'op="${1:-}"', 'n="${2:-}"',
             'me="%s"' % whoami, 'own=""']
    for issue, login in owner_map.items():
        lines.append('[ "$n" = "%s" ] && own="%s"' % (issue, login))
    lines += [
        'case "$op" in',
        '  whoami) [ -n "$me" ] || exit 1; printf "%s" "$me" ;;',
        '  owner)  printf "%s" "$own" ;;',
        '  lock-reason)',
        '    [ -n "$own" ] || exit 1',      # unassigned never locks
        '    [ -n "$me" ]  || exit 1',      # unresolvable identity never locks
        '    [ "$own" = "$me" ] && exit 1',
        '    printf "assigned to %s — reassign it to yourself on GitHub to take command" "$own"',
        '    ;;',
        '  *) exit 2 ;;',
        'esac',
    ]
    path = os.path.join(tmp, "ownership-stub.sh")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


def publish_owner(root, issue, login, host="github.com"):
    """Write the published-owner file exactly as ownership.sh publishes it."""
    d = os.path.join(root, ".git", "lcars", "cache")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "owner-%s-%s" % (host, issue)), "w") as fh:
        if login:
            fh.write(login + "\n")
    return d


def publish_self(root, login, host="github.com"):
    """Write the whoami file exactly as S189's `lcars_whoami` publishes it —
    the file the daemon reads instead of asking the forge on a render."""
    d = os.path.join(root, ".git", "lcars", "cache")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "whoami-%s" % host), "w") as fh:
        fh.write((login or "") + "\n")
    return d


def _scrub(b):
    """activeSecondsAt is a server wall-clock stamp; it moves every run and is
    not what a byte-identity baseline is about."""
    seen = list(b.get("missions", []))
    for col in b.get("columns", {}).values():
        seen += list(col)
    for c in seen:
        if "activeSecondsAt" in c:
            c["activeSecondsAt"] = 0
    return b


class BaselineFixture(object):
    """The identity-free fixture the fixtures/s190 baselines were captured from.

    It must stay EXACTLY in step with tests/drives/s190/capture-baseline.py's
    `plant`: the whole
    point of the baseline is that the same tree is built the same way on both
    sides of the change.
    """

    @staticmethod
    def plant(root):
        fx.plant_simple(root, "m-align", stage="align", issue=101,
                        created="2026-06-01T10:00:00Z")
        fx.plant_simple(root, "m-verify", stage="verify", issue=102,
                        created="2026-06-02T10:00:00Z",
                        pr_url="https://github.com/acme/repo/pull/7",
                        pr_number="7", review="open")
        fx.plant_paused(root, "m-paused", stage="implement", issue=103)
        fx.plant_gated(root, "m-gated", issue=104)
        fx.plant_parked(root, "m-parked", issue=105)
        fx.plant_simple(root, "m-noissue", stage="plan", issue=None,
                        created="2026-06-05T10:00:00Z")


class NoIdentityIsByteIdentical(unittest.TestCase):
    """THE constraint of this session. Every other user's board has no published
    owner and (on a machine with no gh) no identity — and must be untouched."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        BaselineFixture.plant(self.tmp)
        self.adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            # gh is ABSENT: whoami answers nothing, nothing is published.
            ownership_script=_silent_ownership_stub(self.tmp, whoami=""))

    def test_board_payload_is_byte_identical_to_the_pre_change_baseline(self):
        with open(os.path.join(FIXTURES, "board-baseline.json")) as fh:
            expected = fh.read()
        got = json.dumps(_scrub(self.adapter.board()),
                         sort_keys=True, indent=2) + "\n"
        self.assertEqual(expected, got,
                         "the no-identity board payload changed; S190 is "
                         "additive and must leave it untouched")

    def test_no_card_carries_an_owner_key(self):
        for c in self.adapter.board()["missions"]:
            self.assertNotIn("owner", c,
                             "%s gained an owner key with nothing published"
                             % c["id"])

    def test_meta_carries_no_self_key_without_an_identity(self):
        self.assertNotIn("self", self.adapter.board()["meta"])

    @unittest.skipUnless(NODE, "node is required for the board.js vm harness")
    def test_every_rendered_card_is_byte_identical_to_the_pre_change_baseline(self):
        with open(os.path.join(FIXTURES, "card-dom-baseline.json")) as fh:
            expected = json.load(fh)
        for card in _scrub(self.adapter.board())["missions"]:
            fd, p = tempfile.mkstemp(suffix=".json")
            os.close(fd)
            self.addCleanup(os.unlink, p)
            with open(p, "w") as fh:
                json.dump(card, fh)
            out = subprocess.check_output([NODE, CARD_HARNESS, p])
            self.assertEqual(expected[card["id"]], json.loads(out.decode()),
                             "the rendered card for %s changed with no identity "
                             "present" % card["id"])


class OwnerOnTheBoardShape(unittest.TestCase):
    """The additive shape (ADR-003): what a card and meta gain, and when."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, "m-mine", stage="verify", issue=101,
                        created="2026-06-01T10:00:00Z")
        fx.plant_simple(self.tmp, "m-theirs", stage="verify", issue=102,
                        created="2026-06-02T10:00:00Z")
        fx.plant_simple(self.tmp, "m-nobody", stage="verify", issue=103,
                        created="2026-06-03T10:00:00Z")

    def _adapter(self, whoami=ME):
        if whoami:
            publish_self(self.tmp, whoami)
        return LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            ownership_script=_silent_ownership_stub(self.tmp, whoami=whoami))

    def _cards(self, adapter=None):
        b = (adapter or self._adapter()).board()
        return {c["id"]: c for c in b["missions"]}, b["meta"]

    def test_a_published_owner_lands_on_the_card(self):
        publish_owner(self.tmp, 101, ME)
        cards, _ = self._cards()
        self.assertEqual({"login": ME,
                          "avatarUrl": "https://github.com/%s.png?size=64" % ME},
                         cards["m-mine"]["owner"])

    def test_someone_elses_mission_carries_their_login_and_avatar(self):
        publish_owner(self.tmp, 102, OTHER)
        cards, _ = self._cards()
        self.assertEqual(OTHER, cards["m-theirs"]["owner"]["login"])
        self.assertEqual("https://github.com/%s.png?size=64" % OTHER,
                         cards["m-theirs"]["owner"]["avatarUrl"])

    def test_an_explicitly_unassigned_mission_carries_NO_owner_key(self):
        # ownership.sh publishes an EMPTY file for "nobody" — an answer, not an
        # absence. The card must carry no owner key at all (absent, not null).
        publish_owner(self.tmp, 103, "")
        cards, _ = self._cards()
        self.assertNotIn("owner", cards["m-nobody"])

    def test_a_mission_never_asked_about_carries_NO_owner_key(self):
        cards, _ = self._cards()
        self.assertNotIn("owner", cards["m-mine"])

    def test_meta_self_is_the_resolved_login(self):
        _, meta = self._cards()
        self.assertEqual({"login": ME}, meta["self"])

    def test_meta_self_is_ABSENT_when_gh_cannot_say_who_we_are(self):
        _, meta = self._cards(self._adapter(whoami=""))
        self.assertNotIn("self", meta)

    def test_LCARS_GH_USER_pins_the_identity_with_no_subprocess(self):
        # Rule 1 of lcars_whoami's own resolution order, mirrored so a pinned
        # identity costs nothing and a harness can set it.
        prev = os.environ.get("LCARS_GH_USER")
        os.environ["LCARS_GH_USER"] = "pinned"
        try:
            ad = LocalAdapter(self.tmp,
                              git_url_reader=lambda r: "git@x:acme/repo.git",
                              ownership_script="/nonexistent/ownership.sh")
            self.assertEqual({"login": "pinned"}, ad.board()["meta"]["self"])
        finally:
            if prev is None:
                os.environ.pop("LCARS_GH_USER", None)
            else:
                os.environ["LCARS_GH_USER"] = prev

    def test_a_garbage_published_value_is_ignored(self):
        # The file is a cache, and a cache is not a promise. Anything that is not
        # a login is "no answer" — never an owner, never a lock.
        publish_owner(self.tmp, 101, "https://evil.example/x")
        cards, _ = self._cards()
        self.assertNotIn("owner", cards["m-mine"])

    def _tripwire(self, marker):
        """An ownership script that RECORDS every call. Any line in the marker
        file after a board build is a subprocess a render paid for."""
        script = os.path.join(self.tmp, "tripwire.sh")
        with open(script, "w") as fh:
            fh.write('#!/usr/bin/env bash\n'
                     'echo "$*" >> "%s"\n'
                     'case "${1:-}" in whoami) printf "%s" ;; *) exit 1 ;; esac\n'
                     % (marker, ME))
        os.chmod(script, 0o755)
        return script

    def test_A_BOARD_BUILD_SHELLS_OUT_FOR_NOTHING(self):
        # THE rule this whole shape is designed around: `_meta()` and `_card()`
        # run on every board build and the server polls about once a second, so a
        # render that touched the forge — or even spawned bash — would be a
        # subprocess storm and a network dependency on the hot path. Owner AND
        # identity both come off disk.
        publish_self(self.tmp, ME)
        publish_owner(self.tmp, 101, ME)
        publish_owner(self.tmp, 102, OTHER)
        marker = os.path.join(self.tmp, "shelled")
        ad = LocalAdapter(self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
                          ownership_script=self._tripwire(marker))
        for _ in range(5):
            b = ad.board()
        self.assertFalse(os.path.exists(marker),
                         "a board build shelled out for ownership")
        # …and it still answered both questions.
        self.assertEqual({"login": ME}, b["meta"]["self"])
        self.assertEqual(OTHER, {c["id"]: c for c in b["missions"]}
                         ["m-theirs"]["owner"]["login"])

    def test_warm_self_is_the_ONE_place_that_asks_and_it_asks_once(self):
        # The startup warm is the single identity round trip in the daemon's
        # life; a second warm on a resolved identity must be free.
        publish_self(self.tmp, ME)
        marker = os.path.join(self.tmp, "shelled")
        ad = LocalAdapter(self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
                          ownership_script=self._tripwire(marker))
        self.assertEqual(ME, ad.warm_self())
        with open(marker) as fh:
            self.assertEqual(1, len(fh.read().strip().splitlines()))
        ad.warm_self()
        with open(marker) as fh:
            self.assertEqual(1, len(fh.read().strip().splitlines()))

    def test_a_STALE_whoami_file_is_not_an_identity(self):
        # The published whoami honours S189's own $LCARS_WHOAMI_TTL, so a laptop
        # that has not spoken to the forge in a very long time stops claiming to
        # know who it is rather than locking on a memory.
        publish_self(self.tmp, ME)
        prev = os.environ.get("LCARS_WHOAMI_TTL")
        os.environ["LCARS_WHOAMI_TTL"] = "1"
        try:
            path = os.path.join(self.tmp, ".git", "lcars", "cache",
                                "whoami-github.com")
            os.utime(path, (0, 0))
            ad = LocalAdapter(self.tmp,
                              git_url_reader=lambda r: "git@x:acme/repo.git",
                              ownership_script="/nonexistent/ownership.sh")
            self.assertNotIn("self", ad.board()["meta"])
        finally:
            if prev is None:
                os.environ.pop("LCARS_WHOAMI_TTL", None)
            else:
                os.environ["LCARS_WHOAMI_TTL"] = prev


class TheStylesheetMakesNoPROMISEItCannotKEEP(unittest.TestCase):
    """FIX ROUND 1, D2/D3/D6 — the cheap tripwires beside the real proof.

    THESE ARE NOT THE PROOF. Reading `board.css` as text cannot tell you what a
    browser paints — that is the whole reason round 1 shipped a
    `button[disabled]{opacity:1}` that computed as 1 and painted at .55, and a
    `.det-head .owner` rule that matched nothing at all. The proof is
    `tests/drives/s190/owner-paint.sh`: real Chrome, real daemon, the contrast
    read out of a SCREENSHOT, with a red control per defect.

    What these are for is the gap between drive runs. The drive is deliberately
    not in any automatic suite (it boots Chrome); these three lines are what
    stops the exact cured shape from walking back in unnoticed, and each one
    names the drive that would actually catch it.
    """

    CSS = os.path.normpath(os.path.join(HERE, "..", "static", "board.css"))

    def setUp(self):
        with open(self.CSS) as fh:
            raw = fh.read()
        # COMMENTS STRIPPED FIRST. This file explains itself at length — the
        # cured rules are each introduced by a paragraph that QUOTES the broken
        # shape it replaced — so a guard reading the raw text would fire on the
        # explanation of the fix. The subject here is what the browser parses.
        self.css = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)

    def test_no_opacity_group_sits_over_the_locked_controls(self):
        # An `opacity` on `.card.owned-by-other .card-ctrl` makes a compositing
        # group, and NOTHING inside a compositing group can paint brighter than
        # it. So the dim belongs on the control, never on the row above it.
        rows = re.findall(r"\.card\.owned-by-other\s+\.card-ctrl\s*\{([^}]*)\}",
                          self.css)
        for body in rows:
            self.assertNotIn("opacity", body,
                             "a row-level opacity is back over the locked "
                             "controls; anything below it cannot escape it")

    def test_no_rule_styles_an_owner_pill_in_the_detail_header(self):
        # ownerNode() is called only from cardNode(); the detail header renders
        # no owner pill, and CSS describing one reads as a feature that exists.
        self.assertNotRegex(self.css, r"\.det-head[^{,]*\.owner\b")

    def test_the_avatar_filter_is_not_gated_on_a_MOTION_preference(self):
        # A saturate/contrast/brightness treatment is colour, not motion.
        for block in re.findall(r"@media\s*\(prefers-reduced-motion[^{]*\)\s*\{"
                                r"((?:[^{}]|\{[^{}]*\})*)\}", self.css):
            if ".owner" in block:
                self.assertNotIn("filter", block,
                                 "the owner avatar's colour filter is gated on "
                                 "prefers-reduced-motion again")


class AnUnreachableForgeNeverErasesAPublishedOwner(unittest.TestCase):
    """FIX ROUND 1, D1 — at the layer that actually did the damage: the DAEMON.

    `warm_owners()` runs on every boot and calls `refresh_owner()` per active
    mission, which shells the REAL ownership.sh. Before the cure, a `gh` that
    could not be reached made `mission_owner` yield "" — indistinguishable from
    the forge answering "nobody" — and the publisher then TRUNCATED the owner
    file to zero bytes. Measured on the tester's tree: owner files of 8, 7 and
    31 bytes all became 0 the moment gh was absent, and the board forgot whose
    work was whose until something happened to ask again.

    THIS SUITE USES THE REAL SCRIPT, not `_silent_ownership_stub`. The stub
    cannot see this defect at all — it never publishes anything — and a defect
    in the publisher is exactly the thing a stubbed publisher is blind to.
    Still zero spend: `$LCARS_GH_BIN` names a binary that does not exist, which
    is what "gh is unreachable" IS on the host adapter's own terms.
    """

    OWNERSHIP = os.path.normpath(os.path.join(
        HERE, "..", "..", "skills", "lcars-run", "ownership.sh"))

    def setUp(self):
        if not os.path.isfile(self.OWNERSHIP):
            self.skipTest("ownership.sh not present in this tree")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # A REAL git repo: ownership.sh resolves its cache dir from
        # `git rev-parse --git-common-dir`, and the origin remote is what makes
        # the host key `github.com` (matching publish_owner's default).
        for cmd in (["init", "-q"],
                    ["config", "user.email", "t@t"], ["config", "user.name", "t"],
                    ["remote", "add", "origin",
                     "https://github.com/acme/repo.git"]):
            subprocess.run(["git"] + cmd, cwd=self.tmp,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        fx.plant_simple(self.tmp, "m-mine", stage="verify", issue=101,
                        created="2026-06-01T10:00:00Z")
        fx.plant_simple(self.tmp, "m-theirs", stage="verify", issue=102,
                        created="2026-06-02T10:00:00Z")
        publish_self(self.tmp, ME)
        publish_owner(self.tmp, 101, ME)
        publish_owner(self.tmp, 102, OTHER)
        self.cache = os.path.join(self.tmp, ".git", "lcars", "cache")
        self._env = {}
        # gh: a path that does not exist. The host adapter's `command -v` guard
        # turns that into rc=1 — a FAILED call, never the answer "nobody".
        self._pin("LCARS_GH_BIN", os.path.join(self.tmp, "no-such-gh"))
        # …and no env identity, so nothing short-circuits the forge path.
        self._pin("LCARS_GH_USER", None)

    def _pin(self, name, value):
        self._env[name] = os.environ.get(name)
        self.addCleanup(self._restore, name)
        if value is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = value

    def _restore(self, name):
        prev = self._env.get(name)
        if prev is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = prev

    def _adapter(self):
        return LocalAdapter(self.tmp,
                            git_url_reader=lambda r: "git@x:acme/repo.git",
                            ownership_script=self.OWNERSHIP)

    def _owner_file(self, issue):
        return os.path.join(self.cache, "owner-github.com-%d" % issue)

    def test_the_startup_warm_leaves_every_published_owner_untouched(self):
        def snap():
            out = {}
            for n in (101, 102):
                with open(self._owner_file(n)) as fh:
                    out[n] = fh.read()
            return out
        before = snap()
        self._adapter().warm_owners()
        after = snap()
        self.assertEqual(before, after,
                         "an unreachable forge rewrote the published owners")

    def test_the_board_still_names_both_owners_after_the_warm(self):
        # The promise in _published_owner's own docstring: "a daemon whose forge
        # is unreachable simply serves the board it served before this round."
        ad = self._adapter()
        ad.warm_owners()
        cards = {c["id"]: c for c in ad.board()["missions"]}
        self.assertEqual(ME, cards["m-mine"]["owner"]["login"])
        self.assertEqual(OTHER, cards["m-theirs"]["owner"]["login"])

    def test_a_mission_never_asked_about_is_still_never_asked_about(self):
        # The third state has to survive too: a failed call must not CREATE an
        # empty file, or "unknown" would silently become "the forge says nobody".
        fx.plant_simple(self.tmp, "m-new", stage="verify", issue=104,
                        created="2026-06-04T10:00:00Z")
        self._adapter().warm_owners()
        self.assertFalse(os.path.exists(self._owner_file(104)))


class AvatarUrlIsConstructed(unittest.TestCase):
    """The URL is BUILT from the login — never scraped, never read out of a body.

    A body is text a human can edit; an avatar built from it is an image LCARS
    was told to show by whoever last typed in the issue. The login comes from the
    forge's assignee list and nowhere else, and the URL is a pure function of it.
    """

    def test_url_shape(self):
        self.assertEqual("https://github.com/roferg.png?size=64",
                         board_shape.avatar_url("roferg"))

    def test_a_non_login_yields_nothing(self):
        for bad in ("", None, "not a login", "../../etc/passwd",
                    "a" * 40, "http://x/y.png", "-leading"):
            self.assertIsNone(board_shape.avatar_url(bad), repr(bad))

    def test_a_hyphenated_login_is_fine(self):
        self.assertEqual("https://github.com/some-user.png?size=64",
                         board_shape.avatar_url("some-user"))


class BothAdaptersEmitTheSameOwnerBlock(unittest.TestCase):
    """ADR-003: the front end depends on the SHAPE, never on which adapter
    served it. The github adapter reads assignees straight off the issue list it
    already fetches, so parity here costs it nothing."""

    def _gh_adapter(self, issues):
        from lcars_serve.github_adapter import GitHubAdapter
        gh = os.path.join(self.tmp, "gh")
        with open(gh, "w") as fh:
            fh.write("#!/usr/bin/env bash\ncat <<'JSON'\n%s\nJSON\n"
                     % json.dumps(issues))
        os.chmod(gh, 0o755)
        return GitHubAdapter(gh_bin=gh, repo="acme/repo")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _issue(self, number, assignees):
        return {"number": number, "title": "T", "state": "OPEN",
                "labels": [{"name": "lcars:mission"}, {"name": "lcars:align"}],
                "body": "", "comments": [], "updatedAt": "2026-06-01T00:00:00Z",
                "assignees": assignees}

    def test_an_assigned_issue_yields_the_identical_block(self):
        ad = self._gh_adapter([self._issue(101, [{"login": ME}])])
        card = ad.board()["missions"][0]
        self.assertEqual({"login": ME,
                          "avatarUrl": "https://github.com/%s.png?size=64" % ME},
                         card["owner"])

    def test_an_unassigned_issue_carries_NO_owner_key(self):
        ad = self._gh_adapter([self._issue(101, [])])
        self.assertNotIn("owner", ad.board()["missions"][0])

    def test_a_payload_with_no_assignees_field_at_all_does_not_crash(self):
        # An older gh, a partial payload, a forge that changed its mind. The
        # forge is not a promise; a read of one must never take the board down.
        issue = self._issue(101, [])
        del issue["assignees"]
        ad = self._gh_adapter([issue])
        self.assertNotIn("owner", ad.board()["missions"][0])

    def test_only_the_FIRST_assignee_is_read_never_a_list(self):
        # `mission_owner` defines ownership as "the single standing assignee" so
        # the team round can swap in an event-timeline winner by changing ONE
        # function. A reader consuming a list here would make that swap costly.
        ad = self._gh_adapter([self._issue(101, [{"login": ME},
                                                 {"login": OTHER}])])
        self.assertEqual(ME, ad.board()["missions"][0]["owner"]["login"])


def _render(mission, self_login=None, readonly=False, kill_avatar=False):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"mission": mission, "self": self_login,
                       "readonly": readonly, "killAvatar": kill_avatar}, fh)
        out = subprocess.check_output([NODE, HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _nodes(tree):
    yield tree
    for c in tree.get("children", []):
        for n in _nodes(c):
            yield n


def _find(tree, pred):
    return [n for n in _nodes(tree) if pred(n)]


def _cls(n, name):
    return name in (n.get("cls") or "").split()


def _buttons(tree):
    return _find(tree, lambda n: n["tag"] == "button")


def _ctrl_buttons(tree):
    hosts = _find(tree, lambda n: _cls(n, "card-ctrl"))
    out = []
    for h in hosts:
        out += _buttons(h)
    return out


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class CardRendersTheOwner(unittest.TestCase):
    """Behaviour 1: my own mission — avatar + handle, writes ENABLED."""

    def card(self, **kw):
        m = {"id": "m-1", "issue": 101, "title": "Add a dark mode toggle",
             "type": "feature", "stage": "align", "awaiting": False,
             "paused": False, "running": False, "dispatched": False,
             "queued": False, "linked": False, "pills": {}, "tickets": []}
        m.update(kw)
        return m

    def owner(self, login=ME):
        return {"login": login,
                "avatarUrl": "https://github.com/%s.png?size=64" % login}

    def test_the_avatar_img_carries_the_constructed_src_and_the_login_as_alt(self):
        t = _render(self.card(owner=self.owner()), self_login=ME)
        imgs = _find(t, lambda n: n["tag"] == "img")
        self.assertEqual(1, len(imgs))
        self.assertEqual("https://github.com/%s.png?size=64" % ME,
                         imgs[0]["attrs"].get("src"))
        self.assertEqual(ME, imgs[0]["attrs"].get("alt"))

    def test_the_handle_is_rendered_beside_it_in_uppercase(self):
        t = _render(self.card(owner=self.owner()), self_login=ME)
        handles = _find(t, lambda n: _cls(n, "owner-handle"))
        self.assertEqual(1, len(handles))
        self.assertEqual(ME.upper(), handles[0]["text"])

    def test_my_own_mission_leaves_every_write_control_ENABLED(self):
        t = _render(self.card(owner=self.owner()), self_login=ME)
        btns = _ctrl_buttons(t)
        self.assertTrue(btns, "the card rendered no write control at all")
        for b in btns:
            self.assertFalse(b["disabled"], b["text"])
            self.assertNotIn("assigned to", b["title"])

    def test_my_own_mission_is_not_marked_as_someone_elses(self):
        t = _render(self.card(owner=self.owner()), self_login=ME)
        self.assertFalse(_cls(t, "owned-by-other"))

    def test_a_card_with_NO_owner_renders_no_owner_block_at_all(self):
        t = _render(self.card(), self_login=ME)
        self.assertEqual([], _find(t, lambda n: _cls(n, "owner")))
        self.assertEqual([], _find(t, lambda n: n["tag"] == "img"))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class SomeoneElsesMissionIsLocked(unittest.TestCase):
    """Behaviour 2 (client half): the affordances go disabled and SAY WHY.

    The server half — a direct POST past the DOM — is proven in
    test_owner_lock_endpoints.py. A disabled button is not a lock.
    """

    LINE = ("assigned to %s — reassign it to yourself on GitHub to take command"
            % OTHER)

    def card(self, stage="align", **kw):
        m = {"id": "m-1", "issue": 101, "title": "Someone else's work",
             "type": "feature", "stage": stage, "awaiting": False,
             "paused": False, "running": False, "dispatched": False,
             "queued": False, "linked": False, "pills": {}, "tickets": [],
             "owner": {"login": OTHER,
                       "avatarUrl": "https://github.com/%s.png?size=64" % OTHER}}
        m.update(kw)
        return m

    def test_every_write_control_on_the_card_is_disabled(self):
        for stage in ("align", "implement", "verify"):
            t = _render(self.card(stage=stage), self_login=ME)
            btns = _ctrl_buttons(t)
            self.assertTrue(btns, "stage %s rendered no control" % stage)
            for b in btns:
                self.assertTrue(b["disabled"],
                                "%s control %r stayed live" % (stage, b["text"]))

    def test_the_tooltip_names_the_owner_and_the_remedy(self):
        t = _render(self.card(), self_login=ME)
        for b in _ctrl_buttons(t):
            self.assertEqual(self.LINE, b["title"])

    def test_the_gate_answer_action_is_locked_too(self):
        t = _render(self.card(awaiting=True, question="which way?"),
                    self_login=ME)
        btns = _ctrl_buttons(t)
        self.assertTrue(btns)
        for b in btns:
            self.assertTrue(b["disabled"])
            self.assertEqual(self.LINE, b["title"])

    def test_the_card_is_marked_so_the_stylesheet_can_dim_it(self):
        t = _render(self.card(), self_login=ME)
        self.assertTrue(_cls(t, "owned-by-other"))

    def test_the_verify_merge_action_is_locked(self):
        t = _render(self.card(stage="verify",
                              prUrl="https://github.com/acme/repo/pull/7",
                              prNumber=7, review="open"), self_login=ME)
        for b in _ctrl_buttons(t):
            self.assertTrue(b["disabled"], b["text"])
            self.assertEqual(self.LINE, b["title"])


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheLockNeverGuessesatIdentity(unittest.TestCase):
    """Behaviour 5: the two cases that must NEVER lock.

    Both mirror lcars_owner_lock_reason's posture exactly. A false lock is
    strictly worse than the thing the lock prevents: it shuts the captain out of
    his own work because a network hiccuped.
    """

    def card(self, **kw):
        m = {"id": "m-1", "issue": 101, "title": "T", "type": "feature",
             "stage": "align", "awaiting": False, "paused": False,
             "running": False, "dispatched": False, "queued": False,
             "linked": False, "pills": {}, "tickets": []}
        m.update(kw)
        return m

    def test_an_UNASSIGNED_mission_is_never_locked(self):
        t = _render(self.card(), self_login=ME)
        for b in _ctrl_buttons(t):
            self.assertFalse(b["disabled"], b["text"])

    def test_an_UNRESOLVABLE_identity_never_locks_anything(self):
        # We cannot say who we are, so we do not get to tell the captain he is
        # someone else. The avatar still renders — showing whose it is costs
        # nothing and is honest.
        t = _render(self.card(owner={"login": OTHER,
                                     "avatarUrl": "https://github.com/%s.png?size=64" % OTHER}),
                    self_login=None)
        self.assertFalse(_cls(t, "owned-by-other"))
        for b in _ctrl_buttons(t):
            self.assertFalse(b["disabled"], b["text"])
        self.assertEqual(1, len(_find(t, lambda n: n["tag"] == "img")))

    def test_a_view_only_board_still_reads_as_view_only_not_as_locked(self):
        t = _render(self.card(), self_login=ME, readonly=True)
        for b in _ctrl_buttons(t):
            self.assertTrue(b["disabled"])
            self.assertIn("view-only", b["title"])


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class DeadAvatarDegradesToTheHandle(unittest.TestCase):
    """Behaviour 4: no avatar box with no image in it.

    Fired through the element's OWN error handler, the way a broken URL fires it.
    The rendered-dimension proof is the tester's, in Chrome (S164): a dead <img>
    has the same box and class as a live one, so this file proves the handler
    removes the image — and the stylesheet is what collapses the space.
    """

    def card(self):
        return {"id": "m-1", "issue": 101, "title": "T", "type": "feature",
                "stage": "align", "awaiting": False, "paused": False,
                "running": False, "dispatched": False, "queued": False,
                "linked": False, "pills": {}, "tickets": [],
                "owner": {"login": ME,
                          "avatarUrl": "https://github.com/%s.png?size=64" % ME}}

    def test_the_image_is_gone_after_it_fails(self):
        t = _render(self.card(), self_login=ME, kill_avatar=True)
        live = [n for n in _find(t, lambda n: n["tag"] == "img")
                if not n["hidden"]]
        self.assertEqual([], live, "a dead <img> survived in the layout")

    def test_the_handle_survives_ALONE(self):
        t = _render(self.card(), self_login=ME, kill_avatar=True)
        handles = _find(t, lambda n: _cls(n, "owner-handle"))
        self.assertEqual(1, len(handles))
        self.assertEqual(ME.upper(), handles[0]["text"])

    def test_the_owner_block_is_marked_so_the_cap_can_close_up(self):
        t = _render(self.card(), self_login=ME, kill_avatar=True)
        blocks = _find(t, lambda n: _cls(n, "owner"))
        self.assertEqual(1, len(blocks))
        self.assertTrue(_cls(blocks[0], "dead"))


if __name__ == "__main__":
    unittest.main()
