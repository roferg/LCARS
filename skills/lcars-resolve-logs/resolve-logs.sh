#!/usr/bin/env bash
#
# lcars resolve-logs — drive every logged bug of a parent Mission to its Verify
# gate, then raise ONE consolidated re-verify ask on the parent.
#
# This is an ORCHESTRATION verb. It adds NO new stage logic: it reuses the
# linkage written by `lcars log` (state.json parentMission + type:bug), the
# existing `lcars run` driver, the existing awaiting-human gate, and the
# existing $LCARS_NOTIFY hook. Given a parent Mission that has N linked bug
# Missions, it:
#
#   GATHER  resolve <parent> against the active Mission table (id / #issue /
#           title, same UX as `lcars log`); collect every linked bug Mission
#           (parentMission == parent, type bug, stage != done, not yet at
#           verify) into a work set. None → clean no-op (no gate, no notify).
#   ORDER   ask the worker ($LCARS_WORKER_BIN) for a sensible resolution order
#           (root-cause / dependencies first); record the order + a one-line
#           rationale per bug. The shell consumes the ordered id list; absent a
#           worker choice it falls back to filed order.
#   DRIVE   for each bug in order, delegate to `lcars run drive` ($LCARS_RUN_SCRIPT)
#           up to its Verify gate (never approve, never open a PR). If a bug
#           escalates to awaiting-human, PAUSE the batch at that bug, leave its
#           question in the answer inbox, do not roll back earlier bugs, and
#           do NOT raise the consolidated gate. A later `lcars resolve-logs`
#           resumes with the remaining bugs once the human has answered.
#
# Once every bug in the set has reached Verify, raise EXACTLY ONE consolidated
# re-verify human gate on the PARENT (awaitingHuman + pending.json +
# lcars:awaiting-human) and fire EXACTLY ONE $LCARS_NOTIFY — not N.
#
# Dependencies are env-injected so tests can stub them:
#   LCARS_WORKER_BIN  the ordering worker          (default: none → filed order)
#   LCARS_GH_BIN      the gh binary                (default: gh)
#   LCARS_GIT_BIN     the git binary               (default: git)
#   LCARS_NOTIFY      the notify hook              (default: ../lcars-run/notify.sh)
#   LCARS_RUN_SCRIPT  the `lcars run` driver       (default: ../lcars-run/run.sh)
#   LCARS_HOST_ADAPTER the forge adapter           (default: ../lcars-run/host-adapter.sh)
#
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
WORKER_BIN="${LCARS_WORKER_BIN:-}"
NOTIFY_BIN="${LCARS_NOTIFY:-$SKILL_DIR/../lcars-run/notify.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# The host-integration adapter — the ONE place that speaks to a forge. It lives in
# the sibling lcars-run skill dir; $LCARS_HOST_ADAPTER overrides that path so
# tests and drives can stub the forge at the seam LCARS already owns. Same shape
# as approve.sh / log.sh / feedback.sh.
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SKILL_DIR/../lcars-run/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

die() { printf 'lcars resolve-logs: %s\n' "$1" >&2; exit 1; }

# --- version check (S129) — WARN mode ONLY ---------------------------------
# resolve-logs is a headless, walk-away orchestration verb (it drives bugs to
# their Verify gate). It must never prompt or block on the update ask, so it uses
# `warn` mode: at most one throttled line, no stdin. Guarded + kill-switch aware.
VERSION_CHECK="${LCARS_VERSION_CHECK_BIN:-$SKILL_DIR/../lcars-version/check.sh}"
[ -f "$VERSION_CHECK" ] && bash "$VERSION_CHECK" warn </dev/null || true

# --- tiny JSON readers (no jq; same decoding as log.sh / run.sh) -----------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }
# JSON-string-safe escape (no surrounding quotes): backslash/quote via bash,
# then awk escapes every control char (newline/tab/CR → \n \t \r, rest \u00XX)
# so any multi-line value yields VALID JSON. jq-free. Order: backslash first.
json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# --- state mutators (jq-free; same shape as run.sh) ------------------------
state_del() { # file key
  local tmp; tmp="$(mktemp)"
  grep -v "\"$2\"[[:space:]]*:" "$1" >"$tmp" && mv "$tmp" "$1"
}
state_set_str() { # file key value
  state_del "$1" "$2"
  local esc tmp; esc="$(json_escape "$3")"; tmp="$(mktemp)"
  K="$2" V="$esc" awk 'NR==1{print; printf "  \"%s\": \"%s\",\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$1" >"$tmp" && mv "$tmp" "$1"
}
state_set_raw() { # file key token
  state_del "$1" "$2"
  local tmp; tmp="$(mktemp)"
  K="$2" V="$3" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$1" >"$tmp" && mv "$tmp" "$1"
}

# --- args ------------------------------------------------------------------
# Default verb (no subcommand) is the GATHER → ORDER → DRIVE → consolidated-gate
# flow. The `complete` subcommand (BUG-E) folds the parent's already-verified
# child bug Missions to Done — it is invoked when the consolidated re-verify gate
# on the parent is ACCEPTED (respond.sh calls it after clearing the gate).
SUBCOMMAND=""
case "${1:-}" in
  complete) SUBCOMMAND="complete"; shift ;;
esac

PARENT_SEL=""
BUG_SEL=""   # single-bug mode (BUG-032): complete ONLY this one child bug.
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)   PARENT_SEL="${2:-}"; shift 2 ;;
    --parent=*) PARENT_SEL="${1#--parent=}"; shift ;;
    --bug)      BUG_SEL="${2:-}"; shift 2 ;;
    --bug=*)    BUG_SEL="${1#--bug=}"; shift ;;
    -*)         die "unknown argument: $1" ;;
    *)          [ -z "$PARENT_SEL" ] && PARENT_SEL="$1"; shift ;;
  esac
done

