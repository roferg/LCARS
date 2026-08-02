#!/usr/bin/env bash
#
# lcars launch — get a Mission's app running locally so the captain can view it
# during Verify. This is the mechanical half of `lcars launch`; SKILL.md documents
# the surface. The architecture (fixed by the gating spike, do NOT relitigate):
#
#   The `launch` cold-worker DISCOVERS ONLY; the SKILL executes the launch
#   detached. Headless Copilot denies backgrounding (`&`/pipes) even with
#   --allow-all-tools, so a worker cannot reliably detach a dev server; and
#   skill-owned launching gives one clean, capturable process-group id for a
#   reliable `--stop` (and, next session, daemon tracking). Engine-agnostic.
#
# The flow:
#   1. resolve the mission → its branch (state.json) → the branch-tip SHA
#   2. `git worktree add --detach` that SHA into a DISPOSABLE worktree BESIDE the
#      repo (never inside `.git/` — see the S167 note at the launch-root block).
#      DETACHED is critical: a branch checkout HOLDS the ref and blocks the
#      Implement replay gate from landing fixes on that branch; detached checks out
#      the CONTENT without holding the ref. Idempotent — reuse an existing worktree.
#   3. spawn the `launch`-role worker (engine from state.json workerBin, or
#      $LCARS_WORKER_BIN) via the worker-adapter. It inspects the checkout and
#      writes launch.json {target,command,cwd,url,howToStop,status=ready|failed}.
#      It never starts anything itself.
#   4. the SKILL reads launch.json. failed/missing/invalid → plain-English refusal,
#      non-zero. ready → launch `command` in <wt>/<cwd> DETACHED (its own process
#      group), redirecting output to a log under the mission dir; POLL liveness
#      across a settle window (dev servers can take ~1–2s to fail) → death anywhere
#      in the window sets status=failed and prunes the worktree. surviving the whole
#      window → final launch.json status=running + an LCARS-voice readout
#      (target / url / howToStop).
#   5. `--stop` kills the whole process GROUP, sets status=stopped, prunes the
#      launch worktree. Idempotent; a re-launch after stop works.
#
# Failures are plain English (UX-33): name what went wrong + what to try, never a
# raw stack trace and never a bare CLI command as the primary line.
#
# Dependencies via env so tests can stub them:
#   LCARS_GIT_BIN         the git binary               (default: git)
#   LCARS_WORKER_BIN      the cold-worker CLI          (default: state workerBin → claude)
#   LCARS_WORKER_ADAPTER  the worker-adapter path      (default: ../lcars-run/worker-adapter.sh)
#   LCARS_LAUNCH_SETTLE   liveness poll WINDOW seconds  (default: 4, may be fractional)
#   LCARS_LAUNCH_ROOT     deploy-checkout root         (default: <repo-parent>/.lcars-launch/<repo>)
#   LCARS_NOW             ISO startedAt stamp          (default: now, UTC)
#
set -uo pipefail

GIT_BIN="${LCARS_GIT_BIN:-git}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SETTLE="${LCARS_LAUNCH_SETTLE:-4}"

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
WORKER_ADAPTER="${LCARS_WORKER_ADAPTER:-$SKILL_DIR/../lcars-run/worker-adapter.sh}"

die() { printf 'lcars launch: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq) --------------------------------------------
# String field: the escape-aware idiom run.sh uses (handles \" inside values).
json_str() {
  sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" | head -1
}
# Bare token (number/bool/null).
json_raw() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}
# JSON-escape a string for safe embedding in the launch.json we WRITE.
json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# Sub-second wait via perl (no `sleep` binary dependency).
nap() { perl -e 'select(undef,undef,undef,'"${1:-0.3}"')' 2>/dev/null || true; }

# --- args -----------------------------------------------------------------
# lcars launch <mission> [hint words…] [--stop]
# lcars launch --main [hint words…] [--stop]      (deploy the LOCAL main HEAD)
MISSION=""
HINT=""
STOP=0
MAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --main) MAIN=1; shift ;;
    --stop) STOP=1; shift ;;
    --) shift ;;
    --*) die "unknown option \"$1\" — usage: lcars launch <mission> [hint] [--stop], or lcars launch --main [hint] [--stop]." ;;
    *)
      # In --main mode there is no mission slot — every positional is a hint word.
      if [ "$MAIN" -eq 0 ] && [ -z "$MISSION" ]; then
        MISSION="$1"
      elif [ -z "$HINT" ]; then
        HINT="$1"
      else
        HINT="$HINT $1"
      fi
      shift ;;
  esac
done

# --- locate the repo + the mission dir ------------------------------------
GIT_DIR="$("$GIT_BIN" rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from the mission's repo root."
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
# Canonicalize (resolve symlinks, e.g. macOS /var → /private/var) so paths we
# build compare EQUAL to the ones `git worktree list` reports — the reuse check
# below relies on that exact-string match.
GIT_DIR="$(cd "$GIT_DIR" 2>/dev/null && pwd -P)" || die "cannot resolve the git directory."

