"""Shared fixture builders for the LCARS serve adapter tests.

These plant a `.git/lcars/missions/<id>/` tree on disk the way `lcars file`,
`lcars run`, and the estimator do, so the LOCAL adapter can be exercised against
real artifact shapes (state.json / pending.json / plan.json / waves.json /
estimate.json / events.jsonl) with NO running model, gh, or git.
"""
import json
import os


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def write_json(path, obj):
    write(path, json.dumps(obj, indent=2) + "\n")


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


# A canonical estimator output (schemaVersion 3) — Claude cost block.
ESTIMATE_CLAUDE = {
    "schemaVersion": 3,
    "reasoningCriticality": "medium",
    "implCriticality": "high",
    "models": {
        "research": "opus", "validate": "opus", "plan": "opus",
        "planReview": "sonnet", "implement": "opus", "verify": "sonnet",
    },
    "rationale": "Touches a sensitive boundary.",
    "cost": {"cli": "claude", "unit": "usd", "currency": "USD",
             "usd": {"low": 4.2, "high": 6.4}},
    "estimatorModel": "opus",
}

ESTIMATE_COPILOT_LEGACY = {
    "schemaVersion": 3,
    "reasoningCriticality": "low",
    "implCriticality": "medium",
    "models": {"research": "sonnet", "validate": "sonnet", "plan": "sonnet",
               "planReview": "sonnet", "implement": "opus", "verify": "sonnet"},
    "rationale": "Routine.",
    "cost": {"cli": "copilot", "unit": "premiumRequests", "billing": "legacy",
             "premiumRequests": {"low": 10, "high": 14}, "usdOverage": None},
    "estimatorModel": "sonnet",
}


# Copilot USAGE billing (S64): the estimate carries GROSS `usd` AND `netUsd`
# (after includedCreditsUsd). Here the credits fully cover the run, so net is $0
# — the UX-15 trap the pill must NOT show (it must show the gross range).
ESTIMATE_COPILOT_USAGE = {
    "schemaVersion": 3,
    "reasoningCriticality": "medium",
    "implCriticality": "medium",
    "models": {"research": "sonnet", "validate": "sonnet", "plan": "sonnet",
               "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet"},
    "rationale": "Routine usage-billed run.",
    "cost": {"cli": "copilot", "unit": "usd", "currency": "USD",
             "billing": "usage", "includedCreditsUsd": 10.0,
             "usd": {"low": 3.5, "high": 7.0},
             "netUsd": {"low": 0.0, "high": 0.0}},
    "estimatorModel": "sonnet",
}


# A genuinely FAST-TRACKED bug's canonical estimate.json (legacy/none path): the
# estimator canonicalizes `models` down to ONLY the stages it runs — Research +
# Validate are ABSENT from the map (run.sh estimate fork, stage=="plan"). The
# model mix must then show only these four stages, never empty Research/Validate.
ESTIMATE_FASTTRACK_BUG = {
    "schemaVersion": 3,
    "reasoningCriticality": "low",
    "implCriticality": "medium",
    "models": {
        "plan": "opus", "planReview": "sonnet",
        "implement": "opus", "verify": "sonnet",
    },
    "rationale": "Small fix, fast-tracked.",
    "cost": {"cli": "claude", "unit": "usd", "currency": "USD",
             "usd": {"low": 1.0, "high": 2.0}},
    "estimatorModel": "opus",
}


def mission_dir(root, mid):
    return os.path.join(root, ".git", "lcars", "missions", mid)


def plant_simple(root, mid, *, stage="align", issue=142,
                 title="Add Gamification to Course Site", estimate=ESTIMATE_CLAUDE,
                 created="2026-06-13T10:00:00Z", worker_bin=None,
                 worker_model=None, queued=None,
                 parent_mission=None, parent_issue=None, mtype="feature",
                 origin=None,
                 pr_url=None, pr_number=None, review=None,
                 reconcile_status=None, reconcile_diagnosis=None,
                 reconcile_note=None, reconcile_merge_sha=None,
                 awaiting_human=None, pending_question=None):
    """A plain mission sitting in `stage`, no gate, no tickets.

    `worker_bin` plants the persisted engine field (state.json.workerBin) the
    way `lcars file` does when an engine was chosen; None omits it.
    `queued` plants the S73 resolve-logs scheduled-but-not-started flag
    (state.json.queued); None omits it.
    `parent_mission` plants the UX-28 logged-bug child's parent id
    (state.json.parentMission) the way `lcars log` does; None omits it.
    `mtype` plants state.json.type ("feature" default; "bug" for a logged bug
    that fast-tracks past Research/Validate straight to Plan).
    """
    d = mission_dir(root, mid)
    state = {
        "id": mid, "type": mtype, "title": title, "stage": stage,
        "created": created, "model": "claude", "githubIssue": issue,
        "branch": "lcars/%s" % mid, "base": "main",
    }
    if worker_bin is not None:
        state["workerBin"] = worker_bin
    # S78: an OPTIONAL per-mission frozen model (state.json.workerModel). When
    # present, Start feeds it as a PER-RUN $LCARS_WORKER_MODEL; when absent the
    # mission self-resolves (and Start strips any inherited daemon-wide pin).
    if worker_model is not None:
        state["workerModel"] = worker_model
    if queued is not None:
        state["queued"] = queued
    if parent_mission is not None:
        state["parentMission"] = parent_mission
    # Mission-log-grounding: a bug filed via `lcars log` stamps origin="log", the
    # signal that its Research pass runs in scoped GROUNDING mode.
    if origin is not None:
        state["origin"] = origin
    # BUG-033: a logged-bug child carries its parent's issue number on disk
    # (state.json.parentIssue) so the "child of #<n>" badge survives the parent
    # merging off the board.
    if parent_issue is not None:
        state["parentIssue"] = parent_issue
    # S75 Verify PR lifecycle: an in-review mission records its open PR.
    if pr_url is not None:
        state["prUrl"] = pr_url
    if pr_number is not None:
        state["prNumber"] = pr_number
    if review is not None:
        state["review"] = review
    # S76 main-ahead reconcile sub-state (merging/retesting/healing/escalated).
    if reconcile_status is not None:
        state["reconcileStatus"] = reconcile_status
    # S76 BUG: reconcile_gate persists a MULTI-LINE failure summary here. The
    # value can carry newlines/tabs/quotes — run.sh's json_escape must keep
    # state.json valid JSON so the adapter does not drop the mission.
    if reconcile_diagnosis is not None:
        state["reconcileDiagnosis"] = reconcile_diagnosis
    # BUG-067 SHARED CONTRACT: the human-readable reconcile summary the card shows
    # (e.g. "Reconciled main … re-tested green (8/8). Reapprove to merge.") and the
    # reconciled tip sha.
    if reconcile_note is not None:
        state["reconcileNote"] = reconcile_note
    if reconcile_merge_sha is not None:
        state["reconcileMergeSha"] = reconcile_merge_sha
    if awaiting_human is not None:
        state["awaitingHuman"] = awaiting_human
    if pending_question is not None:
        state["pendingQuestion"] = pending_question
    write_json(os.path.join(d, "state.json"), state)
    if estimate is not None:
        write_json(os.path.join(d, "estimate.json"), estimate)
    return d


