# -*- coding: utf-8 -*-
"""S197 — THE BOARD ASKS WHICH ENGINE, BECAUSE THE COMMAND LINE DOES.

THE DEFECT THE CAPTAIN FOUND HIMSELF, and the way he found it is the point:
every screenshot of the adopt engine question is a TERMINAL, because the
viewscreen could not produce one. There was nothing to photograph.

`lcars adopt` at a tty ASKS which CLI should drive a mission on this laptop —
the ruling of 2026-09-09, taken because a laptop may only have ONE CLI
installed, so a mission filed on the other one is not a handover unless
something converts it. The board's dispatch (web/lcars_serve/actions.py) passed
no `--engine` and ran with no tty, so adopt.sh took its documented
non-interactive path:

    the mission's engine IS installed here  → keep it, silently
    the mission's engine is NOT here        → REFUSE, loudly

…which means that on the board, in exactly the case the feature exists for, the
captain clicked Adopt and got a refusal where the CLI would have asked him a
question. The standing ruling is that the board is a UI version of the command
line; where the two disagree the CLI is the reference and the board comes up to
it. And the captain WORKS FROM THE VIEWSCREEN (2026-09-07), so this is the
surface that actually matters.

WHAT IS PINNED HERE, in order of importance:

  1. A ONE-CLI MACHINE GETS A CHOICE, NOT A REFUSAL. The board offers the
     engines this laptop has, says which one the mission was filed on, and
     dispatches the answer.

  2. THE DEFAULT IS THE MISSION'S OWN ENGINE, and taking it sends NOTHING —
     the identical argv this daemon has always sent. Doing nothing reproduces
     today's behaviour exactly, `note()` warnings and all.

  3. IT IS REACHABLE ON A TWO-CLI LAPTOP. The CLI only prompts on absence or
     disagreement, which is why the captain has never seen the question. The
     board surfaces the decision every time, with the same default — a strict
     SUPERSET of the CLI's behaviour, not a contradiction of it.

  4. ONE DETECTOR (ADR-002). The daemon learns what this machine has from
     `lcars_available_engines` in skills/lcars-init/lcars-common.sh — the same
     answer `lcars init`, the front door's picker and adopt.sh itself read.
     There is no second `command -v` in Python.

  5. NO EXTRA FORGE ROUND TRIP (S152). The mission's own engine comes out of
     the handoff envelope in the issue BODY, which is already in the one cached
     listing. Pinned by counting the stub's argv lines.

No gh, no network, no model, no engine binary: `gh` is a recording bash stub,
the detector is injected, and adopt.sh is a stub that records its argv.
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
from tests.test_remote_overlay import (  # noqa: E402
    _adopt_stub, calls, gh_stub, issue, remote)
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

ME = "roferg"
NODE = shutil.which("node")
OWNER_HARNESS = os.path.join(HERE, "board_owner_harness.js")


def envelope(mid="lcars-20260909-001", branch=None, engine="copilot"):
    """The S188 handoff envelope line, exactly as issue-body.sh writes it."""
    blob = {
        "id": mid,
        "branch": branch or ("lcars/" + mid),
        "base": "main",
        "type": "feature",
        "engine": engine,
        "parentIssue": None,
        "attachments": 0,
    }
    return "<!-- lcars:handoff v1 %s -->" % json.dumps(blob, sort_keys=True)


def filed_on(engine, mid="lcars-20260909-001"):
    """An issue body with a PRD above and the envelope appended below."""
    return "A remote mission.\n\n" + envelope(mid=mid, engine=engine)


def board_of(tmp, rows, record, engines):
    """A LocalAdapter whose forge answers `rows` and whose machine has
    `engines`. The detector is INJECTED, never $PATH-sniffed: the question
    "what does this laptop have" is the subject, so a test that depended on the
    tester's own laptop would be measuring the wrong machine."""
    return LocalAdapter(
        tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
        remote=remote(tmp, rows, record),
        engines_reader=(lambda: list(engines)))


