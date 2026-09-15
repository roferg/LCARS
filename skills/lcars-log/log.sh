#!/usr/bin/env bash
#
# lcars log — fast-track a Mission per logged bug and link each to a parent.
#
# This is the mechanical half of `lcars log`. The conversational half is driven
# by Claude per SKILL.md: it reads the captain's free-form report, splits it into
# N distinct bugs, writes one well-formed bug PRD per bug to a temp file, and
# resolves which active parent Mission they belong to. This script takes those
# PRDs + the parent selector and, for each bug:
#   1. mints a mission ID            lcars-YYYYMMDD-NNN (NNN per-day sequence)
#   2. creates .git/lcars/missions/<id>/ with prd.md + state.json
#   3. gives the Mission its own branch lcars/<id> (off the current branch)
#   4. opens a GitHub issue labelled lcars:align + lcars:bug + lcars:linked + lcars:mission
#   5. links it to the parent (parentMission/parentIssue in state.json + label)
# then prints one aggregate summary.
#
# Bugs SKIP Align (no re-grill — the captain's report stays casual), but they now
# ENTER the pipeline at **Research** in a grounding-only mode and walk the FULL
# pipeline (Research → Validate → Plan → … → Verify). So the child seeds
# stage="align" (the drive maps align + no feedback.md → Research) plus an explicit
# origin="log" flag that Research keys grounding-mode on. Research anchors the
# symptom to the EXISTING code (reading the PARENT Mission's PRD/plan + the
# delivered code), and Validate then writes the real validated-plan.md — so we no
# longer hand-write a thin one here. This exists because a fast-tracked bug once
# built a parallel decoy fix instead of modifying the real feature.
#
# Dependencies are taken via env so they can be stubbed in tests:
#   LCARS_GH_BIN   the gh binary       (default: gh)
#   LCARS_GIT_BIN  the git binary      (default: git)
#   LCARS_DATE     YYYYMMDD for the ID (default: today, UTC)
#   LCARS_NOW      ISO created stamp   (default: now, UTC)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
DATE="${LCARS_DATE:-$(date -u +%Y%m%d)}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
# The lcars-run driver that owns the dynamic estimator (sessions 58–64). A logged
# bug is just a Mission whose estimate is computed from its bug PRD, so it must
# get the SAME estimator scoring a top-level Mission gets — we REUSE run.sh's
# `estimate` entry point exactly the way file.sh does at the end of Align. Default
# matches how SKILL.md invokes the other run.sh subcommands; overridable so tests
# can point it at the real run.sh with a stubbed cold worker. STRICTLY OPTIONAL:
# the estimator NEVER blocks the log (see run_child_estimate below).
RUN_BIN="${LCARS_RUN_BIN:-$HOME/.claude/skills/lcars-run/run.sh}"

# The host-integration adapter — the ONE place that speaks to a forge. We reuse
# the SAME adapter Schedule uses to NATIVELY nest sub-issues, so a logged bug
# nests under its parent the way a ticket nests under its Mission. It lives in
# skills/lcars-run/ (not here), so default to it relative to this script's own
# dir (computed the way run.sh computes SKILL_DIR); $LCARS_HOST_ADAPTER overrides
# it so tests can stub the whole adapter.
SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SKILL_DIR/../lcars-run/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

# --- shared helpers: the attachment wording (S128 / FL-010) -----------------
# A logged bug's prd.md is its GitHub issue body, and a bug filed against a
# holodeck-born Mission can carry the very `mockup.html` the parent was built
# from — since S174 it INHERITS it (see file_one_bug). The heading over that
# list is NOT spelled here — it comes from the one
# shared rule in lcars-common.sh that `lcars file` and the cold-Stage prompt
# block also derive from, so an HTML mockup is never called an image on any
# surface. Sourced the same way `lcars file` sources it.
LCARS_COMMON_LIB="${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
if [ -f "$LCARS_COMMON_LIB" ]; then
  # shellcheck source=../lcars-init/lcars-common.sh
  . "$LCARS_COMMON_LIB"
fi

