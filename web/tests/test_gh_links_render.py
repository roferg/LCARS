"""S168 — the two "view on GitHub" links the board builds, per forge host.

Both of them string-concatenated a LITERAL "https://github.com/" onto
`meta.repo`, so on a GitHub Enterprise repo the captain hand-edited the host
after every click. These drive the REAL builders out of the shipping board.js
through a sandboxed vm (ADR-007: no build step, no jsdom) and read the `href`
the board actually assigned — not a transcription of the source.

WHAT THESE CANNOT SEE, stated because the last blind spot of exactly this shape
cost three fix rounds: the harness calls the builders itself, so every test here
would stay green against a daemon that never sends `meta.ghHost` at all. The
daemon→page delivery is proven in real Chrome by
`tests/drives/browser/ghe-links.sh`.
"""
import json
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_ghlinks_harness.js")

MISSION = {
    "id": "lcars-20260802-001", "issue": 4101, "title": "A mission in flight",
    "type": "feature", "stage": "implement", "awaiting": False, "paused": False,
    "running": False, "dispatched": False, "queued": False, "linked": False,
    "tickets": [], "pills": {}, "progress": {},
}
BUG = dict(MISSION, id="lcars-20260802-009", issue=4109, type="bug",
           linked=True, parentMission="lcars-20260802-001",
           title="A logged bug")


def _board(meta, cards):
    return {"stages": ["implement"], "columns": {"implement": cards},
            "missions": cards, "meta": meta}


def _drive(meta, mode, mission, cards=None):
    # ONE render of the real board with the real payload — never a hand-primed
    # global. The FIRST render has to be enough: measured 2026-08-03, it was not.
    spec = {"mission": mission,
            "board": _board(meta, cards if cards is not None else [MISSION])}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(spec, fh)
        p = fh.name
    try:
        out = subprocess.run(["node", HARNESS, p, mode],
                             capture_output=True, text=True, check=True)
    finally:
        os.unlink(p)
    data = json.loads(out.stdout)
    assert not data["bootErrors"], "board.js failed: %s" % data["bootErrors"]
    return data


def _meta(**kw):
    m = {"repo": "acme/widget", "adapter": "local", "mode": "read-write"}
    m.update(kw)
    return m


def _issue_links(data):
    return [h["href"] for h in data["hrefs"] if "/issues/" in (h["href"] or "")]


class DetailViewOnGitHubTest(unittest.TestCase):
    """Call site 1: the detail header's "↗ View on GitHub" button."""

    def test_the_enterprise_host_reaches_the_link(self):
        d = _drive(_meta(ghHost="github.ghe.com"), "detail", MISSION)
        self.assertIn("https://github.ghe.com/acme/widget/issues/4101",
                      _issue_links(d))

    def test_github_com_is_unchanged_when_no_host_is_sent(self):
        d = _drive(_meta(), "detail", MISSION)
        self.assertIn("https://github.com/acme/widget/issues/4101",
                      _issue_links(d))

    def test_a_null_host_is_the_same_as_no_host(self):
        # ADR-006 shapes carry present-but-null all over the payload; a null must
        # never reach the URL as the string "null".
        d = _drive(_meta(ghHost=None), "detail", MISSION)
        self.assertIn("https://github.com/acme/widget/issues/4101",
                      _issue_links(d))

    def test_a_host_that_is_not_a_hostname_is_ignored_not_spliced(self):
        for junk in ("javascript:alert(1)", "evil.com/acme/x", "a b",
                     "//evil.com", 42, {"h": "x"}):
            d = _drive(_meta(ghHost=junk), "detail", MISSION)
            links = _issue_links(d)
            self.assertIn("https://github.com/acme/widget/issues/4101", links,
                          "%r was not refused: %s" % (junk, links))

    def test_the_host_does_not_leak_between_boards(self):
        # A single page can be re-rendered against a different payload (SSE);
        # an enterprise host must not persist once the board stops sending it.
        d = _drive(_meta(), "detail", MISSION)
        self.assertIn("https://github.com/acme/widget/issues/4101",
                      _issue_links(d))


class LogBugBadgeTest(unittest.TestCase):
    """Call site 2: the "⊗ BUG · child of #<parent>" badge on a logged bug."""

    def test_the_enterprise_host_reaches_the_badge_link(self):
        d = _drive(_meta(ghHost="github.ghe.com"), "logbug", BUG, cards=[MISSION, BUG])
        self.assertEqual(d["badgeTag"], "a")
        self.assertEqual(d["badgeHref"],
                         "https://github.ghe.com/acme/widget/issues/4101")

    def test_github_com_is_unchanged(self):
        d = _drive(_meta(), "logbug", BUG, cards=[MISSION, BUG])
        self.assertEqual(d["badgeHref"],
                         "https://github.com/acme/widget/issues/4101")

    def test_a_bug_with_no_resolvable_parent_still_renders_a_plain_badge(self):
        orphan = dict(BUG, parentMission=None, parentIssue=None)
        d = _drive(_meta(ghHost="github.ghe.com"), "logbug", orphan, cards=[MISSION, orphan])
        self.assertEqual(d["badgeTag"], "span")
        self.assertIsNone(d["badgeHref"])


if __name__ == "__main__":
    unittest.main()
