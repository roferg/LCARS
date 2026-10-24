"""S218 fix round 1 — a Stage that FAILED says so on the board, where the card is.

The tester drove a real Research failure and found the board silent: the card
sat in ALIGN with only a Start button, `/api/board` carried no failure, the
detail's Research band said "in progress" (and earlier failed bands "✓
complete"), and a refused board START answered `{"ok": true}`.

The FACT these read is the one the pipeline RECORDS: the drive's `error` event
(its `stage` is the Stage that ran, its `detail` the whole sentence, its
`data.log` the failure log when one was written). Nothing is inferred from
prose. The card is NOT moved: stage-from-the-label (S191) stands — the failure
is shown ON the card, in the column it is in.

  F1  adapter payload `failure` {stage, sentence, log}; the card line; the
      detail block; the failed band chip; cleared by a later stage_start /
      stage_done / gate, and hidden while a new run is live.
  F3  a START the daemon can see will be refused (the S217 editor-shim guard)
      answers ok:false with the sentence, spawns nothing, and RECORDS the
      failure through run.sh's own event writer so the card shows it too.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

NODE = shutil.which("node")
CARD_HARNESS = os.path.join(HERE, "board_card_harness.js")
DETAIL_HARNESS = os.path.join(HERE, "board_detail_harness.js")
SECTIONS_HARNESS = os.path.join(HERE, "board_sections_harness.js")
REPO = os.path.dirname(os.path.dirname(HERE))
RUN_SH = os.path.join(REPO, "skills", "lcars-run", "run.sh")

MID = "m-rf"
LOG = ".git/lcars/missions/%s/research/worker-failure.log" % MID
SENTENCE = ("research failed: the question-generator worker produced no "
            "questions.txt after 3 attempt(s) — the last attempt exited 1; its "
            "error output for every attempt is in %s. Stage stopped, no "
            "advance." % LOG)


def _events_failed(ts=1000):
    return [
        {"ts": ts, "mission": MID, "stage": "research", "type": "stage_start",
         "detail": "starting"},
        {"ts": ts + 16, "mission": MID, "stage": "research", "type": "error",
         "detail": SENTENCE, "data": {"stageFailure": 1, "log": LOG}},
    ]


# S218 fix round 2 (D2): a pre-S214 `error` event, exactly as the captain's own
# history holds it — recorded against `align`, its sentence beheaded mid-word,
# and NO structured-failure marker. It must never be surfaced.
LEGACY_ALIGN_ERROR = {
    "ts": 500, "mission": MID, "stage": "align", "type": "error",
    "detail": "align failed: ars-20260918-001-fea3' @ fd4e952 (the worker "
              "exited 1)"}


def _plant(root, events, stage="align"):
    fx.plant_simple(root, MID, stage=stage, issue=7)
    fx.write_jsonl(os.path.join(fx.mission_dir(root, MID), "events.jsonl"),
                   events)


def _card(root):
    for m in LocalAdapter(root).board()["missions"]:
        if m["id"] == MID:
            return m
    raise AssertionError("no card")


def _flatten(node, acc=None):
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


def _node(harness, obj, *extra):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(obj, fh)
    try:
        out = subprocess.check_output([NODE, harness, path] + list(extra),
                                      stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


class AdapterFailureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_failed_research_rides_the_card_whole(self):
        _plant(self.tmp, _events_failed())
        c = _card(self.tmp)
        self.assertEqual(c.get("failure"),
                         {"stage": "research", "sentence": SENTENCE, "log": LOG})

    def test_the_card_is_not_moved(self):
        # S191: stage from the label, never the envelope — no invented stage.
        _plant(self.tmp, _events_failed())
        board = LocalAdapter(self.tmp).board()
        self.assertEqual([m["id"] for m in board["columns"]["align"]], [MID])
        self.assertEqual(_card(self.tmp)["stage"], "align")

    def test_detail_payload_carries_it_too(self):
        _plant(self.tmp, _events_failed())
        d = LocalAdapter(self.tmp).mission(MID)
        self.assertEqual(d["failure"]["sentence"], SENTENCE)

    def test_a_later_successful_stage_clears_it(self):
        evs = _events_failed() + [
            {"ts": 2000, "mission": MID, "stage": "research",
             "type": "stage_start", "detail": "starting"},
            {"ts": 2060, "mission": MID, "stage": "research",
             "type": "stage_done", "detail": "research done"},
        ]
        _plant(self.tmp, evs, stage="validate")
        self.assertNotIn("failure", _card(self.tmp))

    def test_a_new_run_starting_clears_it(self):
        evs = _events_failed() + [
            {"ts": 2000, "mission": MID, "stage": "research",
             "type": "stage_start", "detail": "starting"}]
        _plant(self.tmp, evs)
        self.assertNotIn("failure", _card(self.tmp))

    def test_hidden_while_a_driver_is_live(self):
        _plant(self.tmp, _events_failed())
        lock = os.path.join(fx.mission_dir(self.tmp, MID), "driver.lock")
        os.makedirs(lock)
        with open(os.path.join(lock, "pid"), "w") as fh:
            fh.write(str(os.getpid()))
        self.assertNotIn("failure", _card(self.tmp))

    def test_a_pre_log_error_event_still_reads_with_no_log(self):
        evs = [{"ts": 1, "mission": MID, "stage": "research", "type": "error",
                "detail": "research failed: boom", "data": {"stageFailure": 1}}]
        _plant(self.tmp, evs)
        self.assertEqual(_card(self.tmp)["failure"],
                         {"stage": "research", "sentence": "research failed: boom",
                          "log": None})

    def test_a_legacy_unmarked_align_error_is_not_surfaced(self):
        # D2: recorded, not inferred — an event without the marker is history
        # for the activity feed, never a card/detail failure.
        _plant(self.tmp, [LEGACY_ALIGN_ERROR])
        self.assertNotIn("failure", _card(self.tmp))
        d = LocalAdapter(self.tmp).mission(MID)
        self.assertNotIn("failure", d)
        # …and the feed still carries it exactly as before
        self.assertIn("align failed: ars-20260918",
                      json.dumps([a.get("detail") for a in d["activity"]]))

    def test_an_unmarked_research_error_is_not_surfaced_either(self):
        ev = dict(LEGACY_ALIGN_ERROR, stage="research",
                  detail="research failed: boom")
        _plant(self.tmp, [ev])
        self.assertNotIn("failure", _card(self.tmp))

    def test_a_marked_failure_after_legacy_history_is_surfaced(self):
        _plant(self.tmp, [LEGACY_ALIGN_ERROR] + _events_failed())
        self.assertEqual(_card(self.tmp)["failure"]["stage"], "research")

    def test_a_healthy_mission_has_no_failure_key(self):
        _plant(self.tmp, [{"ts": 1, "mission": MID, "stage": "research",
                           "type": "stage_start", "detail": "starting"}])
        self.assertNotIn("failure", _card(self.tmp))


_CARD = {
    "id": MID, "issue": 7, "stage": "align", "title": "Editor shell",
    "type": "feature", "engine": "copilot",
    "pills": {"cost": None, "reasoning": None, "implementation": None},
    "awaiting": False, "paused": False, "running": False, "queued": False,
    "dispatched": True, "tickets": [], "activity": [],
    "failure": {"stage": "research", "sentence": SENTENCE, "log": LOG},
}


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class RenderFailureTest(unittest.TestCase):
    def test_card_says_research_failed_in_a_whole_sentence(self):
        texts = [n.get("text", "") for n in _flatten(_node(CARD_HARNESS, _CARD))]
        self.assertIn("✖ Research failed — open the card to see why and where the log is.",
                      texts)
        # …and the card stays where it is: the stage line is the label's.
        self.assertIn("#7 · lcars:align", texts)

    def test_card_without_a_log_still_reads_whole(self):
        m = dict(_CARD, failure={"stage": "research", "sentence": "research failed: x",
                                 "log": None})
        texts = [n.get("text", "") for n in _flatten(_node(CARD_HARNESS, m))]
        self.assertIn("✖ Research failed — open the card to see why.", texts)

    def test_healthy_card_has_no_failure_line(self):
        m = dict(_CARD)
        m.pop("failure")
        texts = [n.get("text", "") for n in _flatten(_node(CARD_HARNESS, m))]
        self.assertFalse([t for t in texts if "failed" in t])

    def test_detail_states_the_whole_sentence_and_the_log(self):
        res = _node(DETAIL_HARNESS, _CARD, "detail")
        texts = [n.get("text", "") for n in _flatten(res.get("overlay"))]
        self.assertIn("✖ RESEARCH FAILED", texts)
        self.assertIn(SENTENCE, texts)
        self.assertIn("Log: " + LOG, texts)

    def test_the_feed_keeps_the_space_before_the_log_path(self):
        # The detail feed renders each event through sanitizeGateText; its tidy
        # step used to glue "is in .git/…" into "is in.git/…".
        js = (
            "const fs=require('fs'),vm=require('vm');"
            "const p={then(){return p},catch(){return p}};"
            "const sb={document:{getElementById(){return null},"
            "querySelector(){return null},querySelectorAll(){return []},"
            "createElement(){return {style:{},classList:{add(){}},"
            "appendChild(){},setAttribute(){}}},addEventListener(){}},"
            "location:{href:'',search:''},navigator:{},"
            "localStorage:{getItem(){return null},setItem(){}},"
            "setInterval(){},setTimeout(){},fetch(){return p},"
            "EventSource:function(){this.addEventListener=function(){}},"
            "console,JSON,Math,Date};sb.window=sb;vm.createContext(sb);"
            "try{vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),sb)}"
            "catch(e){}"
            "process.stdout.write(sb.sanitizeGateText(process.argv[2]));")
        out = subprocess.check_output(
            [NODE, "-e", js, os.path.join(HERE, "..", "static", "board.js"),
             SENTENCE]).decode("utf-8")
        self.assertIn("is in " + LOG, out)
        # …while a genuinely dangling " ." is still tidied.
        out2 = subprocess.check_output(
            [NODE, "-e", js, os.path.join(HERE, "..", "static", "board.js"),
             "run it `lcars run x` ."]).decode("utf-8")
        self.assertEqual(out2, "run it.")

    def test_failed_research_bands_say_failed(self):
        acts = [
            {"ts": 1000, "stage": "research", "type": "stage_start", "detail": "s"},
            {"ts": 1016, "stage": "research", "type": "error", "detail": SENTENCE,
             "data": {"stageFailure": 1}},
            {"ts": 2000, "stage": "research", "type": "stage_start", "detail": "s"},
            {"ts": 2016, "stage": "research", "type": "error", "detail": SENTENCE,
             "data": {"stageFailure": 1, "log": LOG}},
        ]
        out = _node(SECTIONS_HARNESS, acts, "chips")
        self.assertEqual(len(out), 2)
        for s in out:
            self.assertIn("✖ failed", s["chipTexts"])
            self.assertNotIn("in progress", s["chipTexts"])
            self.assertNotIn("✓ complete", s["chipTexts"])

    def test_a_legacy_unmarked_error_band_is_not_marked_failed(self):
        # D2: the feed shows pre-tonight history exactly as before — no ✖ chip.
        acts = [
            {"ts": 400, "stage": "align", "type": "stage_start", "detail": "s"},
            dict(LEGACY_ALIGN_ERROR),
        ]
        out = _node(SECTIONS_HARNESS, acts, "chips")
        for s in out:
            self.assertNotIn("✖ failed", s["chipTexts"])

    def test_a_band_that_recovered_is_complete(self):
        acts = [
            {"ts": 1000, "stage": "research", "type": "stage_start", "detail": "s"},
            {"ts": 1016, "stage": "research", "type": "stage_done", "detail": "d"},
            {"ts": 1017, "stage": "validate", "type": "stage_start", "detail": "s"},
        ]
        out = _node(SECTIONS_HARNESS, acts, "chips")
        self.assertIn("✓ complete", out[0]["chipTexts"])
        self.assertIn("in progress", out[1]["chipTexts"])


class StartRefusalTest(unittest.TestCase):
    """F3 — a START the daemon can see will be refused says so, synchronously."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        subprocess.run(["git", "init", "-q", self.tmp], check=True)
        # A harmless stand-in where VS Code keeps its shim. Never executed: the
        # guard only resolves it; if anything RAN it, the sentinel would say so.
        shim_dir = os.path.join(self.tmp, "vsc", "github.copilot-chat",
                                "copilotCli")
        os.makedirs(shim_dir)
        self.sentinel = os.path.join(self.tmp, "SHIM-RAN")
        self.shim = os.path.join(shim_dir, "copilot")
        with open(self.shim, "w") as fh:
            fh.write('#!/bin/sh\n: >"%s"\nexit 99\n' % self.sentinel)
        os.chmod(self.shim, 0o755)
        fx.plant_simple(self.tmp, MID, stage="align", issue=7,
                        worker_bin=self.shim)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_refused_start_answers_the_sentence_and_the_card_shows_it(self):
        from lcars_serve.actions import Actions, ActionError
        a = Actions(repo_root=self.tmp, scripts={"run": RUN_SH},
                    gh_bin=shutil.which("true"))
        with self.assertRaises(ActionError) as cm:
            a.start(MID)
        msg = cm.exception.message
        self.assertIn(self.shim, msg)
        self.assertIn("restart the viewscreen", msg)
        # nothing was spawned: no driver capture log, and the shim never ran
        logs = os.path.join(self.tmp, ".git", "lcars", "logs")
        self.assertFalse(os.path.isdir(logs) and os.listdir(logs))
        self.assertFalse(os.path.exists(self.sentinel))
        # …and the refusal is RECORDED, so the card says it where it sits
        c = _card(self.tmp)
        self.assertEqual(c["stage"], "align")
        self.assertEqual(c["failure"]["stage"], "research")
        self.assertIn(msg, c["failure"]["sentence"])
        self.assertTrue(c["failure"]["sentence"].startswith("research failed: "))
        # D2: the recorded refusal carries the structured-failure marker
        ev = [json.loads(l) for l in open(os.path.join(
            fx.mission_dir(self.tmp, MID), "events.jsonl")) if l.strip()]
        errs = [e for e in ev if e.get("type") == "error"]
        self.assertEqual(errs[-1].get("data", {}).get("stageFailure"), 1)


