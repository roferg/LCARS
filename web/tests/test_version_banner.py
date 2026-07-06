"""S130 — the viewscreen version UPDATE banner + POST /api/update.

The board grows an ADDITIVE `meta.version` block (from check.sh in report/cache
mode) when the LCARS install is stale, and a LOCAL-only POST /api/update runs the
update action. These tests:

  1. VersionChecker parses check.sh `report` output into the block, memoizes it
     (no fetch storm), and returns None for a current install.
  2. /api/board carries meta.version when the provider yields a block, and is
     BYTE-IDENTICAL (no `version` key) when it yields None — so a current board
     matches the pre-S130 shape and every existing test stays green.
  3. POST /api/update dispatches check.sh `update` (a recording stub) and returns
     its output line; a read-only / view-only build declines with 403.
  4. The served front end carries the banner node + renderVersionBanner + the
     /api/update POST + a view-only-drops-the-button guard.

stdlib only; the daemon runs on an ephemeral localhost port inside the test.
"""
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402
from lcars_serve.version_check import VersionChecker, _parse_report  # noqa: E402


# ── the check.sh report/update stub ─────────────────────────────────────────
def _check_stub(path, report_lines, count_file=None):
    """A bash stub standing in for check.sh: on `report` prints the given lines
    (and bumps a spawn counter); on `update` prints a success line."""
    body = ['#!/usr/bin/env bash', 'mode="${1:-warn}"']
    if count_file:
        body.append('if [ "$mode" = report ]; then echo x >> "%s"; fi' % count_file)
    body.append('if [ "$mode" = report ]; then')
    for ln in report_lines:
        body.append('  printf "%s\\n"' % ln)
    body.append('fi')
    body.append('if [ "$mode" = update ]; then '
                'printf "CHECK-UPDATE-RAN cwd=%s\\n" "${LCARS_VERSION_CWD:-}"; fi')
    body.append('exit 0')
    with open(path, "w") as fh:
        fh.write("\n".join(body) + "\n")
    os.chmod(path, 0o755)
    return path


class ParseReportTest(unittest.TestCase):
    def test_none_when_current(self):
        self.assertIsNone(_parse_report("running=2026.7.1\n"))
        self.assertIsNone(_parse_report(""))

    def test_source_behind_block(self):
        blk = _parse_report("running=2026.7.1\nremote=2026.7.2\n"
                            "verdict=source_behind\n")
        self.assertEqual(blk["running"], "2026.7.1")
        self.assertEqual(blk["remote"], "2026.7.2")
        self.assertEqual(blk["verdicts"], ["source_behind"])

    def test_repo_predates_and_dedup_order(self):
        blk = _parse_report("running=2026.7.1\nverdict=drift\n"
                            "verdict=repo_predates\nverdict=repo_predates\n")
        # ordered by the canonical verdict order; de-duplicated.
        self.assertEqual(blk["verdicts"], ["repo_predates", "drift"])
        self.assertNotIn("remote", blk)  # remote omitted when absent
        self.assertNotIn("stamped", blk)  # unstamped/predates → no from-version

    def test_repo_stale_carries_stamped_from_version(self):
        # the viewed repo's current stamp flows through so the banner shows from→to
        blk = _parse_report("running=2026.7.2\nstamped=2026.7.1\n"
                            "verdict=repo_stale\n")
        self.assertEqual(blk["stamped"], "2026.7.1")
        self.assertEqual(blk["running"], "2026.7.2")
        self.assertEqual(blk["verdicts"], ["repo_stale"])


class VersionCheckerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_block_parses_and_memoizes(self):
        count = os.path.join(self.tmp, "spawns")
        script = _check_stub(os.path.join(self.tmp, "check.sh"),
                             ["running=2026.7.1", "remote=2026.7.2",
                              "verdict=source_behind"], count_file=count)
        vc = VersionChecker(repo_root=self.tmp, check_script=script, ttl=60.0)
        b1 = vc.block()
        b2 = vc.block()
        self.assertEqual(b1["verdicts"], ["source_behind"])
        self.assertEqual(b1, b2)
        # memoized within the TTL → exactly ONE spawn (no fetch storm).
        with open(count) as fh:
            self.assertEqual(len(fh.read().split()), 1)

    def test_invalidate_forces_reprobe(self):
        count = os.path.join(self.tmp, "spawns")
        script = _check_stub(os.path.join(self.tmp, "check.sh"),
                             ["running=2026.7.1", "verdict=repo_stale"],
                             count_file=count)
        vc = VersionChecker(repo_root=self.tmp, check_script=script, ttl=60.0)
        vc.block()
        vc.invalidate()
        vc.block()
        with open(count) as fh:
            self.assertEqual(len(fh.read().split()), 2)

    def test_current_install_returns_none(self):
        script = _check_stub(os.path.join(self.tmp, "check.sh"),
                             ["running=2026.7.1"])   # no verdict line
        vc = VersionChecker(repo_root=self.tmp, check_script=script)
        self.assertIsNone(vc.block())

    def test_missing_script_degrades_to_none(self):
        vc = VersionChecker(repo_root=self.tmp,
                            check_script=os.path.join(self.tmp, "nope.sh"))
        self.assertIsNone(vc.block())


