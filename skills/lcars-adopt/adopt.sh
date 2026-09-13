#!/usr/bin/env bash
#
# lcars adopt — rebuild a Mission on THIS laptop from its GitHub issue alone.
#
# Session 189, leg B. A second clone has no `.git/lcars` at all, so a Mission
# that plainly exists on GitHub is invisible to it: the board is empty, `lcars
# status` shows nothing, and the only way to get the work locally was to file it
# again. `lcars adopt <issue#>` closes that gap at the two ENDS of the pipeline.
#
#   at ALIGN (or parked-align) — CLAIM it (assign yourself, if it is free),
#     rebuild `.git/lcars/missions/<id>/` from the issue, and fetch the branch
#     if origin already has one. The spec at Align IS the issue body.
#   at VERIFY — JOIN it: rebuild the state, fetch the branch, resolve the OPEN
#     PR and persist prUrl/prNumber IN THE SHAPE THE EXISTING WRITER USES
#     (pr-lib.sh — prUrl and prNumber are both strings), so `lcars approve` /
#     `lcars feedback` work with no further command and the two laptops' state
#     files stay interchangeable. No claim is needed to LOOK; taking an ACTION
#     still requires ownership, and those verbs check the light lock themselves.
#   at ANY OTHER STAGE — refuse, honestly, naming the boundary. v1 portability
#     is the ENDS (captain's ruling, 2026-09-04). The pipeline between them is
#     walk-away and its artifacts (research findings, plan.json, ticket state)
#     stay local by design; mid-pipeline handoff is LEDGERED, not built. An
#     adopt that "worked" mid-pipeline would hand the captain a mission missing
#     the very files the next stage reads.
#
# ---------------------------------------------------------------------------
# THE TWO RULES THIS SCRIPT IS BUILT AROUND
# ---------------------------------------------------------------------------
#
# 1. EVERY FACT COMES FROM A RECORDED PLACE — NEVER FROM THE CAPTAIN'S PROSE.
#
#    The identity facts come from the S188 `lcars:handoff` ENVELOPE (id, branch,
#    base, type, engine, parentIssue, attachments, parked). The STAGE comes from
#    the `lcars:<stage>` LABEL. The title comes from the issue's title field.
#    That is the complete list. This script contains NO regex over the issue's
#    prose — not to find the branch, not to find the type, not to find the
#    estimate, and not to find where the PRD ends.
#
#    That is not fastidiousness, it is the lesson of three sessions (S147, S156,
#    S188 twice) that each paid multiple fix rounds for scanning composed text.
#    The captain writes PRDs *about LCARS*: any pattern keyed on `**Type:**`, on
#    `---`, on `## Estimate`, or on the envelope's own syntax will eventually be
#    handed a document that talks about exactly those things, and it will be
#    confidently wrong. When a fact is NOT recorded, the answer here is an
#    HONEST REFUSAL naming what is missing — see the refusals below, all four of
#    them. `lcars_handoff_require_v1` is the gate, and it runs BEFORE any field
#    is trusted, so a future schema is refused rather than misread.
#
#    The one consequence worth stating out loud: `prd.md` is rebuilt as the
#    WHOLE issue body minus the envelope. The composed body is PRD + optional
#    ADR + optional Estimate, and NOTHING RECORDS where one ends and the next
#    begins (S188 keeps that record locally, in `.issue-body.parts/`, which by
#    definition does not exist on this laptop). Splitting it would mean guessing
#    at `---` rules that a PRD may legitimately contain. So adopt keeps the body
#    whole: a superset of the spec, every byte of it real, nothing invented.
#
# 2. THE MISSION ID IS REUSED, NEVER MINTED. The id names the branch
#    (`lcars/<id>`), the mission dir and the issue that already exist. Minting a
#    new one on adopt would silently fork the mission in two. The envelope
#    carries it; this script copies it.
#
# 3. IDENTITY IS THE ISSUE NUMBER, NOT THE MISSION ID (S196). Mission ids are
#    `lcars-YYYYMMDD-NNN` sequenced PER CLONE, so two laptops filing on the same
#    day mint the IDENTICAL id. Keying "is this mission already here?" on the id
#    therefore matched the WRONG mission and overwrote it — measured in S191's
#    capstone, where adopting #35 erased shipped #34's merge record. So the key
#    is the ISSUE NUMBER, the same key web/lcars_serve/remote.py has always used
#    for the same question ("the dedupe key is the ISSUE NUMBER and nothing
#    else", its rule 1). One notion of identity, two surfaces.
#
#    A colliding id is then a COLLISION, not a match — and because the id also
#    names the directory and the branch, there is nowhere honest to put the
#    newcomer. Adopt REFUSES, names both issues, and touches nothing. That is a
#    STOP SIGN, not a cure: the cure is a mission-id format that cannot collide
#    across clones, and the format is frozen for this round (escalated to the
#    captain, S196). The branch half is guarded separately, and independently of
#    the id, because two missions may carry different ids and one branch.
#
# ---------------------------------------------------------------------------
# WHY THE STAGE IS A LABEL AND NOT AN ENVELOPE FIELD
# ---------------------------------------------------------------------------
# The envelope is refreshed at exactly TWO transfer points (S188: the re-grill
# completion and Verify entry), so an envelope `stage` would be STALE mid-
# pipeline BY CONSTRUCTION — it would say `align` for a mission halfway through
# Implement. The `lcars:<stage>` label is swapped by gh_relabel at every single
# stage transition, and is already what the github board adapter treats as the
# canonical remote stage (web/lcars_serve/github_adapter.py `_stage_of`). One
# source per fact: the envelope owns identity, the label owns stage.
#
# ---------------------------------------------------------------------------
# NOTHING HALF-BUILT, EVER
# ---------------------------------------------------------------------------
# A partially-rebuilt mission dir is WORSE than none: `lcars status` would list
# it, the board would draw a card, and `lcars run` would drive a mission whose
# state is a fiction. So every read and every refusal happens first, the whole
# mission is composed in a STAGING dir, and only a complete mission is moved
# into `.git/lcars/missions/`. A refusal touches the disk not at all.
#
# Idempotent: adopting a mission that is already local — the same ISSUE, found
# wherever its directory happens to live — REFRESHES it: the spec and the
# recorded fields are brought up to date IN PLACE, and local-only artifacts
# (feedback.md, research findings, events.jsonl) are left alone. Adopting a
# DIFFERENT issue that would land on an occupied id or an occupied branch is a
# refusal, not a refresh (rule 3).
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN        the gh binary                    (default: gh)
#   LCARS_GIT_BIN       the git binary                   (default: git)
#   LCARS_HOST_ADAPTER  the forge adapter script path
#   LCARS_ISSUE_BODY_LIB / LCARS_OWNERSHIP_LIB  the sourced libraries
#   LCARS_GH_USER       the identity override (see ownership.sh)
#   LCARS_NOW           ISO stamp for a newly-created mission
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The host-integration adapter — the ONE place that speaks to a forge. It lives
# in the sibling lcars-run skill dir, the same reach approve/feedback make.
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SELF_DIR/../lcars-run/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@" </dev/null; }

die() { printf 'lcars adopt: %s\n' "$1" >&2; exit 1; }
note() { NOTES="${NOTES}  ⚠ $1"$'\n'; }
NOTES=""

# --- the S188 envelope parser: adopt's ONE import surface ------------------
# Sourced, not re-implemented. `lcars_handoff_require_v1` is the schema gate,
# `lcars_handoff_field` reads one recorded value. If this library is missing the
# verb cannot run at all — unlike the ownership library below, there is no
# degraded mode that would still be honest.
ISSUE_BODY_LIB="${LCARS_ISSUE_BODY_LIB:-$SELF_DIR/../lcars-run/issue-body.sh}"
[ -f "$ISSUE_BODY_LIB" ] || die "the handoff-envelope library is missing ($ISSUE_BODY_LIB) — reinstall LCARS (\`./install.sh\`)."
# shellcheck source=/dev/null
. "$ISSUE_BODY_LIB"

# --- S189 solo ownership --------------------------------------------------
# Adopt CLAIMS at align and REPORTS the owner at verify; it never takes a
# mission off anyone. A missing library leaves adopt unowned-but-working, the
# same degradation the write verbs take.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SELF_DIR/../lcars-run/ownership.sh}"
# shellcheck source=/dev/null
[ -f "$OWNERSHIP_LIB" ] && . "$OWNERSHIP_LIB"

