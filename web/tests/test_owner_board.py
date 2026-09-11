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

    def test_a_locked_control_does_not_wear_the_LIVE_control_s_fill(self):
        """S191 fix round 1, D4 — the cheap half of "does it LOOK locked?".

        Round 1's `.7` was true in every number it reported and still failed,
        because the question is not how the locked control paints — it is how it
        paints COMPARED WITH A LIVE ONE, and that comparison only exists in a
        browser with both cards on screen. `owner-paint.sh` measures it at 3:1
        (WCAG 1.4.11). This is the tripwire between drive runs: the locked
        control must be HOLLOW, and must not be handed a solid fill back.
        """
        rules = re.findall(r"\.btn\.locked\s*\{([^}]*)\}", self.css)
        self.assertTrue(rules, "nothing styles `.btn.locked` any more")
        body = " ".join(rules).replace(" ", "").replace("\n", "")
        self.assertIn("background:transparent", body,
                      "the locked control took a solid fill again — at .7 over "
                      "--lcars-teal it measured 1.84:1 against the live button")
        # …and the dim must not come back INSTEAD of the state treatment: `.7`
        # was the shape that shipped and read as live.
        self.assertNotRegex(body, r"opacity:\.\d",
                            "a fractional opacity is back on the locked control")
        # SOURCE ORDER. `.btn.locked` and `.btn[disabled]` tie on specificity, so
        # `opacity:1` only wins from below — above it the locked controls paint
        # at .4 and the cure is silently gone.
        self.assertLess(self.css.index(".btn[disabled]"),
                        self.css.index(".btn.locked"),
                        "`.btn.locked` moved above `.btn[disabled]`; the tie now "
                        "goes the other way and the controls paint at .4")

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