if __name__ == "__main__":
    unittest.main()


# ===========================================================================
# S312 — THE SAME FACT, READ FROM MISSION STATE, AND A CARD THAT READS AS FAILED
# ===========================================================================
# S218 (everything above) put the failure in the EVENT LOG and rendered a NOTE
# on the card. Two things were still missing, and both cost 4 hours 49 minutes
# on a real mission:
#
#   1. Nothing in MISSION STATE said the mission had failed. `state.json.stage`
#      is the resume pointer, so a mission whose Implement died read
#      `"stage": "implement"` — byte-identical to healthy work — and every
#      reader that asks mission state rather than the event log (the ECH, its
#      `status`, the hourly heartbeat) saw nothing wrong. S312 writes
#      failedStage / failedAt / failedReason there, beside `awaitingHuman`,
#      which is the precedent for a non-working state.
#
#   2. The CARD carried a note but kept the chrome of healthy work. A mission
#      that has died must not LOOK like one that is working.
#
# WHAT THESE TESTS CANNOT SEE, stated plainly because the last time it was not
# written down it cost three fix rounds: every harness in this directory calls
# render()/cardNode() itself, so none of them can tell a working board from a
# blank one. The class assertion below proves the class is COMPUTED; it does not
# prove the page paints or that the rule resolves to a visible colour. That is
# proven in real Chrome by tests/drives/browser/smoke.sh and the screenshot a
# human then opens.

