"""S177 — the Mission-Log overlay stops rebuilding the whole repo per request.

THE HOLE THIS CLOSES. Session 176 benchmarked `LocalAdapter.board()` in
isolation, reported 192.9 → 19.2 ms, and shipped. The captain came back the same
afternoon: *"I feel like there is still a noticeable lag between clicking a card
and getting the pop up."* He was right. In the RUNNING DAEMON `/api/board` took
**2.4 seconds** — and no test, and no benchmark, had ever compared the two
numbers, because every measurement called the adapter directly and none of them
went over HTTP.

Instrumenting one `/api/board` request found **784 full mission-detail builds**
(56 missions × 14 scans). Two causes, both measured:

  1. `LogFacts._linked_children` builds `self._reader.mission(name)` for EVERY
     mission in the repo, and only THEN reads `parentMission` off state.json
     with `_read_json_key` — the cheap test it already knows how to do, run
     after the expensive work it gates.
  2. `_waiting_counts → _waiting_children → _log_dispatch_is_stale →
     _batch_short_of_its_gate → _waiting_children` is mutually recursive and
     every arm re-walks the missions dir, so the scan ran 14 times per request.

These tests COUNT WORK rather than measure time. A timing assertion would pass
on a fast laptop with the defect fully intact, which is precisely how this
survived a round that was explicitly about performance.
"""
import copy
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.actions import LogFacts  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402


class _CountingReader(object):
    """A LocalAdapter that records every mission() build it is asked for."""

    def __init__(self, repo_root):
        self._inner = LocalAdapter(repo_root)
        self.built = []

    def mission(self, mid):
        self.built.append(mid)
        return self._inner.mission(mid)

    def board(self):
        return self._inner.board()

    def __getattr__(self, name):
        return getattr(self._inner, name)


class LinkedChildrenScanTest(unittest.TestCase):
    """PART D — test the cheap key BEFORE paying for the card."""

    PARENT = "m-parent"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        fx.plant_simple(self.tmp, self.PARENT, stage="verify", issue=100)
        for i in range(4):
            fx.plant_simple(self.tmp, "m-bug-%d" % i, stage="align",
                            issue=200 + i, mtype="bug", origin="log",
                            parent_mission=self.PARENT)
        # ...and a crowd of unrelated missions, which is what makes the repo
        # expensive and what the defect made it pay for.
        for i in range(50):
            fx.plant_simple(self.tmp, "m-other-%02d" % i, stage="done",
                            issue=300 + i)
        self.reader = _CountingReader(self.tmp)
        self.facts = LogFacts(self.tmp, reader=self.reader)

    def test_only_real_children_are_ever_built(self):
        kids = self.facts._linked_children(self.PARENT)
        self.assertEqual(sorted(c["id"] for c in kids),
                         ["m-bug-0", "m-bug-1", "m-bug-2", "m-bug-3"])
        # THE MEASUREMENT. 55 missions on disk, 4 of them children: a detail
        # build for anything else is work whose result is thrown away.
        self.assertEqual(
            sorted(self.reader.built),
            ["m-bug-0", "m-bug-1", "m-bug-2", "m-bug-3"],
            "a full mission detail must be built ONLY for an actual child")

    def test_the_children_themselves_are_unchanged(self):
        # Part D is a pure reordering, so the returned shape must not move.
        kids = {c["id"]: c for c in self.facts._linked_children(self.PARENT)}
        self.assertEqual(len(kids), 4)
        k = kids["m-bug-0"]
        self.assertEqual(k["issue"], 200)
        self.assertEqual(k["stage"], "align")
        self.assertEqual(k["type"], "bug")
        self.assertIn("pills", k)
        self.assertIn("modelMix", k)
        self.assertIs(k["queued"], False)
        self.assertIs(k["running"], False)

    def test_a_child_the_reader_cannot_build_is_still_skipped(self):
        # The old order tested `card is None` BEFORE the parent key. Hoisting the
        # key test must not lose that guard: a child whose detail cannot be built
        # has to drop out rather than crash the overlay.
        class _Nothing(_CountingReader):
            def mission(self, mid):
                self.built.append(mid)
                return None if mid == "m-bug-2" else _CountingReader.mission(
                    self, mid)

        facts = LogFacts(self.tmp, reader=_Nothing(self.tmp))
        kids = facts._linked_children(self.PARENT)
        self.assertEqual(sorted(c["id"] for c in kids),
                         ["m-bug-0", "m-bug-1", "m-bug-3"])

    def test_a_repo_with_no_children_builds_nothing(self):
        self.reader.built = []
        self.assertEqual(self.facts._linked_children("m-nobody"), [])
        self.assertEqual(self.reader.built, [],
                         "a parent nothing points at must cost no detail builds")


