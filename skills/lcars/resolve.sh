#!/usr/bin/env bash
#
# lcars resolve — the shared mission resolver.
#
# Both `lcars` (drive) and `lcars answer` (act on a card) go through this to pick
# the target Mission without making the captain juggle ids. The rule:
#   • exactly one candidate            → resolve it, no id needed
#   • several candidates, no selector  → ambiguous: print the candidate table so
#                                        the caller can drop into a fuzzy picker
#   • an explicit id / partial-id / title substring → always honoured
#
# It is purely mechanical (no LLM) and shared by both new skills:
#   • executed directly  →  `resolve.sh --scope <active|pending> [--id <sel>]`
#   • sourced            →  defines `lcars_resolve` for in-process use
#
# Scope decides the candidate set:
#   active   missions whose stage is not "done" AND not parked (the drivable set;
#            a parked/prdPending mission has no PRD, so it is never drivable)
#   pending  missions awaiting a human: awaitingHuman, or parked at "verify"
#            (the inbox set — escalations + the Verify ship/send-back gate)
#   parked   the "awaiting alignment" group — prdPending missions ONLY, offered
#            for grilling (`lcars file <id>`) but NEVER auto-driven
#
# Exit codes (so callers can branch without parsing prose):
#   0  resolved      → the single mission id on stdout
#   2  ambiguous     → the candidate table on stdout, one per line:
#                        id <TAB> title <TAB> stage <TAB> note
#   3  none / error  → a message on stderr, nothing on stdout
#
set -uo pipefail

# --- tiny JSON readers (no jq; same decoding awk as status.sh / respond.sh) --
_lr_json_str() { # file key  → first "key": "value", common escapes decoded
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok)
      if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next
      rest = substr(rest, RLENGTH + 1)
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") {
          e = substr(rest, i + 1, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else               out = out e
          i += 2; continue
        }
        if (c == "\"") break
        out = out c; i += 1
      }
      print out; done = 1
    }
  ' "$1"
}
_lr_json_raw() { # file key  → first bare token (number/bool/null)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

_lr_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# lcars_resolve --scope <active|pending> [--id <selector>] [selector]
lcars_resolve() {
  local scope="active" selector=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)   scope="${2:-}"; shift 2 ;;
      --scope=*) scope="${1#--scope=}"; shift ;;
      --id)      selector="${2:-}"; shift 2 ;;
      --id=*)    selector="${1#--id=}"; shift ;;
      *)         selector="$1"; shift ;;   # a bare argument is the selector
    esac
  done

  # Locate .git/lcars/missions (mirrors run.sh / status.sh).
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || { echo "lcars: not inside a git repository." >&2; return 3; }
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  local mdir="$gitdir/lcars/missions"
  [ -d "$mdir" ] || { echo "lcars: no missions yet — file one with \`lcars\`." >&2; return 3; }

  # Build the candidate table for the requested scope.
  local cands=() s id title stage awaiting pend pstage note
  shopt -s nullglob
  for s in "$mdir"/*/state.json; do
    id="$(_lr_json_str "$s" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
    title="$(_lr_json_str "$s" title)"
    stage="$(_lr_json_str "$s" stage)"
    awaiting="$(_lr_json_raw "$s" awaitingHuman)"
    parked="$(_lr_json_raw "$s" prdPending)"

    # A parked Mission's state.json.stage is the resume pointer (e.g. "align");
    # pending.json holds the true in-flight stage (e.g. "research"), matching the
    # board label. Prefer it so this view agrees with the Kanban column.
    pend="$(dirname "$s")/pending.json"
    if [ "$awaiting" = "true" ] && [ -f "$pend" ]; then
      pstage="$(_lr_json_str "$pend" stage)"; [ -n "$pstage" ] && stage="$pstage"
    fi

    note=""
    case "$scope" in
      pending)
        # Parked missions await ALIGNMENT (a grill), not a decision — they are
        # NOT part of the inbox/pending set.
        [ "$parked" = "true" ] && continue
        if [ "$awaiting" = "true" ]; then
          note="$(_lr_json_str "$s" pendingQuestion)"; [ -n "$note" ] || note="awaiting your answer"
        elif [ "$stage" = "verify" ]; then
          note="ready to ship — approve or send back"
        else
          continue
        fi
        ;;
      parked)
        # The "awaiting alignment" group — parked (prdPending) missions ONLY.
        # OFFERED for grilling, never auto-driven.
        [ "$parked" = "true" ] || continue
        note="awaiting alignment"
        ;;
      active|*)
        [ "$stage" = "done" ] && continue
        # A parked mission is NOT drivable (no PRD yet) — the driver never runs a
        # PRD-less mission, so it must never appear in the active/drivable set.
        [ "$parked" = "true" ] && continue
        note="$stage"
        ;;
    esac

    cands+=("$id"$'\t'"$title"$'\t'"$stage"$'\t'"$note")
  done
  shopt -u nullglob

  # Filter by the selector (case-insensitive substring of id OR title).
  if [ -n "$selector" ] && [ "${#cands[@]}" -gt 0 ]; then
    local filtered=() c cid ctitle lsel hid hti
    lsel="$(_lr_lower "$selector")"
    for c in "${cands[@]}"; do
      IFS=$'\t' read -r cid ctitle _ _ <<<"$c"
      hid="$(_lr_lower "$cid")"; hti="$(_lr_lower "$ctitle")"
      case "$hid" in *"$lsel"*) filtered+=("$c"); continue ;; esac
      case "$hti" in *"$lsel"*) filtered+=("$c") ;; esac
    done
    # Empty-array-safe assignment (macOS bash 3.2 errors on "${x[@]}" when empty).
    cands=(${filtered[@]+"${filtered[@]}"})
  fi

  local n="${#cands[@]}"
  if [ "$n" -eq 0 ]; then
    if [ -n "$selector" ]; then
      echo "lcars: no $scope mission matches \"$selector\"." >&2
    else
      echo "lcars: no $scope mission found." >&2
    fi
    return 3
  fi
  if [ "$n" -eq 1 ]; then
    IFS=$'\t' read -r id _ _ _ <<<"${cands[0]}"
    printf '%s\n' "$id"
    return 0
  fi
  # Ambiguous: hand the caller the full candidate table for its picker.
  printf '%s\n' "${cands[@]}"
  return 2
}

# Run when executed directly; stay quiet (just define the function) when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  lcars_resolve "$@"
fi
