"""S191 — THE REMOTE OVERLAY. Missions that exist on the forge and not here.

THE GAP THIS CLOSES. A second clone has no `.git/lcars` at all, so a Mission
that plainly exists on GitHub is INVISIBLE to it: an empty board for work that is
running right now on the other laptop. `lcars adopt` (S189) fixes that for a
mission the captain wants to DRIVE here; this fixes it for the far commoner case
of one he only wants to WATCH.

WHY THIS IS AN OVERLAY AND NOT THE GITHUB ADAPTER. The github adapter
(github_adapter.py) already reads issues + `lcars:*` labels into the board shape,
but it is an EITHER/OR choice made at daemon start: pick it and you lose every
local card, its ticket rows, its wave progress and its live driver state. The
captain's second laptop needs BOTH — the missions it owns locally, in full, plus
the ones driving elsewhere, in outline. So this module reuses the github
adapter's MAPPING (one implementation of "an issue as a card", ADR-003) and adds
its cards to the local board rather than replacing it.

────────────────────────────────────────────────────────────────────────────
THE THREE RULES
────────────────────────────────────────────────────────────────────────────

1. LOCAL MISSIONS ALWAYS WIN. An adopted mission is a LOCAL mission; the issue
   it was adopted from must never draw a second card. The dedupe key is the
   ISSUE NUMBER and nothing else, because `lcars adopt` REUSES the issue (it
   never mints a new one — the id already names the branch and the issue).

2. THE STAGE COMES FROM THE STAGE LABEL, NEVER FROM THE ENVELOPE. This is a
   standing ruling, and the reason is structural, not stylistic: S188 refreshes
   the `lcars:handoff` envelope at exactly TWO transfer points (a feedback
   re-grill completing, and Verify entry), so an envelope `stage` is STALE
   mid-pipeline BY CONSTRUCTION — it says `align` for a mission halfway through
   Implement. `gh_relabel` swaps the `lcars:<stage>` label at every single
   transition. One source per fact: the envelope owns identity, the label owns
   stage. The envelope is therefore read for exactly ONE thing here (S197 —
   the ENGINE the mission was filed on, which is an IDENTITY fact and is the
   half of the adopt question the forge is authoritative about) and for
   nothing that moves as a mission runs. Stage still comes from the label,
   and always will.

3. THE POLL IS SLOW AND CACHED, AND THAT IS A ROADMAP-LEVEL CONSTRAINT (S152).
   The front end re-fetches `/api/board` every four seconds and the SSE channel
   pushes on top of that, so a listing taken per BOARD BUILD is a `gh issue list`
   storm against the forge — the exact failure S152 recorded and forbade. There
   is ONE listing per CYCLE (default 30s, `$LCARS_REMOTE_POLL`, floored at 10s
   so the knob cannot re-create the storm), taken under a lock so two concurrent
   requests cannot both pay for it, and every remote card on the board is built
   from that one answer.

────────────────────────────────────────────────────────────────────────────
WHAT IT REFUSES TO DO
────────────────────────────────────────────────────────────────────────────

  * NO gh, NO overlay, NO new key. A machine without the GitHub CLI serves a
    board BYTE-IDENTICAL to the one it served before this session. That is every
    user who does not have two laptops, and it is checked by test, not by hope.

  * NO NETWORK ON THE LIVE CHANNEL. `fingerprint()` (the SSE poll, ~1/s) never
    reaches this module. Remote cards move on the slow poll and nowhere else —
    the deliberate v1 boundary.

  * NO CLAIMS IT CANNOT SUPPORT. A remote card carries what the forge actually
    knows: stage, awaiting-human, owner, title, the Estimate pills the body
    carries, and Implement ticket progress. The mission's LOCAL richness —
    research findings, plan.json, wave logs, the driver lock — lives in the
    OTHER laptop's `.git/` and is not synced anywhere (the captain's boundary
    ruling, 2026-09-04). The card says so instead of guessing.

stdlib only.
"""
import json
import os
import re
import shutil
import subprocess
import threading
import time

from . import board
from .github_adapter import GitHubAdapter, number_one, ticket_progress

