"""S275 — every ⬡ engine picker offers only the CLIs this machine has.

THE DEFECT, in the captain's own words: install only Copilot, press
▦ FILE MISSION, and the console still offers you **Claude, preselected**. Pick
nothing, press the button, and you file a mission pinned to a CLI that is not
on your machine — `file.sh` persists it and `run.sh` dies at `require_worker`
a stage later. A fresh tester photographed the console on four real PATHs and
the picker's DOM was BYTE-IDENTICAL in all four: two `span.opt` nodes,
`⬡ Claude` carrying `sel` + `aria-pressed=true`, neither disabled, neither
titled.

Three pickers already did this right — the ◈ Number One picker
(board.js :1022-1058), the remote Adopt picker (:1849-1976) and the front door
(:4936-4964). This suite pins the treatment on the two that did not, and pins
it as THE SAME TREATMENT: `disabled`, the `locked` class (hollow + dashed,
wearing `⊘`), and the title "<Name> is not installed on this machine" —
the exact string :1038-1050 writes.

THREE STATES OF `meta.enginesHere`, NOT TWO, and the middle one is the one
that costs money if it is collapsed:
  * ABSENT  — nobody asked (an older daemon, the GitHub adapter, a detector
              that could not run). The console is EXACTLY as it was before
              this session: both options live, Claude preselected.
  * `[]`    — asked, and there is nothing here. Both options locked, both
              submits disabled with a sentence, and one band on the board.
  * a list  — offer what is on it, lock what is not.

WHAT THIS SUITE CANNOT SEE. It calls `render()` and `openFile()` itself in a
node vm against a mini-DOM, so — like every harness in web/tests — it cannot
tell a working board from a blank one, and it has NO CSS: an option that is
`locked` in the markup and indistinguishable from a live one in real Chrome
passes every assertion below. The browser half of the proof is a tester
driving real Chrome on the four real PATHs.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests.test_hotkeys import NODE, board, drive, keys  # noqa: E402

BANNER = ("No LCARS-capable CLI is installed on this machine — install "
          "Claude Code or the GitHub Copilot CLI to file, grill or run "
          "anything. You can still watch.")

NOT_HERE = " is not installed on this machine"


def meta(engines=None, deflt=None, **extra):
    """A board meta the way local_adapter builds it. `engines=None` leaves
    `enginesHere` ABSENT — which is a different fact from `[]`."""
    m = {"repo": "acme/repo", "adapter": "local", "mode": "read-write"}
    if engines is not None:
        m["enginesHere"] = list(engines)
    if deflt is not None:
        m["engineDefault"] = deflt
    m.update(extra)
    return m


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class PickerBase(unittest.TestCase):
    def console(self, engines=None, deflt=None, **spec):
        spec["board"] = board({}, meta=meta(engines, deflt))
        spec["openFile"] = True
        out = drive(spec)
        self.assertEqual(out["bootErrors"], [], "board.js failed to boot")
        self.assertEqual(out["runErrors"], [], "the run raised")
        return out

    def opt(self, out, engine):
        hits = [o for o in out["fileConsole"]["opts"]
                if engine in o["text"].lower()]
        self.assertEqual(len(hits), 1,
                         "one %s option, got %r"
                         % (engine, [o["text"] for o in
                                     out["fileConsole"]["opts"]]))
        return hits[0]

    def assertLocked(self, o, name):
        self.assertTrue(o["disabled"], "%s must be disabled: %r" % (name, o))
        self.assertIn("locked", o["cls"].split(),
                      "%s must wear the house lock class: %r" % (name, o))
        self.assertEqual(o["title"], name + NOT_HERE)
        self.assertIn("⊘", o["text"], "the lock glyph is the house glyph")
        self.assertNotIn("sel", o["cls"].split(),
                         "a CLI that is not here can never be the selection")

    def assertLive(self, o, name):
        self.assertFalse(o["disabled"], "%s must be pressable: %r" % (name, o))
        self.assertNotIn("locked", o["cls"].split())
        self.assertEqual(o["title"], "")
        self.assertEqual(o["role"], "button")
        self.assertEqual(o["tabindex"], "0")

    def selected(self, out):
        sel = [o["text"] for o in out["fileConsole"]["opts"]
               if "sel" in o["cls"].split()]
        self.assertEqual(len(sel), 1,
                         "exactly one option is selected, got %r" % (sel,))
        return sel[0].lower()


# ═══ B1 — the copilot-only laptop, which is the whole reason for this session ══

class CopilotOnlyLaptopTest(PickerBase):
    def test_copilot_is_preselected(self):
        out = self.console(["copilot"], "copilot")
        self.assertIn("copilot", self.selected(out))

    def test_the_claude_option_wears_the_house_lock(self):
        out = self.console(["copilot"], "copilot")
        self.assertLocked(self.opt(out, "claude"), "Claude")

    def test_the_copilot_option_is_live_and_keyboard_reachable(self):
        out = self.console(["copilot"], "copilot")
        self.assertLive(self.opt(out, "copilot"), "Copilot")

    def test_the_missing_engine_is_still_DRAWN(self):
        """Hidden would turn an explanation into a mystery (the Adopt picker's
        own ruling, :1804-1813). Both rows are always on screen."""
        out = self.console(["copilot"], "copilot")
        self.assertEqual(len(out["fileConsole"]["opts"]), 2)

    def test_filing_posts_copilot_without_the_captain_clicking_anything(self):
        """THE MONEY ASSERTION. The old console posted `engine: "claude"` here."""
        out = self.console(["copilot"], "copilot", submitFile="park")
        post = out["fileConsole"]["post"]
        self.assertEqual(post["url"], "/api/park")
        self.assertEqual(post["body"]["engine"], "copilot", post["body"])

    def test_the_claude_only_laptop_is_the_mirror_image(self):
        out = self.console(["claude"], "claude", submitFile="park")
        self.assertIn("claude", self.selected(out))
        self.assertLocked(self.opt(out, "copilot"), "Copilot")
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "claude")

    def test_a_default_this_machine_does_not_have_is_overruled(self):
        """A stale repo config can name an engine that was uninstalled. The
        INSTALLED list wins — the picker may never open on a dead CLI."""
        out = self.console(["copilot"], "claude", submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")


# ═══ B2 — both installed: nothing about today's console changes ══════════════

class BothInstalledTest(PickerBase):
    def test_both_options_are_live(self):
        out = self.console(["claude", "copilot"], "claude")
        self.assertLive(self.opt(out, "claude"), "Claude")
        self.assertLive(self.opt(out, "copilot"), "Copilot")

    def test_the_daemons_default_is_the_selection(self):
        for deflt in ("claude", "copilot"):
            out = self.console(["claude", "copilot"], deflt)
            self.assertIn(deflt, self.selected(out), deflt)

    def test_clicking_copilot_posts_copilot(self):
        out = self.console(["claude", "copilot"], "claude",
                           clickEngine="copilot", submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")

    def test_the_align_path_carries_the_pick_too(self):
        out = self.console(["claude", "copilot"], "claude",
                           clickEngine="copilot", submitFile="align")
        post = out["fileConsole"]["post"]
        self.assertEqual(post["url"], "/api/align/start")
        self.assertEqual(post["body"]["engine"], "copilot", post["body"])

    def test_both_submits_stay_live(self):
        out = self.console(["claude", "copilot"], "claude")
        self.assertFalse(out["fileConsole"]["submit"]["disabled"])
        self.assertFalse(out["fileConsole"]["align"]["disabled"])
        self.assertEqual(out["fileConsole"]["engineNote"], [])


# ═══ B3 — nothing installed: the board says so ONCE, and says why ════════════

class NoEngineAtAllTest(PickerBase):
    def test_both_options_are_locked(self):
        out = self.console([], None)
        self.assertLocked(self.opt(out, "claude"), "Claude")
        self.assertLocked(self.opt(out, "copilot"), "Copilot")

    def test_nothing_is_selected(self):
        out = self.console([], None)
        self.assertEqual([o["text"] for o in out["fileConsole"]["opts"]
                          if "sel" in o["cls"].split()], [])

    def test_both_submits_are_disabled(self):
        out = self.console([], None)
        self.assertTrue(out["fileConsole"]["submit"]["disabled"])
        self.assertTrue(out["fileConsole"]["align"]["disabled"])

    def test_the_console_says_why_rather_than_greying_out_in_silence(self):
        out = self.console([], None)
        self.assertEqual(len(out["fileConsole"]["engineNote"]), 1,
                         out["fileConsole"]["engineNote"])
        note = out["fileConsole"]["engineNote"][0]
        self.assertIn("Claude Code", note)
        self.assertIn("Copilot", note)

    def test_a_disabled_submit_cannot_file_anything(self):
        out = self.console([], None, submitFile="park")
        self.assertIsNone(out["fileConsole"]["post"],
                          "a locked console must open no write path")

    def test_the_board_shows_the_band(self):
        out = self.console([], None)
        self.assertFalse(out["engineBanner"]["hidden"])
        self.assertIn(BANNER, out["engineBanner"]["text"])

    def test_the_band_is_shown_exactly_once(self):
        """Not a boolean. render() runs on every SSE tick, and a host that is
        appended to rather than rebuilt stacks a band per tick."""
        out = self.console([], None)
        self.assertEqual(out["engineBanner"]["bands"], 1)

    def test_a_rerender_does_not_stack_a_second_band(self):
        brd = board({}, meta=meta([], None))
        out = drive({"board": brd, "keys": [{"rerender": True, "board": brd},
                                            {"rerender": True, "board": brd}]})
        self.assertEqual(out["runErrors"], [])
        self.assertEqual(out["engineBanner"]["bands"], 1)

    def test_an_engine_appearing_clears_the_band(self):
        """`lcars init` installs a CLI and the next SSE tick must take the band
        down with nothing to reload."""
        out = drive({"board": board({}, meta=meta([], None)),
                     "keys": [{"rerender": True,
                               "board": board({}, meta=meta(["copilot"],
                                                            "copilot"))}]})
        self.assertEqual(out["runErrors"], [])
        self.assertTrue(out["engineBanner"]["hidden"])
        self.assertEqual(out["engineBanner"]["bands"], 0)

    def test_an_installed_engine_shows_no_band_at_all(self):
        out = self.console(["copilot"], "copilot")
        self.assertTrue(out["engineBanner"]["hidden"])
        self.assertEqual(out["engineBanner"]["bands"], 0)

    def test_the_band_can_be_dismissed_for_this_session(self):
        out = drive({"board": board({}, meta=meta([], None)),
                     "keys": [{"click": "#engineBanner .vb-x"},
                              {"rerender": True,
                               "board": board({}, meta=meta([], None))}]})
        self.assertEqual(out["runErrors"], [])
        self.assertTrue(out["engineBanner"]["hidden"])


# ═══ A DAEMON THAT NEVER ANSWERED — byte-identical to the old console ════════

class NobodyAskedTest(PickerBase):
    """`enginesHere` ABSENT is "I could not ask", which is not "it is not
    here" (the ◈ picker's own words, :973-977). An older daemon, the GitHub
    adapter and a detector that could not run all land here, and all three
    must get the console exactly as it was before S275."""

    def test_both_options_are_offered_live(self):
        out = self.console(None, None)
        self.assertLive(self.opt(out, "claude"), "Claude")
        self.assertLive(self.opt(out, "copilot"), "Copilot")

    def test_claude_is_still_the_preselection(self):
        out = self.console(None, None)
        self.assertEqual([o["text"] for o in out["fileConsole"]["opts"]],
                         ["⬡ Claude", "⬡ Copilot"])
        self.assertIn("claude", self.selected(out))

    def test_it_posts_claude_as_it_always_did(self):
        out = self.console(None, None, submitFile="park")
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "claude")

    def test_no_band_is_shown(self):
        out = self.console(None, None)
        self.assertTrue(out["engineBanner"]["hidden"])

    def test_a_told_default_is_honoured_even_with_no_installed_list(self):
        out = self.console(None, "copilot", submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")


# ═══ B6 — the keyboard must not reach a CLI that is not there ════════════════

class LockedOptionIsNotActivableTest(PickerBase):
    """:1038-1050's rows are real `<button disabled>`, which the browser skips
    natively. These are `span`s, so the guarantee has to be built: no
    keyActivable wiring at all, and the click handler is not there to be
    reached either."""

    def test_the_locked_option_is_not_a_tab_stop(self):
        out = self.console(["copilot"], "copilot")
        dead = self.opt(out, "claude")
        self.assertIsNone(dead["tabindex"])
        self.assertIsNone(dead["role"])

    def test_enter_does_not_select_the_locked_option(self):
        out = self.console(["copilot"], "copilot", keyEngine="claude",
                           keyEngineKey="Enter", submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")

    def test_space_does_not_select_the_locked_option(self):
        out = self.console(["copilot"], "copilot", keyEngine="claude",
                           keyEngineKey=" ", submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")

    def test_a_mouse_click_on_the_locked_option_does_nothing(self):
        out = self.console(["copilot"], "copilot", clickEngine="claude",
                           submitFile="park")
        self.assertIn("copilot", self.selected(out))
        self.assertEqual(out["fileConsole"]["post"]["body"]["engine"], "copilot")

    def test_the_locked_option_opens_no_write_path(self):
        out = self.console([], None, clickEngine="claude")
        self.assertEqual([f for f in out["fetches"] if f["method"] == "POST"],
                         [])


# ═══ ONE HELPER, NOT FIVE PICKERS ════════════════════════════════════════════

class OnePickerImplementationTest(unittest.TestCase):
    """The treatment is extracted so a sixth picker cannot be written without
    it. Pinned as SOURCE, which is the only place "there is one of these"
    can be asserted — a DOM projection cannot see a duplicated branch."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(HERE, "..", "static", "board.js")) as fh:
            cls.js = fh.read()

    def test_the_helper_exists(self):
        self.assertIn("function engineOptions(", self.js)

    def test_the_file_console_uses_it(self):
        self.assertIn("engineOptions(choice,", self.js)

    def test_new_program_uses_it(self):
        self.assertIn("engineOptions(echoice,", self.js)

    def test_neither_console_hardcodes_the_pair_any_more(self):
        """`⬡ Claude` is BUILT from engineLabel now. A literal in either
        console is the defect written back in."""
        self.assertNotIn('el("span", "opt", "⬡ Claude")', self.js)
        self.assertNotIn('el("span", "opt", "⬡ Copilot")', self.js)

    def test_the_title_is_the_same_string_the_xo_picker_writes(self):
        self.assertEqual(
            self.js.count('" is not installed on this machine"'), 3,
            "the XO picker, the Adopt picker and the shared helper — one "
            "string each, and no fourth copy")