def _render(mission, self_login=None, readonly=False, kill_avatar=False,
            load_avatar=False, advance_ms=0, rerender=False):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"mission": mission, "self": self_login,
                       "readonly": readonly, "killAvatar": kill_avatar,
                       "loadAvatar": load_avatar, "advanceMs": advance_ms,
                       "rerender": rerender}, fh)
        out = subprocess.check_output([NODE, HARNESS, p])
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _drive(mission, self_login=None, readonly=False, steps=()):
    """Run a SEQUENCE against one card in one process, on the harness clock.

    `_render` above answers "what does the card look like after ONE thing
    happened". This answers "what does it look like after the board has been
    repainting for nine seconds", which is the only shape in which the S196.1
    defect is visible at all — and it returns the clock and the timer ledger
    beside the tree, because "no timers piled up" is not a fact about the DOM.
    """
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump({"mission": mission, "self": self_login,
                       "readonly": readonly, "steps": list(steps),
                       "emit": "full"}, fh)
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

    def test_every_locked_control_opens_with_the_lock_mark(self):
        # S191 fix round 1, D4. `▶ Start` on a mission you cannot start is the
        # lie stated in the one place the eye lands last. The glyph is `⊘` —
        # already worn by the Verify lock label since S190, and nothing new.
        for stage in ("align", "implement", "verify"):
            t = _render(self.card(stage=stage), self_login=ME)
            btns = _ctrl_buttons(t)
            self.assertTrue(btns, "stage %s rendered no control" % stage)
            for b in btns:
                self.assertTrue(b["text"].startswith("⊘ "),
                                "%s control %r wears no lock mark"
                                % (stage, b["text"]))

    def test_the_action_glyph_is_REPLACED_never_merely_prefixed(self):
        # `⊘ ▶ Start` would still show the go-arrow. One glyph, and it is the
        # one that tells the truth.
        t = _render(self.card(stage="align"), self_login=ME)
        for b in _ctrl_buttons(t):
            self.assertNotIn("▶", b["text"], b["text"])
            self.assertEqual(1, b["text"].count("⊘"), b["text"])

    def test_every_locked_control_carries_the_state_class(self):
        # The fill half of D4 hangs entirely off this class; the glyph half is
        # above. Both are asserted, because either alone still reads as live
        # from one of the two distances a card is read at.
        for stage in ("align", "implement", "verify"):
            t = _render(self.card(stage=stage), self_login=ME)
            for b in _ctrl_buttons(t):
                self.assertIn("locked", (b.get("cls") or "").split(),
                              "%s control %r carries no `locked` class"
                              % (stage, b["text"]))

    def test_MY_OWN_controls_wear_no_lock_mark(self):
        # The negative control. A mark that fell on every card would pass the two
        # tests above and mean nothing.
        mine = self.card(stage="align")
        mine["owner"] = {"login": ME,
                         "avatarUrl": "https://github.com/%s.png?size=64" % ME}
        for b in _ctrl_buttons(_render(mine, self_login=ME)):
            self.assertNotIn("⊘", b["text"], b["text"])

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


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class APendingPortraitIsNeverAHole(unittest.TestCase):
    """S196 — THE MISSING CASE, and the reason the beam exists at all.

    THE BUG. `ownerNode()` has always handled a portrait that FAILED: the cap is
    removed, the pill goes `.dead`, and what is left is a complete handle-only
    LCARS pill. It has never handled a portrait that is merely PENDING. An
    avatar that is still in flight — or deferred by its own `loading="lazy"` and
    therefore never even started — paints a 15px disc of `--lcars-card-alt` and
    nothing else: precisely "a hole in the cap that looks deliberate", which is
    the sentence the degrade above `ownerNode` says it exists to prevent. The
    error handler never fires, because nothing errored. The captain hit this for
    real — every card in a capture run wore a black circle where his face goes.

    THE RULE THIS CLASS PINS: **a pending portrait degrades exactly as well as a
    failed one.** No state of this pill is ever an empty disc at rest. Either
    the disc is SAYING something (the transporter pad, while the portrait is in
    transit), or the portrait is in it, or the cap is gone and the handle stands
    alone. There is no fourth state.

    The pixels are the tester's — tests/drives/s190/owner-paint.sh measures the
    disc and the portrait inside real Chrome. This proves the WIRING.
    """

    URL = "https://github.com/%s.png?size=64" % ME

    def card(self):
        return {"id": "m-1", "issue": 101, "title": "T", "type": "feature",
                "stage": "align", "awaiting": False, "paused": False,
                "running": False, "dispatched": False, "queued": False,
                "linked": False, "pills": {}, "tickets": [],
                "owner": {"login": ME, "avatarUrl": self.URL}}

    def _beam(self, tree):
        beams = _find(tree, lambda n: _cls(n, "beam"))
        self.assertEqual(1, len(beams), "expected exactly one .beam disc")
        return beams[0]

    # ── THE HEADLINE ──────────────────────────────────────────────────────
    def test_a_PENDING_portrait_is_never_left_as_a_resting_empty_disc(self):
        """The whole session in one assertion.

        Nothing has loaded and nothing has failed — the ordinary case, the case
        that was unhandled. The disc must be actively SAYING it is waiting.
        """
        t = _render(self.card(), self_login=ME)
        beam = self._beam(t)
        self.assertIn("loading", (beam.get("cls") or "").split(),
                      "a portrait still in transit paints an empty disc — this "
                      "is the hole the `.dead` degrade exists to prevent, and "
                      "it is reachable without anything ever erroring")

    def test_a_PENDING_portrait_degrades_AS_WELL_AS_a_FAILED_one(self):
        """The two failures are the same failure, so they must end the same.

        A portrait that never arrives is not a different kind of missing from
        one that 404s; the only difference is that nothing announces it. After
        the give-up window both land on the identical, complete pill.
        """
        failed = _render(self.card(), self_login=ME, kill_avatar=True)
        never = _render(self.card(), self_login=ME,
                        advance_ms=board_avatar_give_up_ms() + 1)
        for name, t in (("failed", failed), ("never-arrived", never)):
            self.assertEqual([], _find(t, lambda n: _cls(n, "owner-av")),
                             "%s: the cap survived with nothing in it" % name)
            blocks = _find(t, lambda n: _cls(n, "owner"))
            self.assertEqual(1, len(blocks), name)
            self.assertTrue(_cls(blocks[0], "dead"), name)
            handles = _find(t, lambda n: _cls(n, "owner-handle"))
            self.assertEqual(ME.upper(), handles[0]["text"], name)

    # ── the three states ──────────────────────────────────────────────────
    def test_IN_TRANSIT_the_pad_is_running_and_the_portrait_is_present(self):
        t = _render(self.card(), self_login=ME)
        beam = self._beam(t)
        self.assertIn("loading", (beam.get("cls") or "").split())
        self.assertNotIn("done", (beam.get("cls") or "").split())
        imgs = _find(beam, lambda n: n["tag"] == "img")
        self.assertEqual(1, len(imgs), "the portrait is not inside the disc")
        self.assertEqual(self.URL, imgs[0]["attrs"].get("src"))

    def test_ON_ARRIVAL_the_loop_stops_and_the_portrait_resolves_in(self):
        t = _render(self.card(), self_login=ME, load_avatar=True)
        beam = self._beam(t)
        cls = (beam.get("cls") or "").split()
        self.assertNotIn("loading", cls, "the pad kept humming after arrival — "
                                         "a spinner that never stops is a lie")
        self.assertIn("done", cls)

    def test_the_BEAM_DOES_NOT_REPLAY_when_the_same_card_is_repainted(self):
        """The board repaints on every SSE tick. A portrait that already
        materialised must not beam in again each time — it would strobe."""
        t = _render(self.card(), self_login=ME, load_avatar=True, rerender=True)
        cls = (self._beam(t).get("cls") or "").split()
        self.assertNotIn("loading", cls,
                         "a repaint restarted the transporter loop")
        self.assertNotIn("done", cls,
                         "a repaint replayed the arrival animation")
        self.assertIn("settled", cls,
                      "an already-arrived portrait must render at rest, visible")

    def test_NEVER_ARRIVES_the_pad_gives_up_rather_than_humming_for_ever(self):
        t = _render(self.card(), self_login=ME,
                    advance_ms=board_avatar_give_up_ms() + 1)
        self.assertEqual([], _find(t, lambda n: n["tag"] == "img"))
        blocks = _find(t, lambda n: _cls(n, "owner"))
        self.assertTrue(_cls(blocks[0], "dead"))

    def test_the_give_up_window_does_NOT_fire_early(self):
        """A negative control. A timer that fired at 0ms would pass the test
        above and would ALSO kill every portrait on a slow connection."""
        t = _render(self.card(), self_login=ME,
                    advance_ms=board_avatar_give_up_ms() - 1)
        self.assertEqual(1, len(_find(t, lambda n: n["tag"] == "img")))
        self.assertIn("loading", (self._beam(t).get("cls") or "").split())

    def test_an_ARRIVED_portrait_is_not_killed_by_the_give_up_window(self):
        """The timer has to be CANCELLED, not merely out-raced. Otherwise every
        avatar on the board vanishes eight seconds after it appeared."""
        t = _render(self.card(), self_login=ME, load_avatar=True,
                    advance_ms=board_avatar_give_up_ms() * 2)
        self.assertEqual(1, len(_find(t, lambda n: n["tag"] == "img")))
        blocks = _find(t, lambda n: _cls(n, "owner"))
        self.assertFalse(_cls(blocks[0], "dead"))

    # ── S196: lazy is gone ────────────────────────────────────────────────
    def test_the_portrait_is_NOT_lazy(self):
        """`loading="lazy"` saved nothing on a 17px image and interacted badly
        with the give-up window: a deferred portrait never starts, never errors,
        and would trip the give-up on a card the captain had simply not
        scrolled to yet — turning "off screen" into "this person has no face"."""
        t = _render(self.card(), self_login=ME)
        imgs = _find(t, lambda n: n["tag"] == "img")
        self.assertEqual(1, len(imgs))
        self.assertIsNone(imgs[0]["attrs"].get("loading"),
                          "the avatar is lazy again; a deferred image trips the "
                          "give-up window on a card that is merely off screen")
        # …and the third-party posture is unchanged.
        self.assertEqual("no-referrer", imgs[0]["attrs"].get("referrerpolicy"))

    # ── the error path must not regress ───────────────────────────────────
    def test_a_HARD_ERROR_still_degrades_exactly_as_it_did_before(self):
        t = _render(self.card(), self_login=ME, kill_avatar=True)
        self.assertEqual([], _find(t, lambda n: n["tag"] == "img"))
        self.assertEqual([], _find(t, lambda n: _cls(n, "beam")))
        blocks = _find(t, lambda n: _cls(n, "owner"))
        self.assertEqual(1, len(blocks))
        self.assertTrue(_cls(blocks[0], "dead"))

    def test_a_card_with_NO_owner_grows_no_disc(self):
        m = self.card()
        del m["owner"]
        t = _render(m, self_login=ME)
        self.assertEqual([], _find(t, lambda n: _cls(n, "beam")))
        self.assertEqual([], _find(t, lambda n: _cls(n, "owner")))


