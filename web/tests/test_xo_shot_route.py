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


class S224_ThePicturesOfTheLookTheVerdictCameFrom(unittest.TestCase):
    """S224 fix round 1, D4 — the captain: *"What happened to the pictures
    being inline?"*

    Every row of his re-checked mission read "The picture for this one
    (recheck-walk-01-j1) isn't on this laptop any more" over a file that is on
    his disk at `…/xo/shots/recheck-3/recheck-walk-01-j1.png`. Measured live
    against his own daemon before a line was changed:

        /api/xo/shot/<mid>/look-1/recheck-walk-01-j1.png    → 404
        /api/xo/shot/<mid>/recheck-3/recheck-walk-01-j1.png → 200

    The route was never wrong. `look.txt` is written ONCE, by `evaluate`, and
    points at the first look; a re-check opens `shots/recheck-<n>` and recorded
    no pointer to it. So the payload carried ONE directory for TWO verdicts,
    and since S224 the pane draws the SECOND one. `shotsDir` still belongs to
    the first look — the filed gaps' thumbnails render off it and they were
    never broken — and `shotsDir2` is the second pointer beside it.

    A mission re-checked BEFORE that pointer existed (every one on his disk)
    gets it resolved against the record instead: the second verdict names the
    shots it reasoned from, and the answer is the directory that holds them.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify")
        self.d = fx.mission_dir(self.tmp, MID)
        self.xodir = os.path.join(self.d, "xo")

        # THE SHAPE OF HIS OWN MISSION, not a simplified stand-in: a first
        # look, an ABORTED re-check that left an empty directory behind, and
        # the real re-check. The aborted one is the reason "the first one you
        # find" is not an answer.
        self._plant("look-1", ["shot-walk-00-wayin", "shot-walk-01-j1"])
        self._plant("recheck-1", [])
        self._plant("recheck-2", ["recheck-walk-00-wayin", "recheck-walk-01-j1"])
        with open(os.path.join(self.xodir, "look.txt"), "w") as fh:
            fh.write("shots/look-1\n")

        self._verdict("verdict.json", "shot-walk-")
        os.makedirs(os.path.join(self.xodir, "second"), exist_ok=True)
        self._verdict(os.path.join("second", "verdict.json"), "recheck-walk-")

        with open(os.path.join(self.d, "number-one.jsonl"), "w") as fh:
            fh.write(json.dumps({"at": "2026-09-20T09:00:00Z",
                                 "action": "rescored", "score": "low"}) + "\n")
        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def _plant(self, look, names):
        room = os.path.join(self.xodir, "shots", look)
        os.makedirs(room, exist_ok=True)
        for n in names:
            with open(os.path.join(room, n + ".png"), "wb") as fh:
                fh.write(_PNG_MAGIC)

    def _verdict(self, rel, stem):
        doc = {"score": "low", "criteria": [
            {"id": "prd-1", "status": "gap", "evidence": "picture",
             "shot": stem + "00-wayin"},
            {"id": "prd-2", "status": "gap", "evidence": "picture",
             "shot": stem + "01-j1"}]}
        with open(os.path.join(self.xodir, rel), "w") as fh:
            json.dump(doc, fh)

    def report(self):
        return self.adapter.mission(MID)["numberOne"]["report"]

    def fetch(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    def test_the_first_looks_pointer_is_untouched(self):
        """The gaps he filed were filed on that look; their thumbnails render
        off this value and they were never the broken ones."""
        self.assertEqual("look-1", self.report()["shotsDir"])

    def test_the_second_verdict_gets_its_own_directory(self):
        self.assertEqual("recheck-2", self.report().get("shotsDir2"))

    def test_the_url_board_js_composes_for_a_recheck_shot_returns_200(self):
        # Composed the way board.js composes it, from the value the API
        # actually emits — the composition, not two halves proven apart.
        r = self.report()
        url = _board_js_xo_shot_url(MID, r["shotsDir2"], "recheck-walk-01-j1")
        status, body = self.fetch(url)
        self.assertEqual(200, status, "the re-check's picture must serve: " + url)
        self.assertEqual(_PNG_MAGIC, body)
        # …and the value it was rendered against before this fix still 404s,
        # which is the defect, stated as a fact rather than as a memory.
        self.assertEqual(404, self.fetch(
            _board_js_xo_shot_url(MID, r["shotsDir"], "recheck-walk-01-j1"))[0])

    def test_an_aborted_recheck_does_not_win_by_coming_first(self):
        """`recheck-1` sorts before `recheck-2` and holds none of the shots
        the verdict names. Most-held wins; first-found is not an answer."""
        self.assertEqual("recheck-2", self.report().get("shotsDir2"))

    def test_the_recorded_pointer_beats_the_resolution(self):
        """What `xo.sh` now writes as the re-check opens its directory. A
        record always outranks a derivation — same rule as look.txt."""
        self._plant("recheck-9", ["recheck-walk-01-j1"])
        with open(os.path.join(self.xodir, "second", "look.txt"), "w") as fh:
            fh.write("shots/recheck-9\n")
        self.assertEqual("recheck-9", self.report().get("shotsDir2"))

    def test_a_mission_looked_at_once_carries_no_second_pointer(self):
        os.remove(os.path.join(self.xodir, "second", "verdict.json"))
        r = self.report()
        self.assertEqual("look-1", r["shotsDir"])
        self.assertNotIn("shotsDir2", r,
                         "a single look must not grow a second directory")


if __name__ == "__main__":
    unittest.main()