# ═══ THE LOCK HAS TO BE VISIBLE, NOT JUST TRUE IN THE MARKUP ════════════════

class LockedOptionStyleTest(unittest.TestCase):
    """`.btn.locked` is a `.btn` rule and these options are `span.opt`, so a
    `locked` class in the markup with no rule behind it is a locked option
    that looks EXACTLY like a live one in Chrome. This pins the rule and pins
    that it mints no colour (ADR-007) — it cannot tell you what painted, which
    is the browser leg's job."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(HERE, "..", "static", "board.css")) as fh:
            cls.css = fh.read()

    def rule(self, selector):
        """The DECLARATION BLOCK, anchored at the start of a line — board.css
        documents itself heavily and quotes its own selectors inside comments
        (`.btn.locked{opacity:1}` is written out three times in prose), so an
        unanchored search reads a comment and reports a rule."""
        import re
        m = re.search(r"(?m)^" + re.escape(selector) + r"\s*\{([^}]*)\}",
                      self.css)
        self.assertIsNotNone(m, "%s has no rule in board.css" % selector)
        return m.group(1)

    def test_the_locked_option_is_hollow_and_dashed(self):
        body = self.rule(".choice .opt.locked")
        self.assertIn("background:transparent", body)
        self.assertIn("border-style:dashed", body)

    def test_it_borrows_the_blue_btn_locked_already_uses(self):
        self.assertIn("--lcars-blue", self.rule(".choice .opt.locked"))
        self.assertIn("--lcars-blue", self.rule(".btn.locked"))

    def test_nothing_dims_it(self):
        """S190's D2, from a fifth direction: an `opacity` makes a compositing
        group and out-specifies `.btn.locked{opacity:1}`."""
        self.assertNotIn("opacity", self.rule(".choice .opt.locked"))

    def test_it_mints_no_colour(self):
        import re
        for selector in (".choice .opt.locked", ".field .engine-none"):
            bad = [h for h in re.findall(r"#[0-9a-fA-F]{3,8}",
                                         self.rule(selector))
                   if h.lower() != "#4499ff"]
            self.assertEqual([], bad,
                             "%s minted a raw colour: %s" % (selector, bad))

    def test_the_console_sentence_has_a_rule_too(self):
        self.assertIn("--lcars-text-dim", self.rule(".field .engine-none"))

    def test_the_sentence_modifier_is_typography_only(self):
        """`vb-sentence` must add no colour — it exists so a whole sentence is
        not rendered in the band's three-word display-font uppercase."""
        import re
        for sel in (".version-banner .vb-band.vb-sentence",
                    ".version-banner .vb-band.vb-sentence .vb-msg"):
            body = self.rule(sel)
            self.assertEqual([], re.findall(r"#[0-9a-fA-F]{3,8}", body), sel)
            for word in ("background", "color:", "border"):
                self.assertNotIn(word, body, "%s touches %s" % (sel, word))

    def test_the_banner_reuses_the_version_banner_host(self):
        """No new banner idiom and no new palette — the band is a
        `.version-banner` > `.vb-band`, which the sheet already styles."""
        with open(os.path.join(HERE, "..", "static", "index.html")) as fh:
            html = fh.read()
        self.assertIn('class="version-banner" id="engineBanner"', html)
        self.assertIn(".version-banner .vb-band{", self.css)


