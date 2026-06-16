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
        return {
            "repo": _repo_identity(self.repo_root, self._git_url_reader),
            "adapter": "local",
            "mode": "read-only" if self.read_only else "read-write",
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
        est = estimate if isinstance(estimate, dict) else {}
        pills = board.pills_from_estimate(est)
        model_mix = board.model_mix_from_estimate(est)

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
            "modelMix": model_mix,
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