LCARS_DIR="$GIT_DIR/lcars"
LCARS_CFG="$LCARS_DIR/config.json"
MISSIONS_DIR="$LCARS_DIR/missions"

# --- S167: where a DEPLOY CHECKOUT lives — OUTSIDE `.git/` ------------------
# Deploys used to be cut at `$LCARS_DIR/launch/<key>`, i.e. inside the repo's own
# `.git/`. Vite's default `server.watch.ignored` contains `**/.git/**`, so the
# whole deploy matched an ignore pattern and chokidar watched NOTHING: the dev
# server booted, served pages, and then never saw another change — no HMR, no
# `import.meta.glob` re-evaluation, no re-read of data files. Every watcher-based
# tool (webpack, nodemon, Tailwind JIT, `tsc --watch`) is affected identically.
# MEASURED on DX-Scorecard 2026-07-31, same commit, two locations, one
# `data/snapshots/*.json` added while the server ran: inside `.git/` the served
# glob stayed at 1 entry indefinitely; outside it reached 2 within 5 seconds. Only
# the path differed. That made a deploy MISLEADING rather than merely limited — it
# looks like a working app, so a fix whose effect depends on reading changed files
# back reads as STILL BROKEN when it is in fact correct (two correctly-fixed bug
# missions, lcars-20260801-004 and -006, both presented as failures).
#
# So the CHECKOUT moves to a sibling of the repo, keyed by the repo's CANONICAL
# parent + basename:   <repo-parent>/.lcars-launch/<repo-name>/<mission|@main>
#   • OUTSIDE `.git/`  — file watchers work.
#   • OUTSIDE the repo — a full second copy of the repo INSIDE it gets swept up by
#     the PARENT's own test globs and watchers (vitest's default `include` would
#     collect the deploy's test files as if they were the captain's), and
#     `.git/info/exclude` does not stop a glob. Outside is the only safe shape.
#   • Keyed by the CANONICAL repo path (`pwd -P`), so two repos sharing a basename
#     under different parents can never fold together, and a symlinked route to one
#     repo always resolves to that repo's single root.
# STATE does NOT move. launch.json, launch-discovery.json, launch.log and every
# mission artifact stay under `.git/lcars` — the board's SSE fingerprint reads
# their mtimes. Only the disposable checkout relocates. (Likewise out of scope:
# run.sh's front-half `stage-tree` worktrees stay under `.git/lcars` — those five
# Stages are read-only and never run the repo.)
REPO_TOP="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_TOP" ] || REPO_TOP="$(dirname "$GIT_DIR")"
REPO_TOP="$(cd "$REPO_TOP" 2>/dev/null && pwd -P)" \
  || die "cannot resolve this repository's root directory."