# --- S196: the SHARED engine detector + the SHARED config writer -----------
# `lcars_engine_available` / `lcars_available_engines` (S195) are the ONE answer
# in LCARS to "is that CLI on this machine" — `lcars init` and the front door's
# engine picker already go through them, and a second answer here is exactly the
# duplication ADR-002 exists to prevent. The same library carries `detect_stack`,
# `detect_test_cmd`, `lcars_test_system_evidence` and the merge-preserving
# `lcars_config_merge` that `lcars init` seeds config.json with, so adopt's
# seeding (A4) is init's own detection, not a re-implementation of it.
#
# Missing library ⇒ adopt still works, degraded: no engine probe, no config
# seed, and it says so. That mirrors the ownership library's degradation, and it
# is the honest failure — refusing to rebuild a mission because a helper file is
# absent would be worse than rebuilding it and naming what is missing.
COMMON_LIB="${LCARS_COMMON_LIB:-$SELF_DIR/../lcars-init/lcars-common.sh}"
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

# shellcheck source=/dev/null
[ -f "$COMMON_LIB" ] && . "$COMMON_LIB"

# --- state.json writing ----------------------------------------------------
# S189 cured THIS file's copy of the house field writer (adopt's refresh path
# had rewritten the last field and left a trailing comma, and the viewscreen
# silently dropped the mission), and ledgered the other seven. S207 promoted
# that cured awk pass to lcars-state.sh and deleted every copy, this one
# included — so adopt's writer is now literally the same code, in one place.
# `json_escape` below stays: the handoff envelope and the event line use it.
json_escape() { # string → JSON-safe string body (no surrounding quotes)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '%s' "${s//$'\n'/\\n}"
}
json_str_of() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

# --- reading ANOTHER mission's state.json ----------------------------------
# The identity checks in section 3 read state files this adopt did not write, so
# these two readers are ANCHORED at the start of the line (state.json is one
# field per line everywhere in LCARS): a title, or any value carrying the text
# `"githubIssue":`, must never be mistaken for the field itself. Same anchoring,
# and the same reason, as `state_put`'s awk.
state_field_str() { # <state.json> <key> → the STRING value, or ""
  sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}
state_issue_of() { # <state.json> → the recorded issue number, or ""
  # `githubIssue` has been written BOTH bare and quoted over this project's life
  # — remote.py's `_as_issue` records exactly that and tolerates both, so this
  # reader does too rather than only understanding the form adopt emits.
  sed -n 's/^[[:space:]]*"githubIssue"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' \
    "$1" 2>/dev/null | head -1
}

# --- argv ------------------------------------------------------------------
ISSUE=""
OPT_ENGINE=""
OPT_ENGINE_SRC=""
OPT_XO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="${2:-}"; shift 2 ;;
    # S196 A3: the engine, chosen ON PURPOSE and without a prompt. This is how a
    # NON-INTERACTIVE adopt converts a mission onto the CLI this laptop actually
    # has — the only way it may, because the alternative (converting silently
    # because nobody was there to ask) is the defect this session is closing.
    --engine) OPT_ENGINE="${2:-}"; shift 2 ;;
    # S197: WHO decided, carried beside WHAT was decided. `--engine` alone
    # cannot tell a captain's click at the viewscreen picker from a mechanical
    # conversion — on a two-CLI laptop with no config disagreement adopt never
    # prompts, so `--engine claude` on a claude mission looks identical either
    # way and there is nothing to infer from. The caller that KNOWS a human
    # chose says so, and the card stops calling a decision nobody was asked
    # about by the same name as one he made. Only the literal `chosen`: a typo
    # must not quietly mint a provenance, because a record that can be wrong is
    # worth nothing.
    --engine-source)
      OPT_ENGINE_SRC="${2:-}"
      [ "$OPT_ENGINE_SRC" = "chosen" ] \
        || die "\`--engine-source $OPT_ENGINE_SRC\` is not something adopt can record — the only value is \`chosen\`, which means a human picked the engine. Nothing was created."
      shift 2 ;;
    # S201: the captain's answer to "engage Number One on this mission here?",
    # carried from a caller that has no tty to ask at — the board's adopt
    # picker checkbox. `yes` puts the mission IN SCOPE, `no` records the
    # per-mission opt-out. Only those two literals: a typo must not silently
    # decide who has the conn.
    --number-one)
      OPT_XO="${2:-}"
      case "$OPT_XO" in
        yes|no) : ;;
        *) die "\`--number-one $OPT_XO\` is not something adopt can record — the only values are \`yes\` and \`no\`. Nothing was created." ;;
      esac
      shift 2 ;;
    -h|--help)
      printf 'usage: adopt.sh --issue <issue-number> [--engine <claude|copilot>] [--engine-source chosen] [--number-one yes|no]\n'
      printf '  Rebuilds the mission on issue <n> locally. Works at the ENDS of the\n'
      printf '  pipeline only: align (claim + rebuild) and verify (join + resolve PR).\n'
      printf '  --engine converts the mission onto a CLI this machine has, and RECORDS\n'
      printf '  the choice; without it an unavailable engine is refused, never switched.\n'
      printf '  --engine-source chosen says a HUMAN picked that engine (the viewscreen\n'
      printf '  picker), so the card reads "chosen at adopt" and not "converted".\n'
      printf '  --number-one answers the Verify engagement question without a tty:\n'
      printf '  yes puts the mission in scope for Number One, no records an opt-out.\n'
      exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *)  ISSUE="$1"; shift ;;
  esac
done
# A provenance with no decision under it. REFUSED rather than ignored: with no
# `--engine` there is no operator choice to attribute, and both other readings
# are lies. Ignoring it lets the caller believe a human choice was recorded when
# adopt in fact took its own automatic path; honouring it would stamp "a human
# chose this" on a decision no human made. A caller that sends the provenance
# without the value is broken, and adopt says which half is missing.
[ -z "$OPT_ENGINE_SRC" ] || [ -n "$OPT_ENGINE" ] \
  || die "\`--engine-source chosen\` says a human picked the engine, but no \`--engine <name>\` came with it — there is no choice to record. Pass both, or neither. Nothing was created."
ISSUE="${ISSUE#\#}"
[ -n "$ISSUE" ] || die "no issue number — run \`lcars adopt <issue#>\` (the number of the mission's GitHub issue)."
case "$ISSUE" in *[!0-9]*) die "'$ISSUE' is not an issue number — run \`lcars adopt <issue#>\`." ;; esac

# --- where the mission will live ------------------------------------------
# `--git-dir`, matching locate_mission in run.sh / approve.sh / feedback.sh, so
# the mission adopt writes is the mission every other verb resolves.
GITDIR="$("$GIT_BIN" rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repo — run this from the clone you want the mission in."
[ -n "$GITDIR" ] || die "not inside a git repo — run this from the clone you want the mission in."
case "$GITDIR" in /*) : ;; *) GITDIR="$PWD/$GITDIR" ;; esac
MISSIONS_DIR="$GITDIR/lcars/missions"

command -v "$GH_BIN" >/dev/null 2>&1 \
  || die "gh not found — adopt reads the mission from its GitHub issue, so it needs the GitHub CLI."

# ===========================================================================
# 1. READ the issue. Nothing is written to the repo until every check passes.
# ===========================================================================
STAGING="$(mktemp -d)" || die "could not create a staging directory."
trap 'rm -rf "$STAGING"' EXIT
BODY="$STAGING/body.md"

# Normalise CRLF as the body lands. GitHub stores a body edited in its web UI
# with \r\n line endings, and a stray \r would ride into prd.md and into every
# value parsed out of the envelope's line. Only a line-terminating \r is
# removed, so a carriage return inside a fenced code block survives.
if ! host issue-body "$ISSUE" >"$STAGING/body.raw" 2>/dev/null; then
  die "could not read issue #$ISSUE from GitHub — check the number, and that \`gh\` is authenticated for this repo."
fi
awk '{ sub(/\r$/, ""); print }' "$STAGING/body.raw" >"$BODY"
[ -s "$BODY" ] || die "issue #$ISSUE has an empty body — there is nothing to rebuild the mission from."

# --- THE SCHEMA GATE. Runs before a single field is trusted. ---------------
# require_v1 says exactly what is wrong on stderr (no envelope at all vs an
# envelope from a schema this LCARS does not understand); we re-say it in this
# verb's own words so the captain reads one message, about his issue.
if ! ENVERR="$(lcars_handoff_require_v1 "$BODY" 2>&1)"; then
  case "$ENVERR" in
    *"understands"*)
      die "issue #$ISSUE carries a handoff envelope from a NEWER schema than this LCARS understands — refusing to guess at it. Update LCARS (\`lcars update\`) and adopt again." ;;
    *)
      die "issue #$ISSUE has no \`lcars:handoff\` envelope — it was filed before LCARS started writing one, so the machine facts a rebuild needs (mission id, branch, base, type, engine) are not recorded anywhere. Nothing was created. Drive this mission from the laptop that filed it, or re-file it here." ;;
  esac
fi

# --- the recorded identity facts ------------------------------------------
MID="$(lcars_handoff_field "$BODY" id)"
BRANCH="$(lcars_handoff_field "$BODY" branch)"
BASE="$(lcars_handoff_field "$BODY" base)"
TYPE="$(lcars_handoff_field "$BODY" type)"
ENGINE="$(lcars_handoff_field "$BODY" engine)"
PARENT="$(lcars_handoff_field "$BODY" parentIssue)"
ATTACH="$(lcars_handoff_field "$BODY" attachments)"
# `parked` is emitted ONLY when true (S188), so an ABSENT key means false. A
# missing line is the normal case, not a parse failure.
PARKED="$(lcars_handoff_field "$BODY" parked)"

[ -n "$MID" ] || die "the handoff envelope on issue #$ISSUE carries no mission id — without it there is no mission to rebuild (and adopt never mints a new id: the id names the branch and the issue that already exist)."
# The id becomes a directory name; refuse anything that is not one.
case "$MID" in
  */*|*..*|.|..) die "the handoff envelope on issue #$ISSUE carries an unusable mission id ('$MID')." ;;
