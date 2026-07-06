#!/usr/bin/env bash
#
# release.sh — `lcars release`, the DRIFT-repair for LCARS's own version.
#
# LCARS's version bump normally rides each PR into main (no CI; the PR author is
# an LLM already in the loop). `lcars release` is the MANUAL repair for when main
# moved WITHOUT a bump — the DRIFT verdict check.sh emits ("main has unversioned
# changes"). It:
#   1. REFUSES unless the SOURCE main checkout is on `main` AND clean — the
#      captain's clones are sacred; anything else prints a one-line reason and
#      no-ops (never stashes, never touches a worktree).
#   2. Collects the commits on main SINCE the commit that last touched VERSION
#      (the unversioned drift). NOTHING unstamped ⇒ "nothing to release", a clean
#      no-op that spawns NO worker.
#   3. Spawns EXACTLY ONE summarization worker through the CLI-agnostic worker
#      adapter (engine-aware, stubbable) to author a CHANGELOG entry from those
#      commit subjects/bodies.
#   4. Bumps VERSION (increment N; roll to <year>.<month>.1 when the calendar
#      month changed), prepends the changelog entry (newest-first), and commits
#      both to main with a standard message.
#
# Everything external is env-injected so tests drive it against a LOCAL fixture
# with a stubbed worker — ZERO tokens, ZERO network:
#   LCARS_REPO           source root (default: resolved from this script's path)
#   LCARS_GIT_BIN/GIT_BIN git binary                       (default: git)
#   LCARS_WORKER_BIN     the cold-worker CLI (the engine)  (default: claude)
#   LCARS_WORKER_CLI     the adapter cli id                (default: basename bin)
#   LCARS_WORKER_MODEL   optional model pin (forwarded to the adapter)
#   LCARS_WORKER_ADAPTER worker-adapter.sh path (default: $REPO/skills/lcars-run/…)
#   LCARS_NOW_YEAR       "now" calendar year   (default: date +%Y)
#   LCARS_NOW_MONTH      "now" month, no zero  (default: date +%-m)
#   LCARS_NOW_DATE       "now" YYYY-MM-DD       (default: date +%Y-%m-%d)
#
set -uo pipefail

# --- locate the LCARS checkout (mirrors version.sh / check.sh) ------------
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
DEFAULT_REPO="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
REPO="${LCARS_REPO:-$DEFAULT_REPO}"

. "$SCRIPT_DIR/version-lib.sh"

GIT_BIN="${LCARS_GIT_BIN:-${GIT_BIN:-git}}"
WORKER_BIN="${LCARS_WORKER_BIN:-claude}"
WORKER_CLI="${LCARS_WORKER_CLI:-$(basename "$WORKER_BIN")}"
# The worker adapter is a SIBLING skill of this one in the SAME install, so
# resolve it from THIS script's dir — NOT from $REPO (the repo being released,
# which need not be the LCARS source and may have no skills/ of its own).
ADAPTER="${LCARS_WORKER_ADAPTER:-$SCRIPT_DIR/../lcars-run/worker-adapter.sh}"

VERSION_FILE="$REPO/VERSION"
CHANGELOG="$REPO/CHANGELOG.md"

say()     { printf '%s\n' "$1"; }
refuse()  { printf 'lcars release: %s\n' "$1" >&2; exit 1; }

# --- 1. the captain's clones are sacred: main + clean only ----------------
branch="$("$GIT_BIN" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$branch" = "main" ] || \
  refuse "refusing — the source checkout is on '${branch:-?}', not main (main may be checked out in another worktree). No-op."
dirty="$("$GIT_BIN" -C "$REPO" status --porcelain 2>/dev/null)"
[ -z "$dirty" ] || \
  refuse "refusing — the source main checkout is dirty. Commit or stash by hand first. No-op."

# --- running version (the anchor for the bump) ----------------------------
RUNNING="$(lcars_version_read_running "$VERSION_FILE")"
version_valid "$RUNNING" || \
  refuse "running VERSION ('$RUNNING') is missing or malformed — cannot bump. No-op."

# --- 2. the unversioned drift: commits since VERSION last changed ----------
vcommit="$("$GIT_BIN" -C "$REPO" rev-list -n1 HEAD -- VERSION 2>/dev/null)"
if [ -n "$vcommit" ]; then
  RANGE="${vcommit}..HEAD"
else
  # VERSION was never committed — every commit is unversioned drift.
  RANGE="HEAD"
