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

die() { printf 'lcars resolve-logs: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same decoding as log.sh / run.sh) -----------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

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
PARENT_SEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)   PARENT_SEL="${2:-}"; shift 2 ;;
    --parent=*) PARENT_SEL="${1#--parent=}"; shift ;;
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

# --- DRIVE each bug to its Verify gate, in order ---------------------------
drive_bug() { # id  -> 0 reached verify | 1 paused (awaiting-human) | 2 error
  local id="$1" sfile="$MISSIONS_DIR/$1/state.json" stage awaiting
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" LCARS_WORKER_BIN="${WORKER_BIN:-}" \
  LCARS_NOTIFY="$NOTIFY_BIN" \
    bash "$RUN_SCRIPT" drive --mission "$id" >/dev/null 2>&1 || true
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

for id in "${ORDERED[@]:-}"; do
  [ -n "$id" ] || continue
  drive_bug "$id"; rc=$?
  case "$rc" in
    0) resolved+=("$id") ;;
    1) pause_at "$id"; exit 0 ;;
    2) die "driving $id did not reach its Verify gate (stage is now '$(json_str "$MISSIONS_DIR/$id/state.json" stage)') — resolve it manually with \`lcars run $id\`, then re-run." ;;
  esac
done

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
ASK="$n $noun resolved and waiting on their Verify gates — ready for you to re-verify against $PARENT_ID ($PARENT_TITLE). Re-inspect each fix, then \`lcars approve <bug-id>\` to ship it (open its PR) or \`lcars feedback <bug-id>\` to send it back."

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
printf '%d %s resolved to Verify and linked to %s (%s):%s\n' "$n" "$noun" "$plabel" "$PARENT_TITLE" "$list_txt"
echo
echo "Raised ONE consolidated re-verify gate on $PARENT_ID and pinged you once."
echo "Re-inspect each fix, then approve or send back:"
for id in "${resolved[@]}"; do
  echo "  lcars approve $id    — ship it (open the PR)"
done
echo "Open the inbox with \`lcars answer\` to act on the consolidated card."
exit 0
