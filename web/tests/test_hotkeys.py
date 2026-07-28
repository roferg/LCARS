"""S140 — the keyboard command deck: focus nav + action keys.

The viewscreen was mouse-only (ONE keydown listener: Escape-closes-overlay). This
round makes the board drivable from the keyboard:

  * cards are focusable (role=button, tabindex=0, data-mid);
  * the EXISTING card controls carry a machine-readable `data-act` identity;
  * ONE exported binding table (KEY_BINDINGS — S141 renders the cheatsheet FROM
    it) registers ↑↓←→ / Enter / s p v l / f d ?;
  * four non-negotiable guards: typing-target, overlay-open (except ?), modifier
    (Ctrl/Cmd/Alt pass to the browser), and e.repeat.

The critical safety property is that a hotkey NEVER opens a new write path — it
resolves the focused card, querySelectors the real control, and `.click()`s it.
A missing or DISABLED control is therefore a silent no-op, which is exactly the
view-only guarantee. Every test below drives the SHIPPING web/static/board.js in
a node vm against a mini-DOM (no jsdom, no build step — ADR-007) and asserts on
what was clicked and what was POSTed.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_hotkeys_harness.js")
NODE = shutil.which("node")

STAGES = ["align", "research", "validate", "plan", "plan-review", "schedule",
          "implement", "verify", "done"]


def mission(mid, stage="align", **kw):
    m = {"id": mid, "title": "Mission " + mid, "issue": 100, "stage": stage}
    m.update(kw)
    return m


def board(columns, meta=None):
    cols = {k: [] for k in STAGES}
    cols.update(columns)
    missions = [m for v in cols.values() for m in v]
    return {"columns": cols, "missions": missions,
            "meta": meta if meta is not None else
            {"repo": "acme/repo", "adapter": "local", "mode": "read-write"}}


def drive(spec):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(spec, fh)
    try:
        out = subprocess.check_output([NODE, HARNESS, path],
                                      stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def keys(*ks):
    """'s' → {"key": "s"}; a dict passes through unchanged."""
    return [k if isinstance(k, dict) else {"key": k} for k in ks]


class HotkeyBase(unittest.TestCase):
    def run_board(self, brd, **spec):
        spec["board"] = brd
        out = drive(spec)
        self.assertEqual(out["bootErrors"], [], "board.js failed to boot")
        self.assertEqual(out["runErrors"], [], "the run raised")
        return out

    def cards_of(self, out, stage):
        idx = STAGES.index(stage)
        return out["columns"][idx]["cards"]

    def acts(self, out, stage, i=0):
        return {a["act"]: a for a in self.cards_of(out, stage)[i]["acts"]}


# ══════════════════ 1. the focus model + the data-act identity ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class FocusModelTest(HotkeyBase):
    """Cards render focusable and every write control carries a data-act."""

    def test_cards_are_focusable_with_data_mid(self):
        out = self.run_board(board({"align": [mission("m-001")],
                                    "verify": [mission("m-002", stage="verify")]}))
        for stage in ("align", "verify"):
            card = self.cards_of(out, stage)[0]
            self.assertEqual(card["role"], "button",
                             "a card must be an ARIA button to be a focus target")
            self.assertEqual(card["tabindex"], "0",
                             "a card must be in the tab order")
            self.assertTrue(card["mid"], "a card must carry data-mid")

    def test_start_control_carries_data_act_start(self):
        out = self.run_board(board({"align": [mission("m-001")]}))
        acts = self.acts(out, "align")
        self.assertIn("start", acts)
        self.assertIn("Start", acts["start"]["text"])

    def test_pause_control_carries_data_act_pause(self):
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", running=True)]}))
        self.assertIn("pause", self.acts(out, "implement"))

    def test_resume_control_carries_data_act_resume(self):
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", paused=True)]}))
        self.assertIn("resume", self.acts(out, "implement"))

    def test_verify_control_carries_data_act_verify(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify", prUrl="https://x/pull/1",
                    prNumber=1)]}))
        acts = self.acts(out, "verify")
        self.assertIn("verify", acts)
        self.assertIn("Review PR", acts["verify"]["text"])

    def test_app_live_stop_carries_data_act_launch_stop(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify",
                    launch={"status": "running", "url": "http://x"})]}))
        self.assertIn("launch-stop", self.acts(out, "verify"))

    def test_awaiting_answer_control_carries_data_act_answer(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify", awaiting=True)]}))
        self.assertIn("answer", self.acts(out, "verify"))

    def test_reapprove_gate_carries_data_act_reapprove(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify", awaiting=True,
                    reconcileStatus="awaiting-reapprove")]}))
        self.assertIn("reapprove", self.acts(out, "verify"))

    def test_merge_failed_gate_carries_data_act_retry_merge(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify", awaiting=True,
                    reconcileStatus="merge-failed")]}))
        self.assertIn("retry-merge", self.acts(out, "verify"))

    def test_parked_start_alignment_is_the_cards_start_control(self):
        """A PARKED card's start-shaped control is ▹ START ALIGNMENT — `s` must
        drive it, so it carries data-act=start like every other start slot."""
        out = self.run_board(board({"align": [
            mission("m-001", prdPending=True)]}))
        acts = self.acts(out, "align")
        self.assertIn("start", acts)
        self.assertIn("ALIGNMENT", acts["start"]["text"].upper())

    def test_queued_card_start_slot_is_disabled_not_absent(self):
        """A queued card shows a DISABLED ◷ Queued… in the start slot. Tagging it
        (rather than leaving it untagged) is what makes `s` a provable no-op."""
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", queued=True)]}))
        acts = self.acts(out, "implement")
        self.assertIn("start", acts)
        self.assertTrue(acts["start"]["disabled"])

    def test_render_diff_is_attribute_only(self):
        """The S140 change adds role/tabindex/data-act and NOTHING else: the
        structural projection (tag / class / text / disabled) of a plain align
        card is exactly what it was before this round."""
        out = self.run_board(board({"align": [mission("m-001")]}))
        self.assertEqual(out["cardStructure"], {
            "tag": "div", "cls": "card", "text": "", "disabled": False,
            "children": [
                {"tag": "div", "cls": "no", "text": "#100 · lcars:align",
                 "disabled": False, "children": []},
                {"tag": "div", "cls": "ttl", "text": "Mission m-001",
                 "disabled": False, "children": []},
                {"tag": "div", "cls": "pills", "text": "",
                 "disabled": False, "children": []},
                {"tag": "div", "cls": "card-ctrl", "text": "", "disabled": False,
                 "children": [
                     {"tag": "button", "cls": "btn go", "text": "▶ Start",
                      "disabled": False, "children": []},
                 ]},
            ],
        })


# ══════════════════ 2. the binding table ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class BindingTableTest(HotkeyBase):
    """ONE exported, iterable structure — S141 renders the cheatsheet from it."""

    def test_binding_table_is_exported_and_iterable(self):
        out = self.run_board(board({}))
        self.assertIsNotNone(out["bindings"],
                             "KEY_BINDINGS must be an exported array")
        self.assertTrue(out["bindings"])

    def test_every_binding_has_human_readable_keycaps_and_label(self):
        out = self.run_board(board({}))
        for b in out["bindings"]:
            self.assertTrue(b["id"], "each binding needs a stable id")
            self.assertTrue(b["keys"] and isinstance(b["keys"], list),
                            "each binding needs a keycap list for the cheatsheet")
            self.assertTrue(b["label"] and b["label"][0].isupper(),
                            "each binding needs a human-readable label")

    def test_the_documented_key_set_is_present(self):
        out = self.run_board(board({}))
        caps = set()
        for b in out["bindings"]:
            caps.update(b["keys"])
        for cap in ["?", "f", "d", "↑", "↓", "←", "→", "Enter", "s", "p", "v",
                    "l", "Esc"]:
            self.assertIn(cap, caps, "binding table is missing " + cap)


# ══════════════════ 3. navigation ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class NavigationTest(HotkeyBase):

    def three_col_board(self):
        # align: 3 cards | research: EMPTY | validate: 1 card
        return board({
            "align": [mission("a1"), mission("a2"), mission("a3")],
            "validate": [mission("v1", stage="validate")],
        })

    def test_first_arrow_grabs_the_first_card(self):
        out = self.run_board(self.three_col_board(), keys=keys("ArrowDown"))
        self.assertEqual(out["focusedMid"], "a1")

    def test_down_moves_to_the_next_card_in_column(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=keys("ArrowDown"))
        self.assertEqual(out["focusedMid"], "a2")

    def test_up_moves_to_the_previous_card_in_column(self):
        out = self.run_board(self.three_col_board(), focus="a3",
                             keys=keys("ArrowUp"))
        self.assertEqual(out["focusedMid"], "a2")

    def test_down_is_clamped_at_the_bottom(self):
        out = self.run_board(self.three_col_board(), focus="a3",
                             keys=keys("ArrowDown", "ArrowDown"))
        self.assertEqual(out["focusedMid"], "a3")

    def test_up_is_clamped_at_the_top(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=keys("ArrowUp", "ArrowUp"))
        self.assertEqual(out["focusedMid"], "a1")

    def test_right_skips_the_empty_column(self):
        """align → (research EMPTY) → validate: one ArrowRight must land on v1."""
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=keys("ArrowRight"))
        self.assertEqual(out["focusedMid"], "v1")

    def test_left_skips_the_empty_column(self):
        out = self.run_board(self.three_col_board(), focus="v1",
                             keys=keys("ArrowLeft"))
        self.assertEqual(out["focusedMid"], "a1")

    def test_right_lands_on_the_nearest_card_when_the_target_is_shorter(self):
        """From the 3rd card of a 3-card column into a 1-card column → clamp."""
        out = self.run_board(self.three_col_board(), focus="a3",
                             keys=keys("ArrowRight"))
        self.assertEqual(out["focusedMid"], "v1")

    def test_right_at_the_last_non_empty_column_is_a_no_op(self):
        out = self.run_board(self.three_col_board(), focus="v1",
                             keys=keys("ArrowRight"))
        self.assertEqual(out["focusedMid"], "v1")

    def test_nav_walks_dom_columns_not_hardcoded_stage_names(self):
        """Only two columns hold cards; nav must find them by walking the RENDERED
        column containers (the multi-repo board inherits this)."""
        out = self.run_board(
            board({"implement": [mission("i1", stage="implement")],
                   "done": [mission("d1", stage="done")]}),
            focus="i1", keys=keys("ArrowRight"))
        self.assertEqual(out["focusedMid"], "d1")

    def test_focus_survives_a_re_render(self):
        brd = self.three_col_board()
        out = self.run_board(brd, focus="a2",
                             keys=[{"rerender": True, "board": brd}])
        self.assertEqual(out["focusedMid"], "a2",
                         "a board rebuild must restore focus by data-mid")

    def test_focus_is_not_restored_when_the_card_is_gone(self):
        brd = self.three_col_board()
        gone = board({"align": [mission("a1"), mission("a3")],
                      "validate": [mission("v1", stage="validate")]})
        out = self.run_board(brd, focus="a2",
                             keys=[{"rerender": True, "board": gone}])
        self.assertIsNone(out["focusedMid"])

    def test_enter_opens_the_focused_cards_detail(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=keys("Enter"))
        self.assertTrue(any("/api/mission/a1" in f["url"] for f in out["fetches"]),
                        "Enter must open the focused card's detail")

    def test_enter_with_nothing_focused_does_nothing(self):
        out = self.run_board(self.three_col_board(), keys=keys("Enter"))
        self.assertEqual(out["fetches"], [])


# ══════════════════ 4. action dispatch ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class DispatchTest(HotkeyBase):

    def test_s_clicks_the_focused_cards_start_control(self):
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", keys=keys("s"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["start"])
        self.assertTrue(out["clicks"][0]["fired"])

    def test_s_acts_on_the_FOCUSED_card_only(self):
        out = self.run_board(
            board({"align": [mission("m-001"), mission("m-002")]}),
            focus="m-002", keys=keys("s"))
        self.assertEqual([c["mid"] for c in out["clicks"]], ["m-002"])

    def test_s_on_a_card_with_no_start_control_does_nothing(self):
        """A done card has no inline control at all."""
        out = self.run_board(board({"done": [mission("m-001", stage="done")]}),
                             focus="m-001", keys=keys("s"))
        self.assertEqual(out["clicks"], [])
        self.assertEqual(out["fetches"], [])

    def test_p_pauses_a_running_card(self):
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", running=True)]}),
            focus="m-001", keys=keys("p"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["pause"])
        self.assertTrue(any("/pause" in f["url"] for f in out["fetches"]))

    def test_p_resumes_a_paused_card(self):
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", paused=True)]}),
            focus="m-001", keys=keys("p"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["resume"])
        self.assertTrue(any("/resume" in f["url"] for f in out["fetches"]))

    def test_v_opens_verify_on_a_gate_card(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify", prUrl="https://x/pull/1",
                    prNumber=1)]}),
            focus="m-001", keys=keys("v"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["verify"])
        self.assertTrue(any("/api/mission/m-001" in f["url"]
                            for f in out["fetches"]))

    def test_v_on_a_non_verify_card_does_nothing(self):
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", keys=keys("v"))
        self.assertEqual(out["clicks"], [])

    def test_l_stops_a_live_app_from_the_card(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify",
                    launch={"status": "running", "url": "http://x"})]}),
            focus="m-001", keys=keys("l"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["launch-stop"])
        self.assertTrue(any("/launch/stop" in f["url"] for f in out["fetches"]))

    def test_l_with_no_launch_control_does_nothing(self):
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify")]}),
            focus="m-001", keys=keys("l"))
        self.assertEqual(out["clicks"], [])

    def test_dispatch_works_when_an_inner_control_holds_focus(self):
        """Focus lands on a button after a mouse click; the card must still
        resolve via activeElement.closest('[data-mid]')."""
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", focusChildAct="start", keys=keys("s"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["start"])

    def test_hotkey_click_does_not_also_open_the_detail(self):
        """The control's own handler stopPropagation()s, so the synthetic click
        must NOT bubble to the card's click-to-open."""
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", running=True)]}),
            focus="m-001", keys=keys("p"))
        self.assertFalse(any(f["url"].endswith("/api/mission/m-001")
                             for f in out["fetches"]),
                         "the hotkey click leaked through to openDetail")

    # ── the no-bypass proof ────────────────────────────────────────────────────
    def test_read_only_board_start_hotkey_changes_nothing(self):
        """applyWriteState disabled the button on a view-only build. `s` clicks
        the SAME element, so a real DOM dispatches nothing → zero POSTs. There is
        no second code path for a hotkey to take."""
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", readonly=True, keys=keys("s"))
        self.assertEqual(len(out["clicks"]), 1)
        self.assertTrue(out["clicks"][0]["disabled"],
                        "the view-only build must have disabled the control")
        self.assertFalse(out["clicks"][0]["fired"])
        self.assertEqual(out["fetches"], [],
                         "a hotkey on a view-only board must POST nothing")

    def test_read_only_board_pause_hotkey_changes_nothing(self):
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", running=True)]}),
            focus="m-001", readonly=True, keys=keys("p"))
        self.assertEqual(out["fetches"], [])

    def test_disabled_queued_start_hotkey_changes_nothing(self):
        """Not just view-only: any disabled affordance (here the queued card's
        ◷ Queued…) is inert under the hotkey exactly as under the mouse."""
        out = self.run_board(board({"implement": [
            mission("m-001", stage="implement", queued=True)]}),
            focus="m-001", keys=keys("s"))
        self.assertEqual(len(out["clicks"]), 1)
        self.assertFalse(out["clicks"][0]["fired"])
        self.assertEqual(out["fetches"], [])