# S196 — the mission-id minter and the clone fingerprint live in lcars-common.sh
# (sourced best-effort above). Define the DEGRADED forms when the lib is absent:
# the PRE-S196 id shape — no fingerprint — but with S196's tolerant sequence
# scan, so a clone that already holds fingerprinted missions cannot die on
# `$((10#a3f4))` just because the library went missing.
if ! command -v lcars_mint_mission_id >/dev/null 2>&1; then
  lcars_clone_fingerprint() { printf ''; }
  lcars_mint_mission_id() {
    local mdir="$1" date="$2" fp="${3:-}" max=0 d n
    shopt -s nullglob
    for d in "$mdir"/lcars-"$date"-*; do
      n="${d##*/}"; n="${n#lcars-$date-}"; n="${n%%-*}"
      case "$n" in ''|*[!0-9]*) continue ;; esac
      n=$((10#$n)); [ "$n" -gt "$max" ] && max="$n"
    done
    shopt -u nullglob
    if [ -n "$fp" ]; then printf 'lcars-%s-%03d-%s' "$date" "$((max + 1))" "$fp"
    else                  printf 'lcars-%s-%03d'    "$date" "$((max + 1))"
    fi
  }
fi

# --- shared helpers: the ONE issue-body composer (S188) --------------------
# `lcars log` is the FIFTH filing lane. It files a Mission (lcars:mission) like
# any other, so its issue body must carry the same machine-readable
# `lcars:handoff` envelope a second laptop reads — without it, `lcars adopt`
# finds nothing on a logged-bug issue. It lives beside the host adapter in the
# sibling lcars-run skill dir, the same reach HOST_ADAPTER already makes.
# $LCARS_ISSUE_BODY_LIB overrides the path for tests.
LCARS_ISSUE_BODY_LIB="${LCARS_ISSUE_BODY_LIB:-$SKILL_DIR/../lcars-run/issue-body.sh}"
if [ -f "$LCARS_ISSUE_BODY_LIB" ]; then
  # shellcheck source=../lcars-run/issue-body.sh
  . "$LCARS_ISSUE_BODY_LIB"
fi

die() { printf 'lcars log: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same decoding as resolve.sh / status.sh) -----
json_str() { # file key -> first "key": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key -> first bare token (number/bool/null)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- args -----------------------------------------------------------------
# PRDS[i] is the i-th bug's PRD path; OVERRIDES[i] is its OPTIONAL captain model
# override ("<scope>:<tier>", same format as `lcars file --model-override` and the
# Launch panel). A `--model-override` applies to the MOST RECENT `--prd` so the
# Mission-Log review panel can steer each bug independently (positional pairing).
PARENT_SEL=""
PRDS=()
OVERRIDES=()
# Durable image attachments (S92 + per-bug routing). The captain's pasted
# screenshots are copied into a child bug's attachments/ dir, referenced by
# RELATIVE path in that bug's prd.md, and recorded in its state.json. `--attach`
# is now POSITIONAL (mirroring --model-override):
#   • seen BEFORE any --prd  → GLOBAL_ATTACH: applies to EVERY bug (this is the
#     legacy all-images-to-all-bugs behaviour, unchanged when only globals pass).
#   • seen AFTER a --prd      → PER_BUG_ATTACH[i]: applies to that ONE bug only,
#     paired positionally with the most recent --prd (parallel to OVERRIDES).
# A bug's final attachment set is GLOBAL_ATTACH ∪ its own PER_BUG_ATTACH (deduped
# by source path). PER_BUG_ATTACH entries are newline-delimited path lists (bash
# arrays can't nest); the staged temp paths carry no newlines.
GLOBAL_ATTACH=()
PER_BUG_ATTACH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)   PARENT_SEL="${2:-}"; shift 2 ;;
    --parent=*) PARENT_SEL="${1#--parent=}"; shift ;;
    --attach|--attach=*)
      av=""
      case "$1" in
        --attach) av="${2:-}"; shift 2 ;;
        *)        av="${1#--attach=}"; shift ;;
      esac
      if [ "${#PRDS[@]}" -eq 0 ]; then
        GLOBAL_ATTACH+=("$av")
      else
        pbi=$(( ${#PRDS[@]} - 1 ))
        if [ -n "${PER_BUG_ATTACH[$pbi]:-}" ]; then
          PER_BUG_ATTACH[$pbi]="${PER_BUG_ATTACH[$pbi]}"$'\n'"$av"
        else
          PER_BUG_ATTACH[$pbi]="$av"
        fi
      fi
      ;;
    --prd)      PRDS+=("${2:-}"); OVERRIDES+=(""); PER_BUG_ATTACH+=(""); shift 2 ;;
    --prd=*)    PRDS+=("${1#--prd=}"); OVERRIDES+=(""); PER_BUG_ATTACH+=(""); shift ;;
    --model-override|--model-override=*)
      mo=""
      case "$1" in
        --model-override) mo="${2:-}"; shift 2 ;;
        *)                mo="${1#--model-override=}"; shift ;;
      esac
      [ "${#PRDS[@]}" -gt 0 ] \
        || die "--model-override must follow a --prd it applies to."
      OVERRIDES[$(( ${#PRDS[@]} - 1 ))]="$mo"
      ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ "${#PRDS[@]}" -gt 0 ] || die "no bug PRDs given — pass --prd <path> (once per bug)."
for p in "${PRDS[@]}"; do
  [ -f "$p" ] || die "bug PRD file not found: $p"
done

# Attachments are optional, but if given each must point at a real file — checked
# BEFORE anything is filed so a bad --attach stops with nothing partial (S92).
# Both the global and the per-bug attaches are validated here.
validate_attach() { # path
  [ -n "$1" ] || die "empty --attach path given."
  [ -f "$1" ] || die "attachment file not found: $1"
}
if [ "${#GLOBAL_ATTACH[@]}" -gt 0 ]; then
  for a in "${GLOBAL_ATTACH[@]}"; do validate_attach "$a"; done
fi
if [ "${#PER_BUG_ATTACH[@]}" -gt 0 ]; then
  for pb in "${PER_BUG_ATTACH[@]}"; do
    [ -n "$pb" ] || continue
    while IFS= read -r a; do [ -n "$a" ] && validate_attach "$a"; done <<<"$pb"
  done
fi

# Validate every per-bug override BEFORE anything is filed (nothing partial on a
# bad value), the same way `lcars file` does. Format is "<scope>:<tier>" with
# scope ∈ {all,reasoning,implementation} and tier ∈ {sonnet,opus}. Empty = none.
validate_override() { # value (may be empty)
  local mo="$1" scope tier
  [ -n "$mo" ] || return 0
  case "$mo" in
    *:*) : ;;
    *) die "malformed --model-override '$mo' — expected <scope>:<tier> (e.g. all:opus)." ;;
  esac
  scope="${mo%%:*}"; tier="${mo#*:}"
  case "$scope" in
    all|reasoning|implementation) : ;;
    *) die "invalid --model-override scope '$scope' — must be one of: all, reasoning, implementation." ;;
  esac
  case "$tier" in
    sonnet|opus) : ;;
    *) die "invalid --model-override tier '$tier' — must be one of: sonnet, opus." ;;
  esac
}
for mo in "${OVERRIDES[@]}"; do validate_override "$mo"; done