if __name__ == "__main__":
    unittest.main()


# ════════════════════════════════════════════════════════════════════════════
# S275 FIX ROUND 1 — THE TWO PICKERS THAT STILL COLLAPSED `[]` INTO ABSENT
#
# A fresh tester, on a laptop with NEITHER CLI, pressed ◈ NUMBER ONE and got
# `◆ Copilot` and `◈ Claude` both fully styled and enabled — no "not
# installed", no title, nothing locked — with Copilot preselected; then pressed
# ◈ ENGAGE and the board POSTed `/api/xo/on {"engine":"copilot"}` to a machine
# with no copilot on it. One line did that:
#
#     var dead = xoEnginesHere(meta).length && !xoEngineHere(meta, engine);
#
# With `enginesHere: []`, `.length` is `0`, so `dead` is falsy for EVERY engine.
# The `.length &&` guard was written to mean "if nobody answered, grey nothing
# out" — which is right — but `xoEnginesHere` normalises absent AND `[]` to the
# same `[]`, so the information it needed was already gone. `[]` is an ANSWER
# meaning "none installed"; absent is "nobody asked".
#
# On the same laptop the day-one front door's ▸ ESTABLISH VISION was enabled,
# untitled, asked no engine question at all, and POSTed `/api/align/start`
# with no `engine` key — the same collapse, one surface along.
#
# `enginesAnswered` / `noEngineHere` (board.js, beside `xoEnginesHere`) are the
# predicate that tells the two apart, reading the RAW field before any
# normalisation. The classes below are written in the same three-states shape
# as NobodyAskedTest / NoEngineAtAllTest above, because it is the same contract.
# ════════════════════════════════════════════════════════════════════════════
import json          # noqa: E402
import subprocess    # noqa: E402
import tempfile      # noqa: E402