# ==========================================================================
# 1. THE SHAPE — what an adoptable remote card carries, and when
# ==========================================================================
class TheCardCarriesBothHalvesOfTheQuestion(unittest.TestCase):
    """The forge's half (`engine`) and this laptop's half (`enginesHere`)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _cards(self, rows, engines=("claude", "copilot")):
        b = board_of(self.tmp, rows, self.record, engines).board()
        return {c["id"]: c for c in b["missions"]}

    def test_the_mission_says_which_engine_it_was_filed_on(self):
        c = self._cards([issue(201, stage="align",
                               body=filed_on("copilot"))])["201"]
        self.assertEqual("copilot", c.get("engine"))

    def test_and_the_card_says_what_THIS_machine_has(self):
        c = self._cards([issue(201, stage="align",
                               body=filed_on("copilot"))],
                        engines=("claude",))["201"]
        self.assertEqual(["claude"], c.get("enginesHere"))

    def test_a_body_with_no_envelope_names_no_engine(self):
        # ABSENT, NEVER NULL — the rule every additive key on this shape has
        # followed since S109, and what keeps an older board untouched.
        c = self._cards([issue(201, stage="align", body="just a PRD")])["201"]
        self.assertNotIn("engine", c)

    def test_engine_null_in_the_envelope_names_no_engine_either(self):
        # `engine: null` is a DELIBERATE S188 answer: the filing laptop pinned
        # nothing and host detection is legitimately in charge. Inventing one
        # here would be the board deciding something nobody decided.
        body = "A remote mission.\n\n" + envelope(engine=None).replace(
            '"engine": null', '"engine": null')
        c = self._cards([issue(201, stage="align", body=body)])["201"]
        self.assertNotIn("engine", c)

    def test_a_TRUNCATED_envelope_never_invents_an_engine(self):
        body = "A remote mission.\n\n<!-- lcars:handoff v1 {\"engine\":\"cop"
        c = self._cards([issue(201, stage="align", body=body)])["201"]
        self.assertNotIn("engine", c)

    def test_the_LAST_envelope_wins_when_a_PRD_quotes_one(self):
        # adopt.sh resolves a quoted envelope exactly this way (`last = NR`);
        # two readers of one body must never read two different envelopes.
        body = ("Here is what an envelope looks like:\n"
                + envelope(engine="claude") + "\n\n"
                + envelope(engine="copilot"))
        c = self._cards([issue(201, stage="align", body=body)])["201"]
        self.assertEqual("copilot", c.get("engine"))

    def test_a_mission_MID_PIPELINE_is_offered_no_engines(self):
        # The question only exists where Adopt does. A card with no Adopt that
        # carried an engine list would be offering a choice it cannot honour.
        c = self._cards([issue(202, stage="implement",
                               body=filed_on("copilot"))])["202"]
        self.assertNotIn("enginesHere", c)

    def test_a_LOCAL_card_never_grows_the_key(self):
        fx.plant_simple(self.tmp, "m-local", stage="align", issue=101)
        c = self._cards([issue(201, stage="align")])["m-local"]
        self.assertNotIn("enginesHere", c)

    def test_a_detector_that_answers_NOTHING_adds_no_key(self):
        # An honest empty answer (neither CLI installed) must leave the card
        # exactly as it was, so the front end falls back to the one-click
        # dispatch rather than painting an empty picker.
        c = self._cards([issue(201, stage="align",
                               body=filed_on("copilot"))], engines=())["201"]
        self.assertNotIn("enginesHere", c)

    def test_a_detector_that_BLOWS_UP_never_costs_the_board(self):
        def boom():
            raise RuntimeError("no bash here")
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp, [issue(201, stage="align")], self.record),
            engines_reader=boom)
        cards = {c["id"]: c for c in adapter.board()["missions"]}
        self.assertIn("201", cards)
        self.assertNotIn("enginesHere", cards["201"])

    def test_the_DETAIL_offers_the_same_question_as_the_card(self):
        # BUG-049's rule: the two doors onto one mission gate identically or
        # they gate wrongly.
        d = board_of(self.tmp, [issue(201, stage="verify",
                                      body=filed_on("copilot"))],
                     self.record, ("claude",)).mission("201")
        self.assertEqual("copilot", d.get("engine"))
        self.assertEqual(["claude"], d.get("enginesHere"))


class ItCostsTheForgeNOTHING(unittest.TestCase):
    """S152 — the engine facts ride the ONE cached listing, never a second call."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def test_25_board_builds_still_cost_exactly_one_gh_invocation(self):
        adapter = board_of(self.tmp,
                           [issue(201, stage="align", body=filed_on("copilot")),
                            issue(203, stage="verify", body=filed_on("claude"))],
                           self.record, ("claude", "copilot"))
        for _ in range(25):
            b = adapter.board()
        self.assertEqual(1, len(calls(self.record)),
                         "the engine facts bought a second forge round trip")
        # …and a no-op cannot pass it: the facts really landed.
        cards = {c["id"]: c for c in b["missions"]}
        self.assertEqual("copilot", cards["201"]["engine"])
        self.assertEqual(["claude", "copilot"], cards["201"]["enginesHere"])

    def test_the_DETECTOR_is_asked_once_per_board_not_once_per_card(self):
        n = {"calls": 0}

        def count():
            n["calls"] += 1
            return ["claude", "copilot"]
        adapter = LocalAdapter(
            self.tmp, git_url_reader=lambda r: "git@x:acme/repo.git",
            remote=remote(self.tmp,
                          [issue(201, stage="align"), issue(203, stage="verify"),
                           issue(204, stage="align")], self.record),
            engines_reader=count)
        adapter.board()
        self.assertEqual(1, n["calls"])


