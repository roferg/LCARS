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
#   LCARS_WORKER_BIN      the cold-worker CLI          (default: state workerBin
#                         → config workerBin → the engine INSTALLED here)
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
# NESTED string at a dotted path (e.g. modelAliases.copilot.opus) — run.sh's
# json_scoped_str, verbatim: each leading segment scopes into that object's
# brace-matched `{ … }` body, then the last segment is read as a string.
json_scoped_str() { # file dotted.path → string value (or empty)
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  local blob; blob="$(tr -d '\n' <"$file")"
  local key="${path##*.}" parents="${path%.*}"
  if [ "$parents" != "$path" ]; then
    local seg
    local IFS='.'
    for seg in $parents; do
      blob="$(_json_scope_into "$blob" "$seg")"
      [ -n "$blob" ] || return 0
    done
  fi
  printf '%s' "$blob" \
    | sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}
_json_scope_into() { # blob key → "{ … }" body of that key's object value
  printf '%s' "$1" | awk -v key="$2" '
    {
      s = $0
      pat = "\"" key "\""
      idx = index(s, pat)
      if (idx == 0) { exit }
      rest = substr(s, idx + length(pat))
      ob = index(rest, "{")
      if (ob == 0) { exit }
      rest = substr(rest, ob)
      depth = 0
      out = ""
      n = length(rest)
      for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        out = out c
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      print out
    }'
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
KEEP_WORKTREE=0
MAIN=0
# S215 — a hint is the captain's PROSE, and prose contains words like
# `--config`. `--` is therefore a REAL end-of-options marker here: after it,
# every remaining word is a positional whatever it starts with. It used to be
# shifted and forgotten, so `lcars launch --main -- "--config vite.config.ts"`
# still died at the `--*` arm below, refusing a sentence as an option.
ENDOPTS=0
# The positional slot rule, in one place so the marker path and the plain path
# can never drift: in --main mode there is no mission slot, so every positional
# is a hint word; otherwise the first one names the mission.
add_positional() {
  if [ "$MAIN" -eq 0 ] && [ -z "$MISSION" ]; then
    MISSION="$1"
  elif [ -z "$HINT" ]; then
    HINT="$1"
  else
    HINT="$HINT $1"
  fi
}
while [ $# -gt 0 ]; do
  if [ "$ENDOPTS" -eq 1 ]; then
    add_positional "$1"; shift; continue
  fi
  case "$1" in
    --main) MAIN=1; shift ;;
    --stop) STOP=1; shift ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --) ENDOPTS=1; shift ;;
    --*) die "unknown option \"$1\" — usage: lcars launch <mission> [hint] [--stop], or lcars launch --main [hint] [--stop]." ;;
    *) add_positional "$1"; shift ;;
  esac
done
[ "$KEEP_WORKTREE" -eq 0 ] || [ "$STOP" -eq 1 ] \
  || die "--keep-worktree requires --stop."

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
PROVISION_LOG="$MDIR/launch-provision.log"  # what dependency provisioning SAID
OUTDIR="$MDIR/.launch-work"              # the worker's answer channel

# Plain-English reason when provisioning looked wrong; EMPTY when it looked fine.
# Set by classify_provisioning(), read by every failure message and the readout.
PROVISION_NOTE=""
# The setup command that actually ran (empty when none was configured). The
# classifier reads it so command-specific advice is only offered when it is TRUE
# of the command in front of the captain.
SETUP_CMD=""

# The command that clears this target's leftovers — quoted in failure messages so
# a left-behind checkout always comes with the way to get rid of it.
if [ "$MAIN" -eq 1 ]; then
  STOP_CMD="lcars launch --main --stop"
else
  STOP_CMD="lcars launch $MISSION --stop"
