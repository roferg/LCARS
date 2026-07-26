"""LOCAL read adapter (ADR-003).

Reads `.git/lcars/missions/*/{state,pending,plan,waves,estimate}.json` and
`events.jsonl` straight off disk and maps them to the adapter-neutral board
shape in board.py. It MUST reproduce status.sh's gate/in-flight rule exactly:

  When a mission is parked behind the awaiting-human gate, state.json.stage is
  the *resume pointer* (e.g. "align"); pending.json.stage carries the TRUE
  in-flight stage (e.g. "research") — the column the card belongs in. So a gated
  mission stays in its real in-flight column and renders an AWAITING-YOU state,
  never pulled into a separate column.

stdlib only; no model/gh/git invoked.
"""
import json
import os
import re
import subprocess
import time

from . import board


class LocalAdapter(object):
    name = "local"

    def __init__(self, repo_root, read_only=False, git_url_reader=None):
        # repo_root is the working tree; mission state lives under .git/lcars.
        self.repo_root = repo_root
        self.missions_dir = os.path.join(repo_root, ".git", "lcars", "missions")
        # The write layer is a local-bridge concern (server decides); the
        # adapter is told whether writes are active so meta.mode is truthful.
        self.read_only = read_only
        # Worktree-safe repo identity asks `git` for the origin url. The reader
        # is injectable so tests stub it (no real git / network); None → the
        # default shell-git reader.
        self._git_url_reader = git_url_reader

    # -- the public surface ---------------------------------------------------
    def board(self):
        cards = [self._card(d) for d in self._mission_dirs()]
        cards = [c for c in cards if c is not None]
        # newest-first by created (string ISO sorts correctly); ties on id.
        cards.sort(key=lambda c: (c.get("_created") or "", c["id"]), reverse=True)
        for c in cards:
            c.pop("_created", None)
        return board.assemble(cards, meta=self._meta())

    def _meta(self):
        meta = {
            "repo": _repo_identity(self.repo_root, self._git_url_reader),
            "adapter": "local",
            "mode": "read-only" if self.read_only else "read-write",
        }
        # S139: the local main-deploy record `lcars launch --main` writes into
        # `.git/lcars/main/launch.json`. It's an ad-hoc deploy, NOT a mission, so
        # it's purely ADDITIVE: present ⇒ a small `mainLaunch`
        # {status,target,url,sha,branch,message} rides meta so the topbar band can
        # show ◐ DEPLOYING → ● MAIN LIVE → failed with the branch/sha + a Stop
        # affordance; ABSENT (no file / unparseable) ⇒ NO `mainLaunch` key at all,
        # so meta is byte-identical to before this round. The github adapter's
        # _meta never reads local files, so its shape is unchanged.
        ml = self._main_launch()
        if ml is not None:
            meta["mainLaunch"] = ml
        return meta

    def _main_launch(self):
        """The local main-deploy record → the additive meta.mainLaunch payload,
        or None (absent/unparseable). Reads `.git/lcars/main/launch.json` — the
        `--main` analog of a mission's launch.json."""
        p = os.path.join(self.repo_root, ".git", "lcars", "main", "launch.json")
        lj = _load_json(p)
        if not isinstance(lj, dict):
            return None
        return {
            "status": lj.get("status"),
            "target": lj.get("target"),
            "url": lj.get("url"),
            "sha": lj.get("sha"),
            "branch": lj.get("branch"),
            "message": lj.get("message"),
        }

    def mission(self, mid):
        d = os.path.join(self.missions_dir, mid)
        if not os.path.isdir(d):
            return None
        card = self._card(d)
        if card is None:
            return None
        card.pop("_created", None)
        card["activity"] = self._activity(d)
        # detail-only shape fields (S70-B): ADRs + verbatim acceptance criteria.
        card["adrs"] = _adrs_from_file(os.path.join(d, "adr.md"))
        card["criteria"] = _criteria_from_prd(os.path.join(d, "prd.md"))
        # S76: the verbatim PRD body, so the detail modal can render the full,
        # human-followable text. For a self-authored reconcile bug child this is the
        # detailed bug PRD (Conflict/failure summary, Root cause, Intended fix, …) —
        # the captain audits the self-heal straight from this. Empty string when
        # absent (non-crashing). The github adapter omits it (no local files).
        card["prd"] = _read_text(os.path.join(d, "prd.md"))
        return card

    def fingerprint(self):
        """A cheap state-change signature: max mtime over every mission file
        AND the main-deploy record.

        The live channel polls this; it changes the instant any state.json /
        pending.json / events.jsonl / etc. is rewritten by the harness. S139:
        it also folds in `.git/lcars/main/launch.json` (the `--main` deploy
        record) so a `POST /api/deploy/main` (or /stop) moves it — otherwise a
        PASSIVE second browser's deploy band never gets an SSE `update`. The
        main record is checked even when there is NO missions dir (a deploy is
        repo-level, not tied to a mission), so the empty-missions short-circuit
        can't hide it.
        """
        latest = 0.0
        seen = False
        for d in self._mission_dirs():
            for fn in os.listdir(d):
                try:
                    latest = max(latest, os.path.getmtime(os.path.join(d, fn)))
                    seen = True
                except OSError:
                    pass
        # S139: the main-deploy record — same path _main_launch() reads. A
        # missing file contributes nothing (mirrors the mission-file loop).
        main_launch = os.path.join(
            self.repo_root, ".git", "lcars", "main", "launch.json")
        try:
            latest = max(latest, os.path.getmtime(main_launch))
            seen = True
        except OSError:
            pass
        # Preserve the "0" sentinel only for the truly-empty case: no mission
        # files AND no main record.
        return "%.6f" % latest if seen else "0"

    # -- internals ------------------------------------------------------------
    def _mission_dirs(self):
        if not os.path.isdir(self.missions_dir):
            return []
        out = []
        for name in sorted(os.listdir(self.missions_dir)):
            d = os.path.join(self.missions_dir, name)
            if os.path.isfile(os.path.join(d, "state.json")):
                out.append(d)
        return out

    def _card(self, d):
        state = _load_json(os.path.join(d, "state.json"))
        if not isinstance(state, dict):
            return None
        mid = state.get("id") or os.path.basename(d)
        stage = state.get("stage") or "align"

        awaiting = _truthy(state.get("awaitingHuman"))
        paused = _truthy(state.get("paused"))
        question = state.get("pendingQuestion")
        # `running` (S67 BUG-A): true iff a LIVE `run drive` driver currently
        # holds this mission's lock (run.sh's $MISSION_DIR/driver.lock, a dir with
        # a pid file). Derived from the live lock so the board can flip a card to a
        # "running" state the instant Start fires — and false for idle/gated/paused/
        # done missions and a STALE lock (crashed driver). The front end depends on
        # this EXACT field name.
        running = _driver_running(d)

        # status.sh's gate rule: when awaiting-human and a pending.json exists,
        # the in-flight column comes from pending.json.stage, not state.stage.
        pending = _load_json(os.path.join(d, "pending.json"))
        events = _load_jsonl(os.path.join(d, "events.jsonl"))

        # BUG-062: `dispatched` — was a run ever actually LAUNCHED for this
        # mission? With the estimate gate (BUG-059) a logged bug fast-tracks to
        # stage="plan" but is FILED but HELD at estimate-review: only
        # estimate.json exists, NO events.jsonl, no driver lock. Such a mission
        # is NOT dispatched, so the front end must render "Start" — keying the
        # button off the stage value alone wrongly shows "Pause". A run is
        # dispatched iff it has emitted any events (durable proof it ran) OR a
        # live driver currently holds the lock (just started, events not yet
        # flushed). The front end (board.js) gates the Start/Pause control on
        # this so a held mission reads as Start, a real run as Pause.
        dispatched = bool(events) or running
        # BUG-027: the harness writes a legible, type-aware gate envelope into
        # pending.json — `humanSummary` (plain-language headline), `escalationType`
        # ("regression"|"scope"|"cap") and `technicalDetail` (raw reason + command).
        # Pass them through verbatim so the front end can render type-appropriate
        # copy + tuck the raw detail behind a disclosure. Absent ⇒ None (the
        # renderer degrades to the bare `question` text). Read-only.
        gate = None
        if awaiting and isinstance(pending, dict):
            pstage = pending.get("stage")
            if pstage:
                stage = pstage
            if not question:
                question = pending.get("question")
            gate = {
                "humanSummary": pending.get("humanSummary"),
                "escalationType": pending.get("escalationType"),
                "technicalDetail": pending.get("technicalDetail"),
            }
            # only surface the gate object if it carries at least one new field
            # (so a plain pre-harness pending.json renders exactly as before).
            if not any(v for v in gate.values()):
                gate = None
        elif running and not paused:
            # BUG-017: state.json.stage is the RESUME pointer — it lags the stage a
            # running mission is actually executing (a card otherwise sits in the
            # PREVIOUS column for the whole of Research/Implement; on a slow engine
            # it's blatant, and a fast stage never lights up its column at all). For
            # a RUNNING, non-gated mission the truer in-flight stage is in
            # events.jsonl: the latest `stage_start` not yet closed by a `stage_done`
            # / subsequent `stage_start`. Use it as the column; fall back to
            # state.json.stage when there are no stage events. Read-only — state.json
            # semantics are untouched (it stays the resume pointer). The
            # awaiting-human → pending.json.stage rule above is left unchanged.
            inflight = _inflight_stage(events)
            if inflight:
                stage = inflight

        estimate = _load_json(os.path.join(d, "estimate.json"))
        est = estimate if isinstance(estimate, dict) else {}
        pills = board.pills_from_estimate(est)
        # The chosen engine (S67): file.sh persists state.json.workerBin. S78
        # CHANGE 4 needs it BEFORE model_mix so the displayed mix reflects the
        # per-engine resolution (a copilot mission is opus-safe ⇒ every row opus).
        # Read it here (the card field below reuses this value).
        engine = state.get("workerBin")
        if not (isinstance(engine, str) and engine.strip()):
            engine = None
        # Mission-log-grounding round: the model mix is now driven PURELY by what
        # estimate.json carries (one row per stage present in `models`). A logged
        # bug walks the FULL pipeline (Research grounding → Validate → …) so its
        # estimate scores all six stages and the table shows Research + Validate
        # too; the old is_bug row-drop is gone (a real fast-track bug's estimate
        # simply omits those keys, so no empty rows). See board.model_mix_from_estimate.
        model_mix = board.model_mix_from_estimate(est, engine=engine)

        # Mission-log-grounding round: a logged bug runs Research in a scoped
        # GROUNDING mode (run.sh cmd_research short-circuits to
        # cmd_research_grounding for origin=="log", fallback type=="bug") — it
        # anchors the symptom to the EXISTING code rather than doing full
        # question-fan-out research. Surface a `groundingResearch` flag so the
        # front end can label the Research pass "grounding (scoped to existing
        # code)" on the same generic card — no new card type. Mirror run.sh's
        # exact condition: origin=="log" OR type=="bug".
        origin = state.get("origin")
        origin = origin if (isinstance(origin, str) and origin.strip()) else None
        grounding_research = (origin == "log"
                              or (state.get("type") or "feature") == "bug")

        # S109: the launched-app record `lcars launch` writes into the mission dir
        # (launch.json). It's an ad-hoc action, NOT a pipeline artifact, so it's
        # purely ADDITIVE: present ⇒ a small `launch` {status,target,url,message}
        # rides the card so the Verify dialog can show launching→running→failed
        # with a clickable URL + a Stop affordance; ABSENT ⇒ no `launch` key at
        # all (a mission that was never launched renders byte-identically to
        # before). The github adapter never reads launch.json, so its shape is
        # unchanged. Writing launch.json into the mission dir moves the adapter
        # fingerprint, so the board/SSE reflects the state change for free.
        lj = _load_json(os.path.join(d, "launch.json"))
        launch = None
        if isinstance(lj, dict):
            launch = {
                "status": lj.get("status"),
                "target": lj.get("target"),
                "url": lj.get("url"),
                "message": lj.get("message"),
            }

        # S113: the ACTUAL usage pill (display-only). S112 appends one usage
        # record per cold-worker spawn to usage.json (JSONL). We show the ACTUAL
        # cost beside the ESTIMATE only for a mission at Verify or Done WITH usage
        # present — the pipeline has actually spent by then. ADDITIVE: an absent
        # usage.json (any pre-verify mission, or a pre-round mission) adds NO
        # `actual` key at all, so the card/board payload is byte-identical to
        # before this round. We MIRROR run.sh cmd_usage's summing (board.sum_usage)
        # so the pill and the CLI readout agree; we never mutate usage.json /
        # estimate.json (display-only). The github adapter never reaches here (its
        # own _card), so its shape is unchanged.
        if board.normalise_stage(stage) in ("verify", "done"):
            usage_totals = board.sum_usage(
                _load_jsonl(os.path.join(d, "usage.json")))
            actual = board.actual_pill(usage_totals)
            if actual is not None:
                pills["actual"] = actual

        plan = _load_json(os.path.join(d, "plan.json"))
        waves = _load_json(os.path.join(d, "waves.json"))

        tickets = _tickets(plan, waves, events, d)
        # S134 parity: a single-ticket mission has NO ticket rows, so its lone
        # ticket's proof-of-work rides the mission itself (None → key omitted).
        contract_proof = _contract_proof(plan, waves, d)
        progress = _progress(waves, events) if board.normalise_stage(stage) == "implement" else None

        # UX-24: active run time (wall-clock since the first stage_start, minus
        # every awaiting-human / paused interval). Cheap (one pass over events we
        # already loaded) so it rides on the card as well as the detail. `now` is
        # real wall-clock here; the computation lives in board.active_seconds,
        # which the tests drive with an injected `now`.
        # BUG-047: anchor the live front-end clock on the SAME server `now` used to
        # compute active_seconds. The front end shows activeSeconds + (clientNow -
        # activeSecondsAt) while running, so a card re-opened mid-stage shows true
        # elapsed instead of re-basing from a snapshot frozen at the last stage
        # boundary. Client/server share the host clock, so this is seconds-accurate.
        now = time.time()
        active_seconds = board.active_seconds(events, now=now)
        active_seconds_at = now

        # S114: the REAL liveness signal. run.sh's hang guard maintains
        # worker-liveness.json ({stage, startedAt, lastOutputTs, outputBytes,
        # state}) for the LIVE worker and REMOVES it on exit (normal or hung), so
        # the file's mere presence means "a worker is producing/thinking/quiet
        # right now". We surface it as an additive `liveness` field with the
        # QUIET-SECONDS staleness computed SERVER-SIDE (now - lastOutputTs) so the
        # client needn't. Gated on `running` (a live driver lock) as well as the
        # file, so a stale file left by a hard-crashed process can NEVER show a
        # fake pulse — a dead worker shows nothing. ABSENT (no file / not running)
        # ⇒ NO `liveness` key at all, so the card/board payload is byte-identical
        # to before this round. The github adapter never reaches here.
        liveness = _liveness(d, running, now) if running else None

        # GitHub issue number may be the literal null / absent.
        issue = state.get("githubIssue")
        if isinstance(issue, str) and issue.isdigit():
            issue = int(issue)
        if not isinstance(issue, int):
            issue = None

        # The chosen engine (S67): `engine` was read above (it is also required by
        # S78 CHANGE 4's per-engine model mix). It surfaces on the card/detail as
        # "claude"/"copilot" rather than None; absent ⇒ None (no field on disk).

        # UX-28: a logged-bug child mission records its parent's id in
        # state.json.parentMission (lcars log links a bug to the parent it was
        # found against). Surface it as `parentMission` (string id) so the front
        # end can render "log bug · child of #<parent>"; a normal mission has no
        # such field on disk ⇒ None. Read-only — state.json is never rewritten.
        parent_mission = state.get("parentMission")
        if not (isinstance(parent_mission, str) and parent_mission.strip()):
            parent_mission = None

        # BUG-033: a logged-bug child carries its parent's GitHub issue number on
        # disk (state.json.parentIssue). Surface it so the "child of #<n>" badge
        # survives the parent merging off the active board (the front-end
        # ISSUE_BY_ID index only resolves ACTIVE cards). Absent ⇒ None.
        parent_issue = state.get("parentIssue")
        if isinstance(parent_issue, str) and parent_issue.isdigit():
            parent_issue = int(parent_issue)
        if not isinstance(parent_issue, int):
            parent_issue = None

        # S75: the Verify PR lifecycle. Verify auto-opens the PR and records
        # prUrl/prNumber + a `review` sub-state ("open" while in review, "merged"
        # once approve/GitHub merges). Surface them so the card/Verify modal can
        # show the PR link and the in-review state, and the primary action can be
        # "Merge PR". Absent ⇒ None/None/None (a mission not yet in review).
        pr_url = state.get("prUrl")
        if not (isinstance(pr_url, str) and pr_url.strip()):
            pr_url = None
        pr_number = state.get("prNumber")
        if isinstance(pr_number, str) and pr_number.isdigit():
            pr_number = int(pr_number)
        if not isinstance(pr_number, int):
            pr_number = None
        # BUG-036: a blank "PR #". When prNumber is absent on disk but a prUrl is
        # recorded, derive the number from the prUrl trailing /pull/<n> so the
        # Verify dialog never renders a bare "PR #" while the link is present.
        if pr_number is None and pr_url:
            pr_number = _pr_number_from_url(pr_url)
        review = state.get("review")
        if not (isinstance(review, str) and review.strip()):
            review = None

        # S76: the main-ahead reconcile sub-state. While a verify-stage mission with
        # no PR yet is reconciling with the updated base (merging / re-testing the
        # merged branch / self-healing via Mission Log children / escalated), run.sh
        # records reconcileStatus in {"merging","retesting","healing","escalated"}.
        # Surface it so the card can show a "reconciling with main / re-verifying"
        # note. Absent ⇒ None (a mission not reconciling). The github adapter forces
        # None (ADR-006: a read-only forge view cannot see this private sub-state).
        reconcile_status = state.get("reconcileStatus")
        if not (isinstance(reconcile_status, str) and reconcile_status.strip()):
            reconcile_status = None

        # BUG-067 SHARED CONTRACT: alongside reconcileStatus the engine persists
        # `reconcileNote` (a human-readable summary to show on the card — e.g.
        # "Reconciled main … re-tested green (8/8). Reapprove to merge." or the
        # merge-failed reason) and `reconcileMergeSha` (the reconciled tip). The
        # new statuses `awaiting-reapprove` (heal converged, awaiting the human's
        # reapprove) and `merge-failed` (push/merge failed — surfaced, not silent)
        # pass through verbatim on reconcileStatus above. Surface both note/sha so
        # the card/detail can render the gate + the merge-failed outcome with the
        # exact summary; absent ⇒ None (present, non-crashing). The github adapter
        # forces None (ADR-006: a read-only forge view can't see this).
        reconcile_note = state.get("reconcileNote")
        if not (isinstance(reconcile_note, str) and reconcile_note.strip()):
            reconcile_note = None
        reconcile_merge_sha = state.get("reconcileMergeSha")
        if not (isinstance(reconcile_merge_sha, str)
                and reconcile_merge_sha.strip()):
            reconcile_merge_sha = None

        card = {
            "id": mid,
            "issue": issue,
            "title": state.get("title") or mid,
            "type": state.get("type") or "feature",
            "engine": engine,
            "stage": stage,
            "awaiting": awaiting,
            "paused": paused,
            "running": running,
            # BUG-062: was a run actually launched? (events emitted OR a live
            # driver lock). A filed-but-held mission — parked at estimate-review
            # with only estimate.json — reads False, so its card shows Start, not
            # Pause. The front end gates the Start/Pause control on this.
            "dispatched": dispatched,
            # `queued` (S73): true iff this mission is SCHEDULED in an active
            # resolve-logs batch but has not started driving its wave yet —
            # resolve-logs.sh stamps state.json.queued:true while a child waits
            # and clears it when the child begins (or finishes). Derived straight
            # from the persisted flag so the board can render the "waiting to go"
            # pill (UX-29). Absent ⇒ False (never None), so the front end can rely
            # on the boolean. The github adapter forces False (ADR-006).
            "queued": _truthy(state.get("queued")),
            "question": question if awaiting else None,
            # BUG-027: the legible, type-aware gate envelope (humanSummary /
            # escalationType / technicalDetail) when awaiting; None otherwise.
            "gate": gate if awaiting else None,
            "linked": _truthy(state.get("linked")),
            # Mission-log-grounding round: `origin` ("log" for a bug filed via
            # `lcars log", else None) + `groundingResearch` (True when the
            # Research pass is the scoped grounding one). The front end shows a
            # small "grounding" descriptor on the Research stage of such a card.
            "origin": origin,
            "groundingResearch": grounding_research,
            # UX-28: parent mission id for a logged-bug child (None when not a
            # logged-bug child). The github adapter forces None (ADR-006).
            "parentMission": parent_mission,
            # BUG-033: the parent's issue number, carried on the child so its
            # "child of #<n>" badge survives the parent leaving the active board.
            "parentIssue": parent_issue,
            # S75 Verify PR lifecycle: the open PR + the in-review/merged state.
            "prUrl": pr_url,
            "prNumber": pr_number,
            "review": review,
            # S76: the main-ahead reconcile sub-state (None when not reconciling).
            "reconcileStatus": reconcile_status,
            # BUG-067: the human-readable reconcile summary + the reconciled tip
            # sha, surfaced so the board can render the awaiting-reapprove gate and
            # the merge-failed outcome with the exact note (None when absent).
            "reconcileNote": reconcile_note,
            "reconcileMergeSha": reconcile_merge_sha,
            "pills": pills,
            "modelMix": model_mix,
            "progress": progress,
            "tickets": tickets,
            "activeSeconds": active_seconds,
            # BUG-047: the server wall-clock (seconds) at which activeSeconds was
            # computed — the anchor the front-end live tick re-bases from.
            "activeSecondsAt": active_seconds_at,
            "_created": state.get("created") or "",
        }
        # S109: additive — only present a `launch` field when launch.json exists
        # (a never-launched mission's card is byte-identical to before).
        if launch is not None:
            card["launch"] = launch
        # S114: additive — only present `liveness` while a live worker's sidecar
        # file exists (byte-identical to before for every idle/finished mission).
        if liveness is not None:
            card["liveness"] = liveness
        # S134 parity: additive — only present `contractProof` for a single-ticket
        # mission whose lone ticket has S133 proof artifacts. ABSENT (not null)
        # otherwise, so a pre-S133 / multi-ticket mission's card is byte-identical.
        if contract_proof is not None:
            card["contractProof"] = contract_proof
        # Park & Align (S137): additive — a PARKED mission (filed pre-PRD via
        # `lcars file --park`) carries state.json.prdPending:true; surface it as
        # `prdPending` so the board renders the ◇ STANDBY badge + START ALIGNMENT
        # control (a parked mission has no PRD, so it must never be runnable) and
        # suppresses the estimate pills (it has no estimate.json). ABSENT (not
        # false) for every non-parked mission, so every existing card payload is
        # BYTE-IDENTICAL. The github adapter never reads this local-only field.
        if _truthy(state.get("prdPending")):
            card["prdPending"] = True
        return card

    def _activity(self, d):
        """Render each event to a concise feed entry for the detail view."""
        feed = []
        for ev in _load_jsonl(os.path.join(d, "events.jsonl")):
            if not isinstance(ev, dict):
                continue
            entry = {
                "ts": ev.get("ts"),
                "stage": ev.get("stage"),
                "type": ev.get("type"),
                "detail": ev.get("detail"),
                "text": _human(ev),
            }
            # S134: pass the event's structured `data` through (additive) so the
            # front end can read the worker-session number (ticket_attempt
            # phase=tdd, attempt=N), the bounced gate name, and the park category
            # — the sub-structure that replaces the retired role distinction.
            # Absent/empty ⇒ no `data` key, so a pre-round event is unchanged.
            data = ev.get("data")
            if isinstance(data, dict) and data:
                entry["data"] = data
            feed.append(entry)
        return feed