esac
case "$ATTACH" in ''|*[!0-9]*) ATTACH=0 ;; esac

# ===========================================================================
# 2. THE STAGE — from the LABEL, the one place it is kept current.
# ===========================================================================
LABELS="$(host issue-labels "$ISSUE" 2>/dev/null)"
STAGE=""
while IFS= read -r lab; do
  case "$lab" in
    lcars:align|lcars:research|lcars:validate|lcars:plan|lcars:plan-review|lcars:schedule|lcars:implement|lcars:verify|lcars:done)
      STAGE="${lab#lcars:}"; break ;;
  esac
done <<EOF
$LABELS
EOF

[ -n "$STAGE" ] || die "issue #$ISSUE carries no \`lcars:<stage>\` label, so its stage is not recorded anywhere adopt may read — and adopt will not guess it from the issue text. Add the stage label on GitHub, then adopt again. Nothing was created."

# --- THE v1 BOUNDARY ------------------------------------------------------
case "$STAGE" in
  align|verify) : ;;
  *)
    die "mission is mid-pipeline at $STAGE; portable ends are Align and Verify. The stages between them keep their working artifacts (research findings, the plan, ticket state) on the laptop that is driving them — those are deliberately not on the issue, so a rebuild here would be a mission with its middle missing. Watch it from the board, or wait for it to reach Verify. Nothing was created." ;;
esac

# ===========================================================================
# 3. IDENTITY — WHICH local mission is this issue? (S196 A1)
# ===========================================================================
# THE DEFECT THIS REPLACES, measured in S191's live capstone (2026-09-09).
# This block used to be three lines: the mission dir was `missions/<envelope
# id>` and "already here?" was "does that dir hold a state.json?". Mission ids
# are `lcars-YYYYMMDD-NNN` sequenced PER CLONE, so two laptops filing on the
# same day mint the IDENTICAL id — and adopting the second laptop's issue then
# matched the FIRST laptop's mission, announced "(refreshed an existing local
# mission — local artifacts kept)" and OVERWROTE it in place: title,
# `githubIssue` 34→35, stage done→align, and the whole merge record (`review`,
# `prNumber`, `prUrl`) gone. A mission the captain had already SHIPPED, erased
# by a verb whose entire purpose is not to lose work.
#
# `web/lcars_serve/remote.py` has never had this bug, and says why in its own
# rule 1: "the dedupe key is the ISSUE NUMBER and nothing else". This is the
# same key, so the two surfaces answer "is this mission already local?" the same
# way. A different issue carrying a colliding mission id is a DIFFERENT MISSION
# and can never be a refresh.
MISSION_DIR=""
EXISTING=0
for _d in "$MISSIONS_DIR"/*/; do
  _d="${_d%/}"
  [ -f "$_d/state.json" ] || continue
  if [ "$(state_issue_of "$_d/state.json")" = "$ISSUE" ]; then
    MISSION_DIR="$_d"; EXISTING=1; break
  fi
done

# --- THE ID COLLISION (S196 A2, local half) --------------------------------
# Knowing WHICH mission is ours is only half of it: the id also names the
# DIRECTORY, so a colliding id means the newcomer's home is already occupied.
# `mkdir -p` + `cp` would still overwrite the incumbent — the destruction above,
# by a different route. There is no honest way to hold both under one id here
# (the id names the branch `lcars/<id>` too, so a renamed directory would still
# collide on the shared remote the moment a stage cut it). So: REFUSE, name both
# issues, and touch nothing at all — no dir, no state, no assignment.
if [ "$EXISTING" -eq 0 ]; then
  MISSION_DIR="$MISSIONS_DIR/$MID"
  if [ -f "$MISSION_DIR/state.json" ]; then
    OTHER_ISSUE="$(state_issue_of "$MISSION_DIR/state.json")"
    if [ -n "$OTHER_ISSUE" ]; then
      OTHER_TITLE="$(state_field_str "$MISSION_DIR/state.json" title)"
      die "issue #$ISSUE carries mission id '$MID', but this clone already holds a DIFFERENT mission under that id — issue #$OTHER_ISSUE${OTHER_TITLE:+ (\"$OTHER_TITLE\")}. Mission ids are sequenced per clone, so two laptops filing on the same day mint the same one; the id names the mission directory AND the branch \`lcars/$MID\`, so there is no way to keep both here without overwriting #$OTHER_ISSUE. Nothing was created and #$OTHER_ISSUE was not touched. Adopt #$ISSUE in a clone that does not hold #$OTHER_ISSUE, or retire $MISSION_DIR first."
    fi
    # No issue recorded at all: nothing is CLAIMING this directory, so it is
    # this laptop's own copy of the same mission (a `lcars file` whose gh call
    # failed leaves exactly this). Refresh it, as adopt always has.
    EXISTING=1
  fi
fi

# --- THE BRANCH COLLISION (S196 A2, the half that lives on the remote) -----
# The id guard cannot see this one: two missions may carry different ids and the
# SAME branch, and the branch is a SHARED ref, not a local directory. Adopting
# would point two local missions at one branch and hand the newcomer the other
# mission's history — which is precisely what the capstone saw when #35's adopt
# reported "local branch already here" and attached itself to #34's MERGED
# branch. Checked against what the other missions RECORD rather than against
# git's refs, so the refusal does not depend on whether this clone has fetched
# the branch yet. The mission's OWN branch is skipped, so a refresh is never
# read as a re-use of itself.
if [ -n "$BRANCH" ]; then
  for _d in "$MISSIONS_DIR"/*/; do
    _d="${_d%/}"
    [ -f "$_d/state.json" ] || continue
    [ "$_d" = "$MISSION_DIR" ] && continue
    [ "$(state_field_str "$_d/state.json" branch)" = "$BRANCH" ] || continue
    OTHER_ISSUE="$(state_issue_of "$_d/state.json")"
    [ -n "$OTHER_ISSUE" ] && [ "$OTHER_ISSUE" != "$ISSUE" ] || continue
    OTHER_TITLE="$(state_field_str "$_d/state.json" title)"
    die "issue #$ISSUE's mission records branch '$BRANCH', but that branch already belongs to this clone's mission for issue #$OTHER_ISSUE${OTHER_TITLE:+ (\"$OTHER_TITLE\")} at $_d. Adopting would point two missions at one branch and give #$ISSUE #$OTHER_ISSUE's history. Nothing was created and #$OTHER_ISSUE was not touched. Give #$ISSUE a branch of its own, or adopt it in a clone that does not hold #$OTHER_ISSUE."
  done
fi

