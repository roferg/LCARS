#!/usr/bin/env bash
#
# lcars approve — ship a verified Mission: MERGE its open PR and mark it Done.
#
# S75 changed approve's job. Verify now AUTO-OPENS the PR (the driver, reusing
# the shared pr-lib.sh open_pr) and parks the Mission "in review — PR open".
# `lcars approve` is the captain's MERGE signal: on a Mission at "verify" WITH an
# open PR (prUrl recorded in state.json), it merges the PR via the host adapter,
# then — and ONLY on a successful merge — clears the stage labels, marks the
# issue lcars:done, moves state.json's stage to "done", and prints the result.
#
# It is purely mechanical — no LLM. It NEVER marks a Mission Done without a real
# merge: if the merge call fails (auth, conflicts, gh absent) it stays at verify
# with a clear message. Approve REQUIRES an open PR to merge — Verify opens it.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary  (default: gh)
#   LCARS_GIT_BIN  the git binary (default: git)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
RELABEL_NOTE=""

# The host-integration adapter — the ONE place that speaks to a forge. It lives
# in the sibling lcars-run skill dir; $LCARS_HOST_ADAPTER overrides that path.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- THE state.json field writer (S207) ------------------------------------
# ONE family, in ONE place: lcars_state_set (a raw JSON token) /
# lcars_state_set_string (plain text, escaped for you) / lcars_state_unset.
# This file used to carry its own copy, as seven others did, and every copy
# corrupted the object when the field it wrote or cleared was the object's LAST
# one (S189 found it in adopt; S202 made it reachable through the gate clears).
# A MISSING library is FATAL here rather than degraded: a fallback writer is
# exactly how two ways of writing one field get back into the tree.
LCARS_STATE_LIB="${LCARS_STATE_LIB:-$SELF_DIR/../lcars-init/lcars-state.sh}"
[ -f "$LCARS_STATE_LIB" ] || {
  echo "LCARS: the state writer library is missing at $LCARS_STATE_LIB — reinstall LCARS (./install.sh)." >&2
  exit 1
}
# shellcheck source=../lcars-init/lcars-state.sh
. "$LCARS_STATE_LIB"

HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SELF_DIR/../lcars-run/host-adapter.sh}"
# The sibling run.sh — its `reconcile` subcommand is the S76 self-heal engine the
# merge gate runs BEFORE merging (BUG-037). Override the path for tests.
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SELF_DIR/../lcars-run/run.sh}"
# The sibling resolve-logs — it OWNS the logged-bug fold (fold_one_child) and its
# premise check. approve dispatches to it rather than reimplementing the fold, so
# the "is the fix actually on the parent branch?" guard has exactly one home.
# Override the path for tests.
RESOLVE_LOGS_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$SELF_DIR/../lcars-resolve-logs/resolve-logs.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