# ══════════════════ 5. global consoles ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class GlobalKeyTest(HotkeyBase):

    def test_f_opens_the_file_mission_console(self):
        out = self.run_board(board({}), keys=keys("f"))
        self.assertTrue(out["overlayHiddenBefore"])
        self.assertFalse(out["overlayHidden"], "f must open the File console")
        self.assertEqual([c["cls"] for c in out["clicks"]], ["btn go"])

    def test_d_opens_the_deploy_main_console(self):
        out = self.run_board(board({}), keys=keys("d"))
        self.assertFalse(out["overlayHidden"], "d must open the Deploy Main modal")

    def test_question_mark_is_bound(self):
        """S141 renders the real console; this session only proves ? is wired and
        harmless (it must not throw and must not open a write path)."""
        out = self.run_board(board({}), keys=keys("?"))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["runErrors"], [])


# ══════════════════ 6. the four guards ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class GuardTest(HotkeyBase):

    def one_card(self):
        return board({"align": [mission("m-001")]})

    # guard 1 — typing target
    def test_letter_typed_in_a_textarea_fires_nothing(self):
        out = self.run_board(self.one_card(), focusTextarea=True,
                             keys=keys("s", "p", "v", "l", "f", "d", "?"))
        self.assertEqual(out["clicks"], [])
        self.assertEqual(out["fetches"], [])
        self.assertTrue(out["overlayHidden"])

    def test_letter_typed_in_an_input_fires_nothing(self):
        out = self.run_board(self.one_card(), focusInput=True, keys=keys("f"))
        self.assertTrue(out["overlayHidden"])

    def test_letter_typed_in_a_contenteditable_fires_nothing(self):
        out = self.run_board(self.one_card(), focusContentEditable=True,
                             keys=keys("f"))
        self.assertTrue(out["overlayHidden"])

    def test_arrows_in_a_textarea_do_not_move_card_focus(self):
        out = self.run_board(
            board({"align": [mission("a1"), mission("a2")]}),
            focusTextarea=True, keys=keys("ArrowDown"))
        self.assertEqual(out["focusedTag"], "TEXTAREA")

    # guard 2 — overlay open
    def test_action_letters_do_nothing_while_an_overlay_is_open(self):
        out = self.run_board(self.one_card(), focus="m-001", openOverlay=True,
                             keys=keys("s", "p", "v", "l", "d", "f",
                                       "ArrowDown", "Enter"))
        self.assertEqual(out["clicks"], [])
        self.assertEqual(out["fetches"], [])

    def test_question_mark_is_the_sanctioned_overlay_exception(self):
        out = self.run_board(self.one_card(), openOverlay=True, keys=keys("?"))
        self.assertEqual(out["runErrors"], [],
                         "? must still be handled with an overlay open")

    def test_escape_semantics_are_unchanged(self):
        """Esc closes the overlay through the EXISTING listener — the new layer
        must not double-handle it (one close, no throw)."""
        out = self.run_board(self.one_card(), openOverlay=True, keys=keys("Escape"))
        self.assertFalse(out["overlayHiddenBefore"])
        self.assertTrue(out["overlayHidden"])
        self.assertEqual(out["runErrors"], [])

    # guard 3 — modifiers pass to the browser
    def test_cmd_s_is_left_to_the_browser(self):
        out = self.run_board(self.one_card(), focus="m-001",
                             keys=[{"key": "s", "metaKey": True}])
        self.assertEqual(out["clicks"], [])

    def test_ctrl_and_alt_letters_are_left_to_the_browser(self):
        for mod in ("ctrlKey", "altKey"):
            out = self.run_board(self.one_card(), focus="m-001",
                                 keys=[{"key": "s", mod: True}])
            self.assertEqual(out["clicks"], [], mod + " must pass through")

    def test_modified_arrows_are_left_to_the_browser(self):
        out = self.run_board(board({"align": [mission("a1"), mission("a2")]}),
                             focus="a1", keys=[{"key": "ArrowDown", "metaKey": True}])
        self.assertEqual(out["focusedMid"], "a1")

    def test_shift_is_not_a_bail_modifier(self):
        """`?` is Shift+/ on most layouts — shift must never bail."""
        out = self.run_board(self.one_card(),
                             keys=[{"key": "?", "shiftKey": True}])
        self.assertEqual(out["runErrors"], [])

    # guard 4 — key auto-repeat
    def test_a_held_key_fires_exactly_once(self):
        out = self.run_board(self.one_card(), focus="m-001",
                             keys=[{"key": "s"}, {"key": "s", "repeat": True},
                                   {"key": "s", "repeat": True},
                                   {"key": "s", "repeat": True}])
        self.assertEqual(len(out["clicks"]), 1,
                         "a held key must not fire a stream of actions")

    def test_a_held_arrow_does_not_run_the_focus_away(self):
        out = self.run_board(
            board({"align": [mission("a1"), mission("a2"), mission("a3")]}),
            focus="a1", keys=[{"key": "ArrowDown"},
                              {"key": "ArrowDown", "repeat": True},
                              {"key": "ArrowDown", "repeat": True}])
        self.assertEqual(out["focusedMid"], "a2")


