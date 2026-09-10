"""S196 B5 — FILTER THE BOARD BY OWNERSHIP.

Until this session there was no way to ask the board a question. A captain
running two laptops sees his own work, the other laptop's work, whatever GitHub
has assigned to somebody else and whatever is unassigned, all in one wall of
cards, and the only way to find "the three that are actually mine" was to read
every card.

FOUR FACETS, AND NOT ONE NEW NOTION OF IDENTITY. Half A of this session existed
to make ONE key mean ONE fact; a filter that invented a fifth answer to "whose
is this?" would undo it. So every facet is a question the board can already
answer off the payload it already has:

    mine        card.owner.login === meta.self.login
    theirs      ownerLockLogin(m) — the EXACT predicate the light lock is
                built on, so a card the board will not let you drive and a card
                the filter calls "someone else's" can never disagree
    unassigned  no owner at all — ownership.sh's own "empty is unowned, not an
                error", the state that is NEVER locked
    remote      card.remote — a CARD CLASS, not an owner. A remote mission can
                be assigned to me, to somebody else, or to nobody, so this is a
                SECOND AXIS and the facets are deliberately not exclusive.

Because they are not exclusive the strip is a SET of toggles, ORed: a card shows
if it matches any selected facet. Nothing selected means nothing is filtered.

THE FOUR PROPERTIES THIS FILE PINS, in order of how badly they would hurt:

  1. IT COSTS NO FORGE ROUND TRIP. S152's constraint on the remote overlay is
     one cached listing per CYCLE, never per render; S191 measured the whole
     board at exactly one `gh` invocation across 25 GETs. A filter that
     re-fetched would spend a forge call per keystroke. Filtering happens on the
     board the page ALREADY holds, and the proof is that the page issues ZERO
     fetches while every filter is applied. (The pixel drive proves the other
     half — that `gh` itself never moves. A count of fetches from inside the
     harness cannot see a subprocess.)
  2. AN IDENTITY-FREE BOARD IS UNCHANGED. The S190 posture, unbroken: with no
     `meta.self` the board cannot say what "mine" means, so it does not offer
     it — and a `mine` remembered from a machine that DID have an identity must
     never blank the board. Every uncertain case shows MORE, never less.
  3. THE COUNTS AGREE. A chip that says 3 and a board that renders 2 is worse
     than no count at all, and so is a column head that keeps counting cards it
     is no longer drawing.
  4. IT SURVIVES A REFRESH, and it does not fight the keyboard.

Everything here drives the SHIPPING web/static/board.js through render() in a
node vm against the mini-DOM (ADR-007, no jsdom, no build step). What it CANNOT
see is whether the strip is legible on screen — that is
tests/drives/s190/owner-paint.sh, in real Chrome, off pixels.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_hotkeys_harness.js")
NODE = shutil.which("node")

STAGES = ["align", "research", "validate", "plan", "plan-review", "schedule",
          "implement", "verify", "done"]

ME = "roferg"
OTHER = "picard"
FILTER_KEY = "lcars-owner-filter"


def mission(mid, stage="align", **kw):
    m = {"id": mid, "title": "Mission " + mid, "issue": 100, "stage": stage}
    m.update(kw)
    return m


def mine(mid, **kw):
    return mission(mid, owner={"login": ME}, **kw)


def theirs(mid, **kw):
    return mission(mid, owner={"login": OTHER}, **kw)


def nobodys(mid, **kw):
    return mission(mid, **kw)


def remote(mid, owner=None, **kw):
    kw["remote"] = True
    if owner:
        kw["owner"] = {"login": owner}
    return mission(mid, **kw)


def board(columns, self_login=ME):
    cols = {k: [] for k in STAGES}
    cols.update(columns)
    missions = [m for v in cols.values() for m in v]
    meta = {"repo": "acme/repo", "adapter": "local", "mode": "read-write"}
    if self_login:
        meta["self"] = {"login": self_login}
    return {"columns": cols, "missions": missions, "meta": meta}


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


# The board every test below reasons about unless it says otherwise: two of
# mine, one of theirs, one unassigned, and two remote — one of which is ALSO
# assigned to me, which is the overlap the facets have to survive.
def mixed_board(self_login=ME):
    return board({
        "align": [mine("m1"), theirs("t1"), nobodys("u1")],
        "verify": [mine("m2"), remote("r1"), remote("r2", owner=ME)],
    }, self_login=self_login)


class FilterBase(unittest.TestCase):
    def run_board(self, brd, **spec):
        spec["board"] = brd
        out = drive(spec)
        self.assertEqual(out["bootErrors"], [], "board.js failed to boot")
        self.assertEqual(out["runErrors"], [], "the run raised")
        return out

    def chips(self, out):
        return {c["id"]: c for c in out["ownerFilter"]["chips"]}

    def rendered(self, out):
        """Every mission id the board actually DREW, across every column."""
        ids = []
        for col in out["columns"]:
            ids += [c["mid"] for c in col["cards"]]
        return ids

    def click(self, fid):
        return {"click": '#ownerFilter button[data-filter="%s"]' % fid}


# ══════════════════ 1. the strip itself ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class TheStripTest(FilterBase):

    def test_a_mixed_board_offers_the_strip(self):
        out = self.run_board(mixed_board())
        self.assertFalse(out["ownerFilter"]["hidden"],
                         "a board with four kinds of ownership on it must "
                         "offer a way to ask about them")

    def test_it_offers_one_chip_per_facet_present_plus_all(self):
        c = self.chips(self.run_board(mixed_board()))
        self.assertEqual(sorted(c), sorted(["all", "mine", "theirs",
                                            "remote", "unassigned"]))

    def test_a_facet_with_no_cards_is_not_offered(self):
        """B3's ruling, applied to this strip: a control that can only ever
        empty the board is a dead control, and this board draws none."""
        c = self.chips(self.run_board(board({"align": [mine("m1"), mine("m2")]})))
        self.assertNotIn("theirs", c)
        self.assertNotIn("remote", c)
        self.assertNotIn("unassigned", c)

    def test_a_board_with_only_one_kind_of_card_offers_no_strip(self):
        """Nothing to ask ⇒ nothing to ask WITH. A strip whose every chip
        selects the whole board is furniture."""
        out = self.run_board(board({"align": [mine("m1"), mine("m2")]}))
        self.assertTrue(out["ownerFilter"]["hidden"])
        self.assertEqual(out["ownerFilter"]["chips"], [])

    def test_an_empty_board_offers_no_strip(self):
        out = self.run_board(board({}))
        self.assertTrue(out["ownerFilter"]["hidden"])

    def test_all_is_the_selected_chip_on_a_fresh_board(self):
        c = self.chips(self.run_board(mixed_board()))
        self.assertEqual(c["all"]["pressed"], "true")
        for fid in ("mine", "theirs", "unassigned", "remote"):
            self.assertEqual(c[fid]["pressed"], "false")

    def test_every_chip_says_what_it_would_do(self):
        for chip in self.run_board(mixed_board())["ownerFilter"]["chips"]:
            self.assertTrue(chip["title"],
                            "chip %r explains itself to nobody" % chip["id"])

    def test_no_chip_is_a_write_control(self):
        """A view-only board still gets to ask questions — the same exemption
        the ? console has. `.btn.go` is what markViewOnly disables."""
        for chip in self.run_board(mixed_board(), readonly=True)["ownerFilter"]["chips"]:
            self.assertNotIn("go", chip["cls"].split())
            self.assertFalse(chip["disabled"],
                             "filtering is a READ; a view-only board must "
                             "still be able to do it")


# ══════════════════ 2. each filter selects the right cards ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class SelectionTest(FilterBase):

    def select(self, fid, brd=None):
        out = self.run_board(brd or mixed_board(), keys=[self.click(fid)])
        return sorted(self.rendered(out))

    def test_unfiltered_draws_everything(self):
        self.assertEqual(self.select("all"),
                         ["m1", "m2", "r1", "r2", "t1", "u1"])

    def test_mine_draws_the_cards_assigned_to_me(self):
        """r2 is REMOTE and assigned to me — remote is a second axis, not a
        fifth owner, so it is mine as well."""
        self.assertEqual(self.select("mine"), ["m1", "m2", "r2"])

    def test_theirs_draws_only_somebody_elses(self):
        self.assertEqual(self.select("theirs"), ["t1"])

    def test_unassigned_draws_only_the_ownerless(self):
        """r1 is remote AND has no assignee, so it is unassigned too."""
        self.assertEqual(self.select("unassigned"), ["r1", "u1"])

    def test_remote_draws_only_the_cards_driven_elsewhere(self):
        self.assertEqual(self.select("remote"), ["r1", "r2"])

    def test_two_facets_are_ORed_never_ANDed(self):
        """They overlap by construction, so AND would routinely draw nothing."""
        out = self.run_board(mixed_board(),
                             keys=[self.click("theirs"), self.click("unassigned")])
        self.assertEqual(sorted(self.rendered(out)), ["r1", "t1", "u1"])

    def test_clicking_a_selected_facet_again_releases_it(self):
        out = self.run_board(mixed_board(),
                             keys=[self.click("mine"), self.click("mine")])
        self.assertEqual(sorted(self.rendered(out)),
                         ["m1", "m2", "r1", "r2", "t1", "u1"])

    def test_all_clears_every_facet(self):
        out = self.run_board(mixed_board(),
                             keys=[self.click("mine"), self.click("remote"),
                                   self.click("all")])
        self.assertEqual(sorted(self.rendered(out)),
                         ["m1", "m2", "r1", "r2", "t1", "u1"])
        self.assertEqual(self.chips(out)["all"]["pressed"], "true")

    def test_the_filter_survives_a_re_render(self):
        """An SSE tick rebuilds the whole board; the question the captain asked
        is not a thing a tick gets to answer differently."""
        brd = mixed_board()
        out = self.run_board(brd, keys=[self.click("mine"),
                                        {"rerender": True, "board": brd}])
        self.assertEqual(sorted(self.rendered(out)), ["m1", "m2", "r2"])


# ══════════════════ 3. the counts agree ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class CountsAgreeTest(FilterBase):

    def test_each_chip_counts_exactly_what_selecting_it_draws(self):
        base = self.chips(self.run_board(mixed_board()))
        for fid in ("all", "mine", "theirs", "unassigned", "remote"):
            out = self.run_board(mixed_board(), keys=[self.click(fid)])
            self.assertEqual(int(base[fid]["count"]), len(self.rendered(out)),
                             "chip %r says %s and the board draws %d"
                             % (fid, base[fid]["count"], len(self.rendered(out))))

    def test_the_chip_prints_its_count_where_a_human_can_read_it(self):
        c = self.chips(self.run_board(mixed_board()))
        self.assertIn("3", c["mine"]["text"])
        self.assertIn("1", c["theirs"]["text"])

    def test_a_column_head_counts_the_cards_it_actually_draws(self):
        out = self.run_board(mixed_board(), keys=[self.click("mine")])
        for col in out["columns"]:
            head = col["head"]
            drawn = len(col["cards"])
            self.assertTrue(head.endswith(str(drawn)),
                            "column head %r draws %d card(s)" % (head, drawn))

    def test_an_unfiltered_column_head_is_unchanged(self):
        out = self.run_board(mixed_board())
        heads = [c["head"] for c in out["columns"]]
        self.assertEqual(heads[STAGES.index("align")][-1], "3")
        self.assertEqual(heads[STAGES.index("verify")][-1], "3")

    def test_the_status_line_says_it_is_filtered(self):
        """The routine line describes the board. A filtered board that claims
        `6 active missions` while drawing 3 is the board lying about itself."""
        out = self.run_board(mixed_board(), keys=[self.click("mine")])
        self.assertIn("filtered", out["status"].lower())
        self.assertIn("3", out["status"])
        self.assertIn("6", out["status"])

    def test_an_unfiltered_status_line_is_byte_identical_to_before(self):
        out = self.run_board(mixed_board())
        self.assertEqual(out["status"], "6 active missions")


# ══════════════════ 4. it survives a refresh ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class PersistenceTest(FilterBase):

    def test_a_choice_is_written_to_storage(self):
        out = self.run_board(mixed_board(), keys=[self.click("mine")])
        self.assertEqual(out["storage"].get(FILTER_KEY), "mine")

    def test_a_remembered_choice_is_applied_on_a_COLD_BOOT(self):
        """This is the refresh: a brand-new page, board.js booted from scratch,
        with only what the previous visit left behind."""
        out = self.run_board(mixed_board(), storage={FILTER_KEY: "mine"})
        self.assertEqual(sorted(self.rendered(out)), ["m1", "m2", "r2"])
        self.assertEqual(self.chips(out)["mine"]["pressed"], "true")

    def test_two_remembered_facets_come_back_as_two(self):
        out = self.run_board(mixed_board(), storage={FILTER_KEY: "theirs,unassigned"})
        self.assertEqual(sorted(self.rendered(out)), ["r1", "t1", "u1"])

    def test_clearing_the_filter_clears_the_stored_choice(self):
        out = self.run_board(mixed_board(), storage={FILTER_KEY: "mine"},
                             keys=[self.click("all")])
        self.assertIn(out["storage"].get(FILTER_KEY, ""), ("", None))

    def test_junk_in_storage_shows_the_whole_board(self):
        """Never trust what came back off disk. An unreadable preference is a
        board with no filter on it, not a board with no cards on it."""
        out = self.run_board(mixed_board(), storage={FILTER_KEY: "sideways,{}"})
        self.assertEqual(len(self.rendered(out)), 6)
        self.assertTrue(out["ownerFilter"]["hidden"] is False)

    def test_a_remembered_facet_with_no_cards_today_shows_the_whole_board(self):
        """The holo-split idiom: the CHOICE is remembered, the EFFECTIVE filter
        is that choice made legal for what is on screen right now. A `theirs`
        chosen yesterday must not blank a board that has none today — and it
        must not be forgotten either, or tomorrow's board loses it."""
        out = self.run_board(board({"align": [mine("m1"), remote("r1")]}),
                             storage={FILTER_KEY: "theirs"})
        self.assertEqual(sorted(self.rendered(out)), ["m1", "r1"])
        self.assertEqual(out["storage"].get(FILTER_KEY), "theirs")