# --- BUG-017: the in-flight stage from events.jsonl --------------------------
# state.json.stage is the resume pointer and LAGS the running stage. The truer
# in-flight stage for a running, non-gated mission is the latest `stage_start`
# event not yet closed by a `stage_done` (or superseded by a later `stage_start`).
# events.jsonl is chronological (append-only; run.sh emit_event), so a single
# forward walk suffices: a `stage_start` opens an in-flight stage; the matching
# `stage_done` (same stage) closes it; a later `stage_start` supersedes any still
# open. Returns the canonical column key, or None when there are no stage events
# (caller falls back to state.json.stage). Crash-proof: any malformed row skipped.
def _inflight_stage(events):
    inflight = None
    for ev in (events or []):
        if not isinstance(ev, dict):
            continue
        typ = ev.get("type")
        st = ev.get("stage")
        if typ == "stage_start" and st:
            inflight = st
        elif typ == "stage_done" and st:
            # close the open stage (whether or not it matches — a stage_done means
            # that stage finished; the next stage_start opens the following one).
            if inflight is not None and board.normalise_stage(st) == board.normalise_stage(inflight):
                inflight = None
    if inflight is None:
        return None
    return board.normalise_stage(inflight)


# --- ticket + progress derivation (shared shape; mirrors render.sh ideas) ----
def _tickets(plan, waves, events, mission_dir=None):
    """Ordered ticket rows with sub-issue numbers and an event-derived state.

    A single-ticket mission shows none (the lone ticket reuses the mission's own
    issue, per the Schedule fast-path) — same "no nested rows" rule as the card.

    S134: each row ALSO carries an additive `proof` object read from the ticket's
    S133 gate artifacts (see `_ticket_proof`) so the Verify surfaces can render
    the contract-changes story. A pre-S133 ticket (no such artifacts) gets NO
    `proof` key at all, so its row is byte-identical to before this round.
    """
    order = []
    titles = {}
    if isinstance(plan, list):
        for t in plan:
            if isinstance(t, dict) and t.get("id"):
                order.append(t["id"])
                titles[t["id"]] = t.get("title") or t["id"]
    issues = {}
    if isinstance(waves, list):
        for w in waves:
            for t in (w.get("tickets") or []) if isinstance(w, dict) else []:
                if isinstance(t, dict) and t.get("id"):
                    if t["id"] not in order:
                        order.append(t["id"])
                    issues[t["id"]] = t.get("issue")
    if len(order) <= 1:
        return []

    states = _ticket_states(events)
    rows = []
    for tid in order:
        row = {
            "id": tid,
            "issue": issues.get(tid),
            "title": titles.get(tid, tid),
            "state": states.get(tid, "pending"),
        }
        proof = _ticket_proof(mission_dir, tid)
        if proof is not None:
            row["proof"] = proof
        rows.append(row)
    return rows