class TheDetectorIsTheSHAREDOne(unittest.TestCase):
    """ADR-002 — one answer to 'what does this machine have', not two.

    The default reader SOURCES skills/lcars-init/lcars-common.sh and calls
    `lcars_available_engines`. Proven by pointing $LCARS_COMMON_LIB at a stub
    library that defines that ONE function: if the daemon had its own detector,
    the stub's answer could not possibly come out.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _with_lib(self, body):
        lib = os.path.join(self.tmp, "lcars-common.sh")
        with open(lib, "w") as fh:
            fh.write(body)
        old = os.environ.get("LCARS_COMMON_LIB")
        os.environ["LCARS_COMMON_LIB"] = lib
        self.addCleanup(lambda: (os.environ.__setitem__("LCARS_COMMON_LIB", old)
                                 if old is not None
                                 else os.environ.pop("LCARS_COMMON_LIB", None)))
        return LocalAdapter(self.tmp, git_url_reader=lambda r: "git@x:acme/r.git")

    def test_the_shared_function_is_what_answers(self):
        a = self._with_lib("lcars_available_engines() { printf 'copilot\\n'; }\n")
        self.assertEqual(["copilot"], a._engines_here())

    def test_a_library_without_it_answers_NOTHING_rather_than_guessing(self):
        a = self._with_lib("# an older lcars-common.sh\n")
        self.assertEqual([], a._engines_here())

    def test_the_answer_is_memoized_so_a_board_render_is_not_a_spawn(self):
        a = self._with_lib("lcars_available_engines() { printf 'claude\\n'; }\n")
        self.assertEqual(["claude"], a._engines_here())
        with open(os.environ["LCARS_COMMON_LIB"], "w") as fh:
            fh.write("lcars_available_engines() { printf 'copilot\\n'; }\n")
        self.assertEqual(["claude"], a._engines_here(), "the memo did not hold")


# ==========================================================================
# 2. THE PICKER — what the captain actually sees and presses
# ==========================================================================
@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class ThePickerOnTheCard(unittest.TestCase):
    """The real board.js, the real card, the real click."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")

    def _render(self, engines=("claude", "copilot"), filed="copilot",
                stage="align", click=None, body=None):
        rows = [issue(201, stage=stage,
                      body=(body if body is not None
                            else (filed_on(filed) if filed else "no envelope")))]
        b = board_of(self.tmp, rows, self.record, engines).board()
        card = {c["id"]: c for c in b["missions"]}["201"]
        spec = {"mission": card, "self": ME}
        if click:
            spec["steps"] = [{"click": click}]
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump(spec, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    def _walk(self, n, out=None):
        out = [] if out is None else out
        out.append(n)
        for k in n.get("children", []):
            self._walk(k, out)
        return out

    def _buttons(self, dom):
        return [n for n in self._walk(dom)
                if (n.get("tag") or "").lower() == "button"]

    def _options(self, dom):
        return [n for n in self._buttons(dom)
                if "adopt-engine" in (n.get("cls") or "")]

    # -- it is not there until he asks for it ------------------------------
    def test_a_freshly_painted_card_shows_no_picker(self):
        self.assertEqual([], self._options(self._render()))

    def test_and_still_offers_exactly_one_adopt_control(self):
        ad = [b for b in self._buttons(self._render())
              if "ADOPT" in (b.get("text") or "").upper()]
        self.assertEqual(1, len(ad), [b.get("text") for b in ad])

    # -- THE HEADLINE: a one-CLI laptop is asked, not refused --------------
    def test_ONE_CLI_MACHINE_gets_a_CHOICE_not_a_refusal(self):
        """The mission was filed on copilot; this laptop only has claude.

        At the CLI this is the ASK branch. Through the daemon it was the REFUSE
        branch, because nobody could answer. The board must now be able to."""
        dom = self._render(engines=("claude",), filed="copilot",
                           click="adopt")
        opts = self._options(dom)
        self.assertTrue(opts, "the one-CLI machine was offered no choice at all")
        labels = [o.get("text") or "" for o in opts]
        self.assertTrue(any("Claude" in t for t in labels), labels)
        live = [o for o in opts if not o.get("disabled")]
        self.assertTrue(live, "every option was dead — that is a refusal, not a "
                              "choice")

    def test_the_engine_this_machine_LACKS_is_shown_and_UNUSABLE(self):
        # Still DRAWN, deliberately: "filed on copilot, and copilot is not
        # here" is the fact that explains the choice. Hiding it turns an
        # explanation into a mystery.
        dom = self._render(engines=("claude",), filed="copilot", click="adopt")
        dead = [o for o in self._options(dom) if o.get("disabled")]
        self.assertEqual(1, len(dead), [o.get("text") for o in self._options(dom)])
        self.assertIn("Copilot", dead[0].get("text") or "")
        self.assertIn("locked", dead[0].get("cls") or "")
        self.assertTrue((dead[0].get("text") or "").startswith("⊘ "),
                        dead[0].get("text"))

    def test_the_one_engine_it_HAS_is_the_default(self):
        dom = self._render(engines=("claude",), filed="copilot", click="adopt")
        chosen = [o for o in self._options(dom) if "chosen" in (o.get("cls") or "")]
        self.assertEqual(1, len(chosen))
        self.assertIn("Claude", chosen[0].get("text") or "")

    # -- reachable on a two-CLI laptop, with the mission's engine default ---
    def test_the_picker_is_REACHABLE_on_a_two_CLI_laptop(self):
        """The reason the captain had never seen this question."""
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        self.assertEqual(2, len(self._options(dom)),
                         [o.get("text") for o in self._options(dom)])

    def test_the_default_is_the_MISSIONS_engine(self):
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        chosen = [o for o in self._options(dom) if "chosen" in (o.get("cls") or "")]
        self.assertEqual(1, len(chosen))
        self.assertEqual("copilot", (chosen[0].get("attrs") or {}).get("data-engine"))
        self.assertIn("filed with this mission", chosen[0].get("text") or "")

    def test_the_missions_engine_is_offered_FIRST(self):
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        first = self._options(dom)[0]
        self.assertEqual("copilot", (first.get("attrs") or {}).get("data-engine"))

    def test_a_mission_that_pinned_NOTHING_defaults_to_pinning_nothing(self):
        # adopt.sh leaves `engine: null` alone on purpose (S188). The board
        # must offer the same non-answer as its default, or a click would pin
        # an engine nobody chose.
        dom = self._render(engines=("claude", "copilot"), filed=None,
                           click="adopt")
        chosen = [o for o in self._options(dom) if "chosen" in (o.get("cls") or "")]
        self.assertEqual(1, len(chosen))
        self.assertEqual("", (chosen[0].get("attrs") or {}).get("data-engine"))
        self.assertIn("host CLI decides", chosen[0].get("text") or "")

    # -- the vocabulary ----------------------------------------------------
    HOUSE = u"▶▸▹✓⏸◐◷↻◆✹" \
            u"⊘◈"

    def test_no_glyph_in_the_picker_is_OUTSIDE_the_house_family(self):
        dom = self._render(engines=("claude",), filed="copilot", click="adopt")
        for n in self._walk(dom):
            for ch in (n.get("text") or ""):
                if ord(ch) > 0x2000 and ch not in u"—–…’":
                    self.assertIn(ch, self.HOUSE,
                                  "%r is outside the house family (in %r)"
                                  % (ch, n.get("text")))

    def test_SOLID_means_chosen_and_HOLLOW_means_merely_available(self):
        """This round's language, carried by SHAPE so it survives greyscale."""
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        for o in self._options(dom):
            t = o.get("text") or ""
            if o.get("disabled"):
                self.assertTrue(t.startswith(u"⊘ "), t)   # ⊘ not here
            elif "chosen" in (o.get("cls") or ""):
                self.assertTrue(t.startswith(u"◆ "), t)   # ◆ in force
            else:
                self.assertTrue(t.startswith(u"◈ "), t)   # ◈ available

    def test_the_confirm_keeps_the_shared_dispatch_suffix(self):
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        go = [b for b in self._buttons(dom)
              if "adopt-confirm" in (b.get("cls") or "")]
        self.assertEqual(1, len(go))
        self.assertTrue((go[0].get("text") or "").endswith(u" ▸"),
                        go[0].get("text"))
        self.assertTrue((go[0].get("text") or "").startswith(u"◆ "),
                        go[0].get("text"))

    def test_it_names_the_engine_it_is_about_to_use(self):
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        go = [b for b in self._buttons(dom)
              if "adopt-confirm" in (b.get("cls") or "")][0]
        self.assertIn("Copilot", go.get("text") or "")

    def test_there_is_a_way_out_that_adopts_nothing(self):
        dom = self._render(engines=("claude", "copilot"), click="adopt")
        self.assertEqual(1, len([b for b in self._buttons(dom)
                                 if "adopt-cancel" in (b.get("cls") or "")]))

    def test_the_group_announces_itself_to_a_screen_reader(self):
        dom = self._render(engines=("claude", "copilot"), click="adopt")
        groups = [n for n in self._walk(dom)
                  if (n.get("attrs") or {}).get("role") == "group"]
        self.assertTrue(groups)
        self.assertIn("engine",
                      (groups[0].get("attrs") or {}).get("aria-label", ""))

    def test_every_option_is_a_real_button_so_TAB_reaches_it(self):
        # Keyboard reachability is not a style: a span with a click handler is
        # unreachable, which is the S140 lesson. Real buttons take focus, take
        # Enter/Space, and take board.css's amber :focus-visible ring.
        dom = self._render(engines=("claude", "copilot"), click="adopt")
        for o in self._options(dom):
            self.assertEqual("button", (o.get("tag") or "").lower())

    def test_the_options_report_their_pressed_state(self):
        dom = self._render(engines=("claude", "copilot"), filed="copilot",
                           click="adopt")
        states = sorted((o.get("attrs") or {}).get("aria-pressed")
                        for o in self._options(dom))
        self.assertEqual(["false", "true"], states)

    # -- it survives the board repainting underneath him -------------------
    def _steps(self, steps, engines=("claude", "copilot"), filed="copilot"):
        rows = [issue(201, stage="align", body=filed_on(filed))]
        b = board_of(self.tmp, rows, self.record, engines).board()
        card = {c["id"]: c for c in b["missions"]}["201"]
        fd, p = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        self.addCleanup(os.unlink, p)
        with open(p, "w") as fh:
            json.dump({"mission": card, "self": ME, "steps": steps}, fh)
        return json.loads(subprocess.check_output([NODE, OWNER_HARNESS, p]))

    def test_the_QUESTION_SURVIVES_the_boards_own_repaint(self):
        """Found by the pixel rig, not by this file — and it is the third time
        this project has met the shape (S196.1 cured the avatar give-up window
        for the same reason, one commit before this round). The board rebuilds
        every card off its four-second poll, so a picker that lived only in the
        DOM was deleted underneath the captain while he was reading it. A
        question that closes itself after four seconds is not a question."""
        dom = self._steps([{"click": "adopt"}, {"rerender": True}])
        self.assertTrue(self._options(dom),
                        "the repaint threw the engine question away")

    def test_and_it_comes_back_on_the_option_he_had_CHOSEN(self):
        # Not reset to the default: a repaint is not a change of mind.
        dom = self._steps([{"click": "adopt"},
                           {"click": "data-engine"},   # never matches — noop
                           {"rerender": True}])
        chosen = [o for o in self._options(dom) if "chosen" in (o.get("cls") or "")]
        self.assertEqual(1, len(chosen))
        self.assertEqual("copilot",
                         (chosen[0].get("attrs") or {}).get("data-engine"))

    def test_CANCEL_is_remembered_as_cancelled_across_a_repaint(self):
        # The other half, and the one a naive memo gets wrong: a question he
        # DISMISSED must not come back on the next tick.
        dom = self._steps([{"click": "adopt"}, {"click": "adopt-cancel"},
                           {"rerender": True}])
        self.assertEqual([], self._options(dom))

    # -- nothing to ask with ⇒ nothing changes ------------------------------
    def test_a_daemon_that_SENDS_NO_LIST_still_dispatches_in_one_click(self):
        dom = self._render(engines=(), filed="copilot", click="adopt")
        self.assertEqual([], self._options(dom))
        ad = [b for b in self._buttons(dom)
              if "remote-adopt" in (b.get("cls") or "")][0]
        self.assertIn(u"Adopting", ad.get("text") or "",
                      "the one-click dispatch stopped happening")


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class NoHotkeyIsShadowed(unittest.TestCase):
    """The picker registers NO global key, so the command deck is untouched.

    The keyboard table is walked by test_hotkeys.py; this is the guard that
    stops a later round reaching for a letter. Escape is bound on the picker
    itself and consumed there (the WAI-ARIA pattern), which is exactly what
    `keyActivable` already does for the File console's engine control."""

    def test_the_picker_adds_no_entry_to_the_hotkey_table(self):
        from tests import test_hotkeys as th
        src = open(os.path.join(HERE, "..", "static", "board.js")).read()
        at = src.find("function openAdoptPicker")
        end = src.find("\nfunction closeAdoptPicker")
        self.assertGreater(at, 0)
        self.assertGreater(end, at)
        body = src[at:end]
        self.assertNotIn("HOTKEYS", body)
        self.assertNotIn("document.addEventListener", body)
        # the ONE key it consumes, and it is not a command-deck key
        self.assertIn('"Escape"', body)
        self.assertIsNotNone(th)


class NoNewColourTokenIsMinted(unittest.TestCase):
    """ADR-007 — one palette, in docs/lcars.css, never forked by this sheet."""

    def _block(self):
        css = open(os.path.join(HERE, "..", "static", "board.css")).read()
        at = css.find("S197 — THE ADOPT ENGINE PICKER")
        self.assertGreater(at, 0, "the picker's stylesheet block is gone")
        return css[at:]

    def _rules(self):
        """The DECLARATIONS only. The prose above them NAMES the tokens it
        borrows — that is the point of it — so a naive line scan reads the
        comment as a definition, which is how this test first went red."""
        block = self._block()
        end = block.find("*/")
        self.assertGreater(end, 0)
        return block[end + 2:]

    def test_the_block_defines_no_lcars_token(self):
        import re
        body = re.sub(r"/\*.*?\*/", "", self._rules(), flags=re.S)
        for line in body.splitlines():
            head = line.split(":")[0]
            self.assertNotIn("--lcars-", head,
                             "a shared token is being REDEFINED: %r" % line)

    def test_every_colour_it_uses_is_an_existing_shared_token(self):
        import re
        block = self._rules()
        # the one literal permitted is a transparent tint of a token already in
        # the sheet (`.pill.queued` uses the identical rgba for --lcars-violet)
        bad = [h for h in re.findall(r"#[0-9a-fA-F]{3,8}", block)
               if h.lower() not in ("#9977ff", "#4499ff", "#030608")]
        self.assertEqual([], bad, "a raw colour was minted: %s" % bad)


# ==========================================================================
# 3. THE WIRE — what actually reaches adopt.sh
# ==========================================================================
class _Serve(unittest.TestCase):
    def serve(self, adapter, actions):
        self.httpd = make_server(adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(
            url, data=json.dumps(obj or {}).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())


class TheAnswerReachesAdoptSh(_Serve):
    """`--engine`, adopt.sh's own flag, and nothing invented beside it."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.argv = os.path.join(self.tmp, "argv.txt")
        stub = _adopt_stub(self.tmp, "adopt.sh",
                           'printf "%s\\n" "$*" >> "' + self.argv + '"\n'
                           'echo "◇ Adopted lcars-1 — stage align"\nexit 0\n')
        actions = Actions(repo_root=self.tmp, scripts={"adopt": stub},
                          worker_bin="/bin/echo")
        adapter = board_of(self.tmp,
                           [issue(34, stage="align", body=filed_on("copilot"))],
                           self.record, ("claude", "copilot"))
        self.serve(adapter, actions)

    def test_the_chosen_engine_arrives_as_adopts_own_flag(self):
        status, _ = self.post("/api/mission/34/adopt", {"engine": "claude"})
        self.assertEqual(200, status)
        self.assertEqual(["--issue 34 --engine claude"], calls(self.argv))

    def test_taking_the_default_sends_NOTHING_and_the_argv_is_unchanged(self):
        """Doing nothing must reproduce today's behaviour exactly — including
        adopt.sh's own `note()` about a repo config that disagrees, which a
        gratuitous `--engine` would suppress."""
        status, _ = self.post("/api/mission/34/adopt")
        self.assertEqual(200, status)
        self.assertEqual(["--issue 34"], calls(self.argv))

    def test_an_engine_that_is_not_an_engine_name_is_refused_at_the_door(self):
        # It is one hop from being a command-line argument.
        for bad in ("--help", "claude; rm -rf /", "../../bin/sh", "a" * 80):
            status, _ = self.post("/api/mission/34/adopt", {"engine": bad})
            self.assertEqual(400, status, bad)
        self.assertEqual([], calls(self.argv))

    def test_the_REFUSAL_channel_is_untouched_by_the_new_flag(self):
        # adopt.sh's own `die()` banner must still map to 409, not 502.
        stub = _adopt_stub(self.tmp, "refuse.sh",
                           'printf "lcars adopt: nope\\n" >&2\nexit 1\n')
        actions = Actions(repo_root=self.tmp, scripts={"adopt": stub},
                          worker_bin="/bin/echo")
        adapter = board_of(self.tmp, [issue(34, stage="align")],
                           self.record, ("claude",))
        self.serve(adapter, actions)
        status, payload = self.post("/api/mission/34/adopt",
                                    {"engine": "claude"})
        self.assertEqual(409, status)
        self.assertEqual("nope", payload.get("error"))


# ==========================================================================
# 4. PROVENANCE — "A HUMAN CHOSE THIS", and the one thing this session could
#    not finish inside its own fence.
# ==========================================================================
class TheBoardsChoiceMustRecordAsCHOSEN(_Serve):
    """BLOCKED ON `skills/lcars-adopt/adopt.sh`, which is another
    implementor's file this session (read-only fence). Written now so the
    moment the flag lands, deleting one decorator is the whole of the proof.

    WHAT THE CARD SAYS TODAY, AND WHY IT IS THE WRONG STORY. adopt.sh records
    three provenances and board.js already renders all three
    (ENGINE_SOURCE_LABEL, board.js:2010):

        adopt-kept       "mission pin · kept at adopt"
        adopt-converted  "converted at adopt"
        adopt-chosen     "chosen at adopt"

    `adopt-chosen` is reachable from exactly ONE place — the ANSWERED PROMPT
    (adopt.sh:589) — and that prompt fires only on a tty, and only when the
    mission's engine is installed AND this repo's config.json disagrees with
    it. The `--engine` FLAG path (adopt.sh:570-575) records `adopt-kept` when
    the flag names the mission's own engine and `adopt-converted` otherwise.

    So the board, which can only speak to adopt.sh through `--engine`, will
    have a deliberate human choice written onto the card as a MECHANICAL
    CONVERSION. A captain who stood at the viewscreen, read that copilot is
    not on this laptop, and picked claude on purpose gets "converted at adopt"
    — the sentence LCARS uses for something nobody was asked about.

    THE ASK, exactly, and it is one flag and four lines:

        --engine-source chosen     (argv, beside the existing --engine)

      · a new `OPT_ENGINE_SRC` alongside `OPT_ENGINE` in the argv loop
        (adopt.sh:~274), accepting only the literal `chosen`;
      · in the `if [ -n "$OPT_ENGINE" ]` branch (adopt.sh:~567), after the
        existing `engine_here` check and the kept/converted decision:
            [ "$OPT_ENGINE_SRC" = "chosen" ] && ENGINE_SRC="adopt-chosen"
      · the readout's `adopt-chosen` case already prints the right sentence.

    IT RECORDS THE DISTINCTION RATHER THAN INFERRING IT, which is this round's
    standing rule (the producer records; nothing downstream re-derives). The
    alternative considered and REJECTED: driving adopt.sh's own prompt from
    the daemon with `LCARS_ASSUME_TTY=1` and the answer on stdin. It cannot
    work — on a two-CLI laptop with no config disagreement (the common case,
    and requirement 3 of this session) adopt.sh never prompts at all, so the
    captain's answer would be read by nobody and silently discarded. A
    silently dropped choice is worse than a mislabelled one.
    """

    REASON = ("BLOCKED: adopt.sh needs `--engine-source chosen`; that file "
              "belongs to the parallel implementor this session")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.record = os.path.join(self.tmp, "rec.txt")
        self.argv = os.path.join(self.tmp, "argv.txt")
        stub = _adopt_stub(self.tmp, "adopt.sh",
                           'printf "%s\\n" "$*" >> "' + self.argv + '"\\n'
                           'exit 0\\n')
        actions = Actions(repo_root=self.tmp, scripts={"adopt": stub},
                          worker_bin="/bin/echo")
        adapter = board_of(self.tmp,
                           [issue(34, stage="align", body=filed_on("copilot"))],
                           self.record, ("claude",))
        self.serve(adapter, actions)

    @unittest.skip(REASON)
    def test_the_boards_choice_travels_as_CHOSEN_not_as_a_conversion(self):
        self.post("/api/mission/34/adopt", {"engine": "claude"})
        self.assertEqual(["--issue 34 --engine claude --engine-source chosen"],
                         calls(self.argv))

    @unittest.skip(REASON)
    def test_taking_the_default_claims_no_human_choice(self):
        # He did not choose; he declined to. Nothing is asserted about him.
        self.post("/api/mission/34/adopt")
        self.assertEqual(["--issue 34"], calls(self.argv))

    def test_the_card_ALREADY_knows_how_to_say_chosen_at_adopt(self):
        """The rendering half is done and needs nothing: this is the guard
        that the label survives, so the flag landing is the only remaining
        step."""
        src = open(os.path.join(HERE, "..", "static", "board.js")).read()
        self.assertIn('"adopt-chosen":    "chosen at adopt"', src)
        self.assertIn('"adopt-converted": "converted at adopt"', src)


if __name__ == "__main__":
    unittest.main()