# ══════════════════ 5. identity absent changes NOTHING ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class IdentityAbsentTest(FilterBase):
    """The S190 posture, unbroken. With no `meta.self` the board cannot say who
    it is, so it does not get to tell the captain which work is his."""

    def test_mine_and_theirs_are_not_offered(self):
        c = self.chips(self.run_board(mixed_board(self_login=None)))
        self.assertNotIn("mine", c)
        self.assertNotIn("theirs", c)

    def test_the_answerable_facets_still_are(self):
        """`unassigned` and `remote` are facts about the CARD; neither needs to
        know who we are, so neither goes away."""
        c = self.chips(self.run_board(mixed_board(self_login=None)))
        self.assertIn("unassigned", c)
        self.assertIn("remote", c)

    def test_an_owned_card_is_not_called_unassigned(self):
        """The dishonest degrade this test exists to stop: with no identity,
        `mine` collapsing to false would sweep every owned card into
        `unassigned`. An assignee is a fact; who WE are is the unknown."""
        out = self.run_board(mixed_board(self_login=None),
                             keys=[self.click("unassigned")])
        self.assertEqual(sorted(self.rendered(out)), ["r1", "u1"])

    def test_a_remembered_mine_does_not_blank_the_board(self):
        """He filtered to `mine` on a laptop with gh; gh expired. The board must
        show everything, not nothing."""
        out = self.run_board(mixed_board(self_login=None),
                             storage={FILTER_KEY: "mine"})
        self.assertEqual(len(self.rendered(out)), 6)

    def test_a_board_with_no_owners_at_all_offers_no_strip(self):
        """The solo board this product shipped with, byte-identical."""
        out = self.run_board(board({"align": [nobodys("a"), nobodys("b")]},
                                   self_login=None))
        self.assertTrue(out["ownerFilter"]["hidden"])
        self.assertEqual(out["status"], "2 active missions")


