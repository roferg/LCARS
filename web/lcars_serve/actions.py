"""The LOCAL-BRIDGE write layer (S68).

Operator actions on the board — file / start / pause / resume / respond /
verify (approve|send-back) / log — are dispatched here. Each shells out to the
matching `lcars` skill script (ADR-002: dispatch, never reimplement Stage
logic). The harness scripts stay the single implementation of the pipeline; this
module is a thin HTTP→skill bridge.

ALL external dependencies are env-injected and stubbable: every skill path is a
key in `scripts`, and the worker engine is `worker_bin`. Tests point each path
at a recording stub and assert the dispatch (argv/stdin) without spending.

This is a LOCAL-BRIDGE concern only (ADR-006). The renderer/read path stays
adapter-neutral; a github/view-only daemon is built with NO Actions (the server
declines writes with 403), so the read build drops the write layer with no
rewrite. A write that changes `.git/lcars` moves the LocalAdapter fingerprint,
so the existing /api/events SSE loop carries the update — no second push path.

stdlib only; no pip/npm/build step (ADR-007).
"""
import os
import subprocess
import tempfile

from .local_adapter import LocalAdapter


class ActionError(Exception):
    """Raised on a bad request (status carries the HTTP code to return)."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# The env seam names the daemon resolves each skill path from (mirrors how
# serve.sh env-injects). Used by the launcher/__main__ to build the script map.
SCRIPT_ENV = {
    "file": "LCARS_FILE_SCRIPT",
    "run": "LCARS_RUN_SCRIPT",
    "pause": "LCARS_PAUSE_SCRIPT",
    "respond": "LCARS_RESPOND_SCRIPT",
    "approve": "LCARS_APPROVE_SCRIPT",
    "feedback": "LCARS_FEEDBACK_SCRIPT",
    "log": "LCARS_LOG_SCRIPT",
    "resolve": "LCARS_RESOLVE_SCRIPT",
}


# A minimal, well-formed PRD skeleton. file.sh validates that the PRD carries
# every required section (# Mission / Type / Goal / Acceptance Criteria / Out of
# Scope / Constraints) before filing. Over HTTP the conversational Align grilling
# that normally authors a rich PRD is NOT driven (see DEFERRED in the report);
# the daemon materialises this tractable skeleton from the captain's idea so the
# mission is created and lands on the board, then Align is finished in the
# console (or a later S70 endpoint).
_PRD_TEMPLATE = """# Mission: {title}

**Type:** {type}

**Goal:** {idea}

**Acceptance Criteria:** To be refined in Align.
- The behaviour described above works end to end.

**Out of Scope:** To be refined in Align.