# The cadence. THIRTY SECONDS, not one: this is a "somebody else's laptop is
# working" indicator, not a live feed, and the cost of being wrong in the fast
# direction is a request storm against the forge (S152).
DEFAULT_TTL = 30.0
# …and a FLOOR under the env knob. `$LCARS_REMOTE_POLL` exists so a capstone run
# can watch a pipeline advance without waiting half a minute per step; it must
# not be able to reintroduce the thing the default exists to prevent. A knob with
# no floor is the storm with an extra step.
MIN_TTL = 10.0

# How long one listing may take before we give up on it. Generous (the forge is
# a network away and gh starts a process) but BOUNDED: a board build must never
# be able to hang on a forge that has stopped answering. Note the seam this runs
# on is NOT the board build — see RemoteMissions.listing — but the bound belongs
# here anyway, because "no timeout" is how a daemon thread is lost for ever.
FETCH_TIMEOUT = 25

# The fields ONE listing has to carry. `subIssuesSummary` is the whole reason
# this is one call and not two: Schedule opens one `lcars:ticket` sub-issue per
# ticket and nests it NATIVELY under the mission issue (host-adapter.sh
# `link-subissue`), so the forge itself already counts them — completed/total,
# on the parent, for free. Counting them by listing the children instead would
# mean a second call AND a way to attribute each child to its parent, which the
# ticket bodies do not carry (see the ledger note in the session report).
# S278 — …and `closedAt`, the ONE field the Done column needs that nothing here
# used to ask for. It is the date the mission SHIPPED (the merge closes the issue
# via the PR body's `Closes #n`), which is the order a history reads in; the
# issue NUMBER is the order it was FILED in, and those are different orders.
# Verified read-only against an enterprise repo on 2026-10-11: gh emits it on all 51
# closed `lcars:done` rows. Still ONE call per cycle — a field, not a request.
_JSON_FIELDS = ("number,title,state,labels,body,updatedAt,assignees,"
                "subIssuesSummary,closedAt")

# The forge's window. WIDENED FROM `open` TO `all`, and the reason is the whole
# of this session:
#
#   `lcars approve` merges the PR, and the PR body carries `Closes #<n>`
#   (host-adapter.sh `pr-body`), so GitHub CLOSES the mission issue the moment
#   the merge lands. Under `--state open` the shipped mission therefore
#   DISAPPEARS from the listing — and the laptop that FILED it, whose local
#   `.git/lcars` still says `verify`, went on offering a live `✓ Review PR ▸`
#   for a pull request that merged minutes ago. Measured twice in one day on two
#   different pairs of clones.
#
# ABSENCE IS NOT EVIDENCE, so "it fell out of the open listing" could never be
# read as "it shipped": the listing is capped, and a mission past the cap would
# have been declared merged on no information at all. The cure is to ASK FOR THE
# FACT instead of inferring it from a hole — same ONE call per cycle (S152 is
# untouched: the count is pinned by test), one wider window.
#
# WHAT IT COSTS, stated honestly: closed missions now occupy rows in the capped
# listing. gh returns newest-created first and a still-open mission is by
# definition recent, so the ones crowded out are historical; and a mission that
# IS crowded out simply gets no verdict, which leaves its card exactly as it was.
# The degrade is silence, never a wrong claim.
_STATE = "all"
_LIMIT = "200"
# …and the same number as an int, so "did the listing HIT the cap?" is a
# comparison and not a second literal that can drift from the first.
_LIMIT_N = int(_LIMIT)

_MISSION_LABEL = "lcars:mission"

# The label `lcars approve` applies at the ship, and the ONE thing on the forge
# that means "this mission is finished". Rule 4 (S191's standing ruling): stage
# truth comes from the LABEL, which `gh_relabel` swaps at every transition —
# never from the S188 envelope, which is stale mid-pipeline by construction.
_DONE_LABEL = "lcars:done"

# The two ENDS of the pipeline, and the complete list of stages a remote mission
# may be adopted at. S189's boundary, restated here because this is the surface
# that OFFERS it: at align the spec IS the issue body, and at verify the branch
# and the PR are both on the forge — so a rebuild is complete. Everything
# between them reads local artifacts (research findings, plan.json, ticket
# state) that were never synced, and an adopt that "worked" there would hand the
# captain a mission missing the very files the next stage opens.
ADOPTABLE_STAGES = ("align", "verify")