# ══════════════════ 6. IT COSTS NO FORGE ROUND TRIP (S152) ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class NoRoundTripTest(FilterBase):
    """The absolute constraint. The remote overlay's whole design is one cached
    `gh issue list` per CYCLE; a filter that asked the daemon to re-answer would
    put a forge call behind a chip.

    Filtering reads the board the page ALREADY holds. Proven here as ZERO
    fetches — no /api/board, no /api/mission, nothing — while every filter is
    applied and released, twice over. The other half of the proof (that the
    `gh` binary itself is never invoked) is the pixel drive's, which can see the
    subprocess this harness cannot."""

    ALL = ["all", "mine", "theirs", "unassigned", "remote"]

    def test_applying_every_filter_issues_no_fetch(self):
        seq = [self.click(f) for f in self.ALL] * 2
        out = self.run_board(mixed_board(), keys=seq)
        self.assertEqual(out["fetches"], [],
                         "filtering must never reach the daemon")

    def test_the_hotkey_path_issues_no_fetch_either(self):
        out = self.run_board(mixed_board(),
                             keys=[{"key": "o"}] * 8)
        self.assertEqual(out["fetches"], [])

    def test_a_cold_boot_under_a_remembered_filter_issues_no_extra_fetch(self):
        cold = self.run_board(mixed_board())
        warm = self.run_board(mixed_board(), storage={FILTER_KEY: "mine"})
        self.assertEqual(warm["fetches"], cold["fetches"])


