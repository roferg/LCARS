"""S205 behaviour 3 — `GET /api/xo/shot/<mission>/<name>`.

PATH-SAFETY IS A SECURITY BOUNDARY, not a nicety (this session's own standing
instruction). The route must serve ONLY files under a mission's own
`xo/shots/` tree; `../` traversal — and every equivalent of it (absolute
paths, an encoded segment, a symlink pointing back out) — must 404, and the
guard must work by resolving the REAL path and checking containment, never by
rejecting a literal `..` substring alone.

LOCAL ADAPTER ONLY: the github adapter never grows this route (no local
shots exist for a remote card) — asserted here by giving the server an
adapter object with no `xo_shot` method at all and confirming it 404s rather
than raising.

No gh, no network, no model, no worker.
"""
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402

MID = "lcars-20260914-801"
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n" + b"0" * 32


class ShotRouteBase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")
        d = fx.mission_dir(self.tmp, MID)
        shots = os.path.join(d, "xo", "shots", "look-1")
        os.makedirs(shots, exist_ok=True)
        with open(os.path.join(shots, "shot-01.png"), "wb") as fh:
            fh.write(_PNG_MAGIC)
        # A file OUTSIDE the mission's shots tree, at a name a `../../` from
        # inside it would reach — the traversal target.
        with open(os.path.join(d, "state.json.secret-marker"), "wb") as fh:
            fh.write(b"SECRET")

        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def fetch(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return r.status, r.read(), r.headers.get("Content-Type")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), None


class TheRealShot(ShotRouteBase):

    def test_serves_the_shot_200(self):
        status, body, ctype = self.fetch(
            "/api/xo/shot/%s/look-1/shot-01.png" % MID)
        self.assertEqual(200, status)
        self.assertEqual(_PNG_MAGIC, body)
        self.assertEqual("image/png", ctype)

    def test_no_store_cache_header(self):
        url = "http://127.0.0.1:%d/api/xo/shot/%s/look-1/shot-01.png" % (
            self.port, MID)
        with urllib.request.urlopen(url, timeout=10) as r:
            self.assertIn("no-store", r.headers.get("Cache-Control", ""))


class Traversal(ShotRouteBase):

    def test_dotdot_segments_404(self):
        status, _, _ = self.fetch(
            "/api/xo/shot/%s/../../state.json.secret-marker" % MID)
        self.assertEqual(404, status)

    def test_dotdot_into_the_look_dir_404(self):
        status, _, _ = self.fetch(
            "/api/xo/shot/%s/look-1/../../../state.json.secret-marker" % MID)
        self.assertEqual(404, status)

    def test_absolute_path_404(self):
        status, _, _ = self.fetch(
            "/api/xo/shot/%s//etc/passwd" % MID)
        self.assertEqual(404, status)

    def test_a_symlink_escaping_the_shots_tree_is_refused(self):
        # REAL PATH containment, not a string check: a symlink INSIDE the
        # shots tree whose target is OUTSIDE it must still 404, because the
        # jail resolves realpath before checking containment.
        d = fx.mission_dir(self.tmp, MID)
        link = os.path.join(d, "xo", "shots", "look-1", "escape.png")
        target = os.path.join(d, "state.json.secret-marker")
        try:
            os.symlink(target, link)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks not supported on this filesystem")
        status, _, _ = self.fetch(
            "/api/xo/shot/%s/look-1/escape.png" % MID)
        self.assertEqual(404, status)

    def test_a_nonexistent_mission_404(self):
        status, _, _ = self.fetch("/api/xo/shot/no-such-mission/shot-01.png")
        self.assertEqual(404, status)

    def test_a_nonexistent_shot_404(self):
        status, _, _ = self.fetch(
            "/api/xo/shot/%s/look-1/nope.png" % MID)
        self.assertEqual(404, status)

    def test_a_non_image_extension_404(self):
        d = fx.mission_dir(self.tmp, MID)
        with open(os.path.join(d, "xo", "shots", "look-1", "notes.txt"), "w") as fh:
            fh.write("not an image")
        status, _, _ = self.fetch(
            "/api/xo/shot/%s/look-1/notes.txt" % MID)
        self.assertEqual(404, status)


class RemoteAdapterNeverGrowsThisRoute(unittest.TestCase):
    """A github/remote adapter has no `xo_shot` at all — the daemon must 404
    cleanly rather than raise."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")

        class _NoShotAdapter(object):
            """Answers `board()`/`mission()` minimally; deliberately carries
            NO `xo_shot` method — the github adapter's real shape."""

            def board(self):
                return {"cards": [], "meta": {}}

            def mission(self, mid):
                return None

            def fingerprint(self):
                return "0"

        self.adapter = _NoShotAdapter()
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def test_404_not_500(self):
        url = "http://127.0.0.1:%d/api/xo/shot/%s/look-1/shot-01.png" % (
            self.port, MID)
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                status = r.status
        except urllib.error.HTTPError as exc:
            status = exc.code
        self.assertEqual(404, status)


