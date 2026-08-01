"""S161 — the DAEMON owns the authored mission-log bugs (`_LogSession`).

Before this session the whole Mission-Log flow lived in CLIENT memory
(`board.js` openLog's `var authored = {prds: null, ...}`): the authored bug PRDs
existed only on the Preview response and were only ever sent by the File POST.
Close the console between Preview and File and the PRDs were GONE — the captain
had to re-run (and re-pay for) the split worker.

S161 moves them server-side, mirroring the Align console's `_AlignSession`:

  * `POST /api/mission/<id>/log` (authoring preview) creates a session and
    returns its `sessionId` ALONGSIDE today's payload (additive).
  * `POST /api/mission/<id>/log/file` accepts `sessionId` INSTEAD of a `prds`
    body and DISPATCHES the file+estimate work, so the POST returns PROMPTLY.
    Status walks `previewed` → `filing` → `filed` / `failed`.
  * `GET  /api/mission/<id>/log/session` restores a reopened console exactly
    where the captain left it.
  * an ADDITIVE `logFiling {sessionId,status,bugCount,filedCount}` board stamp on
    the PARENT card (mirroring `alignResume`) — no session ⇒ byte-identical board.
  * the LEGACY prds-in-body File path stays byte-identical.
  * BUG-059's hold is preserved: `filed` NEVER auto-dispatches `/log/run`.

Every skill call is a recording stub (log.sh plants child missions + estimates
the way the real one does) and the split worker is a canned-turn stub, so the
whole suite costs ZERO tokens.

stdlib only; the daemon runs on an ephemeral localhost port inside the test.
"""
import copy
import glob
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
from lcars_serve.actions import Actions  # noqa: E402


BUG_A = ("# Mission: XP not awarded on video completion\n\n"
         "**Type:** bug\n**Goal:** Award XP on video complete.\n"
         "**Acceptance Criteria:**\n- xp\n**Out of Scope:**\n- n\n"
         "**Constraints:**\n- c\n")
BUG_B = ("# Mission: Leaderboard flicker on first load\n\n"
         "**Type:** bug\n**Goal:** No flicker.\n"
         "**Acceptance Criteria:**\n- ok\n**Out of Scope:**\n- n\n"
         "**Constraints:**\n- c\n")
# A bug PRD the REAL log.sh rejects: no `# Mission:` title line. `_log_author`
# authors it happily (it only needs a non-empty string), so the captain can and
# does reach File with one of these in the batch — which is exactly the D1
# scenario: log.sh prints its validation error, files NOTHING, and still exits 0.
BUG_MALFORMED = ("**Type:** bug\n**Goal:** Someone forgot the title line.\n"
                 "**Acceptance Criteria:**\n- x\n")


def _worker_stub(turns_path, prompt_log):
    """$LCARS_WORKER_BIN stand-in: log the prompt, print the next canned turn."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
prompt=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then prompt="$a"; fi
  prev="$a"
done
printf "===PROMPT===\n%s\n" "$prompt" >> "PROMPTLOG"
idx_file="TURNS.idx"
i=0
[ -f "$idx_file" ] && i=$(cat "$idx_file")
awk -v want="$i" 'BEGIN{n=0} /^===TURN===$/{n++; next} {if(n==want) print}' "TURNS"
echo $((i+1)) > "$idx_file"
exit 0
'''.replace("PROMPTLOG", prompt_log).replace("TURNS", turns_path)
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


def _log_sh_stub(record_path, root, est_path, slow_flag, fail_flag,
                 seq_file=None, refuse_flag=None):
    """A log.sh stand-in that behaves like the real one where it matters.

    * records the argv it saw (so the dispatch can be asserted byte-for-byte);
    * for every WELL-FORMED `--prd <path>` it PLANTS a linked child mission on
      disk with an `estimate.json` — exactly what the real log.sh does when it
      runs the estimator per child, so the "estimates land" behaviour is
      observable. Child ids come from a PERSISTENT counter (`seq_file`), so a
      second invocation cannot collide with (or silently overwrite) a child the
      first one planted — the real log.sh mints a fresh id per bug too, and the
      retry-only-the-unfiled path (N1) files in a second invocation;
    * refuses any bug whose title CONTAINS the text in `refuse_flag`, printing a
      log.sh-style refusal and planting nothing — a per-bug, CLEARABLE fault, so a
      test can make one bug of a batch fail and then succeed on the retry (the
      transient-failure case a retry exists for);
    * for a `--prd` with NO `# Mission:` title line it prints the real script's
      validation line, plants NOTHING — and STILL EXITS 0. That is not stub
      licence: the real `log.sh` calls `file_one_bug` inside a command
      substitution (`ROWS+=("$(file_one_bug …)")`), so its `die`'s `exit 1` kills
      only the SUBSHELL and the batch sails on to `exit 0`. Reproducing that lie
      is the whole point — a caller that trusts the exit code reports a batch
      that filed nothing as `filed` (D1);
    * sleeps while `slow_flag` exists (so a test can prove the file POST returns
      BEFORE the estimator finishes);
    * exits non-zero while `fail_flag` exists (the failed-file path).
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
printf "ARGV: %s\n" "$*" >> "REC"
if [ -f "SLOWFLAG" ]; then sleep "$(cat SLOWFLAG)"; fi
if [ -f "FAILFLAG" ]; then
  echo "log.sh: refusing to file — the bug PRD is missing its Goal section"
  exit 3
fi
args=("$@")
parent=""
n=0
[ -f "SEQFILE" ] && n=$(cat "SEQFILE")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  if [ "$a" = "--parent" ]; then
    parent="${args[$((i+1))]}"; i=$((i+2)); continue
  fi
  if [ "$a" = "--prd" ]; then
    p="${args[$((i+1))]}"; i=$((i+2))
    n=$((n+1))
    if ! grep -q '^# Mission:' "$p"; then
      # the real log.sh's die, swallowed by its own command substitution.
      echo "lcars log: bug PRD $p is missing its '# Mission:' title line." >&2
      continue
    fi
    title=$(sed -n 's/^# Mission: //p' "$p" | head -1)
    [ -n "$title" ] || title="Untitled bug"
    if [ -f "REFUSEFLAG" ]; then
      case "$title" in
        *"$(cat REFUSEFLAG)"*)
          echo "lcars log: bug PRD $p was refused upstream — the issue was not created." >&2
          continue ;;
      esac
    fi
    d="ROOT/.git/lcars/missions/m-bug$n"
    mkdir -p "$d"
    cat > "$d/state.json" <<EOF
{"id":"m-bug$n","type":"bug","title":"$title","stage":"plan",
 "created":"2026-08-01T10:00:00Z","githubIssue":$((300+n)),
 "parentMission":"$parent","origin":"log","linked":true,
 "branch":"lcars/m-bug$n","base":"main"}
EOF
    cp "ESTPATH" "$d/estimate.json"
    continue
  fi
  i=$((i+1))
