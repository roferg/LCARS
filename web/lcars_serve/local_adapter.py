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

from . import board


class LocalAdapter(object):
    name = "local"

    def __init__(self, repo_root):
        # repo_root is the working tree; mission state lives under .git/lcars.
        self.repo_root = repo_root
        self.missions_dir = os.path.join(repo_root, ".git", "lcars", "missions")

    # -- the public surface ---------------------------------------------------
    def board(self):
        cards = [self._card(d) for d in self._mission_dirs()]
        cards = [c for c in cards if c is not None]
        # newest-first by created (string ISO sorts correctly); ties on id.
        cards.sort(key=lambda c: (c.get("_created") or "", c["id"]), reverse=True)
        for c in cards:
            c.pop("_created", None)
        return board.assemble(cards)

    def mission(self, mid):
        d = os.path.join(self.missions_dir, mid)
        if not os.path.isdir(d):
            return None
        card = self._card(d)
        if card is None:
            return None
        card.pop("_created", None)
        card["activity"] = self._activity(d)
        return card

    def fingerprint(self):
        """A cheap state-change signature: max mtime over every mission file.

        The live channel polls this; it changes the instant any state.json /
        pending.json / events.jsonl / etc. is rewritten by the harness.
        """
        latest = 0.0
        if not os.path.isdir(self.missions_dir):
            return "0"
        for d in self._mission_dirs():
            for fn in os.listdir(d):
                try:
                    latest = max(latest, os.path.getmtime(os.path.join(d, fn)))
                except OSError:
                    pass
        return "%.6f" % latest

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

        # status.sh's gate rule: when awaiting-human and a pending.json exists,
        # the in-flight column comes from pending.json.stage, not state.stage.
        pending = _load_json(os.path.join(d, "pending.json"))
        if awaiting and isinstance(pending, dict):
            pstage = pending.get("stage")
            if pstage:
                stage = pstage
            if not question:
                question = pending.get("question")

        estimate = _load_json(os.path.join(d, "estimate.json"))
        pills = board.pills_from_estimate(estimate if isinstance(estimate, dict) else {})

        plan = _load_json(os.path.join(d, "plan.json"))
        waves = _load_json(os.path.join(d, "waves.json"))
        events = _load_jsonl(os.path.join(d, "events.jsonl"))

        tickets = _tickets(plan, waves, events)
        progress = _progress(waves, events) if board.normalise_stage(stage) == "implement" else None

        # GitHub issue number may be the literal null / absent.
        issue = state.get("githubIssue")
        if isinstance(issue, str) and issue.isdigit():
            issue = int(issue)
        if not isinstance(issue, int):
            issue = None

        return {
            "id": mid,
            "issue": issue,
            "title": state.get("title") or mid,
            "type": state.get("type") or "feature",
            "stage": stage,
            "awaiting": awaiting,
            "paused": paused,
            "question": question if awaiting else None,
            "linked": _truthy(state.get("linked")),
            "pills": pills,
            "progress": progress,
            "tickets": tickets,
            "_created": state.get("created") or "",
        }

    def _activity(self, d):
        """Render each event to a concise feed entry for the detail view."""
        feed = []
        for ev in _load_jsonl(os.path.join(d, "events.jsonl")):
            if not isinstance(ev, dict):
                continue
            feed.append({
                "ts": ev.get("ts"),
                "stage": ev.get("stage"),
                "type": ev.get("type"),
                "detail": ev.get("detail"),
                "text": _human(ev),
            })
        return feed


# --- ticket + progress derivation (shared shape; mirrors render.sh ideas) ----
def _tickets(plan, waves, events):
    """Ordered ticket rows with sub-issue numbers and an event-derived state.

    A single-ticket mission shows none (the lone ticket reuses the mission's own
    issue, per the Schedule fast-path) — same "no nested rows" rule as the card.
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
        rows.append({
            "id": tid,
            "issue": issues.get(tid),
            "title": titles.get(tid, tid),
            "state": states.get(tid, "pending"),
        })
    return rows


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
    tickets_done = 0
    for ev in events:
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "wave_start":
            w = (ev.get("data") or {}).get("wave")
            if isinstance(w, int):
                cur_wave = w
        elif ev.get("type") == "ticket_green":
            tickets_done += 1
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