class RemoteMissions(object):
    """The cached, slow reader behind the remote overlay.

    Injectable throughout — `gh_bin`, `ttl` and `clock` are all parameters — so
    the suites drive it with a recording stub and an owned clock, and no test in
    this repo has ever to reach a real forge to prove the cadence.
    """

    def __init__(self, repo_root, gh_bin=None, repo=None, ttl=None,
                 clock=None, env=None):
        self.repo_root = repo_root
        self.gh_bin = gh_bin or os.environ.get("LCARS_GH_BIN", "gh")
        self.repo = repo            # optional owner/name; None → gh's default
        self._env = env if env is not None else os.environ
        self.ttl = self._resolve_ttl(ttl)
        self._clock = clock or time.time
        # The cache: (stamp, rows, status). `status` is "ok" or "unavailable" —
        # a FAILED listing is cached exactly like a successful one, deliberately,
        # so a forge that has stopped answering is asked once per cycle and not
        # once per render. The degraded path must not become the storm.
        self._stamp = None
        self._rows = []
        self._status = "unavailable"
        # The daemon is threaded. Without this two concurrent /api/board
        # requests both find a cold cache and both pay for a listing — which is
        # the storm again, just rarer and harder to see.
        self._lock = threading.Lock()
        # The MAPPER, not a reader: this GitHubAdapter is constructed purely to
        # borrow its issue→card mapping (ADR-003 — one implementation of the
        # board shape per fact). Its own `_fetch_issues` is never called from
        # here; the listing below is this module's single forge seam.
        self._mapper = GitHubAdapter(gh_bin=self.gh_bin, repo=repo)

    # -- configuration --------------------------------------------------------
    def _resolve_ttl(self, ttl):
        if isinstance(ttl, (int, float)) and ttl > 0:
            return float(ttl)
        raw = self._env.get("LCARS_REMOTE_POLL")
        try:
            val = float(raw) if raw else DEFAULT_TTL
        except (TypeError, ValueError):
            val = DEFAULT_TTL
        return max(val, MIN_TTL)

    def enabled(self):
        """Is there anything to ask, and are we allowed to ask it?

        TWO ways to be off, and BOTH must leave the board untouched:
          * `$LCARS_REMOTE_OVERLAY=0` — the explicit opt-out (a harness, a
            captain who does not want his board reaching the network at all);
          * no `gh` on this machine — the ordinary case for most users, and the
            one the byte-identity guarantee is written for.

        Read on every call rather than memoized, so the opt-out takes effect
        without a daemon restart and a test can flip it between renders.
        """
        if str(self._env.get("LCARS_REMOTE_OVERLAY", "1")).strip() == "0":
            return False
        return self._gh_path() is not None

    def _gh_path(self):
        """The resolved gh binary, or None when there is none.

        A value with a separator in it is a PATH (the tests' stub, an explicit
        `--gh-bin /usr/local/bin/gh`) and is checked as a file; a bare name goes
        through PATH lookup. Never raises.
        """
        gh = self.gh_bin
        if not gh:
            return None
        try:
            if os.sep in gh:
                return gh if os.path.isfile(gh) and os.access(gh, os.X_OK) else None
            return shutil.which(gh)
        except OSError:
            return None

    # -- the ONE forge seam ---------------------------------------------------
    def listing(self):
        """(rows, status) for THIS cycle. One `gh` call per cycle, at most.

        status is "off" (nothing to ask / not allowed), "ok", or "unavailable".

        The stamp is written BEFORE the fetch is attempted, not after, so a
        listing that fails, hangs to its timeout, or returns junk still consumes
        its cycle. Otherwise the one path that costs the most — a forge that is
        down — would be the one path that is retried on every single render.
        """
        if not self.enabled():
            return [], "off"
        with self._lock:
            now = self._clock()
            if self._stamp is not None and (now - self._stamp) < self.ttl:
                return self._rows, self._status
            self._stamp = now
            self._rows, self._status = self._fetch()
            return self._rows, self._status

    def _fetch(self):
        gh = self._gh_path()
        if gh is None:
            return [], "unavailable"
        cmd = [gh, "issue", "list", "--state", _STATE, "--limit", _LIMIT,
               "--label", _MISSION_LABEL, "--json", _JSON_FIELDS]
        if self.repo:
            cmd += ["--repo", self.repo]
        try:
            proc = subprocess.run(
                cmd, cwd=self.repo_root, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=FETCH_TIMEOUT)
        except Exception:
            # gh missing between the check and the call, un-runnable, or it hung
            # past the bound. "We could not ask" — never an exception into a
            # board build, and never a claim that there is nothing there.
            return [], "unavailable"
        if proc.returncode != 0:
            # No auth, no network, not a GitHub remote, rate-limited. All the
            # same answer from here: we do not know.
            return [], "unavailable"
        try:
            data = json.loads((proc.stdout or b"").decode("utf-8") or "[]")
        except ValueError:
            return [], "unavailable"
        if not isinstance(data, list):
            return [], "unavailable"
        return [r for r in data if isinstance(r, dict)], "ok"

    # -- the overlay ----------------------------------------------------------
    def cards(self, local_issues=(), host=None, repo=None):
        """(remote cards, meta block) for a board whose LOCAL cards hold
        `local_issues`.

        `host`/`repo` are the board's own `meta.ghHost` / `meta.repo` — the
        forge identity the LOCAL adapter has already resolved (ADR-002: the
        daemon shells `host-adapter.sh gh-host`; nothing here re-derives it).
        They are passed in rather than looked up because this module's whole
        posture is that it owns exactly one seam, `gh issue list`, and a second
        subprocess per board build is the thing S152 forbade. Absent ⇒ a done
        card simply carries no `url`; see `issue_url`.

        The meta block is None when the overlay is OFF — and None means the
        caller adds NO `remote` key at all. ABSENT, never null: the rule every
        additive key in this shape has followed since S109, and the thing that
        keeps a gh-less board byte-identical to the one it served yesterday.
        """
        rows, status = self.listing()
        if status == "off":
            return [], None
        if status != "ok":
            return [], {"status": "unavailable"}
        held = set()
        for n in (local_issues or ()):
            n = _as_issue(n)
            if n is not None:
                held.add(n)
        cards = []
        done = []
        for row in rows:
            n = _as_issue(row.get("number"))
            if n is None or n in held:
                # LOCAL WINS. An adopted mission is a local mission and its issue
                # must never draw a second card. ONE dedupe key — the ISSUE
                # NUMBER — shared with `verdicts()` below, and applied BEFORE
                # anything is built rather than as a later pass that could be
                # reached with the wrong list.
                continue
            if _is_closed(row):
                # S278 — THE OTHER HALF OF THE WIDER WINDOW, FINALLY SPENT.
                #
                # `--state all` was taken (S197) so a LOCAL card could learn that
                # its issue had closed, and every closed row was thrown away one
                # line later with the note "THE WIDER WINDOW IS FOR VERDICTS, NOT
                # FOR CARDS". That was right about one thing and wrong about
                # another: a mid-pipeline mission's artifacts are genuinely not
                # on the forge, but a FINISHED one has nothing left to carry. The
                # cost of the old line was that a fresh clone of a repo with 51
                # shipped missions showed an empty Done column — no evidence the
                # factory had ever shipped anything at all.
                #
                # THE LABEL IS THE WHOLE DISTINCTION (rule 2). `lcars approve`
                # applies `lcars:done` at the ship and nowhere else, so:
                #   closed + lcars:done  → it SHIPPED. Draw it, read-only.
                #   closed, no label     → it was ABANDONED (or closed by hand).
                #                          Not drawn. There are three of them in
                #                          the measured repo and the Done column is
                #                          not the place to list them.
                if _DONE_LABEL not in _labels(row):
                    continue
                card = self._done_card(row, rows, host, repo)
                if card is not None:
                    done.append(card)
                continue
            card = self._card(row, rows)
            if card is not None:
                cards.append(card)
        cards.sort(key=lambda c: c.get("issue") or 0, reverse=True)
        # DONE IS ORDERED BY WHEN IT SHIPPED, not by what it was numbered. A
        # missing `closedAt` sorts LAST ("" < any stamp) rather than dropping the
        # card: a forge is not a promise, and an unreadable date costs the card
        # its place in the order, never its existence. The issue number breaks
        # ties so the order is total and a repaint cannot reshuffle equals.
        done.sort(key=lambda c: (c.get("closedAt") or "", c.get("issue") or 0),
                  reverse=True)
        meta = {"status": "ok", "count": len(cards) + len(done)}
        if len(rows) >= _LIMIT_N:
            # THE CAP WAS REACHED, SO THE HISTORY IS INCOMPLETE — and a history
            # that is quietly incomplete is worse than no history. The caller
            # promotes this to `meta.doneTruncated` and the board draws one row
            # saying so. ABSENT when the listing fit, which is every repo but the
            # very largest.
            meta["doneTruncated"] = True
        return cards + done, meta

    def mission(self, mid):
        """The DETAIL payload for a remote card, or None.

        The card is click-to-open, so without this a remote card opens onto "no
        such mission" — a board that shows you something and then denies it
        exists. It claims nothing it cannot see: no activity feed (the comments
        are not fetched — that is the OTHER laptop's story to tell), no ADRs, no
        acceptance criteria, exactly as the github adapter's detail does.
        """
        rows, status = self.listing()
        if status != "ok" or not mid:
            return None
        for row in rows:
            if str(row.get("number")) == str(mid):
                if _is_closed(row):
                    # S278 — STILL NONE, FOR A BETTER REASON THAN BEFORE.
                    #
                    # This used to read "no card is drawn for it (see cards()),
                    # so no detail opens onto it either", and half of that is no
                    # longer true: a closed `lcars:done` issue DOES draw a Done
                    # card now. What has not changed is that there is nothing to
                    # put in a detail pane for it. A finished mission's research
                    # findings, plan.json, wave logs and usage record live in
                    # whichever laptop's `.git/lcars` drove it and are not synced
                    # to the issue (the captain's boundary ruling, 2026-09-04),
                    # so a detail here would be a window onto nothing.
                    #
                    # THE CARD DOES NOT NEED ONE. It is click-through to the
                    # ISSUE (board.js `isRemoteDone`), where the whole record —
                    # the PRD, the estimate, the merged PR — actually is.
                    return None
                card = self._card(row, rows)
                if card is None:
                    return None
                card["activity"] = []
                card["adrs"] = None
                card["criteria"] = None
                return card
        return None

    def _card(self, row, rows):
        """One issue → one adapter-neutral card, plus the remote-only keys."""
        try:
            card = self._mapper.card_from_issue(row, rows)
        except Exception:
            # A forge is not a promise (the github adapter's own words). One
            # malformed row must never cost the whole overlay, let alone the
            # local board it is riding on.
            return None
        if not isinstance(card, dict):
            return None
        # THIS CARD IS NOT DRIVEN FROM HERE. The front end keys every read-only
        # affordance off this one boolean, so it is a hard True, never a
        # truthy-ish value a later reader has to interpret.
        card["remote"] = True
        # …and whether the captain may take command of it on THIS laptop. Derived
        # from the STAGE LABEL (see rule 2), which is the only thing that can
        # answer it, and offered at exactly the two ENDS.
        card["adoptable"] = card.get("stage") in ADOPTABLE_STAGES
        card["progress"] = _ticket_progress(row, card.get("stage"))
        # S197 — WHICH ENGINE THIS MISSION WAS FILED ON. The board's adopt
        # picker has to be able to SAY it before it dispatches, and the issue
        # body is the only place a laptop that has never seen this mission can
        # learn it. Read off the row already in hand: NO extra forge call, so
        # S152's one-listing-per-cycle is untouched.
        #
        # ABSENT, NEVER NULL. `engine: null` in the envelope is a real and
        # deliberate answer ("the filing laptop pinned nothing; host detection
        # decides" — S188), and it is carried here by the KEY BEING MISSING,
        # exactly as a body with no envelope at all is. The picker treats both
        # the same way, which is what the CLI does.
        eng = _envelope_engine(row.get("body"))
        if eng:
            card["engine"] = eng
        # S203 — WHAT NUMBER ONE SAID ABOUT THIS MISSION, read off the SAME row's
        # labels: `lcars:xo:engaged` for the badge, `lcars:xo:high|medium|low`
        # for the intent-match score. NO EXTRA CALL — the whole reason the score
        # is a label and not an envelope field ("stage from the label, never the
        # envelope") is that this poll must stay ONE `gh` call per cycle (S191).
        #
        # ABSENT, NEVER NULL, and it is `card_from_issue`'s own key: the mapper
        # already sets it (one implementation, ADR-003) and this line is the
        # seam that says the overlay depends on it — the shape `_ticket_progress`
        # above takes for the same reason.
        xo = _number_one(row)
        if xo is not None:
            card["numberOne"] = xo
        else:
            card.pop("numberOne", None)
        return card


    def _done_card(self, row, rows, host, repo):
        """One CLOSED, `lcars:done` issue → one read-only Done card.

        IT IS THE SAME CARD, PLUS A DATE AND MINUS EVERY AFFORDANCE. The mapping
        is `card_from_issue`'s, exactly as the live remote cards use (ADR-003 —
        one implementation of "an issue as a card"), so the Done column paints
        the generic card the rest of the board paints: title, type, the Estimate
        pills the body carries, the engine watermark. What it adds is the one
        fact that makes it history rather than news — WHEN it shipped — and what
        it takes away is everything that implies there is something left to do.

        `readOnly` IS NOT `remote`. A live remote card is read-only *here* and
        offers Adopt, because the mission is running on another machine and could
        be taken over. This one offers nothing, ever: there is no local detail to
        open (see `mission()`), no stage to advance, and no artifacts to rebuild.
        The front end keys the no-controls, click-through-to-the-issue treatment
        off `readOnly`, so it is a hard True rather than a truthy-ish value.
        """
        card = self._card(row, rows)
        if card is None:
            return None
        # `_card` derives this from the STAGE LABEL (rule 2), and a `lcars:done`
        # issue already reads as `done` there — asserted, not assumed, because
        # the column a card lands in is decided by this string.
        card["stage"] = "done"
        card["readOnly"] = True
        # NOTHING TO TAKE OVER. `_card` set this from the stage label and `done`
        # is not in ADOPTABLE_STAGES, so it is already False; it is pinned here
        # because a future stage added to that tuple must not reach this card.
        card["adoptable"] = False
        at = row.get("closedAt")
        if isinstance(at, str) and at.strip():
            card["closedAt"] = at.strip()
        url = issue_url(host, repo, card.get("issue"))
        if url:
            card["url"] = url
        # THE MISSION'S OWN ID, when the body records one. A done card is the
        # only remote card whose id is never POSTed anywhere (there is no adopt
        # and no detail), so it is free to be the id the mission actually had on
        # the laptop that shipped it — which is what the captain's own notes,
        # branches and `lcars status` output call it. The ISSUE NUMBER remains
        # the dedupe key and `issue` still carries it; this changes the label,
        # never the identity. Read with the SAME parser `_envelope_engine` uses.
        mid = _envelope_field(row.get("body"), "id")
        if mid:
            card["id"] = mid
        return card

    # -- the verdict on a LOCAL mission --------------------------------------
    def verdicts(self, local_issues=()):
        """{issue number: verdict} for the LOCAL missions the forge says are over.

        THE DEFECT THIS ANSWERS. Two live two-laptop runs, independently, on the
        same day: laptop B adopted a mission, drove it and merged it, and laptop
        A — the one that FILED it — still showed the card at Verify offering a
        live `✓ Review PR ▸` for a pull request that had already merged. Local
        state beats the remote overlay (rule 1), which is right for CONTENT and
        was silently being applied to TRUTH as well.

        WHAT IT DOES NOT DO. It does not build a card, move a card, or touch
        `.git/lcars`. It answers ONE question about issues the local board
        ALREADY holds — is this issue finished on the forge? — and the caller
        decides what to say. Rule 3 is intact: the local mission still wins.

        IT BUYS NOTHING. `listing()` is the same cached call `cards()` makes;
        inside one cycle the second reader is free, and inside one board build
        it is the same cache entry. S152 is pinned by an argv-counting test, not
        by this paragraph.

        THREE WAYS TO RETURN NOTHING, and every one of them leaves the card
        exactly as it is:

          * the overlay is OFF (no gh, opted out) — the byte-identity guarantee;
          * the listing FAILED ("unavailable") — S190's D1 in this session's
            clothes. A forge that did not answer must never be readable as a
            forge that said "shipped", so a bad cycle yields `{}` and not a
            single verdict;
          * the issue is not IN the listing. Absence is not evidence: the query
            is capped, so a mission past the cap is UNKNOWN. Only a row we can
            actually read produces a verdict.

        Two verdicts, because they are two different facts and only one of them
        is a merge:

          "shipped"  the `lcars:done` label is on the issue. `lcars approve`
                     applies it at the ship and nowhere else.
          "closed"   the issue is CLOSED and carries no `lcars:done` — the
                     mission was abandoned or closed by hand on the forge.
                     Over, but NOT merged, and saying "shipped" here would be
                     inventing a merge nobody performed.
        """
        rows, status = self.listing()
        if status != "ok":
            return {}
        wanted = set()
        for n in (local_issues or ()):
            n = _as_issue(n)
            if n is not None:
                wanted.add(n)
        if not wanted:
            return {}
        out = {}
        for row in rows:
            n = _as_issue(row.get("number"))
            if n is None or n not in wanted:
                continue
            labels = _labels(row)
            closed = _is_closed(row)
            done = _DONE_LABEL in labels
            if not (done or closed):
                continue
            out[n] = {
                "issue": n,
                "state": "shipped" if done else "closed",
                "closed": closed,
                # The forge's own stage, from the LABEL (rule 4). "done" for a
                # shipped mission; for a closed-but-unshipped one it is the
                # stage the mission died at, which is the honest thing to name.
                "stage": _stage_label(labels),
            }
        return out