# ══════════════════ 7. degenerate boards ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class EmptyBoardTest(HotkeyBase):

    def test_every_key_on_a_board_with_zero_cards_is_safe(self):
        out = self.run_board(board({}), keys=keys(
            "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Enter",
            "s", "p", "v", "l", "?", "Escape", "z"))
        self.assertEqual(out["runErrors"], [])
        self.assertEqual(out["clicks"], [])
        self.assertIsNone(out["focusedMid"])

    def test_single_card_column_nav_is_safe(self):
        out = self.run_board(board({"align": [mission("only")]}), focus="only",
                             keys=keys("ArrowUp", "ArrowDown", "ArrowLeft",
                                       "ArrowRight"))
        self.assertEqual(out["focusedMid"], "only")
        self.assertEqual(out["runErrors"], [])

    def test_unbound_letters_are_ignored(self):
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", keys=keys("q", "z", "1", "Tab"))
        self.assertEqual(out["clicks"], [])
        self.assertEqual(out["fetches"], [])


# ══════════════════ 8. the focus ring ══════════════════

class FocusRingTest(unittest.TestCase):
    """A focus target you cannot see is a defect. The ring must be LCARS amber,
    keyboard-only (:focus-visible), and shift no layout."""

    LAYOUT_PROPS = ("width", "height", "padding", "margin", "border-width",
                    "border-left", "border-right", "top", "left", "position",
                    "transform", "font-size")

    def setUp(self):
        with open(os.path.join(HERE, "..", "static", "board.css")) as fh:
            self.css = fh.read()

    def rule(self):
        i = self.css.index(".card:focus-visible")
        return self.css[self.css.index("{", i) + 1:self.css.index("}", i)]

    def test_a_focus_visible_ring_exists(self):
        self.assertIn(".card:focus-visible", self.css,
                      "cards must show a keyboard focus ring")

    def test_the_ring_is_lcars_amber(self):
        self.assertIn("var(--lcars-amber)", self.rule())

    def test_the_ring_is_an_outline_not_a_border(self):
        """outline is painted outside the box model — it cannot move anything."""
        self.assertIn("outline:", self.rule())

    def test_the_ring_shifts_no_layout(self):
        body = self.rule()
        for prop in self.LAYOUT_PROPS:
            self.assertNotIn(prop + ":", body,
                             "the focus ring must not set " + prop)

    # ── DEFECT 4: the comment above the ring must describe the REAL cascade ──

    def comment(self):
        """The explanatory block comment immediately above .card:focus-visible,
        whitespace-collapsed so a wrapped sentence still reads as one."""
        i = self.css.index(".card:focus-visible")
        start = self.css.rindex("/*", 0, i)
        return re.sub(r"\s+", " ", self.css[start:self.css.index("*/", start)])

    def test_the_running_pulse_really_does_animate_box_shadow(self):
        """The premise of the fix: .card.running runs a keyframe animation over
        box-shadow, and a CSS animation beats a normal declaration — so the focus
        rule's box-shadow CANNOT win on a running card, at any specificity."""
        i = self.css.index("@keyframes card-running")
        frames = self.css[i:self.css.index("}\n", self.css.index("{", i))]
        self.assertIn("box-shadow", frames)
        self.assertIn("animation:card-running", self.css)

    def test_the_focus_ring_comment_does_not_claim_the_shadow_wins(self):
        """It used to say the rule 'wins at equal specificity' — false for a
        running card, where the pulse animation overrides the box-shadow."""
        self.assertNotIn("wins at equal specificity", self.comment())

    def test_the_focus_ring_comment_names_the_running_pulse_caveat(self):
        """Honest instead: outline is what carries the ring in every state, and
        the comment must say so and name the animation that beats the shadow."""
        c = self.comment().lower()
        self.assertIn("animation", c,
                      "the comment must name the pulse animation that wins")
        self.assertIn("outline", c,
                      "the comment must state that outline carries the ring")

    # ── DEFECT 3: the console's span-as-controls get the same ring ──

    def test_span_controls_have_the_same_focus_visible_ring(self):
        for sel in (".choice .opt:focus-visible", ".img-chip-x:focus-visible"):
            self.assertIn(sel, self.css,
                          sel + " — a keyboard-reachable control must show focus")
            i = self.css.index(sel)
            rule = self.css[self.css.index("{", i) + 1:self.css.index("}", i)]
            self.assertIn("outline:", rule)
            self.assertIn("var(--lcars-amber)", rule)