die() { printf 'lcars approve: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / file.sh) -------------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }


# --- S189: solo ownership, the light lock ----------------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars approve` MERGES a pull request and marks a mission Done, so it consults the lock; the READ verbs (status,
# buddy, the viewscreen's reads) never do. The remedy is deliberately a HUMAN act
# on GitHub — the solo protocol's premise is that the captain moves ownership
# where both laptops can see it, and LCARS never takes a mission off anyone.
#
# The library lives in the sibling lcars-run skill dir (the same reach this
# script already makes for the host adapter). A MISSING library leaves the verb
# unenforced — exactly pre-S189 behaviour — rather than refusing blindly, and
# LCARS_OWNER_ENFORCE=0 bypasses the lock for harness debugging.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SELF_DIR/../lcars-run/ownership.sh}"
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
# S239 — THE ONE CALLED-OUT EXCEPTION OF THIS ROUND. The lock now fires only
# while a look is ALIVE (ownership.sh explains why). A FINISHED verdict is not a
# refusal any more: it is one line printed on the way past, because the captain
# is about to merge the very thing Number One looked at, and because making him
# run `lcars xo off <id>` before every approve cost him 10–20 minutes a Verify
# (feedback #39) and taught him to switch his first officer off.
xo_lock_or_die() { # <mission-dir>
  local r v
  command -v lcars_xo_lock_reason >/dev/null 2>&1 || return 0
  if r="$(lcars_xo_lock_reason "${1:-}")"; then
    # THE NARROWING IS HERE AND ONLY HERE. The shared lock still answers "is
    # Number One engaged" for every other write verb, exactly as S201 wrote it
    # and as `tests/ownership.test.sh` asserts, sentence for sentence. `approve`
    # alone asks the narrower question, because it is the verb the ruling was
    # about: a LIVE look is a race, a FINISHED one is a line to read.
    if ! command -v lcars_xo_live_look >/dev/null 2>&1 \
       || lcars_xo_live_look "${1:-}"; then
      [ -n "$r" ] && die "$r"
    fi
  fi
  if command -v lcars_xo_verdict_line >/dev/null 2>&1; then
    v="$(lcars_xo_verdict_line "${1:-}" 2>/dev/null)" && [ -n "$v" ] \
      && printf '◈ %s\n' "$v"
  fi
  return 0
}

# --- locate the mission (mirrors run.sh) -----------------------------------
locate_mission() {
  local id="$1" gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$id"
  STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$id' under .git/lcars/missions/ — check the id."
  [ -f "$STATE" ]       || die "mission '$id' has no state.json — its state is corrupt."
}

require_stage() {
  local stage; stage="$(json_str "$STATE" stage)"
  [ "$stage" = "$1" ] || die "mission is at stage '${stage:-unknown}', not '$1' — approve only ships a verified mission."
}

set_stage() {
  local newstage="$1" tmp; tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# JSON-string-safe escape (no surrounding quotes): backslash/quote, then awk
# escapes every control char (newline/tab/CR → \n \t \r, rest \u00XX) so any
# multi-line value yields VALID JSON. jq-free. Order: backslash first.
json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# --- append-only mission event (BUG-071) -----------------------------------
# Mirrors run.sh / pause.sh emit_event: one short single-line JSON record per
# milestone, written in APPEND mode (atomic under PIPE_BUF) to the mission's
# events.jsonl so the card timeline shows the ship. approve had NO emit_event,
# so a merge never recorded a `merged` milestone. NO-OP-SAFE: no MISSION_DIR →
# returns 0. Timestamp overridable via $LCARS_NOW for deterministic tests.
emit_event() { # type stage detail
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ts type stage detail mid
  ts="${LCARS_NOW:-$(date +%s)}"
  type="$(json_escape "${1:-}")"; stage="$(json_escape "${2:-}")"
  detail="$(json_escape "${3:-}")"; mid="$(json_escape "${MISSION_ID:-}")"
  printf '{"ts":%s,"mission":"%s","stage":"%s","type":"%s","detail":"%s"}\n' \
    "$ts" "$mid" "$stage" "$type" "$detail" >>"$MISSION_DIR/events.jsonl"
}

# === S185: PROMOTION AT APPROVE ============================================
# An INITIALIZATION mission (state.json `missionType: "initialization"`, stamped
# by Establish Vision → file.sh) exists to build the repo's test foundation. Its
# scaffold ticket ESTABLISHES a runner, and run.sh records that command
# MISSION-LOCALLY at `<mission>/test-command.json` — deliberately NOT in the
# repo's config.json, because the runner exists only on the mission BRANCH until
# merge, and repo config is shared with every sibling mission.
#
# APPROVE IS NOT MID-MISSION. The PR has merged: the setup files are now on the
# base branch, so the command is a fact about the REPO and belongs in repo
# config. Writing it here is what unlocks everything downstream — the S183
# foundation gate reads `testCommand` through `lcars_test_readiness`, so `lcars
# file` and the holodeck stop refusing the moment this lands, and the board's
# own foundation payload flips with it.
#
# Ordering is load-bearing: this runs ONLY after a SUCCESSFUL merge (inside
# do_merge, past the merge gate), never on the merge-failed path.
promote_test_command() {
  [ -n "${MISSION_DIR:-}" ] || return 0
  [ "$(json_str "$STATE" missionType)" = "initialization" ] || return 0
  local rec="$MISSION_DIR/test-command.json" cmd=""
  # The SANCTIONED shared lib (lcars-common.sh) — the ONE home of BOTH halves of
  # this promotion: the escape-aware reader `lcars_config_get` and the writer
  # `lcars_config_set_or_add_string`. Located FIRST, because without it there is
  # nothing here that can read the record honestly.
  local lib="${LCARS_COMMON_LIB:-$SELF_DIR/../lcars-init/lcars-common.sh}"
  if [ ! -f "$lib" ]; then
    echo "  ⚠ NOTE — lcars-common.sh is not available, so this initialization mission's established test command was NOT promoted to .git/lcars/config.json. Point LCARS at the runner the mission built:  lcars update --test-command '<command>'" >&2
    emit_event foundation_not_promoted done \
      "initialization mission merged but lcars-common.sh was unavailable, so repo config was NOT written; the captain must set testCommand"
    return 0
  fi
  # S185 FIX ROUND 1 — READ IT WITH THE ESCAPE-AWARE READER, NOT approve's own.
  # approve's local json_str stops at the FIRST `\"`, and EVERY command the real
  # detector emits embeds quotes (VITEST_RELATIVIZING_CMD, the jest/mocha/
  # `npm test --` arms, pytest). Read through it, the record
  #   "npx vitest run ${LCARS_TESTS_DIR:+\"${LCARS_TESTS_DIR#\"$PWD/\"}\"}"
  # promoted as
  #   npx vitest run ${LCARS_TESTS_DIR:+\
  # — a fragment no shell can parse, promoted into repo config as the fact that
  # unlocks `lcars file` and the holodeck. `lcars_config_get` is the reader
  # run.sh's json_str mirrors; it is used here on the mission-local record for
  # exactly the same reason it is used on config.json. Sourced in a SUBSHELL —
  # see the write below: nothing the lib defines may reach do_merge's helpers.
  [ -f "$rec" ] && cmd="$( . "$lib" >/dev/null 2>&1 \
                           && command -v lcars_config_get >/dev/null 2>&1 \
                           && lcars_config_get "$rec" testCommand )"
  if [ -z "$cmd" ]; then
    # The mission never recorded an established runner. Say so — silence here
    # would leave the captain with a "done" initialization mission and a repo
    # that still refuses to file a normal one, with nothing explaining why.
    echo "  ⚠ NOTE — this initialization mission recorded no established test command, so nothing was promoted to .git/lcars/config.json. Point LCARS at the runner the mission built:  lcars update --test-command '<command>'" >&2
    emit_event foundation_not_promoted done \
      "initialization mission merged but recorded no established test command — repo config was NOT written; the captain must set testCommand"
    return 0
  fi
  local gitdir; gitdir="$("$GIT_BIN" rev-parse --git-dir 2>/dev/null)" || return 0
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  local cfg="$gitdir/lcars/config.json"
  [ -f "$cfg" ] || { echo "  ⚠ NOTE — no .git/lcars/config.json to promote '$cmd' into." >&2; return 0; }
  # === S232: ONLY AN ABSENT testCommand IS FILLED ===========================
  #
  # THE WEEKEND DEFECT (evidence/lcars-feedback.jsonl #7/#8). This write used to
  # be UNCONDITIONAL. The Canvas repo's config carried the command the captain had
  # recorded BY HAND — `python3 -m unittest discover …`, the stdlib runner, chosen
  # because it is the one that is actually installed — and an initialization
  # mission whose scaffold ticket had declared `pytest` replaced it on merge. Every
  # gate downstream then ran an uninstalled binary, so every suite "failed" for a
  # reason that had nothing to do with the code.
  #
  # A value in repo config is a DECISION, not a cache. It may have been put there
  # by `lcars update --test-command`, by `lcars init`'s detector, or by the captain
  # in an editor, and approve cannot tell which — so it does not get to overrule
  # any of them. An ABSENT value is the only thing this promotion was ever for
  # (S185: the runner exists only on the mission BRANCH until merge, so config is
  # deliberately empty until here), and an absent value is all it fills now.
  #
  # COMPARED EXACTLY — no trimming, no whitespace normalising, no canonicalising.
  # A loose compare is the rejected wrong answer: it decides that two commands are
  # "the same" and then overwrites on the strength of that judgement, which is the
  # same defect wearing a smaller hat. Byte-identical is a no-op (it falls through
  # to the write below, which writes what is already there); ANY other difference
  # keeps the captain's.
  #
  # AND THE DECLARATION IS NOT THROWN AWAY. It is RECORDED on the mission as
  # `declaredTestCommand`, so the mission still carries what its scaffold built and
  # the captain can see both and choose — record, don't discard.
  local existing=""
  existing="$( . "$lib" >/dev/null 2>&1 \
               && command -v lcars_config_get >/dev/null 2>&1 \
               && lcars_config_get "$cfg" testCommand )"
  if [ -n "$existing" ] && [ "$existing" != "$cmd" ]; then
    lcars_state_set_string "$STATE" declaredTestCommand "$cmd"
    emit_event foundation_testcommand_kept done \
      "repo config already had a testCommand ($existing) that differs from this mission's declared one ($cmd) — KEPT the recorded command; the declaration is on the mission as declaredTestCommand"
    echo "  ◇ FOUNDATION — KEPT the testCommand already recorded in .git/lcars/config.json ($existing) rather than the one this mission declared ($cmd), because a command already in repo config is a decision somebody made and approve does not overrule it."
    echo "    The declaration is recorded on the Mission as declaredTestCommand. To switch the repo over:  lcars update --test-command '$cmd'"
    return 0
  fi
  # The SANCTIONED writer (lcars-common.sh) — the same primitive
  # `lcars update --test-command` uses, so there is exactly one way repo config
  # ever gains a testCommand. Sourced in a SUBSHELL: this runs in the middle of
  # do_merge, after the merge and before the stage flip, and approve.sh's own
  # helpers (die / json_str / lcars_state_set_string "$STATE" / emit_event) must not be reachable
  # by anything the lib might define. The subshell writes the file and exits;
  # nothing it defines survives. ($lib was located and checked above.)
  if ! ( . "$lib" >/dev/null 2>&1 \
         && command -v lcars_config_set_or_add_string >/dev/null 2>&1 \
         && lcars_config_set_or_add_string "$cfg" testCommand "$cmd" ); then
    echo "  ⚠ NOTE — could not write testCommand into $cfg; set it with: lcars update --test-command '$cmd'" >&2
    return 0
  fi
  emit_event foundation_promoted done \
    "test foundation PROMOTED to repo config on merge — testCommand: $cmd. Normal missions and the holodeck are unlocked for this repo."
  echo "  ◇ FOUNDATION ESTABLISHED — testCommand promoted to .git/lcars/config.json: $cmd"
  echo "    Normal missions and the holodeck are unlocked for this repo."
  return 0
}

# --- folded logged-bug children: close them out as part of the parent's ship --
#
# A Mission-Log bug child folds its fix onto the PARENT's branch and gets NO PR of
# its own (run.sh's cmd_open_pr skips it deliberately), so the ONLY thing that can
# mark it Done is the fold. Before this, the fold was reachable from exactly one
# place — accepting the parent's consolidated re-verify gate (respond.sh →
# resolve-logs complete). Merging the parent here therefore STRANDED every child:
# this block's `lcars_state_unset "$STATE" awaitingHuman/pendingQuestion` destroyed the gate that
# was the only route to the fold, `set_stage done` then put the parent outside
# resolve-logs' reach entirely (its active_table skips done missions), and approve
# itself refuses a child directly (no PR of its own). Four real bug missions sat at
# verify with their fixes already merged into main (DX-Scorecard, 2026-07-29).
#
# So the parent's merge IS the children's ship signal, and it must fold them. We
# dispatch per child to `resolve-logs complete --bug`, which:
#   • runs fold_one_child, keeping its PREMISE CHECK — the 2026-07-28 fix for the
#     opposite failure, where cards read Done while the code had vanished. A child
#     whose fix is NOT on the parent branch is REFUSED and stays at verify. Both
#     directions have to hold at once, so the check keeps its single home.
#   • is exempt from the bulk path's completeness guard (which would refuse the
#     WHOLE batch over one mid-flight sibling and re-raise a gate on a mission we
#     are about to mark done), and pushes nothing — approve already pushed+merged.
#
# STRICTLY best-effort and never fatal: the merge has already landed, so a refusal
# must not turn a shipped parent into a failed approve. It is reported LOUDLY
# instead, and a mid-flight child is named too — merging the parent leaves that
# child's fix outside the PR, which the captain needs to know.
fold_logged_children() {
  local cstate bid stage verified="" midflight="" out rc missions_dir
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    [ -f "$cstate" ] || continue
    [ "$(json_str "$cstate" parentMission)" = "$MISSION_ID" ] || continue
    [ "$(json_str "$cstate" type)" = "bug" ] || continue
    bid="$(json_str "$cstate" id)"
    [ -n "$bid" ] || bid="$(basename "$(dirname "$cstate")")"
    stage="$(json_str "$cstate" stage)"
    case "$stage" in
      verify) verified="${verified}${bid}"$'\n' ;;
      done)   : ;;
      *)      midflight="${midflight}${bid} (stage ${stage:-unknown})"$'\n' ;;
    esac
  done

  [ -n "$verified$midflight" ] || return 0   # no logged bugs — nothing to say.

  if [ -n "$verified" ] && [ ! -f "$RESOLVE_LOGS_SCRIPT" ]; then
    echo "  ⚠ logged bug(s) folded onto this Mission could not be closed out —" >&2
    echo "    resolve-logs not found at $RESOLVE_LOGS_SCRIPT. Fold them by hand." >&2
    return 0
  fi

  local folded=0 refused=""
  while IFS= read -r bid; do
    [ -n "$bid" ] || continue
    out=""; rc=0
    out="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
             bash "$RESOLVE_LOGS_SCRIPT" complete \
             --parent "$MISSION_ID" --bug "$bid" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      folded=$((folded + 1))
      echo "  Folded logged bug: $bid → done"
      # A SUCCESSFUL fold can still carry a best-effort warning (S165: the child's
      # issue was relabelled but the close did not land). `out` is otherwise
      # discarded on rc 0, so that note would die here — pass the ⚠ lines through
      # or the captain is told "folded" and never learns an issue is still open.
      # Here-string, never a pipe: approve runs under `set -o pipefail`.
      grep '⚠' <<<"$out" >&2 || true
    else
      refused="${refused}${bid}"$'\n'
      echo "  ⚠ REFUSED to close out logged bug $bid:" >&2
      printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
  done <<<"$verified"

  if [ -n "$midflight" ]; then
    echo "  ⚠ logged bug(s) still mid-flight — their fixes are NOT in this PR:" >&2
    printf '%s' "$midflight" | sed 's/^/      • /' >&2
    echo "    Drive them (\`lcars run <id>\`); they now need folding by hand," >&2
    echo "    because this Mission is done and resolve-logs only resolves an" >&2
    echo "    active parent." >&2
  fi
  [ "$folded" -gt 0 ] && echo "  Logged bugs closed out: $folded"
  return 0
}