def plant_gated(root, mid, *, resume_stage="align", inflight_stage="research",
                issue=143, title="Gated mission",
                question="Global vs per-course leaderboard?"):
    """A mission parked behind a human gate: state.json.stage is the resume
    pointer; pending.json.stage is the TRUE in-flight column (status.sh rule)."""
    d = mission_dir(root, mid)
    write_json(os.path.join(d, "state.json"), {
        "id": mid, "type": "feature", "title": title, "stage": resume_stage,
        "created": "2026-06-13T11:00:00Z", "githubIssue": issue,
        "awaitingHuman": True, "pendingQuestion": question,
        "branch": "lcars/%s" % mid, "base": "main",
    })
    write_json(os.path.join(d, "pending.json"),
               {"stage": inflight_stage, "question": question})
    write_json(os.path.join(d, "estimate.json"), ESTIMATE_CLAUDE)
    return d


def plant_paused(root, mid, *, stage="implement", issue=144, title="Paused mission"):
    d = mission_dir(root, mid)
    write_json(os.path.join(d, "state.json"), {
        "id": mid, "type": "feature", "title": title, "stage": stage,
        "created": "2026-06-13T12:00:00Z", "githubIssue": issue, "paused": True,
        "branch": "lcars/%s" % mid, "base": "main",
    })
    write_json(os.path.join(d, "estimate.json"), ESTIMATE_CLAUDE)
    return d


def plant_implementing(root, mid, *, issue=145, title="Implement mission"):
    """A mission in Implement with a plan, waves and ticket_* events."""
    d = mission_dir(root, mid)
    write_json(os.path.join(d, "state.json"), {
        "id": mid, "type": "feature", "title": title, "stage": "implement",
        "created": "2026-06-13T13:00:00Z", "githubIssue": issue,
        "branch": "lcars/%s" % mid, "base": "main",
    })
    write_json(os.path.join(d, "estimate.json"), ESTIMATE_CLAUDE)
    write_json(os.path.join(d, "plan.json"), [
        {"id": "t-001", "title": "XP model", "acceptanceCriteria": ["xp"],
         "dependencies": []},
        {"id": "t-002", "title": "Badge model", "acceptanceCriteria": ["badge"],
         "dependencies": []},
        {"id": "t-003", "title": "Leaderboard service", "acceptanceCriteria": ["lb"],
         "dependencies": ["t-001"]},
    ])
    write_json(os.path.join(d, "waves.json"), [
        {"wave": 1, "tickets": [{"id": "t-001", "issue": 201},
                                {"id": "t-002", "issue": 202}]},
        {"wave": 2, "tickets": [{"id": "t-003", "issue": 203}]},
    ])
    write_jsonl(os.path.join(d, "events.jsonl"), [
        {"ts": 1000, "mission": mid, "stage": "implement", "type": "stage_start",
         "detail": "implement starting"},
        {"ts": 1001, "mission": mid, "stage": "implement", "type": "wave_start",
         "detail": "wave 1", "data": {"wave": 1, "totalWaves": 2, "ticketCount": 2}},
        {"ts": 1002, "mission": mid, "stage": "implement", "type": "ticket_start",
         "detail": "t-001 XP model", "data": {"ticket": "t-001"}},
        {"ts": 1060, "mission": mid, "stage": "implement", "type": "ticket_green",
         "detail": "t-001 green", "data": {"ticket": "t-001"}},
        {"ts": 1061, "mission": mid, "stage": "implement", "type": "ticket_start",
         "detail": "t-002 Badge model", "data": {"ticket": "t-002"}},
    ])
    return d