# ══════════════ 9. DEFECT 1 — the binding table may not advertise fiction ═════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class BindingHonestyTest(HotkeyBase):
    """S141 renders the cheatsheet VERBATIM from this table, so an entry that
    names an action no card can render, or a label promising something the key
    cannot do, ships as a lie in the help console."""

    def every_control_the_board_can_render(self):
        """Every data-act that appears on a BOARD CARD across the full spread of
        card states. clickCardAct only ever searches inside the focused card, so
        this set is exactly what a card-scoped binding can reach."""
        brd = board({
            "align": [mission("a1"),                       # ▶ Start
                      mission("a2", prdPending=True)],     # ▹ START ALIGNMENT
            "implement": [mission("i1", stage="implement", running=True),
                          mission("i2", stage="implement", paused=True),
                          mission("i3", stage="implement", queued=True)],
            "verify": [
                mission("v1", stage="verify", prUrl="https://x/pull/1",
                        prNumber=1),
                mission("v2", stage="verify",
                        launch={"status": "running", "url": "http://x"}),
                mission("v3", stage="verify", awaiting=True),
                mission("v4", stage="verify", awaiting=True,
                        reconcileStatus="awaiting-reapprove"),
                mission("v5", stage="verify", awaiting=True,
                        reconcileStatus="merge-failed"),
            ],
        })
        out = self.run_board(brd)
        found = set()
        for col in out["columns"]:
            for card in col["cards"]:
                for a in card["acts"]:
                    found.add(a["act"])
        return out, found

    def test_the_fixture_spread_really_does_cover_the_card_controls(self):
        """Guard on the guard: if this spread stopped rendering controls the
        reachability test below would pass vacuously."""
        _, found = self.every_control_the_board_can_render()
        for act in ("start", "pause", "resume", "verify", "launch-stop",
                    "answer", "reapprove", "retry-merge"):
            self.assertIn(act, found, "fixture spread lost the " + act + " control")

    def test_no_binding_declares_an_action_no_card_can_render(self):
        """`launch` (the ⚡ RUN control) is built ONLY inside launchAffordance,
        which is appended into OVERLAY bodies — never onto a card. A card-scoped
        binding naming it is unreachable code with a user-facing label."""
        out, found = self.every_control_the_board_can_render()
        for b in out["bindings"]:
            for act in (b["acts"] or []):
                self.assertIn(act, found,
                              "binding '" + b["id"] + "' names data-act='" + act
                              + "', which no board card renders")

    def test_the_l_binding_only_stands_an_app_down(self):
        out = self.run_board(board({}))
        b = [x for x in out["bindings"] if "l" in x["on"]][0]
        self.assertEqual(b["acts"], ["launch-stop"])

    def test_the_l_label_does_not_promise_starting_an_app(self):
        """The overlay guard blocks `l` inside the detail where ⚡ RUN lives, and
        no card carries it — so the label must not offer to run anything."""
        out = self.run_board(board({}))
        label = [x for x in out["bindings"] if "l" in x["on"]][0]["label"]
        for word in ("run", "start", "launch"):
            self.assertIsNone(
                re.search(r"\b" + word + r"\b", label, re.I),
                "the l label must not promise to " + word + " an app: " + label)

    def test_the_l_label_still_describes_the_stand_down(self):
        out = self.run_board(board({}))
        label = [x for x in out["bindings"] if "l" in x["on"]][0]["label"]
        self.assertRegex(label.lower(), r"stand down|stop")

    def test_l_still_stops_a_live_app(self):
        """The behaviour is unchanged — only the advertised words are."""
        out = self.run_board(board({"verify": [
            mission("m-001", stage="verify",
                    launch={"status": "running", "url": "http://x"})]}),
            focus="m-001", keys=keys("l"))
        self.assertEqual([c["act"] for c in out["clicks"]], ["launch-stop"])