LAUNCH_ROOT="${LCARS_LAUNCH_ROOT:-$(dirname "$REPO_TOP")/.lcars-launch/$(basename "$REPO_TOP")}"
# Belt and braces: refuse legibly rather than hand back a deploy that silently
# cannot see its own writes. TWO different causes reach this one guard, and each
# has a DIFFERENT fix — so each gets its own message. Saying "run from the repo's
# own checkout" to someone who set $LCARS_LAUNCH_ROOT is a dead end: they already
# are, and the message never names the thing they'd have to change.
case "/$LAUNCH_ROOT/" in
  */.git/*)
    if [ -n "${LCARS_LAUNCH_ROOT:-}" ]; then
      # The override is what put it there. Name the variable — it is the one
      # thing the operator can change.
      die "can't deploy into a .git directory — \$LCARS_LAUNCH_ROOT is set to \"$LCARS_LAUNCH_ROOT\", which is inside one. File watchers ignore .git, so the app there could never see its own changes. Point LCARS_LAUNCH_ROOT at a directory outside any .git, or unset it to use the default beside the repo."
    fi
    # No override: the root was DERIVED from a repo that itself lives under a
    # `.git/` — e.g. invoked from inside one of run.sh's stage-tree worktrees.
    # Here, moving to the real checkout genuinely is the fix.
    die "can't place the deploy outside .git from here — \"$LAUNCH_ROOT\" is itself inside a .git directory. Run \`lcars launch\` from the repo's own checkout."
    ;;
esac
# The PRE-S167 location. A captain mid-round may still have a deploy checked out
# here; it is migrated away (removed + pruned) on the next launch or stop.
OLD_LAUNCH_ROOT="$LCARS_DIR/launch"

# --- resolve the TARGET: a mission, or the local main deploy (--main) -------
# This is the ONE seam --main adds. Everything downstream is target-agnostic: it
# works off MDIR (state home), WT (disposable worktree), BRANCH, and (below) a
# resolved SHA — whether those describe a mission or the local main deploy. No
# code path is forked; only these four handles are set differently up here.
if [ "$MAIN" -eq 1 ]; then
  # --main takes NO mission id. Catch the two ways one slips in: a positional
  # parsed as a mission BEFORE --main (`lcars launch m1 --main`), or a hint word
  # that actually names an existing mission (`lcars launch --main m1`).
  [ -z "$MISSION" ] \
    || die "\`--main\` deploys the local main branch and takes no mission id — run \`lcars launch $MISSION\` for that mission, or \`lcars launch --main\` for the deploy."
  _h1="${HINT%% *}"
  if [ -n "$_h1" ] && [ -d "$MISSIONS_DIR/$_h1" ]; then
    die "\"$_h1\" is a mission, not a hint — drop \`--main\` to launch it (\`lcars launch $_h1\`), or reword your hint."
  fi

  # Resolve the local default branch — NO fetch, EVER (the same local rev-parse
  # the mission path uses). Preference: config mainBranch → local main → master.
  BRANCH=""
  [ -f "$LCARS_CFG" ] && BRANCH="$(json_str "$LCARS_CFG" mainBranch)"
  case "$BRANCH" in ''|null) BRANCH="" ;; esac
  if [ -z "$BRANCH" ]; then
    if "$GIT_BIN" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
      BRANCH="main"
    elif "$GIT_BIN" rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1; then
      BRANCH="master"
    else
      die "no main/master branch — set mainBranch in .git/lcars/config.json"
    fi
  fi

  # State home for the deploy: holds launch.json + launch-discovery.json ONLY —
  # no mission dir, no state.json. The worktree uses the RESERVED @main path.
  MDIR="$LCARS_DIR/main"
  STATE=""                                 # there is no state.json for a deploy
  mkdir -p "$MDIR"
  WT="$LAUNCH_ROOT/@main"                  # reserved key for the main deploy
  OLD_WT="$OLD_LAUNCH_ROOT/@main"          # its pre-S167 in-`.git/` location
else
  [ -n "$MISSION" ] \
    || die "name a mission to launch — e.g. \`lcars launch <mission-id>\` — or deploy the local main HEAD with \`lcars launch --main\`."
  [ "$MISSION" = "@main" ] \
    && die "\"@main\" is reserved for the main deploy — run \`lcars launch --main\` instead."
  MDIR="$MISSIONS_DIR/$MISSION"
  STATE="$MDIR/state.json"
  [ -d "$MDIR" ] || die "no mission \"$MISSION\" here — check the id, or file it first."
  [ -f "$STATE" ] || die "mission \"$MISSION\" looks incomplete (no state.json) — re-file it before launching."
  WT="$LAUNCH_ROOT/$MISSION"               # the disposable detached worktree
  OLD_WT="$OLD_LAUNCH_ROOT/$MISSION"       # its pre-S167 in-`.git/` location
  BRANCH="$(json_str "$STATE" branch)"
fi

LAUNCH_JSON="$MDIR/launch.json"          # the record both CLI + daemon read
# S111 (RUN-button flash fix): the discovery worker gets its OWN answer file —
# it must NEVER write the shared launch.json directly. Its {status:"ready"}
# answer sitting in launch.json between worker-end and the final "running"
# write made the board briefly render the idle RUN affordance mid-launch (the
# captain saw the button flash). launch.json is now written ONLY by this skill,
# ONLY atomically (commit_launch_json), and only ever carries
# launching|running|failed|stopped.
LAUNCH_DISCOVERY="$MDIR/launch-discovery.json"

# Atomically commit stdin as the new launch.json: write a temp sibling, then
# `mv -f` (an atomic rename on the same filesystem) — a concurrent board poll
# reads either the OLD record or the NEW one, never a truncated half-write.
commit_launch_json() { # (json on stdin)
  local tmp="$LAUNCH_JSON.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$LAUNCH_JSON"
}
LOG="$MDIR/launch.log"                   # the app's captured stdout+stderr
OUTDIR="$MDIR/.launch-work"              # the worker's answer channel

# --- provision a freshly-created launch worktree --------------------------
# A disposable DETACHED worktree checks out the mission's CONTENT but has no
# installed dependencies (its node_modules / venv / etc. are absent), so a real
# Node/pnpm app dies instantly ("electron-vite: command not found …"). Mirror
# run.sh's provision_worktree(): run the repo's configured `worktreeSetupCommand`
# ONCE with the worktree as CWD, right after `git worktree add` and BEFORE the app
# is launched. Resolution: the env override ($LCARS_WORKTREE_SETUP_CMD) wins, else
# the repo config (worktreeSetupCommand). With NO command configured this is a safe
# NO-OP (rc 0) so LCARS's own dependency-free dogfood stays unaffected. BEST-EFFORT:
# a non-zero provisioning exit does NOT abort the launch — the subsequent app-launch
# surfaces its own human-readable failure if deps truly cannot be provisioned. It is
# purely additive: it never changes the worktree from its --detach checkout.
provision_worktree() { # worktree-path → 0 (no-op or success), else the command's rc
  local wt="$1" cmd rc=0
  if [ -n "${LCARS_WORKTREE_SETUP_CMD:-}" ]; then
    cmd="$LCARS_WORKTREE_SETUP_CMD"
  else
    [ -f "$LCARS_CFG" ] || return 0
    cmd="$(json_str "$LCARS_CFG" worktreeSetupCommand)"
  fi
  case "$cmd" in ''|null) return 0 ;; esac
  # Run ONCE with the worktree as CWD; best-effort — swallow a non-zero exit.
  ( cd "$wt" && bash -c "$cmd" ) >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# --- worktree teardown (shared by --stop and a clean re-launch) -----------
# Takes an OPTIONAL path so the S167 migration can tear down the legacy in-`.git/`
# location with the same three-step (remove → prune → rm -rf); with no argument it
# behaves exactly as it always has, on $WT. A leaked REGISTRATION is not cosmetic:
# a later `worktree add` at that path trips over it, so the prune is as important
# as the removal.
remove_worktree() { # [path] — defaults to $WT
  local wt="${1:-$WT}"
  [ -n "$wt" ] || return 0
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || true
  "$GIT_BIN" worktree prune >/dev/null 2>&1 || true
  rm -rf "$wt" 2>/dev/null || true
  # Now that deploys live OUTSIDE the repo, leave no empty scaffolding behind in
  # the captain's directory. `rmdir` only succeeds on an EMPTY directory, so a
  # SIBLING mission's live deploy keeps the shared root alive — this can never
  # disturb another deploy. Best-effort; never fails the teardown.
  rmdir "$(dirname "$wt")" 2>/dev/null || true
  rmdir "$(dirname "$(dirname "$wt")")" 2>/dev/null || true
}

# --- S167 migration: clear a PRE-S167 deploy from the old in-`.git/` path --
# A captain mid-round may already have a deploy checked out at
# `.git/lcars/launch/<key>`. Remove + prune it before the new one is cut, so he
# never ends up with TWO checkouts of one mission, and never a stale registration.
# Cooperates with (never duplicates) the existing pid reaping: kill_recorded_launch
# runs FIRST on both the launch and the --stop path and group-kills whatever the
# last launch recorded — so by the time this runs, nothing is serving the old
# directory it tears down. Clean no-op when the old path was never used.
migrate_legacy_worktree() {
  [ -n "${OLD_WT:-}" ] || return 0
  [ "$OLD_WT" != "$WT" ] || return 0
  if [ -e "$OLD_WT" ] \
     || "$GIT_BIN" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $OLD_WT"; then
    remove_worktree "$OLD_WT"
  fi
}

# --- group-kill whatever process a PRIOR launch.json recorded -------------
# Reads pid/pgid from $LAUNCH_JSON and group-kills TERM → grace → KILL, exactly
# as the --stop block always has. Shared by BOTH --stop AND the re-launch guard
# below: re-launching into a (reused) worktree must first reap the process the
# LAST launch left running, or overwriting launch.json's pid orphans it.
# NO-OP SAFE: a fresh launch (no launch.json) or a prior stopped/failed record
# (those writers OMIT pid/pgid) yields empty → kills NOTHING, never errors; an
# already-dead recorded pid → the kills are harmless no-ops. Best-effort
# throughout. Does NOT touch the worktree — --stop prunes separately, and a
# re-launch REUSES it.
kill_recorded_launch() {
  local pid="" pgid=""
  if [ -f "$LAUNCH_JSON" ]; then
    pid="$(json_raw "$LAUNCH_JSON" pid)"
    pgid="$(json_raw "$LAUNCH_JSON" pgid)"
  fi
  case "$pgid" in ''|null) pgid="" ;; esac
  case "$pid"  in ''|null) pid=""  ;; esac
  [ -n "$pgid" ] || [ -n "$pid" ] || return 0

  # Kill the whole GROUP first (negative pgid), so a dev server's children die
  # with it; fall back to the bare pid. Grace, then SIGKILL the group.
  [ -n "$pgid" ] && kill -TERM -"$pgid" 2>/dev/null || true
  [ -n "$pid" ]  && kill -TERM "$pid"  2>/dev/null || true
  nap 0.4
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    [ -n "$pgid" ] && kill -KILL -"$pgid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    nap 0.2
  fi
}

# =====================================================================
# --stop : kill the process group + prune the worktree. Idempotent.
# =====================================================================
if [ "$STOP" -eq 1 ]; then
  kill_recorded_launch          # group-kill the recorded process (TERM→grace→KILL)
  remove_worktree
  # A captain who STOPS (rather than re-launches) right after upgrading past S167
  # must not be left with the legacy in-`.git/` checkout and its registration.
  migrate_legacy_worktree

  # Refresh the record to status=stopped, preserving what we can read.
  if [ -f "$LAUNCH_JSON" ]; then
    st_target="$(json_str "$LAUNCH_JSON" target)"
    st_url="$(json_str "$LAUNCH_JSON" url)"
    st_stop="$(json_str "$LAUNCH_JSON" howToStop)"
    {
      printf '{\n'
      printf '  "status": "stopped",\n'
      printf '  "target": "%s",\n'    "$(json_esc "$st_target")"
      printf '  "url": "%s",\n'       "$(json_esc "$st_url")"
      printf '  "howToStop": "%s",\n' "$(json_esc "$st_stop")"
      printf '  "message": "the app has been stopped."\n'
      printf '}\n'
    } | commit_launch_json
  fi

  if [ "$MAIN" -eq 1 ]; then
    printf 'LCARS — main deploy offline. The %s viewer has been powered down.\n' "${BRANCH:-main}"
  else
    printf 'LCARS — mission app offline. The %s viewer has been powered down.\n' "$MISSION"
  fi
  exit 0
fi

# =====================================================================
# launch : discover → check out → run detached → record → readout
# =====================================================================

# --- re-launch guard: reap the PRIOR launch's process FIRST ---------------
# If an app from a previous launch is still running, its pid/pgid live in the
# CURRENT $LAUNCH_JSON. Group-kill it NOW — this MUST happen before the early
# `launching` write below (commit_launch_json), which OVERWRITES $LAUNCH_JSON and
# destroys that pid/pgid. Skipping this orphans the old process (a later --stop,
# reading only the new pid, could never reap it). $LAUNCH_JSON derives from $MDIR
# — already set by the target-resolution seam — so this is uniform for --main and
# missions. A fresh/stopped/failed record carries no pid/pgid → clean no-op. The
# worktree is left intact: a re-launch REUSES it (idempotent `worktree add`).
kill_recorded_launch

# ...and only THEN clear any pre-S167 deploy still sitting inside `.git/`. Order
# matters: the process that was serving the old checkout is reaped by the call
# above, so this tears down a directory nothing is reading.
migrate_legacy_worktree

# --- resolve the branch tip SHA -------------------------------------------
[ -n "$BRANCH" ] \
  || die "mission \"$MISSION\" has no branch yet — run the mission before launching its app."
SHA="$("$GIT_BIN" rev-parse --verify --quiet "$BRANCH^{commit}" 2>/dev/null)"
[ -n "$SHA" ] \
  || SHA="$("$GIT_BIN" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null)"
if [ -z "$SHA" ]; then
  if [ "$MAIN" -eq 1 ]; then
    die "the \"$BRANCH\" branch doesn't exist here — check mainBranch in .git/lcars/config.json."
  else
    die "the mission's branch \"$BRANCH\" doesn't exist here — run the mission first, or fetch its branch."
  fi
fi
# The main deploy records its human branch name + a short SHA (additive fields on
# the main path ONLY — the per-mission launch.json stays byte-identical to today).
SHA_SHORT=""
if [ "$MAIN" -eq 1 ]; then
  SHA_SHORT="$("$GIT_BIN" rev-parse --short "$SHA" 2>/dev/null)"
  [ -n "$SHA_SHORT" ] || SHA_SHORT="$(printf '%s' "$SHA" | cut -c1-12)"
fi

# --- make sure the out-of-`.git/` deploy area is usable, BEFORE anything is
# --- written --------------------------------------------------------------
# Deploys now live beside the repo, so a repo whose PARENT directory is not
# writable (a read-only mount, a locked-down /Volumes path) cannot host one. Fail
# FAST and legibly HERE — before the first launch.json write below — so a refusal
# leaves no half-made record for the board to render and nothing on disk to clean
# up. Plain English, naming what to try (UX-33), never a raw mkdir error.
if [ ! -d "$LAUNCH_ROOT" ] && ! mkdir -p "$LAUNCH_ROOT" 2>/dev/null; then
  die "couldn't create the deploy area at \"$LAUNCH_ROOT\" — LCARS keeps deploys beside the repo, outside .git/, so the app's file watcher works. Make \"$(dirname "$(dirname "$LAUNCH_ROOT")")\" writable, or point \$LCARS_LAUNCH_ROOT at a directory you can write."
fi
[ -w "$LAUNCH_ROOT" ] \
  || die "the deploy area \"$LAUNCH_ROOT\" isn't writable — LCARS keeps deploys beside the repo, outside .git/, so the app's file watcher works. Fix its permissions, or point \$LCARS_LAUNCH_ROOT at a directory you can write."

# --- persist the `launching` record IMMEDIATELY, before the SLOW pre-flight --
# Write it at the VERY TOP of the launch flow — BEFORE `git worktree add --detach`
# and `provision_worktree` (a pnpm/node_modules provision can take several seconds).
# Those two, plus the later discovery worker + app spawn, together take ~15–60s;
# without this record on disk FIRST, any observer during that window (a Verify card
# reopened right after clicking RUN, SSE, a second browser) reads the STALE
# pre-launch launch.json → wrongly re-renders the ⚡ RUN button, letting the captain
# "outrun" the launch and re-click RUN. Writing `launching` here (milliseconds into
# launch.sh) shrinks that window to nothing. `$MDIR` already exists (the worktree
# does not yet), so writing $MDIR/launch.json now is safe. This single early write
# also ESTABLISHES the known starting state the silent-worker check depends on: a
# worker that writes nothing leaves the status STILL "launching" (see the check
# after the worker spawn) — the semantic equivalent of the old "no launch.json"
# test. The final settle (status=running) or any write_failed OVERWRITES it; using
# `>` here also clears any prior record, so no separate `rm` is needed.
LAUNCH_TARGET="${HINT:-discovering how to run the app…}"
{
  printf '{\n'
  printf '  "status": "launching",\n'
  printf '  "target": "%s",\n' "$(json_esc "$LAUNCH_TARGET")"
  printf '  "message": "the app is starting…"\n'
  printf '}\n'
} | commit_launch_json
# A STALE discovery answer from a prior launch must never satisfy the
# silent-worker check below — the worker's channel starts empty every launch.
rm -f "$LAUNCH_DISCOVERY"

# --- check the SHA into a DETACHED, disposable worktree (idempotent) -------
mkdir -p "$(dirname "$WT")"
already=0
while IFS= read -r line; do
  [ "$line" = "worktree $WT" ] && already=1
done < <("$GIT_BIN" worktree list --porcelain 2>/dev/null)
if [ "$already" -eq 0 ]; then
  # If a stale directory is squatting the path but isn't a registered worktree,
  # clear it so `add` succeeds (e.g. a crashed prior run).
  [ -e "$WT" ] && remove_worktree
  "$GIT_BIN" worktree add --detach "$WT" "$SHA" >/dev/null 2>&1 \
    || die "couldn't check out the mission's code — its branch \"$BRANCH\" may be in a bad state."
fi

# Provision the worktree's dependencies (dep install, etc.) ONCE with the worktree
# as CWD, right after check-out and BEFORE the app is launched. Idempotent, so it is
# safe on both the fresh-add and reuse paths; best-effort — a failure never aborts
# the launch (the app-launch surfaces any real dependency failure itself).
provision_worktree "$WT" || :

# --- resolve the engine + spawn the launch-role discovery worker ----------
WORKER_BIN="${LCARS_WORKER_BIN:-}"
# The main deploy has NO state.json, so only consult it when it exists (reading an
# empty $STATE path with the jq-free sed reader would stall). Fallback chain is
# otherwise unchanged: env → state workerBin → claude.
if [ -z "$WORKER_BIN" ] && [ -n "$STATE" ] && [ -f "$STATE" ]; then
  WORKER_BIN="$(json_str "$STATE" workerBin)"
fi
[ -n "$WORKER_BIN" ] || WORKER_BIN="claude"
CLI="$(basename "$WORKER_BIN")"

mkdir -p "$OUTDIR"
# NB: the `launching` record was already written at the TOP of this flow (before the
# worktree + provision), so there is no rm/rewrite here — that early write both keeps
# every observer on "launching…" through the whole spin-up AND seeds the known
# starting state the silent-worker check below relies on.

# --- derive this mission's touched target(s) → the launch DEFAULT ----------
# The launch should default to the app that exercises THIS mission's change. In a
# multi-target monorepo the worker's only other disambiguation signal is the
# captain's free-text hint; with no hint it can guess the WRONG target. So diff
# the mission branch against its merge-base with the recorded base, reduce the
# changed paths to their top-level target dir(s) (packages/<x>, apps/<x>, or the
# first path segment), and feed those to the discovery worker as the DEFAULT
# target to pin. The captain's hint still WINS over this default. Any failure —
# no base, detached head, git error, or an empty diff — yields NO section, so the
# no-context prompt stays byte-for-byte today's (do not regress that path).
# The main deploy has no base (no state.json), so there is nothing to diff — BASE
# stays empty and the no-context prompt path (today's byte-identical default) is
# taken, exactly as a mission with no recorded base.
BASE=""
[ -n "$STATE" ] && [ -f "$STATE" ] && BASE="$(json_str "$STATE" base)"
TOUCHED_BLOCK=""
if [ -n "$BASE" ]; then
  _mb="$("$GIT_BIN" merge-base "$BASE" "$BRANCH" 2>/dev/null)"
  if [ -n "$_mb" ]; then
    _range="$_mb..$BRANCH"
  else
    _range="$BASE..$BRANCH"   # merge-base failed (base moved/absent) — best effort
  fi
  _diff="$("$GIT_BIN" diff --name-only "$_range" 2>/dev/null)"
  if [ -n "$_diff" ]; then
    # Reduce each changed path to its top-level target dir, dedupe, join ", ".
    _dirs="$(printf '%s\n' "$_diff" | awk '
      $0=="" { next }
      {
        n = split($0, a, "/")
        if ((a[1] == "packages" || a[1] == "apps") && n >= 2) print a[1] "/" a[2]
        else print a[1]
      }' | sort -u | awk 'NR>1{printf ", "} {printf "%s", $0} END{if (NR) printf "\n"}')"
    if [ -n "$_dirs" ]; then
      TOUCHED_BLOCK="
This Mission's changes are in: $_dirs. DEFAULT to launching the app that lets the
captain SEE those changes — the runnable app in / downstream of that package (an
editor/site/game, NOT a pure library). If the captain gave a hint above, the hint
OVERRIDES this default."
    fi
  fi
fi

# Assemble the prompt with `read -d ''` (NOT $(cat <<EOF …)): the prompt text
# contains parentheses, and a heredoc inside a command substitution trips bash
# 3.2's parser on them. `read -d ''` captures the whole heredoc verbatim, with
# variables still expanded (unquoted delimiter), and returns non-zero at EOF.
IFS= read -r -d '' PROMPT <<EOF || true
You are the LCARS launch inspector. A checkout of a Mission's code is at:
  $WT
The captain wants to run: ${HINT:-the app}.
${TOUCHED_BLOCK}
DISCOVER how to start it. Do NOT start it yourself, and do NOT modify any file in
the checkout — inspection only. Read package.json / Makefile / pyproject / README
/ config as needed to find the exact command that starts the app the captain named.

Then write a JSON object to EXACTLY this path (and print nothing):
  $LAUNCH_DISCOVERY
with these fields:
  "target"    a short human name for what runs (e.g. "example-game dev server")
  "command"   the exact shell command that starts it
  "cwd"       the directory to run it in, RELATIVE to the checkout root ("." = root)
  "url"       the expected local URL (e.g. http://localhost:5173), or "" if none
  "howToStop" one short human sentence on how it is normally stopped
  "status"    "ready"

If you CANNOT determine how to run it, instead write "status": "failed" and a
"message" field in plain English naming exactly what is missing (e.g. no dev
script, ambiguous entry point). Never guess a command you are unsure of.

Note the layout can be a trap: a repo root may only launch a different app than
the captain wants — for example a root package.json that starts an Electron editor
while the real game lives in a subdirectory with its OWN dev server unreachable
from the root scripts. Use the captain's hint to select the correct target.
EOF

# Reuse the worker-adapter's spawn (never re-implement spawning). Export the
# engine + the DISCOVERY target so both the adapter and the worker resolve them.
# (The env var keeps its historical name — test stubs write to it — but it now
# points at the worker's PRIVATE discovery file, never the shared launch.json.)
LCARS_LAUNCH_JSON="$LAUNCH_DISCOVERY" LCARS_WORKER_BIN="$WORKER_BIN" \
  bash "$WORKER_ADAPTER" spawn "$CLI" launch "$OUTDIR" "$PROMPT" || true

# --- read the discovery result --------------------------------------------
write_failed() { # message  → persist a status=failed record (no pid)
  local msg="$1"
  {
    printf '{\n'
    printf '  "status": "failed",\n'
    printf '  "target": "%s",\n'    "$(json_esc "${TARGET:-}")"
    printf '  "url": "%s",\n'       "$(json_esc "${URL:-}")"
    printf '  "howToStop": "%s",\n' "$(json_esc "${HOWSTOP:-}")"
    printf '  "message": "%s"\n'    "$(json_esc "$msg")"
    printf '}\n'
  } | commit_launch_json
}

TARGET=""; CMD=""; CWD=""; URL=""; HOWSTOP=""; DSTATUS=""; WMSG=""
# SILENT-WORKER detection — back to the simple original semantic: the worker
# writes its answer to its OWN discovery file (cleared before the spawn), so
# "no file" ⟺ the inspector reported nothing. The shared launch.json still
# says "launching" throughout and is never consulted here.
if [ ! -f "$LAUNCH_DISCOVERY" ]; then
  TARGET=""; URL=""; HOWSTOP=""
  write_failed "couldn't work out how to run this app — the inspector reported nothing back. Try naming the app or its directory as a hint."
  remove_worktree
  die "couldn't work out how to run this app — the inspector reported nothing back. Try naming the app or its directory as a hint."
fi
DSTATUS="$(json_str "$LAUNCH_DISCOVERY" status)"
TARGET="$(json_str "$LAUNCH_DISCOVERY" target)"
CMD="$(json_str "$LAUNCH_DISCOVERY" command)"
CWD="$(json_str "$LAUNCH_DISCOVERY" cwd)"
URL="$(json_str "$LAUNCH_DISCOVERY" url)"
HOWSTOP="$(json_str "$LAUNCH_DISCOVERY" howToStop)"
WMSG="$(json_str "$LAUNCH_DISCOVERY" message)"

if [ "$DSTATUS" = "failed" ] || [ -z "$CMD" ]; then
  # NB: an apostrophe inside a ${VAR:-default} default trips bash 3.2's parser,
  # so pick the default in two steps rather than inline.
  msg="$WMSG"
  [ -n "$msg" ] \
    || msg="could not determine how to start this app — no runnable command was found. Try naming the app or its directory as a hint."
  write_failed "$msg"
  remove_worktree
  die "$msg"
fi

# --- launch the discovered command DETACHED (its own process group) --------
LAUNCH_CWD="$WT"
case "$CWD" in ''|'.'|'./') : ;; *) LAUNCH_CWD="$WT/$CWD" ;; esac
[ -d "$LAUNCH_CWD" ] \
  || { write_failed "the app's directory \"$CWD\" isn't in the checkout — its layout may have changed."; \
       remove_worktree; \
       die "the app's directory \"$CWD\" isn't in the checkout — its layout may have changed."; }

: > "$LOG"
# macOS has no setsid(1): perl POSIX::setsid makes the child its own session &
# process-group leader (PGID == PID), so the whole tree can be group-killed on
# --stop. The perl `exec` preserves the backgrounded pid. Same trick the
# viewscreen daemon + run.sh watchdog use. We wrap in `sh -c` to cd into the app
# directory first; `exec` keeps the pid so PID == PGID == the app.
perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- \
  sh -c "cd '$LAUNCH_CWD' && exec $CMD" >"$LOG" 2>&1 &
PID=$!
PGID="$PID"

# Confirm liveness by POLLING across a window, not one fixed sleep. Real dev
# servers (pnpm/node/electron) spawn through several layers and can take ~1–2s to
# reach their failure (ENOENT / "command not found"), which is AFTER any single
# short settle. So sample `kill -0` repeatedly over the whole $SETTLE window: a
# process that dies ANYWHERE in the window is caught as failed (with the log tail),
# and only one that survives the ENTIRE window is declared running. Fail FAST —
# break the instant `kill -0` fails rather than always waiting the full window.
# Poll interval is min(0.3, window) so even a tiny (test) window polls ≥ once.
INTERVAL="$(awk -v w="$SETTLE" 'BEGIN{i=0.3; if(w+0<i)i=w+0; if(i<=0)i=0.05; print i}')"
ITERS="$(awk -v w="$SETTLE" -v i="$INTERVAL" 'BEGIN{n=(i>0)?int((w+0)/i+0.9999):1; if(n<1)n=1; print n}')"
alive=1
k=0
while [ "$k" -lt "$ITERS" ]; do
  nap "$INTERVAL"
  if ! kill -0 "$PID" 2>/dev/null; then alive=0; break; fi
  k=$((k + 1))
done
if [ "$alive" -eq 0 ]; then
  tail_txt="$(tail -n 5 "$LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
  msg="the app exited immediately — ${tail_txt:-no output was captured}"
  write_failed "$msg"
  remove_worktree
  die "$msg"
fi

# Best-effort URL probe (never gates success): give a served URL a moment.
if [ -n "$URL" ] && command -v curl >/dev/null 2>&1; then
  curl -sf -m 2 "$URL" >/dev/null 2>&1 || true
fi

# --- write the FINAL running record ---------------------------------------
{
  printf '{\n'
  printf '  "status": "running",\n'
  if [ "$MAIN" -eq 1 ]; then
    printf '  "branch": "%s",\n' "$(json_esc "$BRANCH")"
    printf '  "sha": "%s",\n'    "$(json_esc "$SHA_SHORT")"
  fi
  printf '  "target": "%s",\n'    "$(json_esc "$TARGET")"
  printf '  "url": "%s",\n'       "$(json_esc "$URL")"
  printf '  "howToStop": "%s",\n' "$(json_esc "$HOWSTOP")"
  printf '  "command": "%s",\n'   "$(json_esc "$CMD")"
  printf '  "cwd": "%s",\n'       "$(json_esc "$CWD")"
  printf '  "worktree": "%s",\n'  "$(json_esc "$WT")"
  printf '  "log": "%s",\n'       "$(json_esc "$LOG")"
  printf '  "startedAt": "%s",\n' "$NOW"
  printf '  "pid": %s,\n'         "$PID"
  printf '  "pgid": %s,\n'        "$PGID"
  printf '  "message": "the app is running."\n'
  printf '}\n'
} | commit_launch_json

# --- LCARS-voice readout --------------------------------------------------
if [ "$MAIN" -eq 1 ]; then
  printf 'LCARS — main deploy online. The %s is on the viewscreen (%s @ %s).\n' \
    "${TARGET:-app}" "$BRANCH" "${SHA_SHORT:-$SHA}"
else
  printf 'LCARS — mission app online. The %s is on the viewscreen.\n' "${TARGET:-app}"
fi
[ -n "$URL" ] && printf '  On screen:  %s\n' "$URL"
if [ "$MAIN" -eq 1 ]; then
  # NB: keep this default apostrophe-free — an apostrophe in a ${VAR:-default}
  # default trips bash 3.2's parser (see the same guard in write_failed above).
  main_stop="lcars launch --main --stop"
  printf '  To stand down:  %s\n' "${HOWSTOP:-$main_stop}"
else
  printf '  To stand down:  %s\n' "${HOWSTOP:-lcars launch $MISSION --stop}"
fi
printf '  Log:  %s\n' "$LOG"
exit 0