# --- helpers -----------------------------------------------------------------
# The S188 handoff envelope, as issue-body.sh writes it:
#   <!-- lcars:handoff v1 {"id":…,"branch":…,"base":…,"type":…,"engine":…,…} -->
# ONE LINE, APPENDED, and the LAST one on the body is the real one — a PRD may
# legitimately QUOTE an envelope, and adopt.sh resolves that exactly this way
# (`index($0, "<!-- lcars:handoff ")` … `last = NR`). Same rule here, so the
# board and adopt.sh can never read two different envelopes off one body.
_ENVELOPE_MARK = "<!-- lcars:handoff "
_ENVELOPE_END = " -->"


def _envelope(body):
    """The handoff envelope on `body` as a dict, or None. Never raises.

    S278 lifted this out of `_envelope_engine` unchanged, because a SECOND
    envelope reader is exactly the drift this file's own header warns about (the
    zero-collect phrase list, which lives in two places and has since disagreed
    with itself). The LAST envelope on the body wins — a PRD may legitimately
    quote one, and `adopt.sh` resolves it the same way — so the board and the
    CLI can never read two different envelopes off one issue.

    A FORGE IS NOT A PROMISE (this module's standing posture): a truncated
    envelope, a body that is not a string, or JSON that does not parse all
    answer None, and every caller treats None exactly as it treats a body that
    carries no envelope at all.
    """
    if not isinstance(body, str) or _ENVELOPE_MARK not in body:
        return None
    tail = body[body.rfind(_ENVELOPE_MARK) + len(_ENVELOPE_MARK):]
    end = tail.find(_ENVELOPE_END)
    if end < 0:
        return None
    blob = tail[:end].strip()
    at = blob.find("{")
    if at < 0:
        return None
    try:
        env = json.loads(blob[at:])
    except Exception:
        return None
    return env if isinstance(env, dict) else None