# ═══ 10. DEFECT 2 — role=button owes Space as well as Enter (WAI-ARIA) ═══════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class SpaceActivationTest(HotkeyBase):
    """A widget that announces role=button must activate on BOTH Enter and Space
    (WAI-ARIA button pattern). Space was a dead key on a focused card: no detail,
    and no page scroll either."""

    def three_col_board(self):
        return board({
            "align": [mission("a1"), mission("a2")],
            "validate": [mission("v1", stage="validate")],
        })

    def test_the_open_binding_advertises_space(self):
        out = self.run_board(board({}))
        b = [x for x in out["bindings"] if x["id"] == "open"][0]
        self.assertIn(" ", b["on"], "Space must trigger the open binding")
        self.assertIn("Space", b["keys"], "the cheatsheet must print the Space cap")
        self.assertIn("Enter", b["keys"])

    def test_space_opens_the_focused_cards_detail(self):
        out = self.run_board(self.three_col_board(), focus="a1", keys=keys(" "))
        self.assertTrue(any("/api/mission/a1" in f["url"] for f in out["fetches"]),
                        "Space must open the focused card, like Enter")

    def test_space_on_a_card_swallows_the_page_scroll(self):
        out = self.run_board(self.three_col_board(), focus="a1", keys=keys(" "))
        self.assertEqual(out["prevented"], [True],
                         "activating a card must not ALSO scroll the page")

    def test_space_with_nothing_focused_is_left_to_the_browser(self):
        """No card focused ⇒ Space is the page-scroll key it has always been."""
        out = self.run_board(self.three_col_board(), keys=keys(" "))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["prevented"], [False],
                         "Space must still scroll when focus is off the board")

    def test_space_in_a_textarea_still_types_a_space(self):
        out = self.run_board(self.three_col_board(), focusTextarea=True,
                             keys=keys(" "))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["clicks"], [])
        self.assertEqual(out["prevented"], [False],
                         "the typing guard must leave the space character alone")

    def test_space_in_an_input_still_types_a_space(self):
        out = self.run_board(self.three_col_board(), focusInput=True,
                             keys=keys(" "))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["prevented"], [False])

    def test_space_in_a_contenteditable_still_types_a_space(self):
        out = self.run_board(self.three_col_board(), focusContentEditable=True,
                             keys=keys(" "))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["prevented"], [False])

    def test_space_on_a_focused_button_belongs_to_the_button(self):
        """A real BUTTON activates itself on Space — we must not open the detail
        behind it, and must not swallow the key."""
        out = self.run_board(board({"align": [mission("m-001")]}),
                             focus="m-001", focusChildAct="start", keys=keys(" "))
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["prevented"], [False])

    def test_space_does_nothing_while_a_console_is_open(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             openOverlay=True, keys=keys(" "))
        self.assertEqual(out["fetches"], [])

    def test_held_space_fires_exactly_once(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=[{"key": " "}, {"key": " ", "repeat": True},
                                   {"key": " ", "repeat": True}])
        self.assertEqual(len([f for f in out["fetches"]
                              if "/api/mission/a1" in f["url"]]), 1)

    def test_cmd_space_is_left_to_the_os(self):
        out = self.run_board(self.three_col_board(), focus="a1",
                             keys=[{"key": " ", "metaKey": True}])
        self.assertEqual(out["fetches"], [])
        self.assertEqual(out["prevented"], [False])

    def test_space_on_an_empty_board_is_safe(self):
        out = self.run_board(board({}), keys=keys(" "))
        self.assertEqual(out["runErrors"], [])
        self.assertEqual(out["fetches"], [])