# --- locate the repo + state dir -------------------------------------------
GITDIR="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
case "$GITDIR" in /*) : ;; *) GITDIR="$PWD/$GITDIR" ;; esac
LCARS_DIR="$GITDIR/lcars"
MISSIONS_DIR="$LCARS_DIR/missions"
CONFIG="$LCARS_DIR/config.json"
[ -d "$MISSIONS_DIR" ] || die "no missions yet — run \`lcars init\` and file a parent Mission first."

# --- the active Mission table (id, title, stage, issue) --------------------
active_table() { # -> id<TAB>title<TAB>stage<TAB>issue
  local s id title stage issue
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    stage="$(json_str "$s" stage)"
    [ "$stage" = "done" ] && continue
    id="$(json_str "$s" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
    title="$(json_str "$s" title)"
    issue="$(json_raw "$s" githubIssue)"
    printf '%s\t%s\t%s\t%s\n' "$id" "$title" "$stage" "$issue"
  done
  shopt -u nullglob
}

list_active() { # human-readable, for the no/ambiguous-parent error
  local id title stage issue line
  echo "  Active missions you can resolve logs for:" >&2
  while IFS=$'\t' read -r id title stage issue; do
    [ -n "$id" ] || continue
    case "$issue" in ''|null) line="(local)" ;; *) line="#$issue" ;; esac
    printf '    %s  %s  %s  %s\n' "$id" "$line" "$stage" "$title" >&2
  done < <(active_table)
}

# --- resolve the parent Mission (same UX as log.sh) ------------------------
if [ -z "$PARENT_SEL" ]; then
  echo "lcars resolve-logs: no parent Mission named — say which active Mission's logs to resolve." >&2
  list_active
  exit 1
fi

SEL="${PARENT_SEL#\#}"
lsel="$(printf '%s' "$SEL" | tr '[:upper:]' '[:lower:]')"
PARENT_ID=""; PARENT_TITLE=""; PARENT_ISSUE=""
matches=0
while IFS=$'\t' read -r id title stage issue; do
  [ -n "$id" ] || continue
  hid="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  hti="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  hit=0
  [ "$hid" = "$lsel" ] && hit=1
  [ "$issue" = "$SEL" ] && hit=1
  case "$hid" in *"$lsel"*) hit=1 ;; esac
  case "$hti" in *"$lsel"*) hit=1 ;; esac
  if [ "$hit" -eq 1 ]; then
    PARENT_ID="$id"; PARENT_TITLE="$title"; PARENT_ISSUE="$issue"
    matches=$((matches + 1))
  fi
done < <(active_table)

if [ "$matches" -eq 0 ]; then
  echo "lcars resolve-logs: no active Mission matches \"$PARENT_SEL\"." >&2
  list_active
  exit 1
fi
if [ "$matches" -gt 1 ]; then
  echo "lcars resolve-logs: \"$PARENT_SEL\" matches more than one active Mission — be specific." >&2
  list_active
  exit 1
fi

PARENT_DIR="$MISSIONS_DIR/$PARENT_ID"
PARENT_STATE="$PARENT_DIR/state.json"

# --- S189/S196: solo ownership, the light lock -----------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars resolve-logs` DRIVES a parent's logged bugs to their
# Verify gate, folds them onto the parent's branch and raises a gate on the
# parent's issue, so it consults the lock; the READ verbs (status, buddy, the
# viewscreen's reads) never do. The remedy is deliberately a HUMAN act on
# GitHub — the solo protocol's premise is that the captain moves ownership
# where both laptops can see it, and LCARS never takes a mission off anyone.
#
# ON THE PARENT, and as soon as the parent resolves — before a child is
# gathered, ordered, driven or folded, and before the `complete` path touches a
# single state.json. A logged bug rides its parent's branch and nests under its
# parent's issue, so resolving one against a mission somebody else holds is a
# write to their work (the same reasoning `lcars log` records at its own call).
#
# The library lives in the sibling lcars-run skill dir (the same reach this
# script already makes for the host adapter). A MISSING library leaves the verb
# unenforced — exactly pre-S189 behaviour — rather than refusing blindly, and
# LCARS_OWNER_ENFORCE=0 bypasses the lock for harness debugging.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SKILL_DIR/../lcars-run/ownership.sh}"
[ -f "$OWNERSHIP_LIB" ] && . "$OWNERSHIP_LIB"

# owner_lock_or_die <issue> — refuse with ONE plain line, or return.
# lcars_owner_lock_reason returns 0 (and echoes the line) ONLY when someone else
# demonstrably holds the mission: unassigned, an unreachable forge and an
# unresolvable identity all fall through to "proceed", because a lock that fires
# on uncertainty locks the captain out of his own work.
owner_lock_or_die() { # <issue>
  local r
  command -v lcars_owner_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_owner_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

# xo_lock_or_die <mission-dir> — refuse with ONE plain line, or return (S201).
# THE SECOND REASON ON THE SAME SEAM. Number One acts on the captain's behalf
# THROUGH these very verbs, so while it holds a mission a second hand on that
# mission is a race with his own first officer. `lcars_xo_lock_reason` returns 0
# (and echoes the line) ONLY when the mission's RECORDED state says
# numberOne.status is `engaged`; no state, no key, stood-down and finished all
# fall through to "proceed", exactly like the owner lock's posture, and
# LCARS_XO_ENFORCE=0 bypasses it. The remedy is `lcars xo off <id>`.
xo_lock_or_die() { # <mission-dir>
  local r
  command -v lcars_xo_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_xo_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

owner_lock_or_die "$PARENT_ISSUE"
xo_lock_or_die "$PARENT_DIR"

# --- the PARENT's engine (BUG-D) -------------------------------------------
# A logged bug folds into the parent and must RUN on the SAME engine the parent
# ran on — a copilot parent's fixes must not silently host-detect claude. The
# child `lcars run drive` is fed this as $LCARS_WORKER_BIN below. We resolve it
# from the PARENT mission's state.json `workerBin` (written by `lcars log` /
# `lcars file`). This is deliberately SEPARATE from $WORKER_BIN above, which is
# the ORDERING worker the resolver consults — they are different concerns.
# Empty ⇒ no engine pinned, the child host-detects exactly as before.
PARENT_ENGINE="$(json_str "$PARENT_STATE" workerBin)"

# --- the linked child bug Missions, by current stage -----------------------
# Reused by both the default drive flow (GATHER, below) and `complete`. Echoes
# one "<bug-id>\t<stage>" line per linked, non-done child (type bug, parentMission
# == PARENT_ID), in id order.
linked_children() { # -> id<TAB>stage
  local s bid type parent stage
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    bid="$(json_str "$s" id)"; [ -n "$bid" ] || bid="$(basename "$(dirname "$s")")"
    type="$(json_str "$s" type)"
    parent="$(json_str "$s" parentMission)"
    stage="$(json_str "$s" stage)"
    [ "$type" = "bug" ] || continue
    [ "$parent" = "$PARENT_ID" ] || continue
    [ "$stage" = "done" ] && continue
    printf '%s\t%s\n' "$bid" "$stage"
  done < <(ls -1 "$MISSIONS_DIR"/*/state.json 2>/dev/null | sort)
}

# === S73: dependency-aware PARALLEL wave scheduling ========================
#
# SPIKE DECISION (recorded here so the rule lives next to the code):
#
#   INDEPENDENCE SIGNAL — CONSERVATIVE. Two sibling bug Missions are treated as
#   INDEPENDENT (eligible to share a wave) ONLY when BOTH:
#     (a) their plan.json target FILE PATHS are CLEARLY DISJOINT, and
#     (b) they do NOT share a working branch (state.json.branch).
#   Anything else SERIALISES. A bug with NO plan.json yet, or a plan from which
#   no path token can be extracted, is treated as touching-everything → it is
#   never independent of anything → it serialises. Paths are read from each
#   child's plan.json (the same artifact the per-Mission Schedule reads), pulling
#   path-shaped tokens out of every ticket's description + acceptanceCriteria
#   (plan tickets carry no dedicated files field — this is the available signal).
#
#   PARALLEL-SAFETY — the hard part. BUG-E folds a pre-merge child's commits onto
#   the PARENT's branch, in the SINGLE shared working tree. Two children that
#   share a branch therefore CANNOT commit concurrently (Implement checks out and
#   commits on that branch). So:
#     • Same-wave children with DISTINCT branches + disjoint paths drive
#       CONCURRENTLY (bounded by $LCARS_RESOLVE_CONCURRENCY) — the per-Mission
#       driver lock already isolates distinct Missions, and distinct branches mean
#       no same-branch / same-working-tree collision for these.
#     • Children that share a branch (the common pre-merge fold case) are pushed
#       into SEPARATE waves so they run ONE AT A TIME — we never ship unsafe
#       same-branch concurrent commits (option (c) for that case).
#   This ships REAL concurrency for the distinct-branch case and a correct
#   schedule for every case; same-branch folds stay safely serial.