# The LOCAL ADDRESS of the mission — the directory name, which is what every
# other verb's `locate_mission` takes as its id. Normally identical to $MID; it
# differs only for a mission whose directory was named something else before
# adopt learned to find missions by issue number. The `Next:` lines below print
# THIS, so the command they suggest is one that actually resolves.
MID_LOCAL="$(basename "$MISSION_DIR")"

# ===========================================================================
# 3b. THE ENGINE — an explicit choice, made AT THE HANDOFF. (S196 A3)
# ===========================================================================
# THE DEFECT, measured in S191's capstone with PATH shims faking both CLIs. A
# mission was filed `--engine copilot`; the envelope carried copilot; adopt wrote
# `workerBin: copilot` correctly; the adopting clone's config.json said claude —
# and run.sh's precedence put `config.json workerBin` ABOVE the mission's own
# record. Result: 3 invocations of the BILLED shim, 0 of the free one, and not a
# word anywhere. The spend was the only symptom. (Meanwhile `lcars approve`
# already pinned the mission's engine by exporting $LCARS_WORKER_BIN — two paths,
# two answers, which is how a thing like this survives.)
#
# THE CAPTAIN'S RULING (2026-09-09) is NOT "the mission always wins". A laptop
# may only have ONE CLI installed, and a mission that can never run here is not a
# handover. It is ASK AND CONVERT:
#
#   • the mission's engine IS here            → use it, and SAY so.
#   • it is here and the local config DISAGREES → ASK, defaulting to the
#     mission's. The config is this repo's ambient preference; the mission is
#     another laptop's deliberate act, and neither should silently beat the other.
#   • it is NOT here                          → ASK which of the engines this
#     machine actually has should take over, and RECORD the conversion.
#   • no tty and no `--engine`                → REFUSE, loudly, naming both the
#     engine the mission wants and the ones this machine has. Never switch in
#     silence: a silent switch IS the defect; a loud failure is the cure.
#
# The answer is RECORDED (workerBin + engineSource + engineResolved) and from
# here on OUTRANKS config.json — run.sh's precedence was reversed in the same
# session, because an engine the captain was asked about that a repo default
# could then overrule would make the asking theatre.
#
# RECORDED AT THE MOMENT OF CHOICE, never re-derived. Nothing later re-reads
# config.json to work out which source "would have" won — that inference is the
# mistake S147, S156 and S188 each paid fix rounds for, and it is this round's
# standing pre-flight rule: the producer records.
#
# THE PROBE IS `command -v`, THROUGH THE SHARED DETECTOR, and deliberately
# nothing cleverer. lcars-common.sh says why in its own words: no `--version`
# spawn per engine, and no `~/.claude` / `~/.copilot` directory sniffing (run.sh's
# host detection explicitly refuses that signal as a launch marker). One detector,
# so the front door's engine picker, `lcars init` and adopt can never disagree
# about what this machine has. It answers PRESENCE; a CLI that is installed but
# not signed in fails at its first spawn with its own error, which is a better
# message than any guess adopt could make — and probing auth for real would mean
# a network round trip on a verb that is meant to be instant.

# Is this engine on THIS machine? Known ids go through the shared detector; a
# custom binary name (a wrapper script, a pinned path) is checked as itself.
# WITHOUT the shared library it falls back to a bare `command -v` on the engine's
# own name. That is not a second answer to the question — it IS the shared
# detector's answer, minus the $LCARS_CLAUDE_BIN / $LCARS_COPILOT_BIN seams it
# resolves the name through. The fallback exists because the alternative is
# worse: with `lcars_engine_available` undefined, every engine would read as
# ABSENT and a non-interactive adopt would refuse a mission it could perfectly
# well have run — a missing helper file turning into a hard refusal.
engine_here() { # <engine-or-bin>
  [ -n "${1:-}" ] || return 1
  case "$1" in
    claude|copilot)
      if command -v lcars_engine_available >/dev/null 2>&1; then
        lcars_engine_available "$1"
      else
        command -v "$1" >/dev/null 2>&1
      fi ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
engines_here() { # → the installed engines, one per line
  if command -v lcars_available_engines >/dev/null 2>&1; then
    lcars_available_engines; return 0
  fi
  local e
  for e in claude copilot; do
    command -v "$e" >/dev/null 2>&1 && printf '%s\n' "$e"
  done
  return 0
}
engines_here_line() { engines_here | tr '\n' ' ' | sed 's/ *$//'; }

# A tty, or a test standing in for one. `LCARS_ASSUME_TTY=1` exists because the
# PROMPT is the behaviour under test here and a suite has no terminal; it forces
# the interactive branch to read from stdin. It is a seam, not a policy: without
# it the rule is exactly `[ -t 0 ]`.
ADOPT_TTY=0
{ [ -t 0 ] || [ "${LCARS_ASSUME_TTY:-}" = "1" ]; } && ADOPT_TTY=1

ENGINE_CHOSEN=""
ENGINE_SRC=""
CONFIG="$GITDIR/lcars/config.json"
CFG_ENGINE=""
if [ -f "$CONFIG" ] && command -v lcars_config_get >/dev/null 2>&1; then
  CFG_ENGINE="$(lcars_config_get "$CONFIG" workerBin)"
fi

# The prompt. Prints to STDERR so the readout on stdout stays machine-clean, and
# an empty answer takes the default (the mission's engine, per the ruling).
ask_engine() { # <default> <candidates…>  → the answer on stdout
  local def="$1"; shift
  local ans=""
  printf '  Which engine should drive this mission here? [%s] (%s): ' \
    "$def" "$*" >&2
  read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
  [ -n "$ans" ] || ans="$def"
  printf '%s' "$ans"
}

if [ -n "$OPT_ENGINE" ]; then
  # An explicit operator act. It is still checked against this machine: recording
  # an engine that is not here would hand the captain a mission whose first stage
  # dies in a spawn log.
  OPT_ENGINE="$(basename "$OPT_ENGINE")"
  engine_here "$OPT_ENGINE" \
    || die "\`--engine $OPT_ENGINE\` was asked for, but $OPT_ENGINE is not on this machine$( [ -n "$(engines_here_line)" ] && printf ' (installed: %s)' "$(engines_here_line)"). Nothing was created."
  ENGINE_CHOSEN="$OPT_ENGINE"
  if [ -n "$ENGINE" ] && [ "$OPT_ENGINE" = "$(basename "$ENGINE")" ]; then
    ENGINE_SRC="adopt-kept"
  else
    ENGINE_SRC="adopt-converted"
  fi
  # …unless the caller RECORDED that a human chose it. kept/converted describe
  # what the flag did to the mission's pin; `chosen` describes who decided, and
  # that is the more specific truth, so it wins. The readout's `adopt-chosen`
  # case and the board's "chosen at adopt" label already exist for it.
  [ "$OPT_ENGINE_SRC" = "chosen" ] && ENGINE_SRC="adopt-chosen"
elif [ -z "$ENGINE" ]; then
  # `engine: null` in the envelope means the filing laptop deliberately made NO
  # pin and host-detection is legitimately in charge (S188). Inventing one here
  # would be adopt deciding something nobody decided. Leave it absent.
  :
elif engine_here "$ENGINE"; then
  if [ -n "$CFG_ENGINE" ] && [ "$CFG_ENGINE" != "$ENGINE" ] && engine_here "$CFG_ENGINE"; then
    if [ "$ADOPT_TTY" -eq 1 ]; then
      printf '  This mission was filed on %s; this repo'"'"'s config.json prefers %s. Both are installed here.\n' \
        "$ENGINE" "$CFG_ENGINE" >&2
      ENGINE_CHOSEN="$(ask_engine "$ENGINE" "$ENGINE" "$CFG_ENGINE")"
      engine_here "$ENGINE_CHOSEN" \
        || die "'$ENGINE_CHOSEN' is not an engine this machine has (installed: $(engines_here_line)). Nothing was created."
      ENGINE_SRC="adopt-chosen"
    else
      # No one to ask: the ruling's non-interactive rule is "use the mission's
      # engine if it is available", so the mission wins — but the disagreement is
      # NAMED rather than resolved behind the captain's back.
      ENGINE_CHOSEN="$ENGINE"
      ENGINE_SRC="adopt-kept"
      note "this repo's config.json prefers $CFG_ENGINE, but the mission was filed on $ENGINE and $ENGINE is installed here — the MISSION's engine takes over, and it now outranks config.json. Re-run with \`--engine $CFG_ENGINE\` to convert it on purpose."
    fi
  else
    ENGINE_CHOSEN="$ENGINE"
    ENGINE_SRC="adopt-kept"
  fi