# --- S134: the per-ticket proof-of-work contract (from the S133 gate artifacts)
# The unified TDD Implementer's work is proven post-hoc and recorded to
# tickets/<id>/{result.json (v2), flip-flop.json, test-edits.json}. This reads
# those into the adapter-neutral shape the Verify surfaces render:
#     {newTests: int, declaredEdits: [{path, reason}], flipFlop: {verdict, reason}}
# verdict is the human-facing chip: "proven" | "n-a" | "fail" | "inconclusive";
# reason carries the not-applicable / rejection reason (None for a clean PROVEN).
# ADDITIVE: a ticket with NO gate artifacts at all (a pre-S133 mission) returns
# None, so its row is byte-identical to before this round. Mirrors run.sh's
# verify_contract_readout so the CLI and the board read the SAME source.
def _ticket_proof(mission_dir, tid):
    if not mission_dir:
        return None
    td = os.path.join(mission_dir, "tickets", tid)
    ff = _load_json(os.path.join(td, "flip-flop.json"))
    te = _load_json(os.path.join(td, "test-edits.json"))
    res = _load_json(os.path.join(td, "result.json"))
    if not isinstance(ff, dict) and not isinstance(te, list):
        return None  # pre-S133 ticket — no proof artifacts

    # declared edits: the durable {path, reason} list (falls back to result.testEdits)
    src = te if isinstance(te, list) else (
        (res.get("testEdits") if isinstance(res, dict) else None) or [])
    edits = [{"path": e.get("path"), "reason": e.get("reason", "") or ""}
             for e in (src or []) if isinstance(e, dict) and e.get("path")]

    new_tests = 0
    if isinstance(res, dict) and isinstance(res.get("newTests"), list):
        new_tests = len([p for p in res["newTests"] if isinstance(p, str) and p])

    verdict = reason = None
    decl = res.get("flipFlop") if isinstance(res, dict) else None
    ffv = ff.get("verdict") if isinstance(ff, dict) else None
    if decl == "not-applicable" or ffv == "skipped":
        verdict = "n-a"
        reason = (res.get("flipFlopReason") if isinstance(res, dict) else None) \
            or (ff.get("reason") if isinstance(ff, dict) else None)
    elif ffv == "pass":
        verdict = "proven"
    elif ffv in ("fail", "inconclusive"):
        verdict = ffv
        reason = ff.get("reason") if isinstance(ff, dict) else None

    proof = {"newTests": new_tests, "declaredEdits": edits}
    if verdict is not None:
        proof["flipFlop"] = {"verdict": verdict, "reason": reason}
    return proof