# Extract path-shaped tokens from a child's plan.json. Echoes one path per line.
# A "path token" looks like a file path: contains a "/" or ends in a dotted
# extension (e.g. src/foo.py, board.js, web/x). Pulled from the ticket
# description + acceptanceCriteria text (parse_plan_table-style, jq-free).
child_paths() { # child-id
  local plan="$MISSIONS_DIR/$1/plan.json"
  [ -f "$plan" ] || return 0
  # Strip JSON structure to words, keep path-looking tokens, dedupe.
  tr -c 'A-Za-z0-9_./-' ' ' <"$plan" \
    | tr ' ' '\n' \
    | grep -E '(/[A-Za-z0-9_.-]+)|(^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$)' \
    | grep -vE '^(plan\.json|state\.json)$' \
    | sort -u
}

child_branch() { json_str "$MISSIONS_DIR/$1/state.json" branch; }

# Are two children INDEPENDENT (safe to co-schedule / run concurrently)?
# Returns 0 = independent, 1 = dependent (must serialise). Conservative: empty
# path set on either side ⇒ NOT independent; shared branch ⇒ NOT independent.
bugs_independent() { # idA idB
  local a="$1" b="$2" pa pb ba bb
  ba="$(child_branch "$a")"; bb="$(child_branch "$b")"
  [ -n "$ba" ] && [ "$ba" = "$bb" ] && return 1   # shared branch → serialise
  pa="$(child_paths "$a")"; pb="$(child_paths "$b")"
  [ -n "$pa" ] || return 1                         # no signal → serialise
  [ -n "$pb" ] || return 1
  # Disjoint? Any common path → dependent.
  if printf '%s\n' "$pa" | grep -qxF -f <(printf '%s\n' "$pb"); then
    return 1
  fi
  return 0
}

# Group the ordered work list into waves. A bug joins the FIRST existing wave in
# which it is independent of EVERY member already placed there; otherwise it
# opens a new wave. Same-wave members are eligible to drive concurrently.
# Echoes "<wave-number> <id>" lines, in wave then placement order.
compute_bug_waves() { # ids... (passed as args, in resolution order)
  local ids=("$@") nwaves=0
  local -a wave_members   # wave_members[w] = space-joined ids in wave w
  local id w placed m indep
  for id in "${ids[@]}"; do
    placed=0
    for ((w=1; w<=nwaves; w++)); do
      indep=1
      for m in ${wave_members[w]:-}; do
        if ! bugs_independent "$id" "$m"; then indep=0; break; fi
      done
      if [ "$indep" -eq 1 ]; then
        wave_members[w]="${wave_members[w]} $id"
        placed=1; break
      fi
    done
    if [ "$placed" -eq 0 ]; then
      nwaves=$((nwaves + 1))
      wave_members[nwaves]="$id"
    fi
  done
  for ((w=1; w<=nwaves; w++)); do
    for m in ${wave_members[w]}; do printf '%s %s\n' "$w" "$m"; done
  done
}

# Render the wave schedule to resolve-waves.json on the parent (machine form,
# mirrors the per-Mission waves.json idea: [ { wave, bugs:[ id... ] } ]).
emit_resolve_waves_json() { # "<wave> <id>" lines on stdin
  awk '
    { w=$1; if (!(w in seen)) { seen[w]=1; worder[++nw]=w } cnt[w]++; bid[w,cnt[w]]=$2 }
    END {
      print "["
      for (x=1;x<=nw;x++) {
        w=worder[x]
        print "  {"
        printf "    \"wave\": %s,\n", w
        print "    \"bugs\": ["
        for (y=1;y<=cnt[w];y++) printf "      \"%s\"%s\n", bid[w,y], (y<cnt[w]?",":"")
        print "    ]"
        printf "  }%s\n", (x<nw?",":"")
      }
      print "]"
    }
  '
}

# The queued flag (UX-29): stamp/clear state.json.queued for a child.
mark_queued()   { state_set_raw "$MISSIONS_DIR/$1/state.json" queued true; }
clear_queued()  { state_del     "$MISSIONS_DIR/$1/state.json" queued; }