class BoardMetaVersionTest(unittest.TestCase):
    """meta.version rides the board ONLY when the provider yields a block."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        self.adapter = LocalAdapter(self.tmp)

    def _serve(self, provider):
        httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                            poll_interval=0.05, version_provider=provider)
        port = httpd.server_address[1]
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        return httpd, port

    def _board(self, port):
        url = "http://127.0.0.1:%d/api/board" % port
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.loads(r.read())

    def test_meta_version_present_when_stale(self):
        blk = {"running": "2026.7.1", "remote": "2026.7.2",
               "verdicts": ["source_behind"]}
        httpd, port = self._serve(lambda: blk)
        try:
            data = self._board(port)
            self.assertEqual(data["meta"]["version"], blk)
        finally:
            httpd.shutdown(); httpd.server_close()

    def test_meta_version_absent_when_current(self):
        # provider returns None (current) → NO version key → byte-identical board.
        httpd, port = self._serve(lambda: None)
        try:
            data = self._board(port)
            self.assertNotIn("version", data["meta"])
        finally:
            httpd.shutdown(); httpd.server_close()

    def test_no_provider_is_byte_identical(self):
        httpd, port = self._serve(None)
        try:
            data = self._board(port)
            self.assertNotIn("version", data["meta"])
        finally:
            httpd.shutdown(); httpd.server_close()

    def test_provider_exception_degrades(self):
        def boom():
            raise RuntimeError("git wedged")
        httpd, port = self._serve(boom)
        try:
            data = self._board(port)              # board still serves
            self.assertNotIn("version", data["meta"])
        finally:
            httpd.shutdown(); httpd.server_close()


class UpdateEndpointTest(unittest.TestCase):
    """POST /api/update dispatches check.sh `update`; read-only → 403."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        self.check = _check_stub(os.path.join(self.tmp, "check.sh"),
                                 ["running=2026.7.1", "verdict=source_behind"])
        self.actions = Actions(repo_root=self.tmp, scripts={},
                               check_script=self.check)

    def _serve(self, actions):
        httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                            poll_interval=0.05, actions=actions)
        port = httpd.server_address[1]
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        return httpd, port

    def _post(self, port, path):
        url = "http://127.0.0.1:%d%s" % (port, path)
        req = urllib.request.Request(url, data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())

    def test_update_dispatches_check_update(self):
        httpd, port = self._serve(self.actions)
        try:
            status, data = self._post(port, "/api/update")
            self.assertEqual(status, 200)
            self.assertTrue(data["ok"])
            # the response carries check.sh's update output line + a fresh board.
            self.assertIn("CHECK-UPDATE-RAN", data["state"]["update"])
            self.assertIn("cwd=%s" % self.tmp, data["state"]["update"])
            self.assertIn("board", data["state"])
        finally:
            httpd.shutdown(); httpd.server_close()

    def test_update_403_on_read_only(self):
        # actions=None ⇒ the view-only / github build ⇒ the read-only guard 403s.
        httpd, port = self._serve(None)
        try:
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self._post(port, "/api/update")
            self.assertEqual(cm.exception.code, 403)
        finally:
            httpd.shutdown(); httpd.server_close()


class BannerFrontEndTest(unittest.TestCase):
    """The served assets carry the banner node + render logic (no JS DOM harness,
    so lock the structure statically — mirrors the S68 front-end asset checks)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown(); self.httpd.server_close()

    def _text(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.read().decode("utf-8")

    def test_index_has_banner_host(self):
        self.assertIn('id="versionBanner"', self._text("/"))

    def test_board_js_renders_banner_and_posts_update(self):
        js = self._text("/board.js")
        self.assertIn("renderVersionBanner", js)
        self.assertIn("meta.version", js)
        self.assertIn("ENGAGE UPDATE", js)
        # copy names LCARS explicitly (not just "REPO") and shows the target version.
        self.assertIn("UPDATE LCARS IN THIS REPO", js)
        # and the repo's CURRENT (stamped) version, rendered from → to.
        self.assertIn("version.stamped", js)
        self.assertIn("/api/update", js)
        # view-only build shows the banner WITHOUT the button.
        self.assertIn("writesActive !== false", js)
        # a non-actionable (drift-only / current) state hides the banner, so a
        # successful update — which leaves at most drift — clears it.
        self.assertIn("if (!sourceBehind && !repoStale)", js)

    def test_board_css_styles_the_banner(self):
        css = self._text("/board.css")
        for sel in (".version-banner", ".vb-band", ".vb-btn"):
            self.assertIn(sel, css, "board.css must style %s" % sel)

    def test_banner_left_aligns_with_the_columns(self):
        # UX: the banner's left edge lines up with the board columns (the ALIGN
        # column), i.e. it shares the .board-wrap horizontal gutter (28px) rather
        # than floating in from it. The 18px top gap clears the rounded corner.
        css = self._text("/board.css")
        self.assertIn(".version-banner{margin:18px28px6px}", css.replace(" ", ""),
                      "banner must share the 28px column gutter so it aligns left")

    def test_banner_has_session_dismiss(self):
        # A ✕ hides the banner for the session only (in-memory flag, not persisted
        # to storage); a refresh reloads board.js and the banner returns.
        js = self._text("/board.js")
        self.assertIn("versionBannerDismissed", js)
        self.assertNotIn("localStorage", js)
        self.assertNotIn("sessionStorage", js)
        self.assertIn(".vb-x", self._text("/board.css"))

    def test_banner_has_running_and_done_states(self):
        # Pressing ENGAGE UPDATE recolours the band (blue → teal) for feedback.
        css = self._text("/board.css")
        self.assertIn(".vb-updating", css)
        self.assertIn(".vb-done", css)
        js = self._text("/board.js")
        self.assertIn("vb-updating", js)
        self.assertIn("UPDATE COMPLETE", js)


if __name__ == "__main__":
    unittest.main()