else
  # NOT HERE. Ask, or refuse — never convert in silence.
  AVAIL_LINE="$(engines_here_line)"
  if [ -z "$AVAIL_LINE" ]; then
    die "this mission runs on $ENGINE, which is not on this machine — and neither is any other engine LCARS drives (claude, copilot). Install one and adopt again. Nothing was created."
  fi
  if [ "$ADOPT_TTY" -eq 1 ]; then
    printf '  This mission was filed on %s, which is NOT installed on this machine.\n' "$ENGINE" >&2
    printf '  Installed here: %s\n' "$AVAIL_LINE" >&2
    DEF_ENGINE="$(printf '%s' "$AVAIL_LINE" | awk '{print $1}')"
    [ -n "$CFG_ENGINE" ] && engine_here "$CFG_ENGINE" && DEF_ENGINE="$CFG_ENGINE"
    ENGINE_CHOSEN="$(ask_engine "$DEF_ENGINE" $AVAIL_LINE)"
    engine_here "$ENGINE_CHOSEN" \
      || die "'$ENGINE_CHOSEN' is not an engine this machine has (installed: $AVAIL_LINE). Nothing was created."
    ENGINE_SRC="adopt-converted"
  else
    die "this mission runs on $ENGINE, which is not on this machine (installed here: $AVAIL_LINE) — and there is no terminal to ask on. Adopt will NOT switch a mission's engine in silence: that is how a copilot mission ends up billed to claude with no warning. Re-run with \`--engine <one of: $AVAIL_LINE>\` to convert it on purpose, or adopt from a laptop that has $ENGINE. Nothing was created and nothing was recorded."
  fi
fi

# ===========================================================================
# 3b. COMPOSE the mission — in staging, entirely.
# ===========================================================================
TITLE="$(host issue-title "$ISSUE" 2>/dev/null | head -1)"
[ -n "$TITLE" ] || TITLE="$MID"

# --- the spec: the body, minus its envelope -------------------------------
# The LAST envelope is the real one (it is APPENDED, so anything above it is
# prose — a PRD may legitimately QUOTE an envelope, and `lcars_ib_scan` already
# resolves that the same way). Only that one line is removed, plus the blank
# line the composer puts above it. Everything else is kept byte-for-byte: see
# the header for why adopt does not try to find where the PRD ends.
awk '
  { line[NR] = $0; if (index($0, "<!-- lcars:handoff ") > 0) last = NR }
  END {
    n = NR
    if (last > 0) {
      n = last - 1
      while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--
    }
    for (i = 1; i <= n; i++) print line[i]
  }
' "$BODY" >"$STAGING/spec.md"

# A PARKED mission has NO PRD yet — its body is the captain's raw idea plus the
# STANDBY note, and `prdPending` is what tells `lcars file <id>` to run the
# grill. Writing that text as prd.md would tell the whole pipeline a PRD exists.
# So it lands as idea.md, exactly where the park lane put it, INCLUDING the
# standby note: separating the two would mean scanning the prose for a boundary
# nothing records.
SPEC_NAME="prd.md"
[ "$PARKED" = "true" ] && SPEC_NAME="idea.md"

# --- state.json -----------------------------------------------------------
# S201 — NUMBER ONE IS DISMISSED BY AN ADOPT, ALWAYS.
#
# Engagement is a fact about ONE LAPTOP: a first officer running there, holding
# that laptop's conn, with a worker pid recorded in that mission directory. A
# mission adopted HERE has none of that — no process, no pid, nothing to stand
# down — so a `numberOne` key carried across would be a badge for an officer who
# is not aboard, locking the controls of a mission nobody is driving.
#
# Read BEFORE the rebuild, because the rebuild is what removes it.
XO_WAS=""
if [ "$EXISTING" -eq 1 ] && [ -f "$MISSION_DIR/state.json" ]; then
  XO_WAS="$(sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{[^}]*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
              "$MISSION_DIR/state.json" | head -1)"
fi
STATE="$STAGING/state.json"
if [ "$EXISTING" -eq 1 ]; then
  # REFRESH, never duplicate. Edit a COPY: the real file is only replaced once
  # the whole rebuild has succeeded, and every local-only field on it (an
  # estimate's modelOverride, baseSha, attachments paths) survives untouched.
  cp "$MISSION_DIR/state.json" "$STATE" 2>/dev/null || die "could not read the existing mission at $MISSION_DIR."
  lcars_state_set_string "$STATE" id "$MID"
  lcars_state_set_string "$STATE" title "$TITLE"
  lcars_state_set_string "$STATE" stage "$STAGE"
  lcars_state_set_string "$STATE" branch "$BRANCH"
  lcars_state_set_string "$STATE" base "$BASE"
  lcars_state_set "$STATE" githubIssue "$ISSUE"
  [ -n "$TYPE" ]   && lcars_state_set_string "$STATE" type "$TYPE"
  # S196 A3 — the engine RESOLVED at this handoff, not the envelope's raw value:
  # they differ exactly when the captain converted it, and the converted one is
  # the fact that must be recorded (see section 3b).
  if [ -n "$ENGINE_CHOSEN" ]; then
    lcars_state_set_string "$STATE" workerBin     "$ENGINE_CHOSEN"
    lcars_state_set_string "$STATE" engineResolved "$ENGINE_CHOSEN"
    lcars_state_set_string "$STATE" engineSource   "$ENGINE_SRC"
  fi
  case "$PARENT" in ''|null) lcars_state_unset "$STATE" parentIssue ;; *) lcars_state_set "$STATE" parentIssue "$PARENT" ;; esac
  if [ "$PARKED" = "true" ]; then lcars_state_set "$STATE" prdPending true; else lcars_state_unset "$STATE" prdPending; fi
  # A mission that is back at ALIGN has no open PR — `lcars feedback` closes the
  # PR when it bounces one, and Verify opens a FRESH one on the way back. So a
  # prUrl left over from this laptop's earlier copy of the mission is stale by
  # the label's own account, and keeping it would make `lcars run` believe a PR
  # is already open. The stage is the recorded fact; these follow it.
  if [ "$STAGE" = "align" ]; then
    lcars_state_unset "$STATE" prUrl; lcars_state_unset "$STATE" prNumber; lcars_state_unset "$STATE" review
  fi
  # …and Number One, at EVERY stage. Unlike the PR fields above this is not a
  # fact that goes stale at one stage and holds at another — it is stale the
  # moment the mission changes laptops, so it goes unconditionally.
  lcars_state_unset "$STATE" numberOne
else
  MODEL=""
  # $CONFIG was resolved in section 3b (the engine block reads workerBin from it).
  [ -f "$CONFIG" ] && MODEL="$(json_str_of "$CONFIG" model)"
  [ -n "$MODEL" ] || MODEL="${LCARS_MODEL:-claude-sonnet}"
  # Field order mirrors file.sh's write_state so an adopted mission and a filed
  # one read the same way in a diff. Optional fields are OMITTED rather than
  # emitted empty — an absent key is what "not recorded" looks like everywhere
  # else in LCARS, and an empty string would read as a real value.
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$(json_escape "$MID")"
    [ -n "$TYPE" ] && printf '  "type": "%s",\n' "$(json_escape "$TYPE")"
    printf '  "title": "%s",\n' "$(json_escape "$TITLE")"
    printf '  "stage": "%s",\n' "$STAGE"
    [ "$PARKED" = "true" ] && printf '  "prdPending": true,\n'
    printf '  "created": "%s",\n' "$NOW"
    printf '  "adopted": "%s",\n' "$NOW"
    printf '  "model": "%s",\n' "$(json_escape "$MODEL")"
    if [ -n "$ENGINE_CHOSEN" ]; then
      printf '  "workerBin": "%s",\n'      "$(json_escape "$ENGINE_CHOSEN")"
      printf '  "engineResolved": "%s",\n' "$(json_escape "$ENGINE_CHOSEN")"
      printf '  "engineSource": "%s",\n'   "$(json_escape "$ENGINE_SRC")"
    fi
    case "$PARENT" in ''|null) : ;; *) printf '  "parentIssue": %s,\n' "$PARENT" ;; esac
    printf '  "githubIssue": %s,\n' "$ISSUE"
    printf '  "branch": "%s",\n' "$(json_escape "$BRANCH")"
    printf '  "base": "%s"\n' "$(json_escape "$BASE")"
    printf '}\n'
  } >"$STATE"
  # BOTH PATHS, on purpose. This one writes the object field by field and could
  # not emit `numberOne` if it tried — which is exactly why the guard belongs
  # here too: the day somebody adds a field to that heredoc, the rule is already
  # written down beside it instead of living in one branch of an if.
  lcars_state_unset "$STATE" numberOne