# --- complete: fold the verified children to Done, no per-bug PR (BUG-E) ----
# Model A — logged-bug fixes ride the PARENT's PR. When the consolidated
# re-verify gate is accepted, every linked child still parked at Verify is moved
# to Done WITHOUT opening its own PR: its fix already lives on the parent branch
# (log.sh records the parent branch for a pre-merge child), so the parent's PR
# carries it. We only flip the stage + board label here. A child must never be
# left orphaned at Verify after acceptance. NEVER calls `gh pr create`.
# child_recorded_a_commit <bug-id> — did this bug's Implement actually produce a
# commit? A green ticket with no file changes records no .commit-sha and has
# nothing to verify, so it must never be refused below.
child_recorded_a_commit() { # bug-id
  local f
  for f in "$MISSIONS_DIR/$1"/tickets/*/.commit-sha; do
    [ -s "$f" ] && return 0
  done
  return 1
}

# child_fix_on_branch <bug-id> <branch> — is this bug's fix ACTUALLY on the
# parent branch?
#
# Matching the recorded worktree sha would be WRONG: cmd_implement CHERRY-PICKS
# that commit onto the mission branch, so the branch carries a DIFFERENT sha with
# the same message (in the real incident the worktree sha was ec85424 while the
# branch carried b75400b). A cherry-pick PRESERVES the subject, so the reliable
# signal is the "lcars(<bug-id>) …" prefix commit_ticket writes.
#
# Returns 0 (present) when the branch cannot be resolved at all — an unverifiable
# state must never become a refusal, or a local-only / branch-less mission would
# be blocked from completing.
# NEVER pipe git into `grep -q` here. This script runs under `set -o pipefail`, and
# `grep -q` exits the instant it matches — which closes the pipe under git, so git
# dies of SIGPIPE (141) and pipefail hands that 141 back as the function's status.
# The result was inverted on the ONE case that matters: a fix that IS on the branch
# reported "not on branch", so fold_one_child REFUSED every legitimate fold with
# "its fix is NOT on the parent branch" — a false alarm about vanished code, on
# work that was sitting right there. Capture first, match with a here-string: no
# pipe, no SIGPIPE, same subjects-only fixed-string semantics.
child_fix_on_branch() { # bug-id branch
  local bid="$1" branch="$2" subjects
  [ -n "$branch" ] || return 0
  "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" || return 0
  subjects="$("$GIT_BIN" log --format=%s "$branch" 2>/dev/null)" || return 0
  grep -qF "lcars($bid)" <<<"$subjects"
}

# fold_one_child — the per-bug fold-to-Done step, shared by the bulk and the
# single-bug (BUG-032) complete paths so the fold logic is authored ONCE. Given a
# child bug id whose stage is verify, flips it to done on disk and moves its board
# column (clear stage labels, apply lcars:done) WITHOUT opening a per-bug PR — the
# parent's PR carries the fix. Echoes nothing on stdout (only a best-effort
# forge-failure note on stderr). Never rewrites the child's branch.
#
# Returns: 0 folded · 1 not at verify (skipped) · 2 REFUSED — the fix is not on
# the parent branch.
#
# THE PREMISE IS NOW CHECKED. This function used to assert that the fix "already
# lives on the parent branch" and flip the stage regardless. When that premise
# was false the bug went to Done with a green board and no fix anywhere — which
# is precisely how three DX-Scorecard fixes vanished on 2026-07-28 (a reconcile
# re-entry reset the parent branch out from under them, and the fold then marked
# all three Done). The reconcile fix removes that cause; verifying here closes
# the CLASS, so any future cause is a loud refusal at the moment of decision
# rather than a silent loss discovered days later.
fold_one_child() { # bug-id
  local bid="$1" cstate stage cissue cbranch
  cstate="$MISSIONS_DIR/$bid/state.json"
  [ -f "$cstate" ] || return 1
  stage="$(json_str "$cstate" stage)"
  # Only fold children that reached their Verify gate. A child still mid-flight
  # (escalated / earlier stage) is left untouched — it is not "resolved" yet.
  [ "$stage" = "verify" ] || return 1
  # REFUSE to call it Done when its fix is not where the whole model says it is.
  cbranch="$(json_str "$cstate" branch)"
  if child_recorded_a_commit "$bid" && ! child_fix_on_branch "$bid" "$cbranch"; then
    return 2
  fi
  # Move the child to Done on disk — stage flips to done, branch is preserved
  # (the fix stays folded onto the parent branch; we never rewrite it here).
  state_set_str "$cstate" stage done
  # Board: clear the stage labels, apply lcars:done — same column move approve
  # makes, but WITHOUT a PR (the parent's PR carries the fix). Best-effort.
  #
  # …and then CLOSE the issue (S165). A logged-bug child is NOT a ticket
  # sub-issue: it is a separate Mission linked by `lcars:linked`, so open_pr()
  # never puts it in the PR's `Closes` list and GitHub never auto-closes it on
  # merge. Relabelling and stopping is exactly how seven DX-Scorecard bug issues
  # (#78–84) stayed OPEN carrying `lcars:done` after PR #77 merged all 14 of
  # their commits. The close rides the host adapter — the ONE forge seam — rather
  # than the direct $GH_BIN above.
  #
  # ORDER MATTERS: relabel first, close second. The column move is what the board
  # reads; closing first would briefly show a closed card still sitting in Verify.
  #
  # STRICTLY best-effort, exactly like the relabel: a forge hiccup leaves a
  # legible note on stderr and the fold still returns 0. A logged bug whose fix is
  # really on the parent branch must never be held hostage to a failed API call.
  # Idempotent by construction: `gh issue close` on an already-closed issue warns
  # and exits 0, and a re-fold never reaches here at all (a done child is not at
  # verify, so fold_one_child returns 1 above).
  cissue="$(json_raw "$cstate" githubIssue)"
  case "$cissue" in
    ''|null) : ;;
    *) if command -v "$GH_BIN" >/dev/null 2>&1; then
         "$GH_BIN" issue edit "$cissue" \
           --add-label "lcars:done" \
           --remove-label "lcars:verify" \
           --remove-label "lcars:awaiting-human" >/dev/null 2>&1 || true
         # No pipes here on purpose — this function has already been broken once
         # by SIGPIPE under `set -o pipefail` (see child_fix_on_branch above).
         host issue-close "$cissue" >/dev/null 2>&1 \
           || printf '  ⚠ folded %s but could not close its issue #%s — close it by hand.\n' \
                "$bid" "$cissue" >&2
       fi ;;
  esac
  return 0
}

# parent_has_pending_children — 0 if ANY linked child of the parent is still
# pending (stage != done), 1 if none remain. Used by the single-bug path to
# decide whether the parent's consolidated re-verify gate should stay UP.
# linked_children already excludes done children, so a non-empty list ⇒ pending.
parent_has_pending_children() {
  local bid stage
  while IFS=$'\t' read -r bid stage; do
    [ -n "$bid" ] && return 0
  done < <(linked_children)
  return 1
}

# undriven_children — linked children that have NOT reached Verify (stage is
# neither verify nor done): the un-driven / queued stragglers. A non-empty list
# means the batch is INCOMPLETE — a bulk accept would fold the verified children
# to Done and SILENTLY DROP these (the real incident: 002/003 reached Verify and
# folded while 004 sat stranded at plan). Echoes one "<id>\t<stage>" line each.
undriven_children() {
  local bid stage
  while IFS=$'\t' read -r bid stage; do
    [ -n "$bid" ] || continue
    case "$stage" in
      verify|done) ;;
      *) printf '%s\t%s\n' "$bid" "$stage" ;;
    esac
  done < <(linked_children)
}

# clear_parent_gate — finalize the parent as the bulk path leaves it once every
# child is folded: drop the awaiting-human overlay + pending.json + board label.
# Best-effort; mirrors the gate-raising at the bottom of the default flow in
# reverse. Called only when NO child of the parent remains pending.
clear_parent_gate() {
  state_del "$PARENT_STATE" awaitingHuman
  state_del "$PARENT_STATE" pendingQuestion
  rm -f "$PARENT_DIR/pending.json" 2>/dev/null || true
  case "$PARENT_ISSUE" in
    ''|null) : ;;
    *) if command -v "$GH_BIN" >/dev/null 2>&1; then
         "$GH_BIN" issue edit "$PARENT_ISSUE" \
           --remove-label "lcars:awaiting-human" >/dev/null 2>&1 || true
       fi ;;
  esac
}

# reraise_incomplete_gate — the completeness guard's counterpart to
# clear_parent_gate. respond.sh CLEARS the consolidated gate before delegating the
# fold to us and never blocks on our exit code (PRD: "never blocks clearing the
# gate"), so merely refusing would leave the gate gone and the straggler dropped.
# Instead we RE-RAISE the parent's gate with a corrective ask naming the un-driven
# bug(s): the parent returns to awaiting-human, and the captain drives them (re-run
# resolve-logs) before re-accepting. Mirrors the bottom gate-raise; folds nothing.
reraise_incomplete_gate() { # $1 = "<id>\t<stage>" lines (the undriven set)
  local bid stage idlist=""
  while IFS=$'\t' read -r bid stage; do
    [ -n "$bid" ] || continue
    idlist="$idlist
  • $bid (stage $stage)"
  done <<<"$1"
  local ask="Cannot accept $PARENT_ID ($PARENT_TITLE) yet — one or more logged bugs have NOT reached their Verify gate and would be silently dropped. Drive them with \`lcars resolve-logs $PARENT_ID\`, then re-accept. Still unresolved:$idlist"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$(json_str "$PARENT_STATE" stage)"
    echo '  "questions": ['
    printf '    "%s"\n' "$(json_escape "$ask")"
    echo '  ]'
    echo '}'
  } >"$PARENT_DIR/pending.json"
  state_set_raw "$PARENT_STATE" awaitingHuman true
  state_set_str "$PARENT_STATE" pendingQuestion "$ask"
  case "$PARENT_ISSUE" in
    ''|null) : ;;
    *) command -v "$GH_BIN" >/dev/null 2>&1 \
         && "$GH_BIN" issue edit "$PARENT_ISSUE" --add-label "lcars:awaiting-human" >/dev/null 2>&1 || true ;;
  esac
}

# reraise_push_failure_gate — sibling of reraise_incomplete_gate for the S89
# push-on-accept guard. The BULK accept must PUSH the parent branch (which carries
# the already-committed logged-bug fixes) to origin so the open PR reflects them,
# and BLOCK the accept until that push succeeds. respond.sh CLEARS the consolidated
# gate before delegating the fold to us and ignores our exit code, so a printed
# error is invisible — a push failure MUST surface via STATE. We RE-RAISE the
# parent's gate with an ask naming the branch + the captured git push output, so
# the parent returns to awaiting-human and never reads as shipped/PR-current.
# Mirrors the bottom gate-raise; folds nothing. $1 = branch, $2 = push output.
reraise_push_failure_gate() {
  local branch="$1" out="$2"
  local ask="Cannot accept $PARENT_ID ($PARENT_TITLE) — pushing the parent branch \`$branch\` to origin FAILED, so the open PR does NOT reflect the accepted logged-bug fixes. Nothing was shipped and no logged bug was folded to Done. Fix the push (auth / network / non-fast-forward), then re-run \`lcars resolve-logs complete --parent $PARENT_ID\` to retry the push and fold. git push said: $out"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$(json_str "$PARENT_STATE" stage)"
    echo '  "questions": ['
    printf '    "%s"\n' "$(json_escape "$ask")"
    echo '  ]'
    echo '}'
  } >"$PARENT_DIR/pending.json"
  state_set_raw "$PARENT_STATE" awaitingHuman true
  state_set_str "$PARENT_STATE" pendingQuestion "$ask"
  case "$PARENT_ISSUE" in
    ''|null) : ;;
    *) command -v "$GH_BIN" >/dev/null 2>&1 \
         && "$GH_BIN" issue edit "$PARENT_ISSUE" --add-label "lcars:awaiting-human" >/dev/null 2>&1 || true ;;
  esac
}

# reraise_no_branch_gate — the missing-branch counterpart of the push-failure gate
# (S90 GAP 2). When an origin IS configured (a real PR to keep current) but the
# parent records NO branch, there is nothing to push — we cannot bring the open PR
# current, and folding would SILENTLY ship nothing to it (the stale-PR hazard this
# round closes). As with the push-failure case respond.sh has already cleared the
# gate and ignores our exit code, so a printed error is invisible: we RE-RAISE the
# parent's gate via STATE with an ask making clear the parent records NO branch so
# its open PR cannot be brought current and the batch was NOT folded. Folds nothing.
reraise_no_branch_gate() {
  local ask="Cannot accept $PARENT_ID ($PARENT_TITLE) — an origin is configured (its open PR must be kept current) but the parent records NO branch, so its open PR cannot be brought current to reflect the accepted logged-bug fixes. Nothing was shipped and no logged bug was folded to Done. Record the parent's working branch in its state.json, then re-run \`lcars resolve-logs complete --parent $PARENT_ID\`."
  {
    echo '{'
    printf '  "stage": "%s",\n' "$(json_str "$PARENT_STATE" stage)"
    echo '  "questions": ['
    printf '    "%s"\n' "$(json_escape "$ask")"
    echo '  ]'
    echo '}'
  } >"$PARENT_DIR/pending.json"
  state_set_raw "$PARENT_STATE" awaitingHuman true
  state_set_str "$PARENT_STATE" pendingQuestion "$ask"
  case "$PARENT_ISSUE" in
    ''|null) : ;;
    *) command -v "$GH_BIN" >/dev/null 2>&1 \
         && "$GH_BIN" issue edit "$PARENT_ISSUE" --add-label "lcars:awaiting-human" >/dev/null 2>&1 || true ;;
  esac
}

# --- single-bug complete (BUG-032): fold ONLY one child, re-evaluate the gate --
# The per-bug "Verify" on a single bug card must complete ONLY that bug — NOT the
# whole batch. It folds just this child to Done, then re-checks the parent: if any
# sibling bug is still pending, the parent's consolidated re-verify gate STAYS up;
# only when none remain do we finalize the parent (clear the gate) as the bulk
# path would. Contrast cmd_complete (no --bug), which accepts ALL remaining bugs.
cmd_complete_single() { # bug-id
  local bid="$1"
  [ -f "$MISSIONS_DIR/$bid/state.json" ] \
    || die "no such bug Mission \"$bid\" to complete."
  # Guard: the --bug must actually be a linked child of this parent.
  local cparent ctype
  cparent="$(json_str "$MISSIONS_DIR/$bid/state.json" parentMission)"
  ctype="$(json_str "$MISSIONS_DIR/$bid/state.json" type)"
  [ "$ctype" = "bug" ] || die "$bid is not a bug Mission."
  [ "$cparent" = "$PARENT_ID" ] \
    || die "$bid is not linked to parent $PARENT_ID (parentMission=$cparent)."

  fold_one_child "$bid"; fold_rc=$?
  if [ "$fold_rc" -eq 2 ]; then
    die "$bid reached Verify but its fix is NOT on the parent branch '$(json_str "$MISSIONS_DIR/$bid/state.json" branch)' — REFUSING to mark it Done, because that would report a fix that does not exist. A logged bug's fix rides the parent's PR, so it must be present on that branch. Re-run the bug (\`lcars run $bid\`) to rebuild it, or restore the commit if the branch was reset."
  fi
  if [ "$fold_rc" -ne 0 ]; then
    echo "lcars resolve-logs: $bid is not at a Verify gate (stage is '$(json_str "$MISSIONS_DIR/$bid/state.json" stage)') — nothing to complete for it."
    exit 0
  fi

  case "$(json_raw "$MISSIONS_DIR/$bid/state.json" githubIssue)" in
    ''|null) blabel="$bid" ;;
    *) blabel="#$(json_raw "$MISSIONS_DIR/$bid/state.json" githubIssue)" ;;
  esac

  if parent_has_pending_children; then
    printf 'Folded %s into %s (%s) — moved to Done. Other logged bugs are still pending; the consolidated re-verify gate stays up.\n' \
      "$blabel" "$PARENT_ID" "$PARENT_TITLE"
  else
    clear_parent_gate
    printf 'Folded %s into %s (%s) — moved to Done. No logged bugs remain; the consolidated re-verify gate is cleared.\n' \
      "$blabel" "$PARENT_ID" "$PARENT_TITLE"
  fi
  exit 0
}

cmd_complete() {
  local folded=0 bid stage
  # --- COMPLETENESS GUARD ---------------------------------------------------
  # Never fold a PARTIAL batch. If ANY linked child has not reached Verify, a bulk
  # accept would fold the verified children to Done and SILENTLY DROP the rest (the
  # real incident: 004 stranded at plan while 002/003 folded). respond.sh has
  # already cleared the gate and ignores our exit code, so we RE-RAISE the gate with
  # a corrective ask and refuse (non-zero). The captain drives the straggler (re-run
  # resolve-logs), then re-accepts. Single-bug `complete --bug` is intentionally
  # exempt: it folds one verified card and leaves the gate up for the rest.
  local undriven; undriven="$(undriven_children)"
  if [ -n "$undriven" ]; then
    reraise_incomplete_gate "$undriven"
    echo "lcars resolve-logs: NOT completing $PARENT_ID — these logged bugs have not reached Verify:" >&2
    while IFS=$'\t' read -r bid stage; do
      [ -n "$bid" ] && echo "  • $bid (stage $stage)" >&2
    done <<<"$undriven"
    echo "  Re-raised the consolidated gate. Drive them with \`lcars resolve-logs $PARENT_ID\`, then accept again." >&2
    exit 1
  fi

  # The fold set: after the guard, every remaining linked (non-done) child is at
  # its Verify gate. Gather it up front so we know whether there is a REAL batch
  # to ship before touching the remote.
  local fold_ids=()
  while IFS=$'\t' read -r bid stage; do
    [ -n "$bid" ] || continue
    fold_ids+=("$bid")
  done < <(linked_children)

  # IDEMPOTENT / no-op: nothing at Verify to fold (all already done, or none).
  # There is no batch to ship, so we DO NOT push — a second accept of an
  # already-folded+pushed parent is a clean no-op. Return before the push.
  if [ "${#fold_ids[@]}" -eq 0 ]; then
    echo "lcars resolve-logs: no child bug at Verify to fold into $PARENT_ID — nothing to complete."
    exit 0
  fi

  # --- PUSH-BEFORE-FOLD (S89) -----------------------------------------------
  # The fix commits already live on the PARENT branch (fold only flips child
  # stage/labels), so accepting the consolidated gate must make the OPEN PR
  # reflect them: PUSH the parent branch to origin and BLOCK the accept until it
  # succeeds. We push BEFORE folding (not fold-then-push-then-rollback) for two
  # reasons: (1) on a push failure NOTHING is folded — nothing reads as
  # shipped/PR-current; and (2) a RE-RUN naturally RETRIES the push, because the
  # children are still at Verify (un-folded) so the fold set is non-empty again.
  # respond.sh ignores our exit code, so a failure MUST surface via the re-raised
  # STATE gate (reraise_push_failure_gate), never just stdout. Capture-the-result
  # (BUG-066 pattern), never fire-and-forget.
  #
  # ORIGIN-FIRST (S90 GAP 2): the decision pivots on whether there is a real remote
  # to keep current, NOT on whether a branch happens to be recorded. When an origin
  # IS configured there is an open PR to bring current, so:
  #   • parent records NO branch → we cannot push anything → folding would SILENTLY
  #     ship nothing to the open PR (the stale-PR hazard). BLOCK + re-raise; fold
  #     NOTHING. (Previously `[ -n "$branch" ]` short-circuited the whole guard and
  #     folded silently — the hole this closes.)
  #   • parent HAS a branch → push it; on failure re-raise + block (no force-push —
  #     a non-fast-forward means the remote genuinely diverged and the human must
  #     reconcile; that is approve's concern, never ours).
  # When NO origin is configured (the local/test-repo escape hatch — the parent
  # branch IS the local branch with nowhere to ship) we skip the push entirely and
  # fall through to the fold, exactly as before.
  local branch; branch="$(json_str "$PARENT_STATE" branch)"
  if command -v "$GIT_BIN" >/dev/null 2>&1 \
     && "$GIT_BIN" remote get-url origin >/dev/null 2>&1; then
    if [ -z "$branch" ]; then
      reraise_no_branch_gate
      echo "lcars resolve-logs: NOT completing $PARENT_ID — an origin is configured but the parent records NO branch, so its open PR cannot be brought current; nothing was folded. Re-raised the consolidated gate." >&2
      echo "  Record the parent's branch in its state.json, then re-run \`lcars resolve-logs complete --parent $PARENT_ID\`." >&2
      exit 1
    fi
    local push_out push_rc=0
    push_out="$("$GIT_BIN" push origin "$branch" 2>&1)" || push_rc=$?
    if [ "$push_rc" -ne 0 ]; then
      reraise_push_failure_gate "$branch" "$push_out"
      echo "lcars resolve-logs: NOT completing $PARENT_ID — pushing branch '$branch' to origin failed; the PR would not reflect the fixes, so nothing was folded. Re-raised the consolidated gate." >&2
      echo "  git push: $push_out" >&2
      echo "  Fix the push, then re-run \`lcars resolve-logs complete --parent $PARENT_ID\`." >&2
      exit 1
    fi
  fi

  # Push landed (or there is no remote to ship to) — fold the verified children.
  # A child whose fix is NOT on the parent branch is REFUSED (rc 2), never folded:
  # marking it Done would report a fix that does not exist. Its siblings still
  # fold — their work is real and must not be held hostage — but the refusal is
  # loud and the command exits non-zero.
  local fold_refused=""
  for bid in "${fold_ids[@]}"; do
    fold_one_child "$bid"; fold_rc=$?
    case "$fold_rc" in
      0) folded=$((folded + 1)) ;;
      2) fold_refused="${fold_refused:+$fold_refused }$bid" ;;
    esac
  done
  if [ -n "$fold_refused" ]; then
    printf 'lcars resolve-logs: REFUSED to mark these logged bug(s) Done — their fixes are NOT on the parent branch: %s\n' "$fold_refused" >&2
    printf '  A logged bug'\''s fix rides the parent'\''s PR, so it must be present on that branch. Marking them Done would report fixes that do not exist.\n' >&2
    printf '  Re-run each (`lcars run <id>`) to rebuild the fix, or restore the commits if the branch was reset. %d sibling(s) folded normally.\n' "$folded" >&2
    exit 1
  fi

  if [ "$folded" -eq 0 ]; then
    echo "lcars resolve-logs: no child bug at Verify to fold into $PARENT_ID — nothing to complete."
    exit 0
  fi
  noun="logged bugs"; [ "$folded" -eq 1 ] && noun="logged bug"
  printf 'Folded %d %s into %s (%s) — moved to Done; no per-bug PR (the parent PR carries the fixes).\n' \
    "$folded" "$noun" "$PARENT_ID" "$PARENT_TITLE"
  exit 0
}

if [ "$SUBCOMMAND" = "complete" ]; then
  if [ -n "$BUG_SEL" ]; then
    cmd_complete_single "$BUG_SEL"
  fi
  cmd_complete
fi

# --- GATHER the linked bug Missions ----------------------------------------
# A linked bug: type==bug, parentMission==PARENT_ID. "open" = stage != done.
# The work set is the open bugs not yet at their Verify gate; bugs already at
# verify count as resolved (they reached the gate already).
linked_open=()      # ids, filed order (sorted by id)
work=()             # open bugs still needing driving (stage != verify)
resolved=()         # open bugs already at verify
paused_existing=""  # an open bug already parked at awaiting-human (prior run)

while IFS= read -r s; do
  [ -n "$s" ] || continue
  bid="$(json_str "$s" id)"; [ -n "$bid" ] || bid="$(basename "$(dirname "$s")")"
  type="$(json_str "$s" type)"
  parent="$(json_str "$s" parentMission)"
  stage="$(json_str "$s" stage)"
  awaiting="$(json_raw "$s" awaitingHuman)"
  [ "$type" = "bug" ] || continue
  [ "$parent" = "$PARENT_ID" ] || continue
  [ "$stage" = "done" ] && continue
  linked_open+=("$bid")
  if [ "$awaiting" = "true" ]; then
    [ -z "$paused_existing" ] && paused_existing="$bid"
  elif [ "$stage" = "verify" ]; then
    resolved+=("$bid")
  else
    work+=("$bid")
  fi
done < <(ls -1 "$MISSIONS_DIR"/*/state.json 2>/dev/null | sort)

