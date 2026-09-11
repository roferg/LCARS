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
   stage. This module therefore parses no envelope at all.

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
import shutil
import subprocess
import threading
import time

from . import board
from .github_adapter import GitHubAdapter

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
_JSON_FIELDS = ("number,title,state,labels,body,updatedAt,assignees,"
                "subIssuesSummary")

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
    def cards(self, local_issues=()):
        """(remote cards, meta block) for a board whose LOCAL cards hold
        `local_issues`.

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
        for row in rows:
            n = _as_issue(row.get("number"))
            if n is None or n in held:
                # LOCAL WINS. An adopted mission is a local mission and its issue
                # must never draw a second card.
                continue
            if _is_closed(row):
                # THE WIDER WINDOW IS FOR VERDICTS, NOT FOR CARDS. `--state all`
                # was taken so a LOCAL card can learn that its issue closed; it
                # must not also start drawing remote cards for every mission this
                # repo ever shipped. The overlay's card set is exactly what it
                # was — the open issues — and that is pinned by test.
                continue
            card = self._card(row, rows)
            if card is not None:
                cards.append(card)
        cards.sort(key=lambda c: c.get("issue") or 0, reverse=True)
        return cards, {"status": "ok", "count": len(cards)}

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
                    # No card is drawn for it (see cards()), so no detail opens
                    # onto it either. One window, both surfaces.
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
    """Implement progress from the mission issue's own sub-issue summary.

    WHAT THIS IS AND IS NOT. It is `completed/total` over the `lcars:ticket`
    sub-issues Schedule opened and nested under this mission — the forge's own
    count, so it moves as Implement closes each ticket. It is NOT the local
    card's wave progress: waves.json lives in the driving laptop's `.git/` and is
    not synced anywhere, so the label says TICKET and never WAVE, and the block
    carries no `wave`/`shape` keys for the renderer to imply one from. Claiming
    a wave number we cannot see would be the exact class of invented fact this
    round has spent three sessions refusing.

    None (no block at all) for any stage but implement, for a mission with no
    sub-issues, and for a payload that does not carry the summary — a gh too old
    to know the field returns nothing here rather than a wrong zero.
    """
    if board.normalise_stage(stage) != "implement":
        return None
    summary = row.get("subIssuesSummary")
    if not isinstance(summary, dict):
        return None
    total = summary.get("total")
    if not isinstance(total, int) or total <= 0:
        return None
    done = summary.get("completed")
    if not isinstance(done, int) or done < 0:
        done = 0
    if done > total:
        done = total
    return {"ticketsDone": done, "ticketsTotal": total,
            "label": "TICKET %d/%d" % (done, total)}