def _envelope_field(body, key):
    """One STRING field off the envelope, validated, or None.

    The validation is `_envelope_engine`'s and it is deliberately the same for
    every key: these values become directory names, command-line arguments and
    URL path segments in other parts of this product, and "it is only a label
    here" is how a value that was never checked arrives somewhere it matters. A
    bare identifier (alphanumerics plus `-_.`), or nothing.
    """
    env = _envelope(body)
    if not isinstance(env, dict):
        return None
    val = env.get(key)
    if not isinstance(val, str):
        return None
    val = val.strip()
    if not val or not all(ch.isalnum() or ch in "-_." for ch in val):
        return None
    return val


def _envelope_engine(body):
    """The `engine` the handoff envelope names, or None. Never raises.

    A FORGE IS NOT A PROMISE (this module's standing posture): a truncated
    envelope, a body that is not a string, JSON that does not parse, or an
    `engine` that is null all answer None — and None means the card carries no
    `engine` key at all, which the picker reads as "the mission pinned
    nothing". An unreadable envelope must never invent an engine.
    """
    return _envelope_field(body, "engine")


# A DNS hostname and nothing else — no scheme, no path, no port, no space. The
# same expression `board.js` guards `meta.ghHost` with (GH_HOST_RE) and the same
# one `local_adapter` validates the shell's answer against, for the same reason:
# this value is spliced into a URL the captain CLICKS, and a guard that exists
# only upstream is not a guard here.
_HOST_RE = re.compile(
    r"^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$")