fi

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
#
# S128 — provisioning is still BEST-EFFORT, but it is no longer SILENT. What it
# says is captured to $PROVISION_LOG (which outlives the launch) and classified
# into $PROVISION_NOTE, so a later failure can name the CAUSE instead of a symptom
# three layers downstream. MEASURED on groutwork 2026-08-06: a mission that added
# a dependency provisioned with `pnpm install --frozen-lockfile`, which printed
# ERR_PNPM_OUTDATED_LOCKFILE, INSTALLED NOTHING, and STILL EXITED 0 — into
# /dev/null — after which the app died with `electron-vite: command not found` and
# the failure path pruned the worktree, deleting the evidence.
provision_worktree() { # worktree-path → 0 (no-op or success), else the command's rc
  local wt="$1" cmd rc=0
  # A provisioning log from a PRIOR launch must never be cited as THIS launch's
  # evidence: fail_msg() points at the log on its mere existence, so a repo with no
  # setup command would send the captain to an unrelated log left behind by an
  # earlier run that used the $LCARS_WORKTREE_SETUP_CMD override. Clear it FIRST,
  # before any early return — exactly as `rm -f $LAUNCH_DISCOVERY` does for the
  # worker's answer channel. Also resets $SETUP_CMD, the string the classifier
  # consults before it offers command-specific advice.
  rm -f "$PROVISION_LOG"
  SETUP_CMD=""
  if [ -n "${LCARS_WORKTREE_SETUP_CMD:-}" ]; then
    cmd="$LCARS_WORKTREE_SETUP_CMD"
  else
    [ -f "$LCARS_CFG" ] || return 0
    cmd="$(json_str "$LCARS_CFG" worktreeSetupCommand)"
  fi
  case "$cmd" in ''|null) return 0 ;; esac
  SETUP_CMD="$cmd"
  # Run ONCE with the worktree as CWD, CAPTURING both streams. Still best-effort:
  # a non-zero exit does NOT abort the launch (deps may already be present in a
  # reused worktree, and refusing there would break a launch that works today) —
  # it is REPORTED, not enforced.
  : > "$PROVISION_LOG"
  ( cd "$wt" && bash -c "$cmd" ) >"$PROVISION_LOG" 2>&1 || rc=$?
  classify_provisioning "$rc"
  return "$rc"
}

# What did provisioning ACTUALLY say? Sets $PROVISION_NOTE to a plain-English
# reason, or leaves it empty when nothing looked wrong.
#
# TWO signals, because the exit code alone is NOT reliable: `pnpm install
# --frozen-lockfile` is documented to print ERR_PNPM_OUTDATED_LOCKFILE and still
# exit 0, so the printed error code is matched in its own right. This is
# deliberately NOT a general "did the install really work" oracle — that is the
# build gate, and it is not this skill's job.
#
# The escape hatch is named on EVERY provisioning failure, because overriding the
# setup command is the fix whatever the reason.
SETUP_HATCH="you can override the setup for one run: LCARS_WORKTREE_SETUP_CMD=\"…\" lcars-launch"
classify_provisioning() { # rc
  local rc="$1"
  local why=""
  local quiet_flag=""
  [ -f "$PROVISION_LOG" ] || return 0
  if pnpm_refused_lockfile; then
    PROVISION_NOTE="dependency setup installed nothing: this branch's lockfile is out of date with its package.json, so the frozen-lockfile install refused (pnpm ERR_PNPM_OUTDATED_LOCKFILE). Fix it by committing an up-to-date lockfile on the branch, or install once without the frozen flag — LCARS_WORKTREE_SETUP_CMD=\"pnpm install --no-frozen-lockfile --prefer-offline\" lcars-launch ${MISSION:---main}"
  elif [ "$rc" -ne 0 ]; then
    why="$(provision_why)"
    PROVISION_NOTE="dependency setup failed (exit $rc)"
    if [ -n "$why" ]; then
      PROVISION_NOTE="$PROVISION_NOTE — it said: $why"
    else
      # MEASURED on groutwork 2026-08-06 (pnpm 9.0.0): the repo's own setup
      # command ends in `--silent`, which swallows pnpm's ERR_PNPM_OUTDATED_LOCKFILE
      # line — the captured log held only a node DeprecationWarning. Say the output
      # explains nothing rather than dress a warning up as the reason.
      PROVISION_NOTE="$PROVISION_NOTE and printed nothing that explains why"
      # …and only blame --silent when the command in front of the captain ACTUALLY
      # carries it. Offered unconditionally (S128 round 0) it sent a captain whose
      # command had no such flag hunting for one — a true-sounding instruction about
      # a thing that is not there. The advice is command-specific, so it is only
      # given when it is true.
      # Name the flag that is ACTUALLY there — never a flag it does not carry.
      case "$SETUP_CMD" in
        *--silent*) quiet_flag="--silent" ;;
        *--quiet*)  quiet_flag="--quiet" ;;
      esac
      [ -n "$quiet_flag" ] \
        && PROVISION_NOTE="$PROVISION_NOTE — the setup command runs with $quiet_flag, which hides it; drop that flag to see the reason"
      # With no such flag there is nothing true to add: fail_msg() already names the
      # captured log, which is the only honest next step.
    fi
    PROVISION_NOTE="$PROVISION_NOTE. Then $SETUP_HATCH ${MISSION:---main}"
  fi
  return 0
}