# === S232: THE OPEN-CHILDREN GATE — PRE-MERGE, AND IT REFUSES ==============
#
# THE WEEKEND DEFECT (evidence/lcars-feedback.jsonl #6, playbook § 9 row 1).
# approve had NO pre-merge check for linked bug Missions at all. The only thing
# that ever looked at them was `fold_logged_children` above, which runs at the
# END of do_merge — AFTER `gh pr merge` has already landed — and which merely
# WARNS about a child still in flight ("their fixes are NOT in this PR"). So a
# parent Mission shipped with its logged bugs open, and the warning arrived too
# late to act on: `set_stage done` immediately afterwards puts the parent outside
# resolve-logs' reach (its active_table skips done missions), and a bug child has
# no PR of its own, so nothing could carry those fixes any more. They had to be
# re-filed by hand.
#
# So the question is asked BEFORE anything is pushed, reconciled or merged, and
# the answer is a REFUSAL. There is deliberately NO `--force`: the captain's rule
# on this is refuse, and an escape hatch on an unattended verb is the same defect
# with one extra keystroke. The remedy is one command, and the refusal names it.
#
# WHAT COUNTS AS OPEN: a sibling mission whose state.json says `parentMission` is
# this Mission and `type` is `bug`, whose stage is NOT `done`, and which carries
# NO `foldedInto` — the fold record S231's `fold_one_child` writes. Once
# `lcars resolve-logs <parent>` has folded a child, its fix IS on the branch about
# to merge and it is no obstacle. fold_logged_children stays exactly as it is for
# the already-folded ones.
#
# READ FROM `.git/lcars/missions/*/state.json`, NEVER FROM `lcars:linked` LABELS.
# The label is a board affordance that lags the truth (and against a stubbed or
# unreachable forge does not exist at all); the mission records ARE the truth, and
# they are local, so the gate cannot be defeated by a network. Same reader and
# the same loop shape as fold_logged_children — deliberately, so the two can never
# disagree about what a child is.
# S232 fix round 2 (D3): THE GATE'S OWN READER, ITS STDERR SILENCED.
# json_str is a `sed` call. On a `chmod 000` record sed writes
# `sed: …/state.json: Permission denied` to STDERR, and the captain was reading
# a tool's internal error sitting above the product's own refusal — which
# already names that exact file, so the noise carried nothing he did not have.
# This silences the READER only. The refusal and the warnings still go to stderr
# untouched, and every gate below reads through this, so what the gate can read
# stays identical to what json_str can read.
gate_json_str() { json_str "$@" 2>/dev/null; }