if [ "${#linked_open[@]}" -eq 0 ]; then
  case "$PARENT_ISSUE" in ''|null) plabel="$PARENT_ID" ;; *) plabel="#$PARENT_ISSUE" ;; esac
  echo "lcars resolve-logs: no open linked bug Missions for $plabel ($PARENT_TITLE) — nothing to resolve."
  exit 0
fi

# --- ORDER the work set (the LLM half) -------------------------------------
ORDER_FILE="$PARENT_DIR/resolve-logs.md"

worker_order() { # echoes "<id> <rationale...>" lines from the worker (best-effort)
  [ -n "$WORKER_BIN" ] || return 0
  command -v "$WORKER_BIN" >/dev/null 2>&1 || [ -x "$WORKER_BIN" ] || return 0
  local prompt out id t
  prompt="You are choosing the order to resolve logged bug Missions for parent $PARENT_ID ($PARENT_TITLE).
Resolve root-cause / data-model bugs and dependencies BEFORE cosmetic ones.
Output one bug id per line, in the order to resolve them, optionally followed by a one-line rationale:
  <mission-id>: <one-line rationale>
The candidate bug Missions (filed order) are:"
  for id in "${work[@]}"; do
    t="$(json_str "$MISSIONS_DIR/$id/state.json" title)"
    prompt="$prompt
  $id  $t"
  done
  out="$("$WORKER_BIN" "$prompt" 2>/dev/null)" || return 0
  printf '%s\n' "$out"
}

