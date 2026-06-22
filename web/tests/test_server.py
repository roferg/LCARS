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

    def test_board_css_hides_drawer_when_hidden(self):
        """Regression (S67 fix-loop r2, DEFECT 1): the served board.css MUST
        carry a rule that hides an element with the `hidden` attribute, so the
        author `.drawer{display:flex}` can't override the UA `[hidden]` rule and
        leave the detail drawer stuck open on load. board.js toggles `hidden`,
        so the only browser-side guard is this CSS — assert it's present."""
        status, ctype, body = self._get("/board.css")
        self.assertEqual(status, 200)
        self.assertIn("text/css", ctype)
        css = body.decode("utf-8").replace(" ", "").lower()
        # a `[hidden]{display:none...}` rule (global or `.drawer[hidden]`) so the
        # hidden drawer is genuinely display:none, beating `.drawer`'s flex.
        self.assertIn("[hidden]", css,
                      "board.css must hide elements with the hidden attribute")
        self.assertRegex(css, r"\[hidden\][^{]*\{[^}]*display:none",
                         "the [hidden] rule must set display:none")

    def test_writes_are_rejected_read_only(self):
        # This daemon is built with no Actions (the read-only / view-only shape),
        # so a POST is declined — 403 (write layer inactive). The S68 write layer
        # is only active when an Actions is injected (see test_write_endpoints).
        url = "http://127.0.0.1:%d/api/mission/m-001/start" % self.port
        req = urllib.request.Request(url, data=b"{}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertIn(cm.exception.code, (403, 405, 501))

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


class FrontEndAssetsTest(unittest.TestCase):
    """S68 front end: the daemon must SERVE assets carrying the operator-screen
    structures the downstream browser tester drives. We can't run a browser (no
    node/jsdom — ADR-007), so we assert the served HTML/JS/CSS contain the stable
    selectors/ids/classes for the eight screens + the detail two-pane. This is a
    static-content check, mirroring the static-serving idiom above."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _text(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.read().decode("utf-8")

    def test_index_has_overlay_host_and_file_entry(self):
        html = self._text("/")
        # the centered overlay host replaces the old right-side drawer.
        self.assertIn('id="overlay"', html)
        self.assertIn('id="overlayBody"', html)
        # the File-a-mission entry control.
        self.assertIn('id="fileBtn"', html)
        # the view-only affordance host.
        self.assertIn('id="viewonly"', html)
        # the old drawer markup is gone (replaced by the modal overlay).
        self.assertNotIn('id="drawer"', html)

    def test_index_has_topbar_repo_host(self):
        """S70-A: the topbar carries a host the renderer fills with meta.repo
        (which repo the board is attached to) next to the LCARS · KANBAN brand."""
        html = self._text("/")
        self.assertIn('id="repoMeta"', html)

    def test_index_has_lcars_elbow_frame(self):
        """S67-kanban: the board is wrapped in the iconic LCARS elbow frame — a
        segmented top band sweeping via a rounded elbow into a left rail, with
        the board nested inside. Assert the frame containers are SERVED in the
        markup and that the folded-in topbar nodes (repoMeta/conn/fileBtn/board)
        survive inside the frame."""
        html = self._text("/")
        # the frame shell + its three structural regions.
        for cls in ('class="lcars-frame"', 'class="frame-elbow"',
                    'frame-top', 'class="frame-rail"', 'class="frame-content"'):
            self.assertIn(cls, html, "index.html must carry %s" % cls)
        # the old topbar nodes are folded INTO the top band (ids preserved).
        self.assertIn('id="repoMeta"', html)
        self.assertIn('id="conn"', html)
        self.assertIn('id="fileBtn"', html)
        # the board + legend still live in the content area.
        self.assertIn('id="board"', html)

    def test_board_css_styles_the_elbow_frame(self):
        """S67-kanban: board.css must style the frame regions (grid shell, the
        fat elbow corner, the rail, the content scroll viewport)."""
        css = self._text("/board.css")
        for sel in (".lcars-frame", ".frame-elbow", ".frame-top",
                    ".frame-rail", ".frame-content"):
            self.assertIn(sel, css, "board.css must style %s" % sel)

    def test_frame_is_one_solid_piece_with_rounded_concave(self):
        """S67 captain fix: the band+elbow+rail must read as ONE solid yellow L
        with a smooth ROUNDED inner concave — and NO stray black geometry in the
        yellow. So the old black 'pie piece' (.frame-elbow::after) must be gone,
        and the inner concave must instead be formed by rounding the content's
        top-left corner backed by frame yellow on the grid."""
        css = self._text("/board.css")
        # the stray black quarter-square pseudo at the elbow must be removed.
        self.assertNotIn(".frame-elbow::after", css,
                         "the black 'pie piece' must be removed")
        # inner concave now = rounded top-left corner of the black content...
        self.assertIn("border-top-left-radius:var(--frame-inner-r)", css)
        # ...backed by a frame-yellow fillet on the grid, behind the content.
        self.assertIn(".lcars-frame::before", css,
                      "yellow concave backing must sit on the frame, not the "
                      "overflow-clipped content")

    def test_board_js_renders_meta_repo(self):
        """S70-A: board.js must read board.meta and render meta.repo into the
        topbar host on the live render path."""
        js = self._text("/board.js")
        self.assertIn("repoMeta", js)
        self.assertIn(".meta", js)

    def test_board_js_renders_model_mix_and_adrs_and_criteria(self):
        """S70-B: board.js must render the new shape fields — modelMix as the
        Launch .mix table, adrs in the detail .adr style, and the verbatim
        criteria as .check rows."""
        js = self._text("/board.js")
        self.assertIn("modelMix", js)
        self.assertIn("adrs", js)
        self.assertIn("criteria", js)

    def test_board_js_align_submit_allows_empty_answer(self):
        """BUG-073: the Align console Submit must NOT block on an empty answer.
        An empty Submit = 'nothing to add / accept the recommendation /
        proceed'. The old guard ('Pick the recommendation or type an answer.'
        with an early return) forced filler text; it must be gone so an empty
        answer POSTs through to /answer (which now treats empty as proceed)."""
        js = self._text("/board.js")
        self.assertNotIn("Pick the recommendation or type an answer.", js,
                         "the empty-answer block must be removed (BUG-073)")

    def test_board_js_has_all_eight_screens(self):
        js = self._text("/board.js")
        for fn in ("openFile", "openLaunch", "openRespond", "openVerify",
                   "openLog", "openDetail"):
            self.assertIn(fn, js, "board.js must define %s" % fn)
        # every write endpoint the contract lists must be POSTed from the JS.
        for ep in ("/api/mission", "/start", "/pause", "/resume", "/respond",
                   "/verify", "/log", "/log/run"):
            self.assertIn(ep, js, "board.js must call %s" % ep)
        # approve vs send-back are the two distinct verify decisions.
        self.assertIn('"approve"', js)
        self.assertIn('"send-back"', js)

    def test_board_js_mission_log_gated_off_bug_child(self):
        """BUG-046: the Mission Log button must NOT render for a logged-bug child
        (type=="bug" && parentMission) — you cannot log bugs against a logged bug.
        The render is gated by the existing logged-bug predicate (isLogBug)."""
        js = self._text("/board.js")
        # the gate guards the Mission Log button render with the bug-child predicate.
        self.assertIn("!isLogBug(mi)", js)
        # and it still sits on the same conditional as the Mission Log button.
        idx_gate = js.find("!isLogBug(mi)")
        idx_btn = js.find('"Mission Log"')
        self.assertNotEqual(idx_gate, -1)
        self.assertNotEqual(idx_btn, -1)
        # the gate appears just before the Mission Log button render.
        self.assertLess(idx_gate, idx_btn)

    def test_board_js_active_runtime_from_server_anchor(self):
        """BUG-047: the live runtime must re-base from the server anchor
        (activeSecondsAt) — base + (clientNow - activeSecondsAt) — so a re-opened
        card shows true elapsed instead of a stale snapshot. It must NOT simply
        anchor on Date.now() at render and add to the bare base."""
        js = self._text("/board.js")
        self.assertIn("activeSecondsAt", js)
        # the live value derives from the server anchor.
        self.assertIn("anchorAt", js)
        self.assertIn("nowSec - anchorAt", js)

    def test_board_js_handles_view_only_403(self):
        js = self._text("/board.js")
        # a 403 must flip the board to view-only, not break the read path.
        self.assertIn("403", js)
        self.assertIn("markViewOnly", js)
        self.assertIn("writesActive", js)

    def test_board_js_merge_has_optimistic_busy_state(self):
        """BUG-044: the Merge (approve) click must OPTIMISTICALLY mark the card
        busy so it is non-clickable from the first click until the real
        reconcileStatus arrives — no double-dispatch. Mirrors the STARTING
        pattern (UX-17): a MERGING set with mark/clear/is helpers + safety
        timeout, gated like isReconcileHealing in the card + verify dialog."""
        js = self._text("/board.js")
        for fn in ("markMerging", "clearMerging", "isMerging"):
            self.assertIn(fn, js, "board.js must define %s" % fn)
        # the optimistic set + a safety timeout (mirror STARTING_TIMEOUT_MS).
        self.assertIn("MERGING", js)
        self.assertIn("MERGING_TIMEOUT_MS", js)
        # the card/dialog gate must treat an optimistic merge like a live heal.
        self.assertIn("isReconcileHealing(m) || isMerging(m.id)", js)
        self.assertIn("isReconcileHealing(mi) || isMerging(mi.id)", js)

    def test_board_js_reapprove_has_optimistic_busy_state(self):
        """BUG-070: the Reapprove (merge-heal awaiting-reapprove gate) button must
        get the SAME optimistic busy treatment as the Merge button (BUG-044) — the
        button is DISABLED on the very first click so a second click can't double-
        fire the reapprove dispatch. doReapprove takes the clicked button and
        disables it immediately (before dispatch returns), and every call site
        (the card Reapprove gate, the card Retry-merge gate, and the detail-header
        Reapprove) passes its button so the disable applies. The dispatch error
        path re-arms (button.disabled = false), and the optimistic merge flag still
        rides the shared MERGING set (markMerging / clearMergingOnState)."""
        js = self._text("/board.js")
        # doReapprove must accept a button arg and disable it immediately on click.
        self.assertIn("function doReapprove(id, host, button)", js)
        self.assertIn("if (button) { button.disabled = true;", js)
        # it still applies the optimistic merge flag (shared with Merge, BUG-044).
        self.assertIn("markMerging(id)", js)
        # the error path re-arms the button so a failed dispatch is retryable.
        self.assertIn("if (button) { button.disabled = false; }", js)
        # every call site passes the clicked button so the disable actually applies
        # (card Reapprove gate, card Retry-merge gate, detail-header Reapprove).
        self.assertIn("doReapprove(m.id, ctrl, reBtn)", js)
        self.assertIn("doReapprove(m.id, ctrl, retryBtn)", js)
        self.assertIn("doReapprove(mi.id, null, rBtn)", js)

    def test_board_js_detail_header_verify_is_reconcile_gated(self):
        """BUG-049: the DETAIL-HEADER verify action must gate IDENTICALLY to the
        board card (cardControls) during a reconcile/merge/heal/resolving — a
        plain "✓ Verify" must NOT render in the header while the mission is mid-
        reconcile. Both call sites share the verifyAffordance decision (DRY),
        which carries the same reconcile/merge guards as the card."""
        js = self._text("/board.js")
        # the shared affordance helper exists and carries the reconcile/merge guards.
        self.assertIn("function verifyAffordance(m)", js)
        self.assertIn("isReconcileEscalated(m)", js)
        self.assertIn("isResolvingLocked(m)", js)
        self.assertIn("isReconcileHealing(m) || isMerging(m.id)", js)
        # the detail header must call the SHARED helper (not a bare btn("✓ Verify")).
        idx_actions = js.find("var actions = el(\"div\", \"det-actions\")")
        self.assertNotEqual(idx_actions, -1, "detail header det-actions block missing")
        header = js[idx_actions:idx_actions + 2500]
        # the header verify branch routes through the shared affordance decision.
        self.assertIn("verifyAffordance(mi)", header)
        # and gates exactly like the card: a non-action kind renders disabled.
        self.assertIn('daff.kind !== "action"', header)
        # the ungated plain "✓ Verify" header button (the BUG) is gone.
        self.assertNotIn('btn("✓ Verify", "go", function () { openVerify(mi.id); })', header)

    def test_board_css_has_detail_twopane_and_screen_classes(self):
        css = self._text("/board.css")
        # detail two-pane (mock .detail-grid / .det-head / .det-body / .feed)
        for sel in (".detail-grid", ".det-head", ".det-body", ".feed", ".evt",
                    ".marker", ".tabbar", ".tabpane", ".check", ".mix",
                    ".modal", ".modal-head", ".twopane", ".card-ctrl"):
            self.assertIn(sel, css, "board.css must style %s" % sel)
        # stage-coloured markers for the feed.
        self.assertIn(".evt.s-research", css)
        self.assertIn(".evt.s-gate", css)
        # the overlay host (centered modal, not a side drawer).
        self.assertIn(".overlay", css)

    def test_board_css_does_not_redefine_lcars_tokens(self):
        """ADR-007: board.css must NOT redefine any --lcars-* token (the shared
        docs/lcars.css owns them). It may REFERENCE var(--lcars-*) freely."""
        css = self._text("/board.css")
        import re
        # a token DEFINITION looks like `--lcars-foo:` NOT inside a var(...).
        # strip every var(--lcars-...) reference first, then any remaining
        # `--lcars-...:` is an illegal redefinition.
        stripped = re.sub(r"var\(\s*--lcars-[^)]*\)", "", css)
        self.assertNotRegex(stripped, r"--lcars-[a-z-]+\s*:",
                            "board.css must not DEFINE any --lcars-* token")


if __name__ == "__main__":
    unittest.main()