fi

# ===========================================================================
# 4. OWNERSHIP — claim at Align, report at Verify. Never take it off anyone.
# ===========================================================================
ME=""; OWNER=""
command -v lcars_whoami     >/dev/null 2>&1 && ME="$(lcars_whoami 2>/dev/null)"
command -v mission_owner    >/dev/null 2>&1 && OWNER="$(mission_owner "$ISSUE" 2>/dev/null)"

if [ -n "$OWNER" ] && [ -n "$ME" ] && [ "$OWNER" != "$ME" ]; then
  # Someone else holds it. A LOOK is never blocked — the rebuild continues — but
  # adopt does not assign itself alongside them: reassignment is a human act on
  # GitHub, which is the whole premise of the solo protocol, and the write verbs
  # will refuse here until it happens.
  note "assigned to $OWNER — reassign it to yourself on GitHub to take command. Until then this laptop can look, not act."
elif [ "$STAGE" = "align" ]; then
  # Align is where the work is picked UP, so adopt claims it. Best-effort: a
  # forge that will not take the assignment warns and never blocks the rebuild.
  if command -v lcars_claim_mission >/dev/null 2>&1; then
    if ! claim_warn="$(lcars_claim_mission "$ISSUE" 2>/dev/null)"; then
      [ -n "$claim_warn" ] && NOTES="${NOTES}${claim_warn}"$'\n'
    fi
  fi
  [ -n "$ME" ] && OWNER="$ME"
fi

