"""GITHUB read adapter (ADR-003).

Reads the canonical Mission state straight off GitHub — issues + `lcars:*`
labels (+ S65 mirrored comments) — via `$LCARS_GH_BIN`, and maps it to the SAME
adapter-neutral board shape the LOCAL adapter produces (board.py). It mirrors
comment-mirror.sh's gh-invocation idiom: every external call is the env-injected
`$LCARS_GH_BIN`, so a test stubs `gh` and no network is touched.

This is the adapter a future view-only hosted build uses: GitHub issues carry
full board state (labels for the column + card state, the issue body's
"## Estimate" section for the pills, sub-issues for the nested tickets).

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
_TICKET_LABEL = "lcars:ticket"
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
        cmd = [self.gh_bin, "issue", "list", "--state", "open",
               "--limit", "200",
               "--json", "number,title,state,labels,body,comments,updatedAt"]
        if self.repo:
            cmd += ["--repo", self.repo]
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            return []
        try:
            data = json.loads(out.decode("utf-8") or "[]")
        except ValueError:
            return []
        return data if isinstance(data, list) else []

    # -- mapping --------------------------------------------------------------
    def _cards(self, issues):
        cards = []
        for issue in issues:
            if _label_names(issue) and _MISSION_LABEL in _label_names(issue):
                c = self._card(issue, issues)
                if c is not None:
                    cards.append(c)
        return cards

    def _card(self, issue, issues):
        labels = _label_names(issue)
        stage = _stage_of(labels)
        awaiting = _AWAITING_LABEL in labels
        paused = _PAUSED_LABEL in labels
        body = issue.get("body") or ""
        pills = _pills_from_body(body)
        model_mix = _model_mix_from_body(body)
        # S74 follow-up CHANGE 3: a logged bug skips Research+Validate, so drop
        # those rows from its model-mix table for adapter parity with the local
        # adapter. The github adapter knows a bug by its labels (lcars:bug /
        # lcars:linked). Shared filter (board.filter_bug_mix_rows) keeps the skip
        # identical across both adapters.
        if model_mix and ("lcars:bug" in labels or _LINKED_LABEL in labels):
            model_mix = board.filter_bug_mix_rows(model_mix) or None
        question = _gate_question(issue) if awaiting else None
        tickets = _tickets_for(issue, issues)
        progress = None  # GitHub progress lives in the mirrored Implement comment

        return {
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

    def _activity(self, issue):
        feed = []
        for c in (issue.get("comments") or []):
            if isinstance(c, dict):
                feed.append({"text": c.get("body") or "",
                             "ts": c.get("createdAt")})
        return feed


# --- helpers -----------------------------------------------------------------
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


def _tickets_for(parent, issues):
    """Sub-issues (lcars:ticket) that reference this parent in their body."""
    pn = parent.get("number")
    rows = []
    for i in issues:
        labels = _label_names(i)
        if _TICKET_LABEL not in labels:
            continue
        body = i.get("body") or ""
        if ("#%s" % pn) not in body:
            continue
        title = i.get("title") or ""
        tid_match = re.match(r"\s*(t-\d+)", title)
        rows.append({
            "id": tid_match.group(1) if tid_match else str(i.get("number")),
            "issue": i.get("number"),
            "title": title,
            "state": "done" if (i.get("state") or "").upper() == "CLOSED"
                     else "in-progress" if "lcars:implement" in labels else "pending",
        })
    # single-ticket missions reuse the parent issue → no nested rows
    return rows if len(rows) > 1 else []


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