# Did pnpm ACTUALLY refuse this install over an out-of-date lockfile? Matching the
# bare error code ANYWHERE in the output (S128 round 0) meant a passing MENTION of
# it — in a note, a comment, an echoed reminder — produced a confidently specific,
# entirely invented diagnosis on a launch that WORKED. "Never invent a cause" is
# this code's contract, so recognise pnpm SAYING it, not the string existing.
#
# Deliberately still independent of the exit code: `pnpm install --frozen-lockfile`
# is documented to print this and exit 0 — that was the original defect. What
# distinguishes the real thing is SHAPE: pnpm prints the code as the line's own
# error tag (start of line, optionally behind an `ERROR`/`npm ERR!` prefix), and
# follows it with the refusal itself.
pnpm_refused_lockfile() { # → 0 when the log holds a genuine pnpm refusal
  [ -f "$PROVISION_LOG" ] || return 1
  grep -Eq '^[[:space:]]*((npm )?ERR!?|ERROR:?)?[[:space:]]*ERR_PNPM_OUTDATED_LOCKFILE' \
      "$PROVISION_LOG" 2>/dev/null && return 0
  grep -Eqi 'ERR_PNPM_OUTDATED_LOCKFILE.{0,80}(cannot install|is not up to date|frozen.?lockfile)' \
      "$PROVISION_LOG" 2>/dev/null
}

# The line(s) from the provisioning output that actually EXPLAIN a failure — never
# a warning. A DeprecationWarning that merely contains the word "errors" is not the
# reason a build failed, and quoting it as one just replaces an old lie with a new
# one. Empty when the output holds no such line (see the --silent case above).
#
# TWO passes, because excluding every line containing "warn" (S128 round 0) threw
# away the most common way an install or a build announces failure — `error: 12
# warnings being treated as errors` — and then CLAIMED the output explained
# nothing, which was false. So PROMOTE real error signals rather than blanket-
# exclude a substring: a line that opens with its own error tag (`error:`,
# `fatal:`, `panic:`) or carries an unmistakable error CODE (`ERR_…`, `npm ERR!`)
# is the reason whatever else it mentions. Only when no such line exists does the
# broader, warning-excluding vocabulary run — which is what keeps a bare
# DeprecationWarning from being dressed up as the cause.
provision_why() {
  [ -f "$PROVISION_LOG" ] || return 0
  local strong
  strong="$(grep -Ei '^[[:space:]]*(error|fatal|panic)[[:space:]:!]|(^|[^[:alnum:]_])(ERR_[A-Z0-9_]+|npm ERR!)' \
      "$PROVISION_LOG" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//' | cut -c1-300)"
  if [ -n "${strong// /}" ]; then printf '%s' "$strong"; return 0; fi
  grep -Ev -i 'warn' "$PROVISION_LOG" 2>/dev/null \
    | grep -Ei 'ERR_|error|fail|cannot|could not|unable|not found|no such|missing|refus' \
    | head -3 | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//' | cut -c1-300
}

