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
# Idempotent: adopting a mission that is already local REFRESHES it — the spec
# and the recorded fields are brought up to date IN PLACE, and local-only
# artifacts (feedback.md, research findings, events.jsonl) are left alone.
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

# --- tiny JSON writers -----------------------------------------------------
# state.json is written ONE FIELD PER LINE by every writer in LCARS (file.sh's
# write_state, run.sh's open_pr, approve.sh), and json_escape flattens any
# newline in a value, so a field is edited as a LINE. These helpers keep that
# shape.
#
# They do NOT keep the shape of the copy-pasted helper the other verbs carry:
# that one deletes the field's line and re-inserts it after line 1 with a
# HARD-CODED trailing comma. `base` is the LAST field of every state.json and
# adopt's refresh path rewrites it, so the previously-second-to-last line kept
# its comma and became the last one — a trailing comma, and INVALID JSON.
# `lcars status` is sed-based and never noticed; the viewscreen board parses
# state.json for real, so a refreshed mission silently VANISHED from the
# captain's main surface (S189 fix round 1, defect 1).
#
# The cure is to treat the comma as a property of POSITION rather than of the
# line: every write re-derives the separators over whatever the object ends up
# containing, so only the last field carries none — for any key, including the
# last one, and for an object with a single field. It also repairs an object
# that a previous adopt already corrupted. A key that is already present is
# updated IN PLACE, which keeps file.sh's field order and makes a repeat adopt
# byte-stable; a NEW key still goes in at the top, exactly where the incumbent
# put it, because that convention is load-bearing while the siblings are
# unfixed — it is what keeps `base` the last field.
#
# The five sibling copies (run.sh, approve.sh, pause.sh, respond.sh,
# resolve-logs.sh) are LEDGERED, not touched here: nothing else in the product
# rewrites the last field, so they are latent, and fixing five files across the
# merge and drive paths mid-cure is exactly the restructure this project has
# paid for before.
json_escape() { # string → JSON-safe string body (no surrounding quotes)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '%s' "${s//$'\n'/\\n}"
}
state_put() { # key mode(str|raw|del) [value] — rewrite $STATE, commas re-derived
  local tmp; tmp="$(mktemp)"
  if K="$1" MODE="$2" V="${3:-}" awk '
    function rendered(   q) { q = (mode == "str") ? "\"" : ""
                              return "  \"" key "\": " q val q }
    BEGIN { key   = ENVIRON["K"]; mode = ENVIRON["MODE"]; val = ENVIRON["V"]
            # anchored at the start of the line, so a VALUE that happens to
            # contain `"base":` is never mistaken for the field itself.
            keyre = "^[[:space:]]*\"" key "\"[[:space:]]*:" }
    { line[NR] = $0 }
    END {
      if (NR < 2) exit 1
      close_i = NR
      while (close_i > 1 && line[close_i] !~ /^[[:space:]]*\}[[:space:]]*$/) close_i--
      if (close_i <= 1) exit 1          # no closing brace: leave the file alone
      n = 0; seen = 0
      for (i = 2; i < close_i; i++) {
        l = line[i]
        if (l ~ /^[[:space:]]*$/) continue
        sub(/,[[:space:]]*$/, "", l)    # the separator only; a comma INSIDE a
                                        # quoted value is not at end-of-line.
        if (l ~ keyre) {
          if (mode == "del") continue
          l = rendered(); seen = 1
        }
        out[++n] = l
      }
      print line[1]
      # A NEW key goes straight after the opening brace — the position the
      # incumbent helper used, and the one the five sibling copies still
      # DEPEND on (see the note above): it keeps `base` the LAST field, which
      # is what keeps their hard-coded comma latent. Appending here instead
      # would leave `review` last, and the `state_set_str review merged` in
      # approve would then corrupt the object the moment the captain shipped.
      if (mode != "del" && seen == 0) printf "%s%s\n", rendered(), (n > 0 ? "," : "")
      for (i = 1; i <= n; i++) printf "%s%s\n", out[i], (i < n ? "," : "")
      print line[close_i]
    }
  ' "$STATE" >"$tmp"; then mv "$tmp" "$STATE"; else rm -f "$tmp"; fi
}
state_del()     { state_put "$1" del; }                            # key
state_set_str() { state_put "$1" str "$(json_escape "$2")"; }      # key value
state_set_raw() { state_put "$1" raw "$2"; }                       # key token
json_str_of() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

# --- argv ------------------------------------------------------------------
ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'usage: adopt.sh --issue <issue-number>\n'
      printf '  Rebuilds the mission on issue <n> locally. Works at the ENDS of the\n'
      printf '  pipeline only: align (claim + rebuild) and verify (join + resolve PR).\n'
      exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *)  ISSUE="$1"; shift ;;
  esac
