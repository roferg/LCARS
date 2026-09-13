"""GITHUB read adapter (ADR-003).

Reads the canonical Mission state straight off GitHub — issues + `lcars:*`
labels (+ S65 mirrored comments) — via `$LCARS_GH_BIN`, and maps it to the SAME
adapter-neutral board shape the LOCAL adapter produces (board.py). It mirrors
comment-mirror.sh's gh-invocation idiom: every external call is the env-injected
`$LCARS_GH_BIN`, so a test stubs `gh` and no network is touched.

This is the adapter a future view-only hosted build uses: GitHub issues carry
full board state (labels for the column + card state, the issue body's
"## Estimate" section for the pills, the sub-issue SUMMARY for the Implement
ticket COUNT).

WHAT THIS ADAPTER DOES NOT HAVE: nested ticket ROWS. `tickets` is `[]` on every
card, deliberately — rendering the rows needs the sub-issue LIST, a second forge
call per mission that S152's one-listing-per-cycle budget does not have. S207
added the COUNT pill (`subIssuesSummary` → `TICKET 1/3`), which rides the listing
already being made; it did NOT add the rows. See the comment at `tickets = []`.

stdlib only.
"""
import json
import os
import re
import subprocess

from . import board

# The label → meaning maps (the label set in lcars-common.sh IS the data model).
_STAGE_LABELS = {"align", "research", "validate", "plan", "plan-review",
                 "schedule", "implement", "verify", "done"}
_MISSION_LABEL = "lcars:mission"
# (`lcars:ticket` had one reader, the never-matching _tickets_for; S207 removed
# both rather than leave a constant that implies a feature this adapter has not
# got.)
_AWAITING_LABEL = "lcars:awaiting-human"
_PAUSED_LABEL = "lcars:paused"
_LINKED_LABEL = "lcars:linked"