# ══════════════════ 7. it does not fight the keyboard ══════════════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class HotkeyTest(FilterBase):

    def test_no_key_value_is_claimed_by_two_bindings(self):
        """The non-shadowing proof, asked of the whole table rather than of the
        one key this session adds — a binding table where any key resolves to
        two actions is broken however it got that way."""
        out = self.run_board(mixed_board())
        seen = {}
        for b in out["bindings"]:
            for k in b["on"]:
                self.assertNotIn(k, seen,
                                 "key %r is claimed by both %r and %r"
                                 % (k, seen.get(k), b["id"]))
                seen[k] = b["id"]

    def test_the_filter_key_is_o_and_it_is_new(self):
        out = self.run_board(mixed_board())
        owners = [b["id"] for b in out["bindings"] if "o" in b["on"]]
        self.assertEqual(owners, ["owner-filter"])

    def test_o_cycles_through_the_offered_facets(self):
        brd = mixed_board()
        seen = []
        for n in range(1, 6):
            out = self.run_board(brd, keys=[{"key": "o"}] * n)
            seen.append(sorted(self.rendered(out)))
        self.assertEqual(seen, [
            ["m1", "m2", "r2"],                          # mine
            ["t1"],                                      # theirs
            ["r1", "u1"],                                # unassigned
            ["r1", "r2"],                                # remote
            ["m1", "m2", "r1", "r2", "t1", "u1"],        # back to all
        ])

    def test_o_only_ever_visits_facets_that_are_offered(self):
        brd = board({"align": [mine("m1"), theirs("t1")]})
        for n in range(1, 7):
            out = self.run_board(brd, keys=[{"key": "o"}] * n)
            self.assertTrue(self.rendered(out),
                            "cycle step %d emptied the board" % n)

    def test_o_is_documented_in_the_command_deck(self):
        out = self.run_board(mixed_board())
        row = [b for b in out["bindings"] if b["id"] == "owner-filter"]
        self.assertEqual(len(row), 1)
        self.assertEqual(row[0]["keys"], ["o"])
        self.assertTrue(row[0]["label"][0].isupper())

    def test_o_typed_into_a_textarea_filters_nothing(self):
        out = self.run_board(mixed_board(), focusTextarea=True,
                             keys=[{"key": "o"}])
        self.assertEqual(len(self.rendered(out)), 6)

    def test_o_does_nothing_while_a_console_is_open(self):
        out = self.run_board(mixed_board(), openOverlay=True,
                             keys=[{"key": "o"}])
        self.assertEqual(len(self.rendered(out)), 6)

    def test_o_on_a_board_with_no_strip_is_safe(self):
        out = self.run_board(board({"align": [mine("m1"), mine("m2")]}),
                             keys=[{"key": "o"}] * 3)
        self.assertEqual(out["runErrors"], [])
        self.assertEqual(len(self.rendered(out)), 2)