def board_avatar_give_up_ms():
    """The give-up window, read out of the shipping board.js.

    Read rather than duplicated: a constant copied into a test is a second
    source of truth, and the first thing that goes stale. This also pins that
    it IS a named constant — the captain asked for one, and `setTimeout(fn,
    8000)` buried in a render path is the shape that never gets found again.
    """
    with open(os.path.normpath(os.path.join(
            HERE, "..", "static", "board.js"))) as fh:
        src = fh.read()
    m = re.search(r"var\s+AVATAR_GIVE_UP_MS\s*=\s*(\d+)\s*;", src)
    assert m, "board.js declares no named AVATAR_GIVE_UP_MS constant"
    return int(m.group(1))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheGiveUpWindowSURVIVESTheRepaint(unittest.TestCase):
    """S196.1 — the give-up window never fired while the board was BUSY, which
    is most of a mission.

    THE DEFECT, measured live. `AVATAR_ARRIVED` correctly remembers the ARRIVAL
    across repaints. The FAILURE side did not: the `giveUp` handle and the
    `closed` flag were per-node closure state, and the SSE tick rebuilds the
    `.beam` node every 3.4–5.6s during a mission. Every rebuild therefore armed
    a FRESH eight-second window and dropped the previous one before it could
    expire, so the deadline receded for as long as the board kept ticking. A
    DNS-blackholed portrait — no `load`, no `error`, nothing to announce it —
    was still `beam loading` with both pad animations running at 14s and 16s;
    six `.beam` generations were counted in twenty seconds. On the SAME browser
    with the board IDLE it collapsed at 8s. Board activity was the only
    variable; timer throttling was ruled out (a control `setTimeout(…, 8000)` in
    the same page fired at 8001ms, visible).

    So the pad hummed for ever on a busy board — the exact thing `ownerNode`'s
    own comment says the window exists to prevent.

    THE RULE THIS CLASS PINS: **the give-up is a DEADLINE, not a duration.** A
    rebuilt node inherits the time REMAINING; it never restarts the clock. And
    the settled states are remembered on BOTH sides — a remembered failure is as
    sticky as a remembered arrival, or a collapsed pill flickers back into a
    humming pad on the next tick.
    """

    URL = "https://github.com/%s.png?size=64" % ME

    def card(self):
        return {"id": "m-1", "issue": 101, "title": "T", "type": "feature",
                "stage": "align", "awaiting": False, "paused": False,
                "running": False, "dispatched": False, "queued": False,
                "linked": False, "pills": {}, "tickets": [],
                "owner": {"login": ME, "avatarUrl": self.URL}}

    def _dead(self, tree, why):
        self.assertEqual([], _find(tree, lambda n: n["tag"] == "img"), why)
        self.assertEqual([], _find(tree, lambda n: _cls(n, "beam")), why)
        self.assertEqual([], _find(tree, lambda n: _cls(n, "owner-av")), why)
        blocks = _find(tree, lambda n: _cls(n, "owner"))
        self.assertEqual(1, len(blocks), why)
        self.assertTrue(_cls(blocks[0], "dead"), why)
        handles = _find(tree, lambda n: _cls(n, "owner-handle"))
        self.assertEqual(ME.upper(), handles[0]["text"], why)

    # ── THE HEADLINE ──────────────────────────────────────────────────────
    def test_a_REPAINTED_portrait_gives_up_at_the_ORIGINAL_deadline(self):
        """The defect in one assertion.

        Nothing loads and nothing errors — the blackholed portrait. The node is
        rebuilt three times inside the window, the way the SSE tick rebuilds it.
        The pill must still collapse at the ORIGINAL deadline; a window that
        restarts on each rebuild leaves a pad humming for as long as the board
        is busy, which is for ever.
        """
        w = board_avatar_give_up_ms()
        q = w // 4
        r = _drive(self.card(), self_login=ME, steps=[
            {"advanceMs": q, "rerender": True},          # t = 2000
            {"advanceMs": q, "rerender": True},          # t = 4000
            {"advanceMs": q, "rerender": True},          # t = 6000
            {"advanceMs": w - 3 * q + 1},                # t = 8001
        ])
        self.assertEqual(w + 1, r["now"], "the harness clock did not advance")
        self._dead(r["tree"],
                   "a portrait that never arrives kept its pad running past "
                   "the give-up window because the board REPAINTED inside it — "
                   "each rebuild armed a fresh window and threw the old one "
                   "away, so the deadline recedes for as long as the board is "
                   "busy and the pad hums for ever")

    def test_the_REPAINTED_window_still_does_not_fire_EARLY(self):
        """The negative control for the headline. A deadline computed wrong in
        the other direction — or a rebuild that collapses on sight — would pass
        the test above and kill every portrait on a slow connection."""
        w = board_avatar_give_up_ms()
        q = w // 4
        r = _drive(self.card(), self_login=ME, steps=[
            {"advanceMs": q, "rerender": True},
            {"advanceMs": q, "rerender": True},
            {"advanceMs": w - 2 * q - 1},                # t = w - 1
        ])
        self.assertEqual(w - 1, r["now"])
        self.assertEqual(1, len(_find(r["tree"], lambda n: n["tag"] == "img")),
                         "the portrait was killed before its deadline")
        beams = _find(r["tree"], lambda n: _cls(n, "beam"))
        self.assertEqual(1, len(beams))
        self.assertIn("loading", (beams[0].get("cls") or "").split(),
                      "the pad stopped saying anything while still in transit")

    # ── a remembered failure is STICKY ────────────────────────────────────
    def test_a_GIVEN_UP_portrait_does_not_flicker_back_into_a_humming_pad(self):
        """Once the pill has collapsed, the next tick must repaint it collapsed.

        A failure held only in a node's closure is forgotten the instant the
        node is replaced, so a board that has already given up would rebuild a
        fresh transporter pad on the very next SSE tick and hum for another
        eight seconds — for ever, once per tick.
        """
        w = board_avatar_give_up_ms()
        r = _drive(self.card(), self_login=ME, steps=[
            {"advanceMs": w + 1},
            {"rerender": True},
            {"advanceMs": w * 3, "rerender": True},
        ])
        self._dead(r["tree"],
                   "a repaint after the give-up brought the disc and the pad "
                   "back — a collapsed pill must STAY collapsed")

    def test_a_HARD_ERROR_is_remembered_across_the_repaint_too(self):
        """Same rule, driven by the event rather than the clock."""
        r = _drive(self.card(), self_login=ME, steps=[
            {"killAvatar": True},
            {"rerender": True},
        ])
        self._dead(r["tree"],
                   "a repaint after a 404 rebuilt the disc and started the pad "
                   "again on a portrait already known to be missing")

    def test_a_remembered_failure_arms_NO_further_timers(self):
        """The sticky path must collapse on sight, not arm another window and
        wait it out — that is a pad that hums for eight seconds per repaint."""
        w = board_avatar_give_up_ms()
        r = _drive(self.card(), self_login=ME, steps=[
            {"killAvatar": True},
            {"rerender": True},
            {"rerender": True},
        ])
        self.assertEqual(0, r["timers"]["live"],
                         "a portrait already known to be missing armed a fresh "
                         "give-up window on repaint")

    def test_an_ARRIVAL_that_is_later_DISPROVED_does_not_shadow_the_failure(self):
        """The error handler is armed on an already-arrived portrait too — a
        cache can be evicted between two ticks. When it fires, the memo of the
        arrival is stale and must not outrank the memo of the failure, or every
        repaint rebuilds a disc around an image known to fail and collapses it
        again: a pill that flickers once per tick for the rest of the session.
        """
        r = _drive(self.card(), self_login=ME, steps=[
            {"loadAvatar": True},
            {"rerender": True},
            {"killAvatar": True},
            {"rerender": True},
        ])
        self._dead(r["tree"],
                   "a portrait proved missing after it had once arrived came "
                   "back as a disc on the next repaint")

    # ── arrival must not regress ──────────────────────────────────────────
    def test_ARRIVAL_still_wins_across_many_repaints(self):
        w = board_avatar_give_up_ms()
        r = _drive(self.card(), self_login=ME, steps=[
            {"loadAvatar": True},
            {"advanceMs": w, "rerender": True},
            {"advanceMs": w, "rerender": True},
            {"advanceMs": w * 4},
        ])
        t = r["tree"]
        self.assertEqual(1, len(_find(t, lambda n: n["tag"] == "img")),
                         "an ARRIVED portrait was killed by a give-up window "
                         "long after it materialised")
        beams = _find(t, lambda n: _cls(n, "beam"))
        self.assertEqual(1, len(beams))
        cls = (beams[0].get("cls") or "").split()
        self.assertIn("settled", cls)
        self.assertNotIn("loading", cls, "a repaint restarted the pad")
        self.assertNotIn("done", cls, "a repaint replayed the arrival")
        blocks = _find(t, lambda n: _cls(n, "owner"))
        self.assertFalse(_cls(blocks[0], "dead"))
        self.assertEqual(0, r["timers"]["live"],
                         "an arrived portrait left a give-up window running")

    # ── the timers must not pile up ───────────────────────────────────────
    def test_a_REPAINTING_board_does_not_hoard_one_timer_per_tick(self):
        """Six `.beam` generations were counted in twenty seconds of one real
        mission. Six abandoned eight-second timers is what that used to mean —
        and every one of them still fires, on a node that is no longer in the
        document, at a moment nothing else expects."""
        r = _drive(self.card(), self_login=ME, steps=[
            {"advanceMs": 900, "rerender": True} for _ in range(6)
        ])
        self.assertLessEqual(
            r["timers"]["live"], 1,
            "%d give-up timers are live after six repaints inside one window; "
            "a rebuilt node must inherit the deadline, not arm another one"
            % r["timers"]["live"])
        # …and the one that survives is still the ORIGINAL deadline.
        self.assertEqual(1, r["timers"]["live"])


