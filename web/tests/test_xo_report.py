"""S205 behaviours 4 and 6 — the First Officer's report, over HTTP.

  4. `GET /api/xo/report`: entries after `lastSeenAt` are "new", with a count;
     `POST /api/xo/seen` moves them into history and updates
     `.git/lcars/xo-seen.json`; NOTHING is ever deleted — a mission's whole
     journal stays in `history` whether or not it is "new".
  6. `lcars xo report` (the CLI) and `GET /api/xo/report` (this route) split
     the SAME fixture identically — both call `xo-report.py`'s own
     `build_report`, so this is a parity proof by construction, not by
     hand-matching two independent readers.

No gh, no network, no model, no worker.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

XO_SCRIPT = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo.sh"))
MID1 = "lcars-20260914-701"
MID2 = "lcars-20260914-702"


def _write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


class XoReportBase(unittest.TestCase):

    def setUp(self):
        if not os.path.isfile(XO_SCRIPT):
            self.skipTest("xo.sh not present in this tree")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # A real git repo + config, so `xo.sh report` (the CLI half of the
        # parity proof) can run for real, exactly as tests/lcars-xo.test.sh's
        # own B22 does.
        subprocess.run(["git", "init", "-q"], cwd=self.tmp, check=True)
        os.makedirs(os.path.join(self.tmp, ".git", "lcars"), exist_ok=True)
        with open(os.path.join(self.tmp, ".git", "lcars", "config.json"), "w") as fh:
            json.dump({"numberOne": {"enabled": True, "engine": "copilot"}}, fh)

        fx.plant_simple(self.tmp, MID1, stage="verify", issue=901,
                        title="The task board")
        fx.plant_simple(self.tmp, MID2, stage="verify", issue=902,
                        title="Dark mode")
        _write_jsonl(fx.mission_dir(self.tmp, MID1) + "/number-one.jsonl", [
            {"at": "2026-09-14T10:00:00Z", "action": "scored",
             "score": "high", "why": "all criteria met"},
            {"at": "2026-09-14T11:00:00Z", "action": "escalated",
             "detail": "the lock glyph is missing"},
        ])
        _write_jsonl(fx.mission_dir(self.tmp, MID2) + "/number-one.jsonl", [
            {"at": "2026-09-14T09:00:00Z", "action": "scored",
             "score": "medium", "why": "one gap"},
        ])

        self.adapter = LocalAdapter(self.tmp)
        self.actions = Actions(repo_root=self.tmp,
                               scripts={"xo": XO_SCRIPT},
                               worker_bin="/bin/echo")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def get(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, json.loads(r.read())

    def post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj or {}).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())

    def cli_report(self, *args):
        proc = subprocess.run(
            ["bash", XO_SCRIPT, "report"] + list(args), cwd=self.tmp,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
        return proc.stdout.decode("utf-8")


class SinceAndHistory(XoReportBase):

    def test_everything_is_new_the_first_time(self):
        status, body = self.get("/api/xo/report")
        self.assertEqual(200, status)
        self.assertEqual(3, body["since"]["count"])
        self.assertIsNone(body["lastSeenAt"])

    def test_history_folds_BOTH_missions_nothing_dropped(self):
        _, body = self.get("/api/xo/report")
        ids = {h["id"] for h in body["history"] if h["entries"]}
        self.assertEqual({MID1, MID2}, ids)

    def test_every_since_entry_is_marked_new(self):
        _, body = self.get("/api/xo/report")
        self.assertTrue(all(e["new"] for e in body["since"]["entries"]))

    def test_seen_moves_them_out_of_since_but_deletes_nothing(self):
        status, seen_body = self.post("/api/xo/seen")
        self.assertEqual(200, status)
        self.assertTrue(seen_body.get("ok"))
        # POST write responses wrap the result under {"ok": true, "state": …}
        # (server.py's do_POST contract) — the fresh report rides in `state`.
        self.assertIsNotNone(seen_body["state"].get("lastSeenAt"))
        self.assertTrue(os.path.isfile(
            os.path.join(self.tmp, ".git", "lcars", "xo-seen.json")))

        _, after = self.get("/api/xo/report")
        self.assertEqual(0, after["since"]["count"])
        total_history_entries = sum(len(h["entries"]) for h in after["history"])
        self.assertEqual(3, total_history_entries)

    def test_a_NEW_entry_after_seen_is_new_again(self):
        # `--mark-seen` deliberately advances `lastSeenAt` to the REAL wall
        # clock, not to the newest entry's own timestamp (xo-report.py's own
        # rule: "seen" means as of the moment you looked, not as of the last
        # thing you saw) — so the new entry below is dated far in the future
        # of any real clock this suite ever runs on, rather than "one second
        # after" the fixture's fixed 2026-09-14 dates.
        self.post("/api/xo/seen")
        _write_jsonl(fx.mission_dir(self.tmp, MID1) + "/number-one.jsonl", [
            {"at": "2026-09-14T10:00:00Z", "action": "scored",
             "score": "high", "why": "all criteria met"},
            {"at": "2026-09-14T11:00:00Z", "action": "escalated",
             "detail": "the lock glyph is missing"},
            {"at": "2099-01-01T00:00:00Z", "action": "rescored",
             "detail": "a fresh look, after seen"},
        ])
        _, after = self.get("/api/xo/report")
        self.assertEqual(1, after["since"]["count"])
        self.assertEqual("rescored", after["since"]["entries"][0]["action"])


class CliApiParity(XoReportBase):

    def test_since_count_matches(self):
        _, api = self.get("/api/xo/report")
        cli_text = self.cli_report("--all")
        import re
        m = re.search(r"Since you last looked \((\d+)\)", cli_text)
        self.assertIsNotNone(m)
        self.assertEqual(api["since"]["count"], int(m.group(1)))

    def test_history_mission_count_matches(self):
        _, api = self.get("/api/xo/report")
        cli_text = self.cli_report("--all")
        api_missions = len([h for h in api["history"] if h["entries"]])
        cli_missions = sum(
            1 for line in cli_text.splitlines()
            if line.startswith("  ") and not line.startswith("   ")
            and "(#" in line and line.rstrip().endswith(")")
            and "—" not in line)
        self.assertEqual(api_missions, cli_missions)

    def test_one_mission_scoped_report_matches_too(self):
        _, api = self.get("/api/xo/report")
        one = [h for h in api["history"] if h["id"] == MID1][0]
        cli_text = self.cli_report(MID1, "--all")
        for entry in one["entries"]:
            self.assertIn(entry["action"], cli_text)


class RemoteAdapterHasNoLocalReport(unittest.TestCase):
    """A github/remote board has `adapter.xo_report` absent entirely — the
    route must 404, not 500 or serve a phantom empty report."""

    def test_no_xo_report_method_on_a_bare_object(self):
        class Bare(object):
            pass
        self.assertFalse(callable(getattr(Bare(), "xo_report", None)))


if __name__ == "__main__":
    unittest.main()