# --- locate the repo + state dir ------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac

LCARS_DIR="$GIT_DIR/lcars"
MISSIONS_DIR="$LCARS_DIR/missions"
CONFIG="$LCARS_DIR/config.json"
[ -d "$MISSIONS_DIR" ] || die "no missions yet — run \`lcars init\` and file a parent Mission first."

# --- the active Mission table (id, title, stage, issue) for resolve/listing -
# A bug is logged against an active (pre-merge) Mission, so "done" is excluded.
active_table() { # -> lines: id<TAB>title<TAB>stage<TAB>issue
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
  echo "  Active missions you can link a bug to:" >&2
  while IFS=$'\t' read -r id title stage issue; do
    [ -n "$id" ] || continue
    case "$issue" in ''|null) line="(local)" ;; *) line="#$issue" ;; esac
    printf '    %s  %s  %s  %s\n' "$id" "$line" "$stage" "$title" >&2
  done < <(active_table)
}

# --- resolve the parent Mission -------------------------------------------
# A bare parent is the captain not naming one — refuse and list the candidates
# so Claude (or the captain) can pick. Match a selector by exact id, by GitHub
# issue number, or by case-insensitive id/title substring; require exactly one.
if [ -z "$PARENT_SEL" ]; then
  echo "lcars log: no parent Mission referenced — say which active Mission these bugs belong to." >&2
  list_active
  exit 1
fi

SEL="${PARENT_SEL#\#}"                 # tolerate a leading '#'
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
  echo "lcars log: no active Mission matches \"$PARENT_SEL\"." >&2
  list_active
  exit 1
fi
if [ "$matches" -gt 1 ]; then
  echo "lcars log: \"$PARENT_SEL\" matches more than one active Mission — be specific." >&2
  list_active
  exit 1