# Compose the message a PERSON actually reads for a failed launch: the REAL
# reason FIRST (a provisioning failure is the cause; the app dying is only its
# symptom), then where the evidence was left. Plain English throughout (UX-33) —
# never a raw stack trace, never a bare CLI command as the primary line.
fail_msg() { # symptom → the full message
  # NB: two statements, not `local sym="$1" out="$sym"` — bash declares every name
  # in a single `local` BEFORE assigning, so the second would read an unset sym
  # and die under `set -u`.
  # COSMETIC (S128 fix round 1): the four parts used to run together as ONE ~600-
  # character unwrapped terminal line, so the cause was unreadable at a glance. Each
  # part now starts on its own line. The separators are newlines EXACTLY where a
  # space used to be, so write_failed()'s collapse reproduces today's single-line
  # record byte for byte — which matters because json_esc() does not escape
  # newlines, and a raw one inside launch.json's "message" would corrupt the record
  # the board parses.
  local sym="$1"
  local out="$sym"
  local nl='
'
  [ -n "$PROVISION_NOTE" ] && out="$PROVISION_NOTE.${nl}The app then failed: $sym"
  [ -f "$PROVISION_LOG" ] && out="$out${nl}Setup output: $PROVISION_LOG."
  [ -d "$WT" ] && out="$out${nl}The checkout is left in place at $WT so you can look at it — run \`$STOP_CMD\` to clear it (the next launch reuses it)."
  printf '%s' "$out"
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
  [ "$KEEP_WORKTREE" -eq 1 ] || remove_worktree
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
      if [ "$KEEP_WORKTREE" -eq 1 ]; then
        printf '  "worktree": "%s",\n' "$(json_esc "$WT")"
      fi
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
# S274 — WHICH ENGINE IS ACTUALLY ON THIS MACHINE. ONE answer to that question,
# and it is not this file's: `lcars init`, the File console's engine picker,
# `lcars xo`, the board and run.sh's resolver all read the shared detector in
# skills/lcars-init/lcars-common.sh (`lcars_default_engine` / `lcars_engine_bin`),
# and so does this. Read IN A SUBSHELL deliberately — that library is large and
# this script has its own `json_str` / `die`, so sourcing it into this process
# could silently redefine one of them; a subshell makes it a pure question.
_launch_common_lib() {
  printf '%s' "${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
}
launch_installed_engine() { # [config] → engine name (may be EMPTY)
  local lib; lib="$(_launch_common_lib)"
  [ -f "$lib" ] || return 0
  ( . "$lib" >/dev/null 2>&1 || exit 0; lcars_default_engine "${1:-}" )
}
launch_engine_bin() { # engine → the binary that name means (identity fallback)
  local lib; lib="$(_launch_common_lib)"
  [ -f "$lib" ] || { printf '%s' "${1:-}"; return 0; }
  ( . "$lib" >/dev/null 2>&1 || { printf '%s' "${1:-}"; exit 0; }
    lcars_engine_bin "${1:-}" || printf '%s' "${1:-}" )
}

WORKER_BIN="${LCARS_WORKER_BIN:-}"
# The main deploy has NO state.json, so only consult it when it exists (reading an
# empty $STATE path with the jq-free sed reader would stall).
if [ -z "$WORKER_BIN" ] && [ -n "$STATE" ] && [ -f "$STATE" ]; then
  WORKER_BIN="$(json_str "$STATE" workerBin)"
fi
# The repo's AMBIENT default, below the mission's own pin and above detection —
# the same rung run.sh's resolver reads config.json at.
if [ -z "$WORKER_BIN" ] && [ -f "$LCARS_CFG" ]; then
  WORKER_BIN="$(json_str "$LCARS_CFG" workerBin)"
fi
# THE LAST RUNG IS WHAT IS INSTALLED, never the literal `claude`. Until S274 this
# read `[ -n "$WORKER_BIN" ] || WORKER_BIN="claude"`, so `lcars launch --main`
# (which has no state.json to pin anything) spawned a claude that is not there on
# every copilot-only laptop — a repo `lcars init` had already set up on copilot.
if [ -z "$WORKER_BIN" ]; then
  _eng="$(launch_installed_engine "$LCARS_CFG")"
  [ -n "$_eng" ] && WORKER_BIN="$(launch_engine_bin "$_eng")"
fi
# NEITHER CLI IS HERE. One sentence naming BOTH engines, because either one
# cures it (init.sh:72's wording, unchanged since S207) — never an instruction
# to install the one engine this captain may deliberately not have.
if [ -z "$WORKER_BIN" ]; then
  NO_ENGINE_MSG="no worker CLI found — LCARS drives missions with Claude Code (looked for '$(launch_engine_bin claude)') or the GitHub Copilot CLI (looked for '$(launch_engine_bin copilot)'), and neither is on this machine. Install either one and re-run: https://claude.com/claude-code or https://github.com/features/copilot/cli."
  # …AND REVISE THE RECORD BEFORE DYING (S274 fix round 2). This refusal lands
  # ~75 lines AFTER the early `{"status":"launching", …}` write at the top of the
  # flow, and that write is deliberately early (it is what stops an observer
  # outrunning the slow spin-up and re-clicking RUN). So a refusal that only
  # `die`s leaves "launching" on disk FOREVER for a launch that started nothing,
  # and the board's top band faithfully renders a permanent ◐ DEPLOYING… pill —
  # a visible lie, still there minutes later. Commit a `failed` record carrying
  # THIS REFUSAL SENTENCE as the message (the band shows ml.message verbatim),
  # so the captain reads the real reason and gets the ▸ Deploy Main retry back.
  # Written here rather than by resolving the engine earlier, because moving the
  # resolution above the worktree/provision block is a restructure. Inline (not
  # write_failed) only because that helper is defined further down this file;
  # it goes through commit_launch_json, the one sanctioned writer, and collapses
  # newlines exactly as write_failed does — json_esc does not escape them, so a
  # raw newline in "message" would truncate the record for every reader.
  {
    printf '{\n'
    printf '  "status": "failed",\n'
    printf '  "target": "",\n'
    printf '  "message": "%s"\n' \
      "$(json_esc "$(printf '%s' "$NO_ENGINE_MSG" | tr '\n' ' ')")"
    printf '}\n'
  } | commit_launch_json
  die "$NO_ENGINE_MSG"
fi
CLI="${LCARS_WORKER_CLI:-$(basename "$WORKER_BIN")}"

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
#
# S168 — THE INSPECTOR SWAPPED ITS SHELL FOR A PEN. The `launch` role used to
# hold Bash and no Write, so it authored launch-discovery.json through a SHELL
# standing in a checkout of the captain's code, while the prompt above told it
# "do NOT modify any file in the checkout — inspection only". It now holds Write
# and no shell (see adapter_deny in worker-adapter.sh). Two consequences here:
#
#   1. $WT must be GRANTED. The checkout lives outside this process's cwd, and
#      without a shell to reach it a path-sandboxed engine (copilot) could read
#      nothing it is meant to inspect. The grant is the same CLI-agnostic seam
#      the Stages use; claude ignores it.
#   2. the checkout is CHECKED clean after the turn, below — "inspection only"
#      stops being a sentence the worker is trusted to obey.
#
# The clean-checkout BASELINE for (2) is taken HERE, immediately before the turn
# — never assumed to be empty. `provision_worktree` has already run the repo's
# `worktreeSetupCommand` in this tree (it can touch a lockfile), and a re-launch
# REUSES an existing worktree that an earlier app run may have left dirty. The
# audit compares before-vs-after, so it names exactly what THIS turn changed and
# nothing else — which is what keeps it silent on every honest inspection.
LAUNCH_WT_BEFORE=""
[ -d "$WT" ] && LAUNCH_WT_BEFORE="$("$GIT_BIN" -C "$WT" status --porcelain 2>/dev/null)"

# --- the inspector's MODEL (S194 follow-through) ---------------------------
# S168 took the inspector's shell, so on copilot `create` is its ONLY way to
# author launch-discovery.json — and S194 MEASURED that `create` exists only on a
# model that offers it: copilot's DEFAULT model does not. Every run.sh spawn got
# that write floor; this spawn goes through its own path and never did, so every
# copilot launch ran on the default model, was offered view/glob only, and wrote
# nothing (measured live 2026-09-11, copilot 1.0.84, default gpt-5.6-sol: "the
# inspector reported nothing back"). This mirrors resolve_stage_model's
# (a)/(d)/(e) arms in run.sh — that stays the ONE home of the policy:
#   (a) $LCARS_WORKER_MODEL — the env pin, verbatim.
#   (d) config.json workerModel — global, verbatim.
#   (e) the write-capable alias: copilot → modelAliases.copilot.opus, else S78's
#       claude-opus-4.8. claude → EMPTY, so the adapter emits no --model and its
#       argv stays byte-for-byte what it was.
launch_worker_model() { # cli → flag string (stdout; may be empty)
  local cli="$1" m=""
  if [ -n "${LCARS_WORKER_MODEL:-}" ]; then printf '%s' "$LCARS_WORKER_MODEL"; return 0; fi
  [ -f "$LCARS_CFG" ] && m="$(json_str "$LCARS_CFG" workerModel)"
  if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  case "$cli" in
    copilot)
      [ -f "$LCARS_CFG" ] && m="$(json_scoped_str "$LCARS_CFG" modelAliases.copilot.opus)"
      printf '%s' "${m:-claude-opus-4.8}" ;;
  esac
}
WORKER_MODEL="$(launch_worker_model "$CLI")"