# --- S134 parity: MISSION-LEVEL proof for a SINGLE-ticket mission -------------
# A single-ticket mission carries NO ticket rows (`_tickets` returns [] — the lone
# slice reuses the mission's own issue, per the Schedule fast-path), so the
# board's per-row proof render has nothing to hang the flip-flop verdict / contract
# amendments on, while the CLI verify-summary reads the lone ticket directly and
# DOES show them. To restore CLI↔UI parity we surface the lone ticket's proof at
# MISSION level (the same `_ticket_proof` shape, PLUS its id + title) as the card's
# `contractProof` field. Rules that protect the round's invariants:
#   * returns None unless there is EXACTLY ONE ticket — a multi-ticket mission
#     carries its proof on the per-ticket rows, so this stays None → NO
#     double-render (the card never sets contractProof for a multi-ticket mission);
#   * returns None when that lone ticket has NO S133 proof artifacts (a pre-S133
#     mission), so the caller omits the key ENTIRELY → byte-identical render.
def _contract_proof(plan, waves, mission_dir):
    order = []
    titles = {}
    if isinstance(plan, list):
        for t in plan:
            if isinstance(t, dict) and t.get("id"):
                if t["id"] not in order:
                    order.append(t["id"])
                titles.setdefault(t["id"], t.get("title") or t["id"])
    if isinstance(waves, list):
        for w in waves:
            for t in (w.get("tickets") or []) if isinstance(w, dict) else []:
                if isinstance(t, dict) and t.get("id") and t["id"] not in order:
                    order.append(t["id"])
    if len(order) != 1:
        return None
    tid = order[0]
    proof = _ticket_proof(mission_dir, tid)
    if proof is None:
        return None
    out = dict(proof)
    out["id"] = tid
    out["title"] = titles.get(tid, tid)
    return out