XO_HARNESS = os.path.join(HERE, "board_xo_harness.js")
FD_HARNESS = os.path.join(HERE, "board_frontdoor_harness.js")

# `ENGINE_NONE_NOTE` verbatim — the one sentence every console shows instead of
# greying a control out in silence. Restated rather than imported for the same
# reason BANNER is: a test that reads the string out of the file it is checking
# cannot notice the string changing.
NOTE = ("No LCARS-capable CLI is installed on this machine, so nothing can "
        "drive this — install Claude Code or the GitHub Copilot CLI and this "
        "console unlocks itself.")


def _spec(harness, payload):
    fd, p = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        with open(p, "w") as fh:
            json.dump(payload, fh)
        out = subprocess.check_output([NODE, harness, p], timeout=60)
    finally:
        os.unlink(p)
    return json.loads(out.decode())


def _band(meta, **spec):
    """The ◈ NUMBER ONE band + picker, through the REAL openXoPicker."""
    spec["meta"] = meta
    spec.setdefault("readonly", False)
    spec.setdefault("click", None)
    return _spec(XO_HARNESS, spec)


def _off(engines=None, **spec):
    """A repo with Number One OFF — the state whose band click opens the
    picker. `engines=None` leaves `enginesHere` ABSENT."""
    meta = {"repo": "acme/repo", "adapter": "local", "numberOne":
            {"enabled": False}}
    if engines is not None:
        meta["enginesHere"] = list(engines)
    return _band(meta, **spec)


