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
import datetime
import glob
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import time

from . import board
# Imported as a MODULE, not as a name: `_as_issue` is remote.py's own
# tolerance for `githubIssue` having been carried as both an int and a
# string over this project's life, and the two readers must normalise
# issue numbers identically or a verdict silently misses its card.
from . import remote as _remote_mod


# --- S146-D2: the bounded detection-marker set ------------------------------
# The readiness verdict (readiness.sh → lcars_test_readiness) depends on the
# repo's TOP-LEVEL stack/runner markers as well as config.json, so the
# adapter's memo/fingerprint must move when any of these appears, changes, or
# vanishes — otherwise the board's verdict goes stale against the CLI's the
# moment (say) a Makefile lands. This ONE list clearly MIRRORS the detector in
# skills/lcars-init/lcars-common.sh (detect_stack + detect_test_cmd +
# detect_workspace_runner): keep it in step with those functions. Bounded and
# cheap by construction — a fixed number of os.stat calls plus three top-level
# globs per check; the readiness SHELL-OUT still runs only when this signature
# (or config.json's mtime) actually changed.
_DETECT_MARKER_FILES = (
    # js (detect_stack: package.json; detect_test_cmd: pnpm-workspace.yaml;
    # detect_workspace_runner: pnpm-lock.yaml)
    "package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml",
    # python
    "pyproject.toml", "setup.py", "pytest.ini", "tox.ini",
    # rust / go
    "Cargo.toml", "go.mod",
    # jvm
    "pom.xml", "build.gradle", "build.gradle.kts",
    # ruby (S145)
    "Gemfile", "Rakefile", "config.ru",
    # generic runners, checked last by detect_test_cmd
    "Makefile", os.path.join("tests", "run.sh"),
)
# S147: `.slnx` is .NET 10's default solution format — a marker like `.sln`.
_DETECT_MARKER_GLOBS = ("*.gemspec", "*.csproj", "*.sln", "*.slnx")
# S147: detect_stack's dotnet marker probe is bounded-RECURSIVE (see
# detect_dotnet_markers / DOTNET_MARKER_MAXDEPTH in lcars-common.sh), because
# `dotnet new xunit -o MyApp.Tests` puts the only project one directory down
# with no root solution. The memo has to see the same files or the board's
# verdict goes stale against the CLI's. Depth-explicit glob patterns (cheap,
# no os.walk) mirroring maxdepth 3; `bin`/`obj`/`.git`/`node_modules` segments
# are dropped exactly as the shell prunes them (a build leaves a csproj copy
# under obj/, and counting it would re-verdict on every compile).
#
# Below the top level the CLI counts a project only when it is a TEST project
# (Test.Sdk reference, or the *Tests* naming convention) — a vendored sample or
# a tools/ helper must not flip a js/python/rust repo. Nested SOLUTIONS do not
# count for it at all, so they are not tracked here either. The remaining
# difference is deliberate: telling a test project from a plain one needs the
# file's CONTENTS, which a stat-cheap fingerprint will not read, so this stays a
# SUPERSET over nested *.csproj. A superset can only cause one extra re-verdict
# (the shell-out then returns the same answer); it can never leave the board
# stale, which is the direction the S146 D2 contract cares about.
# S176: this was a tuple of `*/*.csproj` + `*/*/*.csproj` glob patterns whose
# results were then filtered through _DETECT_MARKER_PRUNE — which meant globbing
# the whole of node_modules on every sweep and throwing it away. It is now a
# DEPTH, walked with the prune applied during the descent (_nested_marker_files).
# Same reach, same file set; it just stops enumerating what it discards.
_DETECT_MARKER_RDEPTH = 2
_DETECT_MARKER_PRUNE = ("bin", "obj", ".git", "node_modules")
# spec/ + test/ dir EXISTENCE is ruby runner evidence (detect_test_cmd S145).
_DETECT_MARKER_DIRS = ("spec", "test")

# S168 — a DNS hostname and nothing else. Labels of alphanumerics and hyphens,
# dot-separated, no scheme, no path, no port, no whitespace. Anything else is
# refused outright (see LocalAdapter.gh_host).
_HOSTNAME_RE = re.compile(
    r"^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$")

# S190 — a forge LOGIN and nothing else: alphanumerics and hyphens, ≤39 chars,
# never leading-hyphen. The SAME rule ownership.sh's `_lcars_own_is_login`
# applies, deliberately kept in step with it. Re-applied on this side because
# the value crosses a file boundary on its way from the shell to a URL the
# browser fetches, and a guard that only exists upstream is not a guard here.
_LOGIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")

# The "not asked yet" sentinel for the gh_host memo. Distinct from "" because ""
# is a real, cacheable answer (github.com) — the common one, in fact. S190's
# self-login memo uses it for exactly the same reason: "" (no identity) is a
# real answer that must be cached, not re-asked on every render.
_UNRESOLVED = object()


def _pruned_child_dirs(parent):
    """Immediate sub-directories of `parent`, minus the pruned + hidden ones.

    The prune list mirrors the shell's (`bin`/`obj`/`.git`/`node_modules`); the
    dot-prefix skip mirrors `glob`, whose `*` has never matched a hidden name —
    so the walk that replaced the globs keeps their exact reach.
    """
    out = []
    try:
        with os.scandir(parent) as entries:
            for e in entries:
                if e.name.startswith(".") or e.name in _DETECT_MARKER_PRUNE:
                    continue
                try:
                    if e.is_dir(follow_symlinks=False):
                        out.append(e.path)
                except OSError:
                    pass
    except OSError:
        return []
    return out


def _nested_marker_files(root):
    """[(relpath, abspath)] for *.csproj one and two directories under `root`.

    The pruning replacement for the old `*/*.csproj` + `*/*/*.csproj` globs — see
    `_DETECT_MARKER_RDEPTH` for why they went. Sorted, so the signature tuple's
    order is stable exactly as `sorted(glob.glob(...))` was.
    """
    found = []
    level = _pruned_child_dirs(root)
    for _ in range(_DETECT_MARKER_RDEPTH):   # depths 1..N, mirroring the globs
        for d in level:
            try:
                with os.scandir(d) as entries:
                    for e in entries:
                        if e.name.startswith(".") or not e.name.endswith(".csproj"):
                            continue
                        try:
                            if e.is_file(follow_symlinks=False):
                                found.append(
                                    (os.path.relpath(e.path, root), e.path))
                        except OSError:
                            pass
            except OSError:
                pass
        level = [c for d in level for c in _pruned_child_dirs(d)]
    return sorted(found)