ORDERED=()
in_work() { local x="$1" w; for w in "${work[@]}"; do [ "$w" = "$x" ] && return 0; done; return 1; }
already_ordered() { local x="$1" o; for o in "${ORDERED[@]:-}"; do [ "$o" = "$x" ] && return 0; done; return 1; }

if [ "${#work[@]}" -gt 0 ]; then
  RATIONALE=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tok="${line%%[: ]*}"
    rest="${line#"$tok"}"; rest="${rest#:}"; rest="${rest# }"
    if in_work "$tok" && ! already_ordered "$tok"; then
      ORDERED+=("$tok")
      RATIONALE+=("$tok|${rest:-chosen by the resolution-order worker}")
    fi
  done < <(worker_order)

  # Append any work ids the worker omitted, in filed order, so none are dropped.
  for id in "${work[@]}"; do
    already_ordered "$id" || { ORDERED+=("$id"); RATIONALE+=("$id|filed order (worker offered no placement)"); }
  done

  # Record the chosen order + rationale on the parent.
  {
    printf '# Resolve-logs order for %s (%s)\n\n' "$PARENT_ID" "$PARENT_TITLE"
    if [ -n "$WORKER_BIN" ]; then
      printf 'Chosen by the resolution-order worker — recorded %s.\n\n' "$NOW"
    else
      printf 'Chosen as filed order (no worker) — recorded %s.\n\n' "$NOW"
    fi
    n=1
    for r in "${RATIONALE[@]}"; do
      rid="${r%%|*}"; rwhy="${r#*|}"
      rt="$(json_str "$MISSIONS_DIR/$rid/state.json" title)"
      printf '%d. %s — %s\n   %s\n' "$n" "$rid" "$rt" "$rwhy"
      n=$((n + 1))
    done
  } >"$ORDER_FILE"