def _door(engines=None, **spec):
    """The day-zero greenfield front door, through the REAL render()."""
    meta = {"adapter": "local", "foundation": "greenfield",
            "frontDoor": {"foundation": "greenfield", "stack": "unknown",
                          "stackLabel": "not recognised", "sourceFiles": 0,
                          "testRunner": None, "engines": [], "engine": ""}}
    if engines is not None:
        meta["enginesHere"] = list(engines)
        meta["frontDoor"]["engines"] = list(engines)
        meta["frontDoor"]["engine"] = engines[0] if engines else ""
    spec["board"] = {"stages": [], "columns": {}, "missions": [], "meta": meta}
    spec.setdefault("readonly", False)
    return _spec(FD_HARNESS, spec)


def _flat(node, out=None):
    if out is None:
        out = []
    if node:
        out.append(node)
        for c in node.get("children", []):
            _flat(c, out)
    return out


# ═══ D1 — the ◈ NUMBER ONE picker on a laptop with NEITHER CLI ══════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class NumberOnePickerOnANakedLaptopTest(unittest.TestCase):
    """`enginesHere: []` — the detector ANSWERED, and the answer is none."""

    def rows(self, out):
        return {r["engine"]: r for r in out["picker"]["rows"]}

    def test_every_row_is_locked(self):
        rows = self.rows(_off([], click="toggle"))
        self.assertEqual(sorted(rows), ["claude", "copilot"])
        for name, r in rows.items():
            self.assertTrue(r["disabled"], "%s must be disabled: %r" % (name, r))
            self.assertIn("locked", r["cls"].split(),
                          "%s must wear the house lock class: %r" % (name, r))

    def test_every_row_says_which_cli_is_missing(self):
        rows = self.rows(_off([], click="toggle"))
        self.assertEqual(rows["copilot"]["title"], "Copilot" + NOT_HERE)
        self.assertEqual(rows["claude"]["title"], "Claude" + NOT_HERE)
        for r in rows.values():
            self.assertIn("not installed", r["text"])
            self.assertIn("⊘", r["text"], "the lock glyph is the house glyph")

    def test_no_row_is_preselected(self):
        """Copilot sat preselected on this exact screen. A CLI that is not
        here can never be the selection."""
        out = _off([], click="toggle")
        self.assertEqual("", out["picker"]["chosen"])
        for r in out["picker"]["rows"]:
            self.assertNotIn("chosen", r["cls"].split())
            self.assertNotEqual("true", r["ariaPressed"])

    def test_engage_is_disabled_and_says_why(self):
        foot = {b["text"]: b for b in _off([], click="toggle")["picker"]
                ["footState"]}
        self.assertIn("◈ Engage", foot)
        self.assertTrue(foot["◈ Engage"]["disabled"])
        self.assertEqual(foot["◈ Engage"]["title"], NOTE)

    def test_engage_posts_nothing(self):
        """THE DEFECT ITSELF: one press POSTed `{"engine":"copilot"}` to a
        machine with no copilot. The attribute is a DOM promise; this is the
        refusal that holds when something reaches the handler anyway."""
        self.assertEqual([], _off([], click="engage")["posts"])

    def test_the_picker_says_why_in_its_own_prose(self):
        """Not a silent grey-out — the File console's rule, applied here."""
        self.assertIn(NOTE, _off([], click="toggle")["picker"]["notes"])

    def test_cancel_is_untouched(self):
        foot = {b["text"]: b for b in _off([], click="toggle")["picker"]
                ["footState"]}
        self.assertFalse(foot["Cancel"]["disabled"])
        self.assertEqual("", foot["Cancel"]["title"])