done
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
# 3. COMPOSE the mission — in staging, entirely.
# ===========================================================================
MISSION_DIR="$MISSIONS_DIR/$MID"
EXISTING=0
[ -f "$MISSION_DIR/state.json" ] && EXISTING=1

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
STATE="$STAGING/state.json"
if [ "$EXISTING" -eq 1 ]; then
  # REFRESH, never duplicate. Edit a COPY: the real file is only replaced once
  # the whole rebuild has succeeded, and every local-only field on it (an
  # estimate's modelOverride, baseSha, attachments paths) survives untouched.
  cp "$MISSION_DIR/state.json" "$STATE" 2>/dev/null || die "could not read the existing mission at $MISSION_DIR."
  state_set_str id "$MID"
  state_set_str title "$TITLE"
  state_set_str stage "$STAGE"
  state_set_str branch "$BRANCH"
  state_set_str base "$BASE"
  state_set_raw githubIssue "$ISSUE"
  [ -n "$TYPE" ]   && state_set_str type "$TYPE"
  [ -n "$ENGINE" ] && state_set_str workerBin "$ENGINE"
  case "$PARENT" in ''|null) state_del parentIssue ;; *) state_set_raw parentIssue "$PARENT" ;; esac
  if [ "$PARKED" = "true" ]; then state_set_raw prdPending true; else state_del prdPending; fi
  # A mission that is back at ALIGN has no open PR — `lcars feedback` closes the
  # PR when it bounces one, and Verify opens a FRESH one on the way back. So a
  # prUrl left over from this laptop's earlier copy of the mission is stale by
  # the label's own account, and keeping it would make `lcars run` believe a PR
  # is already open. The stage is the recorded fact; these follow it.
  if [ "$STAGE" = "align" ]; then
    state_del prUrl; state_del prNumber; state_del review
  fi
else
  MODEL=""
  CONFIG="$GITDIR/lcars/config.json"
  [ -f "$CONFIG" ] && MODEL="$(json_str_of "$CONFIG" model)"
  [ -n "$MODEL" ] || MODEL="${LCARS_MODEL:-claude-sonnet}"
  [ -f "$CONFIG" ] || note "this repo is not initialised for LCARS (no .git/lcars/config.json) — run \`lcars init\` before driving the mission."
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
    [ -n "$ENGINE" ] && printf '  "workerBin": "%s",\n' "$(json_escape "$ENGINE")"
    case "$PARENT" in ''|null) : ;; *) printf '  "parentIssue": %s,\n' "$PARENT" ;; esac
    printf '  "githubIssue": %s,\n' "$ISSUE"
    printf '  "branch": "%s",\n' "$(json_escape "$BRANCH")"
    printf '  "base": "%s"\n' "$(json_escape "$BASE")"
    printf '}\n'
  } >"$STATE"
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
    state_set_str prUrl "$PR_URL"
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
    case "$PR_NUM" in ''|*[!0-9]*) : ;; *) state_set_str prNumber "$PR_NUM" ;; esac
    # The same in-review sub-state the driving laptop records when Verify opens
    # the PR (run.sh cmd_open_pr), so the board reads "in review — PR open".
    state_set_str review open
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
# 6. PUBLISH — the whole mission, at once. Up to here the repo is untouched.
# ===========================================================================
mkdir -p "$MISSION_DIR" || die "could not create $MISSION_DIR."
cp "$STAGING/spec.md" "$MISSION_DIR/$SPEC_NAME" || die "could not write $MISSION_DIR/$SPEC_NAME."
cp "$STATE" "$MISSION_DIR/state.json" || die "could not write $MISSION_DIR/state.json."

[ "$ATTACH" -gt 0 ] 2>/dev/null && note "the original mission had $ATTACH attachment(s); GitHub has no API to carry issue assets, so they are NOT here. Copy them into $MISSION_DIR/attachments/ by hand if a stage needs them."

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
[ "$EXISTING" -eq 1 ] && printf '  (refreshed an existing local mission — local artifacts kept)\n'
[ -n "$NOTES" ] && printf '%s' "$NOTES"

case "$STAGE" in
  align)
    printf 'Next: `lcars run %s` — the mission picks up at Align.\n' "$MID" ;;
  verify)
    if [ -n "$PR_URL" ]; then
      printf 'Next: review the PR, then `lcars approve %s` to merge, or `lcars feedback %s "…"` to send it back.\n' "$MID" "$MID"
    else
      printf 'Next: `lcars run %s` — Verify will open the PR.\n' "$MID"
    fi ;;
esac
exit 0