def _plant_state_failed(root, stage="implement", **extra):
    """A mission with S312's recorded failure and NO events.jsonl at all.

    That absence is the real shape: the driver exited normally after the stage
    stop, so there is nothing in the event log to supersede or to read.
    """
    fx.plant_simple(root, MID, stage=stage, issue=7)
    sp = os.path.join(fx.mission_dir(root, MID), "state.json")
    with open(sp) as fh:
        st = json.load(fh)
    st["failedStage"] = stage
    st["failedAt"] = "2026-10-23T01:36:00Z"
    st["failedReason"] = "implement failed: the self-heal round could not apply its fix"
    st.update(extra)
    with open(sp, "w") as fh:
        json.dump(st, fh)


class StateFailureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_recorded_failed_state_reaches_the_card(self):
        _plant_state_failed(self.tmp)
        self.assertFalse(os.path.exists(os.path.join(
            fx.mission_dir(self.tmp, MID), "events.jsonl")),
            "the fixture must have NO event log — that is the real shape")
        self.assertEqual(_card(self.tmp).get("failure"), {
            "stage": "implement",
            "sentence": "implement failed: the self-heal round could not apply its fix",
            "log": None,
        })

    def test_the_recorded_log_path_rides_it(self):
        # A record that becomes the PREFERRED source must not lose what the
        # event lane carried. Caught in the real suite before it shipped.
        _plant_state_failed(self.tmp, failedLog=LOG)
        self.assertEqual(_card(self.tmp)["failure"]["log"], LOG)

    def test_no_log_recorded_is_none_not_empty(self):
        _plant_state_failed(self.tmp)
        self.assertIsNone(_card(self.tmp)["failure"]["log"])

    def test_a_healthy_mission_still_has_no_failure(self):
        # The control. Same fixture, no recorded failure.
        fx.plant_simple(self.tmp, MID, stage="implement", issue=7)
        self.assertIsNone(_card(self.tmp).get("failure"))

    def test_the_stage_is_not_collapsed_into_failed(self):
        # "at implement, FAILED" — never "at failed". The column is unchanged.
        _plant_state_failed(self.tmp)
        board = LocalAdapter(self.tmp).board()
        self.assertEqual([m["id"] for m in board["columns"]["implement"]], [MID])
        self.assertEqual(_card(self.tmp)["stage"], "implement")

    def test_the_event_log_still_wins_when_state_has_no_record(self):
        # No regression on S218's lane: a mission with only the event-log fact
        # reads exactly as it did before S312, log path and all.
        _plant(self.tmp, _events_failed())
        self.assertEqual(_card(self.tmp).get("failure"),
                         {"stage": "research", "sentence": SENTENCE, "log": LOG})

    def test_hidden_while_a_driver_is_live(self):
        # Same rule as the event-log lane: a live run means the last failure is
        # not the news. Written with a REAL pid — this process's own — because
        # an invented one answers whichever way the host's pid space falls.
        _plant_state_failed(self.tmp)
        lock = os.path.join(fx.mission_dir(self.tmp, MID), "driver.lock")
        os.makedirs(lock, exist_ok=True)
        with open(os.path.join(lock, "pid"), "w") as fh:
            fh.write("%d\n" % os.getpid())
        self.assertIsNone(_card(self.tmp).get("failure"))


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class FailedCardChromeTest(unittest.TestCase):
    """The CARD reads as failed, not as in-progress-with-a-note.

    This is the `.awaiting` precedent: `cardNode` adds a class to the card
    itself off the same `m.failure` fact the note already reads.
    """

    def test_a_failed_card_carries_the_failed_class(self):
        cls = _node(CARD_HARNESS, _CARD)["cls"]
        self.assertIn("failed", cls.split(),
                      "the card itself must read as failed, not just carry a note")

    def test_a_healthy_card_does_not(self):
        m = dict(_CARD)
        m.pop("failure")
        cls = _node(CARD_HARNESS, m)["cls"]
        self.assertNotIn("failed", cls.split())

    def test_the_failed_chrome_has_a_stylesheet_rule(self):
        # A class nothing styles is a class that paints nothing — the exact
        # failure mode that made a legend swatch invisible while every markup
        # assertion passed. This checks the rule EXISTS; real Chrome checks it
        # resolves to something you can see.
        css = os.path.join(REPO, "web", "static", "board.css")
        with open(css) as fh:
            text = fh.read()
        self.assertIn(".card.failed{", text)