LCARS_WORKER_INPUT_DIRS="$WT" LCARS_WORKER_MODEL="$WORKER_MODEL" \
LCARS_LAUNCH_JSON="$LAUNCH_DISCOVERY" LCARS_WORKER_BIN="$WORKER_BIN" \
  bash "$WORKER_ADAPTER" spawn "$CLI" launch "$OUTDIR" "$PROMPT" || true

# --- read the discovery result --------------------------------------------
write_failed() { # message  → persist a status=failed record (no pid)
  local msg="$1"
  # The message a PERSON reads is wrapped onto several lines (fail_msg); the record
  # a MACHINE reads must stay one. json_esc() escapes quotes and backslashes but not
  # newlines, so a raw newline here would emit invalid JSON and truncate the message
  # for every reader (the board, json_str, `lcars status`). fail_msg breaks exactly
  # where a space used to be, so collapsing restores today's record byte for byte.
  msg="$(printf '%s' "$msg" | tr '\n' ' ')"
  {
    printf '{\n'
    printf '  "status": "failed",\n'
    printf '  "target": "%s",\n'    "$(json_esc "${TARGET:-}")"
    printf '  "url": "%s",\n'       "$(json_esc "${URL:-}")"
    printf '  "howToStop": "%s",\n' "$(json_esc "${HOWSTOP:-}")"
    # Only present when provisioning actually complained — an ordinary launch
    # record is byte-identical to today's.
    [ -n "$PROVISION_NOTE" ] \
      && printf '  "provisioning": "%s",\n' "$(json_esc "$PROVISION_NOTE")"
    printf '  "message": "%s"\n'    "$(json_esc "$msg")"
    printf '}\n'
  } | commit_launch_json
}