def _ticket_states(events):
    """green→done, flagged→flagged, the last started-but-not-finished→in-progress."""
    states = {}
    last_started = None
    for ev in events:
        if not isinstance(ev, dict):
            continue
        tid = (ev.get("data") or {}).get("ticket")
        if not tid:
            continue
        t = ev.get("type")
        if t == "ticket_start":
            if states.get(tid) not in ("done", "flagged"):
                states[tid] = "in-progress"
            last_started = tid
        elif t == "ticket_green":
            states[tid] = "done"
        elif t == "ticket_flagged":
            states[tid] = "flagged"
    return states


def _progress(waves, events):
    """The Implement progress strip: wave x/y, ticket done/total."""
    waves_total = len(waves) if isinstance(waves, list) else None
    tickets_total = 0
    if isinstance(waves, list):
        for w in waves:
            tickets_total += len((w.get("tickets") or [])) if isinstance(w, dict) else 0
    cur_wave = None
    # BUG-050: count DISTINCT tickets that reached green — a single ticket can
    # emit MULTIPLE `ticket_green` events (goes green → ticket_replay_conflict →
    # serial rebuild → goes green AGAIN), so a naive per-event increment over-
    # counts ("TICKET 2/1", a >100% bar). Collect the ticket id from each
    # ticket_green into a set (same `data.ticket` shape _ticket_states reads) and
    # take its size; then defensively clamp to tickets_total so it can never
    # exceed the total even on unexpected event streams.
    green_tickets = set()
    for ev in events:
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "wave_start":
            w = (ev.get("data") or {}).get("wave")
            if isinstance(w, int):
                cur_wave = w
        elif ev.get("type") == "ticket_green":
            tid = (ev.get("data") or {}).get("ticket")
            if tid:
                green_tickets.add(tid)
    tickets_done = len(green_tickets)
    if tickets_total:
        tickets_done = min(tickets_done, tickets_total)
    if cur_wave is None and waves_total:
        cur_wave = 1
    wt = waves_total or "?"
    tt = tickets_total or "?"
    label = "WAVE %s/%s · TICKET %s/%s" % (cur_wave or "?", wt, tickets_done, tt)
    return {
        "wave": cur_wave,
        "wavesTotal": waves_total,
        "ticketsDone": tickets_done,
        "ticketsTotal": tickets_total,
        "label": label,
    }