done
echo "$n" > "SEQFILE"
exit 0
'''.replace("REC", record_path).replace("ROOT", root).replace(
        "ESTPATH", est_path).replace("SLOWFLAG", slow_flag).replace(
        "FAILFLAG", fail_flag).replace(
        "SEQFILE", seq_file or (record_path + ".seq")).replace(
        "REFUSEFLAG", refuse_flag or (record_path + ".refuse"))
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


def _plain_stub(record_path):
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\nprintf "ARGV: %s\\n" "$*" >> "'
                 + record_path + '"\nexit 0\n')
    os.chmod(path, 0o755)
    return path


class LogSessionBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)

        self.turns_path = os.path.join(self.tmp, "turns.txt")
        self.prompt_log = os.path.join(self.tmp, "prompts.txt")
        self.slow_flag = os.path.join(self.tmp, "SLOW")
        self.fail_flag = os.path.join(self.tmp, "FAIL")
        # a per-bug, clearable refusal (any bug whose title contains this text)
        # + the stub's persistent child-id counter, so a RETRY invocation cannot
        # collide with the children the first pass planted.
        self.refuse_flag = os.path.join(self.tmp, "REFUSE")
        self.seq_file = os.path.join(self.tmp, "SEQ")
        self.est_path = os.path.join(self.tmp, "estimate.json")
        with open(self.est_path, "w") as fh:
            json.dump(fx.ESTIMATE_FASTTRACK_BUG, fh)

        self.records = {"log": os.path.join(self.tmp, "rec-log.txt"),
                        "resolve": os.path.join(self.tmp, "rec-resolve.txt"),
                        "file": os.path.join(self.tmp, "rec-file.txt")}
        self.scripts = {
            "log": _log_sh_stub(self.records["log"], self.tmp, self.est_path,
                                self.slow_flag, self.fail_flag,
                                seq_file=self.seq_file,
                                refuse_flag=self.refuse_flag),
            "resolve": _plain_stub(self.records["resolve"]),
            "file": _plain_stub(self.records["file"]),
        }
        self.worker_bin = _worker_stub(self.turns_path, self.prompt_log)
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin=self.worker_bin)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    # -- helpers ------------------------------------------------------------
    def _set_turns(self, *blobs):
        # reset the stub's turn cursor so a second preview in one test replays
        # from turn 0 (the cursor file survives a re-write of the turns).
        idx = self.turns_path + ".idx"
        if os.path.exists(idx):
            os.unlink(idx)
        with open(self.turns_path, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(json.dumps(b) + "\n")

    def _post(self, path, obj=None, timeout=30):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _get(self, path, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _record(self, key):
        p = self.records[key]
        if not os.path.exists(p):
            return ""
        with open(p) as fh:
            return fh.read()

    def _preview(self, *bugs, **kw):
        """Author `bugs` via the stubbed split worker; return the state dict.

        `discard_unfiled=True` (S161 fix round 3, R1) is the captain's explicit
        consent to lose the authored text a live session still holds unfiled — the
        daemon refuses such a re-preview without it.
        """
        self._set_turns({"bugs": list(bugs)})
        body = {"text": kw.get("text", "XP is broken. Leaderboard flickers.")}
        if kw.get("images"):
            body["images"] = kw["images"]
        if kw.get("discard_unfiled"):
            body["discardUnfiled"] = True
        status, resp = self._post("/api/mission/m-001/log", body)
        self.assertEqual(status, 200)
        return resp["state"]

    def _await_status(self, sid_path, want, timeout=20.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            _s, resp = self._get(sid_path)
            last = resp
            if resp.get("status") == want:
                return resp
            time.sleep(0.05)
        self.fail("session never reached status %r (last: %r)" % (want, last))

    def _cards(self, board):
        out = []
        for col in (board.get("columns") or {}).values():
            if isinstance(col, list):
                out.extend([c for c in col if isinstance(c, dict)])
        return out

    def _stamp(self, mid="m-001"):
        _s, board = self._get("/api/board")
        for c in self._cards(board):
            if c["id"] == mid:
                return c.get("logFiling")
        self.fail("no card for %s on the board" % mid)

    def _on_disk(self):
        """The bug-mission dirs the (stubbed) log.sh actually planted."""
        return sorted(os.path.basename(p) for p in glob.glob(
            os.path.join(self.tmp, ".git", "lcars", "missions", "m-bug*")))

    def _argvs(self):
        """One entry per log.sh invocation, in order."""
        return [ln[len("ARGV: "):] for ln in self._record("log").splitlines()
                if ln.startswith("ARGV: ")]

    def _splits(self):
        """How many split-worker turns were spent (each one is a real ~25s bill)."""
        if not os.path.exists(self.prompt_log):
            return 0
        with open(self.prompt_log) as fh:
            return fh.read().count("===PROMPT===")

    def _refuse(self, needle):
        """Make the stub refuse any bug whose title contains `needle` (per-bug)."""
        with open(self.refuse_flag, "w") as fh:
            fh.write(needle)

    def _allow_all(self):
        if os.path.exists(self.refuse_flag):
            os.unlink(self.refuse_flag)

    def _post_err(self, path, obj=None):
        """POST expecting a refusal; returns (code, error message)."""
        try:
            self._post(path, obj)
        except urllib.error.HTTPError as exc:
            return exc.code, (json.loads(exc.read()) or {}).get("error") or ""
        self.fail("POST %s was expected to be refused" % path)


# ── behaviour 1: preview → a sessionId; the session holds the PRDs ───────────
class PreviewCreatesSessionTest(LogSessionBase):
    def test_preview_returns_session_id_holding_the_authored_prds(self):
        st = self._preview(BUG_A, BUG_B)
        sid = st.get("sessionId")
        self.assertTrue(sid, "the authoring preview must return a sessionId")
        # the DAEMON holds the authored PRDs now — not the browser.
        sess = self.actions._log_sessions[sid]
        self.assertEqual(sess.parent, "m-001")
        self.assertEqual(sess.prds, [BUG_A, BUG_B])
        self.assertEqual(sess.status, "previewed")
        # today's payload is still all there (purely additive).
        self.assertEqual(st["count"], 2)
        self.assertTrue(st["authored"])
        self.assertEqual(sorted(c["title"] for c in st["children"]),
                         ["Leaderboard flicker on first load",
                          "XP not awarded on video completion"])

    def test_read_only_preview_creates_no_session(self):
        """No text ⇒ the read-only linked-children preview. Nothing authored, so
        nothing to hold: no sessionId, no session, payload byte-identical."""
        fx.plant_simple(self.tmp, "m-bug9", stage="plan", issue=209,
                        parent_mission="m-001", mtype="bug")
        status, resp = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        st = resp["state"]
        self.assertNotIn("sessionId", st)
        self.assertEqual(sorted(st.keys()),
                         ["authored", "children", "count", "parent"])
        self.assertEqual(self.actions._log_sessions, {})

    def test_second_preview_replaces_the_parents_session(self):
        first = self._preview(BUG_A)["sessionId"]
        second = self._preview(BUG_A, BUG_B)["sessionId"]
        self.assertNotEqual(first, second)
        self.assertNotIn(first, self.actions._log_sessions)
        self.assertEqual(self.actions._log_sessions[second].prds, [BUG_A, BUG_B])


# ── behaviour 2 + 3: file-by-sessionId returns promptly; estimates land ──────
class FileBySessionTest(LogSessionBase):
    def test_file_by_session_id_returns_promptly_then_files(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        # make the (stubbed) log.sh estimator take a beat.
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        t0 = time.time()
        status, resp = self._post("/api/mission/m-001/log/file",
                                  {"sessionId": sid})
        elapsed = time.time() - t0
        self.assertEqual(status, 200)
        st = resp["state"]
        self.assertEqual(st["sessionId"], sid)
        self.assertEqual(st["status"], "filing")
        self.assertLess(elapsed, 1.5,
                        "the file POST must DISPATCH, not hold for the estimator "
                        "(took %.2fs)" % elapsed)
        # ... and it really does finish, moving filing → filed.
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual((done["bugCount"], done["filedCount"]), (2, 2))
        self.assertEqual(self.actions._log_sessions[sid].status, "filed")

    def test_file_by_session_id_dispatches_one_prd_per_bug_with_estimates(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        rec = self._record("log")
        self.assertIn("--parent m-001", rec)
        self.assertEqual(rec.count("--prd"), 2,
                         "one --prd per authored bug, as the legacy path does")
        # the estimator ran per child: each child's estimate.json is on disk and
        # the restored session carries its cost/difficulty pills.
        for child in ("m-bug1", "m-bug2"):
            self.assertTrue(os.path.isfile(os.path.join(
                self.tmp, ".git", "lcars", "missions", child, "estimate.json")),
                "%s must have an estimate.json" % child)
        _s, resp = self._get("/api/mission/m-001/log/session")
        ids = sorted(c["id"] for c in resp["children"])
        self.assertEqual(ids, ["m-bug1", "m-bug2"])
        self.assertTrue(all(c.get("pills") for c in resp["children"]),
                        "each filed child must carry its estimate pills")

    def test_file_by_session_id_threads_per_bug_overrides(self):
        """The captain's per-bug steer travels on the SESSION (edited in the
        console), so filing by sessionId still reaches log.sh's --model-override."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file",
                   {"sessionId": sid, "overrides": ["all:opus", ""]})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertIn("--model-override all:opus", self._record("log"))

    def test_pasted_screenshots_ride_the_session_into_filing(self):
        """S92 must survive S161: the captain pastes a screenshot into the report
        box at PREVIEW time and then files by sessionId — a body that carries no
        images at all. The session holds the pastes, so each filed bug still gets
        its durable `--attach`."""
        st = self._preview(BUG_A, images=[
            {"name": "shot.png", "type": "image/png",
             "dataB64": "iVBORw0KGgo="}])
        sid = st["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        rec = self._record("log")
        self.assertIn("--attach", rec,
                      "the previewed screenshot must still reach log.sh")
        self.assertIn("lcars-img-", rec)
        # and no staged copy is left behind in the repo.
        self.assertEqual(
            sorted(glob.glob(os.path.join(self.tmp, ".git", "lcars", "tmp",
                                          "lcars-img-*"))), [])

    def test_file_by_unknown_session_id_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/log/file", {"sessionId": "nope"})
        self.assertEqual(cm.exception.code, 404)

    def test_file_by_session_id_of_another_parent_is_409(self):
        fx.plant_simple(self.tmp, "m-002", stage="verify", issue=143)
        sid = self._preview(BUG_A)["sessionId"]
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-002/log/file", {"sessionId": sid})
        self.assertEqual(cm.exception.code, 409)

    def test_refiling_an_already_filed_session_is_refused(self):
        """A second File after the batch landed would re-run log.sh over the SAME
        PRDs — duplicating every bug child and re-spending the estimator."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self.assertEqual(cm.exception.code, 409)
        self.assertEqual(self._record("log").count("ARGV:"), 1)
        self.assertEqual(self.actions._log_sessions[sid].status, "filed")

    def test_double_file_by_session_id_files_once(self):
        """A second click while the first dispatch is in flight must not re-file
        (that would duplicate every bug child and re-spend the estimator)."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        _s, resp = self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self.assertEqual(resp["state"]["status"], "filing")
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(self._record("log").count("ARGV:"), 1,
                         "log.sh must be dispatched exactly once")


# ── behaviour 4: GET the session mid-filing → filing; after → filed ──────────
class SessionRestoreTest(LogSessionBase):
    def test_get_session_after_preview_restores_the_authored_bugs(self):
        """The captain previews, CLOSES the console (the connection dies), then
        reopens it. The authored PRDs must still be there — no re-split, no
        re-spend."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        status, resp = self._get("/api/mission/m-001/log/session")
        self.assertEqual(status, 200)
        self.assertEqual(resp["sessionId"], sid)
        self.assertEqual(resp["status"], "previewed")
        self.assertEqual(resp["parent"], "m-001")
        self.assertTrue(resp["authored"])
        self.assertFalse(resp["filed"])
        self.assertEqual((resp["bugCount"], resp["filedCount"]), (2, 0))
        self.assertEqual([c["prd"] for c in resp["children"]], [BUG_A, BUG_B])

    def test_get_session_mid_filing_reports_filing_then_filed(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        _s, mid_flight = self._get("/api/mission/m-001/log/session")
        self.assertEqual(mid_flight["status"], "filing")
        self.assertFalse(mid_flight["filed"],
                         "a mid-flight session must NEVER read as filed")
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertTrue(done["filed"])
        self.assertEqual((done["bugCount"], done["filedCount"]), (2, 2))
        self.assertTrue(all(c.get("pills") for c in done["children"]))

    def test_get_session_when_none_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/api/mission/m-001/log/session")
        self.assertEqual(cm.exception.code, 404)

    def test_get_session_for_unknown_mission_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/api/mission/nope/log/session")
        self.assertEqual(cm.exception.code, 404)

    def test_get_session_does_not_dispatch_anything(self):
        self._preview(BUG_A)
        self._get("/api/mission/m-001/log/session")
        self.assertEqual(self._record("log"), "")
        self.assertEqual(self._record("resolve"), "")


# ── behaviour 5: the LEGACY prds-in-body File path is byte-identical ─────────
class LegacyFilePathTest(LogSessionBase):
    LEGACY_KEYS = ["children", "count", "filed", "overrides", "parent"]

    def test_legacy_prds_in_body_response_shape_is_unchanged(self):
        status, resp = self._post(
            "/api/mission/m-001/log/file",
            {"prds": [BUG_A, BUG_B], "overrides": ["", ""]})
        self.assertEqual(status, 200)
        st = resp["state"]
        self.assertEqual(sorted(st.keys()), self.LEGACY_KEYS,
                         "the legacy File response must gain NO new keys")
        self.assertTrue(st["filed"])
        self.assertEqual(st["count"], 2)
        # it BLOCKED: the children are already on disk when the POST returns.
        self.assertEqual(sorted(c["id"] for c in st["children"]),
                         ["m-bug1", "m-bug2"])

    def test_legacy_prds_in_body_dispatch_is_unchanged(self):
        self._post("/api/mission/m-001/log/file",
                   {"prds": [BUG_A], "overrides": ["reasoning:opus"]})
        rec = self._record("log")
        self.assertIn("--parent m-001", rec)
        self.assertIn("--model-override reasoning:opus", rec)
        self.assertEqual(self._record("resolve"), "")

    def test_legacy_file_creates_no_session_and_no_overlay(self):
        self._post("/api/mission/m-001/log/file", {"prds": [BUG_A]})
        self.assertEqual(self.actions._log_sessions, {})
        _s, board = self._get("/api/board")
        self.assertTrue(all("logFiling" not in c for c in self._cards(board)))

    def test_legacy_file_still_blocks_for_the_estimator(self):
        """Pre-161 semantics: the prds-in-body POST HELD until every child was
        filed and estimated. That must not change (an old client depends on it)."""
        with open(self.slow_flag, "w") as fh:
            fh.write("1\n")
        t0 = time.time()
        _s, resp = self._post("/api/mission/m-001/log/file", {"prds": [BUG_A]})
        self.assertGreaterEqual(time.time() - t0, 1.0)
        self.assertTrue(resp["state"]["filed"])


# ── behaviour 6: an ADDITIVE logFiling board stamp ───────────────────────────
class LogOverlayTest(LogSessionBase):
    def test_no_session_leaves_the_board_byte_identical(self):
        _s, before = self._get("/api/board")
        self.assertTrue(all("logFiling" not in c for c in self._cards(before)))
        # unit-level: the overlay is a no-op passthrough with no live session.
        board = self.adapter.board()
        snapshot = copy.deepcopy(board)
        self.assertEqual(self.actions.log_overlay(board), snapshot)

    def test_live_session_stamps_log_filing_on_the_parent_card(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        _s, board = self._get("/api/board")
        parents = [c for c in self._cards(board) if c["id"] == "m-001"]
        self.assertEqual(len(parents), 1)
        stamp = parents[0].get("logFiling")
        # D2: two counts, two self-describing names — `bugCount` is how many bugs
        # this batch is, `filedCount` how many of them are on disk (0 until the
        # filing lands). The old ambiguous `count` is gone.
        self.assertEqual(stamp, {"sessionId": sid, "status": "previewed",
                                 "bugCount": 2, "filedCount": 0})
        # only the parent is stamped.
        others = [c for c in self._cards(board) if c["id"] != "m-001"]
        self.assertTrue(all("logFiling" not in c for c in others))

    def test_stamp_tracks_the_status_through_filing_to_filed(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        _s, board = self._get("/api/board")
        card = [c for c in self._cards(board) if c["id"] == "m-001"][0]
        self.assertEqual(card["logFiling"]["status"], "filing")
        self._await_status("/api/mission/m-001/log/session", "filed")
        _s, board = self._get("/api/board")
        card = [c for c in self._cards(board) if c["id"] == "m-001"][0]
        self.assertEqual(card["logFiling"]["status"], "filed")

    def test_mission_detail_mirrors_the_stamp(self):
        sid = self._preview(BUG_A)["sessionId"]
        _s, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["logFiling"]["sessionId"], sid)

    def test_mission_detail_without_a_session_is_byte_identical(self):
        _s, detail = self._get("/api/mission/m-001")
        self.assertNotIn("logFiling", detail)

    def test_the_explicit_go_consumes_the_session_and_clears_the_stamp(self):
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        # the captain's explicit Go: resolve the already-filed batch.
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertNotIn(sid, self.actions._log_sessions)
        _s, board = self._get("/api/board")
        self.assertTrue(all("logFiling" not in c for c in self._cards(board)))


# ── behaviour 7: a failed file → status `failed`, never a false `filed` ─────
class FailedFileTest(LogSessionBase):
    def test_script_non_zero_marks_the_session_failed_with_a_legible_message(self):
        sid = self._preview(BUG_A)["sessionId"]
        open(self.fail_flag, "w").close()
        status, resp = self._post("/api/mission/m-001/log/file",
                                  {"sessionId": sid})
        self.assertEqual(status, 200)
        self.assertEqual(resp["state"]["status"], "filing")
        bad = self._await_status("/api/mission/m-001/log/session", "failed")
        self.assertFalse(bad["filed"],
                         "a failed file must NEVER report filed")
        self.assertIn("Goal section", bad.get("error") or "",
                      "the script's own plain-English reason must survive")
        # the authored PRDs are STILL held, so the captain can retry for free.
        self.assertEqual([c["prd"] for c in bad["children"]], [BUG_A])
        self.assertTrue(bad["authored"])
        # and nothing was driven.
        self.assertEqual(self._record("resolve"), "")

    def test_failed_session_can_be_refiled_after_the_fault_clears(self):
        sid = self._preview(BUG_A)["sessionId"]
        open(self.fail_flag, "w").close()
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        os.unlink(self.fail_flag)
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        good = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual((good["bugCount"], good["filedCount"]), (1, 1))

    def test_empty_session_prds_is_a_refusal_not_a_filed_session(self):
        """A session with nothing authored must not claim to have filed."""
        self._set_turns({"bugs": [BUG_A]})
        st = self._preview(BUG_A)
        sid = st["sessionId"]
        self.actions._log_sessions[sid].prds = []
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self.assertEqual(cm.exception.code, 400)
        self.assertEqual(self.actions._log_sessions[sid].status, "previewed")


# ── S162: the stamp carries the REASON a filing ended badly ─────────────────
class StampCarriesTheFailureReasonTest(LogSessionBase):
    """S162 — a captain who clicked "File & Cost" and closed the console has the
    parent CARD and nothing else. A shortfall or a refusal therefore has to reach
    that card WITH its reason: the client knows it dispatched a filing, it cannot
    know how log.sh got on, and it must not invent a cause. So the stamp carries
    `error` — and only when there is one, so a healthy session's stamp is
    byte-identical to its S161 self.
    """

    def test_a_failed_stamp_carries_the_scripts_own_reason(self):
        sid = self._preview(BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        sess = self._await_status("/api/mission/m-001/log/session", "failed")
        stamp = self._stamp()
        self.assertEqual(stamp["status"], "failed")
        self.assertTrue(stamp.get("error"), "the card must be told why")
        # …and it is the SAME words the session reports — one source, no drift.
        self.assertEqual(stamp["error"], sess["error"])

    def test_a_partial_stamp_carries_the_shortfall(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        sess = self._await_status("/api/mission/m-001/log/session", "partial")
        stamp = self._stamp()
        self.assertEqual((stamp["bugCount"], stamp["filedCount"]), (2, 1))
        self.assertEqual(stamp["error"], sess["error"])

    def test_a_healthy_stamp_is_byte_identical_to_its_s161_self(self):
        """No error, no key: the additive-payload invariant, inside the stamp."""
        sid = self._preview(BUG_A)["sessionId"]
        self.assertEqual(sorted(self._stamp().keys()),
                         ["bugCount", "filedCount", "sessionId", "status"])
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(sorted(self._stamp().keys()),
                         ["bugCount", "filedCount", "sessionId", "status"])

    def test_the_detail_stamp_says_the_same_thing(self):
        sid = self._preview(BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        _s, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["logFiling"], self._stamp())


# ── D1: the STATUS IS DECIDED BY WHAT LANDED, never by log.sh's exit code ────
class NothingFiledPostConditionTest(LogSessionBase):
    """S161 fix round 1, D1 (HIGH) — a batch that filed NOTHING said `filed`.

    `log.sh` exits 0 even when it files nothing: `file_one_bug` runs inside a
    command substitution, so its `die` exits only the subshell. The session used
    to flip to `filed` on "no exception raised", which is trusting a liar. The
    status must be decided by a POST-CONDITION CHECK — what actually landed on
    disk — so a human reading it is never misled about what exists.
    """

    def test_a_batch_that_filed_nothing_reads_failed_not_filed(self):
        st = self._preview(BUG_MALFORMED, BUG_MALFORMED)
        sid = st["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        bad = self._await_status("/api/mission/m-001/log/session", "failed")
        self.assertFalse(bad["filed"])
        self.assertEqual(bad["filedCount"], 0)
        self.assertEqual(bad["bugCount"], 2)
        # nothing is on disk — and the message says so, in words.
        self.assertEqual(self._on_disk(), [])
        self.assertEqual(self._linked_ids(), [])
        msg = bad.get("error") or ""
        self.assertIn("nothing was filed", msg.lower())
        self.assertIn("2", msg, "the message must name the batch it lost")
        self.assertIn("title line", msg,
                      "log.sh's own reason must survive into the message")

    def test_a_partially_filed_batch_is_never_reported_as_filed(self):
        """1 valid + 1 malformed: log.sh files one, rejects one, exits 0. The
        session must NOT read `filed` — and the message must name the shortfall."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertNotEqual(part["status"], "filed")
        self.assertFalse(part["filed"],
                         "a half-filed batch must never report filed")
        self.assertEqual(part["bugCount"], 2)
        self.assertEqual(part["filedCount"], 1)
        # exactly one child landed, and the session reports THAT one.
        self.assertEqual(self._on_disk(), ["m-bug1"])
        self.assertEqual([c["id"] for c in part["children"]], ["m-bug1"])
        msg = part.get("error") or ""
        self.assertIn("1 of 2", msg, "the message must name the shortfall")
        self.assertIn("m-bug1", msg, "and what actually landed")
        self.assertIn("title line", msg, "and why the rest did not")

    def test_a_partial_batch_is_not_driven_by_itself(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        time.sleep(0.3)
        self.assertEqual(self._record("resolve"), "",
                         "BUG-059's hold covers a partial too")

    def test_a_complete_batch_still_reads_filed(self):
        """The post-condition check must not turn an honest success into a fault."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertTrue(done["filed"])
        self.assertEqual(done["bugCount"], 2)
        self.assertEqual(done["filedCount"], 2)
        self.assertNotIn("error", done)

    def test_pre_existing_children_do_not_count_as_this_batch(self):
        """The parent already has a bug child from an EARLIER report. The check
        must count what THIS batch landed — a delta, not a total — or an old
        child would make a batch that filed nothing look filed."""
        fx.plant_simple(self.tmp, "m-bug9", stage="plan", issue=209,
                        parent_mission="m-001", mtype="bug")
        sid = self._preview(BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        bad = self._await_status("/api/mission/m-001/log/session", "failed")
        self.assertEqual(bad["filedCount"], 0)
        self.assertFalse(bad["filed"])

    def _linked_ids(self):
        return sorted(c["id"] for c in self.actions._linked_children("m-001"))


# ── N1: a shortfall must never make the AUTHORED TEXT unrecoverable ──────────
class PartialRecoveryTest(LogSessionBase):
    """S161 fix round 2, N1 (MEDIUM) — a `partial` LOST the PRD of the bug that
    did not land, which breaks the session's whole reason to exist.

    Round 1 made the status honest ("only 1 of 2 filed") and then threw the
    unfiled bug's authored text away: `children` carried the FILED child only, no
    field carried the missing bug's PRD, and the sole trace was a temp path in the
    error string pointing at a file already unlinked. So the advice — "log the ones
    that failed as a new report" — meant retyping the bug and paying for a second
    ~25s split worker. The daemon holds those PRDs; it must SAY so.

    Two halves:
      * `unfiled` — the authored rows (title + FULL prd text + image refs) of every
        bug that is not on disk, at EVERY status, so a reopened console can rebuild
        them. Nothing the split worker authored is ever unrecoverable.
      * a RETRY — File on a `partial` re-files exactly the missing bugs, never the
        ones that landed (the measured post-condition delta is what decides which).
    """

    def _session(self):
        _s, resp = self._get("/api/mission/m-001/log/session")
        return resp

    def test_a_partial_still_holds_the_unfiled_bugs_authored_text(self):
        """THE finding: 1 of 2 landed — the other bug's PRD must still be here."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual(part["unfiledCount"], 1)
        unfiled = part["unfiled"]
        self.assertEqual(len(unfiled), 1)
        self.assertEqual(unfiled[0]["prd"], BUG_MALFORMED,
                         "the authored PRD of the bug that did NOT land must be "
                         "recoverable verbatim — otherwise the captain retypes it "
                         "and pays for a second split")
        self.assertEqual(unfiled[0]["index"], 1,
                         "and which bug of the batch it was")

    def test_the_unfiled_text_names_the_right_bug_not_just_the_last_one(self):
        """Attribution, not guesswork: the FIRST bug fails, the second lands."""
        self._refuse("XP not awarded")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual([u["prd"] for u in part["unfiled"]], [BUG_A])
        self.assertEqual([c["title"] for c in part["children"]],
                         ["Leaderboard flicker on first load"])

    def test_a_failed_batch_exposes_every_authored_prd_for_recovery(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        open(self.fail_flag, "w").close()
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        bad = self._await_status("/api/mission/m-001/log/session", "failed")
        self.assertEqual(bad["unfiledCount"], 2)
        self.assertEqual([u["prd"] for u in bad["unfiled"]],
                         [BUG_A, BUG_MALFORMED])

    def test_unfiled_is_present_at_every_status_meaning_the_same_thing(self):
        """One key, one meaning (the round's standing lesson): `unfiled` is always
        "the authored bugs that are not on disk, with their text"."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        prev = self._session()
        self.assertEqual(prev["unfiledCount"], 2)
        self.assertEqual([u["prd"] for u in prev["unfiled"]], [BUG_A, BUG_B])
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(done["unfiledCount"], 0)
        self.assertEqual(done["unfiled"], [])

    def test_recovering_the_text_costs_no_second_split_worker_turn(self):
        """The whole point: reopening the console after a partial must not re-run
        the ~25s billable split worker to get the missing bug's words back."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self.assertEqual(self._splits(), 1)
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        for _ in range(3):                      # reopen the console three times
            self.assertEqual(self._session()["unfiled"][0]["prd"], BUG_MALFORMED)
        self.assertEqual(self._splits(), 1,
                         "recovering the authored text must spend NO second split")

    # ── the retry ────────────────────────────────────────────────────────────
    def test_refiling_a_partial_retries_only_the_bugs_that_are_missing(self):
        """A per-bug fault clears (a flaky upstream), so File again. It must file
        the missing bug ONLY — re-filing the whole batch would duplicate the child
        that already landed."""
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual([c["id"] for c in part["children"]], ["m-bug1"])
        self._allow_all()
        status, resp = self._post("/api/mission/m-001/log/file",
                                  {"sessionId": sid})
        self.assertEqual(status, 200)
        self.assertEqual(resp["state"]["status"], "filing",
                         "a partial must be RETRYABLE, not a dead 409")
        done = self._await_status("/api/mission/m-001/log/session", "filed")
        self.assertEqual(done["bugCount"], 2)
        self.assertEqual(done["filedCount"], 2)
        self.assertEqual(done["unfiledCount"], 0)
        # exactly TWO bug missions exist — the retry duplicated nothing.
        self.assertEqual(len(self._on_disk()), 2)
        self.assertEqual(sorted(c["title"] for c in done["children"]),
                         ["Leaderboard flicker on first load",
                          "XP not awarded on video completion"])

    def test_the_retry_dispatch_carries_only_the_unfiled_prd(self):
        self._refuse("Leaderboard")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self._allow_all()
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        argvs = self._argvs()
        self.assertEqual(len(argvs), 2, "the retry is a second log.sh dispatch")
        self.assertEqual(argvs[0].count("--prd"), 2)
        self.assertEqual(argvs[1].count("--prd"), 1,
                         "the retry must dispatch ONLY the bug that is missing")

    def test_a_retry_does_not_hand_the_filed_bugs_images_to_the_retried_one(self):
        """Image routing has to be recomputed for a SUBSET: `_route_images` treats
        an image no bug in its input references as ORPHANED and attaches it to every
        one of them, so a screenshot tied only to the bug that already filed would
        otherwise ride the retry."""
        self._refuse("Leaderboard")
        st = self._preview(
            {"prd": BUG_A, "imageRefs": [1]},
            {"prd": BUG_B, "imageRefs": [2]},
            images=[{"name": "a.png", "type": "image/png",
                     "dataB64": "iVBORw0KGgo="},
                    {"name": "b.png", "type": "image/png",
                     "dataB64": "iVBORw0KGgo="}])
        sid = st["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self._allow_all()
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        argvs = self._argvs()
        self.assertEqual(argvs[0].count("--attach"), 2, "one per bug, first pass")
        self.assertEqual(argvs[1].count("--attach"), 1,
                         "the retried bug gets ITS image and only its image")

    def test_a_retry_that_fails_again_stays_partial_and_keeps_the_text(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        again = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual(again["filedCount"], 1)
        self.assertEqual(again["unfiled"][0]["prd"], BUG_MALFORMED)
        self.assertEqual(len(self._on_disk()), 1,
                         "a failed retry must not duplicate the filed child")

    def test_a_fully_filed_session_still_refuses_a_second_file(self):
        """Nothing is missing, so there is nothing to retry."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        code, msg = self._post_err("/api/mission/m-001/log/file",
                                   {"sessionId": sid})
        self.assertEqual(code, 409)
        self.assertIn("already filed", msg)
        self.assertEqual(len(self._argvs()), 1)

    def test_a_retry_never_dispatches_resolve(self):
        """BUG-059's hold covers the retry path too."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        time.sleep(0.3)
        self.assertEqual(self._record("resolve"), "")

    def test_the_shortfall_message_says_the_text_is_still_held(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        msg = (part.get("error") or "").lower()
        self.assertIn("still held", msg,
                      "the copy must not send the captain off to retype a bug "
                      "whose text the daemon is holding")
        self.assertNotIn("as a new report", msg,
                         "round 1's advice pointed at text it had just discarded")

    def test_steers_of_the_wrong_length_are_ignored_not_re_indexed(self):
        """At `partial` the console's override inputs are indexed by the children
        that LANDED, not by the authored batch. Adopting such a list would silently
        move the captain's steer onto a different bug."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file",
                   {"sessionId": sid, "overrides": ["", "all:opus"]})
        self._await_status("/api/mission/m-001/log/session", "partial")
        # one landed child ⇒ a 1-long list, against a 2-long batch.
        self._post("/api/mission/m-001/log/file",
                   {"sessionId": sid, "overrides": ["reasoning:sonnet"]})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual(self.actions._log_sessions[sid].overrides,
                         ["", "all:opus"],
                         "a mis-shaped steer list must be ignored wholesale")
        self.assertNotIn("reasoning:sonnet", self._record("log"))

    # ── the Go must not destroy what it is not driving ────────────────────────
    def test_the_go_keeps_a_partial_session_so_the_unfiled_text_survives(self):
        """The captain drives the bug that landed. The one that did NOT land is
        still only held here — consuming the session would destroy it."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertIn(sid, self.actions._log_sessions,
                      "the Go drove the filed child — it must not throw away the "
                      "authored text of the one still missing")
        self.assertEqual(self._session()["unfiled"][0]["prd"], BUG_MALFORMED)

    def test_the_go_still_consumes_a_fully_filed_session(self):
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertNotIn(sid, self.actions._log_sessions)

    def test_a_partial_session_can_be_discarded_when_the_captain_is_done(self):
        """The leftover text is the captain's to throw away — explicitly. Without
        this the card would advertise a partial for ever (D3's pathology)."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        status, _resp = self._post("/api/mission/m-001/log/discard")
        self.assertEqual(status, 200)
        self.assertIsNone(self._stamp())
        self.assertNotIn(sid, self.actions._log_sessions)
        # the child that DID land is untouched — a discard drops a session, not work.
        self.assertEqual(self._on_disk(), ["m-bug1"])

    def test_the_go_preserves_the_unfiled_authored_text_over_http(self):
        """S161 fix round 3 — the ONE N1 sub-claim that rested on an implementor's
        word, because the tester is forbidden from dispatching /log/run (cost).

        `log_run` calls `_drop_log_session(keep_unfiled=True)`; before that flag the
        Go destroyed the session as a side effect of driving what landed, taking the
        unfiled bugs' authored text with it. Proven here with the resolve dispatch
        STUBBED (scripts["resolve"] is a recording no-op — zero tokens): the Go
        really does dispatch, and the unfiled PRD is STILL retrievable verbatim
        through the public `GET /log/session` afterwards, at no second split.
        """
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertEqual(self._splits(), 1)
        # the explicit Go — the real endpoint the `Go ▸` button posts to.
        status, _resp = self._post("/api/mission/m-001/log/run", {"overrides": []})
        self.assertEqual(status, 200)
        # it really DID drive the batch (the stub recorded a resolve dispatch)…
        deadline = time.time() + 10
        while time.time() < deadline and not self._record("resolve"):
            time.sleep(0.05)
        self.assertIn("--parent m-001", self._record("resolve"),
                      "the Go must still dispatch resolve-logs for what landed")
        # …and the bug that never reached disk is still recoverable, verbatim.
        _s, after = self._get("/api/mission/m-001/log/session")
        self.assertEqual(after["status"], "partial")
        self.assertEqual(after["sessionId"], sid)
        self.assertEqual(after["unfiledCount"], 1)
        self.assertEqual(after["unfiled"][0]["prd"], BUG_MALFORMED,
                         "the Go drove the filed child — it must not destroy the "
                         "authored text of the one still missing")
        self.assertEqual(self._splits(), 1,
                         "and recovering it after the Go spends no second split")


# ── R1: a re-preview must not SILENTLY destroy held authored text ─────────────
class RepreviewProtectsStrandedTextTest(LogSessionBase):
    """S161 fix round 3, R1 (LOW→real) — a new Preview at `partial` silently threw
    away the still-unfiled authored text.

    The tester reached `partial` with one bug never filed, then posted a brand-new
    report to `POST /api/mission/<id>/log`: the session was REPLACED and the
    canary text was gone from every surface. The captain had paid a ~25s split for
    that bug and never filed it — exactly the loss S161 exists to prevent, arriving
    through the one door nobody had guarded. The console offered "Preview" beside
    "File 1 Remaining" with no warning at all, while the explicitly-destructive
    "Discard Unfiled" next to it DID warn.

    The cure makes the destruction INTENTIONAL rather than incidental, and the
    DAEMON is what enforces it (a client can always be bypassed): a preview that
    would destroy authored text the captain has neither filed nor discarded is
    REFUSED, and the refusal is raised BEFORE the split worker is dispatched so the
    refusal itself costs nothing. `discardUnfiled: true` is the captain saying it
    on purpose. A session with nothing stranded (`previewed`, or a fully `filed`
    batch) is replaced exactly as before.
    """

    def _session(self):
        _s, resp = self._get("/api/mission/m-001/log/session")
        return resp

    def _partial(self):
        """Reach `partial`: BUG_A lands, BUG_MALFORMED never reaches disk."""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        return sid

    def test_a_new_preview_at_partial_is_refused_not_silently_destructive(self):
        """THE finding. The canary text must survive the second Preview."""
        sid = self._partial()
        self._set_turns({"bugs": [BUG_B]})
        code, msg = self._post_err("/api/mission/m-001/log",
                                   {"text": "Sierra is stranded on the pad."})
        self.assertEqual(code, 409)
        # the session — and the text — are still here.
        self.assertIn(sid, self.actions._log_sessions)
        after = self._session()
        self.assertEqual(after["sessionId"], sid)
        self.assertEqual(after["unfiled"][0]["prd"], BUG_MALFORMED,
                         "the unfiled bug's authored text must survive a "
                         "re-preview the captain did not confirm")
        # and the refusal names what is at stake + both ways forward.
        low = msg.lower()
        self.assertIn("Someone forgot the title line", msg + str(after),
                      "sanity: the canary really is the malformed bug")
        self.assertIn("1", msg, "say how many bugs are stranded")
        self.assertIn("file", low, "name the way to KEEP it")
        self.assertIn("discard", low, "and the deliberate way to lose it")

    def test_the_refusal_costs_no_split_worker_turn(self):
        """The guard must run BEFORE the ~25s billable split is dispatched —
        refusing after paying would be its own defect."""
        self._partial()
        self.assertEqual(self._splits(), 1)
        self._post_err("/api/mission/m-001/log", {"text": "another bug"})
        self.assertEqual(self._splits(), 1,
                         "the refusal must not spend a split worker turn")

    def test_the_refusal_names_the_stranded_bug(self):
        """Not just a count — which bug's words are about to be thrown away."""
        self._refuse("XP not awarded")
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        _code, msg = self._post_err("/api/mission/m-001/log", {"text": "more"})
        self.assertIn("XP not awarded on video completion", msg,
                      "name the bug whose authored text is at stake")

    def test_an_explicit_discard_unfiled_lets_the_preview_through(self):
        """The captain says it on purpose — then it happens, no second refusal."""
        old = self._partial()
        self._set_turns({"bugs": [BUG_B]})
        status, resp = self._post("/api/mission/m-001/log",
                                  {"text": "Sierra is stranded on the pad.",
                                   "discardUnfiled": True})
        self.assertEqual(status, 200)
        new = resp["state"]["sessionId"]
        self.assertNotEqual(new, old)
        self.assertNotIn(old, self.actions._log_sessions)
        self.assertEqual(self.actions._log_sessions[new].prds, [BUG_B])

    def test_a_failed_session_protects_its_authored_text_too(self):
        """At `failed` NOTHING landed, so every authored bug is stranded text."""
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        open(self.fail_flag, "w").close()
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        os.unlink(self.fail_flag)
        code, msg = self._post_err("/api/mission/m-001/log", {"text": "more"})
        self.assertEqual(code, 409)
        self.assertIn("2", msg)
        self.assertEqual(self._session()["unfiledCount"], 2)

    def test_an_ordinary_re_preview_is_untouched(self):
        """The constraint: at `previewed` NOTHING is stranded — the captain is
        re-splitting the same un-committed report and paying for that split
        deliberately. It must still replace the session, with no confirmation."""
        first = self._preview(BUG_A)["sessionId"]
        second = self._preview(BUG_A, BUG_B)["sessionId"]
        self.assertNotEqual(first, second)
        self.assertNotIn(first, self.actions._log_sessions)

    def test_a_fully_filed_session_is_replaced_without_a_confirmation(self):
        """Every authored bug is on disk, so a new preview destroys no text."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        self._set_turns({"bugs": [BUG_B]})
        status, resp = self._post("/api/mission/m-001/log", {"text": "next one"})
        self.assertEqual(status, 200)
        self.assertNotEqual(resp["state"]["sessionId"], sid)

    def test_a_preview_during_a_filing_in_flight_is_refused(self):
        """Parity with the discard's one refusal: replacing a session whose filing
        thread is still running would orphan the very work the card is showing."""
        sid = self._preview(BUG_A)["sessionId"]
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        code, msg = self._post_err("/api/mission/m-001/log", {"text": "more"})
        self.assertEqual(code, 409)
        self.assertIn("being filed", msg)
        self.assertIn(sid, self.actions._log_sessions)
        os.unlink(self.slow_flag)
        self._await_status("/api/mission/m-001/log/session", "filed")

    def test_the_read_only_linked_children_preview_is_never_guarded(self):
        """No text ⇒ the read-only linked-children view. It authors nothing and
        destroys nothing, so it must not be refused by the guard."""
        self._partial()
        status, resp = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        self.assertFalse(resp["state"]["authored"])


# ── D2: ONE number that means ONE thing, on BOTH surfaces ────────────────────
class LogCountHonestyTest(LogSessionBase):
    """S161 fix round 1, D2 (MEDIUM) — the board stamp's `count` meant "authored
    PRDs" and the session's `count` meant "filed children", under the SAME key.
    A card said 2 when the truth on disk was 0. Two counts are genuinely needed,
    so they get two distinct self-describing names — `bugCount` (how many bugs
    this batch is) and `filedCount` (how many of them are on disk) — and both
    surfaces report them identically.
    """

    def _session(self):
        _s, resp = self._get("/api/mission/m-001/log/session")
        return resp

    def test_stamp_carries_no_ambiguous_count_key(self):
        self._preview(BUG_A, BUG_B)
        stamp = self._stamp()
        self.assertNotIn("count", stamp,
                         "`count` meant two different things — it is gone")
        self.assertEqual(sorted(stamp.keys()),
                         ["bugCount", "filedCount", "sessionId", "status"])

    def test_both_surfaces_agree_from_preview_through_filed(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        stamp = self._stamp()
        sess = self._session()
        self.assertEqual(stamp, {"sessionId": sid, "status": "previewed",
                                 "bugCount": 2, "filedCount": 0})
        self.assertEqual((sess["bugCount"], sess["filedCount"]), (2, 0))
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        stamp = self._stamp()
        sess = self._session()
        self.assertEqual(stamp, {"sessionId": sid, "status": "filed",
                                 "bugCount": 2, "filedCount": 2})
        self.assertEqual((sess["bugCount"], sess["filedCount"]), (2, 2))

    def test_a_batch_that_filed_nothing_says_zero_on_the_card_too(self):
        """The tester's exact contradiction: card `count: 2` vs 0 bugs on disk."""
        sid = self._preview(BUG_MALFORMED, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        stamp = self._stamp()
        self.assertEqual(stamp["status"], "failed")
        self.assertEqual(stamp["filedCount"], 0)
        self.assertEqual(stamp["bugCount"], 2)
        self.assertEqual(self._on_disk(), [])

    def test_a_partial_says_one_of_two_on_the_card(self):
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "partial")
        stamp = self._stamp()
        # the two honest counts, and no ambiguous `count` — the D2 contract.
        self.assertEqual((stamp["sessionId"], stamp["status"],
                          stamp["bugCount"], stamp["filedCount"]),
                         (sid, "partial", 2, 1))
        self.assertNotIn("count", stamp)
        # S162 rides one more key HERE and only here: the reason a shortfall
        # happened, because the card is now a surface the captain reads instead
        # of the console (see StampCarriesTheFailureReasonTest for its contract).
        self.assertEqual(sorted(stamp.keys()),
                         ["bugCount", "error", "filedCount", "sessionId",
                          "status"])

    def test_the_session_route_carries_no_count_key_at_any_status(self):
        """S161 fix round 2, N2 — round 1 kept `count` on the session payload as a
        "payload-local row count", and it went on lying: it equalled `bugCount` at
        previewed/filing/filed/failed and `filedCount` at partial, because
        `children` itself changes meaning when only some of the batch lands. One key
        cannot mean two things. `/log/session` is new in S161 — no client depends on
        it — so the ambiguous key is GONE, and the two honest, self-describing names
        (`bugCount`, `filedCount`, plus `unfiledCount`) are the only totals.
        (The pre-S161 `/log` and `/log/file` payloads keep their `count` untouched:
        that byte-identity is an invariant of this round.)"""
        sid = self._preview(BUG_A, BUG_MALFORMED)["sessionId"]
        self.assertNotIn("count", self._session(), "previewed")
        with open(self.slow_flag, "w") as fh:
            fh.write("1\n")
        _s, dispatched = self._post("/api/mission/m-001/log/file",
                                    {"sessionId": sid})
        self.assertNotIn("count", dispatched["state"], "the dispatch response")
        self.assertNotIn("count", self._session(), "filing")
        part = self._await_status("/api/mission/m-001/log/session", "partial")
        self.assertNotIn("count", part, "partial")
        # and the honest names are all there, at every one of those statuses.
        for payload in (part, dispatched["state"]):
            for key in ("bugCount", "filedCount", "unfiledCount"):
                self.assertIn(key, payload)

    def test_no_count_key_on_a_failed_or_filed_session_either(self):
        sid = self._preview(BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self.assertNotIn("count",
                         self._await_status("/api/mission/m-001/log/session",
                                            "failed"), "failed")
        # moving on from the failed batch means losing the text it still holds —
        # which R1 makes an explicit choice rather than a side effect.
        sid = self._preview(BUG_A, discard_unfiled=True)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self.assertNotIn("count",
                         self._await_status("/api/mission/m-001/log/session",
                                            "filed"), "filed")

    def test_mission_detail_stamp_matches_the_board_stamp(self):
        self._preview(BUG_A, BUG_B)
        _s, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["logFiling"], self._stamp())


# ── D3: an abandoned preview is DISCARDABLE (Align's cancel parity) ──────────
class LogDiscardTest(LogSessionBase):
    """S161 fix round 1, D3 (LOW) — a previewed-then-abandoned session stamped the
    parent card until the daemon restarted, and there was no way to clear it
    (`log/cancel` / `log/discard` / `log/close` all 404'd). Align has
    `POST /api/align/<sid>/cancel`; the log console gets the same parity.
    """

    def test_discard_drops_the_session_and_clears_the_stamp(self):
        self._preview(BUG_A, BUG_B)
        self.assertIsNotNone(self._stamp())
        status, resp = self._post("/api/mission/m-001/log/discard")
        self.assertEqual(status, 200)
        self.assertEqual(resp["state"]["status"], "discarded")
        self.assertEqual(self.actions._log_sessions, {})
        # and the board is back to ADDITIVE-clean: no stamp anywhere, and the
        # overlay is once again a pure passthrough (the byte-identity invariant —
        # asserted unit-level because the live board carries a wall-clock field).
        _s, after = self._get("/api/board")
        self.assertTrue(all("logFiling" not in c for c in self._cards(after)))
        self.assertIsNone(self._stamp())
        board = self.adapter.board()
        self.assertEqual(self.actions.log_overlay(board), copy.deepcopy(board))

    def test_discard_also_clears_the_mission_detail_stamp(self):
        self._preview(BUG_A)
        self._post("/api/mission/m-001/log/discard")
        _s, detail = self._get("/api/mission/m-001")
        self.assertNotIn("logFiling", detail)

    def test_discard_is_idempotent_and_never_a_404(self):
        self._preview(BUG_A)
        self._post("/api/mission/m-001/log/discard")
        status, resp = self._post("/api/mission/m-001/log/discard")
        self.assertEqual(status, 200)
        self.assertEqual(resp["state"]["status"], "discarded")

    def test_discard_of_an_unknown_mission_is_a_clean_200(self):
        """Align's cancel answers 200 even for a bogus sid — same here, so a
        stale card can always clear itself."""
        status, resp = self._post("/api/mission/m-nope/log/discard")
        self.assertEqual(status, 200)
        self.assertEqual(resp["state"]["status"], "discarded")

    def test_discard_dispatches_nothing(self):
        self._preview(BUG_A)
        self._post("/api/mission/m-001/log/discard")
        self.assertEqual(self._record("log"), "")
        self.assertEqual(self._record("resolve"), "")
        self.assertEqual(self._on_disk(), [])

    def test_discard_is_refused_while_a_filing_is_in_flight(self):
        """Clearing the band while log.sh is still running would hide a real
        in-flight filing — the one case the stamp exists for."""
        sid = self._preview(BUG_A)["sessionId"]
        with open(self.slow_flag, "w") as fh:
            fh.write("2\n")
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        code, msg = self._post_err("/api/mission/m-001/log/discard")
        self.assertEqual(code, 409)
        self.assertIn("being filed", msg)
        self.assertIn(sid, self.actions._log_sessions)
        self._await_status("/api/mission/m-001/log/session", "filed")

    def test_a_filed_session_can_be_discarded(self):
        """The captain reviewed the filed bugs and closed the console without a
        Go — the batch is history, so the card must stop advertising it."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        status, _resp = self._post("/api/mission/m-001/log/discard")
        self.assertEqual(status, 200)
        self.assertIsNone(self._stamp())
        # the filed children are UNTOUCHED — a discard drops a session, not work.
        self.assertEqual(self._on_disk(), ["m-bug1"])

    def test_a_failed_session_can_be_discarded(self):
        sid = self._preview(BUG_MALFORMED)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "failed")
        status, _resp = self._post("/api/mission/m-001/log/discard")
        self.assertEqual(status, 200)
        self.assertIsNone(self._stamp())


# ── D4: say only what is actually known about a missing session ──────────────
class MissingSessionCopyTest(LogSessionBase):
    """S161 fix round 1, D4 (LOW) — a REPLACED session's sid 404'd with "the
    daemon was restarted — preview the report again". The daemon had not been
    restarted; the remedy was right and the stated reason was invented.
    """

    def test_a_replaced_session_is_told_it_was_replaced(self):
        first = self._preview(BUG_A)["sessionId"]
        second = self._preview(BUG_A, BUG_B)["sessionId"]
        code, msg = self._post_err("/api/mission/m-001/log/file",
                                   {"sessionId": first})
        self.assertEqual(code, 404)
        self.assertIn("replaced", msg.lower())
        self.assertNotIn("restart", msg.lower(),
                         "nothing was restarted — do not invent a reason")
        self.assertIn(second, msg, "name the session that IS live")

    def test_an_unknown_session_does_not_claim_a_restart(self):
        code, msg = self._post_err("/api/mission/m-001/log/file",
                                   {"sessionId": "deadbeef"})
        self.assertEqual(code, 404)
        self.assertNotIn("restart", msg.lower())
        self.assertIn("preview the report again", msg.lower(),
                      "the remedy was right — keep it")

    # ── R2 (fix round 3): "replaced" is a CLAIM, and only sometimes knowable ──
    def test_a_sid_that_never_existed_is_not_called_replaced(self):
        """S161 fix round 3, R2 — the same class as D4, one door along.

        With a live session for the parent, ANY unknown sid was reported as "was
        replaced by a newer preview" — including `deadbeefcafe`, which was never a
        session at all. The daemon cannot know that; it only knows the sid is not
        one it holds and that a different one is live. Say THAT.
        """
        live = self._preview(BUG_A)["sessionId"]
        code, msg = self._post_err("/api/mission/m-001/log/file",
                                   {"sessionId": "deadbeefcafe"})
        self.assertEqual(code, 404)
        low = msg.lower()
        self.assertNotIn("replaced", low,
                         "this sid was never a session — the daemon cannot know "
                         "it was the one replaced")
        self.assertNotIn("restart", low, "and D4's invented reason stays gone")
        self.assertIn("deadbeefcafe", msg, "name the sid that was asked for")
        self.assertIn(live, msg, "and the one that IS live")

    def test_a_replaced_sid_is_still_told_it_was_replaced(self):
        """The knowable case keeps its better copy: this sid really was retired by
        a newer preview, and the daemon remembers that."""
        first = self._preview(BUG_A)["sessionId"]
        second = self._preview(BUG_B)["sessionId"]
        _code, msg = self._post_err("/api/mission/m-001/log/file",
                                    {"sessionId": first})
        self.assertIn("replaced", msg.lower())
        self.assertIn(second, msg)

    def test_a_discarded_sid_is_told_it_was_discarded(self):
        """Also knowable — and it is not a replacement, so it must not say so."""
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/discard")
        _code, msg = self._post_err("/api/mission/m-001/log/file",
                                    {"sessionId": sid})
        low = msg.lower()
        self.assertIn("discard", low)
        self.assertNotIn("replaced", low)
        self.assertNotIn("restart", low)


# ── BUG-059: filing NEVER auto-runs the fixes ────────────────────────────────
class Bug059HoldTest(LogSessionBase):
    def test_filed_never_dispatches_resolve(self):
        sid = self._preview(BUG_A, BUG_B)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        # give a would-be auto-dispatch every chance to show up.
        time.sleep(0.5)
        self.assertEqual(self._record("resolve"), "",
                         "BUG-059: filing must HOLD for the captain's Go")

    def test_no_spawn_log_from_the_filing_thread(self):
        sid = self._preview(BUG_A)["sessionId"]
        self._post("/api/mission/m-001/log/file", {"sessionId": sid})
        self._await_status("/api/mission/m-001/log/session", "filed")
        spawned = glob.glob(os.path.join(self.tmp, ".git", "lcars", "logs",
                                         "spawn-resolve*"))
        self.assertEqual(spawned, [])


# ── behaviour 8: read-only build → writes 403, GET 404, no overlay ───────────
class ReadOnlyLogSessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _expect(self, code, path, data=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(
            url, data=json.dumps(data).encode("utf-8") if data is not None
            else None,
            method="POST" if data is not None else "GET",
            headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, code)

    def test_log_preview_declined(self):
        self._expect(403, "/api/mission/m-001/log", {"text": "it broke"})

    def test_log_file_by_session_declined(self):
        self._expect(403, "/api/mission/m-001/log/file", {"sessionId": "x"})

    def test_log_discard_declined(self):
        # D3's new write is a write: it 403s like every other one.
        self._expect(403, "/api/mission/m-001/log/discard", {})

    def test_log_session_get_is_not_offered(self):
        # no write layer ⇒ no sessions to restore.
        self._expect(404, "/api/mission/m-001/log/session")

    def test_the_read_only_404_does_not_deny_the_mission_exists(self):
        """S161 fix round 2, N3 (cosmetic) — the route fell through to the
        mission-DETAIL handler, which read "m-001/log/session" as a mission id and
        answered `no such mission`. The mission is right there on the board; it is
        the SESSION route that is write-board-only. Say what is true."""
        msg = self._error_message("/api/mission/m-001/log/session")
        self.assertNotIn("no such mission", msg,
                         "the mission exists — do not deny it")
        self.assertIn("read-only", msg, "name the actual reason")
        self.assertIn("m-001", msg)
        # a genuinely unknown mission still reads as one.
        self.assertIn("no such mission",
                      self._error_message("/api/mission/m-nope/log/session"))

    def _error_message(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            urllib.request.urlopen(url, timeout=5)
        except urllib.error.HTTPError as exc:
            return (json.loads(exc.read()) or {}).get("error") or ""
        self.fail("GET %s was expected to be refused" % path)

    def test_board_is_never_stamped(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=5) as r:
            board = json.loads(r.read())
        cards = []
        for col in (board.get("columns") or {}).values():
            if isinstance(col, list):
                cards.extend(col)
        self.assertTrue(all("logFiling" not in c for c in cards))


if __name__ == "__main__":
    unittest.main()