class GitHubAdapter(object):
    name = "github"

    def __init__(self, gh_bin=None, repo=None):
        self.gh_bin = gh_bin or os.environ.get("LCARS_GH_BIN", "gh")
        self.repo = repo  # optional owner/name; None → gh's default for the cwd

    # -- public surface -------------------------------------------------------
    def board(self):
        issues = self._fetch_issues()
        cards = self._cards(issues)
        cards.sort(key=lambda c: (c.get("_n") or 0), reverse=True)
        for c in cards:
            c.pop("_n", None)
        return board.assemble(cards, meta=self._meta())

    def _meta(self):
        # The github adapter is the hosted view-only seam: always read-only, and
        # its repo identity is exactly the owner/name it was constructed with
        # (None → empty string; the front end then shows just the adapter hint).
        return {
            "repo": self.repo or "",
            "adapter": "github",
            "mode": "read-only",
        }

    def mission(self, mid):
        issues = self._fetch_issues()
        idx = {str(i.get("number")): i for i in issues}
        issue = idx.get(str(mid))
        if issue is None:
            return None
        card = self._card(issue, issues)
        if card is None:
            return None
        card.pop("_n", None)
        card["activity"] = self._activity(issue)
        # detail-only shape fields (S70-B): the github body does not reliably
        # carry the mission's ADRs or the verbatim PRD acceptance criteria, so
        # both are null here (the front end shows its graceful note). modelMix is
        # already on the card from the body's Estimate table.
        card["adrs"] = None
        card["criteria"] = None
        return card

    def fingerprint(self):
        """A change signature from the issues' updatedAt timestamps."""
        issues = self._fetch_issues()
        stamps = sorted(str(i.get("updatedAt") or "") for i in issues)
        return "|".join(stamps)

    # -- gh invocation (the ONE external seam) --------------------------------
    def _fetch_issues(self):
        # S207: `subIssuesSummary` rides the SAME list call, for the same reason
        # `assignees` does — the forge already counts the sub-issues Schedule
        # nested under each mission (completed/total, on the parent), so the
        # Implement ticket count costs this adapter nothing. remote.py has read
        # it off one listing since S191; this is that fact, on this adapter.
        base = "number,title,state,labels,body,comments,updatedAt,assignees"
        out = self._list(base + ",subIssuesSummary")
        if out is None:
            # A gh too old to know the field fails the WHOLE listing, not just
            # the field. Retrying without it keeps a board on an older gh
            # exactly as full as it was — the count degrades to absent (see
            # _ticket_progress), never the board.
            out = self._list(base)
        if out is None:
            return []
        try:
            data = json.loads(out.decode("utf-8") or "[]")
        except ValueError:
            return []
        return data if isinstance(data, list) else []

    def _list(self, fields):
        """One `gh issue list` for these --json fields; None when gh refused."""
        cmd = [self.gh_bin, "issue", "list", "--state", "open",
               "--limit", "200",
               # S190: `assignees` rides the SAME list call — the forge already
               # knows who holds each issue, so owner parity with the local
               # adapter (ADR-003) costs this adapter nothing: no extra request,
               # no extra round trip, no new failure mode.
               "--json", fields]
        if self.repo:
            cmd += ["--repo", self.repo]
        try:
            return subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            return None

    # -- mapping --------------------------------------------------------------
    def _cards(self, issues):
        cards = []
        for issue in issues:
            if _label_names(issue) and _MISSION_LABEL in _label_names(issue):
                c = self._card(issue, issues)
                if c is not None:
                    cards.append(c)
        return cards

    def card_from_issue(self, issue, issues=()):
        """ONE issue row → ONE adapter-neutral card. The public face of `_card`.

        S191's remote overlay borrows exactly this mapping so a mission read off
        the forge produces the SAME card shape whichever surface read it (ADR-003
        — one implementation per fact). It is a named method rather than a reach
        into `_card` so the seam is visible from both sides: change the mapping
        and you can see who else depends on it.

        The `_n` sort key `_card` carries for its own ordering is dropped here —
        it is an internal of `board()`, not part of the shape.
        """
        card = self._card(issue, list(issues))
        if card is not None:
            card.pop("_n", None)
        return card

    def _card(self, issue, issues):
        labels = _label_names(issue)
        stage = _stage_of(labels)
        awaiting = _AWAITING_LABEL in labels
        paused = _PAUSED_LABEL in labels
        body = issue.get("body") or ""
        pills = _pills_from_body(body)
        # Mission-log-grounding round: the mix is driven PURELY by the issue
        # body's table (parity with the local adapter, which now drives it purely
        # off estimate.json). A logged bug walks the FULL pipeline, so its body
        # table lists all six stages and they all show; the old bug-skip filter
        # (which dropped Research/Validate) is gone. _model_mix_from_body skips
        # any empty-model row, so a genuinely fast-tracked bug — whose body may
        # still render blank Research/Validate cells — never shows empty rows.
        model_mix = _model_mix_from_body(body)
        question = _gate_question(issue) if awaiting else None
        # S207 — NO NESTED TICKET ROWS ON THIS ADAPTER, and that is now said
        # once, honestly, instead of being implied by a matcher that never
        # matched. `_tickets_for` grepped each ticket body for "#<parent>";
        # Schedule nests tickets through GitHub's NATIVE sub-issues API and the
        # bodies carry no such reference, so the rows have been empty for every
        # mission ever created. Rendering them for real needs the sub-issue LIST
        # — a SECOND forge call per mission, which S152's one-listing-per-cycle
        # budget does not have. The COUNT, however, is free (see below).
        tickets = []
        progress = ticket_progress(issue, stage)

        card = {
            "id": str(issue.get("number")),
            "issue": issue.get("number"),
            "title": issue.get("title") or "",
            "type": "bug" if "lcars:bug" in labels else "feature",
            "stage": stage,
            "awaiting": awaiting,
            "paused": paused,
            # S67 BUG-A: the driver lock is a LOCAL filesystem artifact the github
            # adapter cannot see, so `running` is always False here (adapter-
            # neutral shape, ADR-006 — the field is present, never crashing).
            "running": False,
            # BUG-062: `dispatched` (was a run launched?) is derived from LOCAL
            # events.jsonl / the driver lock, which the github adapter cannot see.
            # The forge view is read-only (Start/Pause are write actions, disabled
            # here), so a forge-visible proxy is unnecessary; mirror the
            # `running`/`queued` ADR-006 pattern — present, non-crashing, False.
            "dispatched": False,
            # S73: `queued` (resolve-logs scheduled-but-not-started) is derived
            # from a LOCAL state.json flag the github adapter cannot see, so it is
            # always False here (adapter-neutral shape, ADR-006 — present, non-
            # crashing).
            "queued": False,
            "question": question,
            # BUG-027: the legible gate envelope lives in the mission's LOCAL
            # pending.json, which the github adapter cannot see — None here
            # (adapter-neutral shape, ADR-006; renderer degrades to `question`).
            "gate": None,
            "linked": _LINKED_LABEL in labels,
            # Mission-log-grounding round (adapter parity): the github read-path
            # can't see the LOCAL state.json.origin, so a bug's grounding Research
            # is inferred from its labels — a logged/linked bug (lcars:bug /
            # lcars:linked) grounds. `origin` stays None (not forge-visible).
            "origin": None,
            "groundingResearch": ("lcars:bug" in labels
                                  or _LINKED_LABEL in labels),
            # UX-28: `parentMission` (a logged-bug child's parent id) is read from
            # the child's LOCAL state.json, which the github adapter cannot see, so
            # it is always None here (adapter-neutral shape, ADR-006 — present,
            # non-crashing).
            "parentMission": None,
            # S75 Verify PR lifecycle (ADR-006 adapter-neutral). The PR URL +
            # number live in the mission's LOCAL state.json, which the github
            # adapter cannot see, so they are None here. `review` is DERIVED from
            # the stage label so a github card still reads "in review" while at
            # verify (Verify auto-opens the PR, so a verify card always has an open
            # PR under review) — present, non-crashing, no extra forge calls.
            "prUrl": None,
            "prNumber": None,
            "review": "open" if stage == "verify" else None,
            # S76: the main-ahead reconcile sub-state lives in the mission's LOCAL
            # state.json (reconcileStatus), which the github adapter cannot see —
            # adapter-neutral read-path: None here (ADR-006).
            "reconcileStatus": None,
            # BUG-067: reconcileNote (the card summary) + reconcileMergeSha (the
            # reconciled tip) likewise live in the LOCAL state.json the github
            # read-path can't see — present and None (ADR-006 adapter-neutral).
            "reconcileNote": None,
            "reconcileMergeSha": None,
            "pills": pills,
            "modelMix": model_mix,
            "progress": progress,
            "tickets": tickets,
            # UX-24: active run time is derived from events.jsonl, a LOCAL
            # artifact the github adapter cannot see. Present-but-0 keeps the
            # shape adapter-neutral and non-crashing (ADR-006).
            "activeSeconds": 0,
            "_n": issue.get("number") or 0,
        }
        # S190: WHOSE MISSION IS THIS — from the issue's own assignees, through
        # the SAME shape builder the local adapter uses, so the two adapters emit
        # an identical `owner` block and the front end cannot tell them apart
        # (ADR-003). ABSENT (not null) on an unassigned issue, so a forge board
        # with nothing assigned on it is byte-identical to before this round.
        #
        # THE FIRST assignee, never a list: `mission_owner` defines ownership as
        # "the single standing assignee" precisely so the team round can swap in
        # an event-timeline winner later by changing one function. A reader that
        # started consuming a LIST here would make that swap expensive, so this
        # one does not.
        owner = board.owner_block(_first_assignee(issue))
        if owner is not None:
            card["owner"] = owner
        return card

    def _activity(self, issue):
        feed = []
        for c in (issue.get("comments") or []):
            if isinstance(c, dict):
                feed.append({"text": c.get("body") or "",
                             "ts": c.get("createdAt")})
        return feed