class LocalAdapter(object):
    name = "local"

    def __init__(self, repo_root, read_only=False, git_url_reader=None,
                 readiness_script=None, base_freshness_script=None,
                 host_adapter_script=None, establish_vision_script=None,
                 ownership_script=None, remote=None, engines_reader=None):
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
        # S146: the shared test-readiness helper (skills/lcars-init/readiness.sh
        # — the ONE verdict the CLI surfaces also use; the daemon SHELLS it, it
        # never reimplements the verdict in Python). Injectable for tests; None
        # → env $LCARS_READINESS_SCRIPT → this clone's in-repo copy → the
        # installed symlink under ~/.claude. Memoized on config.json's mtime so
        # a board render costs one subprocess only when the config moved.
        self._readiness_script = readiness_script
        self._readiness_memo = None   # (config_mtime, payload-or-None)
        self._foundation_memo = None  # (detect-sig, locked-verdict-or-None)
        # S184: ((detect-sig, mission-count), front-door-payload-or-None). The
        # mission count is IN the key because the door must lift the moment the
        # initialization mission lands — a signature keyed on files alone would
        # keep serving the front door over a board that now has a card on it.
        self._front_door_memo = None
        # S197 — WHICH CLIs THIS MACHINE HAS, for the board's adopt picker.
        # A CALLABLE, not a path, because the answer is a shell FUNCTION
        # (`lcars_available_engines` in skills/lcars-init/lcars-common.sh) and
        # not a script with a verb: the default reader sources that library and
        # calls it, so the board, `lcars init`, the front door and adopt.sh all
        # read ONE detector (ADR-002). A test injects its own to pin what this
        # machine "has" without touching $PATH.
        self._engines_reader = engines_reader
        self._engines_memo = None     # (monotonic-deadline, [engines])
        self._engine_default_memo = None   # (deadline, engine) — S201/D2
        self._establish_vision_script = establish_vision_script
        self._aliases_memo = None     # (config_mtime, modelAliases-dict)
        # S160: the shared base-freshness reporter
        # (skills/lcars-init/base-freshness.sh — the read-only sibling of
        # readiness.sh over the SAME guard `lcars file` and `lcars run` use; the
        # daemon SHELLS it, it never reimplements the verdict in Python).
        # DELIBERATELY NOT memoized and DELIBERATELY not folded into board()/
        # _meta(): it takes a bounded `git fetch`, and a Kanban board that
        # re-renders on every SSE push must never trigger network I/O. It is
        # asked once, by its own endpoint, when the File console opens.
        self._base_freshness_script = base_freshness_script
        # S168: the shared FORGE-HOST resolver (skills/lcars-run/host-adapter.sh
        # `gh-host` → gh_hostname — the same derivation `gh api --hostname` is
        # pinned with). The daemon SHELLS it and never re-derives the host in
        # Python: LCARS already carries the scar of that choice (the zero-collect
        # phrase list exists in two implementations and they have drifted, so one
        # surface is honest and the other is blind). Injectable for tests.
        #
        # Resolved ONCE for the daemon's life — see gh_host(). `_UNRESOLVED` is a
        # sentinel rather than None/"" because the EMPTY answer (github.com, the
        # common case) must be cached too, or a github.com daemon would shell out
        # on every render forever.
        self._host_adapter_script = host_adapter_script
        self._gh_host_memo = _UNRESOLVED
        # S176 part A: per-mission-dir card memo, populated ONLY for a mission
        # whose card came back `done`. A done mission is immutable by
        # construction — terminal stage, no driver lock, no worker, no writer —
        # so its card is a pure function of files that are finished. On
        # DX-Scorecard (56 missions, 51 of them done) rebuilding those 51 cards
        # from disk on every render was ~80% of a 205 ms board(), four times a
        # minute, for ever. {dir: (signature, card)} — see _dir_signature for
        # what "changed" means and _done_card for why the caller gets a copy.
        self._card_memo = {}
        # S176 part C: repo identity SHELLS git for the origin url. Resolved ONCE
        # for the daemon's life, on exactly the reasoning `_gh_host_memo` above
        # already carries — the origin remote does not change under a running
        # daemon, and `_meta()` runs on every board build.
        self._repo_identity_memo = _UNRESOLVED
        # S190: the shared OWNERSHIP library (skills/lcars-run/ownership.sh). The
        # daemon SHELLS it and never re-derives identity or the light lock in
        # Python — the same ADR-002 rule readiness.sh, the foundation gate and
        # the host adapter already follow, and for the reason S168 recorded in
        # blood: two implementations of one verdict drift, and then one surface
        # is honest and the other is blind. Injectable for tests; None → env
        # $LCARS_OWNERSHIP_SCRIPT → this clone's copy → the installed symlink.
        #
        # It is shelled for exactly ONE thing on the read path — "who am I?" —
        # and that answer is memoized for the daemon's whole life (see
        # self_login). WHO OWNS A MISSION is never shelled here: it is read off
        # the published-owner files ownership.sh writes, because `_meta()` and
        # `_card()` run on every board build and a board build does no network
        # I/O (the rule `base_freshness` is kept out of this class for).
        self._ownership_script = ownership_script
        self._self_login_memo = _UNRESOLVED
        # S191: the REMOTE OVERLAY reader (remote.RemoteMissions), or None.
        #
        # None is the pre-S191 daemon and it is the DEFAULT, deliberately: every
        # existing construction of this class — six suites and the github build —
        # keeps serving exactly the board it served before, with no `meta.remote`
        # key and no forge call, because the overlay is a thing you are HANDED,
        # never a thing this class goes looking for.
        #
        # It is asked in `board()` and in `mission()` and NOWHERE ELSE. In
        # particular `fingerprint()` never touches it: the live channel polls that
        # about once a second, and remote data is deliberately kept off the live
        # channel this round (the slow poll updates it instead).
        self._remote = remote

    # -- the public surface ---------------------------------------------------
    def _model_aliases(self):
        """The repo's `modelAliases` map from config.json ({} when absent).

        S147 round 2: the shape layer resolves a stage's DISPLAYED tier through
        the same policy run.sh's `alias_for_tier` uses, and that policy is
        config-overridable per (cli, tier). Read here rather than in board.py so
        the shape layer stays free of filesystem knowledge.

        MEMOIZED on config.json's mtime, exactly like `_readiness_memo`: `_card`
        runs once per mission, so an un-memoized read would re-parse config.json
        N times per board render just to answer the same question. Keying on
        mtime keeps a mid-session `modelAliases` edit visible on the next render.
        """
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        try:
            mtime = os.path.getmtime(config)
        except OSError:
            mtime = None
        if self._aliases_memo is not None and self._aliases_memo[0] == mtime:
            return self._aliases_memo[1]
        aliases = {}
        if mtime is not None:
            cfg = _load_json(config)
            if isinstance(cfg, dict) and isinstance(cfg.get("modelAliases"), dict):
                aliases = cfg["modelAliases"]
        self._aliases_memo = (mtime, aliases)
        return aliases

    def board(self):
        cards = [self._done_card(d) for d in self._mission_dirs()]
        cards = [c for c in cards if c is not None]
        # newest-first by created (string ISO sorts correctly); ties on id.
        cards.sort(key=lambda c: (c.get("_created") or "", c["id"]), reverse=True)
        for c in cards:
            c.pop("_created", None)
        b = board.assemble(cards, meta=self._meta())
        # S191: …and THEN the remote overlay, on top of the finished local board.
        # The order is the whole design: the local board is built exactly as it
        # was, and remote cards are ADDED to it. Nothing local is consulted, moved
        # or recomputed because a remote card exists.
        self._overlay_remote(b, cards)
        # …and the ONE fact a LOCAL card is allowed to learn from the forge.
        # AFTER the overlay because it reads the same cached listing the overlay
        # just took, and BEFORE the return because the card objects placed in
        # `b` are these same objects.
        self._mark_shipped_elsewhere(cards)
        return b

    def _overlay_remote(self, b, local_cards):
        """Add the forge's missions that have no local mission directory.

        LOCAL WINS, and it wins by CONSTRUCTION rather than by comparison: the
        issue numbers the local board already holds are handed to the reader,
        which never builds a card for one of them. There is no later dedupe pass
        that could be reached with the wrong list.

        NEVER RAISES INTO A BOARD BUILD. The overlay is a courtesy on top of the
        captain's own work; a forge that misbehaves must cost him the remote
        cards and not the board. (The reader is already defensive; this is the
        second wall, on the same reasoning `warm_owners` carries.)
        """
        if self._remote is None:
            return
        try:
            cards, meta = self._remote.cards(
                [c.get("issue") for c in local_cards])
        except Exception:
            return
        # None ⇒ the overlay is OFF (no gh, or opted out) ⇒ NO `remote` key at
        # all. Absent, never null — the rule that keeps a gh-less board
        # byte-identical to the one it served before this round.
        if meta is None:
            return
        b["meta"]["remote"] = meta
        for c in cards:
            stage = board.normalise_stage(c.get("stage"))
            c["stage"] = stage
            self._offer_engines(c)
            b["columns"][stage].append(c)
            if stage != "done":
                b["missions"].append(c)

    def _offer_engines(self, card):
        """S197 — an ADOPTABLE remote card learns what this laptop can run.

        The card already carries `engine` (the engine the mission was FILED on,
        read out of its handoff envelope by remote.py) — that is the forge's
        half. This is the LOCAL half, and the two together are everything the
        picker needs to ask the question `lcars adopt` asks at a terminal.

        ONLY ON A CARD THAT OFFERS ADOPT, and only when the detector actually
        answered: `enginesHere` is ABSENT — never null, never empty — on every
        other card, which is the rule every additive key on this shape has
        followed since S109 and the reason the byte-identity baselines (no gh,
        no overlay, no remote cards) are untouched by this round.

        ONE DETECTOR CALL PER BOARD BUILD AT WORST: `_engines_here` memoizes,
        so a board with twelve adoptable remote cards still spawns one bash.
        NO forge round trip is added — S152 is about `gh`, and this asks the
        local machine, never the network.
        """
        if not card.get("adoptable"):
            return
        engines = self._engines_here()
        if engines:
            card["enginesHere"] = engines

    def _mark_shipped_elsewhere(self, local_cards):
        """Let a LOCAL card learn that its issue is finished on the forge.

        THE DEFECT. Found TWICE in one day by two independent two-laptop runs:
        laptop B adopts a mission, drives it and merges it, and laptop A — the
        one that FILED it — keeps showing the card at Verify with a live
        `✓ Review PR ▸` for a pull request that merged minutes ago. A live
        control for a merged PR is S191's D4 exactly: a lie the hand discovers.

        WHY THE CARD IS NOT REBUILT FROM THE FORGE. Rule 3 of the overlay is
        that a LOCAL mission always wins, and it still does. This adds ONE
        additive key carrying ONE fact the forge is authoritative about (rule 4:
        the `lcars:done` LABEL, and the issue's own closed state). Everything
        else on the card — the title, the pills, the tickets, the activity — is
        still the local mission's, unchanged.

        WHAT IT DELIBERATELY DOES NOT DO: it does not move the card to Done and
        it does not rewrite `.git/lcars`. The local mission genuinely IS at
        verify on this laptop — the branch is here, unmerged, and the CLI would
        say so. Telling the captain the truth is in scope; silently reconciling
        his repo behind his back is not.

        ABSENT, NEVER NULL (the rule every additive key in this shape has
        followed since S109): a mission the forge says nothing about, an overlay
        that is off, and a listing that failed all leave the card with no
        `shippedElsewhere` key at all — which is what keeps a gh-less board
        byte-identical to the one it served before this session.

        NEVER RAISES INTO A BOARD BUILD, on the same reasoning `_overlay_remote`
        carries: this is a courtesy on top of the captain's own work.
        """
        if self._remote is None:
            return
        try:
            verdicts = self._remote.verdicts(
                [c.get("issue") for c in local_cards])
        except Exception:
            return
        if not verdicts:
            return
        for c in local_cards:
            n = _remote_mod._as_issue(c.get("issue"))
            if n is None:
                continue
            v = verdicts.get(n)
            if not v:
                continue
            if board.normalise_stage(c.get("stage")) == "done":
                # Nothing to tell him. The local mission already knows.
                continue
            c["shippedElsewhere"] = dict(v)

    def _meta(self):
        if self._repo_identity_memo is _UNRESOLVED:
            self._repo_identity_memo = _repo_identity(
                self.repo_root, self._git_url_reader)
        meta = {
            "repo": self._repo_identity_memo,
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
        # S146: the additive test-readiness block. Present ONLY when the repo is
        # NOT ready ({status, suggestion, testCommand}); a READY repo carries NO
        # `testReadiness` key at all, so its meta — and every old payload — is
        # byte-identical to before this round. Never raises into the board.
        tr = self._test_readiness()
        if tr is not None:
            meta["testReadiness"] = tr
            # S183: the board LOCKS filing and the holodeck on a repo with no
            # test foundation, so the lock state rides meta as its own key —
            # present ONLY on the two locked verdicts, so every repo that could
            # file before this round carries no `foundation` key at all and its
            # payload is byte-identical. A ready repo has no `testReadiness`
            # block to hang it off in the first place, which is the point: no
            # key ⇒ nothing locked.
            if tr.get("foundation") in ("greenfield", "untested"):
                meta["foundation"] = tr.get("foundation")
        else:
            # S183 FIX ROUND 3 (F2). `_test_readiness` reports NOTHING on a repo
            # with no `.git/lcars/config.json` — an S146 rule, and a correct one:
            # `testReadiness` describes an INITIALIZED repo's configured command,
            # and everything that reads it depends on that meaning. The FOUNDATION
            # is a different question ("does this repo have a test system at
            # all?") and it needs no config file to answer — the CLI gate returns
            # rc=20 on exactly this repo. Hanging the lock off the readiness
            # payload therefore left the board UNLOCKED on the never-init'd repo a
            # captain is most likely to open it against: both band controls
            # enabled, ▦ FILE MISSION opening the idea box, and the refusal
            # arriving only after he had typed one — the late refusal this whole
            # round exists to remove. Asked here, and ONLY here (an initialized
            # repo's verdict still rides `testReadiness` exactly as it did), so
            # `testReadiness` means precisely what it meant before.
            f = self._foundation_only()
            if f is not None:
                meta["foundation"] = f
        # S184: THE FRONT DOOR. `meta.foundation` says the repo is locked;
        # `meta.frontDoor` says the board is REPLACED by the Establish Vision
        # screen — and those are NOT the same question. The front door takes over
        # only when there is NOTHING TO PUT ON THE BOARD, which is the captain's
        # own wording of the ruling. Measured on his machine: `Flappy-Bird` is an
        # initialized repo whose verdict is `untested` and which carries TWO real
        # missions; keying the front door off the verdict alone would have DELETED
        # that board and hidden both missions behind "What are we building?".
        #
        # So the key is POSITIVE and narrow: present only when the helper says
        # frontDoor:true (locked verdict AND zero missions). Absent ⇒ the board
        # renders exactly as it does today, with S183's lock still in force on it.
        # A repo that could file before this round carries no `frontDoor` key at
        # all and its payload is byte-identical.
        if meta.get("foundation"):
            fd = self._front_door()
            if fd is not None:
                meta["frontDoor"] = fd
        # S168: the FORGE HOST this repo lives on, for the board's "view on
        # GitHub" links. Purely ADDITIVE and present ONLY on a non-github.com
        # host: `gh_hostname` returns EMPTY for github.com (and for a repo with
        # no origin) BY DESIGN, so those boards carry no `ghHost` key at all and
        # their payload is byte-identical to before this round — which matters,
        # because that is every other user's board. A BARE HOST, never a URL: the
        # front end pins the `https://` scheme itself, so no value arriving from
        # here can ever become the scheme.
        gh = self.gh_host()
        if gh:
            meta["ghHost"] = gh
        # S190: WHO THIS BOARD IS. `meta.self` is the login LCARS is acting as —
        # the other half of a card's `owner`, and the only thing that lets the
        # front end tell "mine" from "someone else's" without deciding policy of
        # its own. Purely ADDITIVE and present ONLY when an identity RESOLVES: no
        # gh, no auth, no network ⇒ no `self` key at all, so that board is
        # byte-identical to before this round and NOTHING on it is ever locked.
        # That absence is not a degradation to paper over — it is the posture
        # `lcars_owner_lock_reason` already takes, mirrored here on purpose.
        me = self.self_login()
        if me:
            meta["self"] = {"login": me}
        # S201: IS NUMBER ONE ON FOR THIS REPO — the band toggle's whole state.
        #
        # The repo's `numberOne` config block, echoed rather than interpreted:
        # `lcars xo on|off` is the ONE writer (ADR-002) and this is a read of
        # what it wrote. Purely ADDITIVE and present ONLY when the block is
        # there AND well formed, so a repo that has never run `lcars xo` — and
        # every repo that predates this round — carries no `numberOne` key at
        # all and its meta is byte-identical.
        xo = self._number_one_config()
        if xo is not None:
            meta["numberOne"] = xo
            # …and the other half of the picker's question: WHICH engines this
            # laptop actually has. The SAME detector `lcars xo` uses at a
            # terminal (S195's `lcars_available_engines`, reached here through
            # the offer the remote overlay already builds), so the board never
            # guesses at an install. Absent when the detector cannot answer,
            # which leaves the picker offering both rows unlabelled rather than
            # claiming an engine is missing.
            here = self._engines_here()
            if here:
                meta["enginesHere"] = here
            # …and WHICH ROW THE PICKER OPENS ON. Not a second opinion: this is
            # `lcars_xo_default_engine`'s answer, the same function the CLI
            # picker preselects with, spawned the way `enginesHere` already is.
            # FIX ROUND 1, D2: the board opened on copilot and the terminal on
            # claude, so a bare Enter engaged a different officer depending on
            # which door the captain came through. One function answers both
            # now, and the front end RENDERS this rather than deriving one.
            # Absent when nothing is installed — an unanswered question, never
            # a guessed answer.
            default = self._engine_default()
            if default:
                meta["engineDefault"] = default
        return meta

    # ── S201: the repo-level toggle, and what this laptop can run ───────────
    def _number_one_config(self):
        """The repo's `numberOne` config block, or None.

        {enabled: bool} at minimum, plus `engine` / `model` when the captain
        pinned them. MALFORMED IS NOTHING: a string, a list, a missing
        `enabled` — every one of them answers None rather than a guess, which
        is the posture `lcars_xo_status` takes in the shell for the same
        reason. A board that cannot read the toggle shows no toggle; it never
        shows a toggle that says the wrong thing.
        """
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        cfg = _load_json(config)
        if not isinstance(cfg, dict):
            return None
        blk = cfg.get("numberOne")
        if not isinstance(blk, dict):
            return None
        if not isinstance(blk.get("enabled"), bool):
            return None
        out = {"enabled": blk["enabled"]}
        for key in ("engine", "model"):
            v = blk.get(key)
            if isinstance(v, str) and v.strip():
                out[key] = v.strip()
        return out

    def _resolve_host_adapter_script(self):
        """The host adapter path: injected → env → in-repo → installed.

        Mirrors _resolve_readiness_script exactly, and honours the SAME
        `LCARS_HOST_ADAPTER` env var the shell callers already use to point at a
        stubbed adapter — one override, both layers.
        """
        if self._host_adapter_script:
            return self._host_adapter_script
        env = os.environ.get("LCARS_HOST_ADAPTER")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-run", "host-adapter.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-run",
                            "host-adapter.sh")

    def gh_host(self):
        """The forge host this repo lives on, or "" for github.com / no remote.

        Shells `host-adapter.sh gh-host` (ADR-002: the daemon dispatches to the
        skill; it never re-derives the host in Python) with the board's repo as
        cwd. A pure read of the origin remote — no gh, no network, no spend.

        RESOLVED ONCE, for the daemon's whole life. The server's poll loop ticks
        about once a second and `_meta()` runs on every board build, so anything
        less than a permanent memo would be a subprocess storm. The origin remote
        does not change under a running daemon; if it ever did, the daemon is
        restarted with it. `__main__.build_adapter` warms this at startup so the
        very first board render costs nothing either.

        ANY failure — script missing, non-zero exit, a value that is not a
        hostname — degrades to "", which is exactly today's behaviour (the front
        end falls back to github.com). Never a broken link, never a raise.
        """
        if self._gh_host_memo is not _UNRESOLVED:
            return self._gh_host_memo
        host = ""
        script = self._resolve_host_adapter_script()
        try:
            proc = subprocess.run(
                ["bash", script, "gh-host"], cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=10)
            if proc.returncode == 0:
                host = (proc.stdout or b"").decode("utf-8", "replace").strip()
        except Exception:
            host = ""
        # Defence in depth. The shell strips scheme, user@, path and port, so a
        # real remote cannot produce anything else — but this value is spliced
        # into a URL the captain clicks, and "it cannot happen upstream" is not a
        # guarantee downstream. A hostname, or nothing.
        if not _HOSTNAME_RE.match(host):
            host = ""
        self._gh_host_memo = host
        return host

    # ── S190: identity and ownership ────────────────────────────────────────
    def _resolve_ownership_script(self):
        """The ownership library path: injected → env → in-repo → installed.

        Mirrors _resolve_host_adapter_script exactly, and honours
        $LCARS_OWNERSHIP_SCRIPT so a test (and an alternative install) can point
        it somewhere harmless. NOTE the name: the SHELL callers already use
        $LCARS_OWNERSHIP_LIB for the SOURCED path, and this is the EXECUTED one
        — the same file, two different reaches, so they get two different names
        rather than one that means two things.
        """
        if self._ownership_script:
            return self._ownership_script
        env = os.environ.get("LCARS_OWNERSHIP_SCRIPT")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-run", "ownership.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-run",
                            "ownership.sh")

    def _ownership_call(self, *args, **kw):
        """One `bash ownership.sh <op> …` call. Returns stripped stdout, or "".

        stdin CLOSED and a hard timeout, for the reason ownership.sh's own
        `_lcars_own_host_call` documents: a gh that decides to prompt would
        otherwise stall a daemon thread for ever with no output. ANY failure —
        script missing, non-zero exit, a timeout — degrades to "", which is
        always the "we do not know" answer, and "we do not know" never locks
        anything.
        """
        timeout = kw.pop("timeout", 15)
        script = self._resolve_ownership_script()
        try:
            proc = subprocess.run(
                ["bash", script] + list(args), cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=timeout)
        except Exception:
            return ""
        if proc.returncode != 0:
            return ""
        return (proc.stdout or b"").decode("utf-8", "replace").strip()

    def self_login(self):
        """The login this daemon is acting as, or "" when nothing can say.

        A PURE READ — env pin, then the whoami file `lcars_whoami` publishes.
        NO SUBPROCESS AND NO FORGE CALL, ever, and that is the point: this runs
        inside `_meta()`, which runs on every board build, and a board build does
        no network I/O. `warm_self()` below is the one place that asks.

        Resolution order mirrors `lcars_whoami`'s own, minus the step that costs
        a round trip:

          1. $LCARS_GH_USER — the env pin. It wins over everything and costs
             nothing, exactly as it does in the shell. This is how the suites and
             a headless harness pin an identity.
          2. `.git/lcars/cache/whoami-<host>` — the file S189's `lcars_whoami`
             already writes on every resolution, host-scoped (a login read on one
             forge must never be handed back on another), and honoured here under
             the SAME $LCARS_WHOAMI_TTL. Every CLI verb refreshes it; so does the
             daemon's own `warm_self()` and every pre-write ownership re-check.

        MEMOIZED for the daemon's whole life, on the reasoning `gh_host` carries:
        the captain does not become a different person under a running daemon.

        "" is a first-class answer — no gh, no auth, cold cache. The board then
        carries no `meta.self` at all and NOTHING is ever locked: if we cannot say
        who we are, we do not get to tell the captain he is someone else.
        """
        if self._self_login_memo is not _UNRESOLVED:
            return self._self_login_memo
        pinned = os.environ.get("LCARS_GH_USER")
        login = pinned.strip() if isinstance(pinned, str) else ""
        if not login:
            login = self._published_self()
        if not _LOGIN_RE.match(login or ""):
            login = ""
        self._self_login_memo = login
        return login

    def _published_self(self):
        """The login in the host-scoped whoami file, or "" (absent / stale)."""
        cache = self._owner_cache_dir()
        if not os.path.isdir(cache):
            return ""          # nothing published — see _published_owner
        host = self.gh_host() or "github.com"
        path = os.path.join(cache, "whoami-%s" % host)
        try:
            ttl = int(os.environ.get("LCARS_WHOAMI_TTL") or 43200)
        except ValueError:
            ttl = 43200
        try:
            if ttl > 0 and (time.time() - os.path.getmtime(path)) >= ttl:
                return ""
            with open(path) as fh:
                return (fh.readline() or "").strip()
        except OSError:
            return ""

    def warm_self(self):
        """Ask the forge who we are, ONCE, and publish it. Returns the login.

        The ONE identity round trip in the daemon's life. Called from
        `__main__.build_adapter` at startup — the same "pay for it before anyone
        is waiting" move `gh_host()` makes there — so `self_login()` above can
        stay a pure file read on the render path.

        It goes through `ownership.sh whoami` rather than gh directly, so the
        memo, the host pin and the cache write all stay in the one implementation
        (ADR-002). The cache write is that call's own side effect; we clear our
        memo first so the fresh answer is picked up rather than a cold "".

        Idempotent once it has an answer, so the startup path can call it
        synchronously (the first board must know who we are, or it shows every
        card unlocked) and the background owner warm can call it again for free.
        A warm that found NOTHING is retried, deliberately: gh may simply have
        been slow to start.
        """
        if isinstance(self._self_login_memo, str) and self._self_login_memo:
            return self._self_login_memo
        self._ownership_call("whoami")
        self._self_login_memo = _UNRESOLVED
        return self.self_login()

    def _owner_cache_dir(self):
        return os.path.join(self.repo_root, ".git", "lcars", "cache")

    def _published_owner(self, issue):
        """The owner ownership.sh last PUBLISHED for this issue, or "".

        A PURE DISK READ — no subprocess, no network, no lock. That is the whole
        design: `_card()` runs once per mission on every board build, and a board
        build must never touch the forge (the rule that keeps `base_freshness`,
        with its bounded `git fetch`, out of this class entirely).

        The file is host-scoped for the same reason the whoami cache is: the same
        issue NUMBER exists on both forges and means different work there.

        THREE STATES, and they are not two:
          * file absent            → we have never asked. No owner key.
          * file present, EMPTY    → the forge said "nobody". No owner key.
          * file present with a login → that login.
        The board locks on none of the first two; the distinction is kept because
        "unowned" and "unknown" are different facts and a later surface (the
        remote card, S191) will want to say so.

        WHAT THIS IS NOT: authority. It is a display cache, and a reassignment
        made on GitHub reaches it only when something asks the forge again (any
        write verb, the daemon's own pre-write re-check, or a daemon restart).
        Nothing authoritative is ever decided from it — every write is re-checked
        LIVE against the forge before it is allowed through (see
        Actions.owner_lock_reason). A stale card can therefore mislead for a
        while; it can never let the wrong write happen, nor block the right one.
        """
        if not isinstance(issue, int):
            return ""
        # ASK NOTHING WHEN THERE IS NOTHING TO READ. Resolving the host key means
        # `gh_host()`, and on a cold adapter that is a subprocess — so a repo
        # where ownership has never been published (every pre-S190 repo, and
        # every test fixture) must not pay for one just to learn there is no
        # file. `_card` runs once per mission on every build; this guard is what
        # keeps that free.
        cache = self._owner_cache_dir()
        if not os.path.isdir(cache):
            return ""
        host = self.gh_host() or "github.com"
        path = os.path.join(cache, "owner-%s-%d" % (host, issue))
        try:
            with open(path) as fh:
                login = (fh.readline() or "").strip()
        except OSError:
            return ""
        # The publisher already validated it; validate again, because this value
        # becomes a URL the browser fetches and a name in a refusal sentence.
        return login if _LOGIN_RE.match(login) else ""

    def refresh_owner(self, issue):
        """Re-ask the forge who owns this issue, republishing the cache.

        Shells `ownership.sh owner <n>`, whose own resolution writes the
        published-owner file as a side effect. Called from paths where a
        subprocess is honest — a write the daemon is about to allow or refuse,
        and the startup warm — and NEVER from `board()`.

        A FAILED CALL PUBLISHES NOTHING, and that is enforced in ownership.sh's
        `mission_owner`, not here — one implementation of "who owns this", per
        ADR-002. It matters at this seam because this method returns "" for BOTH
        "the forge says nobody" and "the forge could not be reached", and round 1
        shipped with the publisher unable to tell them apart either: a daemon
        started with gh missing rewrote every owner file to zero bytes on boot.
        The three states `_published_owner` documents are only three because the
        publisher now stays silent when the forge did not answer.
        """
        if not isinstance(issue, int):
            return ""
        return self._ownership_call("owner", str(issue))

    def warm_owners(self, limit=24):
        """Ask the forge who owns each ACTIVE mission, once, at startup.

        Runs in a background thread from `__main__.build_adapter` (the same
        "pay for it before anyone is waiting" move `gh_host()` makes there), so
        the daemon binds its port instantly and the first board a browser sees
        already knows whose work is whose. There is no shared mutable state and
        therefore no lock: each call writes a FILE, and `board()` reads files.

        Bounded on purpose — active missions only, newest first, hard-capped —
        because this is N forge round trips and the tail of finished work would
        make it unbounded. A DONE mission's owner is not a question anyone acts
        on, so it is not asked.

        Best-effort throughout: every failure is already swallowed into "" by
        `_ownership_call`, and a daemon whose forge is unreachable simply serves
        the board it served before this round.
        """
        try:
            # WHO WE ARE FIRST, and it is the more important of the two: without
            # an identity nothing can be compared to an owner, so the board would
            # show every avatar and lock nothing.
            self.warm_self()
            # S191: LOCAL missions only, and FILTERED BEFORE THE CAP. A remote
            # card's owner already came off the issue's own assignees in the
            # listing the overlay took, so re-asking here would be N extra forge
            # round trips at startup to learn what the board already knows — and
            # slicing first would let those cards eat the budget meant for the
            # local missions that genuinely need one.
            local = [c for c in self.board().get("missions", [])
                     if not c.get("remote")]
            for card in local[:limit]:
                issue = card.get("issue")
                if isinstance(issue, int):
                    self.refresh_owner(issue)
        except Exception:
            # A warm-up may never take the daemon down with it.
            pass

    def _resolve_readiness_script(self):
        """The readiness helper path: injected → env → in-repo → installed."""
        if self._readiness_script:
            return self._readiness_script
        env = os.environ.get("LCARS_READINESS_SCRIPT")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "readiness.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-init",
                            "readiness.sh")

    def _resolve_base_freshness_script(self):
        """The base-freshness reporter path: injected → env → in-repo → installed.

        Mirrors _resolve_readiness_script exactly — same four rungs, same order.
        """
        if self._base_freshness_script:
            return self._base_freshness_script
        env = os.environ.get("LCARS_BASE_FRESHNESS_SCRIPT")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "base-freshness.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-init",
                            "base-freshness.sh")

    def base_freshness(self):
        """This repo's LIVE base-freshness record, or None. A READ, never a write.

        Shells `base-freshness.sh --json` (the ONE shared verdict — ADR-002: the
        daemon dispatches, it never reimplements the decision in Python) with the
        board's repo as cwd, and returns the record verbatim:

            {verdict, loud, reason, fix, fixNote, blocker, behindBy, aheadBy,
             baseSha, checkedAt, missionBranchAtBase}

        The reporter is read-only BY CONSTRUCTION (it sets
        LCARS_BASE_CHECK_ONLY=1 itself); the pin is repeated in this env for the
        same reason the CLI repeats it — the daemon inherits the captain's whole
        environment, and a board render must never be able to fast-forward the
        captain's checkout as a side effect.

        The timeout is generous because the guard's own bounded `git fetch`
        (LCARS_BASE_FETCH_TIMEOUT_SECS, 8s by default) may run twice — the base
        and then origin's trunk. ANY failure — missing script, bad JSON, non-zero
        exit, slow origin — degrades to None (the console simply says nothing),
        never into the response.
        """
        script = self._resolve_base_freshness_script()
        env = dict(os.environ)
        env["LCARS_BASE_CHECK_ONLY"] = "1"
        try:
            proc = subprocess.run(
                ["bash", script, "--json"], cwd=self.repo_root, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=45)
            if proc.returncode != 0:
                return None
            rec = json.loads((proc.stdout or b"").decode("utf-8", "replace"))
        except Exception:
            return None
        if not isinstance(rec, dict) or not rec.get("verdict"):
            return None
        return rec

    # --- S205: the First Officer's report + its screenshots -----------------
    def _resolve_xo_report_script(self):
        """`skills/lcars-xo/xo-report.py`'s path: env → in-repo → installed.

        Same rungs as `_resolve_base_freshness_script` (ADR-002: the daemon
        DISPATCHES to the one shared implementation, it never reimplements the
        verdict in a second language) — except this one is imported, not
        shelled: it is a pure, dependency-free read (no git, no gh, no
        subprocess of its own), so a real Python import costs nothing a
        subprocess wouldn't and skips a process spawn on every detail render.
        """
        env = os.environ.get("LCARS_XO_REPORT_SCRIPT")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-xo", "xo-report.py"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-xo",
                            "xo-report.py")

    def _xo_report_module(self):
        script = self._resolve_xo_report_script()
        cache = _XO_REPORT_MODULE_CACHE.get(script)
        if cache is not None:
            return cache
        try:
            spec = importlib.util.spec_from_file_location(
                "lcars_xo_report_module", script)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            return None
        _XO_REPORT_MODULE_CACHE[script] = mod
        return mod

    def xo_report(self):
        """`GET /api/xo/report`'s body: {lastSeenAt, since, history} — every
        mission's `number-one.jsonl`, split against `.git/lcars/xo-seen.json`.

        ONE BUILDER, SHARED WITH THE CLI (S205 behaviour 6): this imports and
        calls `xo-report.py`'s own `build_report`, the SAME function
        `xo.sh report` execs the file for. Neither surface re-derives the
        since/history split independently.
        """
        mod = self._xo_report_module()
        if mod is None:
            return None
        seen_path = os.path.join(self.repo_root, ".git", "lcars",
                                  "xo-seen.json")
        try:
            return mod.build_report(self.missions_dir, seen_path)
        except Exception:
            return None

    def xo_seen(self):
        """Marks the report seen NOW (`.git/lcars/xo-seen.json`), through the
        SAME `xo-report.py` writer the CLI's `--seen` flag uses — one file,
        one writer. Returns the fresh report (now showing "nothing new")."""
        mod = self._xo_report_module()
        if mod is None:
            return None
        seen_path = os.path.join(self.repo_root, ".git", "lcars",
                                  "xo-seen.json")
        try:
            report = mod.build_report(self.missions_dir, seen_path)
            now = datetime.datetime.now(datetime.timezone.utc) \
                .strftime("%Y-%m-%dT%H:%M:%SZ")
            mod.write_seen(seen_path, now)
            report["lastSeenAt"] = now
            report["markedSeenAt"] = now
            return report
        except Exception:
            return None

    _XO_SHOT_TYPES = {".png": "image/png", ".jpg": "image/jpeg",
                       ".jpeg": "image/jpeg"}

    def xo_shot(self, mission_id, rel):
        """(bytes, content-type) for one screenshot under
        `<mission>/xo/shots/…`, or None. LOCAL adapter only — a remote card
        has no local shots at all.

        PATH-SAFETY IS A SECURITY BOUNDARY, not a nicety: `_xo_shot_path`
        checks containment by REAL PATH (`os.path.realpath` + a prefix check),
        never by rejecting a literal `..` alone — a symlink inside the shots
        tree, or an encoded segment, would slip past a naive string check.
        """
        if not (isinstance(mission_id, str) and mission_id.strip()
                and "/" not in mission_id and mission_id not in (".", "..")):
            return None
        d = os.path.join(self.missions_dir, mission_id)
        if not os.path.isdir(d):
            return None
        target = _xo_shot_path(d, rel)
        if target is None or not os.path.isfile(target):
            return None
        ext = os.path.splitext(target)[1].lower()
        ctype = self._XO_SHOT_TYPES.get(ext)
        if ctype is None:
            return None
        try:
            with open(target, "rb") as fh:
                return fh.read(), ctype
        except OSError:
            return None

    def _detect_signature(self):
        """(existence, mtime) over the bounded detection-marker set.

        S146-D2: the hashable state the readiness verdict can depend on beyond
        config.json — folded into the memo key (so a marker landing/vanishing
        re-verdicts on the NEXT board) and into fingerprint() (so SSE pushes an
        update to passive browsers). Pure os.stat/isdir + three top-level
        globs; never shells anything.
        """
        sig = []
        root = self.repo_root
        for name in _DETECT_MARKER_FILES:
            try:
                sig.append((name, os.path.getmtime(os.path.join(root, name))))
            except OSError:
                sig.append((name, None))
        for pat in _DETECT_MARKER_GLOBS:
            for p in sorted(glob.glob(os.path.join(glob.escape(root), pat))):
                try:
                    sig.append((os.path.basename(p), os.path.getmtime(p)))
                except OSError:
                    pass
        # S176: walk to the nested *.csproj with the prune applied DURING the
        # descent instead of after it. `glob("*/*/*.csproj")` expands every
        # directory two levels down and only THEN drops the pruned segments —
        # so on any JS repo it enumerated the whole of node_modules, every time.
        # Measured on DX-Scorecard: 38 ms and 228 glob calls per sweep, and
        # fingerprint() folds this in, so the SSE channel paid it at 1 Hz for as
        # long as a board was open. Same file set, same order, same tuple shape;
        # it just stops walking into directories whose contents it throws away.
        for rel, p in _nested_marker_files(root):
            try:
                sig.append((rel, os.path.getmtime(p)))
            except OSError:
                pass
        for d in _DETECT_MARKER_DIRS:
            sig.append((d + "/", os.path.isdir(os.path.join(root, d))))
        return tuple(sig)

    def _test_readiness(self):
        """The additive meta.testReadiness payload, or None (ready / degraded).

        Shells `readiness.sh --json` (the ONE shared verdict — ADR-002: the
        daemon dispatches, it never reimplements config logic in Python) with
        the board's repo as cwd. Cheap by construction server-side too: the
        result is memoized on config.json's mtime, so the subprocess runs only
        when the config actually moved. ANY failure — script missing, bad JSON,
        non-zero exit — degrades to None (no block), never into the response.
        """
        # Readiness is a property of an INITIALIZED repo: `lcars init` always
        # writes config.json, so its absence means "not an LCARS repo (yet)" —
        # report nothing (and keep pre-init/legacy fixtures byte-identical).
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        if not os.path.isfile(config):
            return None
        try:
            mtime = os.path.getmtime(config)
        except OSError:
            mtime = 0.0
        # S146-D2: the memo key folds the detection-marker signature alongside
        # config.json's mtime — the verdict depends on BOTH (a Makefile landing
        # flips the CLI's verdict with config.json untouched, and the board
        # must agree on the next render). Stat-cheap; the shell-out below still
        # runs only when this key actually moved.
        key = (mtime, self._detect_signature())
        if self._readiness_memo is not None and self._readiness_memo[0] == key:
            return self._readiness_memo[1]
        payload = None
        script = self._resolve_readiness_script()
        try:
            proc = subprocess.run(
                ["bash", script, "--json"], cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=10)
            blk = json.loads((proc.stdout or b"").decode("utf-8", "replace"))
            if isinstance(blk, dict) and blk.get("status") \
                    and blk.get("status") != "ready":
                payload = {"status": blk.get("status"),
                           "suggestion": blk.get("suggestion"),
                           "testCommand": blk.get("testCommand")}
                # S147: `stacks` names the candidates behind an AMBIGUOUS
                # verdict so the board speaks the same CHOOSE voice the CLI
                # line does, and `candidates` carries the PICKABLE commands so
                # the board can offer the choice directly — the ⚡ FIX walk on
                # this state dispatches a paid discovery worker to make the very
                # choice LCARS just said it would not make. Forwarded ONLY when
                # the helper set them, so the missing/broken/unknown payloads
                # stay byte-identical to S146.
                if blk.get("stacks"):
                    payload["stacks"] = blk.get("stacks")
                if isinstance(blk.get("candidates"), list) and blk["candidates"]:
                    payload["candidates"] = [
                        c for c in blk["candidates"] if isinstance(c, str)]
                # S183: the FOUNDATION axis — "does this repo HAVE a test system
                # at all?", as opposed to "is a command configured?". Forwarded
                # only when the helper set it, so a pre-S183 readiness.sh (or a
                # stub in a test) yields a byte-identical payload.
                if blk.get("foundation"):
                    payload["foundation"] = blk.get("foundation")
                if blk.get("foundationWhy"):
                    payload["foundationWhy"] = blk.get("foundationWhy")
        except Exception:
            payload = None
        self._readiness_memo = (key, payload)
        return payload

    def _foundation_only(self):
        """The LOCKED foundation verdict for an UN-INITIALIZED repo, or None.

        Shells the same ONE verdict `_test_readiness` does (ADR-002 — the daemon
        dispatches, it never reimplements the rule in Python) and keeps ONLY the
        two locking verdicts; anything else — `unconfigured`, `ready`, a repo
        that HAS a config, a missing/slow/garbage helper — is None, i.e. nothing
        added to meta and no behaviour changed. Memoized on the detection-marker
        signature, so a board that re-renders does not re-shell.
        """
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        if os.path.isfile(config):
            return None  # initialized: the verdict rides testReadiness already
        key = self._detect_signature()
        if self._foundation_memo is not None and self._foundation_memo[0] == key:
            return self._foundation_memo[1]
        verdict = None
        script = self._resolve_readiness_script()
        try:
            proc = subprocess.run(
                ["bash", script, "--json"], cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=10)
            blk = json.loads((proc.stdout or b"").decode("utf-8", "replace"))
            if isinstance(blk, dict) \
                    and blk.get("foundation") in ("greenfield", "untested"):
                verdict = blk["foundation"]
        except Exception:
            verdict = None
        self._foundation_memo = (key, verdict)
        return verdict

    def _front_door(self):
        """The FRONT DOOR payload — the `untested` screen's FOUND panel, or None.

        Shells `skills/lcars-init/establish-vision.sh --facts`, the ONE detector
        behind both front doors (ADR-002 — the daemon dispatches, it never
        reimplements the rule in Python), so the stack and the source-file count
        the board prints are the same numbers `lcars` prints on the CLI.

        None whenever the helper says the board should render — including the
        `Flappy-Bird` case (a locked verdict WITH missions) — and whenever it is
        missing, slow or unparseable: an absence of information never replaces a
        captain's board. Memoized on the detection-marker signature plus the
        mission count, so the door lifts the instant the initialization mission
        lands and a re-render does not re-shell.
        """
        try:
            n_missions = len(os.listdir(self.missions_dir)) \
                if os.path.isdir(self.missions_dir) else 0
        except OSError:
            n_missions = 0
        key = (self._detect_signature(), n_missions)
        if self._front_door_memo is not None and self._front_door_memo[0] == key:
            return self._front_door_memo[1]
        payload = None
        script = self._resolve_establish_vision_script()
        try:
            proc = subprocess.run(
                ["bash", script, "--facts"], cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=10)
            blk = json.loads((proc.stdout or b"").decode("utf-8", "replace"))
            if isinstance(blk, dict) and blk.get("frontDoor") is True:
                payload = {
                    "foundation": blk.get("foundation"),
                    "foundationWhy": blk.get("foundationWhy"),
                    "stack": blk.get("stack"),
                    "stackLabel": blk.get("stackLabel"),
                    "sourceFiles": blk.get("sourceFiles"),
                    "testRunner": blk.get("testRunner"),
                    # S195 — WHICH CLIs THIS MACHINE HAS, and which to
                    # preselect. Same rule as every other value here: the
                    # helper answers, the daemon relays. A build whose helper
                    # predates this round returns neither key, and the front
                    # end renders no engine control at all rather than
                    # inventing a list — an absence of information is never a
                    # reason to offer the captain a choice LCARS cannot honour.
                    "engines": blk.get("engines") or [],
                    "engine": blk.get("engine") or "",
                }
        except Exception:
            payload = None
        self._front_door_memo = (key, payload)
        return payload

    # --- S197: WHICH ENGINES THIS MACHINE HAS -------------------------------
    # THE DEFECT THIS SERVES. `lcars adopt` at the CLI ASKS which engine should
    # drive a mission here — the captain's ruling of 2026-09-09, taken because a
    # laptop may only have ONE CLI installed. The BOARD could not ask: its adopt
    # dispatch passed no `--engine` and ran with no tty, so adopt.sh took its
    # documented non-interactive path and REFUSED on exactly the machine the
    # feature exists for. The board is a UI of the command line (standing
    # ruling); where they disagree the board comes up to the CLI.
    #
    # ONE DETECTOR, NOT A SECOND ONE (ADR-002). `lcars_available_engines` in
    # skills/lcars-init/lcars-common.sh is the single answer `lcars init`, the
    # front door's engine picker and adopt.sh itself already read; this SOURCES
    # that library and calls the function. Re-implementing `command -v claude`
    # in Python would be the S168 scar again — two answers to one question, and
    # the board offering an engine adopt.sh would then refuse.
    #
    # LAZY AND MEMOIZED. It is only ever asked when there is an ADOPTABLE remote
    # card to offer it on, so a board with no forge overlay never spawns it at
    # all (which is also what keeps the byte-identity baselines untouched). The
    # memo has a short TTL rather than being permanent: a CLI installed while
    # the daemon is up should appear on the next minute, not on the next
    # restart.
    _ENGINES_TTL = 60.0

    def _engines_here(self):
        """The engines installed on THIS machine, canonical order. [] is honest."""
        now = time.time()
        memo = self._engines_memo
        if memo is not None and memo[0] > now:
            return list(memo[1])
        try:
            engines = list(self._read_engines())
        except Exception:
            engines = []
        self._engines_memo = (now + self._ENGINES_TTL, list(engines))
        return list(engines)

    def _engine_default(self):
        """The engine Number One's pickers open on — the shell's answer.

        Memoized beside `_engines_here` and on the same TTL, so a board build
        spawns at most one bash for it, and NEVER raises into a board build:
        an unanswerable question leaves the key off the meta, which is what
        keeps a board that has never heard of Number One byte-identical.
        """
        now = time.time()
        memo = self._engine_default_memo
        if memo is not None and memo[0] > now:
            return memo[1]
        try:
            default = self._read_engine_default()
        except Exception:
            default = ""
        self._engine_default_memo = (now + self._ENGINES_TTL, default)
        return default

    def _read_engine_default(self):
        lib = self._resolve_common_lib()
        if not lib:
            return ""
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        proc = subprocess.run(
            ["bash", "-c",
             '. "$1" >/dev/null 2>&1 || exit 0; lcars_xo_default_engine "$2"',
             "bash", lib, config],
            cwd=self.repo_root, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        out = (proc.stdout or b"").decode("utf-8", "replace")
        return out.strip().splitlines()[0].strip() if out.strip() else ""

    def _read_engines(self):
        if callable(self._engines_reader):
            return [str(e) for e in (self._engines_reader() or []) if e]
        lib = self._resolve_common_lib()
        if not lib:
            return []
        proc = subprocess.run(
            ["bash", "-c",
             '. "$1" >/dev/null 2>&1 || exit 0; lcars_available_engines',
             "bash", lib],
            cwd=self.repo_root, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        out = (proc.stdout or b"").decode("utf-8", "replace")
        return [ln.strip() for ln in out.splitlines() if ln.strip()]

    def _resolve_common_lib(self):
        """lcars-common.sh: env -> in-repo -> installed. Mirrors
        `_resolve_establish_vision_script`, so one override points both."""
        env = os.environ.get("LCARS_COMMON_LIB")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "lcars-common.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        installed = os.path.join(os.path.expanduser("~"), ".claude", "skills",
                                 "lcars-init", "lcars-common.sh")
        return installed if os.path.isfile(installed) else ""

    def _resolve_establish_vision_script(self):
        """establish-vision.sh: injected → env → in-repo → installed. Mirrors
        `_resolve_readiness_script` exactly, so a test can point both at a stub
        with one override."""
        if self._establish_vision_script:
            return self._establish_vision_script
        env = os.environ.get("LCARS_ESTABLISH_VISION_BIN")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "establish-vision.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        return os.path.join(os.path.expanduser("~"), ".claude", "skills",
                            "lcars-init", "establish-vision.sh")

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
            # S191: not here — but it may be a REMOTE card the board is showing.
            # Asked ONLY after the local lookup has failed, so a local mission can
            # never be answered from the forge cache, and answered from the SAME
            # cached listing the board was built from (no extra call).
            return self._remote_mission(mid)
        # S177: through the SAME memo the board uses. `mission()` used to call
        # `_card` directly, so S176's done-card memo never reached the DETAIL
        # path — and the Mission-Log overlay asks for one full detail per linked
        # child on every render (44 of them on DX-Scorecard, most already done).
        # `_done_card` hands back a shallow copy, so the detail-only keys added
        # below decorate the copy and can never leak onto a board card.
        card = self._done_card(d)
        if card is None:
            return None
        card.pop("_created", None)
        card["activity"] = self._activity(d)
        # S205 behaviour 1: `numberOne.report` — DETAIL-ONLY, present only when
        # the mission has a journal at all. `_done_card` may have handed back a
        # SHALLOW copy of a memoized card (S176: "no nested value is ever
        # mutated downstream") — `card["numberOne"]`, if present, can be the
        # SAME nested dict the memo holds, so this builds a FRESH dict rather
        # than mutating it in place. Mutating it would leak the detail-only
        # `report` key onto every future BOARD card for this mission too.
        xo_report = _number_one_report(d)
        if xo_report is not None:
            xo_existing = card.get("numberOne")
            xo_new = dict(xo_existing) if isinstance(xo_existing, dict) else {}
            xo_new["report"] = xo_report
            card["numberOne"] = xo_new
        # detail-only shape fields (S70-B): ADRs + verbatim acceptance criteria.
        card["adrs"] = _adrs_from_file(os.path.join(d, "adr.md"))
        card["criteria"] = _criteria_from_prd(os.path.join(d, "prd.md"))
        # S76: the verbatim PRD body, so the detail modal can render the full,
        # human-followable text. For a self-authored reconcile bug child this is the
        # detailed bug PRD (Conflict/failure summary, Root cause, Intended fix, …) —
        # the captain audits the self-heal straight from this. Empty string when
        # absent (non-crashing). The github adapter omits it (no local files).
        card["prd"] = _read_text(os.path.join(d, "prd.md"))
        # …and the forge's verdict, so the detail header's own `✓ Review PR`
        # is withdrawn by the same fact that withdraws the card's. BUG-049's
        # rule: the two surfaces gate identically or they gate wrongly.
        self._mark_shipped_elsewhere([card])
        return card

    def _remote_mission(self, mid):
        """The DETAIL for a remote card, or None. Never raises.

        Without this a remote card is a card that opens onto "no such mission" —
        the board showing the captain something and then denying it exists. The
        payload is the same one the card came from, with the three detail-only
        fields the forge cannot answer set to their honest empty values.
        """
        if self._remote is None:
            return None
        try:
            card = self._remote.mission(mid)
        except Exception:
            return None
        # S197: the detail is the other door onto the same card, and its header
        # carries the same Adopt. One fact, both surfaces (BUG-049's rule).
        if isinstance(card, dict):
            self._offer_engines(card)
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
        # S146: fold in config.json — a sanctioned testCommand write (the
        # --test-command / --fix-tests verbs) must move the fingerprint so SSE
        # pushes ONE update and every open board (incl. the File console's
        # inline warning) re-verdicts live. Missing file contributes nothing.
        config = os.path.join(self.repo_root, ".git", "lcars", "config.json")
        try:
            latest = max(latest, os.path.getmtime(config))
            seen = True
        except OSError:
            pass
        # S146-D2: for an INITIALIZED repo (config.json present — same gate as
        # _test_readiness) fold in a digest of the detection-marker signature,
        # so a stack/runner marker appearing, changing, or VANISHING (a max-
        # mtime fold could never see a deletion) moves the fingerprint and SSE
        # pushes an update — passive browsers re-fetch and the memo above
        # re-verdicts. An uninitialized/legacy repo skips this entirely, so its
        # fingerprint (including the "0" sentinel) stays byte-identical.
        if os.path.isfile(config):
            digest = hashlib.md5(
                repr(self._detect_signature()).encode("utf-8")).hexdigest()[:12]
            return ("%.6f" % latest if seen else "0") + "|" + digest
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

    def _dir_signature(self, d):
        """A cheap "has anything in this mission changed?" signature.

        (directory mtime, max file mtime, entry count). Max-mtime ALONE cannot
        see a DELETION — removing the newest artifact makes the max go *down*,
        and an older max only compares unequal by luck — so the directory's own
        mtime (which the kernel moves on any create/unlink) and the entry count
        ride along. One scandir per mission per render; the same walk shape
        `fingerprint()` already trusts for the whole board.

        Returns None when the directory cannot be read, which callers treat as
        "never memoize" rather than as a signature that happens to match.
        """
        try:
            dir_mtime = os.path.getmtime(d)
        except OSError:
            return None
        latest = 0.0
        count = 0
        try:
            with os.scandir(d) as entries:
                for e in entries:
                    count += 1
                    try:
                        latest = max(latest, e.stat().st_mtime)
                    except OSError:
                        return None
        except OSError:
            return None
        return (dir_mtime, latest, count)

    def _config_mtime(self):
        """config.json's mtime, or None. Part of the done-card memo key: `_card`
        resolves the displayed model mix through `_model_aliases()`, so a
        `modelAliases` edit legitimately changes a DONE card. Key on the mission
        dir alone and the memo would serve a stale mix for ever."""
        try:
            return os.path.getmtime(
                os.path.join(self.repo_root, ".git", "lcars", "config.json"))
        except OSError:
            return None

    def _done_card(self, d):
        """`_card`, memoized for missions that have finished.

        S176 part A. ONLY a card that came back `done` is cached: an in-flight
        mission carries live fields (`liveness`, `activeSecondsAt`, the
        events-derived in-flight stage) that must be recomputed every render,
        and there are only ever a handful of those. The whole win is in the
        tail of finished work, which is also the part that grows without bound.

        The caller gets a SHALLOW COPY, never the cached dict itself. `board()`
        pops the private `_created` sort key off every card (destructive) and
        `assemble()` writes `c["stage"]` (idempotent for a done card); both act
        on top-level keys only, and no nested value is ever mutated downstream.
        A shallow copy costs microseconds where a deepcopy of 51 cards would eat
        the render time this memo exists to buy back.
        """
        key = (self._dir_signature(d), self._config_mtime())
        if key[0] is not None:
            hit = self._card_memo.get(d)
            if hit is not None and hit[0] == key:
                return dict(hit[1])
        card = self._card(d)
        # Cache only a finished mission — and DROP a stale entry when a mission
        # leaves `done` (an `lcars feedback` send-back does exactly that), so an
        # entry can never outlive the card that earned it.
        if key[0] is not None and isinstance(card, dict) and card.get("stage") == "done":
            self._card_memo[d] = (key, dict(card))
        else:
            self._card_memo.pop(d, None)
        return card

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
        # S147 round 2: hand the repo's `modelAliases` to the shape layer so the
        # displayed tier resolves through the SAME policy run.sh uses. Without it
        # the board hard-coded "copilot ⇒ opus" and disagreed with the CLI on any
        # repo that overrode modelAliases.copilot.<tier>.
        model_mix = board.model_mix_from_estimate(
            est, engine=engine, model_aliases=self._model_aliases())

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
        # S218 fix round 1 (F1): a Stage that FAILED says so ON the card, where
        # the card already is (stage from the label, S191 — never moved). The
        # fact is the drive's RECORDED `error` event; absent (not null) for every
        # healthy mission, and hidden while a new run is live.
        failure = None if running else _stage_failure(events)
        if failure is not None:
            card["failure"] = failure
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
        # S196 A3(g): WHICH ENGINE, AND WHY THAT ONE.
        #
        # Until this session the only answer to that was one stderr line from
        # run.sh's resolver — `worker: claude (bin: config)` — which printed ZERO
        # times in a real 6-stage auto-advance run, was persisted nowhere, and
        # never reached this board. So a captain looking at a card whose worker
        # had been silently re-homed onto a billed engine had no surface that
        # could tell him.
        #
        # Both halves are RECORDED BY THEIR PRODUCER at the moment the choice is
        # made — `lcars adopt` when the captain picks the engine at the handoff
        # (`adopt-kept` / `adopt-converted` / `adopt-chosen`), and run.sh's
        # resolver when it resolves for a run (`env` / `mission` / `config` /
        # `detected` / `default`). This adapter READS them; it never re-derives
        # which source "would have" won, which is the inference three prior
        # sessions each paid fix rounds for.
        #
        # `engine` above stays what it always was (state.json.workerBin — the
        # mission's PIN). `engineResolved` is what actually ran, and the two
        # differ exactly when env/config/detection overrode the pin — which is
        # the case worth seeing. ABSENT (not null) for a mission that has never
        # recorded either, so every pre-S196 card payload is BYTE-IDENTICAL.
        eng_src = state.get("engineSource")
        if isinstance(eng_src, str) and eng_src.strip():
            card["engineSource"] = eng_src.strip()
        eng_res = state.get("engineResolved")
        if isinstance(eng_res, str) and eng_res.strip():
            card["engineResolved"] = eng_res.strip()
        # S160: the base-freshness badge. `lcars file` (S158) and `lcars run`
        # (S159) both stamp state.json.baseFreshness; both print their warning to
        # STDOUT, which the daemon swallows — so a captain filing from the board
        # never saw it. Surface it here, gated on the record's CARRIED `loud`.
        #
        # GATED ON `loud`, NEVER ON THE VERDICT NAME. `unknown` covers BOTH the
        # silent everyday no-remote repo and the loud unreachable-origin one, so
        # a verdict allowlist is provably wrong about one of them — which is
        # precisely why S158 made loudness its own field. ABSENT (not null) when
        # quiet, so an unaffected board is BYTE-IDENTICAL to pre-S160.
        bf = _base_freshness(state.get("baseFreshness"))
        if bf is not None:
            card["baseFreshness"] = bf
        # S190: WHOSE MISSION IS THIS. The login comes off the published-owner
        # file (a pure disk read — see _published_owner) and the avatar URL is
        # CONSTRUCTED from it by the shared shape builder, so both adapters emit
        # the identical block and the front end cannot tell them apart (ADR-003).
        #
        # ABSENT, not null, when there is no owner or none has been published —
        # so a board with no identity on it is byte-identical to before this
        # round, which is every other user's board and, on a machine with no gh,
        # the captain's too.
        owner = board.owner_block(self._published_owner(issue))
        if owner is not None:
            card["owner"] = owner
        # S201: DOES NUMBER ONE HAVE THE CONN HERE. The whole block is read off
        # the mission's OWN state.json — the file `lcars xo` and the driver
        # write and `ownership.sh xo-lock-reason` reads — so the card, the CLI
        # refusal and the daemon's 403 are all answering from one record.
        #
        # ABSENT, not null, whenever nothing is recorded (see board.xo_block),
        # which is every mission on every board this product has served until
        # today. NOTHING IS INFERRED: a mission is engaged because the record
        # says `engaged`, never because a worker looks busy.
        xo = board.xo_block(state.get("numberOne"))
        if xo is not None:
            # S214 fix round 1, D1 — THE SCORE WORD IS THE RECORDED ONE.
            # `xo/verdict.json` is where `xo-score.py` wrote the score; the
            # block above is the copy `xo.sh` took of it. When the two
            # disagree the copy is stale, and a stale block is stale ENTIRE —
            # it reverted as one line of one file — so the sentences beside
            # the stale word go with it and the two fallbacks just below
            # refill all three off the one record. When they agree there is
            # nothing to choose between and S213's precedence stands.
            recorded = _xo_recorded_score(d)
            if recorded and recorded != xo.get("score"):
                xo["score"] = recorded
                xo.pop("headline", None)
                xo.pop("meaning", None)
            # S213 C1 — THE ONE LINE, for a mission scored before this session.
            # `xo.sh` records `headline` on every look from now on; a mission
            # looked at earlier has the very same sentence sitting in its own
            # `xo/verdict.json` as `derivation`, written there by the code that
            # decided the score. Reading it back is reading a RECORD — the
            # alternative, cutting the worker's 150-word prose down to its
            # first sentence, would be this board deciding what Number One
            # meant, which is the class of defect that made S213 necessary.
            if "headline" not in xo:
                line = _xo_recorded_derivation(d)
                if line:
                    xo["headline"] = line
            # S213 fix round 1, D4 — and the score word's own meaning, on the
            # same footing: recorded beside the score in the mission's own
            # verdict.json, never a sentence the board keeps for the word.
            if "meaning" not in xo:
                said = _xo_recorded_meaning(d)
                if said:
                    xo["meaning"] = said
            card["numberOne"] = xo
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
        # S205 behaviour 2: Number One's own journal (number-one.jsonl) merges
        # into the SAME feed, `bot: "number-one"` marked so board.js renders
        # "◈ posted by Number One" in peach beside the ordinary lcars-bot
        # entries — inside the stage band where it happened (the S65 living-
        # comment model: one more producer into the one feed, never a second
        # feed). A journal entry's OWN recorded `stage` wins (cmd_answer can
        # escalate at any gate); every Verify-only action omits it on disk, so
        # it falls back to "verify", which is the only stage those actions are
        # ever written from — never a guess, a fact about which functions call
        # `journal()` without a stage field.
        for j in _load_jsonl(os.path.join(d, "number-one.jsonl")):
            if not isinstance(j, dict):
                continue
            stage = j.get("stage")
            if not (isinstance(stage, str) and stage.strip()):
                stage = "verify"
            entry = {
                "ts": j.get("at"),
                "stage": board.normalise_stage(stage),
                "type": "number-one",
                # `head` is the human HEADLINE (board.js's headlineFor reads
                # it for a number-one entry, exactly as it reads EVENT_HEADS
                # off an ordinary event's `type`); `detail`/`text` is the best
                # available DETAIL sentence alone, never repeating the
                # headline, so the feed's existing headline+txt rendering
                # never shows "Scored the build — Scored the build".
                "head": _number_one_label(j),
                "detail": _number_one_detail(j),
                "text": _number_one_detail(j),
                "bot": "number-one",
            }
            feed.append(entry)
        feed.sort(key=_activity_sort_key)
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