# ===========================================================================
# 5. AT VERIFY — resolve the OPEN PR, so approve/feedback work immediately.
# ===========================================================================
PR_URL=""; PR_NUM=""
if [ "$STAGE" = "verify" ]; then
  prline="$(host issue-closing-prs "$ISSUE" 2>"$STAGING/pr.err" | head -1)"
  if [ -n "$prline" ]; then
    PR_NUM="${prline%%	*}"
    PR_URL="${prline#*	}"
    case "$PR_URL" in
      http*|*/pull/*) : ;;
      *) PR_URL=""; PR_NUM="" ;;
    esac
  fi
  if [ -n "$PR_URL" ]; then
    lcars_state_set_string "$STATE" prUrl "$PR_URL"
    # prNumber is a STRING, matching the ONE existing writer — pr-lib.sh:217,
    # which run.sh's Verify auto-open goes through. S189 fix round 1, defect 2:
    # adopt first wrote it as a bare NUMBER, so the same PR had a different JSON
    # TYPE on the two laptops and the two state.json files were not
    # interchangeable to a real JSON reader. Interchangeability IS the contract
    # this verb exists to deliver, so adopt matches the incumbent rather than
    # being unilaterally more correct in one of two writers. (Both readers —
    # approve.sh:369 and run.sh's drive_pr_merged — use a BARE-TOKEN reader that
    # returns "" for the quoted form and falls back to resolving the PR by
    # `--head <branch>`, which is the same fallback the driving laptop relies on
    # today. Upgrading BOTH writers to a number together is LEDGERED.)
    case "$PR_NUM" in ''|*[!0-9]*) : ;; *) lcars_state_set_string "$STATE" prNumber "$PR_NUM" ;; esac
    # The same in-review sub-state the driving laptop records when Verify opens
    # the PR (run.sh cmd_open_pr), so the board reads "in review — PR open".
    lcars_state_set_string "$STATE" review open
  else
    # Failure mode 11: an empty answer means "no PR" AND "the only PR is
    # closed-unmerged", indistinguishably, and adopt does not pretend to know
    # which. It says what it saw.
    note "no open PR resolves to #$ISSUE — either Verify has not opened one yet, or the one it opened was closed without merging. \`lcars approve\` will refuse until a PR is open; re-run adopt once it is."
  fi
  # Surface the fallback's own caveat if the adapter had to use it.
  if [ -s "$STAGING/pr.err" ] && grep -q 'scanning the' "$STAGING/pr.err" 2>/dev/null; then
    note "this \`gh\` could not answer GitHub's closing-PR query, so the PR was resolved by scanning open PR bodies — a PR linked without a \`Closes #$ISSUE\` line would have been missed."
  fi
fi

# ===========================================================================
# 5b. NUMBER ONE — dismissed, and (at Verify) offered.
# ===========================================================================
# TWO SEPARATE FACTS, and conflating them is the mistake this section is shaped
# to avoid.
#
# THE DISMISSAL IS UNCONDITIONAL and has already happened (the state rebuild
# above). It is not a choice and it is not reversible by answering a question:
# the officer who held this mission is on another laptop and this one cannot
# reach it. All that is left is to SAY SO, because a badge that vanishes without
# a word is a fact the captain has to discover.
#
# THE OFFER IS THIS REPO'S OWN. Number One being on HERE is a different setting
# from Number One having been engaged THERE, and it is asked only where there is
# something to answer it about: `numberOne.enabled` in this repo's config, and a
# mission at VERIFY — the gate an adopting captain has actually arrived at. At
# Align there is nothing for a first officer to do yet, so asking would be
# furniture.
#
# NOTHING IS ENGAGED HERE, AND NOTHING IS RECORDED HERE. `yes` puts the mission
# IN SCOPE (its opt-out is gone with the rest of the block); taking the conn is
# the driver's to do at a gate, and a second way in would be exactly the
# duplication this round exists to prevent. NO TTY IS `no` — the same posture
# the engine picker takes one section up, for the same reason: deciding in
# silence is the defect.
#
# AND `no` LEAVES THE KEY ABSENT (fix round 1). It used to write
# `numberOne: {"optOut": true}`, which made every SILENT adopt — scripted, from
# the board, from any caller with no tty — opt that mission out of a later
# repo-wide `lcars xo on` permanently, until someone ran `lcars xo on <id>` by
# hand. Declining at the prompt is "not engaged NOW", and that is already the
# state every fresh mission is in; a durable opt-out is a larger answer, and
# only `lcars xo off <id>` gives it. The DISCLOSURE still prints — the captain
# is told where he stands — but the record is exactly what a fresh adopt
# writes: no `numberOne` key at all (the additive-key rule, S109).
XO_LINES=""
if [ -n "$XO_WAS" ] && [ "$XO_WAS" = "engaged" ]; then
  XO_LINES="  ${OWNER:-the previous owner}'s Number One was dismissed by this adopt"$'\n'
fi

CFG_XO_ENABLED=""
if [ -f "$CONFIG" ]; then
  case "$(sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$CONFIG" | head -1)" in
    *'"enabled"'*true*) CFG_XO_ENABLED=1 ;;
  esac
fi

if [ -n "$CFG_XO_ENABLED" ] && [ "$STAGE" = "verify" ]; then
  XO_ANSWER="$OPT_XO"
  if [ -z "$XO_ANSWER" ]; then
    if [ "$ADOPT_TTY" -eq 1 ]; then
      printf '  Number One is ON for this repo. Engage Number One on this mission now? [y/N]: ' >&2
      read -r xo_ans || xo_ans=""
      case "$(printf '%s' "$xo_ans" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
        y|yes) XO_ANSWER="yes" ;;
        *)     XO_ANSWER="no" ;;
      esac
    else
      XO_ANSWER="no"
    fi
  fi
  if [ "$XO_ANSWER" = "yes" ]; then
    XO_LINES="${XO_LINES}  Number One: in scope for this mission — it takes the conn at the next gate"$'\n'
  else
    XO_LINES="${XO_LINES}  Number One: NOT engaged on this mission (\`lcars xo on $MID_LOCAL\` puts it back in scope)"$'\n'
  fi
fi

# ===========================================================================
# 6. PUBLISH — the whole mission, at once. Up to here the repo is untouched.
# ===========================================================================
# S207 fix round 1 (D2): the refresh path above edits a STAGING COPY of an
# existing state.json, and the writer now REFUSES a state.json it will not
# touch. Publishing a staging copy whose edits were refused would move a
# STALE file over the real one and call it an adoption. Ask before the repo is
# touched at all — this is still the "up to here the repo is untouched" point.
lcars_state_refusal_die "lcars adopt"
mkdir -p "$MISSION_DIR" || die "could not create $MISSION_DIR."
cp "$STAGING/spec.md" "$MISSION_DIR/$SPEC_NAME" || die "could not write $MISSION_DIR/$SPEC_NAME."
cp "$STATE" "$MISSION_DIR/state.json" || die "could not write $MISSION_DIR/state.json."

[ "$ATTACH" -gt 0 ] 2>/dev/null && note "the original mission had $ATTACH attachment(s); GitHub has no API to carry issue assets, so they are NOT here. Copy them into $MISSION_DIR/attachments/ by hand if a stage needs them."

# ===========================================================================
# 6b. THE REPO ITSELF — seed a config a mission can actually be DRIVEN with.
# ===========================================================================
# S196 A4. An adopted clone had NO `.git/lcars/config.json` at all: no
# testCommand, so the Implement red gate has nothing to run and degrades to a
# warning; no stack, so no stage knows the ecosystem. Adopt DID emit a warning
# and the board's ADOPT dispatch swallowed it, showing only "Adopted #34 — it is
# a local mission now." A warning nobody sees is not a warning, so both halves
# are fixed: adopt seeds, and the daemon surfaces what adopt says.
#
# IT IS `lcars init`'S OWN DETECTION, NOT A SECOND COPY OF IT. `detect_stack`,
# `detect_test_cmd`, `lcars_test_system_evidence` and the merge-preserving
# `lcars_config_merge` all live in lcars-common.sh precisely so init, update,
# status and the daemon cannot drift; adopt calls the same four. What it does
# NOT do is run `lcars init`: init creates the GitHub label set, writes
# .gitignore rules, and — as of S195 — DIES on a machine without the claude CLI,
# which is exactly the copilot-only laptop this session exists to serve. So adopt
# seeds the minimum a drive needs and points at init for the rest.
#
# S183's provenance rule is honoured because it lives inside the shared
# detectors: a DETECTED command is dropped when the repo carries no positive
# evidence of a test system, so adopt can configure a test system a repo already
# has and can never manufacture one. A repo where nothing is detectable gets a
# config with a null testCommand and a WARNING naming it — never a fabricated
# `npm test`.
if [ ! -f "$CONFIG" ]; then
  if command -v lcars_config_merge >/dev/null 2>&1 \
     && command -v detect_stack >/dev/null 2>&1; then
    # detect_test_cmd / detect_worktree_setup_cmd read $TOPLEVEL from the caller's
    # environment — the same contract init.sh gives them.
    TOPLEVEL="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
    [ -n "$TOPLEVEL" ] || TOPLEVEL="$PWD"
    export TOPLEVEL
    SEED_STACK="$(detect_stack 2>/dev/null)"
    case "$SEED_STACK" in
      ''|ambiguous*) SEED_TESTCMD="${LCARS_TEST_CMD:-}" ;;
      *)             SEED_TESTCMD="${LCARS_TEST_CMD:-$(detect_test_cmd 2>/dev/null)}" ;;
    esac
    if [ -n "$SEED_TESTCMD" ] && [ -z "${LCARS_TEST_CMD:-}" ] \
       && command -v lcars_test_system_evidence >/dev/null 2>&1 \
       && ! lcars_test_system_evidence >/dev/null 2>&1; then
      SEED_TESTCMD=""
    fi
    SEED_TESTCMD_JSON='null'
    [ -n "$SEED_TESTCMD" ] && SEED_TESTCMD_JSON="\"$(json_escape "$SEED_TESTCMD")\""
    SEED_WT='null'
    if command -v detect_worktree_setup_cmd >/dev/null 2>&1; then
      SEED_WT_RAW="$(detect_worktree_setup_cmd 2>/dev/null)"
      [ -n "$SEED_WT_RAW" ] && SEED_WT="\"$(json_escape "$SEED_WT_RAW")\""
    fi
    SEED_MODEL="${LCARS_MODEL:-claude-sonnet}"
    # S207 — STAMP WHAT WE SEED. Without `lcarsVersion` the config adopt had
    # just written read as "initialized but never stamped", which
    # skills/lcars-version/check.sh reports as REPO_PREDATES: every verb printed
    # "⚠ this repo predates LCARS versioning — run `lcars update`" until the
    # captain ran an update that had nothing to do — a nag LCARS aimed at itself,
    # on a config LCARS wrote minutes earlier. The version comes from
    # lcars-common.sh's `lcars_running_version` (init's and update's stamper,
    # shared there by this session), and an unresolvable version OMITS the key
    # rather than seeding a bogus stamp. Only the SEED path stamps: a config that
    # already exists keeps whatever stamp it has, because an older repo's "needs
    # lcars update" is TRUE and adopt is not an update.
    SEED_VERSION_LINE=""
    if command -v lcars_running_version >/dev/null 2>&1; then
      SEED_VERSION="$(lcars_running_version)"
      [ -n "$SEED_VERSION" ] && SEED_VERSION_LINE="
lcarsVersion=\"$(json_escape "$SEED_VERSION")\""
    fi
    mkdir -p "$GITDIR/lcars"
    lcars_config_merge "$CONFIG" "model=\"$(json_escape "$SEED_MODEL")\"
projectName=\"$(json_escape "$(basename "$TOPLEVEL")")\"
contextFile=null
stack=\"$(json_escape "${SEED_STACK:-unknown}")\"
testCommand=$SEED_TESTCMD_JSON
worktreeSetupCommand=$SEED_WT
comprehensionBudget=1200
adoptedFrom=$ISSUE$SEED_VERSION_LINE
created=\"$NOW\""
    if [ -n "$SEED_TESTCMD" ]; then
      note "this clone had no .git/lcars/config.json — one was seeded (stack: ${SEED_STACK:-unknown}, testCommand: $SEED_TESTCMD). Run \`lcars init\` to finish setup (GitHub labels, .gitignore)."
    else
      note "this clone had no .git/lcars/config.json — one was seeded (stack: ${SEED_STACK:-unknown}) but NO testCommand could be detected, so the Implement red gate has nothing to prove against. Set it with \`lcars update --test-command '<command>'\`, and run \`lcars init\` to finish setup."
    fi
  else
    note "this repo is not initialised for LCARS (no .git/lcars/config.json) and adopt could not reach its config helpers — run \`lcars init\` before driving the mission."
  fi
fi

# ===========================================================================
# 6c. THE ESTIMATE — carried across, so the card does not downgrade. (S196 A5)
# ===========================================================================
# A REMOTE card shows a cost pill and two difficulty pills; adopting it used to
# make all three vanish, because adopt rebuilt prd.md + state.json and nothing
# else. That is a visible LOSS at the exact moment the captain takes ownership.
#
# The three facts come from the ENVELOPE (issue-body.sh now records them there),
# NEVER from re-scanning the "## Estimate" section: adopt does not read the
# captain's prose, for the reason stated at the top of this file, and behaviour
# P1 in the suite hands it a PRD quoting a decoy envelope to keep it honest.
#
# The PILL facts AND the per-stage MODEL MAP are rebuilt; the token/request
# tables stay on the laptop that computed them (`.git/lcars/` is the local source
# of richness — nothing here starts syncing internal artifacts, and nothing
# downstream reads those tables).
#
# THE MODEL MAP IS WHY THIS BLOCK WAS ONLY HALF-RIGHT WHEN IT SHIPPED. The
# comment that stood here called a `models`-less estimate.json "safe downstream:
# resolve_stage_model reads `models`, finds none, and emits the legacy
# no-`--model` argv". A tester on two genuinely cold clones measured that it is
# not safe — it is a SILENT DIVERGENCE: the laptop that filed the mission spawned
# `claude … --model sonnet` and this one spawned `claude …` with no `--model` at
# all, and the board's `modelMix` was `[]` here and six rows there. Same mission,
# two model policies.
#
# The tiers are READ OUT of the envelope's recorded `estModels` field and written
# back verbatim. They are NEVER recomputed from the two criticalities: that is an
# inference, and an inference at the adopting end drifts from what the filing
# laptop's estimator actually chose. Same rule as the prose (R9), one layer down.
#
# A LOCAL estimate.json is never overwritten. Local artifacts survive a refresh
# — the same rule feedback.md, research findings and events.jsonl live by — and
# a locally COMPUTED estimate is strictly richer than the three carried facts.
if [ ! -f "$MISSION_DIR/estimate.json" ]; then
  EST_UNIT="$(lcars_handoff_field "$BODY" estCostUnit)"
  EST_LOW="$(lcars_handoff_field "$BODY" estCostLow)"
  EST_HIGH="$(lcars_handoff_field "$BODY" estCostHigh)"
  EST_REASON="$(lcars_handoff_field "$BODY" estReasoning)"
  EST_IMPL="$(lcars_handoff_field "$BODY" estImpl)"
  EST_MODELS="$(lcars_handoff_field "$BODY" estModels)"
  case "$EST_UNIT"   in usd|premiumRequests) : ;; *) EST_UNIT="" ;; esac
  case "$EST_REASON" in low|medium|high) : ;; *) EST_REASON="" ;; esac
  case "$EST_IMPL"   in low|medium|high) : ;; *) EST_IMPL="" ;; esac
  case "$EST_LOW"    in ''|*[!0-9.]*) EST_LOW="" ;; esac
  case "$EST_HIGH"   in ''|*[!0-9.]*) EST_HIGH="" ;; esac
  [ -n "$EST_LOW$EST_HIGH" ] || EST_UNIT=""

  # `estModels` is `key=tier,key=tier…` in the estimate's own stage order. Each
  # pair is re-validated HERE too — the producer validates on the way out, and a
  # consumer that trusts a field because the producer promised to is exactly how
  # an issue body anyone can edit becomes an injection. A pair that fails is
  # dropped; the surviving pairs still carry.
  # One pair per line (a here-string, NOT a pipe: a `while` on the right of a
  # pipe runs in a subshell and MODELS_JSON would come back empty), and the
  # global IFS is never touched.
  MODELS_JSON=""
  if [ -n "$EST_MODELS" ]; then
    _msep=""
    while IFS= read -r _pair; do
      case "$_pair" in *=*) : ;; *) continue ;; esac
      _mk="${_pair%%=*}"; _mv="${_pair#*=}"
      case "$_mk" in ''|*[!A-Za-z0-9_]*) continue ;; esac
      case "$_mv" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      MODELS_JSON="$MODELS_JSON$_msep    \"$_mk\": \"$_mv\""
      _msep=$',\n'
    done <<<"$(printf '%s' "$EST_MODELS" | tr ',' '\n')"
  fi

  if [ -n "$EST_UNIT$EST_REASON$EST_IMPL$MODELS_JSON" ]; then
    {
      printf '{\n'
      printf '  "schemaVersion": 3,\n'
      printf '  "adoptedFrom": %s,\n' "$ISSUE"
      [ -n "$EST_REASON" ] && printf '  "reasoningCriticality": "%s",\n' "$EST_REASON"
      [ -n "$EST_IMPL" ]   && printf '  "implCriticality": "%s",\n' "$EST_IMPL"
      # Same key name, same shape and same position as the canonical estimate.json
      # run.sh writes, so resolve_stage_model's `models.<key>` read and the
      # board's model_mix_from_estimate see no difference between an adopted
      # estimate and a locally computed one.
      [ -n "$MODELS_JSON" ] && printf '  "models": {\n%s\n  },\n' "$MODELS_JSON"
      if [ -n "$EST_UNIT" ]; then
        printf '  "cost": {\n'
        printf '    "unit": "%s",\n' "$EST_UNIT"
        printf '    "%s": {\n' "$EST_UNIT"
        if [ -n "$EST_LOW" ] && [ -n "$EST_HIGH" ]; then
          printf '      "low": %s,\n      "high": %s\n' "$EST_LOW" "$EST_HIGH"
        elif [ -n "$EST_LOW" ]; then
          printf '      "low": %s\n' "$EST_LOW"
        else
          printf '      "high": %s\n' "$EST_HIGH"
        fi
        printf '    }\n  },\n'
      fi
      # A trailing key with no comma, so the object is valid whichever of the
      # optional blocks above were emitted.
      printf '  "carriedByAdopt": true\n'
      printf '}\n'
    } >"$MISSION_DIR/estimate.json"
  fi
fi

# ===========================================================================
# 7. THE BRANCH — fetch it when origin has one.
# ===========================================================================
# `ls-remote` first, so "the branch does not exist yet" (the normal Align case)
# is a fact we report rather than a fetch error we swallow. A local branch is
# created to track it because `lcars approve` PUSHES $BRANCH before merging —
# without one, the ship would fail on a missing refspec.
BRANCH_NOTE="not on origin yet — the first stage that needs it will cut it"
if [ -n "$BRANCH" ]; then
  if "$GIT_BIN" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    if "$GIT_BIN" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
      BRANCH_NOTE="fetched from origin"
      if ! "$GIT_BIN" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1; then
        if "$GIT_BIN" branch --quiet "$BRANCH" "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
          BRANCH_NOTE="fetched from origin (local branch created)"
        fi
      else
        BRANCH_NOTE="fetched from origin (local branch already here)"
      fi
    else
      BRANCH_NOTE="on origin, but the fetch failed — run \`git fetch origin $BRANCH\` by hand"
    fi
  fi
else
  BRANCH_NOTE="not recorded in the envelope"
fi

# ===========================================================================
# 8. THE READOUT
# ===========================================================================
printf '◇ Adopted %s — stage %s\n' "$MID" "$STAGE"
printf '  Issue:    #%s — %s\n' "$ISSUE" "$TITLE"
printf '  Mission:  %s\n' "$MISSION_DIR"
printf '  Spec:     %s (rebuilt from the issue body)\n' "$SPEC_NAME"
printf '  Branch:   %s — %s\n' "${BRANCH:-<none>}" "$BRANCH_NOTE"
# S196 A3(g): WHICH engine takes over, and WHY it is that one. This line is the
# CLI half of "visible provenance"; the persisted engineSource/engineResolved
# pair is the half the viewscreen reads, and both are written from the same
# decision so they cannot tell different stories.
case "$ENGINE_SRC" in
  adopt-kept)
    if [ -n "$CFG_ENGINE" ] && [ "$CFG_ENGINE" != "$ENGINE_CHOSEN" ]; then
      printf '  Engine:   %s — the engine this mission was FILED on; it is installed here and now outranks this repo'"'"'s config.json (%s).\n' \
        "$ENGINE_CHOSEN" "$CFG_ENGINE"
    else
      printf '  Engine:   %s — the engine this mission was filed on, and it is installed here.\n' "$ENGINE_CHOSEN"
    fi ;;
  adopt-converted)
    printf '  Engine:   %s — CONVERTED here (the mission was filed on %s, which this machine does not have). Recorded on the mission; it outranks config.json from now on.\n' \
      "$ENGINE_CHOSEN" "${ENGINE:-<none>}" ;;
  adopt-chosen)
    printf '  Engine:   %s — your choice at the handoff (filed on %s, config.json prefers %s). Recorded on the mission.\n' \
      "$ENGINE_CHOSEN" "${ENGINE:-<none>}" "${CFG_ENGINE:-<none>}" ;;
  *)
    printf '  Engine:   not pinned — the mission records none, so the host CLI decides at run time.\n' ;;
esac
if [ -n "$OWNER" ]; then
  if [ -n "$ME" ] && [ "$OWNER" = "$ME" ]; then
    printf '  Owner:    %s (you)\n' "$OWNER"
  else
    printf '  Owner:    %s\n' "$OWNER"
  fi
else
  printf '  Owner:    unassigned\n'
fi
[ -n "$PR_URL" ] && printf '  PR:       %s\n' "$PR_URL"
[ -n "$XO_LINES" ] && printf '%s' "$XO_LINES"
[ "$EXISTING" -eq 1 ] && printf '  (refreshed an existing local mission — local artifacts kept)\n'
[ -n "$NOTES" ] && printf '%s' "$NOTES"

case "$STAGE" in
  align)
    printf 'Next: `lcars run %s` — the mission picks up at Align.\n' "$MID_LOCAL" ;;
  verify)
    if [ -n "$PR_URL" ]; then
      printf 'Next: review the PR, then `lcars approve %s` to merge, or `lcars feedback %s "…"` to send it back.\n' "$MID_LOCAL" "$MID_LOCAL"
    else
      printf 'Next: `lcars run %s` — Verify will open the PR.\n' "$MID_LOCAL"
    fi ;;
esac
exit 0