_HUMAN = {
    "stage_start": "▶ %s", "stage_done": "✔ %s", "wave_start": "〜 %s",
    "ticket_start": "• %s", "ticket_attempt": "↻ %s", "ticket_green": "✓ %s",
    "ticket_flagged": "⚑ %s", "gate": "⏸ %s", "error": "✖ %s",
}


def _human(ev):
    t = ev.get("type")
    detail = ev.get("detail") or ""
    fmt = _HUMAN.get(t)
    return (fmt % detail) if fmt else detail


# --- BUG-036: derive a PR number from a PR url (trailing /pull/<n>) ----------
_PR_NUM = re.compile(r"/pull/(\d+)")


def _pr_number_from_url(url):
    """The PR number from a GitHub PR url's trailing /pull/<n>, or None."""
    if not isinstance(url, str):
        return None
    m = _PR_NUM.search(url)
    return int(m.group(1)) if m else None


# --- jq-free-equivalent loaders (lenient: bad/absent file → None) ------------
def _load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _load_jsonl(path):
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return rows


def _truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")


# --- S67 BUG-A: live driver detection (the `running` flag) -------------------
# run.sh acquires a per-mission driver lock at $MISSION_DIR/driver.lock (a DIR
# whose `pid` file holds the live driver's PID; see acquire_driver_lock in
# run.sh). A mission is `running` iff that lock is held by a LIVE process. We read
# the pid and probe it with os.kill(pid, 0): no signal is sent, but a dead/own-
# unreachable pid raises, which we treat as not-running. A STALE lock (the driver
# crashed without releasing) thus reads as running == False, matching run.sh's own
# reclaim rule. Crash-proof: any read/parse/probe error → False (never raises).
def _liveness(mission_dir, running, now):
    """S114: the live worker's liveness sidecar → an additive card field, or None.

    run.sh's hang guard writes worker-liveness.json for the CURRENT cold worker and
    removes it on exit, so its presence means a worker is live. We echo its fields
    and compute the QUIET-SECONDS staleness server-side (now - lastOutputTs) so the
    front end never has to. Returns None when the file is absent, malformed, or the
    mission isn't running (a stale file after a hard crash never shows a pulse).
    Crash-proof: any malformed shape degrades to None (never raises).
    """
    if not running:
        return None
    data = _load_json(os.path.join(mission_dir, "worker-liveness.json"))
    if not isinstance(data, dict):
        return None
    state = data.get("state")
    if state not in ("thinking", "producing", "quiet"):
        return None
    last_out = data.get("lastOutputTs")
    started = data.get("startedAt")
    try:
        quiet_seconds = int(max(0.0, now - float(last_out)))
    except (TypeError, ValueError):
        quiet_seconds = 0
    out = {
        "state": state,
        "stage": data.get("stage") or None,
        "startedAt": started if isinstance(started, (int, float)) else None,
        "lastOutputTs": last_out if isinstance(last_out, (int, float)) else None,
        "outputBytes": data.get("outputBytes")
        if isinstance(data.get("outputBytes"), (int, float)) else None,
        # server-side staleness so the client renders "quiet Ns" without its own clock.
        "quietSeconds": quiet_seconds,
    }
    return out