class OverlayScanScopeTest(unittest.TestCase):
    """PART E — one scan per request, not fourteen."""

    PARENT = "m-parent"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        fx.plant_simple(self.tmp, self.PARENT, stage="verify", issue=100)
        for i in range(4):
            fx.plant_simple(self.tmp, "m-bug-%d" % i, stage="align",
                            issue=200 + i, mtype="bug", origin="log",
                            parent_mission=self.PARENT)
        for i in range(20):
            fx.plant_simple(self.tmp, "m-other-%02d" % i, stage="done",
                            issue=300 + i)
        self.reader = _CountingReader(self.tmp)
        self.facts = LogFacts(self.tmp, reader=self.reader)

    def _scans(self):
        """How many times the missions dir was walked, inferred from repeats."""
        return len(self.facts._linked_children(self.PARENT))

    def test_one_overlay_scans_the_repo_once(self):
        board = LocalAdapter(self.tmp).board()
        self.reader.built = []
        self.facts.log_overlay(board)
        # 4 children, ONE scan. The defect built 4 x 14 across the recursion.
        self.assertEqual(
            len(self.reader.built), 4,
            "log_overlay must scan the missions dir once, not once per arm "
            "of the _waiting_children/_log_dispatch_is_stale recursion")

    def test_one_mission_overlay_scans_the_repo_once(self):
        detail = LocalAdapter(self.tmp).mission(self.PARENT)
        self.reader.built = []
        self.facts.log_overlay_mission(detail)
        self.assertEqual(len(self.reader.built), 4)

    def test_there_is_no_caching_outside_a_scope(self):
        # A write path calling _linked_children must behave exactly as before:
        # no memo, no staleness, every call a fresh read of disk.
        self.reader.built = []
        self.facts._linked_children(self.PARENT)
        self.facts._linked_children(self.PARENT)
        self.assertEqual(len(self.reader.built), 8,
                         "outside a request scope there must be NO memo")

    def test_a_scope_does_not_outlive_itself(self):
        board = LocalAdapter(self.tmp).board()
        self.facts.log_overlay(board)
        # A new child lands after the overlay returned. The next overlay must
        # see it — a scope that leaked would serve a frozen board for ever.
        fx.plant_simple(self.tmp, "m-bug-late", stage="align", issue=299,
                        mtype="bug", origin="log", parent_mission=self.PARENT)
        kids = self.facts._linked_children(self.PARENT)
        self.assertIn("m-bug-late", [c["id"] for c in kids])

    def test_a_scope_is_cleared_even_when_the_overlay_raises(self):
        boom = LocalAdapter(self.tmp).board()

        def explode(_self, _card, _counts=None):
            raise RuntimeError("kaboom")

        original = type(self.facts)._stamp_waiting
        type(self.facts)._stamp_waiting = explode
        try:
            with self.assertRaises(RuntimeError):
                self.facts.log_overlay(boom)
        finally:
            type(self.facts)._stamp_waiting = original
        # The memo must be gone, so a later call reads disk again.
        self.reader.built = []
        self.facts._linked_children(self.PARENT)
        self.facts._linked_children(self.PARENT)
        self.assertEqual(len(self.reader.built), 8,
                         "an exception must not leave a scope armed")

    def test_the_scope_is_thread_local(self):
        # The daemon is a ThreadingHTTPServer: two boards can render at once. A
        # scope kept on the instance would let one request serve another's
        # snapshot — the hardest class of bug to ever see again.
        seen = {}
        barrier = threading.Barrier(2, timeout=5)

        def in_scope(tag):
            with self.facts._log_scan_scope():
                self.facts._linked_children(self.PARENT)
                barrier.wait()
                # after the other thread has its OWN scope open, this thread's
                # cached snapshot must still be its own
                seen[tag] = len(self.facts._linked_children(self.PARENT))

        t1 = threading.Thread(target=in_scope, args=("a",))
        t2 = threading.Thread(target=in_scope, args=("b",))
        t1.start(); t2.start(); t1.join(6); t2.join(6)
        self.assertEqual(seen.get("a"), 4)
        self.assertEqual(seen.get("b"), 4)


class OverlayOutputIsUnchangedTest(unittest.TestCase):
    """The round's central safety claim: the overlay PUBLISHES the same facts.

    `waitingCount` is the one reading card, review panel and Go all take from
    `_waiting_counts` — the property S163 round 7 exists to guarantee. Making
    the scan cheap must not change a single value it produces.
    """

    PARENT = "m-parent"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        fx.plant_simple(self.tmp, self.PARENT, stage="verify", issue=100)
        # a spread of child states, so the waiting rule has something to decide
        for i, stage in enumerate(("align", "plan", "verify", "done")):
            fx.plant_simple(self.tmp, "m-bug-%d" % i, stage=stage,
                            issue=200 + i, mtype="bug", origin="log",
                            parent_mission=self.PARENT)
        for i in range(6):
            fx.plant_simple(self.tmp, "m-other-%d" % i, stage="done",
                            issue=300 + i)

    def test_waiting_counts_are_unchanged(self):
        facts = LogFacts(self.tmp)
        counts = facts._waiting_counts()
        # two children are short of verify/done; the other two are not.
        self.assertEqual(counts, {self.PARENT: 2})

    def test_the_stamped_board_is_unchanged(self):
        facts = LogFacts(self.tmp)
        board = facts.log_overlay(LocalAdapter(self.tmp).board())
        card = [c for c in board["columns"]["verify"]
                if c["id"] == self.PARENT][0]
        self.assertEqual(card.get("logWaitingCount"), 2)

    def test_a_repo_that_never_logged_a_bug_is_untouched(self):
        plain = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, plain, True)
        fx.plant_simple(plain, "m-001", stage="implement")
        # ONE board, deep-copied — two board() calls differ on activeSecondsAt
        # (it is time.time() by construction), which would fake a difference.
        board = LocalAdapter(plain).board()
        before = json.dumps(copy.deepcopy(board), sort_keys=True)
        after = json.dumps(LogFacts(plain).log_overlay(board), sort_keys=True)
        self.assertEqual(before, after,
                         "the additive contract: no log facts => byte-identical")


if __name__ == "__main__":
    unittest.main()