open_logged_children() { # → "<id>\t<title>\t<stage>" per OPEN child
  local cstate bid stage title folded missions_dir
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    [ -f "$cstate" ] && [ -r "$cstate" ] || continue
    [ "$(gate_json_str "$cstate" parentMission)" = "$MISSION_ID" ] || continue
    [ "$(gate_json_str "$cstate" type)" = "bug" ] || continue
    stage="$(gate_json_str "$cstate" stage)"
    [ "$stage" = "done" ] && continue
    folded="$(gate_json_str "$cstate" foldedInto)"
    [ -n "$folded" ] && continue
    bid="$(gate_json_str "$cstate" id)"
    [ -n "$bid" ] || bid="$(basename "$(dirname "$cstate")")"
    title="$(gate_json_str "$cstate" title)"
    printf '%s\t%s\t%s\n' "$bid" "${title:-no title}" "${stage:-unknown}"
  done
}

# === S232 fix round 1 (D1): THE UNREADABLE RECORD — THE GATE'S BLIND SPOT ===
#
# The gate above opens with ONE line per candidate:
#
#     [ "$(json_str "$cstate" parentMission)" = "$MISSION_ID" ] || continue
#
# json_str is a sed reader, not a JSON parser. A state.json that is SCRAMBLED
# (`{ not json`) or BLANK yields EMPTY for every key, so that comparison fails
# and the child was SILENTLY skipped — a record that CANNOT BE READ was
# indistinguishable from a record that says "not a child of this Mission". The
# tester damaged only the child's state.json, three ways, and got 3 of 3 MERGED
# with no refusal and no warning of any kind. That is the one shape where the new
# gate was WORSE than nothing, because it was silent.
#
# WHY WE CANNOT JUST ATTRIBUTE IT. The parent↔child link is ONE-DIRECTIONAL:
# only the CHILD's state.json records `parentMission`; lcars-log writes nothing on
# the parent side and there is no loggedChildren list anywhere. So when a record
# cannot be read, the gate genuinely cannot tell whether it was a child of this
# Mission. A second linkage record would dissolve the ambiguity and is a bigger
# change than this; the answer here is to fail closed ON THE AMBIGUITY, which is
# the house precedent (init-mission.test.sh B5 — "an unreadable mission ordering
# REFUSES the waiver"). The cost is real and accepted: one broken record blocks
# approve for every mission in that repo. It is acceptable only because the
# refusal is LOUD and names the exact file, so the remedy is obvious.
#
# READABLE means readable BY THE GATE'S OWN READER — a non-empty `id` AND a
# non-empty `stage` via json_str. Deliberately the same reader `open_logged_children`
# uses, so the two can never disagree about what a record says: anything this
# accepts, that one can read.
#
# S232 fix round 2 (D1): AND "CANNOT BE READ" NOW INCLUDES "IS NOT A FILE".
# The loop used to open with `[ -f "$cstate" ] || continue`, which is FALSE both
# for a DIRECTORY named state.json and for a DANGLING SYMLINK — so both fell
# through to the lenient "mission directory with no state.json" warning and
# MERGED, and `mkdir .git/lcars/missions/<child>/state.json` was a deliberate
# bypass of this whole gate. That branch's rationale ("a mission directory exists
# before its state.json is written, so an interrupted filing leaves one") is
# simply false for both shapes: no interrupted filing produces either. `[ -e ]`
# and `[ -L ]` distinguish "something is there" from "nothing is there", so the
# rule the refusal already states — an unreadable record cannot be attributed
# either way — now covers every way a path can be there and unopenable. Only a
# GENUINELY ABSENT path keeps the lenient warning.
unreadable_mission_records() { # → one state.json path per record that cannot be read
  local cstate missions_dir
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    # Nothing there at all — that is stateless_mission_dirs' lenient case, not
    # this one. `-L` is asked separately because `-e` is FALSE for a dangling
    # symlink, and a dangling symlink is very much "something is there".
    [ -e "$cstate" ] || [ -L "$cstate" ] || continue
    # Something IS there but cannot be opened and read as a regular file: a
    # directory, a dangling symlink, a chmod 000 record. Unattributable.
    if [ ! -f "$cstate" ] || [ ! -r "$cstate" ]; then
      printf '%s\n' "$cstate"; continue
    fi
    [ -n "$(gate_json_str "$cstate" id)" ] && [ -n "$(gate_json_str "$cstate" stage)" ] && continue
    printf '%s\n' "$cstate"
  done
}

