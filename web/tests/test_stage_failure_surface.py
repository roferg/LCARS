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