# --- the launch fence audit (S168) -----------------------------------------
# The inspector was told the checkout is read-only. Verify it. A dirty tree is a
# BREACH, not something to tidy: the discovery answer came from a worker that
# edited the code it was reasoning about, so it is not trustworthy and the
# launch stops LOUDLY with the files named. Nothing is reverted or repaired.
# It is a DIFF against the baseline taken just before the spawn, not an
# is-it-empty check, so provisioning's own footprint and a reused worktree's
# leftovers can never be blamed on the inspector — and an honest turn changes
# nothing, so this is silent (the worker's answer file lives outside the tree).
if [ -d "$WT" ]; then
  LAUNCH_WT_AFTER="$("$GIT_BIN" -C "$WT" status --porcelain 2>/dev/null)"
  LAUNCH_DIRT="$(printf '%s\n' "$LAUNCH_WT_AFTER" | grep -vxF -f <(printf '%s\n' "$LAUNCH_WT_BEFORE") 2>/dev/null | grep -v '^$')"
  if [ -n "$LAUNCH_DIRT" ]; then
    LAUNCH_DIRT_FILES="$(printf '%s\n' "$LAUNCH_DIRT" | awk '{$1=$1; print}' | cut -d' ' -f2- | tr '\n' ' ')"
    write_failed "the launch inspector MODIFIED the checkout it was told to only inspect ($LAUNCH_DIRT_FILES) — refusing to run an app discovered by a worker that edited the code it was reading. Nothing has been reverted; inspect $WT."
    die "launch fence breach — the inspector wrote into $WT: $LAUNCH_DIRT_FILES"
  fi
fi

TARGET=""; CMD=""; CWD=""; URL=""; HOWSTOP=""; DSTATUS=""; WMSG=""
# SILENT-WORKER detection — back to the simple original semantic: the worker
# writes its answer to its OWN discovery file (cleared before the spawn), so
# "no file" ⟺ the inspector reported nothing. The shared launch.json still
# says "launching" throughout and is never consulted here.
if [ ! -f "$LAUNCH_DISCOVERY" ]; then
  TARGET=""; URL=""; HOWSTOP=""
  # S128: the checkout is NOT pruned here (nor on any other failure path below).
  # Pruning deleted the only evidence of WHY a launch failed — a half-provisioned
  # node_modules, a missing binary — before anyone could read it. It cannot
  # accumulate: the path is keyed by mission, so a re-launch reuses this same one
  # and `--stop` clears it. fail_msg() says both, in the message.
  msg="$(fail_msg "couldn't work out how to run this app — the inspector reported nothing back. Try naming the app or its directory as a hint.")"
  write_failed "$msg"
  die "$msg"
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
  msg="$(fail_msg "$msg")"
  write_failed "$msg"
  die "$msg"
fi

# --- launch the discovered command DETACHED (its own process group) --------
LAUNCH_CWD="$WT"
case "$CWD" in ''|'.'|'./') : ;; *) LAUNCH_CWD="$WT/$CWD" ;; esac
if [ ! -d "$LAUNCH_CWD" ]; then
  msg="$(fail_msg "the app's directory \"$CWD\" isn't in the checkout — its layout may have changed.")"
  write_failed "$msg"
  die "$msg"
fi

# --- S187: WHERE IS THE APP ACTUALLY LISTENING? ----------------------------
# $URL above is a PREDICTION — the discovery worker read the repo's config and
# guessed. It used to be written into the running record untouched and never
# checked against reality. That is wrong often enough to matter: a dev server
# whose configured port is already taken silently bumps to the next one, and the
# record then points at whatever OTHER app holds the predicted port (measured
# 2026-09-04: one repo's board handed the captain a different repo's app, because
# the best-effort probe below "confirmed" the neighbour's server). So we OBSERVE
# the truth rather than trust the guess: enumerate the launched process GROUP and
# read its listening sockets.
#
# This adds OBSERVATION ONLY. The detached setsid spawn, PID == PGID, the group
# kill on --stop, the liveness contract and idempotent re-launch are untouched.
#
# Darwin BSD userland, bash 3.2: `pgrep -g <pgid>` lists the group's pids and
# `lsof -a -p <pids> -iTCP -sTCP:LISTEN -P -n` lists their LISTEN sockets. -P/-n
# keep lsof's NAME column numeric (`127.0.0.1:5173`, `*:5173`, `[::1]:5173`), so
# the port is simply the text after the last colon. Both tools are asserted by
# the suite; if either is somehow missing we degrade to today's behaviour (the
# prediction stands unverified) rather than refuse a launch that is fine.
LSOF_BIN="$(command -v lsof 2>/dev/null || true)"
[ -n "$LSOF_BIN" ] || { [ -x /usr/sbin/lsof ] && LSOF_BIN=/usr/sbin/lsof; }