fi


# --- S189: solo ownership, the light lock ----------------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars log` FILES bug missions against a parent and nests them under its issue, so it consults the lock; the READ verbs (status,
# buddy, the viewscreen's reads) never do. The remedy is deliberately a HUMAN act
# on GitHub — the solo protocol's premise is that the captain moves ownership
# where both laptops can see it, and LCARS never takes a mission off anyone.
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

# S189: the light lock, on the PARENT. A logged bug rides its parent's branch
# and nests under its parent's issue, so filing one against a mission somebody
# else holds is a write to their work — refused with the same plain line every
# other write verb uses. Checked as soon as the parent resolves, before any bug
# is extracted or any issue is opened.
owner_lock_or_die "$PARENT_ISSUE"
xo_lock_or_die "$MISSIONS_DIR/$PARENT_ID"

# --- resolve the model (config.json wins, else env, else default) ----------
MODEL=""
if [ -f "$CONFIG" ]; then
  MODEL="$(json_str "$CONFIG" model)"
fi
[ -n "$MODEL" ] || MODEL="${LCARS_MODEL:-claude-sonnet}"

# --- the chosen engine (S67, BUG-D) ----------------------------------------
# A logged bug must RUN on the SAME engine as the parent it folds into — a
# copilot parent's fixes must not silently host-detect claude. The daemon (or
# the captain) threads the parent's engine to `lcars log` as $LCARS_WORKER_BIN;
# persist it as state.json's `workerBin` on each child, exactly the way file.sh
# does for a top-level Mission, so the board shows it and the child `lcars run`
# is fed the parent engine. Empty/unset ⇒ no field (host-detect stays in
# charge). JSON-escape the value so an odd engine string can't break the JSON.
WORKER_BIN_LINE=""
if [ -n "${LCARS_WORKER_BIN:-}" ]; then
  wb_json="${LCARS_WORKER_BIN//\\/\\\\}"
  wb_json="${wb_json//\"/\\\"}"
  WORKER_BIN_LINE="  \"workerBin\": \"$wb_json\","
fi

# --- the base branch every bug Mission branches off ------------------------
# `lcars log` is ALWAYS the Mission-Log path: a logged bug fixes the delivered
# code of its PARENT Mission, so its base must track the PARENT's branch, NOT
# the incidental working-tree checkout. Filing bugs against a Claude parent
# (branch lcars/…-002) while the tree happens to sit on the Copilot branch
# (lcars/…-001) must still base on lcars/…-002. Read the parent's
# state.json.branch — the SAME source (with the SAME lcars/<PARENT_ID> fallback)
# the fix-branch logic in file_one_bug uses — and only when there is genuinely
# NO parent fall back to the checked-out HEAD/main (defensive: every Mission-Log
# invocation resolves a parent above).
BASE=""
if [ -n "$PARENT_ID" ]; then
  pstate_base="$MISSIONS_DIR/$PARENT_ID/state.json"
  [ -f "$pstate_base" ] && BASE="$(json_str "$pstate_base" branch)"
  [ -n "$BASE" ] || BASE="lcars/$PARENT_ID"
fi
if [ -z "$BASE" ]; then
  BASE="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$BASE" in ''|HEAD) BASE="main" ;; esac
fi
HAS_COMMITS=0
"$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1 && HAS_COMMITS=1

# --- mint the next mission ID (per-day sequence + the clone fingerprint) ----
# S196 — the SAME minter both `lcars file` lanes use (lcars_mint_mission_id in
# lcars-common.sh), so a bug child sequences over legacy AND fingerprinted
# siblings identically to a normally-filed mission. The scan can no longer read
# the text after the last hyphen: on a fingerprinted id that is the FINGERPRINT.
next_id() {
  lcars_mint_mission_id "$MISSIONS_DIR" "$DATE" "$(lcars_clone_fingerprint "$CONFIG")"
}