# --- helpers -----------------------------------------------------------------
def _first_assignee(issue):
    """The issue's single standing assignee login, or "" when nobody holds it.

    GitHub returns an empty ARRAY for "nobody" — never null, never a missing key
    — on both the `--json assignees` and the REST paths (recorded against real gh
    2.96.0 in ADOPT-RESOLUTION-SPIKE.md). So "unowned" is an EMPTY LIST, a valid
    answer, and never an error. Crash-proof against a payload that is not the
    shape we expect: this adapter reads a forge, and a forge is not a promise.
    """
    rows = issue.get("assignees") if isinstance(issue, dict) else None
    if not isinstance(rows, list):
        return ""
    for row in rows:
        if isinstance(row, dict):
            login = row.get("login")
            if isinstance(login, str) and login:
                return login
    return ""


def _label_names(issue):
    return {lab.get("name") for lab in (issue.get("labels") or [])
            if isinstance(lab, dict) and lab.get("name")}


def _stage_of(labels):
    for lab in labels:
        if lab.startswith("lcars:"):
            name = lab[len("lcars:"):]
            if name in _STAGE_LABELS:
                return board.normalise_stage(name)
    return "align"


def _gate_question(issue):
    # S65 mirrors a gate as a fresh comment; take the most recent comment that
    # mentions a question. Falls back to the latest comment body.
    comments = issue.get("comments") or []
    for c in reversed(comments):
        body = (c.get("body") or "") if isinstance(c, dict) else ""
        m = re.search(r"[Qq]uestion[:\s]+(.+)", body)
        if m:
            return m.group(1).strip()
    if comments and isinstance(comments[-1], dict):
        return (comments[-1].get("body") or "").strip() or None
    return None