def _board_js_xo_shot_url(mid, shots_dir, name):
    """A DELIBERATE MIRROR of `board.js`'s `xoShotUrl`, not a hand-typed path.

    Fix round 2, D1's real lesson: `test_xo_shot_route.py` (this file) proved
    the route in isolation with paths it typed itself, and `test_xo_detail.py`
    proved the payload in isolation — both green while the COMPOSITION
    between them 404ed on every real mission, because board.js's `xoShotUrl`
    prepends `report.shotsDir` (as the API emits it — "shots/look-1", the
    on-disk form) onto a `rel` the route resolves against `xo/shots/`,
    doubling the `shots` segment. This helper closes exactly that gap: it is
    the SAME two-line composition as board.js (encode each non-empty
    `shotsDir` segment, join with "/", prepend it to the shot name) — kept
    intentionally in lockstep with `xoShotUrl` in web/static/board.js rather
    than re-deriving the URL shape independently, so a future edit to one
    without the other is a divergence a human catches by reading both, not a
    reimplementation this test could quietly agree with by mistake."""
    parts = [p for p in str(shots_dir or "shots").split("/") if p]
    dir_ = "/".join(urllib.parse.quote(p, safe="") for p in parts)
    return "/api/xo/shot/%s/%s%s.png" % (
        urllib.parse.quote(mid, safe=""),
        (dir_ + "/") if dir_ else "",
        urllib.parse.quote(name, safe=""))


class CompositionFromTheRealPayload(unittest.TestCase):
    """S205 fix round 2, D1. Not a hand-typed URL: `report.shotsDir` comes
    off a REAL `adapter.mission()` read of a look.txt written exactly the way
    xo.sh:1328 writes it ("shots/<look>", relative to xodir) — the form every
    real S204-and-later mission has on disk — then the shot URL is composed
    the same way board.js's `xoShotUrl` does, and requested for real.

    Before the fix round 2 cure this 404s: `report.shotsDir` rode the on-disk
    "shots/look-1" value unnormalised, so the composed URL doubled the
    `shots` segment (`xo/shots/shots/look-1/…`). After the cure
    `local_adapter._number_one_report` strips that one leading "shots"
    segment before handing `shotsDir` to the API, so the composed URL lands
    on the real file."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")
        d = fx.mission_dir(self.tmp, MID)

        # EXACTLY what xo.sh's `evaluate` writes (xo.sh:1328):
        # `printf 'shots/%s\n' "$look" >"$xodir/look.txt"` — relative to
        # xodir, not to xo/shots. This is the real on-disk form, not a
        # hand-simplified stand-in for it.
        xodir = os.path.join(d, "xo")
        shots = os.path.join(xodir, "shots", "look-1")
        os.makedirs(shots, exist_ok=True)
        with open(os.path.join(shots, "shot-01.png"), "wb") as fh:
            fh.write(_PNG_MAGIC)
        with open(os.path.join(xodir, "look.txt"), "w") as fh:
            fh.write("shots/look-1\n")

        # A journal is the only gate `_number_one_report` checks before it
        # reads look.txt at all (behaviour 1) — content beyond that is
        # irrelevant to this test.
        with open(os.path.join(d, "number-one.jsonl"), "w") as fh:
            fh.write(json.dumps({"at": "2026-09-14T09:00:00Z",
                                 "action": "scored", "score": "high"}) + "\n")

        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def fetch(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return r.status, r.read(), r.headers.get("Content-Type")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), None

    def test_the_payloads_shotsDir_is_normalised(self):
        # The API-emitted value itself, not the on-disk look.txt form — this
        # is what board.js's xoShotUrl actually receives.
        card = self.adapter.mission(MID)
        self.assertEqual("look-1", card["numberOne"]["report"]["shotsDir"])

    def test_the_url_board_js_composes_from_the_real_payload_returns_200(self):
        card = self.adapter.mission(MID)
        shots_dir = card["numberOne"]["report"]["shotsDir"]
        url = _board_js_xo_shot_url(MID, shots_dir, "shot-01")
        status, body, ctype = self.fetch(url)
        self.assertEqual(200, status,
                          "the URL board.js composes from the real "
                          "report.shotsDir must serve the real shot: %s" % url)
        self.assertEqual(_PNG_MAGIC, body)
        self.assertEqual("image/png", ctype)


if __name__ == "__main__":
    unittest.main()