# --- file one bug; echoes "id<TAB>issue<TAB>title" for the summary ----------
file_one_bug() { # prd-path [model-override] [per-bug-attach-newline-list]
  local prd="$1"
  local override="${2:-}"
  local perbug_raw="${3:-}"

  # The bug PRD must be well-formed enough for Plan to consume it. Title + type
  # are the source of truth, exactly like `lcars file`.
  grep -q '^# Mission:'    "$prd" || die "bug PRD $prd is missing its '# Mission:' title line."
  grep -q '\*\*Type:\*\*'  "$prd" || die "bug PRD $prd is missing its '**Type:**' line."
  local title type
  title="$(sed -n 's/^# Mission:[[:space:]]*//p' "$prd" | head -1)"
  [ -n "$title" ] || die "could not read the bug title from $prd."
  type="$(sed -n 's/.*\*\*Type:\*\*[[:space:]]*//p' "$prd" | head -1 | tr 'A-Z' 'a-z' | tr -cd 'a-z')"
  [ "$type" = "bug" ] || die "bug PRD $prd must declare '**Type:** bug' (got: '${type:-empty}')."

  local id; id="$(next_id)"
  local mdir="$MISSIONS_DIR/$id"
  mkdir -p "$mdir"

  # prd.md — the bug report verbatim.
  cat "$prd" >"$mdir/prd.md"

  # --- stage durable image attachments for THIS bug (S92 + per-bug routing) --
  # This bug's attachment set is GLOBAL_ATTACH ∪ its own PER_BUG_ATTACH, deduped
  # by source path (globals first, then this bug's own, preserving order). Copy
  # each into attachments/ under a stable name, append the attachments section
  # to this bug's prd.md (relative paths, wording from the shared rule above),
  # and collect the relative paths for state.json below. No attachments ⇒
  # nothing written (byte-identical).
  local attach_srcs=()
  # --- S174: a bug logged against a DRAWING inherits the drawing -------------
  # The comment at the top of this file has said since S128 that "a bug filed
  # against a holodeck-born Mission can carry the very mockup.html the parent was
  # built from". Nothing wired it up, and the cost was measured: all NINE bugs
  # logged against lcars-20260814-001 carry `attachments: None`, so a fix ticket
  # told to "reproduce #screen-start" was worked by a worker that could not OPEN
  # #screen-start. It restored the structure and lost the specifics — the next-up
  # card's accent border, the full month name — because the only description of
  # the drawing it ever saw was the captain's prose.
  #
  # ONLY a MOCKUP is inherited. A screenshot attached to the parent is a picture
  # of the parent's own bug, not context for a different one; the drawing is the
  # thing the fix is still being judged against.
  #
  # It goes FIRST in the set so it lands as attachment-01.<ext> the way it
  # usually did on the parent, and the captain's own --attach screenshots ride
  # ALONGSIDE it (below) — this is a UNION with what he passed, never a
  # replacement. Best-effort: no parent, no mockup, or no shared classifier ⇒
  # nothing is added and the bug is filed exactly as before.
  if [ -n "$PARENT_ID" ] \
     && [ -d "$MISSIONS_DIR/$PARENT_ID/attachments" ] \
     && command -v lcars_attach_kind >/dev/null 2>&1; then
    local pmock
    for pmock in "$MISSIONS_DIR/$PARENT_ID/attachments"/*; do
      [ -f "$pmock" ] || continue
      [ "$(lcars_attach_kind "$pmock")" = mockup ] || continue
      attach_srcs+=("$pmock")
    done
  fi
  if [ "${#GLOBAL_ATTACH[@]}" -gt 0 ]; then
    local ga
    for ga in "${GLOBAL_ATTACH[@]}"; do [ -n "$ga" ] && attach_srcs+=("$ga"); done
  fi
  if [ -n "$perbug_raw" ]; then
    local pa
    while IFS= read -r pa; do [ -n "$pa" ] && attach_srcs+=("$pa"); done <<<"$perbug_raw"
  fi
  # dedup by source path, preserving first-seen order.
  local attach_list=()
  if [ "${#attach_srcs[@]}" -gt 0 ]; then
    local cand seen dup
    for cand in "${attach_srcs[@]}"; do
      dup=0
      if [ "${#attach_list[@]}" -gt 0 ]; then
        for seen in "${attach_list[@]}"; do
          [ "$seen" = "$cand" ] && { dup=1; break; }
        done
      fi
      [ "$dup" -eq 0 ] && attach_list+=("$cand")
    done
  fi
  local attach_rels=() attach_names=()
  if [ "${#attach_list[@]}" -gt 0 ]; then
    mkdir -p "$mdir/attachments"
    local an=0 asrc aext arel
    for asrc in "${attach_list[@]}"; do
      an=$((an + 1))
      aext=""
      case "$asrc" in *.*) aext=".${asrc##*.}" ;; esac
      arel="$(printf 'attachments/attachment-%02d%s' "$an" "$aext")"
      cp "$asrc" "$mdir/$arel"
      attach_rels+=("$arel")
      attach_names+=("$(basename "$asrc")")
    done
    lcars_attach_prd_section "${attach_rels[@]}" >>"$mdir/prd.md"
    # --- WHICH FILE IS WHICH (S204 fix round 1, D4) -------------------------
    # STAGING RENAMES THE FILE AND THE BODY DOES NOT KNOW. Every attachment is
    # copied in as `attachment-NN.<ext>`, in order; the PRD that came with the
    # bug still talks about the file by the name it had when it was written.
    # Measured: a filed log said "(shot-01)" and "Number One's shots of the
    # running build: shot-01" while the only file attached was
    # `attachments/attachment-02.png`. Nothing connected the two names, so the
    # one picture of the bug was, to the captain, unfindable.
    #
    # THE FIX IS AT THE RENAME, which is the only place that knows both names —
    # not a guess made upstream about what number a file will land on. Written
    # ONLY when a name actually changed, so a bug whose attachments already
    # carry their staged names gains nothing.
    #
    # AND ONLY ON NUMBER ONE'S OWN FILINGS ($LCARS_XO_INTERNAL is set — the
    # marker that says this call is the first officer's, S204 fix round 1 D1).
    # That is the whole population with the problem: Number One writes the bug
    # PRD itself and names its evidence by the name it gave it ("shot-01"). The
    # captain's own `lcars log --attach screenshot.png` says nothing about a
    # file name at all, and its attachment section is asserted BYTE FOR BYTE by
    # the suite (21e) — a pasted screenshot's bug PRD must not move by one
    # character, so it does not.
    local ni=0 changed=0
    while [ "$ni" -lt "${#attach_rels[@]}" ]; do
      [ "$(basename "${attach_rels[$ni]}")" = "${attach_names[$ni]}" ] || changed=1
      ni=$((ni + 1))
    done
    [ -n "${LCARS_XO_INTERNAL:-}" ] || changed=0
    if [ "$changed" -eq 1 ]; then
      {
        printf '\n## Which file is which\n\n'
        printf 'The files above were renamed as they were attached. Where the text of this Mission names a picture, this is the file to open:\n\n'
        ni=0
        while [ "$ni" -lt "${#attach_rels[@]}" ]; do
          printf -- '- `%s` — %s\n' "${attach_rels[$ni]}" "${attach_names[$ni]%.*}"
          ni=$((ni + 1))
        done
      } >>"$mdir/prd.md"
    fi
  fi

  # NOTE: a logged bug now ENTERS the pipeline at Research (grounding mode) and
  # walks Research → Validate → Plan → … (stage="align", origin="log" below), so
  # we DO NOT hand-write a thin validated-plan.md here anymore — Validate produces
  # the real one after Research has anchored the symptom to the existing code.
  # (Align is still skipped: the drive maps stage=align + no feedback.md straight
  # to Research, with no re-grill; the captain's report stays casual.)

  # the Mission's working branch. When the parent Mission is still PRE-MERGE —
  # its branch ref still exists locally — accumulate this fix as commits ONTO
  # the parent's branch instead of minting a per-bug branch (BUG-011): that
  # avoids a stack of bug->parent PRs and the fragile bottom-up merge order, and
  # survives the parent being squashed/rebased on merge. Only when the parent
  # has no live branch (already merged away) does the bug get its own
  # lcars/<id> branch, exactly as `lcars file` does (best-effort).
  local branch="lcars/$id"
  local parent_branch=""
  if [ -n "$PARENT_ID" ]; then
    local pstate="$MISSIONS_DIR/$PARENT_ID/state.json"
    [ -f "$pstate" ] && parent_branch="$(json_str "$pstate" branch)"
    [ -n "$parent_branch" ] || parent_branch="lcars/$PARENT_ID"
  fi
  if [ -n "$parent_branch" ] \
     && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$parent_branch"; then
    # parent is pre-merge: commit the fix straight onto its branch.
    branch="$parent_branch"
  elif [ "$HAS_COMMITS" -eq 1 ]; then
    # parent merged (or unknown): the bug gets its own branch as before.
    "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" \
      || "$GIT_BIN" branch "$branch" >/dev/null 2>&1 || true
  fi

  # open the GitHub issue (labelled for the Plan column + bug + linked + the
  # mission role — a logged bug is a fast-tracked Mission, so it carries
  # lcars:mission like any other Mission).
  local issue="" body
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    body="$(mktemp)"
    # LANE 5 (logged bug). ONE composer (skills/lcars-run/issue-body.sh) — the
    # VISIBLE body is byte-for-byte what this lane built inline before S188 (the
    # `> 🐞 Logged via …` lead-in, then prd.md), plus the appended envelope.
    #
    # Every value is passed as an OVERRIDE because state.json does not exist yet:
    # it is written below, and it needs the issue number this call is about to
    # mint. The provenance line comes out of origin/parentMission/parentIssue —
    # the same three values the inline printf used — so a later Verify-entry
    # refresh recomposes the identical lead-in instead of deleting it.
    if command -v lcars_issue_body_compose >/dev/null 2>&1; then
      lcars_issue_body_compose "$mdir" align "" \
        "id=$id" "branch=$branch" "base=$BASE" "type=bug" \
        "engine=${LCARS_WORKER_BIN:-}" "origin=log" "parentMission=$PARENT_ID" \
        "parentIssue=$PARENT_ISSUE" "attachments=${#attach_rels[@]}" >"$body"
    else
      # The composer is missing (a stale install): degrade to exactly the
      # pre-S188 inline body rather than filing nothing.
      {
        printf '> 🐞 Logged via `lcars log` against %s' "$PARENT_ID"
        case "$PARENT_ISSUE" in ''|null) : ;; *) printf ' (#%s)' "$PARENT_ISSUE" ;; esac
        printf '.\n\n'
        cat "$mdir/prd.md"
      } >"$body"
    fi
    local url num
    url="$("$GH_BIN" issue create \
            --title "$title" \
            --body-file "$body" \
            --label "lcars:align,lcars:bug,lcars:linked,lcars:mission" 2>/dev/null)"
    num="${url##*/}"
    case "$num" in
      ''|*[!0-9]*) issue="" ;;
      # Remember the body that actually reached GitHub — the S188 regression
      # guard's baseline, so a later transfer point cannot delete a section of
      # this issue (see skills/lcars-run/issue-body.sh).
      *) issue="$num"
         { command -v lcars_issue_body_record >/dev/null 2>&1 \
           && lcars_issue_body_record "$mdir" "$body"; } || true ;;
    esac
    rm -f "$body"
  fi

  # NATIVELY nest the bug issue under the parent's issue — the SAME host-adapter
  # op Schedule uses for ticket sub-issues — so a logged bug reads as a child of
  # its Mission, not a standalone labelled card. Best-effort: this NEVER hard-
  # fails `lcars log` (the lcars:linked label + parentIssue/parentMission below
  # are the belt-and-braces record). Skip it when there is no parent issue
  # number or no child number, and never self-nest.
  case "$PARENT_ISSUE" in
    ''|null) : ;;
    *)
      if [ -n "$issue" ] && [ "$issue" != "$PARENT_ISSUE" ]; then
        host link-subissue "$PARENT_ISSUE" "$issue" >/dev/null 2>&1 || true
      fi
      ;;
  esac

  # state.json — type bug, stage plan, linked to the parent. The optional
  # workerBin line is emitted only when an engine was threaded in (BUG-D), so a
  # no-engine log keeps the exact prior shape (host-detect stays in charge). The
  # optional modelOverride line carries the captain's per-bug steer (S74) in the
  # EXACT shape file.sh persists — { "scope": "...", "tier": "..." } — so run.sh's
  # active_model_override picks it up natively with zero resolve-logs changes.
  local override_line=""
  if [ -n "$override" ]; then
    local ov_scope="${override%%:*}" ov_tier="${override#*:}"
    override_line="  \"modelOverride\": { \"scope\": \"$ov_scope\", \"tier\": \"$ov_tier\" },"
  fi
  # The durable attachments array (S92), emitted only when ≥1 was staged for this
  # bug — mirroring the optional WORKER_BIN_LINE / override_line pattern so a
  # no-attachment bug keeps the exact prior state.json shape (no attachments key).
  local attach_line=""
  if [ "${#attach_rels[@]}" -gt 0 ]; then
    local attach_items="" arel2
    for arel2 in "${attach_rels[@]}"; do
      [ -n "$attach_items" ] && attach_items="$attach_items, "
      attach_items="$attach_items\"$arel2\""
    done
    attach_line="  \"attachments\": [$attach_items],"
  fi
  local title_json="${title//\\/\\\\}"; title_json="${title_json//\"/\\\"}"
  local issue_json="${issue:-null}"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "bug",\n'
    printf '  "origin": "log",\n'
    printf '  "title": "%s",\n' "$title_json"
    printf '  "stage": "align",\n'
    printf '  "created": "%s",\n' "$NOW"
    printf '  "model": "%s",\n' "$MODEL"
    [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
    [ -n "$override_line" ] && printf '%s\n' "$override_line"
    [ -n "$attach_line" ] && printf '%s\n' "$attach_line"
    printf '  "githubIssue": %s,\n' "$issue_json"
    printf '  "parentMission": "%s",\n' "$PARENT_ID"
    printf '  "parentIssue": %s,\n' "${PARENT_ISSUE:-null}"
    printf '  "branch": "%s",\n' "$branch"
    printf '  "base": "%s"\n' "$BASE"
    printf '}\n'
  } >"$mdir/state.json"

  # --- run the dynamic estimator on the child (S74) ------------------------
  # Now that prd.md + state.json exist, give this bug Mission the SAME dynamic
  # estimate a top-level Mission gets: invoke run.sh `estimate` exactly the way
  # file.sh does at the end of Align (best-effort, NEVER block the log). On
  # success it writes a canonical, always-valid estimate.json on the child (cost
  # + reasoning/impl criticality + per-stage model map). The estimator inherits
  # the child's engine the same way the rest of the pipeline does (the threaded
  # $LCARS_WORKER_BIN). On failure it leaves NO estimate.json and the bug still
  # files — every stage then falls back to its legacy model, exactly as before.
  if [ -f "$RUN_BIN" ]; then
    bash "$RUN_BIN" estimate --mission "$id" >/dev/null 2>&1 || true
  fi

  printf '%s\t%s\t%s\n' "$id" "$issue" "$title"
}