# `owner/name`, each segment a GitHub-legal repository path segment. A repo with
# NO origin degrades to the working-tree DIRECTORY BASENAME (local_adapter's
# `_repo_identity`, step 3), which would build a link to a github.com repository
# that does not exist — so this refuses anything that is not two segments.
_REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")


def issue_url(host, repo, number):
    """`https://<host>/<owner>/<name>/issues/<n>`, or None.

    THE ONE PLACE THE DAEMON BUILDS AN ISSUE URL, and the mirror of board.js's
    `ghIssueUrl` — same scheme pinned in the code rather than carried over the
    wire, same bare-hostname contract, same github.com fallback for an absent
    host (`gh_hostname` returns EMPTY on github.com by design, so "no host" and
    "github.com" are one case).

    ABSENT, NEVER WRONG. A repo identity that is not `owner/name`, a host that
    is not a hostname, or a number that is not a number all answer None, and the
    caller then omits the key — a Done card with no link still tells the captain
    his repo shipped 51 missions, which a card linking to a 404 does not.
    """
    if not isinstance(repo, str) or not _REPO_RE.match(repo.strip()):
        return None
    n = _as_issue(number)
    if n is None:
        return None
    h = host.strip() if isinstance(host, str) else ""
    if h and not _HOST_RE.match(h):
        # Refused, never spliced. Falling back to github.com here would be a
        # wrong link; and this cannot reach the scheme, which is pinned above.
        h = ""
    return "https://%s/%s/issues/%d" % (h or "github.com", repo.strip(), n)