# ═══ 11. DEFECT 3 — the File console must be drivable without a mouse ════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class FileConsoleKeyboardTest(HotkeyBase):
    """The round's DONE WHEN is a board fully drivable by keyboard. The File
    console's ⬡ Claude / ⬡ Copilot picker (and the pasted-image ✕) are <span>s:
    unfocusable, so Copilot could not be chosen without a mouse."""

    def open_console(self, **spec):
        spec["openFile"] = True
        return self.run_board(board({}), **spec)

    def test_the_engine_picker_renders_both_options(self):
        out = self.open_console()
        self.assertEqual([o["text"] for o in out["fileConsole"]["opts"]],
                         ["⬡ Claude", "⬡ Copilot"])

    def test_the_engine_options_are_in_the_tab_order(self):
        for o in self.open_console()["fileConsole"]["opts"]:
            self.assertEqual(o["tabindex"], "0", o["text"] + " must be tabbable")

    def test_the_engine_options_announce_themselves_as_buttons(self):
        for o in self.open_console()["fileConsole"]["opts"]:
            self.assertEqual(o["role"], "button")

    def test_the_engine_options_expose_their_selected_state(self):
        opts = self.open_console()["fileConsole"]["opts"]
        self.assertEqual(opts[0]["ariaPressed"], "true", "Claude is the default")
        self.assertEqual(opts[1]["ariaPressed"], "false")

    def test_enter_selects_copilot(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys("Enter"))
        opts = out["fileConsole"]["opts"]
        self.assertIn("sel", opts[1]["cls"], "Enter must pick ⬡ Copilot")
        self.assertNotIn("sel", opts[0]["cls"])
        self.assertEqual(opts[1]["ariaPressed"], "true")

    def test_space_selects_copilot(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys(" "))
        self.assertIn("sel", out["fileConsole"]["opts"][1]["cls"])

    def test_selecting_an_engine_opens_no_write_path(self):
        """Picking is local state only — the same as clicking it. No endpoint."""
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys("Enter"))
        self.assertEqual(out["fetches"], [])

    def test_the_pick_key_does_not_also_reach_the_command_deck(self):
        """Enter on the picker must not fall through to the card-open binding."""
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys("Enter"))
        self.assertEqual([c["cls"] for c in out["clicks"]], ["opt"])

    def test_an_unbound_letter_on_the_picker_does_nothing(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys("x"))
        self.assertEqual(out["clicks"], [])
        self.assertNotIn("sel", out["fileConsole"]["opts"][1]["cls"])

    def test_a_modified_enter_on_the_picker_is_left_to_the_browser(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=[{"key": "Enter", "metaKey": True}])
        self.assertEqual(out["clicks"], [])

    def test_escape_still_closes_the_console_from_the_picker(self):
        """The picker consumes Enter/Space ONLY — Esc keeps bubbling to the
        pre-existing overlay listener."""
        out = self.open_console(focusSelector=".choice .opt", focusIndex=1,
                                keys=keys("Escape"))
        self.assertTrue(out["overlayHidden"])

    # ── the sibling span-as-control in the same console: the ✕ image chip ──

    def test_a_pasted_image_chip_renders_a_remove_control(self):
        out = self.open_console(pasteImage=True)
        self.assertEqual(out["fileConsole"]["chips"], 1)
        self.assertEqual(len(out["fileConsole"]["chipRemoves"]), 1)

    def test_the_image_remove_control_is_keyboard_reachable(self):
        x = self.open_console(pasteImage=True)["fileConsole"]["chipRemoves"][0]
        self.assertEqual(x["tabindex"], "0")
        self.assertEqual(x["role"], "button")

    def test_enter_removes_a_pasted_image_chip(self):
        out = self.open_console(pasteImage=True, focusSelector=".img-chip-x",
                                keys=keys("Enter"))
        self.assertEqual(out["fileConsole"]["chips"], 0)

    def test_space_removes_a_pasted_image_chip(self):
        out = self.open_console(pasteImage=True, focusSelector=".img-chip-x",
                                keys=keys(" "))
        self.assertEqual(out["fileConsole"]["chips"], 0)