listen_ports_of_group() { # pgid -> ascending unique ports, one per line (may be empty)
  local pgid="$1" pids
  [ -n "$LSOF_BIN" ] || return 0
  command -v pgrep >/dev/null 2>&1 || return 0
  pids="$(pgrep -g "$pgid" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  [ -n "$pids" ] || return 0
  "$LSOF_BIN" -a -p "$pids" -iTCP -sTCP:LISTEN -P -n 2>/dev/null \
    | awk 'NR > 1 { n = split($9, a, ":"); p = a[n]; if (p ~ /^[0-9]+$/) print p }' \
    | sort -n -u
}

url_port() { # url -> its explicit port, or empty
  local rest="$1" hostport port
  case "$rest" in *://*) rest="${rest#*://}" ;; esac
  # A QUERY OR FRAGMENT IS NOT PART OF THE HOST (S257 fault 3). On a url with no
  # path (`http://h:5173?a=b`) the whole remainder used to be read as the
  # hostport, so the port came back EMPTY and a port swap discarded the query.
  rest="${rest%%#*}"
  rest="${rest%%\?*}"
  hostport="${rest%%/*}"
  case "$hostport" in
    \[*\]:*) port="${hostport##*]:}" ;;   # [::1]:5173
    \[*\])   port="" ;;                   # [::1]
    *:*)     port="${hostport##*:}" ;;
    *)       port="" ;;
  esac
  case "$port" in ''|*[!0-9]*) port="" ;; esac
  printf '%s\n' "$port"
}

url_with_port() { # url port -> the same url with that port (scheme/host/path/query kept)
  local u="$1" p="$2" scheme rest hostport path host tail=""
  case "$u" in
    *://*) scheme="${u%%://*}"; rest="${u#*://}" ;;
    *)     scheme="http";       rest="$u" ;;
  esac
  # THE QUERY AND FRAGMENT BELONG TO THE PATH SIDE, NOT THE HOST SIDE (S257).
  # `http://h:5173?a=b` has no path, so the `*)` arm took `h:5173?a=b` as the
  # hostport and `?a=b` was discarded — which is one of the two places a look's
  # own seed went missing between rounds. Fragment first, then query, so they
  # are put back in url order.
  case "$rest" in
    *\#*) tail="#${rest#*\#}"; rest="${rest%%\#*}" ;;
  esac
  case "$rest" in
    *\?*) tail="?${rest#*\?}$tail"; rest="${rest%%\?*}" ;;
  esac
  case "$rest" in
    */*) hostport="${rest%%/*}"; path="/${rest#*/}" ;;
    *)   hostport="$rest";       path="" ;;
  esac
  case "$hostport" in
    \[*\]*) host="${hostport%%]*}]" ;;    # keep an IPv6 literal intact
    *)      host="${hostport%%:*}" ;;
  esac
  [ -n "$host" ] || host="localhost"
  printf '%s://%s:%s%s%s\n' "$scheme" "$host" "$p" "$path" "$tail"
}

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
# S187: the socket is looked for on EVERY tick of this same window, not sampled
# once after the spawn — a real dev server reaches listen() a second or two in,
# long after the first sample, and one sample would call every one of them
# "nothing listening". FIRST bind wins: once the group is listening we stop
# looking, but we NEVER shorten the liveness poll (only a process that survives
# the WHOLE window is declared running — that contract is unchanged).
LISTEN_PORTS=""
while [ "$k" -lt "$ITERS" ]; do
  nap "$INTERVAL"
  if ! kill -0 "$PID" 2>/dev/null; then alive=0; break; fi
  [ -n "$LISTEN_PORTS" ] || LISTEN_PORTS="$(listen_ports_of_group "$PGID")"
  k=$((k + 1))
done
if [ "$alive" -eq 0 ]; then
  tail_txt="$(tail -n 5 "$LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//')"
  msg="the app exited immediately — ${tail_txt:-no output was captured}"
  msg="$(fail_msg "$msg")"
  write_failed "$msg"
  die "$msg"
fi