# ═══ D1b — and the lock has to SURVIVE paint() ══════════════════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheLockedRowSurvivesARepaintTest(unittest.TestCase):
    """`openXoPicker`'s paint() rewrites every row's `className` wholesale, so
    it DROPPED the `locked` class `markLocked` had just written — and paint()
    runs once immediately after the rows are built, so the lock was wiped
    before the picker reached the screen, and again on every later click. No
    existing test covered a repainted row; these two do."""

    def row(self, out, engine):
        hits = [r for r in out["picker"]["rows"] if r["engine"] == engine]
        self.assertEqual(1, len(hits), out["picker"]["rows"])
        return hits[0]

    def test_the_open_repaint_does_not_wipe_the_lock(self):
        """paint() on open is a full repaint of every row."""
        dead = self.row(_off([], click="toggle"), "claude")
        self.assertIn("locked", dead["cls"].split())
        self.assertEqual(dead["title"], "Claude" + NOT_HERE)

    def test_clicking_a_live_row_does_not_wipe_the_dead_ones_lock(self):
        """The copilot-only laptop: pressing ◈ Copilot repaints, and ◈ Claude
        must still be locked afterwards."""
        out = _off(["copilot"], click="toggle", clickRow="copilot")
        self.assertEqual("copilot", out["picker"]["chosen"],
                         "the click must still select the live row")
        dead = self.row(out, "claude")
        self.assertTrue(dead["disabled"])
        self.assertIn("locked", dead["cls"].split())
        self.assertEqual(dead["title"], "Claude" + NOT_HERE)
        self.assertIn("not installed", dead["text"])