fi
drift_count="$("$GIT_BIN" -C "$REPO" rev-list --count "$RANGE" 2>/dev/null)"
case "$drift_count" in ''|*[!0-9]*) drift_count=0 ;; esac
if [ "$drift_count" -eq 0 ]; then
  say "nothing to release — main has no unversioned commits past VERSION ($RUNNING)."
  exit 0
fi

# The commit subjects + bodies the worker summarizes into a changelog entry.
COMMITS="$("$GIT_BIN" -C "$REPO" log --format='- %s%n%b' "$RANGE" 2>/dev/null)"

# --- 3. compute the NEW version (increment N; roll on a month change) -------
now_y="${LCARS_NOW_YEAR:-$(date +%Y)}"
if [ -n "${LCARS_NOW_MONTH:-}" ]; then
  now_m="$LCARS_NOW_MONTH"
else
  now_m="$(date +%m)"; now_m="$((10#$now_m))"
fi
now_date="${LCARS_NOW_DATE:-$(date +%Y-%m-%d)}"

oldIFS="$IFS"; IFS=.; set -f; set -- $RUNNING; set +f; IFS="$oldIFS"
vy="$1"; vm="$2"; vn="$3"
if [ "$vy" = "$now_y" ] && [ "$vm" = "$now_m" ]; then
  NEW="$now_y.$now_m.$((vn + 1))"
else
  NEW="$now_y.$now_m.1"
fi

# --- 4. ONE summarization worker through the adapter (engine-aware) ---------
OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/lcars-release.XXXXXX")"
ENTRY_FILE="$OUTDIR/changelog-entry.md"
PROMPT="You are authoring ONE CHANGELOG entry for a new LCARS release ($NEW).
Summarize the following commit subjects/bodies into a SHORT, human-readable
changelog entry (a tight paragraph, or a few '- ' bullets) describing what
changed — captain-facing, no commit hashes, no fluff. Write ONLY the entry body
(no '## <version>' header, no date line — the harness adds those) to the file at
\$LCARS_WORK_OUT/changelog-entry.md.

=== commits on main since VERSION last changed ===
$COMMITS"

# adapter_spawn: <cli> <role> <outdir> <prompt>. repo-read grants the worker a
# Write/create tool so it can author the entry file, without edit/bash. The bin
# it execs is $LCARS_WORKER_BIN (defaults to the cli id) — tests point it at a
# recording stub, so this call is stub-argv asserted on BOTH engines.
LCARS_WORKER_BIN="$WORKER_BIN" \
  bash "$ADAPTER" spawn "$WORKER_CLI" repo-read "$OUTDIR" "$PROMPT" || true

ENTRY="$(cat "$ENTRY_FILE" 2>/dev/null)"
# Trim; fall back to a minimal entry so a silent worker never yields a blank
# section (the release still records the commit list pointer).
ENTRY="$(printf '%s' "$ENTRY" | sed -e 's/[[:space:]]*$//')"
if [ -z "$ENTRY" ]; then
  ENTRY="Drift-repair release rolling up $drift_count unversioned commit(s) on main. See \`git log\` for the change list."
fi

# --- prepend the new section (newest-first, after the preamble) ------------
SECTION="$OUTDIR/section.md"
{
  printf '## %s — %s\n\n' "$NEW" "$now_date"
  printf '%s\n\n' "$ENTRY"
} > "$SECTION"

if [ -f "$CHANGELOG" ]; then
  # Insert BEFORE the first existing "## " section (so the preamble stays on top);
  # append at the end if there is no prior section.
  awk -v secfile="$SECTION" '
    function emit(  line){ while((getline line < secfile) > 0) print line }
    /^## / && !ins { emit(); ins=1 }
    { print }
    END{ if(!ins) emit() }
  ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
else
  cp "$SECTION" "$CHANGELOG"
fi

# --- bump VERSION + commit both to main ------------------------------------
printf '%s\n' "$NEW" > "$VERSION_FILE"
"$GIT_BIN" -C "$REPO" add VERSION CHANGELOG.md >/dev/null 2>&1
"$GIT_BIN" -C "$REPO" commit -qm "chore(release): $NEW — repair unversioned drift ($drift_count commit(s))" \
  || refuse "the release commit failed — VERSION/CHANGELOG.md are staged; commit by hand."

rm -rf "$OUTDIR" 2>/dev/null || true
say "Released $NEW — bumped VERSION and prepended the CHANGELOG entry ($drift_count commit(s) summarized)."
exit 0