def _labels(row):
    """The issue's label names as a set. Crash-proof: a forge is not a promise."""
    out = set()
    for lab in (row.get("labels") or []):
        if isinstance(lab, dict):
            name = lab.get("name")
        else:
            name = lab
        if isinstance(name, str) and name:
            out.add(name)
    return out


def _is_closed(row):
    """Is this issue CLOSED on the forge? `state` is "OPEN"/"CLOSED" from gh."""
    return str(row.get("state") or "").strip().upper() == "CLOSED"


def _stage_label(labels):
    """The `lcars:<stage>` the issue currently wears, or None.

    The label, never the envelope — the S188 handoff envelope is refreshed at
    exactly two transfer points and is stale mid-pipeline by construction, while
    `gh_relabel` swaps this at every single transition.
    """
    if _DONE_LABEL in labels:
        # FIRST, and not merely by luck of iteration order: `lcars approve`
        # removes `lcars:verify` as it adds `lcars:done`, but a relabel is
        # best-effort (gh_relabel never blocks the local stage change), so an
        # issue wearing both must read as the LATER of the two.
        return "done"
    for stage in board.STAGES:
        if ("lcars:%s" % stage) in labels:
            return stage
    return None


def _as_issue(value):
    """An issue number as an int, or None. Tolerates the string form: `state.json`
    has carried `githubIssue` as both over this project's life."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _ticket_progress(row, stage):
    """The Implement ticket count off the listing's own `subIssuesSummary`.

    S207 moved the implementation to github_adapter.ticket_progress so the ONE
    fact has ONE implementation: this module's overlay and the github adapter's
    own cards now render the same count from the same code. The name stays as
    this module's seam (and its callers' and tests') — the body is gone, not the
    contract: None for any stage but implement, None for a mission with no
    sub-issues, and None for a payload that does not carry the summary (a gh too
    old to know the field returns nothing rather than a wrong zero).
    """
    return ticket_progress(row, stage)


def _number_one(row):
    """`{status, score}` from the row's `lcars:xo:*` labels, or None.

    Delegates to github_adapter.number_one for the same reason `_ticket_progress`
    delegates to `ticket_progress`: ONE implementation of one fact, shared by the
    overlay and by the github adapter's own board. The seam stays named here so
    this module's dependence on it is visible from this side too.

    IT READS THE ROW, AND ONLY THE ROW. Everything it answers is in the listing
    `listing()` already fetched, so the overlay's forge budget is exactly what it
    was before this round — one call per cycle.
    """
    return number_one(row)