# === S232 fix round 2 (D2): THE RECORD THAT LOST ONLY ITS PARENT LINK ========
#
# The second way a record is unattributable, and it was silent too. Take the
# record `lcars log` writes and remove ONLY `parentMission` / `parentIssue` /
# `origin`: still valid JSON, `id` and `stage` intact, so unreadable_mission_records
# accepts it — and with no `parentMission` it just fails open_logged_children's
# child test and is skipped. Nothing in the repo can attribute it, which is the
# exact condition the refusal above exists for, and the captain was told nothing.
#
# THE DISCRIMINATOR. A record whose `type` is `bug` MUST have a parent to be a
# logged bug: log.sh REQUIRES `**Type:** bug` (it dies otherwise) and always
# writes `parentMission` beside it. An ordinary mission legitimately has no
# parent, so `type: bug` is what keeps this from firing on every standalone
# mission in the repo. `stage = done` is excluded: a finished mission's fix is
# not owed to this PR, and that exclusion is what stops a repo full of old
# finished missions wedging approve months later.
#
# WHY A WARNING AND NOT A REFUSAL. `lcars file` ALSO accepts `**Type:** bug`
# (`case "$TYPE" in feature|bug)`) and writes NO `parentMission`, so a bug
# Mission filed standalone is a LEGITIMATE record of exactly this shape. A
# refusal would therefore block the one irreversible verb on a perfectly healthy
# repo — the cost we refuse to pay elsewhere in this gate. So this shape takes
# the same treatment the absent-record shape takes: named out loud, once,
# pre-merge, with what it means — never silent again, never a brick.
orphan_bug_records() { # → "<id>\t<title>\t<stage>" per bug record with NO parent link
  local cstate missions_dir stage bid title
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    [ -f "$cstate" ] && [ -r "$cstate" ] || continue
    # Never the Mission being approved: a standalone bug Mission IS its own
    # record, and reporting it to itself is noise, not information.
    [ "$cstate" = "$MISSION_DIR/state.json" ] && continue
    [ "$(gate_json_str "$cstate" type)" = "bug" ] || continue
    [ -n "$(gate_json_str "$cstate" parentMission)" ] && continue
    stage="$(gate_json_str "$cstate" stage)"
    [ "$stage" = "done" ] && continue
    bid="$(gate_json_str "$cstate" id)"
    [ -n "$bid" ] || bid="$(basename "$(dirname "$cstate")")"
    title="$(gate_json_str "$cstate" title)"
    printf '%s\t%s\t%s\n' "$bid" "${title:-no title}" "${stage:-unknown}"
  done
}