fi

# --- DRIVE each bug to its Verify gate, wave by wave -----------------------
# run_child_driver just delegates to `lcars run drive` (BUG-D engine inheritance
# preserved); it does NOT inspect the result — that is done after, by
# child_outcome, so the same runner is usable both synchronously and as a
# background job for concurrent waves. It clears the child's queued flag first
# (it is now starting its wave).
run_child_driver() { # id
  local id="$1"
  clear_queued "$id"
  if [ -n "$PARENT_ENGINE" ]; then
    LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" LCARS_WORKER_BIN="$PARENT_ENGINE" \
    LCARS_NOTIFY="$NOTIFY_BIN" \
      bash "$RUN_SCRIPT" drive --mission "$id" >/dev/null 2>&1 || true
  else
    LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
    LCARS_NOTIFY="$NOTIFY_BIN" \
      env -u LCARS_WORKER_BIN bash "$RUN_SCRIPT" drive --mission "$id" >/dev/null 2>&1 || true
  fi
}

child_outcome() { # id -> 0 reached verify | 1 paused (awaiting-human) | 2 error
  local sfile="$MISSIONS_DIR/$1/state.json" stage awaiting
  stage="$(json_str "$sfile" stage)"
  awaiting="$(json_raw "$sfile" awaitingHuman)"
  [ "$awaiting" = "true" ] && return 1
  [ "$stage" = "verify" ] && return 0
  [ "$stage" = "done" ] && return 0
  return 2
}

pause_at() { # id
  local id="$1" first
  first="$(json_str "$MISSIONS_DIR/$id/state.json" pendingQuestion)"
  echo "lcars resolve-logs: paused at $id — it needs your answer before the batch can continue."
  [ -n "$first" ] && echo "  • $first"
  echo "  Answer it in the inbox (\`lcars answer\`), then re-run \`lcars resolve-logs $PARENT_ID\`."
  echo "  Already-resolved bugs are untouched."
}

# A bug already parked at awaiting-human blocks the batch up front.
if [ -n "$paused_existing" ]; then
  pause_at "$paused_existing"
  exit 0
fi

# --- clear any STALE consolidated gate before re-driving (S76) ---------------
# A previous round may have left a consolidated re-verify gate on the PARENT.
# If THIS round has work to drive (a linked child is NOT yet at its Verify gate —
# e.g. it was sent back), that gate is now stale: the parent should read
# "resolving", not falsely-acceptable, while the re-fix is in flight. Clear it
# here, before the DRIVE loop. The gate is re-raised at the END exactly as today
# once every child reaches verify. We do NOT clear it when GATHER found the set
# already all-at-verify (no work) — that path only (re)raises the gate.
if [ "${#work[@]}" -gt 0 ]; then
  clear_parent_gate
fi

# --- build the wave schedule over the ordered work set ----------------------
# CONCURRENCY cap: same-wave children drive concurrently up to this many at once.
# 1 ⇒ scheduled-but-serial (still produces the schedule + queued signal).
CONCURRENCY="${LCARS_RESOLVE_CONCURRENCY:-2}"
case "$CONCURRENCY" in ''|*[!0-9]*) CONCURRENCY=2 ;; esac
[ "$CONCURRENCY" -ge 1 ] || CONCURRENCY=1

WAVE_LINES=""
if [ "${#ORDERED[@]:-0}" -gt 0 ]; then
  WAVE_LINES="$(compute_bug_waves "${ORDERED[@]}")"
  emit_resolve_waves_json <<<"$WAVE_LINES" >"$PARENT_DIR/resolve-waves.json"
  # Append the wave grouping to the human-readable order record (best-effort).
  if [ -f "$ORDER_FILE" ]; then
    {
      echo
      echo "## Wave schedule (independent bugs share a wave; waves run in sequence)"
      cur=""
      while read -r w id; do
        [ -n "$id" ] || continue
        [ "$w" != "$cur" ] && { printf 'Wave %s:\n' "$w"; cur="$w"; }
        printf '  - %s\n' "$id"
      done <<<"$WAVE_LINES"
    } >>"$ORDER_FILE"
  fi
fi

# QUEUED signal (UX-29): every scheduled work bug is queued up front; each clears
# its own flag when run_child_driver starts it. So a child waiting its wave reads
# queued:true; one in-flight or done reads no flag.
for id in "${work[@]:-}"; do
  [ -n "$id" ] || continue
  mark_queued "$id"