class TheTransporterPadKeepsItsPromises(unittest.TestCase):
    """S196 — the stylesheet half, and the same posture as the class above it:
    NOT the proof, the tripwire between drive runs.

    What a browser paints is measured in tests/drives/s190/owner-paint.sh, in
    real Chrome, at real rendered dimensions, with a red control per defect.
    These lines are what stops the cured shape from quietly walking back in.
    """

    CSS = os.path.normpath(os.path.join(HERE, "..", "static", "board.css"))

    def setUp(self):
        with open(self.CSS) as fh:
            raw = fh.read()
        self.raw = raw
        self.css = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)

    def _rule(self, selector):
        rules = re.findall(re.escape(selector) + r"\s*\{([^}]*)\}", self.css)
        self.assertTrue(rules, "nothing styles `%s`" % selector)
        return " ".join(rules).replace(" ", "").replace("\n", "")

    def test_the_portrait_rule_OUTRANKS_the_bare_avatar_rule(self):
        """THE SPECIFICITY TRAP, learned the hard way in the captain's mock.

        `.owner .owner-av img` is (0,2,1). A bare `.beam img` is (0,1,1) and
        LOSES to it — so the portrait keeps the old rule's explicit 17px box and
        its own 1px ring inside a 15px disc that then clips it: a visibly
        non-circular avatar with two fighting black rings, from a stylesheet in
        which every individual rule reads correct.
        """
        beam_img = re.findall(r"([^{}]*?)\.beam\s+img\s*\{", self.css)
        self.assertTrue(beam_img, "nothing styles the portrait inside the disc")
        for prefix in beam_img:
            sel = (prefix + ".beam img").strip().split(",")[-1].strip()
            self.assertGreaterEqual(
                sel.count("."), 3,
                "`%s` is too weak to outrank `.owner .owner-av img` (0,2,1); "
                "the portrait will paint at the old rule's size inside a "
                "smaller disc and be clipped out of round" % sel)

    def test_the_disc_owns_the_ring_and_the_portrait_owns_none(self):
        disc = self._rule(".owner .owner-av .beam")
        self.assertIn("border-radius:50%", disc)
        self.assertIn("overflow:hidden", disc)
        self.assertIn("position:relative", disc)
        self.assertRegex(disc, r"border:1pxsolidvar\(--lcars-black")
        img = self._rule(".owner .owner-av .beam img")
        self.assertIn("border:0", img,
                      "the portrait draws a second ring inside the disc's")
        self.assertIn("width:100%", img)
        self.assertIn("height:100%", img)

    def test_the_settled_pill_wears_EXACTLY_the_filter_it_wore_before(self):
        """"Once loaded the pill must look exactly as it does today." The seat-
        it-in-the-palette filter is the whole of that treatment."""
        img = self._rule(".owner .owner-av .beam img")
        self.assertIn("filter:saturate(.72)contrast(1.06)brightness(.98)", img)

    def test_the_pad_loops_ONLY_while_the_portrait_is_in_transit(self):
        for sel in (".owner .owner-av .beam.loading::after",
                    ".owner .owner-av .beam.loading::before"):
            self.assertIn("infinite", self._rule(sel),
                          "%s does not loop; the pad would run once and stop "
                          "with the portrait still absent" % sel)
        # …and the arrival must not loop, or it strobes for ever.
        for sel in (".owner .owner-av .beam.done img",):
            self.assertNotIn("infinite", self._rule(sel))

    def test_the_pad_beams_in_the_OWNER_S_OWN_COLOUR(self):
        """ADR-007: amber on mine, blue on someone else's, and NOT because the
        beam knows anything about ownership — because it reads `--owner-col`,
        the token the pill already switches. No new colour is minted."""
        for sel in (".owner .owner-av .beam::after",
                    ".owner .owner-av .beam::before"):
            self.assertIn("var(--owner-col)", self._rule(sel))

    def test_no_new_lcars_token_is_MINTED_for_the_beam(self):
        """ADR-007, the house idiom (test_server's board.css token guard):
        board.css may READ any --lcars-* token and must DEFINE none."""
        stripped = re.sub(r"var\(\s*--lcars-[^)]*\)", "", self.css)
        self.assertNotRegex(stripped, r"--lcars-[a-z-]+\s*:",
                            "board.css defines an --lcars-* token")

    def test_REDUCED_MOTION_gets_no_loop_at_all(self):
        """Motion here is decoration; the ARRIVAL is the information. So the
        loop goes and the arrival stays, as a plain fade."""
        blocks = re.findall(r"@media\s*\(prefers-reduced-motion[^{]*\)\s*\{"
                            r"((?:[^{}]|\{[^{}]*\})*)\}", self.css)
        beam_blocks = [b for b in blocks if ".beam" in b]
        self.assertTrue(beam_blocks,
                        "the transporter pad loops for a reader who asked the "
                        "OS for less motion")
        joined = " ".join(beam_blocks).replace(" ", "").replace("\n", "")
        self.assertNotIn("infinite", joined,
                         "a looping animation survives prefers-reduced-motion")
        self.assertIn(".beam.loading::after{animation:none", joined)
        # (spaces stripped above, so `.done img` reads `.doneimg`)
        self.assertIn(".beam.doneimg{animation:padFadeIn", joined,
                      "reduced motion loses the ARRIVAL too; the one thing on this disc that is information, not decoration")
        # D6 again, from the other side: this is a MOTION block, so it must not
        # be where the portrait's COLOUR treatment gets decided.
        self.assertNotIn("filter:", joined,
                         "a colour treatment is being gated on a motion "
                         "preference again (S190 D6)")

    def test_the_HIGH_CONTRAST_escape_hatch_still_reaches_the_portrait(self):
        """S190 D6's cure has to move with the portrait. `.owner .owner-av img`
        (0,2,1) no longer outranks the beam's own rule, so a `filter:none` left
        at the old selector is a promise the cascade cannot keep."""
        blocks = re.findall(r"@media\s*\(prefers-contrast[^{]*\)\s*\{"
                            r"((?:[^{}]|\{[^{}]*\})*)\}", self.css)
        joined = " ".join(blocks)
        self.assertIn(".beam img", joined,
                      "prefers-contrast:more resets a selector that no longer "
                      "wins; the portrait keeps its saturation treatment")


if __name__ == "__main__":
    unittest.main()