# THE OTHER SHAPE, AND WHY IT IS *NOT* A REFUSAL.
#
# A mission DIRECTORY with no state.json at all is NOT treated as an obstacle,
# and that is a decision, not an oversight:
#   • it is a real transient. A mission directory is `mkdir`ed well BEFORE its
#     state.json is written (lcars-log/log.sh, and the same order in
#     lcars-file/file.sh), so an interrupted filing — or a partial `.git/lcars`
#     restore, the very route this defect describes — leaves one behind.
#   • it is invisible to EVERY other LCARS surface. status, respond, resolve-logs
#     and fold_logged_children all glob `*/state.json`, so no other verb thinks
#     that mission exists. Blocking approve alone would brick the one irreversible
#     verb over a record nothing else counts.
#   • there is nothing to name but the path: no id, no title, no stage, so a
#     refusal could not carry the four things the open-children refusal carries.
# But it is never SILENT again: it is WARNED about, by name, pre-merge. The
# tester's bar was "refuse, or at minimum say something"; for the unambiguously
# broken shape we refuse, and for the ambiguous one we say something.
stateless_mission_dirs() { # → one mission dir path per dir with NO state.json
  local mdir missions_dir
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for mdir in "$missions_dir"/*/; do
    [ -d "$mdir" ] || continue
    mdir="${mdir%/}"
    # S232 fix round 2 (D1): GENUINELY ABSENT only. `-f` alone also let a
    # DIRECTORY named state.json and a DANGLING SYMLINK land in this lenient
    # branch, whose stated rationale (an interrupted filing) cannot produce
    # either. Anything that EXISTS there is unreadable_mission_records' problem.
    if [ -e "$mdir/state.json" ] || [ -L "$mdir/state.json" ]; then continue; fi
    printf '%s\n' "$mdir"
  done
}

# ONE plain paragraph, every child named (id, title, stage), one command that
# clears it, exit non-zero. Nothing merged, nothing reconciled, no label moved,
# no stage changed.
#
# S232 fix round 1 (D1): the unreadable-record branch comes FIRST and is its own
# paragraph. The open-children paragraph below is untouched — it keeps its four
# virtues (names the bug by title, its stage, the irreversibility, and ends
# "Nothing has been merged.").
refuse_if_open_logged_children() {
  local open bid title stage broken stateless rec
  broken="$(unreadable_mission_records)"
  if [ -n "$broken" ]; then
    {
      # S232 fix round 2 (D4): the old sentence ASSERTED whose record it was
      # ("cannot tell whether it is a logged bug of X") about a mission that may
      # never have had a logged bug in its life; the file path rescued him but
      # the sentence pointed the wrong way. This one RULES OUT instead, which is
      # all the gate actually knows. The paragraph's four virtues are unchanged:
      # it names the exact file(s), explains the irreversibility, gives the
      # remedy, and ends "Nothing has been merged." — plus one kindness, since
      # he is being told to "remove" a JSON file he has never opened.
      printf 'APPROVE: refused — a mission record in this repo cannot be read, so LCARS cannot rule out that it is a logged bug of %s still in flight. Only a child records its parent, so an unreadable record cannot be attributed either way, and merging is irreversible: once this Mission is Done its bugs cannot be folded onto it at all. Cannot be read:\n' \
        "$MISSION_ID"
      while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        printf '      • %s\n' "$rec"
      done <<<"$broken"
      printf 'Repair or remove each record above, then approve again. If one was a logged bug you no longer need, deleting its whole mission directory is safe — nothing else in LCARS refers to it. Nothing has been merged.\n'
    } >&2
    emit_event approve_refused verify \
      "refused to merge — unreadable mission record(s): $(printf '%s' "$broken" | tr '\n' ' ')"
    exit 1
  fi

  # Not an obstacle (see stateless_mission_dirs) — but said out loud, once. Both
  # call sites ask this gate, so STATELESS_WARNED is deliberately NOT local: it is
  # the once-flag that keeps the captain from reading the same warning twice and
  # concluding there are two broken directories.
  if [ -z "${STATELESS_WARNED:-}" ]; then
    stateless="$(stateless_mission_dirs)"
    if [ -n "$stateless" ]; then
      STATELESS_WARNED=1
      {
        printf '  ⚠ mission directory with no state.json — not blocking, but unattributable:\n'
        while IFS= read -r rec; do
          [ -n "$rec" ] || continue
          printf '      • %s\n' "$rec"
        done <<<"$stateless"
        printf '    A mission directory exists before its state.json is written, so an\n'
        printf '    interrupted filing leaves one, and no LCARS surface can see it. If one of\n'
        printf '    these WAS a logged bug of this Mission, its fix is NOT in this PR.\n'
      } >&2
    fi
  fi

  # S232 fix round 2 (D2): the other unattributable shape — a `type: bug` record
  # with NO parent link and not yet done. Warned, not refused (see
  # orphan_bug_records for why), and warned ONCE across both call sites, which is
  # why ORPHAN_WARNED is deliberately NOT local — same once-flag shape as
  # STATELESS_WARNED above, for the same reason.
  if [ -z "${ORPHAN_WARNED:-}" ]; then
    local orphans obid otitle ostage
    orphans="$(orphan_bug_records)"
    if [ -n "$orphans" ]; then
      ORPHAN_WARNED=1
      {
        printf '  ⚠ bug mission with no parent link — not blocking, but unattributable:\n'
        while IFS=$'\t' read -r obid otitle ostage; do
          [ -n "$obid" ] || continue
          printf '      • %s  %s  (stage %s)\n' "$obid" "$otitle" "$ostage"
        done <<<"$orphans"
        printf '    A logged bug always records the Mission it was logged against; this\n'
        printf '    record does not, so nothing can attribute it. If it WAS a logged bug of\n'
        printf '    this Mission, its fix is NOT in this PR. (A bug Mission you filed on its\n'
        printf '    own with `lcars file` reads this way too, and is fine.)\n'
      } >&2
    fi
  fi

  open="$(open_logged_children)"
  [ -n "$open" ] || return 0
  {
    printf 'APPROVE: refused — %s has logged bug(s) still open, and merging now would ship it with their fixes left outside the PR. Once this Mission is Done its bugs cannot be folded onto it at all (a logged bug has no PR of its own, and resolve-logs only resolves an ACTIVE parent), so they would have to be re-filed by hand. Still open:\n' \
      "$MISSION_ID"
    while IFS=$'\t' read -r bid title stage; do
      [ -n "$bid" ] || continue
      printf '      • %s  %s  (stage %s)\n' "$bid" "$title" "$stage"
    done <<<"$open"
    printf 'Take them the rest of the way first:  lcars resolve-logs %s\n' "$MISSION_ID"
    printf 'Then approve again. Nothing has been merged.\n'
  } >&2
  emit_event approve_refused verify \
    "refused to merge — logged bug(s) still open: $(printf '%s' "$open" | awk -F'\t' '{printf "%s (stage %s) ", $1, $3}')"
  exit 1
}

# --- gh relabel: best-effort, never blocks the local stage change ----------
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2"
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."; return 0 ;;
  esac
  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    host issue-relabel "$issue" --add "$add" --remove "$rem" \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand ($hand)."
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: $hand)."
  fi
}

# The shared PR-open/builders library (title/body/manifest/open_pr). approve
# no longer OPENS a PR (Verify does), but sources the lib so a captain who runs
# approve on a verify mission with NO PR yet gets a graceful, consistent message
# rather than a crash — and so the lib has one home both surfaces share.
# shellcheck source=skills/lcars-approve/pr-lib.sh
. "$SELF_DIR/pr-lib.sh"

# --- args ------------------------------------------------------------------
# --reapprove (or LCARS_REAPPROVE=1, the flag the web layer invokes) runs ONLY
# the merge step on an ALREADY-reconciled, already-green branch — the human's
# sign-off after a self-heal converged (reconcileStatus=awaiting-reapprove). It
# skips the reconcile/self-heal engine entirely and goes straight to the
# push-then-merge path, with the push result CAPTURED (BUG-066) so a rejected
# push surfaces as merge-failed instead of a silent revert.
MISSION_ID=""
REAPPROVE="${LCARS_REAPPROVE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)   MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*) MISSION_ID="${1#--mission=}"; shift ;;
    --reapprove) REAPPROVE=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done
[ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>."

locate_mission "$MISSION_ID"
require_stage verify

# S189: the light lock. Checked BEFORE the merge gate does any work —
# reconcile, push, `gh pr merge` — so a mission that is not ours is never
# half-shipped before the refusal lands.
owner_lock_or_die "$(json_raw "$STATE" githubIssue)"
xo_lock_or_die "$MISSION_DIR"

BRANCH="$(json_str "$STATE" branch)"
BASE="$(json_str "$STATE" base)"; BASE="${BASE:-main}"

# --- the open PR approve is here to MERGE ------------------------------------
# Verify auto-opens the PR and records prUrl/prNumber. approve REQUIRES that PR
# to merge. With no recorded PR, the Mission was not driven through the new
# Verify auto-open (e.g. an old mission) — refuse, staying at verify, with an
# actionable message. We never silently open-and-merge in one shot.
PR_URL="$(json_str "$STATE" prUrl)"
PR_NUM="$(json_raw "$STATE" prNumber)"
case "$PR_URL" in
  http*|*/pull/*) : ;;
  *)
    if origin_guidance="$(pr_origin_guidance)"; then
      die "no open PR recorded for this mission — $origin_guidance"
    fi
    die "no open PR recorded for this mission — run \`lcars run $MISSION_ID\` so Verify opens the PR, then approve to merge it. Mission stays at verify." ;;
esac

# --- the merge step (shared by the normal flow + the reapprove flow) ---------
# Push the (possibly reconciled) branch to origin with its result CAPTURED
# (BUG-066), then `gh pr merge`. On a clean push → merge → Done. On a push that
# was REJECTED (non-fast-forward / diverged) we do NOT proceed to merge: we set
# reconcileStatus=merge-failed with the real reason and KEEP awaitingHuman so the
# gate stays visible — never a silent revert. A benign push miss (no remote / not
# configured, the test-repo case) is distinguished from a real rejection and is
# allowed to fall through to gh pr merge (the real gate). On a gh-pr-merge failure
# we likewise surface the real reason via reconcileStatus=merge-failed.
do_merge() {
  # S232 — THE OPEN-CHILDREN GATE, first and unconditionally. do_merge is the ONE
  # door every merge goes through (the normal flow and `--reapprove` both end
  # here), so asking here means no merge path can escape it. The reconcile
  # pre-step below the reapprove block also asks, so a mission that cannot merge
  # never cuts a reconcile worktree either; the gate exits, so the second ask is
  # only ever reached on the reapprove path.
  refuse_if_open_logged_children
  command -v "$GH_BIN" >/dev/null 2>&1 \
    || die "gh not found — cannot merge PR $PR_URL. Mission stays at verify (merge it by hand)."

  # Push the branch so the remote PR head reflects any reconciled/healed tree.
  # Capture stderr + exit code; classify rejection (must block) vs benign miss.
  if [ -n "$BRANCH" ] && command -v "$GIT_BIN" >/dev/null 2>&1; then
    local push_out push_rc=0
    push_out="$("$GIT_BIN" push origin "$BRANCH" 2>&1)" || push_rc=$?
    # push_rc == 0 is SUCCESS — and that INCLUDES the up-to-date no-op. After
    # S89's push-on-accept (resolve-logs complete --parent pushes the parent
    # branch), the open PR head already equals the local tip, so this final push
    # is a clean fast-forward / "Everything up-to-date" and git returns 0. We fall
    # straight through to `gh pr merge` below. ONLY a non-zero push (rc != 0 —
    # non-fast-forward / diverged / benign-miss) enters the classification block;
    # the force-with-lease + staleness guards below run on rejection alone and are
    # never reached by an up-to-date no-op. (See tests: utd. / nff.)
    if [ "$push_rc" -ne 0 ]; then
      case "$push_out" in
        *'[rejected]'*|*'non-fast-forward'*|*'! [remote rejected]'*|*'fetch first'*|*'tip of your current branch is behind'*)
          # A non-fast-forward push: the remote PR head diverged from our local
          # branch. BUG-077: a reconcile that was killed/parked and retried leaves
          # the local mission branch at the dead attempt's merge commit, so the
          # retry's reconciled tip DIVERGES from the last-pushed remote PR head.
          # When the local branch tip IS the freshly-reconciled green tip
          # (reconcileMergeSha) AND it already CONTAINS current origin/main, the
          # local IS the authoritative resolution → auto-recover with a
          # --force-with-lease push and proceed to merge. STALENESS GUARD
          # (BUG-075): if origin/main advanced PAST the heal (local no longer
          # contains it) we must NOT force over a remote that legitimately moved —
          # surface merge-failed asking the captain to re-reconcile. And a local
          # tip that is not the known green reconcileMergeSha is never forced.
          local sha local_tip recovered=0
          sha="$(json_str "$STATE" reconcileMergeSha)"
          local_tip="$("$GIT_BIN" rev-parse "$BRANCH" 2>/dev/null)"
          if [ -n "$sha" ] && [ "$local_tip" = "$sha" ]; then
            # Refresh remote-tracking refs, then check the local branch still
            # contains current origin/$BASE (the heal incorporates current main).
            "$GIT_BIN" fetch origin "$BASE" >/dev/null 2>&1 || true
            if "$GIT_BIN" merge-base --is-ancestor "origin/$BASE" "$BRANCH" >/dev/null 2>&1; then
              # Authoritative + still on top of current main → force-with-lease.
              if "$GIT_BIN" push --force-with-lease origin "$BRANCH" >/dev/null 2>&1; then
                recovered=1
              else
                local fnote="Could not force-update the PR branch (\`git push --force-with-lease origin $BRANCH\`) — the remote lease was stale (someone else pushed). Re-run the reconcile, then reapprove."
                lcars_state_set_string "$STATE" reconcileStatus "merge-failed"
                lcars_state_set_string "$STATE" reconcileNote "$fnote"
                lcars_state_set "$STATE" awaitingHuman true
                lcars_state_set_string "$STATE" pendingQuestion "$fnote"
                die "$fnote Mission stays at verify."
              fi
            else
              # STALENESS GUARD: main moved past the heal → never force.
              local mnote="main moved since the heal — re-reconcile required. origin/$BASE advanced past the reconciled tip ($sha); the heal no longer incorporates current main. Re-run \`lcars approve $MISSION_ID\` to reconcile against the new base, then reapprove."
              lcars_state_set_string "$STATE" reconcileStatus "merge-failed"
              lcars_state_set_string "$STATE" reconcileNote "$mnote"
              lcars_state_set "$STATE" awaitingHuman true
              lcars_state_set_string "$STATE" pendingQuestion "$mnote"
              die "$mnote Mission stays at verify."
            fi
          fi
          if [ "$recovered" -ne 1 ]; then
            # Not the authoritative tip (or no recorded green tip) — do NOT force;
            # surface the divergence for the captain to resolve, as before.
            local note="Could not update the PR branch: non-fast-forward (the remote PR branch diverged) and the local tip is not the recorded reconciled green tip. The heal is green at ${sha:-the reconciled tip} — re-run the reconcile (\`lcars approve $MISSION_ID\`) or push manually (\`git push --force-with-lease origin $BRANCH\`), then reapprove."
            lcars_state_set_string "$STATE" reconcileStatus "merge-failed"
            lcars_state_set_string "$STATE" reconcileNote "$note"
            lcars_state_set "$STATE" awaitingHuman true
            lcars_state_set_string "$STATE" pendingQuestion "$note"
            die "$note Mission stays at verify."
          fi
          # recovered: fall through to gh pr merge below.
          ;;
        *'does not appear to be a git repository'*|*'No configured push destination'*|*'No such remote'*|*'Could not read from remote'*|*'Authentication failed'*|*'Permission denied'*|*'could not read Username'*)
          # Benign in a test/local repo (no remote / no auth): the PR branch is
          # the local branch. Fall through to gh pr merge — the real gate.
          : ;;
        *)
          # Unknown push failure — fall through to gh pr merge, which is the
          # authoritative gate and will fail loudly if the branch is stale.
          : ;;
      esac
    fi
  fi

  # A merge selector: prefer the recorded PR number, else the branch.
  local MERGE_ARGS=()
  case "$PR_NUM" in
    ''|null) MERGE_ARGS=(--head "$BRANCH") ;;
    *)       MERGE_ARGS=(--number "$PR_NUM") ;;
  esac

  # BUG-069: right after a push GitHub needs a few seconds to RECOMPUTE the PR's
  # mergeability, so the FIRST `gh pr merge` can spuriously fail with a transient
  # "not mergeable yet" even though nothing is wrong. RETRY the merge with a
  # short bounded backoff before falling into the merge-failed path. A real
  # CONFLICTING/DIRTY state simply keeps failing and surfaces after the retries
  # exhaust — we never paper over a true conflict, only ride out the post-push
  # lag. Tunable via env so the test drives it with zero real sleep.
  local merge_tries="${LCARS_MERGE_RETRIES:-6}"        # up to ~6 attempts …
  local merge_sleep="${LCARS_MERGE_RETRY_SLEEP:-5}"    # … ~5s apart (~30s total)
  local attempt=1 merged_ok=0
  while [ "$attempt" -le "$merge_tries" ]; do
    if host pr-merge "${MERGE_ARGS[@]}"; then
      merged_ok=1; break
    fi
    # The attempt failed. It may be the post-push lag (retry) or a real conflict
    # (will keep failing). If the PR has ALREADY merged out from under us (a
    # prior attempt that reported failure but actually landed), treat as success.
    if host pr-view "${MERGE_ARGS[@]}" 2>/dev/null | grep -qi $'state\tMERGED'; then
      merged_ok=1; break
    fi
    if [ "$attempt" -lt "$merge_tries" ]; then
      [ "$merge_sleep" = "0" ] || sleep "$merge_sleep"
    fi
    attempt=$((attempt + 1))
  done

  if [ "$merged_ok" -ne 1 ]; then
    local note="gh pr merge failed for $PR_URL after $merge_tries attempt(s) — resolve it (conflicts/checks/auth) and re-run \`lcars approve $MISSION_ID\` (or \`--reapprove\`), or merge on GitHub. Mission stays at verify."
    lcars_state_set_string "$STATE" reconcileStatus "merge-failed"
    lcars_state_set_string "$STATE" reconcileNote "$note"
    lcars_state_set "$STATE" awaitingHuman true
    lcars_state_set_string "$STATE" pendingQuestion "$note"
    die "$note"
  fi

  # Merge landed. Close out any logged-bug children FIRST — while this Mission is
  # still at verify with its consolidated gate intact, because resolve-logs can
  # only resolve an ACTIVE parent (its active_table skips done). Once set_stage
  # below runs, the fold is unreachable forever.
  fold_logged_children

  # S185: the merge landed, so an INITIALIZATION mission's established runner is
  # now a fact about the REPO — promote it to repo config (see
  # promote_test_command). No-op for every normal mission.
  promote_test_command

  # Then clear the reconcile gate state and flip the Mission to Done.
  lcars_state_unset "$STATE" reconcileStatus
  lcars_state_unset "$STATE" reconcileNote
  lcars_state_unset "$STATE" reconcileMergeSha
  lcars_state_unset "$STATE" awaitingHuman
  lcars_state_unset "$STATE" pendingQuestion
  gh_relabel "lcars:done" "lcars:verify lcars:awaiting-human"
  set_stage "done"
  lcars_state_set_string "$STATE" review "merged"
  . "$SELF_DIR/../lcars-xo/release-stop.sh" \
    && lcars_xo_release_completed_stop "$MISSION_DIR" \
    || die "PR merged, but Number One's stop could not be released; check $MISSION_DIR/xo-stop."

  # BUG-071: record the ship on the mission timeline so the card shows the
  # `merged` milestone (and a terminal `mission_done`), not just stdout.
  emit_event merged verify "PR merged — $PR_URL"
  emit_event mission_done done "Mission shipped — the PR is merged"

  # S207 fix round 1 (D2): the state writer now REFUSES a state.json it will
  # not touch, and returns non-zero. Ask before announcing anything — a verb
  # that prints success over a refused write is the `lcars pause` lie the
  # captain ruled on.
  lcars_state_refusal_die "lcars approve"
  echo "APPROVE: merged — $(pr_title)"
  echo "  Merged PR: $PR_URL"
  echo "  Branch:    $BRANCH → $BASE"
  echo "  Stage:     done"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- REAPPROVE: merge-only on an already-reconciled-green branch -------------
# The web/inbox layer (or `lcars approve --reapprove`) invokes this AFTER the
# captain has signed off on a self-heal that converged green (state set by the
# reconcile gate: reconcileStatus=awaiting-reapprove). Skip the reconcile engine
# entirely and run ONLY the merge step.
if [ -n "$REAPPROVE" ]; then
  rstat="$(json_str "$STATE" reconcileStatus)"
  case "$rstat" in
    awaiting-reapprove|merge-failed) : ;;  # the expected gate to clear.
    *) : ;;  # tolerate a reapprove with no recorded gate — still just merges.
  esac
  emit_event reapprove verify "captain reapproved a converged self-heal — merging $PR_URL"
  do_merge
fi

# --- S232: the open-children gate, BEFORE the reconcile pre-step -------------
# do_merge asks too (it is the door every merge goes through), but the reconcile
# engine below cuts a worktree, merges the base in and re-runs suites, and none of
# that should happen for a Mission that is not allowed to merge. Ask here so the
# refusal costs nothing and leaves nothing behind.
refuse_if_open_logged_children

# --- self-heal-before-escalate: reconcile a possibly-behind base FIRST -------
# Before merging, run the S76 reconcile/self-heal engine (the sibling run.sh
# `reconcile` subcommand) so a PR that fell behind a moved base is merged into
# the mission branch, re-tested, and self-healed to green — instead of letting
# `gh pr merge` hit a conflict and escalate. It is a cheap no-op (exit 0) when
# the base is not ahead. Pin the mission engine so a copilot mission heals on
# copilot (a CLAUDECODE-tagged env would otherwise host-detect claude).
#
# AND SAY WHOSE PIN IT IS. $LCARS_WORKER_BIN is also how the CAPTAIN moves a
# mission onto another engine on purpose, and run.sh's resolver records which
# rule won as the mission's engine PROVENANCE (state.json `engineSource`, the
# card's `copilot · chosen at adopt` line). It could not tell the two apart, so
# this pin — LCARS re-asserting the mission's OWN engine — was recorded as `env`
# and DESTROYED the more specific truth underneath it: the engine the captain
# chose at the adopt prompt, or the mission's own `--engine` pin. Measured three
# times in one day of live runs (tests/drives/s196-capstone/): the card read
# `copilot · chosen at adopt` before approve and `copilot · $LCARS_WORKER_BIN`
# after, and approve's own log line said `worker: copilot (bin: env)` while the
# mission sat there pinned to copilot.
#
# So the pin STATES what it is rather than leaving the far end to guess:
# $LCARS_WORKER_BIN_INTERNAL=1 says "LCARS set this, re-asserting this mission's
# engine". The resolver then takes the value but not the credit — the mission's
# own record wins the source, exactly as it would have with no pin at all. The
# producer records; nothing downstream infers internality by comparing the value
# to `workerBin` (the inference S147/S156/S188 each paid a fix round for, and
# which would mis-silence a captain who re-asserts the same engine by hand).
engine="$(json_str "$STATE" workerBin)"
rcode=0
# The mission engine is plumbed via the environment (an assignment prefix built
# by expansion is parsed as a command, not a var — export into the subshell).
( export LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN"
  [ -n "$engine" ] && export LCARS_WORKER_BIN="$engine" LCARS_WORKER_BIN_INTERNAL=1
  bash "$RUN_SCRIPT" reconcile --mission "$MISSION_ID" ) || rcode=$?
case "$rcode" in
  0)  : ;;  # up to date (base not ahead) → proceed to merge directly below.
  10) echo "APPROVE: reconciling with the updated base — self-heal in flight. Mission stays at verify; re-run \`lcars approve $MISSION_ID\` once it's green."; exit 0 ;;
  20) echo "APPROVE: the base moved ahead and the self-heal was escalated to you (awaiting your answer). Mission stays at verify."; exit 0 ;;
  30) # BUG-067: the self-heal CONVERGED GREEN — do NOT auto-merge. The reconcile
      # gate persisted reconcileStatus=awaiting-reapprove + reconcileNote and
      # raised the awaiting-human gate. STOP here; the captain reapproves to merge.
      note="$(json_str "$STATE" reconcileNote)"
      echo "APPROVE: ${note:-the base moved ahead and the self-heal converged green.} Mission stays at verify awaiting your reapprove — run \`lcars approve $MISSION_ID --reapprove\` (or reapprove from the board) to merge."
      exit 0 ;;
  *)  echo "lcars approve: reconcile failed (rc=$rcode). Mission stays at verify." >&2; exit 1 ;;
esac

# --- merge — only a SUCCESSFUL merge flips the Mission to Done ----------------
# base not ahead (rc=0): the recorded PR is already up to date — merge directly.
do_merge