# ===========================================================================
# S312 FIX ROUND 1 — THE LIVENESS GUARD, WIDENED TO MATCH THE RECORD'S LIFE
# ===========================================================================
# S312 cleared the recorded failure when the next attempt STARTED, and a fresh
# tester hard-killed a drive mid-stage: the record was gone and never re-written
# (the driver died first), so every surface — this one included — went blind.
# `failure: null` on a mission nobody was advancing.
#
# The cure is that the record is cleared by a stage that SUCCEEDS. Which means
# that WHILE A RETRY IS IN FLIGHT the stale record is still on disk, and this
# card must not read as failed. `_driver_running` (the mission's driver.lock)
# already covers a drive, and every drive holds that lock.
#
# IT DOES NOT COVER A BARE STAGE RUN. `acquire_driver_lock` is called from
# `cmd_drive` alone, so `lcars run <stage>` works a mission with no lock and no
# drive record at all — and before this round the stage_start clear is what hid
# the stale record on that path. So the guard reads the SECOND witness the ECH's
# `stalled` already reads: a live `worker-adapter` process whose own argv names
# this mission's directory. It is consulted ONLY for a mission that would
# otherwise be reported failed, so a healthy board pays nothing for it.
#
# THE DIRECTION IS DELIBERATE: this probe can only ever BUY SILENCE. It cannot
# invent a failure, so the worst a wrong answer costs is a report that arrives
# when the worker exits — against a false ✖ on live work, which is the defect
# that teaches a captain to ignore his own board.
#
# REAL PROCESSES ONLY. A made-up pid in a lock file is a stub of the very thing
# under test: `kill -0` on an invented pid answers whichever way the host's pid
# space happens to fall.
class LivenessGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.procs = []

    def tearDown(self):
        # Killed BY PID — only the processes this test started.
        for p in self.procs:
            try:
                p.kill()
                p.wait(timeout=5)
            except Exception:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _adapter_proc(self, mission_dir):
        """A REAL process whose argv looks like run.sh's cold-worker spawn."""
        script = os.path.join(self.tmp, "worker-adapter.sh")
        with open(script, "w") as fh:
            fh.write("#!/usr/bin/env bash\nwhile :; do sleep 1; done\n")
        os.chmod(script, 0o755)
        p = subprocess.Popen(
            ["bash", script, "spawn", "claude", "repo-write",
             os.path.join(mission_dir, "implement"), "<prompt 1234 bytes>"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def test_a_live_worker_adapter_hides_the_failure(self):
        _plant_state_failed(self.tmp)
        d = fx.mission_dir(self.tmp, MID)
        self.assertFalse(os.path.exists(os.path.join(d, "driver.lock")),
                         "a bare stage run holds no lock — that is the point")
        p = self._adapter_proc(d)
        self.assertIsNone(p.poll(), "the fixture worker must really be running")
        self.assertIsNone(_card(self.tmp).get("failure"))

    def test_and_once_that_worker_exits_the_failure_is_shown_again(self):
        _plant_state_failed(self.tmp)
        d = fx.mission_dir(self.tmp, MID)
        p = self._adapter_proc(d)
        self.assertIsNone(_card(self.tmp).get("failure"))
        p.kill()
        p.wait(timeout=5)
        self.assertIsNotNone(
            _card(self.tmp).get("failure"),
            "a guard that is silent both ways is not a guard")

    def test_an_adapter_working_a_DIFFERENT_mission_buys_no_silence(self):
        # The argv match must be anchored on THIS mission's directory, or one
        # live worker anywhere would silence the whole board.
        _plant_state_failed(self.tmp)
        other = os.path.join(os.path.dirname(fx.mission_dir(self.tmp, MID)),
                             "m-someone-else")
        os.makedirs(other, exist_ok=True)
        p = self._adapter_proc(other)
        self.assertIsNone(p.poll())
        self.assertIsNotNone(_card(self.tmp).get("failure"))

    def test_a_dead_lock_owner_does_not_buy_silence(self):
        # The killed-mid-stage shape: the lock dir is still there and its owner
        # is gone. A real process, started and reaped, so the pid is genuinely
        # dead rather than merely unlikely.
        _plant_state_failed(self.tmp)
        p = subprocess.Popen(["true"])
        p.wait(timeout=5)
        lock = os.path.join(fx.mission_dir(self.tmp, MID), "driver.lock")
        os.makedirs(lock, exist_ok=True)
        with open(os.path.join(lock, "pid"), "w") as fh:
            fh.write("%d\n" % p.pid)
        self.assertIsNotNone(_card(self.tmp).get("failure"))