# --- S187: reconcile the PREDICTION against the socket we observed ----------
# The prediction is never thrown away — it is demoted to `predictedUrl` so the
# record is honest about both what was guessed and what is true.
PREDICTED_URL="$URL"
URL_NOTE=""
if [ -n "$LISTEN_PORTS" ]; then
  # WHICH port, when one group listens on several (an HMR socket, a debugger, an
  # API sidecar beside the server)? Deterministic rule, in this order:
  #   1. the PREDICTED port, if the group really is listening on it — that means
  #      the guess was RIGHT, and the guess is the one thing here that knows
  #      which of several sockets a human is meant to open;
  #   2. otherwise the LOWEST port in the group — stable run to run (the list is
  #      sorted numerically), and in practice the primary server, since sidecars
  #      and debuggers bind higher.
  # Many ports never crash it: the list is just longer.
  PRED_PORT="$(url_port "$URL")"
  if [ -n "$PRED_PORT" ] && printf '%s\n' "$LISTEN_PORTS" | grep -qx "$PRED_PORT"; then
    ACTUAL_PORT="$PRED_PORT"
  else
    ACTUAL_PORT="$(printf '%s\n' "$LISTEN_PORTS" | head -1)"
  fi
  if [ -n "$URL" ]; then
    URL="$(url_with_port "$URL" "$ACTUAL_PORT")"
  else
    # Nothing was predicted, but the app IS serving — say where, rather than
    # leave the captain with a running app and no address.
    URL="http://localhost:$ACTUAL_PORT"
  fi
  if [ -n "$PREDICTED_URL" ] && [ "$URL" != "$PREDICTED_URL" ]; then
    # NOT a failure: the app is fine, the guess was wrong. Status stays running.
    URL_NOTE="the launch inspector predicted $PREDICTED_URL, but the app is actually listening on $URL"
  fi
elif [ -n "$PREDICTED_URL" ]; then
  # The process group is alive but holds no listening socket. Publishing the
  # guess anyway is exactly how a board ends up linking someone else's app, so
  # the url is emptied and the record says why in plain English.
  URL=""
  URL_NOTE="app is running but nothing in its process group is listening — predicted $PREDICTED_URL not verified"
fi

# Best-effort URL probe (never gates success): give a served URL a moment.
# S187: this now probes the VERIFIED url. It used to probe the PREDICTION, which
# is what made a colliding launch look "confirmed" — the 200 came from the other
# repo's app. Still best-effort; it has never gated and still does not.
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
  # S187: what the inspector GUESSED, kept beside what was VERIFIED. Additive —
  # the board's launch payload names the fields it renders, so this is ignored
  # there; it exists so the record can never quietly lose the prediction.
  printf '  "predictedUrl": "%s",\n' "$(json_esc "$PREDICTED_URL")"
  # Present ONLY when the observation disagreed with the guess (same shape as
  # the "provisioning" note below), so an ordinary verified launch records
  # nothing new to explain.
  [ -n "$URL_NOTE" ] \
    && printf '  "urlNote": "%s",\n' "$(json_esc "$URL_NOTE")"
  printf '  "howToStop": "%s",\n' "$(json_esc "$HOWSTOP")"
  printf '  "command": "%s",\n'   "$(json_esc "$CMD")"
  printf '  "cwd": "%s",\n'       "$(json_esc "$CWD")"
  printf '  "worktree": "%s",\n'  "$(json_esc "$WT")"
  printf '  "log": "%s",\n'       "$(json_esc "$LOG")"
  # The app came up DESPITE provisioning complaining (deps may already have been
  # in a reused worktree). Say so rather than let a half-provisioned app pass as
  # clean — but never refuse it: best-effort is the contract.
  [ -n "$PROVISION_NOTE" ] \
    && printf '  "provisioning": "%s",\n' "$(json_esc "$PROVISION_NOTE")"
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
# S187: the captain hears about a wrong guess (or an app that serves nothing) the
# moment it happens, instead of discovering it by opening the wrong app.
[ -n "$URL_NOTE" ] && printf '  ⚠ Heads up — %s.\n' "$URL_NOTE"
if [ "$MAIN" -eq 1 ]; then
  # NB: keep this default apostrophe-free — an apostrophe in a ${VAR:-default}
  # default trips bash 3.2's parser (see the same guard in write_failed above).
  main_stop="lcars launch --main --stop"
  printf '  To stand down:  %s\n' "${HOWSTOP:-$main_stop}"
else
  printf '  To stand down:  %s\n' "${HOWSTOP:-lcars launch $MISSION --stop}"
fi
printf '  Log:  %s\n' "$LOG"
# The app is up, but provisioning said something was wrong on the way — surface it
# here rather than leave the captain to discover a half-installed app himself.
if [ -n "$PROVISION_NOTE" ]; then
  printf '  ⚠ Heads up — %s.\n' "$PROVISION_NOTE"
  printf '     Setup output:  %s\n' "$PROVISION_LOG"
fi
exit 0