**Constraints:** To be refined in Align.
"""


class Actions(object):
    """Dispatch operator actions to the LCARS skill scripts.

    Parameters
    ----------
    repo_root : str
        The working tree whose .git/lcars the LocalAdapter reads. Skill scripts
        run with this as cwd so their `git rev-parse` resolves the right repo.
    scripts : dict
        key -> absolute path of the skill .sh to shell out to. Keys are those in
        SCRIPT_ENV. Tests inject recording stubs here.
    worker_bin : str | None
        The cold-worker CLI (the mission "engine"). Threaded to file/run as
        $LCARS_WORKER_BIN. None leaves the host default in place.
    gh_bin : str | None
        The gh binary, threaded to every script as $LCARS_GH_BIN.
    """

    def __init__(self, repo_root, scripts, worker_bin=None, gh_bin=None):
        self.repo_root = repo_root
        self.scripts = dict(scripts or {})
        self.worker_bin = worker_bin
        self.gh_bin = gh_bin
        self._reader = LocalAdapter(repo_root)

    # -- public action surface (one per endpoint) -------------------------------
    def file_mission(self, idea, engine=None, mission_type="feature"):
        """POST /api/mission — file a new mission from a free-form idea.

        engine selects the worker CLI ($LCARS_WORKER_BIN) for this mission.
        Returns the freshly-assembled board state.
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        mtype = "bug" if str(mission_type).strip().lower() == "bug" else "feature"
        title = self._title_from_idea(idea)
        prd = _PRD_TEMPLATE.format(title=title, type=mtype, idea=idea)
        prd_path = self._tmp_prd(prd)
        env_extra = {}
        if engine:
            env_extra["LCARS_WORKER_BIN"] = engine
        try:
            self._run("file", ["--prd", prd_path], env_extra=env_extra)
        finally:
            try:
                os.unlink(prd_path)
            except OSError:
                pass
        return {"board": self._reader.board()}

    def start(self, mid, override=None):
        """POST /api/mission/<id>/start — drive the run, optional override."""
        self._require_mission(mid)
        env_extra = {}
        ov = (override or "").strip()
        if ov:
            # the plain-language override is passed through to the run driver via
            # $LCARS_MODEL_OVERRIDE (run.sh's active_model_override reads it).
            env_extra["LCARS_MODEL_OVERRIDE"] = ov
        self._run("run", ["drive", "--mission", mid], env_extra=env_extra)
        return self._mission_state(mid)

    def pause(self, mid):
        """POST /api/mission/<id>/pause."""
        self._require_mission(mid)
        self._run("pause", ["pause", mid])
        return self._mission_state(mid)

    def resume(self, mid):
        """POST /api/mission/<id>/resume."""
        self._require_mission(mid)
        self._run("pause", ["resume", mid])
        return self._mission_state(mid)

    def respond(self, mid, answer):
        """POST /api/mission/<id>/respond — answer a gate."""
        self._require_mission(mid)
        answer = (answer or "").strip()
        if not answer:
            raise ActionError(400, "missing required field: answer")
        self._run("respond", ["answer", "--mission", mid, "--answer", answer])
        return self._mission_state(mid)

    def verify(self, mid, decision, feedback=None):
        """POST /api/mission/<id>/verify — approve vs send-back.

        decision == "approve"   → approve.sh (open PR, mark done)
        decision == "send-back" → feedback.sh (--feedback note → back to Align)
        These route to TWO DIFFERENT skills.
        """
        self._require_mission(mid)
        decision = (decision or "").strip().lower()
        if decision == "approve":
            self._run("approve", ["--mission", mid])
        elif decision in ("send-back", "sendback", "send_back"):
            note = (feedback or "").strip()
            if not note:
                raise ActionError(400, "send-back requires a 'feedback' note")
            self._run("feedback", ["--mission", mid, "--feedback", note])
        else:
            raise ActionError(
                400, "decision must be 'approve' or 'send-back' (got %r)"
                % decision)
        return self._mission_state(mid)

    def log_preview(self, mid):
        """POST /api/mission/<id>/log — preview the N child bug missions.

        Read-only preview: returns the bug missions already linked to this
        parent (state.json.parentMission == mid). Authoring NEW bug PRDs from a
        free-form report is the interactive half of `lcars log` (Claude splits
        the report into PRDs) — DEFERRED to the console / a later endpoint; this
        surfaces what is already filed so the board can show the batch.
        """
        self._require_mission(mid)
        children = self._linked_children(mid)
        return {"children": children, "count": len(children)}

    def log_run(self, mid):
        """POST /api/mission/<id>/log/run — drive the logged bugs to one gate."""
        self._require_mission(mid)
        self._run("resolve", ["--parent", mid])
        return self._mission_state(mid)

    # -- internals --------------------------------------------------------------
    def _run(self, key, args, env_extra=None):
        script = self.scripts.get(key)
        if not script:
            raise ActionError(500, "no script wired for action '%s'" % key)
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        if self.worker_bin and "LCARS_WORKER_BIN" not in (env_extra or {}):
            env["LCARS_WORKER_BIN"] = self.worker_bin
        if env_extra:
            env.update(env_extra)
        cmd = ["bash", script] + list(args)
        proc = subprocess.run(cmd, cwd=self.repo_root, env=env,
                              stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            out = (proc.stdout or b"").decode("utf-8", "replace").strip()
            raise ActionError(
                502, "skill '%s' exited %d: %s" % (key, proc.returncode, out))
        return proc

    def _require_mission(self, mid):
        d = os.path.join(self.repo_root, ".git", "lcars", "missions", mid)
        if not (mid and os.path.isfile(os.path.join(d, "state.json"))):
            raise ActionError(404, "no such mission: %s" % mid)

    def _mission_state(self, mid):
        detail = self._reader.mission(mid)
        if detail is None:
            # the action may have moved it (e.g. approve → done is still present);
            # fall back to the whole board so the caller always gets fresh state.
            return {"board": self._reader.board()}
        return {"mission": detail}

    def _linked_children(self, parent):
        out = []
        missions_dir = os.path.join(self.repo_root, ".git", "lcars", "missions")
        if not os.path.isdir(missions_dir):
            return out
        for name in sorted(os.listdir(missions_dir)):
            sp = os.path.join(missions_dir, name, "state.json")
            if not os.path.isfile(sp):
                continue
            card = self._reader.mission(name)
            if card is None:
                continue
            # read parentMission straight off disk (not part of the card shape).
            pm = _read_json_key(sp, "parentMission")
            if pm == parent:
                out.append({"id": card["id"], "issue": card.get("issue"),
                            "title": card.get("title"), "stage": card.get("stage"),
                            "type": card.get("type")})
        return out

    @staticmethod
    def _title_from_idea(idea):
        first = idea.splitlines()[0].strip() if idea else "New mission"
        if len(first) > 72:
            first = first[:69].rstrip() + "..."
        return first or "New mission"

    def _tmp_prd(self, content):
        fd, path = tempfile.mkstemp(prefix="lcars-prd-", suffix=".md",
                                    dir=self.repo_root)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        return path


def _read_json_key(path, key):
    """Cheap flat reader for a top-level string key (jq-free, stdlib-only)."""
    import json
    try:
        with open(path) as fh:
            obj = json.load(fh)
    except (OSError, ValueError):
        return None
    return obj.get(key) if isinstance(obj, dict) else None


def build_actions(repo_root, worker_bin=None, gh_bin=None, env=None):
    """Resolve every skill path from its env seam and build an Actions.

    Each path defaults to the installed skill under ~/.claude/skills/<name>/ (the
    symlink install.sh creates), overridable via the SCRIPT_ENV var so tests and
    alternative installs can point elsewhere. Returns None if the script dir
    can't be located AND no overrides are set (caller then runs read-only).
    """
    env = env if env is not None else os.environ
    home = env.get("HOME", os.path.expanduser("~"))
    default_dir = {
        "file": os.path.join(home, ".claude/skills/lcars-file/file.sh"),
        "run": os.path.join(home, ".claude/skills/lcars-run/run.sh"),
        "pause": os.path.join(home, ".claude/skills/lcars-pause/pause.sh"),
        "respond": os.path.join(home, ".claude/skills/lcars-respond/respond.sh"),
        "approve": os.path.join(home, ".claude/skills/lcars-approve/approve.sh"),
        "feedback": os.path.join(home, ".claude/skills/lcars-feedback/feedback.sh"),
        "log": os.path.join(home, ".claude/skills/lcars-log/log.sh"),
        "resolve": os.path.join(
            home, ".claude/skills/lcars-resolve-logs/resolve-logs.sh"),
    }
    scripts = {}
    for key, default in default_dir.items():
        scripts[key] = env.get(SCRIPT_ENV[key], default)
    return Actions(repo_root=repo_root, scripts=scripts,
                   worker_bin=worker_bin, gh_bin=gh_bin)