def _driver_running(mission_dir):
    pidf = os.path.join(mission_dir, "driver.lock", "pid")
    try:
        with open(pidf) as fh:
            raw = fh.read().strip()
    except OSError:
        return False
    try:
        pid = int(raw)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        # ESRCH — no such process → stale lock → not running.
        return False
    except PermissionError:
        # EPERM — the process EXISTS but is owned by another user; it is alive,
        # so the mission is running.
        return True
    except OSError:
        return False
    return True


# --- S70-A: repo identity (which working tree am I attached to) --------------
# Derive owner/name from the git ORIGIN remote, WORKTREE-SAFE. In a git worktree
# `<repo_root>/.git` is a FILE (a `gitdir:` pointer), not a dir, so a direct
# `.git/config` read fails and would wrongly fall back to the dir basename. So
# the resolution chain is:
#   1. shell `git -C <root> config --get remote.origin.url` — understands
#      worktrees (resolves the real gitdir), the primary source of truth.
#   2. parse `.git/config` directly — non-worktree, git-less fallback.
#   3. the directory basename — last resort.
# stdlib-only and crash-proof: a missing/unauthed git, no remote, garbled config
# or no repo root all degrade gracefully — this NEVER raises.
_REMOTE_HDR = re.compile(r'^\[remote "([^"]+)"\]')
_URL_LINE = re.compile(r'^\s*url\s*=\s*(.+?)\s*$')
# owner/name from either git@host:owner/name(.git) or https://host/owner/name(.git)
_OWNER_NAME = re.compile(r'[:/]([^/:]+/[^/:]+?)(?:\.git)?/?$')