# --- S218 fix round 1 (F1): the Stage failure the drive RECORDED -------------
# run.sh's drive writes ONE `error` event when a Stage stops without advancing:
# its `stage` is the Stage that RAN (S214 D2), its `detail` the whole sentence,
# and — since S218 — `data.log` the failure log that run wrote, when it wrote
# one. The daemon's refused START records the same event. A later
# `stage_start` (a new run began), `stage_done` (a Stage finished) or `gate`
# (the run stopped on a question instead) supersedes it. Only an event carrying
# `data.stageFailure: 1` (fix round 2, D2) counts — anything unmarked is
# history, never a surfaced failure. Returns
# {stage, sentence, log} or None. Reads the event TYPE and fields only — never
# the sentence's words. Crash-proof: a malformed row is skipped.
def _stage_failure(events):
    failure = None
    for ev in (events or []):
        if not isinstance(ev, dict):
            continue
        typ = ev.get("type")
        if typ == "error":
            data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
            # S218 fix round 2 (D2): only an error the drive MARKED as a
            # structured Stage failure. Unmarked ones (all pre-S214 history,
            # some recorded against `align` with a beheaded sentence) stay in
            # the activity feed and are never surfaced here — nor reinterpreted.
            if data.get("stageFailure") != 1:
                continue
            log = data.get("log")
            failure = {
                "stage": board.normalise_stage(ev.get("stage") or ""),
                "sentence": ev.get("detail") or "",
                "log": log if isinstance(log, str) and log.strip() else None,
            }
        elif typ in ("stage_start", "stage_done", "gate"):
            failure = None
    return failure


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
    # S178 — the wave SHAPE, derived from the waves this function already reads.
    # MEASURED 2026-08-28: one Plan Review objection made the planner serialise a
    # 14-ticket plan, Schedule honoured the graph into 14 waves of one ticket
    # each, and nothing on the board said so — wavesTotal and ticketsTotal were
    # both already here, and the captain still had to open waves.json. This is a
    # READOUT, never a gate; a genuinely serial plan says the same thing honestly.
    peak = 0
    if isinstance(waves, list):
        for w in waves:
            if isinstance(w, dict):
                peak = max(peak, len(w.get("tickets") or []))
    shape = None
    if waves_total and tickets_total:
        if tickets_total == 1:
            # This is the CLI's own phrase, upper-cased for the board's pill
            # style: run.sh's wave_shape_line prints "Wave shape: a single ticket
            # — nothing to parallelise." Two surfaces describing the same plan
            # must not disagree, so tests/replan-overcorrection.test.sh DERIVES
            # this string from that one rather than comparing two hand-copied
            # literals — drift fails the suite instead of reaching the captain.
            shape = "A SINGLE TICKET — NOTHING TO PARALLELISE"
        elif waves_total == 1:
            shape = "1 WAVE · ALL %d IN PARALLEL" % tickets_total
        elif peak <= 1:
            shape = "%d WAVES · 1 TICKET EACH — NO PARALLELISM" % waves_total
        else:
            shape = "%d WAVES · UP TO %d IN PARALLEL" % (waves_total, peak)
    return {
        "wave": cur_wave,
        "wavesTotal": waves_total,
        "ticketsDone": tickets_done,
        "ticketsTotal": tickets_total,
        "peakParallel": peak,
        "shape": shape,
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


# --- S205: Number One's journal (number-one.jsonl), merged into the feed ----
# ONE line per action Number One recorded — see xo.sh's `journal()`. This is a
# READ, never an inference: the label names the ACTION xo.sh already wrote,
# and the detail is whichever of the entry's OWN recorded fields best explains
# it, in the same priority order the CLI report (xo-report.py) uses. Nothing
# here parses a human sentence to guess what happened.
_NUMBER_ONE_LABELS = {
    "criteria": "Read the drawing",
    "launched": "Launched the build",
    "looked": "Looked at the build",
    "actions": "Drove the build",
    "silent": "Nothing to report this round",
    "scored": "Scored the build",
    "score-overruled": "Corrected its own score",
    "filed-logs": "Filed bugs for the gaps",
    "overflow": "Some gaps were not filed",
    "answered": "Answered the gate",
    "escalated": "Escalated to you",
    "relaunched": "Relaunched the build",
    "fix-did-not-hold": "A fix did not hold",
    "rescored": "Re-scored after the fixes",
    "stood-down": "Stood down",
    "ledger-note": "Noted something about the ledger",
}
_NUMBER_ONE_DETAIL_KEYS = ("detail", "why", "note", "summary", "answer",
                           "rationale", "url")


def _number_one_label(entry):
    """The human HEADLINE — board.js's `headlineFor` reads this off `head`
    for a `type: "number-one"` entry, the same way it reads `EVENT_HEADS` off
    an ordinary event's `type`."""
    return _NUMBER_ONE_LABELS.get(entry.get("action"), entry.get("action") or "?")


def _number_one_detail(entry):
    """The best-available detail sentence, or "" — never duplicates the
    label (unlike the combined form, this rides in `text`/`detail` ALONE, so
    board.js's existing `.txt` line never repeats the headline)."""
    for k in _NUMBER_ONE_DETAIL_KEYS:
        v = entry.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def _number_one_text(entry):
    """Kept for callers that want ONE combined "Label — detail" sentence
    (the CLI-flavoured form; xo-report.py's own `_fmt_entry` does the same
    thing independently, in bash's/CLI's own voice)."""
    label = _number_one_label(entry)
    detail = _number_one_detail(entry)
    return "%s — %s" % (label, detail) if detail else label


def _xo_block_from_state(state):
    xo = state.get("numberOne") if isinstance(state, dict) else None
    return xo if isinstance(xo, dict) else {}


def _number_one_shot_status(logs_doc, journal):
    """{criterion: "held"|"not-held"|"pending"} — READ off two records, never
    inferred: a log is "not-held" ONLY when a `fix-did-not-hold` journal entry
    names its criterion; it is "held" once a `rescored` entry exists (a
    successful recheck accepted the whole batch) and nothing named it as not
    holding; anything else — no recheck has run yet — is "pending"."""
    not_held = set()
    rescored = False
    for j in journal:
        if not isinstance(j, dict):
            continue
        if j.get("action") == "fix-did-not-hold":
            c = j.get("criterion")
            if isinstance(c, str) and c.strip():
                not_held.add(c.strip())
        elif j.get("action") == "rescored":
            rescored = True
    out = {}
    filed = logs_doc.get("filed") if isinstance(logs_doc, dict) else None
    for f in (filed or []):
        if not isinstance(f, dict):
            continue
        crit = f.get("criterion")
        if not isinstance(crit, str):
            continue
        if crit in not_held:
            out[crit] = "not-held"
        elif rescored:
            out[crit] = "held"
        else:
            out[crit] = "pending"
    return out


def _number_one_report(d):
    """`numberOne.report` on the mission DETAIL payload — verdict(s), the
    filed gaps with their held/not-held/pending status, the shots directory
    the current verdict's pictures live in, and a journal tail. Present ONLY
    when the mission has a journal at all (S205 behaviour 1) — a mission
    Number One has never looked at gets no `report` key, ever, not an empty
    one.

    EVERY FIELD IS A DISK READ. Nothing here re-derives what a verdict MEANS;
    it reads xo/verdict.json, xo/second/verdict.json (falling back to the
    legacy xo/verdict-2.json name), xo/logs.json and xo/look.txt exactly as
    xo.sh itself left them.
    """
    journal_path = os.path.join(d, "number-one.jsonl")
    if not os.path.isfile(journal_path):
        return None
    journal = _load_jsonl(journal_path)

    state = _load_json(os.path.join(d, "state.json"))
    state = state if isinstance(state, dict) else {}
    xo = _xo_block_from_state(state)

    xodir = os.path.join(d, "xo")
    verdict = _load_json(os.path.join(xodir, "verdict.json"))
    verdict2 = _load_json(os.path.join(xodir, "second", "verdict.json"))
    if verdict2 is None:
        verdict2 = _load_json(os.path.join(xodir, "verdict-2.json"))

    logs_doc = _load_json(os.path.join(xodir, "logs.json"))
    status_by_crit = _number_one_shot_status(logs_doc, journal)
    logs_out = []
    if isinstance(logs_doc, dict):
        for f in (logs_doc.get("filed") or []):
            if not isinstance(f, dict):
                continue
            crit = f.get("criterion")
            issue = f.get("issue")
            if isinstance(issue, str) and issue.isdigit():
                issue = int(issue)
            elif not isinstance(issue, int):
                issue = None
            shots = f.get("shots")
            shots = [s for s in shots if isinstance(s, str)] if isinstance(shots, list) else []
            logs_out.append({
                "n": f.get("n"),
                "mission": f.get("mission"),
                "issue": issue,
                "criterion": crit,
                "title": f.get("title"),
                "shots": shots,
                "status": status_by_crit.get(crit, "pending") if isinstance(crit, str) else "pending",
            })

    # xo/look.txt: the ONE recorded pointer to where the CURRENT verdict's
    # pictures live (S204) — never re-derived by guessing which shots dir goes
    # with which verdict.
    #
    # THE NORMALISING BOUNDARY (fix round 2, D1): xo.sh:1328 writes look.txt
    # relative to xodir — "shots/<look>" — because that is what `file-logs`
    # (xo.sh:712, `xo_verdict_shots_dir`) reads it back as: `$xodir/$rel`.
    # That reader is untouched here and still gets the on-disk form verbatim
    # via `rel` below. But `report.shotsDir` is a DIFFERENT contract: it is
    # composed by board.js's `xoShotUrl` onto `/api/xo/shot/<mission>/…`,
    # whose `rel` argument `_xo_shot_path` resolves against the room
    # `<mission>/xo/shots/` — i.e. relative to xo/shots, not to xodir. Those
    # two contracts disagree by exactly one leading "shots" segment, which is
    # why every thumbnail 404ed (doubled `xo/shots/shots/…`). This is the
    # ONE place the pointer crosses from the CLI's on-disk contract into the
    # web API's: strip one leading "shots" path segment here, once, rather
    # than lstrip-ing it in the route, in board.js, and in a test fixture.
    #
    # Missions recorded before this fix (S204) already have look.txt in the
    # "shots/<look>" form — this still reads them: `rel` is unchanged and the
    # isdir check below still resolves against xodir exactly as before, only
    # the VALUE handed to the API is normalised. A fixture or a future writer
    # that already recorded the normalised "<look>" form (no "shots" prefix)
    # passes through untouched too — the strip only fires when the first
    # segment literally is "shots".
    shots_dir = "shots"
    look_txt = os.path.join(xodir, "look.txt")
    try:
        with open(look_txt, encoding="utf-8") as fh:
            rel = fh.readline().strip()
        if rel and os.path.isdir(os.path.join(xodir, rel)):
            segs = rel.split("/")
            if segs and segs[0] == "shots":
                segs = segs[1:]
            shots_dir = "/".join(segs) if segs else "shots"
    except OSError:
        pass

    journal_sorted = sorted(
        (j for j in journal if isinstance(j, dict)),
        key=lambda j: _activity_sort_key({"ts": j.get("at")}), reverse=True)

    return {
        "score": xo.get("score"),
        "score2": xo.get("score2"),
        "status": xo.get("status"),
        "engine": xo.get("engine"),
        "verdict": verdict if isinstance(verdict, dict) else None,
        "verdict2": verdict2 if isinstance(verdict2, dict) else None,
        "logs": logs_out,
        "shotsDir": shots_dir,
        "journal": journal_sorted,
    }


def _xo_recorded_score(mission_dir):
    """The score this mission's own `xo/verdict.json` RECORDS, or "".

    `xo-score.py` is the producer: it decides the word and writes it here, and
    nothing downstream is entitled to a second opinion. `state.numberOne.score`
    is a COPY of this value, made by `xo.sh`'s one finisher at the moment of
    the look — and a copy can go stale. On the captain's own disk one of seven
    missions had been looked at twice, and a later writer holding a stale
    `state.json` put the FIRST look's block back; the ledger was never
    reverted, so the board drew HIGH over a mission this file records as LOW.

    THIS READS ONE FIELD AND COUNTS NOTHING. The `counts` sitting beside it in
    the same document would ratio to "high" for exactly that mission. Working a
    score out of them is the second opinion whose existence is the defect."""
    try:
        with open(os.path.join(mission_dir, "xo", "verdict.json"),
                  encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return ""
    if not isinstance(doc, dict):
        return ""
    score = doc.get("score")
    return score.strip() if isinstance(score, str) and score.strip() else ""


def _xo_recorded_derivation(mission_dir):
    """The one-line verdict this mission's own `xo/verdict.json` records, or
    "". Never the worker's `summary` — that is the transcript the card is
    being freed of — and never anything derived by reading either of them."""
    try:
        with open(os.path.join(mission_dir, "xo", "verdict.json"),
                  encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return ""
    if not isinstance(doc, dict):
        return ""
    line = doc.get("derivation")
    return line.strip() if isinstance(line, str) and line.strip() else ""


def _xo_recorded_meaning(mission_dir):
    """What the score WORD means for this mission, off this mission's own
    `xo/verdict.json` — or "" when the verdict cannot support a sentence.

    RECORDED FIRST. `scoreMeaning` is written beside the score by the code that
    decided the score (S213 fix round 1). When it is there, it is read back
    verbatim and nothing else happens.

    DERIVED FROM THE LEDGER SECOND (fix round 3, D4-RESIDUAL). Every mission
    scored BEFORE that round carries no `scoreMeaning` at all — which is every
    mission on the captain's real disk — and the board used to explain those
    scores with one fixed sentence per word, MEDIUM's claiming a primary flow
    that worked end to end. The tester opened such a mission and was told
    exactly that about a build whose every criterion was untested. So where
    there is no recorded sentence the counts in the same file answer instead:
    see `_xo_meaning_from_ledger`.

    AND OTHERWISE, SILENCE. No file, unreadable file, or a verdict with no
    ledger in it at all ⇒ "" ⇒ no `meaning` on the card and an empty tooltip.
    A surface must never assert what no record supports."""
    try:
        with open(os.path.join(mission_dir, "xo", "verdict.json"),
                  encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return ""
    if not isinstance(doc, dict):
        return ""
    said = doc.get("scoreMeaning")
    if isinstance(said, str) and said.strip():
        return said.strip()
    return _xo_meaning_from_ledger(doc)


def _xo_ledger_counts(doc):
    """(met, gap, untested) as this verdict RECORDS them, or None.

    `counts` is what `xo-score.py` has written since Number One's first look;
    an older or hand-written verdict may carry only the `criteria` rows, so
    they are tallied instead — arithmetic over recorded statuses, which is
    still the record answering. A verdict with neither answers None, and None
    means nothing is said at all."""
    counts = doc.get("counts")
    if isinstance(counts, dict):
        got = []
        for key in ("met", "gap", "untested"):
            v = counts.get(key)
            got.append(v if isinstance(v, int) and not isinstance(v, bool)
                       and v >= 0 else 0)
        if sum(got):
            return tuple(got)
    rows = doc.get("criteria")
    if isinstance(rows, list) and rows:
        tally = {"met": 0, "gap": 0, "untested": 0}
        for row in rows:
            if not isinstance(row, dict):
                continue
            st = str(row.get("status") or "").strip().lower()
            if st in tally:
                tally[st] += 1
        if sum(tally.values()):
            return (tally["met"], tally["gap"], tally["untested"])
    return None


def _xo_meaning_from_ledger(doc):
    """One sentence about THIS ledger, built from its own counts, or "".

    IT STATES ARITHMETIC AND NOTHING ELSE. Every number in it is one the
    verdict itself records, and no clause claims anything the numbers do not
    hold — no flow is described, no build is vouched for, no cause is guessed
    at. That is the whole difference between this and the three fixed
    sentences it replaces: those asserted a fact about a specific build from
    nothing but the score word, and one of them was wrong every time the score
    came from an all-untested ledger.

    Written to the captain, in his product's words: things on a list he wrote,
    which either checked out, fell short, or could not be checked."""
    counts = _xo_ledger_counts(doc)
    if counts is None:
        return ""
    met, gap, untested = counts
    total = met + gap + untested
    things = "thing" if total == 1 else "things"
    if untested == total:
        return ("I could not check any of the %d %s on your list, so nothing "
                "here is vouched for" % (total, things))
    if met == total:
        return ("All %d %s on your list checked out" % (total, things))
    said = []
    if met:
        said.append("%d checked out" % met)
    if gap:
        said.append("%d fell short" % gap)
    if untested:
        said.append("%d I could not check" % untested)
    if len(said) > 1:
        said = [", ".join(said[:-1]), said[-1]]
    return ("Of the %d %s on your list, %s"
            % (total, things, " and ".join(said)))


def _activity_sort_key(entry):
    """A chronological key for an activity entry whose `ts` may be an events.
    jsonl epoch (int/float) OR a number-one.jsonl ISO-8601 string — so the two
    producers interleave in true time order. Never raises: an unparsable
    timestamp sorts as 0 (oldest), same posture every other lenient reader in
    this file takes toward a malformed record."""
    ts = entry.get("ts")
    if isinstance(ts, (int, float)):
        return float(ts)
    if isinstance(ts, str):
        try:
            dt = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
            return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            return 0.0
    return 0.0


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


# --- S205: xo-report.py, imported once per resolved path ---------------------
_XO_REPORT_MODULE_CACHE = {}


# --- S205 behaviour 3: the xo shot route's jail ------------------------------
# A COPY of the holodeck preview's own jail shape (actions.py's
# `_room_file_path`) — same checks, same order: refuse an absolute path, a
# drive letter, or any `..` SEGMENT before ever touching the filesystem, then
# resolve the REAL path and verify it is still inside the room. Two jails
# guarding two different rooms is right here (the holodeck's room is
# model-written content; a mission's `xo/shots/` is the driver's own
# screenshots) — what would be wrong is checking containment two DIFFERENT
# ways, so this checks it the same proven way.
def _xo_shot_path(mission_dir, rel):
    """The real, contained path for `rel` under `<mission_dir>/xo/shots/`, or
    None when it is missing, malformed, or would escape that tree."""
    rel = rel or ""
    if "\x00" in rel:
        return None
    if rel.startswith("/") or rel.startswith("\\") or ":" in rel.split("/")[0]:
        return None
    parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    room = os.path.realpath(os.path.join(mission_dir, "xo", "shots"))
    target = os.path.realpath(os.path.join(room, *parts))
    if target != room and not target.startswith(room + os.sep):
        return None
    return target


_BASE_FRESHNESS_KEYS = ("verdict", "loud", "reason", "fix", "fixNote",
                        "blocker", "behindBy", "aheadBy", "baseSha",
                        "checkedAt", "missionBranchAtBase")


def _base_freshness(rec):
    """state.json.baseFreshness → the additive card block, or None when quiet.

    The gate is the record's CARRIED `loud`, never its verdict name (see _card).

    Fields pass through VERBATIM. The guard already wrote one honest sentence
    naming what happened (`reason`), the exact command that clears it (`fix` —
    ONE runnable line or nothing, since S158 caught seven that could not
    succeed and a tester later pasted two more that were not commands at all),
    the prose beside it (`fixNote`), and WHAT is blocking (`blocker`, which the
    badge headline is built from — a headline derived from `behindBy` names the
    benign half of a dirty-and-behind base). The board's job is to DISPLAY
    those, not to compose a second opinion about git state from the numbers. In
    particular `behindBy`/`aheadBy` stay None when
    staleness was never measured: `0` is reserved for a measured zero, and a
    reassuring zero from a check that measured nothing is the one lie a consumer
    cannot detect.

    A shapeless record never raises: `.get` fills the missing keys with None.
    """
    if not isinstance(rec, dict) or not _truthy(rec.get("loud")):
        return None
    return {k: rec.get(k) for k in _BASE_FRESHNESS_KEYS}


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