# --- file every bug, collecting rows for the summary -----------------------
#
# S205 ruling 3 (2026-09-14, false success): `file_one_bug` validates its PRD
# (title line, **Type:** bug) BEFORE it ever `mkdir`s the mission dir, and dies
# with a plain message when it does not pass. But it runs inside
# `$(file_one_bug ...)` — a COMMAND SUBSTITUTION, hence a subshell — so its
# `exit 1` only ended that subshell; the loop below never looked at the
# subshell's exit status, so a validation failure still appended an (empty)
# row to ROWS and the summary printed "1 bug mission filed and linked to #107"
# with an empty id and "Run `lcars run ` to begin." — a false green for a bug
# that was never mkdir'd. Cure: capture the exit status of EACH bug filing and
# refuse to print any success summary the moment one fails. The validation
# error itself already reached the captain (die's own stderr write happens
# inside the subshell, which does not capture stderr — only stdout is
# captured), so nothing here re-prints it; this only stops the false claim.
ROWS=()
i=0
for prd in "${PRDS[@]}"; do
  row="$(file_one_bug "$prd" "${OVERRIDES[$i]:-}" "${PER_BUG_ATTACH[$i]:-}")"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$row" ]; then
    die "could not file the bug PRD $prd — see the error above. No bug mission was filed for it, and this batch stops here (${#ROWS[@]} filed before it)."
  fi
  ROWS+=("$row")
  i=$((i + 1))
done

# --- aggregate summary -----------------------------------------------------
n="${#ROWS[@]}"
noun="bug missions"; [ "$n" -eq 1 ] && noun="bug mission"
case "$PARENT_ISSUE" in ''|null) plabel="$PARENT_ID" ;; *) plabel="#$PARENT_ISSUE" ;; esac

printf '%d %s filed and linked to %s (%s):\n' "$n" "$noun" "$plabel" "$PARENT_TITLE"
first_id=""
for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r rid rissue rtitle <<<"$r"
  [ -n "$first_id" ] || first_id="$rid"
  case "$rissue" in '') ilabel="(local)" ;; *) ilabel="#$rissue" ;; esac
  printf '  %s  %s  %s\n' "$rid" "$ilabel" "$rtitle"
done

if [ "$n" -gt 1 ]; then
  printf 'Run `lcars run %s` (or any of the above) to begin.\n' "$first_id"
else
  printf 'Run `lcars run %s` to begin.\n' "$first_id"
fi