# ═══ 12. DEFECT 3 (folded in) — the Align grill's answer options ═════════════

ALIGN_STATE = {
    "sessionId": "s-1",
    "status": "asking",
    "question": {"text": "Which dialect should the mission speak?",
                 "choices": ["Alpha", "Beta", "Gamma"],
                 "recommended": "Beta"},
    "prd": "**Goal:** ship the thing",
}


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class AlignConsoleKeyboardTest(HotkeyBase):
    """The Align grill is ONE SCREEN on from the File console's "File & Begin
    Alignment" — a captain filing a mission from the keyboard walks straight into
    it. Its answer options are the same `.choice .opt` span-as-control idiom the
    engine picker uses, so they get the same treatment."""

    def open_console(self, **spec):
        spec["openAlign"] = ALIGN_STATE
        return self.run_board(board({}), **spec)

    def opts(self, out):
        return out["alignConsole"]["opts"]

    def test_the_answer_options_render(self):
        self.assertEqual([o["text"] for o in self.opts(self.open_console())],
                         ["Alpha", "Beta", "Gamma"])

    def test_the_answer_options_are_in_the_tab_order(self):
        for o in self.opts(self.open_console()):
            self.assertEqual(o["tabindex"], "0", o["text"] + " must be tabbable")

    def test_the_answer_options_announce_themselves_as_buttons(self):
        for o in self.opts(self.open_console()):
            self.assertEqual(o["role"], "button")

    def test_the_recommended_option_starts_selected(self):
        o = self.opts(self.open_console())
        self.assertIn("sel", o[1]["cls"], "the REC option is pre-picked")
        self.assertEqual([x["ariaPressed"] for x in o],
                         ["false", "true", "false"])

    def test_enter_selects_an_answer_option(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys("Enter"))
        o = self.opts(out)
        self.assertIn("sel", o[2]["cls"], "Enter must pick the focused answer")
        self.assertNotIn("sel", o[1]["cls"], "the old pick must clear")
        self.assertEqual([x["ariaPressed"] for x in o],
                         ["false", "false", "true"])

    def test_space_selects_an_answer_option(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys(" "))
        self.assertIn("sel", self.opts(out)[2]["cls"])

    def test_selecting_an_answer_opens_no_write_path(self):
        """Picking is local until Submit — exactly as clicking it has always
        been. No endpoint, no POST."""
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys("Enter"))
        self.assertEqual(out["fetches"], [])

    def test_the_pick_key_does_not_also_reach_the_command_deck(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys("Enter"))
        self.assertEqual([c["cls"] for c in out["clicks"]], ["opt"])

    def test_escape_still_closes_the_console_from_an_option(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys("Escape"))
        self.assertTrue(out["overlayHidden"])

    def test_an_unbound_letter_on_an_option_does_nothing(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=keys("x"))
        self.assertEqual(out["clicks"], [])
        self.assertNotIn("sel", self.opts(out)[2]["cls"])

    def test_a_modified_enter_on_an_option_is_left_to_the_browser(self):
        out = self.open_console(focusSelector=".choice .opt", focusIndex=2,
                                keys=[{"key": "Enter", "metaKey": True}])
        self.assertEqual(out["clicks"], [])

    def test_a_free_form_answer_clears_every_options_pressed_state(self):
        """The free-form box overrides any pick, so the announced state must go
        with it — an aria-pressed left true would tell a screen reader the
        overridden option is still the answer."""
        out = self.open_console(typeFree="my own words")
        for o in self.opts(out):
            self.assertNotIn("sel", o["cls"])
            self.assertEqual(o["ariaPressed"], "false")


if __name__ == "__main__":
    unittest.main()