done

# --- execute the waves in sequence; same-wave bugs run concurrently ---------
# We walk WAVE_LINES grouped by wave. Within a wave we launch up to CONCURRENCY
# background drivers, then `wait` for them all before inspecting outcomes. If ANY
# child in the completed wave escalated, we PAUSE the batch (remaining waves do
# NOT run) and surface that child's question — leaving the queued flags on the
# not-yet-started bugs so the board still shows them waiting.
run_one_wave() { # wave-id  ids...
  local _wave="$1"; shift
  local ids=("$@") chunk=() id rc
  local paused_id="" errored_id=""
  # Launch in CONCURRENCY-sized chunks.
  while [ "${#ids[@]}" -gt 0 ]; do
    chunk=("${ids[@]:0:$CONCURRENCY}")
    ids=("${ids[@]:$CONCURRENCY}")
    if [ "${#chunk[@]}" -eq 1 ]; then
      run_child_driver "${chunk[0]}"            # lone child: run inline.
    else
      local pids=()
      for id in "${chunk[@]}"; do
        run_child_driver "$id" &
        pids+=("$!")
      done
      for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    fi
  done
  # Inspect outcomes for this whole wave.
  for id in "$@"; do
    child_outcome "$id"; rc=$?
    case "$rc" in
      0) resolved+=("$id") ;;
      1) [ -z "$paused_id" ] && paused_id="$id" ;;
      2) [ -z "$errored_id" ] && errored_id="$id" ;;
    esac
  done
  [ -n "$paused_id" ]  && { WAVE_PAUSED="$paused_id"; return 1; }
  [ -n "$errored_id" ] && { WAVE_ERRORED="$errored_id"; return 2; }
  return 0
}

WAVE_PAUSED=""; WAVE_ERRORED=""
if [ -n "$WAVE_LINES" ]; then
  cur_wave=""; wave_ids=()
  flush_wave() {
    [ "${#wave_ids[@]}" -gt 0 ] || return 0
    run_one_wave "$cur_wave" "${wave_ids[@]}"; return $?
  }
  while read -r w id; do
    [ -n "$id" ] || continue
    if [ "$w" != "$cur_wave" ]; then
      if [ -n "$cur_wave" ]; then
        flush_wave; frc=$?
        [ "$frc" -ne 0 ] && break
      fi
      cur_wave="$w"; wave_ids=()
    fi
    wave_ids+=("$id")
  done <<<"$WAVE_LINES"
  # Final wave (only if we did not already break out on a pause/error).
  if [ -z "$WAVE_PAUSED" ] && [ -z "$WAVE_ERRORED" ]; then
    flush_wave || true
  fi
fi

if [ -n "$WAVE_PAUSED" ]; then
  pause_at "$WAVE_PAUSED"
  exit 0
fi
# BUG-064: a child that did not reach its Verify gate (stuck mid-flight, NOT
# awaiting-human) must NOT throw away the consolidated gate for the children that
# DID fold to verify. If at least one child reached verify, we fall through and
# raise the parent's single consolidated re-verify gate for the resolved set,
# surfacing the stuck child as still needing manual attention. Only when NOTHING
# reached verify is there genuinely no gate to raise — then we error out as before.
STUCK_NOTE=""
if [ -n "$WAVE_ERRORED" ]; then
  if [ "${#resolved[@]}" -eq 0 ]; then
    die "driving $WAVE_ERRORED did not reach its Verify gate (stage is now '$(json_str "$MISSIONS_DIR/$WAVE_ERRORED/state.json" stage)') — resolve it manually with \`lcars run $WAVE_ERRORED\`, then re-run."
  fi
  STUCK_NOTE="One logged bug did NOT reach its Verify gate and still needs attention: $WAVE_ERRORED (stage '$(json_str "$MISSIONS_DIR/$WAVE_ERRORED/state.json" stage)'). Resolve it with \`lcars run $WAVE_ERRORED\`, then re-run \`lcars resolve-logs $PARENT_ID\` to fold it in."
fi

# --- THE SINGLE RE-VERIFY ASK ----------------------------------------------
n="${#resolved[@]}"
[ "$n" -gt 0 ] || { echo "lcars resolve-logs: nothing reached a Verify gate — nothing to ask."; exit 0; }

list_txt=""
for id in "${resolved[@]}"; do
  t="$(json_str "$MISSIONS_DIR/$id/state.json" title)"
  list_txt="$list_txt
  • $id — $t"
done

noun="logged bugs"; [ "$n" -eq 1 ] && noun="logged bug"
# Model A (BUG-E): the fixes are folded onto the PARENT's branch and ride its PR
# — there is NO per-bug PR. The captain re-verifies the parent ONCE; ACCEPTING
# this gate (answer it in the inbox) folds the children to Done. Sending the
# parent back uses the parent's own feedback loop.
ASK="$n $noun resolved on $PARENT_ID ($PARENT_TITLE)'s branch — ready for your single re-verify. Re-inspect the fixes (they ride this Mission's PR — no per-bug PR), then ANSWER this gate to accept them (each logged bug is folded to Done) or send the Mission back with \`lcars feedback $PARENT_ID\`."
[ -n "$STUCK_NOTE" ] && ASK="$ASK $STUCK_NOTE"

# pending.json on the PARENT (the answer inbox reads this).
{
  echo '{'
  printf '  "stage": "%s",\n' "$(json_str "$PARENT_STATE" stage)"
  echo '  "questions": ['
  printf '    "%s"\n' "$(json_escape "$ASK")"
  echo '  ]'
  echo '}'
} >"$PARENT_DIR/pending.json"

# Overlay the awaiting-human gate on the parent's state.
state_set_raw "$PARENT_STATE" awaitingHuman true
state_set_str "$PARENT_STATE" pendingQuestion "$ASK"

# Best-effort board label: add lcars:awaiting-human to the parent issue.
case "$PARENT_ISSUE" in
  ''|null) : ;;
  *) if command -v "$GH_BIN" >/dev/null 2>&1; then
       "$GH_BIN" issue edit "$PARENT_ISSUE" --add-label "lcars:awaiting-human" >/dev/null 2>&1 || true
     fi ;;
esac

# ONE notification (env-injected hook), keyed to the PARENT.
LCARS_CFG="$CONFIG" "$NOTIFY_BIN" "$PARENT_ID" "awaiting-human" "$ASK" >/dev/null 2>&1 || true

# --- summary ---------------------------------------------------------------
case "$PARENT_ISSUE" in ''|null) plabel="$PARENT_ID" ;; *) plabel="#$PARENT_ISSUE" ;; esac
printf '%d %s resolved to Verify and folded onto %s (%s):%s\n' "$n" "$noun" "$plabel" "$PARENT_TITLE" "$list_txt"
if [ -n "$STUCK_NOTE" ]; then
  echo
  echo "⚠ $STUCK_NOTE"
fi
echo
echo "Raised ONE consolidated re-verify gate on $PARENT_ID and pinged you once."
echo "The fixes ride this Mission's PR — there is NO per-bug PR. Re-inspect them, then:"
echo "  lcars answer respond --mission $PARENT_ID --answer \"…\"   — accept (folds each logged bug to Done)"
echo "  lcars feedback $PARENT_ID \"…\"                            — send the Mission back"
echo "Open the inbox with \`lcars answer\` to act on the consolidated card."
exit 0