# ═══ D1c — and a board that was told NOTHING is unchanged ═══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class NumberOnePickerWhenNobodyAskedTest(unittest.TestCase):
    """`enginesHere` ABSENT — an older daemon, the GitHub adapter, a detector
    that could not run. "I could not ask" is not "it is not here", so this
    picker must behave EXACTLY as it did before this fix."""

    def test_no_row_is_locked(self):
        out = _off(None, click="toggle")
        for r in out["picker"]["rows"]:
            self.assertFalse(r["disabled"], r)
            self.assertNotIn("locked", r["cls"].split())
            self.assertEqual("", r["title"])

    def test_engage_is_live_and_posts_the_default(self):
        out = _off(None, click="toggle")
        foot = {b["text"]: b for b in out["picker"]["footState"]}
        self.assertFalse(foot["◈ Engage"]["disabled"])
        self.assertEqual("", foot["◈ Engage"]["title"])
        self.assertEqual([["/api/xo/on", {"engine": "copilot"}]],
                         _off(None, click="engage")["posts"])

    def test_the_picker_adds_no_note(self):
        self.assertNotIn(NOTE, _off(None, click="toggle")["picker"]["notes"])


# ═══ D2 — the day-one front door on the same naked laptop ═══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class FrontDoorOnANakedLaptopTest(unittest.TestCase):
    """▸ ESTABLISH VISION was enabled, untitled, offered no engine question,
    and POSTed `/api/align/start {"idea":…,"vision":true}` with no `engine`
    key — on a machine with nothing to run it on.

    The door asks `meta.enginesHere`, NOT `fd.engines`: the daemon builds the
    front-door block with `blk.get("engines") or []`, so `fd.engines` is `[]`
    both when nothing is installed and when the helper predates S195. The
    distinction only survives on `enginesHere`."""

    def primary(self, out):
        hits = [n for n in _flat(out["frontDoor"])
                if n["tag"] == "button" and "Establish" in (n["text"] or "")]
        self.assertEqual(1, len(hits), "one ▸ ESTABLISH VISION")
        return hits[0]

    def posts(self, out):
        return [f for f in out["fetches"] if f["method"] == "POST"
                and "/api/align/" in f["url"]]

    def test_establish_vision_is_disabled(self):
        self.assertTrue(self.primary(_door([]))["disabled"])

    def test_it_says_why_on_the_control(self):
        self.assertEqual(NOTE, self.primary(_door([]))["title"])

    def test_it_says_why_on_the_screen_too(self):
        texts = [n["text"] for n in _flat(_door([])["frontDoor"])]
        self.assertIn(NOTE, texts,
                      "a door whose button is dead says why, on the door")

    def test_pressing_it_posts_nothing(self):
        out = _door([], act="submit", text="a personal finance site")
        self.assertEqual([], self.posts(out))

    def test_it_offers_no_engine_to_pick(self):
        opts = [n for n in _flat(_door([])["frontDoor"])
                if "opt" in (n["cls"] or "").split()]
        self.assertEqual([], opts, "there is nothing to offer")


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class FrontDoorWhenNobodyAskedTest(FrontDoorOnANakedLaptopTest):
    """The same door with `enginesHere` ABSENT — unchanged by this fix, which
    is what `test_no_engine_installed_offers_nothing_and_posts_nothing` in
    test_front_door.py pins from the other side."""

    def test_establish_vision_is_disabled(self):
        self.assertFalse(self.primary(_door(None))["disabled"])

    def test_it_says_why_on_the_control(self):
        self.assertEqual("", self.primary(_door(None))["title"])

    def test_it_says_why_on_the_screen_too(self):
        texts = [n["text"] for n in _flat(_door(None)["frontDoor"])]
        self.assertNotIn(NOTE, texts)

    def test_pressing_it_posts_nothing(self):
        out = _door(None, act="submit", text="a personal finance site")
        self.assertEqual(1, len(self.posts(out)),
                         "a door told nothing still files, as it always did")
        self.assertEqual("/api/align/start", self.posts(out)[0]["url"])

    def test_it_offers_no_engine_to_pick(self):
        opts = [n for n in _flat(_door(None)["frontDoor"])
                if "opt" in (n["cls"] or "").split()]
        self.assertEqual([], opts,
                         "`fd.engines` is empty here too — nothing to offer, "
                         "and no claim that nothing is installed")