# ══════════════════ 8. the vocabulary is the one that already exists ══════════

@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class VocabularyTest(FilterBase):

    def setUp(self):
        with open(os.path.join(HERE, "..", "static", "board.js")) as fh:
            self.js = fh.read()

    def test_theirs_is_the_light_locks_own_predicate(self):
        """If the filter answered "someone else's" with its own arithmetic, a
        card could be locked and unfiltered, or filtered and drivable. One
        predicate, one answer."""
        i = self.js.index("var OWNER_FILTERS")
        block = self.js[i:i + 4000]
        self.assertIn("ownerLockLogin", block)

    def test_remote_is_the_cards_own_remote_flag(self):
        i = self.js.index("var OWNER_FILTERS")
        self.assertIn("isRemote", self.js[i:i + 4000])

    def test_the_filter_declares_no_new_owner_field(self):
        """No fifth notion of identity: everything the strip reads is `owner`,
        `meta.self` and `remote`, which the daemon already publishes."""
        i = self.js.index("var OWNER_FILTERS")
        block = self.js[i:i + 4000]
        for invented in ("ownedBy", "assignee", "mineFlag", "filterOwner"):
            self.assertNotIn(invented, block)


# ══════════════════ 9. it leaves with the board ══════════════════

class SurfaceSwapTest(unittest.TestCase):
    """The holodeck and the day-zero front door REPLACE the board in the same
    frame, and render() keeps running underneath both (an SSE tick is enough).
    A strip that decided its visibility only from the card counts would float a
    set of board filters over a surface with no board on it."""

    def setUp(self):
        with open(os.path.join(HERE, "..", "static", "board.css")) as fh:
            self.css = fh.read()

    def test_the_deck_hides_the_strip(self):
        self.assertIn("body.on-deck #ownerFilter", self.css)

    def test_the_front_door_hides_the_strip(self):
        self.assertIn("body.on-front-door #ownerFilter", self.css)

    def test_the_strip_is_not_a_write_control_in_the_stylesheet_either(self):
        """`.btn.go` is what markViewOnly() reaches for; a chip must not wear
        it, and must not be styled to look like one."""
        self.assertNotIn(".of-chip.go", self.css)


class TheStripHostTest(unittest.TestCase):

    def test_index_html_carries_the_host_outside_the_band(self):
        """The yellow band's control order is pinned byte-for-byte by
        test_help_console; the strip must live in frame-content instead."""
        with open(os.path.join(HERE, "..", "static", "index.html")) as fh:
            html = fh.read()
        self.assertIn('id="ownerFilter"', html)
        band = html[html.index('class="frame-top topbar"'):html.index('frame-rail')]
        self.assertNotIn("ownerFilter", band)

    def test_the_host_starts_hidden(self):
        with open(os.path.join(HERE, "..", "static", "index.html")) as fh:
            html = fh.read()
        i = html.index('id="ownerFilter"')
        self.assertIn("hidden", html[i:i + 80])


if __name__ == "__main__":
    unittest.main()