def ticket_progress(row, stage):
    """Implement progress from the mission issue's own sub-issue summary.

    WHAT THIS IS AND IS NOT. It is `completed/total` over the `lcars:ticket`
    sub-issues Schedule opened and nested under this mission — the forge's own
    count, so it moves as Implement closes each ticket. It is NOT the local
    card's wave progress: waves.json lives in the driving laptop's `.git/` and is
    not synced anywhere, so the label says TICKET and never WAVE, and the block
    carries no `wave`/`shape` keys for the renderer to imply one from. Claiming
    a wave number we cannot see would be an invented fact.

    None (no block at all) for any stage but implement, for a mission with no
    sub-issues, and for a payload that does not carry the summary — a gh too old
    to know the field returns nothing here rather than a wrong zero.

    S207 moved this here from remote.py (which still calls it) so the ONE fact
    has ONE implementation: remote.py imports this module already, and the
    github adapter cannot import remote.py back without a cycle.
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


# Parse the issue body's "## Estimate" section into the same pill dicts the
# local adapter derives from estimate.json. The section is rendered by
# render_estimate_issue() in skills/lcars-run/run.sh — the source of truth — as a
# single line:
#
#     **Criticality:** reasoning = MEDIUM · implementation = HIGH
#
# i.e. the axis word ("reasoning" / "implementation") followed by ` = LEVEL`
# (UPPERCASE level, `·` middot between the two axes). The regexes below lock onto
# that exact word order + `=` separator and are case-insensitive so HIGH and high
# both parse.
_REASON_RE = re.compile(r"\breasoning\b\s*=\s*\**\s*(low|medium|high)", re.I)
_IMPL_RE = re.compile(r"\bimplementation\b\s*=\s*\**\s*(low|medium|high)", re.I)
_USD_RE = re.compile(r"\$\s*([\d.]+)\s*(?:[-–]\s*\$?\s*([\d.]+))?")
_REQ_RE = re.compile(r"([\d.]+)\s*(?:[-–]\s*([\d.]+))?\s*premium")


def _pills_from_body(body):
    reasoning = _level_search(_REASON_RE, body)
    impl = _level_search(_IMPL_RE, body)
    cost = _cost_from_body(body)
    return {
        "cost": cost,
        "reasoning": board.difficulty_pill("reasoning", reasoning) if reasoning else None,
        "implementation": board.difficulty_pill("implementation", impl) if impl else None,
    }


# S70-B1: parse the issue body's "**Per-stage model mix:**" markdown table that
# render_estimate_issue() (run.sh, the source of truth) emits:
#
#     **Per-stage model mix:**
#
#     | Stage | Model |
#     | --- | --- |
#     | Research | Opus |
#     | Implement | Opus |
#
# into the SAME [{stage, tier, why}] shape the local adapter derives from
# estimate.json. Stage cells are already the display labels ("Plan Review"); tier
# cells are Capitalised ("Opus"/"Sonnet") → lowered. `why` is None (the github
# body keeps the rationale as free prose, not a per-row field). No table → None.
_MIX_HEADER_RE = re.compile(r"\*\*Per-stage model mix:\*\*", re.I)
_MIX_ROW_RE = re.compile(r"^\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$")


def _model_mix_from_body(body):
    if not body:
        return None
    m = _MIX_HEADER_RE.search(body)
    if not m:
        return None
    rows = []
    after = body[m.end():].splitlines()
    started = False
    for line in after:
        cell = _MIX_ROW_RE.match(line)
        if not cell:
            # a blank line before the table is fine; a non-table line after the
            # table body ends the section.
            if started:
                break
            if line.strip() == "":
                continue
            break
        a, b = cell.group(1).strip(), cell.group(2).strip()
        # skip the header row ("Stage | Model") and the divider ("--- | ---").
        if a.lower() == "stage" and b.lower() == "model":
            started = True
            continue
        if set(a) <= set("-: ") and set(b) <= set("-: "):
            started = True
            continue
        started = True
        # Mission-log-grounding round: skip a row whose MODEL cell is empty. A
        # genuinely fast-tracked bug's issue body can render a blank Research /
        # Validate cell (`| Research |  |`) because render_estimate_issue loops
        # all six labels while the estimate omits those tiers. Dropping the empty
        # row here is what keeps a real fast-track bug from showing empty rows now
        # that the bug-skip filter is gone — while a logged bug (all cells filled)
        # keeps its Research + Validate rows.
        if not b:
            continue
        rows.append({"stage": a, "tier": b.lower(), "why": None})
    return rows or None


def _level_search(rx, body):
    m = rx.search(body)
    return m.group(1).lower() if m else None


def _cost_from_body(body):
    # Only look within the Estimate section to avoid matching stray '$' in PRD.
    section = body
    idx = body.find("## Estimate")
    if idx != -1:
        section = body[idx:]
    mreq = _REQ_RE.search(section)
    if mreq:
        low = float(mreq.group(1))
        high = float(mreq.group(2)) if mreq.group(2) else low
        return {"unit": "premiumRequests", "low": low, "high": high,
                "label": board._req_label(low, high)}
    musd = _USD_RE.search(section)
    if musd:
        low = float(musd.group(1))
        high = float(musd.group(2)) if musd.group(2) else low
        return {"unit": "usd", "low": low, "high": high,
                "label": board._usd_label(low, high)}
    return None
