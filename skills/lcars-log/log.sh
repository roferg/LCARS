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
#   2. creates .git/lcars/missions/<id>/ with prd.md, validated-plan.md, state.json
#   3. gives the Mission its own branch lcars/<id> (off the current branch)
#   4. opens a GitHub issue labelled lcars:plan + lcars:bug + lcars:linked + lcars:mission
#   5. links it to the parent (parentMission/parentIssue in state.json + label)
# then prints one aggregate summary.
#
# Bugs SKIP Align, Research, and Validate — they start at the **Plan** stage
# (vision Example 3). Plan's worker still reads validated-plan.md, so we write a
# thin one from the bug PRD: the report IS the validated direction. That makes
# `lcars run <id>` immediately runnable from Plan with no upstream stages.
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
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)   PARENT_SEL="${2:-}"; shift 2 ;;
    --parent=*) PARENT_SEL="${1#--parent=}"; shift ;;
    --prd)      PRDS+=("${2:-}"); OVERRIDES+=(""); shift 2 ;;
    --prd=*)    PRDS+=("${1#--prd=}"); OVERRIDES+=(""); shift ;;
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
BASE="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$BASE" in ''|HEAD) BASE="main" ;; esac
HAS_COMMITS=0
"$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1 && HAS_COMMITS=1

# --- mint the next mission ID (per-day sequence, scanning what exists) ------
next_id() {
  local max=0 d n
  shopt -s nullglob
  for d in "$MISSIONS_DIR"/lcars-"$DATE"-*; do
    n="$((10#${d##*-}))"
    [ "$n" -gt "$max" ] && max="$n"
  done
  shopt -u nullglob
  printf 'lcars-%s-%03d' "$DATE" "$((max + 1))"
}

# --- file one bug; echoes "id<TAB>issue<TAB>title" for the summary ----------
file_one_bug() { # prd-path [model-override]
  local prd="$1"
  local override="${2:-}"

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

  # validated-plan.md — bugs skip Validate, but Plan reads this. The report is
  # the validated direction, so synthesise a thin plan from it. (See header.)
  {
    printf '# Validated Plan: %s\n\n' "$title"
    printf 'This is a **bug Mission** logged via `lcars log` against %s' "$PARENT_ID"
    case "$PARENT_ISSUE" in ''|null) : ;; *) printf ' (#%s)' "$PARENT_ISSUE" ;; esac
    printf '.\n\n'
    printf 'It skips Align, Research, and Validate: the bug report below IS the\n'
    printf 'validated direction. Plan should decompose it into the smallest set of\n'
    printf 'vertical-slice tickets that fix the defect and lock it with a test.\n\n'
    printf -- '---\n\n'
    cat "$prd"
  } >"$mdir/validated-plan.md"

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
    {
      printf '> 🐞 Logged via `lcars log` against %s' "$PARENT_ID"
      case "$PARENT_ISSUE" in ''|null) : ;; *) printf ' (#%s)' "$PARENT_ISSUE" ;; esac
      printf '.\n\n'
      cat "$mdir/prd.md"
    } >"$body"
    local url num
    url="$("$GH_BIN" issue create \
            --title "$title" \
            --body-file "$body" \
            --label "lcars:plan,lcars:bug,lcars:linked,lcars:mission" 2>/dev/null)"
    rm -f "$body"
    num="${url##*/}"
    case "$num" in ''|*[!0-9]*) issue="" ;; *) issue="$num" ;; esac
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
  local title_json="${title//\\/\\\\}"; title_json="${title_json//\"/\\\"}"
  local issue_json="${issue:-null}"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "bug",\n'
    printf '  "title": "%s",\n' "$title_json"
    printf '  "stage": "plan",\n'
    printf '  "created": "%s",\n' "$NOW"
    printf '  "model": "%s",\n' "$MODEL"
    [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
    [ -n "$override_line" ] && printf '%s\n' "$override_line"
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
ROWS=()
i=0
for prd in "${PRDS[@]}"; do
  ROWS+=("$(file_one_bug "$prd" "${OVERRIDES[$i]:-}")")
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