def _repo_identity(repo_root, git_url_reader=None):
    # 1. worktree-safe: ask git for the origin url (resolves the real gitdir).
    url = (git_url_reader or _git_origin_url)(repo_root)
    name = _owner_name_from_url(url)
    if name:
        return name
    # 2. fallback: parse .git/config directly (non-worktree, no git on PATH).
    name = _repo_from_git_config(repo_root)
    if name:
        return name
    # 3. last resort: the working-tree directory basename.
    base = os.path.basename(os.path.normpath(repo_root or "")) or repo_root or ""
    return base


def _git_origin_url(repo_root):
    """The origin remote URL via `git`, worktree-safe. None on any failure.

    Injectable: tests stub the reader arg to _repo_identity so they never depend
    on a real git/network. Here we shell `git` but swallow every error class —
    missing binary, non-zero exit (no remote / not a repo), timeout — so the
    board never crashes on repo identity.
    """
    if not repo_root:
        return None
    try:
        out = subprocess.check_output(
            ["git", "-C", repo_root, "config", "--get", "remote.origin.url"],
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        url = out.decode("utf-8", "replace").strip()
    except Exception:
        return None
    return url or None


def _owner_name_from_url(url):
    if not url:
        return None
    on = _OWNER_NAME.search(url)
    return on.group(1) if on else None


def _repo_from_git_config(repo_root):
    if not repo_root:
        return None
    cfg = os.path.join(repo_root, ".git", "config")
    try:
        with open(cfg) as fh:
            lines = fh.readlines()
    except OSError:
        return None
    # collect every remote's url, then prefer origin.
    urls = {}
    cur = None
    for line in lines:
        m = _REMOTE_HDR.match(line.strip())
        if m:
            cur = m.group(1)
            continue
        if cur is not None and line.strip().startswith("["):
            cur = None
        if cur is not None:
            um = _URL_LINE.match(line)
            if um:
                urls[cur] = um.group(1)
    url = urls.get("origin") or (next(iter(urls.values())) if urls else None)
    return _owner_name_from_url(url)


# --- S70-B2: ADRs (parse adr.md into [{title, body}]) ------------------------
# adr.md is COMPLEX-mission-only (file.sh writes it from Align). Structure:
#   # Architecture Decision Records: <title>
#   ## ADR-001: <short decision title>
#   **Context:** ...  **Decision:** ...  (etc.)
# Each `## ADR-NNN:` (or any `## ` heading after the doc title) opens one record;
# its body is everything up to the next `## ` heading. Absent file → None.
def _adrs_from_file(path):
    try:
        with open(path) as fh:
            text = fh.read()
    except OSError:
        return None
    rows = []
    title = None
    body_lines = []

    def flush():
        if title is not None:
            rows.append({"title": title, "body": "\n".join(body_lines).strip()})

    for line in text.splitlines():
        if line.startswith("## "):
            flush()
            title = line[3:].strip()
            body_lines = []
        elif title is not None:
            body_lines.append(line)
        # lines before the first `## ` (the `# …` doc title) are ignored.
    flush()
    return rows or None


# --- S70-B3: verbatim acceptance criteria (parse prd.md) ---------------------
# prd.md carries a `**Acceptance Criteria:**` section (file.sh requires it),
# followed by `- ` bullets, ending at the next `**…:**` section header. Bullets
# are plain (`- text`); markdown checkboxes (`- [x]`/`- [ ]`) are tolerated and
# map to the `done` flag. Absent file / missing section → None.
_AC_HEADER = re.compile(r'^\s*\*\*Acceptance Criteria:\*\*\s*$', re.I)
_SECTION_HEADER = re.compile(r'^\s*\*\*[^*]+:\*\*\s*$')
_BULLET = re.compile(r'^\s*[-*]\s+(.*\S)\s*$')
_CHECKBOX = re.compile(r'^\[( |x|X)\]\s*(.*)$')


def _read_text(path):
    """The verbatim contents of a text file, or "" when it is absent/unreadable."""
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return ""


def _criteria_from_prd(path):
    try:
        with open(path) as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    rows = []
    in_ac = False
    for line in lines:
        if _AC_HEADER.match(line):
            in_ac = True
            continue
        if in_ac and _SECTION_HEADER.match(line):
            break  # next section ends the criteria block
        if in_ac:
            mb = _BULLET.match(line)
            if mb:
                text = mb.group(1).strip()
                done = False
                cb = _CHECKBOX.match(text)
                if cb:
                    done = cb.group(1).lower() == "x"
                    text = cb.group(2).strip()
                if text:
                    rows.append({"text": text, "done": done})
    return rows or None
