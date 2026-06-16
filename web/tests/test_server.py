"""The daemon — read API + static front end + live channel (behaviors 3 & 5).

  3. GET /api/board returns the board JSON shape; GET /api/mission/<id> returns
     mission detail incl. an activity feed; GET / serves the static board HTML.
  5. The live channel (/api/events SSE) pushes EXACTLY ONE update when mission
     state changes on disk, and none when nothing changes.

Read-only: there are NO write endpoints — a POST/PUT is rejected.
stdlib only; the daemon runs on an ephemeral localhost port inside the test.
"""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        # poll the live channel fast so the test isn't slow.
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _get(self, path, timeout=5):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read()

    def test_api_board_returns_board_shape(self):
        status, ctype, body = self._get("/api/board")
        self.assertEqual(status, 200)
        self.assertIn("application/json", ctype)
        data = json.loads(body)
        self.assertIn("stages", data)
        self.assertIn("columns", data)
        self.assertEqual([m["issue"] for m in data["columns"]["implement"]], [142])

    def test_api_mission_detail_has_activity_feed(self):
        status, _ctype, body = self._get("/api/mission/m-001")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual(data["id"], "m-001")
        self.assertIn("activity", data)

    def test_api_mission_unknown_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/api/mission/nope")
        self.assertEqual(cm.exception.code, 404)

    def test_root_serves_static_html(self):
        status, ctype, body = self._get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", ctype)
        self.assertIn(b"<!doctype html>", body[:200].lower())
        self.assertIn(b'id="board"', body)

    def test_static_css_shared_token_set(self):
        status, ctype, body = self._get("/lcars.css")
        self.assertEqual(status, 200)
        self.assertIn("text/css", ctype)
        # shares the docs/lcars.css token set — the LCARS amber must be present.
        self.assertIn(b"--lcars", body)

    def test_writes_are_rejected_read_only(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        req = urllib.request.Request(url, data=b"{}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertIn(cm.exception.code, (405, 501))

    def test_live_channel_emits_exactly_one_update_on_state_change(self):
        url = "http://127.0.0.1:%d/api/events" % self.port
        events = []
        stop = threading.Event()

        def listen():
            try:
                with urllib.request.urlopen(url, timeout=5) as r:
                    for raw in r:
                        if stop.is_set():
                            break
                        line = raw.decode("utf-8").strip()
                        if line.startswith("data:"):
                            events.append(line[len("data:"):].strip())
                            if len(events) >= 2:
                                break
            except Exception:
                pass

        t = threading.Thread(target=listen, daemon=True)
        t.start()
        time.sleep(0.3)  # let the initial frame (if any) settle
        baseline = len(events)

        # mutate mission state on disk → the watcher must push ONE update.
        fx.plant_simple(self.tmp, "m-002", stage="plan", issue=300)
        # ensure a distinct mtime
        os.utime(os.path.join(fx.mission_dir(self.tmp, "m-002"), "state.json"),
                 (time.time() + 1, time.time() + 1))

        deadline = time.time() + 3
        while time.time() < deadline and len(events) <= baseline:
            time.sleep(0.05)
        stop.set()

        new = events[baseline:]
        self.assertEqual(len(new), 1,
                         "expected exactly one live update, got %r" % (new,))

    def test_burst_of_writes_coalesces_to_single_update(self):
        """Finding B (S67 fix-loop r1): one LOGICAL change writes several files
        (state.json, estimate.json, events.jsonl, …) and those writes land
        across multiple poll ticks. The live channel must coalesce that burst to
        ONE `update` push — not one per file/tick (the tester saw ~4)."""
        url = "http://127.0.0.1:%d/api/events" % self.port
        events = []
        stop = threading.Event()

        def listen():
            try:
                with urllib.request.urlopen(url, timeout=8) as r:
                    for raw in r:
                        if stop.is_set():
                            break
                        line = raw.decode("utf-8").strip()
                        if line.startswith("data:"):
                            events.append(line[len("data:"):].strip())
            except Exception:
                pass

        t = threading.Thread(target=listen, daemon=True)
        t.start()
        time.sleep(0.3)
        baseline = len(events)

        # Simulate a filing: write several files for ONE new mission, each a poll
        # tick (0.05s) apart, so the burst genuinely spans multiple ticks.
        d = fx.mission_dir(self.tmp, "m-003")
        os.makedirs(d, exist_ok=True)
        for i, (fname, payload) in enumerate([
            ("state.json", {"id": "m-003", "stage": "plan", "title": "Burst",
                            "githubIssue": 303, "branch": "lcars/m-003",
                            "base": "main", "type": "feature"}),
            ("estimate.json", fx.ESTIMATE_CLAUDE),
            ("plan.json", [{"id": "t-1", "title": "x",
                            "acceptanceCriteria": ["x"], "dependencies": []}]),
            ("waves.json", [{"wave": 1, "tickets": [{"id": "t-1", "issue": 9}]}]),
        ]):
            fx.write_json(os.path.join(d, fname), payload)
            ts = time.time() + 10 + i  # distinct, monotonically-rising mtimes
            os.utime(os.path.join(d, fname), (ts, ts))
            time.sleep(0.06)

        # Let the burst settle and drain any further (erroneous) pushes.
        time.sleep(1.0)
        stop.set()

        new = events[baseline:]
        self.assertEqual(len(new), 1,
                         "burst of writes must coalesce to ONE update, got %d: %r"
                         % (len(new), new))


if __name__ == "__main__":
    unittest.main()
