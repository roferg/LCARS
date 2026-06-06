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

die() { printf 'lcars log: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same decoding as resolve.sh / status.sh) -----
json_str() { # file key -> first "key": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key -> first bare token (number/bool/null)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- args -----------------------------------------------------------------
PARENT_SEL=""
PRDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)   PARENT_SEL="${2:-}"; shift 2 ;;
    --parent=*) PARENT_SEL="${1#--parent=}"; shift ;;
    --prd)      PRDS+=("${2:-}"); shift 2 ;;
    --prd=*)    PRDS+=("${1#--prd=}"); shift ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ "${#PRDS[@]}" -gt 0 ] || die "no bug PRDs given — pass --prd <path> (once per bug)."
for p in "${PRDS[@]}"; do
  [ -f "$p" ] || die "bug PRD file not found: $p"
done

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
file_one_bug() { # prd-path
  local prd="$1"

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

  # the Mission's own branch (best-effort, mirrors `lcars file`).
  local branch="lcars/$id"
  if [ "$HAS_COMMITS" -eq 1 ]; then
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

  # state.json — type bug, stage plan, linked to the parent.
  local title_json="${title//\\/\\\\}"; title_json="${title_json//\"/\\\"}"
  local issue_json="${issue:-null}"
  cat >"$mdir/state.json" <<EOF
{
  "id": "$id",
  "type": "bug",
  "title": "$title_json",
  "stage": "plan",
  "created": "$NOW",
  "model": "$MODEL",
  "githubIssue": $issue_json,
  "parentMission": "$PARENT_ID",
  "parentIssue": ${PARENT_ISSUE:-null},
  "branch": "$branch",
  "base": "$BASE"
}
EOF

  printf '%s\t%s\t%s\n' "$id" "$issue" "$title"
}

# --- file every bug, collecting rows for the summary -----------------------
ROWS=()
for prd in "${PRDS[@]}"; do
  ROWS+=("$(file_one_bug "$prd")")
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
