#!/usr/bin/env python3
"""S202 — (re)plant the two parked fixture Missions, nothing else.

  python3 plant.py <fixture-root> <issue-cap> <issue-scope> <worker-bin> [mid …]

With no mission ids it plants both. It NEVER touches config.json (the repo's
`lcars xo on` switch lives there) and never writes a `numberOne` block — the
driver engages Number One itself, and a hand-written multi-line block would
break the one-line rule state.json's writer depends on.
"""
import json, os, shutil, sys

root, icap, iscope, wbin = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
want = set(sys.argv[5:])
L = os.path.join(root, ".git", "lcars")
os.makedirs(os.path.join(L, "missions"), exist_ok=True)

PRD = """# PRD — Reviewer queue

## 1. The problem
Reviewers cannot see what is waiting on them. There is no one place that lists
the pull requests a given reviewer has to look at.

## 2. Scope
The queue lists assigned work only — a reviewer who has not been assigned to a
pull request never appears in the queue.
The queue is read-only in this Mission; nothing in it can be actioned.

## 3. Out of scope
Notifications of any kind. Digest emails. Slack. Anything that leaves the page.

## 4. Acceptance
A reviewer opens /queue and sees exactly the pull requests assigned to them,
newest first, and nothing else.
"""

ADR = """# ADR-001 — One list, one source

The queue reads the assignment table and nothing else. We do not infer
reviewership from comment history, CODEOWNERS, or team membership.
"""


def plant(mid, issue, title, qtext, etype, summary, detail):
    d = os.path.join(L, "missions", mid)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    json.dump({
        "id": mid, "type": "feature", "title": title, "stage": "implement",
        "created": "2026-09-12T10:00:00Z", "model": "copilot",
        "githubIssue": int(issue), "branch": "lcars/" + mid, "base": "main",
        "workerBin": wbin,
        "awaitingHuman": True, "pendingQuestion": qtext,
    }, open(os.path.join(d, "state.json"), "w"), indent=2)
    open(os.path.join(d, "prd.md"), "w").write(PRD)
    open(os.path.join(d, "adr.md"), "w").write(ADR)
    open(os.path.join(d, "validated-plan.md"), "w").write(
        "# Validated plan\n\nBuild the read-only reviewer queue described in the PRD.\n")
    json.dump({"stage": "implement", "humanSummary": summary,
               "escalationType": etype, "technicalDetail": detail,
               "questions": [qtext]},
              open(os.path.join(d, "pending.json"), "w"), indent=2)
    json.dump({"tickets": [
        {"id": "t-001", "title": "Render the queue list", "status": "done"},
        {"id": "t-002", "title": "Filter to the signed-in reviewer",
         "status": "blocked"}]},
        open(os.path.join(d, "plan.json"), "w"), indent=2)
    with open(os.path.join(d, "events.jsonl"), "w") as fh:
        for i, (ev, note) in enumerate([
                ("stage", "implement started"),
                ("ticket", "t-001 passed its gates"),
                ("ticket", "t-002 session 3 of 3 exhausted"),
                ("gate", "awaiting-human: " + qtext)]):
            fh.write(json.dumps({"at": "2026-09-12T1%d:00:00Z" % i,
                                 "event": ev, "detail": note}) + "\n")
    print("planted", mid, "(#%s)" % issue)


if not want or "m-cap" in want:
    plant("m-cap", icap, "Reviewer queue — who shows up in it",
          "Should unassigned reviewers appear in the review queue?",
          "cap",
          "Ticket t-002 has used all three worker sessions. It cannot decide whether "
          "a reviewer who has not been assigned to a pull request should still show "
          "up in the queue.",
          "t-002 filter-to-signed-in-reviewer: 3/3 sessions, last failure "
          "`queue.test.js: expected 0 rows for an unassigned reviewer, got 4`.")

if not want or "m-scope" in want:
    plant("m-scope", iscope, "Reviewer queue — a daily digest as well?",
          "Should the queue also send a daily digest email to each reviewer?",
          "scope",
          "Implementing the queue surfaced a request to also email each reviewer a "
          "daily digest of their queue. That is new work beyond the filed Mission.",
          "t-003 would add an SMTP dependency, a scheduler, and a new template "
          "directory; none are in the validated plan.")

cache = os.path.join(L, "cache")
os.makedirs(cache, exist_ok=True)
for i in (icap, iscope):
    open(os.path.join(cache, "owner-github.com-%s" % i), "w").write("roferg\n")
